--[[--
OpenAI-Compatible Handler Base Class

Shared implementation for providers that follow the OpenAI API format:
groq, mistral, xai, together, fireworks, sambanova, openrouter, qwen, kimi, doubao, custom_openai

Child classes override:
- getProviderName() [REQUIRED] - Display name for errors ("Mistral")
- getProviderKey() [REQUIRED] - Defaults lookup key ("mistral")
- customizeHeaders(headers, config) - Add provider-specific headers
- customizeRequestBody(body, config) - Modify request body
- customizeUrl(url, config) - Override URL (e.g., regional endpoints)
- validateConfig(config) - Custom validation (returns bool, error_string)
- enhanceErrorMessage(error, config) - Add hints to errors
- supportsReasoningExtraction() - Return true if <think> tags should be parsed
- getResponseParserKey() - Override parser key (default: getProviderKey())

@module openai_compatible
]]

local BaseHandler = require("koassistant_api.base")
local https = require("ssl.https")
local ltn12 = require("ltn12")
local json = require("json")
local Defaults = require("koassistant_api.defaults")
local ResponseParser = require("koassistant_api.response_parser")
local DebugUtils = require("koassistant_debug_utils")

local OpenAICompatibleHandler = BaseHandler:new()

--- Helper: Check if message has non-empty content
--- @param msg table Message object
--- @return boolean has_content
local function hasContent(msg)
    if not msg or not msg.content then return false end
    if type(msg.content) == "string" then
        return msg.content:match("%S") ~= nil
    end
    return true
end

---------------------------------------------------------------------------
-- Abstract methods (MUST override)
---------------------------------------------------------------------------

--- Get display name for error messages (e.g., "Mistral", "Groq")
--- @return string name
function OpenAICompatibleHandler:getProviderName()
    error("getProviderName() must be implemented by child class")
end

--- Get key for Defaults.ProviderDefaults lookup (e.g., "mistral", "groq")
--- @return string key
function OpenAICompatibleHandler:getProviderKey()
    error("getProviderKey() must be implemented by child class")
end

---------------------------------------------------------------------------
-- Optional hooks (override as needed)
---------------------------------------------------------------------------

--- Add or modify headers before request
--- @param headers table Headers table
--- @param config table Unified config
--- @return table headers Modified headers
function OpenAICompatibleHandler:customizeHeaders(headers, config)
    return headers
end

--- Modify request body before encoding
--- @param body table Request body
--- @param config table Unified config
--- @return table body Modified body
function OpenAICompatibleHandler:customizeRequestBody(body, config)
    return body
end

--- Override URL (e.g., for regional endpoints)
--- @param url string Default URL
--- @param config table Unified config
--- @return string url Final URL
function OpenAICompatibleHandler:customizeUrl(url, config)
    return url
end

--- Validate config before making request
--- @param config table Unified config
--- @return boolean valid, string|nil error_message
function OpenAICompatibleHandler:validateConfig(config)
    if not config or not config.api_key then
        return false, "Error: Missing API key in configuration"
    end
    return true
end

--- Add hints to error messages (e.g., region-specific hints)
--- @param error_msg string Original error message
--- @param config table Unified config
--- @return string error_msg Enhanced error message
function OpenAICompatibleHandler:enhanceErrorMessage(error_msg, config)
    return error_msg
end

--- Whether this provider extracts reasoning from <think> tags
--- @return boolean supports
function OpenAICompatibleHandler:supportsReasoningExtraction()
    return false
end

--- Get the key for ResponseParser (default: getProviderKey())
--- @return string key
function OpenAICompatibleHandler:getResponseParserKey()
    return self:getProviderKey()
end

---------------------------------------------------------------------------
-- Shared implementation
---------------------------------------------------------------------------

--- Build the request body, headers, and URL without making the API call.
--- Used by test inspector to see exactly what would be sent.
--- @param message_history table Array of message objects
--- @param config table Unified config from buildUnifiedRequestConfig
--- @return table { body = table, headers = table, url = string, model = string, provider = string }
function OpenAICompatibleHandler:buildRequestBody(message_history, config)
    local defaults = Defaults.ProviderDefaults[self:getProviderKey()] or {}
    local model = config.model or defaults.model or "default"

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
    request_body.max_tokens = api_params.max_tokens or default_params.max_tokens or 4096

    -- Hook: Allow child classes to customize request body
    request_body = self:customizeRequestBody(request_body, config)

    -- Build headers
    local headers = {
        ["Content-Type"] = "application/json",
        ["Authorization"] = "Bearer " .. (config.api_key or ""),
    }

    -- Hook: Allow child classes to customize headers
    headers = self:customizeHeaders(headers, config)

    -- Determine URL
    local url = config.base_url or defaults.base_url or ""

    -- Hook: Allow child classes to customize URL
    url = self:customizeUrl(url, config)

    return {
        body = request_body,
        headers = headers,
        url = url,
        model = model,
        provider = self:getProviderKey(),
    }
end

--- Execute a query to the API
--- @param message_history table Array of message objects
--- @param config table Unified config from buildUnifiedRequestConfig
--- @return string|table|function Result, error, or streaming function
function OpenAICompatibleHandler:query(message_history, config)
    -- Validate config
    local valid, err = self:validateConfig(config)
    if not valid then
        return err
    end

    -- Build request using shared method (single source of truth)
    local built = self:buildRequestBody(message_history, config)
    local request_body = built.body
    local base_url = built.url

    -- Check if streaming is enabled
    local use_streaming = config.features and config.features.enable_streaming

    -- Debug: Print request body
    local provider_name = self:getProviderName()
    if config and config.features and config.features.debug then
        DebugUtils.print(provider_name .. " Request Body:", request_body, config)
        print("Streaming enabled:", use_streaming and "yes" or "no")
    end

    local requestBody = json.encode(request_body)
    local headers = built.headers
    headers["Content-Length"] = tostring(#requestBody)

    -- If streaming is enabled, return the background request function
    if use_streaming then
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
        DebugUtils.print(provider_name .. " Raw Response:", table.concat(responseBody), config)
    end

    local api_success, response = self:handleApiResponse(success, code, responseBody, provider_name)
    if not api_success then
        -- Hook: Allow child classes to enhance error messages
        return self:enhanceErrorMessage(response, config)
    end

    -- Debug: Print parsed response
    if config and config.features and config.features.debug then
        DebugUtils.print(provider_name .. " Parsed Response:", response, config)
    end

    local parser_key = self:getResponseParserKey()
    local parse_success, result, reasoning, web_search_used = ResponseParser:parseResponse(response, parser_key)
    if not parse_success then
        return "Error: " .. result
    end

    -- Return result with optional metadata (reasoning and/or web_search_used)
    local has_metadata = reasoning or web_search_used
    if has_metadata then
        return {
            content = result,
            reasoning = reasoning,
            _has_reasoning = reasoning and true or nil,
            web_search_used = web_search_used,
        }
    end

    return result
end

return OpenAICompatibleHandler
