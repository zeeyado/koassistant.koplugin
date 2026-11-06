-- The sweep of 2026-11-06, the X-Ray batch: Delete All (the artifact browser's
-- and the Book Hub's) takes the X-Ray lineage with the artifacts (the book's
-- automation pinned off, the marks redrawn through on_xray_edited), and the
-- reader's names file is written through a temp file, so a write a full card
-- cuts short keeps the old file.
--
-- Run: lua tests/unit/test_delete_all_lineage.lua  (or lua tests/run_tests.lua --unit)

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
local plugin_dir = setupPaths()
require("mock_koreader")
local TestRunner = require("test_runner"):new()

local function read(rel)
    local f = assert(io.open(plugin_dir .. "/" .. rel, "r"))
    local s = f:read("*a")
    f:close()
    return s
end

print("Running: test_delete_all_lineage")
print("")

TestRunner:test("both Delete All sites pin the automation off when an X-Ray or its ladder was there", function()
    for _idx, rel in ipairs({ "koassistant/artifacts/artifact_browser.lua", "koassistant/books/book_page.lua" }) do
        local src = read(rel)
        local a = src:find("ActionCache.clearAll(", 1, true)
        TestRunner:assertTrue(a ~= nil, rel .. ": the delete")
        local around = src:sub(a - 400, a + 400)
        TestRunner:assertTrue(around:find("ActionCache.hasAnyXray(", 1, true) ~= nil
            and around:find("ActionCache.getXrayLadder(", 1, true) ~= nil, rel .. ": judged before the delete")
        TestRunner:assertTrue(around:find("clearXrayLineageState(", 1, true) ~= nil, rel .. ": the lineage state cleared")
    end
end)

-- a private sidecar folder and a fresh action cache over it
local TMP = os.tmpname()
os.remove(TMP)
os.execute(string.format("mkdir -p %q", TMP))
local DOC = TMP .. "/b.epub"
os.execute(string.format("mkdir -p %q", DOC .. ".sdr"))
local saved = {
    docsettings = package.loaded["docsettings"],
    util = package.loaded["util"],
    action_cache = package.loaded["koassistant.artifacts.action_cache"],
    G = _G.G_reader_settings,
}
package.loaded["docsettings"] = {
    getSidecarDir = function(_self, doc_path) return doc_path .. ".sdr" end,
    isHashLocationEnabled = function() return false end,
    open = function() return { readSetting = function() end, close = function() end } end,
}
package.loaded["util"] = { makePath = function(dir) os.execute(string.format("mkdir -p %q", dir)) end }
package.loaded["koassistant.artifacts.action_cache"] = nil
_G.G_reader_settings = { _s = {},
    readSetting = function(self, k, d) local v = self._s[k]; if v == nil then return d end; return v end,
    saveSetting = function(self, k, v) self._s[k] = v end, flush = function() end }
local AC = require("koassistant.artifacts.action_cache")

TestRunner:test("clearAll tells the marks (on_xray_edited), with the book's path", function()
    local told
    AC.on_xray_edited = function(path) told = path end
    AC.clearAll(DOC)
    AC.on_xray_edited = nil
    TestRunner:assertEqual(told, DOC)
end)

TestRunner:test("the reader's names: a write a full card cuts short keeps the old file", function()
    local al = { [AC.NEVER_MERGE_KEY] = { { "A", "B" }, { "C", "D" } }, ["Name"] = { add = { "alias1" } } }
    TestRunner:assertTrue(AC.setUserAliases(DOC, al), "the first write")
    local real_open = io.open
    io.open = function(path, mode)
        local f, e = real_open(path, mode)
        if not f or mode ~= "w" then return f, e end
        local written, budget = 0, 40
        local proxy = {}
        function proxy:write(str)
            if written + #str > budget then
                f:write(str:sub(1, math.max(0, budget - written)))
                written = budget
                return nil, "No space left on device"
            end
            written = written + #str
            return f:write(str)
        end
        function proxy:close() f:close(); return nil, "No space left on device" end
        return proxy
    end
    local al2 = AC.getUserAliases(DOC)
    al2["Other"] = { add = { "x" } }
    local ok = AC.setUserAliases(DOC, al2)
    io.open = real_open
    TestRunner:assertFalse(ok, "the failed write says so")
    local back = AC.getUserAliases(DOC)
    local n = 0
    for _k in pairs(back) do n = n + 1 end
    TestRunner:assertEqual(n, 2, "the old file, whole")
    TestRunner:assertEqual(#(back[AC.NEVER_MERGE_KEY] or {}), 2, "its pairs")
    TestRunner:assertEqual(back["Other"], nil, "nothing of the cut write")
    TestRunner:assertEqual(io.open(AC.getUserAliasesPath(DOC) .. ".tmp", "r"), nil, "no temp file left")
end)

package.loaded["docsettings"] = saved.docsettings
package.loaded["util"] = saved.util
package.loaded["koassistant.artifacts.action_cache"] = saved.action_cache
_G.G_reader_settings = saved.G
os.execute(string.format("rm -rf %q", TMP))

return TestRunner:summary()
