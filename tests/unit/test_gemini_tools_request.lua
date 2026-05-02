-- Unit tests for Gemini tool request construction

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
require("mock_koreader")

local GeminiHandler = require("koassistant_api.gemini")

local TestRunner = {
    passed = 0,
    failed = 0,
}

function TestRunner:test(name, fn)
    local ok, err = pcall(fn)
    if ok then
        self.passed = self.passed + 1
        print(string.format("    PASS %s", name))
    else
        self.failed = self.failed + 1
        print(string.format("    FAIL %s", name))
        print(string.format("      Error: %s", tostring(err)))
    end
end

function TestRunner:assertEqual(actual, expected, msg)
    if actual ~= expected then
        error(string.format("%s: expected %q, got %q", msg or "Assertion failed", tostring(expected), tostring(actual)))
    end
end

function TestRunner:assertTrue(value, msg)
    if not value then
        error(string.format("%s: expected true", msg or "Assertion failed"))
    end
end

function TestRunner:summary()
    print("")
    local total = self.passed + self.failed
    if self.failed == 0 then
        print(string.format("  All %d Gemini tool request tests passed!", total))
    else
        print(string.format("  %d passed, %d failed (of %d total)", self.passed, self.failed, total))
    end
    return self.failed == 0
end

print("")
print(string.rep("=", 50))
print("  Unit Tests: Gemini Tool Requests")
print(string.rep("=", 50))

TestRunner:test("preserves raw Gemini parts and adds function declarations", function()
    local function_declarations = {
        {
            name = "search_book",
            description = "Search book text.",
            parameters = {
                type = "object",
                properties = {
                    query = { type = "string" },
                },
                required = { "query" },
            },
        },
    }

    local result = GeminiHandler:buildRequestBody({
        {
            role = "model",
            parts = {
                {
                    functionCall = {
                        name = "search_book",
                        args = { query = "Daisy" },
                    },
                },
            },
        },
        {
            role = "tool",
            parts = {
                {
                    functionResponse = {
                        name = "search_book",
                        response = { ok = true },
                    },
                },
            },
        },
    }, {
        api_key = "test",
        model = "gemini-2.5-flash",
        gemini_tools = {
            function_declarations = function_declarations,
            mode = "AUTO",
        },
    })

    local body = result.body
    TestRunner:assertEqual(body.contents[1].role, "model", "model role")
    TestRunner:assertEqual(body.contents[2].role, "user", "tool response role")
    TestRunner:assertTrue(body.contents[1].parts[1].functionCall ~= nil, "function call part")
    TestRunner:assertTrue(body.contents[2].parts[1].functionResponse ~= nil, "function response part")
    TestRunner:assertEqual(body.tools[1].functionDeclarations[1].name, "search_book", "tool declaration")
    TestRunner:assertEqual(body.toolConfig.functionCallingConfig.mode, "AUTO", "tool mode")
end)

return TestRunner:summary()
