-- A book's saved answers as a text file Anki imports (B722).
--
-- koassistant/chat/anki_export.lua writes one row per highlight whose note
-- holds an answer the plugin saved there, from an action ticked for the
-- export. What a row holds is decided here, on notes as readers leave them:
-- a translation alone, one with a line of the reader's under it, one the
-- reader corrected, an explanation kept on the same passage and left out of
-- the export, a definition written in Markdown.
--
-- What Anki itself makes of such a file (columns filled by name, a second
-- export adding only what is new) was measured with Anki's own importer when
-- the format was chosen; this file holds the format to what was measured: the
-- header lines, one line per row, a cell that starts with a quotation mark.
--
-- Run: lua tests/unit/test_anki_export.lua  (or lua tests/run_tests.lua --unit)

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
setupPaths()
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
for _i, name in ipairs({ "koassistant.storage.doc_settings", "koassistant.request.context_extractor" }) do
    SAVED[name] = package.loaded[name]
end

local AnkiExport = require("koassistant.chat.anki_export")
local HighlightNote = require("koassistant.chat.highlight_note")
local Constants = require("koassistant.core.constants")
local Export = require("koassistant.chat.export")

-- ── notes as the record describes them ──────────────────────────────────────
-- A note built from its stretches: a string is the reader's own words, a
-- table { kind, action, action_name, text, changed = "what it reads now" } is
-- a saved answer. Returns the annotation and what HighlightNote.piecesOf
-- gives for it (a piece that still stands carries its text).
local function noted(stretches, more)
    local note, pieces = "", {}
    for _i, stretch in ipairs(stretches) do
        if note ~= "" then note = note .. "\n\n" end
        if type(stretch) == "string" then
            note = note .. stretch
        else
            local shown = stretch.changed or stretch.text
            pieces[#pieces + 1] = {
                kind = stretch.kind, action = stretch.action, action_name = stretch.action_name,
                from = #note + 1, len = #stretch.text,
                text = not stretch.changed and stretch.text or nil,
            }
            note = note .. shown
        end
    end
    local annotation = { datetime = "2026-11-24 09:12:41", text = "Le matin se leva gris sur le port.", note = note }
    for k, v in pairs(more or {}) do annotation[k] = v end
    return annotation, pieces
end

local function translation(text, more)
    local t = { kind = "translate", action = "translate", action_name = "Translate", text = text }
    for k, v in pairs(more or {}) do t[k] = v end
    return t
end
local function explanation(text)
    return { kind = "chat", action = "explain", action_name = "Explain", text = text }
end
local function definition(text, more)
    local t = { kind = "dictionary", action = "quick_define", action_name = "Quick Define", text = text }
    for k, v in pairs(more or {}) do t[k] = v end
    return t
end

-- A stand-in for the viewer's Markdown conversion (the unit runs have no
-- Markdown library; the real one is run at this file's end where the app is
-- installed): paragraphs, bold, emphasis, a link, a fenced block
local function standInMarkdown(text)
    local out = {}
    local function inline(para)
        para = para:gsub("%[(.-)%]%((.-)%)", '<a href="%2">%1</a>')
        para = para:gsub("%*%*(.-)%*%*", "<strong>%1</strong>")
        return (para:gsub("%*(.-)%*", "<em>%1</em>"))
    end
    for para in (text .. "\n\n"):gmatch("(.-)\n\n+") do
        local code = para:match("^```\n(.*)\n```$")
        if code then
            out[#out + 1] = "<pre><code>" .. code .. "</code></pre>"
        elseif para:find("%S") then
            out[#out + 1] = "<p>" .. inline(para) .. "</p>"
        end
    end
    return table.concat(out, "\n\n") .. "\n"
end

local DEFAULTS = AnkiExport.wanted(Constants.resolveAnkiExportActions(nil))
local function opts(more)
    local o = { wanted = DEFAULTS, markdown = standInMarkdown, title = "The Grey Harbour" }
    for k, v in pairs(more or {}) do o[k] = v end
    return o
end

print("  what a cell holds")

TestRunner:test("plain text as HTML: its lines kept, what HTML would read as a tag or a quote written out", function()
    eq(AnkiExport.plainHtml("  a < b & c > d\n\"quoted\"\n\nlast  "), "a &lt; b &amp; c &gt; d<br>&quot;quoted&quot;<br><br>last")
    eq(AnkiExport.plainHtml("one\r\ntwo"), "one<br>two", "a carriage return is no character of the cell")
    eq(AnkiExport.plainHtml(nil), "")
end)

TestRunner:test("HTML on one line: a lone paragraph is a bare line, a code block keeps its lines", function()
    eq(AnkiExport.oneLine("<p><strong>esquif</strong>, noun</p>\n"), "<strong>esquif</strong>, noun")
    eq(AnkiExport.oneLine("<p>one</p>\n\n<p>two</p>\n"), "<p>one</p> <p>two</p>", "two paragraphs stay two")
    eq(AnkiExport.oneLine("<p>before</p>\n<pre><code>a\nb</code></pre>\n"), "<p>before</p> <pre><code>a<br>b</code></pre>")
    ok(not AnkiExport.oneLine("a\tb\nc"):find("\n"), "no line break is left")
end)

TestRunner:test("a note's format is what KOReader's own note window makes of it", function()
    eq(AnkiExport.noteFormat({ note = "plain", note_format = "md" }), "md", "the format named on the highlight")
    eq(AnkiExport.noteFormat({ note = "<b>x</b>" }), "html")
    eq(AnkiExport.noteFormat({ note = "  **word**, noun" }), "md", "KOReader's guess from the first character")
    eq(AnkiExport.noteFormat({ note = "[link]" }), "md")
    eq(AnkiExport.noteFormat({ note = "# title" }), "md")
    eq(AnkiExport.noteFormat({ note = "Morning rose grey." }), nil)
    eq(AnkiExport.noteFormat({ note = "**x**", note_format = "something else" }), nil, "a format KOReader does not draw")
end)

print("  which saved answers are exported")

TestRunner:test("by default: translations and the two dictionary actions, never a chat", function()
    local set = Constants.resolveAnkiExportActions(nil)
    ok(set.translate and set.quick_define and set.dictionary, "the three short kinds")
    ok(not set.explain and not set.eli5, "an explanation is no card unless its action is ticked")
    local n = 0
    for _k in pairs(set) do n = n + 1 end
    eq(n, 3)
end)

TestRunner:test("a list the reader edited is taken as it is, an empty one included", function()
    local set = Constants.resolveAnkiExportActions({ "explain" })
    ok(set.explain and not set.translate)
    ok(next(Constants.resolveAnkiExportActions({})) == nil, "nothing ticked exports nothing")
end)

TestRunner:test("an answer follows its action; one whose action was not recorded follows its kind", function()
    local wanted = AnkiExport.wanted({ translate = true, dictionary = true })
    ok(wanted({ kind = "translate", action = "translate" }))
    ok(not wanted({ kind = "dictionary", action = "quick_define" }), "Quick Define is its own tick")
    ok(wanted({ kind = "translate" }), "a translation with no action recorded goes with Translate")
    ok(wanted({ kind = "dictionary" }), "a dictionary answer with none goes with Dictionary")
    ok(not wanted({ kind = "chat" }), "a chat with no action has no tick: never")
    ok(not wanted({ kind = "translate", action = "config_3" }), "a reader's own action is exported once ticked")
end)

print("  the card's back")

TestRunner:test("a translation alone: its lines", function()
    local a, pieces = noted({ translation("Morning rose grey\nover the harbour.") })
    eq(AnkiExport.back(a, pieces, opts()), "Morning rose grey<br>over the harbour.")
end)

TestRunner:test("a line the reader wrote under the translation is on the card", function()
    local a, pieces = noted({ translation("She had not slept a wink."), "fermer l'œil = to sleep (idiom)" })
    eq(AnkiExport.back(a, pieces, opts()), "She had not slept a wink.<br><br>fermer l'œil = to sleep (idiom)")
end)

TestRunner:test("a translation the reader corrected: the note as it reads now", function()
    local a, pieces = noted({ translation("Morning rose grey.", { changed = "Morning broke grey." }) })
    eq(pieces[1].text, nil, "the answer no longer stands as it was saved")
    eq(AnkiExport.back(a, pieces, opts()), "Morning broke grey.")
end)

TestRunner:test("an explanation kept on the same passage is left out, with the blank lines that held it", function()
    local a, pieces = noted({
        translation("Morning rose grey."),
        explanation("Explain:\n\nThe **verb** is in the simple past.\n\n- se lever\n- gris"),
        "my own line",
    })
    eq(AnkiExport.back(a, pieces, opts()), "Morning rose grey.<br><br>my own line")
end)

TestRunner:test("the same note with Explain ticked: the explanation drawn, its action's line a paragraph", function()
    local a, pieces = noted({
        translation("Morning rose grey."),
        explanation("Explain:\n\nThe **verb** is in the simple past."),
    })
    local back = AnkiExport.back(a, pieces, opts({ wanted = AnkiExport.wanted({ translate = true, explain = true }) }))
    ok(back:find("^Morning rose grey%."), "the translation first: " .. back)
    ok(back:find("<p>Explain:</p>", 1, true), "the action's line: " .. back)
    ok(back:find("<strong>verb</strong>", 1, true), "its bold word drawn: " .. back)
    ok(not back:find("**", 1, true), "no asterisks")
    ok(not back:find("\n"), "one line")
end)

TestRunner:test("a one-line definition is a bare line with its bold headword", function()
    local a, pieces = noted({ definition("**esquif**, noun: a small, light boat") }, { note_format = "md" })
    eq(AnkiExport.back(a, pieces, opts()), "<strong>esquif</strong>, noun: a small, light boat")
end)

TestRunner:test("a translation of several lines and a definition on one passage: each drawn its own way", function()
    -- KOReader shows this note as plain text (the plugin names no format when
    -- Markdown would run a translation's lines together): the card still
    -- draws the definition
    local a, pieces = noted({ translation("first line\nsecond line"), definition("**mot**, noun: a word") })
    eq(AnkiExport.back(a, pieces, opts()), "first line<br>second line<br><br><strong>mot</strong>, noun: a word")
end)

TestRunner:test("in a note KOReader draws as Markdown, the reader's own words are drawn too", function()
    local a, pieces = noted({ definition("**mot**, noun: a word"), "see also *parole*" }, { note_format = "md" })
    local back = AnkiExport.back(a, pieces, opts())
    ok(back:find("<em>parole</em>", 1, true), "their emphasis drawn: " .. back)
    ok(back:find("<strong>mot</strong>", 1, true))
end)

TestRunner:test("a definition the reader corrected in a Markdown note is drawn as the note reads", function()
    local a, pieces = noted({ definition("**mot**, noun: a word", { changed = "**mot**, noun: a word, a saying" }) },
        { note_format = "md" })
    eq(AnkiExport.back(a, pieces, opts()), "<strong>mot</strong>, noun: a word, a saying")
end)

TestRunner:test("with no Markdown conversion at hand the text's lines are written", function()
    local a, pieces = noted({ definition("**mot**, noun") }, { note_format = "md" })
    eq(AnkiExport.back(a, pieces, opts({ markdown = function() return nil end })), "**mot**, noun")
end)

print("  a row")

TestRunner:test("the cells: the highlight's creation time, the passage, the note, where it stands, what made it", function()
    local a, pieces = noted({ translation("Morning rose grey over the harbour.") },
        { chapter = "Chapter 1", pageno = 3 })
    local row = AnkiExport.row(a, pieces, opts())
    eq(#row, #AnkiExport.COLUMNS, "a cell per column")
    eq(row[1], "2026-11-24 09:12:41", "the id")
    eq(row[2], "Le matin se leva gris sur le port.", "the passage")
    eq(row[3], "Morning rose grey over the harbour.", "the note")
    eq(row[4], "The Grey Harbour")
    eq(row[5], "Chapter 1")
    eq(row[6], "3")
    eq(row[7], "Translate")
    eq(row[8], "KOAssistant translate The_Grey_Harbour")
end)

TestRunner:test("two answers on one passage: both named, each tagged once", function()
    local a, pieces = noted({ translation("one"), definition("**mot**, noun"), translation("two") })
    local row = AnkiExport.row(a, pieces, opts())
    eq(row[7], "Translate, Quick Define")
    eq(row[8], "KOAssistant translate quick_define The_Grey_Harbour")
end)

TestRunner:test("a reader's own action is tagged by its name, in one word", function()
    local own = { kind = "chat", action = "config_3", action_name = "Word by Word", text = "mot à mot" }
    local a, pieces = noted({ own })
    local row = AnkiExport.row(a, pieces, opts({ wanted = AnkiExport.wanted({ config_3 = true }) }))
    eq(row[7], "Word by Word")
    eq(row[8], "KOAssistant word_by_word The_Grey_Harbour")
end)

TestRunner:test("the page: the book's own page label first, then the page number", function()
    local a, pieces = noted({ translation("x") }, { pageref = "xii", pageno = 14 })
    eq(AnkiExport.row(a, pieces, opts())[6], "xii")
    a, pieces = noted({ translation("x") }, { page = 7 })
    eq(AnkiExport.row(a, pieces, opts())[6], "7", "a PDF's page")
    a, pieces = noted({ translation("x") }, { page = "/body/DocFragment[3]/body/p[2]/text().0" })
    eq(AnkiExport.row(a, pieces, opts())[6], "", "a position in the book is no page number")
end)

TestRunner:test("no row: a note with no saved answer, one whose answers are all unticked, no passage, no note", function()
    local a, pieces = noted({ "my own note" })
    eq(AnkiExport.row(a, nil, opts()), nil, "the reader's own note: KOReader's export has it")
    eq(AnkiExport.row(a, pieces, opts()), nil, "a record with nothing saved")
    a, pieces = noted({ explanation("a long explanation") })
    eq(AnkiExport.row(a, pieces, opts()), nil, "an explanation alone, Explain unticked")
    a, pieces = noted({ translation("x") }, { text = "" })
    eq(AnkiExport.row(a, pieces, opts()), nil, "a highlight with no text (a scanned page)")
    a, pieces = noted({ translation("x") }, { note = "  " })
    eq(AnkiExport.row(a, pieces, opts()), nil, "the note is gone")
end)

TestRunner:test("a corrected translation is still a row: the record says Translate saved an answer there", function()
    local a, pieces = noted({ translation("Morning rose grey.", { changed = "Morning broke grey." }) })
    local row = AnkiExport.row(a, pieces, opts())
    ok(row ~= nil)
    eq(row[3], "Morning broke grey.")
    eq(row[7], "Translate")
end)

TestRunner:test("a book's rows come in the book's own order of highlights", function()
    local a1, p1 = noted({ translation("one") })
    local a2 = noted({ "my own note" }, { datetime = "2026-11-24 09:13:00" })
    local a3, p3 = noted({ translation("three") }, { datetime = "2026-11-24 09:14:00" })
    local by = { [a1] = p1, [a3] = p3 }
    local rows = AnkiExport.rows({ a1, a2, a3, { note = "no creation time" } }, function(a) return by[a] end, opts())
    eq(#rows, 2)
    eq(rows[1][3], "one")
    eq(rows[2][1], "2026-11-24 09:14:00")
end)

print("  the column names")

TestRunner:test("the reader's own names for the first three columns", function()
    local own = AnkiExport.parseColumnNames(" NoteRef , phrase,english ")
    eq(table.concat(own, "|"), "NoteRef|phrase|english")
    eq(table.concat(AnkiExport.columnNames("NoteRef, phrase, english"), "|"),
        "NoteRef|phrase|english|Book|Chapter|Page|Kind|Tags")
    eq(table.concat(AnkiExport.columnNames(nil), "|"), "ID|Front|Back|Book|Chapter|Page|Kind|Tags", "none set")
    eq(AnkiExport.columnNamesText(nil), "ID, Front, Back")
    eq(AnkiExport.columnNamesText("NoteRef, phrase, english"), "NoteRef, phrase, english")
end)

TestRunner:test("names that cannot be a file's columns are refused, and the defaults stand", function()
    local function why(text) return select(2, AnkiExport.parseColumnNames(text)) end
    eq(why("a, b"), "count", "three names")
    eq(why("a, b, c, d"), "count")
    eq(why("a, , c"), "name", "an empty name")
    eq(why("a, b\tb, c"), "name", "a tab would cut the header in two")
    eq(why("a, \"b\", c"), "name")
    eq(why("a, a, c"), "twice", "two columns of one name")
    eq(why("ID, Front, Tags"), "twice", "a name one of the fixed columns has")
    eq(why(nil), "empty")
    eq(table.concat(AnkiExport.columnNames("a, a, c"), "|"), "ID|Front|Back|Book|Chapter|Page|Kind|Tags")
end)

print("  the file")

-- A separated file's line as its cells (a cell in double quotes holds doubled quotes)
local function cells(line)
    local out, i = {}, 1
    while i <= #line + 1 do
        if line:sub(i, i) == '"' then
            local j, buf = i + 1, {}
            while true do
                local q = line:find('"', j, true)
                assert(q, "a quoted cell that does not end")
                buf[#buf + 1] = line:sub(j, q - 1)
                if line:sub(q + 1, q + 1) == '"' then buf[#buf + 1] = '"'; j = q + 2 else j = q + 1 break end
            end
            out[#out + 1] = table.concat(buf)
            i = j + 1
        else
            local tab = line:find("\t", i, true) or (#line + 1)
            out[#out + 1] = line:sub(i, tab - 1)
            i = tab + 1
        end
    end
    return out
end

TestRunner:test("Anki's header lines, then one line per row", function()
    local a, pieces = noted({ translation("Morning rose grey.") }, { chapter = "Chapter 1", pageno = 3 })
    local text = AnkiExport.fileText({ AnkiExport.row(a, pieces, opts()) }, AnkiExport.columnNames(nil))
    local lines = {}
    for line in text:gmatch("([^\n]*)\n") do lines[#lines + 1] = line end
    eq(lines[1], "#separator:tab")
    eq(lines[2], "#html:true")
    eq(lines[3], "#columns:ID\tFront\tBack\tBook\tChapter\tPage\tKind\tTags")
    eq(lines[4], "#tags column:8", "the tags are the last column")
    eq(#lines, 5, "four header lines and the row")
    eq(lines[5], "2026-11-24 09:12:41\tLe matin se leva gris sur le port.\tMorning rose grey.\tThe Grey Harbour\tChapter 1\t3\tTranslate\tKOAssistant translate The_Grey_Harbour")
    eq(text:sub(-1), "\n", "the last line ends")
end)

TestRunner:test("the header carries the reader's own column names", function()
    local text = AnkiExport.fileText({}, AnkiExport.columnNames("NoteRef, phrase, english"))
    ok(text:find("#columns:NoteRef\tphrase\tenglish\tBook\t", 1, true))
end)

TestRunner:test("a row is one line whatever its note holds: tabs, line breaks, a code block, a link", function()
    local a, pieces = noted({ explanation("A\ttab and a [link](https://example.org/a).\n\n```\nline one\nline two\n```") },
        { text = "passage\twith a tab\nand a break", note_format = "md" })
    local row = AnkiExport.row(a, pieces, opts({ wanted = AnkiExport.wanted({ explain = true }) }))
    local text = AnkiExport.fileText({ row }, AnkiExport.columnNames(nil))
    local data = {}
    for line in text:gmatch("([^\n]*)\n") do
        if line:sub(1, 1) ~= "#" then data[#data + 1] = line end
    end
    eq(#data, 1, "one line")
    local got = cells(data[1])
    eq(#got, 8, "eight cells")
    eq(got[2], "passage with a tab<br>and a break")
    ok(got[3]:find('href="https://example.org/a"', 1, true), "the link's address whole: " .. got[3])
    ok(got[3]:find("line one<br>line two", 1, true), "the code block's lines: " .. got[3])
end)

TestRunner:test("a cell that starts with a quotation mark cannot be mistaken for a quoted cell", function()
    -- plain text writes the mark out as an entity; HTML that holds one is quoted whole
    local a, pieces = noted({ translation("\"Come here,\" she said.") }, { text = "\"Viens ici\", dit-elle." })
    local row = AnkiExport.row(a, pieces, opts())
    local line = AnkiExport.fileText({ row }, AnkiExport.columnNames(nil)):match("\n(2026[^\n]*)\n")
    local got = cells(line)
    eq(#got, 8)
    eq(got[2], "&quot;Viens ici&quot;, dit-elle.")
    eq(got[3], "&quot;Come here,&quot; she said.")
    local html = AnkiExport.fileText({ { "id", "front", '"quoted" <a href="x">y</a>', "", "", "", "", "" } },
        AnkiExport.columnNames(nil)):match("\n(id[^\n]*)\n")
    got = cells(html)
    eq(#got, 8, "still eight cells")
    eq(got[3], '"quoted" <a href="x">y</a>', "read back as written")
end)

TestRunner:test("the file's name: the book's, the same at every export", function()
    eq(Export.getAnkiFilename("The Grey Harbour: A Novel"), "The_Grey_Harbour_A_Novel_Anki.txt")
    eq(Export.getAnkiFilename(""), "Book_Anki.txt")
    eq(Export.getAnkiFilename(nil), "Book_Anki.txt")
    ok(not Export.getAnkiFilename("a/b\\c"):find("[/\\]"), "no path separator")
end)

print("  a book's export, written whole")

-- A book: its highlights, and the record the note writer keeps of them
local function book(notes)
    local store = { data = {}, readSetting = function(self, key) return self.data[key] end }
    local record, annotations = {}, {}
    for i, n in ipairs(notes) do
        local a, pieces = noted(n.stretches, n.more)
        a.datetime = ("2026-11-24 09:%02d:00"):format(i)
        local parts = {}
        for _j, piece in ipairs(pieces) do
            -- what the writer stored when it saved: where the answer sits, and its fingerprint
            local saved
            for _k, stretch in ipairs(n.stretches) do
                if type(stretch) == "table" and not saved and #stretch.text == piece.len then saved = stretch.text end
            end
            parts[#parts + 1] = { kind = piece.kind, action = piece.action, action_name = piece.action_name,
                from = piece.from, len = piece.len, sum = HighlightNote.fingerprint(saved) }
        end
        if #parts > 0 then record[a.datetime] = { parts = parts } end
        annotations[#annotations + 1] = a
    end
    store.data[HighlightNote.RECORD_KEY] = record
    return annotations, store
end

local function scratch()
    local dir = os.tmpname()
    os.remove(dir)
    os.execute("mkdir -p '" .. dir .. "'")
    return dir
end

local function read(path)
    local handle = io.open(path, "r")
    if not handle then return nil end
    local text = handle:read("*a")
    handle:close()
    return text
end

TestRunner:test("the open book: a file of its saved translations, read from the reader's own highlights", function()
    local annotations, store = book({
        { stretches = { translation("Morning rose grey.") }, more = { chapter = "Chapter 1", pageno = 3 } },
        { stretches = { "a note of my own" } },
        { stretches = { translation("She had not slept."), "my remark" } },
        { stretches = { explanation("Explain:\n\nA long explanation.") } },
    })
    package.loaded["koassistant.storage.doc_settings"] = { resolve = function() return store end }
    local dir = scratch()
    local ui = { document = { file = "/books/harbour.epub" }, annotation = { annotations = annotations } }
    local done, why = AnkiExport.forBook({ file = "/books/harbour.epub", ui = ui, features = {},
        title = "The Grey Harbour", dir = dir })
    ok(done, "written: " .. tostring(why))
    eq(done.count, 2, "the two translations; the reader's own note and the explanation are no rows")
    eq(done.path, dir .. "/The_Grey_Harbour_Anki.txt")
    local text = read(done.path)
    ok(text and text:find("#columns:ID\tFront\tBack", 1, true), "the header")
    ok(text:find("\tMorning rose grey.\t", 1, true))
    ok(text:find("\tShe had not slept.<br><br>my remark\t", 1, true), "the reader's remark on the card")
    ok(not text:find("explanation", 1, true), "the explanation is left out")
    eq(read(done.path .. ".tmp"), nil, "nothing left beside the file")

    -- the next export writes the whole file again: a corrected note, and Explain ticked
    annotations[1].note = "Morning broke grey."
    done = AnkiExport.forBook({ file = "/books/harbour.epub", ui = ui, title = "The Grey Harbour", dir = dir,
        features = { anki_export_actions = { "translate", "explain" }, anki_column_names = "NoteRef, phrase, english" } })
    eq(done.count, 3)
    text = read(done.path)
    ok(text:find("#columns:NoteRef\tphrase\tenglish\tBook", 1, true), "the reader's column names")
    ok(text:find("\tMorning broke grey.\t", 1, true), "the correction")
    ok(not text:find("Morning rose grey", 1, true), "nothing of the file before is left")
    ok(text:find("A long explanation.", 1, true))
    os.remove(done.path)
    os.remove(dir)
end)

TestRunner:test("a closed book: its highlights read from the book's own file", function()
    local annotations, store = book({ { stretches = { translation("Morning rose grey.") } } })
    package.loaded["koassistant.storage.doc_settings"] = { resolve = function() return store end }
    local asked
    package.loaded["koassistant.request.context_extractor"] = {
        readSidecarAnnotations = function(path) asked = path return annotations end,
    }
    local dir = scratch()
    -- another book is open: its highlights are not this book's
    local ui = { document = { file = "/books/other.epub" }, annotation = { annotations = {} } }
    local done = AnkiExport.forBook({ file = "/books/harbour.epub", ui = ui, features = {}, title = "Harbour", dir = dir })
    eq(asked, "/books/harbour.epub")
    eq(done and done.count, 1)
    os.remove(done.path)
    os.remove(dir)
end)

TestRunner:test("a book with nothing to export writes no file and says so", function()
    local annotations, store = book({ { stretches = { "a note of my own" } }, { stretches = { explanation("long") } } })
    package.loaded["koassistant.storage.doc_settings"] = { resolve = function() return store end }
    local dir = scratch()
    local ui = { document = { file = "/b.epub" }, annotation = { annotations = annotations } }
    local done, why = AnkiExport.forBook({ file = "/b.epub", ui = ui, features = {}, title = "B", dir = dir })
    eq(done, nil)
    eq(why, "none")
    eq(read(dir .. "/B_Anki.txt"), nil)
    os.remove(dir)
end)

TestRunner:test("a folder that cannot be written to: the reason, and no half file", function()
    local annotations, store = book({ { stretches = { translation("x") } } })
    package.loaded["koassistant.storage.doc_settings"] = { resolve = function() return store end }
    local ui = { document = { file = "/b.epub" }, annotation = { annotations = annotations } }
    local done, why = AnkiExport.forBook({ file = "/b.epub", ui = ui, features = {}, title = "B",
        dir = "/nonexistent-folder-for-this-test" })
    eq(done, nil)
    ok(type(why) == "string" and why ~= "none", "the system's own reason: " .. tostring(why))
end)

for _i, name in ipairs({ "koassistant.storage.doc_settings", "koassistant.request.context_extractor" }) do
    package.loaded[name] = SAVED[name]
end

print("  the viewer's own Markdown conversion")

TestRunner:test("a saved answer through the real conversion: drawn, on one line, none of the viewer's private marks left", function()
    local md_path = "/Applications/KOReader.app/Contents/koreader/frontend/apps/filemanager/lib/md.lua"
    local probe = io.open(md_path, "r")
    if not probe then
        print("    (skipped: KOReader's Markdown library is not at " .. md_path .. ")")
        return
    end
    probe:close()
    -- the real library and the real viewer in place of the unit runs' stand-ins, put back after
    local keys = { "apps/filemanager/lib/md", "koassistant.ui.chatgptviewer", "ffi/util" }
    local before = {}
    for _idx, k in ipairs(keys) do before[k] = package.loaded[k] end
    local util = package.loaded["ffi/util"] or {}
    local ordered = util.orderedPairs
    util.orderedPairs = util.orderedPairs or function(t)
        local names = {}
        for k in pairs(t) do names[#names + 1] = k end
        table.sort(names)
        local i = 0
        return function() i = i + 1; if names[i] ~= nil then return names[i], t[names[i]] end end
    end
    package.loaded["ffi/util"] = util
    package.loaded["apps/filemanager/lib/md"] = dofile(md_path)
    package.loaded["koassistant.ui.chatgptviewer"] = nil
    local passed, err = pcall(function()
        local quiet = require("koassistant.core.logger")
        local warn = quiet.warn
        quiet.warn = function() end
        local real = { wanted = AnkiExport.wanted({ quick_define = true, dictionary = true, explain = true }),
            markdown = AnkiExport.markdown, title = "B" }
        local a, pieces = noted({ definition("**esquif**, noun: a small, light boat") }, { note_format = "md" })
        eq(AnkiExport.back(a, pieces, real), "<strong>esquif</strong>, noun: a small, light boat",
            "a one-line definition: a bare line")
        a, pieces = noted({ explanation("Explain:\n\nThe **verb** is in the simple past, see [the note](https://example.org/a).\n\n"
            .. "3. third\n4. fourth\n\n- one\n- two\n\n```\nline one\nline two\n```\n\n| a | b |\n|---|---|\n| 1 | 2 |") },
            { note_format = "md" })
        local back = AnkiExport.back(a, pieces, real)
        quiet.warn = warn
        ok(not back:find("[\r\n\t]"), "one line, no tab")
        ok(back:find("<strong>verb</strong>", 1, true), "bold: " .. back)
        ok(back:find('href="https://example.org/a"', 1, true), "the link's address: " .. back)
        ok(back:find("line one<br>line two", 1, true), "the code block's lines kept: " .. back)
        ok(back:find("third", 1, true) and back:find("fourth", 1, true))
        ok(back:find(">3", 1, true) or back:find("3.", 1, true), "the list's own numbers: " .. back)
        ok(back:find("<li>", 1, true), "the bullet list: " .. back)
        ok(not back:find("\238[\128-\191][\128-\191]"), "no private-use mark of the viewer's is left: " .. back)
        ok(not back:find("**", 1, true) and not back:find("```", 1, true), "nothing shown as typed")
        -- the row is still one line with eight cells
        local row = AnkiExport.row(a, pieces, real)
        local line = AnkiExport.fileText({ row }, AnkiExport.columnNames(nil)):match("\n(2026[^\n]*)\n")
        ok(line ~= nil, "one data line")
    end)
    util.orderedPairs = ordered
    for _idx, k in ipairs(keys) do package.loaded[k] = before[k] end
    if not passed then error(err, 0) end
end)

print("")
print(string.format("  Results: %d passed, %d failed", TestRunner.passed, TestRunner.failed))
return TestRunner.failed == 0
