local json = require("json")
local logger = require("logger")
local Constants = require("koassistant_constants")
local ffi = require("ffi")
local ffiutil = require("ffi/util")

-- Load _meta.lua from the plugin's own directory to avoid conflicts with other plugins
-- (assistant.koplugin also has _meta.lua, and require() might load the wrong one)
local function script_path()
   local str = debug.getinfo(2, "S").source:sub(2)
   return str:match("(.*/)")
end

local meta
local plugin_dir = script_path()
if plugin_dir then
    local meta_path = plugin_dir .. "_meta.lua"
    local ok, result = pcall(dofile, meta_path)
    if ok then
        meta = result
        logger.dbg("UpdateChecker: loaded _meta from:", meta_path, "plugin:", meta.name, "version:", meta.version)
    else
        logger.warn("UpdateChecker: failed to load _meta from plugin dir:", result)
        -- Fallback to require (may load wrong plugin's _meta)
        meta = require("_meta")
        logger.warn("UpdateChecker: fell back to require('_meta'), got plugin:", meta.name)
    end
else
    logger.warn("UpdateChecker: could not determine plugin dir, using require('_meta')")
    meta = require("_meta")
    logger.warn("UpdateChecker: loaded via require, got plugin:", meta.name)
end

local InfoMessage = require("ui/widget/infomessage")
local UIManager = require("ui/uimanager")
local ConfirmBox = require("ui/widget/confirmbox")
local Device = require("device")
local Screen = Device.screen

-- For markdown rendering
local Blitbuffer = require("ffi/blitbuffer")
local ButtonTable = require("ui/widget/buttontable")
local CenterContainer = require("ui/widget/container/centercontainer")
local Font = require("ui/font")
local FrameContainer = require("ui/widget/container/framecontainer")
local Geom = require("ui/geometry")
local InputContainer = require("ui/widget/container/inputcontainer")
local MovableContainer = require("ui/widget/container/movablecontainer")
local ScrollHtmlWidget = require("ui/widget/scrollhtmlwidget")
local Size = require("ui/size")
local TitleBar = require("ui/widget/titlebar")
local VerticalGroup = require("ui/widget/verticalgroup")
local GestureRange = require("ui/gesturerange")
local MD = require("apps/filemanager/lib/md")

-- CSS for markdown rendering (matches chatgptviewer style)
local RELEASE_NOTES_CSS = [[
@page {
    margin: 0;
    font-family: 'Noto Sans';
}
body {
    margin: 0;
    padding: 0;
    line-height: 1.3;
}
h1, h2, h3, h4, h5, h6 {
    margin: 0.5em 0 0.3em 0;
    font-weight: bold;
}
h1 { font-size: 1.3em; }
h2 { font-size: 1.2em; }
h3 { font-size: 1.1em; }
p { margin: 0.4em 0; }
ul, ol { margin: 0.3em 0; padding-left: 1.5em; }
li { margin: 0.15em 0; }
code {
    font-family: monospace;
    background-color: #f0f0f0;
    padding: 0.1em 0.3em;
    border-radius: 3px;
    font-size: 0.9em;
}
pre {
    background-color: #f0f0f0;
    padding: 0.5em;
    border-radius: 3px;
    overflow-x: auto;
    margin: 0.5em 0;
}
pre code { background-color: transparent; padding: 0; }
strong, b { font-weight: bold; }
em, i { font-style: italic; }
hr { border: none; border-top: 1px solid #ccc; margin: 0.8em 0; }
blockquote {
    margin: 0.5em 0;
    padding-left: 1em;
    border-left: 3px solid #ccc;
}
]]

-- Simple Markdown Viewer widget for release notes
local MarkdownViewer = InputContainer:extend{
    title = "Release Notes",
    markdown_text = "",
    width = nil,
    height = nil,
    buttons_table = nil,
    text_padding = Size.padding.default,
    text_margin = 0,
}

function MarkdownViewer:init()
    self.width = self.width or math.floor(Screen:getWidth() * 0.85)
    self.height = self.height or math.floor(Screen:getHeight() * 0.85)

    -- Convert markdown to HTML
    local html_body, err = MD(self.markdown_text, {})
    if err then
        logger.warn("MarkdownViewer: could not generate HTML", err)
        html_body = "<pre>" .. (self.markdown_text or "No content.") .. "</pre>"
    end

    -- Create title bar
    local titlebar = TitleBar:new{
        title = self.title,
        width = self.width,
        with_bottom_line = true,
        close_callback = function()
            UIManager:close(self)
        end,
    }

    -- Create button table
    local button_table = ButtonTable:new{
        width = self.width - 2 * Size.padding.default,
        buttons = self.buttons_table or {{
            { text = "Close", callback = function() UIManager:close(self) end }
        }},
        zero_sep = true,
        show_parent = self,
    }

    -- Calculate content height (minimal margins for more content space)
    local content_height = self.height - titlebar:getHeight() - button_table:getSize().h - 2 * self.text_padding

    -- Create scrollable HTML widget with GitHub-like font size
    local scroll_widget = ScrollHtmlWidget:new{
        html_body = html_body,
        css = RELEASE_NOTES_CSS,
        default_font_size = Screen:scaleBySize(16),
        width = self.width - 2 * self.text_padding,
        height = content_height,
        dialog = self,
    }

    local text_container = FrameContainer:new{
        padding = self.text_padding,
        margin = 0,
        bordersize = 0,
        scroll_widget,
    }

    -- Assemble the widget
    local frame_content = VerticalGroup:new{
        align = "left",
        titlebar,
        text_container,
        CenterContainer:new{
            dimen = Geom:new{ w = self.width, h = button_table:getSize().h },
            button_table,
        },
    }

    self.movable = MovableContainer:new{
        FrameContainer:new{
            background = Blitbuffer.COLOR_WHITE,
            radius = Size.radius.window,
            padding = 0,
            margin = 0,
            frame_content,
        }
    }

    self[1] = CenterContainer:new{
        dimen = Screen:getSize(),
        self.movable,
    }

    -- Enable tap outside to close
    self.ges_events.TapClose = {
        GestureRange:new{
            ges = "tap",
            range = Geom:new{
                x = 0, y = 0,
                w = Screen:getWidth(),
                h = Screen:getHeight(),
            },
        },
    }
end

function MarkdownViewer:onTapClose(arg, ges)
    -- Only close if tap is outside the dialog
    if ges.pos:notIntersectWith(self.movable.dimen) then
        UIManager:close(self)
        return true
    end
    return false
end

function MarkdownViewer:onCloseWidget()
    UIManager:setDirty(nil, "partial")
end

local UpdateChecker = {}

-- Pending update info (deferred if streaming is active)
UpdateChecker.pending_update = nil

local function parseVersion(versionString)
    -- Parse semantic version like "0.1.0-beta" or "1.0.0"
    if type(versionString) ~= "string" then
        logger.err("parseVersion: expected string, got " .. type(versionString))
        return nil
    end
    local major, minor, patch, prerelease = versionString:match("^(%d+)%.(%d+)%.(%d+)%-?(.*)$")
    if not major then
        return nil
    end
    
    return {
        major = tonumber(major),
        minor = tonumber(minor),
        patch = tonumber(patch),
        prerelease = prerelease ~= "" and prerelease or nil,
        original = versionString
    }
end

local function compareVersions(v1, v2)
    -- Returns: -1 if v1 < v2, 0 if v1 == v2, 1 if v1 > v2
    local ver1 = parseVersion(v1)
    local ver2 = parseVersion(v2)
    
    if not ver1 or not ver2 then
        return 0
    end
    
    -- Compare major.minor.patch
    if ver1.major ~= ver2.major then
        return ver1.major < ver2.major and -1 or 1
    end
    if ver1.minor ~= ver2.minor then
        return ver1.minor < ver2.minor and -1 or 1
    end
    if ver1.patch ~= ver2.patch then
        return ver1.patch < ver2.patch and -1 or 1
    end
    
    -- Handle prerelease versions
    -- No prerelease > prerelease (1.0.0 > 1.0.0-beta)
    if not ver1.prerelease and ver2.prerelease then
        return 1
    elseif ver1.prerelease and not ver2.prerelease then
        return -1
    elseif ver1.prerelease and ver2.prerelease then
        -- Compare prerelease strings (beta < rc < release)
        local prereleaseOrder = {
            alpha = 1,
            beta = 2,
            rc = 3,
            release = 4
        }
        
        local pre1Type = ver1.prerelease:match("^(%a+)")
        local pre2Type = ver2.prerelease:match("^(%a+)")
        
        local order1 = prereleaseOrder[pre1Type] or 0
        local order2 = prereleaseOrder[pre2Type] or 0
        
        if order1 ~= order2 then
            return order1 < order2 and -1 or 1
        end
        
        -- If same type, compare full strings
        return ver1.prerelease < ver2.prerelease and -1 or (ver1.prerelease > ver2.prerelease and 1 or 0)
    end
    
    return 0
end

--- Show the update available popup
--- @param update_info table: Contains current_version, latest_version, release_notes, download_url, is_prerelease
local function showUpdatePopup(update_info)
    -- Format as markdown with version info header
    local markdown_content = string.format(
        "**New %sversion available!**\n\n**Current:** %s  \n**Latest:** %s\n\n---\n\n%s",
        update_info.is_prerelease and "pre-release " or "",
        update_info.current_version,
        update_info.latest_version,
        update_info.release_notes
    )

    local update_viewer
    update_viewer = MarkdownViewer:new{
        title = update_info.is_prerelease and "KOAssistant Pre-release Update" or "KOAssistant Update Available",
        markdown_text = markdown_content,
        width = math.floor(Screen:getWidth() * 0.85),
        height = math.floor(Screen:getHeight() * 0.85),
        buttons_table = {
            {
                {
                    text = "Later",
                    callback = function()
                        UIManager:close(update_viewer)
                    end,
                },
                {
                    text = "Visit Release Page",
                    callback = function()
                        UIManager:close(update_viewer)
                        if Device:canOpenLink() then
                            Device:openLink(update_info.download_url)
                        else
                            UIManager:show(InfoMessage:new{
                                text = "Please visit:\n" .. update_info.download_url,
                                timeout = 10
                            })
                        end
                    end,
                },
            },
        },
    }
    -- Dismiss any on-screen keyboard before showing the update dialog
    UIManager:broadcastEvent(require("ui/event"):new("CloseKeyboard"))
    UIManager:show(update_viewer)
    UIManager:setDirty(nil, "ui")
end

--- Show pending update popup if one was deferred during streaming
--- Called by stream_handler when streaming completes
function UpdateChecker.showPendingUpdate()
    if UpdateChecker.pending_update then
        local update_info = UpdateChecker.pending_update
        UpdateChecker.pending_update = nil
        -- Small delay to let streaming dialog close and viewer settle
        UIManager:scheduleIn(0.3, function()
            showUpdatePopup(update_info)
        end)
    end
end

-- Absolute timeouts for update checks (seconds)
-- These are wall-clock timeouts that kill the subprocess regardless of connection state
local AUTO_CHECK_TIMEOUT = 4    -- Timeout for automatic background checks (silent, non-intrusive)
local MANUAL_CHECK_TIMEOUT = 10 -- Longer timeout for user-initiated checks
local WARMUP_TIMEOUT = 0.5      -- Quick TCP warmup before fork (macOS fix)

--- Wrap a file descriptor for ltn12 sink
local function wrap_fd(fd)
    local file_object = {}
    function file_object:write(chunk)
        ffiutil.writeToFD(fd, chunk)
        return self
    end
    function file_object:close()
        return true
    end
    return file_object
end

--- Perform HTTP request in subprocess with absolute timeout
--- @param url string URL to fetch
--- @param timeout number Absolute timeout in seconds
--- @param callback function Called with (success, data_or_error)
local function fetchWithAbsoluteTimeout(url, timeout, callback)
    local ltn12 = require("ltn12")
    local socket = require("socket")

    -- Warmup: Make a quick TCP connection in parent before fork
    -- This fixes macOS-specific issues where subprocess connections hang intermittently
    -- (copied from base.lua backgroundRequest)
    if url:sub(1, 8) == "https://" then
        local host = url:match("https://([^/:]+)")
        if host then
            pcall(function()
                local sock = socket.tcp()
                sock:settimeout(WARMUP_TIMEOUT)
                sock:connect(host, 443)
                sock:close()
            end)
        end
    end

    local pid, parent_read_fd
    local completed = false
    local fd_closed = false
    local timeout_task = nil
    local poll_task = nil
    local accumulated_data = ""

    -- Close fd safely (only once)
    local function closeFd()
        if not fd_closed and parent_read_fd then
            fd_closed = true
            -- Drain any remaining data before closing
            pcall(function()
                local remaining = ffiutil.readAllFromFD(parent_read_fd)
                if remaining and #remaining > 0 then
                    accumulated_data = accumulated_data .. remaining
                end
            end)
            pcall(ffi.C.close, parent_read_fd)
            parent_read_fd = nil
        end
    end

    local function cleanup(skip_fd_close)
        completed = true
        if timeout_task then
            UIManager:unschedule(timeout_task)
            timeout_task = nil
        end
        if poll_task then
            UIManager:unschedule(poll_task)
            poll_task = nil
        end
        if pid then
            ffiutil.terminateSubProcess(pid)
            local captured_pid = pid
            pid = nil
            -- Schedule subprocess cleanup
            local collect_and_clean
            collect_and_clean = function()
                if ffiutil.isSubProcessDone(captured_pid) then
                    if not skip_fd_close then
                        closeFd()
                    end
                else
                    UIManager:scheduleIn(0.1, collect_and_clean)
                end
            end
            UIManager:scheduleIn(0.1, collect_and_clean)
        end
    end

    -- Create the subprocess function
    local function subprocess_func(subprocess_pid, child_write_fd)
        if not subprocess_pid or not child_write_fd then return end

        local ok, err = pcall(function()
            local subprocess_https = require("ssl.https")
            local subprocess_ltn12 = require("ltn12")

            -- Set a reasonable timeout for the HTTP request itself
            subprocess_https.TIMEOUT = 8

            local pipe_w = wrap_fd(child_write_fd)
            local request = {
                url = url,
                method = "GET",
                headers = {
                    ["Accept"] = "application/vnd.github.v3+json",
                    ["User-Agent"] = "KOReader-KOAssistant-Plugin"
                },
                sink = subprocess_ltn12.sink.file(pipe_w),
            }

            local req_ok, code = pcall(function()
                return select(2, subprocess_https.request(request))
            end)

            if not req_ok or (code and code ~= 200) then
                ffiutil.writeToFD(child_write_fd, "\n__UPDATE_CHECK_ERROR__:" .. tostring(code or "connection failed"))
            end
        end)

        if not ok then
            ffiutil.writeToFD(child_write_fd, "\n__UPDATE_CHECK_ERROR__:" .. tostring(err))
        end

        ffi.C.close(child_write_fd)
    end

    -- Set up absolute timeout watchdog - this kills the process no matter what
    timeout_task = UIManager:scheduleIn(timeout, function()
        if not completed then
            logger.info("Update check: absolute timeout reached, killing subprocess")
            cleanup()
            callback(false, "Timeout")
        end
    end)

    -- Start subprocess
    pid, parent_read_fd = ffiutil.runInSubProcess(subprocess_func, true)

    if not pid then
        cleanup()
        callback(false, "Failed to start subprocess")
        return
    end

    -- Poll for data using pattern from stream_handler.lua
    local chunksize = 8192
    local buffer = ffi.new("char[?]", chunksize)

    local function pollForData()
        if completed then return end

        local readsize = ffiutil.getNonBlockingReadSize(parent_read_fd)
        if readsize and readsize > 0 then
            local bytes_read = tonumber(ffi.C.read(parent_read_fd, buffer, chunksize))
            if bytes_read and bytes_read > 0 then
                accumulated_data = accumulated_data .. ffi.string(buffer, bytes_read)
            end
        end

        -- Check if subprocess is done
        if ffiutil.isSubProcessDone(pid) then
            -- Read any remaining data
            local final_read = tonumber(ffi.C.read(parent_read_fd, buffer, chunksize))
            if final_read and final_read > 0 then
                accumulated_data = accumulated_data .. ffi.string(buffer, final_read)
            end

            -- Close fd and cleanup
            closeFd()
            cleanup(true)  -- skip_fd_close since we already closed it

            -- Check for error marker
            local error_msg = accumulated_data:match("__UPDATE_CHECK_ERROR__:(.+)")
            if error_msg then
                callback(false, error_msg)
            else
                callback(true, accumulated_data)
            end
            return
        end

        -- Continue polling
        poll_task = UIManager:scheduleIn(0.1, pollForData)
    end

    poll_task = UIManager:scheduleIn(0.05, pollForData)
end

function UpdateChecker.checkForUpdates(auto, include_prereleases)
    -- Default to including prereleases since we're in alpha/beta
    if include_prereleases == nil then
        include_prereleases = true
    end

    local timeout = auto and AUTO_CHECK_TIMEOUT or MANUAL_CHECK_TIMEOUT

    -- Helper to extract version string from tag (handles v0.4.1, v.0.4.1, 0.4.1)
    local function extractVersion(tag)
        if not tag then return nil end
        if type(tag) ~= "string" then
            logger.warn("extractVersion: expected string tag, got " .. type(tag))
            return nil
        end
        -- Remove common prefixes: "v", "v.", "V", "V."
        local version = tag:gsub("^[vV]%.?", "")
        return version
    end

    -- Show loading message only for manual checks (auto checks are silent)
    local loading_msg = nil
    if not auto then
        loading_msg = InfoMessage:new{
            text = "Checking for updates...",
        }
        UIManager:show(loading_msg)
        -- Force screen refresh to show loading message immediately
        UIManager:forceRePaint()
    end

    -- Helper to close loading message (no-op if auto check)
    local function closeLoading()
        if loading_msg then
            UIManager:close(loading_msg)
        end
    end

    -- Use subprocess with absolute timeout
    fetchWithAbsoluteTimeout(Constants.GITHUB.API_URL, timeout, function(fetch_success, response_data)
        closeLoading()

        if not fetch_success then
            logger.err("Failed to check for updates:", response_data)
            if not auto then
                local error_text = response_data == "Timeout"
                    and "Failed to check for updates (timed out). Please try again."
                    or "Failed to check for updates. Please check your internet connection."
                UIManager:show(InfoMessage:new{
                    text = error_text,
                    timeout = 3
                })
            end
            return
        end

        local decode_success, releases = pcall(json.decode, response_data)

        if not decode_success then
            logger.err("Failed to parse GitHub API response:", releases)
            if not auto then
                UIManager:show(InfoMessage:new{
                    text = "Failed to check for updates: Invalid response format",
                    timeout = 3
                })
            end
            return
        end

        -- Validate releases is a table (array)
        if type(releases) ~= "table" then
            logger.err("Failed to parse GitHub API response: expected array, got " .. type(releases), "data:", response_data:sub(1, 200))
            if not auto then
                UIManager:show(InfoMessage:new{
                    text = "Failed to check for updates: Invalid response format",
                    timeout = 3
                })
            end
            return
        end

        -- Find the latest release by comparing versions (don't rely on array order)
        local latest_release = nil
        local latest_version_str = nil
        for _idx, release in ipairs(releases) do
            if not release.draft then
                if include_prereleases or not release.prerelease then
                    local version_str = extractVersion(release.tag_name)
                    if version_str and parseVersion(version_str) then
                        if not latest_release then
                            latest_release = release
                            latest_version_str = version_str
                        else
                            -- Compare and keep the higher version
                            if compareVersions(version_str, latest_version_str) > 0 then
                                latest_release = release
                                latest_version_str = version_str
                            end
                        end
                    end
                end
            end
        end

        if not latest_release then
            if not auto then
                UIManager:show(InfoMessage:new{
                    text = "No releases found",
                    timeout = 3
                })
            end
            return
        end

        -- Use the already-extracted version from the loop
        local latest_version = latest_version_str
        local current_version = meta.version

        -- Type validation before comparison
        if type(current_version) ~= "string" then
            logger.err("Update check: current_version is not a string, type=" .. type(current_version) .. ", value=" .. tostring(current_version))
            if not auto then
                UIManager:show(InfoMessage:new{
                    text = "Update check failed: invalid current version format",
                    timeout = 3
                })
            end
            return
        end
        if type(latest_version) ~= "string" then
            logger.err("Update check: latest_version is not a string, type=" .. type(latest_version) .. ", value=" .. tostring(latest_version))
            if not auto then
                UIManager:show(InfoMessage:new{
                    text = "Update check failed: invalid latest version format",
                    timeout = 3
                })
            end
            return
        end

        local comparison = compareVersions(current_version, latest_version)

        logger.info("Update check: current=" .. current_version .. ", latest=" .. latest_version .. ", comparison=" .. comparison)

        if comparison < 0 then
            -- New version available
            local update_info = {
                current_version = current_version,
                latest_version = latest_version,
                release_notes = latest_release.body or "No release notes available.",
                download_url = latest_release.html_url,
                is_prerelease = latest_release.prerelease or false,
            }

            -- Check if streaming is active - if so, defer the popup
            if _G.KOAssistantStreaming then
                logger.info("Update available but streaming active, deferring popup")
                UpdateChecker.pending_update = update_info
            else
                showUpdatePopup(update_info)
            end
        elseif comparison == 0 then
            if not auto then
                UIManager:show(InfoMessage:new{
                    text = "You are running the latest version (" .. current_version .. ")",
                    timeout = 3
                })
            end
        else
            -- Current version is newer (development version)
            if not auto then
                UIManager:show(InfoMessage:new{
                    text = "You are running a development version (" .. current_version .. ")",
                    timeout = 3
                })
            end
        end
    end)
end

function UpdateChecker.getCurrentVersion()
    return meta.version
end

function UpdateChecker.checkForUpdatesInBackground()
    -- Check for updates silently in the background
    UpdateChecker.checkForUpdates(true)
end

return UpdateChecker