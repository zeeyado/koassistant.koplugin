--- Stream handler module for handling streaming AI responses
--- Based on assistant.koplugin's streaming implementation
--- Uses polling approach to avoid coroutine yield issues on some platforms
local _ = require("koassistant_gettext")
local InputText = require("ui/widget/inputtext")
local InputDialog = require("ui/widget/inputdialog")
local UIManager = require("ui/uimanager")
local Font = require("ui/font")
local Size = require("ui/size")
local Device = require("device")
local Screen = Device.screen
local logger = require("logger")
local json = require("json")
local ffi = require("ffi")
local ffiutil = require("ffi/util")
local UIConstants = require("ui/constants")

local StreamHandler = {
    interrupt_stream = nil,      -- function to interrupt the stream query
    user_interrupted = false,    -- flag to indicate if the stream was interrupted
}

function StreamHandler:new(o)
    o = o or {}
    setmetatable(o, self)
    self.__index = self
    return o
end

--- Custom InputText class for showing streaming responses
--- Uses fast e-ink refresh mode and ignores all input events
local StreamText = InputText:extend{}

function StreamText:addChars(chars)
    self.readonly = false                           -- widget is inited with `readonly = true`
    InputText.addChars(self, chars)                 -- can only add text by our method
end

function StreamText:initTextBox(text, char_added)
    self.for_measurement_only = true                -- trick the method from super class
    InputText.initTextBox(self, text, char_added)   -- skips `UIManager:setDirty`
    -- use our own method of refresh, `fast` is suitable for stream responding
    UIManager:setDirty(self.parent, function() return "fast", self.dimen end)
    self.for_measurement_only = false
end

function StreamText:onCloseWidget()
    -- fast mode makes screen dirty, clean it with `flashui`
    UIManager:setDirty(self.parent, function() return "flashui", self.dimen end)
    return InputText.onCloseWidget(self)
end

-- Export StreamText class
StreamHandler.StreamText = StreamText

--- Create a bouncing dot animation for waiting state
function StreamHandler:createWaitingAnimation()
    local frames = { ".", "..", "...", "..", "." }
    local currentIndex = 1

    return {
        getNextFrame = function()
            local frame = frames[currentIndex]
            currentIndex = currentIndex + 1
            if currentIndex > #frames then
                currentIndex = 1
            end
            return frame
        end,
        reset = function()
            currentIndex = 1
        end
    }
end

--- Show streaming dialog and process the stream using polling
--- This function returns immediately; use the callback to get results
--- @param backgroundQueryFunc function: The background request function from handler
--- @param provider_name string: Name of the provider (for display)
--- @param model string: Model name (for display)
--- @param settings table: Plugin settings (optional)
--- @param on_complete function: Callback with (success, content, error) when stream completes
function StreamHandler:showStreamDialog(backgroundQueryFunc, provider_name, model, settings, on_complete)
    self.user_interrupted = false
    local streamDialog
    local animation_task = nil
    local poll_task = nil
    local first_content_received = false

    -- Stream processing state
    local pid, parent_read_fd = nil, nil
    local partial_data = ""
    local result_buffer = {}
    local non200 = false
    local completed = false
    local reasoning_detected = false  -- Track if thinking/reasoning was seen in stream

    local chunksize = 1024 * 16
    local buffer = ffi.new('char[?]', chunksize, {0})
    local buffer_ptr = ffi.cast('void*', buffer)
    local PROTOCOL_NON_200 = "X-NON-200-STATUS:"
    -- Poll interval from settings (default 125ms), converted to seconds
    local poll_interval_ms = settings and settings.poll_interval_ms or 125
    local check_interval_sec = poll_interval_ms / 1000

    local function cleanup()
        if animation_task then
            UIManager:unschedule(animation_task)
            animation_task = nil
        end
        if poll_task then
            UIManager:unschedule(poll_task)
            poll_task = nil
        end
        if pid then
            ffiutil.terminateSubProcess(pid)
            -- Schedule cleanup of subprocess
            local collect_and_clean
            collect_and_clean = function()
                if ffiutil.isSubProcessDone(pid) then
                    if parent_read_fd then
                        ffiutil.readAllFromFD(parent_read_fd)
                    end
                    logger.dbg("collected previously dismissed subprocess")
                else
                    if parent_read_fd and ffiutil.getNonBlockingReadSize(parent_read_fd) ~= 0 then
                        ffiutil.readAllFromFD(parent_read_fd)
                        parent_read_fd = nil
                    end
                    UIManager:scheduleIn(5, collect_and_clean)
                    logger.dbg("previously dismissed subprocess not yet collectable")
                end
            end
            UIManager:scheduleIn(5, collect_and_clean)
        end
    end

    local function finishStream()
        cleanup()
        UIManager:close(streamDialog)

        local result = table.concat(result_buffer):match("^%s*(.-)%s*$") or "" -- trim

        if self.user_interrupted then
            if on_complete then on_complete(false, nil, _("Request cancelled by user.")) end
            return
        end

        if non200 then
            -- Try to parse error from JSON
            if result:sub(1, 1) == '{' then
                local endPos = result:reverse():find("}")
                if endPos and endPos > 0 then
                    local ok, j = pcall(json.decode, result:sub(1, #result - endPos + 1))
                    if ok then
                        local err = (j.error and j.error.message) or j.message
                        if err then
                            if on_complete then on_complete(false, nil, err) end
                            return
                        end
                    end
                end
            end
            if on_complete then on_complete(false, nil, result) end
            return
        end

        -- Check for empty result - this can happen if the stream completed
        -- but no content was received (e.g., API returned empty response or error)
        if result == "" then
            -- Log partial_data which might contain error info
            if partial_data and #partial_data > 0 then
                logger.warn("Stream ended with no content but partial_data:", partial_data:sub(1, 500))
                -- Try to extract error from partial data
                if partial_data:sub(1, 1) == "{" then
                    local ok, j = pcall(json.decode, partial_data)
                    if ok and j and j.error then
                        local err_msg = j.error.message or j.error.code or json.encode(j.error)
                        if on_complete then on_complete(false, nil, err_msg) end
                        return
                    end
                end
                if on_complete then on_complete(false, nil, _("No response received. Raw: ") .. partial_data:sub(1, 200)) end
                return
            end
            if on_complete then on_complete(false, nil, _("No response received from AI")) end
            return
        end

        -- Pass reasoning_detected as 4th arg (true if thinking was seen, nil otherwise)
        if on_complete then on_complete(true, result, nil, reasoning_detected or nil) end
    end

    local function _closeStreamDialog()
        self.user_interrupted = true
        finishStream()
    end

    -- Dialog size configuration (uses UIConstants for consistency)
    local width, text_height, is_movable
    local large_dialog = settings and settings.large_stream_dialog ~= false
    if large_dialog then
        -- Large streaming dialog (same size as chat window - 95%)
        -- Calculate text_height to achieve ~95% total dialog height
        -- Streaming dialog chrome: title bar (~50px), 1 button row (~50px), borders/padding (~20px)
        -- Note: Chat viewer has 2 button rows, so streaming has less chrome
        local chrome_height = Screen:scaleBySize(120)
        width = UIConstants.CHAT_WIDTH()
        text_height = UIConstants.CHAT_HEIGHT() - chrome_height
        is_movable = false
    else
        -- Compact streaming dialog
        width = UIConstants.COMPACT_DIALOG_WIDTH()
        text_height = math.floor(Screen:getHeight() * UIConstants.INPUT_HEIGHT_RATIO)
        is_movable = true
    end

    local font_size = (settings and settings.response_font_size) or 20
    local auto_scroll = settings and settings.stream_auto_scroll ~= false
    local scroll_paused = false  -- Track if user has paused auto-scroll

    -- Functions to pause/resume auto-scroll (forward declarations)
    local pauseAutoScroll, resumeAutoScroll

    pauseAutoScroll = function()
        if not scroll_paused and auto_scroll then
            scroll_paused = true
            -- Update button to show "Resume"
            local btn = streamDialog.button_table:getButtonById("scroll_control")
            if btn then
                btn:setText(_("Resume ↓"), btn.width)
                btn.callback = resumeAutoScroll
                UIManager:setDirty(streamDialog, "ui")
            end
        end
    end

    resumeAutoScroll = function()
        scroll_paused = false
        -- Scroll to bottom
        streamDialog._input_widget:scrollToBottom()
        -- Update button back to "Pause"
        local btn = streamDialog.button_table:getButtonById("scroll_control")
        if btn then
            btn:setText(_("Pause ↓"), btn.width)
            btn.callback = pauseAutoScroll
            UIManager:setDirty(streamDialog, "ui")
        end
    end

    -- Build buttons - include Pause button only if auto_scroll is enabled
    local dialog_buttons = {
        {
            {
                text = _("Stop"),
                id = "close",
                callback = _closeStreamDialog,
            },
        }
    }
    if auto_scroll then
        table.insert(dialog_buttons[1], {
            text = _("Pause ↓"),
            id = "scroll_control",
            callback = pauseAutoScroll,
        })
    end

    streamDialog = InputDialog:new{
        title = _("AI is responding"),
        inputtext_class = StreamText,
        input_face = Font:getFace("infofont", font_size),

        -- size parameters
        width = width,
        text_height = text_height,
        is_movable = is_movable,

        -- behavior parameters
        readonly = true,
        fullscreen = false,
        allow_newline = true,
        add_nav_bar = false,
        cursor_at_end = true,
        add_scroll_buttons = true,
        condensed = true,
        auto_para_direction = true,
        scroll_by_pan = true,
        buttons = dialog_buttons,
    }

    -- Add close button to title bar
    streamDialog.title_bar.close_callback = _closeStreamDialog
    streamDialog.title_bar:init()
    UIManager:show(streamDialog)

    -- Hook into scroll callbacks to auto-pause when user scrolls
    if auto_scroll then
        local original_scrollUp = streamDialog._input_widget.scrollUp
        streamDialog._input_widget.scrollUp = function(self_widget, ...)
            pauseAutoScroll()
            return original_scrollUp(self_widget, ...)
        end

        local original_scrollDown = streamDialog._input_widget.scrollDown
        streamDialog._input_widget.scrollDown = function(self_widget, ...)
            pauseAutoScroll()
            return original_scrollDown(self_widget, ...)
        end
    end

    -- Set up waiting animation
    local animation = self:createWaitingAnimation()
    streamDialog._input_widget:setText(animation:getNextFrame(), true)
    local function updateAnimation()
        if not first_content_received and not completed then
            streamDialog._input_widget:setText(animation:getNextFrame(), true)
            animation_task = UIManager:scheduleIn(0.4, updateAnimation)
        end
    end
    animation_task = UIManager:scheduleIn(0.4, updateAnimation)

    -- Start the subprocess
    pid, parent_read_fd = ffiutil.runInSubProcess(backgroundQueryFunc, true)

    if not pid then
        logger.warn("Failed to start background query process.")
        cleanup()
        UIManager:close(streamDialog)
        if on_complete then on_complete(false, nil, _("Failed to start subprocess for request")) end
        return
    end

    -- Polling function to check for data
    local function pollForData()
        if completed or self.user_interrupted then
            return
        end

        local readsize = ffiutil.getNonBlockingReadSize(parent_read_fd)
        if readsize > 0 then
            local bytes_read = tonumber(ffi.C.read(parent_read_fd, buffer_ptr, chunksize))
            if bytes_read < 0 then
                local err = ffi.errno()
                logger.warn("readAllFromFD() error: " .. ffi.string(ffi.C.strerror(err)))
                completed = true
                finishStream()
                return
            elseif bytes_read == 0 then
                completed = true
                finishStream()
                return
            else
                local data_chunk = ffi.string(buffer, bytes_read)
                partial_data = partial_data .. data_chunk

                -- Process complete lines
                while true do
                    local line_end = partial_data:find("[\r\n]")
                    if not line_end then break end

                    local line = partial_data:sub(1, line_end - 1)
                    -- Handle both \r\n and \n line endings
                    local next_start = line_end + 1
                    if partial_data:sub(line_end, line_end) == "\r" and
                       partial_data:sub(line_end + 1, line_end + 1) == "\n" then
                        next_start = line_end + 2  -- Skip both \r and \n
                    end
                    partial_data = partial_data:sub(next_start)

                    -- Parse SSE data line (handle both "data: " and "data:" formats)
                    local data_prefix_len = nil
                    if line:sub(1, 6) == "data: " then
                        data_prefix_len = 6
                    elseif line:sub(1, 5) == "data:" then
                        data_prefix_len = 5
                    end

                    if data_prefix_len then
                        local json_str = line:sub(data_prefix_len + 1):match("^%s*(.-)%s*$") -- trim
                        if json_str == '[DONE]' then
                            completed = true
                            finishStream()
                            return
                        end

                        local ok, event = pcall(json.decode, json_str)
                        if ok and event then
                            local content, is_reasoning = self:extractContentFromSSE(event)
                            if is_reasoning then
                                reasoning_detected = true
                            end
                            if type(content) == "string" and #content > 0 then
                                table.insert(result_buffer, content)

                                -- Update UI
                                if not first_content_received then
                                    first_content_received = true
                                    if animation_task then
                                        UIManager:unschedule(animation_task)
                                        animation_task = nil
                                    end
                                    streamDialog._input_widget:setText("", true)
                                end

                                if auto_scroll and not scroll_paused then
                                    -- Normal auto-scroll: append and scroll to bottom
                                    streamDialog:addTextToInput(content)
                                else
                                    -- Either manual mode OR paused: preserve scroll position
                                    streamDialog._input_widget:resyncPos()
                                    streamDialog._input_widget:setText(table.concat(result_buffer), true)
                                end
                            end
                        else
                            logger.warn("Failed to parse JSON from SSE data:", json_str)
                        end
                    elseif line:sub(1, 7) == "event: " then
                        -- Ignore SSE event lines
                    elseif line:sub(1, 1) == ":" then
                        -- SSE comment/keep-alive
                    elseif line:sub(1, 1) == "{" then
                        -- Raw JSON line (NDJSON format - used by Ollama)
                        local ok, event = pcall(json.decode, line)
                        if ok and event then
                            -- Check for error response
                            if event.error then
                                local err_message = event.error.message or event.error
                                table.insert(result_buffer, tostring(err_message))
                            -- Check for Ollama done signal
                            elseif event.done == true then
                                completed = true
                                finishStream()
                                return
                            else
                                -- Try to extract streaming content
                                local content, is_reasoning = self:extractContentFromSSE(event)
                                if is_reasoning then
                                    reasoning_detected = true
                                end
                                if type(content) == "string" and #content > 0 then
                                    table.insert(result_buffer, content)

                                    -- Update UI (same logic as SSE handling)
                                    if not first_content_received then
                                        first_content_received = true
                                        if animation_task then
                                            UIManager:unschedule(animation_task)
                                            animation_task = nil
                                        end
                                        streamDialog._input_widget:setText("", true)
                                    end

                                    if auto_scroll and not scroll_paused then
                                        streamDialog:addTextToInput(content)
                                    else
                                        streamDialog._input_widget:resyncPos()
                                        streamDialog._input_widget:setText(table.concat(result_buffer), true)
                                    end
                                end
                            end
                        else
                            logger.warn("Failed to parse NDJSON line:", line)
                        end
                    elseif line:sub(1, #PROTOCOL_NON_200) == PROTOCOL_NON_200 then
                        non200 = true
                        table.insert(result_buffer, "\n\n" .. line:sub(#PROTOCOL_NON_200 + 1))
                        completed = true
                        finishStream()
                        return
                    else
                        if #line:match("^%s*(.-)%s*$") > 0 then
                            table.insert(result_buffer, line)
                            logger.warn("Unrecognized line format:", line)
                        end
                    end
                end
            end
        elseif readsize == 0 then
            -- No data available, check if subprocess is done
            if ffiutil.isSubProcessDone(pid) then
                completed = true
                finishStream()
                return
            end
        else
            -- Error reading
            local err = ffi.errno()
            logger.warn("Error reading from parent_read_fd:", err, ffi.string(ffi.C.strerror(err)))
            completed = true
            finishStream()
            return
        end

        -- Schedule next poll
        poll_task = UIManager:scheduleIn(check_interval_sec, pollForData)
    end

    -- Start polling
    poll_task = UIManager:scheduleIn(check_interval_sec, pollForData)
end

--- Extract content from SSE event based on provider format
--- @param event table: Parsed JSON event
--- @return string|nil content, boolean|nil is_reasoning (true if this is a reasoning/thinking chunk)
function StreamHandler:extractContentFromSSE(event)
    -- OpenAI/DeepSeek format: choices[0].delta.content
    local choice = event.choices and event.choices[1]
    if choice then
        -- Check for actual stop reasons (not just truthy - JSON null can be truthy in some parsers)
        local finish = choice.finish_reason
        if finish and type(finish) == "string" and finish ~= "" then
            return nil
        end
        local delta = choice.delta
        if delta then
            -- DeepSeek reasoning_content indicates reasoning was used
            if delta.reasoning_content then
                return delta.reasoning_content, true  -- is_reasoning = true
            end
            return delta.content
        end
    end

    -- Anthropic format: Check for thinking block start
    if event.type == "content_block_start" and event.content_block then
        if event.content_block.type == "thinking" then
            return nil, true  -- Signal reasoning detected but no content to show
        end
    end

    -- Anthropic format: delta.text (thinking content comes through delta.thinking)
    local anthropic_delta = event.delta
    if anthropic_delta then
        if anthropic_delta.thinking then
            return nil, true  -- Reasoning content, don't display but signal detected
        end
        if anthropic_delta.text then
            return anthropic_delta.text
        end
    end

    -- Anthropic message event: content[0].text
    local anthropic_content = event.content and event.content[1]
    if anthropic_content then
        if anthropic_content.type == "thinking" then
            return nil, true  -- Reasoning block
        end
        if anthropic_content.text then
            return anthropic_content.text
        end
    end

    -- Gemini format: candidates[0].content.parts[0].text
    -- Skip parts with thought=true (these are thinking/reasoning, not final answer)
    local gemini_candidate = event.candidates and event.candidates[1]
    if gemini_candidate then
        local parts = gemini_candidate.content and gemini_candidate.content.parts
        if parts then
            local has_thinking = false
            -- Check for thinking parts first
            for _, part in ipairs(parts) do
                if part.thought then
                    has_thinking = true
                end
            end
            -- Return first non-thinking part
            for _, part in ipairs(parts) do
                if part.text and not part.thought then
                    return part.text, has_thinking or nil
                end
            end
            -- If only thinking parts, signal reasoning detected
            if has_thinking then
                return nil, true
            end
        end
    end

    -- Ollama format: message.content (NDJSON streaming)
    local ollama_message = event.message
    if ollama_message and ollama_message.content then
        return ollama_message.content
    end

    return nil
end

return StreamHandler
