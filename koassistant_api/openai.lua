local BaseHandler = require("koassistant_api.base")
local https = require("ssl.https")
local ltn12 = require("ltn12")
local json = require("json")
local Defaults = require("koassistant_api.defaults")
local ResponseParser = require("koassistant_api.response_parser")
local ModelConstraints = require("model_constraints")
local DebugUtils = require("koassistant_debug_utils")

local OpenAIHandler = BaseHandler:new()

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
function OpenAIHandler:buildRequestBody(message_history, config)
    local defaults = Defaults.ProviderDefaults.openai
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

    -- Add conversation messages (filter out system role and empty content)
    for _, msg in ipairs(message_history) do
        if msg.role ~= "system" and hasContent(msg) then
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

    -- Reasoning models (o3, o4-mini, GPT-5) share max_completion_tokens between
    -- reasoning and content. Bump default to give headroom (like Gemini's 32768).
    -- Only when action didn't explicitly set max_tokens.
    if not api_params.max_tokens and ModelConstraints.supportsCapability("openai", model, "reasoning") then
        request_body.max_tokens = 32768
    end

    -- OpenAI's newer models (GPT-5.x, o-series, GPT-4.1) require max_completion_tokens instead of max_tokens
    local needs_new_param = model:match("^gpt%-5") or model:match("^o%d") or model:match("^gpt%-4%.1")
    if needs_new_param and request_body.max_tokens then
        request_body.max_completion_tokens = request_body.max_tokens
        request_body.max_tokens = nil
    end

    -- Apply model-specific constraints (e.g., temperature=1.0 for gpt-5/o3 models)
    local adjustments
    request_body, adjustments = ModelConstraints.apply("openai", model, request_body)

    -- Add reasoning effort for o-series and GPT-5 models if enabled
    -- OpenAI uses reasoning_effort as a top-level parameter (low/medium/high)
    if api_params.reasoning and api_params.reasoning.effort then
        if ModelConstraints.supportsCapability("openai", model, "reasoning") then
            request_body.reasoning_effort = api_params.reasoning.effort
        else
            adjustments.reasoning_skipped = {
                reason = "model " .. model .. " does not support reasoning"
            }
        end
    end

    -- Note: OpenAI Chat Completions API does not support native web search.
    -- Web search requires function calling with user-provided search tools.
    -- For now, web search is not supported for OpenAI direct.

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
        provider = "openai",
        adjustments = adjustments,  -- Include for test inspector visibility
    }
end

function OpenAIHandler:query(message_history, config)
    if not config or not config.api_key then
        return "Error: Missing API key in configuration"
    end

    -- Use buildRequestBody to construct the request (single source of truth)
    local built = self:buildRequestBody(message_history, config)
    local request_body = built.body
    local base_url = built.url
    local adjustments = built.adjustments

    -- Check if streaming is enabled
    local use_streaming = config.features and config.features.enable_streaming

    -- Debug: Print constraint adjustments and request body
    if config and config.features and config.features.debug then
        ModelConstraints.logAdjustments("OpenAI", adjustments)
        DebugUtils.print("OpenAI Request Body:", request_body, config)
        print("Streaming enabled:", use_streaming and "yes" or "no")
    end

    local requestBody = json.encode(request_body)
    local headers = {
        ["Content-Type"] = "application/json",
        ["Authorization"] = "Bearer " .. config.api_key,
        ["Content-Length"] = tostring(#requestBody),
    }

    -- If streaming is enabled, return the background request function
    if use_streaming then
        -- Add stream parameter to request body
        local stream_request_body = json.decode(requestBody)
        stream_request_body.stream = true
        local stream_body = json.encode(stream_request_body)
        headers["Content-Length"] = tostring(#stream_body)
        headers["Accept"] = "text/event-stream"

        local stream_fn = self:backgroundRequest(base_url, headers, stream_body)

        -- If reasoning was requested, wrap the function with metadata
        -- so gpt_query.lua knows to show "reasoning requested" indicator
        if request_body.reasoning_effort then
            return {
                _stream_fn = stream_fn,
                _reasoning_requested = true,
                _reasoning_effort = request_body.reasoning_effort,
            }
        end

        return stream_fn
    end

    -- Non-streaming mode: use background request for non-blocking UI
    local reasoning_effort = request_body.reasoning_effort
    local debug_enabled = config and config.features and config.features.debug

    local response_parser = function(response)
        -- Debug: Print parsed response
        if debug_enabled then
            DebugUtils.print("OpenAI Parsed Response:", response, config)
        end

        local parse_success, result, reasoning = ResponseParser:parseResponse(response, "openai")
        if not parse_success then
            return false, "Error: " .. result
        end

        -- Return with reasoning metadata if requested
        if reasoning_effort then
            return true, result, { _requested = true, effort = reasoning_effort }
        end

        return true, result
    end

    return {
        _background_fn = self:backgroundRequest(base_url, headers, requestBody),
        _non_streaming = true,
        _response_parser = response_parser,
    }
end

return OpenAIHandler
