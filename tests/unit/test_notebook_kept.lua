-- A deleted book's notebook is kept (B756).
--
-- The notebook is the one file of a book's that can hold the reader's own
-- writing, and KOReader's own per-book notebook file outlives a deletion.
-- KOAssistant's hook on KOReader's delete removed every file it keeps beside
-- the book, the notebook among them. Now the notebook is moved to the
-- KOAssistant notebooks folder first, the Notebooks list shows it with the
-- words "book not on this device", and the reader is told once where it is.
--
-- Two halves, both on real files in a scratch folder:
--   * koassistant/chat/notebook.lua: keepDeleted (the move, never over
--     another file, never the book-side file gone before the copy is whole),
--     keptNotebooks (what the list shows) and readKept;
--   * main.lua's own hook, cut from the source and run: a delete, two deletes
--     in one go, a move that fails, a notebook with nothing in it, and a
--     moved book, whose notebook still travels with it.
--
-- Run: lua tests/unit/test_notebook_kept.lua  (or lua tests/run_tests.lua --unit)

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

local SAVED = {}
for _i, name in ipairs({ "docsettings", "datastorage", "koassistant.storage.doc_settings", "koassistant.chat.notebook",
        "koassistant.storage.book_store", "koassistant.images.image_generator", "koassistant.books.book_groups",
        "koassistant.xray.xray_merge" }) do
    SAVED[name] = package.loaded[name]
end
local orig_G_reader_settings = _G.G_reader_settings

-- ── a scratch folder of real files, removed file by file at the end ─────────
local tmp = os.tmpname()
os.remove(tmp)
local ROOT = tmp .. "_kept"
local made_dirs, made_files = {}, {}
local function mkdir(dir)
    os.execute("mkdir -p '" .. dir .. "'")
    made_dirs[#made_dirs + 1] = dir
end
local function write(path, content)
    local f = assert(io.open(path, "w"))
    f:write(content)
    f:close()
    made_files[path] = true
end
local function slurp(path)
    local f = io.open(path, "r")
    if not f then return nil end
    local s = f:read("*a")
    f:close()
    return s
end
local function exists(path) return slurp(path) ~= nil end

local BOOKS, DATA = ROOT .. "/books", ROOT .. "/data"
mkdir(ROOT); mkdir(BOOKS); mkdir(DATA)
local KEPT_DIR = DATA .. "/koassistant_notebooks"

-- ── stand-ins ───────────────────────────────────────────────────────────────
local grs_store = { features = {} }
_G.G_reader_settings = {
    readSetting = function(_, key, default)
        if grs_store[key] == nil then return default end
        return grs_store[key]
    end,
    saveSetting = function(_, key, value) grs_store[key] = value end,
    flush = function() end,
}
local props = {}
local function storeFor(path)
    return {
        readSetting = function(_, key) if key == "doc_props" then return props[path] end end,
        saveSetting = function() end, flush = function() end, close = function() end,
    }
end
local original_calls = {}
local DocSettings = {
    open = function(_, path) return storeFor(path) end,
    getSidecarDir = function(_, path) return (path:gsub("%.[^%./]+$", "")) .. ".sdr" end,
    isHashLocationEnabled = function() return false end,
    updateLocation = function(old_path, new_path, copy)
        original_calls[#original_calls + 1] = { old = old_path, new = new_path, copy = copy }
    end,
}
package.loaded["docsettings"] = DocSettings
package.loaded["datastorage"] = { getDataDir = function() return DATA end, getSettingsDir = function() return DATA end }
package.loaded["koassistant.storage.doc_settings"] = {
    resolve = function(path) return storeFor(path) end,
    overlayCustomProps = function(raw) return raw end,
}
local util_mod = package.loaded["util"]
if not util_mod then util_mod = {}; package.loaded["util"] = util_mod end
local orig_makePath = util_mod.makePath
util_mod.makePath = function(dir)
    os.execute("mkdir -p '" .. dir .. "' 2>/dev/null")
    made_dirs[#made_dirs + 1] = dir
end

package.loaded["koassistant.chat.notebook"] = nil
local Notebook = require("koassistant.chat.notebook")
local lfs = require("libs/libkoreader-lfs")
local TestRunner = require("test_runner"):new()
local function truthy(v, msg) TestRunner:assertEqual(v and true or false, true, msg) end

print("")
print(string.rep("=", 50))
print("  Unit Tests: a deleted book's notebook is kept")
print(string.rep("=", 50))

local HEADER = "# Notebook: A Quiet Road\n\n---\n\n"
local ENTRY = "**[2026-11-20 10:00:00]**\n\nPage 12 (8%)\n\n**User:** my own thought about this page\n\n---\n\n"

-- a book with its folder of plugin files, as KOReader leaves them at a delete:
-- the book's own file is already gone
local function book(name, title, notebook)
    local path = BOOKS .. "/" .. name .. ".epub"
    local sdr = BOOKS .. "/" .. name .. ".sdr"
    mkdir(sdr)
    props[path] = { title = title, authors = "Some Author" }
    if notebook then write(sdr .. "/" .. Notebook.SIDECAR_FILE, notebook) end
    return path, sdr
end
local function keptFiles()
    local out = {}
    if lfs.attributes(KEPT_DIR, "mode") == "directory" then
        for f in lfs.dir(KEPT_DIR) do
            if f ~= "." and f ~= ".." then out[#out + 1] = f; made_files[KEPT_DIR .. "/" .. f] = true end
        end
    end
    table.sort(out)
    return out
end

-- ── the module ──────────────────────────────────────────────────────────────
print("\n  [" .. "Notebook.keepDeleted" .. "]")

TestRunner:test("a notebook with entries is moved to the notebooks folder under the book's name, whole", function()
    local path, sdr = book("road", "A Quiet Road", HEADER .. ENTRY)
    local kept, why = Notebook.keepDeleted(path, sdr .. "/" .. Notebook.SIDECAR_FILE)
    TestRunner:assertEqual(why, nil, "no reason: it was kept")
    TestRunner:assertEqual(kept, KEPT_DIR .. "/Some Author \u{2014} A Quiet Road.md", "named as a notebook of that folder is")
    local text = slurp(kept)
    truthy(text ~= nil and text:sub(-#(HEADER .. ENTRY)) == HEADER .. ENTRY, "the reader's text is there, byte for byte")
    truthy(text:find('^%-%-%-\ntitle: "A Quiet Road"\nauthor: "Some Author"\nbook_path: "' .. path:gsub("%p", "%%%0") .. '"\n'),
        "under the front matter a notebook there carries: " .. text:sub(1, 120):gsub("\n", " / "))
    TestRunner:assertEqual(exists(sdr .. "/" .. Notebook.SIDECAR_FILE), false, "the book-side file is gone once the copy is whole")
    TestRunner:assertEqual(Notebook.readKept(kept), HEADER .. ENTRY, "readKept shows it without the front matter")
end)

TestRunner:test("a notebook that holds only the header this plugin writes is not kept", function()
    local path, sdr = book("empty", "An Empty One", "# Notebook: An Empty One\n\n---\n\n")
    local before = #keptFiles()
    local kept, why = Notebook.keepDeleted(path, sdr .. "/" .. Notebook.SIDECAR_FILE)
    TestRunner:assertEqual(kept, nil, "nothing kept")
    TestRunner:assertEqual(why, "empty", "and the reason says so")
    TestRunner:assertEqual(#keptFiles(), before, "no file was written")
    TestRunner:assertEqual(exists(sdr .. "/" .. Notebook.SIDECAR_FILE), true, "the caller removes it with the rest")
end)

TestRunner:test("a name already taken is never written over: the next free name", function()
    -- the same title deleted a second time (the book was added again and written in again)
    local path, sdr = book("road2", "A Quiet Road", HEADER .. "second copy\n")
    local first = slurp(KEPT_DIR .. "/Some Author \u{2014} A Quiet Road.md")
    local kept = Notebook.keepDeleted(path, sdr .. "/" .. Notebook.SIDECAR_FILE)
    TestRunner:assertEqual(kept, KEPT_DIR .. "/Some Author \u{2014} A Quiet Road (2).md", "the next free name")
    TestRunner:assertEqual(slurp(KEPT_DIR .. "/Some Author \u{2014} A Quiet Road.md"), first, "the first kept notebook is untouched")
    truthy(slurp(kept):find("second copy", 1, true), "the second holds its own text")
end)

TestRunner:test("a copy that cannot be written leaves the book-side file where it is", function()
    local path, sdr = book("stuck", "Stuck / Title", HEADER .. ENTRY)
    -- the folder cannot take the file: writeWhole reports it
    local saved = Notebook._writeWhole
    local real_open = io.open
    io.open = function(p, mode) -- luacheck: ignore 122
        if mode == "w" and p:find(KEPT_DIR, 1, true) == 1 then return nil, "no space" end
        return real_open(p, mode)
    end
    local kept, why = Notebook.keepDeleted(path, sdr .. "/" .. Notebook.SIDECAR_FILE)
    io.open = real_open -- luacheck: ignore 122
    TestRunner:assertEqual(kept, nil, "nothing kept")
    truthy(why ~= nil and why ~= "empty", "with a reason: " .. tostring(why))
    TestRunner:assertEqual(slurp(sdr .. "/" .. Notebook.SIDECAR_FILE), HEADER .. ENTRY, "the notebook is still beside the book, whole")
    truthy(saved ~= nil, "the checked writer is the module's own")
end)

print("\n  [" .. "Notebook.keptNotebooks" .. "]")

TestRunner:test("it lists the notebooks whose book is gone, with what their front matter says", function()
    local list = Notebook.keptNotebooks()
    TestRunner:assertEqual(#list, 2, "the two kept so far")
    TestRunner:assertEqual(list[1].title, "A Quiet Road", "its title")
    TestRunner:assertEqual(list[1].author, "Some Author", "its author")
    TestRunner:assertEqual(list[1].book_path, BOOKS .. "/road2.epub", "the path the book had (sorted by file: the (2) first)")
    truthy(type(list[1].modified) == "number" and (list[1].size or 0) > 0, "date and size for the row")
end)

TestRunner:test("never a notebook whose book is there, one a book is linked to, a hand-made file or a dot file", function()
    mkdir(KEPT_DIR)
    -- a notebook of a book that is still on the device (a leftover of another save location)
    write(BOOKS .. "/here.epub", "book")
    write(KEPT_DIR .. "/Here.md", '---\ntitle: "Here"\nbook_path: "' .. BOOKS .. '/here.epub"\ncreated: 2026-11-20\n---\n# Notebook: Here\n')
    -- a notebook a book of the index is linked to: its recorded path is stale after a move
    write(KEPT_DIR .. "/Linked.md", '---\ntitle: "Linked"\nbook_path: "' .. BOOKS .. '/gone-old-place.epub"\ncreated: 2026-11-20\n---\ntext\n')
    grs_store.koassistant_notebook_index = { [BOOKS .. "/moved.epub"] = { filename = "Linked.md", size = 1, modified = 1 } }
    -- a file made by hand, and what macOS writes beside a copied file
    write(KEPT_DIR .. "/By hand.md", "my own file\n")
    write(KEPT_DIR .. "/._Some Author \u{2014} A Quiet Road.md", '---\nbook_path: "/nowhere.epub"\n---\n')
    local names = {}
    for _i, k in ipairs(Notebook.keptNotebooks()) do names[#names + 1] = k.filename end
    TestRunner:assertEqual(table.concat(names, " | "),
        "Some Author \u{2014} A Quiet Road (2).md | Some Author \u{2014} A Quiet Road.md", "only the two whose book is gone")
    grs_store.koassistant_notebook_index = nil
end)

TestRunner:test("with another notebooks folder in use, its orphans are listed too", function()
    local custom = ROOT .. "/vault"
    mkdir(custom)
    write(custom .. "/Old Friend.md", '---\ntitle: "Old Friend"\nauthor: "A. Writer"\nbook_path: "' .. BOOKS .. '/friend.epub"\ncreated: 2026-01-01\n---\n# Notebook: Old Friend\n\nnotes\n')
    grs_store.features = { notebook_save_location = "custom", notebook_custom_path = custom }
    local found
    for _i, k in ipairs(Notebook.keptNotebooks()) do
        if k.filename == "Old Friend.md" then found = k end
    end
    grs_store.features = {}
    truthy(found ~= nil and found.author == "A. Writer", "the folder in use is read as well as KOAssistant's own")
    local again = Notebook.keptNotebooks()
    for _i, k in ipairs(again) do
        truthy(k.filename ~= "Old Friend.md", "and not once the reader is back on another location")
    end
end)

-- ── main.lua's hook on KOReader's delete, cut from the source and run ───────
local f = assert(io.open(PLUGIN_DIR .. "/main.lua", "r"))
local main_src = f:read("*a")
f:close()
local from = assert(main_src:find("-- The notebooks kept from books deleted in one go", 1, true), "the hook's notice is found")
local fn_at = assert(main_src:find("function AskGPT:patchDocSettingsForChatIndex()", from, true))
local to = assert(main_src:find("\nend\n", fn_at, true))

local shown, ticks, warned = {}, {}, {}
local UIManager = {
    show = function(_, w) shown[#shown + 1] = w end,
    nextTick = function(_, fn) ticks[#ticks + 1] = fn end,
}
local InfoMessage = { new = function(_, o) return o end }
local logger = {
    dbg = function() end, info = function() end, err = function() end,
    warn = function(...) warned[#warned + 1] = table.concat({ ... }, " ") end,
}
local moved_copy = {}
local function copyFileContent(a, b)
    moved_copy[#moved_copy + 1] = { a, b }
    local text = slurp(a)
    if not text then return false, "unreadable" end
    write(b, text)
    return true
end
local Registry = require("koassistant.storage.storage_registry")
local chunk = table.concat({
    "local UIManager, InfoMessage, _, T, logger, lfs, util, copyFileContent, KOASSISTANT_SIDECAR_FILES, KOASSISTANT_INDICES = ...",
    "local AskGPT = {}",
    main_src:sub(from, to + 4),
    "return AskGPT",
}, "\n")
package.loaded["koassistant.storage.book_store"] = { invalidate = function() end }
package.loaded["koassistant.images.image_generator"] = { updateIndexForMove = function() end }
package.loaded["koassistant.books.book_groups"] = { updateForMove = function() end }
local noted_moves = {}
package.loaded["koassistant.xray.xray_merge"] = { noteMoved = function(a, b) noted_moves[#noted_moves + 1] = { a, b } end }
local AskGPT = assert(load(chunk, "=main.lua (cut)"))(UIManager, InfoMessage, function(s) return s end,
    function(s, ...)
        local args = { ... }
        return (s:gsub("%%(%d)", function(n) return tostring(args[tonumber(n)]) end))
    end, logger, lfs, package.loaded["util"], copyFileContent, Registry.sidecarFiles(), Registry.indexKeys())
AskGPT:patchDocSettingsForChatIndex()
local hook = DocSettings.updateLocation
local function runTicks()
    local fns = ticks
    ticks = {}
    for _i, fn in ipairs(fns) do fn() end
end

print("\n  [" .. "the delete hook (main.lua, cut from the source)" .. "]")

TestRunner:test("the hook is installed over KOReader's own function, which still runs", function()
    truthy(hook ~= nil and hook ~= DocSettings._original_updateLocation, "the hook stands in")
    truthy(DocSettings._koassistant_patched, "and is marked installed")
end)

TestRunner:test("a deleted book: its notebook is kept, its other files go, the reader is told once", function()
    local path, sdr = book("gone", "Gone Book", "# Notebook: Gone Book\n\n---\n\n" .. ENTRY)
    write(sdr .. "/koassistant_cache.lua", "return {}")
    write(sdr .. "/koassistant_chats.lua", "return {}")
    grs_store.koassistant_notebook_index = { [path] = { size = 10, modified = 1 } }
    shown, ticks, warned, original_calls = {}, {}, {}, {}
    hook(path)
    local kept = KEPT_DIR .. "/Some Author \u{2014} Gone Book.md"
    truthy(slurp(kept) ~= nil and slurp(kept):find("my own thought about this page", 1, true), "the notebook is in the notebooks folder")
    TestRunner:assertEqual(exists(sdr .. "/" .. Notebook.SIDECAR_FILE), false, "and no longer beside the book")
    TestRunner:assertEqual(exists(sdr .. "/koassistant_cache.lua"), false, "the saved results beside the book are removed, as before")
    TestRunner:assertEqual(exists(sdr .. "/koassistant_chats.lua"), false, "the chats too, as before")
    TestRunner:assertEqual(#original_calls, 1, "KOReader's own function ran")
    TestRunner:assertEqual(original_calls[1].old, path, "for that book")
    TestRunner:assertEqual(grs_store.koassistant_notebook_index[path], nil, "the book's index entry is dropped")
    TestRunner:assertEqual(#shown, 0, "nothing is shown inside KOReader's own delete")
    TestRunner:assertEqual(#ticks, 1, "one notice waits for the next tick")
    runTicks()
    TestRunner:assertEqual(#shown, 1, "then one notice")
    truthy(shown[1].text:find(kept, 1, true) and shown[1].text:find("was kept", 1, true) and shown[1].text:find("Notebooks", 1, true),
        "it says the notebook was kept, where it is listed and where the file is: " .. shown[1].text:gsub("\n", " / "))
    TestRunner:assertEqual(#warned, 0, "no warning")
    made_files[kept] = true
end)

TestRunner:test("several books deleted in one go: one notice, with the count and the folder", function()
    shown, ticks = {}, {}
    for i = 1, 3 do
        local path = book("many" .. i, "Many " .. i, "# Notebook: Many\n\n---\n\n" .. ENTRY)
        hook(path)
        made_files[KEPT_DIR .. "/Some Author \u{2014} Many " .. i .. ".md"] = true
    end
    TestRunner:assertEqual(#ticks, 1, "one notice is scheduled for the three")
    runTicks()
    TestRunner:assertEqual(#shown, 1, "one notice")
    truthy(shown[1].text:find("3 deleted books", 1, true) and shown[1].text:find(KEPT_DIR, 1, true)
        and not shown[1].text:find("Many 1.md", 1, true), "the count and the folder, no single file: " .. shown[1].text:gsub("\n", " / "))
    -- the next delete starts a new notice
    local path = book("after", "After", "# Notebook: After\n\n---\n\n" .. ENTRY)
    hook(path)
    made_files[KEPT_DIR .. "/Some Author \u{2014} After.md"] = true
    TestRunner:assertEqual(#ticks, 1, "a later delete schedules its own")
    runTicks()
    truthy(shown[2] and shown[2].text:find("After.md", 1, true), "and names its file")
end)

TestRunner:test("a notebook that cannot be moved stays beside the book: never removed unsaved", function()
    local path, sdr = book("held", "Held Book", "# Notebook: Held Book\n\n---\n\n" .. ENTRY)
    write(sdr .. "/koassistant_cache.lua", "return {}")
    shown, ticks, warned = {}, {}, {}
    local real_open = io.open
    io.open = function(p, mode) -- luacheck: ignore 122
        if mode == "w" and p:find(KEPT_DIR, 1, true) == 1 then return nil, "no space" end
        return real_open(p, mode)
    end
    hook(path)
    io.open = real_open -- luacheck: ignore 122
    truthy(slurp(sdr .. "/" .. Notebook.SIDECAR_FILE) ~= nil
        and slurp(sdr .. "/" .. Notebook.SIDECAR_FILE):find("my own thought", 1, true), "the notebook is still there, whole")
    TestRunner:assertEqual(exists(sdr .. "/koassistant_cache.lua"), false, "the other files are removed as before")
    TestRunner:assertEqual(#ticks, 0, "no notice of a kept notebook")
    TestRunner:assertEqual(#warned, 1, "one warning in the log")
    truthy(not warned[1]:find("my own thought", 1, true), "which holds nothing of the notebook's text")
end)

TestRunner:test("a notebook that failed with an error is left too", function()
    local path, sdr = book("thrown", "Thrown", "# Notebook: Thrown\n\n---\n\n" .. ENTRY)
    local real = Notebook.keepDeleted
    Notebook.keepDeleted = function() error("boom") end
    ticks, warned = {}, {}
    hook(path)
    Notebook.keepDeleted = real
    TestRunner:assertEqual(exists(sdr .. "/" .. Notebook.SIDECAR_FILE), true, "left where it is")
    TestRunner:assertEqual(#warned, 1, "with a warning")
end)

TestRunner:test("a notebook with nothing in it goes with the book", function()
    local path, sdr = book("blank", "Blank", "# Notebook: Blank\n\n---\n\n")
    shown, ticks, warned = {}, {}, {}
    local before = #keptFiles()
    hook(path)
    TestRunner:assertEqual(exists(sdr .. "/" .. Notebook.SIDECAR_FILE), false, "removed, as before")
    TestRunner:assertEqual(#keptFiles(), before, "nothing kept")
    TestRunner:assertEqual(#ticks, 0, "no notice")
    TestRunner:assertEqual(#warned, 0, "no warning")
end)

TestRunner:test("a moved book takes its notebook with it, as before: nothing is kept", function()
    local path, sdr = book("mover", "Mover", "# Notebook: Mover\n\n---\n\n" .. ENTRY)
    local new_path = BOOKS .. "/shelf/mover.epub"
    mkdir(BOOKS .. "/shelf")
    local before = #keptFiles()
    ticks = {}
    hook(path, new_path)
    local new_file = BOOKS .. "/shelf/mover.sdr/" .. Notebook.SIDECAR_FILE
    made_files[new_file] = true
    made_dirs[#made_dirs + 1] = BOOKS .. "/shelf/mover.sdr"
    truthy(slurp(new_file) ~= nil and slurp(new_file):find("my own thought", 1, true), "the notebook is beside the book's new place")
    TestRunner:assertEqual(exists(sdr .. "/" .. Notebook.SIDECAR_FILE), false, "and left the old one")
    TestRunner:assertEqual(#keptFiles(), before, "nothing went to the notebooks folder")
    TestRunner:assertEqual(#ticks, 0, "no notice")
end)

-- ── the Notebooks list shows them ──────────────────────────────────────────
print("\n  [" .. "the Notebooks list" .. "]")

TestRunner:test("its source lists the kept notebooks, marks them and opens their own options", function()
    local mf = assert(io.open(PLUGIN_DIR .. "/koassistant/chat/notebook_manager.lua", "r"))
    local src = mf:read("*a")
    mf:close()
    truthy(src:find("for _idx, kept in ipairs(Notebook.keptNotebooks()) do", 1, true), "the list reads keptNotebooks")
    truthy(src:find('T(_("%1 (book not on this device)"), display_text)', 1, true), "a kept notebook's row says the book is not on this device")
    truthy(src:find("self_ref:showKeptNotebookOptions(captured_doc.kept, opts)", 1, true), "and opens the kept notebook's own options")
    local a = assert(src:find("function NotebookManager:showKeptNotebookOptions", 1, true))
    local body = src:sub(a, assert(src:find("\nend\n", a, true)))
    truthy(body:find("AskGPT:openKeptNotebook(kept)", 1, true), "View shows the file by its own path")
    truthy(body:find("os.remove(kept.path)", 1, true), "Delete removes that file")
    truthy(not body:find("Open Book", 1, true) and not body:find("openNotebookForFile", 1, true),
        "nothing there works on a book: there is none")
end)

-- ── clean up: the files this test made, then its folders, nothing else ─────
for path in pairs(made_files) do os.remove(path) end
for _i, name in ipairs(keptFiles()) do os.remove(KEPT_DIR .. "/" .. name) end
table.sort(made_dirs, function(a, b) return #a > #b end)
for _i, dir in ipairs(made_dirs) do os.remove(dir) end
os.remove(KEPT_DIR); os.remove(DATA); os.remove(BOOKS); os.remove(ROOT)

util_mod.makePath = orig_makePath
_G.G_reader_settings = orig_G_reader_settings
for name, mod in pairs(SAVED) do package.loaded[name] = mod end
for _i, name in ipairs({ "docsettings", "datastorage", "koassistant.storage.doc_settings", "koassistant.chat.notebook",
        "koassistant.storage.book_store", "koassistant.images.image_generator", "koassistant.books.book_groups",
        "koassistant.xray.xray_merge" }) do
    if SAVED[name] == nil then package.loaded[name] = nil end
end

return TestRunner:summary()
