--[[--
Book Picker for KOAssistant

Multi-select book picker for multi-book actions.
Shows reading history as a selectable list; selected books are passed
to compareSelectedBooks() for the standard multi-book action flow.

Supports filtering by book status (All, Reading, On Hold, Finished,
Finished 75%+) and search by title/author.

@module koassistant_book_picker
]]

local ButtonDialog = require("ui/widget/buttondialog")
local DocSettings = require("docsettings")
local InfoMessage = require("ui/widget/infomessage")
local Menu = require("ui/widget/menu")
local Screen = require("device").screen
local T = require("ffi/util").template
local UIManager = require("ui/uimanager")
local logger = require("logger")
local _ = require("koassistant_gettext")

local BookPicker = {}

-- Filter definitions: id, display text, match function
local FILTERS = {
    { id = "all",          text = _("All") },
    { id = "reading",      text = _("Reading") },
    { id = "on_hold",      text = _("On Hold") },
    { id = "finished",     text = _("Finished") },
    { id = "finished_75",  text = _("Finished 75%+") },
}

--- Check if an entry matches a filter
--- @param entry table Book entry with status and progress fields
--- @param filter_id string Filter identifier
--- @return boolean
local function matchesFilter(entry, filter_id)
    if filter_id == "all" then return true end
    if filter_id == "reading" then return entry.status == "reading" end
    if filter_id == "on_hold" then return entry.status == "abandoned" end
    if filter_id == "finished" then return entry.status == "complete" end
    if filter_id == "finished_75" then
        return entry.status == "complete" or (entry.progress and entry.progress >= 0.75)
    end
    return true
end

--- Count selected entries in a hash table
--- @param selected table Hash of selected file paths
--- @return number count
local function countSelected(selected)
    local n = 0
    for _ in pairs(selected) do n = n + 1 end
    return n
end

--- Get book title, author, status, and progress from DocSettings metadata
--- @param doc_path string The document file path
--- @return string title The book title
--- @return string|nil author The book author, or nil
--- @return string|nil status The book status ("reading", "abandoned", "complete", or nil)
--- @return number|nil progress Reading progress (0.0-1.0), or nil
local function getBookMetadata(doc_path)
    local doc_settings = DocSettings:open(doc_path)
    local doc_props = doc_settings:readSetting("doc_props")
    local title = doc_props and (doc_props.display_title or doc_props.title) or nil
    if not title or title == "" then
        title = doc_path:match("([^/]+)%.[^%.]+$") or doc_path
    end
    local author = doc_props and doc_props.authors or nil
    -- Normalize multi-author strings (KOReader stores as newline-separated)
    if author and author:find("\n") then
        author = author:gsub("\n", ", ")
    end
    local summary = doc_settings:readSetting("summary")
    local status = summary and summary.status or nil
    local progress = doc_settings:readSetting("percent_finished")
    return title, author, status, progress
end

--- Get filtered entries based on current filter and search
--- @param entries table Full list of book entries
--- @param filter_id string Active filter id
--- @param search_string string|nil Active search string (lowercase)
--- @return table filtered Filtered entries array
local function getFilteredEntries(entries, filter_id, search_string)
    local filtered = {}
    for _idx, entry in ipairs(entries) do
        if matchesFilter(entry, filter_id) then
            if search_string then
                local title_lower = entry.title and entry.title:lower() or ""
                local author_lower = entry.author and entry.author:lower() or ""
                if not title_lower:find(search_string, 1, true)
                   and not author_lower:find(search_string, 1, true) then
                    goto continue
                end
            end
            table.insert(filtered, entry)
        end
        ::continue::
    end
    return filtered
end

--- Count entries per filter (for display in filter menu)
--- @param entries table Full list of book entries
--- @param search_string string|nil Active search string
--- @return table counts Map of filter_id → count
local function countPerFilter(entries, search_string)
    local counts = {}
    for _idx, filter in ipairs(FILTERS) do
        counts[filter.id] = 0
    end
    for _idx, entry in ipairs(entries) do
        -- Apply search filter first if active
        if search_string then
            local title_lower = entry.title and entry.title:lower() or ""
            local author_lower = entry.author and entry.author:lower() or ""
            if not title_lower:find(search_string, 1, true)
               and not author_lower:find(search_string, 1, true) then
                goto continue
            end
        end
        for _fidx, filter in ipairs(FILTERS) do
            if matchesFilter(entry, filter.id) then
                counts[filter.id] = counts[filter.id] + 1
            end
        end
        ::continue::
    end
    return counts
end

--- Get display text for active filter
--- @param filter_id string Filter identifier
--- @return string
local function getFilterText(filter_id)
    for _idx, filter in ipairs(FILTERS) do
        if filter.id == filter_id then return filter.text end
    end
    return _("All")
end

--- Build the title string with filter and selection count
--- @param filter_id string Active filter id
--- @param selected_count number Number of selected books
--- @return string
local function buildTitle(filter_id, selected_count)
    local filter_text = getFilterText(filter_id)
    return T(_("History: %1 (%2 selected)"), filter_text, selected_count)
end

--- Build menu items from entries and selection state
--- @param entries table Array of book entries
--- @param selected table Hash of selected file paths
--- @param toggle_callback function Called with (entry) when an item is tapped
--- @return table menu_items Array of menu item tables
local function buildMenuItems(entries, selected, toggle_callback)
    local items = {}
    for _idx, entry in ipairs(entries) do
        local is_selected = selected[entry.file] == true
        local check = is_selected and "\u{2611} " or "\u{2610} "
        local display = check .. entry.title
        if entry.author and entry.author ~= "" then
            display = display .. " \u{00B7} " .. entry.author
        end
        local captured_entry = entry
        table.insert(items, {
            text = display,
            mandatory = entry.mandatory,
            mandatory_dim = true,
            callback = function()
                toggle_callback(captured_entry)
            end,
        })
    end
    return items
end

--- Show reading history book picker for multi-book selection
--- @param opts table Options: on_confirm = function(selected_files_hash)
function BookPicker:show(opts)
    local ReadHistory = require("readhistory")

    -- Force reload to get latest history
    ReadHistory:reload()

    -- Build entries from history, filtering to existing files only
    local entries = {}
    for _idx, hist_entry in ipairs(ReadHistory.hist) do
        if not hist_entry.dim then
            local title, author, status, progress = getBookMetadata(hist_entry.file)
            table.insert(entries, {
                file = hist_entry.file,
                title = title,
                author = author,
                status = status,
                progress = progress,
                mandatory = hist_entry.mandatory,
            })
        end
    end

    if #entries == 0 then
        UIManager:show(InfoMessage:new{
            text = _("No books in reading history."),
        })
        return
    end

    local selected = {}
    local menu
    local self_ref = self
    local on_confirm = opts and opts.on_confirm
    self._filter = "all"
    self._search_string = nil

    -- Confirm and close
    local function confirmSelection()
        if countSelected(selected) < 2 then
            UIManager:show(InfoMessage:new{
                text = _("Please select at least 2 books."),
            })
            return
        end
        UIManager:close(menu)
        self_ref.current_menu = nil
        if on_confirm then
            on_confirm(selected)
        end
    end

    local filtered = getFilteredEntries(entries, self._filter, self._search_string)

    -- Toggle selection for an entry and refresh the menu
    local function toggleEntry(entry)
        if selected[entry.file] then
            selected[entry.file] = nil
        else
            selected[entry.file] = true
        end
        self_ref:_refresh(menu, entries, selected)
    end

    local menu_items = buildMenuItems(filtered, selected, toggleEntry)

    menu = Menu:new{
        title = buildTitle(self._filter, countSelected(selected)),
        item_table = menu_items,
        is_borderless = true,
        is_popout = false,
        width = Screen:getWidth(),
        height = Screen:getHeight(),
        title_bar_left_icon = "appbar.menu",
        onLeftButtonTap = function()
            self_ref:_showPickerOptions(menu, entries, selected, confirmSelection)
        end,
        onMenuSelect = function(_self_menu, item)
            if item and item.callback then item.callback() end
            return true
        end,
        search_callback = function(search_string)
            if search_string and search_string ~= "" then
                self_ref._search_string = search_string:lower()
            else
                self_ref._search_string = nil
            end
            self_ref:_refresh(menu, entries, selected)
        end,
        multilines_show_more_text = true,
        items_max_lines = 2,
        single_line = false,
        multilines_forced = true,
        items_font_size = 18,
        items_mandatory_font_size = 14,
    }

    menu.close_callback = function()
        if self_ref.current_menu == menu then
            self_ref.current_menu = nil
        end
    end

    self.current_menu = menu
    UIManager:show(menu)
end

--- Refresh menu items and title after selection/filter/search change
--- @param menu userdata The Menu widget
--- @param entries table Full array of book entries (unfiltered)
--- @param selected table Hash of selected file paths
function BookPicker:_refresh(menu, entries, selected)
    local self_ref = self
    local filtered = getFilteredEntries(entries, self._filter, self._search_string)

    local function toggleEntry(entry)
        if selected[entry.file] then
            selected[entry.file] = nil
        else
            selected[entry.file] = true
        end
        self_ref:_refresh(menu, entries, selected)
    end

    local items = buildMenuItems(filtered, selected, toggleEntry)
    menu:switchItemTable(buildTitle(self._filter, countSelected(selected)), items, -1)
end

--- Show picker options menu (hamburger)
--- @param menu userdata The Menu widget
--- @param entries table Full array of book entries (unfiltered)
--- @param selected table Hash of selected file paths
--- @param confirm_callback function Called to confirm selection
function BookPicker:_showPickerOptions(menu, entries, selected, confirm_callback)
    local self_ref = self
    local cur_count = countSelected(selected)
    local counts = countPerFilter(entries, self._search_string)
    local dialog
    dialog = ButtonDialog:new{
        buttons = {
            {{ text = T(_("Confirm Selection (%1)"), cur_count),
               enabled = cur_count >= 2,
               align = "left",
               callback = function()
                UIManager:close(dialog)
                confirm_callback()
            end }},
            {{ text = _("Filter…"),
               align = "left",
               callback = function()
                UIManager:close(dialog)
                self_ref:_showFilterMenu(menu, entries, selected, counts)
            end }},
            {{ text = self._search_string and T(_("Search: \"%1\""), self._search_string) or _("Search…"),
               align = "left",
               callback = function()
                UIManager:close(dialog)
                self_ref:_showSearchDialog(menu, entries, selected)
            end }},
            {{ text = _("Select All Visible"), align = "left", callback = function()
                UIManager:close(dialog)
                local filtered = getFilteredEntries(entries, self_ref._filter, self_ref._search_string)
                for _idx, entry in ipairs(filtered) do
                    if not selected[entry.file] then
                        selected[entry.file] = true
                    end
                end
                self_ref:_refresh(menu, entries, selected)
            end }},
            {{ text = _("Clear Selection"), align = "left", callback = function()
                UIManager:close(dialog)
                for k, _v in pairs(selected) do
                    selected[k] = nil
                end
                self_ref:_refresh(menu, entries, selected)
            end }},
        },
        shrink_unneeded_width = true,
        anchor = function()
            return menu.title_bar.left_button.image.dimen, true
        end,
    }
    UIManager:show(dialog)
end

--- Show filter selection menu
--- @param menu userdata The Menu widget
--- @param entries table Full array of book entries
--- @param selected table Hash of selected file paths
--- @param counts table Map of filter_id → count
function BookPicker:_showFilterMenu(menu, entries, selected, counts)
    local self_ref = self
    local buttons = {}
    for _idx, filter in ipairs(FILTERS) do
        local is_active = self._filter == filter.id
        local label = T("%1 (%2)", filter.text, counts[filter.id])
        if is_active then
            label = label .. "  \u{2713}"
        end
        table.insert(buttons, {{ text = label,
            align = "left",
            callback = function()
                UIManager:close(self_ref._filter_dialog)
                self_ref._filter_dialog = nil
                self_ref._filter = filter.id
                self_ref:_refresh(menu, entries, selected)
            end,
        }})
    end
    -- Clear search option (if search is active)
    if self._search_string then
        table.insert(buttons, {{ text = _("Clear search"),
            align = "left",
            callback = function()
                UIManager:close(self_ref._filter_dialog)
                self_ref._filter_dialog = nil
                self_ref._search_string = nil
                self_ref:_refresh(menu, entries, selected)
            end,
        }})
    end
    local dialog = ButtonDialog:new{
        title = _("Filter by status"),
        buttons = buttons,
        shrink_unneeded_width = true,
        anchor = function()
            return menu.title_bar.left_button.image.dimen, true
        end,
    }
    self._filter_dialog = dialog
    UIManager:show(dialog)
end

--- Show search input dialog
--- @param menu userdata The Menu widget
--- @param entries table Full array of book entries
--- @param selected table Hash of selected file paths
function BookPicker:_showSearchDialog(menu, entries, selected)
    local self_ref = self
    local InputDialog = require("ui/widget/inputdialog")
    local search_dialog
    search_dialog = InputDialog:new{
        title = _("Search by title or author"),
        input = self._search_string or "",
        buttons = {{
            {
                text = _("Cancel"),
                id = "close",
                callback = function()
                    UIManager:close(search_dialog)
                end,
            },
            {
                text = _("Clear"),
                callback = function()
                    UIManager:close(search_dialog)
                    self_ref._search_string = nil
                    self_ref:_refresh(menu, entries, selected)
                end,
            },
            {
                text = _("Search"),
                is_enter_default = true,
                callback = function()
                    local input = search_dialog:getInputText()
                    UIManager:close(search_dialog)
                    if input and input ~= "" then
                        self_ref._search_string = input:lower()
                    else
                        self_ref._search_string = nil
                    end
                    self_ref:_refresh(menu, entries, selected)
                end,
            },
        }},
    }
    UIManager:show(search_dialog)
    search_dialog:onShowKeyboard()
end

return BookPicker
