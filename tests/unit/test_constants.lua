--[[
Unit Tests for koassistant_constants.lua

Tests the centralized constants module to ensure:
- Context lists are correct
- Context expansion works properly
- Validation functions behave correctly
- GitHub URLs are defined

Run: lua tests/run_tests.lua --unit
]]

-- Setup test environment
package.path = package.path .. ";./?.lua;./?/init.lua"
require("tests.lib.mock_koreader")

local Constants = require("koassistant_constants")

-- Test suite
local TestConstants = {
    passed = 0,
    failed = 0,
}

function TestConstants:test(name, fn)
    local ok, err = pcall(fn)
    if ok then
        self.passed = self.passed + 1
        print(string.format("  ✓ %s", name))
    else
        self.failed = self.failed + 1
        print(string.format("  ✗ %s: %s", name, tostring(err)))
    end
end

function TestConstants:assert(condition, message)
    if not condition then
        error(message or "Assertion failed", 2)
    end
end

function TestConstants:assertEquals(actual, expected, message)
    if actual ~= expected then
        error(string.format("%s: expected %s, got %s",
            message or "Values not equal",
            tostring(expected),
            tostring(actual)), 2)
    end
end

function TestConstants:runAll()
    print("\n=== Testing koassistant_constants.lua ===\n")

    -- Test context constants
    self:test("CONTEXTS constants are strings", function()
        self:assertEquals(type(Constants.CONTEXTS.HIGHLIGHT), "string")
        self:assertEquals(type(Constants.CONTEXTS.BOOK), "string")
        self:assertEquals(type(Constants.CONTEXTS.MULTI_BOOK), "string")
        self:assertEquals(type(Constants.CONTEXTS.GENERAL), "string")
    end)

    self:test("CONTEXTS have expected values", function()
        self:assertEquals(Constants.CONTEXTS.HIGHLIGHT, "highlight")
        self:assertEquals(Constants.CONTEXTS.BOOK, "book")
        self:assertEquals(Constants.CONTEXTS.MULTI_BOOK, "multi_book")
        self:assertEquals(Constants.CONTEXTS.GENERAL, "general")
    end)

    self:test("COMPOUND_CONTEXTS are defined", function()
        self:assertEquals(Constants.COMPOUND_CONTEXTS.BOTH, "both")
        self:assertEquals(Constants.COMPOUND_CONTEXTS.ALL, "all")
    end)

    -- Test getAllContexts
    self:test("getAllContexts returns array", function()
        local contexts = Constants.getAllContexts()
        self:assertEquals(type(contexts), "table")
        self:assert(#contexts == 4, "Should return 4 contexts")
    end)

    self:test("getAllContexts returns correct order", function()
        local contexts = Constants.getAllContexts()
        self:assertEquals(contexts[1], "highlight")
        self:assertEquals(contexts[2], "book")
        self:assertEquals(contexts[3], "multi_book")
        self:assertEquals(contexts[4], "general")
    end)

    -- Test expandContext
    self:test("expandContext handles ALL", function()
        local expanded = Constants.expandContext("all")
        self:assertEquals(#expanded, 4)
        self:assertEquals(expanded[1], "highlight")
        self:assertEquals(expanded[4], "general")
    end)

    self:test("expandContext handles BOTH", function()
        local expanded = Constants.expandContext("both")
        self:assertEquals(#expanded, 2)
        self:assertEquals(expanded[1], "highlight")
        self:assertEquals(expanded[2], "book")
    end)

    self:test("expandContext handles standard context", function()
        local expanded = Constants.expandContext("highlight")
        self:assertEquals(#expanded, 1)
        self:assertEquals(expanded[1], "highlight")
    end)

    -- Test isValidContext
    self:test("isValidContext accepts standard contexts", function()
        self:assert(Constants.isValidContext("highlight"), "highlight should be valid")
        self:assert(Constants.isValidContext("book"), "book should be valid")
        self:assert(Constants.isValidContext("multi_book"), "multi_book should be valid")
        self:assert(Constants.isValidContext("general"), "general should be valid")
    end)

    self:test("isValidContext accepts compound contexts", function()
        self:assert(Constants.isValidContext("both"), "both should be valid")
        self:assert(Constants.isValidContext("all"), "all should be valid")
    end)

    self:test("isValidContext rejects invalid contexts", function()
        self:assert(not Constants.isValidContext("invalid"), "invalid should be rejected")
        self:assert(not Constants.isValidContext(""), "empty string should be rejected")
        self:assert(not Constants.isValidContext(nil), "nil should be rejected")
    end)

    -- Test GitHub constants
    self:test("GitHub constants are defined", function()
        self:assertEquals(type(Constants.GITHUB), "table")
        self:assertEquals(type(Constants.GITHUB.REPO_OWNER), "string")
        self:assertEquals(type(Constants.GITHUB.REPO_NAME), "string")
        self:assertEquals(type(Constants.GITHUB.URL), "string")
        self:assertEquals(type(Constants.GITHUB.API_URL), "string")
    end)

    self:test("GitHub URLs are well-formed", function()
        self:assert(Constants.GITHUB.URL:match("^https://github.com/"),
            "URL should start with https://github.com/")
        self:assert(Constants.GITHUB.API_URL:match("^https://api.github.com/"),
            "API_URL should start with https://api.github.com/")
    end)

    self:test("GitHub URLs contain repo name", function()
        self:assert(Constants.GITHUB.URL:find(Constants.GITHUB.REPO_NAME),
            "URL should contain repo name")
        self:assert(Constants.GITHUB.API_URL:find(Constants.GITHUB.REPO_NAME),
            "API_URL should contain repo name")
    end)

    -- Summary
    print(string.format("\nResults: %d passed, %d failed\n", self.passed, self.failed))
    return self.failed == 0
end

-- Run tests if executed directly
if arg and arg[0] and arg[0]:match("test_constants%.lua$") then
    local success = TestConstants:runAll()
    os.exit(success and 0 or 1)
end

return TestConstants
