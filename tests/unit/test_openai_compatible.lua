-- Unit tests for koassistant_api/openai_compatible.lua
-- Tests the OpenAI-compatible base handler class
-- No API calls - tests with mock data

-- Setup paths (detect script location)
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

    return plugin_dir, tests_dir
end

setupPaths()

-- Load mocks BEFORE any plugin modules
require("mock_koreader")

-- Simple test framework
local TestRunner = {
    passed = 0,
    failed = 0,
    current_suite = "",
}

function TestRunner:suite(name)
    self.current_suite = name
    print(string.format("\n  [%s]", name))
end

function TestRunner:test(name, fn)
    local ok, err = pcall(fn)
    if ok then
        self.passed = self.passed + 1
        print(string.format("    \226\156\147 %s", name))
    else
        self.failed = self.failed + 1
        print(string.format("    \226\156\151 %s", name))
        print(string.format("      Error: %s", tostring(err)))
    end
end

function TestRunner:assertEqual(actual, expected, msg)
    if actual ~= expected then
        error(string.format("%s: expected %q, got %q", msg or "Assertion failed", tostring(expected), tostring(actual)))
    end
end

function TestRunner:assertTrue(value, msg)
    if not value then
        error(string.format("%s: expected true", msg or "Assertion failed"))
    end
end

function TestRunner:assertFalse(value, msg)
    if value then
        error(string.format("%s: expected false", msg or "Assertion failed"))
    end
end

function TestRunner:assertNil(value, msg)
    if value ~= nil then
        error(string.format("%s: expected nil, got %q", msg or "Assertion failed", tostring(value)))
    end
end

function TestRunner:assertNotNil(value, msg)
    if value == nil then
        error(string.format("%s: expected non-nil value", msg or "Assertion failed"))
    end
end

function TestRunner:assertContains(str, pattern, msg)
    if not str or not str:find(pattern, 1, true) then
        error(string.format("%s: expected string to contain %q, got %q", msg or "Assertion failed", pattern, tostring(str)))
    end
end

function TestRunner:summary()
    print("")
    print(string.rep("-", 50))
    local total = self.passed + self.failed
    if self.failed == 0 then
        print(string.format("  All %d tests passed!", total))
    else
        print(string.format("  %d/%d tests passed, %d failed", self.passed, total, self.failed))
    end
    return self.failed == 0
end

-- Run tests
print("")
print(string.rep("=", 50))
print("  Unit Tests: OpenAI-Compatible Handler Base Class")
print(string.rep("=", 50))

-- Load the base handler
local OpenAICompatibleHandler = require("openai_compatible")

--------------------------------------------------------------------------------
-- Test: Abstract methods
--------------------------------------------------------------------------------

TestRunner:suite("Abstract methods")

TestRunner:test("getProviderName raises error if not implemented", function()
    local handler = OpenAICompatibleHandler:new()
    local ok, err = pcall(function() handler:getProviderName() end)
    TestRunner:assertFalse(ok, "should raise error")
    TestRunner:assertContains(err, "must be implemented", "error message")
end)

TestRunner:test("getProviderKey raises error if not implemented", function()
    local handler = OpenAICompatibleHandler:new()
    local ok, err = pcall(function() handler:getProviderKey() end)
    TestRunner:assertFalse(ok, "should raise error")
    TestRunner:assertContains(err, "must be implemented", "error message")
end)

--------------------------------------------------------------------------------
-- Test: Child class implementation
--------------------------------------------------------------------------------

TestRunner:suite("Child class implementation")

-- Create a minimal test handler
local function createTestHandler()
    local TestHandler = OpenAICompatibleHandler:new()
    function TestHandler:getProviderName() return "TestProvider" end
    function TestHandler:getProviderKey() return "test" end
    return TestHandler
end

TestRunner:test("child class can override getProviderName", function()
    local handler = createTestHandler()
    TestRunner:assertEqual(handler:getProviderName(), "TestProvider", "provider name")
end)

TestRunner:test("child class can override getProviderKey", function()
    local handler = createTestHandler()
    TestRunner:assertEqual(handler:getProviderKey(), "test", "provider key")
end)

--------------------------------------------------------------------------------
-- Test: Default hook behavior
--------------------------------------------------------------------------------

TestRunner:suite("Default hook behavior")

TestRunner:test("customizeHeaders returns headers unchanged", function()
    local handler = createTestHandler()
    local headers = { ["Content-Type"] = "application/json" }
    local result = handler:customizeHeaders(headers, {})
    TestRunner:assertEqual(result["Content-Type"], "application/json", "header preserved")
end)

TestRunner:test("customizeRequestBody returns body unchanged", function()
    local handler = createTestHandler()
    local body = { model = "test-model" }
    local result = handler:customizeRequestBody(body, {})
    TestRunner:assertEqual(result.model, "test-model", "body preserved")
end)

TestRunner:test("customizeUrl returns url unchanged", function()
    local handler = createTestHandler()
    local result = handler:customizeUrl("https://api.test.com", {})
    TestRunner:assertEqual(result, "https://api.test.com", "url preserved")
end)

TestRunner:test("validateConfig returns false without api_key", function()
    local handler = createTestHandler()
    local valid, err = handler:validateConfig({})
    TestRunner:assertFalse(valid, "should be invalid")
    TestRunner:assertContains(err, "Missing API key", "error message")
end)

TestRunner:test("validateConfig returns true with api_key", function()
    local handler = createTestHandler()
    local valid, err = handler:validateConfig({ api_key = "test-key" })
    TestRunner:assertTrue(valid, "should be valid")
    TestRunner:assertNil(err, "no error")
end)

TestRunner:test("enhanceErrorMessage returns message unchanged", function()
    local handler = createTestHandler()
    local result = handler:enhanceErrorMessage("Test error", {})
    TestRunner:assertEqual(result, "Test error", "error unchanged")
end)

TestRunner:test("supportsReasoningExtraction returns false by default", function()
    local handler = createTestHandler()
    TestRunner:assertFalse(handler:supportsReasoningExtraction(), "default false")
end)

TestRunner:test("getResponseParserKey returns provider key by default", function()
    local handler = createTestHandler()
    TestRunner:assertEqual(handler:getResponseParserKey(), "test", "uses provider key")
end)

--------------------------------------------------------------------------------
-- Test: Hook overrides
--------------------------------------------------------------------------------

TestRunner:suite("Hook overrides")

TestRunner:test("child can customize headers", function()
    local TestHandler = createTestHandler()
    function TestHandler:customizeHeaders(headers, config)
        headers["X-Custom"] = "value"
        return headers
    end
    local headers = { ["Content-Type"] = "application/json" }
    local result = TestHandler:customizeHeaders(headers, {})
    TestRunner:assertEqual(result["X-Custom"], "value", "custom header added")
end)

TestRunner:test("child can customize request body", function()
    local TestHandler = createTestHandler()
    function TestHandler:customizeRequestBody(body, config)
        body.custom_param = true
        return body
    end
    local body = { model = "test" }
    local result = TestHandler:customizeRequestBody(body, {})
    TestRunner:assertTrue(result.custom_param, "custom param added")
end)

TestRunner:test("child can customize URL", function()
    local TestHandler = createTestHandler()
    function TestHandler:customizeUrl(url, config)
        return "https://custom.api.com/v1"
    end
    local result = TestHandler:customizeUrl("https://original.com", {})
    TestRunner:assertEqual(result, "https://custom.api.com/v1", "url customized")
end)

TestRunner:test("child can customize validation", function()
    local TestHandler = createTestHandler()
    function TestHandler:validateConfig(config)
        if not config.base_url then
            return false, "Error: Missing base URL"
        end
        return true
    end
    local valid, err = TestHandler:validateConfig({ api_key = "test" })
    TestRunner:assertFalse(valid, "should fail without base_url")
    TestRunner:assertContains(err, "Missing base URL", "error message")
end)

TestRunner:test("child can enable reasoning extraction", function()
    local TestHandler = createTestHandler()
    function TestHandler:supportsReasoningExtraction() return true end
    TestRunner:assertTrue(TestHandler:supportsReasoningExtraction(), "enabled")
end)

TestRunner:test("child can override parser key", function()
    local TestHandler = createTestHandler()
    function TestHandler:getResponseParserKey() return "openai" end
    TestRunner:assertEqual(TestHandler:getResponseParserKey(), "openai", "overridden")
end)

--------------------------------------------------------------------------------
-- Test: buildRequestBody
--------------------------------------------------------------------------------

TestRunner:suite("buildRequestBody")

TestRunner:test("returns table with required fields", function()
    local handler = createTestHandler()
    local result = handler:buildRequestBody({}, { api_key = "test-key" })
    TestRunner:assertNotNil(result.body, "body exists")
    TestRunner:assertNotNil(result.headers, "headers exist")
    TestRunner:assertNotNil(result.url, "url exists")
    TestRunner:assertNotNil(result.model, "model exists")
    TestRunner:assertEqual(result.provider, "test", "provider key set")
end)

TestRunner:test("includes Authorization header", function()
    local handler = createTestHandler()
    local result = handler:buildRequestBody({}, { api_key = "my-secret-key" })
    TestRunner:assertEqual(result.headers["Authorization"], "Bearer my-secret-key", "auth header")
end)

TestRunner:test("includes system message when provided", function()
    local handler = createTestHandler()
    local config = {
        api_key = "test",
        system = { text = "You are helpful." }
    }
    local result = handler:buildRequestBody({}, config)
    TestRunner:assertEqual(#result.body.messages, 1, "one message")
    TestRunner:assertEqual(result.body.messages[1].role, "system", "system role")
    TestRunner:assertEqual(result.body.messages[1].content, "You are helpful.", "system content")
end)

TestRunner:test("filters empty messages", function()
    local handler = createTestHandler()
    local messages = {
        { role = "user", content = "Hello" },
        { role = "user", content = "" },
        { role = "user", content = "   " },
        { role = "assistant", content = "Hi there" },
    }
    local result = handler:buildRequestBody(messages, { api_key = "test" })
    -- Should have 2 messages (Hello and Hi there), empty/whitespace filtered
    TestRunner:assertEqual(#result.body.messages, 2, "two non-empty messages")
end)

TestRunner:test("maps roles correctly", function()
    local handler = createTestHandler()
    local messages = {
        { role = "user", content = "Hello" },
        { role = "assistant", content = "Hi" },
        { role = "human", content = "What?" },  -- Non-standard role
    }
    local result = handler:buildRequestBody(messages, { api_key = "test" })
    TestRunner:assertEqual(result.body.messages[1].role, "user", "user role")
    TestRunner:assertEqual(result.body.messages[2].role, "assistant", "assistant role")
    TestRunner:assertEqual(result.body.messages[3].role, "user", "non-standard becomes user")
end)

TestRunner:test("applies temperature from config", function()
    local handler = createTestHandler()
    local config = {
        api_key = "test",
        api_params = { temperature = 0.5 }
    }
    local result = handler:buildRequestBody({}, config)
    TestRunner:assertEqual(result.body.temperature, 0.5, "temperature from config")
end)

TestRunner:test("applies max_tokens from config", function()
    local handler = createTestHandler()
    local config = {
        api_key = "test",
        api_params = { max_tokens = 1000 }
    }
    local result = handler:buildRequestBody({}, config)
    TestRunner:assertEqual(result.body.max_tokens, 1000, "max_tokens from config")
end)

TestRunner:test("uses model from config", function()
    local handler = createTestHandler()
    local config = {
        api_key = "test",
        model = "custom-model"
    }
    local result = handler:buildRequestBody({}, config)
    TestRunner:assertEqual(result.body.model, "custom-model", "model from config")
    TestRunner:assertEqual(result.model, "custom-model", "model in result")
end)

TestRunner:test("uses base_url from config", function()
    local handler = createTestHandler()
    local config = {
        api_key = "test",
        base_url = "https://custom.api.com/v1"
    }
    local result = handler:buildRequestBody({}, config)
    TestRunner:assertEqual(result.url, "https://custom.api.com/v1", "url from config")
end)

TestRunner:test("calls customizeRequestBody hook", function()
    local TestHandler = createTestHandler()
    function TestHandler:customizeRequestBody(body, config)
        body.custom = "added"
        return body
    end
    local result = TestHandler:buildRequestBody({}, { api_key = "test" })
    TestRunner:assertEqual(result.body.custom, "added", "hook was called")
end)

TestRunner:test("calls customizeHeaders hook", function()
    local TestHandler = createTestHandler()
    function TestHandler:customizeHeaders(headers, config)
        headers["X-Custom"] = "header"
        return headers
    end
    local result = TestHandler:buildRequestBody({}, { api_key = "test" })
    TestRunner:assertEqual(result.headers["X-Custom"], "header", "hook was called")
end)

TestRunner:test("calls customizeUrl hook", function()
    local TestHandler = createTestHandler()
    function TestHandler:customizeUrl(url, config)
        return "https://overridden.com"
    end
    local result = TestHandler:buildRequestBody({}, { api_key = "test" })
    TestRunner:assertEqual(result.url, "https://overridden.com", "hook was called")
end)

--------------------------------------------------------------------------------
-- Summary
--------------------------------------------------------------------------------

local success = TestRunner:summary()
return success
