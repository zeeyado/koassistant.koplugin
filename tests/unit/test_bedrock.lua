-- Amazon Bedrock (PR #113 by itsmeyaw, ported 2026-11-05): the Converse
-- request shape, the same-role merge Converse requires, the region and the
-- override, the tools wire, the parser and the seed list.

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

local TestRunner = { passed = 0, failed = 0 }
function TestRunner:test(name, fn)
    local ok, err = pcall(fn)
    if ok then
        self.passed = self.passed + 1
        print("    PASS " .. name)
    else
        self.failed = self.failed + 1
        print("    FAIL " .. name .. ": " .. tostring(err))
    end
end

local handler = require("koassistant.api.bedrock")
local ToolWire = require("koassistant.api.tool_wire")
local ModelConstraints = require("koassistant.request.model_constraints")
local ResponseParser = require("koassistant.api.response_parser")
local ModelLists = require("koassistant.request.model_lists")

TestRunner:test("a plain request: the Converse shape on the default region", function()
    local built = handler:buildRequestBody({ { role = "user", content = "Hello" } }, {
        api_key = "test-key",
        system = { text = "Be brief." },
    })
    assert(built.provider == "bedrock")
    assert(built.url == "https://bedrock-runtime.us-east-1.amazonaws.com/model/deepseek.v3.2/converse", built.url)
    assert(built.headers.Authorization == "Bearer test-key")
    assert(built.body.model == nil, "the model rides the URL, not the body")
    assert(built.body.system[1].text == "Be brief.")
    assert(built.body.messages[1].role == "user")
    assert(built.body.messages[1].content[1].text == "Hello")
    assert(built.body.inferenceConfig.maxTokens == 4096, "the community fallback")
    assert(built.body.inferenceConfig.temperature == 0.7)
end)

TestRunner:test("consecutive same-role messages fold into one turn", function()
    local built = handler:buildRequestBody({
        { role = "user", content = "Book context" },
        { role = "user", content = "The question" },
        { role = "assistant", content = "An answer" },
        { role = "assistant", content = { { text = "and more" } } },
        { role = "user", content = "   " },
        { role = "user", content = "Follow-up" },
    }, { api_key = "k" })
    local m = built.body.messages
    assert(#m == 3, "three turns, got " .. #m)
    assert(m[1].role == "user" and #m[1].content == 2 and m[1].content[2].text == "The question")
    assert(m[2].role == "assistant" and #m[2].content == 2 and m[2].content[2].text == "and more")
    assert(m[3].role == "user" and #m[3].content == 1 and m[3].content[1].text == "Follow-up",
        "a whitespace-only message is skipped")
end)

TestRunner:test("the region setting picks the runtime host; a base_url override wins", function()
    local eu = handler:buildRequestBody({ { role = "user", content = "x" } },
        { api_key = "k", features = { bedrock_region = "eu-central-1" } })
    assert(eu.url == "https://bedrock-runtime.eu-central-1.amazonaws.com/model/deepseek.v3.2/converse", eu.url)
    local own = handler:buildRequestBody({ { role = "user", content = "x" } },
        { api_key = "k", base_url = "https://proxy.example/bedrock/", features = { bedrock_region = "eu-central-1" } })
    assert(own.url == "https://proxy.example/bedrock/model/deepseek.v3.2/converse", own.url)
    assert(handler:getModelsUrl("https://bedrock-runtime.eu-west-1.amazonaws.com") ==
        "https://bedrock.eu-west-1.amazonaws.com/foundation-models?byOutputModality=TEXT&byInferenceType=ON_DEMAND")
end)

TestRunner:test("a custom_models.lua temperature rule reaches inferenceConfig", function()
    local ModelOverrides = require("koassistant.request.model_overrides")
    ModelOverrides._setUserForTests({ constraints = { bedrock = { ["deepseek.v3.2"] = { temperature = 0.2 } } } })
    local built = handler:buildRequestBody({ { role = "user", content = "x" } },
        { api_key = "k", api_params = { temperature = 0.9 } })
    ModelOverrides._setUserForTests(false)
    assert(built.body.inferenceConfig.temperature == 0.2, tostring(built.body.inferenceConfig.temperature))
end)

local specs = {
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

TestRunner:test("tools: the toolConfig and a replayed tool round", function()
    local built = handler:buildRequestBody({
        { role = "user", content = "Find Daisy." },
        { role = "assistant", content = {
            { toolUse = { toolUseId = "call-1", name = "search_book", input = { query = "Daisy" } } },
        } },
        { role = "tool", content = {
            { toolResult = { toolUseId = "call-1", content = { { json = { ok = true } } } } },
        } },
    }, {
        api_key = "test-key",
        model = "amazon.nova-lite-v1:0",
        tools = { specs = specs, mode = "ANY" },
    })
    assert(built.body.toolConfig.tools[1].toolSpec.name == "search_book")
    assert(built.body.toolConfig.tools[1].toolSpec.inputSchema.json.type == "object")
    assert(built.body.toolConfig.toolChoice.any ~= nil)
    assert(built.body.messages[2].content[1].toolUse.toolUseId == "call-1")
    assert(built.body.messages[3].role == "user", "a tool turn is a user turn on Converse")
    assert(built.body.messages[3].content[1].toolResult.toolUseId == "call-1")
    assert(ModelConstraints.supportsCapability("bedrock", "amazon.nova-lite-v1:0", "tools"))
    assert(ModelConstraints.supportsCapability("bedrock", "deepseek.v3.2", "tools"))
    assert(ModelConstraints.supportsCapability("bedrock", "mistral.mistral-large-3-675b-instruct", "tools"))
    assert(not ModelConstraints.supportsCapability("bedrock", "ai21.jamba-1-5-mini-v1:0", "tools"))
    assert(ToolWire.hasAdapter("bedrock"))
end)

TestRunner:test("the parser: text, a stop notice, tool calls and the tool turn", function()
    local ok, text = ResponseParser:parseResponse({
        output = { message = { content = { { text = "Hello back" } } } },
        stopReason = "end_turn",
    }, "bedrock")
    assert(ok and text == "Hello back", tostring(text))
    local cut_ok, cut = ResponseParser:parseResponse({
        output = { message = { content = { { text = "Half" } } } },
        stopReason = "max_tokens",
    }, "bedrock")
    assert(cut_ok and cut:find("Half", 1, true) == 1 and #cut > #"Half", "the truncation notice is appended")
    local err_ok, err = ResponseParser:parseResponse({ message = "The model is not enabled" }, "bedrock")
    assert(not err_ok and err == "The model is not enabled", tostring(err))

    local tools_ok, tool_result = ResponseParser:parseResponse({
        output = { message = { role = "assistant", content = {
            { toolUse = { toolUseId = "call-1", name = "search_book", input = { query = "Daisy" } } },
        } } },
        stopReason = "tool_use",
    }, "bedrock")
    assert(tools_ok and tool_result._tool_calls)
    assert(tool_result.calls[1].id == "call-1")
    assert(tool_result.calls[1].args.query == "Daisy")

    local tool_messages = {}
    ToolWire.appendToolTurn("bedrock", tool_messages, tool_result.raw_assistant_turn,
        { { call = tool_result.calls[1], result = { ok = true } } })
    assert(tool_messages[1].content[1].toolUse.toolUseId == "call-1")
    assert(tool_messages[2].role == "user")
    assert(tool_messages[2].content[1].toolResult.content[1].json.ok)
end)

TestRunner:test("the seed list: the default first, no duplicates, community, no tiers", function()
    local seen = {}
    for _idx, model in ipairs(ModelLists.bedrock) do
        assert(not seen[model], "duplicate Bedrock model: " .. model)
        seen[model] = true
    end
    assert(ModelLists.bedrock[1] == "deepseek.v3.2")
    assert(seen["global.anthropic.claude-sonnet-5"] and seen["amazon.nova-pro-v1:0"])
    assert(ModelLists._community.bedrock == true)
    assert(ModelLists._docs.bedrock.docs:find("Converse", 1, true))
    for tier, placements in pairs(ModelLists._tiers or {}) do
        assert(type(placements) ~= "table" or placements.bedrock == nil, "no tier placement for bedrock: " .. tostring(tier))
    end
end)

print(string.format("\n  Results: %d passed, %d failed", TestRunner.passed, TestRunner.failed))
return TestRunner.failed == 0
