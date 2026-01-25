local BaseHandler = require("api_handlers.base")
local https = require("ssl.https")
local ltn12 = require("ltn12")
local json = require("json")
local ResponseParser = require("api_handlers.response_parser")

--- Generic OpenAI-compatible handler for custom providers
--- Used for user-defined providers that follow the OpenAI API format
local CustomOpenAIHandler = BaseHandler:new()

-- Helper: Check if message has non-empty content
local function hasContent(msg)
    if not msg or not msg.content then return false end
    if type(msg.content) == "string" then
        return msg.content:match("%S") ~= nil
    end
    return true
end

--- Build the request body, headers, and URL without making the API call.
--- @param message_history table: Array of message objects
--- @param config table: Unified config from buildUnifiedRequestConfig
--- @return table: { body = table, headers = table, url = string }
function CustomOpenAIHandler:buildRequestBody(message_history, config)
    local model = config.model or "default"

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

    request_body.temperature = api_params.temperature or 0.7
    request_body.max_tokens = api_params.max_tokens or 4096

    -- Handle max_tokens vs max_completion_tokens for newer OpenAI models
    -- This helps when users clone OpenAI's API with newer models
    local needs_new_param = model:match("^gpt%-5") or model:match("^o%d") or model:match("^gpt%-4%.1")
    if needs_new_param and request_body.max_tokens then
        request_body.max_completion_tokens = request_body.max_tokens
        request_body.max_tokens = nil
    end

    local headers = {
        ["Content-Type"] = "application/json",
    }

    -- Only add Authorization header if API key is provided
    -- (some local servers like LM Studio don't require auth)
    if config.api_key and config.api_key ~= "" then
        headers["Authorization"] = "Bearer " .. config.api_key
    end

    local url = config.base_url or ""

    return {
        body = request_body,
        headers = headers,
        url = url,
        model = model,
        provider = config.provider or "custom",
    }
end

function CustomOpenAIHandler:query(message_history, config)
    if not config or not config.base_url or config.base_url == "" then
        return "Error: Missing base URL for custom provider"
    end

    -- Use buildRequestBody to construct the request (single source of truth)
    local built = self:buildRequestBody(message_history, config)
    local request_body = built.body
    local base_url = built.url

    -- Check if streaming is enabled
    local use_streaming = config.features and config.features.enable_streaming

    -- Debug: Print request body
    if config and config.features and config.features.debug then
        print("Custom OpenAI Request Body:", json.encode(request_body))
        print("Custom OpenAI URL:", base_url)
        print("Streaming enabled:", use_streaming and "yes" or "no")
    end

    local requestBody = json.encode(request_body)
    local headers = {
        ["Content-Type"] = "application/json",
        ["Content-Length"] = tostring(#requestBody),
    }

    -- Only add Authorization header if API key is provided
    if config.api_key and config.api_key ~= "" then
        headers["Authorization"] = "Bearer " .. config.api_key
    end

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
        print("Custom OpenAI Raw Response:", table.concat(responseBody))
    end

    local success, response = self:handleApiResponse(success, code, responseBody, "Custom Provider")
    if not success then
        return response
    end

    -- Debug: Print parsed response
    if config and config.features and config.features.debug then
        print("Custom OpenAI Parsed Response:", json.encode(response))
    end

    -- Parse using OpenAI format (most compatible)
    local success, result, reasoning = ResponseParser:parseResponse(response, "openai")
    if not success then
        return "Error: " .. result
    end

    -- Return result with optional reasoning metadata (for R1-style models)
    if reasoning then
        return {
            content = result,
            reasoning = reasoning,
            _has_reasoning = true,
        }
    end

    return result
end

return CustomOpenAIHandler
