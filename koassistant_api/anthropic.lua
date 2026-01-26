local BaseHandler = require("koassistant_api.base")
local https = require("ssl.https")
local ltn12 = require("ltn12")
local json = require("json")
local Defaults = require("koassistant_api.defaults")
local ResponseParser = require("koassistant_api.response_parser")
local AnthropicRequest = require("koassistant_api.anthropic_request")
local ModelConstraints = require("model_constraints")

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
    })

    -- Check if streaming is enabled
    local use_streaming = config.features and config.features.enable_streaming

    -- Debug: Print constraint adjustments and request body
    if config and config.features and config.features.debug then
        ModelConstraints.logAdjustments("Anthropic", adjustments)
        print("Anthropic Request Body:", json.encode(request_body))
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

    -- Non-streaming mode: make regular request
    local responseBody = {}
    local success, code = https.request({
        url = base_url,
        method = "POST",
        headers = headers,
        source = ltn12.source.string(requestBody),
        sink = ltn12.sink.table(responseBody)
    })

    -- Debug: Print raw response
    if config and config.features and config.features.debug then
        print("Anthropic Raw Response:", table.concat(responseBody))
    end

    local success, response = self:handleApiResponse(success, code, responseBody, "Anthropic")
    if not success then
        return response
    end

    -- Debug: Print parsed response
    if config and config.features and config.features.debug then
        print("Anthropic Parsed Response:", json.encode(response))
    end

    local success, result, reasoning = ResponseParser:parseResponse(response, "anthropic")
    if not success then
        return "Error: " .. result
    end

    -- Return result with optional reasoning metadata
    -- This allows callers to access reasoning if they want it
    if reasoning then
        return {
            content = result,
            reasoning = reasoning,
            _has_reasoning = true,  -- Marker for gpt_query to detect
        }
    end

    return result
end

return AnthropicHandler
