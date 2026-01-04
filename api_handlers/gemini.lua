local BaseHandler = require("api_handlers.base")
local https = require("ssl.https")
local ltn12 = require("ltn12")
local json = require("json")
local Defaults = require("api_handlers.defaults")
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

-- Helper: Check if message has non-empty content
local function hasContent(msg)
    if not msg or not msg.content then return false end
    if type(msg.content) == "string" then
        return msg.content:match("%S") ~= nil
    end
    return true
end

function GeminiHandler:query(message_history, config)
    if not config or not config.api_key then
        return "Error: Missing API key in configuration"
    end

    local defaults = Defaults.ProviderDefaults.gemini
    local model = config.model or defaults.model

    -- Build request body using unified config
    local request_body = {
        contents = {},
    }

    -- Add system instruction from unified config (Gemini's native approach)
    if config.system and config.system.text and config.system.text ~= "" then
        request_body.system_instruction = {
            parts = {{ text = config.system.text }}
        }
    end

    -- Add conversation messages (filter out system role and empty content)
    -- Gemini uses "model" role instead of "assistant" and parts format
    for _, msg in ipairs(message_history) do
        if msg.role ~= "system" and hasContent(msg) then
            table.insert(request_body.contents, {
                role = msg.role == "assistant" and "model" or "user",
                parts = {{ text = msg.content }}
            })
        end
    end

    -- Apply API parameters via generationConfig (Gemini's native approach)
    local api_params = config.api_params or {}
    local default_params = defaults.additional_parameters or {}

    request_body.generationConfig = {
        temperature = api_params.temperature or default_params.temperature or 0.7,
        maxOutputTokens = api_params.max_tokens or 4096,
    }

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
