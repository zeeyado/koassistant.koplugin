local json = require("json")
local logger = require("logger")
local Constants = require("koassistant_constants")
local ffi = require("ffi")
local ffiutil = require("ffi/util")
local lfs = require("libs/libkoreader-lfs")

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
local BD = require("ui/bidi")
local ButtonDialog = require("ui/widget/buttondialog")
local Notification = require("ui/widget/notification")
local NetworkMgr = require("ui/network/manager")
local LuaSettings = require("luasettings")
local DataStorage = require("datastorage")
local T = require("ffi/util").template
local _ = require("koassistant_gettext")

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
local ScrollTextWidget = require("ui/widget/scrolltextwidget")
local Size = require("ui/size")
local TitleBar = require("ui/widget/titlebar")
local VerticalGroup = require("ui/widget/verticalgroup")
local GestureRange = require("ui/gesturerange")
local MD = require("apps/filemanager/lib/md")
local Languages = require("koassistant_languages")

-- Session flag to prevent multiple auto-checks per session
-- (NetworkMgr:runWhenOnline can fire multiple times if network state changes)
local _session_auto_check_done = false

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
a {
    color: #0366d6;
    text-decoration: underline;
}
]]

-- Check if text has dominant RTL content (for auto-detection fallback)
local function hasDominantRTL(text)
    if not text or text == "" then return false end
    local rtl_count = 0
    for _ in text:gmatch("[\216-\219][\128-\191]") do
        rtl_count = rtl_count + 1
    end
    if rtl_count == 0 then return false end
    local latin_count = 0
    for _ in text:gmatch("[a-zA-Z]") do
        latin_count = latin_count + 1
    end
    return rtl_count > latin_count
end

-- Strip markdown syntax for plain text display (RTL mode)
-- Converts markdown to readable plain text with PTF bold markers for TextBoxWidget
local function stripMarkdown(text, is_rtl)
    if not text then return "" end

    -- PTF (Poor Text Formatting) markers - TextBoxWidget interprets these as bold
    local PTF_HEADER = "\u{FFF1}"
    local PTF_BOLD_START = "\u{FFF2}"
    local PTF_BOLD_END = "\u{FFF3}"

    -- Directional marker for BiDi text
    -- In RTL mode, skip LRM to let para_direction_rtl control paragraph direction
    local LRM = is_rtl and "" or "\u{200E}"  -- Left-to-Right Mark

    local result = text

    -- Code blocks: ```lang\ncode\n``` → indented with 4 spaces
    result = result:gsub("```[^\n]*\n(.-)```", function(code)
        local indented = code:gsub("([^\n]+)", "    %1")
        return "\n" .. indented
    end)

    -- Inline code: `code` → 'code'
    result = result:gsub("`([^`]+)`", "'%1'")

    -- Tables: Remove separator rows
    result = result:gsub("\n%s*|[%s%-:]+|[%s%-:|]*\n", "\n")

    -- Headers: Hierarchical symbols with bold text
    local header_symbols = { "▉", "◤", "◆", "✿", "❖", "·" }
    local lines = {}
    for line in result:gmatch("([^\n]*)\n?") do
        local hashes, content = line:match("^(#+)%s*(.-)%s*$")
        if hashes and content and #content > 0 then
            local level = math.min(#hashes, 6)
            local symbol = header_symbols[level]
            local bold_content = PTF_BOLD_START .. content .. PTF_BOLD_END
            if level >= 3 then
                table.insert(lines, " " .. symbol .. " " .. bold_content)
            else
                table.insert(lines, symbol .. " " .. bold_content)
            end
        else
            table.insert(lines, line)
        end
    end
    result = table.concat(lines, "\n")

    -- Emphasis: Convert to PTF bold markers
    -- Bold-italic: ***text*** or ___text___
    result = result:gsub("%*%*%*(.-)%*%*%*", PTF_BOLD_START .. "%1" .. PTF_BOLD_END .. LRM)
    result = result:gsub("___(.-)___", PTF_BOLD_START .. "%1" .. PTF_BOLD_END .. LRM)

    -- Bold: **text** or __text__
    result = result:gsub("%*%*(.-)%*%*", PTF_BOLD_START .. "%1" .. PTF_BOLD_END .. LRM)
    result = result:gsub("__(.-)__", PTF_BOLD_START .. "%1" .. PTF_BOLD_END .. LRM)

    -- Italic with underscores → bold (for part of speech)
    result = result:gsub("(%s)_([^_\n]+)_([%s%p])", "%1" .. PTF_BOLD_START .. "%2" .. PTF_BOLD_END .. "%3")
    result = result:gsub("(%s)_([^_\n]+)_$", "%1" .. PTF_BOLD_START .. "%2" .. PTF_BOLD_END)
    result = result:gsub("^_([^_\n]+)_([%s%p])", PTF_BOLD_START .. "%1" .. PTF_BOLD_END .. "%2")
    result = result:gsub("^_([^_\n]+)_$", PTF_BOLD_START .. "%1" .. PTF_BOLD_END)

    -- Blockquotes: > text → │ text
    result = result:gsub("\n>%s*", "\n│ ")
    result = result:gsub("^>%s*", "│ ")

    -- Unordered lists: - item or * item → • item
    result = result:gsub("\n[%-]%s+", "\n• ")
    result = result:gsub("^[%-]%s+", "• ")
    result = result:gsub("\n%*%s+", "\n• ")

    -- Horizontal rules: --- or *** or ___ → line
    local hr_line = "───────────────"
    result = result:gsub("\n%-%-%-+%s*\n", "\n" .. hr_line .. "\n")
    result = result:gsub("\n%*%*%*+%s*\n", "\n" .. hr_line .. "\n")
    result = result:gsub("\n___+%s*\n", "\n" .. hr_line .. "\n")

    -- Images: ![alt](url) → [Image: alt]
    result = result:gsub("!%[([^%]]*)%]%([^)]+%)", "[Image: %1]")

    -- Links: [text](url) → text
    result = result:gsub("%[([^%]]+)%]%([^)]+%)", "%1")

    -- Clean up multiple blank lines
    result = result:gsub("\n\n\n+", "\n\n")

    -- BiDi fix: Add LRM only to truly mixed RTL+Latin lines
    -- Skip in RTL mode: para_direction_rtl already sets the correct base direction
    if not is_rtl then
        local rtl_pattern = "[\216-\219][\128-\191]"
        local latin_pattern = "[a-zA-Z]"
        local header_pattern = "^%s*[▉◤◆✿❖·]"
        local fixed_lines = {}
        for line in result:gmatch("([^\n]*)\n?") do
            if line:match(rtl_pattern) and line:match(latin_pattern) and not line:match(header_pattern) then
                table.insert(fixed_lines, LRM .. line)
            else
                table.insert(fixed_lines, line)
            end
        end
        result = table.concat(fixed_lines, "\n")
    end

    return PTF_HEADER .. result
end

-- Auto-linkify plain URLs that aren't already part of markdown links
-- Converts https://example.com to [https://example.com](https://example.com)
local function autoLinkUrls(text)
    if not text then return text end

    -- Step 1: Protect existing markdown links by storing them
    local links = {}
    local link_count = 0
    local result = text:gsub("%[([^%]]+)%]%(([^%)]+)%)", function(link_text, url)
        link_count = link_count + 1
        local placeholder = "XURLLINKX" .. link_count .. "XURLLINKX"
        links[link_count] = "[" .. link_text .. "](" .. url .. ")"
        return placeholder
    end)

    -- Step 2: Convert http:// and https:// URLs to markdown links
    result = result:gsub("(https?://[%w%-%./_~:?#@!$&'*+,;=%%]+)", function(url)
        -- Clean trailing punctuation
        local clean_url = url:gsub("[.,;:!?)]+$", "")
        local trailing = url:sub(#clean_url + 1)
        return "[" .. clean_url .. "](" .. clean_url .. ")" .. trailing
    end)

    -- Step 3: Restore protected links
    for i = 1, link_count do
        local placeholder = "XURLLINKX" .. i .. "XURLLINKX"
        result = result:gsub(placeholder, function() return links[i] end)
    end

    return result
end

-- Show link options dialog (matches KOReader's ReaderLink external link dialog)
local link_dialog  -- Forward declaration for closures
local function showLinkDialog(link_url)
    if not link_url then return end

    local QRMessage = require("ui/widget/qrmessage")

    -- Build buttons in 2-column layout like ReaderLink
    local buttons = {}

    -- Row 1: Copy | Show QR code
    table.insert(buttons, {
        {
            text = _("Copy"),
            callback = function()
                Device.input.setClipboardText(link_url)
                UIManager:close(link_dialog)
                UIManager:show(Notification:new{
                    text = _("Link copied to clipboard"),
                })
            end,
        },
        {
            text = _("Show QR code"),
            callback = function()
                UIManager:close(link_dialog)
                UIManager:show(QRMessage:new{
                    text = link_url,
                    width = Screen:getWidth(),
                    height = Screen:getHeight(),
                })
            end,
        },
    })

    -- Row 2: Open in browser (if device supports it)
    if Device:canOpenLink() then
        table.insert(buttons, {
            {
                text = _("Open in browser"),
                callback = function()
                    UIManager:close(link_dialog)
                    Device:openLink(link_url)
                end,
            },
        })
    end

    -- Row 3: Cancel (full width)
    table.insert(buttons, {
        {
            text = _("Cancel"),
            callback = function()
                UIManager:close(link_dialog)
            end,
        },
    })

    -- Title format matches ReaderLink: "External link:\n\nURL"
    link_dialog = ButtonDialog:new{
        title = T(_("External link:\n\n%1"), BD.url(link_url)),
        buttons = buttons,
    }
    UIManager:show(link_dialog)
end

-- Handle link taps in HTML content
local function handleLinkTap(link)
    if link and link.uri then
        showLinkDialog(link.uri)
    end
end

-- Simple Markdown Viewer widget for release notes
local MarkdownViewer = InputContainer:extend{
    title = "Release Notes",
    markdown_text = "",
    width = nil,
    height = nil,
    buttons_table = nil,
    text_padding = Size.padding.default,
    text_margin = 0,
    is_rtl = false,  -- Use text mode with RTL direction when true
}

function MarkdownViewer:init()
    self.width = self.width or math.floor(Screen:getWidth() * 0.85)
    self.height = self.height or math.floor(Screen:getHeight() * 0.85)

    -- Auto-detect RTL if not already set by language check
    if not self.is_rtl and hasDominantRTL(self.markdown_text) then
        self.is_rtl = true
    end

    -- Auto-linkify plain URLs before markdown conversion
    local preprocessed_text = autoLinkUrls(self.markdown_text)

    -- Convert markdown to HTML
    local html_body, err = MD(preprocessed_text, {})
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

    -- Create scrollable widget - use text mode for RTL languages
    local scroll_widget
    if self.is_rtl then
        -- RTL mode: use plain text with RTL paragraph direction and markdown stripping
        scroll_widget = ScrollTextWidget:new{
            text = stripMarkdown(self.markdown_text, true),
            face = Font:getFace("cfont", 20),
            width = self.width - 2 * self.text_padding,
            height = content_height,
            dialog = self,
            para_direction_rtl = true,
            auto_para_direction = false,
        }
    else
        -- Normal mode: use HTML widget with GitHub-like font size
        scroll_widget = ScrollHtmlWidget:new{
            html_body = html_body,
            css = RELEASE_NOTES_CSS,
            default_font_size = Screen:scaleBySize(16),
            width = self.width - 2 * self.text_padding,
            height = content_height,
            dialog = self,
            html_link_tapped_callback = handleLinkTap,
        }
    end

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

--- Get non-English interaction languages for the translate picker
--- @return table: Array of language IDs (filtered, no English)
local function getNonEnglishInteractionLanguages()
    local settings_file = DataStorage:getSettingsDir() .. "/koassistant_settings.lua"
    local settings = LuaSettings:open(settings_file)
    local features = settings:readSetting("features") or {}

    -- Support both new array format and old comma-separated string
    local langs = features.interaction_languages or features.user_languages
    local all_languages = {}
    if type(langs) == "table" then
        for _, lang in ipairs(langs) do
            if lang and lang ~= "" then table.insert(all_languages, lang) end
        end
    elseif type(langs) == "string" and langs ~= "" then
        for lang in langs:gmatch("([^,]+)") do
            local trimmed = lang:match("^%s*(.-)%s*$")
            if trimmed ~= "" then table.insert(all_languages, trimmed) end
        end
    end

    local result = {}
    for _, lang in ipairs(all_languages) do
        if not lang:match("^English") then
            table.insert(result, lang)
        end
    end
    return result
end

-- Forward declarations for mutual recursion
local showUpdatePopup
local performUpdate

--- Translate content using the AI and show in a new viewer
--- @param markdown_content string: The markdown content to translate
--- @param target_language string: The target language for translation
--- @param title string: Title for the translated viewer
--- @param update_info table: Original update info for "Original" button
local function translateAndShowContent(markdown_content, target_language, title, update_info)
    -- Load settings and configuration
    local settings_file = DataStorage:getSettingsDir() .. "/koassistant_settings.lua"
    local settings = LuaSettings:open(settings_file)
    local saved_features = settings:readSetting("features") or {}

    -- Build configuration for translation - respect user's streaming setting
    local configuration = {
        provider = settings:readSetting("provider") or "anthropic",
        model = settings:readSetting("model"),
        features = {
            enable_streaming = saved_features.enable_streaming ~= false,  -- Respect user setting (default true)
            large_stream_dialog = true,  -- Use larger dialog for better readability
            markdown_font_size = saved_features.markdown_font_size or 20,
            stream_poll_interval = saved_features.stream_poll_interval or 125,
            stream_display_interval = saved_features.stream_display_interval or 250,
            -- Custom loading message for non-streaming mode
            loading_message = T(_("Translating to %1..."), target_language),
        },
    }

    -- Get API key
    local apikeys = {}
    pcall(function() apikeys = require("apikeys") end)
    configuration.api_key = apikeys[configuration.provider]

    -- Build translation prompt
    local prompt = T(_("Translate the following release notes to %1. Preserve markdown formatting:\n\n%2"), target_language, markdown_content)

    -- Create simple message for query
    local messages = {
        { role = "user", content = prompt }
    }

    -- Execute query - StreamHandler shows its own dialog when streaming
    -- Non-streaming mode uses handleNonStreamingBackground with loading_message
    local GptQuery = require("koassistant_gpt_query")
    GptQuery.query(messages, configuration, function(success, answer, err)
        if success and answer and answer ~= "" then
            -- Build buttons matching original update popup
            local translated_viewer
            local buttons = {}

            -- Row 1: Later | Visit Release Page
            table.insert(buttons, {
                {
                    text = _("Later"),
                    callback = function()
                        UIManager:close(translated_viewer)
                    end,
                },
                {
                    text = _("Visit Release Page"),
                    callback = function()
                        UIManager:close(translated_viewer)
                        if Device:canOpenLink() then
                            Device:openLink(update_info.download_url)
                        else
                            UIManager:show(InfoMessage:new{
                                text = _("Please visit:") .. "\n" .. update_info.download_url,
                                timeout = 10
                            })
                        end
                    end,
                },
            })

            -- Row 2: Update Now (only if zip available and not a git dev install)
            if update_info.zip_url and lfs.attributes(plugin_dir .. ".git", "mode") ~= "directory" then
                table.insert(buttons, {
                    {
                        text = _("Update Now"),
                        callback = function()
                            UIManager:close(translated_viewer)
                            performUpdate(update_info)
                        end,
                    },
                })
            end

            -- Row 3: Original (to go back to original release notes)
            table.insert(buttons, {
                {
                    text = _("Original"),
                    callback = function()
                        UIManager:close(translated_viewer)
                        showUpdatePopup(update_info)
                    end,
                },
            })

            -- Show translated content in MarkdownViewer
            -- Use text mode with RTL direction for RTL languages
            translated_viewer = MarkdownViewer:new{
                title = T(_("%1 (Translated)"), title),
                markdown_text = answer,
                width = math.floor(Screen:getWidth() * 0.85),
                height = math.floor(Screen:getHeight() * 0.85),
                buttons_table = buttons,
                is_rtl = Languages.isRTL(target_language),
            }
            UIManager:show(translated_viewer)
            -- Force full UI refresh to properly render the new viewer
            UIManager:setDirty(nil, "ui")
        else
            UIManager:show(InfoMessage:new{
                text = T(_("Translation failed: %1"), err or _("Unknown error")),
                timeout = 3,
            })
        end
    end, settings)
end

--- Show the update available popup
--- @param update_info table: Contains current_version, latest_version, release_notes, download_url, is_prerelease
showUpdatePopup = function(update_info)
    local update_viewer  -- Forward declaration for closures

    -- Format as markdown with version info header
    local markdown_content = string.format(
        "**New %sversion available!**\n\n**Current:** %s  \n**Latest:** %s\n\n---\n\n%s",
        update_info.is_prerelease and "pre-release " or "",
        update_info.current_version,
        update_info.latest_version,
        update_info.release_notes
    )

    -- Get non-English interaction languages for translate button
    local translate_languages = getNonEnglishInteractionLanguages()
    local show_translate = #translate_languages > 0

    -- Build buttons
    local buttons = {}

    -- Row 1: Later | Visit Release Page
    table.insert(buttons, {
        {
            text = _("Later"),
            callback = function()
                UIManager:close(update_viewer)
            end,
        },
        {
            text = _("Visit Release Page"),
            callback = function()
                UIManager:close(update_viewer)
                if Device:canOpenLink() then
                    Device:openLink(update_info.download_url)
                else
                    UIManager:show(InfoMessage:new{
                        text = _("Please visit:") .. "\n" .. update_info.download_url,
                        timeout = 10
                    })
                end
            end,
        },
    })

    -- Row 2: Update Now (only if zip available and not a git dev install)
    if update_info.zip_url and lfs.attributes(plugin_dir .. ".git", "mode") ~= "directory" then
        table.insert(buttons, {
            {
                text = _("Update Now"),
                callback = function()
                    UIManager:close(update_viewer)
                    performUpdate(update_info)
                end,
            },
        })
    end

    -- Row 3: Translate (only if non-English interaction languages exist)
    if show_translate then
        table.insert(buttons, {
            {
                text = _("Translate"),
                callback = function()
                    UIManager:close(update_viewer)
                    NetworkMgr:runWhenOnline(function()
                        local title = update_info.is_prerelease and "KOAssistant Pre-release Update" or "KOAssistant Update Available"
                        if #translate_languages == 1 then
                            -- Single language: translate directly
                            translateAndShowContent(markdown_content, translate_languages[1], title, update_info)
                        else
                            -- Multiple languages: show picker
                            local picker_dialog
                            local picker_buttons = {}
                            for _, lang_id in ipairs(translate_languages) do
                                table.insert(picker_buttons, {{
                                    text = Languages.getDisplay(lang_id),
                                    callback = function()
                                        UIManager:close(picker_dialog)
                                        translateAndShowContent(markdown_content, lang_id, title, update_info)
                                    end,
                                }})
                            end
                            table.insert(picker_buttons, {{
                                text = _("Cancel"),
                                id = "close",
                                callback = function()
                                    UIManager:close(picker_dialog)
                                end,
                            }})
                            picker_dialog = ButtonDialog:new{
                                title = _("Translate to"),
                                buttons = picker_buttons,
                            }
                            UIManager:show(picker_dialog)
                        end
                    end)
                end,
            },
        })
    end

    update_viewer = MarkdownViewer:new{
        title = update_info.is_prerelease and "KOAssistant Pre-release Update" or "KOAssistant Update Available",
        markdown_text = markdown_content,
        width = math.floor(Screen:getWidth() * 0.85),
        height = math.floor(Screen:getHeight() * 0.85),
        buttons_table = buttons,
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
local AUTO_CHECK_TIMEOUT = 8    -- Timeout for automatic background checks (silent, non-intrusive)
local MANUAL_CHECK_TIMEOUT = 15 -- Longer timeout for user-initiated checks
local WARMUP_TIMEOUT = 0.5      -- Quick TCP warmup before fork (macOS fix)
local DOWNLOAD_TIMEOUT = 120    -- 2 minutes for ~1.4MB zip on slow WiFi

-- User-owned files and directories that must survive auto-updates
-- Keep in sync with koassistant_backup_manager.lua's backup lists
local USER_FILES = { "apikeys.lua", "configuration.lua", "custom_actions.lua" }
local USER_DIRS = { "behaviors", "domains" }

-- Detect if running on macOS (for TCP warmup which is only needed on macOS)
local IS_MACOS = ffi.os == "OSX"

-- Platform-specific binary paths (same pattern as KOReader's FileManager)
local mv_bin = Device:isAndroid() and "/system/bin/mv" or "/bin/mv"
local cp_bin = Device:isAndroid() and "/system/bin/cp" or "/bin/cp"

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
    -- Skip on e-readers to avoid wasting time on slow network connections
    if IS_MACOS and url:sub(1, 8) == "https://" then
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

-- ============================================================================
-- Auto-Update Functions
-- ============================================================================

--- Download a file via HTTPS in subprocess, writing directly to disk
--- Uses the same subprocess pattern as fetchWithAbsoluteTimeout but writes
--- binary data to file instead of piping through FD (avoids binary data issues)
--- @param url string URL to download
--- @param dest_path string Path to write the downloaded file
--- @param callback function Called with (success, error_msg_or_nil)
local function downloadFile(url, dest_path, callback)
    local socket = require("socket")

    -- Warmup: Quick TCP connection in parent before fork (macOS fix)
    if IS_MACOS and url:sub(1, 8) == "https://" then
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
    local status_data = ""

    local function closeFd()
        if not fd_closed and parent_read_fd then
            fd_closed = true
            pcall(function()
                local remaining = ffiutil.readAllFromFD(parent_read_fd)
                if remaining and #remaining > 0 then
                    status_data = status_data .. remaining
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

    -- Set up absolute timeout watchdog
    timeout_task = UIManager:scheduleIn(DOWNLOAD_TIMEOUT, function()
        if not completed then
            logger.info("UpdateChecker: download timeout reached, killing subprocess")
            cleanup()
            os.remove(dest_path)
            callback(false, _("Download timed out"))
        end
    end)

    -- Start subprocess - writes zip directly to disk, pipe carries status only
    pid, parent_read_fd = ffiutil.runInSubProcess(function(subprocess_pid, child_write_fd)
        if not subprocess_pid or not child_write_fd then return end

        local ok, sub_err = pcall(function()
            local subprocess_https = require("ssl.https")
            local subprocess_ltn12 = require("ltn12")
            subprocess_https.TIMEOUT = DOWNLOAD_TIMEOUT - 5

            local output_file = io.open(dest_path, "wb")
            if not output_file then
                ffiutil.writeToFD(child_write_fd, "ERROR:Failed to create file")
                return
            end

            local req_ok, code = pcall(function()
                return select(2, subprocess_https.request{
                    url = url,
                    method = "GET",
                    headers = {
                        ["User-Agent"] = "KOReader-KOAssistant-Plugin",
                    },
                    sink = subprocess_ltn12.sink.file(output_file),
                })
            end)

            if not req_ok or (code and code ~= 200) then
                os.remove(dest_path)
                ffiutil.writeToFD(child_write_fd, "ERROR:" .. tostring(code or "connection failed"))
            else
                ffiutil.writeToFD(child_write_fd, "OK")
            end
        end)

        if not ok then
            os.remove(dest_path)
            ffiutil.writeToFD(child_write_fd, "ERROR:" .. tostring(sub_err))
        end

        ffi.C.close(child_write_fd)
    end, true)

    if not pid then
        cleanup()
        callback(false, _("Failed to start download"))
        return
    end

    -- Poll for subprocess completion (small buffer - pipe only carries status)
    local chunksize = 256
    local buffer = ffi.new("char[?]", chunksize)

    local function pollForData()
        if completed then return end

        local readsize = ffiutil.getNonBlockingReadSize(parent_read_fd)
        if readsize and readsize > 0 then
            local bytes_read = tonumber(ffi.C.read(parent_read_fd, buffer, chunksize))
            if bytes_read and bytes_read > 0 then
                status_data = status_data .. ffi.string(buffer, bytes_read)
            end
        end

        if ffiutil.isSubProcessDone(pid) then
            local final_read = tonumber(ffi.C.read(parent_read_fd, buffer, chunksize))
            if final_read and final_read > 0 then
                status_data = status_data .. ffi.string(buffer, final_read)
            end

            closeFd()
            cleanup(true)

            local error_msg = status_data:match("^ERROR:(.+)")
            if error_msg then
                os.remove(dest_path)
                callback(false, error_msg)
            else
                -- Verify file exists and is non-empty
                local attr = lfs.attributes(dest_path)
                if not attr or attr.size == 0 then
                    os.remove(dest_path)
                    callback(false, _("Downloaded file is empty"))
                else
                    callback(true)
                end
            end
            return
        end

        poll_task = UIManager:scheduleIn(0.1, pollForData)
    end

    poll_task = UIManager:scheduleIn(0.05, pollForData)
end

--- Verify that an extracted plugin directory is valid
--- @param staging_dir string Path to the extracted plugin directory
--- @param expected_version string Expected version string from the release
--- @return boolean success, string|nil error_msg
local function verifyExtractedPlugin(staging_dir, expected_version)
    -- Check _meta.lua exists
    local meta_path = staging_dir .. "/_meta.lua"
    if lfs.attributes(meta_path, "mode") ~= "file" then
        return false, "_meta.lua not found in extracted plugin"
    end

    -- Check main.lua exists
    if lfs.attributes(staging_dir .. "/main.lua", "mode") ~= "file" then
        return false, "main.lua not found in extracted plugin"
    end

    -- Load and verify version
    local load_ok, loaded_meta = pcall(dofile, meta_path)
    if not load_ok then
        return false, "Failed to load _meta.lua: " .. tostring(loaded_meta)
    end

    if not loaded_meta or not loaded_meta.version then
        return false, "_meta.lua does not contain version"
    end

    if loaded_meta.version ~= expected_version then
        return false, "Version mismatch: expected " .. expected_version .. ", got " .. loaded_meta.version
    end

    return true
end

--- Preserve user-owned files from the current plugin directory
--- @param src_dir string Current plugin directory
--- @param preserve_dir string Temporary directory to hold user files
--- @return boolean success, string|nil error_msg
local function preserveUserFiles(src_dir, preserve_dir)
    lfs.mkdir(preserve_dir)
    if lfs.attributes(preserve_dir, "mode") ~= "directory" then
        return false, "Failed to create preserve directory"
    end

    for _idx, filename in ipairs(USER_FILES) do
        local src_path = src_dir .. "/" .. filename
        if lfs.attributes(src_path, "mode") == "file" then
            local err = ffiutil.copyFile(src_path, preserve_dir .. "/" .. filename)
            if err then
                logger.warn("UpdateChecker: failed to preserve", filename, ":", err)
            end
        end
    end

    for _idx, dirname in ipairs(USER_DIRS) do
        local src_path = src_dir .. "/" .. dirname
        if lfs.attributes(src_path, "mode") == "directory" then
            local ret = ffiutil.execute(cp_bin, "-r", src_path, preserve_dir .. "/" .. dirname)
            if ret ~= 0 then
                logger.warn("UpdateChecker: failed to preserve directory", dirname)
            end
        end
    end

    return true
end

--- Restore user-owned files into the newly installed plugin directory
--- Non-fatal: plugin works even if user files aren't restored
--- @param preserve_dir string Directory containing preserved user files
--- @param target_dir string New plugin directory
--- @return boolean success, string|nil error_msg
local function restoreUserFiles(preserve_dir, target_dir)
    if lfs.attributes(preserve_dir, "mode") ~= "directory" then
        return false, "Preserve directory not found"
    end

    for _idx, filename in ipairs(USER_FILES) do
        local src_path = preserve_dir .. "/" .. filename
        if lfs.attributes(src_path, "mode") == "file" then
            local ret = ffiutil.execute(mv_bin, src_path, target_dir .. "/" .. filename)
            if ret ~= 0 then
                -- Fallback: try copy + delete
                local err = ffiutil.copyFile(src_path, target_dir .. "/" .. filename)
                if not err then
                    os.remove(src_path)
                else
                    logger.warn("UpdateChecker: failed to restore", filename)
                end
            end
        end
    end

    for _idx, dirname in ipairs(USER_DIRS) do
        local src_path = preserve_dir .. "/" .. dirname
        if lfs.attributes(src_path, "mode") == "directory" then
            local target_path = target_dir .. "/" .. dirname
            -- Remove target if it exists (shouldn't for user dirs, but be safe)
            if lfs.attributes(target_path, "mode") == "directory" then
                ffiutil.purgeDir(target_path)
            end
            local ret = ffiutil.execute(mv_bin, src_path, target_path)
            if ret ~= 0 then
                logger.warn("UpdateChecker: failed to restore directory", dirname)
            end
        end
    end

    return true
end

--- Find an available backup directory path (handles collisions from leftover backups)
--- @param base_path string Base path for the backup directory
--- @return string available_path
local function findAvailableBackupPath(base_path)
    if lfs.attributes(base_path, "mode") ~= "directory" then
        return base_path
    end

    -- Try numbered suffixes
    for i = 2, 10 do
        local numbered_path = base_path .. "_" .. i
        if lfs.attributes(numbered_path, "mode") ~= "directory" then
            return numbered_path
        end
    end

    -- Last resort: purge the original and reuse it
    logger.warn("UpdateChecker: too many leftover backups, purging", base_path)
    ffiutil.purgeDir(base_path)
    return base_path
end

--- Main auto-update orchestrator. Called when user taps "Update Now".
--- Downloads, extracts, verifies, and installs the update with user file preservation.
--- @param update_info table Contains zip_url, latest_version, and other update metadata
performUpdate = function(update_info)
    -- Guard: don't update git-based dev installs (would destroy repo)
    if lfs.attributes(plugin_dir .. ".git", "mode") == "directory" then
        UIManager:show(InfoMessage:new{
            text = _("Auto-update is disabled for git-based installs. Please use git pull instead."),
            timeout = 5,
        })
        return
    end

    if not update_info.zip_url then
        UIManager:show(InfoMessage:new{
            text = _("No download URL available for this release. Please update manually."),
            timeout = 5,
        })
        return
    end

    -- Guard: need network
    if not NetworkMgr:isOnline() then
        UIManager:show(InfoMessage:new{
            text = _("No network connection. Please connect and try again."),
            timeout = 3,
        })
        return
    end

    -- Compute paths - all siblings in plugins/ directory for atomic renames
    local plugin_path = plugin_dir:gsub("/$", "")  -- Remove trailing slash
    local plugins_parent = plugin_path:match("(.*/)")  -- Parent directory
    local archive_path = plugins_parent .. "koassistant.koplugin_update.zip"
    local staging_path = plugins_parent .. "koassistant.koplugin_staging"
    local preserve_path = plugins_parent .. "koassistant.koplugin_userfiles"
    local backup_base = plugins_parent .. "koassistant.koplugin.backup"

    -- Helper to clean up temp files and show error
    local function updateFailed(msg, cleanup_paths)
        for _idx, path in ipairs(cleanup_paths or {}) do
            local attr = lfs.attributes(path, "mode")
            if attr == "file" then
                os.remove(path)
            elseif attr == "directory" then
                ffiutil.purgeDir(path)
            end
        end
        UIManager:show(InfoMessage:new{
            text = T(_("Update failed: %1"), msg),
            timeout = 8,
        })
    end

    -- Show download progress
    local progress_msg = InfoMessage:new{
        text = T(_("Downloading update %1..."), update_info.latest_version),
    }
    UIManager:show(progress_msg)
    UIManager:forceRePaint()

    -- Step 1: Download
    downloadFile(update_info.zip_url, archive_path, function(dl_success, dl_error)
        UIManager:close(progress_msg)

        if not dl_success then
            updateFailed(dl_error or _("Download failed"), { archive_path })
            return
        end

        -- Show install progress
        local install_msg = InfoMessage:new{
            text = T(_("Installing update %1..."), update_info.latest_version),
        }
        UIManager:show(install_msg)
        UIManager:forceRePaint()

        -- Step 2: Extract to staging directory
        -- Clean up any leftover staging dir
        if lfs.attributes(staging_path, "mode") == "directory" then
            ffiutil.purgeDir(staging_path)
        end
        lfs.mkdir(staging_path)

        local extract_ok = Device:unpackArchive(archive_path, staging_path, true)
        if not extract_ok then
            UIManager:close(install_msg)
            updateFailed(_("Failed to extract update archive"), { archive_path, staging_path })
            return
        end

        -- Step 3: Verify extracted plugin
        local verify_ok, verify_err = verifyExtractedPlugin(staging_path, update_info.latest_version)
        if not verify_ok then
            UIManager:close(install_msg)
            updateFailed(verify_err, { archive_path, staging_path })
            return
        end

        -- Step 4: Preserve user files
        if lfs.attributes(preserve_path, "mode") == "directory" then
            ffiutil.purgeDir(preserve_path)
        end
        local preserve_ok, preserve_err = preserveUserFiles(plugin_path, preserve_path)
        if not preserve_ok then
            UIManager:close(install_msg)
            updateFailed(preserve_err, { archive_path, staging_path, preserve_path })
            return
        end

        -- Step 5: Atomic swap - old plugin -> backup
        local backup_path = findAvailableBackupPath(backup_base)
        local mv_ret = ffiutil.execute(mv_bin, plugin_path, backup_path)
        if mv_ret ~= 0 then
            UIManager:close(install_msg)
            updateFailed(_("Failed to move current plugin to backup"), { archive_path, staging_path, preserve_path })
            return
        end

        -- Step 6: Atomic swap - staging -> plugin dir
        mv_ret = ffiutil.execute(mv_bin, staging_path, plugin_path)
        if mv_ret ~= 0 then
            -- CRITICAL: Restore from backup
            logger.err("UpdateChecker: CRITICAL - staging move failed, restoring backup")
            ffiutil.execute(mv_bin, backup_path, plugin_path)
            UIManager:close(install_msg)
            updateFailed(_("Failed to install new plugin version. Previous version restored."), { archive_path, preserve_path })
            return
        end

        -- Step 7: Restore user files (non-fatal)
        local restore_ok, restore_err = restoreUserFiles(preserve_path, plugin_path)
        if not restore_ok then
            logger.warn("UpdateChecker: user file restore issue:", restore_err)
        end

        -- Step 8: Cleanup (non-fatal)
        pcall(os.remove, archive_path)
        pcall(ffiutil.purgeDir, backup_path)
        pcall(ffiutil.purgeDir, preserve_path)

        UIManager:close(install_msg)

        -- Show success and ask for restart
        local restart_msg = T(_("KOAssistant updated to version %1.\n\nPlease restart KOReader to use the new version."), update_info.latest_version)
        if not restore_ok then
            restart_msg = restart_msg .. "\n\n" .. _("Note: Some user files (API keys, custom actions) may need to be reconfigured.")
        end

        UIManager:askForRestart(restart_msg)
    end)
end

function UpdateChecker.checkForUpdates(auto, include_prereleases)
    -- Prevent duplicate auto-checks within same session
    -- (NetworkMgr:runWhenOnline can fire multiple times if network state changes)
    if auto and _session_auto_check_done then
        logger.dbg("UpdateChecker: skipping duplicate auto-check this session")
        return
    end
    if auto then
        _session_auto_check_done = true
    end

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
            -- Extract zip asset URL for auto-update
            local zip_url = nil
            if latest_release.assets then
                for _idx, asset in ipairs(latest_release.assets) do
                    if asset.name and asset.name:match("%.zip$") then
                        zip_url = asset.browser_download_url
                        break
                    end
                end
            end

            -- New version available
            local update_info = {
                current_version = current_version,
                latest_version = latest_version,
                release_notes = latest_release.body or "No release notes available.",
                download_url = latest_release.html_url,
                is_prerelease = latest_release.prerelease or false,
                zip_url = zip_url,
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