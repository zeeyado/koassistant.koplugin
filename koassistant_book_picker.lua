--[[--
Book Picker for KOAssistant

Multi-select book picker for library actions.
Shows books from history or folder as a selectable list; selected books
are passed to the on_confirm callback.

Supports source switching (history / folder), filtering by book status
(All, Reading, On Hold, Finished, Finished 75%+), and search by
title/author.

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

-- Filter definitions: id, display text
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

--- Build the title string with source, filter, and selection count
--- @param source_label string Source display name ("History" or folder name)
--- @param filter_id string Active filter id
--- @param selected_count number Number of selected books
--- @return string
local function buildTitle(source_label, filter_id, selected_count)
    local filter_text = getFilterText(filter_id)
    return T(_("%1: %2 (%3 selected)"), source_label, filter_text, selected_count)
end

--- Get short display name for a folder path
--- @param folder_path string Full folder path
--- @return string Short folder name
local function getFolderDisplayName(folder_path)
    return folder_path:match("([^/]+)/?$") or folder_path
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

--- Load entries from reading history
--- @return table entries Array of book entries, or empty table
function BookPicker:_loadHistoryEntries()
    local ReadHistory = require("readhistory")
    ReadHistory:reload()

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
    return entries
end

--- Load entries from a folder via LibraryScanner
--- @param folder_path string Path to scan
--- @return table entries Array of book entries, or nil on error
--- @return string|nil error Error message if scan failed
function BookPicker:_loadFolderEntries(folder_path)
    local scan_ok, LibraryScanner = pcall(require, "koassistant_library_scanner")
    if not scan_ok or not LibraryScanner then
        return nil, _("Failed to load library scanner.")
    end

    local scan_settings = { library_scan_folders = { folder_path } }
    local scan_result = LibraryScanner.scan(scan_settings)
    if not scan_result or not scan_result.books or #scan_result.books == 0 then
        return nil, T(_("No books found in:\n%1"), folder_path)
    end

    local entries = {}
    for _idx, book in ipairs(scan_result.books) do
        -- Format progress as mandatory text (right-side label)
        local mandatory_text
        if book.progress and book.progress > 0 then
            mandatory_text = string.format("%d%%", math.floor(book.progress * 100))
        end
        table.insert(entries, {
            file = book.file or book.path,
            title = book.title or (book.file or book.path):match("([^/]+)%.[^%.]+$") or book.file or book.path,
            author = book.author,
            status = book.status,
            progress = book.progress,
            mandatory = mandatory_text,
        })
    end
    return entries
end

--- Get the display label for the current source
--- @return string
function BookPicker:_getSourceLabel()
    if self._current_source == "history" then
        return _("History")
    else
        return getFolderDisplayName(self._current_source)
    end
end

--- Switch to a new source, preserving selections
--- @param source string "history" or folder path
function BookPicker:_switchSource(source)
    if source == self._current_source then return end

    local entries, err
    if source == "history" then
        entries = self:_loadHistoryEntries()
    else
        entries, err = self:_loadFolderEntries(source)
        if not entries then
            UIManager:show(InfoMessage:new{
                text = err or _("Failed to load folder."),
                timeout = 3,
            })
            return
        end
    end

    if #entries == 0 then
        local msg = source == "history"
            and _("No books in reading history.")
            or T(_("No books found in:\n%1"), source)
        UIManager:show(InfoMessage:new{
            text = msg,
            timeout = 3,
        })
        return
    end

    self._current_source = source
    if source ~= "history" then
        self._folder_path = source
    end
    self._entries = entries
    self._filter = "all"
    self._search_string = nil
    self:_refresh()
end

--- Open a PathChooser and switch to the selected folder
function BookPicker:_browseFolder()
    local PathChooser = require("ui/widget/pathchooser")
    local Device = require("device")
    local DataStorage = require("datastorage")
    local start_path = self._folder_path
        or G_reader_settings:readSetting("home_dir")
        or Device.home_dir
        or DataStorage:getDataDir()
    local self_ref = self
    local path_chooser = PathChooser:new{
        title = _("Select Folder"),
        path = start_path,
        select_directory = true,
        select_file = false,
        onConfirm = function(selected_path)
            self_ref:_switchSource(selected_path)
        end,
    }
    UIManager:show(path_chooser)
end

--- Show the book picker
--- @param opts table Options: on_confirm = function(selected_files_hash), initial_source = "history"|folder_path, on_close = function()
function BookPicker:show(opts)
    local on_confirm = opts and opts.on_confirm
    local on_close = opts and opts.on_close
    local initial_source = opts and opts.initial_source or "history"

    -- Load initial entries
    local entries, err
    if initial_source == "history" then
        entries = self:_loadHistoryEntries()
    else
        entries, err = self:_loadFolderEntries(initial_source)
        if not entries then
            UIManager:show(InfoMessage:new{
                text = err or _("Failed to load folder."),
                timeout = 3,
            })
            if on_close then on_close() end
            return
        end
    end

    if #entries == 0 then
        if initial_source == "history" then
            UIManager:show(InfoMessage:new{
                text = _("No books in reading history."),
            })
        else
            UIManager:show(InfoMessage:new{
                text = T(_("No books found in:\n%1"), initial_source),
            })
        end
        if on_close then on_close() end
        return
    end

    -- Initialize state
    self._current_source = initial_source
    if initial_source ~= "history" then
        self._folder_path = initial_source
    end
    self._entries = entries
    self._selected = {}
    self._confirm_callback = on_confirm
    self._close_callback = on_close
    self._confirmed = false
    self._filter = "all"
    self._search_string = nil

    local self_ref = self

    -- Confirm and close
    local function confirmSelection()
        if countSelected(self_ref._selected) < 1 then
            UIManager:show(InfoMessage:new{
                text = _("Please select at least 1 book."),
            })
            return
        end
        self_ref._confirmed = true
        UIManager:close(self_ref._menu)
        self_ref.current_menu = nil
        if self_ref._confirm_callback then
            self_ref._confirm_callback(self_ref._selected)
        end
    end
    self._confirmSelection = confirmSelection

    local filtered = getFilteredEntries(entries, self._filter, self._search_string)

    local function toggleEntry(entry)
        if self_ref._selected[entry.file] then
            self_ref._selected[entry.file] = nil
        else
            self_ref._selected[entry.file] = true
        end
        self_ref:_refresh()
    end

    local menu_items = buildMenuItems(filtered, self._selected, toggleEntry)
    local source_label = self:_getSourceLabel()

    local menu = Menu:new{
        title = buildTitle(source_label, self._filter, countSelected(self._selected)),
        item_table = menu_items,
        is_borderless = true,
        is_popout = false,
        width = Screen:getWidth(),
        height = Screen:getHeight(),
        title_bar_left_icon = "appbar.menu",
        onLeftButtonTap = function()
            self_ref:_showPickerOptions()
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
            self_ref:_refresh()
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
        if not self_ref._confirmed and self_ref._close_callback then
            self_ref._close_callback()
        end
    end

    self._menu = menu
    self.current_menu = menu
    UIManager:show(menu)
end

--- Refresh menu items and title after selection/filter/search/source change
function BookPicker:_refresh()
    local self_ref = self
    local filtered = getFilteredEntries(self._entries, self._filter, self._search_string)

    local function toggleEntry(entry)
        if self_ref._selected[entry.file] then
            self_ref._selected[entry.file] = nil
        else
            self_ref._selected[entry.file] = true
        end
        self_ref:_refresh()
    end

    local items = buildMenuItems(filtered, self._selected, toggleEntry)
    local source_label = self:_getSourceLabel()
    self._menu:switchItemTable(
        buildTitle(source_label, self._filter, countSelected(self._selected)),
        items, -1
    )
end

--- Show picker options menu (hamburger)
function BookPicker:_showPickerOptions()
    local self_ref = self
    local cur_count = countSelected(self._selected)
    local dialog
    local buttons = {}

    -- Confirm Selection
    table.insert(buttons, {{ text = T(_("Confirm Selection (%1)"), cur_count),
       enabled = cur_count >= 1,
       align = "left",
       callback = function()
            UIManager:close(dialog)
            self_ref._confirmSelection()
       end,
    }})

    -- Sources section
    table.insert(buttons, {{ text = _("Sources:"),
       enabled = false,
       align = "left",
    }})

    -- History source
    local history_label = _("History")
    if self._current_source == "history" then
        history_label = history_label .. "  \u{2713}"
    end
    table.insert(buttons, {{ text = history_label,
       align = "left",
       callback = function()
            UIManager:close(dialog)
            self_ref:_switchSource("history")
       end,
    }})

    -- Last browsed folder (if any, and not currently active)
    if self._folder_path then
        local folder_label = T(_("Folder: %1"), getFolderDisplayName(self._folder_path))
        if self._current_source == self._folder_path then
            folder_label = folder_label .. "  \u{2713}"
        end
        table.insert(buttons, {{ text = folder_label,
           align = "left",
           callback = function()
                UIManager:close(dialog)
                self_ref:_switchSource(self_ref._folder_path)
           end,
        }})
    end

    -- Browse Folder...
    table.insert(buttons, {{ text = _("Browse Folder…"),
       align = "left",
       callback = function()
            UIManager:close(dialog)
            self_ref:_browseFolder()
       end,
    }})

    -- Filter
    local counts = countPerFilter(self._entries, self._search_string)
    table.insert(buttons, {{ text = _("Filter…"),
       align = "left",
       callback = function()
            UIManager:close(dialog)
            self_ref:_showFilterMenu(counts)
       end,
    }})

    -- Search
    table.insert(buttons, {{ text = self._search_string and T(_("Search: \"%1\""), self._search_string) or _("Search…"),
       align = "left",
       callback = function()
            UIManager:close(dialog)
            self_ref:_showSearchDialog()
       end,
    }})

    -- Select All Visible
    table.insert(buttons, {{ text = _("Select All Visible"), align = "left", callback = function()
        UIManager:close(dialog)
        local filtered = getFilteredEntries(self_ref._entries, self_ref._filter, self_ref._search_string)
        for _idx, entry in ipairs(filtered) do
            if not self_ref._selected[entry.file] then
                self_ref._selected[entry.file] = true
            end
        end
        self_ref:_refresh()
    end }})

    -- Clear Selection
    table.insert(buttons, {{ text = _("Clear Selection"), align = "left", callback = function()
        UIManager:close(dialog)
        for k, _v in pairs(self_ref._selected) do
            self_ref._selected[k] = nil
        end
        self_ref:_refresh()
    end }})

    dialog = ButtonDialog:new{
        buttons = buttons,
        shrink_unneeded_width = true,
        anchor = function()
            return self_ref._menu.title_bar.left_button.image.dimen, true
        end,
    }
    UIManager:show(dialog)
end

--- Show filter selection menu
--- @param counts table Map of filter_id → count
function BookPicker:_showFilterMenu(counts)
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
                self_ref:_refresh()
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
                self_ref:_refresh()
            end,
        }})
    end
    local dialog = ButtonDialog:new{
        title = _("Filter by status"),
        buttons = buttons,
        shrink_unneeded_width = true,
        anchor = function()
            return self_ref._menu.title_bar.left_button.image.dimen, true
        end,
    }
    self._filter_dialog = dialog
    UIManager:show(dialog)
end

--- Show search input dialog
function BookPicker:_showSearchDialog()
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
                    self_ref:_refresh()
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
                    self_ref:_refresh()
                end,
            },
        }},
    }
    UIManager:show(search_dialog)
    search_dialog:onShowKeyboard()
end

return BookPicker
