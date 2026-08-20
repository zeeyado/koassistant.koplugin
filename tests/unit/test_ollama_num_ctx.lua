-- Unit tests for ollama's per-request num_ctx sizing (audit quick win).
-- Guards a device-confirmed silent-truncation bug: ollama allocates the
-- context PER REQUEST (default 4096) and silently truncates longer prompts.

local function setupPaths()
    local info = debug.getinfo(1, "S")
    local script_path = info.source:match("@?(.*)")
    local unit_dir = script_path:match("(.+)/[^/]+$") or "."
    local tests_dir = unit_dir:match("(.+)/[^/]+$") or "."
    local plugin_dir = tests_dir:match("(.+)/[^/]+$") or "."
    package.path = table.concat({
        plugin_dir .. "/?.lua", tests_dir .. "/?.lua", tests_dir .. "/lib/?.lua", package.path,
    }, ";")
end
setupPaths()
require("mock_koreader")

local OllamaHandler = require("koassistant_api/ollama")

local TestRunner = { passed = 0, failed = 0 }
function TestRunner:test(name, fn)
    local ok, err = pcall(fn)
    if ok then self.passed = self.passed + 1; print("    ✓ " .. name)
    else self.failed = self.failed + 1; print("    ✗ " .. name); print("      Error: " .. tostring(err)) end
end
function TestRunner:eq(a, b, msg)
    if a ~= b then error(string.format("%s: expected %s, got %s",
        msg or "eq", tostring(b), tostring(a)), 2) end
end

local function build(messages, config)
    config = config or {}
    config.model = config.model or "llama3.2"
    return OllamaHandler:buildRequestBody(messages, config)
end

print("")
print(string.rep("=", 50))
print("  Unit Tests: Ollama num_ctx Sizing")
print(string.rep("=", 50))

TestRunner:test("by default no num_ctx is sent: the server decides", function()
    local r = build({ { role = "user", content = string.rep("a", 300000) } })
    TestRunner:eq(r.body.options.num_ctx, nil, "no window imposed on the server")
    TestRunner:eq(type(r.body.options.temperature), "number", "other options still sent")
end)

TestRunner:test("a limit turns fitting on: tiny prompt sits on the 8192 floor", function()
    local r = build({ { role = "user", content = "hello" } },
        { features = { ollama_num_ctx = 65536 } })
    TestRunner:eq(r.body.options.num_ctx, 8192, "floor bucket, not the limit")
end)

TestRunner:test("a ~24K-char prompt lands in the 16384 bucket", function()
    -- needed = ceil(24000/3) + 4096 = 12096 -> next power-of-two bucket 16384
    local r = build({ { role = "user", content = string.rep("a", 24000) } },
        { features = { ollama_num_ctx = 65536 } })
    TestRunner:eq(r.body.options.num_ctx, 16384, "power-of-two bucket above needed")
end)

TestRunner:test("the limit is a ceiling the sizing never crosses", function()
    local r = build({ { role = "user", content = string.rep("a", 300000) } },
        { features = { ollama_num_ctx = 16384 } })
    TestRunner:eq(r.body.options.num_ctx, 16384, "capped, residual truncation reported by the stream")
end)

TestRunner:test("a limit below the floor is ignored rather than half-honoured", function()
    local r = build({ { role = "user", content = "hello" } },
        { features = { ollama_num_ctx = 4096 } })
    TestRunner:eq(r.body.options.num_ctx, nil, "server decides instead of a sub-floor window")
end)

TestRunner:test("explicit api_params.num_ctx wins untouched", function()
    local r = build({ { role = "user", content = string.rep("a", 60000) } },
        { api_params = { num_ctx = 4096 }, features = { ollama_num_ctx = 65536 } })
    TestRunner:eq(r.body.options.num_ctx, 4096, "user override passes through")
end)

TestRunner:test("system text counts toward the bucket", function()
    -- 12000 sys + 12000 user = 24000 chars -> 16384 like the single-message case
    local r = OllamaHandler:buildRequestBody(
        { { role = "user", content = string.rep("b", 12000) } },
        { model = "llama3.2", features = { ollama_num_ctx = 65536 },
          system = { text = string.rep("s", 12000) } })
    TestRunner:eq(r.body.options.num_ctx, 16384, "system message is part of the prompt")
end)

-- The pre-send warning: knowing a prompt will be cut is only useful BEFORE the
-- request goes out, because a truncated whole-book prompt on a local model
-- streams for minutes (device 2026-08-20).
local UIManagerStub = package.loaded["ui/uimanager"]
local scheduled, shown = {}, {}
UIManagerStub.scheduleIn = function(_self, _t, fn) table.insert(scheduled, fn) end
UIManagerStub.show = function(_self, w) table.insert(shown, w) end
package.loaded["ui/widget/infomessage"] = { new = function(_self, o) return o end }
OllamaHandler.backgroundRequest = function() return function() end end

local BIG = { { role = "user", content = string.rep("a", 515522) } }
local SMALL = { { role = "user", content = "explain this sentence" } }

local function send(messages, features, model)
    scheduled, shown = {}, {}
    OllamaHandler.observed_context = OllamaHandler.observed_context or {}
    OllamaHandler:query(messages, { model = model or "gemma3:4b", features = features })
    for _i = 1, #scheduled do scheduled[_i]() end
    return #shown, shown[1]
end

TestRunner:test("a limited window warns before the request is sent", function()
    local count, msg = send(BIG, { ollama_num_ctx = 8192 })
    TestRunner:eq(count, 1, "one notice")
    TestRunner:eq(msg.timeout, nil, "stays on screen until dismissed")
    if not msg.text:find("8192", 1, true) then error("notice names the window") end
end)

TestRunner:test("a server that cannot be asked falls back to the after-the-fact report", function()
    OllamaHandler.observed_context, OllamaHandler.probed = {}, {}
    TestRunner:eq(send(BIG, {}), 0, "no window, no claim; the stream reports the cut instead")
end)

TestRunner:test("a window learned from a truncated reply warns the NEXT request", function()
    OllamaHandler.observed_context, OllamaHandler.probed = {}, {}
    OllamaHandler.recordObservedContext("gemma3:4b", 4096)
    local count, msg = send(BIG, {})
    TestRunner:eq(count, 1, "warned up front on the second try")
    if not msg.text:find("4096", 1, true) then error("notice names the learned window") end
end)

-- The default mode is where readers actually meet truncation, so "we cannot
-- know the window" is not an answer: ollama is asked. /api/ps reports the
-- EFFECTIVE window of a loaded runner; a cold model is loaded first with
-- ollama's own load-only call.
local Base = require("koassistant_api.base")
local real_fetch = Base.fetchInSubprocess
local fetch_log = {}
local function stubServer(ps_window, opts)
    opts = opts or {}
    fetch_log = {}
    Base.fetchInSubprocess = function(url, o)
        table.insert(fetch_log, url)
        if url:find("/api/ps", 1, true) then
            if opts.cold and #fetch_log == 1 then return 200, [[{"models":[]}]] end
            if not ps_window then return 200, [[{"models":[]}]] end
            return 200, string.format(
                [[{"models":[{"name":"gemma3:4b","context_length":%d}]}]], ps_window)
        end
        if url:find("/api/generate", 1, true) then
            if opts.load_fails then return 500, "" end
            TestRunner:eq((o or {}).method, "POST", "load call is a POST")
            return 200, [[{"done_reason":"load"}]]
        end
        return nil, "unexpected url"
    end
end

TestRunner:test("server mode asks ollama for the real window, then warns", function()
    OllamaHandler.observed_context, OllamaHandler.probed = {}, {}
    stubServer(4096)
    local count, msg = send(BIG, {})
    Base.fetchInSubprocess = real_fetch
    TestRunner:eq(count, 1, "warned before sending")
    TestRunner:eq(OllamaHandler.observed_context["gemma3:4b"], 4096, "window remembered")
    if not msg.text:find("4096", 1, true) then error("notice names the server's window") end
end)

TestRunner:test("a cold model is loaded first so the window can be read", function()
    OllamaHandler.observed_context, OllamaHandler.probed = {}, {}
    stubServer(4096, { cold = true })
    local count = send(BIG, {})
    local urls = table.concat(fetch_log, " ")
    Base.fetchInSubprocess = real_fetch
    TestRunner:eq(count, 1, "still warned")
    if not urls:find("/api/generate", 1, true) then error("load-only call not made") end
end)

TestRunner:test("a small request never pays for a probe", function()
    OllamaHandler.observed_context, OllamaHandler.probed = {}, {}
    stubServer(4096)
    local count = send(SMALL, {})
    local n = #fetch_log
    Base.fetchInSubprocess = real_fetch
    TestRunner:eq(count, 0, "no warning")
    TestRunner:eq(n, 0, "and no request to the server")
end)

TestRunner:test("an unreachable server is asked once, not on every send", function()
    OllamaHandler.observed_context, OllamaHandler.probed = {}, {}
    stubServer(nil, { load_fails = true })
    send(BIG, {})
    local first = #fetch_log
    local before = #fetch_log
    send(BIG, {})
    local second = #fetch_log - before
    Base.fetchInSubprocess = real_fetch
    if first == 0 then error("first send should have tried") end
    TestRunner:eq(second, 0, "second send does not retry the probe")
end)

TestRunner:test("unattended background work never interrupts and never probes", function()
    OllamaHandler.observed_context, OllamaHandler.probed = {}, {}
    stubServer(4096)
    local count = send(BIG, { _background_request = true })
    local n = #fetch_log
    Base.fetchInSubprocess = real_fetch
    TestRunner:eq(count, 0, "silent")
    TestRunner:eq(n, 0, "no probe from a background build")
end)

TestRunner:test("a prompt that fits says nothing", function()
    OllamaHandler.observed_context, OllamaHandler.probed = {}, {}
    TestRunner:eq(send(SMALL, { ollama_num_ctx = 8192 }), 0, "fitted, no warning")
    OllamaHandler.recordObservedContext("gemma3:4b", 4096)
    TestRunner:eq(send(SMALL, {}), 0, "learned window, still fits")
end)

print("")
print(string.rep("-", 50))
print(string.format("  Results: %d passed, %d failed", TestRunner.passed, TestRunner.failed))
print(string.rep("-", 50))
return TestRunner.failed == 0
