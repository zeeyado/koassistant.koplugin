-- Unit tests for the freeform Scope-chip range resolution (flexible_scope_plan.md
-- phase 3): ScopeResolver.chipScope — kind × spoiler × position matrix. The chip's
-- UI, gating, and extraction live in koassistant_dialogs.lua; this file pins the
-- pure range policy only.

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
end
setupPaths()

local ScopeResolver = require("koassistant_scope_resolver")

-- Simple test framework (matches the other unit tests)
local TestRunner = { passed = 0, failed = 0 }
function TestRunner:suite(name) print(string.format("\n  [%s]", name)) end
function TestRunner:test(name, fn)
    local ok, err = pcall(fn)
    if ok then
        self.passed = self.passed + 1
        print(string.format("    ✓ %s", name))
    else
        self.failed = self.failed + 1
        print(string.format("    ✗ %s", name))
        print(string.format("      Error: %s", tostring(err)))
    end
end
function TestRunner:assertEqual(actual, expected, msg)
    if actual ~= expected then
        error(string.format("%s: expected %q, got %q", msg or "assertEqual",
            tostring(expected), tostring(actual)))
    end
end
function TestRunner:assertNil(value, msg)
    if value ~= nil then
        error(string.format("%s: expected nil, got %q", msg or "assertNil", tostring(value)))
    end
end
function TestRunner:assertNotNil(value, msg)
    if value == nil then
        error(string.format("%s: expected non-nil", msg or "assertNotNil"))
    end
end

local function scope(pick, p) return ScopeResolver.chipScope(pick, p) end

TestRunner:suite("chipScope — to_position")

TestRunner:test("mid-book → page 1 to current", function()
    local r = scope({ kind = "to_position" }, { current_page = 120 })
    TestRunner:assertNotNil(r, "range")
    TestRunner:assertEqual(r.start_page, 1, "start")
    TestRunner:assertEqual(r.end_page, 120, "end = current page")
    TestRunner:assertNil(r.clamped, "not clamped")
end)

TestRunner:test("at page 1 → invalid, nothing read", function()
    local r, reason = scope({ kind = "to_position" }, { current_page = 1 })
    TestRunner:assertNil(r, "range")
    TestRunner:assertEqual(reason, "nothing_read", "reason")
end)

TestRunner:test("missing position defaults to page 1 → invalid", function()
    local r, reason = scope({ kind = "to_position" }, {})
    TestRunner:assertNil(r, "range")
    TestRunner:assertEqual(reason, "nothing_read", "reason")
end)

TestRunner:suite("chipScope — from_section (end = position by construction)")

TestRunner:test("section behind position → start to current", function()
    local r = scope({ kind = "from_section", start_page = 100 }, { current_page = 120 })
    TestRunner:assertNotNil(r, "range")
    TestRunner:assertEqual(r.start_page, 100, "start = picked section")
    TestRunner:assertEqual(r.end_page, 120, "end = current page")
end)

TestRunner:test("section beyond position → invalid regardless of spoiler", function()
    local r, reason = scope({ kind = "from_section", start_page = 150 }, { current_page = 120 })
    TestRunner:assertNil(r, "range")
    TestRunner:assertEqual(reason, "beyond_position", "reason")
end)

TestRunner:test("section at current page → single-page range allowed", function()
    local r = scope({ kind = "from_section", start_page = 120 }, { current_page = 120 })
    TestRunner:assertNotNil(r, "range")
    TestRunner:assertEqual(r.start_page, 120, "start")
    TestRunner:assertEqual(r.end_page, 120, "end")
end)

TestRunner:test("missing start page → bad_pick", function()
    local r, reason = scope({ kind = "from_section" }, { current_page = 120 })
    TestRunner:assertNil(r, "range")
    TestRunner:assertEqual(reason, "bad_pick", "reason")
end)

TestRunner:suite("chipScope — section (spoiler clamp)")

TestRunner:test("no spoiler → raw pick passes, even beyond position", function()
    local r = scope({ kind = "section", start_page = 150, end_page = 190 }, { current_page = 120 })
    TestRunner:assertNotNil(r, "range")
    TestRunner:assertEqual(r.start_page, 150, "start")
    TestRunner:assertEqual(r.end_page, 190, "end")
    TestRunner:assertNil(r.clamped, "not clamped")
end)

TestRunner:test("spoiler + section fully read → raw pick passes", function()
    local r = scope({ kind = "section", start_page = 50, end_page = 90 },
        { current_page = 120, spoiler_free = true })
    TestRunner:assertNotNil(r, "range")
    TestRunner:assertEqual(r.end_page, 90, "end unchanged")
    TestRunner:assertNil(r.clamped, "not clamped")
end)

TestRunner:test("spoiler + section straddling position → end clamped to current", function()
    local r = scope({ kind = "section", start_page = 100, end_page = 140 },
        { current_page = 120, spoiler_free = true })
    TestRunner:assertNotNil(r, "range")
    TestRunner:assertEqual(r.start_page, 100, "start")
    TestRunner:assertEqual(r.end_page, 120, "end clamped to current page")
    TestRunner:assertEqual(r.clamped, true, "clamped flag set")
end)

TestRunner:test("spoiler + section fully beyond position → invalid", function()
    local r, reason = scope({ kind = "section", start_page = 150, end_page = 190 },
        { current_page = 120, spoiler_free = true })
    TestRunner:assertNil(r, "range")
    TestRunner:assertEqual(reason, "beyond_position", "reason")
end)

TestRunner:test("missing page bounds → bad_pick", function()
    local r, reason = scope({ kind = "section", start_page = 100 }, { current_page = 120 })
    TestRunner:assertNil(r, "range")
    TestRunner:assertEqual(reason, "bad_pick", "reason")
end)

TestRunner:suite("chipScope — range (section rules across two picks)")

TestRunner:test("no spoiler → raw range passes", function()
    local r = scope({ kind = "range", start_page = 50, end_page = 190 }, { current_page = 120 })
    TestRunner:assertNotNil(r, "range")
    TestRunner:assertEqual(r.start_page, 50, "start")
    TestRunner:assertEqual(r.end_page, 190, "end")
    TestRunner:assertNil(r.clamped, "not clamped")
end)

TestRunner:test("spoiler + range straddling position → end clamped", function()
    local r = scope({ kind = "range", start_page = 50, end_page = 190 },
        { current_page = 120, spoiler_free = true })
    TestRunner:assertNotNil(r, "range")
    TestRunner:assertEqual(r.end_page, 120, "end clamped to current page")
    TestRunner:assertEqual(r.clamped, true, "clamped flag set")
end)

TestRunner:test("spoiler + range fully beyond position → invalid", function()
    local r, reason = scope({ kind = "range", start_page = 150, end_page = 190 },
        { current_page = 120, spoiler_free = true })
    TestRunner:assertNil(r, "range")
    TestRunner:assertEqual(reason, "beyond_position", "reason")
end)

TestRunner:suite("chipScope — degenerate picks")

TestRunner:test("nil pick → bad_pick", function()
    local r, reason = scope(nil, { current_page = 120 })
    TestRunner:assertNil(r, "range")
    TestRunner:assertEqual(reason, "bad_pick", "reason")
end)

TestRunner:test("unknown kind → bad_pick", function()
    local r, reason = scope({ kind = "page" }, { current_page = 120 })
    TestRunner:assertNil(r, "range")
    TestRunner:assertEqual(reason, "bad_pick", "reason (page kind never resolves a range)")
end)

print(string.format("\n  chip scope: %d passed, %d failed", TestRunner.passed, TestRunner.failed))

return TestRunner.failed == 0
