-- Backup/restore round-trip harness (Track 33, Phase 4).
-- Runs the REAL BackupManager against a REAL temp filesystem (real lfs + the
-- backup code's own cp/tar via os.execute) so we can verify backup/restore work
-- end-to-end without manually exercising the on-device UI. Hermetic: everything
-- lives under a temp dir that's wiped before and after.
--
-- Run: lua tests/run_tests.lua --unit   (or: lua tests/unit/test_backup_roundtrip.lua)

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

setupPaths()
require("mock_koreader")

-- The backup manager does real filesystem work via real lfs + os.execute(cp/tar).
-- Wire the real luafilesystem in under KOReader's module name, and stub the one
-- module it requires at load that the mock lacks (docsettings — unused on the
-- no-chats path, just needs to be requireable).
-- Save anything we override in package.loaded so we can restore it at the end
-- (otherwise we'd pollute later suite files — the lesson from test_storage_modes).
local _saved = {
    lfs = package.loaded["libs/libkoreader-lfs"],
    docsettings = package.loaded["docsettings"],
    luasettings = package.loaded["luasettings"],
}
local function restoreMocks()
    package.loaded["libs/libkoreader-lfs"] = _saved.lfs
    package.loaded["docsettings"] = _saved.docsettings
    package.loaded["luasettings"] = _saved.luasettings
    package.loaded["koassistant_backup_manager"] = nil  -- we mutated its path fields
end

local has_lfs, real_lfs = pcall(require, "lfs")
package.loaded["libs/libkoreader-lfs"] = real_lfs
package.loaded["docsettings"] = package.loaded["docsettings"] or {}

-- Compact file-backed LuaSettings stub: reads a `return {...}` Lua file and
-- serializes back on flush. Enough fidelity for the settings round-trip and the
-- strip-api-keys / restore-merge paths.
local function serialize(v, indent)
    indent = indent or ""
    local t = type(v)
    if t == "string" then return string.format("%q", v) end
    if t == "number" or t == "boolean" then return tostring(v) end
    if t == "table" then
        local parts = { "{\n" }
        for k, val in pairs(v) do
            local key = type(k) == "string" and string.format("[%q]", k) or "[" .. tostring(k) .. "]"
            parts[#parts + 1] = indent .. "  " .. key .. " = " .. serialize(val, indent .. "  ") .. ",\n"
        end
        parts[#parts + 1] = indent .. "}"
        return table.concat(parts)
    end
    return "nil"
end
local LuaSettingsStub = {}
function LuaSettingsStub:open(path)
    local data = {}
    local f = io.open(path, "r")
    if f then
        local content = f:read("*a"); f:close()
        local chunk = load(content)
        if chunk then
            local ok, t = pcall(chunk)
            if ok and type(t) == "table" then data = t end
        end
    end
    return {
        data = data,
        readSetting = function(s, key, default)
            local val = s.data[key]; if val == nil then return default end; return val
        end,
        saveSetting = function(s, key, value) s.data[key] = value end,
        delSetting = function(s, key) s.data[key] = nil end,
        has = function(s, key) return s.data[key] ~= nil end,
        flush = function(s)
            local out = io.open(path, "w")
            if out then out:write("return " .. serialize(s.data) .. "\n"); out:close() end
        end,
    }
end
package.loaded["luasettings"] = LuaSettingsStub

local TestRunner = { passed = 0, failed = 0 }
function TestRunner:suite(name) print(string.format("\n  [%s]", name)) end
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
function TestRunner:assertTrue(v, msg) if not v then error(msg or "expected true", 2) end end
function TestRunner:summary()
    print("\n" .. string.rep("-", 50))
    if self.failed == 0 then print(string.format("  All %d tests passed!", self.passed))
    else print(string.format("  %d/%d tests passed, %d failed", self.passed, self.passed + self.failed, self.failed)) end
    return self.failed == 0
end

print("\n" .. string.rep("=", 50))
print("  Unit Tests: Backup/Restore Round-Trip (Track 33)")
print(string.rep("=", 50))

-- ── temp-FS helpers (real filesystem) ────────────────────────────────────────
local TMP = "/tmp/koa_backup_roundtrip_test"
local function sh(cmd) return os.execute(cmd) end
local function wipeTmp() sh(string.format('rm -rf "%s"', TMP)) end
local function mkdirs(path) sh(string.format('mkdir -p "%s"', path)) end
local function writeFile(path, content)
    mkdirs(path:match("(.+)/[^/]+$"))
    local f = assert(io.open(path, "w")); f:write(content); f:close()
end
local function readFile(path)
    local f = io.open(path, "r"); if not f then return nil end
    local c = f:read("*a"); f:close(); return c
end
local function exists(path) return real_lfs.attributes(path, "mode") ~= nil end

if not has_lfs then
    print("  SKIP: real luafilesystem not available in this Lua")
    restoreMocks()
    return true
end

local BackupManager = require("koassistant_backup_manager")

-- Point every storage root at the temp dir BEFORE :new() (new() ensures dirs).
local function freshManager()
    BackupManager.BACKUP_DIR = TMP .. "/data/koassistant_backups"
    BackupManager.SETTINGS_DIR = TMP .. "/settings"
    BackupManager.PLUGIN_DIR = TMP .. "/plugin"
    BackupManager.CHAT_DIR = TMP .. "/data/koassistant_chats"
    BackupManager.LOCK_FILE = TMP .. "/data/koassistant_backups/.backup_lock"
    mkdirs(BackupManager.SETTINGS_DIR)
    mkdirs(BackupManager.PLUGIN_DIR)
    mkdirs(BackupManager.BACKUP_DIR)  -- lfs.mkdir in :new() is non-recursive
    return BackupManager:new()
end

-- Seed a realistic plugin state under the temp dir.
local SETTINGS_BODY = 'return {\n  ["features"] = { ["api_keys"] = { ["anthropic"] = "sk-secret" } },\n  ["provider"] = "anthropic",\n}\n'
local CONFIG_BODY = '-- user config\nreturn { provider = "openai" }\n'
local DOMAIN_BODY = '# Academic\nA custom domain.\n'
local BEHAVIOR_BODY = '# Terse\nBe brief.\n'
local function seed()
    writeFile(TMP .. "/settings/koassistant_settings.lua", SETTINGS_BODY)
    writeFile(TMP .. "/plugin/configuration.lua", CONFIG_BODY)
    writeFile(TMP .. "/plugin/domains/academic.md", DOMAIN_BODY)
    writeFile(TMP .. "/plugin/behaviors/terse.md", BEHAVIOR_BODY)
end

local BACKUP_OPTS = {
    include_settings = true,
    include_api_keys = true,   -- raw copy path (no LuaSettings needed)
    include_configs = true,
    include_content = true,
    include_chats = false,
}

--------------------------------------------------------------------------------
TestRunner:suite("createBackup produces a valid, complete archive")

wipeTmp()
seed()
local bm = freshManager()
local result = bm:createBackup(BACKUP_OPTS)

TestRunner:test("createBackup succeeds and writes a .koa archive", function()
    TestRunner:assertTrue(result and result.success, "createBackup failed: " .. tostring(result and result.error))
    TestRunner:assertTrue(result.backup_path and exists(result.backup_path),
        "archive file should exist at " .. tostring(result.backup_path))
    TestRunner:assertTrue(result.backup_name:match("%.koa$") ~= nil, "archive should be a .koa file")
end)

TestRunner:test("archive contains settings, configs, and content with original bytes", function()
    local check = TMP .. "/check"
    mkdirs(check)
    TestRunner:assertTrue(sh(string.format('tar -xzf "%s" -C "%s"', result.backup_path, check)),
        "archive should extract")
    TestRunner:assertTrue(readFile(check .. "/settings/koassistant_settings.lua") == SETTINGS_BODY,
        "settings file should round-trip byte-for-byte (incl. api keys)")
    TestRunner:assertTrue(readFile(check .. "/configs/configuration.lua") == CONFIG_BODY,
        "configuration.lua should be in the archive")
    TestRunner:assertTrue(readFile(check .. "/domains/academic.md") == DOMAIN_BODY,
        "custom domain should be in the archive")
    TestRunner:assertTrue(readFile(check .. "/behaviors/terse.md") == BEHAVIOR_BODY,
        "custom behavior should be in the archive")
    TestRunner:assertTrue(exists(check .. "/manifest.json"), "archive should include a manifest")
end)

TestRunner:test("validateBackup accepts the archive and reads its manifest", function()
    local v = bm:validateBackup(result.backup_path)
    TestRunner:assertTrue(v and v.valid, "validateBackup should accept our archive: "
        .. tostring(v and table.concat(v.errors or {}, ", ")))
    TestRunner:assertTrue(v.manifest ~= nil, "manifest should parse")
end)

TestRunner:test("listBackups sees the new backup", function()
    local backups = bm:listBackups()
    local found = false
    for _, b in ipairs(backups or {}) do
        if b.path == result.backup_path or b.name == result.backup_name then found = true end
    end
    TestRunner:assertTrue(found, "listBackups should include the created backup")
end)

wipeTmp()

--------------------------------------------------------------------------------
TestRunner:suite("backup -> wipe -> restore recovers the data")

wipeTmp()
seed()
local bm2 = freshManager()
local backup2 = bm2:createBackup(BACKUP_OPTS)

-- Simulate data loss: delete the live settings + plugin files, keep the backup.
sh(string.format('rm -f "%s"', TMP .. "/settings/koassistant_settings.lua"))
sh(string.format('rm -rf "%s" "%s" "%s"',
    TMP .. "/plugin/configuration.lua", TMP .. "/plugin/domains", TMP .. "/plugin/behaviors"))

local pre_restore_gone = not exists(TMP .. "/settings/koassistant_settings.lua")
    and not exists(TMP .. "/plugin/configuration.lua")
    and not exists(TMP .. "/plugin/domains/academic.md")

local restore = bm2:restoreBackup(backup2.backup_path, {
    restore_settings = true,
    restore_configs = true,
    restore_content = true,
    restore_api_keys = true,
    merge_mode = false,         -- replace
    skip_restore_point = true,  -- keep the test focused
})

TestRunner:test("the wipe actually removed the live files first", function()
    TestRunner:assertTrue(pre_restore_gone, "sanity: live files should be gone before restore")
end)

TestRunner:test("restoreBackup succeeds", function()
    TestRunner:assertTrue(restore and restore.success, "restore failed: " .. tostring(restore and restore.error))
end)

TestRunner:test("configs + content come back byte-for-byte", function()
    TestRunner:assertTrue(readFile(TMP .. "/plugin/configuration.lua") == CONFIG_BODY,
        "configuration.lua should be restored")
    TestRunner:assertTrue(readFile(TMP .. "/plugin/domains/academic.md") == DOMAIN_BODY,
        "custom domain should be restored")
    TestRunner:assertTrue(readFile(TMP .. "/plugin/behaviors/terse.md") == BEHAVIOR_BODY,
        "custom behavior should be restored")
end)

TestRunner:test("settings (incl. API keys) come back semantically", function()
    TestRunner:assertTrue(exists(TMP .. "/settings/koassistant_settings.lua"),
        "settings file should be recreated")
    local s = LuaSettingsStub:open(TMP .. "/settings/koassistant_settings.lua")
    TestRunner:assertTrue(s:readSetting("provider") == "anthropic", "top-level provider should restore")
    local features = s:readSetting("features") or {}
    TestRunner:assertTrue(features.api_keys and features.api_keys.anthropic == "sk-secret",
        "API key should restore (include_api_keys was on)")
end)

wipeTmp()
restoreMocks()
return TestRunner:summary()
