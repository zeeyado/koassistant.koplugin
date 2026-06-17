-- Unit tests for koassistant_xray_parser.lua JSON extraction + shared unescaped-quote repair.

local function setupPaths()
    local info = debug.getinfo(1, "S")
    local script_path = info.source:match("@?(.*)")
    local unit_dir = script_path:match("(.+)/[^/]+$") or "."
    local tests_dir = unit_dir:match("(.+)/[^/]+$") or "."
    local plugin_dir = tests_dir:match("(.+)/[^/]+$") or "."
    package.path = table.concat({
        plugin_dir .. "/?.lua", tests_dir .. "/?.lua", tests_dir .. "/lib/?.lua", package.path,
    }, ";")
end
setupPaths()
require("mock_koreader")

local XrayParser = require("koassistant_xray_parser")

local TestRunner = { passed = 0, failed = 0 }
function TestRunner:suite(name) print(string.format("\n  [%s]", name)) end
function TestRunner:test(name, fn)
    local ok, err = pcall(fn)
    if ok then self.passed = self.passed + 1; print("    ✓ " .. name)
    else self.failed = self.failed + 1; print("    ✗ " .. name); print("      Error: " .. tostring(err)) end
end
function TestRunner:ok(v, msg) if not v then error(msg or "expected truthy") end end
function TestRunner:eq(a, b, msg)
    if a ~= b then error(string.format("%s: expected %q, got %q", msg or "eq", tostring(b), tostring(a))) end
end

TestRunner:suite("XrayParser.parse — well-formed")
TestRunner:test("raw fiction JSON", function()
    local d = XrayParser.parse('{"characters":[{"name":"Jack","description":"a man"}]}')
    TestRunner:ok(d); TestRunner:ok(d.characters)
end)
TestRunner:test("fenced JSON", function()
    local d = XrayParser.parse('```json\n{"characters":[{"name":"Wendy","description":"his wife"}]}\n```')
    TestRunner:ok(d); TestRunner:ok(d.characters)
end)
TestRunner:test("JSON with leading thinking text + trailing prose", function()
    local d = XrayParser.parse('Here is the X-Ray:\n```json\n{"characters":[{"name":"Danny","description":"the son"}]}\n```\nHope that helps.')
    TestRunner:ok(d); TestRunner:ok(d.characters)
end)

TestRunner:suite("XrayParser.parse — unescaped inner quotes (shared repair)")
TestRunner:test("raw double quotes in a description are recovered", function()
    local txt = '```json\n{"characters":[{"name":"Jack","description":"He says "all work and no play" repeatedly, echoing the "spirit" of the hotel."}]}\n```'
    local d, e = XrayParser.parse(txt)
    TestRunner:ok(d, "should recover via repair: " .. tostring(e))
    TestRunner:ok(d.characters)
    TestRunner:ok(d.characters[1].description:find("all work and no play"), "description content preserved")
end)
TestRunner:test("repair does not corrupt valid X-Ray", function()
    local d = XrayParser.parse('{"key_figures":[{"name":"Kant","description":"a philosopher"}],"core_concepts":[]}')
    TestRunner:ok(d); TestRunner:ok(d.key_figures)
end)

print("")
print(string.rep("-", 50))
print(string.format("  Results: %d passed, %d failed", TestRunner.passed, TestRunner.failed))
print(string.rep("-", 50))
return TestRunner.failed == 0
