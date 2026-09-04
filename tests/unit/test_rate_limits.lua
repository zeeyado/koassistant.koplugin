-- Unit tests for koassistant_rate_limits.lua (per-minute admission limits,
-- 2026-09-03, docs/tpm_admission_plan.md): header capture, pipe marker
-- encode/decode, session memo, refusal parsing, budget sizing.
-- Run: lua tests/unit/test_rate_limits.lua  (or lua tests/run_tests.lua --unit)

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

local RL = require("koassistant_rate_limits")

-- Real wordings (2026-09-03). Groq = the Reddit screenshot; OpenAI = community reports.
local GROQ = "groq/openai/gpt-oss-20b: Request too large for model `openai/gpt-oss-20b` in organization "
    .. "`org_01kx` service tier `on_demand` on tokens per minute (TPM): Limit 8000, Requested 32979, "
    .. "please reduce your message size and try again. Need more tokens? Upgrade to Dev Tier today at "
    .. "https://console.groq.com/settings/billing"
local OPENAI = "Request too large for gpt-4o in organization org-abc on tokens per min (TPM): Limit 30000, "
    .. "Requested 40000. The input or output tokens must be reduced in order to run successfully."
-- Ordinary bursts: the allowance is spent for now, and the request WOULD fit an
-- empty bucket (requested <= limit). Verbatim, from the corpus in
-- tests/unit/test_error_wordings.lua (sources there).
local GROQ_BURST = "Rate limit reached for model `gemma2-9b-it` in organization `...` service tier "
    .. "`on_demand` on tokens per minute (TPM): Limit 15000, Used 11972, Requested 4351. "
    .. "Please try again in 5.289s. Visit https://console.groq.com/docs/rate-limits for more "
    .. "information."
-- Groq's OTHER 429 shape: "Used 0" with a request larger than the whole allowance.
-- The bucket is empty and the request still does not fit, so no wait admits it:
-- by the numbers this is an admission refusal, whatever its "try again in 50s".
local GROQ_USED0 = "Rate limit reached for model `llama3-70b-8192` in organization "
    .. "`org_01hrsvc1b8ey0anvbgha0xckf2` on tokens per minute (TPM): Limit 7000, Used 0, "
    .. "Requested ~12903. Please try again in 50.597142857s."
-- Per-minute wordings that state NO numbers after the signature: Anthropic's
-- input-tokens-per-minute 429 (verbatim, github.com/cline/cline/issues/879) and the
-- line the plugin itself renders from a Gemini quota violation
-- (ModelConstraints.formatQuotaDetails). Neither provider counts max_tokens at
-- admission, and both refill with time: a burst, never a deterministic refusal.
local ANTHROPIC_ITPM = "This request would exceed your organization's rate limit of 80,000 input tokens "
    .. "per minute. For details, refer to: https://docs.anthropic.com/en/api/rate-limits; see the "
    .. "response headers for current usage. Please reduce the prompt length or the maximum tokens "
    .. "requested, or try again later."
local GEMINI_LINE = "You exceeded your current quota, please check your plan and billing details.\n\n"
    .. "Limit reached: 125000 input tokens per minute (free tier), model gemini-2.5-pro.\nYou can retry in 15s."
local OPENAI_BURST = "Rate limit reached for o4-mini in organization org-**** on tokens per min (TPM): "
    .. "Limit 200000, Used 162960, Requested 42288. Please try again in 1.574s. "
    .. "Visit https://platform.openai.com/account/rate-limits to learn more."
local GROQ_TPD = "Rate limit reached for model `llama-3.3-70b-versatile` in organization "
    .. "`org_01kjh7p9n8f1qs6nz2bz77vy6b` service tier `on_demand` on tokens per day (TPD): "
    .. "Limit 100000, Used 97050, Requested 3619. Please try again in 9m38.016s."
local OPENAI_RPM = "Rate limit reached for default-codex in organization org-{id} on requests per min. "
    .. "Limit: 20.000000 / min. Current: 24.000000 / min."
local CEREBRAS = "Tokens per minute limit exceeded - too many tokens processed"

TestRunner:suite("fromHeaders / marker round trip")

TestRunner:test("picks the OpenAI-style family, any key case", function()
    local f = RL.fromHeaders({ ["X-RateLimit-Limit-Tokens"] = "8000",
        ["x-ratelimit-remaining-tokens"] = "7900", ["content-type"] = "application/json" })
    TestRunner:assertEqual(f.limit_tokens, "8000", "limit")
    TestRunner:assertEqual(f.remaining_tokens, "7900", "remaining")
    TestRunner:assertNil(f["content-type"], "unrelated header dropped")
end)

TestRunner:test("Cerebras '-minute' spelling is read; daily buckets are not", function()
    local f = RL.fromHeaders({ ["x-ratelimit-limit-tokens-minute"] = "30000",
        ["x-ratelimit-remaining-tokens-minute"] = "29000", ["x-ratelimit-limit-tokens-day"] = "1000000" })
    TestRunner:assertEqual(f.limit_tokens, "30000", "per-minute limit")
    TestRunner:assertEqual(f.remaining_tokens, "29000", "per-minute remaining")
    TestRunner:assertNil(RL.fromHeaders({ ["x-ratelimit-limit-tokens-day"] = "1000000",
        ["x-ratelimit-limit"] = "20" }), "daily bucket and OpenRouter's generic limit ignored")
end)

TestRunner:test("nil when no relevant header (Anthropic/Gemini names are not captured)", function()
    TestRunner:assertNil(RL.fromHeaders({ ["anthropic-ratelimit-output-tokens-limit"] = "400000" }))
    TestRunner:assertNil(RL.fromHeaders(nil))
end)

TestRunner:test("encodeMarker -> decodeMarker round trip, sorted, sanitized", function()
    local line = RL.encodeMarker({ ["x-ratelimit-limit-tokens"] = "8000",
        ["x-ratelimit-reset-tokens"] = "6m0s", ["retry-after"] = "12" })
    TestRunner:assertTrue(line:sub(1, 2) == "\r\n" and line:sub(-2) == "\n\n", "pipe line shape")
    TestRunner:assertTrue(line:find(RL.PROTOCOL_MARKER, 1, true), "prefix present")
    local f = RL.decodeMarker(line)
    TestRunner:assertEqual(f.limit_tokens, "8000", "limit survives")
    TestRunner:assertEqual(f.reset_tokens, "6m0s", "reset survives")
    TestRunner:assertEqual(f.retry_after, "12", "retry-after survives")
end)

TestRunner:test("encodeMarker nil when nothing to forward", function()
    TestRunner:assertNil(RL.encodeMarker({ ["content-type"] = "text/event-stream" }))
end)

TestRunner:test("extractMarker strips the line from a non-streaming buffer (before or after body)", function()
    local body = '{"choices":[{"message":{"content":"ok"}}]}'
    local marker = RL.encodeMarker({ ["x-ratelimit-limit-tokens"] = "30000" })
    local f1, c1 = RL.extractMarker(marker .. body)
    TestRunner:assertEqual(f1.limit_tokens, "30000", "fields (marker first)")
    TestRunner:assertEqual(c1:match("^%s*(.-)%s*$"), body, "body intact (marker first)")
    local f2, c2 = RL.extractMarker(body .. marker)
    TestRunner:assertEqual(f2.limit_tokens, "30000", "fields (marker last)")
    TestRunner:assertEqual(c2:match("^%s*(.-)%s*$"), body, "body intact (marker last)")
    local f3, c3 = RL.extractMarker(body)
    TestRunner:assertNil(f3, "no marker -> nil")
    TestRunner:assertEqual(c3, body, "no marker -> text unchanged")
end)

TestRunner:suite("session memo + budget cap")

TestRunner:test("record needs a numeric limit; known/forget", function()
    RL._reset()
    TestRunner:assertEqual(RL.record("groq", "m", { remaining_tokens = "5" }), false, "no limit -> not recorded")
    TestRunner:assertEqual(RL.record("groq", "m", { limit_tokens = "8000", remaining_tokens = "7900" }), true, "recorded")
    TestRunner:assertEqual(RL.known("groq", "m").limit_tokens, 8000, "limit number")
    TestRunner:assertEqual(RL.known("groq", "m").remaining_tokens, 7900, "remaining number")
    TestRunner:assertNil(RL.known("groq", "other"), "per model")
    RL.forget("groq", "m")
    TestRunner:assertNil(RL.known("groq", "m"), "forgotten")
end)

TestRunner:test("record refuses a number that cannot be a real allowance", function()
    RL._reset()
    -- 3 and 4 are what the old unanchored refusal parser read out of `llama3`
    -- and `o4-mini`; one of them used to switch sizing off for the session.
    TestRunner:assertEqual(RL.record("p", "m", { limit_tokens = 3 }), false, "3 rejected")
    TestRunner:assertEqual(RL.record("p", "m", { limit_tokens = 4 }), false, "4 rejected")
    TestRunner:assertEqual(RL.record("p", "m", { limit_tokens = 500 }), false, "below the bound")
    TestRunner:assertEqual(RL.record("p", "m", { limit_tokens = 800030000 }), false, "above the bound")
    TestRunner:assertNil(RL.known("p", "m"), "nothing recorded")
    TestRunner:assertEqual(RL.record("p", "m", { limit_tokens = 1024 }), true, "the bound itself is fine")
end)

TestRunner:test("a repeated response header welded through the pipe is refused", function()
    RL._reset()
    -- luasocket joins duplicate headers with ", " and encodeMarker's sanitizer
    -- deletes the comma and the space, so 8000 and 30000 arrive as 800030000.
    local fields = RL.decodeMarker(RL.encodeMarker({ ["x-ratelimit-limit-tokens"] = "8000, 30000" }))
    TestRunner:assertEqual(fields.limit_tokens, "800030000", "the welded value really does arrive")
    TestRunner:assertEqual(RL.record("p", "m", fields, "header"), false, "not recorded")
    TestRunner:assertNil(RL.known("p", "m"), "sizing still off rather than wrong")
end)

TestRunner:test("a refusal never displaces what a header said; a header displaces a refusal", function()
    RL._reset()
    TestRunner:assertEqual(RL.record("p", "m", { limit_tokens = 8000 }, "header"), true, "header first")
    TestRunner:assertEqual(RL.record("p", "m", { limit_tokens = 2000 }, "refusal"), false, "refusal ignored")
    TestRunner:assertEqual(RL.known("p", "m").limit_tokens, 8000, "header kept")
    RL._reset()
    TestRunner:assertEqual(RL.record("p", "m", { limit_tokens = 2000 }, "refusal"), true, "refusal first")
    TestRunner:assertEqual(RL.record("p", "m", { limit_tokens = 8000 }, "header"), true, "header wins")
    TestRunner:assertEqual(RL.known("p", "m").limit_tokens, 8000, "header value stored")
    TestRunner:assertEqual(RL.record("p", "m", { limit_tokens = 12000 }, "probe"), true, "probe wins too")
    TestRunner:assertEqual(RL.known("p", "m").source, "probe", "source kept")
end)

TestRunner:test("budgetCap: the Reddit case (8K plan, 211-token prompt) fits ~7.5K", function()
    RL._reset()
    RL.record("groq", "openai/gpt-oss-20b", { limit_tokens = "8000" })
    local cap = RL.budgetCap("groq", "openai/gpt-oss-20b", 211 * 3)  -- 633 bytes ~ 211 tokens
    TestRunner:assertEqual(cap, 8000 - 211 - RL.MARGIN, "limit - prompt - margin")
end)

TestRunner:test("budgetCap: exact prompt tokens win over the estimate", function()
    RL._reset()
    RL.record("p", "m", { limit_tokens = "8000" })
    TestRunner:assertEqual(RL.budgetCap("p", "m", 999999, 211), 8000 - 211 - RL.MARGIN, "exact used")
end)

TestRunner:test("budgetCap: nil when plan unknown or prompt leaves no room", function()
    RL._reset()
    TestRunner:assertNil(RL.budgetCap("p", "m", 100), "unknown plan")
    RL.record("p", "m", { limit_tokens = "8000" })
    TestRunner:assertNil(RL.budgetCap("p", "m", 8000 * 3), "prompt alone exceeds the plan")
    TestRunner:assertNil(RL.budgetCap("p", "m", (8000 - RL.MARGIN - 100) * 3), "room under FLOOR")
end)

TestRunner:test("applyCap only shrinks", function()
    TestRunner:assertEqual(select(1, RL.applyCap(32768, 7533)), 7533, "shrinks default")
    TestRunner:assertEqual(select(1, RL.applyCap(65536, 7533)), 7533, "shrinks a pin")
    TestRunner:assertEqual(select(1, RL.applyCap(4096, 7533)), 4096, "keeps a smaller pin")
    TestRunner:assertEqual(select(1, RL.applyCap(nil, 7533)), 7533, "nil value -> cap")
    TestRunner:assertEqual(select(1, RL.applyCap(4096, nil)), 4096, "no cap -> unchanged")
    TestRunner:assertEqual(select(2, RL.applyCap(4096, 7533)), false, "changed flag false")
    TestRunner:assertEqual(select(2, RL.applyCap(32768, 7533)), true, "changed flag true")
end)

TestRunner:test("big plans never bite: 500K TPM leaves the default alone", function()
    RL._reset()
    RL.record("openai", "gpt-5-mini", { limit_tokens = "500000" })
    local cap = RL.budgetCap("openai", "gpt-5-mini", 4000)
    TestRunner:assertEqual(select(1, RL.applyCap(32768, cap)), 32768, "default untouched")
end)

TestRunner:suite("refusal parsing + retry budget")

TestRunner:test("Groq wording (the screenshot)", function()
    local r = RL.parseRefusal(GROQ)
    TestRunner:assertEqual(r.limit, 8000, "limit")
    TestRunner:assertEqual(r.requested, 32979, "requested")
end)

TestRunner:test("OpenAI wording", function()
    local r = RL.parseRefusal(OPENAI)
    TestRunner:assertEqual(r.limit, 30000, "limit")
    TestRunner:assertEqual(r.requested, 40000, "requested")
end)

TestRunner:test("burst wordings: the numbers come from after the signature, not the model name", function()
    local g = RL.parseRefusal(GROQ_BURST)
    TestRunner:assertEqual(g.limit, 15000, "groq limit (not the 2 of gemma2)")
    TestRunner:assertEqual(g.requested, 4351, "groq requested")
    TestRunner:assertEqual(g.used, 11972, "groq used")
    local z = RL.parseRefusal(GROQ_USED0)
    TestRunner:assertEqual(z.limit, 7000, "groq limit (not the 3 of llama3)")
    TestRunner:assertEqual(z.requested, 12903, "groq requested (the ~ is skipped)")
    TestRunner:assertEqual(z.used, 0, "groq used (zero is a number)")
    local o = RL.parseRefusal(OPENAI_BURST)
    TestRunner:assertEqual(o.limit, 200000, "openai limit (not the 4 of o4-mini)")
    TestRunner:assertEqual(o.requested, 42288, "openai requested")
    TestRunner:assertEqual(o.used, 162960, "openai used")
end)

TestRunner:test("admission wordings carry no used count", function()
    TestRunner:assertNil(RL.parseRefusal(GROQ).used, "groq 413")
    TestRunner:assertNil(RL.parseRefusal(OPENAI).used, "openai 429 admission")
end)

TestRunner:test("refusalKind: burst vs admission vs not-a-per-minute-refusal", function()
    TestRunner:assertEqual(RL.refusalKind(GROQ_BURST), "burst", "groq burst (request fits an empty bucket)")
    TestRunner:assertEqual(RL.refusalKind(OPENAI_BURST), "burst", "openai burst")
    TestRunner:assertEqual(RL.refusalKind(GROQ), "admission", "groq 413")
    TestRunner:assertEqual(RL.refusalKind(OPENAI), "admission", "openai admission")
    TestRunner:assertEqual(RL.refusalKind(GROQ_USED0), "admission",
        "Used 0 with requested > limit can never fit: admission, by the numbers")
    -- The 2026-09-04 re-audit: "no Used count" used to mean "admission", which
    -- called every Anthropic and Gemini per-minute 429 a deterministic refusal.
    TestRunner:assertEqual(RL.refusalKind(CEREBRAS), "burst", "a numberless per-minute wording is a burst")
    TestRunner:assertEqual(RL.refusalKind(ANTHROPIC_ITPM), "burst", "Anthropic's input-tokens-per-minute 429 is a burst")
    TestRunner:assertEqual(RL.refusalKind(GEMINI_LINE), "burst", "the plugin's own Gemini quota line is a burst")
    TestRunner:assertEqual(RL.refusalKind("on tokens per min (TPM): Limit 30000, Requested 20000."), "burst",
        "a request that fits an empty bucket is a burst even without a Used count")
    TestRunner:assertNil(RL.refusalKind(GROQ_TPD), "a daily bucket is not per-minute")
    TestRunner:assertNil(RL.refusalKind(OPENAI_RPM), "requests per minute, not tokens")
    TestRunner:assertNil(RL.refusalKind("max_tokens: 65536 > 32768, which is the maximum allowed"))
    TestRunner:assertNil(RL.refusalKind(""))
    TestRunner:assertNil(RL.refusalKind(nil))
end)

TestRunner:test("thousands separators and TPM-only signature tolerated", function()
    local r = RL.parseRefusal("Rejected (TPM): limit 12,000 requested 16,595")
    TestRunner:assertEqual(r.limit, 12000, "limit")
    TestRunner:assertEqual(r.requested, 16595, "requested")
end)

TestRunner:test("not a refusal: plain 429s, output caps, context overflows", function()
    TestRunner:assertNil(RL.parseRefusal("HTTP 429: Rate limit reached for requests, please try again in 2s"))
    TestRunner:assertNil(RL.parseRefusal("max_tokens: 65536 > 32768, which is the maximum allowed"))
    TestRunner:assertNil(RL.parseRefusal("This model's maximum context length is 8192 tokens. However, you requested 9000 tokens (900 in the messages, 8100 in the completion)"))
    TestRunner:assertNil(RL.parseRefusal(""))
    TestRunner:assertNil(RL.parseRefusal(nil))
end)

TestRunner:test("retryBudget: exact prompt from (requested - sent)", function()
    local r = RL.parseRefusal(GROQ)
    TestRunner:assertEqual(RL.retryBudget(r, 32768, 0), 8000 - 211 - RL.MARGIN, "exact")
    TestRunner:assertEqual(RL.promptTokensFromRefusal(r, 32768), 211, "prompt tokens")
end)

TestRunner:test("retryBudget: estimate when the sent budget is unknown", function()
    local r = RL.parseRefusal(GROQ)
    TestRunner:assertEqual(RL.retryBudget(r, nil, 300 * 3), 8000 - 300 - RL.MARGIN, "estimate")
end)

TestRunner:test("retryBudget: nil when the prompt alone exceeds the plan (real book-text case)", function()
    local r = RL.parseRefusal("on tokens per minute (TPM): Limit 8000, Requested 150000")
    TestRunner:assertNil(RL.retryBudget(r, 32768, 0), "150000 - 32768 = 117K prompt > 8K plan")
    TestRunner:assertNil(RL.promptTokensFromRefusal(r, 200000), "sent >= requested -> unknown")
end)

TestRunner:test("record from a refusal feeds budgetCap for the rest of the session", function()
    RL._reset()
    local r = RL.parseRefusal(GROQ)
    RL.record("groq", "openai/gpt-oss-20b", { limit_tokens = r.limit }, "refusal")
    TestRunner:assertEqual(RL.known("groq", "openai/gpt-oss-20b").source, "refusal", "source kept")
    TestRunner:assertEqual(RL.budgetCap("groq", "openai/gpt-oss-20b", 0, 211), 8000 - 211 - RL.MARGIN, "cap")
end)

TestRunner:suite("promptExceedsPlan (the pre-send question)")

TestRunner:test("nil when the plan is unknown, nil when the cap succeeds", function()
    RL._reset()
    TestRunner:assertNil(RL.promptExceedsPlan("p", "m", 100000), "no memo -> no opinion")
    RL.record("p", "m", { limit_tokens = 8000 })
    TestRunner:assertNil(RL.promptExceedsPlan("p", "m", 633), "room for an answer")
end)

TestRunner:test("returns the plan, the estimate and where the plan came from", function()
    RL._reset()
    RL.record("p", "m", { limit_tokens = 8000 }, "header")
    local limit, estimate, source = RL.promptExceedsPlan("p", "m", 8000 * 3)
    TestRunner:assertEqual(limit, 8000, "the plan's allowance")
    TestRunner:assertEqual(estimate, RL.estimateTokens(8000 * 3), "the prompt estimate")
    TestRunner:assertEqual(source, "header", "source (the wording branches on it)")
end)

TestRunner:test("the boundary is budgetCap's own, to the character", function()
    RL._reset()
    RL.record("p", "m", { limit_tokens = 8000 })
    local fits = (8000 - RL.FLOOR - RL.MARGIN) * RL.BYTES_PER_TOKEN
    TestRunner:assertEqual(RL.budgetCap("p", "m", fits), RL.FLOOR, "last prompt that leaves FLOOR")
    TestRunner:assertNil(RL.promptExceedsPlan("p", "m", fits), "so nothing to say")
    TestRunner:assertNil(RL.budgetCap("p", "m", fits + 1), "one character more: no cap")
    TestRunner:assertEqual(select(1, RL.promptExceedsPlan("p", "m", fits + 1)), 8000, "and it says so")
end)

TestRunner:suite("verifier cases: numbers follow their word directly; a Used count means spent")

TestRunner:test("a model id AFTER the signature cannot supply the number", function()
    local r = RL.parseRefusal("Rate limit reached on tokens per minute (TPM) for model `limit-3b`: Limit 8000, Requested 32979.")
    TestRunner:assertEqual(r and r.limit, 8000, "limit read from 'Limit 8000', not from `limit-3b`")
    local r2 = RL.parseRefusal("on tokens per min (TPM) for model `used-7b-v2`: Limit 30000, Requested 40000.")
    TestRunner:assertNil(r2 and r2.used, "`used-7b-v2` is not a used count")
    TestRunner:assertEqual(RL.refusalKind("on tokens per min (TPM) for model `used-7b-v2`: Limit 30000, Requested 40000."),
        "admission", "so the refusal stays an admission one")
end)

TestRunner:test("a number further down the sentence is not the used count", function()
    TestRunner:assertNil(RL.parseRefusal("on tokens per minute (TPM): the allowance is used up. Please try again in 20s."),
        "'used up ... 20s' carries no numbers")
    TestRunner:assertEqual(RL.refusalKind("on tokens per minute (TPM): the allowance is used up. Please try again in 20s."),
        "burst", "and a numberless per-minute wording is a burst")
    local r = RL.parseRefusal("... on tokens per minute (TPM): Limit 7000, Used 0, Requested ~12903.")
    TestRunner:assertEqual(r and r.used, 0, "'Used 0' is a used count (zero is a number)")
    TestRunner:assertEqual(RL.refusalKind("... on tokens per minute (TPM): Limit 7000, Used 0, Requested ~12903."),
        "admission", "but requested > limit decides: the request can never fit")
end)

TestRunner:test("hasPerMinuteSignature: the one definition of the three spellings", function()
    TestRunner:assertTrue(RL.hasPerMinuteSignature("on tokens per min (TPM): Limit 1"), "tokens per min")
    TestRunner:assertTrue(RL.hasPerMinuteSignature("Rejected (TPM): limit 12,000"), "(TPM)")
    TestRunner:assertTrue(RL.hasPerMinuteSignature("tokens-per-minute cap hit"), "tokens-per-minute")
    TestRunner:assertTrue(RL.hasPerMinuteSignature(ANTHROPIC_ITPM), "input tokens per minute")
    TestRunner:assertTrue(not RL.hasPerMinuteSignature(GROQ_TPD), "a daily bucket has none")
    TestRunner:assertTrue(not RL.hasPerMinuteSignature(OPENAI_RPM), "requests per minute has none")
    TestRunner:assertTrue(not RL.hasPerMinuteSignature(nil) and not RL.hasPerMinuteSignature(""), "nil/empty")
end)

TestRunner:test("findMarker: a marker line starts a line; the same bytes mid-line are content", function()
    local M = RL.PROTOCOL_MARKER
    TestRunner:assertEqual(RL.findMarker(M .. "limit_tokens=8000\n"), 1, "at the very start")
    TestRunner:assertEqual(RL.findMarker("body\r\n" .. M .. "limit_tokens=8000\n\n"), 7, "after a newline")
    TestRunner:assertNil(RL.findMarker("the model wrote " .. M .. " in prose"), "mid-line is content")
    local both = "quoting " .. M .. "x\n" .. M .. "limit_tokens=8000\n"
    TestRunner:assertEqual(RL.findMarker(both), #("quoting " .. M .. "x\n") + 1, "the anchored one wins")
    local fields, cleaned = RL.extractMarker("say " .. M .. " here\n" .. M .. "limit_tokens=8000\nrest")
    TestRunner:assertEqual(fields and fields.limit_tokens, "8000", "extractMarker reads the anchored line")
    TestRunner:assertEqual(cleaned, "say " .. M .. " here\nrest", "and leaves the quoted prefix alone")
    TestRunner:assertNil(RL.findMarker(nil), "nil text")
end)

TestRunner:test("hasUsedCount sees any bucket, per minute or per day", function()
    TestRunner:assertTrue(RL.hasUsedCount("on tokens per day (TPD): Limit 100000, Used 97050, Requested 3619"), "daily")
    TestRunner:assertTrue(RL.hasUsedCount(GROQ_BURST or "Limit 7000, Used 0, Requested ~12903"), "per minute")
    TestRunner:assertTrue(not RL.hasUsedCount(GROQ), "the admission wording has none")
    TestRunner:assertTrue(not RL.hasUsedCount("caused by unused delimiters"), "words containing 'used' do not count")
end)

TestRunner:test("memo priority: only a header or probe displaces a header or probe", function()
    RL._reset()
    TestRunner:assertTrue(RL.record("p", "m", { limit_tokens = "8000" }, "header"), "header recorded")
    TestRunner:assertTrue(not RL.record("p", "m", { limit_tokens = "2000" }, "guess"), "an unknown source cannot displace it")
    TestRunner:assertTrue(not RL.record("p", "m", { limit_tokens = "131072" }, "context"), "a window cannot displace an allowance")
    TestRunner:assertEqual(RL.known("p", "m").limit_tokens, 8000, "the header value stands")
    TestRunner:assertTrue(RL.record("p", "m", { limit_tokens = "12000" }, "probe"), "a probe may replace a header")
    RL._reset()
    TestRunner:assertTrue(RL.record("p", "m", { limit_tokens = "8000" }, "refusal"), "refusal recorded")
    TestRunner:assertTrue(RL.record("p", "m", { limit_tokens = "4096" }, "context"), "a window may replace a refusal-learned value (Q3 open)")
    RL._reset()
end)

TestRunner:test("remaining_tokens is bounded like the limit", function()
    RL._reset()
    RL.record("p", "m", { limit_tokens = "8000", remaining_tokens = "800030000" }, "header")
    TestRunner:assertNil(RL.known("p", "m").remaining_tokens, "a welded remaining count is dropped")
    RL.record("p", "m", { limit_tokens = "8000", remaining_tokens = "0" }, "header")
    TestRunner:assertEqual(RL.known("p", "m").remaining_tokens, 0, "zero remaining is a real value")
    RL._reset()
end)

--------------------------------------------------------------------------------
-- The provider's own wait (2026-09-05, borrowed from assistant.koplugin's
-- retry loop): durations as providers write them, the phrase hunt, the
-- retry-after header through the marker into the wait memo, and OpenRouter's
-- "can only afford N".
--------------------------------------------------------------------------------
TestRunner:suite("retry delay")

local function near(a, b) return type(a) == "number" and math.abs(a - b) < 1e-6 end

TestRunner:test("parseDuration reads Go, protobuf and word durations; stops at prose", function()
    TestRunner:assertTrue(near(RL.parseDuration("9m38.016s"), 578.016), "Go m+s")
    TestRunner:assertTrue(near(RL.parseDuration("5.289s. Visit"), 5.289), "trailing prose ignored")
    TestRunner:assertEqual(RL.parseDuration("1m0s"), 60, "Go 1m0s")
    TestRunner:assertTrue(near(RL.parseDuration("500ms"), 0.5), "milliseconds")
    TestRunner:assertTrue(near(RL.parseDuration("15.002899939s"), 15.002899939), "protobuf seconds")
    TestRunner:assertEqual(RL.parseDuration("1h2m3s"), 3723, "hours")
    TestRunner:assertEqual(RL.parseDuration("2 minutes"), 120, "words: minutes")
    TestRunner:assertEqual(RL.parseDuration("30 seconds"), 30, "words: seconds")
    TestRunner:assertEqual(RL.parseDuration("20"), 20, "a bare number is seconds")
    TestRunner:assertNil(RL.parseDuration("20 tokens"), "a count with another unit is not a wait")
    TestRunner:assertNil(RL.parseDuration("a minute"), "no number, no wait")
    TestRunner:assertNil(RL.parseDuration("0s"), "zero is no wait")
    TestRunner:assertNil(RL.parseDuration(nil), "nil")
end)

TestRunner:test("retryAfterSeconds hunts the providers' phrases and never the plugin's own tips", function()
    TestRunner:assertTrue(near(RL.retryAfterSeconds("Limit 7000, Used 0, Requested ~12903. Please try again in 50.597142857s."),
        50.597142857), "Groq: try again in")
    TestRunner:assertTrue(near(RL.retryAfterSeconds("Limit 200000, Used 162960, Requested 42288. Please try again in 1.574s. Visit"),
        1.574), "OpenAI: try again in")
    TestRunner:assertTrue(near(RL.retryAfterSeconds("on tokens per day (TPD): Limit 100000, Used 97050, Requested 3619. Please try again in 9m38.016s."),
        578.016), "Groq daily: Go duration")
    -- Gemini states it twice: its own sentence, then the plugin's rendering of
    -- the same RetryInfo. The earliest in the text wins.
    TestRunner:assertTrue(near(RL.retryAfterSeconds("Please retry in 15.002899939s.\n\nLimit reached: 125000 input tokens per minute.\nYou can retry in 15s."),
        15.002899939), "Gemini: the provider's own number first")
    TestRunner:assertEqual(RL.retryAfterSeconds('{"@type":"type.googleapis.com/google.rpc.RetryInfo","retryDelay":"15s"}'), 15, "raw RetryInfo")
    TestRunner:assertNil(RL.retryAfterSeconds("Please reduce the prompt length or the maximum tokens requested, or try again later."),
        "Anthropic names no delay in the text")
    TestRunner:assertNil(RL.retryAfterSeconds("Options: wait and try again, pick a different model, or switch provider. "
        .. "The provider asks for a wait of about 51 seconds."), "the plugin's own tip is never read back as a delay")
    TestRunner:assertNil(RL.retryAfterSeconds("Pace your requests and follow the Retry-After header when it is present"),
        "the header's NAME in prose is not a delay")
    TestRunner:assertNil(RL.retryAfterSeconds(""), "empty")
end)

TestRunner:test("retryAfter: the header wait rides the marker into a per-model deadline", function()
    RL._reset()
    local real_now = RL._now
    RL._now = function() return 1000 end
    -- Anthropic's refusal carries only retry-after (no x-ratelimit-limit-tokens):
    -- record keeps the wait even though it records no allowance.
    local fields = RL.decodeMarker(RL.encodeMarker({ ["Retry-After"] = "20" }))
    TestRunner:assertEqual(fields and fields.retry_after, "20", "header forwarded through the marker")
    TestRunner:assertTrue(not RL.record("anthropic", "claude-sonnet-5", fields, "header"), "no allowance recorded")
    TestRunner:assertEqual(RL.known("anthropic", "claude-sonnet-5"), nil, "memo untouched")
    local secs, src = RL.retryAfter("no numbers in this wording", "anthropic", "claude-sonnet-5")
    TestRunner:assertEqual(secs, 20, "20 s to wait")
    TestRunner:assertEqual(src, "header", "from the header")
    RL._now = function() return 1015 end
    TestRunner:assertEqual(RL.retryAfter("", "anthropic", "claude-sonnet-5"), 5, "counts down")
    RL._now = function() return 1021 end
    TestRunner:assertNil(RL.retryAfter("", "anthropic", "claude-sonnet-5"), "expired: nothing to wait for")
    TestRunner:assertNil(RL.retryAfter("", "anthropic", "claude-opus-5"), "another model has no wait")
    -- The ms spellings
    RL.record("openai", "m", { retry_after_ms = "1500", limit_tokens = "30000" }, "header")
    TestRunner:assertTrue(near(RL.retryAfter("", "openai", "m"), 1.5), "retry-after-ms in seconds")
    TestRunner:assertEqual(RL.known("openai", "m").limit_tokens, 30000, "the allowance beside it still recorded")
    -- The wording's own number beats a header deadline (exact for THIS refusal)
    TestRunner:assertTrue(near(RL.retryAfter("Please try again in 5.289s.", "openai", "m"), 5.289), "text first")
    -- An HTTP-date arrives mangled by the marker charset and is not a number
    local dated = RL.decodeMarker(RL.encodeMarker({ ["retry-after"] = "Wed, 21 Oct 2015 07:28:00 GMT" }))
    RL.record("p", "d", dated, "header")
    TestRunner:assertNil(RL.retryAfter("", "p", "d"), "an HTTP-date is ignored")
    -- Nonsense bounds
    RL.record("p", "z", { retry_after = "0" }, "header")
    TestRunner:assertNil(RL.retryAfter("", "p", "z"), "zero is no wait")
    RL.record("p", "y", { retry_after = tostring(RL.MAX_WAIT_S + 1) }, "header")
    TestRunner:assertNil(RL.retryAfter("", "p", "y"), "longer than a day is not a wait")
    RL._now = real_now
    RL._reset()
    TestRunner:assertNil(RL.retryAfter("", "openai", "m"), "_reset clears the waits too")
end)

TestRunner:test("parseAffordable reads OpenRouter's 'can only afford N'", function()
    TestRunner:assertEqual(RL.parseAffordable("You requested up to 32000 tokens, but can only afford 0. To increase, visit"), 0, "zero")
    TestRunner:assertEqual(RL.parseAffordable("but can only afford 1,000."), 1000, "thousands separator")
    TestRunner:assertNil(RL.parseAffordable("Limit 7000, Requested 12903"), "not there")
    TestRunner:assertNil(RL.parseAffordable(nil), "nil")
end)

TestRunner:test("withErrorCode appends a string code once, never a number or prose", function()
    TestRunner:assertEqual(RL.withErrorCode("You exceeded your current quota", { type = "insufficient_quota", code = "insufficient_quota" }),
        "You exceeded your current quota (insufficient_quota)", "code")
    TestRunner:assertEqual(RL.withErrorCode("Insufficient credits", { code = 402 }), "Insufficient credits", "numeric code skipped")
    TestRunner:assertEqual(RL.withErrorCode("You exceeded", { code = 429, status = "RESOURCE_EXHAUSTED" }),
        "You exceeded (RESOURCE_EXHAUSTED)", "status when no string code or type")
    TestRunner:assertEqual(RL.withErrorCode("rate_limit_exceeded: slow down", { code = "rate_limit_exceeded" }),
        "rate_limit_exceeded: slow down", "already in the sentence")
    TestRunner:assertEqual(RL.withErrorCode("msg", { type = "not a code at all" }), "msg", "prose is not a code")
    TestRunner:assertEqual(RL.withErrorCode("msg", nil), "msg", "no error object")
    TestRunner:assertEqual(RL.withErrorCode("", { code = "x" }), "", "empty message untouched")
end)

print(string.format("\n  test_rate_limits: %d passed, %d failed", TestRunner.passed, TestRunner.failed))
return TestRunner.failed == 0
