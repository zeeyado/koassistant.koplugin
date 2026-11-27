--[[--
The saved answers of one book as a text file Anki imports (B722).

A file, not cards: Anki's own File > Import makes the notes, in whatever note
type the reader uses, and tells new rows from known ones by that note type's
first field. So the whole file is written at every export and nothing is
appended.

One row per highlight whose note holds an answer the plugin saved there
(koassistant/chat/highlight_note.lua's record) from an action ticked for the
export (features.anki_export_actions, Constants.resolveAnkiExportActions).
Columns, AnkiExport.COLUMNS:

- ID: the highlight's creation time. KOReader keeps it for the highlight's
  whole life, so the same highlight is the same row at every export, and the
  same words highlighted in two places are two rows.
- Front: the highlighted passage.
- Back: the note as it reads NOW (a corrected answer and a line the reader
  added are on the card), without the saved answers of actions left unticked.
- Book, Chapter, Page, Kind (the actions' names), Tags.

Anki fills a note type's fields from the columns of the same NAME, and gives
an unmatched first field the first column: "Front" and "Back" fill Anki's
stock note types by themselves, and the first three names can be the reader's
own fields (features.anki_column_names).

The cells are HTML (`#html:true`): a translation is its lines, a chat or
dictionary answer goes through the viewer's own Markdown conversion, the
reader's own words follow what KOReader's note window makes of the note.
Everything but forBook and markdown is pure.
]]

local _ = require("koassistant.core.gettext")

local AnkiExport = {}

AnkiExport.COLUMNS = { "ID", "Front", "Back", "Book", "Chapter", "Page", "Kind", "Tags" }
--- How many of the columns the reader can name, counted from the first
AnkiExport.RENAMED = 3

local ESCAPES = { ["&"] = "&amp;", ["<"] = "&lt;", [">"] = "&gt;", ['"'] = "&quot;" }

local function trim(text)
    return (text:gsub("^%s+", ""):gsub("%s+$", ""))
end

--- Plain text as HTML, pure: its lines kept as lines
function AnkiExport.plainHtml(text)
    text = trim((text or ""):gsub("\r\n?", "\n"))
    return (text:gsub('[&<>"]', ESCAPES):gsub("\n", "<br>"))
end

--- HTML on one line, pure (a row of the file is one line): a line break
--- inside a code block becomes <br>, any other is white space HTML does not
--- show; a lone paragraph loses its wrapper, so a one-line answer is a bare
--- line in the field
function AnkiExport.oneLine(html)
    html = (html or ""):gsub("\r", "")
    html = html:gsub("(<pre[^>]*>)(.-)(</pre>)", function(open, body, close)
        return open .. (body:gsub("\n", "<br>")) .. close
    end)
    html = trim((html:gsub("%s*\n%s*", " ")))
    local inner = html:match("^<p>(.*)</p>$")
    if inner and not inner:find("<p[ >]") and not inner:find("</p>", 1, true) then
        return inner
    end
    return html
end

--- How KOReader's own note window reads a note, pure: "md", "html" or nil
--- (plain text): the format named on the annotation, else its first character
--- (ReaderHighlight:showHighlightNoteOrDialog)
function AnkiExport.noteFormat(annotation)
    local named = annotation.note_format
    if named == "md" or named == "html" then return named end
    if named ~= nil then return nil end
    local first = (annotation.note or ""):gsub("^%s*", ""):sub(1, 1)
    if first == "<" then return "html" end
    if first == "#" or first == "*" or first == "[" then return "md" end
    return nil
end

--- The test for "this saved answer goes into the export", from the set of
--- ticked action ids. An answer whose action was not recorded follows its
--- kind: a translation goes with Translate, a dictionary answer with Dictionary
function AnkiExport.wanted(ticked)
    return function(piece)
        if piece.action then return ticked[piece.action] == true end
        return (piece.kind == "translate" and ticked.translate == true)
            or (piece.kind == "dictionary" and ticked.dictionary == true)
            or false
    end
end

local KIND_NAME = {
    translate = function() return _("Translate") end,
    dictionary = function() return _("Dictionary") end,
}

-- What a saved answer is called in the Kind column: its action as the reader saw it
local function kindName(piece)
    if piece.action_name then return piece.action_name end
    local named = KIND_NAME[piece.kind]
    return named and named() or _("Chat")
end

--- One word for Anki's tag list (tags are separated by spaces), pure
function AnkiExport.tag(text)
    return (trim(text or ""):gsub("%s+", "_"):gsub('["\t]', ""))
end

-- A saved answer's tag: a built-in action's own id, else its name as one word
local function kindTag(piece)
    if piece.action and piece.action:find("^[%l_]+$") then return piece.action end
    return AnkiExport.tag(kindName(piece)):lower()
end

local BLOCKS = {
    p = true, ul = true, ol = true, pre = true, blockquote = true, table = true, div = true,
    h1 = true, h2 = true, h3 = true, h4 = true, h5 = true, h6 = true, hr = true,
}

-- Pieces of HTML one under the other: a blank line between two that are
-- lines of text, nothing where a block already stands apart
local function stack(parts)
    local out = {}
    for i, part in ipairs(parts) do
        if i > 1 then
            local before = parts[i - 1]:match("</(%w+)>%s*$")
            local after = part:match("^%s*<(%w+)")
            if not (BLOCKS[before or ""] or BLOCKS[after or ""]) then out[#out + 1] = "<br><br>" end
        end
        out[#out + 1] = part
    end
    return table.concat(out)
end

--- The note as the card's back, pure but for `opts.markdown`: the note as it
--- reads now, cut into the saved answers that still stand as saved and the
--- words around them. A standing answer of an action left out of the export
--- is left out; a standing translation is its lines; a standing chat or
--- dictionary answer is drawn as Markdown; every other stretch (the reader's
--- own words, an answer they corrected) follows the note's own format.
-- @param annotation table { note, note_format }
-- @param pieces table HighlightNote.piecesOf: every answer on record, a standing one with its text
-- @param opts table { wanted = function(piece), markdown = function(text) -> html|nil }
function AnkiExport.back(annotation, pieces, opts)
    local note = annotation.note
    local format = AnkiExport.noteFormat(annotation)
    local function markdown(text)
        local html = opts.markdown and opts.markdown(text) or nil
        return html and AnkiExport.oneLine(html) or AnkiExport.plainHtml(text)
    end
    local function own(text)
        if not text:find("%S") then return nil end
        if format == "html" then return AnkiExport.oneLine(text) end
        if format == "md" then return markdown(trim(text)) end
        return AnkiExport.plainHtml(text)
    end
    local parts, at = {}, 1
    for _idx, piece in ipairs(pieces) do
        if piece.text and type(piece.from) == "number" and piece.from >= at then
            parts[#parts + 1] = own(note:sub(at, piece.from - 1))
            if opts.wanted(piece) then
                parts[#parts + 1] = piece.kind == "translate" and AnkiExport.plainHtml(piece.text)
                    or markdown(piece.text)
            end
            at = piece.from + #piece.text
        end
    end
    parts[#parts + 1] = own(note:sub(at))
    return stack(parts)
end

--- One highlight as a row of the file, or nil when it is none: no note, no
--- passage, or no saved answer of a ticked action in its note.
-- @param opts table { wanted, markdown, title = the book's title }
-- @return table|nil the cells in AnkiExport.COLUMNS' order
function AnkiExport.row(annotation, pieces, opts)
    local note, passage = annotation.note, annotation.text
    if type(note) ~= "string" or not note:find("%S") then return nil end
    if type(passage) ~= "string" or not passage:find("%S") then return nil end
    if type(pieces) ~= "table" then return nil end
    local kinds, tags, seen = {}, { "KOAssistant" }, {}
    for _idx, piece in ipairs(pieces) do
        if opts.wanted(piece) then
            local name = kindName(piece)
            if not seen[name] then
                seen[name] = true
                kinds[#kinds + 1] = name
                tags[#tags + 1] = kindTag(piece)
            end
        end
    end
    if #kinds == 0 then return nil end
    local title = opts.title or ""
    if title ~= "" then tags[#tags + 1] = AnkiExport.tag(title) end
    local page = annotation.pageref or annotation.pageno
    if page == nil and type(annotation.page) == "number" then page = annotation.page end
    return {
        tostring(annotation.datetime),
        AnkiExport.plainHtml(passage),
        AnkiExport.back(annotation, pieces, opts),
        AnkiExport.plainHtml(title),
        AnkiExport.plainHtml(annotation.chapter or ""),
        page ~= nil and AnkiExport.plainHtml(tostring(page)) or "",
        AnkiExport.plainHtml(table.concat(kinds, ", ")),
        table.concat(tags, " "),
    }
end

--- A book's rows, in the book's own order of highlights.
-- @param pieces_of function(annotation) -> HighlightNote.piecesOf's result
function AnkiExport.rows(annotations, pieces_of, opts)
    local rows = {}
    for _idx, annotation in ipairs(annotations or {}) do
        if type(annotation) == "table" and annotation.datetime then
            local row = AnkiExport.row(annotation, pieces_of(annotation), opts)
            if row then rows[#rows + 1] = row end
        end
    end
    return rows
end

--- The reader's own names for the first columns, pure: "a, b, c" as three
--- names, or nil and why. A name is a note type's field name: no comma, tab or
--- line break, and no two columns of the file may share one.
function AnkiExport.parseColumnNames(text)
    if type(text) ~= "string" then return nil, "empty" end
    local own = {}
    for chunk in (text .. ","):gmatch("([^,]*),") do
        local name = trim(chunk)
        if name == "" or name:find("[\t\r\n\"]") then return nil, "name" end
        own[#own + 1] = name
    end
    if #own ~= AnkiExport.RENAMED then return nil, "count" end
    local taken = {}
    for i = AnkiExport.RENAMED + 1, #AnkiExport.COLUMNS do taken[AnkiExport.COLUMNS[i]] = true end
    for _idx, name in ipairs(own) do
        if taken[name] then return nil, "twice" end
        taken[name] = true
    end
    return own
end

--- The file's column names: the setting's for the first three, the fixed ones after
function AnkiExport.columnNames(setting)
    local names = {}
    for i, name in ipairs(AnkiExport.COLUMNS) do names[i] = name end
    local own = AnkiExport.parseColumnNames(setting)
    if own then
        for i, name in ipairs(own) do names[i] = name end
    end
    return names
end

--- The first three names as the setting's row and its box show them
function AnkiExport.columnNamesText(setting)
    local names = AnkiExport.columnNames(setting)
    return table.concat(names, ", ", 1, AnkiExport.RENAMED)
end

-- One cell of a row: no tab and no line break can stand in it, and a cell
-- that holds a double quote is quoted the way a separated file quotes
-- (a cell that STARTS with one would otherwise be read as a quoted cell)
local function cell(value)
    value = tostring(value or ""):gsub("[\r\n]+", " "):gsub("\t", " ")
    if value:find('"', 1, true) then
        return '"' .. value:gsub('"', '""') .. '"'
    end
    return value
end

--- The file's whole text, pure: Anki's header lines, then a row a line
function AnkiExport.fileText(rows, names)
    local lines = {
        "#separator:tab",
        "#html:true",
        "#columns:" .. table.concat(names, "\t"),
        "#tags column:" .. #names,
    }
    for _idx, row in ipairs(rows) do
        local cells = {}
        for i = 1, #names do cells[i] = cell(row[i]) end
        lines[#lines + 1] = table.concat(cells, "\t")
    end
    return table.concat(lines, "\n") .. "\n"
end

--- A chat or dictionary answer's Markdown as HTML: the viewer's own
--- conversion up to the Markdown library (the passes after it only serve the
--- e-reader's page engine), with numbered lists as the answer numbered them.
--- nil when it cannot be converted (the caller then writes the text's lines).
function AnkiExport.markdown(text)
    local ok, html = pcall(function()
        local blocks = require("koassistant.ui.chatgptviewer").markdownBlocks(text, { features = {} })
        return blocks and require("koassistant.ui.list_numbers").resolve(blocks) or nil
    end)
    return ok and html or nil
end

-- The whole file or nothing: written beside its place, then moved over the old one
local function writeWhole(path, text)
    local tmp = path .. ".tmp"
    local handle, err = io.open(tmp, "w")
    if not handle then return false, err end
    local ok, write_err = handle:write(text)
    handle:close()
    if not ok then
        os.remove(tmp)
        return false, write_err
    end
    local moved, move_err = os.rename(tmp, path)
    if not moved then
        os.remove(tmp)
        return false, move_err
    end
    return true
end

-- A book's rows: the open book's live highlights, a closed book's from its own file
local function bookRows(file, title, ui, ticked)
    local annotations
    if ui and ui.document and ui.document.file == file and ui.annotation then
        annotations = ui.annotation.annotations
    else
        annotations = require("koassistant.request.context_extractor").readSidecarAnnotations(file)
    end
    local HighlightNote = require("koassistant.chat.highlight_note")
    local ds = require("koassistant.storage.doc_settings").resolve(file, ui)
    return AnkiExport.rows(annotations, function(annotation)
        return HighlightNote.piecesOf(ds, annotation)
    end, { wanted = AnkiExport.wanted(ticked), markdown = AnkiExport.markdown, title = title })
end

--- Write ONE file with the saved answers of every book handed over (B788; the
--- reader of discussion 127: one file, the books told apart in Anki by their
--- tag). The books' rows one after the other in the order given, each row
--- with its book in the Book column and as a tag; the ids are the per-book
--- file's (a highlight's creation time), so importing both adds nothing twice.
--- A book with no saved answer on record is not read any further than its
--- own small settings file.
-- @param opts table { books = { { file, title }, ... }, title_of = function(file) for a book
--   handed over without a title (asked only for a book that has rows), ui, features, dir }
-- @return table|nil { path, count, books = how many books have rows }; nil and "none" when no
--   book has a saved answer to export, nil and the error's text when the file could not be written
function AnkiExport.forAllBooks(opts)
    local features = opts.features or {}
    local HighlightNote = require("koassistant.chat.highlight_note")
    local SafeDocSettings = require("koassistant.storage.doc_settings")
    local ticked = require("koassistant.core.constants").resolveAnkiExportActions(features.anki_export_actions)
    local rows, books = {}, 0
    for _idx, book in ipairs(opts.books or {}) do
        local ok, ds = pcall(SafeDocSettings.resolve, book.file, opts.ui)
        local record = ok and ds and ds:readSetting(HighlightNote.RECORD_KEY)
        if type(record) == "table" and next(record) ~= nil then
            local title = book.title
            if (not title or title == "") and opts.title_of then title = opts.title_of(book.file) end
            local own = bookRows(book.file, title or "", opts.ui, ticked)
            if #own > 0 then
                books = books + 1
                for _i, row in ipairs(own) do rows[#rows + 1] = row end
            end
        end
    end
    if #rows == 0 then return nil, "none" end
    local path = opts.dir .. "/" .. require("koassistant.chat.export").getAnkiAllFilename()
    local ok, err = writeWhole(path, AnkiExport.fileText(rows, AnkiExport.columnNames(features.anki_column_names)))
    if not ok then return nil, tostring(err) end
    return { path = path, count = #rows, books = books }
end

--- Write a book's file.
-- @param opts table { file = the book's path, ui = the reader or file browser,
--   features, title = the book's title, dir = the folder to write into }
-- @return table|nil { path, count }; nil and "none" when the book has no
--   saved answer to export, nil and the error's text when the file could not be written
function AnkiExport.forBook(opts)
    local features = opts.features or {}
    local ticked = require("koassistant.core.constants").resolveAnkiExportActions(features.anki_export_actions)
    local rows = bookRows(opts.file, opts.title, opts.ui, ticked)
    if #rows == 0 then return nil, "none" end
    local path = opts.dir .. "/" .. require("koassistant.chat.export").getAnkiFilename(opts.title)
    local ok, err = writeWhole(path, AnkiExport.fileText(rows, AnkiExport.columnNames(features.anki_column_names)))
    if not ok then return nil, tostring(err) end
    return { path = path, count = #rows }
end

return AnkiExport
