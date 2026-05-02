-- Unit tests for koassistant_book_tools.lua

local function setupPaths()
    local info = debug.getinfo(1, "S")
    local script_path = info.source:match("@?(.*)")
    local unit_dir = script_path:match("(.+)/[^/]+$") or "."
    local tests_dir = unit_dir:match("(.+)/[^/]+$") or "."
    local plugin_dir = tests_dir:match("(.+)/[^/]+$") or "."

    package.path = table.concat({
        plugin_dir .. "/?.lua",
        tests_dir .. "/?.lua",
        tests_dir .. "/lib/?.lua",
        package.path,
    }, ";")
end

setupPaths()
require("mock_koreader")

local BookTools = require("koassistant_book_tools")

local TestRunner = {
    passed = 0,
    failed = 0,
}

function TestRunner:test(name, fn)
    local ok, err = pcall(fn)
    if ok then
        self.passed = self.passed + 1
        print(string.format("    PASS %s", name))
    else
        self.failed = self.failed + 1
        print(string.format("    FAIL %s", name))
        print(string.format("      Error: %s", tostring(err)))
    end
end

function TestRunner:assertEqual(actual, expected, msg)
    if actual ~= expected then
        error(string.format("%s: expected %q, got %q", msg or "Assertion failed", tostring(expected), tostring(actual)))
    end
end

function TestRunner:assertTrue(value, msg)
    if not value then
        error(string.format("%s: expected true", msg or "Assertion failed"))
    end
end

function TestRunner:summary()
    print("")
    local total = self.passed + self.failed
    if self.failed == 0 then
        print(string.format("  All %d book tool tests passed!", total))
    else
        print(string.format("  %d passed, %d failed (of %d total)", self.passed, self.failed, total))
    end
    return self.failed == 0
end

local function makeTools()
    local pages = {
        "Alice saw the white rabbit. Daisy was mentioned in a letter.",
        "The garden path curved behind the old house.",
        "Daisey carried a lantern into the cellar.",
        "This spoiler is beyond the current page.",
    }
    local ui = {
        document = {
            info = {
                has_pages = true,
                number_of_pages = 4,
            },
            getPageText = function(_self, page)
                return pages[page] or ""
            end,
        },
        view = {
            state = {
                page = 3,
            },
        },
        toc = {
            toc = {
                { title = "Chapter 1", page = 1, depth = 1 },
                { title = "Chapter 2", page = 3, depth = 1 },
                { title = "Unread", page = 4, depth = 1 },
            },
        },
    }
    return BookTools:new(ui, { enable_book_text_extraction = true })
end

print("")
print(string.rep("=", 50))
print("  Unit Tests: Book Tools")
print(string.rep("=", 50))

TestRunner:test("searches only up to the current page", function()
    local tools = makeTools()
    local result = tools:searchBook({ query = "spoiler" })
    TestRunner:assertTrue(result.ok, "search ok")
    TestRunner:assertEqual(result.result_count, 0, "unread result count")
end)

TestRunner:test("finds exact matches case-insensitively", function()
    local tools = makeTools()
    local result = tools:searchBook({ query = "daisy" })
    TestRunner:assertTrue(result.ok, "search ok")
    TestRunner:assertEqual(result.results[1].page, 1, "exact page")
end)

TestRunner:test("finds fuzzy matches", function()
    local tools = makeTools()
    local result = tools:searchBook({ query = "lantrn" })
    TestRunner:assertTrue(result.ok, "search ok")
    TestRunner:assertEqual(result.results[1].page, 3, "fuzzy page")
end)

TestRunner:test("reads around a page with current-page clamp", function()
    local tools = makeTools()
    local result = tools:readAround({ page = 2, before_pages = 1, after_pages = 3 })
    TestRunner:assertTrue(result.ok, "read ok")
    TestRunner:assertEqual(result.range.start_page, 1, "start page")
    TestRunner:assertEqual(result.range.end_page, 3, "end page")
end)

TestRunner:test("returns toc entries and excludes unread chapters", function()
    local tools = makeTools()
    local result = tools:toc({ max_snippet_chars = 80 })
    TestRunner:assertTrue(result.ok, "toc ok")
    TestRunner:assertEqual(result.entry_count, 2, "entry count")
    TestRunner:assertEqual(result.entries[2].title, "Chapter 2", "second title")
end)

return TestRunner:summary()
