-- Unit tests for koassistant_api/tool_wire.lua (provider tool-turn adapters)

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

local ToolWire = require("koassistant_api.tool_wire")
local TestRunner = require("test_runner"):new()

print("")
print(string.rep("=", 50))
print("  Unit Tests: Tool Wire (provider adapters)")
print(string.rep("=", 50))

TestRunner:test("hasAdapter recognizes registered providers only", function()
    TestRunner:assertTrue(ToolWire.hasAdapter("gemini"), "gemini")
    TestRunner:assertTrue(ToolWire.hasAdapter("anthropic"), "anthropic")
    TestRunner:assertFalse(ToolWire.hasAdapter("openai"), "openai (no adapter yet)")
    TestRunner:assertFalse(ToolWire.hasAdapter(nil), "nil provider")
end)

TestRunner:test("stringifyResult JSON-encodes a result table losslessly", function()
    local s = ToolWire.stringifyResult("search_book", { ok = true, total_hits = 3 })
    TestRunner:assertTrue(type(s) == "string", "returns string")
    TestRunner:assertTrue(s:find("total_hits", 1, true) ~= nil, "contains field name")
    TestRunner:assertTrue(s:find("3", 1, true) ~= nil, "contains value")
end)

TestRunner:test("gemini adapter echoes parts and appends functionResponse parts", function()
    local messages = { { role = "user", content = "hi" } }
    local raw = { role = "model", parts = { { functionCall = { name = "search_book", args = {} } } } }
    local executed = { { call = { name = "search_book", id = "c1" }, result = { ok = true } } }
    ToolWire.appendToolTurn("gemini", messages, raw, executed)
    TestRunner:assertEqual(#messages, 3, "two messages appended")
    TestRunner:assertEqual(messages[2].role, "model", "model echo role")
    TestRunner:assertTrue(messages[2].parts[1].functionCall ~= nil, "echoes functionCall part")
    TestRunner:assertEqual(messages[3].role, "tool", "tool turn role")
    TestRunner:assertEqual(messages[3].parts[1].functionResponse.name, "search_book", "functionResponse name")
    TestRunner:assertEqual(messages[3].parts[1].functionResponse.id, "c1", "functionResponse id")
end)

TestRunner:test("anthropic adapter echoes content and appends tool_result blocks", function()
    local messages = { { role = "user", content = "hi" } }
    local raw = { role = "assistant", content = {
        { type = "text", text = "let me look" },
        { type = "tool_use", id = "tu1", name = "search_book", input = {} },
    } }
    local executed = { { call = { name = "search_book", id = "tu1" }, result = { ok = true, total_hits = 2 } } }
    ToolWire.appendToolTurn("anthropic", messages, raw, executed)
    TestRunner:assertEqual(#messages, 3, "two messages appended")
    TestRunner:assertEqual(messages[2].role, "assistant", "assistant echo role")
    TestRunner:assertEqual(messages[2].content[2].type, "tool_use", "echoes tool_use block")
    TestRunner:assertEqual(messages[3].role, "user", "tool_result goes on a user turn")
    TestRunner:assertEqual(messages[3].content[1].type, "tool_result", "tool_result block")
    TestRunner:assertEqual(messages[3].content[1].tool_use_id, "tu1", "tool_use_id linkage")
    TestRunner:assertTrue(type(messages[3].content[1].content) == "string", "result stringified")
end)

TestRunner:test("appendToolTurn is a no-op for an unknown provider", function()
    local messages = { { role = "user", content = "hi" } }
    ToolWire.appendToolTurn("openai", messages, { content = {} }, { { call = { name = "x" }, result = {} } })
    TestRunner:assertEqual(#messages, 1, "no messages appended")
end)

return TestRunner:summary()
