--[[--
Book Picker for KOAssistant

Multi-select book picker for multi-book actions.
Shows reading history as a selectable list; selected books are passed
to compareSelectedBooks() for the standard multi-book action flow.

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

--- Count selected entries in a hash table
--- @param selected table Hash of selected file paths
--- @return number count
local function countSelected(selected)
    local n = 0
    for _ in pairs(selected) do n = n + 1 end
    return n
end

--- Get book title and author from DocSettings metadata
--- @param doc_path string The document file path
--- @return string title The book title
--- @return string|nil author The book author, or nil
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
    return title, author
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
            local title, author = getBookMetadata(hist_entry.file)
            table.insert(entries, {
                file = hist_entry.file,
                title = title,
                author = author,
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

    -- Toggle selection for an entry and refresh the menu
    local function toggleEntry(entry)
        if selected[entry.file] then
            selected[entry.file] = nil
        else
            selected[entry.file] = true
        end
        self_ref:_refresh(menu, entries, selected)
    end

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

    local menu_items = buildMenuItems(entries, selected, toggleEntry)

    menu = Menu:new{
        title = T(_("Select Books (%1 selected)"), countSelected(selected)),
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

--- Refresh menu items and title after selection change
--- @param menu userdata The Menu widget
--- @param entries table Array of book entries
--- @param selected table Hash of selected file paths
function BookPicker:_refresh(menu, entries, selected)
    local self_ref = self
    local function toggleEntry(entry)
        if selected[entry.file] then
            selected[entry.file] = nil
        else
            selected[entry.file] = true
        end
        self_ref:_refresh(menu, entries, selected)
    end

    local items = buildMenuItems(entries, selected, toggleEntry)
    menu:switchItemTable(T(_("Select Books (%1 selected)"), countSelected(selected)), items, -1)
end

--- Show picker options menu (hamburger)
--- @param menu userdata The Menu widget
--- @param entries table Array of book entries
--- @param selected table Hash of selected file paths
--- @param confirm_callback function Called to confirm selection
function BookPicker:_showPickerOptions(menu, entries, selected, confirm_callback)
    local self_ref = self
    local cur_count = countSelected(selected)
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
            {{ text = _("Select All"), align = "left", callback = function()
                UIManager:close(dialog)
                for _idx, entry in ipairs(entries) do
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

return BookPicker
