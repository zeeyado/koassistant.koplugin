-- A tap on a passage whose note the plugin wrote (B722, B774).
--
-- Every tap on a highlight goes through one function of KOReader's,
-- ReaderHighlight:showHighlightNoteOrDialog. main.lua puts two things in
-- front of it for a note that is the plugin's own: what KOReader is told of
-- the note's format follows the note as it is now, and a note of answers
-- whose actions show in the minimal popup opens in that popup again, where a
-- tap inside opens KOReader's own window. Everything else, and any failure,
-- is KOReader's window as before.
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
    r.hl = {
        showHighlightNoteOrDialog = r.original,
        getHighlightVisibleBoxes = function(_hl, _index) return r.rects end,
    }
    r.plugin = setmetatable({
        ui = { highlight = r.hl, annotation = { annotations = r.list }, document = { file = "/books/a.epub" } },
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

TestRunner:test("a tap inside the popup: KOReader's own note window, for the highlight where it stands now", function()
    reset()
    local r = newReader()
    r.plugin:syncKeptNotePopup()
    local item = kept(r, { TRANSLATION })
    r.hl:showHighlightNoteOrDialog(1)
    -- the reader's list changed while the popup stood (a highlight made above this one)
    table.insert(r.list, 1, { datetime = "2026-11-23 09:00:00", drawer = "lighten" })
    popup.calls[1].on_expand()
    TestRunner:assertEqual(#r.opened, 1)
    TestRunner:assertEqual(r.list[r.opened[1]], item, "the same highlight, at its place now")
    -- the highlight deleted meanwhile: nothing to open, no error
    table.remove(r.list, 2)
    popup.calls[1].on_expand()
    TestRunner:assertEqual(#r.opened, 1)
end)

TestRunner:test("a note the popup does not take: KOReader's window, as for any note", function()
    reset()
    local r = newReader()
    r.plugin:syncKeptNotePopup()
    kept(r, { EXPLANATION })                                   -- Explain shows in a chat window
    kept(r, { TRANSLATION, EXPLANATION })                      -- one of its answers does
    r.list[#r.list + 1] = { datetime = "2026-11-23 11:00:00", note = "my own note" }   -- no record
    r.list[#r.list + 1] = { datetime = "2026-11-23 11:00:01", drawer = "lighten" }     -- no note: the highlight's menu
    local mixed = kept(r, { TRANSLATION })
    mixed.note = mixed.note .. "\n\nand my own words"
    for index = 1, 5 do r.hl:showHighlightNoteOrDialog(index) end
    TestRunner:assertEqual(#popup.calls, 0)
    TestRunner:assertEqual(table.concat(r.opened, ","), "1,2,3,4,5")
end)

TestRunner:test("the reader's switches: the setting off, the popup off, Translate taken off the popup's list", function()
    for _i, features in ipairs({
        { kept_answer_popup = false },
        { minimal_popup_mode = "off" },
        { minimal_popup_actions = { "quick_define" } },
    }) do
        reset()
        local r = newReader(features)
        r.plugin:syncKeptNotePopup()
        kept(r, { TRANSLATION })
        r.hl:showHighlightNoteOrDialog(1)
        TestRunner:assertEqual(#popup.calls, 0)
        TestRunner:assertEqual(#r.opened, 1)
    end
    -- and an action put on the list since its answer was saved
    reset()
    local r = newReader({ minimal_popup_actions = { "explain" } })
    r.plugin:syncKeptNotePopup()
    kept(r, { EXPLANATION })
    r.hl:showHighlightNoteOrDialog(1)
    TestRunner:assertEqual(#popup.calls, 1, "today's list decides, not the day it was saved")
end)

TestRunner:test("the popup says no (the answer does not fit under When it fits): KOReader's window", function()
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
    local r = newReader()
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
    TestRunner:assertEqual(#popup.calls, 0, "and a note with the reader's words in it is KOReader's window's")
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

return TestRunner:summary()
