--- Stream handler module for handling streaming AI responses
--- Based on assistant.koplugin's streaming implementation
--- Uses polling approach to avoid coroutine yield issues on some platforms
local _ = require("gettext")
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

    local chunksize = 1024 * 16
    local buffer = ffi.new('char[?]', chunksize, {0})
    local buffer_ptr = ffi.cast('void*', buffer)
    local PROTOCOL_NON_200 = "X-NON-200-STATUS:"
    local check_interval_sec = 0.125

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

        if on_complete then on_complete(true, result, nil) end
    end

    local function _closeStreamDialog()
        self.user_interrupted = true
        finishStream()
    end

    -- Dialog size configuration
    local width, use_available_height, text_height, is_movable
    local large_dialog = settings and settings.large_stream_dialog ~= false
    if large_dialog then
        width = Screen:getWidth() - 2 * Size.margin.default
        text_height = nil
        use_available_height = true
        is_movable = false
    else
        width = Screen:getWidth() - Screen:scaleBySize(80)
        text_height = math.floor(Screen:getHeight() * 0.35)
        use_available_height = false
        is_movable = true
    end

    local font_size = (settings and settings.response_font_size) or 20

    streamDialog = InputDialog:new{
        title = _("AI is responding"),
        description = string.format("%s / %s", provider_name or "AI", model or ""),
        inputtext_class = StreamText,
        input_face = Font:getFace("infofont", font_size),

        -- size parameters
        width = width,
        use_available_height = use_available_height,
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
        buttons = {
            {
                {
                    text = _("Stop"),
                    id = "close",
                    callback = _closeStreamDialog,
                },
            }
        }
    }

    -- Add close button to title bar
    streamDialog.title_bar.close_callback = _closeStreamDialog
    streamDialog.title_bar:init()
    UIManager:show(streamDialog)

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

    local auto_scroll = settings and settings.stream_auto_scroll ~= false

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
                    partial_data = partial_data:sub(line_end + 1)

                    -- Parse SSE data line
                    if line:sub(1, 6) == "data: " then
                        local json_str = line:sub(7):match("^%s*(.-)%s*$") -- trim
                        if json_str == '[DONE]' then
                            completed = true
                            finishStream()
                            return
                        end

                        local ok, event = pcall(json.decode, json_str)
                        if ok and event then
                            local content = self:extractContentFromSSE(event)
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

                                if auto_scroll then
                                    streamDialog:addTextToInput(content)
                                else
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
                        -- Raw JSON (possibly error)
                        local ok, j = pcall(json.decode, line)
                        if ok and j then
                            local err_message = j.error and j.error.message
                            if err_message then
                                table.insert(result_buffer, err_message)
                            end
                            logger.info("JSON object received:", line)
                        else
                            table.insert(result_buffer, line)
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
--- @return string|nil content
function StreamHandler:extractContentFromSSE(event)
    -- OpenAI/DeepSeek format: choices[0].delta.content
    local choice = event.choices and event.choices[1]
    if choice then
        if choice.finish_reason then return nil end -- Don't add newline for finish
        local delta = choice.delta
        if delta then
            return delta.content or delta.reasoning_content
        end
    end

    -- Anthropic format: delta.text
    local anthropic_delta = event.delta
    if anthropic_delta and anthropic_delta.text then
        return anthropic_delta.text
    end

    -- Anthropic message event: content[0].text
    local anthropic_content = event.content and event.content[1]
    if anthropic_content and anthropic_content.text then
        return anthropic_content.text
    end

    -- Gemini format: candidates[0].content.parts[0].text
    local gemini_candidate = event.candidates and event.candidates[1]
    if gemini_candidate then
        local parts = gemini_candidate.content and gemini_candidate.content.parts
        if parts and parts[1] and parts[1].text then
            return parts[1].text
        end
    end

    return nil
end

return StreamHandler
