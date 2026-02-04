local BaseHandler = require("koassistant_api.base")
local http = require("socket.http")
local ltn12 = require("ltn12")
local json = require("json")
local Defaults = require("koassistant_api.defaults")
local ResponseParser = require("koassistant_api.response_parser")
local DebugUtils = require("koassistant_debug_utils")

local OllamaHandler = BaseHandler:new()

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
function OllamaHandler:buildRequestBody(message_history, config)
    local defaults = Defaults.ProviderDefaults.ollama
    local model = config.model or defaults.model

    local request_body = {
        model = model,
        messages = {},
        stream = false,  -- Default to non-streaming for inspection
    }

    if config.system and config.system.text and config.system.text ~= "" then
        table.insert(request_body.messages, {
            role = "system",
            content = config.system.text,
        })
    end

    for _, msg in ipairs(message_history) do
        if msg.role ~= "system" and hasContent(msg) then
            table.insert(request_body.messages, {
                role = msg.role == "assistant" and "assistant" or "user",
                content = msg.content,
            })
        end
    end

    -- Ollama uses options object for parameters
    local api_params = config.api_params or {}
    local default_params = defaults.additional_parameters or {}

    request_body.options = {
        temperature = api_params.temperature or default_params.temperature or 0.7,
    }

    local headers = {
        ["Content-Type"] = "application/json",
    }

    return {
        body = request_body,
        headers = headers,
        url = config.base_url or defaults.base_url,
        model = model,
        provider = "ollama",
    }
end

function OllamaHandler:query(message_history, config)
    local defaults = Defaults.ProviderDefaults.ollama
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

    -- Ollama uses options object for parameters
    request_body.options = {
        temperature = api_params.temperature or default_params.temperature or 0.7,
    }

    -- Check if streaming is enabled
    local use_streaming = config.features and config.features.enable_streaming

    -- Set stream parameter based on config
    request_body.stream = use_streaming and true or false

    -- Debug: Print request body
    if config and config.features and config.features.debug then
        DebugUtils.print("Ollama Request Body:", request_body, config)
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

    -- Non-streaming mode: use background request for non-blocking UI
    local debug_enabled = config and config.features and config.features.debug

    local response_parser = function(response)
        -- Debug: Print parsed response
        if debug_enabled then
            DebugUtils.print("Ollama Parsed Response:", response, config)
        end

        local parse_success, result, reasoning = ResponseParser:parseResponse(response, "ollama")
        if not parse_success then
            return false, "Error: " .. result
        end

        -- Return with reasoning metadata if available (R1 models use <think> tags)
        return true, result, reasoning
    end

    return {
        _background_fn = self:backgroundRequest(base_url, headers, requestBody),
        _non_streaming = true,
        _response_parser = response_parser,
    }
end

return OllamaHandler
