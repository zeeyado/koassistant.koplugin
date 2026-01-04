local BaseHandler = require("api_handlers.base")
local http = require("socket.http")
local ltn12 = require("ltn12")
local json = require("json")
local Defaults = require("api_handlers.defaults")
local RequestBuilder = require("api_handlers.request_builder")
local ResponseParser = require("api_handlers.response_parser")

local OllamaHandler = BaseHandler:new()

function OllamaHandler:query(message_history, config)
    local defaults = Defaults.ProviderDefaults.ollama

    -- Use the RequestBuilder to create the request body
    local request_body, error = RequestBuilder:buildRequestBody(message_history, config, "ollama")
    if not request_body then
        return "Error: " .. error
    end

    -- Check if streaming is enabled
    local use_streaming = config.features and config.features.enable_streaming

    -- Set stream parameter based on config
    request_body.stream = use_streaming and true or false

    -- Debug: Print request body
    if config and config.features and config.features.debug then
        print("Ollama Request Body:", json.encode(request_body))
        print("Streaming enabled:", use_streaming and "yes" or "no")
    end

    local requestBody = json.encode(request_body)
    local headers = {
        ["Content-Type"] = "application/json",
        ["Content-Length"] = tostring(#requestBody),
    }

    local base_url = config.base_url or defaults.base_url

    -- If streaming is enabled, return the background request function
    if use_streaming then
        -- Ollama uses NDJSON format (newline-delimited JSON), not SSE
        -- The stream_handler will detect and handle this format
        return self:backgroundRequest(base_url, headers, requestBody)
    end

    -- Non-streaming mode: make regular request
    local responseBody = {}
    local success, code = http.request({
        url = base_url,
        method = "POST",
        headers = headers,
        source = ltn12.source.string(requestBody),
        sink = ltn12.sink.table(responseBody)
    })

    -- Debug: Print raw response
    if config and config.features and config.features.debug then
        print("Ollama Raw Response:", table.concat(responseBody))
    end

    local success, response = self:handleApiResponse(success, code, responseBody, "Ollama")
    if not success then
        return response
    end

    -- Debug: Print parsed response
    if config and config.features and config.features.debug then
        print("Ollama Parsed Response:", json.encode(response))
    end

    local success, result = ResponseParser:parseResponse(response, "ollama")
    if not success then
        return "Error: " .. result
    end

    return result
end

return OllamaHandler
