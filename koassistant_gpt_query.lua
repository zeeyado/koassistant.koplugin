local _ = require("koassistant_gettext")
local api_key = nil
local CONFIGURATION = nil
local Defaults = require("koassistant_api.defaults")
local ConfigHelper = require("koassistant_config_helper")
local logger = require("logger")
local ffi = require("ffi")
local ffiutil = require("ffi/util")
local json = require("json")

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
        return require("koassistant_api." .. name)
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
-- Generic handler for custom OpenAI-compatible providers
loadHandler("custom_openai")

local function getApiKey(provider, settings)
    -- 1. Check GUI-entered keys first (highest priority)
    if settings then
        local features = settings:readSetting("features") or {}
        local gui_keys = features.api_keys or {}
        if gui_keys[provider] and gui_keys[provider] ~= "" then
            return gui_keys[provider]
        end
    end

    -- 2. Fall back to apikeys.lua file
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

--- Handle non-streaming background request with cancellable loading dialog
--- Uses subprocess to avoid blocking the UI
--- @param background_fn function: The background request function from handler
--- @param provider string: Provider name for error messages
--- @param on_complete function: Callback with (success, content, error, reasoning, web_search_used)
--- @param response_parser function: Function to parse JSON response to content
--- @param config table: Configuration with model info and optional loading_message
local function handleNonStreamingBackground(background_fn, provider, on_complete, response_parser, config)
    local UIManager = require("ui/uimanager")
    local InfoMessage = require("ui/widget/infomessage")
    local BaseHandler = require("koassistant_api.base")
    local T = require("ffi/util").template

    local chunksize = 1024 * 64  -- Larger buffer for non-streaming (complete response)
    local buffer = ffi.new('char[?]', chunksize, {0})
    local buffer_ptr = ffi.cast('void*', buffer)
    local PROTOCOL_NON_200 = BaseHandler.PROTOCOL_NON_200 or "X-NON-200-STATUS:"

    local loading_dialog
    local poll_task = nil
    local pid, parent_read_fd = nil, nil
    local completed = false
    local user_cancelled = false
    local response_data = {}

    -- Cleanup function
    local function cleanup()
        if poll_task then
            UIManager:unschedule(poll_task)
            poll_task = nil
        end
        if pid then
            if user_cancelled then
                ffiutil.terminateSubProcess(pid)
            end
            -- Schedule cleanup of subprocess
            local collect_and_clean
            collect_and_clean = function()
                if ffiutil.isSubProcessDone(pid) then
                    if parent_read_fd then
                        ffiutil.readAllFromFD(parent_read_fd)
                    end
                    logger.dbg("collected non-streaming subprocess")
                else
                    if parent_read_fd and ffiutil.getNonBlockingReadSize(parent_read_fd) ~= 0 then
                        ffiutil.readAllFromFD(parent_read_fd)
                        parent_read_fd = nil
                    end
                    UIManager:scheduleIn(5, collect_and_clean)
                    logger.dbg("non-streaming subprocess not yet collectable")
                end
            end
            UIManager:scheduleIn(1, collect_and_clean)
        end
    end

    -- Handle completion
    local function finish(success_flag, content, err, reasoning, web_search_used)
        if completed then return end
        completed = true
        cleanup()
        if loading_dialog then
            UIManager:close(loading_dialog)
            loading_dialog = nil
        end
        if on_complete then
            on_complete(success_flag, content, err, reasoning, web_search_used)
        end
    end

    -- Build loading message - use custom message or match showLoadingDialog format
    local loading_text
    if config and config.features and config.features.loading_message then
        loading_text = config.features.loading_message
    else
        -- Match format from koassistant_dialogs.lua showLoadingDialog
        local status_lines = {}
        local provider_name = config and config.features and config.features.provider or provider or "AI"
        local model = ConfigHelper:getModelInfo(config) or config and config.model or "default"
        table.insert(status_lines, string.format("%s: %s", provider_name:gsub("^%l", string.upper), model))

        -- Check for reasoning/thinking enabled using computed api_params
        -- These are set by buildUnifiedRequestConfig based on action overrides and global settings
        if config and config.api_params then
            -- Anthropic: thinking, OpenAI: reasoning, Gemini: thinking_level
            if config.api_params.thinking or config.api_params.reasoning or config.api_params.thinking_level then
                table.insert(status_lines, _("Reasoning enabled"))
            end
        end

        -- Show action name if available
        if config and config.features and config.features.loading_action_name then
            table.insert(status_lines, config.features.loading_action_name)
        end

        local base_text = table.concat(status_lines, "\n") .. "\n\n"
        loading_text = base_text .. _("Loading...")
    end

    -- Create loading dialog with cancel button
    loading_dialog = InfoMessage:new{
        text = loading_text,
        dismissable = true,
    }
    loading_dialog.dismiss_callback = function()
        user_cancelled = true
        finish(false, nil, _("Request cancelled by user."))
    end
    UIManager:show(loading_dialog)
    UIManager:forceRePaint()

    -- Start subprocess
    pid, parent_read_fd = ffiutil.runInSubProcess(background_fn, true)

    if not pid then
        logger.warn("Failed to start non-streaming background request")
        finish(false, nil, _("Failed to start subprocess for request"))
        return
    end

    -- Poll for completion
    local function pollForData()
        if completed or user_cancelled then
            return
        end

        local readsize = ffiutil.getNonBlockingReadSize(parent_read_fd)
        if readsize > 0 then
            local bytes_read = tonumber(ffi.C.read(parent_read_fd, buffer_ptr, chunksize))
            if bytes_read and bytes_read > 0 then
                local chunk = ffi.string(buffer, bytes_read)
                table.insert(response_data, chunk)
            end
        end

        -- Check if subprocess is done
        if ffiutil.isSubProcessDone(pid) then
            -- Read any remaining data
            local remaining = ffiutil.getNonBlockingReadSize(parent_read_fd)
            while remaining and remaining > 0 do
                local bytes_read = tonumber(ffi.C.read(parent_read_fd, buffer_ptr, chunksize))
                if bytes_read and bytes_read > 0 then
                    table.insert(response_data, ffi.string(buffer, bytes_read))
                else
                    break
                end
                remaining = ffiutil.getNonBlockingReadSize(parent_read_fd)
            end

            -- Process complete response
            local full_response = table.concat(response_data)

            -- Check for error marker
            if full_response:find(PROTOCOL_NON_200) then
                local err_msg = full_response:match(PROTOCOL_NON_200 .. "(.+)")
                if err_msg then
                    err_msg = err_msg:gsub("^%s*", ""):gsub("%s*$", "")  -- trim
                end
                finish(false, nil, err_msg or "Request failed")
                return
            end

            -- Parse JSON response
            local ok, parsed = pcall(json.decode, full_response)
            if not ok then
                logger.warn("Failed to parse non-streaming response:", full_response:sub(1, 200))
                finish(false, nil, "Failed to parse response from " .. provider)
                return
            end

            -- Use response parser to extract content
            if response_parser then
                local parse_success, content, reasoning, web_search_used = response_parser(parsed)
                if parse_success then
                    finish(true, content, nil, reasoning, web_search_used)
                else
                    finish(false, nil, content)  -- content is error message when parse fails
                end
            else
                -- Fallback: just return the parsed response
                finish(true, parsed, nil)
            end
            return
        end

        -- Continue polling
        poll_task = UIManager:scheduleIn(0.1, pollForData)
    end

    -- Start polling
    poll_task = UIManager:scheduleIn(0.1, pollForData)
end

--- Query the AI with message history
--- @param message_history table: List of messages
--- @param temp_config table: Configuration settings
--- @param on_complete function: Optional callback for async streaming mode - receives (success, content, error)
--- @param settings LuaSettings: Optional settings object for GUI API keys
--- @return string|table|nil response, string|nil error
--- When streaming is enabled and on_complete is provided, returns STREAMING_IN_PROGRESS marker
--- and calls on_complete(success, content, error) when stream finishes
local function queryChatGPT(message_history, temp_config, on_complete, settings)
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
    local is_custom_provider = false
    local custom_provider_config = nil

    -- If no built-in handler, check if it's a custom provider
    if not handler then
        -- Check for custom providers in settings
        if settings then
            local features = settings:readSetting("features") or {}
            local custom_providers = features.custom_providers or {}
            for _, cp in ipairs(custom_providers) do
                if cp.id == provider then
                    handler = handlers["custom_openai"]
                    is_custom_provider = true
                    custom_provider_config = cp
                    -- Set base_url from custom provider config
                    config.base_url = cp.base_url
                    break
                end
            end
        end
    end

    if not handler then
        local err = string.format("Provider '%s' not found", provider)
        if on_complete then
            on_complete(false, nil, err)
            return STREAMING_IN_PROGRESS
        end
        return "Error: " .. err
    end

    -- Get API key for the selected provider (GUI settings take priority over apikeys.lua)
    config.api_key = getApiKey(provider, settings)

    -- Check if API key is required
    local api_key_required = true
    if provider == "ollama" then
        api_key_required = false
    elseif is_custom_provider and custom_provider_config then
        -- Custom providers can optionally not require an API key (for local servers)
        api_key_required = custom_provider_config.api_key_required ~= false
    end

    if not config.api_key and api_key_required then
        local err = string.format("No API key found for provider %s. Set it in Settings → API Keys or apikeys.lua", provider)
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
    -- Or table with _background_fn and _non_streaming (non-streaming background request)
    local stream_fn = nil
    local stream_reasoning_requested = nil
    local non_streaming_bg_fn = nil
    local response_parser = nil

    if type(result) == "function" then
        stream_fn = result
    elseif type(result) == "table" then
        if result._stream_fn then
            stream_fn = result._stream_fn
            if result._reasoning_requested then
                stream_reasoning_requested = { _requested = true, effort = result._reasoning_effort }
            end
        elseif result._background_fn and result._non_streaming then
            -- Non-streaming background request
            non_streaming_bg_fn = result._background_fn
            response_parser = result._response_parser
        end
    end

    -- Handle non-streaming background request (allows cancellation)
    if non_streaming_bg_fn then
        handleNonStreamingBackground(
            non_streaming_bg_fn,
            provider,
            function(bg_success, content, err, reasoning, web_search_used)
                if on_complete then
                    on_complete(bg_success, content, err, reasoning, web_search_used)
                end
            end,
            response_parser,
            config
        )
        return STREAMING_IN_PROGRESS
    end

    if stream_fn then
        -- Handler returned a background request function for streaming
        -- Import StreamHandler and process the stream
        local StreamHandler = require("stream_handler")
        local stream_handler = StreamHandler:new()

        -- Get streaming settings
        local stream_settings = {
            stream_auto_scroll = config.features and config.features.stream_auto_scroll == true,
            stream_page_scroll = config.features and config.features.stream_page_scroll ~= false,
            large_stream_dialog = config.features and config.features.large_stream_dialog ~= false,
            response_font_size = config.features and config.features.markdown_font_size or 20,
            poll_interval_ms = config.features and config.features.stream_poll_interval or 125,
            display_interval_ms = config.features and config.features.stream_display_interval or 250,
            enable_emoji_icons = config.features and config.features.enable_emoji_icons == true,
        }

        -- Streaming is async - show dialog and call on_complete when done
        stream_handler:showStreamDialog(
            stream_fn,
            provider,
            config.model,
            stream_settings,
            function(stream_success, content, err, reasoning_content, stream_web_search_used)
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

                if on_complete then on_complete(true, content, nil, reasoning_info, stream_web_search_used) end
            end
        )

        -- Return marker indicating streaming is in progress
        return STREAMING_IN_PROGRESS
    end

    -- Non-streaming response - handle both string and structured result (with reasoning/web_search)
    local content = result
    local reasoning = nil
    local web_search_used = nil

    -- Check if result is a structured response with metadata
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
        -- Check for web search used
        if result.web_search_used then
            web_search_used = true
            content = result.content or content
        end
    end

    if on_complete then
        -- Pass reasoning as 4th argument, web_search_used as 5th when available
        on_complete(true, content, nil, reasoning, web_search_used)
    end
    return result
end

return {
    query = queryChatGPT,
    isStreamingInProgress = isStreamingInProgress,
}
