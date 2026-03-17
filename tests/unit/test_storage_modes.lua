--[[
Unit Tests for Track 24: Full Metadata Storage Mode Support

Tests:
- rebuildChatIndex() Phase A (index-based discovery from ReadHistory + indices)
- rebuildChatIndex() Phase B (dir/hash filesystem scan)
- Lazy sidecar migration (findSidecarInAlternateLocation / migrateSidecarIfNeeded)

Run: lua tests/run_tests.lua --unit
]]

-- Setup test environment
local function setupPaths()
    local info = debug.getinfo(1, "S")
    local script_path = info.source:match("@?(.*)")
    local unit_dir = script_path:match("(.+)/[^/]+$") or "."
    local tests_dir = unit_dir:match("(.+)/[^/]+$") or "."
    local plugin_dir = tests_dir:match("(.+)/[^/]+$") or "."

    package.path = table.concat({
        plugin_dir .. "/?.lua",
        plugin_dir .. "/?/init.lua",
        tests_dir .. "/?.lua",
        tests_dir .. "/lib/?.lua",
        package.path,
    }, ";")
end
setupPaths()

-- ============================================================
-- Deep copy utility
-- ============================================================
local function deepCopy(orig)
    if type(orig) ~= "table" then return orig end
    local copy = {}
    for k, v in pairs(orig) do
        copy[deepCopy(k)] = deepCopy(v)
    end
    return setmetatable(copy, getmetatable(orig))
end

-- ============================================================
-- Mock storage and state
-- ============================================================
local mock_storage = {}
local mock_files = {}        -- path → { mode = "file" } or { mode = "directory" }
local mock_dirs = {}         -- dir_path → { "entry1", "entry2", ... }
local mock_renames = {}      -- track os.rename calls
local mock_makepath_calls = {} -- track util.makePath calls
local storage_mode = "doc"   -- current document_metadata_folder setting

local function resetAll()
    mock_storage = {}
    mock_files = {}
    mock_dirs = {}
    mock_renames = {}
    mock_makepath_calls = {}
    storage_mode = "doc"
end

-- ============================================================
-- G_reader_settings mock
-- ============================================================
local g_reader_store = {}

_G.G_reader_settings = {
    readSetting = function(_self, key, default)
        if key == "chat_storage_version" then return 2 end
        if key == "document_metadata_folder" then return storage_mode end
        local val = g_reader_store[key]
        if val == nil then return default end
        return deepCopy(val)
    end,
    saveSetting = function(_self, key, value)
        g_reader_store[key] = deepCopy(value)
    end,
    flush = function() end,
}

-- ============================================================
-- Module cache reset (critical when run via run_tests.lua after other test suites)
-- Must happen BEFORE installing any mocks or loading any plugin modules
-- ============================================================
package.loaded["koassistant_chat_history_manager"] = nil
package.loaded["koassistant_action_cache"] = nil
package.loaded["koassistant_notebook"] = nil
package.loaded["koassistant_pinned_manager"] = nil
package.loaded["docsettings"] = nil
package.loaded["datastorage"] = nil
package.loaded["libs/libkoreader-lfs"] = nil
package.loaded["readhistory"] = nil
package.loaded["luasettings"] = nil
package.loaded["util"] = nil

-- Load standard mocks FIRST (logger, ffi, json, etc.)
require("mock_koreader")

-- ============================================================
-- Now override specific mocks with our enhanced versions
-- ============================================================

-- MockDocSettings with getSidecarDir, openSettingsFile, isHashLocationEnabled
local MockDocSettings = {}
MockDocSettings.__index = MockDocSettings

function MockDocSettings:getSidecarDir(doc_path, force_location)
    local location = force_location or storage_mode
    local base = doc_path:match("(.*)%.") or doc_path
    if location == "doc" then
        return base .. ".sdr"
    elseif location == "dir" then
        return "/tmp/koreader/docsettings" .. base .. ".sdr"
    elseif location == "hash" then
        local hash = "hash_" .. doc_path:gsub("[^%w]", ""):sub(1, 12)
        return "/tmp/koreader/hashdocsettings/" .. hash:sub(1, 2) .. "/" .. hash .. ".sdr"
    end
    return base .. ".sdr"
end

function MockDocSettings:open(path)
    local store_key = "docsettings:" .. path
    if not mock_storage[store_key] then mock_storage[store_key] = {} end
    return setmetatable({ _path = store_key }, MockDocSettings)
end

function MockDocSettings.openSettingsFile(sidecar_file)
    local store_key = "settingsfile:" .. sidecar_file
    local data = mock_storage[store_key] or {}
    return { data = data }
end

function MockDocSettings:readSetting(key, default)
    local val = mock_storage[self._path][key]
    if val == nil then return default end
    return deepCopy(val)
end

function MockDocSettings:saveSetting(key, value)
    mock_storage[self._path][key] = deepCopy(value)
end

function MockDocSettings:flush() end

function MockDocSettings.isHashLocationEnabled()
    return storage_mode == "hash"
        or mock_files["/tmp/koreader/hashdocsettings"] ~= nil
end

function MockDocSettings.getSidecarFilename(doc_path)
    local suffix = doc_path:match(".*%.(.+)") or "_"
    return "metadata." .. suffix .. ".lua"
end

package.loaded["docsettings"] = MockDocSettings

-- Mock LuaSettings
package.loaded["luasettings"] = {
    open = function(path)
        if not mock_storage[path] then mock_storage[path] = {} end
        return {
            _path = path,
            readSetting = function(self, key, default)
                local val = mock_storage[self._path][key]
                if val == nil then return default end
                return deepCopy(val)
            end,
            saveSetting = function(self, key, value)
                mock_storage[self._path][key] = deepCopy(value)
            end,
            flush = function() end,
        }
    end,
}

-- Mock util
package.loaded["util"] = {
    makePath = function(path)
        table.insert(mock_makepath_calls, path)
    end,
}

-- Mock ffi/sha2
package.loaded["ffi/sha2"] = {
    md5 = function(str) return "mock_md5_" .. tostring(str):sub(1, 8) end,
}

-- Mock lfs with directory listing support
local real_lfs_ok, real_lfs = pcall(require, "lfs")
local mock_lfs = {
    attributes = function(path, attr_name)
        local info = mock_files[path]
        if info then
            if attr_name == "mode" then return info.mode end
            if attr_name == "size" then return info.size or 100 end
            return info
        end
        if real_lfs_ok then
            return real_lfs.attributes(path, attr_name)
        end
        return nil
    end,
    dir = function(path)
        local entries = mock_dirs[path]
        if entries then
            local i = 0
            return function()
                i = i + 1
                return entries[i]
            end
        end
        error("cannot open " .. path .. ": No such file or directory")
    end,
}
package.loaded["libs/libkoreader-lfs"] = mock_lfs

-- Override datastorage with dir/hash support
package.loaded["datastorage"] = {
    getDataDir = function() return "/tmp/koreader" end,
    getSettingsDir = function() return "/tmp/koreader/settings" end,
    getDocSettingsDir = function() return "/tmp/koreader/docsettings" end,
    getDocSettingsHashDir = function() return "/tmp/koreader/hashdocsettings" end,
}

-- Override os.rename to track calls
local original_rename = os.rename
os.rename = function(old, new)
    table.insert(mock_renames, { old = old, new = new })
    if mock_files[old] then
        mock_files[new] = mock_files[old]
        mock_files[old] = nil
    end
    return true
end

-- Mock ReadHistory
local mock_read_history = { hist = {} }
package.loaded["readhistory"] = mock_read_history

-- Load ChatHistoryManager
local ChatHistoryManager = require("koassistant_chat_history_manager")

-- ============================================================
-- Test Runner
-- ============================================================
local TestRunner = {
    passed = 0,
    failed = 0,
}

function TestRunner:test(name, fn)
    resetAll()
    g_reader_store = {}
    mock_read_history.hist = {}

    local ok, err = pcall(fn)
    if ok then
        self.passed = self.passed + 1
        print(string.format("  \226\156\147 %s", name))
    else
        self.failed = self.failed + 1
        print(string.format("  \226\156\151 %s: %s", name, tostring(err)))
    end
end

function TestRunner:assertEqual(actual, expected, message)
    if actual ~= expected then
        error(string.format("%s: expected '%s', got '%s'",
            message or "Values not equal",
            tostring(expected), tostring(actual)), 2)
    end
end

function TestRunner:assertTrue(value, message)
    if not value then
        error(string.format("%s: expected true", message or "Assertion failed"), 2)
    end
end

function TestRunner:assertNil(value, message)
    if value ~= nil then
        error(string.format("%s: expected nil, got '%s'",
            message or "Assertion failed", tostring(value)), 2)
    end
end

function TestRunner:assertNotNil(value, message)
    if value == nil then
        error(string.format("%s: expected non-nil",
            message or "Assertion failed"), 2)
    end
end

-- ============================================================
-- Helper: populate a book with chats in MockDocSettings
-- ============================================================
local function addBookWithChats(doc_path, chat_ids)
    local store_key = "docsettings:" .. doc_path
    local chats = {}
    for _idx, id in ipairs(chat_ids) do
        chats[id] = { id = id, messages = {} }
    end
    mock_storage[store_key] = { koassistant_chats = chats }
    -- Register as existing file
    mock_files[doc_path] = { mode = "file" }
end

-- ============================================================
-- Tests: Phase A — Index-based discovery
-- ============================================================
print("\n  -- Phase A: Index-based discovery --")

TestRunner:test("Phase A: discovers books from ReadHistory", function()
    storage_mode = "doc"
    addBookWithChats("/books/novel.epub", { "chat1", "chat2" })
    addBookWithChats("/books/guide.pdf", { "chat3" })
    mock_read_history.hist = {
        { file = "/books/novel.epub" },
        { file = "/books/guide.pdf" },
    }

    local count = ChatHistoryManager:rebuildChatIndex()
    TestRunner:assertEqual(count, 2, "Should find 2 books with chats")

    local index = g_reader_store["koassistant_chat_index"]
    TestRunner:assertNotNil(index["/books/novel.epub"], "novel should be indexed")
    TestRunner:assertEqual(index["/books/novel.epub"].count, 2, "novel chat count")
    TestRunner:assertNotNil(index["/books/guide.pdf"], "guide should be indexed")
    TestRunner:assertEqual(index["/books/guide.pdf"].count, 1, "guide chat count")
end)

TestRunner:test("Phase A: discovers books from notebook index", function()
    storage_mode = "doc"
    addBookWithChats("/books/noted.epub", { "c1" })
    g_reader_store["koassistant_notebook_index"] = { ["/books/noted.epub"] = { size = 100 } }

    local count = ChatHistoryManager:rebuildChatIndex()
    TestRunner:assertEqual(count, 1, "Should find book from notebook index")
end)

TestRunner:test("Phase A: discovers books from artifact index", function()
    storage_mode = "doc"
    addBookWithChats("/books/analyzed.epub", { "c1", "c2", "c3" })
    g_reader_store["koassistant_artifact_index"] = { ["/books/analyzed.epub"] = { count = 2 } }

    local count = ChatHistoryManager:rebuildChatIndex()
    TestRunner:assertEqual(count, 1, "Should find book from artifact index")
    local index = g_reader_store["koassistant_chat_index"]
    TestRunner:assertEqual(index["/books/analyzed.epub"].count, 3, "correct chat count")
end)

TestRunner:test("Phase A: discovers books from pinned index (skips special keys)", function()
    storage_mode = "doc"
    addBookWithChats("/books/pinned.epub", { "c1" })
    g_reader_store["koassistant_pinned_index"] = {
        ["/books/pinned.epub"] = { count = 1 },
        ["__GENERAL_CHATS__"] = { count = 2 },
        ["__LIBRARY_CHATS__"] = { count = 1 },
    }

    local count = ChatHistoryManager:rebuildChatIndex()
    TestRunner:assertEqual(count, 1, "Should find 1 book (skip special keys)")
end)

TestRunner:test("Phase A: deduplicates across sources", function()
    storage_mode = "doc"
    addBookWithChats("/books/everywhere.epub", { "c1" })
    mock_read_history.hist = { { file = "/books/everywhere.epub" } }
    g_reader_store["koassistant_notebook_index"] = { ["/books/everywhere.epub"] = {} }
    g_reader_store["koassistant_artifact_index"] = { ["/books/everywhere.epub"] = {} }

    local count = ChatHistoryManager:rebuildChatIndex()
    TestRunner:assertEqual(count, 1, "Should count book only once despite 3 sources")
end)

TestRunner:test("Phase A: skips books without chats", function()
    storage_mode = "doc"
    -- Book exists but has no chats
    mock_files["/books/empty.epub"] = { mode = "file" }
    mock_storage["docsettings:/books/empty.epub"] = {}
    mock_read_history.hist = { { file = "/books/empty.epub" } }

    local count = ChatHistoryManager:rebuildChatIndex()
    TestRunner:assertEqual(count, 0, "Should not index book without chats")
end)

TestRunner:test("Phase A: skips missing book files", function()
    storage_mode = "doc"
    -- Book in ReadHistory but file doesn't exist on disk
    mock_storage["docsettings:/books/deleted.epub"] = {
        koassistant_chats = { c1 = { id = "c1" } },
    }
    mock_read_history.hist = { { file = "/books/deleted.epub" } }
    -- Note: NOT registering /books/deleted.epub in mock_files

    local count = ChatHistoryManager:rebuildChatIndex()
    TestRunner:assertEqual(count, 0, "Should skip book whose file is missing")
end)

TestRunner:test("Phase A: works in dir mode", function()
    storage_mode = "dir"
    addBookWithChats("/books/novel.epub", { "c1" })
    mock_read_history.hist = { { file = "/books/novel.epub" } }

    local count = ChatHistoryManager:rebuildChatIndex()
    TestRunner:assertEqual(count, 1, "Should find book via Phase A in dir mode")
end)

TestRunner:test("Phase A: works in hash mode", function()
    storage_mode = "hash"
    addBookWithChats("/books/novel.epub", { "c1" })
    mock_read_history.hist = { { file = "/books/novel.epub" } }

    local count = ChatHistoryManager:rebuildChatIndex()
    TestRunner:assertEqual(count, 1, "Should find book via Phase A in hash mode")
end)

-- ============================================================
-- Tests: Phase B — Dir mode filesystem scan
-- ============================================================
print("\n  -- Phase B: Dir mode filesystem scan --")

TestRunner:test("Phase B dir: scans docsettings dir for .sdr folders", function()
    storage_mode = "dir"
    -- Set up directory structure: /tmp/koreader/docsettings/books/novel.sdr/metadata.epub.lua
    local docsettings = "/tmp/koreader/docsettings"
    mock_files[docsettings] = { mode = "directory" }
    mock_dirs[docsettings] = { ".", "..", "books" }
    mock_files[docsettings .. "/books"] = { mode = "directory" }
    mock_dirs[docsettings .. "/books"] = { ".", "..", "novel.sdr" }
    mock_files[docsettings .. "/books/novel.sdr"] = { mode = "directory" }
    mock_dirs[docsettings .. "/books/novel.sdr"] = { ".", "..", "metadata.epub.lua" }

    -- The reconstructed book path: /books/novel.epub
    addBookWithChats("/books/novel.epub", { "chat_from_scan" })

    local count = ChatHistoryManager:rebuildChatIndex()
    TestRunner:assertEqual(count, 1, "Should find book via dir mode scan")
    local index = g_reader_store["koassistant_chat_index"]
    TestRunner:assertNotNil(index["/books/novel.epub"], "Should index /books/novel.epub")
end)

-- ============================================================
-- Tests: Phase B — Hash mode filesystem scan
-- ============================================================
print("\n  -- Phase B: Hash mode filesystem scan --")

TestRunner:test("Phase B hash: scans hashdocsettings for .sdr folders", function()
    storage_mode = "hash"
    local hash_dir = "/tmp/koreader/hashdocsettings"
    mock_files[hash_dir] = { mode = "directory" }
    mock_dirs[hash_dir] = { ".", "..", "ab" }
    mock_files[hash_dir .. "/ab"] = { mode = "directory" }
    mock_dirs[hash_dir .. "/ab"] = { ".", "..", "abcdef1234.sdr" }
    mock_files[hash_dir .. "/ab/abcdef1234.sdr"] = { mode = "directory" }
    mock_dirs[hash_dir .. "/ab/abcdef1234.sdr"] = { ".", "..", "metadata.epub.lua" }

    -- Pre-populate the settings file with doc_path
    local meta_path = hash_dir .. "/ab/abcdef1234.sdr/metadata.epub.lua"
    mock_storage["settingsfile:" .. meta_path] = { doc_path = "/books/hashed_book.epub" }

    -- Register the book with chats
    addBookWithChats("/books/hashed_book.epub", { "hchat1" })

    local count = ChatHistoryManager:rebuildChatIndex()
    TestRunner:assertEqual(count, 1, "Should find book via hash mode scan")
    local index = g_reader_store["koassistant_chat_index"]
    TestRunner:assertNotNil(index["/books/hashed_book.epub"], "Should index hashed book")
end)

TestRunner:test("Phase B hash: skips non-2char prefix dirs", function()
    storage_mode = "hash"
    local hash_dir = "/tmp/koreader/hashdocsettings"
    mock_files[hash_dir] = { mode = "directory" }
    mock_dirs[hash_dir] = { ".", "..", "toolong", "x" }  -- neither is 2 chars
    -- No valid prefix dirs → no scanning

    local count = ChatHistoryManager:rebuildChatIndex()
    TestRunner:assertEqual(count, 0, "Should not find anything with invalid prefix dirs")
end)

-- ============================================================
-- Tests: No doc-mode filesystem scan
-- ============================================================
print("\n  -- Doc mode: no filesystem scan --")

TestRunner:test("doc mode: does NOT run filesystem scan (Phase B skipped)", function()
    storage_mode = "doc"
    -- Even with a book that has chats, if it's not in any index, it won't be found
    -- because Phase B doesn't run for doc mode
    addBookWithChats("/hidden/secret.epub", { "c1" })
    -- Not in ReadHistory, not in any index

    local count = ChatHistoryManager:rebuildChatIndex()
    TestRunner:assertEqual(count, 0, "Should not find books without index source in doc mode")
end)

-- ============================================================
-- Tests: Lazy sidecar migration
-- ============================================================
print("\n  -- Lazy sidecar migration --")

-- For migration tests, we test the ActionCache module directly
-- We need to reload it after our mocks are set up
local ActionCache = require("koassistant_action_cache")

TestRunner:test("ActionCache.getPath: returns correct path for doc mode", function()
    storage_mode = "doc"
    local path = ActionCache.getPath("/books/test.epub")
    TestRunner:assertEqual(path, "/books/test.sdr/koassistant_cache.lua", "doc mode cache path")
end)

TestRunner:test("ActionCache.getPath: returns correct path for dir mode", function()
    storage_mode = "dir"
    local path = ActionCache.getPath("/books/test.epub")
    TestRunner:assertEqual(path, "/tmp/koreader/docsettings/books/test.sdr/koassistant_cache.lua", "dir mode cache path")
end)

TestRunner:test("ActionCache.getPath: returns nil for special paths", function()
    TestRunner:assertNil(ActionCache.getPath("__GENERAL_CHATS__"), "general")
    TestRunner:assertNil(ActionCache.getPath("__LIBRARY_CHATS__"), "library")
    TestRunner:assertNil(ActionCache.getPath(nil), "nil")
end)

TestRunner:test("lazy migration: loadCache migrates from doc to dir mode", function()
    storage_mode = "dir"
    local doc_path = "/books/migrateme.epub"

    -- File exists at old (doc) location but NOT at new (dir) location
    local old_path = "/books/migrateme.sdr/koassistant_cache.lua"
    mock_files[old_path] = { mode = "file" }
    -- Also register the hash dir as non-existent so isHashLocationEnabled returns false
    -- (default: no hash dir)

    -- Trigger load — should attempt migration
    local cache = ActionCache.get(doc_path, "some_action")
    -- Migration should have been attempted (os.rename called)
    local found_rename = false
    for _idx, r in ipairs(mock_renames) do
        if r.old == old_path then
            found_rename = true
            break
        end
    end
    TestRunner:assertTrue(found_rename, "Should have called os.rename to migrate cache file")
end)

TestRunner:test("lazy migration: no migration when file exists at current location", function()
    storage_mode = "doc"
    local doc_path = "/books/existing.epub"

    -- File exists at current location
    local current_path = "/books/existing.sdr/koassistant_cache.lua"
    mock_files[current_path] = { mode = "file" }

    local _cache = ActionCache.get(doc_path, "some_action")
    -- No rename should occur
    TestRunner:assertEqual(#mock_renames, 0, "Should not attempt migration when file exists")
end)

-- ============================================================
-- Results
-- ============================================================
print(string.format("\n  Storage Modes: %d passed, %d failed", TestRunner.passed, TestRunner.failed))
return TestRunner.failed == 0
