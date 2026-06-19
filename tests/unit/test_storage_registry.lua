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

TestRunner:test("SETTINGS_SUBKEYS has the three non-config buckets, non-empty", function()
    for _, bucket in ipairs({ "credentials", "assets", "internal" }) do
        local list = Registry.SETTINGS_SUBKEYS[bucket]
        TestRunner:assertTrue(type(list) == "table" and #list > 0,
            "SETTINGS_SUBKEYS." .. bucket .. " must be a non-empty list")
    end
end)

TestRunner:test("api_keys is classified as a credential sub-key", function()
    local found = false
    for _, k in ipairs(Registry.SETTINGS_SUBKEYS.credentials) do
        if k == "api_keys" then found = true end
    end
    TestRunner:assertTrue(found, "api_keys must be in SETTINGS_SUBKEYS.credentials")
end)

TestRunner:test("unprefixed global keys are declared", function()
    TestRunner:assertTrue(#Registry.UNPREFIXED_GLOBAL_KEYS >= 2,
        "expected the two unprefixed chat_* keys")
end)

return TestRunner:summary()
