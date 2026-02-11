--[[--
Notebook Manager for KOAssistant

Browser UI for viewing all notebooks across documents.
- Shows list of documents with notebooks (sorted by last modified)
- Tap for options menu (View, Edit, Delete)
- Auto-cleanup stale index entries

@module koassistant_notebook_manager
]]

local ButtonDialog = require("ui/widget/buttondialog")
local ConfirmBox = require("ui/widget/confirmbox")
local DocSettings = require("docsettings")
local InfoMessage = require("ui/widget/infomessage")
local Menu = require("ui/widget/menu")
local Screen = require("device").screen
local UIManager = require("ui/uimanager")
local logger = require("logger")
local Constants = require("koassistant_constants")
local _ = require("koassistant_gettext")

local NotebookManager = {}

--- Show the notebook browser (list of all documents with notebooks)
--- @param opts table|nil Optional config: { enable_emoji = bool }
function NotebookManager:showNotebookBrowser(opts)
    local Notebook = require("koassistant_notebook")
    local index = G_reader_settings:readSetting("koassistant_notebook_index", {})
    local needs_cleanup = false

    -- Build sorted list (newest first), validate entries exist
    local docs = {}
    for doc_path, stats in pairs(index) do
        if Notebook.exists(doc_path) then
            -- Get book title and author from metadata, falling back to filename
            local doc_settings = DocSettings:open(doc_path)
            local doc_props = doc_settings:readSetting("doc_props")
            local title = (doc_props and doc_props.title and doc_props.title ~= "") and doc_props.title
                or doc_path:match("([^/]+)%.[^%.]+$") or doc_path
            local author = doc_props and doc_props.authors or nil
            table.insert(docs, {
                path = doc_path,
                title = title,
                author = author,
                modified = stats.modified or 0,
                size = stats.size or 0,
            })
        else
            -- Stale entry - file no longer exists
            index[doc_path] = nil
            needs_cleanup = true
            logger.dbg("KOAssistant Notebook: Cleaning stale index entry:", doc_path)
        end
    end

    -- Persist cleanup if needed
    if needs_cleanup then
        G_reader_settings:saveSetting("koassistant_notebook_index", index)
        G_reader_settings:flush()
        logger.info("KOAssistant Notebook: Cleaned up stale index entries")
    end

    -- Handle empty state
    if #docs == 0 then
        UIManager:show(InfoMessage:new{
            text = _("No notebooks yet.\n\nUse the NB button in chat viewer to save conversations to a per-book notebook."),
            timeout = 5,
        })
        return
    end

    -- Sort by last modified (newest first)
    table.sort(docs, function(a, b) return a.modified > b.modified end)

    -- Build menu items
    local menu_items = {}
    local self_ref = self

    local enable_emoji = opts and opts.enable_emoji
    for _idx, doc in ipairs(docs) do
        local captured_doc = doc
        local date_str = doc.modified > 0 and os.date("%Y-%m-%d", doc.modified) or _("Unknown")

        local display_text = doc.title
        if doc.author and doc.author ~= "" then
            display_text = display_text .. " \u{00B7} " .. doc.author
        end
        display_text = Constants.getEmojiText("\u{1F4D3}", display_text, enable_emoji)

        table.insert(menu_items, {
            text = display_text,
            mandatory = date_str,
            mandatory_dim = true,
            help_text = doc.path,
            callback = function()
                self_ref:showNotebookOptions(captured_doc.path, captured_doc.title)
            end,
        })
    end

    -- Create menu
    local menu = Menu:new{
        title = _("Notebooks"),
        item_table = menu_items,
        is_borderless = true,
        is_popout = false,
        width = Screen:getWidth(),
        height = Screen:getHeight(),
        multilines_show_more_text = true,
        items_max_lines = 2,
        single_line = false,
        multilines_forced = true,
        items_font_size = 18,
        items_mandatory_font_size = 14,
        close_callback = function()
            self_ref.current_menu = nil
        end,
    }

    self.current_menu = menu
    UIManager:show(menu)
end

--- Show options menu for a notebook
--- @param doc_path string The document file path
--- @param doc_title string The document title for display
function NotebookManager:showNotebookOptions(doc_path, doc_title)
    local Notebook = require("koassistant_notebook")
    local notebook_path = Notebook.getPath(doc_path)
    local self_ref = self

    local dialog
    dialog = ButtonDialog:new{
        title = doc_title,
        buttons = {
            {
                {
                    text = _("View"),
                    callback = function()
                        UIManager:close(dialog)
                        -- Close browser and open in view mode
                        if self_ref.current_menu then
                            UIManager:close(self_ref.current_menu)
                            self_ref.current_menu = nil
                        end
                        local AskGPT = self_ref:getAskGPTInstance()
                        if AskGPT then
                            AskGPT:openNotebookForFile(doc_path)  -- view mode
                        end
                    end,
                },
                {
                    text = _("Edit"),
                    callback = function()
                        UIManager:close(dialog)
                        -- Close browser and open in edit mode
                        if self_ref.current_menu then
                            UIManager:close(self_ref.current_menu)
                            self_ref.current_menu = nil
                        end
                        local AskGPT = self_ref:getAskGPTInstance()
                        if AskGPT then
                            AskGPT:openNotebookForFile(doc_path, true)  -- edit mode
                        end
                    end,
                },
            },
            {
                {
                    text = _("Delete"),
                    callback = function()
                        UIManager:close(dialog)
                        UIManager:show(ConfirmBox:new{
                            text = _("Delete this notebook?\n\nThis cannot be undone."),
                            ok_text = _("Delete"),
                            ok_callback = function()
                                -- Delete file
                                local ok, err = os.remove(notebook_path)
                                if ok == nil and err then
                                    logger.warn("KOAssistant Notebook: Failed to delete:", err)
                                end
                                -- Update index
                                local AskGPT = self_ref:getAskGPTInstance()
                                if AskGPT then
                                    AskGPT:updateNotebookIndex(doc_path, "remove")
                                end
                                -- Refresh view (re-show browser)
                                self_ref:showNotebookBrowser()
                            end,
                        })
                    end,
                },
            },
            {
                {
                    text = _("Cancel"),
                    callback = function()
                        UIManager:close(dialog)
                    end,
                },
            },
        },
    }
    UIManager:show(dialog)
end

--- Get AskGPT plugin instance
--- @return table|nil AskGPT The plugin instance or nil
function NotebookManager:getAskGPTInstance()
    -- Try to get from FileManager first
    local FileManager = require("apps/filemanager/filemanager")
    if FileManager.instance and FileManager.instance.koassistant then
        return FileManager.instance.koassistant
    end

    -- Try to get from ReaderUI
    local ReaderUI = require("apps/reader/readerui")
    if ReaderUI.instance and ReaderUI.instance.koassistant then
        return ReaderUI.instance.koassistant
    end

    logger.warn("KOAssistant Notebook: Could not get AskGPT instance")
    return nil
end

return NotebookManager
