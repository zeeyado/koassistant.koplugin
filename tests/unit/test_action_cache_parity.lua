--[[
Unit tests: ActionCache set() / saveCache() / loadCache field parity (real round-trip)

Guards the documented gotcha (CLAUDE.md "Cache Field Parity"; audit v0.20.0 finding C3):
the manual field-by-field serializer means a field can exist in set()'s entry table but
be silently dropped on disk (or never enter the entry at all — the used_highlights bug).
These tests write an entry with EVERY documented metadata field through the REAL module
into a real temp sidecar dir, reload it from disk, and diff.

Run: lua tests/unit/test_action_cache_parity.lua  (auto-discovered by run_tests.lua --unit)
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

-- Real temp sidecar dir for the round-trip
local TMP_ROOT = "/tmp/koassistant_parity_test_" .. tostring(os.time()) .. "_" .. tostring(math.random(10000))
local SIDECAR_DIR = TMP_ROOT .. "/book.sdr"
local DOC_PATH = TMP_ROOT .. "/book.epub"
os.execute(string.format("mkdir -p %q", SIDECAR_DIR))

-- Module cache reset BEFORE installing mocks (matters when run via run_tests.lua)
package.loaded["koassistant_action_cache"] = nil
package.loaded["koassistant_gettext"] = nil
package.loaded["docsettings"] = nil
package.loaded["util"] = nil
package.loaded["luasettings"] = nil

require("mock_koreader")

-- Minimal mocks the module needs (installed after mock_koreader so they win)
_G.G_reader_settings = {
    _store = {},
    readSetting = function(self, key, default)
        if key == "document_metadata_folder" then return "doc" end
        local v = self._store[key]
        if v == nil then return default end
        return v
    end,
    saveSetting = function(self, key, value) self._store[key] = value end,
    flush = function() end,
}
package.loaded["docsettings"] = {
    getSidecarDir = function(_self, _doc_path, _force_location) return SIDECAR_DIR end,
    isHashLocationEnabled = function() return false end,
}
package.loaded["util"] = {
    makePath = function(dir) os.execute(string.format("mkdir -p %q", dir)) end,
}
package.loaded["luasettings"] = {
    open = function() return { readSetting = function() return nil end, close = function() end } end,
}

local ActionCache = require("koassistant_action_cache")
local TestRunner = require("test_runner"):new()

print("Running: test_action_cache_parity")
print("")
print("  [ActionCache set/save/load round-trip parity]")

-- Every metadata field set() documents/stores. If you add a field to set(),
-- add it here — the parity tests below will then force you to wire saveCache() too.
local FULL_METADATA = {
    model = "test-model-1",
    used_highlights = true,
    used_annotations = true,
    used_book_text = true,
    previous_progress_decimal = 0.25,
    flow_visible_pages = 310,
    progress_page = 123,
    full_document = true,
    used_reasoning = true,
    web_search_used = true,
    used_research_mode = true,
    source_mode = "full_text",
    unavailable_data_text = "highlights (sharing off)",
    scope_label = "Chapter 3",
    scope_start_page = 40,
    scope_end_page = 60,
    scope_start_xpointer = "/body/DocFragment[5]/body/p[1]",
    scope_end_xpointer = "/body/DocFragment[5]/body/p[99]",
    scope_page_summary = "pages 40-60",
}

local RESULT_TEXT = "Line one\nLine two with \"quotes\" and ]] brackets and ]=] tricky closer"

TestRunner:test("set() with every documented field survives a disk reload", function()
    assert(ActionCache.set(DOC_PATH, "xray", RESULT_TEXT, 0.5, FULL_METADATA),
        "set() should succeed")
    -- Force a genuine disk read (loadCache dofile's the file; no in-memory cache)
    local entry = ActionCache.get(DOC_PATH, "xray")
    assert(entry, "entry should reload from disk")
    TestRunner:assertEqual(entry.result, RESULT_TEXT, "result")
    TestRunner:assertEqual(entry.progress_decimal, 0.5, "progress_decimal")
    for field, expected in pairs(FULL_METADATA) do
        TestRunner:assertEqual(entry[field], expected, "field lost in round-trip: " .. field)
    end
end)

TestRunner:test("no undocumented keys appear on disk", function()
    local entry = ActionCache.get(DOC_PATH, "xray")
    local allowed = { progress_decimal = true, timestamp = true, version = true, result = true, quiz_state = true }
    for field in pairs(FULL_METADATA) do allowed[field] = true end
    for k in pairs(entry) do
        TestRunner:assertTrue(allowed[k], "unexpected key on disk (update FULL_METADATA?): " .. tostring(k))
    end
end)

TestRunner:test("permission flags: explicit false round-trips as false, not nil", function()
    -- nil vs false is load-bearing for the read gate (nil/legacy = permission required,
    -- false = data not used, no permission needed). Regression for audit finding C3.
    assert(ActionCache.set(DOC_PATH, "book_info", "AI-knowledge only", 1.0, {
        model = "m", used_highlights = false, used_annotations = false, used_book_text = false,
    }))
    local entry = ActionCache.get(DOC_PATH, "book_info")
    TestRunner:assertEqual(entry.used_highlights, false, "used_highlights false must persist")
    TestRunner:assertEqual(entry.used_annotations, false, "used_annotations false must persist")
    TestRunner:assertEqual(entry.used_book_text, false, "used_book_text false must persist")
end)

TestRunner:test("C3 regression: used_highlights=true persists (highlight revocation gate)", function()
    assert(ActionCache.setXrayCache(DOC_PATH, "xray with reader_engagement", 0.4, {
        model = "m", used_highlights = true, used_book_text = true,
    }))
    local entry = ActionCache.getXrayCache(DOC_PATH)
    TestRunner:assertEqual(entry.used_highlights, true,
        "used_highlights dropped -> highlight-derived cache readable after consent revoked")
end)

TestRunner:test("omitted metadata fields stay nil (no accidental defaults)", function()
    assert(ActionCache.set(DOC_PATH, "recap", "recap text", 0.3, { model = "m" }))
    local entry = ActionCache.get(DOC_PATH, "recap")
    TestRunner:assertEqual(entry.used_highlights, nil, "used_highlights should be nil when not passed")
    TestRunner:assertEqual(entry.used_book_text, nil, "used_book_text should be nil when not passed")
end)

TestRunner:test("updateField(quiz_state) round-trips nested tables", function()
    assert(ActionCache.set(DOC_PATH, "quiz", '{"questions":[]}', 1.0, { model = "m" }))
    assert(ActionCache.updateField(DOC_PATH, "quiz", "quiz_state", {
        answers = { [1] = "B", [3] = "A" },
        revealed = { [1] = true },
        correct = { [1] = true, [3] = false },
        current_index = 3,
        phase = "review",
    }))
    local entry = ActionCache.get(DOC_PATH, "quiz")
    assert(entry.quiz_state, "quiz_state should persist")
    TestRunner:assertEqual(entry.quiz_state.answers[1], "B", "answers[1]")
    TestRunner:assertEqual(entry.quiz_state.answers[3], "A", "answers[3]")
    TestRunner:assertEqual(entry.quiz_state.revealed[1], true, "revealed[1]")
    TestRunner:assertEqual(entry.quiz_state.correct[3], false, "correct[3]")
    TestRunner:assertEqual(entry.quiz_state.current_index, 3, "current_index")
    TestRunner:assertEqual(entry.quiz_state.phase, "review", "phase")
end)

-- Cleanup
os.execute(string.format("rm -rf %q", TMP_ROOT))

local ok = TestRunner:summary()
return ok
