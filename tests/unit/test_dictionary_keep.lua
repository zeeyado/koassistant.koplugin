-- A definition from KOReader's own dictionary kept as the word's note (B790).
--
-- The reader of discussion 127 does not use AI dictionaries and wants the few
-- words of a definition that matter on a card. KOReader's dictionary window
-- gets a "+Note" button (the definition on screen), a selected part of a
-- definition can be saved alone, and both go through the one note writer: one
-- highlight per word, a second save joining the first, the note on record as
-- a saved answer whose "model" is the dictionary's name.
--
-- main.lua's own keepDictionaryDefinition and patchDictionarySelectionSave,
-- cut from the source and run on a stand-in reader with the real writer.
--
-- Run: lua tests/unit/test_dictionary_keep.lua  (or lua tests/run_tests.lua --unit)

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
print("  KOReader's dictionary: a definition kept as the word's note")
print(string.rep("=", 50))

-- What this file replaces, put back at the end (one process runs every file)
local SAVED = {}
for _i, name in ipairs({ "ui/event", "util", "apps/reader/readerui", "ui/widget/dictquicklookup",
        "koassistant.storage.doc_settings" }) do
    SAVED[name] = package.loaded[name]
end
local UIManager = require("ui/uimanager")
local saved_setDirty = rawget(UIManager, "setDirty")
local saved_show = rawget(UIManager, "show")
local notices = {}
UIManager.setDirty = function() end
UIManager.show = function(_um, widget) notices[#notices + 1] = widget and widget.text end
package.loaded["ui/event"] = { new = function(_cls, name, arg) return { name = name, arg = arg } end }
-- KOReader's helper, in short: tags out, <br> a line break
package.loaded["util"] = { htmlToPlainTextIfHtml = function(text)
    return (text:gsub("%s*<%s*br%s*/?>%s*", "\n"):gsub("<[^>]*>", ""))
end }
local the_store
package.loaded["koassistant.storage.doc_settings"] = { resolve = function() return the_store end }

local DictButtons = require("koassistant.ui.dict_buttons")
local HighlightNote = require("koassistant.chat.highlight_note")
local Notification = { new = function(_cls, o) return o end }
local _ = require("koassistant.core.gettext")

local function source(rel)
    local handle = assert(io.open(PLUGIN_DIR .. "/" .. rel, "r"))
    local text = handle:read("*a")
    handle:close()
    return text
end
local main_src = source("main.lua")
local function cut(name)
    local s = main_src:find("\nfunction AskGPT:" .. name .. "(", 1, true)
    assert(s, "main.lua has no AskGPT:" .. name)
    local e = assert(main_src:find("\nend\n", s, true))
    return main_src:sub(s + 1, e + 4)
end
local AskGPT = assert(load(table.concat({
    "local UIManager, Notification, _ = ...",
    "local AskGPT = {}",
    cut("keepDictionaryDefinition"),
    cut("patchDictionarySelectionSave"),
    "return AskGPT",
}, "\n"), "=main.lua (cut)"))(UIManager, Notification, _)

-- A reader that keeps KOReader's rules for a highlight, and its dictionary window
local function newReader()
    local r = { events = {}, clock = 0 }
    the_store = {
        data = {},
        readSetting = function(self, key) return self.data[key] end,
        saveSetting = function(self, key, value) self.data[key] = value end,
    }
    r.store = the_store
    local ui = { document = { file = "/books/a.epub" }, rolling = {} }
    ui.annotation = { annotations = {}, onAnnotationsModified = function() end }
    ui.handleEvent = function(_ui, event) r.events[#r.events + 1] = event end
    ui.highlight = {
        dialog = "the reader's dialog",
        saveHighlight = function(self)
            local st = self.selected_text
            if not (st and st.pos0 and st.pos1) then return nil end
            r.clock = r.clock + 1
            local list = ui.annotation.annotations
            list[#list + 1] = { pos0 = st.pos0, pos1 = st.pos1, text = st.text, drawer = "lighten",
                datetime = "2026-11-27 10:00:0" .. r.clock }
            return #list
        end,
        clear = function() end,
        writePdfAnnotation = function() end,
    }
    r.ui = ui
    r.plugin = setmetatable({ ui = ui, settings = { readSetting = function() return r.features or {} end } }, { __index = AskGPT })
    return r
end
-- KOReader's window after a lookup of `word` in the book
local function window(r, word, results, pos)
    local closed = { n = 0 }
    r.ui.highlight.selected_text = { pos0 = pos or "/p[1]/text().4", pos1 = (pos or "/p[1]/text().4") .. "+", text = word }
    return {
        word = word, results = results, dict_index = 1, highlight = r.ui.highlight,
        onHoldClose = function(self) closed.n = closed.n + 1; closed.save_highlight = self.save_highlight end,
    }, closed
end
local LANTERN = { { dict = "Test Dictionary", word = "lantern",
    definition = "<b>lantern</b> /ˈlæntən/<br/>1. a lamp with a case around its light<br/>2. the top of a lighthouse", is_html = true } }

TestRunner:test("what can be kept: a real result of a lookup made in the book", function()
    local r = newReader()
    local popup = window(r, "lantern", LANTERN)
    TestRunner:assertEqual(DictButtons.canKeepDefinition(popup, {}), true)
    TestRunner:assertEqual(DictButtons.showNoteButton(popup, {}), true, "the button shows")
    TestRunner:assertEqual(DictButtons.showNoteButton(popup, { show_note_in_dictionary = false }), false, "the reader's switch for the button")
    TestRunner:assertEqual(DictButtons.canKeepDefinition(popup), true, "which hides the button, not the ability")
    popup.is_wiki = true
    TestRunner:assertEqual(DictButtons.canKeepDefinition(popup, {}), false, "never on a Wikipedia window")
    popup.is_wiki = nil
    popup.highlight = nil
    TestRunner:assertEqual(DictButtons.canKeepDefinition(popup, {}), false, "a lookup from elsewhere has no word in the book")
    popup.highlight = { selected_text = nil }
    TestRunner:assertEqual(DictButtons.canKeepDefinition(popup, {}), false)
    local none = window(r, "zzz", { { dict = "Not available", word = "zzz", definition = "No results.", no_result = true } })
    TestRunner:assertEqual(DictButtons.canKeepDefinition(none, {}), false, "nothing found is nothing to keep")
    TestRunner:assertEqual(DictButtons.canKeepDefinition(nil, {}), false)
end)

TestRunner:test("KOReader's dictionary opened from one of the plugin's answers keeps on the answer's own passage", function()
    local r = newReader()
    -- the answer's word is already a highlight with a saved AI definition
    local list = r.ui.annotation.annotations
    list[1] = { pos0 = "/p[1]/text().4", pos1 = "/p[1]/text().4+", text = "lantern", drawer = "lighten",
        datetime = "2026-11-27 09:00:00", note = "**lantern**, a lamp." }
    -- the plugin opened the window itself: no selection of KOReader's, the passage sent along
    local popup, closed = window(r, "lantern", LANTERN)
    popup.highlight = nil
    r.ui.highlight.selected_text = nil
    local dict = { _koassistant_keep_selection = { pos0 = list[1].pos0, pos1 = list[1].pos1, text = "lantern" } }
    TestRunner:assertEqual(DictButtons.canKeepDefinition(popup, {}), false, "before the window took the passage over")
    local taken = DictButtons.takeKeepSelection(popup, dict)
    TestRunner:assertTrue(taken ~= nil and taken.pos0 == list[1].pos0, "the window takes the passage")
    TestRunner:assertEqual(dict._koassistant_keep_selection, nil, "once: the next lookup gets none")
    TestRunner:assertEqual(DictButtons.takeKeepSelection(popup, { _koassistant_keep_selection = { pos0 = "x", pos1 = "y" } }), taken,
        "a rebuild of the window's buttons keeps what was taken")
    TestRunner:assertEqual(DictButtons.canKeepDefinition(popup, {}), true)
    TestRunner:assertEqual(DictButtons.selectionOf(popup), taken)
    -- +Note: the definition joins the note of that one highlight
    notices = {}
    TestRunner:assertEqual(r.plugin:keepDictionaryDefinition(popup, "a lamp with a case around its light"), true)
    TestRunner:assertEqual(#list, 1, "no second highlight on the word")
    TestRunner:assertEqual(list[1].note, "**lantern**, a lamp.\n\na lamp with a case around its light")
    TestRunner:assertEqual(notices[#notices], "Added to the highlight's note")
    TestRunner:assertEqual(closed.n, 1)
    -- a window with neither has nothing to keep on; KOReader's own selection wins where there is one
    local bare = window(r, "lantern", LANTERN)
    bare.highlight = nil
    TestRunner:assertEqual(DictButtons.takeKeepSelection(bare, {}), nil)
    TestRunner:assertEqual(DictButtons.canKeepDefinition(bare, {}), false)
    local both = window(r, "brass", LANTERN, "/p[1]/text().30")
    both._koassistant_keep_selection = taken
    TestRunner:assertEqual(DictButtons.selectionOf(both).text, "brass", "the lookup made in the book")
end)

TestRunner:test("the definition as a note: the result on screen as text, the dictionary's name beside it", function()
    local r = newReader()
    local popup = window(r, "lantern", LANTERN)
    local to_plain = package.loaded["util"].htmlToPlainTextIfHtml
    local text, from = DictButtons.shownDefinition(popup, to_plain)
    TestRunner:assertEqual(text, "lantern /ˈlæntən/\n1. a lamp with a case around its light\n2. the top of a lighthouse")
    TestRunner:assertEqual(from.dictionary, "Test Dictionary")
    TestRunner:assertEqual(from.headword, "lantern")
    -- the window's own text carries KOReader's "(query : …)" line under a fuzzy match: not read
    popup.definition = LANTERN[1].definition .. "<br/>_______<br/>(query : lanterns)"
    TestRunner:assertEqual((DictButtons.shownDefinition(popup, to_plain)), text)
    -- the second dictionary's result when the reader paged to it
    popup.results = { LANTERN[1], { dict = "Other", word = "lantern", definition = "  a light  " } }
    popup.dict_index = 2
    text, from = DictButtons.shownDefinition(popup, to_plain)
    TestRunner:assertEqual(text, "a light")
    TestRunner:assertEqual(from.dictionary, "Other")
    TestRunner:assertEqual(DictButtons.shownDefinition({ results = {} }, to_plain), nil)
end)

TestRunner:test("+Note: the definition becomes the note of ONE highlight on the word, on record as a dictionary answer", function()
    local r = newReader()
    local popup, closed = window(r, "lantern", LANTERN)
    popup.save_highlight = true   -- KOReader's own Highlight button was tapped too
    notices = {}
    TestRunner:assertEqual(r.plugin:keepDictionaryDefinition(popup), true)
    local list = r.ui.annotation.annotations
    TestRunner:assertEqual(#list, 1, "one highlight")
    TestRunner:assertEqual(list[1].text, "lantern")
    TestRunner:assertEqual(list[1].note, "lantern /ˈlæntən/\n\n1. a lamp with a case around its light\n\n2. the top of a lighthouse",
        "each line of the definition a paragraph of the note: it is drawn as Markdown, where one line break is a space")
    TestRunner:assertEqual(list[1].note_format, "md", "the plugin names the note's format, as for an AI dictionary answer")
    TestRunner:assertEqual(closed.n, 1, "the window closes: the page shows again")
    TestRunner:assertEqual(closed.save_highlight, nil, "and KOReader's own Highlight mark is taken back: no second highlight")
    TestRunner:assertEqual(notices[#notices], "Saved as a note")
    -- the record: what kind, and where it came from
    local pieces = HighlightNote.piecesOf(r.store, list[1])
    TestRunner:assertEqual(#pieces, 1)
    TestRunner:assertEqual(pieces[1].kind, "dictionary")
    TestRunner:assertEqual(pieces[1].model, "Test Dictionary", "the dictionary's name where a model's stands")
    TestRunner:assertEqual(pieces[1].provider, "koreader_dictionary")
    TestRunner:assertEqual(pieces[1].action, nil, "no action of ours answered")
    TestRunner:assertEqual(pieces[1].text, list[1].note, "the piece stands as saved")
    TestRunner:assertTrue(HighlightNote.sourceText(pieces):find("^KOReader dictionary · Test Dictionary · %d%d%d%d%-%d%d%-%d%d$") ~= nil,
        "the saved answer's menu names it: " .. tostring(HighlightNote.sourceText(pieces)))
    -- it is shown again in the popup, and goes into the file for Anki with the dictionary answers
    TestRunner:assertTrue(HighlightNote.popupParts(pieces, {}) ~= nil)
    local AnkiExport = require("koassistant.chat.anki_export")
    local ticked = require("koassistant.core.constants").resolveAnkiExportActions(nil)
    TestRunner:assertEqual(AnkiExport.wanted(ticked)(pieces[1]), true, "exported by default, with Dictionary")
    local row = AnkiExport.row(list[1], pieces, { wanted = AnkiExport.wanted(ticked), markdown = function(t) return t end, title = "A Book" })
    TestRunner:assertEqual(row[7], "KOReader dictionary", "the Kind column")
    TestRunner:assertTrue(row[8]:find("koreader_dictionary", 1, true) ~= nil, "and its tag: " .. row[8])
end)

TestRunner:test("a selected part is the whole note; a second save on the same word joins the first", function()
    local r = newReader()
    local popup = window(r, "lantern", LANTERN)
    notices = {}
    TestRunner:assertEqual(r.plugin:keepDictionaryDefinition(popup, "  a lamp with a case around its light "), true)
    local list = r.ui.annotation.annotations
    TestRunner:assertEqual(list[1].note, "a lamp with a case around its light", "the part alone, trimmed")
    TestRunner:assertEqual(HighlightNote.linesAsParagraphs(" one \n\ttwo\n\n\nthree "), "one\n\ntwo\n\nthree", "a part of several lines")
    TestRunner:assertEqual(HighlightNote.linesAsParagraphs("one line"), "one line")
    TestRunner:assertEqual(HighlightNote.linesAsParagraphs(nil), "")
    TestRunner:assertEqual(notices[#notices], "Saved as a note")
    -- the same word looked up again, another part
    popup = window(r, "lantern", LANTERN)
    r.plugin:keepDictionaryDefinition(popup, "the top of a lighthouse")
    TestRunner:assertEqual(#list, 1, "still one highlight")
    TestRunner:assertEqual(list[1].note, "a lamp with a case around its light\n\nthe top of a lighthouse")
    TestRunner:assertEqual(notices[#notices], "Added to the highlight's note")
    TestRunner:assertEqual(#HighlightNote.piecesOf(r.store, list[1]), 2, "two pieces on record")
    -- the same part once more: nothing written
    popup = window(r, "lantern", LANTERN)
    r.plugin:keepDictionaryDefinition(popup, "the top of a lighthouse")
    TestRunner:assertEqual(list[1].note, "a lamp with a case around its light\n\nthe top of a lighthouse")
    TestRunner:assertEqual(notices[#notices], "Already in this highlight's note")
    -- another word: its own highlight
    popup = window(r, "brass", { { dict = "Test Dictionary", word = "brass", definition = "a yellow metal" } }, "/p[1]/text().20")
    r.plugin:keepDictionaryDefinition(popup)
    TestRunner:assertEqual(#list, 2)
    TestRunner:assertEqual(list[2].note, "a yellow metal")
end)

TestRunner:test("nothing to keep: a notice, the window left open, nothing written", function()
    local r = newReader()
    local popup, closed = window(r, "lantern", LANTERN)
    popup.highlight = nil
    notices = {}
    TestRunner:assertEqual(r.plugin:keepDictionaryDefinition(popup), false)
    TestRunner:assertEqual(notices[#notices], "No definition to save")
    TestRunner:assertEqual(closed.n, 0)
    TestRunner:assertEqual(#r.ui.annotation.annotations, 0)
end)

TestRunner:test("the one-step switch: a selection inside a definition is saved at once, only when the reader turned it on", function()
    local r = newReader()
    local kept, looked = {}, {}
    local Window = { lookupDictionaryOrWikipedia = function(_self, text, switch) looked[#looked + 1] = { text = text, switch = switch }; return true end }
    package.loaded["ui/widget/dictquicklookup"] = Window
    r.plugin.keepDictionaryDefinition = function(_self, popup, part) kept[#kept + 1] = { popup = popup, part = part } end
    package.loaded["apps/reader/readerui"] = { instance = { koassistant = r.plugin } }
    r.plugin:patchDictionarySelectionSave()
    r.plugin:patchDictionarySelectionSave()   -- installed once
    local popup = setmetatable(window(r, "lantern", LANTERN), { __index = Window })
    -- off (the default): KOReader's own lookup of the selected text
    r.features = {}
    popup:lookupDictionaryOrWikipedia("a lamp", false)
    TestRunner:assertEqual(#looked, 1)
    TestRunner:assertEqual(#kept, 0)
    -- on: saved, KOReader's lookup not run
    r.features = { dict_selection_saves_note = true }
    TestRunner:assertEqual(popup:lookupDictionaryOrWikipedia("a lamp", false), true)
    TestRunner:assertEqual(#looked, 1)
    TestRunner:assertEqual(kept[1].part, "a lamp")
    TestRunner:assertEqual(kept[1].popup, popup)
    -- on, but the lookup was not made in the book: KOReader's own
    popup.highlight = nil
    popup:lookupDictionaryOrWikipedia("a lamp", true)
    TestRunner:assertEqual(#looked, 2)
    TestRunner:assertEqual(looked[2].switch, true, "its arguments handed on")
    TestRunner:assertEqual(#kept, 1)
    -- on, with the +Note button hidden: the button's switch is the button's alone
    popup.highlight = r.ui.highlight
    r.features = { dict_selection_saves_note = true, show_note_in_dictionary = false }
    popup:lookupDictionaryOrWikipedia("a case", false)
    TestRunner:assertEqual(#looked, 2)
    TestRunner:assertEqual(kept[2].part, "a case")
end)

TestRunner:test("the button is registered on both paths, and the selection popup offers the part where a window can keep it", function()
    TestRunner:assertTrue(main_src:find('DictButtons.specId(note_index, "keep_note")', 1, true) ~= nil, "KOReader's button registry")
    local legacy = cut("onDictButtonsReady")
    TestRunner:assertTrue(legacy:find("keepDictionaryDefinition(dict_popup)", 1, true) ~= nil, "the older registration path")
    TestRunner:assertTrue(main_src:find("save_selection = save_selection,", 1, true) ~= nil,
        "KOReader's dictionary window hands the row its save")
    local viewer = source("koassistant/ui/chatgptviewer.lua")
    TestRunner:assertTrue(viewer:find('_("Save Selection to Note")', 1, true) ~= nil, "the row")
    TestRunner:assertTrue(viewer:find("save_selection = (self.canKeepNote and self:canKeepNote()) and function(selected_text)", 1, true) ~= nil,
        "a chat, dictionary or translate window hands it its own")
    -- the two switches: the button on by default, the one step off
    local Schema = require("koassistant.ui.settings_schema")
    local defaults = Schema.getDefaults()
    TestRunner:assertEqual(defaults["features.show_note_in_dictionary"], true)
    TestRunner:assertEqual(defaults["features.dict_selection_saves_note"], false)
end)

-- put back what this file replaced
for name, module in pairs(SAVED) do package.loaded[name] = module end
for _i, name in ipairs({ "ui/event", "util", "apps/reader/readerui", "ui/widget/dictquicklookup",
        "koassistant.storage.doc_settings" }) do
    if SAVED[name] == nil then package.loaded[name] = nil end
end
UIManager.setDirty = saved_setDirty
UIManager.show = saved_show

return TestRunner:summary()
