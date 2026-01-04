local BaseHandler = require("api_handlers.base")
local https = require("ssl.https")
local ltn12 = require("ltn12")
local json = require("json")
local Defaults = require("api_handlers.defaults")
local RequestBuilder = require("api_handlers.request_builder")
local ResponseParser = require("api_handlers.response_parser")

local GeminiHandler = BaseHandler:new()

-- Build the full Gemini API URL with model name
-- @param base_url string: Base URL (without model)
-- @param model string: Model name
-- @param streaming boolean: Whether to use streaming endpoint
-- @return string: Full URL
local function buildGeminiUrl(base_url, model, streaming)
    local endpoint = streaming and ":streamGenerateContent" or ":generateContent"
    local url = base_url .. "/" .. model .. endpoint
    if streaming then
        url = url .. "?alt=sse"
    end
    return url
end

-- Extract system messages from message history for system_instruction
-- @param messages table: Message history
-- @return string|nil: Combined system instruction text
local function extractSystemInstruction(messages)
    local system_parts = {}
    for _, msg in ipairs(messages) do
        if msg.role == "system" and msg.content and msg.content ~= "" then
            table.insert(system_parts, msg.content)
        end
    end
    if #system_parts > 0 then
        return table.concat(system_parts, "\n\n")
    end
    return nil
end

function GeminiHandler:query(message_history, config)
    if not config or not config.api_key then
        return "Error: Missing API key in configuration"
    end

    local defaults = Defaults.ProviderDefaults.gemini
    local model = config.model or defaults.model

    -- Use the RequestBuilder to create the request body
    local request_body, error = RequestBuilder:buildRequestBody(message_history, config, "gemini")
    if not request_body then
        return "Error: " .. error
    end

    -- Extract system instruction from message history
    local system_instruction = extractSystemInstruction(message_history)
    if system_instruction then
        request_body.system_instruction = {
            parts = {{ text = system_instruction }}
        }
    end

    -- Check if streaming is enabled
    local use_streaming = config.features and config.features.enable_streaming

    -- Debug: Print request body
    if config and config.features and config.features.debug then
        print("Gemini Request Body:", json.encode(request_body))
        print("Streaming enabled:", use_streaming and "yes" or "no")
        print("Model:", model)
    end

    local requestBody = json.encode(request_body)

    -- Use header-based authentication (more secure than query param)
    local headers = {
        ["Content-Type"] = "application/json",
        ["x-goog-api-key"] = config.api_key,
        ["Content-Length"] = tostring(#requestBody),
    }

    local base_url = config.base_url or defaults.base_url

    -- If streaming is enabled, return the background request function
    if use_streaming then
        local stream_url = buildGeminiUrl(base_url, model, true)
        headers["Accept"] = "text/event-stream"

        return self:backgroundRequest(stream_url, headers, requestBody)
    end

    -- Non-streaming mode: make regular request
    local url = buildGeminiUrl(base_url, model, false)

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
