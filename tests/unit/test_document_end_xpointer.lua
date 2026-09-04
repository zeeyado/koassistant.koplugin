-- Parity audit F242 (2026-09-04): getPageXPointer(N) is the START of page N, so
-- every extraction that ended on the last page dropped that page's text (whole
-- document builds included). ContextExtractor.documentEndXPointer asks the
-- engine for the end of the last glyph on the last page and every range that
-- reaches the last page ends there.
--
-- Run: lua tests/unit/test_document_end_xpointer.lua  (or lua tests/run_tests.lua --unit)

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
end
setupPaths()
require("mock_koreader")
local ContextExtractor = require("koassistant_context_extractor")

local TestRunner = { passed = 0, failed = 0 }
function TestRunner:suite(name) print(string.format("\n  [%s]", name)) end
function TestRunner:test(name, fn)
    local ok, err = pcall(fn)
    if ok then self.passed = self.passed + 1; print("    ok   " .. name)
    else self.failed = self.failed + 1; print("    FAIL " .. name); print("      " .. tostring(err)) end
end
function TestRunner:assertEqual(actual, expected, msg)
    if actual ~= expected then
        error(string.format("%s: expected %s, got %s", msg or "assert",
            tostring(expected), tostring(actual)), 2)
    end
end
function TestRunner:assertTrue(v, msg) if not v then error(msg or "expected truthy", 2) end end

-- A fake CRE document: pages 1..N, page starts "xp_pN", document end "xp_end".
-- getTextFromPositions answers with the end of the CURRENT page, like crengine;
-- opts.no_end = the engine cannot tell, opts.end_xp = a wrong answer.
local function makeDoc(opts)
    opts = opts or {}
    local N = opts.pages or 10
    local rank = {}
    for p = 1, N + 1 do rank["xp_p" .. p] = p end
    rank["xp_end"] = N + 0.5
    local doc = {
        info = { number_of_pages = N, has_pages = false },
        current = opts.current or "xp_p3",
        calls = { goto_xps = {}, extractions = {} },
    }
    function doc:getXPointer() return self.current end
    function doc:gotoXPointer(xp) table.insert(self.calls.goto_xps, xp); self.current = xp end
    function doc:gotoPage(p) self.current = "xp_p" .. p end
    function doc:gotoPos(_pos) self.current = "xp_p1" end
    function doc:getPageXPointer(p)
        if p > N then return "" end   -- crengine: an empty xpointer past the last page
        return "xp_p" .. p
    end
    function doc:getTextFromPositions(_p0, _p1, no_draw)
        self.calls.no_draw = no_draw
        if opts.no_end then return nil end
        local page = tonumber(self.current:match("%d+"))
        if page == N then
            return { text = "last", pos0 = "xp_p" .. N, pos1 = opts.end_xp or "xp_end" }
        end
        return { pos1 = "xp_p" .. (page + 1) }
    end
    function doc:compareXPointers(a, b)
        local ra, rb = rank[a], rank[b]
        if not ra or not rb then return nil end
        if rb > ra then return 1 elseif rb < ra then return -1 else return 0 end
    end
    function doc:getTextFromXPointers(a, b)
        table.insert(self.calls.extractions, { a, b })
        return "text:" .. a .. "->" .. b
    end
    if opts.hidden_flows then
        function doc:hasHiddenFlows() return true end
        function doc:getPageFlow(_p) return 0 end
    end
    return doc
end

local function makeExtractor(doc)
    return ContextExtractor:new({ document = doc }, { enable_book_text_extraction = true })
end

local function lastExtraction(doc)
    local e = doc.calls.extractions[#doc.calls.extractions]
    return e and e[1], e and e[2]
end

TestRunner:suite("documentEndXPointer")

TestRunner:test("returns the end of the last page and restores the position", function()
    local doc = makeDoc()
    local xp = ContextExtractor.documentEndXPointer(doc, 10)
    TestRunner:assertEqual(xp, "xp_end", "end xpointer")
    TestRunner:assertEqual(doc.current, "xp_p3", "reader position restored")
    TestRunner:assertEqual(doc.calls.goto_xps[#doc.calls.goto_xps], "xp_p3", "restored via gotoXPointer")
    TestRunner:assertEqual(doc.calls.no_draw, true, "no selection drawn on screen")
end)

TestRunner:test("nil when the engine has no answer", function()
    local doc = makeDoc({ no_end = true })
    TestRunner:assertEqual(ContextExtractor.documentEndXPointer(doc, 10), nil, "no answer")
    TestRunner:assertEqual(doc.current, "xp_p3", "position still restored")
end)

TestRunner:test("nil when the answer is not ordered after the last page's start", function()
    local doc = makeDoc({ end_xp = "xp_p2" })
    TestRunner:assertEqual(ContextExtractor.documentEndXPointer(doc, 10), nil, "rejected")
end)

TestRunner:test("nil for a document without the selection call", function()
    TestRunner:assertEqual(ContextExtractor.documentEndXPointer({ info = { number_of_pages = 5 } }, 5), nil, "no call")
    TestRunner:assertEqual(ContextExtractor.documentEndXPointer(nil), nil, "no document")
end)

TestRunner:suite("ranges that reach the last page end at the document end")

TestRunner:test("getPageRangeText: last page included, inner ranges unchanged", function()
    local doc = makeDoc()
    local ex = makeExtractor(doc)
    local r = ex:getPageRangeText(8, 10)
    local a, b = lastExtraction(doc)
    TestRunner:assertEqual(a .. "|" .. b, "xp_p8|xp_end", "range to the end")
    TestRunner:assertEqual(r.text, "text:xp_p8->xp_end", "text returned")
    ex:getPageRangeText(2, 5)
    a, b = lastExtraction(doc)
    TestRunner:assertEqual(a .. "|" .. b, "xp_p2|xp_p6", "inner range still bounded by the next page start")
    TestRunner:assertEqual(doc.current, "xp_p3", "position restored")
end)

TestRunner:test("getPageRangeText: flow-aware path reaches the end too", function()
    local doc = makeDoc({ hidden_flows = true })
    makeExtractor(doc):getPageRangeText(1, 10)
    local a, b = lastExtraction(doc)
    TestRunner:assertEqual(a .. "|" .. b, "xp_p1|xp_end", "visible range to the end")
end)

TestRunner:test("getFullDocumentText: whole document, position restored", function()
    local doc = makeDoc()
    makeExtractor(doc):getFullDocumentText()
    local a, b = lastExtraction(doc)
    TestRunner:assertEqual(a .. "|" .. b, "xp_p1|xp_end", "start to the document end")
    TestRunner:assertEqual(doc.current, "xp_p3", "position restored")
end)

TestRunner:test("getFullDocumentText: falls back to the last page's start when the engine cannot tell", function()
    local doc = makeDoc({ no_end = true })
    makeExtractor(doc):getFullDocumentText()
    local a, b = lastExtraction(doc)
    TestRunner:assertEqual(a .. "|" .. b, "xp_p1|xp_p10", "old bound kept")
    TestRunner:assertEqual(doc.current, "xp_p3", "position restored")
end)

TestRunner:test("getBookTextRange: to 100% reaches the end, a mid-book range keeps its bound", function()
    local doc = makeDoc()
    local ex = makeExtractor(doc)
    ex:getBookTextRange(0.5, 1.0)
    local a, b = lastExtraction(doc)
    TestRunner:assertEqual(a .. "|" .. b, "xp_p5|xp_end", "to the document end")
    ex:getBookTextRange(0.2, 0.5)
    a, b = lastExtraction(doc)
    TestRunner:assertEqual(a .. "|" .. b, "xp_p2|xp_p5", "mid-book range unchanged")
    TestRunner:assertEqual(doc.current, "xp_p3", "position restored")
end)

print(string.format("\n  test_document_end_xpointer: %d passed, %d failed",
    TestRunner.passed, TestRunner.failed))
return TestRunner.failed == 0
