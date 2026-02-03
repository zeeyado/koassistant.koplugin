-- Unit tests for web search features across providers
-- Tests request building, response parsing, and streaming detection
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
        print(string.format("  %d passed, %d failed (of %d total)", self.passed, self.failed, total))
    end
    return self.failed == 0
end

print("")
print(string.rep("=", 50))
print("  Unit Tests: Web Search (Multi-Provider)")
print(string.rep("=", 50))

-- Load modules under test
local ResponseParser = require("koassistant_api.response_parser")
local StreamHandler = require("stream_handler")
local ModelConstraints = require("model_constraints")

--------------------------------------------------------------------------------
-- Test: Response Parser - OpenAI web_search_used detection
--------------------------------------------------------------------------------

TestRunner:suite("Response Parser: OpenAI web_search_used")

TestRunner:test("detects web_search in tool_calls with type", function()
    local response = {
        choices = {
            {
                message = {
                    content = "Here's the latest news...",
                    tool_calls = {
                        { type = "web_search" }
                    }
                }
            }
        }
    }
    local success, content, reasoning, web_search_used = ResponseParser:parseResponse(response, "openai")
    TestRunner:assertTrue(success, "success")
    TestRunner:assertEqual(content, "Here's the latest news...", "content")
    TestRunner:assertTrue(web_search_used, "web_search_used should be true")
end)

TestRunner:test("detects web_search in tool_calls with function.name", function()
    local response = {
        choices = {
            {
                message = {
                    content = "Search results...",
                    tool_calls = {
                        { ["function"] = { name = "web_search" } }
                    }
                }
            }
        }
    }
    local success, content, reasoning, web_search_used = ResponseParser:parseResponse(response, "openai")
    TestRunner:assertTrue(success, "success")
    TestRunner:assertTrue(web_search_used, "web_search_used should be true")
end)

TestRunner:test("returns nil web_search_used when no tool_calls", function()
    local response = {
        choices = {
            {
                message = { content = "Normal response" }
            }
        }
    }
    local success, content, reasoning, web_search_used = ResponseParser:parseResponse(response, "openai")
    TestRunner:assertTrue(success, "success")
    TestRunner:assertNil(web_search_used, "web_search_used should be nil")
end)

TestRunner:test("returns nil web_search_used for other tool types", function()
    local response = {
        choices = {
            {
                message = {
                    content = "Code result",
                    tool_calls = {
                        { type = "code_interpreter" }
                    }
                }
            }
        }
    }
    local success, content, reasoning, web_search_used = ResponseParser:parseResponse(response, "openai")
    TestRunner:assertTrue(success, "success")
    TestRunner:assertNil(web_search_used, "web_search_used should be nil for non-web-search tools")
end)

--------------------------------------------------------------------------------
-- Test: Response Parser - xAI web_search_used detection
--------------------------------------------------------------------------------

TestRunner:suite("Response Parser: xAI web_search_used (live_search)")

TestRunner:test("detects live_search in tool_calls (xAI native format)", function()
    local response = {
        choices = {
            {
                message = {
                    content = "Grok found this...",
                    tool_calls = {
                        { type = "live_search" }
                    }
                }
            }
        }
    }
    local success, content, reasoning, web_search_used = ResponseParser:parseResponse(response, "xai")
    TestRunner:assertTrue(success, "success")
    TestRunner:assertEqual(content, "Grok found this...", "content")
    TestRunner:assertTrue(web_search_used, "web_search_used should be true for live_search")
end)

TestRunner:test("also detects web_search for backwards compatibility", function()
    local response = {
        choices = {
            {
                message = {
                    content = "Grok found this...",
                    tool_calls = {
                        { type = "web_search" }
                    }
                }
            }
        }
    }
    local success, content, reasoning, web_search_used = ResponseParser:parseResponse(response, "xai")
    TestRunner:assertTrue(success, "success")
    TestRunner:assertTrue(web_search_used, "web_search_used should be true")
end)

TestRunner:test("returns nil web_search_used when no tool_calls", function()
    local response = {
        choices = {
            {
                message = { content = "Normal Grok response" }
            }
        }
    }
    local success, content, reasoning, web_search_used = ResponseParser:parseResponse(response, "xai")
    TestRunner:assertTrue(success, "success")
    TestRunner:assertNil(web_search_used, "web_search_used should be nil")
end)

--------------------------------------------------------------------------------
-- Test: Streaming Parser - Web search marker detection
--------------------------------------------------------------------------------

TestRunner:suite("Streaming Parser: Web search detection")

TestRunner:test("detects live_search tool_call in delta (xAI format)", function()
    local event = {
        choices = {
            {
                delta = {
                    tool_calls = {
                        { type = "live_search" }
                    }
                }
            }
        }
    }
    local content, reasoning = StreamHandler:extractContentFromSSE(event)
    TestRunner:assertEqual(content, "__WEB_SEARCH_START__", "should return marker for live_search")
end)

TestRunner:test("detects web_search tool_call in delta (type field)", function()
    local event = {
        choices = {
            {
                delta = {
                    tool_calls = {
                        { type = "web_search" }
                    }
                }
            }
        }
    }
    local content, reasoning = StreamHandler:extractContentFromSSE(event)
    TestRunner:assertEqual(content, "__WEB_SEARCH_START__", "should return marker")
end)

TestRunner:test("detects web_search tool_call in delta (function.name)", function()
    local event = {
        choices = {
            {
                delta = {
                    tool_calls = {
                        { ["function"] = { name = "web_search" } }
                    }
                }
            }
        }
    }
    local content, reasoning = StreamHandler:extractContentFromSSE(event)
    TestRunner:assertEqual(content, "__WEB_SEARCH_START__", "should return marker")
end)

TestRunner:test("returns content normally when no tool_calls", function()
    local event = {
        choices = {
            {
                delta = { content = "Hello" }
            }
        }
    }
    local content, reasoning = StreamHandler:extractContentFromSSE(event)
    TestRunner:assertEqual(content, "Hello", "should return content")
end)

TestRunner:test("returns nil for non-web-search tool_calls", function()
    local event = {
        choices = {
            {
                delta = {
                    tool_calls = {
                        { type = "code_interpreter" }
                    }
                }
            }
        }
    }
    local content, reasoning = StreamHandler:extractContentFromSSE(event)
    TestRunner:assertNil(content, "should return nil for other tools")
end)

--------------------------------------------------------------------------------
-- Test: Streaming Parser - Gemini grounding detection
--------------------------------------------------------------------------------

TestRunner:suite("Streaming Parser: Gemini grounding detection")

TestRunner:test("detects groundingMetadata without content (Gemini format)", function()
    local event = {
        candidates = {
            {
                groundingMetadata = {
                    webSearchQueries = { "test query" }
                }
                -- No content parts
            }
        }
    }
    local content, reasoning = StreamHandler:extractContentFromSSE(event)
    TestRunner:assertEqual(content, "__WEB_SEARCH_START__", "should return marker for grounding")
end)

TestRunner:test("returns content when groundingMetadata present with content", function()
    -- When grounding metadata comes with content, prioritize content to not lose text
    local event = {
        candidates = {
            {
                groundingMetadata = {
                    webSearchQueries = { "test query" }
                },
                content = {
                    parts = {
                        { text = "Here is the search result" }
                    }
                }
            }
        }
    }
    local content, reasoning = StreamHandler:extractContentFromSSE(event)
    -- Should return content (not marker) to preserve text
    TestRunner:assertEqual(content, "Here is the search result", "should return content when both present")
end)

TestRunner:test("detects groundingMetadata with empty parts array", function()
    local event = {
        candidates = {
            {
                groundingMetadata = {
                    groundingChunks = { { url = "https://example.com" } }
                },
                content = {
                    parts = {}  -- Empty parts array
                }
            }
        }
    }
    local content, reasoning = StreamHandler:extractContentFromSSE(event)
    TestRunner:assertEqual(content, "__WEB_SEARCH_START__", "should return marker for empty parts")
end)

TestRunner:test("returns content normally without groundingMetadata", function()
    local event = {
        candidates = {
            {
                content = {
                    parts = {
                        { text = "Normal Gemini response" }
                    }
                }
            }
        }
    }
    local content, reasoning = StreamHandler:extractContentFromSSE(event)
    TestRunner:assertEqual(content, "Normal Gemini response", "should return content normally")
end)

--------------------------------------------------------------------------------
-- Test: Model Constraints - Web search capability
--------------------------------------------------------------------------------

TestRunner:suite("Model Constraints: Web search capability")

-- Note: OpenAI does NOT support web_search in Chat Completions API
TestRunner:test("OpenAI does NOT have web_search capability", function()
    local supports = ModelConstraints.supportsCapability("openai", "gpt-4o", "web_search")
    TestRunner:assertFalse(supports, "OpenAI should NOT have web_search capability")
end)

-- Note: xAI web search requires Responses API which is not Chat Completions compatible
-- The Chat Completions API deprecated web search on Feb 20, 2026 (410 Gone)
TestRunner:test("xAI does NOT have web_search capability (API deprecated)", function()
    local supports = ModelConstraints.supportsCapability("xai", "grok-4", "web_search")
    TestRunner:assertFalse(supports, "xAI should NOT have web_search (deprecated)")
end)

TestRunner:test("Gemini supports google_search", function()
    local supports = ModelConstraints.supportsCapability("gemini", "gemini-2.5-pro", "google_search")
    TestRunner:assertTrue(supports, "gemini-2.5-pro should support google_search")
end)

TestRunner:test("Unknown provider returns false", function()
    local supports = ModelConstraints.supportsCapability("unknown", "model", "web_search")
    TestRunner:assertFalse(supports, "unknown provider should return false")
end)

TestRunner:test("Unknown capability returns false", function()
    local supports = ModelConstraints.supportsCapability("openai", "gpt-4o", "unknown_capability")
    TestRunner:assertFalse(supports, "unknown capability should return false")
end)

--------------------------------------------------------------------------------
-- Test: OpenRouter :online suffix
--------------------------------------------------------------------------------

TestRunner:suite("OpenRouter: :online suffix")

-- Load OpenRouter handler
local OpenRouterHandler = require("openrouter")

TestRunner:test("appends :online suffix when web search enabled", function()
    local body = { model = "anthropic/claude-3-opus" }
    local config = { features = { enable_web_search = true } }
    local result = OpenRouterHandler:customizeRequestBody(body, config)
    TestRunner:assertEqual(result.model, "anthropic/claude-3-opus:online", "model should have :online suffix")
end)

TestRunner:test("does not append :online when web search disabled", function()
    local body = { model = "anthropic/claude-3-opus" }
    local config = { features = { enable_web_search = false } }
    local result = OpenRouterHandler:customizeRequestBody(body, config)
    TestRunner:assertEqual(result.model, "anthropic/claude-3-opus", "model should not have :online suffix")
end)

TestRunner:test("does not double-append :online", function()
    local body = { model = "anthropic/claude-3-opus:online" }
    local config = { features = { enable_web_search = true } }
    local result = OpenRouterHandler:customizeRequestBody(body, config)
    TestRunner:assertEqual(result.model, "anthropic/claude-3-opus:online", "should not double-append")
end)

TestRunner:test("per-action override takes precedence over global", function()
    local body = { model = "openai/gpt-4" }
    local config = {
        enable_web_search = true,  -- per-action override
        features = { enable_web_search = false }  -- global setting
    }
    local result = OpenRouterHandler:customizeRequestBody(body, config)
    TestRunner:assertEqual(result.model, "openai/gpt-4:online", "per-action should override global")
end)

TestRunner:test("per-action false overrides global true", function()
    local body = { model = "openai/gpt-4" }
    local config = {
        enable_web_search = false,  -- per-action override
        features = { enable_web_search = true }  -- global setting
    }
    local result = OpenRouterHandler:customizeRequestBody(body, config)
    TestRunner:assertEqual(result.model, "openai/gpt-4", "per-action false should override")
end)

TestRunner:test("skips :online for models without / (invalid format)", function()
    -- OpenRouter models should be in format "provider/model"
    -- If model is just "custom" or similar, skip the :online suffix
    local body = { model = "custom" }
    local config = { features = { enable_web_search = true } }
    local result = OpenRouterHandler:customizeRequestBody(body, config)
    TestRunner:assertEqual(result.model, "custom", "should NOT append :online to invalid model format")
end)

TestRunner:test("skips :online for nil model", function()
    local body = { model = nil }
    local config = { features = { enable_web_search = true } }
    local result = OpenRouterHandler:customizeRequestBody(body, config)
    TestRunner:assertNil(result.model, "should handle nil model")
end)

--------------------------------------------------------------------------------
-- Test: xAI web search NOT supported (API deprecated Feb 20, 2026)
-- xAI requires Responses API for web search, not Chat Completions
--------------------------------------------------------------------------------

TestRunner:suite("xAI: web search NOT supported (deprecated)")

-- Load xAI handler
local XAIHandler = require("xai")

TestRunner:test("does not add tools (no customizeRequestBody override)", function()
    -- xAI handler no longer overrides customizeRequestBody
    -- So body passes through unchanged
    local body = { model = "grok-4" }
    local config = { features = { enable_web_search = true } }
    local result = XAIHandler:customizeRequestBody(body, config)
    TestRunner:assertNil(result.tools, "tools should NOT be added (API deprecated)")
end)

--------------------------------------------------------------------------------
-- Test: OpenAI - No web search support
-- Note: OpenAI Chat Completions API does NOT support native web search.
-- Web search requires function calling with external tools, which we don't implement.
--------------------------------------------------------------------------------

TestRunner:suite("OpenAI: web search NOT supported")

-- Load OpenAI handler
local OpenAIHandler = require("openai")

TestRunner:test("does not add tools even when web search enabled", function()
    local messages = {}
    local config = {
        api_key = "test-key",
        model = "gpt-4o",
        features = { enable_web_search = true }
    }
    local result = OpenAIHandler:buildRequestBody(messages, config)
    -- OpenAI Chat Completions API doesn't support native web search
    TestRunner:assertNil(result.body.tools, "tools should NOT be added for OpenAI")
end)

--------------------------------------------------------------------------------
-- Test: OpenAI-compatible base handler web_search_used propagation
--------------------------------------------------------------------------------

TestRunner:suite("OpenAI-compatible: web_search_used propagation")

-- Create a test handler that uses the OpenAI-compatible base
local function createTestCompatibleHandler()
    local OpenAICompatibleHandler = require("openai_compatible")
    local TestHandler = OpenAICompatibleHandler:new()
    function TestHandler:getProviderName() return "TestProvider" end
    function TestHandler:getProviderKey() return "xai" end  -- Use xai parser which has web_search detection
    return TestHandler
end

-- Note: Full integration test would require mocking https.request
-- These tests verify the handler is correctly configured

TestRunner:test("handler uses xai parser key which detects web_search", function()
    local handler = createTestCompatibleHandler()
    TestRunner:assertEqual(handler:getResponseParserKey(), "xai", "parser key should be xai")
end)

TestRunner:test("xai response parser returns web_search_used as 4th value", function()
    local response = {
        choices = {
            {
                message = {
                    content = "Test",
                    tool_calls = {{ type = "web_search" }}
                }
            }
        }
    }
    local success, content, reasoning, web_search_used = ResponseParser:parseResponse(response, "xai")
    TestRunner:assertTrue(success, "parse success")
    TestRunner:assertTrue(web_search_used, "web_search_used should be returned as 4th value")
end)

--------------------------------------------------------------------------------
-- Test: OpenRouter web_search_used detection via annotations
--------------------------------------------------------------------------------

TestRunner:suite("Response Parser: OpenRouter web_search_used (annotations)")

TestRunner:test("detects url_citation in annotations (OpenRouter/Exa format)", function()
    local response = {
        choices = {
            {
                message = {
                    content = "Here's what I found from web search...",
                    annotations = {
                        { type = "url_citation", url = "https://example.com", title = "Example" }
                    }
                }
            }
        }
    }
    local success, content, reasoning, web_search_used = ResponseParser:parseResponse(response, "openrouter")
    TestRunner:assertTrue(success, "success")
    TestRunner:assertEqual(content, "Here's what I found from web search...", "content")
    TestRunner:assertTrue(web_search_used, "web_search_used should be true for url_citation")
end)

TestRunner:test("returns nil web_search_used when no annotations", function()
    local response = {
        choices = {
            {
                message = { content = "Normal OpenRouter response" }
            }
        }
    }
    local success, content, reasoning, web_search_used = ResponseParser:parseResponse(response, "openrouter")
    TestRunner:assertTrue(success, "success")
    TestRunner:assertNil(web_search_used, "web_search_used should be nil when no annotations")
end)

TestRunner:test("returns nil web_search_used for non-url_citation annotations", function()
    local response = {
        choices = {
            {
                message = {
                    content = "Response with other annotation type",
                    annotations = {
                        { type = "other_type", data = "some data" }
                    }
                }
            }
        }
    }
    local success, content, reasoning, web_search_used = ResponseParser:parseResponse(response, "openrouter")
    TestRunner:assertTrue(success, "success")
    TestRunner:assertNil(web_search_used, "web_search_used should be nil for non-url_citation")
end)

--------------------------------------------------------------------------------
-- Test: Streaming Parser - OpenRouter annotations detection
--------------------------------------------------------------------------------

TestRunner:suite("Streaming Parser: OpenRouter annotations detection")

TestRunner:test("detects url_citation annotation in delta (OpenRouter format)", function()
    local event = {
        choices = {
            {
                delta = {
                    annotations = {
                        { type = "url_citation", url = "https://example.com" }
                    }
                }
            }
        }
    }
    local content, reasoning = StreamHandler:extractContentFromSSE(event)
    TestRunner:assertEqual(content, "__WEB_SEARCH_START__", "should return marker for url_citation")
end)

TestRunner:test("returns content normally when no annotations in delta", function()
    local event = {
        choices = {
            {
                delta = { content = "Normal streaming content" }
            }
        }
    }
    local content, reasoning = StreamHandler:extractContentFromSSE(event)
    TestRunner:assertEqual(content, "Normal streaming content", "should return content")
end)

--------------------------------------------------------------------------------
-- Summary
--------------------------------------------------------------------------------

local success = TestRunner:summary()
return success
