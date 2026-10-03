--[[
Unit tests: shared artifact write-back primitive (koassistant_artifact_writeback.lua)
— xray_ecosystem_plan.md §6 slice 2.

Pure halves (metadata reconciliation, coverage/gaps, parse+merge) plus real disk
round-trips for commitXray/applyXray and the shared archive rule
(ActionCache.isXrayLadderRung — an outgoing live entry that IS a ladder rung is
never ring-archived).

Run: lua tests/unit/test_artifact_writeback.lua  (auto-discovered by run_tests.lua --unit)
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

-- Mocks BEFORE requiring modules with KOReader deps (same scaffold as
-- test_xray_auto's checkpoint section)
local TMP_ROOT = "/tmp/koassistant_writeback_test_" .. tostring(os.time()) .. "_" .. tostring(math.random(10000))
local SIDECAR_DIR = TMP_ROOT .. "/book.sdr"
os.execute(string.format("mkdir -p %q", SIDECAR_DIR))
package.loaded["koassistant_action_cache"] = nil
package.loaded["koassistant_artifact_writeback"] = nil
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
local WriteBack = require("koassistant_artifact_writeback")
local TestRunner = require("test_runner"):new()
local DOC_PATH = TMP_ROOT .. "/book.epub"

print("Running: test_artifact_writeback")
print("")
print("  [reconcileXrayMeta — sticky-true superset]")

TestRunner:test("base true survives a pass that didn't use the source", function()
    local meta = WriteBack.reconcileXrayMeta(
        { used_highlights = true, used_book_text = true },
        { used_highlights = false, used_book_text = false, model = "m2" })
    TestRunner:assertEqual(meta.used_highlights, true, "base true is sticky")
    TestRunner:assertEqual(meta.used_book_text, true, "book_text sticky too")
    TestRunner:assertEqual(meta.model, "m2", "other fields pass through")
end)

TestRunner:test("new true wins; explicit false survives only when both sides agree", function()
    local meta = WriteBack.reconcileXrayMeta(
        { used_highlights = false, used_annotations = false },
        { used_highlights = true })
    TestRunner:assertEqual(meta.used_highlights, true, "new true wins")
    TestRunner:assertEqual(meta.used_annotations, false, "both-false stays explicit false")
end)

TestRunner:test("nil base (fresh write): new values pass through untouched", function()
    local meta = WriteBack.reconcileXrayMeta(nil,
        { used_book_text = false, model = "m", source_mode = "extract" })
    TestRunner:assertEqual(meta.used_book_text, false, "explicit false kept")
    TestRunner:assertEqual(meta.used_highlights, nil, "absent stays absent")
    TestRunner:assertEqual(meta.source_mode, "extract", "source_mode kept")
end)

TestRunner:test("model/source_mode continuity from the base when the pass has none", function()
    local meta = WriteBack.reconcileXrayMeta(
        { model = "m-base", source_mode = "extract" }, {})
    TestRunner:assertEqual(meta.model, "m-base", "model falls back to base")
    TestRunner:assertEqual(meta.source_mode, "extract", "source_mode falls back to base")
end)

TestRunner:test("lineage/coverage companions inherited: full_document, progress_page, flow", function()
    -- Dropping full_document would feed a complete-track artifact into the
    -- incremental machinery (background updates, ladder promotion) — gate finding
    local meta = WriteBack.reconcileXrayMeta(
        { full_document = true, progress_page = 123, flow_visible_pages = 400 },
        { model = "m-pass" })
    TestRunner:assertEqual(meta.full_document, true, "full_document inherited")
    TestRunner:assertEqual(meta.progress_page, 123, "progress_page inherited (hidden-flow extraction)")
    TestRunner:assertEqual(meta.flow_visible_pages, 400, "flow fingerprint inherited")
    -- A new pass's own values win
    local meta2 = WriteBack.reconcileXrayMeta(
        { progress_page = 123 }, { progress_page = 200 })
    TestRunner:assertEqual(meta2.progress_page, 200, "new pass's page wins when provided")
end)

TestRunner:test("legacy base: used_annotations implies used_highlights (sticky)", function()
    -- Pre-used_highlights caches carry only used_annotations = true; the read
    -- gate treats that as highlights-true — the reconciliation must too, or a
    -- merge flips the artifact to annotations-gated (silent over-gating)
    local meta = WriteBack.reconcileXrayMeta(
        { used_annotations = true },  -- legacy shape, used_highlights nil
        { used_highlights = false })
    TestRunner:assertEqual(meta.used_highlights, true, "legacy implication kept sticky")
    TestRunner:assertEqual(meta.used_annotations, true, "annotations flag kept")
end)

TestRunner:test("web_search_used provenance TABLE normalized to boolean (serializer safety)", function()
    local meta = WriteBack.reconcileXrayMeta(nil, {
        web_search_used = { web_search = true, sources = { { url = "u" } } },
    })
    TestRunner:assertEqual(meta.web_search_used, true, "web-search table -> true")
    local meta2 = WriteBack.reconcileXrayMeta(nil, {
        web_search_used = { book_tools = { lookups = 3 } },
    })
    TestRunner:assertEqual(meta2.web_search_used, false, "book-tools-only table -> false (handleResponse rule)")
end)

print("")
print("  [coverageFromInputs — gaps + end coverage]")

TestRunner:test("contiguous sections: no gaps, max end page, ratio", function()
    local cov = WriteBack.coverageFromInputs({
        { label = "Ch. 1", start_page = 1, end_page = 20 },
        { label = "Ch. 2", start_page = 21, end_page = 45 },
    }, 100)
    TestRunner:assertEqual(#cov.gaps, 0, "no gaps")
    TestRunner:assertEqual(cov.end_page, 45, "max end page")
    TestRunner:assertEqual(cov.progress_decimal, 0.45, "coverage ratio")
end)

TestRunner:test("gap between non-adjacent sections is reported, unordered input sorted", function()
    local cov = WriteBack.coverageFromInputs({
        { label = "Ch. 3", start_page = 61, end_page = 80 },
        { label = "Ch. 1", start_page = 1, end_page = 20 },
    }, 100)
    TestRunner:assertEqual(#cov.gaps, 1, "one gap")
    TestRunner:assertEqual(cov.gaps[1].after_label, "Ch. 1", "gap follows Ch. 1")
    TestRunner:assertEqual(cov.gaps[1].before_label, "Ch. 3", "gap precedes Ch. 3")
    TestRunner:assertEqual(cov.gaps[1].from_page, 21, "gap start")
    TestRunner:assertEqual(cov.gaps[1].to_page, 60, "gap end")
    TestRunner:assertEqual(cov.end_page, 80, "end page from the later section")
end)

TestRunner:test("nested spans never fake gaps (running-max reach)", function()
    -- A parent TOC span covering its own chapters (Part I ⊃ Ch. 2) must not
    -- produce a "gap" between the child's end and the next sibling
    local cov = WriteBack.coverageFromInputs({
        { label = "Part I", start_page = 1, end_page = 100 },
        { label = "Ch. 2", start_page = 20, end_page = 30 },
        { label = "Part II", start_page = 101, end_page = 150 },
    }, 150)
    TestRunner:assertEqual(#cov.gaps, 0, "no fake gap inside the parent span")
    TestRunner:assertEqual(cov.end_page, 150, "end page correct")
    -- But a REAL gap beyond the parent's reach is still reported
    local cov2 = WriteBack.coverageFromInputs({
        { label = "Part I", start_page = 1, end_page = 100 },
        { label = "Ch. 2", start_page = 20, end_page = 30 },
        { label = "Part III", start_page = 120, end_page = 150 },
    }, 150)
    TestRunner:assertEqual(#cov2.gaps, 1, "real gap past the running max reported")
    TestRunner:assertEqual(cov2.gaps[1].after_label, "Part I", "gap attributed to the furthest reach")
    TestRunner:assertEqual(cov2.gaps[1].from_page, 101, "gap start from the reach")
end)

TestRunner:test("inputs without page fields are skipped; empty input is safe", function()
    local cov = WriteBack.coverageFromInputs({
        { label = "no-scope entry" },
        { label = "Ch. 1", start_page = 1, end_page = 10 },
    }, 0)
    TestRunner:assertEqual(cov.end_page, 10, "scoped entry counted")
    TestRunner:assertEqual(cov.progress_decimal, nil, "no ratio without total pages")
    TestRunner:assertEqual(#WriteBack.coverageFromInputs({}).gaps, 0, "empty input: no gaps")
end)

print("")
print("  [parseXrayAnswer — parse, merge, refusals]")

TestRunner:test("complete mode: parses and serializes", function()
    local parsed, err, cache_json = WriteBack.parseXrayAnswer(
        '{"characters":[{"name":"Jack","description":"a man"}]}')
    TestRunner:assertEqual(err, nil, "no error")
    TestRunner:assertEqual(parsed.characters[1].name, "Jack", "parsed")
    TestRunner:assertEqual(type(cache_json), "string", "cache JSON produced")
end)

TestRunner:test("delta mode: merges into a cache-entry base (replace + keep)", function()
    local base_entry = {
        result = '{"characters":[{"name":"Jack","description":"v1"},{"name":"Wendy","description":"his wife"}]}',
        progress_decimal = 0.3,
    }
    local parsed, err = WriteBack.parseXrayAnswer(
        '{"characters":[{"name":"Jack","description":"v2 — now an axe owner"}]}', base_entry)
    TestRunner:assertEqual(err, nil, "no error")
    local by_name = {}
    for _idx, c in ipairs(parsed.characters) do by_name[c.name] = c.description end
    TestRunner:assertEqual(by_name.Jack, "v2 — now an axe owner", "name-matched entry replaced")
    TestRunner:assertEqual(by_name.Wendy, "his wife", "untouched entry kept")
end)

TestRunner:test("model refusal ({\"error\": ...}) surfaces as err, never written", function()
    local parsed, err = WriteBack.parseXrayAnswer('{"error":"I do not recognize this work"}')
    TestRunner:assertEqual(parsed, nil, "no parsed data")
    TestRunner:assertEqual(err, "I do not recognize this work", "refusal text surfaced")
end)

TestRunner:test("garbage answer and invalid base both fail loudly", function()
    local parsed, err = WriteBack.parseXrayAnswer("this is prose, not JSON at all — no braces")
    TestRunner:assertEqual(parsed, nil, "garbage rejected")
    TestRunner:assertTrue(err ~= nil, "with an error message")
    local parsed2, err2 = WriteBack.parseXrayAnswer(
        '{"characters":[{"name":"A","description":"d"}]}', { result = "not json either" })
    TestRunner:assertEqual(parsed2, nil, "invalid base rejected")
    TestRunner:assertTrue(err2 ~= nil and err2:find("base"), "error names the base")
end)

print("")
print("  [commitXray / applyXray — disk round-trips + shared archive rule]")

local function wipe()
    ActionCache.clearAll(DOC_PATH)
end

TestRunner:test("commitXray writes BOTH keys and archives the outgoing live", function()
    wipe()
    ActionCache.setXrayCache(DOC_PATH, '{"old": true}', 0.3,
        { model = "m-old", timestamp = 1700000001, used_book_text = true })
    ActionCache.set(DOC_PATH, "xray", '{"old": true}', 0.3, { model = "m-old" })
    local ok = WriteBack.commitXray(DOC_PATH, '{"new": true}', 0.5,
        { model = "m-new", used_book_text = true }, { limit = 5 })
    TestRunner:assertEqual(ok, true, "commit succeeds")
    TestRunner:assertEqual(ActionCache.getXrayCache(DOC_PATH).result, '{"new": true}', "doc key written")
    local pa = ActionCache.get(DOC_PATH, "xray")
    TestRunner:assertEqual(pa and pa.result, '{"new": true}', "per-action key written")
    local ring = ActionCache.getXrayCheckpoints(DOC_PATH)
    TestRunner:assertEqual(#ring, 1, "outgoing live archived")
    TestRunner:assertEqual(ring[1].result, '{"old": true}', "with its content")
end)

TestRunner:test("commitXray skips the archive when the outgoing live IS a ladder rung", function()
    wipe()
    ActionCache.pushXrayLadderRung(DOC_PATH, {
        result = '{"rung": 40}', progress_decimal = 0.4, timestamp = 1700000040,
    })
    -- Promote it live (identity: same timestamp + progress as the rung)
    local rung = ActionCache.getXrayLadder(DOC_PATH)[1]
    ActionCache.promoteXrayLadderRung(DOC_PATH, rung, 5)
    TestRunner:assertEqual(#ActionCache.getXrayCheckpoints(DOC_PATH), 0, "clean ring before commit")
    local ok = WriteBack.commitXray(DOC_PATH, '{"manual": 45}', 0.45, { model = "m" }, { limit = 5 })
    TestRunner:assertEqual(ok, true, "commit over a promoted rung succeeds")
    TestRunner:assertEqual(#ActionCache.getXrayCheckpoints(DOC_PATH), 0,
        "no ring dup: outgoing live was a ladder rung (shared archive rule)")
end)

TestRunner:test("commitXray: identical result and limit 0 both skip the archive", function()
    wipe()
    ActionCache.setXrayCache(DOC_PATH, '{"same": 1}', 0.3, { timestamp = 1700000050 })
    WriteBack.commitXray(DOC_PATH, '{"same": 1}', 0.35, {}, { limit = 5 })
    TestRunner:assertEqual(#ActionCache.getXrayCheckpoints(DOC_PATH), 0, "identical result: no archive")
    WriteBack.commitXray(DOC_PATH, '{"other": 2}', 0.4, {}, { limit = 0 })
    TestRunner:assertEqual(#ActionCache.getXrayCheckpoints(DOC_PATH), 0, "limit 0: no archive")
end)

TestRunner:test("applyXray end-to-end: delta merge, sticky flags, no coverage regress", function()
    wipe()
    local base = {
        result = '{"characters":[{"name":"Jack","description":"v1"}]}',
        progress_decimal = 0.5,
        used_highlights = true, used_book_text = true,
        model = "m-base", timestamp = 1700000060,
    }
    ActionCache.setXrayCache(DOC_PATH, base.result, base.progress_decimal, base)
    ActionCache.set(DOC_PATH, "xray", base.result, base.progress_decimal, base)
    local refreshed = false
    local ok, result = WriteBack.applyXray({
        document_path = DOC_PATH,
        answer = '{"characters":[{"name":"Jack","description":"deepened"}]}',
        base = base,
        progress_decimal = 0.3,  -- a quality pass reporting LESS coverage than the base
        meta = { used_book_text = false, model = "m-pass" },
        limit = 5,
        refresh_fn = function() refreshed = true end,
    })
    TestRunner:assertEqual(ok, true, "apply succeeds")
    TestRunner:assertTrue(result:find("deepened") ~= nil, "merged content on disk")
    local live = ActionCache.getXrayCache(DOC_PATH)
    TestRunner:assertEqual(live.progress_decimal, 0.5, "coverage never regresses below the base")
    TestRunner:assertEqual(live.used_book_text, true, "sticky-true kept from base")
    TestRunner:assertEqual(live.used_highlights, true, "base highlight flag kept")
    TestRunner:assertEqual(live.model, "m-pass", "new pass's model recorded")
    TestRunner:assertEqual(refreshed, true, "refresh callback ran")
    TestRunner:assertEqual(#ActionCache.getXrayCheckpoints(DOC_PATH), 1, "old version archived")
end)

TestRunner:test("applyXray: content-form base + base_entry keeps flags and coverage floor", function()
    wipe()
    local entry = {
        result = '{"characters":[{"name":"Jack","description":"v1"}]}',
        progress_decimal = 0.5, used_book_text = true, timestamp = 1700000065,
    }
    ActionCache.setXrayCache(DOC_PATH, entry.result, entry.progress_decimal, entry)
    -- Caller passes the JSON STRING as content base (the shape it fed the
    -- model) — flags/floor must come from base_entry, not silently drop
    local ok = WriteBack.applyXray({
        document_path = DOC_PATH,
        answer = '{"characters":[{"name":"Jack","description":"v2"}]}',
        base = entry.result,
        base_entry = entry,
        progress_decimal = 0.2,
        meta = { used_book_text = false },
        limit = 5,
    })
    TestRunner:assertEqual(ok, true, "apply succeeds")
    local live = ActionCache.getXrayCache(DOC_PATH)
    TestRunner:assertEqual(live.used_book_text, true, "flag NOT downgraded (read-gate leak guard)")
    TestRunner:assertEqual(live.progress_decimal, 0.5, "coverage floor from base_entry")
end)

TestRunner:test("applyXray refuses refusals and garbage without touching the cache", function()
    wipe()
    ActionCache.setXrayCache(DOC_PATH, '{"keep": 1}', 0.2, { timestamp = 1700000070 })
    local ok, err = WriteBack.applyXray({
        document_path = DOC_PATH, answer = '{"error":"cannot analyze"}',
    })
    TestRunner:assertEqual(ok, false, "refusal fails")
    TestRunner:assertEqual(err, "cannot analyze", "refusal text returned")
    TestRunner:assertEqual(ActionCache.getXrayCache(DOC_PATH).result, '{"keep": 1}', "cache untouched")
    local ok2 = WriteBack.applyXray({ document_path = DOC_PATH })
    TestRunner:assertEqual(ok2, false, "missing answer refused")
end)

TestRunner:test("isXrayLadderRung: identity is timestamp + progress", function()
    wipe()
    ActionCache.pushXrayLadderRung(DOC_PATH, {
        result = '{"rung": 60}', progress_decimal = 0.6, timestamp = 1700000080,
    })
    TestRunner:assertEqual(
        ActionCache.isXrayLadderRung(DOC_PATH, { timestamp = 1700000080, progress_decimal = 0.6 }),
        true, "matching entry is a rung")
    TestRunner:assertEqual(
        ActionCache.isXrayLadderRung(DOC_PATH, { timestamp = 1700000080, progress_decimal = 0.5 }),
        false, "same timestamp, different progress: not a rung")
    TestRunner:assertEqual(
        ActionCache.isXrayLadderRung(DOC_PATH, { timestamp = 1, progress_decimal = 0.6 }),
        false, "different timestamp: not a rung")
    TestRunner:assertEqual(ActionCache.isXrayLadderRung(DOC_PATH, nil), false, "nil entry safe")
end)

print("")
print("  [coverage spans — timeline slice 1 (plan item 37(b))]")

TestRunner:test("parseSpans normalizes: sort, merge overlaps AND adjacents, drop invalid", function()
    local norm = WriteBack.parseSpans("60-80, 1-40, 30-50, 51-55, 0-3, 9-7")
    TestRunner:assertEqual(#norm, 2, "two merged spans")
    TestRunner:assertEqual(norm[1].from, 1, "first span start")
    TestRunner:assertEqual(norm[1].to, 55, "overlap (30-50) + adjacent (51-55) chain fuses to 1-55")
    TestRunner:assertEqual(norm[2].from, 60, "hole 56-59 preserved")
    TestRunner:assertEqual(norm[2].to, 80, "second span end")
    TestRunner:assertEqual(#WriteBack.parseSpans(nil), 0, "nil is empty")
    TestRunner:assertEqual(#WriteBack.parseSpans("garbage"), 0, "garbage is empty")
end)

TestRunner:test("formatSpans canonical string; nil for empty", function()
    TestRunner:assertEqual(WriteBack.formatSpans("60-80,1-40"), "1-40,60-80", "canonical order")
    TestRunner:assertEqual(WriteBack.formatSpans({ { from = 1, to = 10 }, { from = 11, to = 20 } }),
        "1-20", "adjacent spans fuse")
    TestRunner:assertEqual(WriteBack.formatSpans(nil), nil, "empty set omitted, never stored as \"\"")
end)

TestRunner:test("unionSpans: prefix chain fuses; holes survive union", function()
    TestRunner:assertEqual(WriteBack.unionSpans("1-200", "201-250"), "1-250", "delta extends the prefix")
    TestRunner:assertEqual(WriteBack.unionSpans("1-100,150-200", "201-250"),
        "1-100,150-250", "the 101-149 hole is preserved — merged coverage never overstates")
    TestRunner:assertEqual(WriteBack.unionSpans(nil, "1-40"), "1-40", "nil side is identity")
    TestRunner:assertEqual(WriteBack.unionSpans(nil, nil), nil, "both nil stays nil")
end)

TestRunner:test("prefixCoverage: computed pointer eligibility (item 37(a))", function()
    TestRunner:assertEqual(WriteBack.prefixCoverage("1-120"), 120, "prefix point eligible")
    TestRunner:assertEqual(WriteBack.prefixCoverage("1-100,150-200"), 100,
        "eligible only to the first hole")
    TestRunner:assertEqual(WriteBack.prefixCoverage("40-60"), nil,
        "section span is a member, never a pointer candidate")
    TestRunner:assertEqual(WriteBack.prefixCoverage(nil), nil, "no spans, no eligibility")
end)

TestRunner:test("spanGaps: leading/middle/tail holes; empty spans yield NO gaps", function()
    local gaps = WriteBack.spanGaps("10-20,30-40", 50)
    TestRunner:assertEqual(#gaps, 3, "leading + middle + tail")
    TestRunner:assertEqual(gaps[1].from, 1, "leading gap start")
    TestRunner:assertEqual(gaps[1].to, 9, "leading gap end")
    TestRunner:assertEqual(gaps[2].from, 21, "middle gap start")
    TestRunner:assertEqual(gaps[2].to, 29, "middle gap end")
    TestRunner:assertEqual(gaps[3].from, 41, "tail gap start")
    TestRunner:assertEqual(gaps[3].to, 50, "tail gap end")
    TestRunner:assertEqual(#WriteBack.spanGaps("1-50", 50), 0, "full coverage, no gaps")
    TestRunner:assertEqual(#WriteBack.spanGaps(nil, 300), 0,
        "unknown coverage must not read as everything-missing")
end)

TestRunner:test("spansFromEntry: stamped wins; sections beat full_document; legacy prefix; intro claims nothing", function()
    TestRunner:assertEqual(WriteBack.spansFromEntry({ coverage_spans = "5-10,1-4" }), "1-10",
        "stamped field wins, normalized")
    TestRunner:assertEqual(
        WriteBack.spansFromEntry({ scope_start_page = 40, scope_end_page = 60, full_document = true }),
        "40-60", "section scope beats its scope-complete full_document marker")
    TestRunner:assertEqual(WriteBack.spansFromEntry({ full_document = true }, 320), "1-320",
        "whole-book claim resolves against a known total")
    TestRunner:assertEqual(WriteBack.spansFromEntry({ full_document = true }), nil,
        "whole-book claim without a total derives nothing (flag remains authoritative)")
    TestRunner:assertEqual(WriteBack.spansFromEntry({ progress_decimal = 1.0 }, 320), "1-320",
        "terminal incremental = whole-book claim")
    TestRunner:assertEqual(WriteBack.spansFromEntry({ progress_page = 123, progress_decimal = 0.4 }),
        "1-123", "legacy prefix claim")
    TestRunner:assertEqual(WriteBack.spansFromEntry({ intro = true, progress_page = 0, progress_decimal = 0 }),
        nil, "intro rung claims no coverage")
    TestRunner:assertEqual(WriteBack.spansFromEntry(nil), nil, "nil entry safe")
end)

TestRunner:test("reconcileXrayMeta unions spans with the base and defaults base_timestamp", function()
    local meta = WriteBack.reconcileXrayMeta(
        { coverage_spans = "1-100,150-200", timestamp = 1700000123 },
        { coverage_spans = "201-250", producer = "section_merge" })
    TestRunner:assertEqual(meta.coverage_spans, "1-100,150-250", "union with base, hole kept")
    TestRunner:assertEqual(meta.base_timestamp, 1700000123, "base identity defaulted")
    TestRunner:assertEqual(meta.producer, "section_merge", "producer never inherited, caller's value kept")
    -- Legacy base without stamped spans contributes its prefix claim
    local meta2 = WriteBack.reconcileXrayMeta(
        { progress_page = 120, progress_decimal = 0.4 }, {})
    TestRunner:assertEqual(meta2.coverage_spans, "1-120", "legacy base derives through")
    -- Fresh write: nothing invented
    local meta3 = WriteBack.reconcileXrayMeta(nil, { model = "m" })
    TestRunner:assertEqual(meta3.coverage_spans, nil, "no base, no spans")
    TestRunner:assertEqual(meta3.base_timestamp, nil, "no base, no base identity")
end)

TestRunner:test("merged_from_books inherits through later passes (item 43 continuity)", function()
    local meta = WriteBack.reconcileXrayMeta(
        { merged_from_books = "Book One" }, { model = "m" })
    TestRunner:assertEqual(meta.merged_from_books, "Book One",
        "cross-book background provenance survives updates")
end)

TestRunner:test("spans + provenance survive the rung → ring → live round-trip", function()
    wipe()
    -- Rung with stamped spans/provenance
    ActionCache.pushXrayLadderRung(DOC_PATH, {
        result = '{"rung": 1}', progress_decimal = 0.4, progress_page = 120,
        timestamp = 1700000200, coverage_spans = "1-120", producer = "ladder",
        base_timestamp = 1700000100,
    })
    local ladder = ActionCache.getXrayLadder(DOC_PATH)
    TestRunner:assertEqual(ladder[1].coverage_spans, "1-120", "rung keeps spans on disk")
    TestRunner:assertEqual(ladder[1].producer, "ladder", "rung keeps producer")
    TestRunner:assertEqual(ladder[1].base_timestamp, 1700000100, "rung keeps base identity")
    -- Promotion carries the point's own provenance into the live entry
    ActionCache.promoteXrayLadderRung(DOC_PATH, ladder[1], 5, { manual = true })
    local live = ActionCache.getXrayCache(DOC_PATH)
    TestRunner:assertEqual(live.coverage_spans, "1-120", "promoted live keeps spans")
    TestRunner:assertEqual(live.producer, "ladder", "promotion keeps the point's producer")
    TestRunner:assertEqual(live.base_timestamp, 1700000100, "promotion keeps base identity")
    -- Ring archive on a later overwrite keeps the fields too
    -- The outgoing live IS a rung → not ring-archived (shared archive rule);
    -- overwrite twice so a non-rung entry lands in the ring
    WriteBack.commitXray(DOC_PATH, '{"live": 2}', 0.5,
        { coverage_spans = "1-150", producer = "manual", base_timestamp = 1700000200 }, { limit = 5 })
    WriteBack.commitXray(DOC_PATH, '{"live": 3}', 0.6,
        { coverage_spans = "1-180", producer = "auto", base_timestamp = 1700000300 }, { limit = 5 })
    local ring = ActionCache.getXrayCheckpoints(DOC_PATH)
    TestRunner:assertEqual(ring[1].coverage_spans, "1-150", "ring checkpoint keeps spans")
    TestRunner:assertEqual(ring[1].producer, "manual", "ring checkpoint keeps producer")
    TestRunner:assertEqual(ring[1].base_timestamp, 1700000200, "ring checkpoint keeps base identity")
end)

TestRunner:test("restore does not ring-archive a live that IS a rung (item 40 dup fix)", function()
    wipe()
    -- Manual-fold shape (slice 2): live == rung identity at 17%
    ActionCache.pushXrayLadderRung(DOC_PATH, {
        result = '{"v": 17}', progress_decimal = 0.17, timestamp = 1700000300, producer = "manual",
    })
    ActionCache.setXrayCache(DOC_PATH, '{"v": 17}', 0.17, { timestamp = 1700000300 })
    ActionCache.set(DOC_PATH, "xray", '{"v": 17}', 0.17, { timestamp = 1700000300 })
    -- A newer 35% version sits in the ring (an overwritten non-rung product)
    ActionCache.pushXrayCheckpoint(DOC_PATH, {
        result = '{"v": 35}', progress_decimal = 0.35, timestamp = 1700000400,
    }, 5)
    -- Reinstall the 35% from the ring: the outgoing 17% live IS a ladder rung
    -- and must NOT be ring-archived (the device round saw "17% today" AND
    -- "17% today · checkpoint" from exactly this move)
    local ok_restore = ActionCache.restoreXrayCheckpoint(DOC_PATH, 1, 5)
    TestRunner:assertEqual(ok_restore, true, "restore succeeds")
    TestRunner:assertEqual(#ActionCache.getXrayCheckpoints(DOC_PATH), 0,
        "ring emptied: the rung-live was not duplicated into it")
    local live = ActionCache.getXrayCache(DOC_PATH)
    TestRunner:assertEqual(live.timestamp, 1700000400, "the 35% is live again")
    TestRunner:assertEqual(#ActionCache.getXrayLadder(DOC_PATH), 1,
        "the 17% stays preserved as its ladder point")
end)

print("")
print("  [reader edits replay into built checkpoints (B267, B394 slice 6)]")

local function rungJson(chars)
    return require("json").encode({ type = "fiction", characters = chars })
end

TestRunner:test("applyToRungs: a rename reaches the checkpoints that hold the old name, and only those", function()
    local XrayParser = require("koassistant_xray_parser")
    local rungs = {
        { result = rungJson({ { name = "The Stranger", description = "a" } }), progress_decimal = 0.2, timestamp = 11 },
        { result = rungJson({ { name = "Someone Else", description = "b" } }), progress_decimal = 0.3, timestamp = 12 },
        { result = rungJson({ { name = "The Stranger", description = "c" },
                              { name = "Mara Cole", description = "already here" } }), progress_decimal = 0.4, timestamp = 13 },
        { result = rungJson({ { name = "The Stranger", description = "intro" } }), intro = true, timestamp = 14 },
        { result = "not json", progress_decimal = 0.5 },
    }
    local n = WriteBack.applyToRungs(rungs, WriteBack.renameEdit("characters", "The Stranger", "Mara Cole"))
    TestRunner:assertEqual(n, 1, "one checkpoint rewritten")
    local first = XrayParser.parse(rungs[1].result)
    TestRunner:assertEqual(first.characters[1].name, "Mara Cole", "renamed")
    TestRunner:assertEqual(first.characters[1].aliases[1], "The Stranger", "the old name stays as an alias")
    TestRunner:assertTrue(rungs[1].edited_at ~= nil, "stamped as reader-modified")
    TestRunner:assertEqual(rungs[1].timestamp, 11, "its identity (timestamp, progress) is untouched")
    TestRunner:assertEqual(rungs[2].edited_at, nil, "a checkpoint without the entry is left alone")
    TestRunner:assertEqual(rungs[3].edited_at, nil, "one that already has the new name is left alone (no two entries of one name)")
    TestRunner:assertEqual(XrayParser.parse(rungs[3].result).characters[1].name, "The Stranger")
    TestRunner:assertEqual(rungs[4].edited_at, nil, "the introduction is never rewritten")
    TestRunner:assertEqual(rungs[5].result, "not json", "an unreadable checkpoint is skipped")
    TestRunner:assertEqual(WriteBack.applyToRungs(rungs, WriteBack.renameEdit("characters", "The Stranger", "Mara Cole")), 0,
        "a second replay finds nothing to do")
end)

TestRunner:test("applyToRungs: a link adds the other book's names once", function()
    local XrayParser = require("koassistant_xray_parser")
    local rungs = {
        { result = rungJson({ { name = "Mara", aliases = { "the Keeper" }, description = "a" } }), progress_decimal = 0.2 },
        { result = rungJson({ { name = "Other", description = "b" } }), progress_decimal = 0.3 },
    }
    local edit = WriteBack.aliasEdit("characters", "Mara", { "Mara Alvsund", "the Keeper" })
    TestRunner:assertEqual(WriteBack.applyToRungs(rungs, edit), 1)
    local data = XrayParser.parse(rungs[1].result)
    TestRunner:assertEqual(table.concat(data.characters[1].aliases, ","), "the Keeper,Mara Alvsund", "only the new name is added")
    TestRunner:assertEqual(WriteBack.applyToRungs(rungs, edit), 0, "nothing new the second time: not rewritten, not re-stamped")
end)

TestRunner:test("replayIntoRungs: the stored checkpoints are rewritten on disk", function()
    wipe()
    ActionCache.pushXrayLadderRung(DOC_PATH, {
        result = rungJson({ { name = "The Stranger", description = "built ahead" } }),
        progress_decimal = 0.4, timestamp = 1700000900, producer = "auto",
    })
    TestRunner:assertEqual(WriteBack.replayIntoRungs(DOC_PATH,
        WriteBack.renameEdit("characters", "The Stranger", "Mara Cole")), 1)
    local stored = ActionCache.getXrayLadder(DOC_PATH)
    TestRunner:assertEqual(#stored, 1, "still one checkpoint")
    TestRunner:assertTrue(stored[1].result:find("Mara Cole", 1, true) ~= nil, "the install will carry the new name")
    TestRunner:assertEqual(stored[1].timestamp, 1700000900, "same checkpoint")
    TestRunner:assertEqual(WriteBack.replayIntoRungs("/nowhere/none.epub",
        WriteBack.renameEdit("characters", "A", "B")), 0, "a book with no checkpoints is a quiet no-op")
end)

wipe()
os.execute(string.format("rm -rf %q", TMP_ROOT))

local ok = TestRunner:summary()
return ok
