local BaseHandler = require("koassistant_api.base")
local https = require("ssl.https")
local ltn12 = require("ltn12")
local json = require("json")
local Defaults = require("koassistant_api.defaults")
local ResponseParser = require("koassistant_api.response_parser")
local AnthropicRequest = require("koassistant_api.anthropic_request")
local ModelConstraints = require("model_constraints")
local DebugUtils = require("koassistant_debug_utils")

local AnthropicHandler = BaseHandler:new()

--- Build the request body, headers, and URL without making the API call.
--- This is used by the test inspector to see exactly what would be sent.
--- @param message_history table: Array of message objects
--- @param config table: Unified config from buildUnifiedRequestConfig
--- @return table: { body = table, headers = table, url = string }
function AnthropicHandler:buildRequestBody(message_history, config)
    local defaults = Defaults.ProviderDefaults.anthropic
    local model = config.model or defaults.model

    -- Build request using AnthropicRequest with unified config
    local request_body, adjustments = AnthropicRequest:build({
        model = model,
        messages = message_history,
        system = config.system,  -- Unified format from buildUnifiedRequestConfig
        api_params = config.api_params,
        additional_parameters = config.additional_parameters,
        features = config.features,  -- For web search global setting
        enable_web_search = config.enable_web_search,  -- Per-action override
    })

    local headers = {
        ["Content-Type"] = "application/json",
        ["x-api-key"] = config.api_key or "",
        ["anthropic-version"] = defaults.additional_parameters.anthropic_version,
        ["anthropic-beta"] = AnthropicRequest.CACHE_BETA,  -- Enable prompt caching
    }

    local url = config.base_url or defaults.base_url

    return {
        body = request_body,
        headers = headers,
        url = url,
        model = model,
        provider = "anthropic",
        adjustments = adjustments,  -- Include for test inspector visibility
    }
end

function AnthropicHandler:query(message_history, config)
    if not config or not config.api_key then
        return "Error: Missing API key in configuration"
    end

    local defaults = Defaults.ProviderDefaults.anthropic

    -- Build request using AnthropicRequest with unified config
    local request_body, adjustments = AnthropicRequest:build({
        model = config.model or defaults.model,
        messages = message_history,
        system = config.system,  -- Unified format from buildUnifiedRequestConfig
        api_params = config.api_params,
        additional_parameters = config.additional_parameters,
        features = config.features,  -- For web search global setting
        enable_web_search = config.enable_web_search,  -- Per-action override
    })

    -- Check if streaming is enabled
    local use_streaming = config.features and config.features.enable_streaming

    -- Debug: Print constraint adjustments and request body
    if config and config.features and config.features.debug then
        ModelConstraints.logAdjustments("Anthropic", adjustments)
        DebugUtils.print("Anthropic Request Body:", request_body, config)
        print("Streaming enabled:", use_streaming and "yes" or "no")
    end

    local requestBody = json.encode(request_body)
    local headers = {
        ["Content-Type"] = "application/json",
        ["x-api-key"] = config.api_key,
        ["anthropic-version"] = defaults.additional_parameters.anthropic_version,
        ["anthropic-beta"] = AnthropicRequest.CACHE_BETA,  -- Enable prompt caching
        ["Content-Length"] = tostring(#requestBody),
    }

    local base_url = config.base_url or defaults.base_url

    -- If streaming is enabled, return the background request function
    if use_streaming then
        -- Add stream parameter to request body
        local stream_request_body = json.decode(requestBody)
        stream_request_body.stream = true
        local stream_body = json.encode(stream_request_body)
        headers["Content-Length"] = tostring(#stream_body)
        headers["Accept"] = "text/event-stream"

        -- Return the background request function for streaming
        -- The caller (gpt_query.lua) will detect this and handle streaming
        return self:backgroundRequest(base_url, headers, stream_body)
    end

    -- Non-streaming mode: use background request for non-blocking UI
    -- Return function and parser for gpt_query.lua to handle
    local response_parser = function(response)
        -- Debug: Print parsed response
        if config and config.features and config.features.debug then
            DebugUtils.print("Anthropic Parsed Response:", response, config)
        end

        local parse_success, result, reasoning, web_search_used = ResponseParser:parseResponse(response, "anthropic")
        if not parse_success then
            return false, "Error: " .. result
        end

        return true, result, reasoning, web_search_used
    end

    return {
        _background_fn = self:backgroundRequest(base_url, headers, requestBody),
        _non_streaming = true,
        _response_parser = response_parser,
    }
end

return AnthropicHandler
