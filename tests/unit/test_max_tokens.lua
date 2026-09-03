-- Unit tests for the max_tokens story (item 27, raise-where-known, 2026-08-06):
-- resolveMaxTokens raises the DEFAULT request to min(MAX_TOKENS_TARGET, known
-- ceiling) so reasoning/thinking (billed against the same budget everywhere)
-- can never starve the answer, while unknown models keep the provider's
-- field-proven fallback — missing curation degrades to old behavior, never to
-- a 400. clampMaxTokens keeps protecting EXPLICIT pins with the same table.
-- Born from issue #98 (reasoning-only completions under starved max_tokens).
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

local TestRunner = {
    passed = 0,
    failed = 0,
}

function TestRunner.assert(condition, message)
    if condition then
        TestRunner.passed = TestRunner.passed + 1
    else
        TestRunner.failed = TestRunner.failed + 1
        print("  FAIL: " .. message)
    end
end

local ModelConstraints = require("model_constraints")
local ModelOverrides = require("koassistant_model_overrides")

print("test_max_tokens: resolveMaxTokens / clampMaxTokens (item 27)")

local FALLBACK = 16384
local TARGET = ModelConstraints.MAX_TOKENS_TARGET

TestRunner.assert(TARGET == 32768, "MAX_TOKENS_TARGET is 32768")

-- Known big-ceiling models resolve to the target
local raised = {
    { "anthropic", "claude-sonnet-5" },
    { "anthropic", "claude-fable-5" },
    { "openai", "gpt-5.6-terra" },
    { "openai", "gpt-5.4-nano" },
    { "gemini", "gemini-3.6-flash" },
    { "gemini", "gemini-2.5-flash" },
    { "deepseek", "deepseek-v4-pro" },
    { "xai", "grok-4.5" },
    { "zai", "glm-5.2" },
    { "openrouter", "anthropic/claude-sonnet-5" },
    { "openrouter", "google/gemini-3.6-flash" },
    { "openrouter", "openai/gpt-5.6-sol" },
}
for _idx, c in ipairs(raised) do
    TestRunner.assert(ModelConstraints.resolveMaxTokens(c[1], c[2], FALLBACK) == TARGET,
        c[1] .. "/" .. c[2] .. " resolves to the 32K target")
end

-- Known LOW ceilings cap the default below the fallback (the load-bearing rows)
TestRunner.assert(ModelConstraints.resolveMaxTokens("openrouter", "qwen/qwen3-235b-a22b", FALLBACK) == 8192,
    "openrouter qwen3-235b caps the default at its 8192 ceiling")
TestRunner.assert(ModelConstraints.resolveMaxTokens("openrouter", "perplexity/sonar-pro", FALLBACK) == 8000,
    "openrouter sonar-pro caps the default at its 8000 ceiling")
TestRunner.assert(ModelConstraints.resolveMaxTokens("perplexity", "sonar-pro", FALLBACK) == 8192,
    "direct sonar-pro caps the default at its curated ceiling")

-- Unknown models keep the provider fallback (never a raise, never a 400 risk)
local unknown = {
    { "anthropic", "some-future-model" },
    { "gemini", "gemini-1.5-pro" },
    { "mistral", "mistral-large-latest" },
    { "openrouter", "x-ai/grok-4.3" },
    { "custom_lmstudio", "local-model" },
}
for _idx, c in ipairs(unknown) do
    TestRunner.assert(ModelConstraints.resolveMaxTokens(c[1], c[2], FALLBACK) == FALLBACK,
        c[1] .. "/" .. c[2] .. " (unknown ceiling) keeps the fallback")
end

-- Community providers with NO ceiling data keep their conservative fallback.
-- Their live catalogs justify it and disprove a flat raise: vercel's gateway
-- floor is 4000, featherless has a 2048 context floor, hyperbolic publishes
-- nothing at all (checked 2026-08-09).
for _idx, prov in ipairs({ "hyperbolic", "featherless", "vercel", "chutes" }) do
    TestRunner.assert(ModelConstraints.resolveMaxTokens(prov, "some-model", 4096) == 4096,
        prov .. " has no ceiling data -> keeps its conservative 4096 fallback")
end

-- Community hosts WITH catalog-verified ceilings do get the raise, including
-- for models the user fetched later (provider-wide "" entry).
TestRunner.assert(ModelConstraints.resolveMaxTokens("cerebras", "gpt-oss-120b", 16384) == TARGET,
    "cerebras (catalog: 40960 on every model) reaches the target")
TestRunner.assert(ModelConstraints.resolveMaxTokens("cerebras", "a-model-we-never-listed", 16384) == TARGET,
    "cerebras provider-wide entry covers fetched models too")
TestRunner.assert(ModelConstraints.resolveMaxTokens("deepinfra", "anything", 16384) == 16384,
    "deepinfra's documented 16384 output cap bounds the ask")

-- A per-model ceiling must WIN over the provider-wide raise, and must cap an
-- explicit pin. novita's llama-3.3-70b-instruct is the sharp case: its output
-- cap equals its entire 12288 context, so anything larger is an instant 400.
TestRunner.assert(ModelConstraints.resolveMaxTokens("novita", "meta-llama/llama-3.3-70b-instruct", 4096) == 12288,
    "novita llama-3.3 resolves to its real 12288 cap")
TestRunner.assert(ModelConstraints.clampMaxTokens("novita", "meta-llama/llama-3.3-70b-instruct", 65536) == 12288,
    "X-Ray's 65536 pin clamps to novita llama-3.3's 12288 cap instead of 400ing")
TestRunner.assert(ModelConstraints.resolveMaxTokens("novita", "deepseek/deepseek-v4-pro", 4096) == TARGET,
    "novita deepseek-v4 prefix entry (393216) reaches the target")
TestRunner.assert(ModelConstraints.resolveMaxTokens("novita", "gryphe/mythomax-l2-13b", 4096) == 4096,
    "an unlisted novita model keeps the conservative fallback (its real cap is 3200)")

-- clampMaxTokens still protects explicit pins with the same table
TestRunner.assert(ModelConstraints.clampMaxTokens("openrouter", "qwen/qwen3-235b-a22b", 65536) == 8192,
    "explicit 65536 pin clamps to qwen3-235b's 8192 ceiling")
TestRunner.assert(ModelConstraints.clampMaxTokens("anthropic", "claude-sonnet-5", 65536) == 65536,
    "explicit 65536 pin passes under sonnet-5's 128K ceiling")
TestRunner.assert(ModelConstraints.clampMaxTokens("mistral", "mistral-large-latest", 65536) == 65536,
    "no ceiling data -> explicit value passes through")

-- User override layer (custom_models.lua) feeds both directions
ModelOverrides._setUserForTests({
    max_output_tokens = {
        mistral = {
            ["mistral-large-latest"] = 65536,
            ["ministral-8b-latest"] = 8192,
        },
    },
})
TestRunner.assert(ModelConstraints.resolveMaxTokens("mistral", "mistral-large-latest", FALLBACK) == TARGET,
    "user-declared big ceiling raises the default to the target")
TestRunner.assert(ModelConstraints.resolveMaxTokens("mistral", "ministral-8b-latest", FALLBACK) == 8192,
    "user-declared low ceiling caps the default")
TestRunner.assert(ModelConstraints.clampMaxTokens("mistral", "ministral-8b-latest", 30000) == 8192,
    "user-declared low ceiling clamps explicit pins")
ModelOverrides._setUserForTests(false)

-- The reasoning-headroom net (dialogs.ensureReasoningHeadroom) must fire for
-- models we do not RECOGNIZE, not just models we know reason: anything from
-- "Fetch models", any custom/local provider model, gets the passthrough profile
-- and reports mode "off", so a mode-only gate skipped exactly the models most
-- likely to starve (#98). `profile.unknown` is that seam — it must be set for
-- unrecognized models and NOT set for a curated axis="none" entry, which is a
-- model we positively know does not reason.
do
    local unknown_cases = {
        { "openai", "totally-made-up-model" },
        { "custom_lmstudio", "some-local-llm" },
        { "ollama", "gemma4" },
    }
    for _idx, c in ipairs(unknown_cases) do
        local prof = ModelConstraints.getReasoningProfile(c[1], c[2])
        TestRunner.assert(prof.unknown == true,
            c[1] .. "/" .. c[2] .. " is unrecognized -> profile.unknown must be true")
    end

    local known_cases = {
        { "anthropic", "claude-sonnet-5" },      -- known reasoner
        { "openrouter", "perplexity/sonar" },    -- CURATED axis="none": known NOT to reason
    }
    for _idx, c in ipairs(known_cases) do
        local prof = ModelConstraints.getReasoningProfile(c[1], c[2])
        TestRunner.assert(prof.unknown == nil,
            c[1] .. "/" .. c[2] .. " is curated -> profile.unknown must NOT be set")
    end
end

-- OpenRouter context-overflow wording (#106 follow-up): "(P of text input, Q in the output)"
do
    local P = ModelConstraints.parseMaxTokensError
    local OR = "This endpoint's maximum context length is 32768 tokens. However, you requested about 33002 tokens "
        .. "(234 of text input, 32768 in the output). Please reduce the length of either one, or use the \"middle-out\" transform to compress your prompt automatically."
    local r = P(OR)
    TestRunner.assert(r and r.kind == "context", "openrouter overflow recognized as context kind")
    TestRunner.assert(r and r.limit == 32768 and r.prompt == 234, "openrouter overflow: limit + prompt parsed")
    TestRunner.assert(r and r.retry_at == 32768 - 234 - 256, "openrouter overflow: retry room = limit - prompt - margin")
    local big = P("This endpoint's maximum context length is 8192 tokens. However, you requested about 40000 tokens (9000 of text input, 31000 in the output).")
    TestRunner.assert(big == nil, "openrouter overflow: prompt alone over the window -> no retry")
    local vllm = P("This model's maximum context length is 12288 tokens. However, you requested 20480 tokens (8192 in the messages, 12288 in the completion).")
    TestRunner.assert(vllm and vllm.retry_at == 12288 - 8192 - 256 and vllm.prompt == 8192, "vLLM wording unchanged")
end

-- effectiveMaxTokens: the budget a handler will send, derived like the handlers do
-- (per-minute admission limits need it to read a refusal's "Requested M").
do
    local E = ModelConstraints.effectiveMaxTokens
    TestRunner.assert(E("groq", "openai/gpt-oss-20b", { provider_settings = { groq = { additional_parameters = { max_tokens = 16384 } } } }) == TARGET,
        "effectiveMaxTokens: known ceiling -> raise-where-known target")
    TestRunner.assert(E("custom_lm_studio", "stub-model", { provider_settings = {} }) == 16384,
        "effectiveMaxTokens: custom provider, no ceiling -> the handlers' 16384 fallback")
    TestRunner.assert(E("novita", "some-unknown", { provider_settings = { novita = { additional_parameters = { max_tokens = 4096 } } } }) == 4096,
        "effectiveMaxTokens: community provider fallback from its defaults")
    TestRunner.assert(E("groq", "openai/gpt-oss-20b", { api_params = { max_tokens = 4096 } }) == 4096,
        "effectiveMaxTokens: api_params pin respected")
    TestRunner.assert(E("groq", "llama-3.3-70b-versatile", { api_params = { max_tokens = 65536 } }) == 32768,
        "effectiveMaxTokens: pin clamped to the ceiling")
    TestRunner.assert(E("anthropic", "claude-sonnet-5", { additional_parameters = { max_tokens = 8000 } }) == 8000,
        "effectiveMaxTokens: top-level additional_parameters pin (anthropic reads it as a pin)")
end

-- parseMaxTokensError: the self-heal's decision function. Only provider-STATED
-- numbers may be acted on — a misparse here caches a wrong ceiling silently.
do
    local P = ModelConstraints.parseMaxTokensError

    -- OpenAI: oversized max_tokens / max_completion_tokens
    local r = P("max_tokens is too large: 100000. This model supports at most 16384 completion tokens, whereas you provided 100000.")
    TestRunner.assert(r and r.kind == "output_cap" and r.cap == 16384, "OpenAI 'supports at most N completion tokens'")

    -- Anthropic: the format our own curated entries were verified from
    r = P("max_tokens: 200000 > 128000, which is the maximum allowed number of output tokens for claude-sonnet-5")
    TestRunner.assert(r and r.kind == "output_cap" and r.cap == 128000, "Anthropic 'max_tokens: X > N'")

    -- Groq (issue #89's family): must be less than or equal to
    r = P("`max_tokens` must be less than or equal to `32768`, the maximum value for `max_tokens` is less than the `context_window` for this model")
    TestRunner.assert(r and r.kind == "output_cap" and r.cap == 32768, "Groq 'must be less than or equal to N'")

    -- vLLM family (Novita, Featherless, local servers): context overflow with
    -- computable room -> one-shot retry value, NEVER a cacheable cap
    r = P("This model's maximum context length is 12288 tokens. However, you requested 20480 tokens (8192 in the messages, 12288 in the completion). Please reduce the length of the messages or completion.")
    TestRunner.assert(r and r.kind == "context" and r.retry_at == 12288 - 8192 - 256,
        "vLLM context overflow computes room = limit - prompt - margin")
    TestRunner.assert(r and r.cap == nil, "context overflow carries NO cacheable cap")

    -- Context overflow with no room left: no retry (it cannot help)
    TestRunner.assert(P("This model's maximum context length is 8192 tokens. However, you requested 40000 tokens (7900 in the messages, 32100 in the completion).") == nil,
        "context overflow with < 1024 room -> nil (no pointless retry)")

    -- Negatives: must not fire on unrelated or numberless errors
    TestRunner.assert(P("temperature must be 1.0 for this model") == nil, "temperature error -> nil")
    TestRunner.assert(P("Rate limit exceeded. Please retry after 20 seconds. Limit: 30000 tokens per minute.") == nil, "rate-limit text -> nil")
    TestRunner.assert(P("max_tokens is invalid") == nil, "numberless max_tokens error -> nil (no blind guessing)")
    TestRunner.assert(P("") == nil and P(nil) == nil, "empty/nil -> nil")
    TestRunner.assert(P("max_tokens must be less than or equal to 512") == nil,
        "sub-1024 'cap' fails the sanity gate (likely a different limit)")
end

-- Learned-ceiling layer: user > LEARNED > curated, and the learned value feeds
-- both the default and the clamp exactly like any other ceiling.
do
    local ModelOverrides = require("koassistant_model_overrides")
    -- Curated says sonnet-5 = 128000 -> default 32768. A learned 12000 must win.
    ModelOverrides._setDerivedForTests({
        anthropic = { ["claude-sonnet-5"] = { fetched = 0, params = {}, max_output = 12000 } },
    })
    TestRunner.assert(ModelConstraints.resolveMaxTokens("anthropic", "claude-sonnet-5", FALLBACK) == 12000,
        "learned ceiling beats the curated table (it was learned from a real 400)")
    TestRunner.assert(ModelConstraints.clampMaxTokens("anthropic", "claude-sonnet-5", 65536) == 12000,
        "learned ceiling clamps explicit pins")
    -- ...but explicit user intent beats the learned value
    ModelOverrides._setUserForTests({
        max_output_tokens = { anthropic = { ["claude-sonnet-5"] = 128000 } },
    })
    TestRunner.assert(ModelConstraints.clampMaxTokens("anthropic", "claude-sonnet-5", 65536) == 65536,
        "user-declared ceiling overrides a stale learned one")
    ModelOverrides._setUserForTests(false)
    ModelOverrides._setDerivedForTests(false)

    -- recordDerived (params refetch) must PRESERVE a learned max_output; the
    -- persist step may fail in the test env (no settings dir) — the in-memory
    -- merge is what's asserted.
    ModelOverrides._setDerivedForTests({
        novita = { ["some-model"] = { fetched = 1, params = {}, max_output = 9000 } },
    })
    ModelOverrides.recordDerived("novita", "some-model", { tools = true })
    TestRunner.assert(ModelOverrides.derivedMaxOutput("novita", "some-model") == 9000,
        "params refetch preserves the learned max_output")
    ModelOverrides._setDerivedForTests(false)
end

-- Summary
print(string.format("\n%d passed, %d failed", TestRunner.passed, TestRunner.failed))
return TestRunner.failed == 0
