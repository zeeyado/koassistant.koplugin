--[[
Unit Tests for issue #92: Index healing & rebuild

Tests:
- updateChatIndex "refresh" op: change detection (set-based id compare),
  mutex reset on the no-op path, save path unchanged
- Per-book refresh helpers: refreshChatIndexEntry, Notebook.refreshIndexEntry,
  PinnedManager.refreshIndex (entry created / removed / unchanged-no-write)
- IndexRebuilder.run: merge semantics (never wipes), book-stat gate,
  multi-location sidecar fast-skip, Phase C folder walk, batch flush,
  unmapped-sidecar reporting
- IndexRebuilder.pruneAllIndexes: dead paths removed, special keys kept

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
local mock_files = {}        -- path → { mode = "file"|"directory", size, modification }
local mock_dirs = {}         -- dir_path → { "entry1", "entry2", ... }
local storage_mode = "doc"   -- current document_metadata_folder setting

-- ============================================================
-- G_reader_settings mock with save/flush counters
-- ============================================================
local g_reader_store = {}
local save_counts = {}       -- key → number of saveSetting calls
local flush_count = 0

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
        save_counts[key] = (save_counts[key] or 0) + 1
    end,
    flush = function()
        flush_count = flush_count + 1
    end,
}

-- ============================================================
-- Module cache reset (critical when run via run_tests.lua after other suites)
-- Must happen BEFORE installing any mocks or loading any plugin modules
-- ============================================================
-- Save modules we'll override, for restoration after tests (so later suites
-- in the same run see the standard environment again)
local _overridden = {
    "libs/libkoreader-lfs", "datastorage", "util", "docsettings",
    "luasettings", "readhistory", "ffi/sha2", "document/documentregistry",
}
local _saved = {}
for _idx, name in ipairs(_overridden) do
    _saved[name] = package.loaded[name]
end

package.loaded["koassistant_index_rebuilder"] = nil
package.loaded["koassistant_chat_history_manager"] = nil
package.loaded["koassistant_action_cache"] = nil
package.loaded["koassistant_notebook"] = nil
package.loaded["koassistant_pinned_manager"] = nil
package.loaded["koassistant_library_scanner"] = nil
package.loaded["koassistant_doc_settings"] = nil
package.loaded["docsettings"] = nil
package.loaded["datastorage"] = nil
package.loaded["libs/libkoreader-lfs"] = nil
package.loaded["readhistory"] = nil
package.loaded["luasettings"] = nil
package.loaded["util"] = nil
package.loaded["document/documentregistry"] = nil

-- Load standard mocks FIRST (logger, ffi, json, etc.)
require("mock_koreader")

-- Capture logger.warn calls (mutex-collision regression check)
local warn_log = {}
local logger_mock = package.loaded["logger"]
local _saved_warn = logger_mock.warn
logger_mock.warn = function(...)
    local parts = {}
    for i = 1, select("#", ...) do
        parts[#parts + 1] = tostring(select(i, ...))
    end
    table.insert(warn_log, table.concat(parts, " "))
end

-- ============================================================
-- Enhanced mocks
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
    makePath = function() end,
}

-- Mock ffi/sha2
package.loaded["ffi/sha2"] = {
    md5 = function(str) return "mock_md5_" .. tostring(str):sub(1, 8) end,
}

-- Mock lfs with directory listing support
local mock_lfs = {
    attributes = function(path, attr_name)
        local info = mock_files[path]
        if info then
            if attr_name == "mode" then return info.mode end
            if attr_name == "size" then return info.size or 100 end
            if attr_name == "modification" then return info.modification or 0 end
            return info
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

-- Mock datastorage
package.loaded["datastorage"] = {
    getDataDir = function() return "/tmp/koreader" end,
    getSettingsDir = function() return "/tmp/koreader/settings" end,
    getDocSettingsDir = function() return "/tmp/koreader/docsettings" end,
    getDocSettingsHashDir = function() return "/tmp/koreader/hashdocsettings" end,
}

-- Mock ReadHistory
local mock_read_history = { hist = {} }
package.loaded["readhistory"] = mock_read_history

-- Mock DocumentRegistry (library scanner file filter)
package.loaded["document/documentregistry"] = {
    hasProvider = function(_self, path)
        return path:match("%.epub$") ~= nil or path:match("%.pdf$") ~= nil
    end,
}

-- Load modules under test (after all mocks are in place)
local ChatHistoryManager = require("koassistant_chat_history_manager")
local Notebook = require("koassistant_notebook")
local PinnedManager = require("koassistant_pinned_manager")
local IndexRebuilder = require("koassistant_index_rebuilder")

-- ============================================================
-- Test Runner
-- ============================================================
local TestRunner = {
    passed = 0,
    failed = 0,
}

local function resetAll()
    mock_storage = {}
    mock_files = {}
    mock_dirs = {}
    g_reader_store = {}
    save_counts = {}
    flush_count = 0
    warn_log = {}
    storage_mode = "doc"
    mock_read_history.hist = {}
end

function TestRunner:test(name, fn)
    resetAll()
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
-- Helpers
-- ============================================================
local CHAT_KEY = "koassistant_chat_index"

local function chatsTable(ids)
    local chats = {}
    for _idx, id in ipairs(ids) do
        chats[id] = { id = id, timestamp = 1000, messages = {} }
    end
    return chats
end

-- Book with chats readable through (Safe)DocSettings + existing book file
local function addBookWithChats(doc_path, chat_ids)
    mock_storage["docsettings:" .. doc_path] = { koassistant_chats = chatsTable(chat_ids) }
    mock_files[doc_path] = { mode = "file" }
end

-- Register the book's doc-mode sidecar dir (rebuild fast-skip gate)
local function addDocSidecarDir(doc_path)
    local base = doc_path:match("(.*)%.") or doc_path
    mock_files[base .. ".sdr"] = { mode = "directory" }
end

local function chatSaves()
    return save_counts[CHAT_KEY] or 0
end

-- ============================================================
-- Tests: updateChatIndex "refresh" op (P1)
-- ============================================================
print("\n  -- updateChatIndex refresh op (P1) --")

TestRunner:test("refresh: unchanged entry writes nothing", function()
    local chats = chatsTable({ "c1", "c2" })
    ChatHistoryManager:updateChatIndex("/books/a.epub", "save", nil, chats)
    local saves_after_seed = chatSaves()
    local flushes_after_seed = flush_count

    ChatHistoryManager:updateChatIndex("/books/a.epub", "refresh", nil, chats)
    TestRunner:assertEqual(chatSaves(), saves_after_seed, "refresh must not save when unchanged")
    TestRunner:assertEqual(flush_count, flushes_after_seed, "refresh must not flush when unchanged")
end)

TestRunner:test("refresh: no-op does not poison the collision mutex", function()
    local chats = chatsTable({ "c1" })
    ChatHistoryManager:updateChatIndex("/books/a.epub", "save", nil, chats)
    -- No-op refresh takes the early-return path
    ChatHistoryManager:updateChatIndex("/books/a.epub", "refresh", nil, chats)
    -- A later save must NOT log a collision warning
    warn_log = {}
    ChatHistoryManager:updateChatIndex("/books/a.epub", "save", nil, chats)
    for _idx, msg in ipairs(warn_log) do
        TestRunner:assertTrue(not msg:find("collision"),
            "mutex stuck: collision warning logged after no-op refresh")
    end
end)

TestRunner:test("refresh: changed chat count writes", function()
    ChatHistoryManager:updateChatIndex("/books/a.epub", "save", nil, chatsTable({ "c1" }))
    ChatHistoryManager:updateChatIndex("/books/a.epub", "refresh", nil, chatsTable({ "c1", "c2" }))
    local entry = g_reader_store[CHAT_KEY]["/books/a.epub"]
    TestRunner:assertEqual(entry.count, 2, "refresh should pick up the new chat")
end)

TestRunner:test("refresh: same count, different id set writes (set compare)", function()
    ChatHistoryManager:updateChatIndex("/books/a.epub", "save", nil, chatsTable({ "c1", "c2" }))
    ChatHistoryManager:updateChatIndex("/books/a.epub", "refresh", nil, chatsTable({ "c1", "c3" }))
    local entry = g_reader_store[CHAT_KEY]["/books/a.epub"]
    local has_c3 = false
    for _idx, id in ipairs(entry.chat_ids) do
        if id == "c3" then has_c3 = true end
    end
    TestRunner:assertTrue(has_c3, "id-set change must be detected despite equal count")
end)

TestRunner:test("refresh: preserves last_modified", function()
    ChatHistoryManager:updateChatIndex("/books/a.epub", "save", nil, chatsTable({ "c1" }))
    local t1 = g_reader_store[CHAT_KEY]["/books/a.epub"].last_modified
    ChatHistoryManager:updateChatIndex("/books/a.epub", "refresh", nil, chatsTable({ "c1", "c2" }))
    TestRunner:assertEqual(g_reader_store[CHAT_KEY]["/books/a.epub"].last_modified, t1,
        "refresh must not bump last_modified")
end)

TestRunner:test("refresh: removes entry when chats gone", function()
    ChatHistoryManager:updateChatIndex("/books/a.epub", "save", nil, chatsTable({ "c1" }))
    ChatHistoryManager:updateChatIndex("/books/a.epub", "refresh", nil, {})
    TestRunner:assertNil(g_reader_store[CHAT_KEY]["/books/a.epub"], "entry should be removed")
end)

TestRunner:test("refresh: no entry + no chats = no write", function()
    ChatHistoryManager:updateChatIndex("/books/a.epub", "refresh", nil, {})
    TestRunner:assertEqual(chatSaves(), 0, "nothing to do, nothing to write")
end)

TestRunner:test("save: still always writes", function()
    local chats = chatsTable({ "c1" })
    ChatHistoryManager:updateChatIndex("/books/a.epub", "save", nil, chats)
    local n = chatSaves()
    ChatHistoryManager:updateChatIndex("/books/a.epub", "save", nil, chats)
    TestRunner:assertEqual(chatSaves(), n + 1, "save op must write unconditionally")
end)

TestRunner:test("no_flush opt skips flush but saves", function()
    ChatHistoryManager:updateChatIndex("/books/a.epub", "save", nil, chatsTable({ "c1" }),
        { no_flush = true })
    TestRunner:assertEqual(chatSaves(), 1, "should save")
    TestRunner:assertEqual(flush_count, 0, "should not flush")
end)

-- ============================================================
-- Tests: refreshChatIndexEntry (sidecar-driven heal)
-- ============================================================
print("\n  -- refreshChatIndexEntry --")

TestRunner:test("heals index from sidecar chats", function()
    addBookWithChats("/books/synced.epub", { "x1", "x2" })
    ChatHistoryManager:refreshChatIndexEntry("/books/synced.epub", nil)
    local entry = g_reader_store[CHAT_KEY]["/books/synced.epub"]
    TestRunner:assertNotNil(entry, "synced book should be indexed")
    TestRunner:assertEqual(entry.count, 2, "both chats counted")
end)

TestRunner:test("special keys are refused", function()
    ChatHistoryManager:refreshChatIndexEntry("__GENERAL_CHATS__", nil)
    TestRunner:assertEqual(chatSaves(), 0, "special key must not be indexed")
end)

-- ============================================================
-- Tests: Notebook.refreshIndexEntry
-- ============================================================
print("\n  -- Notebook.refreshIndexEntry --")

local NB_KEY = "koassistant_notebook_index"

TestRunner:test("creates entry when notebook file exists", function()
    mock_files["/books/x.sdr/koassistant_notebook.md"] =
        { mode = "file", size = 42, modification = 1000 }
    Notebook.refreshIndexEntry("/books/x.epub")
    local entry = g_reader_store[NB_KEY]["/books/x.epub"]
    TestRunner:assertNotNil(entry, "entry should be created")
    TestRunner:assertEqual(entry.size, 42, "size recorded")
    TestRunner:assertEqual(entry.modified, 1000, "mtime recorded")
end)

TestRunner:test("unchanged entry writes nothing on second run", function()
    mock_files["/books/x.sdr/koassistant_notebook.md"] =
        { mode = "file", size = 42, modification = 1000 }
    Notebook.refreshIndexEntry("/books/x.epub")
    local n = save_counts[NB_KEY] or 0
    Notebook.refreshIndexEntry("/books/x.epub")
    TestRunner:assertEqual(save_counts[NB_KEY] or 0, n, "no write when unchanged")
end)

TestRunner:test("removes entry when notebook file gone", function()
    g_reader_store[NB_KEY] = { ["/books/x.epub"] = { modified = 1, size = 1 } }
    Notebook.refreshIndexEntry("/books/x.epub")
    TestRunner:assertNil((g_reader_store[NB_KEY] or {})["/books/x.epub"], "entry removed")
end)

TestRunner:test("no file + no entry = no write", function()
    Notebook.refreshIndexEntry("/books/x.epub")
    TestRunner:assertEqual(save_counts[NB_KEY] or 0, 0, "nothing to do, nothing to write")
end)

-- ============================================================
-- Tests: PinnedManager.refreshIndex
-- ============================================================
print("\n  -- PinnedManager.refreshIndex --")

TestRunner:test("removes stale entry when pinned file missing", function()
    local PIN_KEY = "koassistant_pinned_index"
    g_reader_store[PIN_KEY] = { ["/books/x.epub"] = { count = 2, modified = 1 } }
    PinnedManager.refreshIndex("/books/x.epub")
    TestRunner:assertNil((g_reader_store[PIN_KEY] or {})["/books/x.epub"], "entry removed")
end)

-- ============================================================
-- Tests: IndexRebuilder.run
-- ============================================================
print("\n  -- IndexRebuilder.run --")

TestRunner:test("merge: known books re-verified, history books added, unreachable entries survive", function()
    -- Book A: only in the chat index (Phase A cross-pollination re-verifies it)
    addBookWithChats("/books/a.epub", { "a1" })
    addDocSidecarDir("/books/a.epub")
    g_reader_store[CHAT_KEY] = {
        ["/books/a.epub"] = { count = 1, last_modified = 1, chat_ids = { "a1" } },
        -- Book C: entry exists, book file exists, but NO sidecar dir anywhere
        -- (e.g. data on unmounted storage): must survive a rebuild untouched
        ["/books/c.epub"] = { count = 3, last_modified = 5, chat_ids = { "c1", "c2", "c3" } },
    }
    mock_files["/books/c.epub"] = { mode = "file" }
    -- Book B: only in ReadHistory, has synced chats on disk
    addBookWithChats("/books/b.epub", { "b1", "b2" })
    addDocSidecarDir("/books/b.epub")
    mock_read_history.hist = { { file = "/books/b.epub" } }

    IndexRebuilder.run(nil, {})

    local index = g_reader_store[CHAT_KEY]
    TestRunner:assertNotNil(index["/books/a.epub"], "A re-verified")
    TestRunner:assertNotNil(index["/books/b.epub"], "B discovered from history")
    TestRunner:assertEqual(index["/books/b.epub"].count, 2, "B chats counted")
    TestRunner:assertNotNil(index["/books/c.epub"], "C must survive (merge, not wipe)")
    TestRunner:assertEqual(index["/books/c.epub"].count, 3, "C untouched")
end)

TestRunner:test("book-stat gate: foreign sidecar path not indexed, reported as unmapped", function()
    storage_mode = "dir"
    -- Central dir-mode tree with one synced sidecar whose book doesn't exist locally
    mock_files["/tmp/koreader/docsettings"] = { mode = "directory" }
    mock_dirs["/tmp/koreader/docsettings"] = { "books" }
    mock_files["/tmp/koreader/docsettings/books"] = { mode = "directory" }
    mock_dirs["/tmp/koreader/docsettings/books"] = { "novel.sdr" }
    mock_files["/tmp/koreader/docsettings/books/novel.sdr"] = { mode = "directory" }
    mock_dirs["/tmp/koreader/docsettings/books/novel.sdr"] =
        { "metadata.epub.lua", "koassistant_cache.lua" }
    mock_files["/tmp/koreader/docsettings/books/novel.sdr/koassistant_cache.lua"] = { mode = "file" }
    -- reconstructed path /books/novel.epub does NOT exist in mock_files

    local report = IndexRebuilder.run(nil, {})

    TestRunner:assertNil((g_reader_store[CHAT_KEY] or {})["/books/novel.epub"],
        "dead path must not be indexed")
    TestRunner:assertEqual(report.skipped_missing, 1, "missing book counted")
    TestRunner:assertEqual(report.unmapped_sidecars, 1, "sidecar with data reported")
end)

TestRunner:test("fast-skip checks alternate sidecar locations (doc mode, dir-location data)", function()
    storage_mode = "doc"
    addBookWithChats("/books/w.epub", { "w1" })
    -- NO /books/w.sdr — but the dir-location sidecar dir exists
    mock_files["/tmp/koreader/docsettings/books/w.sdr"] = { mode = "directory" }
    mock_read_history.hist = { { file = "/books/w.epub" } }

    IndexRebuilder.run(nil, {})

    TestRunner:assertNotNil(g_reader_store[CHAT_KEY]["/books/w.epub"],
        "dir-location sidecar must not be fast-skipped in doc mode")
end)

TestRunner:test("fast-skip: no sidecar dir anywhere = book not healed", function()
    storage_mode = "doc"
    addBookWithChats("/books/v.epub", { "v1" })  -- chats in store, but no .sdr dir mock
    mock_read_history.hist = { { file = "/books/v.epub" } }

    IndexRebuilder.run(nil, {})

    TestRunner:assertNil((g_reader_store[CHAT_KEY] or {})["/books/v.epub"],
        "no sidecar dir → skipped")
end)

TestRunner:test("phase C: user folders scanned, missing folders skipped", function()
    storage_mode = "doc"
    addBookWithChats("/sync/books/s.epub", { "s1" })
    addDocSidecarDir("/sync/books/s.epub")
    mock_files["/sync/books"] = { mode = "directory" }
    mock_dirs["/sync/books"] = { "s.epub", "notes.txt" }
    mock_files["/sync/books/notes.txt"] = { mode = "file" }

    local report = IndexRebuilder.run(nil, {
        index_scan_folders = { "/sync/books", "/gone/folder" },
    })

    TestRunner:assertNotNil(g_reader_store[CHAT_KEY]["/sync/books/s.epub"],
        "book in scan folder discovered")
    TestRunner:assertEqual(report.candidates.c, 1, "only document files counted")
end)

TestRunner:test("phase C: no folders configured = no folder scan", function()
    storage_mode = "doc"
    addBookWithChats("/sync/books/s.epub", { "s1" })
    addDocSidecarDir("/sync/books/s.epub")
    mock_files["/sync/books"] = { mode = "directory" }
    mock_dirs["/sync/books"] = { "s.epub" }

    local report = IndexRebuilder.run(nil, {})

    TestRunner:assertEqual(report.candidates.c, 0, "no configured folders, no scan")
    TestRunner:assertNil((g_reader_store[CHAT_KEY] or {})["/sync/books/s.epub"],
        "book not discovered without folder config")
end)

TestRunner:test("batch flush: exactly one settings flush per run", function()
    addBookWithChats("/books/a.epub", { "a1" })
    addDocSidecarDir("/books/a.epub")
    addBookWithChats("/books/b.epub", { "b1" })
    addDocSidecarDir("/books/b.epub")
    mock_read_history.hist = { { file = "/books/a.epub" }, { file = "/books/b.epub" } }

    flush_count = 0
    IndexRebuilder.run(nil, {})
    TestRunner:assertEqual(flush_count, 1, "one flush at end of run, none per book")
end)

TestRunner:test("rebuild prunes dead index entries", function()
    g_reader_store[CHAT_KEY] = {
        ["/books/gone.epub"] = { count = 1, last_modified = 1, chat_ids = { "g1" } },
    }
    IndexRebuilder.run(nil, {})
    TestRunner:assertNil((g_reader_store[CHAT_KEY] or {})["/books/gone.epub"],
        "dead entry pruned at end of rebuild")
end)

-- ============================================================
-- Tests: pruneAllIndexes
-- ============================================================
print("\n  -- pruneAllIndexes --")

TestRunner:test("removes dead paths, keeps live books and special keys", function()
    mock_files["/books/live.epub"] = { mode = "file" }
    mock_files["/books/a_directory"] = { mode = "directory" }
    g_reader_store[CHAT_KEY] = {
        ["/books/live.epub"] = { count = 1 },
        ["/books/gone.epub"] = { count = 1 },
        ["__GENERAL_CHATS__"] = { count = 5 },
    }
    g_reader_store["koassistant_pinned_index"] = {
        ["__LIBRARY_CHATS__"] = { count = 2 },
        ["/books/a_directory"] = { count = 1 },
    }

    local pruned = IndexRebuilder.pruneAllIndexes()

    TestRunner:assertEqual(pruned, 2, "gone.epub + directory entry pruned")
    TestRunner:assertNotNil(g_reader_store[CHAT_KEY]["/books/live.epub"], "live kept")
    TestRunner:assertNotNil(g_reader_store[CHAT_KEY]["__GENERAL_CHATS__"], "special key kept")
    TestRunner:assertNil(g_reader_store[CHAT_KEY]["/books/gone.epub"], "dead pruned")
    TestRunner:assertNotNil(g_reader_store["koassistant_pinned_index"]["__LIBRARY_CHATS__"],
        "pinned special key kept")
    TestRunner:assertNil(g_reader_store["koassistant_pinned_index"]["/books/a_directory"],
        "directory path pruned (~= file)")
end)

-- ============================================================
-- Cleanup: restore overridden modules so subsequent suites work
-- ============================================================
for _idx, name in ipairs(_overridden) do
    package.loaded[name] = _saved[name]
end
logger_mock.warn = _saved_warn
-- Drop plugin modules loaded against our mocks; later suites reload fresh
package.loaded["koassistant_index_rebuilder"] = nil
package.loaded["koassistant_chat_history_manager"] = nil
package.loaded["koassistant_action_cache"] = nil
package.loaded["koassistant_notebook"] = nil
package.loaded["koassistant_pinned_manager"] = nil
package.loaded["koassistant_library_scanner"] = nil
package.loaded["koassistant_doc_settings"] = nil

-- ============================================================
-- Summary
-- ============================================================
print(string.format("\n  Index rebuild tests: %d passed, %d failed",
    TestRunner.passed, TestRunner.failed))

return TestRunner.failed == 0
