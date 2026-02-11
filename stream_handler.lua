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
local UIConstants = require("koassistant_ui.constants")
local Constants = require("koassistant_constants")

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
    local ui_update_task = nil  -- Forward declaration for display throttling
    local first_content_received = false

    -- Stream processing state
    local pid, parent_read_fd = nil, nil
    local partial_data = ""
    local result_buffer = {}
    local reasoning_buffer = {}  -- Capture reasoning content during stream
    local non200 = false
    local completed = false
    local in_reasoning_phase = false  -- Track if we're currently showing reasoning
    local in_web_search_phase = false  -- Track if web search tool is executing
    local web_search_used = false  -- Track if web search was ever used during this stream
    local was_truncated = false  -- Track if response was truncated (max tokens)

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
        -- Clear streaming flag immediately (all exit paths)
        _G.KOAssistantStreaming = nil

        -- Cancel pending UI update if any
        if ui_update_task then
            UIManager:unschedule(ui_update_task)
            ui_update_task = nil
        end
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

        -- Append truncation notice if response was cut short
        if was_truncated then
            local ResponseParser = require("koassistant_api.response_parser")
            result = result .. ResponseParser.TRUNCATION_NOTICE
        end

        -- Pass reasoning content as 4th arg (string if captured, nil otherwise)
        -- Pass web_search_used as 5th arg (true if search was used, nil otherwise)
        local reasoning_content = #reasoning_buffer > 0 and table.concat(reasoning_buffer) or nil
        local search_used = web_search_used and true or nil
        if on_complete then on_complete(true, result, nil, reasoning_content, search_used) end

        -- Show any pending update popup (deferred during streaming)
        local ok, UpdateChecker = pcall(require, "koassistant_update_checker")
        if ok and UpdateChecker and UpdateChecker.showPendingUpdate then
            UpdateChecker.showPendingUpdate()
        end
    end

    local function _closeStreamDialog()
        self.user_interrupted = true
        finishStream()
    end

    -- Dialog size configuration (uses UIConstants for consistency)
    local width, text_height, is_movable
    local large_dialog = settings and settings.large_stream_dialog ~= false
    if large_dialog then
        -- Large streaming dialog (95% of screen)
        -- Streaming dialog chrome: title bar (~50px), 1 button row (~50px), borders/padding (~20px)
        local chrome_height = Screen:scaleBySize(120)
        width = UIConstants.CHAT_WIDTH()
        text_height = UIConstants.CHAT_HEIGHT() - chrome_height
        is_movable = false
    else
        -- Compact streaming dialog (same size as compact chat view)
        local chrome_height = Screen:scaleBySize(120)
        width = UIConstants.CHAT_WIDTH()
        text_height = UIConstants.COMPACT_DIALOG_HEIGHT() - chrome_height
        is_movable = true
    end

    local font_size = (settings and settings.response_font_size) or 20
    local auto_scroll = settings and settings.stream_auto_scroll == true

    -- Auto-scroll state: starts based on setting, can be toggled by user
    local auto_scroll_active = auto_scroll
    local page_scroll = settings and settings.stream_page_scroll ~= false  -- default true
    local page_top_line = 1  -- Top line of current auto-scroll page (page-based mode only)

    -- Display throttling for performance (affects both auto-scroll and manual modes)
    local display_interval_sec = ((settings and settings.display_interval_ms) or 250) / 1000
    local pending_ui_update = false

    -- Apply page-based scroll: advance page if overflowed, pad text to fill page, scroll
    -- Must be called after iw:setText(display, true) so widget dimensions are available.
    -- Uses scrollToBottom() instead of directly setting virtual_line_num, so the
    -- ScrollTextWidget's scroll indicator and position tracking stay in sync.
    -- This works because padding aligns text to the page boundary, making "bottom"
    -- equal to the correct page position.
    local function applyPageScroll(iw, display)
        local stw = iw.text_widget  -- ScrollTextWidget
        local inner = stw and stw.text_widget  -- TextBoxWidget
        if not inner or not inner.lines_per_page or inner.lines_per_page <= 0 then return end
        local lpp = inner.lines_per_page
        local total_lines = #(inner.vertical_string_list or {})

        -- Check if content overflowed current page
        if total_lines > page_top_line + lpp - 1 then
            while total_lines > page_top_line + lpp - 1 do
                page_top_line = page_top_line + lpp
            end
        end

        -- Pad text with empty lines to fill the current page.
        -- This creates the blank space for text to stream into.
        local page_end = page_top_line + lpp - 1
        if total_lines < page_end then
            iw:setText(display .. string.rep("\n", page_end - total_lines), true)
        end

        -- Scroll to current page via scrollToBottom (padding makes bottom = page position).
        -- Goes through InputText → ScrollTextWidget → TextBoxWidget chain,
        -- keeping scroll indicator and position tracking in sync.
        iw:scrollToBottom()
    end

    -- Throttled UI update function - batches multiple chunks into single display refresh
    local function scheduleUIUpdate()
        if pending_ui_update or completed then return end
        pending_ui_update = true
        ui_update_task = UIManager:scheduleIn(display_interval_sec, function()
            pending_ui_update = false
            ui_update_task = nil
            if not completed and streamDialog and streamDialog._input_widget then
                local iw = streamDialog._input_widget
                if not auto_scroll_active then
                    -- Preserve user's manual scroll position
                    iw:resyncPos()
                end
                local display = in_reasoning_phase and table.concat(reasoning_buffer) or table.concat(result_buffer)
                iw:setText(display, true)

                if auto_scroll_active then
                    if page_scroll then
                        applyPageScroll(iw, display)
                    else
                        iw:scrollToBottom()
                    end
                end
            end
        end)
    end

    -- Functions to toggle auto-scroll (forward declarations)
    local turnOffAutoScroll, turnOnAutoScroll

    turnOffAutoScroll = function()
        if auto_scroll_active then
            auto_scroll_active = false
            -- Update button to show current state (OFF)
            local btn = streamDialog.button_table:getButtonById("scroll_control")
            if btn then
                btn:setText(_("Autoscroll OFF ↓"), btn.width)
                btn.callback = turnOnAutoScroll
                UIManager:setDirty(streamDialog, "ui")
            end
        end
    end

    turnOnAutoScroll = function()
        auto_scroll_active = true
        local iw = streamDialog._input_widget
        if iw then
            if page_scroll then
                -- Page-based: jump to the last page of content
                local display = in_reasoning_phase and table.concat(reasoning_buffer) or table.concat(result_buffer)
                iw:setText(display, true)
                local stw = iw.text_widget
                local inner = stw and stw.text_widget
                if inner and inner.lines_per_page and inner.lines_per_page > 0 then
                    local total_lines = #(inner.vertical_string_list or {})
                    if total_lines > inner.lines_per_page then
                        local pages = math.ceil(total_lines / inner.lines_per_page)
                        page_top_line = (pages - 1) * inner.lines_per_page + 1
                    else
                        page_top_line = 1
                    end
                else
                    page_top_line = 1
                end
                applyPageScroll(iw, display)
            else
                -- Bottom-scroll: just scroll to bottom
                iw:scrollToBottom()
            end
        end
        -- Update button to show current state (ON)
        local btn = streamDialog.button_table:getButtonById("scroll_control")
        if btn then
            btn:setText(_("Autoscroll ON ↓"), btn.width)
            btn.callback = turnOffAutoScroll
            UIManager:setDirty(streamDialog, "ui")
        end
    end

    -- Build buttons - always include Autoscroll toggle
    local dialog_buttons = {
        {
            {
                text = _("Stop"),
                id = "close",
                callback = _closeStreamDialog,
            },
            {
                -- Button shows current state, click toggles
                text = auto_scroll and _("Autoscroll ON ↓") or _("Autoscroll OFF ↓"),
                id = "scroll_control",
                callback = auto_scroll and turnOffAutoScroll or turnOnAutoScroll,
            },
        }
    }

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
            turnOffAutoScroll()
            return original_scrollUp(self_widget, ...)
        end

        local original_scrollDown = streamDialog._input_widget.scrollDown
        streamDialog._input_widget.scrollDown = function(self_widget, ...)
            turnOffAutoScroll()
            return original_scrollDown(self_widget, ...)
        end

        -- Hook scrollText for pan scrolling (touch drag)
        local original_scrollText = streamDialog._input_widget.scrollText
        if original_scrollText then
            streamDialog._input_widget.scrollText = function(self_widget, ...)
                turnOffAutoScroll()
                return original_scrollText(self_widget, ...)
            end
        end

        -- Hook page turn key events for hardware button scrolling
        -- Store original handlers
        local original_onKeyPgFwd = streamDialog.onKeyPgFwd
        local original_onKeyPgBack = streamDialog.onKeyPgBack

        streamDialog.onKeyPgFwd = function(self_dialog)
            turnOffAutoScroll()
            if original_onKeyPgFwd then
                return original_onKeyPgFwd(self_dialog)
            end
            -- Default: scroll down
            if self_dialog._input_widget and self_dialog._input_widget.scrollDown then
                self_dialog._input_widget:scrollDown()
            end
            return true
        end

        streamDialog.onKeyPgBack = function(self_dialog)
            turnOffAutoScroll()
            if original_onKeyPgBack then
                return original_onKeyPgBack(self_dialog)
            end
            -- Default: scroll up
            if self_dialog._input_widget and self_dialog._input_widget.scrollUp then
                self_dialog._input_widget:scrollUp()
            end
            return true
        end

        -- Register key events for page turn buttons if device has keys
        if Device:hasKeys() then
            streamDialog.key_events = streamDialog.key_events or {}
            streamDialog.key_events.KeyPgFwd = { { Device.input.group.PgFwd } }
            streamDialog.key_events.KeyPgBack = { { Device.input.group.PgBack } }
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

    -- Mark streaming as active (for update checker to defer popups)
    _G.KOAssistantStreaming = true

    -- Start the subprocess
    pid, parent_read_fd = ffiutil.runInSubProcess(backgroundQueryFunc, true)

    if not pid then
        logger.warn("Failed to start background query process.")
        _G.KOAssistantStreaming = nil  -- Clear flag on subprocess failure
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
                            -- Debug: Log SSE event structure (first few events only)
                            if settings and settings.debug and not first_content_received then
                                local preview = json_str:sub(1, 200)
                                if #json_str > 200 then preview = preview .. "..." end
                                print("SSE event:", preview)
                            end

                            -- Check for error response in SSE data (OpenRouter/OpenAI format)
                            if event.error then
                                local err_message = event.error.message or event.error.type or json.encode(event.error)
                                logger.warn("SSE error event received:", err_message)
                                completed = true
                                finishStream()
                                if on_complete then on_complete(false, nil, err_message) end
                                return
                            end

                            -- Check for truncation before extracting content
                            if self:checkIfTruncated(event) then
                                was_truncated = true
                            end

                            local content, reasoning = self:extractContentFromSSE(event)

                            -- Check for Gemini groundingMetadata (web search indicator)
                            -- Only set web_search_used if metadata contains actual search results
                            local gm = event.candidates and event.candidates[1] and event.candidates[1].groundingMetadata
                            if gm then
                                -- Check if search was actually performed (not just enabled)
                                if (gm.webSearchQueries and #gm.webSearchQueries > 0) or
                                   (gm.groundingChunks and #gm.groundingChunks > 0) or
                                   (gm.groundingSupports and #gm.groundingSupports > 0) then
                                    web_search_used = true
                                end
                            end

                            -- Handle reasoning content (displayed with header, saved separately)
                            if type(reasoning) == "string" and #reasoning > 0 then
                                table.insert(reasoning_buffer, reasoning)

                                -- Update UI with reasoning
                                if not first_content_received then
                                    first_content_received = true
                                    if animation_task then
                                        UIManager:unschedule(animation_task)
                                        animation_task = nil
                                    end
                                    in_reasoning_phase = true
                                    streamDialog._input_widget:setText("", true)
                                    if auto_scroll_active then page_top_line = 1 end
                                end

                                scheduleUIUpdate()
                            end

                            -- Handle regular content
                            if type(content) == "string" and #content > 0 then
                                -- Check for web search marker
                                if content == "__WEB_SEARCH_START__" then
                                    in_web_search_phase = true
                                    web_search_used = true  -- Mark that search was used
                                    if not first_content_received then
                                        first_content_received = true
                                        if animation_task then
                                            UIManager:unschedule(animation_task)
                                            animation_task = nil
                                        end
                                    end
                                    local search_text = Constants.getEmojiText("🔍", _("Searching the web..."), settings and settings.enable_emoji_icons)
                                    streamDialog._input_widget:setText(search_text, true)
                                    -- Don't add to result buffer - this is just UI feedback
                                else
                                    -- If transitioning from web search or reasoning to answer, clear display
                                    if in_web_search_phase then
                                        in_web_search_phase = false
                                        streamDialog._input_widget:setText("", true)
                                        if auto_scroll_active then page_top_line = 1 end
                                    end
                                    if in_reasoning_phase then
                                        in_reasoning_phase = false
                                        -- Clear the reasoning display and show answer
                                        streamDialog._input_widget:setText("", true)
                                        if auto_scroll_active then page_top_line = 1 end
                                    end

                                    table.insert(result_buffer, content)

                                    -- Update UI
                                    if not first_content_received then
                                        first_content_received = true
                                        if animation_task then
                                            UIManager:unschedule(animation_task)
                                            animation_task = nil
                                        end
                                        streamDialog._input_widget:setText("", true)
                                        if auto_scroll_active then page_top_line = 1 end
                                    end

                                    scheduleUIUpdate()
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
                            -- Check for truncation
                            if self:checkIfTruncated(event) then
                                was_truncated = true
                            end

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
                                local content, reasoning = self:extractContentFromSSE(event)

                                -- Check for Gemini groundingMetadata (web search indicator)
                                if event.candidates and event.candidates[1] and event.candidates[1].groundingMetadata then
                                    web_search_used = true
                                end

                                -- Handle reasoning content (same logic as SSE handling)
                                if type(reasoning) == "string" and #reasoning > 0 then
                                    table.insert(reasoning_buffer, reasoning)

                                    if not first_content_received then
                                        first_content_received = true
                                        if animation_task then
                                            UIManager:unschedule(animation_task)
                                            animation_task = nil
                                        end
                                        in_reasoning_phase = true
                                        streamDialog._input_widget:setText("", true)
                                        if auto_scroll_active then page_top_line = 1 end
                                    end

                                    scheduleUIUpdate()
                                end

                                -- Handle regular content
                                if type(content) == "string" and #content > 0 then
                                    if in_reasoning_phase then
                                        in_reasoning_phase = false
                                        streamDialog._input_widget:setText("", true)
                                        if auto_scroll_active then page_top_line = 1 end
                                    end

                                    table.insert(result_buffer, content)

                                    if not first_content_received then
                                        first_content_received = true
                                        if animation_task then
                                            UIManager:unschedule(animation_task)
                                            animation_task = nil
                                        end
                                        streamDialog._input_widget:setText("", true)
                                        if auto_scroll_active then page_top_line = 1 end
                                    end

                                    scheduleUIUpdate()
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

--- Check if an SSE event indicates the response was truncated (max tokens)
--- @param event table: Parsed JSON event
--- @return boolean truncated
function StreamHandler:checkIfTruncated(event)
    -- OpenAI/DeepSeek format: finish_reason = "length"
    local choice = event.choices and event.choices[1]
    if choice and choice.finish_reason == "length" then
        return true
    end

    -- Anthropic format: message_stop event with stop_reason = "max_tokens"
    if event.type == "message_stop" or event.type == "message_delta" then
        if event.delta and event.delta.stop_reason == "max_tokens" then
            return true
        end
    end

    -- Gemini format: finishReason = "MAX_TOKENS"
    local gemini_candidate = event.candidates and event.candidates[1]
    if gemini_candidate and gemini_candidate.finishReason == "MAX_TOKENS" then
        return true
    end

    return false
end

--- Extract content from SSE event based on provider format
--- @param event table: Parsed JSON event
--- @return string|nil content, string|nil reasoning_content
--- Returns: (content, nil) for regular content
---          (nil, reasoning) for reasoning-only chunks
---          (content, reasoning) if both present in same event
function StreamHandler:extractContentFromSSE(event)
    -- OpenAI/DeepSeek/xAI format: choices[0].delta.content
    local choice = event.choices and event.choices[1]
    if choice then
        -- Check for actual stop reasons (not just truthy - JSON null can be truthy in some parsers)
        local finish = choice.finish_reason
        if finish and type(finish) == "string" and finish ~= "" then
            return nil, nil
        end
        local delta = choice.delta
        if delta then
            -- Check for web search tool calls (OpenAI/xAI)
            -- xAI uses "live_search" type
            if delta.tool_calls then
                for _, tool_call in ipairs(delta.tool_calls) do
                    if tool_call.type == "web_search" or tool_call.type == "live_search" or
                       (tool_call["function"] and (tool_call["function"].name == "web_search" or tool_call["function"].name == "live_search")) then
                        return "__WEB_SEARCH_START__", nil
                    end
                end
            end

            -- Check for OpenRouter web search annotations (url_citation)
            -- OpenRouter uses Exa search via :online suffix, annotations appear in delta
            if delta.annotations then
                for _, annotation in ipairs(delta.annotations) do
                    if annotation.type == "url_citation" then
                        return "__WEB_SEARCH_START__", nil
                    end
                end
            end

            -- DeepSeek: reasoning_content comes alongside regular content
            local reasoning = delta.reasoning_content
            local content = delta.content
            if reasoning or content then
                return content, reasoning
            end
        end
    end

    -- Anthropic format: Check for thinking block start (no content yet, just marker)
    if event.type == "content_block_start" and event.content_block then
        if event.content_block.type == "thinking" then
            -- Initial thinking text might be in the block
            local text = event.content_block.thinking
            return nil, text  -- May be nil, that's okay
        end
        -- Web search tool use indicator
        -- Note: Anthropic uses "server_tool_use" for built-in tools like web_search,
        -- and "tool_use" for user-defined tools
        local block_type = event.content_block.type
        if block_type == "tool_use" or block_type == "server_tool_use" then
            if event.content_block.name == "web_search" then
                return "__WEB_SEARCH_START__", nil
            end
        end
    end

    -- Anthropic format: content_block_stop indicates tool finished executing
    if event.type == "content_block_stop" then
        -- This could be end of tool execution; caller tracks state
        -- Return nil, nil - the next content_block_start with type="text" will clear search phase
    end

    -- Anthropic format: delta.text or delta.thinking
    local anthropic_delta = event.delta
    if anthropic_delta then
        if anthropic_delta.thinking then
            -- This is thinking/reasoning content
            return nil, anthropic_delta.thinking
        end
        if anthropic_delta.text then
            return anthropic_delta.text, nil
        end
    end

    -- Anthropic message event: content[0].text or content[0].thinking
    local anthropic_content = event.content and event.content[1]
    if anthropic_content then
        if anthropic_content.type == "thinking" and anthropic_content.thinking then
            return nil, anthropic_content.thinking
        end
        if anthropic_content.text then
            return anthropic_content.text, nil
        end
    end

    -- Gemini format: candidates[0].content.parts[0].text
    -- Parts with thought=true are thinking/reasoning
    local gemini_candidate = event.candidates and event.candidates[1]
    if gemini_candidate then
        local parts = gemini_candidate.content and gemini_candidate.content.parts

        -- Check for Google Search grounding (web search indicator)
        -- Only show search indicator if metadata contains actual search results
        -- and no content in this chunk (to not lose text)
        local gm = gemini_candidate.groundingMetadata
        if gm then
            -- Check if search was actually performed
            local search_used = (gm.webSearchQueries and #gm.webSearchQueries > 0) or
                               (gm.groundingChunks and #gm.groundingChunks > 0) or
                               (gm.groundingSupports and #gm.groundingSupports > 0)
            if search_used then
                local has_content = false
                if parts then
                    for _, part in ipairs(parts) do
                        if part.text and part.text ~= "" then
                            has_content = true
                            break
                        end
                    end
                end
                if not has_content then
                    return "__WEB_SEARCH_START__", nil
                end
            end
        end

        if parts then
            local content_text = nil
            local reasoning_text = nil

            for _, part in ipairs(parts) do
                if part.text then
                    if part.thought then
                        -- Thinking/reasoning part
                        reasoning_text = (reasoning_text or "") .. part.text
                    else
                        -- Regular content part
                        content_text = (content_text or "") .. part.text
                    end
                end
            end

            if content_text or reasoning_text then
                return content_text, reasoning_text
            end
        end
    end

    -- Ollama format: message.content (NDJSON streaming)
    local ollama_message = event.message
    if ollama_message and ollama_message.content then
        return ollama_message.content, nil
    end

    return nil, nil
end

return StreamHandler
