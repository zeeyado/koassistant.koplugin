-- Unit tests for koassistant_quiz_chapters.lua (pure chapter-boundary resolution).

local function setupPaths()
    local info = debug.getinfo(1, "S")
    local script_path = info.source:match("@?(.*)")
    local unit_dir = script_path:match("(.+)/[^/]+$") or "."
    local tests_dir = unit_dir:match("(.+)/[^/]+$") or "."
    local plugin_dir = tests_dir:match("(.+)/[^/]+$") or "."
    package.path = table.concat({
        plugin_dir .. "/?.lua", tests_dir .. "/?.lua", tests_dir .. "/lib/?.lua", package.path,
    }, ";")
end
setupPaths()

local QC = require("koassistant_quiz_chapters")

local TestRunner = { passed = 0, failed = 0 }
function TestRunner:suite(name) print(string.format("\n  [%s]", name)) end
function TestRunner:test(name, fn)
    local ok, err = pcall(fn)
    if ok then self.passed = self.passed + 1; print("    ✓ " .. name)
    else self.failed = self.failed + 1; print("    ✗ " .. name); print("      Error: " .. tostring(err)) end
end
function TestRunner:eq(a, b, msg)
    if a ~= b then error(string.format("%s: expected %q, got %q", msg or "eq", tostring(b), tostring(a))) end
end
function TestRunner:list(actual, expected, msg)
    if #actual ~= #expected then
        error(string.format("%s: length %d != %d", msg or "list", #actual, #expected))
    end
    for i = 1, #expected do
        if actual[i] ~= expected[i] then
            error(string.format("%s: [%d] expected %q got %q", msg or "list", i, tostring(expected[i]), tostring(actual[i])))
        end
    end
end

-- TOC fixtures: arrays of { page, depth }
local FLAT = { {page=1,depth=1}, {page=11,depth=1}, {page=21,depth=1} }
-- Part(1) > Chapter(2): I ch1 ch2 ch3 II ch4 ch5
local PART_CH = {
    {page=1,depth=1},  {page=2,depth=2}, {page=12,depth=2}, {page=22,depth=2},
    {page=32,depth=1}, {page=33,depth=2}, {page=43,depth=2},
}
-- Chapter(1) > Section(2): Ch1 1.1 1.2 Ch2 2.1   (sections ~4-6 pages)
local CH_SEC = {
    {page=1,depth=1}, {page=2,depth=2}, {page=6,depth=2}, {page=11,depth=1}, {page=12,depth=2},
}
-- Same-page parent/child: I & ch1 both on page 1
local SAME_PAGE = { {page=1,depth=1}, {page=1,depth=2}, {page=10,depth=2} }
-- Mixed: flat chapter A(d1), chapter B(d1) with sub B.1(d2)
local MIXED = { {page=1,depth=1}, {page=11,depth=1}, {page=12,depth=2} }

TestRunner:suite("maxDepth")
TestRunner:test("flat = 1", function() TestRunner:eq(QC.maxDepth(FLAT), 1) end)
TestRunner:test("part>chapter = 2", function() TestRunner:eq(QC.maxDepth(PART_CH), 2) end)
TestRunner:test("empty = 0", function() TestRunner:eq(QC.maxDepth({}), 0) end)

TestRunner:suite("chapterIndices")
TestRunner:test("flat level 1 = all", function() TestRunner:list(QC.chapterIndices(FLAT, 1), {1,2,3}) end)
TestRunner:test("flat level 2 self-clamps to all", function() TestRunner:list(QC.chapterIndices(FLAT, 2), {1,2,3}) end)
TestRunner:test("part>chapter level 1 = the Parts", function()
    TestRunner:list(QC.chapterIndices(PART_CH, 1), {1,5}) end)
TestRunner:test("part>chapter level 2 = the chapters (no Parts)", function()
    TestRunner:list(QC.chapterIndices(PART_CH, 2), {2,3,4,6,7}) end)
TestRunner:test("chapter>section level 1 = chapters (sections ignored)", function()
    TestRunner:list(QC.chapterIndices(CH_SEC, 1), {1,4}) end)
TestRunner:test("chapter>section level 2 = sections", function()
    TestRunner:list(QC.chapterIndices(CH_SEC, 2), {2,3,5}) end)
TestRunner:test("mixed level 2 = flat chapter + nested sub (container excluded)", function()
    TestRunner:list(QC.chapterIndices(MIXED, 2), {1,3}) end)
TestRunner:test("same-page level 2 = the child chapter, not the Part", function()
    TestRunner:list(QC.chapterIndices(SAME_PAGE, 2), {2,3}) end)

TestRunner:suite("currentChapter (range mapping)")
local PC2 = QC.chapterIndices(PART_CH, 2)  -- {2,3,4,6,7}, pages {2,12,22,33,43}
TestRunner:test("before first chapter → nil (front matter / Part heading)", function()
    TestRunner:eq(QC.currentChapter(PART_CH, PC2, 1), nil) end)
TestRunner:test("inside ch1 → ch1", function()
    TestRunner:eq(QC.currentChapter(PART_CH, PC2, 5), 2) end)
TestRunner:test("a Part-II heading page is absorbed into the preceding chapter (ch3)", function()
    TestRunner:eq(QC.currentChapter(PART_CH, PC2, 32), 4) end)
TestRunner:test("entering ch4 → ch4", function()
    TestRunner:eq(QC.currentChapter(PART_CH, PC2, 33), 6) end)

TestRunner:suite("currentChapter (same-page parent/child → no oscillation)")
local SP2 = QC.chapterIndices(SAME_PAGE, 2)  -- {2,3}, pages {1,10}
TestRunner:test("page 1 maps to ch1 (the child), never the Part", function()
    TestRunner:eq(QC.currentChapter(SAME_PAGE, SP2, 1), 2) end)
TestRunner:test("reading ch1 stays ch1 (no parent transition)", function()
    TestRunner:eq(QC.currentChapter(SAME_PAGE, SP2, 5), 2) end)
TestRunner:test("crossing to ch2 finishes ch1", function()
    TestRunner:eq(QC.currentChapter(SAME_PAGE, SP2, 10), 3) end)

TestRunner:suite("autoLevel")
TestRunner:test("flat → 1", function() TestRunner:eq(QC.autoLevel(FLAT, 30, 5), 1) end)
TestRunner:test("part>chapter → 2 (chapters are substantial)", function()
    TestRunner:eq(QC.autoLevel(PART_CH, 52, 5), 2) end)
TestRunner:test("chapter>section → 1 (sections too short for min_pages)", function()
    TestRunner:eq(QC.autoLevel(CH_SEC, 15, 5), 1) end)
TestRunner:test("lower min_pages lets auto pick the deeper level", function()
    TestRunner:eq(QC.autoLevel(CH_SEC, 15, 3), 2) end)

print("")
print(string.rep("-", 50))
print(string.format("  Results: %d passed, %d failed", TestRunner.passed, TestRunner.failed))
print(string.rep("-", 50))
return TestRunner.failed == 0
