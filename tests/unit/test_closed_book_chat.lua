-- B387: a chat about a closed book, started while another book is open (a Book
-- Hub's "book not open" row, a group hub, the artifact browser), is that book's
-- chat: its title, author, settings and save place, its saved position, its own
-- artifact cache, and no book tools (they search the open book). Before the fix
-- the dialog took the open book's identity first, the request named the open
-- book, the chat was saved under it, an artifact action cached its answer in
-- the open book's file, and the launcher scanned the open book's first page for
-- a DOI it then cached as the other book's.
--
-- The dialog's expressions are cut from the source and evaluated (the
-- test_front_matter_flow pattern): a guard that only greps can pass while the
-- code it names never runs.
--
-- Run: lua tests/unit/test_closed_book_chat.lua  (or lua tests/run_tests.lua --unit)

local function setupPaths()
    local info = debug.getinfo(1, "S")
    local script_path = info.source:match("@?(.*)")
    local unit_dir = script_path:match("(.+)/[^/]+$") or "."
    local tests_dir = unit_dir:match("(.+)/[^/]+$") or "."
    local plugin_dir = tests_dir:match("(.+)/[^/]+$") or "."
    package.path = table.concat({
        plugin_dir .. "/?.lua",
        plugin_dir .. "/koassistant_api/?.lua",
        tests_dir .. "/?.lua",
        tests_dir .. "/lib/?.lua",
        package.path,
    }, ";")
    return plugin_dir
end
local plugin_dir = setupPaths()
require("mock_koreader")
local TestRunner = require("test_runner"):new()
local BookToolRunner = require("koassistant_book_tool_runner")

local function source(rel)
    local f = assert(io.open(plugin_dir .. "/" .. rel, "r"))
    local s = f:read("*a")
    f:close()
    return s
end
local dialogs_src = source("koassistant_dialogs.lua")
local main_src = source("main.lua")

local function cut(src, pattern, what)
    local expr = src:match(pattern)
    assert(expr, what .. ": not found in the source")
    return expr
end

local A, B = "/books/open.epub", "/books/closed.epub"
local function bookCfg(target, extra)
    local f = { is_book_context = true, book_metadata = target and { file = target, title = "Closed" } }
    for k, v in pairs(extra or {}) do f[k] = v end
    return { features = f }
end
local function openUi(file) return { document = { file = file } } end

print("\n  [the dialog's identity]")

TestRunner:test("a book chat whose book is not the open one takes the closed-book branch", function()
    local cond = cut(dialogs_src, "\n%s*elseif (doc_file and not %(configuration and configuration%.features.-%)) then\n",
        "the open-document branch")
    local openBranch = assert(load("local doc_file, configuration = ...; return " .. cond, "identity"))
    TestRunner:assertFalse(openBranch(A, bookCfg(B)), "another book beside the open one")
    TestRunner:assertTrue(openBranch(A, bookCfg(A)), "the open book's own chat")
    TestRunner:assertTrue(openBranch(A, bookCfg(nil)), "no target: the open book")
    TestRunner:assertTrue(openBranch(A, { features = { book_metadata = { file = B } } }),
        "highlight context keeps the open book")
    TestRunner:assertFalse(openBranch(nil, bookCfg(B)), "nothing open: the closed-book branch")
end)

print("\n  [the Send's position line]")

local position_body = cut(dialogs_src,
    "local function appendSendPosition%(%)\n(.-)\n%s*end\n\n%s*%-%- Add appropriate context",
    "appendSendPosition")
local appendSendPosition = assert(load(
    "local configuration, book_metadata, ui_instance, document_path, parts = ...\n" .. position_body,
    "appendSendPosition"))

local function withExtractor(stats, fn)
    local saved = package.loaded["koassistant_context_extractor"]
    package.loaded["koassistant_context_extractor"] = {
        new = function() return {
            getReadingStats = function() return stats end,
            getReadingProgress = function() return { formatted = stats.progress } end,
        } end,
    }
    local ok, err = pcall(fn)
    package.loaded["koassistant_context_extractor"] = saved
    if not ok then error(err, 0) end
end

TestRunner:test("a closed book's chat sends its saved progress, never the open book's chapter", function()
    withExtractor({ chapter_title = "Open book chapter", page_number = "88", progress = "61%" }, function()
        local parts = {}
        local cfg = bookCfg(B)
        cfg.features.book_metadata.reading_progress = "12%"
        appendSendPosition(cfg, { title = "Closed" }, openUi(A), B, parts)
        TestRunner:assertEqual(table.concat(parts, "|"), "Reading progress: 12%", "its own saved position only")
    end)
end)

TestRunner:test("the open book's chat sends the live position, chapter and page", function()
    withExtractor({ chapter_title = "Chapter 3", page_number = "88", progress = "61%" }, function()
        local parts = {}
        local cfg = bookCfg(A)
        cfg.features.book_metadata.reading_progress = "40%"  -- the launcher's, superseded by live
        appendSendPosition(cfg, { title = "Open" }, openUi(A), A, parts)
        TestRunner:assertEqual(table.concat(parts, "|"),
            "Reading progress: 61%|Current chapter: Chapter 3|Page: 88", "live")
    end)
end)

TestRunner:test("a file-browser chat at level Full sends the book's saved progress", function()
    local parts = {}
    local cfg = bookCfg(B)
    cfg.features.book_metadata.reading_progress = "12%"
    appendSendPosition(cfg, { title = "Closed" }, {}, B, parts)
    TestRunner:assertEqual(table.concat(parts, "|"), "Reading progress: 12%", "it sent nothing before")
end)

TestRunner:test("Basic stats off sends no position for either", function()
    local parts = {}
    local cfg = bookCfg(B, { enable_basic_stats = false })
    cfg.features.book_metadata.reading_progress = "12%"
    appendSendPosition(cfg, {}, openUi(A), B, parts)
    TestRunner:assertEqual(#parts, 0, "nothing")
end)

print("\n  [book tools]")

TestRunner:test("tools never run for a request whose book is not the open one", function()
    local cfg = { provider = "gemini", features = { enable_book_text_extraction = true,
        book_metadata = { file = B } } }
    local ok, why = BookToolRunner.sessionEligible(cfg, openUi(A))
    TestRunner:assertFalse(ok, "not eligible")
    TestRunner:assertEqual(why, "no_book", "nothing to search: the button is omitted")
    cfg.features.book_metadata.file = A
    TestRunner:assertTrue((BookToolRunner.sessionEligible(cfg, openUi(A))), "the open book's own request")
    cfg.features.book_metadata = nil
    TestRunner:assertTrue((BookToolRunner.sessionEligible(cfg, openUi(A))), "no target: the open book")
end)

print("\n  [the artifact cache]")

TestRunner:test("a request caches under its own book: a highlight's is the open one", function()
    local block = cut(dialogs_src, "\n    (local per_book_file\n.-\n    end)\n    local per_book_ds", "per_book_file")
    local resolve = assert(load("local context, ui, config = ...\n" .. block .. "\nreturn per_book_file", "per_book_file"))
    TestRunner:assertEqual(resolve("book", openUi(A), bookCfg(B)), B, "a closed book beside the open one")
    TestRunner:assertEqual(resolve("book", openUi(A), bookCfg(A)), A, "the open book")
    TestRunner:assertEqual(resolve("book", {}, bookCfg(B)), B, "file browser, nothing open")
    TestRunner:assertEqual(resolve("book", openUi(A), bookCfg(nil)), A, "no target: the open book")
    TestRunner:assertEqual(resolve("highlight", openUi(A), { features = { book_metadata = { file = B } } }), A,
        "a highlight's stale book_metadata never wins")
    local p_cache = dialogs_src:find("local cache_file = per_book_file\n    if temp_config then temp_config._cache_file = cache_file end", 1, true)
    TestRunner:assertTrue(p_cache and p_cache > dialogs_src:find("local per_book_file", 1, true),
        "the write uses it and records it on the request's config")
end)

TestRunner:test("every completion opens the artifact where the request wrote it", function()
    local dlg = "local file = temp_config._cache_file or document_path\n%s*or %(ui_instance and ui_instance%.document and ui_instance%.document%.file%)"
    local n_dlg = select(2, dialogs_src:gsub(dlg, ""))
    local eda = "local file = temp_config._cache_file or document_path or (ui and ui.document and ui.document.file)"
    local n_eda = select(2, dialogs_src:gsub(eda:gsub("%p", "%%%0"), ""))
    TestRunner:assertEqual(n_dlg, 2, "the input dialog's two readers")
    TestRunner:assertEqual(n_eda, 3, "executeDirectAction's three readers")
    local read = assert(load("local temp_config, document_path, ui_instance = ...; return "
        .. cut(dialogs_src, "local file = (temp_config%._cache_file or document_path\n%s*or %(ui_instance.-%))\n", "a reader"), "reader"))
    TestRunner:assertEqual(read({ _cache_file = B }, A, openUi(A)), B, "the written file wins")
    TestRunner:assertEqual(read({}, A, openUi(A)), A, "no mark: the dialog's book")
    local preflight = assert(load("local document_path, ui_instance = ...; return "
        .. cut(dialogs_src, "local file = (document_path\n%s*or %(ui_instance and ui_instance%.document and ui_instance%.document%.file%))\n%s*local cached = ",
            "the pre-flight read"), "pre-flight"))
    TestRunner:assertEqual(preflight(B, openUi(A)), B, "the dialog's book before the open one")
    TestRunner:assertTrue(dialogs_src:find("cache_opts = {\n                    file = document_path,", 1, true),
        "the cached-action popup gets the dialog's book")
end)

TestRunner:test("every viewer the dialogs open names the book it shows", function()
    local missing = {}
    for call in dialogs_src:gmatch("viewCachedAction(%b())") do
        local depth, args = 0, 1
        for c in call:sub(2, -2):gmatch(".") do
            if c == "(" or c == "{" then depth = depth + 1
            elseif c == ")" or c == "}" then depth = depth - 1
            elseif c == "," and depth == 0 then args = args + 1 end
        end
        if args < 4 then missing[#missing + 1] = call:sub(1, 60) end
    end
    TestRunner:assertEqual(table.concat(missing, " | "), "", "viewCachedAction without the book")
    TestRunner:assertTrue(dialogs_src:find("plugin:_checkRequirements(action, document_path,", 1, true),
        "the dialog's requirement check judges its own book")
end)

TestRunner:test("executeDirectAction takes a book-level request's own book", function()
    local block = cut(dialogs_src,
        "(local forced_path = opts and opts%.document_path\n.-forced_path = target end\n%s*end)\n", "forced_path")
    local forced = assert(load("local opts, ui, configuration = ...\n" .. block .. "\nreturn forced_path", "forced_path"))
    TestRunner:assertEqual(forced(nil, openUi(A), bookCfg(B)), B, "a Regenerate from a closed book's hub")
    TestRunner:assertEqual(forced(nil, openUi(A), bookCfg(A)), nil, "the open book: no switch")
    TestRunner:assertEqual(forced(nil, openUi(A), { features = { book_metadata = { file = B } } }), nil,
        "a highlight-shaped request keeps the open book")
    TestRunner:assertEqual(forced({ document_path = "/books/third.epub" }, openUi(A), bookCfg(B)),
        "/books/third.epub", "an explicit path still wins")
end)

TestRunner:test("the cached-action popup reads the requested book, the open one only when it is that book", function()
    local fn = main_src:match("function AskGPT:showCacheActionPopup%(.-\nend\n")
    TestRunner:assertTrue(fn, "the popup")
    local head = cut(fn, "(local open_doc = self%.ui and self%.ui%.document\n.-if open_doc and open_doc%.file ~= file then open_doc = nil end)",
        "the popup's book")
    local pick = assert(load("local self, opts = ...\n" .. head .. "\nreturn file, open_doc", "popup"))
    local plugin = { ui = openUi(A) }
    local f, d = pick(plugin, { file = B })
    TestRunner:assertEqual(f, B, "the dialog's closed book")
    TestRunner:assertEqual(d, nil, "and no open document for it")
    f, d = pick(plugin, nil)
    TestRunner:assertEqual(f, A, "no book passed: the open one")
    TestRunner:assertEqual(d, plugin.ui.document, "with its document")
    local raw = {}
    for line in fn:gmatch("[^\n]+") do
        local code = line:gsub("%-%-.*$", "")
        if code:find("self.ui.document", 1, true) and not code:find("local open_doc =", 1, true) then
            raw[#raw + 1] = code
        end
    end
    TestRunner:assertEqual(#raw, 0, "every other read goes through open_doc: " .. table.concat(raw, " | "))
end)

TestRunner:test("an X-Ray lookup about another book opens its browser without the open book's UI", function()
    local block = cut(dialogs_src, "(local browser_ui = ui\n.-browser_ui = nil\n%s*end)\n", "browser_ui")
    local pick = assert(load("local ui, target_file = ...\n" .. block .. "\nreturn browser_ui", "browser_ui"))
    local ui = openUi(A)
    TestRunner:assertEqual(pick(ui, B), nil, "another book: no UI")
    TestRunner:assertEqual(pick(ui, A), ui, "the open book keeps it")
    TestRunner:assertTrue(dialogs_src:find("XrayBrowser:show(data, browser_metadata, browser_ui,", 1, true),
        "and the browser gets that")
end)

print("\n  [the launcher]")

TestRunner:test("the launcher hands the open book's document only to the open book's own chat", function()
    local fn = main_src:match("function AskGPT:showKOAssistantDialogForFile%(.-\nend\n")
    TestRunner:assertTrue(fn, "the launcher")
    local open_here = assert(load("local self, file = ...; return "
        .. cut(fn, "local open_here = (.-)\n", "open_here"), "open_here"))
    local plugin = { ui = { document = { file = A } } }
    TestRunner:assertTrue(open_here(plugin, A), "the open book")
    TestRunner:assertFalse(open_here(plugin, B), "another book")
    TestRunner:assertTrue(fn:find("buildBookMetadata(title, authors, file, raw_doc_props,\n      open_here and self.ui.document or nil, open_here and self.ui.doc_settings or nil)", 1, true),
        "document and settings only when open here")
    TestRunner:assertFalse(fn:find("DocSettings:open(", 1, true), "no raw DocSettings in the launcher")
    TestRunner:assertFalse(fn:find("koassistant.context_extractor", 1, true), "no dead live branch")
end)

return TestRunner:summary()
