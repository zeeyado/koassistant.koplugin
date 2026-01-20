-- Unit tests for SSE/NDJSON content extraction
-- Tests the extractContentFromSSE logic from stream_handler.lua
-- No API calls - pure logic testing with mock events

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

-- Import StreamHandler from plugin code (not hardcoded reimplementation)
local StreamHandler = require("stream_handler")

-- Wrapper function to call the method from StreamHandler
-- This ensures tests use actual plugin code, not duplicated logic
local function extractContentFromSSE(event)
    return StreamHandler:extractContentFromSSE(event)
end

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

function TestRunner:assertNil(value, msg)
    if value ~= nil then
        error(string.format("%s: expected nil, got %q", msg or "Assertion failed", tostring(value)))
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

print("")
print(string.rep("=", 50))
print("  Unit Tests: Streaming Parser (SSE/NDJSON)")
print(string.rep("=", 50))

-- Test OpenAI format
TestRunner:suite("OpenAI format")

TestRunner:test("extracts content from delta", function()
    local event = {
        choices = { { delta = { content = "Hello" } } }
    }
    TestRunner:assertEqual(extractContentFromSSE(event), "Hello", "delta.content")
end)

TestRunner:test("handles empty delta", function()
    local event = {
        choices = { { delta = {} } }
    }
    TestRunner:assertNil(extractContentFromSSE(event), "empty delta")
end)

TestRunner:test("returns nil on finish_reason=stop", function()
    local event = {
        choices = { { delta = {}, finish_reason = "stop" } }
    }
    TestRunner:assertNil(extractContentFromSSE(event), "finish_reason=stop")
end)

TestRunner:test("returns nil on finish_reason=length", function()
    local event = {
        choices = { { delta = {}, finish_reason = "length" } }
    }
    TestRunner:assertNil(extractContentFromSSE(event), "finish_reason=length")
end)

TestRunner:test("ignores empty string finish_reason", function()
    local event = {
        choices = { { delta = { content = "Hello" }, finish_reason = "" } }
    }
    TestRunner:assertEqual(extractContentFromSSE(event), "Hello", "empty finish_reason ignored")
end)

TestRunner:test("handles multiple chunks", function()
    local chunks = {
        { choices = { { delta = { content = "Hello" } } } },
        { choices = { { delta = { content = " " } } } },
        { choices = { { delta = { content = "World" } } } },
    }
    local result = ""
    for _, event in ipairs(chunks) do
        local content = extractContentFromSSE(event)
        if content then result = result .. content end
    end
    TestRunner:assertEqual(result, "Hello World", "multiple chunks")
end)

-- Test DeepSeek format (reasoning_content)
-- Note: extractContentFromSSE returns (content, reasoning_content) - two values
TestRunner:suite("DeepSeek format")

TestRunner:test("extracts reasoning_content as second return value", function()
    local event = {
        choices = { { delta = { reasoning_content = "Let me think..." } } }
    }
    local content, reasoning = extractContentFromSSE(event)
    TestRunner:assertNil(content, "content is nil when only reasoning present")
    TestRunner:assertEqual(reasoning, "Let me think...", "reasoning_content extracted")
end)

TestRunner:test("returns both content and reasoning when both present", function()
    local event = {
        choices = { { delta = { content = "Answer", reasoning_content = "Thinking" } } }
    }
    local content, reasoning = extractContentFromSSE(event)
    TestRunner:assertEqual(content, "Answer", "content extracted")
    TestRunner:assertEqual(reasoning, "Thinking", "reasoning also extracted")
end)

-- Test Anthropic format
TestRunner:suite("Anthropic format")

TestRunner:test("extracts delta.text", function()
    local event = {
        delta = { text = "Claude says" }
    }
    TestRunner:assertEqual(extractContentFromSSE(event), "Claude says", "delta.text")
end)

TestRunner:test("extracts content[0].text (message event)", function()
    local event = {
        content = { { text = "Full message" } }
    }
    TestRunner:assertEqual(extractContentFromSSE(event), "Full message", "content[0].text")
end)

TestRunner:test("handles empty delta", function()
    local event = {
        delta = {}
    }
    TestRunner:assertNil(extractContentFromSSE(event), "empty delta")
end)

-- Test Gemini format
TestRunner:suite("Gemini format")

TestRunner:test("extracts candidates[0].content.parts[0].text", function()
    local event = {
        candidates = {
            {
                content = {
                    parts = {
                        { text = "Gemini response" }
                    }
                }
            }
        }
    }
    TestRunner:assertEqual(extractContentFromSSE(event), "Gemini response", "gemini format")
end)

TestRunner:test("handles missing parts", function()
    local event = {
        candidates = {
            {
                content = {}
            }
        }
    }
    TestRunner:assertNil(extractContentFromSSE(event), "no parts")
end)

TestRunner:test("handles missing content", function()
    local event = {
        candidates = { {} }
    }
    TestRunner:assertNil(extractContentFromSSE(event), "no content")
end)

-- Test Ollama format (NDJSON)
TestRunner:suite("Ollama format (NDJSON)")

TestRunner:test("extracts message.content", function()
    local event = {
        message = { content = "Local model says" }
    }
    TestRunner:assertEqual(extractContentFromSSE(event), "Local model says", "message.content")
end)

TestRunner:test("handles done signal", function()
    local event = {
        message = { content = "" },
        done = true
    }
    -- Note: extractContentFromSSE doesn't check 'done', it returns empty string
    -- The caller checks 'done' separately
    TestRunner:assertEqual(extractContentFromSSE(event), "", "done signal returns empty")
end)

TestRunner:test("handles empty message", function()
    local event = {
        message = {}
    }
    TestRunner:assertNil(extractContentFromSSE(event), "empty message")
end)

-- Test edge cases
TestRunner:suite("Edge cases")

TestRunner:test("returns nil for empty event", function()
    local event = {}
    TestRunner:assertNil(extractContentFromSSE(event), "empty event")
end)

TestRunner:test("returns nil for unrecognized format", function()
    local event = {
        unknown_field = "something"
    }
    TestRunner:assertNil(extractContentFromSSE(event), "unrecognized format")
end)

TestRunner:test("handles nil event gracefully", function()
    -- This would error if we didn't handle nil - but it should be caught
    local ok = pcall(function()
        local _ = extractContentFromSSE(nil)
    end)
    -- We expect this to error (nil doesn't have .choices etc)
    if ok then
        error("Expected error for nil event")
    end
end)

-- Test JSON null handling (simulated)
TestRunner:suite("JSON null handling")

TestRunner:test("non-string finish_reason is ignored", function()
    -- In some JSON parsers, null is decoded as a special value
    -- We need to handle this case - only string "stop" should trigger completion
    local event = {
        choices = { { delta = { content = "Hello" }, finish_reason = false } }
    }
    TestRunner:assertEqual(extractContentFromSSE(event), "Hello", "false finish_reason")
end)

TestRunner:test("numeric finish_reason is ignored", function()
    local event = {
        choices = { { delta = { content = "Hello" }, finish_reason = 0 } }
    }
    TestRunner:assertEqual(extractContentFromSSE(event), "Hello", "numeric finish_reason")
end)

-- Summary
local success = TestRunner:summary()
return success
