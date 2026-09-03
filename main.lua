local Device = require("device")
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local NetworkMgr = require("ui/network/manager")
local Dispatcher = require("dispatcher")
local _ = require("koassistant_gettext")
local UIManager = require("ui/uimanager")
local InfoMessage = require("ui/widget/infomessage")
local Menu = require("ui/widget/menu")
local MultiInputDialog = require("ui/widget/multiinputdialog")
local ButtonDialog = require("ui/widget/buttondialog")
local Notification = require("ui/widget/notification")
local LuaSettings = require("luasettings")
local DataStorage = require("datastorage")
local FileManager = require("apps/filemanager/filemanager")
local lfs = require("libs/libkoreader-lfs")
local T = require("ffi/util").template
local logger = require("koassistant_logger")
local util = require("util")
local Screen = Device.screen

local Dialogs = require("koassistant_dialogs")
local showChatGPTDialog = Dialogs.showChatGPTDialog
-- UpdateChecker is lazy-loaded to speed up plugin startup (defers loading ~25 UI modules)
local SettingsSchema = require("koassistant_settings_schema")
local SettingsManager = require("koassistant_ui.settings_manager")
local PromptsManager = require("koassistant_ui.prompts_manager")
local UIConstants = require("koassistant_ui.constants")
local ActionService = require("action_service")

local ModelLists = require("koassistant_model_lists")
local Constants = require("koassistant_constants")
local StorageRegistry = require("koassistant_storage_registry")

-- Load the configuration directly
local configuration = {
    -- Default configuration values
    provider = "anthropic",
    features = {
        hide_highlighted_text = false,
        hide_long_highlights = true,
        long_highlight_threshold = 280,
        translate_to = "English",
        debug = false,
    }
}

-- Try to load the configuration file if it exists
-- Get the directory of this script
local function script_path()
   local str = debug.getinfo(2, "S").source:sub(2)
   return str:match("(.*/)")
end

local plugin_dir = script_path()
local config_path = plugin_dir .. "configuration.lua"

-- Track configuration.lua load errors to notify user in init()
local config_load_error = nil

-- Whether the user actually supplied a configuration.lua. NOT the same as
-- "configuration has values": without the file, `configuration` stays the built-in
-- literal above, which carries legacy keys (notably translate_to) that must never be
-- treated as user intent — writing them to disk would fire legacy migrations.
local user_config_loaded = false

local ok, loaded_config = pcall(dofile, config_path)
if ok and loaded_config then
    configuration = loaded_config
    user_config_loaded = true
    logger.dbg("Loaded configuration from configuration.lua")
else
    -- Distinguish "file doesn't exist" from "file exists but has errors"
    if lfs.attributes(config_path, "mode") then
        -- File exists but failed to parse — likely a syntax error
        config_load_error = tostring(loaded_config or "unknown error")
        logger.warn("configuration.lua has errors:", config_load_error)
    else
        logger.dbg("No configuration.lua found, using defaults")
    end
end

-- Normalize the loaded config so a configuration.lua that lacks a `features` table — or isn't a
-- table at all — can't nil-deref / crash initSettings later and silently disable the plugin
-- (e.g. a config returning just `{provider="openai"}`, or a malformed non-table return).
if type(configuration) ~= "table" then configuration = {} end
configuration.features = configuration.features or {}

-- Save configuration.lua values as a base layer before settings UI overrides them.
-- These serve as fallbacks when the Settings UI hasn't set a value.
local config_file_defaults = {
    provider = configuration.provider,
    model = configuration.model,
    features = {},
    provider_settings = configuration.provider_settings,
}
if configuration.features then
    for k, v in pairs(configuration.features) do
        config_file_defaults.features[k] = v
    end
end

-- Helper function to count table entries
local function table_count(t)
    local count = 0
    if t then
        for _ in pairs(t) do
            count = count + 1
        end
    end
    return count
end

-- KOAssistant custom sidecar files to track during book move/copy/delete
-- (automatically moved/copied/deleted alongside books in FileManager) and the
-- G_reader_settings indices that track per-book data. Both derive from the
-- storage registry (single source of truth, Track 33) — no longer hand-listed.
local KOASSISTANT_SIDECAR_FILES = StorageRegistry.sidecarFiles()
local KOASSISTANT_INDICES = StorageRegistry.indexKeys()

-- Language data (shared module)
local Languages = require("koassistant_languages")
local REGULAR_LANGUAGES = Languages.REGULAR
local CLASSICAL_LANGUAGES = Languages.CLASSICAL
local COMMON_LANGUAGES = Languages.getAllIds()

-- Helper to get display name for a language (native script or as-is for classical)
local function getLanguageDisplay(lang_id)
    return Languages.getDisplay(lang_id)
end

-- Helper function to copy file content (fallback for cross-filesystem moves)
-- Returns: success (boolean), error_message (string or nil)
local function copyFileContent(src, dest)
    local src_file = io.open(src, "rb")
    if not src_file then
        return false, "Cannot open source file"
    end

    local content = src_file:read("*all")
    src_file:close()

    local dest_file = io.open(dest, "wb")
    if not dest_file then
        return false, "Cannot open destination file"
    end

    dest_file:write(content)
    dest_file:close()

    return true
end

local DOIResolver = require("doi_resolver")

--- Get raw doc_props (with identifiers) from DocSettings for a file.
--- Raw props include the identifiers field that extendProps() filters out.
--- RAW = the original metadata: a title edited in Book information is NOT in
--- here (SafeDocSettings.overlayCustomProps for anything user-facing).
--- @param file string Document file path
--- @return table|nil Raw document properties, or nil
local function getRawDocProps(file)
    if not file then return nil end
    local DocSettings = require("docsettings")
    local ok, doc_settings = pcall(DocSettings.open, DocSettings, file)
    if ok and doc_settings then
        return doc_settings:readSetting("doc_props") -- raw-props: DOI identifiers, callers overlay for display
    end
    return nil
end

local function buildBookMetadata(title, authors, file, doc_props, document, doc_settings)
    local metadata = DOIResolver.buildBookMetadata(title, authors, file, doc_props, document, doc_settings)
    -- Apply per-book AI title/author override (what the AI sees; never touches library metadata).
    -- Load the sidecar from disk when no doc_settings was passed but we have a file path.
    local ds = doc_settings
    if not ds and file then
        local DocSettings = require("docsettings")
        ds = DocSettings:open(file)
    end
    return require("koassistant_book_settings").applyMetadataOverride(metadata, ds)
end

--- The synthetic "book context" string for book-level actions (chat-header display, the
--- {highlighted_text} fallback, and the [Context] fallback). Derived from the already-overridden
--- book_metadata so it honors a custom AI title/author, and limited to title + author — the AI's
--- actual book-identity comes from the Book-info-gated [Context] block, which never sends language.
local function bookContextString(metadata)
    if not metadata then return "" end
    local s = string.format("Title: %s.", metadata.title or "Unknown")
    if metadata.author and metadata.author ~= "" then
        s = s .. string.format(" Author: %s.", metadata.author)
    end
    return s
end

local AskGPT = WidgetContainer:extend{
  name = "koassistant",
  is_doc_only = false,
}

function AskGPT:init()
  logger.dbg("KOAssistant plugin: init() called")

  -- Store configuration on the instance (single source of truth)
  self.configuration = configuration

  -- Initialize settings
  self:initSettings()

  -- Initialize action service
  self.action_service = ActionService:new(self.settings)
  self.action_service:initialize()

  -- Track 37: move per-book plugin data out of KOReader's metadata.lua
  -- (one-shot, runs before any read; see _runBookStoreMigration)
  self:_runBookStoreMigration()

  -- Register dispatcher actions
  self:onDispatcherRegisterActions()

  -- Patch DocSettings for chat index tracking on file moves
  self:patchDocSettingsForChatIndex()

  -- Cross-book X-Ray knowledge (S4, ref #90): the lookup direction follows
  -- the current book's spoiler protection; group edits and live X-Ray writes
  -- re-seed the members' carried lists (deferred, zero tokens)
  self:_installGroupSeedingHooks()

  -- Chat index validation deferred to first chat history browser open
  -- (see ChatHistoryDialog:showChatHistoryBrowser for lazy validation)

  -- Auto-check for updates at startup (if enabled)
  -- Use isWifiOn() as a fast, non-blocking guard (avoids isOnline() which can block
  -- the UI thread for several seconds on shaky WiFi connections).
  -- The HTTP request runs in a subprocess with an 8-second timeout, so it fails
  -- gracefully when offline without blocking the UI.
  local features = self.settings:readSetting("features") or {}
  if features.auto_check_updates ~= false then
    -- 24h min-interval (timestamp written by the checker on SUCCESS only): skips the
    -- fork + GitHub call + JSON parse — and even loading the checker module — on most
    -- starts. Cheap G_reader_settings read; registered in the storage registry.
    local last_check = G_reader_settings:readSetting("koassistant_last_update_check")
    if type(last_check) == "number" and os.time() - last_check < 24 * 60 * 60 then
      logger.dbg("KOAssistant: Skipping auto update check (checked within 24h)")
    else
      -- 20s defer (was 1s): keeps the subprocess fork out of the book-open/FM
      -- rendering hot window on slow e-ink devices.
      UIManager:scheduleIn(20, function()
        if not NetworkMgr:isWifiOn() then
          logger.dbg("KOAssistant: Skipping auto update check (Wi-Fi not on)")
          return
        end
        local ok, err = pcall(function()
          local UpdateChecker = require("koassistant_update_checker")
          UpdateChecker.checkForUpdates(true) -- auto = true (silent background check)
        end)
        if not ok then
          logger.warn("KOAssistant: Auto update check failed:", err)
        end
      end)
    end
  end

  -- Add to highlight dialog if highlight feature is available.
  -- All KOAssistant buttons register UNCONDITIONALLY; visibility is decided per
  -- menu-open via show_in_highlight_dialog_func (KOReader rebuilds the button table
  -- on every onShowHighlightMenu), so toggle/ordering changes apply the next time
  -- the menu opens — no restart or book reopen needed.
  if self.ui and self.ui.highlight then
    -- Main KOAssistant button (controlled separately from quick actions)
    self.ui.highlight:addToHighlightDialog("koassistant_dialog", function(reader_highlight_instance)
        return {
          text = _("Chat/Action") .. " (KOA)",
          enabled = Device:hasClipboard(),
          show_in_highlight_dialog_func = function()
            local feats = self.settings:readSetting("features") or {}
            return feats.show_koassistant_in_highlight ~= false
          end,
          callback = function()
            -- Capture text and close highlight overlay to prevent darkening on saved highlights
            local selected_text = reader_highlight_instance.selected_text.text

            -- Capture full selection data for "Save to Note" feature (before onClose clears it)
            local selection_data = nil
            if reader_highlight_instance.selected_text then
              local st = reader_highlight_instance.selected_text
              selection_data = {
                text = st.text,
                pos0 = st.pos0,
                pos1 = st.pos1,
                sboxes = st.sboxes,
                pboxes = st.pboxes,
                ext = st.ext,
                drawer = st.drawer,
                color = st.color,
              }
            end

            -- Pre-extract the surrounding-context window while the selection is alive
            -- (onClose clears it; the dialog trims/sends per the resolved mode later)
            local sc_window = Dialogs.fetchSelectionContextWindow(self.ui, selected_text)

            reader_highlight_instance:onClose()
            self:ensureInitialized()
            -- Make sure we're using the latest configuration
            self:updateConfigFromSettings()
            -- Scrub stale cross-context state for highlight context (default context)
            configuration.features = configuration.features or {}
            self:_scrubContextFeatures(configuration.features)
            -- Store selection data for "Save to Note" feature
            configuration.features.selection_data = selection_data
            configuration.features._selection_context_window = sc_window
            showChatGPTDialog(self.ui, selected_text, configuration, nil, self)
          end,
        }
    end)

    -- "Add to notebook" utility button — saves the selection straight to this book's
    -- notebook, no AI involved. Registration id sorts just before "koassistant_dialog"
    -- under orderedPairs, placing it second-to-last (maintainer decision 2026-07-15).
    self.ui.highlight:addToHighlightDialog("koassistant_add_notebook", function(reader_highlight_instance)
      return {
        text = _("Add to notebook") .. " (KOA)",
        show_in_highlight_dialog_func = function()
          local feats = self.settings:readSetting("features") or {}
          -- Opt-in since the A9 follow-up 2026-08-17 (maintainer: highlight-menu
          -- pare-down; the toggle lives in Menus & Buttons > Highlight menu)
          return feats.show_notebook_in_highlight == true
        end,
        hold_callback = function()
          UIManager:show(InfoMessage:new{
            text = _("Save the selected text to this book's notebook (creates the notebook if needed)."),
          })
        end,
        callback = function()
          -- Capture before onClose clears the selection
          local selected_text = reader_highlight_instance.selected_text
            and reader_highlight_instance.selected_text.text
          reader_highlight_instance:onClose()
          if not selected_text or selected_text == "" then return end
          local doc_path = self.ui and self.ui.document and self.ui.document.file
          if not doc_path then return end
          local Notebook = require("koassistant_notebook")
          local ChatGPTViewer = require("koassistant_chatgptviewer")
          ChatGPTViewer.appendSnippetToNotebook(doc_path, selected_text, {
            page_info = Notebook.getPageInfo(self.ui),
            book_title = self.ui.doc_props
              and (self.ui.doc_props.display_title or self.ui.doc_props.title),
          })
        end,
      }
    end)
    -- The old hardcoded "Generate Image" button is RETIRED (2026-08-13): image
    -- generation is the `image_gen` ACTION now — membership/order via the
    -- Highlight Menu manager, provider-capability gate in the action getters
    -- (requires_image_provider), dispatch through handleLocalAction. The old
    -- "Show Generate Image button" toggle is migrated in initSettings.

    logger.dbg("KOAssistant: highlight-menu buttons registered (visibility resolved per menu open)")

    -- Register quick-action shortcut slots (own toggle; resolved per menu open)
    self:registerHighlightMenuActions()
  else
    logger.dbg("Highlight feature not available, skipping highlight dialog integration")
  end

  -- Sync dictionary bypass setting (override Translator if enabled)
  self:syncDictionaryBypass()

  -- Register dictionary-popup AI buttons on KOReader's new addToDictButtons API
  -- (no-op on older builds, which use the legacy onDictButtonsReady event).
  self:installDictButtonRegistration()

  -- Register to main menu immediately
  self:registerToMainMenu()
  
  -- Also register when reader is ready as a backup
  self.onReaderReady = function()
    -- Track 37 straggler net: anything an older build (or an unmigrated
    -- sidecar synced from another device) left in this book's metadata.lua
    -- is folded into our files before any read. A table scan when clean.
    if self.ui and self.ui.document and self.ui.doc_settings then
      local ok_m, err_m = pcall(function()
        require("koassistant_book_store").ensureMigrated(self.ui.document.file, self.ui.doc_settings)
      end)
      if not ok_m then logger.warn("KOAssistant: book store straggler check failed:", err_m) end
    end
    self:registerToMainMenu()
    -- Sync highlight bypass (needs ui.highlight to be available)
    self:syncHighlightBypass()
    -- Round 5 (per-book intercept): the dict wrapper's install gate consults
    -- the OPEN book's override, so re-evaluate per book open (idempotent)
    self:syncDictionaryBypass()
    -- Ambient X-Ray marks (slice 2): install the paint module + first scan
    self:syncXrayMarks()
    -- Backup: ensure new-API dict buttons are registered (idempotent;
    -- covers cases where ui.dictionary wasn't ready at init time).
    self:installDictButtonRegistration()
    -- Auto-reopen X-Ray browser after opening book from file browser
    local XrayBrowser = require("koassistant_xray_browser")
    if XrayBrowser._pending_reopen then
      local pending = XrayBrowser._pending_reopen
      XrayBrowser._pending_reopen = nil
      local book_file = self.ui and self.ui.document and self.ui.document.file
      if book_file and book_file == pending.book_file then
        -- Stash navigate_to for show() to pick up after scheduleIn delay
        if pending.navigate_to then
          XrayBrowser._pending_navigate_to = pending.navigate_to
        end
        local UIManager = require("ui/uimanager")
        UIManager:scheduleIn(0.5, function()
          local ActionCache = require("koassistant_action_cache")
          local cached = ActionCache.getXrayCache(book_file)
          if cached then
            self:showCacheViewer({
              name = "X-Ray",
              key = "_xray_cache",
              data = cached,
            })
          end
        end)
      end
    end
    -- Auto-reopen the Book Hub after "Open Book" on its closed-book view
    -- (same pattern as the X-Ray browser reopen above)
    local BookPageReopen = require("koassistant_book_page")
    if BookPageReopen._pending_reopen then
      local bp_pending = BookPageReopen._pending_reopen
      BookPageReopen._pending_reopen = nil
      local bp_file = self.ui and self.ui.document and self.ui.document.file
      if bp_file and bp_file == bp_pending.book_file then
        local UIManager = require("ui/uimanager")
        UIManager:scheduleIn(0.5, function()
          local props = self.ui and self.ui.doc_props
          BookPageReopen.show({
            file = bp_file,
            plugin = self,
            ui = self.ui,
            title = props and (props.display_title or props.title),
            author = props and props.authors,
            enable_emoji = configuration and configuration.features
                and configuration.features.enable_emoji_icons == true,
          })
        end)
      end
    end
    -- Check if recap reminder should be shown
    self:checkRecapReminder()
    -- One-shot Automatic X-Ray offer (§7 P4, opt-in; gates inside)
    self:checkXrayOffer()
    -- Initialize chapter quiz state (reset on each book open). The chapter boundary list is
    -- recomputed lazily on the first page turn (and whenever the level setting changes), since
    -- the TOC may not be filled yet here.
    self._quiz_cur_idx = nil
    self._last_quiz_offered_chapter = nil
    self._last_quiz_page = nil
    self._quiz_chapter_indices = nil
    self._quiz_level = nil
    self._quiz_setting = nil
    -- X-Ray background auto-update: load the per-book pre-filter state, then a
    -- session-start catch-up pass (update-checker delay pattern; obeys ALL gates
    -- including the delta cap — it serves only modest cross-session gaps, plan §8.3)
    self:_refreshXrayAutoState()
    if self._xray_auto_state and self._xray_auto_state.auto_update then
      local XrayAuto = require("koassistant_xray_auto")
      local xa_file = self.ui and self.ui.document and self.ui.document.file
      local UIManager = require("ui/uimanager")
      UIManager:scheduleIn(XrayAuto.CATCHUP_DELAY_S, function()
        if not (self.ui and self.ui.document and self.ui.document.file == xa_file) then return end
        local ok, cur = pcall(function() return self.ui.document:getCurrentPage() end)
        if ok and type(cur) == "number" then
          local st = self._xray_auto_state
          if st then st.prev_page = cur end  -- same page → the jump guard passes
          self:_xrayAutoOnPageUpdate(cur)
        end
      end)
    elseif self._xray_auto_state and self._xray_auto_state.rung_progress then
      -- 50(f): posture pass on open for ladder books without auto — settings
      -- may have changed while the book was closed (spoiler protection off →
      -- install the newest rung; back on over a posture-promoted install →
      -- revert to the position rung). The fire re-checks everything and
      -- no-ops when the posture and the live entry already agree.
      self:_scheduleXrayLadderPromotion()
    end
    -- Heal KOAssistant data indexes for this book (issue #92): synced or
    -- restored sidecar data becomes visible in the global browsers through
    -- normal use. Deferred off the book-open path; each refresh writes
    -- settings only when its index entry actually changed. Snapshot the path
    -- and ui now — the user may close/switch books before the timer fires
    -- (SafeDocSettings degrades to a fresh read-only open in that case).
    local heal_file = self.ui and self.ui.document and self.ui.document.file
    if heal_file then
      local heal_ui = self.ui
      local UIManager = require("ui/uimanager")
      UIManager:scheduleIn(2, function()
        local ok, err = pcall(function()
          require("koassistant_action_cache").refreshIndex(heal_file)
          require("koassistant_chat_history_manager"):refreshChatIndexEntry(heal_file, heal_ui)
          require("koassistant_notebook").refreshIndexEntry(heal_file)
          require("koassistant_pinned_manager").refreshIndex(heal_file)
        end)
        if not ok then
          logger.warn("KOAssistant: index heal-on-open failed:", err)
        end
      end)
    end
  end
  
  -- Register file dialog buttons with delays to ensure they appear at the bottom
  -- First attempt after a short delay to let core plugins register
  UIManager:scheduleIn(0.5, function()
    logger.dbg("KOAssistant: First file dialog button registration (0.5s delay)")
    self:addFileDialogButtons()
  end)

  -- Second attempt after other plugins should be loaded
  UIManager:scheduleIn(2, function()
    logger.dbg("KOAssistant: Second file dialog button registration (2s delay)")
    self:addFileDialogButtons()
  end)

  -- Final attempt to ensure registration in all contexts
  UIManager:scheduleIn(5, function()
    logger.dbg("KOAssistant: Final file dialog button registration (5s delay)")
    self:addFileDialogButtons()
  end)
  
  -- Patch TextViewer and DictQuickLookup for dictionary + selection popup
  self:patchTextSelectionHandlers()

  -- Patch FileManager for multi-select support
  self:patchFileManagerForMultiSelect()

  -- Opt-in startup index rebuild (issue #92): quiet, throttled to once per
  -- 24h, and only meaningful when scan folders are configured (heal-on-open
  -- already converges local knowledge without it).
  do
    local feats = self.settings:readSetting("features") or {}
    if feats.index_rebuild_on_start == true
       and type(feats.index_scan_folders) == "table" and #feats.index_scan_folders > 0 then
      local last = tonumber(feats._last_auto_index_rebuild) or 0
      local now = os.time()
      if now - last >= 24 * 60 * 60 then
        -- Stamp before running so the second plugin instance created in the
        -- same session (FileManager vs ReaderUI) doesn't run it again.
        feats._last_auto_index_rebuild = now
        self.settings:saveSetting("features", feats)
        self.settings:flush()
        UIManager:scheduleIn(15, function()
          self:rebuildAllIndexes({ quiet = true })
        end)
      end
    end
  end
end

-- Split flat button list into rows of max N, equally distributed
-- Example: 5 buttons, max 4 -> rows of 3+2; 7 buttons -> 4+3; 8 -> 4+4
local function splitIntoRows(buttons, max_per_row)
  if #buttons == 0 then return nil end
  if #buttons <= max_per_row then return { buttons } end
  local num_rows = math.ceil(#buttons / max_per_row)
  local base = math.floor(#buttons / num_rows)
  local extra = #buttons % num_rows  -- first 'extra' rows get base+1 items
  local rows = {}
  local idx = 1
  for r = 1, num_rows do
    local row_size = base + (r <= extra and 1 or 0)
    local row = {}
    for _j = 1, row_size do
      table.insert(row, buttons[idx])
      idx = idx + 1
    end
    table.insert(rows, row)
  end
  return rows
end

-- Button generator for all KOA file dialog buttons (utilities + main)
-- Returns array of rows (max 4 buttons per row, equally distributed)
function AskGPT:generateFileDialogRows(file, is_file, book_props)
  logger.dbg("KOAssistant: generateFileDialogRows called with file=" .. tostring(file))

  -- Only show buttons for document files
  if not is_file or not self:isDocumentFile(file) then
    return nil
  end

  -- Get features for settings (read fresh from settings, not stale CONFIG)
  local features = self.settings:readSetting("features") or {}

  -- Check notebook and chat status
  local Notebook = require("koassistant_notebook")
  local has_notebook = Notebook.exists(file)
  local has_chats = self:documentHasChats(file)

  local buttons = {}

  -- Main Chat/Action button (always first - primary entry point)
  -- Title fallback: book_props → DocSettings (display_title/title) → filename
  local title = book_props and book_props.title or nil
  if not title or title == "" then
    local DocSettings = require("docsettings")
    local doc_settings = DocSettings:open(file)
    local doc_props = require("koassistant_doc_settings").overlayCustomProps(doc_settings:readSetting("doc_props"), file)
    title = doc_props and (doc_props.display_title or doc_props.title) or nil
  end
  if not title or title == "" then
    title = file:match("([^/]+)%.[^%.]+$") or file:match("([^/]+)$")
  end
  local authors = book_props and book_props.authors or ""
  local self_ref_main = self
  -- Every utility button below is individually toggleable (File Browser Items
  -- manager + Menus & Buttons ▸ File browser — same features.* booleans,
  -- default true, read `~= false`); dynamic conditions (has_chats etc.) AND
  -- with the toggle
  if features.show_chat_action_in_file_browser ~= false then
    table.insert(buttons, {
      text = _("Chat/Action") .. " (KOA)",
      callback = function()
        local UIManager = require("ui/uimanager")
        local current_dialog = UIManager:getTopmostVisibleWidget()
        if current_dialog then
          UIManager:close(current_dialog)
        end
        self_ref_main:showKOAssistantDialogForFile(file, title, authors, book_props)
      end,
    })
  end

  -- Notebook (KOA) button - respects settings
  local show_notebook = features.show_notebook_in_file_browser ~= false  -- default true
  local require_existing = features.notebook_button_require_existing ~= false  -- default true
  if show_notebook and (has_notebook or not require_existing) then
    table.insert(buttons, {
      text = _("Notebook") .. " (KOA)",
      callback = function()
        local UIManager = require("ui/uimanager")
        local current_dialog = UIManager:getTopmostVisibleWidget()
        if current_dialog then
          UIManager:close(current_dialog)
        end
        self:openNotebookForFile(file)  -- view mode
      end,
      hold_callback = function()
        local UIManager = require("ui/uimanager")
        local current_dialog = UIManager:getTopmostVisibleWidget()
        if current_dialog then
          UIManager:close(current_dialog)
        end
        self:openNotebookForFile(file, true)  -- edit mode
      end,
    })
  end

  -- Chat History (KOA) button - only if chats exist
  if features.show_chat_history_in_file_browser ~= false and has_chats then
    table.insert(buttons, {
      text = _("Chat History") .. " (KOA)",
      callback = function()
        local UIManager = require("ui/uimanager")
        local current_dialog = UIManager:getTopmostVisibleWidget()
        if current_dialog then
          UIManager:close(current_dialog)
        end
        self:showChatHistoryForFile(file)
      end,
    })
  end

  -- View Artifacts (KOA) button - if any document cache exists for this file
  local ActionCache = require("koassistant_action_cache")
  local caches = ActionCache.getAvailableArtifactsWithPinned(file)
  -- Add book metadata for file browser context (no open book)
  for _idx, cache in ipairs(caches) do
    if not cache.is_pinned_group then
      cache.book_title = title
      cache.book_author = authors
      cache.file = file
    end
  end
  -- Refresh artifact index for this document (populates index for pre-existing artifacts)
  if #caches > 0 then
    ActionCache.refreshIndex(file)
  end
  if features.show_artifacts_in_file_browser ~= false and #caches > 0 then
    local self_ref = self
    table.insert(buttons, {
      text = _("View Artifacts") .. " (KOA)",
      callback = function()
        local UIManager = require("ui/uimanager")
        -- Capture file browser menu reference before showing popup
        local fb_menu = UIManager:getTopmostVisibleWidget()
        local ButtonDialog = require("ui/widget/buttondialog")
        local btn_rows = {}
        for _idx, cache in ipairs(caches) do
          local display = cache.name
          if not cache.is_pinned_group and not cache.is_section_group and not cache.is_wiki_group then
            -- Shared meta (A4 parity): "X-Ray (65%, today)", percent always
            local meta = Constants.formatArtifactMeta(cache.data)
            if meta then display = display .. " (" .. meta .. ")" end
          end
          table.insert(btn_rows, {{
            text = display,
            callback = function()
              if cache.is_image_group then
                UIManager:close(self_ref._cache_selector)
                if fb_menu then UIManager:close(fb_menu) end
                local ImageBrowser = require("koassistant_image_browser")
                ImageBrowser.show({ book_file = file, book_title = title })
              elseif cache.is_xray_versions_group then
                UIManager:close(self_ref._cache_selector)
                if fb_menu then UIManager:close(fb_menu) end
                self_ref:_showXrayCheckpointList({ file = file,
                  book_title = title, book_author = authors })
              elseif cache.is_section_group or cache.is_wiki_group or cache.is_pinned_group then
                local ArtifactBrowser = require("koassistant_artifact_browser")
                local selector = self_ref._cache_selector
                local close_all = function()
                  UIManager:close(selector)
                  if fb_menu then UIManager:close(fb_menu) end
                end
                if cache.is_section_xray_group then
                  ArtifactBrowser:_showSectionXrayGroupPopup(
                      cache.data, file, title, self_ref, cache._excluded_section_key, close_all)
                elseif cache.is_section_group then
                  ArtifactBrowser:_showSectionGroupPopup(
                      cache.data, file, title, self_ref, cache.section_type, cache._excluded_section_key, close_all)
                elseif cache.is_wiki_group then
                  ArtifactBrowser:_showWikiGroupPopup(cache.data, file, self_ref, title, close_all)
                else
                  ArtifactBrowser:_showPinnedGroupPopup(cache.data, file, title, close_all)
                end
              else
                UIManager:close(self_ref._cache_selector)
                -- Close file browser menu after selection
                if fb_menu then
                  UIManager:close(fb_menu)
                end
                if cache.is_per_action then
                  self_ref:viewCachedAction({ text = cache.name }, cache.key, cache.data, { file = cache.file, book_title = cache.book_title, book_author = cache.book_author })
                else
                  self_ref:showCacheViewer(cache)
                end
              end
            end,
          }})
        end
        table.insert(btn_rows, {{
          text = require("koassistant_book_page").entryLabel(),
          callback = function()
            UIManager:close(self_ref._cache_selector)
            if fb_menu then UIManager:close(fb_menu) end
            require("koassistant_book_page").show({
              file = file,
              plugin = self_ref,
              ui = self_ref.ui,
              title = title,
              author = authors,
              enable_emoji = configuration and configuration.features
                  and configuration.features.enable_emoji_icons == true,
            })
          end,
        }})
        table.insert(btn_rows, {{
          text = _("Cancel"),
          callback = function()
            UIManager:close(self_ref._cache_selector)
          end,
        }})
        self_ref._cache_selector = ButtonDialog:new{
          title = _("View Artifacts"),
          buttons = btn_rows,
        }
        UIManager:show(self_ref._cache_selector)
      end,
    })
  end

  -- Book Hub (KOA) button — the book's home page (before Book Settings,
  -- maintainer 2026-08-09); toggleable like the Notebook button since the A4
  -- follow-up (Menus & Buttons ▸ File browser, default true)
  if features.show_book_hub_in_file_browser ~= false then
    table.insert(buttons, {
      text = require("koassistant_book_page").pageName() .. " (KOA)",
      callback = function()
        local UIManager = require("ui/uimanager")
        local current_dialog = UIManager:getTopmostVisibleWidget()
        if current_dialog then
          UIManager:close(current_dialog)
        end
        require("koassistant_book_page").show({
          file = file,
          plugin = self,
          ui = self.ui,
          title = title,
          author = authors,
          enable_emoji = configuration and configuration.features
              and configuration.features.enable_emoji_icons == true,
        })
      end,
    })
  end

  -- Book Settings (KOA) button — per-book domain, research, AI title/author overrides
  if features.show_book_settings_in_file_browser ~= false then
    table.insert(buttons, {
      text = _("Book Settings") .. " (KOA)",
      callback = function()
        local UIManager = require("ui/uimanager")
        local current_dialog = UIManager:getTopmostVisibleWidget()
        if current_dialog then
          UIManager:close(current_dialog)
        end
        local BookSettings = require("koassistant_book_settings")
        BookSettings.show({ plugin = self, ui = self.ui, document_path = file })
      end,
    })
  end

  -- Pinned file browser actions (user-selected via Action Manager hold menu)
  local fb_actions = self.action_service and self.action_service:getFileBrowserActions() or {}
  if #fb_actions > 0 then
    local self_ref = self
    for _idx, fb_action in ipairs(fb_actions) do
      local full_action = self.action_service and self.action_service:getAction("book", fb_action.id)
      local action_for_hold = full_action or fb_action
      table.insert(buttons, {
        text = ActionService.getActionDisplayText(action_for_hold, features) .. " (KOA)",
        allow_hold_when_disabled = true,
        callback = function()
          local UIManager = require("ui/uimanager")
          local current_dialog = UIManager:getTopmostVisibleWidget()
          if current_dialog then
            UIManager:close(current_dialog)
          end
          self_ref:executeFileBrowserAction(file, title, authors, book_props, fb_action.id)
        end,
        hold_callback = function()
          if action_for_hold and action_for_hold.description then
            local InfoMessage = require("ui/widget/infomessage")
            UIManager:show(InfoMessage:new{
              text = action_for_hold.description,
            })
          end
        end,
      })
    end
  end

  -- Split into rows of max 4, equally distributed
  logger.dbg("KOAssistant: Returning " .. #buttons .. " button(s) in rows")
  return splitIntoRows(buttons, 4)
end

-- Button generator for multiple file selection
function AskGPT:generateMultiSelectButtons(file, is_file, book_props)
  -- Check if we have multiple files selected
  if FileManager.instance and FileManager.instance.selected_files and
     next(FileManager.instance.selected_files) then
    logger.dbg("KOAssistant: Multiple files selected")
    return {
      {
        text = _("Compare with KOAssistant"),
        callback = function()
          local UIManager = require("ui/uimanager")
          local current_dialog = UIManager:getTopmostVisibleWidget()
          if current_dialog then
            UIManager:close(current_dialog)
          end
          self:compareSelectedBooks(FileManager.instance.selected_files)
        end,
      },
    }
  end
end

-- Add file dialog buttons using the FileManager instance API
function AskGPT:addFileDialogButtons()
  -- Prevent multiple registrations
  if self.file_dialog_buttons_added then
    logger.dbg("KOAssistant: File dialog buttons already registered, skipping")
    return true
  end

  -- Check if file browser integration is disabled
  local f = self.settings:readSetting("features") or {}
  if f.show_in_file_browser == false then
    logger.dbg("KOAssistant: File browser integration disabled")
    return true  -- Return true to prevent retry attempts
  end

  logger.dbg("KOAssistant: Attempting to add file dialog buttons")

  -- Load other managers carefully to avoid circular dependencies
  local FileManagerHistory, FileManagerCollection, FileManagerFileSearcher
  pcall(function()
    FileManagerHistory = require("apps/filemanager/filemanagerhistory")
  end)
  pcall(function()
    FileManagerCollection = require("apps/filemanager/filemanagercollection")
  end)
  pcall(function()
    FileManagerFileSearcher = require("apps/filemanager/filemanagerfilesearcher")
  end)
  
  -- Create closures that bind self
  -- All KOA buttons (utilities + main) distributed across rows (max 4 per row)
  -- Row cache avoids recomputing for each row slot in the same dialog open
  -- Stored on self so delete callbacks can invalidate it
  self._file_dialog_row_cache = { file = nil, rows = nil }
  local row_generators = {}
  -- Key set MUST stay in sync with removeFileDialogButtons' list
  local row_keys = { "zzz_koassistant_1a", "zzz_koassistant_1b", "zzz_koassistant_1c" }
  for slot = 1, 3 do
    local row_index = slot
    row_generators[slot] = function(file, is_file, book_props)
      if self._file_dialog_row_cache.file ~= file then
        self._file_dialog_row_cache.file = file
        self._file_dialog_row_cache.rows = self:generateFileDialogRows(file, is_file, book_props)
      end
      return self._file_dialog_row_cache.rows and self._file_dialog_row_cache.rows[row_index]
    end
  end

  -- KOA group break (maintainer 2026-08-13): a leading EMPTY row renders as
  -- ButtonTable's double-rule between KOReader's native rows and the KOA
  -- section. Registered FIRST — generators run in registration order
  -- (filemanager.lua inserts returned rows in ipairs order) — and emits only
  -- when a KOA row will actually follow, so folders/non-documents get no
  -- stray line. Shares the row cache (it runs first, so it fills it).
  local separator_generator = function(file, is_file, book_props)
    -- Recompute UNCONDITIONALLY: this generator runs FIRST per dialog build
    -- (verified: filechooser.lua iterates file_dialog_added_buttons with ipairs
    -- in registration order), so the cache now only shares the compute among
    -- the 4 generators of ONE build (A9 sitting 2026-08-17: the old file-keyed
    -- reuse survived ACROSS opens, so re-long-pressing the SAME file after a
    -- settings toggle showed the pre-toggle rows).
    -- Disk refresh (A9 device round 2026-08-17): these closures bind ONE plugin
    -- instance forever (KOReader's addFileDialogButtons is register-once per id
    -- — duplicates are silently ignored), while toggles/dismissals may be saved
    -- by the OTHER instance (FileManager vs ReaderUI). readSetting is an
    -- in-memory read, so without this the rows only healed on restart.
    self:updateConfigFromSettings()
    self._file_dialog_row_cache.file = file
    self._file_dialog_row_cache.rows = self:generateFileDialogRows(file, is_file, book_props)
    local rows = self._file_dialog_row_cache.rows
    if rows and rows[1] then return {} end
  end

  local multi_file_generator = function(file, is_file, book_props)
    return self:generateMultiSelectButtons(file, is_file, book_props)
  end

  local success_count = 0

  -- Method 1: Register via instance method if available
  if FileManager.instance and FileManager.instance.addFileDialogButtons then
    local success = pcall(function()
      FileManager.instance:addFileDialogButtons("zzz_koassistant_0_sep", separator_generator)
      for slot = 1, 3 do
        FileManager.instance:addFileDialogButtons(row_keys[slot], row_generators[slot])
      end
      FileManager.instance:addFileDialogButtons("zzz_koassistant_multi_select", multi_file_generator)
    end)

    if success then
      logger.dbg("KOAssistant: File dialog buttons registered via instance method")
      success_count = success_count + 1
    end
  end

  -- Method 2: Register on all widget classes using static method pattern (like CoverBrowser)
  -- This ensures buttons appear in History, Collections, and Search dialogs
  local widgets_to_register = {
    filemanager = FileManager,
    history = FileManagerHistory,
    collections = FileManagerCollection,
    filesearcher = FileManagerFileSearcher,
  }

  for widget_name, widget_class in pairs(widgets_to_register) do
    if widget_class and FileManager.addFileDialogButtons then
      logger.dbg("KOAssistant: Attempting to register buttons on " .. widget_name .. " class")
      local success, err = pcall(function()
        FileManager.addFileDialogButtons(widget_class, "zzz_koassistant_0_sep", separator_generator)
        for slot = 1, 3 do
          FileManager.addFileDialogButtons(widget_class, row_keys[slot], row_generators[slot])
        end
        FileManager.addFileDialogButtons(widget_class, "zzz_koassistant_multi_select", multi_file_generator)
      end)

      if success then
        logger.dbg("KOAssistant: File dialog buttons registered on " .. widget_name)
        success_count = success_count + 1
      else
        logger.warn("KOAssistant: Failed to register buttons on " .. widget_name .. ": " .. tostring(err))
      end
    else
      if not widget_class then
        logger.dbg("KOAssistant: Widget class " .. widget_name .. " not loaded")
      else
        logger.dbg("KOAssistant: FileManager.addFileDialogButtons not available")
      end
    end
  end
  
  -- Log diagnostic information
  if success_count > 0 then
    -- Mark as registered to prevent duplicate attempts
    self.file_dialog_buttons_added = true
    -- Check what History/Collections/Search can see
    self:checkButtonVisibility()
    return true
  else
    logger.err("KOAssistant: Failed to register file dialog buttons with any method")
    return false
  end
end

function AskGPT:removeFileDialogButtons()
  -- Remove file dialog buttons (unload + the live master toggle). NO guard on
  -- self.file_dialog_buttons_added (A9 device round 2026-08-17): registration is
  -- first-instance-wins, so the toggle's on_change may run in the plugin
  -- instance that never registered — the old early-return made that a silent
  -- no-op. Removal is id-keyed and safe to attempt regardless; a follow-up
  -- addFileDialogButtons from THIS instance then re-registers live closures.
  logger.dbg("KOAssistant: Removing file dialog buttons")

  local FileManagerHistory = require("apps/filemanager/filemanagerhistory")
  local FileManagerCollection = require("apps/filemanager/filemanagercollection")
  local FileManagerFileSearcher = require("apps/filemanager/filemanagerfilesearcher")
  
  -- The REGISTERED key set (must match addFileDialogButtons). The old list
  -- here named "zzz_koassistant_1_utilities"/"_2_main" — ids that were never
  -- registered — so unload left the real 1a/1b/1c generators (and their stale
  -- self closures) behind. Fixed alongside the 0_sep addition (2026-08-13).
  local koa_row_keys = {
    "zzz_koassistant_0_sep",
    "zzz_koassistant_1a", "zzz_koassistant_1b", "zzz_koassistant_1c",
    "zzz_koassistant_multi_select",
  }

  -- Remove from instance if available
  if FileManager.instance and FileManager.instance.removeFileDialogButtons then
    pcall(function()
      for _idx, key in ipairs(koa_row_keys) do
        FileManager.instance:removeFileDialogButtons(key)
      end
    end)
  end

  -- Remove from all widget classes
  local widgets_to_clean = {
    filemanager = FileManager,
    history = FileManagerHistory,
    collections = FileManagerCollection,
    filesearcher = FileManagerFileSearcher,
  }

  for widget_name, widget_class in pairs(widgets_to_clean) do
    if widget_class and FileManager.removeFileDialogButtons then
      pcall(function()
        for _idx, key in ipairs(koa_row_keys) do
          FileManager.removeFileDialogButtons(widget_class, key)
        end
      end)
    end
  end

  self.file_dialog_buttons_added = false
  logger.dbg("KOAssistant: File dialog buttons removed")
end

function AskGPT:checkButtonVisibility()
  if FileManager.instance and FileManager.instance.file_dialog_added_buttons then
    logger.dbg("KOAssistant: FileManager.instance.file_dialog_added_buttons has " ..
                #FileManager.instance.file_dialog_added_buttons .. " entries")
  end
  if FileManager.file_dialog_added_buttons then
    logger.dbg("KOAssistant: FileManager.file_dialog_added_buttons (static) has " ..
                #FileManager.file_dialog_added_buttons .. " entries")
  end
  -- Note: Cannot check FileManagerHistory/Collection here due to circular dependency
  -- They will be checked when they're actually created
  logger.dbg("KOAssistant: Button registration complete. History/Collection will see buttons when created.")
end

function AskGPT:showKOAssistantDialogForFile(file, title, authors, book_props)
  -- Normalize multi-author strings (KOReader stores as newline-separated)
  if authors and authors:find("\n") then
    authors = authors:gsub("\n", ", ")
  end
  -- Ensure features exists
  configuration.features = configuration.features or {}

  -- Get book context configuration
  local book_context_config = configuration.features.book_context or {
    prompts = {}
  }

  logger.dbg("Book context has " ..
    (book_context_config.prompts and tostring(table_count(book_context_config.prompts)) or "0") ..
    " prompts defined")

  -- Set context flags on original configuration (no copy needed)
  -- This ensures settings changes are immediately visible
  -- Clear other context flags first
  configuration.features.is_general_context = nil
  configuration.features.is_book_context = true
  configuration.features.is_library_context = nil

  -- Store the book metadata for template substitution
  -- Use raw doc_props (from DocSettings) for DOI extraction — includes identifiers field
  local raw_doc_props = getRawDocProps(file) or book_props
  configuration.features.book_metadata = buildBookMetadata(title, authors, file, raw_doc_props,
      self.ui and self.ui.document, self.ui and self.ui.doc_settings)
  -- Display/fallback book-context string, derived from the overridden metadata (title+author only).
  local book_context = bookContextString(configuration.features.book_metadata)
  configuration.features.book_context = book_context

  -- Add reading progress to book_metadata for spoiler-free mode
  -- Use live data from open book if it matches, otherwise load from DocSettings
  local bm = configuration.features.book_metadata
  if self.ui and self.ui.document and self.ui.document.file == file then
    -- Open book: live progress from context extractor
    if self.ui.koassistant and self.ui.koassistant.context_extractor then
      local progress = self.ui.koassistant.context_extractor:getReadingProgress()
      bm.reading_progress = progress.formatted
      bm.progress_decimal = progress.decimal
    end
  end
  if not bm.reading_progress and file then
    -- File browser or different book: load from DocSettings
    local DocSettings = require("docsettings")
    local ds = DocSettings:open(file)
    local pf = ds:readSetting("percent_finished")
    if pf and pf > 0 then
      bm.reading_progress = tostring(math.floor(pf * 100 + 0.5)) .. "%"
      bm.progress_decimal = pf
    end
  end

  self:ensureInitialized()
  -- Make sure we're using the latest configuration
  self:updateConfigFromSettings()
  -- Show dialog with book context instead of highlighted text
  -- Pass book_metadata so action input popup can access file path for artifact viewers
  local book_metadata = configuration.features.book_metadata
  showChatGPTDialog(self.ui, book_context, configuration, nil, self, book_metadata)
end

function AskGPT:isDocumentFile(file)
  -- Check if the file is a supported document type
  local DocumentRegistry = require("document/documentregistry")
  return DocumentRegistry:hasProvider(file)
end


function AskGPT:compareSelectedBooks(selected_files)
  -- Check if we have selected files
  if not selected_files then
    logger.err("KOAssistant: compareSelectedBooks called with nil selected_files")
    UIManager:show(InfoMessage:new{
      text = _("No files selected for comparison"),
    })
    return
  end
  
  local DocumentRegistry = require("document/documentregistry")
  local books_info = {}
  
  -- Try to load BookInfoManager to get cached metadata
  local BookInfoManager = nil
  local ok = pcall(function()
    BookInfoManager = require("bookinfomanager")
  end)
  
  -- Log how many files we're processing
  local file_count = 0
  for file, _ in pairs(selected_files) do
    file_count = file_count + 1
    logger.dbg("KOAssistant: Selected file " .. file_count .. ": " .. tostring(file))
  end
  logger.dbg("KOAssistant: Processing " .. file_count .. " selected files")
  
  -- Gather info about each selected book
  for file, _ in pairs(selected_files) do
    if self:isDocumentFile(file) then
      local title = nil
      local authors = ""
      
      -- First try to get metadata from BookInfoManager (cached)
      if ok and BookInfoManager then
        local book_info = BookInfoManager:getBookInfo(file)
        if book_info then
          title = book_info.title
          authors = book_info.authors or ""
        end
      end
      
      -- If no cached metadata, try to extract from filename
      if not title then
        -- Try to extract cleaner title from filename
        local filename = file:match("([^/]+)$")
        if filename then
          -- Remove extension
          title = filename:gsub("%.%w+$", "")
          -- Try to extract title and author from common filename patterns
          -- Pattern: "Title · Additional Info -- Author -- Other Info"
          local extracted_title, extracted_author = title:match("^(.-)%s*·.*--%s*([^-]+)")
          if extracted_title and extracted_author then
            title = extracted_title:gsub("%s+$", "")
            authors = extracted_author:gsub("%s+$", ""):gsub(",%s*$", "")
          else
            -- Pattern: "Author - Title"
            extracted_author, extracted_title = title:match("^([^-]+)%s*-%s*(.+)")
            if extracted_author and extracted_title and not extracted_title:match("%-") then
              title = extracted_title:gsub("%s+$", "")
              authors = extracted_author:gsub("%s+$", "")
            end
          end
        end
      end
      
      -- Final fallback
      if not title or title == "" then
        title = file:match("([^/]+)$") or "Unknown"
      end
      
      -- Normalize multi-author strings (KOReader stores as newline-separated)
      if authors and authors:find("\n") then
        authors = authors:gsub("\n", ", ")
      end

      logger.dbg("KOAssistant: Book info - Title: " .. tostring(title) .. ", Authors: " .. tostring(authors))

      table.insert(books_info, {
        title = title,
        authors = authors,
        file = file
      })
    else
      logger.warn("KOAssistant: File is not a document: " .. tostring(file))
    end
  end

  logger.dbg("KOAssistant: Collected info for " .. #books_info .. " books")
  
  -- Create comparison prompt
  if #books_info < 2 then
    UIManager:show(InfoMessage:new{
      text = _("Please select at least 2 books to compare"),
    })
    return
  end
  
  local books_list = {}
  for i, book in ipairs(books_info) do
    if book.authors ~= "" then
      table.insert(books_list, string.format('%d. "%s" by %s', i, book.title, book.authors))
    else
      table.insert(books_list, string.format('%d. "%s"', i, book.title))
    end
  end
  
  logger.dbg("KOAssistant: Books list for comparison:")
  for i, book_str in ipairs(books_list) do
    logger.dbg("  " .. book_str)
  end
  
  -- Build the book context that will be used by the multi_file_browser prompts
  local prompt_text = string.format("Selected %d books for comparison:\n\n%s",
                                    #books_info,
                                    table.concat(books_list, "\n"))

  logger.dbg("KOAssistant: Book context for comparison: " .. prompt_text)

  -- Ensure features exists
  configuration.features = configuration.features or {}

  -- Set context flags on original configuration (no copy needed)
  -- This ensures settings changes are immediately visible
  -- Clear other context flags first
  configuration.features.is_general_context = nil
  configuration.features.is_book_context = nil
  configuration.features.is_library_context = true
  configuration.features._group_launch = nil

  -- Store the books list as context
  configuration.features.book_context = prompt_text
  configuration.features.books_info = books_info  -- Store the parsed book info for template substitution

  -- Store metadata for template substitution (using first book's info)
  -- No DOI for library context (no single document to identify)
  if #books_info > 0 then
    configuration.features.book_metadata = buildBookMetadata(
      books_info[1].title, books_info[1].authors)
  end

  self:ensureInitialized()
  -- Make sure we're using the latest configuration
  self:updateConfigFromSettings()
  -- Pass the prompt as book context with configuration
  -- Use FileManager.instance as the UI context
  local ui_context = self.ui or FileManager.instance
  showChatGPTDialog(ui_context, prompt_text, configuration, nil, self)
end

-- Generate button for multi-select plus dialog
function AskGPT:genMultipleKOAssistantButton(close_dialog_toggle_select_mode_callback, button_disabled, selected_files)
  return {
    {
      text = _("Compare with KOAssistant"),
      enabled = not button_disabled,
      callback = function()
        -- Capture selected files before closing dialog
        local files_to_compare = selected_files or (FileManager.instance and FileManager.instance.selected_files)
        if files_to_compare then
          -- Make a copy of selected files since they may be cleared after dialog closes
          local files_copy = {}
          for file, val in pairs(files_to_compare) do
            files_copy[file] = val
          end
          -- Close the multi-select dialog first
          local dialog = UIManager:getTopmostVisibleWidget()
          if dialog then
            UIManager:close(dialog)
          end
          -- Don't toggle select mode yet - let the comparison finish first
          -- Schedule the comparison to run after dialog closes
          UIManager:scheduleIn(0.1, function()
            self:compareSelectedBooks(files_copy)
          end)
        else
          logger.err("KOAssistant: No selected files found for comparison")
          UIManager:show(InfoMessage:new{
            text = _("No files selected for comparison"),
          })
        end
      end,
    },
  }
end

function AskGPT:onDispatcherRegisterActions()
  logger.dbg("KOAssistant: onDispatcherRegisterActions called")

  if not Dispatcher then
    logger.warn("KOAssistant: Dispatcher module not available!")
    return
  end

  -- Register chat history action
  Dispatcher:registerAction("koassistant_chat_history", {
    category = "none",
    event = "KOAssistantChatHistory",
    title = _("KOAssistant: Chat History"),
    general = true
  })

  -- Register continue last saved chat action
  Dispatcher:registerAction("koassistant_continue_last", {
    category = "none",
    event = "KOAssistantContinueLast",
    title = _("KOAssistant: Continue Last Saved Chat"),
    general = true,
  })

  -- Register continue last opened chat action
  Dispatcher:registerAction("koassistant_continue_last_opened", {
    category = "none",
    event = "KOAssistantContinueLastOpened",
    title = _("KOAssistant: Continue Last Chat"),
    general = true,
    separator = true
  })

  -- Register KOAssistant settings action
  Dispatcher:registerAction("koassistant_settings", {
    category = "none",
    event = "KOAssistantSettings",
    title = _("KOAssistant: Settings"),
    general = true
  })

  -- Register general context chat action
  Dispatcher:registerAction("koassistant_general_chat", {
    category = "none",
    event = "KOAssistantGeneralChat",
    title = _("KOAssistant: General Chat/Action"),
    general = true
  })

  -- Register book context chat action (requires open book)
  Dispatcher:registerAction("koassistant_book_chat", {
    category = "none",
    event = "KOAssistantBookChat",
    title = _("KOAssistant: Book Chat/Action"),
    general = false,  -- Requires open book
    reader = true,
  })

  -- Register Book Hub action (A4 — gesture-assignable like its peer
  -- destinations; internal ids keep book_overview)
  Dispatcher:registerAction("koassistant_book_overview", {
    category = "none",
    event = "KOAssistantBookOverview",
    title = _("KOAssistant: Book Hub"),
    general = false,  -- Requires open book
    reader = true,
  })

  Dispatcher:registerAction("koassistant_ai_settings", {
    category = "none",
    event = "KOAssistantAISettings",
    title = _("KOAssistant: Quick Settings"),
    general = true,
  })

  Dispatcher:registerAction("koassistant_quick_actions", {
    category = "none",
    event = "KOAssistantQuickActions",
    title = _("KOAssistant: Quick Actions"),
    general = false,
    reader = true,
    separator = true
  })

  Dispatcher:registerAction("koassistant_library_actions", {
    category = "none",
    event = "KOAssistantLibraryActions",
    title = _("KOAssistant: Library Chat/Action"),
    general = true,
  })

  Dispatcher:registerAction("koassistant_toggle_dictionary_bypass", {
    category = "none",
    event = "KOAssistantToggleDictionaryBypass",
    title = _("KOAssistant: Toggle Dictionary Bypass"),
    general = true,
  })

  Dispatcher:registerAction("koassistant_toggle_highlight_bypass", {
    category = "none",
    event = "KOAssistantToggleHighlightBypass",
    title = _("KOAssistant: Toggle Highlight Bypass"),
    general = true,
    separator = true
  })

  Dispatcher:registerAction("koassistant_translate_page", {
    category = "none",
    event = "KOAssistantTranslatePage",
    title = _("KOAssistant: Translate Page"),
    general = false,
    reader = true,
    separator = true
  })

  -- Register user-configured action gestures (gated by show_in_gesture_menu toggle)
  -- These are toggled per-action in Action Manager → hold action → "Add to Gesture Menu"
  -- Uses ActionService:getGestureActions() to inject defaults from in_gesture_menu flags
  local gesture_features = self.settings:readSetting("features") or {}
  if gesture_features.show_in_gesture_menu ~= false then
    local gesture_actions = {}
    if self.action_service then
      gesture_actions = self.action_service:getGestureActions() or {}
    end

    for action_key, _enabled in pairs(gesture_actions) do
      -- Parse "context:id" format
      local context, action_id = action_key:match("^([^:]+):(.+)$")
      if context and action_id and self.action_service then
        local action = self.action_service:getAction(context, action_id)
        if action then
          local gesture_id = "koassistant_action_" .. context .. "_" .. action_id
          local event_name = "KOAssistantAction_" .. context .. "_" .. action_id

          Dispatcher:registerAction(gesture_id, {
            category = "none",
            event = event_name,
            title = _("KOAssistant: ") .. (action.text or action_id),
            general = (context == "general" or context == "book+general"),
            reader = (context == "book" or context == "book+general"),
          })

          -- Dynamically create handler using closure
          AskGPT["on" .. event_name] = function(self_ref)
            self_ref:executeConfigurableAction(context, action_id)
            return true
          end
          logger.dbg("KOAssistant: Registered action gesture:", gesture_id)
        else
          logger.dbg("KOAssistant: Skipping gesture for missing action:", context, action_id)
        end
      end
    end
  end

  logger.dbg("KOAssistant: Dispatcher actions registered successfully")
end

function AskGPT:registerToMainMenu()
  -- Add to KOReader's main menu
  if not self.menu_item and self.ui and self.ui.menu then
    self.menu_item = self.ui.menu:registerToMainMenu(self)
    logger.dbg("Registered KOAssistant to main menu")
  else
    if not self.ui then
      logger.warn("Cannot register to main menu: UI not available")
    elseif not self.ui.menu then
      logger.warn("Cannot register to main menu: Menu not available")
    end
  end
end

function AskGPT:initSettings()
  -- Settings file path. Deliberately NOT named `self.settings_file`: KOReader's
  -- plugin-management UI shows a "delete plugin settings" button whenever an
  -- instance exposes `settings_file`, and that button only removes this one file
  -- (orphaning everything else the plugin owns). The plugin manages its own
  -- backup/restore/reset (Track 33), so we don't expose that partial-delete hook.
  self._settings_path = DataStorage:getSettingsDir() .. "/koassistant_settings.lua"
  -- Initialize settings with default values from configuration.lua
  self.settings = LuaSettings:open(self._settings_path)

  -- Set default values if they don't exist
  if not self.settings:has("provider") then
    self.settings:saveSetting("provider", configuration.provider or "anthropic")
  end
  
  if not self.settings:has("model") then
    self.settings:saveSetting("model", configuration.model)
  end
  
  if not self.settings:has("features") then
    -- Seed ONLY what cannot come from read-through (defaults sweep D3, 2026-07-26):
    -- migration markers, plus whatever the user pinned in a REAL configuration.lua.
    -- Anything written here is materialized on disk forever, so a later schema
    -- default change can never reach that install — the seed used to bake 14
    -- schema-default-equal values and permanently froze them (finding F1).
    -- configuration.lua overrides do NOT depend on this seed: updateConfigFromSettings
    -- gap-fills them from config_file_defaults for any key absent from settings.
    -- They are copied in anyway so the Settings menu displays the user's real value.
    -- The user_config_loaded guard is load-bearing: without a configuration.lua,
    -- config_file_defaults mirrors the built-in literal at the top of this file, whose
    -- legacy `translate_to = "English"` would be seeded and then migrated into
    -- translation_language — pinning English on every fresh install, in a key that
    -- survives every reset preset.
    local seed = {
      -- Fresh installs are NOT migration candidates: without these stamps the
      -- migrations below fire on the very first launch (all their keys are nil on a
      -- fresh table). tools_posture would bake "manual", making the schema default
      -- "auto" unreachable for everyone (defaults sweep M5, 2026-07-25); the behavior
      -- migration would assign "full" instead of the "standard" default.
      behavior_migrated = true,
      _tools_posture_migrated = true,
      _tools_binary_migrated = true,
      -- Kimi regional split (2026-08-14): a fresh install must never be
      -- stamped kimi_region="china" just because apikeys.lua was pre-filled —
      -- only UPGRADING installs (which keyed against the China platform our
      -- docs pointed at) get the preserving stamp below.
      _kimi_region_migrated = true,
    }
    if user_config_loaded then
      for k, v in pairs(config_file_defaults.features) do
        seed[k] = v
      end
    end
    self.settings:saveSetting("features", seed)
  end

  -- Migration for existing users: add new settings with defaults
  -- This runs even if features already exists (for users upgrading from older versions)
  local features = self.settings:readSetting("features")
  if features then
    -- One-time feature migrations, extracted verbatim to koassistant_migrations.lua
    -- (pure, unit-tested: tests/unit/test_migrations.lua). Mutates `features` in
    -- place; the save below persists. The model-default refresh stays HERE — it is
    -- not one-time (re-evaluates every launch) and needs self + ModelLists.
    local needs_save = require("koassistant_migrations").run(features)

    -- Image gen became the image_gen ACTION (2026-08-13). One-time here, not in
    -- the pure migrations module: an explicit old "Show Generate Image button"
    -- OFF must seed a highlight-menu DISMISSAL — a top-level settings list the
    -- features-only module can't reach — so the auto-injected action doesn't
    -- resurrect the button against the user's choice. Stamp registered in the
    -- storage registry's internal bucket.
    if not features._image_gen_action_v1 then
      features._image_gen_action_v1 = true
      if features.show_image_gen_in_highlight == false then
        local dismissed = self.settings:readSetting("_dismissed_highlight_menu_actions") or {}
        local present = false
        for _idx, id in ipairs(dismissed) do
          if id == "image_gen" then present = true break end
        end
        if not present then
          table.insert(dismissed, "image_gen")
          self.settings:saveSetting("_dismissed_highlight_menu_actions", dismissed)
        end
      end
      features.show_image_gen_in_highlight = nil
      needs_save = true
    end

    -- Kimi regional split (2026-08-14): the schema default is "international",
    -- but every PRE-SPLIT kimi key was minted on the China platform our docs
    -- pointed at, and Moonshot keys are region-locked. One-time here, not in
    -- the pure migrations module: detecting an existing key needs
    -- BaseHandler.getApiKey (GUI + apikeys.lua). Fresh installs seed the stamp
    -- above so a brand-new key is never mis-stamped. Stamp registered in the
    -- storage registry's internal bucket.
    if not features._kimi_region_migrated then
      features._kimi_region_migrated = true
      if features.kimi_region == nil
          and require("koassistant_api.base").getApiKey("kimi", self.settings) then
        features.kimi_region = "china"
        logger.info("KOAssistant: existing kimi key stamped kimi_region=china (region-locked keys)")
      end
      needs_save = true
    end

    -- Model default refresh (defaults_propagation_plan.md §3, gaps G2/G3). NOT guarded by a
    -- one-time flag: it must re-evaluate whenever we bump a provider default. Safe to repeat
    -- because an explicit pick sets features.model_explicit[provider], which pins it forever.
    -- Two outcomes: an auto-baked old default moves to the current one, and a model id that
    -- no longer exists is reset instead of 404ing. The decision itself is pure + unit-tested
    -- (ModelLists.resolveModelRefresh).
    do
      local provider = features.provider or self.configuration.provider or "anthropic"
      local is_custom_provider = self:isCustomProvider(provider)
      -- Custom providers own their default and have no shipped history — leave them alone.
      if features.model and not is_custom_provider then
        local known = {}
        for _idx, id in ipairs(ModelLists[provider] or {}) do table.insert(known, id) end
        for _idx, id in ipairs((features.custom_models or {})[provider] or {}) do
          table.insert(known, id)
        end
        local action, new_model = ModelLists.resolveModelRefresh({
          model = features.model,
          current_default = self:getEffectiveDefaultModel(provider),
          explicit = (features.model_explicit or {})[provider],
          known_models = known,
          shipped_defaults = ModelLists._shipped_defaults[provider],
        })
        if action ~= "keep" and new_model then
          logger.info(string.format("KOAssistant: model %s '%s' -> '%s' (%s)",
            action, tostring(features.model), tostring(new_model), provider))
          -- Surfaced once by the UI so the switch is never silent (cost/behavior change).
          if action == "refresh" then
            features._model_switch_notice = { from = features.model, to = new_model }
          end
          features.model = new_model
          needs_save = true
        end
      end
    end

    if needs_save then
      self.settings:saveSetting("features", features)
      logger.info("KOAssistant: Migrated settings")
    end
  end

  self.settings:flush()

  -- Initialize Notebook module with plugin settings reference
  local Notebook = require("koassistant_notebook")
  Notebook.init(self.settings)

  -- Update the configuration with settings values
  self:updateConfigFromSettings()

  -- Tell the user once when we moved them onto a provider's new default model — a model
  -- change affects cost and behavior, so it must never be silent (defaults_propagation_plan.md
  -- §3 guardrails). Deferred: the UI does not exist yet this early in init.
  local notice = (self.settings:readSetting("features") or {})._model_switch_notice
  if notice and notice.to then
    UIManager:scheduleIn(3, function()
      UIManager:show(InfoMessage:new{
        text = T(_("Model updated to %1.\n\nYour provider's default changed (you were on %2). Pick a different model any time in Settings."),
          notice.to, notice.from or "?"),
        timeout = 8,
      })
    end)
    local f = self.settings:readSetting("features") or {}
    f._model_switch_notice = nil
    self.settings:saveSetting("features", f)
    self.settings:flush()
  end
end

function AskGPT:updateConfigFromSettings()
  -- Re-read settings from disk to ensure freshness across plugin instances.
  -- KOReader creates separate plugin instances for FileManager and ReaderUI;
  -- settings changed in one instance are flushed to disk but the other instance's
  -- in-memory LuaSettings remains stale. Re-reading ensures we always have the
  -- latest values regardless of which instance modified them.
  if self._settings_path then
    local fresh = LuaSettings:open(self._settings_path)
    local fresh_features = fresh:readSetting("features")
    if fresh_features then
      local mem_features = self.settings:readSetting("features")
      if mem_features then
        -- Merge disk values into existing in-memory table (preserves reference)
        for k, v in pairs(fresh_features) do
          mem_features[k] = v
        end
        -- Clear keys deleted on disk (set to nil). pairs() only sees non-nil
        -- keys, so the additive merge above can't propagate deletions.
        -- Clear any non-underscore-prefixed key in memory that's absent on disk.
        -- Underscore-prefixed keys are transient runtime flags (e.g. _spoiler_free_active)
        -- that are never persisted and must not be cleared by the disk sync.
        for k, _ in pairs(mem_features) do
          if fresh_features[k] == nil and type(k) == "string" and k:sub(1, 1) ~= "_" then
            mem_features[k] = nil
          end
        end
      else
        self.settings:saveSetting("features", fresh_features)
      end
    end
    -- Sync the top-level action-list keys consumed by the register-once file
    -- dialog closures (A9 device round 2026-08-17): those closures bind one
    -- plugin instance forever, so File Browser Items edits/dismissals saved by
    -- the OTHER instance must be pulled from disk here or they wait for restart.
    for _idx, key in ipairs({ "file_browser_actions", "_dismissed_file_browser_actions" }) do
      local disk_v = fresh:readSetting(key)
      if disk_v ~= nil then
        self.settings:saveSetting(key, disk_v)
      else
        self.settings:delSetting(key)
      end
    end
  end

  -- Update configuration with values from settings
  -- Provider and model are stored inside features table
  local features = self.settings:readSetting("features") or {}

  -- Settings UI > configuration.lua > default
  configuration.provider = features.provider or config_file_defaults.provider or "anthropic"
  configuration.model = features.model or config_file_defaults.model

  -- Merge settings into existing features table instead of replacing it.
  -- This preserves runtime-only keys (context flags, book_metadata, etc.)
  -- that callers set before the network callback fires.
  -- Skip runtime-only keys that may have leaked into saved settings.
  local runtime_only_keys = {
    is_general_context = true,
    is_book_context = true,
    is_library_context = true,
    book_metadata = true,
    book_context = true,
    books_info = true,
    selection_data = true,
    compact_view = true,
    dictionary_view = true,
    minimal_buttons = true,
    is_full_page_translate = true,
  }
  if not configuration.features then
    configuration.features = features
  else
    for k, v in pairs(features) do
      if not runtime_only_keys[k] then
        configuration.features[k] = v
      end
    end
    -- Clear settings deleted on disk (nil'd keys). The additive merge above
    -- can't propagate nil values. Clear any non-runtime, non-transient key
    -- in configuration.features that no longer exists in disk settings.
    -- Preserve keys from configuration.lua (config_file_defaults) — those are
    -- intentional overrides that shouldn't be wiped by the settings sync.
    for k, _ in pairs(configuration.features) do
      if not runtime_only_keys[k] and type(k) == "string" and k:sub(1, 1) ~= "_"
          and features[k] == nil and config_file_defaults.features[k] == nil then
        configuration.features[k] = nil
      end
    end
    -- Apply configuration.lua features as defaults for keys not in settings.
    -- Settings UI values take priority; configuration.lua fills in the gaps.
    for k, v in pairs(config_file_defaults.features) do
      if configuration.features[k] == nil then
        configuration.features[k] = v
      end
    end
  end

  -- Ensure transient flags are cleared (these are only set at runtime for specific actions)
  -- This prevents flags from "leaking" to other actions
  configuration.features.compact_view = nil
  configuration.features.dictionary_view = nil
  configuration.features.minimal_buttons = nil
  configuration.features.is_full_page_translate = nil  -- Only set by translateCurrentPage

  -- Push GUI tier placements + global tier pins into the pure override layer
  -- (tier GUI, docs/tier_gui_plan.md). ModelOverrides never reads settings
  -- itself; this runs on every request path in both plugin instances, so
  -- cross-instance staleness is covered by construction. The key checker makes
  -- an unusable pin invisible (resolution falls back to the active provider's
  -- ladder) — GUI-entered keys count via isProviderConfigured.
  do
    local MO = require("koassistant_model_overrides")
    MO.setGuiTiers(features.tier_overrides)
    MO.setGlobalTierPins(features.global_tier_models)
    local self_ref = self
    MO.setKeyChecker(function(provider_id)
      return self_ref:isProviderConfigured(provider_id,
        self_ref.getCustomProvider and self_ref:getCustomProvider(provider_id) or nil)
    end)
  end

  -- Log the current configuration for debugging
  local config_parts = {
    "provider=" .. (configuration.provider or "nil"),
    "model=" .. (configuration.model or "default"),
  }

  -- Always show AI behavior variant
  table.insert(config_parts, "behavior=" .. (features.selected_behavior or "standard"))

  -- Add other relevant settings if they differ from defaults
  if features.default_temperature and features.default_temperature ~= 0.7 then
    table.insert(config_parts, "temp=" .. features.default_temperature)
  end
  -- Show reasoning stance (per-model reasoning system) when not the default.
  local stance = require("reasoning_prefs").getStance(features)
  if stance ~= "default" then
    table.insert(config_parts, "reasoning_stance=" .. stance)
  end
  -- Always show debug level when debug is enabled
  if features.debug then
    table.insert(config_parts, "debug=" .. (features.debug_display_level or "names"))
  end
  if features.enable_streaming == false then
    table.insert(config_parts, "streaming=off")
  end
  if features.render_markdown == false then
    table.insert(config_parts, "markdown=off")
  end

  -- Window size (Display Settings) lives in the shared UI constants so the
  -- viewer, quiz viewer and streaming dialogs all read one truth without
  -- plumbing features through constructors that never carried it. Pushed here
  -- like the tier overrides above, so it survives a restart and reaches the
  -- OTHER plugin instance, which never sees the toggle.
  require("koassistant_ui.constants").setExpandedWindows(
    features.chat_window_size == "expanded")

  -- Console Debug raises KOReader's log level so the plugin's logger.dbg
  -- tracing prints (issue #104). Applied here rather than only in the schema's
  -- on_change so it survives a restart and reaches the OTHER plugin instance,
  -- which never sees the toggle. Level changes only on transition.
  -- Unconditional, not transition-guarded: the sync also picks up KOReader's
  -- own verbose-logging flag, which can flip mid-session without our setting
  -- changing. Costs a require plus an assignment.
  require("koassistant_debug_utils").syncLogLevel(features.debug and true or false)

  -- updateConfigFromSettings() runs on every dialog open and file-dialog
  -- rebuild, so log the summary only when it actually changed (issue #104) —
  -- one line at startup plus one per settings change, which is what makes it
  -- worth having in a user's crash.log at all.
  local config_line = table.concat(config_parts, ", ")
  if config_line ~= self._logged_config_line then
    self._logged_config_line = config_line
    logger.info("KOAssistant config: " .. config_line)
  end
end

-- Helper: Get current provider name
function AskGPT:getCurrentProvider()
  local features = self.settings:readSetting("features") or {}
  return features.provider or self.configuration.provider or "anthropic"
end

-- Helper: Get current model name
function AskGPT:getCurrentModel()
  local features = self.settings:readSetting("features") or {}
  return features.model or self.configuration.model or "claude-sonnet-4-20250514"
end

-- Helper: Get custom models for a provider
function AskGPT:getCustomModels(provider)
  local features = self.settings:readSetting("features") or {}
  local custom_models = features.custom_models or {}
  return custom_models[provider] or {}
end

-- Tier GUI helpers (docs/tier_gui_plan.md): features.tier_overrides[provider][tier]
-- = model_id. GUI layer of tier resolution (beats custom_models.lua placements).
function AskGPT:getTierOverride(provider, tier)
  local features = self.settings:readSetting("features") or {}
  local map = features.tier_overrides and features.tier_overrides[provider]
  local model = type(map) == "table" and map[tier] or nil
  if type(model) == "string" and model ~= "" then return model end
  return nil
end

-- model = nil clears the tier; empty provider tables are pruned so the settings
-- file never accumulates husks.
function AskGPT:setTierOverride(provider, tier, model)
  local features = self.settings:readSetting("features") or {}
  features.tier_overrides = features.tier_overrides or {}
  features.tier_overrides[provider] = features.tier_overrides[provider] or {}
  features.tier_overrides[provider][tier] = model
  if next(features.tier_overrides[provider]) == nil then
    features.tier_overrides[provider] = nil
  end
  if next(features.tier_overrides) == nil then
    features.tier_overrides = nil
  end
  self.settings:saveSetting("features", features)
  self.settings:flush()
  self:updateConfigFromSettings()  -- pushes the new table into ModelOverrides
end

function AskGPT:clearTierOverrides(provider)
  local features = self.settings:readSetting("features") or {}
  if features.tier_overrides then
    features.tier_overrides[provider] = nil
    if next(features.tier_overrides) == nil then
      features.tier_overrides = nil
    end
  end
  self.settings:saveSetting("features", features)
  self.settings:flush()
  self:updateConfigFromSettings()
end

function AskGPT:hasTierOverrides(provider)
  local features = self.settings:readSetting("features") or {}
  local map = features.tier_overrides and features.tier_overrides[provider]
  return type(map) == "table" and next(map) ~= nil
end

-- Global tier pins (tier GUI phase 2): features.global_tier_models[tier] =
-- {provider, model}. nil pin = "Follow active provider" (the per-provider
-- ladder applies).
function AskGPT:getGlobalTierPin(tier)
  local features = self.settings:readSetting("features") or {}
  local p = features.global_tier_models and features.global_tier_models[tier]
  if type(p) == "table" and type(p.provider) == "string" and p.provider ~= ""
      and type(p.model) == "string" and p.model ~= "" then
    return p
  end
  return nil
end

function AskGPT:setGlobalTierPin(tier, pin)
  local features = self.settings:readSetting("features") or {}
  features.global_tier_models = features.global_tier_models or {}
  features.global_tier_models[tier] = pin
  if next(features.global_tier_models) == nil then
    features.global_tier_models = nil
  end
  self.settings:saveSetting("features", features)
  self.settings:flush()
  self:updateConfigFromSettings()  -- pushes the new pins into ModelOverrides
end

-- Helper: Save a custom model for a provider
function AskGPT:saveCustomModel(provider, model)
  local features = self.settings:readSetting("features") or {}
  features.custom_models = features.custom_models or {}
  features.custom_models[provider] = features.custom_models[provider] or {}

  -- Check for duplicates
  for _idx, existing in ipairs(features.custom_models[provider]) do
    if existing == model then
      return false, _("Model already exists")
    end
  end

  -- Check if this is the first model for this provider (especially for custom providers)
  local is_first_model = #features.custom_models[provider] == 0

  table.insert(features.custom_models[provider], model)

  -- If this is the first custom model for a custom provider with no default model,
  -- automatically set it as the user's default
  if is_first_model and self:isCustomProvider(provider) then
    local cp = self:getCustomProvider(provider)
    if cp and (not cp.default_model or cp.default_model == "") then
      features.provider_default_models = features.provider_default_models or {}
      features.provider_default_models[provider] = model
    end
  end

  self.settings:saveSetting("features", features)
  self.settings:flush()
  return true
end

-- Helper: Remove a custom model for a provider
function AskGPT:removeCustomModel(provider, model)
  local features = self.settings:readSetting("features") or {}
  if not features.custom_models or not features.custom_models[provider] then
    return false
  end

  for i, existing in ipairs(features.custom_models[provider]) do
    if existing == model then
      table.remove(features.custom_models[provider], i)
      self.settings:saveSetting("features", features)
      self.settings:flush()

      -- If removed model was selected, reset to effective default
      if self:getCurrentModel() == model then
        features.model = self:getEffectiveDefaultModel(provider)
        -- Baked a default, not a user pick: clear the explicitness flag so future
        -- default bumps can still refresh it (defaults_propagation_plan.md §3).
        if features.model_explicit then features.model_explicit[provider] = nil end
        self.settings:saveSetting("features", features)
        self.settings:flush()
        self:updateConfigFromSettings()
      end
      return true
    end
  end
  return false
end

-- Fetch OpenRouter's per-model metadata (supported_parameters) and record it in the
-- derived capability cache (item 19 auto-derive, docs/model_capability_resolution_plan.md).
-- ~2 KB endpoint; synchronous — only called behind explicit user actions (add custom
-- model / refresh row). Returns true when metadata was fetched and recorded.
-- Ollama server endpoints (GUI): features.ollama_endpoints = { active = <root url|nil>,
-- list = { { url, name? }, ... } }. Absent/nil active = the shipped default
-- (localhost:11434). Stored urls are normalized roots (ConfigHelper.normalizeServerUrl);
-- the /api/chat path is appended at the consumers (mergeWithDefaults + descriptor).
function AskGPT:getOllamaEndpoints()
  local features = self.settings:readSetting("features") or {}
  local eps = features.ollama_endpoints
  if type(eps) ~= "table" then eps = {} end
  if type(eps.list) ~= "table" then eps.list = {} end
  return eps
end

-- The ACTIVE server's root url (no API path).
function AskGPT:ollamaRootUrl()
  local eps = self:getOllamaEndpoints()
  if type(eps.active) == "string" and eps.active ~= "" then return eps.active end
  local Defaults = require("koassistant_api.defaults")
  local base = (Defaults.ProviderDefaults.ollama or {}).base_url or "http://localhost:11434/api/chat"
  return (base:gsub("/api/chat$", ""))
end

-- Cached installed-model list for the ACTIVE server, or nil (never fetched /
-- fetched from a different server). Ollama can only run PULLED models, so this
-- live list is what the model menu renders — never the curated seed array.
function AskGPT:getOllamaCachedModels()
  local features = self.settings:readSetting("features") or {}
  local cache = features.ollama_live_models
  if type(cache) ~= "table" or type(cache.models) ~= "table" then return nil end
  if cache.url ~= self:ollamaRootUrl() then return nil end
  return cache.models
end

-- Context-window policy for ollama requests (features.ollama_num_ctx, read in
-- koassistant_api/ollama.lua). nil (the default) = send no num_ctx, so the
-- server's own Modelfile / OLLAMA_CONTEXT_LENGTH decides: the window is memory
-- on the machine running ollama, and a request num_ctx overrides a Modelfile
-- PARAMETER, so choosing one for the reader would overrule a deliberately tuned
-- server. A NUMBER = fit num_ctx to each request, never above that many tokens.
-- Either way the stream handler reports a prompt that came back truncated.
AskGPT.OLLAMA_CONTEXT_CHOICES = { 131072, 65536, 32768, 16384, 8192 }

function AskGPT:getOllamaContextPref()
  local features = self.settings:readSetting("features") or {}
  local pref = features.ollama_num_ctx
  if type(pref) == "number" then return pref end
  return nil
end

function AskGPT:ollamaContextLabel()
  local pref = self:getOllamaContextPref()
  if pref then return T(_("fit, max %1K"), math.floor(pref / 1024)) end
  return _("server decides")
end

function AskGPT:setOllamaContextPref(value)
  local features = self.settings:readSetting("features") or {}
  features.ollama_num_ctx = value
  self.settings:saveSetting("features", features)
  self.settings:flush()
  self:updateConfigFromSettings()
end

-- Radio submenu for the row above.
function AskGPT:buildOllamaContextMenu()
  local self_ref = self
  local items = {
    {
      text = _("Server decides (default)"),
      help_text = _("Send no context size, so your Modelfile setting or OLLAMA_CONTEXT_LENGTH is in charge. Ollama's own default is 4096 tokens; if a request comes back cut, KOAssistant says so."),
      checked_func = function() return self_ref:getOllamaContextPref() == nil end,
      radio = true,
      callback = function() self_ref:setOllamaContextPref(nil) end,
    },
  }
  for _idx, cap in ipairs(self.OLLAMA_CONTEXT_CHOICES) do
    table.insert(items, {
      text = T(_("Fit to request, max %1K"), math.floor(cap / 1024)),
      help_text = _("KOAssistant asks for a window sized to each request, never larger than this. Ollama reserves the memory for whatever it is given, so on a large model a large window can push it onto the CPU or stop it loading."),
      checked_func = function() return self_ref:getOllamaContextPref() == cap end,
      radio = true,
      callback = function() self_ref:setOllamaContextPref(cap) end,
    })
  end
  return items
end

-- Per-server model memory: remember the last deliberate model pick for each
-- server (keyed by root url, the virtual localhost default included) so
-- switching servers restores the model you actually use there (phone runs a
-- small model, the desktop a big one).
function AskGPT:recordOllamaModelPick(model)
  if type(model) ~= "string" or model == "" then return end
  local features = self.settings:readSetting("features") or {}
  local eps = features.ollama_endpoints
  if type(eps) ~= "table" then eps = {} end
  if type(eps.models) ~= "table" then eps.models = {} end
  eps.models[self:ollamaRootUrl()] = model
  features.ollama_endpoints = eps
  self.settings:saveSetting("features", features)
  self.settings:flush()
end

-- Refresh the cached installed-model list from the active server (/api/tags).
-- Synchronous — only call behind an explicit user action (refresh row, server
-- switch), NEVER from a menu builder (menu-search indexes those).
function AskGPT:refreshOllamaModels(opts)
  local ids, err = self:fetchProviderModels("ollama", opts)
  if not ids then return nil, err end
  local features = self.settings:readSetting("features") or {}
  features.ollama_live_models = { url = self:ollamaRootUrl(), models = ids }
  self.settings:saveSetting("features", features)
  self.settings:flush()
  return ids
end

-- Ollama server manager (key-manager pattern): tap a server to switch to it,
-- hold a saved one to rename/remove. The default localhost row is virtual —
-- never stored, never removable. Switching drops the model-list cache (another
-- server has another set of pulled models) and refetches it right away.
function AskGPT:showOllamaServerManager(on_change)
  local self_ref = self
  local ButtonDialog = require("ui/widget/buttondialog")
  local ConfigHelper = require("koassistant_config_helper")
  local Defaults = require("koassistant_api.defaults")
  local default_root =
    (((Defaults.ProviderDefaults.ollama or {}).base_url or "http://localhost:11434/api/chat")
      :gsub("/api/chat$", ""))
  local eps = self:getOllamaEndpoints()
  local active_root = self:ollamaRootUrl()

  local dialog
  local function rebuild()
    UIManager:close(dialog)
    self_ref:showOllamaServerManager(on_change)
    if on_change then on_change() end
  end

  local function hostLabel(url)
    return (url:gsub("^https?://", ""))
  end

  -- Persist a mutation of the endpoints table. When the active server changed,
  -- drop the old server's model cache and fetch the new server's list.
  local function saveEndpoints(new_eps, switched)
    local f = self_ref.settings:readSetting("features") or {}
    f.ollama_endpoints = new_eps
    if switched then f.ollama_live_models = nil end
    -- Per-server model memory: coming back to a server restores the model last
    -- picked there. Active-provider only — never clobber another provider's pick.
    local restored
    if switched and self_ref:getCurrentProvider() == "ollama" then
      local root = (type(new_eps.active) == "string" and new_eps.active ~= "")
        and new_eps.active or default_root
      local mem = type(new_eps.models) == "table" and new_eps.models[root] or nil
      if type(mem) == "string" and mem ~= "" and mem ~= f.model then
        f.model = mem
        f.model_explicit = f.model_explicit or {}
        f.model_explicit.ollama = true
        restored = mem
      end
    end
    self_ref.settings:saveSetting("features", f)
    self_ref.settings:flush()
    self_ref:updateConfigFromSettings()
    if switched then
      UIManager:show(Notification:new{
        text = restored
          and T(_("Ollama server: %1, model %2"), hostLabel(self_ref:ollamaRootUrl()), restored)
          or T(_("Ollama server: %1"), hostLabel(self_ref:ollamaRootUrl())),
        timeout = 1.5,
      })
      -- Grab the new server's installed list right away; failure is silent
      -- (the model menu shows its "no models listed" hint and the refresh row)
      UIManager:scheduleIn(0.2, function()
        self_ref:refreshOllamaModels({ timeout = 5 })
        if on_change then on_change() end
      end)
    end
  end

  local buttons = {}
  do  -- virtual default row
    local is_active = active_root == default_root
    table.insert(buttons, { {
      text = (is_active and "● " or "○ ") .. T(_("This device (%1)"), hostLabel(default_root)),
      align = "left",
      callback = function()
        UIManager:close(dialog)
        if not is_active then
          local new_eps = self_ref:getOllamaEndpoints()
          new_eps.active = nil
          saveEndpoints(new_eps, true)
        end
        if on_change then on_change() end
      end,
    } })
  end

  for idx, ep in ipairs(eps.list) do
    local idx_copy, ep_copy = idx, ep
    local is_active = ep.url == active_root
    local shown = (type(ep.name) == "string" and ep.name ~= "")
      and (ep.name .. "  " .. hostLabel(ep.url)) or hostLabel(ep.url)
    table.insert(buttons, { {
      text = (is_active and "● " or "○ ") .. shown,
      align = "left",
      callback = function()
        UIManager:close(dialog)
        if not is_active then
          local new_eps = self_ref:getOllamaEndpoints()
          new_eps.active = ep_copy.url
          saveEndpoints(new_eps, true)
        end
        if on_change then on_change() end
      end,
      hold_callback = function()
        local opts_dialog
        opts_dialog = ButtonDialog:new{
          title = shown,
          buttons = {
            { {
              text = _("Rename..."),
              callback = function()
                UIManager:close(opts_dialog)
                local InputDialog = require("ui/widget/inputdialog")
                local rename_dialog
                rename_dialog = InputDialog:new{
                  title = T(_("Name for %1"), hostLabel(ep_copy.url)),
                  input = ep_copy.name or "",
                  input_hint = _("e.g. phone, desktop"),
                  buttons = { {
                    { text = _("Cancel"), id = "close",
                      callback = function() UIManager:close(rename_dialog) end },
                    { text = _("Save"), is_enter_default = true,
                      callback = function()
                        local name = rename_dialog:getInputText()
                        name = name and name:match("^%s*(.-)%s*$") or ""
                        local new_eps = self_ref:getOllamaEndpoints()
                        if new_eps.list[idx_copy] and new_eps.list[idx_copy].url == ep_copy.url then
                          new_eps.list[idx_copy].name = name ~= "" and name or nil
                          saveEndpoints(new_eps, false)
                        end
                        UIManager:close(rename_dialog)
                        rebuild()
                      end },
                  } },
                }
                UIManager:show(rename_dialog)
                rename_dialog:onShowKeyboard()
              end,
            } },
            { {
              text = _("Remove server"),
              callback = function()
                UIManager:close(opts_dialog)
                local new_eps = self_ref:getOllamaEndpoints()
                if new_eps.list[idx_copy] and new_eps.list[idx_copy].url == ep_copy.url then
                  table.remove(new_eps.list, idx_copy)
                  local was_active = new_eps.active == ep_copy.url
                  if was_active then new_eps.active = nil end
                  saveEndpoints(new_eps, was_active)
                end
                rebuild()
              end,
            } },
            { {
              text = _("Cancel"),
              callback = function() UIManager:close(opts_dialog) end,
            } },
          },
        }
        UIManager:show(opts_dialog)
      end,
    } })
  end

  table.insert(buttons, { {
    text = _("Add server..."),
    callback = function()
      UIManager:close(dialog)
      local input_dialog
      input_dialog = MultiInputDialog:new{
        title = _("Add Ollama server"),
        fields = {
          { text = "", hint = _("Address, e.g. 192.168.1.20:11434") },
          { text = "", hint = _("Name (optional), e.g. phone") },
        },
        description = _("Address of a machine running Ollama (it must be serving on the network, not just localhost). The port is usually 11434."),
        buttons = { {
          { text = _("Cancel"), id = "close",
            callback = function() UIManager:close(input_dialog) end },
          { text = _("Add"), is_enter_default = true,
            callback = function()
              local fields = input_dialog:getFields()
              local url = ConfigHelper.normalizeServerUrl(fields[1])
              local name = type(fields[2]) == "string" and fields[2]:match("^%s*(.-)%s*$") or ""
              UIManager:close(input_dialog)
              if not url then
                UIManager:show(InfoMessage:new{ text = _("That does not look like a server address.") })
                return
              end
              local new_eps = self_ref:getOllamaEndpoints()
              local exists = url == default_root
              for _idx, e in ipairs(new_eps.list) do
                if e.url == url then
                  exists = true
                  if name ~= "" then e.name = name end  -- re-add with a name = rename
                  break
                end
              end
              if not exists then
                table.insert(new_eps.list, { url = url, name = name ~= "" and name or nil })
              end
              -- Adding a server means wanting to use it: switch to it too
              new_eps.active = url ~= default_root and url or nil
              saveEndpoints(new_eps, true)
              if on_change then on_change() end
            end },
        } },
      }
      UIManager:show(input_dialog)
      input_dialog:onShowKeyboard()
    end,
  } })

  table.insert(buttons, { {
    text = _("Close"),
    callback = function() UIManager:close(dialog) end,
  } })

  dialog = ButtonDialog:new{
    title = _("Ollama servers\nTap to use. Hold a saved server to rename or remove it."),
    buttons = buttons,
  }
  UIManager:show(dialog)
end

function AskGPT:fetchDerivedModelCaps(provider, model)
  if not model or model == "" then return false end
  -- Ollama: /api/show returns a per-model `capabilities` array (probed 0.17.7:
  -- ["completion","tools",...]) — recorded as a derived params set so
  -- supportsCapability("ollama", <model>, "tools") resolves per LOCAL model
  -- (names are user-specific; curation is impossible). Local + fast, but only
  -- ever called behind explicit user actions (model pick, custom add, refresh).
  if provider == "ollama" then
    local BaseHandler = require("koassistant_api.base")
    local json = require("json")
    local ModelOverrides = require("koassistant_model_overrides")
    local d = self:getProviderDescriptor("ollama")
    local base = d and d.base_url or ""
    local show_url = base:gsub("/api/chat$", "") .. "/api/show"
    local code, body = BaseHandler.fetchInSubprocess(show_url, {
      timeout = 5,
      method = "POST",
      headers = { ["Content-Type"] = "application/json" },
      body = json.encode({ model = model }),
    })
    if tonumber(code) ~= 200 or type(body) ~= "string" or body == "" then return false end
    local ok, decoded = pcall(json.decode, body)
    if not ok or type(decoded) ~= "table" or type(decoded.capabilities) ~= "table" then
      return false
    end
    local params = {}
    for _idx, cap in ipairs(decoded.capabilities) do
      if type(cap) == "string" then params[cap] = true end
    end
    -- No-tools models need no explicit false: derivedParam treats a recorded
    -- entry WITHOUT the param as a definitive no (and the serializer only
    -- persists true values anyway).
    return ModelOverrides.recordDerived(provider, model, params)
  end
  if provider ~= "openrouter" then return false end
  local BaseHandler = require("koassistant_api.base")
  local json = require("json")
  local ModelOverrides = require("koassistant_model_overrides")
  local url = "https://openrouter.ai/api/v1/models/" .. model .. "/endpoints"
  local code, body = BaseHandler.fetchInSubprocess(url, { timeout = 8 })
  if tonumber(code) ~= 200 or type(body) ~= "string" or body == "" then return false end
  local ok, decoded = pcall(json.decode, body)
  -- Type-check every level: luajson decodes JSON null to a truthy function sentinel.
  if not ok or type(decoded) ~= "table" or type(decoded.data) ~= "table"
      or type(decoded.data.endpoints) ~= "table" then
    return false
  end
  -- Union across endpoints: OpenRouter routes a request to an endpoint that supports
  -- the params it carries, so "any endpoint supports it" is the correct semantics.
  local params, seen = {}, false
  for _idx, ep in ipairs(decoded.data.endpoints) do
    if type(ep) == "table" and type(ep.supported_parameters) == "table" then
      seen = true
      for _j, p in ipairs(ep.supported_parameters) do
        if type(p) == "string" then params[p] = true end
      end
    end
  end
  if not seen then return false end
  return ModelOverrides.recordDerived(provider, model, params)
end

-- Resolve a provider descriptor for the universal fetch/test tooling (REVISION 2
-- M2): custom providers AND built-ins (base_url from ProviderDefaults).
function AskGPT:getProviderDescriptor(provider_id)
  local cp = self:getCustomProvider(provider_id)
  if cp then
    return {
      id = provider_id, name = cp.name, base_url = cp.base_url,
      default_model = cp.default_model, is_custom = true,
    }
  end
  local Defaults = require("koassistant_api.defaults")
  local pd = Defaults.ProviderDefaults[provider_id]
  if not pd then return nil end
  local base_url = pd.base_url
  if provider_id == "ollama" then
    -- Active GUI server (model-menu server manager) beats the shipped default,
    -- so the fetch/derive/test tooling talks to the same server as the wire.
    base_url = self:ollamaRootUrl() .. "/api/chat"
  end
  return {
    id = provider_id,
    name = self:getProviderDisplayName(provider_id),
    base_url = base_url,
    default_model = self:getEffectiveDefaultModel(provider_id) or pd.model,
    is_custom = false,
  }
end

function AskGPT:providerSupportsFetch(provider_id)
  if provider_id == "openai_codex" then return false end  -- no models endpoint
  local d = self:getProviderDescriptor(provider_id)
  return d ~= nil and type(d.base_url) == "string" and d.base_url ~= ""
end

-- The micro probe battery speaks the OpenAI chat wire; customs speak it by
-- construction, built-ins qualify by base_url shape (anthropic/gemini/ollama/
-- cohere are excluded — their curated coverage comes from the local pipeline).
function AskGPT:providerSupportsTest(provider_id)
  local d = self:getProviderDescriptor(provider_id)
  if not d then return false end
  if d.is_custom then return true end
  return type(d.base_url) == "string" and d.base_url:find("/chat/completions$") ~= nil
end

-- Fetch the live model list from a provider's list endpoint (18g; universal
-- since REVISION 2 M2). Synchronous like fetchDerivedModelCaps — only called
-- behind an explicit user action. Returns a sorted array of ids, or nil + error.
function AskGPT:fetchProviderModels(provider_id, opts)
  local d = self:getProviderDescriptor(provider_id)
  if not d or not d.base_url or d.base_url == "" then
    return nil, _("Provider has no base URL")
  end
  local BaseHandler = require("koassistant_api.base")
  local json = require("json")
  local key = BaseHandler.getApiKey(provider_id, self.settings)
  if not (type(key) == "string" and key ~= "" and not BaseHandler.isPlaceholderKey(key)) then
    key = nil
  end

  -- Per-wire list endpoint + auth + response field. Default: OpenAI-shaped
  -- ({base}/chat/completions -> {base}/models, Bearer auth, data[].id).
  local models_url, headers, list_field, name_field
  if provider_id == "anthropic" then
    models_url = d.base_url:gsub("/messages$", "/models")
    headers = key and { ["x-api-key"] = key, ["anthropic-version"] = "2023-06-01" } or nil
  elseif provider_id == "ollama" then
    models_url = d.base_url:gsub("/api/chat$", "") .. "/api/tags"
    list_field, name_field = "models", "name"
  elseif provider_id == "gemini" then
    if not key then return nil, _("Gemini needs an API key to list models") end
    local ModelLists = require("koassistant_model_lists")
    models_url = ModelLists._docs.gemini.api_list .. "?key=" .. key
    list_field, name_field = "models", "name"
  else
    models_url = d.base_url:gsub("/+$", ""):gsub("/chat/completions$", "")
    models_url = models_url:gsub("/+$", "") .. "/models"
    headers = key and { ["Authorization"] = "Bearer " .. key } or nil
  end

  local code, body = BaseHandler.fetchInSubprocess(models_url,
    { timeout = (opts and opts.timeout) or 15, headers = headers })
  if not tonumber(code) then
    return nil, T(_("Network error: %1"), tostring(body))
  end
  if tonumber(code) ~= 200 then
    -- never echo the key (gemini rides it in the URL)
    local msg = T(_("HTTP %1 from %2"), tostring(code), models_url:gsub("key=[^&]+", "key=***"))
    local n = tonumber(code)
    if n == 401 or n == 403 then
      msg = msg .. "\n" .. _("This provider needs an API key. Add one in Settings → API Keys & Auth.")
    end
    return nil, msg
  end
  local ok, decoded = pcall(json.decode, body)
  if not ok or type(decoded) ~= "table" then
    return nil, _("Could not parse the model list response")
  end
  -- Type-check every level: luajson decodes JSON null to a truthy function sentinel.
  local rows
  if list_field then
    rows = type(decoded[list_field]) == "table" and decoded[list_field] or {}
  else
    rows = type(decoded.data) == "table" and decoded.data or decoded
  end
  local ids, seen_ids = {}, {}
  for _idx, row in ipairs(rows) do
    local id
    if type(row) == "table" and type(row[name_field or "id"]) == "string" then
      id = row[name_field or "id"]
    elseif type(row) == "string" then
      id = row
    end
    if id then
      id = id:gsub("^models/", "")  -- gemini prefixes ids with "models/"
    end
    if id and id ~= "" and not seen_ids[id] then
      seen_ids[id] = true
      table.insert(ids, id)
    end
  end
  if #ids == 0 then
    return nil, _("No models found in the response")
  end
  table.sort(ids)
  return ids
end

-- Shared entry for the fetch flow (notification -> fetch -> picker/error)
function AskGPT:startFetchModels(provider_id, on_change)
  local self_ref = self
  UIManager:show(Notification:new{
    text = _("Fetching model list..."),
    timeout = 1,
  })
  -- Delayed so the notification paints before the synchronous fetch
  UIManager:scheduleIn(0.2, function()
    local ids, err = self_ref:fetchProviderModels(provider_id)
    if ids then
      self_ref:showFetchedModelsPicker(provider_id, ids, nil, on_change)
    else
      UIManager:show(InfoMessage:new{
        text = T(_("Could not fetch models: %1"), err or _("unknown error")),
      })
    end
  end)
end

-- Tap-to-add picker over a fetched model list (18g). Tapping a model adds it to the
-- provider's custom-models list; the picker re-opens so added rows show a check mark.
-- Big lists are capped at 30 visible rows — the filter narrows them.
-- @param on_change function: optional, fired after each add so the model menu
--        behind the picker refreshes its rows in place
function AskGPT:showFetchedModelsPicker(provider_id, all_ids, filter, on_change)
  local self_ref = self
  local ButtonDialog = require("ui/widget/buttondialog")
  local provider_name = self:getProviderDisplayName(provider_id)

  local needle = filter and filter:lower() or nil
  local ids = {}
  for _idx, id in ipairs(all_ids) do
    if not needle or id:lower():find(needle, 1, true) then
      table.insert(ids, id)
    end
  end

  local added = {}
  for _idx, m in ipairs(self:getCustomModels(provider_id)) do added[m] = true end
  -- Built-in providers: ids already in the curated array count as present too
  for _idx, m in ipairs(require("koassistant_model_lists")[provider_id] or {}) do
    added[m] = true
  end

  local buttons = {}
  table.insert(buttons, {{
    text = filter and T(_("Filter: %1 (tap to change)"), filter) or _("Filter models..."),
    callback = function()
      UIManager:close(self_ref._fetched_models_dialog)
      local InputDialog = require("ui/widget/inputdialog")
      local input_dialog
      input_dialog = InputDialog:new{
        title = _("Filter models"),
        input = filter or "",
        buttons = {{
          {
            text = _("Cancel"),
            id = "close",
            callback = function()
              UIManager:close(input_dialog)
              self_ref:showFetchedModelsPicker(provider_id, all_ids, filter, on_change)
            end,
          },
          {
            text = _("Apply"),
            is_enter_default = true,
            callback = function()
              local new_filter = input_dialog:getInputText()
              UIManager:close(input_dialog)
              if new_filter == "" then new_filter = nil end
              self_ref:showFetchedModelsPicker(provider_id, all_ids, new_filter, on_change)
            end,
          },
        }},
      }
      UIManager:show(input_dialog)
      input_dialog:onShowKeyboard()
    end,
  }})

  -- "Add all" only for short (possibly filtered) lists, so one tap can't flood the picker
  if #ids > 0 and #ids <= 20 then
    table.insert(buttons, {{
      text = T(_("Add all (%1)"), #ids),
      callback = function()
        UIManager:close(self_ref._fetched_models_dialog)
        local added_n = 0
        for _idx, id in ipairs(ids) do
          if self_ref:saveCustomModel(provider_id, id) then added_n = added_n + 1 end
        end
        UIManager:show(Notification:new{
          text = T(_("Added %1 model(s)"), added_n),
          timeout = 1.5,
        })
        if on_change then on_change() end
        self_ref:showFetchedModelsPicker(provider_id, all_ids, filter, on_change)
      end,
    }})
  end

  local shown = 0
  for _idx, id in ipairs(ids) do
    if shown >= 30 then break end
    shown = shown + 1
    local id_copy = id
    if added[id_copy] then
      table.insert(buttons, {{
        text = "✓ " .. id_copy,
        enabled = false,
        callback = function() end,
      }})
    else
      table.insert(buttons, {{
        text = id_copy,
        callback = function()
          UIManager:close(self_ref._fetched_models_dialog)
          local success, err = self_ref:saveCustomModel(provider_id, id_copy)
          UIManager:show(Notification:new{
            text = success and T(_("Added: %1"), id_copy) or (err or _("Failed to add model")),
            timeout = 1.5,
          })
          if success and on_change then on_change() end
          self_ref:showFetchedModelsPicker(provider_id, all_ids, filter, on_change)
        end,
      }})
    end
  end

  table.insert(buttons, {{
    text = _("Close"),
    callback = function()
      UIManager:close(self_ref._fetched_models_dialog)
    end,
  }})

  local title = T(_("%1: %2 model(s)"), provider_name, #ids)
  if #ids > 30 then
    title = title .. "\n" .. _("Showing the first 30 - use the filter to narrow")
  end
  self._fetched_models_dialog = ButtonDialog:new{
    title = title,
    buttons = buttons,
  }
  UIManager:show(self._fetched_models_dialog)
end

-- 19e: micro probe battery — universal since REVISION 2 M2 (any provider whose
-- wire is OpenAI chat-shaped; see providerSupportsTest). Five cheap requests
-- (~16 output tokens each) against the provider's own chat endpoint; positive
-- findings land in the DERIVED capability layer (user override > curated >
-- derived) via ModelOverrides.recordDerived — never in custom_models.lua.
function AskGPT:testProvider(provider_id)
  local self_ref = self
  local provider = self:getProviderDescriptor(provider_id)
  if not provider then return end
  if not self:providerSupportsTest(provider_id) then
    UIManager:show(InfoMessage:new{
      text = _("This provider's wire format isn't covered by the built-in test."),
    })
    return
  end
  local model = provider.default_model
  if not model or model == "" then
    model = self:getCustomModels(provider_id)[1]
  end
  if not model or model == "" then
    UIManager:show(InfoMessage:new{
      text = _("Add a model first (Fetch models from provider, or add one manually), then test."),
    })
    return
  end

  local BaseHandler = require("koassistant_api.base")
  local json = require("json")
  local url = provider.base_url
  local auth
  local key = BaseHandler.getApiKey(provider_id, self.settings)
  if type(key) == "string" and key ~= "" and not BaseHandler.isPlaceholderKey(key) then
    auth = "Bearer " .. key
  end
  -- Pre-flight: don't burn five requests to learn there's no key (custom
  -- providers marked key-not-required are exempt — local servers)
  local cp = self:getCustomProvider(provider_id)
  local needs_key = not (cp and cp.api_key_required == false)
  if needs_key and not auth then
    UIManager:show(InfoMessage:new{
      text = T(_("No API key configured for %1.\n\nAdd one in Settings → API Keys & Auth, then test again."),
        provider.name or provider_id),
    })
    return
  end

  local function post(extra)
    local body = {
      model = model,
      messages = { { role = "user", content = "Reply with only: ok" } },
      max_tokens = 16,
    }
    for k, v in pairs(extra or {}) do body[k] = v end
    local payload = json.encode(body)
    local hdrs = {
      ["Content-Type"] = "application/json",
      ["Content-Length"] = tostring(#payload),
    }
    if auth then hdrs["Authorization"] = auth end
    return BaseHandler.fetchInSubprocess(url, {
      method = "POST", headers = hdrs, body = payload, timeout = 20,
    })
  end

  local probe_tools = { { type = "function",
    ["function"] = { name = "ping", description = "Connectivity test.",
      parameters = { type = "object",
        properties = { ping = { type = "string", description = "Any value." } } } } } }

  local results = {}  -- { {label, ok = true|false|nil(skipped), detail} }
  local caps = {}     -- positive findings for the derived layer

  local steps = {
    { label = _("Reachability"), run = function()
        local code, body = post(nil)
        local n = tonumber(code)
        if n == 200 then return true end
        if n == 401 or n == 403 then
          return false, T(_("auth failed (HTTP %1) - check the API key"), n)
        end
        if not n then return false, T(_("network error: %1"), tostring(body)) end
        -- Surface the server's own explanation when it gives one: NVIDIA
        -- retires models with a 410 whose body names the end-of-life date,
        -- which "check base URL" would hide.
        local detail
        if type(body) == "string" then
          local ok, parsed = pcall(json.decode, body)
          if ok and type(parsed) == "table" then
            local err = parsed.error
            detail = parsed.detail or parsed.message
                or (type(err) == "table" and err.message) or (type(err) == "string" and err)
          end
        end
        if type(detail) == "string" and detail ~= "" then
          return false, T(_("HTTP %1 - %2"), n, detail:sub(1, 200))
        end
        return false, T(_("HTTP %1 - check base URL and model id"), n)
      end },
    { label = _("Streaming (SSE)"), run = function()
        local code, body = post({ stream = true })
        if tonumber(code) ~= 200 then return false, "HTTP " .. tostring(code) end
        if type(body) == "string" and (body:find("^data:") or body:find("\ndata:")
            or body:find("^event:") or body:find("\nevent:")) then
          return true
        end
        return false, _("200 but not SSE - streaming may be unsupported")
      end },
    { label = _("Tool calling"), run = function()
        local code = post({ tools = probe_tools })
        if tonumber(code) == 200 then
          caps.tools = true
          return true
        end
        return false, "HTTP " .. tostring(code)
      end },
    { label = _("Forced tool use (book-tools search)"), run = function()
        if not caps.tools then return nil, _("skipped - tools not accepted") end
        local code = post({ tools = probe_tools, tool_choice = "required" })
        if tonumber(code) == 200 then return true end
        return false, T(_("HTTP %1 - book tools' search phase may not work"), tostring(code))
      end },
    { label = _("Reasoning effort parameter"), run = function()
        local code = post({ reasoning_effort = "low" })
        if tonumber(code) == 200 then
          caps.reasoning = true
          return true, _("accepted (some hosts silently ignore it)")
        end
        return false, "HTTP " .. tostring(code)
      end },
  }

  local step_i = 0
  local function runNext()
    step_i = step_i + 1
    local step = steps[step_i]
    if not step then
      self_ref:showProviderTestReport(provider, model, results, caps)
      return
    end
    UIManager:show(Notification:new{
      text = T(_("Testing %1/%2: %3"), step_i, #steps, step.label),
      timeout = 1,
    })
    -- Delayed so the notification paints before the synchronous request
    UIManager:scheduleIn(0.3, function()
      -- A crashing step must render as a result, never a silent empty report
      local run_ok, ok, detail = pcall(step.run)
      if not run_ok then
        detail = T(_("test error: %1"), tostring(ok))
        ok = false
      end
      table.insert(results, { label = step.label, ok = ok, detail = detail })
      if step_i == 1 and ok == false then
        -- Baseline failed: the rest would just repeat the same error
        self_ref:showProviderTestReport(provider, model, results, caps)
        return
      end
      runNext()
    end)
  end
  runNext()
end

function AskGPT:showProviderTestReport(provider, model, results, caps)
  local self_ref = self
  local ButtonDialog = require("ui/widget/buttondialog")

  local lines = { T(_("Model tested: %1"), model), "" }
  for _idx, r in ipairs(results) do
    local mark = (r.ok == true and "✓") or (r.ok == nil and "-") or "✗"
    local line = mark .. " " .. r.label
    if r.detail then line = line .. "\n   " .. r.detail end
    table.insert(lines, line)
  end
  if #results == 0 then
    table.insert(lines, _("No results — the test could not run. Check the base URL and API key."))
  end

  local buttons = {}
  if caps.tools or caps.reasoning then
    table.insert(buttons, {{
      text = _("Record capabilities for this model"),
      callback = function()
        UIManager:close(self_ref._provider_test_dialog)
        local ModelOverrides = require("koassistant_model_overrides")
        local ok = ModelOverrides.recordDerived(provider.id, model, caps)
        UIManager:show(Notification:new{
          text = ok and T(_("Capabilities recorded for %1"), model)
                     or _("Could not write the capability cache"),
          timeout = 2,
        })
      end,
    }})
  end
  table.insert(buttons, {{
    text = _("Close"),
    callback = function()
      UIManager:close(self_ref._provider_test_dialog)
    end,
  }})

  -- Report rides the TITLE (multi-line titles render everywhere; info_text
  -- support varies across KOReader versions — an unsupported field would show
  -- an empty-looking popup)
  self._provider_test_dialog = ButtonDialog:new{
    title = T(_("Test results: %1"), provider.name or provider.id)
      .. "\n\n" .. table.concat(lines, "\n"),
    title_align = "left",
    buttons = buttons,
  }
  UIManager:show(self._provider_test_dialog)
end

-- Helper: Check if a model is a custom model for the current provider
function AskGPT:isCustomModel(provider, model)
  local custom_models = self:getCustomModels(provider)
  for _idx, custom in ipairs(custom_models) do
    if custom == model then
      return true
    end
  end
  return false
end

-------------------------------------------------------------------------------
-- CUSTOM PROVIDER HELPERS
-------------------------------------------------------------------------------

-- Helper: Get all custom providers
function AskGPT:getCustomProviders()
  local features = self.settings:readSetting("features") or {}
  return features.custom_providers or {}
end

-- Helper: Get a custom provider by ID
function AskGPT:getCustomProvider(provider_id)
  local custom_providers = self:getCustomProviders()
  for _idx, cp in ipairs(custom_providers) do
    if cp.id == provider_id then
      return cp
    end
  end
  return nil
end

-- Helper: Check if a provider ID is a custom provider
function AskGPT:isCustomProvider(provider_id)
  return self:getCustomProvider(provider_id) ~= nil
end

-- Helper: Get display name for a provider (custom or built-in)
function AskGPT:getProviderDisplayName(provider_id)
  -- Check if it's a custom provider
  local custom = self:getCustomProvider(provider_id)
  if custom then
    return custom.name
  end
  if provider_id == "openai_codex" then
    return _("OpenAI Subscription")
  end
  -- Community-set ids whose display casing isn't first-letter-capitalize
  local special = {
    nvidia = "NVIDIA",
    minimax = "MiniMax",
    deepinfra = "DeepInfra",
    novita = "Novita AI",
    nebius = "Nebius AI Studio",
    vercel = "Vercel AI Gateway",
  }
  if special[provider_id] then return special[provider_id] end
  -- Built-in provider: capitalize first letter
  return provider_id:gsub("^%l", string.upper)
end

-- Settings action row (Quick Answer Preset → Model override): opens the shared
-- mode picker from koassistant_dialogs; refreshes the menu row on close.
function AskGPT:showQuickPresetModelMode(touchmenu_instance)
  require("koassistant_dialogs").showQuickPresetModelMode({
    plugin = self,
    on_close = function()
      if touchmenu_instance and touchmenu_instance.updateItems then
        touchmenu_instance:updateItems()
      end
    end,
  })
end

-- Settings action row (Quick Answer Preset → Behavior): same shape as the
-- model-mode row above.
function AskGPT:showQuickPresetBehavior(touchmenu_instance)
  require("koassistant_dialogs").showQuickPresetBehavior({
    plugin = self,
    on_close = function()
      if touchmenu_instance and touchmenu_instance.updateItems then
        touchmenu_instance:updateItems()
      end
    end,
  })
end

-- Settings action row (Quick Answer Preset → Brevity nudge): same shape.
function AskGPT:showQuickPresetNudge(touchmenu_instance)
  require("koassistant_dialogs").showQuickPresetNudge({
    plugin = self,
    on_close = function()
      if touchmenu_instance and touchmenu_instance.updateItems then
        touchmenu_instance:updateItems()
      end
    end,
  })
end

-- Helper: A provider is "configured" when a real API key resolves for it (GUI or
-- apikeys.lua), or when it doesn't need one (ollama; custom providers with
-- api_key_required = false). Mirrors the pre-flight gate in koassistant_gpt_query.
function AskGPT:isProviderConfigured(provider_id, custom_config)
  if provider_id == "ollama" then return true end
  if provider_id == "openai_codex" then
    return require("koassistant_openai_codex_oauth").isConfigured(self.settings)
  end
  local custom = custom_config or self:getCustomProvider(provider_id)
  if custom and custom.api_key_required == false then return true end
  local BaseHandler = require("koassistant_api.base")
  return BaseHandler.getApiKey(provider_id, self.settings) ~= nil
end

-- Helper: true when at least one provider (built-in or custom) has an actual API
-- key. While false (fresh install), key-filtered pickers stay disarmed and show
-- the full list; keyless-but-usable providers like Ollama don't count toward this.
function AskGPT:hasAnyRealApiKey()
  if require("koassistant_openai_codex_oauth").isConfigured(self.settings) then return true end
  local BaseHandler = require("koassistant_api.base")
  local ModelLists = require("koassistant_model_lists")
  for _idx, provider in ipairs(ModelLists.getAllProviders()) do
    if BaseHandler.getApiKey(provider, self.settings) then return true end
  end
  for _idx, cp in ipairs(self:getCustomProviders()) do
    if cp.id and BaseHandler.getApiKey(cp.id, self.settings) then return true end
  end
  return false
end

-- Helper: Generate a unique ID for a custom provider
function AskGPT:generateCustomProviderId(name)
  -- Convert name to lowercase, replace spaces with underscores
  local base_id = "custom_" .. name:lower():gsub("%s+", "_"):gsub("[^a-z0-9_]", "")

  -- Check for uniqueness
  local custom_providers = self:getCustomProviders()
  local id = base_id
  local counter = 1
  while true do
    local exists = false
    for _idx, cp in ipairs(custom_providers) do
      if cp.id == id then
        exists = true
        break
      end
    end
    if not exists then
      break
    end
    counter = counter + 1
    id = base_id .. "_" .. counter
  end

  return id
end

-- Helper: Save a new custom provider
-- @param config table: {name, base_url, default_model, api_key_required}
-- @return boolean, string|nil: success, error message
function AskGPT:saveCustomProvider(config)
  if not config.name or config.name == "" then
    return false, _("Provider name is required")
  end
  if not config.base_url or config.base_url == "" then
    return false, _("Base URL is required")
  end

  local features = self.settings:readSetting("features") or {}
  features.custom_providers = features.custom_providers or {}

  -- Check for duplicate names
  for _idx, existing in ipairs(features.custom_providers) do
    if existing.name:lower() == config.name:lower() then
      return false, _("A provider with this name already exists")
    end
  end

  -- Generate unique ID
  local id = self:generateCustomProviderId(config.name)

  local new_provider = {
    id = id,
    name = config.name,
    base_url = config.base_url,
    default_model = config.default_model or "",
    api_key_required = config.api_key_required ~= false,  -- default true
  }

  table.insert(features.custom_providers, new_provider)
  self.settings:saveSetting("features", features)
  self.settings:flush()
  return true, id
end

-- Helper: Update an existing custom provider
function AskGPT:updateCustomProvider(provider_id, updates)
  local features = self.settings:readSetting("features") or {}
  if not features.custom_providers then
    return false
  end

  for i, cp in ipairs(features.custom_providers) do
    if cp.id == provider_id then
      -- Apply updates
      if updates.name then cp.name = updates.name end
      if updates.base_url then cp.base_url = updates.base_url end
      if updates.default_model ~= nil then cp.default_model = updates.default_model end
      if updates.api_key_required ~= nil then cp.api_key_required = updates.api_key_required end

      features.custom_providers[i] = cp
      self.settings:saveSetting("features", features)
      self.settings:flush()
      return true
    end
  end
  return false
end

-- Helper: Remove a custom provider
function AskGPT:removeCustomProvider(provider_id)
  local features = self.settings:readSetting("features") or {}
  if not features.custom_providers then
    return false
  end

  for i, cp in ipairs(features.custom_providers) do
    if cp.id == provider_id then
      table.remove(features.custom_providers, i)

      -- If removed provider was selected, reset to default (anthropic)
      if features.provider == provider_id then
        features.provider = "anthropic"
        features.model = nil  -- Reset model too
      end

      -- Also remove any custom models for this provider
      if features.custom_models and features.custom_models[provider_id] then
        features.custom_models[provider_id] = nil
      end

      -- Remove API key for this provider
      if features.api_keys and features.api_keys[provider_id] then
        features.api_keys[provider_id] = nil
      end

      self.settings:saveSetting("features", features)
      self.settings:flush()
      self:updateConfigFromSettings()
      return true
    end
  end
  return false
end

-- Helper: Get user's preferred default model for a provider
function AskGPT:getUserDefaultModel(provider)
  local features = self.settings:readSetting("features") or {}
  local provider_defaults = features.provider_default_models or {}
  return provider_defaults[provider]
end

-- Helper: Set user's preferred default model for a provider
function AskGPT:setUserDefaultModel(provider, model)
  local features = self.settings:readSetting("features") or {}
  features.provider_default_models = features.provider_default_models or {}
  features.provider_default_models[provider] = model
  self.settings:saveSetting("features", features)
  self.settings:flush()
end

-- Helper: Clear user's preferred default model for a provider
function AskGPT:clearUserDefaultModel(provider)
  local features = self.settings:readSetting("features") or {}
  if features.provider_default_models then
    features.provider_default_models[provider] = nil
    self.settings:saveSetting("features", features)
    self.settings:flush()
  end
end

-- Helper: Get effective default model (user default or system default)
function AskGPT:getEffectiveDefaultModel(provider)
  -- First check user's preferred default
  local user_default = self:getUserDefaultModel(provider)
  if user_default then
    return user_default
  end

  -- Check if this is a custom provider
  local custom_provider = self:getCustomProvider(provider)
  if custom_provider then
    return custom_provider.default_model or ""
  end

  local Defaults = require("koassistant_api.defaults")
  local provider_defaults = Defaults.ProviderDefaults[provider]

  -- Ollama: the shipped default is just a NAME — a local server can only run
  -- pulled models, so when the live list says the name is not installed,
  -- default to the first installed model instead of a guaranteed 404.
  if provider == "ollama" then
    local cached = self:getOllamaCachedModels()
    if cached and #cached > 0 then
      local shipped = provider_defaults and provider_defaults.model
      for _idx, m in ipairs(cached) do
        if m == shipped then return shipped end
      end
      return cached[1]
    end
  end

  -- Fall back to system default for built-in providers
  if provider_defaults and provider_defaults.model then
    return provider_defaults.model
  end

  return nil
end


-- Helper: Build provider selection sub-menu
-- @param simplified: if true, shows only provider list without management options (for quick settings)
-- Plugin-wide in-place TouchMenu refresh: swap freshly built rows in and
-- repaint. updateItems() alone repaints the OLD item table — TouchMenu only
-- re-runs sub_item_table_func when the submenu is reopened — so any callback
-- that adds/removes/renames rows must come through here for the change to show
-- immediately. Safe no-op without an instance (the same builders also render
-- inside quick-settings ButtonDialogs, which rebuild on every open anyway).
function AskGPT:refreshTouchMenu(touchmenu_instance, rebuild)
  if touchmenu_instance and touchmenu_instance.updateItems and rebuild then
    touchmenu_instance.item_table = rebuild()
    touchmenu_instance:updateItems()
  end
end

function AskGPT:buildProviderMenu(simplified, show_all, hub)
  -- hub = the unified provider/model navigation (maintainer 2026-08-14): each
  -- provider row drills into its model panel (buildModelMenu w/ override)
  -- instead of switching on tap — switching happens by PICKING A MODEL there.
  local self_ref = self
  local current = self:getCurrentProvider()
  local ModelLists = require("koassistant_model_lists")
  local builtin_providers = ModelLists.getAllProviders()
  local custom_providers = self:getCustomProviders()
  local items = {}

  -- In-place refresh hook for mutations triggered from this menu (add/edit/
  -- remove custom providers): nil-tmi (quick settings) degrades to no-op
  local function menuRefresher(touchmenu_instance)
    return function()
      self_ref:refreshTouchMenu(touchmenu_instance, function()
        return self_ref:buildProviderMenu(simplified, show_all, hub)
      end)
    end
  end

  -- Helper to create provider select callback
  local function createProviderCallback(prov_id, display_name)
    return function(touchmenu_instance)
      local features = self_ref.settings:readSetting("features") or {}
      local old_provider = features.provider

      -- Reset model to new provider's effective default when provider changes
      if old_provider ~= prov_id then
        features.model = self_ref:getEffectiveDefaultModel(prov_id)
        -- Baked, not chosen -> the new provider's model is refreshable again.
        if features.model_explicit then features.model_explicit[prov_id] = nil end
      end

      features.provider = prov_id
      self_ref.settings:saveSetting("features", features)
      self_ref.settings:flush()
      self_ref:updateConfigFromSettings()
      -- Show toast confirmation
      UIManager:show(Notification:new{
        text = T(_("Provider: %1"), display_name),
        timeout = 1.5,
      })
      -- Selecting an unconfigured provider offers its setup right here instead
      -- of failing politely at send time (device 2026-08-13). The selection
      -- STANDS either way — Cancel just leaves the key for later. Checked at
      -- tap time (not the build-time no_key marker) so a key added since the
      -- menu was built doesn't re-prompt. Codex has no key — its connect
      -- dialog is the equivalent. menuRefresher(nil) in the QS popup path is
      -- the documented safe no-op (QS rebuilds per open).
      if not self_ref:isProviderConfigured(prov_id) then
        if prov_id == "openai_codex" then
          require("koassistant_openai_codex_oauth").showManageDialog(self_ref)
        else
          self_ref:showApiKeyDialog(prov_id, display_name, false,
            menuRefresher(touchmenu_instance))
        end
      end
    end
  end

  -- Build unified list of all providers for sorting
  local all_providers = {}

  -- Add built-in providers
  for _i, provider in ipairs(builtin_providers) do
    table.insert(all_providers, {
      id = provider,
      display_name = self:getProviderDisplayName(provider),
      is_custom = false,
    })
  end

  -- Add custom providers
  for _i, cp in ipairs(custom_providers) do
    table.insert(all_providers, {
      id = cp.id,
      display_name = cp.name,
      is_custom = true,
      config = cp,
    })
  end

  -- Sort alphabetically by display name (case-insensitive)
  table.sort(all_providers, function(a, b)
    return a.display_name:lower() < b.display_name:lower()
  end)

  -- Key-filtering (controls parity; extended from quick-settings to FULL settings
  -- mode 2026-08-12): once any real API key exists, show only configured providers
  -- (+ the current selection, marked) with a "Show all" escape hatch. Display-only —
  -- stored selections are never touched.
  local hidden_count = 0
  do
    local has_real_key = self:hasAnyRealApiKey()
    for _i, prov in ipairs(all_providers) do
      -- unconfigured drives the select-time key-dialog offer (and its QS
      -- opens_dialog routing below) on EVERY install state; no_key stays the
      -- display/filter marker, meaningful only once some real key exists
      prov.unconfigured = not self:isProviderConfigured(prov.id, prov.config)
      if has_real_key and prov.unconfigured then
        prov.no_key = true
      end
    end
    if has_real_key and not show_all then
      local kept = {}
      for _i, prov in ipairs(all_providers) do
        if not prov.no_key or prov.id == current then
          table.insert(kept, prov)
        else
          hidden_count = hidden_count + 1
        end
      end
      all_providers = kept
    end
  end

  -- Community-set legend up top (only when a marked row can appear below it).
  -- Full settings mode only (maintainer 2026-08-14): the QS popup keeps the *
  -- markers but not the legend row — the main menu is where the set is explained.
  local has_community = false
  if not simplified then
    for _i, prov in ipairs(all_providers) do
      if not prov.is_custom and ModelLists.isCommunity(prov.id) then
        has_community = true
        break
      end
    end
  end
  if has_community then
    -- Tappable legend (maintainer 2026-08-14: the * was explained nowhere
    -- in-plugin) — the disabled see-README row became a real explainer.
    table.insert(items, {
      text = _("* = community set — tap for info"),
      keep_menu_open = true,
      callback = function()
        UIManager:show(InfoMessage:new{
          text = _("Providers marked * are the community set: wired up from documentation and community reports, not maintainer-tested end to end. Their model lists are seed lists — use \"Fetch models from provider…\" inside the provider for the live list, and \"Test provider…\" to verify your key and connection.\n\nUnmarked providers are the curated set."),
        })
      end,
    })
  end

  -- Create menu items from sorted list
  for _i, prov in ipairs(all_providers) do
    local prov_copy = prov  -- Capture for closure
    local text = prov.is_custom and ("★ " .. prov.display_name) or prov.display_name
    -- Community-set marker (REVISION 2 M3): docs-based, not maintainer-tested
    if not prov.is_custom and ModelLists.isCommunity(prov.id) then
      text = text .. " *"
    end
    if prov.no_key then
      text = T(_("%1 (no key)"), text)
    end
    local item = {
      text = text,
      checked_func = function() return self_ref:getCurrentProvider() == prov_copy.id end,
      radio = true,
    }
    if hub then
      -- Round 3 (maintainer 2026-08-14): provider rows are PLAIN submenus —
      -- entering a panel never switches anything (the panel hosts settings:
      -- key, tiers, fetch/test, later capabilities). The models inside are
      -- the radio rows; picking one switches provider+model together and is
      -- the ONLY switch path. The checkmark (checked_func, re-evaluated per
      -- repaint) just marks the active provider. sub_item_table_func stays
      -- side-effect-free, so KOReader's menu-search indexing (which evaluates
      -- every sub_item_table_func) is safe here.
      item.radio = nil
      item.sub_item_table_func = function()
        return self_ref:buildModelMenu(false, prov_copy.id)
      end
    else
      item.callback = createProviderCallback(prov_copy.id, prov_copy.display_name)
      item.keep_menu_open = true
      -- QS path (device 2026-08-13): selecting an unconfigured provider opens
      -- the key dialog, and the QS popup's reopen-after-select buried it —
      -- opens_dialog is the popup's own close-first-don't-reopen contract for
      -- exactly this. Build-time state is fine here: the QS popup rebuilds on
      -- every open. TouchMenu ignores the field.
      item.opens_dialog = prov_copy.unconfigured or nil
    end

    -- Add hold callback for custom providers
    if prov.is_custom then
      item.hold_callback = function(touchmenu_instance)
        self_ref:showCustomProviderOptions(prov_copy.config, menuRefresher(touchmenu_instance))
      end
    end

    table.insert(items, item)
  end

  -- "Show all" escape hatch so the filtered list never hides the existence of
  -- more providers (keys are added in Settings → API Keys & Auth)
  if hidden_count > 0 then
    table.insert(items, {
      text = T(_("Show all providers (%1 more)…"), hidden_count),
      replace_items = function() return self_ref:buildProviderMenu(true, true) end,
      -- TouchMenu path (full settings mode): swap this submenu's list in place.
      -- The QS popup checks replace_items before callback, so it never gets here.
      callback = function(touchmenu_instance)
        self_ref:refreshTouchMenu(touchmenu_instance, function()
          return self_ref:buildProviderMenu(simplified, true, hub)
        end)
      end,
      keep_menu_open = true,
    })
  end

  -- Add management options (only in full mode, not quick settings)
  if not simplified then
    -- Split line on the row above instead of a padded dash row
    -- (maintainer 2026-08-14; covers both the Show-all and all-shown cases)
    if #items > 0 then items[#items].separator = true end

    -- Add local provider preset option
    table.insert(items, {
      text = _("Quick setup: Local provider..."),
      callback = function(touchmenu_instance)
        self_ref:showLocalProviderPresets(menuRefresher(touchmenu_instance))
      end,
      keep_menu_open = true, -- dialog stacks on top; menu refreshes in place on save
    })

    -- Add custom provider option
    table.insert(items, {
      text = _("Add custom provider..."),
      callback = function(touchmenu_instance)
        self_ref:showAddCustomProviderDialog(nil, menuRefresher(touchmenu_instance))
      end,
      keep_menu_open = true, -- dialog stacks on top; menu refreshes in place on save
    })

    -- Manage custom providers (only if there are any)
    if #custom_providers > 0 then
      table.insert(items, {
        text = T(_("Manage custom providers (%1)..."), #custom_providers),
        callback = function(touchmenu_instance)
          self_ref:showManageCustomProvidersMenu(menuRefresher(touchmenu_instance))
        end,
        keep_menu_open = true,
      })
    end
  end

  return items
end

-- The unified provider/model hub (maintainer 2026-08-14): ONE settings row —
-- providers listed (key-filtered, active radio-marked), each drilling into its
-- model panel where a model pick switches provider+model in one tap. The
-- legacy two-row shape survives only in the quick-settings popups.
function AskGPT:buildProviderModelHub()
  return self:buildProviderMenu(false, false, true)
end

-- Helper: Show options for a custom provider (on hold)
-- @param on_change function: optional, called after any mutation (edit/toggle/
--        remove) so the menu behind can refresh its rows in place
function AskGPT:showCustomProviderOptions(provider, on_change)
  local self_ref = self
  local ButtonDialog = require("ui/widget/buttondialog")
  local ConfirmBox = require("ui/widget/confirmbox")

  -- Text for API key toggle
  local api_key_text
  if provider.api_key_required ~= false then
    api_key_text = _("API key: Required [tap to toggle]")
  else
    api_key_text = _("API key: Not required [tap to toggle]")
  end

  local buttons = {
    {{
      text = _("Edit provider..."),
      callback = function()
        UIManager:close(self_ref._provider_options_dialog)
        self_ref:showEditCustomProviderDialog(provider, on_change)
      end,
    }},
    {{
      text = _("Fetch models from provider..."),
      callback = function()
        UIManager:close(self_ref._provider_options_dialog)
        self_ref:startFetchModels(provider.id)
      end,
    }},
    {{
      text = _("Test this provider..."),
      callback = function()
        UIManager:close(self_ref._provider_options_dialog)
        self_ref:testProvider(provider.id)
      end,
    }},
    {{
      text = api_key_text,
      callback = function()
        UIManager:close(self_ref._provider_options_dialog)
        local new_required = provider.api_key_required == false
        self_ref:updateCustomProvider(provider.id, {
          api_key_required = new_required,
        })
        local status = new_required and _("required") or _("not required")
        UIManager:show(Notification:new{
          text = T(_("API key: %1"), status),
          timeout = 1.5,
        })
        if on_change then on_change() end
      end,
    }},
    {{
      text = _("Remove provider"),
      callback = function()
        UIManager:close(self_ref._provider_options_dialog)
        UIManager:show(ConfirmBox:new{
          text = T(_("Remove custom provider '%1'?\n\nThis will also remove any custom models and API key for this provider."), provider.name),
          ok_callback = function()
            self_ref:removeCustomProvider(provider.id)
            UIManager:show(Notification:new{
              text = T(_("Removed: %1"), provider.name),
              timeout = 1.5,
            })
            if on_change then on_change() end
          end,
        })
      end,
    }},
    {{
      text = _("Cancel"),
      callback = function()
        UIManager:close(self_ref._provider_options_dialog)
      end,
    }},
  }

  self._provider_options_dialog = ButtonDialog:new{
    title = provider.name,
    buttons = buttons,
  }
  UIManager:show(self._provider_options_dialog)
end

-- Local provider presets for quick setup
-- All use OpenAI-compatible API format, no API key needed
local LOCAL_PROVIDER_PRESETS = {
  { name = "LM Studio",     port = 1234, desc = _("Popular GUI, drag-and-drop models") },
  { name = "llama.cpp",     port = 8080, desc = _("Fast CLI server (llama-server)") },
  { name = "Jan",           port = 1337, desc = _("Desktop app, easy setup") },
  { name = "vLLM",          port = 8000, desc = _("Production-grade serving") },
  { name = "KoboldCpp",     port = 5001, desc = _("Optimized for creative writing") },
  { name = "LocalAI",       port = 8080, desc = _("Drop-in OpenAI replacement") },
}

-- Helper: Show local provider preset selection
function AskGPT:showLocalProviderPresets(on_change)
  local self_ref = self
  local ButtonDialog = require("ui/widget/buttondialog")

  local buttons = {}
  for _idx, preset in ipairs(LOCAL_PROVIDER_PRESETS) do
    table.insert(buttons, {{
      text = T("%1  (%2)", preset.name, T(_("port %1"), preset.port)),
      callback = function()
        UIManager:close(self_ref._local_presets_dialog)
        self_ref:showAddCustomProviderDialog({
          name = preset.name,
          base_url = string.format("http://localhost:%d/v1/chat/completions", preset.port),
          api_key_required = false,
        }, on_change)
      end,
    }})
  end
  table.insert(buttons, {{
    text = _("Cancel"),
    callback = function()
      UIManager:close(self_ref._local_presets_dialog)
    end,
  }})

  self._local_presets_dialog = ButtonDialog:new{
    title = _("Select local provider"),
    info_text = _("Pre-fills name and URL. Change 'localhost' to your server's IP if needed."),
    buttons = buttons,
  }
  UIManager:show(self._local_presets_dialog)
end

-- (The 2026-08-04 hosted provider presets were RETIRED the same day: those hosts
-- are now community-set BUILT-INS — model_management_strategy.md "End-state
-- REVISION 2" M1. Custom providers remain for personal endpoints only.)

-- Helper: Show dialog to add a new custom provider
-- @param preset table: Optional pre-fill values {name, base_url, api_key_required}
-- @param on_change function: optional, called after a successful add
function AskGPT:showAddCustomProviderDialog(preset, on_change)
  local self_ref = self

  local dialog
  dialog = MultiInputDialog:new{
    title = preset and T(_("Add: %1"), preset.name) or _("Add Custom Provider"),
    fields = {
      {
        text = preset and preset.name or "",
        hint = _("Provider name (e.g., LM Studio)"),
      },
      {
        text = preset and preset.base_url or "",
        hint = _("Base URL (e.g., http://localhost:1234/v1/chat/completions)"),
      },
      {
        text = "",
        hint = _("Default model name (optional)"),
      },
    },
    buttons = {
      {
        {
          text = _("Cancel"),
          id = "close",
          callback = function()
            UIManager:close(dialog)
          end,
        },
        {
          text = _("Add"),
          callback = function()
            local fields = dialog:getFields()
            local name = fields[1]
            local base_url = fields[2]
            local default_model = fields[3]

            local api_key_required = true
            if preset and preset.api_key_required ~= nil then api_key_required = preset.api_key_required end

            local success, result = self_ref:saveCustomProvider({
              name = name,
              base_url = base_url,
              default_model = default_model,
              api_key_required = api_key_required,
            })

            if success then
              UIManager:close(dialog)
              UIManager:show(Notification:new{
                text = T(_("Added provider: %1"), name),
                timeout = 1.5,
              })
              if on_change then on_change() end
            else
              UIManager:show(Notification:new{
                text = result,
                timeout = 2,
              })
            end
          end,
        },
      },
    },
  }
  UIManager:show(dialog)
  dialog:onShowKeyboard()
end

-- Helper: Show dialog to edit a custom provider
-- @param on_change function: optional, called after a successful save
function AskGPT:showEditCustomProviderDialog(provider, on_change)
  local self_ref = self

  local dialog
  dialog = MultiInputDialog:new{
    title = T(_("Edit: %1"), provider.name),
    fields = {
      {
        text = provider.name or "",
        hint = _("Provider name"),
      },
      {
        text = provider.base_url or "",
        hint = _("Base URL"),
      },
      {
        text = provider.default_model or "",
        hint = _("Default model name (optional)"),
      },
    },
    buttons = {
      {
        {
          text = _("Cancel"),
          id = "close",
          callback = function()
            UIManager:close(dialog)
          end,
        },
        {
          text = _("Save"),
          callback = function()
            local fields = dialog:getFields()
            local name = fields[1]
            local base_url = fields[2]
            local default_model = fields[3]

            if name == "" then
              UIManager:show(Notification:new{
                text = _("Provider name is required"),
                timeout = 2,
              })
              return
            end

            if base_url == "" then
              UIManager:show(Notification:new{
                text = _("Base URL is required"),
                timeout = 2,
              })
              return
            end

            self_ref:updateCustomProvider(provider.id, {
              name = name,
              base_url = base_url,
              default_model = default_model,
            })

            UIManager:close(dialog)
            UIManager:show(Notification:new{
              text = T(_("Updated: %1"), name),
              timeout = 1.5,
            })
            if on_change then on_change() end
          end,
        },
      },
    },
  }
  UIManager:show(dialog)
  dialog:onShowKeyboard()
end

-- Helper: Show menu to manage custom providers
-- @param on_change function: optional, called after any mutation
function AskGPT:showManageCustomProvidersMenu(on_change)
  local self_ref = self
  local custom_providers = self:getCustomProviders()

  if #custom_providers == 0 then
    UIManager:show(Notification:new{
      text = _("No custom providers to manage"),
      timeout = 1.5,
    })
    return
  end

  local ButtonDialog = require("ui/widget/buttondialog")
  local ConfirmBox = require("ui/widget/confirmbox")
  local buttons = {}

  -- Add each custom provider as an option
  for _idx, cp in ipairs(custom_providers) do
    local cp_copy = cp
    table.insert(buttons, {{
      text = T(_("Edit: %1"), cp_copy.name),
      callback = function()
        UIManager:close(self_ref._manage_providers_dialog)
        self_ref:showEditCustomProviderDialog(cp_copy, on_change)
      end,
    }})
  end

  -- Add remove all option
  table.insert(buttons, {{
    text = "────────────────────",
    enabled = false,
  }})

  table.insert(buttons, {{
    text = T(_("Remove all (%1)"), #custom_providers),
    callback = function()
      UIManager:close(self_ref._manage_providers_dialog)
      UIManager:show(ConfirmBox:new{
        text = T(_("Remove all %1 custom provider(s)?\n\nThis will also remove their custom models and API keys."), #custom_providers),
        ok_callback = function()
          local features = self_ref.settings:readSetting("features") or {}

          -- Reset provider if current is custom
          if self_ref:isCustomProvider(features.provider) then
            features.provider = "anthropic"
            features.model = nil
          end

          -- Clear all custom provider data
          local old_providers = features.custom_providers or {}
          for _idx, cp in ipairs(old_providers) do
            -- Remove custom models for this provider
            if features.custom_models and features.custom_models[cp.id] then
              features.custom_models[cp.id] = nil
            end
            -- Remove API key
            if features.api_keys and features.api_keys[cp.id] then
              features.api_keys[cp.id] = nil
            end
          end

          features.custom_providers = {}
          self_ref.settings:saveSetting("features", features)
          self_ref.settings:flush()
          self_ref:updateConfigFromSettings()

          UIManager:show(Notification:new{
            text = _("All custom providers removed"),
            timeout = 1.5,
          })
          if on_change then on_change() end
        end,
      })
    end,
  }})

  table.insert(buttons, {{
    text = _("Close"),
    callback = function()
      UIManager:close(self_ref._manage_providers_dialog)
    end,
  }})

  self._manage_providers_dialog = ButtonDialog:new{
    title = _("Manage Custom Providers"),
    buttons = buttons,
  }
  UIManager:show(self._manage_providers_dialog)
end

-- Helper: Build model selection sub-menu for current provider
-- @param simplified: if true, shows only model list without management options (for quick settings)
function AskGPT:buildModelMenu(simplified, provider_override)
  local self_ref = self
  -- provider_override = a specific provider's panel inside the provider/model
  -- HUB (any provider, not just the active one); nil = the active provider
  -- (legacy Model menu shape, still used by the quick-settings popups).
  local provider = provider_override or self:getCurrentProvider()
  local is_custom_provider = self:isCustomProvider(provider)
  local custom_provider_config = is_custom_provider and self:getCustomProvider(provider) or nil

  -- Get models: built-in providers have model lists, custom providers only have custom models
  local models = {}
  local ollama_installed = nil  -- set = installed names on the active server (nil = never fetched)
  if provider == "ollama" then
    -- Live list: a local server can only run PULLED models, so the menu renders
    -- the cached /api/tags list — never the curated seed array (that stays
    -- internal for defaults/tiers). NO fetching here: menu-search indexes
    -- sub_item_table_funcs, so the cache refreshes only behind explicit actions
    -- (the refresh row, server switches).
    models = self:getOllamaCachedModels() or {}
    if #models > 0 then
      ollama_installed = {}
      for _idx, m in ipairs(models) do ollama_installed[m] = true end
    end
  elseif not is_custom_provider then
    models = ModelLists[provider] or {}
  end

  -- Get defaults
  local Defaults = require("koassistant_api.defaults")
  local provider_defaults = Defaults.ProviderDefaults[provider]
  local system_default = nil
  if is_custom_provider and custom_provider_config then
    system_default = custom_provider_config.default_model
  elseif provider_defaults then
    system_default = provider_defaults.model
  end

  local user_default = self:getUserDefaultModel(provider)
  local effective_default = user_default or system_default or ""
  local custom_models = self:getCustomModels(provider)
  local items = {}

  -- Get display name for provider (used in messages)
  local provider_display_name
  if is_custom_provider and custom_provider_config then
    provider_display_name = custom_provider_config.name
  else
    provider_display_name = provider:gsub("^%l", string.upper)
  end

  -- In-place refresh hook for mutations triggered from this menu (add/remove
  -- custom models, default changes — the "(default)" suffixes live in row text)
  local function menuRefresher(touchmenu_instance)
    return function()
      self_ref:refreshTouchMenu(touchmenu_instance, function()
        return self_ref:buildModelMenu(simplified, provider_override)
      end)
    end
  end

  -- Helper to create hold callback for model items
  local function createHoldCallback(model, is_custom)
    return function(touchmenu_instance)
      local refresh = menuRefresher(touchmenu_instance)
      local ButtonDialog = require("ui/widget/buttondialog")
      local current_user_default = self_ref:getUserDefaultModel(provider)
      local buttons = {}

      -- Option to set as default (if not already user default)
      if model ~= current_user_default then
        table.insert(buttons, {{
          text = T(_("Set as default for %1"), provider_display_name),
          callback = function()
            UIManager:close(self_ref._model_hold_dialog)
            self_ref:setUserDefaultModel(provider, model)
            UIManager:show(Notification:new{
              text = T(_("Default for %1: %2"), provider_display_name, model),
              timeout = 1.5,
            })
            refresh()
          end,
        }})
      end

      -- Option to clear custom default (if this is the user default)
      if current_user_default and model == current_user_default then
        table.insert(buttons, {{
          text = _("Clear custom default"),
          callback = function()
            UIManager:close(self_ref._model_hold_dialog)
            self_ref:clearUserDefaultModel(provider)
            UIManager:show(Notification:new{
              text = T(_("Cleared custom default for %1"), provider_display_name),
              timeout = 1.5,
            })
            refresh()
          end,
        }})
      end

      -- Option to remove custom model
      if is_custom then
        table.insert(buttons, {{
          text = _("Remove custom model"),
          callback = function()
            UIManager:close(self_ref._model_hold_dialog)
            local ConfirmBox = require("ui/widget/confirmbox")
            UIManager:show(ConfirmBox:new{
              text = T(_("Remove custom model '%1'?"), model),
              ok_callback = function()
                self_ref:removeCustomModel(provider, model)
                UIManager:show(Notification:new{
                  text = T(_("Removed: %1"), model),
                  timeout = 1.5,
                })
                refresh()
              end,
            })
          end,
        }})
      end

      -- Cancel button
      table.insert(buttons, {{
        text = _("Cancel"),
        callback = function()
          UIManager:close(self_ref._model_hold_dialog)
        end,
      }})

      if #buttons > 1 then  -- More than just cancel
        self_ref._model_hold_dialog = ButtonDialog:new{
          buttons = buttons,
        }
        UIManager:show(self_ref._model_hold_dialog)
      end
    end
  end

  -- Reverse tier map for this provider: show at a glance which models the tier
  -- ladder points at ("· fast/ultrafast"). Curated placements only (user
  -- overrides ride custom_models.lua and get their own management UI later).
  local model_tiers = {}
  for _tidx, tier_name in ipairs({ "frontier", "flagship", "standard", "fast", "ultrafast" }) do
    local tier_model = (ModelLists._tiers[tier_name] or {})[provider]
    if tier_model then
      model_tiers[tier_model] = model_tiers[tier_model] or {}
      table.insert(model_tiers[tier_model], tier_name)
    end
  end

  -- Helper to build display name with default indicators
  local function buildDisplayName(model, is_custom)
    local display_name = model
    if is_custom then
      display_name = "★ " .. display_name
    end
    if model_tiers[model] then
      display_name = display_name .. " · " .. table.concat(model_tiers[model], "/")
    end

    -- Ollama: mark rows the active server does not have (custom adds and a
    -- selected model that vanished from /api/tags). Only when a live list
    -- exists — before the first fetch we know nothing.
    if ollama_installed and not ollama_installed[model] then
      display_name = display_name .. " " .. _("(not installed)")
    end

    -- Add default indicators
    local is_system_default = (model == system_default)
    local is_user_default = (model == user_default)

    if is_user_default and user_default == system_default then
      -- User explicitly set system default as their default - just show "(default)"
      display_name = display_name .. " " .. _("(default)")
    elseif is_user_default then
      -- User has a custom default different from system default
      display_name = display_name .. " " .. _("(your default)")
    elseif is_system_default and not user_default then
      -- No user default set, show system default
      display_name = display_name .. " " .. _("(default)")
    elseif is_system_default and user_default then
      -- User has a different default, mark system default
      display_name = display_name .. " " .. _("(system default)")
    end

    return display_name
  end

  -- Add helper text at the top (only in full mode)
  if not simplified then
    table.insert(items, {
      text = _("Hold to manage. ★ = custom"),
      enabled = false,
    })
  end

  -- Build unified list of all models (custom first, then built-in)
  local all_models = {}
  local listed = {}

  -- Add custom models at the top (user-defined, most likely to be used)
  for _idx, model in ipairs(custom_models) do
    table.insert(all_models, {
      name = model,
      is_custom = true,
    })
    listed[model] = true
  end

  -- Add built-in models (preserves order from model lists file). Skip names
  -- already present as custom rows — with Ollama's live list a fetched-and-added
  -- model would otherwise render twice.
  for i = 1, #models do
    if not listed[models[i]] then
      table.insert(all_models, {
        name = models[i],
        is_custom = false,
      })
      listed[models[i]] = true
    end
  end

  if provider == "ollama" then
    -- Keep the SELECTED model visible even when the server no longer lists it
    -- (deleted there, or the list came from another server) — it renders with
    -- the "(not installed)" marker instead of silently vanishing.
    if self:getCurrentProvider() == "ollama" then
      local f = self.settings:readSetting("features") or {}
      local selected = f.model
      if type(selected) == "string" and selected ~= "" and not listed[selected] then
        table.insert(all_models, { name = selected, is_custom = false })
        listed[selected] = true
      end
    end
    if #all_models == 0 then
      table.insert(items, {
        text = _("No installed models listed yet"),
        enabled = false,
      })
      if not simplified then
        -- The refresh row only exists in the full menu; the QS popup points home
        table.insert(items, {
          text = _("Tap 'Refresh installed models' below with the server running."),
          enabled = false,
        })
      end
    end
  end

  -- Create menu items from model list
  for _idx, model_info in ipairs(all_models) do
    local model_copy = model_info.name  -- Capture for closure
    local is_custom = model_info.is_custom

    table.insert(items, {
      text = buildDisplayName(model_copy, is_custom),
      checked_func = function()
        -- Hub panels exist for NON-active providers too: a coincidental
        -- same-named f.model must not render checked there.
        if self_ref:getCurrentProvider() ~= provider then return false end
        local f = self_ref.settings:readSetting("features") or {}
        local selected = f.model or effective_default
        return selected == model_copy
      end,
      radio = true,
      callback = function()
        local switching = self_ref:getCurrentProvider() ~= provider
        local f = self_ref.settings:readSetting("features") or {}
        -- Hub one-tap switch (maintainer 2026-08-14): picking a model under a
        -- non-active provider sets provider + model TOGETHER — the old
        -- switch-provider/back/reopen-models dance collapses into this tap.
        if switching then f.provider = provider end
        f.model = model_copy
        -- Mark this as a DELIBERATE pick so default bumps never overwrite it
        -- (defaults_propagation_plan.md §3 — features.model alone can't tell an
        -- explicit choice from one auto-baked on provider switch).
        f.model_explicit = f.model_explicit or {}
        f.model_explicit[provider] = true
        self_ref.settings:saveSetting("features", f)
        self_ref.settings:flush()
        self_ref:updateConfigFromSettings()
        UIManager:show(Notification:new{
          text = switching
            and T(_("Provider: %1 — Model: %2"), provider_display_name, model_copy)
            or T(_("Model: %1"), model_copy),
          timeout = 1.5,
        })
        -- Ollama: derive this model's capabilities from /api/show (tools gate —
        -- local model names can't be curated). Deferred so the notification
        -- paints first; server-down failure is silent, retried on next pick.
        if provider == "ollama" then
          self_ref:recordOllamaModelPick(model_copy)
          UIManager:scheduleIn(0.2, function()
            self_ref:fetchDerivedModelCaps("ollama", model_copy)
          end)
        end
        -- Same key-setup offer as the provider picker (the selection stands
        -- either way — Cancel just leaves the key for later).
        if switching and not self_ref:isProviderConfigured(provider) then
          if provider == "openai_codex" then
            require("koassistant_openai_codex_oauth").showManageDialog(self_ref)
          else
            self_ref:showApiKeyDialog(provider, provider_display_name, false)
          end
        end
      end,
      hold_callback = createHoldCallback(model_copy, is_custom),
      keep_menu_open = true,
    })
  end

  -- Add management options (only in full mode)
  if not simplified then
    -- Split line on the last model row instead of a padded dash row
    if #items > 0 then items[#items].separator = true end

    -- Ollama: server picker in the API-key row's place (keyless provider; the
    -- server address is its equivalent of "where do requests go")
    if provider == "ollama" then
      table.insert(items, {
        text_func = function()
          local root = self_ref:ollamaRootUrl()
          local label = root:gsub("^https?://", "")
          for _idx, ep in ipairs(self_ref:getOllamaEndpoints().list) do
            if ep.url == root and type(ep.name) == "string" and ep.name ~= "" then
              label = ep.name
              break
            end
          end
          return T(_("Server: %1"), label)
        end,
        keep_menu_open = true,
        callback = function(touchmenu_instance)
          self_ref:showOllamaServerManager(menuRefresher(touchmenu_instance))
        end,
      })
      -- Ollama sizes its context window PER REQUEST and truncates anything
      -- longer without a word, so the plugin sends a fitted num_ctx. The cap
      -- is the VRAM dial for that (and the way out for a tuned local setup).
      table.insert(items, {
        text_func = function()
          return T(_("Context window: %1"), self_ref:ollamaContextLabel())
        end,
        help_text = _("Ollama gives each request a context window and quietly cuts anything longer. By default your server decides how big it is; KOAssistant can instead fit one to each request, up to a limit you set here."),
        keep_menu_open = true,
        sub_item_table_func = function() return self_ref:buildOllamaContextMenu() end,
      })
    end

    -- Per-provider auth, right where you're looking at the provider (round 3;
    -- the top-level API Keys overview stays as the cross-provider view)
    if provider == "openai_codex" then
      table.insert(items, {
        text = _("Connect / manage subscription..."),
        keep_menu_open = true,
        callback = function()
          require("koassistant_openai_codex_oauth").showManageDialog(self_ref)
        end,
      })
    elseif provider ~= "ollama"
        and not (is_custom_provider and custom_provider_config
                 and custom_provider_config.api_key_required == false) then
      table.insert(items, {
        text_func = function()
          local n = #require("koassistant_api.base").listApiKeys(provider, self_ref.settings)
          if n > 1 then
            return T(_("API keys (%1)..."), n)
          end
          return _("API key...")
        end,
        keep_menu_open = true, -- dialog stacks on top
        callback = function(touchmenu_instance)
          if #require("koassistant_api.base").listApiKeys(provider, self_ref.settings) > 0 then
            self_ref:showApiKeyManager(provider, provider_display_name, false,
              menuRefresher(touchmenu_instance))
          else
            self_ref:showApiKeyDialog(provider, provider_display_name, false,
              menuRefresher(touchmenu_instance))
          end
        end,
      })
    end

    -- Custom providers: endpoint/name/etc. editor (also on hold at hub level)
    if is_custom_provider and custom_provider_config then
      table.insert(items, {
        text = _("Edit provider..."),
        keep_menu_open = true,
        callback = function(touchmenu_instance)
          self_ref:showCustomProviderOptions(custom_provider_config,
            menuRefresher(touchmenu_instance))
        end,
      })
    end

    -- Provider-specific settings (regional endpoints, Z.AI search engine),
    -- MIRRORED from Settings ▸ Advanced ▸ Provider Settings — same features
    -- keys, two doors to one setting (maintainer 2026-08-14; option lists must
    -- stay in sync with the schema rows, cross-noted there). Row labels
    -- refresh via text_func; sub_item_table_func stays side-effect-free
    -- (menu-search evaluates it while indexing).
    local provider_radio_rows = {
      zai = {
        { key = "zai_region", tpl = _("Region: %1"), default = "international",
          options = {
            { value = "international", text = _("International (api.z.ai)") },
            { value = "china", text = _("China (open.bigmodel.cn)") },
          } },
        { key = "zai_search_engine", tpl = _("Search engine: %1"), default = "search_pro_jina",
          options = {
            { value = "search_pro_jina", text = _("Jina (international, default)") },
            { value = "search_pro_bing", text = _("Bing (international)") },
            { value = "search_pro_quark", text = _("Quark (Chinese web)") },
            { value = "search_pro_sogou", text = _("Sogou (Chinese web)") },
            { value = "search_pro", text = _("Pro (Chinese web)") },
            { value = "search_std", text = _("Basic (Chinese web)") },
          } },
      },
      qwen = {
        { key = "qwen_region", tpl = _("Region: %1"), default = "international",
          options = {
            { value = "international", text = _("International (Singapore)") },
            { value = "china", text = _("China (Beijing)") },
            { value = "us", text = _("US (Virginia)") },
          } },
      },
      kimi = {
        { key = "kimi_region", tpl = _("Region: %1"), default = "international",
          options = {
            { value = "international", text = _("International (api.moonshot.ai)") },
            { value = "china", text = _("China (api.moonshot.cn)") },
          } },
      },
    }
    for _idx, spec in ipairs(provider_radio_rows[provider] or {}) do
      local spec_copy = spec
      table.insert(items, {
        text_func = function()
          local f = self_ref.settings:readSetting("features") or {}
          local current = f[spec_copy.key] or spec_copy.default
          local label = current
          for _i, opt in ipairs(spec_copy.options) do
            if opt.value == current then label = opt.text break end
          end
          return T(spec_copy.tpl, label)
        end,
        sub_item_table_func = function()
          local sub = {}
          for _i, opt in ipairs(spec_copy.options) do
            local opt_copy = opt
            table.insert(sub, {
              text = opt_copy.text,
              radio = true,
              checked_func = function()
                local f = self_ref.settings:readSetting("features") or {}
                return (f[spec_copy.key] or spec_copy.default) == opt_copy.value
              end,
              callback = function()
                local f = self_ref.settings:readSetting("features") or {}
                f[spec_copy.key] = opt_copy.value
                self_ref.settings:saveSetting("features", f)
                self_ref.settings:flush()
                self_ref:updateConfigFromSettings()
              end,
              keep_menu_open = true,
            })
          end
          return sub
        end,
      })
    end

    -- Add custom model input option (now saves to list)
    table.insert(items, {
      text = _("Add custom model..."),
      keep_menu_open = true, -- dialog stacks on top; menu refreshes in place on add
      callback = function(touchmenu_instance)
        local refresh = menuRefresher(touchmenu_instance)
        do
          local InputDialog = require("ui/widget/inputdialog")
          local input_dialog
          input_dialog = InputDialog:new{
            title = _("Add Custom Model"),
            input = "",
            input_hint = _("e.g., claude-3-opus-20240229"),
            description = _("Enter the exact model identifier. It will be saved and selected."),
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
                  text = _("Add"),
                  is_enter_default = true,
                  callback = function()
                    local new_model = input_dialog:getInputText()
                    if new_model and new_model ~= "" then
                      local success, err = self_ref:saveCustomModel(provider, new_model)
                      if success then
                        -- Select the new model (a hand-added model is by definition a
                        -- deliberate pick — never auto-refresh away from it)
                        local f = self_ref.settings:readSetting("features") or {}
                        f.model = new_model
                        f.model_explicit = f.model_explicit or {}
                        f.model_explicit[provider] = true
                        self_ref.settings:saveSetting("features", f)
                        self_ref.settings:flush()
                        self_ref:updateConfigFromSettings()
                        UIManager:show(Notification:new{
                          text = T(_("Added: %1"), new_model),
                          timeout = 1.5,
                        })
                        refresh()
                        -- OpenRouter: derive capabilities (tools/reasoning) from the
                        -- provider's per-model metadata so the new model works beyond
                        -- the curated lists. Delayed so the notification paints first;
                        -- offline failure is silent (family fallbacks still apply,
                        -- retry via Manage custom models -> Refresh).
                        if provider == "ollama" then
                          self_ref:recordOllamaModelPick(new_model)
                        end
                        if provider == "openrouter" or provider == "ollama" then
                          UIManager:scheduleIn(0.2, function()
                            if self_ref:fetchDerivedModelCaps(provider, new_model) then
                              UIManager:show(Notification:new{
                                text = _("Model capabilities detected"),
                                timeout = 1.5,
                              })
                            end
                          end)
                        end
                      else
                        UIManager:show(Notification:new{
                          text = err or _("Failed to add model"),
                          timeout = 2,
                        })
                      end
                    end
                    UIManager:close(input_dialog)
                  end,
                },
              },
            },
          }
          UIManager:show(input_dialog)
          input_dialog:onShowKeyboard()
        end
      end,
    })

    -- Add manage custom models option (only if there are custom models)
    if #custom_models > 0 then
      table.insert(items, {
        text = T(_("Manage custom models (%1)..."), #custom_models),
        keep_menu_open = true, -- dialog stacks on top; menu refreshes in place
        callback = function(touchmenu_instance)
          self_ref:showManageCustomModelsMenu(provider, menuRefresher(touchmenu_instance))
        end,
      })
    end

    -- Universal provider tooling (REVISION 2 M2): live model-list fetch and the
    -- micro probe for ANY provider with a fetchable endpoint, built-in or custom.
    -- Ollama: the fetch is a cache REFRESH, not an add-picker — the live list IS
    -- the menu, so there is nothing to hand-pick into it.
    if provider == "ollama" then
      table.insert(items, {
        text = _("Refresh installed models"),
        keep_menu_open = true,
        callback = function(touchmenu_instance)
          local refresh = menuRefresher(touchmenu_instance)
          UIManager:show(Notification:new{ text = _("Checking the server..."), timeout = 1 })
          UIManager:scheduleIn(0.2, function()
            local ids, err = self_ref:refreshOllamaModels()
            if ids then
              UIManager:show(Notification:new{
                text = T(_("%1 installed model(s)"), #ids),
                timeout = 1.5,
              })
              refresh()
            else
              UIManager:show(InfoMessage:new{
                text = T(_("Could not reach the Ollama server: %1"), err or _("unknown error")),
              })
            end
          end)
        end,
      })
    elseif self_ref:providerSupportsFetch(provider) then
      table.insert(items, {
        text = _("Fetch models from provider..."),
        keep_menu_open = true, -- picker stacks on top; menu refreshes as models are added
        callback = function(touchmenu_instance)
          self_ref:startFetchModels(provider, menuRefresher(touchmenu_instance))
        end,
      })
    end
    if self_ref:providerSupportsTest(provider) then
      table.insert(items, {
        text = _("Test provider..."),
        keep_menu_open = true, -- result dialog stacks on top; no list change
        callback = function()
          self_ref:testProvider(provider)
        end,
      })
    end
    -- Tier GUI (docs/tier_gui_plan.md): per-provider speed-ladder editor
    table.insert(items, {
      text = _("Model tiers..."),
      sub_item_table_func = function()
        return self_ref:buildTierMenu(provider)
      end,
    })
  end

  if #items == 0 then  -- No models at all (simplified mode with no models)
    -- No predefined models, add a note
    table.insert(items, 1, {
      text = _("No predefined models"),
      enabled = false,
    })
  end

  return items
end

-- Tier GUI (docs/tier_gui_plan.md): edit this provider's speed ladder. Tiers are
-- RELATIVE — per-action model_tier hints and the ⚡ "fastest" walk resolve
-- through them, always within the current provider. The GUI layer
-- (features.tier_overrides) beats custom_models.lua placements, which beat the
-- curated defaults in koassistant_model_lists.lua.
function AskGPT:buildTierMenu(provider)
  local self_ref = self
  local ModelOverrides = require("koassistant_model_overrides")
  local tiers = { "frontier", "flagship", "standard", "fast", "ultrafast" }
  local tier_labels = {
    frontier = _("Frontier"), flagship = _("Flagship"), standard = _("Standard"),
    fast = _("Fast"), ultrafast = _("Ultrafast"),
  }

  -- The resolution a cleared tier falls back to: custom_models.lua > curated.
  local function defaultFor(tier)
    local tier_map = ModelLists._tiers[tier]
    return ModelOverrides.userTierOverride(provider, tier)
        or (tier_map and tier_map[provider]) or nil
  end

  -- Pick-list source: provider array + user-added models, deduped, plus the
  -- current override even when it's in neither (stays visible and clearable).
  local function candidateModels(override)
    local seen, list = {}, {}
    local function add(m)
      if type(m) == "string" and m ~= "" and not seen[m] then
        seen[m] = true
        list[#list + 1] = m
      end
    end
    if not self_ref:isCustomProvider(provider) then
      for _idx, m in ipairs(ModelLists[provider] or {}) do add(m) end
    end
    for _idx, m in ipairs(self_ref:getCustomModels(provider)) do add(m) end
    add(override)
    return list
  end

  local function buildPickList(tier)
    local pick = {}
    -- Tier description behind a tap (rows truncate, descriptions don't fit)
    local info = ModelLists.getTierInfo(tier)
    if info and info.description then
      pick[#pick + 1] = {
        text = T(_("About: %1"), tier_labels[tier]),
        keep_menu_open = true,
        callback = function()
          UIManager:show(InfoMessage:new{ text = info.description })
        end,
      }
    end
    pick[#pick + 1] = {
      text_func = function()
        local def = defaultFor(tier)
        return def and T(_("Default (%1)"), def) or _("Default (not set)")
      end,
      checked_func = function()
        return self_ref:getTierOverride(provider, tier) == nil
      end,
      callback = function()
        self_ref:setTierOverride(provider, tier, nil)
      end,
    }
    for _idx, m in ipairs(candidateModels(self_ref:getTierOverride(provider, tier))) do
      pick[#pick + 1] = {
        text = m,
        checked_func = function()
          return self_ref:getTierOverride(provider, tier) == m
        end,
        callback = function()
          self_ref:setTierOverride(provider, tier, m)
        end,
      }
    end
    return pick
  end

  -- Menu rows truncate rather than wrap, so the explanation lives behind a tap
  -- (maintainer 2026-08-09: long disabled info rows overflow the row width)
  local items = {
    {
      text = _("About tiers"),
      keep_menu_open = true,
      callback = function()
        UIManager:show(InfoMessage:new{
          text = _("A speed ladder for this provider: actions that declare a speed tier (like Quick Define and Translate) and the Quick Answer preset pick their model from it.\n\nTiers never switch providers — use a per-action provider pin or a global tier pin for that.\n\nFrontier is never chosen automatically."),
        })
      end,
    },
  }
  -- Masking marker (tier GUI phase 2): global pins outrank this ladder for
  -- tier-invoking requests — say so instead of letting the rows look dead.
  do
    local pinned = {}
    for _idx, tier in ipairs(tiers) do
      if self_ref:getGlobalTierPin(tier) then
        pinned[#pinned + 1] = tier_labels[tier]
      end
    end
    if #pinned > 0 then
      local pinned_list = table.concat(pinned, ", ")
      table.insert(items, {
        text = T(_("Global pins: %1"), pinned_list),
        keep_menu_open = true,
        callback = function()
          UIManager:show(InfoMessage:new{
            text = T(_("Global tier pins override this ladder for: %1.\n\nEdit them under Settings → Advanced → Tier Models (Global)."), pinned_list),
          })
        end,
      })
    end
  end
  for _idx, tier in ipairs(tiers) do
    items[#items + 1] = {
      text_func = function()
        local override = self_ref:getTierOverride(provider, tier)
        if override then
          return T(_("%1: %2 (custom)"), tier_labels[tier], override)
        end
        local def = defaultFor(tier)
        if def then
          return T(_("%1: %2"), tier_labels[tier], def)
        end
        return T(_("%1: not set"), tier_labels[tier])
      end,
      sub_item_table_func = function()
        return buildPickList(tier)
      end,
    }
  end
  items[#items + 1] = {
    text = _("Reset all tiers to defaults"),
    keep_menu_open = true,
    enabled_func = function() return self_ref:hasTierOverrides(provider) end,
    callback = function(touchmenu_instance)
      self_ref:clearTierOverrides(provider)
      UIManager:show(Notification:new{
        text = _("Tier customizations cleared"),
        timeout = 1.5,
      })
      self_ref:refreshTouchMenu(touchmenu_instance, function()
        return self_ref:buildTierMenu(provider)
      end)
    end,
  }
  return items
end

-- Global tier pins screen (tier GUI phase 2, docs/tier_gui_plan.md; schema
-- callback "buildGlobalTierMenu"): each slot either follows the active
-- provider's ladder (default) or pins ONE provider+model that any
-- tier-invoking request (action model_tier hints, the ⚡ fastest walk)
-- switches to — for that request only, via the model-override rebase. Normal
-- chats, explicit picks and action pins are never affected. A pin whose
-- provider loses its key silently falls back to the ladder.
function AskGPT:buildGlobalTierMenu()
  local self_ref = self
  local tiers = { "frontier", "flagship", "standard", "fast", "ultrafast" }
  local tier_labels = {
    frontier = _("Frontier"), flagship = _("Flagship"), standard = _("Standard"),
    fast = _("Fast"), ultrafast = _("Ultrafast"),
  }
  local items = {
    {
      text = _("About global pins"),
      keep_menu_open = true,
      callback = function()
        UIManager:show(InfoMessage:new{
          text = _("Each tier either follows the active provider's ladder (default) or pins one provider and model.\n\nA pin applies only when an action or Quick Answer asks for a speed tier, and overrides the selected provider and model for that request only.\n\nIf the pinned provider has no usable API key, the pin is ignored and the active provider's ladder applies."),
        })
      end,
    },
  }
  for _idx, tier in ipairs(tiers) do
    items[#items + 1] = {
      text_func = function()
        local pin = self_ref:getGlobalTierPin(tier)
        if pin then
          return T(_("%1: %2 · %3"), tier_labels[tier], pin.provider, pin.model)
        end
        return T(_("%1: Follow active provider"), tier_labels[tier])
      end,
      keep_menu_open = true,
      callback = function(touchmenu_instance)
        local function refresh()
          self_ref:refreshTouchMenu(touchmenu_instance, function()
            return self_ref:buildGlobalTierMenu()
          end)
        end
        require("koassistant_dialogs").pickProviderModel({
          plugin = self_ref,
          current = self_ref:getGlobalTierPin(tier),
          top_row = {
            text = _("Follow active provider (default)"),
            callback = function()
              self_ref:setGlobalTierPin(tier, nil)
              refresh()
            end,
          },
          on_pick = function(provider_id, model_name)
            self_ref:setGlobalTierPin(tier, { provider = provider_id, model = model_name })
            refresh()
          end,
        })
      end,
    }
  end
  items[#items + 1] = {
    text = _("Clear all pins"),
    keep_menu_open = true,
    enabled_func = function()
      local features = self.settings:readSetting("features") or {}
      return type(features.global_tier_models) == "table"
        and next(features.global_tier_models) ~= nil
    end,
    callback = function(touchmenu_instance)
      local features = self.settings:readSetting("features") or {}
      features.global_tier_models = nil
      self.settings:saveSetting("features", features)
      self.settings:flush()
      self:updateConfigFromSettings()
      UIManager:show(Notification:new{
        text = _("Global tier pins cleared"),
        timeout = 1.5,
      })
      self_ref:refreshTouchMenu(touchmenu_instance, function()
        return self_ref:buildGlobalTierMenu()
      end)
    end,
  }
  return items
end

-- Helper: Show manage custom models menu
-- @param on_change function: optional, called after any mutation
function AskGPT:showManageCustomModelsMenu(provider, on_change)
  local self_ref = self
  local custom_models = self:getCustomModels(provider)

  if #custom_models == 0 then
    UIManager:show(Notification:new{
      text = _("No custom models to manage"),
      timeout = 1.5,
    })
    return
  end

  local ButtonDialog = require("ui/widget/buttondialog")
  local ConfirmBox = require("ui/widget/confirmbox")
  local buttons = {}

  -- Add each custom model as a remove option
  for _idx, model in ipairs(custom_models) do
    local model_copy = model
    table.insert(buttons, {{
      text = T(_("Remove: %1"), model_copy),
      callback = function()
        UIManager:close(self_ref._manage_models_dialog)
        UIManager:show(ConfirmBox:new{
          text = T(_("Remove custom model '%1'?"), model_copy),
          ok_callback = function()
            self_ref:removeCustomModel(provider, model_copy)
            UIManager:show(Notification:new{
              text = T(_("Removed: %1"), model_copy),
              timeout = 1.5,
            })
            if on_change then on_change() end
          end,
        })
      end,
    }})
  end

  -- OpenRouter + Ollama: re-fetch derived capabilities for all custom models
  -- (item 19 auto-derive; ollama = /api/show capabilities) — covers models
  -- added before the feature existed and offline adds.
  if provider == "openrouter" or provider == "ollama" then
    table.insert(buttons, {{
      text = _("Refresh model capabilities"),
      callback = function()
        UIManager:close(self_ref._manage_models_dialog)
        local updated = 0
        for _idx, model in ipairs(custom_models) do
          if self_ref:fetchDerivedModelCaps(provider, model) then
            updated = updated + 1
          end
        end
        UIManager:show(Notification:new{
          text = T(_("Capabilities updated for %1 of %2 model(s)"), updated, #custom_models),
          timeout = 2,
        })
      end,
    }})
  end

  -- Add clear all option
  table.insert(buttons, {{
    text = _("Clear all custom models"),
    callback = function()
      UIManager:close(self_ref._manage_models_dialog)
      UIManager:show(ConfirmBox:new{
        text = T(_("Remove all %1 custom model(s) for %2?"), #custom_models, provider:gsub("^%l", string.upper)),
        ok_callback = function()
          local features = self_ref.settings:readSetting("features") or {}
          local current_model = features.model

          -- Check if current model is a custom one that will be removed
          local was_custom = self_ref:isCustomModel(provider, current_model)

          features.custom_models = features.custom_models or {}
          features.custom_models[provider] = {}

          -- If current model was custom, reset to effective default
          if was_custom then
            features.model = self_ref:getEffectiveDefaultModel(provider)
            if features.model_explicit then features.model_explicit[provider] = nil end
          end

          self_ref.settings:saveSetting("features", features)
          self_ref.settings:flush()
          self_ref:updateConfigFromSettings()

          UIManager:show(Notification:new{
            text = _("All custom models cleared"),
            timeout = 1.5,
          })
          if on_change then on_change() end
        end,
      })
    end,
  }})

  -- Cancel button
  table.insert(buttons, {{
    text = _("Cancel"),
    callback = function()
      UIManager:close(self_ref._manage_models_dialog)
    end,
  }})

  self._manage_models_dialog = ButtonDialog:new{
    title = T(_("Custom Models for %1"), provider:gsub("^%l", string.upper)),
    buttons = buttons,
  }
  UIManager:show(self._manage_models_dialog)
end

-- Helper: Mask API key for display (e.g., "sk-...abc123")
local function maskApiKey(key)
  if not key or key == "" then return "" end
  local len = #key
  if len <= 8 then
    return string.rep("*", len)
  end
  -- Show first 3 and last 4 characters
  return key:sub(1, 3) .. "..." .. key:sub(-4)
end

-- Helper: Check if a key value looks like a placeholder (not a real key)
local function isPlaceholderKey(key)
  if not key or key == "" then return true end
  -- Detect common placeholder patterns from apikeys.lua.sample
  local upper = key:upper()
  if upper:find("YOUR_") or upper:find("_HERE") or upper:find("API_KEY") then
    return true
  end
  -- Real API keys are typically at least 20 characters
  if #key < 20 then
    return true
  end
  return false
end

-- Helper: Check if apikeys.lua has a real (non-placeholder) key for provider
local function hasFileApiKey(provider)
  -- Shape-safe via the shared enumerator (string / array / {key, alias} entries;
  -- placeholders filtered): nil settings = file entries only.
  return #require("koassistant_api.base").listApiKeys(provider, nil) > 0
end

-- Count of usable entries in one provider's GUI key store value (legacy string
-- or the multi-key array shape).
local function guiKeyCount(value)
  if type(value) == "string" then
    return value ~= "" and 1 or 0
  end
  if type(value) == "table" then
    return #value
  end
  return 0
end

-- Helper: Check if user has any API keys configured (GUI or file), excluding a specific provider
local function hasAnyApiKeys(gui_keys, exclude_provider)
  -- Check GUI keys
  for provider, key in pairs(gui_keys or {}) do
    if provider ~= exclude_provider and guiKeyCount(key) > 0 then
      return true
    end
  end
  -- Check apikeys.lua file
  local builtin_providers = ModelLists.getAllProviders()
  for _idx, provider in ipairs(builtin_providers) do
    if provider ~= exclude_provider and hasFileApiKey(provider) then
      return true
    end
  end
  return false
end

-- Helper: Build API Keys management menu
function AskGPT:buildApiKeysMenu()
  local self_ref = self
  local items = {}
  local builtin_providers = ModelLists.getAllProviders()
  local custom_providers = self:getCustomProviders()
  local features = self.settings:readSetting("features") or {}
  local gui_keys = features.api_keys or {}

  -- Build unified list of all providers for sorting
  local all_providers = {}

  -- Add built-in providers
  for _i, provider in ipairs(builtin_providers) do
    local is_subscription = provider == "openai_codex"
    local has_gui_key = not is_subscription and guiKeyCount(gui_keys[provider]) > 0
    local has_file_key = hasFileApiKey(provider)
    local key_count = not is_subscription
      and #require("koassistant_api.base").listApiKeys(provider, self.settings) or 0
    local status = ""
    if is_subscription and require("koassistant_openai_codex_oauth").isConfigured(self.settings) then
      status = " [connected]"
    elseif key_count > 1 then
      status = " [" .. key_count .. " " .. _("keys") .. "]"
    elseif has_gui_key then
      status = " [set]"
    elseif has_file_key then
      status = " (file)"
    end

    table.insert(all_providers, {
      id = provider,
      display_name = self:getProviderDisplayName(provider),
      status = status,
      is_custom = false,
    })
  end

  -- Add custom providers
  for _i, cp in ipairs(custom_providers) do
    local cp_count = guiKeyCount(gui_keys[cp.id])
    local status = ""
    if cp_count > 1 then
      status = " [" .. cp_count .. " " .. _("keys") .. "]"
    elseif cp_count > 0 then
      status = " [set]"
    elseif not cp.api_key_required then
      status = " (not required)"
    end

    table.insert(all_providers, {
      id = cp.id,
      display_name = cp.name,
      status = status,
      is_custom = true,
      api_key_optional = not cp.api_key_required,
    })
  end

  -- Sort alphabetically by display name (case-insensitive)
  table.sort(all_providers, function(a, b)
    return a.display_name:lower() < b.display_name:lower()
  end)

  -- In-place refresh: the [set]/(file)/[connected] markers live in row text,
  -- so saving or clearing a key must rebuild the rows
  local function menuRefresher(touchmenu_instance)
    return function()
      self_ref:refreshTouchMenu(touchmenu_instance, function()
        return self_ref:buildApiKeysMenu()
      end)
    end
  end

  -- Create menu items from sorted list
  for _i, prov in ipairs(all_providers) do
    local prov_copy = prov  -- Capture for closure
    local text = prov.is_custom and ("★ " .. prov.display_name .. prov.status) or (prov.display_name .. prov.status)

    table.insert(items, {
      text = text,
      keep_menu_open = true,
      callback = function(touchmenu_instance)
        if prov_copy.id == "openai_codex" then
          require("koassistant_openai_codex_oauth").showManageDialog(self_ref)
        elseif #require("koassistant_api.base").listApiKeys(prov_copy.id, self_ref.settings) > 0 then
          -- Keys exist: the manager (list / select / add / rename / delete)
          self_ref:showApiKeyManager(prov_copy.id, prov_copy.display_name, prov_copy.api_key_optional,
            menuRefresher(touchmenu_instance))
        else
          self_ref:showApiKeyDialog(prov_copy.id, prov_copy.display_name, prov_copy.api_key_optional,
            menuRefresher(touchmenu_instance))
        end
      end,
    })
  end

  return items
end

-- Show dialog to enter/edit API key for a provider
-- @param provider string: Provider ID
-- @param display_name string: Display name (optional, defaults to capitalized provider)
-- @param key_optional boolean: If true, shows hint that key is optional (for local servers)
-- @param on_change function: optional, called after save/clear (status markers in menu rows)
-- @param append boolean: optional, Save ADDS a key to the GUI list instead of replacing
--        the stored value (the key manager's "Add API key..." row; Clear is hidden —
--        per-key deletion lives in the manager)
function AskGPT:showApiKeyDialog(provider, display_name, key_optional, on_change, append)
  local self_ref = self
  display_name = display_name or provider:gsub("^%l", string.upper)
  local features = self.settings:readSetting("features") or {}
  local gui_keys = features.api_keys or {}
  local current_value = gui_keys[provider]
  local current_key = (not append and type(current_value) == "string") and current_value or ""
  local masked = maskApiKey(current_key)
  local has_file_key = hasFileApiKey(provider)

  -- Build hint text
  local hint_text
  if append then
    hint_text = _("Enter additional API key...")
  elseif masked ~= "" then
    hint_text = T(_("Current: %1"), masked)
  elseif has_file_key then
    hint_text = _("Using key from apikeys.lua")
  elseif key_optional then
    hint_text = _("Optional - leave empty for local servers")
  else
    hint_text = _("Enter API key...")
  end

  local InputDialog = require("ui/widget/inputdialog")
  local input_dialog
  input_dialog = InputDialog:new{
    title = display_name .. " " .. _("API Key"),
    input = "",  -- Start empty, show hint with masked value
    input_hint = hint_text,
    input_type = "text",
    use_available_height = true,
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
          text = _("Clear"),
          enabled = current_key ~= "",
          callback = function()
            local f = self_ref.settings:readSetting("features") or {}
            f.api_keys = f.api_keys or {}
            f.api_keys[provider] = nil
            self_ref.settings:saveSetting("features", f)
            self_ref.settings:flush()
            UIManager:close(input_dialog)
            UIManager:show(InfoMessage:new{
              text = T(_("%1 API key cleared"), display_name),
              timeout = 2,
            })
            if on_change then on_change() end
          end,
        },
        {
          text = _("Save"),
          is_enter_default = true,
          callback = function()
            local raw_key = input_dialog:getInputText() or ""
            -- Strip everything an auth header cannot carry: whitespace ANYWHERE
            -- (not just the ends) plus NBSP / zero-width / BOM. On Kindle the key
            -- is usually copied out of a text file opened in KOReader, and a key
            -- long enough to wrap arrives with the line break inside it.
            local new_key = require("koassistant_api.base").sanitizeKey(raw_key)
            local removed = #(raw_key:gsub("^%s*(.-)%s*$", "%1")) - #new_key
            if new_key and new_key ~= "" then
              local f = self_ref.settings:readSetting("features") or {}
              f.api_keys = f.api_keys or {}
              -- Check if this is the user's first API key (before saving)
              local is_first_key = not hasAnyApiKeys(f.api_keys, provider)
              local stored = f.api_keys[provider]
              if append or type(stored) == "table" then
                -- Multi-key shape: append as a { key } entry, converting a legacy
                -- single string in place. Never replace an existing list — even a
                -- non-append call must not nuke keys the manager owns.
                local list
                if type(stored) == "table" then
                  list = stored
                elseif type(stored) == "string" and stored ~= "" then
                  list = { { key = stored } }
                else
                  list = {}
                end
                table.insert(list, { key = new_key })
                f.api_keys[provider] = list
              else
                f.api_keys[provider] = new_key
              end
              local message = T(_("%1 API key saved"), display_name)
              if removed > 0 then
                -- Never silent: the user typed/pasted something we changed.
                message = T(_("%1 API key saved (%2 stray character(s) removed)"),
                  display_name, removed)
              end
              -- Auto-select provider if this is the first API key
              if is_first_key then
                f.provider = provider
                f.model = nil  -- Reset to new provider's default
                message = T(_("%1 API key saved. %1 selected as provider."), display_name)
              end
              self_ref.settings:saveSetting("features", f)
              self_ref.settings:flush()
              self_ref:updateConfigFromSettings()
              UIManager:close(input_dialog)
              UIManager:show(InfoMessage:new{
                text = message,
                timeout = 2,
              })
              if on_change then on_change() end
            else
              UIManager:close(input_dialog)
            end
          end,
        },
      },
    },
  }
  UIManager:show(input_dialog)
  input_dialog:onShowKeyboard()
end

-- Multi-key manager (2026-08-15): list every configured key for a provider with
-- provenance, pick the active one, add / rename / delete keys added in the app.
-- apikeys.lua entries are listed read-only (edit the file to change them; entries
-- there may carry their own alias: { key = "...", alias = "name" }). The selection
-- is stored as a masked FINGERPRINT (features.api_key_selected[provider]), never
-- the key itself, and resolves inside BaseHandler.getApiKey — the single
-- chokepoint — so chat, provider tests and image generation all follow it. A
-- stale fingerprint (key deleted, file edited) silently falls back to the default
-- GUI-then-file order.
function AskGPT:showApiKeyManager(provider, display_name, key_optional, on_change)
  local self_ref = self
  local Base = require("koassistant_api.base")
  display_name = display_name or provider:gsub("^%l", string.upper)
  local ButtonDialog = require("ui/widget/buttondialog")

  -- Normalize this provider's GUI store to the list shape and run fn(list, idx)
  -- on the entry matching fp; persists and returns true when fn changed it.
  local function mutateGuiEntry(fp, fn)
    local f = self_ref.settings:readSetting("features") or {}
    f.api_keys = f.api_keys or {}
    local stored = f.api_keys[provider]
    local list
    if type(stored) == "string" and stored ~= "" then
      list = { { key = stored } }
    elseif type(stored) == "table" then
      list = stored
    else
      return false
    end
    for idx, entry in ipairs(list) do
      local key = type(entry) == "string" and entry or entry.key
      if type(key) == "string"
          and Base.keyFingerprint(Base.sanitizeKey(key)) == fp then
        -- Normalize the touched entry to table shape so fn can set fields
        if type(entry) == "string" then
          entry = { key = entry }
          list[idx] = entry
        end
        fn(list, idx)
        if #list == 0 then
          f.api_keys[provider] = nil
        else
          f.api_keys[provider] = list
        end
        self_ref.settings:saveSetting("features", f)
        self_ref.settings:flush()
        self_ref:updateConfigFromSettings()
        return true
      end
    end
    return false
  end

  local dialog
  local function rebuild()
    UIManager:close(dialog)
    self_ref:showApiKeyManager(provider, display_name, key_optional, on_change)
    if on_change then on_change() end
  end

  local features = self.settings:readSetting("features") or {}
  local keys = Base.listApiKeys(provider, self.settings)
  local selected_fp = (features.api_key_selected or {})[provider]
  -- The entry getApiKey would actually use: selection match, else the first
  local active_idx = 1
  if selected_fp then
    for i, e in ipairs(keys) do
      if Base.keyFingerprint(e.key) == selected_fp then
        active_idx = i
        break
      end
    end
  end

  local buttons = {}
  for i, entry in ipairs(keys) do
    local fp = Base.keyFingerprint(entry.key)
    local shown = entry.alias and (entry.alias .. "  " .. maskApiKey(entry.key))
      or maskApiKey(entry.key)
    local source_label = entry.source == "gui" and _("added in app") or "apikeys.lua"
    table.insert(buttons, { {
      text = (i == active_idx and "● " or "○ ") .. shown .. "  (" .. source_label .. ")",
      align = "left",
      callback = function()
        local f = self_ref.settings:readSetting("features") or {}
        f.api_key_selected = f.api_key_selected or {}
        f.api_key_selected[provider] = fp
        self_ref.settings:saveSetting("features", f)
        self_ref.settings:flush()
        self_ref:updateConfigFromSettings()
        UIManager:show(Notification:new{
          text = T(_("%1 now uses %2"), display_name, entry.alias or maskApiKey(entry.key)),
          timeout = 2,
        })
        rebuild()
      end,
      hold_callback = function()
        if entry.source ~= "gui" then
          UIManager:show(InfoMessage:new{
            text = _("This key comes from apikeys.lua. Edit that file to change or remove it. A file entry can carry a name too: { key = \"...\", alias = \"paid\" }"),
          })
          return
        end
        local opts
        opts = ButtonDialog:new{
          title = shown,
          buttons = {
            { {
              text = _("Rename..."),
              callback = function()
                UIManager:close(opts)
                local InputDialog = require("ui/widget/inputdialog")
                local rename_dialog
                rename_dialog = InputDialog:new{
                  title = T(_("Name for %1"), maskApiKey(entry.key)),
                  input = entry.alias or "",
                  input_hint = _("e.g. personal, work, paid"),
                  buttons = { {
                    { text = _("Cancel"), id = "close",
                      callback = function() UIManager:close(rename_dialog) end },
                    { text = _("Save"), is_enter_default = true,
                      callback = function()
                        local alias = rename_dialog:getInputText()
                        alias = alias and alias:match("^%s*(.-)%s*$") or ""
                        mutateGuiEntry(fp, function(list, idx)
                          list[idx].alias = alias ~= "" and alias or nil
                        end)
                        UIManager:close(rename_dialog)
                        UIManager:close(dialog)
                        self_ref:showApiKeyManager(provider, display_name, key_optional, on_change)
                        if on_change then on_change() end
                      end },
                  } },
                }
                UIManager:show(rename_dialog)
                rename_dialog:onShowKeyboard()
              end,
            } },
            { {
              text = _("Delete this key"),
              callback = function()
                UIManager:close(opts)
                UIManager:show(require("ui/widget/confirmbox"):new{
                  text = T(_("Delete key %1 for %2?"), shown, display_name),
                  ok_text = _("Delete"),
                  ok_callback = function()
                    mutateGuiEntry(fp, function(list, idx)
                      table.remove(list, idx)
                    end)
                    -- A selection pointing at the deleted key is stale: clear it
                    -- so resolution returns to the default order explicitly.
                    local f = self_ref.settings:readSetting("features") or {}
                    if f.api_key_selected and f.api_key_selected[provider] == fp then
                      f.api_key_selected[provider] = nil
                      self_ref.settings:saveSetting("features", f)
                      self_ref.settings:flush()
                    end
                    rebuild()
                  end,
                })
              end,
            } },
            { { text = _("Cancel"), callback = function() UIManager:close(opts) end } },
          },
        }
        UIManager:show(opts)
      end,
    } })
  end

  table.insert(buttons, { {
    text = _("Add API key..."),
    callback = function()
      UIManager:close(dialog)
      self_ref:showApiKeyDialog(provider, display_name, key_optional, function()
        self_ref:showApiKeyManager(provider, display_name, key_optional, on_change)
        if on_change then on_change() end
      end, true)
    end,
  } })
  table.insert(buttons, { {
    text = _("Close"),
    callback = function() UIManager:close(dialog) end,
  } })

  dialog = ButtonDialog:new{
    title = T(_("%1 API keys (tap to use, hold to manage)"), display_name),
    title_align = "left",
    buttons = buttons,
  }
  UIManager:show(dialog)
end

-- Get the effective primary language (with override support)
-- Supports both new array format (interaction_languages) and old string format (user_languages)
function AskGPT:getEffectivePrimaryLanguage()
  local features = self.settings:readSetting("features") or {}
  local override = features.primary_language

  -- Try new array format first
  local languages = features.interaction_languages
  if not languages or #languages == 0 then
    -- Fall back to old string format for backward compatibility
    local user_languages = features.user_languages or ""
    if user_languages == "" then
      -- Auto-detect from KOReader UI language
      return Languages.detectFromKOReader()
    end
    languages = {}
    for lang in user_languages:gmatch("([^,]+)") do
      local trimmed = lang:match("^%s*(.-)%s*$")
      if trimmed ~= "" then
        table.insert(languages, trimmed)
      end
    end
  end

  if #languages == 0 then
    -- Auto-detect from KOReader UI language
    return Languages.detectFromKOReader()
  end

  -- Check if override is valid (exists in list)
  if override and override ~= "" then
    for _i, lang in ipairs(languages) do
      if lang == override then
        return override
      end
    end
  end

  -- Default to first language
  return languages[1]
end

-- Get display name for a language (native script for regular, English for classical)
-- Wrapper for schema access
function AskGPT:getLanguageDisplay(lang_id)
  return getLanguageDisplay(lang_id)
end

-- Get combined languages list (interaction + additional, deduplicated)
-- Used for translation/dictionary language pickers
function AskGPT:getCombinedLanguages()
  local features = self.settings:readSetting("features") or {}
  local combined = {}
  local seen = {}

  -- Add interaction languages first
  for _i, lang in ipairs(features.interaction_languages or {}) do
    if not seen[lang] then
      table.insert(combined, lang)
      seen[lang] = true
    end
  end

  -- Add additional languages
  for _i, lang in ipairs(features.additional_languages or {}) do
    if not seen[lang] then
      table.insert(combined, lang)
      seen[lang] = true
    end
  end

  -- Fall back to old string format if arrays are empty
  if #combined == 0 then
    local user_languages = features.user_languages or ""
    for lang in user_languages:gmatch("([^,]+)") do
      local trimmed = lang:match("^%s*(.-)%s*$")
      if trimmed ~= "" and not seen[trimmed] then
        table.insert(combined, trimmed)
        seen[trimmed] = true
      end
    end
  end

  return combined
end

-- Helper to show custom language input dialog and add to array
local function showAddCustomLanguageDialog(self_ref, array_key, touchmenu_instance)
    local InputDialog = require("ui/widget/inputdialog")
    local input_dialog
    input_dialog = InputDialog:new{
        title = _("Add Custom Language"),
        input = "",
        input_hint = _("e.g., Esperanto, Swahili"),
        description = _("Enter a language name to add."),
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
                    text = _("Add"),
                    is_enter_default = true,
                    callback = function()
                        local new_lang = input_dialog:getInputText()
                        if new_lang and new_lang ~= "" then
                            new_lang = new_lang:match("^%s*(.-)%s*$")  -- Trim whitespace
                            if new_lang ~= "" then
                                local f = self_ref.settings:readSetting("features") or {}
                                local langs = f[array_key] or {}
                                -- Check if already exists
                                local exists = false
                                for _i, lang in ipairs(langs) do
                                    if lang == new_lang then
                                        exists = true
                                        break
                                    end
                                end
                                if not exists then
                                    table.insert(langs, new_lang)
                                    f[array_key] = langs
                                    -- Also update user_languages for backward compatibility (interaction only)
                                    if array_key == "interaction_languages" then
                                        f.user_languages = table.concat(langs, ", ")
                                    end
                                    self_ref.settings:saveSetting("features", f)
                                    self_ref.settings:flush()
                                    self_ref:updateConfigFromSettings()
                                    UIManager:show(Notification:new{
                                        text = T(_("Added: %1"), new_lang),
                                        timeout = 2,
                                    })
                                    self_ref:refreshTouchMenu(touchmenu_instance, function()
                                        return array_key == "interaction_languages"
                                            and self_ref:buildInteractionLanguagesSubmenu()
                                            or self_ref:buildAdditionalLanguagesSubmenu()
                                    end)
                                else
                                    UIManager:show(Notification:new{
                                        text = T(_("'%1' is already added"), new_lang),
                                        timeout = 2,
                                    })
                                end
                            end
                        end
                        UIManager:close(input_dialog)
                    end,
                },
            },
        },
    }
    UIManager:show(input_dialog)
    input_dialog:onShowKeyboard()
end

-- Build interaction languages submenu (native dropdown with checkmarks)
-- Languages the user speaks/understands - used in system prompt
function AskGPT:buildInteractionLanguagesSubmenu()
    local self_ref = self
    local menu_items = {}

    -- Greyed-out info header
    table.insert(menu_items, {
        text = _("Languages you speak. Guides AI responses."),
        enabled = false,
    })

    -- Add custom language option at top
    table.insert(menu_items, {
        text = _("Add Custom Language..."),
        keep_menu_open = true,
        callback = function(touchmenu_instance)
            showAddCustomLanguageDialog(self_ref, "interaction_languages", touchmenu_instance)
        end,
        separator = true,
    })

    -- Helper to check if language is selected
    local function isSelected(lang_id)
        local f = self_ref.settings:readSetting("features") or {}
        local langs = f.interaction_languages or {}
        for _i, l in ipairs(langs) do
            if l == lang_id then return true end
        end
        return false
    end

    -- Helper to toggle language
    local function toggleLanguage(lang_id)
        local f = self_ref.settings:readSetting("features") or {}
        local langs = f.interaction_languages or {}
        local found = false
        local new_langs = {}
        for _i, l in ipairs(langs) do
            if l == lang_id then
                found = true
                -- Skip to remove
            else
                table.insert(new_langs, l)
            end
        end
        if not found then
            table.insert(new_langs, lang_id)
        end
        f.interaction_languages = new_langs
        -- Update backward compat
        f.user_languages = table.concat(new_langs, ", ")
        -- If the removed language was the primary, reset to first in list
        if found and f.primary_language == lang_id then
            f.primary_language = new_langs[1]  -- nil if list is now empty
        end
        self_ref.settings:saveSetting("features", f)
        self_ref.settings:flush()
        self_ref:updateConfigFromSettings()
    end

    -- English first
    table.insert(menu_items, {
        text = "English",
        checked_func = function() return isSelected("English") end,
        keep_menu_open = true,
        callback = function() toggleLanguage("English") end,
    })

    -- Regular languages alphabetically (excluding English), displayed in native script
    local sorted_regular = {}
    for _i, lang in ipairs(REGULAR_LANGUAGES) do
        if lang.id ~= "English" then
            table.insert(sorted_regular, lang)
        end
    end
    table.sort(sorted_regular, function(a, b) return a.id:lower() < b.id:lower() end)

    for _i, lang in ipairs(sorted_regular) do
        local lang_id = lang.id
        local lang_display = lang.display
        table.insert(menu_items, {
            text = lang_display,
            checked_func = function() return isSelected(lang_id) end,
            keep_menu_open = true,
            callback = function() toggleLanguage(lang_id) end,
        })
    end

    -- Add any custom languages the user has added
    local f = self.settings:readSetting("features") or {}
    local current_langs = f.interaction_languages or {}
    local known_ids = {}
    for _i, lang in ipairs(REGULAR_LANGUAGES) do
        known_ids[lang.id] = true
    end
    for _i, lang in ipairs(CLASSICAL_LANGUAGES) do
        known_ids[lang] = true
    end
    local custom_langs = {}
    for _i, lang in ipairs(current_langs) do
        if not known_ids[lang] then
            table.insert(custom_langs, lang)
        end
    end
    if #custom_langs > 0 then
        table.sort(custom_langs, function(a, b) return a:lower() < b:lower() end)
        for _i, lang in ipairs(custom_langs) do
            local lang_copy = lang
            table.insert(menu_items, {
                text = lang_copy,
                checked_func = function() return isSelected(lang_copy) end,
                keep_menu_open = true,
                callback = function(touchmenu_instance)
                    toggleLanguage(lang_copy)
                    -- Unchecking a custom language removes it entirely: rebuild
                    -- so the row disappears now, not on the next menu open
                    self_ref:refreshTouchMenu(touchmenu_instance, function()
                        return self_ref:buildInteractionLanguagesSubmenu()
                    end)
                end,
            })
        end
    end

    -- Separator before classical languages
    if #menu_items > 0 then
        menu_items[#menu_items].separator = true
    end

    -- Classical languages (displayed in English)
    for _i, lang in ipairs(CLASSICAL_LANGUAGES) do
        local lang_copy = lang
        table.insert(menu_items, {
            text = lang_copy,
            checked_func = function() return isSelected(lang_copy) end,
            keep_menu_open = true,
            callback = function() toggleLanguage(lang_copy) end,
        })
    end

    return menu_items
end

-- Build additional languages submenu (native dropdown with checkmarks)
-- Extra languages for translation/dictionary targets - NOT in system prompt
function AskGPT:buildAdditionalLanguagesSubmenu()
    local self_ref = self
    local menu_items = {}

    -- Greyed-out info header
    table.insert(menu_items, {
        text = _("For translation/dictionary targets only."),
        enabled = false,
    })

    -- Add custom language option at top
    table.insert(menu_items, {
        text = _("Add Custom Language..."),
        keep_menu_open = true,
        callback = function(touchmenu_instance)
            showAddCustomLanguageDialog(self_ref, "additional_languages", touchmenu_instance)
        end,
        separator = true,
    })

    -- Build set of interaction languages to show which are already in "Your Languages"
    local f = self.settings:readSetting("features") or {}
    local interaction_langs = f.interaction_languages or {}
    local interaction_set = {}
    for _i, lang in ipairs(interaction_langs) do
        interaction_set[lang] = true
    end

    -- Helper to check if language is selected
    local function isSelected(lang_id)
        local features = self_ref.settings:readSetting("features") or {}
        local langs = features.additional_languages or {}
        for _i, l in ipairs(langs) do
            if l == lang_id then return true end
        end
        return false
    end

    -- Helper to toggle language
    local function toggleLanguage(lang_id)
        local features = self_ref.settings:readSetting("features") or {}
        local langs = features.additional_languages or {}
        local found = false
        local new_langs = {}
        for _i, l in ipairs(langs) do
            if l == lang_id then
                found = true
                -- Skip to remove
            else
                table.insert(new_langs, l)
            end
        end
        if not found then
            table.insert(new_langs, lang_id)
        end
        features.additional_languages = new_langs
        self_ref.settings:saveSetting("features", features)
        self_ref.settings:flush()
        self_ref:updateConfigFromSettings()
    end

    -- English first (if not in interaction languages)
    if not interaction_set["English"] then
        table.insert(menu_items, {
            text = "English",
            checked_func = function() return isSelected("English") end,
            keep_menu_open = true,
            callback = function() toggleLanguage("English") end,
        })
    end

    -- Regular languages alphabetically (excluding English and those in interaction list)
    local sorted_regular = {}
    for _i, lang in ipairs(REGULAR_LANGUAGES) do
        if lang.id ~= "English" and not interaction_set[lang.id] then
            table.insert(sorted_regular, lang)
        end
    end
    table.sort(sorted_regular, function(a, b) return a.id:lower() < b.id:lower() end)

    for _i, lang in ipairs(sorted_regular) do
        local lang_id = lang.id
        local lang_display = lang.display
        table.insert(menu_items, {
            text = lang_display,
            checked_func = function() return isSelected(lang_id) end,
            keep_menu_open = true,
            callback = function() toggleLanguage(lang_id) end,
        })
    end

    -- Add any custom additional languages the user has added
    local current_langs = f.additional_languages or {}
    local known_ids = {}
    for _i, lang in ipairs(REGULAR_LANGUAGES) do
        known_ids[lang.id] = true
    end
    for _i, lang in ipairs(CLASSICAL_LANGUAGES) do
        known_ids[lang] = true
    end
    local custom_langs = {}
    for _i, lang in ipairs(current_langs) do
        if not known_ids[lang] then
            table.insert(custom_langs, lang)
        end
    end
    if #custom_langs > 0 then
        table.sort(custom_langs, function(a, b) return a:lower() < b:lower() end)
        for _i, lang in ipairs(custom_langs) do
            local lang_copy = lang
            table.insert(menu_items, {
                text = lang_copy,
                checked_func = function() return isSelected(lang_copy) end,
                keep_menu_open = true,
                callback = function(touchmenu_instance)
                    toggleLanguage(lang_copy)
                    -- Unchecking a custom language removes it entirely: rebuild
                    -- so the row disappears now, not on the next menu open
                    self_ref:refreshTouchMenu(touchmenu_instance, function()
                        return self_ref:buildAdditionalLanguagesSubmenu()
                    end)
                end,
            })
        end
    end

    -- Separator before classical languages
    if #menu_items > 0 then
        menu_items[#menu_items].separator = true
    end

    -- Classical languages (displayed in English, excluding those in interaction list)
    for _i, lang in ipairs(CLASSICAL_LANGUAGES) do
        if not interaction_set[lang] then
            local lang_copy = lang
            table.insert(menu_items, {
                text = lang_copy,
                checked_func = function() return isSelected(lang_copy) end,
                keep_menu_open = true,
                callback = function() toggleLanguage(lang_copy) end,
            })
        end
    end

    return menu_items
end

-- Build primary language picker menu
function AskGPT:buildPrimaryLanguageMenu()
  local self_ref = self
  local features = self.settings:readSetting("features") or {}

  -- Use new array format, fall back to old string format
  local languages = features.interaction_languages
  if not languages or #languages == 0 then
    local user_languages = features.user_languages or ""
    if user_languages == "" then
      return {
        {
          text = _("Set your languages first"),
          enabled = false,
        },
      }
    end
    languages = {}
    for lang in user_languages:gmatch("([^,]+)") do
      local trimmed = lang:match("^%s*(.-)%s*$")
      if trimmed ~= "" then
        table.insert(languages, trimmed)
      end
    end
  end

  if #languages == 0 then
    return {
      {
        text = _("Set your languages first"),
        enabled = false,
      },
    }
  end

  local menu_items = {}

  for _i, lang in ipairs(languages) do
    local lang_copy = lang  -- Capture for closure
    local lang_display = getLanguageDisplay(lang)

    table.insert(menu_items, {
      text = lang_display,
      checked_func = function()
        return lang_copy == self_ref:getEffectivePrimaryLanguage()
      end,
      radio = true,
      callback = function()
        local f = self_ref.settings:readSetting("features") or {}
        f.primary_language = lang_copy
        self_ref.settings:saveSetting("features", f)
        self_ref.settings:flush()
        -- Show toast confirmation
        UIManager:show(Notification:new{
          text = T(_("Primary: %1"), getLanguageDisplay(lang_copy)),
          timeout = 1.5,
        })
      end,
      keep_menu_open = true,
    })
  end

  return menu_items
end

-- Build translation language picker menu
function AskGPT:buildTranslationLanguageMenu()
  local self_ref = self
  local effective_primary = self:getEffectivePrimaryLanguage() or "English"

  local menu_items = {}

  -- Add "Use Primary" option at top
  table.insert(menu_items, {
    text = T(_("Follow Primary (%1)"), getLanguageDisplay(effective_primary)),
    checked_func = function()
      local f = self_ref.settings:readSetting("features") or {}
      -- Primary is selected when: toggle is on, OR translation_language is sentinel/nil
      -- Prioritize the toggle as the source of truth
      if f.translation_use_primary == true then
        return true
      end
      if f.translation_use_primary == false then
        return false
      end
      -- If toggle never set (nil), check translation_language
      local trans = f.translation_language
      return trans == nil or trans == "" or trans == "__PRIMARY__"
    end,
    radio = true,
    callback = function()
      local f = self_ref.settings:readSetting("features") or {}
      -- Sync BOTH mechanisms
      f.translation_use_primary = true
      f.translation_language = "__PRIMARY__"
      self_ref.settings:saveSetting("features", f)
      self_ref.settings:flush()
      -- Show toast confirmation
      local prim = self_ref:getEffectivePrimaryLanguage() or "English"
      UIManager:show(Notification:new{
        text = T(_("Translate: %1"), getLanguageDisplay(prim)),
        timeout = 1.5,
      })
    end,
  })

  -- Get combined languages (interaction + additional)
  local languages = self:getCombinedLanguages()

  -- Add each language as an option
  for _i, lang in ipairs(languages) do
    local lang_copy = lang  -- Capture for closure
    table.insert(menu_items, {
      text = getLanguageDisplay(lang),
      checked_func = function()
        local f = self_ref.settings:readSetting("features") or {}
        -- Only checked if toggle is OFF and this language is selected
        if f.translation_use_primary == true then
          return false
        end
        return f.translation_language == lang_copy
      end,
      radio = true,
      callback = function()
        local f = self_ref.settings:readSetting("features") or {}
        -- Sync BOTH mechanisms
        f.translation_use_primary = false
        f.translation_language = lang_copy
        self_ref.settings:saveSetting("features", f)
        self_ref.settings:flush()
        -- Show toast confirmation
        UIManager:show(Notification:new{
          text = T(_("Translate: %1"), getLanguageDisplay(lang_copy)),
          timeout = 1.5,
        })
      end,
    })
  end

  -- Add separator before Custom
  if #menu_items > 0 then
    menu_items[#menu_items].separator = true
  end

  -- Add "Custom..." option for entering any language
  table.insert(menu_items, {
    text = _("Custom..."),
    opens_dialog = true, -- quick settings: close the popup, don't reopen over the input dialog
    callback = function()
      local InputDialog = require("ui/widget/inputdialog")
      local f = self_ref.settings:readSetting("features") or {}
      -- Never prefill the __PRIMARY__ sentinel — it's an internal value
      local current = f.translation_language
      if current == "__PRIMARY__" then current = nil end
      local input_dialog
      input_dialog = InputDialog:new{
        title = _("Custom Translation Language"),
        input = current or "",
        input_hint = _("e.g., Spanish, Japanese, French"),
        description = _("Enter the target language for translations."),
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
                local new_lang = input_dialog:getInputText()
                if new_lang and new_lang ~= "" then
                  -- Sync BOTH mechanisms, like the fixed-language rows: with
                  -- translation_use_primary left true the custom language
                  -- would be silently ignored
                  f.translation_use_primary = false
                  f.translation_language = new_lang
                  self_ref.settings:saveSetting("features", f)
                  self_ref.settings:flush()
                  UIManager:show(Notification:new{
                    text = T(_("Translate: %1"), getLanguageDisplay(new_lang)),
                    timeout = 1.5,
                  })
                end
                UIManager:close(input_dialog)
              end,
            },
          },
        },
      }
      UIManager:show(input_dialog)
      input_dialog:onShowKeyboard()
    end,
  })

  -- If no languages set, show a helpful message
  if #languages == 0 then
    table.insert(menu_items, 1, {
      text = _("(Set your languages for quick selection)"),
      enabled = false,
    })
  end

  return menu_items
end

-- Minimal Popup action registry picker (Minimal Popup settings): multi-select
-- over highlight actions. Membership in features.minimal_popup_actions (nil =
-- Constants.DEFAULT_MINIMAL_POPUP_ACTIONS read-through); dispatch gate in
-- koassistant_dialogs.lua createTempConfig. Highlight-only actions listed, to
-- match the dispatch gate (prompt.context == "highlight"); local_handler
-- pseudo actions (xray_lookup, image_gen) excluded — they never enter the
-- chat pipeline, so a minimal-popup registration would be meaningless.
function AskGPT:buildMinimalPopupActionsMenu()
  local self_ref = self
  local menu_items = {}
  local actions = self.action_service
    and self.action_service:getAllActions("highlight", true, true) or {}
  for _idx, action in ipairs(actions) do
    if (action.original_context or action.context) == "highlight" and action.id
        and not action.local_handler then
      local action_id = action.id
      table.insert(menu_items, {
        text = action.text or action_id,
        checked_func = function()
          local f = self_ref.settings:readSetting("features") or {}
          return Constants.resolveMinimalPopupActions(f.minimal_popup_actions)[action_id] == true
        end,
        keep_menu_open = true,
        callback = function()
          self_ref:_toggleMinimalPopupAction(action_id)
        end,
      })
    end
  end
  return menu_items
end

-- Toggle one action's minimal-popup registration. Shared by the Settings
-- screen picker above and the QS tile's hold popup below — one persistence
-- truth for both surfaces.
function AskGPT:_toggleMinimalPopupAction(action_id)
  local f = self.settings:readSetting("features") or {}
  local set = Constants.resolveMinimalPopupActions(f.minimal_popup_actions)
  if set[action_id] then
    set[action_id] = nil
  else
    set[action_id] = true
  end
  -- Persist as a stable sorted array: consumers do set lookups, so order
  -- is free — sorting keeps the settings file diff-friendly.
  local list = {}
  for id in pairs(set) do list[#list + 1] = id end
  table.sort(list)
  f.minimal_popup_actions = list
  self.settings:saveSetting("features", f)
  self.settings:flush()
  self:updateConfigFromSettings()
end

-- Minimal Popup quick settings (QS tile hold, maintainer design 2026-08-17):
-- the view mode as one radio row, then the action registry as tap-to-toggle
-- rows, two per row. Self-rebuilding on every change (fresh marks); Close and
-- tap-outside both return to the caller via on_close.
function AskGPT:showMinimalPopupQuickSettings(on_close)
  local ButtonDialog = require("ui/widget/buttondialog")
  local self_ref = self
  local function dot(active) return active and "\u{25CF} " or "\u{25CB} " end
  local f = self.settings:readSetting("features") or {}
  local mode = f.minimal_popup_mode or "short"
  local set = Constants.resolveMinimalPopupActions(f.minimal_popup_actions)

  local dialog
  local function reshow()
    UIManager:close(dialog)
    self_ref:showMinimalPopupQuickSettings(on_close)
  end
  local function setMode(new_mode)
    return function()
      local ff = self_ref.settings:readSetting("features") or {}
      ff.minimal_popup_mode = new_mode
      self_ref.settings:saveSetting("features", ff)
      self_ref.settings:flush()
      self_ref:updateConfigFromSettings()
      reshow()
    end
  end

  local buttons = {
    {
      { text = dot(mode == "off") .. _("Off"), callback = setMode("off") },
      { text = dot(mode == "short") .. _("When it fits"), callback = setMode("short") },
      { text = dot(mode == "always") .. _("Always"), callback = setMode("always") },
    },
  }

  -- Registered actions, same eligibility as the Settings screen picker above
  local actions = self.action_service
    and self.action_service:getAllActions("highlight", true, true) or {}
  local row = {}
  for _idx, action in ipairs(actions) do
    if (action.original_context or action.context) == "highlight" and action.id
        and not action.local_handler then
      local action_id = action.id
      table.insert(row, {
        text = dot(set[action_id] == true) .. (action.text or action_id),
        callback = function()
          self_ref:_toggleMinimalPopupAction(action_id)
          reshow()
        end,
      })
      if #row == 2 then
        table.insert(buttons, row)
        row = {}
      end
    end
  end
  if #row > 0 then table.insert(buttons, row) end

  table.insert(buttons, {
    {
      text = _("Close"),
      callback = function()
        UIManager:close(dialog)
        if on_close then on_close() end
      end,
    },
  })

  dialog = ButtonDialog:new{
    title = _("Minimal Popup"),
    buttons = buttons,
    tap_close_callback = on_close,
  }
  UIManager:show(dialog)
end

-- (buildDictionaryLanguageMenu lives further down, next to the gesture handler
-- that uses it — a dead duplicate definition here was removed 2026-08-05.)

-- Build dictionary context mode picker menu
function AskGPT:buildDictionaryContextModeMenu()
  local self_ref = self
  local menu_items = {}

  local modes = {
    { id = "sentence", text = _("Sentence"), help = _("Extract the full sentence containing the word") },
    { id = "paragraph", text = _("Paragraph"), help = _("Include more surrounding context") },
    { id = "characters", text = _("Characters"), help = _("Fixed number of characters before/after") },
    { id = "none", text = _("None"), help = _("Only send the word, no surrounding context") },
  }

  for _i, mode in ipairs(modes) do
    local mode_copy = mode.id
    table.insert(menu_items, {
      text = mode.text,
      help_text = mode.help,
      checked_func = function()
        local f = self_ref.settings:readSetting("features") or {}
        -- Default must match BookSettings.resolveDictionaryContext (D1: "sentence"),
        -- or the radio dot marks a mode the request isn't actually using.
        local current = f.dictionary_context_mode or "sentence"
        return current == mode_copy
      end,
      radio = true,
      callback = function()
        local f = self_ref.settings:readSetting("features") or {}
        f.dictionary_context_mode = mode_copy
        self_ref.settings:saveSetting("features", f)
        self_ref.settings:flush()
        UIManager:show(Notification:new{
          text = T(_("Context: %1"), mode.text),
          timeout = 1.5,
        })
      end,
    })
  end

  return menu_items
end

-- Edit custom AI behavior text
function AskGPT:editCustomAIBehavior()
  local self_ref = self
  local features = self.settings:readSetting("features") or {}
  local current_text = features.custom_ai_behavior or ""

  local InputDialog = require("ui/widget/inputdialog")
  local input_dialog
  input_dialog = InputDialog:new{
    title = _("Custom AI Behavior"),
    input = current_text,
    input_hint = _("Enter custom AI behavior instructions..."),
    description = _("Define how the AI should behave. This replaces the built-in Minimal/Full behavior when 'Custom' is selected.\n\nTip: Start with the Full behavior as a template."),
    input_type = "text",
    allow_newline = true,
    cursor_at_end = false,
    fullscreen = true,
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
          text = _("Load Full"),
          callback = function()
            local SystemPrompts = require("prompts.system_prompts")
            local full_text = SystemPrompts.getBehavior("full") or ""
            input_dialog:setInputText(full_text)
          end,
        },
        {
          text = _("Save"),
          is_enter_default = true,
          callback = function()
            local new_text = input_dialog:getInputText()
            local f = self_ref.settings:readSetting("features") or {}
            f.custom_ai_behavior = new_text
            self_ref.settings:saveSetting("features", f)
            self_ref.settings:flush()
            UIManager:close(input_dialog)
          end,
        },
      },
    },
  }
  UIManager:show(input_dialog)
  input_dialog:onShowKeyboard()
end

-- Show behavior manager UI
function AskGPT:showBehaviorManager()
  local BehaviorManager = require("koassistant_ui.behavior_manager")
  local manager = BehaviorManager:new(self)
  manager:show()
end

-- Show domain manager UI
function AskGPT:showDomainManager()
  local DomainManager = require("koassistant_ui.domain_manager")
  local manager = DomainManager:new(self)
  manager:show()
end

function AskGPT:addToMainMenu(menu_items)
  menu_items["koassistant"] = {
    text = _("KOAssistant"),
    sorting_hint = "tools",
    sorting_order = 1,
    sub_item_table_func = function()
      self:ensureInitialized()
      return SettingsManager:generateMenuFromSchema(self, SettingsSchema)
    end,
  }
end


function AskGPT:showManageModelsDialog()
  -- Show a message that this feature is now managed through model_lists.lua
  UIManager:show(InfoMessage:new{
    text = _("Model lists are now managed through the model_lists.lua file. Please edit this file to add or remove models."),
  })
end

-- showTranslationDialog() removed - translation language is now configured
-- via Settings → Translation Language (settings_schema.lua)

-- Dictionary popup hook - adds AI Dictionary button to KOReader's native dictionary popup
-- This event is fired by KOReader when the dictionary popup is about to display
-- Shared executor for a dictionary-popup action. Used by BOTH the new
-- addToDictButtons adapter (syncDictButtons) and the legacy onDictButtonsReady
-- fallback. `word` is the looked-up word, `dict_popup` the DictQuickLookup
-- instance, `non_reader_lookup` true when the lookup originated outside the
-- reader (e.g. the chat viewer) so book context must NOT be extracted.
-- `lookup_book`: the originating surface's own book (chat-viewer lookups) —
-- local X-Ray lookups target it instead of whatever the reader has open.
function AskGPT:executeDictAction(action, word, dict_popup, non_reader_lookup, lookup_book)
  local features = self.settings:readSetting("features") or {}

  -- FIRST: Capture selection_data for "Save to Note" feature (before popup closes)
  -- The popup being open means selected_text still exists
  local selection_data = nil
  if self.ui and self.ui.highlight and self.ui.highlight.selected_text then
    local st = self.ui.highlight.selected_text
    selection_data = {
      text = st.text,  -- Just the word
      pos0 = st.pos0,
      pos1 = st.pos1,
      sboxes = st.sboxes,
      pboxes = st.pboxes,
      ext = st.ext,
      drawer = st.drawer,
      color = st.color,
    }
  end

  -- CRITICAL: Extract context BEFORE closing the popup
  -- The highlight/selection is cleared when the popup closes
  -- Extract context only for reader-originated lookups.
  -- Non-reader lookups (ChatGPT viewer, nested dictionary) have no meaningful
  -- book context to extract — the word came from AI-generated or dictionary text.
  local context = ""
  local context_mode = require("koassistant_book_settings")
    .resolveDictionaryContext(self.ui and self.ui.doc_settings, features)
  local context_chars = features.dictionary_context_chars or 100
  local extraction_mode = (context_mode == "none") and "sentence" or context_mode
  local sc_window = nil

  if not non_reader_lookup then
    if self.ui and self.ui.highlight and self.ui.highlight.getSelectedWordContext then
      context = Dialogs.extractSurroundingContext(
        self.ui,
        word,
        extraction_mode,
        context_chars
      )
      -- Pre-extract the surrounding-context window while the selection is alive
      -- (the popup close clears it; handlePredefinedPrompt trims per resolved mode)
      sc_window = Dialogs.fetchSelectionContextWindow(self.ui, word)
    end

    if context ~= "" then
      logger.dbg("KOAssistant DICT: Got context (" .. #context .. " chars)")
    else
      logger.dbg("KOAssistant DICT: No context available (word tap, not selection)")
    end
  end

  if action.local_handler then
    -- Local actions don't need network or dictionary-specific config
    self:updateConfigFromSettings()
    -- Pass dictionary popup reference so X-Ray browser can close it
    -- when launching book text search (prevents widget stack blocking)
    configuration.features._source_widget = dict_popup
    -- Chat-originated lookups carry the chat's own book — it beats whatever
    -- the reader happens to have open (device 2026-08-13: wrong-book lookups)
    Dialogs.executeDirectAction(self.ui, action, word, configuration, self,
      lookup_book and { document_path = lookup_book } or nil)
  else
    -- Ensure network is available (use runWhenConnected to avoid blocking DNS check)
    NetworkMgr:runWhenConnected(function()
      -- Make sure we're using the latest configuration
      self:updateConfigFromSettings()
      -- Get effective dictionary language (per-book override folded in for the open book)
      local SystemPrompts = require("prompts.system_prompts")
      local dict_language = SystemPrompts.getEffectiveDictionaryLanguage(
        require("koassistant_book_settings").applyLanguageOverride({
          dictionary_language = features.dictionary_language,
          translation_language = features.translation_language,
          translation_use_primary = features.translation_use_primary,
          interaction_languages = features.interaction_languages,
          user_languages = features.user_languages,
          primary_language = features.primary_language,
        }, self.ui and self.ui.doc_settings))

      -- Create a shallow copy of configuration to avoid polluting global state
      local dict_config = {}
      for k, v in pairs(configuration) do
        dict_config[k] = v
      end
      -- Deep copy features to avoid modifying global
      dict_config.features = {}
      if configuration.features then
        for k, v in pairs(configuration.features) do
          dict_config.features[k] = v
        end
      end

      -- Scrub stale cross-context state to ensure highlight context (like
      -- executeQuickAction does; also drops a stale book_metadata that would
      -- redirect sidecar reads to another book — injection_gating_audit)
      self:_scrubContextFeatures(dict_config.features)

      -- Set dictionary-specific values
      if non_reader_lookup then
        -- Non-reader lookup: no context available, disable CTX toggle
        dict_config.features.dictionary_context = ""
        dict_config.features._original_context = ""
        dict_config.features._no_context_available = true
        -- Unified flag consumed by handlePredefinedPrompt: the selection is NOT the open
        -- document, so it must not re-extract the book's surrounding context/identity (B3)
        dict_config.features._non_document_selection = true
      else
        -- Only include context in the request if mode is not "none"
        dict_config.features.dictionary_context = (context_mode ~= "none") and context or ""
        -- Always store extracted context so compact view toggle can use it
        dict_config.features._original_context = context
        dict_config.features._original_context_mode = extraction_mode
      end
      dict_config.features.dictionary_language = dict_language
      dict_config.features.dictionary_context_mode = context_mode
      -- Mark the mode authoritative on this copy: handlePredefinedPrompt must not
      -- re-resolve it (the CTX+ toggle's re-run configs inherit this marker, and its
      -- session mode has to beat a per-book override)
      dict_config.features._dictionary_context_explicit = true
      -- Pre-extracted selection window (set-or-clear; a features copy could
      -- otherwise carry a stale one from an earlier launch)
      dict_config.features._selection_context_window = sc_window
      -- Store selection_data for "Save to Note" feature (word position only)
      dict_config.features.selection_data = selection_data

      -- Skip auto-save for dictionary if setting is enabled (default: true)
      if features.dictionary_disable_auto_save ~= false then
        dict_config.features.storage_key = "__SKIP__"
      end

      -- Apply view mode from action definition (respects user overrides)
      if action.compact_view then
        dict_config.features.compact_view = true
        dict_config.features.hide_highlighted_text = true
        dict_config.features.minimal_buttons = action.minimal_buttons ~= false
        dict_config.features.large_stream_dialog = false  -- Small streaming dialog
      elseif action.dictionary_view then
        dict_config.features.dictionary_view = true
        dict_config.features.hide_highlighted_text = true
        dict_config.features.minimal_buttons = action.minimal_buttons ~= false
      end

      -- Check dictionary streaming setting
      if features.dictionary_enable_streaming == false then
        dict_config.features.enable_streaming = false
      end

      -- In popup mode, KOReader's dictionary already triggered WordLookedUp
      -- (the word was added/skipped by KOReader's own vocab builder settings).
      -- We just reflect the state for our UI button — don't fire the event again.
      local vocab_settings = G_reader_settings and G_reader_settings:readSetting("vocabulary_builder") or {}
      if vocab_settings.enabled then
        dict_config.features.vocab_word_auto_added = true
      end

      -- Execute the action
      Dialogs.executeDirectAction(
        self.ui,       -- ui
        action,        -- action
        word,          -- highlighted_text
        dict_config,   -- local config copy (not global)
        self           -- plugin
      )
    end)
  end
end

-- New-API adapter: register our dictionary-popup actions via KOReader's
-- addToDictButtons (PR #15184+). Re-runnable — clears our prior entries first,
-- so it reflects the current configured action set on every call. Buttons are
-- `conditional` (always shown, gated only by show_func) and grouped into rows of
-- three to mirror the legacy layout. Driven by the showDict wrapper installed in
-- init(), so reorders / X-Ray-cache changes take effect on the next popup.
function AskGPT:syncDictButtons()
  local dictionary = self.ui and self.ui.dictionary
  if not dictionary or type(dictionary.addToDictButtons) ~= "function" then
    return  -- old KOReader: legacy onDictButtonsReady path handles registration
  end

  local DictButtons = require("koassistant_dict_buttons")

  -- Clear our previously-registered buttons (no removal API; nil the keys).
  -- Collect keys first, then delete — never mutate while iterating.
  if dictionary._dict_buttons then
    local stale = DictButtons.ourKeys(dictionary._dict_buttons)
    for _idx = 1, #stale do
      dictionary._dict_buttons[stale[_idx]] = nil
    end
  end

  local features = self.settings:readSetting("features") or {}
  if features.enable_dictionary_hook == false then
    return  -- hook disabled: leave our buttons cleared
  end

  local has_open_book = self.ui and self.ui.document ~= nil
  local document_path = has_open_book and self.ui.document.file
  local popup_actions = self.action_service:getDictionaryPopupActionObjects(has_open_book, document_path)

  local self_ref = self
  for i, action in ipairs(popup_actions) do
    local act = action  -- capture per-iteration for closures
    local spec = DictButtons.scaffold(act, i, ActionService.getActionDisplayText(act, features))
    spec.show_func = function(popup)
      local has_doc = (self_ref.ui and self_ref.ui.document) ~= nil
      local visible = DictButtons.shouldShow(popup, act, has_doc, function()
        local path = self_ref.ui and self_ref.ui.document and self_ref.ui.document.file
        return path ~= nil and require("koassistant_action_cache").hasAnyXray(path)
      end)
      if not visible then return false end
      -- Consume the non-reader-lookup flag once, onto the popup (idempotent
      -- across rebuilds from pagination/resize).
      DictButtons.consumeNonReader(popup, self_ref.ui and self_ref.ui.dictionary)
      return true
    end
    spec.callback = function(popup)
      self_ref:executeDictAction(act, popup.word, popup, popup._koassistant_non_reader,
        popup._koassistant_lookup_book)
    end
    dictionary:addToDictButtons(spec)
  end
end

-- Install new-API (KOReader PR #15184+) dictionary button registration.
-- No-op on older KOReader (the legacy onDictButtonsReady event handles those).
-- Wraps showDict — the single popup-builder for every lookup — so the button set
-- is refreshed right before each popup builds. This per-popup refresh is what
-- keeps reorders and the conditional X-Ray button live without relying on events
-- (onWordLookedUp is unreliable: VocabBuilder consumes it before us).
function AskGPT:installDictButtonRegistration()
  local dictionary = self.ui and self.ui.dictionary
  if not dictionary or type(dictionary.addToDictButtons) ~= "function" then
    return  -- old API: nothing to install (legacy path covers it)
  end

  if not dictionary._koassistant_original_showDict then
    dictionary._koassistant_original_showDict = dictionary.showDict
    local self_ref = self
    dictionary.showDict = function(dict_self, ...)
      self_ref:syncDictButtons()
      local result = dictionary._koassistant_original_showDict(dict_self, ...)
      -- Safety: clear any non-reader flag that no show_func consumed (e.g. when
      -- our buttons are hidden) so it cannot leak to a later popup.
      dict_self._koassistant_non_reader_lookup = nil
      dict_self._koassistant_lookup_book = nil
      return result
    end
  end

  -- Eager initial registration so the very first popup already has buttons.
  self:syncDictButtons()
end

function AskGPT:onDictButtonsReady(dict_popup, dict_buttons)
  -- New KOReader (PR #15184+) uses addToDictButtons and no longer broadcasts the
  -- DictButtonsReady event, so this legacy hook is dead there. Guard anyway: on
  -- such builds registration happens via syncDictButtons (showDict wrapper).
  if self.ui and self.ui.dictionary and type(self.ui.dictionary.addToDictButtons) == "function" then
    return
  end

  -- Check if the hook is enabled
  local features = self.settings:readSetting("features") or {}
  if features.enable_dictionary_hook == false then
    return
  end

  -- Skip Wikipedia popups - only show AI buttons in dictionary
  if dict_popup and dict_popup.is_wiki then
    return
  end

  local self_ref = self

  -- Extract the word from the dictionary popup
  local word = dict_popup and dict_popup.word
  if not word or word == "" then
    return
  end

  -- Check if this is a non-reader lookup (e.g., from ChatGPT viewer).
  -- Capture early so button callbacks (fired later) can use it via closure.
  local non_reader_lookup = self.ui and self.ui.dictionary
      and self.ui.dictionary._koassistant_non_reader_lookup
  local lookup_book = self.ui and self.ui.dictionary
      and self.ui.dictionary._koassistant_lookup_book
  if non_reader_lookup or lookup_book then
    self.ui.dictionary._koassistant_non_reader_lookup = nil  -- Consume flags
    self.ui.dictionary._koassistant_lookup_book = nil
  end

  -- Get configured actions for dictionary popup
  -- Filter out actions requiring open book if no book is open (should always be true for dictionary)
  local has_open_book = self.ui and self.ui.document ~= nil
  local document_path = has_open_book and self.ui.document.file
  local popup_actions = self.action_service:getDictionaryPopupActionObjects(has_open_book, document_path)
  if #popup_actions == 0 then
    return  -- No actions configured
  end

  -- Helper function to create a button for an action
  local function createActionButton(action)
    return {
      text = ActionService.getActionDisplayText(action, features) .. " (KOA)",
      font_bold = true,
      callback = function()
        self_ref:executeDictAction(action, word, dict_popup, non_reader_lookup, lookup_book)
      end,
    }
  end

  -- Create buttons arranged in rows of 3
  local buttons = {}
  for _i, action in ipairs(popup_actions) do
    table.insert(buttons, createActionButton(action))
  end
  local plugin_rows = require("koassistant_dict_buttons").splitRows(buttons)

  -- Insert all rows at position 2 (after the first row of standard buttons)
  -- Insert in reverse order so they appear in correct order
  for i = #plugin_rows, 1, -1 do
    table.insert(dict_buttons, 2, plugin_rows[i])
  end
end

-- Generated-images browser (Settings → Advanced → Image Generation)
function AskGPT:showImageBrowser()
  local ImageBrowser = require("koassistant_image_browser")
  ImageBrowser.show()
end

-- The exact prompt sent to the image API, rendered through the live builder
-- with the current framing toggles (Settings → Advanced → Image Generation)
function AskGPT:showImageGenPromptTemplate()
  local ImageGenerator = require("koassistant_image_generator")
  local TextViewer = require("ui/widget/textviewer")
  local features = self.settings:readSetting("features") or {}
  UIManager:show(TextViewer:new{
    title = _("Image prompt template"),
    text = ImageGenerator.promptTemplateText(features)
        .. "\n\n" .. _("Book title/author and surrounding text are included only when available for the request."),
  })
end

-- Ghost-widget net (device family #9, 2026-08-17): ReaderUI:showReader
-- broadcasts ShowingReader before every book open but closes only the
-- FileManager, so any cross-book plugin Menu/dialog left below survives into
-- the reader — painted full-screen during the opening repaint, then stuck
-- under it, and it blocks app exit (non-empty window stack). One sweep closes
-- every module singleton at that moment; per-site closes remain the polite
-- fast path. SetupShowReader (the calibre/cloudstorage pre-announce pattern)
-- is honored too.
function AskGPT:_sweepCrossBookSurfaces()
  local function closeField(mod_path, field)
    local ok, mod = pcall(require, mod_path)
    if ok and type(mod) == "table" and mod[field] then
      local widget = mod[field]
      mod[field] = nil
      UIManager:close(widget)
    end
  end
  -- Detail overlay above the X-Ray browser first, then the hosts
  closeField("koassistant_xray_browser", "_detail_viewer")
  closeField("koassistant_xray_browser", "menu")
  closeField("koassistant_book_page", "_menu")
  closeField("koassistant_artifact_browser", "current_menu")
  closeField("koassistant_chat_history_dialog", "current_menu")
  closeField("koassistant_notebook_manager", "current_menu")
  closeField("koassistant_book_groups_ui", "_group_dialog")
  -- The stock long-press file dialog: ReaderUI closes the FileManager itself,
  -- never this separate window (the #1 dead-guard sites' stock sibling)
  if FileManager.instance and FileManager.instance.file_dialog then
    local fd = FileManager.instance.file_dialog
    FileManager.instance.file_dialog = nil
    UIManager:close(fd)
  end
end

function AskGPT:onShowingReader()
  self:_sweepCrossBookSurfaces()
end

function AskGPT:onSetupShowReader()
  self:_sweepCrossBookSurfaces()
end

-- Event handlers for gesture-triggered actions
function AskGPT:onKOAssistantChatHistory()
  -- Use the same implementation as the settings menu
  self:showChatHistory()
  return true
end

function AskGPT:onKOAssistantContinueLast()
  local ChatHistoryManager = require("koassistant_chat_history_manager")
  local ChatHistoryDialog = require("koassistant_chat_history_dialog")

  -- Get the most recently saved chat across all documents
  local most_recent_chat, document_path = ChatHistoryManager:getMostRecentChat()

  if not most_recent_chat then
    UIManager:show(InfoMessage:new{
      icon = "notice-warning",
      text = _("No saved chats found")
    })
    return true
  end

  logger.dbg("Continue last saved chat: found chat ID " .. (most_recent_chat.id or "nil") ..
              " for document: " .. (document_path or "nil"))

  -- Continue the most recent chat
  local chat_history_manager = ChatHistoryManager:new()
  ChatHistoryDialog:continueChat(self.ui, document_path, most_recent_chat, chat_history_manager, configuration)
  return true
end

function AskGPT:onKOAssistantContinueLastOpened()
  local ChatHistoryManager = require("koassistant_chat_history_manager")
  local ChatHistoryDialog = require("koassistant_chat_history_dialog")

  -- Get the last opened chat (regardless of when it was last saved)
  local chat_history_manager = ChatHistoryManager:new()
  local last_opened_chat, document_path = chat_history_manager:getLastOpenedChat()

  if not last_opened_chat then
    UIManager:show(InfoMessage:new{
      icon = "notice-warning",
      text = _("No previously opened chat found")
    })
    return true
  end

  logger.dbg("Continue last opened chat: found chat ID " .. (last_opened_chat.id or "nil") ..
              " for document: " .. (document_path or "nil"))

  -- Continue the last opened chat
  ChatHistoryDialog:continueChat(self.ui, document_path, last_opened_chat, chat_history_manager, configuration)
  return true
end

function AskGPT:onKOAssistantGeneralChat()
  if not configuration then
    UIManager:show(InfoMessage:new{
      icon = "notice-warning",
      text = _("Configuration not found. Please set up configuration.lua first.")
    })
    return true
  end

  -- Close any existing input dialog to prevent stacking
  if self.current_input_dialog then
    UIManager:close(self.current_input_dialog)
    self.current_input_dialog = nil
  end

  self:ensureInitialized()
  -- Make sure we're using the latest configuration
  self:updateConfigFromSettings()

  -- Set context flag on the original configuration (no copy needed)
  -- This ensures settings changes are immediately visible
  configuration.features = configuration.features or {}
  -- Scrub inherited context state, then mark general
  self:_scrubContextFeatures(configuration.features)
  configuration.features.is_general_context = true

  -- Show dialog with general context
  showChatGPTDialog(self.ui, nil, configuration, nil, self)
  return true
end

function AskGPT:onKOAssistantBookChat()
  -- Check if we have a document open
  if not self.ui or not self.ui.document then
    UIManager:show(InfoMessage:new{
      icon = "notice-warning",
      text = _("Please open a book first")
    })
    return true
  end

  -- Get book metadata from KOReader's merged props (includes user edits from Book Info dialog)
  local doc_props = self.ui.doc_props or {}
  local title = doc_props.display_title or doc_props.title or "Unknown"
  local authors = doc_props.authors or ""

  -- Call the existing function that handles file browser context properly
  self:showKOAssistantDialogForFile(self.ui.document.file, title, authors, doc_props)
  return true
end

--- Show available cached content for current document
local formatRelativeTime = Constants.formatRelativeTime

--- Format the source label for cache viewers (AI training data vs extracted text)
--- @param used_book_text boolean|nil Whether book text was used to build the cache
--- @return string Label text
local function formatCacheSourceLabel(used_book_text, source_mode)
  if source_mode == "summary" then
    return _("Based on document summary")
  elseif source_mode == "ai_knowledge" then
    return _("Based on AI training data knowledge")
  elseif used_book_text == false then
    return _("Based on AI training data knowledge")
  else
    return _("Based on extracted document text")
  end
end

--- Format a date with optional relative time suffix
--- @param timestamp number Unix timestamp
--- @return string Formatted date string (e.g., "2026-02-10 (3d ago)")
local function formatDateWithRelative(timestamp)
  if not timestamp then return "" end
  -- Time of day included (round 26, maintainer request): this string is
  -- Info-only — the artifact rows elsewhere show the relative form — and
  -- several artifacts a day is normal once merges and rebuilds are in play
  local date_str = os.date("%Y-%m-%d %H:%M", timestamp)
  local relative = formatRelativeTime(timestamp)
  if relative ~= "" then
    date_str = date_str .. " (" .. relative .. ")"
  end
  return date_str
end

--- Build info popup text for artifact viewer (labeled lines for Info button popup).
--- @param cached_entry table: Cache entry with progress_decimal, model, timestamp, etc.
--- @param progress_str string|nil: Pre-formatted progress string (e.g., "45%")
--- @return string: Multi-line info text for InfoMessage popup
local function buildInfoPopupText(cached_entry, progress_str)
  local info_lines = {}
  if progress_str then
    local progress_label = progress_str
    if cached_entry.previous_progress_decimal then
      progress_label = progress_label .. " (" .. _("updated from") .. " "
          .. math.floor(cached_entry.previous_progress_decimal * 100 + 0.5) .. "%)"
    end
    table.insert(info_lines, _("Progress:") .. " " .. progress_label)
  end
  table.insert(info_lines, _("Source:") .. " " .. formatCacheSourceLabel(cached_entry.used_book_text, cached_entry.source_mode))
  if cached_entry.model then
    table.insert(info_lines, _("Model:") .. " " .. cached_entry.model)
  end
  if cached_entry.timestamp then
    table.insert(info_lines, _("Date:") .. " " .. formatDateWithRelative(cached_entry.timestamp))
  end
  if cached_entry.language then
    table.insert(info_lines, _("Language:") .. " " .. cached_entry.language)
  end
  if cached_entry.used_reasoning then
    table.insert(info_lines, _("Reasoning:") .. " " .. _("Yes"))
  end
  if cached_entry.web_search_used then
    table.insert(info_lines, _("Web search:") .. " " .. _("Yes"))
  end
  if cached_entry.tokens_in or cached_entry.tokens_out then
    local tok = T(_("%1 in, %2 out"), cached_entry.tokens_in or 0, cached_entry.tokens_out or 0)
    if cached_entry.tokens_reasoning and cached_entry.tokens_reasoning > 0 then
      tok = tok .. " " .. T(_("(%1 thinking)"), cached_entry.tokens_reasoning)
    end
    table.insert(info_lines, _("Tokens:") .. " " .. tok)
  end
  return table.concat(info_lines, "\n")
end

--- Build inline indicator text for reasoning/web search usage (matching chat viewer style).
--- Respects show_reasoning_indicator and show_web_search_indicator settings.
--- @param cached_entry table: Cache entry with used_reasoning, web_search_used
--- @param config table|nil: Configuration with features settings
--- @return string|nil: Indicator text to prepend, or nil if no indicators
local function buildInlineIndicators(cached_entry, config)
  local indicators = {}
  local features = config and config.features
  -- Default to showing indicators (matching chat viewer defaults)
  local show_reasoning = not features or features.show_reasoning_indicator ~= false
  local show_web_search = not features or features.show_web_search_indicator ~= false
  -- Combined single-line indicator (matching the chat viewer); no gear hint here —
  -- artifact details live behind the Info button, not the gear
  local usage = Constants.buildUsageIndicator({
    reasoning = (show_reasoning and cached_entry.used_reasoning) or nil,
    web_search = (show_web_search and cached_entry.web_search_used) or nil,
  })
  if usage then
    table.insert(indicators, usage)
  end
  -- Source mode indicator (for source_selection actions with non-default source)
  if cached_entry.source_mode == "summary" then
    table.insert(indicators, "*[" .. _("Based on document summary") .. "]*")
  elseif cached_entry.source_mode == "ai_knowledge" then
    table.insert(indicators, "*[" .. _("Based on AI knowledge only") .. "]*")
  end
  -- Show unavailable data notice (same format as chat viewer's MessageHistory)
  if cached_entry.unavailable_data_text then
    table.insert(indicators, "*Response generated without: " .. cached_entry.unavailable_data_text .. "*")
  end
  if #indicators > 0 then
    return table.concat(indicators, "\n") .. "\n\n"
  end
  return nil
end

function AskGPT:viewCache(parent_dialog)
  if not self.ui or not self.ui.document or not self.ui.document.file then
    UIManager:show(InfoMessage:new{
      text = _("No book open"),
    })
    return
  end

  local ActionCache = require("koassistant_action_cache")
  local file = self.ui.document.file

  local caches = ActionCache.getAvailableArtifactsWithPinned(file, nil, self.ui.document)

  -- Refresh artifact index for this document (populates index for pre-existing artifacts)
  ActionCache.refreshIndex(file)

  if #caches == 0 then
    UIManager:show(InfoMessage:new{
      text = _("No artifacts found for this document.\n\nRun X-Ray, Recap, X-Ray (Simple), Document Summary, or Document Analysis to create them."),
    })
    return
  end

  -- Always show popup selector with metadata (even for single artifact)
  local self_ref = self
  local buttons = {}
  for _idx, cache in ipairs(caches) do
    -- Format with metadata: "X-Ray (65%, today)" or pinned indicator —
    -- shared meta (A4 parity), percent always when tracked
    local display = cache.name
    if not cache.is_pinned_group and not cache.is_section_group and not cache.is_wiki_group then
      local meta = Constants.formatArtifactMeta(cache.data)
      if meta then display = display .. " (" .. meta .. ")" end
    end
    table.insert(buttons, {{
      text = display,
      callback = function()
        if cache.is_image_group then
          UIManager:close(self_ref._cache_selector)
          if parent_dialog then UIManager:close(parent_dialog) end
          local props = self_ref.ui and self_ref.ui.doc_props
          local ImageBrowser = require("koassistant_image_browser")
          ImageBrowser.show({ book_file = file,
            book_title = props and (props.display_title or props.title) })
        elseif cache.is_xray_versions_group then
          UIManager:close(self_ref._cache_selector)
          if parent_dialog then UIManager:close(parent_dialog) end
          self_ref:_showXrayCheckpointList()
        elseif cache.is_section_group or cache.is_wiki_group or cache.is_pinned_group then
          local ArtifactBrowser = require("koassistant_artifact_browser")
          local props = self_ref.ui and self_ref.ui.doc_props
          local book_title = props and (props.display_title or props.title)
          local selector = self_ref._cache_selector
          local close_all = function()
            UIManager:close(selector)
            if parent_dialog then UIManager:close(parent_dialog) end
          end
          if cache.is_section_xray_group then
            ArtifactBrowser:_showSectionXrayGroupPopup(
                cache.data, file, book_title, self_ref, cache._excluded_section_key, close_all)
          elseif cache.is_section_group then
            ArtifactBrowser:_showSectionGroupPopup(
                cache.data, file, book_title, self_ref, cache.section_type, cache._excluded_section_key, close_all)
          elseif cache.is_wiki_group then
            ArtifactBrowser:_showWikiGroupPopup(cache.data, file, self_ref, book_title, close_all)
          else
            ArtifactBrowser:_showPinnedGroupPopup(cache.data, file, book_title, close_all)
          end
        else
          UIManager:close(self_ref._cache_selector)
          -- Close parent dialog (e.g., QA panel) only when user picks an artifact
          if parent_dialog then UIManager:close(parent_dialog) end
          if cache.is_per_action then
            self_ref:viewCachedAction({ text = cache.name }, cache.key, cache.data)
          else
            self_ref:showCacheViewer(cache)
          end
        end
      end,
    }})
  end
  -- Book page round (2026-08-09): the popup stays the two-tap fast path; the
  -- page is the explore view (same artifact rows + chats/notebook/group/settings)
  table.insert(buttons, {{
    text = require("koassistant_book_page").entryLabel(),
    callback = function()
      UIManager:close(self_ref._cache_selector)
      if parent_dialog then UIManager:close(parent_dialog) end
      local props = self_ref.ui and self_ref.ui.doc_props
      require("koassistant_book_page").show({
        file = file,
        plugin = self_ref,
        ui = self_ref.ui,
        title = props and (props.display_title or props.title),
        author = props and props.authors,
        enable_emoji = configuration and configuration.features
            and configuration.features.enable_emoji_icons == true,
      })
    end,
  }})
  table.insert(buttons, {{
    text = _("Cancel"),
    callback = function()
      UIManager:close(self._cache_selector)
    end,
  }})

  self._cache_selector = ButtonDialog:new{
    title = _("View Artifacts"),
    buttons = buttons,
  }
  UIManager:show(self._cache_selector)
end

--- Build a callback for launching a new book chat from an artifact viewer.
--- Opens the input dialog in book context so the user can ask about the artifact.
--- @param artifact_file string The book file path
--- @param artifact_book_title string The book title
--- @param artifact_book_author string The book author
--- @return function|nil The callback, or nil if no file
function AskGPT:_buildLaunchChatCallback(artifact_file, artifact_book_title, artifact_book_author, artifact_content, artifact_type_name)
  if not artifact_file then return nil end
  local self_ref = self
  return function(user_question)
    self_ref:updateConfigFromSettings()

    -- Build a fresh config copy for the chat (book context)
    local config_copy = {}
    for k, v in pairs(configuration) do config_copy[k] = v end
    config_copy.features = {}
    for k, v in pairs(configuration.features or {}) do config_copy.features[k] = v end
    config_copy.features.is_general_context = nil
    config_copy.features.is_book_context = true
    config_copy.features.is_library_context = nil

    local book_metadata = {
      title = artifact_book_title or "Unknown",
      author = artifact_book_author or "",
      file = artifact_file,
    }
    config_copy.features.book_metadata = book_metadata

    Dialogs.launchArtifactChat(user_question, artifact_content or "", artifact_type_name or _("Artifact"), self_ref.ui, config_copy, self_ref, book_metadata)
  end
end

--- Show a specific cache in the viewer
--- @param cache_info table: { name, key, data } where data contains result, progress_decimal, model, timestamp, used_annotations, used_book_text
--- Main-menu entry (settings schema "book_groups" action row, item 46)
function AskGPT:showBookGroupsManager()
  local GroupsUI = require("koassistant_book_groups_ui")
  GroupsUI.showManager({ plugin = self, ui = self.ui })
end

--- Cheap membership check — callers build "→ Group" buttons lazily from it.
function AskGPT:_inBookGroup(file)
  return file ~= nil and #require("koassistant_book_groups").groupsFor(file) > 0
end

--- Book Hub entry for registry-driven surfaces (QA panel utility
--- "book_overview" — internal id unchanged by the A4 rename; also the
--- main-menu row and the Dispatcher gesture action; reader mode, so the
--- open book is the target)
function AskGPT:onKOAssistantBookOverview()
  local file = self.ui and self.ui.document and self.ui.document.file
  if not file then return true end
  local props = self.ui.doc_props
  require("koassistant_book_page").show({
    file = file,
    plugin = self,
    ui = self.ui,
    title = props and (props.display_title or props.title),
    author = props and props.authors,
    enable_emoji = configuration and configuration.features
        and configuration.features.enable_emoji_icons == true,
  })
  return true
end

--- Group entry for registry-driven surfaces (QA panel utility "book_group",
--- gestures). Members popup when this book is in a group, the manager
--- otherwise — so the entry is never a dead end.
function AskGPT:onKOAssistantBookGroup()
  local file = self.ui and self.ui.document and self.ui.document.file
  if file and self:_inBookGroup(file) then
    self:_showGroupMembersPopup(file, "artifacts")
  else
    self:showBookGroupsManager()
  end
  return true
end

--- Book-group members popup (item 46) — THE group-navigation idiom: one
--- ordered list of the group's books (current one marked), replacing the old
--- prev/next pair. What a tap opens depends on mode:
---   "artifacts" — that book's Book Hub page (never empty — chrome rows at
---                 minimum, so no disabled rows in this mode; A4)
---   "xray"      — that book's live X-Ray (grayed "(no X-Ray)")
--- @param file string The current book (its groups are listed)
--- @param mode string "artifacts" | "xray"
--- @param opts table|nil { before_open = fn } — runs before a member surface
---   opens; { location = { category_key, item_name, item_aliases } } ("xray"
---   mode only) — where the reader is in THIS book's X-Ray, so the member's
---   opens at the same entity/category (XrayBrowser:_applyPendingLocation
---   falls back one level at a time when it has neither)
--- S4 (ref #90): the three module hooks behind cross-book X-Ray knowledge.
--- Single slots, so the most recently created plugin instance (the reader's,
--- when a book is open) owns them; the direction resolver reads the live
--- DocSettings only while that instance still has a document.
function AskGPT:_installGroupSeedingHooks()
  local self_ref = self
  local ActionCache = require("koassistant_action_cache")
  local BookGroups = require("koassistant_book_groups")
  -- Earlier books only while the current book is under spoiler protection;
  -- both directions once it is not (off, marked finished, research mode)
  ActionCache.setLookupDirectionResolver(function(file)
    local features = configuration and configuration.features
    if not features then return false end
    local ui = (self_ref.ui and self_ref.ui.document) and self_ref.ui or nil
    local ds = require("koassistant_doc_settings").resolve(file, ui)
    return require("koassistant_book_settings").resolveSpoilerFree(ds, features) == false
  end)
  BookGroups.on_change = function(group_id)
    self_ref:_scheduleGroupReseed(group_id)
  end
  ActionCache.on_live_xray_written = function(file)
    for _idx, group in ipairs(BookGroups.groupsFor(file)) do
      self_ref:_scheduleGroupReseed(group.id)
    end
  end
end

--- Debounced automatic seeding of a group's carried lists (S4): every
--- trigger within 2 s folds into one run; the run suppresses the write hook
--- for its own writes and re-syncs the marks when it wrote anything.
function AskGPT:_scheduleGroupReseed(group_id)
  if type(group_id) ~= "string" or group_id == "" then return end
  self._reseed_pending = self._reseed_pending or {}
  self._reseed_pending[group_id] = true
  if self._reseed_fn then UIManager:unschedule(self._reseed_fn) end
  local self_ref = self
  self._reseed_fn = function()
    local pending = self_ref._reseed_pending or {}
    self_ref._reseed_pending = {}
    local ActionCache = require("koassistant_action_cache")
    local BookGroups = require("koassistant_book_groups")
    local XrayMerge = require("koassistant_xray_merge")
    local ui = (self_ref.ui and self_ref.ui.document) and self_ref.ui or nil
    ActionCache.suppress_write_hook = true
    for id in pairs(pending) do
      local group = BookGroups.byId(id)
      if group then
        local ok, written, checked = pcall(XrayMerge.reseedGroup, group,
          (configuration and configuration.features) or {},
          configuration and configuration.provider, ui)
        if not ok then
          logger.warn("KOAssistant: group seeding failed:", tostring(written))
        elseif (written or 0) > 0 then
          logger.info("KOAssistant: group seeding wrote", written, "carried list(s) of",
            checked, "checked")
          if self_ref.syncXrayMarks then pcall(function() self_ref:syncXrayMarks() end) end
        end
      end
    end
    ActionCache.suppress_write_hook = false
  end
  UIManager:scheduleIn(2, self._reseed_fn)
end

function AskGPT:_showGroupMembersPopup(file, mode, opts)
  local BookGroups = require("koassistant_book_groups")
  local GroupsUI = require("koassistant_book_groups_ui")
  local list = BookGroups.groupsFor(file)
  if #list == 0 then return end
  local ButtonDialog = require("ui/widget/buttondialog")
  local ActionCache = require("koassistant_action_cache")
  local self_ref = self
  local dialog
  local rows = {}
  for _g, group in ipairs(list) do
    if #list > 1 then
      rows[#rows + 1] = {{ text = GroupsUI.displayName(group), enabled = false }}
    end
    for i, path in ipairs(group.books) do
      local captured = path
      local title = BookGroups.displayTitle(captured, self.ui)
      local raw_title = title  -- undecorated, for the member's Book Hub header
      -- A3: mark missing files here too (the group screen already does) —
      -- rows with content stay tappable, sidecars outlive moved books
      if not BookGroups.fileExists(captured) then
        title = title .. " " .. _("(missing)")
      end
      local cb
      if captured == file then
        title = title .. " " .. _("(this book)")
      elseif mode == "xray" then
        local ok, entry = pcall(ActionCache.getXrayCache, captured)
        if ok and entry and entry.result then
          -- Entity graying (2026-08-09 round answer A): with an entity
          -- context, a member whose X-Ray lacks the entity (name+aliases,
          -- entity's category preferred — findByIdentity) is disabled instead
          -- of offering a jump that could only fall back. One parse per
          -- member, only at popup-open; the → Group button itself stays
          -- ungated (per-detail gating would pay these reads on every page).
          local present = true
          if opts and opts.location and opts.location.item_name then
            local XrayParser = require("koassistant_xray_parser")
            local parsed = XrayParser.parse(entry.result)
            local names = { opts.location.item_name }
            for _i, a in ipairs(opts.location.item_aliases or {}) do
              names[#names + 1] = a
            end
            present = (parsed and not parsed.error
              and XrayParser.findByIdentity(parsed, names, opts.location.category_key)) ~= nil
          end
          if present then
            cb = function()
              UIManager:close(dialog)
              if opts and opts.before_open then opts.before_open() end
              -- Round 25: land the jump where the reader was in THIS book's
              -- X-Ray (set inside the callback, so a dismissed popup leaves no
              -- stranded descriptor; the book stamp guards a browser that never
              -- opens — e.g. an unparseable cache falls through to plain text)
              if opts and opts.location then
                require("koassistant_xray_browser")._pending_navigate_to = {
                  category_key = opts.location.category_key,
                  item_name = opts.location.item_name,
                  item_aliases = opts.location.item_aliases,
                  book_file = captured,
                  fallback = true,
                }
              end
              -- Q16: the jumped-to browser's up-arrow at root returns to the
              -- X-Ray this popup was opened from (browser callers pass it)
              if opts and opts.return_to then
                local rt = {}
                for k, v in pairs(opts.return_to) do rt[k] = v end
                rt.target = captured
                require("koassistant_xray_browser")._pending_return_to = rt
              end
              self_ref:showCacheViewer({ name = _("X-Ray"), key = "_xray_cache",
                data = entry, book_title = title, file = captured })
            end
          else
            title = title .. " " .. _("(not in its X-Ray)")
          end
        else
          title = title .. " " .. _("(no X-Ray)")
        end
      else
        -- A4: a member row opens the member's Book Hub — every book has one
        -- (chrome rows at minimum), so the old artifact gate, its disabled
        -- "(no artifacts)" rows and the bare 1-arg selector call all retire
        cb = function()
          UIManager:close(dialog)
          if opts and opts.before_open then opts.before_open() end
          require("koassistant_book_page").show({
            file = captured,
            plugin = self_ref,
            ui = self_ref.ui,
            title = raw_title,
            enable_emoji = configuration and configuration.features
                and configuration.features.enable_emoji_icons == true,
          })
        end
      end
      rows[#rows + 1] = {{
        text = i .. ". " .. title,
        align = "left",
        enabled = cb ~= nil,
        callback = cb,
      }}
    end
  end
  -- A2 merge discoverability: fold group-mates into THIS book from group
  -- navigation — the flow's picker leads with the chain/fan-in rows per kind.
  -- Plain groups share nothing by design, so they get no row.
  local mp_shares = false
  for _g, group in ipairs(list) do
    if BookGroups.sharesKnowledge(group) then mp_shares = true end
  end
  if mp_shares then
    rows[#rows + 1] = {{
      text = _("Merge / fold X-Rays…"),
      callback = function()
        UIManager:close(dialog)
        -- before_open retires the browser this popup may sit over — the flow
        -- calls it only when a merge actually starts (deferred, T11)
        self_ref:_startCrossBookXrayFlow(file,
          { close_browser = opts and opts.before_open })
      end,
    }}
  end
  -- Round 29 (audit): every row here is a NAVIGATION target, and in xray mode
  -- a row is disabled when its book has no X-Ray — so a fresh group could
  -- render a popup with nothing tappable and no way onward. Always offer the
  -- manager, which is where adding, reordering and the series/project switch
  -- live. (Artifacts mode stopped disabling rows with the A4 Book Hub swap.)
  rows[#rows + 1] = {{
    text = _("Manage groups…"),
    callback = function()
      UIManager:close(dialog)
      self_ref:showBookGroupsManager()
    end,
  }}
  dialog = ButtonDialog:new{
    title = #list == 1 and T(_("Group: %1"), GroupsUI.displayName(list[1])) or _("Groups"),
    buttons = rows,
  }
  UIManager:show(dialog)
end

function AskGPT:showCacheViewer(cache_info)
  local ChatGPTViewer = require("koassistant_chatgptviewer")
  local ActionCache = require("koassistant_action_cache")

  -- Get book metadata: prefer explicit (artifact browser may show a different book)
  -- Fall back to open book's merged props (includes user edits from Book Info dialog)
  local book_title = cache_info.book_title
  local book_author = cache_info.book_author
  if not book_title and self.ui then
    local props = self.ui.doc_props
    if props then
      book_title = props.display_title or props.title
      book_author = book_author or props.authors
    end
  end

  -- Format title: Type (XX%) - Book Title (only for partial progress)
  local progress_str
  if cache_info.data.progress_decimal and cache_info.data.progress_decimal < 1.0 then
    progress_str = math.floor(cache_info.data.progress_decimal * 100 + 0.5) .. "%"
  end
  local title = cache_info.name
  if progress_str then
    title = title .. " (" .. progress_str .. ")"
  end
  if cache_info.data.timestamp then
    local rel = formatRelativeTime(cache_info.data.timestamp)
    if rel ~= "" then
      title = title .. " · " .. rel
    end
  end
  if book_title then
    title = title .. " - " .. book_title
  end

  -- Build info popup text (for Info button)
  local info_popup_text = buildInfoPopupText(cache_info.data, progress_str)

  -- Map cache key to cache type
  local cache_type_map = {
    ["_xray_cache"] = "xray",
    ["_summary_cache"] = "summary",
    ["_analyze_cache"] = "analyze",
  }
  local is_section_xray = type(cache_info.key) == "string"
      and cache_info.key:sub(1, #ActionCache.SECTION_XRAY_PREFIX) == ActionCache.SECTION_XRAY_PREFIX
  local cache_type = is_section_xray and "section_xray" or (cache_type_map[cache_info.key] or "cache")

  -- Build cache metadata for export
  local cache_metadata = {
    cache_type = cache_type,
    book_title = book_title,
    book_author = book_author,
    progress_decimal = cache_info.data.progress_decimal,
    model = cache_info.data.model,
    timestamp = cache_info.data.timestamp,
    used_annotations = cache_info.data.used_annotations,
    used_book_text = cache_info.data.used_book_text,
    scope_label = cache_info.data.scope_label,
    scope_page_summary = cache_info.data.scope_page_summary,
  }

  -- Create delete/regenerate callbacks
  -- Delete works from both open book and file browser (via cache_info.file fallback)
  -- Prefer explicit file (artifact browser may pass a different book than the one open)
  -- Checkpoint views (archived X-Ray versions) are read-only: no delete/regenerate —
  -- deleting the LIVE cache from an archived version's viewer would be a trap
  local on_delete = nil
  local on_regenerate = nil
  local file = cache_info.file or (self.ui and self.ui.document and self.ui.document.file)
  if file and not cache_info.checkpoint then
    local cache_key = cache_info.key
    local cache_name = cache_info.name

    on_delete = function(keep_versions)
      -- Clear the appropriate cache based on key
      if cache_key == "_xray_cache" then
        -- Round 28: ONE lineage-delete helper; the ladder always dies (a
        -- prepared rung would resurrect the X-Ray), the archived versions only
        -- when the reader said so (delete_options below)
        ActionCache.deleteXray(file, { keep_versions = keep_versions })
        -- The per-book state describing the deleted lineage dies with it
        -- (coverage-ask stamp, promotion hold, automatic override)
        require("koassistant_book_settings").clearXrayLineageState(
          require("koassistant_doc_settings").resolve(file, self.ui))
      elseif cache_key == "_analyze_cache" then
        ActionCache.clearAnalyzeCache(file)
        ActionCache.clear(file, "analyze_full_document")
      elseif cache_key == "_summary_cache" then
        ActionCache.clearSummaryCache(file)
        ActionCache.clear(file, "summarize_full_document")
      else
        -- Section X-Ray or other generic key: clear directly
        ActionCache.clear(file, cache_key)
      end
      -- Invalidate file browser row cache so deleted artifacts don't reappear
      self._file_dialog_row_cache = { file = nil, rows = nil }
      UIManager:show(Notification:new{
        text = keep_versions and _("X-Ray deleted — archived versions kept")
          or T(_("%1 deleted"), cache_name),
        timeout = 2,
      })
    end

    -- Summary and Analyze get regenerate buttons when book is open
    if cache_key == "_summary_cache" and self.ui and self.ui.document then
      local self_ref = self
      on_regenerate = function()
        local action = self_ref.action_service:getAction("book", "summarize_full_document")
        if action then
          if self_ref:_checkRequirements(action) then return end
          self_ref._file_dialog_row_cache = { file = nil, rows = nil }
          self_ref:_executeBookLevelActionDirect(action, "summarize_full_document")
        end
      end
    end
    if cache_key == "_analyze_cache" and self.ui and self.ui.document then
      local self_ref = self
      on_regenerate = function()
        local action = self_ref.action_service:getAction("book", "analyze_full_document")
        if action then
          if self_ref:_checkRequirements(action) then return end
          self_ref._file_dialog_row_cache = { file = nil, rows = nil }
          self_ref:_executeBookLevelActionDirect(action, "analyze_full_document")
        end
      end
    end
  end

  -- For X-Ray (main or section): try structured JSON browser when data is JSON
  local ActionCache = require("koassistant_action_cache")
  local is_section_xray = type(cache_info.key) == "string"
      and cache_info.key:sub(1, #ActionCache.SECTION_XRAY_PREFIX) == ActionCache.SECTION_XRAY_PREFIX
  if cache_info.key == "_xray_cache" or is_section_xray then
    local XrayParser = require("koassistant_xray_parser")
    if XrayParser.isJSON(cache_info.data.result) then
      local parsed = XrayParser.parse(cache_info.data.result)
      if parsed then
        local XrayBrowser = require("koassistant_xray_browser")
        local features = configuration and configuration.features or {}
        local browser_metadata = {
          title = book_title,
          book_author = book_author,
          progress = cache_info.data.full_document and "Complete"
              or (cache_info.data.progress_decimal and
              (math.floor(cache_info.data.progress_decimal * 100 + 0.5) .. "%")),
          model = cache_info.data.model,
          timestamp = cache_info.data.timestamp,
          book_file = cache_info.file or (self.ui and self.ui.document and self.ui.document.file),
          enable_emoji = features.enable_emoji_icons == true,
          cache_metadata = cache_metadata,
          configuration = configuration,
          plugin = self,
          -- Pre-computed display strings for Full View and Info dialog
          source_label = formatCacheSourceLabel(cache_info.data.used_book_text, cache_info.data.source_mode),
          formatted_date = cache_info.data.timestamp and formatDateWithRelative(cache_info.data.timestamp),
          previous_progress = cache_info.data.previous_progress_decimal and
              (math.floor(cache_info.data.previous_progress_decimal * 100 + 0.5) .. "%"),
          progress_decimal = cache_info.data.progress_decimal,
          full_document = cache_info.data.full_document,
          used_reasoning = cache_info.data.used_reasoning,
          web_search_used = cache_info.data.web_search_used,
          merged_from_sections = cache_info.data.merged_from_sections,
          merged_from_books = cache_info.data.merged_from_books,
          merged_from = cache_info.data.merged_from,
          info_popup_text = info_popup_text,
          -- Archived-version view: browser goes read-only (no update/delete rows,
          -- no nested version history), title says "X-Ray Version". Round 24:
          -- the raw entry rides along so the viewer can reach the version's
          -- own options (restore/delete) instead of dead-ending at Info.
          checkpoint = cache_info.checkpoint,
          checkpoint_data = cache_info.checkpoint and cache_info.data or nil,
        }
        -- (Item 46 prev/next rows are computed LAZILY in the browser's
        -- hamburger — every show path gets them, incl. fresh generation)
        -- Add scope metadata for section X-Rays
        if is_section_xray and cache_info.data.scope_label then
          local scope_start = cache_info.data.scope_start_page
          local scope_end = cache_info.data.scope_end_page
          local scope_summary = cache_info.data.scope_page_summary
          -- Reconvert XPointers to current pages if book is open (font-size independence)
          -- Only reconvert when start_xpointer exists (confirms XPointers were stored at generation)
          local doc = self.ui and self.ui.document
          if doc and doc.getPageFromXPointer then
            local start_xp = cache_info.data.scope_start_xpointer
            local end_xp = cache_info.data.scope_end_xpointer
            if start_xp then
              local new_start = doc:getPageFromXPointer(start_xp)
              if new_start then scope_start = new_start end
              if end_xp then
                local new_end = doc:getPageFromXPointer(end_xp)
                if new_end then scope_end = new_end - 1 end  -- XPointer was at next section start
              else
                -- Last section: find last visible page (excluding hidden flows)
                local total = doc.info.number_of_pages or 0
                if doc.hasHiddenFlows and doc:hasHiddenFlows() then
                  for page = total, 1, -1 do
                    if doc:getPageFlow(page) == 0 then
                      scope_end = page
                      break
                    end
                  end
                else
                  scope_end = total
                end
              end
              -- Convert to visible page numbers for display
              local vis_start = doc.getPageNumberInFlow and doc:getPageNumberInFlow(scope_start) or scope_start
              local vis_end = doc.getPageNumberInFlow and doc:getPageNumberInFlow(scope_end) or scope_end
              scope_summary = T(_("pp %1–%2"), vis_start, vis_end)
            end
          end
          browser_metadata.scope = {
            label = cache_info.data.scope_label,
            start_page = scope_start,
            end_page = scope_end,
            page_summary = scope_summary,
            cache_key = cache_info.key,
          }
          browser_metadata.progress = "Complete"
          browser_metadata.full_document = true
        end
        -- Pass ui only when the open book matches the artifact's book
        -- Cross-book viewing (artifact browser) must not use the open book's document
        local browser_ui = self.ui
        if browser_ui and browser_ui.document then
          local open_file = browser_ui.document.file
          local artifact_file = browser_metadata.book_file
          if open_file and artifact_file and open_file ~= artifact_file then
            browser_ui = nil
          end
        end
        XrayBrowser:show(parsed, browser_metadata, browser_ui, on_delete)

        return
      end
    end
  end

  -- Fallback: ChatGPTViewer for legacy markdown caches or non-xray caches
  local inline_prefix = buildInlineIndicators(cache_info.data, configuration)
  local xr_delete_choice = (on_delete and cache_info.key == "_xray_cache" and file)
      and require("koassistant_xray_rows").deleteChoice(file) or nil
  local viewer = ChatGPTViewer:new{
    title = title,
    text = inline_prefix and (inline_prefix .. cache_info.data.result) or cache_info.data.result,
    _cache_content = cache_info.data.result,
    simple_view = true,
    configuration = configuration,
    cache_metadata = cache_metadata,
    cache_type_name = cache_info.name,
    on_regenerate = on_regenerate,
    on_delete = on_delete,
    -- Round 28: the X-Ray owns archived versions — deleting it asks whether
    -- those go too. A2: choice content shared with the browser hamburger
    -- (koassistant_xray_rows.deleteChoice), which also adds the prepared-
    -- checkpoints line this path previously lacked. Every other artifact
    -- keeps the plain confirm.
    delete_options = (xr_delete_choice and xr_delete_choice.two_way) and {
        { text = xr_delete_choice.keep_text, arg = true },
        { text = xr_delete_choice.drop_text, arg = false },
    } or nil,
    delete_title = xr_delete_choice and xr_delete_choice.title or nil,
    _plugin = self,
    _ui = self.ui,
    _info_text = info_popup_text,
    _artifact_file = file,
    _artifact_key = cache_info.key,
    _artifact_book_title = book_title,
    _artifact_book_author = book_author,
    _book_open = (self.ui and self.ui.document ~= nil),
    group_open = (not cache_info.checkpoint and self:_inBookGroup(file))
      and function() self:_showGroupMembersPopup(file, "artifacts") end or nil,
    on_launch_chat = self:_buildLaunchChatCallback(file, book_title, book_author, cache_info.data.result, cache_info.name),
  }
  UIManager:show(viewer)
end

--- Check if text extraction is blocked for an action.
--- Shows an InfoMessage explaining the issue and returns true if blocked.
--- Two blocking conditions: per-action disabled (use_book_text == false) or global setting off.
--- @param action table: Action definition (checks use_book_text flag)
--- @param alternative_text string|nil: Optional suffix appended to the message (e.g., X-Ray suggests Simple)
--- @return boolean: true if blocked (showed popup), false if OK to proceed
--- Check if any declared requirements for this action are unmet.
--- Actions declare requirements via requires = {"book_text", "highlights", ...}.
--- Each requirement checks per-action gate (flag override) then global gate (privacy setting).
--- Shows an error popup identifying which gate is the problem.
--- @param action table: Action definition (checks action.requires array)
--- @return boolean: true if blocked (showed popup), false if OK to proceed
function AskGPT:_checkRequirements(action, target_file)
  if not action.requires then
    return false
  end
  -- Read from configuration.features (updated by updateConfigFromSettings) for consistency
  -- with the sidecar extractor, which also reads from config.features.
  -- This ensures _checkRequirements and extraction always agree on gating decisions.
  local features = configuration and configuration.features or {}
  local hint = action.blocked_hint and ("\n\n" .. action.blocked_hint) or ""

  -- Check if the provider this action dispatches to is trusted (bypasses global privacy gates).
  -- Must match the extraction gate: use the action's pinned provider when set, else the global —
  -- otherwise pre-flight and extraction disagree on trust (audit v0.20.0 finding C4).
  local function isProviderTrusted()
    local provider = action.provider or features.provider
    if not provider then return false end
    for _idx, trusted_id in ipairs(features.trusted_providers or {}) do
      if trusted_id == provider then return true end
    end
    return false
  end

  -- Per-book privacy overrides (Book Settings ▸ Privacy): deny beats trusted,
  -- allow satisfies the global gate only. `target_file` names the action's book
  -- when it is not (or may not be) the open one (file browser, cross-book
  -- artifact regenerate); default = the open book.
  local book_priv = {}
  do
    local pf = target_file or (self.ui and self.ui.document and self.ui.document.file)
    if pf then
      local ok_r, ds = pcall(function()
        return require("koassistant_doc_settings").resolve(pf, self.ui)
      end)
      if ok_r and ds then
        book_priv = require("koassistant_book_settings").effectivePrivacyOverrides(ds)
      end
    end
  end

  for _idx, req in ipairs(action.requires) do
    if req == "book_text" then
      -- Per-action gate: use_book_text explicitly overridden to false?
      if action.use_book_text == false then
        UIManager:show(InfoMessage:new{
          text = _("Text extraction is disabled for this action. Re-enable it in the Action Manager.") .. hint,
        })
        return true
      end
      -- Global gate: text extraction enabled? (trusted providers bypass;
      -- per-book override wins in both directions)
      local bt_allowed = features.enable_book_text_extraction == true or isProviderTrusted()
      if book_priv.book_text ~= nil then bt_allowed = book_priv.book_text end
      if not bt_allowed then
        UIManager:show(InfoMessage:new{
          text = (book_priv.book_text == false
            and _("Text extraction is turned off for this book (Book Settings → Privacy).")
            or _("Text extraction is required to generate this artifact.\n\nEnable it in Settings → Privacy & Data → Text Extraction.")) .. hint,
        })
        return true
      end
    elseif req == "library" then
      -- Per-action gate: use_library explicitly overridden to false?
      if action.use_library == false then
        UIManager:show(InfoMessage:new{
          text = _("Library scanning is disabled for this action. Re-enable it in the Action Manager.") .. hint,
        })
        return true
      end
      -- Global gate: library scanning enabled? (trusted providers bypass)
      -- This is an absolute gate — session folders do NOT bypass it
      if features.enable_library_scanning ~= true and not isProviderTrusted() then
        UIManager:show(InfoMessage:new{
          text = _("Library scanning is required for this action.\n\nEnable it in Settings → Privacy & Data → Allow Library Scanning.") .. hint,
        })
        return true
      end
      -- Folder gate: need permanent folders or session folders
      local has_session = self._session_scan_folders and #self._session_scan_folders > 0
      if not has_session then
        local lib_folders = features.library_scan_folders
        if not lib_folders or #lib_folders == 0 then
          UIManager:show(InfoMessage:new{
            text = _("No scan folders configured.\n\nAdd folders in Settings → Library Settings → Permanent Scan Folders.") .. hint,
          })
          return true
        end
      end
    elseif req == "highlights" then
      -- Per-action gate: are both highlight flags explicitly disabled?
      if not action.use_highlights and not action.use_annotations then
        UIManager:show(InfoMessage:new{
          text = _("This action requires highlight or annotation data, but data access is disabled for this action.\n\nRe-enable in Action Manager (hold the action → Edit).") .. hint,
        })
        return true
      end
      -- Global gate: is any highlight-type sharing enabled? (trusted providers
      -- bypass; per-book override wins in both directions)
      local hl_allowed = features.enable_highlights_sharing == true
        or features.enable_annotations_sharing == true or isProviderTrusted()
      if book_priv.highlights ~= nil then hl_allowed = book_priv.highlights end
      if not hl_allowed then
        UIManager:show(InfoMessage:new{
          text = (book_priv.highlights == false
            and _("Highlights sharing is turned off for this book (Book Settings → Privacy).")
            or _("This action requires access to your highlights or annotations.\n\nEnable sharing in Settings → Privacy & Data.")) .. hint,
        })
        return true
      end
    end
  end
  return false
end

--- Show a popup for incremental actions that have an existing cached result.
--- Offers "View" (opens cached result) or "Update" (re-runs the action incrementally).
--- Called from executeBookLevelAction(), book chat input, and file browser for actions with use_response_caching.
--- @param action table: The action definition
--- @param action_id string: The action ID
--- @param on_update function: Callback to execute the action (update/re-run)
--- @param opts table|nil: Optional {file, book_title, book_author} fallback for closed-book contexts
--- Consent for CLOSED-book generation runs of source_selection actions
--- (consolidation Q4, 2026-08-16). Open books route through the unified scope
--- popup whose Run button owns this ask (C3); a closed book has no scope
--- popup — New/Regenerate there covers the whole book from AI knowledge — so
--- under spoiler protection it asks once before running. Re-homes the
--- 2026-08-15 file-browser consent, which sat in an unreachable arm and never
--- fired. Covers all three closed-book dispatch points: the cache popup's
--- Update/Regenerate, its no-cache fallthrough, and the artifact viewer's
--- Regenerate.
function AskGPT:_confirmClosedBookSpoilerRun(action, file, run_fn)
  if not (action and action.source_selection and file) then return run_fn() end
  local SafeDocSettings = require("koassistant_doc_settings")
  if self.ui and self.ui.document
      and SafeDocSettings.samePath(self.ui.document.file, file) then
    return run_fn()  -- open book: the scope popup owns consent
  end
  local BookSettings = require("koassistant_book_settings")
  local sp_ds = SafeDocSettings.resolve(file, self.ui)
  local sp_feats = self.settings:readSetting("features") or {}
  -- resolveSpoilerFree already stands down for research mode and books marked
  -- finished; the progress check below covers read-to-the-end-but-unmarked
  if not BookSettings.resolveSpoilerFree(sp_ds, sp_feats) then return run_fn() end
  local pf = sp_ds and tonumber(sp_ds:readSetting("percent_finished")) or 0
  if pf >= 0.995 then return run_fn() end
  local ConfirmBox = require("ui/widget/confirmbox")
  UIManager:show(ConfirmBox:new{
    text = _("Spoiler protection is on for this book. This covers the whole book, including parts you haven't read yet. Continue?"),
    ok_text = _("Run"),
    ok_callback = run_fn,
  })
end

function AskGPT:showCacheActionPopup(action, action_id, on_update, opts)
  local file = self.ui and self.ui.document and self.ui.document.file
      or (opts and opts.file)
  if not file then
    on_update()
    return
  end

  local ActionCache = require("koassistant_action_cache")
  local cached = ActionCache.get(file, action_id)

  -- X-Ray actions: always route to scope popup (handles no-cache and cached scenarios)
  if action.cache_as_xray then
    self:_showXrayScopePopup(action, action_id, on_update, cached, opts)
    return
  end

  -- Analyze Notes: route to scope popup for "to %" / "complete" options
  if action_id == "analyze_highlights" then
    self:_showAnalyzeNotesScopePopup(action, action_id, on_update, cached, opts)
    return
  end

  -- Fallback for dual-cached actions: check document cache for migration
  -- (existing users may have document-level cache but no per-action cache)
  if not cached or not cached.result then
    if action.cache_as_summary then
      cached = ActionCache.getSummaryCache(file)
    elseif action.cache_as_analyze then
      cached = ActionCache.getAnalyzeCache(file)
    end
  end

  if not cached or not cached.result then
    -- Check if action supports sections and book is open with TOC
    local section_prefix = ActionCache.getSectionPrefix(action_id)
    local has_toc = section_prefix and self.ui and self.ui.document and self.ui.toc
        and self.ui.toc.toc and #self.ui.toc.toc > 0
    if has_toc then
      -- Show scope popup: Generate full document / sections / cancel
      local action_name = action.text or action_id
      local ButtonDialog = require("ui/widget/buttondialog")
      local self_ref = self
      local no_cache_dialog
      local nc_buttons = {}
      -- Generate full document
      table.insert(nc_buttons, {{
        text = T(_("Generate %1"), action_name),
        callback = function()
          UIManager:close(no_cache_dialog)
          if self_ref:_checkRequirements(action) then return end
          on_update()
        end,
      }})
      -- Surface in-range section artifacts
      local doc = self.ui and self.ui.document
      if doc then
        local in_range = ActionCache.findMatchingSections(file, doc, section_prefix)
        for _idx, sec in ipairs(in_range) do
          local page_info = ActionCache.reconvertPageSummary(sec.data, doc)
          local sec_parts = {}
          if page_info and page_info ~= "" then
            table.insert(sec_parts, page_info)
          end
          local sec_rel = formatRelativeTime(sec.data.timestamp)
          if sec_rel ~= "" then
            table.insert(sec_parts, sec_rel)
          end
          local sec_detail = #sec_parts > 0 and " (" .. table.concat(sec_parts, ", ") .. ")" or ""
          local captured_sec = sec
          table.insert(nc_buttons, {{
            text = T(_("View \"%1\""), sec.label) .. sec_detail,
            callback = function()
              UIManager:close(no_cache_dialog)
              self_ref:viewCachedAction(action, action_id, captured_sec.data, {
                file = file,
                section_key = captured_sec.key,
                section_label = captured_sec.label,
              })
            end,
          }})
        end
      end
      -- Existing sections
      local sec_count = ActionCache.getSectionCount(file, section_prefix)
      if sec_count > 0 then
        table.insert(nc_buttons, {{
          text = string.format("%s (%d)", ActionCache.getSectionGroupName(action_id) or action_name, sec_count),
          callback = function()
            UIManager:close(no_cache_dialog)
            self_ref:_showSectionList(action, action_id)
          end,
        }})
      end
      -- Focus on a section
      table.insert(nc_buttons, {{
        text = _("Focus on a section…"),
        callback = function()
          UIManager:close(no_cache_dialog)
          if self_ref:_checkRequirements(action) then return end
          self_ref:_showSectionPicker(action, {
            title = T(_("Select Section for %1"), action_name),
            on_select = function(entry)
              self_ref:_showSectionNameInput(action, action_id, entry)
            end,
          })
        end,
      }})
      table.insert(nc_buttons, {{
        text = _("Cancel"),
        callback = function()
          UIManager:close(no_cache_dialog)
        end,
      }})
      no_cache_dialog = ButtonDialog:new{
        title = action_name,
        buttons = nc_buttons,
      }
      UIManager:show(no_cache_dialog)
    else
      if self:_checkRequirements(action) then return end
      self:_confirmClosedBookSpoilerRun(action, file, on_update)
    end
    return
  end

  local action_name = action.text or action_id

  -- View detail: cached progress + relative time, e.g. "View X-Ray (29%, today)"
  -- (percent always when tracked — A4 parity with the Book Hub rows)
  local view_detail = ""
  if cached.progress_decimal or cached.timestamp then
    local parts = {}
    if cached.progress_decimal then
      table.insert(parts, math.floor(cached.progress_decimal * 100 + 0.5) .. "%")
    end
    local rel_time = formatRelativeTime(cached.timestamp)
    if rel_time ~= "" then
      table.insert(parts, rel_time)
    end
    if #parts > 0 then
      view_detail = " (" .. table.concat(parts, ", ") .. ")"
    end
  end

  -- Determine update vs redo based on progress change (matches 1% threshold in dialogs)
  local update_text
  local cached_progress = cached.progress_decimal or 0
  if self.ui and self.ui.document then
    local ContextExtractor = require("koassistant_context_extractor")
    local extractor = ContextExtractor:new(self.ui)
    local progress = extractor:getReadingProgress()
    if progress.decimal > cached_progress + 0.01 then
      -- Enough new content for incremental update
      update_text = T(_("Update %1"), action_name .. " (" .. T(_("to %1"), progress.formatted) .. ")")
    else
      -- Same position or negligible change
      -- Position-relevant actions: "Redo" (re-run at same position)
      -- Position-irrelevant actions: "Regenerate" (full regen, position doesn't matter)
      if action.use_reading_progress then
        update_text = T(_("Redo %1"), action_name)
      else
        update_text = T(_("Regenerate %1"), action_name)
      end
    end
  else
    if action.use_reading_progress then
      update_text = T(_("Redo %1"), action_name)
    else
      update_text = T(_("Regenerate %1"), action_name)
    end
  end

  local ButtonDialog = require("ui/widget/buttondialog")
  local self_ref = self
  local dialog
  local buttons = {}

  -- View
  table.insert(buttons, {{
    text = T(_("View %1"), action_name .. view_detail),
    callback = function()
      UIManager:close(dialog)
      self_ref:viewCachedAction(action, action_id, cached, {
        file = file,
        book_title = opts and opts.book_title,
        book_author = opts and opts.book_author,
      })
    end,
  }})

  -- Surface in-range section artifacts
  local section_prefix = ActionCache.getSectionPrefix(action_id)
  local doc = self.ui and self.ui.document
  if section_prefix and file and doc then
    local in_range = ActionCache.findMatchingSections(file, doc, section_prefix)
    for _idx, sec in ipairs(in_range) do
      local page_info = ActionCache.reconvertPageSummary(sec.data, doc)
      local sec_parts = {}
      if page_info and page_info ~= "" then
        table.insert(sec_parts, page_info)
      end
      local sec_rel = formatRelativeTime(sec.data.timestamp)
      if sec_rel ~= "" then
        table.insert(sec_parts, sec_rel)
      end
      local sec_detail = #sec_parts > 0 and " (" .. table.concat(sec_parts, ", ") .. ")" or ""
      local captured_sec = sec
      table.insert(buttons, {{
        text = T(_("View \"%1\""), sec.label) .. sec_detail,
        callback = function()
          UIManager:close(dialog)
          self_ref:viewCachedAction(action, action_id, captured_sec.data, {
            section_key = captured_sec.key,
            section_label = captured_sec.label,
          })
        end,
      }})
    end
  end

  -- Update/Regenerate
  table.insert(buttons, {{
    text = update_text,
    callback = function()
      UIManager:close(dialog)
      if self_ref:_checkRequirements(action) then return end
      self_ref:_confirmClosedBookSpoilerRun(action, file, on_update)
    end,
  }})
  if section_prefix and self.ui and self.ui.document and self.ui.toc
      and self.ui.toc.toc and #self.ui.toc.toc > 0 then
    local sec_count = ActionCache.getSectionCount(file, section_prefix)
    if sec_count > 0 then
      table.insert(buttons, {{
        text = string.format("%s (%d)", ActionCache.getSectionGroupName(action_id) or action_name, sec_count),
        callback = function()
          UIManager:close(dialog)
          self_ref:_showSectionList(action, action_id)
        end,
      }})
    end
    table.insert(buttons, {{
      text = _("Focus on a section…"),
      callback = function()
        UIManager:close(dialog)
        if self_ref:_checkRequirements(action) then return end
        self_ref:_showSectionPicker(action, {
          title = T(_("Select Section for %1"), action_name),
          on_select = function(entry)
            self_ref:_showSectionNameInput(action, action_id, entry)
          end,
        })
      end,
    }})
  end

  -- Cancel
  table.insert(buttons, {{
    text = _("Cancel"),
    callback = function()
      UIManager:close(dialog)
    end,
  }})

  dialog = ButtonDialog:new{
    title = action_name .. view_detail,
    buttons = buttons,
  }
  UIManager:show(dialog)
end

--- Show Analyze Notes scope popup: choose between "to %" (spoiler guardrails) or "complete" (no restrictions).
--- Analyze Notes is highlights-based (pseudo-update): all highlights are sent regardless of position,
--- but the prompt instructs "do not spoil beyond X%." Complete mode sets progress to 100%.
--- @param action table: The action definition
--- @param action_id string: The action ID
--- @param on_update function: Callback to execute normal (to reading position) action
--- @param cached_entry table|nil: Existing cached entry, or nil if no cache
function AskGPT:_showAnalyzeNotesScopePopup(action, action_id, on_update, cached_entry, opts)
  local action_name = action.text or action_id
  local ButtonDialog = require("ui/widget/buttondialog")
  local self_ref = self

  -- File browser context: target file differs from open book (or no book open)
  local target_file = opts and opts.file
  local is_file_browser = target_file and (not self.ui or not self.ui.document or self.ui.document.file ~= target_file)

  -- Get current reading progress
  local current_progress
  if not is_file_browser and self.ui and self.ui.document then
    local ContextExtractor = require("koassistant_context_extractor")
    local extractor = ContextExtractor:new(self.ui)
    current_progress = extractor:getReadingProgress()
  elseif is_file_browser then
    local ContextExtractor = require("koassistant_context_extractor")
    local sidecar = ContextExtractor.readSidecarProgress(target_file)
    if sidecar and sidecar.decimal > 0 then
      current_progress = { decimal = sidecar.decimal, formatted = sidecar.formatted }
    end
  end

  local dialog
  local buttons = {}

  if not cached_entry or not cached_entry.result then
    -- No cache: Generate (to X%) / Generate (complete) / Cancel
    if self:_checkRequirements(action) then return end

    -- "to X%" only when not already at ~100%
    if current_progress and current_progress.decimal < 0.995 then
      table.insert(buttons, {{
        text = T(_("Generate %1 (to %2)"), action_name, current_progress.formatted),
        callback = function()
          UIManager:close(dialog)
          on_update()
        end,
      }})
    end
    table.insert(buttons, {{
      text = T(_("Generate %1 (complete)"), action_name),
      callback = function()
        UIManager:close(dialog)
        if is_file_browser then
          on_update({ complete_analysis = true })
        else
          self_ref:_executeBookLevelActionDirect(action, action_id, { complete_analysis = true })
        end
      end,
    }})
    table.insert(buttons, {{
      text = _("Cancel"),
      callback = function()
        UIManager:close(dialog)
      end,
    }})

    dialog = ButtonDialog:new{
      title = action_name,
      buttons = buttons,
    }
  else
    -- Cache exists: View / Update-or-Redo (to X%) / Redo (complete) / Cancel
    local view_detail = ""
    local parts = {}
    if cached_entry.intro then
      table.insert(parts, _("introduction"))
    elseif cached_entry.progress_decimal then
      table.insert(parts, math.floor(cached_entry.progress_decimal * 100 + 0.5) .. "%")
    end
    local rel_time = formatRelativeTime(cached_entry.timestamp)
    if rel_time ~= "" then
      table.insert(parts, rel_time)
    end
    if #parts > 0 then
      view_detail = " (" .. table.concat(parts, ", ") .. ")"
    end

    -- View
    table.insert(buttons, {{
      text = T(_("View %1"), action_name .. view_detail),
      callback = function()
        UIManager:close(dialog)
        self_ref:viewCachedAction(action, action_id, cached_entry)
      end,
    }})

    -- Update/Redo (to X%) — skip if already at ~100% (redundant with "complete")
    if current_progress and current_progress.decimal < 0.995 then
      local cached_progress = cached_entry.progress_decimal or 0
      local update_text
      if current_progress.decimal > cached_progress + 0.01 then
        update_text = T(_("Update %1 (to %2)"), action_name, current_progress.formatted)
      else
        update_text = T(_("Redo %1 (to %2)"), action_name, current_progress.formatted)
      end
      table.insert(buttons, {{
        text = update_text,
        callback = function()
          UIManager:close(dialog)
          if self_ref:_checkRequirements(action) then return end
          on_update()
        end,
      }})
    end

    -- Redo (complete) — always available
    table.insert(buttons, {{
      text = T(_("Redo %1 (complete)"), action_name),
      callback = function()
        UIManager:close(dialog)
        if self_ref:_checkRequirements(action) then return end
        if is_file_browser then
          on_update({ complete_analysis = true })
        else
          self_ref:_executeBookLevelActionDirect(action, action_id, { complete_analysis = true })
        end
      end,
    }})

    table.insert(buttons, {{
      text = _("Cancel"),
      callback = function()
        UIManager:close(dialog)
      end,
    }})

    dialog = ButtonDialog:new{
      title = action_name .. view_detail,
      buttons = buttons,
    }
  end

  UIManager:show(dialog)
end

--- Show unified action popup combining scope (full document / section) and source
--- (extract text / use summary / AI knowledge) selection in a single dialog.
--- Radio buttons via bullet prefixes; state changes rebuild the dialog.
--- @param action table: The action definition
--- @param action_id string: The action ID
--- @param opts table: { on_execute = function(state), for_highlight = boolean }
---   state = { source = "full_text"|"summary"|"ai_knowledge",
---             scope = "full"|"section"|"read_so_far"|"chapter"|"chapter_so_far"|"from_section"|"range",
---             section_entry = table|nil, section_label = string|nil }
---   scope "read_so_far" (whole-doc actions, mid-read) routes through _executeSectionAction as a
---   synthetic page-1→current-page section; source is full_text (extract read text) or ai_knowledge
---   (no text, spoiler boundary via the framing instruction — like recap); summary doesn't apply.
---   scope "chapter" (flexible scope phase 1; QUIZ-ONLY) is an auto-filled section pick — the
---   current chapter at the quiz-level resolution fills section_entry/section_label and behaves
---   exactly like scope "section" (section-summary options included, no picker/name input).
---   scope "chapter_so_far" (QUIZ-ONLY) and "from_section" (all whole-doc + to-position actions;
---   TOC pick → current position, pick in section_entry) route like read_so_far with so-far
---   framing; summary doesn't apply to those two.
function AskGPT:_showUnifiedActionPopup(action, action_id, opts)
  local action_name = action.text or action_id
  local ActionCache = require("koassistant_action_cache")
  local self_ref = self

  -- Determine if scope row should be shown
  local section_prefix = ActionCache.getSectionPrefix(action_id)
  local toc_available = self.ui and self.ui.document
      and self.ui.toc and self.ui.toc.toc and #self.ui.toc.toc > 0
  -- Show scope for: book actions with section prefix + TOC, highlight actions with TOC,
  -- or source_selection actions without sections (grayed scope teaches the concept)
  local show_scope = toc_available and (section_prefix or opts.for_highlight or action.source_selection)
  -- Must be boolean (not nil) — nil won't override CheckButton's default enabled=true
  local scope_sections_enabled = section_prefix ~= nil or opts.for_highlight == true

  -- Check text extraction availability
  -- Trust against the effective dispatch provider (pinned action provider, else global) so this
  -- popup agrees with the extraction gate (audit v0.20.0 finding C4).
  local features = configuration and configuration.features or {}
  local text_extraction_enabled = features.enable_book_text_extraction == true
  if not text_extraction_enabled and features.trusted_providers then
    local provider = action.provider or features.provider or ""
    for _idx, tp in ipairs(features.trusted_providers) do
      if tp == provider then
        text_extraction_enabled = true
        break
      end
    end
  end
  -- Per-book privacy override (Book Settings ▸ Privacy) — the source picker must
  -- agree with the extraction gate: deny beats trusted, allow satisfies the
  -- global gate ("Full text" usable when this book allows it).
  if self.ui and self.ui.doc_settings then
    local bt_ov = require("koassistant_book_settings")
      .effectivePrivacyOverrides(self.ui.doc_settings).book_text
    if bt_ov ~= nil then text_extraction_enabled = bt_ov end
  end

  -- Check if action requires book_text (constrains source to text extraction only)
  local requires_book_text = false
  if action.requires then
    for _idx, req in ipairs(action.requires) do
      if req == "book_text" then
        requires_book_text = true
        break
      end
    end
  end

  -- "Up to current position" scope: only for whole-document actions (those whose "Full document"
  -- extracts the ENTIRE book). Actions that extract to the reading position already
  -- ({book_text_section}/{incremental_book_text_section}, e.g. recap/xray) get this for free via
  -- their "Full document" option, so adding it there would be redundant. Detected from placeholders
  -- so custom actions are covered too.
  local prompt_text = action.prompt or ""
  local is_whole_doc = (prompt_text:find("{full_document_section}", 1, true)
        or prompt_text:find("{document_context_section}", 1, true))
      and not (prompt_text:find("{book_text_section}", 1, true)
        or prompt_text:find("{incremental_book_text_section}", 1, true))
  local reading_progress
  if self.ui and self.ui.document then
    local ContextExtractor = require("koassistant_context_extractor")
    reading_progress = ContextExtractor:new(self.ui):getReadingProgress()
  end
  -- Gate: whole-doc action + open book + meaningfully mid-read
  -- (needs a DISPLAYED percent of at least 1 — `decimal > 0` let page 1 of a long book offer
  -- "Up to current position (0%)" and extract an empty cover-page span, device 2026-08-12;
  -- near 100% it collapses to "Full document"). Visible whether or not text
  -- extraction is on: with it, read-so-far uses the extracted text (hard spoiler boundary); without
  -- it, it falls back to AI knowledge bounded by the spoiler instruction (soft boundary, like recap).
  -- requires_book_text actions still need extraction (they're blocked otherwise).
  -- Highlight actions included since consolidation P5 (2026-08-16, maintainer yes):
  -- the old `not opts.for_highlight` exclusion was deliberate but the extraction
  -- bound works identically, and it also unlocks the spoiler pre-select below +
  -- the From-section/section rows for in-context actions.
  local read_so_far_available = is_whole_doc
      and self.ui and self.ui.document
      and (text_extraction_enabled or not requires_book_text)
      and reading_progress and reading_progress.percent >= 1 and reading_progress.decimal < 0.98
      and true or false
  -- Show the scope section even without a TOC when read-so-far is the reason (it needs no sections).
  if read_so_far_available then show_scope = true end

  -- Chapter/section scope additions (flexible_scope_plan.md phase 1, revised 2026-07-16):
  -- everything is packed into ONE table local to spare closure upvalues (LuaJIT 60 cap).
  --   * "From section… (to current position)" — generic explicit-start "so far" for whole-doc
  --     AND to-position (recap family) actions: the user picks the start from the TOC, so no
  --     chapter-level resolution is involved. Spoiler-safe by construction (end = position).
  --   * "Current chapter (so far)" presets — QUIZ-ONLY (maintainer 2026-07-16): the chapter
  --     level setting exists for the quiz trigger, and the manual quiz presets share its
  --     resolution and cache labels (the trigger's existing-quiz check dedupes manual runs).
  --     Every other action states its scope explicitly (Pick section… / From section…), so
  --     quiz chapter resolution never leaks into non-quiz scope UI.
  local is_to_position = not is_whole_doc
      and (prompt_text:find("{book_text_section}", 1, true)
        or prompt_text:find("{incremental_book_text_section}", 1, true))
      and true or false
  local chapter = { presets = {} }
  -- Highlight actions included since consolidation P5 (with the read-so-far
  -- lift): From-section/range picks ride the same _highlight_section_scope
  -- page-range transient as their existing "Pick section" scope.
  if (is_whole_doc or is_to_position)
      and self.ui and self.ui.document
      and (text_extraction_enabled or not requires_book_text) then
    chapter.current_page = (self.ui.view and self.ui.view.state and self.ui.view.state.page) or 1
    chapter.from_section_available = toc_available and chapter.current_page > 1 and true or false
    -- "Pick section range…" (phase 4): two TOC picks, start→end. Needs only a TOC —
    -- no reading-position requirement. Recap is excluded (maintainer 2026-08-11:
    -- arbitrary spans make no sense for a catch-up action — "From section…" IS
    -- the recap shape and stays).
    chapter.range_available = toc_available and action.id ~= "recap" and true or false
    if is_whole_doc and action.interactive_quiz then
      local info = self:_currentChapterInfo()
      if info then
        chapter.info = info
        chapter.presets = require("koassistant_scope_resolver").chapterPresets({
          chapter = info,
          current_page = info.current_page,
          -- Per-book > global posture; the session Spoiler chip never applies to
          -- predefined actions (buildUnifiedRequestConfig clears it for action ~= nil).
          spoiler_free = require("koassistant_book_settings").resolveSpoilerFree(
              self.ui.doc_settings, features),
        })
      end
    end
  end
  if chapter.presets.chapter or chapter.presets.chapter_so_far
      or chapter.from_section_available or chapter.range_available then
    show_scope = true
  end

  -- Smart retrieval (D3 — tools_ux_plan.md §4): 4th source for pilot actions
  -- (action.smart_retrieval), highlight path only — the gather-before-action wiring
  -- lives in the input-dialog dispatch (runActionWithSource); book-level dispatch has
  -- no gather step. The row always shows for those actions; ineligible sessions get it
  -- grayed with the reason (maintainer 2026-07-11 — matches the Extract text row's
  -- pattern). Eligibility is fixed for the popup's lifetime, so compute it once here —
  -- it also drives the default pick below.
  local smart_row_shown = action.smart_retrieval == true
      and opts.for_highlight == true and not requires_book_text
  local smart_eligible, smart_block_reason
  if smart_row_shown then
    -- Master switch (2026-07-11): posture "off" gates ALL tool use, incl. this row.
    smart_eligible, smart_block_reason =
        require("koassistant_book_tool_runner").smartRetrievalAllowed(configuration, self.ui)
  end

  -- State (persists across rebuilds)
  -- Default source: smart retrieval when offered and eligible (maintainer 2026-07-11 —
  -- targeted passages beat a full-text dump for highlight-anchored questions; full text
  -- stays one tap away), else the pre-D3 rule.
  -- Default scope: under spoiler protection, pre-select "Up to current position"
  -- when that row exists (maintainer 2026-08-11) — the popup should not default
  -- to a scope covering unread text; the C3 consent confirm then only fires when
  -- the user ACTIVELY picks a spoiler-crossing scope. (read_so_far_available
  -- implies an open book, so doc_settings is resolvable here.)
  local state = {
    scope = (read_so_far_available
        and require("koassistant_book_settings").resolveSpoilerFree(self.ui.doc_settings, features)
        and "read_so_far") or "full",
    source = (requires_book_text and "full_text")
        -- Dialog launches pass session_tools (the session Tools chip); false skips the
        -- smart-retrieval DEFAULT (row stays selectable). Direct entries pass nothing.
        or (smart_row_shown and smart_eligible and opts.session_tools ~= false and "smart_retrieval")
        or (text_extraction_enabled and "full_text" or "ai_knowledge"),
    section_entry = nil,
    section_label = nil,
  }

  local current_dialog
  -- Height of the first build, used to anchor the popup's top across rebuilds (see buildAndShow):
  -- it opens centered, then later selections keep that top so the dialog grows downward instead of
  -- re-centering (which moves content vertically and reads as a jarring jump).
  local first_frame_h

  -- Returns: (has_any, timestamp, is_section_match, has_full_doc, full_doc_timestamp)
  -- When scope=section (or "chapter" — an auto-filled section pick): checks both section
  -- and full doc summaries independently
  local function getSummaryAvailable()
    local file = self_ref.ui and self_ref.ui.document and self_ref.ui.document.file
    if not file then return false end
    if (state.scope == "section" or state.scope == "chapter") and state.section_entry then
      -- Check for matching section summary
      local doc = self_ref.ui and self_ref.ui.document
      local match = ActionCache.findBestSectionForScope(
          file, doc, ActionCache.SECTION_PREFIXES.summary,
          state.section_entry.start_page, state.section_entry.end_page)
      -- Also check full document summary (independent)
      local full_doc = ActionCache.getSummaryCache(file)
      local has_section = match and match.data and match.data.result and match.data.result ~= ""
      local has_full = full_doc and full_doc.result and full_doc.result ~= ""
      if has_section then
        return true, match.data.timestamp, true, has_full, has_full and full_doc.timestamp
      elseif has_full then
        return true, full_doc.timestamp, false, true, full_doc.timestamp
      else
        return false, nil, nil, false, nil
      end
    else
      local summary = ActionCache.getSummaryCache(file)
      if summary and summary.result and summary.result ~= "" then
        return true, summary.timestamp, false
      end
      return false
    end
  end

  local function buildAndShow()
    local has_summary, summary_timestamp, is_section_summary, has_full_doc, full_doc_timestamp = getSummaryAvailable()
    local Blitbuffer = require("ffi/blitbuffer")
    local ButtonTable = require("ui/widget/buttontable")
    local CenterContainer = require("ui/widget/container/centercontainer")
    local Font = require("ui/font")
    local FrameContainer = require("ui/widget/container/framecontainer")
    local Geom = require("ui/geometry")
    local GestureRange = require("ui/gesturerange")
    local MovableContainer = require("ui/widget/container/movablecontainer")
    local RadioButtonTable = require("ui/widget/radiobuttontable")
    local Size = require("ui/size")
    local TextWidget = require("ui/widget/textwidget")
    local TitleBar = require("ui/widget/titlebar")
    local VerticalGroup = require("ui/widget/verticalgroup")
    local VerticalSpan = require("ui/widget/verticalspan")

    local screen_width = Screen:getWidth()
    local screen_height = Screen:getHeight()
    local dialog_width = math.floor(math.min(screen_width, screen_height) * 0.8)
    local content_width = dialog_width - 2 * Size.padding.large
    local label_face = Font:getFace("cfont", 18)
    local radio_face = Font:getFace("cfont", 20)
    local info_face = Font:getFace("cfont", 16)

    local TextBoxWidget = require("ui/widget/textboxwidget")
    local vgroup = VerticalGroup:new{ align = "left" }

    -- C3 (spoiler_posture_plan.md §4.2): running a scope that covers unread text
    -- under spoiler protection is CONSENT, confirmed once — at Run, on the
    -- committed scope (see the Run callback). Not at pick time: "Full document"
    -- is the popup's pre-selected default, so the plain open→Run path never
    -- touches a radio row. Cancel returns to the popup unchanged. Declared at
    -- this level because the Run button lives outside the scope-section block.
    local scope_spoiler_free = require("koassistant_book_settings").resolveSpoilerFree(
        self_ref.ui.doc_settings, features)
    local function confirmUnreadScope(covers_unread, proceed)
      if scope_spoiler_free and covers_unread then
        local ConfirmBox = require("ui/widget/confirmbox")
        UIManager:show(ConfirmBox:new{
          text = _("This covers parts you haven't read yet."),
          ok_text = _("Continue"),
          ok_callback = proceed,
          cancel_callback = function() buildAndShow() end,
        })
      else
        proceed()
      end
    end

    -- Title: show progress for position-relevant actions (e.g. "Recap (to 55%)")
    local popup_title = action_name
    if action.use_reading_progress and self_ref.ui and self_ref.ui.document then
      local ContextExtractor = require("koassistant_context_extractor")
      local extractor = ContextExtractor:new(self_ref.ui)
      local progress = extractor:getReadingProgress()
      if progress.decimal < 1.0 then
        popup_title = action_name .. " (" .. T(_("to %1"), progress.formatted) .. ")"
      end
    end

    -- Title bar
    local title_bar = TitleBar:new{
      width = dialog_width,
      align = "left",
      with_bottom_line = true,
      title = popup_title,
      title_shrink_font_to_fit = true,
      close_callback = function()
        UIManager:close(current_dialog)
      end,
    }

    -- Helper: section label
    local function addLabel(text)
      table.insert(vgroup, VerticalSpan:new{ width = Size.padding.large })
      table.insert(vgroup, TextWidget:new{
        text = text,
        face = label_face,
        bold = true,
        fgcolor = Blitbuffer.COLOR_DARK_GRAY,
      })
      table.insert(vgroup, VerticalSpan:new{ width = Size.padding.small })
    end

    -- === Scope section ===
    if show_scope then
      addLabel(_("Scope"))

      -- With read-so-far or chapter presets present, stack the choices vertically; otherwise
      -- keep the original two-column row (no layout churn for actions without new options).
      local scope_radio_buttons
      if read_so_far_available or chapter.presets.chapter or chapter.presets.chapter_so_far
          or chapter.from_section_available or chapter.range_available then
        -- read_so_far can show the scope row without a TOC; keep "Pick section" explicitly disabled
        -- (false, not nil) when there are no sections so the callback's `== false` guard catches it.
        local pick_section_enabled = scope_sections_enabled and toc_available and true or false
        -- To-position actions ({book_text_section}, e.g. recap): their "full" extraction already
        -- stops at the reading position — label the row honestly (maintainer 2026-07-16; the old
        -- "Full document" label read as if recap covered unread text / lacked a to-position scope).
        local full_scope_text = _("Full document")
        if is_to_position and reading_progress then
          full_scope_text = T(_("Up to current position (%1)"), reading_progress.formatted)
        end
        scope_radio_buttons = {
          { { text = full_scope_text, provider = "full", checked = state.scope == "full" } },
        }
        if read_so_far_available then
          table.insert(scope_radio_buttons,
            { { text = T(_("Up to current position (%1)"), reading_progress.formatted), provider = "read_so_far", checked = state.scope == "read_so_far" } })
        end
        -- Chapter preset rows stay plain (maintainer 2026-07-16: less busy); the resolved
        -- chapter name appears in the gray info line below once selected, like a section pick.
        if chapter.presets.chapter then
          table.insert(scope_radio_buttons,
            { { text = _("Current chapter"), provider = "chapter", checked = state.scope == "chapter" } })
        end
        if chapter.presets.chapter_so_far then
          table.insert(scope_radio_buttons,
            { { text = _("Current chapter so far"), provider = "chapter_so_far", checked = state.scope == "chapter_so_far" } })
        end
        if chapter.from_section_available then
          table.insert(scope_radio_buttons,
            { { text = T(_("From section… (to %1)"), reading_progress.formatted), provider = "from_section", checked = state.scope == "from_section" } })
        end
        if chapter.range_available then
          table.insert(scope_radio_buttons,
            { { text = _("Pick section range…"), provider = "range", checked = state.scope == "range" } })
        end
        table.insert(scope_radio_buttons,
          { { text = _("Pick section…"), provider = "section", checked = state.scope == "section", enabled = pick_section_enabled } })
      else
        local full_scope_text = _("Full document")
        if is_to_position and reading_progress then
          full_scope_text = T(_("Up to current position (%1)"), reading_progress.formatted)
        end
        scope_radio_buttons = {
          {
            { text = full_scope_text, provider = "full", checked = state.scope == "full" },
            { text = _("Pick section…"), provider = "section", checked = state.scope == "section", enabled = scope_sections_enabled },
          },
        }
      end
      local scope_table = RadioButtonTable:new{
        radio_buttons = scope_radio_buttons,
        width = content_width,
        no_sep = true,
        sep_width = 0,
        face = radio_face,
        show_parent = self_ref,
        parent = self_ref,
        button_select_callback = function(btn_entry)
          if btn_entry.enabled == false then return end
          if btn_entry.provider == "full" then
            if state.scope == "full" then return end
            UIManager:close(current_dialog)
            state.scope = "full"
            state.section_entry = nil
            state.section_label = nil
            if state.source == "section_summary" then
              -- "section_summary" not valid for full scope — try "summary" if action supports it
              if action.use_summary_cache == true and (getSummaryAvailable() or text_extraction_enabled) then
                state.source = "summary"
              else
                state.source = text_extraction_enabled and "full_text" or "ai_knowledge"
              end
            elseif state.source == "summary" and not getSummaryAvailable() then
              state.source = text_extraction_enabled and "full_text" or "ai_knowledge"
            end
            buildAndShow()
          elseif btn_entry.provider == "read_so_far" then
            if state.scope == "read_so_far" then return end
            UIManager:close(current_dialog)
            state.scope = "read_so_far"
            state.section_entry = nil
            state.section_label = nil
            -- Default to extracted text when available, else AI knowledge (summary never applies —
            -- a whole-doc summary isn't chronological).
            state.source = text_extraction_enabled and "full_text" or "ai_knowledge"
            buildAndShow()
          elseif btn_entry.provider == "chapter" then
            if state.scope == "chapter" then return end
            UIManager:close(current_dialog)
            -- "Current chapter" = an auto-filled section pick (maintainer 2026-07-16): same
            -- state, same source options (section summaries included), same Run path — only
            -- the picker and the name input are skipped (label = the chapter's title).
            state.scope = "chapter"
            state.section_entry = {
              title = chapter.info.title,
              start_page = chapter.presets.chapter.start_page,
              end_page = chapter.presets.chapter.end_page,
            }
            state.section_label = chapter.info.title
            if state.source == "section_summary" then
              -- Check if the chapter already has a summary (mirrors the section pick)
              local _has, _ts, is_sec = getSummaryAvailable()
              if is_sec then state.source = "summary" end
            elseif state.source == "summary" and not getSummaryAvailable() then
              state.source = text_extraction_enabled and "full_text" or "ai_knowledge"
            end
            buildAndShow()
          elseif btn_entry.provider == "chapter_so_far" then
            if state.scope == "chapter_so_far" then return end
            UIManager:close(current_dialog)
            state.scope = "chapter_so_far"
            state.section_entry = nil
            state.section_label = nil
            -- Extracted text or AI knowledge only (a summary can't be bounded to a mid-chapter
            -- position).
            state.source = text_extraction_enabled and "full_text" or "ai_knowledge"
            buildAndShow()
          elseif btn_entry.provider == "from_section" then
            UIManager:close(current_dialog)
            self_ref:_showSectionPicker(action, {
              title = _("Start from which section?"),
              on_select = function(entry)
                if entry.start_page > chapter.current_page then
                  -- An empty/backwards span; teach rather than filter (hiding later
                  -- sections from the picker would read as missing chapters).
                  UIManager:show(InfoMessage:new{
                    text = _("That section starts after your current position."),
                    timeout = 3,
                  })
                else
                  state.scope = "from_section"
                  state.section_entry = entry
                  local picked_label = entry.title or ""
                  if picked_label == "" then
                    -- Untitled TOC entry: mirror the picker's own display fallback
                    local vis_sp = self_ref.ui.document.getPageNumberInFlow
                        and self_ref.ui.document:getPageNumberInFlow(entry.start_page)
                        or entry.start_page
                    picked_label = T(_("Page %1"), vis_sp)
                  end
                  state.section_label = picked_label
                  state.source = text_extraction_enabled and "full_text" or "ai_knowledge"
                end
                buildAndShow()
              end,
            })
          elseif btn_entry.provider == "range" then
            -- Custom range (phase 4): two sequential TOC picks — start section, then end
            -- section. A span touching unread text gets the C3 consent confirm (the old
            -- policy refused it outright; explicit scope selection is consent now).
            UIManager:close(current_dialog)
            local function rangeSectionLabel(entry)
              local lbl = entry.title or ""
              if lbl == "" then
                local vis_sp = self_ref.ui.document.getPageNumberInFlow
                    and self_ref.ui.document:getPageNumberInFlow(entry.start_page)
                    or entry.start_page
                lbl = T(_("Page %1"), vis_sp)
              end
              return lbl
            end
            self_ref:_showSectionPicker(action, {
              title = _("Range start: which section?"),
              on_select = function(start_entry)
                self_ref:_showSectionPicker(action, {
                  title = _("Range end: which section?"),
                  on_select = function(end_entry)
                    if end_entry.start_page < start_entry.start_page then
                      UIManager:show(InfoMessage:new{
                        text = _("The end section comes before the start section."),
                        timeout = 3,
                      })
                      buildAndShow()
                      return
                    end
                    state.scope = "range"
                    state.section_entry = {
                      start_page = start_entry.start_page,
                      end_page = end_entry.end_page,
                      title = rangeSectionLabel(start_entry) .. " – " .. rangeSectionLabel(end_entry),
                    }
                    state.section_label = state.section_entry.title
                    -- Extracted text or AI knowledge only (no summary matches a
                    -- two-section span).
                    state.source = text_extraction_enabled and "full_text" or "ai_knowledge"
                    buildAndShow()
                  end,
                })
              end,
            })
          elseif btn_entry.provider == "section" then
            UIManager:close(current_dialog)
            self_ref:_showSectionPicker(action, {
              title = T(_("Select Section for %1"), action_name),
              on_select = function(entry)
                if opts.for_highlight then
                  -- Highlight scope: no naming needed, just set the section
                  state.scope = "section"
                  state.section_entry = entry
                  state.section_label = entry.title or ""
                  if state.source == "section_summary" then
                    -- Check if new section already has a summary
                    local _has, _ts, is_sec = getSummaryAvailable()
                    if is_sec then state.source = "summary" end
                  elseif state.source == "summary" and not getSummaryAvailable() then
                    state.source = text_extraction_enabled and "full_text" or "ai_knowledge"
                  end
                  buildAndShow()
                else
                  -- Book scope: name the section now (shows in popup before Run)
                  self_ref:_showSectionNameInput(action, action_id, entry, {
                    on_confirm = function(label)
                      state.scope = "section"
                      state.section_entry = entry
                      state.section_label = label
                      if state.source == "section_summary" then
                        -- Check if new section already has a summary
                        local _has, _ts, is_sec = getSummaryAvailable()
                        if is_sec then state.source = "summary" end
                      elseif state.source == "summary" and not getSummaryAvailable() then
                        state.source = text_extraction_enabled and "full_text" or "ai_knowledge"
                      end
                      buildAndShow()
                    end,
                  })
                end
              end,
            })
          end
        end,
      }
      table.insert(vgroup, scope_table)

      -- Show selected section name or explanation for unavailable sections
      if (state.scope == "section" or state.scope == "chapter" or state.scope == "range")
          and state.section_label then
        table.insert(vgroup, VerticalSpan:new{ width = Size.padding.small })
        table.insert(vgroup, TextBoxWidget:new{
          text = state.section_label,
          face = info_face,
          width = content_width,
          fgcolor = Blitbuffer.COLOR_DARK_GRAY,
        })
      elseif state.scope == "chapter_so_far" and chapter.info then
        table.insert(vgroup, VerticalSpan:new{ width = Size.padding.small })
        table.insert(vgroup, TextBoxWidget:new{
          text = T(_("From \"%1\" to current position"), chapter.info.title),
          face = info_face,
          width = content_width,
          fgcolor = Blitbuffer.COLOR_DARK_GRAY,
        })
      elseif state.scope == "from_section" and state.section_label then
        table.insert(vgroup, VerticalSpan:new{ width = Size.padding.small })
        table.insert(vgroup, TextBoxWidget:new{
          text = T(_("From \"%1\" to current position"), state.section_label),
          face = info_face,
          width = content_width,
          fgcolor = Blitbuffer.COLOR_DARK_GRAY,
        })
      elseif not scope_sections_enabled then
        table.insert(vgroup, VerticalSpan:new{ width = Size.padding.small })
        table.insert(vgroup, TextBoxWidget:new{
          text = _("Sections not available for this action.") .. "\n" .. _("Use KOReader's hidden flows to limit scope."),
          face = info_face,
          width = content_width,
          fgcolor = Blitbuffer.COLOR_DARK_GRAY,
        })
      end
    end

    -- === Source section ===
    addLabel(_("Source"))

    -- Smart retrieval rides the full or up-to-position scope (round 4, maintainer:
    -- scope means SCOPE regardless of source — full searches the whole document,
    -- read-so-far clamps the tool session to the position). Section scopes stay
    -- out: their START bound can't be told to the tools, so the combination would
    -- mislead (deferred by maintainer).
    if state.source == "smart_retrieval" and state.scope ~= "full"
        and state.scope ~= "read_so_far" then
      -- Scope switched to a section scope while smart retrieval was selected — fall back
      state.source = text_extraction_enabled and "full_text" or "ai_knowledge"
    end

    -- Build source radio buttons dynamically (section scope may add extra summary rows)
    local extract_text = text_extraction_enabled
        and _("Extract text")
        or (_("Extract text") .. "  (" .. _("enable in Settings → Privacy") .. ")")
    local supports_summary = action.use_summary_cache == true
    local source_radio_buttons = {}

    -- Row 1: Extract text (always present)
    table.insert(source_radio_buttons, {
      { text = extract_text, provider = "full_text", checked = state.source == "full_text", enabled = text_extraction_enabled },
    })

    -- Summary row(s): varies by scope and availability
    if state.scope == "read_so_far" or state.scope == "chapter_so_far"
        or state.scope == "from_section" or state.scope == "range" then
      -- A whole-document summary isn't chronological, so it can't be bounded to a position, a
      -- start→now span, or a two-section range. ("chapter" is NOT here: it's an auto-filled
      -- section pick and gets the full section-summary options below.) Plain disabled label
      -- keeps the row height stable across scope switches.
      table.insert(source_radio_buttons, {
        { text = _("Use summary"), provider = "summary", checked = false, enabled = false },
      })
    elseif requires_book_text then
      table.insert(source_radio_buttons, {
        { text = _("Use summary") .. "  (" .. _("this action requires text extraction") .. ")", provider = "summary", checked = false, enabled = false },
      })
    elseif not supports_summary then
      table.insert(source_radio_buttons, {
        { text = _("Use summary") .. "  (" .. _("not available for this action") .. ")", provider = "summary", checked = false, enabled = false },
      })
    elseif (state.scope == "section" or state.scope == "chapter") and state.section_entry then
      -- Section scope (incl. "chapter" auto-filled pick): show section-specific summary options
      if is_section_summary then
        -- Matching section summary exists
        local age = summary_timestamp and formatRelativeTime(summary_timestamp) or ""
        local label = _("Use section summary")
        if age ~= "" then label = label .. "  (" .. age .. ")" end
        table.insert(source_radio_buttons, {
          { text = label, provider = "summary", checked = state.source == "summary", enabled = true },
        })
      else
        -- No matching section summary
        if has_full_doc then
          -- Full doc summary exists as fallback
          local age = full_doc_timestamp and formatRelativeTime(full_doc_timestamp) or ""
          local label = _("Use document summary")
          if age ~= "" then label = label .. "  (" .. age .. ")" end
          table.insert(source_radio_buttons, {
            { text = label, provider = "summary", checked = state.source == "summary", enabled = true },
          })
        end
        if text_extraction_enabled then
          -- Offer to generate section summary
          table.insert(source_radio_buttons, {
            { text = _("Generate section summary") .. " (" .. _("one-time, reusable by other actions") .. ")", provider = "section_summary", checked = state.source == "section_summary", enabled = true },
          })
        end
        if not has_full_doc and not text_extraction_enabled then
          -- No summary available and can't generate
          table.insert(source_radio_buttons, {
            { text = _("Use summary") .. "  (" .. _("enable text extraction first") .. ")", provider = "summary", checked = false, enabled = false },
          })
        end
      end
    else
      -- Full scope: existing logic
      if has_summary then
        local age = summary_timestamp and formatRelativeTime(summary_timestamp) or ""
        local summary_label = _("Use existing summary")
        if age ~= "" then summary_label = summary_label .. "  (" .. age .. ")" end
        table.insert(source_radio_buttons, {
          { text = summary_label, provider = "summary", checked = state.source == "summary", enabled = true },
        })
      elseif text_extraction_enabled then
        table.insert(source_radio_buttons, {
          { text = _("Generate summary") .. " (" .. _("one-time, reusable by other actions") .. ")", provider = "summary", checked = state.source == "summary", enabled = true },
        })
      else
        table.insert(source_radio_buttons, {
          { text = _("Use summary") .. "  (" .. _("enable text extraction first") .. ")", provider = "summary", checked = false, enabled = false },
        })
      end
    end

    -- Smart retrieval row (between summary and AI knowledge: decreasing text volume).
    -- Always shown for pilot actions; disabled (not hidden) with the reason when the
    -- session can't use it or the scope isn't full — stable popup height, discoverable.
    if smart_row_shown then
      -- Round 4 (maintainer): the SCOPE pick governs the tool session — full =
      -- whole document (the normal Run consent fires under protection, like any
      -- other source), read-so-far = tools clamped to the position. No special
      -- label: scope says what it covers.
      local sr_label = _("Smart retrieval (AI searches the book)")
      local sr_scope_ok = state.scope == "full" or state.scope == "read_so_far"
      local sr_enabled = smart_eligible == true and sr_scope_ok
      local sr_text
      if not smart_eligible then
        if smart_block_reason == "consent" then
          sr_text = sr_label .. "  (" .. _("enable in Settings → Privacy") .. ")"
        else
          sr_text = sr_label .. "  (" .. _("not supported by this provider") .. ")"
        end
      elseif not sr_scope_ok then
        sr_text = sr_label .. "  (" .. _("full or up-to-position only") .. ")"
      else
        sr_text = sr_label
      end
      table.insert(source_radio_buttons, {
        { text = sr_text, provider = "smart_retrieval", checked = state.source == "smart_retrieval", enabled = sr_enabled },
      })
    end

    -- AI knowledge row. For read-so-far this stays enabled (the framing line carries the "nothing
    -- beyond this point" spoiler boundary, same mechanism recap/xray_simple use); only
    -- requires_book_text actions disable it.
    local ai_knowledge_text, ai_knowledge_enabled
    if requires_book_text then
      ai_knowledge_text = _("AI knowledge only") .. "  (" .. _("this action requires text extraction") .. ")"
      ai_knowledge_enabled = false
    else
      ai_knowledge_text = _("AI knowledge only")
      ai_knowledge_enabled = true
    end
    table.insert(source_radio_buttons, {
      { text = ai_knowledge_text, provider = "ai_knowledge", checked = state.source == "ai_knowledge", enabled = ai_knowledge_enabled },
    })

    local source_table = RadioButtonTable:new{
      radio_buttons = source_radio_buttons,
      width = content_width,
      no_sep = true,
      face = radio_face,
      show_parent = self_ref,
      parent = self_ref,
      button_select_callback = function(btn_entry)
        if btn_entry.enabled == false then return end
        if btn_entry.provider == state.source then return end
        UIManager:close(current_dialog)
        state.source = btn_entry.provider
        buildAndShow()
      end,
    }
    table.insert(vgroup, source_table)

    -- Action button (ButtonTable's zero_sep provides the separator line)
    table.insert(vgroup, VerticalSpan:new{ width = Size.padding.default })

    local action_buttons = ButtonTable:new{
      width = content_width,
      buttons = {{
        {
          text = _("Run"),
          callback = function()
            UIManager:close(current_dialog)
            local function continueWithAction()
              if (state.scope == "section" or state.scope == "chapter")
                  and state.section_entry and not opts.for_highlight then
                -- Name already confirmed during scope selection (or auto-filled from the
                -- current chapter — same label the chapter-end quiz trigger uses, so its
                -- existing-quiz check dedupes manual runs) — execute directly
                self_ref:_executeSectionAction(action, action_id, state.section_entry, state.section_label, {
                  source_mode = state.source == "section_summary" and "summary" or state.source,
                })
              elseif state.scope == "read_so_far" and not opts.for_highlight then
                -- Synthetic section scope: page 1 → current page. Reuses the section path (same as
                -- the auto chapter quiz); label/cache key carry the % so positions don't clobber.
                -- source_mode follows the user's pick: "full_text" extracts the read text (hard
                -- boundary); "ai_knowledge" sends no text and relies on the framing line's spoiler
                -- instruction (soft boundary, like recap).
                -- (Highlight actions fall through to on_execute: their bound rides
                -- _highlight_section_scope, not the section-artifact path.)
                local current_page = (self_ref.ui.view and self_ref.ui.view.state
                    and self_ref.ui.view.state.page) or 1
                local rsf_label = T(_("Up to %1"), reading_progress.formatted)
                self_ref:_executeSectionAction(action, action_id,
                  { start_page = 1, end_page = current_page }, rsf_label,
                  { source_mode = state.source, read_so_far = true })
              elseif state.scope == "chapter_so_far" then
                -- Quiz-only preset: current chapter's start → current page, so-far framing.
                -- The label carries the % so successive positions don't clobber each other.
                local range = chapter.presets.chapter_so_far
                self_ref:_executeSectionAction(action, action_id,
                  { start_page = range.start_page, end_page = range.end_page, title = chapter.info.title },
                  T(_("%1 (to %2)"), chapter.info.title, reading_progress.formatted),
                  { source_mode = state.source,
                    section_so_far = { section = chapter.info.title,
                        position = reading_progress.formatted } })
              elseif state.scope == "from_section" and state.section_entry
                  and not opts.for_highlight then
                -- Explicit-start "so far": picked section's start → current position. Same
                -- framing/label treatment as the quiz chapter preset, but the start is the
                -- user's own TOC pick — chapter resolution is not involved.
                local from_label = T(_("%1 (to %2)"), state.section_label, reading_progress.formatted)
                self_ref:_executeSectionAction(action, action_id,
                  { start_page = state.section_entry.start_page, end_page = chapter.current_page,
                    title = state.section_label },
                  from_label,
                  { source_mode = state.source,
                    section_so_far = { section = state.section_label,
                        position = reading_progress.formatted } })
              elseif state.scope == "range" and state.section_entry
                  and not opts.for_highlight then
                -- Custom range (phase 4): rides the plain section path — the composite
                -- "start – end" label is the section name for framing and cache.
                self_ref:_executeSectionAction(action, action_id,
                  state.section_entry, state.section_label,
                  { source_mode = state.source })
              elseif state.scope == "full" and not opts.for_highlight then
                -- Check for existing full-document cache and warn before replacing
                -- Skip for incremental actions (update_prompt) — they handle update/redo downstream
                local aa_file = self_ref.ui and self_ref.ui.document and self_ref.ui.document.file
                local aa_cache = require("koassistant_action_cache")
                local existing = aa_file and not action.update_prompt and aa_cache.get(aa_file, action_id)
                if existing and existing.result then
                  local aa_action_name = action.text or action_id
                  local aa_dialog
                  aa_dialog = ButtonDialog:new{
                    title = T(_("A full-document %1 already exists. Replace it?"), aa_action_name),
                    buttons = {
                      {{
                        text = _("Replace"),
                        callback = function()
                          UIManager:close(aa_dialog)
                          opts.on_execute(state)
                        end,
                      }},
                      {{
                        text = _("Cancel"),
                        callback = function()
                          UIManager:close(aa_dialog)
                        end,
                      }},
                    },
                  }
                  UIManager:show(aa_dialog)
                else
                  opts.on_execute(state)
                end
              else
                opts.on_execute(state)
              end
            end
            -- C3: consent to unread coverage happens HERE, on the committed scope —
            -- a pick-time check on the radio rows would miss the main path ("Full
            -- document" is the pre-selected default, so open→Run taps no row).
            -- Gating the whole tail also covers the summary pre-generation
            -- branches, which extract the same span. Bounded scopes never confirm:
            -- read-so-far/from-section end at the position by construction, and
            -- the chapter presets are clamped under protection (chapterPresets).
            local covers_unread
            local explicit_span
            if state.scope == "full" then
              -- Unless this is a to-position action, whose "full" extraction
              -- already stops at the reading position. Smart retrieval is NOT
              -- exempt (round 4 reversal): full scope means the tool session
              -- reads the whole document, so the consent is exactly right.
              covers_unread = not is_to_position and reading_progress
                  and reading_progress.decimal < 1
            elseif (state.scope == "section" or state.scope == "range")
                and state.section_entry then
              -- One check on the END bound covers a beyond-position start too
              -- (range end_page >= start_page by the picker's order check).
              covers_unread = chapter.current_page and state.section_entry.end_page
                  and state.section_entry.end_page > chapter.current_page
              explicit_span = covers_unread
            end
            confirmUnreadScope(covers_unread, function()
              if explicit_span then
                -- Consenting to an EXPLICIT beyond-position span stands the
                -- spoiler nudge down for this request (prompt and content
                -- agree); full-document consent keeps the nudge (the round-4
                -- stance: whole-book context, spoiler-safe answer). One-shot,
                -- consumed at the first protected send, strays scrubbed at
                -- every entry point.
                configuration.features._spoiler_scope_consent = true
              end
              -- When summary source is selected but no summary exists yet,
              -- generate it first (cache saves it), then continue
              if state.source == "section_summary" then
                -- Generate section summary, then switch source and continue
                local cache_label = state.section_label:gsub(":", "-")
                local scope = self_ref:_buildSectionScope(
                    state.section_entry, state.section_label, cache_label, ActionCache.SECTION_PREFIXES.summary)
                self_ref:_generateSummaryAndContinue(function()
                  state.source = "summary"
                  continueWithAction()
                end, scope)
              elseif state.source == "summary" and not getSummaryAvailable() then
                self_ref:_generateSummaryAndContinue(continueWithAction)
              else
                continueWithAction()
              end
            end)
          end,
        },
      }},
      zero_sep = true,
      show_parent = current_dialog,
    }
    table.insert(vgroup, CenterContainer:new{
      dimen = Geom:new{ w = content_width, h = action_buttons:getSize().h },
      action_buttons,
    })
    table.insert(vgroup, VerticalSpan:new{ width = Size.padding.default })

    -- Wrap in dialog frame. Stock radio-picker composition (RadioButtonWidget
    -- idiom): frame padding 0 so the title bar spans edge-to-edge, content
    -- column CENTERED — the old large frame padding plus a left-aligned column
    -- narrower than the title bar sat everything (Run button included) one
    -- padding left of the dialog's true center (polish round 2026-08-14).
    local widget_frame = FrameContainer:new{
      radius = Size.radius.window,
      padding = 0,
      margin = 0,
      background = Blitbuffer.COLOR_WHITE,
      VerticalGroup:new{
        align = "left",
        title_bar,
        CenterContainer:new{
          dimen = Geom:new{ w = dialog_width, h = vgroup:getSize().h },
          vgroup,
        },
      },
    }
    local movable = MovableContainer:new{ widget_frame }

    -- Anchor the top: open centered (first build), then on rebuilds shift painting down by half the
    -- height growth so the top stays put and the dialog extends downward — no vertical jump as rows
    -- change between scope/source selections. CenterContainer still centers; MovableContainer's
    -- offset (applied in its paintTo) pins us back to the original top.
    local frame_h = widget_frame:getSize().h
    if not first_frame_h then first_frame_h = frame_h end
    movable:setMovedOffset({ x = 0, y = math.floor((frame_h - first_frame_h) / 2) })

    -- Build the dialog as an InputContainer with tap-outside-to-close
    local InputContainer = require("ui/widget/container/inputcontainer")
    current_dialog = InputContainer:new{
      dimen = Geom:new{ x = 0, y = 0, w = screen_width, h = screen_height },
      CenterContainer:new{
        dimen = Geom:new{ w = screen_width, h = screen_height },
        movable,
      },
    }
    current_dialog._widget_frame = widget_frame
    current_dialog.ges_events = {
      TapClose = { GestureRange:new{
        ges = "tap",
        range = Geom:new{ w = screen_width, h = screen_height },
      }},
    }
    function current_dialog:onTapClose(arg, ges_ev)
      if ges_ev.pos:notIntersectWith(widget_frame.dimen) then
        UIManager:close(self)
      end
      return true
    end
    function current_dialog:onCloseWidget()
      UIManager:setDirty(nil, function()
        return "ui", widget_frame.dimen
      end)
    end
    function current_dialog:onShow()
      UIManager:setDirty(self, function()
        return "ui", widget_frame.dimen
      end)
      return true
    end

    UIManager:show(current_dialog)
  end

  buildAndShow()
end

--- Generate document or section summary cache, then call on_done() on success.
--- Builds book config and delegates to Dialogs.generateSummaryCache.
--- @param on_done function: Called when summary generation succeeds
--- @param section_scope table|nil: Section scope from _buildSectionScope() for section summaries
function AskGPT:_generateSummaryAndContinue(on_done, section_scope)
  self:updateConfigFromSettings()
  local config_copy = {}
  for k, v in pairs(configuration or {}) do
    config_copy[k] = v
  end
  config_copy.features = {}
  for k, v in pairs((configuration or {}).features or {}) do
    config_copy.features[k] = v
  end
  config_copy.features.is_book_context = true

  -- Section scope: propagate to config for text extraction scoping and cache saving
  if section_scope then
    config_copy.features._section_scope = section_scope
    config_copy.features._full_document_xray = true  -- Triggers full extraction for section range
  end

  local doc_props = self.ui.doc_props or {}
  local title = doc_props.display_title or doc_props.title or "Unknown"
  local authors = doc_props.authors or ""
  if authors:find("\n") then
    authors = authors:gsub("\n", ", ")
  end
  local doc_file = self.ui and self.ui.document and self.ui.document.file
  local raw_doc_props = getRawDocProps(doc_file) or doc_props
  config_copy.features.book_metadata = buildBookMetadata(title, authors, doc_file, raw_doc_props,
      self.ui and self.ui.document, self.ui and self.ui.doc_settings)

  NetworkMgr:runWhenConnected(function()
    Dialogs.generateSummaryCache(self.ui, config_copy, self, config_copy.features.book_metadata, function(success)
      if success and on_done then
        on_done()
      end
    end, section_scope)
  end)
end

--- Show X-Ray scope popup: choose between partial (to reading position) or full-document X-Ray.
--- Handles two cases: no cache (generate options), cached (view/update/redo/sections).
--- @param action table: The action definition
--- @param action_id string: The action ID
--- @param on_update function: Callback to execute partial (to reading position) action
--- @param cached_entry table|nil: Existing cached entry, or nil if no cache
function AskGPT:_showXrayScopePopup(action, action_id, on_update, cached_entry, opts)
  local action_name = action.text or action_id
  local ButtonDialog = require("ui/widget/buttondialog")
  local self_ref = self

  -- Get current reading progress
  local current_progress
  if self.ui and self.ui.document then
    local ContextExtractor = require("koassistant_context_extractor")
    local extractor = ContextExtractor:new(self.ui)
    current_progress = extractor:getReadingProgress()
  end

  local dialog
  local buttons = {}

  -- P6 grouping (§7): collapse secondary rows behind one "<label>…" row. Group
  -- rows are built exactly like top-level ones — reassigning `dialog` to the
  -- sub-dialog makes their UIManager:close(dialog) close the right widget.
  local function addGroupRow(group_rows, label, group_title)
    if #group_rows == 0 then return end
    -- Round 27 (device: "why does the version menu go into another popup with
    -- just All versions (5)?"): a group holding ONE row is a pure detour — its
    -- own label already says what the row says. Promote it to top level.
    if #group_rows == 1 then
      table.insert(buttons, group_rows[1])
      return
    end
    table.insert(buttons, {{
      text = label,
      callback = function()
        UIManager:close(dialog)
        local rows = {}
        for _idx, r in ipairs(group_rows) do rows[#rows + 1] = r end
        rows[#rows + 1] = {{ text = _("Back"), callback = function()
          UIManager:close(dialog)
          self_ref:_showXrayScopePopup(action, action_id, on_update, cached_entry, opts)
        end }}
        dialog = ButtonDialog:new{ title = group_title, buttons = rows }
        UIManager:show(dialog)
      end,
    }})
  end

  if not cached_entry or not cached_entry.result then
    if self:_checkRequirements(action) then
      return
    end
    -- Round 16: the unified creation chooser replaces the two legacy generate
    -- rows (coverage step, then delivery step — one request / checkpoints /
    -- follow; §7.4 batch item 9 unified-creation design v1)
    table.insert(buttons, {{
      text = _("Create X-Ray…"),
      callback = function()
        UIManager:close(dialog)
        self_ref:_showXrayCreationChooser(action, action_id, on_update, opts)
      end,
    }})
    -- Surface in-range section X-Rays + list existing + new — grouped (P6)
    local ActionCache = require("koassistant_action_cache")
    local sx_file = (self.ui and self.ui.document and self.ui.document.file)
        or (opts and opts.file)
    local nc_sec_rows, nc_ver_rows = {}, {}
    local nc_sx_count = 0
    if sx_file then
      local doc = self.ui and self.ui.document
      if doc then
        local in_range = ActionCache.findMatchingSections(sx_file, doc)
        for _idx, sec in ipairs(in_range) do
          local page_info = ActionCache.reconvertPageSummary(sec.data, doc)
          local sec_parts = {}
          if page_info and page_info ~= "" then
            table.insert(sec_parts, page_info)
          end
          local sec_rel = formatRelativeTime(sec.data.timestamp)
          if sec_rel ~= "" then
            table.insert(sec_parts, sec_rel)
          end
          local sec_detail = #sec_parts > 0 and " (" .. table.concat(sec_parts, ", ") .. ")" or ""
          local captured_sec = sec
          table.insert(nc_sec_rows, {{
            text = T(_("View \"%1\""), sec.label) .. sec_detail,
            callback = function()
              UIManager:close(dialog)
              self_ref:viewCachedAction(action, action_id, captured_sec.data, {
                section_key = captured_sec.key,
                section_label = captured_sec.label,
              })
            end,
          }})
        end
      end
      nc_sx_count = ActionCache.getSectionXrayCount(sx_file)
      if nc_sx_count > 0 then
        table.insert(nc_sec_rows, {{
          text = T(_("View Section X-Rays (%1)"), nc_sx_count),
          callback = function()
            UIManager:close(dialog)
            self_ref:_showSectionXrayList(opts)
          end,
        }})
      end
      -- "Generate Section X-Ray..." only when book is open and has TOC
      if self.ui and self.ui.toc and self.ui.toc.toc and #self.ui.toc.toc > 0 then
        table.insert(nc_sec_rows, {{
          text = _("Generate Section X-Ray…"),
          callback = function()
            UIManager:close(dialog)
            self_ref:_showSectionPicker(action)
          end,
        }})
        table.insert(nc_sec_rows, {{
          text = _("Generate for a section range…"),
          callback = function()
            UIManager:close(dialog)
            self_ref:_showSectionRangePicker(action)
          end,
        }})
      end
      -- A2: two or more section X-Rays can merge into a combined span even
      -- with no main X-Ray — the flow's picker handles scope and consent
      if nc_sx_count >= 2 then
        table.insert(nc_sec_rows, {{
          text = T(_("Merge section X-Rays (%1)…"), nc_sx_count),
          callback = function()
            UIManager:close(dialog)
            self_ref:_startSectionXrayMergeFlow(sx_file, opts)
          end,
        }})
      end
    end
    -- Version ladder from nothing (§6 slice 1): build the full rung set up front —
    -- reading then promotes rungs in for free, and every position has a
    -- spoiler-correct version. Flowing docs only, like the background machinery.
    local nc_xa = require("koassistant_xray_auto")
    local nc_build = nc_xa.ladderBuild()
    if nc_build then
      -- Name the step's target — "no idea what the scope is" when the start
      -- toast was missed (device round 2)
      local nc_step = nc_xa.currentLadderStep()
      local nc_tgt = nc_step and tonumber(nc_step.target)
        and math.floor(nc_step.target * 100 + 0.5) or nil
      table.insert(buttons, {{
        text = nc_build.total == 1
            and (nc_tgt and T(_("Generating X-Ray to %1% in the background… (tap to cancel)"), nc_tgt)
              or _("Generating X-Ray in the background… (tap to cancel)"))
          or (nc_tgt and T(_("Building checkpoints: %1 of %2, to %3%… (tap to cancel)"),
              nc_build.step or nc_build.idx, nc_build.total, nc_tgt)
            or T(_("Building checkpoints: %1 of %2… (tap to cancel)"),
              nc_build.step or nc_build.idx, nc_build.total)),
        callback = function()
          UIManager:close(dialog)
          self_ref:_cancelXrayLadderBuild()
        end,
      }})
    elseif self.ui and self.ui.document and self.ui.document.file
        and not (self.ui.document.info and self.ui.document.info.has_pages) then
      local nc_ac = require("koassistant_action_cache")
      local nc_rungs = nc_ac.getXrayLadderCount(self.ui.document.file)
      local nc_highest
      if nc_rungs > 0 then
        nc_highest = nc_ac.highestXrayLadderProgress(
          nc_ac.getXrayLadder(self.ui.document.file))
      end
      -- With no live X-Ray, the versions list is the rungs' ONLY browse surface —
      -- show it for ANY rung count, not just a complete ladder (device round 1 T3:
      -- a cancelled from-nothing build left its rungs unviewable).
      -- Round 25: count the ARCHIVE RING too. It counted rungs only, so after a
      -- rebuild that archived the live X-Ray and cleared the ladder this row —
      -- the one surface the reader lands on next — was absent, hiding the very
      -- version the rebuild had just promised to keep.
      local nc_arch = nc_ac.getXrayCheckpointCount(self.ui.document.file)
      if nc_rungs + nc_arch > 0 then
        table.insert(nc_ver_rows, {{
          text = T(_("All versions (%1)…"), nc_rungs + nc_arch),
          callback = function()
            UIManager:close(dialog)
            self_ref:_showXrayCheckpointList(opts)
          end,
        }})
      end
      -- Complete from-nothing ladder, no live X-Ray yet (reader before rung 1):
      -- the spoiler-warned switch is the "front-loaded build, no gating wanted"
      -- exit here too (device round 2)
      if nc_rungs > 0 and (nc_highest or 0) >= 1.0 - 0.005 then
        table.insert(nc_ver_rows, {{
          text = _("Switch to complete version (100%), instant"),
          callback = function()
            UIManager:close(dialog)
            self_ref:_switchToCompleteXrayRung(opts)
          end,
        }})
      end
      -- Round 20b (maintainer): the Versions group holds VERSIONS only — the
      -- from-nothing build lives in "Create X-Ray…". Only a PAUSED build keeps
      -- a top-level Resume row; with no rungs the group is empty and hides.
      -- Round 22b (D3 follow-up): a cancelled AUTO chain gets the explicit
      -- "paused" resume row — the in-session exit from the cancel suppression
      -- (covers the cancelled-before-anything-built case too, where no rungs
      -- exist and there was nothing to hang a Resume row on).
      local nc_features = self.settings:readSetting("features") or {}
      local nc_auto_on = self.ui.doc_settings and require("koassistant_book_settings")
        .resolveXrayAuto(self.ui.doc_settings, nc_features)
      if nc_auto_on and nc_xa.isAutoSuppressed(self.ui.document.file) then
        local nc_file = self.ui.document.file
        table.insert(buttons, {{
          text = _("Resume automatic building (paused)…"),
          callback = function()
            UIManager:close(dialog)
            nc_xa.clearAutoSuppression(nc_file)
            -- A cancelled PRE-SWAP rebuild resumes as a rebuild (2026-08-15
            -- A5 — the cancel path records the stop now, and this row must
            -- honor it like the checkpoint-resume row below)
            local nc_stop = nc_xa.lastLadderStop(nc_file)
            self_ref:_fireXrayAutoCheckpoints({ notify = true, explicit = true, asked = true,
              rebuild = (nc_stop and nc_stop.rebuild) or nil })
          end,
        }})
      elseif not nc_xa.isAutoSuppressed(self.ui.document.file)
          and nc_rungs > 0 and (nc_highest or 0) < 1.0 - 0.005 then
        -- Round 24b: a cancel this session means "stop" — with auto toggled
        -- off afterwards the manual Resume row must not reappear either.
        -- The suppression clears on book close, so next open offers it again.
        local nc_stop = nc_xa.lastLadderStop(self.ui.document.file)
        local nc_reason = nc_stop and self:_xrayStopReasonLabel(nc_stop.kind)
        table.insert(buttons, {{
          text = nc_reason
            and T(_("Resume building checkpoints (%1 so far — stopped: %2)…"), nc_rungs, nc_reason)
            or T(_("Resume building checkpoints (%1 so far)…"), nc_rungs),
          callback = function()
            UIManager:close(dialog)
            -- A stopped PRE-SWAP rebuild resumes as a rebuild (2026-08-15)
            self_ref:_startXrayLadderBuild(nc_stop and nc_stop.rebuild
              and { rebuild = true } or nil)
          end,
        }})
      end
    else
      -- Paged documents (PDF) AND closed-book entries: no ladder rows here,
      -- but archived versions must still be reachable with no live X-Ray
      -- (round 25 — archives are never strandable, whatever the document type;
      -- round 26 — nor whether the book happens to be open: the ladder rows
      -- above are open-book-only, this one has no such reason)
      local pg_file = (self.ui and self.ui.document and self.ui.document.file)
        or (opts and opts.file)
      local pg_ac = require("koassistant_action_cache")
      local pg_arch = pg_file and (pg_ac.getXrayCheckpointCount(pg_file)
        + pg_ac.getXrayLadderCount(pg_file)) or 0
      if pg_arch > 0 then
        table.insert(nc_ver_rows, {{
          text = T(_("All versions (%1)…"), pg_arch),
          callback = function()
            UIManager:close(dialog)
            self_ref:_showXrayCheckpointList(opts)
          end,
        }})
      end
    end
    -- P6 group rows (only non-empty groups render)
    addGroupRow(nc_sec_rows,
      nc_sx_count > 0 and T(_("Section X-Rays (%1)…"), nc_sx_count) or _("Section X-Rays…"),
      _("Section X-Rays"))
    addGroupRow(nc_ver_rows, _("Versions…"), _("Versions"))
    -- Per-book Automatic X-Ray (§7 P1): tri-state, universal — On bundles
    -- auto-create + auto-update for this book, no global master needed
    local nc_af = self.settings:readSetting("features") or {}
    if self.ui and self.ui.doc_settings and self.ui.document
        and not (self.ui.document.info and self.ui.document.info.has_pages) then
      table.insert(buttons, {{
        text = T(_("Automatic X-Ray: %1"),
          require("koassistant_book_settings").xrayAutoLabel(self.ui.doc_settings, nc_af)),
        callback = function()
          UIManager:close(dialog)
          require("koassistant_book_settings").showXrayAutoPicker({
            plugin = self_ref, ui = self_ref.ui,
            on_change = function()
              self_ref:_refreshXrayAutoState()
              self_ref:_showXrayScopePopup(action, action_id, on_update, cached_entry, opts)
            end,
          })
        end,
      }})
      -- §5 (51c): one-line posture hint, tap-through to the spoiler picker —
      -- names why checkpoints will follow the position (post-flip the default)
      if self:_xrayPosture() == "track" then
        -- Round 12 wording: never claim "spoiler protection is on" beside an
        -- install that ignores it — a complete or ahead install is pinned
        -- (item 40, never auto-reverted) and its content is not
        -- position-limited. Complete includes a promoted 1.0 ladder rung
        -- (progress-complete, no full_document stamp); the ahead check
        -- follows the versionRows open-book + margin discipline.
        local inst_dec = (cached_entry and cached_entry.result)
          and tonumber(cached_entry.progress_decimal) or 0
        local posture_hint
        if cached_entry and cached_entry.result
            and (cached_entry.full_document or inst_dec >= 0.995) then
          posture_hint = _("The installed X-Ray covers the whole book — spoiler protection does not limit it")
        elseif current_progress and inst_dec > (current_progress.decimal or 0) + 0.01
            and self.ui and self.ui.document and self.ui.document.file == sx_file then
          posture_hint = T(_("The installed X-Ray reaches %1%, ahead of your reading position"),
            math.floor(inst_dec * 100 + 0.5))
        else
          posture_hint = _("Spoiler protection is on — checkpoints follow your position")
        end
        table.insert(buttons, {{
          text = posture_hint,
          callback = function()
            UIManager:close(dialog)
            -- Seam 2: book-scoped launch surface → open on the book tab
            require("koassistant_book_settings").showSpoilerFree({
              plugin = self_ref, ui = self_ref.ui, target_override = "book",
              on_close = function()
                self_ref:_showXrayScopePopup(action, action_id, on_update, cached_entry, opts)
              end,
            })
          end,
        }})
      end
    end
    table.insert(buttons, {{
      text = _("Cancel"),
      callback = function()
        UIManager:close(dialog)
      end,
    }})

    dialog = ButtonDialog:new{
      title = action_name,
      buttons = buttons,
    }
  else
    -- Cached X-Ray: View / Update-or-Redo / Update to 100% / Sections / Cancel
    local view_detail = ""
    local parts = {}
    if cached_entry.intro then
      -- Round 20: a live intro is premise-only coverage, not "0%"
      table.insert(parts, _("introduction"))
    elseif cached_entry.progress_decimal then
      table.insert(parts, math.floor(cached_entry.progress_decimal * 100 + 0.5) .. "%")
    end
    local rel_time = formatRelativeTime(cached_entry.timestamp)
    if rel_time ~= "" then
      table.insert(parts, rel_time)
    end
    -- Visible trace (v1 requirement, xray_background_plan.md §6): distinguish
    -- auto-updates from manual ones in the detail line
    if cached_entry.updated_by_auto then
      table.insert(parts, _("auto"))
    end
    if #parts > 0 then
      view_detail = " (" .. table.concat(parts, ", ") .. ")"
    end

    local ActionCache = require("koassistant_action_cache")
    local sx_file = (self.ui and self.ui.document and self.ui.document.file)
        or (opts and opts.file)
    local doc = self.ui and self.ui.document
    local cp_ring = sx_file and ActionCache.getXrayCheckpoints(sx_file) or {}
    -- Version ladder (§6 slice 1): rungs join the ring everywhere versions are
    -- surfaced (nearest-version pick, count, browse list)
    local ladder_rungs = sx_file and ActionCache.getXrayLadder(sx_file) or {}
    local versions_all = cp_ring
    if #ladder_rungs > 0 then
      versions_all = {}
      for _idx, cp in ipairs(cp_ring) do versions_all[#versions_all + 1] = cp end
      for _idx, rung in ipairs(ladder_rungs) do versions_all[#versions_all + 1] = rung end
    end
    -- P6 grouping: secondary rows collect here, one "<label>…" row each below
    local c_sec_rows, c_ver_rows = {}, {}
    local c_sx_count = sx_file and ActionCache.getSectionXrayCount(sx_file) or 0

    table.insert(buttons, {{
      text = T(_("View %1"), action_name .. view_detail),
      callback = function()
        UIManager:close(dialog)
        self_ref:viewCachedAction(action, action_id, cached_entry)
      end,
    }})
    -- Re-reader shortcut: when the live X-Ray is ahead of the reading position,
    -- offer the newest archived version that stays at-or-below it directly
    -- (spoiler-safe view — xray_ecosystem_plan.md W5)
    if #versions_all > 0 and doc and current_progress
        and (cached_entry.full_document
          or (cached_entry.progress_decimal or 0) > current_progress.decimal + 0.01) then
      local near_idx = ActionCache.nearestCheckpointIndex(versions_all, current_progress.decimal)
      if near_idx then
        local near_cp = versions_all[near_idx]
        -- Short label here (percent only) — the full "end of <chapter> · 2d ago"
        -- form eats the row; orientation detail lives in the Versions list
        local near_short = near_cp.intro and _("Introduction")
          or (tonumber(near_cp.progress_decimal)
            and (math.floor(tonumber(near_cp.progress_decimal) * 100 + 0.5) .. "%"))
          or "…"
        table.insert(buttons, {{
          text = T(_("View earlier version (%1)"), near_short),
          callback = function()
            UIManager:close(dialog)
            self_ref:showCacheViewer({
              name = _("X-Ray Version"),
              key = "_xray_cache",
              data = near_cp,
              file = sx_file,
              book_title = opts and opts.book_title,
              book_author = opts and opts.book_author,
              checkpoint = true,
            })
          end,
        }})
      end
    end
    if sx_file and doc then
      local in_range = ActionCache.findMatchingSections(sx_file, doc)
      for _idx, sec in ipairs(in_range) do
        local page_info = ActionCache.reconvertPageSummary(sec.data, doc)
        local sec_parts = {}
        if page_info and page_info ~= "" then
          table.insert(sec_parts, page_info)
        end
        local sec_rel = formatRelativeTime(sec.data.timestamp)
        if sec_rel ~= "" then
          table.insert(sec_parts, sec_rel)
        end
        local sec_detail = #sec_parts > 0 and " (" .. table.concat(sec_parts, ", ") .. ")" or ""
        local captured_sec = sec
        table.insert(c_sec_rows, {{
          text = T(_("View \"%1\""), sec.label) .. sec_detail,
          callback = function()
            UIManager:close(dialog)
            self_ref:viewCachedAction(action, action_id, captured_sec.data, {
              section_key = captured_sec.key,
              section_label = captured_sec.label,
            })
          end,
        }})
      end
    end
    local XrayAuto = require("koassistant_xray_auto")
    local ladder_building = XrayAuto.ladderBuild()
    -- 50(f) posture + promotion hold: the state header wording below needs
    -- them; the version rows themselves come from the SHARED builder (A2 —
    -- koassistant_xray_rows.lua, one set of gates/labels/confirms with the
    -- browser hamburger), which re-derives both for its own gating
    local xr_posture = self:_xrayPosture()
    local xr_hold = false
    if xr_posture == "full" and doc and self.ui.document.file == sx_file
        and self.ui.doc_settings then
      xr_hold = require("koassistant_book_settings").xrayPromotionHold(self.ui.doc_settings)
    end
    local vr = require("koassistant_xray_rows").versionRows({
      plugin = self, file = sx_file, entry = cached_entry,
      current_progress = current_progress,
      on_update = on_update,
      action = action, action_name = action_name,
      list_opts = opts,
      pre = function() UIManager:close(dialog) end,
    })
    local promotable, next_ahead = vr.promotable, vr.next_ahead
    if ladder_building then
      -- Name the step's target (round 2, same as the no-cache branch)
      local lb_step = XrayAuto.currentLadderStep()
      local lb_tgt = lb_step and tonumber(lb_step.target)
        and math.floor(lb_step.target * 100 + 0.5) or nil
      table.insert(buttons, {{
        text = ladder_building.total == 1
            and (lb_tgt and T(_("Generating X-Ray to %1% in the background… (tap to cancel)"), lb_tgt)
              or _("Generating X-Ray in the background… (tap to cancel)"))
          or (lb_tgt and T(_("Building checkpoints: %1 of %2, to %3%… (tap to cancel)"),
              ladder_building.step or ladder_building.idx, ladder_building.total, lb_tgt)
            or T(_("Building checkpoints: %1 of %2… (tap to cancel)"),
              ladder_building.step or ladder_building.idx, ladder_building.total)),
        callback = function()
          UIManager:close(dialog)
          self_ref:_cancelXrayLadderBuild()
        end,
      }})
    elseif XrayAuto.isInFlight() and XrayAuto.inFlightFile() == sx_file then
      -- A manual run while a background one is in flight is safe (completion guard),
      -- just wasteful — surface the state instead of the Update button. File-scoped
      -- (device round 1 T8): another book's flight must not gray out this book's rows.
      -- Tap-to-cancel (watchdog retirement 2026-08-05): with no timer killing
      -- hung flights, the user is the judge of "too long" — parity with chains.
      table.insert(buttons, {{
        text = _("Auto-update in progress… (tap to cancel)"),
        callback = function()
          UIManager:close(dialog)
          XrayAuto.cancelInFlight()
          self_ref._file_dialog_row_cache = { file = nil, rows = nil }
          self_ref:_refreshXrayAutoState()
          UIManager:show(Notification:new{ text = _("Background update cancelled.") })
        end,
      }})
    elseif vr.update then
      table.insert(buttons, vr.update)
    end
    -- Free local update from a prepared version (§6 slice 1); shown even
    -- while a background update is in flight (device round 1 T6)
    if vr.instant then
      table.insert(buttons, vr.instant)
    end
    -- Free switch to a finished 1.0 rung + free exit from ahead-mode (both
    -- from the shared builder; ladder_highest still feeds the resume gating)
    local ladder_highest = ActionCache.highestXrayLadderProgress(ladder_rungs)
    if vr.switch_complete then
      table.insert(c_ver_rows, vr.switch_complete)
    end
    if vr.switch_back then
      table.insert(c_ver_rows, vr.switch_back)
    end
    -- One-tap built-ahead install (spacing slice; deliberate spoiler-side pick)
    if vr.install_ahead then
      table.insert(c_ver_rows, vr.install_ahead)
    end
    -- The cached-book authoring entry (round 23, item 30 — ONE surface): the
    -- dual-mode creation chooser, labeled by what it will actually do
    -- ("Extend coverage…" on a usable base / "Rebuild X-Ray…" on a
    -- foreign-lineage live — closing the old Extend dead end where
    -- complete-track/AI-knowledge books could only "Delete it first").
    -- Replaces round 21's lean Extend chooser AND the Build-remaining row.
    -- Round 22b rows kept: a cancelled AUTO chain shows the explicit "paused"
    -- resume row (the in-session exit from the cancel suppression); a
    -- genuinely paused MANUAL chain keeps its cheap top-level Resume.
    if doc and not ladder_building
        and self.ui and self.ui.document and self.ui.document.file == sx_file then
      local c_flowing = not (doc.info and doc.info.has_pages)
      local c_features = self.settings:readSetting("features") or {}
      local c_auto_on = c_flowing and self.ui.doc_settings
        and require("koassistant_book_settings")
          .resolveXrayAuto(self.ui.doc_settings, c_features)
      local ext_goal = self.ui.doc_settings and tonumber(self:_openBookDS():readSetting(
        require("koassistant_book_settings").KEY_XRAY_GOAL)) or nil
      if c_auto_on and XrayAuto.isAutoSuppressed(sx_file) then
        table.insert(buttons, {{
          text = _("Resume automatic building (paused)…"),
          callback = function()
            UIManager:close(dialog)
            XrayAuto.clearAutoSuppression(sx_file)
            -- A cancelled PRE-SWAP rebuild resumes as a rebuild (2026-08-15 A5)
            local sx_paused_stop = XrayAuto.lastLadderStop(sx_file)
            self_ref:_fireXrayAutoCheckpoints({ notify = true, explicit = true, asked = true,
              rebuild = (sx_paused_stop and sx_paused_stop.rebuild) or nil })
          end,
        }})
      else
        -- Round 24b: not while cancel-suppressed — cancelling then turning
        -- auto off must not leave a lingering Resume nag (suppression clears
        -- on book close; the authoring form is the in-session re-entry).
        -- Item 40: CHAIN rungs only — a lone manual-fold point (slice 2) is a
        -- kept version, not a paused build to resume.
        if c_flowing and not c_auto_on and XrayAuto.chainRungCount(ladder_rungs) > 0
            and not XrayAuto.isAutoSuppressed(sx_file)
            and (ladder_highest or 0) < 1.0 - 0.005
            and not (ext_goal and (ladder_highest or 0) >= ext_goal - 0.01) then
          local sx_stop = XrayAuto.lastLadderStop(sx_file)
          local sx_reason = sx_stop and self:_xrayStopReasonLabel(sx_stop.kind)
          table.insert(buttons, {{
            text = sx_reason
              and T(_("Resume building checkpoints (from %1% — stopped: %2)…"),
                math.floor((ladder_highest or 0) * 100 + 0.5), sx_reason)
              or T(_("Resume building checkpoints (from %1%)…"),
                math.floor((ladder_highest or 0) * 100 + 0.5)),
            callback = function()
              UIManager:close(dialog)
              -- A stopped PRE-SWAP rebuild resumes as a rebuild (2026-08-15)
              self_ref:_startXrayLadderBuild(sx_stop and sx_stop.rebuild
                and { rebuild = true } or nil)
            end,
          }})
        end
        -- Round 24: no flowing gate — the form's one-request picks (incl. the
        -- redo replacement: below-coverage rebuilds) apply to PDFs too; the
        -- checkpoint/follow rows gate themselves on flowing inside the form
        local a_mode, a_base = self:_xrayAuthoringMode(sx_file)
        if a_mode == "extend" and (a_base or 0) < 0.995 then
          -- Spacing slice (build-shapes): the SPLIT entry — [Extend…] grows
          -- forward from the base, [Rebuild…] opens the same form forced
          -- from-scratch. Before it, a mid-book incremental book had no
          -- whole-book from-scratch path at all (whole-book in extend mode
          -- is an update; only below-base picks rebuilt).
          table.insert(buttons, {
            { text = _("Extend…"), callback = function()
              UIManager:close(dialog)
              self_ref:_showXrayCreationChooser(action, action_id, on_update, opts)
            end },
            { text = _("Rebuild…"), callback = function()
              UIManager:close(dialog)
              self_ref:_showXrayCreationChooser(action, action_id, on_update, opts, true)
            end },
          })
        else
          -- Fully covered incremental (100%): "Extend" would be a lie; the row
          -- reads "Rebuild X-Ray…" and the form's picks all rebuild from scratch.
          -- The 100% extend base rides the FORCED-rebuild form (2026-08-25):
          -- unforced, the position row gated on "position past the base" and
          -- vanished behind a complete X-Ray, so a short book at 34% could not
          -- rebuild to position without deleting first
          local a_label = (a_mode == "rebuild" or a_mode == "extend")
            and _("Rebuild X-Ray…") or _("Create X-Ray…")
          table.insert(buttons, {{
            text = a_label,
            callback = function()
              UIManager:close(dialog)
              self_ref:_showXrayCreationChooser(action, action_id, on_update, opts,
                a_mode == "extend" or nil)
            end,
          }})
        end
      end
    end
    -- Section X-Rays: list existing + new
    if sx_file then
      if c_sx_count > 0 then
        table.insert(c_sec_rows, {{
          text = T(_("View Section X-Rays (%1)"), c_sx_count),
          callback = function()
            UIManager:close(dialog)
            self_ref:_showSectionXrayList(opts)
          end,
        }})
      end
      if self.ui and self.ui.toc and self.ui.toc.toc and #self.ui.toc.toc > 0 then
        table.insert(c_sec_rows, {{
          text = _("Generate Section X-Ray…"),
          callback = function()
            UIManager:close(dialog)
            self_ref:_showSectionPicker(action)
          end,
        }})
        table.insert(c_sec_rows, {{
          text = _("Generate for a section range…"),
          callback = function()
            UIManager:close(dialog)
            self_ref:_showSectionRangePicker(action)
          end,
        }})
      end
      -- Archived pre-overwrite versions + ladder rungs (#73 browsable
      -- history) — the shared builder's row ("All", not "Previous": rungs
      -- ahead of the reader are FUTURE versions)
      if vr.all_versions then
        table.insert(c_ver_rows, vr.all_versions)
      end
    end
    -- P6 group rows (only non-empty groups render)
    addGroupRow(c_sec_rows,
      c_sx_count > 0 and T(_("Section X-Rays (%1)…"), c_sx_count) or _("Section X-Rays…"),
      _("Section X-Rays"))
    addGroupRow(c_ver_rows,
      #versions_all > 0 and T(_("Versions (%1)…"), #versions_all) or _("Versions…"),
      _("Versions"))
    -- A2 merge discoverability: the merge/fold story (sections → main,
    -- cross-book fold incl. the series chain / project fan-in, dedup) was
    -- reachable only via the browser hamburger — the popup gets the same
    -- three entries behind one group row
    local mf_rows = {}
    if sx_file then
      if c_sx_count > 0 then
        table.insert(mf_rows, {{
          text = T(_("Merge section X-Rays (%1)…"), c_sx_count),
          callback = function()
            UIManager:close(dialog)
            self_ref:_startSectionXrayMergeFlow(sx_file, opts)
          end,
        }})
      end
      table.insert(mf_rows, {{
        text = _("Merge from another book…"),
        callback = function()
          UIManager:close(dialog)
          self_ref:_startCrossBookXrayFlow(sx_file, opts)
        end,
      }})
      table.insert(mf_rows, {{
        text = _("Find duplicate entities…"),
        callback = function()
          UIManager:close(dialog)
          self_ref:_startXrayDedupFlow(sx_file, opts)
        end,
      }})
    end
    -- 2026-08-15 (maintainer): the popup surfaces Merge / fold only when it
    -- is actionable here — the book is in a group (cross-book fold) or holds
    -- section X-Rays (within-book merge). Ungrouped books keep full access
    -- via the browser hamburger; this just stops the clutter.
    local mf_relevant = c_sx_count > 0
    if not mf_relevant and sx_file then
      local ok_bg, BookGroups = pcall(require, "koassistant_book_groups")
      mf_relevant = ok_bg and #(BookGroups.groupsFor(sx_file) or {}) > 0
    end
    if mf_relevant then
      addGroupRow(mf_rows, _("Merge / fold…"), _("Merge / fold"))
    end
    -- Per-book Automatic X-Ray (§7 P1): tri-state, universal — mirrored in
    -- Book Settings. Flowing docs only.
    local af = self.settings:readSetting("features") or {}
    if self.ui and self.ui.doc_settings and doc
        and not (doc.info and doc.info.has_pages) then
      table.insert(buttons, {{
        text = T(_("Automatic X-Ray: %1"),
          require("koassistant_book_settings").xrayAutoLabel(self.ui.doc_settings, af)),
        callback = function()
          UIManager:close(dialog)
          require("koassistant_book_settings").showXrayAutoPicker({
            plugin = self_ref, ui = self_ref.ui,
            on_change = function()
              self_ref:_refreshXrayAutoState()
              self_ref:_showXrayScopePopup(action, action_id, on_update, cached_entry, opts)
            end,
          })
        end,
      }})
      -- §5 (51c): one-line posture hint, tap-through to the spoiler picker —
      -- names why updates follow the position (post-flip the default)
      if xr_posture == "track" then
        -- Round 12 wording: never claim "spoiler protection is on" beside an
        -- install that ignores it — a complete or ahead install is pinned
        -- (item 40, never auto-reverted) and its content is not
        -- position-limited. Complete includes a promoted 1.0 ladder rung
        -- (progress-complete, no full_document stamp); the ahead check
        -- follows the versionRows open-book + margin discipline.
        local inst_dec = (cached_entry and cached_entry.result)
          and tonumber(cached_entry.progress_decimal) or 0
        local posture_hint
        if cached_entry and cached_entry.result
            and (cached_entry.full_document or inst_dec >= 0.995) then
          posture_hint = _("The installed X-Ray covers the whole book — spoiler protection does not limit it")
        elseif current_progress and inst_dec > (current_progress.decimal or 0) + 0.01
            and self.ui and self.ui.document and self.ui.document.file == sx_file then
          posture_hint = T(_("The installed X-Ray reaches %1%, ahead of your reading position"),
            math.floor(inst_dec * 100 + 0.5))
        else
          posture_hint = _("Spoiler protection is on — checkpoints follow your position")
        end
        table.insert(buttons, {{
          text = posture_hint,
          callback = function()
            UIManager:close(dialog)
            -- Seam 2: book-scoped launch surface → open on the book tab
            require("koassistant_book_settings").showSpoilerFree({
              plugin = self_ref, ui = self_ref.ui, target_override = "book",
              on_close = function()
                self_ref:_showXrayScopePopup(action, action_id, on_update, cached_entry, opts)
              end,
            })
          end,
        }})
      end
    end
    -- Slice 2 quick settings (plan ruling 5: the X-Ray popup doubles as
    -- X-Ray quick settings). Round 2: a SELF-REBUILDING dialog — toggling
    -- inside the old addGroupRow sub-dialog dumped the reader back at the
    -- main popup (maintainer: "same as clicking the back button").
    table.insert(buttons, {{
      text = _("Marking & lookup…"),
      callback = function()
        UIManager:close(dialog)
        -- file threaded (2026-08-15): the marking rows write THIS book's
        -- sidecar override, so the dialog must know which book it serves
        self_ref:_showXrayMarkingQuickSettings({ file = sx_file, back = function()
          self_ref:_showXrayScopePopup(action, action_id, on_update, cached_entry, opts)
        end })
      end,
    }})
    table.insert(buttons, {{
      text = _("Cancel"),
      callback = function()
        UIManager:close(dialog)
      end,
    }})

    -- State header (round 12, scope/source design standard): line 1 = coverage
    -- (view detail), line 2 = the reader's position + the one fact no row shows
    -- (where the next prepared version lands / that a free one is ready).
    local popup_title = action_name .. view_detail
    if current_progress and not cached_entry.full_document
        and (cached_entry.progress_decimal or 0) < 0.995 then
      -- Round 24 (maintainer): both lines describe FINISHED checkpoints
      -- waiting on disk, never a build trigger — say so plainly
      local pos_line
      if promotable then
        pos_line = T(_("You're at %1. A checkpoint at %2% is ready to install now, free."),
          current_progress.formatted,
          math.floor((tonumber(promotable.progress_decimal) or 0) * 100 + 0.5))
      elseif next_ahead then
        -- Full posture: an uninstalled ahead rung is a transient (promotion
        -- installs it on the next turn) — never claim it waits for the reader
        pos_line = (xr_posture == "full" and not xr_hold)
          and T(_("You're at %1. The next checkpoint (%2%) is built and installs on the next page turn."),
            current_progress.formatted, math.floor(next_ahead * 100 + 0.5))
          or T(_("You're at %1. The next checkpoint (%2%) is already built and installs when you reach it."),
            current_progress.formatted, math.floor(next_ahead * 100 + 0.5))
      else
        pos_line = T(_("You're at %1."), current_progress.formatted)
      end
      popup_title = popup_title .. "\n" .. pos_line
    end
    -- "Last auto-update failed" trace line (session-scoped, silent-failure surfacing)
    if doc and doc.file and XrayAuto.lastFailure(doc.file) then
      popup_title = popup_title .. "\n" .. _("Last auto-update failed")
    end
    dialog = ButtonDialog:new{
      title = popup_title,
      buttons = buttons,
    }
  end

  UIManager:show(dialog)
end

--- Show a TOC picker for selecting a section scope for Section X-Ray generation.
--- Uses the same collapsible hierarchical TOC pattern as the chapter picker in mentions.
--- @param action table: The base xray action definition
--- Show TOC picker for section selection.
--- @param action table Action definition (used by X-Ray legacy path)
--- @param opts table|nil { title = string, on_select = function(entry) }
---   When on_select is provided, it's called with the TOC entry instead of the X-Ray name input flow.
function AskGPT:_showSectionPicker(action, opts)
  if not self.ui or not self.ui.document or not self.ui.toc then return end

  local toc = self.ui.toc.toc
  if not toc or #toc == 0 then
    UIManager:show(InfoMessage:new{ text = _("This book has no table of contents."), timeout = 3 })
    return
  end

  local raw_total_pages = self.ui.document.info.number_of_pages or 0
  local BD = require("ui/bidi")
  local Blitbuffer = require("ffi/blitbuffer")
  local Button = require("ui/widget/button")
  local CenterContainer = require("ui/widget/container/centercontainer")
  local Font = require("ui/font")
  local Geom = require("ui/geometry")
  local Menu = require("ui/widget/menu")
  local Size = require("ui/size")
  local TextWidget = require("ui/widget/textwidget")
  local self_ref = self

  -- Filter hidden flow entries and find last visible page
  local effective_toc = toc
  local total_pages = raw_total_pages
  if self.ui.document.hasHiddenFlows and self.ui.document:hasHiddenFlows() then
    effective_toc = {}
    for _idx, entry in ipairs(toc) do
      if entry.page and self.ui.document:getPageFlow(entry.page) == 0 then
        table.insert(effective_toc, entry)
      end
    end
    -- Last visible (flow 0) page, excluding hidden flows
    for page = raw_total_pages, 1, -1 do
      if self.ui.document:getPageFlow(page) == 0 then
        total_pages = page
        break
      end
    end
  end
  if #effective_toc == 0 then
    UIManager:show(InfoMessage:new{ text = _("No chapters available."), timeout = 3 })
    return
  end

  -- Build entries with end_page scoped to same-or-shallower next sibling
  local max_depth = 0
  local entries = {}
  for i, entry in ipairs(effective_toc) do
    if entry.page then
      local d = entry.depth or 1
      if d > max_depth then max_depth = d end
      local end_page = total_pages
      for j = i + 1, #effective_toc do
        local next_d = effective_toc[j].depth or 1
        if next_d <= d and effective_toc[j].page then
          end_page = effective_toc[j].page - 1
          break
        end
      end
      -- Find parent title for sub-chapters (used in section name suggestions)
      local parent_title
      if d > 1 then
        for j = #entries, 1, -1 do
          if entries[j].depth < d then
            parent_title = entries[j].title
            break
          end
        end
      end
      table.insert(entries, {
        title = entry.title or "",
        start_page = entry.page,
        end_page = end_page,
        depth = d,
        parent_title = parent_title,
      })
    end
  end

  -- Calculate indentation unit: width of 4 spaces (same as KOReader TOC)
  local items_font_size = 18
  local tmp = TextWidget:new{
    text = "    ",
    face = Font:getFace("smallinfofont", items_font_size),
  }
  local toc_indent = tmp:getSize().w
  tmp:free()

  -- Find current reading page for auto-expand
  local current_page = self.ui.view and self.ui.view.state
      and self.ui.view.state.page or 0

  -- Build full TOC array with indent, depth, page range fields
  local full_toc = {}
  for i, entry in ipairs(entries) do
    local d = entry.depth or 1
    local title = entry.title
    -- Use visible page numbers for display
    local vis_sp = self.ui.document.getPageNumberInFlow
        and self.ui.document:getPageNumberInFlow(entry.start_page) or entry.start_page
    local vis_ep = self.ui.document.getPageNumberInFlow
        and self.ui.document:getPageNumberInFlow(entry.end_page) or entry.end_page
    if not title or title == "" then title = T(_("Page %1"), vis_sp) end
    local is_current = current_page >= entry.start_page and current_page <= entry.end_page
    table.insert(full_toc, {
      text = title,
      mandatory = T(_("pp %1–%2"), vis_sp, vis_ep),
      indent = toc_indent * (d - 1),
      depth = d,
      index = i,
      start_page = entry.start_page,
      end_page = entry.end_page,
      is_current = is_current,
      _entry = entry,
    })
  end

  -- Expand/collapse button sizing (same calculation as KOReader TOC)
  local items_per_page = 14
  local icon_size = math.floor(Screen:getHeight() / items_per_page * 2 / 5)
  local button_width = icon_size * 2

  -- Detect parent nodes (reverse pass: if depth < next entry's depth, it's a parent)
  local can_collapse = max_depth > 1
  if can_collapse then
    local depth = 0
    for i = #full_toc, 1, -1 do
      local v = full_toc[i]
      if v.depth < depth then
        v._is_parent = true
      end
      depth = v.depth
    end
  end

  -- State: expanded_nodes tracks which full_toc indices are expanded
  local expanded_nodes = {}

  -- Build initial collapsed view (only top-level entries if multi-depth)
  local collapse_depth = 2
  local collapsed_toc = {}
  if can_collapse then
    for _idx, v in ipairs(full_toc) do
      if v.depth < collapse_depth then
        table.insert(collapsed_toc, v)
      end
    end
  else
    for _idx, v in ipairs(full_toc) do
      table.insert(collapsed_toc, v)
    end
  end

  -- Create the TOC menu (full-screen widget)
  local picker_title = (opts and opts.title) or _("Select Section")
  local toc_menu = Menu:new{
    title = picker_title,
    state_w = can_collapse and button_width or 0,
    is_borderless = true,
    is_popout = false,
    single_line = true,
    align_baselines = true,
    with_dots = true,
    items_per_page = items_per_page,
    items_font_size = items_font_size,
    items_mandatory_font_size = items_font_size - 4,
    items_padding = can_collapse and math.floor(Size.padding.fullscreen / 2) or nil,
    line_color = Blitbuffer.COLOR_WHITE,
  }

  local menu_container = CenterContainer:new{
    dimen = Screen:getSize(),
    covers_fullscreen = true,
    toc_menu,
  }

  -- Create expand/collapse buttons (after menu, for show_parent)
  local expand_button = Button:new{
    icon = "control.expand",
    icon_rotation_angle = BD.mirroredUILayout() and 180 or 0,
    width = button_width,
    icon_width = icon_size,
    icon_height = icon_size,
    bordersize = 0,
    show_parent = menu_container,
    callback = function() end,
    onTapSelectButton = function() end,
  }
  local collapse_button = Button:new{
    icon = "control.collapse",
    width = button_width,
    icon_width = icon_size,
    icon_height = icon_size,
    bordersize = 0,
    show_parent = menu_container,
    callback = function() end,
    onTapSelectButton = function() end,
  }

  -- Assign expand/collapse state to parent nodes
  if can_collapse then
    for _idx, v in ipairs(full_toc) do
      if v._is_parent then
        v.state = expand_button:new{}
      end
    end
  end

  -- Find deepest is_current entry (reading position) for auto-expand
  local target_ft_idx
  if can_collapse then
    for i, v in ipairs(full_toc) do
      if v.is_current then
        target_ft_idx = i  -- keep overwriting → deepest wins
      end
    end
  end

  -- Auto-expand ancestor chain so the current entry is visible
  if target_ft_idx and can_collapse and full_toc[target_ft_idx].depth >= collapse_depth then
    local ancestors = {}
    local need_depth = full_toc[target_ft_idx].depth - 1
    for i = target_ft_idx - 1, 1, -1 do
      if full_toc[i].depth == need_depth then
        table.insert(ancestors, 1, i)
        need_depth = need_depth - 1
        if need_depth < 1 then break end
      end
    end
    for _idx, anc_idx in ipairs(ancestors) do
      expanded_nodes[anc_idx] = true
      local anc = full_toc[anc_idx]
      local ci
      for j, cv in ipairs(collapsed_toc) do
        if cv.start_page == anc.start_page and cv.depth == anc.depth
            and cv.text == anc.text then
          ci = j
          break
        end
      end
      if ci then
        for j = anc_idx + 1, #full_toc do
          local v = full_toc[j]
          if v.depth == anc.depth + 1 then
            ci = ci + 1
            table.insert(collapsed_toc, ci, v)
          elseif v.depth <= anc.depth then
            break
          end
        end
        if anc.state then anc.state:free() end
        anc.state = collapse_button:new{}
      end
    end
  end

  -- Bold highlighting: target the current reading position
  if target_ft_idx then
    local target = full_toc[target_ft_idx]
    for i, v in ipairs(collapsed_toc) do
      if v.start_page == target.start_page and v.depth == target.depth then
        collapsed_toc.current = i
        break
      end
    end
  end

  -- Expand: insert immediate children into collapsed_toc
  local function expandTocNode(index)
    if expanded_nodes[index] then return end
    expanded_nodes[index] = true
    local cur_node = full_toc[index]
    local cur_depth = cur_node.depth
    local collapsed_index
    for i, v in ipairs(collapsed_toc) do
      if v.start_page == cur_node.start_page and v.depth == cur_depth
          and v.text == cur_node.text then
        collapsed_index = i
        break
      end
    end
    if not collapsed_index then return end
    for i = index + 1, #full_toc do
      local v = full_toc[i]
      if v.depth == cur_depth + 1 then
        collapsed_index = collapsed_index + 1
        table.insert(collapsed_toc, collapsed_index, v)
      elseif v.depth <= cur_depth then
        break
      end
    end
    if cur_node.state then cur_node.state:free() end
    cur_node.state = collapse_button:new{}
    toc_menu:switchItemTable(nil, collapsed_toc, -1)
  end

  -- Collapse: remove all descendants from collapsed_toc
  local function collapseTocNode(index)
    if not expanded_nodes[index] then return end
    expanded_nodes[index] = nil
    local cur_node = full_toc[index]
    local cur_depth = cur_node.depth
    local i = 1
    local is_child_node = false
    while i <= #collapsed_toc do
      local v = collapsed_toc[i]
      if is_child_node then
        if v.depth and v.depth <= cur_depth then
          is_child_node = false
          i = i + 1
        else
          if v.state then
            v.state:free()
            if v._is_parent then
              v.state = expand_button:new{}
            end
            if v.index and expanded_nodes[v.index] then
              expanded_nodes[v.index] = nil
            end
          end
          table.remove(collapsed_toc, i)
        end
      else
        if v.start_page == cur_node.start_page and v.depth == cur_depth
            and v.text == cur_node.text then
          is_child_node = true
        end
        i = i + 1
      end
    end
    cur_node.state:free()
    cur_node.state = expand_button:new{}
    toc_menu:switchItemTable(nil, collapsed_toc, -1)
  end

  -- Wire button callbacks
  expand_button.callback = function(index) expandTocNode(index) end
  collapse_button.callback = function(index) collapseTocNode(index) end

  -- Override onMenuSelect: left-zone tap toggles expand/collapse, rest selects entry
  function toc_menu:onMenuSelect(item, pos)
    if item.state and pos and pos.x then
      local do_toggle = BD.mirroredUILayout() and pos.x > 0.7 or pos.x < 0.3
      if do_toggle then
        item.state.callback(item.index)
        return true
      end
    end
    local entry = item._entry
    if not entry then return true end
    UIManager:close(menu_container)
    if opts and opts.on_select then
      opts.on_select(entry)
    else
      self_ref:_showSectionXrayNameInput(action, entry)
    end
    return true
  end

  -- Long-press: show full title (same as KOReader TOC)
  function toc_menu:onMenuHold(item)
    if not Device:isTouchDevice() and item.state then
      item.state.callback(item.index)
    else
      UIManager:show(InfoMessage:new{
        show_icon = false,
        text = item.text or "",
      })
    end
    return true
  end

  toc_menu.close_callback = function()
    UIManager:close(menu_container)
    -- Round 17 back-navigation rule: a picker inside a multi-step flow returns
    -- to the previous step on close-out instead of abandoning the whole flow
    if opts and opts.on_cancel then opts.on_cancel() end
  end
  toc_menu.show_parent = menu_container

  toc_menu:switchItemTable(nil, collapsed_toc, collapsed_toc.current or -1)
  UIManager:show(menu_container)
end

--- Section X-Ray over a RANGE of sections (round 14, §7.4 batch item 10): two
--- TOC picks → one synthetic entry spanning both (union span, composite label),
--- which rides the normal name-input + generate path — one API call instead of
--- build-per-chapter + merge. Picks may come in either order.
function AskGPT:_showSectionRangePicker(action)
  local self_ref = self
  self:_showSectionPicker(action, {
    title = _("Section range: pick the first section"),
    on_select = function(first)
      self_ref:_showSectionPicker(action, {
        title = _("Section range: pick the last section"),
        on_cancel = function()
          -- Back one step: re-open the first pick, not abandon the flow
          self_ref:_showSectionRangePicker(action)
        end,
        on_select = function(second)
          local a, b = first, second
          if (b.start_page or 0) < (a.start_page or 0) then a, b = b, a end
          local entry
          if a.start_page == b.start_page and a.end_page == b.end_page then
            entry = a
          else
            entry = {
              title = T(_("%1 – %2"), a.title or "", b.title or ""),
              start_page = a.start_page,
              end_page = math.max(a.end_page or 0, b.end_page or 0),
              depth = math.min(a.depth or 1, b.depth or 1),
            }
          end
          self_ref:_showSectionXrayNameInput(action, entry)
        end,
      })
    end,
  })
end

--- Round 24: route a version entry to ITS options dialog (rung vs ring
--- resolved by the identity match every version surface uses). The archived-
--- version viewer's way out of the old Info-only dead end.
--- True when this checkpoint identity-matches a ladder rung. Rungs install by
--- position-crossing promotion, never by restore — their options card differs
--- from a ring version's, and callers labeling an entry point need to know.
function AskGPT:_xrayVersionIsRung(cp, file)
  local ActionCache = require("koassistant_action_cache")
  for _idx, r in ipairs(ActionCache.getXrayLadder(file)) do
    if r.timestamp == cp.timestamp
        and math.abs((tonumber(r.progress_decimal) or -1)
          - (tonumber(cp.progress_decimal) or -2)) < 1e-6 then
      return true
    end
  end
  return false
end

function AskGPT:_showXrayVersionOptions(cp, file, opts)
  if self:_xrayVersionIsRung(cp, file) then
    return self:_showXrayLadderRungOptions(cp, opts)
  end
  return self:_showXrayCheckpointOptions(cp, opts)
end

--- Round 23 (plan item 30, maintainer GO): shared base-state derivation for
--- the dual-mode authoring form and its popup row label. Same base rules as
--- _startXrayLadderBuild: highest non-intro rung vs eligible live entry
--- (terminal-100% incremental counts; intro entries never do).
--- @return string mode "create" (nothing usable — incl. intro-only leftovers)
---   | "extend" (usable incremental base) | "rebuild" (foreign-lineage live:
---   complete-track / AI-knowledge source / legacy text, no rung base)
--- @return number|nil base progress, boolean has_intro (live or rung),
---   table|nil the live per-action entry
function AskGPT:_xrayAuthoringMode(file)
  local ActionCache = require("koassistant_action_cache")
  local XrayParser = require("koassistant_xray_parser")
  local XrayAuto = require("koassistant_xray_auto")
  local ladder = ActionCache.getXrayLadder(file)
  local base = ActionCache.highestXrayLadderProgress(ladder)
  local has_intro = false
  for _idx, r in ipairs(ladder) do
    if r.intro then has_intro = true end
  end
  local entry = ActionCache.get(file, "xray")
  if entry and entry.intro then has_intro = true end
  local live_ok, live_progress = XrayAuto.eligibilityFromEntry(entry, XrayParser.isJSON)
  if not live_ok and entry and entry.result then
    -- A terminal (100%) incremental X-Ray is a valid base — eligibility only
    -- rejects it because there is nothing left to UPDATE
    local p = tonumber(entry.progress_decimal)
    if p and p >= 1.0 and not entry.full_document and entry.source_mode ~= "ai_knowledge"
        and XrayParser.isJSON(entry.result) then
      live_ok, live_progress = true, p
    end
  end
  -- The INSTALLED artifact's own coverage, separate from the ladder top
  -- (2026-08-14 device round: with a checkpoint built AHEAD of the reader,
  -- folding both into one "base" made the form's position pick read "from
  -- scratch" — while round 24's paid-row demotion in the popup assumed this
  -- form kept the to-position update reachable; jointly, "update to where I
  -- am" had no surface at all)
  local installed = live_ok and not (entry and entry.intro) and live_progress or nil
  if live_ok and not (entry and entry.intro)
      and (base == nil or (live_progress or 0) > base) then
    base = live_progress
  end
  local mode = "create"
  if base ~= nil then
    mode = "extend"
  elseif entry and entry.result and not entry.intro then
    mode = "rebuild"
  end
  return mode, base, has_intro, entry, installed
end

--- Unified X-Ray creation chooser (round 18 re-shell of the round-16 two-step:
--- the scope/source RADIO idiom — both axes visible at once, rebuild-on-change
--- with the top-anchor trick from _showUnifiedActionPopup; dispatch identical).
--- State-aware: reading position, per-book auto posture, live checkpoint counts.
--- Round 23: DUAL-MODE — also the cached-branch authoring surface ("Extend
--- coverage…" / "Rebuild X-Ray…" rows). Extend plans FROM the disk base and
--- disables already-covered picks; rebuild archives the foreign-lineage live
--- X-Ray (ring) and starts from scratch — closing the item-30 dead end where
--- complete-track/AI-knowledge books could only "Delete it first".
--- Spacing slice: force_rebuild (the split entry's [Rebuild…] button) keeps
--- mode "extend" for anchoring but makes EVERY pick a from-scratch rebuild —
--- the only whole-book from-scratch path on a mid-book incremental base.
function AskGPT:_showXrayCreationChooser(action, action_id, on_update, opts, force_rebuild)
  local ButtonDialog = require("ui/widget/buttondialog")
  local XrayAuto = require("koassistant_xray_auto")
  local self_ref = self
  local doc = self.ui and self.ui.document
  if not doc then
    -- File-browser entry: no live document, so only the one-request paths exist
    local fb_dialog
    fb_dialog = ButtonDialog:new{
      title = _("Create X-Ray: how far should it cover?"),
      buttons = {
        {{ text = _("The whole book"), callback = function()
          UIManager:close(fb_dialog)
          self_ref:_executeBookLevelActionDirect(action, action_id, { full_document = true })
        end }},
        {{ text = _("Up to my reading position"), callback = function()
          UIManager:close(fb_dialog)
          on_update()
        end }},
        {{ text = _("Cancel"), callback = function() UIManager:close(fb_dialog) end }},
      },
    }
    UIManager:show(fb_dialog)
    return
  end
  local ContextExtractor = require("koassistant_context_extractor")
  local progress = ContextExtractor:new(self.ui):getReadingProgress()
  local decimal = progress and tonumber(progress.decimal) or 0
  local features = self.settings:readSetting("features") or {}
  local flowing = not (doc.info and doc.info.has_pages)
  local total_pages = doc:getPageCount() or 0
  local BookSettings = require("koassistant_book_settings")
  local auto_on = flowing and BookSettings.resolveXrayAuto(self.ui.doc_settings, features)
  -- Round 23 (item 30): dual-mode — create / extend (usable base on disk) /
  -- rebuild (foreign-lineage live, no base)
  local cc_file = doc.file
  local mode, base_progress, has_intro_rung, base_entry, installed_progress =
    self:_xrayAuthoringMode(cc_file)
  -- Position picks anchor on the INSTALLED artifact (ladder rungs ahead of
  -- the reader are future versions, not current coverage); whole/target
  -- picks keep the ladder anchor — their builds continue the rung chain.
  -- No installed artifact (foreign live + rungs) falls back to the ladder.
  local pos_anchor = installed_progress or base_progress

  -- Round 20b (maintainer): whole book is the DEFAULT and top coverage option.
  -- Round 22 (§25(f)): checkpoints are the default DELIVERY when the plan is
  -- substantial (≥4 steps) — medium and long books get spoiler-safe versions
  -- unless the user opts into one big request; short books keep one request.
  -- (Adjusted below once the planning helpers exist.)
  local cr = {
    coverage = "whole",
    delivery = "one",
    target = nil, target_label = nil,
  }
  local current_dialog
  local first_frame_h
  local buildAndShow

  local function goalFor()
    if cr.coverage == "position" then return decimal end
    if cr.coverage == "target" then return cr.target or 1.0 end
    return 1.0
  end

  -- Round 24 (maintainer: fold redo into the form): in extend mode a pick
  -- whose coverage END is at or below the base is a REBUILD from scratch
  -- (replaces the old "already covered" disable) — same dispatch family as
  -- mode "rebuild". This absorbs the popup's old redo and
  -- rebuild-to-your-position rows.
  local function pickIsRebuild()
    if force_rebuild then return true end
    if mode == "rebuild" then return true end
    if mode ~= "extend" then return false end
    if cr.coverage == "position" then
      -- Installed anchor: a position past the installed coverage is an
      -- UPDATE even when a checkpoint is built ahead of it
      return decimal <= (pos_anchor or 0) + 0.01
    end
    return goalFor() <= (base_progress or 0) + 0.01
  end

  -- Extend picks never plan an intro; create picks do unless a leftover intro
  -- rung exists. Rebuild chains deliberately never plan one (the reader keeps
  -- the old live X-Ray until rung 1 lands, so a premise-only step buys
  -- nothing — the engine forces has_intro there), and the count here must
  -- match or the "In checkpoints, now" row overcounts by 1 (2026-08-15).
  local function planIntroStep()
    if pickIsRebuild() then return false end
    if mode == "extend" then return false end
    -- To-position plans build no intro (2026-08-25): the chain ends AT the
    -- reader's position whatever the spacing, and a premise-only step ahead of
    -- a bounded plan the reader asked for is a spend they did not ask for
    if cr.coverage == "position" then return false end
    return not has_intro_rung
  end

  local function stepsFor()
    if not flowing then return 0 end
    local spacing = self_ref:_xrayLadderSpacing()
    -- Seed-aware (round 19): whole-book/target builds gain a first checkpoint
    -- at the reading position, and the shown step count must match the plan.
    -- Extend picks plan FROM the disk base (round 23); rebuild picks plan
    -- from nothing (round 24).
    local rungs = XrayAuto.planBuildRungs(
      (mode == "extend" and not pickIsRebuild()) and base_progress or 0,
      spacing, goalFor(), decimal, pickIsRebuild())
    return #rungs
  end

  -- Keep the delivery pick valid when coverage changes. Round 21 (unified
  -- engine): "as I read" is valid for whole-book AND section-end coverage —
  -- the coverage goal bounds the auto scheduler exactly as it bounds the
  -- front-load chain. "Up to where I am" is a snapshot: now-deliveries only.
  -- Round 22 (D5): the follow row stays pickable when auto is already on —
  -- it reads "already on — start now" and starts the engine (R4: explicit
  -- enables act immediately; without this, a nominally-auto book with
  -- nothing built had no explicit-start entry).
  -- Auto already on with the ladder at or past the reader: the follow pick
  -- has nothing to start (2026-08-14 device round — a pickable row that did
  -- nothing); it renders as a disabled state row and is never a default
  local function followIdle()
    -- A rebuild's follow pick is never "already on" — it starts a from-scratch
    -- catch-up chain regardless of what the old lineage covers (device round 2:
    -- the idle label on a rebuild read as nonsense and disabled the commit)
    if force_rebuild then return false end
    return (auto_on and (base_progress or 0) >= decimal - 0.01) and true or false
  end

  local function fixDelivery()
    if cr.delivery == "follow" and cr.coverage == "position" then
      cr.delivery = "one"
    end
    if cr.delivery == "checkpoints" and stepsFor() < 1 then
      cr.delivery = "one"
    end
    -- one_bg needs the ladder machinery (flowing); target coverage's "one"
    -- row IS the background request, so the pick folds into it
    if cr.delivery == "one_bg" and (not flowing or cr.coverage == "target") then
      cr.delivery = "one"
    end
  end

  -- Round 22 (§25(f)): the checkpoint default for substantial plans.
  -- Build-shapes 2026-08-14: the default DELIVERY is posture-routed —
  -- protection OFF (spoiler off / research / finished) keeps build-all-now
  -- (the quality path: short steps, bounded context), protection ON prefers
  -- build-as-you-read when the follow pick can actually start. The steps
  -- gate doubles as the length threshold: short docs stay on one request.
  if flowing and stepsFor() >= 4 then
    cr.delivery = "checkpoints"
    local sp = BookSettings.resolveSpoilerPosture(self.ui.doc_settings, features)
    if sp and sp.protected and not followIdle() then
      cr.delivery = "follow"
    end
  end

  local function dispatch()
    local rebuild_pick = pickIsRebuild()
    -- DEFERRED DESTRUCTION, NO EXCEPTIONS (2026-08-14 device disaster: the
    -- old "ladder deliveries keep the eager clear" branch archived a live
    -- X-Ray and silently deleted an UNARCHIVED checkpoint at this confirm —
    -- on a build the user then DECLINED at the next screen). The round-25
    -- rule is absolute now: NOTHING is archived, cleared or replaced before
    -- a run has actually succeeded. Foreground whole-book rebuilds keep the
    -- existing xray_rebuild success-write defer; every ladder delivery
    -- (checkpoints / one_bg / follow catch-up / bounded one-shots) carries
    -- rebuild=true on the build session instead, and the FIRST successful
    -- rung write performs the swap (archive live, clear old ladder, store).
    local function go()
      -- Round 21: the coverage goal is a BOOK property bounding the auto
      -- scheduler — target picks store it, whole-book picks clear it (position
      -- is a snapshot: untouched). Round 23: written here, AFTER the rebuild
      -- confirm — a cancelled rebuild must not have touched the goal.
      if self_ref.ui and self_ref.ui.doc_settings and cr.coverage ~= "position" then
        self_ref:_openBookDS():saveSetting(
          require("koassistant_book_settings").KEY_XRAY_GOAL,
          cr.coverage == "target" and cr.target or nil)
      end
      if cr.delivery == "follow" then
        if rebuild_pick then
          -- Rebuild catch-up: the same auto chain, planned from scratch with
          -- the deferred swap; auto continues on the new lineage afterwards
          if not auto_on then
            self_ref:_enableXrayFollowForBook(decimal, { rebuild = true })
          else
            self_ref:_xrayFollowCatchUp(decimal, { rebuild = true })
          end
        elseif auto_on then
          -- Round 22 (D5): already on (per-book or via the global master) —
          -- don't re-pin the per-book key, just start the engine now
          self_ref:_xrayFollowCatchUp(decimal)
        else
          self_ref:_enableXrayFollowForBook(decimal)
        end
      elseif cr.delivery == "checkpoints" then
        local bo = { rebuild = rebuild_pick or nil }
        if cr.coverage == "position" then
          bo.target, bo.to_position = decimal, true
        elseif cr.coverage == "target" then
          bo.target, bo.target_label = cr.target, cr.target_label
        end
        self_ref:_startXrayLadderBuild(bo)
      elseif cr.delivery == "one_bg" then
        if cr.coverage == "position" and mode == "extend" and not rebuild_pick then
          -- Position update in background: the plain background UPDATE of
          -- the installed artifact — the ladder one-shot plans from the
          -- rung top and no-ops when a rung is built ahead of the reader
          self_ref:_fireXrayAutoUpdate({ manual = true })
        else
          -- Item 50(a): whole-book/position single request through the
          -- silent one-step machinery (install + notification; cancel like
          -- a build)
          self_ref:_startXrayLadderBuild({
            one_shot = true,
            rebuild = rebuild_pick or nil,
            target = cr.coverage == "position" and decimal or nil,
          })
        end
      else
        if cr.coverage == "position" then
          if rebuild_pick then
            -- From-scratch to position: the bounded one-shot with the
            -- deferred swap (the old path cleared eagerly then ran the
            -- foreground update against the void)
            self_ref:_startXrayLadderBuild({
              one_shot = true, rebuild = true, target = decimal })
          else
            on_update()
          end
        elseif cr.coverage == "whole" then
          if mode == "extend" and not rebuild_pick then
            -- Round 23: extending an incremental base to 100% is an UPDATE,
            -- not a fresh complete-track analysis
            self_ref:_executeBookLevelActionDirect(action, action_id, { update_to_full = true })
          else
            self_ref:_executeBookLevelActionDirect(action, action_id,
              { full_document = true, xray_rebuild = rebuild_pick or nil })
          end
        else
          self_ref:_startXrayLadderBuild({
            target = cr.target, target_label = cr.target_label, one_shot = true,
            rebuild = rebuild_pick or nil })
        end
      end
    end
    if not rebuild_pick then return go() end
    -- Ladder deliveries carry their own honest replace line inside the build
    -- confirm — stacking a second ConfirmBox here was part of the 2026-08-14
    -- confusion (two screens, and the first one used to destroy data).
    if cr.delivery == "checkpoints" or cr.delivery == "one_bg"
        or cr.delivery == "follow"
        or (cr.delivery == "one" and cr.coverage ~= "whole") then
      return go()
    end
    -- Foreground whole-book rebuild: one confirm, nothing touched until the
    -- new X-Ray is saved (xray_rebuild success-write defer, round 25)
    local ConfirmBox = require("ui/widget/confirmbox")
    local ActionCache = require("koassistant_action_cache")
    local limit = ActionCache.checkpointLimitFromFeatures(features)
    local confirm_text = limit ~= 0
      and _("Rebuild from scratch, replacing the current X-Ray? The current one is kept until the new one arrives, then archived under \"All versions\".")
      or _("Rebuild from scratch, replacing the current X-Ray? The current one is kept until the new one arrives, then replaced. Version archiving is off, so it will be gone.")
    local n_rungs = ActionCache.getXrayLadderCount(cc_file)
    if n_rungs > 0 then
      confirm_text = confirm_text .. "\n"
        .. T(_("Its %1 checkpoints belong to the old version and are deleted when the new one is saved."), n_rungs)
    end
    UIManager:show(ConfirmBox:new{
      text = confirm_text,
      ok_text = _("Rebuild"),
      ok_callback = function()
        go()
      end,
    })
  end

  buildAndShow = function()
    local Blitbuffer = require("ffi/blitbuffer")
    local ButtonTable = require("ui/widget/buttontable")
    local CenterContainer = require("ui/widget/container/centercontainer")
    local Font = require("ui/font")
    local FrameContainer = require("ui/widget/container/framecontainer")
    local Geom = require("ui/geometry")
    local GestureRange = require("ui/gesturerange")
    local MovableContainer = require("ui/widget/container/movablecontainer")
    local RadioButtonTable = require("ui/widget/radiobuttontable")
    local Size = require("ui/size")
    local TextBoxWidget = require("ui/widget/textboxwidget")
    local TextWidget = require("ui/widget/textwidget")
    local TitleBar = require("ui/widget/titlebar")
    local VerticalGroup = require("ui/widget/verticalgroup")
    local VerticalSpan = require("ui/widget/verticalspan")

    local screen_width = Screen:getWidth()
    local screen_height = Screen:getHeight()
    local dialog_width = math.floor(math.min(screen_width, screen_height) * 0.8)
    local content_width = dialog_width - 2 * Size.padding.large
    local label_face = Font:getFace("cfont", 18)
    local radio_face = Font:getFace("cfont", 20)
    local info_face = Font:getFace("cfont", 16)

    local vgroup = VerticalGroup:new{ align = "left" }
    local title_bar = TitleBar:new{
      width = dialog_width,
      align = "left",
      with_bottom_line = true,
      title = (force_rebuild or mode == "rebuild"
            or (mode == "extend" and (base_progress or 0) >= 0.995))
          and _("Rebuild X-Ray")
        or mode == "extend" and _("Extend X-Ray")
        or _("Create X-Ray"),
      title_shrink_font_to_fit = true,
      close_callback = function() UIManager:close(current_dialog) end,
    }
    local function addLabel(text)
      table.insert(vgroup, VerticalSpan:new{ width = Size.padding.large })
      table.insert(vgroup, TextWidget:new{
        text = text, face = label_face, bold = true,
        fgcolor = Blitbuffer.COLOR_DARK_GRAY,
      })
      table.insert(vgroup, VerticalSpan:new{ width = Size.padding.small })
    end

    -- Round 23: state line — what exists, and what picking here does to it
    local state_line
    if force_rebuild then
      state_line = T(_("Your X-Ray covers to %1%. Building here replaces it from scratch (the outgoing version is archived under \"All versions\")."),
        math.floor((base_progress or 0) * 100 + 0.5))
    elseif mode == "extend" then
      -- Name BOTH numbers when they differ (device 2026-08-14: "covers to
      -- 60%" while the reader's viewer showed the installed 50% read as a
      -- contradiction)
      if installed_progress and base_progress
          and base_progress > installed_progress + 0.005 then
        -- "already built" spelled out (device: "checkpoints are built to X%"
        -- read as a general statement about how checkpoints work)
        state_line = T(_("Your installed X-Ray covers to %1%. A checkpoint up to %2% is already built."),
          math.floor(installed_progress * 100 + 0.5),
          math.floor(base_progress * 100 + 0.5))
      else
        state_line = T(_("Your X-Ray covers to %1%."),
          math.floor((base_progress or 0) * 100 + 0.5))
      end
    elseif mode == "rebuild" and base_entry then
      local flavor = base_entry.full_document and _("analyzed as a whole")
        or base_entry.source_mode == "ai_knowledge" and _("made from AI knowledge")
        or _("in an older format")
      state_line = T(_("Your current X-Ray was %1, so it can't be extended. Building here replaces it (the outgoing version is archived under \"All versions\")."), flavor)
    end
    -- Round 2 (device: "it says auto is on, but no next checkpoint or
    -- anything"): with automatic building on, the state line names where the
    -- next checkpoint will land under the current spacing
    if state_line and auto_on and mode == "extend" and not force_rebuild then
      local nxt = XrayAuto.planBuildRungs(base_progress or 0,
        self_ref:_xrayLadderSpacing(), 1.0, decimal)[1]
      if nxt and nxt < 1.0 - 0.005 then
        state_line = state_line .. " " .. T(_("Automatic building is on; the next checkpoint arrives at %1%."),
          math.floor(nxt * 100 + 0.5))
      elseif nxt then
        state_line = state_line .. " " .. _("Automatic building is on; the next checkpoint completes the book.")
      end
    end
    if state_line then
      table.insert(vgroup, VerticalSpan:new{ width = Size.padding.small })
      table.insert(vgroup, TextBoxWidget:new{
        text = state_line, face = info_face, width = content_width,
        fgcolor = Blitbuffer.COLOR_DARK_GRAY,
      })
    end

    -- === Coverage ===
    addLabel(_("Coverage"))
    local cov_rows = {}
    cov_rows[#cov_rows + 1] = { { text = _("The whole book"),
      provider = "whole", checked = cr.coverage == "whole" } }
    -- The row label rounds to the nearest percent, so gate on the rounded
    -- value too: a book displayed at "1%" must never show the row (0.015
    -- rounds to 2%, the lowest percent that does)
    if progress and decimal >= 0.015 then
      -- Round 2 (device): plain-extend mode DROPS the ", from scratch"
      -- position variant — redo lives under [Rebuild…] now. The row exists
      -- in plain extend only when it is a real update past the installed
      -- coverage; the rebuild form keeps it with the from-scratch marker.
      local pos_is_update = mode ~= "extend"
        or decimal > (pos_anchor or 0) + 0.01
      if force_rebuild or pos_is_update then
        cov_rows[#cov_rows + 1] = { { text = force_rebuild
            and T(_("Up to my current position (%1), from scratch"), progress.formatted)
            or T(_("Up to my current position (%1)"), progress.formatted),
          provider = "position",
          checked = cr.coverage == "position" } }
      end
    end
    if flowing and self.ui.toc and self.ui.toc.toc and #self.ui.toc.toc > 0 then
      local tgt_rebuild = mode == "extend" and cr.target
        and (force_rebuild or cr.target <= (base_progress or 0) + 0.01)
      local target_text = cr.coverage == "target" and cr.target
        and (tgt_rebuild
          and T(_("To the end of \"%1\" (%2%), from scratch"), cr.target_label or "?",
            math.floor(cr.target * 100 + 0.5))
          or T(_("To the end of \"%1\" (%2%)"), cr.target_label or "?",
            math.floor(cr.target * 100 + 0.5)))
        or _("To the end of a section…")
      cov_rows[#cov_rows + 1] = { { text = target_text,
        provider = "target", checked = cr.coverage == "target" } }
    end
    local cov_table = RadioButtonTable:new{
      radio_buttons = cov_rows,
      width = content_width,
      no_sep = true, sep_width = 0,
      face = radio_face,
      show_parent = self_ref, parent = self_ref,
      button_select_callback = function(btn)
        if btn.enabled == false then return end
        if btn.provider == "target" then
          -- (Re-)pick the section even when already selected: tapping the row
          -- again is the natural way to change the target
          UIManager:close(current_dialog)
          self_ref:_showSectionPicker(action, {
            title = _("Cover the book up to the end of…"),
            on_cancel = function() buildAndShow() end,
            on_select = function(entry)
              local ratio = total_pages > 0 and (entry.end_page or 0) / total_pages or 0
              -- Round 24: a section inside the covered range is a valid pick
              -- now — it reads ", from scratch" and rebuilds (no more bounce)
              if ratio >= 1.0 - 0.005 then
                cr.coverage, cr.target, cr.target_label = "whole", nil, nil
              elseif ratio > 0.01 then
                cr.coverage, cr.target, cr.target_label = "target", ratio, entry.title
              end
              fixDelivery()
              buildAndShow()
            end,
          })
          return
        end
        if cr.coverage == btn.provider then return end
        UIManager:close(current_dialog)
        cr.coverage = btn.provider
        cr.target, cr.target_label = nil, nil
        fixDelivery()
        buildAndShow()
      end,
    }
    table.insert(vgroup, cov_table)

    -- === Build ===
    addLabel(_("Build"))
    local pick_rebuild = pickIsRebuild()
    local one_label
    if cr.coverage == "target" then
      -- The section-bounded single request has ALWAYS run in the background
      -- (round 17 one_shot) — label it honestly; no streamed variant exists
      one_label = (mode == "extend" and not pick_rebuild)
        and _("In one request, in background (update)")
        or _("In one request, in background")
    elseif pick_rebuild and cr.coverage == "position" then
      -- From-scratch to position rides the deferred one-shot (background)
      one_label = _("In one request, in background (from scratch)")
    elseif mode == "extend" and not pick_rebuild then
      one_label = cr.coverage == "whole" and _("In one request now (update to 100%)")
        or _("In one request now (update to your position)")
    else
      one_label = _("In one request now")
    end
    local del_rows = {
      { { text = one_label,
        provider = "one", checked = cr.delivery == "one" } },
    }
    -- Item 50(a): the background single request — same request, silent ladder
    -- machinery, one step. Flowing docs only (the machinery's gate); target
    -- coverage's "one" row IS this already, so no second row there — nor for
    -- the position rebuild, whose "one" row is already the background one-shot.
    if flowing and cr.coverage ~= "target"
        and not (pick_rebuild and cr.coverage == "position") then
      local bg_label = (mode == "extend" and not pick_rebuild
          and cr.coverage == "position")
        and _("In one request, in background (update)")
        or _("In one request, in background")
      del_rows[#del_rows + 1] = { { text = bg_label,
        provider = "one_bg", checked = cr.delivery == "one_bg" } }
    end
    local n_steps = stepsFor()
    if n_steps >= 1 then
      -- From-nothing/rebuild checkpoint builds start with the introductory
      -- step (round 20); extend picks never do (rounds 23/24) — the shown
      -- count must match the build confirm's plan. A ONE-step plan stays
      -- pickable (2026-08-25, maintainer): wide spacing on a short range is
      -- still the ladder path, the count says so
      local shown = n_steps + (planIntroStep() and 1 or 0)
      del_rows[#del_rows + 1] = { { text = shown == 1
          and _("In checkpoints, now (1 background step)")
          or T(_("In checkpoints, now (%1 background steps)"), shown),
        provider = "checkpoints", checked = cr.delivery == "checkpoints" } }
    end
    if flowing and (cr.coverage == "whole" or cr.coverage == "target") then
      -- The idle state row stays SELECTABLE and black (round 12 device: a
      -- grayed radio still took the tap, and its gray bled into the gray
      -- hint below it) — selecting it disables the commit button instead,
      -- with the hint saying why
      del_rows[#del_rows + 1] = { { text = followIdle()
          and _("In checkpoints, as I read (already on)")
          or (auto_on and not force_rebuild)
            and _("In checkpoints, as I read (already on; start now)")
          or _("In checkpoints, as I read (automatic)"),
        provider = "follow", checked = cr.delivery == "follow" } }
    end
    local del_table = RadioButtonTable:new{
      radio_buttons = del_rows,
      width = content_width,
      no_sep = true, sep_width = 0,
      face = radio_face,
      show_parent = self_ref, parent = self_ref,
      button_select_callback = function(btn)
        if btn.enabled == false then return end
        if cr.delivery == btn.provider then return end
        UIManager:close(current_dialog)
        cr.delivery = btn.provider
        buildAndShow()
      end,
    }
    table.insert(vgroup, del_table)

    -- Gray hint under the Build group — every pick explains itself up front
    -- (round 22, §25(f); previously only the follow pick had one)
    local hint
    -- Item 50(c): the forward story every extendable one-request pick carries
    local later_line = _("You can update it manually anytime, or turn on automatic updates later; both build on top of what you have.")
    if cr.delivery == "follow" and followIdle() then
      hint = _("Automatic building is on and caught up. The next checkpoint builds by itself as you read on.")
    elseif cr.delivery == "follow" then
      hint = _("Builds checkpoints in the background as you read, keeping the next one ready ahead of you. Missing checkpoints up to your position build right away.")
      if cr.coverage == "whole" then
        hint = hint .. " " .. _("Coverage reaches 100% when you finish the book.")
      elseif cr.coverage == "target" and cr.target_label then
        hint = hint .. " " .. T(_("It stops at the end of \"%1\"."), cr.target_label)
      end
    elseif cr.delivery == "checkpoints" then
      -- Item 33(1): checkpoints are a quality/size mechanism first, spoiler
      -- safety second — the copy names both, in that order. Item 50(b): the
      -- INDIVIDUAL-requests-stay-small fact, plainly (the total text read is
      -- the same; only each request shrinks).
      hint = (mode == "extend" and not pick_rebuild)
        and _("Continues from your current coverage in bounded background steps, each a spoiler-safe version. Keep reading, cancel anytime, resume later.")
        or _("Covers the range in bounded background steps, each a spoiler-safe version up to its position. A usable X-Ray installs after the first step; keep reading, cancel anytime, resume later.")
    elseif cr.delivery == "one_bg" then
      hint = _("The same single request in the background; a notification arrives when it is ready. The book must stay open.")
      if cr.coverage ~= "whole" then
        hint = hint .. " " .. later_line
      end
    elseif mode == "extend" and not pick_rebuild then
      if cr.coverage == "whole" then
        hint = _("Updates your existing X-Ray to 100% in a single request.")
      elseif cr.coverage == "position" then
        hint = _("Updates your existing X-Ray up to your position in a single request.")
          .. " " .. later_line
      else
        hint = _("Updates your existing X-Ray to the end of the chosen section in one background request; a notification arrives when it is ready.")
      end
    elseif cr.coverage == "whole" then
      hint = _("Analyzes the whole book in a single request, shown as it streams in. Large for long books, no spoiler-safe intermediate versions.")
    elseif cr.coverage == "position" then
      hint = _("Reads the book up to your position in a single request, shown as it streams in.")
        .. " " .. later_line
    else
      hint = _("Reads the book up to the end of the chosen section in one background request; a notification arrives when it is ready.")
        .. " " .. later_line
    end
    -- Round 24: rebuild picks carry the replacement fact in the hint too
    -- (forced rebuilds skip it — "already covered" would be wrong for a
    -- whole-book force, and the state line above already names replacement)
    if pick_rebuild and mode == "extend" and not force_rebuild then
      hint = hint .. " " .. _("Rebuilds from scratch and replaces the current X-Ray (the outgoing version is archived).")
    end
    -- With a checkpoint already built ahead, "update to where I am" can read
    -- as the mechanical/free install (device 2026-08-14) — say plainly that
    -- this pick is a fresh paid request and the built checkpoint stays free
    if mode == "extend" and not pick_rebuild and cr.coverage == "position"
        and (base_progress or 0) > decimal + 0.005 then
      hint = (hint and (hint .. " ") or "")
        .. T(_("Note: this is a fresh AI request; the checkpoint already built to %1% still installs for free as you read past it."),
          math.floor((base_progress or 0) * 100 + 0.5))
    end
    if hint then
      table.insert(vgroup, VerticalSpan:new{ width = Size.padding.small })
      table.insert(vgroup, TextBoxWidget:new{
        text = hint, face = info_face, width = content_width,
        fgcolor = Blitbuffer.COLOR_DARK_GRAY,
      })
    end

    -- Options row (2026-08-25 redesign, ref #90): the two sticky per-book
    -- settings the form can change sit on ONE small-font row right above
    -- the action buttons, always visible, grayed when the current pick
    -- cannot use them. Checkpoint spacing (spacing slice 2026-08-14: picker
    -- writes KEY_XRAY_SPACING; step counts and the auto engine re-resolve
    -- through _xrayLadderSpacing, a change only affects rungs planned from
    -- now on) applies to checkpoint-family picks; categories (presets
    -- v0.21) to picks that START a lineage — a plain extend continues the
    -- artifact's own stamp (categories cannot be added incrementally).
    local sp_now = self_ref:_xrayLadderSpacing()
    local spacing_on = flowing and (cr.delivery == "checkpoints" or cr.delivery == "follow")
    local categories_on = force_rebuild or mode ~= "extend" or pickIsRebuild()
    local cat_value = BookSettings.resolveXrayCategories(self.ui.doc_settings,
      self.settings and self.settings:readSetting("features"))
    local depth_value = BookSettings.resolveXrayDepth(self.ui.doc_settings,
      self.settings and self.settings:readSetting("features"))
    local ButtonTableO = require("ui/widget/buttontable")
    -- The row's header is its FIRST ROW inside the same table (maintainer
    -- 2026-08-25: a floating label above the frame read as part of the hint
    -- text); the buttons below show VALUES only, and every dial stays in place
    -- grayed when the current pick cannot use it (the form's standing rule).
    local option_buttons = {}
    option_buttons[#option_buttons + 1] = {
          text = T(_("Every %1%…"), self_ref:_xraySpacingPctLabel(sp_now)),
          font_size = 16, font_bold = false,
          enabled = spacing_on,
          callback = function()
            UIManager:close(current_dialog)
            self_ref:_showXraySpacingPicker{
              current = sp_now,
              override = self_ref.ui and self_ref.ui.doc_settings
                and require("koassistant_book_settings").xraySpacingOverride(
                  self_ref.ui.doc_settings) or nil,
              title = _("Checkpoint spacing for this book:"),
              count_for = function(s)
                local rungs = XrayAuto.planBuildRungs(
                  (mode == "extend" and not pickIsRebuild()) and base_progress or 0,
                  s, goalFor(), decimal)
                return #rungs
              end,
              on_pick = function(s)
                if self_ref.ui and self_ref.ui.doc_settings then
                  self_ref:_openBookDS():saveSetting(
                    require("koassistant_book_settings").KEY_XRAY_SPACING, s)
                  self_ref:_openBookDS():flush()
                  -- A sticky per-book write must never be silent — a stray
                  -- tap on "Every 50%" here is how the 2026-08-14 device
                  -- round ended up planning one giant rung to 100%
                  UIManager:show(Notification:new{
                    text = T(_("Checkpoint spacing for this book: every %1%"),
                      self_ref:_xraySpacingPctLabel(s)),
                  })
                end
                fixDelivery()
                buildAndShow()
              end,
              on_reset = function()
                if self_ref.ui and self_ref.ui.doc_settings then
                  self_ref:_openBookDS():saveSetting(
                    require("koassistant_book_settings").KEY_XRAY_SPACING, nil)
                  self_ref:_openBookDS():flush()
                  UIManager:show(Notification:new{
                    text = T(_("Checkpoint spacing for this book: recommended (every %1%)"),
                      self_ref:_xraySpacingPctLabel(self_ref:_xrayLadderSpacing())),
                  })
                end
                fixDelivery()
                buildAndShow()
              end,
              on_back = function() buildAndShow() end,
            }
          end,
      }
    option_buttons[#option_buttons + 1] = {
      text = BookSettings.xrayCategoriesLabel(cat_value) .. "…",
      font_size = 16, font_bold = false,
      enabled = categories_on,
      callback = function()
        UIManager:close(current_dialog)
        BookSettings.showXrayCategoriesPicker({
          ui = self_ref.ui, plugin = self_ref,
          on_close = function() buildAndShow() end,
        })
      end,
    }
    option_buttons[#option_buttons + 1] = {
      text = BookSettings.xrayDepthLabel(depth_value) .. "…",
      font_size = 16, font_bold = false,
      enabled = categories_on,
      callback = function()
        UIManager:close(current_dialog)
        BookSettings.showXrayDepthPicker({
          ui = self_ref.ui, plugin = self_ref, target_override = "book",
          on_close = function() buildAndShow() end,
        })
      end,
    }
    local options_row = ButtonTableO:new{
      width = content_width,
      buttons = {
        {{ text = _("Checkpoint spacing, categories, depth:"),
           font_size = 16, font_bold = false, enabled = false }},
        option_buttons,
      },
      zero_sep = true,
      show_parent = self_ref,
    }
    table.insert(vgroup, VerticalSpan:new{ width = Size.padding.small })
    table.insert(vgroup, options_row)

    table.insert(vgroup, VerticalSpan:new{ width = Size.padding.default })
    local action_buttons = ButtonTable:new{
      width = content_width,
      buttons = {{
        {
          text = _("Cancel"),
          callback = function() UIManager:close(current_dialog) end,
        },
        {
          text = (mode == "rebuild" or pick_rebuild) and _("Rebuild")
            or mode == "extend" and _("Extend")
            or _("Create"),
          -- Idle follow pick: nothing to start — the commit button is what
          -- disables (round 12; the row itself stays selectable and black)
          enabled = not (cr.delivery == "follow" and followIdle()),
          callback = function()
            UIManager:close(current_dialog)
            dispatch()
          end,
        },
      }},
      zero_sep = true,
      show_parent = current_dialog,
    }
    table.insert(vgroup, CenterContainer:new{
      dimen = Geom:new{ w = content_width, h = action_buttons:getSize().h },
      action_buttons,
    })
    table.insert(vgroup, VerticalSpan:new{ width = Size.padding.default })

    -- Stock radio-picker composition (same fix as _showUnifiedActionPopup,
    -- polish round 2026-08-14): frame padding 0, content column centered
    local widget_frame = FrameContainer:new{
      radius = Size.radius.window,
      padding = 0,
      margin = 0,
      background = Blitbuffer.COLOR_WHITE,
      VerticalGroup:new{
        align = "left",
        title_bar,
        CenterContainer:new{
          dimen = Geom:new{ w = dialog_width, h = vgroup:getSize().h },
          vgroup,
        },
      },
    }
    local movable = MovableContainer:new{ widget_frame }
    -- Top-anchor on rebuilds (same trick as _showUnifiedActionPopup): no
    -- vertical jump as rows change between selections. Round 2 (device): a
    -- pick can grow the form well past the first frame's height, pushing the
    -- bottom off screen — clamp the offset so the bottom edge stays visible
    -- (and the top never leaves the screen either).
    local frame_h = widget_frame:getSize().h
    if not first_frame_h then first_frame_h = frame_h end
    local y_off = math.floor((frame_h - first_frame_h) / 2)
    local top = math.floor((screen_height - frame_h) / 2) + y_off
    local overflow = top + frame_h - screen_height
    if overflow > 0 then
      y_off = y_off - overflow
      top = top - overflow
    end
    if top < 0 then y_off = y_off - top end
    movable:setMovedOffset({ x = 0, y = y_off })

    local InputContainer = require("ui/widget/container/inputcontainer")
    current_dialog = InputContainer:new{
      dimen = Geom:new{ x = 0, y = 0, w = screen_width, h = screen_height },
      CenterContainer:new{
        dimen = Geom:new{ w = screen_width, h = screen_height },
        movable,
      },
    }
    current_dialog.ges_events = {
      TapClose = { GestureRange:new{
        ges = "tap",
        range = Geom:new{ w = screen_width, h = screen_height },
      }},
    }
    function current_dialog:onTapClose(arg, ges_ev)
      if ges_ev.pos:notIntersectWith(widget_frame.dimen) then
        UIManager:close(self)
      end
      return true
    end
    function current_dialog:onCloseWidget()
      UIManager:setDirty(nil, function() return "ui", widget_frame.dimen end)
    end
    function current_dialog:onShow()
      UIManager:setDirty(self, function() return "ui", widget_frame.dimen end)
    end
    UIManager:show(current_dialog)
  end

  buildAndShow()
end

--- The "follow as I read" pick: per-book Automatic X-Ray ON, then the shared
--- engine start (round 21/22: establishment = intro + missing checkpoints to
--- the reader's position + one ahead, each installing as built; a large
--- catch-up names its cost first).
function AskGPT:_enableXrayFollowForBook(decimal, opts)
  if not self.ui or not self.ui.doc_settings then return end
  local BookSettings = require("koassistant_book_settings")
  -- "on" string, NOT boolean true (round-19 bug fix): the P1 tri-state resolver
  -- honors a legacy boolean only for migrated users (_xray_auto_legacy_optin),
  -- so a boolean write here was INERT for everyone else
  self:_openBookDS():saveSetting(BookSettings.KEY_XRAY_AUTO, "on")
  self:_openBookDS():flush()
  self:_refreshXrayAutoState()
  self:_xrayFollowCatchUp(decimal, opts)
end

--- Size of the establishment chain the engine would run right now: intro +
--- missing checkpoints to the position + one ahead. Mirrors the fire path's
--- planning exactly (planAutoWork + shared grid + truncation). nil when
--- nothing would build. opts.rebuild (deferred rebuild): from-scratch plan,
--- ignoring the disk lineage entirely (no intro — rebuild chains skip it).
function AskGPT:_xrayEstablishmentSteps(opts)
  if not self.ui or not self.ui.document or not self.ui.document.file
      or not self.ui.doc_settings then return nil end
  local doc_info = self.ui.document.info
  if not doc_info or doc_info.has_pages then return nil end
  local XrayAuto = require("koassistant_xray_auto")
  local ActionCache = require("koassistant_action_cache")
  local XrayParser = require("koassistant_xray_parser")
  local BookSettings = require("koassistant_book_settings")
  local file = self.ui.document.file
  local progress = require("koassistant_context_extractor"):new(self.ui):getReadingProgress()
  local decimal = progress and tonumber(progress.decimal)
  if not decimal then return nil end
  local rebuild = opts and opts.rebuild or nil
  local ladder = ActionCache.getXrayLadder(file)
  local work = XrayAuto.planAutoWork{
    entry = ActionCache.get(file, "xray"),
    ladder = ladder,
    base_progress = ActionCache.highestXrayLadderProgress(ladder),
    position = decimal,
    goal = tonumber(self:_openBookDS():readSetting(BookSettings.KEY_XRAY_GOAL)),
    is_json = XrayParser.isJSON,
  }
  if not rebuild and (work.lineage_blocked or not work.build) then return nil end
  local features = self.settings:readSetting("features") or {}
  local spacing = self:_xrayLadderSpacing()
  local boundaries = features.xray_ladder_chapter_snap ~= false
    and self:_ladderChapterBoundaries() or nil
  -- No and/or chain for the base: `rebuild and nil or work.base` folds to
  -- work.base ALWAYS (the tri-state pitfall) — the 2026-08-15 device round's
  -- broken rebuild: the plan started at the OLD ladder top, seedForBuild saw
  -- a non-zero base and refused the position seed, and the chain's only rung
  -- landed ahead of the reader (nothing promotable after the swap)
  local plan_base = nil
  if not rebuild then plan_base = work.base end
  local rungs, labels = self:_planXrayGrid(plan_base,
    spacing, work.goal, decimal, boundaries, rebuild)
  rungs = XrayAuto.truncateToOneAhead(rungs, decimal, labels)
  if #rungs == 0 then return nil end
  return #rungs + ((not rebuild and work.plan_intro) and 1 or 0)
end

--- The follow pick's engine start, shared with the tri-state picker's "On"
--- (round 21, unified engine): an explicit enable stamps the coverage ask
--- (it IS the answer) and immediately establishes the one-ahead invariant —
--- intro + missing checkpoints to the reader's position + one ahead, each
--- installing as built. Round 22 (known gap (c), load-bearing after the D1
--- seed ceiling): a catch-up of more than a few requests names its cost
--- before the chain starts; declining pauses automatic building for this
--- book this session (the setting stays on).
function AskGPT:_xrayFollowCatchUp(_decimal, opts)
  -- An explicit follow choice answers the coverage ask — never re-ask this book
  if self.ui and self.ui.doc_settings then
    self:_openBookDS():saveSetting(
      require("koassistant_book_settings").KEY_XRAY_COVERAGE_ASKED, true)
    self:_openBookDS():flush()
  end
  local XrayAuto = require("koassistant_xray_auto")
  local file = self.ui and self.ui.document and self.ui.document.file
  local rebuild = opts and opts.rebuild or nil
  local self_ref = self
  local function start()
    UIManager:show(Notification:new{
      text = rebuild and _("Automatic X-Ray on: rebuilding as you read.")
        or _("Automatic X-Ray on: building as you read."),
    })
    self_ref:_fireXrayAutoCheckpoints({ notify = true, explicit = true, asked = true,
      rebuild = rebuild })
  end
  local n = self:_xrayEstablishmentSteps(rebuild and { rebuild = true } or nil)
  if n and n > 3 then
    local confirm
    confirm = ButtonDialog:new{
      title = T(_("Automatic X-Ray needs to catch up first: %1 background requests build checkpoints up to your position, plus one ahead. Each covers a bounded slice of the text. Start now?"), n),
      buttons = {
        {{ text = _("Start"), callback = function()
          UIManager:close(confirm)
          start()
        end }},
        {{ text = _("Later (resumes when you reopen this book)"), callback = function()
          UIManager:close(confirm)
          if file then XrayAuto.suppressAuto(file) end
          UIManager:show(InfoMessage:new{
            text = _("Automatic X-Ray stays on. Resume from the X-Ray popup, or it continues next time you open this book."),
            timeout = 4,
          })
        end }},
      },
    }
    UIManager:show(confirm)
    return
  end
  start()
end

--- Round 19/21 ("auto-toggle entry"): turning per-book Automatic X-Ray ON from
--- the tri-state picker starts the engine like the Create form's follow pick —
--- first-ever books get intro + catch-up + one ahead; books with an X-Ray just
--- get their next checkpoint ahead.
function AskGPT:_onXrayAutoTurnedOn()
  if not self.ui or not self.ui.document or not self.ui.document.file then return end
  local doc_info = self.ui.document.info
  if not doc_info or doc_info.has_pages then return end
  self:_xrayFollowCatchUp()
end

--- Show name input for a Section X-Ray, then trigger generation.
--- @param action table: The base xray action definition
--- @param entry table: TOC entry { title, start_page, end_page, depth }
function AskGPT:_showSectionXrayNameInput(action, entry)
  local InputDialog = require("ui/widget/inputdialog")
  local ActionCache = require("koassistant_action_cache")
  local Actions = require("prompts/actions")
  local self_ref = self

  -- Default name: full TOC title, with truncated parent for sub-chapters
  local default_name = entry.title or ""
  if entry.parent_title and entry.parent_title ~= "" then
    local parent = entry.parent_title
    if #parent > 15 then parent = parent:sub(1, 15) .. "…" end
    default_name = parent .. " > " .. default_name
  end

  local input_dialog
  input_dialog = InputDialog:new{
    title = _("Section X-Ray Name"),
    description = T(_("Pages %1–%2"),
        self.ui.document.getPageNumberInFlow and self.ui.document:getPageNumberInFlow(entry.start_page) or entry.start_page,
        self.ui.document.getPageNumberInFlow and self.ui.document:getPageNumberInFlow(entry.end_page) or entry.end_page),
    input = default_name,
    input_hint = _("Enter a name for this Section X-Ray"),
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
          text = _("Generate"),
          is_enter_default = true,
          callback = function()
            local label = input_dialog:getInputText()
            if not label or label == "" then
              UIManager:show(InfoMessage:new{ text = _("Please enter a name."), timeout = 2 })
              return
            end
            -- Truncate to 80 chars (menus truncate display naturally)
            if #label > 80 then label = label:sub(1, 80) end
            UIManager:close(input_dialog)

            -- Sanitize cache key: strip colons (separator conflict)
            local cache_label = label:gsub(":", "-")

            -- Check for duplicate
            local file = self_ref.ui and self_ref.ui.document and self_ref.ui.document.file
            local cache_key = ActionCache.SECTION_XRAY_PREFIX .. cache_label
            if file and ActionCache.get(file, cache_key) then
              local confirm_dialog
              confirm_dialog = ButtonDialog:new{
                title = T(_("A Section X-Ray named '%1' already exists. Replace it?"), label),
                buttons = {
                  {{
                    text = _("Replace"),
                    callback = function()
                      UIManager:close(confirm_dialog)
                      self_ref:_generateSectionXray(action, entry, label, cache_label)
                    end,
                  }},
                  {{
                    text = _("Cancel"),
                    callback = function()
                      UIManager:close(confirm_dialog)
                    end,
                  }},
                },
              }
              UIManager:show(confirm_dialog)
            else
              self_ref:_generateSectionXray(action, entry, label, cache_label)
            end
          end,
        },
      },
    },
  }
  UIManager:show(input_dialog)
  input_dialog:onShowKeyboard()
end

--- Build section scope metadata from a TOC entry.
--- Extracts XPointers for font-size-independent storage (EPUB only), computes page summary.
--- @param entry table TOC entry { start_page, end_page }
--- @param label string Display label
--- @param cache_label string Sanitized label (no colons)
--- @param prefix string Section prefix (e.g., ActionCache.SECTION_XRAY_PREFIX)
--- @return table scope { label, cache_label, start_page, end_page, start_xpointer, end_xpointer, page_summary, cache_key }
function AskGPT:_buildSectionScope(entry, label, cache_label, prefix)
  local vis_start = entry.start_page
  local vis_end = entry.end_page
  if self.ui.document.getPageNumberInFlow then
    vis_start = self.ui.document:getPageNumberInFlow(entry.start_page)
    vis_end = self.ui.document:getPageNumberInFlow(entry.end_page)
  end
  local page_summary = T(_("pp %1–%2"), vis_start, vis_end)

  -- Extract XPointers for font-size-independent storage (EPUB only; nil for PDF)
  local raw_total = self.ui.document.info.number_of_pages or 0
  local visible_total = raw_total
  if self.ui.document.hasHiddenFlows and self.ui.document:hasHiddenFlows() then
    for page = raw_total, 1, -1 do
      if self.ui.document:getPageFlow(page) == 0 then
        visible_total = page
        break
      end
    end
  end
  local start_xp, end_xp
  if self.ui.document.getPageXPointer then
    start_xp = self.ui.document:getPageXPointer(entry.start_page)
    if entry.end_page < visible_total then
      end_xp = self.ui.document:getPageXPointer(entry.end_page + 1)
    end
  end

  return {
    label = label,
    cache_label = cache_label,
    start_page = entry.start_page,
    end_page = entry.end_page,
    start_xpointer = start_xp,
    end_xpointer = end_xp,
    page_summary = page_summary,
    cache_key = prefix .. cache_label,
  }
end

--- Generate a Section X-Ray for the given entry.
--- @param action table: The base xray action definition
--- @param entry table: TOC entry { title, start_page, end_page }
--- @param label string: Display label for the section
--- @param cache_label string: Sanitized label for cache key
function AskGPT:_generateSectionXray(action, entry, label, cache_label)
  local Actions = require("prompts/actions")
  local ActionCache = require("koassistant_action_cache")

  local scope = self:_buildSectionScope(entry, label, cache_label, ActionCache.SECTION_XRAY_PREFIX)

  -- Clone the xray action and override for section behavior
  local section_action = {}
  for k, v in pairs(action) do section_action[k] = v end

  section_action.id = "section_xray"
  section_action.prompt = Actions.buildSectionXrayPrompt(label, scope.page_summary)
  section_action.doi_prompt = Actions.buildSectionXrayPrompt(label, scope.page_summary, true)
  section_action.complete_prompt = nil
  section_action.doi_complete_prompt = nil
  section_action.update_prompt = nil
  section_action.doi_update_prompt = nil
  section_action.use_reading_progress = false
  section_action.use_response_caching = false
  section_action.cache_as_xray = false
  section_action._section_scope = scope

  self:_executeBookLevelActionDirect(section_action, "section_xray", { section_xray = scope })
end

--- Execute a generic section action (non-X-Ray).
--- Builds scope metadata, clones the action for section behavior, and executes.
--- @param action table The action definition
--- @param action_id string The action ID (e.g., "key_arguments")
--- @param entry table TOC entry { title, start_page, end_page }
--- @param label string Display label for the section
--- @param opts table|nil { source_mode = string,
---   read_so_far = boolean,  -- "Up to current position" framing (label = the position)
---   section_so_far = { section = string, position = string } | nil,  -- start→position framing
---     (quiz "Current chapter so far" preset + generic "From section… (to current position)")
--- } for source_selection actions
function AskGPT:_executeSectionAction(action, action_id, entry, label, opts)
  local ActionCache = require("koassistant_action_cache")

  local cache_label = label:gsub(":", "-")
  local prefix = ActionCache.getSectionPrefix(action_id)

  -- Build scope (or lightweight scope for non-cacheable actions)
  local scope
  if prefix then
    scope = self:_buildSectionScope(entry, label, cache_label, prefix)
  else
    -- Section action without cache prefix: build scope without cache key
    local vis_sp = self.ui.document.getPageNumberInFlow
        and self.ui.document:getPageNumberInFlow(entry.start_page) or entry.start_page
    local vis_ep = self.ui.document.getPageNumberInFlow
        and self.ui.document:getPageNumberInFlow(entry.end_page) or entry.end_page
    scope = {
      label = label,
      start_page = entry.start_page,
      end_page = entry.end_page,
      page_summary = T(_("pp %1–%2"), vis_sp, vis_ep),
    }
  end

  -- Clone the action and override for section behavior
  local section_action = {}
  for k, v in pairs(action) do section_action[k] = v end

  section_action.update_prompt = nil
  section_action.use_reading_progress = false
  section_action.use_response_caching = false
  -- Document cache actions: disable document-level cache writes (section saves via _section_scope)
  section_action.cache_as_summary = false
  section_action.cache_as_analyze = false
  section_action._section_scope = scope

  -- Inject section scope context into the prompt
  if section_action.prompt then
    -- To-position actions ({book_text...}, e.g. recap) executed with a section scope: swap to
    -- the full-document placeholders — those are the ones _section_scope range-bounds in the
    -- extractor (same idiom as buildSectionXrayPrompt's __TEXT_SECTION__ swap).
    section_action.prompt = section_action.prompt
        :gsub("{book_text_section}", "{full_document_section}")
        :gsub("{book_text}", "{full_document}")
    local scope_line
    if opts and opts.read_so_far then
      -- Read-so-far framing: scope everything to the reader's current position and make the spoiler
      -- boundary explicit. Phrased to hold in both modes — when text is extracted (it ends at this
      -- point) and when the model works from its own knowledge (recap-style instruction boundary).
      -- Position is the reading percentage only (like recap): a TOC-title pick is level-ambiguous
      -- (deepest heading, or the parent on shared-start pages) and edition-dependent, so it's an
      -- unreliable boundary signal; the percentage is sufficient and predictable.
      scope_line = string.format(
          'This concerns "{title}"{author_clause} only up to the reader\'s current position (%s).\nCover only material up to this point — do not use, reference, or reveal anything beyond it (no later events, results, or conclusions).\n\n',
          label)
    elseif opts and opts.section_so_far then
      -- Section-so-far framing (flexible scope phase 1): section boundary + spoiler boundary
      -- in one. Used by the quiz "Current chapter so far" preset AND the generic "From
      -- section… (to current position)" scope. Phrased to hold in both source modes —
      -- extracted text ends at the position; AI-knowledge mode gets an instruction boundary
      -- (like read_so_far).
      scope_line = string.format(
          'This concerns the section "%s" of "{title}"{author_clause}, and only up to the reader\'s current position (%s of the whole work).\nCover only material up to this point — do not use, reference, or reveal anything beyond it (no later events, results, or conclusions).\n\n',
          opts.section_so_far.section, opts.section_so_far.position)
      -- The section pipeline forces {reading_progress} to 100% (the _full_document_xray
      -- progress override) — pre-resolve it with the real position so prompts that reference
      -- it (e.g. recap's "No spoilers beyond {reading_progress}") stay true.
      section_action.prompt = section_action.prompt:gsub("{reading_progress}",
          function() return opts.section_so_far.position end)
    else
      scope_line = string.format(
          'This is a section of "{title}"{author_clause}.\nSection: "%s" (%s)\nFocus your analysis on this section only.\n\n',
          label, scope.page_summary)
    end
    section_action.prompt = scope_line .. section_action.prompt
  end

  local exec_opts = { section_scope = scope }
  if opts and opts.source_mode then
    exec_opts.source_mode = opts.source_mode
  elseif action.source_selection then
    -- Section actions for source_selection actions default to full_text
    -- so {document_context_section} resolves with the extracted section text
    exec_opts.source_mode = "full_text"
  end

  self:_executeBookLevelActionDirect(section_action, action_id, exec_opts)
end

--- Show name input for a section action, with duplicate check, then execute or confirm.
--- @param action table The action definition
--- @param action_id string The action ID
--- @param entry table TOC entry { title, start_page, end_page }
--- @param opts table|nil { source_mode = string, action_label = string, on_confirm = function(label) }
---   When on_confirm is provided, calls it with the confirmed name instead of executing.
function AskGPT:_showSectionNameInput(action, action_id, entry, opts)
  local InputDialog = require("ui/widget/inputdialog")
  local ActionCache = require("koassistant_action_cache")
  local ButtonDialog = require("ui/widget/buttondialog")
  local self_ref = self

  local action_label = (opts and opts.action_label) or action.text or action_id
  local on_confirm = opts and opts.on_confirm
  local default_name = entry.title or ""
  -- Prepend truncated parent title for sub-chapters (disambiguation)
  if entry.parent_title and entry.parent_title ~= "" then
    local parent = entry.parent_title
    if #parent > 15 then parent = parent:sub(1, 15) .. "…" end
    default_name = parent .. " > " .. default_name
  end

  local function onNameConfirmed(label)
    if on_confirm then
      on_confirm(label)
    else
      self_ref:_executeSectionAction(action, action_id, entry, label, opts)
    end
  end

  local input_dialog
  input_dialog = InputDialog:new{
    title = _("Name this section"),
    description = T(_("%1 · Pages %2–%3"), action_label,
        self.ui.document.getPageNumberInFlow and self.ui.document:getPageNumberInFlow(entry.start_page) or entry.start_page,
        self.ui.document.getPageNumberInFlow and self.ui.document:getPageNumberInFlow(entry.end_page) or entry.end_page),
    input = default_name,
    input_hint = _("Enter a name for this section"),
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
          text = on_confirm and _("Confirm") or _("Generate"),
          is_enter_default = true,
          callback = function()
            local label = input_dialog:getInputText()
            if not label or label == "" then
              UIManager:show(InfoMessage:new{ text = _("Please enter a name."), timeout = 2 })
              return
            end
            if #label > 80 then label = label:sub(1, 80) end
            UIManager:close(input_dialog)

            local cache_label = label:gsub(":", "-")
            local prefix = ActionCache.getSectionPrefix(action_id)
            if not prefix then return end
            local cache_key = prefix .. cache_label
            local file = self_ref.ui and self_ref.ui.document and self_ref.ui.document.file

            if file and ActionCache.get(file, cache_key) then
              -- Name-based duplicate: same name exists, offer to replace
              local confirm_dialog
              confirm_dialog = ButtonDialog:new{
                title = T(_("A section '%1' already exists for %2. Replace it?"), label, action_label),
                buttons = {
                  {{
                    text = _("Replace"),
                    callback = function()
                      UIManager:close(confirm_dialog)
                      onNameConfirmed(label)
                    end,
                  }},
                  {{
                    text = _("Cancel"),
                    callback = function()
                      UIManager:close(confirm_dialog)
                    end,
                  }},
                },
              }
              UIManager:show(confirm_dialog)
            else
              -- Scope-based duplicate: different name but same page range — replace old entry
              local doc = self_ref.ui and self_ref.ui.document
              local scope_match = file and doc and entry.start_page and entry.end_page
                  and ActionCache.findBestSectionForScope(file, doc, prefix, entry.start_page, entry.end_page)
              if scope_match and scope_match.key ~= cache_key then
                local confirm_dialog
                confirm_dialog = ButtonDialog:new{
                  title = T(_("A %1 for this page range already exists: \"%2\". Replace it?"), action_label, scope_match.label),
                  buttons = {
                    {{
                      text = _("Replace"),
                      callback = function()
                        UIManager:close(confirm_dialog)
                        -- Delete old entry (different name, same scope)
                        ActionCache.clear(file, scope_match.key)
                        onNameConfirmed(label)
                      end,
                    }},
                    {{
                      text = _("Cancel"),
                      callback = function()
                        UIManager:close(confirm_dialog)
                      end,
                    }},
                  },
                }
                UIManager:show(confirm_dialog)
              else
                onNameConfirmed(label)
              end
            end
          end,
        },
      },
    },
  }
  UIManager:show(input_dialog)
  input_dialog:onShowKeyboard()
end

--- Show a list popup of existing sections for any action type.
--- @param action table The action definition
--- @param action_id string The action ID
function AskGPT:_showSectionList(action, action_id)
  local ActionCache = require("koassistant_action_cache")
  local ButtonDialog = require("ui/widget/buttondialog")

  local file = self.ui and self.ui.document and self.ui.document.file
  if not file then return end

  local prefix = ActionCache.getSectionPrefix(action_id)
  if not prefix then return end

  local sections = ActionCache.getSections(file, prefix)
  if #sections == 0 then
    UIManager:show(InfoMessage:new{ text = _("No sections found."), timeout = 2 })
    return
  end

  local doc = self.ui and self.ui.document
  local self_ref = self
  local section_dialog
  local buttons = {}
  local action_name = action.text or action_id
  for _idx, sec in ipairs(sections) do
    local detail_parts = {}
    local page_summary = ActionCache.reconvertPageSummary(sec.data, doc)
    if page_summary and page_summary ~= "" then
      table.insert(detail_parts, page_summary)
    end
    local rel_time = formatRelativeTime(sec.data.timestamp)
    if rel_time ~= "" then
      table.insert(detail_parts, rel_time)
    end
    local detail = #detail_parts > 0 and (" (" .. table.concat(detail_parts, ", ") .. ")") or ""

    table.insert(buttons, {{
      text = sec.label .. detail,
      callback = function()
        UIManager:close(section_dialog)
        self_ref:viewCachedAction(action, action_id, sec.data, {
          section_key = sec.key,
          section_label = sec.label,
        })
      end,
      hold_callback = function()
        UIManager:close(section_dialog)
        -- Delete section on hold
        local confirm
        confirm = ButtonDialog:new{
          title = T(_("Delete section '%1'?"), sec.label),
          buttons = {
            {{
              text = _("Delete"),
              callback = function()
                UIManager:close(confirm)
                ActionCache.clear(file, sec.key)
                self_ref:_showSectionList(action, action_id)
              end,
            }},
            {{
              text = _("Cancel"),
              callback = function()
                UIManager:close(confirm)
              end,
            }},
          },
        }
        UIManager:show(confirm)
      end,
    }})
  end

  table.insert(buttons, {{
    text = _("Cancel"),
    callback = function()
      UIManager:close(section_dialog)
    end,
  }})

  local group_name = ActionCache.getSectionGroupName(action_id) or action_name
  section_dialog = ButtonDialog:new{
    title = string.format("%s (%d)", group_name, #sections),
    buttons = buttons,
  }
  UIManager:show(section_dialog)
end

--- Show a list popup of all section X-Rays for the current book.
--- @param opts table|nil: Optional { file, book_title, book_author } for file browser context
function AskGPT:_showSectionXrayList(opts)
  local ActionCache = require("koassistant_action_cache")
  local ButtonDialog = require("ui/widget/buttondialog")

  local file = (self.ui and self.ui.document and self.ui.document.file) or (opts and opts.file)
  if not file then return end

  local sections = ActionCache.getSectionXrays(file)
  if #sections == 0 then
    UIManager:show(InfoMessage:new{ text = _("No Section X-Rays found."), timeout = 2 })
    return
  end

  -- Reconvert XPointers to current pages if book is open (font-size independence)
  local doc = self.ui and self.ui.document

  local self_ref = self
  local section_dialog
  local buttons = {}
  for _idx, sec in ipairs(sections) do
    local detail_parts = {}
    local page_summary = ActionCache.reconvertPageSummary(sec.data, doc)
    if page_summary then
      table.insert(detail_parts, page_summary)
    end
    local rel_time = formatRelativeTime(sec.data.timestamp)
    if rel_time ~= "" then
      table.insert(detail_parts, rel_time)
    end
    -- T15: this section's content was folded into the main X-Ray
    if sec.data.merged_to_main then
      table.insert(detail_parts, _("merged"))
    end
    local detail = #detail_parts > 0 and (" (" .. table.concat(detail_parts, ", ") .. ")") or ""

    table.insert(buttons, {{
      text = sec.label .. detail,
      callback = function()
        UIManager:close(section_dialog)
        self_ref:showCacheViewer({
          name = T(_("Section X-Ray: %1"), sec.label),
          key = sec.key,
          data = sec.data,
          file = file,
          book_title = opts and opts.book_title,
          book_author = opts and opts.book_author,
        })
      end,
      hold_callback = function()
        UIManager:close(section_dialog)
        self_ref:_showSectionXrayOptions(sec, file, opts)
      end,
    }})
  end

  -- Merge engine entry (§6 slice 3, #90): sections → main / combined span
  table.insert(buttons, {{
    text = _("Merge section X-Rays…"),
    callback = function()
      UIManager:close(section_dialog)
      self_ref:_startSectionXrayMergeFlow(file, opts)
    end,
  }})

  table.insert(buttons, {{
    text = _("Cancel"),
    callback = function()
      UIManager:close(section_dialog)
    end,
  }})

  section_dialog = ButtonDialog:new{
    title = T(_("View Section X-Rays (%1)"), #sections),
    buttons = buttons,
  }
  UIManager:show(section_dialog)
end

--- Merge/fold flow launchers (A2 merge discoverability): the X-Ray popup, the
--- section popups, the group screen and the members popup reach the SAME
--- flows the browser hamburger owns. The wrappers supply what those callers
--- lack — the module configuration — and land the reader on the result
--- (reopen_live). The flows re-read settings and disk truth themselves.
--- opts: { book_title, book_author, close_browser } (all optional)
function AskGPT:_startSectionXrayMergeFlow(file, opts)
  require("koassistant_xray_merge").startFlow({
    file = file, ui = self.ui, plugin = self, configuration = configuration,
    title = opts and opts.book_title, author = opts and opts.book_author,
    close_browser = opts and opts.close_browser,
    reopen_live = true,
  })
end

function AskGPT:_startCrossBookXrayFlow(file, opts)
  require("koassistant_xray_merge").startCrossBookFlow({
    file = file, ui = self.ui, plugin = self, configuration = configuration,
    title = opts and opts.book_title, author = opts and opts.book_author,
    close_browser = opts and opts.close_browser,
    reopen_live = true,
  })
end

function AskGPT:_startXrayDedupFlow(file, opts)
  require("koassistant_xray_dedup").startFlow({
    file = file, ui = self.ui, plugin = self, configuration = configuration,
    title = opts and opts.book_title, author = opts and opts.book_author,
    close_browser = opts and opts.close_browser,
  })
end

--- Post-update dedup ask (round 18, maintainer-approved): after an ATTENDED
--- X-Ray change (manual update/create, manual instant install), scan the
--- installed artifact for duplicate suggestions and offer the review ONCE
--- per pair — offered pairs are remembered in the aliases sidecar
--- (__dedup_offered) and never re-asked; the manual scan stays available.
--- Background builds/promotions never ask (no dialog mid-reading).
function AskGPT:maybeOfferDedupAsk(file)
  if not file then return end
  local self_ref = self
  pcall(function()
    local ActionCache = require("koassistant_action_cache")
    local XrayParser = require("koassistant_xray_parser")
    local XrayDedup = require("koassistant_xray_dedup")
    local entry = ActionCache.getXrayCache(file)
    if not (entry and entry.result) or entry.source_mode == "ai_knowledge" then return end
    local data = XrayParser.parse(entry.result)
    if not data or data.error then return end
    local user_aliases = ActionCache.getUserAliases(file)
    if next(user_aliases) then
      XrayParser.mergeUserAliases(data, user_aliases)
    end
    local never = ActionCache.neverMergePairsFrom(user_aliases)
    local found = XrayDedup.findDuplicates(data, never)
    if not found or #found == 0 then return end
    local offered_set = {}
    for _idx, p in ipairs(ActionCache.dedupOfferedPairsFrom(user_aliases)) do
      local a, b = p[1]:lower(), p[2]:lower()
      if a > b then a, b = b, a end
      offered_set[a .. "\0" .. b] = true
    end
    local fresh = {}
    for _idx, pr in ipairs(found) do
      if type(pr.name_a) == "string" and type(pr.name_b) == "string" then
        local a, b = pr.name_a:lower(), pr.name_b:lower()
        if a > b then a, b = b, a end
        if not offered_set[a .. "\0" .. b] then
          fresh[#fresh + 1] = { pr.name_a, pr.name_b }
        end
      end
    end
    if #fresh == 0 then return end
    -- Stamped at ASK time: one ask per pair, ever — dismissing is an answer
    ActionCache.addDedupOfferedPairs(file, fresh)
    local text
    if #fresh == 1 then
      text = T(_("The updated X-Ray may list the same entity twice: \"%1\" and \"%2\".\n\nReview the suggestion?"),
        fresh[1][1], fresh[1][2])
    else
      text = T(_("The updated X-Ray has %1 possible duplicate entity pairs.\n\nReview the suggestions?"), #fresh)
    end
    local ConfirmBox = require("ui/widget/confirmbox")
    UIManager:show(ConfirmBox:new{
      text = text,
      ok_text = _("Review"),
      ok_callback = function()
        self_ref:_startXrayDedupFlow(file)
      end,
      cancel_text = _("Not now"),
    })
  end)
end

--- Show options (rename/delete) for a section X-Ray.
--- @param sec table: { key, label, data } from getSectionXrays
--- @param file string: Document file path
--- @param opts table|nil: Context opts for re-opening list
function AskGPT:_showSectionXrayOptions(sec, file, opts)
  local ActionCache = require("koassistant_action_cache")
  local ButtonDialog = require("ui/widget/buttondialog")
  local self_ref = self

  local options_dialog
  options_dialog = ButtonDialog:new{
    title = T(_("Section X-Ray: %1"), sec.label),
    buttons = {
      {{
        text = _("Delete"),
        callback = function()
          UIManager:close(options_dialog)
          local confirm_dialog
          confirm_dialog = ButtonDialog:new{
            title = T(_("Delete Section X-Ray: %1?"), sec.label),
            buttons = {
              {{
                text = _("Delete"),
                callback = function()
                  UIManager:close(confirm_dialog)
                  ActionCache.clear(file, sec.key)
                  self_ref._file_dialog_row_cache = { file = nil, rows = nil }
                  UIManager:show(Notification:new{
                    text = T(_("Section X-Ray '%1' deleted"), sec.label),
                    timeout = 2,
                  })
                end,
              }},
              {{
                text = _("Cancel"),
                callback = function()
                  UIManager:close(confirm_dialog)
                  self_ref:_showSectionXrayList(opts)
                end,
              }},
            },
          }
          UIManager:show(confirm_dialog)
        end,
      }},
      {{
        text = _("Cancel"),
        callback = function()
          UIManager:close(options_dialog)
          self_ref:_showSectionXrayList(opts)
        end,
      }},
    },
  }
  UIManager:show(options_dialog)
end

--- Display label for an archived X-Ray version: "43% · 3 days ago"
--- (complete versions show "Complete" instead of a percent).
function AskGPT:_xrayCheckpointLabel(cp)
  local parts = {}
  if cp.intro then
    -- Round 20: premise-only version at progress 0 — "0%" would read as broken
    table.insert(parts, _("Introduction (spoiler-free)"))
  elseif cp.full_document then
    table.insert(parts, _("Complete"))
  elseif cp.progress_decimal then
    table.insert(parts, math.floor(cp.progress_decimal * 100 + 0.5) .. "%")
  end
  if cp.chapter_label then
    -- P3: chapter-snapped rungs name the chapter whose end they cover
    table.insert(parts, T(_("end of %1"), cp.chapter_label))
  end
  -- Round 27 (device: "at this point hallvard has 5 versions, they all just
  -- look the same"): the relative form collapses every version built today
  -- into the word "today" — which is exactly the day you have five of them.
  -- Same day → clock time; older → the relative form, which is what a reader
  -- actually wants at that distance.
  -- Which time this is was ambiguous (device 2026-08-18: "81, 71, 81 from
  -- 02:06, 02:05, 2d ago ... even though the archived ones should be older").
  -- `timestamp` is when the CONTENT was built; the ring is ordered by when it
  -- was ARCHIVED. Showing only the former while sorting by the latter made the
  -- list read as out of order, so an archived row now names both.
  local rel = formatRelativeTime(cp.timestamp)
  if cp.timestamp and os.date("%Y-%m-%d", cp.timestamp) == os.date("%Y-%m-%d") then
    table.insert(parts, T(_("built %1"), os.date("%H:%M", cp.timestamp)))
  elseif rel ~= "" then
    table.insert(parts, T(_("built %1"), rel))
  end
  if cp.edited_at then
    table.insert(parts, _("edited"))
  end
  if cp.archived_at and cp.timestamp and cp.archived_at > cp.timestamp + 60 then
    local arel = formatRelativeTime(cp.archived_at)
    if os.date("%Y-%m-%d", cp.archived_at) == os.date("%Y-%m-%d") then
      table.insert(parts, T(_("archived %1"), os.date("%H:%M", cp.archived_at)))
    elseif arel ~= "" then
      table.insert(parts, T(_("archived %1"), arel))
    end
  end
  if #parts == 0 then
    return _("Unknown")
  end
  return table.concat(parts, " · ")
end

--- Reopen the live X-Ray after an install that closed the browser it was
--- launched from (device round 27: "the installed version doesn't auto open
--- when installed from an open X-Ray's hamburger menu"). Opt-in via
--- opts.reopen_live so the artifact-browser and file-browser routes — where
--- the reader was never looking at an X-Ray — keep landing where they did.
function AskGPT:_reopenLiveXrayAfterInstall(file, opts)
  if not (opts and opts.reopen_live) then return end
  self:_showLiveXray(file, opts)
end

--- Open the book's CURRENT X-Ray, re-read from disk. The landing surface for
--- any flow that retired the browser it ran from (install, cross-book merge) —
--- round 27: "after folding in, the x ray closes; it should probably just
--- refresh". A refresh-in-place is impossible there because the merge is what
--- closed the view; reopening on fresh data is the same result.
function AskGPT:_showLiveXray(file, opts)
  local ActionCache = require("koassistant_action_cache")
  local fresh = ActionCache.getXrayCache(file)
  if not (fresh and fresh.result) then return end
  self:showCacheViewer({
    name = _("X-Ray"),
    key = "_xray_cache",
    data = fresh,
    file = file,
    book_title = opts and opts.book_title,
    book_author = opts and opts.book_author,
  })
end

--- Locate a checkpoint by identity (archived_at + original timestamp) — ring
--- indices can shift if a background update archives a new head while the
--- version card is open, so actions never trust a stale index.
function AskGPT:_findXrayCheckpointIndex(file, cp)
  local ActionCache = require("koassistant_action_cache")
  local ring = ActionCache.getXrayCheckpoints(file)
  for i, e in ipairs(ring) do
    if e.archived_at == cp.archived_at and e.timestamp == cp.timestamp then
      return i
    end
  end
end

--- Browse archived X-Ray versions (#73 browsable history): the pre-overwrite
--- snapshot ring (newest first), then ladder rungs (most complete first —
--- §6 slice 1). For a re-reader whose live X-Ray is ahead of their position,
--- marks the nearest at-or-below version — the spoiler-safe view.
function AskGPT:_showXrayCheckpointList(opts)
  local ActionCache = require("koassistant_action_cache")
  local ButtonDialog = require("ui/widget/buttondialog")

  local file = (self.ui and self.ui.document and self.ui.document.file) or (opts and opts.file)
  if not file then return end

  local ring = ActionCache.getXrayCheckpoints(file)
  local ladder = ActionCache.getXrayLadder(file)
  if #ring == 0 and #ladder == 0 then
    UIManager:show(InfoMessage:new{ text = _("No X-Ray versions."), timeout = 2 })
    return
  end

  local entries = {}
  for _idx, cp in ipairs(ring) do
    entries[#entries + 1] = { cp = cp }
  end
  for i = #ladder, 1, -1 do
    entries[#entries + 1] = { cp = ladder[i], is_rung = true }
  end

  local live = ActionCache.getXrayCache(file)

  -- Re-reader marker: only when this book is open, position is known, and the
  -- live X-Ray is ahead of the reader (the one real spoiler exposure —
  -- xray_ecosystem_plan.md W5). Ring and ladder compete on equal terms.
  local mark_idx, current_progress
  if self.ui and self.ui.document and self.ui.document.file == file then
    local ContextExtractor = require("koassistant_context_extractor")
    current_progress = ContextExtractor:new(self.ui):getReadingProgress()
    if current_progress then
      if live and (live.full_document
          or (live.progress_decimal or 0) > current_progress.decimal + 0.01) then
        local combined = {}
        for _idx, e in ipairs(entries) do combined[#combined + 1] = e.cp end
        mark_idx = ActionCache.nearestCheckpointIndex(combined, current_progress.decimal)
      end
    end
  end

  local self_ref = self
  local list_dialog
  local buttons = {}
  -- Item 40 (maintainer): the CURRENT version is a timeline point too — after
  -- a ring reinstall it appeared nowhere in this list. Skip when it
  -- identity-matches a rung (that row already reads "(current)"). Opens the
  -- normal live X-Ray view, not a read-only version card.
  if live and live.result and not ActionCache.isXrayLadderRung(file, live) then
    table.insert(buttons, {{
      text = self:_xrayCheckpointLabel(live) .. " " .. _("(current)"),
      callback = function()
        UIManager:close(list_dialog)
        if opts and opts.close_browser then opts.close_browser() end
        self_ref:showCacheViewer({
          name = _("X-Ray"),
          key = "_xray_cache",
          data = live,
          file = file,
          book_title = opts and opts.book_title,
          book_author = opts and opts.book_author,
        })
      end,
    }})
  end
  -- Round 27 (device: "we need better sorting and info"): the list is two
  -- different things in sequence — archived snapshots (newest first) and
  -- prepared checkpoints (most complete first) — which is unreadable as one
  -- undifferentiated stack. Dim, disabled section rows say which is which.
  local ring_n = #ring
  for idx, e in ipairs(entries) do
    if idx == 1 and ring_n > 0 then
      table.insert(buttons, {{ text = _("— Archived versions —"), enabled = false }})
    elseif idx == ring_n + 1 then
      table.insert(buttons, {{ text = _("— Prepared checkpoints —"), enabled = false }})
    end
    local row_text = self:_xrayCheckpointLabel(e.cp)
    if e.is_rung then
      row_text = row_text .. " · " .. _("checkpoint")
    end
    -- A rung whose copy IS the live X-Ray (installed via promotion/switch) is
    -- the same content in two roles — say so instead of looking like a
    -- mysterious duplicate (device round 2)
    local row_is_current = e.is_rung and live and live.timestamp == e.cp.timestamp
        and math.abs((tonumber(live.progress_decimal) or -1)
          - (tonumber(e.cp.progress_decimal) or -2)) < 1e-6
    if row_is_current then
      row_text = row_text .. " " .. _("(current)")
    elseif e.is_rung and not e.cp.intro and current_progress
        and (tonumber(e.cp.progress_decimal) or 0) > current_progress.decimal + 0.01 then
      -- Slice 2 (35 E4): posture awareness at a glance — this checkpoint
      -- reaches past the reader (its card offers install behind a confirm)
      row_text = row_text .. " " .. _("(ahead)")
    end
    if idx == mark_idx then
      -- "latest BEFORE your position", not numerically closest: a version ahead
      -- of the reader covers text they haven't re-reached (spoilers)
      row_text = row_text .. " " .. _("(latest before your position)")
    end
    local captured = e
    table.insert(buttons, {{
      text = row_text,
      callback = function()
        UIManager:close(list_dialog)
        if captured.is_rung then
          self_ref:_showXrayLadderRungOptions(captured.cp, opts)
        else
          self_ref:_showXrayCheckpointOptions(captured.cp, opts)
        end
      end,
    }})
  end
  -- Parity with the popup (device round 2): the free switch must be reachable
  -- from every surface that lists the finished 1.0 rung
  if (ActionCache.highestXrayLadderProgress(ladder) or 0) >= 0.995
      and not (live and live.result
        and (live.full_document or live.source_mode == "ai_knowledge"))
      and (not live or (tonumber(live.progress_decimal) or 0) < 0.995) then
    table.insert(buttons, {{
      text = _("Switch to complete version (100%), instant"),
      callback = function()
        UIManager:close(list_dialog)
        if opts and opts.close_browser then opts.close_browser() end
        self_ref:_switchToCompleteXrayRung(opts)
      end,
    }})
  end
  if #ladder > 0 and not require("koassistant_xray_auto").ladderBuild() then
    table.insert(buttons, {{
      text = T(_("Delete checkpoints (%1)…"), #ladder),
      callback = function()
        UIManager:close(list_dialog)
        local function doDelete(confirm_widget)
          UIManager:close(confirm_widget)
          ActionCache.clearXrayLadder(file)
          self_ref._file_dialog_row_cache = { file = nil, rows = nil }
          self_ref:_refreshXrayAutoState()
        end
        -- Round-12 delete honesty (maintainer): the complete version IS the 1.0
        -- rung until installed — a plain delete before switching would silently
        -- discard it. Three states, three messages.
        local has_complete_rung =
          (ActionCache.highestXrayLadderProgress(ladder) or 0) >= 0.995
        local live_complete = live and live.result
          and (live.full_document or (tonumber(live.progress_decimal) or 0) >= 0.995)
        local confirm
        if has_complete_rung and not live_complete then
          confirm = ButtonDialog:new{
            title = T(_("Delete the %1 checkpoints? They include your complete version (100%), which is not installed as your current X-Ray; deleting now discards it."), #ladder),
            buttons = {
              {{
                text = _("Switch to complete version first…"),
                callback = function()
                  UIManager:close(confirm)
                  self_ref:_switchToCompleteXrayRung(opts)
                end,
              }},
              {{
                text = _("Delete all, including the complete version"),
                callback = function() doDelete(confirm) end,
              }},
              {{
                text = _("Cancel"),
                callback = function()
                  UIManager:close(confirm)
                  self_ref:_showXrayCheckpointList(opts)
                end,
              }},
            },
          }
        else
          local detail
          if live_complete then
            detail = _("Your complete X-Ray stays; this deletes only the checkpoints.")
            if live and not live.full_document then
              detail = detail .. " " .. _("It also removes the free \"Switch back to your position\" option.")
            end
          else
            detail = _("The current X-Ray and archived previous versions are not affected.")
          end
          confirm = ButtonDialog:new{
            title = T(_("Delete all %1 checkpoints?"), #ladder) .. "\n" .. detail,
            buttons = {
              {{
                text = _("Delete"),
                callback = function() doDelete(confirm) end,
              }},
              {{
                text = _("Cancel"),
                callback = function()
                  UIManager:close(confirm)
                  self_ref:_showXrayCheckpointList(opts)
                end,
              }},
            },
          }
        end
        UIManager:show(confirm)
      end,
    }})
  end
  table.insert(buttons, {{
    text = _("Cancel"),
    callback = function()
      UIManager:close(list_dialog)
    end,
  }})

  -- "X-Ray Versions", not "Previous": ladder rungs can sit AHEAD of the reader
  local title = _("X-Ray Versions")
  -- 50(f): version surfaces name the posture when it changes behavior — under
  -- FULL the newest checkpoint installs without waiting for the reader
  if #ladder > 0 and self.ui and self.ui.document and self.ui.document.file == file then
    local posture, p_reason = self:_xrayPosture()
    if posture == "full" then
      -- Device round 5: the hold is the reader's deliberate override — name it
      if require("koassistant_book_settings").xrayPromotionHold(self.ui.doc_settings) then
        title = title .. "\n" .. _("X-Ray follows your reading position (your choice). Installing the newest checkpoint switches back to newest-first.")
      else
        title = title .. "\n" .. (p_reason == "research"
          and _("Research mode: the newest checkpoint installs as soon as it is built.")
          or p_reason == "finished"
          and _("Book finished: the newest checkpoint installs as soon as it is built.")
          or _("Spoiler protection is off: the newest checkpoint installs as soon as it is built."))
      end
    end
  end
  if mark_idx and current_progress then
    title = title .. "\n" .. T(_("Reading position: %1"), current_progress.formatted)
  end
  list_dialog = ButtonDialog:new{
    title = title,
    buttons = buttons,
  }
  UIManager:show(list_dialog)
end

--- Options card for one ladder rung: view / install / delete — COPY semantics
--- throughout (§5 decision 10). Round 24: per-rung delete added (maintainer);
--- safe under the unified engine — a missing grid point is re-planned when it
--- is ever needed again. Slice 2 (item 37(a), 35 E3(ii)): manual install —
--- at-or-below the reader it is the same free switch promotion performs;
--- AHEAD of the reader it is a posture choice behind a confirm that names the
--- exposure (non-spoiler readers are first-class, item 33(1)). Intro rungs
--- have no install (premise-only; the engine delivers them when nothing
--- better exists).
function AskGPT:_showXrayLadderRungOptions(rung, opts)
  local ButtonDialog = require("ui/widget/buttondialog")
  local ActionCache = require("koassistant_action_cache")
  local XrayAuto = require("koassistant_xray_auto")
  local self_ref = self
  local file = (self.ui and self.ui.document and self.ui.document.file) or (opts and opts.file)
  if not file then return end
  local label = self:_xrayCheckpointLabel(rung)
  local card
  local buttons = {}
  table.insert(buttons, {{
    text = _("View"),
    callback = function()
      UIManager:close(card)
      -- Viewing opens another X-Ray browser (module-level state) — the
      -- originating browser must close now, not when the list was opened
      if opts and opts.close_browser then opts.close_browser() end
      self_ref:showCacheViewer({
        name = _("X-Ray Version"),
        key = "_xray_cache",
        data = rung,
        file = file,
        book_title = opts and opts.book_title,
        book_author = opts and opts.book_author,
        checkpoint = true,
      })
    end,
  }})
  if not rung.intro then
    local live = ActionCache.getXrayCache(file)
    local is_current = live and live.timestamp == rung.timestamp
      and math.abs((tonumber(live.progress_decimal) or -1)
        - (tonumber(rung.progress_decimal) or -2)) < 1e-6
    if is_current then
      table.insert(buttons, {{ text = _("Installed as your current X-Ray"), enabled = false }})
    elseif XrayAuto.isInFlight() then
      -- Same rationale as the ring card's Restore: an in-flight background
      -- update would lose the race or clobber the result
      table.insert(buttons, {{ text = _("Install (auto-update in progress)"), enabled = false }})
    else
      local pos
      if self.ui and self.ui.document and self.ui.document.file == file then
        local progress = require("koassistant_context_extractor"):new(self.ui):getReadingProgress()
        pos = progress and tonumber(progress.decimal) or nil
      end
      local p = tonumber(rung.progress_decimal) or 0
      local ahead = (pos and p > pos + XrayAuto.LADDER_TOLERANCE) or false
      -- 50(f): posture of the OPEN book only — a card for another book keeps
      -- the conservative track framing (pos is nil there anyway)
      local posture = "track"
      if self.ui and self.ui.document and self.ui.document.file == file then
        posture = self:_xrayPosture()
      end
      -- Under FULL posture an ahead install is the posture's own behavior — no
      -- spoiler confirm. Installing BELOW the newest rung PINS the promotion
      -- hold (device round 5): the book follows the position from then on.
      local spoiler_confirm = ahead and posture ~= "full"
      local below_newest_full = false
      if posture == "full" then
        below_newest_full = (ActionCache.highestXrayLadderProgress(
          ActionCache.getXrayLadder(file)) or 0) > p + XrayAuto.LADDER_TOLERANCE
      end
      local function doInstall()
        local features = self_ref.settings:readSetting("features") or {}
        local ok = ActionCache.promoteXrayLadderRung(file, rung,
          ActionCache.checkpointLimitFromFeatures(features), { manual = true })
        if ok and posture == "full" then
          -- A deliberate install is a promotion preference: below the newest
          -- pins position-following, the newest releases it (item 40 spirit —
          -- deliberate acts win until the next deliberate act)
          local highest = ActionCache.highestXrayLadderProgress(
            ActionCache.getXrayLadder(file)) or 0
          self_ref:_setXrayPromotionHold(file, p < highest - XrayAuto.LADDER_TOLERANCE)
        end
        if ok then
          if opts and opts.close_browser then opts.close_browser() end
          self_ref._file_dialog_row_cache = { file = nil, rows = nil }
          self_ref:_refreshXrayAutoState()
          UIManager:show(Notification:new{
            text = T(_("Checkpoint installed (%1)"), label),
            timeout = 2,
          })
          self_ref:_reopenLiveXrayAfterInstall(file, opts)
          -- §14: every install into live runs the pair-check (stamped once per pair)
          UIManager:scheduleIn(1, function() self_ref:maybeOfferDedupAsk(file) end)
        else
          UIManager:show(InfoMessage:new{ text = _("Install failed. This checkpoint is no longer on disk."), timeout = 3 })
        end
      end
      table.insert(buttons, {{
        text = _("Install as current X-Ray (free)"),
        callback = function()
          UIManager:close(card)
          if spoiler_confirm or pos == nil or below_newest_full then
            local generic_title = T(_("Install the checkpoint from %1 as your current X-Ray? Your current version stays in the version list."), label)
            if below_newest_full then
              generic_title = generic_title .. "\n"
                .. _("Spoiler protection is off, but this pins the X-Ray to follow your reading position for this book. Installing the newest checkpoint switches back.")
            end
            local confirm
            confirm = ButtonDialog:new{
              -- Device round 2026-08-05: name what happens NEXT — with the live
              -- X-Ray ahead of the reader, free position swaps stop engaging, so
              -- without this line the install reads as "checkpoints keep
              -- installing as I reach them"
              title = spoiler_confirm
                and T(_("Install the checkpoint from %1? It reaches past your reading position (%2%), so its entries may mention people and events you have not reached yet. Your current version stays in the version list. Free checkpoint swaps pause until you read past it; the X-Ray popup offers a switch back to your position."),
                  label, math.floor(pos * 100 + 0.5))
                or generic_title,
              buttons = {
                {{
                  text = _("Install"),
                  callback = function()
                    UIManager:close(confirm)
                    doInstall()
                  end,
                }},
                {{
                  text = _("Cancel"),
                  callback = function()
                    UIManager:close(confirm)
                    self_ref:_showXrayLadderRungOptions(rung, opts)
                  end,
                }},
              },
            }
            UIManager:show(confirm)
          else
            doInstall()
          end
        end,
      }})
    end
  end
  table.insert(buttons, {{
    text = _("Delete this checkpoint"),
    callback = function()
      UIManager:close(card)
      -- Deleting the rung that IS the installed X-Ray (same identity test as
      -- the "Installed as your current X-Ray" row) removes only the list
      -- entry — the live copy stays. Say so, and offer the revert the user
      -- almost certainly wants (device finding 2026-08-05). Promote-then-
      -- remove order is load-bearing: while the rung still exists the
      -- outgoing live is rung-guarded out of the ring, so the deleted
      -- version does not resurrect under All versions.
      local live = ActionCache.getXrayCache(file)
      local is_live = live and live.timestamp == rung.timestamp
        and math.abs((tonumber(live.progress_decimal) or -1)
          - (tonumber(rung.progress_decimal) or -2)) < 1e-6
      local revert_rung
      local del_posture = "track"
      if is_live and not XrayAuto.isInFlight() then
        local pos
        local del_hold = false
        if self_ref.ui and self_ref.ui.document and self_ref.ui.document.file == file then
          local progress = require("koassistant_context_extractor"):new(self_ref.ui):getReadingProgress()
          pos = progress and tonumber(progress.decimal) or nil
          del_posture = self_ref:_xrayPosture()
          if del_posture == "full" then
            del_hold = require("koassistant_book_settings").xrayPromotionHold(self_ref.ui.doc_settings)
          end
        end
        local remaining = {}
        for _idx, r in ipairs(ActionCache.getXrayLadder(file)) do
          if not (r.timestamp == rung.timestamp
              and math.abs((tonumber(r.progress_decimal) or -1)
                - (tonumber(rung.progress_decimal) or -2)) < 1e-6) then
            remaining[#remaining + 1] = r
          end
        end
        revert_rung = XrayAuto.pickPromotableRung(remaining, 0, pos,
          { ahead_ok = del_posture == "full" and not del_hold })
      end
      local title_text = T(_("Delete the checkpoint from %1?"), label) .. "\n"
        .. _("If automatic building needs this grid point again, it is rebuilt.")
      if is_live then
        title_text = title_text .. "\n"
          .. _("This checkpoint is currently installed as your X-Ray — deleting it from the list alone keeps it installed.")
      end
      local confirm
      local confirm_rows = {}
      if revert_rung then
        local revert_label = self_ref:_xrayCheckpointLabel(revert_rung)
        table.insert(confirm_rows, {{
          text = T(_("Delete and go back to %1"), revert_label),
          callback = function()
            UIManager:close(confirm)
            local features = self_ref.settings:readSetting("features") or {}
            ActionCache.promoteXrayLadderRung(file, revert_rung,
              ActionCache.checkpointLimitFromFeatures(features), { manual = true })
            ActionCache.removeXrayLadderRung(file, rung)
            -- Device round 5: going back past still-newer rungs is the same
            -- deliberate "by position" pick as the switch — pin the hold so
            -- the next page turn doesn't reinstall what was just left
            if del_posture == "full" then
              local rem_high = ActionCache.highestXrayLadderProgress(
                ActionCache.getXrayLadder(file)) or 0
              if rem_high > (tonumber(revert_rung.progress_decimal) or 0)
                  + XrayAuto.LADDER_TOLERANCE then
                self_ref:_setXrayPromotionHold(file, true)
              end
            end
            self_ref._file_dialog_row_cache = { file = nil, rows = nil }
            self_ref:_refreshXrayAutoState()
            UIManager:show(Notification:new{
              text = T(_("Checkpoint deleted — X-Ray back to %1"), revert_label),
              timeout = 3,
            })
          end,
        }})
      end
      table.insert(confirm_rows, {{
        text = is_live and _("Delete from the list only") or _("Delete"),
        callback = function()
          UIManager:close(confirm)
          ActionCache.removeXrayLadderRung(file, rung)
          self_ref._file_dialog_row_cache = { file = nil, rows = nil }
          self_ref:_refreshXrayAutoState()
          UIManager:show(Notification:new{
            text = T(_("Checkpoint deleted (%1)"), label),
            timeout = 2,
          })
        end,
      }})
      table.insert(confirm_rows, {{
        text = _("Cancel"),
        callback = function()
          UIManager:close(confirm)
          self_ref:_showXrayLadderRungOptions(rung, opts)
        end,
      }})
      confirm = ButtonDialog:new{
        title = title_text,
        buttons = confirm_rows,
      }
      UIManager:show(confirm)
    end,
  }})
  table.insert(buttons, {{
    text = _("Back"),
    callback = function()
      UIManager:close(card)
      self_ref:_showXrayCheckpointList(opts)
    end,
  }})
  card = ButtonDialog:new{
    title = T(_("Checkpoint: %1"), label),
    buttons = buttons,
  }
  UIManager:show(card)
end

--- Options card for one archived X-Ray version: view (read-only), restore
--- (move semantics: the current version takes its ring slot — a restore
--- round-trip never grows the ring), delete.
function AskGPT:_showXrayCheckpointOptions(cp, opts)
  local ActionCache = require("koassistant_action_cache")
  local ButtonDialog = require("ui/widget/buttondialog")
  local XrayAuto = require("koassistant_xray_auto")
  local self_ref = self

  local file = (self.ui and self.ui.document and self.ui.document.file) or (opts and opts.file)
  if not file then return end
  local label = self:_xrayCheckpointLabel(cp)

  local options_dialog
  local buttons = {}
  table.insert(buttons, {{
    text = _("View"),
    callback = function()
      UIManager:close(options_dialog)
      if opts and opts.close_browser then opts.close_browser() end
      self_ref:showCacheViewer({
        name = _("X-Ray Version"),
        key = "_xray_cache",
        data = cp,
        file = file,
        book_title = opts and opts.book_title,
        book_author = opts and opts.book_author,
        checkpoint = true,
      })
    end,
  }})
  if XrayAuto.isInFlight() then
    -- Restoring under an in-flight background update would either lose the
    -- race at its completion or clobber its result — wait it out
    table.insert(buttons, {{ text = _("Install (auto-update in progress)"), enabled = false }})
  else
    -- Item 40: rung installs and ring restores are the same act (a pointer
    -- move) — one language across both cards. Mechanics stay move-semantics
    -- (the current version takes this ring slot).
    table.insert(buttons, {{
      text = _("Install as current X-Ray (free)"),
      callback = function()
        UIManager:close(options_dialog)
        local confirm_dialog
        confirm_dialog = ButtonDialog:new{
          title = T(_("Install the version from %1 as your current X-Ray? Your current version stays in the version list."), label),
          buttons = {
            {{
              text = _("Install"),
              callback = function()
                UIManager:close(confirm_dialog)
                local idx = self_ref:_findXrayCheckpointIndex(file, cp)
                local features = self_ref.settings:readSetting("features") or {}
                local ok = idx and ActionCache.restoreXrayCheckpoint(file, idx,
                    ActionCache.checkpointLimitFromFeatures(features))
                if ok then
                  -- The restore replaced the data an open browser renders
                  if opts and opts.close_browser then opts.close_browser() end
                  self_ref._file_dialog_row_cache = { file = nil, rows = nil }
                  -- Cache progress moved — resync the background pre-filter
                  self_ref:_refreshXrayAutoState()
                  UIManager:show(Notification:new{
                    text = T(_("Version installed (%1)"), label),
                    timeout = 2,
                  })
                  self_ref:_reopenLiveXrayAfterInstall(file, opts)
                else
                  UIManager:show(InfoMessage:new{ text = _("Install failed. This version is no longer archived."), timeout = 3 })
                end
              end,
            }},
            {{
              text = _("Cancel"),
              callback = function()
                UIManager:close(confirm_dialog)
                self_ref:_showXrayCheckpointList(opts)
              end,
            }},
          },
        }
        UIManager:show(confirm_dialog)
      end,
    }})
  end
  table.insert(buttons, {{
    text = _("Delete"),
    callback = function()
      UIManager:close(options_dialog)
      local confirm_dialog
      confirm_dialog = ButtonDialog:new{
        title = T(_("Delete the X-Ray version from %1?"), label),
        buttons = {
          {{
            text = _("Delete"),
            callback = function()
              UIManager:close(confirm_dialog)
              local idx = self_ref:_findXrayCheckpointIndex(file, cp)
              if idx then
                ActionCache.removeXrayCheckpoint(file, idx)
              end
              self_ref:_showXrayCheckpointList(opts)
            end,
          }},
          {{
            text = _("Cancel"),
            callback = function()
              UIManager:close(confirm_dialog)
              self_ref:_showXrayCheckpointList(opts)
            end,
          }},
        },
      }
      UIManager:show(confirm_dialog)
    end,
  }})
  table.insert(buttons, {{
    text = _("Cancel"),
    callback = function()
      UIManager:close(options_dialog)
      self_ref:_showXrayCheckpointList(opts)
    end,
  }})

  options_dialog = ButtonDialog:new{
    title = T(_("X-Ray version: %1"), label),
    buttons = buttons,
  }
  UIManager:show(options_dialog)
end

--- View a cached action result, routing to the appropriate viewer.
--- For actions with cache_as_xray/analyze/summary, uses the document cache viewer.
--- For other cacheable actions (e.g., Recap), shows in ChatGPTViewer simple_view.
--- @param action table: The action definition (or minimal { text = "Name" } for picker use)
--- @param action_id string: The action ID
--- @param cached_entry table: The cached entry from ActionCache.get()
--- @param opts table|nil: Optional overrides { file = path, book_title = title } for file browser context
function AskGPT:viewCachedAction(action, action_id, cached_entry, opts)
  -- Route to document cache viewer for actions that write to document caches
  if action.cache_as_xray then
    local name = "X-Ray"
    local key = "_xray_cache"
    if opts and opts.section_label then
      name = T(_("Section X-Ray: %1"), opts.section_label)
      key = opts.section_key
    end
    local info = { name = name, key = key, data = cached_entry }
    if opts then info.file = opts.file; info.book_title = opts.book_title; info.book_author = opts.book_author end
    self:showCacheViewer(info)
    return
  end
  if action.cache_as_analyze then
    local name = _("Analysis")
    local key = "_analyze_cache"
    if opts and opts.section_label then
      name = T(_("Section Analysis: %1"), opts.section_label)
      key = opts.section_key
    end
    local info = { name = name, key = key, data = cached_entry }
    if opts then info.file = opts.file; info.book_title = opts.book_title; info.book_author = opts.book_author end
    self:showCacheViewer(info)
    return
  end
  if action.cache_as_summary then
    local name = _("Summary")
    local key = "_summary_cache"
    if opts and opts.section_label then
      name = T(_("Section Summary: %1"), opts.section_label)
      key = opts.section_key
    end
    local info = { name = name, key = key, data = cached_entry }
    if opts then info.file = opts.file; info.book_title = opts.book_title; info.book_author = opts.book_author end
    self:showCacheViewer(info)
    return
  end

  -- Look up full action definition if we got a minimal stub (e.g., from artifact browser)
  if action_id and not action.id and self.action_service then
    local full_action = self.action_service:getAction("book", action_id)
    if full_action then
      action = full_action
    end
  end

  -- Interactive quiz: parse cached JSON and open quiz viewer
  if action.interactive_quiz and cached_entry and cached_entry.result then
    local QuizParser = require("koassistant_quiz_parser")
    local parsed = QuizParser.parse(cached_entry.result)
    if parsed and parsed.questions and #parsed.questions > 0 then
      local quiz_book_title = (opts and opts.book_title) or (self.ui and self.ui.doc_props and (self.ui.doc_props.display_title or self.ui.doc_props.title)) or ""
      local quiz_book_author = (opts and opts.book_author) or (self.ui and self.ui.doc_props and self.ui.doc_props.authors) or ""
      local section_label = opts and opts.section_label
      local file = (opts and opts.file) or (self.ui and self.ui.document and self.ui.document.file)
      local cache_key = (opts and opts.section_key) or action_id

      local function openQuizViewer(saved_state)
        local QuizViewer = require("koassistant_quiz_viewer")
        local viewer_opts = {
          quiz_data = parsed,
          opts = {
            title = quiz_book_title,
            chapter = section_label,
            book_author = quiz_book_author,
            ui = self.ui,
            plugin = self,
            document_path = file,
            on_save_notebook = file and function(text)
              local Notebook = require("koassistant_notebook")
              local notebook_path = Notebook.getPath(file)
              if notebook_path then
                Notebook.append(notebook_path, "\n---\n\n" .. text .. "\n")
              end
            end,
            on_save_state = file and function(state)
              local ActionCache = require("koassistant_action_cache")
              ActionCache.updateField(file, cache_key, "quiz_state", state)
            end,
          },
        }
        -- Restore saved state if provided
        if saved_state then
          viewer_opts.answers = saved_state.answers
          viewer_opts.revealed = saved_state.revealed
          viewer_opts.correct = saved_state.correct
          viewer_opts.current_index = saved_state.current_index or 1
          viewer_opts.phase = saved_state.phase or "taking"
        end
        UIManager:show(QuizViewer:new(viewer_opts))
      end

      -- Check for saved quiz state
      local saved_state = cached_entry.quiz_state
      if saved_state then
        local ButtonDialog = require("ui/widget/buttondialog")
        local quiz_dialog
        quiz_dialog = ButtonDialog:new{
          title = _("Quiz"),
          buttons = {
            {{ text = _("Continue / Review"), callback = function()
              UIManager:close(quiz_dialog)
              openQuizViewer(saved_state)
            end }},
            {{ text = _("Take Again"), callback = function()
              UIManager:close(quiz_dialog)
              openQuizViewer(nil)
            end }},
            {{ text = _("Cancel"), callback = function()
              UIManager:close(quiz_dialog)
            end }},
          },
        }
        UIManager:show(quiz_dialog)
      else
        openQuizViewer(nil)
      end
      return
    end
    -- Fallback: JSON parse failed, show raw text in generic viewer below
  end

  -- Generic viewer for per-action caches (e.g., Recap)
  local ChatGPTViewer = require("koassistant_chatgptviewer")
  local action_name = action.text or action_id

  -- Build title (same pattern as showCacheViewer)
  -- Only show progress for incremental actions with partial progress (< 100%)
  local progress_str
  if cached_entry.progress_decimal and cached_entry.progress_decimal < 1.0 then
    progress_str = math.floor(cached_entry.progress_decimal * 100 + 0.5) .. "%"
  end
  local title = action_name
  if opts and opts.section_label then
    title = T(_("Section %1: %2"), action_name, opts.section_label)
  end
  if progress_str then
    title = title .. " (" .. progress_str .. ")"
  end
  -- Book metadata: prefer explicit opts (artifact browser may show a different book)
  -- Fall back to open book's props
  local book_title, book_author
  if opts then
    book_title = opts.book_title
    book_author = opts.book_author
  end
  if not book_title and self.ui then
    local props = self.ui.doc_props
    if props then
      book_title = props.display_title or props.title
      book_author = book_author or props.authors
    end
  end
  if book_title then
    title = title .. " - " .. book_title
  end

  -- Build info popup text (for Info button)
  local info_popup_text = buildInfoPopupText(cached_entry, progress_str)

  -- Build cache metadata for export
  local cache_metadata = {
    cache_type = action_id,
    book_title = book_title,
    book_author = book_author,
    progress_decimal = cached_entry.progress_decimal,
    model = cached_entry.model,
    timestamp = cached_entry.timestamp,
    used_annotations = cached_entry.used_annotations,
    used_book_text = cached_entry.used_book_text,
    scope_label = cached_entry.scope_label,
    scope_page_summary = cached_entry.scope_page_summary,
  }

  -- Delete callback (open book or file browser via opts.file)
  -- Prefer explicit file (artifact browser may pass a different book than the one open)
  local on_delete
  local file = (opts and opts.file) or (self.ui and self.ui.document and self.ui.document.file)
  if file then
    local ActionCache = require("koassistant_action_cache")
    local delete_key = (opts and opts.section_key) or action_id
    local delete_name = (opts and opts.section_label) and title or action_name
    on_delete = function()
      ActionCache.clear(file, delete_key)
      -- Invalidate file browser row cache so deleted artifacts don't reappear
      self._file_dialog_row_cache = { file = nil, rows = nil }
      UIManager:show(require("ui/widget/notification"):new{
        text = T(_("%1 deleted"), delete_name),
        timeout = 2,
      })
    end
  end

  -- Update/Regenerate button (skip for section entries — regenerate via section flow)
  local on_regenerate
  local regenerate_label
  if action.use_response_caching and not (opts and opts.section_key) then
    local self_ref2 = self
    local captured_action_id = action_id
    -- The live-execution branch must only run when the open book IS the artifact's
    -- book: the artifact browser passes another book via opts.file, and
    -- _executeBookLevelActionDirect reads self.ui — regenerating there would rebuild
    -- the OPEN book and overwrite ITS cache (injection_gating_audit). A different
    -- book falls through to the closed-book branch, which honours `file`.
    if self.ui and self.ui.document
        and require("koassistant_doc_settings").samePath(self.ui.document.file, file) then
      -- Open book: regenerate via direct execution (bypass cache popup)
      on_regenerate = function()
        if self_ref2:_checkRequirements(action) then return end
        self_ref2._file_dialog_row_cache = { file = nil, rows = nil }
        if action.source_selection then
          self_ref2:_showUnifiedActionPopup(action, captured_action_id, {
            on_execute = function(popup_state)
              self_ref2:_executeBookLevelActionDirect(action, captured_action_id, { source_mode = popup_state.source })
            end,
          })
        else
          self_ref2:_executeBookLevelActionDirect(action, captured_action_id)
        end
      end
      -- Determine label based on action type and progress
      if action.use_reading_progress then
        local ContextExtractor = require("koassistant_context_extractor")
        local extractor = ContextExtractor:new(self.ui)
        local progress = extractor:getReadingProgress()
        local cached_progress = cached_entry.progress_decimal or 0
        if progress.decimal > cached_progress + 0.01 then
          regenerate_label = T(_("Update to %1"), progress.formatted)
        else
          regenerate_label = _("Redo")
        end
      else
        regenerate_label = _("Regenerate")
      end
    elseif file then
      -- Closed book: regenerate via direct execution (bypass cache popup)
      local Actions = require("prompts/actions")
      if not Actions.requiresOpenBook(action) then
        on_regenerate = function()
          if self_ref2:_checkRequirements(action, file) then return end
          self_ref2:_confirmClosedBookSpoilerRun(action, file, function()
          self_ref2._file_dialog_row_cache = { file = nil, rows = nil }
          -- Set up context flags (same as executeFileBrowserAction)
          -- Required for cache_file resolution in handlePredefinedPrompt
          local bt = book_title or "Unknown"
          local ba = book_author or ""
          configuration.features = configuration.features or {}
          configuration.features.is_general_context = nil
          configuration.features.is_book_context = true
          configuration.features.is_library_context = nil
          configuration.features.book_metadata = buildBookMetadata(bt, ba, file, getRawDocProps(file))
          configuration.features.book_context = bookContextString(configuration.features.book_metadata)
          NetworkMgr:runWhenConnected(function()
            self_ref2:ensureInitialized()
            self_ref2:updateConfigFromSettings()
            local config_copy = {}
            for k, v in pairs(configuration or {}) do
              config_copy[k] = v
            end
            config_copy.features = {}
            for k, v in pairs((configuration or {}).features or {}) do
              config_copy.features[k] = v
            end
            Dialogs.executeDirectAction(self_ref2.ui, action,
                config_copy.features.book_context or "", config_copy, self_ref2)
          end)
          end)
        end
        regenerate_label = _("Regenerate")
      end
    end
  end

  local inline_prefix = buildInlineIndicators(cached_entry, configuration)
  local viewer = ChatGPTViewer:new{
    title = title,
    text = inline_prefix and (inline_prefix .. cached_entry.result) or cached_entry.result,
    _cache_content = cached_entry.result,
    simple_view = true,
    configuration = configuration,
    cache_metadata = cache_metadata,
    cache_type_name = action_name,
    on_delete = on_delete,
    on_regenerate = on_regenerate,
    regenerate_label = regenerate_label,
    _plugin = self,
    _ui = self.ui,
    _info_text = info_popup_text,
    _artifact_file = file,
    _artifact_key = action_id,
    _artifact_book_title = book_title,
    _artifact_book_author = book_author,
    _book_open = (self.ui and self.ui.document ~= nil),
    group_open = self:_inBookGroup(file)
      and function() self:_showGroupMembersPopup(file, "artifacts") end or nil,
    on_launch_chat = self:_buildLaunchChatCallback(file, book_title, book_author, cached_entry.result, action_name),
  }
  UIManager:show(viewer)
end

--- Check if we should show a recap reminder for the current book.
--- Called from onReaderReady when the user opens a book they haven't read in a while.
--- One-shot "turn on Automatic X-Ray?" offer on book open (§7 P4, recap-reminder
--- pattern; opt-in via xray_offer_auto). Fires only when accepting can act
--- immediately: flowing doc, no X-Ray at all, inside the auto-create window,
--- consent already satisfied. Declining sets the per-book tri-state to "off"
--- (the offer only fires while it is unset, so it never re-asks); tapping
--- outside decides nothing and may ask again next open. A ButtonDialog, NOT a
--- ConfirmBox — ConfirmBox fires cancel_callback on ANY close incl. dismiss.
function AskGPT:checkXrayOffer()
  local features = self.settings:readSetting("features") or {}
  if features.xray_offer_auto ~= true then return end
  if not self.ui or not self.ui.document or not self.ui.doc_settings then return end
  local doc_info = self.ui.document.info
  if not doc_info or doc_info.has_pages then return end
  local file = self.ui.document.file
  if not file then return end
  local BookSettings = require("koassistant_book_settings")
  if BookSettings.xrayAutoOverride(self.ui.doc_settings, features) ~= nil then return end
  if BookSettings.resolveXrayAuto(self.ui.doc_settings, features) then return end
  local ActionCache = require("koassistant_action_cache")
  local entry = ActionCache.get(file, "xray")
  if entry and entry.result then return end
  local doc_entry = ActionCache.getXrayCache(file)
  if doc_entry and doc_entry.result then return end
  -- Round 21: no window gate — the engine can act at any position (intro +
  -- catch-up checkpoints), so the offer is valid whenever consent is in place
  local action = self.action_service and self.action_service:getAction("book", "xray")
  if not action then return end
  if not self:_xrayBackgroundConsentOk(action, features) then return end
  local self_ref = self
  local offer
  offer = ButtonDialog:new{
    title = _("This book has no X-Ray yet.") .. "\n"
      .. _("Turn on Automatic X-Ray for this book? It will be created in the background now and kept updated as you read."),
    buttons = {
      {{ text = _("Turn on"), callback = function()
        UIManager:close(offer)
        self_ref:_openBookDS():saveSetting(
          require("koassistant_book_settings").KEY_XRAY_AUTO, "on")
        -- The offer promised a quiet background create — that IS the coverage
        -- answer, so the round-19 ask must not interject a second question
        self_ref:_openBookDS():saveSetting(
          require("koassistant_book_settings").KEY_XRAY_COVERAGE_ASKED, true)
        self_ref:_openBookDS():flush()
        self_ref:_refreshXrayAutoState()
        -- Act now — the deferred fire re-checks every gate from disk truth
        UIManager:scheduleIn(2, function()
          self_ref:_fireXrayAutoCheckpoints({ notify = true, explicit = true, asked = true })
        end)
      end }},
      {{ text = _("Not for this book"), callback = function()
        UIManager:close(offer)
        self_ref:_openBookDS():saveSetting(
          require("koassistant_book_settings").KEY_XRAY_AUTO, "off")
        self_ref:_openBookDS():flush()
      end }},
    },
  }
  UIManager:show(offer)
end

function AskGPT:checkRecapReminder()
  local features = self.settings:readSetting("features") or {}
  if features.enable_recap_reminder ~= true then return end

  if not self.ui or not self.ui.document or not self.ui.doc_settings then return end

  local now = os.time()
  local last_opened = self:_openBookDS():readSetting("koassistant_last_opened")

  -- Retroactive fallback: use sidecar directory mod time for books opened
  -- before this feature existed (sidecar is written on book close)
  if not last_opened then
    local DocSettings = require("docsettings")
    local sidecar_dir = DocSettings:getSidecarDir(self.ui.document.file)
    local attr = lfs.attributes(sidecar_dir)
    if attr and attr.modification then
      last_opened = attr.modification
    end
  end

  -- Always update timestamp for next session
  self:_openBookDS():saveSetting("koassistant_last_opened", now)

  if not last_opened then return end

  local days_since = (now - last_opened) / 86400
  local threshold = features.recap_reminder_days or 7
  if days_since < threshold then return end

  -- Skip if not started or nearly finished
  local percent = self:_openBookDS():readSetting("percent_finished") or 0
  if percent <= 0 or percent > 0.95 then return end

  local days_display = math.floor(days_since)
  local self_ref = self
  local ConfirmBox = require("ui/widget/confirmbox")
  UIManager:show(ConfirmBox:new{
    text = T(_("You haven't read this book in %1 days.\n\nWould you like an AI Recap to help you get back into it?"), days_display),
    ok_text = _("Recap"),
    ok_callback = function()
      self_ref:ensureInitialized()
      self_ref:executeBookLevelAction("recap")
    end,
  })
end

--- Offer a quiz for the book's final chapter at end-of-book — the only place it can fire, since
--- it has no following chapter to cross into. Gated like any chapter quiz. Returns true if a
--- prompt was actually scheduled (so the next-read suggestion yields the end-of-book slot).
function AskGPT:_maybeOfferLastChapterQuiz(features)
  if features.enable_chapter_quiz ~= true then return false end
  if not self.ui or not self.ui.document or not self.ui.toc then return false end
  local toc = self.ui.toc
  if not toc.toc or #toc.toc == 0 then return false end
  local book_quiz = self.ui.doc_settings and self:_openBookDS():readSetting("koassistant_book_quiz")
  self._book_quiz = book_quiz
  if book_quiz and book_quiz.enabled == false then return false end
  self:_ensureQuizChapters(features)
  local indices = self._quiz_chapter_indices
  if not indices or #indices == 0 then return false end
  local last_idx = indices[#indices]
  if self._last_quiz_offered_chapter == last_idx then return false end
  local offered = self:_offerChapterQuiz(last_idx)
  if offered then self._last_quiz_offered_chapter = last_idx end
  return offered
end

--- Called when user reaches the end of a book.
--- Offers a quiz for the final chapter (quiz-first), else suggests a next read.
function AskGPT:onEndOfBook()
  local features = self.settings:readSetting("features") or {}

  -- Quiz-first single-slot: if an eligible last-chapter quiz is offered, it takes the
  -- end-of-book slot and the next-read suggestion yields this once (avoids stacking popups).
  if self:_maybeOfferLastChapterQuiz(features) then return end

  -- Otherwise, suggest a next read (requires library scanning).
  -- Setting defaults to true (opt-out), requires library scanning to be useful
  if features.enable_end_of_book_suggestion == false then return end
  if features.enable_library_scanning ~= true then return end
  if not features.library_scan_folders or #features.library_scan_folders == 0 then return end
  if not self.ui or not self.ui.document then return end

  -- Delay slightly to let KOReader's own end-of-book popup show first
  local self_ref = self
  UIManager:scheduleIn(0.3, function()
    -- The document can close DURING the delay (core end-of-book actions like
    -- "return to file browser" close it synchronously after our event) — the
    -- suggestion flow runs book-level machinery, so bail rather than crash
    if not (self_ref.ui and self_ref.ui.document) then return end
    local ConfirmBox = require("ui/widget/confirmbox")
    UIManager:show(ConfirmBox:new{
      text = _("KOAssistant: Would you like an AI suggestion for what to read next from your library?"),
      ok_text = _("Suggest"),
      ok_callback = function()
        self_ref:ensureInitialized()
        self_ref:executeBookLevelAction("suggest_from_library")
      end,
    })
  end)
end

--- Resolve and cache the chapter-boundary list for the current book + level setting.
--- The resolved chapter TOC indices are structural (font-size independent), so they're cached
--- and recomputed only when the level setting changes (or first call after a book opens).
--- Pages are read live from the TOC each page turn, so pagination changes are handled.
function AskGPT:_ensureQuizChapters(features)
  local setting = (self._book_quiz and self._book_quiz.chapter_depth)
    or (features and features.quiz_chapter_depth) or 2
  if self._quiz_chapter_indices and self._quiz_setting == setting then return end
  self._quiz_setting = setting

  local QuizChapters = require("koassistant_quiz_chapters")
  local toc = self.ui.toc.toc
  if setting == "toc_filter" or setting == "all" then
    -- "All TOC headings": every entry, honoring KOReader's per-depth tick-ignore filter.
    self._quiz_level = "all"
    local ignored = self.ui.toc.toc_ticks_ignored_levels or {}
    local idxs = {}
    for i = 1, #toc do
      if not ignored[toc[i].depth or 1] then idxs[#idxs + 1] = i end
    end
    self._quiz_chapter_indices = idxs
  else
    local level
    if setting == "auto" then
      local min_pages = (self._book_quiz and self._book_quiz.min_pages)
        or (features and features.quiz_min_chapter_pages) or 5
      level = QuizChapters.autoLevel(toc, self.ui.document:getPageCount(), min_pages)
    elseif type(setting) == "number" then
      level = setting
    else
      level = 2
    end
    self._quiz_level = level
    self._quiz_chapter_indices = QuizChapters.chapterIndices(toc, level)
  end
end

--- Content page range [start, end] of a chapter, bounded by the next TOC entry at the same or
--- shallower depth (the quiz scope). Used by the min-pages gate and _runChapterQuiz.
function AskGPT:_chapterContentRange(chapter_index)
  local toc = self.ui.toc.toc
  local chapter = toc[chapter_index]
  if not chapter then return nil end
  local depth = chapter.depth or 1
  local end_page
  for i = chapter_index + 1, #toc do
    if (toc[i].depth or 1) <= depth then
      end_page = toc[i].page - 1
      break
    end
  end
  if not end_page then end_page = self.ui.document:getPageCount() end
  return chapter.page, end_page
end

--- Chapter containing the current page, resolved at the same chapter level as the auto
--- chapter quiz (per-book quiz setting > global > level 2), so the manual "Current chapter"
--- scope presets and the chapter-end trigger agree on what "a chapter" is.
--- @return table|nil { start_page, end_page, current_page, title } (nil = no TOC / front matter)
function AskGPT:_currentChapterInfo()
  if not (self.ui and self.ui.document and self.ui.toc and self.ui.toc.toc and #self.ui.toc.toc > 0) then
    return nil
  end
  local features = self.settings:readSetting("features") or {}
  -- Fresh per-book override read, same as onPageUpdate (consumed by _ensureQuizChapters)
  self._book_quiz = self.ui.doc_settings and self:_openBookDS():readSetting("koassistant_book_quiz")
  self:_ensureQuizChapters(features)
  local indices = self._quiz_chapter_indices
  if not indices or #indices == 0 then return nil end
  local current_page = (self.ui.view and self.ui.view.state and self.ui.view.state.page) or 1
  local QuizChapters = require("koassistant_quiz_chapters")
  local idx = QuizChapters.currentChapter(self.ui.toc.toc, indices, current_page)
  if not idx then return nil end
  local start_page, end_page = self:_chapterContentRange(idx)
  if not start_page then return nil end
  local title = self.ui.toc.toc[idx].title or ""
  if self.ui.toc.cleanUpTocTitle then
    title = self.ui.toc:cleanUpTocTitle(title) or title
  end
  if title == "" then title = T(_("Chapter %1"), idx) end
  return { start_page = start_page, end_page = end_page, current_page = current_page, title = title }
end

--- Reading time (seconds) the user spent in a page range, from KOReader's statistics DB.
--- Flushes volatile in-memory stats first (insertDB self-guards when frozen/disabled), then
--- queries the page_stat view in current pagination. Returns nil when stats are unavailable so
--- the caller can fail open (never block a quiz on missing data).
function AskGPT:_chapterReadingTime(start_page, end_page)
  local stats = self.ui and self.ui.statistics
  if not stats or not start_page or not end_page then return nil end
  local id_book = stats.id_curr_book
  if type(id_book) ~= "number" or id_book <= 0 then return nil end
  if stats.insertDB then pcall(function() stats:insertDB() end) end
  return require("koassistant_stats_reader").getReadingTimeInRange(id_book, start_page, end_page)
end

--- Chapter transition detection for automatic chapter quizzes.
--- Range-based: tracks which chapter (at the resolved level) the current page sits in and
--- offers a quiz for the chapter just finished when you cross forward into the next one.
--- Nested sub-entries never trigger (same chapter); a parent heading is not a chapter.
-- Thin dispatcher: each page-turn feature gets its own handler with its own gates.
-- The quiz handler's whole-handler early return must not shadow other features
-- (xray_background_plan.md §3 wiring note).
function AskGPT:onPageUpdate(pageno)
  self:_quizOnPageUpdate(pageno)
  self:_xrayAutoOnPageUpdate(pageno)
  -- Ambient X-Ray marks (slice 2): scanning INSIDE the dispatch lets the
  -- marks ride the page's own repaint — no extra e-ink refresh. Nil state
  -- short-circuits when marking is off.
  require("koassistant_xray_marks").onPageTurn(self, pageno)
end

function AskGPT:_quizOnPageUpdate(pageno)
  local features = self.settings:readSetting("features") or {}
  if features.enable_chapter_quiz ~= true then return end
  if not self.ui or not self.ui.document or not self.ui.toc then return end
  -- A live search session's next/prev jumps are navigation, not reading —
  -- crossing a chapter boundary there must not offer a quiz (device round
  -- 2026-08-13: walking X-Ray appearance hits triggered it)
  local search_dialog = self.ui.search and self.ui.search.search_dialog
  if search_dialog and UIManager:isWidgetShown(search_dialog) then return end

  -- Per-book quiz overrides, read from the live in-memory doc_settings (a hash lookup, fresh
  -- every page turn). `enabled` is suppress-only (the global gate above already returned for a
  -- globally-disabled quiz). (Key: BookSettings.KEY_QUIZ.)
  local book_quiz = self.ui.doc_settings and self:_openBookDS():readSetting("koassistant_book_quiz")
  self._book_quiz = book_quiz
  if book_quiz and book_quiz.enabled == false then return end

  local toc = self.ui.toc
  if not toc.toc or #toc.toc == 0 then return end

  -- Track page for jump detection (a TOC jump moves many pages; a page turn moves 1-3).
  local prev_page = self._last_quiz_page
  self._last_quiz_page = pageno

  self:_ensureQuizChapters(features)
  local indices = self._quiz_chapter_indices
  if not indices or #indices == 0 then return end

  local QuizChapters = require("koassistant_quiz_chapters")
  local cur_idx = QuizChapters.currentChapter(toc.toc, indices, pageno)

  if cur_idx and cur_idx ~= self._quiz_cur_idx then
    local prev_idx = self._quiz_cur_idx
    self._quiz_cur_idx = cur_idx
    -- Skip TOC jumps (not sequential reading); we still updated the current chapter above.
    if prev_page and math.abs(pageno - prev_page) > 5 then return end
    -- Offer only when moving forward into a later chapter, once per finished chapter, and only
    -- if we were actually in a chapter (prev_idx nil = opened mid-book or finished front matter).
    if prev_idx and (toc.toc[cur_idx].page or 0) > (toc.toc[prev_idx].page or 0)
       and self._last_quiz_offered_chapter ~= prev_idx then
      -- Only offer once we've actually crossed OUT of the finished chapter's content range. For
      -- single-level modes a chapter's range ends right before the next chapter, so this is a no-op.
      -- In "All TOC headings" mode it kills the parent-container misfire: entering a parent's first
      -- child keeps pageno inside the parent's range, so no quiz fires for the parent on descent.
      local _, prev_end = self:_chapterContentRange(prev_idx)
      if prev_end and pageno > prev_end then
        self._last_quiz_offered_chapter = prev_idx
        self:_offerChapterQuiz(prev_idx)
      end
    end
  end
end

-- ========================= X-Ray background auto-update =========================
-- docs/xray_background_plan.md. Per-page work is arithmetic on in-memory state only
-- (self._xray_auto_state); ALL disk truth is re-derived inside the deferred fire.

--- Rebuild the in-memory pre-filter state from disk. Called on onReaderReady, after
--- the scope-popup toggle, and after background completions. It may go stale in
--- between — that can cost at most a wasted schedule, never a wrong request (the
--- fire re-verifies everything from disk).
function AskGPT:_refreshXrayAutoState()
  local prev = self._xray_auto_state
  self._xray_auto_state = nil
  local file = self.ui and self.ui.document and self.ui.document.file
  if not file then return end
  local features = self.settings:readSetting("features") or {}
  local state = { prev_page = prev and prev.prev_page }
  -- §7 P1 tri-state: per-book "on" (bundles create) / "off" / follow-global
  local auto_on, create_allowed = require("koassistant_book_settings")
      .resolveXrayAuto(self.ui.doc_settings, features)
  state.auto_update = self.ui.doc_settings ~= nil and auto_on
  if state.auto_update then
    -- One cache dofile — paid only by opted-in books; default users never hit disk here.
    -- Round 21 (unified engine, plan item 23): the per-page question is the
    -- ONE-AHEAD INVARIANT, not a progress-delta window — state carries what
    -- that check needs (live/rung coverage, goal, lineage), zero-disk per turn.
    local XrayAuto = require("koassistant_xray_auto")
    local ActionCache = require("koassistant_action_cache")
    local XrayParser = require("koassistant_xray_parser")
    local entry = ActionCache.get(file, "xray")
    state.create_allowed = create_allowed
    -- Round 22 (D1): a live INTRO is not "built" — an intro-only book (build
    -- cancelled after its introduction) is still a first spend for the create
    -- guard; the fire path's planAutoWork applies the same rule to has_any
    state.never_built = not (entry and entry.result and not entry.intro)
    if entry and entry.result and not entry.intro then
      if entry.full_document or entry.source_mode == "ai_knowledge"
          or not XrayParser.isJSON(entry.result) then
        -- Different lineage: automation never builds over or beside it
        state.lineage_blocked = true
      else
        state.live_progress = tonumber(entry.progress_decimal)
      end
    end
    local dials = XrayAuto.dialsFromFeatures(features)
    state.cooldown_s = dials.cooldown_s
    state.goal = tonumber(self:_openBookDS():readSetting(
      require("koassistant_book_settings").KEY_XRAY_GOAL)) or nil
    -- Console visibility while testing: log per-turn gate declines when debug is on
    state.debug = features.debug and true or nil
  end
  -- Version ladder presence (xray_ecosystem_plan.md §6 slice 1). Promotion is
  -- UNCONDITIONAL (decision 11: a local swap needs no consent or opt-in), so
  -- these fields live OUTSIDE the auto_update block. Default users pay one file
  -- stat; ladder books additionally pay one parse per refresh to hold the rung
  -- progress list (numbers only — never the results).
  do
    local ActionCache = require("koassistant_action_cache")
    state.ladder_count = ActionCache.getXrayLadderCount(file)
    if state.ladder_count > 0 then
      local rungs = {}
      for _idx, rung in ipairs(ActionCache.getXrayLadder(file)) do
        local p = tonumber(rung.progress_decimal)
        -- Intro rungs (round 20) are not coverage points — never a promotion
        -- trigger nor a "next checkpoint at N%" candidate
        if p and not rung.intro then rungs[#rungs + 1] = p end
      end
      state.rung_progress = rungs
      local live = ActionCache.getXrayCache(file)
      if not (live and live.result) then
        -- Build-from-nothing: no live X-Ray yet — the first promotion INSTALLS the
        -- position rung. (A deleted X-Ray can't reach here: delete clears the ladder.)
        state.live_progress = 0
      elseif not live.full_document and live.source_mode ~= "ai_knowledge" then
        state.live_progress = tonumber(live.progress_decimal)
        -- 50(f): FULL-posture ahead install stamp — the pre-filter's revert
        -- trigger reads it when spoiler protection comes back on
        state.live_posture_promoted = live.posture_promoted or nil
      end
      -- Different-lineage live entry (complete-track / AI-knowledge): live_progress
      -- stays nil → the pre-filter never schedules a promotion over it
    end
  end
  -- Round 21/22: any built NON-intro checkpoint counts as "built" for the
  -- coverage ask (rung_progress already excludes intro rungs)
  if state.never_built and state.rung_progress and #state.rung_progress > 0 then
    state.never_built = false
  end
  self._xray_auto_state = state
end

--- Cheap per-page pre-filter (zero disk). Tracks prev_page for the jump guard even
--- when the gates fail.
function AskGPT:_xrayAutoOnPageUpdate(pageno)
  local state = self._xray_auto_state
  if not state then return end
  local prev_page = state.prev_page
  state.prev_page = pageno
  if not self.ui or not self.ui.document then return end
  local doc_info = self.ui.document.info
  -- Flowing documents only in v1: a PDF range extraction is a synchronous per-page
  -- MuPDF loop — minutes of frozen UI at the delta cap (plan §8.2)
  if not doc_info or doc_info.has_pages then return end
  local total = doc_info.number_of_pages
  if not total or total <= 0 then return end

  -- Ladder promotion pre-filter (§6 slice 1, decision 11: unconditional — no
  -- opt-in, no consent, no rate limit; the fire is a local file swap). Pure
  -- arithmetic: fire only when the position has crossed a rung that is ahead of
  -- the live cache. Same jump guard as the API path — a TOC peek ahead must not
  -- promote spoilers into the live X-Ray. 50(f): under the FULL posture the
  -- pick is position-independent (newest built rung installs), so the trigger
  -- is simply "a built rung is ahead of the live entry" and the jump guard is
  -- moot; under TRACK a posture-promoted live AHEAD of the reader additionally
  -- triggers the revert (the fire demotes back to the position rung).
  if state.rung_progress and state.live_progress and not self._xray_ladder_promo_pending then
    local XrayAuto = require("koassistant_xray_auto")
    if not XrayAuto.ladderBuild() and not XrayAuto.isInFlight() then
      local pos = pageno / total
      local PfBookSettings = require("koassistant_book_settings")
      local posture = PfBookSettings.resolveXrayPosture(
        self.ui.doc_settings, self.settings:readSetting("features") or {})
      -- Device round 5: the promotion hold routes a FULL-posture book through
      -- the position-crossing branch (position-following was deliberately picked)
      if posture == "full" and not PfBookSettings.xrayPromotionHold(self.ui.doc_settings) then
        for _idx, rp in ipairs(state.rung_progress) do
          if rp > state.live_progress + XrayAuto.LADDER_TOLERANCE then
            self:_scheduleXrayLadderPromotion()
            break
          end
        end
      elseif prev_page and math.abs(pageno - prev_page) <= XrayAuto.JUMP_GUARD_PAGES then
        for _idx, rp in ipairs(state.rung_progress) do
          if rp > state.live_progress + XrayAuto.LADDER_TOLERANCE
              and rp <= pos + XrayAuto.PROMOTE_TOLERANCE then
            self:_scheduleXrayLadderPromotion()
            break
          end
        end
        if not self._xray_ladder_promo_pending and state.live_posture_promoted
            and state.live_progress > pos + XrayAuto.LADDER_TOLERANCE then
          for _idx, rp in ipairs(state.rung_progress) do
            if rp <= pos + XrayAuto.LADDER_TOLERANCE then
              self:_scheduleXrayLadderPromotion()
              break
            end
          end
        end
      end
    end
  end

  -- Round 21 (unified engine, plan item 23): the auto scheduler's per-page
  -- question is the ONE-AHEAD INVARIANT — is a built checkpoint (or live
  -- coverage) waiting ahead of the reader? If yes, idle; crossing it promotes
  -- it (above) and the next turn finds the invariant broken and builds N+1.
  if state.auto_update ~= true or state.lineage_blocked then return end
  if state.never_built and state.create_allowed ~= true then return end
  -- Never contend with an active chain: it is already building this grid
  if require("koassistant_xray_auto").ladderBuild() then return end
  if self._xray_auto_pending then
    -- Log once per pending window — this runs per page-turn tick and flooded
    -- the log at ~25 lines/second on the 2026-08-14 device round
    if state.debug and not self._xray_auto_pending_logged then
      self._xray_auto_pending_logged = true
      logger.info("KOAssistant: automatic X-Ray: fire already scheduled")
    end
    return
  end
  local XrayAuto = require("koassistant_xray_auto")
  local pos = pageno / total
  local goal_bound = state.goal or 1.0
  if pos >= goal_bound - 0.01 then return end
  -- BUILD_LAG: the next build waits until the newest checkpoint has installed
  -- and the reader is a few pages past it (edits made meanwhile ride along)
  local ahead = (state.live_progress or 0) + XrayAuto.BUILD_LAG > pos
  if not ahead and state.rung_progress then
    for _idx, rp in ipairs(state.rung_progress) do
      if rp + XrayAuto.BUILD_LAG > pos then ahead = true break end
    end
  end
  if ahead then return end
  -- Jump guard: no prev_page (first turn after open/refresh) or a big hop is
  -- not sequential reading — never chase a TOC peek with background builds
  if not prev_page or math.abs(pageno - prev_page) > XrayAuto.JUMP_GUARD_PAGES then
    if state.debug then logger.dbg("KOAssistant: automatic X-Ray declined: page jump") end
    return
  end
  if XrayAuto.isInFlight() then return end
  if not XrayAuto.cooldownElapsed(state.cooldown_s, os.time()) then
    logger.dbg("KOAssistant: automatic X-Ray declined: cooldown")
    return
  end
  -- No-request-in-flight gate (plan §3 #9): don't contend with a user's streamed
  -- request (update-checker precedent; the streaming-disabled overlap is accepted,
  -- correctness preserved by the completion guard)
  if _G.KOAssistantStreaming then
    if state.debug then logger.info("KOAssistant: automatic X-Ray declined: user request streaming") end
    return
  end
  -- WiFi fast guard: background work never prompts (update-checker precedent)
  if not NetworkMgr:isWifiOn() then
    if state.debug then logger.info("KOAssistant: automatic X-Ray declined: WiFi off") end
    return
  end
  -- Round 22 (D3): an explicitly cancelled build stays cancelled this session
  if XrayAuto.isAutoSuppressed(self.ui.document.file) then
    if state.debug then logger.info("KOAssistant: automatic X-Ray declined: cancelled this session") end
    return
  end
  self:_scheduleXrayAutoFire()
end

--- Defer the fire off the page-turn tick. The rate limit is stamped at SCHEDULE
--- time — several page turns can pass the gates inside the deferral window.
function AskGPT:_scheduleXrayAutoFire()
  local XrayAuto = require("koassistant_xray_auto")
  if self._xray_auto_pending or XrayAuto.isInFlight() then return end
  XrayAuto.markScheduled(os.time())
  local self_ref = self
  local fire = function()
    self_ref._xray_auto_pending = nil
    self_ref._xray_auto_pending_logged = nil
    self_ref:_fireXrayAutoCheckpoints()
  end
  self._xray_auto_pending = fire
  UIManager:scheduleIn(XrayAuto.SCHEDULE_DELAY_S, fire)
end

--- Round 19 (item-16 "first-auto-fire coverage-ask"), reworked round 22 (D4):
--- the first time auto-create is about to fire on a book (every gate has
--- already passed), ask HOW coverage should happen instead of silently
--- creating — once per book (sidecar stamp). features.xray_coverage_mode
--- remembers a global answer: "follow" = never ask, create silently; "build" =
--- offer the (always-confirmed) checkpoint build once per book; nil/"ask" =
--- ask. The decline row is a REAL decline (R4 "Not for this book"): it sets
--- the per-book tri-state to "off" — reversible via the Automatic X-Ray
--- picker, no stamp needed on that branch. Dismissing the dialog decides
--- nothing and may ask again at the next fire. Explicit follow opt-ins (picker
--- On, Create-form follow pick, the book-open offer) pre-stamp — the user
--- already answered this question. Button counts are the real establishment
--- plans (D6): catch-up = grid to position + one ahead; build-all = the full
--- grid; both count the intro when one is still needed.
--- @return boolean true when this fire was consumed (ask shown / build offered)
function AskGPT:_xrayCoverageAskBeforeCreate(file, features, decimal, has_intro)
  if not self.ui or not self.ui.doc_settings then return false end
  local BookSettings = require("koassistant_book_settings")
  if features.xray_coverage_mode == "follow" then return false end
  if self:_openBookDS():readSetting(BookSettings.KEY_XRAY_COVERAGE_ASKED) then return false end
  local self_ref = self
  local function stamp()
    self_ref:_openBookDS():saveSetting(BookSettings.KEY_XRAY_COVERAGE_ASKED, true)
    self_ref:_openBookDS():flush()
  end
  if features.xray_coverage_mode == "build" then
    stamp()
    self:_startXrayLadderBuild()
    return true
  end
  local XrayAuto = require("koassistant_xray_auto")
  local boundaries = features.xray_ladder_chapter_snap ~= false
    and self:_ladderChapterBoundaries() or nil
  -- The ask only fires for from-nothing books: base nil. Counts mirror the
  -- plans each button dispatches (goal bounds the follow path; build-all is
  -- the whole book, matching _startXrayLadderBuild without opts).
  local goal = tonumber(self:_openBookDS():readSetting(BookSettings.KEY_XRAY_GOAL))
  if goal and (goal <= 0.01 or goal >= 0.995) then goal = nil end
  local intro_extra = has_intro and 0 or 1
  local remember = false
  local ask
  local function showAsk()
    -- Counts recompute per show — the spacing row below changes them
    -- (spacing slice: the ask IS the once-per-book up-front spacing moment)
    local spacing = self_ref:_xrayLadderSpacing()
    local follow_rungs, follow_labels = self_ref:_planXrayGrid(nil, spacing, goal, decimal, boundaries)
    local n_follow = #(XrayAuto.truncateToOneAhead(follow_rungs, decimal, follow_labels)) + intro_extra
    local n_all = #(self_ref:_planXrayGrid(nil, spacing, nil, decimal, boundaries)) + intro_extra
    ask = ButtonDialog:new{
      title = _("This book has no X-Ray yet. How should it be created?"),
      buttons = {
        {{ text = T(_("Catch up to here now, then keep one ahead (%1 requests)"), n_follow),
          callback = function()
            UIManager:close(ask)
            stamp()
            if remember then self_ref:_setXrayCoverageMode("follow") end
            self_ref:_fireXrayAutoCheckpoints({ asked = true, notify = true })
          end }},
        {{ text = T(_("Build all checkpoints now (%1 background requests)…"), n_all),
          callback = function()
            UIManager:close(ask)
            stamp()
            if remember then self_ref:_setXrayCoverageMode("build") end
            self_ref:_startXrayLadderBuild()
          end }},
        {{ text = T(_("Change checkpoint spacing (every %1%)…"),
            self_ref:_xraySpacingPctLabel(spacing)),
          callback = function()
            UIManager:close(ask)
            self_ref:_showXraySpacingPicker{
              current = spacing,
              override = BookSettings.xraySpacingOverride(self_ref.ui.doc_settings),
              title = _("Checkpoint spacing for this book:"),
              count_for = function(s)
                return #(self_ref:_planXrayGrid(nil, s, nil, decimal, boundaries)) + intro_extra
              end,
              on_pick = function(s)
                self_ref:_openBookDS():saveSetting(
                  BookSettings.KEY_XRAY_SPACING, s)
                self_ref:_openBookDS():flush()
                UIManager:show(Notification:new{
                  text = T(_("Checkpoint spacing for this book: every %1%"),
                    self_ref:_xraySpacingPctLabel(s)),
                })
                showAsk()
              end,
              on_reset = function()
                self_ref:_openBookDS():saveSetting(
                  BookSettings.KEY_XRAY_SPACING, nil)
                self_ref:_openBookDS():flush()
                UIManager:show(Notification:new{
                  text = T(_("Checkpoint spacing for this book: recommended (every %1%)"),
                    self_ref:_xraySpacingPctLabel(self_ref:_xrayLadderSpacing())),
                })
                showAsk()
              end,
              on_back = function() showAsk() end,
            }
          end }},
        {{ text = (remember and "● " or "○ ") .. _("Always do this, for every book"),
          callback = function()
            UIManager:close(ask)
            remember = not remember
            showAsk()
          end }},
        {{ text = _("Not for this book"), callback = function()
          UIManager:close(ask)
          self_ref:_openBookDS():saveSetting(BookSettings.KEY_XRAY_AUTO, "off")
          self_ref:_openBookDS():flush()
          self_ref:_refreshXrayAutoState()
        end }},
      },
    }
    UIManager:show(ask)
  end
  showAsk()
  return true
end

function AskGPT:_setXrayCoverageMode(mode)
  local f = self.settings:readSetting("features") or {}
  f.xray_coverage_mode = mode
  self.settings:saveSetting("features", f)
  self.settings:flush()
end

--- Silent consent check shared by every unattended X-Ray fire (background update,
--- auto-create, ladder rungs): the book_text gate incl. trusted-provider bypass,
--- without _checkRequirements' UI.
function AskGPT:_xrayBackgroundConsentOk(action, features)
  if action.use_book_text == false then return false end
  -- Per-book privacy override wins in both directions (deny beats trusted)
  if self.ui and self.ui.doc_settings then
    local ov = require("koassistant_book_settings")
      .effectivePrivacyOverrides(self.ui.doc_settings).book_text
    if ov ~= nil then return ov end
  end
  if features.enable_book_text_extraction == true then return true end
  local provider = action.provider or features.provider
  for _idx, trusted_id in ipairs(features.trusted_providers or {}) do
    if trusted_id == provider then return true end
  end
  return false
end

--- Round 21 — the UNIFIED CHECKPOINT ENGINE's auto fire (plan item 23): build
--- every missing grid point up to ONE past the reader, through the same chain
--- the front-load build uses (same grid, same store, same promotion). Replaces
--- the retired to-position auto-update/auto-create path. Disk truth derived
--- here; the chain re-verifies per step. First-ever spend for a book routes
--- through the coverage ask. opts: { notify = true } → announce chain progress
--- (explicit enables); { asked = true } → the coverage ask was just answered;
--- { explicit = true } → fired by an explicit enable (skip the posture
--- re-check — the key may have just been written).
function AskGPT:_fireXrayAutoCheckpoints(opts)
  local XrayAuto = require("koassistant_xray_auto")
  if XrayAuto.ladderBuild() or XrayAuto.isInFlight() then return end
  if not self.ui or not self.ui.document or not self.ui.document.file
      or not self.ui.doc_settings then return end
  local doc_info = self.ui.document.info
  if not doc_info or doc_info.has_pages then return end
  local file = self.ui.document.file
  -- Round 22 (D3): an explicit user cancel pauses unattended fires for this
  -- book this session; any explicit engine start clears the pause
  if opts and opts.explicit then
    XrayAuto.clearAutoSuppression(file)
    XrayAuto.clearScheduled()
  elseif XrayAuto.isAutoSuppressed(file) then
    return
  end
  local features = self.settings:readSetting("features") or {}
  local BookSettings = require("koassistant_book_settings")
  local auto_on, create_allowed = BookSettings.resolveXrayAuto(self.ui.doc_settings, features)
  if not auto_on and not (opts and opts.explicit) then return end
  if _G.KOAssistantStreaming then return end
  if not NetworkMgr:isWifiOn() then
    if opts and opts.notify then
      UIManager:show(InfoMessage:new{ text = _("WiFi is off."), timeout = 2 })
    end
    return
  end
  local action = self.action_service and self.action_service:getAction("book", "xray")
  if not action or not action.update_prompt then return end
  if not self:_xrayBackgroundConsentOk(action, features) then
    logger.dbg("KOAssistant: automatic X-Ray declined: text extraction consent off")
    return
  end

  local ActionCache = require("koassistant_action_cache")
  local XrayParser = require("koassistant_xray_parser")
  local ContextExtractor = require("koassistant_context_extractor")
  local progress = ContextExtractor:new(self.ui):getReadingProgress()
  local decimal = progress and tonumber(progress.decimal)
  if not decimal then return end
  -- Round 22 (T2): the decision core is pure — see XrayAuto.planAutoWork.
  -- has_any counts only NON-intro artifacts (D1: an intro-only book, e.g. a
  -- build cancelled after its introduction, is still a first spend).
  local ladder = ActionCache.getXrayLadder(file)
  local work = XrayAuto.planAutoWork{
    entry = ActionCache.get(file, "xray"),
    ladder = ladder,
    base_progress = ActionCache.highestXrayLadderProgress(ladder),
    position = decimal,
    goal = tonumber(self:_openBookDS():readSetting(BookSettings.KEY_XRAY_GOAL)),
    is_json = XrayParser.isJSON,
  }
  -- Deferred rebuild catch-up (2026-08-14): an explicit rebuild-follow pick
  -- plans from scratch and marks the chain — the old lineage stays untouched
  -- until the first new rung lands (the write-seam swap). The planAutoWork
  -- early-outs don't apply: replacing a blocked/complete lineage is exactly
  -- what the rebuild is for.
  local chain_rebuild = opts and opts.rebuild or nil
  if not chain_rebuild then
    if work.lineage_blocked or not work.build then return end
    -- Follow-global books keep the separate create guard (P1): the FIRST build
    -- for a book needs create_allowed unless the enable was explicit
    if not work.has_any and not create_allowed and not (opts and opts.explicit) then return end
    -- First-ever spend goes through the coverage ask (round 19; once per book)
    if not work.has_any and not (opts and opts.asked)
        and self:_xrayCoverageAskBeforeCreate(file, features, decimal, work.has_intro) then
      return
    end
  end

  local spacing = self:_xrayLadderSpacing()
  local boundaries = features.xray_ladder_chapter_snap ~= false
    and self:_ladderChapterBoundaries() or nil
  -- No and/or chain for the base (see _xrayEstablishmentSteps): the fold sent
  -- the old ladder top into a REBUILD plan — seed refused, single ahead rung,
  -- live lost at the swap (2026-08-15 device round)
  local plan_base = nil
  if not chain_rebuild then plan_base = work.base end
  local rungs, labels = self:_planXrayGrid(plan_base,
    spacing, work.goal, decimal, boundaries, chain_rebuild)
  rungs, labels = XrayAuto.truncateToOneAhead(rungs, decimal, labels)
  if #rungs == 0 then return end
  local plan_intro = not chain_rebuild and work.plan_intro
  XrayAuto.markScheduled(os.time())
  logger.dbg("KOAssistant: automatic X-Ray building", #rungs + (plan_intro and 1 or 0),
    "checkpoint(s) to", rungs[#rungs], chain_rebuild and "(rebuild)" or "")
  XrayAuto.beginLadderBuild(file, rungs, labels,
    { intro = plan_intro, silent = not (opts and opts.notify), rebuild = chain_rebuild })
  self:_fireXrayLadderRung()
end

--- The deferred fire. Fresh disk reads are the authority here; then dispatch the
--- headless update through the normal incremental machinery (executeActionForResult
--- with the _background_request transient on a config COPY — never the shared
--- module configuration). Round 14: opts.manual = user-invoked background update
--- (the "Update in background" choice on the paid confirm) — skips the posture
--- and spend dials (still consent/WiFi/eligibility-gated), never creates, always
--- notifies, and reports timeouts/failures instead of staying silent.
--- Round 21: MANUAL-ONLY — the unattended path retired into
--- _fireXrayAutoCheckpoints (unified engine); an unattended call is redirected.
function AskGPT:_fireXrayAutoUpdate(opts)
  local manual = (opts and opts.manual) or false
  -- Round 21: any unattended call belongs to the unified engine
  if not manual then return self:_fireXrayAutoCheckpoints(opts) end
  local XrayAuto = require("koassistant_xray_auto")
  -- A close/book-switch inside the deferral window must not execute against a dead
  -- instance (readerui broadcasts CloseDocument then nils the document)
  if not self.ui or not self.ui.document or not self.ui.document.file then return end
  if XrayAuto.isInFlight() then
    UIManager:show(InfoMessage:new{ text = _("An X-Ray task is already running."), timeout = 2 })
    return
  end
  local file = self.ui.document.file

  local features = self.settings:readSetting("features") or {}
  if not self.ui.doc_settings then return end
  local doc_info = self.ui.document.info
  if not doc_info or doc_info.has_pages then return end

  local ActionCache = require("koassistant_action_cache")
  local XrayParser = require("koassistant_xray_parser")
  local fire_entry = ActionCache.get(file, "xray")
  local eligible, cached_progress =
    XrayAuto.eligibilityFromEntry(fire_entry, XrayParser.isJSON)
  if not eligible then
    self:_refreshXrayAutoState()
    return
  end

  -- Authoritative (flow-aware) progress for the delta floor
  local ContextExtractor = require("koassistant_context_extractor")
  local progress = ContextExtractor:new(self.ui):getReadingProgress()
  local decimal = progress and tonumber(progress.decimal)
  if not decimal then return end
  -- User-affirmed run: no spend dials — only a nothing-to-update floor
  if decimal - cached_progress <= 0.005 then return end
  if _G.KOAssistantStreaming then return end
  if not NetworkMgr:isWifiOn() then
    UIManager:show(InfoMessage:new{ text = _("WiFi is off."), timeout = 2 })
    return
  end

  local action = self.action_service and self.action_service:getAction("book", "xray")
  if not action or not action.update_prompt or not action.use_response_caching then return end

  -- Consent gate, mirroring _checkRequirements' book_text gate (the background path
  -- never runs that UI pre-flight): revoking text extraction after a book was opted
  -- in must stop background fires. Trusted providers bypass, same as everywhere.
  if not self:_xrayBackgroundConsentOk(action, features) then
    logger.dbg("KOAssistant: background X-Ray update declined: text extraction consent off")
    return
  end

  self:updateConfigFromSettings()
  local config_copy = {}
  for k, v in pairs(configuration or {}) do config_copy[k] = v end
  config_copy.features = {}
  for k, v in pairs((configuration or {}).features or {}) do config_copy.features[k] = v end
  config_copy.features.is_book_context = true
  config_copy.features._background_request = true
  config_copy.features._is_book_level_action = true

  local doc_props = self.ui.doc_props or {}
  local title = doc_props.display_title or doc_props.title or "Unknown"
  local authors = doc_props.authors or ""
  if authors:find("\n") then authors = authors:gsub("\n", ", ") end
  local raw_doc_props = getRawDocProps(file) or doc_props
  config_copy.features.book_metadata = buildBookMetadata(title, authors, file, raw_doc_props,
      self.ui.document, self.ui.doc_settings)
  local book_context = bookContextString(config_copy.features.book_metadata)
  config_copy.features.book_context = book_context

  XrayAuto.beginFlight(file)
  -- No watchdog (retired 2026-08-05, maintainer): a kill is lossy — the
  -- provider bills the request anyway — and slow is not stuck (local models
  -- legitimately take as long as they take, #90). True hangs are covered by
  -- the child's own socket timeouts, book-close cancel, and the popup's
  -- tap-to-cancel row on the in-progress state.
  local self_ref = self

  logger.dbg("KOAssistant: background X-Ray update firing, delta", decimal - cached_progress)
  -- Manual runs always notify: the user just asked for this
  UIManager:show(Notification:new{
    text = T(_("Updating X-Ray in background (%1% → %2%)…"),
      math.floor(cached_progress * 100 + 0.5), math.floor(decimal * 100 + 0.5)),
  })
  Dialogs.executeActionForResult(action, book_context, self.ui, config_copy, self,
    config_copy.features.book_metadata,
    function(result, meta_or_err)
      XrayAuto.endFlight()
      local was_cancelled, was_discarded = XrayAuto.consumeOutcomeFlags()
      if was_cancelled or was_discarded then
        -- Guard-discard (a manual run won the race / X-Ray deleted) or book-close
        -- cancel: a skip — neither a success (nothing written) nor a failure
        logger.dbg("KOAssistant: background X-Ray update skipped -",
          was_discarded and "discarded (cache changed mid-flight)" or "cancelled")
      elseif result then
        XrayAuto.recordSuccess(file)
        logger.dbg("KOAssistant: background X-Ray update completed (session total:",
          XrayAuto.sessionUpdateCount(), ")")
        UIManager:show(Notification:new{
          text = T(_("X-Ray updated to %1%"), math.floor(decimal * 100 + 0.5)),
        })
      else
        local msg = tostring(meta_or_err or "unknown error")
        if msg:find("^background:") then
          -- Deliberate abort (path not applicable / truncated delta) — a skip, not a failure
          logger.dbg("KOAssistant: background X-Ray update skipped -", msg)
        else
          XrayAuto.recordFailure(file, msg)
          logger.warn("KOAssistant: background X-Ray update failed:", msg)
          if manual then
            UIManager:show(InfoMessage:new{
              text = T(_("Background X-Ray update failed: %1"), msg), timeout = 4 })
          end
        end
      end
      -- Refresh the pre-filter state if this book is still open
      if self_ref.ui and self_ref.ui.document and self_ref.ui.document.file == file then
        self_ref:_refreshXrayAutoState()
      end
    end)
end

-- ========================= X-Ray version ladder =========================
-- Create-ahead prefix versions (xray_ecosystem_plan.md §5 decisions 10/11 +
-- §6 slice 1, ref #73 #90): chain the incremental machinery ahead of the
-- reader, rung by rung to 100%, into a separate ladder sidecar. The live
-- X-Ray keeps tracking the reader throughout; PROMOTION swaps rungs in
-- locally as the reader passes them — free, instant, no consent needed.

--- Spoiler posture for the OPEN book's X-Ray version machinery (50(f)+(g)):
--- BookSettings.resolveXrayPosture over the live doc settings. "track" =
--- promotion follows the reading position (spoiler protection on); "full" =
--- the newest built version installs as soon as it is ready (protection off,
--- or research mode). No open book → "track" (the position-gated paths bail
--- without a position anyway).
function AskGPT:_xrayPosture()
  if not (self.ui and self.ui.doc_settings) then return "track", "global" end
  return require("koassistant_book_settings").resolveXrayPosture(
    self.ui.doc_settings, self.settings:readSetting("features") or {})
end

--- Defer a promotion off the page-turn tick (same pattern as the API fire).
--- Page-turn promotions are CAPPED (a big position swing is more likely a peek
--- than reading — see the cap note in the fire); manual and post-build calls
--- are not.
function AskGPT:_scheduleXrayLadderPromotion()
  if self._xray_ladder_promo_pending then return end
  local self_ref = self
  local fire = function()
    self_ref._xray_ladder_promo_pending = nil
    self_ref:_fireXrayLadderPromotion({ capped = true })
  end
  self._xray_ladder_promo_pending = fire
  UIManager:scheduleIn(require("koassistant_xray_auto").SCHEDULE_DELAY_S, fire)
end

--- The deferred promotion. Disk truth re-derived here (ladder + live cache +
--- flow-aware position), then a pure pick. COPY semantics — the rung stays in
--- the ladder for re-readers.
--- @param opts table|nil { manual = true } → always notify and report back;
---   { capped = true } (page-turn path) → refuse position swings above the
---   max-gap dial: the jump guard only suppresses the jump TURN itself, so the
---   next ordinary turn at a peeked-ahead location would otherwise promote
---   far-ahead spoilers. Manual taps and the post-build install are
---   user-affirmed positions — uncapped. { mid_build = true } (rung completion
---   callback, round 19) → allowed while the chain is active: called between
---   rungs, never concurrent with a flight, so a finished rung at-or-below the
---   reader installs immediately instead of at chain end.
--- @return boolean promoted
function AskGPT:_fireXrayLadderPromotion(opts)
  if not self.ui or not self.ui.document or not self.ui.document.file then return false end
  local XrayAuto = require("koassistant_xray_auto")
  if (XrayAuto.ladderBuild() and not (opts and opts.mid_build)) or XrayAuto.isInFlight() then return false end
  local file = self.ui.document.file
  local ActionCache = require("koassistant_action_cache")
  local ladder = ActionCache.getXrayLadder(file)
  if #ladder == 0 then return false end
  local live = ActionCache.getXrayCache(file)
  if live and live.result and (live.full_document or live.source_mode == "ai_knowledge") then
    -- Different lineage — never promote over it. (No live entry at all is FINE:
    -- that's the build-from-nothing case, and the first promotion installs the
    -- position rung; a deleted X-Ray can't reach here since delete clears the ladder.)
    self:_refreshXrayAutoState()
    return false
  end
  local ContextExtractor = require("koassistant_context_extractor")
  local progress = ContextExtractor:new(self.ui):getReadingProgress()
  local decimal = progress and tonumber(progress.decimal)
  if not decimal then return false end
  local features = self.settings:readSetting("features") or {}
  local live_p = live and tonumber(live.progress_decimal) or 0
  -- 50(f)+(g): spoiler posture decides the pick rule. FULL (protection off /
  -- research) installs the newest built rung regardless of position; the
  -- max-gap peek cap compares reader-vs-live positions and is meaningless there.
  local posture = self:_xrayPosture()
  -- Device round 5: the promotion hold pins FULL-posture books back to
  -- position-following (a deliberate below-newest install said "by position")
  local hold = posture == "full"
    and require("koassistant_book_settings").xrayPromotionHold(self.ui.doc_settings)
  if opts and opts.capped and (posture ~= "full" or hold)
      and decimal - live_p > XrayAuto.dialsFromFeatures(features).max_gap then
    logger.dbg("KOAssistant: ladder promotion declined - position swing above the max-gap dial")
    return false
  end
  -- 50(f) revert: a FULL-posture promotion may have installed a version ahead
  -- of the reader (stamped posture_promoted). With spoiler protection back on,
  -- drop back to the position rung — the ahead version stays in the ladder.
  -- Deliberate ahead installs (manual switches/version-card installs) are
  -- never stamped and never reverted (item 40 keeps them active).
  if posture == "track" and live and live.result and live.posture_promoted
      and live_p > decimal + XrayAuto.LADDER_TOLERANCE then
    local back = XrayAuto.pickPromotableRung(ladder, 0, decimal)
    local ok_back = false
    if back and back.timestamp ~= live.timestamp then
      ok_back = ActionCache.promoteXrayLadderRung(file, back,
          ActionCache.checkpointLimitFromFeatures(features), opts)
      if ok_back then
        self._file_dialog_row_cache = { file = nil, rows = nil }
        logger.info("KOAssistant: X-Ray posture revert - back to", tostring(back.progress_decimal))
        UIManager:show(Notification:new{
          text = T(_("Spoiler protection is on: X-Ray back to your position (%1%). Newer versions are kept."),
            math.floor((tonumber(back.progress_decimal) or 0) * 100 + 0.5)),
        })
      end
      self:_refreshXrayAutoState()
      return ok_back
    end
    -- No rung at-or-below the reader: nothing safe to revert to — keep the
    -- ahead version (the popup's paid rebuild-to-position path covers it)
  end
  local rung = XrayAuto.pickPromotableRung(ladder, live_p, decimal,
      (posture == "full" and not hold) and { ahead_ok = true } or nil)
  if not rung and not (live and live.result) then
    -- Round 20: with no live X-Ray at all, the INTRO rung installs at any
    -- position — premise-only content is spoiler-free by construction, so the
    -- X-Ray button works from the very start instead of waiting for rung 1
    for _idx, r in ipairs(ladder) do
      if r.intro and r.result then rung = r break end
    end
  end
  if not rung then
    self:_refreshXrayAutoState()
    return false
  end
  -- Ahead-of-position install under FULL posture → stamp for the revert
  local posture_ahead = (posture == "full" and not hold and not rung.intro
      and (tonumber(rung.progress_decimal) or 0) > decimal + XrayAuto.LADDER_TOLERANCE)
      or nil
  local promote_opts = opts
  if posture_ahead then
    promote_opts = { manual = opts and opts.manual, posture_ahead = true }
  end
  local ok = ActionCache.promoteXrayLadderRung(file, rung,
      ActionCache.checkpointLimitFromFeatures(features), promote_opts)
  if ok then
    self._file_dialog_row_cache = { file = nil, rows = nil }
    logger.info("KOAssistant: X-Ray ladder rung promoted to", tostring(rung.progress_decimal),
      rung.intro and "(intro)" or ((opts and opts.manual) and "(manual)" or "(auto)"))
    if (opts and opts.manual) or posture_ahead or features.xray_auto_notify == true then
      -- An ahead install always notifies: it changes what the live X-Ray may
      -- reveal, so it must never happen silently (the suffix names why)
      UIManager:show(Notification:new{
        text = rung.intro and _("Introductory X-Ray is ready (spoiler-free).")
          or (posture_ahead
            and T(_("X-Ray updated to %1% (newest checkpoint; spoiler protection is off)"),
              math.floor((tonumber(rung.progress_decimal) or 0) * 100 + 0.5))
            or T(_("X-Ray updated to %1% (checkpoint)"),
              math.floor((tonumber(rung.progress_decimal) or 0) * 100 + 0.5))),
      })
    end
    -- Filing 08-17 §14 decided trigger: the dedup pair-check runs when rung
    -- content becomes LIVE, never before install (an uninstalled rung's
    -- identity assert stays invisible, which is also spoiler-correct by
    -- construction). Fresh-pairs filter + one-ask-per-pair stamps keep it
    -- quiet; the posture revert above deliberately skips it (corrective,
    -- that content was live before).
    local self_ref = self
    UIManager:scheduleIn(1, function() self_ref:maybeOfferDedupAsk(file) end)
  end
  self:_refreshXrayAutoState()
  return ok
end

--- Per-book promotion hold (device round 5): under the FULL posture a
--- deliberate below-newest install pins mechanical promotion to
--- position-following ("I want X-Rays by position, not spoiler protection");
--- a deliberate newest/complete install releases it. Spoiler/research prompts
--- and build cadence are untouched — this only changes which rung promotion
--- picks. Persisted on the book's sidecar so it survives restarts.
function AskGPT:_setXrayPromotionHold(file, on)
  local BookSettings = require("koassistant_book_settings")
  local ds = require("koassistant_doc_settings").resolve(file, self.ui)
  if not ds then return false end
  local prev = ds:readSetting(BookSettings.KEY_XRAY_PROMOTION)
  local changed
  if on then
    changed = prev ~= "position"
    if changed then ds:saveSetting(BookSettings.KEY_XRAY_PROMOTION, "position") end
  else
    changed = prev ~= nil
    if changed then ds:delSetting(BookSettings.KEY_XRAY_PROMOTION) end
  end
  if changed and ds.flush then ds:flush() end
  return changed
end

--- Manual install of the finished 1.0 rung as the live X-Ray (device round 2):
--- the ladder's complete version IS the whole-book X-Ray, so switching is free —
--- this replaces the API "Update to 100%" whenever a finished rung exists.
--- Deliberately bypasses the promotion position gate (a user-affirmed spoiler
--- jump — warned first). Round 13: afterwards the switched-to X-Ray OPENS and a
--- timed notice says the versions can be safely deleted — the round-8 modal
--- delete offer was too aggressive (maintainer); the delete row lives in the
--- versions list.
function AskGPT:_switchToCompleteXrayRung(opts)
  local XrayAuto = require("koassistant_xray_auto")
  local ActionCache = require("koassistant_action_cache")
  local ButtonDialog = require("ui/widget/buttondialog")
  if XrayAuto.ladderBuild() or XrayAuto.isInFlight() then
    UIManager:show(InfoMessage:new{ text = _("An X-Ray task is already running."), timeout = 2 })
    return
  end
  local file = (self.ui and self.ui.document and self.ui.document.file) or (opts and opts.file)
  if not file then return end
  local live = ActionCache.getXrayCache(file)
  if live and live.result and (live.full_document or live.source_mode == "ai_knowledge") then
    -- Different lineage — same rule as promotion. (Row gating already excludes
    -- this; guard against disk moving between drawing and tapping.)
    return
  end
  local rung
  for _idx, r in ipairs(ActionCache.getXrayLadder(file)) do
    local p = tonumber(r.progress_decimal)
    if p and p >= 1.0 - 0.005 and not r.full_document
        and (not rung or p > tonumber(rung.progress_decimal)) then
      rung = r
    end
  end
  if not rung then
    UIManager:show(InfoMessage:new{ text = _("The complete checkpoint is no longer available."), timeout = 3 })
    return
  end
  local self_ref = self
  local confirm
  confirm = ButtonDialog:new{
    title = _("Switch to the complete X-Ray (100%)?") .. "\n"
      .. _("It covers the whole book, including everything ahead of your reading position. The current version is kept in the version list."),
    buttons = {
      {{
        text = _("Switch"),
        callback = function()
          UIManager:close(confirm)
          local features = self_ref.settings:readSetting("features") or {}
          local ok = ActionCache.promoteXrayLadderRung(file, rung,
              ActionCache.checkpointLimitFromFeatures(features), { manual = true })
          if not ok then
            UIManager:show(InfoMessage:new{ text = _("Switch failed. The checkpoint could not be installed."), timeout = 3 })
            return
          end
          -- Device round 5: a deliberate switch to the newest releases the
          -- promotion hold — newest-first resumes for this book
          self_ref:_setXrayPromotionHold(file, false)
          self_ref._file_dialog_row_cache = { file = nil, rows = nil }
          self_ref:_refreshXrayAutoState()
          -- Round 12: land where the reader was — the switched-to X-Ray
          -- reopens only when the switch started from an OPEN X-Ray (the
          -- browser hamburger and its version list pass reopen_live); from
          -- the action popup and its version list the toast is the feedback
          self_ref:_reopenLiveXrayAfterInstall(file, opts)
          UIManager:show(InfoMessage:new{
            text = _("Switched to the complete X-Ray. The checkpoints are kept; they can be safely deleted under \"All versions\", or kept for the free \"Switch back to your position\" option."),
            timeout = 6,
          })
          -- §14: every install into live runs the pair-check (stamped once per pair)
          UIManager:scheduleIn(1, function() self_ref:maybeOfferDedupAsk(file) end)
        end,
      }},
      {{
        text = _("Cancel"),
        callback = function()
          UIManager:close(confirm)
        end,
      }},
    },
  }
  UIManager:show(confirm)
end

--- The mirror of _switchToCompleteXrayRung (device round 3): when the live
--- X-Ray sits AHEAD of the reader (typically after switch-to-complete), install
--- the highest rung at-or-below the reading position — free, spoiler-safe (it
--- only moves coverage DOWN to the reader), so no warning dialog. Promotion
--- resumes naturally afterwards; while the ladder exists the two switches are
--- fully reversible. Requires the book open (needs the reading position).
--- Device round 5: under the FULL posture this switch also PINS the promotion
--- hold — without it the next page turn would reinstall the newest rung,
--- undoing the deliberate choice the reader just made.
function AskGPT:_switchBackToPositionRung(opts)
  local XrayAuto = require("koassistant_xray_auto")
  local ActionCache = require("koassistant_action_cache")
  if XrayAuto.ladderBuild() or XrayAuto.isInFlight() then
    UIManager:show(InfoMessage:new{ text = _("An X-Ray task is already running."), timeout = 2 })
    return
  end
  local file = (self.ui and self.ui.document and self.ui.document.file) or (opts and opts.file)
  if not file or not self.ui or not self.ui.document or self.ui.document.file ~= file then return end
  local live = ActionCache.getXrayCache(file)
  -- ai_knowledge lineages never mix with rungs; a COMPLETE live is allowed
  -- since the 2026-08-13 device round — switching back to position-following
  -- from a pinned complete install is exactly this row's job (the outgoing
  -- complete stays recoverable: as a 1.0 rung it lives in the ladder, as a
  -- foreground build it ring-archives)
  if live and live.result and live.source_mode == "ai_knowledge" then
    return
  end
  local ContextExtractor = require("koassistant_context_extractor")
  local progress = ContextExtractor:new(self.ui):getReadingProgress()
  local decimal = progress and tonumber(progress.decimal)
  if not decimal then return end
  -- live_progress 0 = "highest rung at-or-below the reader", ignoring the
  -- ahead live (the whole point of the switch-back)
  local rung = XrayAuto.pickPromotableRung(ActionCache.getXrayLadder(file), 0, decimal)
  if not rung then
    UIManager:show(InfoMessage:new{ text = _("No checkpoint at or below your position."), timeout = 3 })
    return
  end
  local features = self.settings:readSetting("features") or {}
  local posture = self:_xrayPosture()
  local ok = ActionCache.promoteXrayLadderRung(file, rung,
      ActionCache.checkpointLimitFromFeatures(features), { manual = true })
  if ok then
    if posture == "full" then
      self:_setXrayPromotionHold(file, true)
    end
    self._file_dialog_row_cache = { file = nil, rows = nil }
    self:_refreshXrayAutoState()
    -- Round 12 parity with switch-to-complete: reopen only from an open
    -- X-Ray (reopen_live rides the browser's list opts)
    self:_reopenLiveXrayAfterInstall(file, opts)
    UIManager:show(Notification:new{
      text = posture == "full"
        and T(_("Switched back: X-Ray now at %1% and follows your position for this book"),
          math.floor((tonumber(rung.progress_decimal) or 0) * 100 + 0.5))
        or T(_("Switched back: X-Ray now at %1%"),
          math.floor((tonumber(rung.progress_decimal) or 0) * 100 + 0.5)),
    })
    -- §14: every install into live runs the pair-check; usually a no-op here
    -- (earlier content, pairs already stamped) but a ladder sweep can seed
    -- fresh pairs into a rung after its content was last live
    local self_ref = self
    UIManager:scheduleIn(1, function() self_ref:maybeOfferDedupAsk(file) end)
  else
    UIManager:show(InfoMessage:new{ text = _("Switch failed. The checkpoint could not be installed."), timeout = 3 })
  end
end

--- One-tap install of the nearest checkpoint built AHEAD of the reader
--- (spacing slice, build-shapes list item "install built-ahead rung" — was
--- reachable only through the All-versions cards). Deliberate spoiler-side
--- choice: always behind the same confirm the version card uses, with the
--- same posture/hold discipline (a deliberate ahead install never
--- auto-reverts — item 40; under FULL posture with the hold pinned,
--- installing the newest rung releases the hold like the card does).
function AskGPT:_installAheadXrayRung(opts)
  local XrayAuto = require("koassistant_xray_auto")
  local ActionCache = require("koassistant_action_cache")
  if XrayAuto.ladderBuild() or XrayAuto.isInFlight() then
    UIManager:show(InfoMessage:new{ text = _("An X-Ray task is already running."), timeout = 2 })
    return
  end
  local file = (self.ui and self.ui.document and self.ui.document.file) or (opts and opts.file)
  if not file or not self.ui or not self.ui.document or self.ui.document.file ~= file then return end
  local live = ActionCache.getXrayCache(file)
  if live and live.result and live.source_mode == "ai_knowledge" then return end
  local live_dec = live and tonumber(live.progress_decimal) or 0
  local ContextExtractor = require("koassistant_context_extractor")
  local progress = ContextExtractor:new(self.ui):getReadingProgress()
  local decimal = progress and tonumber(progress.decimal)
  if not decimal then return end
  -- Nearest rung past BOTH the reader and live coverage — the versionRows
  -- next_ahead rule, re-derived from disk at tap time
  local rungs = ActionCache.getXrayLadder(file)
  local rung
  for _idx, r in ipairs(rungs) do
    local p = tonumber(r.progress_decimal)
    if p and not r.full_document and p > decimal + 0.005 and p > live_dec + 0.005 then
      if not rung or p < tonumber(rung.progress_decimal) then rung = r end
    end
  end
  if not rung then
    UIManager:show(InfoMessage:new{ text = _("No checkpoint is built ahead of your position."), timeout = 3 })
    return
  end
  local p = tonumber(rung.progress_decimal) or 0
  local self_ref = self
  local function doInstall()
    local features = self_ref.settings:readSetting("features") or {}
    local ok = ActionCache.promoteXrayLadderRung(file, rung,
      ActionCache.checkpointLimitFromFeatures(features), { manual = true })
    if not ok then
      UIManager:show(InfoMessage:new{ text = _("Install failed. This checkpoint is no longer on disk."), timeout = 3 })
      return
    end
    if self_ref:_xrayPosture() == "full" then
      local highest = ActionCache.highestXrayLadderProgress(
        ActionCache.getXrayLadder(file)) or 0
      self_ref:_setXrayPromotionHold(file, p < highest - XrayAuto.LADDER_TOLERANCE)
    end
    self_ref._file_dialog_row_cache = { file = nil, rows = nil }
    self_ref:_refreshXrayAutoState()
    UIManager:show(Notification:new{
      text = T(_("Checkpoint installed (%1%)"), math.floor(p * 100 + 0.5)),
      timeout = 2,
    })
    self_ref:_reopenLiveXrayAfterInstall(file, opts)
    if self_ref.maybeOfferDedupAsk then
      UIManager:scheduleIn(1, function() self_ref:maybeOfferDedupAsk(file) end)
    end
  end
  local ConfirmBox = require("ui/widget/confirmbox")
  UIManager:show(ConfirmBox:new{
    -- The version card's ahead wording (device round 2026-08-05): name what
    -- happens NEXT — free position swaps pause until the reader passes it
    text = T(_("Install the checkpoint to %1%? It reaches past your reading position (%2%), so its entries may mention people and events you have not reached yet. Your current version stays in the version list. Free checkpoint swaps pause until you read past it; the X-Ray popup offers a switch back to your position."),
      math.floor(p * 100 + 0.5), math.floor(decimal * 100 + 0.5)),
    ok_text = _("Install"),
    ok_callback = doInstall,
  })
end

--- Chapter-end boundaries for ladder rung snapping (P3): ascending
--- { ratio, title } where ratio = the chapter's last page over the page count
--- and title = the chapter that ENDS there. Chapter set = the quiz auto-level
--- heuristic (leaf-at-N, 5-page floor) — deliberately independent of the
--- per-book quiz settings. Ends inside the final 3% are excluded (that close
--- to the end is the 1.0 rung's job). nil = unusable TOC (< 3 boundaries).
function AskGPT:_ladderChapterBoundaries()
  local toc = self.ui and self.ui.toc and self.ui.toc.toc
  local doc = self.ui and self.ui.document
  if not toc or #toc == 0 or not doc then return nil end
  local total = doc:getPageCount()
  if not total or total <= 0 then return nil end
  local QuizChapters = require("koassistant_quiz_chapters")
  local level = QuizChapters.autoLevel(toc, total, 5)
  local indices = QuizChapters.chapterIndices(toc, level)
  local out = {}
  for k = 1, #indices - 1 do
    local end_page = (toc[indices[k + 1]].page or 1) - 1
    local ratio = end_page / total
    if ratio > 0 and ratio <= 0.97 then
      local title = toc[indices[k]].title or ""
      if self.ui.toc.cleanUpTocTitle then
        title = self.ui.toc:cleanUpTocTitle(title) or title
      end
      out[#out + 1] = { ratio = ratio, title = title ~= "" and title or nil }
    end
  end
  if #out < 3 then return nil end
  return out
end

--- Effective checkpoint spacing for the open book (spacing slice 2026-08-14):
--- per-book override (KEY_XRAY_SPACING — the authoring form's spacing row and
--- the first-spend ask write it) over the pages-per-rung formula. ONE resolver
--- for every planning/count site, so a spacing change reaches the auto engine,
--- the build-all plan, the form's step counts and the coverage ask alike.
--- Change-forward is free by construction: plans start at the ladder top, so
--- built rungs keep their spans whatever the new value.
--- @return number spacing ratio
function AskGPT:_xrayLadderSpacing()
  local XrayAuto = require("koassistant_xray_auto")
  local override = self.ui and self.ui.doc_settings
    and require("koassistant_book_settings").xraySpacingOverride(self.ui.doc_settings)
  if override then return override end
  return XrayAuto.ladderSpacingFor(
    self.ui and self.ui.document and self.ui.document:getPageCount())
end

--- Spacing as a display percent ("10", "2.5") — shared by every row naming it.
function AskGPT:_xraySpacingPctLabel(s)
  local pct = (tonumber(s) or 0) * 100
  return pct % 1 == 0 and tostring(math.floor(pct)) or string.format("%.1f", pct)
end

--- Shared checkpoint-spacing picker (spacing slice; consolidation P2
--- 2026-08-16: current-selection radio dots + the explicit reset row the Q3
--- invariant requires). Options 2.5–50% plus the formula recommendation; each
--- row may carry a live step count via opts.count_for. The caller decides
--- persistence in opts.on_pick — the form and the coverage ask write the
--- per-book key and pass opts.override + opts.on_reset; a per-run caller
--- passes neither and the dots follow opts.current instead.
--- @param opts table { current, override, title, count_for(spacing)->n|nil,
---   on_pick(spacing), on_reset()|nil, on_back() }
function AskGPT:_showXraySpacingPicker(opts)
  local ButtonDialog = require("ui/widget/buttondialog")
  local XrayAuto = require("koassistant_xray_auto")
  local recommended = XrayAuto.ladderSpacingFor(
    self.ui and self.ui.document and self.ui.document:getPageCount())
  -- Half-percent resolution so 2.5% survives the dedupe rounding
  local function skey(s) return math.floor((tonumber(s) or 0) * 200 + 0.5) end
  local function dot(on) return on and "● " or "○ " end
  -- With a reset row the dots mirror the PIN: an explicit override marks its
  -- value row, no override marks the reset row (picking a value that equals
  -- the recommendation is still a pin, Q3). Without on_reset (per-run pick)
  -- the dots follow the resolved current value. Explicit if — override may
  -- legitimately be nil.
  local marked
  if opts.on_reset then marked = opts.override else marked = opts.current end
  local choices, seen = {}, {}
  for _idx, s in ipairs({ 0.025, 0.05, 0.10, 0.15, 0.20, 0.25, 0.50, recommended }) do
    local key = skey(s)
    if not seen[key] then
      seen[key] = true
      choices[#choices + 1] = { spacing = s }
    end
  end
  table.sort(choices, function(a, b) return a.spacing < b.spacing end)
  local picker
  local rows = {}
  if opts.on_reset then
    rows[#rows + 1] = {{
      text = dot(opts.override == nil)
        .. T(_("Use recommended (every %1%)"), self:_xraySpacingPctLabel(recommended)),
      callback = function()
        UIManager:close(picker)
        opts.on_reset()
      end,
    }}
  end
  for _idx, c in ipairs(choices) do
    local n = opts.count_for and opts.count_for(c.spacing) or nil
    local label
    if n then
      label = T(_("Every %1%: %2 checkpoints"), self:_xraySpacingPctLabel(c.spacing), n)
    else
      label = T(_("Every %1%"), self:_xraySpacingPctLabel(c.spacing))
    end
    if skey(c.spacing) == skey(recommended) then
      label = label .. " " .. _("(recommended)")
    end
    local captured = c.spacing
    rows[#rows + 1] = {{
      text = dot(marked ~= nil and skey(marked) == skey(captured)) .. label,
      callback = function()
        UIManager:close(picker)
        opts.on_pick(captured)
      end,
    }}
  end
  rows[#rows + 1] = {{
    text = _("Back"),
    callback = function()
      UIManager:close(picker)
      if opts.on_back then opts.on_back() end
    end,
  }}
  picker = ButtonDialog:new{
    title = opts.title or _("Checkpoint spacing:"),
    buttons = rows,
  }
  UIManager:show(picker)
end

--- Entry point for the ladder build/resume (X-Ray popup rows). Explicit user
--- action: pre-flight UI gating + a cost dialog, then the silent chain.
function AskGPT:_startXrayLadderBuild(build_opts)
  local XrayAuto = require("koassistant_xray_auto")
  local ActionCache = require("koassistant_action_cache")
  local XrayParser = require("koassistant_xray_parser")
  if XrayAuto.ladderBuild() or XrayAuto.isInFlight() then
    UIManager:show(InfoMessage:new{ text = _("An X-Ray task is already running."), timeout = 2 })
    return
  end
  if not self.ui or not self.ui.document or not self.ui.document.file then return end
  local doc_info = self.ui.document.info
  if not doc_info or doc_info.has_pages then
    UIManager:show(InfoMessage:new{
      text = _("Checkpoint building supports EPUB-style (flowing) documents only."),
      timeout = 3,
    })
    return
  end
  local file = self.ui.document.file

  local action = self.action_service and self.action_service:getAction("book", "xray")
  if not action or not action.update_prompt then return end
  if self:_checkRequirements(action) then return end
  if not NetworkMgr:isWifiOn() then
    UIManager:show(InfoMessage:new{ text = _("WiFi is off."), timeout = 2 })
    return
  end

  -- Base = whichever is further along: the highest existing rung (resume) or the
  -- live incremental X-Ray (a manual update mid-ladder can pass the rungs). No
  -- base at all = build from nothing (rung 1 is a bounded create, §6).
  local ladder = ActionCache.getXrayLadder(file)
  local base_progress = ActionCache.highestXrayLadderProgress(ladder)
  local entry = ActionCache.get(file, "xray")
  local live_ok_base, live_progress = XrayAuto.eligibilityFromEntry(entry, XrayParser.isJSON)
  if not live_ok_base and entry and entry.result then
    -- An incremental-track X-Ray at 100% is a valid (terminal) base — eligibility
    -- only rejects it because there is nothing left to UPDATE. Other ineligible
    -- types (complete-track, AI-knowledge, legacy text) are a different lineage.
    local p = tonumber(entry.progress_decimal)
    if p and p >= 1.0 and not entry.full_document and entry.source_mode ~= "ai_knowledge"
        and XrayParser.isJSON(entry.result) then
      live_ok_base, live_progress = true, p
    end
  end
  -- Deferred rebuild (2026-08-14): the chain replaces the lineage at its
  -- FIRST successful rung — so planning ignores the disk state entirely
  -- (from-scratch grid), and the foreign-lineage bail below does not apply
  -- (replacing such a lineage is exactly what a rebuild is for)
  local chain_rebuild = build_opts and build_opts.rebuild or nil
  if not chain_rebuild then
    if entry and entry.result and not live_ok_base and base_progress == nil then
      UIManager:show(InfoMessage:new{
        text = _("This X-Ray can't build checkpoints (complete-track, AI-knowledge, or legacy format). Delete it first to build from scratch."),
        timeout = 5,
      })
      return
    end
    -- A live INTRO X-Ray (round 20: premise-only, progress 0) is not a build
    -- base — the chain must still create rung 1 from scratch, not "extend" a
    -- deliberately censored artifact
    if live_ok_base and not (entry and entry.intro)
        and (base_progress == nil or (live_progress or 0) > base_progress) then
      base_progress = live_progress
    end
  else
    base_progress = nil
  end

  -- P2(a): spacing adapts to book length (min-pages floor); P3: targets snap
  -- to chapter ends when a usable TOC exists (labels ride into the rung entries).
  -- Spacing slice round 2: the per-run adjust row is retired — the resolved
  -- per-book spacing (form/ask pickers write it) is the run's spacing.
  -- Round 16: build_opts.target (+ target_label) bounds the build below 100%
  -- (unified creation flow: cover one huge section in prefix steps).
  local goal = build_opts and tonumber(build_opts.target) or nil
  -- Round 17: one_shot = a single rung at the goal (same machinery, one
  -- background step). Item 50(a): it serves ALL coverages now — no target
  -- means whole book (goal 1.0, a rung at 100% is a normal ladder end) and
  -- position goals ride through; only the grid path keeps nil-ing near-1.0
  -- goals (whole-book grids plan to 1.0 by default).
  local one_shot = build_opts and build_opts.one_shot or nil
  if one_shot then
    goal = math.min(goal or 1.0, 1.0)
    if goal <= 0.005 then return end
  elseif goal and (goal <= 0.005 or goal >= 1.0 - 0.005) then
    goal = nil
  end
  local goal_label = goal and build_opts and build_opts.target_label or nil
  local features = self.settings:readSetting("features") or {}
  local boundaries = features.xray_ladder_chapter_snap ~= false
    and self:_ladderChapterBoundaries() or nil

  -- Resume = real (non-intro) rungs exist; the intro step (round 20) plans only
  -- on a genuine from-nothing build that hasn't built its intro yet
  local resume, has_intro = false, false
  for _idx, r in ipairs(ladder) do
    if r.intro then has_intro = true else resume = true end
  end
  -- Rebuild chains: old rungs are the OLD lineage (they die at the swap), so
  -- this is never a resume; no intro either — the reader keeps the old live
  -- X-Ray until rung 1 lands, which then covers to their position (seed), so
  -- a premise-only step would buy nothing and complicate the swap ordering
  if chain_rebuild then
    resume, has_intro = false, true
  end
  -- To-position chains (form, 2026-08-25) skip the intro too: the plan ends
  -- at the reader's position, and the form's step count assumes no intro
  local plan_intro = base_progress == nil and not has_intro and not one_shot
    and not (build_opts and build_opts.to_position)
  -- Round 19: a from-nothing build seeds its first checkpoint AT the reading
  -- position, so the reader gets a promotable (openable) X-Ray from the very
  -- first finished rung instead of waiting to cross the first spacing boundary
  local seed_prog = require("koassistant_context_extractor"):new(self.ui):getReadingProgress()
  local seed_position = seed_prog and tonumber(seed_prog.decimal) or nil
  local self_ref = self
  local function planFor(spacing)
    if one_shot then
      if (base_progress or 0) >= goal - 0.01 then return {}, {} end
      return { goal }, (goal_label and { goal_label } or {})
    end
    return self_ref:_planXrayGrid(base_progress, spacing, goal, seed_position, boundaries,
      chain_rebuild)
  end

  -- Round 2 of the spacing slice (device: the confirm "fills the whole
  -- screen"): the text is THREE short lines now — what happens, the plan,
  -- the cost. The per-run "Adjust spacing…" row is RETIRED (redundant with
  -- the form's spacing button; it also stacked a fourth screen).
  local function showConfirm(spacing)
    local rungs, rung_labels, seed = planFor(spacing)
    if #rungs == 0 then
      -- Also the no-ladder-but-live-at-100% case — say why, not "complete"
      UIManager:show(InfoMessage:new{ text = _("Nothing to build: the X-Ray already covers the whole book."), timeout = 3 })
      return
    end
    local snapped = next(rung_labels) ~= nil
    local base_pct = math.floor((base_progress or 0) * 100 + 0.5)
    local goal_text
    if goal then
      goal_text = goal_label
        and T(_("%1% (end of \"%2\")"), math.floor(goal * 100 + 0.5), goal_label)
        or T(_("%1%"), math.floor(goal * 100 + 0.5))
    end
    local state_line
    if chain_rebuild then
      state_line = _("Replaces your current X-Ray from scratch. Nothing is touched until the first new checkpoint arrives; the outgoing version is archived then.")
      -- The foreground rebuild confirm names the checkpoint deletion; this
      -- path routes past that ConfirmBox, so it has to say it itself. A
      -- rebuild clears the whole prepared ladder, and only the installed
      -- version is archived: without this line a lineage of checkpoints
      -- disappears with no warning anywhere (device, twice on 2026-08-18).
      local n_rungs = ActionCache.getXrayLadderCount(file)
      if n_rungs > 0 then
        state_line = state_line .. " "
          .. T(_("Its %1 checkpoints belong to the old version and are deleted then too."), n_rungs)
      end
    elseif one_shot then
      state_line = (base_progress or 0) > 0.005
        and T(_("Extends your X-Ray from %1% to %2."), base_pct, goal_text or "100%")
        or T(_("Covers the book from the beginning to %1."), goal_text or "100%")
    elseif resume or (base_progress or 0) > 0.005 then
      state_line = T(_("Continues from %1% to %2."), base_pct, goal_text or "100%")
    else
      state_line = goal_text
        and T(_("Covers the book from the beginning to %1."), goal_text)
        or _("Covers the whole book from the beginning.")
    end
    local plan_line, cost_line
    if one_shot then
      plan_line = _("One background request.")
      cost_line = _("Keep reading; the book must stay open. A notification arrives when it is ready.")
    else
      if seed and #rungs == 2 then
        plan_line = T(_("2 checkpoints: one at your position (%1%), one at the end."),
          math.floor(seed * 100 + 0.5))
      elseif seed then
        plan_line = snapped
          and T(_("%1 checkpoints: the first at your position (%2%), then chapter ends roughly every %3%."),
            #rungs, math.floor(seed * 100 + 0.5), math.floor(spacing * 100 + 0.5))
          or T(_("%1 checkpoints: the first at your position (%2%), then every %3%."),
            #rungs, math.floor(seed * 100 + 0.5), math.floor(spacing * 100 + 0.5))
      else
        plan_line = snapped
          and T(_("%1 checkpoints, at chapter ends roughly every %2%."),
            #rungs, math.floor(spacing * 100 + 0.5))
          or T(_("%1 checkpoints, every %2%."),
            #rungs, math.floor(spacing * 100 + 0.5))
      end
      if plan_intro then
        plan_line = plan_line .. " " .. T(_("An introduction is generated first (%1 requests in total)."), #rungs + 1)
      end
      cost_line = _("Small background requests; keep reading, cancel anytime, resume later.")
    end
    local confirm
    confirm = ButtonDialog:new{
      title = (one_shot and _("Generate the X-Ray?")
          or resume and _("Resume building X-Ray checkpoints?")
          or _("Build X-Ray checkpoints?"))
        .. "\n" .. state_line
        .. "\n" .. plan_line
        .. "\n" .. cost_line,
      buttons = {
        {{
          text = one_shot and _("Generate") or resume and _("Resume") or _("Build"),
          callback = function()
            UIManager:close(confirm)
            -- Round 22 (D3): an explicit build start ends any cancel pause
            XrayAuto.clearAutoSuppression(file)
            XrayAuto.beginLadderBuild(file, rungs, rung_labels,
              { intro = plan_intro, rebuild = chain_rebuild, one_shot = one_shot })
            self_ref:_fireXrayLadderRung()
          end,
        }},
        {{
          text = _("Cancel"),
          callback = function()
            UIManager:close(confirm)
          end,
        }},
      },
    }
    UIManager:show(confirm)
  end
  -- The run uses the RESOLVED spacing (per-book value or formula); spacing is
  -- changed via the form's spacing button, not here
  showConfirm(self:_xrayLadderSpacing())
end

-- (Round 21's lean Extend chooser retired in round 23 — the dual-mode
-- creation chooser is the single cached-book authoring surface, item 30.)

--- Shared grid planner (round 21, unified engine): the front-load chain and
--- the auto scheduler MUST produce the same checkpoint grid — position seed,
--- goal bound, and chapter snapping all live here. Pure given its inputs.
--- @param base_progress number|nil highest built coverage (nil = from nothing)
--- @param spacing number rung spacing (ladderSpacingFor or a per-run pick)
--- @param goal number|nil coverage goal (nil = 1.0 whole book)
--- @param seed_position number|nil reader position (round-19 seed candidate)
--- @param boundaries table|nil chapter boundaries (nil = no snapping)
--- @return table rungs, table labels (sparse parallel), number|nil seed
function AskGPT:_planXrayGrid(base_progress, spacing, goal, seed_position, boundaries, force_seed)
  local XrayAuto = require("koassistant_xray_auto")
  local rungs, seed = XrayAuto.planBuildRungs(base_progress or 0, spacing, goal, seed_position, force_seed)
  local rung_labels = {}
  local snap_bounds = boundaries
  if goal and snap_bounds then
    -- Intermediate rungs may snap, but never past the target: the final rung
    -- stays exactly at the goal
    local kept = {}
    for _idx, bd in ipairs(snap_bounds) do
      if (bd.ratio or 0) < goal - XrayAuto.LADDER_TOLERANCE then
        kept[#kept + 1] = bd
      end
    end
    snap_bounds = #kept >= 3 and kept or nil
  end
  if snap_bounds then
    if seed then
      -- Snap the tail only: a seed snapped to a boundary ahead of the reader
      -- could never promote — it stays exactly at the position, unlabeled
      local tail = {}
      for i = 2, #rungs do tail[#tail + 1] = rungs[i] end
      local snapped_tail, tail_labels = XrayAuto.snapLadderRungs(tail, snap_bounds, seed, spacing)
      rungs = { seed }
      for _i, t in ipairs(snapped_tail) do rungs[#rungs + 1] = t end
      rung_labels = {}
      for i, l in pairs(tail_labels) do rung_labels[i + 1] = l end
    else
      rungs, rung_labels = XrayAuto.snapLadderRungs(rungs, snap_bounds, base_progress or 0, spacing)
    end
  end
  return rungs, rung_labels, seed
end

--- One rung of the chain: resolve the base fresh from disk (highest rung vs live
--- entry), fire the silent incremental machinery at the rung target, advance from
--- the completion callback. Same authority rule as _fireXrayAutoUpdate — disk
--- truth per rung, config COPY per rung.
function AskGPT:_fireXrayLadderRung()
  local XrayAuto = require("koassistant_xray_auto")
  local build = XrayAuto.ladderBuild()
  if not build then return end
  if not self.ui or not self.ui.document or self.ui.document.file ~= build.file then
    XrayAuto.endLadderBuild()
    return
  end
  -- Round 20: the chain may start with an INTRO step (premise-only version at
  -- progress 0, read from rung 1's slice) before the rungs proper
  local step = XrayAuto.currentLadderStep()
  local target = step and step.target
  local is_intro = (step and step.intro) or false
  if not target or build.cancel_requested then
    XrayAuto.endLadderBuild()
    return
  end
  local file = build.file
  local features = self.settings:readSetting("features") or {}
  local action = self.action_service and self.action_service:getAction("book", "xray")
  if not action or not action.update_prompt then
    XrayAuto.endLadderBuild()
    return
  end
  -- Consent re-check per rung: revoking text extraction mid-build stops the chain
  -- (same rule as the background update path)
  if not self:_xrayBackgroundConsentOk(action, features) then
    XrayAuto.endLadderBuild()
    UIManager:show(InfoMessage:new{ text = _("Checkpoint build stopped: text extraction is disabled."), timeout = 3 })
    return
  end
  if not NetworkMgr:isWifiOn() then
    XrayAuto.endLadderBuild()
    UIManager:show(InfoMessage:new{ text = _("Checkpoint build stopped: WiFi is off."), timeout = 3 })
    return
  end

  local ActionCache = require("koassistant_action_cache")
  local XrayParser = require("koassistant_xray_parser")
  local ladder = ActionCache.getXrayLadder(file)
  if is_intro then
    -- Skip the intro when one already exists (resume) or a live X-Ray appeared
    -- mid-chain — the intro's whole point is "something openable before rung 1"
    local have_intro = false
    for _idx, r in ipairs(ladder) do
      if r.intro and r.result then have_intro = true break end
    end
    local live_now = ActionCache.get(file, "xray")
    if have_intro or (live_now and live_now.result) then
      XrayAuto.completeIntro()
      return self:_fireXrayLadderRung()
    end
  end
  local base, base_progress
  -- Intro rungs never qualify as a base (round 20): a premise-only artifact
  -- must not seed the incremental path — rung 1 creates from scratch
  for _idx, rung in ipairs(ladder) do
    local p = tonumber(rung.progress_decimal)
    if p and rung.result and not rung.intro and (base_progress == nil or p > base_progress) then
      base, base_progress = rung, p
    end
  end
  local entry = ActionCache.get(file, "xray")
  if entry and entry.result and not entry.full_document and not entry.intro
      and entry.source_mode ~= "ai_knowledge" and XrayParser.isJSON(entry.result) then
    local p = tonumber(entry.progress_decimal)
    -- Tie goes to LIVE (2026-08-25): after an install live is the rung's copy
    -- plus whatever the reader renamed, linked or merged since; basing the
    -- next rung on it carries those edits into every later checkpoint
    if p and (base_progress == nil or p >= base_progress) then
      base, base_progress = entry, p
    end
  end
  if is_intro then
    base, base_progress = nil, nil
  end
  -- Deferred rebuild: the old lineage stays UNTOUCHED on disk until the first
  -- new rung lands, so it must not seed this chain either — pre-swap steps
  -- create from scratch; post-swap steps chain on the new rungs normally
  if build.rebuild and not build.rebuild_swapped then
    base, base_progress = nil, nil
  end
  -- Skip threshold MUST be at least the incremental path's engagement threshold
  -- (dialogs.lua: update engages only when target > cached + 0.01) — a narrower
  -- skip would fire a rung the update path then aborts, wedging resume forever
  if base_progress and base_progress >= target - 0.01 then
    -- Already covered (resume overlap) — skip ahead
    XrayAuto.advanceLadderBuild()
    return self:_fireXrayLadderRung()
  end
  local create_mode = base == nil

  self:updateConfigFromSettings()
  local config_copy = {}
  for k, v in pairs(configuration or {}) do config_copy[k] = v end
  config_copy.features = {}
  for k, v in pairs((configuration or {}).features or {}) do config_copy.features[k] = v end
  config_copy.features.is_book_context = true
  config_copy.features._background_request = true
  config_copy.features._background_create = create_mode or nil
  config_copy.features._is_book_level_action = true
  config_copy.features._ladder_build = true
  config_copy.features._ladder_target_ratio = target
  config_copy.features._ladder_base = base
  config_copy.features._ladder_intro = is_intro or nil
  -- Pre-swap rebuild rung (2026-08-15 device round): the step carries NO base
  -- BY DESIGN — without this marker the dialogs cache-engagement fallback read
  -- the surviving old live artifact as an incremental base and merged the very
  -- lineage the rebuild was replacing back into the fresh create
  config_copy.features._ladder_fresh = (build.rebuild and not build.rebuild_swapped) or nil
  config_copy.features._ladder_chapter_label = (not is_intro) and build.labels and build.labels[build.idx] or nil
  -- Item 50 follow-up: user-initiated builds keep the large-extraction warning
  -- on their FIRST request (it fires right after the confirm tap, so a dialog
  -- is fine); later steps never dialog — an oversized one PAUSES for review
  -- instead (dialogs seam; build.size_ack is set there on acceptance and
  -- stands for the rest of the build).
  if not build.silent and not build.size_checked then
    config_copy.features._ladder_size_check = true
    build.size_checked = true
  end

  local doc_props = self.ui.doc_props or {}
  local title = doc_props.display_title or doc_props.title or "Unknown"
  local authors = doc_props.authors or ""
  if authors:find("\n") then authors = authors:gsub("\n", ", ") end
  local raw_doc_props = getRawDocProps(file) or doc_props
  config_copy.features.book_metadata = buildBookMetadata(title, authors, file, raw_doc_props,
      self.ui.document, self.ui.doc_settings)
  config_copy.features.book_context = bookContextString(config_copy.features.book_metadata)

  XrayAuto.beginFlight(file)
  -- No watchdog (retired 2026-08-05 — see the note at the solo update fire):
  -- chains always show a tap-to-cancel row, and slow is not stuck
  local self_ref = self

  -- Intro step (round 20): same slice as rung 1, but the prompt asks for a
  -- premise-only, spoiler-free introduction (action copy — never mutate the
  -- shared action table). Prompt text is wire content, not UI — no _().
  local fire_action = action
  if is_intro then
    fire_action = {}
    for k, v in pairs(action) do fire_action[k] = v end
    fire_action.prompt = (action.prompt or "")
      .. "\n\nIMPORTANT — INTRODUCTORY X-RAY: This X-Ray is a spoiler-free introduction for a reader who has NOT started the book yet. Cover only the premise, the setting, and the characters, concepts, or terms as they stand when first introduced in this opening portion. Do not mention any developments, reveals, relationships, or events beyond the initial setup."
  end

  local step_no = build.step or build.idx
  if is_intro then
    logger.dbg("KOAssistant: ladder step", step_no, "of", build.total, "firing (introduction)")
  else
    logger.dbg("KOAssistant: ladder step", step_no, "of", build.total, "firing (to", target, ")")
  end
  -- Silent chains (round 21: the auto scheduler) toast only on the
  -- xray_auto_notify opt-in; failures below stay visible regardless
  if not build.silent or features.xray_auto_notify == true then
    -- Item 50(a): a one-step build is a background one-shot, not a chain
    local toast_text = build.total == 1
        and T(_("Generating X-Ray in the background (to %1%)…"),
          math.floor(target * 100 + 0.5))
      or is_intro
        and T(_("X-Ray checkpoints: %1 of %2 (introduction)…"), step_no, build.total)
      or T(_("X-Ray checkpoints: %1 of %2 (to %3%)…"),
        step_no, build.total, math.floor(target * 100 + 0.5))
    if config_copy.features._ladder_size_check then
      -- Follow-up 2: nothing may announce a build the size warning can still
      -- cancel — the toast rides to the send seam and fires with the request
      config_copy.features._ladder_send_toast = toast_text
    else
      UIManager:show(Notification:new{ text = toast_text })
    end
  end
  Dialogs.executeActionForResult(fire_action, config_copy.features.book_context, self.ui, config_copy, self,
    config_copy.features.book_metadata,
    function(result, meta_or_err)
      XrayAuto.endFlight()
      local was_cancelled = XrayAuto.consumeOutcomeFlags()
      local cur = XrayAuto.ladderBuild()
      if not cur then return end  -- build ended (close/cancel) while in flight
      if was_cancelled or cur.cancel_requested then
        XrayAuto.endLadderBuild()
        UIManager:show(Notification:new{ text = cur.total == 1
          and _("X-Ray generation cancelled.") or _("Checkpoint build cancelled.") })
        return
      end
      -- Honesty check: the rung must actually be on disk — truncated responses and
      -- silent save failures never advance the chain. The intro writes at
      -- progress 0, so it is verified by presence, not by coverage progress.
      local rung_written
      if is_intro then
        for _idx, r in ipairs(ActionCache.getXrayLadder(file)) do
          if r.intro and r.result then rung_written = true break end
        end
        rung_written = result and rung_written
      else
        local on_disk = ActionCache.highestXrayLadderProgress(ActionCache.getXrayLadder(file))
        rung_written = result and on_disk and on_disk >= target - XrayAuto.LADDER_TOLERANCE
      end
      if not rung_written then
        -- The completion callback is (history, temp_config) on SUCCESS and
        -- (nil, err_string) on failure, so a request that SUCCEEDED but whose
        -- rung failed to write arrives here with a TABLE in the error slot —
        -- tostring gave "table: 0x…" as the stop reason, which is what the
        -- device log showed when a rung was rejected as invalid JSON.
        local err_text = type(meta_or_err) == "string" and meta_or_err
            or (result and "rung not written (response rejected or save failed)")
            or "rung not saved"
        -- Item 50 follow-up: declining the size warning is a clean user
        -- cancel, not a failure — no stop record, no resume nudge
        if err_text == "size_warning_declined" then
          XrayAuto.endLadderBuild()
          UIManager:show(Notification:new{ text = cur.total == 1
            and _("X-Ray generation cancelled.") or _("Checkpoint build cancelled.") })
          return
        end
        -- Follow-up 3: "In checkpoints instead" from the size warning — the
        -- one-shot converts to a checkpoint build over the same range; the
        -- checkpoint confirm then shows the plan + spacing adjuster
        if err_text == "size_switch_checkpoints" then
          XrayAuto.endLadderBuild()
          local goal = cur.rungs and cur.rungs[#cur.rungs]
          self_ref:_startXrayLadderBuild({
            target = (goal and goal < 1.0 - 0.005) and goal or nil,
            target_label = cur.labels and cur.labels[#cur.rungs] or nil,
          })
          return
        end
        -- Follow-up 2: an unattended oversized step pauses the chain — a stop
        -- WITH record so the resume row explains itself; resuming starts a
        -- fresh (attended) build, which re-arms the warning with real numbers
        if err_text == "size_needs_review" then
          XrayAuto.endLadderBuild()
          XrayAuto.recordLadderStop(file, { step = cur.step or cur.idx, total = cur.total,
            kind = "step_too_large",
            rebuild = (cur.rebuild and not cur.rebuild_swapped) or nil })
          UIManager:show(InfoMessage:new{
            text = T(_("Checkpoint build paused at %1 of %2: the next step is a large request. Resume from the X-Ray popup to review it."),
              cur.step or cur.idx, cur.total),
            timeout = 5,
          })
          return
        end
        local kind, transient = XrayAuto.classifyStopReason(err_text)
        -- Item 45: one silent retry per step for transient provider failures
        -- (503/429/5xx/network) — the field specimen healed on a resume 76s
        -- later. The build state stays ALIVE through the wait so cancel works.
        if transient and (cur.retried or 0) < 1 and not cur.cancel_requested then
          cur.retried = 1
          logger.dbg("KOAssistant: ladder step", cur.step or cur.idx, "transient failure (",
            kind, ") - retrying in", XrayAuto.RETRY_DELAY_S, "s:", err_text)
          if not cur.silent or features.xray_auto_notify == true then
            UIManager:show(Notification:new{
              text = T(_("Model busy — retrying checkpoint %1 of %2 in %3 s…"),
                cur.step or cur.idx, cur.total, XrayAuto.RETRY_DELAY_S),
            })
          end
          local retry_fn = function()
            self_ref._xray_ladder_retry = nil
            local live = XrayAuto.ladderBuild()
            if not live or live.file ~= file or live.cancel_requested then return end
            if not (self_ref.ui and self_ref.ui.document
                and self_ref.ui.document.file == file) then
              -- Book closed during the wait: mirror the between-rung guard
              XrayAuto.endLadderBuild()
              return
            end
            self_ref:_fireXrayLadderRung()
          end
          self_ref._xray_ladder_retry = retry_fn
          UIManager:scheduleIn(XrayAuto.RETRY_DELAY_S, retry_fn)
          return
        end
        XrayAuto.endLadderBuild()
        XrayAuto.recordLadderStop(file, { step = cur.step or cur.idx, total = cur.total,
          kind = kind,
          rebuild = (cur.rebuild and not cur.rebuild_swapped) or nil })
        logger.dbg("KOAssistant: ladder build stopped at step", cur.step or cur.idx, "-",
          err_text)
        local reason = self_ref:_xrayStopReasonLabel(kind)
        UIManager:show(InfoMessage:new{
          text = reason
            and T(_("Checkpoint build stopped at %1 of %2 (%3): resume it from the X-Ray popup."),
              cur.step or cur.idx, cur.total, reason)
            or T(_("Checkpoint build stopped at %1 of %2: resume it from the X-Ray popup."),
              cur.step or cur.idx, cur.total),
          timeout = 4,
        })
        return
      end
      -- A landed rung refreshes the step's retry budget (item 45)
      cur.retried = nil
      -- Round 19: a finished rung at-or-below the reader installs NOW — the
      -- seed (and any catch-up rung) must not wait for the whole chain.
      -- pickPromotableRung no-ops when nothing at-or-below qualifies; with no
      -- live X-Ray at all, the intro installs (round 20).
      self_ref:_fireXrayLadderPromotion({ mid_build = true })
      local next_target
      if is_intro then
        XrayAuto.completeIntro()
        local nxt = XrayAuto.currentLadderStep()
        next_target = nxt and nxt.target
      else
        next_target = XrayAuto.advanceLadderBuild()
      end
      if next_target and self_ref.ui and self_ref.ui.document
          and self_ref.ui.document.file == file then
        -- Yield the UI between rungs
        UIManager:scheduleIn(1, function()
          self_ref:_fireXrayLadderRung()
        end)
      else
        XrayAuto.endLadderBuild()
        self_ref._file_dialog_row_cache = { file = nil, rows = nil }
        -- 2026-08-15 device round: a commissioned ONE-SHOT installs its goal
        -- rung regardless of the promotion posture — the user explicitly asked
        -- for that coverage, so the position gate does not apply (deliberate
        -- install, item 40: never auto-reverted; a complete install releases
        -- the promotion hold like the switch rows do). Without this, a
        -- "complete X-Ray in background" finished into the ladder and the
        -- track posture never installed it — the user saw nothing (or a
        -- position rung) plus phantom "checkpoints".
        local installed_pct
        if cur.one_shot then
          local goal_t = cur.rungs and cur.rungs[#cur.rungs]
          local goal_rung
          for _idx2, r in ipairs(ActionCache.getXrayLadder(file)) do
            local p = tonumber(r.progress_decimal)
            if p and goal_t and r.result and not r.intro
                and math.abs(p - goal_t) <= XrayAuto.LADDER_TOLERANCE then
              goal_rung = r
            end
          end
          if goal_rung and ActionCache.promoteXrayLadderRung(file, goal_rung,
              ActionCache.checkpointLimitFromFeatures(features)) then
            local gp = tonumber(goal_rung.progress_decimal) or 0
            installed_pct = math.floor(gp * 100 + 0.5)
            if gp >= 1.0 - 0.005 then
              self_ref:_setXrayPromotionHold(file, false)
            end
            logger.info("KOAssistant: one-shot X-Ray installed at", tostring(gp))
            -- §14: every install into live runs the pair-check (stamped once per pair)
            UIManager:scheduleIn(1, function() self_ref:maybeOfferDedupAsk(file) end)
          end
        end
        if not cur.silent or features.xray_auto_notify == true then
          UIManager:show(Notification:new{
            text = installed_pct and T(_("X-Ray ready (covers to %1%)."), installed_pct)
              or cur.total == 1 and _("X-Ray ready.")
              or T(_("X-Ray checkpoints built (%1)."), cur.total),
          })
        end
        self_ref:_refreshXrayAutoState()
        -- B261: a completed chain lifts the cooldown — the next due
        -- checkpoint may fire on the next page turn
        XrayAuto.clearScheduled()
        if not installed_pct then
          -- Bring the live X-Ray up to the reader's position for free
          self_ref:_fireXrayLadderPromotion()
        end
      end
    end)
end

--- Short translated label for a chain-stop reason kind (item 45); nil for
--- kinds not worth a clause ("other").
function AskGPT:_xrayStopReasonLabel(kind)
  if kind == "overloaded" then return _("model overloaded") end
  if kind == "rate_limited" then return _("rate limited") end
  if kind == "server_error" then return _("provider error") end
  if kind == "timeout" then return _("request timed out") end
  if kind == "network" then return _("connection problem") end
  if kind == "bad_json" then return _("unusable response") end
  if kind == "step_too_large" then return _("large step needs review") end
  return nil
end

--- Stop the chain (popup row). An in-flight rung is killed; completed rungs stay
--- (resume re-plans from the highest one).
function AskGPT:_cancelXrayLadderBuild()
  local XrayAuto = require("koassistant_xray_auto")
  -- Item 45: a pending transient-failure retry dies with the build
  if self._xray_ladder_retry then
    UIManager:unschedule(self._xray_ladder_retry)
    self._xray_ladder_retry = nil
  end
  -- Round 22 (D3): an explicit cancel must stick — without suppression the
  -- next page turn re-plans the very chain the user just cancelled (the
  -- cooldown was stamped at schedule time and has often already elapsed).
  -- Session-scoped; any explicit engine start or reopening the book clears it.
  local build = XrayAuto.ladderBuild()
  local cancelled_file = (build and build.file) or XrayAuto.inFlightFile()
    or (self.ui and self.ui.document and self.ui.document.file)
  XrayAuto.suppressAuto(cancelled_file)
  XrayAuto.markScheduled(os.time())
  XrayAuto.requestLadderCancel()
  XrayAuto.cancelInFlight()
  -- 2026-08-15 (A5): the explicit cancel leaves the same resumable stop
  -- record the failure paths leave — without it, cancelling a PRE-SWAP
  -- rebuild silently resumed as a plain extend of the very lineage the
  -- rebuild was replacing. Post-swap cancels record rebuild=nil: the new
  -- lineage is live, the remaining rungs ARE a plain extend.
  if build and build.file then
    XrayAuto.recordLadderStop(build.file, { step = build.step or build.idx,
      total = build.total, kind = "cancelled",
      rebuild = (build.rebuild and not build.rebuild_swapped) or nil })
  end
  XrayAuto.endLadderBuild()
  -- Short toast (Notification renders ONE line — long text truncates); the
  -- popup's "Resume automatic building (paused)…" / Resume rows are the way
  -- back in, and reopening the book clears the pause
  UIManager:show(Notification:new{
    text = _("Build cancelled: resume from the X-Ray popup."),
  })
end

--- Kill anything pending or in flight when the book closes. (The completion guard
--- makes a straggler write impossible regardless; this just stops wasted work.)
function AskGPT:onCloseDocument()
  require("koassistant_xray_marks").teardown(self)
  if self._xray_auto_pending then
    UIManager:unschedule(self._xray_auto_pending)
    self._xray_auto_pending = nil
    self._xray_auto_pending_logged = nil
  end
  if self._xray_ladder_promo_pending then
    UIManager:unschedule(self._xray_ladder_promo_pending)
    self._xray_ladder_promo_pending = nil
  end
  local XrayAuto = require("koassistant_xray_auto")
  local closing_build = XrayAuto.ladderBuild()
  if closing_build then
    -- Completed rungs stay on disk; the popup offers Resume next open.
    -- 2026-08-15 (A5): record the stop like the failure paths do — closing
    -- the book mid-chain used to drop the PRE-SWAP rebuild flag, so the
    -- resume row restarted the chain as a plain extend of the lineage the
    -- rebuild was replacing (post-swap closes record rebuild=nil: correct,
    -- the new lineage is live and the rest IS an extend)
    if closing_build.file then
      XrayAuto.recordLadderStop(closing_build.file, {
        step = closing_build.step or closing_build.idx,
        total = closing_build.total, kind = "interrupted",
        rebuild = (closing_build.rebuild and not closing_build.rebuild_swapped) or nil })
    end
    XrayAuto.endLadderBuild()
  end
  XrayAuto.cancelInFlight()
  -- Round 22 (D3): the cancel suppression is session-scoped — reopening the
  -- book starts fresh
  if self.ui and self.ui.document and self.ui.document.file then
    XrayAuto.clearAutoSuppression(self.ui.document.file)
  end
end

--- Show a "quiz?" popup for a finished chapter.
--- Applies the substance gate (min pages) and skips if a quiz already exists for this chapter.
--- @param chapter_index number TOC index of the finished chapter
--- @return boolean  true if the prompt was scheduled, false if gated out (length/cache)
function AskGPT:_offerChapterQuiz(chapter_index)
  local toc_entries = self.ui.toc.toc
  local chapter = toc_entries[chapter_index]
  if not chapter then return false end

  -- Resolve the substance gates (per-book > global > schema default 5 pages / 3 min) via the one
  -- shared resolver, so the active defaults can't drift from the schema. 0 = no minimum.
  local features = self.settings:readSetting("features") or {}
  local quiz = require("koassistant_book_settings").resolveQuiz(self.ui and self.ui.doc_settings, features)

  -- Minimum chapter length gate (#68): skip the auto-quiz for very short chapters, measured over
  -- the chapter's actual content range (= the quiz scope).
  local min_pages = quiz.min_pages
  if min_pages > 0 then
    local s, e = self:_chapterContentRange(chapter_index)
    if s and e and (e - s + 1) < min_pages then return false end
  end

  local chapter_title = chapter.title or ""
  if self.ui.toc.cleanUpTocTitle then
    chapter_title = self.ui.toc:cleanUpTocTitle(chapter_title) or chapter_title
  end

  -- Skip if a quiz already exists for this chapter (check section cache)
  local file = self.ui and self.ui.document and self.ui.document.file
  if file then
    local ActionCache = require("koassistant_action_cache")
    local prefix = ActionCache.SECTION_PREFIXES.quiz
    if prefix then
      local cache_label = (chapter_title ~= "" and chapter_title or T(_("Chapter %1"), chapter_index)):gsub(":", "-")
      local cached = ActionCache.get(file, prefix .. cache_label)
      if cached and cached.result then return false end
    end
  end

  -- Minimum reading-time gate: skip if the reader spent too little time in this chapter (catches
  -- flipping fast through a long chapter, which the page-length gate can't — fast-flipped pages
  -- record ~0s in KOReader's stats). Fails OPEN: when stats are unavailable, _chapterReadingTime
  -- returns nil and the quiz is still offered. Last (it's the only gate that touches the stats DB).
  local min_time = quiz.min_minutes
  if min_time > 0 then
    local s, e = self:_chapterContentRange(chapter_index)
    local secs = self:_chapterReadingTime(s, e)
    if secs ~= nil and secs < min_time * 60 then return false end
  end

  local display_title = chapter_title ~= "" and chapter_title or T(_("Chapter %1"), chapter_index)

  local self_ref = self
  UIManager:scheduleIn(0.3, function()
    local ConfirmBox = require("ui/widget/confirmbox")
    -- Running through several chapters fires several offers — replace the
    -- previous one instead of stacking (device 2026-08-13)
    if self_ref._quiz_offer_box and UIManager:isWidgetShown(self_ref._quiz_offer_box) then
      UIManager:close(self_ref._quiz_offer_box)
    end
    self_ref._quiz_offer_box = ConfirmBox:new{
      text = T(_("End of: %1\n\nWould you like a comprehension quiz?"), display_title),
      ok_text = _("Quiz"),
      cancel_text = _("Skip"),
      ok_callback = function()
        self_ref:_runChapterQuiz(chapter_index)
      end,
      -- Inline per-book controls: turn the chapter quiz off for this book, or open its settings.
      other_buttons_first = true,
      other_buttons = {{
        {
          text = _("Not for this book"),
          callback = function()
            require("koassistant_book_settings").setQuizField(
              self_ref.ui and self_ref.ui.doc_settings, "enabled", false)
            UIManager:show(InfoMessage:new{
              text = _("Chapter quizzes turned off for this book.\nRe-enable in Book Settings → Quiz."),
              timeout = 3,
            })
          end,
        },
        {
          text = _("Quiz settings…"),
          callback = function()
            -- The ConfirmBox died with this tap, so the settings screen re-offers
            -- THIS chapter's quiz on close (was a dead end: settings opened, and
            -- the only path back to the quiz was the NEXT chapter trigger).
            -- Suppressed when the reader just used the screen to turn chapter
            -- quizzes off — globally or for this book.
            require("koassistant_book_settings").showQuizConfig({
              plugin = self_ref, ui = self_ref.ui,
              on_close = function()
                local feats = self_ref.settings:readSetting("features") or {}
                if feats.enable_chapter_quiz ~= true then return end
                local bq = self_ref.ui and self_ref.ui.doc_settings
                    and self_ref:_openBookDS():readSetting("koassistant_book_quiz")
                if bq and bq.enabled == false then return end
                UIManager:show(ConfirmBox:new{
                  text = T(_("End of: %1\n\nStart the quiz now?"), display_title),
                  ok_text = _("Quiz"),
                  cancel_text = _("Skip"),
                  ok_callback = function()
                    self_ref:_runChapterQuiz(chapter_index)
                  end,
                })
              end,
            })
          end,
        },
      }},
    }
    UIManager:show(self_ref._quiz_offer_box)
  end)
  return true
end

--- Execute a chapter quiz for the specified chapter.
--- Extracts chapter boundaries from TOC and runs the quiz action
--- with section scope matching the chapter's page range.
--- @param chapter_index number TOC index of the chapter
function AskGPT:_runChapterQuiz(chapter_index)
  self:ensureInitialized()

  local toc_entries = self.ui.toc.toc
  local chapter = toc_entries[chapter_index]
  if not chapter then return end

  -- Chapter content page range (next entry at same-or-shallower depth → quiz scope)
  local start_page, end_page = self:_chapterContentRange(chapter_index)

  local chapter_title = chapter.title or ""
  if self.ui.toc.cleanUpTocTitle then
    chapter_title = self.ui.toc:cleanUpTocTitle(chapter_title) or chapter_title
  end

  -- Get the chapter_quiz action
  local action = self.action_service:getAction("book", "quiz")
  if not action then return end

  -- Block if requirements unmet
  if self:_checkRequirements(action) then return end

  -- Execute using the standard section action path (scoped extraction)
  local label = chapter_title ~= "" and chapter_title or T(_("Chapter %1"), chapter_index)
  self:_executeSectionAction(action, "quiz", {
    start_page = start_page,
    end_page = end_page,
    title = label,
  }, label, { source_mode = "full_text" })
end


--- Helper function to execute book-level actions (X-Ray, Recap, Analyze My Notes)
--- @param action_id string: The action ID from Actions.book
function AskGPT:executeBookLevelAction(action_id)
  -- Check if we have a document open
  if not self.ui or not self.ui.document then
    UIManager:show(InfoMessage:new{
      icon = "notice-warning",
      text = _("Please open a book first")
    })
    return
  end

  -- Get the action from ActionService instance (includes user overrides)
  local action = self.action_service:getAction("book", action_id)
  if not action then
    UIManager:show(InfoMessage:new{
      icon = "notice-warning",
      text = T(_("Action '%1' not found"), action_id)
    })
    return
  end

  -- Block actions when declared requirements are unmet
  if self:_checkRequirements(action) then
    return
  end

  -- Cache actions with source_selection: View/Sections/New popup (or direct to unified popup)
  if action.use_response_caching and action.source_selection then
    local ActionCache = require("koassistant_action_cache")
    local file = self.ui and self.ui.document and self.ui.document.file
    local cached = file and ActionCache.get(file, action_id)
    -- Fallback: check document-level cache (migration from pre-per-action cache)
    if not cached or not cached.result then
      if action.cache_as_summary then
        cached = ActionCache.getSummaryCache(file)
      elseif action.cache_as_analyze then
        cached = ActionCache.getAnalyzeCache(file)
      end
    end
    if cached and cached.result then
      -- Show View / [Update/Redo] / Sections / New initial popup
      local action_name = action.text or action_id
      local view_detail = ""
      if cached.progress_decimal or cached.timestamp then
        local parts = {}
        if cached.intro then
          table.insert(parts, _("introduction"))
        elseif cached.progress_decimal then
          table.insert(parts, math.floor(cached.progress_decimal * 100 + 0.5) .. "%")
        end
        local rel_time = formatRelativeTime(cached.timestamp)
        if rel_time ~= "" then
          table.insert(parts, rel_time)
        end
        if #parts > 0 then
          view_detail = " (" .. table.concat(parts, ", ") .. ")"
        end
      end
      local ButtonDialog = require("ui/widget/buttondialog")
      local self_ref = self
      local dialog
      local popup_buttons = {}
      -- View existing artifact
      table.insert(popup_buttons, {{
        text = T(_("View %1"), action_name .. view_detail),
        callback = function()
          UIManager:close(dialog)
          self_ref:viewCachedAction(action, action_id, cached, {
            file = file,
          })
        end,
      }})
      -- Surface in-range section artifacts
      local section_prefix = ActionCache.getSectionPrefix(action_id)
      local doc = self.ui and self.ui.document
      if section_prefix and file and doc then
        local in_range = ActionCache.findMatchingSections(file, doc, section_prefix)
        for _idx, sec in ipairs(in_range) do
          local page_info = ActionCache.reconvertPageSummary(sec.data, doc)
          local sec_detail_parts = {}
          if page_info and page_info ~= "" then
            table.insert(sec_detail_parts, page_info)
          end
          local sec_rel = formatRelativeTime(sec.data.timestamp)
          if sec_rel ~= "" then
            table.insert(sec_detail_parts, sec_rel)
          end
          local sec_detail = #sec_detail_parts > 0 and " (" .. table.concat(sec_detail_parts, ", ") .. ")" or ""
          local captured_sec = sec
          table.insert(popup_buttons, {{
            text = T(_("View \"%1\""), sec.label) .. sec_detail,
            callback = function()
              UIManager:close(dialog)
              self_ref:viewCachedAction(action, action_id, captured_sec.data, {
                section_key = captured_sec.key,
                section_label = captured_sec.label,
              })
            end,
          }})
        end
      end
      -- Update/Redo for position-relevant actions (e.g. Recap)
      if action.use_reading_progress then
        local cached_progress = cached.progress_decimal or 0
        local update_text
        if self.ui and self.ui.document then
          local ContextExtractor = require("koassistant_context_extractor")
          local extractor = ContextExtractor:new(self.ui)
          local progress = extractor:getReadingProgress()
          if progress.decimal > cached_progress + 0.01 then
            update_text = T(_("Update %1"), action_name .. " (" .. T(_("to %1"), progress.formatted) .. ")")
          else
            update_text = T(_("Redo %1"), action_name)
          end
        else
          update_text = T(_("Redo %1"), action_name)
        end
        table.insert(popup_buttons, {{
          text = update_text,
          callback = function()
            UIManager:close(dialog)
            -- Use cached source_mode for update/redo (same source)
            self_ref:_executeBookLevelActionDirect(action, action_id, { source_mode = cached.source_mode })
          end,
        }})
      end
      -- Browse remaining section artifacts (all sections in group)
      if section_prefix and file then
        local sec_count = ActionCache.getSectionCount(file, section_prefix)
        if sec_count > 0 then
          table.insert(popup_buttons, {{
            text = string.format("%s (%d)", ActionCache.getSectionGroupName(action_id) or _("Sections"), sec_count),
            callback = function()
              UIManager:close(dialog)
              self_ref:_showSectionList(action, action_id)
            end,
          }})
        end
      end
      -- New generation (opens scope/source popup)
      table.insert(popup_buttons, {{
        text = T(_("New %1…"), action_name),
        callback = function()
          UIManager:close(dialog)
          self_ref:_showUnifiedActionPopup(action, action_id, {
            on_execute = function(popup_state)
              self_ref:_executeBookLevelActionDirect(action, action_id, { source_mode = popup_state.source })
            end,
          })
        end,
      }})
      table.insert(popup_buttons, {{
        text = _("Cancel"),
        callback = function()
          UIManager:close(dialog)
        end,
      }})
      dialog = ButtonDialog:new{
        title = action_name,
        buttons = popup_buttons,
      }
      UIManager:show(dialog)
    else
      -- No cache: check for existing section artifacts before going to scope/source popup
      local self_ref = self
      local section_prefix = ActionCache.getSectionPrefix(action_id)
      local sec_count = section_prefix and file and ActionCache.getSectionCount(file, section_prefix) or 0
      if sec_count > 0 then
        -- Show surfaced sections / Sections group / New popup
        local action_name = action.text or action_id
        local ButtonDialog = require("ui/widget/buttondialog")
        local nc_dialog
        local nc_buttons = {}
        -- Surface in-range section artifacts
        local doc = self.ui and self.ui.document
        if section_prefix and file and doc then
          local in_range = ActionCache.findMatchingSections(file, doc, section_prefix)
          for _idx, sec in ipairs(in_range) do
            local page_info = ActionCache.reconvertPageSummary(sec.data, doc)
            local sec_parts = {}
            if page_info and page_info ~= "" then
              table.insert(sec_parts, page_info)
            end
            local sec_rel = formatRelativeTime(sec.data.timestamp)
            if sec_rel ~= "" then
              table.insert(sec_parts, sec_rel)
            end
            local sec_detail = #sec_parts > 0 and " (" .. table.concat(sec_parts, ", ") .. ")" or ""
            local captured_sec = sec
            table.insert(nc_buttons, {{
              text = T(_("View \"%1\""), sec.label) .. sec_detail,
              callback = function()
                UIManager:close(nc_dialog)
                self_ref:viewCachedAction(action, action_id, captured_sec.data, {
                  file = file,
                  section_key = captured_sec.key,
                  section_label = captured_sec.label,
                })
              end,
            }})
          end
        end
        table.insert(nc_buttons, {{
          text = string.format("%s (%d)", ActionCache.getSectionGroupName(action_id) or _("Sections"), sec_count),
          callback = function()
            UIManager:close(nc_dialog)
            self_ref:_showSectionList(action, action_id)
          end,
        }})
        table.insert(nc_buttons, {{
          text = T(_("New %1…"), action_name),
          callback = function()
            UIManager:close(nc_dialog)
            self_ref:_showUnifiedActionPopup(action, action_id, {
              on_execute = function(popup_state)
                self_ref:_executeBookLevelActionDirect(action, action_id, { source_mode = popup_state.source })
              end,
            })
          end,
        }})
        table.insert(nc_buttons, {{
          text = _("Cancel"),
          callback = function()
            UIManager:close(nc_dialog)
          end,
        }})
        nc_dialog = ButtonDialog:new{
          title = action_name,
          buttons = nc_buttons,
        }
        UIManager:show(nc_dialog)
      else
        self:_showUnifiedActionPopup(action, action_id, {
          on_execute = function(popup_state)
            self_ref:_executeBookLevelActionDirect(action, action_id, { source_mode = popup_state.source })
          end,
        })
      end
    end
    return
  end

  -- For other cache actions (without source_selection): show View/Update popup
  if action.use_response_caching then
    local self_ref = self
    self:showCacheActionPopup(action, action_id, function()
      self_ref:_executeBookLevelActionDirect(action, action_id)
    end)
    return
  end

  -- Unified popup for source_selection actions (scope + source in one dialog)
  if action.source_selection then
    local self_ref = self
    self:_showUnifiedActionPopup(action, action_id, {
      on_execute = function(popup_state)
        self_ref:_executeBookLevelActionDirect(action, action_id, { source_mode = popup_state.source })
      end,
    })
    return
  end

  self:_executeBookLevelActionDirect(action, action_id)
end

--- Internal: Execute a book-level action directly (after popup, if any)
--- @param action table: The action definition
--- @param action_id string: The action ID
--- @param opts table|nil: Optional { full_document = true, update_to_full = true }
function AskGPT:_executeBookLevelActionDirect(action, action_id, opts)
  -- Make sure we're using the latest configuration
  self:updateConfigFromSettings()

  -- Build config with book context
  -- IMPORTANT: Create a proper shallow copy with a NEW features object
  -- to avoid polluting the global configuration.features
  local config_copy = {}
  for k, v in pairs(configuration or {}) do
    config_copy[k] = v
  end
  -- Create NEW features table (don't share reference with global configuration)
  config_copy.features = {}
  for k, v in pairs((configuration or {}).features or {}) do
    config_copy.features[k] = v
  end
  config_copy.features.is_book_context = true  -- Signal book context to getPromptContext()

  -- Full-document X-Ray: propagate transient flag to config for prompt transformation in dialogs
  if opts and opts.full_document then
    config_copy.features._full_document_xray = true
  end
  -- Deferred rebuild (round 25): the old X-Ray is still on disk while this
  -- request runs — the flag makes the create ignore it (from-nothing) and
  -- hands the destructive half to the successful write
  if opts and opts.xray_rebuild then
    config_copy.features._xray_rebuild = true
  end
  -- Update to 100%: override progress to 1.0 (same spoiler-free prompt, no schema change)
  if opts and opts.update_to_full then
    config_copy.features._update_to_full_progress = true
  end
  -- Complete analysis: override progress to 1.0 (no spoiler restrictions for Analyze Notes)
  if opts and opts.complete_analysis then
    config_copy.features._complete_analysis = true
  end
  -- Source mode: controls which data {document_context_section} resolves to
  if opts and opts.source_mode then
    config_copy.features._source_mode = opts.source_mode
  end
  -- Section X-Ray: propagate scope and trigger full extraction
  if opts and opts.section_xray then
    config_copy.features._section_xray = opts.section_xray
    config_copy.features._full_document_xray = true  -- Triggers full extraction + 100% progress
  end
  -- Generic section scope: propagate scope for any action type
  if opts and opts.section_scope then
    config_copy.features._section_scope = opts.section_scope
    config_copy.features._full_document_xray = true  -- Triggers full extraction + 100% progress
    -- Pass chapter title for quiz viewer (consumed by onComplete routing)
    if action and action.interactive_quiz and opts.section_scope.label then
      config_copy.features._chapter_quiz_title = opts.section_scope.label
    end
  end

  -- Get book metadata from KOReader's merged props (includes user edits from Book Info dialog)
  local doc_props = self.ui.doc_props or {}
  local title = doc_props.display_title or doc_props.title or "Unknown"
  local authors = doc_props.authors or ""
  -- Normalize multi-author strings (KOReader stores as newline-separated)
  if authors:find("\n") then
    authors = authors:gsub("\n", ", ")
  end
  local doc_file = self.ui and self.ui.document and self.ui.document.file
  local raw_doc_props = getRawDocProps(doc_file) or doc_props
  config_copy.features.book_metadata = buildBookMetadata(title, authors, doc_file, raw_doc_props,
      self.ui and self.ui.document, self.ui and self.ui.doc_settings)

  -- Display/fallback book-context string, derived from the overridden metadata (title+author only).
  local book_context = bookContextString(config_copy.features.book_metadata)
  config_copy.features.book_context = book_context
  -- Signal that highlighted_text is synthetic book metadata, not user-selected text
  -- (used by handlePredefinedPrompt to skip source_highlight for chat naming)
  config_copy.features._is_book_level_action = true

  -- Execute the action with book context as highlighted text
  NetworkMgr:runWhenConnected(function()
    Dialogs.executeDirectAction(
      self.ui,
      action,
      book_context,
      config_copy,
      self
    )
  end)
end

--- Execute an action from the file browser long-press menu (pinned action)
--- Sets up book metadata context and calls executeDirectAction without requiring an open document.
--- @param file string: Path to the book file
--- @param title string: Book title
--- @param authors string: Book authors
--- @param book_props table: Book properties from file manager
--- @param action_id string: The action ID to execute
function AskGPT:executeFileBrowserAction(file, title, authors, book_props, action_id)
  -- Normalize multi-author strings (KOReader stores as newline-separated)
  if authors and authors:find("\n") then
    authors = authors:gsub("\n", ", ")
  end
  -- Set context flags (same pattern as showKOAssistantDialogForFile)
  configuration.features = configuration.features or {}
  configuration.features.is_general_context = nil
  configuration.features.is_book_context = true
  configuration.features.is_library_context = nil
  configuration.features.book_metadata = buildBookMetadata(title, authors, file, getRawDocProps(file) or book_props)

  -- Display/fallback book-context string, derived from the overridden metadata (title+author only).
  local book_context = bookContextString(configuration.features.book_metadata)
  configuration.features.book_context = book_context

  NetworkMgr:runWhenConnected(function()
    self:ensureInitialized()
    self:updateConfigFromSettings()

    local action = self.action_service:getAction("book", action_id)
    if not action then
      UIManager:show(InfoMessage:new{
        icon = "notice-warning",
        text = T(_("Action '%1' not found"), action_id),
      })
      return
    end

    -- Config copy pattern (same as executeBookLevelAction)
    local config_copy = {}
    for k, v in pairs(configuration or {}) do
      config_copy[k] = v
    end
    config_copy.features = {}
    for k, v in pairs((configuration or {}).features or {}) do
      config_copy.features[k] = v
    end

    -- Signal synthetic book metadata (same as _executeBookLevelActionDirect)
    config_copy.features._is_book_level_action = true

    if self:_checkRequirements(action, file) then return end

    -- Consolidation Q4 (2026-08-16): the old `use_response_caching and
    -- source_selection` arm here (a bespoke View/New dialog carrying the
    -- 2026-08-15 spoiler consent) was UNREACHABLE — the file-browser
    -- long-press list filters out every source_selection action via
    -- requiresOpenBook — so it is gone, and the consent lives at the live
    -- closed-book dispatch points instead (_confirmClosedBookSpoilerRun).
    if action.use_response_caching then
      local self_ref = self
      self:showCacheActionPopup(action, action_id, function(update_opts)
        if update_opts and update_opts.complete_analysis then
          config_copy.features._complete_analysis = true
        end
        Dialogs.executeDirectAction(self_ref.ui, action, book_context, config_copy, self_ref)
      end, { file = file, book_title = title, book_author = authors })
    else
      Dialogs.executeDirectAction(self.ui, action, book_context, config_copy, self)
    end
  end)
end

--- Execute a configurable action gesture (routes to context-specific handler)
--- @param context string: The action context ("book", "general", or "book+general")
--- @param action_id string: The action ID
function AskGPT:executeConfigurableAction(context, action_id)
  -- For compound contexts like "book+general", check if we have a book open
  -- and route to book context if so, otherwise general
  if context == "book+general" then
    if self.ui and self.ui.document then
      self:executeBookLevelAction(action_id)
    else
      self:executeGeneralAction(action_id)
    end
  elseif context == "book" then
    self:executeBookLevelAction(action_id)
  elseif context == "general" then
    self:executeGeneralAction(action_id)
  else
    UIManager:show(InfoMessage:new{
      icon = "notice-warning",
      text = T(_("Unknown action context: %1"), context)
    })
  end
end

--- Execute a general context action (no book required)
--- @param action_id string: The action ID
function AskGPT:executeGeneralAction(action_id)
  -- Get the action from ActionService instance
  local action = self.action_service:getAction("general", action_id)
  if not action then
    -- Also try book+general compound context
    action = self.action_service:getAction("book+general", action_id)
  end
  if not action then
    UIManager:show(InfoMessage:new{
      icon = "notice-warning",
      text = T(_("Action '%1' not found"), action_id)
    })
    return
  end

  -- Make sure we're using the latest configuration
  self:updateConfigFromSettings()

  -- Build config for general context
  -- IMPORTANT: Create a proper shallow copy with a NEW features object
  local config_copy = {}
  for k, v in pairs(configuration or {}) do
    config_copy[k] = v
  end
  -- Create NEW features table (don't share reference with global configuration)
  config_copy.features = {}
  for k, v in pairs((configuration or {}).features or {}) do
    config_copy.features[k] = v
  end
  -- Scrub inherited context state, then mark general: a stale is_book_context from
  -- an earlier book entry would otherwise win in getPromptContext and misclassify
  -- this gesture-fired general action as book context (injection_gating_audit)
  self:_scrubContextFeatures(config_copy.features)
  config_copy.features.is_general_context = true

  -- Execute the action
  NetworkMgr:runWhenConnected(function()
    Dialogs.executeDirectAction(
      self.ui,
      action,
      nil,  -- No highlighted text for general actions
      config_copy,
      self
    )
  end)
end

--- Open KOAssistant settings via menu traversal
--- Opens the main menu at the Tools tab and selects KOAssistant
function AskGPT:onKOAssistantSettings()
  -- Standalone settings menu built directly from our schema. The previous
  -- implementation crawled KOReader's main menu (hardcoded tab index + 0.2s timer +
  -- text match on private internals), which silently no-opped with user menu_order
  -- override files, on slow devices, and after KOReader menu refactors.
  self:ensureInitialized()
  local TouchMenu = require("ui/widget/touchmenu")
  local CenterContainer = require("ui/widget/container/centercontainer")
  local items = SettingsManager:generateMenuFromSchema(self, SettingsSchema)
  items.icon = "appbar.settings"  -- TouchMenu builds its icon bar from each tab's .icon
  local menu_container = CenterContainer:new{
    covers_header = true,
    ignore = "height",
    dimen = Screen:getSize(),
  }
  local main_menu = TouchMenu:new{
    width = Screen:getWidth(),
    tab_item_table = { items },
    show_parent = menu_container,
  }
  main_menu.close_callback = function()
    UIManager:close(menu_container)
  end
  menu_container[1] = main_menu
  UIManager:show(menu_container)
  return true
end

--- Helper: Show a settings popup from menu items
--- @param title string: Dialog title
--- @param menu_items table: Array of menu items from build*Menu functions
--- @param close_on_select boolean: If true, close popup after selection (default: true)
function AskGPT:showQuickSettingsPopup(title, menu_items, close_on_select, on_close_callback)
  local ButtonDialog = require("ui/widget/buttondialog")
  local self_ref = self

  -- Default to closing after selection
  if close_on_select == nil then
    close_on_select = true
  end

  local buttons = {}
  for _idx, item in ipairs(menu_items) do
    -- TouchMenu semantics: separator = true on an ACTIONABLE item means "draw a
    -- line after this item", not "this item is a header" — treating any
    -- separator-flagged item as a header grayed out real options (last language
    -- in the translate picker, dictionary "Follow Primary"). This popup renders
    -- a flat list: separators are ignored entirely; only non-actionable items
    -- with text render as disabled info rows.
    local is_actionable = item.callback or item.replace_items or item.checked_func
    if not is_actionable and item.text then
      table.insert(buttons, {
        {
          text = item.text,
          enabled = false,
        },
      })
    elseif item.text then
      local is_checked = item.checked_func and item.checked_func()
      local text = item.text
      if is_checked then
        text = "✓ " .. text
      end
      local btn = {
        text = text,
        enabled = item.enabled ~= false,
        callback = function()
          -- opens_dialog: the item's callback shows its own dialog (e.g. the
          -- custom-language InputDialog) — close this popup first and don't
          -- reopen the parent, or the new dialog ends up buried under it
          if item.opens_dialog then
            UIManager:close(self_ref._quick_settings_dialog)
            self_ref._quick_settings_dialog = nil
            if item.callback then item.callback() end
            return
          end
          -- replace_items: swap this popup's list in place (e.g. "Show all
          -- providers"), keeping the same title and close semantics
          if item.replace_items then
            UIManager:close(self_ref._quick_settings_dialog)
            self_ref._quick_settings_dialog = nil
            self_ref:showQuickSettingsPopup(title, item.replace_items(), close_on_select, on_close_callback)
            return
          end
          if item.callback then
            item.callback()
          end
          UIManager:close(self_ref._quick_settings_dialog)
          if not close_on_select then
            -- Reopen to show updated state
            self_ref._quick_settings_dialog = nil
            self_ref:showQuickSettingsPopup(title, menu_items, close_on_select, on_close_callback)
          else
            self_ref._quick_settings_dialog = nil
            -- Call the close callback if provided (e.g., to reopen parent dialog)
            if on_close_callback then
              on_close_callback()
            end
          end
        end,
      }
      -- Long-press: pass the item's hold action through (e.g. custom provider
      -- options) — close the popup first so the follow-up dialog isn't stacked
      -- over a list it may invalidate
      if item.hold_callback then
        btn.hold_callback = function()
          UIManager:close(self_ref._quick_settings_dialog)
          self_ref._quick_settings_dialog = nil
          item.hold_callback()
        end
      end
      table.insert(buttons, { btn })
    end
  end

  -- Add close button
  table.insert(buttons, {
    {
      text = _("Close"),
      callback = function()
        UIManager:close(self_ref._quick_settings_dialog)
        self_ref._quick_settings_dialog = nil
        -- Call on_close_callback to return to parent dialog (e.g., AI Quick Settings)
        if on_close_callback then
          on_close_callback()
        end
      end,
    },
  })

  self._quick_settings_dialog = ButtonDialog:new{
    title = title,
    buttons = buttons,
    -- Handle escape key and tap-outside to return to parent dialog
    tap_close_callback = function()
      self_ref._quick_settings_dialog = nil
      if on_close_callback then
        on_close_callback()
      end
    end,
  }
  UIManager:show(self._quick_settings_dialog)
end

--- Quick Settings reasoning popup, in the Web/Tools picker shape: a
--- [Global | Current model] target-toggle header row, ALWAYS opening on Global.
--- Global tab = the stance dial; model tab = the per-model controls (shared
--- _reasoningControlRows) plus the "Other models…" browser. Defaults to the active
--- provider/model; the model browser passes provider_arg/model_arg to control
--- another one (and target_arg="model" so the pick lands on that model's tab).
--- Rebuilds itself on each change so labels and marks stay fresh.
function AskGPT:showReasoningQuickPopup(on_close_callback, provider_arg, model_arg, target_arg)
  local ButtonDialog = require("ui/widget/buttondialog")
  local ModelConstraints = require("model_constraints")
  local ReasoningPrefs = require("reasoning_prefs")
  local self_ref = self

  local features = self.settings:readSetting("features") or {}
  local provider = provider_arg or features.provider or "anthropic"
  local provider_display = self:getProviderDisplayName(provider)
  local model = model_arg or self:getCurrentModel() or "default"
  local profile = ModelConstraints.getReasoningProfile(provider, model)
  local stance = ReasoningPrefs.getStance(features)
  local is_model_target = target_arg == "model"

  local function reopen(new_target)
    UIManager:close(self_ref._reasoning_qs_dialog)
    self_ref._reasoning_qs_dialog = nil
    self_ref:showReasoningQuickPopup(on_close_callback, provider_arg, model_arg, new_target)
  end
  -- Persist a mutation, then close+reopen (same tab) so labels/marks refresh.
  local function mutate(fn)
    local f = self_ref.settings:readSetting("features") or {}
    fn(f)
    self_ref.settings:saveSetting("features", f)
    self_ref.settings:flush()
    self_ref:updateConfigFromSettings()
    reopen(target_arg)
  end

  local function dot(active) return active and "\u{25CF} " or "\u{25CB} " end
  local buttons = {}
  local function row(text, checked, cb)
    table.insert(buttons, {{ text = dot(checked) .. text, callback = cb }})
  end

  -- Target toggle: "This model" instead of "Current model" when the browser
  -- navigated here for an explicit (possibly non-active) model pick.
  table.insert(buttons, {
    {
      text = dot(not is_model_target) .. _("Global"),
      callback = function()
        if is_model_target then reopen("global") end
      end,
    },
    {
      text = dot(is_model_target) .. (model_arg and _("This model") or _("Current model")),
      callback = function()
        if not is_model_target then reopen("model") end
      end,
    },
  })

  if not is_model_target then
    -- Global stance (affects every model, respecting each model's capability)
    local STANCES = {
      { id = "minimal", label = _("Minimal (off where possible)") },
      { id = "default", label = _("Default (let each model decide)") },
      { id = "maximum", label = _("Maximum (most reasoning)") },
    }
    for _idx, s in ipairs(STANCES) do
      row(s.label, stance == s.id, function()
        mutate(function(f) ReasoningPrefs.setStance(f, s.id) end)
      end)
    end
  else
    -- This model (rendered from the model's reasoning profile, via shared builder).
    -- "Follow global" shows the FALLBACK (provider default then stance) — what
    -- you'd get with no per-model override — NOT the current model pref.
    table.insert(buttons, {{ text = T(_("This model: %1"), model), enabled = false }})
    local eff = ModelConstraints.resolveReasoning(provider, model, {
      global_stance = stance,
    })
    local eff_label
    if eff.send_nothing then
      eff_label = _("model default")
    elseif eff.mode == "off" then
      eff_label = _("Off")
    elseif eff.option then
      eff_label = ReasoningPrefs.effortLabel(eff.option)
    else
      eff_label = _("On")
    end
    local function get_model_pref()
      return ReasoningPrefs.getModelPref(self_ref.settings:readSetting("features") or {}, provider, model)
    end
    local model_rows = self:_reasoningControlRows(profile, get_model_pref, eff_label,
      function(p) mutate(function(f) ReasoningPrefs.setModelPref(f, provider, model, p) end) end,
      function() mutate(function(f) ReasoningPrefs.clearModelPref(f, provider, model) end) end)
    for _idx, r in ipairs(model_rows) do
      if r.info then
        table.insert(buttons, {{ text = r.text, enabled = false }})
      else
        row(r.text, r.checked_func(), r.callback)
      end
    end
  end

  -- Footer: other-models browser (model tab only — beside the Global stance it
  -- read as if the stance were per-model, maintainer 2026-08-12) + close
  if is_model_target then
    table.insert(buttons, {{
      text = _("Other models…"),
      callback = function()
        UIManager:close(self_ref._reasoning_qs_dialog)
        self_ref._reasoning_qs_dialog = nil
        self_ref:showReasoningModelBrowser(on_close_callback)
      end,
    }})
  end
  table.insert(buttons, {{
    text = _("Close"),
    callback = function()
      UIManager:close(self_ref._reasoning_qs_dialog)
      self_ref._reasoning_qs_dialog = nil
      if on_close_callback then on_close_callback() end
    end,
  }})

  self._reasoning_qs_dialog = ButtonDialog:new{
    title = is_model_target and T(_("Reasoning · %1"), provider_display) or _("Reasoning"),
    buttons = buttons,
    tap_close_callback = function()
      self_ref._reasoning_qs_dialog = nil
      if on_close_callback then on_close_callback() end
    end,
  }
  UIManager:show(self._reasoning_qs_dialog)
end

--- Shared builder: abstract control rows for a reasoning target (model or provider),
--- driven by its reasoning profile. Used by both the Quick Settings popup
--- (ButtonDialog) and the Settings reasoning menu (TouchMenu).
--- Each row is { text=, checked_func=()->bool, callback=fn } or { info=true, text= }.
--- get_pref() re-reads the current stored pref so checked_func stays live; on_set(pref)
--- / on_clear() persist the choice. effective_label is the resolved fallback shown on
--- the "Inherit" row (what you get with NO override at this level).
function AskGPT:_reasoningControlRows(profile, get_pref, effective_label, on_set, on_clear)
  local ReasoningPrefs = require("reasoning_prefs")
  local rows = {}
  if profile.axis == "none" then
    rows[#rows + 1] = { info = true, text = (profile.default_state == "on")
      and _("Always reasons (cannot be changed)")
      or _("This model does not support reasoning") }
    return rows
  end
  rows[#rows + 1] = {
    text = T(_("Follow global (%1)"), effective_label),
    checked_func = function() return get_pref() == nil end,
    callback = on_clear,
  }
  rows[#rows + 1] = {
    -- Explicit "API default" pin: send nothing on the wire regardless of the global
    -- stance (differs from Follow global whenever stance is Minimal/Maximum).
    text = _("Model API default (no override)"),
    checked_func = function() local p = get_pref(); return p ~= nil and p.state == "default" end,
    callback = function() on_set({ state = "default" }) end,
  }
  if profile.can_disable then
    rows[#rows + 1] = {
      text = _("Off"),
      checked_func = function() local p = get_pref(); return p ~= nil and p.state == "off" end,
      callback = function() on_set({ state = "off" }) end,
    }
  else
    -- No off switch exists at the API (Gemini 3.x, always-on reasoning
    -- providers): say so where the Off row would sit — otherwise the picker
    -- reads as if Off were forgotten. Minimal stance already maps to the
    -- lowest effort for these models; this row is explanation only.
    rows[#rows + 1] = { info = true,
      text = _("Always reasons — this model's API has no off switch") }
  end
  if profile.axis == "binary" then
    rows[#rows + 1] = {
      text = _("On"),
      checked_func = function() local p = get_pref(); return p ~= nil and p.state == "on" end,
      callback = function() on_set({ state = "on" }) end,
    }
  else
    for _idx, opt in ipairs(profile.options or {}) do
      rows[#rows + 1] = {
        text = ReasoningPrefs.effortLabel(opt),
        checked_func = function()
          local p = get_pref()
          return p ~= nil and p.state ~= "off" and (p.effort == opt or p.budget == opt)
        end,
        callback = function()
          local p = { state = "on" }
          if profile.axis == "budget" then p.budget = opt else p.effort = opt end
          on_set(p)
        end,
      }
    end
  end
  return rows
end

-- Short summary of a stored reasoning pref ({state,effort,budget} or nil).
local function reasoningPrefSummary(pref)
  local ReasoningPrefs = require("reasoning_prefs")
  if pref == nil then return _("Follow global") end
  if pref.state == "default" then return _("Model default") end
  if pref.state == "off" then return _("Off") end
  local opt = pref.effort or pref.budget
  if opt then return ReasoningPrefs.effortLabel(opt) end
  if pref.state == "on" then return _("On") end
  return _("Follow global")
end

-- Providers with at least one CONFIGURABLE reasoning model (axis ~= "none").
-- Excludes providers whose only reasoning models always reason with no control
-- (e.g. Mistral Magistral) and providers with no reasoning at all.
local function reasoningCapableProviders()
  local ModelConstraints = require("model_constraints")
  local ModelLists = require("koassistant_model_lists")
  local out = {}
  for _idx, p in ipairs(ModelLists.getAllProviders()) do
    local profiles = ModelConstraints.reasoning_profiles[p]
    if profiles then
      for _i, prof in ipairs(profiles) do
        if prof.axis ~= "none" then
          out[#out + 1] = p
          break
        end
      end
    end
  end
  return out
end

--- Reasoning model browser: provider list → configurable-model list (with effective
--- state) → the same reasoning popup for that model. Lets the Quick Settings popup
--- reach EVERY model, not just the active one.
--- (Defined after reasoningCapableProviders — local function ordering matters.)
function AskGPT:showReasoningModelBrowser(on_close_callback, show_all)
  local ButtonDialog = require("ui/widget/buttondialog")
  local ModelConstraints = require("model_constraints")
  local ReasoningPrefs = require("reasoning_prefs")
  local ModelLists = require("koassistant_model_lists")
  local self_ref = self

  local function closeBrowser()
    UIManager:close(self_ref._reasoning_browser_dialog)
    self_ref._reasoning_browser_dialog = nil
  end

  local function showModels(provider)
    local features = self_ref.settings:readSetting("features") or {}
    local buttons = {}
    for _idx, model in ipairs(ModelLists[provider] or {}) do
      if ModelConstraints.getReasoningProfile(provider, model).axis ~= "none" then
        local m = model
        table.insert(buttons, {{
          text = T(_("%1 · %2"), m, ReasoningPrefs.summaryLabel(features, provider, m)),
          callback = function()
            closeBrowser()
            self_ref:showReasoningQuickPopup(on_close_callback, provider, m, "model")
          end,
        }})
      end
    end
    if #buttons == 0 then
      table.insert(buttons, {{ text = _("No configurable models"), enabled = false }})
    end
    table.insert(buttons, {{ text = _("Close"), callback = closeBrowser }})
    self_ref._reasoning_browser_dialog = ButtonDialog:new{
      title = T(_("Reasoning · %1"), self_ref:getProviderDisplayName(provider)),
      buttons = buttons,
      tap_close_callback = function() self_ref._reasoning_browser_dialog = nil end,
    }
    UIManager:show(self_ref._reasoning_browser_dialog)
  end

  local buttons = {}
  -- Key-filtering (controls parity): quick-settings surface, so hide providers
  -- without a configured key behind a "Show all" row (disarmed while no real key
  -- exists at all)
  local has_real_key = self:hasAnyRealApiKey()
  local hidden_count = 0
  for _idx, provider in ipairs(reasoningCapableProviders()) do
    local p = provider
    if show_all or not has_real_key or self:isProviderConfigured(p) then
      table.insert(buttons, {{
        text = self_ref:getProviderDisplayName(p),
        callback = function()
          closeBrowser()
          showModels(p)
        end,
      }})
    else
      hidden_count = hidden_count + 1
    end
  end
  if hidden_count > 0 then
    table.insert(buttons, {{
      text = T(_("Show all providers (%1 more)…"), hidden_count),
      callback = function()
        closeBrowser()
        self_ref:showReasoningModelBrowser(on_close_callback, true)
      end,
    }})
  end
  table.insert(buttons, {{ text = _("Close"), callback = closeBrowser }})
  self._reasoning_browser_dialog = ButtonDialog:new{
    title = _("Reasoning · pick a provider"),
    buttons = buttons,
    tap_close_callback = function() self_ref._reasoning_browser_dialog = nil end,
  }
  UIManager:show(self._reasoning_browser_dialog)
end

--- TouchMenu items: reasoning control (Follow global / Off / On / effort) for one
--- model. Uses the shared _reasoningControlRows; checked_func keeps the radio marks
--- live as the user taps.
function AskGPT:buildReasoningTargetMenu(provider, model)
  local ModelConstraints = require("model_constraints")
  local ReasoningPrefs = require("reasoning_prefs")
  local self_ref = self

  local profile = ModelConstraints.getReasoningProfile(provider, model)

  local function get_pref()
    return ReasoningPrefs.getModelPref(self_ref.settings:readSetting("features") or {}, provider, model)
  end

  -- "Follow global" fallback = the global stance applied to this model.
  local eff = ModelConstraints.resolveReasoning(provider, model, {
    global_stance = ReasoningPrefs.getStance(self.settings:readSetting("features") or {}),
  })
  local eff_label
  if eff.send_nothing then eff_label = _("model default")
  elseif eff.mode == "off" then eff_label = _("Off")
  elseif eff.option then eff_label = ReasoningPrefs.effortLabel(eff.option)
  else eff_label = _("On") end

  local function persist(fn)
    local f = self_ref.settings:readSetting("features") or {}
    fn(f)
    self_ref.settings:saveSetting("features", f)
    self_ref.settings:flush()
    self_ref:updateConfigFromSettings()
  end
  local on_set = function(p)
    persist(function(f) ReasoningPrefs.setModelPref(f, provider, model, p) end)
  end
  local on_clear = function()
    persist(function(f) ReasoningPrefs.clearModelPref(f, provider, model) end)
  end

  local rows = self:_reasoningControlRows(profile, get_pref, eff_label, on_set, on_clear)
  local items = {}
  for _idx, r in ipairs(rows) do
    if r.info then
      items[#items + 1] = { text = r.text, enabled_func = function() return false end }
    else
      items[#items + 1] = {
        text = r.text,
        radio = true,
        checked_func = r.checked_func,
        callback = r.callback,
        keep_menu_open = true,
      }
    end
  end
  return items
end

--- TouchMenu callback submenu: per-model overrides — pick a provider first.
function AskGPT:buildReasoningModelProviderMenu()
  local self_ref = self
  local items = {}
  for _idx, provider in ipairs(reasoningCapableProviders()) do
    local p = provider
    items[#items + 1] = {
      text = self_ref:getProviderDisplayName(p),
      sub_item_table_func = function() return self_ref:buildReasoningModelListMenu(p) end,
    }
  end
  return items
end

--- TouchMenu: a provider's CONFIGURABLE models, each opening its per-model control.
--- Models with no controllable reasoning (axis "none" — always-on or no reasoning)
--- are omitted, since there is nothing to set for them.
function AskGPT:buildReasoningModelListMenu(provider)
  local ModelConstraints = require("model_constraints")
  local ReasoningPrefs = require("reasoning_prefs")
  local ModelLists = require("koassistant_model_lists")
  local self_ref = self
  local items = {}
  for _idx, model in ipairs(ModelLists[provider] or {}) do
    if ModelConstraints.getReasoningProfile(provider, model).axis ~= "none" then
      local m = model
      items[#items + 1] = {
        text_func = function()
          local f = self_ref.settings:readSetting("features") or {}
          local pref = ReasoningPrefs.getModelPref(f, provider, m)
          if pref == nil then
            -- No override: show what "Follow global" actually resolves to for this
            -- model, so the list answers "what will it do?" without drilling in.
            return T(_("%1: Follow global → %2"), m, ReasoningPrefs.summaryLabel(f, provider, m))
          end
          return T(_("%1: %2"), m, reasoningPrefSummary(pref))
        end,
        sub_item_table_func = function()
          return self_ref:buildReasoningTargetMenu(provider, m)
        end,
      }
    end
  end
  if #items == 0 then
    items[#items + 1] = { text = _("No configurable models"), enabled_func = function() return false end }
  end
  return items
end

--- Build behavior variant menu (for Quick Settings panel)
--- Loads all behaviors from all sources (builtin, folder, UI-created)
function AskGPT:buildBehaviorMenu()
  local SystemPrompts = require("prompts/system_prompts")
  local self_ref = self

  local features = self.settings:readSetting("features") or {}
  local custom_behaviors = features.custom_behaviors or {}
  local all_behaviors = SystemPrompts.getSortedBehaviors(custom_behaviors)  -- Returns sorted array

  local items = {}
  for _idx, behavior in ipairs(all_behaviors) do
    -- Skip specialized behaviors in quick picker (they're for specific actions, not general use)
    if not behavior.specialized then
      local behavior_copy = behavior
      table.insert(items, {
        text = behavior_copy.display_name or behavior_copy.name,  -- display_name already includes source indicator
        checked_func = function()
          local f = self_ref.settings:readSetting("features") or {}
          return (f.selected_behavior or "standard") == behavior_copy.id
        end,
        radio = true,
        callback = function()
          local f = self_ref.settings:readSetting("features") or {}
          f.selected_behavior = behavior_copy.id
          self_ref.settings:saveSetting("features", f)
          self_ref.settings:flush()
          self_ref:updateConfigFromSettings()
        end,
      })
    end
  end

  return items
end

--- TitledButtonDialog: ButtonDialog-like popup with TitleBar (gear icon + close X).
--- Used by QS and QA panels instead of plain ButtonDialog.
local _FocusManager = require("ui/widget/focusmanager")
local TitledButtonDialog = _FocusManager:extend{}

function TitledButtonDialog:init()
  local ButtonTable = require("ui/widget/buttontable")
  local TitleBar = require("ui/widget/titlebar")
  local Blitbuffer = require("ffi/blitbuffer")
  local CenterContainer = require("ui/widget/container/centercontainer")
  local Font = require("ui/font")
  local FrameContainer = require("ui/widget/container/framecontainer")
  local Geom = require("ui/geometry")
  local GestureRange = require("ui/gesturerange")
  local MovableContainer = require("ui/widget/container/movablecontainer")
  local Size = require("ui/size")
  local VerticalGroup = require("ui/widget/verticalgroup")

  if not self.width then
    self.width = math.floor(math.min(Screen:getWidth(), Screen:getHeight()) * 0.9)
  end

  if Device:hasKeys() then
    local back_group = util.tableDeepCopy(Device.input.group.Back)
    if Device:hasFewKeys() then
      table.insert(back_group, "Left")
    else
      table.insert(back_group, "Menu")
    end
    self.key_events.Close = { { back_group } }
  end
  if Device:isTouchDevice() then
    self.ges_events.TapClose = {
      GestureRange:new{
        ges = "tap",
        range = Geom:new{ x = 0, y = 0, w = Screen:getWidth(), h = Screen:getHeight() },
      }
    }
  end

  local content_width = self.width - 2 * Size.border.window - 2 * Size.padding.button
  self.buttontable = ButtonTable:new{
    buttons = self.buttons,
    width = content_width,
    show_parent = self,
  }
  local buttontable_width = self.buttontable:getSize().w

  self.title_bar = TitleBar:new{
    width = buttontable_width,
    title = self.title or "",
    title_face = Font:getFace("infofont"),
    left_icon = self.left_icon or "appbar.settings",
    left_icon_tap_callback = self.left_icon_tap_callback or function() end,
    close_callback = function() self:onClose() end,
    with_bottom_line = true,
    bottom_line_color = Blitbuffer.COLOR_GRAY,
    show_parent = self,
  }
  local titlebar = self.title_bar

  local max_height = Screen:getHeight() - 2 * Size.padding.buttontable
                     - 2 * Size.margin.default - titlebar:getSize().h
  local content
  if self.buttontable:getSize().h > max_height then
    local ScrollableContainer = require("ui/widget/container/scrollablecontainer")
    local VerticalSpan = require("ui/widget/verticalspan")
    self.buttontable:setupGridScrollBehaviour()
    local step_scroll_grid = self.buttontable:getStepScrollGrid()
    local row_height = step_scroll_grid[1].bottom + 1 - step_scroll_grid[1].top
    max_height = row_height * math.floor(max_height / row_height)
    self.cropping_widget = ScrollableContainer:new{
      dimen = Geom:new{
        w = buttontable_width + ScrollableContainer:getScrollbarWidth(),
        h = max_height,
      },
      show_parent = self,
      step_scroll_grid = step_scroll_grid,
      self.buttontable,
    }
    content = VerticalGroup:new{
      VerticalSpan:new{ width = Size.padding.buttontable },
      self.cropping_widget,
      VerticalSpan:new{ width = Size.padding.buttontable },
    }
  else
    content = self.buttontable
  end

  self.movable = MovableContainer:new{
    FrameContainer:new{
      background = Blitbuffer.COLOR_WHITE,
      bordersize = Size.border.window,
      radius = Size.radius.window,
      padding = Size.padding.button,
      padding_top = 0,
      padding_bottom = 0,
      VerticalGroup:new{
        titlebar,
        content,
      },
    }
  }

  self.layout = self.buttontable.layout
  self.buttontable.layout = nil

  self[1] = CenterContainer:new{
    dimen = Screen:getSize(),
    self.movable,
  }
end

function TitledButtonDialog:onShow()
  UIManager:setDirty(self, function()
    return "ui", self.movable.dimen
  end)
end

function TitledButtonDialog:onCloseWidget()
  UIManager:setDirty(nil, function()
    return "flashui", self.movable.dimen
  end)
end

function TitledButtonDialog:onClose()
  if self.close_callback then
    self.close_callback()
  end
  UIManager:close(self)
  return true
end

function TitledButtonDialog:onTapClose(arg, ges)
  if ges.pos:notIntersectWith(self.movable.dimen) then
    self:onClose()
  end
  return true
end

function TitledButtonDialog:paintTo(...)
  _FocusManager.paintTo(self, ...)
  self.dimen = self.movable.dimen
end

--- Combined AI Quick Settings popup (for gesture action)
--- Two-column layout with commonly used settings
--- @param on_close_callback function: Optional callback called when user closes the dialog
function AskGPT:onKOAssistantAISettings(on_close_callback)
  local SpinWidget = require("ui/widget/spinwidget")
  local DomainLoader = require("domain_loader")
  local SystemPrompts = require("prompts/system_prompts")
  local ReasoningPrefs = require("reasoning_prefs")
  local self_ref = self

  -- Helper to reopen this dialog after sub-dialog closes (immediate, no delay)
  local function reopenQuickSettings()
    self_ref:onKOAssistantAISettings(on_close_callback)
  end

  local features = self.settings:readSetting("features") or {}
  local provider = features.provider or "anthropic"
  local provider_display = self:getProviderDisplayName(provider)
  local model = self:getCurrentModel() or "default"
  local behavior_id = features.selected_behavior or "standard"
  local streaming = features.enable_streaming ~= false  -- Default true
  -- Reasoning chip reflects the EFFECTIVE state for the active provider/model
  -- (resolved from the global stance + per-provider/per-model prefs).
  local reasoning_chip = ReasoningPrefs.summaryLabel(features, provider, model)
  -- Whether the *currently active* provider/model can actually use web search.
  -- The picker stays usable (it sets the defaults); we just annotate when N/A.
  local ModelConstraints = require("model_constraints")
  local web_search_supported = ModelConstraints.supportsWebSearch(provider, model)
  local text_extraction = features.enable_book_text_extraction == true  -- Default false

  -- Get behavior display name (with source indicator)
  local custom_behaviors = features.custom_behaviors or {}
  local behavior_info = SystemPrompts.getBehaviorById(behavior_id, custom_behaviors)
  local behavior_display = behavior_info and behavior_info.display_name or behavior_id

  -- Get domain display name (with source indicator)
  -- Effective domain via the shared resolver (book > global, "_none" = explicit
  -- no-domain override for this book — nil id with layer "book")
  local qs_ds = self.ui and self.ui.document and self.ui.doc_settings or nil
  local eff_domain_id, domain_layer =
      require("koassistant_book_settings").resolveDomain(qs_ds, features)
  local domain_display = _("None")
  if domain_layer == "book" and not eff_domain_id then
    domain_display = _("None") .. _(" (book)")
  elseif eff_domain_id then
    local custom_domains = features.custom_domains or {}
    local domain = DomainLoader.getDomainById(eff_domain_id, custom_domains)
    if domain then
      -- Bare name on the chip — provenance suffixes stay in picker lists only
      domain_display = domain.name or domain.display_name or eff_domain_id
      if domain_layer == "book" then
        domain_display = domain_display .. _(" (book)")
      end
    end
  end
  -- Research indicator (maintainer 2026-08-12, same rule as the input dialog's
  -- Domain chip): book override > global via the shared resolver; emoji mode
  -- swaps the chip's 🏛️ for 🔬, text mode appends "(research)" (this row has
  -- the width the toolbar chip lacks).
  local research_on = require("koassistant_book_settings").resolveResearch(qs_ds, features)

  -- Get primary language display (use native script)
  local primary_lang_id = self:getEffectivePrimaryLanguage()
  local lang_display = primary_lang_id and getLanguageDisplay(primary_lang_id) or _("Default")

  -- Get translation language display (use native script)
  local trans_lang = features.translation_language
  local trans_effective  -- The actual language name (for dictionary cascade)
  local trans_display    -- What to show in the button
  if trans_lang == nil or trans_lang == "" or trans_lang == "__PRIMARY__" then
    trans_effective = lang_display
    trans_display = lang_display .. " ↵"  -- Follow primary (arrow indicates "same as")
  else
    trans_effective = getLanguageDisplay(trans_lang)
    trans_display = trans_effective
  end

  -- Get dictionary language display (use native script)
  local dict_lang = features.dictionary_language
  local dict_display
  if dict_lang == "__FOLLOW_PRIMARY__" then
    dict_display = lang_display .. " ↵"  -- Follow primary (same indicator as translation)
  elseif dict_lang == nil or dict_lang == "" or dict_lang == "__FOLLOW_TRANSLATION__" then
    dict_display = trans_effective .. " ↵T"  -- Follow translation (T distinguishes from primary)
  else
    dict_display = getLanguageDisplay(dict_lang)
  end

  -- Get bypass states
  local highlight_bypass = features.highlight_bypass_enabled
  local dict_bypass = features.dictionary_bypass_enabled

  -- Check if we're in reader mode (book is open)
  local has_document = self.ui and self.ui.document

  -- Emoji support (uses separate "Emoji Panel Icons" setting)
  local enable_emoji = features.enable_emoji_panel_icons == true
  local function E(emoji, text) return Constants.getEmojiText(emoji, text, enable_emoji) end

  -- Flag to track if we're closing for a sub-dialog (vs true dismissal)
  local opening_subdialog = false

  -- Build ALL buttons dynamically based on QS Panel settings
  -- Order driven by stored qs_items_order (user-sortable)
  -- Buttons populate in order, two per row, Close always last and alone
  local dialog  -- Forward declaration for callbacks
  local all_buttons = {}  -- All buttons except Close

  -- Helper to check if a QS item is enabled (default true)
  local function isQsEnabled(key)
    local val = features["qs_show_" .. key]
    if val == nil then return true end  -- Default enabled
    return val
  end

  -- Build button definitions map (id -> button spec)
  -- Dynamic items only added when available; order iteration skips missing keys
  local button_defs = {}

  button_defs["provider"] = {
    text = enable_emoji and ("\u{1F517} " .. provider_display) or T(_("Provider: %1"), provider_display),
    callback = function()
      opening_subdialog = true
      UIManager:close(dialog)
      local menu_items = self_ref:buildProviderMenu(true)
      self_ref:showQuickSettingsPopup(_("Provider"), menu_items, true, reopenQuickSettings)
    end,
  }

  button_defs["model"] = {
    text = enable_emoji and ("\u{1F916} " .. model) or T(_("Model: %1"), model),
    callback = function()
      opening_subdialog = true
      UIManager:close(dialog)
      local menu_items = self_ref:buildModelMenu(true)
      self_ref:showQuickSettingsPopup(_("Model"), menu_items, true, reopenQuickSettings)
    end,
  }

  button_defs["behavior"] = {
    text = enable_emoji and ("🎭 " .. behavior_display) or T(_("Behavior: %1"), behavior_display),
    callback = function()
      opening_subdialog = true
      UIManager:close(dialog)
      local menu_items = self_ref:buildBehaviorMenu()
      self_ref:showQuickSettingsPopup(_("AI Behavior"), menu_items, true, reopenQuickSettings)
    end,
  }

  button_defs["domain"] = {
    text = E(research_on and "\u{1F52C}" or "\u{1F3DB}\u{FE0F}",
      T(_("Domain: %1"), domain_display)
        .. ((research_on and not enable_emoji) and (" " .. _("(research)")) or "")),
    callback = function()
      opening_subdialog = true
      UIManager:close(dialog)
      self_ref:showDomainPopup(reopenQuickSettings)
    end,
    -- P4 (deviation 9): hold parity with the sibling tiles — the scope-aware
    -- Domain & Research picker on the book tab (book open only)
    hold_callback = has_document and function()
      opening_subdialog = true
      UIManager:close(dialog)
      require("koassistant_book_settings").showDomainResearch({
        plugin = self_ref, ui = self_ref.ui,
        on_close = reopenQuickSettings,
      })
    end or nil,
  }

  button_defs["extended_thinking"] = {
    text = E("\u{1F9E0}", T(_("Reasoning: %1"), reasoning_chip)),
    callback = function()
      opening_subdialog = true
      UIManager:close(dialog)
      self_ref:showReasoningQuickPopup(reopenQuickSettings)
    end,
  }

  button_defs["book_tools"] = {
    text = (function()
      -- Binary-global rule since the 2026-08-12 tools collapse (web-search
      -- model): tap toggles the GLOBAL default, hold opens the scope-aware
      -- picker. "(book)" marks a per-book override masking the global.
      local BookSettings = require("koassistant_book_settings")
      local doc_settings = has_document and self.ui.doc_settings or nil
      local label = BookSettings.resolveBookTools(doc_settings, features)
        and _("On") or _("Off")
      if doc_settings and doc_settings:readSetting(BookSettings.KEY_TOOLS) ~= nil then
        label = label .. _(" (book)")
      end
      local base = T(_("Book Tools: %1"), label)
      -- Same annotate-don't-disable rule as the Web Search tile: the toggle
      -- still edits the global default, but say when the ACTIVE model can't
      -- run tool sessions (capability list + a ToolWire adapter — the
      -- membership half of BookToolRunner.shouldUse; for local/custom models
      -- the capability side comes from derived caps or custom_models.lua
      -- grants, so a model reads N/A until it has been derived/granted).
      local ToolWire = require("koassistant_api.tool_wire")
      local ModelConstraintsQS = require("model_constraints")
      if not (ModelConstraintsQS.supportsCapability(provider, model, "tools")
              and ToolWire.hasAdapter(provider)) then
        base = base .. " · " .. T(_("N/A for %1"), model)
      end
      return E("\u{1F50D}", base)
    end)(),
    callback = function()
      local BookSettings = require("koassistant_book_settings")
      local f = self_ref.settings:readSetting("features") or {}
      f.enable_book_tools = not BookSettings.resolveBookTools(nil, f)
      f.tools_posture = nil
      self_ref.settings:saveSetting("features", f)
      self_ref.settings:flush()
      self_ref:updateConfigFromSettings()
      opening_subdialog = true
      UIManager:close(dialog)
      reopenQuickSettings()
    end,
    hold_callback = function()
      opening_subdialog = true
      UIManager:close(dialog)
      self_ref:showToolsPosturePopup(reopenQuickSettings)
    end,
  }

  button_defs["quick_answer"] = {
    text = (function()
      -- Binary-global rule (seam 2): tap toggles the GLOBAL default in place,
      -- hold opens the scope-aware picker. Label shows the EFFECTIVE state,
      -- "(book)" when an override masks it.
      local BookSettings = require("koassistant_book_settings")
      local doc_settings = has_document and self.ui.doc_settings or nil
      local label = BookSettings.resolveQuickAnswerDefault(doc_settings, features)
        and _("On") or _("Off")
      if doc_settings and doc_settings:readSetting(BookSettings.KEY_QUICK_ANSWER) ~= nil then
        label = label .. _(" (book)")
      end
      return E("\u{26A1}", T(_("Quick Answer: %1"), label))
    end)(),
    callback = function()
      local f = self_ref.settings:readSetting("features") or {}
      f.quick_answer_default = not f.quick_answer_default
      self_ref.settings:saveSetting("features", f)
      self_ref.settings:flush()
      self_ref:updateConfigFromSettings()
      opening_subdialog = true
      UIManager:close(dialog)
      reopenQuickSettings()
    end,
    hold_callback = function()
      opening_subdialog = true
      UIManager:close(dialog)
      require("koassistant_book_settings").showQuickAnswerDefault({
        plugin = self_ref,
        ui = has_document and self_ref.ui or nil,
        preset_settings = function(chain_close)
          require("koassistant_dialogs").showQuickPresetEditor({
            plugin = self_ref, on_close = chain_close,
          })
        end,
        on_close = reopenQuickSettings,
      })
    end,
  }

  button_defs["spoiler"] = {
    text = (function()
      -- Seam 2 rider (maintainer 2026-08-12): spoiler joins the QS panel.
      -- Same binary-global rule; label = effective posture for the open book.
      -- Unlike web/tools/quick, THREE book layers can mask the global here —
      -- per-book override, research mode, Finished status — so name whichever
      -- applies (§5 label-never-gray), else the tap looks dead.
      local BookSettings = require("koassistant_book_settings")
      local doc_settings = has_document and self.ui.doc_settings or nil
      local posture = BookSettings.resolveSpoilerPosture(doc_settings, features)
      local label = posture.protected and _("On") or _("Off")
      if posture.reason == "book" then
        label = label .. _(" (book)")
      elseif posture.reason == "research" then
        label = label .. _(" (research mode)")
      elseif posture.reason == "finished" then
        label = label .. _(" (book finished)")
      end
      return E("\u{1F6E1}\u{FE0F}", T(_("Spoiler Protection: %1"), label))
    end)(),
    callback = function()
      local BookSettings = require("koassistant_book_settings")
      local f = self_ref.settings:readSetting("features") or {}
      -- default-true key: nil/true → explicit false (off), false → true (on)
      f.spoiler_free_chat = (f.spoiler_free_chat == false)
      self_ref.settings:saveSetting("features", f)
      self_ref.settings:flush()
      self_ref:updateConfigFromSettings()
      -- The global is saved either way; if a book-scoped layer masks it for
      -- the open book, say where the change went (the temperature tile's
      -- "Saved as default" pattern) — a silent no-op reads as a dead button.
      local doc_settings = has_document and self_ref.ui and self_ref.ui.doc_settings or nil
      local posture = BookSettings.resolveSpoilerPosture(doc_settings, f)
      if posture.reason == "book" then
        UIManager:show(Notification:new{
          text = _("Saved as default. This book has its own override — hold the button to change it."),
          timeout = 3,
        })
      elseif posture.reason == "research" then
        UIManager:show(Notification:new{
          text = _("Saved as default. Research mode keeps protection off for this book."),
          timeout = 3,
        })
      elseif posture.reason == "finished" then
        UIManager:show(Notification:new{
          text = _("Saved as default. This book is marked finished, so protection stays off."),
          timeout = 3,
        })
      end
      opening_subdialog = true
      UIManager:close(dialog)
      reopenQuickSettings()
    end,
    hold_callback = function()
      opening_subdialog = true
      UIManager:close(dialog)
      require("koassistant_book_settings").showSpoilerFree({
        plugin = self_ref,
        ui = has_document and self_ref.ui or nil,
        on_close = reopenQuickSettings,
      })
    end,
  }

  button_defs["minimal_popup"] = {
    text = (function()
      -- QS tile (maintainer 2026-08-17): tap = ON/OFF toggle, hold = view mode
      -- + action picker. Label is plain ON/OFF; which on-state is active
      -- (when-it-fits vs always) lives in the hold popup.
      local mode = features.minimal_popup_mode or "short"
      local label = (mode == "off") and _("Off") or _("On")
      return E("\u{1F4AD}", T(_("Minimal Popup: %1"), label))
    end)(),
    callback = function()
      local f = self_ref.settings:readSetting("features") or {}
      local mode = f.minimal_popup_mode or "short"
      if mode == "off" then
        -- Restore the remembered on-state (a user on "always" round-trips)
        f.minimal_popup_mode = f._minimal_popup_prev_mode or "short"
      else
        f._minimal_popup_prev_mode = mode
        f.minimal_popup_mode = "off"
      end
      self_ref.settings:saveSetting("features", f)
      self_ref.settings:flush()
      self_ref:updateConfigFromSettings()
      opening_subdialog = true
      UIManager:close(dialog)
      reopenQuickSettings()
    end,
    hold_callback = function()
      opening_subdialog = true
      UIManager:close(dialog)
      self_ref:showMinimalPopupQuickSettings(reopenQuickSettings)
    end,
  }

  button_defs["web_search"] = {
    text = (function()
      -- Binary-global rule (seam 2): tap toggles the GLOBAL default in place, hold
      -- opens the scope-aware picker (with the search-depth dial). Label shows the
      -- EFFECTIVE state for the open book, "(book)" when a per-book override masks it.
      local BookSettings = require("koassistant_book_settings")
      local doc_settings = has_document and self.ui.doc_settings or nil
      local label = BookSettings.resolveWebSearch(doc_settings, features,
        self:getCurrentProvider()) and _("On") or _("Off")
      if doc_settings and doc_settings:readSetting(BookSettings.KEY_WEB_SEARCH) ~= nil then
        label = label .. _(" (book)")
      end
      local base = T(_("Web Search: %1"), label)
      if not web_search_supported then
        -- Provider can't search — annotate but keep the global default toggle usable
        base = base .. " · " .. T(_("N/A for %1"), provider_display)
      end
      return E("\u{1F310}", base)
    end)(),
    callback = function()
      local f = self_ref.settings:readSetting("features") or {}
      f.enable_web_search = not f.enable_web_search
      self_ref.settings:saveSetting("features", f)
      self_ref.settings:flush()
      self_ref:updateConfigFromSettings()
      if not web_search_supported then
        UIManager:show(InfoMessage:new{
          text = T(_("Saved as default. %1 can't use web search. Switch to: %2."),
            provider_display, ModelConstraints.getWebSearchProvidersLabel()),
          timeout = 4,
        })
      end
      opening_subdialog = true
      UIManager:close(dialog)
      reopenQuickSettings()
    end,
    hold_callback = function()
      opening_subdialog = true
      UIManager:close(dialog)
      require("koassistant_book_settings").showWebSearch({
        plugin = self_ref,
        ui = has_document and self_ref.ui or nil,
        on_close = reopenQuickSettings,
      })
    end,
  }

  -- Language tiles (P4 deviation 8): the panel family rule — label shows the
  -- EFFECTIVE value for the open book with "(book)" when a per-book language
  -- override masks the global; tap keeps editing the global picker; hold (book
  -- open only) lands on the per-book Languages screen.
  local function bookLangOverride(key)
    local doc_settings = has_document and self.ui.doc_settings or nil
    local ov = doc_settings and doc_settings:readSetting(key)
    if ov and ov ~= "" then return ov end
    return nil
  end
  local holdLanguageConfig = has_document and function()
    opening_subdialog = true
    UIManager:close(dialog)
    require("koassistant_book_settings").showLanguageConfig({
      plugin = self_ref, ui = self_ref.ui,
      on_close = reopenQuickSettings,
    })
  end or nil
  local BookSettingsQS = require("koassistant_book_settings")

  local resp_ov = bookLangOverride(BookSettingsQS.KEY_RESPONSE_LANG)
  button_defs["language"] = {
    text = E("\u{1F30D}", T(_("Language: %1"),
      resp_ov and (getLanguageDisplay(resp_ov) .. _(" (book)")) or lang_display)),
    callback = function()
      opening_subdialog = true
      UIManager:close(dialog)
      local menu_items = self_ref:buildPrimaryLanguageMenu()
      self_ref:showQuickSettingsPopup(_("Primary Language"), menu_items, true, reopenQuickSettings)
    end,
    hold_callback = holdLanguageConfig,
  }

  local trans_ov = bookLangOverride(BookSettingsQS.KEY_TRANSLATION_LANG)
  button_defs["translation_language"] = {
    text = E("\u{1F30D}", T(_("Translate: %1"),
      trans_ov and (getLanguageDisplay(trans_ov) .. _(" (book)")) or trans_display)),
    callback = function()
      opening_subdialog = true
      UIManager:close(dialog)
      local menu_items = self_ref:buildTranslationLanguageMenu()
      self_ref:showQuickSettingsPopup(_("Translation Language"), menu_items, true, reopenQuickSettings)
    end,
    hold_callback = holdLanguageConfig,
  }

  local dict_ov = bookLangOverride(BookSettingsQS.KEY_DICTIONARY_LANG)
  button_defs["dictionary_language"] = {
    text = E("\u{1F30D}", T(_("Dictionary: %1"),
      dict_ov and (getLanguageDisplay(dict_ov) .. _(" (book)")) or dict_display)),
    callback = function()
      opening_subdialog = true
      UIManager:close(dialog)
      local menu_items = self_ref:buildDictionaryLanguageMenu()
      self_ref:showQuickSettingsPopup(_("Dictionary Language"), menu_items, true, reopenQuickSettings)
    end,
    hold_callback = holdLanguageConfig,
  }

  -- ⏩ = the bypass class icon; ⚡ is reserved for Quick Answer (A7b de-collision)
  button_defs["h_bypass"] = {
    text = E("\u{23E9}", highlight_bypass and _("H.Bypass: ON") or _("H.Bypass: OFF")),
    callback = function()
      local f = self_ref.settings:readSetting("features") or {}
      f.highlight_bypass_enabled = not f.highlight_bypass_enabled
      self_ref.settings:saveSetting("features", f)
      self_ref.settings:flush()
      self_ref:syncHighlightBypass()
      opening_subdialog = true
      UIManager:close(dialog)
      reopenQuickSettings()
    end,
    hold_callback = function()
      opening_subdialog = true
      UIManager:close(dialog)
      self_ref:showBypassQuickPick("highlight", reopenQuickSettings)
    end,
  }

  button_defs["d_bypass"] = {
    text = E("\u{23E9}", dict_bypass and _("D.Bypass: ON") or _("D.Bypass: OFF")),
    callback = function()
      local f = self_ref.settings:readSetting("features") or {}
      f.dictionary_bypass_enabled = not f.dictionary_bypass_enabled
      self_ref.settings:saveSetting("features", f)
      self_ref.settings:flush()
      self_ref:syncDictionaryBypass()
      opening_subdialog = true
      UIManager:close(dialog)
      reopenQuickSettings()
    end,
    hold_callback = function()
      opening_subdialog = true
      UIManager:close(dialog)
      self_ref:showBypassQuickPick("dictionary", reopenQuickSettings)
    end,
  }

  button_defs["text_extraction"] = {
    text = (function()
      -- P4 (deviation 7): the panel family rule — label shows the EFFECTIVE
      -- state for the open book, "(book)" when a per-book privacy override
      -- masks the global; tap keeps toggling the global, hold opens the
      -- per-book Privacy screen.
      local doc_settings = has_document and self.ui.doc_settings or nil
      local ov = doc_settings and doc_settings:readSetting(BookSettingsQS.KEY_TEXT_EXTRACTION)
      local on = text_extraction
      if ov ~= nil then on = ov end
      local label = on and _("On") or _("Off")
      if ov ~= nil then label = label .. _(" (book)") end
      return E("\u{1F4C4}", T(_("Text Extraction: %1"), label))
    end)(),
    callback = function()
      local f = self_ref.settings:readSetting("features") or {}
      -- First-time guard: must enable via Settings → Privacy & Data first
      if not f._text_extraction_acknowledged then
        local InfoMessage = require("ui/widget/infomessage")
        UIManager:show(InfoMessage:new{
          text = _("To enable text extraction for the first time, go to:\nSettings → Privacy & Data → Text Extraction\n\nAfter that, this toggle will work directly."),
        })
        return
      end
      f.enable_book_text_extraction = not f.enable_book_text_extraction
      self_ref.settings:saveSetting("features", f)
      self_ref.settings:flush()
      self_ref:updateConfigFromSettings()
      -- Masked-global rule (the spoiler tile's pattern): the global saved
      -- either way; if this book's own override masks it, say so — a silent
      -- no-op reads as a dead button.
      local doc_settings = has_document and self_ref.ui and self_ref.ui.doc_settings or nil
      if doc_settings and doc_settings:readSetting(BookSettingsQS.KEY_TEXT_EXTRACTION) ~= nil then
        UIManager:show(Notification:new{
          text = _("Saved as default. This book has its own override — hold the button to change it."),
          timeout = 3,
        })
      end
      opening_subdialog = true
      UIManager:close(dialog)
      reopenQuickSettings()
    end,
    hold_callback = has_document and function()
      opening_subdialog = true
      UIManager:close(dialog)
      require("koassistant_book_settings").showPrivacyConfig({
        plugin = self_ref, ui = self_ref.ui,
        on_close = reopenQuickSettings,
      })
    end or nil,
  }

  button_defs["chat_history"] = {
    text = E("\u{1F4DC}", _("Chat History")),
    callback = function()
      opening_subdialog = true
      UIManager:close(dialog)
      -- Always the main browser, even with a book open (all_books) — the QA
      -- panel's entry is the book-specific one
      self_ref:showChatHistory({ all_books = true })
    end,
  }

  button_defs["browse_notebooks"] = {
    text = E("\u{1F4D3}", _("Browse Notebooks")),
    callback = function()
      opening_subdialog = true
      UIManager:close(dialog)
      self_ref:onKOAssistantBrowseNotebooks()
    end,
  }

  button_defs["browse_artifacts"] = {
    text = E("\u{1F4E6}", _("Browse Artifacts")),
    callback = function()
      opening_subdialog = true
      UIManager:close(dialog)
      self_ref:onKOAssistantBrowseArtifacts()
    end,
  }

  -- Round 29: Groups joins the cross-book family in Quick Settings. This is the
  -- GLOBAL surface (like Browse Artifacts / Browse Notebooks), so it opens the
  -- manager unconditionally — a panel item labelled "Groups" that could not
  -- reach group management was the audit's dead-end finding. The book-scoped
  -- landing (members popup) stays on the Quick Actions panel entry, which only
  -- renders when the open book is in a group.
  button_defs["book_groups"] = {
    text = E("\u{1F5C2}\u{FE0F}", _("Groups")),
    callback = function()
      opening_subdialog = true
      UIManager:close(dialog)
      self_ref:showBookGroupsManager()
    end,
  }

  button_defs["library_actions"] = {
    text = E("\u{1F4DA}", _("Library Chat/Action")),
    callback = function()
      opening_subdialog = true
      UIManager:close(dialog)
      self_ref:openLibraryDialog()
    end,
  }

  button_defs["general_chat"] = {
    text = E("\u{1F5E8}\u{FE0F}", _("General Chat/Action")),
    callback = function()
      opening_subdialog = true
      UIManager:close(dialog)
      self_ref:startGeneralChat()
    end,
  }

  button_defs["continue_last_chat"] = {
    text = E("\u{21A9}\u{FE0F}", _("Continue Last Chat")),
    callback = function()
      opening_subdialog = true
      UIManager:close(dialog)
      self_ref:onKOAssistantContinueLastOpened()
    end,
  }

  button_defs["manage_actions"] = {
    text = E("\u{1F527}", _("Manage Actions")),
    callback = function()
      opening_subdialog = true
      UIManager:close(dialog)
      self_ref:showPromptsManager()
    end,
  }

  button_defs["more_settings"] = {
    text = E("\u{2699}\u{FE0F}", _("More Settings...")),
    callback = function()
      opening_subdialog = true
      UIManager:close(dialog)
      self_ref:onKOAssistantSettings()
    end,
  }

  -- Dynamic items (only when book is open)
  if has_document then
    -- (new_book_chat tile retired 2026-08-17, maintainer: it only rendered
    -- with a book open, exactly when the QA panel carries the same entry.)
    button_defs["quick_actions"] = {
      -- 🔁 = cross-panel link (pairs with the QA panel's Quick Settings utility)
      text = E("\u{1F501}", _("Quick Actions...")),
      callback = function()
        opening_subdialog = true
        UIManager:close(dialog)
        self_ref:onKOAssistantQuickActions()
      end,
    }
  end

  -- Iterate stored order, adding enabled + available items
  local qs_order = self.action_service:getQsItemsOrder()
  for _idx, item_id in ipairs(qs_order) do
    if isQsEnabled(item_id) and button_defs[item_id] then
      local btn = button_defs[item_id]
      btn.font_bold = false
      if features.qs_left_align ~= false then btn.align = "left" end
      table.insert(all_buttons, btn)
    end
  end

  -- Pair all buttons into rows of 2
  local buttons = {}
  for i = 1, #all_buttons, 2 do
    if all_buttons[i + 1] then
      table.insert(buttons, { all_buttons[i], all_buttons[i + 1] })
    else
      table.insert(buttons, { all_buttons[i] })
    end
  end
  -- Center lone last-row item when left-align is on
  if features.qs_left_align ~= false and #buttons > 0 and #buttons[#buttons] == 1 then
    buttons[#buttons][1].align = "center"
  end

  dialog = TitledButtonDialog:new{
    title = _("Quick Settings"),
    buttons = buttons,
    left_icon_tap_callback = function()
      local qs_gear_dialog
      qs_gear_dialog = ButtonDialog:new{
        shrink_unneeded_width = true,
        anchor = function()
          return dialog.title_bar.left_button.image.dimen, true
        end,
        buttons = {
          {{ text = _("Sort Items"), callback = function()
            UIManager:close(qs_gear_dialog)
            -- Close QS panel before sorting (invisible under fullscreen sorting manager)
            UIManager:close(dialog)
            PromptsManager:new(self_ref):showQsItemsManager(nil, function()
              reopenQuickSettings()
            end)
          end }},
          {{ text = features.qs_left_align ~= false and _("Align Buttons ✓") or _("Align Buttons"), callback = function()
            UIManager:close(qs_gear_dialog)
            local f = self_ref.settings:readSetting("features") or {}
            if f.qs_left_align ~= false then
              f.qs_left_align = false
            else
              f.qs_left_align = true
            end
            self_ref.settings:saveSetting("features", f)
            self_ref.settings:flush()
            self_ref:updateConfigFromSettings()
            opening_subdialog = true
            UIManager:close(dialog)
            reopenQuickSettings()
          end }},
        },
      }
      UIManager:show(qs_gear_dialog)
    end,
    close_callback = function()
      if not opening_subdialog and on_close_callback then
        on_close_callback()
      end
    end,
  }

  UIManager:show(dialog)
  return true
end

-- Quick Actions menu - launch reading-related actions quickly
-- Available only in reader mode (when a book is open)
function AskGPT:onKOAssistantQuickActions()
  local ButtonDialog = require("ui/widget/buttondialog")
  local self_ref = self

  -- Only available in reader mode
  if not self.ui or not self.ui.document then
    UIManager:show(InfoMessage:new{
      icon = "notice-warning",
      text = _("Quick Actions is only available while reading a book."),
    })
    return true
  end

  local dialog
  local buttons = {}
  local row = {}
  local qa_features = self.settings:readSetting("features") or {}

  -- Helper to add a button to current row, flush row when full
  local function addButton(btn)
    btn.font_bold = false
    if qa_features.qa_left_align == true then btn.align = "left" end
    table.insert(row, btn)
    if #row == 2 then
      table.insert(buttons, row)
      row = {}
    end
  end

  -- 1. Book actions from unified quick actions list (built-in defaults + user-added)
  local features = self.settings:readSetting("features") or {}
  local quick_action_ids = self.action_service:getQuickActions()
  for _idx, action_id in ipairs(quick_action_ids) do
    local action = self.action_service:getAction("book", action_id)
    if action and action.enabled ~= false then
      addButton({
        text = ActionService.getActionDisplayText(action, features),
        allow_hold_when_disabled = true,
        callback = function()
          UIManager:close(dialog)
          self_ref:executeBookLevelAction(action_id)
        end,
        hold_callback = function()
          if action.description then
            UIManager:show(InfoMessage:new{
              text = action.description,
            })
          end
        end,
      })
    end
  end

  -- 2. Utility items (configurable via Settings → Quick Actions Settings → Panel Utilities)
  -- Order driven by stored qa_utilities_order (user-sortable)
  local ActionCache = require("koassistant_action_cache")
  local file = self.ui.document.file

  -- Emoji support for QA utilities
  local qa_enable_emoji = features.enable_emoji_panel_icons == true
  local qa_emoji_map = {
    -- translate_page intentionally omitted (action-like, first utility)
    new_book_chat = "\u{1F4AC}",       -- 💬
    continue_last_chat = "\u{21A9}\u{FE0F}", -- ↩️
    general_chat = "\u{1F5E8}\u{FE0F}", -- 🗨️
    chat_history = "\u{1F4DC}",        -- 📜
    notebook = "\u{1F4D3}",            -- 📓
    view_caches = "\u{1F4E6}",         -- 📦
    book_group = "\u{1F5C2}\u{FE0F}",  -- 🗂️ (one icon for groups everywhere)
    book_overview = "\u{1F4CB}",       -- 📋 (the overview page)
    ai_quick_settings = "\u{1F501}",   -- 🔁 cross-panel link (pairs with QS's Quick Actions tile)
    book_settings = "\u{1F4D5}",       -- 📕
  }

  -- Build lookup map from constants
  local qa_util_map = {}
  for _i, u in ipairs(Constants.QUICK_ACTION_UTILITIES) do qa_util_map[u.id] = u end

  local qa_util_order = self.action_service:getQaUtilitiesOrder()
  for _idx, util_id in ipairs(qa_util_order) do
    local qa_util = qa_util_map[util_id]
    if qa_util then
      -- Check if utility is enabled (default true if not set)
      local enabled = features["qa_show_" .. util_id]
      if enabled == nil then enabled = qa_util.default end

      if enabled then
        if util_id == "view_caches" then
          -- Single "Artifacts" button — opens cache picker
          local has_any_cache = #ActionCache.getAvailableArtifactsWithPinned(file) > 0
          if has_any_cache then
            addButton({
              text = Constants.getEmojiText(qa_emoji_map[util_id], _("View Artifacts"), qa_enable_emoji),
              callback = function()
                -- Don't close QA panel yet — close only when user picks an artifact
                self_ref:viewCache(dialog)
              end,
            })
          end
        elseif util_id == "book_group" then
          -- Round 28: same dynamic rule as View Artifacts — the row exists only
          -- when this book actually belongs to a group, so readers who don't use
          -- groups never see it. Opens the members popup (THE group-navigation
          -- idiom), not the manager: from the panel you want to GO somewhere.
          if self_ref:_inBookGroup(file) then
            addButton({
              text = Constants.getEmojiText(qa_emoji_map[util_id], _("Group"), qa_enable_emoji),
              callback = function()
                UIManager:close(dialog)
                self_ref:_showGroupMembersPopup(file, "artifacts")
              end,
            })
          end
        else
          -- Standard utility button
          local display_text = Constants.getQuickActionUtilityText(util_id, _)
          local emoji = qa_emoji_map[util_id]
          if emoji then
            display_text = Constants.getEmojiText(emoji, display_text, qa_enable_emoji)
          end
          addButton({
            text = display_text,
            callback = function()
              UIManager:close(dialog)
              self_ref[qa_util.callback](self_ref)
            end,
          })
        end
      end
    end
  end

  -- Flush any remaining partial row
  if #row > 0 then
    table.insert(buttons, row)
  end
  -- Center lone last-row item when left-align is on
  if qa_features.qa_left_align == true and #buttons > 0 and #buttons[#buttons] == 1 then
    buttons[#buttons][1].align = "center"
  end

  dialog = TitledButtonDialog:new{
    title = _("Quick Actions"),
    buttons = buttons,
    left_icon_tap_callback = function()
      local chooser_dialog
      chooser_dialog = ButtonDialog:new{
        shrink_unneeded_width = true,
        anchor = function()
          return dialog.title_bar.left_button.image.dimen, true
        end,
        buttons = {
          {{ text = _("Panel Actions"), callback = function()
            UIManager:close(chooser_dialog)
            UIManager:close(dialog)  -- Close QA panel (invisible under fullscreen sorting)
            PromptsManager:new(self_ref):showQuickActionsManager(function()
              self_ref:onKOAssistantQuickActions()
            end)
          end }},
          {{ text = _("Panel Utilities"), callback = function()
            UIManager:close(chooser_dialog)
            UIManager:close(dialog)  -- Close QA panel (invisible under fullscreen sorting)
            PromptsManager:new(self_ref):showQaUtilitiesManager(nil, function()
              self_ref:onKOAssistantQuickActions()
            end)
          end }},
          {{ text = qa_features.qa_left_align == true and _("Align Buttons ✓") or _("Align Buttons"), callback = function()
            UIManager:close(chooser_dialog)
            local f = self_ref.settings:readSetting("features") or {}
            if f.qa_left_align == true then
              f.qa_left_align = false
            else
              f.qa_left_align = true
            end
            self_ref.settings:saveSetting("features", f)
            self_ref.settings:flush()
            self_ref:updateConfigFromSettings()
            UIManager:close(dialog)
            self_ref:onKOAssistantQuickActions()
          end }},
        },
      }
      UIManager:show(chooser_dialog)
    end,
  }
  UIManager:show(dialog)
  return true
end

function AskGPT:testProviderConnection()
  local InfoMessage = require("ui/widget/infomessage")
  local UIManager = require("ui/uimanager")
  local GptQuery = require("koassistant_gpt_query")
  local queryChatGPT = GptQuery.query
  local isStreamingInProgress = GptQuery.isStreamingInProgress
  local MessageHistory = require("koassistant_message_history")

  UIManager:show(InfoMessage:new{
    text = _("Testing connection..."),
    timeout = 2,
  })

  -- Create a simple test message
  local test_message_history = MessageHistory:new()
  test_message_history:addUserMessage("Hello, this is a connection test. Please respond with 'Connection successful'.")

  -- Get current configuration (global configuration is updated with settings in init)
  -- Disable streaming for test to keep it simple
  local test_config = {
    provider = configuration.provider,
    model = configuration.model,
    temperature = 0.1,
    max_tokens = 50,
    features = {
      debug = configuration.features and configuration.features.debug or false,
      enable_streaming = false, -- Disable streaming for test
    }
  }

  -- Perform the test query asynchronously with callback
  UIManager:scheduleIn(0.1, function()
    queryChatGPT(test_message_history:getMessages(), test_config, function(success, response, err)
      if success and response and type(response) == "string" then
        if response:match("^Error:") then
          -- Connection failed
          UIManager:show(InfoMessage:new{
            text = _("Connection test failed:\n") .. response,
            timeout = 5,
          })
        else
          -- Connection successful
          UIManager:show(InfoMessage:new{
            text = T(_("Connection test successful!\n\nProvider: %1\nModel: %2\n\nResponse: %3"),
              test_config.provider, test_config.model or "default", response:sub(1, 100)),
            timeout = 5,
          })
        end
      else
        -- Connection failed with error
        UIManager:show(InfoMessage:new{
          text = _("Connection test failed: ") .. (err or "Unexpected response format"),
          timeout = 5,
        })
      end
    end, self.settings)
  end)
end

--- Delete all artifacts for the current book
-- Called from Settings → Advanced → Book Text Extraction → Delete Book Artifacts
function AskGPT:clearActionCache()
  local InfoMessage = require("ui/widget/infomessage")
  local UIManager = require("ui/uimanager")
  local ButtonDialog = require("ui/widget/buttondialog")
  local ActionCache = require("koassistant_action_cache")

  -- Check if we're in reader mode with an open book
  local ui = self.ui
  if not ui or not ui.document or not ui.document.file then
    UIManager:show(InfoMessage:new{
      text = _("No book is currently open.\n\nOpen a book first, then use this option to delete its artifacts."),
      timeout = 5,
    })
    return
  end

  local document_path = ui.document.file
  local cache_path = ActionCache.getPath(document_path)

  -- Check if cache exists
  local attr = cache_path and lfs.attributes(cache_path)
  if not attr or attr.mode ~= "file" then
    UIManager:show(InfoMessage:new{
      text = _("No artifacts found for this book.\n\nRun an artifact action (X-Ray, Recap, Summarize, etc.) first."),
      timeout = 3,
    })
    return
  end

  -- Confirm before clearing
  local dialog
  dialog = ButtonDialog:new{
    title = _("Delete Book Artifacts"),
    text = _("Delete ALL artifacts for this book?\n\nThis removes the X-Ray (with its archived versions and checkpoints), summaries, analyses, wiki entries and every other artifact. Chats, notebook, pinned items and generated images are kept.\n\nThis cannot be undone."),
    buttons = {
      {
        {
          text = _("Cancel"),
          callback = function()
            UIManager:close(dialog)
          end,
        },
        {
          text = _("Delete"),
          callback = function()
            UIManager:close(dialog)
            local success = ActionCache.clearAll(document_path)
            -- Invalidate file browser row cache
            self._file_dialog_row_cache = { file = nil, rows = nil }
            if success then
              UIManager:show(InfoMessage:new{
                text = _("Artifacts deleted."),
                timeout = 2,
              })
            else
              UIManager:show(InfoMessage:new{
                text = _("Failed to delete artifacts."),
                timeout = 3,
              })
            end
          end,
        },
      },
    },
  }
  UIManager:show(dialog)
end

--- Action Manager gesture handler
function AskGPT:onKOAssistantActionManager()
  self:showPromptsManager()
  return true
end

--- Behavior Manager gesture handler
function AskGPT:onKOAssistantManageBehaviors()
  self:showBehaviorManager()
  return true
end

--- Domain Manager gesture handler
function AskGPT:onKOAssistantManageDomains()
  self:showDomainManager()
  return true
end

--- Change Domain gesture handler (quick selector popup)
function AskGPT:onKOAssistantChangeDomain()
  self:showDomainPopup()
  return true
end

--- Book Settings — per-book settings (domain, research, AI title/author). Quick Actions
--- panel utility; reader-only (a book is open).
function AskGPT:onKOAssistantBookSettings()
  local BookSettings = require("koassistant_book_settings")
  BookSettings.show({ plugin = self, ui = self.ui })
  return true
end

--- Show the Domain & Research picker from the Quick Settings domain chip.
--- Thin wrapper over the shared BookSettings.showDomainResearch entry point — this
--- surface stays the domain/research control (it opens with no book too), NOT Book Settings.
--- @param on_close_callback function|nil: Called after popup closes (e.g., reopen quick settings)
--- @param target_override string|nil: "book" | "global" — forces the editing layer
function AskGPT:showDomainPopup(on_close_callback, target_override)
  local BookSettings = require("koassistant_book_settings")
  BookSettings.showDomainResearch({
    plugin = self,
    ui = self.ui,
    on_close = on_close_callback,
    target_override = target_override,
  })
end

--- AI Book Tools posture picker (QS chip entry; tools_ux_plan.md §3)
function AskGPT:showToolsPosturePopup(on_close_callback, target_override)
  local BookSettings = require("koassistant_book_settings")
  BookSettings.showToolsPosture({
    plugin = self,
    ui = self.ui,
    on_close = on_close_callback,
    target_override = target_override,
  })
end

--- "Default Domain & Research" settings entry (Actions & Prompts submenu) — the shared
-- scope-aware picker, opened targeting the GLOBAL default (a book target stays one tap
-- away when a book is open). The settings renderer passes touchmenu_instance as the
-- second arg; ignore it (it is not an on_close callback).
function AskGPT:showDomainSettingsEntry()
  self:showDomainPopup(nil, "global")
end

-- Dictionary Popup Manager gesture handler
function AskGPT:onKOAssistantDictionaryPopupManager()
  self:showDictionaryPopupManager()
  return true
end

-- Toggle Dictionary Bypass gesture handler
function AskGPT:onKOAssistantToggleDictionaryBypass()
  local features = self.settings:readSetting("features") or {}
  local current_state = features.dictionary_bypass_enabled or false
  features.dictionary_bypass_enabled = not current_state
  self.settings:saveSetting("features", features)
  self.settings:flush()

  -- Re-sync the bypass
  self:syncDictionaryBypass()

  UIManager:show(Notification:new{
    text = features.dictionary_bypass_enabled and _("Dictionary bypass: ON") or _("Dictionary bypass: OFF"),
    timeout = 1.5,
  })
  return true
end

function AskGPT:onKOAssistantToggleHighlightBypass()
  local features = self.settings:readSetting("features") or {}
  local current_state = features.highlight_bypass_enabled or false
  features.highlight_bypass_enabled = not current_state
  self.settings:saveSetting("features", features)
  self.settings:flush()

  UIManager:show(Notification:new{
    text = features.highlight_bypass_enabled and _("Highlight bypass: ON") or _("Highlight bypass: OFF"),
    timeout = 1.5,
  })
  return true
end

--- View current book's notebook gesture handler
function AskGPT:onKOAssistantViewNotebook()
  local ReaderUI = require("apps/reader/readerui")
  local reader_ui = ReaderUI.instance

  if not reader_ui or not reader_ui.document then
    UIManager:show(InfoMessage:new{
      text = _("Please open a book first"),
      timeout = 2,
    })
    return true
  end

  local file_path = reader_ui.document.file
  self:openNotebookForFile(file_path)
  return true
end

--- Edit current book's notebook gesture handler
function AskGPT:onKOAssistantEditNotebook()
  local ReaderUI = require("apps/reader/readerui")
  local reader_ui = ReaderUI.instance

  if not reader_ui or not reader_ui.document then
    UIManager:show(InfoMessage:new{
      text = _("Please open a book first"),
      timeout = 2,
    })
    return true
  end

  local file_path = reader_ui.document.file
  self:openNotebookForFile(file_path, true)  -- true = edit mode
  return true
end

--- Notebook button for QA panel: View/Edit popup, or create if none exists
function AskGPT:onKOAssistantNotebook()
  local ReaderUI = require("apps/reader/readerui")
  local reader_ui = ReaderUI.instance

  if not reader_ui or not reader_ui.document then
    UIManager:show(InfoMessage:new{
      text = _("Please open a book first"),
      timeout = 2,
    })
    return true
  end

  local file_path = reader_ui.document.file
  local Notebook = require("koassistant_notebook")

  if not Notebook.exists(file_path) then
    -- No notebook — go straight to create prompt (opens editor after creation)
    self:openNotebookForFile(file_path)
    return true
  end

  -- Notebook exists — show View/Edit popup
  local ButtonDialog = require("ui/widget/buttondialog")
  local self_ref = self
  local dialog
  dialog = ButtonDialog:new{
    title = _("Notebook"),
    buttons = {
      {
        {
          text = _("View"),
          callback = function()
            UIManager:close(dialog)
            self_ref:openNotebookForFile(file_path)
          end,
        },
        {
          text = _("Edit"),
          callback = function()
            UIManager:close(dialog)
            self_ref:openNotebookForFile(file_path, true)
          end,
        },
      },
    },
  }
  UIManager:show(dialog)
  return true
end

--- Browse all notebooks gesture handler
function AskGPT:onKOAssistantBrowseNotebooks()
  local NotebookManager = require("koassistant_notebook_manager")
  local features = self.settings:readSetting("features") or {}
  NotebookManager:showNotebookBrowser({ enable_emoji = features.enable_emoji_icons == true })
  return true
end

function AskGPT:onKOAssistantViewCaches()
  self:viewCache()
  return true
end

--- Browse notebooks (settings menu callback)
function AskGPT:showNotebookBrowser()
  local NotebookManager = require("koassistant_notebook_manager")
  local features = self.settings:readSetting("features") or {}
  NotebookManager:showNotebookBrowser({ enable_emoji = features.enable_emoji_icons == true })
end

--- Browse artifacts gesture handler
function AskGPT:onKOAssistantBrowseArtifacts()
  self:showArtifactBrowser()
  return true
end

--- Browse artifacts (settings menu callback)
function AskGPT:showArtifactBrowser()
  local ArtifactBrowser = require("koassistant_artifact_browser")
  local features = self.settings:readSetting("features") or {}
  ArtifactBrowser:showArtifactBrowser({ enable_emoji = features.enable_emoji_icons == true })
end

--- Library actions gesture handler
function AskGPT:onKOAssistantLibraryActions()
  self:openLibraryDialog()
  return true
end

--- Open library dialog directly to input/actions (no BookPicker gate)
function AskGPT:openLibraryDialog()
  configuration.features = configuration.features or {}
  -- Scrub inherited context state (incl. a stale book_metadata, which would make
  -- response-language/effort dials resolve against that book — injection_gating_audit),
  -- then set library context. Books start unselected — user adds via presets/picker.
  self:_scrubContextFeatures(configuration.features)
  configuration.features.is_library_context = true

  self:ensureInitialized()
  self:updateConfigFromSettings()
  local ui_context = self.ui or FileManager.instance
  showChatGPTDialog(ui_context, nil, configuration, nil, self)
end

--- Open the library dialog pre-filled with a group's members (item 48(a):
--- groups as launch surface). Reading order kept; missing files skipped.
--- Saved chats get stamped with the group via the _group_launch transient.
function AskGPT:openLibraryDialogForGroup(group_id)
  local BookGroups = require("koassistant_book_groups")
  local group = BookGroups.byId(group_id)
  if not group then return end
  local books_info = BookGroups.booksInfoFor(group, self.ui)
  if #books_info == 0 then
    UIManager:show(InfoMessage:new{
      text = _("No books from this group are available on this device."),
      timeout = 3,
    })
    return
  end
  configuration.features = configuration.features or {}
  self:_scrubContextFeatures(configuration.features)
  configuration.features.is_library_context = true
  -- Same shapes mergeBooks (koassistant_dialogs.lua) writes, so the dialog's
  -- selected-books editor and Add Books menu work on this list seamlessly
  local books_list = {}
  for i, book in ipairs(books_info) do
    if book.authors ~= "" then
      table.insert(books_list, string.format('%d. "%s" by %s', i, book.title, book.authors))
    else
      table.insert(books_list, string.format('%d. "%s"', i, book.title))
    end
  end
  configuration.features.books_info = books_info
  configuration.features.book_context = string.format(
    "Selected %d books:\n\n%s", #books_info, table.concat(books_list, "\n"))
  configuration.features.book_metadata = buildBookMetadata(
    books_info[1].title, books_info[1].authors)
  configuration.features._group_launch = { id = group.id, name = group.name }

  self:ensureInitialized()
  self:updateConfigFromSettings()
  local ui_context = self.ui or FileManager.instance
  showChatGPTDialog(ui_context, nil, configuration, nil, self)
end

--- Legacy: open BookPicker for manual book selection (called from Add Books menu)
function AskGPT:showLibraryPicker()
  local BookPicker = require("koassistant_book_picker")
  local self_ref = self
  BookPicker:show({
    on_confirm = function(selected_files)
      self_ref:compareSelectedBooks(selected_files)
    end,
  })
end

-- Translate current page gesture handler
function AskGPT:onKOAssistantTranslatePage()
  self:translateCurrentPage()
  return true
end

function AskGPT:translateCurrentPage()
  if not self.ui or not self.ui.document then
    UIManager:show(InfoMessage:new{
      text = _("No document open"),
      timeout = 2,
    })
    return
  end

  local ContextExtractor = require("koassistant_context_extractor")
  local extractor = ContextExtractor:new(self.ui, configuration.features or {})
  local page_result = extractor:getVisiblePageText()
  local page_text = page_result.text

  if not page_text or page_text == "" then
    UIManager:show(InfoMessage:new{
      text = _("Could not extract text from current page"),
      timeout = 2,
    })
    return
  end

  -- Get translate action
  local Actions = require("prompts/actions")
  local translate_action = Actions.special and Actions.special.translate
  if not translate_action then
    UIManager:show(InfoMessage:new{
      text = _("Translate action not found"),
      timeout = 2,
    })
    return
  end

  -- Build configuration (full view, not compact)
  -- IMPORTANT: Create a proper shallow copy with a NEW features object
  local config_copy = {}
  for k, v in pairs(configuration) do
    config_copy[k] = v
  end
  -- Create NEW features table (don't share reference with global configuration)
  config_copy.features = {}
  for k, v in pairs(configuration.features or {}) do
    config_copy.features[k] = v
  end
  config_copy.context = "highlight"
  -- Scrub stale cross-context state to ensure highlight context
  self:_scrubContextFeatures(config_copy.features)
  -- Explicitly ensure full view (not compact/dictionary)
  config_copy.features.compact_view = false
  config_copy.features.dictionary_view = false
  config_copy.features.minimal_buttons = false
  -- Mark this as full page translate so handlePredefinedPrompt can apply translate_hide_full_page setting
  -- Note: The actual hiding is handled in handlePredefinedPrompt which respects user's translate_hide_highlight_mode
  config_copy.features.is_full_page_translate = true
  -- Clear selection_data - there's no actual user highlight for page translation,
  -- so the "Save to Note" button should be disabled (prevents using stale data from prior highlights)
  config_copy.features.selection_data = nil
  -- Same hygiene for the surrounding-context window: no selection here, and the
  -- features copy above could carry a stale one from an earlier highlight
  config_copy.features._selection_context_window = nil

  -- Execute translation
  logger.dbg("KOAssistant: translateCurrentPage calling executeDirectAction with page_text:", page_text and #page_text or "nil/empty")
  Dialogs.executeDirectAction(
    self.ui,
    translate_action,
    page_text,
    config_copy,
    self
  )
end

-- Change Dictionary Language gesture handler
function AskGPT:onKOAssistantChangeDictionaryLanguage()
  local menu_items = self:buildDictionaryLanguageMenu()
  self:showQuickSettingsPopup(_("Dictionary Language"), menu_items)
  return true
end

-- Build dictionary language menu (for gesture action and AI Quick Settings)
-- Shows available languages for dictionary response language
-- NOTE: This overrides the earlier buildDictionaryLanguageMenu definition
function AskGPT:buildDictionaryLanguageMenu()
  local self_ref = self
  local items = {}

  -- Option to follow translation language
  table.insert(items, {
    text = _("Follow Translation Language"),
    checked_func = function()
      local f = self_ref.settings:readSetting("features") or {}
      local dict_lang = f.dictionary_language
      return dict_lang == nil or dict_lang == "" or dict_lang == "__FOLLOW_TRANSLATION__"
    end,
    radio = true,
    callback = function()
      local f = self_ref.settings:readSetting("features") or {}
      f.dictionary_language = "__FOLLOW_TRANSLATION__"
      self_ref.settings:saveSetting("features", f)
      self_ref.settings:flush()
      self_ref:updateConfigFromSettings()
      UIManager:show(Notification:new{
        text = _("Dictionary: Follow Translation"),
        timeout = 1.5,
      })
    end,
  })

  -- Option to follow primary language directly
  table.insert(items, {
    text = _("Follow Primary Language"),
    checked_func = function()
      local f = self_ref.settings:readSetting("features") or {}
      return f.dictionary_language == "__FOLLOW_PRIMARY__"
    end,
    radio = true,
    callback = function()
      local f = self_ref.settings:readSetting("features") or {}
      f.dictionary_language = "__FOLLOW_PRIMARY__"
      self_ref.settings:saveSetting("features", f)
      self_ref.settings:flush()
      self_ref:updateConfigFromSettings()
      UIManager:show(Notification:new{
        text = _("Dictionary: Follow Primary"),
        timeout = 1.5,
      })
    end,
    separator = true,
  })

  -- Get combined languages (interaction + additional)
  local languages = self:getCombinedLanguages()

  -- Shared row builder: fixed language choice with confirmation toast
  local function addLanguageRow(lang)
    table.insert(items, {
      text = getLanguageDisplay(lang),
      checked_func = function()
        local f = self_ref.settings:readSetting("features") or {}
        return f.dictionary_language == lang
      end,
      radio = true,
      callback = function()
        local f = self_ref.settings:readSetting("features") or {}
        f.dictionary_language = lang
        self_ref.settings:saveSetting("features", f)
        self_ref.settings:flush()
        self_ref:updateConfigFromSettings()
        UIManager:show(Notification:new{
          text = T(_("Dictionary: %1"), getLanguageDisplay(lang)),
          timeout = 1.5,
        })
      end,
    })
  end

  -- Add each language as an option
  for _i, lang in ipairs(languages) do
    addLanguageRow(lang)
  end

  -- Add common fallback if no languages configured
  if #languages == 0 then
    local fallback_languages = {"English", "Spanish", "French", "German", "Chinese", "Japanese", "Korean"}
    for _idx, lang in ipairs(fallback_languages) do
      addLanguageRow(lang)
    end
  end

  -- "Custom..." — any language by name, mirrors the translate picker. Sets
  -- dictionary_language only; deliberately does NOT touch the user's language
  -- lists (interaction/additional).
  table.insert(items, {
    text = _("Custom..."),
    opens_dialog = true, -- quick settings: close the popup, don't reopen over the input dialog
    callback = function()
      local InputDialog = require("ui/widget/inputdialog")
      local f = self_ref.settings:readSetting("features") or {}
      -- Never prefill the internal __FOLLOW_*__ sentinels
      local current = f.dictionary_language
      if current == "__FOLLOW_TRANSLATION__" or current == "__FOLLOW_PRIMARY__" then
        current = nil
      end
      local input_dialog
      input_dialog = InputDialog:new{
        title = _("Custom Dictionary Language"),
        input = current or "",
        input_hint = _("e.g., Spanish, Japanese, French"),
        description = _("Enter the response language for dictionary lookups."),
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
                local new_lang = input_dialog:getInputText()
                if new_lang and new_lang ~= "" then
                  f.dictionary_language = new_lang
                  self_ref.settings:saveSetting("features", f)
                  self_ref.settings:flush()
                  self_ref:updateConfigFromSettings()
                  UIManager:show(Notification:new{
                    text = T(_("Dictionary: %1"), getLanguageDisplay(new_lang)),
                    timeout = 1.5,
                  })
                end
                UIManager:close(input_dialog)
              end,
            },
          },
        },
      }
      UIManager:show(input_dialog)
      input_dialog:onShowKeyboard()
    end,
  })

  return items
end

function AskGPT:showPromptsManager()
  local prompts_manager = PromptsManager:new(self)
  prompts_manager:show()
end

function AskGPT:showHighlightMenuManager()
  local prompts_manager = PromptsManager:new(self)
  prompts_manager:showHighlightMenuManager()
end

function AskGPT:showDictionaryPopupManager()
  local prompts_manager = PromptsManager:new(self)
  prompts_manager:showDictionaryPopupManager()
end

function AskGPT:showQuickActionsManager()
  local prompts_manager = PromptsManager:new(self)
  prompts_manager:showQuickActionsManager()
end

function AskGPT:showQaUtilitiesManager()
  local prompts_manager = PromptsManager:new(self)
  prompts_manager:showQaUtilitiesManager()
end

function AskGPT:showQsItemsManager()
  local prompts_manager = PromptsManager:new(self)
  prompts_manager:showQsItemsManager()
end

function AskGPT:showFileBrowserActionsManager()
  local prompts_manager = PromptsManager:new(self)
  prompts_manager:showFileBrowserActionsManager()
end

function AskGPT:showInputActionsChooser()
  local prompts_manager = PromptsManager:new(self)
  prompts_manager:showInputActionsChooser()
end

-- Show PathChooser for custom export path
function AskGPT:showExportPathPicker(revert_on_cancel)
  local PathChooser = require("ui/widget/pathchooser")

  local features = self.settings:readSetting("features") or {}
  -- Use KOReader's fallback chain: home_dir setting → Device.home_dir → DataStorage
  local start_path = G_reader_settings:readSetting("home_dir") or Device.home_dir or DataStorage:getDataDir()
  local current_path = features.export_custom_path or start_path

  local confirmed = false
  local self_ref = self

  local path_chooser = PathChooser:new{
    title = _("Select Export Folder"),
    path = current_path,
    select_directory = true,
    select_file = false,
    onConfirm = function(selected_path)
      confirmed = true
      features.export_custom_path = selected_path
      self_ref.settings:saveSetting("features", features)
      UIManager:show(InfoMessage:new{
        text = T(_("Export path set to:\n%1"), selected_path),
        timeout = 3,
      })
    end,
  }

  -- Revert dropdown to default if user cancels without picking a folder
  if revert_on_cancel then
    path_chooser.close_callback = function()
      if not confirmed then
        features.export_save_directory = "exports_folder"
        self_ref.settings:saveSetting("features", features)
        self_ref:updateConfigFromSettings()
      end
    end
  end

  UIManager:show(path_chooser)
end

--- Show path picker for notebook custom folder
--- @param revert_to string|nil Previous location to revert to on cancel (nil = no revert)
function AskGPT:showNotebookPathPicker(revert_to)
  local PathChooser = require("ui/widget/pathchooser")

  local features = self.settings:readSetting("features") or {}
  local start_path = G_reader_settings:readSetting("home_dir") or Device.home_dir or DataStorage:getDataDir()
  local current_path = features.notebook_custom_path or start_path

  local confirmed = false
  local self_ref = self

  local path_chooser = PathChooser:new{
    title = _("Select Notebook Folder"),
    path = current_path,
    select_directory = true,
    select_file = false,
    onConfirm = function(selected_path)
      confirmed = true
      features.notebook_custom_path = selected_path
      self_ref.settings:saveSetting("features", features)
      self_ref.settings:flush()
      UIManager:show(InfoMessage:new{
        text = T(_("Notebook folder set to:\n%1"), selected_path),
        timeout = 3,
      })
      -- Trigger migration offer if switching from another location
      if revert_to then
        self_ref:offerNotebookMigration(revert_to, "custom")
      end
    end,
  }

  -- Revert dropdown to previous location if user cancels
  if revert_to then
    path_chooser.close_callback = function()
      if not confirmed then
        features.notebook_save_location = revert_to
        self_ref.settings:saveSetting("features", features)
        self_ref:updateConfigFromSettings()
      end
    end
  end

  UIManager:show(path_chooser)
end

-- Register quick-action shortcut SLOTS for the highlight menu.
-- Called once during init. A fixed set of stable slot ids is always registered; each
-- slot resolves "the i-th entry of the CURRENT ordered highlight-menu action list"
-- freshly at menu-open time (KOReader calls every factory on each onShowHighlightMenu
-- and honors show_in_highlight_dialog_func), so enable/disable, membership and
-- ordering-manager changes apply the next time the menu opens — no restart.
-- Membership beyond the slot cap appears only after the plugin re-inits (book reopen).
function AskGPT:registerHighlightMenuActions()
  if not self.ui or not self.ui.highlight then return end

  local MAX_SLOTS = 15

  -- Per-menu-open memo shared by all slot closures. KOReader calls every registered
  -- factory synchronously in ONE sorted onShowHighlightMenu loop, so slot 01 always
  -- runs first among our slots: it resolves the ordered action list once and the
  -- other slots reuse it. Resolving per slot would re-run action requirement checks
  -- (hasAnyXray → loadCache dofile of the X-Ray cache) up to 15× per menu open —
  -- a real cost on e-ink storage.
  local menu_memo = nil

  for i = 1, MAX_SLOTS do
    local slot_index = i
    -- Numeric prefix for ordering: KOReader's orderedPairs sorts keys alphabetically;
    -- 90_ comes after KOReader's built-in items and before our koassistant_* buttons
    local dialog_id = string.format("90_%02d_koassistant_slot", i)

    self.ui.highlight:addToHighlightDialog(dialog_id, function(reader_highlight_instance)
      -- Slot 01 refreshes the memo each menu open (current toggle/membership/order);
      -- later slots fall back to resolving only if slot 01 somehow never ran
      if slot_index == 1 or not menu_memo then
        local cur_features = self.settings:readSetting("features") or {}
        local list = {}
        if cur_features.show_quick_actions_in_highlight ~= false then
          local has_open_book = self.ui and self.ui.document ~= nil
          local document_path = has_open_book and self.ui.document.file
          list = self.action_service:getHighlightMenuActionObjects(has_open_book, document_path)
        end
        menu_memo = { list = list, features = cur_features }
      end
      local cur_features = menu_memo.features
      local action = menu_memo.list[slot_index]
      if not action then
        -- Empty/hidden slot. NEVER return nil here: onShowHighlightMenu indexes the
        -- returned table unconditionally (readerhighlight.lua)
        return { text = "", show_in_highlight_dialog_func = function() return false end }
      end
      return {
        text = ActionService.getActionDisplayText(action, cur_features) .. " (KOA)",
        enabled = Device:hasClipboard(),
        allow_hold_when_disabled = true,
        hold_callback = function()
          if action.description then
            UIManager:show(InfoMessage:new{
              text = action.description,
            })
          end
        end,
        callback = function()
          -- Capture text and extract context BEFORE closing highlight overlay
          local selected_text = reader_highlight_instance.selected_text.text
          local context = ""
          -- Check if highlight module has the getSelectedWordContext method
          -- Note: Method is on self.ui.highlight, not reader_highlight_instance
          if self.ui.highlight and self.ui.highlight.getSelectedWordContext then
            local context_mode = require("koassistant_book_settings")
              .resolveDictionaryContext(self.ui and self.ui.doc_settings, cur_features)
            -- Skip context extraction if mode is "none"
            if context_mode ~= "none" then
              local context_chars = cur_features.dictionary_context_chars or 100
              context = Dialogs.extractSurroundingContext(
                self.ui,
                selected_text,
                context_mode,
                context_chars
              )
            end
          end
          -- Pre-extract the surrounding-context window while the selection is alive
          -- (onClose clears it; handlePredefinedPrompt trims per the resolved mode)
          local sc_window = Dialogs.fetchSelectionContextWindow(self.ui, selected_text)

          -- Capture full selection data for "Save to Note" feature (before onClose clears it)
          local selection_data = nil
          if reader_highlight_instance.selected_text then
            local st = reader_highlight_instance.selected_text
            selection_data = {
              text = st.text,
              pos0 = st.pos0,
              pos1 = st.pos1,
              sboxes = st.sboxes,
              pboxes = st.pboxes,
              ext = st.ext,
              drawer = st.drawer,
              color = st.color,
            }
          end

          -- Close highlight overlay to prevent darkening on saved highlights
          reader_highlight_instance:onClose()

          if action.local_handler then
            -- Local actions don't need network
            self:updateConfigFromSettings()
            self:executeQuickAction(action, selected_text, context, selection_data, sc_window)
          else
            NetworkMgr:runWhenConnected(function()
              self:updateConfigFromSettings()
              -- Pass extracted context and selection data to executeQuickAction
              self:executeQuickAction(action, selected_text, context, selection_data, sc_window)
            end)
          end
        end,
      }
    end)
  end
end

-- Sync dictionary bypass based on settings
-- When enabled, word taps go directly to the default dictionary popup action
-- This overrides ReaderDictionary:onLookupWord to intercept word taps
function AskGPT:syncDictionaryBypass()
  local features = self.settings:readSetting("features") or {}
  local bypass_enabled = features.dictionary_bypass_enabled
  -- X-Ray intercept (#63 rounds 9-10, OPT-OUT since round 10 — it only
  -- does anything for books with an X-Ray, where you almost always want it):
  -- a layer AHEAD of the whole dictionary flow — an exact entity word opens
  -- its X-Ray entry, everything else falls through to the configured
  -- behavior (bypass action or native dictionary). Independent of the
  -- bypass setting, so the wrapper installs for either.
  -- Round 5 (per-book intercept): the actual gate resolves PER CALL inside
  -- the wrapper (book > global); this install condition only asks whether the
  -- intercept COULD apply — global on, or the open book overriding on while
  -- the global is off. Re-evaluated per book open (onReaderReady resync). A
  -- lookup-book override with global off and another book open is out of
  -- reach by design (no wrapper installed).
  local intercept_on = features.xray_selection_intercept ~= false
  if not intercept_on and self.ui and self.ui.doc_settings then
    intercept_on = self:_openBookDS():readSetting(
      require("koassistant_book_settings").KEY_XRAY_INTERCEPT) == true
  end

  -- Check if we have access to the reader's dictionary module
  if not self.ui or not self.ui.dictionary then
    logger.dbg("KOAssistant: Cannot sync dictionary bypass - reader dictionary not available")
    return
  end

  local dictionary = self.ui.dictionary

  if bypass_enabled or intercept_on then
    -- Store original method if not already stored
    if not dictionary._koassistant_original_onLookupWord then
      dictionary._koassistant_original_onLookupWord = dictionary.onLookupWord
      logger.dbg("KOAssistant: Storing original ReaderDictionary:onLookupWord")
    end

    local self_ref = self
    dictionary.onLookupWord = function(dict_self, word, is_sane, boxes, highlight, link, dict_close_callback)
      -- X-Ray intercept: exact entity hit → its X-Ray entry, ahead of any
      -- bypass action. Reads the lookup-book flag WITHOUT consuming (the
      -- fall-through paths hand it to the normal chain); consumes only when
      -- actually intercepting. Round 5: the gate resolves per call
      -- (book > global) — install-time capture would strand book overrides.
      do
        local ActionCache = require("koassistant_action_cache")
        local i_file = dict_self._koassistant_lookup_book
          or (self_ref.ui and self_ref.ui.document and self_ref.ui.document.file)
        -- Memoized route index (slice 2): a stat per tap instead of the old
        -- full cache parse per tap — the #63 one-parse-per-tap cost is gone
        if i_file and self_ref:_xrayInterceptEnabled(i_file)
            and ActionCache.matchAnyXrayExact(i_file, word,
              { include_ahead = self_ref:_xrayAheadEnabled(i_file),
                position = self_ref:_xrayReaderPosition(i_file) }) then
          logger.dbg("KOAssistant: X-Ray intercept - word matches entity, opening X-Ray")
          local lookup_book = dict_self._koassistant_lookup_book
          dict_self._koassistant_non_reader_lookup = nil
          dict_self._koassistant_lookup_book = nil
          -- No dict window will ever exist to clear the reader's selection
          -- on close (stock clears it from DictQuickLookup; the bypass
          -- path below clears it too) — without this the word stays stuck
          -- selected and the next tap re-fires the lookup (device
          -- 2026-08-13)
          if highlight and highlight.clear then
            highlight:clear()
          end
          if dict_close_callback then
            dict_close_callback()
          end
          -- The lookup's word boxes (screen coords, from the tap in the OPEN
          -- book — valid even when the card data comes from a lookup book)
          -- anchor the floating-popup card style. Fresh copies: the source
          -- tables belong to the selection machinery.
          local card_boxes
          if type(boxes) == "table" then
            card_boxes = {}
            for bi = 1, #boxes do
              local b = boxes[bi]
              if type(b) == "table" and b.y and b.h then
                card_boxes[#card_boxes + 1] = { x = b.x, y = b.y, w = b.w, h = b.h }
              end
            end
            if #card_boxes == 0 then card_boxes = nil end
          end
          local card_opts
          if lookup_book or card_boxes then
            card_opts = { document_path = lookup_book, sboxes = card_boxes }
          end
          self_ref:openXrayCard(word, card_opts)
          return
        end
      end
      if not bypass_enabled then
        -- Intercept-only install, no entity hit: the native dictionary
        if dictionary._koassistant_original_onLookupWord then
          return dictionary._koassistant_original_onLookupWord(dict_self, word, is_sane, boxes, highlight, link, dict_close_callback)
        end
        return
      end
      -- Get the bypass action from settings (default: quick_define)
      local action_id = features.dictionary_bypass_action or "quick_define"
      local bypass_action = self_ref.action_service:getAction("highlight", action_id)

      -- Also check special actions if not found
      if not bypass_action then
        local Actions = require("prompts/actions")
        if Actions.special and Actions.special[action_id] then
          bypass_action = Actions.special[action_id]
        end
      end

      if not bypass_action then
        -- Fallback to original if action not found
        logger.warn("KOAssistant: Dictionary bypass action not found: " .. action_id .. ", using original dictionary")
        if dictionary._koassistant_original_onLookupWord then
          return dictionary._koassistant_original_onLookupWord(dict_self, word, is_sane, boxes, highlight, link, dict_close_callback)
        end
        return
      end

      -- Check cache requirements before executing
      if bypass_action.requires_xray_cache then
        local ActionCache = require("koassistant_action_cache")
        -- Chat-viewer lookups carry their own book (may differ from the open
        -- one). Read WITHOUT consuming — the fall-through paths below hand the
        -- flags to the normal dictionary-popup chain, which consumes them.
        local file = dict_self._koassistant_lookup_book
            or (self_ref.ui and self_ref.ui.document and self_ref.ui.document.file)
        if not file or not ActionCache.hasAnyXray(file) then
          logger.dbg("KOAssistant: Dictionary bypass - action requires X-Ray cache, falling through to dictionary")
          if dictionary._koassistant_original_onLookupWord then
            return dictionary._koassistant_original_onLookupWord(dict_self, word, is_sane, boxes, highlight, link, dict_close_callback)
          end
          return
        end
        -- Word-level conditional (#63 round 10): with the X-Ray lookup as the
        -- bypass action, a word NO X-Ray matches falls through to the normal
        -- dictionary instead of a dead-end "no results" message. SUBSTRING
        -- matching again (round 8's exact-only gate is superseded): direct
        -- entity hits are the INTERCEPT's job now, so this config means the
        -- deliberate "search the X-Ray for every word" — fuzzy hits and the
        -- results list are its point. Across main + section X-Rays; costs
        -- one cache parse per tapped word.
        if bypass_action.local_handler == "xray_lookup" then
          -- Live doc informs page context only when it IS the target book
          local doc = self_ref.ui and self_ref.ui.document
          if doc and doc.file ~= file then doc = nil end
          local hits = ActionCache.searchAllXrays(file, word,
            doc, { skip_description = true })
          if #hits == 0 then
            logger.dbg("KOAssistant: Dictionary bypass - no X-Ray entry for word, falling through to dictionary")
            if dictionary._koassistant_original_onLookupWord then
              return dictionary._koassistant_original_onLookupWord(dict_self, word, is_sane, boxes, highlight, link, dict_close_callback)
            end
            return
          end
        end
      end

      -- Check if this is a non-reader lookup (e.g., from ChatGPT viewer or nested dictionary).
      -- Context extraction from the book page would be irrelevant in these cases.
      local non_reader_lookup = dict_self._koassistant_non_reader_lookup
      local lookup_book_override = dict_self._koassistant_lookup_book
      dict_self._koassistant_non_reader_lookup = nil  -- Consume flags
      dict_self._koassistant_lookup_book = nil

      -- IMPORTANT: Extract context BEFORE clearing highlight
      -- The highlight object contains the selection state needed for context extraction.
      -- Once cleared, getSelectedWordContext() will return nil.
      -- Always extract regardless of mode, so compact view toggle can enable context later.
      local context = ""
      local context_mode = require("koassistant_book_settings")
        .resolveDictionaryContext(self_ref.ui and self_ref.ui.doc_settings, features)
      local context_chars = features.dictionary_context_chars or 100
      -- Use "sentence" as extraction mode when setting is "none" (for toggle availability)
      local extraction_mode = (context_mode == "none") and "sentence" or context_mode
      local sc_window = nil
      if not non_reader_lookup and self_ref.ui and self_ref.ui.highlight then
        context = Dialogs.extractSurroundingContext(
          self_ref.ui,
          word,
          extraction_mode,
          context_chars
        )
        -- Pre-extract the surrounding-context window while the selection is alive
        -- (highlight:clear() below kills it; handlePredefinedPrompt trims per mode)
        sc_window = Dialogs.fetchSelectionContextWindow(self_ref.ui, word)
        if context and context ~= "" then
          logger.dbg("KOAssistant BYPASS: Got context (" .. #context .. " chars)")
        else
          logger.dbg("KOAssistant BYPASS: No context available")
        end
      end

      -- BEFORE clearing highlight, capture selection_data for "Save to Note" feature
      local selection_data = nil
      if highlight and highlight.selected_text then
        local st = highlight.selected_text
        selection_data = {
          text = st.text,
          pos0 = st.pos0,
          pos1 = st.pos1,
          sboxes = st.sboxes,
          pboxes = st.pboxes,
          ext = st.ext,
          drawer = st.drawer,
          color = st.color,
        }
      end

      -- NOW clear the selection highlight (after context and selection_data extraction)
      -- KOReader uses highlight:clear() to remove the selection highlight
      if highlight and highlight.clear then
        highlight:clear()
      end
      -- Also call the close callback if provided (for additional cleanup)
      if dict_close_callback then
        dict_close_callback()
      end

      -- Execute the default action directly (context already captured above)
      if bypass_action.local_handler then
        -- Local actions don't need network or dictionary-specific config
        self_ref:updateConfigFromSettings()
        Dialogs.executeDirectAction(self_ref.ui, bypass_action, word, configuration, self_ref,
          lookup_book_override and { document_path = lookup_book_override } or nil)
      else
        NetworkMgr:runWhenConnected(function()
          -- Make sure we're using the latest configuration
          self_ref:updateConfigFromSettings()
          -- Get effective dictionary language (per-book override folded in for the open book)
          local SystemPrompts = require("prompts.system_prompts")
          local dict_language = SystemPrompts.getEffectiveDictionaryLanguage(
            require("koassistant_book_settings").applyLanguageOverride({
              dictionary_language = features.dictionary_language,
              translation_language = features.translation_language,
              translation_use_primary = features.translation_use_primary,
              interaction_languages = features.interaction_languages,
              user_languages = features.user_languages,
              primary_language = features.primary_language,
            }, self_ref.ui and self_ref.ui.doc_settings))

          -- Create a shallow copy of configuration to avoid polluting global state
          local dict_config = {}
          for k, v in pairs(configuration) do
            dict_config[k] = v
          end
          -- Deep copy features to avoid modifying global
          dict_config.features = {}
          if configuration.features then
            for k, v in pairs(configuration.features) do
              dict_config.features[k] = v
            end
          end

          -- Clear context flags to ensure highlight context
          dict_config.features.is_general_context = nil
          dict_config.features.is_book_context = nil
          dict_config.features.is_library_context = nil

          -- Set dictionary-specific values
          if non_reader_lookup then
            -- Non-reader lookup: no context available, disable CTX toggle
            dict_config.features.dictionary_context = ""
            dict_config.features._original_context = ""
            dict_config.features._no_context_available = true
            -- Unified flag consumed by handlePredefinedPrompt: the selection is NOT the
            -- open document, so it must not re-extract the book's context/identity (B3)
            dict_config.features._non_document_selection = true
          else
            -- Only include context in the request if mode is not "none"
            dict_config.features.dictionary_context = (context_mode ~= "none") and context or ""
            -- Always store extracted context so compact view toggle can use it
            dict_config.features._original_context = context
            dict_config.features._original_context_mode = extraction_mode
          end
          dict_config.features.dictionary_language = dict_language
          dict_config.features.dictionary_context_mode = context_mode
          -- Mark the mode authoritative on this copy (see executeDictAction): the
          -- CTX+ toggle's re-run configs inherit it via the features copy
          dict_config.features._dictionary_context_explicit = true
          -- Pre-extracted selection window (set-or-clear; a features copy could
          -- otherwise carry a stale one from an earlier launch)
          dict_config.features._selection_context_window = sc_window
          -- Store selection_data for "Save to Note" feature (word position only)
          dict_config.features.selection_data = selection_data

          -- Skip auto-save for dictionary if setting is enabled (default: true)
          if features.dictionary_disable_auto_save ~= false then
            dict_config.features.storage_key = "__SKIP__"
          end

          -- Apply view mode from action definition (respects user overrides)
          if bypass_action.compact_view then
            dict_config.features.compact_view = true
            dict_config.features.hide_highlighted_text = true
            dict_config.features.minimal_buttons = bypass_action.minimal_buttons ~= false
            dict_config.features.large_stream_dialog = false
          elseif bypass_action.dictionary_view then
            dict_config.features.dictionary_view = true
            dict_config.features.hide_highlighted_text = true
            dict_config.features.minimal_buttons = bypass_action.minimal_buttons ~= false
          end

          -- Check dictionary streaming setting
          if features.dictionary_enable_streaming == false then
            dict_config.features.enable_streaming = false
          end

          -- Vocab builder auto-add in bypass mode:
          -- Only add if both vocab builder is enabled AND the bypass vocab setting allows it
          local vocab_settings = G_reader_settings and G_reader_settings:readSetting("vocabulary_builder") or {}
          if vocab_settings.enabled and features.dictionary_bypass_vocab_add ~= false then
            local book_title = (self_ref.ui.doc_props and self_ref.ui.doc_props.display_title) or _("AI Dictionary lookup")
            local Event = require("ui/event")
            self_ref.ui:handleEvent(Event:new("WordLookedUp", word, book_title, false))
            dict_config.features.vocab_word_auto_added = true
            logger.dbg("KOAssistant: Auto-added word to vocabulary builder (bypass): " .. word)
          end

          -- Execute the action
          Dialogs.executeDirectAction(
            self_ref.ui,
            bypass_action,
            word,
            dict_config,
            self_ref
          )
        end)
      end
    end
    logger.dbg("KOAssistant: Dictionary bypass enabled")
  else
    -- Restore original method
    if dictionary._koassistant_original_onLookupWord then
      dictionary.onLookupWord = dictionary._koassistant_original_onLookupWord
      dictionary._koassistant_original_onLookupWord = nil
      logger.dbg("KOAssistant: Dictionary bypass disabled, restored original dictionary lookup")
    end
  end
end

-- Highlight Bypass: immediately trigger an action when text is selected
function AskGPT:syncHighlightBypass()
  if not self.ui or not self.ui.highlight then
    logger.dbg("KOAssistant: Cannot sync highlight bypass - highlight not available")
    return
  end

  local highlight = self.ui.highlight
  local self_ref = self

  -- Store original if not already stored
  if not highlight._koassistant_original_onShowHighlightMenu then
    highlight._koassistant_original_onShowHighlightMenu = highlight.onShowHighlightMenu
  end

  -- Very-long-press escape (round 10): KOReader's own convention — holding
  -- LONGER at the end of a selection bypasses the default highlight action
  -- and shows the menu (readerhighlight.lua onHoldRelease, long_hold_reached).
  -- That flag is consumed into a local BEFORE onShowHighlightMenu runs, so
  -- stash it per release; the menu wrapper reads-and-clears the stash and
  -- steps aside (bypass AND intercept), handing back the native menu. A
  -- release that never reaches the menu overwrites the stash on the next
  -- one — self-healing, no staleness.
  if not highlight._koassistant_original_onHoldRelease then
    highlight._koassistant_original_onHoldRelease = highlight.onHoldRelease
    highlight.onHoldRelease = function(hl_self, ...)
      hl_self._koassistant_long_final = hl_self.long_hold_reached or nil
      return highlight._koassistant_original_onHoldRelease(hl_self, ...)
    end
  end

  -- Stock KOReader never ARMS that long-hold timer when default_highlight_action
  -- is "ask" ("the menu would come anyway" — readerhighlight.lua
  -- _resetHoldTimer), so under the stock default the escape could never
  -- trigger: no state icon, long_hold_reached never set (device 2026-08-13 —
  -- worked for words, which arm unconditionally, but never for selections).
  -- Our wrapper REPLACES that menu, so supplement the timer in exactly the
  -- branches stock skips, only while our layer is active.
  if not highlight._koassistant_original_resetHoldTimer then
    highlight._koassistant_original_resetHoldTimer = highlight._resetHoldTimer
    highlight._resetHoldTimer = function(hl_self, clear)
      highlight._koassistant_original_resetHoldTimer(hl_self, clear)
      if clear then return end
      local features = self_ref.settings:readSetting("features") or {}
      if not (features.highlight_bypass_enabled
          or self_ref:_xrayInterceptEnabled(self_ref.ui
            and self_ref.ui.document and self_ref.ui.document.file)) then
        return
      end
      if G_reader_settings:readSetting("default_highlight_action", "ask") ~= "ask" then
        return -- stock armed the timer itself
      end
      if hl_self.is_word_selection
          and not G_reader_settings:isTrue("highlight_action_on_single_word") then
        return -- word heading for dict lookup: stock armed this one too
      end
      -- long_hold_reached_action exists: the original call above creates it
      -- unconditionally before deciding whether to schedule
      local GestureDetector = require("device/gesturedetector")
      UIManager:scheduleIn(G_reader_settings:readSetting("highlight_long_hold_threshold_s")
        or GestureDetector.LONG_HOLD_INTERVAL_S, hl_self.long_hold_reached_action)
    end
  end

  -- Replace with our interceptor
  highlight.onShowHighlightMenu = function(hl_self, ...)
    local features = self_ref.settings:readSetting("features", {})

    -- Very-long-press escape: the user asked for the menu — skip the
    -- intercept and the bypass both
    local was_long_final = hl_self._koassistant_long_final
    hl_self._koassistant_long_final = nil
    if was_long_final then
      return highlight._koassistant_original_onShowHighlightMenu(hl_self, ...)
    end

    -- X-Ray intercept (#63 rounds 9-10, opt-out): a selection that IS an
    -- entity's name/alias opens its X-Ray entry ahead of any highlight flow
    -- (bypass action or menu); anything else falls through untouched.
    -- Word-count-independent (maintainer ruling). Round 5: the gate resolves
    -- per call (book > global), after the cheap handle-shape checks.
    if hl_self.selected_text and hl_self.selected_text.text then
      -- Collapse whitespace runs (selections can span lines), trim edge
      -- ASCII punctuation; entity handles are short — skip the parse cost
      -- for long selections outright
      local sel = hl_self.selected_text.text:gsub("%s+", " ")
      sel = sel:match("^%s*(.-)%s*$") or ""
      sel = sel:gsub("^%p+", ""):gsub("%p+$", "")
      if #sel > 2 and #sel <= 120 then
        local ActionCache = require("koassistant_action_cache")
        local i_file = self_ref.ui and self_ref.ui.document and self_ref.ui.document.file
        -- Memoized route index (slice 2): a stat per release instead of the
        -- old full cache parse
        if i_file and self_ref:_xrayInterceptEnabled(i_file)
            and ActionCache.matchAnyXrayExact(i_file, sel,
              { include_ahead = self_ref:_xrayAheadEnabled(i_file),
                position = self_ref:_xrayReaderPosition(i_file) }) then
          logger.dbg("KOAssistant: X-Ray intercept - selection matches entity, opening X-Ray")
          -- Selection geometry anchors the floating-popup card style —
          -- captured as fresh copies BEFORE clear() releases the selection
          local sel_boxes
          local sb = hl_self.selected_text.sboxes
          if type(sb) == "table" then
            sel_boxes = {}
            for bi = 1, #sb do
              local b = sb[bi]
              if type(b) == "table" and b.y and b.h then
                sel_boxes[#sel_boxes + 1] = { x = b.x, y = b.y, w = b.w, h = b.h }
              end
            end
            if #sel_boxes == 0 then sel_boxes = nil end
          end
          hl_self:clear()
          self_ref:openXrayCard(sel, sel_boxes and { sboxes = sel_boxes } or nil)
          return true
        end
      end
    end

    -- Check if bypass is enabled
    if features.highlight_bypass_enabled then
      local action_id = features.highlight_bypass_action or "translate"
      -- Use action_service which handles built-in and custom actions
      local action = self_ref.action_service:getAction("highlight", action_id)
      -- Also check special actions (translate, dictionary)
      if not action then
        local Actions = require("prompts/actions")
        action = Actions.special and Actions.special[action_id]
      end

      if action and hl_self.selected_text and hl_self.selected_text.text then
        -- Check cache requirements before executing
        if action.requires_xray_cache then
          local ActionCache = require("koassistant_action_cache")
          local file = self_ref.ui and self_ref.ui.document and self_ref.ui.document.file
          if not file or not ActionCache.hasAnyXray(file) then
            logger.dbg("KOAssistant: Highlight bypass - action requires X-Ray cache, falling through to menu")
            return highlight._koassistant_original_onShowHighlightMenu(hl_self, ...)
          end
        end
        logger.dbg("KOAssistant: Highlight bypass active, executing action: " .. action_id)
        -- Execute our action
        self_ref:executeHighlightBypassAction(action, hl_self.selected_text.text, hl_self)
        -- Clear selection without showing menu
        hl_self:clear()
        return true
      else
        logger.warn("KOAssistant: Highlight bypass - action not found or no text selected")
      end
    end

    -- Bypass not enabled or action not found - show normal menu
    return highlight._koassistant_original_onShowHighlightMenu(hl_self, ...)
  end

  logger.dbg("KOAssistant: Highlight bypass synced")
end

--- Ambient X-Ray marks (slice 2): install/refresh/remove the paint layer per
--- current settings + book. Safe to call any time; no-ops without a reader.
--- The pre-card exact-hit open: the xray_lookup action through the exact
--- fast path (browser detail, natural back stack). Shared by the card's
--- "Full entry", the full-entry landing preference, and the resolver-miss
--- fallback. opts = { document_path } for lookup-book taps.
function AskGPT:_openXrayEntityDirect(query, opts)
  local xaction = self.action_service
    and self.action_service:getAction("highlight", "xray_lookup")
  if not xaction then return end
  self:updateConfigFromSettings()
  -- Card target (round 19): the card resolved ONE entity — its "full entry"
  -- opens exactly that one (consume-once transient; the lookup falls back to
  -- the normal search when the target went stale)
  if opts and opts.target then
    configuration.features = configuration.features or {}
    configuration.features._xray_lookup_target = opts.target
  end
  Dialogs.executeDirectAction(self.ui, xaction, query, configuration, self,
    opts and opts.document_path and { document_path = opts.document_path } or nil)
end

--- Card landing router (point-4 v1, ref #78/#63): every EXACT entity hit
--- (mark tap, dict-side intercept, highlight-side intercept) lands here.
--- Card first (identification tier, may peek at the newest built
--- checkpoint), full entry one tap away at the position tier; ahead-only
--- entities reveal their full entry behind a confirm while spoiler
--- protection is on. `features.xray_card_landing == false` restores the
--- straight-to-full-entry behavior — except ahead-only entities, which keep
--- the reveal flow (the position-tier lookup cannot show them).
--- Effective Upcoming Entities toggle for a book: book override > global,
--- default ON (BookSettings.resolveXrayMarking .ahead). The three
--- ahead-peek sites read this per call: the dict/highlight intercepts'
--- matchAnyXrayExact include_ahead flag and the card resolver.
function AskGPT:_xrayAheadEnabled(file)
  local features = self.settings:readSetting("features") or {}
  local ds = file and require("koassistant_doc_settings").resolve(file, self.ui) or nil
  return require("koassistant_book_settings").resolveXrayMarking(ds, features).ahead
end

--- Reading position (0..1) for the ahead peek's rung pick (B269): the open
--- book's live progress, else the sidecar's; nil = no peek possible.
function AskGPT:_xrayReaderPosition(file)
  if self.ui and self.ui.document and (not file or self.ui.document.file == file) then
    local ok, prog = pcall(function()
      return require("koassistant_context_extractor"):new(self.ui):getReadingProgress()
    end)
    if ok and type(prog) == "table" and type(prog.decimal) == "number" then
      return prog.decimal
    end
  end
  if file then
    local sidecar = require("koassistant_context_extractor").readSidecarProgress(file)
    if sidecar and type(sidecar.decimal) == "number" then return sidecar.decimal end
  end
  return nil
end

--- Effective selection-intercept toggle for a book (round 5, per book):
--- book override > global, default ON. Both intercept sites read this per
--- call; the install-time gates only decide whether the wrappers exist.
function AskGPT:_xrayInterceptEnabled(file)
  local features = self.settings:readSetting("features") or {}
  local ds = file and require("koassistant_doc_settings").resolve(file, self.ui) or nil
  return require("koassistant_book_settings").resolveXrayMarking(ds, features).intercept
end

--- Effective exact-hit landing for a book (round 5, per book):
--- "footnote" | "popup" | "full" — book override > the global landing+style pair.
function AskGPT:_xrayCardMode(file)
  local features = self.settings:readSetting("features") or {}
  local ds = file and require("koassistant_doc_settings").resolve(file, self.ui) or nil
  return require("koassistant_book_settings").resolveXrayMarking(ds, features).card
end

function AskGPT:openXrayCard(query, opts)
  local features = self.settings:readSetting("features") or {}
  local file = (opts and opts.document_path)
    or (self.ui and self.ui.document and self.ui.document.file)
  local XrayCard = require("koassistant_xray_card")
  local ok, hit = pcall(XrayCard.resolve, file, query,
    { include_ahead = self:_xrayAheadEnabled(file),
      position = self:_xrayReaderPosition(file) })
  if not ok or not hit then
    -- The exact gate said yes but the resolver disagreed (disk moved,
    -- parse hiccup): the old path handles it — incl. its no-result flows
    return self:_openXrayEntityDirect(query, opts)
  end
  local self_ref = self
  local function openFull(h)
    if h.source == "carried" then
      -- Carried stub (S1, ref #90): its full page is the browser's
      -- carried-entity detail — threaded through the lookup the way live
      -- card targets are (consume-once transient, stale target re-searches)
      self_ref:_openXrayEntityDirect(h.query, {
        document_path = opts and opts.document_path or nil,
        target = { carried = true, name = h.name },
      })
      return
    end
    if h.source == "predecessor" then
      -- Earlier book's entry (S2, ref #90): the read-only predecessor view
      -- (provenance, "Open in <title>'s X-Ray", "Carry into this book").
      -- No book_metadata here, so a carry just toasts; the lookup paths land
      Dialogs.showPredecessorEntity{
        ui = self_ref.ui,
        plugin = self_ref,
        config = configuration,
        document_path = (opts and opts.document_path)
          or (self_ref.ui and self_ref.ui.document and self_ref.ui.document.file),
        hit = h,
      }
      return
    end
    if h.source ~= "ahead" then
      -- Live-main hits carry the resolved identity so "full entry" opens the
      -- entity the CARD showed — two entries sharing a handle used to dump
      -- this tap on an unranked search list (round 19). Section hits keep
      -- the plain lookup (their entity lives outside the main artifact).
      self_ref:_openXrayEntityDirect(h.query, {
        document_path = opts and opts.document_path or nil,
        target = h.source == "live"
          and { category_key = h.category_key, name = h.name } or nil,
      })
      return
    end
    -- Ahead-only entity: the full entry crosses the reading position
    local function reveal()
      XrayCard.showFullDetail(h)
    end
    local f2 = self_ref.settings:readSetting("features") or {}
    local ds = self_ref.ui and self_ref.ui.doc_settings
    local protected = ds and require("koassistant_book_settings")
      .resolveSpoilerPosture(ds, f2).protected
    if protected then
      local ConfirmBox = require("ui/widget/confirmbox")
      UIManager:show(ConfirmBox:new{
        text = T(_("This entry comes from the next checkpoint (to %1%), ahead of your reading position, and may contain spoilers.\n\nReveal the full entry?"),
          math.floor((h.ahead_progress or 0) * 100 + 0.5)),
        ok_text = _("Reveal"),
        ok_callback = reveal,
      })
    else
      reveal()
    end
  end
  -- Round 5: landing + style resolve per book (book three-way > global pair).
  -- B269: the card-content dials ride the same resolver.
  local ds_m = file and require("koassistant_doc_settings").resolve(file, self.ui) or nil
  local marking = require("koassistant_book_settings").resolveXrayMarking(ds_m, features)
  local card_mode = marking.card
  if card_mode == "full" then
    -- Full-entry landing (round 16): an AHEAD-ONLY entity still needs the
    -- reveal flow — the direct lookup searches the position tier and would
    -- dead-end on "no results" for a hit the gate just confirmed
    return openFull(hit)
  end
  XrayCard.show(hit, {
    -- Presentation (round 15): footnote panel (default) or floating popup,
    -- anchored at the tapped word when the landing carried geometry
    style = card_mode,
    ui = self.ui,
    sboxes = opts and opts.sboxes or nil,
    on_full = openFull,
    card_length = marking.card_length,
    ahead_card = marking.ahead_card,
  })
end

function AskGPT:syncXrayMarks()
  require("koassistant_xray_marks").sync(self)
  -- d2 tap layer (slice 2 round 2): marked words are LINKS — a plain tap on
  -- a mark opens the entity. ReaderHighlight's tap zone sees every tap
  -- EXCEPT link taps (stock zone comment: links keep priority), so real
  -- links in the text still win; everything else falls through to the
  -- original handler (saved-highlight taps, page turns). Wrapper reads
  -- per call — tapTarget returns nil when marking/tap is off.
  local highlight = self.ui and self.ui.highlight
  if highlight and not highlight._koassistant_original_onTap then
    highlight._koassistant_original_onTap = highlight.onTap
    local self_ref = self
    highlight.onTap = function(hl_self, arg, ges)
      local name, box
      if ges then
        name, box = require("koassistant_xray_marks").tapTarget(self_ref, ges)
      end
      if name then
        logger.dbg("KOAssistant: X-Ray mark tap - opening card for tapped text: " .. name)
        -- The word box anchors the floating-popup card style
        self_ref:openXrayCard(name, box and { sboxes = { box } } or nil)
        return true
      end
      return highlight._koassistant_original_onTap(hl_self, arg, ges)
    end
  end
  -- Search-session flag for the marks scan (round 3): our findAllText
  -- shares crengine's selection state with the search session's hit
  -- highlighting, so the scan stands down for the whole session. The flag
  -- must be set BEFORE the session's initial jump — do_search runs before
  -- UIManager:show(search_dialog), so an isWidgetShown check alone would
  -- miss the first hit. The marks module promotes/clears it from there.
  local search = self.ui and self.ui.search
  if search and not search._koassistant_original_onShowSearchDialog then
    search._koassistant_original_onShowSearchDialog = search.onShowSearchDialog
    local marks_self = self
    search.onShowSearchDialog = function(s_self, ...)
      s_self._koassistant_search_session = true
      local ret = search._koassistant_original_onShowSearchDialog(s_self, ...)
      -- Round 6: marks must RETURN when the session ends, not wait for the
      -- next page turn (closing the search often restores the origin page
      -- with no PageUpdate at all, and the close can race the final scan
      -- while the dialog still counts as shown). Hook THIS session dialog's
      -- teardown — onCloseWidget covers every close path (tap-outside,
      -- buttons, the X-Ray return button's UIManager:close) — clear the
      -- flag and rescan on the next tick.
      local sd = s_self.search_dialog
      if sd and not sd._koassistant_close_wrapped then
        sd._koassistant_close_wrapped = true
        local orig_close = sd.onCloseWidget
        sd.onCloseWidget = function(d_self, ...)
          s_self._koassistant_search_session = nil
          UIManager:nextTick(function()
            marks_self:syncXrayMarks()
          end)
          if orig_close then return orig_close(d_self, ...) end
        end
      end
      return ret
    end
  end
end

--- Slice-2 quick settings (X-Ray popup "Marking & lookup…"): SELF-REBUILDING
--- — every change re-shows this dialog with fresh labels instead of dumping
--- the reader back at the main popup (device 2026-08-14). Consolidation P2
--- (2026-08-16): the four MARKING rows open the canonical two-layer pickers
--- (BookSettings.showXrayMarkingPicker) landed on the book tab — per-field
--- Follow-global rows, Global one tap away; the old tap-cycles are gone. The
--- lookup rows (selection intercept, card) stay global-only tap-cycles.
--- opts.back reopens whatever launched this.
function AskGPT:_showXrayMarkingQuickSettings(opts)
  local self_ref = self
  local features = self.settings:readSetting("features") or {}
  local BookSettings = require("koassistant_book_settings")
  local ds
  if opts and opts.file then
    ds = require("koassistant_doc_settings").resolve(opts.file, self.ui)
  elseif self.ui and self.ui.doc_settings then
    ds = self.ui.doc_settings
  end
  local marking = BookSettings.resolveXrayMarking(ds, features)
  local function scopeTag(book_key)
    if ds and ds:readSetting(book_key) ~= nil then return _("book") end
    return _("global")
  end
  local ButtonDialog = require("ui/widget/buttondialog")
  local dialog
  -- Tap-cycle row (the two global-only lookup settings below)
  local function row(text, change_fn, resync_fn)
    return {{ text = text, callback = function()
      UIManager:close(dialog)
      change_fn()
      self_ref.settings:flush()
      if resync_fn then resync_fn() else self_ref:syncXrayMarks() end
      self_ref:_showXrayMarkingQuickSettings(opts)
    end }}
  end
  -- Marking row: opens the canonical picker for one marking key, book tab
  -- first (this popup is book-scoped chrome, like Book Settings)
  local function pickerRow(text, kind)
    return {{ text = text, callback = function()
      UIManager:close(dialog)
      BookSettings.showXrayMarkingPicker({
        plugin = self_ref, ui = self_ref.ui,
        document_path = opts and opts.file or nil,
        kind = kind, target_override = "book",
        on_close = function() self_ref:_showXrayMarkingQuickSettings(opts) end,
      })
    end }}
  end
  local buttons = {}
  table.insert(buttons, pickerRow(
    T(_("Passive marking: %1 (%2)"),
      marking.enabled and _("On") or _("Off"),
      scopeTag(BookSettings.KEY_XRAY_MARKING)), "enabled"))
  if marking.enabled then
    table.insert(buttons, pickerRow(
      T(_("Density: %1 (%2)"),
        BookSettings.xrayMarkingDensityLabel(marking.density),
        scopeTag(BookSettings.KEY_XRAY_MARKING_DENSITY)), "density"))
    table.insert(buttons, pickerRow(
      T(_("Mark: %1 (%2)"),
        BookSettings.xrayMarkingFamiliesLabel(marking.families),
        scopeTag(BookSettings.KEY_XRAY_MARKING_FAMILIES)), "families"))
    table.insert(buttons, pickerRow(
      T(_("Tap marked words to open: %1 (%2)"),
        marking.tap and _("On") or _("Off"),
        scopeTag(BookSettings.KEY_XRAY_MARKING_TAP)), "tap"))
  end
  -- Upcoming Entities (device round 3, maintainer: same pattern as the other
  -- marking keys) — ahead-checkpoint entities in marking/lookup/cards (dash
  -- marks, identification only). Book override > global via the canonical
  -- picker like its siblings; outside the marking-gated group since lookup
  -- and cards consult it even with passive marking off.
  table.insert(buttons, pickerRow(
    T(_("Upcoming entities: %1 (%2)"),
      marking.ahead and _("On") or _("Off"),
      scopeTag(BookSettings.KEY_XRAY_AHEAD)), "ahead"))
  -- B269: what upcoming-entity cards show (sub-dial of the peek)
  if marking.ahead then
    table.insert(buttons, pickerRow(
      T(_("Upcoming entity cards: %1 (%2)"),
        BookSettings.xrayAheadCardLabel(marking.ahead_card),
        scopeTag(BookSettings.KEY_XRAY_AHEAD_CARD)), "ahead_card"))
  end
  -- The long-press layer (independent of marking): a held selection that
  -- exactly matches an entity opens it, everything else falls through.
  -- Round 5 (maintainer: "yes per book"): canonical two-layer picker like
  -- the marking rows; the gate resolves per call at both intercept sites.
  table.insert(buttons, pickerRow(
    T(_("Matching selections open entries: %1 (%2)"),
      marking.intercept and _("On") or _("Off"),
      scopeTag(BookSettings.KEY_XRAY_INTERCEPT)), "intercept"))
  -- Point-4: the shared landing for every exact hit (mark taps AND matching
  -- selections — hence outside the marking-gated group). Round 5: per book;
  -- one three-way value (footnote panel / floating popup / full entry) over
  -- the global landing+style pair.
  table.insert(buttons, pickerRow(
    T(_("Exact hits open: %1 (%2)"),
      BookSettings.xrayCardModeLabel(marking.card),
      scopeTag(BookSettings.KEY_XRAY_CARD)), "card"))
  -- B269: how much of an installed entry the card shows
  if marking.card ~= "full" then
    table.insert(buttons, pickerRow(
      T(_("Card shows: %1 (%2)"),
        BookSettings.xrayCardLengthLabel(marking.card_length),
        scopeTag(BookSettings.KEY_XRAY_CARD_LENGTH)), "card_length"))
  end
  if ds and marking.has_override then
    table.insert(buttons, row(
      _("Use global marking settings for this book"),
      function()
        ds:delSetting(BookSettings.KEY_XRAY_MARKING)
        ds:delSetting(BookSettings.KEY_XRAY_MARKING_DENSITY)
        ds:delSetting(BookSettings.KEY_XRAY_MARKING_FAMILIES)
        ds:delSetting(BookSettings.KEY_XRAY_MARKING_TAP)
        ds:delSetting(BookSettings.KEY_XRAY_AHEAD)
        ds:delSetting(BookSettings.KEY_XRAY_INTERCEPT)
        ds:delSetting(BookSettings.KEY_XRAY_CARD)
        ds:delSetting(BookSettings.KEY_XRAY_CARD_LENGTH)
        ds:delSetting(BookSettings.KEY_XRAY_AHEAD_CARD)
        if ds.flush then ds:flush() end
      end,
      function()
        -- The cleared intercept/card overrides re-gate the wrappers too
        self_ref:syncXrayMarks()
        self_ref:syncDictionaryBypass()
        self_ref:syncHighlightBypass()
      end))
  end
  if opts and opts.back then
    table.insert(buttons, {{ text = _("Back"), callback = function()
      UIManager:close(dialog)
      opts.back()
    end }})
  end
  dialog = ButtonDialog:new{
    title = _("Marking & lookup"),
    buttons = buttons,
  }
  UIManager:show(dialog)
end

-- Scrub cross-context state from a features table before entering a new context.
-- The module-level `configuration` is SHARED between the FileManager and ReaderUI
-- plugin instances and across entry points: general/library/file-browser entries
-- write context flags plus book identity onto it, and updateConfigFromSettings
-- deliberately preserves those keys (runtime_only_keys). An entry point that skips
-- this scrub inherits another context's flags/identity — wrong context resolution,
-- wrong-book sidecar reads (injection_gating_audit). Callers re-set what their own
-- context actually knows AFTER scrubbing.
function AskGPT:_scrubContextFeatures(features)
  features.is_general_context = nil
  features.is_book_context = nil
  features.is_library_context = nil
  features.book_metadata = nil
  features.books_info = nil
  features.book_context = nil
  features.dictionary_context = nil
  features._group_launch = nil
  -- Selection state is highlight-entry-scoped: every highlight entry re-captures
  -- both AFTER this scrub (menu/quick/dict/bypass). Left stale, a previous
  -- selection's sboxes would anchor the minimal popup to the OLD selection's
  -- position, and an old context window could pass its fingerprint check.
  features.selection_data = nil
  features._selection_context_window = nil
  -- The spoiler session chip is dialog-scoped: freeform Send (re)writes this flag
  -- on the SHARED features table just-in-time, and nothing un-sets it after the
  -- chat ends. resolveReadingScope treats any non-nil value as authoritative, so
  -- left stale a direct-entry smart-retrieval gather would clamp (or un-clamp) its
  -- reading scope from the LAST chat's chip instead of this book's posture
  -- (spoiler_posture_plan B1).
  features._spoiler_free_active = nil
  -- Spoiler-scope consent is request-scoped (one-shot, consumed at the first
  -- protected send); any stray on the shared table dies here
  features._spoiler_scope_consent = nil
  -- Quick-pin touch marks are dialog-scoped (A9 (b) 2026-08-17); stale marks
  -- would exempt a facet from the preset in the NEXT quick chat
  features._session_web_touched = nil
  features._session_tools_touched = nil
end

function AskGPT:executeHighlightBypassAction(action, selected_text, highlight_instance)
  -- Build configuration
  -- IMPORTANT: Create a proper shallow copy with a NEW features object
  local config_copy = {}
  for k, v in pairs(configuration) do
    config_copy[k] = v
  end
  -- Create NEW features table (don't share reference with global configuration)
  config_copy.features = {}
  for k, v in pairs(configuration.features or {}) do
    config_copy.features[k] = v
  end
  config_copy.context = "highlight"
  -- Scrub inherited context flags/identity: getPromptContext reads the is_*_context
  -- flags (config_copy.context alone does NOT decide the context), so a stale
  -- is_general_context from an earlier General Chat would re-context this request
  -- to "general" and skip the entire highlight branch (injection_gating_audit).
  self:_scrubContextFeatures(config_copy.features)

  -- Capture selection geometry + the surrounding-context window while the
  -- selection is still alive (the interceptor clear()s it right after we
  -- return) — same capture as the highlight-menu entries. Without this the
  -- minimal popup had no sboxes to anchor to (bypass launches always fell back
  -- to centered), and the context window relied on the selection surviving
  -- until consumption instead of the entry-point pre-extract every other
  -- highlight entry does.
  local st = highlight_instance and highlight_instance.selected_text
  if st then
    config_copy.features.selection_data = {
      text = st.text,
      pos0 = st.pos0,
      pos1 = st.pos1,
      sboxes = st.sboxes,
      pboxes = st.pboxes,
      ext = st.ext,
      drawer = st.drawer,
      color = st.color,
    }
  end
  config_copy.features._selection_context_window =
    Dialogs.fetchSelectionContextWindow(self.ui, selected_text)

  -- Block actions when declared requirements are unmet
  if self:_checkRequirements(action) then
    return
  end

  -- Execute the action
  Dialogs.executeDirectAction(
    self.ui,
    action,
    selected_text,
    config_copy,
    self
  )
end

-- Bypass tile hold (A7b, maintainer 2026-08-12 "worth a menu"): pick the
-- bypass action without leaving the QS panel flow. Renders the settings
-- submenu's item builder as a ButtonDialog (auto-scrolls when tall), so the
-- pick list — including specials like X-Ray Lookup — stays defined in ONE place.
function AskGPT:showBypassQuickPick(kind, on_close)
  local ButtonDialog = require("ui/widget/buttondialog")
  local items = kind == "dictionary"
    and self:buildDictionaryBypassActionMenu()
    or self:buildHighlightBypassActionMenu()
  local menu
  local function closePicked()
    UIManager:close(menu)
    if on_close then on_close() end
  end
  -- Two buttons per row (maintainer 2026-08-12: long single-column pick lists
  -- waste the dialog; the same note covers the provider/model popups — sweep
  -- recorded in the tracker). Close stays full-width.
  local rows = {}
  local pending
  for _idx, item in ipairs(items) do
    if item.callback then
      local checked = item.checked_func and item.checked_func() or false
      local btn = {
        text = (checked and "● " or "○ ") .. (item.text or ""),
        align = "left",
        callback = function()
          item.callback()
          closePicked()
        end,
      }
      if pending then
        rows[#rows + 1] = { pending, btn }
        pending = nil
      else
        pending = btn
      end
    end
  end
  if pending then rows[#rows + 1] = { pending } end
  rows[#rows + 1] = {{ text = _("Close"), id = "close", callback = closePicked }}
  menu = ButtonDialog:new{
    title = kind == "dictionary"
      and _("Dictionary bypass action") or _("Highlight bypass action"),
    buttons = rows,
    tap_close_callback = function() if on_close then on_close() end end,
  }
  UIManager:show(menu)
end

-- Build menu for selecting highlight bypass action
function AskGPT:buildHighlightBypassActionMenu()
  local self_ref = self
  local menu_items = {}
  local features = self.settings:readSetting("features") or {}

  -- Get all highlight-context actions using action_service (handles built-in + custom)
  local all_actions = self.action_service:getAllHighlightActionsWithMenuState()

  -- Also add special actions (translate, dictionary) if not already included
  local Actions = require("prompts/actions")
  local action_ids = {}
  for _i, item in ipairs(all_actions) do
    action_ids[item.action.id] = true
  end

  if Actions.special then
    if Actions.special.translate and not action_ids["translate"] then
      table.insert(all_actions, { action = Actions.special.translate })
    end
    if Actions.special.dictionary and not action_ids["dictionary"] then
      table.insert(all_actions, { action = Actions.special.dictionary })
    end
  end

  for _i, item in ipairs(all_actions) do
    local action = item.action
    local action_id = action.id
    local action_text = ActionService.getActionDisplayText(action, features)
    table.insert(menu_items, {
      text = action_text,
      checked_func = function()
        local f = self_ref.settings:readSetting("features") or {}
        local current = f.highlight_bypass_action or "translate"
        return current == action_id
      end,
      radio = true,
      callback = function()
        local f = self_ref.settings:readSetting("features") or {}
        f.highlight_bypass_action = action_id
        self_ref.settings:saveSetting("features", f)
        self_ref.settings:flush()
        UIManager:show(Notification:new{
          text = T(_("Bypass action: %1"), action_text),
          timeout = 1.5,
        })
      end,
    })
  end

  return menu_items
end

-- Build menu for selecting dictionary bypass action
function AskGPT:buildDictionaryBypassActionMenu()
  local self_ref = self
  local menu_items = {}
  local features = self.settings:readSetting("features") or {}

  -- Get all highlight-context actions using action_service (handles built-in + custom)
  local all_actions = self.action_service:getAllHighlightActionsWithMenuState()

  -- Also add special actions (translate, dictionary) if not already included
  local Actions = require("prompts/actions")
  local action_ids = {}
  for _i, item in ipairs(all_actions) do
    action_ids[item.action.id] = true
  end

  if Actions.special then
    -- Dictionary should be first for this menu
    if Actions.special.dictionary and not action_ids["dictionary"] then
      table.insert(all_actions, 1, { action = Actions.special.dictionary })
    end
    if Actions.special.translate and not action_ids["translate"] then
      table.insert(all_actions, { action = Actions.special.translate })
    end
  end

  for _i, item in ipairs(all_actions) do
    local action = item.action
    local action_id = action.id
    local action_text = ActionService.getActionDisplayText(action, features)
    table.insert(menu_items, {
      text = action_text,
      checked_func = function()
        local f = self_ref.settings:readSetting("features") or {}
        local current = f.dictionary_bypass_action or "quick_define"
        return current == action_id
      end,
      radio = true,
      callback = function()
        local f = self_ref.settings:readSetting("features") or {}
        f.dictionary_bypass_action = action_id
        self_ref.settings:saveSetting("features", f)
        self_ref.settings:flush()
        UIManager:show(Notification:new{
          text = T(_("Bypass action: %1"), action_text),
          timeout = 1.5,
        })
      end,
    })
  end

  return menu_items
end

-- Execute a quick action directly without showing intermediate dialog
-- @param action: The action to execute
-- @param highlighted_text: The selected text
-- @param context: Optional surrounding context (for dictionary actions)
-- @param selection_data: Optional selection position data (for "Save to Note" feature)
function AskGPT:executeQuickAction(action, highlighted_text, context, selection_data, sc_window)
  -- Scrub stale cross-context state for highlight context (default context)
  configuration.features = configuration.features or {}
  self:_scrubContextFeatures(configuration.features)
  -- Pass surrounding context if provided (for dictionary actions). Set-or-clear:
  -- a stale value from an earlier launch must not attach to this one.
  configuration.features.dictionary_context = (context and context ~= "") and context or nil
  -- Store selection data for "Save to Note" feature
  configuration.features.selection_data = selection_data
  -- Pre-extracted selection window (set-or-clear: a stale window must not survive
  -- this entry; handlePredefinedPrompt consumes it — which local actions never
  -- reach, so don't leave it on the shared config for them. Exception: the
  -- image_gen local handler consumes it itself, as prompt-framing context)
  configuration.features._selection_context_window =
      (not action.local_handler or action.local_handler == "image_gen")
      and sc_window or nil
  -- Block actions when declared requirements are unmet
  if self:_checkRequirements(action) then
    return
  end
  Dialogs.executeDirectAction(self.ui, action, highlighted_text, configuration, self)
end

function AskGPT:restoreDefaultPrompts()
  -- Combined reset: custom actions + edits + all menus
  self:resetCustomActions(true)
  self:resetActionEdits(true)
  self:resetActionMenus(true)
  self:resetQaUtilities()
  self:resetQsItems()
  -- Legacy cleanup
  self.settings:delSetting("disabled_prompts")
  self.settings:flush()

  UIManager:show(Notification:new{
    text = _("All action settings restored to defaults"),
    timeout = 2,
  })
end

function AskGPT:startGeneralChat()
  -- Same logic as onKOAssistantGeneralChat
  if not configuration then
    UIManager:show(InfoMessage:new{
      icon = "notice-warning",
      text = _("Configuration not found. Please set up configuration.lua first.")
    })
    return
  end

  -- Close any existing input dialog to prevent stacking
  -- (e.g., when launched from AI Quick Settings while an action dialog is open)
  if self.current_input_dialog then
    UIManager:close(self.current_input_dialog)
    self.current_input_dialog = nil
  end

  self:ensureInitialized()
  -- Make sure we're using the latest configuration
  self:updateConfigFromSettings()

  -- Set context flag on the original configuration (no copy needed)
  -- This ensures settings changes are immediately visible
  configuration.features = configuration.features or {}
  -- Scrub inherited context state, then mark general
  self:_scrubContextFeatures(configuration.features)
  configuration.features.is_general_context = true

  -- Show dialog with general context
  showChatGPTDialog(self.ui, nil, configuration, nil, self)
end

function AskGPT:showChatHistory(opts)
  -- Load the chat history manager
  local ChatHistoryManager = require("koassistant_chat_history_manager")
  local chat_history_manager = ChatHistoryManager:new()
  
  -- Get the current document path if a document is open. opts.all_books skips
  -- the open-book jump-in (maintainer 2026-08-17: the QS tile is the CROSS-BOOK
  -- surface, like Browse Artifacts/Notebooks; the book-scoped landing stays on
  -- the Quick Actions panel entry and the gesture, which keep the default).
  local document_path = nil
  if not (opts and opts.all_books)
      and self.ui and self.ui.document and self.ui.document.file then
      document_path = self.ui.document.file
  end
  
  -- Show the chat history browser
  local ChatHistoryDialog = require("koassistant_chat_history_dialog")
  ChatHistoryDialog:showChatHistoryBrowser(
      self.ui, 
      document_path,
      chat_history_manager, 
      configuration
  )
end

function AskGPT:checkForUpdates()
  NetworkMgr:runWhenConnected(function()
    local UpdateChecker = require("koassistant_update_checker")
    UpdateChecker.checkForUpdates(false) -- auto = false (manual check with UI feedback)
  end)
end

function AskGPT:showAbout()
  local UpdateChecker = require("koassistant_update_checker")
  local version = UpdateChecker.getCurrentVersion() or _("Unknown")
  UIManager:show(InfoMessage:new{
    text = T(_([[KOAssistant %1

An AI companion for KOReader. Chat about your books, highlights and library, translate and look things up, and build book artifacts (X-Ray, summaries, quizzes, recaps) with per-book settings, spoiler protection, and your choice of AI provider.

Project page, guides and updates:
github.com/zeeyado/koassistant.koplugin

Gestures: assign KOAssistant actions in Settings → Taps and gestures → Gesture manager.]]), version),
  })
end

-- Event handlers for registering buttons with different FileManager views
function AskGPT:onFileManagerReady(filemanager)
  logger.dbg("KOAssistant: onFileManagerReady event received")
  
  -- Register immediately since FileManager should be ready
  self:addFileDialogButtons()
  
  -- Also register with a delay as a fallback
  UIManager:scheduleIn(0.1, function()
    logger.dbg("KOAssistant: Late registration of file dialog buttons (onFileManagerReady)")
    self:addFileDialogButtons()
  end)
end

-- Patch FileManager to add our multi-select button
function AskGPT:patchFileManagerForMultiSelect()
  if not FileManager or not ButtonDialog then
    logger.warn("KOAssistant: Could not load required modules for multi-select patching")
    return
  end
  
  -- Store reference to self for the closure
  local koassistant_plugin = self

  -- Patch ButtonDialog.new to inject our button into multi-select dialogs
  if not ButtonDialog._orig_new_koassistant then
    ButtonDialog._orig_new_koassistant = ButtonDialog.new
    
    ButtonDialog.new = function(self, o)
      -- Check if this is a FileManager multi-select dialog
      if o and o.buttons and o.title and type(o.title) == "string" and 
         (o.title:find("file.*selected") or o.title:find("No files selected")) and
         FileManager.instance and FileManager.instance.selected_files then
        
        local fm = FileManager.instance
        local select_count = util.tableSize(fm.selected_files)
        local actions_enabled = select_count > 0
        
        if actions_enabled then
          -- Create the close callback
          local close_callback = function()
            -- The dialog will be assigned to the variable after construction
            UIManager:scheduleIn(0, function()
              local dialog = UIManager:getTopmostVisibleWidget()
              if dialog then
                UIManager:close(dialog)
              end
              fm:onToggleSelectMode(true)
            end)
          end

          -- Add KOAssistant button
          local koassistant_button = koassistant_plugin:genMultipleKOAssistantButton(
            close_callback,
            not actions_enabled,
            fm.selected_files
          )
          
          if koassistant_button then
            -- Append at the very end
            table.insert(o.buttons, koassistant_button)
            logger.dbg("KOAssistant: Added multi-select button to dialog at end position " .. #o.buttons)
          end
        end
      end

      -- Call original constructor
      return ButtonDialog._orig_new_koassistant(self, o)
    end

    logger.dbg("KOAssistant: Patched ButtonDialog.new for multi-select support")
  end
end

-- Reset feature settings to defaults (preserves API keys, custom actions/behaviors, custom models)
function AskGPT:resetFeatureSettings()
  self:_resetFeatureSettingsInternal()
  UIManager:show(Notification:new{
    text = _("Feature settings reset to defaults"),
    timeout = 2,
  })
end

-- Reset all customizations (preserves API keys and chat history only)
-- Note: This function is kept for backup restore compatibility, but is no longer in the menu
function AskGPT:resetAllCustomizations()
  local features = self.settings:readSetting("features") or {}

  -- Apply defaults, preserving only API keys
  local new_features = SettingsSchema.applyDefaults(features, {
    "features.api_keys",
    "features.api_key_selected",
    "features.openai_codex_oauth",
  })

  self.settings:saveSetting("features", new_features)

  -- Clear all other top-level settings (custom actions, overrides, all menu configs)
  self:resetCustomActions(true)
  self:resetActionEdits(true)
  self:resetActionMenus(true)
  self:resetQaUtilities()
  self:resetQsItems()
  -- Legacy cleanup
  self.settings:delSetting("disabled_prompts")

  self.settings:flush()
  self:updateConfigFromSettings()

  UIManager:show(Notification:new{
    text = _("All customizations reset"),
    timeout = 2,
  })
end

-- Clear all chat history
function AskGPT:clearAllChatHistory()
  local ChatHistoryManager = require("koassistant_chat_history_manager")
  local chat_manager = ChatHistoryManager:new()
  local total_deleted, docs_deleted = chat_manager:deleteAllChats()

  UIManager:show(Notification:new{
    text = T(_("Deleted %1 chat(s) from %2 book(s)"), total_deleted, docs_deleted),
    timeout = 2,
  })
end

-- Reset custom actions only (user-created actions)
function AskGPT:resetCustomActions(silent)
  self.settings:delSetting("custom_actions")
  self.settings:flush()

  if not silent then
    UIManager:show(Notification:new{
      text = _("Custom actions deleted"),
      timeout = 2,
    })
  end
end

-- Reset action edits only (overrides to built-in actions + disabled actions)
function AskGPT:resetActionEdits(silent)
  self.settings:delSetting("builtin_action_overrides")
  self.settings:delSetting("disabled_actions")
  self.settings:flush()

  if not silent then
    UIManager:show(Notification:new{
      text = _("Action edits reset to defaults"),
      timeout = 2,
    })
  end
end

-- Reset action menus only (highlight/dictionary/quick actions menu configs)
function AskGPT:resetActionMenus(silent)
  -- Highlight menu actions
  self.settings:delSetting("highlight_menu_actions")
  self.settings:delSetting("_dismissed_highlight_actions")
  self.settings:delSetting("_dismissed_highlight_menu_actions")
  -- Dictionary popup actions
  self.settings:delSetting("dictionary_popup_actions")
  self.settings:delSetting("_dictionary_popup_actions")
  self.settings:delSetting("_dismissed_dictionary_actions")
  self.settings:delSetting("_dismissed_dictionary_popup_actions")
  -- Quick actions
  self.settings:delSetting("quick_actions_list")
  self.settings:delSetting("_dismissed_quick_actions")
  -- General menu actions
  self.settings:delSetting("general_menu_actions")
  self.settings:delSetting("_dismissed_general_menu_actions")
  -- File browser actions
  self.settings:delSetting("file_browser_actions")
  self.settings:delSetting("_dismissed_file_browser_actions")
  -- Input dialog actions (all contexts — keys derived from ActionService so a
  -- new context can't be missed here; library once was)
  for _i, key in ipairs(ActionService.getInputContextKeys()) do
    self.settings:delSetting(key)
  end
  self.settings:flush()

  if not silent then
    UIManager:show(InfoMessage:new{
      text = _("Action menus reset to defaults."),
    })
  end
end

-- Reset dictionary popup actions only
function AskGPT:resetDictionaryPopupActions(touchmenu_instance)
  self.settings:delSetting("dictionary_popup_actions")
  self.settings:delSetting("_dictionary_popup_actions")
  self.settings:delSetting("_dismissed_dictionary_actions")
  self.settings:delSetting("_dismissed_dictionary_popup_actions")
  self.settings:flush()
  UIManager:show(Notification:new{
    text = _("Dictionary popup actions reset"),
    timeout = 2,
  })
  if touchmenu_instance then touchmenu_instance:updateItems() end
end

-- Reset highlight menu actions only
function AskGPT:resetHighlightMenuActions(touchmenu_instance)
  self.settings:delSetting("highlight_menu_actions")
  self.settings:delSetting("_dismissed_highlight_actions")
  self.settings:delSetting("_dismissed_highlight_menu_actions")
  self.settings:flush()
  UIManager:show(Notification:new{
    text = _("Highlight menu actions reset"),
    timeout = 2,
  })
  if touchmenu_instance then touchmenu_instance:updateItems() end
end

-- Reset file browser actions only
function AskGPT:resetFileBrowserActions(touchmenu_instance)
  self.settings:delSetting("file_browser_actions")
  self.settings:delSetting("_dismissed_file_browser_actions")
  self.settings:flush()
  UIManager:show(Notification:new{
    text = _("File browser actions reset"),
    timeout = 2,
  })
  if touchmenu_instance then touchmenu_instance:updateItems() end
end

-- Reset quick actions only
function AskGPT:resetQuickActions(touchmenu_instance)
  self.settings:delSetting("quick_actions_list")
  self.settings:delSetting("_dismissed_quick_actions")
  self.settings:flush()
  UIManager:show(Notification:new{
    text = _("Quick actions reset"),
    timeout = 2,
  })
  if touchmenu_instance then touchmenu_instance:updateItems() end
end

-- Reset input dialog actions (all contexts — keys derived from ActionService)
function AskGPT:resetInputDialogActions()
  for _i, key in ipairs(ActionService.getInputContextKeys()) do
    self.settings:delSetting(key)
  end
  self.settings:flush()
  UIManager:show(Notification:new{
    text = _("Input dialog actions reset"),
    timeout = 2,
  })
end

-- Reset QA panel utilities order and visibility
function AskGPT:resetQaUtilities()
  self.settings:delSetting("qa_utilities_order")
  local features = self.settings:readSetting("features") or {}
  for _i, u in ipairs(Constants.QUICK_ACTION_UTILITIES) do
    features["qa_show_" .. u.id] = nil
  end
  self.settings:saveSetting("features", features)
  self.settings:flush()
end

-- Reset QS panel items order and visibility
function AskGPT:resetQsItems()
  self.settings:delSetting("qs_items_order")
  local features = self.settings:readSetting("features") or {}
  for _i, id in ipairs(Constants.QS_ITEMS_DEFAULT_ORDER) do
    features["qs_show_" .. id] = nil
  end
  features.qs_show_new_book_chat = nil  -- retired tile (2026-08-17), clear residue
  self.settings:saveSetting("features", features)
  self.settings:flush()
end

-- Reset custom providers and models only
function AskGPT:resetCustomProvidersModels(silent)
  local features = self.settings:readSetting("features") or {}

  -- Clear custom providers, models, and default model selections
  features.custom_providers = nil
  features.custom_models = nil
  features.provider_default_models = nil

  self.settings:saveSetting("features", features)
  self.settings:flush()
  self:updateConfigFromSettings()

  if not silent then
    UIManager:show(Notification:new{
      text = _("Custom providers and models reset"),
      timeout = 2,
    })
  end
end

-- Reset behaviors and domains (custom behaviors created via UI)
function AskGPT:resetBehaviorsDomains()
  local features = self.settings:readSetting("features") or {}
  features.custom_behaviors = nil
  self.settings:saveSetting("features", features)
  self.settings:flush()
  self:updateConfigFromSettings()
end

-- Reset API keys
function AskGPT:resetAPIKeys()
  local features = self.settings:readSetting("features") or {}
  features.api_keys = nil
  features.api_key_selected = nil
  features.openai_codex_oauth = nil
  self.settings:saveSetting("features", features)
  self.settings:flush()
  self:updateConfigFromSettings()
end

-- Internal: Reset feature settings using centralized defaults (no notification)
function AskGPT:_resetFeatureSettingsInternal()
  local features = self.settings:readSetting("features") or {}

  -- Preserve list is registry-derived (Track 33): credentials + assets +
  -- preferences + internal flags — only the plain feature toggles reset to default.
  -- Fixes a latent bug: the old hardcoded list dropped _reasoning_v2_migrated /
  -- _reasoning_hint_shown, silently re-triggering the reasoning-v2 migration (and
  -- its one-time notice) on every reset.
  local new_features = SettingsSchema.applyDefaults(features, StorageRegistry.settingsResetPreserve())

  self.settings:saveSetting("features", new_features)
  self.settings:flush()
  self:updateConfigFromSettings()
end

-- Re-run setup wizard
function AskGPT:rerunSetupWizard()
  self.settings:delSetting("setup_wizard_completed")
  self.settings:flush()
  self:showSetupWizard()
end

-- Setup Wizard v2 dev entry (koassistant_setup_wizard.lua) — INERT for
-- users until the release flip: the only route here is the debug-gated
-- Settings > Advanced row. At release, checkSetupWizard/rerunSetupWizard
-- switch to the new module and this row retires.
-- Settings ▸ X-Ray ▸ "Categories for New X-Rays": the global default every
-- book without its own pick follows (presets v0.21; schema action row).
function AskGPT:showXrayDefaultCategoriesPicker()
  local BookSettings = require("koassistant_book_settings")
  BookSettings.showXrayCategoriesPicker({ target = "global", plugin = self })
end

-- Settings ▸ X-Ray ▸ "Depth of New X-Rays": the global depth rung (depth axis
-- 2026-08-25; the shared two-layer picker opened on its Global tab).
function AskGPT:showXrayDefaultDepthPicker()
  local BookSettings = require("koassistant_book_settings")
  BookSettings.showXrayDepthPicker({ plugin = self, ui = self.ui, target_override = "global" })
end

function AskGPT:showSetupWizardDev()
  require("koassistant_setup_wizard").showDevMenu(self)
end

-- Quick reset: Settings only
function AskGPT:quickResetSettings()
  self:_resetFeatureSettingsInternal()
  UIManager:show(Notification:new{
    text = _("Settings reset to defaults"),
    timeout = 2,
  })
end

-- Quick reset: Actions only (all action-related settings)
function AskGPT:quickResetActions()
  self:resetCustomActions(true)
  self:resetActionEdits(true)
  self:resetActionMenus(true)
  self:resetQaUtilities()
  self:resetQsItems()
  UIManager:show(Notification:new{
    text = _("All action settings reset"),
    timeout = 2,
  })
end

-- Quick reset: Fresh start (everything except API keys and chats)
function AskGPT:quickResetFreshStart()
  local features = self.settings:readSetting("features") or {}
  -- Clean-slate config reset (registry-driven). Preserve only credentials,
  -- languages, and internal migration flags; everything else in the features
  -- table resets — feature toggles, selections, gestures, fonts, AND custom
  -- providers/models/behaviors/domains (no schema default -> dropped). This
  -- folds in the old resetCustomProvidersModels/resetBehaviorsDomains calls and
  -- the manual nil-block, and fixes the reasoning-flag drop (now in `internal`).
  local new_features = SettingsSchema.applyDefaults(features, StorageRegistry.freshStartPreserve())
  self.settings:saveSetting("features", new_features)

  -- Top-level keys (applyDefaults only rebuilds the features table):
  self:resetCustomActions(true)   -- custom_actions / custom_prompts
  self:resetActionEdits(true)     -- builtin_action_overrides, disabled_actions
  self:resetActionMenus(true)     -- highlight/dict/quick/general/file-browser/input menus
  self.settings:delSetting("qa_utilities_order")
  self.settings:delSetting("qs_items_order")
  -- Fresh start: clear wizard flag so onboarding re-runs on next launch
  self.settings:delSetting("setup_wizard_completed")

  self.settings:flush()
  self:updateConfigFromSettings()

  UIManager:show(Notification:new{
    text = _("Fresh start complete - API keys preserved"),
    timeout = 2,
  })
end

-- Privacy preset: Default (recommended balance)
function AskGPT:applyPrivacyPresetDefault(touchmenu_instance)
  local f = self.settings:readSetting("features") or {}
  -- Default: personal content private, basic context shared
  f.enable_highlights_sharing = false
  f.enable_annotations_sharing = false
  f.enable_notebook_sharing = false
  f.enable_basic_stats = true
  f.enable_advanced_stats = false
  f.enable_book_text_extraction = false
  f.enable_library_scanning = false
  self.settings:saveSetting("features", f)
  self.settings:flush()
  self:updateConfigFromSettings()
  if touchmenu_instance then
    touchmenu_instance:updateItems()
  end
  UIManager:show(InfoMessage:new{
    text = _("Default: Personal content private, basic context shared"),
    timeout = 3,
  })
end

-- Privacy preset: Minimal (maximum privacy)
function AskGPT:applyPrivacyPresetMinimal(touchmenu_instance)
  local f = self.settings:readSetting("features") or {}
  -- Disable all extended data sharing
  f.enable_highlights_sharing = false
  f.enable_annotations_sharing = false
  f.enable_notebook_sharing = false
  f.enable_basic_stats = false
  f.enable_advanced_stats = false
  f.enable_book_text_extraction = false
  f.enable_library_scanning = false
  self.settings:saveSetting("features", f)
  self.settings:flush()
  self:updateConfigFromSettings()
  if touchmenu_instance then
    touchmenu_instance:updateItems()
  end
  UIManager:show(InfoMessage:new{
    text = _("Minimal: All extended sharing disabled"),
    timeout = 3,
  })
end

-- Privacy preset: Full (enable all sharing except book text)
function AskGPT:applyPrivacyPresetFull(touchmenu_instance)
  local f = self.settings:readSetting("features") or {}
  -- Enable all data sharing (except book text which has cost implications)
  f.enable_highlights_sharing = true
  f.enable_annotations_sharing = true
  f.enable_notebook_sharing = true
  f.enable_library_scanning = true
  f.enable_basic_stats = true
  f.enable_advanced_stats = true
  -- Note: enable_book_text_extraction not touched - user must enable manually
  self.settings:saveSetting("features", f)
  self.settings:flush()
  self:updateConfigFromSettings()
  if touchmenu_instance then
    touchmenu_instance:updateItems()
  end
  UIManager:show(InfoMessage:new{
    text = _("Full: All data sharing enabled (Text extraction must be enabled separately)"),
    timeout = 3,
  })
end

-- The per-book override pattern, spelled out (schema privacy tip row)
function AskGPT:showPrivacyOverridesTip()
  UIManager:show(InfoMessage:new{
    text = _("Every sharing toggle here can be overridden per book (Book Settings → Privacy). Two patterns: keep a global toggle off and allow it for specific books, or keep it on and deny it for sensitive books. A per-book deny always wins — even over trusted providers."),
  })
end

-- Show trusted providers dialog for privacy settings
function AskGPT:showTrustedProvidersDialog()
  local CheckButton = require("ui/widget/checkbutton")
  local ButtonDialog = require("ui/widget/buttondialog")

  local f = self.settings:readSetting("features") or {}
  local current_trusted = f.trusted_providers or {}

  -- Build list of all available providers (built-in + custom)
  local all_providers = {}

  -- Built-in providers
  local Defaults = require("koassistant_api/defaults")
  for provider_id, _info in pairs(Defaults.ProviderDefaults) do
    table.insert(all_providers, {
      id = provider_id,
      name = self:getProviderDisplayName(provider_id),
      is_custom = false,
    })
  end

  -- Custom providers
  local custom_providers = f.custom_providers or {}
  for _idx, cp in ipairs(custom_providers) do
    table.insert(all_providers, {
      id = cp.id,
      name = cp.name or cp.id,
      is_custom = true,
    })
  end

  -- Sort by name
  table.sort(all_providers, function(a, b)
    return a.name:lower() < b.name:lower()
  end)

  -- Track selection state — use pending state from previous rebuild if available,
  -- otherwise initialize from saved settings.
  -- State stored on self because the settings manager passes touchmenu_instance
  -- as first arg — a function parameter would capture that widget object instead.
  local selected
  if self._pending_trusted_selection then
    selected = self._pending_trusted_selection
    self._pending_trusted_selection = nil
  else
    selected = {}
    for _idx, provider_id in ipairs(current_trusted) do
      selected[provider_id] = true
    end
  end

  -- Build checkbox buttons
  local buttons = {}
  for _idx, provider in ipairs(all_providers) do
    local display_name = provider.name
    if provider.is_custom then
      display_name = display_name .. " " .. _("(custom)")
    end

    table.insert(buttons, {{
      text = (selected[provider.id] and "☑ " or "☐ ") .. display_name,
      align = "left",
      callback = function()
        selected[provider.id] = not selected[provider.id]
        -- Rebuild dialog to show updated state, preserving in-progress selection
        self._pending_trusted_selection = selected
        UIManager:close(self._trusted_providers_dialog)
        self:showTrustedProvidersDialog()
      end,
    }})
  end

  -- Add save/cancel buttons
  table.insert(buttons, {
    {
      text = _("Cancel"),
      callback = function()
        UIManager:close(self._trusted_providers_dialog)
      end,
    },
    {
      text = _("Save"),
      callback = function()
        -- Build new trusted list from selection
        local new_trusted = {}
        for provider_id, is_selected in pairs(selected) do
          if is_selected then
            table.insert(new_trusted, provider_id)
          end
        end
        -- Sort for consistency
        table.sort(new_trusted)

        -- Save
        f.trusted_providers = new_trusted
        self.settings:saveSetting("features", f)
        self.settings:flush()
        self:updateConfigFromSettings()

        UIManager:close(self._trusted_providers_dialog)

        -- Show confirmation
        local msg
        if #new_trusted == 0 then
          msg = _("Trusted Providers: None")
        else
          msg = T(_("Trusted Providers: %1"), table.concat(new_trusted, ", "))
        end
        UIManager:show(Notification:new{
          text = msg,
          timeout = 3,
        })
      end,
    },
  })

  self._trusted_providers_dialog = ButtonDialog:new{
    title = _("Select providers to trust\n\nTrusted providers bypass data sharing controls."),
    buttons = buttons,
  }
  UIManager:show(self._trusted_providers_dialog)
end

-- Returns menu items for library folders submenu
-- Each folder shown with hold-to-remove, plus "Add folder" opens PathChooser
function AskGPT:getLibraryFoldersMenuItems()
  local items = {}
  local self_ref = self

  local f = self.settings:readSetting("features") or {}
  local folders = f.library_scan_folders or {}

  -- Show each configured folder
  for _idx, folder_path in ipairs(folders) do
    local display = folder_path:match("([^/]+)$") or folder_path
    table.insert(items, {
      text = display,
      keep_menu_open = true,
      help_text = folder_path,
      callback = function()
        UIManager:show(InfoMessage:new{
          text = folder_path,
          timeout = 5,
        })
      end,
      hold_callback = function(touchmenu_instance)
        local ConfirmBox = require("ui/widget/confirmbox")
        UIManager:show(ConfirmBox:new{
          text = T(_("Remove this folder from library scanning?\n\n%1"), folder_path),
          ok_callback = function()
            local feat = self_ref.settings:readSetting("features") or {}
            local fldrs = feat.library_scan_folders or {}
            for i = #fldrs, 1, -1 do
              if fldrs[i] == folder_path then
                table.remove(fldrs, i)
                break
              end
            end
            feat.library_scan_folders = fldrs
            self_ref.settings:saveSetting("features", feat)
            self_ref.settings:flush()
            self_ref:updateConfigFromSettings()
            self_ref:refreshTouchMenu(touchmenu_instance, function()
              return self_ref:getLibraryFoldersMenuItems()
            end)
          end,
        })
      end,
    })
  end

  -- Separator before "Add folder" if there are existing folders
  if #items > 0 then
    items[#items].separator = true
  end

  -- "Add folder" item
  table.insert(items, {
    text = _("Add folder"),
    keep_menu_open = true,
    callback = function(touchmenu_instance)
      local PathChooser = require("ui/widget/pathchooser")
      local start_path = G_reader_settings:readSetting("home_dir") or Device.home_dir or DataStorage:getDataDir()
      local path_chooser = PathChooser:new{
        title = _("Select Library Folder"),
        path = start_path,
        select_directory = true,
        select_file = false,
        onConfirm = function(selected_path)
          local feat = self_ref.settings:readSetting("features") or {}
          local fldrs = feat.library_scan_folders or {}
          for _fidx, existing in ipairs(fldrs) do
            if existing == selected_path then
              UIManager:show(InfoMessage:new{
                text = T(_("Folder already added:\n%1"), selected_path),
                timeout = 3,
              })
              return
            end
          end
          table.insert(fldrs, selected_path)
          table.sort(fldrs)
          feat.library_scan_folders = fldrs
          self_ref.settings:saveSetting("features", feat)
          self_ref.settings:flush()
          self_ref:updateConfigFromSettings()
          self_ref:refreshTouchMenu(touchmenu_instance, function()
            return self_ref:getLibraryFoldersMenuItems()
          end)
        end,
      }
      UIManager:show(path_chooser)
    end,
  })

  if #folders == 0 then
    table.insert(items, 1, {
      text = _("No folders configured"),
      enabled_func = function() return false end,
    })
  end

  return items
end

-- Show custom reset dialog with checklist
function AskGPT:showCustomResetDialog()
  self:_showCustomResetOptionsDialog({
    reset_settings = false,
    reset_custom_actions = false,
    reset_action_edits = false,
    reset_action_menus = false,
    reset_providers_models = false,
    reset_behaviors_domains = false,
    reset_api_keys = false,
  })
end

-- Internal: Show custom reset options dialog
function AskGPT:_showCustomResetOptionsDialog(state)
  local ButtonDialog = require("ui/widget/buttondialog")
  local dialog

  local function toggleText(label, is_reset, warning)
    if is_reset then
      return label .. ": " .. _("✓ Reset") .. (warning or "")
    else
      return label .. ": " .. _("✗ Keep")
    end
  end

  local buttons = {
    {{
      text = toggleText(_("Settings"), state.reset_settings),
      callback = function()
        UIManager:close(dialog)
        state.reset_settings = not state.reset_settings
        self:_showCustomResetOptionsDialog(state)
      end,
    }},
    {{
      text = toggleText(_("Custom actions"), state.reset_custom_actions),
      callback = function()
        UIManager:close(dialog)
        state.reset_custom_actions = not state.reset_custom_actions
        self:_showCustomResetOptionsDialog(state)
      end,
    }},
    {{
      text = toggleText(_("Action edits"), state.reset_action_edits),
      callback = function()
        UIManager:close(dialog)
        state.reset_action_edits = not state.reset_action_edits
        self:_showCustomResetOptionsDialog(state)
      end,
    }},
    {{
      text = toggleText(_("Action menus"), state.reset_action_menus),
      callback = function()
        UIManager:close(dialog)
        state.reset_action_menus = not state.reset_action_menus
        self:_showCustomResetOptionsDialog(state)
      end,
    }},
    {{
      text = toggleText(_("Custom providers & models"), state.reset_providers_models),
      callback = function()
        UIManager:close(dialog)
        state.reset_providers_models = not state.reset_providers_models
        self:_showCustomResetOptionsDialog(state)
      end,
    }},
    {{
      text = toggleText(_("Behaviors & domains"), state.reset_behaviors_domains),
      callback = function()
        UIManager:close(dialog)
        state.reset_behaviors_domains = not state.reset_behaviors_domains
        self:_showCustomResetOptionsDialog(state)
      end,
    }},
    {{
      text = toggleText(_("API keys"), state.reset_api_keys, " ⚠"),
      callback = function()
        UIManager:close(dialog)
        state.reset_api_keys = not state.reset_api_keys
        self:_showCustomResetOptionsDialog(state)
      end,
    }},
    {{
      text = "━━━━━━━━━━━━━━━━",
      enabled = false,
    }},
    {{
      text = _("Reset Selected"),
      callback = function()
        UIManager:close(dialog)
        self:_performCustomReset(state)
      end,
    }},
  }

  dialog = ButtonDialog:new{
    title = _("What would you like to reset?"),
    buttons = buttons,
  }
  UIManager:show(dialog)
end

-- Internal: Perform custom reset based on selected options
function AskGPT:_performCustomReset(state)
  local reset_items = {}

  if state.reset_settings then
    self:_resetFeatureSettingsInternal()
    table.insert(reset_items, _("settings"))
  end
  if state.reset_custom_actions then
    self:resetCustomActions(true)
    table.insert(reset_items, _("custom actions"))
  end
  if state.reset_action_edits then
    self:resetActionEdits(true)
    table.insert(reset_items, _("action edits"))
  end
  if state.reset_action_menus then
    self:resetActionMenus(true)
    table.insert(reset_items, _("action menus"))
  end
  if state.reset_providers_models then
    self:resetCustomProvidersModels(true)
    table.insert(reset_items, _("providers/models"))
  end
  if state.reset_behaviors_domains then
    self:resetBehaviorsDomains()
    table.insert(reset_items, _("behaviors/domains"))
  end
  if state.reset_api_keys then
    self:resetAPIKeys()
    table.insert(reset_items, _("API keys"))
  end

  if #reset_items > 0 then
    UIManager:show(Notification:new{
      text = T(_("Reset: %1"), table.concat(reset_items, ", ")),
      timeout = 3,
    })
  else
    UIManager:show(Notification:new{
      text = _("Nothing selected to reset"),
      timeout = 2,
    })
  end
end

-- Validate and sanitize action overrides during restore
function AskGPT:_validateActionOverrides(overrides)
  if not overrides or type(overrides) ~= "table" then
    return {}, {}
  end

  local valid_overrides = {}
  local warnings = {}
  local Actions = require("prompts.actions")

  for action_id, override_config in pairs(overrides) do
    -- Check if the base action still exists
    local base_action = Actions[action_id]
    if base_action then
      -- Action exists, keep the override
      valid_overrides[action_id] = override_config
    else
      -- Action no longer exists, skip and warn
      table.insert(warnings, string.format("Skipped override for missing action: %s", action_id))
      logger.warn("BackupRestore: Skipped override for missing action:", action_id)
    end
  end

  return valid_overrides, warnings
end

-- Validate all data indexes: prune stale entries for moved/deleted books
function AskGPT:validateAllIndexes()
  local InfoMessage = require("ui/widget/infomessage")

  -- Validate chat index (also checks count mismatches via existing function)
  local ChatHistoryManager = require("koassistant_chat_history_manager")
  local chat_manager = ChatHistoryManager:new{}
  chat_manager:validateChatIndex()

  -- Prune stale entries from all indexes (shared with the index rebuilder)
  local IndexRebuilder = require("koassistant_index_rebuilder")
  local total_pruned = IndexRebuilder.pruneAllIndexes()

  if total_pruned > 0 then
    UIManager:show(InfoMessage:new{
      text = T(_("Validation complete. Removed %1 stale entries."), total_pruned),
    })
  else
    UIManager:show(InfoMessage:new{
      text = _("All indexes are valid. No issues found."),
      timeout = 3,
    })
  end
end

-- Rebuild all data indexes (issue #92): merge-discover books from reading
-- history, central sidecar locations, and user-designated scan folders, heal
-- their index entries, then prune stale ones. Never wipes an index.
-- @param opts table|nil { quiet = true } for the throttled startup auto-run
function AskGPT:rebuildAllIndexes(opts)
  local IndexRebuilder = require("koassistant_index_rebuilder")
  local features = self.settings:readSetting("features") or {}

  if opts and opts.quiet then
    local ok, err = pcall(IndexRebuilder.run, self.ui, features)
    if not ok then
      logger.warn("KOAssistant: startup index rebuild failed:", err)
    end
    return
  end

  local info = InfoMessage:new{ text = _("Rebuilding data indexes…") }
  UIManager:show(info)
  UIManager:forceRePaint()
  UIManager:scheduleIn(0.1, function()
    local ok, report = pcall(IndexRebuilder.run, self.ui, features)
    UIManager:close(info)
    if not ok then
      logger.warn("KOAssistant: index rebuild failed:", report)
      UIManager:show(InfoMessage:new{
        text = _("Index rebuild failed. Check the log for details."),
      })
      return
    end
    local checked = report.candidates.a + report.candidates.b + report.candidates.c
    local msg_lines = {
      _("Index rebuild complete."),
      T(_("Checked %1 books: %2 with KOAssistant data."), checked, report.with_data),
      T(_("Indexed books: artifacts %1, chats %2, notebooks %3, pinned %4."),
        report.totals["koassistant_artifact_index"],
        report.totals["koassistant_chat_index"],
        report.totals["koassistant_notebook_index"],
        report.totals["koassistant_pinned_index"]),
      T(_("Removed %1 stale entries."), report.pruned),
    }
    if report.unmapped_sidecars > 0 then
      table.insert(msg_lines,
        T(_("%1 synced sidecars couldn't be matched to local books."), report.unmapped_sidecars))
    end
    UIManager:show(InfoMessage:new{ text = table.concat(msg_lines, "\n") })
  end)
end

-- Menu items for the index scan folders manager (issue #92). Deliberately
-- separate from library_scan_folders: that one belongs to the privacy-gated
-- library feature (data goes to a provider); this scan is purely local.
function AskGPT:getIndexScanFoldersMenuItems()
  local items = {}
  local self_ref = self

  local f = self.settings:readSetting("features") or {}
  local folders = f.index_scan_folders or {}

  -- Show each configured folder
  for _idx, folder_path in ipairs(folders) do
    local display = folder_path:match("([^/]+)$") or folder_path
    table.insert(items, {
      text = display,
      keep_menu_open = true,
      help_text = folder_path,
      callback = function()
        UIManager:show(InfoMessage:new{
          text = folder_path,
          timeout = 5,
        })
      end,
      hold_callback = function(touchmenu_instance)
        local ConfirmBox = require("ui/widget/confirmbox")
        UIManager:show(ConfirmBox:new{
          text = T(_("Remove this folder from index scanning?\n\n%1"), folder_path),
          ok_callback = function()
            local feat = self_ref.settings:readSetting("features") or {}
            local fldrs = feat.index_scan_folders or {}
            for i = #fldrs, 1, -1 do
              if fldrs[i] == folder_path then
                table.remove(fldrs, i)
                break
              end
            end
            feat.index_scan_folders = fldrs
            self_ref.settings:saveSetting("features", feat)
            self_ref.settings:flush()
            self_ref:updateConfigFromSettings()
            self_ref:refreshTouchMenu(touchmenu_instance, function()
              return self_ref:getIndexScanFoldersMenuItems()
            end)
          end,
        })
      end,
    })
  end

  -- Separator before "Add folder" if there are existing folders
  if #items > 0 then
    items[#items].separator = true
  end

  -- "Add folder" item
  table.insert(items, {
    text = _("Add folder"),
    keep_menu_open = true,
    callback = function(touchmenu_instance)
      local PathChooser = require("ui/widget/pathchooser")
      local start_path = G_reader_settings:readSetting("home_dir") or Device.home_dir or DataStorage:getDataDir()
      local path_chooser = PathChooser:new{
        title = _("Select Folder to Scan"),
        path = start_path,
        select_directory = true,
        select_file = false,
        onConfirm = function(selected_path)
          local feat = self_ref.settings:readSetting("features") or {}
          local fldrs = feat.index_scan_folders or {}
          for _fidx, existing in ipairs(fldrs) do
            if existing == selected_path then
              UIManager:show(InfoMessage:new{
                text = T(_("Folder already added:\n%1"), selected_path),
                timeout = 3,
              })
              return
            end
          end
          table.insert(fldrs, selected_path)
          table.sort(fldrs)
          feat.index_scan_folders = fldrs
          self_ref.settings:saveSetting("features", feat)
          self_ref.settings:flush()
          self_ref:updateConfigFromSettings()
          self_ref:refreshTouchMenu(touchmenu_instance, function()
            return self_ref:getIndexScanFoldersMenuItems()
          end)
        end,
      }
      UIManager:show(path_chooser)
    end,
  })

  if #folders == 0 then
    table.insert(items, 1, {
      text = _("No folders configured"),
      enabled_func = function() return false end,
    })
  end

  return items
end

-- Show create backup dialog
function AskGPT:showCreateBackupDialog()
  local BackupManager = require("koassistant_backup_manager")
  local backup_manager = BackupManager:new()

  -- Go straight to options dialog with default states
  self:_showBackupOptionsDialog(backup_manager, "", {
    include_settings = true,
    include_api_keys = false,
    include_configs = true,
    include_content = true,
    include_chats = false,
  })
end

-- Show backup options dialog (internal helper)
function AskGPT:_showBackupOptionsDialog(backup_manager, notes, state)
  -- Use provided state or defaults
  local include_settings = state.include_settings
  local include_api_keys = state.include_api_keys
  local include_configs = state.include_configs
  local include_content = state.include_content
  local include_chats = state.include_chats

  -- Use ButtonDialog for interactive checkbox-like behavior
  local ButtonDialog = require("ui/widget/buttondialog")
  local dialog
  local buttons = {
    {
      {
        text = _("Core Settings: ✓ Included"),
        enabled = false,
      },
    },
    {
      {
        text = include_api_keys and _("API Keys: ✓ Include (⚠ Sensitive)") or _("API Keys: ✗ Exclude"),
        callback = function()
          UIManager:close(dialog)
          self:_showBackupOptionsDialog(backup_manager, notes, {
            include_settings = include_settings,
            include_api_keys = not include_api_keys,
            include_configs = include_configs,
            include_content = include_content,
            include_chats = include_chats,
          })
        end,
      },
    },
    {
      {
        text = include_configs and _("Config Files: ✓ Include") or _("Config Files: ✗ Exclude"),
        callback = function()
          UIManager:close(dialog)
          self:_showBackupOptionsDialog(backup_manager, notes, {
            include_settings = include_settings,
            include_api_keys = include_api_keys,
            include_configs = not include_configs,
            include_content = include_content,
            include_chats = include_chats,
          })
        end,
      },
    },
    {
      {
        text = include_content and _("Domains & Behaviors: ✓ Include") or _("Domains & Behaviors: ✗ Exclude"),
        callback = function()
          UIManager:close(dialog)
          self:_showBackupOptionsDialog(backup_manager, notes, {
            include_settings = include_settings,
            include_api_keys = include_api_keys,
            include_configs = include_configs,
            include_content = not include_content,
            include_chats = include_chats,
          })
        end,
      },
    },
    {
      {
        text = include_chats and _("Chat History: ✓ Include") or _("Chat History: ✗ Exclude"),
        callback = function()
          UIManager:close(dialog)
          self:_showBackupOptionsDialog(backup_manager, notes, {
            include_settings = include_settings,
            include_api_keys = include_api_keys,
            include_configs = include_configs,
            include_content = include_content,
            include_chats = not include_chats,
          })
        end,
      },
    },
    {
      {
        text = _("━━━━━━━━━━━━━━━━"),
        enabled = false,
      },
    },
    {
      {
        text = _("Create Backup"),
        callback = function()
          UIManager:close(dialog)

          local options = {
            include_settings = include_settings,
            include_api_keys = include_api_keys,
            include_configs = include_configs,
            include_content = include_content,
            include_chats = include_chats,
            notes = notes,
          }

          self:_performBackup(backup_manager, options)
        end,
      },
    },
  }

  dialog = ButtonDialog:new{
    title = _("What to include in backup:"),
    buttons = buttons,
  }
  UIManager:show(dialog)
end

-- Perform backup (internal helper)
function AskGPT:_performBackup(backup_manager, options)
  local InfoMessage = require("ui/widget/infomessage")

  -- Show progress message
  local progress_msg = InfoMessage:new{
    text = _("Creating backup...\n\nThis may take a moment."),
  }
  UIManager:show(progress_msg)
  UIManager:forceRePaint()

  -- Perform backup
  local result = backup_manager:createBackup(options)

  UIManager:close(progress_msg)

  if result.success then
    -- Show success message
    local success_text = T(_("Backup created successfully!\n\nLocation: %1\n\nSize: %2"),
      result.backup_name,
      backup_manager:_formatSize(result.size))

    -- Add what was included
    local included = {}
    if options.include_settings then
      table.insert(included, _("Settings"))
    end
    if options.include_api_keys then
      table.insert(included, _("API Keys"))
    end
    if options.include_configs then
      table.insert(included, _("Config Files"))
    end
    if options.include_content then
      -- Show count of domains and behaviors
      local content_parts = {}
      if result.counts.domains and result.counts.domains > 0 then
        table.insert(content_parts, T(_("%1 domains"), result.counts.domains))
      else
        table.insert(content_parts, _("0 domains"))
      end
      if result.counts.behaviors and result.counts.behaviors > 0 then
        table.insert(content_parts, T(_("%1 behaviors"), result.counts.behaviors))
      else
        table.insert(content_parts, _("0 behaviors"))
      end
      table.insert(included, table.concat(content_parts, ", "))
    end
    if options.include_chats then
      if result.counts.chats and result.counts.chats > 0 then
        table.insert(included, T(_("%1 chats"), result.counts.chats))
      else
        table.insert(included, _("0 chats"))
      end
    end

    if #included > 0 then
      success_text = success_text .. "\n\n" .. _("Included:") .. "\n• " .. table.concat(included, "\n• ")
    end

    UIManager:show(InfoMessage:new{
      text = success_text,
      timeout = 10,
    })
  else
    -- Show error message
    UIManager:show(InfoMessage:new{
      text = T(_("Backup failed:\n\n%1"), result.error or _("Unknown error")),
      timeout = 5,
    })
  end
end

-- Show restore backup dialog
function AskGPT:showRestoreBackupDialog()
  local BackupManager = require("koassistant_backup_manager")
  local backup_manager = BackupManager:new()

  -- List available backups
  local backups = backup_manager:listBackups()

  if #backups == 0 then
    local InfoMessage = require("ui/widget/infomessage")
    UIManager:show(InfoMessage:new{
      text = _("No backups found.\n\nCreate a backup first using:\nSettings → Backup & Reset → Create Backup"),
      timeout = 5,
    })
    return
  end

  -- Show backup selection dialog
  local ButtonDialog = require("ui/widget/buttondialog")
  local dialog
  local buttons = {}

  for _idx, backup in ipairs(backups) do
    local backup_info = backup.name
    if backup.manifest then
      backup_info = backup_info .. "\n" .. backup.manifest.created_date
    end
    backup_info = backup_info .. "\n" .. backup_manager:_formatSize(backup.size)

    if backup.is_restore_point then
      local enable_emoji = self.configuration.features.enable_emoji_icons == true
      backup_info = Constants.getEmojiText("🔄", backup_info, enable_emoji) .. " (" .. _("Restore Point") .. ")"
    end

    table.insert(buttons, {
      {
        text = backup_info,
        callback = function()
          UIManager:close(dialog)
          self:_showRestorePreviewDialog(backup_manager, backup)
        end,
      },
    })
  end

  -- Add separator and cancel
  table.insert(buttons, {
    {
      text = _("━━━━━━━━━━━━━━━━"),
      enabled = false,
    },
  })

  dialog = ButtonDialog:new{
    title = T(_("Select backup to restore\n\nTotal: %1 backup(s)"), #backups),
    buttons = buttons,
  }
  UIManager:show(dialog)
end

-- Show restore preview dialog (internal helper)
function AskGPT:_showRestorePreviewDialog(backup_manager, backup)
  local InfoMessage = require("ui/widget/infomessage")

  -- Validate backup
  local validation = backup_manager:validateBackup(backup.path)

  if not validation.valid then
    UIManager:show(InfoMessage:new{
      text = T(_("Invalid backup:\n\n%1"), table.concat(validation.errors, "\n")),
      timeout = 5,
    })
    return
  end

  local manifest = validation.manifest

  -- Build preview text
  local preview = T(_("Backup: %1\n\nCreated: %2\nPlugin version: %3\n\nContents:"),
    backup.name,
    manifest.created_date or "Unknown",
    manifest.plugin_version or "Unknown")

  local contents = {}
  if manifest.contents.settings then table.insert(contents, "• " .. _("Settings")) end
  if manifest.contents.api_keys then
    table.insert(contents, "• " .. _("API Keys"))
  else
    table.insert(contents, "• ⚠ " .. _("No API keys"))
  end
  if manifest.contents.config_files then table.insert(contents, "• " .. _("Config Files")) end
  -- Show domains and behaviors together
  if manifest.contents.domains or manifest.contents.behaviors then
    local content_parts = {}
    if manifest.counts and manifest.counts.domains then
      table.insert(content_parts, T(_("%1 domains"), manifest.counts.domains))
    else
      table.insert(content_parts, _("domains"))
    end
    if manifest.counts and manifest.counts.behaviors then
      table.insert(content_parts, T(_("%1 behaviors"), manifest.counts.behaviors))
    else
      table.insert(content_parts, _("behaviors"))
    end
    table.insert(contents, "• " .. table.concat(content_parts, ", "))
  end
  if manifest.contents.chats then
    if manifest.counts and manifest.counts.chats then
      table.insert(contents, "• " .. T(_("%1 chats"), manifest.counts.chats))
    else
      table.insert(contents, "• " .. _("Chat history"))
    end
  end

  if #contents > 0 then
    preview = preview .. "\n" .. table.concat(contents, "\n")
  end

  -- Add warnings
  if #validation.warnings > 0 then
    preview = preview .. "\n\n⚠ " .. _("Warnings:") .. "\n• " .. table.concat(validation.warnings, "\n• ")
  end

  -- Show preview with restore button
  local ButtonDialog = require("ui/widget/buttondialog")
  local dialog
  dialog = ButtonDialog:new{
    title = preview,
    buttons = {
      {
        {
          text = _("Cancel"),
          callback = function()
            UIManager:close(dialog)
          end,
        },
        {
          text = _("Restore →"),
          callback = function()
            UIManager:close(dialog)
            self:_showRestoreOptionsDialog(backup_manager, backup, manifest)
          end,
        },
      },
    },
  }
  UIManager:show(dialog)
end

-- Show restore options dialog (internal helper)
function AskGPT:_showRestoreOptionsDialog(backup_manager, backup, manifest, state)
  -- Use provided state or defaults from manifest
  local restore_settings, restore_api_keys, restore_configs, restore_content, restore_chats, merge_mode
  if state then
    restore_settings = state.restore_settings
    restore_api_keys = state.restore_api_keys
    restore_configs = state.restore_configs
    restore_content = state.restore_content
    restore_chats = state.restore_chats
    merge_mode = state.merge_mode
  else
    restore_settings = manifest.contents.settings or false
    restore_api_keys = manifest.contents.api_keys or false
    restore_configs = manifest.contents.config_files or false
    restore_content = (manifest.contents.domains or manifest.contents.behaviors) or false
    restore_chats = manifest.contents.chats or false
    merge_mode = false
  end

  local ButtonDialog = require("ui/widget/buttondialog")
  local dialog
  local buttons = {
    {
      {
        text = restore_settings and _("Settings: ✓ Restore") or _("Settings: ✗ Skip"),
        enabled = manifest.contents.settings,
        callback = function()
          UIManager:close(dialog)
          self:_showRestoreOptionsDialog(backup_manager, backup, manifest, {
            restore_settings = not restore_settings,
            restore_api_keys = restore_api_keys,
            restore_configs = restore_configs,
            restore_content = restore_content,
            restore_chats = restore_chats,
            merge_mode = merge_mode,
          })
        end,
      },
    },
    {
      {
        text = restore_api_keys and _("API Keys: ✓ Restore") or _("API Keys: ✗ Skip"),
        enabled = manifest.contents.api_keys,
        callback = function()
          UIManager:close(dialog)
          self:_showRestoreOptionsDialog(backup_manager, backup, manifest, {
            restore_settings = restore_settings,
            restore_api_keys = not restore_api_keys,
            restore_configs = restore_configs,
            restore_content = restore_content,
            restore_chats = restore_chats,
            merge_mode = merge_mode,
          })
        end,
      },
    },
    {
      {
        text = restore_configs and _("Config Files: ✓ Restore") or _("Config Files: ✗ Skip"),
        enabled = manifest.contents.config_files,
        callback = function()
          UIManager:close(dialog)
          self:_showRestoreOptionsDialog(backup_manager, backup, manifest, {
            restore_settings = restore_settings,
            restore_api_keys = restore_api_keys,
            restore_configs = not restore_configs,
            restore_content = restore_content,
            restore_chats = restore_chats,
            merge_mode = merge_mode,
          })
        end,
      },
    },
    {
      {
        text = restore_content and _("Domains & Behaviors: ✓ Restore") or _("Domains & Behaviors: ✗ Skip"),
        enabled = (manifest.contents.domains or manifest.contents.behaviors),
        callback = function()
          UIManager:close(dialog)
          self:_showRestoreOptionsDialog(backup_manager, backup, manifest, {
            restore_settings = restore_settings,
            restore_api_keys = restore_api_keys,
            restore_configs = restore_configs,
            restore_content = not restore_content,
            restore_chats = restore_chats,
            merge_mode = merge_mode,
          })
        end,
      },
    },
    {
      {
        text = restore_chats and _("Chat History: ✓ Restore") or _("Chat History: ✗ Skip"),
        enabled = manifest.contents.chats,
        callback = function()
          UIManager:close(dialog)
          self:_showRestoreOptionsDialog(backup_manager, backup, manifest, {
            restore_settings = restore_settings,
            restore_api_keys = restore_api_keys,
            restore_configs = restore_configs,
            restore_content = restore_content,
            restore_chats = not restore_chats,
            merge_mode = merge_mode,
          })
        end,
      },
    },
    {
      {
        text = _("━━━━━━━━━━━━━━━━"),
        enabled = false,
      },
    },
    {
      {
        text = merge_mode and _("Mode: Merge with existing") or _("Mode: Replace existing"),
        callback = function()
          UIManager:close(dialog)
          self:_showRestoreOptionsDialog(backup_manager, backup, manifest, {
            restore_settings = restore_settings,
            restore_api_keys = restore_api_keys,
            restore_configs = restore_configs,
            restore_content = restore_content,
            restore_chats = restore_chats,
            merge_mode = not merge_mode,
          })
        end,
      },
    },
    {
      {
        text = _("━━━━━━━━━━━━━━━━"),
        enabled = false,
      },
    },
    {
      {
        text = _("Restore Now"),
        callback = function()
          UIManager:close(dialog)

          local options = {
            restore_settings = restore_settings,
            restore_api_keys = restore_api_keys,
            restore_configs = restore_configs,
            restore_content = restore_content,
            restore_chats = restore_chats,
            merge_mode = merge_mode,
          }

          self:_performRestore(backup_manager, backup, options)
        end,
      },
    },
  }

  dialog = ButtonDialog:new{
    title = _("What to restore:"),
    buttons = buttons,
  }
  UIManager:show(dialog)
end

-- Perform restore (internal helper)
function AskGPT:_performRestore(backup_manager, backup, options)
  local InfoMessage = require("ui/widget/infomessage")
  local ConfirmBox = require("ui/widget/confirmbox")

  -- Show confirmation
  local confirm = ConfirmBox:new{
    text = _("Restore from backup?\n\n⚠ A restore point will be created automatically.\n\n⚠ KOReader should be restarted after restore for changes to take full effect."),
    ok_text = _("Restore"),
    ok_callback = function()
      -- Show progress
      local progress_msg = InfoMessage:new{
        text = _("Restoring backup...\n\nThis may take a moment."),
      }
      UIManager:show(progress_msg)
      UIManager:forceRePaint()

      -- Perform restore
      local result = backup_manager:restoreBackup(backup.path, options)

      UIManager:close(progress_msg)

      if result.success then
        -- Show success with restart option
        local ButtonDialog = require("ui/widget/buttondialog")
        local success_text = _("Restore completed successfully!\n\nIt's recommended to restart KOReader for all changes to take effect.")

        if #result.warnings > 0 then
          success_text = success_text .. "\n\n⚠ " .. _("Warnings:") .. "\n• " .. table.concat(result.warnings, "\n• ")
        end

        local dialog
        dialog = ButtonDialog:new{
          title = success_text,
          buttons = {
            {
              {
                text = _("OK"),
                callback = function()
                  UIManager:close(dialog)
                end,
              },
              {
                text = _("Restart Now"),
                callback = function()
                  UIManager:close(dialog)
                  -- Trigger restart
                  UIManager:restartKOReader()
                end,
              },
            },
          },
        }
        UIManager:show(dialog)
      else
        -- Show error
        UIManager:show(InfoMessage:new{
          text = T(_("Restore failed:\n\n%1"), result.error or _("Unknown error")),
          timeout = 5,
        })
      end
    end,
  }
  UIManager:show(confirm)
end

-- Show backup list dialog
function AskGPT:showBackupListDialog()
  local BackupManager = require("koassistant_backup_manager")
  local backup_manager = BackupManager:new()

  -- Clean up old restore points first
  backup_manager:cleanupOldRestorePoints()

  -- List available backups
  local backups = backup_manager:listBackups()

  if #backups == 0 then
    local InfoMessage = require("ui/widget/infomessage")
    UIManager:show(InfoMessage:new{
      text = _("No backups found."),
      timeout = 3,
    })
    return
  end

  -- Calculate total size
  local total_size = 0
  for _idx, backup in ipairs(backups) do
    total_size = total_size + backup.size
  end

  -- Show backup list
  local ButtonDialog = require("ui/widget/buttondialog")
  local dialog
  local buttons = {}

  for _idx, backup in ipairs(backups) do
    local backup_info = backup.name
    if backup.manifest then
      backup_info = backup_info .. "\n" .. backup.manifest.created_date
    end
    backup_info = backup_info .. " • " .. backup_manager:_formatSize(backup.size)

    if backup.is_restore_point then
      local enable_emoji = self.configuration.features.enable_emoji_icons == true
      backup_info = Constants.getEmojiText("🔄", backup_info, enable_emoji)
    end

    table.insert(buttons, {
      {
        text = backup_info,
        callback = function()
          UIManager:close(dialog)
          self:_showBackupActionsDialog(backup_manager, backup)
        end,
      },
    })
  end

  -- Add separator and total
  table.insert(buttons, {
    {
      text = "━━━━━━━━━━━━━━━━",
      enabled = false,
    },
  })

  dialog = ButtonDialog:new{
    title = T(_("Backups (%1)\n\nTotal size: %2"), #backups, backup_manager:_formatSize(total_size)),
    buttons = buttons,
  }
  UIManager:show(dialog)
end

-- Show backup actions dialog (internal helper)
function AskGPT:_showBackupActionsDialog(backup_manager, backup)
  local ButtonDialog = require("ui/widget/buttondialog")

  local dialog
  dialog = ButtonDialog:new{
    title = backup.name,
    buttons = {
      {
        {
          text = _("Info"),
          callback = function()
            UIManager:close(dialog)

            -- Show backup info
            local validation = backup_manager:validateBackup(backup.path)
            if validation.valid then
              self:_showRestorePreviewDialog(backup_manager, backup)
            else
              local InfoMessage = require("ui/widget/infomessage")
              UIManager:show(InfoMessage:new{
                text = T(_("Invalid backup:\n\n%1"), table.concat(validation.errors, "\n")),
                timeout = 5,
              })
            end
          end,
        },
      },
      {
        {
          text = _("Restore"),
          callback = function()
            UIManager:close(dialog)
            self:_showRestorePreviewDialog(backup_manager, backup)
          end,
        },
      },
      {
        {
          text = _("Delete"),
          callback = function()
            UIManager:close(dialog)

            -- Confirm deletion
            local ConfirmBox = require("ui/widget/confirmbox")
            local confirm = ConfirmBox:new{
              text = T(_("Delete backup?\n\n%1\n\nThis cannot be undone."), backup.name),
              ok_text = _("Delete"),
              ok_callback = function()
                local result = backup_manager:deleteBackup(backup.path)

                if result.success then
                  local Notification = require("ui/widget/notification")
                  UIManager:show(Notification:new{
                    text = _("Backup deleted"),
                    timeout = 2,
                  })

                  -- Refresh backup list
                  self:showBackupListDialog()
                else
                  local InfoMessage = require("ui/widget/infomessage")
                  UIManager:show(InfoMessage:new{
                    text = T(_("Failed to delete backup:\n\n%1"), result.error or _("Unknown error")),
                    timeout = 3,
                  })
                end
              end,
            }
            UIManager:show(confirm)
          end,
        },
      },
    },
  }
  UIManager:show(dialog)
end

--[[============================================================================
    CHAT HISTORY MIGRATION (V1 -> V2)
    ============================================================================

    These methods handle the one-time migration from hash-based chat storage
    to DocSettings-based storage. This fixes the critical bug where chat history
    was lost when files were moved.

    Migration process:
    1. Check storage version on plugin init
    2. Show migration dialog if version < 2
    3. Scan old koassistant_chats/ directory
    4. Group chats by document_path (stored inside each chat)
    5. Save to each document's doc_settings or general chat file
    6. Backup old directory to koassistant_chats.backup/
    7. Mark migration complete (version = 2)
--]]

--- The open book's settings object for plugin keys (Track 37): a BookStore
--- facade over the live DocSettings, so koassistant_* keys read/write the
--- plugin's own per-book file while KOReader keys still read KOReader's.
--- nil when no book is open. Replaces every direct DocSettings call on the
--- open book in this file (grep gate in tests/unit/test_book_store.lua).
function AskGPT:_openBookDS()
  local ds = self.ui and self.ui.doc_settings
  if not ds then return nil end
  local file = self.ui.document and self.ui.document.file
  return require("koassistant_book_store").wrap(ds, file)
end

--- Track 37 one-shot: move chats + per-book keys out of metadata.lua into the
--- plugin's own sidecar files for every book the plugin can find. Runs at
--- plugin init while chat_storage_version == 2 (v1 installs go through the
--- v1 import, which now writes straight into the new files and stamps 3).
--- Per book: copy, verify, then delete + flush — idempotent, so an
--- interrupted pass simply re-runs on the next start; the version stamp is
--- written only after a pass with zero failures. Once per process.
function AskGPT:_runBookStoreMigration()
  local version = G_reader_settings:readSetting("chat_storage_version", 1)
  if version ~= 2 then return end
  local BookStore = require("koassistant_book_store")
  if BookStore._bulk_ran then return end
  BookStore._bulk_ran = true
  local features = self.settings:readSetting("features") or {}
  logger.info("KOAssistant: moving per-book data out of metadata.lua (chat storage v2 -> v3)")
  local ok, report = pcall(BookStore.migrateAll, self.ui, features)
  if not ok then
    logger.warn("KOAssistant: book store migration crashed:", report)
    return
  end
  logger.info("KOAssistant: book store migration:", report.candidates, "candidates,",
    report.moved, "moved (" .. report.chats .. " chats, " .. report.keys .. " keys),",
    report.clean, "clean,", report.skipped, "skipped,", report.failed, "failed")
  for _idx, f in ipairs(report.failures) do
    logger.info("KOAssistant: book store migration failure:", f)
  end
  if report.failed == 0 then
    G_reader_settings:saveSetting("chat_storage_version", 3)
  end
  G_reader_settings:flush()
  if report.moved > 0 then
    local moved = report.moved
    UIManager:scheduleIn(2, function()
      UIManager:show(InfoMessage:new{
        text = T(_("KOAssistant moved its data out of KOReader's metadata files for %1 books."), moved),
        timeout = 6,
      })
    end)
  end
end

-- Check if chat history migration is needed
function AskGPT:checkChatMigrationStatus()
  local version = G_reader_settings:readSetting("chat_storage_version", 1)

  -- Check if migration is already in progress
  if G_reader_settings:readSetting("chat_migration_in_progress") then
    logger.warn("Chat migration already in progress, skipping check")
    return
  end

  if version < 2 then
    -- Check if we have any actual old chats to migrate (not just empty directory)
    local ChatHistoryManager = require("koassistant_chat_history_manager")

    if ChatHistoryManager:hasV1Chats() then
      logger.info("Chat storage needs migration from v1 to v2")
      self:showMigrationDialog()
    else
      -- No old chats to migrate, just mark as v3 (the current sidecar-file layout)
      logger.info("No old chats found, marking storage as v3")
      G_reader_settings:saveSetting("chat_storage_version", 3)
      G_reader_settings:flush()
    end
  end
end

-- Show migration dialog to user
function AskGPT:showMigrationDialog()
  local ConfirmBox = require("ui/widget/confirmbox")
  local confirm = ConfirmBox:new{
    text = _([[KOAssistant: Chat Storage Upgrade

The KOAssistant plugin needs to upgrade its chat history storage to fix an issue where chats were lost when files were moved.

This will migrate all existing chats to the new system. The process may take a few minutes for large libraries.

Old chat files will be backed up to koassistant_chats.backup/]]),
    ok_text = _("Migrate Now"),
    cancel_text = _("Later"),
    ok_callback = function()
      self:migrateChatsToDocSettings()
    end,
    cancel_callback = function()
      logger.info("User postponed chat migration")
    end,
  }
  UIManager:show(confirm)
end

-- Migrate chats from hash directories to DocSettings
function AskGPT:migrateChatsToDocSettings()
  local ChatHistoryManager = require("koassistant_chat_history_manager")
  local DocSettings = require("docsettings")

  -- Set migration lock
  G_reader_settings:saveSetting("chat_migration_in_progress", true)
  G_reader_settings:flush()

  -- Track progress
  local stats = {
    total_chats = 0,
    migrated = 0,
    failed = 0,
    skipped = 0,
    errors = {},
  }

  -- Show progress dialog
  local progress = InfoMessage:new{
    text = _("KOAssistant: Migrating chat history..."),
  }
  UIManager:show(progress)

  -- Scan old directory structure
  local old_dir = ChatHistoryManager.CHAT_DIR
  if not lfs.attributes(old_dir, "mode") then
    -- No old chats to migrate
    G_reader_settings:saveSetting("chat_storage_version", 3)
    G_reader_settings:delSetting("chat_migration_in_progress")
    G_reader_settings:flush()
    UIManager:close(progress)
    UIManager:show(InfoMessage:new{
      text = _("No old chats found to migrate"),
      timeout = 3,
    })
    return
  end

  -- Group chats by document_path
  local chats_by_document = {}

  for doc_hash in lfs.dir(old_dir) do
    if doc_hash ~= "." and doc_hash ~= ".." then
      local doc_dir = old_dir .. "/" .. doc_hash
      if lfs.attributes(doc_dir, "mode") == "directory" then
        -- Read all chats in this directory
        for filename in lfs.dir(doc_dir) do
          if filename:match("%.lua$") and not filename:match("%.old$") then
            local chat_path = doc_dir .. "/" .. filename
            local chat = ChatHistoryManager:loadChat(chat_path)

            if chat and chat.document_path then
              stats.total_chats = stats.total_chats + 1

              -- Group by document path
              local doc_path = chat.document_path
              if not chats_by_document[doc_path] then
                chats_by_document[doc_path] = {}
              end
              table.insert(chats_by_document[doc_path], chat)
            end
          end
        end
      end
    end
  end

  logger.info("Found " .. stats.total_chats .. " chats to migrate")

  -- Migrate each document's chats
  for doc_path, chats in pairs(chats_by_document) do
    local success, err = pcall(function()
      if doc_path == "__GENERAL_CHATS__" then
        -- Migrate to general chat file
        for _idx, chat in ipairs(chats) do
          ChatHistoryManager:saveGeneralChat(chat)
          stats.migrated = stats.migrated + 1
        end
        logger.info("Migrated " .. #chats .. " general chats")
      else
        -- Check if document still exists
        if lfs.attributes(doc_path, "mode") then
          -- Read existing chats from the book's chats file (if any) and add
          -- the v1 chats (keyed by ID). Track 37: v1 imports straight into the
          -- sidecar chats file, never through metadata.lua.
          local BookStore = require("koassistant_book_store")
          local existing_chats = BookStore.readChats(doc_path)
          for _idx, chat in ipairs(chats) do
            existing_chats[chat.id] = chat
            stats.migrated = stats.migrated + 1
          end
          local ok_w, err_w = BookStore.writeChats(doc_path, existing_chats)
          if not ok_w then error(err_w or "chats write failed") end

          -- Update chat index (title/author from KOReader's DocSettings)
          local doc_settings = require("koassistant_doc_settings").resolve(doc_path)
          ChatHistoryManager:updateChatIndex(doc_path, "save", nil, existing_chats,
            { doc_props = doc_settings:readSetting("doc_props"), has_props = true })

          logger.info("Migrated " .. #chats .. " chats for: " .. doc_path)
        else
          -- Document no longer exists, skip these chats
          stats.skipped = stats.skipped + #chats
          logger.info("Skipped " .. #chats .. " chats for missing document: " .. doc_path)
        end
      end
    end)

    if not success then
      stats.failed = stats.failed + #chats
      table.insert(stats.errors, {
        document = doc_path,
        error = tostring(err),
        count = #chats,
      })
      logger.warn("Failed to migrate chats for " .. doc_path .. ": " .. tostring(err))
    end
  end

  -- Only backup old directory and mark complete if migration succeeded
  if stats.failed == 0 then
    -- Backup old directory
    local backup_dir = old_dir .. ".backup"
    -- Remove any existing backup first
    if lfs.attributes(backup_dir, "mode") then
      logger.info("Removing existing backup directory")
      os.execute('rm -rf "' .. backup_dir .. '"')
    end
    local rename_ok, rename_err = os.rename(old_dir, backup_dir)
    if not rename_ok then
      logger.warn("Failed to backup old directory: " .. tostring(rename_err))
      -- Don't mark as complete if we couldn't even backup
      stats.failed = 1  -- Force retry
    else
      -- Mark migration complete only after successful backup
      -- v3 = chats in the plugin's own koassistant_chats.lua sidecar file
      G_reader_settings:saveSetting("chat_storage_version", 3)
      logger.info("Migration successful, marked as v3 storage (sidecar chats file)")
    end
  else
    logger.warn("Migration had " .. stats.failed .. " failures, keeping v1 storage for retry")
  end

  -- Always clear migration lock
  G_reader_settings:delSetting("chat_migration_in_progress")
  G_reader_settings:flush()

  -- Close progress
  UIManager:close(progress)

  -- Show results
  local result_text
  if stats.failed > 0 then
    -- Migration failed, will retry
    result_text = T(_([[KOAssistant: Migration Incomplete

✓ Migrated: %1 chats
⊗ Skipped: %2 chats (documents no longer exist)
✗ Failed: %3 chats

Migration will be retried on next startup.
Check the console for detailed error messages.]]),
      stats.migrated,
      stats.skipped,
      stats.failed
    )
    result_text = result_text .. "\n\n" .. _("Failed documents:") .. "\n"
    for _idx, error_info in ipairs(stats.errors) do
      result_text = result_text .. string.format("• %s (%d chats)\n  Error: %s\n",
        error_info.document, error_info.count, error_info.error)
    end
  else
    -- Migration succeeded
    result_text = T(_([[KOAssistant: Migration Complete

✓ Migrated: %1 chats
⊗ Skipped: %2 chats (documents no longer exist)

Old chat files backed up to:
koassistant_chats.backup/]]),
      stats.migrated,
      stats.skipped
    )
  end

  UIManager:show(InfoMessage:new{
    text = result_text,
    timeout = 10,
  })

  logger.info("Chat migration complete - migrated: " .. stats.migrated ..
              ", skipped: " .. stats.skipped .. ", failed: " .. stats.failed)
end

--[[
    Lazy Initialization
    Deferred initialization that runs on first user interaction (action or settings open).
    This avoids intrusive popups when KOReader starts.
--]]

-- Ensure plugin is initialized before first use
-- Call this from action entry points and settings menu
function AskGPT:ensureInitialized()
  -- Only run once per session
  if self._initialized then
    return
  end
  self._initialized = true

  -- Notify user if configuration.lua exists but failed to load (syntax error etc.)
  -- Shown here (first interaction) rather than at startup — avoids firing when
  -- the user isn't using KOAssistant, and provides immediate context.
  if config_load_error then
    UIManager:show(InfoMessage:new{
      text = _("configuration.lua has errors and was not loaded.") .. "\n\n"
        .. config_load_error
        .. "\n\n" .. _("Please fix the syntax error. Your custom settings (endpoints, provider, features) are not active."),
      icon = "notice-warning",
    })
  end

  -- Check migration first (may show dialog if old chats exist)
  self:checkChatMigrationStatus()

  -- Setup wizard: welcome → language → emoji test → gesture setup → tips
  -- Shows once for new users (v2+ storage, not yet completed)
  self:checkSetupWizard()

  -- One-time language prompt for existing users who never configured languages
  self:checkLanguagePrompt()
end

--[[
    Setup Wizard
    Sequential first-run setup: welcome → emoji test → gesture setup → tips.
    Shows once for new users. Replaces the old separate welcome + gesture dialogs.
--]]

-- Scan gestures data for every slot holding the given dispatcher action.
-- Returns an array of { section = "gesture_reader"|"gesture_fm", slot = id },
-- sorted for a steady display (pairs order is unstable).
local function _scanGesturesForAction(gestures_data, action_id)
  local found = {}
  for _idx, section_name in ipairs({"gesture_reader", "gesture_fm"}) do
    local section = gestures_data[section_name]
    if type(section) == "table" then
      for slot, gesture_entry in pairs(section) do
        if type(gesture_entry) == "table" and gesture_entry[action_id] then
          table.insert(found, { section = section_name, slot = slot })
        end
      end
    end
  end
  table.sort(found, function(a, b)
    if a.section ~= b.section then return a.section < b.section end
    return a.slot < b.slot
  end)
  return found
end

-- Check if a gesture slot is empty (nil or empty table)
local function _isGestureSlotEmpty(gesture_entry)
  if gesture_entry == nil then
    return true
  end
  if type(gesture_entry) == "table" and next(gesture_entry) == nil then
    return true
  end
  return false
end

--[[
    Shortcuts screen (release prep A7, decided 2026-08-12): every KOA
    dispatcher action with its CURRENT gesture binding, editable in place.
    Assignment goes through the LIVE Gestures plugin instance — its settings
    object is class-level and its gestureAction() reads the shared table at
    fire time, with every zone registered unconditionally at init, so a write
    takes effect immediately, no restart (verified against
    plugins/gestures.koplugin 2026-08-12). The file fallback is READ-ONLY
    display: writing gestures.lua behind the plugin's back is the issue-#72
    class of bug — its next flush would clobber the write.
--]]

-- The static dispatcher registrations from onDispatcherRegisterActions, in
-- display order. fm/reader eligibility mirrors the registration flags
-- (general=true actions appear in both gesture menus).
function AskGPT:_shortcutActionList()
  local list = {
    { id = "koassistant_general_chat", title = _("General Chat/Action"), fm = true, reader = true },
    { id = "koassistant_book_chat", title = _("Book Chat/Action"), fm = false, reader = true },
    { id = "koassistant_library_actions", title = _("Library Chat/Action"), fm = true, reader = true },
    { id = "koassistant_book_overview", title = _("Book Hub"), fm = false, reader = true },
    { id = "koassistant_quick_actions", title = _("Quick Actions"), fm = false, reader = true },
    { id = "koassistant_ai_settings", title = _("Quick Settings"), fm = true, reader = true },
    { id = "koassistant_chat_history", title = _("Chat History"), fm = true, reader = true },
    { id = "koassistant_continue_last_opened", title = _("Continue Last Chat"), fm = true, reader = true },
    { id = "koassistant_continue_last", title = _("Continue Last Saved Chat"), fm = true, reader = true },
    { id = "koassistant_settings", title = _("Settings"), fm = true, reader = true },
    { id = "koassistant_translate_page", title = _("Translate Page"), fm = false, reader = true },
    { id = "koassistant_toggle_dictionary_bypass", title = _("Toggle Dictionary Bypass"), fm = true, reader = true },
    { id = "koassistant_toggle_highlight_bypass", title = _("Toggle Highlight Bypass"), fm = true, reader = true },
  }
  -- Per-action gestures the user registered via the Action Manager ("Add to
  -- Gesture Menu") — same ids onDispatcherRegisterActions builds.
  local features = self.settings:readSetting("features") or {}
  if features.show_in_gesture_menu ~= false and self.action_service then
    local gesture_actions = self.action_service:getGestureActions() or {}
    local keys = {}
    for k in pairs(gesture_actions) do table.insert(keys, k) end
    table.sort(keys)
    for _idx, action_key in ipairs(keys) do
      local context, action_id = action_key:match("^([^:]+):(.+)$")
      local action = context and self.action_service
        and self.action_service:getAction(context, action_id)
      if action then
        local is_general = (context == "general" or context == "book+general")
        table.insert(list, {
          id = "koassistant_action_" .. context .. "_" .. action_id,
          title = action.text or action_id,
          fm = is_general,
          reader = is_general or context == "book" or context == "book+general",
        })
      end
    end
  end
  return list
end

-- Live-first gestures access. Returns data, live_instance (nil = file
-- fallback, display only).
function AskGPT:_gesturesAccess()
  local ges = self.ui and self.ui.gestures
  if ges and ges.settings and ges.settings.data then
    return ges.settings.data, ges
  end
  local settings = LuaSettings:open(DataStorage:getSettingsDir() .. "/gestures.lua")
  return settings.data or {}, nil
end

-- Friendly name for a gesture slot: our candidate labels, else the raw id
-- prettified (bindings made through KOReader's own gesture manager).
function AskGPT:_gestureSlotLabel(slot)
  local SetupWizard = require("koassistant_setup_wizard")
  for _idx, cand in ipairs(SetupWizard.GESTURE_CANDIDATES) do
    if cand.id == slot then return cand.label end
  end
  return (slot:gsub("_", " "))
end

function AskGPT:_gestureSectionLabel(section)
  return section == "gesture_fm" and _("file browser") or _("reader")
end

-- Bind action_id to a free slot through the live instance. Single-action
-- entry, the wizard's write shape; no order bookkeeping needed for one action.
function AskGPT:_assignShortcut(live, section, slot, action_id)
  local data = live.settings.data
  data[section] = data[section] or {}
  data[section][slot] = { [action_id] = true }
  -- Re-point the fire-time lookup table in case the section table was
  -- created fresh (normally the same table ref, so this is a no-op).
  if live.ges_mode then live.gestures = data[live.ges_mode] end
  live.settings:flush()
end

-- Remove action_id from a slot, mirroring Dispatcher's native uncheck path
-- (setValue → _removeFromOrder). A slot left with nothing actionable goes
-- back to nil ("pass through"), so a tap that used to fall through — e.g. to
-- page turn — falls through again.
function AskGPT:_removeShortcut(live, section, slot, action_id)
  local data = live.settings.data
  local sec = data[section]
  local entry = sec and sec[slot]
  if type(entry) ~= "table" then return end
  entry[action_id] = nil
  Dispatcher._removeFromOrder(sec, slot, action_id)
  local remaining = 0
  for k in pairs(entry) do
    if k ~= "settings" then remaining = remaining + 1 end
  end
  if remaining == 0 then sec[slot] = nil end
  if live.ges_mode then live.gestures = data[live.ges_mode] end
  live.settings:flush()
end

function AskGPT:showShortcutsScreen()
  local data, live = self:_gesturesAccess()
  local self_ref = self
  local dialog
  local buttons = {}
  for _idx, act in ipairs(self:_shortcutActionList()) do
    local bindings = _scanGesturesForAction(data, act.id)
    local label
    if #bindings == 0 then
      label = T(_("%1: %2"), act.title, _("not set"))
    else
      local parts = {}
      for _b, b in ipairs(bindings) do
        table.insert(parts, T(_("%1 (%2)"),
          self:_gestureSlotLabel(b.slot), self:_gestureSectionLabel(b.section)))
      end
      label = T(_("%1: %2"), act.title, table.concat(parts, ", "))
    end
    table.insert(buttons, { {
      text = label,
      enabled = live ~= nil,
      callback = function()
        UIManager:close(dialog)
        self_ref:showShortcutSlotPicker(act)
      end,
    } })
  end
  table.insert(buttons, { {
    text = _("Close"), id = "close",
    callback = function() UIManager:close(dialog) end,
  } })
  local title = _("Shortcuts")
  if live then
    title = title .. "\n" .. _("Tap an action to assign or remove a gesture. Changes apply immediately.")
  else
    title = title .. "\n" .. _("KOReader's gesture data isn't ready, so assignment is unavailable here — use KOReader Settings > Taps and gestures.")
  end
  dialog = ButtonDialog:new{ title = title, buttons = buttons }
  UIManager:show(dialog)
end

function AskGPT:showShortcutSlotPicker(act)
  local data, live = self:_gesturesAccess()
  if not live then return self:showShortcutsScreen() end
  local self_ref = self
  local dialog
  local function done()
    if dialog then UIManager:close(dialog); dialog = nil end
    self_ref:showShortcutsScreen()
  end

  local buttons = {}
  local bindings = _scanGesturesForAction(data, act.id)
  for _b, b in ipairs(bindings) do
    table.insert(buttons, { {
      text = T(_("Remove: %1 (%2)"),
        self:_gestureSlotLabel(b.slot), self:_gestureSectionLabel(b.section)),
      callback = function()
        self_ref:_removeShortcut(live, b.section, b.slot, act.id)
        UIManager:show(Notification:new{ text = _("Gesture removed."), timeout = 2 })
        done()
      end,
    } })
  end

  local SetupWizard = require("koassistant_setup_wizard")
  local sections = {}
  if act.reader then table.insert(sections, { key = "gesture_reader", header = _("— Reader —") }) end
  if act.fm then table.insert(sections, { key = "gesture_fm", header = _("— File browser —") }) end
  for _s, s in ipairs(sections) do
    if #sections > 1 then
      table.insert(buttons, { { text = s.header, enabled = false } })
    end
    for _c, cand in ipairs(SetupWizard.GESTURE_CANDIDATES) do
      local entry = (data[s.key] or {})[cand.id]
      local state = SetupWizard.slotState(entry)
      if state == "free" then
        table.insert(buttons, { {
          text = cand.label,
          callback = function()
            self_ref:_assignShortcut(live, s.key, cand.id, act.id)
            UIManager:show(Notification:new{
              text = T(_("Gesture assigned: %1"), cand.label), timeout = 2 })
            done()
          end,
        } })
      else
        -- Show what holds the slot (pcall: gestures.lua can hold ids the
        -- Dispatcher doesn't know this session, e.g. from removed plugins)
        local ok, holder = pcall(function() return Dispatcher:menuTextFunc(entry) end)
        table.insert(buttons, { {
          text = T(_("%1 — %2"), cand.label, ok and holder or _("taken")),
          enabled = false,
        } })
      end
    end
  end

  table.insert(buttons, { {
    text = _("Cancel"), id = "close",
    callback = done,
  } })
  dialog = ButtonDialog:new{
    title = T(_("Shortcut for: %1"), act.title) .. "\n"
      .. _("Pick a gesture — it starts working right away:"),
    buttons = buttons,
    -- Outside-tap = Cancel (plugin tenet); the widget already closed itself,
    -- so only the reopen runs.
    tap_close_callback = function()
      dialog = nil
      self_ref:showShortcutsScreen()
    end,
  }
  UIManager:show(dialog)
end

-- Check if setup wizard should be shown
function AskGPT:checkSetupWizard()
  -- Skip if already completed
  if self.settings:readSetting("setup_wizard_completed") then
    return
  end

  -- Only show for v2+ users (skips users mid-migration to avoid dialog collision)
  local storage_version = G_reader_settings:readSetting("chat_storage_version", 1)
  if storage_version < 2 then
    return
  end

  self:showSetupWizard()
end

-- One-time language prompt for existing users who completed wizard
-- but never configured languages, and auto-detect finds non-English.
function AskGPT:checkLanguagePrompt()
  -- Only show if wizard was completed (this is an existing user, not a new one)
  if not self.settings:readSetting("setup_wizard_completed") then
    return
  end

  local features = self.settings:readSetting("features") or {}

  -- Skip if already has languages configured (new or old format)
  if features.interaction_languages and #features.interaction_languages > 0 then
    return
  end
  if features.user_languages and features.user_languages ~= "" then
    return
  end

  -- Skip if already prompted
  if features._language_prompt_shown then
    return
  end

  -- Auto-detect from KOReader
  local detected = Languages.detectFromKOReader()

  -- Skip if English or unmappable (English users already get correct behavior)
  if not detected or detected == "English" then
    return
  end

  local ConfirmBox = require("ui/widget/confirmbox")
  local detected_display = Languages.getDisplay(detected)

  local text = T(_("KOAssistant detected your language as %1."), detected_display) .. "\n\n" ..
    T(_("Use %1 for AI responses, translations, and dictionary?"), detected_display) .. "\n\n" ..
    _("You can change this anytime in Settings → AI Language Settings.")

  local prompt_advancing = false
  UIManager:show(ConfirmBox:new{
    text = text,
    ok_text = T(_("Use %1"), detected_display),
    cancel_text = _("Keep English"),
    ok_callback = function()
      prompt_advancing = true
      features.interaction_languages = { detected }
      features.user_languages = detected  -- backward compat
      features._language_prompt_shown = true
      self.settings:saveSetting("features", features)
      self.settings:flush()
      self:updateConfigFromSettings()
    end,
    cancel_callback = function()
      if not prompt_advancing then
        prompt_advancing = true
        -- Save English explicitly so auto-detect doesn't override
        features.interaction_languages = { "English" }
        features.user_languages = "English"
        features._language_prompt_shown = true
        self.settings:saveSetting("features", features)
        self.settings:flush()
        self:updateConfigFromSettings()
      end
    end,
  })
end

-- Orchestrate the setup wizard steps
function AskGPT:showSetupWizard()
  -- Pre-load gesture data for step 3
  local gestures_path = DataStorage:getSettingsDir() .. "/gestures.lua"
  local gestures_settings = LuaSettings:open(gestures_path)
  local gestures_data = gestures_settings.data

  -- Determine gesture slot availability
  local gestures_available = gestures_data and next(gestures_data) ~= nil
  local both_free = false
  if gestures_available then
    local reader_gestures = gestures_data.gesture_reader or {}
    local fm_gestures = gestures_data.gesture_fm or {}
    both_free = _isGestureSlotEmpty(reader_gestures.tap_right_bottom_corner)
      and _isGestureSlotEmpty(fm_gestures.tap_right_bottom_corner)
  end

  -- Chain: Step 1 → Step 2 → Step 3 → Step 4 → Step 5
  self:showSetupStep1Welcome(function()
    self:showSetupStep2Language(function()
      self:showSetupStep3EmojiTest(function()
        self:showSetupStep4Gestures(gestures_settings, gestures_available, both_free, function(gestures_applied)
          self:showSetupStep5Tips(gestures_applied)
        end)
      end)
    end)
  end)
end

-- Step 1: Welcome
function AskGPT:showSetupStep1Welcome(next_step)
  local text = _("Welcome to KOAssistant!") .. "\n\n" ..
    _("Your AI reading assistant is ready. Let's set up a few things. Tap the screen to continue.")

  UIManager:show(InfoMessage:new{
    text = text,
    dismiss_callback = next_step,
  })
end

-- Step 2: Language selection
function AskGPT:showSetupStep2Language(next_step)
  -- Skip if languages already configured (e.g., re-running wizard)
  do
    local f = self.settings:readSetting("features") or {}
    if (f.interaction_languages and #f.interaction_languages > 0)
        or (f.user_languages and f.user_languages ~= "") then
      next_step()
      return
    end
  end

  local ConfirmBox = require("ui/widget/confirmbox")

  -- Auto-detect from KOReader UI language
  local detected = Languages.detectFromKOReader()
  local detected_display = detected and Languages.getDisplay(detected) or nil

  local function saveLanguageAndAdvance(lang_id)
    local features = self.settings:readSetting("features") or {}
    features.interaction_languages = { lang_id }
    features.user_languages = lang_id  -- backward compat
    self.settings:saveSetting("features", features)
    self.settings:flush()
    self:updateConfigFromSettings()
    next_step()
  end

  if detected and detected ~= "English" then
    -- Non-English detected: confirm or let them choose differently
    local text = _("LANGUAGE SETUP") .. "\n\n" ..
      T(_("Your KOReader language is %1."), detected_display) .. "\n" ..
      T(_("Use %1 as your AI language?"), detected_display) .. "\n\n" ..
      _("You can add more languages later in Settings.")

    local wizard_advancing = false
    UIManager:show(ConfirmBox:new{
      text = text,
      ok_text = T(_("Use %1"), detected_display),
      cancel_text = _("Choose different"),
      ok_callback = function()
        wizard_advancing = true
        saveLanguageAndAdvance(detected)
      end,
      cancel_callback = function()
        if not wizard_advancing then
          wizard_advancing = true
          self:showWizardLanguagePicker(next_step)
        end
      end,
    })
  else
    -- English detected or detection failed: confirm or choose different
    local text = _("LANGUAGE SETUP") .. "\n\n" ..
      _("KOAssistant will respond in English by default.") .. "\n" ..
      _("If you prefer a different language, tap \"Choose Language\".") .. "\n\n" ..
      _("You can add more languages later in Settings.")

    local wizard_advancing = false
    UIManager:show(ConfirmBox:new{
      text = text,
      ok_text = _("Keep English"),
      cancel_text = _("Choose language"),
      ok_callback = function()
        wizard_advancing = true
        saveLanguageAndAdvance("English")
      end,
      cancel_callback = function()
        if not wizard_advancing then
          wizard_advancing = true
          self:showWizardLanguagePicker(next_step)
        end
      end,
    })
  end
end

-- Helper: Show language picker for wizard
function AskGPT:showWizardLanguagePicker(next_step)
  -- Build button rows (2 columns) from REGULAR languages
  local buttons = {}
  local row = {}
  local picker_dialog
  -- Guard so picking a language and dismissing the dialog can't both advance.
  local picker_advancing = false
  for _i, lang in ipairs(Languages.REGULAR) do
    local lang_id = lang.id
    local lang_display = lang.display
    table.insert(row, {
      text = lang_display,
      callback = function()
        if picker_advancing then return end
        picker_advancing = true
        UIManager:close(picker_dialog)
        -- Save selected language
        local features = self.settings:readSetting("features") or {}
        features.interaction_languages = { lang_id }
        features.user_languages = lang_id  -- backward compat
        self.settings:saveSetting("features", features)
        self.settings:flush()
        self:updateConfigFromSettings()
        next_step()
      end,
    })
    if #row == 2 then
      table.insert(buttons, row)
      row = {}
    end
  end
  if #row > 0 then
    table.insert(buttons, row)
  end

  picker_dialog = ButtonDialog:new{
    title = _("Choose your AI language"),
    buttons = buttons,
    -- Dismissing (tap outside / Back) must not strand the wizard: continue
    -- without forcing a language (auto-detect stays in effect).
    tap_close_callback = function()
      if picker_advancing then return end
      picker_advancing = true
      next_step()
    end,
  }
  UIManager:show(picker_dialog)
end

-- Step 3: Emoji display test
function AskGPT:showSetupStep3EmojiTest(next_step)
  local ConfirmBox = require("ui/widget/confirmbox")
  local text = _("EMOJI DISPLAY TEST") .. "\n\n" ..
    _("Do these icons display correctly on your device?") .. "\n\n" ..
    "📄 Document  📝 Notes  📓 Notebook\n" ..
    "🔍 Search  🌐 Web  🎭 Behavior\n" ..
    "📜 History  🔖 Bookmark  📖 Book" .. "\n\n" ..
    _("See the README for instructions on how to enable emojis in the KOReader UI.") .. "\n\n" ..
    _("If you see blank boxes or question marks, choose \"No\".")

  local wizard_advancing = false
  UIManager:show(ConfirmBox:new{
    icon = "notice-info",
    text = text,
    ok_text = _("Yes, enable"),
    cancel_text = _("No, skip"),
    ok_callback = function()
      -- Enable all three emoji settings
      local features = self.settings:readSetting("features") or {}
      features.enable_emoji_icons = true
      features.enable_emoji_panel_icons = true
      features.enable_data_access_indicators = true
      self.settings:saveSetting("features", features)
      self.settings:flush()
      self:updateConfigFromSettings()
      wizard_advancing = true
      next_step()
    end,
    cancel_callback = function()
      -- ConfirmBox calls cancel_callback on both "No" tap and dismiss.
      -- Guard against advancing twice.
      if not wizard_advancing then
        wizard_advancing = true
        next_step()
      end
    end,
  })
end

-- Step 4: Gesture setup
function AskGPT:showSetupStep4Gestures(gestures_settings, gestures_available, both_free, next_step)
  local ConfirmBox = require("ui/widget/confirmbox")

  if gestures_available and both_free then
    -- Offer to auto-assign both gestures
    local text = _("GESTURE SETUP") .. "\n\n" ..
      _("KOAssistant has two quick-access panels:") .. "\n\n" ..
      _("Quick Actions: book actions, artifacts, and utilities (reader mode)") .. "\n" ..
      _("Quick Settings: change provider, model, behavior, and more (file browser)") .. "\n\n" ..
      _("Assign both to \"tap bottom right corner\"?") .. "\n\n" ..
      _("You can change these anytime in KOReader Settings (Gear icon) → Taps and Gestures.") .. "\n\n" ..
      _("Requires KOReader restart to take effect.")

    local wizard_advancing = false
    UIManager:show(ConfirmBox:new{
      text = text,
      ok_text = _("Set up"),
      cancel_text = _("No thanks"),
      ok_callback = function()
        self:applyGestureSetup(gestures_settings)
        wizard_advancing = true
        next_step(true) -- true = gestures were set up
      end,
      cancel_callback = function()
        if not wizard_advancing then
          wizard_advancing = true
          next_step()
        end
      end,
    })
  else
    -- Info-only: gesture slots already occupied or gestures.lua not ready
    local text = _("GESTURE TIP") .. "\n\n" ..
      _("KOAssistant has two quick-access panels you can assign to gestures:") .. "\n\n" ..
      _("Quick Actions: book actions, artifacts, and utilities (assign in reader mode)") .. "\n" ..
      _("Quick Settings: change provider, model, behavior, and more (assign in file browser mode)") .. "\n\n" ..
      _("Set them up in KOReader Settings (Gear icon) → Taps and Gestures.")

    UIManager:show(InfoMessage:new{
      text = text,
      dismiss_callback = next_step,
    })
  end
end

-- Step 5: Getting started tips
function AskGPT:showSetupStep5Tips(gestures_applied)
  local text = _("GETTING STARTED") .. "\n\n" ..
    _("Privacy & Data") .. "\n" ..
    _("Some features need document text access. Enable in: Settings → Privacy & Data") .. "\n" ..
    _("Tip: keep a toggle off globally and allow it per book — or on globally and deny it for sensitive books. A per-book deny always wins.") .. "\n\n" ..
    _("Actions & Prompts") .. "\n" ..
    _("Create or edit prompts: Settings → Actions & Prompts → Manage Actions (or from Quick Settings panel)")

  if gestures_applied then
    text = text .. "\n\n" ..
      _("Gestures assigned. Please restart KOReader for changes to take effect.")
  end

  text = text .. "\n\n" .. _("Enjoy your reading!")

  UIManager:show(InfoMessage:new{
    text = text,
  })

  -- Mark wizard as completed
  self.settings:saveSetting("setup_wizard_completed", true)
  self.settings:flush()
end

-- Apply gesture assignments to gestures.lua
function AskGPT:applyGestureSetup(gestures_settings)
  -- Ensure sections exist
  if not gestures_settings.data.gesture_reader then
    gestures_settings.data.gesture_reader = {}
  end
  if not gestures_settings.data.gesture_fm then
    gestures_settings.data.gesture_fm = {}
  end

  -- Assign QA to tap bottom right in reader mode
  gestures_settings.data.gesture_reader.tap_right_bottom_corner = {
    koassistant_quick_actions = true,
  }

  -- Assign QS to tap bottom right in file browser mode
  gestures_settings.data.gesture_fm.tap_right_bottom_corner = {
    koassistant_ai_settings = true,
  }

  -- Persist to gestures.lua
  gestures_settings:flush()
end

-- Patch TextViewer and DictQuickLookup for unified text selection behavior:
-- Single word + short hold → dictionary lookup
-- Single word + long hold → selection popup (Copy, Dictionary, Translate, Notebook)
-- Multi-word → selection popup
-- Long hold threshold matches user's ges_hold_interval_ms setting.
function AskGPT:patchTextSelectionHandlers()
  local features = self.settings:readSetting("features") or {}
  if features.enhance_text_selection ~= true then return end

  local TextViewer = require("ui/widget/textviewer")
  local DictQuickLookup = require("ui/widget/dictquicklookup")
  local ReaderUI = require("apps/reader/readerui")
  local ChatGPTViewer = require("koassistant_chatgptviewer")

  -- Only patch once
  if TextViewer._koassistant_patched then return end
  TextViewer._koassistant_patched = true

  -- Helper: get plugin instance from ReaderUI
  local function getPlugin()
    local reader_ui = ReaderUI.instance
    return reader_ui and reader_ui.koassistant
  end

  -- Helper: clear highlight from a TextViewer's scroll widget
  -- (scroll_widget = post-2026-07 KOReader field name, scroll_text_w = older)
  local function clearViewerHighlight(viewer)
    local sw = viewer and (viewer.scroll_widget or viewer.scroll_text_w)
    if sw and sw.text_widget then
      local tw = sw.text_widget
      if tw.clearHighlight and tw:clearHighlight() then
        tw:redrawHighlight()
      end
    end
  end

  -- Patch TextViewer: add dictionary lookup + selection popup
  local orig_tv_handleTextSelection = TextViewer.handleTextSelection
  function TextViewer:handleTextSelection(text, hold_duration, start_idx, end_idx, to_source_index_func)
    -- Respect existing text_selection_callback (used by X-Ray browser etc.)
    if self.text_selection_callback then
      self.text_selection_callback(text, hold_duration, start_idx, end_idx, to_source_index_func)
      return
    end

    local reader_ui = ReaderUI.instance
    if not reader_ui or not reader_ui.dictionary then
      -- No reader context — fall back to original (copy to clipboard)
      return orig_tv_handleTextSelection(self, text, hold_duration, start_idx, end_idx, to_source_index_func)
    end

    local word_count = 0
    if text then
      for _w in text:gmatch("%S+") do
        word_count = word_count + 1
        if word_count > 1 then break end
      end
    end

    if word_count == 1 and not ChatGPTViewer.isLongHold(hold_duration) then
      -- Single word + short hold: dictionary lookup
      reader_ui.dictionary._koassistant_non_reader_lookup = true
      reader_ui.dictionary:onLookupWord(text)
      clearViewerHighlight(self)
      return
    end

    -- 2+ words, or single word + long hold: show selection popup
    local plugin = getPlugin()
    -- Viewer text isn't the book, but the note belongs to the reading session's open
    -- book — the only identity available here (Q3 decision; toast names the target)
    local doc_path = reader_ui.document and reader_ui.document.file
    local append_to_notebook
    if doc_path then
      append_to_notebook = function(sel_text)
        ChatGPTViewer.appendSnippetToNotebook(doc_path, sel_text, {
          book_title = reader_ui.doc_props and reader_ui.doc_props.display_title,
        })
      end
    end
    ChatGPTViewer.buildTextSelectionPopup(text, {
      ui = reader_ui,
      plugin = plugin,
      configuration = plugin and plugin.configuration,
      document_path = doc_path,
      append_to_notebook = append_to_notebook,
      clear_highlight = function() clearViewerHighlight(self) end,
    })
  end

  -- Patch DictQuickLookup: long hold on single word → our popup instead of Wikipedia
  local orig_dql_init = DictQuickLookup.init
  function DictQuickLookup:init()
    orig_dql_init(self)

    -- Replace HoldReleaseText callback: same behavior as our viewers
    -- 1 word + short hold → dictionary lookup (original behavior)
    -- 1 word + long hold → our popup
    -- 2+ words → our popup (always)
    if self.ges_events and self.ges_events.HoldReleaseText then
      local orig_args = self.ges_events.HoldReleaseText.args
      local dql_self = self
      self.ges_events.HoldReleaseText.args = function(text, hold_duration)
        local word_count = 0
        if text then
          for _w in text:gmatch("%S+") do
            word_count = word_count + 1
            if word_count > 1 then break end
          end
        end

        -- Single word + short hold: original dictionary/Wikipedia behavior.
        -- The word came from inside a dictionary popup, not the book — mark it so that
        -- if the resulting lookup's KOAssistant action runs, it won't pull the open
        -- book's surrounding context/identity into the request (B3).
        if word_count == 1 and not ChatGPTViewer.isLongHold(hold_duration) then
          local reader_ui = ReaderUI.instance
          if reader_ui and reader_ui.dictionary then
            reader_ui.dictionary._koassistant_non_reader_lookup = true
          end
          orig_args(text, hold_duration)
          return
        end

        -- Multi-word, or single word + long hold: show our popup
        local reader_ui = ReaderUI.instance
        local plugin = getPlugin()
        -- Same open-book targeting as the TextViewer patch (Q3 decision)
        local doc_path = reader_ui and reader_ui.document and reader_ui.document.file
        local append_to_notebook
        if doc_path then
          append_to_notebook = function(sel_text)
            ChatGPTViewer.appendSnippetToNotebook(doc_path, sel_text, {
              book_title = reader_ui.doc_props
                and (reader_ui.doc_props.display_title or reader_ui.doc_props.title),
            })
          end
        end
        ChatGPTViewer.buildTextSelectionPopup(text, {
          ui = reader_ui,
          plugin = plugin,
          configuration = plugin and plugin.configuration,
          document_path = doc_path,
          append_to_notebook = append_to_notebook,
          clear_highlight = function()
            if dql_self.text_widget then
              local inner = dql_self.text_widget.htmlbox_widget or dql_self.text_widget.text_widget
              if inner and inner.clearHighlight and inner:clearHighlight() then
                inner:redrawHighlight()
              end
            end
          end,
        })
      end
    end
  end

  -- Patch TextViewer to enable text selection highlighting by default
  -- and fix HoldPanText gesture (uses "hold" instead of "hold_pan")
  local orig_tv_init = TextViewer.init
  function TextViewer:init(re_init)
    orig_tv_init(self, re_init)

    -- Enable highlight on text selection
    -- (scroll_widget = post-2026-07 KOReader field name, scroll_text_w = older)
    local sw = self.scroll_widget or self.scroll_text_w
    if sw and sw.text_widget then
      sw.text_widget.highlight_text_selection = true
    end

    -- Fix live highlight during drag: TextViewer uses ges="hold" for HoldPanText
    -- (fires once) instead of ges="hold_pan" (fires continuously during drag)
    if self.ges_events and self.ges_events.HoldPanText
        and self.ges_events.HoldPanText[1]
        and self.ges_events.HoldPanText[1].ges == "hold" then
      self.ges_events.HoldPanText[1].ges = "hold_pan"
      self.ges_events.HoldPanText[1].rate = Screen.low_pan_rate and 5.0 or 30.0
    end
  end
end

-- Patch DocSettings.updateLocation() to handle sidecar files and indices on move/copy/delete
-- Mirrors KOReader's own behavior: move on cut, copy on copy, delete on delete
function AskGPT:patchDocSettingsForChatIndex()
  local DocSettings = require("docsettings")

  if DocSettings._koassistant_patched then
    return
  end

  DocSettings._original_updateLocation = DocSettings.updateLocation

  DocSettings.updateLocation = function(old_path, new_path, copy)
    local old_sidecar_dir = DocSettings:getSidecarDir(old_path)

    if new_path then
      -- Move or Copy: transfer sidecar files to new .sdr BEFORE KOReader's original
      -- runs, so purge() (on move) finds the old .sdr empty and can rmdir it
      local new_sidecar_dir = DocSettings:getSidecarDir(new_path)
      util.makePath(new_sidecar_dir)

      for _idx, filename in ipairs(KOASSISTANT_SIDECAR_FILES) do
        local old_sidecar = old_sidecar_dir .. "/" .. filename
        local new_sidecar = new_sidecar_dir .. "/" .. filename

        if lfs.attributes(old_sidecar, "mode") == "file" then
          if copy then
            -- Copy: duplicate file, keep original in place
            local ok, err = copyFileContent(old_sidecar, new_sidecar)
            if ok then
              logger.info("KOAssistant: Copied sidecar file:", filename)
            else
              logger.err("KOAssistant: Failed to copy sidecar file", filename, ":", err)
            end
          else
            -- Move: rename (same filesystem) or copy+delete (cross-filesystem)
            local ok, err = os.rename(old_sidecar, new_sidecar)
            if ok then
              logger.info("KOAssistant: Moved sidecar file:", filename)
            else
              logger.dbg("KOAssistant: os.rename failed, trying copy+delete:", err)
              local copy_ok, copy_err = copyFileContent(old_sidecar, new_sidecar)
              if copy_ok then
                os.remove(old_sidecar)
                logger.info("KOAssistant: Moved sidecar file (cross-filesystem):", filename)
              else
                logger.err("KOAssistant: Failed to move sidecar file", filename, ":", copy_err)
              end
            end
          end
        end
      end
    else
      -- Delete: remove our sidecar files so KOReader's purge() can rmdir the .sdr
      -- (purge only removes its own known files, then rmdir which needs empty dir)
      for _idx, filename in ipairs(KOASSISTANT_SIDECAR_FILES) do
        local sidecar_file = old_sidecar_dir .. "/" .. filename
        if lfs.attributes(sidecar_file, "mode") == "file" then
          os.remove(sidecar_file)
          logger.dbg("KOAssistant: Removed sidecar file:", filename)
        end
      end
    end

    -- Call KOReader's original function (passes through copy parameter)
    DocSettings._original_updateLocation(old_path, new_path, copy)

    -- Per-book store cache (Track 37): the files just moved/copied/died
    local BookStore = require("koassistant_book_store")
    BookStore.invalidate(old_path)
    if new_path then BookStore.invalidate(new_path) end

    -- Update indices: move replaces old→new, copy adds new (keeps old), delete removes old
    local needs_flush = false

    for _idx, index_name in ipairs(KOASSISTANT_INDICES) do
      local index = G_reader_settings:readSetting(index_name, {})
      if index[old_path] then
        if new_path then
          index[new_path] = index[old_path]
        end
        if not copy then
          index[old_path] = nil
        end
        G_reader_settings:saveSetting(index_name, index)
        needs_flush = true
      end
    end

    if needs_flush then
      G_reader_settings:flush()
      if not new_path then
        logger.info("KOAssistant: Cleaned up indices for deleted file")
      elseif copy then
        logger.info("KOAssistant: Duplicated indices for copied file")
      else
        logger.info("KOAssistant: Updated indices for moved file")
      end
    end

    -- Generated-images index maps filenames → book_file values (a plain file
    -- in the images dir, not a G_reader_settings index): move rewrites the
    -- association, delete drops it (images are kept, global-only), copy no-ops
    local ImageGenerator = require("koassistant_image_generator")
    ImageGenerator.updateIndexForMove(old_path, new_path, copy)

    -- Book groups (item 46): move re-keys memberships; copy never joins a
    -- group; delete keeps the entry (missing-file policy — manual remove only)
    require("koassistant_book_groups").updateForMove(old_path, new_path, copy)
  end

  DocSettings._koassistant_patched = true
  logger.dbg("KOAssistant: DocSettings.updateLocation() patched for sidecar file tracking")
end

--- Update notebook index for a document
--- @param document_path string The document file path
--- @param operation string "update" to add/update entry, "remove" to delete entry
function AskGPT:updateNotebookIndex(document_path, operation)
  if not document_path then return end

  local index = G_reader_settings:readSetting("koassistant_notebook_index", {})

  if operation == "remove" then
    index[document_path] = nil
  else
    local Notebook = require("koassistant_notebook")
    local stats = Notebook.getStats(document_path)
    if stats then
      index[document_path] = stats
    else
      -- File doesn't exist, remove from index
      index[document_path] = nil
    end
  end

  G_reader_settings:saveSetting("koassistant_notebook_index", index)
  G_reader_settings:flush()
end

--- Get the notebook index
--- @return table index Map of document_path -> {size, modified}
function AskGPT:getNotebookIndex()
  return G_reader_settings:readSetting("koassistant_notebook_index", {})
end

--- Offer to migrate notebooks when save location changes
--- If no notebooks exist, silently applies the new setting.
--- If notebooks exist, shows confirmation dialog. Reverts on decline.
--- @param old_location string Previous save location ("sidecar", "central", "custom")
--- @param new_location string New save location
function AskGPT:offerNotebookMigration(old_location, new_location)
  if old_location == new_location then return end

  local index = G_reader_settings:readSetting("koassistant_notebook_index", {})
  local count = 0
  for _ in pairs(index) do count = count + 1 end

  -- If index is empty but old location is a vault dir, try scanning for files
  if count == 0 and old_location ~= "sidecar" then
    local Notebook = require("koassistant_notebook")
    local old_base_dir
    if old_location == "central" then
      old_base_dir = DataStorage:getDataDir() .. "/koassistant_notebooks"
    else
      local features = self.settings:readSetting("features") or {}
      old_base_dir = features.notebook_custom_path
    end
    if old_base_dir then
      local rebuilt = Notebook.scanAndRebuildIndex(old_base_dir)
      if rebuilt > 0 then
        count = rebuilt
      end
    end
  end

  if count == 0 then
    -- No notebooks to migrate, just apply setting
    local features = self.settings:readSetting("features") or {}
    features.notebook_save_location = new_location
    self.settings:saveSetting("features", features)
    self.settings:flush()
    self:updateConfigFromSettings()
    return
  end

  -- Setting is currently reverted to old_location — only commit on accept
  local self_ref = self
  local ConfirmBox = require("ui/widget/confirmbox")
  UIManager:show(ConfirmBox:new{
    text = T(_("Move %1 notebook(s) to the new location?"), count),
    ok_text = _("Move"),
    ok_callback = function()
      -- Apply new setting
      local features = self_ref.settings:readSetting("features") or {}
      features.notebook_save_location = new_location
      self_ref.settings:saveSetting("features", features)
      self_ref.settings:flush()
      self_ref:updateConfigFromSettings()

      -- Run migration
      local Notebook = require("koassistant_notebook")
      local moved, failed = Notebook.migrateAll(old_location, new_location, features)

      if failed > 0 then
        UIManager:show(InfoMessage:new{
          text = T(_("Moved %1 notebooks. %2 failed."), moved, failed),
          timeout = 5,
        })
      else
        UIManager:show(InfoMessage:new{
          text = T(_("Moved %1 notebooks."), moved),
          timeout = 3,
        })
      end
    end,
    -- cancel: setting stays at old_location (already reverted by on_change)
  })
end

--- KOReader broadcasts this after a Book information edit (title/authors/
--- cover) for `file`, from the reader or the file browser. The chat index
--- carries the effective title/author (Fix M), so refresh that one entry
--- right away; the refresh no-ops when nothing indexed changed.
function AskGPT:onInvalidateMetadataCache(file)
  if type(file) ~= "string" or not self:documentHasChats(file) then return end
  local ok, err = pcall(function()
    require("koassistant_chat_history_manager"):refreshChatIndexEntry(file, self.ui)
  end)
  if not ok then
    logger.warn("KOAssistant: chat index refresh after metadata edit failed:", err)
  end
end

--- Check if document has saved chats
--- @param file_path string The document file path
--- @return boolean has_chats Whether the document has saved chats
function AskGPT:documentHasChats(file_path)
  local index = G_reader_settings:readSetting("koassistant_chat_index", {})
  return index[file_path] and index[file_path].count and index[file_path].count > 0
end

--- Show chat history filtered to a specific book
--- @param file_path string The document file path
--- @param nav_context table|nil Navigation context passthrough (book page passes
---   close_on_up so level-up returns to the page underneath, not the documents list)
function AskGPT:showChatHistoryForFile(file_path, nav_context)
  local ChatHistoryDialog = require("koassistant_chat_history_dialog")
  local ChatHistoryManager = require("koassistant_chat_history_manager")

  local chat_history_manager = ChatHistoryManager:new()
  if nav_context then
    -- Mirror showChatHistoryBrowser's own default init (skipped when a context
    -- is passed in)
    nav_context.level = nav_context.level or "documents"
    nav_context.came_from_document = true
    nav_context.initial_document = file_path
  end
  -- Pass the live module config (self.CONFIG was never assigned → nil → resumed chats ran with
  -- empty features/no provider). Matches AskGPT:showChatHistory()'s call.
  ChatHistoryDialog:showChatHistoryBrowser(self.ui, file_path, chat_history_manager, configuration, nav_context)
end

--- Open notebook for viewing or editing
--- @param file_path string The document file path
--- @param edit_mode boolean|nil If true, open in TextEditor (edit mode); otherwise open in reader (view mode)
function AskGPT:openNotebookForFile(file_path, edit_mode)
  local Notebook = require("koassistant_notebook")
  local notebook_path = Notebook.getPath(file_path)

  if not notebook_path then
    UIManager:show(InfoMessage:new{
      text = Notebook.getPathError(file_path),
      timeout = 4,
    })
    return
  end

  if not Notebook.exists(file_path) then
    -- Offer to create empty notebook
    local ConfirmBox = require("ui/widget/confirmbox")
    UIManager:show(ConfirmBox:new{
      text = _("No notebook exists for this document. Create one?"),
      ok_callback = function()
        -- Create empty notebook with header
        local ok, err = Notebook.create(file_path)
        if ok then
          self:updateNotebookIndex(file_path, "update")
          -- Re-resolve path (vault mode may have generated collision-safe name)
          local created_path = Notebook.getPath(file_path)
          -- Open in edit mode for new notebooks
          self:openNotebookEditor(created_path, file_path)
        else
          UIManager:show(InfoMessage:new{
            text = T(_("Failed to create notebook: %1"), err or "unknown"),
            timeout = 3,
          })
        end
      end,
    })
    return
  end

  if edit_mode then
    self:openNotebookEditor(notebook_path, file_path)
  else
    self:openNotebookViewer(notebook_path, file_path)
  end
end

--- Open notebook in viewer (mode determined by settings)
--- @param notebook_path string Full path to the notebook file
--- @param document_path string The original document file path (for callbacks)
function AskGPT:openNotebookViewer(notebook_path, document_path)
  local features = self.settings:readSetting("features") or {}
  local viewer_mode = features.notebook_viewer or "chatviewer"

  if viewer_mode == "reader" then
    local ReaderUI = require("apps/reader/readerui")
    ReaderUI:showReader(notebook_path)
  else
    self:openNotebookInChatViewer(notebook_path, document_path)
  end
end

--- Open notebook in ChatGPTViewer simple_view mode
--- @param notebook_path string Full path to the notebook file
--- @param document_path string The original document file path (for edit callback)
function AskGPT:openNotebookInChatViewer(notebook_path, document_path)
  local ChatGPTViewer = require("koassistant_chatgptviewer")
  local Notebook = require("koassistant_notebook")
  local PathChooser = require("ui/widget/pathchooser")

  local content = Notebook.read(document_path)
  if not content or content == "" then
    UIManager:show(InfoMessage:new{
      text = _("Notebook is empty"),
      timeout = 2,
    })
    return
  end

  -- Build title from document filename
  local book_name = document_path:match("([^/]+)%.[^%.]+$") or document_path:match("([^/]+)$") or ""
  local title = _("Notebook") .. " - " .. book_name

  local features = self.settings:readSetting("features") or {}
  local viewer_config = { features = features }

  local self_ref = self

  local on_edit = function()
    self_ref:openNotebookEditor(notebook_path, document_path)
  end

  local on_open_reader = function()
    local ReaderUI = require("apps/reader/readerui")
    ReaderUI:showReader(notebook_path)
  end

  local on_export = function()
    -- Default export path from settings
    local default_path
    local dir_option = features.export_save_directory or "exports_folder"
    if dir_option == "custom" and features.export_custom_path and features.export_custom_path ~= "" then
      default_path = features.export_custom_path
    elseif dir_option == "exports_folder" or dir_option == "ask" then
      default_path = DataStorage:getDataDir() .. "/koassistant_exports"
    else
      default_path = DataStorage:getDataDir()
    end

    local path_chooser = PathChooser:new{
      title = _("Select export folder"),
      path = default_path,
      show_hidden = false,
      select_directory = true,
      select_file = false,
      onConfirm = function(selected_path)
        local filename = notebook_path:match("([^/]+)$") or "notebook.md"
        local filepath = selected_path .. "/" .. filename

        local input_file = io.open(notebook_path, "rb")
        if not input_file then
          UIManager:show(InfoMessage:new{
            text = _("Failed to read notebook file."),
          })
          return
        end
        local file_content = input_file:read("*all")
        input_file:close()

        local ok, err = util.writeToFile(file_content, filepath)
        if ok then
          UIManager:show(Notification:new{
            text = T(_("Saved to %1"), filename),
            timeout = 3,
          })
        else
          UIManager:show(InfoMessage:new{
            text = T(_("Export failed: %1"), err or "unknown error"),
          })
        end
      end,
    }
    UIManager:show(path_chooser)
  end

  -- Resolve book title/author for the "→ Chat" context (best-effort; the book may
  -- not be open when the notebook is viewed from the file browser / notebook manager).
  local book_title, book_author
  if self_ref.ui and self_ref.ui.document and self_ref.ui.document.file == document_path then
    local props = self_ref.ui.doc_props
    book_title = props and (props.display_title or props.title)
    book_author = props and props.authors
  else
    local props = require("koassistant_doc_settings").overlayCustomProps(getRawDocProps(document_path), document_path)
    book_title = props and (props.display_title or props.title)
    book_author = props and props.authors
  end
  book_title = book_title or book_name

  local viewer = ChatGPTViewer:new{
    title = title,
    text = content,
    simple_view = true,
    configuration = viewer_config,
    on_edit = on_edit,
    on_open_reader = on_open_reader,
    on_export = on_export,
    -- Chat directly about the notebook content (controls parity slice (e) note C),
    -- reusing the artifact viewer's → Chat launcher with notebook-specific wording.
    on_launch_chat = self_ref:_buildLaunchChatCallback(document_path, book_title, book_author, content, _("Notebook")),
    launch_chat_title = _("Chat about this notebook"),
    launch_chat_hold_hint = _("Start a new chat about this notebook"),
    _plugin = self_ref,
    _ui = self_ref.ui,
  }

  UIManager:show(viewer)
end

--- Open notebook in TextEditor (edit mode)
--- @param notebook_path string Full path to the notebook file
--- @param document_path string The original document file path (for index updates)
function AskGPT:openNotebookEditor(notebook_path, document_path)
  local InputDialog = require("ui/widget/inputdialog")
  local self_ref = self

  local content = util.readFromFile(notebook_path, "rb") or ""
  local filename = notebook_path:match("([^/]+)$") or "notebook.md"

  local editor = InputDialog:new{
    title = filename,
    input = content,
    fullscreen = true,
    condensed = true,
    allow_newline = true,
    cursor_at_end = false,
    add_nav_bar = true,
    keyboard_visible = false,
    scroll_by_pan = true,

    save_callback = function(edited_content, _closing)
      local ok, err = util.writeToFile(edited_content, notebook_path)
      if ok then
        self_ref:updateNotebookIndex(document_path, "update")
        return true, _("Notebook saved")
      else
        return false, T(_("Failed to save: %1"), err or "unknown")
      end
    end,

    reset_callback = function(_content)
      return util.readFromFile(notebook_path, "rb") or "", _("Reset to last saved")
    end,
  }

  UIManager:show(editor)
end

return AskGPT