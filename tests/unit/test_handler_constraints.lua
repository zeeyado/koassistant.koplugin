-- Every parameter constraint reaches the request its handler builds.
--
-- model_constraints.lua holds forced parameter values (temperature = 1.0 for
-- models that reject any other), and tests/model_audit.lua reads them as
-- "what we send". That holds only when the provider's handler runs
-- ModelConstraints.apply: the kimi-k2.6 rule sat in the table from 2026-08-15
-- while the OpenAI-compatible handler never applied it, so every kimi chat
-- sent 0.7 and was refused. This file builds each constrained model's request
-- through its real handler, then a custom_models.lua constraint through every
-- built-in provider, a custom provider, the bodies Ollama and Cohere build a
-- second time on the way to the wire, and xAI's Responses route.
--
-- Run: lua tests/run_tests.lua --unit

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
end

setupPaths()
require("mock_koreader")

local ModelConstraints = require("model_constraints")
local ModelOverrides = require("koassistant_model_overrides")
local Defaults = require("koassistant_api.defaults")
local json = require("json")
local TestRunner = require("test_runner"):new()

print("")
print(string.rep("=", 50))
print("  Unit Tests: Handler Constraints")
print(string.rep("=", 50))

local saved_user = ModelOverrides._user
ModelOverrides._setUserForTests(false)  -- no custom_models.lua from disk

local MESSAGES = { { role = "user", content = "hi" } }

local function makeConfig(provider, model, api_params, extra)
    local config = {
        provider = provider, model = model, api_key = "test-key",
        system = { text = "sys" },
        api_params = api_params or { temperature = 0.7 },
        features = { enable_streaming = false },
    }
    for k, v in pairs(extra or {}) do config[k] = v end
    return config
end

-- The body the provider's handler builds (handler module defaults to the provider id)
local function build(provider, model, api_params, extra, module)
    local handler = require("koassistant_api." .. (module or provider))
    return handler:buildRequestBody(MESSAGES, makeConfig(provider, model, api_params, extra)).body
end

-- Where a body carries its temperature (Gemini: generationConfig, Ollama: options)
local function sentTemperature(body)
    if type(body.generationConfig) == "table" then return body.generationConfig.temperature end
    if type(body.options) == "table" then return body.options.temperature end
    return body.temperature
end

local function sortedProviders()
    local ids = {}
    for provider in pairs(Defaults.ProviderDefaults) do ids[#ids + 1] = provider end
    table.sort(ids)
    return ids
end

-- A custom_models.lua temperature rule for every built-in provider and one custom provider
local SWEPT = 0.42
local function sweepRules()
    local constraints = { custom_lab = { ["m1"] = { temperature = 0.3 } } }
    for provider in pairs(Defaults.ProviderDefaults) do
        constraints[provider] = { ["sweep-model"] = { temperature = SWEPT } }
    end
    return { constraints = constraints }
end

TestRunner:test("every curated constraint reaches its provider's request", function()
    local checked = 0
    for _idx, provider in ipairs(sortedProviders()) do
        local forced_by_model = ModelConstraints[provider]
        if type(forced_by_model) == "table" then
            for prefix, forced in pairs(forced_by_model) do
                if type(prefix) == "string" and prefix:sub(1, 1) ~= "_" and type(forced) == "table" then
                    local body = build(provider, prefix)
                    for param, value in pairs(forced) do
                        -- Sent with the forced value, or not sent at all (the OpenAI
                        -- Subscription handler sends no temperature); never another value
                        if body[param] ~= nil then
                            TestRunner:assertEqual(body[param], value, provider .. "/" .. prefix .. " " .. param)
                        end
                        checked = checked + 1
                    end
                end
            end
        end
    end
    TestRunner:assertTrue(checked > 0, "found curated constraints to check")
end)

TestRunner:test("Anthropic's provider maximum caps temperature", function()
    TestRunner:assertEqual(build("anthropic", "claude-haiku-4-5", { temperature = 1.5 }).temperature, 1.0,
        "1.5 capped")
end)

TestRunner:test("kimi drops the forced temperature when thinking is off", function()
    TestRunner:assertEqual(build("kimi", "kimi-k2.6",
        { temperature = 0.7, kimi_thinking = { type = "disabled" } }).temperature, nil, "thinking off")
    TestRunner:assertEqual(build("kimi", "kimi-k2.6", nil, { tools = {
        specs = { { name = "toc", description = "d", parameters = { type = "object" } } }, mode = "ANY",
    } }).temperature, nil, "tool session")
end)

TestRunner:test("a custom_models.lua constraint reaches every built-in and a custom provider", function()
    ModelOverrides._setUserForTests(sweepRules())
    for _idx, provider in ipairs(sortedProviders()) do
        local expected = SWEPT
        if provider == "openai_codex" then expected = nil end  -- sends no temperature at all
        -- A bare id on Perplexity is a preset, which carries its own sampling (the
        -- direct-model case is in test_perplexity_agent.lua)
        if provider == "perplexity" then expected = nil end
        TestRunner:assertEqual(sentTemperature(build(provider, "sweep-model")), expected, provider)
    end
    TestRunner:assertEqual(build("custom_lab", "m1", nil,
        { base_url = "http://localhost:1234/v1/chat/completions" }, "custom_openai").temperature, 0.3,
        "custom provider")
    TestRunner:assertEqual(build("groq", "other-model").temperature, 0.7, "unmatched model untouched")
    ModelOverrides._setUserForTests(false)
end)

TestRunner:test("Ollama's and Cohere's wire copies and xAI's Responses route apply it too", function()
    ModelOverrides._setUserForTests(sweepRules())
    -- Both build the body again inside query(); capture what would be sent
    for _idx, provider in ipairs({ "ollama", "cohere" }) do
        for _j, streaming in ipairs({ false, true }) do
            local handler = require("koassistant_api." .. provider)
            local own = rawget(handler, "backgroundRequest")
            local sent
            rawset(handler, "backgroundRequest", function(_self, _url, _headers, body)
                sent = body
                return function() end
            end)
            -- num_ctx given, so Ollama never asks a server for its window
            local ok, err = pcall(handler.query, handler, MESSAGES, makeConfig(provider, "sweep-model",
                { temperature = 0.7, num_ctx = 8192 }, { features = { enable_streaming = streaming } }))
            rawset(handler, "backgroundRequest", own)
            local label = provider .. (streaming and " streamed" or " not streamed")
            TestRunner:assertTrue(ok, label .. ": " .. tostring(err))
            TestRunner:assertEqual(sentTemperature(json.decode(sent)), SWEPT, label)
        end
    end
    local xai = require("koassistant_api.xai")
    TestRunner:assertEqual(xai:buildResponsesRequest(MESSAGES, makeConfig("xai", "sweep-model"),
        "sweep-model").body.temperature, SWEPT, "xai Responses")
    ModelOverrides._setUserForTests(false)
end)

ModelOverrides._setUserForTests(saved_user)

return TestRunner:summary()
