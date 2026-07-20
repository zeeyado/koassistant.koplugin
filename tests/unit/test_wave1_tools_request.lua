-- Unit tests for tools wave 1 request construction (DeepSeek / Mistral / Groq / xAI).
-- HANDLER-level through each provider's buildRequestBody (the real send path) so both
-- the tools declaration block AND the message-copy loop are exercised — the W4 lesson:
-- copy loops silently dropping tool_calls/tool_call_id break tool replay invisibly.
-- xAI additionally guards the routing invariant: tool sessions NEVER ride Responses.

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

local DeepSeekHandler = require("koassistant_api.deepseek")
local MistralHandler = require("koassistant_api.mistral")
local GroqHandler = require("koassistant_api.groq")
local XAIHandler = require("koassistant_api.xai")
local TestRunner = require("test_runner"):new()

print("")
print(string.rep("=", 50))
print("  Unit Tests: Tools Wave 1 Requests")
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

local TOOL_HISTORY = {
    { role = "user", content = "Where is Daisy first mentioned?" },
    { role = "assistant", content = nil, reasoning_content = "I should search.", tool_calls = {
        { id = "c1", type = "function", ["function"] = { name = "search_book", arguments = "{\"query\":\"Daisy\"}" } },
    } },
    { role = "tool", tool_call_id = "c1", content = "{\"ok\":true,\"total_hits\":2}" },
}

TestRunner:test("deepseek: config.tools becomes type=function tools + tool_choice modes", function()
    local result = DeepSeekHandler:buildRequestBody({
        { role = "user", content = "hi" },
    }, {
        api_key = "test",
        model = "deepseek-v4-pro",
        tools = { specs = SPECS, mode = "AUTO" },
    })
    local body = result.body
    TestRunner:assertTrue(body.tools ~= nil, "request has tools")
    TestRunner:assertEqual(body.tools[1].type, "function", "tool type")
    TestRunner:assertEqual(body.tools[1]["function"].name, "search_book", "function name")
    TestRunner:assertEqual(body.tool_choice, "auto", "AUTO renders auto")

    local none = DeepSeekHandler:buildRequestBody({ { role = "user", content = "hi" } },
        { api_key = "test", tools = { specs = SPECS, mode = "NONE" } })
    TestRunner:assertEqual(none.body.tool_choice, "none", "NONE renders none")
    local any = DeepSeekHandler:buildRequestBody({ { role = "user", content = "hi" } },
        { api_key = "test", tools = { specs = SPECS, mode = "ANY" } })
    TestRunner:assertEqual(any.body.tool_choice, "required", "ANY renders required")
end)

TestRunner:test("deepseek: no tools in config -> no tools/tool_choice in request", function()
    local result = DeepSeekHandler:buildRequestBody({
        { role = "user", content = "hi" },
    }, { api_key = "test", model = "deepseek-v4-pro" })
    TestRunner:assertTrue(result.body.tools == nil, "no tools array")
    TestRunner:assertTrue(result.body.tool_choice == nil, "no tool_choice")
end)

TestRunner:test("deepseek: message loop preserves tool turns AND reasoning_content", function()
    local result = DeepSeekHandler:buildRequestBody(TOOL_HISTORY, {
        api_key = "test",
        model = "deepseek-v4-pro",
        tools = { specs = SPECS, mode = "AUTO" },
    })
    local msgs = result.body.messages
    TestRunner:assertEqual(#msgs, 3, "user + assistant tool-call turn + tool result")
    TestRunner:assertEqual(msgs[2].role, "assistant", "assistant echo kept")
    TestRunner:assertTrue(msgs[2].tool_calls ~= nil, "tool_calls kept on assistant turn")
    TestRunner:assertEqual(msgs[2].reasoning_content, "I should search.",
        "reasoning_content forwarded (DeepSeek 400s without it on tool-call replay)")
    TestRunner:assertEqual(msgs[3].role, "tool", "tool result keeps role=tool")
    TestRunner:assertEqual(msgs[3].tool_call_id, "c1", "tool result keeps tool_call_id")
end)

TestRunner:test("deepseek: plain turns do NOT leak reasoning_content", function()
    local result = DeepSeekHandler:buildRequestBody({
        { role = "user", content = "hi" },
        { role = "assistant", content = "hello", reasoning_content = "thought" },
    }, { api_key = "test", model = "deepseek-v4-pro" })
    local msgs = result.body.messages
    TestRunner:assertEqual(msgs[2].content, "hello", "assistant content kept")
    TestRunner:assertTrue(msgs[2].reasoning_content == nil,
        "no reasoning_content on non-tool assistant turns")
end)

TestRunner:test("mistral: declaration + tool-turn preservation via the shared base", function()
    local result = MistralHandler:buildRequestBody(TOOL_HISTORY, {
        api_key = "test",
        model = "mistral-large-latest",
        tools = { specs = SPECS, mode = "AUTO" },
    })
    local body = result.body
    TestRunner:assertEqual(body.tools[1]["function"].name, "search_book", "tools declared")
    TestRunner:assertEqual(body.tool_choice, "auto", "tool_choice auto")
    TestRunner:assertEqual(body.messages[2].tool_calls[1].id, "c1", "tool_calls preserved")
    TestRunner:assertEqual(body.messages[3].tool_call_id, "c1", "tool result preserved")
end)

TestRunner:test("groq: declaration coexists with reasoning customization", function()
    local result = GroqHandler:buildRequestBody({
        { role = "user", content = "hi" },
    }, {
        api_key = "test",
        model = "openai/gpt-oss-120b",
        api_params = { groq_reasoning = { effort = "low" } },
        tools = { specs = SPECS, mode = "AUTO" },
    })
    local body = result.body
    TestRunner:assertEqual(body.tools[1]["function"].name, "search_book", "tools declared")
    TestRunner:assertEqual(body.reasoning_effort, "low", "reasoning_effort still applied")
end)

TestRunner:test("xai: tool session stays on the chat wire even with web search on", function()
    local result = XAIHandler:buildRequestBody(TOOL_HISTORY, {
        api_key = "test",
        model = "grok-4.5",
        enable_web_search = true,  -- would route to /v1/responses WITHOUT config.tools
        tools = { specs = SPECS, mode = "AUTO" },
    })
    TestRunner:assertTrue(result.parser == nil, "no openai_responses parser override")
    TestRunner:assertTrue(result.body.input == nil, "chat wire shape (messages, not input)")
    TestRunner:assertTrue(result.body.messages ~= nil, "messages present")
    TestRunner:assertEqual(result.body.tools[1].type, "function", "book tools declared")
    TestRunner:assertEqual(result.body.tools[1]["function"].name, "search_book", "function name")
    TestRunner:assertEqual(result.body.messages[2].tool_calls[1].id, "c1", "tool_calls preserved")
end)

TestRunner:test("xai: web-on WITHOUT tools still routes to Responses (guard the guard)", function()
    local result = XAIHandler:buildRequestBody({
        { role = "user", content = "hi" },
    }, {
        api_key = "test",
        model = "grok-4.5",
        enable_web_search = true,
    })
    TestRunner:assertEqual(result.parser, "openai_responses", "Responses parser override")
    TestRunner:assertTrue(result.body.input ~= nil, "Responses shape")
end)

return TestRunner:summary()
