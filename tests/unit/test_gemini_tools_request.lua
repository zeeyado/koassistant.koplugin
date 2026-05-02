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

local TestRunner = require("test_runner"):new()

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
