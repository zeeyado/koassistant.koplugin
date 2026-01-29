--[[--
Displays some text in a scrollable view.

@usage
    local chatgptviewer = ChatGPTViewer:new{
        title = _("I can scroll!"),
        text = _("I'll need to be longer than this example to scroll."),
    }
    UIManager:show(chatgptviewer)
]]
local BD = require("ui/bidi")
local Blitbuffer = require("ffi/blitbuffer")
local ButtonDialog = require("ui/widget/buttondialog")
local ButtonTable = require("ui/widget/buttontable")
local CenterContainer = require("ui/widget/container/centercontainer")
local CheckButton = require("ui/widget/checkbutton")
local Device = require("device")
local logger = require("logger")
local Geom = require("ui/geometry")
local Font = require("ui/font")
local FrameContainer = require("ui/widget/container/framecontainer")
local GestureRange = require("ui/gesturerange")
local InfoMessage = require("ui/widget/infomessage")
local InputContainer = require("ui/widget/container/inputcontainer")
local InputDialog = require("ui/widget/inputdialog")
local MovableContainer = require("ui/widget/container/movablecontainer")
local Notification = require("ui/widget/notification")
local ScrollTextWidget = require("ui/widget/scrolltextwidget")
local ScrollHtmlWidget = require("ui/widget/scrollhtmlwidget")
local Size = require("ui/size")
local TextViewer = require("ui/widget/textviewer")
local TitleBar = require("ui/widget/titlebar")
local UIManager = require("ui/uimanager")
local VerticalGroup = require("ui/widget/verticalgroup")
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local T = require("ffi/util").template
local util = require("util")
local _ = require("koassistant_gettext")
local Screen = Device.screen
local MD = require("apps/filemanager/lib/md")
local SpinWidget = require("ui/widget/spinwidget")
local UIConstants = require("koassistant_ui.constants")

-- Show link options dialog (matches KOReader's ReaderLink external link dialog)
local link_dialog  -- Forward declaration for closures
local function showLinkDialog(link_url)
    if not link_url then return end

    local QRMessage = require("ui/widget/qrmessage")
    local Event = require("ui/event")

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

    -- Row 2: Add to Wallabag (if available) | Open in browser
    local row2 = {}

    -- Try to add Wallabag option by broadcasting event (works if ReaderUI is active)
    -- Check if we can reach the Wallabag plugin through ReaderUI
    local ReaderUI = require("apps/reader/readerui")
    local reader_ui = ReaderUI.instance
    if reader_ui and reader_ui.wallabag then
        table.insert(row2, {
            text = _("Add to Wallabag"),
            callback = function()
                UIManager:close(link_dialog)
                UIManager:broadcastEvent(Event:new("AddWallabagArticle", link_url))
            end,
        })
    end

    if Device:canOpenLink() then
        table.insert(row2, {
            text = _("Open in browser"),
            callback = function()
                UIManager:close(link_dialog)
                Device:openLink(link_url)
            end,
        })
    end

    if #row2 > 0 then
        table.insert(buttons, row2)
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

-- Show content picker dialog for Copy/Note "Ask every time" mode
-- @param title string Dialog title
-- @param is_translate boolean Whether this is for translate view (different labels)
-- @param callback function(content) Called with selected content type
local function showContentPicker(title, is_translate, callback)
    local content_dialog
    local options = {
        { value = "full", label = _("Full (metadata + chat)") },
        { value = "qa", label = _("Question + Response") },
        { value = "response", label = is_translate and _("Translation only") or _("Response only") },
        { value = "everything", label = _("Everything (debug)") },
    }

    local buttons = {}
    for _idx, opt in ipairs(options) do
        table.insert(buttons, {
            {
                text = opt.label,
                callback = function()
                    UIManager:close(content_dialog)
                    callback(opt.value)
                end,
            },
        })
    end
    table.insert(buttons, {
        {
            text = _("Cancel"),
            callback = function()
                UIManager:close(content_dialog)
            end,
        },
    })

    content_dialog = ButtonDialog:new{
        title = title,
        buttons = buttons,
    }
    UIManager:show(content_dialog)
end

-- Pre-process markdown tables to HTML (luamd doesn't support tables)
local function preprocessMarkdownTables(text)
    if not text then return text end

    local lines = {}
    for line in text:gmatch("([^\n]*)\n?") do
        table.insert(lines, line)
    end

    local result = {}
    local i = 1

    while i <= #lines do
        local line = lines[i]

        -- Check if this line looks like a table row (contains | and isn't a code block)
        local is_table_row = line:match("^%s*|.*|%s*$") or line:match("^%s*[^|]+|[^|]+")

        -- Also check if next line is a separator row (|----|----| pattern)
        local next_line = lines[i + 1]
        local is_separator = next_line and next_line:match("^%s*|?[%s%-:]+|[%s%-:|]+$")

        if is_table_row and is_separator then
            -- Found a markdown table, parse it
            local table_html = {"<table>"}

            -- Parse header row
            local header_cells = {}
            for cell in line:gmatch("[^|]+") do
                local trimmed = cell:match("^%s*(.-)%s*$")
                if trimmed and trimmed ~= "" then
                    table.insert(header_cells, trimmed)
                end
            end

            -- Parse alignment from separator row
            local alignments = {}
            for sep in next_line:gmatch("[^|]+") do
                local trimmed = sep:match("^%s*(.-)%s*$")
                if trimmed and trimmed:match("^:?%-+:?$") then
                    if trimmed:match("^:.*:$") then
                        table.insert(alignments, "center")
                    elseif trimmed:match(":$") then
                        table.insert(alignments, "right")
                    else
                        table.insert(alignments, "left")
                    end
                end
            end

            -- Generate header HTML
            table.insert(table_html, "<thead><tr>")
            for j, cell in ipairs(header_cells) do
                local align = alignments[j] or "left"
                table.insert(table_html, string.format('<th style="text-align:%s">%s</th>', align, cell))
            end
            table.insert(table_html, "</tr></thead>")

            -- Skip header and separator rows
            i = i + 2

            -- Parse body rows
            table.insert(table_html, "<tbody>")
            while i <= #lines do
                local body_line = lines[i]

                -- Check if still a table row
                if not (body_line:match("^%s*|.*|%s*$") or body_line:match("^%s*[^|]+|[^|]+")) then
                    break
                end

                -- Skip empty lines within table
                if body_line:match("^%s*$") then
                    break
                end

                local body_cells = {}
                for cell in body_line:gmatch("[^|]+") do
                    local trimmed = cell:match("^%s*(.-)%s*$")
                    if trimmed then
                        table.insert(body_cells, trimmed)
                    end
                end

                -- Generate row HTML
                table.insert(table_html, "<tr>")
                for j, cell in ipairs(body_cells) do
                    local align = alignments[j] or "left"
                    -- Skip empty cells that are just whitespace from leading/trailing |
                    if cell ~= "" then
                        table.insert(table_html, string.format('<td style="text-align:%s">%s</td>', align, cell))
                    end
                end
                table.insert(table_html, "</tr>")

                i = i + 1
            end
            table.insert(table_html, "</tbody></table>")

            table.insert(result, table.concat(table_html, "\n"))
        else
            table.insert(result, line)
            i = i + 1
        end
    end

    return table.concat(result, "\n")
end

-- Auto-linkify plain URLs that aren't already part of markdown links
-- Converts https://example.com to [https://example.com](https://example.com)
-- Also handles www.example.com (adds https://)
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

    -- Step 3: Convert www. URLs (need to check they're not already converted)
    -- Only match www. that isn't preceded by :// (to avoid matching https://www.)
    result = result:gsub("([^/])(www%.[%w%-%./_~:?#@!$&'*+,;=%%]+)", function(prefix, url)
        local clean_url = url:gsub("[.,;:!?)]+$", "")
        local trailing = url:sub(#clean_url + 1)
        return prefix .. "[" .. clean_url .. "](https://" .. clean_url .. ")" .. trailing
    end)
    -- Handle www. at very start of text
    if result:match("^www%.") then
        result = result:gsub("^(www%.[%w%-%./_~:?#@!$&'*+,;=%%]+)", function(url)
            local clean_url = url:gsub("[.,;:!?)]+$", "")
            local trailing = url:sub(#clean_url + 1)
            return "[" .. clean_url .. "](https://" .. clean_url .. ")" .. trailing
        end)
    end

    -- Step 4: Restore the protected markdown links
    for i = 1, link_count do
        local placeholder = "XURLLINKX" .. i .. "XURLLINKX"
        result = result:gsub(placeholder, function() return links[i] end)
    end

    return result
end

-- Pre-process brackets to prevent them being rendered as links
-- Square brackets in markdown can be interpreted as link references
local function preprocessBrackets(text)
    if not text then return text end

    -- Strategy: Preserve real markdown links [text](url) but escape other brackets
    -- Real links have the pattern: [text](url) where url starts with http/https/mailto/# or is a relative path

    -- First, temporarily replace real markdown links with placeholders
    local links = {}
    local link_count = 0

    -- Match [text](url) pattern - url can be http, https, mailto, #anchor, or relative path
    local protected_text = text:gsub("%[([^%]]+)%]%(([^%)]+)%)", function(link_text, url)
        link_count = link_count + 1
        local placeholder = "XMDLINKX" .. link_count .. "XMDLINKX"
        links[link_count] = "[" .. link_text .. "](" .. url .. ")"
        return placeholder
    end)

    -- Now escape all remaining square brackets to HTML entities
    protected_text = protected_text:gsub("%[", "&#91;")
    protected_text = protected_text:gsub("%]", "&#93;")

    -- Restore the real links from placeholders
    for i = 1, link_count do
        local placeholder = "XMDLINKX" .. i .. "XMDLINKX"
        protected_text = protected_text:gsub(placeholder, function() return links[i] end)
    end

    return protected_text
end

-- CSS for markdown rendering (function to support dynamic text-align)
local function getViewerCSS(text_align)
    text_align = text_align or "justify"
    return string.format([[
@page {
    margin: 0;
    font-family: 'Noto Sans';
}

body {
    margin: 0;
    line-height: 1.3;
    text-align: %s;
    padding: 0;
}

blockquote {
    margin: 0.5em 0;
    padding-left: 1em;
    border-left: 3px solid #ccc;
}

code {
    background-color: #f0f0f0;
    padding: 0.1em 0.3em;
    border-radius: 3px;
    font-family: monospace;
    font-size: 0.9em;
}

pre {
    background-color: #f0f0f0;
    padding: 0.5em;
    border-radius: 3px;
    overflow-x: auto;
    margin: 0.5em 0;
}

pre code {
    background-color: transparent;
    padding: 0;
}

ol, ul {
    margin: 0.5em 0;
    padding-left: 1.5em;
}

h1, h2, h3, h4, h5, h6 {
    margin: 0.5em 0 0.3em 0;
    font-weight: bold;
}

h1 { font-size: 1.5em; }
h2 { font-size: 1.3em; }
h3 { font-size: 1.1em; }

p {
    margin: 0.5em 0;
}

table {
    border-collapse: collapse;
    margin: 0.5em 0;
}

td, th {
    border: 1px solid #ccc;
    padding: 0.3em 0.5em;
}

th {
    background-color: #f0f0f0;
    font-weight: bold;
}
]], text_align)
end

local ChatGPTViewer = InputContainer:extend {
  title = nil,
  text = nil,
  width = nil,
  height = nil,
  buttons_table = nil,
  -- See TextBoxWidget for details about these options
  -- We default to justified and auto_para_direction to adapt
  -- to any kind of text we are given (book descriptions,
  -- bookmarks' text, translation results...).
  -- When used to display more technical text (HTML, CSS,
  -- application logs...), it's best to reset them to false.
  alignment = "left",
  justified = true,
  render_markdown = true, -- Convert markdown to HTML for display
  markdown_font_size = 20, -- Font size for markdown rendering
  text_align = "justify", -- Text alignment for markdown: "justify" or "left"
  lang = nil,
  para_direction_rtl = nil,
  auto_para_direction = true,
  alignment_strict = false,

  title_face = nil,               -- use default from TitleBar
  title_multilines = nil,         -- see TitleBar for details
  title_shrink_font_to_fit = nil, -- see TitleBar for details
  text_face = Font:getFace("x_smallinfofont"),
  fgcolor = Blitbuffer.COLOR_BLACK,
  text_padding = Size.padding.large,
  text_margin = Size.margin.small,
  button_padding = Size.padding.default,
  -- Bottom row with Close, Find buttons. Also added when no caller's buttons defined.
  add_default_buttons = nil,
  default_hold_callback = nil,   -- on each default button
  find_centered_lines_count = 5, -- line with find results to be not far from the center

  onAskQuestion = nil,
  save_callback = nil, -- New callback for saving chat
  export_callback = nil, -- New callback for exporting chat
  tag_callback = nil, -- Callback for tagging chat (receives showTagDialog function)
  scroll_to_bottom = false, -- Whether to scroll to bottom on show

  -- Recreate function for rotation handling
  -- Set by dialogs.lua to enable window recreation on screen rotation
  _recreate_func = nil,

  -- Session-only toggle for hiding highlighted text (does not persist)
  hide_highlighted_text = false,

  -- Compact view mode (used for dictionary lookups)
  compact_view = false,

  -- Minimal buttons mode (used for dictionary lookups)
  -- Shows only: MD/Text, Copy, Expand, Close
  minimal_buttons = false,

  -- Translate view mode (special view for translations)
  -- Shows: MD/Text, Copy, Expand, Toggle Quote, Close
  translate_view = false,

  -- Session toggle for hiding original text in translate view
  translate_hide_quote = false,

  -- Original highlighted text for translate view toggle
  original_highlighted_text = nil,

  -- Selection position data for "Save to Note" feature
  -- Contains pos0, pos1, sboxes, pboxes for recreating highlight
  selection_data = nil,

  -- Configuration passed from dialogs.lua (must be in defaults to ensure proper option merging)
  configuration = nil,
}

function ChatGPTViewer:init()
  -- calculate window dimension using shared constants
  self.align = "center"
  self.region = Geom:new {
    x = 0, y = 0,
    w = Screen:getWidth(),
    h = Screen:getHeight(),
  }
  self.width = self.width or UIConstants.CHAT_WIDTH()
  -- Use compact height if compact_view is enabled
  if self.compact_view then
    self.height = self.height or UIConstants.COMPACT_DIALOG_HEIGHT()
  else
    self.height = self.height or UIConstants.CHAT_HEIGHT()
  end

  self._find_next = false
  self._find_next_button = false
  self._old_virtual_line_num = 1

  if Device:hasKeys() then
    self.key_events.Close = { { Device.input.group.Back } }
  end

  if Device:isTouchDevice() then
    local range = Geom:new {
      x = 0, y = 0,
      w = Screen:getWidth(),
      h = Screen:getHeight(),
    }
    self.ges_events = {
      TapClose = {
        GestureRange:new {
          ges = "tap",
          range = range,
        },
      },
      Swipe = {
        GestureRange:new {
          ges = "swipe",
          range = range,
        },
      },
      MultiSwipe = {
        GestureRange:new {
          ges = "multiswipe",
          range = range,
        },
      },
      -- Allow selection of one or more words (see textboxwidget.lua):
      HoldStartText = {
        GestureRange:new {
          ges = "hold",
          range = range,
        },
      },
      HoldPanText = {
        GestureRange:new {
          ges = "hold_pan",
          range = range,
          rate = Screen.low_pan_rate and 5.0 or 30.0,
        },
      },
      HoldReleaseText = {
        GestureRange:new {
          ges = "hold_release",
          range = range,
        },
        -- callback function when HoldReleaseText is handled as args
        args = function(text, hold_duration, start_idx, end_idx, to_source_index_func)
          self:handleTextSelection(text, hold_duration, start_idx, end_idx, to_source_index_func)
        end
      },
      -- These will be forwarded to MovableContainer after some checks
      ForwardingTouch = { GestureRange:new { ges = "touch", range = range, }, },
      ForwardingPan = { GestureRange:new { ges = "pan", range = range, }, },
      ForwardingPanRelease = { GestureRange:new { ges = "pan_release", range = range, }, },
    }
  end

  local titlebar = TitleBar:new {
    width = self.width,
    align = "left",
    with_bottom_line = true,
    title = self.title,
    title_face = self.title_face,
    title_multilines = self.title_multilines,
    title_shrink_font_to_fit = self.title_shrink_font_to_fit,
    close_callback = function() self:onClose() end,
    show_parent = self,
    left_icon = "appbar.settings",
    left_icon_tap_callback = function()
      self:showViewerSettings()
    end,
  }

  -- Callback to enable/disable buttons, for at-top/at-bottom feedback
  local prev_at_top = false -- Buttons were created enabled
  local prev_at_bottom = false
  local function button_update(id, enable)
    local button = self.button_table:getButtonById(id)
    if button then
      if enable then
        button:enable()
      else
        button:disable()
      end
      button:refresh()
    end
  end
  self._buttons_scroll_callback = function(low, high)
    if prev_at_top and low > 0 then
      button_update("top", true)
      prev_at_top = false
    elseif not prev_at_top and low <= 0 then
      button_update("top", false)
      prev_at_top = true
    end
    if prev_at_bottom and high < 1 then
      button_update("bottom", true)
      prev_at_bottom = false
    elseif not prev_at_bottom and high >= 1 then
      button_update("bottom", false)
      prev_at_bottom = true
    end
  end

  -- buttons - organize into multiple rows for better layout
  -- First row: Main actions
  local first_row = {
    {
      text = _("Reply"),
      id = "ask_another_question",
      callback = function()
        self:askAnotherQuestion()
      end,
    },
    {
      text_func = function()
        -- Show "Autosaved" when auto-save is active for this chat:
        -- auto_save_all_chats, OR auto_save_chats + already saved once
        local features = self.configuration and self.configuration.features
        local auto_save = features and (
          features.auto_save_all_chats or
          (features.auto_save_chats ~= false and features.chat_saved)
        )
        local skip_save = features and features.storage_key == "__SKIP__"
        local expanded_from_skip = features and features.expanded_from_skip
        return (auto_save and not skip_save and not expanded_from_skip) and _("Autosaved") or _("Save")
      end,
      id = "save_chat",
      callback = function()
        if self.save_callback then
          self.save_callback()
        else
          local Notification = require("ui/widget/notification")
          UIManager:show(Notification:new{
            text = _("Save function not available"),
            timeout = 2,
          })
        end
      end,
      hold_callback = self.default_hold_callback,
    },
    {
      text = _("Copy"),
      id = "copy_chat",
      callback = function()
        local history = self._message_history or self.original_history
        if not history then
          UIManager:show(Notification:new{
            text = _("No chat to copy"),
            timeout = 2,
          })
          return
        end

        local features = self.configuration and self.configuration.features or {}
        local content = features.copy_content or "full"
        local style = features.export_style or "markdown"

        -- Helper to perform the copy
        local function doCopy(selected_content)
          local Export = require("koassistant_export")
          local data = Export.fromHistory(history, self.original_highlighted_text)
          local text = Export.format(data, selected_content, style)

          Device.input.setClipboardText(text)
          UIManager:show(Notification:new{
            text = _("Copied"),
            timeout = 2,
          })
        end

        if content == "ask" then
          showContentPicker(_("Copy Content"), false, doCopy)
        else
          doCopy(content)
        end
      end,
      hold_callback = self.default_hold_callback,
    },
    {
      text = _("Note"),
      id = "save_to_note",
      enabled = self.selection_data ~= nil,
      callback = function()
        self:saveToNote()
      end,
      hold_callback = function()
        UIManager:show(Notification:new{
          text = _("Save response as note on highlighted text"),
          timeout = 2,
        })
      end,
    },
    {
      text = "#",
      id = "tag_chat",
      callback = function()
        if self.tag_callback then
          self.tag_callback()
        else
          UIManager:show(Notification:new{
            text = _("Tag function not available"),
            timeout = 2,
          })
        end
      end,
      hold_callback = function()
        UIManager:show(Notification:new{
          text = _("Add or manage tags for this chat"),
          timeout = 2,
        })
      end,
    },
  }

  local default_buttons = {
    first_row,
    -- Second row: Controls and toggles
    {
      {
        text_func = function()
          return self.render_markdown and "MD" or "Text"
        end,
        id = "toggle_markdown",
        callback = function()
          self:toggleMarkdown()
        end,
        hold_callback = function()
          UIManager:show(Notification:new{
            text = _("Toggle between markdown and plain text display"),
            timeout = 2,
          })
        end,
      },
      {
        text_func = function()
          return self.show_debug_in_chat and "Hide Debug" or "Show Debug"
        end,
        id = "toggle_debug",
        callback = function()
          self:toggleDebugMode()
        end,
        hold_callback = function()
          UIManager:show(Notification:new{
            text = _("Toggle debug display in chat viewer"),
            timeout = 2,
          })
        end,
      },
      {
        text_func = function()
          return self.hide_highlighted_text and _("Show Quote") or _("Hide Quote")
        end,
        id = "toggle_highlight",
        enabled_func = function()
          -- Only enable when there's highlighted text to show/hide
          return self.original_highlighted_text and self.original_highlighted_text ~= ""
        end,
        callback = function()
          self:toggleHighlightVisibility()
        end,
        hold_callback = function()
          UIManager:show(Notification:new{
            text = _("Toggle highlighted text display in chat"),
            timeout = 2,
          })
        end,
      },
      {
        text = _("Show Reasoning"),
        id = "view_reasoning",
        enabled_func = function()
          return self:hasReasoningContent()
        end,
        callback = function()
          self:showReasoningViewer()
        end,
        hold_callback = function()
          UIManager:show(Notification:new{
            text = _("View AI reasoning/thinking content (when available)"),
            timeout = 2,
          })
        end,
      },
      {
        text = "⇱",
        id = "top",
        callback = function()
          if self.render_markdown then
            -- If rendering in a ScrollHtmlWidget, use scrollToRatio
            self.scroll_text_w:scrollToRatio(0)
          else
            self.scroll_text_w:scrollToTop()
          end
        end,
        hold_callback = self.default_hold_callback,
        allow_hold_when_disabled = true,
      },
      {
        text = "⇲",
        id = "bottom",
        callback = function()
          if self.render_markdown then
            -- If rendering in a ScrollHtmlWidget, use scrollToRatio
            self.scroll_text_w:scrollToRatio(1)
          else
            self.scroll_text_w:scrollToBottom()
          end
        end,
        hold_callback = self.default_hold_callback,
        allow_hold_when_disabled = true,
      },
      {
        text = _("Close"),
        callback = function()
          self:onClose()
        end,
        hold_callback = self.default_hold_callback,
      },
    },
  }
  -- Use passed configuration, or load from disk as fallback
  -- This must happen BEFORE button table creation so text_func can use the values
  if not self.configuration then
    self.configuration = {}
    local ok, loaded_config = pcall(dofile, require("datastorage"):getSettingsDir() .. "/koassistant.koplugin/configuration.lua")
    if ok and loaded_config then
      self.configuration = loaded_config
    end
  end

  -- Use configuration setting if present, otherwise use instance setting
  if self.configuration.features and self.configuration.features.render_markdown ~= nil then
    self.render_markdown = self.configuration.features.render_markdown
  end
  if self.configuration.features and self.configuration.features.markdown_font_size then
    self.markdown_font_size = self.configuration.features.markdown_font_size
  end
  if self.configuration.features and self.configuration.features.text_align then
    self.text_align = self.configuration.features.text_align
  end
  if self.configuration.features and self.configuration.features.show_debug_in_chat ~= nil then
    self.show_debug_in_chat = self.configuration.features.show_debug_in_chat
  end

  -- Initialize hide_highlighted_text based on settings and text length
  -- This determines initial button state (Show Quote vs Hide Quote)
  -- Must happen BEFORE button table creation so text_func sees correct value
  if self.configuration.features then
    local highlight_text = self.original_highlighted_text or ""
    local threshold = self.configuration.features.long_highlight_threshold or 280
    self.hide_highlighted_text = self.configuration.features.hide_highlighted_text or
      (self.configuration.features.hide_long_highlights and string.len(highlight_text) > threshold)
    -- Compact view settings (used by dictionary bypass and popup actions)
    if self.configuration.features.compact_view then
      self.compact_view = true
    end
    if self.configuration.features.minimal_buttons then
      self.minimal_buttons = true
    end
    if self.configuration.features.translate_view then
      self.translate_view = true
    end
    if self.configuration.features.translate_hide_quote then
      self.translate_hide_quote = true
    end
  end

  -- Minimal buttons for compact dictionary view
  -- Row 1: MD/Text, Copy, Wiki, +Vocab
  -- Row 2: Expand, Lang, Ctx, Close
  local minimal_button_row1 = {}
  local minimal_button_row2 = {}

  -- Row 1: MD/Text toggle
  table.insert(minimal_button_row1, {
    text_func = function()
      return self.render_markdown and "MD" or "Text"
    end,
    id = "toggle_markdown",
    callback = function()
      self:toggleMarkdown()
    end,
    hold_callback = function()
      UIManager:show(Notification:new{
        text = _("Toggle between markdown and plain text display"),
        timeout = 2,
      })
    end,
  })

  -- Row 1: Copy button
  table.insert(minimal_button_row1, {
    text = _("Copy"),
    id = "copy_chat",
    callback = function()
      if self.export_callback then
        self.export_callback()
      else
        UIManager:show(Notification:new{
          text = _("Copy function not available"),
          timeout = 2,
        })
      end
    end,
    hold_callback = self.default_hold_callback,
  })

  -- Row 1: Wiki button
  table.insert(minimal_button_row1, {
    text = _("Wiki"),
    id = "lookup_wikipedia",
    callback = function()
      local word = self.original_highlighted_text
      if word and word ~= "" then
        local ReaderUI = require("apps/reader/readerui")
        local reader_ui = ReaderUI.instance
        if reader_ui and reader_ui.wikipedia then
          reader_ui.wikipedia:onLookupWikipedia(word, true, nil, false, nil)
        else
          UIManager:show(Notification:new{
            text = _("Wikipedia not available"),
            timeout = 2,
          })
        end
      else
        UIManager:show(Notification:new{
          text = _("No word to look up"),
          timeout = 2,
        })
      end
    end,
    hold_callback = function()
      UIManager:show(Notification:new{
        text = _("Look up word in Wikipedia"),
        timeout = 2,
      })
    end,
  })

  -- Row 1: Vocab builder button
  local vocab_auto_added = self.configuration and self.configuration.features and
    self.configuration.features.vocab_word_auto_added
  if vocab_auto_added or self._vocab_word_added then
    table.insert(minimal_button_row1, {
      text = _("Added"),
      id = "vocab_added",
      enabled = false,
      hold_callback = function()
        UIManager:show(Notification:new{
          text = _("Word added to vocabulary builder"),
          timeout = 2,
        })
      end,
    })
  else
    table.insert(minimal_button_row1, {
      text = _("+Vocab"),
      id = "vocab_add",
      callback = function()
        local word = self.original_highlighted_text
        if word and word ~= "" then
          local ReaderUI = require("apps/reader/readerui")
          local reader_ui = ReaderUI.instance
          if reader_ui then
            local book_title = (reader_ui.doc_props and reader_ui.doc_props.display_title) or _("AI Dictionary lookup")
            local Event = require("ui/event")
            reader_ui:handleEvent(Event:new("WordLookedUp", word, book_title, true))
            self._vocab_word_added = true
            UIManager:show(Notification:new{
              text = T(_("Added '%1' to vocabulary"), word),
              timeout = 2,
            })
            local button = self.button_table and self.button_table.button_by_id and self.button_table.button_by_id["vocab_add"]
            if button then
              button:setText(_("Added"), button.width)
              button:disable()
              UIManager:setDirty(self, function()
                return "ui", button.dimen
              end)
            end
          else
            UIManager:show(Notification:new{
              text = _("Vocabulary builder not available"),
              timeout = 2,
            })
          end
        end
      end,
      hold_callback = function()
        UIManager:show(Notification:new{
          text = _("Add word to vocabulary builder"),
          timeout = 2,
        })
      end,
    })
  end

  -- Row 2: Expand button
  table.insert(minimal_button_row2, {
    text = _("Expand"),
    id = "expand_view",
    callback = function()
      self:expandToFullView()
    end,
    hold_callback = function()
      UIManager:show(Notification:new{
        text = _("Open in full-size viewer with all options"),
        timeout = 2,
      })
    end,
  })

  -- Row 2: Language button (re-run with different dictionary language)
  local rerun_features = self.configuration and self.configuration.features
  local has_rerun = self.configuration and self.configuration._rerun_action
  table.insert(minimal_button_row2, {
    text = _("Lang"),
    id = "change_language",
    enabled = has_rerun and true or false,
    callback = function()
      if not has_rerun then return end
      local languages = rerun_features.user_languages
      if not languages or languages == "" then
        UIManager:show(Notification:new{
          text = _("Configure languages in Settings first"),
          timeout = 2,
        })
        return
      end
      -- Build language buttons
      local lang_dialog
      local lang_buttons = {}
      for lang in languages:gmatch("[^,]+") do
        lang = lang:match("^%s*(.-)%s*$")  -- trim
        table.insert(lang_buttons, {{
          text = lang,
          callback = function()
            UIManager:close(lang_dialog)
            -- Build new config copy with changed language
            -- Exclude _rerun_* keys (complex objects that can't be deep-copied)
            local new_config = {}
            for k, v in pairs(self.configuration) do
              if type(k) ~= "string" or not k:match("^_rerun_") then
                new_config[k] = v
              end
            end
            new_config.features = {}
            for k, v in pairs(self.configuration.features) do
              new_config.features[k] = v
            end
            new_config.features.dictionary_language = lang
            -- Close viewer and re-execute
            UIManager:close(self)
            local Dialogs = require("koassistant_dialogs")
            Dialogs.executeDirectAction(
              self.configuration._rerun_ui, self.configuration._rerun_action,
              self.original_highlighted_text, new_config, self.configuration._rerun_plugin
            )
          end,
        }})
      end
      table.insert(lang_buttons, {{
        text = _("Cancel"),
        callback = function() UIManager:close(lang_dialog) end,
      }})
      lang_dialog = ButtonDialog:new{
        title = _("Dictionary Language"),
        buttons = lang_buttons,
      }
      UIManager:show(lang_dialog)
    end,
    hold_callback = function()
      UIManager:show(Notification:new{
        text = _("Re-run with a different dictionary language"),
        timeout = 2,
      })
    end,
  })

  -- Row 2: Context toggle button (re-run with context ON/OFF)
  local has_context = rerun_features and
    rerun_features.dictionary_context_mode ~= "none" and
    rerun_features.dictionary_context and
    rerun_features.dictionary_context ~= ""
  table.insert(minimal_button_row2, {
    text = has_context and _("Ctx: ON") or _("Ctx: OFF"),
    id = "toggle_context",
    enabled = has_rerun and true or false,
    callback = function()
      if not has_rerun then return end
      -- Build new config copy with toggled context
      -- Exclude _rerun_* keys (complex objects that can't be deep-copied)
      local new_config = {}
      for k, v in pairs(self.configuration) do
        if type(k) ~= "string" or not k:match("^_rerun_") then
          new_config[k] = v
        end
      end
      new_config.features = {}
      for k, v in pairs(self.configuration.features) do
        new_config.features[k] = v
      end
      if has_context then
        -- Turn OFF: clear context
        new_config.features.dictionary_context_mode = "none"
        new_config.features.dictionary_context = ""
      else
        -- Turn ON: restore context mode (use user's setting or default to sentence)
        local user_mode = rerun_features._original_context_mode or "sentence"
        new_config.features.dictionary_context_mode = user_mode
        -- Use stored original context if available (selection is gone by now)
        if rerun_features._original_context and rerun_features._original_context ~= "" then
          new_config.features.dictionary_context = rerun_features._original_context
        else
          -- No stored context available, let extraction try again
          new_config.features.dictionary_context = nil
        end
      end
      -- Close viewer and re-execute
      UIManager:close(self)
      local Dialogs = require("koassistant_dialogs")
      Dialogs.executeDirectAction(
        self.configuration._rerun_ui, self.configuration._rerun_action,
        self.original_highlighted_text, new_config, self.configuration._rerun_plugin
      )
    end,
    hold_callback = function()
      UIManager:show(Notification:new{
        text = has_context and _("Re-run without surrounding context") or _("Re-run with surrounding context"),
        timeout = 2,
      })
    end,
  })

  -- Row 2: Close button
  table.insert(minimal_button_row2, {
    text = _("Close"),
    callback = function()
      self:onClose()
    end,
    hold_callback = self.default_hold_callback,
  })

  -- Translate view buttons (5 buttons in 2 rows)
  -- Row 1: MD/Text, Copy
  -- Row 2: Expand, Toggle Quote, Close
  local translate_button_row1 = {}
  local translate_button_row2 = {}

  -- Translate Row 1: MD/Text toggle
  table.insert(translate_button_row1, {
    text_func = function()
      return self.render_markdown and "MD" or "Text"
    end,
    id = "toggle_markdown",
    callback = function()
      self:toggleMarkdown()
    end,
    hold_callback = function()
      UIManager:show(Notification:new{
        text = _("Toggle between markdown and plain text display"),
        timeout = 2,
      })
    end,
  })

  -- Translate Row 1: Copy button
  table.insert(translate_button_row1, {
    text = _("Copy"),
    id = "copy_chat",
    callback = function()
      local history = self._message_history or self.original_history
      if not history then
        UIManager:show(Notification:new{
          text = _("No translation to copy"),
          timeout = 2,
        })
        return
      end

      local features = self.configuration and self.configuration.features or {}
      local content = features.translate_copy_content or "response"
      if content == "global" then
        content = features.copy_content or "full"
      end
      local style = features.export_style or "markdown"

      -- Helper to perform the copy
      local function doCopy(selected_content)
        local Export = require("koassistant_export")
        local data = Export.fromHistory(history, self.original_highlighted_text)
        local text = Export.format(data, selected_content, style)

        Device.input.setClipboardText(text)
        UIManager:show(Notification:new{
          text = _("Copied"),
          timeout = 2,
        })
      end

      if content == "ask" then
        showContentPicker(_("Copy Content"), true, doCopy)
      else
        doCopy(content)
      end
    end,
    hold_callback = self.default_hold_callback,
  })

  -- Translate Row 1: Note button (only if selection_data available)
  if self.selection_data then
    table.insert(translate_button_row1, {
      text = _("Note"),
      id = "save_to_note",
      callback = function()
        self:saveToNote()
      end,
      hold_callback = function()
        UIManager:show(Notification:new{
          text = _("Save translation as note on highlighted text"),
          timeout = 2,
        })
      end,
    })
  end

  -- Translate Row 2: Open full chat button
  table.insert(translate_button_row2, {
    text = _("→ Chat"),
    id = "expand_view",
    callback = function()
      self:expandToFullView()
    end,
    hold_callback = function()
      UIManager:show(Notification:new{
        text = _("Open full chat with all options"),
        timeout = 2,
      })
    end,
  })

  -- Translate Row 2: Toggle Quote button
  local has_original = self.original_highlighted_text and self.original_highlighted_text ~= ""
  table.insert(translate_button_row2, {
    text_func = function()
      return self.translate_hide_quote and _("Show Original") or _("Hide Original")
    end,
    id = "toggle_quote",
    enabled = has_original,
    callback = function()
      self:toggleTranslateQuoteVisibility()
    end,
    hold_callback = function()
      UIManager:show(Notification:new{
        text = self.translate_hide_quote and _("Show the original text") or _("Hide the original text"),
        timeout = 2,
      })
    end,
  })

  -- Translate Row 2: Close button
  table.insert(translate_button_row2, {
    text = _("Close"),
    callback = function()
      self:onClose()
    end,
    hold_callback = self.default_hold_callback,
  })

  local buttons = self.buttons_table or {}
  if self.add_default_buttons or not self.buttons_table then
    -- Use minimal buttons in minimal mode, translate buttons in translate mode, otherwise full default buttons
    if self.minimal_buttons then
      table.insert(buttons, minimal_button_row1)
      table.insert(buttons, minimal_button_row2)
    elseif self.translate_view then
      table.insert(buttons, translate_button_row1)
      table.insert(buttons, translate_button_row2)
    else
      -- Add both rows
      for _, row in ipairs(default_buttons) do
        table.insert(buttons, row)
      end
    end
  end
  self.button_table = ButtonTable:new {
    width = self.width - 2 * self.button_padding,
    buttons = buttons,
    zero_sep = true,
    show_parent = self,
  }

  -- Disable save button if auto-save is active for this chat:
  -- auto_save_all_chats, OR auto_save_chats + already saved once
  -- Skipped chats (storage_key = "__SKIP__") should always allow manual save
  -- Expanded-from-skip chats should also allow manual save initially
  local features = self.configuration and self.configuration.features
  local auto_save_active = features and (
    features.auto_save_all_chats or
    (features.auto_save_chats ~= false and features.chat_saved)
  )
  local skip_save = features and features.storage_key == "__SKIP__"
  local expanded_from_skip = features and features.expanded_from_skip
  if auto_save_active and not skip_save and not expanded_from_skip then
    local save_button = self.button_table:getButtonById("save_chat")
    if save_button then
      save_button:disable()
    end
  end

  local textw_height = self.height - titlebar:getHeight() - self.button_table:getSize().h

  if self.render_markdown then
    -- Convert Markdown to HTML and render in a ScrollHtmlWidget
    -- 1. Auto-linkify plain URLs, 2. Escape non-link brackets, 3. Convert tables
    local auto_linked = autoLinkUrls(self.text)
    local bracket_escaped = preprocessBrackets(auto_linked)
    local preprocessed_text = preprocessMarkdownTables(bracket_escaped)
    local html_body, err = MD(preprocessed_text, {})
    if err then
      logger.warn("ChatGPTViewer: could not generate HTML", err)
      -- Fallback to plain text if HTML generation fails
      html_body = "<pre>" .. (self.text or "Missing text.") .. "</pre>"
    end
    self.scroll_text_w = ScrollHtmlWidget:new {
      html_body = html_body,
      css = getViewerCSS(self.text_align),
      default_font_size = Screen:scaleBySize(self.markdown_font_size),
      width = self.width - 2 * self.text_padding - 2 * self.text_margin,
      height = textw_height - 2 * self.text_padding - 2 * self.text_margin,
      dialog = self,
      highlight_text_selection = true,
      html_link_tapped_callback = handleLinkTap,
    }
  else
    -- If not rendering Markdown, use the text as is
    self.scroll_text_w = ScrollTextWidget:new {
      text = self.text,
      face = self.text_face,
      fgcolor = self.fgcolor,
      width = self.width - 2 * self.text_padding - 2 * self.text_margin,
      height = textw_height - 2 * self.text_padding - 2 * self.text_margin,
      dialog = self,
      alignment = self.alignment,
      justified = self.justified,
      lang = self.lang,
      para_direction_rtl = self.para_direction_rtl,
      auto_para_direction = self.auto_para_direction,
      alignment_strict = self.alignment_strict,
      scroll_callback = self._buttons_scroll_callback,
      highlight_text_selection = true,
    }
  end
  self.textw = FrameContainer:new {
    padding = self.text_padding,
    margin = self.text_margin,
    bordersize = 0,
    self.scroll_text_w
  }

  self.frame = FrameContainer:new {
    radius = Size.radius.window,
    padding = 0,
    margin = 0,
    background = Blitbuffer.COLOR_WHITE,
    VerticalGroup:new {
      titlebar,
      CenterContainer:new {
        dimen = Geom:new {
          w = self.width,
          h = self.textw:getSize().h,
        },
        self.textw,
      },
      CenterContainer:new {
        dimen = Geom:new {
          w = self.width,
          h = self.button_table:getSize().h,
        },
        self.button_table,
      }
    }
  }
  self.movable = MovableContainer:new {
    -- We'll handle these events ourselves, and call appropriate
    -- MovableContainer's methods when we didn't process the event
    ignore_events = {
      -- These have effects over the text widget, and may
      -- or may not be processed by it
      "swipe", "hold", "hold_release", "hold_pan",
      -- These do not have direct effect over the text widget,
      -- but may happen while selecting text: we need to check
      -- a few things before forwarding them
      "touch", "pan", "pan_release",
    },
    self.frame,
  }
  self[1] = WidgetContainer:new {
    align = self.align,
    dimen = self.region,
    self.movable,
  }
end

function ChatGPTViewer:askAnotherQuestion()
  -- Store reference to current instance to use in callbacks
  local current_instance = self

  local input_dialog
  input_dialog = InputDialog:new {
    title = _("Reply"),
    input = self.reply_draft or "",  -- Restore saved draft
    input_type = "text",
    input_hint = _("Type your reply..."),
    input_height = 8,  -- Taller (was 6)
    allow_newline = true,
    input_multiline = true,
    text_height = 380,  -- Taller (was 300)
    width = UIConstants.DIALOG_WIDTH(),
    text_widget_width = UIConstants.DIALOG_WIDTH() - Screen:scaleBySize(50),  -- Dialog width minus padding
    text_widget_height = math.floor(Screen:getHeight() * 0.38),  -- Taller (was 0.3)
    buttons = {
      {
        {
          text = _("Close"),
          id = "close",  -- Enable tap-outside-to-close
          callback = function()
            -- Save draft before closing
            local draft = input_dialog:getInputText()
            if draft and draft ~= "" then
              current_instance.reply_draft = draft
            else
              current_instance.reply_draft = nil
            end
            UIManager:close(input_dialog)
          end,
        },
        {
          text = _("Send"),
          is_enter_default = true,
          callback = function()
            local input_text = input_dialog:getInputText()
            UIManager:close(input_dialog)

            -- Clear draft on send
            current_instance.reply_draft = nil

            if input_text and input_text ~= "" then
              -- Store reference to onAskQuestion before we potentially close this instance
              local onAskQuestionFn = current_instance.onAskQuestion

              -- Check if we have a valid callback
              if onAskQuestionFn then
                -- Properly pass self as first argument
                onAskQuestionFn(current_instance, input_text)
              end
            end
          end,
        },
      },
    },
  }
  UIManager:show(input_dialog)
  input_dialog:onShowKeyboard()
end

function ChatGPTViewer:onCloseWidget()
  UIManager:setDirty(nil, function()
    return "partial", self.frame.dimen
  end)
end

function ChatGPTViewer:onShow()
  UIManager:setDirty(self, function()
    return "partial", self.frame.dimen
  end)
  
  -- Schedule scroll to bottom if requested
  if self.scroll_to_bottom then
    UIManager:scheduleIn(0.1, function()
      if self.scroll_text_w then
        if self.render_markdown then
          self.scroll_text_w:scrollToRatio(1)
        else
          self.scroll_text_w:scrollToBottom()
        end
      end
    end)
  end
  
  return true
end

function ChatGPTViewer:onTapClose(arg, ges_ev)
  if ges_ev.pos:notIntersectWith(self.frame.dimen) then
    self:onClose()
  end
  return true
end

function ChatGPTViewer:onMultiSwipe(arg, ges_ev)
  -- For consistency with other fullscreen widgets where swipe south can't be
  -- used to close and where we then allow any multiswipe to close, allow any
  -- multiswipe to close this widget too.
  self:onClose()
  return true
end

function ChatGPTViewer:expandToFullView()
  -- Regenerate text from message history with prefixes (compact_view=false)
  -- This is needed because the original text was generated without prefixes
  local expanded_text = self.text
  local expanded_config = nil  -- Will hold config with compact_view=false
  if self._message_history and self.configuration then
    -- Create a config copy with compact_view=false to regenerate with prefixes
    expanded_config = {}
    for k, v in pairs(self.configuration) do
      if type(v) == "table" then
        expanded_config[k] = {}
        for k2, v2 in pairs(v) do
          expanded_config[k][k2] = v2
        end
      else
        expanded_config[k] = v
      end
    end
    -- Reset ALL compact-mode settings so expanded view works correctly
    if expanded_config.features then
      expanded_config.features.compact_view = false
      expanded_config.features.minimal_buttons = false
      expanded_config.features.translate_view = false
      expanded_config.features.translate_hide_quote = false
      expanded_config.features.hide_highlighted_text = false
      -- Reset streaming to use large dialog (user's default setting)
      -- This is critical for replies after expand to use the full streaming dialog
      expanded_config.features.large_stream_dialog = true
      -- Remove __SKIP__ storage_key so expanded chats become saveable
      -- Dictionary/translate chats with "Don't Save" can be saved after expanding
      if expanded_config.features.storage_key == "__SKIP__" then
        expanded_config.features.storage_key = nil
        -- Mark as expanded from skip so save button shows "Save" (not "Autosaved")
        -- until the user explicitly saves or a reply triggers auto-save
        expanded_config.features.expanded_from_skip = true
      end
      -- Enable debug display after expand (follows global setting)
      -- Compact view hides debug, but expanded view can show it
    end
    -- Regenerate text with prefixes
    expanded_text = self._message_history:createResultText(self.original_highlighted_text, expanded_config)
  end

  -- Collect current state
  -- Use expanded_config (with compact_view=false) so debug toggle and other features work correctly
  local config_for_full_view = expanded_config or self.configuration

  -- Get the message history - could be stored as _message_history or original_history
  local message_history = self._message_history or self.original_history

  local current_state = {
    text = expanded_text,  -- Use regenerated text with prefixes
    title = self.title,
    title_multilines = self.title_multilines,
    title_shrink_font_to_fit = self.title_shrink_font_to_fit,
    -- CRITICAL: Set BOTH property names for compatibility
    -- _message_history is used by expandToFullView for text regeneration
    -- original_history is used by toggleDebugDisplay, toggleHighlightVisibility, and other features
    _message_history = message_history,
    original_history = message_history,
    original_highlighted_text = self.original_highlighted_text,
    configuration = config_for_full_view,
    onAskQuestion = self.onAskQuestion,
    save_callback = self.save_callback,
    export_callback = self.export_callback,
    tag_callback = self.tag_callback,
    close_callback = self.close_callback,
    add_default_buttons = true,
    render_markdown = self.render_markdown,
    markdown_font_size = self.markdown_font_size,
    text_align = self.text_align,
    show_debug_in_chat = self.show_debug_in_chat,
    hide_highlighted_text = false,  -- Show highlighted text in full view
    _recreate_func = self._recreate_func,
    settings_callback = self.settings_callback,
    update_debug_callback = self.update_debug_callback,
    -- Explicitly disable compact mode
    compact_view = false,
    minimal_buttons = false,
  }

  -- Close current viewer
  UIManager:close(self)

  -- Schedule creation of full viewer to ensure proper cleanup
  UIManager:scheduleIn(0.1, function()
    -- Create close callback that properly clears global reference for THIS viewer
    local original_close_callback = current_state.close_callback
    current_state.close_callback = function()
      if _G.ActiveChatViewer then
        _G.ActiveChatViewer = nil
      end
      if original_close_callback then
        original_close_callback()
      end
    end

    local full_viewer = ChatGPTViewer:new(current_state)

    -- CRITICAL: Set global reference so reply callbacks can find this viewer
    -- Without this, updateViewer() checks fail and replies don't show
    _G.ActiveChatViewer = full_viewer
    UIManager:show(full_viewer)
  end)
end

function ChatGPTViewer:onClose()
  UIManager:close(self)
  if self.close_callback then
    self.close_callback()
  end
  return true
end

function ChatGPTViewer:onSwipe(arg, ges)
  if ges.pos:intersectWith(self.textw.dimen) then
    local direction = BD.flipDirectionIfMirroredUILayout(ges.direction)
    if direction == "west" then
      self.scroll_text_w:scrollText(1)
      return true
    elseif direction == "east" then
      self.scroll_text_w:scrollText(-1)
      return true
    else
      -- trigger a full-screen HQ flashing refresh
      UIManager:setDirty(nil, "full")
      -- a long diagonal swipe may also be used for taking a screenshot,
      -- so let it propagate
      return false
    end
  end
  -- Let our MovableContainer handle swipe outside of text
  return self.movable:onMovableSwipe(arg, ges)
end

-- The following handlers are similar to the ones in DictQuickLookup:
-- we just forward to our MoveableContainer the events that our
-- TextBoxWidget has not handled with text selection.
function ChatGPTViewer:onHoldStartText(_, ges)
  -- Forward Hold events not processed by TextBoxWidget event handler
  -- to our MovableContainer
  return self.movable:onMovableHold(_, ges)
end

function ChatGPTViewer:onHoldPanText(_, ges)
  -- Forward Hold events not processed by TextBoxWidget event handler
  -- to our MovableContainer
  -- We only forward it if we did forward the Touch
  if self.movable._touch_pre_pan_was_inside then
    return self.movable:onMovableHoldPan(arg, ges)
  end
end

function ChatGPTViewer:onHoldReleaseText(_, ges)
  -- Forward Hold events not processed by TextBoxWidget event handler
  -- to our MovableContainer
  return self.movable:onMovableHoldRelease(_, ges)
end

-- These 3 event processors are just used to forward these events
-- to our MovableContainer, under certain conditions, to avoid
-- unwanted moves of the window while we are selecting text in
-- the definition widget.
function ChatGPTViewer:onForwardingTouch(arg, ges)
  -- This Touch may be used as the Hold we don't get (for example,
  -- when we start our Hold on the bottom buttons)
  if not ges.pos:intersectWith(self.textw.dimen) then
    return self.movable:onMovableTouch(arg, ges)
  else
    -- Ensure this is unset, so we can use it to not forward HoldPan
    self.movable._touch_pre_pan_was_inside = false
  end
end

function ChatGPTViewer:onForwardingPan(arg, ges)
  -- We only forward it if we did forward the Touch or are currently moving
  if self.movable._touch_pre_pan_was_inside or self.movable._moving then
    return self.movable:onMovablePan(arg, ges)
  end
end

function ChatGPTViewer:onForwardingPanRelease(arg, ges)
  -- We can forward onMovablePanRelease() does enough checks
  return self.movable:onMovablePanRelease(arg, ges)
end

function ChatGPTViewer:handleTextSelection(text, hold_duration, start_idx, end_idx, to_source_index_func)
  if self.text_selection_callback then
    self.text_selection_callback(text, hold_duration, start_idx, end_idx, to_source_index_func)
    return
  end
  if Device:hasClipboard() then
    Device.input.setClipboardText(text)
    UIManager:show(Notification:new {
      text = _("Copied to clipboard."),
    })
  end
end

function ChatGPTViewer:update(new_text, scroll_to_bottom)
  self.text = new_text
  
  -- Default to true for backward compatibility
  if scroll_to_bottom == nil then
    scroll_to_bottom = true
  end
  
  if self.render_markdown then
    -- Convert Markdown to HTML and update the ScrollHtmlWidget
    -- 1. Auto-linkify plain URLs, 2. Escape non-link brackets, 3. Convert tables
    local auto_linked = autoLinkUrls(new_text)
    local bracket_escaped = preprocessBrackets(auto_linked)
    local preprocessed_text = preprocessMarkdownTables(bracket_escaped)
    local html_body, err = MD(preprocessed_text, {})
    if err then
      logger.warn("ChatGPTViewer: could not generate HTML", err)
      html_body = "<pre>" .. (new_text or "Missing text.") .. "</pre>"
    end

    -- Recreate the ScrollHtmlWidget with new content
    self.scroll_text_w = ScrollHtmlWidget:new {
      html_body = html_body,
      css = getViewerCSS(self.text_align),
      default_font_size = Screen:scaleBySize(self.markdown_font_size),
      width = self.width - 2 * self.text_padding - 2 * self.text_margin,
      height = self.textw:getSize().h - 2 * self.text_padding - 2 * self.text_margin,
      dialog = self,
      highlight_text_selection = true,
      html_link_tapped_callback = handleLinkTap,
    }
    
    -- Update the frame container with the new scroll widget
    self.textw:clear()
    self.textw[1] = self.scroll_text_w
    
    -- Only scroll to bottom if requested
    if scroll_to_bottom then
      UIManager:scheduleIn(0.1, function()
        if self.scroll_text_w then
          self.scroll_text_w:scrollToRatio(1)
        end
      end)
    end
  else
    -- For plain text, recreate the widget with new text
    self.scroll_text_w = ScrollTextWidget:new {
      text = new_text,
      face = self.text_face,
      fgcolor = self.fgcolor,
      width = self.width - 2 * self.text_padding - 2 * self.text_margin,
      height = self.textw:getSize().h - 2 * self.text_padding - 2 * self.text_margin,
      dialog = self,
      alignment = self.alignment,
      justified = self.justified,
      lang = self.lang,
      para_direction_rtl = self.para_direction_rtl,
      auto_para_direction = self.auto_para_direction,
      alignment_strict = self.alignment_strict,
      scroll_callback = self._buttons_scroll_callback,
      highlight_text_selection = true,
    }

    -- Update the frame container with the new scroll widget
    self.textw:clear()
    self.textw[1] = self.scroll_text_w
    
    -- Only scroll to bottom if requested
    if scroll_to_bottom then
      UIManager:scheduleIn(0.1, function()
        if self.scroll_text_w and type(self.scroll_text_w.scrollToBottom) == "function" then
          self.scroll_text_w:scrollToBottom()
        end
      end)
    end
  end
  
  UIManager:setDirty(self, function()
    return "ui", self.frame.dimen
  end)
end

-- Add method to update the title
function ChatGPTViewer:setTitle(new_title)
  self.title = new_title
  -- Update the titlebar title - need to find it first
  if self.movable and self.movable.vertical_group then
    local vg = self.movable.vertical_group
    for _, widget in ipairs(vg) do
      if widget.title_bar and widget.title_bar.setTitle then
        widget.title_bar:setTitle(new_title)
        UIManager:setDirty(self, function()
          return "ui", widget.title_bar.dimen
        end)
        break
      end
    end
  end
  -- Call update_title_callback if provided
  if self.update_title_callback then
    self.update_title_callback(self)
  end
end

function ChatGPTViewer:resetLayout()
  -- Implementation of resetLayout method
end

function ChatGPTViewer:toggleMarkdown()
  -- Toggle markdown rendering
  self.render_markdown = not self.render_markdown
  
  -- Update configuration
  if self.configuration.features then
    self.configuration.features.render_markdown = self.render_markdown
  end
  
  -- Save to settings if available
  if self.settings_callback then
    self.settings_callback("features.render_markdown", self.render_markdown)
  end
  
  -- Rebuild the scroll widget with new rendering mode
  local textw_height = self.textw:getSize().h
  
  if self.render_markdown then
    -- Convert to markdown
    -- 1. Auto-linkify plain URLs, 2. Escape non-link brackets, 3. Convert tables
    local auto_linked = autoLinkUrls(self.text)
    local bracket_escaped = preprocessBrackets(auto_linked)
    local preprocessed_text = preprocessMarkdownTables(bracket_escaped)
    local html_body, err = MD(preprocessed_text, {})
    if err then
      logger.warn("ChatGPTViewer: could not generate HTML", err)
      html_body = "<pre>" .. (self.text or "Missing text.") .. "</pre>"
    end
    self.scroll_text_w = ScrollHtmlWidget:new {
      html_body = html_body,
      css = getViewerCSS(self.text_align),
      default_font_size = Screen:scaleBySize(self.markdown_font_size),
      width = self.width - 2 * self.text_padding - 2 * self.text_margin,
      height = textw_height - 2 * self.text_padding - 2 * self.text_margin,
      dialog = self,
      highlight_text_selection = true,
      html_link_tapped_callback = handleLinkTap,
    }
  else
    -- Convert to plain text
    self.scroll_text_w = ScrollTextWidget:new {
      text = self.text,
      face = self.text_face,
      fgcolor = self.fgcolor,
      width = self.width - 2 * self.text_padding - 2 * self.text_margin,
      height = textw_height - 2 * self.text_padding - 2 * self.text_margin,
      dialog = self,
      alignment = self.alignment,
      justified = self.justified,
      lang = self.lang,
      para_direction_rtl = self.para_direction_rtl,
      auto_para_direction = self.auto_para_direction,
      alignment_strict = self.alignment_strict,
      scroll_callback = self._buttons_scroll_callback,
      highlight_text_selection = true,
    }
  end

  -- Update the frame container
  self.textw:clear()
  self.textw[1] = self.scroll_text_w
  
  -- Update button text
  local button = self.button_table:getButtonById("toggle_markdown")
  if button then
    button:setText(self.render_markdown and "MD" or "Text", button.width)
  end
  
  -- Refresh display
  UIManager:setDirty(self, function()
    return "ui", self.frame.dimen
  end)
end

function ChatGPTViewer:saveToNote()
  -- Save AI response as a note on the highlighted text
  if not self.selection_data then
    UIManager:show(Notification:new{
      text = _("No highlight selection data available"),
      timeout = 2,
    })
    return
  end

  -- Get ReaderUI instance
  local ReaderUI = require("apps/reader/readerui")
  local reader_ui = ReaderUI.instance
  if not reader_ui or not reader_ui.highlight then
    UIManager:show(Notification:new{
      text = _("No document open"),
      timeout = 2,
    })
    return
  end

  local history = self._message_history or self.original_history
  if not history then
    UIManager:show(Notification:new{
      text = _("No response to save"),
      timeout = 2,
    })
    return
  end

  -- Get note content based on settings
  local features = self.configuration and self.configuration.features or {}
  local content
  if self.translate_view then
    content = features.translate_note_content or "response"
    if content == "global" then
      content = features.note_content or "response"
    end
  else
    content = features.note_content or "response"
  end
  local style = features.export_style or "markdown"

  -- Helper to perform the save
  local function doSave(selected_content)
    local Export = require("koassistant_export")
    local data = Export.fromHistory(history, self.original_highlighted_text)
    local note_text = Export.format(data, selected_content, style)

    if note_text == "" then
      UIManager:show(Notification:new{
        text = _("No response to save"),
        timeout = 2,
      })
      return
    end

    -- Restore selected_text to ReaderHighlight so addNote() can create the highlight
    reader_ui.highlight.selected_text = self.selection_data

    -- Call addNote which creates the highlight and opens the note editor
    -- The note editor will be pre-filled with the formatted content
    reader_ui.highlight:addNote(note_text)
  end

  if content == "ask" then
    showContentPicker(_("Note Content"), self.translate_view, doSave)
  else
    doSave(content)
  end
end

function ChatGPTViewer:toggleTranslateQuoteVisibility()
  -- Toggle visibility of original text in translate view
  self.translate_hide_quote = not self.translate_hide_quote

  -- Update configuration
  if self.configuration.features then
    self.configuration.features.translate_hide_quote = self.translate_hide_quote
  end

  -- Rebuild the text using translate view formatting
  if self.original_history then
    self.text = self.original_history:createTranslateViewText(
      self.original_highlighted_text,
      self.translate_hide_quote
    )
  end

  -- Rebuild the scroll widget
  local textw_height = self.textw:getSize().h

  if self.render_markdown then
    local auto_linked = autoLinkUrls(self.text)
    local bracket_escaped = preprocessBrackets(auto_linked)
    local preprocessed_text = preprocessMarkdownTables(bracket_escaped)
    local html_body, err = MD(preprocessed_text, {})
    if err then
      logger.warn("ChatGPTViewer: could not generate HTML", err)
      html_body = "<pre>" .. (self.text or "Missing text.") .. "</pre>"
    end
    self.scroll_text_w = ScrollHtmlWidget:new {
      html_body = html_body,
      css = getViewerCSS(self.text_align),
      default_font_size = Screen:scaleBySize(self.markdown_font_size),
      width = self.scroll_text_w.width,
      height = self.scroll_text_w.height,
      dialog = self,
      highlight_text_selection = true,
      html_link_tapped_callback = handleLinkTap,
    }
  else
    self.scroll_text_w = ScrollTextWidget:new {
      text = self.text,
      face = self.text_face,
      fgcolor = self.fgcolor,
      width = self.scroll_text_w.width,
      height = self.scroll_text_w.height,
      dialog = self,
      alignment = self.alignment,
      justified = self.justified,
      lang = self.lang,
      para_direction_rtl = self.para_direction_rtl,
      auto_para_direction = self.auto_para_direction,
      alignment_strict = self.alignment_strict,
      highlight_text_selection = true,
    }
  end

  -- Update the frame container
  self.textw:clear()
  self.textw[1] = self.scroll_text_w

  -- Update button text
  local button = self.button_table:getButtonById("toggle_quote")
  if button then
    button:setText(self.translate_hide_quote and _("Show Original") or _("Hide Original"), button.width)
  end

  -- Refresh display
  UIManager:setDirty(self, function()
    return "ui", self.frame.dimen
  end)
end

function ChatGPTViewer:toggleDebugMode()
  -- Toggle debug display (not console logging - that's controlled separately in settings)
  self.show_debug_in_chat = not self.show_debug_in_chat

  -- Update configuration
  if self.configuration.features then
    self.configuration.features.show_debug_in_chat = self.show_debug_in_chat
  end

  -- Save display preference to settings
  if self.settings_callback then
    self.settings_callback("features.show_debug_in_chat", self.show_debug_in_chat)
  end

  -- If debug display was toggled and we have update_debug_callback, call it
  if self.update_debug_callback then
    self.update_debug_callback(self.show_debug_in_chat)
  end

  -- Rebuild the display with debug info shown/hidden
  if self.original_history then
    -- Create a temporary config with updated display setting
    local temp_config = {
      features = {
        show_debug_in_chat = self.show_debug_in_chat,
        debug_display_level = self.configuration.features and self.configuration.features.debug_display_level,
        hide_highlighted_text = self.configuration.features and self.configuration.features.hide_highlighted_text,
        hide_long_highlights = self.configuration.features and self.configuration.features.hide_long_highlights,
        long_highlight_threshold = self.configuration.features and self.configuration.features.long_highlight_threshold,
        is_file_browser_context = self.configuration.features and self.configuration.features.is_file_browser_context,
        is_book_context = self.configuration.features and self.configuration.features.is_book_context,
        is_multi_book_context = self.configuration.features and self.configuration.features.is_multi_book_context,
        selected_behavior = self.configuration.features and self.configuration.features.selected_behavior,
        selected_domain = self.configuration.features and self.configuration.features.selected_domain,
        show_reasoning_indicator = self.configuration.features and self.configuration.features.show_reasoning_indicator,
      },
      model = self.configuration.model,
      additional_parameters = self.configuration.additional_parameters,
      api_params = self.configuration.api_params,
      system = self.configuration.system,
    }

    -- Recreate the text with new display setting
    local new_text = self.original_history:createResultText(self.original_highlighted_text or "", temp_config)
    self:update(new_text, false)  -- false = don't scroll to bottom
  end

  -- Update button text
  local button = self.button_table:getButtonById("toggle_debug")
  if button then
    button:setText(self.show_debug_in_chat and "Hide Debug" or "Show Debug", button.width)
  end

  -- Show notification
  UIManager:show(Notification:new{
    text = self.show_debug_in_chat and _("Showing debug info") or _("Debug info hidden"),
    timeout = 2,
  })

  -- Refresh display
  UIManager:setDirty(self, function()
    return "ui", self.frame.dimen
  end)
end

-- Toggle highlighted text visibility (session-only, does not persist)
function ChatGPTViewer:toggleHighlightVisibility()
  self.hide_highlighted_text = not self.hide_highlighted_text

  -- Rebuild display with updated visibility
  if self.original_history then
    -- Create a temporary config with updated display setting
    local temp_config = {
      features = {
        show_debug_in_chat = self.show_debug_in_chat,
        debug_display_level = self.configuration.features and self.configuration.features.debug_display_level,
        hide_highlighted_text = self.hide_highlighted_text,  -- Use toggled value
        hide_long_highlights = false,  -- Disable auto-hide when manually toggling
        long_highlight_threshold = self.configuration.features and self.configuration.features.long_highlight_threshold,
        is_file_browser_context = self.configuration.features and self.configuration.features.is_file_browser_context,
        is_book_context = self.configuration.features and self.configuration.features.is_book_context,
        is_multi_book_context = self.configuration.features and self.configuration.features.is_multi_book_context,
        selected_behavior = self.configuration.features and self.configuration.features.selected_behavior,
        selected_domain = self.configuration.features and self.configuration.features.selected_domain,
        show_reasoning_indicator = self.configuration.features and self.configuration.features.show_reasoning_indicator,
      },
      model = self.configuration.model,
      additional_parameters = self.configuration.additional_parameters,
      api_params = self.configuration.api_params,
      system = self.configuration.system,
    }

    -- Recreate the text with new display setting
    local new_text = self.original_history:createResultText(self.original_highlighted_text or "", temp_config)
    self:update(new_text, false)  -- false = don't scroll to bottom
  end

  -- Update button text
  local button = self.button_table:getButtonById("toggle_highlight")
  if button then
    button:setText(self.hide_highlighted_text and _("Show Quote") or _("Hide Quote"), button.width)
  end

  -- Show notification
  UIManager:show(Notification:new{
    text = self.hide_highlighted_text and _("Quote hidden") or _("Quote shown"),
    timeout = 2,
  })

  -- Refresh display
  UIManager:setDirty(self, function()
    return "ui", self.frame.dimen
  end)
end

-- Check if there's any reasoning content available to view
function ChatGPTViewer:hasReasoningContent()
  if not self.original_history then
    return false
  end

  local entries = self.original_history:getReasoningEntries()
  return entries and #entries > 0
end

-- Show reasoning content in a viewer
function ChatGPTViewer:showReasoningViewer()
  if not self.original_history then
    UIManager:show(Notification:new{
      text = _("No conversation history available"),
      timeout = 2,
    })
    return
  end

  local entries = self.original_history:getReasoningEntries()
  if not entries or #entries == 0 then
    UIManager:show(Notification:new{
      text = _("No reasoning content available"),
      timeout = 2,
    })
    return
  end

  -- Build the content to display
  local content_parts = {}
  local has_viewable_content = false

  for idx, entry in ipairs(entries) do
    table.insert(content_parts, string.format("--- Response #%d ---\n", entry.msg_num))

    if entry.requested_only then
      -- OpenAI: reasoning was requested but not exposed
      local effort = entry.effort and (" (" .. entry.effort .. ")") or ""
      table.insert(content_parts, string.format("Reasoning was requested%s but OpenAI does not expose reasoning content.\n", effort))
    elseif entry.has_content then
      -- Full reasoning content available
      table.insert(content_parts, entry.reasoning .. "\n")
      has_viewable_content = true
    else
      -- Legacy: reasoning was detected but content not captured (old streaming format)
      table.insert(content_parts, "Reasoning/thinking was used but content was not captured.\n(This message is from an older chat - new chats capture reasoning content)\n")
    end

    table.insert(content_parts, "\n")
  end

  local title = has_viewable_content and _("AI Reasoning") or _("Reasoning Status")

  local viewer = TextViewer:new{
    title = title,
    text = table.concat(content_parts),
    width = self.width,
    height = self.height,
  }

  UIManager:show(viewer)
end

-- Internal function to handle rotation/resize recreation
-- Called by both onSetRotationMode and onScreenResize
function ChatGPTViewer:_handleScreenChange()
  if not self._recreate_func then
    return false
  end

  -- Prevent double recreation if both events fire
  if self._recreating then
    return true
  end
  self._recreating = true

  -- Capture current state before closing
  local state = self:captureState()

  -- Close current viewer
  UIManager:close(self)
  if _G.ActiveChatViewer == self then
    _G.ActiveChatViewer = nil
  end

  -- Schedule recreation with enough delay for screen dimensions to update
  -- Use 0.2s to ensure Screen:getWidth()/getHeight() return new values
  UIManager:scheduleIn(0.2, function()
    self._recreate_func(state)
  end)

  return true
end

-- Handle screen rotation by recreating the viewer with new dimensions
-- This preserves state (text, scroll position, settings) across rotation
function ChatGPTViewer:onSetRotationMode(rotation)
  return self:_handleScreenChange()
end

-- Alternative handler for screen resize events (some KOReader builds use this)
function ChatGPTViewer:onScreenResize(dimen)
  return self:_handleScreenChange()
end

-- Capture current viewer state for restoration after recreation
function ChatGPTViewer:captureState()
  local scroll_ratio = 0
  if self.scroll_text_w then
    -- Try to get current scroll position as ratio (0-1)
    if self.scroll_text_w.getScrolledRatio then
      scroll_ratio = self.scroll_text_w:getScrolledRatio()
    elseif self.scroll_text_w.getScrollPercent then
      scroll_ratio = self.scroll_text_w:getScrollPercent() / 100
    end
  end

  return {
    title = self.title,
    text = self.text,
    render_markdown = self.render_markdown,
    show_debug_in_chat = self.show_debug_in_chat,
    scroll_ratio = scroll_ratio,
    configuration = self.configuration,
    original_history = self.original_history,
    original_highlighted_text = self.original_highlighted_text,
    reply_draft = self.reply_draft,
    -- Callbacks (will be re-bound by recreate function)
    onAskQuestion = self.onAskQuestion,
    save_callback = self.save_callback,
    export_callback = self.export_callback,
    tag_callback = self.tag_callback,
    close_callback = self.close_callback,
    settings_callback = self.settings_callback,
    update_debug_callback = self.update_debug_callback,
  }
end

-- Restore scroll position after recreation
function ChatGPTViewer:restoreScrollPosition(scroll_ratio)
  if not self.scroll_text_w or not scroll_ratio or scroll_ratio == 0 then
    return
  end

  -- Schedule scroll restoration after widget is fully rendered
  UIManager:scheduleIn(0.2, function()
    if self.scroll_text_w then
      if self.scroll_text_w.scrollToRatio then
        self.scroll_text_w:scrollToRatio(scroll_ratio)
      elseif self.scroll_text_w.scrollToPercent then
        self.scroll_text_w:scrollToPercent(scroll_ratio * 100)
      end
      UIManager:setDirty(self, "ui")
    end
  end)
end

-- Helper to get display name for text alignment
local function getAlignmentDisplayName(align)
  if align == "justify" then return _("Justified")
  elseif align == "right" then return _("Right (RTL)")
  else return _("Left")
  end
end

-- Show viewer settings dialog (font size, text alignment)
function ChatGPTViewer:showViewerSettings()
  local dialog
  dialog = ButtonDialog:new{
    title = _("Chat Viewer Settings"),
    buttons = {
      {
        {
          text = _("Font Size") .. ": " .. self.markdown_font_size,
          callback = function()
            UIManager:close(dialog)
            self:showFontSizeSpinner()
          end,
        },
      },
      {
        {
          text = _("Alignment") .. ": " .. getAlignmentDisplayName(self.text_align),
          callback = function()
            -- Cycle: left -> justify -> right -> left
            local order = {"left", "justify", "right"}
            local current = self.text_align or "justify"
            local idx = 1
            for i, v in ipairs(order) do
              if v == current then idx = i; break end
            end
            local next_align = order[(idx % #order) + 1]
            self.text_align = next_align
            if self.configuration and self.configuration.features then
              self.configuration.features.text_align = next_align
            end
            if self.settings_callback then
              self.settings_callback("features.text_align", next_align)
            end
            self:refreshMarkdownDisplay()
            UIManager:show(Notification:new{
              text = T(_("Alignment: %1"), getAlignmentDisplayName(next_align)),
              timeout = 2,
            })
            -- Reopen settings to show updated label
            UIManager:close(dialog)
            self:showViewerSettings()
          end,
        },
      },
      {
        {
          text = _("Reset to Defaults"),
          callback = function()
            UIManager:close(dialog)
            self:resetViewerSettings()
          end,
        },
      },
      {
        {
          text = _("Close"),
          callback = function()
            UIManager:close(dialog)
          end,
        },
      },
    },
  }
  UIManager:show(dialog)
end

-- Show font size spinner
function ChatGPTViewer:showFontSizeSpinner()
  local spin_widget = SpinWidget:new{
    title_text = _("Font Size"),
    value = self.markdown_font_size,
    value_min = 12,
    value_max = 32,
    value_step = 1,
    default_value = 20,
    ok_text = _("Set"),
    callback = function(spin)
      self.markdown_font_size = spin.value

      -- Save to configuration and persist
      if self.configuration.features then
        self.configuration.features.markdown_font_size = spin.value
      end
      if self.settings_callback then
        self.settings_callback("features.markdown_font_size", spin.value)
      end

      -- Refresh display
      self:refreshMarkdownDisplay()

      UIManager:show(Notification:new{
        text = T(_("Font size set to %1"), spin.value),
        timeout = 2,
      })
    end,
  }
  UIManager:show(spin_widget)
end

-- Reset viewer settings to defaults
function ChatGPTViewer:resetViewerSettings()
  self.markdown_font_size = 20
  self.text_align = "justify"

  -- Save to configuration and persist
  if self.configuration.features then
    self.configuration.features.markdown_font_size = 20
    self.configuration.features.text_align = "justify"
  end
  if self.settings_callback then
    self.settings_callback("features.markdown_font_size", 20)
    self.settings_callback("features.text_align", "justify")
  end

  -- Refresh display
  self:refreshMarkdownDisplay()

  UIManager:show(Notification:new{
    text = _("Settings reset to defaults"),
    timeout = 2,
  })
end

-- Refresh the markdown display after settings change
function ChatGPTViewer:refreshMarkdownDisplay()
  if not self.render_markdown then
    return
  end

  -- Re-convert markdown with new settings and update display
  -- 1. Auto-linkify plain URLs, 2. Escape non-link brackets, 3. Convert tables
  local auto_linked = autoLinkUrls(self.text)
  local bracket_escaped = preprocessBrackets(auto_linked)
  local preprocessed_text = preprocessMarkdownTables(bracket_escaped)
  local html_body, err = MD(preprocessed_text, {})
  if err then
    logger.warn("ChatGPTViewer: could not generate HTML", err)
    html_body = "<pre>" .. (self.text or "Missing text.") .. "</pre>"
  end

  -- Calculate current height
  local textw_height = self.textw:getSize().h

  -- Create new scroll widget with updated settings
  self.scroll_text_w = ScrollHtmlWidget:new {
    html_body = html_body,
    css = getViewerCSS(self.text_align),
    default_font_size = Screen:scaleBySize(self.markdown_font_size),
    width = self.width - 2 * self.text_padding - 2 * self.text_margin,
    height = textw_height - 2 * self.text_padding - 2 * self.text_margin,
    dialog = self,
    highlight_text_selection = true,
    html_link_tapped_callback = handleLinkTap,
  }

  -- Update the frame container
  self.textw:clear()
  self.textw[1] = self.scroll_text_w

  -- Refresh display
  UIManager:setDirty(self, function()
    return "ui", self.frame.dimen
  end)
end

return ChatGPTViewer
