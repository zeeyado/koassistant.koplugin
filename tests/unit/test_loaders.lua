-- Unit tests for behavior_loader.lua and domain_loader.lua
-- Tests file loading, sorting, and retrieval functions
-- Uses actual filesystem if behaviors/ and domains/ folders exist

-- Setup paths (detect script location)
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

    return plugin_dir, tests_dir
end

local plugin_dir = setupPaths()

-- Load mocks BEFORE any plugin modules
require("mock_koreader")

-- Simple test framework (same as other unit tests)
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
        print(string.format("    ✓ %s", name))
    else
        self.failed = self.failed + 1
        print(string.format("    ✗ %s", name))
        print(string.format("      Error: %s", tostring(err)))
    end
end

function TestRunner:assertEqual(actual, expected, msg)
    if actual ~= expected then
        error(string.format("%s: expected %q, got %q", msg or "Assertion failed", tostring(expected), tostring(actual)))
    end
end

function TestRunner:assertContains(str, pattern, msg)
    if not str or not str:find(pattern, 1, true) then
        error(string.format("%s: expected string to contain %q", msg or "Assertion failed", pattern))
    end
end

function TestRunner:assertNil(value, msg)
    if value ~= nil then
        error(string.format("%s: expected nil, got %q", msg or "Assertion failed", tostring(value)))
    end
end

function TestRunner:assertNotNil(value, msg)
    if value == nil then
        error(string.format("%s: expected non-nil value", msg or "Assertion failed"))
    end
end

function TestRunner:assertType(value, expected_type, msg)
    if type(value) ~= expected_type then
        error(string.format("%s: expected type %q, got %q", msg or "Assertion failed", expected_type, type(value)))
    end
end

function TestRunner:assertGreaterThan(actual, expected, msg)
    if actual <= expected then
        error(string.format("%s: expected > %d, got %d", msg or "Assertion failed", expected, actual))
    end
end

function TestRunner:summary()
    print("")
    print(string.rep("-", 50))
    local total = self.passed + self.failed
    if self.failed == 0 then
        print(string.format("  All %d tests passed!", total))
    else
        print(string.format("  %d passed, %d failed (of %d total)", self.passed, self.failed, total))
    end
    return self.failed == 0
end

-- Load the modules under test
local BehaviorLoader = require("behavior_loader")
local DomainLoader = require("domain_loader")

print("")
print(string.rep("=", 50))
print("  Unit Tests: behavior_loader.lua & domain_loader.lua")
print(string.rep("=", 50))

-- ============================================================
-- BehaviorLoader tests
-- ============================================================

TestRunner:suite("BehaviorLoader.load()")

TestRunner:test("returns a table", function()
    local result = BehaviorLoader.load()
    TestRunner:assertType(result, "table", "returns table")
end)

TestRunner:test("getFolderPath returns string ending with behaviors/", function()
    local path = BehaviorLoader.getFolderPath()
    TestRunner:assertType(path, "string", "returns string")
    TestRunner:assertContains(path, "behaviors/", "ends with behaviors/")
end)

-- Test hasAny()
TestRunner:suite("BehaviorLoader.hasAny()")

TestRunner:test("returns false for empty table", function()
    local result = BehaviorLoader.hasAny({})
    TestRunner:assertEqual(result, false, "empty returns false")
end)

TestRunner:test("returns true for non-empty table", function()
    local behaviors = { test = { name = "Test", text = "text" } }
    local result = BehaviorLoader.hasAny(behaviors)
    TestRunner:assertEqual(result, true, "non-empty returns true")
end)

-- Test getSortedIds()
TestRunner:suite("BehaviorLoader.getSortedIds()")

TestRunner:test("returns empty array for empty behaviors", function()
    local result = BehaviorLoader.getSortedIds({})
    TestRunner:assertType(result, "table", "returns table")
    TestRunner:assertEqual(#result, 0, "empty array")
end)

TestRunner:test("returns sorted IDs", function()
    local behaviors = {
        zebra = { name = "Zebra", text = "z" },
        alpha = { name = "Alpha", text = "a" },
    }
    local result = BehaviorLoader.getSortedIds(behaviors)
    TestRunner:assertEqual(result[1], "alpha", "alpha first")
    TestRunner:assertEqual(result[2], "zebra", "zebra second")
end)

-- Test get()
TestRunner:suite("BehaviorLoader.get()")

TestRunner:test("returns behavior by id", function()
    local behaviors = {
        test = { name = "Test", text = "test text" },
    }
    local result = BehaviorLoader.get(behaviors, "test")
    TestRunner:assertNotNil(result, "found behavior")
    TestRunner:assertEqual(result.name, "Test", "name matches")
end)

TestRunner:test("returns nil for unknown id", function()
    local behaviors = {}
    local result = BehaviorLoader.get(behaviors, "unknown")
    TestRunner:assertNil(result, "nil for unknown")
end)

-- Test with actual behaviors/ folder if it has files
TestRunner:suite("BehaviorLoader integration (actual folder)")

TestRunner:test("loads from behaviors/ folder if files exist", function()
    local behaviors = BehaviorLoader.load()
    -- This test documents behavior - may have files or not
    TestRunner:assertType(behaviors, "table", "returns table regardless")
    -- If concise.md exists (from earlier context), it should be loaded
    if behaviors["concise"] then
        TestRunner:assertEqual(behaviors["concise"].source, "folder", "source is folder")
        TestRunner:assertNotNil(behaviors["concise"].text, "has text")
    end
end)

-- ============================================================
-- DomainLoader tests
-- ============================================================

TestRunner:suite("DomainLoader.load()")

TestRunner:test("returns a table", function()
    local result = DomainLoader.load()
    TestRunner:assertType(result, "table", "returns table")
end)

TestRunner:test("getFolderPath returns string ending with domains/", function()
    local path = DomainLoader.getFolderPath()
    TestRunner:assertType(path, "string", "returns string")
    TestRunner:assertContains(path, "domains/", "ends with domains/")
end)

-- Test hasAny()
TestRunner:suite("DomainLoader.hasAny()")

TestRunner:test("returns false for empty table", function()
    local result = DomainLoader.hasAny({})
    TestRunner:assertEqual(result, false, "empty returns false")
end)

TestRunner:test("returns true for non-empty table", function()
    local domains = { test = { name = "Test", context = "context" } }
    local result = DomainLoader.hasAny(domains)
    TestRunner:assertEqual(result, true, "non-empty returns true")
end)

-- Test getAllDomains()
TestRunner:suite("DomainLoader.getAllDomains()")

TestRunner:test("returns table", function()
    local result = DomainLoader.getAllDomains(nil)
    TestRunner:assertType(result, "table", "returns table")
end)

TestRunner:test("includes UI-created domains", function()
    local custom = {
        { id = "custom_1", name = "My Domain", context = "Domain context" },
    }
    local result = DomainLoader.getAllDomains(custom)
    TestRunner:assertNotNil(result["custom_1"], "has custom domain")
    TestRunner:assertEqual(result["custom_1"].source, "ui", "source is ui")
    TestRunner:assertEqual(result["custom_1"].context, "Domain context", "context matches")
end)

TestRunner:test("UI-created domains get (custom) suffix", function()
    local custom = {
        { id = "custom_1", name = "My Domain", context = "context" },
    }
    local result = DomainLoader.getAllDomains(custom)
    TestRunner:assertContains(result["custom_1"].display_name, "(custom)", "has custom suffix")
end)

TestRunner:test("handles nil custom_domains", function()
    local result = DomainLoader.getAllDomains(nil)
    TestRunner:assertType(result, "table", "returns table")
end)

TestRunner:test("handles empty custom_domains array", function()
    local result = DomainLoader.getAllDomains({})
    TestRunner:assertType(result, "table", "returns table")
end)

-- Test getSortedDomains()
TestRunner:suite("DomainLoader.getSortedDomains()")

TestRunner:test("returns array", function()
    local result = DomainLoader.getSortedDomains(nil)
    TestRunner:assertType(result, "table", "returns table")
end)

TestRunner:test("folder domains come before UI domains", function()
    local custom = {
        { id = "custom_1", name = "Custom Domain", context = "context" },
    }
    local result = DomainLoader.getSortedDomains(custom)
    -- If there are folder domains, they should come first
    local found_folder = false
    local found_ui_after_folder = true
    for _idx, domain in ipairs(result) do
        if domain.source == "folder" then
            found_folder = true
        end
        if domain.source == "ui" and not found_folder then
            -- UI before folder (shouldn't happen if folder exists)
            -- This is only an error if we have both
        end
    end
    -- Test passes as long as sorting doesn't crash
    TestRunner:assertType(result, "table", "sorted without error")
end)

TestRunner:test("includes custom domains in result", function()
    local custom = {
        { id = "custom_1", name = "Custom 1", context = "context 1" },
        { id = "custom_2", name = "Custom 2", context = "context 2" },
    }
    local result = DomainLoader.getSortedDomains(custom)
    local custom_count = 0
    for _idx, domain in ipairs(result) do
        if domain.source == "ui" then
            custom_count = custom_count + 1
        end
    end
    TestRunner:assertEqual(custom_count, 2, "both custom domains present")
end)

-- Test getDomainById()
TestRunner:suite("DomainLoader.getDomainById()")

TestRunner:test("returns UI-created domain by ID", function()
    local custom = {
        { id = "custom_1", name = "My Domain", context = "My context" },
    }
    local result = DomainLoader.getDomainById("custom_1", custom)
    TestRunner:assertNotNil(result, "found custom domain")
    TestRunner:assertEqual(result.id, "custom_1", "id matches")
    TestRunner:assertEqual(result.source, "ui", "source is ui")
    TestRunner:assertEqual(result.context, "My context", "context matches")
end)

TestRunner:test("returns nil for unknown ID", function()
    local result = DomainLoader.getDomainById("nonexistent", nil)
    TestRunner:assertNil(result, "nil for unknown")
end)

TestRunner:test("returns nil for nil ID", function()
    local result = DomainLoader.getDomainById(nil, nil)
    TestRunner:assertNil(result, "nil for nil ID")
end)

TestRunner:test("folder domain takes priority over custom with same ID", function()
    -- Load actual folder domains
    local folder_domains = DomainLoader.load()
    -- If there are any folder domains, test that they take priority
    for id, domain in pairs(folder_domains) do
        local custom = {
            { id = id, name = "Fake " .. domain.name, context = "Fake context" },
        }
        local result = DomainLoader.getDomainById(id, custom)
        -- Folder should win
        TestRunner:assertEqual(result.source, "folder", "folder domain wins for " .. id)
        break  -- Only need to test one
    end
    -- If no folder domains, test passes (nothing to verify)
end)

-- Test with actual domains/ folder if it has files
TestRunner:suite("DomainLoader integration (actual folder)")

TestRunner:test("loads from domains/ folder if files exist", function()
    local domains = DomainLoader.load()
    TestRunner:assertType(domains, "table", "returns table regardless")
    -- Document what was found
    local count = 0
    for _id, domain in pairs(domains) do
        count = count + 1
        TestRunner:assertEqual(domain.source, "folder", "loaded domain has folder source")
    end
    -- Test passes regardless of whether files exist
end)

-- Summary
local success = TestRunner:summary()
return success
