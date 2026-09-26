--[[--
Amazon Bedrock Converse API Handler (community set — M1,
model_management_strategy.md "End-state REVISION 2"). Uses a Bedrock API key;
AWS credential / SigV4 authentication is not supported.

@module bedrock
]]

local BaseHandler = require("koassistant_api.base")
local json = require("json")
local Defaults = require("koassistant_api.defaults")
local ResponseParser = require("koassistant_api.response_parser")
local DebugUtils = require("koassistant_debug_utils")
local ModelConstraints = require("model_constraints")

local Handler = BaseHandler:new()

local function hasText(msg)
    return msg and type(msg.content) == "string" and msg.content:match("%S") ~= nil
end

local function hasBlocks(msg)
    return msg and type(msg.content) == "table" and #msg.content > 0
end

function Handler:getModelsUrl(runtime_url)
    local control_url = runtime_url:gsub("bedrock%-runtime%.", "bedrock."):gsub("/$", "")
    return control_url .. "/foundation-models?byOutputModality=TEXT&byInferenceType=ON_DEMAND"
end

function Handler:buildRequestBody(message_history, config)
    local defaults = Defaults.ProviderDefaults.bedrock
    local model = config.model or defaults.model
    local api_params = config.api_params or {}
    local default_params = defaults.additional_parameters or {}
    local max_tokens = api_params.max_tokens
        or ModelConstraints.resolveMaxTokens("bedrock", model, default_params.max_tokens or 16384)

    local request_body = {
        messages = {},
        inferenceConfig = {
            temperature = api_params.temperature or default_params.temperature or 0.7,
            maxTokens = ModelConstraints.clampMaxTokens("bedrock", model, max_tokens),
        },
    }

    if config.system and config.system.text and config.system.text ~= "" then
        request_body.system = { { text = config.system.text } }
    end

    for _, msg in ipairs(message_history) do
        if msg.role ~= "system" and (hasText(msg) or hasBlocks(msg)) then
            table.insert(request_body.messages, {
                role = msg.role == "assistant" and "assistant" or "user",
                content = hasBlocks(msg) and msg.content or { { text = msg.content } },
            })
        end
    end

    if config.tools and type(config.tools.specs) == "table" and #config.tools.specs > 0 then
        local tools = {}
        for _, spec in ipairs(config.tools.specs) do
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
        -- ponytail: Converse has no "none" tool choice; final-pass instructions
        -- prevent extra calls. Use it if Bedrock adds a native equivalent.
    end

    local base_url = (config.base_url or defaults.base_url):gsub("/$", "")
    return {
        body = request_body,
        headers = {
            ["Content-Type"] = "application/json",
            ["Authorization"] = "Bearer " .. (config.api_key or ""),
        },
        url = base_url .. "/model/" .. model .. "/converse",
        model = model,
        provider = "bedrock",
    }
end

function Handler:query(message_history, config)
    if not config or not config.api_key then
        return "Error: Missing API key in configuration"
    end

    local built = self:buildRequestBody(message_history, config)
    if config.features and config.features.debug then
        DebugUtils.print("Amazon Bedrock Request Body:", built.body, config)
        print("Streaming enabled: no (Converse uses AWS EventStream)")
    end

    local request_body = json.encode(built.body)
    built.headers["Content-Length"] = tostring(#request_body)
    local debug_enabled = config.features and config.features.debug

    return {
        _background_fn = self:backgroundRequest(built.url, built.headers, request_body),
        _non_streaming = true,
        _response_parser = function(response)
            if debug_enabled then
                DebugUtils.print("Amazon Bedrock Parsed Response:", response, config)
            end
            local ok, result, reasoning = ResponseParser:parseResponse(response, "bedrock")
            return ok, ok and result or "Error: " .. result, reasoning
        end,
    }
end

return Handler
