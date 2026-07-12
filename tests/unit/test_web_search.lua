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
-- Test: Response Parser - Gemini web_search_used detection (groundingMetadata)
--------------------------------------------------------------------------------

TestRunner:suite("Response Parser: Gemini web_search_used (groundingMetadata)")

TestRunner:test("detects webSearchQueries in groundingMetadata", function()
    local response = {
        candidates = {
            {
                content = { parts = { { text = "Search result..." } } },
                groundingMetadata = {
                    webSearchQueries = { "what is the weather" }
                }
            }
        }
    }
    local success, content, reasoning, web_search_used = ResponseParser:parseResponse(response, "gemini")
    TestRunner:assertTrue(success, "success")
    TestRunner:assertEqual(content, "Search result...", "content")
    TestRunner:assertTrue(web_search_used, "web_search_used should be true")
end)

TestRunner:test("detects groundingChunks in groundingMetadata", function()
    local response = {
        candidates = {
            {
                content = { parts = { { text = "Grounded response" } } },
                groundingMetadata = {
                    groundingChunks = { { web = { uri = "https://example.com" } } }
                }
            }
        }
    }
    local success, content, reasoning, web_search_used = ResponseParser:parseResponse(response, "gemini")
    TestRunner:assertTrue(success, "success")
    TestRunner:assertTrue(web_search_used, "web_search_used should be true for groundingChunks")
end)

TestRunner:test("returns nil web_search_used for empty groundingMetadata", function()
    -- When googleSearch tool is enabled but search wasn't performed
    local response = {
        candidates = {
            {
                content = { parts = { { text = "Normal response" } } },
                groundingMetadata = {}  -- Present but empty
            }
        }
    }
    local success, content, reasoning, web_search_used = ResponseParser:parseResponse(response, "gemini")
    TestRunner:assertTrue(success, "success")
    TestRunner:assertEqual(content, "Normal response", "content")
    TestRunner:assertNil(web_search_used, "web_search_used should be nil for empty metadata")
end)

TestRunner:test("returns nil web_search_used for empty arrays in groundingMetadata", function()
    local response = {
        candidates = {
            {
                content = { parts = { { text = "Normal response" } } },
                groundingMetadata = {
                    webSearchQueries = {},
                    groundingChunks = {}
                }
            }
        }
    }
    local success, content, reasoning, web_search_used = ResponseParser:parseResponse(response, "gemini")
    TestRunner:assertTrue(success, "success")
    TestRunner:assertNil(web_search_used, "web_search_used should be nil for empty arrays")
end)

TestRunner:test("returns nil web_search_used when no groundingMetadata", function()
    local response = {
        candidates = {
            {
                content = { parts = { { text = "Normal Gemini response" } } }
            }
        }
    }
    local success, content, reasoning, web_search_used = ResponseParser:parseResponse(response, "gemini")
    TestRunner:assertTrue(success, "success")
    TestRunner:assertNil(web_search_used, "web_search_used should be nil without metadata")
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

TestRunner:test("empty groundingMetadata does NOT trigger web search marker", function()
    -- When googleSearch tool is enabled but search wasn't used, metadata exists but is empty
    local event = {
        candidates = {
            {
                groundingMetadata = {}  -- Empty - no search was performed
            }
        }
    }
    local content, reasoning = StreamHandler:extractContentFromSSE(event)
    -- Should NOT return web search marker since no actual search results
    TestRunner:assertNil(content, "should return nil for empty groundingMetadata")
end)

TestRunner:test("groundingMetadata with empty arrays does NOT trigger web search marker", function()
    local event = {
        candidates = {
            {
                groundingMetadata = {
                    webSearchQueries = {},  -- Empty array
                    groundingChunks = {},   -- Empty array
                }
            }
        }
    }
    local content, reasoning = StreamHandler:extractContentFromSSE(event)
    TestRunner:assertNil(content, "should return nil for empty arrays in groundingMetadata")
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
    local supports = ModelConstraints.supportsCapability("gemini", "gemini-3.5-flash", "google_search")
    TestRunner:assertTrue(supports, "gemini-3.5-flash should support google_search")
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
-- Test: ModelConstraints.supportsWebSearch (UI gating source of truth)
--------------------------------------------------------------------------------

TestRunner:suite("Model Constraints: supportsWebSearch matrix")

-- Providers that support web search for ALL models
for _idx, p in ipairs({ "anthropic", "openrouter", "perplexity" }) do
    TestRunner:test(p .. " supports web search (any model)", function()
        TestRunner:assertTrue(
            ModelConstraints.supportsWebSearch(p, "any-model"),
            p .. " should support web search")
    end)
end

-- Gemini: only google_search-capable models
TestRunner:test("gemini-3.5-flash supports web search", function()
    TestRunner:assertTrue(
        ModelConstraints.supportsWebSearch("gemini", "gemini-3.5-flash"),
        "gemini-3.5-flash should support web search")
end)

TestRunner:test("gemini unsupported model does NOT support web search", function()
    TestRunner:assertFalse(
        ModelConstraints.supportsWebSearch("gemini", "gemini-2.0-flash"),
        "gemini-2.0-flash should NOT support web search")
end)

-- Providers WITHOUT web search (toggle is a no-op there) — root cause of issue #81
for _idx, p in ipairs({ "openai", "deepseek", "xai", "mistral", "groq",
                        "qwen", "kimi", "together", "fireworks", "sambanova",
                        "cohere", "doubao", "zai", "ollama", "requesty" }) do
    TestRunner:test(p .. " does NOT support web search", function()
        TestRunner:assertFalse(
            ModelConstraints.supportsWebSearch(p, "any-model"),
            p .. " should NOT support web search")
    end)
end

TestRunner:test("nil provider returns false", function()
    TestRunner:assertFalse(ModelConstraints.supportsWebSearch(nil, "x"),
        "nil provider should be false")
end)

TestRunner:test("getWebSearchProvidersLabel lists supported providers (single source)", function()
    local label = ModelConstraints.getWebSearchProvidersLabel()
    for _idx, name in ipairs({ "Anthropic", "Gemini", "Perplexity", "OpenRouter" }) do
        TestRunner:assertNotNil(label:find(name, 1, true), name .. " should appear in label")
    end
end)

--------------------------------------------------------------------------------
-- Test: Request building - supported providers DO inject web search
--------------------------------------------------------------------------------

TestRunner:suite("Request building: Anthropic web_search tool")

local AnthropicRequest = require("anthropic_request")

TestRunner:test("Anthropic adds web_search tool when enabled", function()
    local body = AnthropicRequest:build({
        model = "claude-sonnet-4-6",
        messages = { { role = "user", content = "hi" } },
        features = { enable_web_search = true },
    })
    TestRunner:assertNotNil(body.tools, "tools should be present")
    TestRunner:assertEqual(body.tools[1].type, "web_search_20250305", "web_search tool injected")
end)

TestRunner:test("Anthropic omits web_search tool when disabled", function()
    local body = AnthropicRequest:build({
        model = "claude-sonnet-4-6",
        messages = { { role = "user", content = "hi" } },
        features = { enable_web_search = false },
    })
    TestRunner:assertNil(body.tools, "tools should NOT be present")
end)

TestRunner:suite("Request building: Gemini grounding (gated)")

local GeminiHandler = require("gemini")

TestRunner:test("Gemini adds googleSearch for supported model", function()
    local result = GeminiHandler:buildRequestBody({ { role = "user", content = "hi" } }, {
        api_key = "test-key",
        model = "gemini-3.5-flash",
        api_params = {},
        features = { enable_web_search = true },
    })
    TestRunner:assertNotNil(result.body.tools, "tools should be present for capable model")
    TestRunner:assertNotNil(result.body.tools[1].googleSearch, "googleSearch grounding injected")
end)

TestRunner:test("Gemini skips grounding for unsupported model", function()
    local result = GeminiHandler:buildRequestBody({ { role = "user", content = "hi" } }, {
        api_key = "test-key",
        model = "gemini-2.0-flash",
        api_params = {},
        features = { enable_web_search = true },
    })
    TestRunner:assertNil(result.body.tools, "tools should NOT be present for unsupported model")
end)

--------------------------------------------------------------------------------
-- Test: Web search effort dial (report 3(a)) — per-provider wire mappings
--------------------------------------------------------------------------------

TestRunner:suite("Effort dial: Anthropic max_uses")

local AnthropicRequestDial = require("anthropic_request")

local function anthropicTools(features)
    local body = AnthropicRequestDial:build({
        model = "claude-sonnet-4-6",
        messages = { { role = "user", content = "hi" } },
        features = features,
    })
    return body.tools and body.tools[1]
end

TestRunner:test("default (standard) maps to max_uses 5", function()
    local tool = anthropicTools({ enable_web_search = true })
    TestRunner:assertEqual(tool.max_uses, 5)
end)

TestRunner:test("light maps to max_uses 2", function()
    local tool = anthropicTools({ enable_web_search = true, web_search_effort = "light" })
    TestRunner:assertEqual(tool.max_uses, 2)
end)

TestRunner:test("thorough maps to max_uses 10", function()
    local tool = anthropicTools({ enable_web_search = true, web_search_effort = "thorough" })
    TestRunner:assertEqual(tool.max_uses, 10)
end)

TestRunner:test("legacy web_search_max_uses wins over the dial", function()
    local tool = anthropicTools({ enable_web_search = true,
        web_search_effort = "light", web_search_max_uses = 7 })
    TestRunner:assertEqual(tool.max_uses, 7, "configuration.lua power-user value respected")
end)

TestRunner:suite("Effort dial: OpenRouter web plugin")

TestRunner:test("standard keeps the plain :online suffix, no plugins", function()
    local result = OpenRouterHandler:customizeRequestBody({ model = "openai/gpt-4" },
        { features = { enable_web_search = true, web_search_effort = "standard" } })
    TestRunner:assertEqual(result.model, "openai/gpt-4:online")
    TestRunner:assertNil(result.plugins)
end)

TestRunner:test("light uses the web plugin with max_results 3, no suffix", function()
    local result = OpenRouterHandler:customizeRequestBody({ model = "openai/gpt-4" },
        { features = { enable_web_search = true, web_search_effort = "light" } })
    TestRunner:assertEqual(result.model, "openai/gpt-4", "no :online when plugin used")
    TestRunner:assertEqual(result.plugins[1].id, "web")
    TestRunner:assertEqual(result.plugins[1].max_results, 3)
end)

TestRunner:test("thorough uses max_results 10 and strips a baked-in suffix", function()
    local result = OpenRouterHandler:customizeRequestBody({ model = "openai/gpt-4:online" },
        { features = { enable_web_search = true, web_search_effort = "thorough" } })
    TestRunner:assertEqual(result.model, "openai/gpt-4", "baked :online stripped")
    TestRunner:assertEqual(result.plugins[1].max_results, 10)
end)

TestRunner:test("web search off emits no plugins regardless of dial", function()
    local result = OpenRouterHandler:customizeRequestBody({ model = "openai/gpt-4" },
        { features = { enable_web_search = false, web_search_effort = "thorough" } })
    TestRunner:assertEqual(result.model, "openai/gpt-4")
    TestRunner:assertNil(result.plugins)
end)

TestRunner:suite("Effort dial: Perplexity search_context_size")

local PerplexityHandler = require("perplexity")

TestRunner:test("standard sends no web_search_options (API default)", function()
    local result = PerplexityHandler:customizeRequestBody({ model = "sonar-pro" },
        { features = { web_search_effort = "standard" } })
    TestRunner:assertNil(result.web_search_options)
end)

TestRunner:test("light sends search_context_size low", function()
    local result = PerplexityHandler:customizeRequestBody({ model = "sonar-pro" },
        { features = { web_search_effort = "light" } })
    TestRunner:assertEqual(result.web_search_options.search_context_size, "low")
end)

TestRunner:test("thorough sends search_context_size high", function()
    local result = PerplexityHandler:customizeRequestBody({ model = "sonar-pro" },
        { features = { web_search_effort = "thorough" } })
    TestRunner:assertEqual(result.web_search_options.search_context_size, "high")
end)

--------------------------------------------------------------------------------
-- Test: Web-search provenance (sources/queries in the web_search slot)
--------------------------------------------------------------------------------

TestRunner:suite("Response Parser: web-search provenance (sources/queries)")

TestRunner:test("Anthropic captures queries and result URLs", function()
    local response = {
        content = {
            { type = "server_tool_use", name = "web_search", input = { query = "moby dick reviews" } },
            { type = "web_search_tool_result", content = {
                { type = "web_search_result", url = "https://example.com/a", title = "Review A" },
                { type = "web_search_result", url = "https://example.com/b", title = "Review B" },
                { type = "web_search_result", url = "https://example.com/a", title = "Dup" },
            } },
            { type = "text", text = "The reviews say..." },
        },
    }
    local success, content, _r, prov = ResponseParser:parseResponse(response, "anthropic")
    TestRunner:assertTrue(success, "parse succeeds")
    TestRunner:assertEqual(content, "The reviews say...", "content extracted")
    TestRunner:assertEqual(type(prov), "table", "provenance table returned")
    TestRunner:assertTrue(prov.web_search, "web_search flag set")
    TestRunner:assertEqual(#prov.sources, 2, "sources deduped by URL")
    TestRunner:assertEqual(prov.sources[1].title, "Review A", "title captured")
    TestRunner:assertEqual(prov.queries[1], "moby dick reviews", "query captured")
end)

TestRunner:test("Anthropic search without result details collapses to true", function()
    local response = {
        content = {
            { type = "server_tool_use", name = "web_search" },
            { type = "text", text = "Answer." },
        },
    }
    local _s, _c, _r, prov = ResponseParser:parseResponse(response, "anthropic")
    TestRunner:assertEqual(prov, true, "bare true when no sources/queries captured")
end)

TestRunner:test("Gemini captures grounding chunks and queries", function()
    local response = {
        candidates = { {
            content = { parts = { { text = "Grounded answer" } } },
            groundingMetadata = {
                webSearchQueries = { "whale symbolism" },
                groundingChunks = {
                    { web = { uri = "https://g.example/1", title = "site-one.com" } },
                    { web = { uri = "https://g.example/2", title = "site-two.com" } },
                },
            },
        } },
    }
    local success, _c, _r, prov = ResponseParser:parseResponse(response, "gemini")
    TestRunner:assertTrue(success, "parse succeeds")
    TestRunner:assertEqual(type(prov), "table", "provenance table returned")
    TestRunner:assertEqual(#prov.sources, 2, "grounding chunks become sources")
    TestRunner:assertEqual(prov.sources[2].url, "https://g.example/2", "uri mapped to url")
    TestRunner:assertEqual(prov.queries[1], "whale symbolism", "search query captured")
end)

TestRunner:test("OpenRouter captures url_citation annotations", function()
    local response = {
        choices = { { message = {
            content = "Cited answer",
            annotations = {
                { type = "url_citation", url_citation = { url = "https://exa.example/x", title = "Exa X" } },
            },
        } } },
    }
    local success, _c, _r, prov = ResponseParser:parseResponse(response, "openrouter")
    TestRunner:assertTrue(success, "parse succeeds")
    TestRunner:assertEqual(type(prov), "table", "provenance table returned")
    TestRunner:assertEqual(prov.sources[1].url, "https://exa.example/x", "annotation url captured")
    TestRunner:assertEqual(prov.sources[1].title, "Exa X", "annotation title captured")
end)

TestRunner:test("Perplexity prefers search_results over bare citations", function()
    local response = {
        choices = { { message = { content = "Sonar answer" } } },
        citations = { "https://p.example/1", "https://p.example/2" },
        search_results = {
            { url = "https://p.example/1", title = "Titled One" },
        },
    }
    local success, _c, _r, prov = ResponseParser:parseResponse(response, "perplexity")
    TestRunner:assertTrue(success, "parse succeeds")
    TestRunner:assertEqual(type(prov), "table", "provenance table returned")
    TestRunner:assertEqual(#prov.sources, 1, "search_results win over citations")
    TestRunner:assertEqual(prov.sources[1].title, "Titled One", "title captured")
end)

TestRunner:test("Perplexity falls back to citation URLs", function()
    local response = {
        choices = { { message = { content = "Sonar answer" } } },
        citations = { "https://p.example/1", "https://p.example/2" },
    }
    local _s, _c, _r, prov = ResponseParser:parseResponse(response, "perplexity")
    TestRunner:assertEqual(type(prov), "table", "provenance table returned")
    TestRunner:assertEqual(#prov.sources, 2, "citation URLs become sources")
    TestRunner:assertNil(prov.sources[1].title, "no title on bare citation")
end)

TestRunner:test("Perplexity without any source data stays true", function()
    local response = {
        choices = { { message = { content = "Sonar answer" } } },
    }
    local _s, _c, _r, prov = ResponseParser:parseResponse(response, "perplexity")
    TestRunner:assertEqual(prov, true, "always-on web search collapses to true")
end)

TestRunner:test("Z.AI captures web_search result links", function()
    local response = {
        choices = { { message = { content = "GLM answer" } } },
        web_search = {
            { title = "Zhipu Result", link = "https://z.example/1" },
        },
    }
    local _s, _c, _r, prov = ResponseParser:parseResponse(response, "zai")
    TestRunner:assertEqual(type(prov), "table", "provenance table returned")
    TestRunner:assertEqual(prov.sources[1].url, "https://z.example/1", "link mapped to url")
end)

--------------------------------------------------------------------------------
-- Test: Streaming source harvest (StreamHandler.harvestWebSources)
--------------------------------------------------------------------------------

TestRunner:suite("Streaming: web source harvest")

local function newProv()
    return { sources = {}, queries = {}, seen = {} }
end

TestRunner:test("harvests Anthropic web_search_tool_result blocks", function()
    local prov = newProv()
    StreamHandler.harvestWebSources({
        type = "content_block_start",
        content_block = { type = "web_search_tool_result", content = {
            { type = "web_search_result", url = "https://a.example", title = "A" },
        } },
    }, prov)
    TestRunner:assertEqual(#prov.sources, 1, "source harvested")
    TestRunner:assertEqual(prov.sources[1].title, "A", "title harvested")
end)

TestRunner:test("harvests Gemini grounding metadata and dedupes across events", function()
    local prov = newProv()
    local event = {
        candidates = { {
            groundingMetadata = {
                webSearchQueries = { "q1" },
                groundingChunks = { { web = { uri = "https://g.example", title = "G" } } },
            },
        } },
    }
    StreamHandler.harvestWebSources(event, prov)
    StreamHandler.harvestWebSources(event, prov)  -- repeated chunk in later event
    TestRunner:assertEqual(#prov.sources, 1, "sources deduped across events")
    TestRunner:assertEqual(#prov.queries, 1, "queries deduped across events")
end)

TestRunner:test("harvests OpenRouter delta annotations", function()
    local prov = newProv()
    StreamHandler.harvestWebSources({
        choices = { { delta = { annotations = {
            { type = "url_citation", url_citation = { url = "https://o.example", title = "O" } },
        } } } },
    }, prov)
    TestRunner:assertEqual(#prov.sources, 1, "annotation source harvested")
end)

TestRunner:test("harvests Perplexity search_results", function()
    local prov = newProv()
    StreamHandler.harvestWebSources({
        search_results = { { url = "https://p.example", title = "P" } },
    }, prov)
    TestRunner:assertEqual(#prov.sources, 1, "search_results harvested")
end)

TestRunner:test("tolerates luajson null sentinels and junk shapes", function()
    local prov = newProv()
    local sentinel = function() end  -- luajson decodes JSON null to a truthy function
    StreamHandler.harvestWebSources({
        type = "content_block_start",
        content_block = { type = "web_search_tool_result", content = sentinel },
        candidates = { { groundingMetadata = sentinel } },
        choices = { { delta = sentinel } },
        search_results = { sentinel, { url = 42, title = "bad" } },
    }, prov)
    TestRunner:assertEqual(#prov.sources, 0, "no sources from junk")
    TestRunner:assertEqual(#prov.queries, 0, "no queries from junk")
end)

--------------------------------------------------------------------------------
-- Test: Pre-search prose assembly (report 3(b) — segments + inline marker)
--------------------------------------------------------------------------------

TestRunner:suite("Anthropic assembly: pre-search prose segments")

local MARKER = ResponseParser.WEB_SEARCH_MARKER
local LONG_PROSE = "Fanon is first mentioned on page 28, in the introductory chapter, "
    .. "where Said lists him among the pivotal anticolonial thinkers."

TestRunner:test("substantive pre-search prose is kept behind the marker", function()
    local response = {
        content = {
            { type = "text", text = LONG_PROSE },
            { type = "server_tool_use", name = "web_search", input = { query = "fanon parents" } },
            { type = "web_search_tool_result", content = {
                { type = "web_search_result", url = "https://w.example", title = "W" } } },
            { type = "text", text = "His father was Félix Casimir Fanon." },
        },
    }
    local success, content = ResponseParser:parseResponse(response, "anthropic")
    TestRunner:assertTrue(success, "parse succeeds")
    TestRunner:assertContains(content, LONG_PROSE)
    TestRunner:assertContains(content, MARKER)
    TestRunner:assertContains(content, "Félix Casimir Fanon")
    TestRunner:assertTrue(content:find(LONG_PROSE, 1, true) < content:find(MARKER, 1, true),
        "pre-search prose comes before the marker")
end)

TestRunner:test("short pre-search filler is dropped, no marker", function()
    local response = {
        content = {
            { type = "text", text = "Let me search the web." },
            { type = "server_tool_use", name = "web_search" },
            { type = "web_search_tool_result", content = {} },
            { type = "text", text = "The answer is 42." },
        },
    }
    local _s, content = ResponseParser:parseResponse(response, "anthropic")
    TestRunner:assertEqual(content, "The answer is 42.", "filler dropped, clean answer")
end)

TestRunner:test("search before any prose leaves no leading marker", function()
    local response = {
        content = {
            { type = "server_tool_use", name = "web_search" },
            { type = "web_search_tool_result", content = {} },
            { type = "text", text = "Straight answer after searching." },
        },
    }
    local _s, content = ResponseParser:parseResponse(response, "anthropic")
    TestRunner:assertEqual(content, "Straight answer after searching.")
end)

TestRunner:test("prose between two searches is preserved with two markers", function()
    local response = {
        content = {
            { type = "text", text = LONG_PROSE },
            { type = "server_tool_use", name = "web_search" },
            { type = "web_search_tool_result", content = {} },
            { type = "text", text = LONG_PROSE .. " (second angle, still substantive prose here)" },
            { type = "server_tool_use", name = "web_search" },
            { type = "web_search_tool_result", content = {} },
            { type = "text", text = "Final synthesis." },
        },
    }
    local _s, content = ResponseParser:parseResponse(response, "anthropic")
    local _, marker_count = content:gsub(MARKER:gsub("%p", "%%%0"), "")
    TestRunner:assertEqual(marker_count, 2, "one marker per search burst")
    TestRunner:assertContains(content, "Final synthesis.")
end)

TestRunner:test("trailing search without prose leaves no dangling marker", function()
    local response = {
        content = {
            { type = "text", text = LONG_PROSE },
            { type = "server_tool_use", name = "web_search" },
            { type = "web_search_tool_result", content = {} },
        },
    }
    local _s, content = ResponseParser:parseResponse(response, "anthropic")
    TestRunner:assertEqual(content, LONG_PROSE, "no trailing marker")
end)

TestRunner:suite("Streaming: closeWebSearchSegment")

TestRunner:test("substantive buffer gets the marker appended", function()
    local buffer = { LONG_PROSE:sub(1, 60), LONG_PROSE:sub(61) }
    local next_start = StreamHandler.closeWebSearchSegment(buffer, 1)
    TestRunner:assertEqual(#buffer, 3, "marker appended as new entry")
    TestRunner:assertContains(buffer[3], MARKER)
    TestRunner:assertEqual(next_start, 4, "next segment starts after the marker")
end)

TestRunner:test("filler buffer is truncated back, no marker", function()
    local buffer = { "Let me ", "search the web." }
    local next_start = StreamHandler.closeWebSearchSegment(buffer, 1)
    TestRunner:assertEqual(#buffer, 0, "filler removed")
    TestRunner:assertEqual(next_start, 1, "segment start reset")
end)

TestRunner:test("only the current segment is considered", function()
    local buffer = { LONG_PROSE, "\n\n" .. MARKER .. "\n\n", "Short tail." }
    local next_start = StreamHandler.closeWebSearchSegment(buffer, 3)
    TestRunner:assertEqual(#buffer, 2, "only the short tail segment dropped")
    TestRunner:assertEqual(buffer[1], LONG_PROSE, "earlier kept segment untouched")
    TestRunner:assertEqual(next_start, 3)
end)

TestRunner:test("empty buffer is a no-op", function()
    local buffer = {}
    local next_start = StreamHandler.closeWebSearchSegment(buffer, 1)
    TestRunner:assertEqual(#buffer, 0)
    TestRunner:assertEqual(next_start, 1)
end)

--------------------------------------------------------------------------------
-- Summary
--------------------------------------------------------------------------------

local success = TestRunner:summary()
return success
