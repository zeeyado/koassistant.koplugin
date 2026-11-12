-- Every plugin-local require names a file (B589, 2026-11-05): the relayout of
-- 2026-10-14 moved the code under koassistant/<area>/ and two bench tools
-- kept the old names for three weeks, since nothing in the suite loads them.
-- Every `require("koassistant...")` literal in main.lua, the plugin's code,
-- tests/ and scripts/ must resolve to a file under the plugin folder.
--
-- Run: lua tests/unit/test_requires.lua  (or lua tests/run_tests.lua --unit)

local function setupPaths()
    local info = debug.getinfo(1, "S")
    local script_path = info.source:match("@?(.*)")
    local unit_dir = script_path:match("(.+)/[^/]+$") or "."
    local tests_dir = unit_dir:match("(.+)/[^/]+$") or "."
    local plugin_dir = tests_dir:match("(.+)/[^/]+$") or "."
    package.path = table.concat({
        plugin_dir .. "/?.lua", tests_dir .. "/?.lua", tests_dir .. "/lib/?.lua", package.path,
    }, ";")
    return plugin_dir
end
local PLUGIN_DIR = setupPaths()

local TestRunner = { passed = 0, failed = 0 }
function TestRunner:test(name, fn)
    local ok, err = pcall(fn)
    if ok then
        self.passed = self.passed + 1
        print(string.format("  \226\156\147 %s", name))
    else
        self.failed = self.failed + 1
        print(string.format("  \226\156\151 %s: %s", name, tostring(err)))
    end
end
function TestRunner:assertTrue(v, msg) if not v then error((msg or "expected true"), 2) end end

print("\nEvery plugin-local require names a file (B589)")

local function listLuaFiles()
    local cmd = string.format('cd %q && { echo main.lua; find koassistant tests scripts -name "*.lua" -not -path "*/node_modules/*"; } 2>/dev/null',
        PLUGIN_DIR)
    local h = io.popen(cmd)
    local out = {}
    if h then
        for line in h:lines() do out[#out + 1] = line end
        h:close()
    end
    return out
end

local function exists(rel)
    local h = io.open(PLUGIN_DIR .. "/" .. rel, "r")
    if h then h:close() return true end
    return false
end

TestRunner:test("every require(\"koassistant...\") literal resolves to a file", function()
    local files = listLuaFiles()
    TestRunner:assertTrue(#files > 100, "files scanned: " .. #files)
    local checked, missing = 0, {}
    for _idx, rel in ipairs(files) do
        local h = io.open(PLUGIN_DIR .. "/" .. rel, "r")
        if h then
            local src = h:read("*a")
            h:close()
            for id in src:gmatch('require%s*%(?%s*"(koassistant[%w_%.]*)"') do
                -- a prefix completed at run time ("koassistant.api." .. provider) is not a module
                if id:sub(-1) ~= "." then
                    checked = checked + 1
                    local path = id:gsub("%.", "/") .. ".lua"
                    if not exists(path) and not exists(id:gsub("%.", "/") .. "/init.lua") then
                        missing[#missing + 1] = rel .. ": " .. id
                    end
                end
            end
        end
    end
    TestRunner:assertTrue(checked > 300, "requires checked: " .. checked)
    TestRunner:assertTrue(#missing == 0, "unresolved: " .. table.concat(missing, ", "))
end)

TestRunner:test("the two bench tools require the moved modules by their new ids", function()
    for _idx, rel in ipairs({ "tests/bench/xray_bench.lua", "tests/bench/front_matter_probe.lua" }) do
        -- the bench folder is not tracked: a clone has no such file, and the
        -- suite must pass there too (it failed on every clean checkout)
        local h = io.open(PLUGIN_DIR .. "/" .. rel, "r")
        if h then
            local src = h:read("*a")
            h:close()
            TestRunner:assertTrue(src:find('require("koassistant_', 1, true) == nil, rel .. ": a pre-relayout name")
            TestRunner:assertTrue(src:find('require("model_constraints")', 1, true) == nil, rel .. ": the bare constraints name")
            TestRunner:assertTrue(src:find('require("koassistant.xray.xray_parser")', 1, true) ~= nil, rel .. ": the parser's new id")
        end
    end
end)

print(string.format("\n=== Results: %d passed, %d failed ===", TestRunner.passed, TestRunner.failed))
return TestRunner.failed == 0
