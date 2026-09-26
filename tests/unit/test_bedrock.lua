-- Unit test for the Amazon Bedrock provider request shape

local info = debug.getinfo(1, "S")
local unit_dir = info.source:match("@?(.*)"):match("(.+)/[^/]+$") or "."
local tests_dir = unit_dir:match("(.+)/[^/]+$") or "."
local plugin_dir = tests_dir:match("(.+)/[^/]+$") or "."
package.path = plugin_dir .. "/?.lua;" .. tests_dir .. "/?.lua;" ..
    tests_dir .. "/lib/?.lua;" .. package.path

require("mock_koreader")

local handler = require("koassistant_api.bedrock")
local ToolWire = require("koassistant_api.tool_wire")
local ModelConstraints = require("model_constraints")
local built = handler:buildRequestBody({ { role = "user", content = "Hello" } }, {
    api_key = "test-key",
    system = { text = "Be brief." },
})

assert(built.provider == "bedrock")
assert(built.url == "https://bedrock-runtime.us-east-1.amazonaws.com/model/deepseek.v3.2/converse")
assert(built.headers.Authorization == "Bearer test-key")
assert(built.body.model == nil)
assert(built.body.system[1].text == "Be brief.")
assert(built.body.messages[1].role == "user")
assert(built.body.messages[1].content[1].text == "Hello")
assert(built.body.inferenceConfig.maxTokens == 16384)

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
local tool_built = handler:buildRequestBody({
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
assert(tool_built.body.toolConfig.tools[1].toolSpec.name == "search_book")
assert(tool_built.body.toolConfig.tools[1].toolSpec.inputSchema.json.type == "object")
assert(tool_built.body.toolConfig.toolChoice.any ~= nil)
assert(tool_built.body.messages[2].content[1].toolUse.toolUseId == "call-1")
assert(tool_built.body.messages[3].content[1].toolResult.toolUseId == "call-1")
assert(ModelConstraints.supportsCapability("bedrock", "amazon.nova-lite-v1:0", "tools"))
assert(ModelConstraints.supportsCapability("bedrock", "deepseek.v3.2", "tools"))
assert(ModelConstraints.supportsCapability("bedrock", "mistral.mistral-large-3-675b-instruct", "tools"))
assert(not ModelConstraints.supportsCapability("bedrock", "ai21.jamba-1-5-mini-v1:0", "tools"))

local ResponseParser = require("koassistant_api.response_parser")
local ModelLists = require("koassistant_model_lists")
assert(ModelLists._docs.bedrock.api_list ==
    "https://bedrock.us-east-1.amazonaws.com/foundation-models?byOutputModality=TEXT&byInferenceType=ON_DEMAND")
assert(handler:getModelsUrl("https://bedrock-runtime.eu-west-1.amazonaws.com") ==
    "https://bedrock.eu-west-1.amazonaws.com/foundation-models?byOutputModality=TEXT&byInferenceType=ON_DEMAND")
local bedrock_models, seen = ModelLists.bedrock, {}
for _, model in ipairs(bedrock_models) do
    assert(not seen[model], "duplicate Bedrock model: " .. model)
    seen[model] = true
end
assert(seen["amazon.nova-2-lite-v1:0"])
assert(seen["global.anthropic.claude-fable-5-1"])
assert(seen["openai.gpt-oss-120b-1:0"])
assert(seen["qwen.qwen3-coder-next"])
assert(not seen["amazon.nova-sonic-v1:0"])
local ok, text = ResponseParser:parseResponse({
    output = { message = { content = { { text = "Hello back" } } } },
    stopReason = "end_turn",
}, "bedrock")
assert(ok and text == "Hello back")

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

print("Amazon Bedrock provider test passed")
return true
