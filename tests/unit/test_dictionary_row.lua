-- KOReader's own dictionary stays reachable while the dictionary bypass is on
-- (B716, B583).
--
-- The bypass replaces ReaderDictionary:onLookupWord, the one function behind
-- every lookup, so with it on nothing reached KOReader's dictionary: not the
-- highlight menu's own Dictionary row (a pick of that dictionary by name), and
-- not a word under the Vocabulary Builder's review, whose Forgot and Got it
-- buttons live on KOReader's window. An exact X-Ray name opened its card from
-- the same places, bypass or not.
--
-- main.lua's own syncDictionaryBypass, cut from the source and run on a
-- stand-in reader: what the wrappers do with a held word, with the menu's
-- row, with the default highlight action, with a review word, and what
-- switching everything off puts back.
--
-- Run: lua tests/unit/test_dictionary_row.lua  (or lua tests/run_tests.lua --unit)

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
print("  KOReader's dictionary beside the bypass")
print(string.rep("=", 50))

local UIManager = require("ui/uimanager")
local InfoMessage = require("ui/widget/infomessage")
local _ = require("koassistant.core.gettext")
local logger = require("koassistant.core.logger")
-- The X-Ray lookup's index, as a stand-in for this file (the real module reads
-- KOReader's sidecar code); put back at the end: one Lua process runs the suite
local AC_NAME = "koassistant.artifacts.action_cache"
local saved_action_cache = package.loaded[AC_NAME]
local ActionCache = { matchAnyXrayExact = function() return false end }
package.loaded[AC_NAME] = ActionCache

local main_src
do
    local f = assert(io.open(PLUGIN_DIR .. "/main.lua", "r"))
    main_src = f:read("*a")
    f:close()
end
local function cut(name)
    local s = main_src:find("\nfunction AskGPT:" .. name .. "(", 1, true)
    assert(s, "main.lua has no AskGPT:" .. name)
    local e = assert(main_src:find("\nend\n", s, true))
    return main_src:sub(s + 1, e + 4)
end

-- what the cut function reaches outside itself
local ran = {}          -- the bypass action's runs: the word each got
local Dialogs = {
    extractSurroundingContext = function() return "" end,
    contextAfterLimit = function() return nil end,
    fetchSelectionContextWindow = function() return nil end,
    executeDirectAction = function(_ui, action, word) ran[#ran + 1] = { action = action.id, word = word } end,
}
local NetworkMgr = { runWhenConnected = function(_self, fn) fn() end }
local chunk = table.concat({
    "local UIManager, InfoMessage, _, logger, Dialogs, NetworkMgr, configuration = ...",
    "local AskGPT = {}",
    cut("syncDictionaryBypass"),
    "return AskGPT",
}, "\n")
local AskGPT = assert(load(chunk, "=main.lua (cut)"))(UIManager, InfoMessage, _, logger, Dialogs, NetworkMgr,
    { features = {} })

-- A reader as the wrappers see it. KOReader's own two functions record their
-- calls; lookupDict hands the selection to the dictionary as KOReader's does.
local function reader(features)
    local looked, cards = {}, {}
    local ui = { document = { file = "/books/a.epub" }, doc_settings = { readSetting = function() end } }
    ui.dictionary = {
        ui = ui,
        cleanSelection = function(_self, word) return word end,
        onLookupWord = function(_self, word) looked[#looked + 1] = word; return true end,
    }
    ui.highlight = {
        ui = ui,
        selected_text = { text = "lantern" },
        lookupDict = function(self)
            if not self.selected_text then return end
            return self.ui.dictionary:onLookupWord(self.selected_text.text, false, nil, self)
        end,
        clear = function() end,
    }
    local intercept = false
    local plugin = setmetatable({
        ui = ui,
        settings = { readSetting = function() return features end },
        action_service = { getAction = function(_s, _ctx, id) return { id = id, local_handler = "stand-in" } end },
        updateConfigFromSettings = function() end,
        _scrubContextFeatures = function() end,
        _openBookDS = function() return ui.doc_settings end,
        _xrayInterceptEnabled = function() return intercept end,
        _xrayAheadEnabled = function() return false end,
        _xrayReaderPosition = function() return 0 end,
        openXrayCard = function(_s, word) cards[#cards + 1] = word end,
    }, { __index = AskGPT })
    return plugin, ui, looked, cards, function(on) intercept = on end
end
local function reset()
    for i = #ran, 1, -1 do ran[i] = nil end
end
-- the highlight menu is open while its Dictionary row's callback runs
local function pickDictionaryRow(ui)
    ui.highlight.highlight_dialog = {}
    ui.highlight:lookupDict()
    ui.highlight.highlight_dialog = nil
end

TestRunner:test("with the bypass on a held word runs the bypass action (the control)", function()
    reset()
    local plugin, ui, looked = reader({ dictionary_bypass_enabled = true, dictionary_bypass_action = "quick_define" })
    plugin:syncDictionaryBypass()
    ui.dictionary:onLookupWord("lantern", false, nil, ui.highlight)
    TestRunner:assertEqual(#ran, 1, "the action ran")
    TestRunner:assertEqual(ran[1].word, "lantern", "with the held word")
    TestRunner:assertEqual(#looked, 0, "and KOReader's dictionary did not open")
end)

TestRunner:test("the highlight menu's own Dictionary row opens KOReader's dictionary", function()
    reset()
    local plugin, ui, looked = reader({ dictionary_bypass_enabled = true })
    plugin:syncDictionaryBypass()
    pickDictionaryRow(ui)
    TestRunner:assertEqual(#looked, 1, "KOReader's dictionary opened")
    TestRunner:assertEqual(looked[1], "lantern", "for the selected word")
    TestRunner:assertEqual(#ran, 0, "and the bypass action did not run")
end)

TestRunner:test("the pick is for that one lookup: the next held word is the bypass's again", function()
    reset()
    local plugin, ui, looked = reader({ dictionary_bypass_enabled = true })
    plugin:syncDictionaryBypass()
    pickDictionaryRow(ui)
    ui.dictionary:onLookupWord("brass", false, nil, ui.highlight)
    TestRunner:assertEqual(#looked, 1, "one lookup went to KOReader")
    TestRunner:assertEqual(#ran, 1, "the next one to the action")
    TestRunner:assertEqual(ran[1].word, "brass", "with its own word")
    -- a row tapped with nothing selected reaches no lookup, and leaves no mark behind
    reset()
    ui.highlight.selected_text = nil
    pickDictionaryRow(ui)
    TestRunner:assertTrue(ui.dictionary._koassistant_explicit_dictionary == nil, "no mark is left by a pick that looked nothing up")
    ui.dictionary:onLookupWord("table", false, nil, ui.highlight)
    TestRunner:assertEqual(#ran, 1, "so the next held word still runs the action")
end)

TestRunner:test("KOReader's default highlight action Dictionary (no menu) stays the bypass's", function()
    reset()
    local plugin, ui, looked = reader({ dictionary_bypass_enabled = true })
    plugin:syncDictionaryBypass()
    ui.highlight:lookupDict()   -- no highlight_dialog: the release itself went to the dictionary
    TestRunner:assertEqual(#ran, 1, "the action ran")
    TestRunner:assertEqual(#looked, 0, "KOReader's dictionary did not open")
end)

TestRunner:test("an X-Ray name: a held word opens its card, the menu's Dictionary row the dictionary", function()
    reset()
    local saved = ActionCache.matchAnyXrayExact
    ActionCache.matchAnyXrayExact = function() return true, "lantern" end
    local plugin, ui, looked, cards, setIntercept = reader({})   -- the bypass off: the intercept alone installs the wrapper
    setIntercept(true)
    plugin:syncDictionaryBypass()
    ui.dictionary:onLookupWord("lantern", false, nil, ui.highlight)
    TestRunner:assertEqual(#cards, 1, "the held word opened the X-Ray card")
    TestRunner:assertEqual(#looked, 0, "not the dictionary")
    pickDictionaryRow(ui)
    TestRunner:assertEqual(#looked, 1, "the row opened KOReader's dictionary")
    TestRunner:assertEqual(#cards, 1, "and no second card")
    ActionCache.matchAnyXrayExact = saved
end)

TestRunner:test("an X-Ray name picked for the Dictionary in the plugin's own selection popup is never the card's", function()
    -- the popup of a chat window or an X-Ray page: Dictionary and "Look up in
    -- X-Ray" are two rows there, and the first one opened the card of a word
    -- that is an entry. Its row marks the lookup for the one call.
    local function pickPopupDictionary(ui, word)
        ui.dictionary._koassistant_non_reader_lookup = true
        ui.dictionary._koassistant_skip_xray = true
        ui.dictionary:onLookupWord(word)
        ui.dictionary._koassistant_skip_xray = nil
    end
    reset()
    local saved = ActionCache.matchAnyXrayExact
    ActionCache.matchAnyXrayExact = function() return true, "lantern" end
    -- the bypass off: KOReader's dictionary
    local plugin, ui, looked, cards, setIntercept = reader({})
    setIntercept(true)
    plugin:syncDictionaryBypass()
    pickPopupDictionary(ui, "lantern")
    TestRunner:assertEqual(#cards, 0, "no X-Ray card")
    TestRunner:assertEqual(#looked, 1, "KOReader's dictionary opened")
    TestRunner:assertTrue(ui.dictionary._koassistant_skip_xray == nil, "the mark is gone after the call")
    -- the next held word is the card's again
    ui.dictionary:onLookupWord("lantern", false, nil, ui.highlight)
    TestRunner:assertEqual(#cards, 1, "a held word still opens the card")
    -- the bypass on: the reader's own dictionary action, still not the card
    reset()
    plugin, ui, looked, cards, setIntercept = reader({ dictionary_bypass_enabled = true, dictionary_bypass_action = "quick_define" })
    setIntercept(true)
    plugin:syncDictionaryBypass()
    pickPopupDictionary(ui, "lantern")
    TestRunner:assertEqual(#cards, 0, "no X-Ray card with the bypass on either")
    TestRunner:assertEqual(#ran, 1, "the bypass action ran, as for any word looked up there")
    TestRunner:assertEqual(#looked, 0, "in place of KOReader's dictionary")
    -- the bypass set to Look up in X-Ray: the pick is still the dictionary's
    reset()
    plugin, ui, looked, cards, setIntercept = reader({ dictionary_bypass_enabled = true, dictionary_bypass_action = "xray_lookup" })
    plugin.action_service = { getAction = function(_s, _ctx, id) return { id = id, local_handler = id } end }
    setIntercept(true)
    plugin:syncDictionaryBypass()
    pickPopupDictionary(ui, "lantern")
    TestRunner:assertEqual(#cards, 0, "no X-Ray card")
    TestRunner:assertEqual(#ran, 0, "and no X-Ray lookup in the bypass's name")
    TestRunner:assertEqual(#looked, 1, "KOReader's dictionary opened")
    ActionCache.matchAnyXrayExact = saved
    -- and the row itself sets the mark around its one call
    local f = assert(io.open(PLUGIN_DIR .. "/koassistant/ui/chatgptviewer.lua", "r"))
    local viewer_src = f:read("*a")
    f:close()
    local a = assert(viewer_src:find("function ChatGPTViewer.buildTextSelectionPopup(", 1, true))
    local body = viewer_src:sub(a, assert(viewer_src:find("\nend\n", a, true)))
    local set_at = body:find("dui.dictionary._koassistant_skip_xray = true", 1, true)
    local call_at = body:find("dui.dictionary:onLookupWord(text)", 1, true)
    local clear_at = body:find("dui.dictionary._koassistant_skip_xray = nil", 1, true)
    TestRunner:assertTrue(set_at ~= nil and call_at ~= nil and clear_at ~= nil and set_at < call_at and call_at < clear_at,
        "the popup's Dictionary row marks its lookup, then clears the mark")
end)

TestRunner:test("a word under the Vocabulary Builder's review gets KOReader's window, with its buttons", function()
    reset()
    local plugin, ui, looked = reader({ dictionary_bypass_enabled = true })
    plugin:syncDictionaryBypass()
    ui.vocabbuilder = { widget = { current_lookup_word = "lantern" } }   -- the builder's list is open on this word
    ui.dictionary:onLookupWord("lantern", true)
    TestRunner:assertEqual(#looked, 1, "KOReader's window opened")
    TestRunner:assertEqual(#ran, 0, "the bypass action did not run")
    -- another word looked up meanwhile is not under review
    ui.dictionary:onLookupWord("brass", true)
    TestRunner:assertEqual(#ran, 1, "another word is the bypass's")
    -- the builder closed: its window is gone, the word is an ordinary one again
    ui.vocabbuilder.widget = nil
    ui.dictionary:onLookupWord("lantern", true)
    TestRunner:assertEqual(#ran, 2, "after the builder closed the word is the bypass's again")
end)

TestRunner:test("switching the bypass and the X-Ray lookup off puts both of KOReader's functions back", function()
    local features = { dictionary_bypass_enabled = true }
    local plugin, ui = reader(features)
    local own_lookup, own_row = ui.dictionary.onLookupWord, ui.highlight.lookupDict
    plugin:syncDictionaryBypass()
    TestRunner:assertTrue(ui.dictionary.onLookupWord ~= own_lookup, "the lookup is wrapped")
    TestRunner:assertTrue(ui.highlight.lookupDict ~= own_row, "the row's function is wrapped")
    features.dictionary_bypass_enabled = false
    features.xray_selection_intercept = false
    plugin:syncDictionaryBypass()
    TestRunner:assertTrue(ui.dictionary.onLookupWord == own_lookup, "the lookup is KOReader's again")
    TestRunner:assertTrue(ui.highlight.lookupDict == own_row, "the row's function is KOReader's again")
    -- and on again: wrapped once, not twice
    features.dictionary_bypass_enabled = true
    plugin:syncDictionaryBypass()
    plugin:syncDictionaryBypass()
    TestRunner:assertTrue(ui.highlight._koassistant_original_lookupDict == own_row, "a second sync keeps KOReader's function as the original")
end)

TestRunner:test("the KOReader names this rests on exist in the installed app", function()
    local base = "/Applications/KOReader.app/Contents/koreader/"
    local function bundle(path)
        local f = io.open(base .. path, "r")
        if not f then return nil end
        local s = f:read("*a")
        f:close()
        return s
    end
    local hl = bundle("frontend/apps/reader/modules/readerhighlight.lua")
    if not hl then
        print("    (skipped: KOReader is not at " .. base .. ")")
        return
    end
    TestRunner:assertTrue(hl:find("function ReaderHighlight:lookupDict(index)", 1, true) ~= nil, "ReaderHighlight:lookupDict")
    TestRunner:assertTrue(hl:find("this:lookupDict(index)", 1, true) ~= nil, "the Dictionary row calls it")
    TestRunner:assertTrue(hl:find("self.highlight_dialog = ButtonDialog:new{", 1, true) ~= nil, "the menu is highlight_dialog")
    TestRunner:assertTrue(hl:find("self:lookupDict()", 1, true) ~= nil, "the default highlight action calls it with no menu")
    local vb = bundle("plugins/vocabbuilder.koplugin/main.lua")
    TestRunner:assertTrue(vb ~= nil and vb:find("self.current_lookup_word = item.word", 1, true) ~= nil,
        "the Vocabulary Builder names the word under review")
    TestRunner:assertTrue(vb ~= nil and vb:find("self.vocabbuilder.widget = nil", 1, true) ~= nil,
        "and forgets its window when it closes")
end)

package.loaded[AC_NAME] = saved_action_cache

return TestRunner:summary()
