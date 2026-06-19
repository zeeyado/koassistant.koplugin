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

local function makeToolsWithPages(pages, current_page, toc, scope)
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
    return BookTools:new(ui, { enable_book_text_extraction = true, reading_scope = scope })
end

local DEMO_PAGES = {
    "Alice saw the white rabbit. Daisy was mentioned in a letter.",
    "The garden path curved behind the old house.",
    "Daisey carried a lantern into the cellar.",
    "This spoiler is beyond the current page.",
}

local function makeTools()
    return makeToolsWithPages(DEMO_PAGES, 3)
end

-- Same book/position but with full ("whole document") reading scope (spoiler-free off).
local function makeFullTools()
    return makeToolsWithPages(DEMO_PAGES, 3, nil, "full")
end

print("")
print(string.rep("=", 50))
print("  Unit Tests: Book Tools")
print(string.rep("=", 50))

TestRunner:test("searches only up to the current page", function()
    local tools = makeTools()
    local result = tools:searchBook({ query = "spoiler" })
    TestRunner:assertTrue(result.ok, "search ok")
    TestRunner:assertEqual(result.queries[1].total_hits, 0, "unread total hits")
end)

TestRunner:test("finds exact matches case-insensitively", function()
    local tools = makeTools()
    local result = tools:searchBook({ query = "daisy" })
    TestRunner:assertTrue(result.ok, "search ok")
    TestRunner:assertEqual(result.queries[1].results[1].page, 1, "exact page")
    TestRunner:assertEqual(result.queries[1].results[1].hit_id, "q1:p1:2", "namespaced hit id")
end)

TestRunner:test("finds fuzzy matches", function()
    local tools = makeTools()
    local result = tools:searchBook({ query = "lantrn" })
    TestRunner:assertTrue(result.ok, "search ok")
    TestRunner:assertEqual(result.queries[1].results[1].page, 3, "fuzzy page")
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
    TestRunner:assertEqual(result.query_count, 1, "query count")
    local block = result.queries[1]
    TestRunner:assertEqual(block.total_hits, 15, "block total hits")
    TestRunner:assertEqual(#block.results, 15, "returned hits")
    TestRunner:assertEqual(block.matching_pages, 15, "matching pages")
    TestRunner:assertEqual(block.page_summary[15].page, 15, "last summary page")
    TestRunner:assertEqual(block.results[1].snippet, "Daisy appears on page 1.", "compact snippet")
end)

TestRunner:test("search snippets are concordance-sized", function()
    local tools = makeToolsWithPages({
        "One two three four five Daisy six seven eight nine ten eleven.",
    }, 1, {})
    local result = tools:searchBook({ query = "Daisy" })
    TestRunner:assertTrue(result.ok, "search ok")
    TestRunner:assertEqual(result.queries[1].results[1].snippet, "One two three four five Daisy six seven eight nine ten...", "concordance snippet")
end)

TestRunner:test("multi-query search returns one block per term", function()
    local tools = makeTools()
    local result = tools:searchBook({ queries = { "daisy", "lantern" } })
    TestRunner:assertTrue(result.ok, "search ok")
    TestRunner:assertEqual(result.query_count, 2, "query count")
    TestRunner:assertEqual(#result.queries, 2, "blocks count")
    TestRunner:assertEqual(result.queries[1].query, "daisy", "first query")
    TestRunner:assertEqual(result.queries[2].query, "lantern", "second query")
    TestRunner:assertEqual(result.queries[1].results[1].hit_id, "q1:p1:2", "first block hit_id")
    TestRunner:assertEqual(result.queries[2].results[1].hit_id, "q2:p3:1", "second block hit_id")
    TestRunner:assertTrue(result.total_hits >= 2, "aggregate total hits")
end)

TestRunner:test("read_around accepts namespaced multi-query hit_ids", function()
    local tools = makeTools()
    local search = tools:searchBook({ queries = { "daisy", "lantern" } })
    local id1 = search.queries[1].results[1].hit_id
    local id2 = search.queries[2].results[1].hit_id
    local result = tools:readAround({ hit_ids = { id1, id2 }, before_pages = 0, after_pages = 0 })
    TestRunner:assertTrue(result.ok, "read ok")
    TestRunner:assertEqual(result.target_count, 2, "target count")
    TestRunner:assertEqual(result.results[1].page, 1, "first page")
    TestRunner:assertEqual(result.results[2].page, 3, "second page")
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

-- Reading scope: "full" lets the tools read the whole document (research / non-fiction)
TestRunner:test("full reading scope searches beyond the current page", function()
    local tools = makeFullTools()
    local result = tools:searchBook({ query = "spoiler" })
    TestRunner:assertTrue(result.ok, "search ok")
    TestRunner:assertEqual(result.queries[1].results[1].page, 4, "reads ahead to page 4")
end)

TestRunner:test("full reading scope read_around reaches a later page", function()
    local tools = makeFullTools()
    local result = tools:readAround({ page = 4, before_pages = 0, after_pages = 0 })
    TestRunner:assertTrue(result.ok, "read ok")
    TestRunner:assertEqual(result.range.end_page, 4, "reads page 4")
    TestRunner:assertTrue(result.text:find("spoiler", 1, true) ~= nil, "page-4 text returned")
end)

TestRunner:test("full reading scope toc includes later chapters", function()
    local tools = makeFullTools()
    local result = tools:toc()
    TestRunner:assertTrue(result.ok, "toc ok")
    TestRunner:assertEqual(result.entry_count, 3, "includes the unread chapter")
    TestRunner:assertEqual(result.entries[3].title, "Unread", "last chapter title")
end)

TestRunner:test("getScope reports the reading scope and ceiling", function()
    TestRunner:assertEqual(makeTools():getScope().reading_scope, "current", "current scope")
    TestRunner:assertEqual(makeTools():getScope().end_page, 3, "current ceiling = current page")
    TestRunner:assertEqual(makeFullTools():getScope().reading_scope, "full", "full scope")
    TestRunner:assertEqual(makeFullTools():getScope().end_page, 4, "full ceiling = last page")
end)

return TestRunner:summary()
