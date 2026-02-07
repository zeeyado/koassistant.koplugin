--[[
Unit Tests for action_service.lua

Tests pure functions: copyAction, getApiParams, migrateCustomActionsOpenBookFlags,
generateUniqueDuplicateName, createDuplicateAction.

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

local ActionService = require("action_service")
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
        error(string.format("%s: '%s' not found",
            message or "Substring not found",
            substring), 2)
    end
end

function TestRunner:assertNotNil(value, message)
    if value == nil then
        error(string.format("%s: expected non-nil", message or "Assertion failed"), 2)
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

-- Helper: create a mock settings object
local function createMockSettings(data)
    return {
        readSetting = function(_self, key) return data[key] end,
        saveSetting = function(_self, key, value) data[key] = value end,
        flush = function() end,
    }
end

-- Helper: create an ActionService with mock settings and initialized modules
local function createService(settings_data)
    settings_data = settings_data or {}
    local settings = createMockSettings(settings_data)
    local service = ActionService:new(settings)
    service.Actions = Actions
    -- Load Templates module
    local ok, Templates = pcall(require, "prompts.templates")
    if ok then service.Templates = Templates end
    return service
end

-- =============================================================================
-- copyAction() Tests
-- =============================================================================

local function runCopyActionTests()
    print("\n--- copyAction() ---")

    TestRunner:test("shallow copies primitive fields", function()
        local service = createService()
        local original = { id = "test", text = "Test", temperature = 0.5 }
        local copy = service:copyAction(original)
        TestRunner:assertEqual(copy.id, "test")
        TestRunner:assertEqual(copy.text, "Test")
        TestRunner:assertEqual(copy.temperature, 0.5)
    end)

    TestRunner:test("nested tables are copied (not shared ref)", function()
        local service = createService()
        local original = {
            id = "test",
            api_params = { temperature = 0.5, max_tokens = 1024 },
        }
        local copy = service:copyAction(original)
        -- Modify copy's nested table
        copy.api_params.temperature = 0.9
        -- Original should be unmodified
        TestRunner:assertEqual(original.api_params.temperature, 0.5, "original unmodified")
        TestRunner:assertEqual(copy.api_params.temperature, 0.9, "copy modified")
    end)

    TestRunner:test("original unmodified after copy changes", function()
        local service = createService()
        local original = { id = "test", text = "Original" }
        local copy = service:copyAction(original)
        copy.text = "Modified"
        TestRunner:assertEqual(original.text, "Original")
    end)

    TestRunner:test("copies reasoning_config table", function()
        local service = createService()
        local original = {
            id = "test",
            reasoning_config = {
                anthropic = { enabled = true, budget = 4096 },
            },
        }
        local copy = service:copyAction(original)
        TestRunner:assertNotNil(copy.reasoning_config)
        -- Note: copyAction only does one-level deep copy for tables
        TestRunner:assertNotNil(copy.reasoning_config.anthropic)
    end)
end

-- =============================================================================
-- getApiParams() Tests
-- =============================================================================

local function runGetApiParamsTests()
    print("\n--- getApiParams() ---")

    TestRunner:test("returns defaults when action has no api_params", function()
        local service = createService()
        local defaults = { temperature = 0.7, max_tokens = 1024 }
        local result = service:getApiParams({}, defaults)
        TestRunner:assertEqual(result.temperature, 0.7)
        TestRunner:assertEqual(result.max_tokens, 1024)
    end)

    TestRunner:test("action api_params override defaults", function()
        local service = createService()
        local defaults = { temperature = 0.7, max_tokens = 1024 }
        local action = { api_params = { temperature = 0.3 } }
        local result = service:getApiParams(action, defaults)
        TestRunner:assertEqual(result.temperature, 0.3)
        TestRunner:assertEqual(result.max_tokens, 1024)
    end)

    TestRunner:test("handles nil defaults", function()
        local service = createService()
        local action = { api_params = { temperature = 0.5 } }
        local result = service:getApiParams(action, nil)
        TestRunner:assertEqual(result.temperature, 0.5)
    end)

    TestRunner:test("handles nil action", function()
        local service = createService()
        local result = service:getApiParams(nil, { temperature = 0.7 })
        TestRunner:assertEqual(result.temperature, 0.7)
    end)

    TestRunner:test("handles action without api_params field", function()
        local service = createService()
        local result = service:getApiParams({ id = "test" }, { temperature = 0.7 })
        TestRunner:assertEqual(result.temperature, 0.7)
    end)
end

-- =============================================================================
-- migrateCustomActionsOpenBookFlags() Tests
-- =============================================================================

local function runMigrationTests()
    print("\n--- migrateCustomActionsOpenBookFlags() ---")

    TestRunner:test("infers safe flags from prompt text", function()
        local data = {
            custom_actions = {
                {
                    prompt = "At {reading_progress}, what's happening?",
                    context = "book",
                    text = "Progress check",
                },
            },
        }
        local service = createService(data)
        local migrated = service:migrateCustomActionsOpenBookFlags()
        TestRunner:assertEqual(migrated, true, "should migrate")
        TestRunner:assertEqual(data.custom_actions[1].use_reading_progress, true)
    end)

    TestRunner:test("does NOT infer double-gated flags (use_book_text)", function()
        local data = {
            custom_actions = {
                {
                    prompt = "Analyze {book_text_section}",
                    context = "book",
                    text = "Analyze",
                },
            },
        }
        local service = createService(data)
        service:migrateCustomActionsOpenBookFlags()
        -- use_book_text is double-gated, should NOT be auto-inferred
        TestRunner:assertNil(data.custom_actions[1].use_book_text, "should not infer use_book_text")
    end)

    TestRunner:test("does NOT infer double-gated flags (use_annotations)", function()
        local data = {
            custom_actions = {
                {
                    prompt = "Review {annotations_section}",
                    context = "book",
                    text = "Review",
                },
            },
        }
        local service = createService(data)
        service:migrateCustomActionsOpenBookFlags()
        TestRunner:assertNil(data.custom_actions[1].use_annotations, "should not infer use_annotations")
    end)

    TestRunner:test("does NOT infer double-gated flags (use_notebook)", function()
        local data = {
            custom_actions = {
                {
                    prompt = "Check {notebook_section}",
                    context = "book",
                    text = "Check notes",
                },
            },
        }
        local service = createService(data)
        service:migrateCustomActionsOpenBookFlags()
        TestRunner:assertNil(data.custom_actions[1].use_notebook, "should not infer use_notebook")
    end)

    TestRunner:test("skips actions that already have flags", function()
        local data = {
            custom_actions = {
                {
                    prompt = "At {reading_progress}, recap",
                    context = "book",
                    text = "Recap",
                    use_reading_progress = true,  -- Already has flag
                },
            },
        }
        local service = createService(data)
        local migrated = service:migrateCustomActionsOpenBookFlags()
        TestRunner:assertEqual(migrated, false, "should not migrate (already has flags)")
    end)

    TestRunner:test("returns false when no custom actions", function()
        local service = createService({})
        local migrated = service:migrateCustomActionsOpenBookFlags()
        TestRunner:assertEqual(migrated, false)
    end)

    TestRunner:test("infers use_reading_stats from {chapter_title}", function()
        local data = {
            custom_actions = {
                {
                    prompt = "Current chapter: {chapter_title}",
                    context = "book",
                    text = "Chapter info",
                },
            },
        }
        local service = createService(data)
        service:migrateCustomActionsOpenBookFlags()
        TestRunner:assertEqual(data.custom_actions[1].use_reading_stats, true)
    end)

    TestRunner:test("saves migrated actions to settings", function()
        local data = {
            custom_actions = {
                {
                    prompt = "At {reading_progress}",
                    context = "book",
                    text = "Progress",
                },
            },
        }
        local service = createService(data)
        service:migrateCustomActionsOpenBookFlags()
        -- saveSetting should have been called (data is mutated in place by mock)
        TestRunner:assertEqual(data.custom_actions[1].use_reading_progress, true)
    end)
end

-- =============================================================================
-- generateUniqueDuplicateName() Tests
-- =============================================================================

local function runDuplicateNameTests()
    print("\n--- generateUniqueDuplicateName() ---")

    TestRunner:test("appends ' Copy' when no collision", function()
        local service = createService({
            disabled_actions = {},
        })
        -- Initialize actions cache with no existing "Test Copy" action
        service.actions_cache = {
            highlight = { { text = "Test", id = "test" } },
            book = {},
            multi_book = {},
            general = {},
        }
        local result = service:generateUniqueDuplicateName("Test")
        TestRunner:assertEqual(result, "Test Copy")
    end)

    TestRunner:test("increments number on collision", function()
        local service = createService({
            disabled_actions = {},
        })
        service.actions_cache = {
            highlight = {
                { text = "Test", id = "test" },
                { text = "Test Copy", id = "test_copy" },
            },
            book = {},
            multi_book = {},
            general = {},
        }
        local result = service:generateUniqueDuplicateName("Test")
        TestRunner:assertEqual(result, "Test Copy (2)")
    end)

    TestRunner:test("finds next available number", function()
        local service = createService({
            disabled_actions = {},
        })
        service.actions_cache = {
            highlight = {
                { text = "Test", id = "test" },
                { text = "Test Copy", id = "test_copy" },
                { text = "Test Copy (2)", id = "test_copy2" },
            },
            book = {},
            multi_book = {},
            general = {},
        }
        local result = service:generateUniqueDuplicateName("Test")
        TestRunner:assertEqual(result, "Test Copy (3)")
    end)
end

-- =============================================================================
-- createDuplicateAction() Tests
-- =============================================================================

local function runCreateDuplicateTests()
    print("\n--- createDuplicateAction() ---")

    TestRunner:test("copies basic fields", function()
        local service = createService({ disabled_actions = {} })
        service.actions_cache = { highlight = {}, book = {}, multi_book = {}, general = {} }
        local action = {
            id = "explain",
            text = "Explain",
            context = "highlight",
            prompt = "Explain this: {highlighted_text}",
            skip_language_instruction = true,
            skip_domain = false,
        }
        local dup = service:createDuplicateAction(action)
        TestRunner:assertContains(dup.text, "Copy", "has Copy in name")
        TestRunner:assertEqual(dup.context, "highlight")
        TestRunner:assertEqual(dup.prompt, "Explain this: {highlighted_text}")
        TestRunner:assertEqual(dup.skip_language_instruction, true)
        TestRunner:assertEqual(dup.skip_domain, false)
    end)

    TestRunner:test("resolves template to prompt", function()
        local service = createService({ disabled_actions = {} })
        service.actions_cache = { highlight = {}, book = {}, multi_book = {}, general = {} }
        local action = {
            id = "explain",
            text = "Explain",
            context = "highlight",
            template = "explain",  -- Should be resolved to prompt text
        }
        local dup = service:createDuplicateAction(action)
        TestRunner:assertNotNil(dup.prompt, "template resolved to prompt")
        TestRunner:assertContains(dup.prompt, "Explain", "resolved template contains Explain")
        TestRunner:assertNil(dup.template, "template field not copied")
    end)

    TestRunner:test("excludes id, source, enabled", function()
        local service = createService({ disabled_actions = {} })
        service.actions_cache = { highlight = {}, book = {}, multi_book = {}, general = {} }
        local action = {
            id = "test",
            text = "Test",
            context = "highlight",
            source = "builtin",
            enabled = true,
            prompt = "test",
        }
        local dup = service:createDuplicateAction(action)
        TestRunner:assertNil(dup.id, "no id")
        TestRunner:assertNil(dup.source, "no source")
        TestRunner:assertNil(dup.enabled, "no enabled")
    end)

    TestRunner:test("copies context extraction flags", function()
        local service = createService({ disabled_actions = {} })
        service.actions_cache = { highlight = {}, book = {}, multi_book = {}, general = {} }
        local action = {
            id = "test",
            text = "Test",
            context = "book",
            prompt = "test",
            use_book_text = true,
            use_annotations = true,
            use_reading_progress = true,
        }
        local dup = service:createDuplicateAction(action)
        TestRunner:assertEqual(dup.use_book_text, true)
        TestRunner:assertEqual(dup.use_annotations, true)
        TestRunner:assertEqual(dup.use_reading_progress, true)
    end)

    TestRunner:test("copies temperature from api_params", function()
        local service = createService({ disabled_actions = {} })
        service.actions_cache = { highlight = {}, book = {}, multi_book = {}, general = {} }
        local action = {
            id = "test",
            text = "Test",
            context = "highlight",
            prompt = "test",
            api_params = { temperature = 0.3, max_tokens = 2048 },
        }
        local dup = service:createDuplicateAction(action)
        TestRunner:assertEqual(dup.temperature, 0.3)
        TestRunner:assertEqual(dup.max_tokens, 2048)
    end)

    TestRunner:test("copies view mode flags", function()
        local service = createService({ disabled_actions = {} })
        service.actions_cache = { highlight = {}, book = {}, multi_book = {}, general = {} }
        local action = {
            id = "test",
            text = "Test",
            context = "highlight",
            prompt = "test",
            compact_view = true,
            minimal_buttons = true,
        }
        local dup = service:createDuplicateAction(action)
        TestRunner:assertEqual(dup.compact_view, true)
        TestRunner:assertEqual(dup.minimal_buttons, true)
    end)

    TestRunner:test("copies reasoning_config", function()
        local service = createService({ disabled_actions = {} })
        service.actions_cache = { highlight = {}, book = {}, multi_book = {}, general = {} }
        local action = {
            id = "test",
            text = "Test",
            context = "highlight",
            prompt = "test",
            reasoning_config = {
                anthropic = { enabled = true },
            },
        }
        local dup = service:createDuplicateAction(action)
        TestRunner:assertNotNil(dup.reasoning_config)
    end)

    TestRunner:test("migrates use_highlights to use_annotations", function()
        local service = createService({ disabled_actions = {} })
        service.actions_cache = { highlight = {}, book = {}, multi_book = {}, general = {} }
        local action = {
            id = "test",
            text = "Test",
            context = "highlight",
            prompt = "test",
            use_highlights = true,  -- deprecated field
        }
        local dup = service:createDuplicateAction(action)
        TestRunner:assertEqual(dup.use_annotations, true, "use_highlights mapped to use_annotations")
    end)
end

-- =============================================================================
-- Run All Tests
-- =============================================================================

local function runAll()
    print("\n=== Testing ActionService ===")

    runCopyActionTests()
    runGetApiParamsTests()
    runMigrationTests()
    runDuplicateNameTests()
    runCreateDuplicateTests()

    print(string.format("\n=== Results: %d passed, %d failed ===\n", TestRunner.passed, TestRunner.failed))
    return TestRunner.failed == 0
end

-- Run tests if executed directly
if arg and arg[0] and arg[0]:match("test_action_service%.lua$") then
    local success = runAll()
    os.exit(success and 0 or 1)
end

return {
    runAll = runAll,
    TestRunner = TestRunner,
}
