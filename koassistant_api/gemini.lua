local BaseHandler = require("koassistant_api.base")
local https = require("ssl.https")
local ltn12 = require("ltn12")
local json = require("json")
local Defaults = require("koassistant_api.defaults")
local ResponseParser = require("koassistant_api.response_parser")
local ModelConstraints = require("model_constraints")
local DebugUtils = require("koassistant_debug_utils")

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

--- Build the request body, headers, and URL without making the API call.
--- This is used by the test inspector to see exactly what would be sent.
--- @param message_history table: Array of message objects
--- @param config table: Unified config from buildUnifiedRequestConfig
--- @return table: { body = table, headers = table, url = string }
function GeminiHandler:buildRequestBody(message_history, config)
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

    -- Add thinking config for Gemini 3 preview models if enabled
    -- Gemini REST API uses camelCase: generationConfig.thinkingConfig.thinkingLevel
    -- Gemini 3 Pro: LOW, HIGH; Gemini 3 Flash: MINIMAL, LOW, MEDIUM, HIGH
    local adjustments = {}
    if api_params.thinking_level then
        if ModelConstraints.supportsCapability("gemini", model, "thinking") then
            request_body.generationConfig.thinkingConfig = {
                thinkingLevel = api_params.thinking_level:upper(),
                includeThoughts = true,  -- Required to get thinking in response
            }
        else
            adjustments.thinking_skipped = {
                reason = "model " .. model .. " does not support thinking"
            }
        end
    end

    local headers = {
        ["Content-Type"] = "application/json",
        ["x-goog-api-key"] = config.api_key or "",
    }

    local base_url = config.base_url or defaults.base_url
    local url = buildGeminiUrl(base_url, model, false)

    return {
        body = request_body,
        headers = headers,
        url = url,
        model = model,
        provider = "gemini",
        adjustments = adjustments,  -- Include for test inspector visibility
    }
end

function GeminiHandler:query(message_history, config)
    if not config or not config.api_key then
        return "Error: Missing API key in configuration"
    end

    -- Use buildRequestBody to construct the request (single source of truth)
    local built = self:buildRequestBody(message_history, config)
    local request_body = built.body
    local model = built.model
    local adjustments = built.adjustments

    -- Check if streaming is enabled
    local use_streaming = config.features and config.features.enable_streaming

    -- Debug: Print request body and adjustments
    if config and config.features and config.features.debug then
        if adjustments and next(adjustments) then
            ModelConstraints.logAdjustments("Gemini", adjustments)
        end
        DebugUtils.print("Gemini Request Body:", request_body, config)
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

    local defaults = Defaults.ProviderDefaults.gemini
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
        DebugUtils.print("Gemini Raw Response:", table.concat(responseBody), config)
    end

    local success, response = self:handleApiResponse(success, code, responseBody, "Gemini")
    if not success then
        return response
    end

    -- Debug: Print parsed response
    if config and config.features and config.features.debug then
        DebugUtils.print("Gemini Parsed Response:", response, config)
    end

    local success, result, reasoning = ResponseParser:parseResponse(response, "gemini")
    if not success then
        return "Error: " .. result
    end

    -- Return result with optional reasoning metadata (like Anthropic)
    if reasoning then
        return {
            content = result,
            reasoning = reasoning,
            _has_reasoning = true,
        }
    end

    return result
end

return GeminiHandler
