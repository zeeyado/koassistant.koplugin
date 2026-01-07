local api_key = nil
local CONFIGURATION = nil
local Defaults = require("api_handlers.defaults")
local ConfigHelper = require("config_helper")
local logger = require("logger")

-- Attempt to load the configuration module first
local success, result = pcall(function() return require("configuration") end)
if success then
    CONFIGURATION = result
else
    print("configuration.lua not found, attempting legacy api_key.lua...")
    -- Try legacy api_key as fallback
    success, result = pcall(function() return require("api_key") end)
    if success then
        api_key = result.key
        -- Create configuration from legacy api_key using defaults
        local provider = "anthropic" -- Default provider
        CONFIGURATION = Defaults.ProviderDefaults[provider]
        CONFIGURATION.api_key = api_key
    else
        print("No configuration found. Please set up configuration.lua")
    end
end

-- Define handlers table with proper error handling
local handlers = {}
local function loadHandler(name)
    local success, handler = pcall(function()
        return require("api_handlers." .. name)
    end)
    if success then
        handlers[name] = handler
    else
        print("Failed to load " .. name .. " handler: " .. tostring(handler))
    end
end

loadHandler("anthropic")
loadHandler("openai")
loadHandler("deepseek")
loadHandler("ollama")
loadHandler("gemini")
-- New providers
loadHandler("groq")
loadHandler("mistral")
loadHandler("xai")
loadHandler("openrouter")
loadHandler("qwen")
loadHandler("kimi")
loadHandler("together")
loadHandler("fireworks")
loadHandler("sambanova")
loadHandler("cohere")
loadHandler("doubao")

local function getApiKey(provider)
    local success, apikeys = pcall(function() return require("apikeys") end)
    if success and apikeys and apikeys[provider] then
        return apikeys[provider]
    end
    return nil
end

--- Marker returned when streaming is in progress
local STREAMING_IN_PROGRESS = { _streaming = true }

--- Check if a result indicates streaming is in progress
--- @param result any: The result from queryChatGPT
--- @return boolean
local function isStreamingInProgress(result)
    return type(result) == "table" and result._streaming == true
end

--- Query the AI with message history
--- @param message_history table: List of messages
--- @param temp_config table: Configuration settings
--- @param on_complete function: Optional callback for async streaming mode - receives (success, content, error)
--- @return string|table|nil response, string|nil error
--- When streaming is enabled and on_complete is provided, returns STREAMING_IN_PROGRESS marker
--- and calls on_complete(success, content, error) when stream finishes
local function queryChatGPT(message_history, temp_config, on_complete)
    -- Merge config with defaults
    local config = ConfigHelper:mergeWithDefaults(temp_config or CONFIGURATION)

    -- Validate configuration
    local valid, error = ConfigHelper:validate(config)
    if not valid then
        if on_complete then
            on_complete(false, nil, error)
            return STREAMING_IN_PROGRESS
        end
        return "Error: " .. error
    end

    local provider = config.provider
    local handler = handlers[provider]

    if not handler then
        local err = string.format("Provider '%s' not found", provider)
        if on_complete then
            on_complete(false, nil, err)
            return STREAMING_IN_PROGRESS
        end
        return "Error: " .. err
    end

    -- Get API key for the selected provider
    config.api_key = getApiKey(provider)
    if not config.api_key and provider ~= "ollama" then
        local err = string.format("No API key found for provider %s. Please check apikeys.lua", provider)
        if on_complete then
            on_complete(false, nil, err)
            return STREAMING_IN_PROGRESS
        end
        return "Error: " .. err
    end

    local success, result = pcall(function()
        return handler:query(message_history, config)
    end)

    if not success then
        if on_complete then
            on_complete(false, nil, tostring(result))
            return STREAMING_IN_PROGRESS
        end
        return "Error: " .. tostring(result)
    end

    -- Check if result is a function (streaming mode)
    -- Also check for table with _stream_fn (streaming with metadata, e.g., OpenAI reasoning requested)
    local stream_fn = nil
    local stream_reasoning_requested = nil

    if type(result) == "function" then
        stream_fn = result
    elseif type(result) == "table" and result._stream_fn then
        stream_fn = result._stream_fn
        if result._reasoning_requested then
            stream_reasoning_requested = { _requested = true, effort = result._reasoning_effort }
        end
    end

    if stream_fn then
        -- Handler returned a background request function for streaming
        -- Import StreamHandler and process the stream
        local StreamHandler = require("stream_handler")
        local stream_handler = StreamHandler:new()

        -- Get streaming settings
        local stream_settings = {
            stream_auto_scroll = config.features and config.features.stream_auto_scroll == true,
            large_stream_dialog = config.features and config.features.large_stream_dialog ~= false,
            response_font_size = config.features and config.features.markdown_font_size or 20,
            poll_interval_ms = config.features and config.features.stream_poll_interval or 125,
        }

        -- Streaming is async - show dialog and call on_complete when done
        stream_handler:showStreamDialog(
            stream_fn,
            provider,
            config.model,
            stream_settings,
            function(stream_success, content, err, reasoning_content)
                if stream_handler.user_interrupted then
                    if on_complete then on_complete(false, nil, "Request cancelled by user.") end
                    return
                end

                if not stream_success then
                    if on_complete then on_complete(false, nil, err or "Unknown streaming error") end
                    return
                end

                -- Determine reasoning to pass:
                -- 1. If reasoning_content is a string → captured reasoning (Anthropic, DeepSeek, Gemini)
                -- 2. If stream_reasoning_requested → OpenAI format { _requested = true, effort = "..." }
                -- 3. Otherwise → nil
                local reasoning_info = reasoning_content or stream_reasoning_requested

                if on_complete then on_complete(true, content, nil, reasoning_info) end
            end
        )

        -- Return marker indicating streaming is in progress
        return STREAMING_IN_PROGRESS
    end

    -- Non-streaming response - handle both string and structured result (with reasoning)
    local content = result
    local reasoning = nil

    -- Check if result is a structured response with reasoning metadata
    if type(result) == "table" then
        if result._has_reasoning then
            -- Confirmed reasoning (Anthropic, DeepSeek, Gemini): actual reasoning content returned
            content = result.content
            reasoning = result.reasoning
        elseif result._reasoning_requested then
            -- Requested reasoning (OpenAI): we sent the param but API doesn't expose content
            content = result.content
            -- Pass special marker to indicate reasoning was requested (not confirmed)
            reasoning = { _requested = true, effort = result._reasoning_effort }
        end
    end

    if on_complete then
        -- Pass reasoning as fourth argument when available
        on_complete(true, content, nil, reasoning)
    end
    return result
end

return {
    query = queryChatGPT,
    isStreamingInProgress = isStreamingInProgress,
}
