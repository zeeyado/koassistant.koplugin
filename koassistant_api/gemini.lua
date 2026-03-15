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

    -- Check if thinking will be enabled (affects default max_tokens)
    -- Gemini 3: thinkingLevel from settings
    local thinking_enabled = api_params.thinking_level and
                             ModelConstraints.supportsCapability("gemini", model, "thinking")

    -- Gemini 2.5: thinkingBudget from settings (-1=dynamic, 0=disabled, 128-24576=specific)
    -- Gemini 2.5 thinks by default even when reasoning toggle is off (budget nil → dynamic).
    -- Budget compensation must always apply unless thinking is explicitly disabled (budget = 0).
    local has_budget_support = ModelConstraints.supportsCapability("gemini", model, "thinking_budget")
    local thinking_budget = api_params.thinking_budget  -- may be nil, 0, -1, or 128-24576
    if has_budget_support and thinking_budget ~= 0 then
        thinking_enabled = true
    end

    -- Determine max_tokens - use 16384 as base default for all modes
    -- Gemini thinking tokens count toward maxOutputTokens, so thinking gets even more
    local max_tokens = api_params.max_tokens
    if not max_tokens then
        max_tokens = thinking_enabled and 32768 or 16384
    end

    -- Gemini 2.5: thinking tokens share the maxOutputTokens budget.
    -- Scale up large requests only when thinking is active.
    if has_budget_support and thinking_enabled and max_tokens > 16384 then
        max_tokens = math.min(max_tokens * 2, 65536)
    end

    request_body.generationConfig = {
        temperature = api_params.temperature or default_params.temperature or 0.7,
        maxOutputTokens = max_tokens,
    }

    -- Build thinkingConfig
    -- Gemini REST API uses camelCase: generationConfig.thinkingConfig
    -- Gemini 3 uses thinkingLevel (LOW/MEDIUM/HIGH/MINIMAL)
    -- Gemini 2.5 uses thinkingBudget (0=off, -1=dynamic, 128-24576=specific)
    local adjustments = {}

    if api_params.thinking_level and
       ModelConstraints.supportsCapability("gemini", model, "thinking") then
        -- Gemini 3: thinkingLevel
        request_body.generationConfig.thinkingConfig = {
            thinkingLevel = api_params.thinking_level:upper(),
            includeThoughts = true,
        }
    elseif has_budget_support then
        -- Gemini 2.5: thinkingBudget
        if thinking_budget == 0 then
            -- Explicitly disabled
            request_body.generationConfig.thinkingConfig = {
                thinkingBudget = 0,
            }
        elseif thinking_budget then
            -- Enabled: specific budget or dynamic (-1)
            request_body.generationConfig.thinkingConfig = {
                thinkingBudget = thinking_budget,
                includeThoughts = true,
            }
        else
            -- No thinking_budget in api_params (backward compat / direct API calls):
            -- default to dynamic thinking with thoughts exposed
            request_body.generationConfig.thinkingConfig = {
                thinkingBudget = -1,
                includeThoughts = true,
            }
        end
    elseif api_params.thinking_level then
        -- thinking_level set but model doesn't support it
        adjustments.thinking_skipped = {
            reason = "model " .. model .. " does not support thinking"
        }
    end

    -- Add Google Search grounding if enabled
    -- Logic: per-action override > global setting (same pattern as Anthropic)
    local enable_web_search = false
    if config.enable_web_search ~= nil then
        -- Per-action override (true = force on, false = force off)
        enable_web_search = config.enable_web_search
    elseif config.features and config.features.enable_web_search then
        -- Global setting
        enable_web_search = true
    end

    if enable_web_search then
        if ModelConstraints.supportsCapability("gemini", model, "google_search") then
            request_body.tools = {
                { googleSearch = {} }  -- Empty object enables Google Search
            }
        else
            adjustments.web_search_skipped = {
                reason = "model " .. model .. " does not support Google Search"
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

    -- Non-streaming mode: use background request for non-blocking UI
    local url = buildGeminiUrl(base_url, model, false)
    local debug_enabled = config and config.features and config.features.debug

    local response_parser = function(response)
        -- Debug: Print parsed response
        if debug_enabled then
            DebugUtils.print("Gemini Parsed Response:", response, config)
        end

        local parse_success, result, reasoning, web_search_used = ResponseParser:parseResponse(response, "gemini")
        if not parse_success then
            return false, "Error: " .. result
        end

        return true, result, reasoning, web_search_used
    end

    return {
        _background_fn = self:backgroundRequest(url, headers, requestBody),
        _non_streaming = true,
        _response_parser = response_parser,
    }
end

return GeminiHandler
