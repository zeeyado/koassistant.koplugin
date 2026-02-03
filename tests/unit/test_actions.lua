--[[
Unit Tests for prompts/actions.lua

Tests the placeholder gating and flag cascading logic:
- PLACEHOLDER_TO_FLAG mapping
- inferOpenBookFlags() cascading for book text
- inferOpenBookFlags() cascading for annotations
- DOUBLE_GATED_FLAGS definition
- REQUIRES_BOOK_TEXT and REQUIRES_ANNOTATIONS cascading

Run: lua tests/run_tests.lua --unit
]]

-- Setup test environment
package.path = package.path .. ";./?.lua;./?/init.lua"
require("tests.lib.mock_koreader")

local Actions = require("prompts.actions")

-- Test suite
local TestActions = {
    passed = 0,
    failed = 0,
}

function TestActions:test(name, fn)
    local ok, err = pcall(fn)
    if ok then
        self.passed = self.passed + 1
        print(string.format("  ✓ %s", name))
    else
        self.failed = self.failed + 1
        print(string.format("  ✗ %s: %s", name, tostring(err)))
    end
end

function TestActions:assert(condition, message)
    if not condition then
        error(message or "Assertion failed", 2)
    end
end

function TestActions:assertEquals(actual, expected, message)
    if actual ~= expected then
        error(string.format("%s: expected %s, got %s",
            message or "Values not equal",
            tostring(expected),
            tostring(actual)), 2)
    end
end

function TestActions:assertContains(tbl, value, message)
    for _, v in ipairs(tbl) do
        if v == value then return end
    end
    error(string.format("%s: table does not contain %s",
        message or "Value not found",
        tostring(value)), 2)
end

function TestActions:runAll()
    print("\n=== Testing prompts/actions.lua ===\n")

    -- Test PLACEHOLDER_TO_FLAG mapping exists
    self:test("PLACEHOLDER_TO_FLAG is defined", function()
        self:assertEquals(type(Actions.PLACEHOLDER_TO_FLAG), "table")
    end)

    -- Test annotation placeholders map to use_annotations
    self:test("{annotations} maps to use_annotations", function()
        self:assertEquals(Actions.PLACEHOLDER_TO_FLAG["{annotations}"], "use_annotations")
    end)

    self:test("{annotations_section} maps to use_annotations", function()
        self:assertEquals(Actions.PLACEHOLDER_TO_FLAG["{annotations_section}"], "use_annotations")
    end)

    self:test("{highlights} maps to use_annotations (unified)", function()
        self:assertEquals(Actions.PLACEHOLDER_TO_FLAG["{highlights}"], "use_annotations")
    end)

    self:test("{highlights_section} maps to use_annotations (unified)", function()
        self:assertEquals(Actions.PLACEHOLDER_TO_FLAG["{highlights_section}"], "use_annotations")
    end)

    -- Test book text placeholders
    self:test("{book_text} maps to use_book_text", function()
        self:assertEquals(Actions.PLACEHOLDER_TO_FLAG["{book_text}"], "use_book_text")
    end)

    self:test("{full_document} maps to use_book_text", function()
        self:assertEquals(Actions.PLACEHOLDER_TO_FLAG["{full_document}"], "use_book_text")
    end)

    -- Test document cache placeholders
    self:test("{xray_cache} maps to use_xray_cache", function()
        self:assertEquals(Actions.PLACEHOLDER_TO_FLAG["{xray_cache}"], "use_xray_cache")
    end)

    self:test("{analyze_cache} maps to use_analyze_cache", function()
        self:assertEquals(Actions.PLACEHOLDER_TO_FLAG["{analyze_cache}"], "use_analyze_cache")
    end)

    self:test("{summary_cache} maps to use_summary_cache", function()
        self:assertEquals(Actions.PLACEHOLDER_TO_FLAG["{summary_cache}"], "use_summary_cache")
    end)

    -- Test REQUIRES_BOOK_TEXT cascading
    print("\n--- REQUIRES_BOOK_TEXT cascading ---")

    self:test("REQUIRES_BOOK_TEXT includes use_xray_cache", function()
        self:assertContains(Actions.REQUIRES_BOOK_TEXT, "use_xray_cache")
    end)

    self:test("REQUIRES_BOOK_TEXT includes use_analyze_cache", function()
        self:assertContains(Actions.REQUIRES_BOOK_TEXT, "use_analyze_cache")
    end)

    self:test("REQUIRES_BOOK_TEXT includes use_summary_cache", function()
        self:assertContains(Actions.REQUIRES_BOOK_TEXT, "use_summary_cache")
    end)

    -- Test REQUIRES_ANNOTATIONS cascading
    print("\n--- REQUIRES_ANNOTATIONS cascading ---")

    self:test("REQUIRES_ANNOTATIONS includes use_xray_cache", function()
        self:assertContains(Actions.REQUIRES_ANNOTATIONS, "use_xray_cache")
    end)

    self:test("REQUIRES_ANNOTATIONS does NOT include use_analyze_cache", function()
        for _, v in ipairs(Actions.REQUIRES_ANNOTATIONS) do
            if v == "use_analyze_cache" then
                error("use_analyze_cache should NOT be in REQUIRES_ANNOTATIONS")
            end
        end
    end)

    self:test("REQUIRES_ANNOTATIONS does NOT include use_summary_cache", function()
        for _, v in ipairs(Actions.REQUIRES_ANNOTATIONS) do
            if v == "use_summary_cache" then
                error("use_summary_cache should NOT be in REQUIRES_ANNOTATIONS")
            end
        end
    end)

    -- Test DOUBLE_GATED_FLAGS
    print("\n--- DOUBLE_GATED_FLAGS ---")

    self:test("DOUBLE_GATED_FLAGS includes use_book_text", function()
        self:assertContains(Actions.DOUBLE_GATED_FLAGS, "use_book_text")
    end)

    self:test("DOUBLE_GATED_FLAGS includes use_annotations", function()
        self:assertContains(Actions.DOUBLE_GATED_FLAGS, "use_annotations")
    end)

    self:test("DOUBLE_GATED_FLAGS includes use_notebook", function()
        self:assertContains(Actions.DOUBLE_GATED_FLAGS, "use_notebook")
    end)

    -- Test inferOpenBookFlags() function
    print("\n--- inferOpenBookFlags() ---")

    self:test("inferOpenBookFlags returns empty for empty prompt", function()
        local flags = Actions.inferOpenBookFlags("")
        self:assertEquals(next(flags), nil, "Should return empty table")
    end)

    self:test("inferOpenBookFlags returns empty for nil prompt", function()
        local flags = Actions.inferOpenBookFlags(nil)
        self:assertEquals(next(flags), nil, "Should return empty table")
    end)

    self:test("inferOpenBookFlags detects {annotations}", function()
        local flags = Actions.inferOpenBookFlags("Use {annotations} here")
        self:assertEquals(flags.use_annotations, true)
    end)

    self:test("inferOpenBookFlags detects {book_text}", function()
        local flags = Actions.inferOpenBookFlags("Use {book_text} here")
        self:assertEquals(flags.use_book_text, true)
    end)

    self:test("inferOpenBookFlags detects {reading_progress}", function()
        local flags = Actions.inferOpenBookFlags("At {reading_progress}")
        self:assertEquals(flags.use_reading_progress, true)
    end)

    -- Test cascading for {xray_cache}
    print("\n--- inferOpenBookFlags() cascading for {xray_cache} ---")

    self:test("inferOpenBookFlags cascades use_book_text from {xray_cache}", function()
        local flags = Actions.inferOpenBookFlags("Use {xray_cache_section} here")
        self:assertEquals(flags.use_xray_cache, true, "Should set use_xray_cache")
        self:assertEquals(flags.use_book_text, true, "Should cascade to use_book_text")
    end)

    self:test("inferOpenBookFlags cascades use_annotations from {xray_cache}", function()
        local flags = Actions.inferOpenBookFlags("Use {xray_cache_section} here")
        self:assertEquals(flags.use_xray_cache, true, "Should set use_xray_cache")
        self:assertEquals(flags.use_annotations, true, "Should cascade to use_annotations")
    end)

    -- Test cascading for {analyze_cache} (only book text, not annotations)
    print("\n--- inferOpenBookFlags() cascading for {analyze_cache} ---")

    self:test("inferOpenBookFlags cascades use_book_text from {analyze_cache}", function()
        local flags = Actions.inferOpenBookFlags("Use {analyze_cache_section} here")
        self:assertEquals(flags.use_analyze_cache, true, "Should set use_analyze_cache")
        self:assertEquals(flags.use_book_text, true, "Should cascade to use_book_text")
    end)

    self:test("inferOpenBookFlags does NOT cascade use_annotations from {analyze_cache}", function()
        local flags = Actions.inferOpenBookFlags("Use {analyze_cache_section} here")
        self:assertEquals(flags.use_annotations, nil, "Should NOT cascade to use_annotations")
    end)

    -- Test cascading for {summary_cache} (only book text, not annotations)
    print("\n--- inferOpenBookFlags() cascading for {summary_cache} ---")

    self:test("inferOpenBookFlags cascades use_book_text from {summary_cache}", function()
        local flags = Actions.inferOpenBookFlags("Use {summary_cache_section} here")
        self:assertEquals(flags.use_summary_cache, true, "Should set use_summary_cache")
        self:assertEquals(flags.use_book_text, true, "Should cascade to use_book_text")
    end)

    self:test("inferOpenBookFlags does NOT cascade use_annotations from {summary_cache}", function()
        local flags = Actions.inferOpenBookFlags("Use {summary_cache_section} here")
        self:assertEquals(flags.use_annotations, nil, "Should NOT cascade to use_annotations")
    end)

    -- Test multiple placeholders
    print("\n--- Multiple placeholders ---")

    self:test("inferOpenBookFlags handles multiple placeholders", function()
        local prompt = "At {reading_progress}, use {book_text_section} and {annotations_section}"
        local flags = Actions.inferOpenBookFlags(prompt)
        self:assertEquals(flags.use_reading_progress, true)
        self:assertEquals(flags.use_book_text, true)
        self:assertEquals(flags.use_annotations, true)
    end)

    -- Test X-Ray action has correct flags
    print("\n--- Built-in X-Ray action ---")

    self:test("X-Ray action has use_book_text", function()
        local xray = Actions.book.xray
        self:assert(xray, "X-Ray action should exist")
        self:assertEquals(xray.use_book_text, true)
    end)

    self:test("X-Ray action has use_annotations", function()
        local xray = Actions.book.xray
        self:assertEquals(xray.use_annotations, true)
    end)

    self:test("X-Ray action has cache_as_xray_cache", function()
        local xray = Actions.book.xray
        self:assertEquals(xray.cache_as_xray_cache, true)
    end)

    -- Summary
    print(string.format("\nResults: %d passed, %d failed\n", self.passed, self.failed))
    return self.failed == 0
end

-- Run tests if executed directly
if arg and arg[0] and arg[0]:match("test_actions%.lua$") then
    local success = TestActions:runAll()
    os.exit(success and 0 or 1)
end

return TestActions
