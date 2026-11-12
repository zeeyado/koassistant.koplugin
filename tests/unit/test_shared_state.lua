-- Run state on the plugin's shared configuration: what one entry point
-- leaves there must not change what the next one does, and a run about a
-- book must act on that book. The class of defect behind most "opening X
-- broke Y" reports (the shared-state map of 2026-11-12: the module-level
-- configuration table holds the settings AND every run's state, for both
-- plugin instances and every entry point).
--
-- Each test is a cell of that map's matrix, "do A, then B": the state A
-- leaves is built on a table, and B's own code, cut from the source or
-- called for real, runs on it. The four cells here failed on the code of
-- 2026-11-12 before their fixes:
--   Continue from Chat History, then an artifact window: the window's
--     selection tools acted on the continued chat's book
--   a Send with a Scope pick past the position, then another chat: the
--     consent stayed on the shared table and stood the spoiler line down
--   a dialog's action, then a file-browser action on another book: the last
--     chat's Spoiler chip value decided that book's protection
--   an X-Ray entry's chat or wiki beside another open book: the request read
--     the open book's settings
-- A fix of this class gets its cell here.
--
-- Run: lua tests/unit/test_shared_state.lua  (or lua tests/run_tests.lua --unit)

local function setupPaths()
    local info = debug.getinfo(1, "S")
    local script_path = info.source:match("@?(.*)")
    local unit_dir = script_path:match("(.+)/[^/]+$") or "."
    local tests_dir = unit_dir:match("(.+)/[^/]+$") or "."
    local plugin_dir = tests_dir:match("(.+)/[^/]+$") or "."
    package.path = table.concat({
        plugin_dir .. "/?.lua", tests_dir .. "/?.lua", tests_dir .. "/lib/?.lua", package.path,
    }, ";")
    return plugin_dir
end
local PLUGIN_DIR = setupPaths()
require("mock_koreader")

local TestRunner = { passed = 0, failed = 0 }
function TestRunner:test(name, fn)
    local ok, err = pcall(fn)
    if ok then
        self.passed = self.passed + 1
        print(string.format("  \226\156\147 %s", name))
    else
        self.failed = self.failed + 1
        print(string.format("  \226\156\151 %s: %s", name, tostring(err)))
    end
end
function TestRunner:assertEqual(actual, expected, msg)
    if actual ~= expected then
        error(string.format("%s: expected %s, got %s", msg or "eq", tostring(expected), tostring(actual)), 2)
    end
end
function TestRunner:assertTrue(v, msg) if not v then error((msg or "expected true"), 2) end end

local function read(rel)
    local h = assert(io.open(PLUGIN_DIR .. "/" .. rel, "r"))
    local s = h:read("*a")
    h:close()
    return s
end
local loadChunk = loadstring or load
-- A chunk run in an environment of its own (Lua 5.1 and later)
local function chunkIn(src, name, env)
    local chunk = assert(loadChunk(src, name, "t", env))
    if setfenv then setfenv(chunk, env) end
    return chunk
end
-- A method of main.lua as source text, from its first line to its closing end
local function methodSource(main, name)
    local a = main:find("\nfunction AskGPT:" .. name .. "(", 1, true)
    TestRunner:assertTrue(a ~= nil, name .. " exists in main.lua")
    local b = main:find("\nend\n", a, true)
    return main:sub(a + 1, b + 4)
end

local OPEN_BOOK = "/books/Open.epub"
local OTHER_BOOK = "/books/Other.epub"

print("\nRun state on the shared configuration: do A, then B")

-- ── Continue a chat, then open an artifact window ───────────────────────────
-- The chat history module, loaded for one call: the frontend widgets the mock
-- lacks load as inert stubs, and everything this load put in package.loaded
-- (the stubs, the module built on them) is taken out again, since the suite
-- runs every file in one process.
local function withChatHistoryDialog(fn)
    local searchers = package.searchers or package.loaders -- luacheck: ignore
    local served = {}
    local function inert(name)
        if not (name:match("^ui/") or name:match("^apps/") or name:match("^frontend/") or name == "dispatcher") then return nil end
        return function()
            served[#served + 1] = name
            local stub
            stub = setmetatable({}, {
                __index = function() return function() return stub end end,
                __call = function() return stub end,
            })
            return stub
        end
    end
    local module_name = "koassistant.chat.chat_history_dialog"
    local had = package.loaded[module_name]
    package.loaded[module_name] = nil
    table.insert(searchers, inert)
    local ok_load, CHD = pcall(require, module_name)
    local ok_run, err = true, nil
    if ok_load then ok_run, err = pcall(fn, CHD) end
    for i = #searchers, 1, -1 do
        if searchers[i] == inert then table.remove(searchers, i) end
    end
    for _i, name in ipairs(served) do package.loaded[name] = nil end
    package.loaded[module_name] = had
    TestRunner:assertTrue(ok_load, "the chat history module loads: " .. tostring(CHD))
    TestRunner:assertTrue(ok_run, tostring(err))
end

TestRunner:test("Continue from Chat History leaves no book on the table it is handed", function()
    local shared = { provider = "anthropic", features = {} }
    local manager = { getChatById = function() return nil end, setLastOpenedChat = function() end }
    withChatHistoryDialog(function(CHD)
        -- runs as far as the mock lets it: the write this guards came before the window
        pcall(CHD.continueChat, CHD, nil, OTHER_BOOK, { id = "c1", messages = {} }, manager, shared)
    end)
    TestRunner:assertEqual(shared.document_path, nil, "the passed (shared) table names no book")
    local src = read("koassistant/chat/chat_history_dialog.lua")
    local a = src:find("\nfunction ChatHistoryDialog:continueChat(", 1, true)
    local b = src:find("\nend\n", a, true)
    local body = src:sub(a, b)
    local copy_at = body:find("        config = {}\n", 1, true)
    local write_at = body:find("config.document_path = document_path", 1, true)
    TestRunner:assertTrue(copy_at ~= nil and write_at ~= nil and write_at > copy_at,
        "the chat's book is written after the private copy is made, so on the copy")
    local _s, writes = body:gsub("config%.document_path = document_path", "")
    TestRunner:assertEqual(writes, 1, "and nowhere else")
end)

TestRunner:test("an artifact window names its own book, whatever the shared configuration names", function()
    local ChatGPTViewer = require("koassistant.ui.chatgptviewer")
    -- what an older Continue, or any other writer, may have left
    local shared = { provider = "anthropic", document_path = OTHER_BOOK, features = { a_setting = 7 } }
    local own = ChatGPTViewer.ownBookConfiguration(shared, true, OPEN_BOOK)
    TestRunner:assertTrue(own ~= shared, "the window takes a copy")
    TestRunner:assertEqual(own.document_path, OPEN_BOOK, "that names the window's book")
    TestRunner:assertEqual(shared.document_path, OTHER_BOOK, "the shared table is not written")
    TestRunner:assertTrue(own.features == shared.features, "settings are still read live (features is the same table)")
    TestRunner:assertTrue(ChatGPTViewer.ownBookConfiguration(shared, false, OPEN_BOOK) == shared, "a chat window keeps its configuration")
    TestRunner:assertTrue(ChatGPTViewer.ownBookConfiguration(shared, true, nil) == shared, "a window without a book of its own too")
    local same = { document_path = OPEN_BOOK, features = {} }
    TestRunner:assertTrue(ChatGPTViewer.ownBookConfiguration(same, true, OPEN_BOOK) == same, "no copy when the book already matches")
    -- the window's selection tools read the configuration: Add to Notebook
    local viewer = setmetatable({ configuration = own, simple_view = true, _artifact_file = OPEN_BOOK },
        { __index = ChatGPTViewer })
    local appended
    local saved = ChatGPTViewer.appendSnippetToNotebook
    ChatGPTViewer.appendSnippetToNotebook = function(path) appended = path end
    local ok, err = pcall(ChatGPTViewer.appendSelectionToNotebook, viewer, "a line")
    ChatGPTViewer.appendSnippetToNotebook = saved
    TestRunner:assertTrue(ok, tostring(err))
    TestRunner:assertEqual(appended, OPEN_BOOK, "Add to Notebook writes into the window's own book's notebook")
    -- and the window is built that way
    local src = read("koassistant/ui/chatgptviewer.lua")
    local a = src:find("\nfunction ChatGPTViewer:init()", 1, true)
    TestRunner:assertTrue(src:find("self.configuration = ChatGPTViewer.ownBookConfiguration(self.configuration, self.simple_view, self._artifact_file)",
        a, true) ~= nil, "init takes the copy before anything reads the configuration")
end)

-- ── A Send whose Scope pick went past the position, then another chat ───────
TestRunner:test("the Send's consent to read past the position rides its own copy and leaves the shared table", function()
    local dialogs = read("koassistant/ui/dialogs.lua")
    local a = dialogs:find("                    do\n                        -- ALWAYS rebind `configuration` to a private per-Send copy", 1, true)
    local b = a and dialogs:find("                    -- Set spoiler-free flag for system prompt injection", a, true)
    TestRunner:assertTrue(a ~= nil and b ~= nil, "the Send's copy block is where it was")
    local send_copy = assert(loadChunk("return function(configuration, history, send_rv)\n"
        .. dialogs:sub(a, b - 1) .. "\nreturn configuration\nend", "send_copy"))()
    -- the Send wrote the consent on the dialog's configuration (the shared
    -- table for the dialogs main.lua opens with it) just before this block
    local shared = { provider = "anthropic", features = { spoiler_free_chat = true, _spoiler_scope_consent = true } }
    local copy = send_copy(shared, { conversation_id = "c1" }, nil)
    TestRunner:assertTrue(copy ~= shared and copy.features ~= shared.features, "the Send runs on a copy")
    TestRunner:assertEqual(copy.features._spoiler_scope_consent, true, "which carries the consent to its own request")
    TestRunner:assertEqual(shared.features._spoiler_scope_consent, nil, "the shared table no longer holds it for the next chat")
    -- what a leftover did: the next protected send got no spoiler line
    local BTR = require("koassistant.tools.book_tool_runner")
    local function cfg(extra)
        local f = { _spoiler_live = true, spoiler_free_chat = true, enable_basic_stats = true }
        for k, v in pairs(extra or {}) do f[k] = v end
        return { provider = "anthropic", features = f }
    end
    local ok1, line = pcall(BTR._liveSpoilerLine, cfg(), nil)
    TestRunner:assertTrue(ok1 and type(line) == "string" and #line > 0, "a protected chat's send carries the line")
    local ok2, none = pcall(BTR._liveSpoilerLine, cfg({ _spoiler_scope_consent = true }), nil)
    TestRunner:assertTrue(ok2 and none == nil, "and a consent stands it down (the reason a leftover matters)")
end)

-- ── A dialog's action, then a file-browser action on another book ───────────
TestRunner:test("a file-browser action runs on a scrubbed copy about its own book", function()
    local main = read("main.lua")
    -- what the last dialog left: its Spoiler chip value (off, on a finished
    -- book), a consent, a dictionary context, a run allowance
    local shared = { provider = "anthropic", features = {
        spoiler_free_chat = true,
        _spoiler_free_active = false,
        _spoiler_scope_consent = true,
        dictionary_context = "the sentence around a word looked up earlier",
        _data_once = { book = OPEN_BOOK, kinds = { book_text = true } },
        is_library_context = true,
    } }
    local AskGPT, got = {}, nil
    local env = setmetatable({
        configuration = shared,
        buildBookMetadata = function(t, a, f) return { title = t, author = a, file = f } end,
        bookContextString = function(bm) return bm.title end,
        getRawDocProps = function() return nil end,
        -- the network comes up later: another entry has rewritten the shared
        -- table's book in between
        NetworkMgr = { runWhenConnected = function(_s, f)
            shared.features.book_metadata = { title = "Third", file = "/books/Third.epub" }
            shared.features.book_context = "Third"
            f()
        end },
        Dialogs = { executeDirectAction = function(_ui, _action, _text, config) got = config end },
        Notification = { new = function() return {} end },
        UIManager = { show = function() end },
    }, { __index = _G })
    for _i, name in ipairs({ "_scrubContextFeatures", "_asBookRunFor", "executeFileBrowserAction" }) do
        chunkIn("local AskGPT = ...\n" .. methodSource(main, name), name, env)(AskGPT)
    end
    local plugin = setmetatable({
        ui = nil,
        ensureInitialized = function() end, updateConfigFromSettings = function() end,
        _checkRequirements = function() return false end,
        action_service = { getAction = function(_s, _ctx, id) return { id = id, context = "book" } end },
    }, { __index = AskGPT })
    plugin:executeFileBrowserAction(OTHER_BOOK, "Other", "Someone", {}, "book_info")
    TestRunner:assertTrue(got ~= nil and got ~= shared and got.features ~= shared.features, "the run is on a copy")
    TestRunner:assertEqual(got.features._spoiler_free_active, nil, "without the last chat's Spoiler chip value")
    TestRunner:assertEqual(got.features._spoiler_scope_consent, nil, "without its consent to read past the position")
    TestRunner:assertEqual(got.features.dictionary_context, nil, "without its dictionary context")
    TestRunner:assertEqual(got.features._data_once, nil, "without its run allowance")
    TestRunner:assertEqual(got.features.is_library_context, nil, "without a library mark")
    TestRunner:assertEqual(got.features.is_book_context, true, "a book run")
    TestRunner:assertEqual(got.features.book_metadata.file, OTHER_BOOK,
        "about the row's own book, even when the shared table was rewritten while the network came up")
    TestRunner:assertEqual(got.features.spoiler_free_chat, true, "settings ride the copy")
    -- the book's own protection decides again
    local BookSettings = require("koassistant.books.book_settings")
    local protected_book = { readSetting = function(_s, k) if k == BookSettings.KEY_SPOILER_FREE then return true end end }
    local posture = BookSettings.resolveSpoilerPosture(protected_book, got.features, { session = got.features._spoiler_free_active })
    TestRunner:assertEqual(posture.protected, true, "a protected book runs protected")
    -- the closed book's Regenerate makes the same kind of copy
    local _s, uses = main:gsub("_asBookRunFor%(config_copy%.features, own_metadata, ", "")
    TestRunner:assertEqual(uses, 2, "both closed-book copies (the file-browser action, Regenerate) go through _asBookRunFor")
end)

-- ── An X-Ray entry's chat or wiki beside another open book ──────────────────
TestRunner:test("an X-Ray entry's chat or wiki reads the entry's book's settings, not the open book's", function()
    local dialogs = read("koassistant/ui/dialogs.lua")
    local a = dialogs:find("\n    local per_book_file\n", 1, true)
    local b = a and dialogs:find("\n    local per_book_ds = nil", a, true)
    TestRunner:assertTrue(a ~= nil and b ~= nil, "the request's per-book block is where it was")
    local perBookFile = assert(loadChunk("return function(context, ui, config)\n" .. dialogs:sub(a, b)
        .. "\nreturn per_book_file\nend", "per_book_file"))()
    local ui = { document = { file = OPEN_BOOK } }
    local entry_chat = { features = { book_metadata = { file = OTHER_BOOK }, _xray_entry_book = OTHER_BOOK } }
    TestRunner:assertEqual(perBookFile("highlight", ui, entry_chat), OTHER_BOOK,
        "a chat about another book's X-Ray entry takes that book")
    TestRunner:assertEqual(perBookFile("highlight", nil, entry_chat), OTHER_BOOK, "with no book open too")
    -- a real highlight is the open book's, whatever identity an earlier entry left
    local highlight = { features = { book_metadata = { file = OTHER_BOOK } } }
    TestRunner:assertEqual(perBookFile("highlight", ui, highlight), OPEN_BOOK, "a highlight in the open book stays the open book's")
    TestRunner:assertEqual(perBookFile("general", ui, highlight), nil, "a general request has no book")
    TestRunner:assertEqual(perBookFile("book", ui, highlight), OTHER_BOOK, "a book request takes its named book")
    -- both entries name the entry's book on their own copies, and the scrub knows the key
    local browser = read("koassistant/xray/xray_browser.lua")
    TestRunner:assertTrue(browser:find("config.features._xray_entry_book = self.metadata.book_file or nil", 1, true) ~= nil,
        "the entry's chat names its book")
    TestRunner:assertTrue(browser:find("config.features._xray_entry_book = file", 1, true) ~= nil, "the AI Wiki run too")
    local main = read("main.lua")
    local AskGPT = {}
    assert(loadChunk("local AskGPT = ...\n" .. methodSource(main, "_scrubContextFeatures"), "scrub"))(AskGPT)
    local features = { _xray_entry_book = OTHER_BOOK }
    AskGPT:_scrubContextFeatures(features)
    TestRunner:assertEqual(features._xray_entry_book, nil, "an entry that scrubs drops the key")
end)

print(string.format("\n=== Results: %d passed, %d failed ===", TestRunner.passed, TestRunner.failed))
return TestRunner.failed == 0
