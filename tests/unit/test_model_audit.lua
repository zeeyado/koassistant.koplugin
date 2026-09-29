-- Unit tests for the pure helpers in tests/model_audit.lua (agenda item 20):
-- diff/noise/snapshot classification, ceiling parsing, reasoning evidence,
-- and draft-stanza emission. No API calls (the probe engine itself is live-only).
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

local ModelAudit = require("model_audit")

--==========================================================================
TestRunner:suite("Noise filter")

TestRunner:check("openai whisper-1 is noise", ModelAudit.isNoise("openai", "whisper-1") ~= nil)
TestRunner:check("openai text-embedding-3-large is noise",
    ModelAudit.isNoise("openai", "text-embedding-3-large") ~= nil)
TestRunner:check("openai gpt-5.7 is NOT noise", ModelAudit.isNoise("openai", "gpt-5.7") == nil)
TestRunner:check("openai *-pro is noise (responses-only variants)",
    ModelAudit.isNoise("openai", "gpt-5.6-sol-pro") ~= nil)
TestRunner:check("gemini gemma is noise", ModelAudit.isNoise("gemini", "gemma-3-27b-it") ~= nil)
TestRunner:check("gemini video-understanding EAP variant is noise",
    ModelAudit.isNoise("gemini", "gemini-3.7-flash-video-understanding-eap") ~= nil)
TestRunner:check("gemini-2.5-pro is NOT noise (-pro list is openai-only)",
    ModelAudit.isNoise("gemini", "gemini-2.5-pro") == nil)
TestRunner:check("mistral mistral-large is NOT noise",
    ModelAudit.isNoise("mistral", "mistral-large-2512") == nil)

--==========================================================================
TestRunner:suite("Snapshot/alias detection")

local curated_set = { ["gpt-4o"] = true, ["gemini-2.5-flash"] = true, ["claude-sonnet-5"] = true }
TestRunner:check("dated snapshot maps to curated base",
    ModelAudit.isSnapshotOf("gpt-4o-2024-08-06", curated_set) == "gpt-4o")
TestRunner:check("-001 suffix maps to curated base",
    ModelAudit.isSnapshotOf("gemini-2.5-flash-001", curated_set) == "gemini-2.5-flash")
TestRunner:check("-latest alias maps to curated base",
    ModelAudit.isSnapshotOf("claude-sonnet-5-latest", curated_set) ~= nil)
TestRunner:check("genuinely new id is not a snapshot",
    ModelAudit.isSnapshotOf("gpt-5.7", curated_set) == nil)
TestRunner:check("dated id with uncurated base is not a snapshot",
    ModelAudit.isSnapshotOf("gpt-6-2027-01-01", curated_set) == nil)

local latest_set = { ["magistral-medium-latest"] = true, ["codestral-latest"] = true }
TestRunner:check("mistral YYMM snapshot maps to curated -latest alias",
    ModelAudit.isSnapshotOf("magistral-medium-2509", latest_set) == "magistral-medium-latest")
TestRunner:check("codestral-2508 maps to codestral-latest",
    ModelAudit.isSnapshotOf("codestral-2508", latest_set) == "codestral-latest")
TestRunner:check("YYMM id with uncurated alias is not a snapshot",
    ModelAudit.isSnapshotOf("devstral-2512", latest_set) == nil)

--==========================================================================
TestRunner:suite("diffLists")

local NOW = 1785000000  -- fixed fake "now" so the test is deterministic
local fetched = {
    ["m-a"] = {},                                          -- curated, present
    ["m-new"] = { created = NOW - 86400 },                 -- fresh
    ["m-old"] = { created = NOW - 300 * 86400 },           -- released long ago
    ["m-a-2025-01-01"] = {},                               -- snapshot of curated
    ["whisper-x"] = {},                                    -- noise (openai list)
    ["m-undated"] = {},                                    -- no timestamp -> treat recent
}
local diff = ModelAudit.diffLists("openai", { "m-a", "m-b" }, fetched, NOW)

TestRunner:check("known counted", diff.known == 1, diff.known)
TestRunner:check("fresh id lands in new", #diff.new == 2 and diff.new[1] == "m-new" or diff.new[2] == "m-new")
TestRunner:check("undated id lands in new (loud beats silent)",
    (diff.new[1] == "m-undated" or diff.new[2] == "m-undated") and #diff.new == 2)
TestRunner:check("old id lands in stale", #diff.stale == 1 and diff.stale[1] == "m-old")
TestRunner:check("snapshot bucketed", #diff.snapshots == 1 and diff.snapshots[1] == "m-a-2025-01-01")
TestRunner:check("noise bucketed", #diff.ignored == 1 and diff.ignored[1] == "whisper-x")
TestRunner:check("curated-but-absent flagged removed", #diff.removed == 1 and diff.removed[1] == "m-b")

local diff_no_now = ModelAudit.diffLists("openai", { "m-a", "m-b" }, fetched, nil)
TestRunner:check("without `now` everything uncurated is new",
    #diff_no_now.new == 3 and #diff_no_now.stale == 0)

local skip_diff = ModelAudit.diffLists("anthropic", { "claude-opus-4-8" },
    { ["claude-opus-4-6"] = {}, ["claude-opus-4-8"] = {} }, NOW)
TestRunner:check("deliberate skip bucketed with its reason",
    #skip_diff.deliberate == 1 and skip_diff.deliberate[1].id == "claude-opus-4-6"
    and type(skip_diff.deliberate[1].reason) == "string")
TestRunner:check("deliberate skip stays out of new", #skip_diff.new == 0)

--==========================================================================
TestRunner:suite("modelTimestamp")

TestRunner:check("epoch `created` passes through", ModelAudit.modelTimestamp({ created = 123 }) == 123)
local iso_ts = ModelAudit.modelTimestamp({ created_at = "2026-07-24T10:00:00Z" })
TestRunner:check("ISO created_at parses to a number", type(iso_ts) == "number")
TestRunner:check("no timestamp -> nil", ModelAudit.modelTimestamp({}) == nil)
TestRunner:check("non-table -> nil", ModelAudit.modelTimestamp(nil) == nil)

--==========================================================================
TestRunner:suite("parseCeiling")

TestRunner:check("anthropic-style ceiling parsed",
    ModelAudit.parseCeiling(
        "max_tokens: 10000000 > 128000, which is the maximum allowed number of output tokens for claude-opus-5",
        10000000) == 128000)
TestRunner:check("date-like model-id digits do not poison the parse",
    ModelAudit.parseCeiling(
        "max_tokens: 10000000 > 8192, which is the maximum for claude-haiku-4-5-20251001",
        10000000) == 8192)
TestRunner:check("no candidate number -> nil",
    ModelAudit.parseCeiling("invalid request: streaming is required", 10000000) == nil)
TestRunner:check("echo of the sent value alone -> nil",
    ModelAudit.parseCeiling("max_tokens 10000000 is invalid", 10000000) == nil)
-- T7 fix (2026-08-14): the vLLM-family CONTEXT error echoes the request total,
-- which the largest-number rule would misread as the ceiling.
TestRunner:check("vLLM context error returns the stated context length, not the request total",
    ModelAudit.parseCeiling(
        "This model's maximum context length is 12288 tokens. However, you requested 20480 tokens (8192 in the messages, 12288 in the completion).",
        10000000) == 12288)
TestRunner:check("context window phrasing also matched",
    ModelAudit.parseCeiling("input exceeds the context window of 131072 tokens (you sent 200000)",
        10000000) == 131072)
-- #106 (2026-09-07): a per-minute admission refusal states the PLAN's
-- allowance; drafting it as the model's ceiling would bake a plan constant.
TestRunner:check("per-minute admission refusal is not a ceiling",
    ModelAudit.parseCeiling(
        "Request too large for model `openai/gpt-oss-20b` in organization `org_x` service tier `on_demand` on tokens per minute (TPM): Limit 8000, Requested 10000211, please reduce your message size and try again.",
        10000000) == nil)

--==========================================================================
TestRunner:suite("real-shape helpers (T7 hardening)")

local nested = { a = {}, b = { c = {}, d = { 1, 2 } }, e = "x" }
local copy = ModelAudit.deepcopy(nested)
TestRunner:check("deepcopy: distinct tables, equal leaves",
    copy ~= nested and copy.b ~= nested.b and copy.b.d[2] == 2 and copy.e == "x")
ModelAudit.markEmptyObjects(copy)
TestRunner:check("markEmptyObjects: empty tables tagged __jsontype=object",
    getmetatable(copy.a) and getmetatable(copy.a).__jsontype == "object"
    and getmetatable(copy.b.c) and getmetatable(copy.b.c).__jsontype == "object")
TestRunner:check("markEmptyObjects: non-empty tables untouched",
    getmetatable(copy.b) == nil and getmetatable(copy.b.d) == nil)
TestRunner:check("markEmptyObjects: original specs never mutated (deepcopy first)",
    getmetatable(nested.a) == nil)

--==========================================================================
TestRunner:suite("errText / reasoningEvidence")

TestRunner:check("nested error.message extracted",
    ModelAudit.errText({ error = { message = "boom" } }) == "boom")
TestRunner:check("string error extracted", ModelAudit.errText({ error = "plain" }) == "plain")
TestRunner:check("falls back to raw text", ModelAudit.errText(nil, "raw body") == "raw body")

TestRunner:check("reasoning_tokens evidence",
    ModelAudit.reasoningEvidence({ usage = { completion_tokens_details = { reasoning_tokens = 42 } } })
        == "reasoning_tokens=42")
TestRunner:check("reasoning_content evidence",
    ModelAudit.reasoningEvidence({ choices = { { message = { reasoning_content = "hm" } } } }) ~= nil)
TestRunner:check("<think> tag evidence",
    ModelAudit.reasoningEvidence({ choices = { { message = { content = "<think>x</think>ok" } } } }) ~= nil)
TestRunner:check("plain completion -> no evidence",
    ModelAudit.reasoningEvidence({ choices = { { message = { content = "ok" } } },
                                   usage = { completion_tokens_details = { reasoning_tokens = 0 } } }) == nil)

--==========================================================================
TestRunner:suite("draftStanzas: anthropic adaptive (opus-5-shaped)")

local afacts = {
    family = "anthropic", provider = "anthropic", model = "claude-test-9",
    reachable = true, default_reasoning = true, temp_ok = false, disable_ok = true,
    adaptive_ok = true, budget_ok = false,
    ladder = { "low", "medium", "high", "xhigh", "max" },
    efforts = { low = true, medium = true, high = true, xhigh = true, max = true },
    ceiling = 128000, tools_ok = true, probes = {},
}
local acurrent = ModelAudit.currentResolution("anthropic", "claude-test-9")
local atext = table.concat(ModelAudit.draftStanzas(afacts, acurrent), "\n")

TestRunner:check("adaptive_thinking flagged for curation",
    atext:find('adaptive_thinking', 1, true) and atext:find("NEEDS CURATION", 1, true) ~= nil)
TestRunner:check("no_sampling_params capability drafted",
    atext:find('no_sampling_params', 1, true) ~= nil)
TestRunner:check("tools already covered (claude family entry)",
    atext:find("already covered", 1, true) ~= nil)
TestRunner:check("profile stanza: adaptive_effort + default on",
    atext:find('{ match = "claude-test-9", axis = "adaptive_effort", default_state = "on",', 1, true) ~= nil)
TestRunner:check("full effort ladder in options",
    atext:find('options = { "low", "medium", "high", "xhigh", "max" }', 1, true) ~= nil)
TestRunner:check("needs_no_sampling flag drafted",
    atext:find("needs_no_sampling = true", 1, true) ~= nil)
TestRunner:check("minimal stance = off (disable accepted)",
    atext:find('minimal = { state = "off" }', 1, true) ~= nil)
TestRunner:check("maximum stance = max",
    atext:find('maximum = { state = "on", option = "max" }', 1, true) ~= nil)
TestRunner:check("ceiling stanza drafted",
    atext:find('["claude-test-9"] = 128000', 1, true) ~= nil)

--==========================================================================
TestRunner:suite("draftStanzas: openai gated effort (gpt-5.6-shaped)")

local ofacts = {
    family = "openai", provider = "openai", model = "gpt-9-test",
    reachable = true, default_reasoning = false, temp_ok = false,
    needs_max_completion_tokens = true, disable_ok = true,
    ladder = { "none", "minimal", "low", "medium", "high", "xhigh", "max" },
    efforts = { none = true, minimal = true, low = true, medium = true,
                high = true, xhigh = true, max = false },
    ceiling = 128000, tools_ok = true, probes = {},
}
local ocurrent = ModelAudit.currentResolution("openai", "gpt-9-test")
local otext = table.concat(ModelAudit.draftStanzas(ofacts, ocurrent), "\n")

TestRunner:check("temperature constraint stanza drafted",
    otext:find('["gpt-9-test"] = { temperature = 1.0 },', 1, true) ~= nil)
TestRunner:check("profile: effort axis, default off",
    otext:find('axis = "effort", default_state = "off",', 1, true) ~= nil)
TestRunner:check('options exclude "none", keep minimal..xhigh, drop rejected max',
    otext:find('options = { "minimal", "low", "medium", "high", "xhigh" }', 1, true) ~= nil)
TestRunner:check('off_option = "none" drafted',
    otext:find('off_option = "none"', 1, true) ~= nil)
TestRunner:check("reasoning_gated drafted (efforts accepted, default OFF)",
    otext:find("reasoning_gated", 1, true) ~= nil)
TestRunner:check("max_completion_tokens note points at openai.lua",
    otext:find("openai.lua", 1, true) ~= nil)
TestRunner:check("model_lists reminder present",
    otext:find("koassistant_model_lists.lua", 1, true) ~= nil)

--==========================================================================
TestRunner:suite("draftStanzas: binary axis (deepseek-shaped)")

local bfacts = {
    family = "openai", provider = "deepseek", model = "deepseek-test-x",
    reachable = true, default_reasoning = true, temp_ok = true,
    binary = true, binary_on_ok = true, binary_off_ok = true, disable_ok = true,
    efforts = {}, tools_ok = true, probes = {},
}
local bcurrent = ModelAudit.currentResolution("deepseek", "deepseek-test-x")
local btext = table.concat(ModelAudit.draftStanzas(bfacts, bcurrent), "\n")

TestRunner:check("binary profile stanza drafted",
    btext:find('axis = "binary", default_state = "on",', 1, true) ~= nil)
TestRunner:check("binary can_disable/can_enable from probes",
    btext:find("can_disable = true, can_enable = true },", 1, true) ~= nil)
TestRunner:check("no temperature constraint drafted when temp accepted",
    btext:find("temperature = 1.0", 1, true) == nil)

--==========================================================================
TestRunner:suite("looksLikeSSE + tool_choice/stream wire notes")

TestRunner:check("SSE: leading data line", ModelAudit.looksLikeSSE('data: {"x":1}\n\n') == true)
TestRunner:check("SSE: event line after preamble",
    ModelAudit.looksLikeSSE(': ping\nevent: message_start\ndata: {}\n') == true)
TestRunner:check("SSE: plain JSON body is not SSE",
    ModelAudit.looksLikeSSE('{"choices":[{"message":{}}]}') == false)
TestRunner:check("SSE: nil-safe", ModelAudit.looksLikeSSE(nil) == false)

local zfacts = {
    family = "openai", provider = "zai", model = "glm-test-x",
    reachable = true, default_reasoning = true, temp_ok = true,
    binary = true, binary_on_ok = true, binary_off_ok = true, disable_ok = true,
    efforts = {}, tools_ok = true, probes = {},
    tool_choice_any_ok = false, tool_choice_any_thinking_off = true,
    tool_choice_none_ok = false, stream_ok = false,
}
local zcurrent = ModelAudit.currentResolution("zai", "glm-test-x")
local ztext = table.concat(ModelAudit.draftStanzas(zfacts, zcurrent), "\n")

TestRunner:check("gather-mode rejection note drafted (Z.AI class)",
    ztext:find("runner-incompatible as-is", 1, true) ~= nil)
TestRunner:check("thinking-disabled accommodation note drafted",
    ztext:find("thinking disabled - deepseek-style", 1, true) ~= nil)
TestRunner:check("final-pass (none) rejection note drafted",
    ztext:find("final pass needs an accommodation", 1, true) ~= nil)
TestRunner:check("stream-not-honored note drafted",
    ztext:find("stream=true not honored", 1, true) ~= nil)
TestRunner:check("no wire notes when tool_choice/stream fine",
    btext:find("runner-incompatible", 1, true) == nil
    and btext:find("stream=true not honored", 1, true) == nil)

--------------------------------------------------------------------------------
TestRunner:suite("Transient-error classification (retry gate)")

TestRunner:check("429 is transient", ModelAudit.isTransient(429, "") == true)
TestRunner:check("503 is transient", ModelAudit.isTransient(503, "whatever") == true)
TestRunner:check("529 (anthropic overloaded) is transient", ModelAudit.isTransient(529, "") == true)
TestRunner:check("nil code (network-layer failure) is transient",
    ModelAudit.isTransient(nil, "network: timeout") == true)
TestRunner:check("400 invalid-param is NOT transient",
    ModelAudit.isTransient(400, '{"error":{"message":"temperature is not supported"}}') == false)
TestRunner:check("non-429 with rate-limit body IS transient (mistral gated class)",
    ModelAudit.isTransient(400, "Rate limit exceeded") == true)
TestRunner:check("capacity message is transient (gemini high-demand class)",
    ModelAudit.isTransient(403, "This model is currently experiencing high demand.") == true)
TestRunner:check("permission denial is NOT transient (zai staged-rollout class)",
    ModelAudit.isTransient(403, "You do not have permission to access glm-5.3") == false)
TestRunner:check("string code with transient body still matches",
    ModelAudit.isTransient("closed", "connection reset, please retry") == true)

--------------------------------------------------------------------------------
TestRunner:suite("Watch-list classification")

local wcurated = { ["glm-5.2"] = true }
TestRunner:check("uncurated + unlisted -> watching",
    ModelAudit.watchStatus("glm-5.3", wcurated, {}) == "watching")
TestRunner:check("appears in fetched list -> listed",
    ModelAudit.watchStatus("glm-5.3", wcurated, { ["glm-5.3"] = {} }) == "listed")
TestRunner:check("curated wins over listed -> curated (delete reminder)",
    ModelAudit.watchStatus("glm-5.2", wcurated, { ["glm-5.2"] = {} }) == "curated")
TestRunner:check("nil fetched tolerated (no-adapter providers)",
    ModelAudit.watchStatus("x", wcurated, nil) == "watching")
TestRunner:check("every WATCH entry names an UNCURATED id (else the reminder is stale)",
    (function()
        local ModelLists = require("koassistant_model_lists")
        for provider, entries in pairs(ModelAudit.WATCH) do
            local cset = {}
            for _i, id in ipairs(ModelLists[provider] or {}) do cset[id] = true end
            for id in pairs(entries) do
                if cset[id] then return false end
            end
        end
        return true
    end)())

--------------------------------------------------------------------------------
TestRunner:suite("Recheck drift comparison")

local function rlevel(obs, current)
    local level = ModelAudit.recheckCompare(obs, current)
    return level
end

TestRunner:check("consistent default-on reasoning + temp passthrough -> ok",
    rlevel({ served = true, default_reasoning = true, temp_ok = true },
        { profile = { axis = "effort", default_state = "on" }, temp_after_apply = 0.7 }) == "ok")
TestRunner:check("not served -> drift with reason", (function()
    local level, reasons = ModelAudit.recheckCompare({ served = nil, err = "model_not_found" }, {})
    return level == "drift" and reasons[1]:find("not served", 1, true) ~= nil
end)())
TestRunner:check("reasons by default but profile axis none -> drift",
    rlevel({ served = true, default_reasoning = true, temp_ok = true },
        { profile = { axis = "none" }, temp_after_apply = 0.7 }) == "drift")
TestRunner:check("always-on documented via axis none + default on -> ok (magistral/grok-build class)",
    rlevel({ served = true, default_reasoning = true, temp_ok = true },
        { profile = { axis = "none", default_state = "on" }, temp_after_apply = 0.7 }) == "ok")
TestRunner:check("reasons by default but profile default off -> drift",
    rlevel({ served = true, default_reasoning = true, temp_ok = true },
        { profile = { axis = "effort", default_state = "off" }, temp_after_apply = 0.7 }) == "drift")
TestRunner:check("no evidence with profile-on -> warn only (some wires don't report)",
    rlevel({ served = true, default_reasoning = false, temp_ok = true },
        { profile = { axis = "binary", default_state = "on" }, temp_after_apply = 0.7 }) == "warn")
TestRunner:check("temp rejected but constraints pass it through -> drift (field 400s)",
    rlevel({ served = true, default_reasoning = false, temp_ok = false },
        { profile = { axis = "none" }, temp_after_apply = 0.7 }) == "drift")
TestRunner:check("temp rejected while constraints strip it -> consistent ok",
    rlevel({ served = true, default_reasoning = true, temp_ok = false },
        { profile = { axis = "adaptive_effort", default_state = "on" }, temp_after_apply = nil }) == "ok")
TestRunner:check("temp rejected while constraints force 1.0 -> consistent ok (gpt-5.6 class)",
    rlevel({ served = true, default_reasoning = false, temp_ok = false },
        { profile = { axis = "effort", default_state = "off" }, temp_after_apply = 1.0 }) == "ok")
TestRunner:check("temp accepted while constraints strip it -> warn (over-strict, not harmful)",
    rlevel({ served = true, default_reasoning = false, temp_ok = true },
        { profile = { axis = "none" }, temp_after_apply = nil }) == "warn")
TestRunner:check("temp inconclusive (quota) -> warn, never drift",
    rlevel({ served = true, default_reasoning = false, temp_ok = nil },
        { profile = { axis = "none" }, temp_after_apply = 0.7 }) == "warn")
TestRunner:check("nil profile tolerated (unknown model)",
    rlevel({ served = true, default_reasoning = false, temp_ok = true },
        { temp_after_apply = 0.7 }) == "ok")
TestRunner:check("temp rejected under no_sampling_params cap -> consistent ok (opus-5/fable class)",
    rlevel({ served = true, default_reasoning = true, temp_ok = false },
        { profile = { axis = "adaptive_effort", default_state = "on" },
          temp_after_apply = 0.7, caps = { no_sampling_params = true } }) == "ok")
TestRunner:check("quota-blocked model -> warn not drift (free-key paid-only class)",
    rlevel({ served = nil, err = "You exceeded your current quota, please check your plan and billing details." },
        {}) == "warn")
TestRunner:check("permission-blocked model -> warn not drift (staged rollout class)",
    rlevel({ served = nil, err = "You do not have permission to access glm-5.3" }, {}) == "warn")
TestRunner:check("model_not_found stays drift",
    rlevel({ served = nil, err = "The model `gone-1` does not exist" }, {}) == "drift")
TestRunner:check("weak evidence on default-off profile -> warn (terra class)",
    rlevel({ served = true, default_reasoning = false, weak_evidence = 12, temp_ok = false },
        { profile = { axis = "effort", default_state = "off" }, temp_after_apply = 1.0 }) == "warn")

--------------------------------------------------------------------------------
TestRunner:suite("Recheck ceiling comparison (--ceilings leg)")

local rc_base = { profile = { axis = "none" }, temp_after_apply = 0.7 }
local function withCeil(rd, clamped)
    local c = { profile = rc_base.profile, temp_after_apply = 0.7,
                resolved_default = rd, clamped = clamped }
    return c
end
TestRunner:check("stated ceiling below our default -> drift (first request 400s)",
    rlevel({ served = true, default_reasoning = false, temp_ok = true, ceiling = 8192 },
        withCeil(32768, 65536)) == "drift")
TestRunner:check("ceiling between default and clamp -> warn (pins in the gap 400)",
    rlevel({ served = true, default_reasoning = false, temp_ok = true, ceiling = 40000 },
        withCeil(32768, 65536)) == "warn")
TestRunner:check("deliberate low clamp stays silent (grok-4 known-good floor class)",
    rlevel({ served = true, default_reasoning = false, temp_ok = true, ceiling = 131072 },
        withCeil(32768, 32768)) == "ok")
TestRunner:check("no stated ceiling (silent-clamp provider) -> no ceiling verdict",
    rlevel({ served = true, default_reasoning = false, temp_ok = true },
        withCeil(32768, 8192)) == "ok")

--------------------------------------------------------------------------------
TestRunner:suite("OpenRouter marketplace cross-ref (pricing/context enrichment)")

local or_map = {
    ["x-ai/grok-4.6"] = { pricing = { prompt = "0.000002", completion = "0.000006" },
                          context_length = 500000 },
    ["anthropic/claude-opus-4.8"] = { context_length = 200000 },
    ["mistralai/ministral-3b-2512"] = { pricing = { prompt = "0.0000001", completion = "0.0000001" } },
}
local slug1 = ModelAudit.openrouterLookup(or_map, "xai", "grok-4.6")
TestRunner:check("xai id maps through the x-ai prefix", slug1 == "x-ai/grok-4.6")
local slug2 = ModelAudit.openrouterLookup(or_map, "anthropic", "claude-opus-4-8")
TestRunner:check("dash/period fold matches (claude-opus-4-8 vs .4.8)",
    slug2 == "anthropic/claude-opus-4.8")
TestRunner:check("unmapped provider -> nil",
    ModelAudit.openrouterLookup(or_map, "groq", "llama-3.3-70b-versatile") == nil)
TestRunner:check("no match -> nil",
    ModelAudit.openrouterLookup(or_map, "xai", "grok-9000") == nil)
local _slug3, meta3 = ModelAudit.openrouterLookup(or_map, "xai", "grok-4.6")
local ann = ModelAudit.openrouterAnnotation(meta3)
TestRunner:check("annotation scales per-token strings to per-million + context",
    ann == "$2.00 in / $6.00 out per M tokens - ctx 500K")
TestRunner:check("annotation with context only",
    ModelAudit.openrouterAnnotation({ context_length = 200000 }) == "ctx 200K")
TestRunner:check("annotation nil-safe on empty meta",
    ModelAudit.openrouterAnnotation({}) == nil and ModelAudit.openrouterAnnotation(nil) == nil)

--------------------------------------------------------------------------------
TestRunner:suite("Responses-wire facts in draft stanzas")

local rfacts = {
    family = "openai", provider = "xai", model = "grok-4.6",
    efforts = {}, probes = {}, reachable = true,
    tools_ok = true, tool_choice_any_ok = true, tool_choice_none_ok = true,
    stream_ok = true, responses_ok = true, responses_web_ok = true,
    responses_stream_ok = true,
}
local rcurrent = ModelAudit.currentResolution("xai", "grok-4.6")
local rtext = table.concat(ModelAudit.draftStanzas(rfacts, rcurrent), "\n")
TestRunner:check("responses_web_search cap drafted when Responses web probe passes",
    rtext:find("responses_web_search", 1, true) ~= nil)
TestRunner:check("grok-4.6 responses cap already covered (grok-4 prefix)",
    rtext:find("responses_web_search", 1, true) ~= nil
    and rtext:find("NOTE: Responses wire REJECTED", 1, true) == nil)

local rfacts_new = {}
for k, v in pairs(rfacts) do rfacts_new[k] = v end
rfacts_new.model = "newmodel-9"
local rtext_new = table.concat(ModelAudit.draftStanzas(rfacts_new,
    ModelAudit.currentResolution("xai", "newmodel-9")), "\n")
TestRunner:check("uncovered id gets NEEDS CURATION on the responses cap",
    rtext_new:find("responses_web_search", 1, true) ~= nil
    and rtext_new:find("NEEDS CURATION", 1, true) ~= nil)

local rfacts_rej = {}
for k, v in pairs(rfacts) do rfacts_rej[k] = v end
rfacts_rej.responses_ok = false
rfacts_rej.responses_web_ok = nil
rfacts_rej.responses_stream_ok = nil
local rtext_rej = table.concat(ModelAudit.draftStanzas(rfacts_rej, rcurrent), "\n")
TestRunner:check("Responses rejection drafts the cannot-route note",
    rtext_rej:find("Responses wire REJECTED", 1, true) ~= nil)

--------------------------------------------------------------------------------
TestRunner:suite("Undated lists, reviewed catalogs, never-listed ids (2026-09-28)")

TestRunner:check("one shared created value = undated (Perplexity 0, NVIDIA 1993)",
    ModelAudit.undatedList({ a = { created = 0 }, b = { created = 0 }, c = { created = 0 } }))
TestRunner:check("real release dates = dated",
    not ModelAudit.undatedList({ a = { created = 100 }, b = { created = 200 } }))
TestRunner:check("a single dated entry proves nothing",
    not ModelAudit.undatedList({ a = { created = 100 }, b = {} }))
TestRunner:check("no timestamps at all = not undated (the no-`now` rule already applies)",
    not ModelAudit.undatedList({ a = {}, b = {} }))

local saved_reviewed = ModelAudit.REVIEWED.probe_host
ModelAudit.REVIEWED.probe_host = { date = "2026-09-28", ids = { "old-model" } }
local rdiff = ModelAudit.diffLists("probe_host", { "cur" },
    { cur = {}, ["old-model"] = {}, ["brand-new"] = {} }, nil)
ModelAudit.REVIEWED.probe_host = saved_reviewed
TestRunner:check("reviewed id leaves the new bucket",
    #rdiff.reviewed == 1 and rdiff.reviewed[1] == "old-model")
TestRunner:check("unreviewed id still prints as new",
    #rdiff.new == 1 and rdiff.new[1] == "brand-new")

local udiff = ModelAudit.diffLists("perplexity", { "fast", "perplexity/sonar", "perplexity/gone" },
    { ["perplexity/sonar"] = {} }, nil,
    { unlisted = function(id) return not id:find("/", 1, true) end })
TestRunner:check("never-listed preset is not reported removed",
    #udiff.removed == 1 and udiff.removed[1] == "perplexity/gone")

local together = ModelAudit.parseTogetherList({
    { id = "org/chat-model", type = "chat" },
    { id = "org/embed-model", type = "embedding" },
    { id = "org/base-model", type = "language" },
})
TestRunner:check("Together: bare array parsed, chat entries only",
    together and together["org/chat-model"] ~= nil and together["org/embed-model"] == nil
    and together["org/base-model"] == nil)
TestRunner:check("Together: an object body is rejected",
    ModelAudit.parseTogetherList({ data = {} }) == nil)
local cohere = ModelAudit.parseCohereList({ models = { { name = "command-x" }, { id = "no-name" } } })
TestRunner:check("Cohere: models keyed by name",
    cohere and cohere["command-x"] ~= nil and cohere["no-name"] == nil)

TestRunner:check("qwen speech/realtime/vision-language ids are noise",
    ModelAudit.isNoise("qwen", "qwen3-tts-flash") ~= nil
    and ModelAudit.isNoise("qwen", "qwen3.5-omni-plus-realtime") ~= nil
    and ModelAudit.isNoise("qwen", "qwen3-vl-plus") ~= nil)
TestRunner:check("qwen chat and coder ids are not noise (coder is curated)",
    ModelAudit.isNoise("qwen", "qwen3.8-flash") == nil
    and ModelAudit.isNoise("qwen", "qwen3-coder-plus") == nil)
TestRunner:check("together LoRA and base weights are noise",
    ModelAudit.isNoise("together", "Qwen/Qwen3.5-2B-Lora") ~= nil
    and ModelAudit.isNoise("together", "Qwen/Qwen3-8B-Base") ~= nil
    and ModelAudit.isNoise("together", "zai-org/GLM-5.3") == nil)

TestRunner:check("request-id digits are never a ceiling; the stated range wins",
    ModelAudit.parseCeiling("Invalid max_tokens value, the valid range of max_tokens is [1, 393216] "
        .. "(request_id: fe922218-5da4-4ae2-a51b-1605698c5c50)", 10000000) == 393216)
TestRunner:check("a bare request id alone yields no ceiling",
    ModelAudit.parseCeiling("Bad request (request_id: 12345678-1605698)", 10000000) == nil)
TestRunner:check("a validation 400 inviting a retry is not transient",
    not ModelAudit.isTransient(400, "Thinking level MINIMAL is not supported. Please retry with other thinking levels"))
TestRunner:check("429 and 5xx stay transient",
    ModelAudit.isTransient(429, "") and ModelAudit.isTransient(503, "") and ModelAudit.isTransient(nil, ""))
TestRunner:check("openai voice model is noise", ModelAudit.isNoise("openai", "gpt-live-1") ~= nil)

--------------------------------------------------------------------------------
TestRunner:suite("recheck: key limitations and skipped temperature")

TestRunner:check("new-account lockout is a key limitation, not drift",
    rlevel({ served = nil, err = "This model models/gemini-2.5-flash is no longer available to new users." },
        {}) == "warn")
TestRunner:check("lapsed subscription is a key limitation",
    rlevel({ served = nil, err = "An active OpenCode Go subscription is required to use Go models." },
        {}) == "warn")
TestRunner:check("spent credits are a key limitation",
    rlevel({ served = nil, err = "Credit limit exceeded, please add credits" }, {}) == "warn")
TestRunner:check("a skipped temperature leg (preset) is not 'inconclusive'",
    rlevel({ served = true, temp_skipped = true }, { temp_after_apply = 0.7, caps = {} }) == "ok")

--------------------------------------------------------------------------------
TestRunner:suite("Perplexity Agent API facts")

local agent_ok = {
    output = {
        { type = "search_results", results = { { url = "https://example.org" } } },
        { type = "message", content = { { type = "output_text", text = "Argentina won [1]." } } },
    },
    usage = { output_tokens_details = { reasoning_tokens = 120 } },
}
local searched, cited = ModelAudit.agentSearchFacts(agent_ok)
TestRunner:check("search_results item + [n] marker detected", searched and cited)
local _s2, cited2 = ModelAudit.agentSearchFacts({ output = {
    { type = "message", content = { { type = "output_text", text = "Argentina [web:2]." } } } } })
TestRunner:check("[web:n] marker counts as a citation", cited2)
TestRunner:check("reasoning tokens are evidence",
    ModelAudit.agentReasoningEvidence(agent_ok) == "reasoning_tokens=120")
TestRunner:check("a reasoning output item is evidence",
    ModelAudit.agentReasoningEvidence({ output = { { type = "reasoning" } } }) ~= nil)
TestRunner:check("plain answer: no evidence",
    ModelAudit.agentReasoningEvidence({ output = {}, usage = {} }) == nil)

local pfacts = { family = "perplexity", provider = "perplexity", model = "newvendor/model-1",
    efforts = {}, probes = {}, reachable = true, searched = true, cited = true,
    isolated = { "reasoning_mandatory" }, temp_ok = false, ceiling = 65536 }
local ptext = table.concat(ModelAudit.draftStanzas(pfacts,
    ModelAudit.currentResolution("perplexity", "newvendor/model-1")), "\n")
TestRunner:check("draft names both exception lists the probe implies",
    ptext:find('reasoning_mandatory%s+%+= "newvendor/model%-1"') ~= nil
    and ptext:find('no_sampling_params%s+%+= "newvendor/model%-1"') ~= nil)
TestRunner:check("draft carries the probed ceiling", ptext:find("65536", 1, true) ~= nil)
local covered = table.concat(ModelAudit.draftStanzas(
    { family = "perplexity", provider = "perplexity", model = "openai/gpt-6-astra",
      efforts = {}, probes = {}, reachable = true, searched = true, cited = true,
      isolated = { "no_sampling_params", "reasoning_mandatory" } },
    ModelAudit.currentResolution("perplexity", "openai/gpt-6-astra")), "\n")
TestRunner:check("already-listed model reads as covered",
    covered:find("NEEDS CURATION", 1, true) == nil and covered:find("already covered", 1, true) ~= nil)
TestRunner:check("preset drafts nothing",
    table.concat(ModelAudit.draftStanzas({ family = "perplexity", provider = "perplexity",
        model = "fast", is_preset = true, efforts = {}, probes = {} },
        ModelAudit.currentResolution("perplexity", "fast")), "\n"):find("nothing to curate", 1, true) ~= nil)

--------------------------------------------------------------------------------
TestRunner:suite("Inherited off shapes and the named lowest setting (2026-09-29)")

local SONNET55_DISABLE_ERR = '"thinking.type.disabled" is not supported for this model. Use '
    .. '"thinking.type.between_tools" for the lowest thinking setting, or "thinking.type.adaptive" '
    .. 'and "output_config.effort" to control thinking behavior.'
TestRunner:check("lowest setting parsed from the refusal",
    ModelAudit.lowestThinkingType(SONNET55_DISABLE_ERR) == "between_tools")
TestRunner:check("a refusal naming no lowest setting -> nil",
    ModelAudit.lowestThinkingType('"thinking.type.disabled" is not supported for this model. Use '
        .. '"thinking.type.adaptive" and "output_config.effort" to control thinking behavior.') == nil
    and ModelAudit.lowestThinkingType(nil) == nil)

TestRunner:check("disabled refused -> Minimal flagged",
    ModelAudit.minimalRefused({ thinking = { type = "disabled" } }, { disable_ok = false }) ~= nil)
TestRunner:check("the named lowest setting accepted -> not flagged",
    ModelAudit.minimalRefused({ thinking = { type = "between_tools" } },
        { lowest_type = "between_tools", lowest_ok = true }) == nil)
TestRunner:check("OpenRouter enabled=false refused -> flagged",
    ModelAudit.minimalRefused({ openrouter_reasoning = { enabled = false } }, { disable_ok = false }) ~= nil)
TestRunner:check("a translated enabled=false (a2agent) is not judged",
    ModelAudit.minimalRefused({ a2agent_reasoning = { enabled = false } }, { disable_ok = false }) == nil)
TestRunner:check("effort none refused -> flagged",
    ModelAudit.minimalRefused({ xai_reasoning = { effort = "none" } }, { efforts = { none = false } }) ~= nil)
TestRunner:check("adaptive low accepted -> not flagged",
    ModelAudit.minimalRefused({ thinking = { type = "adaptive" }, output_config = { effort = "low" } },
        { efforts = { low = true } }) == nil)
TestRunner:check("not probed -> not flagged",
    ModelAudit.minimalRefused({ thinking = { type = "disabled" } }, {}) == nil)

-- A new id under claude-sonnet-5's profile (disable accepted there) that refuses
-- disabled and names between_tools: the sonnet-5-5 case, read right.
local lfacts = {
    family = "anthropic", provider = "anthropic", model = "claude-sonnet-5-9",
    reachable = true, default_reasoning = true, temp_ok = false,
    disable_ok = false, disable_err = SONNET55_DISABLE_ERR,
    lowest_type = "between_tools", lowest_ok = true,
    adaptive_ok = true, budget_ok = false,
    ladder = { "low", "medium", "high", "xhigh", "max" },
    efforts = { low = true, medium = true, high = true, xhigh = true, max = true },
    tools_ok = true, probes = {},
}
local ltext = table.concat(ModelAudit.draftStanzas(lfacts,
    ModelAudit.currentResolution("anthropic", "claude-sonnet-5-9")), "\n")
TestRunner:check("inherited disable named in a NOTE",
    ltext:find('NOTE: Minimal sends thinking type "disabled"', 1, true) ~= nil)
TestRunner:check("profile flagged although axis and default state match the sibling",
    (ltext:match("[^\n]*reasoning_profiles%.anthropic[^\n]*") or ""):find("NEEDS CURATION", 1, true) ~= nil)
TestRunner:check("drafted off is the named lowest setting",
    ltext:find('off_option = "between_tools"', 1, true) ~= nil
    and ltext:find("can_disable = true", 1, true) ~= nil
    and ltext:find('minimal = { state = "off" }', 1, true) ~= nil)

-- Summary
print(string.format("\n%d passed, %d failed", TestRunner.passed, TestRunner.failed))
return TestRunner.failed == 0
