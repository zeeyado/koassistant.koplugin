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
stub("koassistant.storage.doc_settings", { resolve = function() return store end })
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

for i = #saved, 1, -1 do package.loaded[saved[i].name] = saved[i].value end

return TestRunner:summary()
