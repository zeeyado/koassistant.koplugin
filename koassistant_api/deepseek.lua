local BaseHandler = require("koassistant_api.base")
local https = require("ssl.https")
local ltn12 = require("ltn12")
local json = require("json")
local Defaults = require("koassistant_api.defaults")
local ResponseParser = require("koassistant_api.response_parser")
local DebugUtils = require("koassistant_debug_utils")
local ModelConstraints = require("model_constraints")

local DeepSeekHandler = BaseHandler:new()

-- Helper: Check if message has non-empty content
local function hasContent(msg)
    if not msg or not msg.content then return false end
    if type(msg.content) == "string" then
        return msg.content:match("%S") ~= nil
    end
    return true
end

--- Build the request body, headers, and URL without making the API call.
--- This is used by the test inspector to see exactly what would be sent.
--- @param message_history table: Array of message objects
--- @param config table: Unified config from buildUnifiedRequestConfig
--- @return table: { body = table, headers = table, url = string }
function DeepSeekHandler:buildRequestBody(message_history, config)
    local defaults = Defaults.ProviderDefaults.deepseek
    local model = config.model or defaults.model

    -- Build request body using unified config
    local request_body = {
        model = model,
        messages = {},
    }

    -- Add system message from unified config
    if config.system and config.system.text and config.system.text ~= "" then
        table.insert(request_body.messages, {
            role = "system",
            content = config.system.text,
        })
    end

    -- Add conversation messages (filter out system role and empty content).
    -- Tool turns must survive intact: an assistant tool-call turn keeps tool_calls (its
    -- content may legitimately be nil) AND reasoning_content — since V3.2 DeepSeek
    -- REQUIRES reasoning_content back on replayed tool-call turns (400 if missing;
    -- on non-tool turns it is simply ignored). Tool-result turns keep role="tool" +
    -- tool_call_id.
    for _, msg in ipairs(message_history) do
        if msg.role == "tool" and msg.tool_call_id then
            table.insert(request_body.messages, {
                role = "tool",
                tool_call_id = msg.tool_call_id,
                content = msg.content,
            })
        elseif msg.role == "assistant" and msg.tool_calls then
            table.insert(request_body.messages, {
                role = "assistant",
                content = msg.content,
                tool_calls = msg.tool_calls,
                reasoning_content = msg.reasoning_content,
            })
        elseif msg.role ~= "system" and hasContent(msg) then
            table.insert(request_body.messages, {
                role = msg.role == "assistant" and "assistant" or "user",
                content = msg.content,
            })
        end
    end

    -- Apply API parameters from unified config
    local api_params = config.api_params or {}
    local default_params = defaults.additional_parameters or {}

    request_body.temperature = api_params.temperature or default_params.temperature or 0.7
    request_body.max_tokens = api_params.max_tokens or default_params.max_tokens or 16384
    request_body.max_tokens = ModelConstraints.clampMaxTokens("deepseek", model, request_body.max_tokens)

    -- DeepSeek V4 thinking toggle (resolved upstream by the reasoning resolver).
    -- When the resolver emits nothing (model behaves at its API default) we omit
    -- `thinking` entirely so V4's default-on behaviour applies; an explicit
    -- enabled/disabled decision is honoured as-is.
    request_body.thinking = api_params.deepseek_thinking

    -- Book-tool declarations from the neutral config.tools (set by the tool runner).
    -- Same OpenAI-shaped rendering as openai_compatible.lua; gated upstream by the
    -- deepseek `tools` capability list in model_constraints.lua.
    if config.tools and config.tools.specs then
        -- Force thinking OFF for tool sessions. DeepSeek V4 thinks by DEFAULT, and its
        -- thinking mode rejects tool_choice "required" (our gather rounds, mode ANY) with
        -- 400 "Thinking mode does not support this tool_choice" (and only loosely tolerates
        -- "none"). {type="disabled"} is DeepSeek's documented toggle, so we override the
        -- resolver's decision (incl. its default-on omission) to restore full tool_choice
        -- control. Only the mechanical lookup turns lose thinking: gather mode's phase-2
        -- answer carries NO config.tools, so it still streams with the model's default
        -- thinking.
        request_body.thinking = { type = "disabled" }
        request_body.tools = {}
        for _, spec in ipairs(config.tools.specs) do
            table.insert(request_body.tools, {
                type = "function",
                ["function"] = {
                    name = spec.name,
                    description = spec.description,
                    parameters = spec.parameters,
                },
            })
        end
        if config.tools.mode == "NONE" then
            request_body.tool_choice = "none"
        elseif config.tools.mode == "ANY" then
            request_body.tool_choice = "required"
        else
            request_body.tool_choice = "auto"
        end
    end

    local headers = {
        ["Content-Type"] = "application/json",
        ["Authorization"] = "Bearer " .. (config.api_key or ""),
    }

    local url = config.base_url or defaults.base_url

    return {
        body = request_body,
        headers = headers,
        url = url,
        model = model,
        provider = "deepseek",
    }
end

function DeepSeekHandler:query(message_history, config)
    if not config or not config.api_key then
        return "Error: Missing API key in configuration"
    end

    -- Build request using shared method (single source of truth)
    local built = self:buildRequestBody(message_history, config)
    local request_body = built.body
    local base_url = built.url

    -- Check if streaming is enabled
    local use_streaming = config.features and config.features.enable_streaming

    -- Debug: Print request body
    if config and config.features and config.features.debug then
        DebugUtils.print("DeepSeek Request Body:", request_body, config)
        print("Streaming enabled:", use_streaming and "yes" or "no")
    end

    local requestBody = json.encode(request_body)
    local headers = built.headers
    headers["Content-Length"] = tostring(#requestBody)

    -- If streaming is enabled, return the background request function
    if use_streaming then
        -- Add stream parameter to request body
        local stream_request_body = json.decode(requestBody)
        stream_request_body.stream = true
        local stream_body = json.encode(stream_request_body)
        headers["Content-Length"] = tostring(#stream_body)
        headers["Accept"] = "text/event-stream"

        return self:backgroundRequest(base_url, headers, stream_body)
    end

    -- Non-streaming mode: use background request for non-blocking UI
    local debug_enabled = config and config.features and config.features.debug

    local response_parser = function(response)
        -- Debug: Print parsed response
        if debug_enabled then
            DebugUtils.print("DeepSeek Parsed Response:", response, config)
        end

        local parse_success, result, reasoning = ResponseParser:parseResponse(response, "deepseek")
        if not parse_success then
            return false, "Error: " .. result
        end

        -- Return with reasoning metadata if available (deepseek-reasoner)
        return true, result, reasoning
    end

    return {
        _background_fn = self:backgroundRequest(base_url, headers, requestBody),
        _non_streaming = true,
        _response_parser = response_parser,
    }
end

return DeepSeekHandler
