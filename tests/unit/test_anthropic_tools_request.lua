-- Unit tests for Anthropic tool request construction.
-- NOTE: these go through AnthropicHandler:buildRequestBody (the real send path), NOT
-- AnthropicRequest:build directly — the handler reconstructs the build config, and an earlier
-- bug dropped config.tools there, so the request must be checked at the handler level.

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

local AnthropicHandler = require("koassistant_api.anthropic")
local TestRunner = require("test_runner"):new()

print("")
print(string.rep("=", 50))
print("  Unit Tests: Anthropic Tool Requests")
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

TestRunner:test("handler threads config.tools into the request (input_schema) and preserves tool-turn blocks", function()
    local result = AnthropicHandler:buildRequestBody({
        { role = "assistant", content = {
            { type = "tool_use", id = "tu1", name = "search_book", input = { query = "Daisy" } },
        } },
        { role = "user", content = {
            { type = "tool_result", tool_use_id = "tu1", content = "{\"ok\":true}" },
        } },
    }, {
        api_key = "test",
        model = "claude-sonnet-4-6",
        tools = { specs = SPECS, mode = "auto" },
    })
    local body = result.body
    TestRunner:assertTrue(body.tools ~= nil, "request has tools (config.tools threaded through the handler)")
    TestRunner:assertEqual(body.tools[1].name, "search_book", "tool declaration name")
    TestRunner:assertTrue(body.tools[1].input_schema ~= nil, "input_schema present (not parameters)")
    TestRunner:assertEqual(body.tools[1].input_schema.type, "object", "input_schema type")
    -- tool-turn content blocks survive filterMessages
    TestRunner:assertEqual(body.messages[1].role, "assistant", "assistant tool_use turn")
    TestRunner:assertEqual(body.messages[1].content[1].type, "tool_use", "tool_use block preserved")
    TestRunner:assertEqual(body.messages[2].role, "user", "tool_result turn mapped to user role")
    TestRunner:assertEqual(body.messages[2].content[1].type, "tool_result", "tool_result block preserved")
end)

TestRunner:test("final pass (mode NONE) keeps declarations and sets tool_choice none", function()
    local result = AnthropicHandler:buildRequestBody({
        { role = "assistant", content = {
            { type = "tool_use", id = "tu1", name = "search_book", input = { query = "Daisy" } },
        } },
        { role = "user", content = {
            { type = "tool_result", tool_use_id = "tu1", content = "{\"ok\":true}" },
        } },
    }, {
        api_key = "test",
        model = "claude-sonnet-4-6",
        tools = { specs = SPECS, mode = "NONE" },
    })
    local body = result.body
    TestRunner:assertTrue(body.tools ~= nil, "declarations stay (tool turns are replayed)")
    TestRunner:assertTrue(body.tool_choice ~= nil and body.tool_choice.type == "none",
        "tool_choice type none forbids further calls")
end)

TestRunner:test("book tools coexist with web search in the tools array", function()
    local result = AnthropicHandler:buildRequestBody({
        { role = "user", content = "hi" },
    }, {
        api_key = "test",
        model = "claude-sonnet-4-6",
        features = { enable_web_search = true },
        tools = { specs = SPECS },
    })
    local body = result.body
    local has_web, has_book = false, false
    for _, t in ipairs(body.tools or {}) do
        if t.type == "web_search_20250305" then has_web = true end
        if t.name == "search_book" then has_book = true end
    end
    TestRunner:assertTrue(has_web, "web_search tool present")
    TestRunner:assertTrue(has_book, "book tool present alongside web search")
end)

TestRunner:test("gather pass (mode ANY) sets tool_choice any", function()
    local result = AnthropicHandler:buildRequestBody({
        { role = "user", content = "q" },
    }, {
        model = "claude-sonnet-5",
        api_key = "test",
        tools = { specs = SPECS, mode = "ANY" },
        features = {},
    })
    TestRunner:assertEqual(result.body.tool_choice and result.body.tool_choice.type, "any",
        "mode ANY renders tool_choice {type=any} (gather rounds force a tool call)")
end)

TestRunner:test("Sonnet 5 default (no thinking param) gets visible summarized thinking", function()
    -- send_nothing carve-out: adaptive is Sonnet 5's API default and it thinks silently;
    -- display=summarized is behaviorally identical but streams the reasoning.
    local result = AnthropicHandler:buildRequestBody({
        { role = "user", content = "q" },
    }, {
        model = "claude-sonnet-5",
        api_key = "test",
        features = {},
    })
    local thinking = result.body.thinking
    TestRunner:assertEqual(thinking and thinking.type, "adaptive", "adaptive thinking set")
    TestRunner:assertEqual(thinking and thinking.display, "summarized", "summarized display set")
end)

TestRunner:test("carve-out excludes default-OFF adaptive models (Sonnet 4.6)", function()
    -- Enabling thinking on a default-off model WOULD change behavior — must stay untouched.
    local result = AnthropicHandler:buildRequestBody({
        { role = "user", content = "q" },
    }, {
        model = "claude-sonnet-4-6",
        api_key = "test",
        features = {},
    })
    TestRunner:assertEqual(result.body.thinking, nil, "no thinking param for Sonnet 4.6 default")
end)

TestRunner:test("explicit disabled thinking survives the carve-out (Sonnet 5)", function()
    local result = AnthropicHandler:buildRequestBody({
        { role = "user", content = "q" },
    }, {
        model = "claude-sonnet-5",
        api_key = "test",
        api_params = { thinking = { type = "disabled" } },
        features = {},
    })
    TestRunner:assertEqual(result.body.thinking and result.body.thinking.type, "disabled",
        "explicit off stays off — carve-out only fires when NO thinking param exists")
end)

return TestRunner:summary()
