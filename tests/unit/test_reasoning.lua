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
local _ = require("koassistant_gettext")

print("")
print(string.rep("=", 50))
print("  Unit Tests: Reasoning Request Injection & Parsing")
print(string.rep("=", 50))

--------------------------------------------------------------------------------
-- Test: Handler customizeRequestBody() — reasoning parameter injection
--------------------------------------------------------------------------------

TestRunner:suite("DeepSeek thinking injection")

local DeepSeekHandler = require("deepseek")

TestRunner:test("deepseek-v4-pro supports thinking capability", function()
    TestRunner:assertTrue(
        ModelConstraints.supportsCapability("deepseek", "deepseek-v4-pro", "thinking"),
        "deepseek-v4-pro should support thinking"
    )
end)

TestRunner:test("deepseek-v4-flash supports thinking capability", function()
    TestRunner:assertTrue(
        ModelConstraints.supportsCapability("deepseek", "deepseek-v4-flash", "thinking"),
        "deepseek-v4-flash should support thinking"
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

TestRunner:suite("Requesty reasoning injection")

local RequestyHandler = require("requesty")

TestRunner:test("adds reasoning object when config present", function()
    local body = { model = "openai/gpt-5.5", messages = {} }
    local config = {
        api_params = { requesty_reasoning = { effort = "high" } },
        features = {},
    }
    local result = RequestyHandler:customizeRequestBody(body, config)
    TestRunner:assertNotNil(result.reasoning, "reasoning should be set")
    TestRunner:assertEqual(result.reasoning.effort, "high", "effort level")
end)

TestRunner:test("no reasoning object when config absent", function()
    local body = { model = "openai/gpt-5.5", messages = {} }
    local config = { api_params = {}, features = {} }
    local result = RequestyHandler:customizeRequestBody(body, config)
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
    local body = { model = "deepseek-ai/DeepSeek-V4-Pro", messages = {} }
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
    local body = { model = "DeepSeek-V3.1", messages = {} }
    local config = { api_params = { sambanova_thinking = true } }
    local result = SambaNovaHandler:customizeRequestBody(body, config)
    TestRunner:assertNotNil(result.chat_template_kwargs, "should set chat_template_kwargs")
    TestRunner:assertTrue(result.chat_template_kwargs.enable_thinking, "enable_thinking")
end)

TestRunner:test("omits chat_template_kwargs when config absent (model default)", function()
    local body = { model = "DeepSeek-V3.1", messages = {} }
    local config = { api_params = {} }
    local result = SambaNovaHandler:customizeRequestBody(body, config)
    TestRunner:assertNil(result.chat_template_kwargs, "should not set chat_template_kwargs (send nothing)")
end)

TestRunner:test("disables thinking when explicitly false", function()
    local body = { model = "DeepSeek-V3.1", messages = {} }
    local config = { api_params = { sambanova_thinking = false } }
    local result = SambaNovaHandler:customizeRequestBody(body, config)
    TestRunner:assertNotNil(result.chat_template_kwargs, "should set chat_template_kwargs")
    TestRunner:assertFalse(result.chat_template_kwargs.enable_thinking, "enable_thinking false")
end)

TestRunner:test("no thinking for unsupported model", function()
    local body = { model = "Meta-Llama-3.3-70B-Instruct", messages = {} }
    local config = { api_params = { sambanova_thinking = true } }
    local result = SambaNovaHandler:customizeRequestBody(body, config)
    TestRunner:assertNil(result.chat_template_kwargs, "should not set chat_template_kwargs")
end)

TestRunner:suite("xAI reasoning injection")

local XAIHandler = require("xai")

TestRunner:test("adds reasoning_effort for grok-4.3", function()
    local body = { model = "grok-4.3", messages = {} }
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

TestRunner:test("extracts reasoning_content from grok-4.3", function()
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
    { "deepseek", "deepseek-v4-flash", "thinking", true },
    { "deepseek", "deepseek-v4-pro", "thinking", true },
    { "groq", "openai/gpt-oss-120b", "reasoning", true },
    { "groq", "qwen/qwen3-32b", "reasoning", true },
    { "groq", "llama-3.3-70b", "reasoning", false },
    { "together", "deepseek-ai/DeepSeek-V4-Pro", "reasoning", true },
    { "together", "Qwen/Qwen3-235B-A22B", "reasoning", true },
    { "together", "Qwen/Qwen3.5-397B-A17B", "reasoning", true },
    { "together", "meta-llama/Llama-4-Maverick", "reasoning", false },
    { "fireworks", "accounts/fireworks/models/deepseek-r1", "reasoning", true },
    { "fireworks", "accounts/fireworks/models/llama-v3p3-70b", "reasoning", false },
    { "sambanova", "DeepSeek-V3.1", "thinking", true },
    { "sambanova", "DeepSeek-V3.2", "thinking", true },
    { "sambanova", "Llama-4-Maverick", "thinking", false },
    { "xai", "grok-4.3", "reasoning", true },
    { "xai", "grok-4.20-0309-reasoning", "reasoning", true },
    { "xai", "grok-4.20-0309-non-reasoning", "reasoning", false },
    { "perplexity", "sonar-reasoning-pro", "reasoning", true },
    { "perplexity", "sonar-deep-research", "reasoning", true },
    { "perplexity", "sonar", "reasoning", false },
    { "perplexity", "sonar-pro", "reasoning", false },
    { "mistral", "magistral-medium", "thinking", true },
    { "mistral", "magistral-small", "thinking", true },
    { "mistral", "mistral-large-latest", "thinking", false },
    -- Z.AI thinking capabilities
    { "zai", "glm-5.1", "thinking", true },
    { "zai", "glm-5-turbo", "thinking", true },
    { "zai", "glm-5", "thinking", true },
    { "zai", "glm-4.7", "thinking", true },
    { "zai", "glm-4.7-flash", "thinking", true },
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

TestRunner:test("xAI has low/medium/high effort options", function()
    local opts = ModelConstraints.reasoning_defaults.xai.effort_options
    TestRunner:assertEqual(#opts, 3, "should have 3 options")
    TestRunner:assertEqual(opts[1], "low", "first option")
    TestRunner:assertEqual(opts[2], "medium", "second option")
    TestRunner:assertEqual(opts[3], "high", "third option")
end)

TestRunner:test("all effort providers default to high", function()
    local providers = { "openrouter", "requesty", "groq", "together", "fireworks", "perplexity" }
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
TestRunner:test("OpenAI gpt-5.5 is reasoning-capable but not gated (category)", function()
    TestRunner:assertTrue(
        ModelConstraints.supportsCapability("openai", "gpt-5.5", "reasoning"),
        "gpt-5.5 should have reasoning capability"
    )
    TestRunner:assertFalse(
        ModelConstraints.supportsCapability("openai", "gpt-5.5", "reasoning_gated"),
        "gpt-5.5 should NOT be gated"
    )
end)

TestRunner:test("OpenAI gpt-5.4-nano is reasoning-capable and gated", function()
    TestRunner:assertTrue(
        ModelConstraints.supportsCapability("openai", "gpt-5.4-nano", "reasoning"),
        "gpt-5.4-nano should have reasoning capability"
    )
    TestRunner:assertTrue(
        ModelConstraints.supportsCapability("openai", "gpt-5.4-nano", "reasoning_gated"),
        "gpt-5.4-nano should be gated"
    )
end)

TestRunner:test("OpenAI gpt-5.5 is reasoning-capable but not gated", function()
    TestRunner:assertTrue(
        ModelConstraints.supportsCapability("openai", "gpt-5.5", "reasoning"),
        "gpt-5.5 should have reasoning capability"
    )
    TestRunner:assertFalse(
        ModelConstraints.supportsCapability("openai", "gpt-5.5", "reasoning_gated"),
        "gpt-5.5 should NOT be gated (reasons by default)"
    )
end)

TestRunner:test("OpenAI gpt-5.4 IS gated (toggleable)", function()
    TestRunner:assertTrue(
        ModelConstraints.supportsCapability("openai", "gpt-5.4", "reasoning_gated"),
        "gpt-5.4 should be gated"
    )
end)

TestRunner:test("xAI grok-4.3 is always-on reasoning", function()
    TestRunner:assertTrue(
        ModelConstraints.supportsCapability("xai", "grok-4.3", "reasoning"),
        "grok-4.3 should have reasoning"
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

--------------------------------------------------------------------------------
-- Test: Reasoning RESOLVER (resolveReasoning / applyReasoningParams / parseActionReasoning)
--------------------------------------------------------------------------------

TestRunner:suite("Reasoning profiles")

TestRunner:test("getReasoningProfile returns matching profile for known model", function()
    local p = ModelConstraints.getReasoningProfile("deepseek", "deepseek-v4-pro")
    TestRunner:assertEqual(p.axis, "binary", "deepseek axis")
    TestRunner:assertEqual(p.default_state, "on", "deepseek default on")
end)

TestRunner:test("getReasoningProfile prefix-matches dated model ids", function()
    local p = ModelConstraints.getReasoningProfile("anthropic", "claude-opus-4-8-20260115")
    TestRunner:assertEqual(p.axis, "adaptive_effort", "opus axis via prefix")
    TestRunner:assertTrue(p.needs_no_sampling, "opus needs_no_sampling")
end)

TestRunner:test("getReasoningProfile returns passthrough (none) for unknown model", function()
    local p = ModelConstraints.getReasoningProfile("openai", "totally-unknown-model")
    TestRunner:assertEqual(p.axis, "none", "unknown -> none")
    TestRunner:assertFalse(p.can_disable, "unknown not disableable")
end)

TestRunner:test("OpenRouter universal profile matches any model", function()
    local p = ModelConstraints.getReasoningProfile("openrouter", "anthropic/claude-sonnet-4.5")
    TestRunner:assertEqual(p.axis, "effort", "openrouter axis")
end)

TestRunner:suite("resolveReasoning: global stance")

TestRunner:test("Minimal turns DeepSeek V4 OFF (explicit disable, not send_nothing)", function()
    local d = ModelConstraints.resolveReasoning("deepseek", "deepseek-v4-pro", { global_stance = "minimal" })
    TestRunner:assertEqual(d.mode, "off", "mode off")
    TestRunner:assertFalse(d.send_nothing, "must emit explicit disable")
    local params = {}
    ModelConstraints.applyReasoningParams("deepseek", params, d)
    TestRunner:assertNotNil(params.deepseek_thinking, "deepseek_thinking set")
    TestRunner:assertEqual(params.deepseek_thinking.type, "disabled", "type disabled")
end)

TestRunner:test("Default stance leaves DeepSeek natural (send_nothing, no param)", function()
    local d = ModelConstraints.resolveReasoning("deepseek", "deepseek-v4-pro", { global_stance = "default" })
    TestRunner:assertTrue(d.send_nothing, "send_nothing")
    local params = {}
    ModelConstraints.applyReasoningParams("deepseek", params, d)
    TestRunner:assertNil(params.deepseek_thinking, "no thinking param -> model default")
end)

TestRunner:test("Maximum on Opus 4.8 -> max effort, needs_no_sampling", function()
    local d = ModelConstraints.resolveReasoning("anthropic", "claude-opus-4-8", { global_stance = "maximum" })
    TestRunner:assertEqual(d.mode, "on", "on")
    TestRunner:assertEqual(d.effort, "max", "max effort")
    TestRunner:assertTrue(d.needs_no_sampling, "needs_no_sampling")
    local params = {}
    ModelConstraints.applyReasoningParams("anthropic", params, d)
    TestRunner:assertEqual(params.thinking.type, "adaptive", "adaptive thinking")
    TestRunner:assertEqual(params.output_config.effort, "max", "output_config effort")
end)

TestRunner:test("Maximum on Sonnet 4.6 -> high effort (no max), needs_temp_1", function()
    local d = ModelConstraints.resolveReasoning("anthropic", "claude-sonnet-4-6", { global_stance = "maximum" })
    TestRunner:assertEqual(d.effort, "high", "high effort (sonnet has no max)")
    TestRunner:assertTrue(d.needs_temp_1, "needs_temp_1")
    TestRunner:assertFalse(d.needs_no_sampling, "sonnet keeps sampling params")
end)

TestRunner:test("Maximum on Sonnet 5 -> max effort, needs_no_sampling (NOT needs_temp_1)", function()
    -- Sonnet 5 is a Sonnet that behaves like Opus 4.7/4.8 for sampling: rejects
    -- temperature/top_p/top_k (needs_no_sampling), and supports the full effort ladder
    -- incl. xhigh/max. It must NOT set needs_temp_1 (unlike Sonnet 4.6).
    local d = ModelConstraints.resolveReasoning("anthropic", "claude-sonnet-5", { global_stance = "maximum" })
    TestRunner:assertEqual(d.mode, "on", "on")
    TestRunner:assertEqual(d.effort, "max", "max effort supported on Sonnet 5")
    TestRunner:assertTrue(d.needs_no_sampling, "needs_no_sampling")
    TestRunner:assertFalse(d.needs_temp_1, "must NOT force temp=1.0 (sampling is stripped)")
    local params = {}
    ModelConstraints.applyReasoningParams("anthropic", params, d)
    TestRunner:assertEqual(params.thinking.type, "adaptive", "adaptive thinking")
    TestRunner:assertEqual(params.output_config.effort, "max", "output_config effort")
end)

TestRunner:test("Default stance on Sonnet 5 -> send_nothing but natural state is ON", function()
    -- Unlike the Opus family (default off), Sonnet 5's API default is adaptive-ON.
    -- Default stance still sends nothing (model runs its own default), but the reported
    -- mode is "on" so the UI truthfully shows it thinks by default.
    local d = ModelConstraints.resolveReasoning("anthropic", "claude-sonnet-5", { global_stance = "default" })
    TestRunner:assertTrue(d.send_nothing, "default stance emits nothing")
    TestRunner:assertEqual(d.mode, "on", "natural state reported as on")
    local params = {}
    ModelConstraints.applyReasoningParams("anthropic", params, d)
    TestRunner:assertNil(params.thinking, "send_nothing -> no thinking param emitted")
end)

TestRunner:test("Minimal on Sonnet 5 -> explicit disable param (not omission)", function()
    -- Because Sonnet 5 thinks by default, an off decision must emit thinking={type=disabled},
    -- NOT rely on omission (which would still think). Distinct from the Opus family.
    local d = ModelConstraints.resolveReasoning("anthropic", "claude-sonnet-5", { global_stance = "minimal" })
    TestRunner:assertEqual(d.mode, "off", "minimal disables")
    TestRunner:assertFalse(d.send_nothing, "must emit an explicit disable")
    local params = {}
    ModelConstraints.applyReasoningParams("anthropic", params, d)
    TestRunner:assertNotNil(params.thinking, "explicit disable param emitted")
    TestRunner:assertEqual(params.thinking.type, "disabled", "thinking type disabled")
end)

TestRunner:test("Minimal on Gemini 2.5 -> thinking_budget 0", function()
    local d = ModelConstraints.resolveReasoning("gemini", "gemini-2.5-flash", { global_stance = "minimal" })
    TestRunner:assertEqual(d.mode, "off", "off")
    local params = {}
    ModelConstraints.applyReasoningParams("gemini", params, d)
    TestRunner:assertEqual(params.thinking_budget, 0, "explicit budget 0")
end)

TestRunner:test("Maximum on Gemini 2.5 -> max budget", function()
    local d = ModelConstraints.resolveReasoning("gemini", "gemini-2.5-flash", { global_stance = "maximum" })
    TestRunner:assertEqual(d.budget, 24576, "max budget value")
    local params = {}
    ModelConstraints.applyReasoningParams("gemini", params, d)
    TestRunner:assertEqual(params.thinking_budget, 24576, "thinking_budget applied")
end)

TestRunner:test("Minimal on Gemini 3 flash -> minimal level (can't disable)", function()
    local d = ModelConstraints.resolveReasoning("gemini", "gemini-3.5-flash", { global_stance = "minimal" })
    TestRunner:assertEqual(d.mode, "on", "still on")
    TestRunner:assertEqual(d.effort, "minimal", "minimal level")
    local params = {}
    ModelConstraints.applyReasoningParams("gemini", params, d)
    TestRunner:assertEqual(params.thinking_level, "minimal", "thinkingLevel minimal")
end)

TestRunner:suite("resolveReasoning: can't-disable clamping")

TestRunner:test("Perplexity Minimal cannot disable -> on at lowest effort", function()
    local d = ModelConstraints.resolveReasoning("perplexity", "sonar-reasoning-pro", { global_stance = "minimal" })
    TestRunner:assertEqual(d.mode, "on", "clamped on")
    TestRunner:assertEqual(d.effort, "low", "lowest effort")
end)

TestRunner:test("Perplexity action force-off cannot truly disable -> on at lowest", function()
    local d = ModelConstraints.resolveReasoning("perplexity", "sonar-reasoning-pro", {
        global_stance = "default",
        action_override = { force = "off" },
    })
    TestRunner:assertEqual(d.mode, "on", "force-off clamped to on")
    TestRunner:assertEqual(d.effort, "low", "lowest effort")
end)

TestRunner:test("Mistral Magistral: axis none, send_nothing, emits nothing", function()
    local d = ModelConstraints.resolveReasoning("mistral", "magistral-medium", { global_stance = "maximum" })
    TestRunner:assertEqual(d.axis, "none", "axis none")
    TestRunner:assertTrue(d.send_nothing, "send_nothing")
    local params = {}
    ModelConstraints.applyReasoningParams("mistral", params, d)
    TestRunner:assertNil(next(params), "no params emitted")
end)

TestRunner:suite("resolveReasoning: precedence layering")

TestRunner:test("model_pref beats stance", function()
    local d = ModelConstraints.resolveReasoning("anthropic", "claude-opus-4-8", {
        global_stance = "maximum",            -- would be max
        model_pref = { effort = "medium" },   -- wins
    })
    TestRunner:assertEqual(d.effort, "medium", "model_pref wins over stance")
end)

TestRunner:test("stance applies when no model_pref", function()
    local d = ModelConstraints.resolveReasoning("deepseek", "deepseek-v4-pro", {
        global_stance = "minimal",
    })
    TestRunner:assertEqual(d.mode, "off", "minimal stance off when no model pref")
end)

TestRunner:test("action force-off beats global Maximum on Opus", function()
    local d = ModelConstraints.resolveReasoning("anthropic", "claude-opus-4-8", {
        global_stance = "maximum",
        model_pref = { state = "on", effort = "high" },
        action_override = { force = "off" },
    })
    TestRunner:assertEqual(d.mode, "off", "action force-off wins over everything")
    local params = {}
    ModelConstraints.applyReasoningParams("anthropic", params, d)
    TestRunner:assertNil(params.thinking, "no thinking param when off")
end)

TestRunner:test("action force-on at effort beats global Minimal", function()
    local d = ModelConstraints.resolveReasoning("openai", "gpt-5.4", {
        global_stance = "minimal",
        action_override = { force = "on", effort = "high" },
    })
    TestRunner:assertEqual(d.mode, "on", "forced on")
    TestRunner:assertEqual(d.effort, "high", "forced effort")
end)

TestRunner:suite("resolveReasoning: 'Model API default' sentinel ({state='default'})")

TestRunner:test("sentinel suppresses Maximum stance (send_nothing, no params)", function()
    local d = ModelConstraints.resolveReasoning("anthropic", "claude-sonnet-5", {
        global_stance = "maximum",
        model_pref = { state = "default" },
    })
    TestRunner:assertTrue(d.send_nothing, "sentinel -> send_nothing despite Maximum stance")
    local params = {}
    ModelConstraints.applyReasoningParams("anthropic", params, d)
    TestRunner:assertNil(params.thinking, "no thinking param")
    TestRunner:assertNil(params.output_config, "no output_config")
end)

TestRunner:test("sentinel suppresses Minimal stance on binary axis (no disable param)", function()
    local d = ModelConstraints.resolveReasoning("deepseek", "deepseek-v4-pro", {
        global_stance = "minimal",           -- would emit an explicit disable
        model_pref = { state = "default" },  -- sentinel: emit nothing instead
    })
    TestRunner:assertTrue(d.send_nothing, "send_nothing")
    local params = {}
    ModelConstraints.applyReasoningParams("deepseek", params, d)
    TestRunner:assertNil(next(params), "no params emitted")
end)

TestRunner:test("sentinel on budget axis emits nothing", function()
    local d = ModelConstraints.resolveReasoning("anthropic", "claude-haiku-4-5", {
        global_stance = "maximum",
        model_pref = { state = "default" },
    })
    TestRunner:assertTrue(d.send_nothing, "send_nothing on budget axis")
    local params = {}
    ModelConstraints.applyReasoningParams("anthropic", params, d)
    TestRunner:assertNil(params.thinking, "no thinking param")
end)

TestRunner:test("sentinel reports the model's natural state as mode", function()
    -- Sonnet 5 default_state=on, Haiku 4.5 default_state=off: mode mirrors reality
    local d5 = ModelConstraints.resolveReasoning("anthropic", "claude-sonnet-5", {
        global_stance = "minimal", model_pref = { state = "default" },
    })
    TestRunner:assertEqual(d5.mode, "on", "sonnet-5 naturally on")
    local dh = ModelConstraints.resolveReasoning("anthropic", "claude-haiku-4-5", {
        global_stance = "maximum", model_pref = { state = "default" },
    })
    TestRunner:assertEqual(dh.mode, "off", "haiku naturally off")
end)

TestRunner:test("action override still beats the sentinel", function()
    local d = ModelConstraints.resolveReasoning("anthropic", "claude-sonnet-5", {
        global_stance = "default",
        model_pref = { state = "default" },
        action_override = { force = "on", effort = "max" },
    })
    TestRunner:assertFalse(d.send_nothing, "action override wins")
    TestRunner:assertEqual(d.effort, "max", "forced effort applied")
end)

TestRunner:test("summaryLabel for sentinel says Model default", function()
    local ReasoningPrefs = require("reasoning_prefs")
    local f = { reasoning_prefs = { stance = "maximum", models = {
        ["deepseek/deepseek-v4-pro"] = { state = "default" },
    } } }
    TestRunner:assertEqual(ReasoningPrefs.summaryLabel(f, "deepseek", "deepseek-v4-pro"),
        _("Default"), "sentinel label")
end)

TestRunner:suite("parseActionReasoning")

TestRunner:test("string 'off' -> force off", function()
    local o = ModelConstraints.parseActionReasoning({ reasoning_config = "off" }, "anthropic")
    TestRunner:assertEqual(o.force, "off", "force off")
end)

TestRunner:test("{ default = 'off' } -> force off (regression: latent bug)", function()
    local o = ModelConstraints.parseActionReasoning({ reasoning_config = { default = "off" } }, "deepseek")
    TestRunner:assertNotNil(o, "should not be nil")
    TestRunner:assertEqual(o.force, "off", "default off honoured")
    -- end-to-end: suggest_from_library-style action now actually disables DeepSeek
    local d = ModelConstraints.resolveReasoning("deepseek", "deepseek-v4-pro", {
        global_stance = "maximum", action_override = o,
    })
    TestRunner:assertEqual(d.mode, "off", "resolves to off")
end)

TestRunner:test("per-provider entry overrides default", function()
    local rc = { default = "off", anthropic = { effort = "high" } }
    local a = ModelConstraints.parseActionReasoning({ reasoning_config = rc }, "anthropic")
    TestRunner:assertEqual(a.force, "on", "anthropic forced on")
    TestRunner:assertEqual(a.effort, "high", "effort high")
    local g = ModelConstraints.parseActionReasoning({ reasoning_config = rc }, "gemini")
    TestRunner:assertEqual(g.force, "off", "gemini falls to default off")
end)

TestRunner:test("gemini 'level' maps to effort", function()
    local o = ModelConstraints.parseActionReasoning({ reasoning_config = { gemini = { level = "low" } } }, "gemini")
    TestRunner:assertEqual(o.force, "on", "on")
    TestRunner:assertEqual(o.effort, "low", "level -> effort")
end)

TestRunner:test("legacy reasoning='off' -> force off", function()
    local o = ModelConstraints.parseActionReasoning({ reasoning = "off" }, "openai")
    TestRunner:assertEqual(o.force, "off", "legacy off")
end)

TestRunner:test("no reasoning config -> nil (inherit)", function()
    local o = ModelConstraints.parseActionReasoning({}, "openai")
    TestRunner:assertNil(o, "nil inherit")
end)

TestRunner:suite("applyReasoningParams: xAI off via 'none'")

TestRunner:test("xAI force-off sends effort 'none'", function()
    local d = ModelConstraints.resolveReasoning("xai", "grok-4.3", {
        global_stance = "default", action_override = { force = "off" },
    })
    TestRunner:assertEqual(d.mode, "off", "off")
    local params = {}
    ModelConstraints.applyReasoningParams("xai", params, d)
    TestRunner:assertEqual(params.xai_reasoning.effort, "none", "effort none")
end)

--------------------------------------------------------------------------------
-- Test: ReasoningPrefs store (accessors / mutators / display)
--------------------------------------------------------------------------------

TestRunner:suite("ReasoningPrefs store")

local ReasoningPrefs = require("reasoning_prefs")

TestRunner:test("modelKey composes provider/model", function()
    TestRunner:assertEqual(ReasoningPrefs.modelKey("anthropic", "claude-opus-4-8"),
        "anthropic/claude-opus-4-8", "key format")
end)

TestRunner:test("getStance defaults to 'default' when unset", function()
    TestRunner:assertEqual(ReasoningPrefs.getStance({}), "default", "empty -> default")
    TestRunner:assertEqual(ReasoningPrefs.getStance({ reasoning_prefs = { stance = "bogus" } }),
        "default", "invalid -> default")
end)

TestRunner:test("setStance / getStance round-trip", function()
    local f = {}
    ReasoningPrefs.setStance(f, "minimal")
    TestRunner:assertEqual(ReasoningPrefs.getStance(f), "minimal", "stance saved")
    TestRunner:assertNil(f.reasoning_prefs.models, "stance set does not create models")
end)

TestRunner:test("model pref set / get / clear (keyed by provider/model)", function()
    local f = {}
    ReasoningPrefs.setModelPref(f, "deepseek", "deepseek-v4-pro", { state = "off" })
    TestRunner:assertEqual(ReasoningPrefs.getModelPref(f, "deepseek", "deepseek-v4-pro").state, "off", "saved")
    TestRunner:assertNil(ReasoningPrefs.getModelPref(f, "deepseek", "deepseek-v4-flash"), "other model unaffected")
    ReasoningPrefs.clearModelPref(f, "deepseek", "deepseek-v4-pro")
    TestRunner:assertNil(ReasoningPrefs.getModelPref(f, "deepseek", "deepseek-v4-pro"), "cleared")
end)

TestRunner:test("two features tables stay independent (no aliasing)", function()
    local a, b = {}, {}
    ReasoningPrefs.setModelPref(a, "deepseek", "deepseek-v4-pro", { state = "off" })
    TestRunner:assertNil(ReasoningPrefs.getModelPref(b, "deepseek", "deepseek-v4-pro"), "b unaffected")
end)

TestRunner:test("resolve applies stored model pref", function()
    local f = {}
    ReasoningPrefs.setModelPref(f, "deepseek", "deepseek-v4-pro", { state = "off" })
    local d = ReasoningPrefs.resolve(f, "deepseek", "deepseek-v4-pro")
    TestRunner:assertEqual(d.mode, "off", "model pref off resolves off")
end)

TestRunner:test("summaryLabel reflects effective state", function()
    local f = {}
    -- default stance, deepseek thinks naturally -> "Default" (send_nothing label)
    TestRunner:assertEqual(ReasoningPrefs.summaryLabel(f, "deepseek", "deepseek-v4-pro"), _("Default"), "default")
    ReasoningPrefs.setStance(f, "minimal")
    TestRunner:assertEqual(ReasoningPrefs.summaryLabel(f, "deepseek", "deepseek-v4-pro"), _("Off"), "minimal -> off")
    -- Opus at maximum shows the effort level
    ReasoningPrefs.setStance(f, "maximum")
    TestRunner:assertEqual(ReasoningPrefs.summaryLabel(f, "anthropic", "claude-opus-4-8"), _("Max"), "maximum -> Max")
    -- Mistral always on
    TestRunner:assertEqual(ReasoningPrefs.summaryLabel(f, "mistral", "magistral-medium"), _("Always on"), "mistral")
end)

TestRunner:suite("B4: quiz reasoning disabled on adaptive-default-ON models")

TestRunner:test("quiz action reasoning_config='off' emits thinking disabled on sonnet-5", function()
    local Actions = require("prompts.actions")
    local quiz = Actions.getById("quiz")
    TestRunner:assertNotNil(quiz, "quiz action exists")
    TestRunner:assertEqual(quiz.reasoning_config, "off", "quiz pins reasoning off")

    -- claude-sonnet-5 is adaptive-thinking default ON; without the pin its thinking tokens
    -- bill against the quiz's 4096 max_tokens and truncate the JSON (broken quiz viewer).
    local ao = ModelConstraints.parseActionReasoning(quiz, "anthropic")
    local dec = ModelConstraints.resolveReasoning("anthropic", "claude-sonnet-5",
        { action_override = ao, global_stance = "default" })
    TestRunner:assertEqual(dec.mode, "off", "decision off")
    TestRunner:assertFalse(dec.send_nothing, "must actively disable, not send nothing")

    local api = {}
    ModelConstraints.applyReasoningParams("anthropic", api, dec)
    TestRunner:assertNotNil(api.thinking, "thinking param present")
    TestRunner:assertEqual(api.thinking.type, "disabled",
        "thinking disabled so it can't consume the quiz max_tokens budget")
end)

-- Summary
return TestRunner:summary()
