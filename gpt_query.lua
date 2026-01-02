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

    -- Warn if extended thinking is enabled for non-Anthropic providers
    if config.features and config.features.enable_extended_thinking and provider ~= "anthropic" then
        logger.warn("KOAssistant: Extended thinking is only supported for Anthropic provider, ignoring setting")
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
    if type(result) == "function" then
        -- Handler returned a background request function for streaming
        -- Import StreamHandler and process the stream
        local StreamHandler = require("stream_handler")
        local stream_handler = StreamHandler:new()

        -- Get streaming settings
        local stream_settings = {
            stream_auto_scroll = config.features and config.features.stream_auto_scroll ~= false,
            large_stream_dialog = config.features and config.features.large_stream_dialog ~= false,
            response_font_size = config.features and config.features.markdown_font_size or 20,
        }

        -- Streaming is async - show dialog and call on_complete when done
        stream_handler:showStreamDialog(
            result,
            provider,
            config.model,
            stream_settings,
            function(stream_success, content, err)
                if stream_handler.user_interrupted then
                    if on_complete then on_complete(false, nil, "Request cancelled by user.") end
                    return
                end

                if not stream_success then
                    if on_complete then on_complete(false, nil, err or "Unknown streaming error") end
                    return
                end

                if on_complete then on_complete(true, content, nil) end
            end
        )

        -- Return marker indicating streaming is in progress
        return STREAMING_IN_PROGRESS
    end

    -- Non-streaming response (string) - call callback if provided
    if on_complete then
        on_complete(true, result, nil)
    end
    return result
end

return {
    query = queryChatGPT,
    isStreamingInProgress = isStreamingInProgress,
}
