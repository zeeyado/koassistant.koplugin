-- B396: data that went out against the reader's settings because its consent
-- was judged for one provider while the request went to another (a run option,
-- a ⚡ pick, an action's own pin) or never judged at all. Each test runs the
-- real hand-off where the code allows, or cuts the send site's own expression
-- from the source and evaluates it, so a guard can never pass while the check
-- never runs (the test_front_matter_flow lesson).
--   (a) "Chat about this notebook" checks notebook sharing for the chat's provider
--   (b) a reply in a resumed chat checks its notebook for the reply's provider
--   (c) the library Send judges the book list for the Send's provider
--   (d) an X-Ray chat's "Your highlights" block is judged for each send's provider
--   (e) is the raw doc-settings gate in test_book_store.lua
--
-- Run: lua tests/unit/test_send_consent.lua  (or lua tests/run_tests.lua --unit)

local function setupPaths()
    local info = debug.getinfo(1, "S")
    local script_path = info.source:match("@?(.*)")
    local unit_dir = script_path:match("(.+)/[^/]+$") or "."
    local tests_dir = unit_dir:match("(.+)/[^/]+$") or "."
    local plugin_dir = tests_dir:match("(.+)/[^/]+$") or "."
    package.path = table.concat({
        plugin_dir .. "/?.lua",
        plugin_dir .. "/koassistant_api/?.lua",
        tests_dir .. "/?.lua",
        tests_dir .. "/lib/?.lua",
        package.path,
    }, ";")
    return plugin_dir
end
local plugin_dir = setupPaths()
require("mock_koreader")
local Dialogs = require("koassistant_dialogs")
local A = require("koassistant_attachments")
local TestRunner = require("test_runner"):new()

local function source(rel)
    local f = assert(io.open(plugin_dir .. "/" .. rel, "r"))
    local s = f:read("*a")
    f:close()
    return s
end
local dialogs_src = source("koassistant_dialogs.lua")
local history_src = source("koassistant_chat_history_dialog.lua")
local browser_src = source("koassistant_xray_browser.lua")

-- Stubs this file installs, restored at the end (one Lua process runs every file).
-- Taken from launchArtifactChat's own upvalues: earlier files in the suite swap
-- package.loaded entries, so a fresh require can return another table than the
-- one the dialogs module holds.
local function upvalue(fn, name)
    local i = 1
    while true do
        local n, v = debug.getupvalue(fn, i)
        if not n then return nil end
        if n == name then return v end
        i = i + 1
    end
end
local UIManager = upvalue(Dialogs.launchArtifactChat, "UIManager") or require("ui/uimanager")
local BTR = upvalue(Dialogs.launchArtifactChat, "BookToolRunner") or require("koassistant_book_tool_runner")
local SDS = upvalue(Dialogs.launchArtifactChat, "SafeDocSettings") or require("koassistant_doc_settings")
local saved = {
    show = UIManager.show, queryWith = BTR.queryWith, resolve = SDS.resolve,
    override = A.notebookOverrideFor, getList = A.getList,
    showChatGPTDialog = Dialogs.showChatGPTDialog,
}
local shown, sent = {}, 0
UIManager.show = function(_self, w) shown[#shown + 1] = w end
BTR.queryWith = function() sent = sent + 1 end
SDS.resolve = function() return nil end
local override
A.notebookOverrideFor = function() return override end

local function trusted(over)
    local f = { trusted_providers = { "ollama" }, enable_notebook_sharing = false,
        enable_highlights_sharing = false, enable_annotations_sharing = false }
    for k, v in pairs(over or {}) do f[k] = v end
    return f
end

-- ------------------------------------------------------------------- (a)

print("\n  [(a) Chat about this notebook]")

local function notebookChat(features, provider, opts)
    sent, shown = 0, {}
    local cfg = { provider = provider, model = "m", provider_settings = {}, features = features }
    Dialogs.launchArtifactChat("What do I note most?", "my notes", "Notebook", nil, cfg, nil,
        { file = "/books/b.epub", title = "B" }, opts)
    return sent, shown
end

TestRunner:test("a notebook chat goes to a trusted provider with sharing off", function()
    override = nil
    local n = notebookChat(trusted(), "ollama", { notebook = true })
    TestRunner:assertEqual(n, 1, "sent")
end)

TestRunner:test("a run option to an untrusted provider is refused, with a message", function()
    override = nil
    local n, msgs = notebookChat(trusted({ _run_variant = { provider = "openai", model = "gpt-5.5" } }),
        "ollama", { notebook = true })
    TestRunner:assertEqual(n, 0, "not sent")
    TestRunner:assertEqual(#msgs, 1, "one message")
    TestRunner:assertTrue((msgs[1].text or ""):find("Notebook sharing", 1, true), "names the setting")
end)

TestRunner:test("the book's deny beats a trusted provider; its allow passes an untrusted one", function()
    override = false
    TestRunner:assertEqual((notebookChat(trusted(), "ollama", { notebook = true })), 0, "deny")
    override = true
    TestRunner:assertEqual((notebookChat(trusted(), "openai", { notebook = true })), 1, "allow")
    override = nil
end)

TestRunner:test("the notebook viewer marks its chat, and the launcher passes the mark on", function()
    local main_src = source("main.lua")
    local viewer = main_src:match("function AskGPT:openNotebookInChatViewer%(.-\nend\n")
    TestRunner:assertTrue(viewer and viewer:find(
        '_buildLaunchChatCallback(document_path, book_title, book_author, content, _("Notebook"),\n      { notebook = true })', 1, true),
        "the viewer asks for the notebook check")
    local params_body = main_src:match("\nfunction AskGPT:_buildLaunchChatCallback%((.-)\nend\n")
    TestRunner:assertTrue(params_body, "the launcher")
    local build = assert(load("local configuration, Dialogs, _ = ...\nreturn function(self, " .. params_body .. "\nend",
        "_buildLaunchChatCallback"))
    local got
    local StubDialogs = { launchArtifactChat = function(...) got = { ... } end }
    local make = build({ provider = "ollama", features = {} }, StubDialogs, function(x) return x end)
    local cb = make({ updateConfigFromSettings = function() end, ui = nil },
        "/books/b.epub", "B", "", "my notes", "Notebook", { notebook = true })
    cb("What do I note most?", nil)
    TestRunner:assertTrue(got and got[8] and got[8].notebook == true, "launchArtifactChat receives the mark")
end)

TestRunner:test("sharing on sends anywhere; other artifacts are untouched", function()
    TestRunner:assertEqual((notebookChat(trusted({ enable_notebook_sharing = true }), "openai",
        { notebook = true })), 1, "sharing on")
    TestRunner:assertEqual((notebookChat(trusted(), "openai", nil)), 1, "an X-Ray or a pin")
end)

-- ------------------------------------------------------------------- (b)

print("\n  [(b) a reply in a resumed chat]")

TestRunner:test("every attachment message passes the send-time check", function()
    local offenders = {}
    for _idx, rel in ipairs({ "koassistant_dialogs.lua", "koassistant_chat_history_dialog.lua",
            "koassistant_chatgptviewer.lua", "main.lua", "koassistant_attachments.lua" }) do
        local n = 0
        for line in source(rel):gmatch("[^\n]*") do
            n = n + 1
            if line:find("buildMessage(", 1, true) and not line:find("^function ")
                    and not line:find("forProvider(", 1, true) then
                offenders[#offenders + 1] = rel .. ":" .. n
            end
        end
    end
    TestRunner:assertEqual(table.concat(offenders, ", "), "", "buildMessage without forProvider")
end)

TestRunner:test("the resumed reply judges the notebook for the provider its overrides chose", function()
    local body = history_src:match("onAskQuestion = function%(self_viewer, question%)(.-)\n%s*save_callback = ")
    TestRunner:assertTrue(body, "the resumed chat's reply callback")
    local p_over = body:find("applyQuickReplyOverrides(config", 1, true)
    local call = body:match("local attach_msg = A%.buildMessage%((A%.forProvider%(A%.getList%(%),.-, ui%))%)")
    TestRunner:assertTrue(p_over and call, "both the overrides and the check")
    TestRunner:assertTrue(p_over < body:find(call, 1, true), "the check runs after the overrides")
    local check = assert(load("local A, config, ui = ...; return " .. call, "resumed reply"))
    local list = { { type = "notebook", path = "/books/b.epub" }, { type = "note", text = "x" } }
    A.getList = function() return list end
    override = nil
    local cfg = { provider = "ollama", model = "m", provider_settings = {}, api_params = {},
        features = trusted() }
    TestRunner:assertEqual(#check(A, cfg, nil), 2, "the chat's own trusted provider keeps it")
    cfg.features._session_model = { provider = "openai", model = "gpt-5.5" }
    Dialogs.applyQuickReplyOverrides(cfg, nil)
    TestRunner:assertEqual(cfg.provider, "openai", "the reply goes elsewhere")
    local out = check(A, cfg, nil)
    TestRunner:assertEqual(#out, 1, "the notebook is left out")
    TestRunner:assertEqual(out[1].type, "note", "the rest rides")
    A.getList = saved.getList
end)

-- ------------------------------------------------------------------- (c)

print("\n  [(c) the library Send]")

TestRunner:test("the book list is judged for the provider the Send goes to", function()
    local cond = dialogs_src:match(
        "local scan_folders_to_use\n%s*if (lib_features%.enable_library_scanning.-) then\n%s*scan_folders_to_use = ")
    TestRunner:assertTrue(cond, "the catalog condition")
    local allowed = assert(load("local lib_features, send_rv, configuration = ...; return " .. cond,
        "library catalog"))
    local lib = { enable_library_scanning = false, trusted_providers = { "ollama" } }
    local function cfg(provider, f) return { provider = provider, features = f or {} } end
    TestRunner:assertTrue(allowed(lib, nil, cfg("ollama")), "trusted provider, no re-point")
    TestRunner:assertFalse(allowed(lib, { provider = "openai", model = "gpt-5.5" }, cfg("ollama")),
        "Send's long-press to an untrusted provider")
    TestRunner:assertFalse(allowed(lib, nil, cfg("ollama",
        { _session_model = { provider = "openai", model = "gpt-5.5" } })), "a ⚡ pick")
    TestRunner:assertTrue(allowed(lib, { provider = "ollama" }, cfg("openai")), "re-pointed to trusted")
    TestRunner:assertTrue(allowed({ enable_library_scanning = true }, { provider = "openai" },
        cfg("openai")), "scanning on")
    TestRunner:assertFalse(cond:find("library_toggle_on", 1, true), "no judgment from the dialog's opening")
    local block = dialogs_src:match("Auto%-attach library scan data(.-)if scan_folders_to_use and #scan_folders_to_use")
    TestRunner:assertTrue(block:find("elseif library_toggle_on then", 1, true)
        and block:find("Your book list was left out", 1, true),
        "a list the dialog offered and this Send drops is named, never dropped silently")
end)

-- ------------------------------------------------------------------- (d)

print("\n  [(d) X-Ray chat highlights]")

TestRunner:test("the highlights rule: the book's override, then sharing, then trust", function()
    local f = trusted()
    TestRunner:assertTrue(A.highlightsAllowed(f, "ollama", nil), "trusted")
    TestRunner:assertFalse(A.highlightsAllowed(f, "openai", nil), "untrusted, sharing off")
    TestRunner:assertTrue(A.highlightsAllowed(trusted({ enable_annotations_sharing = true }), "openai", nil),
        "annotations sharing covers highlights")
    TestRunner:assertFalse(A.highlightsAllowed(f, "ollama", false), "deny beats trust")
    TestRunner:assertTrue(A.highlightsAllowed(f, "openai", true), "the book's allow")
end)

local ENTRY = "Anna: a teacher in the village."
local BLOCK = "\n\n" .. "Your highlights:" .. "\n" .. "\n> Anna smiled." .. "\n> Anna left."
local FULL = ENTRY .. BLOCK

TestRunner:test("the block is cut for a provider that may not have it, nothing else changes", function()
    local f = trusted({ _xray_chat_highlights = { block = BLOCK } })
    TestRunner:assertEqual(A.xrayChatTextFor(FULL, f, "ollama"), FULL, "byte-identical when allowed")
    TestRunner:assertEqual(A.xrayChatTextFor(FULL, f, "openai"), ENTRY, "cut")
    TestRunner:assertEqual(A.xrayChatTextFor(ENTRY, f, "openai"), ENTRY, "no block, no change")
    TestRunner:assertEqual(A.xrayChatTextFor(FULL, trusted(), "openai"), FULL, "no record, no change")
    f._xray_chat_highlights.override = true
    TestRunner:assertEqual(A.xrayChatTextFor(FULL, f, "openai"), FULL, "the book's allow")
end)

-- The browser's side: "Chat about this" hands the record to the chat's config
local stubbed = {}
for _idx, name in ipairs({ "ui/event", "ui/widget/menu", "ui/widget/textviewer" }) do
    if not package.loaded[name] then
        stubbed[#stubbed + 1] = name
        local C = {}
        function C:new(o) return setmetatable(o or {}, { __index = self }) end
        function C:extend(o) return setmetatable(o or {}, { __index = self }) end
        package.loaded[name] = C
    end
end
local had_browser = package.loaded["koassistant_xray_browser"]
local XrayBrowser = require("koassistant_xray_browser")

local function chatAbout(features, entity)
    local captured
    Dialogs.showChatGPTDialog = function(_ui, text, config) captured = { text = text, config = config } end
    XrayBrowser.chatAboutItem({
        metadata = { configuration = { provider = "ollama", features = features }, title = "B" },
    }, FULL, entity)
    Dialogs.showChatGPTDialog = saved.showChatGPTDialog
    return captured
end

TestRunner:test("Chat about this hands the block to the chat, and the page builds it as appended", function()
    TestRunner:assertTrue(browser_src:find("chat_text = chat_text .. hl_record.block", 1, true),
        "the page appends exactly the recorded block")
    TestRunner:assertTrue(browser_src:find("highlights = hl_record,", 1, true), "and passes it on")
    local rec = { block = BLOCK }
    local got = chatAbout(trusted(), { name = "Anna", category = "people", highlights = rec })
    TestRunner:assertEqual(got.text, FULL, "the chat's text is unchanged")
    TestRunner:assertEqual(got.config.features._xray_chat_highlights, rec, "the record rides the chat")
    TestRunner:assertEqual(A.xrayChatTextFor(got.text, got.config.features, "openai"), ENTRY,
        "and an untrusted send drops the block")
    local stale = chatAbout(trusted({ _xray_chat_highlights = rec }), { name = "Bo", category = "people" })
    TestRunner:assertEqual(stale.config.features._xray_chat_highlights, nil, "a fresh chat never names a stale block")
end)

TestRunner:test("the freeform Send judges the block for its own provider", function()
    local expr = dialogs_src:match(
        "if xray_context_prefix then\n%s*sel_text = (require%(\"koassistant_attachments\"%)%.xrayChatTextFor%(.-%))\n%s*end\n%s*table%.insert%(parts, '\"' %.%. sel_text")
    TestRunner:assertTrue(expr, "the Send's selected-text expression")
    local text_for = assert(load("local highlighted_text, configuration, send_rv = ...; return " .. expr,
        "freeform Send"))
    local function cfg(f) return { provider = "ollama", features = f } end
    local rec = { block = BLOCK }
    TestRunner:assertEqual(text_for(FULL, cfg(trusted({ _xray_chat_highlights = rec })), nil), FULL,
        "the chat's trusted provider")
    TestRunner:assertEqual(text_for(FULL, cfg(trusted({ _xray_chat_highlights = rec })),
        { provider = "openai", model = "gpt-5.5" }), ENTRY, "Send's long-press elsewhere")
    TestRunner:assertEqual(text_for(FULL, cfg(trusted({ _xray_chat_highlights = rec,
        _session_model = { provider = "openai", model = "gpt-5.5" } })), nil), ENTRY, "a ⚡ pick")
end)

TestRunner:test("an action from the X-Ray chat judges the block for the action's provider", function()
    local p_eff = dialogs_src:find("local effective_provider = effectiveDispatchProvider(", 1, true)
    local p_cut = dialogs_src:find("if xray_prefix then\n        message_data.highlighted_text = require(\"koassistant_attachments\").xrayChatTextFor(\n            message_data.highlighted_text, config.features, effective_provider)", 1, true)
    local p_build = dialogs_src:find("buildConsolidatedMessage(prompt, context, message_data", 1, true)
    TestRunner:assertTrue(p_eff and p_cut and p_build, "all three")
    TestRunner:assertTrue(p_eff < p_cut and p_cut < p_build, "after the dispatch provider, before the message")
end)

-- ------------------------------------------------------------------- cleanup

UIManager.show = saved.show
BTR.queryWith = saved.queryWith
SDS.resolve = saved.resolve
A.notebookOverrideFor = saved.override
A.getList = saved.getList
Dialogs.showChatGPTDialog = saved.showChatGPTDialog
package.loaded["koassistant_xray_browser"] = had_browser
for _idx, name in ipairs(stubbed) do package.loaded[name] = nil end

return TestRunner:summary()
