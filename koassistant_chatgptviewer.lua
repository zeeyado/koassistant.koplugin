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
local Languages = require("koassistant_languages")
local Constants = require("koassistant_constants")

-- Strip markdown syntax for text mode (preserves readability without formatting)
-- Used when render_markdown is false - converts markdown to plain text with visual hints
-- Uses universal symbols that work for ALL scripts (Arabic, CJK, etc.)
-- Uses PTF (Poor Text Formatting) for bold text - TextBoxWidget renders these as actual bold
local function stripMarkdown(text, is_rtl)
    if not text then return "" end

    -- PTF (Poor Text Formatting) markers - TextBoxWidget interprets these as bold
    -- See frontend/ui/widget/textboxwidget.lua in KOReader
    local PTF_HEADER = "\u{FFF1}"      -- Put at start to signal PTF is in use
    local PTF_BOLD_START = "\u{FFF2}"  -- Start a bold sequence
    local PTF_BOLD_END = "\u{FFF3}"    -- End a bold sequence

    -- Directional marker for BiDi text (RTL headwords followed by LTR IPA/definitions)
    -- In RTL mode, skip LRM to let para_direction_rtl control paragraph direction
    local LRM = is_rtl and "" or "\u{200E}"  -- Left-to-Right Mark - resets direction after RTL text

    local result = text

    -- Code blocks FIRST (before other transformations can affect content inside)
    -- ```lang\ncode\n``` → indented with 4 spaces
    result = result:gsub("```[^\n]*\n(.-)```", function(code)
        -- Indent each line
        local indented = code:gsub("([^\n]+)", "    %1")
        return "\n" .. indented
    end)

    -- Inline code: `code` → 'code'
    result = result:gsub("`([^`]+)`", "'%1'")

    -- Tables: Remove separator rows (|---|---|), keep header and data rows
    -- Separator rows contain only |, -, :, and whitespace
    result = result:gsub("\n%s*|[%s%-:]+|[%s%-:|]*\n", "\n")

    -- Headers: Hierarchical symbols (shifted from Wikipedia-style, removing heavy full block)
    -- Header text is bolded using PTF markers for emphasis
    local header_symbols = {
        "▉",   -- H1: Seven Eighths Block (U+2589)
        "◤",   -- H2: Black Upper Left Triangle (U+25E4)
        "◆",   -- H3: Black Diamond (U+25C6)
        "✿",   -- H4: Black Florette (U+273F)
        "❖",   -- H5: Black Diamond Minus White X (U+2756)
        "·",   -- H6: Middle Dot (U+00B7)
    }
    local lines = {}
    for line in result:gmatch("([^\n]*)\n?") do
        local hashes, content = line:match("^(#+)%s*(.-)%s*$")
        if hashes and content and #content > 0 then
            local level = math.min(#hashes, 6)
            local symbol = header_symbols[level]
            -- Bold the header text for emphasis
            local bold_content = PTF_BOLD_START .. content .. PTF_BOLD_END
            -- H3+ get slight indent for hierarchy
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

    -- Emphasis: Convert to PTF bold markers (TextBoxWidget renders these as actual bold!)
    -- Order matters: bold-italic first, then bold, then italic
    -- Italic becomes plain text (no italic support in PTF)

    -- Bold-italic: ***text*** or ___text___ → bold text (no italic in PTF)
    -- LRM after bold helps with RTL headwords followed by LTR content (IPA, definitions)
    result = result:gsub("%*%*%*(.-)%*%*%*", PTF_BOLD_START .. "%1" .. PTF_BOLD_END .. LRM)
    result = result:gsub("___(.-)___", PTF_BOLD_START .. "%1" .. PTF_BOLD_END .. LRM)

    -- Bold: **text** or __text__ → bold text
    result = result:gsub("%*%*(.-)%*%*", PTF_BOLD_START .. "%1" .. PTF_BOLD_END .. LRM)
    result = result:gsub("__(.-)__", PTF_BOLD_START .. "%1" .. PTF_BOLD_END .. LRM)

    -- Italic handling:
    -- *italic* with asterisks → kept as-is (visual hint for prose italics)
    -- _italic_ with underscores → bold (used for part of speech in dictionary entries)
    -- Must use word boundary patterns to avoid matching mid-word underscores (like variable_name)
    result = result:gsub("(%s)_([^_\n]+)_([%s%p])", "%1" .. PTF_BOLD_START .. "%2" .. PTF_BOLD_END .. "%3")
    result = result:gsub("(%s)_([^_\n]+)_$", "%1" .. PTF_BOLD_START .. "%2" .. PTF_BOLD_END)
    result = result:gsub("^_([^_\n]+)_([%s%p])", PTF_BOLD_START .. "%1" .. PTF_BOLD_END .. "%2")
    result = result:gsub("^_([^_\n]+)_$", PTF_BOLD_START .. "%1" .. PTF_BOLD_END)

    -- Blockquotes: > text → │ text (box drawing character)
    result = result:gsub("\n>%s*", "\n│ ")
    result = result:gsub("^>%s*", "│ ")

    -- Unordered lists: - item or * item → • item
    result = result:gsub("\n[%-]%s+", "\n• ")
    result = result:gsub("^[%-]%s+", "• ")
    -- For * lists, only at start of line (not mid-line asterisks)
    result = result:gsub("\n%*%s+", "\n• ")

    -- Horizontal rules: --- or *** or ___ → line (15 chars, subtle separator)
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

    -- BiDi fix: Prepend LRM to lines containing RTL characters to establish LTR base direction
    -- Without this, lines starting with RTL text get RTL paragraph direction, reversing everything
    -- Skip in RTL mode: para_direction_rtl already sets the correct base direction
    if not is_rtl then
        -- Add LRM only to truly mixed RTL+Latin lines
        -- Pure RTL lines (even with numbers/punctuation) should align right naturally
        local rtl_pattern = "[\216-\219][\128-\191]"
        local latin_pattern = "[a-zA-Z]"  -- Latin letters indicate mixed content needing LTR base
        local header_pattern = "^%s*[▉◤◆✿❖·]"  -- Header symbols from header processing above
        local fixed_lines = {}
        for line in result:gmatch("([^\n]*)\n?") do
            -- Add LRM only to mixed RTL+Latin lines (not headers, not pure RTL)
            if line:match(rtl_pattern) and line:match(latin_pattern) and not line:match(header_pattern) then
                table.insert(fixed_lines, LRM .. line)
            else
                table.insert(fixed_lines, line)
            end
        end
        result = table.concat(fixed_lines, "\n")
    end

    -- Add PTF header at start to signal TextBoxWidget to interpret PTF markers
    return PTF_HEADER .. result
end

-- Fix BiDi issues in dictionary RTL compact view
-- In RTL paragraphs, LTR content displays left-to-right internally, so the
-- last element of an LTR sequence sits at the right edge (read first in RTL).
-- For Latin headwords followed by IPA, this puts IPA rightmost (wrong).
-- Fix: swap IPA before headword in logical order so headword ends up rightmost.
local function fixIPABidi(text)
    if not text then return text end
    local LRM = "\226\128\142"            -- U+200E Left-to-Right Mark
    local PTF_BOLD_START = "\239\191\178" -- U+FFF2 in UTF-8
    local PTF_BOLD_END = "\239\191\179"   -- U+FFF3 in UTF-8
    -- For Latin headwords: swap IPA before headword in logical order
    -- so headword appears rightmost (read first) in RTL paragraph
    text = text:gsub(
        PTF_BOLD_START .. "(.-)" .. PTF_BOLD_END .. " (/[^/\n]+/)",
        function(bold_content, ipa)
            if bold_content:match("[a-zA-Z]") then
                return ipa .. " " .. PTF_BOLD_START .. bold_content .. PTF_BOLD_END
            end
            return PTF_BOLD_START .. bold_content .. PTF_BOLD_END .. " " .. ipa
        end
    )
    -- Wrap IPA in LRM to anchor slashes correctly (don't touch surrounding spaces)
    text = text:gsub("(/[^/\n]+/)", LRM .. "%1" .. LRM)
    return text
end

-- UTF-8 pattern for Arabic script detection (U+0600-U+06FF = bytes 216-219)
local RTL_PATTERN = "[\216-\219][\128-\191]"
local LATIN_PATTERN = "[a-zA-Z]"

-- Check if text has dominant RTL content (for general chat auto-detection)
-- Returns true only if RTL characters outnumber Latin characters
-- This prevents switching for English text that merely references e.g. Arabic
-- Optional sample_size limits scanning to first N characters (for large content)
local function hasDominantRTL(text, sample_size)
    if not text or text == "" then return false end
    local check_text = sample_size and text:sub(1, sample_size) or text
    local rtl_count = 0
    for _ in check_text:gmatch(RTL_PATTERN) do
        rtl_count = rtl_count + 1
    end
    if rtl_count == 0 then return false end
    local latin_count = 0
    for _ in check_text:gmatch(LATIN_PATTERN) do
        latin_count = latin_count + 1
    end
    return rtl_count > latin_count
end

-- Get the latest assistant response from message history (excludes user input/context)
local function getLatestResponse(message_history)
    if not message_history or not message_history.messages then return "" end
    -- Iterate backwards to find the last assistant message
    for i = #message_history.messages, 1, -1 do
        local msg = message_history.messages[i]
        if msg.role == "assistant" and msg.content then
            return msg.content
        end
    end
    return ""
end

-- Post-process HTML for RTL support in markdown view
-- Uses inline CSS text-align since MuPDF doesn't support dir attribute
local function addHtmlBidiAttributes(html, options)
    if not html then return html end
    options = options or {}
    -- When true, use startsWithRTL for paragraphs (for RTL dictionary language)
    local use_starts_with_rtl = options.use_starts_with_rtl or false

    -- Normalize HTML: collapse whitespace between tags for easier pattern matching
    local normalized = html:gsub(">%s+<", "><")

    local rtl_pattern = "[\216-\219][\128-\191]"
    local latin_pattern = "[a-zA-Z]"

    -- Unicode directional marks for BiDi control
    local RLM = "\226\128\143"  -- U+200F Right-to-Left Mark
    local RLI = "\226\129\167"  -- U+2067 Right-to-Left Isolate
    local PDI = "\226\129\169"  -- U+2069 Pop Directional Isolate

    -- Strip HTML tags to get text content for language detection
    local function stripTags(s)
        return s:gsub("<[^>]+>", "")
    end

    -- Check if text is pure RTL (has RTL, no Latin)
    local function isPureRTL(s)
        local text = stripTags(s)
        return text:match(rtl_pattern) and not text:match(latin_pattern)
    end

    -- Check if text starts with RTL (for bullet list handling)
    local function startsWithRTL(s)
        local text = stripTags(s):gsub("^%s+", "")  -- Strip tags and leading whitespace
        return text:match("^" .. rtl_pattern) ~= nil
    end

    -- Apply BiDi formatting to pure RTL content
    local function formatRTLContent(content, addStyle)
        -- Add RLM before trailing period for correct visual placement
        local fixed = content:gsub("%.(%s*)$", RLM .. ".%1")
        -- Also handle period before closing tags
        fixed = fixed:gsub("(%.)(%s*</[^>]+>%s*)$", RLM .. "%1%2")
        if addStyle then
            return string.format('<p style="text-align: right;">%s%s</p>', RLM, fixed)
        else
            return RLM .. fixed
        end
    end

    -- Convert ordered lists to paragraphs with per-item RTL detection
    -- MuPDF doesn't support RTL list markers, so we convert to paragraphs
    -- Uses Western numerals consistently (matches text view behavior)
    normalized = normalized:gsub("<ol>(.-)</ol>", function(list_content)
        local items = {}
        local num = 1
        for item_content in list_content:gmatch("<li>(.-)</li>") do
            local item_text = stripTags(item_content)
            local item_has_rtl = item_text:match(rtl_pattern)
            local item_has_latin = item_text:match(latin_pattern)

            if item_has_rtl and not item_has_latin then
                -- Pure RTL item → RLM establishes RTL base direction, number goes on right
                table.insert(items, string.format(
                    '<p style="text-align: right;">%s%d. %s</p>',
                    RLM, num, item_content
                ))
            else
                -- LTR or mixed item → number on left
                table.insert(items, string.format('<p>%d. %s</p>', num, item_content))
            end
            num = num + 1
        end
        return table.concat(items, "")
    end)

    -- Convert unordered lists to paragraphs with per-item RTL detection
    -- For bullets: RTL if text STARTS with RTL (matches text view behavior)
    normalized = normalized:gsub("<ul>(.-)</ul>", function(list_content)
        local items = {}
        for item_content in list_content:gmatch("<li>(.-)</li>") do
            if startsWithRTL(item_content) then
                -- Starts with RTL → use BiDi isolate to maintain proper content ordering
                -- RLI isolates the content in RTL context, bullet outside isolate goes to visual right
                table.insert(items, string.format(
                    '<p style="text-align: right;">%s• %s%s</p>',
                    RLI, item_content, PDI
                ))
            else
                -- Starts with LTR → bullet on left
                table.insert(items, string.format('<p>• %s</p>', item_content))
            end
        end
        return table.concat(items, "")
    end)

    -- Continue processing with normalized HTML
    html = normalized

    -- Process block-level elements: li, h1-h6 (paragraphs handled earlier)
    -- Pattern captures: opening tag, content, closing tag
    local function processBidiElement(tag_open, content, tag_close)
        if isPureRTL(content) then
            -- Pure RTL content → apply BiDi formatting
            local fixed = formatRTLContent(content, false)  -- false = don't wrap in <p>
            return tag_open:gsub(">$", ' style="text-align: right;">') .. fixed .. tag_close
        else
            -- LTR or mixed content → leave as-is (default left alignment works)
            return tag_open .. content .. tag_close
        end
    end

    -- Handle "fake" bullet lists: paragraphs with • at start of lines (AI often generates these)
    -- Also apply BiDi formatting to ALL paragraphs here (including non-bullet)
    html = html:gsub("<p>(.-)</p>", function(content)
        -- Check if this looks like a bullet list (multiple lines starting with •)
        if content:match("\n") and content:match("^•") then
            local items = {}
            for line in content:gmatch("[^\n]+") do
                if line:match("^•") then
                    -- Remove leading bullet and space
                    local item_text = line:gsub("^•%s*", "")
                    if item_text ~= "" then
                        -- For bullets: RTL if text STARTS with RTL (matches text view)
                        if startsWithRTL(item_text) then
                            -- Use BiDi isolate for proper content ordering
                            table.insert(items, string.format(
                                '<p style="text-align: right;">%s• %s%s</p>',
                                RLI, item_text, PDI
                            ))
                        else
                            -- Starts with LTR → bullet on left
                            table.insert(items, string.format('<p>• %s</p>', item_text))
                        end
                    end
                else
                    -- Non-bullet line - apply BiDi formatting based on RTL detection mode
                    if line ~= "" then
                        local line_is_rtl = use_starts_with_rtl and startsWithRTL(line) or isPureRTL(line)
                        if line_is_rtl then
                            table.insert(items, formatRTLContent(line, true))
                        else
                            table.insert(items, "<p>" .. line .. "</p>")
                        end
                    end
                end
            end
            return table.concat(items, "")
        end
        -- Not a bullet list - apply BiDi formatting based on RTL detection mode
        -- use_starts_with_rtl: for dictionary popup with RTL language, align if STARTS with RTL
        -- default: only align if PURE RTL (no Latin characters)
        local is_rtl = use_starts_with_rtl and startsWithRTL(content) or isPureRTL(content)
        if is_rtl then
            return formatRTLContent(content, true)
        end
        return "<p>" .. content .. "</p>"
    end)

    -- Note: Paragraphs are now fully handled above (bullet and non-bullet)
    -- No additional paragraph processing needed

    -- Process list items (for remaining non-RTL lists)
    html = html:gsub("(<li>)(.-)(</li>)", processBidiElement)

    -- Process headers h1-h6
    for i = 1, 6 do
        local open_tag = "<h" .. i .. ">"
        local close_tag = "</h" .. i .. ">"
        html = html:gsub("(" .. open_tag .. ")(.-)" .. close_tag, function(tag_open, content)
            return processBidiElement(tag_open, content, close_tag)
        end)
    end

    return html
end

-- Show link options dialog
-- Delegates to KOReader's ReaderLink when available (gets all registered plugin
-- buttons like Wallabag, Wikipedia, etc.), falls back to basic dialog otherwise.
local link_dialog  -- Forward declaration for closures
local function showLinkDialog(link_url)
    if not link_url then return end

    -- When a book is open, delegate to ReaderLink's external link dialog.
    -- This gives us all registered plugin buttons (Wallabag, Wikipedia, etc.)
    local ReaderUI = require("apps/reader/readerui")
    local reader_ui = ReaderUI.instance
    if reader_ui and reader_ui.link then
        reader_ui.link:onGoToExternalLink(link_url)
        return
    end

    -- Fallback: basic dialog when no book is open (file browser, general chat)
    local QRMessage = require("ui/widget/qrmessage")

    local buttons = {}

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

    -- Add Wallabag if the plugin is loaded (works from file browser too)
    local row2 = {}
    local FileManager = require("apps/filemanager/filemanager")
    local fm = FileManager.instance
    if fm and fm.wallabag then
        local Event = require("ui/event")
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

    table.insert(buttons, {
        {
            text = _("Cancel"),
            callback = function()
                UIManager:close(link_dialog)
            end,
        },
    })

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

hr {
    border: none;
    border-top: 1px solid #999;
    margin: 0.8em 0;
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
  strip_markdown_in_text_mode = true, -- Strip markdown syntax in plain text mode
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
  scroll_to_last_question = false, -- Whether to scroll to last user question on show

  -- Recreate function for rotation handling
  -- Set by dialogs.lua to enable window recreation on screen rotation
  _recreate_func = nil,

  -- Session-only toggle for hiding highlighted text (does not persist)
  hide_highlighted_text = false,

  -- Session-only web search override (nil = follow global, true = force on, false = force off)
  session_web_search_override = nil,

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

  -- Simple view mode (read-only viewer for cached analyses)
  -- Shows only: MD/Text, Copy, Scroll, Close (plus Regenerate/Delete if callbacks provided)
  simple_view = false,

  -- Callbacks for simple_view regenerate/delete functionality
  -- on_regenerate: function() called when user clicks Regenerate (should close viewer and regenerate)
  -- on_delete: function() called when user clicks Delete (should close viewer and clear cache)
  -- cache_type_name: display name for confirmation dialogs (e.g., "X-Ray", "Summary", "Analysis")
  on_regenerate = nil,
  regenerate_label = nil,  -- Custom label for regenerate button (e.g., "Update" instead of "Regenerate")
  on_delete = nil,
  cache_type_name = nil,

  -- Artifact viewer context (simple_view only)
  -- _info_text: pre-built multi-line string for Info popup (model, date, source, etc.)
  -- _artifact_file: book file path for cross-navigation and Open button
  -- _artifact_key: current artifact key for excluding from "Other Artifacts" list
  -- _artifact_book_title/author: for passing to cross-navigation viewers
  -- _book_open: whether the book is currently open in the reader
  _info_text = nil,
  _artifact_file = nil,
  _artifact_key = nil,
  _artifact_book_title = nil,
  _artifact_book_author = nil,
  _book_open = false,

  -- Callbacks for notebook viewer (simple_view for notebooks)
  -- on_edit: function() called when user clicks Edit (should close viewer and open editor)
  -- on_open_reader: function() called when user clicks Open in Reader (should close viewer and open ReaderUI)
  -- on_export: function() called when user clicks Export (for non-cache content like notebooks)
  on_edit = nil,
  on_open_reader = nil,
  on_export = nil,

  -- Metadata for cache export (simple_view only)
  -- Contains: cache_type, book_title, book_author, progress_decimal, model, timestamp, used_annotations
  cache_metadata = nil,

  -- Original cache content without metadata header (simple_view only)
  -- Used by copy/export to avoid duplicating metadata already added by Export.formatCacheContent()
  _cache_content = nil,

  -- Selection position data for "Save to Note" feature
  -- Contains pos0, pos1, sboxes, pboxes for recreating highlight
  selection_data = nil,

  -- Configuration passed from dialogs.lua (must be in defaults to ensure proper option merging)
  configuration = nil,
}

function ChatGPTViewer:init()
  -- calculate window dimension using shared constants
  -- Uses Wikipedia-style dimensions: near-100% with tiny margin
  self.align = "center"
  self.region = Geom:new {
    x = 0, y = 0,
    w = Screen:getWidth(),
    h = Screen:getHeight(),
  }
  self.width = self.width or UIConstants.CHAT_WIDTH()

  -- Height calculation depends on view mode:
  -- - compact_view: fixed compact height (60%)
  -- - translate_view: dynamic height based on content, capped at max
  -- - standard: full Wikipedia-style height
  if self.compact_view then
    self.height = self.height or UIConstants.COMPACT_DIALOG_HEIGHT()
  elseif self.simple_view or self.translate_view or (self.configuration and self.configuration.features and self.configuration.features.translate_view) then
    -- Dynamic height for simple/translate view (like Wikipedia)
    -- Calculate based on content length, capped at max available height
    self.height = self.height or self:calculateDynamicHeight()
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

  -- Scroll buttons stay always enabled - simpler and more reliable than
  -- tracking state across widget recreation (MD/Text mode toggle).
  -- No-op callback kept for compatibility with ScrollTextWidget.
  self._buttons_scroll_callback = function() end

  -- buttons - organize into multiple rows for better layout
  local enable_emoji = self.configuration and self.configuration.features
                       and self.configuration.features.enable_emoji_icons
  -- First row: Main actions
  local first_row = {
    {
      text = Constants.getEmojiText("↩️", _("Reply"), enable_emoji),
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
          -- Extract book metadata and books_info from configuration
          local book_metadata = features.book_metadata
          local books_info = features.is_multi_book_context and features.books_info or nil
          local data = Export.fromHistory(history, self.original_highlighted_text, book_metadata, books_info)
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
      text = _("Save to Note"),
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
      text = _("Add to Notebook"),
      id = "save_to_notebook",
      enabled = self.configuration and self.configuration.document_path
                and self.configuration.document_path ~= "__GENERAL_CHATS__"
                and self.configuration.document_path ~= "__MULTI_BOOK_CHATS__",
      callback = function()
        self:saveToNotebook()
      end,
      hold_callback = function()
        UIManager:show(Notification:new{
          text = _("Append chat to per-book notebook file"),
          timeout = 2,
        })
      end,
    },
    {
      text = Constants.getEmojiText("🏷️", "#", enable_emoji),
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

  -- Conditionally add Export button if enabled in settings
  local export_features = self.configuration and self.configuration.features or {}
  if export_features.show_export_in_chat_viewer then
    table.insert(first_row, {
      text = _("Export"),
      id = "export_chat",
      callback = function()
        self:showExportDialog()
      end,
      hold_callback = function()
        UIManager:show(Notification:new{
          text = _("Export chat to file or clipboard"),
          timeout = 2,
        })
      end,
    })
  end

  -- Conditionally add Regenerate Fresh button when response was from cache
  local history = self._message_history or self.original_history
  if history and history.used_cache and history.cache_action_id then
    table.insert(first_row, {
      text = _("↻ Fresh"),
      id = "regenerate_fresh",
      callback = function()
        self:showRegenerateFreshDialog()
      end,
      hold_callback = function()
        UIManager:show(Notification:new{
          text = _("Clear cache and regenerate from scratch (extracts all book text again)"),
          timeout = 3,
        })
      end,
    })
  end

  -- Add web search toggle (far right of first row)
  -- Session override > global setting
  local function getWebSearchState()
    if self.session_web_search_override ~= nil then
      return self.session_web_search_override
    end
    -- Check global setting from configuration
    local cfg = self.configuration
    if cfg and cfg.features and cfg.features.enable_web_search then
      return true
    end
    return false
  end
  -- Helper to get web search button text with optional emoji
  local function getWebSearchButtonText(state)
    local label = state and _("ON") or _("OFF")
    if enable_emoji then
      return Constants.getEmojiText("🔍", label, enable_emoji)
    end
    return "Web " .. label
  end

  table.insert(first_row, {
    text_func = function()
      local state = getWebSearchState()
      return getWebSearchButtonText(state)
    end,
    id = "toggle_web_search",
    callback = function()
      -- Toggle web search override for this session
      local current_state = getWebSearchState()
      self.session_web_search_override = not current_state
      -- Update button text (force re-init to handle truncation avoidance)
      local button = self.button_table:getButtonById("toggle_web_search")
      if button then
        local new_state = getWebSearchState()
        button.did_truncation_tweaks = true  -- Force full re-init with truncation check
        button:setText(getWebSearchButtonText(new_state), button.width)
      end
      -- Refresh display
      UIManager:setDirty(self, function()
        return "ui", self.frame.dimen
      end)
    end,
    hold_callback = function()
      UIManager:show(Notification:new{
        text = _("Toggle web search for this session (Anthropic, Gemini)"),
        timeout = 2,
      })
    end,
  })

  local default_buttons = {
    first_row,
    -- Second row: Controls and toggles
    {
      {
        text_func = function()
          return self.render_markdown and "MD ON" or "TXT ON"
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
            local htmlbox = self.scroll_text_w.htmlbox_widget
            if htmlbox then
              -- Already at top - do nothing to avoid unnecessary refresh
              if htmlbox.page_number == 1 then
                return
              end
              -- Use scrollToRatio for smooth scroll without full re-render
              self.scroll_text_w:scrollToRatio(0)
            end
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
  if self.configuration.features and self.configuration.features.strip_markdown_in_text_mode ~= nil then
    self.strip_markdown_in_text_mode = self.configuration.features.strip_markdown_in_text_mode
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
  -- Simple view has its own info header that should always be visible (no quote toggle)
  if self.configuration.features then
    if not self.simple_view then
      local highlight_text = self.original_highlighted_text or ""
      local threshold = self.configuration.features.long_highlight_threshold or 280
      self.hide_highlighted_text = self.configuration.features.hide_highlighted_text or
        (self.configuration.features.hide_long_highlights and string.len(highlight_text) > threshold)
    end
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
    -- Dictionary compact view: text mode and RTL settings
    if self.compact_view then
      -- Check if text mode is forced for all dictionary lookups
      if self.configuration.features.dictionary_text_mode then
        self.render_markdown = false
      end
      -- Set RTL paragraph direction when dictionary language is RTL
      local dict_lang = self.configuration.features.dictionary_language
      if Languages.isRTL(dict_lang) then
        self.para_direction_rtl = true
        self.auto_para_direction = false  -- Override auto-detection with explicit RTL
        -- Default to text mode for RTL dictionary if setting enabled (and not already forced)
        if not self.configuration.features.dictionary_text_mode and
           self.configuration.features.rtl_dictionary_text_mode ~= false then
          self.render_markdown = false
        end
      end
    end
    -- Translate view: RTL text mode setting
    if self.translate_view then
      local trans_lang = self.configuration.features.translation_language
      if Languages.isRTL(trans_lang) then
        self.para_direction_rtl = true
        self.auto_para_direction = false  -- Override auto-detection with explicit RTL
        -- Default to text mode for RTL translation if setting enabled
        if self.configuration.features.rtl_translate_text_mode ~= false then
          self.render_markdown = false
        end
      end
    end
    -- Standard chat view: auto-detect RTL in AI response if setting enabled
    -- (compact_view and translate_view have their own RTL handling via language settings)
    if not self.compact_view and not self.translate_view and not self.simple_view then
      if self.configuration.features.rtl_chat_text_mode ~= false then
        local latest_response = getLatestResponse(self._message_history or self.original_history)
        if hasDominantRTL(latest_response) then
          self.para_direction_rtl = true
          self.auto_para_direction = false
          self.render_markdown = false
        end
      end
    end
    -- Simple view (caches/summaries): auto-detect RTL in content
    -- Uses sampling (first 10KB) for performance on large cached content
    if self.simple_view and self.text then
      if self.configuration.features.rtl_chat_text_mode ~= false then
        if hasDominantRTL(self.text, 10000) then
          self.para_direction_rtl = true
          self.auto_para_direction = false
          self.render_markdown = false
        end
      end
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
      return self.render_markdown and "MD ON" or "TXT ON"
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

  -- Row 1: Copy button (uses dictionary_copy_content setting)
  table.insert(minimal_button_row1, {
    text = _("Copy"),
    id = "copy_chat",
    callback = function()
      local chat_history = self._message_history or self.original_history
      if not chat_history then
        UIManager:show(Notification:new{
          text = _("No response to copy"),
          timeout = 2,
        })
        return
      end

      local features = self.configuration and self.configuration.features or {}
      local content = features.dictionary_copy_content or "response"
      if content == "global" then
        content = features.copy_content or "full"
      end
      local style = features.export_style or "markdown"

      -- Helper to perform the copy
      local function doCopy(selected_content)
        local Export = require("koassistant_export")
        local book_metadata = features.book_metadata
        local books_info = features.is_multi_book_context and features.books_info or nil
        local data = Export.fromHistory(chat_history, self.original_highlighted_text, book_metadata, books_info)
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
  })

  -- Row 1: +Note button (save to KOReader highlight note)
  table.insert(minimal_button_row1, {
    text = _("+Note"),
    id = "save_to_note",
    enabled = self.selection_data ~= nil,
    callback = function()
      self:saveToNote()
    end,
    hold_callback = function()
      UIManager:show(Notification:new{
        text = self.selection_data
          and _("Save AI response as note on highlighted word")
          or _("No selection data available (word position not captured)"),
        timeout = 2,
      })
    end,
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
    text = _("Language"),
    id = "change_language",
    enabled = has_rerun and true or false,
    callback = function()
      if not has_rerun then return end
      local plugin = self.configuration._rerun_plugin
      local languages = plugin and plugin.getCombinedLanguages and plugin:getCombinedLanguages() or {}
      if #languages == 0 then
        UIManager:show(Notification:new{
          text = _("Configure languages in Settings first"),
          timeout = 2,
        })
        return
      end
      -- Build language buttons with native display names
      local lang_dialog
      local lang_buttons = {}
      for _i, lang in ipairs(languages) do
        table.insert(lang_buttons, {{
          text = Languages.getDisplay(lang),  -- Native script display
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
            new_config.features.dictionary_language = lang  -- Keep English ID for RTL detection
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
  -- Disable entirely for non-reader lookups (ChatGPT viewer, nested dictionary)
  -- where book page context would be irrelevant
  local no_context_available = rerun_features and rerun_features._no_context_available
  local has_context = not no_context_available and rerun_features and
    rerun_features.dictionary_context_mode ~= "none" and
    rerun_features.dictionary_context and
    rerun_features.dictionary_context ~= ""
  table.insert(minimal_button_row2, {
    text = has_context and _("Ctx: ON") or _("Ctx: OFF"),
    id = "toggle_context",
    enabled = has_rerun and not no_context_available or false,
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

  -- Row 2: Action switcher button (re-run with different dictionary action)
  -- Get current action and other dictionary popup actions
  local current_action = self.configuration and self.configuration._rerun_action
  local current_action_text = current_action and current_action.text or "?"
  local other_actions = {}
  if has_rerun and self.configuration._rerun_plugin then
    local action_service = self.configuration._rerun_plugin.action_service
    if action_service then
      local all_dict_actions = action_service:getDictionaryPopupActionObjects(true)
      for _i, action in ipairs(all_dict_actions) do
        if not current_action or action.id ~= current_action.id then
          table.insert(other_actions, action)
        end
      end
    end
  end

  table.insert(minimal_button_row2, {
    text = current_action_text,
    id = "switch_action",
    enabled = has_rerun and #other_actions > 0,
    callback = function()
      if not has_rerun or #other_actions == 0 then return end

      -- Helper to switch to a different action
      local function switchToAction(action)
        -- Build new config copy
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
        -- Close viewer and execute new action
        UIManager:close(self)
        local Dialogs = require("koassistant_dialogs")
        Dialogs.executeDirectAction(
          self.configuration._rerun_ui, action,
          self.original_highlighted_text, new_config, self.configuration._rerun_plugin
        )
      end

      -- If only one other action, switch directly
      if #other_actions == 1 then
        switchToAction(other_actions[1])
        return
      end

      -- Show popup with other actions
      local action_dialog
      local action_buttons = {}
      for _i, action in ipairs(other_actions) do
        table.insert(action_buttons, {{
          text = action.text,
          callback = function()
            UIManager:close(action_dialog)
            switchToAction(action)
          end,
        }})
      end
      table.insert(action_buttons, {{
        text = _("Cancel"),
        callback = function() UIManager:close(action_dialog) end,
      }})
      action_dialog = ButtonDialog:new{
        title = _("Dictionary Action"),
        buttons = action_buttons,
      }
      UIManager:show(action_dialog)
    end,
    hold_callback = function()
      UIManager:show(Notification:new{
        text = #other_actions > 0
          and _("Switch to a different dictionary action")
          or _("No other dictionary actions available"),
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

  -- Translate view buttons (2 rows)
  -- Row 1: MD/Text, Copy, Note (if highlighting)
  -- Row 2: → Chat, Show/Hide Original, Lang, Close
  local translate_button_row1 = {}
  local translate_button_row2 = {}

  -- Translate Row 1: MD/Text toggle
  table.insert(translate_button_row1, {
    text_func = function()
      return self.render_markdown and "MD ON" or "TXT ON"
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
      local chat_history = self._message_history or self.original_history
      if not chat_history then
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
        local book_metadata = features.book_metadata
        local books_info = features.is_multi_book_context and features.books_info or nil
        local data = Export.fromHistory(chat_history, self.original_highlighted_text, book_metadata, books_info)
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

  -- Translate Row 1: Save to Note button (grayed out when no selection_data)
  table.insert(translate_button_row1, {
    text = _("Save to Note"),
    id = "save_to_note",
    enabled = self.selection_data ~= nil,
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

  -- Translate Row 2: Language button (re-run with different translation language)
  local translate_rerun_features = self.configuration and self.configuration.features
  local translate_has_rerun = self.configuration and self.configuration._rerun_action
  table.insert(translate_button_row2, {
    text = _("Language"),
    id = "change_language",
    enabled = translate_has_rerun and true or false,
    callback = function()
      if not translate_has_rerun then return end
      local plugin = self.configuration._rerun_plugin
      local languages = plugin and plugin.getCombinedLanguages and plugin:getCombinedLanguages() or {}
      if #languages == 0 then
        UIManager:show(Notification:new{
          text = _("Configure languages in Settings first"),
          timeout = 2,
        })
        return
      end
      -- Build language buttons with native display names
      local lang_dialog
      local lang_buttons = {}
      for _i, lang in ipairs(languages) do
        table.insert(lang_buttons, {{
          text = Languages.getDisplay(lang),  -- Native script display
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
            new_config.features.translation_language = lang  -- Keep English ID for RTL detection
            -- Override the "use primary" toggle so the explicit selection takes effect (runtime only)
            new_config.features.translation_use_primary = false
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
        title = _("Translate To"),
        buttons = lang_buttons,
      }
      UIManager:show(lang_dialog)
    end,
    hold_callback = function()
      UIManager:show(Notification:new{
        text = _("Re-run translation with a different target language"),
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

  -- Simple view buttons - read-only viewer for cached analyses
  -- Row 1: Copy, [Artifacts], Export, ⇱ (top), ⇲ (bottom)
  -- Row 2: MD/Text, Info, [Update/Regenerate/Open Doc], [Delete], Close
  -- Notebook mode replaces Row 2 middle with: Open in Reader, Edit
  local simple_view_row1 = {
    {
      text = _("Copy"),
      id = "copy_cache",
      callback = function()
        local copy_text
        if self.cache_metadata then
          -- Include metadata header like file export
          -- Use _cache_content (original text without info header) to avoid duplicating metadata
          local Export = require("koassistant_export")
          copy_text = Export.formatCacheContent(self._cache_content or self.text, self.cache_metadata, "markdown")
        else
          copy_text = self.text
        end
        Device.input.setClipboardText(copy_text)
        UIManager:show(Notification:new{
          text = _("Copied to clipboard"),
          timeout = 2,
        })
      end,
      hold_callback = self.default_hold_callback,
    },
  }

  -- Artifacts button (cross-navigate to other cached artifacts for the same book)
  if self._artifact_file then
    local ActionCache = require("koassistant_action_cache")
    local other_artifacts = ActionCache.getAvailableArtifacts(self._artifact_file, self._artifact_key)
    if #other_artifacts > 0 then
      table.insert(simple_view_row1, {
        text = _("Artifacts"),
        id = "artifacts",
        callback = function()
          local ButtonDialog = require("ui/widget/buttondialog")
          local art_buttons = {}
          for _idx, art in ipairs(other_artifacts) do
            local captured = art
            table.insert(art_buttons, {{
              text = _("View") .. " " .. captured.name,
              callback = function()
                UIManager:close(self._artifacts_dialog)
                self:onClose()
                if self._plugin then
                  if captured.is_per_action then
                    self._plugin:viewCachedAction(
                      { text = captured.name }, captured.key, captured.data,
                      { file = self._artifact_file, book_title = self._artifact_book_title,
                        book_author = self._artifact_book_author })
                  else
                    self._plugin:showCacheViewer({
                      name = captured.name, key = captured.key, data = captured.data,
                      book_title = self._artifact_book_title, book_author = self._artifact_book_author,
                      file = self._artifact_file })
                  end
                end
              end,
            }})
          end
          table.insert(art_buttons, {{
            text = _("Cancel"),
            callback = function() UIManager:close(self._artifacts_dialog) end,
          }})
          self._artifacts_dialog = ButtonDialog:new{
            title = _("Other Artifacts"),
            buttons = art_buttons,
          }
          UIManager:show(self._artifacts_dialog)
        end,
        hold_callback = self.default_hold_callback,
      })
    end
  end

  -- Export button (if cache_metadata or on_export callback is provided)
  if self.cache_metadata or self.on_export then
    table.insert(simple_view_row1, {
      text = _("Export"),
      id = "export_cache",
      callback = function()
        if self.on_export then
          self.on_export()
        else
          self:exportCacheContent()
        end
      end,
      hold_callback = self.default_hold_callback,
    })
  end

  -- Navigation buttons
  table.insert(simple_view_row1, {
    text = "⇱",
    id = "top",
    callback = function()
      if self.render_markdown then
        local htmlbox = self.scroll_text_w.htmlbox_widget
        if htmlbox then
          if htmlbox.page_number == 1 then
            return
          end
          self.scroll_text_w:scrollToRatio(0)
        end
      else
        self.scroll_text_w:scrollToTop()
      end
    end,
    hold_callback = self.default_hold_callback,
  })
  table.insert(simple_view_row1, {
    text = "⇲",
    id = "bottom",
    callback = function()
      if self.render_markdown then
        self.scroll_text_w:scrollToRatio(1)
      else
        self.scroll_text_w:scrollToBottom()
      end
    end,
    hold_callback = self.default_hold_callback,
  })

  -- Build second row based on whether callbacks are provided
  -- Always starts with MD/TXT toggle
  local simple_view_row2 = {
    {
      text_func = function()
        return self.render_markdown and "MD ON" or "TXT ON"
      end,
      id = "toggle_markdown",
      callback = function()
        self:toggleMarkdown()
      end,
      hold_callback = self.default_hold_callback,
    },
  }
  -- Info button (shows metadata popup) - in Row 2 for balanced button distribution
  if self._info_text then
    table.insert(simple_view_row2, {
      text = _("Info"),
      id = "info_cache",
      callback = function()
        local InfoMessage = require("ui/widget/infomessage")
        UIManager:show(InfoMessage:new{
          text = self._info_text,
        })
      end,
      hold_callback = self.default_hold_callback,
    })
  end
  if self.on_open_reader and self.on_edit then
    -- Notebook mode: Open in Reader + Edit buttons
    table.insert(simple_view_row2, {
      text = _("Open in Reader"),
      id = "open_reader",
      callback = function()
        self:onClose()
        self.on_open_reader()
      end,
      hold_callback = self.default_hold_callback,
    })
    table.insert(simple_view_row2, {
      text = _("Edit"),
      id = "edit_notebook",
      callback = function()
        self:onClose()
        self.on_edit()
      end,
      hold_callback = self.default_hold_callback,
    })
  else
    -- Cache mode: Update/Regenerate or Open button
    if self._book_open and self.on_regenerate then
      -- Book is open: show Update or Regenerate
      local regen_label = self.regenerate_label or _("Regenerate")
      table.insert(simple_view_row2, {
        text = regen_label,
        id = "regenerate_cache",
        callback = function()
          local ConfirmBox = require("ui/widget/confirmbox")
          UIManager:show(ConfirmBox:new{
            text = T(_("Regenerate this %1?\n\nThe current %1 will be replaced."), self.cache_type_name or _("summary")),
            ok_text = regen_label,
            ok_callback = function()
              self:onClose()
              self.on_regenerate()
            end,
          })
        end,
        hold_callback = self.default_hold_callback,
      })
    elseif not self._book_open and self._artifact_file then
      -- Book not open (file browser): show Open Doc button
      table.insert(simple_view_row2, {
        text = _("Open Doc"),
        id = "open_book",
        callback = function()
          self:onClose()
          local ReaderUI = require("apps/reader/readerui")
          ReaderUI:showReader(self._artifact_file)
        end,
        hold_callback = self.default_hold_callback,
      })
    end
    if self.on_delete then
      table.insert(simple_view_row2, {
        text = _("Delete"),
        id = "delete_cache",
        callback = function()
          local ConfirmBox = require("ui/widget/confirmbox")
          UIManager:show(ConfirmBox:new{
            text = T(_("Delete this %1?"), self.cache_type_name or _("summary")),
            ok_text = _("Delete"),
            ok_callback = function()
              self:onClose()
              self.on_delete()
            end,
          })
        end,
        hold_callback = self.default_hold_callback,
      })
    end
  end
  table.insert(simple_view_row2, {
    text = _("Close"),
    callback = function()
      self:onClose()
    end,
    hold_callback = self.default_hold_callback,
  })

  -- Always use two rows (row 2 has MD/TXT toggle + Close at minimum)
  local simple_view_buttons = { simple_view_row1, simple_view_row2 }

  local buttons = self.buttons_table or {}
  if self.add_default_buttons or not self.buttons_table then
    -- Use minimal buttons in minimal mode, translate buttons in translate mode, simple view in simple mode, otherwise full default buttons
    if self.minimal_buttons then
      table.insert(buttons, minimal_button_row1)
      table.insert(buttons, minimal_button_row2)
    elseif self.simple_view then
      for _, row in ipairs(simple_view_buttons) do
        table.insert(buttons, row)
      end
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

  -- For dictionary popup with RTL language, detect early for IPA fix
  local dict_lang = self.configuration and self.configuration.features
      and self.configuration.features.dictionary_language
  local is_rtl_lang = Languages.isRTL(dict_lang)
  local needs_rtl_fix = self.compact_view and is_rtl_lang

  if self.render_markdown then
    -- Convert Markdown to HTML and render in a ScrollHtmlWidget
    -- 1. Auto-linkify plain URLs, 2. Escape non-link brackets, 3. Convert tables
    local source_text = self.text
    -- Fix IPA BiDi issues before HTML conversion when RTL dictionary language
    if needs_rtl_fix then
      source_text = fixIPABidi(source_text)
    end
    local auto_linked = autoLinkUrls(source_text)
    local bracket_escaped = preprocessBrackets(auto_linked)
    local preprocessed_text = preprocessMarkdownTables(bracket_escaped)
    local html_body, err = MD(preprocessed_text, {})
    if err then
      logger.warn("ChatGPTViewer: could not generate HTML", err)
      -- Fallback to plain text if HTML generation fails
      html_body = "<pre>" .. (self.text or "Missing text.") .. "</pre>"
    end
    -- For dictionary popup with RTL language, use "starts with RTL" detection
    local bidi_opts = { use_starts_with_rtl = needs_rtl_fix }
    html_body = addHtmlBidiAttributes(html_body, bidi_opts)
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
    -- If not rendering Markdown, optionally strip markdown syntax for cleaner display
    local display_text = self.strip_markdown_in_text_mode and stripMarkdown(self.text, self.para_direction_rtl) or self.text
    -- Fix IPA BiDi issues when RTL dictionary language
    if needs_rtl_fix then
      display_text = fixIPABidi(display_text)
    end
    self.scroll_text_w = ScrollTextWidget:new {
      text = display_text,
      face = self.text_face,
      fgcolor = self.fgcolor,
      line_height = 0.2,  -- Denser than default 0.3 to match markdown view
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

-- Calculate dynamic height for translate view (Wikipedia-style sizing)
-- Estimates content height based on text length and caps at max available height
-- Returns height that fits content or max, whichever is smaller
function ChatGPTViewer:calculateDynamicHeight()
  local max_height = UIConstants.CHAT_HEIGHT()  -- Maximum: Wikipedia-style full height

  -- Estimate chrome height (title bar + buttons + padding)
  -- Title bar: ~50px, buttons (2 rows for translate): ~80px, padding/margins: ~40px
  local chrome_height = Screen:scaleBySize(170)

  -- If no text, use a reasonable default
  if not self.text or self.text == "" then
    -- Minimum height: enough for chrome + a few lines
    return math.min(Screen:scaleBySize(300), max_height)
  end

  -- Estimate line height based on font size
  -- Default markdown font is 20, gives roughly 1.5x for line height with spacing
  local font_size = self.markdown_font_size or 20
  local estimated_line_height = Screen:scaleBySize(math.floor(font_size * 1.8))

  -- Estimate content width (width minus padding/margins)
  local content_width = self.width and (self.width - Screen:scaleBySize(40)) or (Screen:getWidth() * 0.85)

  -- Estimate characters per line (rough: ~0.5 of font size per character on average)
  local chars_per_line = math.floor(content_width / (font_size * 0.6))
  chars_per_line = math.max(chars_per_line, 20)  -- Minimum reasonable chars per line

  -- Estimate number of lines from text length
  -- Account for line breaks in text
  local text_length = #self.text
  local newline_count = select(2, self.text:gsub("\n", "\n"))
  local estimated_lines = math.ceil(text_length / chars_per_line) + newline_count

  -- Calculate estimated content height
  local content_height = estimated_lines * estimated_line_height

  -- Add chrome and some padding
  local total_height = content_height + chrome_height + Screen:scaleBySize(40)

  -- Minimum height: at least enough to show something useful
  local min_height = Screen:scaleBySize(250)

  -- Return clamped height
  return math.max(min_height, math.min(total_height, max_height))
end

-- Calculate scroll ratio to show the last user question at top of viewport
-- For plain text: uses character position for accuracy
-- For markdown: uses line-based calculation (character positions don't match rendered content)
function ChatGPTViewer:calculateLastQuestionRatio()
  if not self.text then return 0 end

  -- Find all "▶ User:" markers in the display text
  local user_marker = "▶ User:"
  local last_pos = nil
  local search_start = 1

  while true do
    local pos = self.text:find(user_marker, search_start, true)  -- plain text search
    if pos then
      last_pos = pos
      search_start = pos + 1
    else
      break
    end
  end

  -- If no user marker found or at the start, no scrolling needed
  if not last_pos or last_pos <= 1 then return 0 end

  -- For markdown mode, use line-based calculation
  -- Character positions don't match rendered positions (tables, formatting expand)
  if self.render_markdown then
    -- Count total lines and lines before last user marker
    local lines_before = 0
    local total_lines = 0
    local pos = 1
    while pos <= #self.text do
      local nl = self.text:find("\n", pos, true)
      if nl then
        total_lines = total_lines + 1
        if nl < last_pos then
          lines_before = lines_before + 1
        end
        pos = nl + 1
      else
        total_lines = total_lines + 1
        break
      end
    end

    if total_lines <= 1 then return 0 end
    local ratio = lines_before / total_lines
    return math.max(0, math.min(ratio, 1))
  else
    -- For plain text, character position is accurate
    local total_len = #self.text
    local ratio = (last_pos - 1) / total_len
    return math.max(0, math.min(ratio, 1))
  end
end

function ChatGPTViewer:onShow()
  UIManager:setDirty(self, function()
    return "partial", self.frame.dimen
  end)

  -- Schedule scroll after widget renders
  if self.scroll_to_last_question then
    UIManager:scheduleIn(0.1, function()
      if self.scroll_text_w then
        local ratio = self:calculateLastQuestionRatio()
        if self.scroll_text_w.scrollToRatio then
          self.scroll_text_w:scrollToRatio(ratio)
        elseif self.scroll_text_w.scrollToBottom and ratio >= 0.9 then
          self.scroll_text_w:scrollToBottom()
        end
      end
    end)
  elseif self.scroll_to_bottom then
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
      expanded_config.features.simple_view = false
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
    selection_data = self.selection_data,  -- Preserve for "Save to Note" feature
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

  -- Count words: up to 3 words → dictionary lookup, 4+ → clipboard copy
  local word_count = 0
  if text then
    for _w in text:gmatch("%S+") do
      word_count = word_count + 1
      if word_count > 3 then break end  -- Early exit, no need to count all
    end
  end

  local did_lookup = false
  if word_count >= 1 and word_count <= 3 then
    -- Use KOReader's dictionary lookup (onLookupWord).
    -- If bypass is ON, the installed intercept routes to KOAssistant's AI action.
    -- If bypass is OFF, KOReader's native dictionary popup opens.
    -- Either way, the current viewer stays open underneath.
    local ui = self._ui or (self.configuration and self.configuration._rerun_ui)
    if ui and ui.dictionary then
      -- Signal that this lookup originates from a non-reader context (AI response text).
      -- Context extraction from the book page would be irrelevant/misleading.
      ui.dictionary._koassistant_non_reader_lookup = true
      ui.dictionary:onLookupWord(text)
      did_lookup = true
    end
  end

  if not did_lookup then
    if Device:hasClipboard() then
      Device.input.setClipboardText(text)
      UIManager:show(Notification:new {
        text = _("Copied to clipboard."),
      })
    end
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
    -- For dictionary popup with RTL language, use "starts with RTL" detection
    local dict_lang = self.configuration and self.configuration.features
        and self.configuration.features.dictionary_language
    local bidi_opts = { use_starts_with_rtl = self.compact_view and Languages.isRTL(dict_lang) }
    html_body = addHtmlBidiAttributes(html_body, bidi_opts)

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
    -- For plain text, optionally strip markdown and recreate widget
    local display_text = self.strip_markdown_in_text_mode and stripMarkdown(new_text, self.para_direction_rtl) or new_text
    -- Fix BiDi issues for RTL dictionary compact view
    if self.compact_view and self.para_direction_rtl then
      display_text = fixIPABidi(display_text)
    end
    self.scroll_text_w = ScrollTextWidget:new {
      text = display_text,
      face = self.text_face,
      fgcolor = self.fgcolor,
      line_height = 0.2,  -- Denser than default 0.3 to match markdown view
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
  
  -- Check if RTL dictionary popup for IPA fix
  local dict_lang = self.configuration and self.configuration.features
      and self.configuration.features.dictionary_language
  local needs_rtl_fix = self.compact_view and Languages.isRTL(dict_lang)

  if self.render_markdown then
    -- Convert to markdown
    -- 1. Auto-linkify plain URLs, 2. Escape non-link brackets, 3. Convert tables
    local source_text = self.text
    -- Fix IPA BiDi issues before HTML conversion when RTL dictionary language
    if needs_rtl_fix then
      source_text = fixIPABidi(source_text)
    end
    local auto_linked = autoLinkUrls(source_text)
    local bracket_escaped = preprocessBrackets(auto_linked)
    local preprocessed_text = preprocessMarkdownTables(bracket_escaped)
    local html_body, err = MD(preprocessed_text, {})
    if err then
      logger.warn("ChatGPTViewer: could not generate HTML", err)
      html_body = "<pre>" .. (self.text or "Missing text.") .. "</pre>"
    end
    -- For dictionary popup with RTL language, use "starts with RTL" detection
    local bidi_opts = { use_starts_with_rtl = needs_rtl_fix }
    html_body = addHtmlBidiAttributes(html_body, bidi_opts)
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
    -- Convert to plain text with optional markdown stripping
    local display_text = self.strip_markdown_in_text_mode and stripMarkdown(self.text, self.para_direction_rtl) or self.text
    -- Fix IPA BiDi issues when RTL dictionary language
    if needs_rtl_fix then
      display_text = fixIPABidi(display_text)
    end
    self.scroll_text_w = ScrollTextWidget:new {
      text = display_text,
      face = self.text_face,
      fgcolor = self.fgcolor,
      line_height = 0.2,  -- Denser than default 0.3 to match markdown view
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

  -- Update button text (force re-init to handle truncation avoidance)
  local button = self.button_table:getButtonById("toggle_markdown")
  if button then
    button.did_truncation_tweaks = true  -- Force full re-init with truncation check
    button:setText(self.render_markdown and "MD ON" or "TXT ON", button.width)
  end

  -- Refresh display (view toggle always starts at top - no scroll restoration)
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
  if features.minimal_buttons then
    -- Dictionary/compact view: use dictionary-specific setting
    content = features.dictionary_note_content or "response"
    if content == "global" then
      content = features.note_content or "qa"
    end
  elseif self.translate_view then
    content = features.translate_note_content or "response"
    if content == "global" then
      content = features.note_content or "qa"
    end
  else
    content = features.note_content or "qa"
  end
  local style = features.export_style or "markdown"

  -- For dictionary/compact view: DON'T extend to sentence (word-only highlight)
  -- For translate/highlight: extend to sentence (existing behavior)
  local extend_to_sentence = not features.minimal_buttons

  -- Helper to perform the save
  local function doSave(selected_content)
    local Export = require("koassistant_export")
    local book_metadata = features.book_metadata
    local books_info = features.is_multi_book_context and features.books_info or nil
    local data = Export.fromHistory(history, self.original_highlighted_text, book_metadata, books_info)
    local note_text = Export.format(data, selected_content, style)

    if note_text == "" then
      UIManager:show(Notification:new{
        text = _("No response to save"),
        timeout = 2,
      })
      return
    end

    -- Close translate view before opening note editor (so note editor appears on top of book)
    if self.translate_view then
      UIManager:close(self)
    end

    -- Restore selected_text to ReaderHighlight so saveHighlight() can create the highlight
    reader_ui.highlight.selected_text = self.selection_data

    -- For dictionary: bypass addNote() which forces sentence extension
    -- Call saveHighlight(false) directly to preserve word-only highlight
    if not extend_to_sentence then
      local index = reader_ui.highlight:saveHighlight(false)  -- false = no sentence extension
      if index then
        reader_ui.highlight:clear()
        reader_ui.highlight:editNote(index, true, note_text)
      else
        UIManager:show(Notification:new{
          text = _("Failed to create highlight"),
          timeout = 2,
        })
      end
    else
      -- Standard flow for translate/highlight views (extends to sentence)
      reader_ui.highlight:addNote(note_text)
    end
  end

  if content == "ask" then
    showContentPicker(_("Note Content"), self.translate_view, doSave)
  else
    doSave(content)
  end
end

function ChatGPTViewer:saveToNotebook()
  -- Save chat to per-book notebook file
  local document_path = self.configuration and self.configuration.document_path
  if not document_path
      or document_path == "__GENERAL_CHATS__"
      or document_path == "__MULTI_BOOK_CHATS__" then
    UIManager:show(Notification:new{
      text = _("Notebooks are only available for single-book chats"),
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

  -- Get ReaderUI for page info
  local ReaderUI = require("apps/reader/readerui")
  local reader_ui = ReaderUI.instance

  -- Get content format setting (default: qa)
  local features = self.configuration and self.configuration.features or {}
  local content_format = features.notebook_content_format or "qa"

  -- Save to notebook
  local Notebook = require("koassistant_notebook")
  local model_name = self.configuration and self.configuration.model
  local ok, err = Notebook.saveChat(document_path, history, self.original_highlighted_text, reader_ui, content_format, model_name)

  if ok then
    -- Update notebook index directly (same as main.lua:updateNotebookIndex)
    local stats = Notebook.getStats(document_path)
    if stats then
      local index = G_reader_settings:readSetting("koassistant_notebook_index", {})
      index[document_path] = stats
      G_reader_settings:saveSetting("koassistant_notebook_index", index)
      G_reader_settings:flush()
    end

    UIManager:show(Notification:new{
      text = _("Saved to notebook"),
      timeout = 2,
    })
  else
    UIManager:show(Notification:new{
      text = _("Failed to save: ") .. (err or "unknown error"),
      timeout = 3,
    })
  end
end

function ChatGPTViewer:showRegenerateFreshDialog()
  -- Show confirmation dialog for clearing cache and regenerating from scratch
  local history = self._message_history or self.original_history
  if not history or not history.cache_action_id then
    UIManager:show(Notification:new{
      text = _("No cached action to clear"),
      timeout = 2,
    })
    return
  end

  local document_path = self.configuration and self.configuration.document_path
  if not document_path or document_path == "__GENERAL_CHATS__" or document_path == "__MULTI_BOOK_CHATS__" then
    UIManager:show(Notification:new{
      text = _("Cache only applies to book actions"),
      timeout = 2,
    })
    return
  end

  local action_id = history.cache_action_id
  local cached_progress = history.cached_progress or "?"

  local ButtonDialog = require("ui/widget/buttondialog")
  local dialog
  dialog = ButtonDialog:new{
    title = _("Regenerate Fresh"),
    text = T(_("This response was updated from a cached analysis at %1.\n\nClearing the cache will extract and send all book text again on next run, which uses more tokens.\n\nClear cache for this action?"), cached_progress),
    buttons = {
      {
        {
          text = _("Cancel"),
          callback = function()
            UIManager:close(dialog)
          end,
        },
        {
          text = _("Clear & Close"),
          callback = function()
            UIManager:close(dialog)
            -- Clear the cache for this action
            local ok, ActionCache = pcall(require, "koassistant_action_cache")
            if ok and ActionCache then
              local success = ActionCache.clear(document_path, action_id)
              if success then
                UIManager:show(Notification:new{
                  text = _("Cache cleared. Run the action again for fresh analysis."),
                  timeout = 3,
                })
                -- Close the viewer
                self:onClose()
              else
                UIManager:show(Notification:new{
                  text = _("Failed to clear cache"),
                  timeout = 2,
                })
              end
            else
              UIManager:show(Notification:new{
                text = _("Cache module not available"),
                timeout = 2,
              })
            end
          end,
        },
      },
    },
  }
  UIManager:show(dialog)
end

function ChatGPTViewer:showExportDialog()
  -- Show export dialog with options to copy or save to file
  local history = self._message_history or self.original_history
  if not history then
    UIManager:show(Notification:new{
      text = _("No chat to export"),
      timeout = 2,
    })
    return
  end

  local features = self.configuration and self.configuration.features or {}
  local content_setting = features.copy_content or "full"
  local style = features.export_style or "markdown"

  -- Get book title and chat title for filename
  -- For unsaved chats: use prompt_action as title, current time as timestamp
  -- Priority: book_metadata > configuration > document path extraction
  local book_title = nil
  if features.book_metadata and features.book_metadata.title then
    book_title = features.book_metadata.title
  elseif self.configuration and self.configuration.book_title then
    book_title = self.configuration.book_title
  elseif self.configuration and self.configuration.document_path then
    -- Extract filename from path as fallback
    book_title = self.configuration.document_path:match("([^/\\]+)$") or nil
    if book_title then
      book_title = book_title:gsub("%.[^.]+$", "")  -- Remove extension
    end
  end
  local chat_title = history.prompt_action or nil  -- Action name for unsaved chats
  -- For unsaved chats, timestamp will be nil (uses current time)

  local Export = require("koassistant_export")
  local viewer_self = self
  local export_book_metadata = features.book_metadata
  local export_books_info = features.is_multi_book_context and features.books_info or nil

  -- Determine chat type for subfolder routing
  local document_path = self.configuration and self.configuration.document_path
  local chat_type = "book"
  if features.is_multi_book_context then
    chat_type = "multi_book"
  elseif not document_path or document_path == "" or document_path == "__GENERAL_CHATS__" then
    chat_type = "general"
  end

  -- Helper to perform the copy
  local function doCopy(selected_content)
    local data = Export.fromHistory(history, viewer_self.original_highlighted_text, export_book_metadata, export_books_info)
    local text = Export.format(data, selected_content, style)
    Device.input.setClipboardText(text)
    UIManager:show(Notification:new{
      text = _("Copied"),
      timeout = 2,
    })
  end

  -- Helper to perform save to file
  local function doSave(selected_content, target_dir, skip_book_title)
    local data = Export.fromHistory(history, viewer_self.original_highlighted_text, export_book_metadata, export_books_info)
    local text = Export.format(data, selected_content, style)

    if not text or text == "" then
      UIManager:show(InfoMessage:new{
        text = _("No content to export"),
        timeout = 2,
      })
      return
    end

    local extension = (style == "markdown") and "md" or "txt"
    local filename = Export.getFilename(book_title, chat_title, nil, extension, skip_book_title)  -- nil = use current time
    local filepath = target_dir .. "/" .. filename

    local success, err = Export.saveToFile(text, filepath)
    if success then
      UIManager:show(InfoMessage:new{
        text = T(_("Saved to:\n%1"), filepath),
        timeout = 4,
      })
    else
      UIManager:show(InfoMessage:new{
        text = T(_("Failed to save: %1"), err or "Unknown error"),
        timeout = 3,
      })
    end
  end

  -- Show action selection dialog
  local function showActionDialog(selected_content)
    local action_dialog
    local dir_option = features.export_save_directory or "book_folder"

    local buttons = {
      {
        {
          text = _("Copy to Clipboard"),
          callback = function()
            UIManager:close(action_dialog)
            doCopy(selected_content)
          end,
        },
      },
      {
        {
          text = _("Save to File"),
          callback = function()
            UIManager:close(action_dialog)

            if dir_option == "ask" then
              -- Show PathChooser
              local PathChooser = require("ui/widget/pathchooser")
              local DataStorage = require("datastorage")
              -- Use KOReader's fallback chain: home_dir setting → Device.home_dir → DataStorage
              local start_path = G_reader_settings:readSetting("home_dir") or Device.home_dir or DataStorage:getDataDir()
              local path_chooser = PathChooser:new{
                title = _("Select Export Directory"),
                path = start_path,
                select_directory = true,
                onConfirm = function(path)
                  doSave(selected_content, path, false)  -- User-chosen path, don't skip book title
                end,
              }
              UIManager:show(path_chooser)
            else
              -- Use configured directory
              local target_dir, dir_err, skip_book_title = Export.getDirectory(features, document_path, chat_type)
              if not target_dir then
                UIManager:show(InfoMessage:new{
                  text = T(_("Invalid export directory: %1"), dir_err or "Unknown error"),
                  timeout = 3,
                })
                return
              end
              doSave(selected_content, target_dir, skip_book_title)
            end
          end,
        },
      },
      {
        {
          text = _("Cancel"),
          callback = function()
            UIManager:close(action_dialog)
          end,
        },
      },
    }

    action_dialog = ButtonDialog:new{
      title = _("Export Chat"),
      buttons = buttons,
    }
    UIManager:show(action_dialog)
  end

  if content_setting == "ask" then
    -- Show content picker first
    showContentPicker(_("Export Content"), self.translate_view, function(selected_content)
      showActionDialog(selected_content)
    end)
  else
    -- Content is predetermined, show action dialog directly
    showActionDialog(content_setting)
  end
end

--- Export cached content to file (simple_view only)
-- Uses PathChooser to select directory, then saves with metadata header
function ChatGPTViewer:exportCacheContent()
  if not self.cache_metadata then
    UIManager:show(InfoMessage:new{
      text = _("No export metadata available."),
    })
    return
  end

  local PathChooser = require("ui/widget/pathchooser")
  local Export = require("koassistant_export")
  local DataStorage = require("datastorage")

  -- Default path from main export settings
  local default_path
  local features = self.configuration and self.configuration.features or {}
  local dir_option = features.export_save_directory or "exports_folder"

  if dir_option == "custom" and features.export_custom_path and features.export_custom_path ~= "" then
    default_path = features.export_custom_path
  elseif dir_option == "exports_folder" or dir_option == "ask" then
    default_path = DataStorage:getDataDir() .. "/koassistant_exports"
  else
    default_path = DataStorage:getDataDir()
  end

  local path_chooser = PathChooser:new{
    title = _("Select export folder"),
    path = default_path,
    show_hidden = false,
    select_directory = true,
    select_file = false,
    onConfirm = function(selected_path)
      -- Generate filename
      local filename = Export.getCacheFilename(
        self.cache_metadata.book_title,
        self.cache_metadata.cache_type
      )
      local filepath = selected_path .. "/" .. filename

      -- Format content with metadata
      -- Use _cache_content (original text without info header) to avoid duplicating metadata
      local formatted = Export.formatCacheContent(
        self._cache_content or self.text,
        self.cache_metadata,
        "markdown"
      )

      -- Save to file
      local success, err = Export.saveToFile(formatted, filepath)
      if success then
        UIManager:show(Notification:new{
          text = T(_("Saved to %1"), filename),
          timeout = 3,
        })
      else
        UIManager:show(InfoMessage:new{
          text = T(_("Export failed: %1"), err or "unknown error"),
        })
      end
    end,
  }
  UIManager:show(path_chooser)
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
    -- For dictionary popup with RTL language, use "starts with RTL" detection
    local dict_lang = self.configuration and self.configuration.features
        and self.configuration.features.dictionary_language
    local bidi_opts = { use_starts_with_rtl = self.compact_view and Languages.isRTL(dict_lang) }
    html_body = addHtmlBidiAttributes(html_body, bidi_opts)
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
    -- Plain text mode with optional markdown stripping
    local display_text = self.strip_markdown_in_text_mode and stripMarkdown(self.text, self.para_direction_rtl) or self.text
    self.scroll_text_w = ScrollTextWidget:new {
      text = display_text,
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
    selection_data = self.selection_data,  -- Preserve for "Save to Note" feature
    -- Plugin/UI references for text selection dictionary lookup
    _plugin = self._plugin,
    _ui = self._ui,
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
  -- For dictionary popup with RTL language, use "starts with RTL" detection
  local dict_lang = self.configuration and self.configuration.features
      and self.configuration.features.dictionary_language
  local bidi_opts = { use_starts_with_rtl = self.compact_view and Languages.isRTL(dict_lang) }
  html_body = addHtmlBidiAttributes(html_body, bidi_opts)

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
