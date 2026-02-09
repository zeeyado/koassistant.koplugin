--[[--
X-Ray Browser for KOAssistant

Browsable menu UI for structured X-Ray data.
Presents categories (Cast, World, Ideas, etc.) with item counts,
drill-down into category items, detail views, chapter character tracking,
and search.

Uses a single Menu instance with switchItemTable() for navigation,
maintaining a stack for back-arrow support.

@module koassistant_xray_browser
]]

local ButtonDialog = require("ui/widget/buttondialog")
local Device = require("device")
local InfoMessage = require("ui/widget/infomessage")
local InputDialog = require("ui/widget/inputdialog")
local Menu = require("ui/widget/menu")
local Screen = Device.screen
local TextViewer = require("ui/widget/textviewer")
local UIManager = require("ui/uimanager")
local _ = require("koassistant_gettext")
local T = require("ffi/util").template

local Constants = require("koassistant_constants")
local XrayParser = require("koassistant_xray_parser")

local XrayBrowser = {}

--- Extract text for the current chapter from the open document
--- @param ui table KOReader UI instance
--- @return string chapter_text The extracted text, or empty string
--- @return string chapter_title The chapter title, or empty string
local function getCurrentChapterText(ui)
    if not ui or not ui.document then
        return "", ""
    end

    -- Get total pages
    local total_pages = ui.document.info and ui.document.info.number_of_pages or 0
    if total_pages == 0 then return "", "" end

    -- Get current page
    local current_page
    if ui.document.info.has_pages then
        -- PDF/DJVU
        current_page = ui.view and ui.view.state and ui.view.state.page or 1
    else
        -- EPUB/reflowable
        local xp = ui.document:getXPointer()
        current_page = xp and ui.document:getPageFromXPointer(xp) or 1
    end

    -- Get TOC
    local toc = ui.toc and ui.toc.toc
    if not toc or #toc == 0 then
        return "", ""
    end

    -- Find current chapter boundaries
    local chapter_start_page, chapter_end_page, chapter_title
    for i, entry in ipairs(toc) do
        if entry.page and entry.page <= current_page then
            chapter_start_page = entry.page
            chapter_title = entry.title or ""
            if toc[i + 1] and toc[i + 1].page then
                chapter_end_page = toc[i + 1].page - 1
            else
                chapter_end_page = total_pages
            end
        end
    end

    if not chapter_start_page then return "", "" end

    -- Extract text between chapter boundaries
    local text = ""
    local max_chars = 100000  -- Cap at 100K for performance

    if ui.document.info.has_pages then
        -- PDF: iterate pages
        local parts = {}
        local char_count = 0
        local end_page = math.min(chapter_end_page, chapter_start_page + 50)  -- Cap pages too
        for page = chapter_start_page, end_page do
            local ok, page_text = pcall(ui.document.getPageText, ui.document, page)
            if ok and page_text then
                -- getPageText returns a table of text blocks for PDFs
                if type(page_text) == "table" then
                    for _idx, block in ipairs(page_text) do
                        if block.text then
                            table.insert(parts, block.text)
                            char_count = char_count + #block.text
                        end
                    end
                elseif type(page_text) == "string" then
                    table.insert(parts, page_text)
                    char_count = char_count + #page_text
                end
                if char_count >= max_chars then break end
            end
        end
        text = table.concat(parts, " ")
    else
        -- EPUB/reflowable: use getTextFromPositions if available
        -- Convert pages to document positions
        local ok, result = pcall(function()
            -- Get xpointers for chapter start and end pages
            local start_xp = ui.document:getPageXPointer(chapter_start_page)
            local end_xp = ui.document:getPageXPointer(math.min(chapter_end_page + 1, total_pages))
            if start_xp and end_xp then
                return ui.document:getTextFromXPointers(start_xp, end_xp)
            end
        end)
        if ok and result then
            text = result
        end
    end

    -- Cap length
    if #text > max_chars then
        text = text:sub(1, max_chars)
    end

    return text, chapter_title or ""
end

--- Find user highlights that mention a character (by name or aliases)
--- @param character table Character entry with name and aliases
--- @param ui table KOReader UI instance
--- @return table matches Array of highlight text strings
local function findCharacterHighlights(character, ui)
    if not ui or not ui.annotation or not ui.annotation.annotations then
        return {}
    end

    -- Build list of names to search for
    local names = {}
    if character.name and #character.name > 2 then
        table.insert(names, character.name:lower())
    end
    if character.aliases then
        for _idx, alias in ipairs(character.aliases) do
            if #alias > 2 then
                table.insert(names, alias:lower())
            end
        end
    end
    if #names == 0 then return {} end

    local matches = {}
    for _idx, annotation in ipairs(ui.annotation.annotations) do
        local ann_text = annotation.text
        if ann_text and ann_text ~= "" then
            local text_lower = ann_text:lower()
            for _idx2, name in ipairs(names) do
                if text_lower:find(name, 1, true) then
                    table.insert(matches, ann_text)
                    break
                end
            end
        end
    end
    return matches
end

-- Emoji mappings for category keys (used when enable_emoji_icons is on)
local CATEGORY_EMOJIS = {
    characters = "👥", key_figures = "👥",
    locations = "🌍", core_concepts = "💡",
    themes = "💭", arguments = "⚖️",
    lexicon = "📖", terminology = "📖",
    timeline = "📅", argument_development = "📅",
    current_state = "📍", current_position = "📍",
}

--- Show the top-level X-Ray category menu
--- @param xray_data table Parsed JSON structure
--- @param metadata table { title, progress, model, timestamp, book_file, enable_emoji }
--- @param ui table|nil KOReader UI instance (nil when book not open)
--- @param on_delete function|nil Callback to delete this cache
function XrayBrowser:show(xray_data, metadata, ui, on_delete)
    self.xray_data = xray_data
    self.metadata = metadata
    self.ui = ui
    self.on_delete = on_delete
    self.nav_stack = {}

    local items = self:buildCategoryItems()
    local title = self:buildMainTitle()
    self.current_title = title

    local self_ref = self
    self.menu = Menu:new{
        title = title,
        item_table = items,
        is_borderless = true,
        is_popout = false,
        width = Screen:getWidth(),
        height = Screen:getHeight(),
        single_line = true,
        items_font_size = 18,
        items_mandatory_font_size = 14,
        title_bar_left_icon = "appbar.menu",
        onLeftButtonTap = function()
            self_ref:showOptions()
        end,
        onReturn = function()
            self_ref:navigateBack()
        end,
        -- NOTE: Do NOT use close_callback here. KOReader's Menu:onMenuSelect()
        -- calls close_callback after every item tap, not just on widget close.
        -- Cleanup is done via onCloseWidget instead.
    }
    -- Hook into onCloseWidget for cleanup (only fires when widget is actually removed)
    local orig_onCloseWidget = self.menu.onCloseWidget
    self.menu.onCloseWidget = function(menu_self)
        self_ref.menu = nil
        self_ref.nav_stack = {}
        if orig_onCloseWidget then
            return orig_onCloseWidget(menu_self)
        end
    end
    UIManager:show(self.menu)
end

--- Build the main title for the browser
--- @return string title
function XrayBrowser:buildMainTitle()
    local title = "X-Ray"
    if self.metadata.progress then
        title = title .. " (" .. self.metadata.progress .. ")"
    end
    return title
end

--- Build item table for the top-level category menu
--- @return table items Menu item table
function XrayBrowser:buildCategoryItems()
    local categories = XrayParser.getCategories(self.xray_data)
    local enable_emoji = self.metadata.enable_emoji
    local self_ref = self

    local items = {}

    -- Category items with counts
    for _idx, cat in ipairs(categories) do
        local count = #cat.items
        if count > 0 then
            local mandatory_text = ""
            -- Don't show count for current_state/current_position (always 1)
            if cat.key ~= "current_state" and cat.key ~= "current_position" then
                mandatory_text = tostring(count)
            end

            local label = Constants.getEmojiText(CATEGORY_EMOJIS[cat.key] or "", cat.label, enable_emoji)
            local captured_cat = cat
            table.insert(items, {
                text = label,
                mandatory = mandatory_text,
                callback = function()
                    if captured_cat.key == "current_state" or captured_cat.key == "current_position" then
                        self_ref:showItemDetail(captured_cat.items[1], captured_cat.key, captured_cat.label)
                    else
                        self_ref:showCategoryItems(captured_cat)
                    end
                end,
            })
        end
    end

    -- Separator before utility items
    if #items > 0 then
        items[#items].separator = true
    end

    -- Chapter Characters (only when book is open and we have characters)
    local char_key = XrayParser.getCharacterKey(self.xray_data)
    local has_characters = self.xray_data[char_key] and #self.xray_data[char_key] > 0
    if self.ui and self.ui.document and has_characters then
        table.insert(items, {
            text = Constants.getEmojiText("📑", _("Chapter Characters"), enable_emoji),
            callback = function()
                self_ref:showChapterCharacters()
            end,
        })
    end

    -- Search
    table.insert(items, {
        text = Constants.getEmojiText("🔍", _("Search"), enable_emoji),
        callback = function()
            self_ref:showSearch()
        end,
    })

    -- Full View
    table.insert(items, {
        text = Constants.getEmojiText("📄", _("Full View"), enable_emoji),
        callback = function()
            self_ref:showFullView()
        end,
    })

    return items
end

--- Navigate forward: push current state and switch to new items
--- @param title string New menu title
--- @param items table New menu items
function XrayBrowser:navigateForward(title, items)
    if not self.menu then return end

    -- Save current state
    table.insert(self.nav_stack, {
        title = self.current_title,
        items = self.menu.item_table,
    })
    self.current_title = title

    -- Add to paths so back arrow becomes enabled via updatePageInfo
    table.insert(self.menu.paths, true)
    self.menu:switchItemTable(title, items)
end

--- Navigate back: pop state and restore, or close if at root
function XrayBrowser:navigateBack()
    if not self.menu then return end

    if #self.nav_stack == 0 then
        -- At root level — close the browser
        UIManager:close(self.menu)
        return
    end

    local prev = table.remove(self.nav_stack)
    self.current_title = prev.title

    -- Remove from paths so back arrow disables when we reach root
    table.remove(self.menu.paths)
    self.menu:switchItemTable(prev.title, prev.items)
end

--- Show items within a category (navigates forward)
--- @param category table {key, label, items}
function XrayBrowser:showCategoryItems(category)
    local items = {}
    local self_ref = self

    for _idx, item in ipairs(category.items) do
        local name = XrayParser.getItemName(item, category.key)
        local secondary = XrayParser.getItemSecondary(item, category.key)

        local captured_item = item
        table.insert(items, {
            text = name,
            mandatory = secondary,
            mandatory_dim = true,
            callback = function()
                self_ref:showItemDetail(captured_item, category.key, name)
            end,
        })
    end

    local title = category.label .. " (" .. #category.items .. ")"
    self:navigateForward(title, items)
end

--- Show detail view for a single item (overlays as TextViewer)
--- @param item table The item data
--- @param category_key string The category key
--- @param title string Display title
function XrayBrowser:showItemDetail(item, category_key, title)
    local detail_text = XrayParser.formatItemDetail(item, category_key)

    -- For current state/position: prepend reading progress for clarity
    if (category_key == "current_state" or category_key == "current_position") and self.metadata.progress then
        detail_text = _("As of") .. " " .. self.metadata.progress .. "\n\n" .. detail_text
    end

    -- For characters: append matching highlights if available
    if (category_key == "characters" or category_key == "key_figures") and self.ui then
        local highlights = findCharacterHighlights(item, self.ui)
        if #highlights > 0 then
            detail_text = detail_text .. "\n\n" .. _("Your highlights:") .. "\n"
            for _idx, hl in ipairs(highlights) do
                -- Truncate very long highlights
                local display_hl = hl
                if #display_hl > 200 then
                    display_hl = display_hl:sub(1, 200) .. "..."
                end
                detail_text = detail_text .. "\n> " .. display_hl
            end
        end
    end

    UIManager:show(TextViewer:new{
        title = title or _("Details"),
        text = detail_text,
        width = Screen:getWidth(),
        height = Screen:getHeight(),
    })
end

--- Show characters appearing in the current chapter
function XrayBrowser:showChapterCharacters()
    if not self.ui or not self.ui.document then
        UIManager:show(InfoMessage:new{
            text = _("No book open."),
            timeout = 3,
        })
        return
    end

    -- Show processing notification
    UIManager:show(InfoMessage:new{
        text = _("Analyzing chapter..."),
        timeout = 1,
    })

    -- Schedule the actual work to let the notification render
    local self_ref = self
    UIManager:scheduleIn(0.2, function()
        local chapter_text, chapter_title = getCurrentChapterText(self_ref.ui)

        if not chapter_text or chapter_text == "" then
            UIManager:show(InfoMessage:new{
                text = _("Could not extract chapter text."),
                timeout = 3,
            })
            return
        end

        local found = XrayParser.findCharactersInChapter(self_ref.xray_data, chapter_text)

        if #found == 0 then
            local msg = chapter_title ~= "" and
                T(_("No known characters found in \"%1\"."), chapter_title) or
                _("No known characters found in current chapter.")
            UIManager:show(InfoMessage:new{
                text = msg,
                timeout = 4,
            })
            return
        end

        -- Build menu items
        local items = {}
        for _idx, entry in ipairs(found) do
            local char = entry.item
            local count = entry.count
            local name = char.name or _("Unknown")

            local captured_char = char
            table.insert(items, {
                text = name,
                mandatory = T(_("%1x"), count),
                mandatory_dim = true,
                callback = function()
                    local char_key = XrayParser.getCharacterKey(self_ref.xray_data)
                    self_ref:showItemDetail(captured_char, char_key, name)
                end,
            })
        end

        -- Title
        local title
        if chapter_title ~= "" then
            title = T(_("%1 — %2 characters"), chapter_title, #found)
        else
            title = T(_("This Chapter — %1 characters"), #found)
        end

        self_ref:navigateForward(title, items)
    end)
end

--- Show search dialog (overlays as InputDialog)
function XrayBrowser:showSearch()
    local self_ref = self

    local input_dialog
    input_dialog = InputDialog:new{
        title = _("Search X-Ray"),
        input = "",
        input_hint = _("Name, term, description..."),
        buttons = {
            {
                {
                    text = _("Cancel"),
                    id = "close",
                    callback = function()
                        UIManager:close(input_dialog)
                    end,
                },
                {
                    text = _("Search"),
                    is_enter_default = true,
                    callback = function()
                        local query = input_dialog:getInputText()
                        UIManager:close(input_dialog)
                        if query and query ~= "" then
                            self_ref:showSearchResults(query)
                        end
                    end,
                },
            },
        },
    }
    UIManager:show(input_dialog)
    input_dialog:onShowKeyboard()
end

--- Show search results (navigates forward)
--- @param query string The search query
function XrayBrowser:showSearchResults(query)
    local results = XrayParser.searchAll(self.xray_data, query)

    if #results == 0 then
        UIManager:show(InfoMessage:new{
            text = T(_("No results for \"%1\"."), query),
            timeout = 3,
        })
        return
    end

    local items = {}
    local self_ref = self

    for _idx, result in ipairs(results) do
        local item = result.item
        local name = XrayParser.getItemName(item, result.category_key)
        local match_label = result.category_label
        if result.match_field == "alias" then
            match_label = match_label .. " (" .. _("alias") .. ")"
        elseif result.match_field == "description" then
            match_label = match_label .. " (" .. _("desc.") .. ")"
        end

        local captured_item = item
        local captured_key = result.category_key
        table.insert(items, {
            text = name,
            mandatory = match_label,
            mandatory_dim = true,
            callback = function()
                self_ref:showItemDetail(captured_item, captured_key, name)
            end,
        })
    end

    local title = T(_("Results for \"%1\" (%2)"), query, #results)
    self:navigateForward(title, items)
end

--- Show full rendered markdown view in ChatGPTViewer (overlays on menu)
function XrayBrowser:showFullView()
    local ChatGPTViewer = require("koassistant_chatgptviewer")

    local markdown = XrayParser.renderToMarkdown(
        self.xray_data,
        self.metadata.title or "",
        self.metadata.progress or ""
    )

    -- Build title matching existing cache viewer format
    local title = "X-Ray"
    if self.metadata.progress then
        title = title .. " (" .. self.metadata.progress .. ")"
    end
    if self.metadata.model then
        title = title .. " - " .. self.metadata.model
    end
    if self.metadata.timestamp then
        local date_str = os.date("%Y-%m-%d", self.metadata.timestamp)
        title = title .. " [" .. date_str .. "]"
    end

    -- Overlay on top of the menu — closing the viewer returns to the browser
    UIManager:show(ChatGPTViewer:new{
        title = title,
        text = markdown,
        simple_view = true,
    })
end

--- Show options menu (hamburger button)
function XrayBrowser:showOptions()
    local self_ref = self
    local buttons = {}

    -- Delete option
    if self.on_delete then
        table.insert(buttons, {{
            text = _("Delete X-Ray"),
            callback = function()
                if self_ref.options_dialog then
                    UIManager:close(self_ref.options_dialog)
                    self_ref.options_dialog = nil
                end

                local ConfirmBox = require("ui/widget/confirmbox")
                UIManager:show(ConfirmBox:new{
                    text = _("Delete this X-Ray? This cannot be undone."),
                    ok_text = _("Delete"),
                    ok_callback = function()
                        self_ref.on_delete()
                        if self_ref.menu then
                            UIManager:close(self_ref.menu)
                        end
                    end,
                })
            end,
        }})
    end

    -- Info
    local info_parts = {}
    if self.metadata.model then
        table.insert(info_parts, _("Model:") .. " " .. self.metadata.model)
    end
    if self.metadata.progress then
        table.insert(info_parts, _("Progress:") .. " " .. self.metadata.progress)
    end
    if self.metadata.timestamp then
        table.insert(info_parts, _("Date:") .. " " .. os.date("%Y-%m-%d %H:%M", self.metadata.timestamp))
    end
    local type_label = XrayParser.isFiction(self.xray_data) and _("Fiction") or _("Non-Fiction")
    table.insert(info_parts, _("Type:") .. " " .. type_label)

    if #info_parts > 0 then
        table.insert(buttons, {{
            text = _("Info"),
            callback = function()
                if self_ref.options_dialog then
                    UIManager:close(self_ref.options_dialog)
                    self_ref.options_dialog = nil
                end
                UIManager:show(InfoMessage:new{
                    text = table.concat(info_parts, "\n"),
                })
            end,
        }})
    end

    table.insert(buttons, {{
        text = _("Close"),
        callback = function()
            if self_ref.options_dialog then
                UIManager:close(self_ref.options_dialog)
                self_ref.options_dialog = nil
            end
        end,
    }})

    if self.options_dialog then
        UIManager:close(self.options_dialog)
    end
    self.options_dialog = ButtonDialog:new{
        buttons = buttons,
    }
    UIManager:show(self.options_dialog)
end

return XrayBrowser
