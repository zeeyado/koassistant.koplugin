--[[--
Artifact Browser for KOAssistant

Browser UI for viewing all documents with cached artifacts (X-Ray, Summary, Analysis, Recap, X-Ray Simple, Book Info, Notes Analysis).
- One entry per document, sorted by most recent artifact date
- Tap to show artifact selector popup (same as "View Artifacts" elsewhere)
- Hold for delete options
- Auto-cleanup stale index entries

@module koassistant_artifact_browser
]]

local ActionCache = require("koassistant_action_cache")
local ButtonDialog = require("ui/widget/buttondialog")
local ConfirmBox = require("ui/widget/confirmbox")
local DocSettings = require("docsettings")
local InfoMessage = require("ui/widget/infomessage")
local Menu = require("ui/widget/menu")
local Notification = require("ui/widget/notification")
local Screen = require("device").screen
local UIManager = require("ui/uimanager")
local logger = require("logger")
local Constants = require("koassistant_constants")
local _ = require("koassistant_gettext")

local ArtifactBrowser = {}

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
    return title, author
end

--- Show the artifact browser (list of documents with artifacts)
--- @param opts table|nil Optional config: { enable_emoji = bool }
function ArtifactBrowser:showArtifactBrowser(opts)
    local lfs = require("libs/libkoreader-lfs")
    -- One-time migration: scan known document paths for existing cache files
    local migration_version = G_reader_settings:readSetting("koassistant_artifact_index_version")
    if not migration_version or migration_version < 1 then
        self:migrateExistingArtifacts()
        G_reader_settings:saveSetting("koassistant_artifact_index_version", 1)
        G_reader_settings:flush()
    end

    local index = G_reader_settings:readSetting("koassistant_artifact_index", {})
    local needs_cleanup = false

    -- Build sorted list (newest first), validate entries exist
    local docs = {}
    for doc_path, stats in pairs(index) do
        local cache_path = ActionCache.getPath(doc_path)
        if cache_path and lfs.attributes(cache_path, "mode") == "file" then
            local title, author = getBookMetadata(doc_path)
            table.insert(docs, {
                path = doc_path,
                title = title,
                author = author,
                modified = stats.modified or 0,
                count = stats.count or 0,
            })
        else
            -- Stale entry - cache file no longer exists
            index[doc_path] = nil
            needs_cleanup = true
            logger.dbg("KOAssistant Artifacts: Cleaning stale index entry:", doc_path)
        end
    end

    -- Persist cleanup if needed
    if needs_cleanup then
        G_reader_settings:saveSetting("koassistant_artifact_index", index)
        G_reader_settings:flush()
        logger.info("KOAssistant Artifacts: Cleaned up stale index entries")
    end

    -- Handle empty state
    if #docs == 0 then
        UIManager:show(InfoMessage:new{
            text = _("No artifacts yet.\n\nRun X-Ray, Recap, Document Summary, or Document Analysis to create reusable artifacts."),
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
        local count_str = tostring(doc.count)
        local right_text = count_str .. " \u{00B7} " .. date_str

        local display_text = doc.title
        if doc.author and doc.author ~= "" then
            display_text = display_text .. " \u{00B7} " .. doc.author
        end
        display_text = Constants.getEmojiText("\u{1F4D6}", display_text, enable_emoji)

        table.insert(menu_items, {
            text = display_text,
            mandatory = right_text,
            mandatory_dim = true,
            help_text = doc.path,
            callback = function()
                self_ref:showArtifactSelector(captured_doc.path, captured_doc.title, opts)
            end,
            hold_callback = function()
                self_ref:showDocumentOptions(captured_doc, opts)
            end,
        })
    end

    -- Close existing menu if re-showing (e.g., after delete)
    if self.current_menu then
        UIManager:close(self.current_menu)
        self.current_menu = nil
    end

    local menu = Menu:new{
        title = _("Artifacts"),
        item_table = menu_items,
        is_borderless = true,
        is_popout = false,
        width = Screen:getWidth(),
        height = Screen:getHeight(),
        title_bar_left_icon = "appbar.menu",
        onLeftButtonTap = function()
            self_ref:showBrowserMenuOptions(opts)
        end,
        -- Override onMenuSelect to prevent close_callback from firing on item tap.
        onMenuSelect = function(_self_menu, item)
            if item and item.callback then item.callback() end
            return true
        end,
        onMenuHold = function(_self_menu, item)
            if item and item.hold_callback then item.hold_callback() end
            return true
        end,
        multilines_show_more_text = true,
        items_max_lines = 2,
        single_line = false,
        multilines_forced = true,
        items_font_size = 18,
        items_mandatory_font_size = 14,
    }

    -- close_callback: only fires from onCloseAllMenus (back/X button),
    -- NOT from item tap (we override onMenuSelect above).
    menu.close_callback = function()
        if self_ref.current_menu == menu then
            self_ref.current_menu = nil
        end
    end

    self.current_menu = menu
    UIManager:show(menu)
end

--- Show artifact selector popup for a document (same pattern as "View Artifacts" elsewhere)
--- @param doc_path string The document file path
--- @param doc_title string The document title
--- @param opts table|nil Config passed through for refresh
function ArtifactBrowser:showArtifactSelector(doc_path, doc_title, opts)
    -- Load actual cache and discover which artifacts exist
    local caches = ActionCache.getAvailableArtifacts(doc_path)

    if #caches == 0 then
        -- All artifacts were removed since index was built; clean up and refresh
        local index = G_reader_settings:readSetting("koassistant_artifact_index", {})
        index[doc_path] = nil
        G_reader_settings:saveSetting("koassistant_artifact_index", index)
        G_reader_settings:flush()
        UIManager:show(InfoMessage:new{
            text = _("No artifacts found for this document."),
        })
        self:showArtifactBrowser(opts)
        return
    end

    local AskGPT = self:getAskGPTInstance()
    if not AskGPT then
        UIManager:show(InfoMessage:new{ text = _("Could not open viewer.") })
        return
    end

    -- Always show popup selector (with View prefix and Open Book option)
    local self_ref = self
    local buttons = {}
    for _idx, cache in ipairs(caches) do
        local captured = cache
        table.insert(buttons, {{
            text = _("View") .. " " .. captured.name,
            callback = function()
                UIManager:close(self_ref._cache_selector)
                if captured.is_per_action then
                    AskGPT:viewCachedAction(
                        { text = captured.name }, captured.key, captured.data,
                        { file = doc_path, book_title = doc_title })
                else
                    AskGPT:showCacheViewer({
                        name = captured.name, key = captured.key, data = captured.data,
                        book_title = doc_title, file = doc_path })
                end
            end,
        }})
    end
    table.insert(buttons, {{
        text = _("Open Book"),
        callback = function()
            UIManager:close(self_ref._cache_selector)
            if self_ref.current_menu then
                UIManager:close(self_ref.current_menu)
                self_ref.current_menu = nil
            end
            local ReaderUI = require("apps/reader/readerui")
            ReaderUI:showReader(doc_path)
        end,
    }})
    table.insert(buttons, {{
        text = _("Cancel"),
        callback = function()
            UIManager:close(self._cache_selector)
        end,
    }})

    self._cache_selector = ButtonDialog:new{
        title = doc_title,
        buttons = buttons,
    }
    UIManager:show(self._cache_selector)
end

--- Show options for a document's artifacts (hold menu)
--- @param doc table The document entry: { path, title, count }
--- @param opts table|nil Config passed through for refresh
function ArtifactBrowser:showDocumentOptions(doc, opts)
    local self_ref = self

    local dialog
    dialog = ButtonDialog:new{
        title = doc.title,
        buttons = {
            {
                {
                    text = _("View"),
                    callback = function()
                        UIManager:close(dialog)
                        self_ref:showArtifactSelector(doc.path, doc.title, opts)
                    end,
                },
            },
            {
                {
                    text = _("Delete All"),
                    callback = function()
                        UIManager:close(dialog)
                        UIManager:show(ConfirmBox:new{
                            text = _("Delete all artifacts for this document?\n\nThis cannot be undone."),
                            ok_text = _("Delete"),
                            ok_callback = function()
                                ActionCache.clearAll(doc.path)
                                -- Invalidate file browser row cache
                                local AskGPT = self_ref:getAskGPTInstance()
                                if AskGPT then
                                    AskGPT._file_dialog_row_cache = { file = nil, rows = nil }
                                end
                                UIManager:show(Notification:new{
                                    text = _("All artifacts deleted"),
                                    timeout = 2,
                                })
                                -- Refresh browser
                                self_ref:showArtifactBrowser(opts)
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

--- One-time migration: scan known document paths for existing cache files.
--- Checks ReadHistory, chat index, and notebook index for known document paths,
--- then refreshes the artifact index for any that have cache files.
function ArtifactBrowser:migrateExistingArtifacts()
    logger.info("KOAssistant Artifacts: Running one-time migration for existing artifacts")
    local lfs = require("libs/libkoreader-lfs")

    -- Collect unique document paths from all known sources
    local doc_paths = {}

    -- Source 1: KOReader reading history (most complete — all books ever opened)
    local ok, ReadHistory = pcall(require, "readhistory")
    if ok and ReadHistory and ReadHistory.hist then
        for _idx, item in ipairs(ReadHistory.hist) do
            if item.file then
                doc_paths[item.file] = true
            end
        end
    end

    -- Source 2: Chat index
    local chat_index = G_reader_settings:readSetting("koassistant_chat_index", {})
    for doc_path, _val in pairs(chat_index) do
        if doc_path ~= "__GENERAL_CHATS__" and doc_path ~= "__MULTI_BOOK_CHATS__" then
            doc_paths[doc_path] = true
        end
    end

    -- Source 3: Notebook index
    local notebook_index = G_reader_settings:readSetting("koassistant_notebook_index", {})
    for doc_path, _val in pairs(notebook_index) do
        doc_paths[doc_path] = true
    end

    -- Check each path for a cache file and refresh
    local found = 0
    for doc_path, _val in pairs(doc_paths) do
        local cache_path = ActionCache.getPath(doc_path)
        if cache_path and lfs.attributes(cache_path, "mode") == "file" then
            ActionCache.refreshIndex(doc_path)
            found = found + 1
        end
    end

    logger.info("KOAssistant Artifacts: Migration complete, scanned", next(doc_paths) and "documents" or "0 documents", ", found", found, "with artifacts")
end

--- Show hamburger menu with cross-browser navigation
--- @param opts table|nil Config passed through for refresh
function ArtifactBrowser:showBrowserMenuOptions(opts)
    local self_ref = self
    local dialog

    local function navClose()
        UIManager:close(dialog)
        if self_ref._cache_selector then
            UIManager:close(self_ref._cache_selector)
            self_ref._cache_selector = nil
        end
        local menu_to_close = self_ref.current_menu
        self_ref.current_menu = nil
        return menu_to_close
    end

    dialog = ButtonDialog:new{
        buttons = {
            {{ text = _("Chat History"), align = "left", callback = function()
                local mc = navClose()
                UIManager:nextTick(function()
                    if mc then UIManager:close(mc) end
                    local AskGPT = self_ref:getAskGPTInstance()
                    if AskGPT then AskGPT:showChatHistory() end
                end)
            end }},
            {{ text = _("Notebooks"), align = "left", callback = function()
                local mc = navClose()
                UIManager:nextTick(function()
                    if mc then UIManager:close(mc) end
                    local AskGPT = self_ref:getAskGPTInstance()
                    if AskGPT then AskGPT:showNotebookBrowser() end
                end)
            end }},
        },
        shrink_unneeded_width = true,
        anchor = function()
            return self_ref.current_menu.title_bar.left_button.image.dimen, true
        end,
    }
    UIManager:show(dialog)
end

--- Get AskGPT plugin instance
--- @return table|nil AskGPT The plugin instance or nil
function ArtifactBrowser:getAskGPTInstance()
    local FileManager = require("apps/filemanager/filemanager")
    if FileManager.instance and FileManager.instance.koassistant then
        return FileManager.instance.koassistant
    end

    local ReaderUI = require("apps/reader/readerui")
    if ReaderUI.instance and ReaderUI.instance.koassistant then
        return ReaderUI.instance.koassistant
    end

    logger.warn("KOAssistant Artifacts: Could not get AskGPT instance")
    return nil
end

return ArtifactBrowser
