-- The small fixes of 2026-11-05 that live in main.lua's patches and timers,
-- checked at the source where no harness drives them, plus the radio rows'
-- on_change through the real settings renderer:
--   B585 a Settings radio row calls its on_change (the X-Ray marking rows redraw)
--   B586 the Domain chip opens Book Settings' Domain & Research screen
--   B604 the configuration.lua notice once per session
--   B605 Compare with KOAssistant runs on the live plugin instance
--   B606 the duplicate-entities ask and the two reopens check the open book
--   B608 thirty highlight-menu slots
--   B612 the HTML text viewer's highlight is cleared too
--
-- Run: lua tests/unit/test_session_guards.lua  (or lua tests/run_tests.lua --unit)

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
local function count(src, needle)
    local _, n = src:gsub(needle:gsub("%p", "%%%0"), "")
    return n
end

print("\nThe session guards and small fixes of 2026-11-05")

TestRunner:test("B585: a radio row's pick calls on_change with the new value, the plugin and the old one", function()
    local ok, SettingsManager = pcall(require, "koassistant.ui.settings_manager")
    if not ok then
        print("    (settings_manager does not load under the mock: " .. tostring(SettingsManager):sub(1, 80) .. ")")
        local src = read("koassistant/ui/settings_manager.lua")
        local radio = src:match('elseif item%.type == "radio" then(.-)elseif item%.type == "dropdown" then')
        TestRunner:assertTrue(radio and radio:find("item.on_change(option.value, plugin, old_value)", 1, true), "the radio branch calls on_change")
        return
    end
    local data = { features = { xray_marking_density = "10" } }
    local synced = 0
    local plugin = {
        settings = { data = data, readSetting = function(_s, k) return data[k] end,
            saveSetting = function(_s, k, v) data[k] = v end, flush = function() end },
        updateConfigFromSettings = function() synced = synced + 1 end,
    }
    local seen = {}
    local item = {
        id = "xray_marking_density", type = "radio", text = "Density", path = "features.xray_marking_density",
        default = "10",
        options = { { value = "10", text = "Ten" }, { value = "25", text = "Twenty-five" } },
        on_change = function(value, p, old) seen = { value = value, plugin = p, old = old } end,
    }
    local row = SettingsManager:createMenuItem(plugin, item, {})
    TestRunner:assertTrue(row and row.sub_item_table and #row.sub_item_table == 2, "two radio rows")
    row.sub_item_table[2].callback()
    TestRunner:assertEqual(data.features.xray_marking_density, "25", "written")
    TestRunner:assertEqual(seen.value, "25", "on_change: the new value")
    TestRunner:assertEqual(seen.old, "10", "on_change: the old value")
    TestRunner:assertEqual(seen.plugin, plugin, "on_change: the plugin")
    TestRunner:assertEqual(synced, 1, "the live config synced")
    TestRunner:assertTrue(row.sub_item_table[2].checked_func(), "ticked")
end)

TestRunner:test("B586: the Domain chip opens the shared Domain & Research screen, global alone without a book", function()
    local src = read("koassistant/ui/dialogs.lua")
    TestRunner:assertTrue(src:find("global_only = doc_settings == nil,", 1, true) ~= nil, "the chip passes global_only without a book")
    TestRunner:assertTrue(src:find("_G.domain_selector_dialog", 1, true) == nil, "the chip's own list is gone")
    TestRunner:assertTrue(src:find("persistBookDomain", 1, true) == nil, "its writer over the follow-group marker is gone")
    local engine = read("koassistant/books/book_settings.lua")
    TestRunner:assertTrue(engine:find("if not opts.global_only then doc_settings = opts.doc_settings or resolveDocSettings(ui, document_path) end", 1, true) ~= nil,
        "the engine honours global_only")
    TestRunner:assertTrue(engine:find("scope = opts.scope, global_only = opts.global_only,", 1, true) ~= nil, "and hands it to its target switch")
end)

TestRunner:test("B604: the configuration.lua notice once per session", function()
    local src = read("main.lua")
    TestRunner:assertTrue(src:find("if config_load_error and not AskGPT._config_error_warned then", 1, true) ~= nil, "guarded on the class")
    TestRunner:assertTrue(src:find("AskGPT._config_error_warned = true", 1, true) ~= nil, "and marked")
end)

TestRunner:test("B605: the multi-select Compare runs on the live instance", function()
    local src = read("main.lua")
    TestRunner:assertTrue(src:find("liveInstance(self):compareSelectedBooks(files_copy)", 1, true) ~= nil, "the patch's callback resolves the live instance")
    local def = src:find("local function liveInstance(fallback)", 1, true)
    local use = src:find("liveInstance(self):compareSelectedBooks", 1, true)
    TestRunner:assertTrue(def and use and def < use, "defined before its use (local function ordering)")
end)

TestRunner:test("B606: every install schedules the ask through _scheduleDedupAsk; the reopens check the open book", function()
    local src = read("main.lua")
    TestRunner:assertEqual(count(src, "UIManager:scheduleIn(1, function() self_ref:maybeOfferDedupAsk(file) end)"), 0, "no bare schedule left")
    TestRunner:assertEqual(count(src, "self_ref:_scheduleDedupAsk(file)"), 7, "the seven install sites")
    TestRunner:assertTrue(src:find("function AskGPT:maybeOfferDedupAsk(file, opts)", 1, true) ~= nil)
    TestRunner:assertTrue(src:find("if opts and opts.was_open and not (self.ui and self.ui.document and self.ui.document.file == file) then", 1, true) ~= nil,
        "an ask for a book that was open and closed since is dropped")
    TestRunner:assertTrue(src:find("if not (self.ui and self.ui.document and self.ui.document.file == book_file) then return end", 1, true) ~= nil, "the X-Ray reopen")
    TestRunner:assertTrue(src:find("if not (self.ui and self.ui.document and self.ui.document.file == bp_file) then return end", 1, true) ~= nil, "the Book Hub reopen")
end)

TestRunner:test("B608: thirty highlight-menu slots", function()
    local src = read("main.lua")
    TestRunner:assertTrue(src:find("local MAX_SLOTS = 30", 1, true) ~= nil)
end)

TestRunner:test("B612: the HTML text viewer's widget clears its highlight too", function()
    local src = read("main.lua")
    TestRunner:assertTrue(src:find("local tw = sw and (sw.text_widget or sw.htmlbox_widget)", 1, true) ~= nil)
    local bundle = "/Applications/KOReader.app/Contents/koreader/frontend/ui/widget/"
    local h = io.open(bundle .. "htmlboxwidget.lua", "r")
    if not h then
        print("    (no KOReader bundle: the widget's methods are not checked)")
        return
    end
    local w = h:read("*a")
    h:close()
    TestRunner:assertTrue(w:find("function HtmlBoxWidget:clearHighlight", 1, true) ~= nil, "clearHighlight")
    TestRunner:assertTrue(w:find("function HtmlBoxWidget:redrawHighlight", 1, true) ~= nil, "redrawHighlight")
    local sh = assert(io.open(bundle .. "scrollhtmlwidget.lua", "r")):read("*a")
    TestRunner:assertTrue(sh:find("htmlbox_widget = HtmlBoxWidget:new", 1, true) ~= nil, "the field name")
end)

print(string.format("\n=== Results: %d passed, %d failed ===", TestRunner.passed, TestRunner.failed))
return TestRunner.failed == 0
