--[[--
Artifact Browser for KOAssistant

Browser UI for viewing all documents with cached artifacts (X-Ray, Summary, Analysis, Recap).
- Level 1: Documents sorted by most recent artifact date
- Level 2: Artifact list for a document (tap to view, hold to delete)
- Auto-cleanup stale index entries

@module koassistant_artifact_browser
]]

local ActionCache = require("koassistant_action_cache")
local ButtonDialog = require("ui/widget/buttondialog")
local ConfirmBox = require("ui/widget/confirmbox")
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

--- Show the artifact browser (list of all documents with artifacts)
--- @param opts table|nil Optional config: { enable_emoji = bool }
function ArtifactBrowser:showArtifactBrowser(opts)
    local lfs = require("libs/libkoreader-lfs")
    local index = G_reader_settings:readSetting("koassistant_artifact_index", {})
    local needs_cleanup = false

    -- Build sorted list (newest first), validate entries exist
    local docs = {}
    for doc_path, stats in pairs(index) do
        local cache_path = ActionCache.getPath(doc_path)
        if cache_path and lfs.attributes(cache_path, "mode") == "file" then
            local title = doc_path:match("([^/]+)%.[^%.]+$") or doc_path
            table.insert(docs, {
                path = doc_path,
                title = title,
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
            text = _("No artifacts yet.\n\nRun X-Ray, Summarize Document, or Analyze Document to create reusable artifacts."),
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

        table.insert(menu_items, {
            text = Constants.getEmojiText("\u{1F4E6}", doc.title, enable_emoji),
            mandatory = count_str .. " \u{00B7} " .. date_str,
            mandatory_dim = true,
            callback = function()
                self_ref:showDocumentArtifacts(captured_doc.path, captured_doc.title, opts)
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

--- Show artifacts for a specific document (Level 2)
--- @param doc_path string The document file path
--- @param doc_title string The document title for display
--- @param opts table|nil Optional config passed through from Level 1
function ArtifactBrowser:showDocumentArtifacts(doc_path, doc_title, opts)
    -- Load actual cache and discover which artifacts exist
    local artifacts = {}
    for _idx, key in ipairs(ActionCache.ARTIFACT_KEYS) do
        local entry = ActionCache.get(doc_path, key)
        if entry and entry.result then
            table.insert(artifacts, {
                key = key,
                name = ARTIFACT_NAMES[key] or key,
                emoji = ARTIFACT_EMOJI[key] or "",
                data = entry,
            })
        end
    end

    if #artifacts == 0 then
        -- All artifacts were removed since index was built; clean up
        local index = G_reader_settings:readSetting("koassistant_artifact_index", {})
        index[doc_path] = nil
        G_reader_settings:saveSetting("koassistant_artifact_index", index)
        G_reader_settings:flush()

        UIManager:show(InfoMessage:new{
            text = _("No artifacts found for this document."),
        })
        -- Refresh Level 1
        self:showArtifactBrowser(opts)
        return
    end

    -- Build menu items for each artifact
    local menu_items = {}
    local self_ref = self
    local enable_emoji = opts and opts.enable_emoji
    for _idx, artifact in ipairs(artifacts) do
        local captured = artifact
        -- Build info string: progress% + date
        local parts = {}
        if captured.data.progress_decimal then
            table.insert(parts, math.floor(captured.data.progress_decimal * 100 + 0.5) .. "%")
        end
        if captured.data.timestamp then
            table.insert(parts, os.date("%Y-%m-%d", captured.data.timestamp))
        end
        local mandatory = table.concat(parts, " \u{00B7} ")

        table.insert(menu_items, {
            text = Constants.getEmojiText(captured.emoji, captured.name, enable_emoji),
            mandatory = mandatory,
            mandatory_dim = true,
            callback = function()
                self_ref:openArtifactViewer(doc_path, doc_title, captured)
            end,
            hold_callback = function()
                self_ref:showArtifactOptions(doc_path, doc_title, captured, opts)
            end,
        })
    end

    -- Close existing menu and show Level 2
    if self.current_menu then
        UIManager:close(self.current_menu)
        self.current_menu = nil
    end

    local menu = Menu:new{
        title = doc_title,
        item_table = menu_items,
        is_borderless = true,
        is_popout = false,
        width = Screen:getWidth(),
        height = Screen:getHeight(),
        single_line = true,
        items_font_size = 18,
        items_mandatory_font_size = 14,
        -- Enable back arrow
        onReturn = function()
            self_ref:showArtifactBrowser(opts)
        end,
        close_callback = function()
            self_ref.current_menu = nil
        end,
    }

    self.current_menu = menu
    UIManager:show(menu)
end

--- Open the appropriate viewer for an artifact
--- @param doc_path string The document file path
--- @param doc_title string The document title
--- @param artifact table The artifact entry: { key, name, data }
function ArtifactBrowser:openArtifactViewer(doc_path, doc_title, artifact)
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
            { file = doc_path, book_title = doc_title }
        )
    else
        -- Document caches use showCacheViewer
        AskGPT:showCacheViewer({
            name = artifact.name,
            key = artifact.key,
            data = artifact.data,
            book_title = doc_title,
            file = doc_path,
        })
    end
end

--- Show options for an artifact (hold menu)
--- @param doc_path string The document file path
--- @param doc_title string The document title
--- @param artifact table The artifact entry: { key, name, data }
--- @param opts table|nil Config passed through for refresh
function ArtifactBrowser:showArtifactOptions(doc_path, doc_title, artifact, opts)
    local self_ref = self

    local dialog
    dialog = ButtonDialog:new{
        title = artifact.name .. " - " .. doc_title,
        buttons = {
            {
                {
                    text = _("View"),
                    callback = function()
                        UIManager:close(dialog)
                        self_ref:openArtifactViewer(doc_path, doc_title, artifact)
                    end,
                },
            },
            {
                {
                    text = _("Delete"),
                    callback = function()
                        UIManager:close(dialog)
                        UIManager:show(ConfirmBox:new{
                            text = _("Delete this artifact?\n\nThis cannot be undone."),
                            ok_text = _("Delete"),
                            ok_callback = function()
                                ActionCache.clear(doc_path, artifact.key)
                                -- X-Ray also has a per-action cache
                                if artifact.key == "_xray_cache" then
                                    ActionCache.clear(doc_path, "xray")
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
                                -- Refresh Level 2 (will pop to Level 1 if empty)
                                self_ref:showDocumentArtifacts(doc_path, doc_title, opts)
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
