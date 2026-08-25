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
print("  [round 21: unified-engine scheduler pieces]")
-- (The shouldFire threshold/cap gate matrix was retired with the to-position
-- auto-update path — the scheduler's rule is now the one-ahead invariant,
-- checked in main.lua against state; cooldown + truncation are the pure bits.)

local NOW = 1000000

TestRunner:test("cooldownElapsed: stamped at schedule time, binds and expires", function()
    TestRunner:assertEqual(XrayAuto.cooldownElapsed(60, NOW), true, "never scheduled: allowed")
    XrayAuto.markScheduled(NOW)
    TestRunner:assertEqual(XrayAuto.cooldownElapsed(60, NOW + 30), false, "inside the window")
    TestRunner:assertEqual(XrayAuto.cooldownElapsed(60, NOW + 60), true, "window elapsed")
    TestRunner:assertEqual(XrayAuto.cooldownElapsed(0, NOW + 1), true, "zero cooldown never limits")
    TestRunner:assertEqual(XrayAuto.cooldownElapsed(nil, NOW + XrayAuto.RATE_LIMIT_S), true,
        "nil cooldown falls back to the module default")
end)

TestRunner:test("truncateToOneAhead: grid prefix ending one past the reader", function()
    local rungs = { 0.15, 0.3, 0.45, 0.6, 1.0 }
    local labels = { nil, "Ch 2", nil, "Ch 4" }
    local out, out_labels = XrayAuto.truncateToOneAhead(rungs, 0.32, labels)
    TestRunner:assertEqual(#out, 3, "everything to position plus ONE ahead")
    TestRunner:assertEqual(out[3], 0.45, "the one-ahead target")
    TestRunner:assertEqual(out_labels[2], "Ch 2", "labels ride with their rungs")
    out = XrayAuto.truncateToOneAhead(rungs, 0.0)
    TestRunner:assertEqual(#out, 1, "at the start: just the first target")
    out = XrayAuto.truncateToOneAhead(rungs, 0.99)
    TestRunner:assertEqual(#out, 5, "deep position: the whole grid (1.0 is the one ahead)")
    TestRunner:assertEqual(#XrayAuto.truncateToOneAhead({}, 0.5), 0, "empty grid stays empty")
end)

print("")
print("  [user dials (§10; gap dials retired round 21 — stored values still parse)]")

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

TestRunner:test("flight file scopes the display (watchdog retired 2026-08-05)", function()
    XrayAuto.consumeOutcomeFlags()
    XrayAuto.beginFlight("/books/a.epub")
    TestRunner:assertEqual(XrayAuto.inFlightFile(), "/books/a.epub", "flight carries its file")
    XrayAuto.cancelInFlight()
    local c = XrayAuto.consumeOutcomeFlags()
    TestRunner:assertEqual(c, true, "in-flight cancel recorded")
    TestRunner:assertEqual(XrayAuto.inFlightFile(), nil, "flight file cleared on cancel")
    -- endFlight clears the file too
    XrayAuto.beginFlight("/books/c.epub")
    XrayAuto.endFlight()
    TestRunner:assertEqual(XrayAuto.inFlightFile(), nil, "flight file cleared on end")
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

TestRunner:test("trimCheckpoints evicts the least coverage, not the oldest", function()
    -- Newest first. The tail-truncating version kept 0.10 and dropped 0.95.
    local list = {
        { progress_decimal = 0.10 }, { progress_decimal = 0.20 },
        { progress_decimal = 0.30 }, { progress_decimal = 0.40 },
        { progress_decimal = 0.50 }, { progress_decimal = 0.60 },
        { progress_decimal = 0.95 }, { progress_decimal = 0.05 },
    }
    ActionCache.trimCheckpoints(list, 5)
    TestRunner:assertEqual(#list, 5, "trimmed to limit")
    TestRunner:assertEqual(list[1].progress_decimal, 0.30, "0.10 and 0.20 evicted as the thinnest")
    TestRunner:assertEqual(list[#list].progress_decimal, 0.95, "the near-complete version survives")

    -- Order among survivors is untouched (display + restore indexes rely on it)
    local prev = 0
    for i = 2, #list do
        TestRunner:assertEqual(list[i].progress_decimal > list[i - 1].progress_decimal, true,
            "survivors keep their original relative order")
        prev = i
    end
    TestRunner:assertEqual(prev, #list, "walked every survivor")

    -- A whole-document build counts as complete even without a 1.0 stamp
    local full = {
        { progress_decimal = 0.90 }, { progress_decimal = 0.90 },
        { progress_decimal = 0.90 }, { progress_decimal = 0.90 },
        { progress_decimal = 0.90 }, { progress_decimal = 0.40, full_document = true },
    }
    ActionCache.trimCheckpoints(full, 5)
    TestRunner:assertEqual(full[#full].full_document, true, "full_document outranks a higher stamp")

    -- Equal coverage falls back to age: the oldest goes
    local tied = {}
    for i = 1, 7 do tied[i] = { progress_decimal = 0.5, tag = i } end
    ActionCache.trimCheckpoints(tied, 5)
    TestRunner:assertEqual(tied[1].tag, 1, "newest of the tied kept")
    TestRunner:assertEqual(tied[#tied].tag, 5, "the two oldest tied entries evicted")

    -- Under the limit nothing moves
    local small = { { progress_decimal = 0.1 }, { progress_decimal = 0.9 } }
    ActionCache.trimCheckpoints(small, 5)
    TestRunner:assertEqual(#small, 2, "no eviction below the limit")
    TestRunner:assertEqual(small[1].progress_decimal, 0.1, "order untouched below the limit")

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
print("  [version ladder]")

TestRunner:test("planLadderRungs: spacing multiples above base, final 1.0, float-clean", function()
    local from_zero = XrayAuto.planLadderRungs(0)
    TestRunner:assertEqual(#from_zero, 10, "from nothing: 10 rungs")
    TestRunner:assertEqual(from_zero[1], 0.1, "first rung 10%")
    TestRunner:assertEqual(from_zero[3], 0.3, "no float drift (0.3 exact)")
    TestRunner:assertEqual(from_zero[10], 1.0, "final rung 100%")

    -- First rung must be at least HALF a step ahead of the base: a 48% X-Ray
    -- must NOT get a 50% rung (near-duplicate for a full call's price)
    local near = XrayAuto.planLadderRungs(0.48)
    TestRunner:assertEqual(near[1], 0.6, "48% base skips the 50% near-duplicate")
    TestRunner:assertEqual(#near, 5, "48% base: 5 rungs (60..90 + 100)")
    TestRunner:assertEqual(XrayAuto.planLadderRungs(0.45)[1], 0.5, "exactly half a step qualifies")

    local mid = XrayAuto.planLadderRungs(0.37)
    TestRunner:assertEqual(#mid, 6, "base 37%: 6 rungs (50..90 + 100 — 40% is under half a step)")
    TestRunner:assertEqual(mid[1], 0.5, "first rung at least half a step above base")
    TestRunner:assertEqual(mid[6], 1.0, "ends at 100%")

    -- Base ON a rung boundary starts at the NEXT one
    TestRunner:assertEqual(XrayAuto.planLadderRungs(0.4)[1], 0.5, "boundary base skips its own rung")
    -- Near-boundary float (0.4 stored as 0.39999...) treated as the boundary
    TestRunner:assertEqual(XrayAuto.planLadderRungs(0.399)[1], 0.5, "tolerance absorbs float drift")

    local tail = XrayAuto.planLadderRungs(0.95)
    TestRunner:assertEqual(#tail, 1, "near the end: just the final rung")
    TestRunner:assertEqual(tail[1], 1.0, "which is 100%")
    TestRunner:assertEqual(#XrayAuto.planLadderRungs(1.0), 0, "complete base: nothing to build")
    TestRunner:assertEqual(#XrayAuto.planLadderRungs(0.995), 0,
        "within 1% of the end: update path can't engage, nothing to build")
end)

TestRunner:test("ladderSpacingFor: 10% baseline, min-pages floor, tiny-book clamp", function()
    TestRunner:assertEqual(XrayAuto.ladderSpacingFor(nil), 0.1, "no page count: baseline")
    TestRunner:assertEqual(XrayAuto.ladderSpacingFor(0), 0.1, "zero pages: baseline")
    TestRunner:assertEqual(XrayAuto.ladderSpacingFor(600), 0.1, "long book: baseline 10%")
    TestRunner:assertEqual(XrayAuto.ladderSpacingFor(450), 0.1, "450 pages: floor lands exactly on baseline")
    TestRunner:assertEqual(XrayAuto.ladderSpacingFor(300), 0.15, "300 pages: 45-page floor -> 15%")
    TestRunner:assertEqual(XrayAuto.ladderSpacingFor(200), 0.23, "200 pages: 45-page floor -> 23%")
    TestRunner:assertEqual(XrayAuto.ladderSpacingFor(100), 0.45, "novella: 45%")
    TestRunner:assertEqual(XrayAuto.ladderSpacingFor(40), 0.5, "tiny book clamps at 50%")
    TestRunner:assertEqual(XrayAuto.ladderSpacingFor(220), 0.2,
        "whole-percent rounding (45/220 -> 20.45 -> 20%)")
    local novella = XrayAuto.planLadderRungs(0, XrayAuto.ladderSpacingFor(100))
    TestRunner:assertEqual(#novella, 2, "novella ladder normalizes 45% -> 50/100 (no 90+100 sliver)")
    TestRunner:assertEqual(novella[1], 0.5, "even grid: first rung at 50%")
end)

TestRunner:test("normalizedSpacing + even grids (device 2026-08-05: 12%/24% grids ended 96+100)", function()
    TestRunner:assertEqual(XrayAuto.normalizedSpacing(0.12, nil), 0.125, "12% -> 12.5% (8 even steps)")
    TestRunner:assertEqual(XrayAuto.normalizedSpacing(0.24, nil), 0.25, "24% -> 25% (4 even steps)")
    TestRunner:assertEqual(XrayAuto.normalizedSpacing(0.1, nil), 0.1, "even divisors unchanged")
    TestRunner:assertEqual(XrayAuto.normalizedSpacing(0.12, 0.6), 0.12, "target builds normalize over the goal span")
    local twelve = XrayAuto.planLadderRungs(0, 0.12)
    TestRunner:assertEqual(#twelve, 8, "12% grid: 8 rungs, one fewer than the sliver plan")
    TestRunner:assertEqual(twelve[7], 0.875, "last regular rung a full step below the end")
    TestRunner:assertEqual(twelve[8], 1.0, "lands exactly on 100%")
    local tf = XrayAuto.planLadderRungs(0, 0.24)
    TestRunner:assertEqual(#tf, 4, "24% -> 4 even steps")
    TestRunner:assertEqual(tf[1], 0.25, "25")
    TestRunner:assertEqual(tf[2], 0.5, "50")
    TestRunner:assertEqual(tf[3], 0.75, "75")
    TestRunner:assertEqual(tf[4], 1.0, "100")
    -- Extends keep the grid anchored at 0 with the same normalized step
    local ext = XrayAuto.planLadderRungs(0.5, 0.24)
    TestRunner:assertEqual(#ext, 2, "base 50% continues the 25% grid")
    TestRunner:assertEqual(ext[1], 0.75, "next grid point above the base")
    TestRunner:assertEqual(ext[2], 1.0, "ends at 100%")
    -- Seed rule follows the NORMALIZED step: reader between nominal (45%) and
    -- normalized (50%) first rung still gets a seed (D1: promotable point)
    TestRunner:assertEqual(XrayAuto.seedForBuild(0, 0.47, nil, 0.45), 0.47,
        "seed granted below the normalized first rung")
    TestRunner:assertEqual(XrayAuto.seedForBuild(0, 0.52, nil, 0.45), nil,
        "at/past the normalized first rung: the grid point serves")
end)

TestRunner:test("planLadderRungs: target_end bounds the build", function()
    local rungs = XrayAuto.planLadderRungs(0, 0.1, 0.6)
    TestRunner:assertEqual(#rungs, 6, "0->60% at 10%: 6 rungs")
    TestRunner:assertEqual(rungs[#rungs], 0.6, "final rung = the target, not 1.0")
    local mid = XrayAuto.planLadderRungs(0.3, 0.1, 0.6)
    TestRunner:assertEqual(#mid, 3, "30->60% at 10%: 3 rungs")
    TestRunner:assertEqual(mid[1], 0.4, "first rung past the base")
    TestRunner:assertEqual(#XrayAuto.planLadderRungs(0.59, 0.1, 0.6), 0,
        "base within 1% of target: nothing to build")
    TestRunner:assertEqual(XrayAuto.planLadderRungs(0, 0.1, nil)[10], 1.0,
        "nil target keeps the 1.0 behavior")
    TestRunner:assertEqual(XrayAuto.planLadderRungs(0, 0.1, 1.5)[10], 1.0,
        "invalid target clamps to 1.0")
end)

TestRunner:test("seedForBuild: from-nothing builds seed the reader's position (round 19)", function()
    TestRunner:assertEqual(XrayAuto.seedForBuild(0, 0.05, nil), 0.05,
        "reader below the first spacing rung gets a seed at the position")
    TestRunner:assertEqual(XrayAuto.seedForBuild(nil, 0.123, 1.0, 0.15), 0.123,
        "nil base is from-nothing; seed rounded to 3 decimals")
    TestRunner:assertEqual(XrayAuto.seedForBuild(0.3, 0.35, nil), nil,
        "an existing base means something is already promotable: no seed")
    TestRunner:assertEqual(XrayAuto.seedForBuild(0, 0.02, nil), nil,
        "below LADDER_SEED_MIN the seed is noise")
    TestRunner:assertEqual(XrayAuto.seedForBuild(0, nil, nil), nil,
        "no position, no seed")
    TestRunner:assertEqual(XrayAuto.seedForBuild(0, 0.595, 0.6, 0.7), nil,
        "position within 1% of the goal: the goal rung IS the seed")
    TestRunner:assertEqual(XrayAuto.seedForBuild(0, 0.995, nil), nil,
        "position at the end of the book: nothing to seed")
end)

TestRunner:test("seedForBuild: the round-22 CEILING (D1) — no seed at or past the first rung", function()
    -- The docstring always specified "below the first spacing rung"; only the
    -- floor was enforced. Without the ceiling, a from-nothing build at 71%
    -- planned a seed AT 71% — ONE request carrying ~710 pages of a 1000-page
    -- book (the device-round-3 field report).
    TestRunner:assertEqual(XrayAuto.seedForBuild(0, 0.71, nil, 0.10), nil,
        "the field case: reader deep in the book gets NO seed")
    TestRunner:assertEqual(XrayAuto.seedForBuild(0, 0.10, nil, 0.10), nil,
        "at the first rung exactly: the rung itself is promotable, no seed")
    TestRunner:assertEqual(XrayAuto.seedForBuild(0, 0.099, nil, 0.10), 0.099,
        "just below the first rung: seed applies")
    TestRunner:assertEqual(XrayAuto.seedForBuild(0, 0.12, nil), nil,
        "nil spacing falls back to LADDER_SPACING for the ceiling")
    TestRunner:assertEqual(XrayAuto.seedForBuild(0, 0.4, nil, 0.5), 0.4,
        "wide novella spacing: below the first rung, seed applies (bounded by spacing)")
end)

TestRunner:test("planBuildRungs: seed first, tail planned FROM the seed", function()
    -- 15% nominal normalizes to a 1/7 grid (0.143 steps). Position at the
    -- half-step floor — the lowest position that still seeds
    local rungs, seed = XrayAuto.planBuildRungs(0, 0.15, nil, 0.075)
    TestRunner:assertEqual(seed, 0.075, "seed reported (at the half-step floor)")
    TestRunner:assertEqual(rungs[1], 0.075, "seed is rung 1")
    TestRunner:assertEqual(rungs[2], 0.286, "first grid point within half a step of the seed is dropped")
    TestRunner:assertEqual(rungs[#rungs], 1.0, "final rung unchanged")
    -- Seed close under a grid boundary: the half-step rule drops the
    -- near-duplicate first grid rung — the tail continues one step later
    local near = XrayAuto.planBuildRungs(0, 0.15, nil, 0.12)
    TestRunner:assertEqual(near[1], 0.12, "seed at the position")
    TestRunner:assertEqual(near[2], 0.286, "near-duplicate grid rung dropped")
    -- Reader past the first rung (round 22, D1): NO seed — the plan is the
    -- plain spaced grid, every step bounded
    local past, no_seed = XrayAuto.planBuildRungs(0, 0.15, nil, 0.4)
    TestRunner:assertEqual(no_seed, nil, "reader past the first grid point: no seed")
    TestRunner:assertEqual(past[1], 0.143, "grid starts at the first normalized rung")
    TestRunner:assertEqual(past[2], 0.286, "spaced steps, nothing swallowed")
    -- Position-coverage build (goal == position): no seed, goal rung covers it
    local pos_cov, pos_seed = XrayAuto.planBuildRungs(0, 0.15, 0.4, 0.4)
    TestRunner:assertEqual(pos_seed, nil, "goal == position: no seed")
    TestRunner:assertEqual(pos_cov[#pos_cov], 0.4, "final rung = the position goal")
end)

TestRunner:test("E7 (item 38): the seed floor is formula-based — max(SEED_MIN, spacing/2)", function()
    -- The field case: 48-page book (spacing clamps to 50%), reader at 4%.
    -- The flat 3% floor seeded a two-page checkpoint next to the intro; the
    -- half-step floor (25% here) drops it — the plan is intro + 50 + 100.
    TestRunner:assertEqual(XrayAuto.seedForBuild(0, 0.04, nil, 0.5), nil,
        "novella at 4%: below half a step, no seed")
    local rungs, seed = XrayAuto.planBuildRungs(0, 0.5, nil, 0.04)
    TestRunner:assertEqual(seed, nil, "plan agrees: no seed")
    TestRunner:assertEqual(rungs[1], 0.5, "grid starts at the midpoint rung")
    TestRunner:assertEqual(rungs[2], 1.0, "then the whole book")
    -- The seed band on 50% spacing is [25%, 50%)
    TestRunner:assertEqual(XrayAuto.seedForBuild(0, 0.24, nil, 0.5), nil,
        "just under half a step: still no seed")
    TestRunner:assertEqual(XrayAuto.seedForBuild(0, 0.26, nil, 0.5), 0.26,
        "past half a step: seed applies")
    -- Normal 10% spacing: half-step (5%) beats the 3% absolute floor
    TestRunner:assertEqual(XrayAuto.seedForBuild(0, 0.04, nil, 0.10), nil,
        "10% spacing at 4%: below the 5% half-step floor")
    TestRunner:assertEqual(XrayAuto.seedForBuild(0, 0.05, nil, 0.10), 0.05,
        "10% spacing at 5%: at the floor, seed applies")
    -- Monster-book 5% spacing: the absolute 3% floor still binds (2.5% half-step)
    TestRunner:assertEqual(XrayAuto.seedForBuild(0, 0.028, nil, 0.05), nil,
        "5% spacing at 2.8%: under LADDER_SEED_MIN")
    TestRunner:assertEqual(XrayAuto.seedForBuild(0, 0.032, nil, 0.05), 0.032,
        "5% spacing at 3.2%: above both floors")
end)

TestRunner:test("tiny-book field case (item 38): seed just under the novella midpoint rung", function()
    -- 48-page book: spacing clamps to 50%; reader at 48%. The half-step rule
    -- (planned FROM the seed) must drop the 50% near-duplicate — the grid is
    -- seed + final ONLY. The session-2 device report read the confirm's
    -- "every 50%" phrasing as a third checkpoint; the copy now names the
    -- actual grid, and this pins the grid itself.
    local spacing = XrayAuto.ladderSpacingFor(48)
    TestRunner:assertEqual(spacing, 0.5, "novella clamp: 50% spacing")
    local rungs, seed = XrayAuto.planBuildRungs(0, spacing, nil, 0.48)
    TestRunner:assertEqual(seed, 0.48, "seed at the reader's position")
    TestRunner:assertEqual(#rungs, 2, "seed + final only, NO 50% near-duplicate")
    TestRunner:assertEqual(rungs[1], 0.48, "first = seed")
    TestRunner:assertEqual(rungs[2], 1.0, "second = whole book")
end)

TestRunner:test("T1 INVARIANT: no planned rung covers more than 1.5 spacings of new text", function()
    -- The property the whole checkpoint system exists to guarantee — each
    -- request's extraction delta is bounded by the spacing (×1.5 worst case:
    -- the half-step rule may skip one near-duplicate boundary). This is the
    -- test that would have caught D1. Scenarios: {pages, base, goal, position}.
    local scenarios = {
        { 1000, nil, nil, 0.71 },   -- the device-round-3 field report
        { 1000, nil, nil, 0.05 },
        { 1000, nil, nil, 0.98 },
        { 1000, 0.3, nil, 0.71 },
        { 1000, nil, 0.5, 0.45 },
        { 300,  nil, nil, 0.5 },
        { 90,   nil, nil, 0.6 },    -- novella: wide spacing
        { 2500, nil, nil, 0.33 },   -- monster book: min-spacing bound
        { 450,  0.48, nil, 0.52 },  -- half-step rule near the base
    }
    for _idx, s in ipairs(scenarios) do
        local pages, base, goal, pos = s[1], s[2], s[3], s[4]
        local spacing = XrayAuto.ladderSpacingFor(pages)
        local rungs = XrayAuto.planBuildRungs(base, spacing, goal, pos)
        local label = string.format("pages=%d base=%s goal=%s pos=%.2f",
            pages, tostring(base), tostring(goal), pos)
        local prev = base or 0
        for i, target in ipairs(rungs) do
            local delta = target - prev
            TestRunner:assertEqual(delta <= spacing * 1.5 + XrayAuto.LADDER_TOLERANCE, true,
                string.format("%s rung %d (%.3f): delta %.3f within 1.5×spacing %.2f",
                    label, i, target, delta, spacing))
            prev = target
        end
        -- The truncated (auto-establishment) prefix obeys the same bound by
        -- construction — assert it stays a prefix
        local trunc = XrayAuto.truncateToOneAhead(rungs, pos)
        for i, target in ipairs(trunc) do
            TestRunner:assertEqual(target, rungs[i], label .. ": truncation is a prefix")
        end
    end
    -- The field case exactly: 8 bounded requests, not 2 unbounded ones
    local spacing = XrayAuto.ladderSpacingFor(1000)
    local rungs = XrayAuto.planBuildRungs(nil, spacing, nil, 0.71)
    local trunc = XrayAuto.truncateToOneAhead(rungs, 0.71)
    TestRunner:assertEqual(#trunc, 8, "establishment at 71%: grid to position + one ahead")
    TestRunner:assertEqual(trunc[1], 0.1, "first checkpoint bounded at the first spacing rung")
    TestRunner:assertEqual(trunc[#trunc], 0.8, "one ahead of the reader")
end)

print("")
print("  [round 22: planAutoWork decision core (T2) + cancel suppression (D3)]")

local function isJSON(s) return s == "{}" end

TestRunner:test("planAutoWork: from-nothing establishment", function()
    local w = XrayAuto.planAutoWork{ entry = nil, ladder = {}, base_progress = nil,
        position = 0.2, goal = nil, is_json = isJSON }
    TestRunner:assertEqual(w.build, true, "builds")
    TestRunner:assertEqual(w.base, nil, "no base")
    TestRunner:assertEqual(w.has_any, false, "nothing built")
    TestRunner:assertEqual(w.plan_intro, true, "intro planned")
end)

TestRunner:test("planAutoWork: intro-only book is still a FIRST SPEND (D1 has_any hole)", function()
    -- The field case: build cancelled after the introduction — a live intro
    -- entry and an intro rung, nothing else. has_any must stay false so the
    -- create guard and the coverage ask still apply.
    local intro_entry = { result = "{}", intro = true, progress_decimal = 0 }
    local w = XrayAuto.planAutoWork{
        entry = intro_entry,
        ladder = { { intro = true, result = "{}", progress_decimal = 0 } },
        base_progress = nil,  -- highestXrayLadderProgress skips intro rungs
        position = 0.71, goal = nil, is_json = isJSON,
    }
    TestRunner:assertEqual(w.build, true, "builds (once past the guards)")
    TestRunner:assertEqual(w.has_any, false, "intro alone is not 'built'")
    TestRunner:assertEqual(w.has_intro, true, "the intro is seen")
    TestRunner:assertEqual(w.plan_intro, false, "no second intro planned")
    TestRunner:assertEqual(w.base, nil, "the intro is never a base")
end)

TestRunner:test("planAutoWork: lineage blocks + live base folding", function()
    local complete = { result = "{}", full_document = true }
    local w = XrayAuto.planAutoWork{ entry = complete, ladder = {}, base_progress = nil,
        position = 0.3, goal = nil, is_json = isJSON }
    TestRunner:assertEqual(w.lineage_blocked, true, "complete-track blocks")
    TestRunner:assertEqual(w.build, nil, "no build")
    -- A rung base beside a different-lineage live entry: rungs win, not blocked
    w = XrayAuto.planAutoWork{ entry = complete,
        ladder = { { result = "{}", progress_decimal = 0.2 } }, base_progress = 0.2,
        position = 0.35, goal = nil, is_json = isJSON }
    TestRunner:assertEqual(w.build, true, "rung lineage continues past a foreign live entry")
    TestRunner:assertEqual(w.base, 0.2, "rung base kept")
    -- Live incremental ahead of the rungs: live wins as base
    w = XrayAuto.planAutoWork{ entry = { result = "{}", progress_decimal = 0.4 },
        ladder = { { result = "{}", progress_decimal = 0.2 } }, base_progress = 0.2,
        position = 0.45, goal = nil, is_json = isJSON }
    TestRunner:assertEqual(w.base, 0.4, "live coverage folds into the base")
end)

TestRunner:test("planAutoWork: idle reasons — ahead, goal reached, no position", function()
    local w = XrayAuto.planAutoWork{ entry = nil,
        ladder = { { result = "{}", progress_decimal = 0.3 } }, base_progress = 0.3,
        position = 0.25, goal = nil, is_json = isJSON }
    TestRunner:assertEqual(w.reason, "ahead", "built rung ahead of the reader: idle")
    w = XrayAuto.planAutoWork{ entry = { result = "{}", progress_decimal = 0.5 },
        ladder = {}, base_progress = nil,
        position = 0.45, goal = nil, is_json = isJSON }
    TestRunner:assertEqual(w.reason, "ahead", "live coverage ahead: idle")
    w = XrayAuto.planAutoWork{ entry = nil,
        ladder = { { result = "{}", progress_decimal = 0.5 } }, base_progress = 0.5,
        position = 0.55, goal = 0.5, is_json = isJSON }
    TestRunner:assertEqual(w.reason, "goal_reached", "goal-bounded scheduler idles at the goal")
    w = XrayAuto.planAutoWork{ entry = nil, ladder = {}, base_progress = nil,
        position = nil, goal = nil, is_json = isJSON }
    TestRunner:assertEqual(w.reason, "no_position", "no position: nothing to plan")
    -- Invalid goals are ignored, not treated as tiny targets
    w = XrayAuto.planAutoWork{ entry = nil, ladder = {}, base_progress = nil,
        position = 0.2, goal = 0.999, is_json = isJSON }
    TestRunner:assertEqual(w.goal, nil, "near-1.0 goal normalizes to whole book")
    TestRunner:assertEqual(w.build, true, "and still builds")
end)

TestRunner:test("planAutoWork: intro rung is never 'ahead'", function()
    -- An intro (progress 0) plus nothing else, reader anywhere: not ahead
    local w = XrayAuto.planAutoWork{ entry = nil,
        ladder = { { intro = true, result = "{}", progress_decimal = 0 } },
        base_progress = nil, position = 0.1, goal = nil, is_json = isJSON }
    TestRunner:assertEqual(w.build, true, "intro alone never satisfies the invariant")
end)

TestRunner:test("auto suppression (D3): per-file, clearable, session-scoped semantics", function()
    TestRunner:assertEqual(XrayAuto.isAutoSuppressed("/a"), false, "clean start")
    XrayAuto.suppressAuto("/a")
    TestRunner:assertEqual(XrayAuto.isAutoSuppressed("/a"), true, "suppressed after cancel")
    TestRunner:assertEqual(XrayAuto.isAutoSuppressed("/b"), false, "other books unaffected")
    XrayAuto.clearAutoSuppression("/a")
    TestRunner:assertEqual(XrayAuto.isAutoSuppressed("/a"), false, "explicit start clears")
    XrayAuto.suppressAuto(nil)
    TestRunner:assertEqual(XrayAuto.isAutoSuppressed(nil), false, "nil file never suppresses")
end)

TestRunner:test("ladder build chain: intro step (round 20)", function()
    XrayAuto.beginLadderBuild("/f", { 0.15, 0.3, 1.0 }, {}, { intro = true })
    local b = XrayAuto.ladderBuild()
    TestRunner:assertEqual(b.total, 4, "display total counts the intro step")
    TestRunner:assertEqual(b.step, 1, "display step starts at 1")
    local s = XrayAuto.currentLadderStep()
    TestRunner:assertEqual(s.intro, true, "intro fires first")
    TestRunner:assertEqual(s.target, 0.15, "intro reads rung 1's slice")
    XrayAuto.completeIntro()
    s = XrayAuto.currentLadderStep()
    TestRunner:assertEqual(s.intro, nil, "rung 1 follows the intro")
    TestRunner:assertEqual(s.target, 0.15, "rung index unchanged by the intro")
    TestRunner:assertEqual(XrayAuto.ladderBuild().step, 2, "display step advanced")
    TestRunner:assertEqual(XrayAuto.advanceLadderBuild(), 0.3, "advance to rung 2")
    TestRunner:assertEqual(XrayAuto.ladderBuild().step, 3, "step tracks the advance")
    XrayAuto.endLadderBuild()
    -- No-intro chain: unchanged behavior
    XrayAuto.beginLadderBuild("/f", { 0.5, 1.0 }, {})
    TestRunner:assertEqual(XrayAuto.ladderBuild().total, 2, "no intro: total = rung count")
    TestRunner:assertEqual(XrayAuto.currentLadderStep().target, 0.5, "rung 1 immediately")
    TestRunner:assertEqual(XrayAuto.currentLadderStep().intro, nil, "no intro step")
    XrayAuto.endLadderBuild()
end)

TestRunner:test("ladderSpacingFor v2: max-pages ceiling narrows spacing on long books", function()
    TestRunner:assertEqual(XrayAuto.ladderSpacingFor(1000), 0.1,
        "1000 pages: ceiling lands exactly on baseline (100-page rungs)")
    TestRunner:assertEqual(XrayAuto.ladderSpacingFor(1500), 0.07,
        "1500 pages: narrowed to 7% (~100-page rungs, not 150)")
    TestRunner:assertEqual(XrayAuto.ladderSpacingFor(2000), 0.05,
        "2000 pages: 5% (100-page rungs, 20 calls)")
    TestRunner:assertEqual(XrayAuto.ladderSpacingFor(3000), 0.05,
        "monster book: call-count floor wins over the size ceiling")
    TestRunner:assertEqual(#XrayAuto.planLadderRungs(0, XrayAuto.ladderSpacingFor(3000)), 20,
        "5% spacing from nothing = 19 partial rungs + 1.0")
end)

TestRunner:test("snapLadderRungs: narrow spacing shrinks the snap window", function()
    -- spacing 5%: window becomes 2% (0.4 * spacing), so a boundary 2.5% away
    -- must NOT capture the target (it would under the default 3% window)
    local t, l = XrayAuto.snapLadderRungs({ 0.50, 1.0 }, {
        { ratio = 0.475, title = "Near" }, { ratio = 0.2, title = "B" }, { ratio = 0.8, title = "C" },
    }, 0, 0.05)
    TestRunner:assertEqual(t[1], 0.5, "boundary 2.5% away ignored under the scaled 2% window")
    TestRunner:assertEqual(l[1], nil, "no label for the unsnapped target")
    -- inside the scaled window it still snaps
    local t2, l2 = XrayAuto.snapLadderRungs({ 0.50, 1.0 }, {
        { ratio = 0.49, title = "Close" }, { ratio = 0.2, title = "B" }, { ratio = 0.8, title = "C" },
    }, 0, 0.05)
    TestRunner:assertEqual(t2[1], 0.49, "1% away snaps under the scaled window")
    TestRunner:assertEqual(l2[1], "Close", "label rides")
    -- nil spacing keeps the legacy full window (back-compat)
    local t3 = XrayAuto.snapLadderRungs({ 0.50, 1.0 }, {
        { ratio = 0.475, title = "Near" }, { ratio = 0.2, title = "B" }, { ratio = 0.8, title = "C" },
    }, 0)
    TestRunner:assertEqual(t3[1], 0.475, "no spacing arg: 3% window still captures")
end)

TestRunner:test("snapLadderRungs: chapter-end snap, window, dedup, final rung survives", function()
    local rungs = XrayAuto.planLadderRungs(0)  -- 0.1..0.9 + 1.0
    local bounds = {
        { ratio = 0.12, title = "One" },
        { ratio = 0.28, title = "Two" },
        { ratio = 0.55, title = "Three" },
        { ratio = 0.71, title = "Four" },
    }
    local targets, labels = XrayAuto.snapLadderRungs(rungs, bounds, 0)
    TestRunner:assertEqual(targets[1], 0.12, "0.10 snaps to the chapter end at 0.12")
    TestRunner:assertEqual(labels[1], "One", "carries the chapter title")
    TestRunner:assertEqual(targets[2], 0.2, "no boundary within 3%: raw target kept")
    TestRunner:assertEqual(labels[2], nil, "raw targets carry no label")
    TestRunner:assertEqual(targets[3], 0.28, "0.30 snaps DOWN to 0.28")
    TestRunner:assertEqual(targets[5], 0.5, "0.55 is outside the 3% window of 0.50")
    TestRunner:assertEqual(targets[7], 0.71, "0.70 snaps up to 0.71")
    TestRunner:assertEqual(labels[7], "Four", "label rides")
    TestRunner:assertEqual(targets[#targets], 1.0, "final rung stays 1.0, never snapped")
    TestRunner:assertEqual(labels[#targets], nil, "final rung unlabeled")

    local t2, l2 = XrayAuto.snapLadderRungs(rungs, { { ratio = 0.5, title = "Only" } }, 0)
    TestRunner:assertEqual(t2, rungs, "fewer than 3 boundaries: passthrough (unusable TOC)")
    TestRunner:assertEqual(next(l2), nil, "and no labels")

    local t3 = XrayAuto.snapLadderRungs({ 0.9, 1.0 }, {
        { ratio = 0.3, title = "A" }, { ratio = 0.6, title = "B" }, { ratio = 0.99, title = "Z" },
    }, 0.85)
    TestRunner:assertEqual(t3[1], 0.9, "a boundary inside the final 3% is ignored")
    TestRunner:assertEqual(t3[2], 1.0, "so the final rung is never displaced")

    local t4 = XrayAuto.snapLadderRungs({ 0.30, 0.33, 1.0 }, {
        { ratio = 0.31, title = "A" }, { ratio = 0.05, title = "B" }, { ratio = 0.07, title = "C" },
    }, 0)
    TestRunner:assertEqual(#t4, 2, "two rungs collapsing onto one chapter build it once")
    TestRunner:assertEqual(t4[1], 0.31, "the snapped rung")
    TestRunner:assertEqual(t4[2], 1.0, "plus the final rung")

    -- Labels ride the build state per-index (skip-ahead advances idx, staying aligned)
    XrayAuto.beginLadderBuild("/x.epub", targets, labels)
    TestRunner:assertEqual(XrayAuto.ladderBuild().labels[1], "One", "labels stored on the build")
    XrayAuto.endLadderBuild()

    -- chapter_label survives the ladder sidecar serializer (field parity)
    ActionCache.clearXrayLadder(DOC_PATH)
    ActionCache.pushXrayLadderRung(DOC_PATH, {
        result = '{"x":1}', progress_decimal = 0.28, timestamp = 1700000000,
        chapter_label = "Two \"quoted\" title",
    })
    local disk = ActionCache.getXrayLadder(DOC_PATH)
    TestRunner:assertEqual(disk[1] and disk[1].chapter_label, "Two \"quoted\" title",
        "chapter_label round-trips through the ring serializer")
    ActionCache.clearXrayLadder(DOC_PATH)
end)

TestRunner:test("pickAheadRung (B269): the LOWEST built rung past live that reaches the position", function()
    local ladder = {
        { progress_decimal = 0.2, result = "{}", timestamp = 1 },
        { progress_decimal = 0.4, result = "{}", timestamp = 2 },
        { progress_decimal = 0.6, result = "{}", timestamp = 3 },
        { progress_decimal = 0.8, result = "{}", timestamp = 4 },
        { progress_decimal = 1.0, result = "{}", timestamp = 5, full_document = true },
    }
    -- installed 0.4, reader at 0.52 -> the 0.6 rung, never the 1.0 one
    TestRunner:assertEqual(XrayAuto.pickAheadRung(ladder, 0.4, 0.52).timestamp, 3, "covering rung")
    -- reader sitting exactly on a rung's coverage: that rung
    TestRunner:assertEqual(XrayAuto.pickAheadRung(ladder, 0.4, 0.6).timestamp, 3, "exact coverage")
    -- reader just past 0.6 -> 0.8
    TestRunner:assertEqual(XrayAuto.pickAheadRung(ladder, 0.4, 0.61).timestamp, 4, "next rung")
    -- rungs at or below live never qualify: live 0.6, reader 0.5 -> 0.8
    TestRunner:assertEqual(XrayAuto.pickAheadRung(ladder, 0.6, 0.5).timestamp, 4, "past live")
    -- the covering rung is not built yet (gap at 0.5..0.6) -> nothing; no position -> nothing
    TestRunner:assertEqual(XrayAuto.pickAheadRung({ ladder[1], ladder[2] }, 0.4, 0.52), nil, "unbuilt")
    TestRunner:assertEqual(XrayAuto.pickAheadRung(ladder, 0.4, nil), nil, "no position")
    -- intro rungs / result-less rungs are skipped
    TestRunner:assertEqual(XrayAuto.pickAheadRung({
        { progress_decimal = 0.6, result = "{}", intro = true, timestamp = 9 },
        { progress_decimal = 0.8, timestamp = 10 },
        ladder[5] }, 0.4, 0.52).timestamp, 5, "skips intro and empty")
end)

TestRunner:test("pickPromotableRung: at-or-below position, ahead of live, complete excluded", function()
    local ladder = {
        { progress_decimal = 0.2, result = "a" },
        { progress_decimal = 0.4, result = "b" },
        { progress_decimal = 0.6, result = "c" },
        { progress_decimal = 1.0, result = "d", full_document = true },
    }
    local pick = XrayAuto.pickPromotableRung(ladder, 0.2, 0.45)
    TestRunner:assertEqual(pick and pick.progress_decimal, 0.4, "highest rung <= position, ahead of live")
    TestRunner:assertEqual(XrayAuto.pickPromotableRung(ladder, 0.4, 0.45), nil,
        "live already at the covering rung -> nothing")
    TestRunner:assertEqual(XrayAuto.pickPromotableRung(ladder, 0.4, 0.599), nil,
        "a rung a tenth of a percent ahead of the reader does not install (ref #90)")
    pick = XrayAuto.pickPromotableRung(ladder, 0.4, 0.5996)
    TestRunner:assertEqual(pick and pick.progress_decimal, 0.6, "snap-unit tolerance at the boundary")
    TestRunner:assertEqual(XrayAuto.pickPromotableRung(ladder, 0.6, 1.0), nil,
        "full-document rungs never promote")
    pick = XrayAuto.pickPromotableRung(ladder, nil, 0.25)
    TestRunner:assertEqual(pick and pick.progress_decimal, 0.2, "nil live treated as 0 (install case)")
    TestRunner:assertEqual(XrayAuto.pickPromotableRung(ladder, 0.2, nil), nil, "no position -> nil")
    TestRunner:assertEqual(XrayAuto.pickPromotableRung(nil, 0.2, 0.5), nil, "no ladder -> nil")
end)

TestRunner:test("pickPromotableRung ahead_ok (50(f) FULL posture): newest rung, position ignored", function()
    local ladder = {
        { progress_decimal = 0.2, result = "a" },
        { progress_decimal = 0.6, result = "c" },
        { progress_decimal = 1.0, result = "d", full_document = true },
        { progress_decimal = 0, result = "i", intro = true },
    }
    local pick = XrayAuto.pickPromotableRung(ladder, 0.2, 0.25, { ahead_ok = true })
    TestRunner:assertEqual(pick and pick.progress_decimal, 0.6,
        "highest non-full rung wins regardless of the reading position")
    pick = XrayAuto.pickPromotableRung(ladder, nil, nil, { ahead_ok = true })
    TestRunner:assertEqual(pick and pick.progress_decimal, 0.6,
        "position not required under ahead_ok (nil live treated as 0)")
    TestRunner:assertEqual(XrayAuto.pickPromotableRung(ladder, 0.6, 0.25, { ahead_ok = true }), nil,
        "live already at the newest rung -> nothing (full_document still excluded)")
    -- The default (track) pick is unchanged by the opts param existing
    pick = XrayAuto.pickPromotableRung(ladder, 0.2, 0.25, nil)
    TestRunner:assertEqual(pick and pick.progress_decimal, nil,
        "track posture still position-gated (0.6 is ahead of 0.25)")
end)

TestRunner:test("ladder build state: begin/advance/cancel/end", function()
    TestRunner:assertEqual(XrayAuto.ladderBuild(), nil, "idle by default")
    XrayAuto.beginLadderBuild("/x.epub", { 0.4, 0.5, 1.0 })
    local b = XrayAuto.ladderBuild()
    TestRunner:assertEqual(b.idx, 1, "starts at rung 1")
    TestRunner:assertEqual(b.total, 3, "total stamped")
    TestRunner:assertEqual(XrayAuto.advanceLadderBuild(), 0.5, "advance returns next target")
    TestRunner:assertEqual(XrayAuto.advanceLadderBuild(), 1.0, "then the last")
    TestRunner:assertEqual(XrayAuto.advanceLadderBuild(), nil, "then nil (done)")
    XrayAuto.requestLadderCancel()
    TestRunner:assertEqual(XrayAuto.ladderBuild().cancel_requested, true, "cancel flag set")
    XrayAuto.endLadderBuild()
    TestRunner:assertEqual(XrayAuto.ladderBuild(), nil, "ended")
end)

TestRunner:test("ladder disk round-trip: ascending order, replace-within-tolerance, O(1) count", function()
    ActionCache.clearXrayLadder(DOC_PATH)
    -- Push out of order; expect ascending on read
    for _idx, p in ipairs({ 0.4, 0.2, 0.6 }) do
        local ok_push = ActionCache.pushXrayLadderRung(DOC_PATH, {
            result = '{"rung": ' .. tostring(p) .. '}', progress_decimal = p,
            progress_page = math.floor(p * 100), timestamp = 1700000000 + math.floor(p * 10),
            used_book_text = true, model = "m",
        })
        TestRunner:assertEqual(ok_push, true, "push " .. tostring(p) .. " succeeds")
    end
    local ladder = ActionCache.getXrayLadder(DOC_PATH)
    TestRunner:assertEqual(#ladder, 3, "three rungs")
    TestRunner:assertEqual(ladder[1].progress_decimal, 0.2, "ascending: lowest first")
    TestRunner:assertEqual(ladder[3].progress_decimal, 0.6, "highest last")
    TestRunner:assertEqual(ActionCache.getXrayLadderCount(DOC_PATH), 3, "header count")
    TestRunner:assertEqual(ActionCache.highestXrayLadderProgress(ladder), 0.6, "highest progress")

    -- Same-progress re-push replaces, never duplicates (resume overlap)
    ActionCache.pushXrayLadderRung(DOC_PATH, {
        result = '{"rung": "0.4 v2"}', progress_decimal = 0.402, timestamp = 1700009999,
    })
    ladder = ActionCache.getXrayLadder(DOC_PATH)
    TestRunner:assertEqual(#ladder, 3, "replaced within tolerance, not appended")
    TestRunner:assertEqual(ladder[2].result, '{"rung": "0.4 v2"}', "newer rung content wins")

    ActionCache.clearXrayLadder(DOC_PATH)
    TestRunner:assertEqual(ActionCache.getXrayLadderCount(DOC_PATH), 0, "cleared -> 0")
end)

TestRunner:test("intro rung: disk round-trip, resume-point exclusion (round 20)", function()
    ActionCache.clearXrayLadder(DOC_PATH)
    ActionCache.pushXrayLadderRung(DOC_PATH, {
        result = '{"intro": true}', progress_decimal = 0, progress_page = 0,
        timestamp = 1700000001, used_book_text = true, model = "m", intro = true,
    })
    local ladder = ActionCache.getXrayLadder(DOC_PATH)
    TestRunner:assertEqual(#ladder, 1, "intro rung stored")
    TestRunner:assertEqual(ladder[1].intro, true, "intro flag round-trips")
    TestRunner:assertEqual(ActionCache.highestXrayLadderProgress(ladder), nil,
        "intro-only ladder has no resume point (still a from-nothing build)")
    ActionCache.pushXrayLadderRung(DOC_PATH, {
        result = '{"rung": 1}', progress_decimal = 0.15, timestamp = 1700000002,
    })
    ladder = ActionCache.getXrayLadder(DOC_PATH)
    TestRunner:assertEqual(#ladder, 2, "real rung joins the intro")
    TestRunner:assertEqual(ActionCache.highestXrayLadderProgress(ladder), 0.15,
        "real rungs set the resume point")
    TestRunner:assertEqual(XrayAuto.pickPromotableRung(ladder, 0, 0.05), nil,
        "intro never promotes via the position picker (installed by the no-live fallback only)")
    ActionCache.clearXrayLadder(DOC_PATH)
end)

TestRunner:test("promoteXrayLadderRung: copy semantics, conditional ring push, flag fallback", function()
    ActionCache.clearXrayLadder(DOC_PATH)
    ActionCache.clearXrayCheckpoints(DOC_PATH)
    ActionCache.clearXrayCache(DOC_PATH)
    ActionCache.clear(DOC_PATH, "xray")

    -- No live entry at all: promotion INSTALLS the rung (build-from-nothing case)
    ActionCache.pushXrayLadderRung(DOC_PATH, {
        result = '{"rung": "20"}', progress_decimal = 0.2, progress_page = 20,
        timestamp = 1700000020, used_book_text = true, used_highlights = false, model = "m-20",
    })
    local ladder = ActionCache.getXrayLadder(DOC_PATH)
    local ok_install = ActionCache.promoteXrayLadderRung(DOC_PATH, ladder[1], 5)
    TestRunner:assertEqual(ok_install, true, "install succeeds without a live entry")
    local live = ActionCache.getXrayCache(DOC_PATH)
    TestRunner:assertEqual(live.result, '{"rung": "20"}', "rung is live (doc key)")
    TestRunner:assertEqual(live.timestamp, 1700000020, "rung generation time preserved")
    local pa = ActionCache.get(DOC_PATH, "xray")
    TestRunner:assertEqual(pa and pa.result, '{"rung": "20"}', "per-action key updated too")
    TestRunner:assertEqual(#ActionCache.getXrayCheckpoints(DOC_PATH), 0,
        "no ring push when nothing was live")
    TestRunner:assertEqual(#ActionCache.getXrayLadder(DOC_PATH), 1, "rung STAYS in the ladder (copy)")

    -- Live == a ladder rung: promotion must NOT ring-archive it (dup guard)
    ActionCache.pushXrayLadderRung(DOC_PATH, {
        result = '{"rung": "40"}', progress_decimal = 0.4, progress_page = 40,
        timestamp = 1700000040, used_book_text = true, model = "m-40",
    })
    ladder = ActionCache.getXrayLadder(DOC_PATH)
    local ok_step = ActionCache.promoteXrayLadderRung(DOC_PATH, ladder[2], 5)
    TestRunner:assertEqual(ok_step, true, "promotion over a rung-identical live succeeds")
    TestRunner:assertEqual(#ActionCache.getXrayCheckpoints(DOC_PATH), 0,
        "no ring dup: outgoing live was itself a rung")
    TestRunner:assertEqual(ActionCache.getXrayCache(DOC_PATH).result, '{"rung": "40"}', "live moved forward")

    -- Live NOT a rung (manual update happened): promotion ring-archives it
    ActionCache.setXrayCache(DOC_PATH, '{"manual": "45"}', 0.45,
        { model = "m-manual", used_book_text = true, used_highlights = true, progress_page = 45 })
    ActionCache.set(DOC_PATH, "xray", '{"manual": "45"}', 0.45, { model = "m-manual" })
    ActionCache.pushXrayLadderRung(DOC_PATH, {
        result = '{"rung": "60"}', progress_decimal = 0.6, progress_page = 60,
        timestamp = 1700000060, model = "m-60",
        -- no used_* flags on this rung: promotion falls back to the live entry's
    })
    ladder = ActionCache.getXrayLadder(DOC_PATH)
    local ok_over = ActionCache.promoteXrayLadderRung(DOC_PATH, ladder[3], 5)
    TestRunner:assertEqual(ok_over, true, "promotion over a manual live succeeds")
    local ring = ActionCache.getXrayCheckpoints(DOC_PATH)
    TestRunner:assertEqual(#ring, 1, "manual live was ring-archived")
    TestRunner:assertEqual(ring[1].result, '{"manual": "45"}', "with its content")
    live = ActionCache.getXrayCache(DOC_PATH)
    TestRunner:assertEqual(live.result, '{"rung": "60"}', "rung is live")
    TestRunner:assertEqual(live.used_highlights, true, "missing rung flag falls back to live's (superset)")

    ActionCache.clearXrayLadder(DOC_PATH)
    ActionCache.clearXrayCheckpoints(DOC_PATH)
    ActionCache.clearXrayCache(DOC_PATH)
    ActionCache.clear(DOC_PATH, "xray")
end)

TestRunner:test("clearAll clears companion files (ladder resurrection guard)", function()
    ActionCache.pushXrayLadderRung(DOC_PATH, {
        result = '{"r": 1}', progress_decimal = 0.2, timestamp = 1700000001,
    })
    ActionCache.pushXrayCheckpoint(DOC_PATH, {
        result = '{"c": 1}', progress_decimal = 0.1, timestamp = 1700000002,
    })
    ActionCache.clearAll(DOC_PATH)
    TestRunner:assertEqual(ActionCache.getXrayLadderCount(DOC_PATH), 0,
        "delete-all clears the ladder (no promotion resurrection)")
    TestRunner:assertEqual(#ActionCache.getXrayCheckpoints(DOC_PATH), 0,
        "delete-all clears the ring (no orphan)")
end)

TestRunner:test("classifyStopReason: transient classes vs terminal ones (item 45)", function()
    local cases = {
        { "gemini/gemini-3.1-flash-lite: HTTP 503: This model is currently experiencing high demand. Spikes in demand are usually temporary.", "overloaded", true },
        { "HTTP 429: rate limit exceeded", "rate_limited", true },
        { "openai/gpt-5.5: quota exceeded for this billing period", "rate_limited", true },
        { "HTTP 502: bad gateway", "server_error", true },
        { "request timed out", "timeout", true },
        { "SSL handshake failed", "network", true },
        { "could not connect to server", "network", true },
        { "response is not a valid X-Ray JSON structure", "bad_json", false },
        { "rung not saved", "bad_json", false },
        { "some entirely novel failure", "other", false },
        { nil, "other", false },
    }
    for _idx, case in ipairs(cases) do
        local kind, transient = XrayAuto.classifyStopReason(case[1])
        TestRunner:assertEqual(kind, case[2], "kind for: " .. tostring(case[1]))
        TestRunner:assertEqual(transient, case[3], "transient for: " .. tostring(case[1]))
    end
end)

TestRunner:test("ladder stop record: per-file, superseded by a chain (re)start", function()
    XrayAuto.recordLadderStop("/a.epub", { step = 7, total = 11, kind = "overloaded" })
    local stop = XrayAuto.lastLadderStop("/a.epub")
    TestRunner:assertEqual(stop.step, 7, "step recorded")
    TestRunner:assertEqual(stop.kind, "overloaded", "kind recorded")
    TestRunner:assertEqual(XrayAuto.lastLadderStop("/b.epub"), nil, "other file: nil")
    XrayAuto.beginLadderBuild("/a.epub", { 0.5, 1.0 }, nil, nil)
    TestRunner:assertEqual(XrayAuto.lastLadderStop("/a.epub"), nil,
        "restart clears the pause reason")
    XrayAuto.endLadderBuild()
end)

os.execute(string.format("rm -rf %q", TMP_ROOT))

local ok = TestRunner:summary()
return ok
