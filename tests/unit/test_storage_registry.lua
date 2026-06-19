-- Unit tests for koassistant_storage_registry.lua (Track 33).
-- Guards that the registry stays the single source of truth:
--   * schema validity + unique ids
--   * the consumed accessors still equal the pre-refactor hardcoded lists
--     (proves Phase 1 is a no-behavior-change refactor)
--   * a source-literal scan: every getSettingsDir()/getDataDir() "koassistant_*"
--     path in the codebase is registered (catches new storage added without
--     registering it — the historical drift bug)
-- No API calls.
--
-- Run: lua tests/run_tests.lua --unit

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

    return plugin_dir, tests_dir
end

local PLUGIN_DIR = setupPaths()

require("mock_koreader")

-- Earlier suite files (e.g. test_storage_modes) juggle package.loaded["datastorage"]
-- and can leave it in an odd state. Pin a known-good DataStorage so resolvePath()
-- is deterministic regardless of run order. (The registry resolves datastorage
-- lazily at call time, so this is all that's needed.)
package.loaded["datastorage"] = {
    getDataDir = function() return "/tmp/koreader" end,
    getSettingsDir = function() return "/tmp/koreader/settings" end,
}

local TestRunner = {
    passed = 0,
    failed = 0,
    current_suite = "",
}

function TestRunner:suite(name)
    self.current_suite = name
    print(string.format("\n  [%s]", name))
end

function TestRunner:test(name, fn)
    local ok, err = pcall(fn)
    if ok then
        self.passed = self.passed + 1
        print(string.format("    \226\156\147 %s", name))
    else
        self.failed = self.failed + 1
        print(string.format("    \226\156\151 %s", name))
        print(string.format("      Error: %s", tostring(err)))
    end
end

function TestRunner:assertEqual(actual, expected, msg)
    if actual ~= expected then
        error(string.format("%s: expected %s, got %s", msg or "Assertion failed", tostring(expected), tostring(actual)))
    end
end

function TestRunner:assertTrue(value, msg)
    if not value then
        error(string.format("%s: expected true", msg or "Assertion failed"))
    end
end

function TestRunner:summary()
    print("")
    print(string.rep("-", 50))
    local total = self.passed + self.failed
    if self.failed == 0 then
        print(string.format("  All %d tests passed!", total))
    else
        print(string.format("  %d/%d tests passed, %d failed", self.passed, total, self.failed))
    end
    return self.failed == 0
end

local function assertListEqual(actual, expected, msg)
    assert(type(actual) == "table", (msg or "") .. ": actual is not a table")
    if #actual ~= #expected then
        error(string.format("%s: length %d != expected %d (got: %s)",
            msg or "list mismatch", #actual, #expected, table.concat(actual, ", ")))
    end
    for i = 1, #expected do
        if actual[i] ~= expected[i] then
            error(string.format("%s: index %d: expected %q, got %q",
                msg or "list mismatch", i, tostring(expected[i]), tostring(actual[i])))
        end
    end
end

local Registry = require("koassistant_storage_registry")

print("")
print(string.rep("=", 50))
print("  Unit Tests: Storage Registry (Track 33)")
print(string.rep("=", 50))

--------------------------------------------------------------------------------
TestRunner:suite("Schema")

local VALID_LOCATIONS = {
    settings_dir = true, settings_subkey = true, global_key = true,
    sidecar_file = true, sidecar_dockey = true, plugin_file = true,
    plugin_dir = true, data_dir = true,
}
local VALID_CATEGORIES = {
    credentials = true, config = true, assets = true, conversations = true,
    artifacts = true, notebooks = true, exports = true, backups = true,
    index = true, internal = true,
}

TestRunner:test("every entry has required fields with valid enums", function()
    for _, e in ipairs(Registry.all()) do
        TestRunner:assertTrue(type(e.id) == "string" and #e.id > 0, "entry missing id")
        TestRunner:assertTrue(type(e.label) == "string" and #e.label > 0, "entry " .. tostring(e.id) .. " missing label")
        TestRunner:assertTrue(VALID_LOCATIONS[e.location], "entry " .. e.id .. " bad location: " .. tostring(e.location))
        TestRunner:assertTrue(VALID_CATEGORIES[e.category], "entry " .. e.id .. " bad category: " .. tostring(e.category))
        TestRunner:assertTrue(type(e.ref) == "string" or type(e.ref) == "function",
            "entry " .. e.id .. " ref must be string or function")
    end
end)

TestRunner:test("entry ids are unique", function()
    local seen = {}
    for _, e in ipairs(Registry.all()) do
        TestRunner:assertTrue(not seen[e.id], "duplicate entry id: " .. tostring(e.id))
        seen[e.id] = true
    end
end)

--------------------------------------------------------------------------------
TestRunner:suite("Accessors match pre-refactor lists (no behavior change)")

TestRunner:test("updateFiles() == old USER_FILES", function()
    assertListEqual(Registry.updateFiles(),
        { "apikeys.lua", "configuration.lua", "custom_actions.lua" }, "updateFiles")
end)

TestRunner:test("updateDirs() == old USER_DIRS", function()
    assertListEqual(Registry.updateDirs(), { "behaviors", "domains" }, "updateDirs")
end)

TestRunner:test("sidecarFiles() == old KOASSISTANT_SIDECAR_FILES", function()
    assertListEqual(Registry.sidecarFiles(), {
        "koassistant_notebook.md", "koassistant_cache.lua",
        "koassistant_user_aliases.lua", "koassistant_pinned.lua",
    }, "sidecarFiles")
end)

TestRunner:test("indexKeys() == old KOASSISTANT_INDICES", function()
    assertListEqual(Registry.indexKeys(), {
        "koassistant_chat_index", "koassistant_notebook_index",
        "koassistant_artifact_index", "koassistant_pinned_index",
    }, "indexKeys")
end)

--------------------------------------------------------------------------------
TestRunner:suite("Known inventory present")

-- A removal-guard: these entries must always exist. Adding new entries is fine;
-- silently dropping one fails here.
local REQUIRED_IDS = {
    "settings", "general_chats", "library_chats", "last_opened",
    "pinned_general", "pinned_library",
    "chat_index", "notebook_index", "artifact_index", "pinned_index",
    "artifact_index_version", "chat_storage_version", "chat_migration_in_progress",
    "sidecar_notebook", "sidecar_cache", "sidecar_user_aliases", "sidecar_pinned",
    "dockey_book_settings", "dockey_chats", "dockey_notebook_ref", "dockey_doi",
    "apikeys", "configuration", "custom_actions", "behaviors_dir", "domains_dir",
    "chats_v1_dir", "chats_backup_dir", "backups_dir", "exports_dir",
    "notebooks_vault_dir",
}

TestRunner:test("all required entry ids exist", function()
    local by_id = {}
    for _, e in ipairs(Registry.all()) do by_id[e.id] = true end
    for _, id in ipairs(REQUIRED_IDS) do
        TestRunner:assertTrue(by_id[id], "missing required registry entry: " .. id)
    end
end)

TestRunner:test("backups dir is never auto-deleted (invariant)", function()
    for _, e in ipairs(Registry.all()) do
        if e.id == "backups_dir" then
            TestRunner:assertTrue(e.uninstall ~= true, "backups_dir must not be removed by uninstall")
            TestRunner:assertTrue(e.reset_in == nil or #e.reset_in == 0, "backups_dir must not be in any reset preset")
        end
    end
end)

--------------------------------------------------------------------------------
TestRunner:suite("Coverage guard (source-literal scan)")

-- Every getSettingsDir()/getDataDir() "/koassistant_*" path literal in the
-- codebase must map to a registered settings_dir/data_dir entry. This is the
-- drift catcher: add a new settings/data file without registering it -> fail.
local function scanStorageLiterals(plugin_dir)
    local cmd = string.format(
        'grep -rhE "getSettingsDir|getDataDir" --include="*.lua" '
        .. '--exclude="koassistant_storage_registry.lua" --exclude-dir=tests %q 2>/dev/null',
        plugin_dir)
    local handle = io.popen(cmd)
    if not handle then return {} end
    local out = handle:read("*a") or ""
    handle:close()
    local found = {}
    -- Anchor on the leading slash of a path literal to avoid bare comment mentions.
    for token in out:gmatch('/(koassistant_[%w_]+)') do
        found[token] = true
    end
    return found
end

TestRunner:test("every settings/data koassistant_* literal is registered", function()
    -- Registry stems for settings_dir/data_dir entries (strip the .lua suffix).
    local registered = {}
    for _, e in ipairs(Registry.all()) do
        if e.location == "settings_dir" or e.location == "data_dir" then
            registered[(e.ref:gsub("%.lua$", ""))] = true
        end
    end

    local found = scanStorageLiterals(PLUGIN_DIR)
    local count = 0
    local missing = {}
    for token in pairs(found) do
        count = count + 1
        if not registered[token] then missing[#missing + 1] = token end
    end

    -- Guard against a broken grep silently passing the test.
    TestRunner:assertTrue(count >= 5,
        "source scan found too few literals (" .. count .. ") — grep likely failed")
    TestRunner:assertTrue(#missing == 0,
        "unregistered storage literals found: " .. table.concat(missing, ", "))
end)

--------------------------------------------------------------------------------
TestRunner:suite("Settings sub-key categories")

local function listContains(list, val)
    for _, v in ipairs(list) do
        if v == val then return true end
    end
    return false
end

TestRunner:test("SETTINGS_SUBKEYS has the five non-config buckets, non-empty", function()
    for _, bucket in ipairs({ "credentials", "assets", "languages", "preferences", "internal" }) do
        local list = Registry.SETTINGS_SUBKEYS[bucket]
        TestRunner:assertTrue(type(list) == "table" and #list > 0,
            "SETTINGS_SUBKEYS." .. bucket .. " must be a non-empty list")
    end
end)

TestRunner:test("api_keys is classified as a credential sub-key", function()
    TestRunner:assertTrue(listContains(Registry.SETTINGS_SUBKEYS.credentials, "api_keys"),
        "api_keys must be in SETTINGS_SUBKEYS.credentials")
end)

TestRunner:test("custom_domains is an asset (consistency with custom_behaviors)", function()
    TestRunner:assertTrue(listContains(Registry.SETTINGS_SUBKEYS.assets, "custom_domains"),
        "custom_domains must be an asset")
    TestRunner:assertTrue(listContains(Registry.SETTINGS_SUBKEYS.assets, "custom_behaviors"),
        "custom_behaviors must be an asset")
end)

TestRunner:test("unprefixed global keys are declared", function()
    TestRunner:assertTrue(#Registry.UNPREFIXED_GLOBAL_KEYS >= 2,
        "expected the two unprefixed chat_* keys")
end)

--------------------------------------------------------------------------------
TestRunner:suite("Reset preserve-lists (behavior contract)")

TestRunner:test("settingsResetPreserve keeps credentials/assets/languages/preferences/internal", function()
    local p = Registry.settingsResetPreserve()
    for _, key in ipairs({
        "features.api_keys", "features.custom_behaviors", "features.custom_domains",
        "features.primary_language",  -- languages preserved
        "features.selected_behavior", "features.gesture_actions",  -- preferences preserved
        "features._reasoning_v2_migrated",  -- bug fix: reasoning flags survive resets
    }) do
        TestRunner:assertTrue(listContains(p, key), "Reset Settings must preserve " .. key)
    end
end)

TestRunner:test("settingsResetPreserve excludes top-level sub-keys", function()
    local p = Registry.settingsResetPreserve()
    -- custom_actions / setup_wizard_completed are top-level; applyDefaults only
    -- touches the features table, so they must NOT appear as features.* paths.
    TestRunner:assertTrue(not listContains(p, "features.custom_actions"),
        "custom_actions is top-level, must not be a features.* preserve path")
    TestRunner:assertTrue(not listContains(p, "features.setup_wizard_completed"),
        "setup_wizard_completed is top-level, must not be a features.* preserve path")
end)

TestRunner:test("freshStartPreserve is clean-slate: wipes custom assets + preferences, keeps languages + flags", function()
    local p = Registry.freshStartPreserve()
    -- Clean-slate: custom assets and preferences are NOT preserved (wiped).
    for _, key in ipairs({
        "features.custom_behaviors", "features.custom_domains",
        "features.custom_providers", "features.custom_models",
        "features.selected_behavior", "features.gesture_actions",
    }) do
        TestRunner:assertTrue(not listContains(p, key), "Fresh Start must reset " .. key)
    end
    -- Kept: credentials, languages, and internal migration flags (reasoning bug fix).
    TestRunner:assertTrue(listContains(p, "features.api_keys"), "Fresh Start keeps API keys")
    TestRunner:assertTrue(listContains(p, "features.primary_language"), "Fresh Start keeps languages")
    TestRunner:assertTrue(listContains(p, "features._reasoning_v2_migrated"),
        "Fresh Start must preserve reasoning migration flags (bug fix)")
end)

TestRunner:test("resetEntries(fresh_start) clears only internal data-dir cruft", function()
    local ids = {}
    for _, e in ipairs(Registry.resetEntries("fresh_start")) do ids[e.id] = true end
    TestRunner:assertTrue(ids["chats_v1_dir"], "fresh_start should clear v1 chats dir")
    TestRunner:assertTrue(ids["chats_backup_dir"], "fresh_start should clear chats.backup dir")
    -- Must NOT force-clear conversations/backups via this path.
    TestRunner:assertTrue(not ids["general_chats"], "fresh_start must not force-clear chats")
    TestRunner:assertTrue(not ids["backups_dir"], "fresh_start must never touch backups")
end)

TestRunner:test("resetEntries(wipe_all) includes content + settings but never backups", function()
    local ids = {}
    for _, e in ipairs(Registry.resetEntries("wipe_all")) do ids[e.id] = true end
    TestRunner:assertTrue(ids["settings"], "wipe_all clears settings file")
    TestRunner:assertTrue(ids["general_chats"], "wipe_all clears general chats")
    TestRunner:assertTrue(ids["chat_index"], "wipe_all clears indexes")
    TestRunner:assertTrue(not ids["backups_dir"], "wipe_all must never touch backups")
    TestRunner:assertTrue(not ids["exports_dir"], "exports are opt-in, not force-cleared by wipe_all")
end)

--------------------------------------------------------------------------------
TestRunner:suite("Path resolution")

-- resolvePath is the registry's path resolver, consumed by backup enumeration
-- (Phase 4) and the future in-plugin wipe.
TestRunner:test("resolvePath maps settings_dir/data_dir entries to absolute paths", function()
    local n = 0
    for _, e in ipairs(Registry.all()) do
        if e.location == "settings_dir" or e.location == "data_dir" then
            local p = Registry.resolvePath(e)
            TestRunner:assertTrue(type(p) == "string" and p:sub(1, #"/tmp/koreader") == "/tmp/koreader",
                "resolvePath(" .. e.id .. ") should be absolute under the data dir, got " .. tostring(p))
            n = n + 1
        end
    end
    TestRunner:assertTrue(n >= 6, "expected several settings/data entries to resolve")
end)

TestRunner:test("resolvePath returns nil for keys and sidecar entries", function()
    for _, e in ipairs(Registry.all()) do
        if e.location == "global_key" or e.location == "sidecar_dockey" or e.location == "sidecar_file" then
            TestRunner:assertTrue(Registry.resolvePath(e) == nil,
                "resolvePath(" .. e.id .. ") should be nil for " .. e.location)
        end
    end
end)

return TestRunner:summary()
