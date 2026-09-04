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
-- Ordinary bursts: the allowance is already spent, so the wording carries "Used".
-- Verbatim, from the corpus in tests/unit/test_error_wordings.lua (sources there).
local GROQ_BURST = "Rate limit reached for model `llama3-70b-8192` in organization "
    .. "`org_01hrsvc1b8ey0anvbgha0xckf2` on tokens per minute (TPM): Limit 7000, Used 0, "
    .. "Requested ~12903. Please try again in 50.597142857s."
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
    TestRunner:assertEqual(g.limit, 7000, "groq limit (not the 3 of llama3)")
    TestRunner:assertEqual(g.requested, 12903, "groq requested (the ~ is skipped)")
    TestRunner:assertEqual(g.used, 0, "groq used")
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
    TestRunner:assertEqual(RL.refusalKind(GROQ_BURST), "burst", "groq burst (Used present)")
    TestRunner:assertEqual(RL.refusalKind(OPENAI_BURST), "burst", "openai burst")
    TestRunner:assertEqual(RL.refusalKind(GROQ), "admission", "groq 413")
    TestRunner:assertEqual(RL.refusalKind(OPENAI), "admission", "openai admission")
    TestRunner:assertEqual(RL.refusalKind(CEREBRAS), "admission", "numberless admission still classifies")
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
    TestRunner:assertEqual(RL.refusalKind("on tokens per minute (TPM): the allowance is used up. Please try again in 20s."),
        "admission", "'used up ... 20s' carries no used count")
    TestRunner:assertEqual(RL.refusalKind("... on tokens per minute (TPM): Limit 7000, Used 0, Requested ~12903."),
        "burst", "'Used 0' is a used count (zero is a number)")
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

print(string.format("\n  test_rate_limits: %d passed, %d failed", TestRunner.passed, TestRunner.failed))
return TestRunner.failed == 0
