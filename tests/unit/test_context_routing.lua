--[[
Unit Tests for Action Context Routing

Tests that actions belong to correct contexts, input dialog defaults
are valid, library context is properly isolated, and open-book
filtering works correctly.

These tests would have caught the library context bug where
highlight actions were loaded instead of library ones.

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

local Actions = require("prompts.actions")
local ActionService = require("action_service")
local Constants = require("koassistant_constants")

-- ============================================================
-- Test Runner
-- ============================================================
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

function TestRunner:assertTrue(value, message)
    if not value then
        error(string.format("%s: expected true", message or "Assertion failed"), 2)
    end
end

function TestRunner:assertFalse(value, message)
    if value then
        error(string.format("%s: expected false, got '%s'", message or "Assertion failed", tostring(value)), 2)
    end
end

function TestRunner:assertNotNil(value, message)
    if value == nil then
        error(string.format("%s: expected non-nil", message or "Assertion failed"), 2)
    end
end

function TestRunner:assertGreaterThan(actual, threshold, message)
    if actual <= threshold then
        error(string.format("%s: expected > %d, got %d",
            message or "Value too small", threshold, actual), 2)
    end
end

-- ============================================================
-- Helpers
-- ============================================================

local function createMockSettings(data)
    return {
        readSetting = function(_self, key) return data[key] end,
        saveSetting = function(_self, key, value) data[key] = value end,
        flush = function() end,
    }
end

local function createService(settings_data)
    settings_data = settings_data or {}
    local settings = createMockSettings(settings_data)
    local service = ActionService:new(settings)
    service.Actions = Actions
    local ok, Templates = pcall(require, "prompts.templates")
    if ok then service.Templates = Templates end
    return service
end

-- Set of contexts that are compatible with "both" compound context
local BOTH_CONTEXTS = { highlight = true, book = true }

-- Map compound context to its constituent contexts
local function expandedContextsContain(context_value, target_context)
    local expanded = Constants.expandContext(context_value)
    for _, ctx in ipairs(expanded) do
        if ctx == target_context then return true end
    end
    return false
end

-- ============================================================
-- Tests: Context Expansion
-- ============================================================

print("\n  -- Context Expansion --")

TestRunner:test("expandContext('both') returns highlight and book", function()
    local result = Constants.expandContext("both")
    TestRunner:assertEqual(#result, 2, "Should expand to 2 contexts")
    TestRunner:assertEqual(result[1], "highlight", "First should be highlight")
    TestRunner:assertEqual(result[2], "book", "Second should be book")
end)

TestRunner:test("expandContext('book+general') returns book and general", function()
    local result = Constants.expandContext("book+general")
    TestRunner:assertEqual(#result, 2, "Should expand to 2 contexts")
    TestRunner:assertEqual(result[1], "book", "First should be book")
    TestRunner:assertEqual(result[2], "general", "Second should be general")
end)

TestRunner:test("expandContext('highlight') returns highlight only", function()
    local result = Constants.expandContext("highlight")
    TestRunner:assertEqual(#result, 1, "Should expand to 1 context")
    TestRunner:assertEqual(result[1], "highlight", "Should be highlight")
end)

TestRunner:test("expandContext('library') returns library only", function()
    local result = Constants.expandContext("library")
    TestRunner:assertEqual(#result, 1, "Should expand to 1 context")
    TestRunner:assertEqual(result[1], "library", "Should be library")
end)

-- ============================================================
-- Tests: Action Context Membership
-- ============================================================

print("\n  -- Action Context Membership --")

TestRunner:test("all highlight actions have compatible context", function()
    for id, action in pairs(Actions.highlight) do
        local compatible = expandedContextsContain(action.context, "highlight")
        TestRunner:assertTrue(compatible,
            "Highlight action '" .. id .. "' has incompatible context: " .. tostring(action.context))
    end
end)

TestRunner:test("all book actions have compatible context", function()
    for id, action in pairs(Actions.book) do
        local compatible = expandedContextsContain(action.context, "book")
        TestRunner:assertTrue(compatible,
            "Book action '" .. id .. "' has incompatible context: " .. tostring(action.context))
    end
end)

TestRunner:test("all library actions have context = 'library'", function()
    for id, action in pairs(Actions.library) do
        TestRunner:assertEqual(action.context, "library",
            "Library action '" .. id .. "' has wrong context: " .. tostring(action.context))
    end
end)

TestRunner:test("all general actions have compatible context", function()
    for id, action in pairs(Actions.general) do
        local compatible = expandedContextsContain(action.context, "general")
        TestRunner:assertTrue(compatible,
            "General action '" .. id .. "' has incompatible context: " .. tostring(action.context))
    end
end)

TestRunner:test("every action has a unique ID within its context table", function()
    for _, context_name in ipairs({"highlight", "book", "library", "general"}) do
        local seen = {}
        for id, action in pairs(Actions[context_name]) do
            -- The table key should match the action's id field
            TestRunner:assertEqual(action.id, id,
                context_name .. ": table key '" .. id .. "' != action.id '" .. tostring(action.id) .. "'")
            TestRunner:assertFalse(seen[id],
                context_name .. ": duplicate action ID '" .. id .. "'")
            seen[id] = true
        end
    end
end)

-- ============================================================
-- Tests: Library Isolation
-- ============================================================

print("\n  -- Library Isolation --")

TestRunner:test("library actions don't include highlight-only actions", function()
    for id, action in pairs(Actions.library) do
        TestRunner:assertFalse(action.context == "highlight",
            "Library action '" .. id .. "' has highlight context")
        TestRunner:assertFalse(action.context == "both",
            "Library action '" .. id .. "' has 'both' context")
    end
end)

TestRunner:test("library actions don't have open-book-only flags", function()
    for id, action in pairs(Actions.library) do
        TestRunner:assertFalse(action.use_surrounding_context,
            "Library action '" .. id .. "' has use_surrounding_context (requires open book)")
        TestRunner:assertFalse(action.use_reading_progress,
            "Library action '" .. id .. "' has use_reading_progress (requires open book)")
        TestRunner:assertFalse(action.use_book_text,
            "Library action '" .. id .. "' has use_book_text (requires open book)")
    end
end)

TestRunner:test("getAllActions('library') returns only library actions", function()
    local service = createService()
    service:loadActions()
    local actions = service:getAllActions("library", true, false)
    TestRunner:assertGreaterThan(#actions, 0, "Should have library actions")

    for _, action in ipairs(actions) do
        TestRunner:assertEqual(action.context, "library",
            "getAllActions('library') returned action '" .. action.id .. "' with context: " .. tostring(action.context))
    end
end)

TestRunner:test("getAllActions('highlight') returns no library actions", function()
    local service = createService()
    service:loadActions()
    local actions = service:getAllActions("highlight", true, true)

    for _, action in ipairs(actions) do
        TestRunner:assertFalse(action.context == "library",
            "getAllActions('highlight') returned library action: " .. action.id)
    end
end)

-- ============================================================
-- Tests: Input Dialog Context Routing
-- ============================================================

print("\n  -- Input Dialog Context Routing --")

TestRunner:test("input defaults for 'book' are valid book-context action IDs", function()
    local service = createService()
    service:loadActions()

    local defaults = service:getInputActions("book")
    TestRunner:assertGreaterThan(#defaults, 0, "Should have book input defaults")

    for _, action_id in ipairs(defaults) do
        local action = service:getAction("book", action_id)
        TestRunner:assertNotNil(action,
            "Book input default '" .. action_id .. "' not found in book context")
    end
end)

TestRunner:test("input defaults for 'highlight' are valid highlight-context action IDs", function()
    local service = createService()
    service:loadActions()

    local defaults = service:getInputActions("highlight")
    TestRunner:assertGreaterThan(#defaults, 0, "Should have highlight input defaults")

    for _, action_id in ipairs(defaults) do
        -- Highlight actions may also be in book context (via "both"), search all
        local action = service:getAction(nil, action_id)
        TestRunner:assertNotNil(action,
            "Highlight input default '" .. action_id .. "' not found in any context")
    end
end)

TestRunner:test("input defaults for 'library' are valid library-context action IDs", function()
    local service = createService()
    service:loadActions()

    local defaults = service:getInputActions("library")
    TestRunner:assertGreaterThan(#defaults, 0, "Should have library input defaults")

    for _, action_id in ipairs(defaults) do
        local action = service:getAction("library", action_id)
        TestRunner:assertNotNil(action,
            "Library input default '" .. action_id .. "' not found in library context")
    end
end)

TestRunner:test("input defaults for 'xray_chat' are valid highlight-context action IDs", function()
    local service = createService()
    service:loadActions()

    local defaults = service:getInputActions("xray_chat")
    TestRunner:assertGreaterThan(#defaults, 0, "Should have xray_chat input defaults")

    for _, action_id in ipairs(defaults) do
        -- xray_chat uses highlight context actions
        local action = service:getAction(nil, action_id)
        TestRunner:assertNotNil(action,
            "X-Ray chat input default '" .. action_id .. "' not found in any context")
    end
end)

TestRunner:test("library input actions don't include highlight-only action IDs", function()
    local service = createService()
    service:loadActions()

    local library_actions = service:getInputActions("library")
    -- Collect all highlight-only action IDs (context = "highlight", not "both")
    local highlight_only = {}
    for id, action in pairs(Actions.highlight) do
        if action.context == "highlight" then
            highlight_only[id] = true
        end
    end

    for _, action_id in ipairs(library_actions) do
        TestRunner:assertFalse(highlight_only[action_id],
            "Library input includes highlight-only action: " .. action_id)
    end
end)

TestRunner:test("book_filebrowser input actions don't require open book", function()
    local service = createService()
    service:loadActions()

    local fb_defaults = service:getInputActions("book_filebrowser")
    TestRunner:assertGreaterThan(#fb_defaults, 0, "Should have file browser defaults")

    for _, action_id in ipairs(fb_defaults) do
        local action = service:getAction(nil, action_id)
        if action then
            TestRunner:assertFalse(Actions.requiresOpenBook(action),
                "File browser default '" .. action_id .. "' requires open book")
        end
    end
end)

-- ============================================================
-- Tests: Open Book Filtering
-- ============================================================

print("\n  -- Open Book Filtering --")

TestRunner:test("getAllActions with has_open_book=false excludes open-book actions", function()
    local service = createService()
    service:loadActions()

    local without_book = service:getAllActions("book", true, false)
    local with_book = service:getAllActions("book", true, true)

    -- With book should have more or equal actions
    TestRunner:assertTrue(#with_book >= #without_book,
        "Open book should have >= actions than no book")

    -- Verify none of the no-book results require an open book
    for _, action in ipairs(without_book) do
        TestRunner:assertFalse(Actions.requiresOpenBook(action),
            "No-book action '" .. action.id .. "' requires open book")
    end
end)

TestRunner:test("actions with use_book_text require open book", function()
    -- Find an action with use_book_text and verify requiresOpenBook returns true
    local found = false
    for _, context_name in ipairs({"highlight", "book"}) do
        for id, action in pairs(Actions[context_name]) do
            if action.use_book_text then
                TestRunner:assertTrue(Actions.requiresOpenBook(action),
                    "Action '" .. id .. "' has use_book_text but requiresOpenBook is false")
                found = true
            end
        end
    end
    TestRunner:assertTrue(found, "Should find at least one action with use_book_text")
end)

TestRunner:test("actions with use_reading_progress require open book", function()
    local found = false
    for _, context_name in ipairs({"highlight", "book"}) do
        for id, action in pairs(Actions[context_name]) do
            if action.use_reading_progress then
                TestRunner:assertTrue(Actions.requiresOpenBook(action),
                    "Action '" .. id .. "' has use_reading_progress but requiresOpenBook is false")
                found = true
            end
        end
    end
    TestRunner:assertTrue(found, "Should find at least one action with use_reading_progress")
end)

-- ============================================================
-- Tests: Cross-Context Integrity
-- ============================================================

print("\n  -- Cross-Context Integrity --")

TestRunner:test("in_quick_actions actions are book-context", function()
    for _, context_name in ipairs({"highlight", "book", "library", "general"}) do
        for id, action in pairs(Actions[context_name]) do
            if action.in_quick_actions then
                local is_book = expandedContextsContain(action.context, "book")
                TestRunner:assertTrue(is_book,
                    "in_quick_actions action '" .. id .. "' has non-book context: " .. tostring(action.context))
            end
        end
    end
end)

TestRunner:test("in_reading_features actions are book-context", function()
    for _, context_name in ipairs({"highlight", "book", "library", "general"}) do
        for id, action in pairs(Actions[context_name]) do
            if action.in_reading_features then
                local is_book = expandedContextsContain(action.context, "book")
                TestRunner:assertTrue(is_book,
                    "in_reading_features action '" .. id .. "' has non-book context: " .. tostring(action.context))
            end
        end
    end
end)

TestRunner:test("in_file_browser actions don't require open book", function()
    for _, context_name in ipairs({"highlight", "book", "library", "general"}) do
        for id, action in pairs(Actions[context_name]) do
            if action.in_file_browser then
                TestRunner:assertFalse(Actions.requiresOpenBook(action),
                    "in_file_browser action '" .. id .. "' requires open book")
            end
        end
    end
end)

TestRunner:test("each context table has at least one action", function()
    for _, context_name in ipairs({"highlight", "book", "library", "general"}) do
        local count = 0
        for _ in pairs(Actions[context_name]) do
            count = count + 1
        end
        TestRunner:assertGreaterThan(count, 0,
            "Context '" .. context_name .. "' should have at least one action")
    end
end)

TestRunner:test("getInputActionObjects returns enabled actions with correct structure", function()
    local service = createService()
    service:loadActions()

    for _, ctx_name in ipairs({"book", "highlight", "library"}) do
        local objects = service:getInputActionObjects(ctx_name)
        for _, action in ipairs(objects) do
            TestRunner:assertNotNil(action.id,
                ctx_name .. ": input action object missing 'id'")
            TestRunner:assertNotNil(action.text,
                ctx_name .. ": input action object '" .. action.id .. "' missing 'text'")
            TestRunner:assertTrue(action.enabled,
                ctx_name .. ": input action object '" .. action.id .. "' not enabled")
        end
    end
end)

-- ============================================================
-- Summary
-- ============================================================

print(string.format("\n  Context Routing: %d passed, %d failed",
    TestRunner.passed, TestRunner.failed))

return TestRunner.failed == 0
