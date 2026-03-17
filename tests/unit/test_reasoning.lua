-- Unit tests for reasoning/thinking request injection and response parsing
-- Tests that reasoning parameters are correctly injected into request bodies
-- and that reasoning content is correctly extracted from responses.
-- No API calls.
--
-- Run: lua tests/run_tests.lua --unit

-- Setup paths
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

-- Test framework
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
        error(string.format("%s: expected %s, got %s", msg or "Assertion failed", tostring(expected), tostring(actual)))
    end
end

function TestRunner:assertTrue(value, msg)
    if not value then
        error(string.format("%s: expected true", msg or "Assertion failed"))
    end
end

function TestRunner:assertFalse(value, msg)
    if value then
        error(string.format("%s: expected false, got %s", msg or "Assertion failed", tostring(value)))
    end
end

function TestRunner:assertNil(value, msg)
    if value ~= nil then
        error(string.format("%s: expected nil, got %s", msg or "Assertion failed", tostring(value)))
    end
end

function TestRunner:assertNotNil(value, msg)
    if value == nil then
        error(string.format("%s: expected non-nil value", msg or "Assertion failed"))
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

-- Load modules
local ModelConstraints = require("model_constraints")
local ResponseParser = require("response_parser")

print("")
print(string.rep("=", 50))
print("  Unit Tests: Reasoning Request Injection & Parsing")
print(string.rep("=", 50))

--------------------------------------------------------------------------------
-- Test: Handler customizeRequestBody() — reasoning parameter injection
--------------------------------------------------------------------------------

TestRunner:suite("DeepSeek thinking injection")

local DeepSeekHandler = require("deepseek")

TestRunner:test("deepseek-reasoner supports thinking capability", function()
    TestRunner:assertTrue(
        ModelConstraints.supportsCapability("deepseek", "deepseek-reasoner", "thinking"),
        "deepseek-reasoner should support thinking"
    )
end)

TestRunner:test("deepseek-chat supports thinking capability", function()
    TestRunner:assertTrue(
        ModelConstraints.supportsCapability("deepseek", "deepseek-chat", "thinking"),
        "deepseek-chat should support thinking"
    )
end)

TestRunner:test("deepseek non-thinking model is excluded", function()
    TestRunner:assertFalse(
        ModelConstraints.supportsCapability("deepseek", "some-other-model", "thinking"),
        "unknown model should not support thinking"
    )
end)

TestRunner:suite("OpenRouter reasoning injection")

local OpenRouterHandler = require("openrouter")

TestRunner:test("adds reasoning object when config present", function()
    local body = { model = "anthropic/claude-sonnet-4.5", messages = {} }
    local config = {
        api_params = { openrouter_reasoning = { effort = "high" } },
        features = {},
    }
    local result = OpenRouterHandler:customizeRequestBody(body, config)
    TestRunner:assertNotNil(result.reasoning, "reasoning should be set")
    TestRunner:assertEqual(result.reasoning.effort, "high", "effort level")
end)

TestRunner:test("no reasoning object when config absent", function()
    local body = { model = "anthropic/claude-sonnet-4.5", messages = {} }
    local config = { api_params = {}, features = {} }
    local result = OpenRouterHandler:customizeRequestBody(body, config)
    TestRunner:assertNil(result.reasoning, "reasoning should not be set")
end)

TestRunner:suite("Groq reasoning injection")

local GroqHandler = require("groq")

TestRunner:test("adds reasoning_effort for supported model", function()
    local body = { model = "qwen/qwen3-32b", messages = {} }
    local config = { api_params = { groq_reasoning = { effort = "high" } } }
    local result = GroqHandler:customizeRequestBody(body, config)
    TestRunner:assertEqual(result.reasoning_effort, "high", "reasoning_effort")
end)

TestRunner:test("adds include_reasoning for GPT-OSS models", function()
    local body = { model = "openai/gpt-oss-120b", messages = {} }
    local config = { api_params = { groq_reasoning = { effort = "medium" } } }
    local result = GroqHandler:customizeRequestBody(body, config)
    TestRunner:assertEqual(result.reasoning_effort, "medium", "reasoning_effort")
    TestRunner:assertTrue(result.include_reasoning, "include_reasoning for GPT-OSS")
end)

TestRunner:test("no reasoning for unsupported model", function()
    local body = { model = "llama-3.3-70b-versatile", messages = {} }
    local config = { api_params = { groq_reasoning = { effort = "high" } } }
    local result = GroqHandler:customizeRequestBody(body, config)
    TestRunner:assertNil(result.reasoning_effort, "should not add reasoning_effort")
end)

TestRunner:suite("Together reasoning injection")

local TogetherHandler = require("together")

TestRunner:test("adds reasoning_effort for R1", function()
    local body = { model = "deepseek-ai/DeepSeek-R1", messages = {} }
    local config = { api_params = { together_reasoning = { effort = "low" } } }
    local result = TogetherHandler:customizeRequestBody(body, config)
    TestRunner:assertEqual(result.reasoning_effort, "low", "reasoning_effort")
end)

TestRunner:test("no reasoning for unsupported model", function()
    local body = { model = "meta-llama/Llama-4-Scout", messages = {} }
    local config = { api_params = { together_reasoning = { effort = "high" } } }
    local result = TogetherHandler:customizeRequestBody(body, config)
    TestRunner:assertNil(result.reasoning_effort, "should not add reasoning_effort")
end)

TestRunner:suite("Fireworks reasoning injection")

local FireworksHandler = require("fireworks")

TestRunner:test("adds reasoning_effort for Qwen3", function()
    local body = { model = "accounts/fireworks/models/qwen3-235b-a22b", messages = {} }
    local config = { api_params = { fireworks_reasoning = { effort = "medium" } } }
    local result = FireworksHandler:customizeRequestBody(body, config)
    TestRunner:assertEqual(result.reasoning_effort, "medium", "reasoning_effort")
end)

TestRunner:suite("SambaNova thinking injection")

local SambaNovaHandler = require("sambanova")

TestRunner:test("enables thinking when config present", function()
    local body = { model = "DeepSeek-R1-0528", messages = {} }
    local config = { api_params = { sambanova_thinking = true } }
    local result = SambaNovaHandler:customizeRequestBody(body, config)
    TestRunner:assertNotNil(result.chat_template_kwargs, "should set chat_template_kwargs")
    TestRunner:assertTrue(result.chat_template_kwargs.enable_thinking, "enable_thinking")
end)

TestRunner:test("disables thinking when config absent", function()
    local body = { model = "DeepSeek-R1-0528", messages = {} }
    local config = { api_params = {} }
    local result = SambaNovaHandler:customizeRequestBody(body, config)
    TestRunner:assertNotNil(result.chat_template_kwargs, "should set chat_template_kwargs")
    TestRunner:assertFalse(result.chat_template_kwargs.enable_thinking, "enable_thinking should be false")
end)

TestRunner:test("no thinking for unsupported model", function()
    local body = { model = "Meta-Llama-3.3-70B-Instruct", messages = {} }
    local config = { api_params = { sambanova_thinking = true } }
    local result = SambaNovaHandler:customizeRequestBody(body, config)
    TestRunner:assertNil(result.chat_template_kwargs, "should not set chat_template_kwargs")
end)

TestRunner:suite("xAI reasoning injection")

local XAIHandler = require("xai")

TestRunner:test("adds reasoning_effort for grok-3-mini", function()
    local body = { model = "grok-3-mini", messages = {} }
    local config = { api_params = { xai_reasoning = { effort = "low" } } }
    local result = XAIHandler:customizeRequestBody(body, config)
    TestRunner:assertEqual(result.reasoning_effort, "low", "reasoning_effort")
end)

TestRunner:test("no reasoning for grok-4 (not in capability list)", function()
    local body = { model = "grok-4", messages = {} }
    local config = { api_params = { xai_reasoning = { effort = "high" } } }
    local result = XAIHandler:customizeRequestBody(body, config)
    TestRunner:assertNil(result.reasoning_effort, "should not add reasoning_effort")
end)

TestRunner:suite("Z.AI thinking injection")

local ZaiHandler = require("zai")

TestRunner:test("adds thinking when config present", function()
    local body = { model = "glm-5-turbo", messages = {}, temperature = 0.7 }
    local config = { api_params = { zai_thinking = { type = "enabled" } } }
    local result = ZaiHandler:customizeRequestBody(body, config)
    TestRunner:assertNotNil(result.thinking, "thinking should be set")
    TestRunner:assertEqual(result.thinking.type, "enabled", "thinking type")
end)

TestRunner:test("forces temperature=1.0 when thinking enabled", function()
    local body = { model = "glm-5", messages = {}, temperature = 0.7 }
    local config = { api_params = { zai_thinking = { type = "enabled" } } }
    local result = ZaiHandler:customizeRequestBody(body, config)
    TestRunner:assertEqual(result.temperature, 1.0, "temperature should be forced to 1.0")
end)

TestRunner:test("preserves temperature when thinking disabled", function()
    local body = { model = "glm-4.7-flash", messages = {}, temperature = 0.5 }
    local config = { api_params = { zai_thinking = { type = "disabled" } } }
    local result = ZaiHandler:customizeRequestBody(body, config)
    TestRunner:assertEqual(result.temperature, 0.5, "temperature should be preserved")
end)

TestRunner:test("no thinking when config absent", function()
    local body = { model = "glm-5-turbo", messages = {}, temperature = 0.7 }
    local config = { api_params = {} }
    local result = ZaiHandler:customizeRequestBody(body, config)
    TestRunner:assertNil(result.thinking, "thinking should not be set")
    TestRunner:assertEqual(result.temperature, 0.7, "temperature unchanged")
end)

TestRunner:test("forces temp=1.0 even from high temperature", function()
    local body = { model = "glm-4.7", messages = {}, temperature = 1.8 }
    local config = { api_params = { zai_thinking = { type = "enabled" } } }
    local result = ZaiHandler:customizeRequestBody(body, config)
    TestRunner:assertEqual(result.temperature, 1.0, "should override any temperature to 1.0")
end)

TestRunner:suite("Perplexity reasoning injection")

local PerplexityHandler = require("perplexity")

TestRunner:test("adds reasoning_effort for sonar-reasoning-pro", function()
    local body = { model = "sonar-reasoning-pro", messages = { { role = "user", content = "hi" } } }
    local config = { api_params = { perplexity_reasoning = { effort = "high" } }, features = {} }
    local result = PerplexityHandler:customizeRequestBody(body, config)
    TestRunner:assertEqual(result.reasoning_effort, "high", "reasoning_effort")
end)

TestRunner:test("no reasoning for sonar (non-reasoning model)", function()
    local body = { model = "sonar", messages = { { role = "user", content = "hi" } } }
    local config = { api_params = { perplexity_reasoning = { effort = "high" } }, features = {} }
    local result = PerplexityHandler:customizeRequestBody(body, config)
    TestRunner:assertNil(result.reasoning_effort, "should not add reasoning_effort")
end)

TestRunner:test("merges consecutive same-role messages", function()
    local body = {
        model = "sonar",
        messages = {
            { role = "user", content = "context" },
            { role = "user", content = "question" },
        },
    }
    local config = { api_params = {}, features = {} }
    local result = PerplexityHandler:customizeRequestBody(body, config)
    TestRunner:assertEqual(#result.messages, 1, "should merge to 1 message")
    TestRunner:assertTrue(result.messages[1].content:find("question"), "should contain question")
end)

--------------------------------------------------------------------------------
-- Test: Response Parser — reasoning extraction
--------------------------------------------------------------------------------

TestRunner:suite("Response Parser: Mistral structured content")

TestRunner:test("extracts thinking from structured content blocks", function()
    local response = {
        choices = { {
            message = {
                content = {
                    { type = "thinking", thinking = { { type = "text", text = "Let me think..." } } },
                    { type = "text", text = "The answer is 42." },
                },
            },
        } },
    }
    local ok, content, reasoning = ResponseParser:parseResponse(response, "mistral")
    TestRunner:assertTrue(ok, "should succeed")
    TestRunner:assertEqual(content, "The answer is 42.", "content")
    TestRunner:assertEqual(reasoning, "Let me think...", "reasoning")
end)

TestRunner:test("handles string content (non-Magistral)", function()
    local response = {
        choices = { {
            message = { content = "Simple response." },
        } },
    }
    local ok, content, reasoning = ResponseParser:parseResponse(response, "mistral")
    TestRunner:assertTrue(ok, "should succeed")
    TestRunner:assertEqual(content, "Simple response.", "content")
    TestRunner:assertNil(reasoning, "no reasoning for non-Magistral")
end)

TestRunner:suite("Response Parser: OpenRouter reasoning")

TestRunner:test("extracts message.reasoning field", function()
    local response = {
        choices = { {
            message = {
                content = "The answer.",
                reasoning = "I thought about this carefully.",
            },
        } },
    }
    local ok, content, reasoning = ResponseParser:parseResponse(response, "openrouter")
    TestRunner:assertTrue(ok, "should succeed")
    TestRunner:assertEqual(content, "The answer.", "content")
    TestRunner:assertEqual(reasoning, "I thought about this carefully.", "reasoning")
end)

TestRunner:test("nil reasoning when not present", function()
    local response = {
        choices = { {
            message = { content = "No reasoning." },
        } },
    }
    local ok, content, reasoning = ResponseParser:parseResponse(response, "openrouter")
    TestRunner:assertTrue(ok, "should succeed")
    TestRunner:assertNil(reasoning, "no reasoning")
end)

TestRunner:suite("Response Parser: xAI reasoning_content")

TestRunner:test("extracts reasoning_content from grok-3-mini", function()
    local response = {
        choices = { {
            message = {
                content = "Result.",
                reasoning_content = "Mini reasoning.",
            },
        } },
    }
    local ok, content, reasoning = ResponseParser:parseResponse(response, "xai")
    TestRunner:assertTrue(ok, "should succeed")
    TestRunner:assertEqual(content, "Result.", "content")
    TestRunner:assertEqual(reasoning, "Mini reasoning.", "reasoning")
end)

TestRunner:suite("Response Parser: Passive reasoning_content extraction")

TestRunner:test("Qwen extracts reasoning_content", function()
    local response = {
        choices = { {
            message = {
                content = "Qwen answer.",
                reasoning_content = "Qwen thinking.",
            },
        } },
    }
    local ok, content, reasoning = ResponseParser:parseResponse(response, "qwen")
    TestRunner:assertTrue(ok, "should succeed")
    TestRunner:assertEqual(reasoning, "Qwen thinking.", "reasoning")
end)

TestRunner:test("Kimi extracts reasoning_content", function()
    local response = {
        choices = { {
            message = {
                content = "Kimi answer.",
                reasoning_content = "Kimi thinking.",
            },
        } },
    }
    local ok, content, reasoning = ResponseParser:parseResponse(response, "kimi")
    TestRunner:assertTrue(ok, "should succeed")
    TestRunner:assertEqual(reasoning, "Kimi thinking.", "reasoning")
end)

TestRunner:test("Doubao extracts reasoning_content", function()
    local response = {
        choices = { {
            message = {
                content = "Doubao answer.",
                reasoning_content = "Doubao thinking.",
            },
        } },
    }
    local ok, content, reasoning = ResponseParser:parseResponse(response, "doubao")
    TestRunner:assertTrue(ok, "should succeed")
    TestRunner:assertEqual(reasoning, "Doubao thinking.", "reasoning")
end)

TestRunner:test("Qwen returns nil reasoning when not present", function()
    local response = {
        choices = { {
            message = { content = "Simple answer." },
        } },
    }
    local ok, content, reasoning = ResponseParser:parseResponse(response, "qwen")
    TestRunner:assertTrue(ok, "should succeed")
    TestRunner:assertNil(reasoning, "no reasoning")
end)

TestRunner:suite("Response Parser: Think tag extraction")

TestRunner:test("Groq extracts <think> tags from R1 responses", function()
    local response = {
        choices = { {
            message = {
                content = "<think>Reasoning here.</think>The actual answer.",
            },
        } },
    }
    local ok, content, reasoning = ResponseParser:parseResponse(response, "groq")
    TestRunner:assertTrue(ok, "should succeed")
    TestRunner:assertEqual(content, "The actual answer.", "content after tag removal")
    TestRunner:assertEqual(reasoning, "Reasoning here.", "extracted reasoning")
end)

TestRunner:test("Together extracts <think> tags", function()
    local response = {
        choices = { {
            message = {
                content = "<think>Deep thought.</think>Answer.",
            },
        } },
    }
    local ok, content, reasoning = ResponseParser:parseResponse(response, "together")
    TestRunner:assertTrue(ok, "should succeed")
    TestRunner:assertNotNil(reasoning, "should extract reasoning")
end)

TestRunner:test("Fireworks extracts <think> tags", function()
    local response = {
        choices = { {
            message = {
                content = "<Think>Thinking process.</Think>Response text.",
            },
        } },
    }
    local ok, content, reasoning = ResponseParser:parseResponse(response, "fireworks")
    TestRunner:assertTrue(ok, "should succeed")
    TestRunner:assertNotNil(reasoning, "should extract reasoning")
end)

TestRunner:test("SambaNova extracts <think> tags", function()
    local response = {
        choices = { {
            message = {
                content = "<think>R1 thinking.</think>Final output.",
            },
        } },
    }
    local ok, content, reasoning = ResponseParser:parseResponse(response, "sambanova")
    TestRunner:assertTrue(ok, "should succeed")
    TestRunner:assertNotNil(reasoning, "should extract reasoning")
end)

TestRunner:test("Perplexity extracts <think> tags from sonar-reasoning-pro", function()
    local response = {
        choices = { {
            message = {
                content = "<think>Sonar reasoning.</think>Web-grounded answer.",
            },
            finish_reason = "stop",
        } },
    }
    local ok, content, reasoning = ResponseParser:parseResponse(response, "perplexity")
    TestRunner:assertTrue(ok, "should succeed")
    TestRunner:assertNotNil(reasoning, "should extract reasoning")
    TestRunner:assertTrue(content:find("Web%-grounded"), "content should remain")
end)

--------------------------------------------------------------------------------
-- Test: Model capability checks
--------------------------------------------------------------------------------

TestRunner:suite("Model capability checks for new providers")

-- Verify all new capability entries resolve correctly
local capability_checks = {
    { "deepseek", "deepseek-chat", "thinking", true },
    { "deepseek", "deepseek-reasoner", "thinking", true },
    { "groq", "openai/gpt-oss-120b", "reasoning", true },
    { "groq", "qwen/qwen3-32b", "reasoning", true },
    { "groq", "llama-3.3-70b", "reasoning", false },
    { "together", "deepseek-ai/DeepSeek-R1", "reasoning", true },
    { "together", "Qwen/Qwen3-235B-A22B", "reasoning", true },
    { "together", "Qwen/Qwen3.5-397B-A17B", "reasoning", true },
    { "together", "meta-llama/Llama-4-Maverick", "reasoning", false },
    { "fireworks", "accounts/fireworks/models/deepseek-r1", "reasoning", true },
    { "fireworks", "accounts/fireworks/models/llama-v3p3-70b", "reasoning", false },
    { "sambanova", "DeepSeek-R1-0528", "thinking", true },
    { "sambanova", "Qwen3-32B", "thinking", true },
    { "sambanova", "Llama-4-Maverick", "thinking", false },
    { "xai", "grok-3-mini", "reasoning", true },
    { "xai", "grok-4", "reasoning", false },
    { "perplexity", "sonar-reasoning-pro", "reasoning", true },
    { "perplexity", "sonar-reasoning", "reasoning", true },
    { "perplexity", "sonar", "reasoning", false },
    { "perplexity", "sonar-pro", "reasoning", false },
    { "mistral", "magistral-medium", "thinking", true },
    { "mistral", "magistral-small", "thinking", true },
    { "mistral", "mistral-large-latest", "thinking", false },
    -- Z.AI thinking capabilities
    { "zai", "glm-5-turbo", "thinking", true },
    { "zai", "glm-5", "thinking", true },
    { "zai", "glm-4.7", "thinking", true },
    { "zai", "glm-4.7-flash", "thinking", true },
    { "zai", "glm-4.7-flashx", "thinking", true },
    { "zai", "glm-4.6", "thinking", true },
    { "zai", "glm-4.5", "thinking", true },
    { "zai", "glm-4.5-flash", "thinking", true },
    { "zai", "glm-4-plus", "thinking", false },
}

for _idx, check in ipairs(capability_checks) do
    local provider, model, cap, expected = check[1], check[2], check[3], check[4]
    TestRunner:test(string.format("%s/%s supports %s = %s", provider, model, cap, tostring(expected)), function()
        local result = ModelConstraints.supportsCapability(provider, model, cap)
        if expected then
            TestRunner:assertTrue(result, "should support capability")
        else
            TestRunner:assertFalse(result, "should not support capability")
        end
    end)
end

--------------------------------------------------------------------------------
-- Test: Reasoning defaults
--------------------------------------------------------------------------------

TestRunner:suite("Reasoning defaults for new providers")

TestRunner:test("OpenRouter defaults to high effort", function()
    TestRunner:assertEqual(ModelConstraints.reasoning_defaults.openrouter.effort, "high", "default effort")
end)

TestRunner:test("xAI has low and high effort options only", function()
    local opts = ModelConstraints.reasoning_defaults.xai.effort_options
    TestRunner:assertEqual(#opts, 2, "should have 2 options")
    TestRunner:assertEqual(opts[1], "low", "first option")
    TestRunner:assertEqual(opts[2], "high", "second option")
end)

TestRunner:test("all effort providers default to high", function()
    local providers = { "openrouter", "groq", "together", "fireworks", "perplexity" }
    for _idx, p in ipairs(providers) do
        TestRunner:assertEqual(ModelConstraints.reasoning_defaults[p].effort, "high",
            p .. " should default to high")
    end
end)

--------------------------------------------------------------------------------
-- Test: Provider categorization (always-on vs toggleable)
--------------------------------------------------------------------------------

TestRunner:suite("Provider reasoning categories")

-- Always-on models should have reasoning capability but NOT be in reasoning_gated
TestRunner:test("OpenAI o3 is reasoning-capable but not gated", function()
    TestRunner:assertTrue(
        ModelConstraints.supportsCapability("openai", "o3", "reasoning"),
        "o3 should have reasoning capability"
    )
    TestRunner:assertFalse(
        ModelConstraints.supportsCapability("openai", "o3", "reasoning_gated"),
        "o3 should NOT be gated"
    )
end)

TestRunner:test("OpenAI o4-mini is reasoning-capable but not gated", function()
    TestRunner:assertTrue(
        ModelConstraints.supportsCapability("openai", "o4-mini", "reasoning"),
        "o4-mini should have reasoning capability"
    )
    TestRunner:assertFalse(
        ModelConstraints.supportsCapability("openai", "o4-mini", "reasoning_gated"),
        "o4-mini should NOT be gated"
    )
end)

TestRunner:test("OpenAI gpt-5 is reasoning-capable but not gated", function()
    TestRunner:assertTrue(
        ModelConstraints.supportsCapability("openai", "gpt-5", "reasoning"),
        "gpt-5 should have reasoning capability"
    )
    TestRunner:assertFalse(
        ModelConstraints.supportsCapability("openai", "gpt-5", "reasoning_gated"),
        "gpt-5 should NOT be gated"
    )
end)

TestRunner:test("OpenAI gpt-5.1 IS gated (toggleable)", function()
    TestRunner:assertTrue(
        ModelConstraints.supportsCapability("openai", "gpt-5.1", "reasoning_gated"),
        "gpt-5.1 should be gated"
    )
end)

TestRunner:test("xAI grok-3-mini is always-on reasoning", function()
    TestRunner:assertTrue(
        ModelConstraints.supportsCapability("xai", "grok-3-mini", "reasoning"),
        "grok-3-mini should have reasoning"
    )
end)

TestRunner:test("Perplexity sonar-reasoning-pro is always-on reasoning", function()
    TestRunner:assertTrue(
        ModelConstraints.supportsCapability("perplexity", "sonar-reasoning-pro", "reasoning"),
        "sonar-reasoning-pro should have reasoning"
    )
end)

TestRunner:test("Mistral magistral has thinking but is always-on (no toggle)", function()
    TestRunner:assertTrue(
        ModelConstraints.supportsCapability("mistral", "magistral-medium", "thinking"),
        "magistral should have thinking capability"
    )
end)

-- Summary
return TestRunner:summary()
