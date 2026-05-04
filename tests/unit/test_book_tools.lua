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

local TestRunner = require("test_runner"):new()

local function makeToolsWithPages(pages, current_page, toc)
    local ui = {
        document = {
            info = {
                has_pages = true,
                number_of_pages = #pages,
            },
            getPageText = function(_self, page)
                return pages[page] or ""
            end,
        },
        view = {
            state = {
                page = current_page or #pages,
            },
        },
        toc = {
            toc = toc or {
                { title = "Chapter 1", page = 1, depth = 1 },
                { title = "Chapter 2", page = 3, depth = 1 },
                { title = "Unread", page = 4, depth = 1 },
            },
        },
    }
    return BookTools:new(ui, { enable_book_text_extraction = true })
end

local function makeTools()
    return makeToolsWithPages({
        "Alice saw the white rabbit. Daisy was mentioned in a letter.",
        "The garden path curved behind the old house.",
        "Daisey carried a lantern into the cellar.",
        "This spoiler is beyond the current page.",
    }, 3)
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

TestRunner:test("returns all search hits compactly without result cap", function()
    local pages = {}
    for page = 1, 15 do
        pages[page] = "Daisy appears on page " .. page .. "."
    end
    local tools = makeToolsWithPages(pages, 15, {})
    local result = tools:searchBook({ query = "Daisy" })
    TestRunner:assertTrue(result.ok, "search ok")
    TestRunner:assertEqual(result.total_hits, 15, "total hits")
    TestRunner:assertEqual(result.result_count, 15, "result count")
    TestRunner:assertEqual(#result.results, 15, "returned hits")
    TestRunner:assertEqual(result.matching_pages, 15, "matching pages")
    TestRunner:assertEqual(result.page_summary[15].page, 15, "last summary page")
    TestRunner:assertEqual(result.results[1].snippet, "Daisy appears on page 1.", "compact snippet")
end)

TestRunner:test("search snippets are concordance-sized", function()
    local tools = makeToolsWithPages({
        "One two three four five Daisy six seven eight nine ten eleven.",
    }, 1, {})
    local result = tools:searchBook({ query = "Daisy" })
    TestRunner:assertTrue(result.ok, "search ok")
    TestRunner:assertEqual(result.results[1].snippet, "One two three four five Daisy six seven eight nine ten...", "concordance snippet")
end)

TestRunner:test("reads around a page with current-page clamp", function()
    local tools = makeTools()
    local result = tools:readAround({ page = 2, before_pages = 1, after_pages = 3 })
    TestRunner:assertTrue(result.ok, "read ok")
    TestRunner:assertEqual(result.range.start_page, 1, "start page")
    TestRunner:assertEqual(result.range.end_page, 3, "end page")
end)

TestRunner:test("reads around multiple targets in one call", function()
    local tools = makeTools()
    local result = tools:readAround({ pages = { 1, 3 }, before_pages = 0, after_pages = 0 })
    TestRunner:assertTrue(result.ok, "read ok")
    TestRunner:assertEqual(result.target_count, 2, "target count")
    TestRunner:assertEqual(result.results[1].page, 1, "first page")
    TestRunner:assertEqual(result.results[2].page, 3, "second page")
end)

TestRunner:test("returns toc entries and excludes unread chapters", function()
    local tools = makeTools()
    local result = tools:toc({ max_snippet_chars = 80 })
    TestRunner:assertTrue(result.ok, "toc ok")
    TestRunner:assertEqual(result.entry_count, 2, "entry count")
    TestRunner:assertEqual(result.entries[2].title, "Chapter 2", "second title")
end)

TestRunner:test("toc omits snippets by default", function()
    local tools = makeTools()
    local result = tools:toc()
    TestRunner:assertTrue(result.ok, "toc ok")
    TestRunner:assertEqual(result.entries[1].snippet, "", "default snippet")
end)

return TestRunner:summary()
