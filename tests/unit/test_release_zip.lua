-- The release zip, and what every installed updater needs from it (B379).
-- Readers update with the version they have installed: its updater dofiles the
-- new _meta.lua inside its own process and looks for main.lua and _meta.lua at
-- the top of the zip's one folder. tests/tools/updater_e2e.sh runs real
-- updates (the last release's updater and this tree's) with KOReader's own
-- archive code; these are the static rules that keep it passing.
--
-- Run: lua tests/unit/test_release_zip.lua  (or lua tests/run_tests.lua --unit)

local function setupPaths()
    local info = debug.getinfo(1, "S")
    local script_path = info.source:match("@?(.*)")
    local unit_dir = script_path:match("(.+)/[^/]+$") or "."
    local tests_dir = unit_dir:match("(.+)/[^/]+$") or "."
    local plugin_dir = tests_dir:match("(.+)/[^/]+$") or "."
    package.path = table.concat({
        plugin_dir .. "/?.lua",
        tests_dir .. "/?.lua",
        tests_dir .. "/lib/?.lua",
        package.path,
    }, ";")
    return plugin_dir
end
local plugin_dir = setupPaths()
local TestRunner = require("test_runner"):new()

local function read(rel)
    local f = assert(io.open(plugin_dir .. "/" .. rel, "r"), rel)
    local s = f:read("*a")
    f:close()
    return s
end

print("\n  [the zip]")

TestRunner:test("the build script leaves out what the release workflow leaves out", function()
    local function excludes(src)
        local seen, list = {}, {}
        for name in src:gmatch("%-%-exclude='([^']+)'") do
            if not seen[name] then
                seen[name] = true
                list[#list + 1] = name
            end
        end
        table.sort(list)
        return table.concat(list, ",")
    end
    local workflow = excludes(read(".github/workflows/release.yml"))
    TestRunner:assertTrue(#workflow > 0, "the workflow's list is found")
    TestRunner:assertEqual(excludes(read("scripts/build_release_zip.sh")), workflow,
        "the tester's zip holds what readers download")
end)

TestRunner:test("main.lua and _meta.lua stay at the top: every updater checks both there", function()
    TestRunner:assertTrue(io.open(plugin_dir .. "/main.lua", "r") ~= nil, "main.lua")
    TestRunner:assertTrue(io.open(plugin_dir .. "/_meta.lua", "r") ~= nil, "_meta.lua")
end)

TestRunner:test("_meta.lua needs nothing an older updater's process lacks", function()
    local meta = read("_meta.lua")
    local reqs = {}
    for name in meta:gmatch('require%(%s*"([^"]+)"%s*%)') do
        reqs[#reqs + 1] = name
    end
    TestRunner:assertEqual(table.concat(reqs, ","), "koassistant_gettext",
        "only the gettext module every release has had")
    TestRunner:assertTrue(meta:find('version = "[^"]+"'), "a version the updater compares with the tag")
end)

print("\n  [the updater]")

TestRunner:test("its deletes never follow a link", function()
    local uc = read("koassistant_update_checker.lua")
    TestRunner:assertFalse(uc:find("ffiutil%.purgeDir[,(]"),
        "no purgeDir call: it empties a linked folder's target")
    TestRunner:assertTrue(uc:find('lfs.symlinkattributes(path, "mode")', 1, true), "purgeTree reads the link itself")
end)

TestRunner:test("any .git, a folder or a worktree's file, is a checkout it never replaces", function()
    local uc = read("koassistant_update_checker.lua")
    TestRunner:assertFalse(uc:find('".git", "mode") == "directory"', 1, true), "the guard is not folder-only")
    TestRunner:assertFalse(uc:find('".git", "mode") ~= "directory"', 1, true), "Update Now is not folder-only")
end)

TestRunner:test("the download is checked before anything is extracted", function()
    local uc = read("koassistant_update_checker.lua")
    local body = uc:match("performUpdate = function%(update_info%)(.-)\nend\n")
    TestRunner:assertTrue(body, "performUpdate found")
    local check = body and body:find("verifyDownload(archive_path, update_info)", 1, true)
    local extract = body and body:find("extractUpdateArchive(archive_path, staging_path)", 1, true)
    TestRunner:assertTrue(check and extract and check < extract, "verify, then extract")
    TestRunner:assertTrue(uc:find('asset.digest:match("^sha256:(%x+)$")', 1, true),
        "the release's sha256 is what the download must match")
end)

return TestRunner:summary()
