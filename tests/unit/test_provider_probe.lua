-- Test provider sends what a real request sends (koassistant_provider_probe.lua).
--
-- The probe used to write its own OpenAI-shaped requests, so it tested requests
-- the plugin never sends: DeepSeek's "Forced tool use" failed on every model
-- ("Thinking mode does not support this tool_choice") while book tools worked,
-- because book-tools rounds switch DeepSeek's thinking off and the probe did
-- not. Each step is now built by the provider's own handler on the config the
-- router builds; these tests pin the shapes that matter.
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

local ConfigHelper = require("koassistant_config_helper")
local ModelOverrides = require("koassistant_model_overrides")
local ProviderProbe = require("koassistant_provider_probe")
local json = require("json")
local TestRunner = require("test_runner"):new()

print("")
print(string.rep("=", 50))
print("  Unit Tests: Provider Probe")
print(string.rep("=", 50))

local saved_user, saved_derived = ModelOverrides._user, ModelOverrides._derived
ModelOverrides._setUserForTests(false)     -- no custom_models.lua from disk
ModelOverrides._setDerivedForTests(false)  -- no learned capabilities from disk

-- One probe step as testProvider builds it: the router's merge, then the handler
--   opts: features, provider_settings, api_key (false = none), base_url, module
local function probe(provider, model, step, opts)
    opts = opts or {}
    local api_key = "test-key"
    if opts.api_key == false then api_key = nil end
    local base = ConfigHelper:mergeWithDefaults({
        provider = provider, model = model, api_key = api_key,
        features = opts.features or {}, provider_settings = opts.provider_settings,
    })
    if opts.base_url then base.base_url = opts.base_url end
    local handler = require("koassistant_api." .. (opts.module or provider))
    local req = ProviderProbe.request(handler, base, step)
    return req, json.decode(req.payload)
end

TestRunner:test("DeepSeek's tool steps switch thinking off, as book tools do", function()
    local _req, forced = probe("deepseek", "deepseek-v4-pro", "forced_tools")
    TestRunner:assertEqual(forced.thinking and forced.thinking.type, "disabled", "forced: thinking")
    TestRunner:assertEqual(forced.tool_choice, "required", "forced: tool_choice")
    TestRunner:assertEqual(forced.tools[1]["function"].name, "ping", "forced: declaration")
    local _r2, auto = probe("deepseek", "deepseek-v4-pro", "tools")
    TestRunner:assertEqual(auto.tool_choice, "auto", "tools: tool_choice")
    TestRunner:assertEqual(auto.thinking and auto.thinking.type, "disabled", "tools: thinking")
    local _r3, plain = probe("deepseek", "deepseek-v4-pro", "plain")
    TestRunner:assertEqual(plain.thinking, nil, "plain: model default thinking")
    TestRunner:assertEqual(plain.tools, nil, "plain: no tools")
    TestRunner:assertEqual(plain.max_tokens, 16, "plain: small pin")
end)

TestRunner:test("Kimi's tool steps drop thinking and temperature; its plain step sends 1", function()
    local _req, forced = probe("kimi", "kimi-k2.6", "forced_tools")
    TestRunner:assertEqual(forced.thinking and forced.thinking.type, "disabled", "forced: thinking")
    TestRunner:assertEqual(forced.temperature, nil, "forced: no temperature")
    local _r2, plain = probe("kimi", "kimi-k2.6", "plain")
    TestRunner:assertEqual(plain.temperature, 1, "plain: the forced temperature")
    local china = probe("kimi", "kimi-k2.6", "plain", { features = { kimi_region = "china" } })
    TestRunner:assertEqual(china.url, "https://api.moonshot.cn/v1/chat/completions", "region host")
end)

TestRunner:test("OpenAI and xAI book tools take the Responses endpoint", function()
    local tools_req, tools = probe("openai", "gpt-5.6-terra", "tools")
    TestRunner:assertTrue(tools_req.responses, "openai tools: responses flag")
    TestRunner:assertEqual(tools_req.url, "https://api.openai.com/v1/responses", "openai tools: url")
    TestRunner:assertEqual(tools.tools[1].name, "ping", "openai tools: flat declaration")
    local plain_req, plain = probe("openai", "gpt-5.6-terra", "plain")
    TestRunner:assertFalse(plain_req.responses, "openai plain: chat route")
    TestRunner:assertEqual(plain_req.url, "https://api.openai.com/v1/chat/completions", "openai plain: url")
    TestRunner:assertEqual(plain.max_completion_tokens, 16, "openai plain: renamed token field")
    TestRunner:assertEqual(plain.max_tokens, nil, "openai plain: no max_tokens")
    local xai_req, xai = probe("xai", "grok-4.6", "forced_tools")
    TestRunner:assertEqual(xai_req.url, "https://api.x.ai/v1/responses", "xai forced: url")
    TestRunner:assertEqual(xai.tool_choice, "required", "xai forced: tool_choice")
end)

TestRunner:test("web search stays off even when it is on globally", function()
    local req, body = probe("openai", "gpt-5.6-terra", "plain", { features = { enable_web_search = true } })
    TestRunner:assertFalse(req.responses, "chat route")
    TestRunner:assertEqual(body.tools, nil, "no web search tool")
end)

TestRunner:test("streaming, effort and the request basics", function()
    local stream_req, stream = probe("groq", "openai/gpt-oss-120b", "stream")
    TestRunner:assertEqual(stream.stream, true, "stream flag")
    TestRunner:assertEqual(stream_req.headers["Accept"], "text/event-stream", "Accept header")
    TestRunner:assertEqual(stream_req.headers["Content-Length"], tostring(#stream_req.payload), "Content-Length")
    TestRunner:assertEqual(stream_req.headers["Authorization"], "Bearer test-key", "Bearer auth")
    local _req, effort = probe("groq", "openai/gpt-oss-120b", "effort")
    TestRunner:assertEqual(effort.reasoning_effort, "low", "effort parameter")
    local _r2, warm = probe("groq", "openai/gpt-oss-120b", "plain", { features = { default_temperature = 0.3 } })
    TestRunner:assertEqual(warm.temperature, 0.3, "the user's default temperature")
end)

TestRunner:test("custom providers use their own URL; no key, no Authorization", function()
    local url = "http://localhost:1234/v1/chat/completions"
    local req, body = probe("custom_lab", "m1", "plain", { module = "custom_openai", base_url = url, api_key = false })
    TestRunner:assertEqual(req.url, url, "custom url")
    TestRunner:assertEqual(body.model, "m1", "custom model")
    TestRunner:assertEqual(req.headers["Authorization"], nil, "keyless")
end)

TestRunner:test("a configuration.lua base_url reaches the probe as it reaches the wire", function()
    local proxy = "https://proxy.example/v1/chat/completions"
    local req = probe("kimi", "kimi-k2.6", "plain", {
        features = { kimi_region = "china" }, provider_settings = { kimi = { base_url = proxy } },
    })
    TestRunner:assertEqual(req.url, proxy, "override beats the region")
end)

ModelOverrides._setUserForTests(saved_user)
ModelOverrides._setDerivedForTests(saved_derived)

return TestRunner:summary()
