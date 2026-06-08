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

local TIP_NEEDLE = "separate monthly quota"

local function ws_on() return { features = { enable_web_search = true } } end

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
-- Summary
--------------------------------------------------------------------------------

local success = TestRunner:summary()
return success
