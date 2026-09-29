-- Unit tests for the capability resolution layer (agenda item 19):
-- user overrides (custom_models.lua) + derived provider metadata + family-prefix
-- fallbacks, resolved behind the model_constraints.lua chokepoints.
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
    print("\n== " .. name .. " ==")
end

function TestRunner:check(name, condition, detail)
    if condition then
        self.passed = self.passed + 1
        print("  PASS: " .. name)
    else
        self.failed = self.failed + 1
        print("  FAIL: " .. name .. (detail and ("  [" .. tostring(detail) .. "]") or ""))
    end
end

local ModelOverrides = require("koassistant_model_overrides")
local ModelConstraints = require("model_constraints")

local function resetLayers()
    ModelOverrides._setUserForTests(false)     -- loaded, empty (avoid disk reads)
    ModelOverrides._setDerivedForTests(false)
end
-- _setUserForTests(nil) re-arms lazy file loading; false = "loaded, nothing there"
-- (matches the sentinel the lazy loader itself stores on a missing file).
resetLayers()

--==========================================================================
TestRunner:suite("Family-prefix fallbacks (19a)")

-- New minors inherit tools/reasoning without curated entries
TestRunner:check("gemini-3.9-flash gets tools via family",
    ModelConstraints.supportsCapability("gemini", "gemini-3.9-flash", "tools"))
TestRunner:check("gemini-3.9-flash gets google_search via family",
    ModelConstraints.supportsCapability("gemini", "gemini-3.9-flash", "google_search"))
local p = ModelConstraints.getReasoningProfile("gemini", "gemini-3.9-flash")
TestRunner:check("gemini-3.9-flash reasoning profile = effort/on", p.axis == "effort"
    and p.default_state == "on", p.axis)
TestRunner:check("gemini-3.9-flash family options exclude minimal (pro-safe)",
    p.options and p.options[1] == "low")

-- Specific entries still win over the family fallback
p = ModelConstraints.getReasoningProfile("gemini", "gemini-3.6-flash")
TestRunner:check("gemini-3.6-flash keeps its specific profile (has minimal)",
    p.options and p.options[1] == "minimal")

p = ModelConstraints.getReasoningProfile("openai", "gpt-5.7-terra")
TestRunner:check("gpt-5.7 inherits gated effort profile", p.axis == "effort"
    and p.default_state == "off", p.axis)
TestRunner:check("gpt-5.7 family profile has no xhigh guess",
    p.options and #p.options == 3)
p = ModelConstraints.getReasoningProfile("openai", "gpt-5.6-sol")
TestRunner:check("gpt-5.6 keeps specific profile (xhigh present)",
    p.options and p.options[#p.options] == "xhigh")
TestRunner:check("gpt-5.7 gets tools via family",
    ModelConstraints.supportsCapability("openai", "gpt-5.7-terra", "tools"))
TestRunner:check("gpt-5.7 gets responses_web_search via family",
    ModelConstraints.supportsCapability("openai", "gpt-5.7-terra", "responses_web_search"))

p = ModelConstraints.getReasoningProfile("deepseek", "deepseek-v5-pro")
TestRunner:check("deepseek-v5 inherits binary/on", p.axis == "binary" and p.default_state == "on")
-- (glm-5.3 is curated since 2026-09-28; a still-unlisted minor tests the fallback)
p = ModelConstraints.getReasoningProfile("zai", "glm-5.9")
TestRunner:check("glm-5.9 inherits binary/on + temp1 via glm-5 prefix",
    p.axis == "binary" and p.needs_temp_1 == true)
p = ModelConstraints.getReasoningProfile("zai", "glm-4-plus")
TestRunner:check("glm-4-plus (pre-4.5, non-thinking) stays passthrough", p.axis == "none")

-- xAI: family fallback must NOT capture the non-reasoning 4.20 slug
p = ModelConstraints.getReasoningProfile("xai", "grok-4.20-0309")
TestRunner:check("grok-4.20-0309 (non-reasoning slug) stays axis=none", p.axis == "none")
p = ModelConstraints.getReasoningProfile("xai", "grok-4.20-0309-reasoning")
TestRunner:check("grok-4.20-0309-reasoning: always on, no knob (refuses reasoningEffort, recheck 2026-09-29)",
    p.axis == "none" and p.default_state == "on")
p = ModelConstraints.getReasoningProfile("xai", "grok-4.6")
TestRunner:check("grok-4.6 inherits effort profile via family", p.axis == "effort")
TestRunner:check("grok-4.6 gets tools via family",
    ModelConstraints.supportsCapability("xai", "grok-4.6", "tools"))

-- Anthropic deliberately has NO family fallback (old-id collisions)
p = ModelConstraints.getReasoningProfile("anthropic", "claude-opus-4-9")
TestRunner:check("claude-opus-4-9 stays passthrough (no anthropic family)", p.axis == "none")

-- Unknown models still fall through cleanly
p = ModelConstraints.getReasoningProfile("openai", "gpt-4o")
TestRunner:check("gpt-4o stays passthrough", p.axis == "none")
TestRunner:check("unknown provider capability = false",
    not ModelConstraints.supportsCapability("nonexistent", "whatever", "tools"))

--==========================================================================
TestRunner:suite("User overrides (custom_models.lua, 19b)")

ModelOverrides._setUserForTests({
    capabilities = {
        custom_lm_studio = { tools = { [""] = true } },
        openrouter = { tools = { ["somevendor/othermodel"] = true } },
        -- Deny: user says gemini-3.9-flash actually has no tools
        gemini = { tools = { ["gemini-3.9-flash"] = false } },
    },
    reasoning_profiles = {
        custom_lm_studio = {
            { match = "qwen", axis = "binary", default_state = "on",
              can_disable = true, can_enable = true, wire = "enable_thinking",
              stance_map = { minimal = { state = "off" }, maximum = { state = "on" } } },
            { match = "", axis = "effort", default_state = "off",
              can_disable = true, can_enable = true, wire = "effort",
              options = { "low", "medium", "high" }, default_option = "medium",
              stance_map = { minimal = { state = "off" }, maximum = { state = "on", option = "high" } } },
        },
        -- User profile beats the builtin specific entry
        openai = {
            { match = "gpt-5.6", axis = "effort", default_state = "on",
              can_disable = false, can_enable = true,
              options = { "low", "high" }, default_option = "low",
              stance_map = { minimal = { option = "low" }, maximum = { option = "high" } } },
        },
    },
    constraints = {
        custom_lm_studio = { [""] = { temperature = 0.6 } },
    },
    max_output_tokens = {
        custom_lm_studio = { ["qwen"] = 4096 },
    },
})

TestRunner:check("custom provider granted tools via \"\" prefix",
    ModelConstraints.supportsCapability("custom_lm_studio", "qwen3-30b", "tools"))
TestRunner:check("user grant on openrouter model",
    ModelConstraints.supportsCapability("openrouter", "somevendor/othermodel", "tools"))
TestRunner:check("user DENY beats curated family grant",
    not ModelConstraints.supportsCapability("gemini", "gemini-3.9-flash", "tools"))
TestRunner:check("deny is scoped: sibling model unaffected",
    ModelConstraints.supportsCapability("gemini", "gemini-3.8-flash", "tools"))

p = ModelConstraints.getReasoningProfile("custom_lm_studio", "qwen3-30b")
TestRunner:check("custom provider profile: first match wins (qwen entry)",
    p.axis == "binary" and p.wire == "enable_thinking", p.axis)
p = ModelConstraints.getReasoningProfile("custom_lm_studio", "llama-70b")
TestRunner:check("custom provider profile: catch-all entry", p.wire == "effort")
p = ModelConstraints.getReasoningProfile("openai", "gpt-5.6-terra")
TestRunner:check("user profile beats builtin (default on, no xhigh)",
    p.default_state == "on" and #p.options == 2)

-- resolveReasoning + emission through the neutral custom_reasoning key
local decision = ModelConstraints.resolveReasoning("custom_lm_studio", "qwen3-30b",
    { global_stance = "minimal" })
TestRunner:check("custom binary profile resolves off under minimal stance",
    decision.mode == "off" and not decision.send_nothing)
local api_params = {}
ModelConstraints.applyReasoningParams("custom_lm_studio", api_params, decision)
TestRunner:check("custom_reasoning emitted with wire",
    api_params.custom_reasoning and api_params.custom_reasoning.wire == "enable_thinking")
TestRunner:check("custom_reasoning carries on=false", api_params.custom_reasoning.on == false)

decision = ModelConstraints.resolveReasoning("custom_lm_studio", "llama-70b",
    { model_pref = { state = "on", effort = "high" } })
api_params = {}
ModelConstraints.applyReasoningParams("custom_lm_studio", api_params, decision)
TestRunner:check("effort wire carries level",
    api_params.custom_reasoning and api_params.custom_reasoning.effort == "high")

-- send_nothing (default stance) emits no custom_reasoning
decision = ModelConstraints.resolveReasoning("custom_lm_studio", "llama-70b", {})
api_params = {}
ModelConstraints.applyReasoningParams("custom_lm_studio", api_params, decision)
TestRunner:check("send_nothing emits nothing for custom wire",
    api_params.custom_reasoning == nil)

-- No profile, no wire: unknown custom provider stays inert
decision = ModelConstraints.resolveReasoning("custom_other", "whatever", { global_stance = "maximum" })
api_params = {}
ModelConstraints.applyReasoningParams("custom_other", api_params, decision)
TestRunner:check("custom provider without profile emits nothing",
    api_params.custom_reasoning == nil and decision.send_nothing)

-- Param constraints + output caps
local params = ModelConstraints.apply("custom_lm_studio", "qwen3-30b", { temperature = 1.4 })
TestRunner:check("user constraint forces temperature", params.temperature == 0.6)
TestRunner:check("user output cap clamps",
    ModelConstraints.clampMaxTokens("custom_lm_studio", "qwen3-30b", 16384) == 4096)
TestRunner:check("cap scoped by prefix (other model uncapped)",
    ModelConstraints.clampMaxTokens("custom_lm_studio", "llama-70b", 16384) == 16384)

--==========================================================================
TestRunner:suite("Derived metadata (OpenRouter auto-derive)")

resetLayers()
ModelOverrides._setDerivedForTests({
    version = 1,
    openrouter = {
        ["moonshotai/kimi-k2-0905"] = { fetched = 1753500000,
            params = { tools = true, temperature = true } },           -- no reasoning
        ["somevendor/reasoner"] = { fetched = 1753500000,
            params = { tools = true, reasoning = true } },
        ["somevendor/basic"] = { fetched = 1753500000,
            params = { temperature = true } },                          -- neither
    },
    -- Ollama rides the same derived layer (fetchDerivedModelCaps /api/show
    -- branch, 2026-08-14): capabilities array -> params set; there is no
    -- curated ollama tools list, so derived data is the ONLY grant path.
    ollama = {
        ["qwen2.5:0.5b"] = { fetched = 1786700000, params = { tools = true, completion = true } },
        ["gemma:2b"] = { fetched = 1786700000, params = { completion = true } },
    },
})

TestRunner:check("derived grants tools after curated miss",
    ModelConstraints.supportsCapability("openrouter", "moonshotai/kimi-k2-0905", "tools"))
TestRunner:check("derived absence of tools denies",
    not ModelConstraints.supportsCapability("openrouter", "somevendor/basic", "tools"))
TestRunner:check("curated family grant unaffected by missing derived data",
    ModelConstraints.supportsCapability("openrouter", "anthropic/claude-sonnet-5", "tools"))

TestRunner:check("ollama derived grants tools per local model",
    ModelConstraints.supportsCapability("ollama", "qwen2.5:0.5b", "tools"))
TestRunner:check("ollama recorded model without tools capability denies",
    not ModelConstraints.supportsCapability("ollama", "gemma:2b", "tools"))
TestRunner:check("ollama unknown model (never derived) denies",
    not ModelConstraints.supportsCapability("ollama", "mystery:7b", "tools"))

p = ModelConstraints.getReasoningProfile("openrouter", "moonshotai/kimi-k2-0905")
TestRunner:check("catch-all downgraded to passthrough when derived says no reasoning",
    p.axis == "none", p.axis)
p = ModelConstraints.getReasoningProfile("openrouter", "somevendor/reasoner")
TestRunner:check("catch-all kept when derived confirms reasoning", p.axis == "effort")
p = ModelConstraints.getReasoningProfile("openrouter", "somevendor/unknown")
TestRunner:check("catch-all kept when no derived data exists", p.axis == "effort")
p = ModelConstraints.getReasoningProfile("openrouter", "google/gemini-3-flash-preview")
TestRunner:check("curated family profile bypasses the generic gate",
    p.axis == "effort" and p.can_disable == false)

-- Derived data is exact-id only ("somevendor/reasoner" is in the fixture; an
-- extended id must NOT inherit its grant. kimi-k2 no longer works for this
-- check - it gained a curated family entry in the 2026-07-25 tools round.)
TestRunner:check("derived never prefix-matches",
    not ModelConstraints.supportsCapability("openrouter", "somevendor/reasoner-v2", "tools"))

--==========================================================================
TestRunner:suite("recordDerived round-trip")

resetLayers()
local recorded = ModelOverrides.recordDerived("openrouter", "a/b", { tools = true })
-- In the unit environment there may be no writable settings dir; the in-memory
-- layer must be updated either way.
TestRunner:check("recordDerived updates in-memory layer (persisted=" .. tostring(recorded) .. ")",
    ModelOverrides.derivedParam("openrouter", "a/b", "tools") == true)
TestRunner:check("derivedParam false for absent param",
    ModelOverrides.derivedParam("openrouter", "a/b", "reasoning") == false)
TestRunner:check("derivedParam nil for unknown model",
    ModelOverrides.derivedParam("openrouter", "a/c", "tools") == nil)

resetLayers()

-- Summary
print(string.format("\n%d passed, %d failed", TestRunner.passed, TestRunner.failed))
return TestRunner.failed == 0
