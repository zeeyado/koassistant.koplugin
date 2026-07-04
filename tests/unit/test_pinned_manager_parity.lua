--[[
Unit tests: PinnedManager save/load long-string round-trip (real disk round-trip)

Guards audit v0.20.0 finding G3: writeLongString wrote the long-string closer with NO
leading guard newline, so a pinned result/user_prompt ending in "]==" fused into a
premature "]==]" -> dofile failed -> loadPinned returned {} -> the next addPin overwrote
the file, losing ALL pins in that context.

The fix adds a guard "\n" before the closer (write side) and strips exactly one trailing
newline from each long-string field (load side) so the round-trip stays lossless. These
tests exercise addPin -> disk -> getPinnedForDocument with adversarial content.

Run: lua tests/unit/test_pinned_manager_parity.lua  (auto-discovered by run_tests.lua --unit)
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
local TMP_ROOT = "/tmp/koassistant_pinned_parity_" .. tostring(os.time()) .. "_" .. tostring(math.random(10000))
local SIDECAR_DIR = TMP_ROOT .. "/book.sdr"
local DOC_PATH = TMP_ROOT .. "/book.epub"
os.execute(string.format("mkdir -p %q", SIDECAR_DIR))

-- Module cache reset BEFORE installing mocks (matters when run via run_tests.lua)
package.loaded["koassistant_pinned_manager"] = nil
package.loaded["docsettings"] = nil
package.loaded["util"] = nil

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

local PinnedManager = require("koassistant_pinned_manager")
local TestRunner = require("test_runner"):new()

print("Running: test_pinned_manager_parity")
print("")
print("  [PinnedManager save/load long-string round-trip]")

-- Reload the pins straight off disk (getPinnedForDocument -> loadPinned -> dofile),
-- then return the entry matching the given id.
local function reloadById(id)
    local pinned = PinnedManager.getPinnedForDocument(DOC_PATH)
    for _idx, entry in ipairs(pinned) do
        if entry.id == id then return entry end
    end
    return nil
end

TestRunner:test("content ending in ']==' survives the round-trip (the G3 corruption case)", function()
    -- Without the guard newline, writeLongString would emit "...]==" immediately followed by
    -- "]==]" -> the first "]==]" closes the string early -> dofile parse error -> total loss.
    local result = "Analysis line one\nLine two with \"quotes\" and a tricky tail ]=="
    local user_prompt = "explain this passage ]=="
    assert(PinnedManager.addPin(DOC_PATH, {
        id = "pin_tricky",
        action_id = "chat",
        action_text = "Chat",
        result = result,
        user_prompt = user_prompt,
        context_type = "book",
    }), "addPin should succeed")

    local entry = reloadById("pin_tricky")
    assert(entry, "tricky pin should reload from disk (not corrupted away)")
    TestRunner:assertEqual(entry.result, result, "result must round-trip exactly")
    TestRunner:assertEqual(entry.user_prompt, user_prompt, "user_prompt must round-trip exactly")
end)

TestRunner:test("plain content is not over-stripped (no phantom newline loss)", function()
    local result = "Plain result with no trailing bracket or newline"
    local user_prompt = "a normal question"
    assert(PinnedManager.addPin(DOC_PATH, {
        id = "pin_plain",
        action_id = "chat",
        action_text = "Chat",
        result = result,
        user_prompt = user_prompt,
        context_type = "book",
    }))
    local entry = reloadById("pin_plain")
    assert(entry, "plain pin should reload")
    TestRunner:assertEqual(entry.result, result, "plain result unchanged")
    TestRunner:assertEqual(entry.user_prompt, user_prompt, "plain user_prompt unchanged")
end)

TestRunner:test("content that legitimately ends in a newline round-trips losslessly", function()
    -- The guard adds a trailing "\n"; the load-side strip removes exactly one. A value that
    -- itself ends in "\n" must therefore still come back with its own newline intact.
    local result = "Ends with a real newline\n"
    assert(PinnedManager.addPin(DOC_PATH, {
        id = "pin_nl",
        action_id = "chat",
        action_text = "Chat",
        result = result,
        user_prompt = "q",
        context_type = "book",
    }))
    local entry = reloadById("pin_nl")
    assert(entry, "newline pin should reload")
    TestRunner:assertEqual(entry.result, result, "trailing newline must be preserved")
end)

TestRunner:test("multiple pins coexist after a tricky pin (file not overwritten)", function()
    -- Corruption manifested as loadPinned returning {} then the next addPin wiping the file.
    -- After the three adds above, all three (+ any earlier) must still be present.
    local pinned = PinnedManager.getPinnedForDocument(DOC_PATH)
    local ids = {}
    for _idx, e in ipairs(pinned) do ids[e.id] = true end
    TestRunner:assertTrue(ids["pin_tricky"], "pin_tricky present")
    TestRunner:assertTrue(ids["pin_plain"], "pin_plain present")
    TestRunner:assertTrue(ids["pin_nl"], "pin_nl present")
end)

-- Cleanup
os.execute(string.format("rm -rf %q", TMP_ROOT))

local ok = TestRunner:summary()
return ok
