--[[
Unit tests: X-Ray background auto-update gate module (koassistant_xray_auto.lua)
+ the checkpoint ring (trim logic pure; push/get as a real disk round-trip).

Gate matrix per docs/xray_background_plan.md §3: opt-in, eligibility, threshold,
cap, jump guard, rate limit (stamped at schedule time), in-flight exclusion.

Run: lua tests/unit/test_xray_auto.lua  (auto-discovered by run_tests.lua --unit)
]]

-- Setup test environment
local function setupPaths()
    local info = debug.getinfo(1, "S")
    local script_path = info.source:match("@?(.*)")
    local unit_dir = script_path:match("(.+)/[^/]+$") or "."
    local tests_dir = unit_dir:match("(.+)/[^/]+$") or "."
    local plugin_dir = tests_dir:match("(.+)/[^/]+$") or "."

    package.path = table.concat({
        plugin_dir .. "/?.lua",
        plugin_dir .. "/?/init.lua",
        tests_dir .. "/?.lua",
        tests_dir .. "/lib/?.lua",
        package.path,
    }, ";")
end
setupPaths()

-- Fresh module (module-level state must start clean)
package.loaded["koassistant_xray_auto"] = nil
local XrayAuto = require("koassistant_xray_auto")
local TestRunner = require("test_runner"):new()

print("Running: test_xray_auto")
print("")
print("  [shouldFire gate matrix]")

local NOW = 1000000
local function baseState(overrides)
    local s = { auto_update = true, eligible = true, cached_progress = 0.30, prev_page = 100 }
    for k, v in pairs(overrides or {}) do s[k] = v end
    return s
end

TestRunner:test("fires when all gates pass", function()
    local v = XrayAuto.shouldFire(baseState(), 0.40, 101, NOW)
    TestRunner:assertEqual(v.fire, true, "should fire")
end)

TestRunner:test("nil state / not opted in blocks", function()
    TestRunner:assertEqual(XrayAuto.shouldFire(nil, 0.40, 101, NOW).fire, false, "nil state")
    local v = XrayAuto.shouldFire(baseState({ auto_update = false }), 0.40, 101, NOW)
    TestRunner:assertEqual(v.reason, "not_opted_in", "opt-in gate")
end)

TestRunner:test("ineligible cache blocks", function()
    local v = XrayAuto.shouldFire(baseState({ eligible = false }), 0.40, 101, NOW)
    TestRunner:assertEqual(v.reason, "not_eligible", "eligibility gate")
end)

TestRunner:test("missing progress numbers block", function()
    -- (nil can't ride through the overrides table — build the state explicitly)
    local v = XrayAuto.shouldFire({ auto_update = true, eligible = true, prev_page = 100 }, 0.40, 101, NOW)
    TestRunner:assertEqual(v.reason, "no_progress", "cached progress required")
    v = XrayAuto.shouldFire(baseState(), nil, 101, NOW)
    TestRunner:assertEqual(v.reason, "no_progress", "current progress required")
end)

TestRunner:test("delta at/below threshold blocks; just above fires", function()
    local v = XrayAuto.shouldFire(baseState(), 0.30 + XrayAuto.THRESHOLD, 101, NOW)
    TestRunner:assertEqual(v.reason, "below_threshold", "delta == threshold must not fire")
    v = XrayAuto.shouldFire(baseState(), 0.30 + XrayAuto.THRESHOLD + 0.001, 101, NOW)
    TestRunner:assertEqual(v.fire, true, "delta just above threshold fires")
end)

TestRunner:test("delta above cap blocks (offline-day gaps stay manual)", function()
    local v = XrayAuto.shouldFire(baseState(), 0.30 + XrayAuto.MAX_DELTA + 0.01, 101, NOW)
    TestRunner:assertEqual(v.reason, "above_cap", "cap gate")
    -- Exactly-at-cap uses binary-exact values (0.50 - 0.25 == 0.25) to dodge float noise
    local at_cap = baseState({ cached_progress = 0.25 })
    v = XrayAuto.shouldFire(at_cap, 0.25 + XrayAuto.MAX_DELTA, 101, NOW)
    TestRunner:assertEqual(v.fire, true, "delta == cap still fires (inclusive)")
end)

TestRunner:test("jump guard: no prev_page or big hop blocks", function()
    -- (nil can't ride through the overrides table — build the state explicitly)
    local v = XrayAuto.shouldFire(
        { auto_update = true, eligible = true, cached_progress = 0.30 }, 0.40, 101, NOW)
    TestRunner:assertEqual(v.reason, "page_jump", "first turn after open must not fire")
    v = XrayAuto.shouldFire(baseState({ prev_page = 90 }), 0.40, 101, NOW)
    TestRunner:assertEqual(v.reason, "page_jump", "11-page hop is a jump")
    v = XrayAuto.shouldFire(baseState({ prev_page = 96 }), 0.40, 101, NOW)
    TestRunner:assertEqual(v.fire, true, "5-page hop is sequential reading")
end)

TestRunner:test("rate limit stamped at schedule time binds and expires", function()
    XrayAuto.markScheduled(NOW)
    local v = XrayAuto.shouldFire(baseState(), 0.40, 101, NOW + 60)
    TestRunner:assertEqual(v.reason, "rate_limited", "within the window")
    v = XrayAuto.shouldFire(baseState(), 0.40, 101, NOW + XrayAuto.RATE_LIMIT_S)
    TestRunner:assertEqual(v.fire, true, "window elapsed")
end)

TestRunner:test("in-flight blocks; endFlight releases", function()
    XrayAuto.beginFlight()
    local v = XrayAuto.shouldFire(baseState(), 0.40, 101, NOW + XrayAuto.RATE_LIMIT_S)
    TestRunner:assertEqual(v.reason, "in_flight", "in-flight gate")
    XrayAuto.endFlight()
    v = XrayAuto.shouldFire(baseState(), 0.40, 101, NOW + XrayAuto.RATE_LIMIT_S)
    TestRunner:assertEqual(v.fire, true, "released")
end)

print("")
print("  [user dials (§10)]")

TestRunner:test("dialsFromFeatures: defaults match module constants", function()
    local d = XrayAuto.dialsFromFeatures(nil)
    TestRunner:assertEqual(d.min_gap, XrayAuto.THRESHOLD, "default min gap")
    TestRunner:assertEqual(d.max_gap, XrayAuto.MAX_DELTA, "default max gap")
    TestRunner:assertEqual(d.cooldown_s, XrayAuto.RATE_LIMIT_S, "default cooldown")
end)

TestRunner:test("dialsFromFeatures: custom values convert; inverted window clamps", function()
    local d = XrayAuto.dialsFromFeatures({
        xray_auto_min_gap = 10, xray_auto_max_gap = 40, xray_auto_cooldown = 5 })
    TestRunner:assertEqual(d.min_gap, 0.10, "percent to decimal")
    TestRunner:assertEqual(d.max_gap, 0.40, "percent to decimal")
    TestRunner:assertEqual(d.cooldown_s, 300, "minutes to seconds")
    d = XrayAuto.dialsFromFeatures({ xray_auto_min_gap = 20, xray_auto_max_gap = 10 })
    TestRunner:assertEqual(d.max_gap, d.min_gap, "inverted window clamps to min")
end)

TestRunner:test("shouldFire honors state gap overrides", function()
    local past_limit = NOW + XrayAuto.RATE_LIMIT_S  -- earlier markScheduled(NOW) still stands
    local v = XrayAuto.shouldFire(baseState({ min_gap = 0.10 }), 0.38, 101, past_limit)
    TestRunner:assertEqual(v.reason, "below_threshold", "raised min gap blocks a default-firing delta")
    v = XrayAuto.shouldFire(baseState({ min_gap = 0.10 }), 0.45, 101, past_limit)
    TestRunner:assertEqual(v.fire, true, "fires past the raised min gap")
    v = XrayAuto.shouldFire(baseState({ max_gap = 0.50 }), 0.70, 101, past_limit)
    TestRunner:assertEqual(v.fire, true, "raised max gap allows a default-blocked delta")
end)

TestRunner:test("shouldFire honors state cooldown override (0 = none)", function()
    local T0 = NOW + 10000
    XrayAuto.markScheduled(T0)
    local v = XrayAuto.shouldFire(baseState({ cooldown_s = 60 }), 0.40, 101, T0 + 30)
    TestRunner:assertEqual(v.reason, "rate_limited", "inside the shortened window")
    v = XrayAuto.shouldFire(baseState({ cooldown_s = 60 }), 0.40, 101, T0 + 61)
    TestRunner:assertEqual(v.fire, true, "past the shortened window")
    v = XrayAuto.shouldFire(baseState({ cooldown_s = 0 }), 0.40, 101, T0 + 1)
    TestRunner:assertEqual(v.fire, true, "zero cooldown never rate-limits")
end)

print("")
print("  [session state helpers]")

TestRunner:test("cancelInFlight calls the handle once and clears state", function()
    local calls = 0
    XrayAuto.beginFlight()
    XrayAuto.registerCancel(function() calls = calls + 1 end)
    XrayAuto.cancelInFlight()
    XrayAuto.cancelInFlight()
    TestRunner:assertEqual(calls, 1, "cancel handle fires once")
    TestRunner:assertEqual(XrayAuto.isInFlight(), false, "flight cleared")
end)

TestRunner:test("outcome flags: idle close doesn't poison; cancel/discard consumed once", function()
    XrayAuto.consumeOutcomeFlags()  -- drain state left by the previous test's cancel
    -- Idle close (no flight, no handle) must NOT mark cancelled
    XrayAuto.cancelInFlight()
    local c, d = XrayAuto.consumeOutcomeFlags()
    TestRunner:assertEqual(c, false, "idle close is not a cancellation")
    TestRunner:assertEqual(d, false, "nothing discarded")
    -- A real in-flight cancel marks cancelled, consumed exactly once
    XrayAuto.beginFlight()
    XrayAuto.cancelInFlight()
    c, d = XrayAuto.consumeOutcomeFlags()
    TestRunner:assertEqual(c, true, "in-flight cancel recorded")
    c, d = XrayAuto.consumeOutcomeFlags()
    TestRunner:assertEqual(c, false, "consumed once")
    -- Guard discard marks discarded, consumed exactly once
    XrayAuto.markDiscarded()
    c, d = XrayAuto.consumeOutcomeFlags()
    TestRunner:assertEqual(d, true, "discard recorded")
    c, d = XrayAuto.consumeOutcomeFlags()
    TestRunner:assertEqual(d, false, "consumed once")
end)

TestRunner:test("failure trace is per-file and cleared by success", function()
    XrayAuto.recordFailure("/books/a.epub", "boom")
    TestRunner:assertEqual(XrayAuto.lastFailure("/books/a.epub"), "boom", "recorded")
    TestRunner:assertEqual(XrayAuto.lastFailure("/books/b.epub"), nil, "other file unaffected")
    XrayAuto.recordSuccess("/books/a.epub")
    TestRunner:assertEqual(XrayAuto.lastFailure("/books/a.epub"), nil, "success clears failure")
end)

print("")
print("  [eligibilityFromEntry]")

local function isJSON(s) return s:sub(1, 1) == "{" end

TestRunner:test("eligible incremental JSON entry", function()
    local ok, p = XrayAuto.eligibilityFromEntry(
        { result = "{}", progress_decimal = 0.4 }, isJSON)
    TestRunner:assertEqual(ok, true, "eligible")
    TestRunner:assertEqual(p, 0.4, "cached progress returned")
end)

TestRunner:test("ineligible entries: missing, complete-track, ai_knowledge, legacy, done", function()
    TestRunner:assertEqual(XrayAuto.eligibilityFromEntry(nil, isJSON), false, "missing entry")
    TestRunner:assertEqual(XrayAuto.eligibilityFromEntry(
        { result = "{}", progress_decimal = 0.4, full_document = true }, isJSON), false, "complete track")
    TestRunner:assertEqual(XrayAuto.eligibilityFromEntry(
        { result = "{}", progress_decimal = 0.4, source_mode = "ai_knowledge" }, isJSON), false, "ai_knowledge")
    TestRunner:assertEqual(XrayAuto.eligibilityFromEntry(
        { result = "# markdown", progress_decimal = 0.4 }, isJSON), false, "legacy markdown")
    TestRunner:assertEqual(XrayAuto.eligibilityFromEntry(
        { result = "{}", progress_decimal = 1.0 }, isJSON), false, "already at 100%")
end)

print("")
print("  [checkpoint ring]")

TestRunner:test("trimCheckpoints keeps the newest N", function()
    package.loaded["koassistant_action_cache"] = nil
    -- trim is pure; load the module with the parity-style mocks below installed lazily
    -- (ActionCache requires KOReader modules at load — mock first)
    local TMP_ROOT = "/tmp/koassistant_xray_auto_test_" .. tostring(os.time()) .. "_" .. tostring(math.random(10000))
    local SIDECAR_DIR = TMP_ROOT .. "/book.sdr"
    os.execute(string.format("mkdir -p %q", SIDECAR_DIR))
    package.loaded["koassistant_gettext"] = nil
    package.loaded["docsettings"] = nil
    package.loaded["util"] = nil
    package.loaded["luasettings"] = nil
    require("mock_koreader")
    _G.G_reader_settings = _G.G_reader_settings or {
        readSetting = function() return nil end,
        saveSetting = function() end,
        flush = function() end,
    }
    package.loaded["docsettings"] = {
        getSidecarDir = function(_self, _doc_path, _force) return SIDECAR_DIR end,
        isHashLocationEnabled = function() return false end,
    }
    package.loaded["util"] = {
        makePath = function(dir) os.execute(string.format("mkdir -p %q", dir)) end,
    }
    package.loaded["luasettings"] = {
        open = function() return { readSetting = function() return nil end, close = function() end } end,
    }
    local ActionCache = require("koassistant_action_cache")

    local list = {}
    for i = 1, 8 do list[i] = { progress_decimal = i } end
    ActionCache.trimCheckpoints(list, 5)
    TestRunner:assertEqual(#list, 5, "trimmed to limit")
    TestRunner:assertEqual(list[1].progress_decimal, 1, "head (newest) kept")

    -- Real push/get round-trip: ring order, cap, and tricky-result serialization
    local DOC_PATH = TMP_ROOT .. "/book.epub"
    for i = 1, 7 do
        local ok = ActionCache.pushXrayCheckpoint(DOC_PATH, {
            result = '{"n": ' .. i .. ', "s": "with \\"quotes\\" and ]] closer"}',
            progress_decimal = i / 10,
            progress_page = i * 10,
            timestamp = 1700000000 + i,
        })
        TestRunner:assertEqual(ok, true, "push " .. i .. " succeeds")
    end
    local ring = ActionCache.getXrayCheckpoints(DOC_PATH)
    TestRunner:assertEqual(#ring, ActionCache.XRAY_CHECKPOINT_LIMIT, "ring capped")
    TestRunner:assertEqual(ring[1].progress_decimal, 0.7, "newest first")
    TestRunner:assertEqual(ring[#ring].progress_decimal, 0.3, "oldest surviving = push 3")
    TestRunner:assertEqual(ring[1].result, '{"n": 7, "s": "with \\"quotes\\" and ]] closer"}',
        "result round-trips losslessly")
    TestRunner:assertEqual(ring[1].progress_page, 70, "progress_page kept")
    TestRunner:assertEqual(ring[1].timestamp, 1700000007, "original timestamp kept")
    assert(type(ring[1].archived_at) == "number", "archived_at stamped")

    ActionCache.clearXrayCheckpoints(DOC_PATH)
    TestRunner:assertEqual(#ActionCache.getXrayCheckpoints(DOC_PATH), 0, "clear removes the ring")

    os.execute(string.format("rm -rf %q", TMP_ROOT))
end)

local ok = TestRunner:summary()
return ok
