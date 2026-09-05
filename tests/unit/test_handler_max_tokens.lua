-- Handler-contract tests for the max_tokens story (item 27).
--
-- test_max_tokens.lua covers the pure resolver. This file covers the OTHER half:
-- that every provider handler actually WIRES it up. That gap was not theoretical
-- — an audit found openai.lua and gemini.lua resolving but never clamping,
-- cohere.lua bypassing both, custom providers looking up under the wrong key, and
-- anthropic_request.lua reading the provider default as if it were an action pin
-- (which made the resolver unreachable, so the plugin's DEFAULT provider never
-- got the raise). Each is asserted below so a handler cannot regress silently.
--
-- The contract, per handler:
--   1. RAISE   — no pin + known ceiling  -> min(32768, ceiling), not the fallback
--   2. CLAMP   — explicit pin above ceiling -> capped down to the ceiling
--   3. RESPECT — explicit pin below ceiling -> passed through untouched
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
        plugin_dir .. "/koassistant_api/?.lua",
        tests_dir .. "/?.lua",
        tests_dir .. "/lib/?.lua",
        package.path,
    }, ";")
end

setupPaths()
require("mock_koreader")

local TestRunner = { passed = 0, failed = 0 }

function TestRunner.assert(condition, message)
    if condition then
        TestRunner.passed = TestRunner.passed + 1
    else
        TestRunner.failed = TestRunner.failed + 1
        print("  FAIL: " .. message)
    end
end

local MESSAGES = { { role = "user", content = "hi" } }

--- Pull whatever output-token field a handler chose to emit.
local function tokenField(body)
    if type(body) ~= "table" then return nil end
    return body.max_tokens
        or body.max_completion_tokens
        or body.max_output_tokens
        or (type(body.generationConfig) == "table" and body.generationConfig.maxOutputTokens or nil)
end

local function buildBody(handler, provider, model, pin, extra_config)
    local config = {
        provider = provider,
        model = model,
        api_key = "test-key",
        base_url = extra_config and extra_config.base_url or nil,
        system = { text = "sys" },
        api_params = pin and { max_tokens = pin } or {},
        features = { enable_streaming = false },
    }
    for k, v in pairs(extra_config or {}) do config[k] = v end
    local built = handler:buildRequestBody(MESSAGES, config)
    return tokenField(built and built.body)
end

print("test_handler_max_tokens: every handler resolves AND clamps (item 27)")

local TARGET = require("model_constraints").MAX_TOKENS_TARGET

-- provider, handler module, model with a KNOWN ceiling, that ceiling
local CASES = {
    { "anthropic",  "koassistant_api.anthropic",         "claude-sonnet-5",          128000 },
    { "openai",     "koassistant_api.openai",            "gpt-5.6-terra",            128000 },
    { "gemini",     "koassistant_api.gemini",            "gemini-3.6-flash",          65536 },
    { "deepseek",   "koassistant_api.deepseek",          "deepseek-v4-pro",          384000 },
    { "xai",        "koassistant_api.xai",               "grok-4.5",                  32768 },
    { "zai",        "koassistant_api.zai",               "glm-5.2",                  128000 },
    { "openrouter", "koassistant_api.openrouter",        "anthropic/claude-sonnet-5",128000 },
    { "cohere",     "koassistant_api.cohere",            "command-a-plus-05-2026",      nil },
    { "groq",       "koassistant_api.groq",              "llama-3.3-70b-versatile",   32768 },
    { "perplexity", "koassistant_api.perplexity",        "sonar-pro",                  8192 },
    -- No curated ceiling: NVIDIA states none and any real cap is learned by the
    -- max_tokens self-heal. Exercises the no-ceiling resolve+clamp path.
    { "nvidia",     "koassistant_api.nvidia",            "nvidia/nemotron-3-super-120b-a12b", nil },
    -- OpenCode (#107): no curated ceiling either; the 16384 fallback was probed accepted.
    { "opencode",   "koassistant_api.opencode",          "glm-5.3-flash",               nil },
    { "opencode_go", "koassistant_api.opencode_go",      "glm-5.3-flash",               nil },
}

for _idx, case in ipairs(CASES) do
    local provider, module_name, model, ceiling = case[1], case[2], case[3], case[4]
    local ok, handler = pcall(require, module_name)
    if not ok or type(handler) ~= "table" or type(handler.buildRequestBody) ~= "function" then
        TestRunner.assert(false, provider .. ": handler module has no buildRequestBody (" .. module_name .. ")")
    else
        -- 1. RAISE: no pin, known ceiling -> min(target, ceiling)
        local unpinned = buildBody(handler, provider, model, nil)
        if ceiling then
            local want = math.min(TARGET, ceiling)
            TestRunner.assert(unpinned == want,
                string.format("%s/%s unpinned should resolve to %d, got %s",
                    provider, model, want, tostring(unpinned)))
        else
            -- No curated ceiling: must still emit SOMETHING (the fallback)
            TestRunner.assert(type(unpinned) == "number" and unpinned > 0,
                provider .. "/" .. model .. " unpinned should emit the provider fallback")
        end

        -- 2. CLAMP: a pin above the ceiling must be capped (this is the X-Ray
        --    65536 pin meeting a low-ceiling model — an unclamped one is a 400)
        if ceiling and ceiling < 1000000 then
            local over = ceiling + 100000
            local clamped = buildBody(handler, provider, model, over)
            TestRunner.assert(clamped ~= nil and clamped <= ceiling,
                string.format("%s/%s pin %d must clamp to <=%d, got %s",
                    provider, model, over, ceiling, tostring(clamped)))
        end

        -- 3. RESPECT: a modest pin below the ceiling passes through
        local small = buildBody(handler, provider, model, 4096)
        TestRunner.assert(small == 4096,
            string.format("%s/%s pin 4096 should pass through, got %s",
                provider, model, tostring(small)))
    end
end

-- Same contract, proven independently of CURATED data: declare a ceiling in the
-- user layer (custom_models.lua) for each provider and require the handler to
-- honour it in both directions. Without this, a handler for a provider we have
-- no curated ceiling for (e.g. cohere) could bypass ModelConstraints entirely
-- and still pass every assertion above — verified: reverting cohere's wiring
-- left the curated-data loop green.
do
    local ModelOverrides = require("koassistant_model_overrides")
    for _idx, case in ipairs(CASES) do
        local provider, module_name, model = case[1], case[2], case[3]
        local ok, handler = pcall(require, module_name)
        if ok and type(handler) == "table" and type(handler.buildRequestBody) == "function" then
            -- Low user ceiling: must cap BOTH the default and an explicit pin.
            ModelOverrides._setUserForTests({
                max_output_tokens = { [provider] = { [model] = 1024 } },
            })
            local defaulted = buildBody(handler, provider, model, nil)
            TestRunner.assert(defaulted == 1024,
                string.format("%s/%s: user ceiling 1024 must cap the DEFAULT (handler must call resolveMaxTokens), got %s",
                    provider, model, tostring(defaulted)))

            local pinned = buildBody(handler, provider, model, 50000)
            TestRunner.assert(pinned == 1024,
                string.format("%s/%s: user ceiling 1024 must clamp an explicit PIN (handler must call clampMaxTokens), got %s",
                    provider, model, tostring(pinned)))
            ModelOverrides._setUserForTests(false)
        end
    end
end

-- Custom OpenAI-compatible providers: capability data is keyed by the RUNTIME
-- id (custom_<slug>), not the handler's static "custom" key. A user ceiling
-- declared in custom_models.lua must therefore reach both roles.
do
    local ModelOverrides = require("koassistant_model_overrides")
    local ok, CustomHandler = pcall(require, "koassistant_api.custom_openai")
    if ok and type(CustomHandler) == "table" then
        ModelOverrides._setUserForTests({
            max_output_tokens = { custom_lmstudio = { ["local-big"] = 100000, ["local-small"] = 2048 } },
        })
        local big = buildBody(CustomHandler, "custom_lmstudio", "local-big", nil,
            { base_url = "http://localhost:1234/v1/chat/completions" })
        TestRunner.assert(big == TARGET,
            "custom provider: user-declared big ceiling raises the default to the target, got " .. tostring(big))

        local small = buildBody(CustomHandler, "custom_lmstudio", "local-small", nil,
            { base_url = "http://localhost:1234/v1/chat/completions" })
        TestRunner.assert(small == 2048,
            "custom provider: user-declared low ceiling caps the default, got " .. tostring(small))

        local clamped = buildBody(CustomHandler, "custom_lmstudio", "local-small", 60000,
            { base_url = "http://localhost:1234/v1/chat/completions" })
        TestRunner.assert(clamped == 2048,
            "custom provider: user-declared low ceiling clamps an explicit pin, got " .. tostring(clamped))
        ModelOverrides._setUserForTests(false)
    else
        TestRunner.assert(false, "custom_openai handler failed to load")
    end
end

-- Built-in actions must not reintroduce a starving pin. Only deliberate RAISES
-- (>= the target) are allowed; the 4096/8192 pins were removed by item 27.
do
    local Actions = require("prompts.actions")
    local offenders = {}
    for id, action in pairs(Actions) do
        local pin = type(action) == "table" and type(action.api_params) == "table"
            and action.api_params.max_tokens
        if type(pin) == "number" and pin < TARGET then
            table.insert(offenders, string.format("%s=%d", tostring(id), pin))
        end
    end
    table.sort(offenders)
    TestRunner.assert(#offenders == 0,
        "built-in actions must not pin max_tokens below the target: " .. table.concat(offenders, ", "))
end

print(string.format("\n%d passed, %d failed", TestRunner.passed, TestRunner.failed))
return TestRunner.failed == 0
