-- Every parameter constraint reaches the request its handler builds.
--
-- model_constraints.lua holds forced parameter values (temperature = 1.0 for
-- models that reject any other), and tests/model_audit.lua reads them as
-- "what we send". That holds only when the provider's handler runs
-- ModelConstraints.apply: the kimi-k2.6 rule sat in the table from 2026-08-15
-- while the OpenAI-compatible handler never applied it, so every kimi chat
-- sent 0.7 and was refused. This file builds each constrained model's request
-- through its real handler, plus a custom_models.lua constraint on an
-- OpenAI-compatible provider and on a custom provider.
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
local TestRunner = require("test_runner"):new()

print("")
print(string.rep("=", 50))
print("  Unit Tests: Handler Constraints")
print(string.rep("=", 50))

local saved_user = ModelOverrides._user
ModelOverrides._setUserForTests(false)  -- no custom_models.lua from disk

-- The body the provider's handler builds (handler module defaults to the provider id)
local function build(provider, model, api_params, extra, module)
    local config = {
        provider = provider, model = model, api_key = "test-key",
        system = { text = "sys" },
        api_params = api_params or { temperature = 0.7 },
        features = { enable_streaming = false },
    }
    for k, v in pairs(extra or {}) do config[k] = v end
    local handler = require("koassistant_api." .. (module or provider))
    return handler:buildRequestBody({ { role = "user", content = "hi" } }, config).body
end

TestRunner:test("every curated constraint reaches its provider's request", function()
    local ids = {}
    for provider in pairs(Defaults.ProviderDefaults) do ids[#ids + 1] = provider end
    table.sort(ids)
    local checked = 0
    for _idx, provider in ipairs(ids) do
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

TestRunner:test("a custom_models.lua constraint reaches built-in and custom providers", function()
    ModelOverrides._setUserForTests({ constraints = {
        groq = { ["llama-x"] = { temperature = 0.2 } },
        custom_lab = { ["m1"] = { temperature = 0.3 } },
    } })
    TestRunner:assertEqual(build("groq", "llama-x-70b").temperature, 0.2, "groq")
    TestRunner:assertEqual(build("custom_lab", "m1", nil,
        { base_url = "http://localhost:1234/v1/chat/completions" }, "custom_openai").temperature, 0.3,
        "custom provider")
    TestRunner:assertEqual(build("groq", "other-model").temperature, 0.7, "unmatched model untouched")
    ModelOverrides._setUserForTests(false)
end)

ModelOverrides._setUserForTests(saved_user)

return TestRunner:summary()
