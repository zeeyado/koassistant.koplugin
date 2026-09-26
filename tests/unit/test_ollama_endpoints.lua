-- Unit tests for the Ollama GUI server endpoints: address normalization
-- (ConfigHelper.normalizeServerUrl) and the mergeWithDefaults injection that
-- routes the wire at features.ollama_endpoints.active (Settings UI >
-- configuration.lua > shipped default).

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
local TestRunner = require("test_runner"):new()

print("")
print(string.rep("=", 50))
print("  Unit Tests: Ollama Endpoints")
print(string.rep("=", 50))

local norm = ConfigHelper.normalizeServerUrl

-- The URL the provider's handler puts on the wire for a merged config
local function wireUrl(provider, merged)
    local handler = require("koassistant_api." .. provider)
    return handler:buildRequestBody({ { role = "user", content = "hi" } }, merged).url
end

TestRunner:test("normalize: bare host:port gets http scheme", function()
    TestRunner:assertEqual(norm("192.168.1.20:11434"), "http://192.168.1.20:11434", "bare host")
    TestRunner:assertEqual(norm("myserver.local:11434"), "http://myserver.local:11434", "hostname")
end)

TestRunner:test("normalize: explicit scheme kept, trailing junk stripped", function()
    TestRunner:assertEqual(norm("https://box:11434/"), "https://box:11434", "https kept, slash stripped")
    TestRunner:assertEqual(norm("http://box:11434/api/chat"), "http://box:11434",
        "pasted chat path stripped to root")
    TestRunner:assertEqual(norm("  box:11434  "), "http://box:11434", "whitespace trimmed")
end)

TestRunner:test("normalize: unusable input returns nil", function()
    TestRunner:assertEqual(norm(""), nil, "empty")
    TestRunner:assertEqual(norm("   "), nil, "blank")
    TestRunner:assertEqual(norm("http://"), nil, "scheme only")
    TestRunner:assertEqual(norm(nil), nil, "nil input")
end)

TestRunner:test("merge: no GUI endpoint keeps the shipped default", function()
    local merged = ConfigHelper:mergeWithDefaults({ provider = "ollama", features = {} })
    TestRunner:assertEqual(wireUrl("ollama", merged), "http://localhost:11434/api/chat", "default wire url")
end)

TestRunner:test("merge: active GUI endpoint routes the wire", function()
    local merged = ConfigHelper:mergeWithDefaults({
        provider = "ollama",
        features = { ollama_endpoints = {
            active = "http://192.168.1.20:11434",
            list = { { url = "http://192.168.1.20:11434", name = "phone" } },
        } },
    })
    TestRunner:assertEqual(merged.base_url, "http://192.168.1.20:11434/api/chat", "top-level url")
    TestRunner:assertEqual(merged.provider_settings.ollama.base_url,
        "http://192.168.1.20:11434/api/chat", "provider_settings url")
end)

TestRunner:test("merge: GUI endpoint beats a configuration.lua base_url override", function()
    local merged = ConfigHelper:mergeWithDefaults({
        provider = "ollama",
        provider_settings = { ollama = { base_url = "http://filehost:9999/api/chat" } },
        features = { ollama_endpoints = { active = "http://guihost:11434" } },
    })
    TestRunner:assertEqual(merged.base_url, "http://guihost:11434/api/chat",
        "Settings UI > configuration.lua")
end)

TestRunner:test("merge: configuration.lua override still wins with no GUI endpoint", function()
    local merged = ConfigHelper:mergeWithDefaults({
        provider = "ollama",
        provider_settings = { ollama = { base_url = "http://filehost:9999/api/chat" } },
        features = {},
    })
    TestRunner:assertEqual(merged.base_url, "http://filehost:9999/api/chat",
        "configuration.lua respected")
end)

TestRunner:test("merge: other providers unaffected by ollama_endpoints", function()
    local merged = ConfigHelper:mergeWithDefaults({
        provider = "anthropic",
        features = { ollama_endpoints = { active = "http://guihost:11434" } },
    })
    TestRunner:assertEqual(wireUrl("anthropic", merged), "https://api.anthropic.com/v1/messages",
        "anthropic untouched")
end)

TestRunner:test("merge: absent features table does not crash", function()
    local merged = ConfigHelper:mergeWithDefaults({ provider = "ollama" })
    TestRunner:assertEqual(wireUrl("ollama", merged), "http://localhost:11434/api/chat", "default url")
end)

return TestRunner:summary()
