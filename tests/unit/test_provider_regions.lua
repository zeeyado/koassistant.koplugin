-- Region settings reach the wire (Z.AI, Qwen, Kimi).
--
-- These handlers route by features.<provider>_region unless config.base_url is
-- set, which they read as the user's own override (configuration.lua). The
-- router's merge used to copy the shipped default into config.base_url for
-- every provider, so the region was never consulted and every region went to
-- the international host (a China Kimi or Qwen key then fails there). Only an
-- override the user set reaches config.base_url now; every handler falls back
-- to its own default.
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
local Defaults = require("koassistant_api.defaults")
local TestRunner = require("test_runner"):new()

print("")
print(string.rep("=", 50))
print("  Unit Tests: Provider Regions")
print(string.rep("=", 50))

-- The URL the provider's handler puts on the wire, after the router's merge
local function wireUrl(provider, features, provider_settings)
    local merged = ConfigHelper:mergeWithDefaults({
        provider = provider, features = features or {}, provider_settings = provider_settings,
    })
    local handler = require("koassistant_api." .. provider)
    return handler:buildRequestBody({ { role = "user", content = "hi" } }, merged).url
end

local REGIONS = {
    { "zai", {
        international = "https://api.z.ai/api/paas/v4/chat/completions",
        china = "https://open.bigmodel.cn/api/paas/v4/chat/completions",
    } },
    { "qwen", {
        international = "https://dashscope-intl.aliyuncs.com/compatible-mode/v1/chat/completions",
        china = "https://dashscope.aliyuncs.com/compatible-mode/v1/chat/completions",
        us = "https://dashscope-us.aliyuncs.com/compatible-mode/v1/chat/completions",
    } },
    { "kimi", {
        international = "https://api.moonshot.ai/v1/chat/completions",
        china = "https://api.moonshot.cn/v1/chat/completions",
    } },
}

TestRunner:test("each region setting routes the wire", function()
    for _idx, entry in ipairs(REGIONS) do
        local provider, endpoints = entry[1], entry[2]
        for region, url in pairs(endpoints) do
            TestRunner:assertEqual(wireUrl(provider, { [provider .. "_region"] = region }), url,
                provider .. " " .. region)
        end
    end
end)

TestRunner:test("no region set goes to the international host", function()
    for _idx, entry in ipairs(REGIONS) do
        TestRunner:assertEqual(wireUrl(entry[1]), entry[2].international, entry[1])
    end
end)

TestRunner:test("a configuration.lua base_url still beats the region", function()
    local proxy = "https://proxy.example/v1/chat/completions"
    for _idx, entry in ipairs(REGIONS) do
        local provider = entry[1]
        TestRunner:assertEqual(wireUrl(provider, { [provider .. "_region"] = "china" },
            { [provider] = { base_url = proxy } }), proxy, provider)
    end
end)

TestRunner:test("every built-in provider keeps its default URL, and the merge sets none", function()
    local ids = {}
    for provider in pairs(Defaults.ProviderDefaults) do ids[#ids + 1] = provider end
    table.sort(ids)
    for _idx, provider in ipairs(ids) do
        local merged = ConfigHelper:mergeWithDefaults({ provider = provider, features = {} })
        TestRunner:assertEqual(merged.base_url, nil, provider .. " config.base_url")
        local default = Defaults.ProviderDefaults[provider].base_url
        local url = wireUrl(provider)
        -- Gemini appends the model to its base
        TestRunner:assertTrue(type(url) == "string" and url:sub(1, #default) == default,
            provider .. " wire url " .. tostring(url))
    end
end)

return TestRunner:summary()
