-- Unit tests for OpenAI tool request construction.
-- These go through OpenAIHandler:buildRequestBody (the real send path) to exercise BOTH the
-- tools declaration block AND the message-copy loop — the loop previously dropped
-- tool_calls/tool_call_id and coerced role="tool" to user, which would break tool replay.

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

local OpenAIHandler = require("koassistant_api.openai")
local TestRunner = require("test_runner"):new()

print("")
print(string.rep("=", 50))
print("  Unit Tests: OpenAI Tool Requests")
print(string.rep("=", 50))

local SPECS = {
    {
        name = "search_book",
        description = "Search book text.",
        parameters = {
            type = "object",
            properties = { query = { type = "string" } },
            required = { "query" },
        },
    },
}

TestRunner:test("declaration: config.tools becomes type=function tools + tool_choice=auto", function()
    local result = OpenAIHandler:buildRequestBody({
        { role = "user", content = "hi" },
    }, {
        api_key = "test",
        model = "gpt-5.5",
        tools = { specs = SPECS, mode = "AUTO" },
    })
    local body = result.body
    TestRunner:assertTrue(body.tools ~= nil, "request has tools")
    TestRunner:assertEqual(body.tools[1].type, "function", "tool type")
    TestRunner:assertEqual(body.tools[1]["function"].name, "search_book", "function name")
    TestRunner:assertTrue(body.tools[1]["function"].parameters ~= nil, "parameters schema present")
    TestRunner:assertEqual(body.tool_choice, "auto", "tool_choice is lowercase auto")
end)

TestRunner:test("no tools in config -> no tools/tool_choice in request", function()
    local result = OpenAIHandler:buildRequestBody({
        { role = "user", content = "hi" },
    }, {
        api_key = "test",
        model = "gpt-5.5",
    })
    TestRunner:assertTrue(result.body.tools == nil, "no tools array")
    TestRunner:assertTrue(result.body.tool_choice == nil, "no tool_choice")
end)

TestRunner:test("message loop preserves assistant tool_calls turn (nil content) and role=tool turns", function()
    local result = OpenAIHandler:buildRequestBody({
        { role = "user", content = "Where is Daisy first mentioned?" },
        { role = "assistant", content = nil, tool_calls = {
            { id = "c1", type = "function", ["function"] = { name = "search_book", arguments = "{\"query\":\"Daisy\"}" } },
        } },
        { role = "tool", tool_call_id = "c1", content = "{\"ok\":true,\"total_hits\":2}" },
    }, {
        api_key = "test",
        model = "gpt-5.5",
        tools = { specs = SPECS },
    })
    local msgs = result.body.messages
    TestRunner:assertEqual(#msgs, 3, "all three turns survive the copy loop")
    TestRunner:assertEqual(msgs[2].role, "assistant", "assistant turn kept despite nil content")
    TestRunner:assertTrue(msgs[2].tool_calls ~= nil, "tool_calls preserved on assistant turn")
    TestRunner:assertEqual(msgs[2].tool_calls[1].id, "c1", "tool_call id intact")
    TestRunner:assertEqual(msgs[3].role, "tool", "tool role NOT coerced to user")
    TestRunner:assertEqual(msgs[3].tool_call_id, "c1", "tool_call_id preserved")
    TestRunner:assertTrue(type(msgs[3].content) == "string", "tool result content is a string")
end)

TestRunner:test("final pass (mode NONE) keeps declarations and sets tool_choice none", function()
    local result = OpenAIHandler:buildRequestBody({
        { role = "user", content = "hi" },
    }, {
        api_key = "test",
        model = "gpt-5.5",
        tools = { specs = SPECS, mode = "NONE" },
    })
    TestRunner:assertTrue(result.body.tools ~= nil, "declarations stay on the final pass")
    TestRunner:assertEqual(result.body.tool_choice, "none", "tool_choice none on the final pass")
end)

TestRunner:test("assistant tool_calls turn keeps reasoning_details through the copy loop", function()
    local result = OpenAIHandler:buildRequestBody({
        { role = "assistant", content = nil,
          tool_calls = { { id = "c1", type = "function", ["function"] = { name = "toc", arguments = "{}" } } },
          reasoning_details = { { type = "reasoning.text", text = "thinking..." } } },
        { role = "tool", tool_call_id = "c1", content = "{}" },
    }, {
        api_key = "test",
        model = "gpt-5.5",
        tools = { specs = SPECS },
    })
    TestRunner:assertTrue(result.body.messages[1].reasoning_details ~= nil,
        "reasoning_details preserved (OpenRouter thinking backends require it)")
end)

-- OpenRouter rides the same OpenAI wire format through openai_compatible.lua
TestRunner:test("openrouter (compatible family): declaration + tool turns survive", function()
    local OpenRouterHandler = require("koassistant_api.openrouter")
    local result = OpenRouterHandler:buildRequestBody({
        { role = "user", content = "Where is Daisy first mentioned?" },
        { role = "assistant", content = nil, tool_calls = {
            { id = "c1", type = "function", ["function"] = { name = "search_book", arguments = "{\"query\":\"Daisy\"}" } },
        } },
        { role = "tool", tool_call_id = "c1", content = "{\"ok\":true}" },
    }, {
        api_key = "test",
        model = "anthropic/claude-sonnet-5",
        tools = { specs = SPECS, mode = "AUTO" },
    })
    local body = result.body
    TestRunner:assertEqual(body.tools[1].type, "function", "tools declared in OpenAI format")
    TestRunner:assertEqual(body.tool_choice, "auto", "tool_choice auto")
    TestRunner:assertEqual(#body.messages, 3, "all turns survive")
    TestRunner:assertTrue(body.messages[2].tool_calls ~= nil, "tool_calls preserved")
    TestRunner:assertEqual(body.messages[3].role, "tool", "tool role preserved")
    TestRunner:assertEqual(body.messages[3].tool_call_id, "c1", "tool_call_id preserved")
end)

return TestRunner:summary()
