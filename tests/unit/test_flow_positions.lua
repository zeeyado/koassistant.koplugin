-- B335 (2026-09-29): a book with hidden flows has two coordinate systems. The
-- reader's percent, checkpoint targets, installs and the card count only the
-- visible (flow 0) pages; raw page numbers count every page. The checkpoint
-- path read its targets as raw fractions, so a book whose front matter is
-- hidden extracted NOTHING for its first checkpoints (the request still went
-- out), snapped to hidden chapters, and the marks and page-turn gates ran
-- ahead of the installs. ContextExtractor.flowFraction / rawPageAt are the one
-- conversion pair; a background X-Ray step with no text never sends.
--
-- Run: lua tests/unit/test_flow_positions.lua  (or lua tests/run_tests.lua --unit)

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
local ContextExtractor = require("koassistant_context_extractor")
local XrayAuto = require("koassistant_xray_auto")

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

-- A fake CRE document of N pages. opts.hidden = { {first, last}, ... } hides
-- page runs the way KOReader's flows do: getPageFlow names the run, the flow
-- cache numbers a visible page by its place in flow 0 (getPageNumberInFlow)
-- and getTotalPagesInFlow(0) counts the visible pages. Page starts "xp_pN".
local function makeDoc(opts)
    opts = opts or {}
    local N = opts.pages or 30
    local flow_of = {}
    for i, run in ipairs(opts.hidden or {}) do
        for p = run[1], run[2] do flow_of[p] = i end
    end
    local in_flow, visible = {}, 0
    for p = 1, N do
        if not flow_of[p] then visible = visible + 1; in_flow[p] = visible end
    end
    local doc = {
        info = { number_of_pages = N, has_pages = false },
        current = "xp_p" .. (opts.at or 1),
        extractions = {},
    }
    function doc:getXPointer() return self.current end
    function doc:gotoXPointer(xp) self.current = xp end
    function doc:gotoPage(p) self.current = "xp_p" .. p end
    function doc:getPageFromXPointer(xp) return tonumber(xp:match("%d+")) end
    function doc:getPageXPointer(p)
        if p > N then return "" end
        return "xp_p" .. p
    end
    -- No end-of-document answer: ranges reaching the last page keep the old bound
    function doc:getTextFromPositions() return nil end
    function doc:getTextFromXPointers(a, b)
        table.insert(self.extractions, { a, b })
        return "text:" .. a .. "->" .. b
    end
    if opts.hidden then
        function doc:hasHiddenFlows() return true end
        function doc:getPageFlow(p) return flow_of[p] or 0 end
        function doc:getTotalPagesInFlow(flow)
            if flow == 0 then return visible end
            local run = opts.hidden[flow]
            return run[2] - run[1] + 1
        end
        function doc:getPageNumberInFlow(p)
            if flow_of[p] then return p - opts.hidden[flow_of[p]][1] + 1 end
            return in_flow[p]
        end
    end
    return doc
end

-- The novella's shape, shrunk: 30 pages, front matter 1-5 and back matter
-- 28-30 hidden, 22 visible pages (6..27)
local function hiddenDoc(at)
    return makeDoc({ pages = 30, hidden = { { 1, 5 }, { 28, 30 } }, at = at })
end

TestRunner:suite("flowFraction")

TestRunner:test("no hidden flows: page / total", function()
    local doc = makeDoc({ pages = 30 })
    TestRunner:assertEqual(ContextExtractor.flowFraction(doc, 15), 0.5, "mid-book")
    TestRunner:assertEqual(ContextExtractor.flowFraction(doc, 30), 1, "last page")
    TestRunner:assertEqual(ContextExtractor.flowFraction(doc, 0), 0, "page 0")
end)

TestRunner:test("hidden flows: visible pages only, a hidden page counts the ones before it", function()
    local doc = hiddenDoc()
    TestRunner:assertEqual(ContextExtractor.flowFraction(doc, 6), 1 / 22, "first visible page")
    TestRunner:assertEqual(ContextExtractor.flowFraction(doc, 16), 11 / 22, "mid visible")
    TestRunner:assertEqual(ContextExtractor.flowFraction(doc, 27), 1, "last visible page")
    TestRunner:assertEqual(ContextExtractor.flowFraction(doc, 3), 0, "hidden front matter")
    TestRunner:assertEqual(ContextExtractor.flowFraction(doc, 29), 1, "hidden back matter")
end)

TestRunner:test("agrees with getReadingProgress at every page", function()
    for p = 1, 30 do
        local doc = hiddenDoc(p)
        local prog = ContextExtractor:new({ document = doc }, {}):getReadingProgress()
        -- getReadingProgress falls back to the saved percent at exactly 0
        if prog.decimal > 0 then
            TestRunner:assertTrue(math.abs(prog.decimal - ContextExtractor.flowFraction(doc, p)) < 1e-12,
                "page " .. p)
        end
    end
end)

TestRunner:suite("rawPageAt")

TestRunner:test("hidden flows: the k-th visible page, rounded down or up", function()
    local doc = hiddenDoc()
    TestRunner:assertEqual(ContextExtractor.rawPageAt(doc, 0.5), 16, "0.5 of 22 = 11th visible")
    TestRunner:assertEqual(ContextExtractor.rawPageAt(doc, 0.1), 7, "2.2 down = 2nd visible")
    TestRunner:assertEqual(ContextExtractor.rawPageAt(doc, 0.1, true), 8, "2.2 up = 3rd visible")
    TestRunner:assertEqual(ContextExtractor.rawPageAt(doc, 0), 6, "never before the first visible page")
    TestRunner:assertEqual(ContextExtractor.rawPageAt(doc, 1.0, true), 27, "never into hidden back matter")
end)

TestRunner:test("round trip: every visible page maps back to itself", function()
    local doc = makeDoc({ pages = 131, hidden = { { 1, 18 }, { 60, 64 }, { 120, 131 } } })
    for p = 1, 131 do
        if doc:getPageFlow(p) == 0 then
            local f = ContextExtractor.flowFraction(doc, p)
            TestRunner:assertEqual(ContextExtractor.rawPageAt(doc, f), p, "down, page " .. p)
            TestRunner:assertEqual(ContextExtractor.rawPageAt(doc, f, true), p, "up, page " .. p)
        end
    end
end)

TestRunner:test("no hidden flows: fraction x total, float-safe (7/25 stays page 7)", function()
    for _idx, n in ipairs({ 22, 25, 49, 102 }) do
        local doc = makeDoc({ pages = n })
        for p = 1, n do
            TestRunner:assertEqual(ContextExtractor.rawPageAt(doc, p / n), p, n .. " down " .. p)
            TestRunner:assertEqual(ContextExtractor.rawPageAt(doc, p / n, true), p, n .. " up " .. p)
        end
    end
end)

TestRunner:test("nil without a page count or a fraction", function()
    TestRunner:assertEqual(ContextExtractor.rawPageAt({ info = {} }, 0.5), nil, "no pages")
    TestRunner:assertEqual(ContextExtractor.rawPageAt(makeDoc(), nil), nil, "no fraction")
end)

TestRunner:suite("extraction")

local function extractor(doc)
    return ContextExtractor:new({ document = doc }, { enable_book_text_extraction = true })
end

TestRunner:test("getBookTextRange maps page fractions back to exactly those pages", function()
    local doc = makeDoc({ pages = 25 })
    extractor(doc):getBookTextRange(2 / 25, 7 / 25)
    local e = doc.extractions[#doc.extractions]
    -- The plain path ends at the start of the last page asked for
    TestRunner:assertEqual(e[1] .. "|" .. e[2], "xp_p2|xp_p7", "pages 2..7, not 2..8")
end)

TestRunner:test("a checkpoint's first step reads the visible pages up to its flow target", function()
    local doc = hiddenDoc(20)
    local data = extractor(doc):extractForAction({
        use_book_text = true, prompt = "{book_text_section}",
    })
    TestRunner:assertTrue(data.book_text and data.book_text ~= "", "reader-position extraction has text")
    doc.extractions = {}
    local ex = ContextExtractor:new({ document = doc },
        { enable_book_text_extraction = true, _ladder_target_ratio = 0.1 })
    data = ex:extractForAction({ use_book_text = true, prompt = "{book_text_section}" })
    -- 0.1 of 22 visible pages, rounded up = 3 visible pages: raw 6..8, read as
    -- one visible run ending at the start of page 9. Read raw (the bug), the
    -- target was page 3: all hidden, nothing extracted.
    TestRunner:assertEqual(#doc.extractions, 1, "one visible run")
    TestRunner:assertEqual(doc.extractions[1][1] .. "|" .. doc.extractions[1][2], "xp_p6|xp_p9", "pages 6-8")
    TestRunner:assertTrue(not data.book_text_extraction_empty, "not flagged empty")
end)

TestRunner:suite("the no-text stop")

TestRunner:test("a step with no book text is named, and never retried", function()
    local kind, transient = XrayAuto.classifyStopReason("background: no book text")
    TestRunner:assertEqual(kind, "no_text", "kind")
    TestRunner:assertEqual(transient, false, "not transient")
    kind = XrayAuto.classifyStopReason("background: delta truncated")
    TestRunner:assertEqual(kind, "aborted", "other local skips unchanged")
end)

TestRunner:suite("every checkpoint site reads flow positions (source guard)")

local function read(rel)
    local f = assert(io.open(plugin_dir .. "/" .. rel, "r"))
    local s = f:read("*a")
    f:close()
    return s
end

TestRunner:test("no raw page fraction in the page-turn gates, snapping or the marks' pick", function()
    local main = read("main.lua")
    local body = main:match("function AskGPT:_xrayAutoOnPageUpdate%(pageno%)(.-)\nend\n")
    TestRunner:assertTrue(body, "page-turn gates found")
    TestRunner:assertTrue(not body:find("pageno / total", 1, true), "gates on flowFraction")
    local snap = main:match("function AskGPT:_ladderChapterBoundaries%(%)(.-)\nend\n")
    TestRunner:assertTrue(snap and snap:find("flowFraction", 1, true), "snapping on flow ratios")
    local marks = read("koassistant_xray_marks.lua")
    TestRunner:assertTrue(not marks:find("pageno / total", 1, true), "marks' ahead pick on flowFraction")
    local dialogs = read("koassistant_dialogs.lua")
    TestRunner:assertTrue(dialogs:find(".rawPageAt(ui.document, lt)", 1, true), "rung page through rawPageAt")
    TestRunner:assertTrue(dialogs:find('"background: no book text"', 1, true), "the no-text abort")
end)

TestRunner:test("a section target is a flow position (the form's coverage, the build limit)", function()
    for _idx, rel in ipairs({ "main.lua", "koassistant_book_settings.lua" }) do
        local src = read(rel)
        TestRunner:assertTrue(not src:find("(entry.end_page or 0) /", 1, true), rel .. ": no raw ratio")
        TestRunner:assertTrue(src:find("flowFraction%(%s*[%w_.]+document, entry%.end_page or 0%)"),
            rel .. ": the section end through flowFraction")
    end
end)

print(string.format("\n  test_flow_positions: %d passed, %d failed",
    TestRunner.passed, TestRunner.failed))
return TestRunner.failed == 0
