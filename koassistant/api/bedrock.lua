--[[--
Amazon Bedrock handler (community set; PR #113 by itsmeyaw, 2026-09-19,
ported onto the koassistant/ layout 2026-11-05 with the pieces the handler
contract asks for). The Converse API with a Bedrock API key sent as a bearer
(AWS credentials and SigV4 are not supported). One wire for every model
Bedrock serves. No streaming yet: ConverseStream is a binary event stream the
plugin cannot parse, so every answer arrives whole. Reasoning is not wired.
The runtime host follows the `bedrock_region` setting unless configuration.lua
sets base_url (an override, as for Qwen's and Kimi's regions).

@module koassistant.api.bedrock
]]

local BaseHandler = require("koassistant.api.base")
local Defaults = require("koassistant.api.defaults")
local ResponseParser = require("koassistant.api.response_parser")
local DebugUtils = require("koassistant.core.debug_utils")
local ModelConstraints = require("koassistant.request.model_constraints")

local Handler = BaseHandler:new()

Handler.DEFAULT_REGION = "us-east-1"

function Handler:getProviderName()
    return "Amazon Bedrock"
end

function Handler:getProviderKey()
    return "bedrock"
end

--- The runtime endpoint: configuration.lua's base_url override, else the host
--- of the region setting (features.bedrock_region, default us-east-1).
function Handler.baseUrl(config)
    if type(config) == "table" and type(config.base_url) == "string" and config.base_url ~= "" then
        return (config.base_url:gsub("/+$", ""))
    end
    local region = type(config) == "table" and type(config.features) == "table"
        and config.features.bedrock_region or nil
    if type(region) ~= "string" or region == "" then region = Handler.DEFAULT_REGION end
    return "https://bedrock-runtime." .. region .. ".amazonaws.com"
end

--- The URL hook the provider descriptor asks (main.lua getProviderDescriptor,
--- as Qwen's and Kimi's regions), so Fetch models and Test provider talk to
--- the region in effect.
function Handler:customizeUrl(_url, config)
    return Handler.baseUrl(config)
end

--- The control-plane list for "Fetch models": the text models served on
--- demand in the runtime host's region.
function Handler:getModelsUrl(runtime_url)
    local control_url = runtime_url:gsub("bedrock%-runtime%.", "bedrock."):gsub("/+$", "")
    return control_url .. "/foundation-models?byOutputModality=TEXT&byInferenceType=ON_DEMAND"
end

local function hasText(msg)
    return msg and type(msg.content) == "string" and msg.content:match("%S") ~= nil
end

local function hasBlocks(msg)
    return msg and type(msg.content) == "table" and #msg.content > 0
end

--- Converse takes user and assistant turns only, strictly alternating and
--- starting with a user turn. The plugin's histories hold two user messages
--- in a row all the time (the context then the question, an attachment, the
--- spoiler line, a tool round's results), and Converse rejects that with a
--- 400, so consecutive same-role messages are folded into one turn whose
--- content blocks follow each other. A string message becomes one text block.
local function converseMessages(message_history)
    local out = {}
    for _idx, msg in ipairs(message_history or {}) do
        if msg.role ~= "system" and (hasText(msg) or hasBlocks(msg)) then
            local role = msg.role == "assistant" and "assistant" or "user"
            local blocks = hasBlocks(msg) and msg.content or { { text = msg.content } }
            local last = out[#out]
            if last and last.role == role then
                for _j, block in ipairs(blocks) do last.content[#last.content + 1] = block end
            else
                local copy = {}
                for _j, block in ipairs(blocks) do copy[#copy + 1] = block end
                out[#out + 1] = { role = role, content = copy }
            end
        end
    end
    return out
end
Handler.converseMessages = converseMessages

function Handler:buildRequestBody(message_history, config)
    local defaults = Defaults.ProviderDefaults.bedrock
    local model = config.model or defaults.model
    local api_params = config.api_params or {}
    local default_params = defaults.additional_parameters or {}
    local max_tokens = api_params.max_tokens
        or ModelConstraints.resolveMaxTokens("bedrock", model, default_params.max_tokens or 4096)

    local request_body = {
        messages = converseMessages(message_history),
        inferenceConfig = {
            temperature = api_params.temperature or default_params.temperature or 0.7,
            maxTokens = ModelConstraints.clampMaxTokens("bedrock", model, max_tokens),
        },
    }
    -- The curated and custom_models.lua rules on the sampling keys (the handler
    -- constraints contract, tests/unit/test_handler_constraints.lua)
    request_body.inferenceConfig = ModelConstraints.apply("bedrock", model, request_body.inferenceConfig)

    if config.system and config.system.text and config.system.text ~= "" then
        request_body.system = { { text = config.system.text } }
    end

    if config.tools and type(config.tools.specs) == "table" and #config.tools.specs > 0 then
        local tools = {}
        for _idx, spec in ipairs(config.tools.specs) do
            table.insert(tools, {
                toolSpec = {
                    name = spec.name,
                    description = spec.description,
                    inputSchema = { json = spec.parameters },
                },
            })
        end
        request_body.toolConfig = { tools = tools }
        if config.tools.mode == "ANY" then
            request_body.toolConfig.toolChoice = { any = {} }
        elseif config.tools.mode == "AUTO" then
            request_body.toolConfig.toolChoice = { auto = {} }
        end
        -- Converse has no "none" tool choice; the runner's final-pass
        -- instructions keep the model from calling again.
    end

    return {
        body = request_body,
        headers = {
            ["Content-Type"] = "application/json",
            ["Authorization"] = "Bearer " .. (config.api_key or ""),
        },
        url = Handler.baseUrl(config) .. "/model/" .. model .. "/converse",
        model = model,
        provider = "bedrock",
    }
end

function Handler:query(message_history, config)
    if not config or not config.api_key then
        return "Error: Missing API key in configuration"
    end

    local built = self:buildRequestBody(message_history, config)
    local debug_enabled = config.features and config.features.debug
    if debug_enabled then
        DebugUtils.print("Amazon Bedrock Request Body:", built.body, config)
    end

    -- Always a whole answer (see the header): the background request, never
    -- the stream handler, whatever the streaming setting says.
    local request_body = BaseHandler.encodeBody(built.body)
    built.headers["Content-Length"] = tostring(#request_body)

    return {
        _background_fn = self:backgroundRequest(built.url, built.headers, request_body),
        _non_streaming = true,
        _response_parser = function(response)
            if debug_enabled then
                DebugUtils.print("Amazon Bedrock Parsed Response:", response, config)
            end
            local ok, result, reasoning = ResponseParser:parseResponse(response, "bedrock")
            if not ok then
                return false, "Error: " .. tostring(result)
            end
            return true, result, reasoning
        end,
    }
end

return Handler
