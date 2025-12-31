local BaseHandler = require("api_handlers.base")
local https = require("ssl.https")
local ltn12 = require("ltn12")
local json = require("json")
local Defaults = require("api_handlers.defaults")
local RequestBuilder = require("api_handlers.request_builder")
local ResponseParser = require("api_handlers.response_parser")

local GeminiHandler = BaseHandler:new()

function GeminiHandler:query(message_history, config)
    if not config or not config.api_key then
        return "Error: Missing API key in configuration"
    end

    local defaults = Defaults.ProviderDefaults.gemini

    -- Use the RequestBuilder to create the request body
    local request_body, error = RequestBuilder:buildRequestBody(message_history, config, "gemini")
    if not request_body then
        return "Error: " .. error
    end

    -- Check if streaming is enabled
    local use_streaming = config.features and config.features.enable_streaming

    -- Debug: Print request body
    if config and config.features and config.features.debug then
        print("Gemini Request Body:", json.encode(request_body))
        print("Streaming enabled:", use_streaming and "yes" or "no")
    end

    local requestBody = json.encode(request_body)
    local headers = {
        ["Content-Type"] = "application/json",
        ["Content-Length"] = tostring(#requestBody),
    }

    -- Gemini uses different endpoints for streaming vs non-streaming
    -- Non-streaming: generateContent
    -- Streaming: streamGenerateContent
    local base_url = config.base_url or defaults.base_url

    -- If streaming is enabled, modify the endpoint
    if use_streaming then
        -- Change endpoint from generateContent to streamGenerateContent
        base_url = base_url:gsub(":generateContent$", ":streamGenerateContent")
        base_url = base_url .. "?key=" .. config.api_key .. "&alt=sse"
        headers["Accept"] = "text/event-stream"

        return self:backgroundRequest(base_url, headers, requestBody)
    end

    -- Non-streaming mode: make regular request
    -- Add API key as query parameter
    local url = base_url .. "?key=" .. config.api_key

    local responseBody = {}
    local success, code = https.request({
        url = url,
        method = "POST",
        headers = headers,
        source = ltn12.source.string(requestBody),
        sink = ltn12.sink.table(responseBody)
    })

    -- Debug: Print raw response
    if config and config.features and config.features.debug then
        print("Gemini Raw Response:", table.concat(responseBody))
    end

    local success, response = self:handleApiResponse(success, code, responseBody, "Gemini")
    if not success then
        return response
    end

    -- Debug: Print parsed response
    if config and config.features and config.features.debug then
        print("Gemini Parsed Response:", json.encode(response))
    end

    local success, result = ResponseParser:parseResponse(response, "gemini")
    if not success then
        return "Error: " .. result
    end

    return result
end

return GeminiHandler
