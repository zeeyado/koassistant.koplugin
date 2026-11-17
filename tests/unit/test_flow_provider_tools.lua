-- Flow test (docs/test_automation_plan.md, layer 1): Fetch models and Test
-- provider send their requests off the UI loop, behind a waiting message
-- (B709, #126). Both used to send them while the loop stood still: nothing
-- could move on screen, a device that sleeps a few seconds after the last
-- screen update stopped mid-request until a touch, and nothing could be
-- stopped.
--
-- main.lua's own functions, cut from the source and run on a stand-in plugin
-- with the dialogs recorded (tests/lib/ui_recorder.lua) and the fetch
-- replaced: every request is held until the test answers it, which is what
-- lets it see the message that is up meanwhile and tap it.
--
-- Run: lua tests/unit/test_flow_provider_tools.lua  (or lua tests/run_tests.lua --unit)

local function setupPaths()
    local info = debug.getinfo(1, "S")
    local script_path = info.source:match("@?(.*)")
    local unit_dir = script_path:match("(.+)/[^/]+$") or "."
    local tests_dir = unit_dir:match("(.+)/[^/]+$") or "."
    local plugin_dir = tests_dir:match("(.+)/[^/]+$") or "."
    package.path = table.concat({
        plugin_dir .. "/?.lua", tests_dir .. "/?.lua", tests_dir .. "/lib/?.lua", package.path,
    }, ";")
    return plugin_dir
end
local PLUGIN_DIR = setupPaths()
require("mock_koreader")
local TestRunner = require("test_runner"):new()
local Recorder = require("ui_recorder")
local json = require("json")

print("")
print(string.rep("=", 50))
print("  Flow Tests: Fetch models and Test provider")
print(string.rep("=", 50))

local BaseHandler = require("koassistant.api.base")
local RateLimits = require("koassistant.request.rate_limits")
local ModelOverrides = require("koassistant.request.model_overrides")
local saved_user, saved_derived = ModelOverrides._user, ModelOverrides._derived
ModelOverrides._setUserForTests(false)     -- no custom_models.lua from disk
ModelOverrides._setDerivedForTests(false)  -- no learned capabilities from disk

-- ------------------------------------------------------------------ the fetch
-- Every request is held: { url, opts, done, cancelled }. answer(i, ...) hands
-- request i its answer, as the fetch does on the UI loop.
local sent = {}
local saved_async, saved_sync, saved_key = BaseHandler.fetchAsync, BaseHandler.fetchInSubprocess, BaseHandler.getApiKey
BaseHandler.fetchAsync = function(url, opts, on_done)
    local req = { url = url, opts = opts or {}, done = on_done }
    sent[#sent + 1] = req
    return function() req.cancelled = true end
end
BaseHandler.fetchInSubprocess = function() error("a request was sent while the loop waits") end
BaseHandler.getApiKey = function() return "unit-test-key" end  -- never the keys file
local function answer(i, code, body, kept)
    local req = assert(sent[i], "no request " .. tostring(i))
    assert(not req.cancelled, "request " .. i .. " was stopped: the fetch never answers it")
    req.done(code, body, kept)
end
local function probeOf(req)
    local body = json.decode(req.opts.body)
    if body.stream then return "stream" end
    if body.tool_choice == "required" then return "forced_tools" end
    if body.tools then return "tools" end
    if body.reasoning_effort or body.reasoning then return "effort" end
    return "plain"
end

-- ------------------------------------------------------------------ the plugin
local ui = Recorder.install()
local UIManager = require("ui/uimanager")
local InfoMessage = require("ui/widget/infomessage")
local Notification = require("ui/widget/notification")
local T = require("ffi/util").template
local _ = require("koassistant.core.gettext")
local logger = require("koassistant.core.logger")

local main_src
do
    local f = assert(io.open(PLUGIN_DIR .. "/main.lua", "r"))
    main_src = f:read("*a")
    f:close()
end
-- A method of the plugin, from its first line to the "end" at the margin
local function cut(name)
    local s = main_src:find("\nfunction AskGPT:" .. name .. "(", 1, true)
    assert(s, "main.lua has no AskGPT:" .. name)
    local e = assert(main_src:find("\nend\n", s, true))
    return main_src:sub(s + 1, e + 4)
end
local chunk = table.concat({
    "local UIManager, InfoMessage, Notification, T, _, logger, configuration = ...",
    "local AskGPT = {}",
    cut("modelListRequest"), cut("parseModelList"), cut("fetchProviderModels"),
    cut("startFetchModels"), cut("testProvider"),
    "return AskGPT",
}, "\n")
local AskGPT = assert(load(chunk, "=main.lua (cut)"))(UIManager, InfoMessage, Notification, T, _, logger, {})

local STUB = { id = "custom_stub", name = "Stub", base_url = "http://127.0.0.1:1/v1/chat/completions",
    default_model = "stub-model", api_key_required = false }
local reports, pickers
local function plugin()
    reports, pickers = {}, {}
    return setmetatable({
        settings = { readSetting = function() return { provider = "anthropic" } end },
        getProviderDescriptor = function()
            return { id = STUB.id, name = STUB.name, base_url = STUB.base_url,
                default_model = STUB.default_model, is_custom = true }
        end,
        providerSupportsTest = function() return true end,
        getCustomProviders = function() return { STUB } end,
        getCustomProvider = function() return STUB end,
        getCustomModels = function() return {} end,
        showProviderTestReport = function(_self, provider, model, results, caps)
            reports[#reports + 1] = { provider = provider, model = model, results = results, caps = caps }
        end,
        showFetchedModelsPicker = function(_self, provider_id, ids)
            pickers[#pickers + 1] = { provider = provider_id, ids = ids }
        end,
    }, { __index = AskGPT })
end
local function reset()
    for i = #sent, 1, -1 do sent[i] = nil end
    for i = #ui.stack, 1, -1 do ui.stack[i] = nil end
    for i = #ui.shown, 1, -1 do ui.shown[i] = nil end
end
-- The reader's tap on a waiting message: KOReader closes it and runs its
-- dismiss_callback (as on any close of an InfoMessage)
local function tapMessage(w)
    UIManager:close(w)
    if w.dismiss_callback then w.dismiss_callback() end
end
local function topText()
    local w = ui:top()
    return w and tostring(w.text) or "nothing"
end

-- ------------------------------------------------------------------ Fetch models
TestRunner:test("Fetch models: the list is asked for off the loop, behind a message, then the picker", function()
    reset()
    local p = plugin()
    p:startFetchModels("custom_stub")
    TestRunner:assertEqual(#sent, 1, "one request, handed to the fetch that does not hold the loop")
    TestRunner:assertEqual(sent[1].url, "http://127.0.0.1:1/v1/models", "the provider's list endpoint")
    TestRunner:assertEqual(sent[1].opts.headers and sent[1].opts.headers["Authorization"], "Bearer unit-test-key")
    TestRunner:assertTrue(topText():find("^Fetching model list") ~= nil, "a waiting message is up meanwhile: " .. topText())
    TestRunner:assertEqual(#pickers, 0, "nothing else yet")
    answer(1, 200, '{"data":[{"id":"zeta"},{"id":"alpha"},{"id":"alpha"}]}')
    TestRunner:assertEqual(#ui.stack, 0, "the message is closed")
    TestRunner:assertFalse(sent[1].cancelled, "and that close is not a tap: the fetch is not stopped")
    TestRunner:assertEqual(#pickers, 1, "the picker opens")
    TestRunner:assertEqual(table.concat(pickers[1].ids, ","), "alpha,zeta", "with the ids sorted, each once")
end)

TestRunner:test("Fetch models: a tap on the message stops the fetch", function()
    reset()
    local p = plugin()
    p:startFetchModels("custom_stub")
    tapMessage(ui:top())
    TestRunner:assertTrue(sent[1].cancelled, "the request is stopped")
    TestRunner:assertEqual(#ui.stack, 0, "nothing is left on screen")
    TestRunner:assertEqual(#pickers, 0)
end)

TestRunner:test("Fetch models: a list that cannot be fetched says why", function()
    reset()
    local p = plugin()
    p:startFetchModels("custom_stub")
    answer(1, 401, '{"error":"no"}')
    TestRunner:assertTrue(topText():find("Could not fetch models: HTTP 401", 1, true) ~= nil, topText())
    TestRunner:assertTrue(topText():find("needs an API key", 1, true) ~= nil, "with what to do about it")
    reset()
    p:startFetchModels("custom_stub")
    answer(1, nil, "connection refused")
    TestRunner:assertTrue(topText():find("Network error: connection refused", 1, true) ~= nil, topText())
    reset()
    p.getProviderDescriptor = function() return { id = "x", base_url = "" } end
    p:startFetchModels("x")
    TestRunner:assertEqual(#sent, 0, "a provider with no address sends nothing")
    TestRunner:assertTrue(topText():find("Could not fetch models", 1, true) ~= nil, topText())
end)

TestRunner:test("the fetch that waits (Ollama's installed models) reads the same request and answer", function()
    reset()
    local p = plugin()
    local asked
    BaseHandler.fetchInSubprocess = function(url, opts)
        asked = { url = url, timeout = opts.timeout }
        return 200, '{"data":[{"id":"b"},{"id":"a"}]}'
    end
    local ids = p:fetchProviderModels("custom_stub", { timeout = 3 })
    BaseHandler.fetchInSubprocess = function() error("a request was sent while the loop waits") end
    TestRunner:assertEqual(asked.url, "http://127.0.0.1:1/v1/models")
    TestRunner:assertEqual(asked.timeout, 3)
    TestRunner:assertEqual(table.concat(ids, ","), "a,b")
end)

-- ------------------------------------------------------------------ Test provider
TestRunner:test("Test provider: five steps, one at a time, each behind its own message", function()
    reset()
    RateLimits.forget("custom_stub", "stub-model")
    local p = plugin()
    p:testProvider("custom_stub")
    local order = {}
    for step = 1, 5 do
        TestRunner:assertEqual(#sent, step, "step " .. step .. ": its request is out, the next one is not")
        TestRunner:assertTrue(topText():find("^Testing " .. step .. "/5: ") ~= nil, "its message is up: " .. topText())
        TestRunner:assertEqual(#ui.stack, 1, "alone on screen")
        TestRunner:assertEqual(sent[step].opts.method, "POST")
        TestRunner:assertEqual(sent[step].opts.keep_headers, RateLimits.safeFields,
            "the answer's rate limit headers are asked back from the fetch")
        order[step] = probeOf(sent[step])
        local body = order[step] == "stream" and 'data: {"choices":[{"delta":{"content":"pong"}}]}\n\ndata: [DONE]\n\n'
            or '{"choices":[{"message":{"role":"assistant","content":"pong"},"finish_reason":"stop"}]}'
        answer(step, 200, body, step == 1 and { limit_tokens = "8000" } or nil)
    end
    TestRunner:assertEqual(table.concat(order, " "), "plain stream tools forced_tools effort", "the steps in order")
    TestRunner:assertEqual(#ui.stack, 0, "the last message is closed")
    TestRunner:assertEqual(#reports, 1, "one report")
    local r = reports[1]
    TestRunner:assertEqual(r.model, "stub-model")
    TestRunner:assertEqual(#r.results, 5)
    for i, result in ipairs(r.results) do
        TestRunner:assertEqual(result.ok, true, "step " .. i .. " passes: " .. tostring(result.detail))
    end
    TestRunner:assertTrue(r.results[1].detail:find('answered "pong"', 1, true) ~= nil, r.results[1].detail)
    TestRunner:assertTrue(r.caps.tools == true and r.caps.reasoning == true, "what it found, for Record")
    local known = RateLimits.known("custom_stub", "stub-model")
    TestRunner:assertEqual(known and known.limit_tokens, 8000, "the plan's allowance, from the headers the fetch kept")
    RateLimits.forget("custom_stub", "stub-model")
end)

TestRunner:test("Test provider: a refused key ends it at the first step", function()
    reset()
    local p = plugin()
    p:testProvider("custom_stub")
    answer(1, 401, '{"error":{"message":"bad key"}}')
    TestRunner:assertEqual(#sent, 1, "no later step is sent")
    TestRunner:assertEqual(#reports, 1)
    TestRunner:assertEqual(reports[1].results[1].ok, false)
    TestRunner:assertTrue(reports[1].results[1].detail:find("auth failed (HTTP 401)", 1, true) ~= nil, reports[1].results[1].detail)
    TestRunner:assertEqual(#ui.stack, 0)
end)

TestRunner:test("Test provider: tools refused, so the forced step is not sent", function()
    reset()
    local p = plugin()
    p:testProvider("custom_stub")
    answer(1, 200, '{"choices":[{"message":{"role":"assistant","content":"pong"}}]}')
    answer(2, 200, "data: {}\n\n")
    answer(3, 400, '{"error":{"message":"tools are not supported"}}')
    TestRunner:assertEqual(#sent, 4, "the fourth request is the effort step's")
    TestRunner:assertEqual(probeOf(sent[4]), "effort")
    TestRunner:assertTrue(topText():find("^Testing 5/5: ") ~= nil, topText())
    answer(4, 400, '{"error":{"message":"unknown parameter"}}')
    local results = reports[1].results
    TestRunner:assertEqual(#results, 5, "the skipped step is still a line of the report")
    TestRunner:assertEqual(results[3].ok, false)
    TestRunner:assertTrue(results[3].detail:find("tools are not supported", 1, true) ~= nil, results[3].detail)
    TestRunner:assertEqual(results[4].ok, nil, "skipped")
    TestRunner:assertTrue(results[4].detail:find("skipped", 1, true) ~= nil, tostring(results[4].detail))
    TestRunner:assertEqual(results[5].ok, false)
    TestRunner:assertTrue(reports[1].caps.tools == nil and reports[1].caps.reasoning == nil, "nothing to record")
end)

TestRunner:test("Test provider: a forced call refused takes the tools finding back", function()
    reset()
    local p = plugin()
    p:testProvider("custom_stub")
    answer(1, 200, '{"choices":[{"message":{"role":"assistant","content":"pong"}}]}')
    answer(2, 200, "data: {}\n\n")
    answer(3, 200, "{}")
    answer(4, 400, '{"error":{"message":"tool_choice required is not supported"}}')
    answer(5, 200, "{}")
    TestRunner:assertEqual(reports[1].results[4].ok, false)
    TestRunner:assertEqual(reports[1].caps.tools, nil, "Record must not grant tools")
    TestRunner:assertEqual(reports[1].caps.reasoning, true)
end)

TestRunner:test("Test provider: a tap on a step's message stops the test", function()
    reset()
    local p = plugin()
    p:testProvider("custom_stub")
    answer(1, 200, '{"choices":[{"message":{"role":"assistant","content":"pong"}}]}')
    TestRunner:assertTrue(topText():find("^Testing 2/5: ") ~= nil, topText())
    tapMessage(ui:top())
    TestRunner:assertTrue(sent[2].cancelled, "the running request is stopped")
    TestRunner:assertEqual(#sent, 2, "no further step")
    TestRunner:assertEqual(#reports, 0, "and no report")
    TestRunner:assertEqual(#ui.stack, 0)
end)

TestRunner:test("Test provider: a step that cannot be built is a line of the report, never a silent stop", function()
    reset()
    local p = plugin()
    local ProviderProbe = require("koassistant.api.provider_probe")
    local real = ProviderProbe.request
    local calls = 0
    ProviderProbe.request = function(...)
        calls = calls + 1
        if calls == 2 then error("no such step") end
        return real(...)
    end
    local ok, err = pcall(function()
        p:testProvider("custom_stub")
        answer(1, 200, '{"choices":[{"message":{"role":"assistant","content":"pong"}}]}')
    end)
    ProviderProbe.request = real
    TestRunner:assertTrue(ok, "the test goes on: " .. tostring(err))
    TestRunner:assertEqual(#sent, 2, "the second step sent nothing; the third is out")
    TestRunner:assertEqual(probeOf(sent[2]), "tools")
    TestRunner:assertTrue(topText():find("^Testing 3/5: ") ~= nil, topText())
    answer(2, 200, "{}")
    answer(3, 200, "{}")
    answer(4, 200, "{}")
    local second = reports[1].results[2]
    TestRunner:assertEqual(second.ok, false)
    TestRunner:assertTrue(second.detail:find("test error", 1, true) ~= nil and second.detail:find("no such step", 1, true) ~= nil,
        second.detail)
end)

TestRunner:test("neither flow holds the loop for a request", function()
    for _idx, name in ipairs({ "startFetchModels", "testProvider" }) do
        local body = cut(name)
        TestRunner:assertTrue(body:find("fetchAsync", 1, true) ~= nil, name .. " hands its requests to the fetch off the loop")
        TestRunner:assertTrue(body:find("fetchInSubprocess", 1, true) == nil and body:find("fetchProviderModels", 1, true) == nil,
            name .. " sends none while the loop waits")
        TestRunner:assertTrue(body:find('require("koassistant.ui.waiting").message{', 1, true) ~= nil,
            name .. " waits behind the message that moves")
    end
end)

-- everything replaced goes back: one Lua process runs the whole suite
BaseHandler.fetchAsync, BaseHandler.fetchInSubprocess, BaseHandler.getApiKey = saved_async, saved_sync, saved_key
ModelOverrides._user, ModelOverrides._derived = saved_user, saved_derived
ui:restore()

return TestRunner:summary()
