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

TestRunner:test("in-flight reason wins over the rate limit (log honesty)", function()
    -- Both gates usually hold together (the limit is stamped at schedule time);
    -- the decline must report the flight, not the cooldown
    local T1 = NOW + 20000
    XrayAuto.markScheduled(T1)
    XrayAuto.beginFlight()
    local v = XrayAuto.shouldFire(baseState(), 0.40, 101, T1 + 1)
    TestRunner:assertEqual(v.reason, "in_flight", "in_flight masks rate_limited")
    XrayAuto.endFlight()
    v = XrayAuto.shouldFire(baseState(), 0.40, 101, T1 + 1)
    TestRunner:assertEqual(v.reason, "rate_limited", "cooldown reported once the flight ends")
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

-- Section-level mocks (ActionCache requires KOReader modules at load — mock first;
-- shared by all checkpoint tests below, TMP_ROOT removed before summary)
local TMP_ROOT = "/tmp/koassistant_xray_auto_test_" .. tostring(os.time()) .. "_" .. tostring(math.random(10000))
local SIDECAR_DIR = TMP_ROOT .. "/book.sdr"
os.execute(string.format("mkdir -p %q", SIDECAR_DIR))
package.loaded["koassistant_action_cache"] = nil
package.loaded["koassistant_gettext"] = nil
package.loaded["docsettings"] = nil
package.loaded["util"] = nil
package.loaded["luasettings"] = nil
require("mock_koreader")
_G.G_reader_settings = {
    _store = {},
    readSetting = function(self, key, default)
        local v = self._store[key]
        if v == nil then return default end
        return v
    end,
    saveSetting = function(self, key, value) self._store[key] = value end,
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
local DOC_PATH = TMP_ROOT .. "/book.epub"

TestRunner:test("trimCheckpoints keeps the newest N", function()
    local list = {}
    for i = 1, 8 do list[i] = { progress_decimal = i } end
    ActionCache.trimCheckpoints(list, 5)
    TestRunner:assertEqual(#list, 5, "trimmed to limit")
    TestRunner:assertEqual(list[1].progress_decimal, 1, "head (newest) kept")

    -- Real push/get round-trip: ring order, cap, and tricky-result serialization
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
end)

TestRunner:test("checkpoint metadata round-trips (incl. explicit false)", function()
    ActionCache.clearXrayCheckpoints(DOC_PATH)
    ActionCache.pushXrayCheckpoint(DOC_PATH, {
        result = '{"v": 1}',
        progress_decimal = 0.4,
        progress_page = 40,
        timestamp = 1700000001,
        used_highlights = true,
        used_annotations = false,
        used_book_text = false,
        model = "test-model",
        source_mode = "extract",
        flow_visible_pages = 123,
    })
    local ring = ActionCache.getXrayCheckpoints(DOC_PATH)
    TestRunner:assertEqual(ring[1].used_highlights, true, "used_highlights kept")
    TestRunner:assertEqual(ring[1].used_annotations, false, "explicit false kept")
    TestRunner:assertEqual(ring[1].used_book_text, false, "used_book_text false kept")
    TestRunner:assertEqual(ring[1].model, "test-model", "model kept")
    TestRunner:assertEqual(ring[1].source_mode, "extract", "source_mode kept")
    TestRunner:assertEqual(ring[1].flow_visible_pages, 123, "flow_visible_pages kept")
    ActionCache.clearXrayCheckpoints(DOC_PATH)
end)

TestRunner:test("checkpointLimitFromFeatures parity + clamps; push honors limit", function()
    TestRunner:assertEqual(ActionCache.checkpointLimitFromFeatures(nil), 5, "nil features -> schema default 5")
    TestRunner:assertEqual(ActionCache.checkpointLimitFromFeatures({}),
        ActionCache.XRAY_CHECKPOINT_LIMIT, "fallback equals module constant")
    TestRunner:assertEqual(ActionCache.checkpointLimitFromFeatures({ xray_versions_kept = 2 }), 2, "custom value")
    TestRunner:assertEqual(ActionCache.checkpointLimitFromFeatures({ xray_versions_kept = 0 }), 0, "zero allowed")
    TestRunner:assertEqual(ActionCache.checkpointLimitFromFeatures({ xray_versions_kept = -3 }), 0, "negative clamps to 0")
    TestRunner:assertEqual(ActionCache.checkpointLimitFromFeatures({ xray_versions_kept = 99 }), 20, "upper clamp")

    ActionCache.clearXrayCheckpoints(DOC_PATH)
    for i = 1, 4 do
        ActionCache.pushXrayCheckpoint(DOC_PATH, {
            result = '{"n": ' .. i .. '}', progress_decimal = i / 10, timestamp = 1700000000 + i,
        }, 2)
    end
    TestRunner:assertEqual(#ActionCache.getXrayCheckpoints(DOC_PATH), 2, "ring capped at custom limit")
    TestRunner:assertEqual(ActionCache.pushXrayCheckpoint(DOC_PATH, {
        result = '{"n": 5}', progress_decimal = 0.5, timestamp = 1700000005,
    }, 0), false, "limit 0 = no archiving")
    TestRunner:assertEqual(#ActionCache.getXrayCheckpoints(DOC_PATH), 2, "ring untouched at limit 0")
    ActionCache.clearXrayCheckpoints(DOC_PATH)
end)

TestRunner:test("getXrayCheckpointCount: header fast-path + pre-header fallback", function()
    ActionCache.clearXrayCheckpoints(DOC_PATH)
    for i = 1, 3 do
        ActionCache.pushXrayCheckpoint(DOC_PATH, {
            result = '{"n": ' .. i .. '}', progress_decimal = i / 10, timestamp = 1700000000 + i,
        })
    end
    TestRunner:assertEqual(ActionCache.getXrayCheckpointCount(DOC_PATH), 3, "header count")
    -- Simulate a v1 (pre-header) ring file: strip the first line
    local path = ActionCache.getXrayCheckpointsPath(DOC_PATH)
    local f = io.open(path, "r")
    local content = f:read("*a")
    f:close()
    content = content:gsub("^%-%- count: %d+\n", "")
    f = io.open(path, "w")
    f:write(content)
    f:close()
    TestRunner:assertEqual(ActionCache.getXrayCheckpointCount(DOC_PATH), 3, "pre-header fallback parses")
    ActionCache.clearXrayCheckpoints(DOC_PATH)
    TestRunner:assertEqual(ActionCache.getXrayCheckpointCount(DOC_PATH), 0, "cleared -> 0")
end)

TestRunner:test("nearestCheckpointIndex: at-or-below, tolerance, ties, complete excluded", function()
    local ring = {
        { progress_decimal = 0.60 },              -- newest
        { progress_decimal = 0.45 },
        { progress_decimal = 0.30 },
        { progress_decimal = 1.0, full_document = true },
        { progress_decimal = 0.10 },              -- oldest
    }
    TestRunner:assertEqual(ActionCache.nearestCheckpointIndex(ring, 0.50), 2, "0.45 nearest below 0.50")
    TestRunner:assertEqual(ActionCache.nearestCheckpointIndex(ring, 0.35), 3, "0.30 nearest below 0.35")
    TestRunner:assertEqual(ActionCache.nearestCheckpointIndex(ring, 0.05), nil, "all ahead -> nil")
    -- Half-percent tolerance: a 0.598 reader matches the 0.60 version
    TestRunner:assertEqual(ActionCache.nearestCheckpointIndex(ring, 0.598), 1, "tolerance catches near-equal")
    -- Complete versions never qualify (whole-book spoilers), even past everything else
    TestRunner:assertEqual(ActionCache.nearestCheckpointIndex(
        { { progress_decimal = 1.0, full_document = true } }, 0.99), nil, "complete excluded")
    -- Tie: two entries at the same progress -> newest (lowest index)
    TestRunner:assertEqual(ActionCache.nearestCheckpointIndex(
        { { progress_decimal = 0.30 }, { progress_decimal = 0.30 } }, 0.40), 1, "tie -> newest")
end)

TestRunner:test("removeXrayCheckpoint removes by index; bad index refused", function()
    ActionCache.clearXrayCheckpoints(DOC_PATH)
    for i = 1, 3 do
        ActionCache.pushXrayCheckpoint(DOC_PATH, {
            result = '{"n": ' .. i .. '}', progress_decimal = i / 10, timestamp = 1700000000 + i,
        })
    end
    -- ring is newest-first: [3, 2, 1]; remove the middle (n=2)
    TestRunner:assertEqual(ActionCache.removeXrayCheckpoint(DOC_PATH, 2), true, "remove succeeds")
    local ring = ActionCache.getXrayCheckpoints(DOC_PATH)
    TestRunner:assertEqual(#ring, 2, "one removed")
    TestRunner:assertEqual(ring[1].progress_decimal, 0.3, "head intact")
    TestRunner:assertEqual(ring[2].progress_decimal, 0.1, "tail intact")
    TestRunner:assertEqual(ActionCache.removeXrayCheckpoint(DOC_PATH, 9), false, "bad index refused")
    ActionCache.removeXrayCheckpoint(DOC_PATH, 1)
    ActionCache.removeXrayCheckpoint(DOC_PATH, 1)
    TestRunner:assertEqual(#ActionCache.getXrayCheckpoints(DOC_PATH), 0, "ring empty after removing all")
end)

TestRunner:test("restoreXrayCheckpoint swaps live and archived versions (move semantics)", function()
    ActionCache.clearXrayCheckpoints(DOC_PATH)
    -- Live cache = B (current, both keys); archived = A (older, own metadata)
    local b_meta = { model = "model-B", used_book_text = true, used_highlights = true, progress_page = 50 }
    ActionCache.setXrayCache(DOC_PATH, '{"live": "B"}', 0.5, b_meta)
    ActionCache.set(DOC_PATH, "xray", '{"live": "B"}', 0.5, b_meta)
    ActionCache.pushXrayCheckpoint(DOC_PATH, {
        result = '{"old": "A"}', progress_decimal = 0.3, progress_page = 30,
        timestamp = 1700000100, used_book_text = false, used_highlights = false, model = "model-A",
    })

    local ok = ActionCache.restoreXrayCheckpoint(DOC_PATH, 1)
    TestRunner:assertEqual(ok, true, "restore succeeds")

    local live = ActionCache.getXrayCache(DOC_PATH)
    TestRunner:assertEqual(live.result, '{"old": "A"}', "A is live")
    TestRunner:assertEqual(live.progress_decimal, 0.3, "progress restored")
    TestRunner:assertEqual(live.timestamp, 1700000100, "original generation time preserved")
    TestRunner:assertEqual(live.used_book_text, false, "archived flag wins over outgoing entry's")
    TestRunner:assertEqual(live.model, "model-A", "archived model wins")
    local per_action = ActionCache.get(DOC_PATH, "xray")
    TestRunner:assertEqual(per_action and per_action.result, '{"old": "A"}', "per-action key updated too")

    local ring = ActionCache.getXrayCheckpoints(DOC_PATH)
    TestRunner:assertEqual(#ring, 1, "ring did not grow")
    TestRunner:assertEqual(ring[1].result, '{"live": "B"}', "outgoing live took the slot")
    TestRunner:assertEqual(ring[1].progress_decimal, 0.5, "with its progress")
end)

TestRunner:test("restore: pre-metadata checkpoint inherits the outgoing entry's flags", function()
    ActionCache.clearXrayCheckpoints(DOC_PATH)
    ActionCache.setXrayCache(DOC_PATH, '{"live": "C"}', 0.6,
        { model = "model-C", used_book_text = true, used_highlights = true })
    -- Pre-metadata checkpoint: only the v1 archive fields
    ActionCache.pushXrayCheckpoint(DOC_PATH, {
        result = '{"old": "legacy"}', progress_decimal = 0.2, timestamp = 1700000200,
    })
    local ok = ActionCache.restoreXrayCheckpoint(DOC_PATH, 1)
    TestRunner:assertEqual(ok, true, "restore succeeds")
    local live = ActionCache.getXrayCache(DOC_PATH)
    TestRunner:assertEqual(live.used_book_text, true, "falls back to outgoing flags (sticky-true superset)")
    TestRunner:assertEqual(live.used_highlights, true, "fallback used_highlights")
    TestRunner:assertEqual(live.model, "model-C", "fallback model")
end)

print("")
print("  [auto-create window]")

TestRunner:test("create mode: cached_progress 0 fires only inside the gap window", function()
    -- Auto-create rides the normal gates with cached_progress = 0 (§5 decision 1):
    -- min_gap = too early, max_gap = too far into the book (stays manual)
    local FAR = NOW + 100000  -- past every rate-limit stamp earlier tests left behind
    local s = baseState({ cached_progress = 0 })
    TestRunner:assertEqual(XrayAuto.shouldFire(s, 0.04, 101, FAR).reason, "below_threshold",
        "before min gap: too early")
    TestRunner:assertEqual(XrayAuto.shouldFire(s, 0.10, 101, FAR).fire, true,
        "early-book window fires")
    TestRunner:assertEqual(XrayAuto.shouldFire(s, 0.30, 101, FAR).reason, "above_cap",
        "past max gap: first X-Ray stays manual")
end)

os.execute(string.format("rm -rf %q", TMP_ROOT))

local ok = TestRunner:summary()
return ok
