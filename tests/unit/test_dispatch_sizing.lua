-- Unit tests for the one-model-id-per-request rule
-- (docs/request_sizing_audit.md B3 / findings F3 + F41):
-- ModelConstraints.dispatchModel is THE resolver for the model id a request is
-- keyed under — the per-minute plan memo, the context-window pre-check, the
-- effective answer budget and the handler on the wire must agree on one string
-- or all be nil together.
-- Run: lua tests/unit/test_dispatch_sizing.lua  (or lua tests/run_tests.lua --unit)

local plugin_dir   -- the structural gate at the end of the file reads the sources
local function setupPaths()
    local info = debug.getinfo(1, "S")
    local script_path = info.source:match("@?(.*)")
    local unit_dir = script_path:match("(.+)/[^/]+$") or "."
    local tests_dir = unit_dir:match("(.+)/[^/]+$") or "."
    plugin_dir = tests_dir:match("(.+)/[^/]+$") or "."
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

local TestRunner = { passed = 0, failed = 0, current_suite = "" }
function TestRunner:suite(name) self.current_suite = name; print(string.format("\n  [%s]", name)) end
function TestRunner:test(name, fn)
    local ok, err = pcall(fn)
    if ok then self.passed = self.passed + 1; print("    ✓ " .. name)
    else self.failed = self.failed + 1; print("    ✗ " .. name); print("      Error: " .. tostring(err)) end
end
function TestRunner:assertEqual(actual, expected, msg)
    if actual ~= expected then
        error(string.format("%s: expected %s, got %s", msg or "assert", tostring(expected), tostring(actual)))
    end
end
function TestRunner:assertTrue(v, msg) if not v then error(msg or "expected truthy") end end
function TestRunner:assertNil(v, msg) if v ~= nil then error((msg or "expected nil") .. ", got " .. tostring(v)) end end

local ModelConstraints = require("model_constraints")
local Defaults = require("koassistant_api.defaults")

-- A custom provider list as it lives on features.custom_providers.
local function customs(default_model)
    local cp = { id = "custom_x", name = "Custom X", base_url = "https://example.invalid/v1/chat/completions" }
    cp.default_model = default_model  -- nil stays nil
    return { cp }
end

TestRunner:suite("dispatchModel: the named model wins")

TestRunner:test("a non-empty config.model is returned as-is", function()
    TestRunner:assertEqual(
        ModelConstraints.dispatchModel({ provider = "groq", model = "llama-3.3-70b-versatile" }),
        "llama-3.3-70b-versatile", "config.model")
end)

TestRunner:test("config.model wins over the provider default", function()
    local m = ModelConstraints.dispatchModel({ provider = "groq", model = "picked-by-the-user" })
    TestRunner:assertEqual(m, "picked-by-the-user", "no default lookup when a model is named")
end)

TestRunner:suite("dispatchModel: falling through to the provider default")

TestRunner:test("nil model on a built-in resolves to the shipped default (F3's four nil routes)", function()
    local expected = Defaults.ProviderDefaults.groq.model
    TestRunner:assertTrue(type(expected) == "string" and expected ~= "", "fixture: groq has a default")
    TestRunner:assertEqual(ModelConstraints.dispatchModel({ provider = "groq" }), expected, "built-in default")
end)

TestRunner:test("an EMPTY config.model falls through (F41: \"\" is truthy in Lua)", function()
    TestRunner:assertEqual(ModelConstraints.dispatchModel({ provider = "groq", model = "" }),
        Defaults.ProviderDefaults.groq.model, "empty string is not a model id")
end)

TestRunner:test("config.default_provider is honoured when config.provider is nil", function()
    TestRunner:assertEqual(ModelConstraints.dispatchModel({ default_provider = "groq" }),
        Defaults.ProviderDefaults.groq.model, "default_provider")
end)

TestRunner:suite("dispatchModel: custom providers (never ProviderDefaults, never getProviderKey)")

TestRunner:test("a custom provider's default_model resolves", function()
    TestRunner:assertEqual(
        ModelConstraints.dispatchModel({ provider = "custom_x", features = { custom_providers = customs("m") } }),
        "m", "custom default_model")
end)

TestRunner:test("default_model = \"\" resolves to nil, not to \"\" (F41)", function()
    TestRunner:assertNil(
        ModelConstraints.dispatchModel({ provider = "custom_x", features = { custom_providers = customs("") } }),
        "empty default_model")
end)

TestRunner:test("no default_model at all resolves to nil, never the placeholder \"default\"", function()
    -- buildCustomProviderDefaults synthesizes `default_model or "default"`, which is
    -- the handler's last resort on the wire. Keying a plan allowance under a string
    -- nobody named would be an invented fact.
    TestRunner:assertNil(
        ModelConstraints.dispatchModel({ provider = "custom_x", features = { custom_providers = customs(nil) } }),
        "placeholder is not a model id")
end)

TestRunner:test("an unknown provider resolves to nil", function()
    TestRunner:assertNil(ModelConstraints.dispatchModel({ provider = "no_such_provider" }), "unknown provider")
    TestRunner:assertNil(ModelConstraints.dispatchModel({ provider = "custom_gone",
        features = { custom_providers = customs("m") } }), "custom id not in the list")
end)

TestRunner:test("no provider at all, and a non-table config, resolve to nil", function()
    TestRunner:assertNil(ModelConstraints.dispatchModel({}), "no provider")
    TestRunner:assertNil(ModelConstraints.dispatchModel(nil), "nil config")
    TestRunner:assertNil(ModelConstraints.dispatchModel("groq"), "string config")
end)

TestRunner:suite("one key: the memo written and read through the resolver agree")

TestRunner:test("a nil-model config records and reads the plan under the same key (F3)", function()
    local RL = require("koassistant_rate_limits")
    RL._reset()
    -- The probe learns the allowance for the model it tested...
    local probe_key = ModelConstraints.dispatchModel({ provider = "groq", model = Defaults.ProviderDefaults.groq.model })
    RL.record("groq", probe_key, { limit_tokens = "8000" }, "probe")
    -- ...and the request whose config.model is nil (first API key save) reads it back.
    local cfg = { provider = "groq" }  -- model deliberately nil
    local dispatch_key = ModelConstraints.dispatchModel(cfg)
    TestRunner:assertEqual(dispatch_key, probe_key, "same string on both sides")
    TestRunner:assertTrue(RL.known("groq", dispatch_key) ~= nil, "the plan is visible to the dispatch read")
    TestRunner:assertEqual(RL.budgetCap("groq", dispatch_key, 0, 211), 8000 - 211 - RL.MARGIN, "cap applies")
    -- The bug this replaces: the bare config.model read landed in the "?" bucket.
    TestRunner:assertNil(RL.known("groq", cfg.model), "the raw nil model finds nothing")
    RL._reset()
end)

-- ===========================================================================
-- Router-level cases: what koassistant_gpt_query.lua actually puts on the wire.
--
-- The cap block runs synchronously inside dispatchRequest, before handler:query,
-- and a handler whose `query` returns a plain string takes the router's
-- synchronous return path (no fork, no scheduler, no stream dialog). So a stub
-- handler is enough to read back the budget the plan cap produced, and the
-- widgets the pre-send notice raised.
--
-- The STREAMING half is covered by the structural gate below on the one line
-- that feeds it (stream_handler.lua records the plan headers under
-- settings.model, which the router fills from the resolved id) plus
-- tests/unit/test_stream_ratelimit_marker.lua, which drives the real streaming
-- loop over a recorded pipe.
-- ===========================================================================

local RL = require("koassistant_rate_limits")

-- Everything the router touches on this path, restored at the end of the file:
-- the harness loadfile()s every unit test into ONE Lua state.
local SAVED_KEYS = {
    "ui/network/manager", "koassistant_api.ollama", "ui/uimanager",
    "ui/widget/infomessage", "ui/widget/notification", "koassistant_gpt_query",
}
local saved = {}
for _idx, k in ipairs(SAVED_KEYS) do saved[k] = package.loaded[k] end

-- The stub handler. The router fills its handlers table with
-- require("koassistant_api." .. name) at LOAD time, so this preloaded entry
-- must be in place before the module is required (below). Provider "ollama"
-- needs no API key.
local calls = {}
package.loaded["koassistant_api.ollama"] = {
    query = function(_self, _message_history, cfg)
        calls[#calls + 1] = { max_tokens = cfg.api_params and cfg.api_params.max_tokens }
        return "ok"
    end,
}
-- The WiFi gate: runWhenConnected runs its callback synchronously when the
-- device is already connected, which is what the router relies on.
package.loaded["ui/network/manager"] = {
    runWhenConnected = function(_self, cb) return cb() end,
}

-- Widgets: record what a reader would have seen. The notice and the pin
-- notification are scheduled 0.8s out (the ollama warn-before-send precedent),
-- so scheduleIn runs the callback at once here.
local shown = {}
local function widgetStub(kind)
    return { new = function(_self, o) o = o or {}; o._kind = kind; return o end }
end
package.loaded["ui/widget/infomessage"] = widgetStub("info")
package.loaded["ui/widget/notification"] = widgetStub("notification")
package.loaded["ui/uimanager"] = {
    show = function(_self, w) shown[#shown + 1] = w end,
    close = function() end,
    unschedule = function() end,
    forceRePaint = function() end,
    scheduleIn = function(_self, _sec, fn) if fn then fn() end end,
}

package.loaded["koassistant_gpt_query"] = nil
local Query = require("koassistant_gpt_query")

--- One request through the real router. Returns nothing: the assertions read
--- `calls` (the wire) and `shown` (the widgets).
local function runQuery(cfg, text)
    calls, shown = {}, {}
    Query.query({ { role = "user", content = text or string.rep("x", 300) } }, cfg, nil, nil)
end

local function shownOfKind(kind)
    for _idx = 1, #shown do
        if shown[_idx]._kind == kind then return shown[_idx] end
    end
    return nil
end

TestRunner:suite("the dispatch caps the wire budget under the resolved model id")

TestRunner:test("a nil-model config is capped by the plan recorded for its default (a)", function()
    RL._reset()
    local cfg = { provider = "ollama", features = {} }
    local resolved = ModelConstraints.dispatchModel(cfg)
    TestRunner:assertTrue(resolved ~= nil, "fixture: ollama has a default model")
    RL.record("ollama", resolved, { limit_tokens = "8000" }, "header")
    local cap = RL.budgetCap("ollama", resolved, 300)
    TestRunner:assertTrue(cap < ModelConstraints.effectiveMaxTokens("ollama", resolved, cfg),
        "fixture: the cap really is below the handler's own budget")
    runQuery(cfg)
    TestRunner:assertEqual(#calls, 1, "one request went out")
    TestRunner:assertEqual(calls[1].max_tokens, cap, "the wire budget is the plan cap")
    TestRunner:assertEqual(#shown, 0, "an unpinned default being sized down is silent")
    RL._reset()
end)

TestRunner:test("the plan filed under the WRONG key never binds (a2, the measured F3 failure)", function()
    RL._reset()
    local cfg = { provider = "ollama", features = {} }
    -- What the shipped code did: the refusal/header writer resolved the default
    -- while the sizing read passed a bare nil config.model, so the allowance
    -- landed in the "ollama/?" bucket the cap never reads.
    RL.record("ollama", nil, { limit_tokens = "8000" }, "header")
    runQuery(cfg)
    TestRunner:assertEqual(#calls, 1, "the request still goes out")
    TestRunner:assertEqual(calls[1].max_tokens, nil, "no cap: the handler's own default went out")
    RL._reset()
end)

TestRunner:test("a provider_settings model entry is NOT the key (d): no handler reads that slot", function()
    -- Every handler sends `config.model or defaults.model`; the merge copies the
    -- top-level model INTO provider_settings, never out of it. A stale entry
    -- there must not key the memo under a model the wire never carries.
    RL._reset()
    local cfg = { provider = "ollama", features = {},
        provider_settings = { ollama = { model = "stale-entry" } } }
    local Defaults = require("koassistant_api.defaults")
    TestRunner:assertEqual(ModelConstraints.dispatchModel(cfg), Defaults.ProviderDefaults.ollama.model,
        "resolves to the provider default the wire carries")
    RL.record("ollama", "stale-entry", { limit_tokens = "8000" }, "header")
    runQuery(cfg)
    TestRunner:assertEqual(calls[1].max_tokens, nil, "a memo under the stale entry never caps")
    RL._reset()
end)

TestRunner:suite("a cut PIN is said out loud (F9)")

TestRunner:test("a 65536 pin cut to the cap shows one notification (b)", function()
    RL._reset()
    local cfg = { provider = "ollama", features = {}, api_params = { max_tokens = 65536 } }
    local resolved = ModelConstraints.dispatchModel(cfg)
    -- 20356 - 100 (300 chars / 3) - MARGIN = 20000 exactly.
    RL.record("ollama", resolved, { limit_tokens = "20356" }, "header")
    runQuery(cfg)
    TestRunner:assertEqual(calls[1].max_tokens, 20000, "the pin went out at the cap")
    local note = shownOfKind("notification")
    TestRunner:assertTrue(note ~= nil, "a notification was shown")
    TestRunner:assertTrue(note.text:find("Answer budget reduced", 1, true) ~= nil,
        "it says the budget was reduced: " .. tostring(note.text))
    TestRunner:assertTrue(note.text:find("65536", 1, true) and note.text:find("20000", 1, true),
        "with both numbers: " .. tostring(note.text))
    RL._reset()
end)

TestRunner:test("an unattended request keeps the pin cut silent (all three flags)", function()
    for _idx, flags in ipairs({ { _background_request = true }, { hidden_streaming = true },
                                { _suppress_loading_dialog = true } }) do
        RL._reset()
        local cfg = { provider = "ollama", api_params = { max_tokens = 65536 }, features = flags }
        RL.record("ollama", ModelConstraints.dispatchModel(cfg), { limit_tokens = "20356" }, "header")
        runQuery(cfg)
        TestRunner:assertEqual(calls[1].max_tokens, 20000, "still capped")
        TestRunner:assertEqual(#shown, 0, "nothing raised over an unattended request")
    end
    RL._reset()
end)

TestRunner:suite("say it before sending, when the plan cannot admit the prompt (B14)")

local BIG = string.rep("x", 30000)   -- ~10,000 tokens at 3 bytes/token

TestRunner:test("the notice names the plan, and the request still goes out (c)", function()
    RL._reset()
    local cfg = { provider = "ollama", features = {} }
    RL.record("ollama", ModelConstraints.dispatchModel(cfg), { limit_tokens = "8000" }, "header")
    runQuery(cfg, BIG)
    TestRunner:assertEqual(#calls, 1, "never blocked on an estimate: the request went out")
    local msg = shownOfKind("info")
    TestRunner:assertTrue(msg ~= nil, "a notice was shown")
    TestRunner:assertTrue(msg.text:find("larger than your plan allows", 1, true) ~= nil,
        "per-minute wording: " .. tostring(msg.text))
    TestRunner:assertTrue(msg.text:find("tokens a minute", 1, true) ~= nil, "names the bucket")
    TestRunner:assertTrue(msg.text:find("your ollama plan", 1, true) ~= nil, "names the provider")
    TestRunner:assertTrue(msg.text:find("8000", 1, true) and msg.text:find("10000", 1, true),
        "carries the allowance and the estimate: " .. tostring(msg.text))
    RL._reset()
end)

TestRunner:test("a context-window entry gets the other wording", function()
    RL._reset()
    local cfg = { provider = "ollama", features = {} }
    -- The same memo slot also holds a model's context window, written by the
    -- self-heal from a 400 (audit F10/Q3): it is not a per-minute plan and must
    -- not be described as one.
    RL.record("ollama", ModelConstraints.dispatchModel(cfg), { limit_tokens = "8000" }, "context")
    runQuery(cfg, BIG)
    local msg = shownOfKind("info")
    TestRunner:assertTrue(msg ~= nil, "a notice was shown")
    TestRunner:assertTrue(msg.text:find("context window", 1, true) ~= nil,
        "context wording: " .. tostring(msg.text))
    TestRunner:assertTrue(msg.text:find("a minute", 1, true) == nil, "and never claims a plan")
    RL._reset()
end)

TestRunner:test("unattended requests raise nothing", function()
    local cases = {
        { _background_request = true },
        { hidden_streaming = true },
        { _suppress_loading_dialog = true },
    }
    for _idx = 1, #cases do
        RL._reset()
        local cfg = { provider = "ollama", features = cases[_idx] }
        RL.record("ollama", ModelConstraints.dispatchModel(cfg), { limit_tokens = "8000" }, "header")
        runQuery(cfg, BIG)
        TestRunner:assertEqual(#calls, 1, "the request still went out")
        TestRunner:assertEqual(#shown, 0, "no widget for an unattended request " .. _idx)
    end
    RL._reset()
end)

TestRunner:test("an unknown plan says nothing at all", function()
    RL._reset()
    runQuery({ provider = "ollama", features = {} }, BIG)
    TestRunner:assertEqual(#calls, 1, "sent")
    TestRunner:assertEqual(#shown, 0, "nothing is invented when the plan is unknown")
end)

TestRunner:suite("the burst rule: a spent allowance is never resent (B1)")

-- (e) The self-heal itself cannot be driven from here. It runs ONLY from the
-- two failure branches that need a real subprocess: the non-streaming
-- background poll loop (ffiutil.runInSubProcess + ffi.C.read + a scheduler) and
-- the stream dialog's completion callback. A handler that returns a string, or
-- an "Error: ..." string, never reaches either: the router treats a returned
-- string as CONTENT and a pcall failure as a plain error. Driving it would mean
-- a second copy of test_stream_ratelimit_marker.lua's replay transport, so the
-- decision itself is asserted here through the functions the router calls, on
-- the exact wordings from the error corpus, plus a source-order gate below.
local BURST = "Rate limit reached for model `gemma2-9b-it` in organization `...` service tier "
    .. "`on_demand` on tokens per minute (TPM): Limit 15000, Used 11972, Requested 4351. "
    .. "Please try again in 5.289s. Visit https://console.groq.com/docs/rate-limits for more "
    .. "information."
-- Groq's other 429 shape: "Used 0" and a request larger than the whole allowance.
-- Read off the numbers it is an admission refusal: no wait admits it, a smaller
-- answer budget can (re-audit 2026-09-04; the old "Used means burst" rule never resent it).
local USED0 = "Rate limit reached for model `llama3-70b-8192` in organization "
    .. "`org_01hrsvc1b8ey0anvbgha0xckf2` on tokens per minute (TPM): Limit 7000, Used 0, "
    .. "Requested ~12903. Please try again in 50.597142857s."
local ADMISSION = "Request too large for model `openai/gpt-oss-20b` in organization `org_01kx` "
    .. "service tier `on_demand` on tokens per minute (TPM): Limit 8000, Requested 32979, please "
    .. "reduce your message size and try again. Need more tokens? Upgrade to Dev Tier today at "
    .. "https://console.groq.com/settings/billing"

TestRunner:test("a burst still teaches the session its allowance", function()
    RL._reset()
    local refusal = RL.parseRefusal(BURST)
    TestRunner:assertEqual(refusal.limit, 15000, "the provider's own number, not the 2 of gemma2")
    TestRunner:assertTrue(RL.record("groq", "gemma2-9b-it",
        { limit_tokens = refusal.limit }, "refusal"), "recorded")
    TestRunner:assertEqual(RL.known("groq", "gemma2-9b-it").limit_tokens, 15000, "and readable")
    RL._reset()
end)

TestRunner:test("but is never resent, though a resend budget exists", function()
    TestRunner:assertEqual(RL.refusalKind(BURST), "burst", "classified as a burst")
    -- The rule is load-bearing: without it the router WOULD have resent, because
    -- retryBudget answers with a number. A burst refills with time, not with a
    -- smaller request, so that resend is a second doomed round trip.
    TestRunner:assertTrue(RL.retryBudget(RL.parseRefusal(BURST), 32768, 300) ~= nil,
        "retryBudget would have offered a budget")
end)

TestRunner:test("an admission refusal is the one that is resent", function()
    TestRunner:assertEqual(RL.refusalKind(ADMISSION), "admission", "classified as admission")
    local budget = RL.retryBudget(RL.parseRefusal(ADMISSION), 32768, 300)
    TestRunner:assertTrue(budget ~= nil and budget > 0, "and a budget to resend at")
    -- "Used 0" with requested > limit: by the numbers a refusal no wait can heal
    TestRunner:assertEqual(RL.refusalKind(USED0), "admission", "Used 0 + requested > limit is admission")
    -- The resend is sized from the refusal's exact prompt count (requested minus
    -- the budget sent): with a 12000 budget sent the prompt was 903 tokens and a
    -- resend fits; with 4096 sent it was 8807, more than the whole allowance, and
    -- nothing is resent (the error then explains the lever).
    TestRunner:assertTrue(RL.retryBudget(RL.parseRefusal(USED0), 12000, 300) ~= nil, "resent smaller when the prompt fits")
    TestRunner:assertNil(RL.retryBudget(RL.parseRefusal(USED0), 4096, 300), "no resend when the prompt alone does not fit")
end)

TestRunner:test("the second pass and the non-streaming consumer are wired (source gates)", function()
    -- The four fixes the Stage 0 verifiers demanded are control-flow facts in
    -- closures a stub handler cannot reach (mutation testing 2026-09-04 showed
    -- every one of them could be deleted with the suite still green), so pin
    -- them by source: (1) the pinned-budget notification and the pre-send notice
    -- fire on the FIRST pass only; (2) the resend is sized from the refusal's
    -- exact prompt count; (3) the non-streaming consumer strips the marker line
    -- and records it under the ONE dispatch model.
    local fh = io.open(plugin_dir .. "/koassistant_gpt_query.lua", "r")
    TestRunner:assertTrue(fh ~= nil, "cannot read the router")
    local src = fh:read("*a")
    fh:close()
    local function count(needle)
        local n, pos = 0, 1
        while true do
            local at = src:find(needle, pos, true)
            if not at then return n end
            n, pos = n + 1, at + 1
        end
    end
    TestRunner:assertTrue(count("and first_pass") >= 2, "both notices are gated on the first pass")
    TestRunner:assertEqual(count("budgetCap(provider, dispatch_model, prompt_chars, exact_prompt_tokens)"), 1,
        "the cap takes the exact prompt count from the refusal")
    TestRunner:assertEqual(count("exact_prompt_tokens = RateLimits.promptTokensFromRefusal(refusal, sent)"), 1,
        "the admission resend records the exact prompt count")
    TestRunner:assertEqual(count("RateLimits.extractMarker(full_response)"), 1, "non-streaming: the marker is extracted")
    TestRunner:assertEqual(count("full_response = cleaned"), 1, "non-streaming: and stripped from the body")
    TestRunner:assertEqual(count('RateLimits.record(provider, dispatch_model, rl_fields, "header")'), 1,
        "non-streaming: recorded under the dispatch model")
end)

TestRunner:test("ConfigHelper:getModelInfo records the wire's model id, never the provider_settings slot", function()
    local ConfigHelper = require("koassistant_config_helper")
    local cfg = { provider = "ollama", provider_settings = { ollama = { model = "stale-entry" } }, features = {} }
    TestRunner:assertEqual(ConfigHelper:getModelInfo(cfg), ModelConstraints.dispatchModel(cfg),
        "the same id the memo and the budget use")
    TestRunner:assertTrue(ConfigHelper:getModelInfo(cfg) ~= "stale-entry", "not the slot no handler reads")
    TestRunner:assertEqual(ConfigHelper:getModelInfo({ provider = "ollama", model = "picked", features = {} }),
        "picked", "an explicit pick wins")
    TestRunner:assertEqual(ConfigHelper:getModelInfo(nil), "default", "nil config keeps the old fallback")
end)

TestRunner:test("the classification survives DECORATION (the non-streaming path)", function()
    -- The non-streaming failure branch hands the self-heal the error AFTER
    -- decorateRequestError appended its explanation, so the appended prose is
    -- itself input to refusalKind. A hint that said "used" would flip an
    -- admission refusal into a burst and kill the resend.
    for _idx, case in ipairs({ { BURST, "burst" }, { ADMISSION, "admission" } }) do
        local decorated = ModelConstraints.decorateRequestError(
            case[1], "groq", "openai/gpt-oss-20b", { features = {} })
        TestRunner:assertEqual(RL.refusalKind(decorated), case[2],
            "case " .. _idx .. ": decorated text keeps its kind")
    end
end)

-- ---------------------------------------------------------------------------
-- (g) The self-heal's second pass, DRIVEN (re-audit 2026-09-04, F6/F18): the
-- router requires stream_handler lazily at dispatch, so a fake one can hand the
-- first stream an admission refusal computed from the budget that actually went
-- out and let the second succeed. The stub handler returns a function, which
-- takes the router's streaming path (the shipped default). Everything is put
-- back at the end of the section.
-- ---------------------------------------------------------------------------
TestRunner:suite("the second pass, driven through a fake stream handler")

do
    local handler = package.loaded["koassistant_api.ollama"]
    local real_query = handler.query
    local saved_stream = package.loaded["stream_handler"]
    -- What the fake provider refuses with, per case: a function of the budget sent.
    local refusal_for = nil
    handler.query = function(_self, _message_history, cfg)
        calls[#calls + 1] = { max_tokens = cfg.api_params and cfg.api_params.max_tokens, cfg = cfg }
        return function() end  -- a stream_fn
    end
    package.loaded["stream_handler"] = {
        new = function()
            return {
                showStreamDialog = function(_s, _fn, _prov, _model, _settings, cb)
                    if #calls == 1 and refusal_for then
                        local sent = calls[1].max_tokens
                            or ModelConstraints.effectiveMaxTokens("ollama",
                                ModelConstraints.dispatchModel(calls[1].cfg), calls[1].cfg)
                        cb(false, nil, refusal_for(sent))
                    else
                        cb(true, "done", nil)
                    end
                end,
            }
        end,
    }
    local function admission(prompt_tokens)
        return function(sent)
            return "Request too large for model `openai/gpt-oss-20b` in organization `org_01kx` "
                .. "service tier `on_demand` on tokens per minute (TPM): Limit 8000, Requested "
                .. tostring(prompt_tokens + sent) .. ", please reduce your message size and try again."
        end
    end
    local function runStreaming(cfg, bytes)
        RL._reset()
        runQuery(cfg, string.rep("x", bytes))
    end
    local model = ModelConstraints.dispatchModel({ provider = "ollama", features = {} })

    TestRunner:test("an admission refusal is resent once, at the exact prompt count", function()
        refusal_for = admission(211)
        runStreaming({ provider = "ollama", features = {}, api_params = { max_tokens = 65536 } }, 300)
        TestRunner:assertEqual(#calls, 2, "refused once, resent once")
        TestRunner:assertEqual(calls[2].max_tokens, 8000 - 211 - RL.MARGIN, "resend budget = allowance - exact prompt - margin")
        TestRunner:assertEqual(RL.known("ollama", model).limit_tokens, 8000, "the allowance was learned")
        TestRunner:assertEqual(shownOfKind("notification"), nil, "no pin notification: the first pass had no cap, the second is the cap")
    end)

    TestRunner:test("the resend is never re-capped from the byte estimate (exact_prompt_tokens)", function()
        -- 15000 bytes estimate to 5000 tokens, but the provider counted 3000: the
        -- resend must carry 8000 - 3000 - margin, not 8000 - 5000 - margin.
        refusal_for = admission(3000)
        runStreaming({ provider = "ollama", features = {} }, 15000)
        TestRunner:assertEqual(#calls, 2, "refused once, resent once")
        TestRunner:assertEqual(calls[2].max_tokens, 8000 - 3000 - RL.MARGIN, "sized from the refusal's exact count")
    end)

    TestRunner:test("the pre-send notice does not fire on the second pass (first_pass)", function()
        -- 30000 bytes estimate to 10000 tokens (more than the plan); the provider
        -- counted 5000, so the resend fits. On the second pass the memo is warm and
        -- promptExceedsPlan(estimate) would say "larger than your plan": that notice
        -- belongs to the first pass only.
        refusal_for = admission(5000)
        runStreaming({ provider = "ollama", features = {} }, 30000)
        TestRunner:assertEqual(#calls, 2, "refused once, resent once")
        TestRunner:assertEqual(calls[2].max_tokens, 8000 - 5000 - RL.MARGIN, "resent at the exact budget")
        TestRunner:assertEqual(shownOfKind("info"), nil, "no 'larger than your plan' notice on the resend")
    end)

    TestRunner:test("a burst is learned and never resent (B1's core rule, driven)", function()
        refusal_for = function() return BURST end
        runStreaming({ provider = "ollama", features = {} }, 300)
        TestRunner:assertEqual(#calls, 1, "no resend: the bucket refills with time")
        TestRunner:assertEqual(RL.known("ollama", model).limit_tokens, 15000, "but the allowance was learned")
    end)

    TestRunner:test("a numberless per-minute refusal is neither learned nor resent", function()
        refusal_for = function() return "Tokens per minute limit exceeded - too many tokens processed" end
        runStreaming({ provider = "ollama", features = {} }, 300)
        TestRunner:assertEqual(#calls, 1, "nothing to resend at")
        TestRunner:assertEqual(RL.known("ollama", model), nil, "nothing learned from a wording without numbers")
    end)

    refusal_for = nil
    handler.query = real_query
    package.loaded["stream_handler"] = saved_stream
    RL._reset()
end

-- ---------------------------------------------------------------------------
-- (f) STRUCTURAL GATE, in the shape of tests/unit/test_effective_props.lua's
-- raw-props scan: no sizing consumer may be handed a bare model read.
-- ---------------------------------------------------------------------------

local SINKS = { "RateLimits.", "effectiveMaxTokens(", "checkContextWindow(", "showStreamDialog(" }
local READS = { "config.model", "configuration.model", "temp_config.model" }

local function hasAny(line, list)
    for _idx = 1, #list do
        if line:find(list[_idx], 1, true) then return true end
    end
    return false
end

TestRunner:suite("structural gate: one model id, checked in the source")

TestRunner:test("no bare config.model reaches a sizing consumer", function()
    local dir = plugin_dir
    local offenders = {}
    for _idx, name in ipairs({ "koassistant_gpt_query.lua", "koassistant_dialogs.lua" }) do
        local fh = io.open(dir .. "/" .. name, "r")
        TestRunner:assertTrue(fh ~= nil, "cannot read " .. name)
        local n, prev = 0, ""
        for line in fh:lines() do
            n = n + 1
            local exempt = line:find("dispatchModel", 1, true) or prev:find("dispatchModel", 1, true)
                or line:find("-- raw-model:", 1, true)
            -- Two-line window: a sink and its model argument are routinely on
            -- separate lines (showStreamDialog, decorateRequestError).
            if hasAny(line, READS) and (hasAny(line, SINKS) or hasAny(prev, SINKS)) and not exempt then
                offenders[#offenders + 1] = name .. ":" .. n .. "  " .. line:match("^%s*(.-)%s*$")
            -- A model read ALONE on its line is a positional argument to a call
            -- opened further up (showStreamDialog spreads over five lines), which
            -- the window above cannot see. Neither file has a legitimate one.
            elseif line:match("^%s*config%.model,?%s*$")
                or line:match("^%s*configuration%.model,?%s*$")
                or line:match("^%s*temp_config%.model,?%s*$") then
                offenders[#offenders + 1] = name .. ":" .. n .. "  (bare model argument)"
            end
            -- The stream settings feed: stream_handler records the plan headers
            -- under settings.model. Router only: `model = config.model` is an
            -- ordinary table field elsewhere (the quick-reply snapshot).
            if name == "koassistant_gpt_query.lua"
                and line:find("model = config.model", 1, true) and not exempt then
                offenders[#offenders + 1] = name .. ":" .. n .. "  (stream settings feed)"
            end
            prev = line
        end
        fh:close()
    end
    if #offenders > 0 then
        error("a size guard is reading a bare model id (resolve it once with "
            .. "ModelConstraints.dispatchModel, or mark '-- raw-model: <reason>'):\n        "
            .. table.concat(offenders, "\n        "))
    end
end)

TestRunner:test("the router's prompt-size figure is the module's own (B14 call site)", function()
    -- test_prompt_chars.lua proves promptChars matches the old closure; this line
    -- proves the router still feeds it the same two arguments (a changed call
    -- site would silently stop the notice for system-prompt-heavy requests).
    local fh = io.open(plugin_dir .. "/koassistant_gpt_query.lua", "r")
    local src = fh:read("*a"); fh:close()
    TestRunner:assertTrue(src:find(
        "RateLimits.promptChars(config.system and config.system.text, message_history)", 1, true) ~= nil,
        "the router calls promptChars with the system text and the history")
end)

TestRunner:test("the router records a per-minute refusal BEFORE it decides not to resend", function()
    -- Source order, because the behaviour is a control-flow fact: a burst must
    -- still teach the session its allowance, and only then stand down; and the
    -- burst return must sit ahead of the resend arithmetic.
    local fh = io.open(plugin_dir .. "/koassistant_gpt_query.lua", "r")
    TestRunner:assertTrue(fh ~= nil, "cannot read the router")
    local n, at_record, at_burst, at_retry = 0, nil, nil, nil
    for line in fh:lines() do
        n = n + 1
        if not at_record and line:find('{ limit_tokens = refusal.limit }, "refusal"', 1, true) then
            at_record = n
        end
        if not at_burst and line:find('RateLimits.refusalKind(err) == "burst"', 1, true) then
            at_burst = n
        end
        if not at_retry and line:find("RateLimits.retryBudget(", 1, true) then at_retry = n end
    end
    fh:close()
    TestRunner:assertTrue(at_record ~= nil, "the refusal is recorded")
    TestRunner:assertTrue(at_burst ~= nil, "the burst is classified")
    TestRunner:assertTrue(at_retry ~= nil, "the resend budget is computed")
    TestRunner:assertTrue(at_record < at_burst, "record first, so a burst still teaches the allowance")
    TestRunner:assertTrue(at_burst < at_retry, "and the burst stands down before the resend")
end)

-- ---------------------------------------------------------------------------
RL._reset()
package.loaded["koassistant_gpt_query"] = nil
for _idx, k in ipairs(SAVED_KEYS) do package.loaded[k] = saved[k] end

print(string.format("\n  test_dispatch_sizing: %d passed, %d failed", TestRunner.passed, TestRunner.failed))
return TestRunner.failed == 0
