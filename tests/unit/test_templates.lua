--[[
Unit Tests for prompts/templates.lua and nudge substitution

Tests template resolution, nudge constants, variable building,
and end-to-end nudge substitution through MessageBuilder.

Priority 1: catches the nudge-not-populating bug class.

Run: lua tests/run_tests.lua --unit
]]

-- Setup test environment
local function setupPaths()
    local info = debug.getinfo(1, "S")
    local script_path = info.source:match("@?(.*)")
    local unit_dir = script_path:match("(.+)/[^/]+$") or "."
    local tests_dir = unit_dir:match("(.+)/[^/]+$") or "."
    local plugin_dir = tests_dir:match("(.+)/[^/]+$") or "."

    package.path = table.concat({
        plugin_dir .. "/?.lua",
        plugin_dir .. "/?/init.lua",
        tests_dir .. "/?.lua",
        tests_dir .. "/lib/?.lua",
        package.path,
    }, ";")
end
setupPaths()

require("mock_koreader")

local Templates = require("prompts.templates")
local MessageBuilder = require("message_builder")
local Actions = require("prompts.actions")

-- Test suite
local TestRunner = {
    passed = 0,
    failed = 0,
}

function TestRunner:test(name, fn)
    local ok, err = pcall(fn)
    if ok then
        self.passed = self.passed + 1
        print(string.format("  \226\156\147 %s", name))
    else
        self.failed = self.failed + 1
        print(string.format("  \226\156\151 %s: %s", name, tostring(err)))
    end
end

function TestRunner:assertEqual(actual, expected, message)
    if actual ~= expected then
        error(string.format("%s: expected '%s', got '%s'",
            message or "Values not equal",
            tostring(expected),
            tostring(actual)), 2)
    end
end

function TestRunner:assertContains(str, substring, message)
    if not str or not str:find(substring, 1, true) then
        error(string.format("%s: '%s' not found in '%s'",
            message or "Substring not found",
            substring,
            (str or "nil"):sub(1, 100) .. ((str and #str > 100) and "..." or "")), 2)
    end
end

function TestRunner:assertNotContains(str, substring, message)
    if str and str:find(substring, 1, true) then
        error(string.format("%s: '%s' should not be in '%s'",
            message or "Unexpected substring found",
            substring,
            str:sub(1, 100) .. (#str > 100 and "..." or "")), 2)
    end
end

function TestRunner:assertNotNil(value, message)
    if value == nil then
        error(string.format("%s: expected non-nil value", message or "Assertion failed"), 2)
    end
end

function TestRunner:assertNil(value, message)
    if value ~= nil then
        error(string.format("%s: expected nil, got '%s'", message or "Assertion failed", tostring(value)), 2)
    end
end

function TestRunner:assertType(value, expected_type, message)
    if type(value) ~= expected_type then
        error(string.format("%s: expected type '%s', got '%s'",
            message or "Type mismatch", expected_type, type(value)), 2)
    end
end

-- =============================================================================
-- Template Constants Tests
-- =============================================================================

local function runConstantTests()
    print("\n--- Template Constants ---")

    TestRunner:test("CONCISENESS_NUDGE is a non-empty string", function()
        TestRunner:assertType(Templates.CONCISENESS_NUDGE, "string")
        if Templates.CONCISENESS_NUDGE == "" then
            error("CONCISENESS_NUDGE is empty")
        end
    end)

    TestRunner:test("HALLUCINATION_NUDGE is a non-empty string", function()
        TestRunner:assertType(Templates.HALLUCINATION_NUDGE, "string")
        if Templates.HALLUCINATION_NUDGE == "" then
            error("HALLUCINATION_NUDGE is empty")
        end
    end)

    TestRunner:test("CONCISENESS_NUDGE does not contain curly braces", function()
        TestRunner:assertNotContains(Templates.CONCISENESS_NUDGE, "{", "Should not contain {")
    end)

    TestRunner:test("HALLUCINATION_NUDGE does not contain curly braces", function()
        TestRunner:assertNotContains(Templates.HALLUCINATION_NUDGE, "{", "Should not contain {")
    end)
end

-- =============================================================================
-- Templates.get() Tests
-- =============================================================================

local function runGetTests()
    print("\n--- Templates.get() ---")

    TestRunner:test("resolves 'explain' template", function()
        local result = Templates.get("explain")
        TestRunner:assertNotNil(result, "explain template")
        TestRunner:assertContains(result, "Explain", "contains Explain")
    end)

    TestRunner:test("resolves 'book_info' template", function()
        local result = Templates.get("book_info")
        TestRunner:assertNotNil(result, "book_info template")
        TestRunner:assertContains(result, "{title}", "contains {title}")
    end)

    TestRunner:test("resolves 'compare_books' template", function()
        local result = Templates.get("compare_books")
        TestRunner:assertNotNil(result, "compare_books template")
        TestRunner:assertContains(result, "{count}", "contains {count}")
    end)

    TestRunner:test("returns nil for unknown template", function()
        local result = Templates.get("nonexistent_template_xyz")
        TestRunner:assertNil(result, "unknown returns nil")
    end)

    TestRunner:test("returns nil for nil template_id", function()
        local result = Templates.get(nil)
        TestRunner:assertNil(result, "nil returns nil")
    end)
end

-- =============================================================================
-- Templates.substitute() Tests
-- =============================================================================

local function runSubstituteTests()
    print("\n--- Templates.substitute() ---")

    TestRunner:test("basic replacement", function()
        local result = Templates.substitute("Hello {name}", { name = "World" })
        TestRunner:assertEqual(result, "Hello World")
    end)

    TestRunner:test("multiple replacements", function()
        local result = Templates.substitute("{a} and {b}", { a = "X", b = "Y" })
        TestRunner:assertEqual(result, "X and Y")
    end)

    TestRunner:test("missing vars left as-is", function()
        local result = Templates.substitute("Hello {unknown}", {})
        TestRunner:assertEqual(result, "Hello {unknown}")
    end)

    TestRunner:test("empty vars replaced with empty string", function()
        local result = Templates.substitute("Hello {name}!", { name = "" })
        TestRunner:assertEqual(result, "Hello !")
    end)

    TestRunner:test("nil template returns empty string", function()
        local result = Templates.substitute(nil, { name = "test" })
        TestRunner:assertEqual(result, "")
    end)

    TestRunner:test("nil variables defaults to empty table", function()
        local result = Templates.substitute("Hello {name}", nil)
        TestRunner:assertEqual(result, "Hello {name}")
    end)
end

-- =============================================================================
-- Templates.buildVariables() Tests
-- =============================================================================

local function runBuildVariablesTests()
    print("\n--- Templates.buildVariables() ---")

    TestRunner:test("highlight context includes nudges", function()
        local vars = Templates.buildVariables("highlight", { highlighted_text = "test" })
        TestRunner:assertEqual(vars.conciseness_nudge, Templates.CONCISENESS_NUDGE)
        TestRunner:assertEqual(vars.hallucination_nudge, Templates.HALLUCINATION_NUDGE)
    end)

    TestRunner:test("book context includes nudges", function()
        local vars = Templates.buildVariables("book", { title = "Test" })
        TestRunner:assertEqual(vars.conciseness_nudge, Templates.CONCISENESS_NUDGE)
        TestRunner:assertEqual(vars.hallucination_nudge, Templates.HALLUCINATION_NUDGE)
    end)

    TestRunner:test("multi_book context includes nudges", function()
        local vars = Templates.buildVariables("multi_book", {})
        TestRunner:assertEqual(vars.conciseness_nudge, Templates.CONCISENESS_NUDGE)
        TestRunner:assertEqual(vars.hallucination_nudge, Templates.HALLUCINATION_NUDGE)
    end)

    TestRunner:test("highlight context includes highlighted_text", function()
        local vars = Templates.buildVariables("highlight", { highlighted_text = "selected" })
        TestRunner:assertEqual(vars.highlighted_text, "selected")
    end)

    TestRunner:test("highlight context builds author_clause", function()
        local vars = Templates.buildVariables("highlight", { author = "Tolkien" })
        TestRunner:assertContains(vars.author_clause, "Tolkien")
    end)

    TestRunner:test("highlight context empty author_clause when no author", function()
        local vars = Templates.buildVariables("highlight", { author = "" })
        TestRunner:assertEqual(vars.author_clause, "")
    end)

    TestRunner:test("book context includes title and author", function()
        local vars = Templates.buildVariables("book", { title = "Dune", author = "Herbert" })
        TestRunner:assertEqual(vars.title, "Dune")
        TestRunner:assertEqual(vars.author, "Herbert")
    end)

    TestRunner:test("multi_book context includes count and books_list", function()
        local books = {
            { title = "Book A", author = "Author 1" },
            { title = "Book B", author = "Author 2" },
        }
        local vars = Templates.buildVariables("multi_book", { books_info = books })
        TestRunner:assertEqual(vars.count, 2)
        TestRunner:assertContains(vars.books_list, "Book A")
    end)

    TestRunner:test("nil data defaults to empty", function()
        local vars = Templates.buildVariables("highlight", nil)
        TestRunner:assertEqual(vars.highlighted_text, "")
        TestRunner:assertEqual(vars.conciseness_nudge, Templates.CONCISENESS_NUDGE)
    end)
end

-- =============================================================================
-- Templates.renderForAction() Tests
-- =============================================================================

local function runRenderForActionTests()
    print("\n--- Templates.renderForAction() ---")

    TestRunner:test("resolves template field to prompt text", function()
        local action = { template = "explain" }
        local result = Templates.renderForAction(action, "highlight", { highlighted_text = "quantum" })
        TestRunner:assertContains(result, "quantum")
        -- Nudges should be resolved
        TestRunner:assertNotContains(result, "{conciseness_nudge}")
    end)

    TestRunner:test("returns empty for nil action", function()
        local result = Templates.renderForAction(nil, "highlight", {})
        TestRunner:assertEqual(result, "")
    end)

    TestRunner:test("returns empty for action without template", function()
        local result = Templates.renderForAction({ prompt = "direct prompt" }, "highlight", {})
        TestRunner:assertEqual(result, "")
    end)

    TestRunner:test("returns empty for unknown template", function()
        local result = Templates.renderForAction({ template = "nonexistent" }, "highlight", {})
        TestRunner:assertEqual(result, "")
    end)
end

-- =============================================================================
-- Nudge Substitution via MessageBuilder.build() Tests
-- =============================================================================

local function runBuildNudgeTests()
    print("\n--- Nudge substitution via MessageBuilder.build() ---")

    TestRunner:test("{conciseness_nudge} replaced in prompt via build()", function()
        local result = MessageBuilder.build({
            prompt = { prompt = "Explain this. {conciseness_nudge}" },
            context = "general",
            data = {},
        })
        TestRunner:assertNotContains(result, "{conciseness_nudge}")
        TestRunner:assertContains(result, Templates.CONCISENESS_NUDGE)
    end)

    TestRunner:test("{hallucination_nudge} replaced in prompt via build()", function()
        local result = MessageBuilder.build({
            prompt = { prompt = "Tell me. {hallucination_nudge}" },
            context = "general",
            data = {},
        })
        TestRunner:assertNotContains(result, "{hallucination_nudge}")
        TestRunner:assertContains(result, Templates.HALLUCINATION_NUDGE)
    end)

    TestRunner:test("both nudges replaced simultaneously", function()
        local result = MessageBuilder.build({
            prompt = { prompt = "{conciseness_nudge} and {hallucination_nudge}" },
            context = "general",
            data = {},
        })
        TestRunner:assertContains(result, Templates.CONCISENESS_NUDGE)
        TestRunner:assertContains(result, Templates.HALLUCINATION_NUDGE)
    end)
end

-- =============================================================================
-- Nudge Substitution via MessageBuilder.substituteVariables() Tests
-- =============================================================================

local function runSubstituteVariablesNudgeTests()
    print("\n--- Nudge substitution via MessageBuilder.substituteVariables() ---")

    TestRunner:test("{conciseness_nudge} replaced via substituteVariables()", function()
        local result = MessageBuilder.substituteVariables("Explain. {conciseness_nudge}", {})
        TestRunner:assertNotContains(result, "{conciseness_nudge}")
        TestRunner:assertContains(result, Templates.CONCISENESS_NUDGE)
    end)

    TestRunner:test("{hallucination_nudge} replaced via substituteVariables()", function()
        local result = MessageBuilder.substituteVariables("Tell me. {hallucination_nudge}", {})
        TestRunner:assertNotContains(result, "{hallucination_nudge}")
        TestRunner:assertContains(result, Templates.HALLUCINATION_NUDGE)
    end)
end

-- =============================================================================
-- Custom templates_getter Callback Tests
-- =============================================================================

local function runTemplatesGetterTests()
    print("\n--- templates_getter callback ---")

    TestRunner:test("custom getter called and result gets nudges substituted", function()
        local getter_called = false
        local custom_getter = function(template_name)
            getter_called = true
            if template_name == "my_template" then
                return "Custom template with {conciseness_nudge}"
            end
            return nil
        end
        local result = MessageBuilder.build({
            prompt = { template = "my_template" },
            context = "general",
            data = {},
            templates_getter = custom_getter,
        })
        if not getter_called then
            error("Custom getter was not called")
        end
        TestRunner:assertContains(result, Templates.CONCISENESS_NUDGE)
        TestRunner:assertNotContains(result, "{conciseness_nudge}")
    end)

    TestRunner:test("custom getter returning nil falls back gracefully", function()
        local custom_getter = function(_template_name)
            return nil
        end
        local result = MessageBuilder.build({
            prompt = { template = "unknown" },
            context = "general",
            data = {},
            templates_getter = custom_getter,
        })
        -- Should not crash, just have empty prompt area
        TestRunner:assertType(result, "string")
    end)
end

-- =============================================================================
-- Built-in Action Regression Tests
-- =============================================================================

local function runActionRegressionTests()
    print("\n--- Built-in action regression: no literal nudge placeholders after substitution ---")

    local contexts = {
        { name = "highlight", table = Actions.highlight },
        { name = "book", table = Actions.book },
        { name = "multi_book", table = Actions.multi_book },
        { name = "general", table = Actions.general },
        { name = "special", table = Actions.special },
    }

    for _, ctx in ipairs(contexts) do
        for action_id, action in pairs(ctx.table) do
            -- Get prompt text (either direct or via template)
            local prompt_text = action.prompt
            if not prompt_text and action.template then
                prompt_text = Templates.get(action.template)
            end

            if prompt_text then
                TestRunner:test(ctx.name .. "." .. action_id .. ": no literal {conciseness_nudge} after substitution", function()
                    local result = MessageBuilder.substituteVariables(prompt_text, {})
                    TestRunner:assertNotContains(result, "{conciseness_nudge}",
                        action_id .. " still has literal {conciseness_nudge}")
                end)

                TestRunner:test(ctx.name .. "." .. action_id .. ": no literal {hallucination_nudge} after substitution", function()
                    local result = MessageBuilder.substituteVariables(prompt_text, {})
                    TestRunner:assertNotContains(result, "{hallucination_nudge}",
                        action_id .. " still has literal {hallucination_nudge}")
                end)
            end
        end
    end
end

-- =============================================================================
-- Run All Tests
-- =============================================================================

local function runAll()
    print("\n=== Testing Templates & Nudge Substitution ===")

    runConstantTests()
    runGetTests()
    runSubstituteTests()
    runBuildVariablesTests()
    runRenderForActionTests()
    runBuildNudgeTests()
    runSubstituteVariablesNudgeTests()
    runTemplatesGetterTests()
    runActionRegressionTests()

    print(string.format("\n=== Results: %d passed, %d failed ===\n", TestRunner.passed, TestRunner.failed))
    return TestRunner.failed == 0
end

-- Run tests if executed directly
if arg and arg[0] and arg[0]:match("test_templates%.lua$") then
    local success = runAll()
    os.exit(success and 0 or 1)
end

return {
    runAll = runAll,
    TestRunner = TestRunner,
}
