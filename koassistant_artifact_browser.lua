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
local PinnedManager = require("koassistant_pinned_manager")
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

    -- Load pinned index for merging
    local pinned_index = PinnedManager.getPinnedIndex()
    local has_general_pinned = pinned_index[PinnedManager.GENERAL_KEY] and pinned_index[PinnedManager.GENERAL_KEY].count > 0
    local has_multi_pinned = pinned_index[PinnedManager.MULTI_BOOK_KEY] and pinned_index[PinnedManager.MULTI_BOOK_KEY].count > 0

    -- Handle empty state (no artifacts AND no pinned)
    if #docs == 0 and not has_general_pinned and not has_multi_pinned then
        -- Check if any per-book pinned exist
        local has_any_pinned = false
        for doc_path, _stats in pairs(pinned_index) do
            if doc_path ~= PinnedManager.GENERAL_KEY and doc_path ~= PinnedManager.MULTI_BOOK_KEY then
                has_any_pinned = true
                break
            end
        end
        if not has_any_pinned then
            UIManager:show(InfoMessage:new{
                text = _("No artifacts yet.\n\nRun X-Ray, Recap, Document Summary, or Document Analysis to create reusable artifacts.\n\nYou can also pin chat responses as artifacts from the chat viewer."),
                timeout = 5,
            })
            return
        end
    end

    -- Sort by last modified (newest first)
    table.sort(docs, function(a, b) return a.modified > b.modified end)

    -- Build menu items
    local menu_items = {}
    local self_ref = self
    local enable_emoji = opts and opts.enable_emoji

    -- Insert General Pinned section at top (if exists)
    if has_general_pinned then
        local gp = pinned_index[PinnedManager.GENERAL_KEY]
        local date_str = gp.modified > 0 and os.date("%Y-%m-%d", gp.modified) or ""
        table.insert(menu_items, {
            text = Constants.getEmojiText("\u{1F4CC}", _("General (Pinned)"), enable_emoji),
            mandatory = tostring(gp.count) .. " \u{00B7} " .. date_str,
            mandatory_dim = true,
            callback = function()
                local entries = PinnedManager.getGeneralPinned()
                self_ref:showPinnedList(entries, _("General (Pinned)"), PinnedManager.GENERAL_KEY, opts)
            end,
        })
    end

    -- Insert Multi-Book Pinned section (if exists)
    if has_multi_pinned then
        local mp = pinned_index[PinnedManager.MULTI_BOOK_KEY]
        local date_str = mp.modified > 0 and os.date("%Y-%m-%d", mp.modified) or ""
        table.insert(menu_items, {
            text = Constants.getEmojiText("\u{1F4CC}", _("Multi-Book (Pinned)"), enable_emoji),
            mandatory = tostring(mp.count) .. " \u{00B7} " .. date_str,
            mandatory_dim = true,
            callback = function()
                local entries = PinnedManager.getMultiBookPinned()
                self_ref:showPinnedList(entries, _("Multi-Book (Pinned)"), PinnedManager.MULTI_BOOK_KEY, opts)
            end,
        })
    end

    -- Merge per-book pinned counts into docs, and add docs that only have pinned (no cache)
    local docs_by_path = {}
    for _idx, doc in ipairs(docs) do
        docs_by_path[doc.path] = doc
    end
    for doc_path, pstats in pairs(pinned_index) do
        if doc_path ~= PinnedManager.GENERAL_KEY and doc_path ~= PinnedManager.MULTI_BOOK_KEY then
            local existing = docs_by_path[doc_path]
            if existing then
                existing.pinned_count = pstats.count
                -- Use newer timestamp between cache and pinned
                if (pstats.modified or 0) > (existing.modified or 0) then
                    existing.modified = pstats.modified
                end
            else
                -- Book only has pinned artifacts (no cache)
                local title, author = getBookMetadata(doc_path)
                local doc = {
                    path = doc_path,
                    title = title,
                    author = author,
                    modified = pstats.modified or 0,
                    count = 0,
                    pinned_count = pstats.count,
                }
                table.insert(docs, doc)
            end
        end
    end

    -- Re-sort after merge (pinned-only docs may be newer)
    table.sort(docs, function(a, b) return a.modified > b.modified end)

    for _idx, doc in ipairs(docs) do
        local captured_doc = doc
        local date_str = doc.modified > 0 and os.date("%Y-%m-%d", doc.modified) or _("Unknown")
        local total_count = (doc.count or 0) + (doc.pinned_count or 0)
        local count_str = tostring(total_count)
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
    -- Load all artifacts including pinned
    local all_artifacts = ActionCache.getAvailableArtifactsWithPinned(doc_path)

    if #all_artifacts == 0 then
        -- All artifacts were removed since index was built; clean up and refresh
        local index = G_reader_settings:readSetting("koassistant_artifact_index", {})
        index[doc_path] = nil
        G_reader_settings:saveSetting("koassistant_artifact_index", index)
        G_reader_settings:flush()
        -- Also clean pinned index if no pinned remain
        local pindex = G_reader_settings:readSetting("koassistant_pinned_index", {})
        if pindex[doc_path] then
            pindex[doc_path] = nil
            G_reader_settings:saveSetting("koassistant_pinned_index", pindex)
            G_reader_settings:flush()
        end
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

    -- Build buttons for all artifacts (cached + pinned)
    local self_ref = self
    local enable_emoji = opts and opts.enable_emoji
    local buttons = {}
    for _idx, artifact in ipairs(all_artifacts) do
        local captured = artifact
        local display_name
        if captured.is_pinned then
            local pin_label = Constants.getEmojiText("\u{1F4CC}", "", enable_emoji)
            display_name = pin_label .. (captured.name or _("Pinned")) .. " (" .. _("Pinned") .. ")"
        else
            display_name = captured.name
        end
        table.insert(buttons, {{
            text = _("View") .. " " .. display_name,
            callback = function()
                UIManager:close(self_ref._cache_selector)
                if captured.is_pinned then
                    self_ref:showPinnedViewer(captured.data, doc_path, opts)
                elseif captured.is_per_action then
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

--- Show list of pinned artifacts for a given context
--- @param entries table Array of pinned entries
--- @param title string Menu title
--- @param context_path string Document path or special key
--- @param opts table|nil Config passed through for refresh
function ArtifactBrowser:showPinnedList(entries, title, context_path, opts)
    if #entries == 0 then
        UIManager:show(InfoMessage:new{
            text = _("No pinned artifacts."),
            timeout = 2,
        })
        return
    end

    local self_ref = self
    local enable_emoji = opts and opts.enable_emoji
    local menu_items = {}

    for _idx, entry in ipairs(entries) do
        local captured = entry
        local date_str = entry.timestamp > 0 and os.date("%Y-%m-%d", entry.timestamp) or ""
        local display_text = Constants.getEmojiText("\u{1F4CC}", captured.action_text or _("Chat"), enable_emoji)
        if captured.book_title then
            display_text = display_text .. " \u{00B7} " .. captured.book_title
        end

        table.insert(menu_items, {
            text = display_text,
            mandatory = (captured.model or "") .. " \u{00B7} " .. date_str,
            mandatory_dim = true,
            callback = function()
                self_ref:showPinnedViewer(captured, context_path, opts)
            end,
            hold_callback = function()
                self_ref:showPinnedOptions(captured, context_path, opts)
            end,
        })
    end

    -- Close existing menu if re-showing
    if self.current_pinned_menu then
        UIManager:close(self.current_pinned_menu)
        self.current_pinned_menu = nil
    end

    local menu = Menu:new{
        title = title,
        item_table = menu_items,
        is_borderless = true,
        is_popout = false,
        width = Screen:getWidth(),
        height = Screen:getHeight(),
        onMenuSelect = function(_self_menu, item)
            if item and item.callback then item.callback() end
            return true
        end,
        onMenuHold = function(_self_menu, item)
            if item and item.hold_callback then item.hold_callback() end
            return true
        end,
        onReturn = function()
            if self_ref.current_pinned_menu then
                UIManager:close(self_ref.current_pinned_menu)
                self_ref.current_pinned_menu = nil
            end
            UIManager:nextTick(function()
                self_ref:showArtifactBrowser(opts)
            end)
        end,
        multilines_show_more_text = true,
        items_max_lines = 2,
        single_line = false,
        multilines_forced = true,
        items_font_size = 18,
        items_mandatory_font_size = 14,
    }

    menu.close_callback = function()
        if self_ref.current_pinned_menu == menu then
            self_ref.current_pinned_menu = nil
        end
    end

    -- Enable return button (back arrow to artifact browser)
    menu.paths = menu.paths or {}
    table.insert(menu.paths, true)
    if menu.page_return_arrow then
        menu.page_return_arrow:show()
        menu.page_return_arrow:enableDisable(true)
    end

    self.current_pinned_menu = menu
    UIManager:show(menu)
end

--- Show a pinned artifact in simple_view
--- @param entry table Pinned entry
--- @param context_path string Document path or special key
--- @param opts table|nil Config for refresh
function ArtifactBrowser:showPinnedViewer(entry, context_path, opts)
    local AskGPT = self:getAskGPTInstance()
    if not AskGPT then
        UIManager:show(InfoMessage:new{ text = _("Could not open viewer.") })
        return
    end

    local self_ref = self
    local ChatGPTViewer = require("koassistant_chatgptviewer")

    -- Build info text
    local info_parts = {}
    if entry.model and entry.model ~= "" then
        table.insert(info_parts, _("Model") .. ": " .. entry.model)
    end
    if entry.timestamp and entry.timestamp > 0 then
        table.insert(info_parts, _("Pinned") .. ": " .. os.date("%B %d, %Y", entry.timestamp))
    end
    if entry.user_prompt and entry.user_prompt ~= "" then
        local preview = entry.user_prompt:sub(1, 200)
        if #entry.user_prompt > 200 then preview = preview .. "..." end
        table.insert(info_parts, _("Prompt") .. ": " .. preview)
    end

    local viewer = ChatGPTViewer:new{
        title = (entry.action_text or _("Pinned")) .. " (" .. _("Pinned") .. ")",
        text = entry.result or "",
        simple_view = true,
        cache_type_name = _("pinned artifact"),
        cache_metadata = {
            cache_type = "pinned",
            book_title = entry.book_title,
            book_author = entry.book_author,
            model = entry.model,
            timestamp = entry.timestamp,
        },
        _info_text = #info_parts > 0 and table.concat(info_parts, "\n") or nil,
        on_delete = function()
            PinnedManager.removePin(context_path, entry.id)
            UIManager:show(Notification:new{
                text = _("Pinned artifact removed"),
                timeout = 2,
            })
            -- Refresh the pinned list if open
            if self_ref.current_pinned_menu then
                UIManager:close(self_ref.current_pinned_menu)
                self_ref.current_pinned_menu = nil
                local entries = PinnedManager.getPinnedForDocument(context_path)
                if #entries > 0 then
                    self_ref:showPinnedList(entries, _("Pinned"), context_path, opts)
                end
            end
            -- Refresh main browser if open
            if self_ref.current_menu then
                UIManager:close(self_ref.current_menu)
                self_ref.current_menu = nil
                self_ref:showArtifactBrowser(opts)
            end
        end,
    }
    UIManager:show(viewer)
end

--- Show options for a pinned artifact (hold menu)
--- @param entry table Pinned entry
--- @param context_path string Document path or special key
--- @param opts table|nil Config for refresh
function ArtifactBrowser:showPinnedOptions(entry, context_path, opts)
    local self_ref = self
    local dialog
    dialog = ButtonDialog:new{
        title = entry.action_text or _("Pinned"),
        buttons = {
            {
                {
                    text = _("View"),
                    callback = function()
                        UIManager:close(dialog)
                        self_ref:showPinnedViewer(entry, context_path, opts)
                    end,
                },
            },
            {
                {
                    text = _("Delete"),
                    callback = function()
                        UIManager:close(dialog)
                        UIManager:show(ConfirmBox:new{
                            text = _("Delete this pinned artifact?\n\nThis cannot be undone."),
                            ok_text = _("Delete"),
                            ok_callback = function()
                                PinnedManager.removePin(context_path, entry.id)
                                UIManager:show(Notification:new{
                                    text = _("Pinned artifact removed"),
                                    timeout = 2,
                                })
                                -- Refresh pinned list
                                if self_ref.current_pinned_menu then
                                    UIManager:close(self_ref.current_pinned_menu)
                                    self_ref.current_pinned_menu = nil
                                    local entries = PinnedManager.getPinnedForDocument(context_path)
                                    if #entries > 0 then
                                        self_ref:showPinnedList(entries, _("Pinned"), context_path, opts)
                                    end
                                end
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
