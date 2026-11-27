-- Flow test (docs/test_automation_plan.md, layer 1): the Book Hub's row
-- "Export saved answers for Anki" (B722), through book_page.lua's real code
-- with the windows recorded (tests/lib/ui_recorder.lua).
--
-- A tap writes the book's file and says where it is; with the export
-- folder on "Ask every time" the folder is asked for first; a book with
-- nothing to export gets a notice that names the setting, and no file. What
-- the file holds has its own tests (test_anki_export.lua); the default
-- export folder is made in the real app's run.
--
-- Run: lua tests/unit/test_flow_anki_export.lua  (or lua tests/run_tests.lua --unit)

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
local Recorder = require("ui_recorder")

-- One Lua process runs every test file: everything replaced here goes back.
local saved = {}
local function stub(name, value)
    saved[#saved + 1] = { name = name, value = package.loaded[name] }
    package.loaded[name] = value
end
stub("ui/widget/menu", { new = function(cls, o) return setmetatable(o or {}, { __index = cls }) end })
stub("ui/widget/pathchooser", { new = function(cls, o)
    o = o or {}
    o._widget = "ui/widget/pathchooser"
    return setmetatable(o, { __index = cls })
end })
local store = { data = {}, readSetting = function(self, key) return self.data[key] end }
-- one book's own store where a test gives it one (the export of all books), else the shared one
local stores, resolved = {}, {}
stub("koassistant.storage.doc_settings", {
    resolve = function(file)
        resolved[#resolved + 1] = file
        return stores[file] or store
    end,
    effectiveProps = function(props) return props end,
})
-- KOReader's history and a closed book's highlights, for the export of all books
local history = { hist = {}, reload = function() end }
stub("readhistory", history)
local sidecar, sidecar_read = {}, {}
stub("koassistant.request.context_extractor", { readSidecarAnnotations = function(file)
    sidecar_read[#sidecar_read + 1] = file
    return sidecar[file] or {}
end })
stub("koassistant.books.book_page", nil)

local HighlightNote = require("koassistant.chat.highlight_note")
local BookPage = require("koassistant.books.book_page")

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

-- The open book with one saved translation, and the page's own context
local function context(features, with_answer)
    local note = "Morning rose grey over the harbour."
    local annotation = { datetime = "2026-11-24 09:12:41", text = "Le matin se leva gris sur le port.", note = note }
    store.data[HighlightNote.RECORD_KEY] = with_answer and {
        [annotation.datetime] = { parts = { { kind = "translate", action = "translate", action_name = "Translate",
            from = 1, len = #note, sum = HighlightNote.fingerprint(note) } } },
    } or {}
    local file = "/books/harbour.epub"
    return {
        file = file, title = "The Grey Harbour",
        ui = { document = { file = file }, annotation = { annotations = { annotation } } },
        plugin = { settings = { data = { features = features } } },
    }
end

print("  the Book Hub's row for Anki")

TestRunner:test("Save Location on Ask every time: the folder is asked for, then the file is written and its place said", function()
    local ui = Recorder.install()
    local dir = scratch()
    BookPage.exportForAnki(context({ export_save_directory = "ask" }, true))
    local chooser = ui:top()
    TestRunner:assertEqual(chooser and chooser._widget, "ui/widget/pathchooser", "the folder chooser")
    TestRunner:assertTrue(chooser.select_directory == true, "a folder is picked, not a file")
    chooser.onConfirm(dir)
    local notice = ui:top()
    TestRunner:assertEqual(notice and notice._widget, "ui/widget/infomessage")
    local path = dir .. "/The_Grey_Harbour_Anki.txt"
    TestRunner:assertTrue(notice.text:find(path, 1, true) ~= nil, "the notice names the file: " .. tostring(notice.text))
    TestRunner:assertTrue(notice.text:find("1", 1, true) ~= nil, "and how many answers it holds")
    TestRunner:assertTrue(notice.text:find("File > Import", 1, true) ~= nil, "and what to do in Anki")
    local text = read(path)
    ui:restore()
    TestRunner:assertTrue(text ~= nil, "the file is there")
    TestRunner:assertTrue(text:find("\tLe matin se leva gris sur le port.\tMorning rose grey over the harbour.\t", 1, true) ~= nil,
        "the passage and its translation")
    os.remove(path)
    os.remove(dir)
end)

TestRunner:test("a book with no saved answer: a notice that names the setting, and no file", function()
    local ui = Recorder.install()
    local dir = scratch()
    BookPage.exportForAnki(context({ export_save_directory = "ask" }, false))
    ui:top().onConfirm(dir)
    local notice = ui:top()
    ui:restore()
    TestRunner:assertEqual(notice and notice._widget, "ui/widget/infomessage")
    TestRunner:assertTrue(notice.text:find("Answers Exported for Anki", 1, true) ~= nil,
        "the setting that decides it: " .. tostring(notice.text))
    TestRunner:assertEqual(read(dir .. "/The_Grey_Harbour_Anki.txt"), nil, "nothing written")
    os.remove(dir)
end)

TestRunner:test("a folder that cannot be written to: the reason, said", function()
    local ui = Recorder.install()
    BookPage.exportForAnki(context({ export_save_directory = "ask" }, true))
    ui:top().onConfirm("/nonexistent-folder-for-this-test")
    local notice = ui:top()
    ui:restore()
    TestRunner:assertTrue(notice.text:find("could not be written", 1, true) ~= nil, tostring(notice.text))
end)

TestRunner:test("the page's menu has the row, and the row runs that export", function()
    local handle = assert(io.open(PLUGIN_DIR .. "/koassistant/books/book_page.lua", "r"))
    local src = handle:read("*a")
    handle:close()
    local from = src:find("local function showHamburger", 1, true)
    TestRunner:assertTrue(from ~= nil, "the menu's builder")
    local menu = src:sub(from, src:find("\nend\n", from, true))
    local row = menu:find('text = _("Export saved answers for Anki")', 1, true)
    TestRunner:assertTrue(row ~= nil, "the row")
    local next_row = menu:find("text = _(", row + 10, true)
    TestRunner:assertTrue(menu:sub(row, next_row):find("BookPage.exportForAnki(ctx)", 1, true) ~= nil,
        "its tap is the export")
end)

-- One file for all books (B788)
local function bookStore(title, record)
    return { data = { doc_props = { title = title }, [HighlightNote.RECORD_KEY] = record },
        readSetting = function(self, key) return self.data[key] end }
end
local function piece(note, action, name)
    return { kind = action == "translate" and "translate" or "chat", action = action, action_name = name,
        from = 1, len = #note, sum = HighlightNote.fingerprint(note) }
end

TestRunner:test("one file for all books: every book of KOReader's history with saved answers, each row carrying its book", function()
    local ui = Recorder.install()
    local dir = scratch()
    local ctx = context({ export_save_directory = "ask" }, true)   -- the open book, one saved translation
    ctx.ui.doc_props = { display_title = "The Grey Harbour" }
    local open_file = ctx.file
    stores[open_file] = bookStore("The Grey Harbour", store.data[HighlightNote.RECORD_KEY])
    -- a closed book with two saved answers, read from its own file
    local second = "/books/second.epub"
    local a = { datetime = "2026-11-25 10:00:01", text = "une lanterne", note = "a lantern" }
    local b = { datetime = "2026-11-25 10:00:02", text = "le port", note = "the harbour" }
    sidecar[second] = { a, b }
    stores[second] = bookStore("Second Book", {
        [a.datetime] = { parts = { piece(a.note, "translate", "Translate") } },
        [b.datetime] = { parts = { piece(b.note, "translate", "Translate") } },
    })
    -- a closed book whose one saved answer is of an action that is not exported
    local third = "/books/third.epub"
    local c = { datetime = "2026-11-25 11:00:00", text = "a passage", note = "a long explanation" }
    sidecar[third] = { c }
    stores[third] = bookStore("Third Book", { [c.datetime] = { parts = { piece(c.note, "explain", "Explain") } } })
    -- a book with nothing saved, and one that is no longer on the device
    local plain, gone = "/books/plain.epub", "/books/gone.epub"
    stores[plain] = bookStore("Plain Book", nil)
    history.hist = { { file = open_file }, { file = second }, { file = third }, { file = plain }, { file = gone, dim = true } }
    resolved, sidecar_read = {}, {}

    BookPage.exportForAnki({ plugin = ctx.plugin, ui = ctx.ui, all_books = true })
    ui:top().onConfirm(dir)
    local notice = ui:top()
    local path = dir .. "/KOAssistant_All_Books_Anki.txt"
    local text = read(path)
    ui:restore()
    TestRunner:assertEqual(notice and notice._widget, "ui/widget/infomessage")
    TestRunner:assertTrue(notice.text:find(path, 1, true) ~= nil, "the notice names the one file: " .. tostring(notice.text))
    TestRunner:assertTrue(notice.text:find("3 (books: 2)", 1, true) ~= nil, "three answers from two books: " .. tostring(notice.text))
    TestRunner:assertTrue(text ~= nil, "the file is there")
    local rows = {}
    for line in text:gmatch("[^\n]+") do
        if line:sub(1, 1) ~= "#" then rows[#rows + 1] = line end
    end
    TestRunner:assertEqual(#rows, 3, "one row per saved answer")
    TestRunner:assertTrue(rows[1]:find("\tThe Grey Harbour\t", 1, true) ~= nil and rows[1]:find("The_Grey_Harbour", 1, true) ~= nil,
        "the open book's row names its book, as a column and as a tag")
    TestRunner:assertTrue(rows[2]:find("^2026%-11%-25 10:00:01\tune lanterne\ta lantern\tSecond Book\t") ~= nil,
        "a closed book's rows come from its own file: " .. rows[2])
    TestRunner:assertTrue(rows[3]:find("Second_Book", 1, true) ~= nil)
    TestRunner:assertEqual(text:find("a long explanation", 1, true), nil, "an action that is not exported stays out")
    -- what was read: a book with nothing on record is not opened any further, a book that is gone not at all
    local read_set = {}
    for _i, file in ipairs(sidecar_read) do read_set[file] = true end
    TestRunner:assertEqual(read_set[plain], nil, "no saved answer on record: its highlights are not read")
    TestRunner:assertTrue(read_set[second] == true and read_set[third] == true)
    TestRunner:assertEqual(read_set[open_file], nil, "the open book's highlights are the live ones")
    for _i, file in ipairs(resolved) do TestRunner:assertTrue(file ~= gone, "a book no longer on the device is skipped") end
    os.remove(path)
    os.remove(dir)
end)

TestRunner:test("all books and nothing saved anywhere: a notice that names the setting, and no file", function()
    local ui = Recorder.install()
    local dir = scratch()
    local ctx = context({ export_save_directory = "ask" }, false)
    stores = {}
    history.hist = { { file = ctx.file }, { file = "/books/other.epub" } }
    BookPage.exportForAnki({ plugin = ctx.plugin, ui = ctx.ui, all_books = true })
    ui:top().onConfirm(dir)
    local notice = ui:top()
    ui:restore()
    TestRunner:assertTrue(notice.text:find("No book has saved answers", 1, true) ~= nil, tostring(notice.text))
    TestRunner:assertTrue(notice.text:find("Answers Exported for Anki", 1, true) ~= nil)
    TestRunner:assertEqual(read(dir .. "/KOAssistant_All_Books_Anki.txt"), nil, "nothing written")
    os.remove(dir)
end)

TestRunner:test("the door: a row of Highlight Settings beside the two Anki rows, and it runs the export of all books", function()
    local Schema = require("koassistant.ui.settings_schema")
    local function find(id, items, parent)
        for i, item in ipairs(items or Schema.items) do
            if item.id == id then return item, parent, i end
            if item.items then
                local hit, p, at = find(id, item.items, item)
                if hit then return hit, p, at end
            end
        end
    end
    local row, parent, at = find("anki_export_all")
    TestRunner:assertTrue(row ~= nil, "the row")
    TestRunner:assertEqual(parent.id, "highlight_settings")
    TestRunner:assertEqual(parent.items[at - 1].id, "anki_column_names", "right after the other Anki rows")
    TestRunner:assertEqual(row.callback, "exportAllForAnki")
    TestRunner:assertEqual(row.keep_menu_open, true, "the notice shows over the menu")
    local handle = assert(io.open(PLUGIN_DIR .. "/main.lua", "r"))
    local main = handle:read("*a")
    handle:close()
    local from = assert(main:find("\nfunction AskGPT:exportAllForAnki(", 1, true), "the row's function")
    local body = main:sub(from, main:find("\nend\n", from, true))
    TestRunner:assertTrue(body:find("exportForAnki({ plugin = self, ui = self.ui, all_books = true })", 1, true) ~= nil,
        "the Book Hub's own export, for all books")
end)

for i = #saved, 1, -1 do package.loaded[saved[i].name] = saved[i].value end

return TestRunner:summary()
