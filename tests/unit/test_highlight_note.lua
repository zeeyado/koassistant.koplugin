-- An answer kept as the note of the selection's highlight, at once (B722).
--
-- Save to Note opened KOReader's note editor, where the reader tapped Save a
-- second time, and it made a second highlight over a passage that was already
-- one. Now koassistant/chat/highlight_note.lua is the one writer: KOReader's
-- own highlight and note, saved the way KOReader's "Edit note" dialog saves
-- them, on the highlight the passage already has when it has one, and a record
-- of which notes the plugin wrote.
--
-- Three parts:
--   * the writer on a reader that keeps KOReader's rules for a highlight and
--     for a changed note (what an event counts, what stamps the change time);
--   * the windows' own saveToNote, run as it is: a tap saves, a hold asks,
--     "Edit before saving…" is KOReader's editor;
--   * guards: no other file writes a highlight or a note.
--
-- Run: lua tests/unit/test_highlight_note.lua  (or lua tests/run_tests.lua --unit)

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
    if ok then self.passed = self.passed + 1; print("    ✓ " .. name)
    else self.failed = self.failed + 1; print("    ✗ " .. name); print("      Error: " .. tostring(err)) end
end
local function eq(a, b, msg)
    if a ~= b then error(string.format("%s: expected %s, got %s", msg or "eq", tostring(b), tostring(a)), 2) end
end
local function ok(v, msg)
    if not v then error(msg or "expected a true value", 2) end
end

-- What this file replaces, put back at the end (one process runs every file)
local SAVED = {}
for _i, name in ipairs({ "ui/event", "apps/reader/readerui", "koassistant.chat.export",
        "koassistant.storage.doc_settings" }) do
    SAVED[name] = package.loaded[name]
end
local UIManager = require("ui/uimanager")
local saved_setDirty = rawget(UIManager, "setDirty")
local dirty = {}
UIManager.setDirty = function(_um, widget, mode) dirty[#dirty + 1] = { widget = widget, mode = mode } end

package.loaded["ui/event"] = {
    new = function(_cls, name, arg) return { name = name, arg = arg } end,
}

local HighlightNote = require("koassistant.chat.highlight_note")

-- ── a reader that keeps KOReader's rules ────────────────────────────────────
local function newStore()
    return {
        data = {}, saves = 0,
        readSetting = function(self, key) return self.data[key] end,
        saveSetting = function(self, key, value) self.data[key] = value; self.saves = self.saves + 1 end,
    }
end

local function newReader(opts)
    opts = opts or {}
    local r = { events = {}, pdf = {}, edits = {}, adds = {}, cleared = 0, stamps = 0, clock = 0, extension_asked = 0 }
    local ui = { document = { file = "/books/a.epub" } }
    r.ui = ui
    if opts.paging then ui.paging = {} else ui.rolling = {} end
    ui.document.extendXPointersToSentenceSegment = function(_doc, pos0, pos1)
        r.extension_asked = r.extension_asked + 1
        return opts.extend and opts.extend(pos0, pos1) or nil
    end
    ui.annotation = {
        annotations = {},
        -- ReaderAnnotation:onAnnotationsModified: the change time, unless an
        -- annotation was added or removed
        onAnnotationsModified = function(_self, items)
            if items.index_modified == nil or items.modify_datetime then
                r.stamps = r.stamps + 1
                items[1].datetime_updated = "changed " .. r.stamps
            end
        end,
    }
    ui.handleEvent = function(_ui, event)
        r.events[#r.events + 1] = event
        if event.name == "AnnotationsModified" then ui.annotation:onAnnotationsModified(event.arg) end
    end
    ui.highlight = {
        dialog = "the reader's dialog",
        view = { highlight = { note_mark = "underline" } },
        -- ReaderHighlight:saveHighlight, in short: an item from the selection's
        -- fields, the event that counts one highlight more
        saveHighlight = function(self, extend_to_sentence)
            r.save_flag = extend_to_sentence
            local st = self.selected_text
            if opts.no_highlight or not (st and st.pos0 and st.pos1) then return nil end
            r.clock = r.clock + 1
            local item = {
                pos0 = st.pos0, pos1 = st.pos1, text = st.text,
                datetime = st.datetime or ("2026-11-23 10:00:0" .. r.clock),
                drawer = st.drawer or "lighten", color = st.color, note = st.note,
            }
            local list = ui.annotation.annotations
            list[#list + 1] = item
            ui:handleEvent(require("ui/event"):new("AnnotationsModified",
                { item, nb_highlights_added = 1, index_modified = #list }))
            return #list
        end,
        -- ReaderHighlight:clear with no selection live: selected_text stays
        clear = function() r.cleared = r.cleared + 1 end,
        writePdfAnnotation = function(_self, action, item, content)
            r.pdf[#r.pdf + 1] = { action = action, item = item, content = content }
        end,
        editNote = function(_self, index, is_new, text)
            r.edits[#r.edits + 1] = { index = index, is_new = is_new, text = text }
        end,
        -- ReaderHighlight:deleteHighlight: the PDF's copy, the list, the page
        deleteHighlight = function(self, index)
            self:writePdfAnnotation("delete", ui.annotation.annotations[index])
            table.remove(ui.annotation.annotations, index)
            r.deleted = (r.deleted or 0) + 1
        end,
        addNote = function(self, text)
            r.adds[#r.adds + 1] = { text = text, selected = self.selected_text }
        end,
    }
    r.store = newStore()
    r.list = ui.annotation.annotations
    return r
end

local function selection(pos0, pos1, text)
    return { pos0 = pos0, pos1 = pos1, text = text or "Le matin se leva gris.", sboxes = {}, drawer = nil, color = nil }
end

-- A highlight the reader made before
local function highlightOf(r, pos0, pos1, note, stamp)
    local item = { pos0 = pos0, pos1 = pos1, text = "x", drawer = "lighten", note = note,
        datetime = stamp or ("2026-11-01 09:00:0" .. (#r.list + 1)) }
    r.list[#r.list + 1] = item
    return item
end

local function countEvents(r, which)
    local n = 0
    for _i, e in ipairs(r.events) do
        if e.name == "AnnotationsModified" and e.arg.nb_notes_added == which then n = n + 1 end
    end
    return n
end

print("")
print(string.rep("=", 60))
print("  Unit Tests: an answer kept as the highlight's note (B722)")
print(string.rep("=", 60))

print("\n  the writer")

TestRunner:test("fingerprint: the same text the same, a changed text not, nothing of the text kept", function()
    local a = HighlightNote.fingerprint("The morning rose grey.")
    eq(a, HighlightNote.fingerprint("The morning rose grey."))
    ok(a ~= HighlightNote.fingerprint("The morning rose gray."), "one letter changed, the same length")
    ok(a ~= HighlightNote.fingerprint("The morning rose grey. "), "a space more")
    ok(not a:find("morning", 1, true), "it holds no word of the note")
    eq(HighlightNote.fingerprint(nil), nil)
end)

TestRunner:test("a new selection: one highlight with the note, saved as KOReader's editor saves it", function()
    local r = newReader()
    local sel = selection("/body/p[3].0", "/body/p[3].22")
    dirty = {}
    local saved = HighlightNote.save(r.ui, sel, "The morning rose grey.\n", { extend = true, kind = "translate", store = r.store })
    ok(saved and saved.created and not saved.appended and not saved.already, "a highlight was made")
    eq(#r.list, 1, "one annotation")
    eq(r.list[1].note, "The morning rose grey.", "its note, the trailing line break gone")
    eq(saved.annotation, r.list[1])
    eq(r.save_flag, false, "the passage is handed over ready: KOReader is not asked to extend it again")
    eq(#r.events, 2, "two events")
    eq(r.events[1].arg.nb_highlights_added, 1, "KOReader's own: a highlight more")
    eq(r.events[2].arg.nb_highlights_added, -1, "then a highlight less")
    eq(r.events[2].arg.nb_notes_added, 1, "and a note more")
    eq(r.events[2].arg[1], r.list[1], "about that annotation")
    eq(r.list[1].datetime_updated, "changed 1", "the change time is stamped")
    eq(#r.pdf, 1, "the note is handed to the PDF writer")
    eq(r.pdf[1].action, "content")
    eq(r.pdf[1].content, "The morning rose grey.")
    eq(#dirty, 1, "the page is drawn again (the highlight, its note mark)")
    eq(dirty[1].widget, "the reader's dialog")
    eq(r.cleared, 1, "the selection's own drawing is cleared")
    eq(r.ui.highlight.selected_text, nil, "nothing of ours is left as KOReader's selection")
end)

TestRunner:test("the caller's selection is never written to", function()
    local r = newReader({ extend = function() return { pos0 = "/body/p[3].0", pos1 = "/body/p[3].23", text = "« Le matin. »" } end })
    local sel = selection("/body/p[3].2", "/body/p[3].21", "Le matin.")
    HighlightNote.save(r.ui, sel, "The morning.", { extend = true, store = r.store })
    eq(sel.pos0, "/body/p[3].2"); eq(sel.pos1, "/body/p[3].21"); eq(sel.text, "Le matin.")
    eq(sel.datetime, nil); eq(sel.note, nil)
    eq(r.list[1].pos0, "/body/p[3].0", "the highlight is the passage as KOReader's Add note saves it")
    eq(r.list[1].pos1, "/body/p[3].23")
    eq(r.list[1].text, "« Le matin. »")
end)

TestRunner:test("a looked-up word stays the word: the extension is not asked", function()
    local r = newReader({ extend = function() error("must not be asked") end })
    local saved = HighlightNote.save(r.ui, selection("/body/p[1].4", "/body/p[1].11", "lantern"), "A lamp.",
        { extend = false, kind = "dictionary", store = r.store })
    ok(saved and saved.created)
    eq(r.extension_asked, 0)
    eq(r.list[1].pos1, "/body/p[1].11")
end)

TestRunner:test("a passage that is already a highlight gets the note: no second highlight", function()
    local r = newReader()
    local mine = highlightOf(r, "/body/p[3].0", "/body/p[3].22")
    local saved = HighlightNote.save(r.ui, selection("/body/p[3].0", "/body/p[3].22"), "The morning rose grey.",
        { extend = true, kind = "translate", store = r.store })
    ok(saved and not saved.created and not saved.appended, "the reader's own highlight")
    eq(#r.list, 1, "still one annotation")
    eq(mine.note, "The morning rose grey.")
    eq(#r.events, 1, "one event: the highlight became a note")
    eq(r.events[1].arg.nb_highlights_added, -1)
    eq(r.events[1].arg.nb_notes_added, 1)
    eq(r.save_flag, nil, "KOReader was not asked for a highlight")
    eq(mine.pos1, "/body/p[3].22", "its ends are as the reader set them")
end)

TestRunner:test("a passage saved before is found by its extended ends", function()
    local wide = { pos0 = "/body/p[3].0", pos1 = "/body/p[3].23", text = "« Le matin. »" }
    local r = newReader({ extend = function() return wide end })
    local sel = selection("/body/p[3].2", "/body/p[3].21", "Le matin.")
    HighlightNote.save(r.ui, sel, "The morning.", { extend = true, store = r.store })
    local again = HighlightNote.save(r.ui, sel, "Morning came.", { extend = true, store = r.store })
    eq(#r.list, 1, "the second answer joins the first highlight")
    ok(again.appended and not again.created)
    eq(r.list[1].note, "The morning.\n\nMorning came.")
end)

TestRunner:test("a highlight with the reader's own note keeps it: the answer after a blank line", function()
    local r = newReader()
    local mine = highlightOf(r, "/body/p[3].0", "/body/p[3].22", "why grey?")
    local saved = HighlightNote.save(r.ui, selection("/body/p[3].0", "/body/p[3].22"), "The morning rose grey.",
        { kind = "translate", store = r.store })
    ok(saved.appended and not saved.created)
    eq(mine.note, "why grey?\n\nThe morning rose grey.")
    eq(#r.events, 0, "no counter changes: it was a note and is one")
    eq(r.stamps, 1, "the change time is stamped")
    eq(r.pdf[1].content, "why grey?\n\nThe morning rose grey.")
    local state, parts = HighlightNote.recordOf(r.store, mine)
    eq(state, "mixed", "the record says the note also holds the reader's words")
    eq(#parts, 1, "one piece is the plugin's")
    eq(parts[1].kind, "translate")
    eq(parts[1].text, "The morning rose grey.", "and it can be taken out of the note alone")
end)

TestRunner:test("the same answer saved twice is written once", function()
    local r = newReader()
    local sel = selection("/body/p[3].0", "/body/p[3].22")
    HighlightNote.save(r.ui, sel, "The morning rose grey.", { store = r.store })
    local events, saves = #r.events, r.store.saves
    local again = HighlightNote.save(r.ui, sel, "The morning rose grey.  ", { store = r.store })
    ok(again and again.already and not again.created and not again.appended)
    eq(r.list[1].note, "The morning rose grey.")
    eq(#r.events, events, "no event")
    eq(r.store.saves, saves, "no record write")
end)

TestRunner:test("the record: ours as left, the reader's once they rewrite it, nothing without a line", function()
    local r = newReader()
    local saved = HighlightNote.save(r.ui, selection("/body/p[3].0", "/body/p[3].22"), "The morning rose grey.",
        { kind = "translate", store = r.store })
    local state, parts = HighlightNote.recordOf(r.store, saved.annotation)
    eq(state, "ours")
    eq(#parts, 1)
    eq(parts[1].kind, "translate")
    ok(type(parts[1].at) == "number", "when")
    eq(parts[1].text, "The morning rose grey.")
    eq(parts[1].from, 1)
    -- the reader adds a line of their own under it: the piece still stands
    saved.annotation.note = "The morning rose grey.\n\n(ch. 2, my own line)"
    state, parts = HighlightNote.recordOf(r.store, saved.annotation)
    eq(state, "mixed", "their words beside the plugin's")
    eq(parts[1].text, "The morning rose grey.")
    -- the reader rewrites the piece itself: theirs now
    saved.annotation.note = "The morning rose gray, I would say."
    state, parts = HighlightNote.recordOf(r.store, saved.annotation)
    eq(state, "changed")
    eq(#parts, 0)
    eq((HighlightNote.recordOf(r.store, highlightOf(r, "/a", "/b", "mine alone"))), nil, "a note the plugin never wrote")
    eq((HighlightNote.recordOf(nil, saved.annotation)), nil)
    -- nothing of a note's text is in the record
    local dump = {}
    for _stamp, line in pairs(r.store.data[HighlightNote.RECORD_KEY]) do
        for _i, part in ipairs(line.parts) do
            for k, v in pairs(part) do dump[#dump + 1] = k .. "=" .. tostring(v) end
        end
    end
    ok(not table.concat(dump, " "):find("morning", 1, true), "the record holds no word of the note")
end)

TestRunner:test("two answers on one highlight are two pieces: the translation can be taken out alone", function()
    local r = newReader()
    local sel = selection("/body/p[3].0", "/body/p[3].22")
    local first = HighlightNote.save(r.ui, sel, "The morning rose grey.", { kind = "translate", store = r.store })
    HighlightNote.save(r.ui, sel, "Grey here means overcast.", { kind = "chat", store = r.store })
    local state, parts = HighlightNote.recordOf(r.store, first.annotation)
    eq(state, "ours", "every word of the note is the plugin's")
    eq(#parts, 2)
    eq(parts[1].kind, "translate"); eq(parts[1].text, "The morning rose grey.")
    eq(parts[2].kind, "chat"); eq(parts[2].text, "Grey here means overcast.")
    -- the reader rewrites the second piece: the first is still the plugin's translation
    first.annotation.note = "The morning rose grey.\n\nGrey = overcast (mine)."
    state, parts = HighlightNote.recordOf(r.store, first.annotation)
    eq(state, "mixed")
    eq(#parts, 1); eq(parts[1].kind, "translate")
    -- a third answer after that: recorded at its place, the rewritten piece gone from the record
    HighlightNote.save(r.ui, sel, "A third answer.", { kind = "chat", store = r.store })
    state, parts = HighlightNote.recordOf(r.store, first.annotation)
    eq(state, "mixed")
    eq(#parts, 2)
    eq(parts[2].text, "A third answer.")
    eq(#r.store.data[HighlightNote.RECORD_KEY][first.annotation.datetime].parts, 2,
        "the piece the reader rewrote left the record")
end)

TestRunner:test("a line of the first day's shape (no pieces) reads as the reader's, and the next save writes pieces", function()
    local r = newReader()
    local mine = highlightOf(r, "/body/p[3].0", "/body/p[3].22", "An old note.")
    r.store.data[HighlightNote.RECORD_KEY] = { [mine.datetime] = { kind = "translate", at = 1, sum = "12:1" } }
    local state, parts = HighlightNote.recordOf(r.store, mine)
    eq(state, "changed"); eq(#parts, 0)
    HighlightNote.save(r.ui, selection("/body/p[3].0", "/body/p[3].22"), "New.", { kind = "chat", store = r.store })
    state, parts = HighlightNote.recordOf(r.store, mine)
    eq(state, "mixed"); eq(#parts, 1); eq(parts[1].text, "New.")
end)

TestRunner:test("remove: a highlight the save made goes with its note; KOReader's own delete", function()
    local r = newReader()
    local saved = HighlightNote.save(r.ui, selection("/body/p[3].0", "/body/p[3].22"), "The morning rose grey.",
        { kind = "translate", store = r.store })
    eq(saved.text, "The morning rose grey.", "the save says what it wrote")
    local removed = HighlightNote.remove(r.ui, saved, { store = r.store })
    eq(removed, "highlight")
    eq(#r.list, 0)
    eq(r.deleted, 1)
    eq(r.store.data[HighlightNote.RECORD_KEY][saved.annotation.datetime], nil, "its line left the record")
    local again, why = HighlightNote.remove(r.ui, saved, { store = r.store })
    eq(again, nil); eq(why, "gone")
end)

TestRunner:test("remove: the reader's own highlight stays, without the note, as KOReader's Delete note leaves it", function()
    local r = newReader()
    local mine = highlightOf(r, "/body/p[3].0", "/body/p[3].22")
    local saved = HighlightNote.save(r.ui, selection("/body/p[3].0", "/body/p[3].22"), "The morning rose grey.",
        { store = r.store })
    r.events, r.pdf = {}, {}
    eq(HighlightNote.remove(r.ui, saved, { store = r.store }), "note")
    eq(#r.list, 1, "the highlight is the reader's")
    eq(mine.note, nil)
    eq(r.deleted, nil)
    eq(#r.events, 1)
    eq(r.events[1].arg.nb_highlights_added, 1, "a highlight more")
    eq(r.events[1].arg.nb_notes_added, -1, "a note less")
    eq(r.pdf[1].action, "content"); eq(r.pdf[1].content, "")
    eq((HighlightNote.recordOf(r.store, mine)), nil)
end)

TestRunner:test("remove: an answer added under a note leaves, and what was there stays", function()
    local r = newReader()
    local mine = highlightOf(r, "/body/p[3].0", "/body/p[3].22", "why grey?")
    local sel = selection("/body/p[3].0", "/body/p[3].22")
    local first = HighlightNote.save(r.ui, sel, "The morning rose grey.", { kind = "translate", store = r.store })
    local second = HighlightNote.save(r.ui, sel, "Grey here means overcast.", { kind = "chat", store = r.store })
    r.events = {}
    local stamps = r.stamps
    eq(HighlightNote.remove(r.ui, second, { store = r.store }), "note")
    eq(mine.note, "why grey?\n\nThe morning rose grey.")
    eq(#r.events, 0, "it was a note and is one")
    eq(r.stamps, stamps + 1, "the change time is stamped")
    local state, parts = HighlightNote.recordOf(r.store, mine)
    eq(state, "mixed"); eq(#parts, 1); eq(parts[1].kind, "translate")
    -- the first is no longer at the note's end once something follows it: not touched
    HighlightNote.save(r.ui, sel, "A later answer.", { kind = "chat", store = r.store })
    local removed, why = HighlightNote.remove(r.ui, first, { store = r.store })
    eq(removed, nil); eq(why, "changed")
    eq(mine.note, "why grey?\n\nThe morning rose grey.\n\nA later answer.")
end)

TestRunner:test("remove: a note the reader changed since is not touched", function()
    local r = newReader()
    local saved = HighlightNote.save(r.ui, selection("/body/p[3].0", "/body/p[3].22"), "The morning rose grey.",
        { store = r.store })
    saved.annotation.note = "The morning rose grey. My own words now."
    local removed, why = HighlightNote.remove(r.ui, saved, { store = r.store })
    eq(removed, nil); eq(why, "changed")
    eq(#r.list, 1)
    eq(r.list[1].note, "The morning rose grey. My own words now.")
    eq((HighlightNote.remove(nil, saved)), nil)
end)

TestRunner:test("a deleted highlight's line leaves the record at the next save", function()
    local r = newReader()
    local first = HighlightNote.save(r.ui, selection("/body/p[3].0", "/body/p[3].22"), "One.", { store = r.store })
    local stamp = first.annotation.datetime
    ok(r.store.data[HighlightNote.RECORD_KEY][stamp], "recorded")
    table.remove(r.list, 1)
    HighlightNote.save(r.ui, selection("/body/p[5].0", "/body/p[5].9"), "Two.", { store = r.store })
    eq(r.store.data[HighlightNote.RECORD_KEY][stamp], nil)
    local n = 0
    for _k in pairs(r.store.data[HighlightNote.RECORD_KEY]) do n = n + 1 end
    eq(n, 1, "one line, the new note's")
end)

TestRunner:test("a PDF: found by its page and coordinates; a page bookmark on the page is no highlight", function()
    local r = newReader({ paging = true })
    r.list[1] = { page = 4, datetime = "2026-11-01 08:00:00" }  -- a page bookmark: no ends, no style
    local mine = highlightOf(r, { page = 4, x = 10.5, y = 20 }, { page = 4, x = 90, y = 20 })
    highlightOf(r, { page = 4, x = 10.5, y = 60 }, { page = 4, x = 90, y = 60 })
    local saved = HighlightNote.save(r.ui, selection({ page = 4, x = 10.5, y = 20 }, { page = 4, x = 90, y = 20 }), "Note.",
        { extend = true, store = r.store })
    ok(saved and not saved.created, "the reader's highlight of those coordinates")
    eq(saved.annotation, mine)
    eq(#r.list, 3)
    eq(r.extension_asked, 0, "a PDF's selection is never extended")
    local other = HighlightNote.save(r.ui, selection({ page = 4, x = 11, y = 20 }, { page = 4, x = 90, y = 20 }), "Other.",
        { store = r.store })
    ok(other.created, "other coordinates: a highlight of its own")
    eq(#r.list, 4)
end)

TestRunner:test("nothing to save on: said, and nothing written", function()
    local r = newReader()
    local sel = selection("/body/p[3].0", "/body/p[3].22")
    local res, why = HighlightNote.save(nil, sel, "x", {})
    eq(res, nil); eq(why, "no_reader")
    res, why = HighlightNote.save({ highlight = {} }, sel, "x", {})
    eq(why, "no_reader")
    res, why = HighlightNote.save(r.ui, { text = "no ends" }, "x", { store = r.store })
    eq(why, "no_selection")
    res, why = HighlightNote.save(r.ui, sel, "  \n", { store = r.store })
    eq(why, "no_text")
    local none = newReader({ no_highlight = true })
    res, why = HighlightNote.save(none.ui, sel, "x", { store = none.store })
    eq(res, nil); eq(why, "no_highlight")
    eq(none.store.saves, 0)
    eq(#r.list, 0); eq(r.store.saves, 0)
end)

TestRunner:test("a record that cannot be written does not lose the note", function()
    local r = newReader()
    r.store.saveSetting = function() error("disk full") end
    local saved = HighlightNote.save(r.ui, selection("/body/p[3].0", "/body/p[3].22"), "Kept.", { store = r.store })
    ok(saved and saved.created)
    eq(r.list[1].note, "Kept.")
end)

TestRunner:test("edit: KOReader's editor on the passage's own highlight, or a new one as before", function()
    local r = newReader()
    highlightOf(r, "/body/p[3].0", "/body/p[3].22", "why grey?")
    ok(HighlightNote.edit(r.ui, selection("/body/p[3].0", "/body/p[3].22"), "The morning.", { extend = true }))
    eq(#r.edits, 1)
    eq(r.edits[1].index, 1); eq(r.edits[1].is_new, false); eq(r.edits[1].text, "The morning.")
    eq(#r.list, 1, "no second highlight")
    eq(#r.adds, 0)
    -- a new passage: KOReader's own Add note (its extension, its colour question)
    local sel = selection("/body/p[7].0", "/body/p[7].9")
    ok(HighlightNote.edit(r.ui, sel, "New.", { extend = true }))
    eq(#r.adds, 1); eq(r.adds[1].text, "New.")
    ok(r.adds[1].selected ~= sel, "a copy of the selection, never the caller's table")
    eq(r.adds[1].selected.pos0, "/body/p[7].0")
    -- a looked-up word: the word alone, then the editor; Cancel there removes the highlight
    local word = newReader()
    ok(HighlightNote.edit(word.ui, selection("/body/p[1].4", "/body/p[1].11", "lantern"), "A lamp.", { extend = false }))
    eq(word.save_flag, false)
    eq(#word.list, 1)
    eq(word.edits[1].is_new, true); eq(word.edits[1].index, 1)
    eq(#word.adds, 0)
    eq(word.store.saves, 0, "nothing is recorded for a note that goes through the editor")
    local res, why = HighlightNote.edit(word.ui, { text = "no ends" }, "x", {})
    eq(res, nil); eq(why, "no_selection")
end)

-- ── the windows' own saveToNote ─────────────────────────────────────────────
print("\n  the windows (Save to Note, +Note)")

local Recorder = require("ui_recorder")
local ChatGPTViewer = require("koassistant.ui.chatgptviewer")
local ReaderUIMock = {}
package.loaded["apps/reader/readerui"] = ReaderUIMock
local asked_content = {}
local single_answer = false
package.loaded["koassistant.chat.export"] = {
    fromHistory = function() return {} end,
    isSingleAnswer = function() return single_answer end,
    format = function(_data, content) asked_content[#asked_content + 1] = content; return "NOTE:" .. content end,
}
local resolved_store
package.loaded["koassistant.storage.doc_settings"] = {
    resolve = function() return resolved_store end,
}

local function window(r, fields)
    ReaderUIMock.instance = r.ui
    resolved_store = r.store
    asked_content = {}
    single_answer = false
    fields.selection_data = fields.selection_data or selection("/body/p[3].0", "/body/p[3].22")
    fields._message_history = {}
    fields.configuration = fields.configuration or { features = {} }
    return setmetatable(fields, { __index = ChatGPTViewer })
end

local function lastNotice(rec)
    for i = #rec.shown, 1, -1 do
        if rec.shown[i]._widget == "ui/widget/notification" then return rec.shown[i].text end
    end
end

TestRunner:test("noteKind: the dictionary and compact windows, the translate window, a chat", function()
    eq(setmetatable({ configuration = { features = { minimal_buttons = true } } }, { __index = ChatGPTViewer }):noteKind(), "dictionary")
    eq(setmetatable({ translate_view = true, configuration = { features = {} } }, { __index = ChatGPTViewer }):noteKind(), "translate")
    eq(setmetatable({ configuration = { features = {} } }, { __index = ChatGPTViewer }):noteKind(), "chat")
    eq(setmetatable({}, { __index = ChatGPTViewer }):noteKind(), "chat")
end)

TestRunner:test("the translate window: a tap saves the translation at once and the window closes", function()
    local rec = Recorder.install()
    local r = newReader()
    local v = window(r, { translate_view = true })
    UIManager:show(v)
    v:saveToNote()
    local closed = not UIManager:isWidgetShown(v)
    local notice = lastNotice(rec)
    rec:restore()
    eq(#r.list, 1)
    eq(r.list[1].note, "NOTE:response", "the translation only, the setting's default")
    eq(#r.edits + #r.adds, 0, "KOReader's note editor is not opened")
    ok(closed, "the translate window closed")
    eq(notice, "Saved as a note")
    local state, parts = HighlightNote.recordOf(r.store, r.list[1])
    eq(state, "ours"); eq(parts[1].kind, "translate")
end)

TestRunner:test("the chat window: question and response by default, and the window stays", function()
    local rec = Recorder.install()
    local r = newReader()
    local v = window(r, {})
    UIManager:show(v)
    v:saveToNote()
    local shown = UIManager:isWidgetShown(v)
    rec:restore()
    eq(r.list[1].note, "NOTE:qa")
    ok(shown, "a chat is not closed by its note")
    local _state, parts = HighlightNote.recordOf(r.store, r.list[1])
    eq(parts[1].kind, "chat")
end)

TestRunner:test("a dictionary window: the definition only, on the word alone", function()
    local rec = Recorder.install()
    local r = newReader({ extend = function() error("a word is not extended") end })
    local v = window(r, { configuration = { features = { minimal_buttons = true } },
        selection_data = selection("/body/p[1].4", "/body/p[1].11", "lantern") })
    v:saveToNote()
    rec:restore()
    eq(r.list[1].note, "NOTE:response")
    eq(r.list[1].pos1, "/body/p[1].11")
    local _state, parts = HighlightNote.recordOf(r.store, r.list[1])
    eq(parts[1].kind, "dictionary")
end)

TestRunner:test("the content settings are read per kind, Follow global setting included", function()
    local rec = Recorder.install()
    local r = newReader()
    window(r, { translate_view = true, configuration = { features = { translate_note_content = "qa" } } }):saveToNote()
    eq(asked_content[1], "qa")
    r = newReader()
    window(r, { translate_view = true,
        configuration = { features = { translate_note_content = "global", note_content = "full" } } }):saveToNote()
    eq(asked_content[1], "full")
    r = newReader()
    window(r, { configuration = { features = { minimal_buttons = true, dictionary_note_content = "full" } } }):saveToNote()
    eq(asked_content[1], "full")
    rec:restore()
end)

TestRunner:test("a passage that is already a highlight: said so, and one highlight", function()
    local rec = Recorder.install()
    local r = newReader()
    highlightOf(r, "/body/p[3].0", "/body/p[3].22")
    window(r, { translate_view = true }):saveToNote()
    local notice = lastNotice(rec)
    eq(#r.list, 1)
    eq(notice, "Added to the highlight's note")
    -- and the same answer once more
    window(r, { translate_view = true }):saveToNote()
    notice = lastNotice(rec)
    rec:restore()
    eq(r.list[1].note, "NOTE:response")
    eq(notice, "Already in this highlight's note")
end)

TestRunner:test("a hold asks what the note holds, and saves the pick at once", function()
    local rec = Recorder.install()
    local r = newReader()
    local v = window(r, { translate_view = true })
    v:saveToNote(true)
    local rows = table.concat(rec:texts(), " | ")
    eq(#r.list, 0, "nothing is saved before the pick")
    rec:tap("Question + Response")
    rec:restore()
    eq(rows, "Full (metadata + chat) | Question + Response | Translation only | Everything (debug) | Edit before saving… | Cancel")
    eq(r.list[1].note, "NOTE:qa")
    eq(#r.edits + #r.adds, 0)
end)

TestRunner:test("Edit before saving…: KOReader's note editor, the window's default content, nothing recorded", function()
    local rec = Recorder.install()
    local r = newReader()
    local v = window(r, { translate_view = true })
    UIManager:show(v)
    v:saveToNote(true)
    rec:tap("Edit before saving…")
    local closed = not UIManager:isWidgetShown(v)
    rec:restore()
    eq(#r.adds, 1, "KOReader's Add note")
    eq(r.adds[1].text, "NOTE:response")
    ok(closed, "the translate window closes: the editor opens over the page")
    eq(r.store.saves, 0)
end)

TestRunner:test("Ask every time: a tap asks, and the editor row takes the kind's own default", function()
    local rec = Recorder.install()
    local r = newReader()
    local v = window(r, { configuration = { features = { note_content = "ask" } } })
    v:saveToNote()
    ok(rec:has("Last response only"), "the picker, a chat's wording")
    eq(#r.list, 0)
    rec:tap("Edit before saving…")
    rec:restore()
    eq(r.adds[1].text, "NOTE:qa")
end)

TestRunner:test("no selection, no book, no chat: said, nothing written", function()
    local rec = Recorder.install()
    local r = newReader()
    local v = window(r, {})
    v.selection_data = nil
    v:saveToNote()
    eq(lastNotice(rec), "No highlight selection data available")
    v = window(r, {})
    ReaderUIMock.instance = nil
    v:saveToNote()
    eq(lastNotice(rec), "No document open")
    v = window(r, {})
    v._message_history = nil
    v:saveToNote()
    eq(lastNotice(rec), "No response to save")
    rec:restore()
    eq(#r.list, 0)
end)

TestRunner:test("a chat that is one answer with nothing typed: Question + Response is the answer", function()
    local rec = Recorder.install()
    local r = newReader()
    local v = window(r, {})
    single_answer = true
    v:saveToNote()
    eq(r.list[1].note, "NOTE:response", "no question to put beside it")
    -- a typed question or a second exchange: the questions and answers as before
    r = newReader()
    v = window(r, {})
    v:saveToNote()
    rec:restore()
    eq(r.list[1].note, "NOTE:qa")
end)

TestRunner:test("keepAsNote: the save with no notice and no window closed; Ask every time takes the kind's default", function()
    local rec = Recorder.install()
    local r = newReader()
    local v = window(r, { translate_view = true })
    UIManager:show(v)
    ok(v:canKeepNote())
    local saved = v:keepAsNote()
    ok(saved and saved.created)
    eq(r.list[1].note, "NOTE:response")
    eq(lastNotice(rec), nil, "no notice")
    ok(UIManager:isWidgetShown(v), "nothing closed")
    r = newReader()
    v = window(r, { configuration = { features = { note_content = "ask" } } })
    v:keepAsNote()
    eq(r.list[1].note, "NOTE:qa", "nobody to ask: a chat's own default")
    v = window(r, {})
    v.selection_data = nil
    eq(v:canKeepNote(), false)
    local none, why = v:keepAsNote()
    eq(none, nil); eq(why, "No highlight selection data available")
    rec:restore()
end)

TestRunner:test("dropNote: the kept answer leaves; a note changed since is said and stays", function()
    local rec = Recorder.install()
    local r = newReader()
    local v = window(r, { translate_view = true })
    local saved = v:keepAsNote()
    eq(v:dropNote(saved), true)
    eq(#r.list, 0, "the highlight the save made is gone")
    eq(v:dropNote(saved), true, "already gone: nothing kept")
    saved = v:keepAsNote()
    r.list[1].note = r.list[1].note .. " and my own words"
    eq(v:dropNote(saved), false)
    local notice = lastNotice(rec)
    rec:restore()
    eq(#r.list, 1)
    eq(notice, "The note has changed since. Remove it from the highlight's own menu.")
end)

TestRunner:test("from the popup: a save says nothing and closes nothing, and hands the result over", function()
    local rec = Recorder.install()
    local r = newReader()
    local v = window(r, { translate_view = true })
    UIManager:show(v)
    local got
    v:saveToNote(false, { popup = true, on_saved = function(saved) got = saved end })
    ok(got and got.created, "the popup gets the save's result")
    eq(lastNotice(rec), nil, "the popup's own tick says it")
    ok(UIManager:isWidgetShown(v))
    -- a hold from the popup: the caller's rows under a double line, and its close before the editor
    local closed = 0
    local flipped = 0
    v:saveToNote(true, {
        popup = true,
        before_edit = function() closed = closed + 1 end,
        extra = { { separator = true }, { text = "Save every Translate answer", callback = function() flipped = flipped + 1 end } },
    })
    local top = rec:top()
    eq(#top.buttons, 8, "four content rows, the editor row, the double line, the setting row, Cancel")
    eq(#top.buttons[6], 0, "the double line: an empty row")
    rec:tap("Save every Translate answer")
    eq(flipped, 1)
    v:saveToNote(true, { popup = true, before_edit = function() closed = closed + 1 end })
    rec:tap("Edit before saving…")
    rec:restore()
    eq(closed, 1, "the popup closes before KOReader's editor opens")
    eq(#r.adds + #r.edits, 1)
end)

-- ── guards ──────────────────────────────────────────────────────────────────
print("\n  guards")

local function slurp(path)
    local f = assert(io.open(path, "r"))
    local s = f:read("*a")
    f:close()
    return s
end

local function luaFiles()
    local files = { PLUGIN_DIR .. "/main.lua" }
    local p = io.popen("find '" .. PLUGIN_DIR .. "/koassistant' -name '*.lua'")
    for line in p:lines() do files[#files + 1] = line end
    p:close()
    return files
end

TestRunner:test("one writer: no other file makes a highlight or opens KOReader's note editor", function()
    local offenders = {}
    for _i, path in ipairs(luaFiles()) do
        if not path:find("koassistant/chat/highlight_note.lua", 1, true) then
            local n = 0
            for line in (slurp(path) .. "\n"):gmatch("(.-)\n") do
                n = n + 1
                local code = line:gsub("%-%-.*$", "")
                if code:find(":saveHighlight%(") or code:find(":addNote%(") or code:find(":editNote%(")
                        or code:find("annotation%.note%s*=[^=]") then
                    offenders[#offenders + 1] = path:sub(#PLUGIN_DIR + 2) .. ":" .. n
                end
            end
        end
    end
    eq(table.concat(offenders, ", "), "", "these write a highlight or a note themselves")
end)

TestRunner:test("the three buttons share the hold: Save to Note twice, +Note once", function()
    local src = slurp(PLUGIN_DIR .. "/koassistant/ui/chatgptviewer.lua")
    local holds = select(2, src:gsub("self:saveToNote%(true%)", ""))
    local taps = select(2, src:gsub("self:saveToNote%(%)", ""))
    eq(holds, 3, "a hold on each button asks")
    eq(taps, 3, "a tap on each button saves")
end)

-- ── put everything back ─────────────────────────────────────────────────────
for name, mod in pairs(SAVED) do package.loaded[name] = mod end
for _i, name in ipairs({ "ui/event", "apps/reader/readerui", "koassistant.chat.export",
        "koassistant.storage.doc_settings" }) do
    if SAVED[name] == nil then package.loaded[name] = nil end
end
UIManager.setDirty = saved_setDirty

print("")
print(string.format("  Results: %d passed, %d failed", TestRunner.passed, TestRunner.failed))
return TestRunner.failed == 0
