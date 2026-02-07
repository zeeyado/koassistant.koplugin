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

    self:test("X-Ray action has cache_as_xray", function()
        local xray = Actions.book.xray
        self:assertEquals(xray.cache_as_xray, true)
    end)

    -- ================================================================
    -- Actions.requiresOpenBook() tests
    -- ================================================================
    print("\n--- requiresOpenBook() ---")

    self:test("requiresOpenBook returns false for nil", function()
        self:assertEquals(Actions.requiresOpenBook(nil), false)
    end)

    self:test("requiresOpenBook returns false for action with no flags", function()
        self:assertEquals(Actions.requiresOpenBook({ id = "test", text = "Test" }), false)
    end)

    self:test("requiresOpenBook returns true for explicit requires_open_book", function()
        self:assertEquals(Actions.requiresOpenBook({ requires_open_book = true }), true)
    end)

    self:test("requiresOpenBook returns true for use_book_text", function()
        self:assertEquals(Actions.requiresOpenBook({ use_book_text = true }), true)
    end)

    self:test("requiresOpenBook returns true for use_reading_progress", function()
        self:assertEquals(Actions.requiresOpenBook({ use_reading_progress = true }), true)
    end)

    self:test("requiresOpenBook returns true for use_annotations", function()
        self:assertEquals(Actions.requiresOpenBook({ use_annotations = true }), true)
    end)

    self:test("requiresOpenBook returns true for use_reading_stats", function()
        self:assertEquals(Actions.requiresOpenBook({ use_reading_stats = true }), true)
    end)

    self:test("requiresOpenBook returns true for use_notebook", function()
        self:assertEquals(Actions.requiresOpenBook({ use_notebook = true }), true)
    end)

    -- ================================================================
    -- Actions.checkRequirements() tests
    -- ================================================================
    print("\n--- checkRequirements() ---")

    self:test("checkRequirements returns true for action with no requirements", function()
        self:assertEquals(Actions.checkRequirements({ id = "test" }, {}), true)
    end)

    self:test("checkRequirements filters open book action when has_open_book=false", function()
        local action = { use_book_text = true }
        self:assertEquals(Actions.checkRequirements(action, { has_open_book = false }), false)
    end)

    self:test("checkRequirements passes open book action when has_open_book=true", function()
        local action = { use_book_text = true }
        self:assertEquals(Actions.checkRequirements(action, { has_open_book = true }), true)
    end)

    self:test("checkRequirements passes open book action when has_open_book=nil (management)", function()
        local action = { use_book_text = true }
        self:assertEquals(Actions.checkRequirements(action, {}), true)
    end)

    self:test("checkRequirements requires=author fails when no author", function()
        self:assertEquals(Actions.checkRequirements({ requires = "author" }, {}), false)
    end)

    self:test("checkRequirements requires=author fails when empty author", function()
        self:assertEquals(Actions.checkRequirements({ requires = "author" }, { author = "" }), false)
    end)

    self:test("checkRequirements requires=author passes when author present", function()
        self:assertEquals(Actions.checkRequirements({ requires = "author" }, { author = "Tolkien" }), true)
    end)

    -- ================================================================
    -- Actions.getForContext() tests
    -- ================================================================
    print("\n--- getForContext() ---")

    self:test("getForContext('highlight') returns actions array", function()
        local result = Actions.getForContext("highlight")
        self:assert(type(result) == "table", "returns table")
        self:assert(#result > 0, "has actions")
    end)

    self:test("getForContext('book') returns actions", function()
        local result = Actions.getForContext("book")
        self:assert(#result > 0, "has actions")
        -- Verify xray is present
        local found = false
        for _, action in ipairs(result) do
            if action.id == "xray" then found = true break end
        end
        self:assert(found, "xray should be in book context")
    end)

    self:test("getForContext('multi_book') returns actions", function()
        local result = Actions.getForContext("multi_book")
        self:assert(#result > 0, "has actions")
    end)

    self:test("getForContext('general') returns actions", function()
        local result = Actions.getForContext("general")
        self:assert(#result > 0, "has actions")
    end)

    self:test("getForContext returns sorted by text", function()
        local result = Actions.getForContext("highlight")
        for i = 2, #result do
            self:assert((result[i-1].text or "") <= (result[i].text or ""),
                "should be sorted: " .. (result[i-1].text or "") .. " <= " .. (result[i].text or ""))
        end
    end)

    self:test("getForContext('highlight') includes special 'all' context actions", function()
        -- Check if any special action with context="all" or context="highlight" is included
        local result = Actions.getForContext("highlight")
        local special_count = 0
        for _, action in ipairs(result) do
            -- translate and dictionary actions are special actions with highlight context
            if action.id == "translate" or action.id == "quick_define" then
                special_count = special_count + 1
            end
        end
        self:assert(special_count > 0, "should include special actions")
    end)

    -- ================================================================
    -- Actions.getById() tests
    -- ================================================================
    print("\n--- getById() ---")

    self:test("getById finds highlight action", function()
        local action = Actions.getById("explain")
        self:assert(action ~= nil, "found explain")
        self:assertEquals(action.id, "explain")
    end)

    self:test("getById finds book action", function()
        local action = Actions.getById("xray")
        self:assert(action ~= nil, "found xray")
        self:assertEquals(action.id, "xray")
    end)

    self:test("getById finds multi_book action", function()
        local action = Actions.getById("compare_books")
        self:assert(action ~= nil, "found compare_books")
        self:assertEquals(action.id, "compare_books")
    end)

    self:test("getById finds special action", function()
        local action = Actions.getById("translate")
        self:assert(action ~= nil, "found translate")
        self:assertEquals(action.id, "translate")
    end)

    self:test("getById returns nil for unknown", function()
        local action = Actions.getById("nonexistent_action_xyz")
        self:assertEquals(action, nil)
    end)

    -- ================================================================
    -- Actions.getApiParams() tests
    -- ================================================================
    print("\n--- getApiParams() ---")

    self:test("getApiParams returns defaults when action has no api_params", function()
        local defaults = { temperature = 0.7, max_tokens = 1024 }
        local result = Actions.getApiParams({}, defaults)
        self:assertEquals(result.temperature, 0.7)
        self:assertEquals(result.max_tokens, 1024)
    end)

    self:test("getApiParams overrides with action api_params", function()
        local defaults = { temperature = 0.7, max_tokens = 1024 }
        local action = { api_params = { temperature = 0.3 } }
        local result = Actions.getApiParams(action, defaults)
        self:assertEquals(result.temperature, 0.3, "overridden")
        self:assertEquals(result.max_tokens, 1024, "preserved")
    end)

    self:test("getApiParams handles nil defaults", function()
        local action = { api_params = { temperature = 0.5 } }
        local result = Actions.getApiParams(action, nil)
        self:assertEquals(result.temperature, 0.5)
    end)

    self:test("getApiParams handles nil action", function()
        local result = Actions.getApiParams(nil, { temperature = 0.7 })
        self:assertEquals(result.temperature, 0.7)
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
