--[[--
Artifact Browser for KOAssistant

Browser UI for viewing all documents with cached artifacts (X-Ray, Summary, Analysis, Recap, X-Ray Simple, About, Notes Analysis).
- One entry per document, sorted by most recent artifact date
- Tap to show artifact selector popup (same as "View Artifacts" elsewhere)
- Hold for delete options
- Auto-cleanup stale index entries

@module koassistant.artifacts.artifact_browser
]]

local ActionCache = require("koassistant.artifacts.action_cache")
local ButtonDialog = require("ui/widget/buttondialog")
local ConfirmBox = require("ui/widget/confirmbox")
local DocSettings = require("docsettings")
local SafeDocSettings = require("koassistant.storage.doc_settings")
local InfoMessage = require("ui/widget/infomessage")
local Menu = require("ui/widget/menu")
local Notification = require("ui/widget/notification")
local PinnedManager = require("koassistant.artifacts.pinned_manager")
local Screen = require("device").screen
local UIManager = require("ui/uimanager")
local logger = require("koassistant.core.logger")
local Constants = require("koassistant.core.constants")
local T = require("ffi/util").template
local _ = require("koassistant.core.gettext")

local ArtifactBrowser = {}

--- Get book title and author from DocSettings metadata
--- @param doc_path string The document file path
--- @return string title The book title
--- @return string|nil author The book author, or nil
local function getBookMetadata(doc_path)
    local doc_settings = DocSettings:open(doc_path)
    local doc_props = SafeDocSettings.overlayCustomProps(doc_settings:readSetting("doc_props"), doc_path)
    local title = doc_props and (doc_props.display_title or doc_props.title) or nil
    if not title or title == "" then
        title = doc_path:match("([^/]+)%.[^%.]+$") or doc_path
    end
    local author = doc_props and doc_props.authors or nil
    return title, author
end

--- The open book's document when it is this book (a section's page range is
--- recomputed from it); nil for any other book, whose stored range stands
local function openDocFor(AskGPT, doc_path)
    local doc = AskGPT and AskGPT.ui and AskGPT.ui.document
    if doc and SafeDocSettings.samePath(doc.file, doc_path) then return doc end
    return nil
end

--- Shared select-mode tail for every leaf pick (attach_plan.md v1): a refusal
--- (quiz/empty artifact) shows the reason and KEEPS the picker open; a success
--- closes the given dialog, runs the parent-close callback, closes the browser
--- menu, and hands the built entry to the select callback.
local function finishLeafSelect(self, opts, entry, err, dialog, parent_close)
    if not entry then
        UIManager:show(InfoMessage:new{ text = err })
        return
    end
    if dialog then UIManager:close(dialog) end
    if parent_close then parent_close() end
    if self.current_menu then
        UIManager:close(self.current_menu)
        self.current_menu = nil
    end
    opts.select_mode.on_select(entry)
end

--- Every book the browser lists, newest first: a saved artifact (the artifact
--- index, its cache file present; stale entries are dropped and the cleanup
--- saved), a pin (the pinned index) or a generated image (the images index).
--- ONE walk for the browser's list and Browse by type. A book with only
--- pictures takes its title from the images index (no sidecar read).
--- @return table books { { path, title, author, modified, count, pinned_count, image_count } }
--- @return table image_books ImageGenerator.booksWithImages(), for the per-book aggregation
function ArtifactBrowser.artifactBooks()
    local lfs = require("libs/libkoreader-lfs")
    local index = G_reader_settings:readSetting("koassistant_artifact_index", {})
    local books, by_path = {}, {}
    local needs_cleanup = false
    for doc_path, stats in pairs(index) do
        local cache_path = ActionCache.getPath(doc_path)
        if cache_path and lfs.attributes(cache_path, "mode") == "file" then
            local book = { path = doc_path, modified = stats.modified or 0, count = stats.count or 0 }
            books[#books + 1] = book
            by_path[doc_path] = book
        else
            -- Stale entry - cache file no longer exists
            index[doc_path] = nil
            needs_cleanup = true
            logger.dbg("KOAssistant Artifacts: Cleaning stale index entry:", doc_path)
        end
    end
    if needs_cleanup then
        G_reader_settings:saveSetting("koassistant_artifact_index", index)
        G_reader_settings:flush()
        logger.info("KOAssistant Artifacts: Cleaned up stale index entries")
    end
    -- Per-book pins; a book with only pins still gets a row
    for doc_path, pstats in pairs(PinnedManager.getPinnedIndex()) do
        if doc_path ~= PinnedManager.GENERAL_KEY and doc_path ~= PinnedManager.LIBRARY_KEY then
            local book = by_path[doc_path]
            if not book then
                book = { path = doc_path, modified = 0, count = 0 }
                books[#books + 1] = book
                by_path[doc_path] = book
            end
            book.pinned_count = pstats.count
            if (pstats.modified or 0) > book.modified then book.modified = pstats.modified end
        end
    end
    -- Generated images (book_file → { count, modified, book_title }); a book
    -- with only images still gets a row
    local image_books = require("koassistant.images.image_generator").booksWithImages()
    for book_file, istats in pairs(image_books) do
        local book = by_path[book_file]
        if not book then
            book = { path = book_file, modified = 0, count = 0,
                title = istats.book_title or book_file:match("([^/]+)$") or book_file }
            books[#books + 1] = book
            by_path[book_file] = book
        end
        book.image_count = istats.count
        if (istats.modified or 0) > book.modified then book.modified = istats.modified end
    end
    for _idx, book in ipairs(books) do
        if not book.title then book.title, book.author = getBookMetadata(book.path) end
    end
    table.sort(books, function(a, b) return a.modified > b.modified end)
    return books, image_books
end

--- True when a row opens the full-screen X-Ray browser (showCacheViewer's own
--- routing condition), which the surface under it may have to close for
local function opensXrayBrowser(row)
    local is_xray_key = row.key == ActionCache.XRAY_CACHE_KEY
        or (type(row.key) == "string"
            and row.key:sub(1, #ActionCache.SECTION_XRAY_PREFIX) == ActionCache.SECTION_XRAY_PREFIX)
    return is_xray_key and row.data and row.data.result
        and require("koassistant.xray.xray_parser").isJSON(row.data.result) and true or false
end

--- A row's progress and age ("65%, today") when it is a saved result; nil for
--- a group row, whose name carries its count. Every View-Artifacts list labels
--- its rows through this and rowLabel, so none reads the group flags itself.
function ArtifactBrowser.rowMeta(row)
    if type(row.data) == "table" and row.data.result then
        return Constants.formatArtifactMeta(row.data)
    end
end

--- A row's label in a View-Artifacts popup: "Recap (6%, today)", or a group
--- row's own name ("AI Wiki Entries (4)")
function ArtifactBrowser.rowLabel(row)
    local meta = ArtifactBrowser.rowMeta(row)
    if meta then return row.name .. " (" .. meta .. ")" end
    return row.name
end

--- THE opener for a row of ActionCache.getAvailableArtifactsWithPinned: the
--- same destination wherever the row is listed (the group flags are that
--- aggregation's contract; docs/artifact_rows_plan.md). ctx:
---   plugin, file, title, author  the book; its identity goes to every viewer,
---       which compares it with the open book itself
---   before_open(dest)  runs once, right before the destination opens (for a
---       group row, when the reader picks an entry of its popup; the popup
---       itself stacks on the surface), so the surface can close what the
---       destination replaces. dest = "xray" (the full-screen X-Ray browser),
---       "viewer" (another artifact window), "gallery" or "versions"
---   close_browser  versions only: runs when a version is viewed, installed or
---       switched to (browsing the list keeps the surface)
---   opts  the artifact browser's opts: in select mode (Attach) a saved result
---       is attached instead of opened, and the group popups pick
function ArtifactBrowser.openRow(row, ctx)
    local plugin, file = ctx.plugin, ctx.file
    -- The open book's own props fill what a surface did not pass: a viewer
    -- given a title no longer falls back to them for the author
    local title, author = ctx.title, ctx.author
    local props = openDocFor(plugin, file) and plugin.ui.doc_props
    if props then
        title = title or props.display_title or props.title
        author = author or props.authors
    end
    local function before(dest)
        if ctx.before_open then ctx.before_open(dest) end
    end
    local function picked(dest)
        return function() before(dest) end
    end
    logger.dbg("KOAssistant Artifacts: open row",
        row.is_image_group and "images"
        or row.is_xray_versions_group and "xray-versions"
        or row.is_section_xray_group and "section-xray-group"
        or row.is_section_group and "section-group"
        or row.is_wiki_group and "wiki-group"
        or row.is_pinned_group and "pinned-group"
        or row.is_per_action and "per-action"
        or "cache-viewer",
        row.key or "?")
    if row.is_image_group then
        before("gallery")
        require("koassistant.images.image_browser").show({
            book_file = file, book_title = title })
    elseif row.is_xray_versions_group then
        before("versions")
        plugin:_showXrayCheckpointList({ file = file,
            book_title = title, book_author = author,
            close_browser = ctx.close_browser })
    elseif row.is_section_xray_group then
        -- A pick opens that section's full-screen X-Ray browser
        ArtifactBrowser:_showSectionXrayGroupPopup(row.data, file, title, plugin,
            row._excluded_section_key, picked("xray"), ctx.opts, author)
    elseif row.is_section_group then
        ArtifactBrowser:_showSectionGroupPopup(row.data, file, title, plugin,
            row.section_type, row._excluded_section_key, picked("viewer"), ctx.opts, author)
    elseif row.is_wiki_group then
        ArtifactBrowser:_showWikiGroupPopup(row.data, file, plugin, title,
            picked("viewer"), ctx.opts, author)
    elseif row.is_pinned_group then
        ArtifactBrowser:_showPinnedGroupPopup(row.data, file, title,
            picked("viewer"), ctx.opts, author)
    elseif ctx.opts and ctx.opts.select_mode then
        -- Attach: the shared build-first tail (a refusal keeps the picker open)
        local entry, err = require("koassistant.request.attachments").makeArtifact(
            row.name, row.key, row.data, title, nil, file)
        finishLeafSelect(ArtifactBrowser, ctx.opts, entry, err, nil, picked("viewer"))
    elseif row.is_per_action then
        before("viewer")
        plugin:viewCachedAction({ text = row.name }, row.key, row.data,
            { file = file, book_title = title, book_author = author })
    else
        before(opensXrayBrowser(row) and "xray" or "viewer")
        plugin:showCacheViewer({ name = row.name, key = row.key, data = row.data,
            file = file, book_title = title, book_author = author })
    end
end

--- Show the artifact browser (list of documents with artifacts)
--- @param opts table|nil Optional config: { enable_emoji = bool }
function ArtifactBrowser:showArtifactBrowser(opts)
    -- One-time migration: scan known document paths for existing cache files
    local migration_version = G_reader_settings:readSetting("koassistant_artifact_index_version")
    if not migration_version or migration_version < 1 then
        self:migrateExistingArtifacts()
        G_reader_settings:saveSetting("koassistant_artifact_index_version", 1)
        G_reader_settings:flush()
    end

    local docs = ArtifactBrowser.artifactBooks()

    -- Pins outside any book get their own rows at the top
    local pinned_index = PinnedManager.getPinnedIndex()
    local has_general_pinned = pinned_index[PinnedManager.GENERAL_KEY] and pinned_index[PinnedManager.GENERAL_KEY].count > 0
    local has_multi_pinned = pinned_index[PinnedManager.LIBRARY_KEY] and pinned_index[PinnedManager.LIBRARY_KEY].count > 0

    -- Handle empty state (no book with artifacts, pins or images, and no general or library pins)
    if #docs == 0 and not has_general_pinned and not has_multi_pinned then
        UIManager:show(InfoMessage:new{
            text = _("No artifacts yet.\n\nRun X-Ray, Recap, Document Summary, or Document Analysis to create reusable artifacts.\n\nYou can also pin chat responses as artifacts from the chat viewer."),
            timeout = 5,
        })
        return
    end

    -- Build menu items
    local menu_items = {}
    local self_ref = self
    local enable_emoji = opts and opts.enable_emoji

    -- Insert General Pinned section at top (if exists)
    if has_general_pinned then
        local gp = pinned_index[PinnedManager.GENERAL_KEY]
        local date_str = gp.modified > 0 and Constants.formatRelativeTime(gp.modified) or ""
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

    -- Insert Library Pinned section (if exists)
    if has_multi_pinned then
        local mp = pinned_index[PinnedManager.LIBRARY_KEY]
        local date_str = mp.modified > 0 and Constants.formatRelativeTime(mp.modified) or ""
        table.insert(menu_items, {
            text = Constants.getEmojiText("\u{1F4CC}", _("Library (Pinned)"), enable_emoji),
            mandatory = tostring(mp.count) .. " \u{00B7} " .. date_str,
            mandatory_dim = true,
            callback = function()
                local entries = PinnedManager.getLibraryPinned()
                self_ref:showPinnedList(entries, _("Library (Pinned)"), PinnedManager.LIBRARY_KEY, opts)
            end,
        })
    end

    for _idx, doc in ipairs(docs) do
        local captured_doc = doc
        local date_str = doc.modified > 0 and Constants.formatRelativeTime(doc.modified) or _("Unknown")
        local total_count = (doc.count or 0) + (doc.pinned_count or 0) + (doc.image_count or 0)
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
            -- Hold options (Delete All…) are destructive — suppressed while
            -- picking an artifact to attach
            hold_callback = not (opts and opts.select_mode) and function()
                self_ref:showDocumentOptions(captured_doc, opts)
            end or nil,
        })
    end

    -- Close existing menu if re-showing (e.g., after delete)
    if self.current_menu then
        UIManager:close(self.current_menu)
        self.current_menu = nil
    end

    local menu = Menu:new{
        -- Select mode (attach_plan.md v1): same browser, tap selects-and-returns.
        -- The left options menu is hidden there — its Chat History/Notebooks
        -- entries open plain browsers that would silently abandon the pick.
        title = (opts and opts.select_mode) and _("Select artifact to attach") or _("Artifacts"),
        item_table = menu_items,
        is_borderless = true,
        is_popout = false,
        width = Screen:getWidth(),
        height = Screen:getHeight(),
        title_bar_left_icon = not (opts and opts.select_mode) and "appbar.menu" or nil,
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
    -- Callers that only know the path (Attach chip) pass nil title
    doc_title = doc_title or getBookMetadata(doc_path)
    -- Load all artifacts including pinned; pass doc for section promotion if this is the open book
    local ReaderUI = require("apps/reader/readerui")
    local open_doc = ReaderUI.instance and ReaderUI.instance.document
        and ReaderUI.instance.document.file == doc_path and ReaderUI.instance.document or nil
    local all_artifacts = ActionCache.getAvailableArtifactsWithPinned(doc_path, nil, open_doc)

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
    local select_mode = opts and opts.select_mode
    local buttons = {}
    for _idx, artifact in ipairs(all_artifacts) do
        local captured = artifact
        local display_name = ArtifactBrowser.rowLabel(captured)
        -- Select mode: image rows aren't text, and archived X-Ray versions are a
        -- management surface (attach the live X-Ray artifact instead) — skip both
        if not (select_mode and (captured.is_image_group or captured.is_xray_versions_group)) then
        table.insert(buttons, {{
            text = display_name,
            callback = function()
                local selector = self_ref._cache_selector
                local ab_menu = self_ref.current_menu
                ArtifactBrowser.openRow(captured, {
                    plugin = AskGPT, file = doc_path, title = doc_title, opts = opts,
                    before_open = function() UIManager:close(selector) end,
                    -- Round 26 (device report: "the View/Install/Delete popup
                    -- stays open"): browsing the versions keeps the browser,
                    -- an actual View/Install/Switch retires it, so it does not
                    -- stay up showing the pre-install state
                    close_browser = function()
                        if ab_menu then
                            UIManager:close(ab_menu)
                            self_ref.current_menu = nil
                        end
                    end,
                })
            end,
        }})
        end
    end

    -- Select mode with every row filtered out (e.g. the book only has
    -- generated images): explain instead of showing a bare Cancel popup —
    -- and when launched directly (Attach chip, no browser underneath), fall
    -- through to the all-books browser so the pick isn't dead-ended
    if select_mode and #buttons == 0 then
        UIManager:show(InfoMessage:new{
            text = _("This document has no attachable artifacts (generated images can't be attached as text)."),
        })
        if not self.current_menu then
            self:showArtifactBrowser(opts)
        end
        return
    end

    -- Launched directly for one book (Attach chip): offer the full browser
    if select_mode and not self.current_menu then
        table.insert(buttons, {{
            text = _("All books…"),
            callback = function()
                UIManager:close(self_ref._cache_selector)
                self_ref:showArtifactBrowser(opts)
            end,
        }})
    end

    if not select_mode then
        table.insert(buttons, {{
            text = require("koassistant.books.book_page").entryLabel(),
            callback = function()
                UIManager:close(self_ref._cache_selector)
                -- Close the full-screen browser too — Book Hub replaces it as
                -- this book's surface. Leaving it below leaked an invisible
                -- Menu behind the reader once the hub navigated away (device
                -- 2026-08-13: ghost browser flashing on book open, surviving
                -- to app close); the "Open Book" sibling already closes both.
                if self_ref.current_menu then
                    UIManager:close(self_ref.current_menu)
                    self_ref.current_menu = nil
                end
                require("koassistant.books.book_page").show({
                    file = doc_path,
                    plugin = AskGPT,
                    ui = AskGPT.ui,
                    title = doc_title,
                    enable_emoji = opts and opts.enable_emoji,
                })
            end,
        }})
        table.insert(buttons, {{
            text = _("Open Book"),
            callback = function()
                UIManager:close(self_ref._cache_selector)
                if self_ref.current_menu then
                    UIManager:close(self_ref.current_menu)
                    self_ref.current_menu = nil
                end
                require("apps/reader/readerui"):showReader(doc_path)
            end,
        }})
    end
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
                                local AskGPT = self_ref:getAskGPTInstance()
                                -- the X-Ray lineage goes with its artifacts: the
                                -- book's automation is pinned off, as every other
                                -- delete of a live X-Ray does (the sweep of 2026-11-06)
                                local had = ActionCache.hasAnyXray(doc.path)
                                    or #(ActionCache.getXrayLadder(doc.path) or {}) > 0
                                ActionCache.clearAll(doc.path)
                                if had then
                                    require("koassistant.books.book_settings").clearXrayLineageState(
                                        require("koassistant.storage.doc_settings").resolve(doc.path, AskGPT and AskGPT.ui))
                                end
                                -- Invalidate file browser row cache
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
        if doc_path ~= "__GENERAL_CHATS__" and doc_path ~= "__LIBRARY_CHATS__" then
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
            -- Uniform browser carousel (maintainer 2026-08-13): the SAME three
            -- rows in the same order in every browser hamburger — " →" leaves
            -- this browser (the navClose rows), the grayed "● " row is the
            -- current one, kept visible so the carousel is memorizable.
            {{ text = _("Chat History") .. " →", align = "left", callback = function()
                local mc = navClose()
                UIManager:nextTick(function()
                    if mc then UIManager:close(mc) end
                    local AskGPT = self_ref:getAskGPTInstance()
                    -- all_books: cross-book surface, swap lands on the top
                    -- level (device 2026-08-17, notebook-swap sibling)
                    if AskGPT then AskGPT:showChatHistory({ all_books = true }) end
                end)
            end }},
            {{ text = _("Notebooks") .. " →", align = "left", callback = function()
                local mc = navClose()
                UIManager:nextTick(function()
                    if mc then UIManager:close(mc) end
                    local AskGPT = self_ref:getAskGPTInstance()
                    if AskGPT then AskGPT:showNotebookBrowser() end
                end)
            end }},
            {{ text = "● " .. _("Artifacts"), align = "left", enabled = false,
               callback = function() end }},
            -- Group break (device 2026-08-13: hamburger pattern = carousel/nav
            -- rows first, current-view rows below a separator). An EMPTY row is
            -- ButtonTable's cheapest double-rule: it contributes only its
            -- vertical span + row line, so two gray lines with a gap render
            -- between the groups; column_cnt == 0 keeps it out of DPad focus
            -- (verified in frontend buttontable.lua, incl. the shrink path).
            {},
            -- Stays INSIDE the browser (list overlays it) — no navClose, unlike
            -- the cross-browser rows above
            {{ text = _("Browse by type…"), align = "left", callback = function()
                UIManager:close(dialog)
                self_ref:showBrowseByType(opts)
            end }},
        },
        shrink_unneeded_width = true,
        anchor = function()
            return self_ref.current_menu.title_bar.left_button.image.dimen, true
        end,
    }
    UIManager:show(dialog)
end

--- How many artifacts a row stands for, when its newest was made, and whether
--- it is a group: a saved result is one; a group row (sections, wiki entries,
--- pins) is its members. Rows without data (images, X-Ray versions) count 0.
local function rowSize(row)
    if type(row.data) ~= "table" then return 0, 0, false end
    if row.is_section_group or row.is_wiki_group or row.is_pinned_group then
        local newest = 0
        for _idx, member in ipairs(row.data) do
            local ts = tonumber(member.timestamp)
                or (type(member.data) == "table" and tonumber(member.data.timestamp)) or 0
            if ts > newest then newest = ts end
        end
        return #row.data, newest, true
    end
    return 1, tonumber(row.data.timestamp) or 0, false
end

--- Browse by type's kinds (pure). books = { { path, title, author, rows } },
--- rows = getAvailableArtifactsWithPinned's for that book; extra = { general,
--- library = the pinned index's { count, modified } for the pins outside any
--- book (or nil), images = the gallery's picture count }. A kind is named by
--- its rows' type_name and counted in artifacts. The X-Ray versions are left
--- out (a list for managing one book's X-Ray); the pictures are one kind that
--- opens the gallery (its own list of places, pictures without a book
--- included), so the per-book image rows are not listed.
--- @return table kinds { { key, name, count, items, gallery }, ... }, most artifacts first;
---   items = { { path, title, author, row, n, modified, group } | { pinned = "general"|"library", n, modified, group } }
function ArtifactBrowser.typeKinds(books, extra)
    extra = extra or {}
    local kinds, by_key = {}, {}
    local function kindFor(key, name)
        local kind = by_key[key]
        if not kind then
            kind = { key = key, name = name, count = 0, items = {} }
            by_key[key] = kind
            kinds[#kinds + 1] = kind
        end
        return kind
    end
    for _idx, book in ipairs(books) do
        for _idx2, row in ipairs(book.rows or {}) do
            if not (row.is_xray_versions_group or row.is_image_group) then
                local n, modified, group = rowSize(row)
                if n > 0 then
                    local kind = kindFor(row.key, row.type_name or row.name)
                    kind.count = kind.count + n
                    kind.items[#kind.items + 1] = { path = book.path, title = book.title,
                        author = book.author, row = row, n = n, modified = modified, group = group }
                end
            end
        end
    end
    for _idx, which in ipairs({ "general", "library" }) do
        local pins = extra[which]
        local n = type(pins) == "table" and tonumber(pins.count) or 0
        if n > 0 then
            local kind = kindFor("_pinned_artifacts", _("Pinned Artifacts"))
            kind.count = kind.count + n
            kind.items[#kind.items + 1] = { pinned = which, n = n,
                modified = tonumber(pins.modified) or 0, group = true }
        end
    end
    if (tonumber(extra.images) or 0) > 0 then
        local kind = kindFor("_generated_images", _("Generated Images"))
        kind.count = extra.images
        kind.gallery = true
    end
    -- Most artifacts first, ties alphabetical
    table.sort(kinds, function(x, y)
        if x.count ~= y.count then return x.count > y.count end
        return x.name < y.name
    end)
    return kinds
end

--- Cross-book "browse by type" (device 2026-08-13; every kind since B490):
--- pick a kind of artifact, list every book that has it. Reads the browser's
--- own walk (artifactBooks) and the per-book aggregation every View-Artifacts
--- surface reads (getAvailableArtifactsWithPinned), so a kind shows up here
--- exactly where a book's own list shows it (docs/artifact_rows_plan.md).
--- Loads each book's artifacts once; explicit user action, so the scan is
--- acceptable.
--- @param opts table|nil Config passed through
function ArtifactBrowser:showBrowseByType(opts)
    local AskGPT = self:getAskGPTInstance()
    if not AskGPT then
        UIManager:show(InfoMessage:new{ text = _("Could not open viewer.") })
        return
    end
    local books, image_books = ArtifactBrowser.artifactBooks()
    for _idx, book in ipairs(books) do
        book.rows = ActionCache.getAvailableArtifactsWithPinned(book.path, nil, nil,
            { image_books = image_books })
    end
    local pinned_index = PinnedManager.getPinnedIndex()
    local ImageBrowser = require("koassistant.images.image_browser")
    local kinds = ArtifactBrowser.typeKinds(books, {
        general = pinned_index[PinnedManager.GENERAL_KEY],
        library = pinned_index[PinnedManager.LIBRARY_KEY],
        images = ImageBrowser.count(),
    })
    if #kinds == 0 then
        UIManager:show(InfoMessage:new{ text = _("No artifacts yet."), timeout = 2 })
        return
    end

    local self_ref = self
    local dialog
    local rows = {}
    for _idx, kind in ipairs(kinds) do
        local captured = kind
        table.insert(rows, {{
            text = T("%1 (%2)", captured.name, captured.count),
            align = "left",
            callback = function()
                UIManager:close(dialog)
                if captured.gallery then
                    ImageBrowser.show()
                else
                    self_ref:_showTypeList(captured, AskGPT, opts)
                end
            end,
        }})
    end
    table.insert(rows, {{ text = _("Cancel"),
        callback = function() UIManager:close(dialog) end }})
    dialog = ButtonDialog:new{
        title = _("Browse by type"),
        buttons = rows,
    }
    UIManager:show(dialog)
end

--- One kind's artifacts across all books: the pins outside any book first,
--- then the books, newest first. Overlays the browser Menu (X/back returns to
--- it); a tapped book opens on top through openRow, where the book's own list
--- goes (a group kind: that book's popup).
function ArtifactBrowser:_showTypeList(kind, AskGPT, opts)
    local function rank(item)
        if item.pinned == "general" then return 1 end
        if item.pinned == "library" then return 2 end
        return 3
    end
    table.sort(kind.items, function(a, b)
        local ra, rb = rank(a), rank(b)
        if ra ~= rb then return ra < rb end
        return (a.modified or 0) > (b.modified or 0)
    end)
    local self_ref = self
    -- The pins outside any book open a pinned list whose back arrow returns
    -- here (the browser's own rows rebuild the browser instead)
    local pinned_opts = { return_to_list = true }
    for k, v in pairs(opts or {}) do
        if pinned_opts[k] == nil then pinned_opts[k] = v end
    end
    local menu_items = {}
    for _idx, item in ipairs(kind.items) do
        local captured = item
        local mandatory
        if captured.group then
            local rel = (captured.modified or 0) > 0 and Constants.formatRelativeTime(captured.modified) or ""
            mandatory = rel ~= "" and (tostring(captured.n) .. " \u{00B7} " .. rel) or tostring(captured.n)
        else
            mandatory = ArtifactBrowser.rowMeta(captured.row)
        end
        local text, callback
        if captured.pinned == "general" then
            text = _("General (Pinned)")
            callback = function()
                self_ref:showPinnedList(PinnedManager.getGeneralPinned(), _("General (Pinned)"),
                    PinnedManager.GENERAL_KEY, pinned_opts)
            end
        elseif captured.pinned == "library" then
            text = _("Library (Pinned)")
            callback = function()
                self_ref:showPinnedList(PinnedManager.getLibraryPinned(), _("Library (Pinned)"),
                    PinnedManager.LIBRARY_KEY, pinned_opts)
            end
        else
            text = captured.title
            callback = function()
                ArtifactBrowser.openRow(captured.row, { plugin = AskGPT, file = captured.path,
                    title = captured.title, author = captured.author })
            end
        end
        table.insert(menu_items, {
            text = text,
            mandatory = mandatory,
            mandatory_dim = true,
            help_text = captured.path,
            callback = callback,
        })
    end
    local menu = Menu:new{
        title = T(_("%1 (all books)"), kind.name),
        item_table = menu_items,
        is_borderless = true,
        is_popout = false,
        width = Screen:getWidth(),
        height = Screen:getHeight(),
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
    UIManager:show(menu)
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
        local date_str = entry.timestamp > 0 and Constants.formatRelativeTime(entry.timestamp) or ""
        local display_name = captured.name or captured.action_text or _("Chat")
        local display_text = Constants.getEmojiText("\u{1F4CC}", display_name, enable_emoji)
        if captured.book_title then
            display_text = display_text .. " \u{00B7} " .. captured.book_title
        end

        table.insert(menu_items, {
            text = display_text,
            mandatory = (captured.model or "") .. " \u{00B7} " .. date_str,
            mandatory_dim = true,
            callback = function()
                -- Select mode (attach_plan.md): shared build-first tail
                if opts and opts.select_mode then
                    local sel_entry, err = require("koassistant.request.attachments").makePinned(captured)
                    finishLeafSelect(self_ref, opts, sel_entry, err,
                        self_ref.current_pinned_menu, function()
                            self_ref.current_pinned_menu = nil
                        end)
                    return
                end
                self_ref:showPinnedViewer(captured, context_path, opts)
            end,
            -- Hold options (delete/rename) are destructive — suppressed while
            -- picking an artifact to attach
            hold_callback = not (opts and opts.select_mode) and function()
                self_ref:showPinnedOptions(captured, context_path, opts)
            end or nil,
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
            -- Opened from Browse by type: back is that list, still underneath
            if opts and opts.return_to_list then return end
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
    local ChatGPTViewer = require("koassistant.ui.chatgptviewer")

    -- Build info text
    local info_parts = {}
    if entry.action_text and entry.action_text ~= "" then
        table.insert(info_parts, _("Action") .. ": " .. entry.action_text)
    end
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

    local display_name = entry.name or entry.action_text or _("Pinned")
    local viewer = ChatGPTViewer:new{
        title = display_name .. " (" .. _("Pinned") .. ")",
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
        _artifact_file = context_path,
        _artifact_key = "pinned:" .. (entry.id or ""),
        _artifact_book_title = entry.book_title,
        _artifact_book_author = entry.book_author,
        _book_open = (AskGPT.ui and AskGPT.ui.document ~= nil),
        _plugin = AskGPT,
        on_launch_chat = AskGPT._buildLaunchChatCallback
            and AskGPT:_buildLaunchChatCallback(context_path, entry.book_title, entry.book_author, entry.result, entry.action_text or _("Pinned"), { stamps = entry }) or nil,
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
        title = entry.name or entry.action_text or _("Pinned"),
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
                    text = _("Rename"),
                    callback = function()
                        UIManager:close(dialog)
                        local InputDialog = require("ui/widget/inputdialog")
                        local input_dialog
                        input_dialog = InputDialog:new{
                            title = _("Rename Artifact"),
                            input = entry.name or entry.action_text or "",
                            input_hint = _("Enter a new name"),
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
                                        text = _("Save"),
                                        is_enter_default = true,
                                        callback = function()
                                            local new_name = input_dialog:getInputText()
                                            if not new_name or new_name == "" then return end
                                            if #new_name > 80 then new_name = new_name:sub(1, 80) end
                                            UIManager:close(input_dialog)
                                            entry.name = new_name
                                            PinnedManager.updatePin(context_path, entry.id, { name = new_name })
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
                                    },
                                },
                            },
                        }
                        UIManager:show(input_dialog)
                        input_dialog:onShowKeyboard()
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

--- Show popup listing individual section X-Rays from a group entry
--- @param sections table Array from getSectionXrays()
--- @param doc_path string Document file path
--- @param doc_title string Document title
--- @param AskGPT table Plugin instance for opening viewers
--- @param excluded_key string|nil Section key to exclude from listing
--- @param on_select function|nil Called when an item is selected (to close parent popups)
--- @param opts table|nil the artifact browser's opts (select mode)
--- @param doc_author string|nil Document author (the viewers and the chat carry it)
function ArtifactBrowser:_showSectionXrayGroupPopup(sections, doc_path, doc_title, AskGPT, excluded_key, on_select, opts, doc_author)
    local self_ref = self
    local buttons = {}
    for _idx, sec in ipairs(sections) do
        if sec.key ~= excluded_key then
            local captured = sec
            local label = captured.label or captured.key
            local doc = openDocFor(AskGPT, doc_path)
            local detail_parts = {}
            local page_info = captured.data and ActionCache.reconvertPageSummary(captured.data, doc) or ""
            if page_info ~= "" then table.insert(detail_parts, page_info) end
            if captured.data and captured.data.timestamp then
                local rel = Constants.formatRelativeTime(captured.data.timestamp)
                if rel ~= "" then table.insert(detail_parts, rel) end
            end
            local display = #detail_parts > 0 and (label .. " (" .. table.concat(detail_parts, ", ") .. ")") or label
            table.insert(buttons, {{
                text = display,
                callback = function()
                    -- Select mode (attach_plan.md): shared build-first tail
                    if opts and opts.select_mode then
                        local entry, err = require("koassistant.request.attachments")
                            .makeArtifact(label, captured.key, captured.data, doc_title, nil, doc_path)
                        finishLeafSelect(self_ref, opts, entry, err,
                            self_ref._section_group_dialog, on_select)
                        return
                    end
                    if self_ref._section_group_dialog then
                        UIManager:close(self_ref._section_group_dialog)
                    end
                    if on_select then on_select() end
                    AskGPT:showCacheViewer({
                        name = label, key = captured.key, data = captured.data,
                        book_title = doc_title, book_author = doc_author, file = doc_path })
                end,
            }})
        end
    end

    if #buttons == 0 then
        UIManager:show(InfoMessage:new{
            text = _("No Section X-Rays available."),
            timeout = 3,
        })
        return
    end

    -- Merge entry (A2): riding the shared popup covers every consumer of the
    -- section X-Ray group at once. Management row — select mode skips it,
    -- like every hamburger/hold-menu in select mode.
    if not (opts and opts.select_mode) then
        table.insert(buttons, {{
            text = _("AI merge section X-Rays…"),
            callback = function()
                if self_ref._section_group_dialog then
                    UIManager:close(self_ref._section_group_dialog)
                end
                -- The surface under the popup closes only once the merge
                -- really starts (the flow's T11 rule, as the X-Ray browser's
                -- own merge row): a refusal leaves it in place
                AskGPT:_startSectionXrayMergeFlow(doc_path, { book_title = doc_title,
                    book_author = doc_author, close_browser = on_select })
            end,
        }})
    end

    self._section_group_dialog = ButtonDialog:new{
        title = _("View Section X-Rays"),
        buttons = buttons,
    }
    UIManager:show(self._section_group_dialog)
end

--- Show popup listing individual section entries from a generic (non-X-Ray) section group.
--- @param sections table Array of { key, label, data } section entries
--- @param doc_path string Document file path
--- @param doc_title string|nil Document title
--- @param AskGPT table Plugin instance for viewer
--- @param section_type string Section type key (e.g., "summary", "recap")
--- @param excluded_key string|nil Key to exclude
--- @param on_select function|nil Called when an item is selected (to close parent popups)
--- @param opts table|nil the artifact browser's opts (select mode)
--- @param doc_author string|nil Document author (the viewers and the chat carry it)
function ArtifactBrowser:_showSectionGroupPopup(sections, doc_path, doc_title, AskGPT, section_type, excluded_key, on_select, opts, doc_author)
    local self_ref = self
    local buttons = {}
    local type_label = ActionCache.SECTION_TYPE_LABELS[section_type] or section_type
    for _idx, sec in ipairs(sections) do
        if sec.key ~= excluded_key then
            local captured = sec
            local label = captured.label or captured.key
            local doc = openDocFor(AskGPT, doc_path)
            local detail_parts = {}
            local page_info = captured.data and ActionCache.reconvertPageSummary(captured.data, doc) or ""
            if page_info ~= "" then table.insert(detail_parts, page_info) end
            if captured.data and captured.data.timestamp then
                local rel = Constants.formatRelativeTime(captured.data.timestamp)
                if rel ~= "" then table.insert(detail_parts, rel) end
            end
            local display = #detail_parts > 0 and (label .. " (" .. table.concat(detail_parts, ", ") .. ")") or label
            table.insert(buttons, {{
                text = display,
                callback = function()
                    -- Select mode (attach_plan.md): shared build-first tail —
                    -- a refusal (e.g. section quiz) keeps the picker open
                    if opts and opts.select_mode then
                        local entry, err = require("koassistant.request.attachments").makeArtifact(
                            T(_("Section %1: %2"), type_label, label),
                            captured.key, captured.data, doc_title, section_type, doc_path)
                        finishLeafSelect(self_ref, opts, entry, err,
                            self_ref._section_group_dialog, on_select)
                        return
                    end
                    if self_ref._section_group_dialog then
                        UIManager:close(self_ref._section_group_dialog)
                    end
                    if on_select then on_select() end
                    -- Route through viewCachedAction for per-action types (e.g. quiz → quiz viewer)
                    local action_id = section_type
                    local action_stub = AskGPT.action_service and AskGPT.action_service:getAction("book", action_id)
                    if action_stub and action_stub.interactive_quiz then
                        AskGPT:viewCachedAction(action_stub, action_id, captured.data, {
                            file = doc_path, book_title = doc_title, book_author = doc_author,
                            section_label = label, section_key = captured.key })
                    else
                        AskGPT:showCacheViewer({
                            name = T(_("Section %1: %2"), type_label, label),
                            key = captured.key, data = captured.data,
                            book_title = doc_title, book_author = doc_author, file = doc_path })
                    end
                end,
            }})
        end
    end

    if #buttons == 0 then
        UIManager:show(InfoMessage:new{
            text = _("No sections available."),
            timeout = 3,
        })
        return
    end

    local group_title = ActionCache.SECTION_GROUP_NAMES[section_type]
        or (section_type .. " sections")
    self._section_group_dialog = ButtonDialog:new{
        title = group_title,
        buttons = buttons,
    }
    UIManager:show(self._section_group_dialog)
end

--- Show popup listing individual wiki entries from a group entry (artifact browser context)
--- @param wiki_entries table Array of wiki entries
--- @param doc_path string Document file path
--- @param AskGPT table|nil Plugin instance for artifact cross-navigation
--- @param doc_title string|nil Document title
--- @param on_select function|nil Called when an item is selected (to close parent popups)
--- @param opts table|nil the artifact browser's opts (select mode)
--- @param doc_author string|nil Document author (the viewer and the chat carry it)
function ArtifactBrowser:_showWikiGroupPopup(wiki_entries, doc_path, AskGPT, doc_title, on_select, opts, doc_author)
    local ChatGPTViewer = require("koassistant.ui.chatgptviewer")
    local self_ref = self

    local buttons = {}
    for _idx, wiki in ipairs(wiki_entries) do
        local captured = wiki
        local btn_label = captured.label
        local wiki_title = T(_("AI Wiki: %1"), captured.label)
        if captured.data and captured.data.timestamp then
            local rel = Constants.formatRelativeTime(captured.data.timestamp)
            if rel ~= "" then
                btn_label = btn_label .. " · " .. rel
                wiki_title = wiki_title .. " · " .. rel
            end
        end
        table.insert(buttons, {{
            text = btn_label,
            callback = function()
                -- Select mode (attach_plan.md): shared build-first tail
                if opts and opts.select_mode then
                    local entry, err = require("koassistant.request.attachments").makeArtifact(
                        T(_("AI Wiki: %1"), captured.label),
                        captured.key, captured.data, doc_title, nil, doc_path)
                    finishLeafSelect(self_ref, opts, entry, err,
                        self_ref._wiki_group_dialog, on_select)
                    return
                end
                if self_ref._wiki_group_dialog then
                    UIManager:close(self_ref._wiki_group_dialog)
                end
                if on_select then on_select() end
                local viewer = ChatGPTViewer:new{
                    title = wiki_title,
                    text = captured.data.result,
                    simple_view = true,
                    cache_type_name = _("AI Wiki"),
                    on_delete = function()
                        ActionCache.clear(doc_path, captured.key)
                        UIManager:show(Notification:new{
                            text = _("AI Wiki deleted"),
                            timeout = 2,
                        })
                    end,
                    _plugin = AskGPT,
                    _artifact_file = doc_path,
                    _artifact_key = captured.key,
                    _book_open = (AskGPT and AskGPT.ui and AskGPT.ui.document ~= nil),
                    _artifact_book_title = doc_title,
                    _artifact_book_author = doc_author,
                    on_launch_chat = AskGPT and AskGPT._buildLaunchChatCallback
                        and AskGPT:_buildLaunchChatCallback(doc_path, doc_title, doc_author, captured.data.result, _("AI Wiki"), { stamps = captured.data }) or nil,
                }
                UIManager:show(viewer)
            end,
        }})
    end

    if #buttons == 0 then
        UIManager:show(InfoMessage:new{
            text = _("No AI Wiki entries available."),
            timeout = 3,
        })
        return
    end

    self._wiki_group_dialog = ButtonDialog:new{
        title = _("AI Wiki Entries"),
        buttons = buttons,
    }
    UIManager:show(self._wiki_group_dialog)
end

--- Show popup listing individual pinned entries from a group entry (artifact selector context)
--- @param pinned_entries table Array of pinned entries
--- @param doc_path string Document file path
--- @param doc_title string Document title
--- @param on_select function|nil Called when an item is selected (to close parent popups)
--- @param opts table|nil the artifact browser's opts (select mode)
--- @param doc_author string|nil Document author (the viewer and the chat carry it)
function ArtifactBrowser:_showPinnedGroupPopup(pinned_entries, doc_path, doc_title, on_select, opts, doc_author)
    local ChatGPTViewer = require("koassistant.ui.chatgptviewer")
    local AskGPT = self:getAskGPTInstance()
    local self_ref = self

    local buttons = {}
    for _idx, pin in ipairs(pinned_entries) do
        local captured = pin
        local label = captured.name or captured.action_text or _("Pinned")
        if captured.timestamp and captured.timestamp > 0 then
            local rel = Constants.formatRelativeTime(captured.timestamp)
            if rel ~= "" then
                label = label .. " · " .. rel
            end
        end
        table.insert(buttons, {{
            text = label,
            callback = function()
                -- Select mode (attach_plan.md): shared build-first tail
                if opts and opts.select_mode then
                    local entry, err = require("koassistant.request.attachments").makePinned(captured)
                    finishLeafSelect(self_ref, opts, entry, err,
                        self_ref._pinned_group_dialog, on_select)
                    return
                end
                if self_ref._pinned_group_dialog then
                    UIManager:close(self_ref._pinned_group_dialog)
                end
                if on_select then on_select() end
                local display_name = captured.name or captured.action_text or _("Pinned")
                -- Build info text (same as showPinnedViewer)
                local info_parts = {}
                if captured.action_text and captured.action_text ~= "" then
                    table.insert(info_parts, _("Action") .. ": " .. captured.action_text)
                end
                if captured.model and captured.model ~= "" then
                    table.insert(info_parts, _("Model") .. ": " .. captured.model)
                end
                if captured.timestamp and captured.timestamp > 0 then
                    table.insert(info_parts, _("Pinned") .. ": " .. os.date("%B %d, %Y", captured.timestamp))
                end
                if captured.user_prompt and captured.user_prompt ~= "" then
                    local preview = captured.user_prompt:sub(1, 200)
                    if #captured.user_prompt > 200 then preview = preview .. "..." end
                    table.insert(info_parts, _("Prompt") .. ": " .. preview)
                end
                local viewer = ChatGPTViewer:new{
                    title = display_name .. " (" .. _("Pinned") .. ")",
                    text = captured.result or "",
                    simple_view = true,
                    cache_type_name = _("pinned artifact"),
                    cache_metadata = {
                        cache_type = "pinned",
                        book_title = captured.book_title,
                        book_author = captured.book_author,
                        model = captured.model,
                        timestamp = captured.timestamp,
                    },
                    _info_text = #info_parts > 0 and table.concat(info_parts, "\n") or nil,
                    on_delete = function()
                        PinnedManager.removePin(doc_path, captured.id)
                        UIManager:show(Notification:new{
                            text = _("Pinned artifact removed"),
                            timeout = 2,
                        })
                    end,
                    _plugin = AskGPT,
                    _artifact_file = doc_path,
                    _artifact_key = "pinned:" .. (captured.id or ""),
                    _book_open = (AskGPT and AskGPT.ui and AskGPT.ui.document ~= nil),
                    _artifact_book_title = doc_title,
                    _artifact_book_author = doc_author,
                    on_launch_chat = AskGPT and AskGPT._buildLaunchChatCallback
                        and AskGPT:_buildLaunchChatCallback(doc_path, doc_title, doc_author, captured.result, captured.action_text or _("Pinned"), { stamps = captured }) or nil,
                }
                UIManager:show(viewer)
            end,
        }})
    end

    if #buttons == 0 then
        UIManager:show(InfoMessage:new{
            text = _("No pinned artifacts available."),
            timeout = 3,
        })
        return
    end

    self._pinned_group_dialog = ButtonDialog:new{
        title = _("Pinned Artifacts"),
        buttons = buttons,
    }
    UIManager:show(self._pinned_group_dialog)
end

return ArtifactBrowser
