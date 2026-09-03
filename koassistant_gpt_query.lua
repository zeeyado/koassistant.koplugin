local _ = require("koassistant_gettext")
local api_key = nil
local CONFIGURATION = nil
local Defaults = require("koassistant_api.defaults")
local ConfigHelper = require("koassistant_config_helper")
local Constants = require("koassistant_constants")
local logger = require("koassistant_logger")
local ffi = require("ffi")
local ffiutil = require("ffi/util")
local json = require("json")
local DebugUtils = require("koassistant_debug_utils")
local ModelConstraints = require("model_constraints")

-- Attempt to load the configuration module first
local success, result = pcall(function() return require("configuration") end)
if success then
    CONFIGURATION = result
else
    logger.dbg("KOAssistant: no configuration.lua, using settings")
    -- Try legacy api_key as fallback
    success, result = pcall(function() return require("api_key") end)
    if success then
        api_key = result.key
        -- Create configuration from legacy api_key using defaults
        local provider = "anthropic" -- Default provider
        CONFIGURATION = Defaults.ProviderDefaults[provider]
        CONFIGURATION.api_key = api_key
    else
        logger.dbg("KOAssistant: no configuration.lua or api_key.lua, using settings")
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
loadHandler("openai_codex")
loadHandler("deepseek")
loadHandler("ollama")
loadHandler("gemini")
-- New providers
loadHandler("groq")
loadHandler("mistral")
loadHandler("xai")
loadHandler("openrouter")
loadHandler("requesty")
loadHandler("qwen")
loadHandler("kimi")
loadHandler("together")
loadHandler("fireworks")
loadHandler("sambanova")
loadHandler("cohere")
loadHandler("doubao")
loadHandler("zai")
loadHandler("perplexity")
loadHandler("nvidia")
-- Community set (M1 — model_management_strategy.md "End-state REVISION 2")
loadHandler("cerebras")
loadHandler("minimax")
loadHandler("deepinfra")
loadHandler("novita")
loadHandler("hyperbolic")
loadHandler("nebius")
loadHandler("chutes")
loadHandler("featherless")
loadHandler("vercel")
-- Generic handler for custom OpenAI-compatible providers
loadHandler("custom_openai")

-- Key resolution + placeholder detection live in koassistant_api/base.lua
-- (shared with image generation). Local name kept for existing call sites.
local function getApiKey(provider, settings)
    return require("koassistant_api.base").getApiKey(provider, settings)
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
--- @param on_complete function: Callback with (success, content, error, reasoning, web_search_used, usage)
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
    local function finish(success_flag, content, err, reasoning, web_search_used, usage)
        if completed then return end
        completed = true
        cleanup()
        if loading_dialog then
            UIManager:close(loading_dialog)
            loading_dialog = nil
        end
        if on_complete then
            on_complete(success_flag, content, err, reasoning, web_search_used, usage)
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

        -- Check for reasoning/thinking enabled using computed api_params.
        -- Shape-aware: an explicit disable (thinking={type="disabled"}, budget 0,
        -- effort "none") is a TABLE and used to pass a bare truthiness check,
        -- claiming "Reasoning enabled" on reasoning-off actions like translate.
        if config and ModelConstraints.reasoningDisplayEnabled(config.api_params) then
            table.insert(status_lines, _("Reasoning enabled"))
        end

        -- Show action name if available
        if config and config.features and config.features.loading_action_name then
            table.insert(status_lines, config.features.loading_action_name)
        end

        local base_text = table.concat(status_lines, "\n") .. "\n\n"
        loading_text = base_text .. _("Loading...")
    end

    -- Create loading dialog with cancel button. The tool runner's gather phase suppresses
    -- it (its own status window is up) and registers a cancel handle instead — without the
    -- dialog, the dismiss_callback below would be the only path to terminateSubProcess.
    local suppress_loading = config and config.features
        and config.features._suppress_loading_dialog == true
    if not suppress_loading then
        -- Minimal-popup requests swap the centered modal for KOReader's own
        -- translator wait pattern: a small bottom-left corner notice
        -- (TrapWidget), so the passage being read stays visible while a quick
        -- translate/define runs. Any tap/key/swipe dismisses = cancel — the
        -- same contract as the InfoMessage (and TrapWidget only fires
        -- dismiss_callback on real dismiss events, never on the programmatic
        -- close in finish()). Gated on loading_message: the corner text is a
        -- single-line TextWidget, and the popup dispatch provides a one-line
        -- notice; an eligible request without one keeps the info-rich modal.
        local minimal_trap = config and config.features
            and config.features._minimal_popup_eligible == true
            and config.features.loading_message ~= nil
        if minimal_trap then
            local TrapWidget = require("ui/widget/trapwidget")
            loading_dialog = TrapWidget:new{
                text = loading_text,
                dismiss_callback = function()
                    user_cancelled = true
                    finish(false, nil, _("Request cancelled by user."))
                end,
            }
        else
            loading_dialog = InfoMessage:new{
                text = loading_text,
                dismissable = true,
            }
            loading_dialog.dismiss_callback = function()
                user_cancelled = true
                finish(false, nil, _("Request cancelled by user."))
            end
        end
        UIManager:show(loading_dialog)
        UIManager:forceRePaint()
    end
    -- Expose a cancel handle to the caller (a function survives ConfigHelper's table
    -- deep-copies by reference, unlike a table field).
    if type(config._register_cancel) == "function" then
        config._register_cancel(function()
            user_cancelled = true
            finish(false, nil, _("Request cancelled by user."))
        end)
    end

    -- Start subprocess
    pid, parent_read_fd = ffiutil.runInSubProcess(background_fn, true)

    if not pid then
        logger.warn("Failed to start non-streaming background request")
        finish(false, nil, _("Failed to start subprocess for request"))
        return
    end

    -- Set pipe to non-blocking mode so read() can distinguish
    -- "no data yet" (returns -1/EAGAIN) from "pipe closed" (returns 0/EOF).
    -- F_GETFL=3, F_SETFL=4 are universal POSIX constants — but O_NONBLOCK is NOT:
    -- KOReader's posix cdef hardcodes the Linux value (2048); on macOS the real value
    -- is 0x0004, so the wrong bit left the pipe BLOCKING and the first poll read()
    -- froze the whole UI for the duration of the request (mac-only; e-ink devices are
    -- Linux and were always correct). Same fix as image_generator's portable poll.
    local bit = require("bit")
    local O_NONBLOCK = ffi.os == "OSX" and 0x0004 or ffi.C.O_NONBLOCK
    local flags = ffi.C.fcntl(parent_read_fd, 3)  -- F_GETFL
    if flags >= 0 then
        ffi.C.fcntl(parent_read_fd, 4, ffi.cast("int", bit.bor(flags, O_NONBLOCK)))  -- F_SETFL
    end

    -- Process accumulated response data
    local function processResponse()
        local full_response = table.concat(response_data)

        -- Per-minute admission limits: the fetch child forwards the provider's
        -- rate-limit headers as a marker line (before or after the body);
        -- record it and strip it before anything decodes the buffer.
        do
            local RateLimits = require("koassistant_rate_limits")
            local rl_fields, cleaned = RateLimits.extractMarker(full_response)
            if rl_fields then
                RateLimits.record(provider, config and config.model, rl_fields, "header")
                full_response = cleaned
            end
        end

        -- Check for error marker (plain find — PROTOCOL_NON_200 contains '-'
        -- which is a Lua pattern quantifier, so pattern matching fails)
        local marker_pos = full_response:find(PROTOCOL_NON_200, 1, true)
        if marker_pos then
            -- Try to extract detailed error from JSON body (before the marker)
            local body = full_response:sub(1, marker_pos - 1):match("^%s*(.-)%s*$")
            -- Debug: the raw error body is the ground truth for quota forensics
            -- (bucket/quotaId shapes vary per failure class) and is otherwise
            -- never logged — only the extracted message reaches the user.
            if config and config.features and config.features.debug then
                logger.warn("KOAssistant: non-200 raw body:",
                    (body and body ~= "") and body:sub(1, 2000) or "(empty)")
            end
            if body and #body > 0 then
                local decode_ok, j = pcall(json.decode, body)
                if decode_ok and type(j) == "table" then
                    -- Type-checked: luajson decodes JSON null to a truthy sentinel, which
                    -- would survive the old `or` chain and blow up on concatenation below.
                    local err = (type(j.error) == "table" and type(j.error.message) == "string"
                            and j.error.message)
                        or (type(j.message) == "string" and j.message)
                        or nil
                    if err and err ~= "" then
                        -- 429 bodies name the exact bucket (per-day vs per-minute, requests
                        -- vs tokens) and the retry delay in error.details[]; error.message
                        -- alone says only "you exceeded your current quota".
                        local detail = ModelConstraints.formatQuotaDetails(j)
                        if detail then err = err .. "\n\n" .. detail end
                        finish(false, nil, ModelConstraints.decorateRequestError(
                            err, provider, config and config.model, config))
                        return
                    end
                end
            end
            -- Fallback to status line from marker
            local err_msg = full_response:sub(marker_pos + #PROTOCOL_NON_200)
            if err_msg then
                err_msg = err_msg:gsub("^%s*", ""):gsub("%s*$", "")  -- trim
            end
            finish(false, nil, ModelConstraints.decorateRequestError(
                err_msg ~= "" and err_msg or "Request failed",
                provider, config and config.model, config))
            return
        end

        -- Parse JSON response
        local ok, parsed = pcall(json.decode, full_response)
        if not ok then
            -- 200 chars stopped inside the HTTP headers, so a 200-with-unparseable-body
            -- (the 2026-08-18 X-Ray case) could not be diagnosed at all. This is a
            -- rare failure path; 2000 buys the start of the body without spamming.
            logger.warn("Failed to parse non-streaming response:", full_response:sub(1, 2000))
            finish(false, nil, "Failed to parse response from " .. provider)
            return
        end

        local usage = DebugUtils.extractUsage(parsed)

        -- Debug: Print token usage
        if config and config.features and config.features.debug and usage then
            print(string.format("[%s] Token usage: %s", provider, DebugUtils.formatUsage(usage)))
        end

        -- Use response parser to extract content
        if response_parser then
            local parse_success, content, reasoning, web_search_used = response_parser(parsed)
            if parse_success then
                finish(true, content, nil, reasoning, web_search_used, usage)
            else
                finish(false, nil, content)  -- content is error message when parse fails
            end
        else
            -- Fallback: just return the parsed response
            finish(true, parsed, nil, nil, nil, usage)
        end
    end

    -- Poll for completion using non-blocking read.
    -- read() on non-blocking fd returns: >0 data, 0 EOF, -1 EAGAIN (no data yet).
    -- This detects pipe close instantly without depending on waitpid,
    -- which can take minutes on some Android devices.
    local function pollForData()
        if completed or user_cancelled then
            return
        end

        -- Read all available data from the pipe
        while true do
            local bytes_read = tonumber(ffi.C.read(parent_read_fd, buffer_ptr, chunksize))
            if bytes_read and bytes_read > 0 then
                table.insert(response_data, ffi.string(buffer, bytes_read))
            elseif bytes_read == 0 then
                -- EOF: subprocess closed write end, process response immediately
                processResponse()
                return
            else
                -- EAGAIN/EWOULDBLOCK (-1): no data available right now
                break
            end
        end

        -- Fallback: check if subprocess exited (works on most devices)
        if ffiutil.isSubProcessDone(pid) then
            processResponse()
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

    -- Validate configuration (no network needed)
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
            for _idx, cp in ipairs(custom_providers) do
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

    -- Get API key for ordinary providers. OpenAI Subscription stores OAuth
    -- credentials separately and resolves/refreshes them only after WiFi is ready.
    if provider ~= "openai_codex" then
        config.api_key = getApiKey(provider, settings)
    end

    -- Check if API key is required
    local api_key_required = true
    if provider == "ollama" or provider == "openai_codex" then
        api_key_required = false
    elseif is_custom_provider and custom_provider_config then
        -- Custom providers can optionally not require an API key (for local servers)
        api_key_required = custom_provider_config.api_key_required ~= false
    end

    if provider == "openai_codex" then
        local OAuth = require("koassistant_openai_codex_oauth")
        if not settings or not OAuth.isConfigured(settings) then
            local err = "OpenAI Subscription is not connected. Connect it in Settings → API Keys."
            if on_complete then
                on_complete(false, nil, err)
                return STREAMING_IN_PROGRESS
            end
            return "Error: " .. err
        end
    elseif not config.api_key and api_key_required then
        local err = string.format("No API key found for provider %s. Set it in Settings → API Keys or apikeys.lua", provider)
        if on_complete then
            on_complete(false, nil, err)
            return STREAMING_IN_PROGRESS
        end
        return "Error: " .. err
    end

    -- Ensure WiFi is connected before making the network request.
    -- When already connected, runWhenConnected calls the callback synchronously (no behavior change).
    -- When WiFi is off, shows the WiFi turn-on dialog and runs the callback after connection.
    local NetworkMgr = require("ui/network/manager")
    local query_return = STREAMING_IN_PROGRESS
    local function doQueryWithAuth()

    -- max_tokens self-heal (item 27): when the provider rejects the request
    -- because our max_tokens exceeds the model's real output cap or context
    -- room, the 400 states its numbers — parse them, retry ONCE at exactly the
    -- stated value, and (for output caps) persist the ceiling into the derived
    -- caps cache so every later request on this model resolves right the first
    -- time. Curated data can't cover an open-ended model space ("Fetch models",
    -- custom providers); this converts each wrong guess into one extra second,
    -- permanently. Runs from both completion paths' failure branches, AFTER the
    -- user-cancel checks; the once-flag makes a wrong parse fail loudly on the
    -- second attempt instead of looping.
    local dispatchRequest
    local max_tokens_retry_done = false
    -- Per-minute admission limits (docs/tpm_admission_plan.md): byte size of
    -- everything we send as text, for the plan-fit budget and the honest
    -- refusal arithmetic. Also feeds the stream settings' truncation check.
    local RateLimits = require("koassistant_rate_limits")
    local prompt_chars = (function()
        local n = 0
        if config.system and type(config.system.text) == "string" then
            n = n + #config.system.text
        end
        for _idx = 1, #(message_history or {}) do
            local m = message_history[_idx]
            if m and type(m.content) == "string" then n = n + #m.content end
        end
        return n
    end)()
    -- The answer budget the last dispatch carried when the plan capped it (nil =
    -- the handler's own default went out) — the refusal arithmetic needs it.
    local sent_budget = nil
    local function tryMaxTokensSelfHeal(err)
        if max_tokens_retry_done then return false end
        local model = config.model
        if not model then
            local pd = Defaults.ProviderDefaults[provider]
            model = pd and pd.model or nil
        end
        local parsed = ModelConstraints.parseMaxTokensError(err)
        if not parsed then
            -- Admission refusal ("Limit N, Requested M"): the plan's per-minute
            -- allowance could not admit prompt + budget. Learn the allowance for
            -- the session, resend ONCE at a budget that fits; when the prompt
            -- alone does not fit there is nothing to resend — the decorated
            -- error says so.
            local refusal = RateLimits.parseRefusal(err)
            if not refusal then return false end
            RateLimits.record(provider, model, { limit_tokens = refusal.limit }, "refusal")
            local sent = sent_budget or ModelConstraints.effectiveMaxTokens(provider, model, config)
            local budget = RateLimits.retryBudget(refusal, sent, prompt_chars)
            if not budget then
                logger.warn("KOAssistant: per-minute allowance", refusal.limit, "cannot admit this prompt (~",
                    RateLimits.promptTokensFromRefusal(refusal, sent) or RateLimits.estimateTokens(prompt_chars),
                    "tokens) - no resend for", provider, model or "?")
                return false
            end
            max_tokens_retry_done = true
            logger.warn("KOAssistant: per-minute allowance", refusal.limit, "refused budget",
                sent or "?", "- resending at", budget, "for", provider, model or "?")
            local retry_config = {}
            for k, v in pairs(config) do retry_config[k] = v end
            retry_config.api_params = {}
            for k, v in pairs(config.api_params or {}) do retry_config.api_params[k] = v end
            retry_config.api_params.max_tokens = budget
            sent_budget = budget
            dispatchRequest(retry_config)
            return true
        end
        max_tokens_retry_done = true
        if parsed.kind == "output_cap" and model then
            ModelConstraints.learnMaxOutput(provider, model, parsed.cap)
        end
        local retry_at = parsed.cap or parsed.retry_at
        logger.warn("KOAssistant: max_tokens self-heal (" .. parsed.kind .. "), retrying at",
            retry_at, "for", provider, model or "?")
        -- Copy-on-write (Config Copy Pattern): the retry value must not linger
        -- on the caller's config — a context-room value is valid for THIS
        -- prompt only, and output caps are served by the derived cache anyway.
        local retry_config = {}
        for k, v in pairs(config) do retry_config[k] = v end
        retry_config.api_params = {}
        for k, v in pairs(config.api_params or {}) do retry_config.api_params[k] = v end
        retry_config.api_params.max_tokens = retry_at
        dispatchRequest(retry_config)
        return true
    end

    -- The parameter shadows the outer `config` on purpose: the body below is
    -- the original request flow, unchanged; the self-heal re-enters it with its
    -- corrected copy while the first pass uses the caller's config verbatim.
    dispatchRequest = function(config) --luacheck: ignore 431

    -- Plan-fit budget: when this session already knows the plan's per-minute
    -- allowance (headers of an earlier response, the "Test provider" probe, or
    -- a refusal), shrink the answer budget so prompt + budget is admitted.
    -- Only ever shrinks; unknown plan = request untouched (Config Copy Pattern).
    do
        local cap = RateLimits.budgetCap(provider, config.model, prompt_chars)
        local current = ModelConstraints.effectiveMaxTokens(provider, config.model, config)
        local capped, changed = RateLimits.applyCap(current, cap)
        if changed then
            local capped_config = {}
            for k, v in pairs(config) do capped_config[k] = v end
            capped_config.api_params = {}
            for k, v in pairs(config.api_params or {}) do capped_config.api_params[k] = v end
            capped_config.api_params.max_tokens = capped
            config = capped_config
            sent_budget = capped
            logger.dbg("KOAssistant: answer budget capped to", capped, "by the plan's per-minute allowance",
                RateLimits.known(provider, config.model).limit_tokens, "for", provider, config.model or "?")
        end
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
            function(bg_success, content, err, reasoning, web_search_used, usage)
                if not bg_success and tryMaxTokensSelfHeal(err) then return end
                if on_complete then
                    on_complete(bg_success, content, err, reasoning, web_search_used, usage)
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
            stream_auto_scroll = config.features and config.features.stream_auto_scroll ~= false,
            stream_page_scroll = config.features and config.features.stream_page_scroll ~= false,
            stream_keep_read_position = config.features and config.features.stream_keep_read_position ~= false,
            large_stream_dialog = config.features and config.features.large_stream_dialog ~= false,
            response_font_size = config.features and config.features.markdown_font_size or 20,
            poll_interval_ms = config.features and config.features.stream_poll_interval or 125,
            display_interval_ms = config.features and config.features.stream_display_interval or 250,
            enable_emoji_icons = config.features and config.features.enable_emoji_icons == true,
            debug = config.features and config.features.debug,
            hidden_streaming = config.features and config.features.hidden_streaming,
            -- Input-truncation detection: ollama reports how many prompt tokens
            -- it actually evaluated, so comparing that against what we sent
            -- PROVES a prompt was cut to fit the server's context window,
            -- instead of guessing from a token estimate.
            provider_name = provider,
            model = config.model,
            prompt_chars = prompt_chars,
            -- Round 27: the label/note round 26 added rode config.features but
            -- were never copied into stream_settings, so every hidden stream
            -- still announced itself as quiz generation on the device
            hidden_streaming_label = config.features and config.features.hidden_streaming_label,
            hidden_streaming_note = config.features and config.features.hidden_streaming_note,
            -- Quick-answer retry (input safety net S3): a ⚡ button in the stream window
            -- that aborts + resends with quick posture. Shown only for quick-ELIGIBLE runs
            -- (freeform sends + actions that opted into quick via accept_quick_answer; NOT
            -- artifact/JSON actions like X-Ray, whose output would break under the brevity
            -- posture) and not for hidden/spoiler streams (quiz); grayed when this run is
            -- already quick (nothing to speed up).
            quick_retry_available = (config.features and config.features._quick_eligible == true)
                and not (config.features and config.features.hidden_streaming) or false,
            quick_already_active = config.features and config.features._session_quick_answer == true,
        }

        -- Streaming is async - show dialog and call on_complete when done
        stream_handler:showStreamDialog(
            stream_fn,
            provider,
            config.model,
            stream_settings,
            function(stream_success, content, err, reasoning_content, stream_web_search_used, usage)
                -- Quick-answer retry (S3): the ⚡ button aborted this stream. Signal it UP to
                -- the caller (BookToolRunner.queryWith) via the sentinel err — that layer owns
                -- the send-site config used for chat attribution AND the viewer's reply config,
                -- so IT rebuilds the request with quick posture and re-runs. Rebuilding here
                -- would only change the wire, not the viewer state (and in gather mode the
                -- attribution config lives upstream of us entirely). Checked BEFORE
                -- user_interrupted (the ⚡ button set both flags).
                if stream_handler.quick_retry_requested then
                    if on_complete then on_complete(false, nil, Constants.QUICK_RETRY_SENTINEL) end
                    return
                end
                if stream_handler.user_interrupted then
                    if on_complete then on_complete(false, nil, "Request cancelled by user.") end
                    return
                end

                if not stream_success then
                    -- Self-heal before surfacing: finishStream has already
                    -- closed the stream dialog, so the retry opens a fresh one.
                    if tryMaxTokensSelfHeal(err) then return end
                    -- Debug: keep the undecorated extracted error in the log for
                    -- quota forensics (the streaming raw body never reaches here).
                    if config.features and config.features.debug then
                        logger.warn("KOAssistant: stream failed:",
                            err and tostring(err):sub(1, 2000) or "(no error text)")
                    end
                    local emsg = ModelConstraints.decorateRequestError(
                        err or "Unknown streaming error", provider, config.model, config)
                    if on_complete then on_complete(false, nil, emsg) end
                    return
                end

                -- Determine reasoning to pass:
                -- 1. If reasoning_content is a string → captured reasoning (Anthropic, DeepSeek, Gemini)
                -- 2. If stream_reasoning_requested → OpenAI format { _requested = true, effort = "..." }
                -- 3. Otherwise → nil
                local reasoning_info = reasoning_content or stream_reasoning_requested

                if on_complete then on_complete(true, content, nil, reasoning_info, stream_web_search_used, usage) end
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
    query_return = result

    end -- dispatchRequest

    return dispatchRequest(config)

    end -- doQueryWithAuth

    local function doQuery()
        if provider ~= "openai_codex" then
            return doQueryWithAuth()
        end
        require("koassistant_openai_codex_oauth").resolveAccessTokenAsync(settings, function(auth, oauth_err)
            if not auth then
                local err = oauth_err or "OpenAI Subscription authentication failed."
                if on_complete then on_complete(false, nil, err) end
                query_return = "Error: " .. err
                return
            end
            config.api_key = auth.access_token
            config.oauth = auth
            doQueryWithAuth()
        end)
        return STREAMING_IN_PROGRESS
    end

    -- Background requests never prompt (update-checker precedent): the auto-update
    -- fire pre-checked isWifiOn(), and a drop inside the schedule window should fail
    -- silently in the subprocess — runWhenConnected would raise the WiFi dialog.
    if config.features and config.features._background_request then
        doQuery()
    else
        NetworkMgr:runWhenConnected(doQuery)
    end

    return query_return
end

return {
    query = queryChatGPT,
    isStreamingInProgress = isStreamingInProgress,
}
