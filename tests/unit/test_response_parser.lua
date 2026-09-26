-- Unit tests for koassistant_api/response_parser.lua
-- Tests response parsing for all 18 providers
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
print("  Unit Tests: Response Parser (17 Providers)")
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

TestRunner:test("openai tool_calls → neutral shape (arguments JSON string decoded)", function()
    local message = {
        role = "assistant",
        content = nil,
        tool_calls = {
            { id = "c1", type = "function",
              ["function"] = { name = "search_book", arguments = "{\"query\":\"Daisy\"}" } },
        },
    }
    local response = { choices = { { message = message, finish_reason = "tool_calls" } } }
    local success, result = ResponseParser:parseResponse(response, "openai")
    TestRunner:assertTrue(success, "success")
    TestRunner:assertTrue(type(result) == "table" and result._tool_calls, "neutral tool-call marker")
    TestRunner:assertEqual(result.calls[1].id, "c1", "call id")
    TestRunner:assertEqual(result.calls[1].name, "search_book", "call name")
    TestRunner:assertEqual(result.calls[1].args.query, "Daisy", "arguments string decoded to table")
    TestRunner:assertTrue(result.raw_assistant_turn == message, "raw_assistant_turn is the message")
end)

TestRunner:test("openrouter tool_calls → neutral shape", function()
    local message = {
        role = "assistant",
        tool_calls = {
            { id = "or1", type = "function",
              ["function"] = { name = "read_around", arguments = "{\"page\":42}" } },
        },
    }
    local response = { choices = { { message = message } } }
    local success, result = ResponseParser:parseResponse(response, "openrouter")
    TestRunner:assertTrue(success, "success")
    TestRunner:assertTrue(type(result) == "table" and result._tool_calls, "neutral tool-call marker")
    TestRunner:assertEqual(result.calls[1].id, "or1", "call id")
    TestRunner:assertEqual(result.calls[1].args.page, 42, "arguments decoded")
end)

TestRunner:test("openai content:null sentinel does not crash truncation or escape as answer", function()
    -- KOReader's luajson decodes JSON null to a truthy FUNCTION sentinel; a tool-call
    -- message truncated mid-arguments hits both content:null and finish_reason=length.
    local sentinel = function() end
    local response = { choices = { { message = {
        role = "assistant",
        content = sentinel,
        tool_calls = {
            { id = "c1", type = "function",
              ["function"] = { name = "search_book", arguments = "{\"query\":" } },
        },
    }, finish_reason = "length" } } }
    local success, result = ResponseParser:parseResponse(response, "openai")
    TestRunner:assertTrue(success, "no crash")
    TestRunner:assertTrue(type(result) == "table" and result._tool_calls, "tool call still detected")
end)

TestRunner:test("openai tool_calls:null sentinel is ignored, content returned", function()
    local sentinel = function() end
    local response = { choices = { { message = {
        role = "assistant", content = "plain answer", tool_calls = sentinel,
    } } } }
    local success, result = ResponseParser:parseResponse(response, "openai")
    TestRunner:assertTrue(success, "no crash on non-table tool_calls")
    TestRunner:assertEqual(result, "plain answer", "content returned")
end)

TestRunner:test("openrouter tool_calls:null sentinel is ignored, content returned", function()
    local sentinel = function() end
    local response = { choices = { { message = {
        role = "assistant", content = "plain answer", tool_calls = sentinel,
    } } } }
    local success, result = ResponseParser:parseResponse(response, "openrouter")
    TestRunner:assertTrue(success, "no crash on non-table tool_calls")
    TestRunner:assertEqual(result, "plain answer", "content returned")
end)

-- Tools wave 1: deepseek/mistral/groq/xai chat-wire tool-call detection
TestRunner:test("deepseek tool_calls → neutral shape, reasoning_content rides along", function()
    local message = {
        role = "assistant",
        content = nil,
        reasoning_content = "let me search the book",
        tool_calls = {
            { id = "ds1", type = "function",
              ["function"] = { name = "search_book", arguments = "{\"query\":\"Daisy\"}" } },
        },
    }
    local response = { choices = { { message = message, finish_reason = "tool_calls" } } }
    local success, result, reasoning = ResponseParser:parseResponse(response, "deepseek")
    TestRunner:assertTrue(success, "success")
    TestRunner:assertTrue(type(result) == "table" and result._tool_calls, "neutral tool-call marker")
    TestRunner:assertEqual(result.calls[1].name, "search_book", "call name")
    TestRunner:assertEqual(result.calls[1].args.query, "Daisy", "arguments decoded")
    TestRunner:assertTrue(result.raw_assistant_turn == message, "raw_assistant_turn is the message")
    TestRunner:assertEqual(result.raw_assistant_turn.reasoning_content, "let me search the book",
        "reasoning_content preserved for the mandatory replay echo")
    TestRunner:assertEqual(reasoning, "let me search the book", "reasoning returned")
end)

TestRunner:test("deepseek content:null sentinel cannot escape as the answer", function()
    local sentinel = function() end
    local response = { choices = { { message = {
        role = "assistant", content = sentinel,
    }, finish_reason = "stop" } } }
    local success, result = ResponseParser:parseResponse(response, "deepseek")
    TestRunner:assertTrue(success, "no crash")
    TestRunner:assertTrue(result == nil, "sentinel normalized to nil")
end)

TestRunner:test("mistral tool_calls → neutral shape (coexists with Magistral thinking blocks)", function()
    local message = {
        role = "assistant",
        -- Magistral: structured content chunks AND tool_calls as sibling fields
        content = {
            { type = "thinking", thinking = { { text = "hmm" } } },
        },
        tool_calls = {
            { id = "m1", type = "function",
              ["function"] = { name = "toc", arguments = "{}" } },
        },
    }
    local response = { choices = { { message = message } } }
    local success, result = ResponseParser:parseResponse(response, "mistral")
    TestRunner:assertTrue(success, "success")
    TestRunner:assertTrue(type(result) == "table" and result._tool_calls, "tool calls win over thinking content")
    TestRunner:assertEqual(result.calls[1].name, "toc", "call name")
end)

TestRunner:test("mistral non-string non-table content normalized to nil", function()
    local sentinel = function() end
    local response = { choices = { { message = { role = "assistant", content = sentinel } } } }
    local success, result = ResponseParser:parseResponse(response, "mistral")
    TestRunner:assertTrue(success, "no crash")
    TestRunner:assertTrue(result == nil, "sentinel normalized to nil")
end)

TestRunner:test("groq tool_calls → neutral shape (before think-tag extraction)", function()
    local sentinel = function() end
    local response = { choices = { { message = {
        role = "assistant",
        content = sentinel,  -- tool-call turns carry content:null
        tool_calls = {
            { id = "g1", type = "function",
              ["function"] = { name = "read_around", arguments = "{\"page\":7}" } },
        },
    }, finish_reason = "tool_calls" } } }
    local success, result = ResponseParser:parseResponse(response, "groq")
    TestRunner:assertTrue(success, "success")
    TestRunner:assertTrue(type(result) == "table" and result._tool_calls, "neutral tool-call marker")
    TestRunner:assertEqual(result.calls[1].args.page, 7, "arguments decoded")
end)

TestRunner:test("xai tool_calls → neutral shape, reasoning + no false web flag", function()
    local message = {
        role = "assistant",
        content = nil,
        reasoning_content = "searching",
        tool_calls = {
            { id = "x1", type = "function",
              ["function"] = { name = "search_book", arguments = "{\"query\":\"whale\"}" } },
        },
    }
    local response = { choices = { { message = message } } }
    local success, result, reasoning, web = ResponseParser:parseResponse(response, "xai")
    TestRunner:assertTrue(success, "success")
    TestRunner:assertTrue(type(result) == "table" and result._tool_calls, "neutral tool-call marker")
    TestRunner:assertEqual(result.calls[1].args.query, "whale", "arguments decoded")
    TestRunner:assertEqual(reasoning, "searching", "reasoning_content returned")
    TestRunner:assertTrue(web == nil, "book tools don't set the web-search flag")
end)

TestRunner:test("xai tool_calls:null sentinel is ignored, content returned", function()
    local sentinel = function() end
    local response = { choices = { { message = {
        role = "assistant", content = "plain answer", tool_calls = sentinel,
    } } } }
    local success, result = ResponseParser:parseResponse(response, "xai")
    TestRunner:assertTrue(success, "no crash on non-table tool_calls")
    TestRunner:assertEqual(result, "plain answer", "content returned")
end)

TestRunner:test("openai malformed tool arguments fall back to empty args", function()
    local response = { choices = { { message = {
        role = "assistant",
        tool_calls = {
            { id = "c1", type = "function",
              ["function"] = { name = "toc", arguments = "{not json" } },
        },
    } } } }
    local success, result = ResponseParser:parseResponse(response, "openai")
    TestRunner:assertTrue(success, "success")
    TestRunner:assertTrue(result._tool_calls, "still a tool call")
    TestRunner:assertTrue(type(result.calls[1].args) == "table", "args is a table")
    TestRunner:assertTrue(next(result.calls[1].args) == nil, "args empty on decode failure")
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

TestRunner:test("parses function calls", function()
    local response = {
        candidates = {
            {
                content = {
                    role = "model",
                    parts = {
                        {
                            functionCall = {
                                id = "call-1",
                                name = "search_book",
                                args = { query = "Daisy", max_results = 3 },
                            },
                        },
                    },
                },
            },
        },
    }
    local success, result = ResponseParser:parseResponse(response, "gemini")
    TestRunner:assertTrue(success, "success")
    TestRunner:assertTrue(type(result) == "table", "result table")
    TestRunner:assertTrue(result._tool_calls, "function call marker")
    TestRunner:assertEqual(result.calls[1].id, "call-1", "call id")
    TestRunner:assertEqual(result.calls[1].name, "search_book", "call name")
    TestRunner:assertEqual(result.calls[1].args.query, "Daisy", "call args")
end)

TestRunner:test("anthropic tool_use blocks → neutral tool-call shape", function()
    local response = {
        content = {
            { type = "text", text = "let me look" },
            { type = "tool_use", id = "tu1", name = "search_book", input = { query = "Daisy" } },
        },
        stop_reason = "tool_use",
    }
    local success, result = ResponseParser:parseResponse(response, "anthropic")
    TestRunner:assertTrue(success, "success")
    TestRunner:assertTrue(type(result) == "table" and result._tool_calls, "neutral tool-call marker")
    TestRunner:assertEqual(result.calls[1].id, "tu1", "call id")
    TestRunner:assertEqual(result.calls[1].name, "search_book", "call name")
    TestRunner:assertEqual(result.calls[1].args.query, "Daisy", "call args (from input)")
    TestRunner:assertEqual(result.raw_assistant_turn.role, "assistant", "raw_assistant_turn echo")
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

-- Test Z.AI format (custom transformer with reasoning_content + web search)
TestRunner:suite("Z.AI")

TestRunner:test("parses successful response", function()
    local response = {
        choices = { { message = { content = "Hello from Z.AI" } } }
    }
    local success, result = ResponseParser:parseResponse(response, "zai")
    TestRunner:assertTrue(success, "success")
    TestRunner:assertEqual(result, "Hello from Z.AI", "content")
end)

TestRunner:test("extracts reasoning_content", function()
    local response = {
        choices = { { message = { content = "Answer", reasoning_content = "Thinking..." } } }
    }
    local success, result, reasoning = ResponseParser:parseResponse(response, "zai")
    TestRunner:assertTrue(success, "success")
    TestRunner:assertEqual(result, "Answer", "content")
    TestRunner:assertEqual(reasoning, "Thinking...", "reasoning")
end)

TestRunner:test("detects web search usage", function()
    local response = {
        choices = { { message = { content = "Search result" } } },
        web_search = { { content = "source info" } }
    }
    local success, result, reasoning, web_search_used = ResponseParser:parseResponse(response, "zai")
    TestRunner:assertTrue(success, "success")
    TestRunner:assertEqual(result, "Search result", "content")
    TestRunner:assertTrue(web_search_used, "web_search_used")
end)

TestRunner:test("handles error response", function()
    local response = {
        error = { message = "Error from Z.AI" }
    }
    local success, result = ResponseParser:parseResponse(response, "zai")
    TestRunner:assertFalse(success, "error success")
    TestRunner:assertEqual(result, "Error from Z.AI", "error message")
end)

TestRunner:suite("OpenAI-shaped parser: passive reasoning (2026-09-05)")

TestRunner:test("openai parser returns reasoning_content as reasoning", function()
    local ok, content, reasoning = ResponseParser:parseResponse({
        choices = { { message = { role = "assistant", content = "OK", reasoning_content = "thought" }, finish_reason = "stop" } },
    }, "openai")
    TestRunner:assertTrue(ok, "success")
    TestRunner:assertEqual(content, "OK", "content")
    TestRunner:assertEqual(reasoning, "thought", "reasoning_content surfaced")
end)

TestRunner:test("openai parser strips <think> tags from content into reasoning", function()
    local ok, content, reasoning = ResponseParser:parseResponse({
        choices = { { message = { role = "assistant", content = "<think>plan</think>\nOK" }, finish_reason = "stop" } },
    }, "openai")
    TestRunner:assertTrue(ok, "success")
    TestRunner:assertEqual(content, "OK", "answer text without the tags")
    TestRunner:assertEqual(reasoning, "plan", "think block surfaced as reasoning")
end)

TestRunner:test("orphan </think>: template-opened reasoning splits at the first closer", function()
    local ok, content, reasoning = ResponseParser:parseResponse({
        choices = { { message = { role = "assistant",
            content = "Let me weigh this.\n</think>\n\nThe answer." }, finish_reason = "stop" } },
    }, "openai")
    TestRunner:assertTrue(ok, "success")
    TestRunner:assertEqual(content, "The answer.", "answer after the closer")
    TestRunner:assertEqual(reasoning, "Let me weigh this.", "text before the closer is reasoning")
    -- Same through a parser that calls extractThinkTags unconditionally
    local ok2, content2, reasoning2 = ResponseParser:parseResponse({
        choices = { { message = { content = "plan</think>OK" } } },
    }, "groq")
    TestRunner:assertTrue(ok2, "groq success")
    TestRunner:assertEqual(content2, "OK", "groq answer")
    TestRunner:assertEqual(reasoning2, "plan", "groq reasoning")
end)

TestRunner:test("splitOrphanThink: guards (opener present, nothing after, bare closer)", function()
    local split = ResponseParser.splitOrphanThink
    -- A reply that quotes both tags keeps its text
    local quoted = "Models wrap it in <think> and </think> tags."
    local a1, r1 = split(quoted)
    TestRunner:assertEqual(a1, quoted, "opener anywhere = untouched")
    TestRunner:assertEqual(r1, nil, "no reasoning")
    -- Nothing after the closer: keep the text (the reader must see something)
    local a2, r2 = split("all reasoning</think>   ")
    TestRunner:assertEqual(a2, "all reasoning</think>   ", "empty answer = untouched")
    TestRunner:assertEqual(r2, nil, "no reasoning")
    -- Empty reasoning: the closer is stripped, no reasoning recorded
    local a3, r3 = split("</think>\n\nHello")
    TestRunner:assertEqual(a3, "Hello", "bare closer stripped")
    TestRunner:assertEqual(r3, nil, "empty reasoning = nil")
    -- No closer at all, and non-strings, pass through
    TestRunner:assertEqual(split("plain"), "plain", "no closer")
    TestRunner:assertEqual(split(nil), nil, "nil")
    -- Only the FIRST closer splits; a later one stays in the answer
    local a4, r4 = split("r</think>a </think> b")
    TestRunner:assertEqual(a4, "a </think> b", "first closer only")
    TestRunner:assertEqual(r4, "r", "reasoning before the first")
end)

TestRunner:test("openai parser: no reasoning field = nil, content untouched", function()
    local ok, content, reasoning = ResponseParser:parseResponse({
        choices = { { message = { role = "assistant", content = "plain" }, finish_reason = "stop" } },
    }, "openai")
    TestRunner:assertTrue(ok, "success")
    TestRunner:assertEqual(content, "plain", "content")
    TestRunner:assertEqual(reasoning, nil, "no reasoning")
end)

-- Test OpenAI-compatible providers
local openai_compatible = {
    "groq", "mistral", "xai", "openrouter", "requesty", "qwen",
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

-- Test Perplexity (always-on web search + citations)
TestRunner:suite("Perplexity")

TestRunner:test("web_search_used is evidence-based (2026-08-14: disable_search is real)", function()
    local bare = {
        choices = { { message = { content = "Hello from Perplexity" } } }
    }
    local success, result, _r, web_search_used = ResponseParser:parseResponse(bare, "perplexity")
    TestRunner:assertTrue(success, "success")
    TestRunner:assertEqual(result, "Hello from Perplexity", "content")
    TestRunner:assertTrue(web_search_used == nil, "no citations/search_results -> no search claim")
    local searched = {
        choices = { { message = { content = "Grounded answer" } } },
        search_results = { { url = "https://s.example/1", title = "Source" } },
    }
    local _s2, _c2, _r2, used2 = ResponseParser:parseResponse(searched, "perplexity")
    TestRunner:assertTrue(type(used2) == "table" and used2.web_search == true,
        "search artifacts -> provenance table")
end)

TestRunner:test("appends citation footnotes", function()
    local response = {
        choices = { { message = { content = "Answer with [1] and [2] refs" } } },
        citations = { "https://example.com/article", "https://en.wikipedia.org/wiki/Topic" }
    }
    local success, result = ResponseParser:parseResponse(response, "perplexity")
    TestRunner:assertTrue(success, "success")
    TestRunner:assertContains(result, "**Sources:**", "sources header")
    TestRunner:assertContains(result, "[1] [example.com](https://example.com/article)", "citation 1")
    TestRunner:assertContains(result, "[2] [en.wikipedia.org](https://en.wikipedia.org/wiki/Topic)", "citation 2")
end)

TestRunner:test("handles response without citations", function()
    local response = {
        choices = { { message = { content = "No citations here" } } }
    }
    local success, result = ResponseParser:parseResponse(response, "perplexity")
    TestRunner:assertTrue(success, "success")
    TestRunner:assertEqual(result, "No citations here", "content unchanged")
end)

TestRunner:test("handles error response", function()
    local response = {
        error = { message = "Error from Perplexity" }
    }
    local success, result = ResponseParser:parseResponse(response, "perplexity")
    TestRunner:assertFalse(success, "error success")
    TestRunner:assertEqual(result, "Error from Perplexity", "error message")
end)

TestRunner:test("extracts reasoning from <think> tags (sonar-reasoning-pro)", function()
    local response = {
        choices = { { message = { content = "<think>Let me reason about this</think>The answer is 42" } } },
        citations = { "https://example.com/answer" }
    }
    local success, result, reasoning, web_search_used = ResponseParser:parseResponse(response, "perplexity")
    TestRunner:assertTrue(success, "success")
    TestRunner:assertEqual(result, "The answer is 42\n\n---\n**Sources:**\n\n- [1] [example.com](https://example.com/answer)", "content without think tags")
    TestRunner:assertEqual(reasoning, "Let me reason about this", "reasoning extracted")
    TestRunner:assertTrue(web_search_used, "web_search_used always true")
end)

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

TestRunner:suite("Incomplete-response notices — token limit vs provider interrupt")

TestRunner:test("interruptedNotice names the provider's own error", function()
    -- The real Gemini 503 from the 2026-08-06 device round.
    local n = ResponseParser.interruptedNotice(
        "This model is currently experiencing high demand. Spikes in demand are usually temporary. Please try again later.")
    TestRunner:assertContains(n, "experiencing high demand", "carries the provider message")
    TestRunner:assertFalse(n:find("token limit", 1, true) ~= nil, "does not claim a token limit")
end)

TestRunner:test("interruptedNotice falls back when no detail is available", function()
    TestRunner:assertEqual(ResponseParser.interruptedNotice(nil), ResponseParser.INTERRUPTED_NOTICE)
    TestRunner:assertEqual(ResponseParser.interruptedNotice(""), ResponseParser.INTERRUPTED_NOTICE)
end)

TestRunner:test("multi-line provider detail is flattened to one italic run", function()
    local n = ResponseParser.interruptedNotice("Quota exceeded.\n\nLimit: 50/day\nRetry in 30s")
    TestRunner:assertFalse(n:sub(#ResponseParser.INTERRUPTED_PREFIX + 1):find("\n") ~= nil,
        "no newlines inside the notice body")
    TestRunner:assertContains(n, "Retry in 30s", "detail preserved")
end)

TestRunner:test("isIncomplete matches BOTH markers", function()
    TestRunner:assertTrue(ResponseParser.isIncomplete("answer" .. ResponseParser.TRUNCATION_NOTICE),
        "token-truncated")
    TestRunner:assertTrue(ResponseParser.isIncomplete("answer" .. ResponseParser.INTERRUPTED_NOTICE),
        "interrupted, no detail")
    TestRunner:assertTrue(
        ResponseParser.isIncomplete("answer" .. ResponseParser.interruptedNotice("503 high demand")),
        "interrupted, with detail — prefix match, not whole-string")
end)

TestRunner:test("isIncomplete is false for whole responses and non-strings", function()
    TestRunner:assertFalse(ResponseParser.isIncomplete("a perfectly complete answer"), "complete")
    TestRunner:assertFalse(ResponseParser.isIncomplete(nil), "nil")
    TestRunner:assertFalse(ResponseParser.isIncomplete({}), "table")
end)

-- Abnormal stop reasons (parity audit F059/F276, 2026-09-07): a stop the
-- provider names (Gemini SAFETY/RECITATION, OpenAI content_filter, Anthropic
-- refusal) is named to the reader instead of "Unexpected response format" (no
-- text) or a silently shortened answer (partial text).
TestRunner:suite("Abnormal stop reasons")

TestRunner:test("gemini SAFETY with no parts names the reason", function()
    local response = { candidates = { { content = { role = "model" }, finishReason = "SAFETY" } } }
    local success, result = ResponseParser:parseResponse(response, "gemini")
    TestRunner:assertFalse(success, "failure")
    TestRunner:assertContains(result, "SAFETY", "reason named")
    TestRunner:assertContains(result, "Content Filter", "points at the setting")
end)

TestRunner:test("gemini RECITATION with partial text appends the stop notice", function()
    local response = { candidates = { {
        content = { parts = { { text = "It begins" } } }, finishReason = "RECITATION" } } }
    local success, result = ResponseParser:parseResponse(response, "gemini")
    TestRunner:assertTrue(success, "partial text kept")
    TestRunner:assertEqual(result:sub(1, 9), "It begins", "text intact")
    TestRunner:assertContains(result, "RECITATION", "reason named")
    TestRunner:assertTrue(ResponseParser.isIncomplete(result), "never cached as whole")
end)

TestRunner:test("gemini prompt block (promptFeedback, no candidates) names the block", function()
    local response = { promptFeedback = { blockReason = "PROHIBITED_CONTENT" } }
    local success, result = ResponseParser:parseResponse(response, "gemini")
    TestRunner:assertFalse(success, "failure")
    TestRunner:assertContains(result, "PROHIBITED_CONTENT", "block reason named")
end)

TestRunner:test("gemini STOP and MAX_TOKENS stay as before", function()
    local ok1, r1 = ResponseParser:parseResponse({ candidates = { {
        content = { parts = { { text = "fine" } } }, finishReason = "STOP" } } }, "gemini")
    TestRunner:assertTrue(ok1 and r1 == "fine", "STOP untouched")
    local ok2, r2 = ResponseParser:parseResponse({ candidates = { {
        content = { parts = { { text = "cut" } } }, finishReason = "MAX_TOKENS" } } }, "gemini")
    TestRunner:assertTrue(ok2, "MAX_TOKENS still succeeds")
    TestRunner:assertContains(r2, "truncated", "truncation notice, not a stop notice")
    TestRunner:assertEqual(r2:find(ResponseParser.STOP_PREFIX, 1, true), nil, "no stop notice")
end)

TestRunner:test("openai content_filter: notice on partial text, error on none", function()
    local ok1, r1 = ResponseParser:parseResponse({ choices = { {
        message = { content = "Part of it" }, finish_reason = "content_filter" } } }, "openai")
    TestRunner:assertTrue(ok1, "partial kept")
    TestRunner:assertContains(r1, "content_filter", "reason named")
    local ok2, r2 = ResponseParser:parseResponse({ choices = { {
        message = { content = "" }, finish_reason = "content_filter" } } }, "openai")
    TestRunner:assertFalse(ok2, "no text = failure")
    TestRunner:assertContains(r2, "content_filter", "reason named in the error")
    local ok3, r3 = ResponseParser:parseResponse({ choices = { {
        message = { content = "done" }, finish_reason = "stop" } } }, "openai")
    TestRunner:assertTrue(ok3 and r3 == "done", "stop untouched")
end)

TestRunner:test("anthropic refusal: notice on partial text, error on none", function()
    local ok1, r1 = ResponseParser:parseResponse({ content = { { type = "text", text = "I" } },
        stop_reason = "refusal" }, "anthropic")
    TestRunner:assertTrue(ok1, "partial kept")
    TestRunner:assertContains(r1, "refusal", "reason named")
    local ok2, r2 = ResponseParser:parseResponse({ content = {}, stop_reason = "refusal" }, "anthropic")
    TestRunner:assertFalse(ok2, "no text = failure")
    TestRunner:assertContains(r2, "refusal", "reason named in the error")
    local ok3, r3 = ResponseParser:parseResponse({ content = { { type = "text", text = "ok" } },
        stop_reason = "end_turn" }, "anthropic")
    TestRunner:assertTrue(ok3 and r3 == "ok", "end_turn untouched")
end)

TestRunner:test("abnormalStop: normal reasons and non-strings are nil", function()
    for _idx, r in ipairs({ "stop", "length", "tool_calls", "end_turn", "max_tokens", "STOP", "MAX_TOKENS", "" }) do
        TestRunner:assertEqual(ResponseParser.abnormalStop(r), nil, "normal: " .. r)
    end
    TestRunner:assertEqual(ResponseParser.abnormalStop(nil), nil, "nil")
    TestRunner:assertEqual(ResponseParser.abnormalStop(function() end), nil, "json null sentinel")
    TestRunner:assertEqual(ResponseParser.abnormalStop("SAFETY"), "SAFETY", "abnormal passes through")
end)

-- Summary
local success = TestRunner:summary()
return success
