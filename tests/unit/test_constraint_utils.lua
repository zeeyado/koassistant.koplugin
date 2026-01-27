--[[
Unit Tests for constraint_utils.lua

Tests the constraint utilities module to ensure:
- Temperature/reasoning defaults match plugin
- Constraint error parsing works correctly
- Retry config building handles constraints
- Capability checking delegates properly

Run: lua tests/run_tests.lua --unit
]]

-- Setup test environment
package.path = package.path .. ";./?.lua;./?/init.lua"
require("tests.lib.mock_koreader")

local ConstraintUtils = require("tests.lib.constraint_utils")
local ModelConstraints = require("model_constraints")

-- Test suite
local TestConstraintUtils = {
    passed = 0,
    failed = 0,
}

function TestConstraintUtils:test(name, fn)
    local ok, err = pcall(fn)
    if ok then
        self.passed = self.passed + 1
        print(string.format("  ✓ %s", name))
    else
        self.failed = self.failed + 1
        print(string.format("  ✗ %s: %s", name, tostring(err)))
    end
end

function TestConstraintUtils:assert(condition, message)
    if not condition then
        error(message or "Assertion failed", 2)
    end
end

function TestConstraintUtils:assertEquals(actual, expected, message)
    if actual ~= expected then
        error(string.format("%s: expected %s, got %s",
            message or "Values not equal",
            tostring(expected),
            tostring(actual)), 2)
    end
end

function TestConstraintUtils:runAll()
    print("\n=== Testing constraint_utils.lua ===\n")

    -- Test getMaxTemperature
    self:test("getMaxTemperature returns 1.0 for Anthropic", function()
        local max_temp = ConstraintUtils.getMaxTemperature("anthropic")
        self:assertEquals(max_temp, 1.0, "Anthropic max temp should be 1.0")
    end)

    self:test("getMaxTemperature returns 2.0 for OpenAI", function()
        local max_temp = ConstraintUtils.getMaxTemperature("openai")
        self:assertEquals(max_temp, 2.0, "OpenAI max temp should be 2.0")
    end)

    self:test("getMaxTemperature returns 2.0 for unknown provider", function()
        local max_temp = ConstraintUtils.getMaxTemperature("unknown_provider")
        self:assertEquals(max_temp, 2.0, "Unknown provider should default to 2.0")
    end)

    self:test("getMaxTemperature matches ModelConstraints", function()
        -- Verify it delegates to actual plugin code
        local constraint = ModelConstraints.anthropic._provider_max_temperature
        local utils_result = ConstraintUtils.getMaxTemperature("anthropic")
        self:assertEquals(utils_result, constraint,
            "Should match ModelConstraints value")
    end)

    -- Test getDefaultTemperature
    self:test("getDefaultTemperature returns number", function()
        local temp = ConstraintUtils.getDefaultTemperature("anthropic")
        self:assert(type(temp) == "number", "Should return a number")
        self:assert(temp >= 0 and temp <= 2, "Should be valid temperature")
    end)

    self:test("getDefaultTemperature has fallback", function()
        local temp = ConstraintUtils.getDefaultTemperature("unknown_provider")
        self:assertEquals(temp, 0.7, "Should fallback to 0.7")
    end)

    -- Test getReasoningDefaults
    self:test("getReasoningDefaults returns Anthropic config", function()
        local defaults = ConstraintUtils.getReasoningDefaults("anthropic")
        self:assert(type(defaults) == "table", "Should return table")
        self:assertEquals(type(defaults.budget), "number", "Should have budget")
        self:assertEquals(defaults.budget, 4096, "Budget should be 4096")
    end)

    self:test("getReasoningDefaults returns OpenAI config", function()
        local defaults = ConstraintUtils.getReasoningDefaults("openai")
        self:assert(type(defaults) == "table", "Should return table")
        self:assertEquals(defaults.effort, "medium", "Default effort should be medium")
    end)

    self:test("getReasoningDefaults returns nil for unsupported", function()
        local defaults = ConstraintUtils.getReasoningDefaults("ollama")
        self:assertEquals(defaults, nil, "Should return nil for unsupported provider")
    end)

    self:test("getReasoningDefaults matches ModelConstraints", function()
        local plugin_defaults = ModelConstraints.reasoning_defaults.anthropic
        local utils_defaults = ConstraintUtils.getReasoningDefaults("anthropic")
        self:assertEquals(utils_defaults.budget, plugin_defaults.budget,
            "Should match plugin defaults")
    end)

    -- Test supportsCapability
    self:test("supportsCapability detects Anthropic thinking", function()
        local supports = ConstraintUtils.supportsCapability(
            "anthropic", "claude-sonnet-4-5-20250929", "extended_thinking")
        self:assert(supports, "claude-sonnet-4-5 should support extended thinking")
    end)

    self:test("supportsCapability rejects non-thinking models", function()
        local supports = ConstraintUtils.supportsCapability(
            "anthropic", "claude-3-5-sonnet-20241022", "extended_thinking")
        self:assert(not supports, "claude-3-5-sonnet should NOT support extended thinking")
    end)

    self:test("supportsCapability detects OpenAI reasoning", function()
        local supports = ConstraintUtils.supportsCapability(
            "openai", "o3-mini", "reasoning")
        self:assert(supports, "o3-mini should support reasoning")
    end)

    -- Test parseConstraintError
    self:test("parseConstraintError detects temperature constraint", function()
        local constraint = ConstraintUtils.parseConstraintError(
            "Error: temperature must be 1.0 for this model")
        self:assert(constraint ~= nil, "Should detect constraint")
        self:assertEquals(constraint.type, "temperature")
        self:assertEquals(constraint.value, 1.0)
    end)

    self:test("parseConstraintError detects max_tokens constraint", function()
        local constraint = ConstraintUtils.parseConstraintError(
            "Error: max_tokens must be at least 16")
        self:assert(constraint ~= nil, "Should detect constraint")
        self:assertEquals(constraint.type, "max_tokens")
        self:assertEquals(constraint.value, 16)
    end)

    self:test("parseConstraintError detects multiple constraints", function()
        local constraint = ConstraintUtils.parseConstraintError(
            "Error: temperature and max_tokens are invalid")
        self:assert(constraint ~= nil, "Should detect constraint")
        self:assertEquals(constraint.type, "multiple")
    end)

    self:test("parseConstraintError returns nil for non-constraint", function()
        local constraint = ConstraintUtils.parseConstraintError(
            "Error: invalid API key")
        self:assertEquals(constraint, nil, "Should return nil for non-constraint error")
    end)

    self:test("parseConstraintError handles nil input", function()
        local constraint = ConstraintUtils.parseConstraintError(nil)
        self:assertEquals(constraint, nil, "Should handle nil gracefully")
    end)

    -- Test buildRetryConfig
    self:test("buildRetryConfig applies temperature fix", function()
        local orig_config = {
            api_params = { temperature = 0.7, max_tokens = 100 }
        }
        local constraint = { type = "temperature", value = 1.0 }
        local new_config = ConstraintUtils.buildRetryConfig(orig_config, constraint)

        self:assertEquals(new_config.api_params.temperature, 1.0,
            "Should update temperature")
        self:assertEquals(new_config.api_params.max_tokens, 100,
            "Should preserve other params")
    end)

    self:test("buildRetryConfig applies max_tokens fix", function()
        local orig_config = {
            api_params = { temperature = 0.7, max_tokens = 1 }
        }
        local constraint = { type = "max_tokens", value = 16 }
        local new_config = ConstraintUtils.buildRetryConfig(orig_config, constraint)

        self:assertEquals(new_config.api_params.max_tokens, 16,
            "Should update max_tokens")
        self:assertEquals(new_config.api_params.temperature, 0.7,
            "Should preserve temperature")
    end)

    self:test("buildRetryConfig applies multiple constraints fix", function()
        local orig_config = {
            api_params = { temperature = 0.5 }
        }
        local constraint = { type = "multiple" }
        local new_config = ConstraintUtils.buildRetryConfig(orig_config, constraint)

        self:assertEquals(new_config.api_params.temperature, 1.0,
            "Should set temp to 1.0")
        self:assertEquals(new_config.api_params.max_tokens, 256,
            "Should set max_tokens to 256")
    end)

    self:test("buildRetryConfig doesn't modify original", function()
        local orig_config = {
            api_params = { temperature = 0.7 }
        }
        local constraint = { type = "temperature", value = 1.0 }
        local new_config = ConstraintUtils.buildRetryConfig(orig_config, constraint)

        self:assertEquals(orig_config.api_params.temperature, 0.7,
            "Original should not be modified")
        self:assertEquals(new_config.api_params.temperature, 1.0,
            "New config should have updated value")
    end)

    -- Test applyConstraints
    self:test("applyConstraints delegates to ModelConstraints", function()
        local params = { temperature = 0.5, max_tokens = 100 }
        local new_params, adjustments = ConstraintUtils.applyConstraints(
            "anthropic", "claude-sonnet-4-5", params)

        -- Anthropic max temp is 1.0, so 0.5 should pass through
        -- But if temp was > 1.0, it would be adjusted
        self:assertEquals(type(new_params), "table", "Should return params")
        self:assertEquals(type(adjustments), "table", "Should return adjustments")
    end)

    -- Test getProviderCapabilities
    self:test("getProviderCapabilities returns table", function()
        local caps = ConstraintUtils.getProviderCapabilities("anthropic")
        self:assertEquals(type(caps), "table", "Should return table")
    end)

    self:test("getProviderCapabilities returns empty for unsupported", function()
        local caps = ConstraintUtils.getProviderCapabilities("unknown_provider")
        self:assertEquals(type(caps), "table", "Should return table")
        self:assert(next(caps) == nil, "Should be empty table")
    end)

    -- Summary
    print(string.format("\nResults: %d passed, %d failed\n", self.passed, self.failed))
    return self.failed == 0
end

-- Run tests if executed directly
if arg and arg[0] and arg[0]:match("test_constraint_utils%.lua$") then
    local success = TestConstraintUtils:runAll()
    os.exit(success and 0 or 1)
end

return TestConstraintUtils
