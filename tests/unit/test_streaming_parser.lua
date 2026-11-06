-- Unit tests for SSE/NDJSON content extraction
-- Tests the extractContentFromSSE logic from koassistant/request/stream_handler.lua
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
local StreamHandler = require("koassistant.request.stream_handler")

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

TestRunner:test("a chunk that carries finish_reason keeps its own text (the sweep of 2026-11-06)", function()
    -- a host that sends the last words with the stop (vLLM on "length",
    -- relays of Google's text + finishReason shape) lost them
    local c = extractContentFromSSE({ choices = { { delta = { content = "The last sentence." }, finish_reason = "stop" } } })
    TestRunner:assertEqual(c, "The last sentence.", "content with stop")
    c = extractContentFromSSE({ choices = { { delta = { content = "cut here" }, finish_reason = "length" } } })
    TestRunner:assertEqual(c, "cut here", "content with length")
    local c2, r = extractContentFromSSE({ choices = { { delta = { reasoning_content = "last thought" }, finish_reason = "length" } } })
    TestRunner:assertNil(c2, "no content")
    TestRunner:assertEqual(r, "last thought", "the reasoning with length")
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
    -- Note: extractContentFromSSE doesn't check 'done' (the caller does);
    -- empty content on the done event carries no displayable signal → nil
    TestRunner:assertNil(extractContentFromSSE(event), "done signal returns nil")
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

-- Issue #93: luajson decodes JSON null to a truthy function sentinel.
-- llama.cpp streams "content": null in its role-priming chunk; the sentinel
-- must not escape as content (downstream #content crashed KOReader).
local null_sentinel = function() end

TestRunner:test("null content sentinel returns nil (issue #93)", function()
    local event = {
        choices = { { delta = { role = "assistant", content = null_sentinel } } }
    }
    local content, reasoning = extractContentFromSSE(event)
    TestRunner:assertNil(content, "sentinel content dropped")
    TestRunner:assertNil(reasoning, "no reasoning")
end)

TestRunner:test("null reasoning sentinel dropped, content kept", function()
    local event = {
        choices = { { delta = { content = "Answer", reasoning_content = null_sentinel } } }
    }
    local content, reasoning = extractContentFromSSE(event)
    TestRunner:assertEqual(content, "Answer", "content survives sentinel reasoning")
    TestRunner:assertNil(reasoning, "sentinel reasoning dropped")
end)

TestRunner:test("null tool_calls/annotations sentinels don't crash", function()
    local event = {
        choices = { { delta = { content = "Hello", tool_calls = null_sentinel, annotations = null_sentinel } } }
    }
    TestRunner:assertEqual(extractContentFromSSE(event), "Hello", "content extracted past sentinels")
end)

TestRunner:test("null delta sentinel returns nil", function()
    local event = {
        choices = { { delta = null_sentinel } }
    }
    TestRunner:assertNil(extractContentFromSSE(event), "sentinel delta ignored")
end)

TestRunner:suite("Trailing API error detection (provider-shape-agnostic)")

-- An answer streamed, then the provider appended an error object and hung up.
local ANSWER = 'The first thing the stream said arrived intact.\n'

local SHAPES = {
    -- Gemini: `code` first — the ONLY shape the old '"error":{"code"' gate matched.
    { name = "Gemini 503",
      body = '{\n  "error": {\n    "code": 503,\n    "message": "This model is currently experiencing high demand.",\n    "status": "UNAVAILABLE"\n  }\n}' },
    -- OpenAI / OpenRouter: `message` first.
    { name = "OpenAI",
      body = '{"error":{"message":"The server had an error","type":"server_error","code":null}}' },
    { name = "OpenRouter",
      body = '{"error":{"message":"Upstream provider error","code":502}}' },
    -- Anthropic: sibling key BEFORE the error object.
    { name = "Anthropic overloaded",
      body = '{"type":"error","error":{"type":"overloaded_error","message":"Overloaded"}}' },
}

for _idx, shape in ipairs(SHAPES) do
    TestRunner:test("detects " .. shape.name, function()
        local buf = ANSWER .. shape.body
        local pos = StreamHandler._findTrailingApiError(buf)
        if not pos then error("no trailing error found in " .. shape.name) end
        -- The split must keep the whole answer and drop the whole error body.
        local before = buf:sub(1, pos - 1):match("^(.-)%s*$")
        TestRunner:assertEqual(before:sub(1, #ANSWER - 1), ANSWER:sub(1, #ANSWER - 1), "answer preserved")
        if before:find('"message"', 1, true) then error("error body leaked into the answer") end
        TestRunner:assertEqual(type(StreamHandler.extractApiError(buf)), "string", "message extractable")
    end)
end

TestRunner:test("clean answer has no trailing error", function()
    TestRunner:assertNil(StreamHandler._findTrailingApiError(ANSWER), "plain prose")
    TestRunner:assertNil(StreamHandler._findTrailingApiError(""), "empty")
    TestRunner:assertNil(StreamHandler._findTrailingApiError(nil), "nil")
end)

TestRunner:test("an answer DISCUSSING an error body is not truncated", function()
    -- The widened pattern's false-positive case: prose continues after the quoted
    -- object, so the rewrapped tail does not decode and the answer is left whole.
    local prose = 'A 503 looks like {"error": {"code": 503}} and you should retry it.'
    TestRunner:assertNil(StreamHandler._findTrailingApiError(prose), "quoted mid-sentence")
end)

TestRunner:test("skips a quoted object and finds the real trailing one", function()
    local buf = 'Errors look like {"error": {"code": 429}} in general.\n'
        .. '{"error":{"message":"Overloaded","code":503}}'
    local pos = StreamHandler._findTrailingApiError(buf)
    if not pos then error("real trailing error missed") end
    TestRunner:assertEqual(buf:sub(1, pos - 1):find("in general%.") ~= nil, true, "split after the prose")
end)

TestRunner:suite("Abnormal stop reasons on the wire")

TestRunner:test("abnormalStopReason reads every provider shape, ignores normal stops", function()
    local h = StreamHandler:new{}
    TestRunner:assertEqual(h:abnormalStopReason({ choices = { { finish_reason = "content_filter", delta = {} } } }),
        "content_filter", "openai")
    TestRunner:assertEqual(h:abnormalStopReason({ choices = { { finish_reason = "stop", delta = {} } } }),
        nil, "openai stop")
    TestRunner:assertEqual(h:abnormalStopReason({ type = "message_delta", delta = { stop_reason = "refusal" } }),
        "refusal", "anthropic")
    TestRunner:assertEqual(h:abnormalStopReason({ type = "message_delta", delta = { stop_reason = "end_turn" } }),
        nil, "anthropic end_turn")
    TestRunner:assertEqual(h:abnormalStopReason({ candidates = { { finishReason = "SAFETY", content = {} } } }),
        "SAFETY", "gemini")
    TestRunner:assertEqual(h:abnormalStopReason({ candidates = { { finishReason = "STOP" } } }),
        nil, "gemini STOP")
    TestRunner:assertEqual(h:abnormalStopReason({ promptFeedback = { blockReason = "SAFETY" } }),
        "prompt blocked: SAFETY", "gemini prompt block")
    TestRunner:assertEqual(h:abnormalStopReason({ choices = { { delta = { content = "x" } } } }),
        nil, "content chunk")
end)

-- Summary
local success = TestRunner:summary()
return success
