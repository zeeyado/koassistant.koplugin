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

TestRunner:test("a misspelled word finds nothing (no typo tolerance; the model retries a spelling)", function()
    local tools = makeTools()
    local result = tools:searchBook({ query = "lantrn" })
    TestRunner:assertTrue(result.ok, "search ok")
    TestRunner:assertEqual(result.queries[1].total_hits, 0, "no hit for a typo")
    TestRunner:assertEqual(tools:searchBook({ query = "lantern" }).queries[1].results[1].page, 3, "the right spelling hits")
end)

local function hasNote(notes, needle)
    for _idx, note in ipairs(notes or {}) do
        if note:find(needle, 1, true) then return true end
    end
    return false
end

TestRunner:test("search caps the hits it shows at 12, keeps exact totals and says so", function()
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
    TestRunner:assertEqual(block.total_hits, 15, "block total hits exact")
    TestRunner:assertEqual(#block.results, 12, "12 hits shown by default")
    TestRunner:assertEqual(block.shown_hits, 12, "shown_hits")
    TestRunner:assertEqual(block.matching_pages, 15, "matching pages")
    TestRunner:assertEqual(block.page_summary[15].page, 15, "page_summary keeps every page")
    TestRunner:assertEqual(block.results[1].snippet, "Daisy appears on page 1.", "compact snippet")
    TestRunner:assertTrue(hasNote(block.notes, "Showing 12 of 15 hits"), "cap stated in a note")
    TestRunner:assertTrue(result.notes == nil, "full scope at the last page: no range note")
    local raised = tools:searchBook({ query = "Daisy", max_hits = 20 })
    TestRunner:assertEqual(#raised.queries[1].results, 15, "max_hits raises the cap")
    TestRunner:assertTrue(raised.queries[1].notes == nil, "nothing left out: no note")
    local ceiling = tools:searchBook({ query = "Daisy", max_hits = 400 })
    TestRunner:assertEqual(#ceiling.queries[1].results, 15, "max_hits above the ceiling still works")
end)

TestRunner:test("search spreads shown hits across pages instead of the first pages only", function()
    local pages = {}
    for page = 1, 8 do
        pages[page] = "Daisy one. Daisy two. Daisy three."
    end
    local tools = makeToolsWithPages(pages, 8, {})
    local block = tools:searchBook({ query = "Daisy" }).queries[1]
    TestRunner:assertEqual(block.total_hits, 24, "24 hits in total")
    TestRunner:assertEqual(#block.results, 12, "12 shown")
    local pages_seen = {}
    for _idx, hit in ipairs(block.results) do pages_seen[hit.page] = (pages_seen[hit.page] or 0) + 1 end
    local distinct = 0
    for _page, count in pairs(pages_seen) do
        distinct = distinct + 1
        TestRunner:assertTrue(count <= 2, "at most 2 hits per page")
    end
    TestRunner:assertEqual(distinct, 6, "hits come from 6 different pages")
end)

TestRunner:test("non-Latin scripts get word tokens: CJK by substring, Arabic by words", function()
    local tools = makeToolsWithPages({ "東京の空は青く、遠くに山が見えた。今日は晴れ。", "second page" }, 2, {})
    local result = tools:searchBook({ query = "東京" })
    TestRunner:assertTrue(result.ok, "search ok")
    local block = result.queries[1]
    TestRunner:assertEqual(block.total_hits, 1, "CJK hit found")
    TestRunner:assertEqual(block.results[1].match_type, "phrase", "phrase match")
    TestRunner:assertTrue(block.results[1].snippet:find("東京", 1, true) ~= nil, "snippet contains the match")
    TestRunner:assertEqual(hasNote(block.notes, "literal substring"), false, "a CJK clause is a token, not a literal fallback")
    TestRunner:assertEqual(#tools:getSentences(1), 2, "the CJK full stop ends a sentence")
    -- Two CJK words in one query: both must be in the sentence (tokens rung).
    local two = tools:searchBook({ query = "山 東京" }).queries[1]
    TestRunner:assertEqual(two.total_hits, 1, "both substrings in the first sentence")
    TestRunner:assertEqual(two.results[1].match_type, "tokens", "tokens rung across CJK words")
    TestRunner:assertEqual(tools:searchBook({ query = "晴れ 東京" }).queries[1].total_hits, 0, "different sentences do not combine")
    -- Arabic: space-separated words with Arabic punctuation on their edges, and the
    -- Arabic question mark ends a sentence. A three-word query with two of its words
    -- present now takes the partial rung instead of a literal miss.
    local arabic = makeToolsWithPages({ "هل تعرف حيفا؟ شوارع حيفا، ورائحة البحر.", "second page" }, 2, {})
    TestRunner:assertEqual(#arabic:getSentences(1), 2, "Arabic question mark splits")
    local hit = arabic:searchBook({ query = "شوارع حيفا" }).queries[1]
    TestRunner:assertEqual(hit.total_hits, 1, "two-word Arabic phrase")
    TestRunner:assertEqual(hit.results[1].match_type, "phrase", "phrase rung")
    local partial = arabic:searchBook({ query = "رائحة حيفا المدينة" }).queries[1]
    TestRunner:assertEqual(partial.total_hits, 1, "two of three Arabic words")
    TestRunner:assertEqual(partial.results[1].match_type, "partial", "partial rung for Arabic")
    TestRunner:assertEqual(partial.results[1].missing[1], "المدينة", "missing Arabic word listed")
    TestRunner:assertEqual(arabic:searchBook({ query = "حيفآ" }).queries[1].total_hits, 0, "no byte-level fuzz on non-ASCII words")
    -- A punctuation-only query has no tokens and falls back to the literal substring.
    local literal = arabic:searchBook({ query = "،" }).queries[1]
    TestRunner:assertEqual(literal.total_hits, 1, "literal punctuation hit")
    TestRunner:assertTrue(hasNote(literal.notes, "literal substring"), "literal fallback stated")
end)

TestRunner:test("tokens keep interior punctuation, drop edge punctuation and split on no-break spaces", function()
    local tools = makeToolsWithPages({ "\"Don't,\" she said\194\160quietly (self-knowledge) — 1,000 times…" }, 1, {})
    local sentences = tools:getSentences(1)
    TestRunner:assertEqual(#sentences, 1, "one sentence")
    local hits = function(q) return tools:searchBook({ query = q }).queries[1].total_hits end
    TestRunner:assertEqual(hits("don't"), 1, "apostrophe inside a word survives")
    TestRunner:assertEqual(hits("self-knowledge"), 1, "hyphenated word is one token")
    TestRunner:assertEqual(hits("knowledge"), 1, "and still matches by substring")
    TestRunner:assertEqual(hits("1,000"), 1, "number with a comma")
    TestRunner:assertEqual(hits("said quietly"), 1, "no-break space reads as a space")
    TestRunner:assertEqual(hits("times"), 1, "ellipsis stripped from the edge")
end)

TestRunner:test("search under spoiler protection states the readable range", function()
    local tools = makeTools()  -- current page 3 of 4, scope current
    local result = tools:searchBook({ query = "spoiler" })
    TestRunner:assertEqual(result.queries[1].total_hits, 0, "no hit within range")
    TestRunner:assertTrue(hasNote(result.notes, "pages 1-3 of 4 only"), "range note names the ceiling")
    TestRunner:assertTrue(hasNote(result.notes, "not evidence"), "range note says zero hits are inconclusive")
    local full = makeFullTools():searchBook({ query = "spoiler" })
    TestRunner:assertTrue(full.notes == nil, "full scope carries no range note")
end)

TestRunner:test("hidden flows are honored and reported on search and toc", function()
    local tools = makeToolsWithPages(DEMO_PAGES, 4, nil, "full")
    local document = tools.ui.document
    document.hasHiddenFlows = function() return true end
    document.getPageFlow = function(_self, page) return page >= 3 and 1 or 0 end
    local search = tools:searchBook({ query = "lantern" })
    TestRunner:assertEqual(search.queries[1].total_hits, 0, "hidden page not searched")
    TestRunner:assertTrue(hasNote(search.notes, "2 of 4 pages are in sections the reader has hidden"), "hidden pages counted")
    local toc = tools:toc()
    TestRunner:assertEqual(toc.entry_count, 1, "only the visible entry listed")
    TestRunner:assertTrue(hasNote(toc.notes, "2 entries are in sections the reader has hidden"), "hidden entries counted")
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

-- Strict UTF-8 validator (the same rules KOReader's util.fixUtf8 applies).
local function isValidUtf8(str)
    local pos, len = 1, #str
    while pos <= len do
        if str:find("^[%z\1-\127]", pos) then pos = pos + 1
        elseif str:find("^[\194-\223][\128-\191]", pos) then pos = pos + 2
        elseif str:find("^\224[\160-\191][\128-\191]", pos)
            or str:find("^[\225-\236][\128-\191][\128-\191]", pos)
            or str:find("^\237[\128-\159][\128-\191]", pos)
            or str:find("^[\238-\239][\128-\191][\128-\191]", pos) then pos = pos + 3
        elseif str:find("^\240[\144-\191][\128-\191][\128-\191]", pos)
            or str:find("^[\241-\243][\128-\191][\128-\191][\128-\191]", pos)
            or str:find("^\244[\128-\143][\128-\191][\128-\191]", pos) then pos = pos + 4
        else
            return false
        end
    end
    return true
end

-- Multi-byte text: every cut a tool result passes through must land on a character
-- boundary, or the JSON request ships stray bytes and the provider rejects it.
local CJK_SENTENCE = "東京の空は青く、遠くに山が見えた。"  -- 3-byte chars, no spaces

TestRunner:test("read_around: a multi-byte page cut at the read budget stays valid UTF-8", function()
    local big = string.rep(CJK_SENTENCE, 400)  -- ~20K bytes, over MAX_READ_CHARS (8000)
    local tools = makeToolsWithPages({ big, "second page" }, 2)
    local result = tools:readAround({ page = 1, before_pages = 0, after_pages = 0 })
    TestRunner:assertTrue(result.ok, "read ok")
    TestRunner:assertTrue(#result.text <= 8000, "read budget honored in bytes")
    TestRunner:assertTrue(isValidUtf8(result.text), "no partial character at either end")
    TestRunner:assertTrue(result.text:sub(-3) == "...", "excerpt marker kept")
end)

TestRunner:test("toc: a multi-byte chapter snippet cut at max_snippet_chars stays valid UTF-8", function()
    local tools = makeToolsWithPages({ string.rep(CJK_SENTENCE, 20), "x" }, 2,
        { { title = "第一章", page = 1, depth = 1 }, { title = "第二章", page = 2, depth = 1 } })
    local result = tools:toc({ max_snippet_chars = 100 })
    TestRunner:assertTrue(result.ok, "toc ok")
    local snippet = result.entries[1].snippet
    TestRunner:assertTrue(#snippet <= 100, "snippet budget honored")
    TestRunner:assertTrue(isValidUtf8(snippet), "snippet has no partial character")
end)

TestRunner:test("search_book: a multi-byte sentence chunked past MAX_SENTENCE_CHUNK stays valid UTF-8", function()
    -- One 'sentence' with no terminator and no spaces, longer than the 700-byte chunk.
    local run = string.rep("東京", 400) .. " tokyo"
    local tools = makeToolsWithPages({ run, "y" }, 2)
    local result = tools:searchBook({ query = "tokyo" })
    TestRunner:assertTrue(result.ok, "search ok")
    local block = result.queries[1]
    TestRunner:assertTrue((block.total_hits or 0) >= 1, "ASCII token still found")
    for _idx, hit in ipairs(block.results or {}) do
        TestRunner:assertTrue(isValidUtf8(hit.snippet or ""), "snippet " .. _idx .. " valid UTF-8")
    end
end)

local BIG_TOC = {
    { title = "Volume 1", page = 1, depth = 1 },
    { title = "Part I", page = 1, depth = 2 },
    { title = "Archetypes of the Collective Unconscious", page = 1, depth = 3 },
    { title = "Concerning Rebirth", page = 2, depth = 3 },
    { title = "Volume 2", page = 3, depth = 1 },
    { title = "Chapter 1", page = 3, depth = 2 },
    { title = "Volume 3", page = 4, depth = 1 },
    { title = "Chapter 1", page = 4, depth = 2 },
}

TestRunner:test("toc: exact totals, filters and parent paths", function()
    local tools = makeToolsWithPages(DEMO_PAGES, 4, BIG_TOC, "full")
    local all = tools:toc()
    TestRunner:assertEqual(all.entry_count, 8, "all entries")
    TestRunner:assertEqual(all.total_entries, 8, "total_entries exact")
    TestRunner:assertEqual(all.truncated, false, "not truncated")
    TestRunner:assertEqual(all.entries[4].path, "Volume 1 > Part I", "parent path")
    TestRunner:assertEqual(all.entries[1].path, nil, "top level has no path")
    local top = tools:toc({ max_depth = 1 })
    TestRunner:assertEqual(top.entry_count, 3, "max_depth=1 lists the volumes")
    TestRunner:assertEqual(top.entries[3].title, "Volume 3", "last volume")
    local rebirth = tools:toc({ title_contains = "rebirth" })
    TestRunner:assertEqual(rebirth.entry_count, 1, "title filter, case-insensitive")
    TestRunner:assertEqual(rebirth.entries[1].path, "Volume 1 > Part I", "filtered entry keeps its path")
    local none = tools:toc({ title_contains = "zzz" })
    TestRunner:assertEqual(none.entry_count, 0, "no match")
    TestRunner:assertTrue(hasNote(none.notes, "No entries match"), "no-match note")
    local capped = tools:toc({ max_entries = 2 })
    TestRunner:assertEqual(capped.entry_count, 2, "cap honored")
    TestRunner:assertEqual(capped.total_entries, 8, "total still exact")
    TestRunner:assertEqual(capped.truncated, true, "truncated flag")
    -- Level 1 alone (3 volumes) overflows a cap of 2: the volumes are listed first, cut in
    -- document order, never chapters one and two with all their sub-entries.
    TestRunner:assertEqual(capped.depth_shown, 1, "depth fitted to the top level")
    TestRunner:assertEqual(capped.entries[2].title, "Volume 2", "second volume, not a sub-entry")
    TestRunner:assertTrue(hasNote(capped.notes, "only levels 1-1 are listed (3 entries, the first 2 shown)"), "depth fit stated")
    TestRunner:assertTrue(hasNote(capped.notes, "Showing entries 1-2 of 3"), "cap stated in a note")
    local explicit = tools:toc({ max_entries = 2, max_depth = 3 })
    TestRunner:assertEqual(explicit.depth_shown, nil, "an explicit max_depth keeps document order")
    TestRunner:assertEqual(explicit.entries[2].title, "Part I", "document order under explicit depth")
    TestRunner:assertTrue(hasNote(explicit.notes, "Showing entries 1-2 of 8"), "plain cap note")
end)

TestRunner:test("toc: an overflowing list drops its deepest levels until it fits", function()
    local tools = makeToolsWithPages(DEMO_PAGES, 4, BIG_TOC, "full")
    local fitted = tools:toc({ max_entries = 6 })  -- levels 1-2 hold exactly 6 of the 8
    TestRunner:assertEqual(fitted.entry_count, 6, "levels 1-2 listed")
    TestRunner:assertEqual(fitted.depth_shown, 2, "depth_shown")
    TestRunner:assertEqual(fitted.total_entries, 8, "total_entries counts every matching entry")
    TestRunner:assertEqual(fitted.truncated, true, "truncated")
    for _idx, entry in ipairs(fitted.entries) do
        TestRunner:assertTrue(entry.depth <= 2, "no level-3 entry: " .. entry.title)
    end
    TestRunner:assertTrue(hasNote(fitted.notes, "only levels 1-2 are listed (6 entries)"), "fit stated")
    TestRunner:assertTrue(hasNote(fitted.notes, "max_depth=3"), "note says how to go deeper")
    TestRunner:assertEqual(hasNote(fitted.notes, "Showing entries"), false, "no document-order cut once it fits")
    local fits = tools:toc({ max_entries = 8 })
    TestRunner:assertEqual(fits.depth_shown, nil, "nothing to fit when the list is under the cap")
    TestRunner:assertEqual(fits.entry_count, 8, "all entries")
end)

TestRunner:test("search: a longer query matches sentences holding most of its words", function()
    local tools = makeTools()
    -- Page 1 has "white rabbit", nothing has "garden white rabbit" together.
    local result = tools:searchBook({ query = "white rabbit garden" })
    local block = result.queries[1]
    TestRunner:assertEqual(block.total_hits, 1, "one partial hit")
    TestRunner:assertEqual(block.results[1].match_type, "partial", "partial rung")
    TestRunner:assertEqual(block.results[1].page, 1, "on the rabbit page")
    TestRunner:assertEqual(table.concat(block.results[1].missing, ","), "garden", "missing word listed")
    TestRunner:assertTrue(hasNote(block.notes, "1 of the shown hits contain only some of the query words"), "partial note")
    -- Two-word queries never partial-match: "rabbit garden" is not in one sentence.
    local two = tools:searchBook({ query = "rabbit garden" })
    TestRunner:assertEqual(two.queries[1].total_hits, 0, "no partial rung below 3 words")
    -- Full matches rank above partial ones.
    local ranked = tools:searchBook({ query = "daisy letter lantern" })
    local first = ranked.queries[1].results[1]
    TestRunner:assertEqual(first.match_type, "partial", "no sentence holds all three")
    TestRunner:assertEqual(first.page, 1, "two of three on page 1 beats one of three")
    local all = tools:searchBook({ query = "Daisey lantern cellar" })
    TestRunner:assertEqual(all.queries[1].results[1].match_type, "tokens", "all words present on page 3")
end)

-- A mock of KOReader's document search (CreDocument:findAllText): every occurrence of the
-- pattern as a plain substring, case-folded, in page order, at most max_hits hits, each
-- with `start` in the shape `xpointers` selects (a page number, the PDF shape, or a
-- string an xpointer mapper turns back into a page). Counts its walks.
local function addNativeSearch(tools, pages, xpointers)
    local document = tools.ui.document
    document.provider = "crengine"  -- the gate; extraction keeps the mock's page path
    document.walks = {}
    document.findAllText = function(_self, pattern, case_insensitive, _ctx, max_hits)
        table.insert(document.walks, pattern)
        local hits = {}
        local needle = case_insensitive and pattern:lower() or pattern
        for page, text in ipairs(pages) do
            local hay = case_insensitive and text:lower() or text
            local from = 1
            while true do
                local s, e = hay:find(needle, from, true)
                if not s then break end
                table.insert(hits, {
                    start = xpointers and string.format("/body/p[%d].%d", page, s) or page,
                    matched_text = text:sub(s, e),
                })
                if #hits >= max_hits then return hits end
                from = e + 1
            end
        end
        if #hits == 0 then return nil end  -- KoptInterface returns nil on no hits
        return hits
    end
    if xpointers then
        document.getPageFromXPointer = function(_self, xp)
            return tonumber(xp:match("p%[(%d+)%]"))
        end
    end
end

-- A generated book: 60 pages of short sentences over a small vocabulary, so that
-- substring and partial cases all occur, plus the demo pages for phrases.
local function generatedPages()
    local vocab = { "rabbit", "rabbits", "garden", "gardener", "lantern", "cellar", "daisy",
        "daisey", "letter", "house", "path", "curved", "alice", "white", "old", "carried",
        "mentioned", "concatenate", "cat", "o'clock", "self-knowledge", "1984" }
    local seed = 7
    local function rand(n)
        seed = (seed * 1103515245 + 12345) % 2147483648
        return seed % n + 1
    end
    local pages = {}
    for p = 1, 60 do
        local sentences = {}
        for s = 1, 4 do
            local words = {}
            for w = 1, 3 + rand(5) do words[w] = vocab[rand(#vocab)] end
            sentences[s] = table.concat(words, " ") .. "."
        end
        pages[p] = table.concat(sentences, " ")
    end
    for _idx, demo in ipairs(DEMO_PAGES) do table.insert(pages, demo) end
    return pages
end

local function nativeTools(pages, current_page, scope, settings, xpointers)
    local ui_settings = { enable_book_text_extraction = true, reading_scope = scope, scan_pages = 0 }
    for k, v in pairs(settings or {}) do ui_settings[k] = v end
    local tools = makeToolsWithPages(pages, current_page, nil, scope)
    tools = BookTools:new(tools.ui, ui_settings)
    addNativeSearch(tools, pages, xpointers)
    return tools
end

TestRunner:test("native search: candidate pages from the document search give the same hits as the scan", function()
    local pages = generatedPages()
    local scan = makeToolsWithPages(pages, #pages, nil, "full")
    TestRunner:assertEqual(scan:useNativeSearch(#pages), false, "a short range scans (no native search on the mock)")
    local queries = {
        "rabbit", "cat", "garden lantern", "white rabbit garden", "daisy letter lantern",
        "Daisey lantern cellar", "rabit garden celar", "self-knowledge", "o'clock cellar",
        "the garden path", "1984 house", "rabbit garden cellar house path",
    }
    for _v, xpointers in ipairs({ false, true }) do
        local native = nativeTools(pages, #pages, "full", nil, xpointers)
        TestRunner:assertEqual(native:useNativeSearch(#pages), true, "native path on")
        for _q, query in ipairs(queries) do
            local a = scan:searchBook({ query = query, max_hits = 40 }).queries[1]
            local b = native:searchBook({ query = query, max_hits = 40 }).queries[1]
            local label = string.format("%q xpointers=%s", query, tostring(xpointers))
            TestRunner:assertEqual(b.total_hits, a.total_hits, "total_hits " .. label)
            TestRunner:assertEqual(b.matching_pages, a.matching_pages, "matching_pages " .. label)
            TestRunner:assertEqual(#b.results, #a.results, "shown count " .. label)
            for i, hit in ipairs(a.results) do
                TestRunner:assertEqual(b.results[i].hit_id, hit.hit_id, "hit order " .. label)
                TestRunner:assertEqual(b.results[i].match_type, hit.match_type, "match type " .. label)
                TestRunner:assertEqual(b.results[i].score, hit.score, "score " .. label)
            end
        end
    end
    -- Case-sensitive queries walk case-sensitively and still match.
    local cs = nativeTools(pages, #pages, "full")
    TestRunner:assertEqual(cs:searchBook({ query = "Alice", case_sensitive = true }).queries[1].total_hits, 1, "case-sensitive hit")
    TestRunner:assertEqual(cs:searchBook({ query = "ALICE", case_sensitive = true }).queries[1].total_hits, 0, "case-sensitive miss")
end)

TestRunner:test("native search: one walk per word, memoized across calls, budgeted per call", function()
    local pages = generatedPages()
    local tools = nativeTools(pages, #pages, "full", { native_max_walks = 3 })
    local walks = tools.ui.document.walks
    tools:searchBook({ query = "garden lantern" })
    TestRunner:assertEqual(#walks, 2, "two words, two walks, no phrase walk")
    TestRunner:assertEqual(walks[1], "lantern", "longest word first")
    tools:searchBook({ query = "lantern cellar" })
    TestRunner:assertEqual(#walks, 3, "a memoized word is not walked again")
    TestRunner:assertEqual(walks[3], "cellar", "only the new word")
    -- Budget: 3 new walks per call; the fourth word is a wildcard, a fifth query gets an error.
    local result = tools:searchBook({ queries = { "house path curved alice", "letter" } })
    TestRunner:assertEqual(#walks, 6, "three new walks, then the budget is spent")
    local first = result.queries[1]
    TestRunner:assertTrue(first.error == nil, "the query still runs on the walked words")
    TestRunner:assertTrue(hasNote(first.notes, "1 word(s) of the query (path) were not searched for on their own"), "the unwalked word is noted, not dropped")
    local second = result.queries[2]
    TestRunner:assertEqual(second.total_hits, 0, "nothing walked for the second query")
    TestRunner:assertTrue(tostring(second.error):find("lookup budget", 1, true) ~= nil, "the spent budget is an error block")
    -- The same words on the next call are free.
    walks = tools.ui.document.walks
    local again = tools:searchBook({ query = "letter house" })
    TestRunner:assertEqual(#walks, 7, "letter walked, house memoized")
    TestRunner:assertTrue(again.queries[1].error == nil, "runs")
end)

TestRunner:test("native search: a very common word is a wildcard, all-common queries fall back to the phrase", function()
    local pages = generatedPages()
    -- A 3-hit cap: every vocabulary word hits it; "saw" (one demo sentence) does not.
    local tools = nativeTools(pages, #pages, "full", { native_max_hits = 3 })
    local scan = makeToolsWithPages(pages, #pages, nil, "full")
    local block = tools:searchBook({ query = "saw rabbit" }).queries[1]
    local expected = scan:searchBook({ query = "saw rabbit" }).queries[1]
    TestRunner:assertEqual(block.total_hits, expected.total_hits, "the rare word carries the search; totals exact")
    TestRunner:assertEqual(block.total_hits, 1, "the demo sentence")
    -- Every word common, two words: the exact phrase is the only narrowing.
    local phrase = tools:searchBook({ query = "rabbit garden" }).queries[1]
    TestRunner:assertTrue(hasNote(phrase.notes, "Every word of this query is very common"), "phrase-only note")
    for _idx, hit in ipairs(phrase.results) do
        TestRunner:assertTrue(hit.match_type == "phrase" or hit.match_type == "substring", "phrase rung only")
    end
    -- One common word: its first occurrences, said so.
    local single = tools:searchBook({ query = "rabbit" }).queries[1]
    TestRunner:assertTrue(hasNote(single.notes, "Only the first 3 occurrences"), "single capped note")
    TestRunner:assertTrue(single.total_hits > 0, "still returns the first occurrences")
    -- Common words are not required: "rabbit garden saw" has one content word, "saw", so
    -- the sentence holding it is a tokens hit and the two common words are only noted.
    local mixed = tools:searchBook({ query = "rabbit garden saw" }).queries[1]
    TestRunner:assertTrue(hasNote(mixed.notes, "2 very common word(s) of the query (rabbit, garden) occur on most pages"), "common words noted")
    TestRunner:assertEqual(mixed.total_hits, 1, "the one sentence with saw")
    TestRunner:assertEqual(mixed.results[1].match_type, "tokens", "every content word present")
    for _idx, hit in ipairs(mixed.results) do
        TestRunner:assertTrue(pages[hit.page]:lower():find("saw", 1, true) ~= nil, "every hit page holds the rare word")
    end
end)

TestRunner:test("native search: hits past the ceiling and in hidden flows are no candidates", function()
    local pages = generatedPages()
    local tools = nativeTools(pages, 20, "current")
    local block = tools:searchBook({ query = "lantern" }).queries[1]
    for _idx, hit in ipairs(block.results) do
        TestRunner:assertTrue(hit.page <= 20, "hit within the ceiling")
    end
    local scan = makeToolsWithPages(pages, 20, nil, "current")
    TestRunner:assertEqual(block.total_hits, scan:searchBook({ query = "lantern" }).queries[1].total_hits, "same total as the scan")
    -- Hidden flows: the walk lands on them, the mapping drops them.
    local hidden = nativeTools(DEMO_PAGES, 4, "full")
    local document = hidden.ui.document
    document.hasHiddenFlows = function() return true end
    document.getPageFlow = function(_self, page) return page >= 3 and 1 or 0 end
    local search = hidden:searchBook({ query = "lantern" })
    TestRunner:assertEqual(search.queries[1].total_hits, 0, "hidden page not a candidate")
    TestRunner:assertTrue(hasNote(search.notes, "2 of 4 pages are in sections the reader has hidden"), "hidden pages counted")
    -- Literal (token-less) queries walk the text itself, once.
    local cjk = nativeTools({ "他走进了花园。", "花园里很安静。" }, 2, "full")
    local literal = cjk:searchBook({ query = "花园" }).queries[1]
    TestRunner:assertEqual(literal.total_hits, 2, "literal hits on both pages")
    TestRunner:assertEqual(#cjk.ui.document.walks, 1, "one walk for a literal query")
end)

TestRunner:test("executeAsync runs in process without a fork and returns no cancel", function()
    local tools = makeTools()
    local got
    local cancel = tools:executeAsync("search_book", { query = "lantern" }, function(result) got = result end)
    TestRunner:assertEqual(cancel, nil, "no child, no cancel")
    TestRunner:assertEqual(got and got.queries[1].results[1].page, 3, "result delivered synchronously")
    local toc
    tools:executeAsync("toc", {}, function(result) toc = result end)
    TestRunner:assertTrue(toc and toc.entry_count ~= nil, "toc delivered synchronously")
end)

TestRunner:test("whole-word hits outrank hits inside longer words", function()
    local tools = makeToolsWithPages({
        "The animals ran. The anima is the inner figure.",
        "Animated talk about animal noises.",
        "Rabbits and the white rabbit garden.",
    }, 3, {}, "full")
    local block = tools:searchBook({ query = "anima" }).queries[1]
    TestRunner:assertEqual(block.total_hits, 3, "one whole-word sentence, two inside longer words")
    TestRunner:assertEqual(block.results[1].match_type, "phrase", "whole word first")
    TestRunner:assertEqual(block.results[1].page, 1, "the anima sentence")
    TestRunner:assertEqual(block.results[2].match_type, "substring", "inside 'animals' ranks below")
    TestRunner:assertEqual(block.results[3].match_type, "substring", "inside 'animated' too")
    -- Multi-word: every word whole → tokens; a word only inside a longer word → substring.
    local tokens = tools:searchBook({ query = "rabbit garden" }).queries[1]
    TestRunner:assertEqual(tokens.results[1].match_type, "phrase", "adjacent whole words are a phrase")
    local mixed = tools:searchBook({ query = "rabbits garden" }).queries[1]
    TestRunner:assertEqual(mixed.results[1].match_type, "tokens", "both whole words, apart")
    local inside = tools:searchBook({ query = "anima figure" }).queries[1]
    TestRunner:assertEqual(inside.results[1].match_type, "tokens", "anima and figure both whole on page 1")
    local weak = tools:searchBook({ query = "anima noises" }).queries[1]
    TestRunner:assertEqual(weak.results[1].match_type, "substring", "anima only inside 'animal' on page 2")
    -- A hyphen or a non-ASCII neighbour still counts as a word boundary.
    local hy = makeToolsWithPages({ "self-knowledge grows. ورائحة البحر" }, 1, {}, "full")
    TestRunner:assertEqual(hy:searchBook({ query = "knowledge" }).queries[1].results[1].match_type, "phrase", "after a hyphen")
    TestRunner:assertEqual(hy:searchBook({ query = "رائحة" }).queries[1].results[1].match_type, "phrase", "Arabic clitic prefix")
end)

TestRunner:test("getBookLanguage reads metadata then typography; getScope carries a contents outline", function()
    local tools = makeToolsWithPages(DEMO_PAGES, 2, BIG_TOC)  -- reader at page 2 of 4, protected
    tools.ui.doc_props = { language = "de" }
    TestRunner:assertEqual(tools:getBookLanguage(), "de", "language from the document props")
    local scope = tools:getScope()
    TestRunner:assertEqual(scope.language, nil, "the scope itself carries no language (the runner resolves the setting)")
    local outline = scope.outline
    TestRunner:assertEqual(outline.has_toc, true, "outline present")
    TestRunner:assertEqual(#outline.entries, 4, "entries within reach at the levels that fit")
    TestRunner:assertEqual(outline.past_position, 4, "later entries counted, not listed")
    TestRunner:assertEqual(outline.entries[1].continues_past_position, true, "open entry marked")
    tools.ui.doc_props = { language = "" }
    tools.ui.typography = { text_lang_tag = "en-US" }
    TestRunner:assertEqual(tools:getBookLanguage(), "en-US", "typography language as fallback")
    tools.ui.typography = nil
    TestRunner:assertEqual(tools:getBookLanguage(), nil, "unknown stays nil")
    local bare = makeToolsWithPages(DEMO_PAGES, 3, {})
    TestRunner:assertEqual(bare:getScope().outline.has_toc, false, "no TOC flagged")
end)

TestRunner:test("toc under spoiler protection counts the entries past the reader", function()
    local tools = makeToolsWithPages(DEMO_PAGES, 2, BIG_TOC)  -- reader at page 2 of 4
    local result = tools:toc()
    TestRunner:assertEqual(result.entry_count, 4, "entries up to the reader")
    TestRunner:assertTrue(hasNote(result.notes, "4 entries start after the reader's current position"), "later entries counted")
    TestRunner:assertEqual(result.entries[1].continues_past_position, true, "Volume 1 continues past the reader")
    TestRunner:assertEqual(result.entries[3].continues_past_position, nil, "closed entry has no marker")
end)

TestRunner:test("toc without a table of contents returns no entries and says so", function()
    local tools = makeToolsWithPages(DEMO_PAGES, 3, {})
    local result = tools:toc()
    TestRunner:assertTrue(result.ok, "ok")
    TestRunner:assertEqual(result.entry_count, 0, "no synthetic entry")
    TestRunner:assertTrue(hasNote(result.notes, "no table of contents"), "stated")
end)

TestRunner:test("read_around states a moved target and truncated batches", function()
    local tools = makeTools()  -- reader at page 3 of 4
    local moved = tools:readAround({ page = 4, before_pages = 0, after_pages = 0 })
    TestRunner:assertTrue(moved.ok, "ok")
    TestRunner:assertEqual(moved.page, 3, "clamped to the reader")
    TestRunner:assertTrue(hasNote(moved.notes, "Page 4 is past the readable range"), "move stated")
    TestRunner:assertEqual(moved.chars, #moved.text, "chars describes the returned text")
    local batch = tools:readAround({ pages = { 1, 2, 3, 1, 2 }, before_pages = 0, after_pages = 0 })
    TestRunner:assertEqual(batch.target_count, 4, "4 targets read")
    TestRunner:assertTrue(hasNote(batch.notes, "Read 4 of 5 requested targets"), "batch cap stated")
    local skipped = tools:readAround({ hit_ids = { "nonsense", "q1:p1:1" }, before_pages = 0, after_pages = 0 })
    TestRunner:assertEqual(skipped.target_count, 1, "one resolved")
    TestRunner:assertTrue(hasNote(skipped.notes, "1 target(s) could not be resolved"), "skip stated")
end)

TestRunner:test("content words: very common words are not required, partial hits rank by rarity (scan and native)", function()
    -- 40 pages: "alpha" on every page (common), "beta" and "gamma" on 10 pages each,
    -- "delta" on 5, "zeta" on 1 (page 30). Nothing else repeats.
    local pages = {}
    for p = 1, 40 do
        local words = { "alpha filler" .. p }
        if p <= 10 then table.insert(words, "beta") end
        if p >= 11 and p <= 20 then table.insert(words, "gamma") end
        if p >= 21 and p <= 25 then table.insert(words, "delta") end
        pages[p] = table.concat(words, " ") .. "."
    end
    pages[5] = "alpha beta gamma delta here."     -- three of four content words, the commoner ones
    pages[30] = "alpha gamma delta zeta there."   -- three of four, holding the rarest word
    pages[35] = "alpha beta only."                 -- one content word
    for _v, native in ipairs({ false, true }) do
        local tools = native and nativeTools(pages, #pages, "full") or makeToolsWithPages(pages, #pages, nil, "full")
        local label = native and " (native)" or " (scan)"
        -- "alpha" is common (40 of 40 pages); a query needs the content words only.
        local block = tools:searchBook({ query = "beta alpha gamma" }).queries[1]
        TestRunner:assertTrue(hasNote(block.notes, "1 very common word(s) of the query (alpha)"), "common word noted" .. label)
        TestRunner:assertEqual(block.total_hits, 1, "beta and gamma together once" .. label)
        TestRunner:assertEqual(block.results[1].match_type, "tokens", "every content word present is a tokens hit" .. label)
        TestRunner:assertEqual(block.results[1].page, 5, "page 5" .. label)
        -- Partial hits: page 30 holds the rarest words and ranks above page 5 despite page order.
        local partial = tools:searchBook({ query = "beta gamma delta zeta" }).queries[1]
        TestRunner:assertEqual(partial.total_hits, 2, "two sentences hold 3 of 4" .. label)
        TestRunner:assertEqual(partial.results[1].page, 30, "the rarer words rank first" .. label)
        TestRunner:assertEqual(partial.results[1].match_type, "partial", "partial rung" .. label)
        TestRunner:assertTrue(partial.results[1].score > partial.results[2].score, "rarity decides the score" .. label)
        TestRunner:assertEqual(table.concat(partial.results[1].missing, ","), "beta", "missing lists content words" .. label)
        -- A query of only common words keeps them (nothing to prefer).
        local common = tools:searchBook({ query = "alpha" }).queries[1]
        TestRunner:assertEqual(common.total_hits, 40, "a lone common word still searches" .. label)
        TestRunner:assertTrue(not hasNote(common.notes, "very common word(s) of the query"), "no exclusion note when nothing was excluded" .. label)
    end
    -- Below the floor nothing is common: the 4-page demo book requires every word.
    local small = makeTools():searchBook({ query = "the rabbit" }).queries[1]
    TestRunner:assertEqual(small.results[1].match_type, "tokens", "no common words in a short book")
end)

TestRunner:test("isRoutineNote: caps are routine, unreachable parts of the book are not", function()
    local routine = {
        'Showing 12 of 42 hits for "x" (highest scoring first, at most 2 per page); total_hits is the exact count.',
        "page_summary lists the first 40 of 90 pages with hits.",
        "3 of the shown hits contain only some of the query words (match_type partial; the missing words are listed). Full matches rank above them.",
        "This query has no word tokens (for example CJK text), so it was matched as a literal substring.",
        "2 very common word(s) of the query (is, the) occur on most pages and were not required in the matches.",
        "1 word(s) of the query (alice) were not searched for on their own (the call's search budget was spent); they were still required on the pages the other words found.",
        "The passage was cut to 8000 characters; ask for fewer pages or a narrower target for the rest.",
        "Read 4 of 6 requested targets (limit 4 per call); ask again for the rest.",
        "1 target(s) could not be resolved (unknown hit_id or missing page) and were skipped.",
        "This book has no table of contents; pages 1-9 are readable.",
        "No entries match the given title_contains / max_depth filters within the readable range.",
        "The contents has 400 matching entries, more than the 120-per-call limit, so only levels 1-2 are listed (80 entries); deeper levels need max_depth or title_contains.",
        "Showing entries 1-120 of 400 matching entries in document order (limit 120 per call). Narrow with max_depth (1 = top level) or title_contains.",
    }
    for _idx, note in ipairs(routine) do
        TestRunner:assertTrue(BookTools.isRoutineNote(note), "routine: " .. note:sub(1, 40))
    end
    local material = {
        "This call covers pages 1-9 of 40 only (the reader's current position). The 31 later pages are out of reach while spoiler protection is on: a missing hit is not evidence that the book lacks it, so say so instead of answering from memory.",
        "2 of 4 pages are in sections the reader has hidden (KOReader hidden flows) and were not searched.",
        "Page 12 is past the readable range (the reader is at page 9 of 40); pages 8-9 were read instead.",
        "Only the first 5000 occurrences, from the start of the book, were checked; narrow the query for the rest.",
        "Every word of this query is very common, so only sentences holding the exact phrase were counted (single words and partial matches were not).",
        "5 entries start after the reader's current position (page 9 of 40) and were not listed; spoiler protection keeps them out of reach.",
        "2 entries are in sections the reader has hidden (KOReader hidden flows) and were not listed.",
        "The lookup budget for this call was spent on earlier queries; ask again with fewer queries.",
    }
    for _idx, note in ipairs(material) do
        TestRunner:assertTrue(not BookTools.isRoutineNote(note), "material: " .. note:sub(1, 40))
    end
    -- The live wording: a real result's routine notes classify as routine.
    local tools = makeTools()
    local block = tools:searchBook({ query = "white rabbit garden" }).queries[1]
    for _idx, note in ipairs(block.notes or {}) do
        TestRunner:assertTrue(BookTools.isRoutineNote(note), "live partial note is routine")
    end
    local range = tools:searchBook({ query = "rabbit" })
    TestRunner:assertTrue(not BookTools.isRoutineNote(range.notes[1]), "live range note is material")
end)

TestRunner:test("xrayOutlineBlock (B337b): the contents of an X-Ray create's text, to where it ends", function()
    local pages = {}
    for page = 1, 30 do pages[page] = "Page " .. page .. "." end
    local toc = {
        { title = "Introduction", page = 1, depth = 1 },
        { title = "Chronology", page = 8, depth = 1 },
        { title = "Part One", page = 12, depth = 1 },
        { title = "Chapter 1", page = 12, depth = 2 },
        { title = "Chapter 2", page = 20, depth = 2 },
        { title = "Part Two", page = 26, depth = 1 },
    }
    local ui = makeToolsWithPages(pages, 28, toc).ui
    -- A checkpoint whose text ends on page 10: front matter only
    local block = BookTools.xrayOutlineBlock(ui, 10)
    TestRunner:assertTrue(block:find("- Introduction\n", 1, true), "listed")
    TestRunner:assertTrue(block:find("- Chronology (the text ends inside it)", 1, true), "where the text ends")
    TestRunner:assertTrue(not block:find("Part One", 1, true), "nothing past the text's end")
    -- To page 21: nested, the text ends inside chapter 2
    block = BookTools.xrayOutlineBlock(ui, 21)
    TestRunner:assertTrue(block:find("\n  - Chapter 2 (the text ends inside it)", 1, true), "nested entry")
    TestRunner:assertTrue(not block:find("Part Two", 1, true), "later part not listed")
    -- No end page: the reader's page (28)
    TestRunner:assertTrue(BookTools.xrayOutlineBlock(ui):find("Part Two", 1, true), "to the reader's page")
    -- The whole book
    block = BookTools.xrayOutlineBlock(ui, nil, true)
    TestRunner:assertTrue(block:find("(the whole book)", 1, true) and block:find("Part Two", 1, true), "whole book")
    TestRunner:assertTrue(not block:find("ends inside", 1, true), "nothing continues past the end")
    TestRunner:assertEqual(BookTools.xrayOutlineBlock(makeToolsWithPages(pages, 28, {}).ui, 10), nil, "no contents, no block")
end)

return TestRunner:summary()
