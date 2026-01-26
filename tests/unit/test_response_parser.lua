-- Unit tests for koassistant_api/response_parser.lua
-- Tests response parsing for all 16 providers
-- No API calls - tests with mock responses

-- Setup paths (detect script location)
local function setupPaths()
    local info = debug.getinfo(1, "S")
    local script_path = info.source:match("@?(.*)")
    local unit_dir = script_path:match("(.+)/[^/]+$") or "."
    local tests_dir = unit_dir:match("(.+)/[^/]+$") or "."
    local plugin_dir = tests_dir:match("(.+)/[^/]+$") or "."

    package.path = table.concat({
        plugin_dir .. "/?.lua",
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
        print(string.format("    ✓ %s", name))
    else
        self.failed = self.failed + 1
        print(string.format("    ✗ %s", name))
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
        print(string.format("  %d passed, %d failed (of %d total)", self.passed, self.failed, total))
    end
    return self.failed == 0
end

-- Load the module under test
local ResponseParser = require("koassistant_api.response_parser")

print("")
print(string.rep("=", 50))
print("  Unit Tests: Response Parser (16 Providers)")
print(string.rep("=", 50))

-- Test Anthropic format
TestRunner:suite("Anthropic")

TestRunner:test("parses successful response", function()
    local response = {
        content = { { text = "Hello from Claude" } }
    }
    local success, result = ResponseParser:parseResponse(response, "anthropic")
    TestRunner:assertTrue(success, "success")
    TestRunner:assertEqual(result, "Hello from Claude", "content")
end)

TestRunner:test("handles error response", function()
    local response = {
        type = "error",
        error = { message = "Rate limit exceeded" }
    }
    local success, result = ResponseParser:parseResponse(response, "anthropic")
    TestRunner:assertFalse(success, "success")
    TestRunner:assertEqual(result, "Rate limit exceeded", "error message")
end)

TestRunner:test("handles unexpected format", function()
    local response = { unexpected = "data" }
    local success, result = ResponseParser:parseResponse(response, "anthropic")
    TestRunner:assertFalse(success, "success")
    TestRunner:assertContains(result, "Unexpected response format", "error message")
end)

TestRunner:test("parses extended thinking response", function()
    -- Extended thinking puts thinking block first, text block second
    local response = {
        content = {
            { type = "thinking", thinking = "Let me think about this..." },
            { type = "text", text = "The answer is 391" }
        }
    }
    local success, result = ResponseParser:parseResponse(response, "anthropic")
    TestRunner:assertTrue(success, "success")
    TestRunner:assertEqual(result, "The answer is 391", "content")
end)

TestRunner:test("parses response with type field", function()
    -- Regular response with explicit type field
    local response = {
        content = { { type = "text", text = "Hello with type" } }
    }
    local success, result = ResponseParser:parseResponse(response, "anthropic")
    TestRunner:assertTrue(success, "success")
    TestRunner:assertEqual(result, "Hello with type", "content")
end)

-- Test OpenAI format
TestRunner:suite("OpenAI")

TestRunner:test("parses successful response", function()
    local response = {
        choices = { { message = { content = "Hello from GPT" } } }
    }
    local success, result = ResponseParser:parseResponse(response, "openai")
    TestRunner:assertTrue(success, "success")
    TestRunner:assertEqual(result, "Hello from GPT", "content")
end)

TestRunner:test("handles error response", function()
    local response = {
        error = { message = "Invalid API key", type = "invalid_request_error" }
    }
    local success, result = ResponseParser:parseResponse(response, "openai")
    TestRunner:assertFalse(success, "success")
    TestRunner:assertEqual(result, "Invalid API key", "error message")
end)

TestRunner:test("handles error with only type", function()
    local response = {
        error = { type = "rate_limit_error" }
    }
    local success, result = ResponseParser:parseResponse(response, "openai")
    TestRunner:assertFalse(success, "success")
    TestRunner:assertEqual(result, "rate_limit_error", "error type")
end)

-- Test Gemini format
TestRunner:suite("Gemini")

TestRunner:test("parses candidates format", function()
    local response = {
        candidates = {
            {
                content = {
                    parts = { { text = "Hello from Gemini" } }
                }
            }
        }
    }
    local success, result = ResponseParser:parseResponse(response, "gemini")
    TestRunner:assertTrue(success, "success")
    TestRunner:assertEqual(result, "Hello from Gemini", "content")
end)

TestRunner:test("parses direct text format", function()
    local response = { text = "Direct text response" }
    local success, result = ResponseParser:parseResponse(response, "gemini")
    TestRunner:assertTrue(success, "success")
    TestRunner:assertEqual(result, "Direct text response", "content")
end)

TestRunner:test("handles error response", function()
    local response = {
        error = { message = "Invalid request", code = "400" }
    }
    local success, result = ResponseParser:parseResponse(response, "gemini")
    TestRunner:assertFalse(success, "success")
    TestRunner:assertEqual(result, "Invalid request", "error message")
end)

TestRunner:test("handles MAX_TOKENS with no content", function()
    -- Gemini thinking models may hit MAX_TOKENS before generating any output
    local response = {
        candidates = {
            {
                content = { role = "model" },  -- No parts array
                finishReason = "MAX_TOKENS"
            }
        }
    }
    local success, result = ResponseParser:parseResponse(response, "gemini")
    TestRunner:assertFalse(success, "success")
    TestRunner:assertContains(result, "MAX_TOKENS", "error message mentions MAX_TOKENS")
end)

-- Test DeepSeek format
TestRunner:suite("DeepSeek")

TestRunner:test("parses successful response", function()
    local response = {
        choices = { { message = { content = "Hello from DeepSeek" } } }
    }
    local success, result = ResponseParser:parseResponse(response, "deepseek")
    TestRunner:assertTrue(success, "success")
    TestRunner:assertEqual(result, "Hello from DeepSeek", "content")
end)

-- Test Ollama format
TestRunner:suite("Ollama")

TestRunner:test("parses successful response", function()
    local response = {
        message = { content = "Hello from local Llama" }
    }
    local success, result = ResponseParser:parseResponse(response, "ollama")
    TestRunner:assertTrue(success, "success")
    TestRunner:assertEqual(result, "Hello from local Llama", "content")
end)

TestRunner:test("handles error response", function()
    local response = { error = "Model not found" }
    local success, result = ResponseParser:parseResponse(response, "ollama")
    TestRunner:assertFalse(success, "success")
    TestRunner:assertEqual(result, "Model not found", "error message")
end)

-- Test Cohere format (special case - v2 API)
TestRunner:suite("Cohere (v2 API)")

TestRunner:test("parses array content format", function()
    local response = {
        message = { content = { { text = "Hello from Command" } } }
    }
    local success, result = ResponseParser:parseResponse(response, "cohere")
    TestRunner:assertTrue(success, "success")
    TestRunner:assertEqual(result, "Hello from Command", "content")
end)

TestRunner:test("parses string content format", function()
    local response = {
        message = { content = "Direct string content" }
    }
    local success, result = ResponseParser:parseResponse(response, "cohere")
    TestRunner:assertTrue(success, "success")
    TestRunner:assertEqual(result, "Direct string content", "content")
end)

TestRunner:test("handles error response", function()
    local response = { error = "API error", message = "Rate limited" }
    local success, result = ResponseParser:parseResponse(response, "cohere")
    TestRunner:assertFalse(success, "success")
    TestRunner:assertEqual(result, "Rate limited", "error message")
end)

-- Test OpenAI-compatible providers
local openai_compatible = {
    "groq", "mistral", "xai", "openrouter", "qwen",
    "kimi", "together", "fireworks", "sambanova", "doubao"
}

TestRunner:suite("OpenAI-compatible providers")

for _, provider in ipairs(openai_compatible) do
    TestRunner:test(provider .. " parses successful response", function()
        local response = {
            choices = { { message = { content = "Hello from " .. provider } } }
        }
        local success, result = ResponseParser:parseResponse(response, provider)
        TestRunner:assertTrue(success, "success for " .. provider)
        TestRunner:assertEqual(result, "Hello from " .. provider, "content for " .. provider)
    end)

    TestRunner:test(provider .. " handles error response", function()
        local response = {
            error = { message = "Error from " .. provider }
        }
        local success, result = ResponseParser:parseResponse(response, provider)
        TestRunner:assertFalse(success, "error success for " .. provider)
        TestRunner:assertEqual(result, "Error from " .. provider, "error for " .. provider)
    end)
end

-- Test unknown provider
TestRunner:suite("Unknown provider")

TestRunner:test("returns error for unknown provider", function()
    local response = { content = "test" }
    local success, result = ResponseParser:parseResponse(response, "unknown_provider")
    TestRunner:assertFalse(success, "success")
    TestRunner:assertContains(result, "No response transformer", "error message")
end)

-- Test edge cases
TestRunner:suite("Edge cases")

TestRunner:test("handles nil response fields gracefully", function()
    local response = { choices = { {} } }  -- missing message
    local success, result = ResponseParser:parseResponse(response, "openai")
    TestRunner:assertFalse(success, "success")
end)

TestRunner:test("handles empty choices array", function()
    local response = { choices = {} }
    local success, result = ResponseParser:parseResponse(response, "openai")
    TestRunner:assertFalse(success, "success")
end)

TestRunner:test("handles nil content in Anthropic", function()
    local response = { content = {} }  -- empty array
    local success, result = ResponseParser:parseResponse(response, "anthropic")
    TestRunner:assertFalse(success, "success")
end)

-- Summary
local success = TestRunner:summary()
return success
