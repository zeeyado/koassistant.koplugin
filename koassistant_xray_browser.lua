--[[--
X-Ray Browser for KOAssistant

Browsable menu UI for structured X-Ray data.
Presents categories (Cast, World, Ideas, etc.) with item counts,
drill-down into category items, detail views, chapter character tracking,
and character search.

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
local logger = require("logger")
local _ = require("koassistant_gettext")
local T = require("ffi/util").template

local XrayParser = require("koassistant_xray_parser")

local XrayBrowser = {
    current_menu = nil,
    current_detail = nil,
    current_options = nil,
}

-- Helper to safely close a widget
local function safeClose(widget)
    if widget then
        UIManager:close(widget)
    end
end

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

--- Show the top-level X-Ray category menu
--- @param xray_data table Parsed JSON structure
--- @param metadata table { title, progress, model, timestamp, book_file }
--- @param ui table|nil KOReader UI instance (nil when book not open)
--- @param on_delete function|nil Callback to delete this cache
function XrayBrowser:show(xray_data, metadata, ui, on_delete)
    self.xray_data = xray_data
    self.metadata = metadata
    self.ui = ui
    self.on_delete = on_delete
    self:showCategoryMenu()
end

--- Show the category menu (top-level browsing)
function XrayBrowser:showCategoryMenu()
    local categories = XrayParser.getCategories(self.xray_data)

    local menu_items = {}

    -- Category items with counts
    for _idx, cat in ipairs(categories) do
        local count = #cat.items
        if count > 0 then
            local mandatory_text = ""
            -- Don't show count for current_state/current_position (always 1)
            if cat.key ~= "current_state" and cat.key ~= "current_position" then
                mandatory_text = tostring(count)
            end

            local captured_cat = cat
            table.insert(menu_items, {
                text = cat.label,
                mandatory = mandatory_text,
                callback = function()
                    if captured_cat.key == "current_state" or captured_cat.key == "current_position" then
                        self:showItemDetail(captured_cat.items[1], captured_cat.key, captured_cat.label)
                    else
                        self:showCategoryItems(captured_cat)
                    end
                end,
            })
        end
    end

    -- Separator before utility items
    if #menu_items > 0 then
        menu_items[#menu_items].separator = true
    end

    -- Chapter Characters (only when book is open and we have characters)
    local char_key = XrayParser.getCharacterKey(self.xray_data)
    local has_characters = self.xray_data[char_key] and #self.xray_data[char_key] > 0
    if self.ui and self.ui.document and has_characters then
        table.insert(menu_items, {
            text = _("Chapter Characters"),
            callback = function()
                self:showChapterCharacters()
            end,
        })
    end

    -- Search (only if we have characters/figures)
    if has_characters then
        table.insert(menu_items, {
            text = _("Search"),
            callback = function()
                self:showSearch()
            end,
        })
    end

    -- Full View
    table.insert(menu_items, {
        text = _("Full View"),
        callback = function()
            self:showFullView()
        end,
    })

    -- Build title
    local title = "X-Ray"
    if self.metadata.progress then
        title = title .. " (" .. self.metadata.progress .. ")"
    end

    safeClose(self.current_menu)

    local self_ref = self
    local menu = Menu:new{
        title = title,
        item_table = menu_items,
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
        close_callback = function()
            self_ref.current_menu = nil
        end,
    }

    self.current_menu = menu
    UIManager:show(menu)
end

--- Show items within a category
--- @param category table {key, label, items}
function XrayBrowser:showCategoryItems(category)
    local menu_items = {}

    for _idx, item in ipairs(category.items) do
        local name = XrayParser.getItemName(item, category.key)
        local secondary = XrayParser.getItemSecondary(item, category.key)

        local captured_item = item
        table.insert(menu_items, {
            text = name,
            mandatory = secondary,
            mandatory_dim = true,
            callback = function()
                self:showItemDetail(captured_item, category.key, name)
            end,
        })
    end

    safeClose(self.current_menu)

    local self_ref = self
    local title = category.label .. " (" .. #category.items .. ")"
    local menu = Menu:new{
        title = title,
        item_table = menu_items,
        is_borderless = true,
        is_popout = false,
        width = Screen:getWidth(),
        height = Screen:getHeight(),
        single_line = true,
        items_font_size = 18,
        items_mandatory_font_size = 14,
        onReturn = function()
            -- Go back to category menu
            UIManager:close(self_ref.current_menu)
            self_ref.current_menu = nil
            UIManager:scheduleIn(0.1, function()
                self_ref:showCategoryMenu()
            end)
        end,
        close_callback = function()
            self_ref.current_menu = nil
        end,
    }

    self.current_menu = menu
    UIManager:show(menu)
end

--- Show detail view for a single item
--- @param item table The item data
--- @param category_key string The category key
--- @param title string Display title
function XrayBrowser:showItemDetail(item, category_key, title)
    local detail_text = XrayParser.formatItemDetail(item, category_key)

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

    safeClose(self.current_detail)

    self.current_detail = TextViewer:new{
        title = title or _("Details"),
        text = detail_text,
        width = Screen:getWidth(),
        height = Screen:getHeight(),
    }
    UIManager:show(self.current_detail)
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

        -- Build menu
        local menu_items = {}
        for _idx, entry in ipairs(found) do
            local char = entry.item
            local count = entry.count
            local name = char.name or _("Unknown")

            local captured_char = char
            table.insert(menu_items, {
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

        safeClose(self_ref.current_menu)

        local menu = Menu:new{
            title = title,
            item_table = menu_items,
            is_borderless = true,
            is_popout = false,
            width = Screen:getWidth(),
            height = Screen:getHeight(),
            single_line = true,
            items_font_size = 18,
            items_mandatory_font_size = 14,
            onReturn = function()
                UIManager:close(self_ref.current_menu)
                self_ref.current_menu = nil
                UIManager:scheduleIn(0.1, function()
                    self_ref:showCategoryMenu()
                end)
            end,
            close_callback = function()
                self_ref.current_menu = nil
            end,
        }

        self_ref.current_menu = menu
        UIManager:show(menu)
    end)
end

--- Show character search dialog
function XrayBrowser:showSearch()
    local self_ref = self

    safeClose(self.current_detail)

    local input_dialog
    input_dialog = InputDialog:new{
        title = _("Search Characters"),
        input = "",
        input_hint = _("Name, alias, or description..."),
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
    self.current_detail = input_dialog
    UIManager:show(input_dialog)
    input_dialog:onShowKeyboard()
end

--- Show search results
--- @param query string The search query
function XrayBrowser:showSearchResults(query)
    local results = XrayParser.searchCharacters(self.xray_data, query)

    if #results == 0 then
        UIManager:show(InfoMessage:new{
            text = T(_("No results for \"%1\"."), query),
            timeout = 3,
        })
        return
    end

    local menu_items = {}
    local char_key = XrayParser.getCharacterKey(self.xray_data)

    for _idx, result in ipairs(results) do
        local char = result.item
        local name = char.name or _("Unknown")
        local match_label = ""
        if result.match_field == "alias" then
            match_label = _("alias")
        elseif result.match_field == "description" then
            match_label = _("desc.")
        end

        local captured_char = char
        table.insert(menu_items, {
            text = name,
            mandatory = match_label,
            mandatory_dim = true,
            callback = function()
                self:showItemDetail(captured_char, char_key, name)
            end,
        })
    end

    safeClose(self.current_menu)

    local self_ref = self
    local menu = Menu:new{
        title = T(_("Results for \"%1\" (%2)"), query, #results),
        item_table = menu_items,
        is_borderless = true,
        is_popout = false,
        width = Screen:getWidth(),
        height = Screen:getHeight(),
        single_line = true,
        items_font_size = 18,
        items_mandatory_font_size = 14,
        onReturn = function()
            UIManager:close(self_ref.current_menu)
            self_ref.current_menu = nil
            UIManager:scheduleIn(0.1, function()
                self_ref:showCategoryMenu()
            end)
        end,
        close_callback = function()
            self_ref.current_menu = nil
        end,
    }

    self.current_menu = menu
    UIManager:show(menu)
end

--- Show full rendered markdown view in ChatGPTViewer
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

    -- Close the browser menu first
    safeClose(self.current_menu)
    self.current_menu = nil

    local viewer = ChatGPTViewer:new{
        title = title,
        text = markdown,
        simple_view = true,
    }
    UIManager:show(viewer)
end

--- Show options menu (hamburger button)
function XrayBrowser:showOptions()
    local buttons = {}

    -- Delete option
    if self.on_delete then
        local self_ref = self
        table.insert(buttons, {{
            text = _("Delete X-Ray"),
            callback = function()
                safeClose(self_ref.current_options)
                self_ref.current_options = nil

                local ConfirmBox = require("ui/widget/confirmbox")
                UIManager:show(ConfirmBox:new{
                    text = _("Delete this X-Ray? This cannot be undone."),
                    ok_text = _("Delete"),
                    ok_callback = function()
                        self_ref.on_delete()
                        safeClose(self_ref.current_menu)
                        self_ref.current_menu = nil
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
                safeClose(self.current_options)
                self.current_options = nil
                UIManager:show(InfoMessage:new{
                    text = table.concat(info_parts, "\n"),
                })
            end,
        }})
    end

    table.insert(buttons, {{
        text = _("Close"),
        callback = function()
            safeClose(self.current_options)
            self.current_options = nil
        end,
    }})

    safeClose(self.current_options)
    self.current_options = ButtonDialog:new{
        buttons = buttons,
    }
    UIManager:show(self.current_options)
end

return XrayBrowser
