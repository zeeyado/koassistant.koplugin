--[[--
Artifact Browser for KOAssistant

Browser UI for viewing all documents with cached artifacts (X-Ray, Summary, Analysis, Recap).
- Flat list: each artifact shown as "Book Title — Artifact Type"
- Tap to view, hold to delete
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

-- Human-readable names for artifact keys
local ARTIFACT_NAMES = {
    ["_xray_cache"] = "X-Ray",
    ["_summary_cache"] = _("Summary"),
    ["_analyze_cache"] = _("Analysis"),
    ["recap"] = _("Recap"),
}

-- Emoji icons for artifact types
local ARTIFACT_EMOJI = {
    ["_xray_cache"] = "\u{1F50D}",   -- magnifying glass
    ["_summary_cache"] = "\u{1F4DD}", -- memo
    ["_analyze_cache"] = "\u{1F4CA}", -- bar chart
    ["recap"] = "\u{1F4D6}",          -- open book
}

--- Get book title from DocSettings metadata, falling back to filename
--- @param doc_path string The document file path
--- @return string title The book title
local function getBookTitle(doc_path)
    local doc_settings = DocSettings:open(doc_path)
    local doc_props = doc_settings:readSetting("doc_props")
    if doc_props and doc_props.title and doc_props.title ~= "" then
        return doc_props.title
    end
    return doc_path:match("([^/]+)%.[^%.]+$") or doc_path
end

--- Show the artifact browser (flat list of all artifacts)
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

    -- Collect all individual artifacts across all documents
    local all_artifacts = {}
    for doc_path, stats in pairs(index) do
        local cache_path = ActionCache.getPath(doc_path)
        if cache_path and lfs.attributes(cache_path, "mode") == "file" then
            local title = getBookTitle(doc_path)
            -- Load actual cache to discover individual artifacts
            for _idx, key in ipairs(ActionCache.ARTIFACT_KEYS) do
                local entry = ActionCache.get(doc_path, key)
                if entry and entry.result then
                    table.insert(all_artifacts, {
                        doc_path = doc_path,
                        doc_title = title,
                        key = key,
                        name = ARTIFACT_NAMES[key] or key,
                        emoji = ARTIFACT_EMOJI[key] or "",
                        data = entry,
                        timestamp = entry.timestamp or 0,
                    })
                end
            end
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
    if #all_artifacts == 0 then
        UIManager:show(InfoMessage:new{
            text = _("No artifacts yet.\n\nRun X-Ray, Summarize Document, or Analyze Document to create reusable artifacts."),
            timeout = 5,
        })
        return
    end

    -- Sort by timestamp (newest first)
    table.sort(all_artifacts, function(a, b) return a.timestamp > b.timestamp end)

    -- Build menu items
    local menu_items = {}
    local self_ref = self
    local enable_emoji = opts and opts.enable_emoji

    for _idx, artifact in ipairs(all_artifacts) do
        local captured = artifact
        -- Build info string: progress% + date
        local parts = {}
        if captured.data.progress_decimal then
            table.insert(parts, math.floor(captured.data.progress_decimal * 100 + 0.5) .. "%")
        end
        if captured.timestamp > 0 then
            table.insert(parts, os.date("%Y-%m-%d", captured.timestamp))
        end
        local mandatory = table.concat(parts, " \u{00B7} ")

        -- Display: "Book Title — Artifact Type"
        local display_text = captured.doc_title .. " \u{2014} " .. captured.name
        display_text = Constants.getEmojiText(captured.emoji, display_text, enable_emoji)

        table.insert(menu_items, {
            text = display_text,
            mandatory = mandatory,
            mandatory_dim = true,
            callback = function()
                self_ref:showArtifactOptions(captured, opts)
            end,
            hold_callback = function()
                self_ref:confirmDeleteArtifact(captured, opts)
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
        single_line = true,
        items_font_size = 18,
        items_mandatory_font_size = 14,
        close_callback = function()
            self_ref.current_menu = nil
        end,
    }

    self.current_menu = menu
    UIManager:show(menu)
end

--- Show options for an artifact (tap menu)
--- @param artifact table The artifact entry
--- @param opts table|nil Config passed through for refresh
function ArtifactBrowser:showArtifactOptions(artifact, opts)
    local self_ref = self

    local dialog
    dialog = ButtonDialog:new{
        title = artifact.name .. " \u{2014} " .. artifact.doc_title,
        buttons = {
            {
                {
                    text = _("View"),
                    callback = function()
                        UIManager:close(dialog)
                        self_ref:openArtifactViewer(artifact)
                    end,
                },
            },
            {
                {
                    text = _("Delete"),
                    callback = function()
                        UIManager:close(dialog)
                        self_ref:confirmDeleteArtifact(artifact, opts)
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

--- Confirm and delete an artifact
--- @param artifact table The artifact entry
--- @param opts table|nil Config passed through for refresh
function ArtifactBrowser:confirmDeleteArtifact(artifact, opts)
    local self_ref = self

    UIManager:show(ConfirmBox:new{
        text = _("Delete this artifact?\n\nThis cannot be undone."),
        ok_text = _("Delete"),
        ok_callback = function()
            ActionCache.clear(artifact.doc_path, artifact.key)
            -- X-Ray also has a per-action cache
            if artifact.key == "_xray_cache" then
                ActionCache.clear(artifact.doc_path, "xray")
            end
            -- Invalidate file browser row cache
            local AskGPT = self_ref:getAskGPTInstance()
            if AskGPT then
                AskGPT._file_dialog_row_cache = { file = nil, rows = nil }
            end
            UIManager:show(Notification:new{
                text = artifact.name .. " " .. _("deleted"),
                timeout = 2,
            })
            -- Refresh browser
            self_ref:showArtifactBrowser(opts)
        end,
    })
end

--- Open the appropriate viewer for an artifact
--- @param artifact table The artifact entry
function ArtifactBrowser:openArtifactViewer(artifact)
    local AskGPT = self:getAskGPTInstance()
    if not AskGPT then
        UIManager:show(InfoMessage:new{ text = _("Could not open viewer.") })
        return
    end

    -- Close browser before opening viewer
    if self.current_menu then
        UIManager:close(self.current_menu)
        self.current_menu = nil
    end

    if artifact.key == "recap" then
        -- Recap uses viewCachedAction
        AskGPT:viewCachedAction(
            { text = artifact.name },
            artifact.key,
            artifact.data,
            { file = artifact.doc_path, book_title = artifact.doc_title }
        )
    else
        -- Document caches use showCacheViewer
        AskGPT:showCacheViewer({
            name = artifact.name,
            key = artifact.key,
            data = artifact.data,
            book_title = artifact.doc_title,
            file = artifact.doc_path,
        })
    end
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
