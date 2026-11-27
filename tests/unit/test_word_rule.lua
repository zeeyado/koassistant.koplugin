-- What counts as a word, and the door to KOReader's own dictionary.
--
-- KOReader has no count for "a word": a word held in place is looked up,
-- anything dragged is a selection, one word included. The plugin had one rule
-- for a selection inside its own windows (one word = the dictionary). The
-- reader can now raise that number (Highlight Settings, Short Selections as a
-- Word), and ONE rule (ChatGPTViewer.countsAsWord) decides everywhere: a
-- selection in the book (main.lua's wrapper of KOReader's highlight menu,
-- cut from the source and run here), a selection inside a window, and whether
-- an answer's menus offer KOReader's dictionary.
--
-- The door: with the dictionary bypass on, nothing in KOAssistant's own
-- dictionary answers led back to the dictionaries the reader installed.
-- ChatGPTViewer.lookupNative opens KOReader's window whatever the bypass and
-- the X-Ray intercept say, through the mark the bypass's wrapper already
-- honours for KOReader's own Dictionary row.
--
-- Run: lua tests/unit/test_word_rule.lua  (or lua tests/run_tests.lua --unit)

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
local TestRunner = require("test_runner"):new()

print("")
print(string.rep("=", 50))
print("  What counts as a word; KOReader's own dictionary")
print(string.rep("=", 50))

local Viewer = require("koassistant.ui.chatgptviewer")
local UIManager = require("ui/uimanager")
local InfoMessage = require("ui/widget/infomessage")
local logger = require("koassistant.core.logger")
local _ = require("koassistant.core.gettext")

local function source(rel)
    local handle = assert(io.open(PLUGIN_DIR .. "/" .. rel, "r"))
    local text = handle:read("*a")
    handle:close()
    return text
end

-- The one-word rule as it stood before the count: one token, at most four CJK characters
local function oldSingleWord(text)
    if not text or text == "" then return false end
    local tokens = 0
    for _w in text:gmatch("%S+") do
        tokens = tokens + 1
        if tokens > 1 then return false end
    end
    local cjk = 0
    for _c in text:gmatch("[\227-\237][\128-\191][\128-\191]") do
        cjk = cjk + 1
        if cjk > 4 then return false end
    end
    return tokens == 1
end

local SAMPLES = {
    "", " ", "lantern", " lantern ", "ice cream", "se rendre compte", "a b c d e f",
    "D'Arnel", "word.", "naïve", "السلام", "السلام عليكم",
    "読書", "読書家", "読書家たち", "読書家たちは", "読書 家", "한국어", "一二三四五六七八", "一二三四五六七八九",
}

TestRunner:test("with nothing raised, a word is what it was: one run of letters, at most four CJK characters", function()
    for _idx, text in ipairs(SAMPLES) do
        TestRunner:assertEqual(Viewer.isSingleWord(text), oldSingleWord(text), "isSingleWord(" .. text .. ")")
        TestRunner:assertEqual(Viewer.countsAsWord(text, {}), oldSingleWord(text), "countsAsWord(" .. text .. ") with no setting")
        TestRunner:assertEqual(Viewer.countsAsWord(text, { short_selection_words = 1 }), oldSingleWord(text), text .. " with the setting off")
    end
    TestRunner:assertEqual(Viewer.isSingleWord(nil), false)
    TestRunner:assertEqual(Viewer.countsAsWord(nil, nil), false)
end)

TestRunner:test("the count: one per run of letters, a CJK run one for every four characters", function()
    local cases = {
        { "", 0 }, { "   ", 0 }, { "lantern", 1 }, { "ice cream", 2 }, { "se rendre compte", 3 },
        { "読書", 1 }, { "読書家たち", 2 }, { "一二三四五六七八", 2 }, { "一二三四五六七八九", 3 }, { "読書 家", 2 },
        { "the 読書家たち", 3 },
    }
    for _idx, case in ipairs(cases) do
        TestRunner:assertEqual(Viewer.wordUnits(case[1]), case[2], "wordUnits(" .. case[1] .. ")")
    end
    TestRunner:assertEqual(Viewer.wordUnits(nil), 0)
    TestRunner:assertEqual(Viewer.wordUnits(12), 0)
end)

TestRunner:test("raised to N, a selection of up to N words is a word and one more is a passage", function()
    local two, three = { short_selection_words = 2 }, { short_selection_words = 3 }
    TestRunner:assertEqual(Viewer.countsAsWord("lantern", two), true, "one word stays a word")
    TestRunner:assertEqual(Viewer.countsAsWord("ice cream", two), true)
    TestRunner:assertEqual(Viewer.countsAsWord("an ice cream", two), false)
    TestRunner:assertEqual(Viewer.countsAsWord("an ice cream", three), true)
    TestRunner:assertEqual(Viewer.countsAsWord("an ice cream cone", three), false)
    TestRunner:assertEqual(Viewer.countsAsWord("一二三四五六七八", two), true, "eight CJK characters are two")
    TestRunner:assertEqual(Viewer.countsAsWord("一二三四五六七八九", two), false)
    TestRunner:assertEqual(Viewer.countsAsWord("", three), false, "nothing is no word")
    TestRunner:assertEqual(Viewer.countsAsWord("ice cream", { short_selection_words = "2" }), true, "a number stored as text")
    TestRunner:assertEqual(Viewer.countsAsWord("ice cream", { short_selection_words = 0 }), false, "never under one")
end)

-- KOReader's dictionary module as the door sees it, on the reader that is on
-- screen (a stand-in for KOReader's module; put back at the file's end)
local RUI_NAME = "apps/reader/readerui"
local saved_reader_ui = package.loaded[RUI_NAME]
local ReaderUI = {}
package.loaded[RUI_NAME] = ReaderUI
local function withReader(dictionary, fn)
    local saved = ReaderUI.instance
    ReaderUI.instance = dictionary and { dictionary = dictionary } or nil
    local ok, err = pcall(fn)
    ReaderUI.instance = saved
    if not ok then error(err, 0) end
end

TestRunner:test("the door: KOReader's own lookup, marked for the bypass's wrapper for that one call", function()
    local seen = {}
    local dict = {}
    dict.onLookupWord = function(self, word, is_sane, boxes)
        seen[#seen + 1] = { word = word, is_sane = is_sane, boxes = boxes, explicit = self._koassistant_explicit_dictionary }
    end
    withReader(dict, function()
        TestRunner:assertEqual(Viewer.lookupNative("lantern", nil), true)
        TestRunner:assertEqual(#seen, 1)
        TestRunner:assertEqual(seen[1].word, "lantern")
        TestRunner:assertEqual(seen[1].is_sane, false, "KOReader cleans the word itself")
        TestRunner:assertEqual(seen[1].explicit, true, "the mark the wrapper hands to KOReader's own function")
        TestRunner:assertEqual(dict._koassistant_explicit_dictionary, nil, "gone after the call, wrapper or not")
        TestRunner:assertEqual(dict._koassistant_keep_selection, nil, "no passage sent along: nothing left for the window")
        -- the passage the answer belongs to goes along, for "+Note" on KOReader's window
        -- (the window is built after the call returns, and takes it over then)
        local passage = { pos0 = "a", pos1 = "b", text = "lantern" }
        Viewer.lookupNative("lantern", nil, passage)
        TestRunner:assertEqual(dict._koassistant_keep_selection, passage)
        dict._koassistant_keep_selection = nil
        TestRunner:assertEqual(Viewer.lookupNative("   ", nil), false, "nothing to look up")
        TestRunner:assertEqual(Viewer.lookupNative(nil, nil), false)
        TestRunner:assertEqual(#seen, 2, "the two real lookups, nothing for the empty ones")
    end)
    withReader(nil, function()
        TestRunner:assertEqual(Viewer.lookupNative("lantern", { dictionary = dict }), true, "the caller's own UI where none is on screen")
        TestRunner:assertEqual(Viewer.lookupNative("lantern", nil), false, "no dictionary anywhere")
    end)
end)

TestRunner:test("the wrapper does hand a marked lookup to KOReader, bypass on", function()
    -- main.lua's own wrapper, read for the two lines the door relies on
    local main = source("main.lua")
    local from = assert(main:find("\nfunction AskGPT:syncDictionaryBypass(", 1, true))
    local body = main:sub(from, assert(main:find("\nend\n", from, true)))
    local read = body:find("local explicit = dict_self._koassistant_explicit_dictionary", 1, true)
    local hand = body:find("if explicit or", 1, true)
    local bypass = body:find("bypass_enabled = features.dictionary_bypass_enabled", read or 1, true)
    TestRunner:assertTrue(read ~= nil and hand ~= nil and hand > read, "the mark is read, then KOReader's own function runs")
    TestRunner:assertTrue(bypass ~= nil and bypass > hand, "ahead of the bypass")
end)

TestRunner:test("the row is offered for a word and for nothing longer; one name on every surface", function()
    local looked = {}
    local dict = { onLookupWord = function(_self, word) looked[#looked + 1] = word end }
    withReader(dict, function()
        local row = Viewer.nativeDictionaryRow("lantern", {}, nil)
        TestRunner:assertTrue(row ~= nil, "a word")
        TestRunner:assertEqual(row.text, "Open KOReader's dictionary")
        row.callback()
        TestRunner:assertEqual(looked[1], "lantern")
        local passage = { pos0 = "a", pos1 = "b", text = "lantern" }
        Viewer.nativeDictionaryRow("lantern", {}, nil, passage).callback()
        TestRunner:assertEqual(dict._koassistant_keep_selection, passage, "the row sends the answer's passage along")
        dict._koassistant_keep_selection = nil
        TestRunner:assertEqual(Viewer.nativeDictionaryRow("Morning came grey over the town.", {}, nil), nil, "a passage")
        TestRunner:assertEqual(Viewer.nativeDictionaryRow("ice cream", {}, nil), nil, "two words, nothing raised")
        TestRunner:assertTrue(Viewer.nativeDictionaryRow("ice cream", { short_selection_words = 2 }, nil) ~= nil,
            "two words once the reader counts two as a word")
        TestRunner:assertEqual(Viewer.nativeDictionaryRow(nil, {}, nil), nil)
    end)
    withReader(nil, function()
        TestRunner:assertEqual(Viewer.nativeDictionaryRow("lantern", {}, nil), nil, "no dictionary to open")
    end)
    -- the three surfaces ask the one builder
    local n = 0
    for _idx, rel in ipairs({ "main.lua", "koassistant/ui/minimal_popup.lua", "koassistant/ui/chatgptviewer.lua" }) do
        local text = source(rel)
        TestRunner:assertTrue(text:find("nativeDictionaryRow(", 1, true) ~= nil, rel .. " offers the row")
        for _hit in text:gmatch('_%("Open KOReader\'s dictionary"%)') do n = n + 1 end
    end
    TestRunner:assertEqual(n, 1, "the row's words are written once")
end)

-- main.lua's wrapper of KOReader's highlight menu, cut and run on a stand-in reader
local main_src = source("main.lua")
local function cut(name)
    local s = main_src:find("\nfunction AskGPT:" .. name .. "(", 1, true)
    assert(s, "main.lua has no AskGPT:" .. name)
    local e = assert(main_src:find("\nend\n", s, true))
    return main_src:sub(s + 1, e + 4)
end
local AC_NAME = "koassistant.artifacts.action_cache"
local saved_action_cache = package.loaded[AC_NAME]
package.loaded[AC_NAME] = { matchAnyXrayExact = function() return false end, hasAnyXray = function() return false end }
local saved_settings = rawget(_G, "G_reader_settings")
local reader_settings = {}
_G.G_reader_settings = {
    readSetting = function(_self, key, default)
        if reader_settings[key] == nil then return default end
        return reader_settings[key]
    end,
    isTrue = function(_self, key) return reader_settings[key] == true end,
}
local GD_NAME = "device/gesturedetector"
local saved_gesture_detector = package.loaded[GD_NAME]
package.loaded[GD_NAME] = { LONG_HOLD_INTERVAL_S = 3 }
local scheduled = 0
local saved_schedule = UIManager.scheduleIn
UIManager.scheduleIn = function() scheduled = scheduled + 1 end

local AskGPT = assert(load(table.concat({
    "local UIManager, InfoMessage, _, logger = ...",
    "local AskGPT = {}",
    cut("syncHighlightBypass"),
    "return AskGPT",
}, "\n"), "=main.lua (cut)"))(UIManager, InfoMessage, _, logger)

local function reader(features)
    local r = { menus = 0, looked = {}, ran = {}, cleared = 0, features = features }
    r.hl = {
        onShowHighlightMenu = function() r.menus = r.menus + 1; return true end,
        onHoldRelease = function() return true end,
        _resetHoldTimer = function() end,
        long_hold_reached_action = function() end,
        lookupDict = function(hl) r.looked[#r.looked + 1] = { text = hl.selected_text.text, menu_open = hl.highlight_dialog ~= nil } end,
        clear = function() r.cleared = r.cleared + 1 end,
    }
    r.plugin = setmetatable({
        ui = { highlight = r.hl, document = { file = "/books/a.epub" } },
        settings = { readSetting = function() return r.features end },
        action_service = { getAction = function(_self, _context, id) return { id = id, text = id } end },
        _xrayInterceptEnabled = function() return false end,
        executeHighlightBypassAction = function(_self, action, text) r.ran[#r.ran + 1] = { action = action.id, text = text } end,
    }, { __index = AskGPT })
    r.plugin:syncHighlightBypass()
    r.select = function(text, long_final)
        r.hl.selected_text = { text = text }
        r.hl._koassistant_long_final = long_final or nil
        return r.hl:onShowHighlightMenu()
    end
    return r
end

TestRunner:test("in the book: nothing raised, every selection goes where it went", function()
    local r = reader({})
    r.select("ice cream")
    TestRunner:assertEqual(r.menus, 1, "KOReader's menu")
    TestRunner:assertEqual(#r.looked, 0)
    r = reader({ highlight_bypass_enabled = true, highlight_bypass_action = "translate" })
    r.select("ice cream")
    TestRunner:assertEqual(r.ran[1].action, "translate", "the highlight bypass, two words included")
    TestRunner:assertEqual(#r.looked, 0)
end)

TestRunner:test("in the book: a short selection goes where a held word goes, a longer one where a selection goes", function()
    local r = reader({ short_selection_words = 2 })
    TestRunner:assertEqual(r.select("ice cream"), true)
    TestRunner:assertEqual(r.looked[1].text, "ice cream", "KOReader's lookup of the selection")
    TestRunner:assertEqual(r.looked[1].menu_open, false, "no menu open: the dictionary bypass still takes it when it is on")
    TestRunner:assertEqual(r.menus, 0, "and no highlight menu")
    r.select("lantern")
    TestRunner:assertEqual(r.looked[2].text, "lantern", "one dragged word is a word too")
    r.select("an ice cream")
    TestRunner:assertEqual(#r.looked, 2)
    TestRunner:assertEqual(r.menus, 1, "three words: the menu")
end)

TestRunner:test("in the book: ahead of the highlight bypass, behind a very long press", function()
    local r = reader({ short_selection_words = 3, highlight_bypass_enabled = true, highlight_bypass_action = "translate" })
    r.select("se rendre compte")
    TestRunner:assertEqual(#r.looked, 1, "three words are looked up")
    TestRunner:assertEqual(#r.ran, 0, "not translated")
    r.select("Morning came grey over the town.")
    TestRunner:assertEqual(r.ran[1].action, "translate", "a passage still runs the bypass")
    TestRunner:assertEqual(#r.looked, 1)
    r.select("se rendre compte", true)
    TestRunner:assertEqual(r.menus, 1, "a very long press asks for the menu")
    TestRunner:assertEqual(#r.looked, 1)
end)

TestRunner:test("the very long press is armed while short selections are the only thing on", function()
    reader_settings = {}
    local r = reader({ short_selection_words = 2 })
    scheduled = 0
    r.hl.is_word_selection = false
    r.hl:_resetHoldTimer(false)
    TestRunner:assertEqual(scheduled, 1, "our layer replaces the menu, so the timer KOReader skips under Ask is set")
    r = reader({})
    scheduled = 0
    r.hl:_resetHoldTimer(false)
    TestRunner:assertEqual(scheduled, 0, "nothing of ours on: KOReader's own timing")
    reader_settings = { default_highlight_action = "translate" }
    r = reader({ short_selection_words = 2 })
    scheduled = 0
    r.hl:_resetHoldTimer(false)
    TestRunner:assertEqual(scheduled, 0, "under another long-press action KOReader armed it itself")
    reader_settings = {}
end)

TestRunner:test("a window and KOReader's own viewers read the same rule; the setting is a list that starts at Off", function()
    local viewer = source("koassistant/ui/chatgptviewer.lua")
    TestRunner:assertTrue(viewer:find("ChatGPTViewer.countsAsWord(text, self.configuration and self.configuration.features)", 1, true) ~= nil,
        "a selection inside a KOAssistant window")
    local n = 0
    for _hit in main_src:gmatch("ChatGPTViewer%.countsAsWord%(") do n = n + 1 end
    TestRunner:assertEqual(n, 2, "KOReader's text viewer and its dictionary window, under Enhance text selection")
    TestRunner:assertEqual(main_src:find("isSingleWord(", 1, true), nil, "no second rule in main.lua")
    local Schema = require("koassistant.ui.settings_schema")
    local function row(id, items)
        for _idx, item in ipairs(items or Schema.items) do
            if item.id == id then return item end
            local below = item.items and row(id, item.items)
            if below then return below end
        end
    end
    local setting = row("short_selection_words")
    TestRunner:assertTrue(setting ~= nil, "the row")
    TestRunner:assertEqual(setting.default, 1, "off unless the reader raises it")
    TestRunner:assertEqual(setting.options[1].value, 1)
    TestRunner:assertEqual(setting.options[1].label, "Off")
    TestRunner:assertEqual(setting.options[#setting.options].value, 5)
    TestRunner:assertEqual(Schema.getDefaults()["features.short_selection_words"], 1)
end)

-- one Lua process runs the suite: put back what this file replaced
package.loaded[AC_NAME] = saved_action_cache
package.loaded[RUI_NAME] = saved_reader_ui
package.loaded[GD_NAME] = saved_gesture_detector
_G.G_reader_settings = saved_settings
UIManager.scheduleIn = saved_schedule

return TestRunner:summary()
