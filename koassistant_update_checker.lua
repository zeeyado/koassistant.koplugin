local http = require("socket.http")
local ltn12 = require("ltn12")
local json = require("json")
local logger = require("logger")

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
end

function MarkdownViewer:onCloseWidget()
    UIManager:setDirty(nil, "partial")
end

local UpdateChecker = {}

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

function UpdateChecker.checkForUpdates(silent, include_prereleases)
    -- Default to including prereleases since we're in alpha/beta
    if include_prereleases == nil then
        include_prereleases = true
    end

    local response_body = {}
    -- Fetch all releases (not just latest) to include prereleases
    local request_result, code = http.request {
        url = "https://api.github.com/repos/zeeyado/koassistant.koplugin/releases",
        headers = {
            ["Accept"] = "application/vnd.github.v3+json",
            ["User-Agent"] = "KOReader-KOAssistant-Plugin"
        },
        sink = ltn12.sink.table(response_body)
    }

    if code == 200 then
        local data = table.concat(response_body)
        local success, releases = pcall(json.decode, data)

        if not success then
            logger.err("Failed to parse GitHub API response:", releases)
            if not silent then
                UIManager:show(InfoMessage:new{
                    text = "Failed to check for updates: Invalid response format",
                    timeout = 3
                })
            end
            return false
        end

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

        -- Find the latest release by comparing versions (don't rely on array order)
        local latest_release = nil
        local latest_version_str = nil
        for _, release in ipairs(releases) do
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
            if not silent then
                UIManager:show(InfoMessage:new{
                    text = "No releases found",
                    timeout = 3
                })
            end
            return false
        end

        -- Use the already-extracted version from the loop
        local latest_version = latest_version_str

        local current_version = meta.version

        -- Type validation before comparison
        if type(current_version) ~= "string" then
            logger.err("Update check: current_version is not a string, type=" .. type(current_version) .. ", value=" .. tostring(current_version))
            if not silent then
                UIManager:show(InfoMessage:new{
                    text = "Update check failed: invalid current version format",
                    timeout = 3
                })
            end
            return false
        end
        if type(latest_version) ~= "string" then
            logger.err("Update check: latest_version is not a string, type=" .. type(latest_version) .. ", value=" .. tostring(latest_version))
            if not silent then
                UIManager:show(InfoMessage:new{
                    text = "Update check failed: invalid latest version format",
                    timeout = 3
                })
            end
            return false
        end

        local comparison = compareVersions(current_version, latest_version)

        logger.info("Update check: current=" .. current_version .. ", latest=" .. latest_version .. ", comparison=" .. comparison)

        if comparison < 0 then
            -- New version available
            local release_notes = latest_release.body or "No release notes available."
            local download_url = latest_release.html_url
            local is_prerelease = latest_release.prerelease or false

            -- Format as markdown with version info header
            local markdown_content = string.format(
                "**New %sversion available!**\n\n**Current:** %s  \n**Latest:** %s\n\n---\n\n%s",
                is_prerelease and "pre-release " or "",
                current_version,
                latest_version,
                release_notes
            )

            local update_viewer
            update_viewer = MarkdownViewer:new{
                title = is_prerelease and "KOAssistant Pre-release Update" or "KOAssistant Update Available",
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
                                    Device:openLink(download_url)
                                else
                                    UIManager:show(InfoMessage:new{
                                        text = "Please visit:\n" .. download_url,
                                        timeout = 10
                                    })
                                end
                            end,
                        },
                    },
                },
            }
            UIManager:show(update_viewer)

            return true, latest_version
        elseif comparison == 0 then
            if not silent then
                UIManager:show(InfoMessage:new{
                    text = "You are running the latest version (" .. current_version .. ")",
                    timeout = 3
                })
            end
            return false
        else
            -- Current version is newer (development version)
            if not silent then
                UIManager:show(InfoMessage:new{
                    text = "You are running a development version (" .. current_version .. ")",
                    timeout = 3
                })
            end
            return false
        end
    else
        logger.err("Failed to check for updates. HTTP code:", code)
        if not silent then
            UIManager:show(InfoMessage:new{
                text = "Failed to check for updates. Please check your internet connection.",
                timeout = 3
            })
        end
        return false
    end
end

function UpdateChecker.getCurrentVersion()
    return meta.version
end

function UpdateChecker.checkForUpdatesInBackground()
    -- Check for updates silently in the background
    UpdateChecker.checkForUpdates(true)
end

return UpdateChecker