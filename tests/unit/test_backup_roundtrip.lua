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
-- Track 37: the per-book settings export walks the index rebuilder's
-- candidates, which reads G_reader_settings (the suite harness may or may
-- not have installed one; standalone runs have none)
local _saved_grs = rawget(_G, "G_reader_settings")
_G.G_reader_settings = _saved_grs or {
    readSetting = function(_, _key, default) return default end,
    saveSetting = function() end,
    flush = function() end,
}
local function restoreMocks()
    _G.G_reader_settings = _saved_grs
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
local SETTINGS_BODY = 'return {\n  ["features"] = { ["api_keys"] = { ["anthropic"] = "sk-secret" }, ["openai_codex_oauth"] = { ["access_token"] = "oauth-access", ["refresh_token"] = "oauth-refresh", ["chatgpt_account_id"] = "acct-test" } },\n  ["provider"] = "anthropic",\n}\n'
local CONFIG_BODY = '-- user config\nreturn { provider = "openai" }\n'
local DOMAIN_BODY = '# Academic\nA custom domain.\n'
local BEHAVIOR_BODY = '# Terse\nBe brief.\n'
local PINNED_BODY = 'return {\n  ["pinned"] = { { ["title"] = "p1" } },\n}\n'
local GROUPS_BODY = 'return {\n  ["groups"] = { { ["name"] = "g1", ["books"] = {} } },\n}\n'
local function seed()
    writeFile(TMP .. "/settings/koassistant_settings.lua", SETTINGS_BODY)
    -- settings-dir stores copied as-is (registry backupSettingsFiles)
    writeFile(TMP .. "/settings/koassistant_pinned_general.lua", PINNED_BODY)
    writeFile(TMP .. "/settings/koassistant_book_groups.lua", GROUPS_BODY)
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

TestRunner:test("the domain/behavior counts skip macOS '._' companions (#112)", function()
    writeFile(TMP .. "/plugin/domains/._academic.md", "\0\5\22\7binary")
    writeFile(TMP .. "/plugin/behaviors/._terse.md", "\0\5\22\7binary")
    local r = bm:createBackup(BACKUP_OPTS)
    os.remove(TMP .. "/plugin/domains/._academic.md")
    os.remove(TMP .. "/plugin/behaviors/._terse.md")
    TestRunner:assertTrue(r and r.success, "backup should succeed")
    TestRunner:assertTrue(r.counts.domains == 1 and r.counts.behaviors == 1,
        "counts should be 1 and 1, got " .. tostring(r.counts.domains) .. " and " .. tostring(r.counts.behaviors))
end)

TestRunner:test("ordinary backup excludes API keys and subscription OAuth tokens", function()
    local sanitized = bm:createBackup({
        include_settings = true,
        include_api_keys = false,
        include_configs = false,
        include_content = false,
        include_chats = false,
    })
    TestRunner:assertTrue(sanitized and sanitized.success, "sanitized backup should succeed")
    local check = TMP .. "/check_sanitized"
    mkdirs(check)
    TestRunner:assertTrue(sh(string.format('tar -xzf "%s" -C "%s"', sanitized.backup_path, check)),
        "sanitized archive should extract")
    local settings = LuaSettingsStub:open(check .. "/settings/koassistant_settings.lua")
    local features = settings:readSetting("features") or {}
    TestRunner:assertTrue(features.api_keys == nil, "API keys excluded")
    TestRunner:assertTrue(features.openai_codex_oauth == nil, "OAuth tokens excluded")
end)

wipeTmp()

--------------------------------------------------------------------------------
TestRunner:suite("backup -> wipe -> restore recovers the data")

wipeTmp()
seed()
local bm2 = freshManager()
local backup2 = bm2:createBackup(BACKUP_OPTS)

-- Simulate data loss: delete the live settings + plugin files, keep the backup.
sh(string.format('rm -f "%s" "%s" "%s"', TMP .. "/settings/koassistant_settings.lua",
    TMP .. "/settings/koassistant_pinned_general.lua", TMP .. "/settings/koassistant_book_groups.lua"))
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

TestRunner:test("pinned store + groups come back byte-for-byte (registry-driven settings-dir list)", function()
    TestRunner:assertTrue(readFile(TMP .. "/settings/koassistant_pinned_general.lua") == PINNED_BODY, "pinned general restored")
    TestRunner:assertTrue(readFile(TMP .. "/settings/koassistant_book_groups.lua") == GROUPS_BODY, "groups restored (were never backed up before 2026-09-03)")
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
    TestRunner:assertTrue(features.openai_codex_oauth
        and features.openai_codex_oauth.refresh_token == "oauth-refresh",
        "subscription OAuth tokens should restore only with credentials")
end)

--------------------------------------------------------------------------------
TestRunner:suite("a v1-era backup (chats as hash folders) restores AND is flagged for import")

-- The importer lives in main.lua (AskGPT:migrateChatsToDocSettings) and runs
-- off the returned flag; without the flag the restored folders sit unread
-- forever (the pre-Track-37 gap, fixed 2026-09-03).
wipeTmp()
seed()
local bm3 = freshManager()
local v1_src = TMP .. "/v1_archive"
mkdirs(v1_src .. "/chats/abc123")
writeFile(v1_src .. "/chats/abc123/chat_1.lua", 'return { id = "chat_1", messages = {} }\n')
writeFile(v1_src .. "/manifest.json",
    '{"version":"' .. BackupManager.BACKUP_VERSION .. '","plugin_version":"0.9.0","timestamp":1,'
    .. '"created_date":"2026-01-01","contents":{"chats":true},"counts":{},"settings_schema_version":"2","notes":""}')
local v1_archive = BackupManager.BACKUP_DIR .. "/koassistant_backup_v1.koa"
sh(string.format('cd "%s" && tar -czf "%s" .', v1_src, v1_archive))
local restore_v1 = bm3:restoreBackup(v1_archive, {
    restore_chats = true,
    merge_mode = false,
    skip_restore_point = true,
})

TestRunner:test("restoreBackup succeeds on the v1 archive", function()
    TestRunner:assertTrue(restore_v1 and restore_v1.success, "restore failed: " .. tostring(restore_v1 and restore_v1.error))
end)

TestRunner:test("the hash folders land in CHAT_DIR", function()
    TestRunner:assertTrue(exists(BackupManager.CHAT_DIR .. "/abc123/chat_1.lua"), "v1 chat file should be restored")
end)

TestRunner:test("the result carries v1_chats_restored so the caller runs the importer", function()
    TestRunner:assertTrue(restore_v1.v1_chats_restored == true, "v1_chats_restored flag missing")
end)

TestRunner:test("a JSON (v2+) restore does not carry the flag", function()
    TestRunner:assertTrue(restore.v1_chats_restored == false, "flag must be false on a JSON-era restore")
end)

TestRunner:test("main.lua runs the importer off the flag (structural)", function()
    local here = debug.getinfo(1, "S").source:match("@?(.*)")
    local root = here:gsub("/?tests/unit/[^/]+$", "")
    if root == "" then root = "." end
    local main_path = root .. "/main.lua"
    local f = assert(io.open(main_path, "r"))
    local src = f:read("*all"); f:close()
    TestRunner:assertTrue(src:find("result%.v1_chats_restored", 1) ~= nil
        and src:find("self:migrateChatsToDocSettings%(%)", 1) ~= nil, "restore callback must call the importer")
end)

--------------------------------------------------------------------------------
TestRunner:suite("a restore inside a restore can run (rollback lock, audit HIGH)")

-- restoreBackup's own rollback calls restoreBackup again while the outer call
-- still holds the lock. The lock is seconds old and LOCK_TIMEOUT is 5 minutes,
-- so an unconditional acquire could never succeed and every failed restore ended
-- in "Restore failed AND rollback failed". The inner call passes skip_lock.
wipeTmp()
seed()
local bm_lock = freshManager()
local lock_backup = bm_lock:createBackup(BACKUP_OPTS)
local RESTORE_OPTS = {
    restore_settings = true,
    restore_api_keys = true,
    restore_configs = true,
    restore_content = true,
    merge_mode = false,
    skip_restore_point = true,
}

-- Stand in for the outer restore: hold the lock, then restore the way the
-- rollback does.
TestRunner:assertTrue(bm_lock:_acquireLock(), "test setup: lock should be free")
local held = {}
for k, v in pairs(RESTORE_OPTS) do held[k] = v end
held.skip_lock = true
local inner = bm_lock:restoreBackup(lock_backup.backup_path, held)
local lock_still_held = exists(BackupManager.LOCK_FILE)
bm_lock:_releaseLock()

TestRunner:test("a skip_lock restore runs while the caller holds the lock", function()
    TestRunner:assertTrue(inner and inner.success,
        "inner restore failed: " .. tostring(inner and inner.error))
end)

TestRunner:test("the inner restore does not release a lock it never took", function()
    TestRunner:assertTrue(lock_still_held,
        "the outer caller's lock must survive the inner restore")
end)

TestRunner:test("without skip_lock a held lock still blocks a second restore", function()
    TestRunner:assertTrue(bm_lock:_acquireLock(), "test setup: lock should be free again")
    local blocked = bm_lock:restoreBackup(lock_backup.backup_path, RESTORE_OPTS)
    bm_lock:_releaseLock()
    TestRunner:assertTrue(blocked and not blocked.success, "a concurrent restore must be refused")
end)

wipeTmp()

--------------------------------------------------------------------------------
TestRunner:suite("a restore that fails halfway is rolled back (audit HIGH)")

-- The lock fix only matters because of what it unblocks: the rollback itself.
-- Nothing inside the restore pcall raises on its own (the JSON decodes are
-- pcall-ed, LuaSettings swallows a corrupt file, the copies return false), so a
-- device cannot reach this path by hand -- inject the failure instead, at a step
-- that runs AFTER settings and configs were already written, and check the
-- pre-restore state comes back.
wipeTmp()
seed()
local bm_rb = freshManager()

-- The archive we are about to fail to restore: different values throughout, and
-- a chats JSON so the chat step (the last one) actually runs.
local rb_src = TMP .. "/rollback_src"
local ARCHIVE_CONFIG_BODY = '-- from the archive\nreturn { provider = "archived" }\n'
writeFile(rb_src .. "/settings/koassistant_settings.lua",
    'return {\n  ["features"] = {},\n  ["provider"] = "from_the_archive",\n}\n')
writeFile(rb_src .. "/configs/configuration.lua", ARCHIVE_CONFIG_BODY)
writeFile(rb_src .. "/koassistant_chats.json", '{"version":2,"chats":{}}\n')
writeFile(rb_src .. "/manifest.json",
    '{"version":"' .. BackupManager.BACKUP_VERSION .. '","plugin_version":"0.23.0","timestamp":1,'
    .. '"created_date":"2026-01-01","contents":{"settings":true,"api_keys":true,"config_files":true,'
    .. '"chats":true},"counts":{},"settings_schema_version":"2","notes":""}')
local rb_archive = BackupManager.BACKUP_DIR .. "/koassistant_backup_rollback.koa"
sh(string.format('tar -czf "%s" -C "%s" .', rb_archive, rb_src))

-- Fail once, on the last restore step, so settings and configs are already
-- overwritten when it happens. Once only, so the rollback's own run is clean.
local orig_restore_chats = BackupManager.restoreChatsFromJSON
local injected = false
BackupManager.restoreChatsFromJSON = function(selfx, path, merge)
    if not injected then
        injected = true
        error("injected failure after settings were written")
    end
    return orig_restore_chats(selfx, path, merge)
end
local rb_result = bm_rb:restoreBackup(rb_archive, {
    restore_settings = true,
    restore_api_keys = true,
    restore_configs = true,
    restore_content = true,
    restore_chats = true,
    merge_mode = false,
})
BackupManager.restoreChatsFromJSON = orig_restore_chats

TestRunner:test("the failure is reported as rolled back, not as a broken restore", function()
    TestRunner:assertTrue(injected, "test setup: the injected failure never fired")
    TestRunner:assertTrue(rb_result and not rb_result.success, "a failed restore must not report success")
    TestRunner:assertTrue(rb_result.rolled_back == true,
        "rollback did not run: " .. tostring(rb_result and rb_result.error))
end)

TestRunner:test("settings written by the failed restore are undone", function()
    local live = LuaSettingsStub:open(TMP .. "/settings/koassistant_settings.lua")
    TestRunner:assertTrue(live:readSetting("provider") == "anthropic",
        "provider should be back to the pre-restore value, got "
        .. tostring(live:readSetting("provider")))
end)

TestRunner:test("configs written by the failed restore are undone", function()
    TestRunner:assertTrue(readFile(TMP .. "/plugin/configuration.lua") == CONFIG_BODY,
        "configuration.lua should be the pre-restore file, not the archive's")
end)

TestRunner:test("the lock is released once the rollback is done", function()
    TestRunner:assertTrue(not exists(BackupManager.LOCK_FILE),
        "a rolled-back restore must leave no lock behind")
end)

wipeTmp()

--------------------------------------------------------------------------------
TestRunner:suite("relative storage roots (the on-device layout, issue #110)")

-- DataStorage:getDataDir() is the literal "." on every plain install (Kindle,
-- Kobo, PocketBook, plain Linux), so BACKUP_DIR and friends are RELATIVE to
-- KOReader's working directory. Every other suite here uses absolute /tmp paths,
-- which is exactly why the broken archive command shipped: `cd <source> && tar
-- -czf <relative archive>` resolved the archive inside the source directory and
-- tar could not create it. Re-run the backup with the device-shaped paths.
wipeTmp()
seed()
local prev_cwd = real_lfs.currentdir()
mkdirs(TMP .. "/data/koassistant_backups")
BackupManager.BACKUP_DIR = "./data/koassistant_backups"
BackupManager.SETTINGS_DIR = "./settings"
BackupManager.PLUGIN_DIR = "./plugin"
BackupManager.CHAT_DIR = "./data/koassistant_chats"
BackupManager.LOCK_FILE = "./data/koassistant_backups/.backup_lock"
real_lfs.chdir(TMP)
local bm_rel = BackupManager:new()
local rel_result = bm_rel:createBackup(BACKUP_OPTS)
local rel_archive_fails = bm_rel:_createArchive("./no_such_source_dir", "./data/koassistant_backups/never.koa")
real_lfs.chdir(prev_cwd)

TestRunner:test("createBackup writes a real archive when the roots are relative", function()
    TestRunner:assertTrue(rel_result and rel_result.success,
        "createBackup failed: " .. tostring(rel_result and rel_result.error))
    local abs = TMP .. "/data/koassistant_backups/" .. tostring(rel_result and rel_result.backup_name)
    TestRunner:assertTrue(exists(abs), "archive should exist at " .. abs)
    TestRunner:assertTrue((real_lfs.attributes(abs, "size") or 0) > 0, "archive should not be empty")
end)

TestRunner:test("the reported size is the real archive size, never 0 B", function()
    TestRunner:assertTrue((rel_result and rel_result.size or 0) > 0,
        "a 0 B success is the symptom users saw in issue #110")
end)

TestRunner:test("the relative archive holds the settings bytes", function()
    local check = TMP .. "/check_relative"
    mkdirs(check)
    sh(string.format('tar -xzf "%s" -C "%s"',
        TMP .. "/data/koassistant_backups/" .. rel_result.backup_name, check))
    TestRunner:assertTrue(readFile(check .. "/settings/koassistant_settings.lua") == SETTINGS_BODY,
        "settings should round-trip from a relative-root backup")
end)

TestRunner:test("a failing tar is reported as a failure (LuaJIT os.execute returns a number)", function()
    TestRunner:assertTrue(rel_archive_fails == false,
        "_createArchive must return false when tar cannot read the source directory")
end)

wipeTmp()
restoreMocks()
return TestRunner:summary()
