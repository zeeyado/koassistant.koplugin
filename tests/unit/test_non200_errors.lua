-- Unit tests for non-200 / API error handling
-- Covers:
--   * StreamHandler.extractApiError  — clean message extraction from raw/partial error bodies
--   * ModelConstraints.maybeAppendGemini3GroundingHint — Gemini-3 grounding 429 tip gating
-- No API calls - tests with mock data.

-- Setup paths (detect script location)
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

-- Simple test framework
local TestRunner = {
    passed = 0,
    failed = 0,
    current_suite = "",
}

function TestRunner:suite(name)
    self.current_suite = name
    print(string.format("\n  [%s]", name))
end

function TestRunner:test(name, fn)
    local ok, err = pcall(fn)
    if ok then
        self.passed = self.passed + 1
        print(string.format("    ✓ %s", name))
    else
        self.failed = self.failed + 1
        print(string.format("    ✗ %s", name))
        print(string.format("      Error: %s", tostring(err)))
    end
end

function TestRunner:assertEqual(actual, expected, msg)
    if actual ~= expected then
        error(string.format("%s: expected %q, got %q", msg or "Assertion failed", tostring(expected), tostring(actual)))
    end
end

function TestRunner:assertTrue(value, msg)
    if not value then
        error(string.format("%s: expected true", msg or "Assertion failed"))
    end
end

function TestRunner:assertNil(value, msg)
    if value ~= nil then
        error(string.format("%s: expected nil, got %q", msg or "Assertion failed", tostring(value)))
    end
end

function TestRunner:assertContains(str, needle, msg)
    if not str or not str:find(needle, 1, true) then
        error(string.format("%s: expected string to contain %q, got %q", msg or "Assertion failed", needle, tostring(str)))
    end
end

function TestRunner:summary()
    print("")
    print(string.rep("-", 50))
    local total = self.passed + self.failed
    if self.failed == 0 then
        print(string.format("  All %d tests passed!", total))
    else
        print(string.format("  %d passed, %d failed (of %d total)", self.passed, self.failed, total))
    end
    return self.failed == 0
end

print("")
print(string.rep("=", 50))
print("  Unit Tests: Non-200 / API error handling")
print(string.rep("=", 50))

-- Load modules under test
local StreamHandler = require("stream_handler")
local ModelConstraints = require("model_constraints")

--------------------------------------------------------------------------------
-- Test: StreamHandler.extractApiError
--------------------------------------------------------------------------------

TestRunner:suite("extractApiError: clean message from raw error bodies")

TestRunner:test("object form {\"error\":{\"message\":..}}", function()
    local body = '{"error":{"code":429,"message":"You exceeded your current quota.","status":"RESOURCE_EXHAUSTED"}}'
    TestRunner:assertEqual(StreamHandler.extractApiError(body),
        "You exceeded your current quota.", "should extract error.message")
end)

TestRunner:test("array form [{\"error\":{..}}]", function()
    local body = '[{"error":{"code":400,"message":"Bad request body","status":"INVALID_ARGUMENT"}}]'
    TestRunner:assertEqual(StreamHandler.extractApiError(body),
        "Bad request body", "should extract from array[1].error.message")
end)

TestRunner:test("code fallback when no message", function()
    local body = '{"error":{"code":503,"status":"UNAVAILABLE"}}'
    TestRunner:assertEqual(StreamHandler.extractApiError(body),
        "API error 503", "should fall back to error.code before status")
end)

TestRunner:test("status fallback when no message and no code", function()
    local body = '{"error":{"status":"UNAVAILABLE"}}'
    TestRunner:assertEqual(StreamHandler.extractApiError(body),
        "UNAVAILABLE", "should fall back to error.status when message and code absent")
end)

TestRunner:test("regex fallback for truncated/partial JSON body", function()
    -- Decode fails (unterminated), but the "message" pattern still matches.
    local body = '{"error": {"code": 429, "message": "Resource has been exhausted", '
    TestRunner:assertEqual(StreamHandler.extractApiError(body),
        "Resource has been exhausted", "should regex-extract message from partial body")
end)

TestRunner:test("nil/empty body returns nil", function()
    TestRunner:assertNil(StreamHandler.extractApiError(nil), "nil body")
    TestRunner:assertNil(StreamHandler.extractApiError(""), "empty body")
end)

TestRunner:test("body without an error returns nil", function()
    TestRunner:assertNil(StreamHandler.extractApiError('{"candidates":[{"content":"ok"}]}'),
        "non-error body should return nil")
end)

--------------------------------------------------------------------------------
-- Test: ModelConstraints.maybeAppendGemini3GroundingHint
--------------------------------------------------------------------------------

TestRunner:suite("maybeAppendGemini3GroundingHint: gating")

local TIP_NEEDLE = "Google quota limit"

local function ws_on() return { features = { enable_web_search = true } } end
local function tools_on()
    return { enable_web_search = false, features = {},
        tools = { specs = { { name = "search_book" } }, mode = "ANY" } }
end

TestRunner:test("appends tip: gemini-3.5-flash + web search + 429", function()
    local out = ModelConstraints.maybeAppendGemini3GroundingHint(
        "HTTP 429: quota exceeded", "gemini", "gemini-3.5-flash", ws_on())
    TestRunner:assertContains(out, TIP_NEEDLE, "tip should be appended")
    TestRunner:assertContains(out, "HTTP 429: quota exceeded", "original message preserved")
end)

TestRunner:test("appends tip on RESOURCE_EXHAUSTED wording", function()
    local out = ModelConstraints.maybeAppendGemini3GroundingHint(
        "Resource has been exhausted (RESOURCE_EXHAUSTED).", "gemini", "gemini-3.1-pro-preview", ws_on())
    TestRunner:assertContains(out, TIP_NEEDLE, "tip should be appended for RESOURCE_EXHAUSTED")
end)

TestRunner:test("respects per-action web_search override (true)", function()
    local cfg = { enable_web_search = true, features = { enable_web_search = false } }
    local out = ModelConstraints.maybeAppendGemini3GroundingHint(
        "429 quota", "gemini", "gemini-3.5-flash", cfg)
    TestRunner:assertContains(out, TIP_NEEDLE, "per-action true should enable tip")
end)

TestRunner:test("NO tip when web search off (per-action false overrides global true)", function()
    local cfg = { enable_web_search = false, features = { enable_web_search = true } }
    local out = ModelConstraints.maybeAppendGemini3GroundingHint(
        "429 quota", "gemini", "gemini-3.5-flash", cfg)
    TestRunner:assertEqual(out, "429 quota", "per-action false should suppress tip")
end)

TestRunner:test("appends tip: book tools carried, web off (2026-08-14 device round)", function()
    local out = ModelConstraints.maybeAppendGemini3GroundingHint(
        "HTTP 429: quota exceeded", "gemini", "gemini-3.6-flash", tools_on())
    TestRunner:assertContains(out, TIP_NEEDLE,
        "function-calling requests hit the same free-tier gate as grounding")
end)

TestRunner:test("NO tip on empty tools specs with web off", function()
    local cfg = { enable_web_search = false, features = {},
        tools = { specs = {}, mode = "ANY" } }
    local out = ModelConstraints.maybeAppendGemini3GroundingHint(
        "429 quota", "gemini", "gemini-3.6-flash", cfg)
    TestRunner:assertEqual(out, "429 quota", "no declarations means a plain request")
end)

TestRunner:test("NO tip for gemini-2.5-flash", function()
    local out = ModelConstraints.maybeAppendGemini3GroundingHint(
        "HTTP 429: quota exceeded", "gemini", "gemini-2.5-flash", ws_on())
    TestRunner:assertEqual(out, "HTTP 429: quota exceeded", "2.5 model should not get the Gemini-3 tip")
end)

TestRunner:test("NO tip for non-gemini provider", function()
    local out = ModelConstraints.maybeAppendGemini3GroundingHint(
        "HTTP 429: quota", "openai", "gpt-5.5", ws_on())
    TestRunner:assertEqual(out, "HTTP 429: quota", "non-gemini should be unchanged")
end)

TestRunner:test("NO tip for non-429 error", function()
    local out = ModelConstraints.maybeAppendGemini3GroundingHint(
        "HTTP 401: API key not valid", "gemini", "gemini-3.5-flash", ws_on())
    TestRunner:assertEqual(out, "HTTP 401: API key not valid", "auth error should not get grounding tip")
end)

TestRunner:test("empty/nil message returned unchanged", function()
    TestRunner:assertEqual(
        ModelConstraints.maybeAppendGemini3GroundingHint("", "gemini", "gemini-3.5-flash", ws_on()),
        "", "empty message unchanged")
    TestRunner:assertNil(
        ModelConstraints.maybeAppendGemini3GroundingHint(nil, "gemini", "gemini-3.5-flash", ws_on()),
        "nil message unchanged")
end)

TestRunner:test("nil config (no web-search info) -> no tip", function()
    local out = ModelConstraints.maybeAppendGemini3GroundingHint(
        "HTTP 429: quota", "gemini", "gemini-3.5-flash", nil)
    TestRunner:assertEqual(out, "HTTP 429: quota", "nil config means web search not known on -> no tip")
end)

--------------------------------------------------------------------------------
-- Test: ModelConstraints.formatQuotaDetails
--------------------------------------------------------------------------------

TestRunner:suite("formatQuotaDetails: google.rpc quota facts")

local json = require("json")

-- A real Gemini 429 body shape: QuotaFailure violation + Help links + RetryInfo.
local function quotaBody(quota_id, quota_value, model, retry)
    local details = {
        {
            ["@type"] = "type.googleapis.com/google.rpc.QuotaFailure",
            violations = { {
                quotaMetric = "generativelanguage.googleapis.com/generate_content_free_tier_requests",
                quotaId = quota_id,
                quotaDimensions = { model = model, location = "global" },
                quotaValue = quota_value,
            } },
        },
        { ["@type"] = "type.googleapis.com/google.rpc.Help", links = { { description = "Learn more" } } },
    }
    if retry then
        table.insert(details, { ["@type"] = "type.googleapis.com/google.rpc.RetryInfo", retryDelay = retry })
    end
    return {
        error = {
            code = 429,
            message = "You exceeded your current quota, please check your plan and billing details.",
            status = "RESOURCE_EXHAUSTED",
            details = details,
        },
    }
end

TestRunner:test("decodes per-day request limit + model + retry delay", function()
    local out = ModelConstraints.formatQuotaDetails(
        quotaBody("GenerateRequestsPerDayPerProjectPerModel-FreeTier", "200", "gemini-3.5-flash-lite", "53s"))
    TestRunner:assertContains(out, "200 requests per day (free tier)", "unit/period/tier decoded")
    TestRunner:assertContains(out, "model gemini-3.5-flash-lite", "quota dimension model named")
    TestRunner:assertContains(out, "You can retry in 53s.", "RetryInfo surfaced")
end)

TestRunner:test("decodes per-minute input-token limit", function()
    local out = ModelConstraints.formatQuotaDetails(
        quotaBody("GenerateContentInputTokensPerModelPerMinute-FreeTier", "250000", "gemini-3.5-flash", nil))
    TestRunner:assertContains(out, "250000 input tokens per minute (free tier)", "token/minute decoded")
    TestRunner:assertEqual(out:find("retry in", 1, true), nil, "no RetryInfo -> no retry line")
end)

TestRunner:test("unrecognized quotaId printed verbatim", function()
    local out = ModelConstraints.formatQuotaDetails(quotaBody("SomeFutureBucket", "7", nil, nil))
    TestRunner:assertContains(out, "SomeFutureBucket = 7", "raw id beats no id")
end)

TestRunner:test("returns nil without a details array", function()
    TestRunner:assertNil(ModelConstraints.formatQuotaDetails(
        { error = { code = 429, message = "You exceeded your current quota." } }), "no details")
    TestRunner:assertNil(ModelConstraints.formatQuotaDetails({}), "no error key")
    TestRunner:assertNil(ModelConstraints.formatQuotaDetails(nil), "nil body")
    TestRunner:assertNil(ModelConstraints.formatQuotaDetails("not a table"), "non-table body")
end)

TestRunner:test("details present but empty of usable facts -> nil", function()
    local body = { error = { details = { { ["@type"] = "type.googleapis.com/google.rpc.Help",
        links = { { url = "https://example.test" } } } } } }
    TestRunner:assertNil(ModelConstraints.formatQuotaDetails(body), "Help-only details yield nothing")
end)

TestRunner:test("extractApiError appends the quota facts (streaming path)", function()
    local raw = json.encode(quotaBody("GenerateRequestsPerDayPerProjectPerModel-FreeTier",
        "200", "gemini-3.5-flash-lite", "12s"))
    local out = StreamHandler.extractApiError(raw)
    TestRunner:assertContains(out, "You exceeded your current quota", "message preserved")
    TestRunner:assertContains(out, "200 requests per day", "quota facts appended")
    TestRunner:assertContains(out, "You can retry in 12s.", "retry delay appended")
end)

TestRunner:test("extractApiError array form also gets the quota facts", function()
    local body = quotaBody("GenerateRequestsPerDayPerProjectPerModel-FreeTier", "50", nil, nil)
    local out = StreamHandler.extractApiError(json.encode({ body }))
    TestRunner:assertContains(out, "50 requests per day", "details found under j[1].error")
end)

--------------------------------------------------------------------------------
-- Test: ModelConstraints.isRateLimitError / maybeAppendRateLimitHint
--------------------------------------------------------------------------------

TestRunner:suite("rate-limit hint: gating")

local RATE_NEEDLE = "counted per model"

TestRunner:test("recognizes the common 429 wordings", function()
    for _idx, msg in ipairs({
        "HTTP 429: quota exceeded",
        "Resource has been exhausted (RESOURCE_EXHAUSTED)",
        "You exceeded your current quota",
        "Rate limit reached for gpt-5.5",
        "429 Too Many Requests",
    }) do
        TestRunner:assertTrue(ModelConstraints.isRateLimitError(msg), "should match: " .. msg)
    end
end)

TestRunner:test("does not fire on unrelated failures", function()
    TestRunner:assertTrue(not ModelConstraints.isRateLimitError("HTTP 401: API key not valid"), "auth")
    TestRunner:assertTrue(not ModelConstraints.isRateLimitError("Request cancelled by user."), "cancel")
    TestRunner:assertTrue(not ModelConstraints.isRateLimitError(nil), "nil")
end)

TestRunner:test("isOverloadError: recognizes 503/overload wordings, ignores the rest", function()
    for _idx, msg in ipairs({
        "HTTP 503: Service Unavailable",
        "The model is overloaded. Please try again later.",
        "The service is experiencing high demand",
    }) do
        TestRunner:assertTrue(ModelConstraints.isOverloadError(msg), "should match: " .. msg)
    end
    TestRunner:assertTrue(not ModelConstraints.isOverloadError("HTTP 429: quota exceeded"), "429 is rate-limit class")
    TestRunner:assertTrue(not ModelConstraints.isOverloadError("HTTP 401: API key not valid"), "auth")
    TestRunner:assertTrue(not ModelConstraints.isOverloadError(nil), "nil")
end)

TestRunner:test("appends provider-neutral tip and names the provider", function()
    local out = ModelConstraints.maybeAppendRateLimitHint("HTTP 429: quota exceeded", "gemini", "gemini-3.5-flash-lite")
    TestRunner:assertContains(out, RATE_NEEDLE, "tip appended")
    TestRunner:assertContains(out, "this is gemini's own rate limit", "provider named")
end)

TestRunner:test("no tip for non-rate-limit errors", function()
    TestRunner:assertEqual(
        ModelConstraints.maybeAppendRateLimitHint("HTTP 400: bad request", "openai", "gpt-5.5"),
        "HTTP 400: bad request", "unchanged")
end)

TestRunner:test("yields to the more specific grounding tip", function()
    local grounded = ModelConstraints.maybeAppendGemini3GroundingHint(
        "HTTP 429: quota exceeded", "gemini", "gemini-3.5-flash", ws_on())
    local out = ModelConstraints.maybeAppendRateLimitHint(grounded, "gemini", "gemini-3.5-flash", ws_on())
    TestRunner:assertEqual(out, grounded, "should not stack a second tip")
end)

--------------------------------------------------------------------------------
-- Test: ModelConstraints.prefixProviderModel / decorateRequestError
--------------------------------------------------------------------------------

TestRunner:suite("error decoration: provider/model attribution")

TestRunner:test("prefixes provider/model", function()
    TestRunner:assertEqual(
        ModelConstraints.prefixProviderModel("You exceeded your current quota.", "gemini", "gemini-3.5-flash-lite"),
        "gemini/gemini-3.5-flash-lite: You exceeded your current quota.", "labelled")
end)

TestRunner:test("provider only when model unknown", function()
    TestRunner:assertEqual(
        ModelConstraints.prefixProviderModel("boom", "ollama", nil), "ollama: boom", "provider alone")
end)

TestRunner:test("idempotent (retries do not stack prefixes)", function()
    local once = ModelConstraints.prefixProviderModel("boom", "gemini", "gemini-3")
    TestRunner:assertEqual(ModelConstraints.prefixProviderModel(once, "gemini", "gemini-3"), once, "no double prefix")
end)

TestRunner:test("unchanged without a provider", function()
    TestRunner:assertEqual(ModelConstraints.prefixProviderModel("boom", nil, "some-model"), "boom", "no provider")
end)

TestRunner:test("decorateRequestError: label + rate-limit tip together", function()
    local out = ModelConstraints.decorateRequestError(
        "You exceeded your current quota, please check your plan and billing details.",
        "gemini", "gemini-3.5-flash-lite", { features = {} })
    TestRunner:assertContains(out, "gemini/gemini-3.5-flash-lite:", "model named")
    TestRunner:assertContains(out, RATE_NEEDLE, "generic tip applied")
end)

TestRunner:test("decorateRequestError: grounded 429 gets the grounding tip only", function()
    local out = ModelConstraints.decorateRequestError(
        "You exceeded your current quota.", "gemini", "gemini-3.5-flash-lite", ws_on())
    TestRunner:assertContains(out, TIP_NEEDLE, "grounding tip applied")
    TestRunner:assertEqual(out:find(RATE_NEEDLE, 1, true), nil, "generic tip suppressed")
end)

TestRunner:suite("per-minute admission refusals (docs/tpm_admission_plan.md)")

local GROQ_413 = "Request too large for model `openai/gpt-oss-20b` in organization `org_x` service tier "
    .. "`on_demand` on tokens per minute (TPM): Limit 8000, Requested 32979, please reduce your message "
    .. "size and try again."

TestRunner:test("admission refusal: honest explanation replaces the book-text tip", function()
    local out = ModelConstraints.decorateRequestError(GROQ_413, "groq", "openai/gpt-oss-20b", { features = {} })
    TestRunner:assertContains(out, "groq/openai/gpt-oss-20b:", "model named")
    TestRunner:assertContains(out, "counts the answer budget", "explains the mechanism")
    TestRunner:assertContains(out, "32979", "provider's requested number")
    TestRunner:assertContains(out, "8000", "provider's limit")
    TestRunner:assertContains(out, "resends such a request once", "says what the plugin does about it")
    TestRunner:assertEqual(out:find("Max Text Characters", 1, true), nil, "book-text advice gone")
    TestRunner:assertEqual(out:find(RATE_NEEDLE, 1, true), nil, "generic wait-and-retry tip suppressed")
end)

TestRunner:test("admission refusal: prompt alone over the allowance = scope advice", function()
    local out = ModelConstraints.decorateRequestError(
        "on tokens per minute (TPM): Limit 8000, Requested 150000, please reduce your message size",
        "groq", "openai/gpt-oss-120b", { features = {} })
    TestRunner:assertContains(out, "larger than the allowance", "prompt-too-big branch")
    TestRunner:assertContains(out, "smaller scope", "scope advice")
    TestRunner:assertEqual(out:find("resends such a request once", 1, true), nil, "no resend promise")
end)

TestRunner:test("admission refusal is a rate-limit for the persistent dialog (HTTP 413, no 429 wording)", function()
    TestRunner:assertEqual(ModelConstraints.isRateLimitError(GROQ_413), true, "413 TPM wording classed as rate limit")
    TestRunner:assertEqual(ModelConstraints.isRateLimitError("HTTP 413: Request Entity Too Large"), false,
        "a plain 413 is not")
end)

TestRunner:test("decorateRequestError: size errors still get the context tip", function()
    local out = ModelConstraints.decorateRequestError(
        "Request too large for gpt-5.5", "openai", "gpt-5.5", { features = {} })
    TestRunner:assertContains(out, "openai/gpt-5.5:", "model named")
    TestRunner:assertContains(out, "too large for the selected model", "context-limit tip preserved")
end)

--------------------------------------------------------------------------------
-- Summary
--------------------------------------------------------------------------------

local success = TestRunner:summary()
return success
