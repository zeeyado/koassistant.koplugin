--[[
Unit Tests for koassistant_library_scanner.lua

Tests the library scanner's metadata extraction, status categorization,
structured output, and parameterized formatting.

Uses mock DocSettings/ReadHistory/DocumentRegistry — no real filesystem
scanning. Tests the logic, not I/O.

Run: lua tests/run_tests.lua --unit
]]

-- Setup test environment
local function setupPaths()
    local info = debug.getinfo(1, "S")
    local script_path = info.source:match("@?(.*)")
    local unit_dir = script_path:match("(.+)/[^/]+$") or "."
    local tests_dir = unit_dir:match("(.+)/[^/]+$") or "."
    local plugin_dir = tests_dir:match("(.+)/[^/]+$") or "."

    package.path = table.concat({
        plugin_dir .. "/?.lua",
        plugin_dir .. "/?/init.lua",
        tests_dir .. "/?.lua",
        tests_dir .. "/lib/?.lua",
        package.path,
    }, ";")
end
setupPaths()

require("mock_koreader")

-- ============================================================
-- Mock infrastructure for library scanner
-- ============================================================

-- Mock DocSettings: per-file sidecar data
local mock_sidecars = {}

package.loaded["docsettings"] = {
    open = function(_self, doc_path)
        local sidecar = mock_sidecars[doc_path] or {}
        return {
            readSetting = function(_self2, key)
                return sidecar[key]
            end,
        }
    end,
}

-- Mock DocumentRegistry: all test files are "supported"
local mock_supported_extensions = { epub = true, pdf = true, djvu = true, mobi = true, fb2 = true, txt = true }
package.loaded["document/documentregistry"] = {
    hasProvider = function(_self, file_path)
        local ext = file_path:match("%.([^%.]+)$")
        return ext and mock_supported_extensions[ext:lower()] or false
    end,
}

-- Mock ReadHistory
local mock_history = {}
package.loaded["readhistory"] = {
    hist = mock_history,
    reload = function() end,
}

-- Mock device
package.loaded["device"] = {
    home_dir = "/test/books",
    screen = { getSize = function() return { w = 600, h = 800 } end },
}

-- G_reader_settings global
G_reader_settings = {
    readSetting = function(_self, _key)
        return nil
    end,
}

-- Default settings with explicit scan folder (no fallback in scanner)
local DEFAULT_SETTINGS = { library_scan_folders = { "/test/books" } }

-- ============================================================
-- Test helpers
-- ============================================================

local TestRunner = {
    passed = 0,
    failed = 0,
}

function TestRunner:test(name, fn)
    local ok, err = pcall(fn)
    if ok then
        self.passed = self.passed + 1
        print(string.format("  \226\156\147 %s", name))
    else
        self.failed = self.failed + 1
        print(string.format("  \226\156\151 %s: %s", name, tostring(err)))
    end
end

function TestRunner:assertEqual(actual, expected, message)
    if actual ~= expected then
        error(string.format("%s: expected '%s', got '%s'",
            message or "Values not equal",
            tostring(expected),
            tostring(actual)), 2)
    end
end

function TestRunner:assertTrue(value, message)
    if not value then
        error(message or "Expected true", 2)
    end
end

function TestRunner:assertNil(value, message)
    if value ~= nil then
        error(string.format("%s: expected nil, got '%s'",
            message or "Expected nil",
            tostring(value)), 2)
    end
end

function TestRunner:assertContains(str, substr, message)
    if type(str) ~= "string" or not str:find(substr, 1, true) then
        error(string.format("%s: '%s' not found in '%s'",
            message or "String not found",
            tostring(substr),
            tostring(str)), 2)
    end
end

function TestRunner:assertNotContains(str, substr, message)
    if type(str) == "string" and str:find(substr, 1, true) then
        error(string.format("%s: '%s' unexpectedly found in '%s'",
            message or "String unexpectedly found",
            tostring(substr),
            tostring(str)), 2)
    end
end

function TestRunner:summary()
    local total = self.passed + self.failed
    print(string.format("\n%d/%d passed, %d failed", self.passed, total, self.failed))
    return self.failed == 0
end

--- Reset all mock state between tests
local function resetMocks()
    mock_sidecars = {}
    mock_history = {}
    package.loaded["readhistory"].hist = mock_history
end

--- Set up a mock sidecar for a file path
local function setSidecar(path, doc_props, summary, percent_finished)
    mock_sidecars[path] = {
        doc_props = doc_props,
        summary = summary,
        percent_finished = percent_finished,
    }
end

--- Add a history entry
local function addHistory(path, time)
    table.insert(mock_history, { file = path, time = time })
end

-- ============================================================
-- We need to mock lfs.dir to return our test file structure
-- instead of scanning real filesystem
-- ============================================================

local mock_filesystem = {}

local function setFilesystem(tree)
    mock_filesystem = tree
end

-- Override lfs with our mock for directory scanning
local mock_lfs = {
    dir = function(path)
        local entries = mock_filesystem[path]
        if not entries then
            return function() return nil end
        end
        -- Add . and ..
        local all_entries = { ".", ".." }
        for _idx, e in ipairs(entries) do
            table.insert(all_entries, e)
        end
        local i = 0
        return function()
            i = i + 1
            return all_entries[i]
        end
    end,
    attributes = function(path)
        -- Check if it's a directory (has entries in mock_filesystem)
        if mock_filesystem[path] then
            return { mode = "directory" }
        end
        -- Check if it's a file (appears as entry in some directory)
        local parent = path:match("^(.+)/[^/]+$")
        local name = path:match("([^/]+)$")
        if parent and mock_filesystem[parent] then
            for _idx, entry in ipairs(mock_filesystem[parent]) do
                if entry == name then
                    return { mode = "file" }
                end
            end
        end
        return nil
    end,
}
package.loaded["libs/libkoreader-lfs"] = mock_lfs

-- ============================================================
-- Load the module under test (after all mocks are set up)
-- ============================================================

-- Clear cached module to pick up our mocks
package.loaded["koassistant_library_scanner"] = nil
local LibraryScanner = require("koassistant_library_scanner")

-- ============================================================
-- Tests
-- ============================================================

print("\n=== Library Scanner Tests ===\n")

-- ----- Status Categorization -----

print("Status Categorization:")

TestRunner:test("complete status from sidecar", function()
    resetMocks()
    setFilesystem({
        ["/test/books"] = { "book.epub" },
    })
    setSidecar("/test/books/book.epub",
        { title = "Dune", authors = "Frank Herbert" },
        { status = "complete" },
        1.0
    )
    local result = LibraryScanner.scan(DEFAULT_SETTINGS, nil)
    TestRunner:assertEqual(result.stats.complete, 1, "Should be 1 complete")
    TestRunner:assertEqual(result.stats.total, 1, "Total should be 1")
    TestRunner:assertEqual(result.by_status.complete[1].title, "Dune")
end)

TestRunner:test("abandoned status from sidecar", function()
    resetMocks()
    setFilesystem({
        ["/test/books"] = { "book.epub" },
    })
    setSidecar("/test/books/book.epub",
        { title = "War and Peace", authors = "Leo Tolstoy" },
        { status = "abandoned" },
        0.23
    )
    local result = LibraryScanner.scan(DEFAULT_SETTINGS, nil)
    TestRunner:assertEqual(result.stats.abandoned, 1, "Should be 1 abandoned")
    TestRunner:assertEqual(result.by_status.abandoned[1].progress, 0.23)
end)

TestRunner:test("reading status from progress > 0", function()
    resetMocks()
    setFilesystem({
        ["/test/books"] = { "book.epub" },
    })
    setSidecar("/test/books/book.epub",
        { title = "Neuromancer", authors = "William Gibson" },
        nil,  -- no summary
        0.45
    )
    local result = LibraryScanner.scan(DEFAULT_SETTINGS, nil)
    TestRunner:assertEqual(result.stats.reading, 1, "Should be 1 reading")
end)

TestRunner:test("75%+ without explicit status treated as complete", function()
    resetMocks()
    setFilesystem({
        ["/test/books"] = { "book.epub" },
    })
    setSidecar("/test/books/book.epub",
        { title = "Short Book" },
        nil,  -- no explicit status
        0.82
    )
    local result = LibraryScanner.scan(DEFAULT_SETTINGS, nil)
    TestRunner:assertEqual(result.stats.complete, 1, "75%+ should be complete")
    TestRunner:assertEqual(result.stats.reading, 0, "Should not be reading")
end)

TestRunner:test("unread: sidecar exists but no progress", function()
    resetMocks()
    setFilesystem({
        ["/test/books"] = { "book.epub" },
    })
    setSidecar("/test/books/book.epub",
        { title = "Unopened" },
        nil,
        nil  -- no progress
    )
    local result = LibraryScanner.scan(DEFAULT_SETTINGS, nil)
    TestRunner:assertEqual(result.stats.unread, 1, "No progress should be unread")
end)

TestRunner:test("unread: no sidecar at all", function()
    resetMocks()
    setFilesystem({
        ["/test/books"] = { "new_book.epub" },
    })
    -- No setSidecar call — no sidecar exists
    local result = LibraryScanner.scan(DEFAULT_SETTINGS, nil)
    TestRunner:assertEqual(result.stats.unread, 1, "No sidecar should be unread")
    TestRunner:assertEqual(result.by_status.unread[1].title, "new_book")
end)

-- ----- Metadata Extraction -----

print("\nMetadata Extraction:")

TestRunner:test("extracts title from display_title", function()
    resetMocks()
    setFilesystem({ ["/test/books"] = { "book.epub" } })
    setSidecar("/test/books/book.epub",
        { display_title = "Display Title", title = "Raw Title" },
        nil, nil
    )
    local result = LibraryScanner.scan(DEFAULT_SETTINGS, nil)
    TestRunner:assertEqual(result.books[1].title, "Display Title")
end)

TestRunner:test("falls back to title when no display_title", function()
    resetMocks()
    setFilesystem({ ["/test/books"] = { "book.epub" } })
    setSidecar("/test/books/book.epub",
        { title = "Raw Title" },
        nil, nil
    )
    local result = LibraryScanner.scan(DEFAULT_SETTINGS, nil)
    TestRunner:assertEqual(result.books[1].title, "Raw Title")
end)

TestRunner:test("falls back to filename when no title", function()
    resetMocks()
    setFilesystem({ ["/test/books"] = { "my_book.epub" } })
    -- No sidecar
    local result = LibraryScanner.scan(DEFAULT_SETTINGS, nil)
    TestRunner:assertEqual(result.books[1].title, "my_book")
end)

TestRunner:test("normalizes multi-author newlines to commas", function()
    resetMocks()
    setFilesystem({ ["/test/books"] = { "book.epub" } })
    setSidecar("/test/books/book.epub",
        { title = "Book", authors = "Author One\nAuthor Two\nAuthor Three" },
        nil, nil
    )
    local result = LibraryScanner.scan(DEFAULT_SETTINGS, nil)
    TestRunner:assertEqual(result.books[1].author, "Author One, Author Two, Author Three")
end)

TestRunner:test("extracts series and language", function()
    resetMocks()
    setFilesystem({ ["/test/books"] = { "book.epub" } })
    setSidecar("/test/books/book.epub",
        { title = "Dune Messiah", authors = "Frank Herbert", series = "Dune", language = "en" },
        { status = "complete" }, 1.0
    )
    local result = LibraryScanner.scan(DEFAULT_SETTINGS, nil)
    TestRunner:assertEqual(result.books[1].series, "Dune")
    TestRunner:assertEqual(result.books[1].language, "en")
end)

TestRunner:test("empty series/language treated as nil", function()
    resetMocks()
    setFilesystem({ ["/test/books"] = { "book.epub" } })
    setSidecar("/test/books/book.epub",
        { title = "Book", series = "", language = "" },
        nil, nil
    )
    local result = LibraryScanner.scan(DEFAULT_SETTINGS, nil)
    TestRunner:assertNil(result.books[1].series, "Empty series should be nil")
    TestRunner:assertNil(result.books[1].language, "Empty language should be nil")
end)

-- ----- Folder & File Handling -----

print("\nFolder & File Handling:")

TestRunner:test("records source folder", function()
    resetMocks()
    setFilesystem({ ["/test/books"] = { "book.epub" } })
    setSidecar("/test/books/book.epub", { title = "Test" }, nil, nil)
    local result = LibraryScanner.scan(DEFAULT_SETTINGS, nil)
    TestRunner:assertEqual(result.books[1].folder, "/test/books")
end)

TestRunner:test("recursive scan finds nested books", function()
    resetMocks()
    setFilesystem({
        ["/test/books"] = { "top.epub", "subfolder" },
        ["/test/books/subfolder"] = { "nested.epub" },
    })
    setSidecar("/test/books/top.epub", { title = "Top" }, nil, nil)
    setSidecar("/test/books/subfolder/nested.epub", { title = "Nested" }, nil, nil)
    local result = LibraryScanner.scan(DEFAULT_SETTINGS, nil)
    TestRunner:assertEqual(result.stats.total, 2, "Should find 2 books")
end)

TestRunner:test("skips hidden files and folders", function()
    resetMocks()
    setFilesystem({
        ["/test/books"] = { ".hidden_dir", "visible.epub", ".hidden.epub" },
        ["/test/books/.hidden_dir"] = { "secret.epub" },
    })
    setSidecar("/test/books/visible.epub", { title = "Visible" }, nil, nil)
    local result = LibraryScanner.scan(DEFAULT_SETTINGS, nil)
    TestRunner:assertEqual(result.stats.total, 1, "Should only find visible book")
    TestRunner:assertEqual(result.books[1].title, "Visible")
end)

TestRunner:test("skips unsupported file types", function()
    resetMocks()
    setFilesystem({
        ["/test/books"] = { "book.epub", "image.jpg", "notes.doc", "data.csv" },
    })
    setSidecar("/test/books/book.epub", { title = "Book" }, nil, nil)
    local result = LibraryScanner.scan(DEFAULT_SETTINGS, nil)
    -- jpg and csv not in mock_supported_extensions, doc is not either
    TestRunner:assertEqual(result.stats.total, 1, "Should only find epub")
end)

TestRunner:test("excludes current book", function()
    resetMocks()
    setFilesystem({
        ["/test/books"] = { "current.epub", "other.epub" },
    })
    setSidecar("/test/books/current.epub", { title = "Current" }, nil, 0.5)
    setSidecar("/test/books/other.epub", { title = "Other" }, nil, nil)
    local result = LibraryScanner.scan(DEFAULT_SETTINGS, "/test/books/current.epub")
    TestRunner:assertEqual(result.stats.total, 1, "Should exclude current book")
    TestRunner:assertEqual(result.books[1].title, "Other")
end)

TestRunner:test("deduplicates across overlapping folder configs", function()
    resetMocks()
    setFilesystem({
        ["/test/books"] = { "book.epub", "sub" },
        ["/test/books/sub"] = { "nested.epub" },
    })
    setSidecar("/test/books/book.epub", { title = "Book" }, nil, nil)
    setSidecar("/test/books/sub/nested.epub", { title = "Nested" }, nil, nil)
    -- Scan both /test/books (which recurses into /sub) AND /test/books/sub
    local result = LibraryScanner.scan({ library_scan_folders = { "/test/books", "/test/books/sub" } }, nil)
    TestRunner:assertEqual(result.stats.total, 2, "Should deduplicate")
end)

TestRunner:test("no configured folders returns empty result (no fallback)", function()
    resetMocks()
    setFilesystem({
        ["/test/books"] = { "book.epub" },
    })
    setSidecar("/test/books/book.epub", { title = "Should Not Appear" }, nil, nil)
    -- Empty settings — scanner must NOT fall back to home dir or any default
    local result = LibraryScanner.scan({}, nil)
    TestRunner:assertEqual(result.stats.total, 0, "No folders = no scan")
    TestRunner:assertEqual(#result.books, 0)
    -- Also test nil folders explicitly
    local result2 = LibraryScanner.scan({ library_scan_folders = {} }, nil)
    TestRunner:assertEqual(result2.stats.total, 0, "Empty folders array = no scan")
end)

TestRunner:test("empty folder returns empty result", function()
    resetMocks()
    setFilesystem({
        ["/test/books"] = {},
    })
    local result = LibraryScanner.scan(DEFAULT_SETTINGS, nil)
    TestRunner:assertEqual(result.stats.total, 0, "Empty folder should have 0 books")
    TestRunner:assertEqual(#result.books, 0)
end)

-- ----- ReadHistory Enrichment -----

print("\nReadHistory Enrichment:")

TestRunner:test("enriches with last_read from ReadHistory", function()
    resetMocks()
    setFilesystem({ ["/test/books"] = { "book.epub" } })
    setSidecar("/test/books/book.epub", { title = "Book" }, { status = "complete" }, 1.0)
    addHistory("/test/books/book.epub", 1710000000)
    local result = LibraryScanner.scan(DEFAULT_SETTINGS, nil)
    TestRunner:assertEqual(result.books[1].last_read, 1710000000, "Should have last_read")
end)

TestRunner:test("nil last_read for books not in history", function()
    resetMocks()
    setFilesystem({ ["/test/books"] = { "book.epub" } })
    -- No history entry
    local result = LibraryScanner.scan(DEFAULT_SETTINGS, nil)
    TestRunner:assertNil(result.books[1].last_read, "Should be nil without history")
end)

TestRunner:test("sorts reading group by recency", function()
    resetMocks()
    setFilesystem({
        ["/test/books"] = { "old.epub", "new.epub", "mid.epub" },
    })
    setSidecar("/test/books/old.epub", { title = "Old" }, nil, 0.3)
    setSidecar("/test/books/new.epub", { title = "New" }, nil, 0.5)
    setSidecar("/test/books/mid.epub", { title = "Mid" }, nil, 0.1)
    addHistory("/test/books/old.epub", 1000)
    addHistory("/test/books/new.epub", 3000)
    addHistory("/test/books/mid.epub", 2000)
    local result = LibraryScanner.scan(DEFAULT_SETTINGS, nil)
    TestRunner:assertEqual(result.by_status.reading[1].title, "New", "Most recent first")
    TestRunner:assertEqual(result.by_status.reading[2].title, "Mid", "Second most recent")
    TestRunner:assertEqual(result.by_status.reading[3].title, "Old", "Least recent last")
end)

-- ----- by_folder Index -----

print("\nFolder Indexing:")

TestRunner:test("indexes books by folder", function()
    resetMocks()
    setFilesystem({
        ["/test/books"] = { "scifi", "fiction" },
        ["/test/books/scifi"] = { "dune.epub" },
        ["/test/books/fiction"] = { "gatsby.epub", "moby.epub" },
    })
    setSidecar("/test/books/scifi/dune.epub", { title = "Dune" }, nil, nil)
    setSidecar("/test/books/fiction/gatsby.epub", { title = "Gatsby" }, nil, nil)
    setSidecar("/test/books/fiction/moby.epub", { title = "Moby Dick" }, nil, nil)
    local result = LibraryScanner.scan(DEFAULT_SETTINGS, nil)
    TestRunner:assertEqual(#result.by_folder["/test/books/scifi"], 1, "SciFi folder should have 1")
    TestRunner:assertEqual(#result.by_folder["/test/books/fiction"], 2, "Fiction folder should have 2")
end)

-- ----- Formatter -----

print("\nFormatter:")

TestRunner:test("format returns empty string for empty library", function()
    resetMocks()
    setFilesystem({ ["/test/books"] = {} })
    local result = LibraryScanner.scan(DEFAULT_SETTINGS, nil)
    local text = LibraryScanner.format(result)
    TestRunner:assertEqual(text, "", "Empty library should produce empty string")
end)

TestRunner:test("format includes status groups by default", function()
    resetMocks()
    setFilesystem({
        ["/test/books"] = { "reading.epub", "done.epub", "new.epub" },
    })
    setSidecar("/test/books/reading.epub", { title = "Reading Book", authors = "Author A" }, nil, 0.5)
    setSidecar("/test/books/done.epub", { title = "Done Book", authors = "Author B" }, { status = "complete" }, 1.0)
    -- new.epub has no sidecar → unread
    local result = LibraryScanner.scan(DEFAULT_SETTINGS, nil)
    local text = LibraryScanner.format(result)
    TestRunner:assertContains(text, "Currently reading (1):", "Should have reading header")
    TestRunner:assertContains(text, "Finished (1):", "Should have finished header")
    TestRunner:assertContains(text, "Unread (1):", "Should have unread header")
    TestRunner:assertContains(text, '"Reading Book"', "Should include reading book title")
    TestRunner:assertContains(text, '"Done Book"', "Should include done book title")
end)

TestRunner:test("format basic depth: title and author only", function()
    resetMocks()
    setFilesystem({ ["/test/books"] = { "book.epub" } })
    setSidecar("/test/books/book.epub",
        { title = "Test", authors = "Author", series = "MySeries" },
        nil, 0.5
    )
    local result = LibraryScanner.scan(DEFAULT_SETTINGS, nil)
    local text = LibraryScanner.format(result, { depth = "basic" })
    TestRunner:assertContains(text, '"Test"', "Should have title")
    TestRunner:assertContains(text, "by Author", "Should have author")
    TestRunner:assertNotContains(text, "MySeries", "Basic depth should not include series")
    TestRunner:assertNotContains(text, "50%", "Basic depth should not include progress")
end)

TestRunner:test("format standard depth: includes series and progress", function()
    resetMocks()
    setFilesystem({ ["/test/books"] = { "book.epub" } })
    setSidecar("/test/books/book.epub",
        { title = "Test", authors = "Author", series = "MySeries" },
        nil, 0.5
    )
    local result = LibraryScanner.scan(DEFAULT_SETTINGS, nil)
    local text = LibraryScanner.format(result, { depth = "standard" })
    TestRunner:assertContains(text, "MySeries", "Standard depth should include series")
    TestRunner:assertContains(text, "50%", "Standard depth should include progress")
end)

TestRunner:test("format full depth: includes language", function()
    resetMocks()
    setFilesystem({ ["/test/books"] = { "book.epub" } })
    setSidecar("/test/books/book.epub",
        { title = "Test", authors = "Author", language = "ar" },
        nil, 0.5
    )
    local result = LibraryScanner.scan(DEFAULT_SETTINGS, nil)
    local text = LibraryScanner.format(result, { depth = "full" })
    TestRunner:assertContains(text, "[ar]", "Full depth should include language")
end)

TestRunner:test("format status filter: only specified statuses", function()
    resetMocks()
    setFilesystem({
        ["/test/books"] = { "reading.epub", "done.epub", "new.epub" },
    })
    setSidecar("/test/books/reading.epub", { title = "Reading" }, nil, 0.5)
    setSidecar("/test/books/done.epub", { title = "Done" }, { status = "complete" }, 1.0)
    local result = LibraryScanner.scan(DEFAULT_SETTINGS, nil)
    local text = LibraryScanner.format(result, { statuses = { "reading" } })
    TestRunner:assertContains(text, '"Reading"', "Should include reading")
    TestRunner:assertNotContains(text, '"Done"', "Should exclude finished")
    TestRunner:assertNotContains(text, "Unread", "Should exclude unread")
end)

TestRunner:test("format budget truncates unread list", function()
    resetMocks()
    local files = {}
    local fs = {}
    for i = 1, 50 do
        local name = string.format("book_%02d.epub", i)
        table.insert(files, name)
        setSidecar("/test/books/" .. name, { title = "Book " .. i }, nil, nil) -- all unread
    end
    fs["/test/books"] = files
    setFilesystem(fs)
    local result = LibraryScanner.scan(DEFAULT_SETTINGS, nil)
    -- Use a very small budget
    local text = LibraryScanner.format(result, { budget = 500 })
    TestRunner:assertContains(text, "... and", "Should have truncation notice")
    TestRunner:assertContains(text, "more", "Should indicate remaining count")
end)

TestRunner:test("format group_by folder", function()
    resetMocks()
    setFilesystem({
        ["/test/books"] = { "scifi", "fiction" },
        ["/test/books/scifi"] = { "dune.epub" },
        ["/test/books/fiction"] = { "gatsby.epub" },
    })
    setSidecar("/test/books/scifi/dune.epub", { title = "Dune" }, nil, nil)
    setSidecar("/test/books/fiction/gatsby.epub", { title = "Gatsby" }, nil, nil)
    local result = LibraryScanner.scan(DEFAULT_SETTINGS, nil)
    local text = LibraryScanner.format(result, { group_by = "folder" })
    TestRunner:assertContains(text, "fiction", "Should have fiction folder header")
    TestRunner:assertContains(text, "scifi", "Should have scifi folder header")
end)

TestRunner:test("format progress only shown for reading/abandoned", function()
    resetMocks()
    setFilesystem({
        ["/test/books"] = { "reading.epub", "done.epub" },
    })
    setSidecar("/test/books/reading.epub", { title = "Reading" }, nil, 0.45)
    setSidecar("/test/books/done.epub", { title = "Done" }, { status = "complete" }, 1.0)
    local result = LibraryScanner.scan(DEFAULT_SETTINGS, nil)
    local text = LibraryScanner.format(result)
    TestRunner:assertContains(text, "45%", "Reading should show progress")
    TestRunner:assertNotContains(text, "100%", "Complete should not show progress")
end)

-- ----- Stats -----

print("\nStats:")

TestRunner:test("stats counts are accurate", function()
    resetMocks()
    setFilesystem({
        ["/test/books"] = { "r1.epub", "r2.epub", "c1.epub", "a1.epub", "u1.epub", "u2.epub", "u3.epub" },
    })
    setSidecar("/test/books/r1.epub", { title = "R1" }, nil, 0.3)
    setSidecar("/test/books/r2.epub", { title = "R2" }, nil, 0.6)
    setSidecar("/test/books/c1.epub", { title = "C1" }, { status = "complete" }, 1.0)
    setSidecar("/test/books/a1.epub", { title = "A1" }, { status = "abandoned" }, 0.1)
    -- u1, u2, u3 have no sidecars → unread
    local result = LibraryScanner.scan(DEFAULT_SETTINGS, nil)
    TestRunner:assertEqual(result.stats.total, 7, "Total")
    TestRunner:assertEqual(result.stats.reading, 2, "Reading")
    TestRunner:assertEqual(result.stats.complete, 1, "Complete")
    TestRunner:assertEqual(result.stats.abandoned, 1, "Abandoned")
    TestRunner:assertEqual(result.stats.unread, 3, "Unread")
end)

-- ----- Summary -----

print()
local success = TestRunner:summary()
os.exit(success and 0 or 1)
