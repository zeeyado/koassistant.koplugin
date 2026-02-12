--[[
Unit Tests for X-Ray occurrence counting

Tests:
- _collectMatchSpans(): basic matching, word boundaries, Unicode punctuation boundaries
- _countOccurrences(): wrapper correctness
- countItemOccurrences(): union span-merge (name + aliases), deduplication of overlapping spans

Run: lua tests/run_tests.lua --unit
]]

-- Setup test environment
package.path = package.path .. ";./?.lua;./?/init.lua"
require("tests.lib.mock_koreader")

local XrayParser = require("koassistant_xray_parser")

-- Test suite
local TestXrayCounting = {
    passed = 0,
    failed = 0,
}

function TestXrayCounting:test(name, fn)
    local ok, err = pcall(fn)
    if ok then
        self.passed = self.passed + 1
        print(string.format("  \226\156\147 %s", name))
    else
        self.failed = self.failed + 1
        print(string.format("  \226\156\151 %s: %s", name, tostring(err)))
    end
end

function TestXrayCounting:assert(condition, message)
    if not condition then
        error(message or "Assertion failed", 2)
    end
end

function TestXrayCounting:assertEquals(actual, expected, message)
    if actual ~= expected then
        error(string.format("%s: expected %s, got %s",
            message or "Values not equal",
            tostring(expected),
            tostring(actual)), 2)
    end
end

function TestXrayCounting:runAll()
    print("\n=== Testing X-Ray occurrence counting ===\n")

    -- ===== _countOccurrences basic tests =====
    print("--- _countOccurrences ---")

    self:test("simple word match", function()
        self:assertEquals(XrayParser._countOccurrences("hello world hello", "hello"), 2)
    end)

    self:test("word boundary: no match inside word", function()
        self:assertEquals(XrayParser._countOccurrences("quality ali baba", "ali"), 1,
            "Should not match 'ali' inside 'quality'")
    end)

    self:test("word boundary: match at start/end of text", function()
        self:assertEquals(XrayParser._countOccurrences("ali met ali", "ali"), 2)
    end)

    self:test("word boundary: match next to ASCII punctuation", function()
        self:assertEquals(XrayParser._countOccurrences('he said "hello" to her', "hello"), 1)
    end)

    self:test("word boundary: match with possessive 's", function()
        self:assertEquals(XrayParser._countOccurrences("constantine's army marched", "constantine"), 1,
            "Should match 'constantine' in possessive form")
    end)

    self:test("word boundary: no match inside contraction", function()
        self:assertEquals(XrayParser._countOccurrences("don't worry about it", "don"), 1,
            "Apostrophe is not a word character, so 'don' matches in don't")
    end)

    self:test("short needle still matches in _countOccurrences", function()
        -- _countOccurrences has no length filter; the >2 byte filter is in countItemOccurrences
        self:assertEquals(XrayParser._countOccurrences("a b c a", "a"), 2)
    end)

    -- ===== Unicode punctuation boundary tests =====
    print("\n--- Unicode punctuation boundaries ---")

    -- Em-dash: U+2014 = E2 80 94
    self:test("match adjacent to em-dash", function()
        local text = "elizabeth\226\128\148the heroine"  -- elizabeth—the heroine
        self:assertEquals(XrayParser._countOccurrences(text, "elizabeth"), 1,
            "Should match 'elizabeth' before em-dash")
        self:assertEquals(XrayParser._countOccurrences(text, "the"), 1,
            "Should match 'the' after em-dash")
    end)

    -- Smart double quotes: U+201C = E2 80 9C, U+201D = E2 80 9D
    self:test("match inside smart double quotes", function()
        local text = "\226\128\156elizabeth\226\128\157 was there"  -- "elizabeth" was there
        self:assertEquals(XrayParser._countOccurrences(text, "elizabeth"), 1,
            "Should match inside smart double quotes")
    end)

    -- Smart single quotes: U+2018 = E2 80 98, U+2019 = E2 80 99
    self:test("match inside smart single quotes", function()
        local text = "\226\128\152elizabeth\226\128\153 was there"  -- 'elizabeth' was there
        self:assertEquals(XrayParser._countOccurrences(text, "elizabeth"), 1,
            "Should match inside smart single quotes")
    end)

    -- Ellipsis: U+2026 = E2 80 A6
    self:test("match adjacent to ellipsis", function()
        local text = "elizabeth\226\128\166 she said"  -- elizabeth… she said
        self:assertEquals(XrayParser._countOccurrences(text, "elizabeth"), 1,
            "Should match before ellipsis")
    end)

    -- En-dash: U+2013 = E2 80 93
    self:test("match adjacent to en-dash", function()
        local text = "chapters 1\226\128\147elizabeth\226\128\14710"  -- chapters 1–elizabeth–10
        self:assertEquals(XrayParser._countOccurrences(text, "elizabeth"), 1)
    end)

    -- Accented Latin: should still block (caf should not match in café)
    self:test("no match inside accented word", function()
        local text = "caf\195\169 au lait"  -- café au lait
        self:assertEquals(XrayParser._countOccurrences(text, "caf"), 0,
            "Should NOT match 'caf' inside 'café'")
    end)

    -- Guillemets: U+00AB = C2 AB, U+00BB = C2 BB
    self:test("match inside guillemets", function()
        local text = "\194\171elizabeth\194\187 said"  -- «elizabeth» said
        self:assertEquals(XrayParser._countOccurrences(text, "elizabeth"), 1,
            "Should match inside guillemets")
    end)

    -- ===== _collectMatchSpans tests =====
    print("\n--- _collectMatchSpans ---")

    self:test("returns correct spans", function()
        local spans = XrayParser._collectMatchSpans("hello world hello", "hello")
        self:assertEquals(#spans, 2, "Should find 2 spans")
        self:assertEquals(spans[1][1], 1, "First span starts at 1")
        self:assertEquals(spans[1][2], 5, "First span ends at 5")
        self:assertEquals(spans[2][1], 13, "Second span starts at 13")
        self:assertEquals(spans[2][2], 17, "Second span ends at 17")
    end)

    self:test("no spans for no match", function()
        local spans = XrayParser._collectMatchSpans("hello world", "xyz")
        self:assertEquals(#spans, 0, "Should find 0 spans")
    end)

    -- ===== countItemOccurrences union tests =====
    print("\n--- countItemOccurrences (union span-merge) ---")

    self:test("single name, no aliases", function()
        local item = { name = "Elizabeth", description = "Test" }
        local text = "elizabeth went home. elizabeth was happy."
        self:assertEquals(XrayParser.countItemOccurrences(item, text), 2)
    end)

    self:test("name + alias: union not max", function()
        -- "albert einstein" appears once, "einstein" appears 3 times total
        -- (once as part of "albert einstein", twice standalone)
        -- Union should give 3 (not max of 3)
        local item = { name = "Albert Einstein", aliases = {"Einstein"} }
        local text = "albert einstein was a genius. einstein changed physics. einstein won the nobel."
        local count = XrayParser.countItemOccurrences(item, text)
        self:assertEquals(count, 3, "Union: 1 'albert einstein' + 2 standalone 'einstein' = 3")
    end)

    self:test("overlapping spans are merged", function()
        -- "albert einstein" contains "einstein" — the overlap should be merged
        local item = { name = "Albert Einstein", aliases = {"Einstein"} }
        local text = "albert einstein spoke."
        local count = XrayParser.countItemOccurrences(item, text)
        self:assertEquals(count, 1, "Overlapping 'albert einstein' and 'einstein' = 1 unique match")
    end)

    self:test("multiple non-overlapping aliases", function()
        local item = { name = "Elizabeth Bennet", aliases = {"Lizzy", "Eliza"} }
        local text = "elizabeth bennet met lizzy and eliza was there. lizzy smiled."
        local count = XrayParser.countItemOccurrences(item, text)
        -- 1 "elizabeth bennet" + 2 "lizzy" + 1 "eliza" = 4
        self:assertEquals(count, 4, "All non-overlapping aliases counted")
    end)

    self:test("parenthetical name counted as term", function()
        local item = { name = "Theosis (Deification)", description = "Test" }
        local text = "theosis is a concept. deification means becoming divine. theosis again."
        local count = XrayParser.countItemOccurrences(item, text)
        -- 2 "theosis" + 1 "deification" = 3
        self:assertEquals(count, 3, "Parenthetical content counted as separate term")
    end)

    self:test("short name/alias filtered out", function()
        local item = { name = "Bo", description = "Test" }
        self:assertEquals(XrayParser.countItemOccurrences(item, "bo was here"), 0,
            "Names <= 2 bytes should return 0")
    end)

    self:test("short alias filtered out", function()
        local item = { name = "Robert", aliases = {"Bo", "Bob"} }
        local text = "robert and bo and bob were there"
        local count = XrayParser.countItemOccurrences(item, text)
        -- "robert" = 1, "bo" filtered (<=2), "bob" = 1 → union = 2
        self:assertEquals(count, 2, "Short alias 'Bo' filtered, 'Bob' counted")
    end)

    self:test("empty text returns 0", function()
        local item = { name = "Elizabeth", description = "Test" }
        self:assertEquals(XrayParser.countItemOccurrences(item, ""), 0)
    end)

    self:test("unicode punctuation doesn't block matches", function()
        -- "elizabeth" surrounded by smart quotes and em-dashes
        local item = { name = "Elizabeth", description = "Test" }
        local text = "\226\128\156elizabeth\226\128\157 said\226\128\148elizabeth\226\128\148was there"
        local count = XrayParser.countItemOccurrences(item, text)
        self:assertEquals(count, 2, "Matches through smart quotes and em-dashes")
    end)

    -- Print summary
    print(string.format("\n%d passed, %d failed", self.passed, self.failed))
    return self.failed == 0
end

-- Run tests if executed directly
if arg and arg[0] and arg[0]:match("test_xray_counting%.lua$") then
    local success = TestXrayCounting:runAll()
    os.exit(success and 0 or 1)
end

return TestXrayCounting
