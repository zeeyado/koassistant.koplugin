-- End-to-end transport check for per-minute admission limits, WITHOUT provider
-- credentials: drives the REAL koassistant_api/base.lua fetch paths against
-- tests/tools/tpm_stub_server.py under KOReader's bundled LuaJIT + ffi.
--
--   python3 tests/tools/tpm_stub_server.py &          # port 8765, limit 8000
--   (cd /Applications/KOReader.app/Contents/koreader && ./luajit \
--       "/path/to/koassistant.koplugin/tests/tools/tpm_e2e.lua" /path/to/koassistant.koplugin)
--
-- Checks: (1) fetchInSubprocess returns the rate-limit headers as a 3rd value;
-- (2) the forked backgroundRequest child forwards them as the pipe marker line, on
-- a 413 (marker + NON-200 marker) and on a 200 SSE stream (marker trails the body);
-- (3) the parent-side helpers recover the plan from that pipe content and size a
-- fitting budget. Exit code 1 on any failure.
local plugin_dir = arg[1] or "."
require("setupkoenv")
package.path = plugin_dir .. "/?.lua;" .. plugin_dir .. "/koassistant_api/?.lua;" .. package.path
local ffiutil = require("ffi/util")
local json = require("json")
local BaseHandler = require("koassistant_api.base")
local RL = require("koassistant_rate_limits")

local URL = os.getenv("TPM_STUB_URL") or "http://127.0.0.1:8765/v1/chat/completions"
local failed = 0
local function check(cond, msg)
    if cond then print("  ok   " .. msg) else failed = failed + 1; print("  FAIL " .. msg) end
end
local function body(max_tokens, stream)
    return json.encode({ model = "stub-model", stream = stream or nil, max_tokens = max_tokens,
        messages = { { role = "user", content = "Reply with only: ok" } } })
end
-- Content-Length like the real handlers (the stub does not speak chunked uploads)
local function hdrs(b) return { ["Content-Type"] = "application/json", ["Content-Length"] = tostring(#b) } end

print("[1] fetchInSubprocess (in-process http path) exposes headers")
local b1 = body(32768)
local code, resp, headers = BaseHandler.fetchInSubprocess(URL, { method = "POST", headers = hdrs(b1), body = b1 })
check(code == 413, "413 on a 32768 budget (got " .. tostring(code) .. ")")
check(type(headers) == "table" and headers["x-ratelimit-limit-tokens"] == "8000", "3rd return carries x-ratelimit-limit-tokens=8000")
local f = RL.fromHeaders(headers)
check(f and f.limit_tokens == "8000", "RateLimits.fromHeaders reads it")

local function runChild(max_tokens, stream)
    local h = BaseHandler:new{}
    local b = body(max_tokens, stream)
    local child = h:backgroundRequest(URL, hdrs(b), b)
    local pid, parent_read_fd = ffiutil.runInSubProcess(child, true)
    assert(pid and parent_read_fd, "fork failed")
    local out = ffiutil.readAllFromFD(parent_read_fd)
    ffiutil.terminateSubProcess(pid)
    return out or ""
end

print("[2] forked child: 413 -> rate-limit marker + NON-200 marker")
local out413 = runChild(32768)
local fields413, cleaned413 = RL.extractMarker(out413)
check(fields413 and fields413.limit_tokens == "8000", "marker line present with limit 8000")
check(cleaned413:find(BaseHandler.PROTOCOL_NON_200, 1, true) ~= nil, "NON-200 marker still present after stripping")
check(cleaned413:find("Requested", 1, true) ~= nil, "refusal body reached the pipe")
local refusal = RL.parseRefusal(cleaned413)
check(refusal and refusal.limit == 8000, "parseRefusal reads Limit 8000 from the pipe text")
-- The refusal's retry-after header rides the same marker into the wait memo
-- (2026-09-05): the wait tip and the checkpoint ladder's retry read it there.
check(fields413 and fields413.retry_after == "7", "retry-after 7 forwarded on the refusal")
RL._reset()
RL.record("custom_stub", "stub-model", fields413, "header")
local wait = RL.retryAfter("", "custom_stub", "stub-model")
check(wait and wait > 5 and wait <= 7, "the wait memo answers about 7 s (got " .. tostring(wait) .. ")")
check(refusal and RL.retryBudget(refusal, 32768, #body(32768)) ~= nil, "a fitting resend budget exists")

print("[3] forked child: 200 SSE -> marker trails the stream, body intact")
local out200 = runChild(4096, true)
local fields200, cleaned200 = RL.extractMarker(out200)
check(fields200 and fields200.limit_tokens == "8000", "marker present on a 200 stream")
check(cleaned200:find("data: [DONE]", 1, true) ~= nil, "SSE stream intact after stripping")
check(cleaned200:find(RL.PROTOCOL_MARKER, 1, true) == nil, "exactly one marker, fully stripped")

print("[4] parent sizing from what the pipe delivered")
RL._reset()
RL.record("custom_stub", "stub-model", fields200, "header")
local cap = RL.budgetCap("custom_stub", "stub-model", #body(32768))
check(cap and cap < 8000 and cap > 7000, "budgetCap ~7.5K for a tiny prompt (got " .. tostring(cap) .. ")")
local capped, changed = RL.applyCap(32768, cap)
check(changed and capped == cap, "32768 default shrinks to the cap")
check(select(2, RL.applyCap(4096, cap)) == false, "a 4096 pin is left alone")
local b2 = body(capped)
local code2 = BaseHandler.fetchInSubprocess(URL, { method = "POST", headers = hdrs(b2), body = b2 })
check(code2 == 200, "the capped request is admitted by the stub (got " .. tostring(code2) .. ")")

print(failed == 0 and "\nTPM e2e: all checks passed" or ("\nTPM e2e: " .. failed .. " check(s) FAILED"))
os.exit(failed == 0 and 0 or 1)
