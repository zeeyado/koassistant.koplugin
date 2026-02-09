--[[
Unit Tests for auto-update helper functions in koassistant_update_checker.lua

Tests the pure logic helpers using real filesystem operations in temp directories.
Does NOT require the full update checker module (too many UI widget dependencies).

Run: lua tests/run_tests.lua --unit
]]

-- Setup test environment
package.path = package.path .. ";./?.lua;./?/init.lua"
require("tests.lib.mock_koreader")

local lfs = require("lfs")

-- Test suite
local TestAutoUpdate = {
    passed = 0,
    failed = 0,
    temp_dirs = {},  -- Track for cleanup
}

function TestAutoUpdate:test(name, fn)
    local ok, err = pcall(fn)
    if ok then
        self.passed = self.passed + 1
        print(string.format("  ✓ %s", name))
    else
        self.failed = self.failed + 1
        print(string.format("  ✗ %s: %s", name, tostring(err)))
    end
end

function TestAutoUpdate:assert(condition, message)
    if not condition then
        error(message or "Assertion failed", 2)
    end
end

function TestAutoUpdate:assertEquals(actual, expected, message)
    if actual ~= expected then
        error(string.format("%s: expected %s, got %s",
            message or "Values not equal",
            tostring(expected),
            tostring(actual)), 2)
    end
end

-- Helper: create a temporary directory
function TestAutoUpdate:makeTempDir(suffix)
    local path = os.tmpname()
    os.remove(path)  -- tmpname creates a file, we want a dir
    path = path .. (suffix or "_test")
    lfs.mkdir(path)
    table.insert(self.temp_dirs, path)
    return path
end

-- Helper: write a file with content
function TestAutoUpdate:writeFile(path, content)
    local f = io.open(path, "w")
    if not f then error("Failed to create file: " .. path) end
    f:write(content or "")
    f:close()
end

-- Helper: read a file's content
function TestAutoUpdate:readFile(path)
    local f = io.open(path, "r")
    if not f then return nil end
    local content = f:read("*a")
    f:close()
    return content
end

-- Helper: check if path exists
function TestAutoUpdate:pathExists(path)
    return lfs.attributes(path, "mode") ~= nil
end

-- Helper: recursive directory removal
function TestAutoUpdate:purgeDir(path)
    if lfs.attributes(path, "mode") ~= "directory" then return end
    for entry in lfs.dir(path) do
        if entry ~= "." and entry ~= ".." then
            local full_path = path .. "/" .. entry
            local mode = lfs.attributes(full_path, "mode")
            if mode == "directory" then
                self:purgeDir(full_path)
            elseif mode == "file" then
                os.remove(full_path)
            end
        end
    end
    lfs.rmdir(path)
end

-- Cleanup all temp dirs
function TestAutoUpdate:cleanup()
    for _idx, dir in ipairs(self.temp_dirs) do
        self:purgeDir(dir)
    end
    self.temp_dirs = {}
end

-- ============================================================================
-- Local implementations matching koassistant_update_checker.lua logic
-- These mirror the actual functions for testability
-- ============================================================================

local USER_FILES = { "apikeys.lua", "configuration.lua", "custom_actions.lua" }
local USER_DIRS = { "behaviors", "domains" }

local function verifyExtractedPlugin(staging_dir, expected_version)
    local meta_path = staging_dir .. "/_meta.lua"
    if lfs.attributes(meta_path, "mode") ~= "file" then
        return false, "_meta.lua not found in extracted plugin"
    end
    if lfs.attributes(staging_dir .. "/main.lua", "mode") ~= "file" then
        return false, "main.lua not found in extracted plugin"
    end
    local load_ok, loaded_meta = pcall(dofile, meta_path)
    if not load_ok then
        return false, "Failed to load _meta.lua: " .. tostring(loaded_meta)
    end
    if not loaded_meta or not loaded_meta.version then
        return false, "_meta.lua does not contain version"
    end
    if loaded_meta.version ~= expected_version then
        return false, "Version mismatch: expected " .. expected_version .. ", got " .. loaded_meta.version
    end
    return true
end

local function findAvailableBackupPath(base_path)
    if lfs.attributes(base_path, "mode") ~= "directory" then
        return base_path
    end
    for i = 2, 10 do
        local numbered_path = base_path .. "_" .. i
        if lfs.attributes(numbered_path, "mode") ~= "directory" then
            return numbered_path
        end
    end
    -- Last resort: purge and reuse (tested via mock)
    return base_path
end

local function preserveUserFiles(src_dir, preserve_dir)
    lfs.mkdir(preserve_dir)
    for _idx, filename in ipairs(USER_FILES) do
        local src_path = src_dir .. "/" .. filename
        if lfs.attributes(src_path, "mode") == "file" then
            -- Pure Lua copy for tests (production uses ffiutil.copyFile)
            local inf = io.open(src_path, "rb")
            if inf then
                local outf = io.open(preserve_dir .. "/" .. filename, "wb")
                if outf then
                    outf:write(inf:read("*a"))
                    outf:close()
                end
                inf:close()
            end
        end
    end
    for _idx, dirname in ipairs(USER_DIRS) do
        local src_path = src_dir .. "/" .. dirname
        if lfs.attributes(src_path, "mode") == "directory" then
            local dest_path = preserve_dir .. "/" .. dirname
            lfs.mkdir(dest_path)
            for entry in lfs.dir(src_path) do
                if entry ~= "." and entry ~= ".." then
                    local inf = io.open(src_path .. "/" .. entry, "rb")
                    if inf then
                        local outf = io.open(dest_path .. "/" .. entry, "wb")
                        if outf then
                            outf:write(inf:read("*a"))
                            outf:close()
                        end
                        inf:close()
                    end
                end
            end
        end
    end
    return true
end

local function restoreUserFiles(preserve_dir, target_dir)
    if lfs.attributes(preserve_dir, "mode") ~= "directory" then
        return false, "Preserve directory not found"
    end
    for _idx, filename in ipairs(USER_FILES) do
        local src_path = preserve_dir .. "/" .. filename
        if lfs.attributes(src_path, "mode") == "file" then
            -- Use rename (same filesystem)
            os.rename(src_path, target_dir .. "/" .. filename)
        end
    end
    for _idx, dirname in ipairs(USER_DIRS) do
        local src_path = preserve_dir .. "/" .. dirname
        if lfs.attributes(src_path, "mode") == "directory" then
            local target_path = target_dir .. "/" .. dirname
            os.rename(src_path, target_path)
        end
    end
    return true
end

-- ============================================================================
-- Tests
-- ============================================================================

function TestAutoUpdate:runAll()
    print("\n=== Testing auto-update helpers ===\n")

    -- ---- verifyExtractedPlugin ----

    self:test("verifyExtractedPlugin: valid staging dir", function()
        local dir = self:makeTempDir("_verify_ok")
        self:writeFile(dir .. "/main.lua", "return {}")
        self:writeFile(dir .. "/_meta.lua", 'return { name = "koassistant", version = "0.18.0" }')
        local ok, err = verifyExtractedPlugin(dir, "0.18.0")
        self:assert(ok, "Should succeed: " .. tostring(err))
    end)

    self:test("verifyExtractedPlugin: missing _meta.lua", function()
        local dir = self:makeTempDir("_verify_nometa")
        self:writeFile(dir .. "/main.lua", "return {}")
        local ok, err = verifyExtractedPlugin(dir, "0.18.0")
        self:assert(not ok, "Should fail")
        self:assert(err:find("_meta.lua not found"), "Error should mention _meta.lua")
    end)

    self:test("verifyExtractedPlugin: missing main.lua", function()
        local dir = self:makeTempDir("_verify_nomain")
        self:writeFile(dir .. "/_meta.lua", 'return { name = "koassistant", version = "0.18.0" }')
        local ok, err = verifyExtractedPlugin(dir, "0.18.0")
        self:assert(not ok, "Should fail")
        self:assert(err:find("main.lua not found"), "Error should mention main.lua")
    end)

    self:test("verifyExtractedPlugin: version mismatch", function()
        local dir = self:makeTempDir("_verify_mismatch")
        self:writeFile(dir .. "/main.lua", "return {}")
        self:writeFile(dir .. "/_meta.lua", 'return { name = "koassistant", version = "0.17.0" }')
        local ok, err = verifyExtractedPlugin(dir, "0.18.0")
        self:assert(not ok, "Should fail")
        self:assert(err:find("Version mismatch"), "Error should mention version mismatch")
    end)

    self:test("verifyExtractedPlugin: invalid _meta.lua syntax", function()
        local dir = self:makeTempDir("_verify_badsyntax")
        self:writeFile(dir .. "/main.lua", "return {}")
        self:writeFile(dir .. "/_meta.lua", "this is not valid lua")
        local ok, err = verifyExtractedPlugin(dir, "0.18.0")
        self:assert(not ok, "Should fail")
        self:assert(err:find("Failed to load"), "Error should mention load failure")
    end)

    self:test("verifyExtractedPlugin: _meta.lua without version field", function()
        local dir = self:makeTempDir("_verify_noversion")
        self:writeFile(dir .. "/main.lua", "return {}")
        self:writeFile(dir .. "/_meta.lua", 'return { name = "koassistant" }')
        local ok, err = verifyExtractedPlugin(dir, "0.18.0")
        self:assert(not ok, "Should fail")
        self:assert(err:find("does not contain version"), "Error should mention missing version")
    end)

    -- ---- findAvailableBackupPath ----

    self:test("findAvailableBackupPath: no existing backup", function()
        local base = self:makeTempDir("_backup_base")
        self:purgeDir(base)  -- Remove it so it doesn't exist
        local result = findAvailableBackupPath(base)
        self:assertEquals(result, base, "Should return base path when nothing exists")
    end)

    self:test("findAvailableBackupPath: existing backup", function()
        local base = self:makeTempDir("_backup_exists")
        -- base already exists as directory
        local result = findAvailableBackupPath(base)
        self:assertEquals(result, base .. "_2", "Should return _2 suffix")
    end)

    self:test("findAvailableBackupPath: multiple collisions", function()
        local base = self:makeTempDir("_backup_multi")
        -- Create _2 and _3
        lfs.mkdir(base .. "_2")
        table.insert(self.temp_dirs, base .. "_2")
        lfs.mkdir(base .. "_3")
        table.insert(self.temp_dirs, base .. "_3")
        local result = findAvailableBackupPath(base)
        self:assertEquals(result, base .. "_4", "Should skip to _4")
    end)

    self:test("findAvailableBackupPath: all slots taken returns base (last resort)", function()
        local base = self:makeTempDir("_backup_full")
        for i = 2, 10 do
            lfs.mkdir(base .. "_" .. i)
            table.insert(self.temp_dirs, base .. "_" .. i)
        end
        local result = findAvailableBackupPath(base)
        -- Should return base_path (last resort purge)
        self:assertEquals(result, base, "Should return base when all slots taken")
    end)

    -- ---- preserveUserFiles ----

    self:test("preserveUserFiles: preserves existing files", function()
        local src = self:makeTempDir("_preserve_src")
        local dst = self:makeTempDir("_preserve_dst")
        self:purgeDir(dst)  -- Remove so preserveUserFiles can create it

        self:writeFile(src .. "/apikeys.lua", 'return { openai = "sk-test" }')
        self:writeFile(src .. "/configuration.lua", 'return { provider = "openai" }')

        local ok = preserveUserFiles(src, dst)
        self:assert(ok, "Should succeed")
        self:assert(self:pathExists(dst .. "/apikeys.lua"), "apikeys.lua should be preserved")
        self:assert(self:pathExists(dst .. "/configuration.lua"), "configuration.lua should be preserved")
        self:assertEquals(self:readFile(dst .. "/apikeys.lua"), 'return { openai = "sk-test" }', "Content should match")
    end)

    self:test("preserveUserFiles: skips missing files gracefully", function()
        local src = self:makeTempDir("_preserve_empty")
        local dst = self:makeTempDir("_preserve_empty_dst")
        self:purgeDir(dst)

        -- No user files exist
        local ok = preserveUserFiles(src, dst)
        self:assert(ok, "Should succeed even with no files")
        self:assert(self:pathExists(dst), "Preserve dir should be created")
    end)

    self:test("preserveUserFiles: preserves user directories", function()
        local src = self:makeTempDir("_preserve_dirs")
        local dst = self:makeTempDir("_preserve_dirs_dst")
        self:purgeDir(dst)

        -- Create behaviors/ with a file
        lfs.mkdir(src .. "/behaviors")
        self:writeFile(src .. "/behaviors/custom.md", "# Custom Behavior")

        local ok = preserveUserFiles(src, dst)
        self:assert(ok, "Should succeed")
        self:assert(self:pathExists(dst .. "/behaviors/custom.md"), "behaviors/custom.md should be preserved")
        self:assertEquals(self:readFile(dst .. "/behaviors/custom.md"), "# Custom Behavior", "Content should match")
    end)

    -- ---- restoreUserFiles ----

    self:test("restoreUserFiles: restores files to target", function()
        local preserve = self:makeTempDir("_restore_preserve")
        local target = self:makeTempDir("_restore_target")

        self:writeFile(preserve .. "/apikeys.lua", 'return { anthropic = "sk-ant-test" }')
        self:writeFile(preserve .. "/custom_actions.lua", 'return {}')

        local ok = restoreUserFiles(preserve, target)
        self:assert(ok, "Should succeed")
        self:assert(self:pathExists(target .. "/apikeys.lua"), "apikeys.lua should be restored")
        self:assertEquals(self:readFile(target .. "/apikeys.lua"), 'return { anthropic = "sk-ant-test" }', "Content should match")
        self:assert(not self:pathExists(preserve .. "/apikeys.lua"), "Source should be moved (not copied)")
    end)

    self:test("restoreUserFiles: restores directories", function()
        local preserve = self:makeTempDir("_restore_dirs_preserve")
        local target = self:makeTempDir("_restore_dirs_target")

        lfs.mkdir(preserve .. "/domains")
        self:writeFile(preserve .. "/domains/islamic.md", "# Islamic Domain")

        local ok = restoreUserFiles(preserve, target)
        self:assert(ok, "Should succeed")
        self:assert(self:pathExists(target .. "/domains/islamic.md"), "domains/islamic.md should be restored")
    end)

    self:test("restoreUserFiles: fails gracefully with missing preserve dir", function()
        local ok, err = restoreUserFiles("/nonexistent/path", "/tmp")
        self:assert(not ok, "Should fail")
        self:assert(err:find("not found"), "Error should mention not found")
    end)

    -- ---- zip_url extraction logic ----

    self:test("zip_url extraction: finds zip asset", function()
        local assets = {
            { name = "koassistant.koplugin.zip", browser_download_url = "https://example.com/download.zip" },
        }
        local zip_url = nil
        for _idx, asset in ipairs(assets) do
            if asset.name and asset.name:match("%.zip$") then
                zip_url = asset.browser_download_url
                break
            end
        end
        self:assertEquals(zip_url, "https://example.com/download.zip", "Should find zip URL")
    end)

    self:test("zip_url extraction: nil when no zip asset", function()
        local assets = {
            { name = "release-notes.md", browser_download_url = "https://example.com/notes.md" },
        }
        local zip_url = nil
        for _idx, asset in ipairs(assets) do
            if asset.name and asset.name:match("%.zip$") then
                zip_url = asset.browser_download_url
                break
            end
        end
        self:assertEquals(zip_url, nil, "Should be nil when no zip")
    end)

    self:test("zip_url extraction: handles empty assets", function()
        local assets = {}
        local zip_url = nil
        for _idx, asset in ipairs(assets) do
            if asset.name and asset.name:match("%.zip$") then
                zip_url = asset.browser_download_url
                break
            end
        end
        self:assertEquals(zip_url, nil, "Should be nil for empty assets")
    end)

    self:test("zip_url extraction: handles nil assets", function()
        local latest_release = {}
        local zip_url = nil
        if latest_release.assets then
            for _idx, asset in ipairs(latest_release.assets) do
                if asset.name and asset.name:match("%.zip$") then
                    zip_url = asset.browser_download_url
                    break
                end
            end
        end
        self:assertEquals(zip_url, nil, "Should be nil for nil assets")
    end)

    self:test("zip_url extraction: picks first zip when multiple", function()
        local assets = {
            { name = "source.tar.gz", browser_download_url = "https://example.com/source.tar.gz" },
            { name = "koassistant.koplugin.zip", browser_download_url = "https://example.com/plugin.zip" },
            { name = "other.zip", browser_download_url = "https://example.com/other.zip" },
        }
        local zip_url = nil
        for _idx, asset in ipairs(assets) do
            if asset.name and asset.name:match("%.zip$") then
                zip_url = asset.browser_download_url
                break
            end
        end
        self:assertEquals(zip_url, "https://example.com/plugin.zip", "Should pick first zip")
    end)

    -- ---- USER_FILES/USER_DIRS constants ----

    self:test("USER_FILES contains expected files", function()
        local expected = { "apikeys.lua", "configuration.lua", "custom_actions.lua" }
        self:assertEquals(#USER_FILES, #expected, "Should have " .. #expected .. " user files")
        for i, name in ipairs(expected) do
            self:assertEquals(USER_FILES[i], name, "File " .. i .. " should be " .. name)
        end
    end)

    self:test("USER_DIRS contains expected directories", function()
        local expected = { "behaviors", "domains" }
        self:assertEquals(#USER_DIRS, #expected, "Should have " .. #expected .. " user dirs")
        for i, name in ipairs(expected) do
            self:assertEquals(USER_DIRS[i], name, "Dir " .. i .. " should be " .. name)
        end
    end)

    -- Cleanup
    self:cleanup()

    -- Summary
    print(string.format("\nResults: %d passed, %d failed\n", self.passed, self.failed))
    return self.failed == 0
end

-- Run all tests and return success status
local success = TestAutoUpdate:runAll()

-- Exit with code if run directly
if arg and arg[0] and arg[0]:match("test_auto_update%.lua$") then
    os.exit(success and 0 or 1)
end

return success
