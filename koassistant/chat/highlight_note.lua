--[[--
A note saved on a passage of the book: KOReader's own highlight with
KOReader's own note, written without KOReader's note editor.

THE writer for every door that keeps an answer with the selection (the chat
windows' Save to Note and +Note, the minimal popup's mark, the automatic
save). What `save` does is what KOReader's "Edit note" dialog does when its
Save is tapped (ReaderBookmark:setBookmarkNote): the note on the annotation,
the note written into a PDF that keeps its highlights, the counters' event,
the change time, the page drawn again. `remove` takes one saved answer back
out. Nothing else in the plugin writes a highlight or a note.

A passage that is already a highlight gets the note, never a second highlight
over the first (KOReader's own translator does the same with the highlight it
was opened from). A highlight that already has a note keeps it: the new text
goes after a blank line, as KOReader's editor joins a text it is handed.

Which answers the plugin wrote is recorded per book (RECORD_KEY, in the book's
plugin settings file), by the annotation's creation time: KOReader's own
identity for an annotation, kept when a highlight is extended, while a field
of ours on the item would be lost there (the item is rebuilt from a fixed list
of fields). A line holds one PIECE per saved answer: its kind, when, where it
sits in the note and its fingerprint. So a reader of the record can take the
translation alone out of a note that holds more, and can tell a piece the
reader has changed since, which is then the reader's (recordOf). Nothing is
added to the note's text.
]]

local logger = require("koassistant.core.logger")

local HighlightNote = {}

--- The per-book record:
--- { [annotation.datetime] = { parts = { { kind, at, from, len, sum }, ... } } }
HighlightNote.RECORD_KEY = "koassistant_written_notes"

--- A fingerprint of a text (its length and an Adler sum): enough to tell a
--- text that changed since, with nothing of the text kept. Pure.
function HighlightNote.fingerprint(text)
    if type(text) ~= "string" then return nil end
    local a, b = 1, 0
    for i = 1, #text do
        a = (a + text:byte(i)) % 65521
        b = (b + a) % 65521
    end
    return #text .. ":" .. (b * 65536 + a)
end

-- KOReader's own rule for "the same annotation" (ReaderAnnotation:getMatchFunc)
-- without the creation time, which a selection does not have. Spelled out: its
-- function reads pos0.x of the item it is given, and a page bookmark has none.
local function samePassage(rolling, passage, item)
    if not (item.drawer and item.pos0 and item.pos1) then return false end
    if rolling then
        return passage.pos0 == item.pos0 and passage.pos1 == item.pos1
    end
    local a0, a1, b0, b1 = passage.pos0, passage.pos1, item.pos0, item.pos1
    if type(a0) ~= "table" or type(a1) ~= "table" or type(b0) ~= "table" or type(b1) ~= "table" then
        return false
    end
    return a0.page == b0.page and a0.x == b0.x and a0.y == b0.y and a1.x == b1.x and a1.y == b1.y
end

--- The highlight that IS this passage, when the reader has one
-- @return number|nil its index in the book's annotations
function HighlightNote.find(ui, passage)
    local list = ui and ui.annotation and ui.annotation.annotations
    if not (list and passage and passage.pos0 and passage.pos1) then return nil end
    local rolling = ui.rolling ~= nil
    for index, item in ipairs(list) do
        if samePassage(rolling, passage, item) then return index end
    end
    return nil
end

local function copy(t)
    local c = {}
    for k, v in pairs(t) do c[k] = v end
    return c
end

-- The passage as KOReader's own Add note would save it: the punctuation around
-- a selection that already is a sentence segment taken in (reflowable books).
-- nil when nothing changes.
local function extended(ui, selection)
    local doc = ui.rolling and ui.document
    if not (doc and doc.extendXPointersToSentenceSegment) then return nil end
    local wider = doc:extendXPointersToSentenceSegment(selection.pos0, selection.pos1)
    if not wider then return nil end
    local passage = copy(selection)
    passage.pos0, passage.pos1, passage.text = wider.pos0, wider.pos1, wider.text
    return passage
end

local function unusable(ui, selection, text)
    if not (ui and ui.highlight and ui.annotation and ui.annotation.annotations) then return "no_reader" end
    if not (selection and selection.pos0 and selection.pos1) then return "no_selection" end
    if type(text) ~= "string" or not text:find("%S") then return "no_text" end
    return nil
end

-- The reader's highlight of this passage: as selected first, then as KOReader
-- would extend it (a passage saved before was saved extended). An existing
-- highlight's ends are never changed.
local function existing(ui, selection, wider)
    return HighlightNote.find(ui, selection) or (wider and HighlightNote.find(ui, wider)) or nil
end

local function bookStore(ui, opts)
    if opts.store ~= nil then return opts.store end
    local path = ui.document and ui.document.file
    if not path then return nil end
    return require("koassistant.storage.doc_settings").resolve(path, ui)
end

-- The pieces of a record's line that stand in `note` as they were written, in
-- the note's order, each with its text. A piece the reader has changed, or
-- that an edit before it has moved, is not among them: it is the reader's now.
local function intact(line, note)
    local out = {}
    if type(line) ~= "table" or type(line.parts) ~= "table" or type(note) ~= "string" then return out end
    for _idx, part in ipairs(line.parts) do
        if type(part) == "table" and type(part.from) == "number" and type(part.len) == "number" then
            local text = note:sub(part.from, part.from + part.len - 1)
            if #text == part.len and HighlightNote.fingerprint(text) == part.sum then
                out[#out + 1] = { kind = part.kind, at = part.at, from = part.from, len = part.len,
                    sum = part.sum, text = text }
            end
        end
    end
    return out
end

local function stored(part)
    return { kind = part.kind, at = part.at, from = part.from, len = part.len, sum = part.sum }
end

local function readRecord(ds)
    local all = ds:readSetting(HighlightNote.RECORD_KEY)
    if type(all) ~= "table" then all = {} end
    return all
end

-- A piece of the record for the text just written at the end of the note.
-- `old` = the note the highlight had before. The lines of highlights that are
-- gone go with them.
local function remember(ds, annotations, annotation, kind, old, text)
    if not (ds and annotation.datetime) then return end
    local all = readRecord(ds)
    local live = {}
    for _idx, item in ipairs(annotations) do
        if item.datetime then live[item.datetime] = true end
    end
    for stamp in pairs(all) do
        if not live[stamp] then all[stamp] = nil end
    end
    local parts = {}
    for _idx, part in ipairs(intact(all[annotation.datetime], old)) do
        parts[#parts + 1] = stored(part)
    end
    parts[#parts + 1] = {
        kind = kind,
        at = os.time(),
        from = old and (#old + 3) or 1,
        len = #text,
        sum = HighlightNote.fingerprint(text),
    }
    all[annotation.datetime] = { parts = parts }
    ds:saveSetting(HighlightNote.RECORD_KEY, all)
end

-- The piece of `text` at the note's end leaves the record (its note left the highlight)
local function forget(ds, annotation, old, text, whole)
    if not (ds and annotation.datetime) then return end
    local all = readRecord(ds)
    local line = all[annotation.datetime]
    if type(line) ~= "table" then return end
    local parts = {}
    if not whole then
        local sum, from = HighlightNote.fingerprint(text), #old - #text + 1
        for _idx, part in ipairs(intact(line, old)) do
            if not (part.sum == sum and part.from == from) then parts[#parts + 1] = stored(part) end
        end
    end
    all[annotation.datetime] = #parts > 0 and { parts = parts } or nil
    ds:saveSetting(HighlightNote.RECORD_KEY, all)
end

--- What the record says of an annotation's note.
-- @param ds the book's settings object (SafeDocSettings.resolve)
-- @return string|nil "ours" (every word of the note is the plugin's, as left),
--   "mixed" (it holds the plugin's pieces and other words), "changed" (a line
--   exists and no piece stands as written: the reader's now), nil (no line)
-- @return table the plugin's pieces that stand as written, in the note's
--   order: { kind, at, from, len, text }
function HighlightNote.recordOf(ds, annotation)
    if not (ds and annotation and annotation.datetime) then return nil, {} end
    local line = readRecord(ds)[annotation.datetime]
    if type(line) ~= "table" then return nil, {} end
    local note = annotation.note
    local parts = intact(line, note)
    if #parts == 0 then return "changed", parts end
    -- what stands between and around the pieces: white space, or someone's words
    local rest, at = {}, 1
    for _idx, part in ipairs(parts) do
        rest[#rest + 1] = note:sub(at, part.from - 1)
        at = part.from + part.len
    end
    rest[#rest + 1] = note:sub(at)
    if table.concat(rest):find("%S") then return "mixed", parts end
    return "ours", parts
end

local function redraw(ui)
    require("ui/uimanager"):setDirty(ui.highlight.dialog, "ui")
end

--- Save `text` as the note of the selection's highlight, at once.
-- @param ui the reader (ReaderUI)
-- @param selection { pos0, pos1, text, sboxes, pboxes, ext, drawer, color } as captured at the selection; never written to
-- @param text the note
-- @param opts { extend = the passage as KOReader's Add note saves it (not for a looked-up word),
--               kind = "translate" | "dictionary" | "chat", store = the book's settings object (tests) }
-- @return table|nil { index, annotation, text = what was written, created = a highlight was made,
--                     appended = it had a note, already = nothing to write }
-- @return string|nil why not: "no_reader" | "no_selection" | "no_text" | "no_highlight"
function HighlightNote.save(ui, selection, text, opts)
    opts = opts or {}
    local why = unusable(ui, selection, text)
    if why then return nil, why end
    text = text:gsub("%s+$", "")
    local hl = ui.highlight
    local wider = opts.extend and extended(ui, selection) or nil
    local index = existing(ui, selection, wider)
    local created = false
    if not index then
        -- KOReader makes the highlight (its style, its colour, the PDF's own
        -- copy), from a table of ours: saveHighlight writes onto what it is given
        local passage = copy(wider or selection)
        hl.selected_text = passage
        index = hl:saveHighlight(false)
        hl:clear()
        if hl.selected_text == passage then hl.selected_text = nil end
        if not index then return nil, "no_highlight" end
        created = true
    end
    local annotation = ui.annotation.annotations[index]
    local old = annotation.note
    if old == "" then old = nil end
    if old and old:find(text, 1, true) then
        return { index = index, annotation = annotation, text = text, created = false, appended = false, already = true }
    end

    -- KOReader's "Edit note" Save, step for step
    annotation.note = old and (old .. "\n\n" .. text) or text
    hl:writePdfAnnotation("content", annotation, annotation.note)
    if old then
        ui.annotation:onAnnotationsModified({ annotation })
    else
        local Event = require("ui/event")
        ui:handleEvent(Event:new("AnnotationsModified",
            { annotation, nb_highlights_added = -1, nb_notes_added = 1 }))
    end
    redraw(ui)

    local ok, err = pcall(remember, bookStore(ui, opts), ui.annotation.annotations, annotation, opts.kind, old, text)
    if not ok then logger.warn("KOAssistant: the note was saved, its record was not:", err) end
    return { index = index, annotation = annotation, text = text, created = created, appended = old ~= nil, already = false }
end

--- Take a saved answer back out (the popup's tick tapped again): the
--- highlight too when the save made it and its note is still that answer
--- alone, else the answer's text from the end of the note, as KOReader's own
--- "Delete note" does it. A note that is no longer as the save left it is not
--- touched.
-- @param saved what save returned
-- @return string|nil "highlight" | "note" (what was removed)
-- @return string|nil why not: "no_reader" | "gone" (the highlight is no longer there) | "changed"
function HighlightNote.remove(ui, saved, opts)
    opts = opts or {}
    if not (ui and ui.highlight and ui.annotation and ui.annotation.annotations) then return nil, "no_reader" end
    if not (saved and saved.annotation and type(saved.text) == "string") then return nil, "gone" end
    local annotation, hl, text = saved.annotation, ui.highlight, saved.text
    local index
    for i, item in ipairs(ui.annotation.annotations) do
        if item == annotation then index = i break end
    end
    if not index then return nil, "gone" end
    local note = annotation.note
    local removed
    if note == text and saved.created then
        -- KOReader's own delete: the PDF's copy, the list, the counters, the page
        hl:deleteHighlight(index)
        removed = "highlight"
    elseif note == text then
        annotation.note = nil
        local Event = require("ui/event")
        ui:handleEvent(Event:new("AnnotationsModified",
            { annotation, nb_highlights_added = 1, nb_notes_added = -1 }))
        hl:writePdfAnnotation("content", annotation, "")
        redraw(ui)
        removed = "note"
    elseif type(note) == "string" and note:sub(-(#text + 2)) == "\n\n" .. text then
        annotation.note = note:sub(1, #note - #text - 2)
        hl:writePdfAnnotation("content", annotation, annotation.note)
        ui.annotation:onAnnotationsModified({ annotation })
        redraw(ui)
        removed = "note"
    else
        return nil, "changed"
    end
    local ok, err = pcall(forget, bookStore(ui, opts), annotation, note, text, removed == "highlight")
    if not ok then logger.warn("KOAssistant: the note was removed, its record was not:", err) end
    return removed
end

--- KOReader's note editor with `text` filled in, on the same highlight rule:
--- the passage's own highlight when there is one, else a new one as before
--- (KOReader's Add note for a passage, the word alone for a looked-up word).
--- A note saved from the editor is not recorded: the reader may change it there.
-- @return boolean|nil, string|nil why not (as save)
function HighlightNote.edit(ui, selection, text, opts)
    opts = opts or {}
    local why = unusable(ui, selection, text)
    if why then return nil, why end
    local hl = ui.highlight
    local index = existing(ui, selection, opts.extend and extended(ui, selection) or nil)
    if index then
        hl:editNote(index, false, text)
        return true
    end
    hl.selected_text = copy(selection)
    if opts.extend then
        hl:addNote(text)
        return true
    end
    index = hl:saveHighlight(false)
    if not index then return nil, "no_highlight" end
    hl:clear()
    hl:editNote(index, true, text)
    return true
end

return HighlightNote
