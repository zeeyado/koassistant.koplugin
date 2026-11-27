-- A tap on a passage whose note the plugin wrote (B722, B774).
--
-- Every tap on a highlight goes through one function of KOReader's,
-- ReaderHighlight:showHighlightNoteOrDialog. main.lua puts two things in
-- front of it for a note that is the plugin's own: what KOReader is told of
-- the note's format follows the note as it is now, and a note the plugin
-- saved an answer in, whatever action made it, opens in the plugin's own
-- popup, with the note's menu behind a tap: KOReader's buttons, KOReader's
-- own window, and where the answers came from. Everything else, and any
-- failure, is KOReader's window as before.
--
-- main.lua's own two functions, cut from the source and run on a stand-in
-- reader, with the real note writer's record and a stand-in for the popup.
--
-- Run: lua tests/unit/test_kept_note_popup.lua  (or lua tests/run_tests.lua --unit)

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
print("  A tap on a kept passage")
print(string.rep("=", 50))

local HighlightNote = require("koassistant.chat.highlight_note")

-- The popup, as a stand-in for this file; put back at the end (one Lua
-- process runs the suite)
local POPUP = "koassistant.ui.minimal_popup"
local saved_popup = package.loaded[POPUP]
-- KOReader's event, as the writer's Delete note sends one (put back too)
local saved_event = package.loaded["ui/event"]
package.loaded["ui/event"] = { new = function(_cls, name, arg) return { name = name, arg = arg } end }
local UIManager = require("ui/uimanager")
local saved_setDirty = rawget(UIManager, "setDirty")
UIManager.setDirty = function() end
local popup = { calls = {}, shows = true, fails = false }
package.loaded[POPUP] = {
    showForNote = function(opts)
        popup.calls[#popup.calls + 1] = opts
        if popup.fails then error("the popup could not be built") end
        return popup.shows
    end,
}

local warned = {}
local logger = { warn = function(...) warned[#warned + 1] = table.concat({ ... }, " ", 1, 1) end, dbg = function() end }

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
local AskGPT = assert(load(table.concat({
    "local logger = ...",
    "local _ = function(text) return text end",
    "local AskGPT = {}",
    cut("syncKeptNotePopup"),
    cut("_showKeptNote"),
    "return AskGPT",
}, "\n"), "=main.lua (cut)"))(logger)

-- A reader with one book open. KOReader's own function records what it was
-- asked to show; the highlight's rectangles are KOReader's own tables.
local function newReader(features)
    local r = { opened = {}, features = features or {}, rects = { { x = 40, y = 120, w = 600, h = 30, live = true } } }
    r.store = {
        data = {},
        readSetting = function(self, key) return self.data[key] end,
        saveSetting = function(self, key, value) self.data[key] = value end,
    }
    r.list = {}
    r.original = function(_hl, index) r.opened[#r.opened + 1] = index end
    r.edited, r.menus, r.deleted, r.events = {}, {}, {}, {}
    r.hl = {
        showHighlightNoteOrDialog = r.original,
        getHighlightVisibleBoxes = function(_hl, _index) return r.rects end,
        -- KOReader's own, as the note's menu ends in them
        dialog = "the reader's dialog",
        editNote = function(_hl, index) r.edited[#r.edited + 1] = index end,
        showHighlightDialog = function(_hl, index) r.menus[#r.menus + 1] = index end,
        deleteHighlight = function(_hl, index) r.deleted[#r.deleted + 1] = table.remove(r.list, index) end,
        writePdfAnnotation = function() end,
    }
    r.plugin = setmetatable({
        ui = { highlight = r.hl, annotation = { annotations = r.list }, document = { file = "/books/a.epub" },
            handleEvent = function(_ui, event) r.events[#r.events + 1] = event end },
        settings = { readSetting = function() return r.features end },
        _openBookDS = function() return r.store end,
    }, { __index = AskGPT })
    return r
end

-- A highlight whose note is the given pieces, each recorded as the writer records it
local function kept(r, pieces, stamp)
    local note, parts = "", {}
    for i, piece in ipairs(pieces) do
        if i > 1 then note = note .. "\n\n" end
        parts[i] = { kind = piece.kind, action = piece.action, at = 1, from = #note + 1, len = #piece.text,
            sum = HighlightNote.fingerprint(piece.text) }
        note = note .. piece.text
    end
    local item = { datetime = stamp or ("2026-11-23 10:00:0" .. (#r.list + 1)), note = note, drawer = "lighten",
        pos0 = "a", pos1 = "b" }
    r.list[#r.list + 1] = item
    local all = r.store.data[HighlightNote.RECORD_KEY] or {}
    all[item.datetime] = { parts = parts }
    r.store.data[HighlightNote.RECORD_KEY] = all
    return item
end

local TRANSLATION = { kind = "translate", action = "translate", text = "Le matin se leva gris." }
local EXPLANATION = { kind = "chat", action = "explain", text = "Explain:\n\n**Awake** here means she had not slept." }

local function reset()
    popup.calls, popup.shows, popup.fails = {}, true, false
    warned = {}
end

TestRunner:test("a kept translation: the popup, with the note's pieces and the highlight's place; KOReader's window stays shut", function()
    reset()
    local r = newReader()
    r.plugin:syncKeptNotePopup()
    kept(r, { TRANSLATION })
    r.hl:showHighlightNoteOrDialog(1)
    TestRunner:assertEqual(#popup.calls, 1, "the popup is asked")
    TestRunner:assertEqual(#r.opened, 0, "KOReader's own window is not opened")
    local opts = popup.calls[1]
    TestRunner:assertEqual(#opts.parts, 1)
    TestRunner:assertEqual(opts.parts[1].text, "Le matin se leva gris.")
    TestRunner:assertEqual(opts.parts[1].kind, "translate")
    TestRunner:assertEqual(opts.features, r.features, "the reader's settings as they are now")
    TestRunner:assertEqual(opts.plugin, r.plugin)
    TestRunner:assertEqual(opts.ui, r.plugin.ui)
    -- the rectangles as plain copies: the popup's anchor is written on, KOReader's tables are not ours
    TestRunner:assertEqual(opts.boxes[1].x, 40)
    TestRunner:assertEqual(opts.boxes[1].h, 30)
    TestRunner:assertTrue(opts.boxes[1] ~= r.rects[1] and opts.boxes[1].live == nil, "a copy, never KOReader's own table")
end)

-- A row of the menu the popup was handed, by its words
local function row(opts, text)
    for _i, item in ipairs(opts.rows) do
        if item.text == text then return item end
    end
    error("the menu has no row " .. text)
end

TestRunner:test("the note's menu: KOReader's buttons and its window, each on the highlight where it stands now", function()
    reset()
    local r = newReader()
    r.plugin:syncKeptNotePopup()
    local item = kept(r, { TRANSLATION })
    r.hl:showHighlightNoteOrDialog(1)
    local opts = popup.calls[1]
    local words = {}
    for i, entry in ipairs(opts.rows) do words[i] = entry.separator and "--" or entry.text end
    TestRunner:assertEqual(table.concat(words, " | "),
        "Edit note | Open in KOReader's note window | Highlight menu | -- | Delete note | Delete highlight",
        "what leads on first, what takes away last and apart")
    TestRunner:assertEqual(opts.on_expand, nil, "a tap inside is the menu, not a window")
    -- the reader's list changed while the popup stood (a highlight made above this one)
    table.insert(r.list, 1, { datetime = "2026-11-23 09:00:00", drawer = "lighten" })
    row(opts, "Edit note").callback()
    TestRunner:assertEqual(r.list[r.edited[1]], item, "KOReader's editor, on the same highlight at its place now")
    row(opts, "Open in KOReader's note window").callback()
    TestRunner:assertEqual(r.list[r.opened[1]], item, "KOReader's own window, not the popup again")
    TestRunner:assertEqual(#popup.calls, 1)
    row(opts, "Highlight menu").callback()
    TestRunner:assertEqual(r.list[r.menus[1]], item)
    -- Delete note: the note goes, the highlight stays, the record's line leaves
    row(opts, "Delete note").callback()
    TestRunner:assertEqual(item.note, nil)
    TestRunner:assertEqual(#r.list, 2)
    TestRunner:assertEqual(r.events[1].arg.nb_notes_added, -1, "KOReader's own event")
    TestRunner:assertEqual(r.store.data[HighlightNote.RECORD_KEY][item.datetime], nil)
    -- Delete highlight, on another kept passage
    local second = kept(r, { TRANSLATION })
    r.hl:showHighlightNoteOrDialog(3)
    row(popup.calls[2], "Delete highlight").callback()
    TestRunner:assertEqual(r.deleted[1], second)
    TestRunner:assertEqual(r.store.data[HighlightNote.RECORD_KEY][second.datetime], nil)
    -- a row tapped for a highlight that is gone meanwhile: nothing, no error
    row(popup.calls[2], "Highlight menu").callback()
    row(popup.calls[2], "Open in KOReader's note window").callback()
    row(popup.calls[2], "Edit note").callback()
    TestRunner:assertEqual(#r.menus, 1)
    TestRunner:assertEqual(#r.opened, 1)
    TestRunner:assertEqual(#r.edited, 1)
end)

TestRunner:test("a highlighted word's menu also opens KOReader's dictionary, with the popup left standing", function()
    reset()
    local r = newReader()
    local looked = {}
    r.plugin.ui.dictionary = { onLookupWord = function(self, word)
        looked[#looked + 1] = { word = word, explicit = self._koassistant_explicit_dictionary,
            passage = self._koassistant_keep_selection }
    end }
    r.plugin:syncKeptNotePopup()
    local item = kept(r, { { kind = "dictionary", action = "quick_define", text = "**lantern**, a lamp in a case." } })
    item.text = "lantern"
    r.hl:showHighlightNoteOrDialog(1)
    local opts = popup.calls[1]
    local words = {}
    for i, entry in ipairs(opts.rows) do words[i] = entry.separator and "--" or entry.text end
    TestRunner:assertEqual(table.concat(words, " | "),
        "Edit note | Open in KOReader's note window | Highlight menu | Open KOReader's dictionary | -- | Delete note | Delete highlight")
    local door = row(opts, "Open KOReader's dictionary")
    TestRunner:assertEqual(door.keep, true, "the popup stays under KOReader's window")
    door.callback()
    TestRunner:assertEqual(looked[1].word, "lantern")
    TestRunner:assertEqual(looked[1].explicit, true, "KOReader's own dictionary, whatever the bypass is set to")
    TestRunner:assertTrue(looked[1].passage ~= nil and looked[1].passage.pos0 == item.pos0 and looked[1].passage.pos1 == item.pos1
        and looked[1].passage.text == "lantern", "the highlight's own place goes along: +Note on that window adds to this note")
    -- a highlighted passage has no such row
    local passage = kept(r, { TRANSLATION })
    passage.text = "Morning came grey over the town, and the lamps were still lit."
    r.hl:showHighlightNoteOrDialog(2)
    for _i, entry in ipairs(popup.calls[2].rows) do
        TestRunner:assertTrue(entry.text ~= "Open KOReader's dictionary", "a passage is not looked up")
    end
end)

TestRunner:test("the menu's title says where the answers came from", function()
    reset()
    local r = newReader()
    r.plugin:syncKeptNotePopup()
    local item = kept(r, { TRANSLATION })
    local line = r.store.data[HighlightNote.RECORD_KEY][item.datetime]
    line.parts[1].action_name, line.parts[1].model = "Translate", "small-model"
    line.parts[1].at = os.time({ year = 2026, month = 11, day = 24, hour = 12 })
    r.hl:showHighlightNoteOrDialog(1)
    TestRunner:assertEqual(popup.calls[1].info, "Translate · small-model · 2026-11-24")
end)

TestRunner:test("every note the plugin saved an answer in opens in the popup; a note of the reader's own is KOReader's", function()
    reset()
    local r = newReader()
    r.plugin:syncKeptNotePopup()
    kept(r, { EXPLANATION })                                   -- a new Explain answer opens in a chat window
    kept(r, { TRANSLATION, EXPLANATION })
    r.list[#r.list + 1] = { datetime = "2026-11-23 11:00:00", note = "my own note" }   -- no record
    r.list[#r.list + 1] = { datetime = "2026-11-23 11:00:01", drawer = "lighten" }     -- no note: the highlight's menu
    for index = 1, 4 do r.hl:showHighlightNoteOrDialog(index) end
    TestRunner:assertEqual(#popup.calls, 2, "the two notes with saved answers")
    TestRunner:assertEqual(#popup.calls[2].parts, 2, "the whole note, both kinds")
    TestRunner:assertEqual(table.concat(r.opened, ","), "3,4", "the other two are KOReader's, as before")
end)

TestRunner:test("a note the reader has written in since still opens in the popup, as it is now", function()
    reset()
    local r = newReader()
    r.plugin:syncKeptNotePopup()
    -- a line added under the translation (KOReader's Edit note, or the editor of Edit before saving)
    local added = kept(r, { TRANSLATION })
    added.note = added.note .. "\n\nand my own words"
    r.hl:showHighlightNoteOrDialog(1)
    TestRunner:assertEqual(#popup.calls, 1, "an added line does not send the note to KOReader's window")
    TestRunner:assertEqual(#r.opened, 0)
    TestRunner:assertEqual(popup.calls[1].note, added.note, "the popup is handed the note as it is now")
    TestRunner:assertEqual(popup.calls[1].parts[1].text, TRANSLATION.text, "and the answer that still stands, to draw by its kind")
    -- the translation itself corrected: no piece stands as saved; the note is still what Translate made
    local fixed = kept(r, { TRANSLATION })
    fixed.note = "Le matin se leva, gris."
    r.hl:showHighlightNoteOrDialog(2)
    TestRunner:assertEqual(#popup.calls, 2)
    TestRunner:assertEqual(popup.calls[2].note, "Le matin se leva, gris.")
    TestRunner:assertEqual(popup.calls[2].parts[1].kind, "translate")
    TestRunner:assertEqual(popup.calls[2].parts[1].text, nil, "the piece no longer stands as it was saved")
    -- the note deleted in KOReader's window, then a note of the reader's own on the same highlight:
    -- the record's line went with the deleted note, so the new note is theirs alone
    local gone = kept(r, { TRANSLATION })
    gone.note = nil
    r.hl:showHighlightNoteOrDialog(3)                 -- the tap that opens the highlight's menu
    TestRunner:assertEqual(r.store.data[HighlightNote.RECORD_KEY][gone.datetime], nil)
    gone.note = "a note of my own"
    r.hl:showHighlightNoteOrDialog(3)
    TestRunner:assertEqual(#popup.calls, 2, "no popup for it")
    TestRunner:assertEqual(table.concat(r.opened, ","), "3,3")
end)

TestRunner:test("the reader's switch sends a kept passage to KOReader's window; how new answers are shown does not", function()
    reset()
    local off = newReader({ kept_answer_popup = false })
    off.plugin:syncKeptNotePopup()
    kept(off, { TRANSLATION })
    off.hl:showHighlightNoteOrDialog(1)
    TestRunner:assertEqual(#popup.calls, 0)
    TestRunner:assertEqual(#off.opened, 1)
    for _i, features in ipairs({
        { minimal_popup_mode = "off" },                     -- the popup off for new answers
        { minimal_popup_actions = { "quick_define" } },     -- Translate taken off its list
        { minimal_popup_mode = "short" },                   -- When it fits is about new answers
    }) do
        reset()
        local r = newReader(features)
        r.plugin:syncKeptNotePopup()
        kept(r, { TRANSLATION })
        r.hl:showHighlightNoteOrDialog(1)
        TestRunner:assertEqual(#popup.calls, 1)
        TestRunner:assertEqual(#r.opened, 0)
    end
end)

TestRunner:test("the popup has nothing to show: KOReader's window", function()
    reset()
    local r = newReader()
    r.plugin:syncKeptNotePopup()
    kept(r, { TRANSLATION })
    popup.shows = false
    r.hl:showHighlightNoteOrDialog(1)
    TestRunner:assertEqual(#popup.calls, 1)
    TestRunner:assertEqual(#r.opened, 1)
end)

TestRunner:test("a failure on the way is KOReader's window and a line in the log, never a tap that does nothing", function()
    reset()
    local r = newReader()
    r.plugin:syncKeptNotePopup()
    kept(r, { TRANSLATION })
    popup.fails = true
    r.hl:showHighlightNoteOrDialog(1)
    TestRunner:assertEqual(#r.opened, 1)
    TestRunner:assertEqual(#warned, 1)
    -- an index KOReader has no annotation for
    reset()
    r.hl:showHighlightNoteOrDialog(7)
    TestRunner:assertEqual(r.opened[#r.opened], 7, "handed on as it came")
    TestRunner:assertEqual(#warned, 0)
end)

TestRunner:test("the note's format is settled before KOReader shows the note", function()
    reset()
    -- (the popup switched off: KOReader's window is what shows the format)
    local r = newReader({ kept_answer_popup = false })
    r.plugin:syncKeptNotePopup()
    -- an explanation kept before the plugin named formats: named at the first tap
    local item = kept(r, { EXPLANATION })
    local seen
    r.hl._koassistant_original_showNote = function(_hl, index) seen = r.list[index].note_format end
    r.hl:showHighlightNoteOrDialog(1)
    TestRunner:assertEqual(seen, "md", "KOReader draws it as Markdown")
    TestRunner:assertEqual(r.store.data[HighlightNote.RECORD_KEY][item.datetime].md, true)
    -- the reader writes in it: KOReader's window, the answer still drawn
    item.note = item.note .. "\n\nmy own line\nand another"
    seen = nil
    r.hl:showHighlightNoteOrDialog(1)
    TestRunner:assertEqual(seen, "md", "an added line does not take the formatting away")
    -- the note deleted in KOReader's window: the mark is taken back before anything else is shown
    item.note = nil
    seen = "not asked"
    r.hl:showHighlightNoteOrDialog(1)
    TestRunner:assertEqual(seen, nil, "taken back with the note")
    TestRunner:assertEqual(item.note_format, nil)
    -- a translation alone is never named
    reset()
    local t = newReader({ kept_answer_popup = false })
    t.plugin:syncKeptNotePopup()
    local line = kept(t, { TRANSLATION })
    t.hl:showHighlightNoteOrDialog(1)
    TestRunner:assertEqual(line.note_format, nil)
    -- and with the popup on, the format is settled before the popup shows the note
    reset()
    local p = newReader()
    p.plugin:syncKeptNotePopup()
    local shown = kept(p, { EXPLANATION })
    p.hl:showHighlightNoteOrDialog(1)
    TestRunner:assertEqual(#popup.calls, 1)
    TestRunner:assertEqual(shown.note_format, "md", "so KOReader's window, one row further, draws it too")
end)

TestRunner:test("a PDF: no rectangles are handed over (the popup stands in the middle, as a new answer's does)", function()
    reset()
    local r = newReader()
    r.plugin.ui.paging = {}
    r.plugin:syncKeptNotePopup()
    kept(r, { TRANSLATION })
    r.hl:showHighlightNoteOrDialog(1)
    TestRunner:assertEqual(#popup.calls, 1)
    TestRunner:assertEqual(popup.calls[1].boxes, nil)
end)

TestRunner:test("installed once per reader, and not at all where there is no reader", function()
    reset()
    local r = newReader()
    r.plugin:syncKeptNotePopup()
    local wrapped = r.hl.showHighlightNoteOrDialog
    TestRunner:assertTrue(wrapped ~= r.original)
    r.plugin:syncKeptNotePopup()
    TestRunner:assertEqual(r.hl.showHighlightNoteOrDialog, wrapped, "a second call wraps nothing again")
    TestRunner:assertEqual(r.hl._koassistant_original_showNote, r.original)
    -- the file browser's instance has no highlight module
    local browser = setmetatable({ ui = {} }, { __index = AskGPT })
    browser:syncKeptNotePopup()
    setmetatable({}, { __index = AskGPT }):syncKeptNotePopup()
end)

TestRunner:test("both starts install it: the plugin's own start and the reader's ready hook", function()
    local n = select(2, main_src:gsub("self:syncKeptNotePopup%(%)", ""))
    TestRunner:assertEqual(n, 2)
    -- and the function it wraps is the one a tap on a highlight goes through in the bundled KOReader
    local path = "/Applications/KOReader.app/Contents/koreader/frontend/apps/reader/modules/readerhighlight.lua"
    local f = io.open(path, "r")
    if f then
        local hl = f:read("*a")
        f:close()
        TestRunner:assertTrue(hl:find("function ReaderHighlight:showHighlightNoteOrDialog(index)", 1, true) ~= nil)
        TestRunner:assertTrue(hl:find("self:showHighlightNoteOrDialog(highlights[1])", 1, true) ~= nil, "a tap on one highlight")
        TestRunner:assertTrue(hl:find("local note_format = anno.note_format", 1, true) ~= nil, "it reads the note's format")
        TestRunner:assertTrue(hl:find("function ReaderHighlight:getHighlightVisibleBoxes(index)", 1, true) ~= nil)
    end
end)

package.loaded[POPUP] = saved_popup
package.loaded["ui/event"] = saved_event
UIManager.setDirty = saved_setDirty

return TestRunner:summary()
