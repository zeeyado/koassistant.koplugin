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
    local r = { events = {}, pdf = {}, edits = {}, adds = {}, cleared = 0, stamps = 0, clock = 0, extension_asked = 0,
        prompts = 0 }
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
            r.selected_at_save = st
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
    if not opts.old_koreader then
        -- ReaderHighlight:showHighlightPrompt, in short: the reader's question
        -- about the highlight's style where they have one set (hold_prompt:
        -- it stays open until answered), then the highlight as Add note makes
        -- it and the caller's function
        ui.highlight.showHighlightPrompt = function(self, caller_callback)
            r.prompts = r.prompts + 1
            local function answered()
                local index = self:saveHighlight(true)
                self:clear()
                if caller_callback then caller_callback(index) end
            end
            if opts.hold_prompt then r.answer_prompt = answered else answered() end
        end
    end
    -- ReaderBookmark:setBookmarkNote, in short: KOReader's note editor is open
    -- on the highlight, the new text under the note it has. `save(value)` is
    -- its Save (nil = as filled in; a blank input deletes the note): the
    -- note, the PDF's copy, the event that counts or the change time, then the
    -- caller's function. `cancel()` is its Cancel: a highlight made for the
    -- note goes, and nothing is called.
    ui.bookmark = {
        setBookmarkNote = function(_self, index, is_new, text, caller_callback)
            local item = ui.annotation.annotations[index]
            local input = item.note
            if text then input = input and (input .. "\n\n" .. text) or text end
            r.edits[#r.edits + 1] = {
                index = index, is_new = is_new, text = text, input = input,
                save = function(value)
                    if value == nil then value = input end
                    local was_note = item.note ~= nil
                    item.note = value ~= "" and value or nil
                    ui.highlight:writePdfAnnotation("content", item, item.note or "")
                    if was_note ~= (item.note ~= nil) then
                        ui:handleEvent(require("ui/event"):new("AnnotationsModified", { item,
                            nb_highlights_added = was_note and 1 or -1, nb_notes_added = was_note and -1 or 1 }))
                    else
                        ui.annotation:onAnnotationsModified({ item })
                    end
                    if caller_callback then caller_callback() end
                end,
                cancel = function()
                    if is_new then table.remove(ui.annotation.annotations, index) end
                end,
            }
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

TestRunner:test("the record keeps the action a piece came from, its id and its name, through later saves", function()
    local r = newReader()
    local sel = selection("/body/p[3].0", "/body/p[3].22")
    local first = HighlightNote.save(r.ui, sel, "The morning rose grey.",
        { kind = "translate", action = "translate", action_name = "Translate", store = r.store })
    HighlightNote.save(r.ui, sel, "Explain:\nGrey here means overcast.",
        { kind = "chat", action = "explain", action_name = "Explain", lead = #"Explain:\n", store = r.store })
    local _state, parts = HighlightNote.recordOf(r.store, first.annotation)
    eq(#parts, 2)
    eq(parts[1].action, "translate"); eq(parts[1].action_name, "Translate")
    eq(parts[1].lead, nil, "a save that says nothing of it: no field")
    eq(parts[2].action, "explain"); eq(parts[2].action_name, "Explain")
    eq(parts[2].text, "Explain:\nGrey here means overcast.", "a piece is the text as saved, its own first line included")
    eq(parts[2].text:sub(parts[2].lead + 1), "Grey here means overcast.", "and the record says where the answer starts in it")
    eq(r.store.data[HighlightNote.RECORD_KEY][first.annotation.datetime].parts[2].lead, #"Explain:\n")
    eq(r.store.data[HighlightNote.RECORD_KEY][first.annotation.datetime].parts[1].action, "translate",
        "the first piece keeps its action when the line is written again")
    -- a save that names none, or names it with something that is no name: no field
    local other = HighlightNote.save(r.ui, selection("/body/p[5].0", "/body/p[5].9"), "A bare answer.",
        { kind = "chat", action = "", action_name = 7, lead = 0, store = r.store })
    _state, parts = HighlightNote.recordOf(r.store, other.annotation)
    eq(parts[1].kind, "chat")
    eq(parts[1].action, nil); eq(parts[1].action_name, nil)
    eq(parts[1].lead, 0, "a piece that is the answer alone says so")
    -- a start that cannot be one (past the text, below zero, no number) is not recorded
    for _i, bad in ipairs({ 99, -1, "3" }) do
        local r2 = newReader()
        local s2 = HighlightNote.save(r2.ui, sel, "Short.", { kind = "chat", lead = bad, store = r2.store })
        local _s, p2 = HighlightNote.recordOf(r2.store, s2.annotation)
        eq(p2[1].lead, nil, tostring(bad))
    end
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

TestRunner:test("edit: KOReader's editor on the passage's own highlight, or a new one as its Add note makes it", function()
    local r = newReader()
    highlightOf(r, "/body/p[3].0", "/body/p[3].22", "why grey?")
    ok(HighlightNote.edit(r.ui, selection("/body/p[3].0", "/body/p[3].22"), "The morning.\n", { extend = true, store = r.store }))
    eq(#r.edits, 1)
    eq(r.edits[1].index, 1); eq(r.edits[1].is_new, false)
    eq(r.edits[1].text, "The morning.", "as a save at once trims it")
    eq(r.edits[1].input, "why grey?\n\nThe morning.", "under the note the highlight has")
    eq(#r.list, 1, "no second highlight")
    eq(r.prompts, 0, "no highlight to make, no question")
    -- a new passage: KOReader's own Add note step for step (its question, its extension), then the editor
    local sel = selection("/body/p[7].0", "/body/p[7].9")
    ok(HighlightNote.edit(r.ui, sel, "New.", { extend = true, store = r.store }))
    eq(r.prompts, 1, "KOReader's question about the highlight's style comes first, where the reader has one")
    eq(r.save_flag, true, "the passage as Add note saves it")
    ok(r.selected_at_save ~= sel, "a copy of the selection, never the caller's table")
    eq(r.selected_at_save.pos0, "/body/p[7].0")
    eq(#r.list, 2)
    eq(r.edits[2].is_new, true); eq(r.edits[2].index, 2); eq(r.edits[2].text, "New.")
    eq(r.ui.highlight.selected_text, nil, "the copy of the selection is taken back out")
    eq(#r.adds, 0, "not through KOReader's addNote, whose Save cannot be heard")
    -- Cancel in the editor: the highlight made for the note goes, and nothing was recorded
    r.edits[2].cancel()
    eq(#r.list, 1)
    eq(r.store.saves, 0, "nothing is recorded before the editor's Save")
    -- while KOReader's own question is open, nothing is made
    local asked = newReader({ hold_prompt = true })
    ok(HighlightNote.edit(asked.ui, selection("/body/p[7].0", "/body/p[7].9"), "New.", { extend = true, store = asked.store }))
    eq(#asked.list, 0); eq(#asked.edits, 0)
    asked.answer_prompt()
    eq(#asked.list, 1); eq(#asked.edits, 1)
    -- a looked-up word: the word alone, no question, then the editor
    local word = newReader()
    ok(HighlightNote.edit(word.ui, selection("/body/p[1].4", "/body/p[1].11", "lantern"), "A lamp.", { extend = false, store = word.store }))
    eq(word.save_flag, false)
    eq(word.prompts, 0)
    eq(#word.list, 1)
    eq(word.edits[1].is_new, true); eq(word.edits[1].index, 1)
    -- a KOReader from before the question: its Add note of then
    local older = newReader({ old_koreader = true })
    ok(HighlightNote.edit(older.ui, selection("/body/p[7].0", "/body/p[7].9"), "New.", { extend = true, store = older.store }))
    eq(older.save_flag, true); eq(#older.list, 1); eq(older.edits[1].is_new, true)
    -- nothing to make a highlight from
    local res, why = HighlightNote.edit(word.ui, { text = "no ends" }, "x", {})
    eq(res, nil); eq(why, "no_selection")
    local none = newReader({ no_highlight = true, old_koreader = true })
    res, why = HighlightNote.edit(none.ui, selection("/body/p[7].0", "/body/p[7].9"), "x", { extend = true, store = none.store })
    eq(res, nil); eq(why, "no_highlight")
    eq(#none.edits, 0)
    local quiet = newReader({ no_highlight = true })
    ok(HighlightNote.edit(quiet.ui, selection("/body/p[7].0", "/body/p[7].9"), "x", { extend = true, store = quiet.store }))
    eq(#quiet.edits, 0, "KOReader's question made no highlight: no editor, no error")
end)

TestRunner:test("Edit before saving, saved as proposed: recorded and formatted as a save at once", function()
    local r = newReader()
    ok(HighlightNote.edit(r.ui, selection("/body/p[3].0", "/body/p[3].22"), "Explain:\n\n**Awake** here.",
        { extend = true, kind = "chat", action = "explain", action_name = "Explain", chat = "c1", lead = 10, store = r.store }))
    eq(r.store.saves, 0, "nothing before the Save")
    dirty = {}
    r.edits[1].save()
    local item = r.list[1]
    eq(item.note, "Explain:\n\n**Awake** here.")
    local state, parts = HighlightNote.recordOf(r.store, item)
    eq(state, "ours"); eq(#parts, 1)
    eq(parts[1].kind, "chat"); eq(parts[1].action, "explain"); eq(parts[1].action_name, "Explain")
    eq(parts[1].chat, "c1"); eq(parts[1].lead, 10)
    eq(item.note_format, "md", "the format is named, as for a save at once")
    eq(countEvents(r, 1), 1, "the editor's own event, and no second one from the plugin")
    eq(#dirty, 1, "the page is drawn again for the note's mark")
    -- a translation through the editor: recorded, and plain text as a saved translation is
    local t = newReader()
    ok(HighlightNote.edit(t.ui, selection("/body/p[3].0", "/body/p[3].22"), "Le matin se leva gris.",
        { extend = true, kind = "translate", action = "translate", store = t.store }))
    t.edits[1].save()
    state, parts = HighlightNote.recordOf(t.store, t.list[1])
    eq(state, "ours"); eq(parts[1].action, "translate")
    eq(t.list[1].note_format, nil)
end)

TestRunner:test("Edit before saving, changed in the editor: what stands is the plugin's, the rest the reader's, the note formatted", function()
    local r = newReader()
    ok(HighlightNote.edit(r.ui, selection("/body/p[3].0", "/body/p[3].22"), "Explain:\n\n**Awake** here.",
        { extend = true, kind = "chat", store = r.store }))
    r.edits[1].save(r.edits[1].input .. "\n\nmy own line\nand another")
    local item = r.list[1]
    local state, parts = HighlightNote.recordOf(r.store, item)
    eq(state, "mixed"); eq(#parts, 1); eq(parts[1].text, "Explain:\n\n**Awake** here.")
    eq(item.note_format, "md", "decided as for a save at once, whatever the reader added")
    -- the answer itself rewritten in the editor: the note is the reader's, and still drawn
    local w = newReader()
    ok(HighlightNote.edit(w.ui, selection("/body/p[3].0", "/body/p[3].22"), "Explain:\n\n**Awake** here.",
        { extend = true, kind = "chat", store = w.store }))
    w.edits[1].save("Explain:\n\n**Awake** here, I think.")
    state, parts = HighlightNote.recordOf(w.store, w.list[1])
    eq(state, "changed"); eq(#parts, 0)
    eq(w.list[1].note_format, "md")
    -- a blank editor saved: no note, nothing recorded, no mark
    local b = newReader()
    ok(HighlightNote.edit(b.ui, selection("/body/p[3].0", "/body/p[3].22"), "Explain:\n\nIt was early.",
        { extend = true, kind = "chat", store = b.store }))
    b.edits[1].save("")
    eq(b.list[1].note, nil)
    eq(b.list[1].note_format, nil)
    eq(b.store.data[HighlightNote.RECORD_KEY], nil)
    -- a record that cannot be written does not lose the note
    local full = newReader()
    full.store.saveSetting = function() error("disk full") end
    ok(HighlightNote.edit(full.ui, selection("/body/p[3].0", "/body/p[3].22"), "Kept.", { extend = true, kind = "chat", store = full.store }))
    full.edits[1].save()
    eq(full.list[1].note, "Kept.")
end)

TestRunner:test("Edit before saving on a highlight that has a note: recorded where the editor put it; the reader's own note keeps its look", function()
    local r = newReader()
    local mine = highlightOf(r, "/body/p[3].0", "/body/p[3].22", "why grey?")
    ok(HighlightNote.edit(r.ui, selection("/body/p[3].0", "/body/p[3].22"), "Explain:\n\nIt was early.",
        { extend = true, kind = "chat", store = r.store }))
    r.edits[1].save()
    eq(mine.note, "why grey?\n\nExplain:\n\nIt was early.")
    local state, parts = HighlightNote.recordOf(r.store, mine)
    eq(state, "mixed"); eq(parts[1].from, #"why grey?" + 3)
    eq(mine.note_format, nil, "a note the reader had first is not restyled, as with a save at once")
    -- on the plugin's own translation: the explanation names the format as a save at once does,
    -- a line of the reader's typed in the editor or not
    local t = newReader()
    local sel = selection("/body/p[3].0", "/body/p[3].22")
    local kept = HighlightNote.save(t.ui, sel, "Le matin se leva gris.", { kind = "translate", store = t.store })
    eq(kept.annotation.note_format, nil)
    ok(HighlightNote.edit(t.ui, sel, "Explain:\n\nIt was early.", { extend = true, kind = "chat", store = t.store }))
    t.edits[1].save(t.edits[1].input .. "\n\nmine")
    eq(kept.annotation.note_format, "md")
    state, parts = HighlightNote.recordOf(t.store, kept.annotation)
    eq(state, "mixed"); eq(#parts, 2, "the translation and the explanation both stand")
end)

-- ── what KOReader is told of the note, and which notes open in the popup ─────
print("\n  the note's format for KOReader, and the popup on a kept passage")

TestRunner:test("wantsMarkdown: a note that is ours alone and holds an answer written in Markdown", function()
    local chat = { kind = "chat", text = "Explain:\n\n**Awake** here." }
    local dict = { kind = "dictionary", text = "**lantern** (n.)" }
    local line = { kind = "translate", text = "Le matin se leva gris." }
    local lines = { kind = "translate", text = "Premier paragraphe.\nDeuxième paragraphe." }
    local apart = { kind = "translate", text = "Premier paragraphe.\n\nDeuxième paragraphe." }
    eq(HighlightNote.wantsMarkdown("ours", { chat }), true)
    eq(HighlightNote.wantsMarkdown("ours", { dict }), true)
    eq(HighlightNote.wantsMarkdown("ours", { line }), false, "a translation alone is plain text: KOReader's small window")
    eq(HighlightNote.wantsMarkdown("ours", { line, chat }), true, "a translation and an explanation")
    eq(HighlightNote.wantsMarkdown("ours", { lines, chat }), false, "Markdown would run the translation's lines together")
    eq(HighlightNote.wantsMarkdown("ours", { apart, chat }), true, "paragraphs a blank line apart are safe")
    eq(HighlightNote.wantsMarkdown("mixed", { chat }), false,
        "not named for a note that has the reader's words in it (a mark set before stays: keepFormat)")
    eq(HighlightNote.wantsMarkdown("changed", {}), false)
    eq(HighlightNote.wantsMarkdown(nil, {}), false)
    eq(HighlightNote.wantsMarkdown("ours", nil), false)
end)

TestRunner:test("a saved chat answer: the note's format is named for KOReader, and the record says who named it", function()
    local r = newReader()
    local sel = selection("/body/p[3].0", "/body/p[3].22")
    local saved = HighlightNote.save(r.ui, sel, "Explain:\n\n**Awake** here.", { kind = "chat", store = r.store })
    eq(saved.annotation.note_format, "md")
    eq(r.store.data[HighlightNote.RECORD_KEY][saved.annotation.datetime].md, true)
    -- a translation alone names none
    local t = newReader()
    local kept = HighlightNote.save(t.ui, sel, "Le matin se leva gris.", { kind = "translate", store = t.store })
    eq(kept.annotation.note_format, nil)
    eq(t.store.data[HighlightNote.RECORD_KEY][kept.annotation.datetime].md, nil)
    -- an explanation kept on the same passage after it: named now, and kept through later saves
    HighlightNote.save(t.ui, sel, "Explain:\n\nIt was early.", { kind = "chat", store = t.store })
    eq(kept.annotation.note_format, "md")
    HighlightNote.save(t.ui, sel, "Une autre.", { kind = "translate", store = t.store })
    eq(kept.annotation.note_format, "md")
    eq(t.store.data[HighlightNote.RECORD_KEY][kept.annotation.datetime].md, true, "the mark rides the record's line through a save")
    -- a dictionary answer on a word
    local d = newReader()
    local word = HighlightNote.save(d.ui, selection("/body/p[1].4", "/body/p[1].11", "lantern"), "**lantern** (n.): a lamp.",
        { kind = "dictionary", store = d.store })
    eq(word.annotation.note_format, "md")
end)

TestRunner:test("the format stays through what the reader changes; it goes when the answer or the note does", function()
    local r = newReader()
    local sel = selection("/body/p[3].0", "/body/p[3].22")
    local first = HighlightNote.save(r.ui, sel, "Le matin se leva gris.", { kind = "translate", store = r.store })
    local second = HighlightNote.save(r.ui, sel, "Explain:\n\nIt was early.", { kind = "chat", store = r.store })
    local item = first.annotation
    eq(item.note_format, "md")
    -- the explanation taken back out by the plugin: a translation alone again
    eq(HighlightNote.remove(r.ui, second, { store = r.store }), "note")
    eq(item.note_format, nil)
    eq(r.store.data[HighlightNote.RECORD_KEY][item.datetime].md, nil)
    -- kept again, then the reader writes lines of their own under it (KOReader's editor: no word reaches the plugin)
    HighlightNote.save(r.ui, sel, "Explain:\n\nIt was early.", { kind = "chat", store = r.store })
    eq(item.note_format, "md")
    local ours = item.note
    item.note = ours .. "\n\nmy own line\nand another"
    eq((HighlightNote.recordOf(r.store, item)), "mixed")
    eq(HighlightNote.keepFormat(r.store, item), nil, "asked when the passage is tapped: nothing to change")
    eq(item.note_format, "md", "an answer does not lose its formatting to a line added under it")
    eq(r.store.data[HighlightNote.RECORD_KEY][item.datetime].md, true)
    -- the answer itself rewritten: the note is the reader's now, and still Markdown
    item.note = "Explain:\n\nIt was early, I think."
    eq((HighlightNote.recordOf(r.store, item)), "changed")
    eq(HighlightNote.keepFormat(r.store, item), nil)
    eq(item.note_format, "md")
    -- the field lost on the way (KOReader built the item again): the record still says it, and it is named again
    item.note_format = nil
    eq(HighlightNote.keepFormat(r.store, item), "set")
    eq(item.note_format, "md")
    -- the reader deletes the note in KOReader's window: the mark goes with it
    item.note = nil
    eq(HighlightNote.keepFormat(r.store, item), "cleared")
    eq(item.note_format, nil)
    -- and a note they write there later is shown as they write it
    item.note = "a note of my own, later\nin two lines"
    eq(HighlightNote.keepFormat(r.store, item), nil)
    eq(item.note_format, nil)
end)

TestRunner:test("the one answer of a note taken back out: the format's mark and the record's line leave with it", function()
    local r = newReader()
    local mine = highlightOf(r, "/body/p[3].0", "/body/p[3].22")
    local saved = HighlightNote.save(r.ui, selection("/body/p[3].0", "/body/p[3].22"), "Explain:\n\nIt was early.",
        { kind = "chat", store = r.store })
    eq(mine.note_format, "md")
    eq(HighlightNote.remove(r.ui, saved, { store = r.store }), "note")
    eq(mine.note, nil)
    eq(mine.note_format, nil, "a note the reader writes there later is shown as they wrote it")
    eq(r.store.data[HighlightNote.RECORD_KEY][mine.datetime], nil)
end)

TestRunner:test("a format the plugin did not name is never touched; a note without a record is left alone", function()
    local r = newReader()
    local sel = selection("/body/p[3].0", "/body/p[3].22")
    local mine = highlightOf(r, "/body/p[3].0", "/body/p[3].22")
    mine.note_format = "html"   -- another tool's
    HighlightNote.save(r.ui, sel, "Explain:\n\nIt was early.", { kind = "chat", store = r.store })
    eq(mine.note_format, "html")
    eq(r.store.data[HighlightNote.RECORD_KEY][mine.datetime].md, nil, "not ours to take back")
    mine.note = "all my own words now"
    eq(HighlightNote.keepFormat(r.store, mine), nil)
    eq(mine.note_format, "html")
    -- a highlight the plugin never wrote on
    local other = highlightOf(r, "/body/p[9].0", "/body/p[9].5", "* a list of my own")
    other.note_format = "md"
    eq(HighlightNote.keepFormat(r.store, other), nil)
    eq(other.note_format, "md")
    eq(HighlightNote.keepFormat(nil, other), nil)
    eq(HighlightNote.keepFormat(r.store, nil), nil)
end)

TestRunner:test("popupParts: every note the plugin saved an answer in, whatever action made it and however new answers are shown", function()
    local t = { kind = "translate", action = "translate", text = "Le matin." }
    local q = { kind = "chat", action = "quick_explain", text = "Quick Explain:\n\nEarly." }
    local e = { kind = "chat", action = "explain", text = "Explain:\n\nEarly." }
    local old = { kind = "translate", text = "Saved before the action was recorded." }
    local corrected = { kind = "translate", action = "translate" }   -- on record, no longer standing as it was saved
    local f = {}
    ok(HighlightNote.popupParts({ t }, f), "a translation")
    eq(#HighlightNote.popupParts({ t, q }, f), 2, "the whole note")
    eq(#HighlightNote.popupParts({ t, e }, f), 2, "an explanation too: its new answers open in a chat window, a saved one here")
    ok(HighlightNote.popupParts({ old }, f), "an answer saved before its action was recorded")
    ok(HighlightNote.popupParts({ corrected }, f), "an answer the reader corrected is still a saved answer's note")
    eq(HighlightNote.popupParts({}, f), nil, "the plugin saved nothing in this note: KOReader's window")
    eq(HighlightNote.popupParts(nil, f), nil)
    -- how a NEW answer arrives does not decide where a saved one is shown
    ok(HighlightNote.popupParts({ t }, { minimal_popup_actions = { "explain" } }), "Translate taken off the popup's list")
    ok(HighlightNote.popupParts({ t }, { minimal_popup_mode = "off" }), "the popup off for new answers")
    ok(HighlightNote.popupParts({ t }, { minimal_popup_mode = "always" }))
    eq(HighlightNote.popupParts({ t }, { kept_answer_popup = false }), nil, "the reader's switch")
    ok(HighlightNote.popupParts({ t }, nil), "no settings: the defaults")
end)

TestRunner:test("the record keeps what answered, the model and the provider, through later saves", function()
    local r = newReader()
    local sel = selection("/body/p[3].0", "/body/p[3].22")
    local first = HighlightNote.save(r.ui, sel, "Le matin se leva gris.", { kind = "translate", action = "translate",
        action_name = "Translate", model = "small-model", provider = "acme", store = r.store })
    HighlightNote.save(r.ui, sel, "Explain:\n\nEarly.", { kind = "chat", action = "explain", action_name = "Explain",
        model = "large-model", provider = "", store = r.store })
    local pieces = HighlightNote.piecesOf(r.store, first.annotation)
    eq(#pieces, 2)
    eq(pieces[1].model, "small-model")
    eq(pieces[1].provider, "acme")
    eq(pieces[2].model, "large-model")
    eq(pieces[2].provider, nil, "an empty name is no name")
    local _state, standing = HighlightNote.recordOf(r.store, first.annotation)
    eq(standing[1].model, "small-model", "the standing pieces carry it too")
    -- a save with neither (an answer of before): the piece is recorded all the same
    local other = HighlightNote.save(r.ui, selection("/body/p[5].0", "/body/p[5].9"), "Un mot.", { kind = "translate", store = r.store })
    eq(HighlightNote.piecesOf(r.store, other.annotation)[1].model, nil)
end)

TestRunner:test("sourceText: where a note's answers came from, a line each", function()
    local day = os.time({ year = 2026, month = 11, day = 24, hour = 12 })
    eq(HighlightNote.sourceText({ { kind = "translate", action_name = "Translate", model = "small-model", at = day } }),
        "Translate · small-model · 2026-11-24")
    eq(HighlightNote.sourceText({ { kind = "dictionary", at = day } }), "Dictionary answer · 2026-11-24",
        "no action on record: the kind of answer; no model: none shown")
    eq(HighlightNote.sourceText({ { kind = "translate" } }), "Translation")
    eq(HighlightNote.sourceText({ { kind = "chat", action_name = "" } }), "AI answer", "an empty name is no name")
    eq(HighlightNote.sourceText({
        { kind = "translate", action_name = "Translate", model = "small-model", at = day },
        { kind = "chat", action_name = "Explain", model = "large-model", at = day },
    }), "Translate · small-model · 2026-11-24\nExplain · large-model · 2026-11-24")
    eq(HighlightNote.sourceText({
        { kind = "translate", action_name = "Translate", model = "small-model", at = day },
        { kind = "translate", action_name = "Translate", model = "small-model", at = day },
    }), "Translate · small-model · 2026-11-24", "the same line is said once")
    eq(HighlightNote.sourceText({}), nil)
    eq(HighlightNote.sourceText(nil), nil)
end)

TestRunner:test("KOReader's note buttons, done by the writer: Edit note opens KOReader's editor on the highlight where it stands", function()
    local r = newReader()
    highlightOf(r, "/body/p[1].0", "/body/p[1].4", "an earlier highlight")
    local saved = HighlightNote.save(r.ui, selection("/body/p[3].0", "/body/p[3].22"), "Le matin se leva gris.",
        { kind = "translate", action = "translate", store = r.store })
    eq(HighlightNote.editExisting(r.ui, saved.annotation), true)
    eq(#r.edits, 1)
    eq(r.edits[1].index, 2, "the highlight's own place")
    eq(r.edits[1].text, nil, "nothing filled in: the note as it is")
    -- the reader deletes a highlight before it: the place is read again
    table.remove(r.list, 1)
    HighlightNote.editExisting(r.ui, saved.annotation)
    eq(r.edits[2].index, 1)
    local gone, why = HighlightNote.editExisting(r.ui, { datetime = "nobody's" })
    eq(gone, nil)
    eq(why, "gone")
    eq(select(2, HighlightNote.editExisting(nil, saved.annotation)), "no_reader")
end)

TestRunner:test("Delete note: the note leaves as KOReader's button leaves it, and the plugin's record and format mark go with it", function()
    local r = newReader()
    local saved = HighlightNote.save(r.ui, selection("/body/p[3].0", "/body/p[3].22"), "Explain:\n\n**Early** she was up.",
        { kind = "chat", action = "explain", store = r.store })
    local item = saved.annotation
    eq(item.note_format, "md", "named by the plugin at the save")
    eq(HighlightNote.deleteNote(r.ui, item, { store = r.store }), true)
    eq(item.note, nil)
    eq(#r.list, 1, "the highlight stays")
    eq(countEvents(r, -1), 1, "one note less, one highlight more: KOReader's own event")
    eq(r.pdf[#r.pdf].action, "content")
    eq(r.pdf[#r.pdf].content, "", "the PDF's copy of the note emptied")
    eq(item.note_format, nil, "the plugin's mark goes with the note")
    eq(r.store.data[HighlightNote.RECORD_KEY][item.datetime], nil, "and its line")
    eq(HighlightNote.piecesOf(r.store, item), nil, "a note the reader writes there later is theirs alone")
    eq(select(2, HighlightNote.deleteNote(r.ui, { datetime = "nobody's" }, { store = r.store })), "gone")
end)

TestRunner:test("Delete highlight: KOReader's own delete, then the record's line", function()
    local r = newReader()
    local kept = HighlightNote.save(r.ui, selection("/body/p[3].0", "/body/p[3].22"), "Le matin se leva gris.",
        { kind = "translate", action = "translate", store = r.store })
    local other = HighlightNote.save(r.ui, selection("/body/p[7].0", "/body/p[7].9"), "Un mot.",
        { kind = "translate", action = "translate", store = r.store })
    eq(HighlightNote.deleteHighlight(r.ui, kept.annotation, { store = r.store }), true)
    eq(r.deleted, 1)
    eq(#r.list, 1)
    eq(r.list[1], other.annotation, "the other highlight is untouched")
    eq(r.store.data[HighlightNote.RECORD_KEY][kept.annotation.datetime], nil, "the deleted one's line is gone")
    ok(r.store.data[HighlightNote.RECORD_KEY][other.annotation.datetime], "the other's stays")
    eq(select(2, HighlightNote.deleteHighlight(r.ui, kept.annotation, { store = r.store })), "gone", "a second tap finds nothing")
    eq(r.deleted, 1)
end)

TestRunner:test("piecesOf: what the note was made of, standing or not; the reader's edits do not change where it opens", function()
    local r = newReader()
    local sel = selection("/body/p[3].0", "/body/p[3].22")
    local first = HighlightNote.save(r.ui, sel, "Le matin se leva gris.", { kind = "translate", action = "translate", store = r.store })
    HighlightNote.save(r.ui, sel, "Quick Explain:\n\nEarly.", { kind = "chat", action = "quick_explain", store = r.store })
    local item = first.annotation
    local pieces = HighlightNote.piecesOf(r.store, item)
    eq(#pieces, 2)
    eq(pieces[1].action, "translate"); eq(pieces[1].text, "Le matin se leva gris.")
    eq(pieces[2].kind, "chat"); eq(pieces[2].from, #"Le matin se leva gris." + 3); eq(pieces[2].text, "Quick Explain:\n\nEarly.")
    ok(HighlightNote.popupParts(pieces, {}), "both from popup actions")
    -- a line of the reader's under the answers: both still stand, and the popup still takes the note
    local saved_note = item.note
    item.note = saved_note .. "\n\nmine"
    eq((HighlightNote.recordOf(r.store, item)), "mixed")
    pieces = HighlightNote.piecesOf(r.store, item)
    eq(pieces[2].text, "Quick Explain:\n\nEarly.")
    ok(HighlightNote.popupParts(pieces, {}), "a line added does not send the note to KOReader's window")
    -- the translation corrected: the piece after it moved, neither stands; the note is still what the two actions made
    item.note = (saved_note:gsub("gris", "tout gris"))
    eq((HighlightNote.recordOf(r.store, item)), "changed")
    pieces = HighlightNote.piecesOf(r.store, item)
    eq(#pieces, 2, "still on record")
    eq(pieces[1].text, nil); eq(pieces[2].text, nil)
    ok(HighlightNote.popupParts(pieces, {}))
    -- the note deleted: at the next tap its line goes, and a note the reader writes there is theirs alone
    item.note = nil
    HighlightNote.keepFormat(r.store, item)
    eq(HighlightNote.piecesOf(r.store, item), nil)
    eq(r.store.data[HighlightNote.RECORD_KEY][item.datetime], nil)
    item.note = "a note of my own"
    eq(HighlightNote.popupParts(HighlightNote.piecesOf(r.store, item), {}), nil)
    -- a highlight the plugin never wrote on; no store
    eq(HighlightNote.piecesOf(r.store, highlightOf(r, "/a", "/b", "mine alone")), nil)
    eq(HighlightNote.piecesOf(nil, item), nil)
end)

-- ── the windows' own saveToNote ─────────────────────────────────────────────
print("\n  the windows (Save to Note, +Note)")

local Recorder = require("ui_recorder")
local ChatGPTViewer = require("koassistant.ui.chatgptviewer")
local ReaderUIMock = {}
package.loaded["apps/reader/readerui"] = ReaderUIMock
local asked_content = {}
local asked_opts = {}
local single_answer = false
package.loaded["koassistant.chat.export"] = {
    fromHistory = function() return {} end,
    isSingleAnswer = function() return single_answer end,
    singleAnswerNote = function(_data, action_name) return tostring(action_name) .. ":\n\nNOTE", #tostring(action_name) + 3 end,
    format = function(_data, content, _style, opts)
        asked_content[#asked_content + 1] = content
        asked_opts[#asked_opts + 1] = opts or false
        return "NOTE:" .. content
    end,
}
local resolved_store
package.loaded["koassistant.storage.doc_settings"] = {
    resolve = function() return resolved_store end,
}

local function window(r, fields)
    ReaderUIMock.instance = r.ui
    resolved_store = r.store
    asked_content = {}
    asked_opts = {}
    single_answer = false
    fields.selection_data = fields.selection_data or selection("/body/p[3].0", "/body/p[3].22")
    fields._message_history = fields._message_history or {}
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
    eq(parts[1].lead, 0, "the piece is the translation alone, and the record says so")
end)

TestRunner:test("the chat window: question and response by default, and the window stays", function()
    local rec = Recorder.install()
    local r = newReader()
    local v = window(r, { _message_history = { prompt_action = "Explain" },
        configuration = { features = { _note_action = "explain" } } })
    UIManager:show(v)
    v:saveToNote()
    local shown = UIManager:isWidgetShown(v)
    rec:restore()
    eq(r.list[1].note, "NOTE:qa")
    ok(shown, "a chat is not closed by its note")
    local _state, parts = HighlightNote.recordOf(r.store, r.list[1])
    eq(parts[1].kind, "chat")
    eq(parts[1].action, "explain", "the record names the action the chat was started with: its id")
    eq(parts[1].action_name, "Explain", "and its name as the reader saw it")
    eq(parts[1].lead, nil, "questions and answers: no one answer to point at")
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
    rec:tap("Whole chat")
    rec:restore()
    -- the row a plain tap saves carries a tick (a translate window: the translation only)
    eq(rows, "Whole chat + metadata | Whole chat | \u{2713} Translation only | Everything (debug) | Edit before saving… | Cancel")
    eq(r.list[1].note, "NOTE:qa")
    eq(#r.edits + #r.adds, 0)
end)

TestRunner:test("the long-press list ticks the row a tap saves, whatever the setting; Ask every time ticks none", function()
    local rec = Recorder.install()
    local r = newReader()
    window(r, {}):saveToNote(true)
    ok(rec:has("\u{2713} Whole chat"), "a chat window's default")
    ok(rec:has("Last response only") and not rec:has("\u{2713} Last response only"), "one tick")
    rec:restore()
    rec = Recorder.install()
    window(r, { configuration = { features = { note_content = "response" } } }):saveToNote(true)
    ok(rec:has("\u{2713} Last response only"), "the reader's own setting")
    ok(not rec:has("\u{2713} Whole chat"))
    rec:restore()
    rec = Recorder.install()
    window(r, { translate_view = true,
        configuration = { features = { translate_note_content = "global", note_content = "full" } } }):saveToNote(true)
    ok(rec:has("\u{2713} Whole chat + metadata"), "Follow global setting, resolved")
    rec:restore()
    rec = Recorder.install()
    window(r, { configuration = { features = { note_content = "ask" } } }):saveToNote()
    local rows = table.concat(rec:texts(), " | ")
    rec:restore()
    ok(not rows:find("\u{2713}", 1, true), "Ask every time: the list is the tap, no row is the default")
end)

TestRunner:test("Edit before saving…: KOReader's note editor with the window's default content; its Save is recorded as a tap's", function()
    local rec = Recorder.install()
    local r = newReader()
    local v = window(r, { translate_view = true, configuration = { features = { _note_action = "translate" } },
        _message_history = { prompt_action = "Translate", conversation_id = "c9" } })
    UIManager:show(v)
    v:saveToNote(true)
    rec:tap("Edit before saving…")
    local closed = not UIManager:isWidgetShown(v)
    rec:restore()
    eq(#r.edits, 1, "KOReader's editor, on a highlight made as its Add note makes one")
    eq(r.edits[1].text, "NOTE:response"); eq(r.edits[1].is_new, true)
    ok(closed, "the translate window closes: the editor opens over the page")
    eq(r.store.saves, 0, "nothing is recorded before the editor's Save")
    r.edits[1].save()
    local state, parts = HighlightNote.recordOf(r.store, r.list[1])
    eq(state, "ours", "left as proposed, it is a saved answer like any other")
    eq(parts[1].kind, "translate"); eq(parts[1].action, "translate"); eq(parts[1].action_name, "Translate")
    eq(parts[1].chat, "c9"); eq(parts[1].lead, 0)
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
    eq(r.edits[1].text, "NOTE:qa")
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

TestRunner:test("a chat that is one answer with nothing typed: Whole chat names the action above the answer", function()
    local rec = Recorder.install()
    local r = newReader()
    local v = window(r, { _message_history = { prompt_action = "Explain" } })
    single_answer = true
    v:saveToNote()
    eq(r.list[1].note, "Explain:\n\nNOTE", "what was asked is the action")
    local _state, parts = HighlightNote.recordOf(r.store, r.list[1])
    eq(parts[1].lead, #"Explain:\n\n", "the record says where the answer starts under its line")
    eq(parts[1].text:sub(parts[1].lead + 1), "NOTE")
    -- Last response only is the answer alone, whatever the chat
    r = newReader()
    v = window(r, { _message_history = { prompt_action = "Explain" },
        configuration = { features = { note_content = "response" } } })
    single_answer = true
    v:saveToNote()
    eq(r.list[1].note, "NOTE:response")
    -- a typed question or a second exchange: the questions and answers as before,
    -- their first line without its brackets (KOReader's note window draws a
    -- leading bracket as a link with no address)
    r = newReader()
    v = window(r, {})
    v:saveToNote()
    rec:restore()
    eq(r.list[1].note, "NOTE:qa")
    ok(type(asked_opts[1]) == "table" and asked_opts[1].plain_line == true, "a note's export is asked for a plain first line")
end)

TestRunner:test("the record keeps the chat an answer came from: the id the chat is saved under", function()
    local rec = Recorder.install()
    local r = newReader()
    -- a chat not saved yet: the id it was given at its first message
    window(r, { _message_history = { prompt_action = "Explain", conversation_id = "1763900000_123456" } }):saveToNote()
    local _state, parts = HighlightNote.recordOf(r.store, r.list[1])
    eq(parts[1].chat, "1763900000_123456")
    -- a saved chat continued: its own id
    r = newReader()
    window(r, { _message_history = { chat_id = "saved_7", conversation_id = "saved_7" } }):saveToNote()
    _state, parts = HighlightNote.recordOf(r.store, r.list[1])
    eq(parts[1].chat, "saved_7")
    -- a later save on the same passage keeps the first piece's chat
    window(r, { _message_history = { conversation_id = "another" }, configuration = { features = { note_content = "full" } } }):saveToNote()
    _state, parts = HighlightNote.recordOf(r.store, r.list[1])
    rec:restore()
    eq(#parts, 2); eq(parts[1].chat, "saved_7"); eq(parts[2].chat, "another")
    -- no id, no field
    r = newReader()
    HighlightNote.save(r.ui, selection("/body/p[3].0", "/body/p[3].22"), "x", { kind = "chat", chat = "", store = r.store })
    _state, parts = HighlightNote.recordOf(r.store, r.list[1])
    eq(parts[1].chat, nil)
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
        extra = { { separator = true }, { text = "Auto-save Translate answers", callback = function() flipped = flipped + 1 end } },
    })
    local top = rec:top()
    eq(#top.buttons, 8, "four content rows, the editor row, the double line, the setting row, Cancel")
    eq(#top.buttons[6], 0, "the double line: an empty row")
    rec:tap("Auto-save Translate answers")
    eq(flipped, 1)
    v:saveToNote(true, { popup = true, before_edit = function() closed = closed + 1 end })
    eq(rec:top().anchor, nil, "no place given: the picker opens in the middle")
    rec:tap("Edit before saving…")
    eq(closed, 1, "the popup closes before KOReader's editor opens")
    eq(#r.adds + #r.edits, 1)
    -- the picker opens where the popup says (its mark); the window's own opens at its button
    local handed
    local at_mark = function(dialog) handed = dialog; return "the mark's place", true end
    v:saveToNote(true, { popup = true, anchor = at_mark })
    local picker = rec:top()
    local place, under = picker.anchor()
    eq(place, "the mark's place", "the popup's place for the picker")
    eq(under, true)
    eq(handed, picker, "the place is asked with the picker itself: it can follow the picker's size")
    rec:tap("Cancel")
    v.button_table = { getButtonById = function(_self, id) return { dimen = { id = id } } end }
    v:saveToNote(true)
    local where, below = rec:top().anchor()
    rec:restore()
    eq(where.id, "save_to_note", "the window's own picker opens at its button")
    eq(below, true)
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
                        or code:find(":setBookmarkNote%(") or code:find(":showHighlightPrompt%(")
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
