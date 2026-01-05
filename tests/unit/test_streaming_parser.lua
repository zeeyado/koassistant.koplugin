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

-- Extract the content extraction function from stream_handler
-- This is the core parsing logic we want to test
local function extractContentFromSSE(event)
    -- OpenAI/DeepSeek format: choices[0].delta.content
    local choice = event.choices and event.choices[1]
    if choice then
        -- Check for actual stop reasons (not just truthy - JSON null can be truthy in some parsers)
        local finish = choice.finish_reason
        if finish and type(finish) == "string" and finish ~= "" then
            return nil  -- Stream complete
        end
        local delta = choice.delta
        if delta then
            return delta.content or delta.reasoning_content
        end
    end

    -- Anthropic format: delta.text
    local anthropic_delta = event.delta
    if anthropic_delta and anthropic_delta.text then
        return anthropic_delta.text
    end

    -- Anthropic message event: content[0].text
    local anthropic_content = event.content and event.content[1]
    if anthropic_content and anthropic_content.text then
        return anthropic_content.text
    end

    -- Gemini format: candidates[0].content.parts[0].text
    local gemini_candidate = event.candidates and event.candidates[1]
    if gemini_candidate then
        local parts = gemini_candidate.content and gemini_candidate.content.parts
        if parts and parts[1] and parts[1].text then
            return parts[1].text
        end
    end

    -- Ollama format: message.content (NDJSON streaming)
    local ollama_message = event.message
    if ollama_message and ollama_message.content then
        return ollama_message.content
    end

    return nil
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
TestRunner:suite("DeepSeek format")

TestRunner:test("extracts reasoning_content", function()
    local event = {
        choices = { { delta = { reasoning_content = "Let me think..." } } }
    }
    TestRunner:assertEqual(extractContentFromSSE(event), "Let me think...", "reasoning_content")
end)

TestRunner:test("prefers content over reasoning_content", function()
    local event = {
        choices = { { delta = { content = "Answer", reasoning_content = "Thinking" } } }
    }
    TestRunner:assertEqual(extractContentFromSSE(event), "Answer", "content preferred")
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
