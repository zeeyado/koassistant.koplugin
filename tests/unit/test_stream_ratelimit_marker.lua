-- The streaming consumer must learn the plan's per-minute allowance from the
-- pipe marker the forked fetch child writes -- on BOTH transports.
--
-- koassistant_api/base.lua writes RateLimits.PROTOCOL_MARKER BEFORE the body on
-- the macOS raw-SSL path and AFTER the body on the http.request path that every
-- device uses. stream_handler.lua's line loop returns out of the whole poll
-- callback at "data: [DONE]" (and at the SSE/NDJSON error branches), so on the
-- device transport the marker lands in partial_data and the session memo stays
-- empty -- the #106 protection never arms before the first refusal.
--
-- This file drives the REAL loop (StreamHandler:showStreamDialog) over a
-- recorded pipe buffer, with a replay ffi/ffi-util in place of the subprocess.
-- Byte layout verified 2026-09-04 against a real forked child talking to
-- tests/tools/tpm_stub_server.py: a 200 SSE stream ends
-- "data: [DONE]\n\n\r\nX-KOA-RATELIMIT:...\n\n", and a streamed 413 arrives as
-- "<json error body>\r\nX-KOA-RATELIMIT:...\n\n\r\nX-NON-200-STATUS:...\n\n".
--
-- Run: lua tests/unit/test_stream_ratelimit_marker.lua  (or lua tests/run_tests.lua --unit)

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
function TestRunner:suite(name) print(string.format("\n  [%s]", name)) end
function TestRunner:test(name, fn)
    local ok, err = pcall(fn)
    if ok then self.passed = self.passed + 1; print("    ok   " .. name)
    else self.failed = self.failed + 1; print("    FAIL " .. name); print("      " .. tostring(err)) end
end
function TestRunner:assertEqual(actual, expected, msg)
    if actual ~= expected then
        error(string.format("%s: expected %s, got %s", msg or "assert",
            tostring(expected), tostring(actual)), 2)
    end
end
function TestRunner:assertTrue(v, msg) if not v then error(msg or "expected truthy", 2) end end

-- ------------------------------------------------------------------
-- Replay transport: everything showStreamDialog touches, restored at the end
-- so the shared-process unit harness (tests/run_tests.lua loadfile()s every
-- file into ONE Lua state) sees its own mocks again.
-- ------------------------------------------------------------------
local SAVED_KEYS = {
    "ffi", "ffi/util", "ui/uimanager", "device",
    "ui/widget/inputtext", "ui/widget/inputdialog", "stream_handler",
}
local saved = {}
for _idx, k in ipairs(SAVED_KEYS) do saved[k] = package.loaded[k] end

-- A scripted pipe: an ordered list of { text, delay } segments. `delay` is how
-- many further poll ticks must pass before that segment becomes readable, so a
-- fixture can model a marker that the child writes AFTER the parent has already
-- seen "data: [DONE]" (the real ordering on a slow provider).
local pipe = { segs = {}, idx = 1, pos = 1, tick = 0, ready_at = 0 }
local held = ""   -- the "buffer" ffi.string reads back

local function pipeReady()
    local seg = pipe.segs[pipe.idx]
    if not seg then return nil end
    if pipe.tick < pipe.ready_at then return nil end
    return seg
end
local function pipeAvailable()
    local seg = pipeReady()
    if not seg then return 0 end
    return #seg.text - pipe.pos + 1
end
local function pipeExhausted()
    return pipe.idx > #pipe.segs
end

package.loaded["ffi"] = {
    os = "Linux",
    C = {
        close = function() end,
        strerror = function() return "replay" end,
        read = function(_fd, _ptr, size)
            local seg = pipeReady()
            if not seg then return pipeExhausted() and 0 or -1 end
            held = seg.text:sub(pipe.pos, pipe.pos + size - 1)
            pipe.pos = pipe.pos + #held
            if pipe.pos > #seg.text then
                pipe.idx = pipe.idx + 1
                pipe.pos = 1
                local nxt = pipe.segs[pipe.idx]
                pipe.ready_at = pipe.tick + ((nxt and nxt.delay) or 0)
            end
            return #held
        end,
    },
    errno = function() return 0 end,
    string = function(_buf, n) return held:sub(1, n) end,
    new = function() return {} end,
    cast = function(_ctype, b) return b end,
    typeof = function() return function() end end,
    cdef = function() end,
}

local real_ffiutil = saved["ffi/util"]
package.loaded["ffi/util"] = setmetatable({
    runInSubProcess = function() return 4242, 7 end,
    terminateSubProcess = function() end,
    isSubProcessDone = function() return pipeExhausted() end,
    getNonBlockingReadSize = function() pipe.tick = pipe.tick + 1; return pipeAvailable() end,
    readAllFromFD = function() return "" end,
    writeToFD = function() end,
}, { __index = real_ffiutil })   -- keeps template() and friends

local queue = {}
package.loaded["ui/uimanager"] = {
    show = function() end, close = function() end, setDirty = function() end,
    -- Faithful to KOReader: scheduleIn returns NOTHING (frontend/ui/uimanager.lua),
    -- and unschedule takes the action. A stub that returned a handle hid a
    -- device-only double finish (a cancel during the drain).
    scheduleIn = function(_self, _sec, fn) queue[#queue + 1] = fn end,
    unschedule = function(_self, fn)
        for i, f in ipairs(queue) do if f == fn then table.remove(queue, i); break end end
    end,
}

package.loaded["device"] = {
    screen = {
        getWidth = function() return 800 end,
        getHeight = function() return 600 end,
        scaleBySize = function(_self, n) return n end,
        getDPI = function() return 160 end,
    },
    isTouchDevice = function() return false end,
    hasKeys = function() return false end,
    hasDPad = function() return false end,
}

local function widgetClass(name)
    local C = { _stub = name }
    function C:new(o) o = o or {}; setmetatable(o, { __index = self }); return o end
    function C:extend(o) o = o or {}; setmetatable(o, { __index = self }); return o end
    return C
end
local InputTextStub = widgetClass("inputtext")
function InputTextStub:setText() end
function InputTextStub:addChars() end
function InputTextStub:scrollToBottom() end
function InputTextStub:scrollUp() end
function InputTextStub:scrollDown() end
function InputTextStub:initTextBox() end
function InputTextStub:onCloseWidget() end
package.loaded["ui/widget/inputtext"] = InputTextStub

local InputDialogStub = widgetClass("inputdialog")
local last_dialog  -- the stream dialog the handler built last (its close callback = Cancel)
function InputDialogStub:new(o)
    o = o or {}
    setmetatable(o, { __index = self })
    o._input_widget = (o.inputtext_class or InputTextStub):new{}
    o.title_bar = { init = function() end }
    last_dialog = o
    return o
end
package.loaded["ui/widget/inputdialog"] = InputDialogStub

package.loaded["stream_handler"] = nil
local StreamHandler = require("stream_handler")
local RL = require("koassistant_rate_limits")

-- ------------------------------------------------------------------
-- Fixtures. The marker line is produced by the module that writes it on the
-- wire, so a format change can never make this test pass by accident.
-- ------------------------------------------------------------------
local HEADERS = {
    ["x-ratelimit-limit-tokens"] = "8000",
    ["x-ratelimit-remaining-tokens"] = "3900",
    ["x-ratelimit-reset-tokens"] = "1m0s",
}
local MARKER = RL.encodeMarker(HEADERS)         -- "\r\nX-KOA-RATELIMIT:...\n\n"
local NON200 = "\r\nX-NON-200-STATUS:Error 413: Content Too Large\n\n"

local SSE_BODY =
    'data: {"choices":[{"index":0,"delta":{"content":"ok"},"finish_reason":null}]}\n\n' ..
    'data: {"choices":[{"index":0,"delta":{},"finish_reason":"stop"}],' ..
    '"usage":{"prompt_tokens":4,"completion_tokens":1,"total_tokens":5}}\n\n' ..
    'data: [DONE]\n\n'

local REFUSAL_BODY = '{"error": {"message": "Request too large for model `openai/gpt-oss-20b` in ' ..
    'organization `org_01kx` service tier `on_demand` on tokens per minute (TPM): Limit 8000, ' ..
    'Requested 32979, please reduce your message size and try again.", "type": "tokens", ' ..
    '"code": "rate_limit_exceeded"}}'

--- Drive the real streaming loop over one recorded pipe buffer.
--- @return boolean ok, string|nil content, string|nil err
local function runStream(segments)
    RL._reset()
    if type(segments) == "string" then segments = { { text = segments, delay = 0 } } end
    pipe.segs, pipe.idx, pipe.pos, pipe.tick, pipe.ready_at, held = segments, 1, 1, 0, 0, ""
    queue = {}
    local out = {}
    StreamHandler:new{}:showStreamDialog(
        function() end, "groq", "openai/gpt-oss-20b",
        -- 125 ms: the drain grace is max(4 polls, 0.5 s / interval), so this keeps
        -- the bound at 4 polls; the replay never sleeps, so it costs nothing.
        { provider_name = "groq", model = "openai/gpt-oss-20b",
          poll_interval_ms = 125, display_interval_ms = 1, prompt_chars = 100 },
        function(ok, content, err)
            -- pipe.tick counts pipe polls; snapshot it AT completion so the
            -- post-finish subprocess collection (cleanup's 5 s task) is not counted
            out = { ok = ok, content = content, err = err, polls = pipe.tick }
        end)
    local guard = 0
    while #queue > 0 and guard < 200 do
        guard = guard + 1
        table.remove(queue, 1)()
    end
    return out.ok, out.content, out.err, out.polls, (out.ok ~= nil or out.err ~= nil)
end

local function learned()
    local k = RL.known("groq", "openai/gpt-oss-20b")
    return k and k.limit_tokens or nil
end

TestRunner:suite("pipe marker reaches the session memo on both transports")

-- Control: the macOS raw-SSL order (marker written BEFORE the body).
-- This one passes today; it proves the harness really drives the marker branch.
TestRunner:test("macOS order (marker first): the allowance is learned", function()
    local ok, content = runStream(MARKER .. SSE_BODY)
    TestRunner:assertTrue(ok, "stream completed")
    TestRunner:assertEqual(content, "ok", "answer text intact")
    TestRunner:assertEqual(learned(), 8000, "memo learned the plan")
end)

-- The device transport. Regression guard for the shape B4 fixed: "data: [DONE]"
-- returns out of the whole poll callback before the marker branch is ever reached,
-- so without endStream()'s drain the memo stays empty.
TestRunner:test("device order (marker after [DONE]): the allowance is learned", function()
    local ok, content = runStream(SSE_BODY .. MARKER)
    TestRunner:assertTrue(ok, "stream completed")
    TestRunner:assertEqual(content, "ok", "answer text intact")
    TestRunner:assertEqual(learned(), 8000, "memo learned the plan")
end)

-- A streamed refusal carries its own headers. Same shape one branch over: the
-- SSE/NDJSON error branches return out of the poll callback too, so a streamed 413
-- taught the session nothing before the drain.
TestRunner:test("streamed 413: the refusal's own headers are learned", function()
    local ok, _content, err = runStream(REFUSAL_BODY .. MARKER .. NON200)
    TestRunner:assertTrue(not ok, "reported as a failure")
    TestRunner:assertTrue(type(err) == "string" and err:find("Limit 8000", 1, true) ~= nil,
        "the provider's own wording reached the caller")
    TestRunner:assertEqual(learned(), 8000, "memo learned the plan")
end)

-- The marker is protocol, never prose (F27). An empty stream leaves it in
-- partial_data, which finishStream reports as "No response received. Raw: ...";
-- harvestMarkers has to STRIP it, not merely read it.
TestRunner:test("the marker never reaches a user-facing string", function()
    local _ok, _content, err = runStream("data: [DONE]\n\n" .. MARKER)
    TestRunner:assertTrue(type(err) ~= "string" or err:find(RL.PROTOCOL_MARKER, 1, true) == nil,
        "marker text leaked into the error message: " .. tostring(err))
end)

-- A tail scan of partial_data is not enough. On a real provider the last body
-- chunk can reach the parent one poll before http.request returns in the child, so
-- the marker is not merely unscanned, it has not arrived yet. This fixture releases
-- it one tick after [DONE]; only a fix that keeps reading before finishStream tears
-- the descriptor down can pass it.
TestRunner:test("late marker (arrives a poll after [DONE]) is still learned", function()
    local ok = runStream({ { text = SSE_BODY, delay = 0 }, { text = MARKER, delay = 1 } })
    TestRunner:assertTrue(ok, "stream completed")
    TestRunner:assertEqual(learned(), 8000, "memo learned the plan")
end)

-- ------------------------------------------------------------------
-- Round 3 (critique G9): the drain has to be BOUNDED and CHEAP as well as
-- correct. These four cases fence the mechanism in from the other side.
-- ------------------------------------------------------------------

-- Two polls late, still inside the grace. A device's last body chunk can reach
-- the parent before the child has returned from http.request and encoded the
-- headers; one tick is the optimistic case.
TestRunner:test("marker two polls after [DONE] is still learned", function()
    local ok = runStream({ { text = SSE_BODY, delay = 0 }, { text = MARKER, delay = 2 } })
    TestRunner:assertTrue(ok, "stream completed")
    TestRunner:assertEqual(learned(), 8000, "memo learned the plan")
end)

-- A streamed refusal whose headers trail by a poll: the NDJSON error branch
-- must drain too, or a 413 teaches the session nothing on the device transport.
TestRunner:test("late marker after a streamed 413 is learned", function()
    local ok, _c, err = runStream({ { text = REFUSAL_BODY, delay = 0 },
                                   { text = MARKER .. NON200, delay = 1 } })
    TestRunner:assertTrue(not ok, "reported as a failure")
    TestRunner:assertTrue(type(err) == "string" and err:find("Limit 8000", 1, true) ~= nil,
        "the provider's own wording still reached the caller")
    TestRunner:assertEqual(learned(), 8000, "memo learned the plan")
end)

-- A provider that sends no mapped rate-limit header at all (Anthropic, Gemini).
-- The drain must end on the child's exit and must not change the answer.
TestRunner:test("no marker at all: the answer is unchanged and the drain ends", function()
    local ok, content, _e, polls, called = runStream(SSE_BODY)
    TestRunner:assertTrue(called, "on_complete fired")
    TestRunner:assertTrue(ok, "stream completed")
    TestRunner:assertEqual(content, "ok", "answer text intact")
    TestRunner:assertEqual(learned(), nil, "nothing invented when no header was sent")
    TestRunner:assertTrue(polls <= 6, "the drain is bounded, cost " .. tostring(polls) .. " polls")
end)

-- The pathological case: the child neither writes a marker nor exits. The drain
-- must give up on its own bound instead of holding the reader's answer.
--- Drive a stream whose marker never arrives and tap Cancel once a drain tick is
--- pending. Returns what on_complete saw and how often it fired.
local function cancelDuringDrain()
    RL._reset()
    pipe.segs, pipe.idx, pipe.pos, pipe.tick, pipe.ready_at, held =
        { { text = SSE_BODY, delay = 0 }, { text = MARKER, delay = 1000000 } }, 1, 1, 0, 0, ""
    queue = {}
    local completions, seen = 0, {}
    StreamHandler:new{}:showStreamDialog(
        function() end, "groq", "openai/gpt-oss-20b",
        { provider_name = "groq", model = "openai/gpt-oss-20b",
          poll_interval_ms = 125, display_interval_ms = 1, prompt_chars = 100 },
        function(ok, content, err) completions = completions + 1; seen = { ok = ok, content = content, err = err } end)
    local guard, cancelled = 0, false
    while #queue > 0 and guard < 200 do
        guard = guard + 1
        table.remove(queue, 1)()
        -- The body (segment 1) has been consumed and a drain tick is pending:
        -- the reader taps Cancel now.
        if not cancelled and pipe.idx > 1 and #queue > 0 then
            cancelled = true
            last_dialog.title_bar.close_callback()
        end
    end
    return cancelled, completions, seen
end

TestRunner:test("a cancel during the drain finishes the stream exactly once", function()
    local cancelled, completions = cancelDuringDrain()
    TestRunner:assertTrue(cancelled, "the cancel happened while a drain tick was pending")
    -- The loop above pumped up to 200 tasks after the cancel (cleanup's own
    -- subprocess-collection task re-arms itself while the child lives), so a
    -- surviving drain tick would have finished the stream a second time.
    TestRunner:assertEqual(completions, 1, "on_complete fired once")
    TestRunner:assertTrue(#queue <= 1, "only cleanup's collection task remains")
end)

-- Re-audit 2026-09-04: Stop / X during the grace used to report a COMPLETE
-- answer as "Request cancelled by user." The stream had already reached
-- [DONE]; the tap only ends the wait for the marker.
TestRunner:test("a cancel during the drain keeps the complete answer", function()
    local cancelled, _completions, seen = cancelDuringDrain()
    TestRunner:assertTrue(cancelled, "the cancel happened while a drain tick was pending")
    TestRunner:assertTrue(seen.ok, "reported as a success, not a cancel: " .. tostring(seen.err))
    TestRunner:assertEqual(seen.content, "ok", "the complete answer is delivered")
end)

-- The marker prefix is protocol only at a line start (the child writes
-- "\r\n<prefix>...\n\n"). A model quoting the prefix mid-line is content, on
-- both the SSE line loop and the drain's buffer scan.
TestRunner:test("the marker prefix quoted mid-line stays content", function()
    local quoting = 'data: {"choices":[{"index":0,"delta":{"content":"see ' .. RL.PROTOCOL_MARKER ..
        ' in logs"},"finish_reason":null}]}\n\n' .. 'data: [DONE]\n\n'
    local ok, content = runStream(quoting .. MARKER)
    TestRunner:assertTrue(ok, "stream completed")
    TestRunner:assertEqual(content, "see " .. RL.PROTOCOL_MARKER .. " in logs", "the quoted prefix is kept")
    TestRunner:assertEqual(learned(), 8000, "the real marker after [DONE] is still learned")
end)

-- A marker cut off without its newline when the child exits can never complete:
-- it is dropped undecoded and never reaches the "No response received. Raw:" text.
TestRunner:test("a half marker at teardown never reaches the Raw fallback", function()
    local half = "data: [DONE]\n\n\r\n" .. RL.PROTOCOL_MARKER .. "limit_tok"
    local _ok, _content, err = runStream(half)
    TestRunner:assertTrue(type(err) ~= "string" or err:find(RL.PROTOCOL_MARKER, 1, true) == nil,
        "marker prefix leaked: " .. tostring(err))
    TestRunner:assertTrue(type(err) ~= "string" or err:find("limit_tok", 1, true) == nil,
        "half marker body leaked: " .. tostring(err))
    TestRunner:assertEqual(learned(), nil, "a truncated number is never recorded")
end)

-- The grace ends the moment the marker arrives: a late marker costs fewer polls
-- than a child that never writes one.
TestRunner:test("the drain ends early on the marker", function()
    local _o1, _c1, _e1, polls_late = runStream({ { text = SSE_BODY, delay = 0 }, { text = MARKER, delay = 1 } })
    local _o2, _c2, _e2, polls_never = runStream({ { text = SSE_BODY, delay = 0 }, { text = MARKER, delay = 1000000 } })
    TestRunner:assertEqual(learned(), nil, "control: nothing learned when the marker never comes")
    TestRunner:assertTrue(polls_late < polls_never,
        "late marker " .. tostring(polls_late) .. " polls vs never " .. tostring(polls_never))
end)

TestRunner:test("a child that never exits cannot hold the answer", function()
    local ok, content, _e, polls, called = runStream({
        { text = SSE_BODY, delay = 0 },
        { text = MARKER, delay = 1000000 },   -- never becomes readable
    })
    TestRunner:assertTrue(called, "on_complete fired anyway")
    TestRunner:assertTrue(ok, "stream completed")
    TestRunner:assertEqual(content, "ok", "answer text intact")
    TestRunner:assertTrue(polls <= 15, "the grace is bounded, cost " .. tostring(polls) .. " polls")
end)

-- ------------------------------------------------------------------
RL._reset()
package.loaded["stream_handler"] = nil
for _idx, k in ipairs(SAVED_KEYS) do package.loaded[k] = saved[k] end

print(string.format("\n  test_stream_ratelimit_marker: %d passed, %d failed",
    TestRunner.passed, TestRunner.failed))
return TestRunner.failed == 0
