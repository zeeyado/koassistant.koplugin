local json = require("json")
local logger = require("koassistant_logger")
local Constants = require("koassistant_constants")
local Registry = require("koassistant_storage_registry")
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
        logger.dbg("UpdateChecker: fell back to require('_meta'), got plugin:", meta.name)
    end
else
    logger.warn("UpdateChecker: could not determine plugin dir, using require('_meta')")
    meta = require("_meta")
    logger.dbg("UpdateChecker: loaded via require, got plugin:", meta.name)
end

-- Core modules always loaded (needed for subprocess fetch/poll)
local UIManager = require("ui/uimanager")
local T = require("ffi/util").template
local _ = require("koassistant_gettext")

-- UI modules lazy-loaded on first use to avoid blocking startup.
-- The auto-check path (checkForUpdates with auto=true) only needs core modules
-- above; the ~25 UI widget modules below are only needed when showing popups.
local InfoMessage, ConfirmBox, Device, Screen, BD, ButtonDialog, Notification
local NetworkMgr, LuaSettings, DataStorage
local Blitbuffer, ButtonTable, CenterContainer, Font, FrameContainer, Geom
local InputContainer, MovableContainer, ScrollHtmlWidget, ScrollTextWidget
local Size, TitleBar, VerticalGroup, GestureRange, MD, Languages

local function loadUI()
    if Device then return end -- already loaded
    InfoMessage = require("ui/widget/infomessage")
    ConfirmBox = require("ui/widget/confirmbox")
    Device = require("device")
    Screen = Device.screen
    BD = require("ui/bidi")
    ButtonDialog = require("ui/widget/buttondialog")
    Notification = require("ui/widget/notification")
    NetworkMgr = require("ui/network/manager")
    LuaSettings = require("luasettings")
    DataStorage = require("datastorage")
    Blitbuffer = require("ffi/blitbuffer")
    ButtonTable = require("ui/widget/buttontable")
    CenterContainer = require("ui/widget/container/centercontainer")
    Font = require("ui/font")
    FrameContainer = require("ui/widget/container/framecontainer")
    Geom = require("ui/geometry")
    InputContainer = require("ui/widget/container/inputcontainer")
    MovableContainer = require("ui/widget/container/movablecontainer")
    ScrollHtmlWidget = require("ui/widget/scrollhtmlwidget")
    ScrollTextWidget = require("ui/widget/scrolltextwidget")
    Size = require("ui/size")
    TitleBar = require("ui/widget/titlebar")
    VerticalGroup = require("ui/widget/verticalgroup")
    GestureRange = require("ui/gesturerange")
    MD = require("apps/filemanager/lib/md")
    Languages = require("koassistant_languages")
end

-- Session flag to prevent multiple auto-checks per session
-- (NetworkMgr:runWhenOnline can fire multiple times if network state changes)
local _session_auto_check_done = false
local _session_auto_check_inflight = false

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
    loadUI()

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

-- Simple Markdown Viewer widget for release notes (lazy-initialized)
local MarkdownViewer

local function ensureMarkdownViewer()
    if MarkdownViewer then return end
    loadUI()
    MarkdownViewer = InputContainer:extend{
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
end

local UpdateChecker = {}

-- Pending update info (deferred if streaming is active)
UpdateChecker.pending_update = nil

--- Parse a version string: 1 to 3 numeric components (missing ones read as 0),
--- an optional pre-release after "-", build metadata after "+" ignored, an
--- optional leading v. "1.0.0-rc.11", "2.0", "v0.22.0" all parse; "1.2.3.4" and
--- "abc" do not. (2026-09-07: two-part tags used to be dropped from the candidate
--- list and rc.11 sorted below rc.9, parity audit F098.)
--- @param versionString string
--- @return table|nil {major, minor, patch, prerelease, original}
local function parseVersion(versionString)
    if type(versionString) ~= "string" then
        logger.err("parseVersion: expected string, got " .. type(versionString))
        return nil
    end
    local body = versionString:gsub("^[vV]%.?", ""):gsub("%+.*$", "")
    local core, prerelease = body:match("^([%d%.]+)%-(.*)$")
    if not core then
        core, prerelease = body, nil
    end
    local nums = {}
    for part in core:gmatch("[^%.]+") do
        if not part:match("^%d+$") then return nil end
        table.insert(nums, tonumber(part))
    end
    if #nums < 1 or #nums > 3 or core:match("%.%.") or core:match("^%.") or core:match("%.$") then
        return nil
    end
    if prerelease == "" then prerelease = nil end
    return {
        major = nums[1],
        minor = nums[2] or 0,
        patch = nums[3] or 0,
        prerelease = prerelease,
        original = versionString
    }
end

--- SemVer pre-release order: dot-separated identifiers compared one by one,
--- numbers numerically, a number below any word, words by text (so alpha <
--- beta < rc), and when one list is a prefix of the other the shorter is older.
local function comparePrerelease(a, b)
    local pa, pb = {}, {}
    for id in a:gmatch("[^%.]+") do table.insert(pa, id) end
    for id in b:gmatch("[^%.]+") do table.insert(pb, id) end
    for i = 1, math.max(#pa, #pb) do
        local x, y = pa[i], pb[i]
        if x == nil then return -1 end
        if y == nil then return 1 end
        local nx = x:match("^%d+$") and tonumber(x)
        local ny = y:match("^%d+$") and tonumber(y)
        if nx and ny then
            if nx ~= ny then return nx < ny and -1 or 1 end
        elseif nx then
            return -1
        elseif ny then
            return 1
        elseif x ~= y then
            return x < y and -1 or 1
        end
    end
    return 0
end

--- Compare two version strings.
--- @return number -1 if v1 < v2, 0 if equal or unparseable, 1 if v1 > v2
local function compareVersions(v1, v2)
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

    -- A release is newer than any of its pre-releases (1.0.0 > 1.0.0-rc.1)
    if not ver1.prerelease and ver2.prerelease then
        return 1
    elseif ver1.prerelease and not ver2.prerelease then
        return -1
    elseif ver1.prerelease and ver2.prerelease then
        return comparePrerelease(ver1.prerelease, ver2.prerelease)
    end

    return 0
end
UpdateChecker.parseVersion = parseVersion
UpdateChecker.compareVersions = compareVersions

--- Get non-English interaction languages for the translate picker
--- @return table: Array of language IDs (filtered, no English)
local function getNonEnglishInteractionLanguages()
    loadUI()
    local settings_file = DataStorage:getSettingsDir() .. "/koassistant_settings.lua"
    local settings = LuaSettings:open(settings_file)
    local features = settings:readSetting("features") or {}

    -- Support both new array format and old comma-separated string
    local langs = features.interaction_languages or features.user_languages
    local all_languages = {}
    if type(langs) == "table" then
        for _idx, lang in ipairs(langs) do
            if lang and lang ~= "" then table.insert(all_languages, lang) end
        end
    elseif type(langs) == "string" and langs ~= "" then
        for lang in langs:gmatch("([^,]+)") do
            local trimmed = lang:match("^%s*(.-)%s*$")
            if trimmed ~= "" then table.insert(all_languages, trimmed) end
        end
    end

    local result = {}
    for _idx, lang in ipairs(all_languages) do
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
    ensureMarkdownViewer()
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

    -- API key is resolved by GptQuery.query via getApiKey() using the settings
    -- passed below (GUI keys take priority over apikeys.lua, placeholders ignored).
    -- Do not read apikeys.lua here — that bypasses GUI keys and the placeholder guard.

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
    ensureMarkdownViewer()
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
                    NetworkMgr:runWhenConnected(function()
                        local title = update_info.is_prerelease and "KOAssistant Pre-release Update" or "KOAssistant Update Available"
                        if #translate_languages == 1 then
                            -- Single language: translate directly
                            translateAndShowContent(markdown_content, translate_languages[1], title, update_info)
                        else
                            -- Multiple languages: show picker
                            local picker_dialog
                            local picker_buttons = {}
                            for _idx, lang_id in ipairs(translate_languages) do
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

-- Detect if running on macOS (for TCP warmup which is only needed on macOS)
local IS_MACOS = ffi.os == "OSX"

-- User-owned files and directories that must survive auto-updates.
-- Derived from the storage registry (single source of truth, Track 33) — no
-- longer hand-maintained here or in koassistant_backup_manager.lua.
local USER_FILES = Registry.updateFiles()
local USER_DIRS = Registry.updateDirs()

-- Platform-specific binary paths (lazy — Device not yet loaded at file scope).
-- Resolves without loadUI so preserve/restore stay callable under the test
-- mocks (loadUI drags the whole widget zoo); production behavior unchanged,
-- the update flow still runs loadUI before reaching here.
local mv_bin, cp_bin
local function getBinPaths()
    if mv_bin then return end
    local is_android = false
    if Device then
        is_android = Device:isAndroid()
    else
        local ok, D = pcall(require, "device")
        if ok and D and D.isAndroid then is_android = D:isAndroid() or false end
    end
    mv_bin = is_android and "/system/bin/mv" or "/bin/mv"
    cp_bin = is_android and "/system/bin/cp" or "/bin/cp"
end

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

    -- Pre-resolve DNS in parent process (macOS only; the warmup was never used on
    -- other platforms). After fork(), getaddrinfo() aborts or hangs the child under
    -- macOS's post-fork restrictions, so skipping this guarantees a dead child and a
    -- zero-byte pipe — auto-checks failed 100% on macOS as "empty response" while
    -- manual checks (which warmed up) worked. Always resolve here: auto checks now
    -- run ~20s after startup (off the render hot window), so the brief parent-side
    -- resolve is acceptable.
    local resolved_ip
    if IS_MACOS and url:sub(1, 8) == "https://" then
        local BaseHandler = require("koassistant_api.base")
        resolved_ip = BaseHandler.resolveForSubprocess(url)
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
            if IS_MACOS and url:sub(1, 8) == "https://" then
                -- macOS: use raw SSL to bypass http.request which hangs after fork
                local BaseHandler = require("koassistant_api.base")
                local parsed_host = url:match("https://([^/:]+)")
                local parsed_port = tonumber(url:match("https://[^/:]+:(%d+)")) or 443
                local parsed_path = url:match("https://[^/]+(.*)") or "/"

                local ssl_sock = BaseHandler.connectSSLInSubprocess(resolved_ip, parsed_host, parsed_port, 8)
                local req_headers = {
                    ["Accept"] = "application/vnd.github.v3+json",
                    ["User-Agent"] = "KOReader-KOAssistant-Plugin",
                }

                -- Send GET request and read headers (reuse helper via raw protocol)
                local req_lines = {
                    string.format("GET %s HTTP/1.1", parsed_path),
                    string.format("Host: %s", parsed_host),
                }
                for k, v in pairs(req_headers) do
                    table.insert(req_lines, string.format("%s: %s", k, v))
                end
                table.insert(req_lines, "Connection: close")
                table.insert(req_lines, "")
                table.insert(req_lines, "")
                ssl_sock:send(table.concat(req_lines, "\r\n"))

                -- Read status line
                local status_line = ssl_sock:receive("*l")
                local status_code = status_line and tonumber(status_line:match("HTTP/%S+%s+(%d+)"))

                -- Read response headers
                local is_chunked = false
                while true do
                    local line = ssl_sock:receive("*l")
                    if not line or line == "" then break end
                    if line:lower():match("^transfer%-encoding:%s*chunked") then
                        is_chunked = true
                    end
                end

                if not status_code or status_code ~= 200 then
                    -- Read error body and report
                    local err_chunks = {}
                    if is_chunked then
                        while true do
                            local size_line = ssl_sock:receive("*l")
                            if not size_line then break end
                            local chunk_size = tonumber(size_line:match("^%s*(%x+)"), 16)
                            if not chunk_size or chunk_size == 0 then break end
                            local chunk_data = ssl_sock:receive(chunk_size)
                            if chunk_data then table.insert(err_chunks, chunk_data) end
                            ssl_sock:receive("*l")
                        end
                    else
                        while true do
                            local chunk, recv_err, partial = ssl_sock:receive(8192)
                            if chunk then table.insert(err_chunks, chunk)
                            elseif partial and #partial > 0 then table.insert(err_chunks, partial) end
                            if recv_err then break end
                        end
                    end
                    -- Include the (truncated) error body so GitHub's actual message
                    -- (rate limit, etc.) reaches the parent log instead of being discarded
                    local err_body = table.concat(err_chunks):gsub("%s+$", ""):sub(1, 300)
                    ffiutil.writeToFD(child_write_fd, "\n__UPDATE_CHECK_ERROR__:" .. tostring(status_code or "connection failed")
                        .. (err_body ~= "" and (" - " .. err_body) or ""))
                else
                    -- Stream response body to pipe; track bytes so a clean close with an
                    -- empty body (RST after headers, captive portal, TLS oddity) reports a
                    -- diagnosable error instead of the parent's generic "empty response"
                    local body_bytes = 0
                    if is_chunked then
                        while true do
                            local size_line = ssl_sock:receive("*l")
                            if not size_line then break end
                            local chunk_size = tonumber(size_line:match("^%s*(%x+)"), 16)
                            if not chunk_size or chunk_size == 0 then break end
                            local chunk_data = ssl_sock:receive(chunk_size)
                            if chunk_data then
                                ffiutil.writeToFD(child_write_fd, chunk_data)
                                body_bytes = body_bytes + #chunk_data
                            end
                            ssl_sock:receive("*l")
                        end
                    else
                        while true do
                            local chunk, recv_err, partial = ssl_sock:receive(8192)
                            if chunk then
                                ffiutil.writeToFD(child_write_fd, chunk)
                                body_bytes = body_bytes + #chunk
                            elseif partial and #partial > 0 then
                                ffiutil.writeToFD(child_write_fd, partial)
                                body_bytes = body_bytes + #partial
                            end
                            if recv_err then break end
                        end
                    end
                    if body_bytes == 0 then
                        ffiutil.writeToFD(child_write_fd, "\n__UPDATE_CHECK_ERROR__:HTTP 200 but empty body (connection closed after headers)")
                    end
                end

                ssl_sock:close()
            else
                -- Non-macOS: use standard http.request path
                local http = require("socket.http")
                local subprocess_ltn12 = require("ltn12")

                local su_ok, socketutil = pcall(require, "socketutil")
                if su_ok and socketutil then
                    socketutil:set_timeout(8, 15)  -- 8s block, 15s total
                else
                    local subprocess_https = require("ssl.https")
                    subprocess_https.TIMEOUT = 8
                end

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
                    return select(2, http.request(request))
                end)

                if not req_ok or (code and code ~= 200) then
                    ffiutil.writeToFD(child_write_fd, "\n__UPDATE_CHECK_ERROR__:" .. tostring(code or "connection failed"))
                end
            end
        end)

        if not ok then
            ffiutil.writeToFD(child_write_fd, "\n__UPDATE_CHECK_ERROR__:" .. tostring(err))
        end

        ffi.C.close(child_write_fd)

        -- #87: exit raw to skip __cxa_finalize (Adreno SIGSEGV on some Boox devices)
        pcall(function() ffi.C._exit(0) end)
    end

    -- Set up absolute timeout watchdog - this kills the process no matter what
    timeout_task = UIManager:scheduleIn(timeout, function()
        if not completed then
            logger.info("Update check: absolute timeout reached, killing subprocess")
            cleanup()
            callback(false, "Timeout")
        end
    end)

    -- Start subprocess (pcall-protected to prevent crash if fork fails)
    local fork_ok
    fork_ok, pid, parent_read_fd = pcall(ffiutil.runInSubProcess, subprocess_func, true)

    if not fork_ok or not pid then
        cleanup()
        callback(false, fork_ok and "Failed to start subprocess" or ("Fork error: " .. tostring(pid)))
        return
    end

    -- Set pipe to non-blocking mode for instant EOF detection.
    -- F_GETFL=3, F_SETFL=4 are universal POSIX constants — O_NONBLOCK is NOT:
    -- KOReader's cdef hardcodes the Linux value (2048); macOS needs 0x0004 or the
    -- pipe stays blocking and read() freezes the UI (see gpt_query.lua).
    local bit = require("bit")
    local O_NONBLOCK = ffi.os == "OSX" and 0x0004 or ffi.C.O_NONBLOCK
    local nb_flags = ffi.C.fcntl(parent_read_fd, 3)  -- F_GETFL
    if nb_flags >= 0 then
        ffi.C.fcntl(parent_read_fd, 4, ffi.cast("int", bit.bor(nb_flags, O_NONBLOCK)))  -- F_SETFL
    end

    local chunksize = 8192
    local buffer = ffi.new("char[?]", chunksize)

    local function processResult()
        closeFd()
        cleanup(true)  -- skip_fd_close since we already closed it

        -- Check for error marker
        local error_msg = accumulated_data:match("__UPDATE_CHECK_ERROR__:(.+)")
        if error_msg then
            callback(false, error_msg)
        else
            callback(true, accumulated_data)
        end
    end

    local function pollForData()
        if completed then return end

        -- Read all available data (non-blocking)
        while true do
            local bytes_read = tonumber(ffi.C.read(parent_read_fd, buffer, chunksize))
            if bytes_read and bytes_read > 0 then
                accumulated_data = accumulated_data .. ffi.string(buffer, bytes_read)
            elseif bytes_read == 0 then
                -- EOF: subprocess closed pipe, process immediately
                processResult()
                return
            else
                break  -- EAGAIN: no data available yet
            end
        end

        -- Fallback: check waitpid (works on most devices)
        if ffiutil.isSubProcessDone(pid) then
            processResult()
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
    -- Pre-resolve DNS in parent process (macOS only)
    local resolved_ip
    if IS_MACOS and url:sub(1, 8) == "https://" then
        local BaseHandler = require("koassistant_api.base")
        resolved_ip = BaseHandler.resolveForSubprocess(url)
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
            if IS_MACOS and url:sub(1, 8) == "https://" then
                -- macOS: use raw SSL to bypass http.request which hangs after fork
                local BaseHandler = require("koassistant_api.base")
                local parsed_host = url:match("https://([^/:]+)")
                local parsed_port = tonumber(url:match("https://[^/:]+:(%d+)")) or 443
                local parsed_path = url:match("https://[^/]+(.*)") or "/"

                local ssl_sock = BaseHandler.connectSSLInSubprocess(resolved_ip, parsed_host, parsed_port, DOWNLOAD_TIMEOUT - 5)

                -- Send GET request
                local req_lines = {
                    string.format("GET %s HTTP/1.1", parsed_path),
                    string.format("Host: %s", parsed_host),
                    "User-Agent: KOReader-KOAssistant-Plugin",
                    "Connection: close",
                    "", "",
                }
                ssl_sock:send(table.concat(req_lines, "\r\n"))

                -- Read status line
                local status_line = ssl_sock:receive("*l")
                local status_code = status_line and tonumber(status_line:match("HTTP/%S+%s+(%d+)"))

                -- Read response headers, detect chunked TE and content-length
                local is_chunked = false
                local content_length = nil
                while true do
                    local line = ssl_sock:receive("*l")
                    if not line or line == "" then break end
                    if line:lower():match("^transfer%-encoding:%s*chunked") then
                        is_chunked = true
                    end
                    local cl = line:lower():match("^content%-length:%s*(%d+)")
                    if cl then content_length = tonumber(cl) end
                end

                if not status_code or status_code ~= 200 then
                    os.remove(dest_path)
                    ffiutil.writeToFD(child_write_fd, "ERROR:" .. tostring(status_code or "connection failed"))
                else
                    -- Write body to file
                    local output_file = io.open(dest_path, "wb")
                    if not output_file then
                        ffiutil.writeToFD(child_write_fd, "ERROR:Failed to create file")
                    else
                        if is_chunked then
                            while true do
                                local size_line = ssl_sock:receive("*l")
                                if not size_line then break end
                                local chunk_size = tonumber(size_line:match("^%s*(%x+)"), 16)
                                if not chunk_size or chunk_size == 0 then break end
                                local chunk_data = ssl_sock:receive(chunk_size)
                                if chunk_data then output_file:write(chunk_data) end
                                ssl_sock:receive("*l")
                            end
                        else
                            while true do
                                local chunk, recv_err, partial = ssl_sock:receive(8192)
                                if chunk then output_file:write(chunk)
                                elseif partial and #partial > 0 then output_file:write(partial) end
                                if recv_err then break end
                            end
                        end
                        output_file:close()
                        ffiutil.writeToFD(child_write_fd, "OK")
                    end
                end

                ssl_sock:close()
            else
                -- Non-macOS: use standard https.request path
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
            end
        end)

        if not ok then
            os.remove(dest_path)
            ffiutil.writeToFD(child_write_fd, "ERROR:" .. tostring(sub_err))
        end

        ffi.C.close(child_write_fd)

        -- #87: exit raw to skip __cxa_finalize (Adreno SIGSEGV on some Boox devices)
        pcall(function() ffi.C._exit(0) end)
    end, true)

    if not pid then
        cleanup()
        callback(false, _("Failed to start download"))
        return
    end

    -- Set pipe to non-blocking mode for instant EOF detection.
    -- (O_NONBLOCK is platform-specific — see the note at the other fcntl site above.)
    local bit = require("bit")
    local O_NONBLOCK = ffi.os == "OSX" and 0x0004 or ffi.C.O_NONBLOCK
    local nb_flags = ffi.C.fcntl(parent_read_fd, 3)  -- F_GETFL
    if nb_flags >= 0 then
        ffi.C.fcntl(parent_read_fd, 4, ffi.cast("int", bit.bor(nb_flags, O_NONBLOCK)))  -- F_SETFL
    end

    -- Poll for subprocess completion (small buffer - pipe only carries status)
    local chunksize = 256
    local buffer = ffi.new("char[?]", chunksize)

    local function processResult()
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
    end

    local function pollForData()
        if completed then return end

        -- Read all available data (non-blocking)
        while true do
            local bytes_read = tonumber(ffi.C.read(parent_read_fd, buffer, chunksize))
            if bytes_read and bytes_read > 0 then
                status_data = status_data .. ffi.string(buffer, bytes_read)
            elseif bytes_read == 0 then
                -- EOF: subprocess closed pipe, process immediately
                processResult()
                return
            else
                break  -- EAGAIN: no data available yet
            end
        end

        -- Fallback: check waitpid (works on most devices)
        if ffiutil.isSubProcessDone(pid) then
            processResult()
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

--- First file under `src` that is missing from `dst` or differs in size.
--- Judges the copy by what is on disk, never by exit codes: ffiutil.copyFile
--- ignores write errors (a full disk leaves a truncated file and reports
--- success), and execute's status differs by platform.
--- @return string|nil relative path of the first mismatch, nil when all match
local function copyMismatch(src, dst, rel)
    local src_attr = lfs.attributes(src)
    if not src_attr then return nil end
    local dst_attr = lfs.attributes(dst)
    if not dst_attr or dst_attr.mode ~= src_attr.mode then
        return rel
    end
    if src_attr.mode == "file" then
        if dst_attr.size ~= src_attr.size then return rel end
        return nil
    end
    if src_attr.mode == "directory" then
        for entry in lfs.dir(src) do
            if entry ~= "." and entry ~= ".." then
                local bad = copyMismatch(src .. "/" .. entry, dst .. "/" .. entry, rel .. "/" .. entry)
                if bad then return bad end
            end
        end
    end
    return nil
end

--- First user file or folder (USER_FILES + USER_DIRS) that `from_dir` holds and
--- `to_dir` lacks or holds a different size of. nil when every one arrived.
local function firstMissingUserItem(from_dir, to_dir)
    for _idx, list in ipairs({ USER_FILES, USER_DIRS }) do
        for _idx2, name in ipairs(list) do
            local bad = copyMismatch(from_dir .. "/" .. name, to_dir .. "/" .. name, name)
            if bad then return bad end
        end
    end
    return nil
end

--- Preserve user-owned files from the current plugin directory
--- Fails (and the update aborts, before anything is moved) when a preserved
--- copy is missing or short, since step 8 deletes the only other copy.
--- @param src_dir string Current plugin directory
--- @param preserve_dir string Temporary directory to hold user files
--- @return boolean success, string|nil error_msg
local function preserveUserFiles(src_dir, preserve_dir)
    getBinPaths()  -- self-contained: direct calls (tests) skip the update flow's init
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

    local bad = firstMissingUserItem(src_dir, preserve_dir)
    if bad then
        logger.warn("UpdateChecker: preserved copy missing or incomplete:", bad)
        return false, T(_("Could not save a copy of your file %1 before updating (storage full?). Nothing was changed."), bad)
    end

    return true
end

--- Restore user-owned files into the newly installed plugin directory
--- Non-fatal: plugin works even if user files aren't restored
--- @param preserve_dir string Directory containing preserved user files
--- @param target_dir string New plugin directory
--- @return boolean success, string|nil error_msg
local function restoreUserFiles(preserve_dir, target_dir)
    getBinPaths()  -- self-contained: direct calls (tests) skip the update flow's init
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

--- Extract the update zip into staging_path with the archive's single root
--- directory ("koassistant.koplugin/") stripped.
--- KOReader builds through mid-2026 provide Device:unpackArchive; newer builds
--- removed it in favor of ffi/archiver (shipped since KOReader 2025.06), so
--- support both. The iterate/extractToPath loop below replicates what the old
--- Device method did internally.
--- @return boolean ok, string|nil error (error is for logging, not display)
local function extractUpdateArchive(archive_path, staging_path)
    if Device.unpackArchive then
        return Device:unpackArchive(archive_path, staging_path, true)
    end
    local ok_mod, Archiver = pcall(require, "ffi/archiver")
    if not ok_mod or type(Archiver) ~= "table" or not Archiver.Reader then
        return false, "no archive extraction API in this KOReader version"
    end
    local arc = Archiver.Reader:new()
    if not arc:open(archive_path) then
        local open_err = arc.err
        arc:close()
        return false, open_err or "could not open archive"
    end
    for entry in arc:iterate() do
        -- Strip one leading path component; the root directory entry itself
        -- (no remainder after the slash) is skipped.
        local tail = entry.path:match("^[^/]+/(.+)$")
        if tail then
            if not arc:extractToPath(entry.path, staging_path .. "/" .. tail) then
                break
            end
        end
    end
    local ok = not arc.err
    local extract_err = arc.err
    arc:close()
    if not ok then
        return false, extract_err or "extraction failed"
    end
    return true
end

--- Main auto-update orchestrator. Called when user taps "Update Now".
--- Downloads, extracts, verifies, and installs the update with user file preservation.
--- @param update_info table Contains zip_url, latest_version, and other update metadata
performUpdate = function(update_info)
    loadUI()
    getBinPaths()
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

        local extract_ok, extract_err = extractUpdateArchive(archive_path, staging_path)
        if not extract_ok then
            if extract_err then
                logger.err("UpdateChecker: extract failed:", extract_err)
            end
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
            local restore_ret = ffiutil.execute(mv_bin, backup_path, plugin_path)
            UIManager:close(install_msg)
            if restore_ret ~= 0 then
                logger.err("UpdateChecker: CRITICAL - backup restore also failed!")
                updateFailed(_("Failed to install update AND failed to restore previous version. Backup is at: ") .. backup_path, { archive_path, preserve_path })
            else
                updateFailed(_("Failed to install new plugin version. Previous version restored."), { archive_path, preserve_path })
            end
            return
        end

        -- Step 7: Restore user files (non-fatal)
        local restore_ok, restore_err = restoreUserFiles(preserve_path, plugin_path)
        if not restore_ok then
            logger.warn("UpdateChecker: user file restore issue:", restore_err)
        end
        -- Check against the originals, still in the old plugin folder: when a
        -- file did not arrive intact, step 8 keeps that folder instead of
        -- deleting the only good copy.
        local missing = firstMissingUserItem(backup_path, plugin_path)
        if missing then
            logger.warn("UpdateChecker: user file did not reach the new version, keeping", backup_path, ":", missing)
        end

        -- Step 8: Cleanup (non-fatal)
        pcall(os.remove, archive_path)
        if not missing then
            pcall(ffiutil.purgeDir, backup_path)
            pcall(ffiutil.purgeDir, preserve_path)
        end

        UIManager:close(install_msg)

        -- Show success and ask for restart
        local restart_msg = T(_("KOAssistant updated to version %1.\n\nPlease restart KOReader to use the new version."), update_info.latest_version)
        if missing then
            restart_msg = restart_msg .. "\n\n" .. T(_("Note: your file %1 could not be carried over to the new version. The previous version, with all your files, is kept at:\n%2"), missing, backup_path)
        elseif not restore_ok then
            restart_msg = restart_msg .. "\n\n" .. _("Note: Some user files (API keys, custom actions) may need to be reconfigured.")
        end

        UIManager:askForRestart(restart_msg)
    end)
end

function UpdateChecker.checkForUpdates(auto, include_prereleases)
    -- Prevent duplicate/concurrent auto-checks within the same session. The DONE
    -- flag is only set on a successful check (see the fetch callback) so a failed
    -- check gets retried on the next plugin init; INFLIGHT guards concurrency
    -- (FileManager and ReaderUI both init and may schedule a check).
    if auto and (_session_auto_check_done or _session_auto_check_inflight) then
        logger.dbg("UpdateChecker: skipping duplicate auto-check this session")
        return
    end
    if auto then
        _session_auto_check_inflight = true
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
        loadUI()
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
        _session_auto_check_inflight = false

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

        -- Guard against empty response (connection failed silently)
        if not response_data or response_data == "" then
            logger.err("Update check: empty response from GitHub API")
            if not auto then
                loadUI()
                UIManager:show(InfoMessage:new{
                    text = "Failed to check for updates: Empty response from server",
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

        -- Check completed with a parseable payload: only now mark the session done
        -- (failures above fall through so the next plugin init retries) and persist
        -- the timestamp for the 24h min-interval gate in main.lua's auto trigger.
        if auto then
            _session_auto_check_done = true
        end
        G_reader_settings:saveSetting("koassistant_last_update_check", os.time())

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

-- Test seams (release-blocking six-pack [4], 2026-08-17): the registry-driven
-- preserve/restore pair, previously untestable file-locals — the old test
-- exercised a hand-copied re-implementation instead of this shipping code.
UpdateChecker._preserveUserFiles = preserveUserFiles
UpdateChecker._firstMissingUserItem = firstMissingUserItem
UpdateChecker._restoreUserFiles = restoreUserFiles

return UpdateChecker