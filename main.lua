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
local logger = require("logger")
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

local ok, loaded_config = pcall(dofile, config_path)
if ok and loaded_config then
    configuration = loaded_config
    logger.info("Loaded configuration from configuration.lua")
else
    logger.warn("Could not load configuration.lua, using defaults")
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

-- KOAssistant custom sidecar files to track during book moves
-- These files are automatically moved when books are moved via FileManager
-- Add new custom files here as they're implemented (e.g., notebooks, stats, annotations)
local KOASSISTANT_SIDECAR_FILES = {
    "koassistant_notebook.md",
    "koassistant_cache.lua",  -- X-Ray/Recap response cache
    "koassistant_user_aliases.lua",  -- User-defined X-Ray search terms
}

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

local AskGPT = WidgetContainer:extend{
  name = "koassistant",
  is_doc_only = false,
}

function AskGPT:init()
  logger.info("KOAssistant plugin: init() called")

  -- Store configuration on the instance (single source of truth)
  self.configuration = configuration

  -- Initialize settings
  self:initSettings()

  -- Initialize action service
  self.action_service = ActionService:new(self.settings)
  self.action_service:initialize()

  -- Register dispatcher actions
  self:onDispatcherRegisterActions()

  -- Patch DocSettings for chat index tracking on file moves
  self:patchDocSettingsForChatIndex()

  -- Chat index validation deferred to first chat history browser open
  -- (see ChatHistoryDialog:showChatHistoryBrowser for lazy validation)

  -- Auto-check for updates at startup (if enabled)
  -- Skip NetworkMgr:isOnline() check - it can block the UI thread for several seconds
  -- on shaky WiFi connections. The HTTP request runs in a subprocess with an 8-second
  -- timeout, so it fails gracefully when offline without blocking the UI.
  local features = self.settings:readSetting("features") or {}
  if features.auto_check_updates ~= false then
    UIManager:scheduleIn(1, function()
      local UpdateChecker = require("koassistant_update_checker")
      UpdateChecker.checkForUpdates(true) -- auto = true (silent background check)
    end)
  end

  -- Add to highlight dialog if highlight feature is available
  if self.ui and self.ui.highlight then
    local highlight_features = self.settings:readSetting("features") or {}

    -- Main KOAssistant button (controlled separately from quick actions)
    if highlight_features.show_koassistant_in_highlight ~= false then
      self.ui.highlight:addToHighlightDialog("koassistant_dialog", function(reader_highlight_instance)
        return {
          text = _("Chat/Action") .. " (KOA)",
          enabled = Device:hasClipboard(),
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
                drawer = st.drawer or "lighten",
                color = st.color or "yellow",
              }
            end

            reader_highlight_instance:onClose()
            NetworkMgr:runWhenOnline(function()
              self:ensureInitialized()
              -- Make sure we're using the latest configuration
              self:updateConfigFromSettings()
              -- Clear context flags for highlight context (default context)
              configuration.features = configuration.features or {}
              configuration.features.is_general_context = nil
              configuration.features.is_book_context = nil
              configuration.features.is_multi_book_context = nil
              configuration.features.book_metadata = nil
              configuration.features.books_info = nil
              -- Store selection data for "Save to Note" feature
              configuration.features.selection_data = selection_data
              showChatGPTDialog(self.ui, selected_text, configuration, nil, self)
            end)
          end,
        }
      end)
      logger.info("Added KOAssistant to highlight dialog")
    else
      logger.info("KOAssistant: Main highlight button disabled")
    end

    -- Register quick actions for highlight menu (has its own toggle check)
    self:registerHighlightMenuActions()
  else
    logger.warn("Highlight feature not available, skipping highlight dialog integration")
  end

  -- Sync dictionary bypass setting (override Translator if enabled)
  self:syncDictionaryBypass()
  
  -- Register to main menu immediately
  self:registerToMainMenu()
  
  -- Also register when reader is ready as a backup
  self.onReaderReady = function()
    self:registerToMainMenu()
    -- Sync highlight bypass (needs ui.highlight to be available)
    self:syncHighlightBypass()
  end
  
  -- Register file dialog buttons with delays to ensure they appear at the bottom
  -- First attempt after a short delay to let core plugins register
  UIManager:scheduleIn(0.5, function()
    logger.info("KOAssistant: First file dialog button registration (0.5s delay)")
    self:addFileDialogButtons()
  end)

  -- Second attempt after other plugins should be loaded
  UIManager:scheduleIn(2, function()
    logger.info("KOAssistant: Second file dialog button registration (2s delay)")
    self:addFileDialogButtons()
  end)

  -- Final attempt to ensure registration in all contexts
  UIManager:scheduleIn(5, function()
    logger.info("KOAssistant: Final file dialog button registration (5s delay)")
    self:addFileDialogButtons()
  end)
  
  -- Patch FileManager for multi-select support
  self:patchFileManagerForMultiSelect()
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
  logger.info("KOAssistant: generateFileDialogRows called with file=" .. tostring(file))

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
    local doc_props = doc_settings:readSetting("doc_props")
    title = doc_props and (doc_props.display_title or doc_props.title) or nil
  end
  if not title or title == "" then
    title = file:match("([^/]+)%.[^%.]+$") or file:match("([^/]+)$")
  end
  local authors = book_props and book_props.authors or ""
  local self_ref_main = self
  table.insert(buttons, {
    text = _("Chat/Action") .. " (KOA)",
    callback = function()
      local UIManager = require("ui/uimanager")
      local current_dialog = UIManager:getTopmostVisibleWidget()
      if current_dialog and current_dialog.close then
        UIManager:close(current_dialog)
      end
      self_ref_main:showKOAssistantDialogForFile(file, title, authors, book_props)
    end,
  })

  -- Notebook (KOA) button - respects settings
  local show_notebook = features.show_notebook_in_file_browser ~= false  -- default true
  local require_existing = features.notebook_button_require_existing ~= false  -- default true
  if show_notebook and (has_notebook or not require_existing) then
    table.insert(buttons, {
      text = _("Notebook") .. " (KOA)",
      callback = function()
        local UIManager = require("ui/uimanager")
        local current_dialog = UIManager:getTopmostVisibleWidget()
        if current_dialog and current_dialog.close then
          UIManager:close(current_dialog)
        end
        self:openNotebookForFile(file)  -- view mode
      end,
      hold_callback = function()
        local UIManager = require("ui/uimanager")
        local current_dialog = UIManager:getTopmostVisibleWidget()
        if current_dialog and current_dialog.close then
          UIManager:close(current_dialog)
        end
        self:openNotebookForFile(file, true)  -- edit mode
      end,
    })
  end

  -- Chat History (KOA) button - respects settings, only if chats exist
  local show_chat_history = features.show_chat_history_in_file_browser ~= false  -- default true
  if show_chat_history and has_chats then
    table.insert(buttons, {
      text = _("Chat History") .. " (KOA)",
      callback = function()
        local UIManager = require("ui/uimanager")
        local current_dialog = UIManager:getTopmostVisibleWidget()
        if current_dialog and current_dialog.close then
          UIManager:close(current_dialog)
        end
        self:showChatHistoryForFile(file)
      end,
    })
  end

  -- View Artifacts (KOA) button - if any document cache exists for this file
  local show_artifacts = features.show_artifacts_in_file_browser ~= false  -- default true
  local ActionCache = require("koassistant_action_cache")
  local caches = ActionCache.getAvailableArtifacts(file)
  -- Add book metadata for file browser context (no open book)
  for _idx, cache in ipairs(caches) do
    cache.book_title = title
    cache.book_author = authors
    cache.file = file
  end
  -- Refresh artifact index for this document (populates index for pre-existing artifacts)
  if #caches > 0 then
    ActionCache.refreshIndex(file)
  end
  if show_artifacts and #caches > 0 then
    local self_ref = self
    table.insert(buttons, {
      text = (#caches == 1 and (_("View") .. " " .. caches[1].name) or _("View Artifacts")) .. " (KOA)",
      callback = function()
        local UIManager = require("ui/uimanager")
        local current_dialog = UIManager:getTopmostVisibleWidget()
        if current_dialog and current_dialog.close then
          UIManager:close(current_dialog)
        end
        if #caches == 1 then
          local c = caches[1]
          if c.is_per_action then
            self_ref:viewCachedAction({ text = c.name }, c.key, c.data, { file = c.file, book_title = c.book_title, book_author = c.book_author })
          else
            self_ref:showCacheViewer(c)
          end
        else
          local ButtonDialog = require("ui/widget/buttondialog")
          local btn_rows = {}
          for _idx, cache in ipairs(caches) do
            table.insert(btn_rows, {{
              text = cache.name,
              callback = function()
                UIManager:close(self_ref._cache_selector)
                if cache.is_per_action then
                  self_ref:viewCachedAction({ text = cache.name }, cache.key, cache.data, { file = cache.file, book_title = cache.book_title, book_author = cache.book_author })
                else
                  self_ref:showCacheViewer(cache)
                end
              end,
            }})
          end
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
        end
      end,
    })
  end

  -- Pinned file browser actions (user-selected via Action Manager hold menu)
  local fb_actions = self.settings:readSetting("file_browser_actions") or {}
  if #fb_actions > 0 then
    local self_ref = self
    for _idx, fb_action in ipairs(fb_actions) do
      local full_action = self.action_service and self.action_service:getAction("book", fb_action.id)
      table.insert(buttons, {
        text = ActionService.getActionDisplayText(full_action or fb_action, features) .. " (KOA)",
        callback = function()
          local UIManager = require("ui/uimanager")
          local current_dialog = UIManager:getTopmostVisibleWidget()
          if current_dialog and current_dialog.close then
            UIManager:close(current_dialog)
          end
          self_ref:executeFileBrowserAction(file, title, authors, book_props, fb_action.id)
        end,
      })
    end
  end

  -- Split into rows of max 4, equally distributed
  logger.info("KOAssistant: Returning " .. #buttons .. " button(s) in rows")
  return splitIntoRows(buttons, 4)
end

-- Button generator for multiple file selection
function AskGPT:generateMultiSelectButtons(file, is_file, book_props)
  -- Check if we have multiple files selected
  if FileManager.instance and FileManager.instance.selected_files and
     next(FileManager.instance.selected_files) then
    logger.info("KOAssistant: Multiple files selected")
    return {
      {
        text = _("Compare with KOAssistant"),
        callback = function()
          local UIManager = require("ui/uimanager")
          local current_dialog = UIManager:getTopmostVisibleWidget()
          if current_dialog and current_dialog.close then
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
    logger.info("KOAssistant: File dialog buttons already registered, skipping")
    return true
  end

  -- Check if file browser integration is disabled
  local f = self.settings:readSetting("features") or {}
  if f.show_in_file_browser == false then
    logger.info("KOAssistant: File browser integration disabled")
    return true  -- Return true to prevent retry attempts
  end

  logger.info("KOAssistant: Attempting to add file dialog buttons")

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

  local multi_file_generator = function(file, is_file, book_props)
    return self:generateMultiSelectButtons(file, is_file, book_props)
  end

  local success_count = 0

  -- Method 1: Register via instance method if available
  if FileManager.instance and FileManager.instance.addFileDialogButtons then
    local success = pcall(function()
      for slot = 1, 3 do
        FileManager.instance:addFileDialogButtons(row_keys[slot], row_generators[slot])
      end
      FileManager.instance:addFileDialogButtons("zzz_koassistant_multi_select", multi_file_generator)
    end)

    if success then
      logger.info("KOAssistant: File dialog buttons registered via instance method")
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
      logger.info("KOAssistant: Attempting to register buttons on " .. widget_name .. " class")
      local success, err = pcall(function()
        for slot = 1, 3 do
          FileManager.addFileDialogButtons(widget_class, row_keys[slot], row_generators[slot])
        end
        FileManager.addFileDialogButtons(widget_class, "zzz_koassistant_multi_select", multi_file_generator)
      end)

      if success then
        logger.info("KOAssistant: File dialog buttons registered on " .. widget_name)
        success_count = success_count + 1
      else
        logger.warn("KOAssistant: Failed to register buttons on " .. widget_name .. ": " .. tostring(err))
      end
    else
      if not widget_class then
        logger.warn("KOAssistant: Widget class " .. widget_name .. " not loaded")
      else
        logger.warn("KOAssistant: FileManager.addFileDialogButtons not available")
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
    logger.error("KOAssistant: Failed to register file dialog buttons with any method")
    return false
  end
end

function AskGPT:removeFileDialogButtons()
  -- Remove file dialog buttons when plugin is unloaded
  if not self.file_dialog_buttons_added then
    return
  end

  logger.info("KOAssistant: Removing file dialog buttons")

  local FileManagerHistory = require("apps/filemanager/filemanagerhistory")
  local FileManagerCollection = require("apps/filemanager/filemanagercollection")
  local FileManagerFileSearcher = require("apps/filemanager/filemanagerfilesearcher")
  
  -- Remove from instance if available
  if FileManager.instance and FileManager.instance.removeFileDialogButtons then
    pcall(function()
      FileManager.instance:removeFileDialogButtons("zzz_koassistant_1_utilities")
      FileManager.instance:removeFileDialogButtons("zzz_koassistant_2_main")
      FileManager.instance:removeFileDialogButtons("zzz_koassistant_multi_select")
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
        FileManager.removeFileDialogButtons(widget_class, "zzz_koassistant_1_utilities")
        FileManager.removeFileDialogButtons(widget_class, "zzz_koassistant_2_main")
        FileManager.removeFileDialogButtons(widget_class, "zzz_koassistant_multi_select")
      end)
    end
  end

  self.file_dialog_buttons_added = false
  logger.info("KOAssistant: File dialog buttons removed")
end

function AskGPT:checkButtonVisibility()
  -- Check instance buttons
  if FileManager.instance and FileManager.instance.file_dialog_added_buttons then
    logger.info("KOAssistant: FileManager.instance.file_dialog_added_buttons has " ..
                #FileManager.instance.file_dialog_added_buttons .. " entries")
    
    -- List all button generators for debugging (limit to first 10 to avoid spam)
    local count = math.min(10, #FileManager.instance.file_dialog_added_buttons)
    for i = 1, count do
      local entry = FileManager.instance.file_dialog_added_buttons[i]
      local name = ""
      if type(entry) == "table" and entry.name then
        name = entry.name
      elseif type(entry) == "function" then
        name = "function"
      else
        name = "unknown"
      end
      logger.info("KOAssistant: Instance button generator " .. i .. ": " .. name)
    end
  end
  
  -- Check static buttons
  if FileManager.file_dialog_added_buttons then
    logger.info("KOAssistant: FileManager.file_dialog_added_buttons (static) has " ..
                #FileManager.file_dialog_added_buttons .. " entries")
    
    -- List all button generators for debugging
    for i, entry in ipairs(FileManager.file_dialog_added_buttons) do
      local name = ""
      if type(entry) == "table" and entry.name then
        name = entry.name
      elseif type(entry) == "function" then
        -- Try to identify our functions
        local info = debug.getinfo(entry)
        if info and info.source and info.source:find("koassistant.koplugin") then
          name = "koassistant_function"
        else
          name = "function"
        end
      else
        name = tostring(type(entry))
      end
      logger.info("KOAssistant: Static button generator " .. i .. ": " .. name)
    end
  end
  
  -- Note: Cannot check FileManagerHistory/Collection here due to circular dependency
  -- They will be checked when they're actually created
  logger.info("KOAssistant: Button registration complete. History/Collection will see buttons when created.")
end

function AskGPT:showKOAssistantDialogForFile(file, title, authors, book_props)
  -- Normalize multi-author strings (KOReader stores as newline-separated)
  if authors and authors:find("\n") then
    authors = authors:gsub("\n", ", ")
  end
  -- Create book context string (period-separated for clean single-line display)
  local book_context = string.format("Title: %s.", title)
  if authors and authors ~= "" then
    book_context = book_context .. string.format(" Author: %s.", authors)
  end
  if book_props then
    if book_props.series then
      book_context = book_context .. string.format(" Series: %s.", book_props.series)
    end
    if book_props.language then
      book_context = book_context .. string.format(" Language: %s.", book_props.language)
    end
    if book_props.year then
      book_context = book_context .. string.format(" Year: %s.", book_props.year)
    end
  end

  -- Ensure features exists
  configuration.features = configuration.features or {}

  -- Get book context configuration
  local book_context_config = configuration.features.book_context or {
    prompts = {}
  }

  logger.info("Book context has " ..
    (book_context_config.prompts and tostring(table_count(book_context_config.prompts)) or "0") ..
    " prompts defined")

  -- Set context flags on original configuration (no copy needed)
  -- This ensures settings changes are immediately visible
  -- Clear other context flags first
  configuration.features.is_general_context = nil
  configuration.features.is_book_context = true
  configuration.features.is_multi_book_context = nil

  -- Store book metadata for use in prompts
  if book_context and book_context ~= "" then
    configuration.features.book_context = book_context
  end

  -- Store the book metadata for template substitution
  configuration.features.book_metadata = {
    title = title,
    author = authors,
    author_clause = authors ~= "" and string.format(" by %s", authors) or "",
    file = file  -- Add file path for chat saving
  }

  NetworkMgr:runWhenOnline(function()
    self:ensureInitialized()
    -- Make sure we're using the latest configuration
    self:updateConfigFromSettings()
    -- Show dialog with book context instead of highlighted text
    -- Pass book_metadata so action input popup can access file path for artifact viewers
    local book_metadata = configuration.features.book_metadata
    showChatGPTDialog(self.ui, book_context, configuration, nil, self, book_metadata)
  end)
end

function AskGPT:isDocumentFile(file)
  -- Check if the file is a supported document type
  local DocumentRegistry = require("document/documentregistry")
  return DocumentRegistry:hasProvider(file)
end


function AskGPT:compareSelectedBooks(selected_files)
  -- Check if we have selected files
  if not selected_files then
    logger.error("KOAssistant: compareSelectedBooks called with nil selected_files")
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
    logger.info("KOAssistant: Selected file " .. file_count .. ": " .. tostring(file))
  end
  logger.info("KOAssistant: Processing " .. file_count .. " selected files")
  
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

      logger.info("KOAssistant: Book info - Title: " .. tostring(title) .. ", Authors: " .. tostring(authors))

      table.insert(books_info, {
        title = title,
        authors = authors,
        file = file
      })
    else
      logger.warn("KOAssistant: File is not a document: " .. tostring(file))
    end
  end

  logger.info("KOAssistant: Collected info for " .. #books_info .. " books")
  
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
  
  logger.info("KOAssistant: Books list for comparison:")
  for i, book_str in ipairs(books_list) do
    logger.info("  " .. book_str)
  end
  
  -- Build the book context that will be used by the multi_file_browser prompts
  local prompt_text = string.format("Selected %d books for comparison:\n\n%s",
                                    #books_info,
                                    table.concat(books_list, "\n"))

  logger.info("KOAssistant: Book context for comparison: " .. prompt_text)

  -- Ensure features exists
  configuration.features = configuration.features or {}

  -- Set context flags on original configuration (no copy needed)
  -- This ensures settings changes are immediately visible
  -- Clear other context flags first
  configuration.features.is_general_context = nil
  configuration.features.is_book_context = nil
  configuration.features.is_multi_book_context = true

  -- Store the books list as context
  configuration.features.book_context = prompt_text
  configuration.features.books_info = books_info  -- Store the parsed book info for template substitution

  -- Store metadata for template substitution (using first book's info)
  if #books_info > 0 then
    configuration.features.book_metadata = {
      title = books_info[1].title,
      author = books_info[1].authors,
      author_clause = books_info[1].authors ~= "" and string.format(" by %s", books_info[1].authors) or ""
    }
  end

  NetworkMgr:runWhenOnline(function()
    self:ensureInitialized()
    -- Make sure we're using the latest configuration
    self:updateConfigFromSettings()
    -- Pass the prompt as book context with configuration
    -- Use FileManager.instance as the UI context
    local ui_context = self.ui or FileManager.instance
    showChatGPTDialog(ui_context, prompt_text, configuration, nil, self)
  end)
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
          logger.error("KOAssistant: No selected files found for comparison")
          UIManager:show(InfoMessage:new{
            text = _("No files selected for comparison"),
          })
        end
      end,
    },
  }
end

function AskGPT:onDispatcherRegisterActions()
  logger.info("KOAssistant: onDispatcherRegisterActions called")

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
    title = _("KOAssistant: Continue Last Opened Chat"),
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
    title = _("KOAssistant: New Book Chat/Action"),
    general = false,  -- Requires open book
    reader = true,
  })

  -- Book-level reading features (dynamically from in_reading_features flag)
  -- Actions with this flag are automatically registered as gestures
  local reading_actions = self.action_service:getReadingFeaturesActions()
  for _i, action in ipairs(reading_actions) do
    -- Generate gesture ID and event name from action ID
    -- e.g., "xray" -> "koassistant_xray", "KOAssistantXRay"
    local gesture_id = "koassistant_" .. action.id
    local event_name = "KOAssistant" .. action.id:gsub("_(%l)", function(c) return c:upper() end):gsub("^%l", string.upper)

    Dispatcher:registerAction(gesture_id, {
      category = "none",
      event = event_name,
      title = T(_("KOAssistant: %1"), action.text),
      general = false,  -- Book actions require open book
      reader = true,
    })
  end

  -- Register settings change actions (for gestures)
  Dispatcher:registerAction("koassistant_change_primary_language", {
    category = "none",
    event = "KOAssistantChangePrimaryLanguage",
    title = _("KOAssistant: Change Primary Language"),
    general = true
  })

  Dispatcher:registerAction("koassistant_change_translation_language", {
    category = "none",
    event = "KOAssistantChangeTranslationLanguage",
    title = _("KOAssistant: Change Translation Language"),
    general = true
  })

  Dispatcher:registerAction("koassistant_change_provider", {
    category = "none",
    event = "KOAssistantChangeProvider",
    title = _("KOAssistant: Change Provider"),
    general = true
  })

  Dispatcher:registerAction("koassistant_change_model", {
    category = "none",
    event = "KOAssistantChangeModel",
    title = _("KOAssistant: Change Model"),
    general = true
  })

  Dispatcher:registerAction("koassistant_change_behavior", {
    category = "none",
    event = "KOAssistantChangeBehavior",
    title = _("KOAssistant: Change AI Behavior"),
    general = true
  })

  Dispatcher:registerAction("koassistant_ai_settings", {
    category = "none",
    event = "KOAssistantAISettings",
    title = _("KOAssistant: Quick Settings"),
    general = true,
  })

  -- Quick Actions menu - reader mode only
  Dispatcher:registerAction("koassistant_quick_actions", {
    category = "none",
    event = "KOAssistantQuickActions",
    title = _("KOAssistant: Quick Actions"),
    general = false,  -- Requires open book
    reader = true,
  })

  Dispatcher:registerAction("koassistant_action_manager", {
    category = "none",
    event = "KOAssistantActionManager",
    title = _("KOAssistant: Action Manager"),
    general = true,
  })

  Dispatcher:registerAction("koassistant_manage_behaviors", {
    category = "none",
    event = "KOAssistantManageBehaviors",
    title = _("KOAssistant: Behavior Manager"),
    general = true,
  })

  Dispatcher:registerAction("koassistant_manage_domains", {
    category = "none",
    event = "KOAssistantManageDomains",
    title = _("KOAssistant: Domain Manager"),
    general = true,
  })

  Dispatcher:registerAction("koassistant_change_domain", {
    category = "none",
    event = "KOAssistantChangeDomain",
    title = _("KOAssistant: Change Domain"),
    general = true,
  })

  -- Dictionary-related gesture actions
  Dispatcher:registerAction("koassistant_dictionary_popup_manager", {
    category = "none",
    event = "KOAssistantDictionaryPopupManager",
    title = _("KOAssistant: Dictionary Popup Manager"),
    general = true,
  })

  Dispatcher:registerAction("koassistant_change_dictionary_language", {
    category = "none",
    event = "KOAssistantChangeDictionaryLanguage",
    title = _("KOAssistant: Change Dictionary Language"),
    general = true,
  })

  Dispatcher:registerAction("koassistant_toggle_dictionary_bypass", {
    category = "none",
    event = "KOAssistantToggleDictionaryBypass",
    title = _("KOAssistant: Toggle Dictionary Bypass"),
    general = true,
  })

  -- Highlight bypass gesture actions
  Dispatcher:registerAction("koassistant_toggle_highlight_bypass", {
    category = "none",
    event = "KOAssistantToggleHighlightBypass",
    title = _("KOAssistant: Toggle Highlight Bypass"),
    general = true,
  })

  -- Translate current page gesture
  Dispatcher:registerAction("koassistant_translate_page", {
    category = "none",
    event = "KOAssistantTranslatePage",
    title = _("KOAssistant: Translate Current Page"),
    general = false,  -- Requires open book
    reader = true,
    separator = true
  })

  -- Notebook gestures
  -- View current book's notebook (requires open book)
  Dispatcher:registerAction("koassistant_view_notebook", {
    category = "none",
    event = "KOAssistantViewNotebook",
    title = _("KOAssistant: View Notebook"),
    general = false,  -- Requires open book
    reader = true,
  })

  -- Edit current book's notebook (requires open book)
  Dispatcher:registerAction("koassistant_edit_notebook", {
    category = "none",
    event = "KOAssistantEditNotebook",
    title = _("KOAssistant: Edit Notebook"),
    general = false,  -- Requires open book
    reader = true,
  })

  -- Browse all notebooks (general context - works from anywhere)
  Dispatcher:registerAction("koassistant_browse_notebooks", {
    category = "none",
    event = "KOAssistantBrowseNotebooks",
    title = _("KOAssistant: Browse Notebooks"),
    general = true,  -- Only general (no reader flag) so it's not grayed out in file browser
  })

  -- Browse all artifacts (general context - works from anywhere)
  Dispatcher:registerAction("koassistant_browse_artifacts", {
    category = "none",
    event = "KOAssistantBrowseArtifacts",
    title = _("KOAssistant: Browse Artifacts"),
    general = true,
  })

  Dispatcher:registerAction("koassistant_view_caches", {
    category = "none",
    event = "KOAssistantViewCaches",
    title = _("KOAssistant: View Artifacts"),
    general = false,
    reader = true,
  })

  -- Register user-configured action gestures
  -- These are toggled per-action in Action Manager → hold action → "Add to Gesture Menu"
  -- Uses ActionService:getGestureActions() to inject defaults from in_gesture_menu flags
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

  logger.info("KOAssistant: Dispatcher actions registered successfully")
end

function AskGPT:registerToMainMenu()
  -- Add to KOReader's main menu
  if not self.menu_item and self.ui and self.ui.menu then
    self.menu_item = self.ui.menu:registerToMainMenu(self)
    logger.info("Registered KOAssistant to main menu")
  else
    if not self.ui then
      logger.warn("Cannot register to main menu: UI not available")
    elseif not self.ui.menu then
      logger.warn("Cannot register to main menu: Menu not available")
    end
  end
end

function AskGPT:initSettings()
  -- Create settings file path
  self.settings_file = DataStorage:getSettingsDir() .. "/koassistant_settings.lua"
  -- Initialize settings with default values from configuration.lua
  self.settings = LuaSettings:open(self.settings_file)

  -- Set default values if they don't exist
  if not self.settings:has("provider") then
    self.settings:saveSetting("provider", configuration.provider or "anthropic")
  end
  
  if not self.settings:has("model") then
    self.settings:saveSetting("model", configuration.model)
  end
  
  if not self.settings:has("features") then
    self.settings:saveSetting("features", {
      hide_highlighted_text = configuration.features.hide_highlighted_text or false,
      hide_long_highlights = configuration.features.hide_long_highlights or true,
      long_highlight_threshold = configuration.features.long_highlight_threshold or 280,
      translation_language = configuration.features.translation_language or "English",
      debug = configuration.features.debug or false,
      show_debug_in_chat = false,  -- Whether to show debug in chat viewer (independent of console logging)
      auto_save_all_chats = true,  -- Default to auto-save for new installs
      auto_save_chats = true,      -- Default for continued chats
      render_markdown = true,      -- Default to render markdown
      enable_streaming = true,     -- Default to streaming for new installs
      stream_auto_scroll = true,   -- Default to auto-scroll during streaming
      stream_page_scroll = true,   -- Default to page-based scroll (e-ink friendly)
      large_stream_dialog = true,  -- Default to full-screen streaming dialog
      stream_display_interval = 250,  -- ms between display updates (performance tuning)
      -- Behavior settings (new system v0.6+)
      selected_behavior = "standard",  -- Behavior ID: "mini", "standard", "full", or custom ID
      behavior_migrated = true,    -- Mark as already on new system
    })
  end

  -- Migration for existing users: add new settings with defaults
  -- This runs even if features already exists (for users upgrading from older versions)
  local features = self.settings:readSetting("features")
  if features then
    local needs_save = false

    -- Add show_debug_in_chat if missing (separate from console debug)
    if features.show_debug_in_chat == nil then
      features.show_debug_in_chat = false
      needs_save = true
    end

    -- Migrate translate_to to translation_language
    if features.translate_to ~= nil then
      if features.translation_language == nil then
        features.translation_language = features.translate_to
      end
      features.translate_to = nil
      needs_save = true
    end

    -- Clean up removed settings
    if features.use_new_request_format ~= nil then
      features.use_new_request_format = nil
      needs_save = true
    end

    -- Clean up transient flags that should never be persisted
    -- These are set at runtime for dictionary lookups but should not be saved
    if features.compact_view ~= nil then
      features.compact_view = nil
      needs_save = true
      logger.info("KOAssistant: Cleaned up stray compact_view flag")
    end
    if features.minimal_buttons ~= nil then
      features.minimal_buttons = nil
      needs_save = true
      logger.info("KOAssistant: Cleaned up stray minimal_buttons flag")
    end

    -- ONE-TIME migration to new behavior system (v0.6+)
    -- Only runs once, then sets behavior_migrated = true
    if not features.behavior_migrated then
      -- Migrate legacy custom_ai_behavior to custom_behaviors array
      if features.ai_behavior_variant == "custom"
         and features.custom_ai_behavior
         and features.custom_ai_behavior ~= "" then
        features.custom_behaviors = {
          {
            id = "migrated_1",
            name = _("Custom (migrated)"),
            text = features.custom_ai_behavior,
          }
        }
        features.selected_behavior = "migrated_1"
        logger.info("KOAssistant: Migrated custom_ai_behavior to custom_behaviors array")
      elseif features.ai_behavior_variant == "minimal" then
        features.selected_behavior = "minimal"
      else
        features.selected_behavior = "full"
      end
      -- Clean up legacy fields
      features.ai_behavior_variant = nil
      features.behavior_migrated = true
      needs_save = true
      logger.info("KOAssistant: Completed behavior system migration")
    end

    -- ONE-TIME migration: translate_copy_translation_only toggle → translate_copy_content dropdown
    if features.translate_copy_translation_only ~= nil then
      if features.translate_copy_translation_only then
        features.translate_copy_content = "response"
      else
        features.translate_copy_content = "full"
      end
      features.translate_copy_translation_only = nil
      needs_save = true
      logger.info("KOAssistant: Migrated translate_copy_translation_only to translate_copy_content")
    end

    -- Ensure selected_behavior has a value
    if not features.selected_behavior then
      features.selected_behavior = "standard"
      needs_save = true
    end

    -- ONE-TIME migration: old export directory options → new simplified options
    -- book_folder → exports_folder + checkbox
    -- book_folder_custom → custom + checkbox
    if features.export_save_directory == "book_folder" then
      features.export_save_directory = "exports_folder"
      features.export_book_to_book_folder = true
      needs_save = true
      logger.info("KOAssistant: Migrated export_save_directory: book_folder → exports_folder + checkbox")
    elseif features.export_save_directory == "book_folder_custom" then
      features.export_save_directory = "custom"
      features.export_book_to_book_folder = true
      needs_save = true
      logger.info("KOAssistant: Migrated export_save_directory: book_folder_custom → custom + checkbox")
    end

    -- ONE-TIME migration: ui_language_auto boolean → ui_language string
    -- Converts old toggle to new picker format
    if features.ui_language == nil then
      if features.ui_language_auto == false then
        features.ui_language = "en"
        logger.info("KOAssistant: Migrated ui_language_auto=false to ui_language='en'")
      else
        features.ui_language = "auto"
      end
      features.ui_language_auto = nil  -- Clean up old setting
      needs_save = true
    end

    -- ONE-TIME migration: user_languages string → interaction_languages array
    -- Converts old comma-separated string to new array format
    if not features.languages_migrated then
      if features.user_languages and features.user_languages ~= "" then
        -- Parse comma-separated string into array
        local languages = {}
        for lang in features.user_languages:gmatch("([^,]+)") do
          local trimmed = lang:match("^%s*(.-)%s*$")
          if trimmed ~= "" then
            table.insert(languages, trimmed)
          end
        end
        features.interaction_languages = languages
        features.additional_languages = {}  -- Start empty
        logger.info("KOAssistant: Migrated user_languages to interaction_languages array")
      else
        features.interaction_languages = {}
        features.additional_languages = {}
      end
      -- Keep user_languages for backward compatibility during transition
      features.languages_migrated = true
      needs_save = true
    end

    if needs_save then
      self.settings:saveSetting("features", features)
      logger.info("KOAssistant: Migrated settings")
    end
  end

  self.settings:flush()
  
  -- Update the configuration with settings values
  self:updateConfigFromSettings()
end

function AskGPT:updateConfigFromSettings()
  -- Update configuration with values from settings
  -- Provider and model are stored inside features table
  local features = self.settings:readSetting("features") or {}

  configuration.provider = features.provider or "anthropic"
  configuration.model = features.model

  -- Merge settings into existing features table instead of replacing it.
  -- This preserves runtime-only keys (context flags, book_metadata, etc.)
  -- that callers set before the network callback fires.
  -- Skip runtime-only keys that may have leaked into saved settings.
  local runtime_only_keys = {
    is_general_context = true,
    is_book_context = true,
    is_multi_book_context = true,
    book_metadata = true,
    book_context = true,
    books_info = true,
    selection_data = true,
    compact_view = true,
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
  end

  -- Ensure transient flags are cleared (these are only set at runtime for specific actions)
  -- This prevents flags from "leaking" to other actions
  configuration.features.compact_view = nil
  configuration.features.minimal_buttons = nil
  configuration.features.is_full_page_translate = nil  -- Only set by translateCurrentPage

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
  -- Show per-provider reasoning settings
  if features.anthropic_reasoning then
    table.insert(config_parts, "anthropic_thinking=" .. (features.reasoning_budget or 4096))
  end
  if features.openai_reasoning then
    table.insert(config_parts, "openai_reasoning=" .. (features.reasoning_effort or "medium"))
  end
  if features.gemini_reasoning then
    table.insert(config_parts, "gemini_thinking=" .. (features.reasoning_depth or "high"))
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

  logger.info("KOAssistant config: " .. table.concat(config_parts, ", "))
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
        self.settings:saveSetting("features", features)
        self.settings:flush()
        self:updateConfigFromSettings()
      end
      return true
    end
  end
  return false
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
  -- Built-in provider: capitalize first letter
  return provider_id:gsub("^%l", string.upper)
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

  -- Fall back to system default for built-in providers
  local Defaults = require("koassistant_api.defaults")
  local provider_defaults = Defaults.ProviderDefaults[provider]
  if provider_defaults and provider_defaults.model then
    return provider_defaults.model
  end

  return nil
end

-- Helper: Build reading features sub-menu dynamically from actions with in_reading_features flag
-- Used by settings schema - items are built at runtime from action definitions
function AskGPT:buildReadingFeaturesMenu()
  local self_ref = self
  local items = {}
  local features = self.settings:readSetting("features") or {}

  -- Get reading features actions from action service
  local reading_actions = self.action_service:getReadingFeaturesActions()

  for _i, action in ipairs(reading_actions) do
    -- Map action ID to callback name (e.g., "xray" -> "onKOAssistantXray")
    -- Capitalize first letter and handle underscores (e.g., "analyze_highlights" -> "AnalyzeHighlights")
    local callback_name = "onKOAssistant" .. action.id:gsub("_(%l)", function(c) return c:upper() end):gsub("^%l", string.upper)

    -- Look up full action to get data access flags for indicators
    local full_action = self.action_service:getAction("book", action.id)
    table.insert(items, {
      text = ActionService.getActionDisplayText(full_action or action, features),
      info_text = action.info_text,
      callback = function()
        self_ref:executeBookLevelAction(action.id)
      end,
    })
  end

  return items
end

-- Helper: Build provider selection sub-menu
-- @param simplified: if true, shows only provider list without management options (for quick settings)
function AskGPT:buildProviderMenu(simplified)
  local self_ref = self
  local current = self:getCurrentProvider()
  local ModelLists = require("koassistant_model_lists")
  local builtin_providers = ModelLists.getAllProviders()
  local custom_providers = self:getCustomProviders()
  local items = {}

  -- Helper to create provider select callback
  local function createProviderCallback(prov_id, display_name)
    return function()
      local features = self_ref.settings:readSetting("features") or {}
      local old_provider = features.provider

      -- Reset model to new provider's effective default when provider changes
      if old_provider ~= prov_id then
        features.model = self_ref:getEffectiveDefaultModel(prov_id)
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
    end
  end

  -- Build unified list of all providers for sorting
  local all_providers = {}

  -- Add built-in providers
  for _i, provider in ipairs(builtin_providers) do
    table.insert(all_providers, {
      id = provider,
      display_name = provider:gsub("^%l", string.upper),  -- Capitalize
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

  -- Create menu items from sorted list
  for _i, prov in ipairs(all_providers) do
    local prov_copy = prov  -- Capture for closure
    local text = prov.is_custom and ("★ " .. prov.display_name) or prov.display_name
    local item = {
      text = text,
      checked_func = function() return self_ref:getCurrentProvider() == prov_copy.id end,
      radio = true,
      callback = createProviderCallback(prov_copy.id, prov_copy.display_name),
      keep_menu_open = true,
    }

    -- Add hold callback for custom providers
    if prov.is_custom then
      item.hold_callback = function()
        self_ref:showCustomProviderOptions(prov_copy.config)
      end
    end

    table.insert(items, item)
  end

  -- Add management options (only in full mode, not quick settings)
  if not simplified then
    table.insert(items, {
      text = "────────────────────",
      enabled = false,
      callback = function() end,
    })

    -- Add custom provider option
    table.insert(items, {
      text = _("Add custom provider..."),
      callback = function()
        self_ref:showAddCustomProviderDialog()
      end,
      keep_menu_open = false,  -- Close menu for dialog
    })

    -- Manage custom providers (only if there are any)
    if #custom_providers > 0 then
      table.insert(items, {
        text = T(_("Manage custom providers (%1)..."), #custom_providers),
        callback = function()
          self_ref:showManageCustomProvidersMenu()
        end,
        keep_menu_open = false,
      })
    end
  end

  return items
end

-- Helper: Show options for a custom provider (on hold)
function AskGPT:showCustomProviderOptions(provider)
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
        self_ref:showEditCustomProviderDialog(provider)
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

-- Helper: Show dialog to add a new custom provider
function AskGPT:showAddCustomProviderDialog()
  local self_ref = self

  local dialog
  dialog = MultiInputDialog:new{
    title = _("Add Custom Provider"),
    fields = {
      {
        text = "",
        hint = _("Provider name (e.g., LM Studio)"),
      },
      {
        text = "",
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

            local success, result = self_ref:saveCustomProvider({
              name = name,
              base_url = base_url,
              default_model = default_model,
              api_key_required = true,
            })

            if success then
              UIManager:close(dialog)
              UIManager:show(Notification:new{
                text = T(_("Added provider: %1"), name),
                timeout = 1.5,
              })
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
function AskGPT:showEditCustomProviderDialog(provider)
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
          end,
        },
      },
    },
  }
  UIManager:show(dialog)
  dialog:onShowKeyboard()
end

-- Helper: Show menu to manage custom providers
function AskGPT:showManageCustomProvidersMenu()
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
        self_ref:showEditCustomProviderDialog(cp_copy)
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
function AskGPT:buildModelMenu(simplified)
  local self_ref = self
  local provider = self:getCurrentProvider()
  local is_custom_provider = self:isCustomProvider(provider)
  local custom_provider_config = is_custom_provider and self:getCustomProvider(provider) or nil

  -- Get models: built-in providers have model lists, custom providers only have custom models
  local models = {}
  if not is_custom_provider then
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

  -- Helper to create hold callback for model items
  local function createHoldCallback(model, is_custom)
    return function()
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

  -- Helper to build display name with default indicators
  local function buildDisplayName(model, is_custom)
    local display_name = model
    if is_custom then
      display_name = "★ " .. display_name
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

  -- Build unified list of all models (built-in first, then custom)
  local all_models = {}

  -- Add built-in models (preserves order from model lists file)
  for i = 1, #models do
    table.insert(all_models, {
      name = models[i],
      is_custom = false,
    })
  end

  -- Add custom models at the end
  for _idx, model in ipairs(custom_models) do
    table.insert(all_models, {
      name = model,
      is_custom = true,
    })
  end

  -- Create menu items from model list
  for _idx, model_info in ipairs(all_models) do
    local model_copy = model_info.name  -- Capture for closure
    local is_custom = model_info.is_custom

    table.insert(items, {
      text = buildDisplayName(model_copy, is_custom),
      checked_func = function()
        local f = self_ref.settings:readSetting("features") or {}
        local selected = f.model or effective_default
        return selected == model_copy
      end,
      radio = true,
      callback = function()
        local f = self_ref.settings:readSetting("features") or {}
        f.model = model_copy
        self_ref.settings:saveSetting("features", f)
        self_ref.settings:flush()
        self_ref:updateConfigFromSettings()
        UIManager:show(Notification:new{
          text = T(_("Model: %1"), model_copy),
          timeout = 1.5,
        })
      end,
      hold_callback = createHoldCallback(model_copy, is_custom),
      keep_menu_open = true,
    })
  end

  -- Add management options (only in full mode)
  if not simplified then
    -- Add separator before actions
    table.insert(items, {
      text = "────────────",
      enabled = false,
    })

    -- Add custom model input option (now saves to list)
    table.insert(items, {
      text = _("Add custom model..."),
      keep_menu_open = false,  -- Close menu so dialog appears on top
      callback = function()
        -- Delay to let menu close first
        UIManager:scheduleIn(0.1, function()
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
                        -- Select the new model
                        local f = self_ref.settings:readSetting("features") or {}
                        f.model = new_model
                        self_ref.settings:saveSetting("features", f)
                        self_ref.settings:flush()
                        self_ref:updateConfigFromSettings()
                        UIManager:show(Notification:new{
                          text = T(_("Added: %1"), new_model),
                          timeout = 1.5,
                        })
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
        end)
      end,
    })

    -- Add manage custom models option (only if there are custom models)
    if #custom_models > 0 then
      table.insert(items, {
        text = T(_("Manage custom models (%1)..."), #custom_models),
        keep_menu_open = false,  -- Close menu so dialog appears on top
        callback = function()
          -- Delay to let menu close first
          UIManager:scheduleIn(0.1, function()
            self_ref:showManageCustomModelsMenu(provider)
          end)
        end,
      })
    end
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

-- Helper: Show manage custom models menu
function AskGPT:showManageCustomModelsMenu(provider)
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
          end,
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
          end

          self_ref.settings:saveSetting("features", features)
          self_ref.settings:flush()
          self_ref:updateConfigFromSettings()

          UIManager:show(Notification:new{
            text = _("All custom models cleared"),
            timeout = 1.5,
          })
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
  local success, apikeys = pcall(function() return require("apikeys") end)
  if not success or not apikeys or not apikeys[provider] then
    return false
  end
  return not isPlaceholderKey(apikeys[provider])
end

-- Helper: Check if user has any API keys configured (GUI or file), excluding a specific provider
local function hasAnyApiKeys(gui_keys, exclude_provider)
  -- Check GUI keys
  for provider, key in pairs(gui_keys or {}) do
    if provider ~= exclude_provider and key and key ~= "" then
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
    local has_gui_key = gui_keys[provider] and gui_keys[provider] ~= ""
    local has_file_key = hasFileApiKey(provider)
    local status = ""
    if has_gui_key then
      status = " [set]"
    elseif has_file_key then
      status = " (file)"
    end

    table.insert(all_providers, {
      id = provider,
      display_name = provider:gsub("^%l", string.upper),
      status = status,
      is_custom = false,
    })
  end

  -- Add custom providers
  for _i, cp in ipairs(custom_providers) do
    local has_gui_key = gui_keys[cp.id] and gui_keys[cp.id] ~= ""
    local status = ""
    if has_gui_key then
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

  -- Create menu items from sorted list
  for _i, prov in ipairs(all_providers) do
    local prov_copy = prov  -- Capture for closure
    local text = prov.is_custom and ("★ " .. prov.display_name .. prov.status) or (prov.display_name .. prov.status)

    table.insert(items, {
      text = text,
      keep_menu_open = true,
      callback = function()
        self_ref:showApiKeyDialog(prov_copy.id, prov_copy.display_name, prov_copy.api_key_optional)
      end,
    })
  end

  return items
end

-- Show dialog to enter/edit API key for a provider
-- @param provider string: Provider ID
-- @param display_name string: Display name (optional, defaults to capitalized provider)
-- @param key_optional boolean: If true, shows hint that key is optional (for local servers)
function AskGPT:showApiKeyDialog(provider, display_name, key_optional)
  local self_ref = self
  display_name = display_name or provider:gsub("^%l", string.upper)
  local features = self.settings:readSetting("features") or {}
  local gui_keys = features.api_keys or {}
  local current_key = gui_keys[provider] or ""
  local masked = maskApiKey(current_key)
  local has_file_key = hasFileApiKey(provider)

  -- Build hint text
  local hint_text
  if masked ~= "" then
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
          end,
        },
        {
          text = _("Save"),
          is_enter_default = true,
          callback = function()
            local new_key = input_dialog:getInputText()
            if new_key and new_key ~= "" then
              local f = self_ref.settings:readSetting("features") or {}
              f.api_keys = f.api_keys or {}
              -- Check if this is the user's first API key (before saving)
              local is_first_key = not hasAnyApiKeys(f.api_keys, provider)
              f.api_keys[provider] = new_key
              local message = T(_("%1 API key saved"), display_name)
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
      return nil
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
    return nil
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
                                    -- Refresh the menu
                                    if touchmenu_instance then
                                        touchmenu_instance:updateItems()
                                    end
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
                callback = function() toggleLanguage(lang_copy) end,
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
                callback = function() toggleLanguage(lang_copy) end,
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

  for i, lang in ipairs(languages) do
    local is_first = (i == 1)
    local lang_copy = lang  -- Capture for closure
    local lang_display = getLanguageDisplay(lang)

    table.insert(menu_items, {
      text = is_first and lang_display .. " " .. _("(default)") or lang_display,
      checked_func = function()
        return lang_copy == self_ref:getEffectivePrimaryLanguage()
      end,
      radio = true,
      callback = function()
        local f = self_ref.settings:readSetting("features") or {}
        if is_first then
          -- First language = clear override (use default)
          f.primary_language = nil
        else
          f.primary_language = lang_copy
        end
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
    text = T(_("Use Primary (%1)"), getLanguageDisplay(effective_primary)),
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
    callback = function()
      local InputDialog = require("ui/widget/inputdialog")
      local f = self_ref.settings:readSetting("features") or {}
      local input_dialog
      input_dialog = InputDialog:new{
        title = _("Custom Translation Language"),
        input = f.translation_language or "English",
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
                  f.translation_language = new_lang
                  self_ref.settings:saveSetting("features", f)
                  self_ref.settings:flush()
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

-- Build dictionary response language picker menu
function AskGPT:buildDictionaryLanguageMenu()
  local self_ref = self

  local menu_items = {}

  -- Add "Follow Translation" option at top
  table.insert(menu_items, {
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
      UIManager:show(Notification:new{
        text = _("Dictionary: Follow Translation"),
        timeout = 1.5,
      })
    end,
  })

  -- Add "Follow Primary Language" option
  table.insert(menu_items, {
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
      UIManager:show(Notification:new{
        text = _("Dictionary: Follow Primary"),
        timeout = 1.5,
      })
    end,
    separator = true,
  })

  -- Get combined languages (interaction + additional)
  local languages = self:getCombinedLanguages()

  -- Add each language as an option
  for _i, lang in ipairs(languages) do
    local lang_copy = lang
    table.insert(menu_items, {
      text = getLanguageDisplay(lang),
      checked_func = function()
        local f = self_ref.settings:readSetting("features") or {}
        return f.dictionary_language == lang_copy
      end,
      radio = true,
      callback = function()
        local f = self_ref.settings:readSetting("features") or {}
        f.dictionary_language = lang_copy
        self_ref.settings:saveSetting("features", f)
        self_ref.settings:flush()
        UIManager:show(Notification:new{
          text = T(_("Dictionary: %1"), getLanguageDisplay(lang_copy)),
          timeout = 1.5,
        })
      end,
    })
  end

  return menu_items
end

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
        local current = f.dictionary_context_mode or "none"
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
function AskGPT:onDictButtonsReady(dict_popup, dict_buttons)
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
  if non_reader_lookup then
    self.ui.dictionary._koassistant_non_reader_lookup = nil  -- Consume flag
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
        -- FIRST: Capture selection_data for "Save to Note" feature (before popup closes)
        -- The popup being open means selected_text still exists
        local selection_data = nil
        if self_ref.ui and self_ref.ui.highlight and self_ref.ui.highlight.selected_text then
          local st = self_ref.ui.highlight.selected_text
          selection_data = {
            text = st.text,  -- Just the word
            pos0 = st.pos0,
            pos1 = st.pos1,
            sboxes = st.sboxes,
            pboxes = st.pboxes,
            ext = st.ext,
            drawer = st.drawer or "lighten",
            color = st.color or "yellow",
          }
        end

        -- CRITICAL: Extract context BEFORE closing the popup
        -- The highlight/selection is cleared when the popup closes
        -- Extract context only for reader-originated lookups.
        -- Non-reader lookups (ChatGPT viewer, nested dictionary) have no meaningful
        -- book context to extract — the word came from AI-generated or dictionary text.
        local context = ""
        local context_mode = features.dictionary_context_mode or "none"
        local context_chars = features.dictionary_context_chars or 100
        local extraction_mode = (context_mode == "none") and "sentence" or context_mode

        if not non_reader_lookup then
          if self_ref.ui and self_ref.ui.highlight and self_ref.ui.highlight.getSelectedWordContext then
            context = Dialogs.extractSurroundingContext(
              self_ref.ui,
              word,
              extraction_mode,
              context_chars
            )
          end

          if context ~= "" then
            logger.info("KOAssistant DICT: Got context (" .. #context .. " chars)")
          else
            logger.info("KOAssistant DICT: No context available (word tap, not selection)")
          end
        end

        if action.local_handler then
          -- Local actions don't need network or dictionary-specific config
          self_ref:updateConfigFromSettings()
          Dialogs.executeDirectAction(self_ref.ui, action, word, configuration, self_ref)
        else
          -- Ensure network is available
          NetworkMgr:runWhenOnline(function()
            -- Make sure we're using the latest configuration
            self_ref:updateConfigFromSettings()
            -- Get effective dictionary language
            local SystemPrompts = require("prompts.system_prompts")
            local dict_language = SystemPrompts.getEffectiveDictionaryLanguage({
              dictionary_language = features.dictionary_language,
              translation_language = features.translation_language,
              translation_use_primary = features.translation_use_primary,
              interaction_languages = features.interaction_languages,
              user_languages = features.user_languages,
              primary_language = features.primary_language,
            })

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

            -- Clear context flags to ensure highlight context (like executeQuickAction does)
            dict_config.features.is_general_context = nil
            dict_config.features.is_book_context = nil
            dict_config.features.is_multi_book_context = nil

            -- Set dictionary-specific values
            if non_reader_lookup then
              -- Non-reader lookup: no context available, disable CTX toggle
              dict_config.features.dictionary_context = ""
              dict_config.features._original_context = ""
              dict_config.features._no_context_available = true
            else
              -- Only include context in the request if mode is not "none"
              dict_config.features.dictionary_context = (context_mode ~= "none") and context or ""
              -- Always store extracted context so compact view toggle can use it
              dict_config.features._original_context = context
              dict_config.features._original_context_mode = extraction_mode
            end
            dict_config.features.dictionary_language = dict_language
            dict_config.features.dictionary_context_mode = features.dictionary_context_mode or "none"
            -- Store selection_data for "Save to Note" feature (word position only)
            dict_config.features.selection_data = selection_data

            -- Skip auto-save for dictionary if setting is enabled (default: true)
            if features.dictionary_disable_auto_save ~= false then
              dict_config.features.storage_key = "__SKIP__"
            end

            -- Always use compact view for dictionary popup actions
            dict_config.features.compact_view = true
            dict_config.features.hide_highlighted_text = true  -- Hide quote by default in compact mode
            dict_config.features.minimal_buttons = true  -- Use minimal button set
            dict_config.features.large_stream_dialog = false  -- Small streaming dialog

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
              self_ref.ui,   -- ui
              action,        -- action (from closure)
              word,          -- highlighted_text
              dict_config,   -- local config copy (not global)
              self_ref       -- plugin
            )
          end)
        end
      end,
    }
  end

  -- Create buttons arranged in rows of 3
  local plugin_rows = {}
  local current_row = {}

  for _i, action in ipairs(popup_actions) do
    table.insert(current_row, createActionButton(action))
    if #current_row == 3 then
      table.insert(plugin_rows, current_row)
      current_row = {}
    end
  end
  -- Add any remaining buttons in a partial row
  if #current_row > 0 then
    table.insert(plugin_rows, current_row)
  end

  -- Insert all rows at position 2 (after the first row of standard buttons)
  -- Insert in reverse order so they appear in correct order
  for i = #plugin_rows, 1, -1 do
    table.insert(dict_buttons, 2, plugin_rows[i])
  end
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

  logger.info("Continue last saved chat: found chat ID " .. (most_recent_chat.id or "nil") ..
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

  logger.info("Continue last opened chat: found chat ID " .. (last_opened_chat.id or "nil") ..
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

  NetworkMgr:runWhenOnline(function()
    self:ensureInitialized()
    -- Make sure we're using the latest configuration
    self:updateConfigFromSettings()

    -- Set context flag on the original configuration (no copy needed)
    -- This ensures settings changes are immediately visible
    configuration.features = configuration.features or {}
    -- Clear other context flags and book metadata
    configuration.features.is_general_context = true
    configuration.features.is_book_context = nil
    configuration.features.is_multi_book_context = nil
    configuration.features.book_metadata = nil
    configuration.features.books_info = nil

    -- Show dialog with general context
    showChatGPTDialog(self.ui, nil, configuration, nil, self)
  end)
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

--- Execute X-Ray action (book-level reading companion)
function AskGPT:onKOAssistantXray()
  self:executeBookLevelAction("xray")
  return true
end

--- Execute Recap action (story summary for re-immersion)
function AskGPT:onKOAssistantRecap()
  self:executeBookLevelAction("recap")
  return true
end

--- Execute X-Ray (Simple) action (prose companion from AI knowledge)
function AskGPT:onKOAssistantXraySimple()
  self:executeBookLevelAction("xray_simple")
  return true
end

--- Execute Analyze My Notes action (insights from user's annotations)
function AskGPT:onKOAssistantAnalyzeHighlights()
  self:executeBookLevelAction("analyze_highlights")
  return true
end

--- Execute Document Summary action (foundation for Smart actions)
function AskGPT:onKOAssistantSummarizeFullDocument()
  self:executeBookLevelAction("summarize_full_document")
  return true
end

--- Execute Document Analysis action (thesis, structure, insights)
function AskGPT:onKOAssistantAnalyzeFullDocument()
  self:executeBookLevelAction("analyze_full_document")
  return true
end

--- Show available cached content for current document
function AskGPT:viewCache()
  if not self.ui or not self.ui.document or not self.ui.document.file then
    UIManager:show(InfoMessage:new{
      text = _("No book open"),
    })
    return
  end

  local ActionCache = require("koassistant_action_cache")
  local file = self.ui.document.file

  local caches = ActionCache.getAvailableArtifacts(file)

  -- Refresh artifact index for this document (populates index for pre-existing artifacts)
  ActionCache.refreshIndex(file)

  if #caches == 0 then
    UIManager:show(InfoMessage:new{
      text = _("No cached content found for this document.\n\nRun X-Ray, Recap, X-Ray (Simple), Document Summary, or Document Analysis to create reusable caches."),
    })
    return
  end

  -- If only one cache, open directly
  if #caches == 1 then
    if caches[1].is_per_action then
      self:viewCachedAction({ text = caches[1].name }, caches[1].key, caches[1].data)
    else
      self:showCacheViewer(caches[1])
    end
    return
  end

  -- Multiple caches - show selector
  local self_ref = self
  local buttons = {}
  for _idx, cache in ipairs(caches) do
    table.insert(buttons, {{
      text = cache.name,
      callback = function()
        UIManager:close(self_ref._cache_selector)
        if cache.is_per_action then
          self_ref:viewCachedAction({ text = cache.name }, cache.key, cache.data)
        else
          self_ref:showCacheViewer(cache)
        end
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
    title = _("View Artifacts"),
    buttons = buttons,
  }
  UIManager:show(self._cache_selector)
end

--- Format a timestamp as relative time string (e.g., "3d ago", "1m2d ago")
--- @param timestamp number Unix timestamp
--- @return string Relative time string, or empty if invalid
local function formatRelativeTime(timestamp)
  if not timestamp then return "" end
  local now = os.time()
  if now - timestamp < 0 then return "" end
  -- Compare calendar dates (midnight-aligned) to get accurate day counts
  local today_t = os.date("*t", now)
  today_t.hour, today_t.min, today_t.sec = 0, 0, 0
  local cached_t = os.date("*t", timestamp)
  cached_t.hour, cached_t.min, cached_t.sec = 0, 0, 0
  local days = math.floor((os.time(today_t) - os.time(cached_t)) / 86400)
  if days == 0 then
    return _("today")
  elseif days < 30 then
    return string.format(_("%dd ago"), days)
  else
    local months = math.floor(days / 30)
    local years = math.floor(days / 365)
    if years == 0 then
      local rd = days - (months * 30)
      if rd > 0 then
        return string.format(_("%dm%dd ago"), months, rd)
      else
        return string.format(_("%dm ago"), months)
      end
    else
      local rm = months - (years * 12)
      if rm > 0 then
        return string.format(_("%dy%dm ago"), years, rm)
      else
        return string.format(_("%dy ago"), years)
      end
    end
  end
end

--- Format the source label for cache viewers (AI training data vs extracted text)
--- @param used_book_text boolean|nil Whether book text was used to build the cache
--- @return string Label text
local function formatCacheSourceLabel(used_book_text)
  if used_book_text == false then
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
  local date_str = os.date("%Y-%m-%d", timestamp)
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
  table.insert(info_lines, _("Source:") .. " " .. formatCacheSourceLabel(cached_entry.used_book_text))
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
  if show_reasoning and cached_entry.used_reasoning then
    table.insert(indicators, "*[Reasoning/Thinking was used]*")
  end
  if show_web_search and cached_entry.web_search_used then
    table.insert(indicators, "*[Web search was used]*")
  end
  if #indicators > 0 then
    return table.concat(indicators, "\n") .. "\n\n"
  end
  return nil
end

--- Show a specific cache in the viewer
--- @param cache_info table: { name, key, data } where data contains result, progress_decimal, model, timestamp, used_annotations, used_book_text
function AskGPT:showCacheViewer(cache_info)
  local ChatGPTViewer = require("koassistant_chatgptviewer")
  local ActionCache = require("koassistant_action_cache")

  -- Get book metadata from KOReader's merged props (includes user edits from Book Info dialog)
  -- Falls back to cache_info.book_title/book_author (set by file browser when book isn't open)
  local book_title, book_author
  if self.ui then
    local props = self.ui.doc_props
    if props then
      book_title = props.display_title or props.title
      book_author = props.authors
    end
  end
  book_title = book_title or cache_info.book_title
  book_author = book_author or cache_info.book_author

  -- Format title: Type (XX%) - Book Title
  local progress_str
  if cache_info.data.progress_decimal then
    progress_str = math.floor(cache_info.data.progress_decimal * 100 + 0.5) .. "%"
  end
  local title = cache_info.name
  if progress_str then
    title = title .. " (" .. progress_str .. ")"
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
  local cache_type = cache_type_map[cache_info.key] or "cache"

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
  }

  -- Create delete/regenerate callbacks
  -- Delete works from both open book and file browser (via cache_info.file fallback)
  local on_delete = nil
  local on_regenerate = nil
  local file = self.ui and self.ui.document and self.ui.document.file or cache_info.file
  if file then
    local cache_key = cache_info.key
    local cache_name = cache_info.name

    on_delete = function()
      -- Clear the appropriate cache based on key
      if cache_key == "_xray_cache" then
        ActionCache.clearXrayCache(file)
        -- Also clear per-action cache (X-Ray saves to both document and per-action cache)
        ActionCache.clear(file, "xray")
      elseif cache_key == "_analyze_cache" then
        ActionCache.clearAnalyzeCache(file)
        ActionCache.clear(file, "analyze_full_document")
      elseif cache_key == "_summary_cache" then
        ActionCache.clearSummaryCache(file)
        ActionCache.clear(file, "summarize_full_document")
      end
      -- Invalidate file browser row cache so deleted artifacts don't reappear
      self._file_dialog_row_cache = { file = nil, rows = nil }
      UIManager:show(Notification:new{
        text = T(_("%1 deleted"), cache_name),
        timeout = 2,
      })
    end

    -- Summary and Analyze get regenerate buttons when book is open
    if cache_key == "_summary_cache" and self.ui and self.ui.document then
      local self_ref = self
      on_regenerate = function()
        ActionCache.clearSummaryCache(file)
        ActionCache.clear(file, "summarize_full_document")
        self_ref._file_dialog_row_cache = { file = nil, rows = nil }
        self_ref:executeBookLevelAction("summarize_full_document")
      end
    end
    if cache_key == "_analyze_cache" and self.ui and self.ui.document then
      local self_ref = self
      on_regenerate = function()
        ActionCache.clearAnalyzeCache(file)
        ActionCache.clear(file, "analyze_full_document")
        self_ref._file_dialog_row_cache = { file = nil, rows = nil }
        self_ref:executeBookLevelAction("analyze_full_document")
      end
    end
  end

  -- For X-Ray: try structured JSON browser when data is JSON
  if cache_info.key == "_xray_cache" then
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
          book_file = self.ui and self.ui.document and self.ui.document.file or cache_info.file,
          enable_emoji = features.enable_emoji_icons == true,
          cache_metadata = cache_metadata,
          configuration = configuration,
          plugin = self,
          -- Pre-computed display strings for Full View and Info dialog
          source_label = formatCacheSourceLabel(cache_info.data.used_book_text),
          formatted_date = cache_info.data.timestamp and formatDateWithRelative(cache_info.data.timestamp),
          previous_progress = cache_info.data.previous_progress_decimal and
              (math.floor(cache_info.data.previous_progress_decimal * 100 + 0.5) .. "%"),
          progress_decimal = cache_info.data.progress_decimal,
          full_document = cache_info.data.full_document,
          used_reasoning = cache_info.data.used_reasoning,
          web_search_used = cache_info.data.web_search_used,
          info_popup_text = info_popup_text,
        }
        -- Staleness checks (flow config change or reading progress advance)
        local ce_ok, ContextExtractor
        if self.ui and self.ui.document then
            ce_ok, ContextExtractor = pcall(require, "koassistant_context_extractor")
        end

        -- Check if hidden flow config changed since cache was built
        local staleness_shown = false
        if ce_ok and ContextExtractor and self.ui and self.ui.document then
            local cached_flow_fp = cache_info.data.flow_visible_pages
            local current_flow_fp = ContextExtractor.getFlowFingerprint(self.ui.document)
            if cached_flow_fp ~= nil and cached_flow_fp ~= current_flow_fp then
                UIManager:show(Notification:new{
                    text = _("Reading scope changed since this X-Ray was generated. Consider updating."),
                })
                staleness_shown = true
            elseif cached_flow_fp == nil and current_flow_fp ~= nil
                    and cache_info.data.used_book_text ~= false then
                UIManager:show(Notification:new{
                    text = _("Hidden flows active but X-Ray was generated without flow filtering."),
                })
                staleness_shown = true
            end
        end

        XrayBrowser:show(parsed, browser_metadata, self.ui, on_delete)

        -- Progress staleness popup (only if flow staleness wasn't shown
        -- and not suppressed by caller, e.g. showCacheActionPopup already showed update option)
        if not staleness_shown and not cache_info.skip_stale_popup
                and not cache_info.data.full_document
                and ce_ok and ContextExtractor
                and self.ui and self.ui.document
                and cache_info.data.progress_decimal then
            local extractor = ContextExtractor:new(self.ui)
            local current = extractor:getReadingProgress()
            local cached_dec = cache_info.data.progress_decimal
            -- Check session-based dismiss (keyed by book + cached progress)
            local book_file = self.ui.document.file
            local dismissed = self._xray_stale_dismissed
                and self._xray_stale_dismissed[book_file] == cached_dec
            if not dismissed and current.decimal - cached_dec > 0.08 then
                local cache_pct = math.floor(cached_dec * 100 + 0.5)
                local rel_time = formatRelativeTime(cache_info.data.timestamp)
                local info_text = T(_("X-Ray covers to %1%"), cache_pct)
                if rel_time ~= "" then
                    info_text = info_text .. " (" .. rel_time .. ")"
                end
                info_text = info_text .. "\n" .. T(_("You're now at %1%."), current.percent)

                local self_ref = self
                local stale_dialog
                stale_dialog = ButtonDialog:new{
                    title = info_text,
                    buttons = {
                        {{
                            text = T(_("Update X-Ray (to %1)"), current.formatted),
                            callback = function()
                                UIManager:close(stale_dialog)
                                if XrayBrowser.menu then
                                    UIManager:close(XrayBrowser.menu)
                                end
                                local action = self_ref.action_service:getAction("book", "xray")
                                if action then
                                    self_ref:_executeBookLevelActionDirect(action, "xray")
                                end
                            end,
                        }},
                        {{
                            text = _("Don't remind me this session"),
                            callback = function()
                                UIManager:close(stale_dialog)
                                -- Suppress for this session until X-Ray is updated
                                if not self_ref._xray_stale_dismissed then
                                    self_ref._xray_stale_dismissed = {}
                                end
                                self_ref._xray_stale_dismissed[book_file] = cached_dec
                            end,
                        }},
                    },
                }
                UIManager:show(stale_dialog)
            end
        end

        return
      end
    end
  end

  -- Fallback: ChatGPTViewer for legacy markdown caches or non-xray caches
  local inline_prefix = buildInlineIndicators(cache_info.data, configuration)
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
    _plugin = self,
    _ui = self.ui,
    _info_text = info_popup_text,
    _artifact_file = file,
    _artifact_key = cache_info.key,
    _artifact_book_title = book_title,
    _artifact_book_author = book_author,
    _book_open = (self.ui and self.ui.document ~= nil),
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
function AskGPT:_checkRequirements(action)
  if not action.requires then
    return false
  end
  local features
  local hint = action.blocked_hint and ("\n\n" .. action.blocked_hint) or ""
  for _idx, req in ipairs(action.requires) do
    if req == "book_text" then
      -- Per-action gate: use_book_text explicitly overridden to false?
      if action.use_book_text == false then
        UIManager:show(InfoMessage:new{
          text = _("Text extraction is disabled for this action. Re-enable it in the Action Manager.") .. hint,
        })
        return true
      end
      -- Global gate: text extraction enabled?
      features = features or (self.settings and self.settings:readSetting("features") or {})
      if features.enable_book_text_extraction ~= true then
        UIManager:show(InfoMessage:new{
          text = _("Text extraction is required to generate this artifact.\n\nEnable it in Settings → Privacy & Data → Text Extraction.") .. hint,
        })
        return true
      end
    elseif req == "highlights" then
      -- Per-action gate: are both highlight flags explicitly disabled?
      if not action.use_highlights and not action.use_annotations then
        UIManager:show(InfoMessage:new{
          text = _("This action requires highlight or annotation data, but data access is disabled for this action.\n\nRe-enable in Action Manager (hold the action → Edit).") .. hint,
        })
        return true
      end
      -- Global gate: is any highlight-type sharing enabled?
      features = features or (self.settings and self.settings:readSetting("features") or {})
      if features.enable_highlights_sharing ~= true and features.enable_annotations_sharing ~= true then
        UIManager:show(InfoMessage:new{
          text = _("This action requires access to your highlights or annotations.\n\nEnable sharing in Settings → Privacy & Data.") .. hint,
        })
        return true
      end
    end
  end
  return false
end

--- Show a popup for incremental actions that have an existing cached result.
--- Offers "View" (opens cached result) or "Update" (re-runs the action incrementally).
--- Called from executeBookLevelAction() and book chat input field for actions with use_response_caching.
--- @param action table: The action definition
--- @param action_id string: The action ID
--- @param on_update function: Callback to execute the action (update/re-run)
function AskGPT:showCacheActionPopup(action, action_id, on_update)
  local file = self.ui and self.ui.document and self.ui.document.file
  if not file then
    on_update()
    return
  end

  local ActionCache = require("koassistant_action_cache")
  local cached = ActionCache.get(file, action_id)

  -- X-Ray actions: always route to scope popup (handles no-cache and cached scenarios)
  if action.cache_as_xray then
    self:_showXrayScopePopup(action, action_id, on_update, cached)
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
    if self:_checkRequirements(action) then
      return
    end
    on_update()
    return
  end

  local action_name = action.text or action_id

  -- View detail: cached progress + relative time, e.g. "View X-Ray (29%, today)"
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
  dialog = ButtonDialog:new{
    title = action_name .. view_detail,
    buttons = {
      {
        {
          text = T(_("View %1"), action_name .. view_detail),
          callback = function()
            UIManager:close(dialog)
            self_ref:viewCachedAction(action, action_id, cached, { skip_stale_popup = true })
          end,
        },
      },
      {
        {
          text = update_text,
          callback = function()
            UIManager:close(dialog)
            if self_ref:_checkRequirements(action) then return end
            on_update()
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

--- Show X-Ray scope popup: choose between partial (to reading position) or full-document X-Ray.
--- For 100% caches (full-document or partial at 100%), goes directly to viewer.
--- Otherwise handles two cases: no cache, partial cache (< 100%).
--- @param action table: The action definition
--- @param action_id string: The action ID
--- @param on_update function: Callback to execute partial (to reading position) action
--- @param cached_entry table|nil: Existing cached entry, or nil if no cache
function AskGPT:_showXrayScopePopup(action, action_id, on_update, cached_entry)
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

  -- Direct-to-viewer for 100% caches (full-document or partial updated to 100%)
  -- Even if reader turned back pages — the X-Ray is complete, popup is just friction
  if cached_entry and cached_entry.result then
    local cached_pct = cached_entry.progress_decimal or 0
    if cached_entry.full_document or cached_pct >= 0.995 then
      self:viewCachedAction(action, action_id, cached_entry)
      return
    end
  end

  local dialog
  local buttons = {}

  if not cached_entry or not cached_entry.result then
    if self:_checkRequirements(action) then
      return
    end
    -- Generate (to X%) or Generate (entire document)
    local generate_partial_label
    if current_progress then
      generate_partial_label = T(_("Generate %1 (to %2)"), action_name, current_progress.formatted)
    else
      generate_partial_label = T(_("Generate %1"), action_name)
    end
    table.insert(buttons, {{
      text = generate_partial_label,
      callback = function()
        UIManager:close(dialog)
        on_update()
      end,
    }})
    table.insert(buttons, {{
      text = T(_("Generate %1 (entire document)"), action_name),
      callback = function()
        UIManager:close(dialog)
        self_ref:_executeBookLevelActionDirect(action, action_id, { full_document = true })
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
    -- Partial cache (< 100%): View / Update-or-Redo / Update to 100% / Cancel
    local view_detail = ""
    local parts = {}
    if cached_entry.progress_decimal then
      table.insert(parts, math.floor(cached_entry.progress_decimal * 100 + 0.5) .. "%")
    end
    local rel_time = formatRelativeTime(cached_entry.timestamp)
    if rel_time ~= "" then
      table.insert(parts, rel_time)
    end
    if #parts > 0 then
      view_detail = " (" .. table.concat(parts, ", ") .. ")"
    end

    -- Determine update vs redo based on progress delta
    local update_text
    local cached_progress = cached_entry.progress_decimal or 0
    if current_progress and current_progress.decimal > cached_progress + 0.01 then
      update_text = T(_("Update %1 (to %2)"), action_name, current_progress.formatted)
    elseif current_progress then
      update_text = T(_("Redo %1 (to %2)"), action_name, current_progress.formatted)
    else
      update_text = T(_("Redo %1"), action_name)
    end

    table.insert(buttons, {{
      text = T(_("View %1"), action_name .. view_detail),
      callback = function()
        UIManager:close(dialog)
        self_ref:viewCachedAction(action, action_id, cached_entry, { skip_stale_popup = true })
      end,
    }})
    table.insert(buttons, {{
      text = update_text,
      callback = function()
        UIManager:close(dialog)
        if self_ref:_checkRequirements(action) then return end
        on_update()
      end,
    }})
    -- "Update to 100%": normal incremental update with progress override (same spoiler-free prompt)
    -- Only shown when reader isn't already near 100% (otherwise the regular Update button covers it)
    if not current_progress or current_progress.decimal < 0.995 then
      table.insert(buttons, {{
        text = T(_("Update %1 (to %2)"), action_name, "100%"),
        callback = function()
          UIManager:close(dialog)
          if self_ref:_checkRequirements(action) then return end
          self_ref:_executeBookLevelActionDirect(action, action_id, { update_to_full = true })
        end,
      }})
    end
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
    local info = { name = "X-Ray", key = "_xray_cache", data = cached_entry }
    if opts then info.file = opts.file; info.book_title = opts.book_title; info.book_author = opts.book_author end
    if opts and opts.skip_stale_popup then info.skip_stale_popup = true end
    self:showCacheViewer(info)
    return
  end
  if action.cache_as_analyze then
    local info = { name = _("Analysis"), key = "_analyze_cache", data = cached_entry }
    if opts then info.file = opts.file; info.book_title = opts.book_title; info.book_author = opts.book_author end
    self:showCacheViewer(info)
    return
  end
  if action.cache_as_summary then
    local info = { name = _("Summary"), key = "_summary_cache", data = cached_entry }
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

  -- Generic viewer for per-action caches (e.g., Recap)
  local ChatGPTViewer = require("koassistant_chatgptviewer")
  local action_name = action.text or action_id

  -- Build title (same pattern as showCacheViewer)
  local progress_str
  if cached_entry.progress_decimal then
    progress_str = math.floor(cached_entry.progress_decimal * 100 + 0.5) .. "%"
  end
  local title = action_name
  if progress_str then
    title = title .. " (" .. progress_str .. ")"
  end
  -- Book metadata: from open book or opts fallback (file browser)
  local book_title, book_author
  if self.ui then
    local props = self.ui.doc_props
    if props then
      book_title = props.display_title or props.title
      book_author = props.authors
    end
  end
  if not book_title and opts then
    book_title = opts.book_title
  end
  if not book_author and opts then
    book_author = opts.book_author
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
  }

  -- Delete callback (open book or file browser via opts.file)
  local on_delete
  local file = self.ui and self.ui.document and self.ui.document.file or (opts and opts.file)
  if file then
    local ActionCache = require("koassistant_action_cache")
    on_delete = function()
      ActionCache.clear(file, action_id)
      -- Invalidate file browser row cache so deleted artifacts don't reappear
      self._file_dialog_row_cache = { file = nil, rows = nil }
      UIManager:show(require("ui/widget/notification"):new{
        text = T(_("%1 deleted"), action_name),
        timeout = 2,
      })
    end
  end

  -- Update/Regenerate button: only when book is open (file browser gets "Open" button instead)
  local on_regenerate
  local regenerate_label
  if action.use_response_caching and not action.update_prompt
      and self.ui and self.ui.document then
    local self_ref2 = self
    local captured_action_id = action_id
    on_regenerate = function()
      local AC = require("koassistant_action_cache")
      AC.clear(file, captured_action_id)
      self_ref2._file_dialog_row_cache = { file = nil, rows = nil }
      self_ref2:executeBookLevelAction(captured_action_id)
    end
    -- Position-relevant actions get "Update", position-irrelevant get "Regenerate"
    regenerate_label = action.use_reading_progress and _("Update") or _("Regenerate")
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
  }
  UIManager:show(viewer)
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

  -- For incremental actions with existing cache: show View/Update popup
  if action.use_response_caching then
    local self_ref = self
    self:showCacheActionPopup(action, action_id, function()
      self_ref:_executeBookLevelActionDirect(action, action_id)
    end)
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
  -- Update to 100%: override progress to 1.0 (same spoiler-free prompt, no schema change)
  if opts and opts.update_to_full then
    config_copy.features._update_to_full_progress = true
  end

  -- Get book metadata from KOReader's merged props (includes user edits from Book Info dialog)
  local doc_props = self.ui.doc_props or {}
  local title = doc_props.display_title or doc_props.title or "Unknown"
  local authors = doc_props.authors or ""
  -- Normalize multi-author strings (KOReader stores as newline-separated)
  if authors:find("\n") then
    authors = authors:gsub("\n", ", ")
  end
  config_copy.features.book_metadata = {
    title = title,
    author = authors,
    author_clause = (authors ~= "") and (" by " .. authors) or "",
  }

  -- Build book context string for display at top of chat viewer
  local book_context = string.format("Title: %s.", title)
  if authors ~= "" then
    book_context = book_context .. string.format(" Author: %s.", authors)
  end
  if doc_props.language then
    book_context = book_context .. string.format(" Language: %s.", doc_props.language)
  end
  config_copy.features.book_context = book_context

  -- Execute the action with book context as highlighted text
  NetworkMgr:runWhenOnline(function()
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
  configuration.features.is_multi_book_context = nil
  configuration.features.book_metadata = {
    title = title,
    author = authors,
    author_clause = (authors and authors ~= "") and (" by " .. authors) or "",
    file = file,
  }

  -- Build book context string for display at top of chat viewer
  local book_context = string.format("Title: %s.", title)
  if authors and authors ~= "" then
    book_context = book_context .. string.format(" Author: %s.", authors)
  end
  if book_props then
    if book_props.language then
      book_context = book_context .. string.format(" Language: %s.", book_props.language)
    end
  end
  configuration.features.book_context = book_context

  NetworkMgr:runWhenOnline(function()
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

    Dialogs.executeDirectAction(self.ui, action, book_context, config_copy, self)
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
  -- Clear book metadata for general context
  config_copy.features.is_general_context = true
  config_copy.features.book_metadata = nil
  config_copy.features.books_info = nil

  -- Execute the action
  NetworkMgr:runWhenOnline(function()
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
  logger.info("KOAssistant: Opening settings via menu traversal")

  -- Determine Tools tab index (3 in FileManager, 4 in Reader)
  local tools_tab_index = self.ui.document and 4 or 3

  -- Show main menu at Tools tab, then traverse to KOAssistant
  if self.ui.menu and self.ui.menu.onShowMenu then
    self.ui.menu:onShowMenu(tools_tab_index)

    -- Schedule menu item selection after menu is shown
    UIManager:scheduleIn(0.2, function()
      local menu_container = self.ui.menu.menu_container
      if menu_container and menu_container[1] then
        local touch_menu = menu_container[1]
        local menu_items = touch_menu.item_table
        if menu_items then
          for i = 1, #menu_items do
            local item = menu_items[i]
            if item.text == _("KOAssistant") then
              touch_menu:onMenuSelect(item)
              return
            end
          end
        end
      end
    end)
  end

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
    if item.text then
      local is_checked = item.checked_func and item.checked_func()
      local text = item.text
      if is_checked then
        text = "✓ " .. text
      end
      table.insert(buttons, {
        {
          text = text,
          callback = function()
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
        },
      })
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

--- Event handlers for gesture-accessible settings changes

function AskGPT:onKOAssistantChangePrimaryLanguage()
  local menu_items = self:buildPrimaryLanguageMenu()
  self:showQuickSettingsPopup(_("Primary Language"), menu_items)
  return true
end

function AskGPT:onKOAssistantChangeTranslationLanguage()
  local menu_items = self:buildTranslationLanguageMenu()
  self:showQuickSettingsPopup(_("Translation Language"), menu_items)
  return true
end

function AskGPT:onKOAssistantChangeProvider()
  local menu_items = self:buildProviderMenu(true)  -- simplified mode for quick access
  self:showQuickSettingsPopup(_("Provider"), menu_items)
  return true
end

function AskGPT:onKOAssistantChangeModel()
  local menu_items = self:buildModelMenu(true)  -- simplified mode for quick access
  self:showQuickSettingsPopup(_("Model"), menu_items)
  return true
end

function AskGPT:onKOAssistantChangeBehavior()
  local menu_items = self:buildBehaviorMenu()
  self:showQuickSettingsPopup(_("AI Behavior"), menu_items)
  return true
end

--- Build behavior variant menu (for gesture action)
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
  local self_ref = self

  -- Helper to reopen this dialog after sub-dialog closes
  local function reopenQuickSettings()
    UIManager:scheduleIn(0.1, function()
      self_ref:onKOAssistantAISettings(on_close_callback)
    end)
  end

  local features = self.settings:readSetting("features") or {}
  local provider = features.provider or "anthropic"
  local provider_display = self:getProviderDisplayName(provider)
  local model = self:getCurrentModel() or "default"
  local behavior_id = features.selected_behavior or "standard"
  local temp = features.default_temperature or 0.7
  local streaming = features.enable_streaming ~= false  -- Default true
  local reasoning_enabled = features.enable_reasoning == true  -- Default false
  local web_search = features.enable_web_search == true  -- Default false

  -- Get behavior display name (with source indicator)
  local custom_behaviors = features.custom_behaviors or {}
  local behavior_info = SystemPrompts.getBehaviorById(behavior_id, custom_behaviors)
  local behavior_display = behavior_info and behavior_info.display_name or behavior_id

  -- Get domain display name (with source indicator)
  local domain_id = features.selected_domain
  local domain_display = _("None")
  if domain_id then
    local custom_domains = features.custom_domains or {}
    local domain = DomainLoader.getDomainById(domain_id, custom_domains)
    if domain then
      domain_display = domain.display_name or domain.name or domain_id
    end
  end

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
    text = T(_("Provider: %1"), provider_display),
    callback = function()
      opening_subdialog = true
      UIManager:close(dialog)
      local menu_items = self_ref:buildProviderMenu(true)
      self_ref:showQuickSettingsPopup(_("Provider"), menu_items, true, reopenQuickSettings)
    end,
  }

  button_defs["model"] = {
    text = T(_("Model: %1"), model),
    callback = function()
      opening_subdialog = true
      UIManager:close(dialog)
      local menu_items = self_ref:buildModelMenu(true)
      self_ref:showQuickSettingsPopup(_("Model"), menu_items, true, reopenQuickSettings)
    end,
  }

  button_defs["behavior"] = {
    text = T(_("Behavior: %1"), behavior_display),
    callback = function()
      opening_subdialog = true
      UIManager:close(dialog)
      local menu_items = self_ref:buildBehaviorMenu()
      self_ref:showQuickSettingsPopup(_("AI Behavior"), menu_items, true, reopenQuickSettings)
    end,
  }

  button_defs["domain"] = {
    text = T(_("Domain: %1"), domain_display),
    callback = function()
      opening_subdialog = true
      UIManager:close(dialog)
      local menu_items = self_ref:buildDomainMenu()
      self_ref:showQuickSettingsPopup(_("Knowledge Domain"), menu_items, true, reopenQuickSettings)
    end,
  }

  button_defs["temperature"] = {
    text = T(_("Temp: %1"), string.format("%.1f", temp)),
    callback = function()
      opening_subdialog = true
      UIManager:close(dialog)
      local spin = SpinWidget:new{
        value = temp,
        value_min = 0,
        value_max = 2,
        value_step = 0.1,
        precision = "%.1f",
        ok_text = _("Set"),
        title_text = _("Temperature"),
        default_value = 0.7,
        callback = function(spin_widget)
          local f = self_ref.settings:readSetting("features") or {}
          f.default_temperature = spin_widget.value
          self_ref.settings:saveSetting("features", f)
          self_ref.settings:flush()
          self_ref:updateConfigFromSettings()
          reopenQuickSettings()
        end,
      }
      UIManager:show(spin)
    end,
  }

  button_defs["extended_thinking"] = {
    text = reasoning_enabled and _("Anthropic/Gemini Reasoning: ON") or _("Anthropic/Gemini Reasoning: OFF"),
    callback = function()
      local f = self_ref.settings:readSetting("features") or {}
      f.enable_reasoning = not f.enable_reasoning
      self_ref.settings:saveSetting("features", f)
      self_ref.settings:flush()
      self_ref:updateConfigFromSettings()
      opening_subdialog = true
      UIManager:close(dialog)
      reopenQuickSettings()
    end,
  }

  button_defs["web_search"] = {
    text = web_search and _("Web Search: ON") or _("Web Search: OFF"),
    callback = function()
      local f = self_ref.settings:readSetting("features") or {}
      f.enable_web_search = not f.enable_web_search
      self_ref.settings:saveSetting("features", f)
      self_ref.settings:flush()
      self_ref:updateConfigFromSettings()
      opening_subdialog = true
      UIManager:close(dialog)
      reopenQuickSettings()
    end,
  }

  button_defs["language"] = {
    text = T(_("Language: %1"), lang_display),
    callback = function()
      opening_subdialog = true
      UIManager:close(dialog)
      local menu_items = self_ref:buildPrimaryLanguageMenu()
      self_ref:showQuickSettingsPopup(_("Primary Language"), menu_items, true, reopenQuickSettings)
    end,
  }

  button_defs["translation_language"] = {
    text = T(_("Translate: %1"), trans_display),
    callback = function()
      opening_subdialog = true
      UIManager:close(dialog)
      local menu_items = self_ref:buildTranslationLanguageMenu()
      self_ref:showQuickSettingsPopup(_("Translation Language"), menu_items, true, reopenQuickSettings)
    end,
  }

  button_defs["dictionary_language"] = {
    text = T(_("Dictionary: %1"), dict_display),
    callback = function()
      opening_subdialog = true
      UIManager:close(dialog)
      local menu_items = self_ref:buildDictionaryLanguageMenu()
      self_ref:showQuickSettingsPopup(_("Dictionary Language"), menu_items, true, reopenQuickSettings)
    end,
  }

  button_defs["h_bypass"] = {
    text = highlight_bypass and _("H.Bypass: ON") or _("H.Bypass: OFF"),
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
  }

  button_defs["d_bypass"] = {
    text = dict_bypass and _("D.Bypass: ON") or _("D.Bypass: OFF"),
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
  }

  button_defs["chat_history"] = {
    text = _("Chat History"),
    callback = function()
      opening_subdialog = true
      UIManager:close(dialog)
      self_ref:showChatHistory()
    end,
  }

  button_defs["browse_notebooks"] = {
    text = _("Browse Notebooks"),
    callback = function()
      opening_subdialog = true
      UIManager:close(dialog)
      self_ref:onKOAssistantBrowseNotebooks()
    end,
  }

  button_defs["browse_artifacts"] = {
    text = _("Browse Artifacts"),
    callback = function()
      opening_subdialog = true
      UIManager:close(dialog)
      self_ref:onKOAssistantBrowseArtifacts()
    end,
  }

  button_defs["general_chat"] = {
    text = _("General Chat/Action"),
    callback = function()
      opening_subdialog = true
      UIManager:close(dialog)
      self_ref:startGeneralChat()
    end,
  }

  button_defs["continue_last_chat"] = {
    text = _("Continue Last Chat"),
    callback = function()
      opening_subdialog = true
      UIManager:close(dialog)
      self_ref:onKOAssistantContinueLastOpened()
    end,
  }

  button_defs["manage_actions"] = {
    text = _("Manage Actions"),
    callback = function()
      opening_subdialog = true
      UIManager:close(dialog)
      self_ref:showPromptsManager()
    end,
  }

  button_defs["more_settings"] = {
    text = _("More Settings..."),
    callback = function()
      opening_subdialog = true
      UIManager:close(dialog)
      self_ref:onKOAssistantSettings()
    end,
  }

  -- Dynamic items (only when book is open)
  if has_document then
    button_defs["new_book_chat"] = {
      text = _("New Book Chat/Action"),
      callback = function()
        opening_subdialog = true
        UIManager:close(dialog)
        self_ref:onKOAssistantBookChat()
      end,
    }

    button_defs["quick_actions"] = {
      text = _("Quick Actions..."),
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
      table.insert(all_buttons, button_defs[item_id])
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

  dialog = TitledButtonDialog:new{
    title = _("Quick Settings"),
    buttons = buttons,
    left_icon_tap_callback = function()
      opening_subdialog = true
      UIManager:close(dialog)
      PromptsManager:new(self_ref):showQsItemsManager()
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

  -- Helper to add a button to current row, flush row when full
  local function addButton(btn)
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
        callback = function()
          UIManager:close(dialog)
          self_ref:executeBookLevelAction(action_id)
        end,
      })
    end
  end

  -- 2. Utility items (configurable via Settings → Quick Actions Settings → Panel Utilities)
  -- Order driven by stored qa_utilities_order (user-sortable)
  local ActionCache = require("koassistant_action_cache")
  local file = self.ui.document.file

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
          -- Single "Artifacts" button — opens cache picker (skips list if only one)
          local has_any_cache = #ActionCache.getAvailableArtifacts(file) > 0
          if has_any_cache then
            addButton({
              text = _("View Artifacts"),
              callback = function()
                UIManager:close(dialog)
                self_ref:viewCache()
              end,
            })
          end
        else
          -- Standard utility button
          local display_text = Constants.getQuickActionUtilityText(util_id, _)
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
            UIManager:close(dialog)
            PromptsManager:new(self_ref):showQuickActionsManager()
          end }},
          {{ text = _("Panel Utilities"), callback = function()
            UIManager:close(chooser_dialog)
            UIManager:close(dialog)
            PromptsManager:new(self_ref):showQaUtilitiesManager()
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
    end)
  end)
end

--- Clear action cache for the current book
-- Called from Settings → Advanced → Book Text Extraction → Clear Action Cache
function AskGPT:clearActionCache()
  local InfoMessage = require("ui/widget/infomessage")
  local UIManager = require("ui/uimanager")
  local ButtonDialog = require("ui/widget/buttondialog")
  local ActionCache = require("koassistant_action_cache")

  -- Check if we're in reader mode with an open book
  local ui = self.ui
  if not ui or not ui.document or not ui.document.file then
    UIManager:show(InfoMessage:new{
      text = _("No book is currently open.\n\nOpen a book first, then use this option to clear its cached action responses."),
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
      text = _("No action cache found for this book.\n\nRun an artifact action (X-Ray, Recap, Summarize, etc.) to create a cache."),
      timeout = 3,
    })
    return
  end

  -- Confirm before clearing
  local dialog
  dialog = ButtonDialog:new{
    title = _("Clear Action Cache"),
    text = _("Clear all cached action responses for this book?\n\nThis removes X-Ray, Recap, Summarize, Analyze, and X-Ray (Simple) caches. Next time you run these actions, they will regenerate from scratch."),
    buttons = {
      {
        {
          text = _("Cancel"),
          callback = function()
            UIManager:close(dialog)
          end,
        },
        {
          text = _("Clear Cache"),
          callback = function()
            UIManager:close(dialog)
            local success = ActionCache.clearAll(document_path)
            -- Invalidate file browser row cache
            self._file_dialog_row_cache = { file = nil, rows = nil }
            if success then
              UIManager:show(InfoMessage:new{
                text = _("Action cache cleared successfully."),
                timeout = 2,
              })
            else
              UIManager:show(InfoMessage:new{
                text = _("Failed to clear action cache."),
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
  local menu_items = self:buildDomainMenu()
  self:showQuickSettingsPopup(_("Knowledge Domain"), menu_items)
  return true
end

--- Build domain menu (for gesture action)
--- Shows available domains for quick selection
function AskGPT:buildDomainMenu()
  local DomainLoader = require("domain_loader")
  local self_ref = self

  local features = self.settings:readSetting("features") or {}
  local custom_domains = features.custom_domains or {}
  local all_domains = DomainLoader.getSortedDomains(custom_domains)  -- Returns sorted array

  local items = {}

  -- Add "None" option first
  table.insert(items, {
    text = _("None"),
    checked_func = function()
      local f = self_ref.settings:readSetting("features") or {}
      return not f.selected_domain
    end,
    radio = true,
    callback = function()
      local f = self_ref.settings:readSetting("features") or {}
      f.selected_domain = nil
      self_ref.settings:saveSetting("features", f)
      self_ref.settings:flush()
      self_ref:updateConfigFromSettings()
    end,
  })

  -- Add all available domains
  for _idx, domain in ipairs(all_domains) do
    local domain_copy = domain
    table.insert(items, {
      text = domain_copy.display_name or domain_copy.name or domain_copy.id,
      checked_func = function()
        local f = self_ref.settings:readSetting("features") or {}
        return f.selected_domain == domain_copy.id
      end,
      radio = true,
      callback = function()
        local f = self_ref.settings:readSetting("features") or {}
        f.selected_domain = domain_copy.id
        self_ref.settings:saveSetting("features", f)
        self_ref.settings:flush()
        self_ref:updateConfigFromSettings()
      end,
    })
  end

  return items
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

  local document = self.ui.document
  local page_text = nil

  -- Detect document type: CRE (EPUB) vs PDF/DjVu
  local is_cre_document = document.getXPointer ~= nil

  if is_cre_document then
    -- EPUB/CRE documents: use screen positions approach
    -- getTextBoxes is not implemented for CRE, so we use getTextFromPositions
    -- with the full screen area
    logger.info("KOAssistant: Translate page - CRE document detected")

    local view_dimen = self.ui.view and self.ui.view.dimen
    if view_dimen then
      -- Get text from top-left to bottom-right of visible area
      local pos0 = { x = 0, y = 0 }
      local pos1 = { x = view_dimen.w, y = view_dimen.h }

      local result = document:getTextFromPositions(pos0, pos1, true) -- true = don't draw selection
      if result and result.text and result.text ~= "" then
        page_text = result.text
        logger.info("KOAssistant: Got CRE page text:", #page_text, "chars")
      end
    end

    -- Fallback: try getTextFromXPointer for partial content
    if (not page_text or page_text == "") and document.getTextFromXPointer then
      local xp = document:getXPointer()
      if xp then
        local text = document:getTextFromXPointer(xp)
        if text and text ~= "" then
          page_text = text
          logger.info("KOAssistant: Got CRE page text via XPointer:", #page_text, "chars")
        end
      end
    end
  else
    -- PDF/DjVu documents: use getTextBoxes approach
    logger.info("KOAssistant: Translate page - PDF/DjVu document detected")

    local current_page = self.ui:getCurrentPage()
    if not current_page then
      UIManager:show(InfoMessage:new{
        text = _("Cannot determine current page"),
        timeout = 2,
      })
      return
    end

    local text_boxes = document:getTextBoxes(current_page)
    if text_boxes and #text_boxes > 0 then
      local lines = {}
      for _line_idx, line in ipairs(text_boxes) do
        local words = {}
        for _word_idx, word_box in ipairs(line) do
          if word_box.word then
            table.insert(words, word_box.word)
          end
        end
        if #words > 0 then
          table.insert(lines, table.concat(words, " "))
        end
      end
      page_text = table.concat(lines, "\n")
      logger.info("KOAssistant: Got PDF page text:", #page_text, "chars from", #lines, "lines")
    end

    -- Fallback: try getTextFromPositions with text box bounds
    if (not page_text or page_text == "") and text_boxes and #text_boxes > 0 then
      local first_line = text_boxes[1]
      local last_line = text_boxes[#text_boxes]
      if first_line and #first_line > 0 and last_line and #last_line > 0 then
        local first_word = first_line[1]
        local last_word = last_line[#last_line]
        if first_word and last_word then
          local pos0 = { x = first_word.x0 or 0, y = first_word.y0 or 0, page = current_page }
          local pos1 = { x = last_word.x1 or 0, y = last_word.y1 or 0, page = current_page }
          local result = document:getTextFromPositions(pos0, pos1)
          if result and result.text then
            page_text = result.text
            logger.info("KOAssistant: Got PDF page text via positions:", #page_text, "chars")
          end
        end
      end
    end
  end

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
  -- Clear context flags to ensure highlight context
  config_copy.features.is_general_context = nil
  config_copy.features.is_book_context = nil
  config_copy.features.is_multi_book_context = nil
  -- Explicitly ensure full view (not compact)
  config_copy.features.compact_view = false
  config_copy.features.minimal_buttons = false
  -- Mark this as full page translate so handlePredefinedPrompt can apply translate_hide_full_page setting
  -- Note: The actual hiding is handled in handlePredefinedPrompt which respects user's translate_hide_highlight_mode
  config_copy.features.is_full_page_translate = true
  -- Clear selection_data - there's no actual user highlight for page translation,
  -- so the "Save to Note" button should be disabled (prevents using stale data from prior highlights)
  config_copy.features.selection_data = nil

  -- Execute translation
  logger.info("KOAssistant: translateCurrentPage calling executeDirectAction with page_text:", page_text and #page_text or "nil/empty")
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
      return f.dictionary_language == nil or f.dictionary_language == "__FOLLOW_TRANSLATION__"
    end,
    radio = true,
    callback = function()
      local f = self_ref.settings:readSetting("features") or {}
      f.dictionary_language = "__FOLLOW_TRANSLATION__"
      self_ref.settings:saveSetting("features", f)
      self_ref.settings:flush()
      self_ref:updateConfigFromSettings()
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
    end,
    separator = true,
  })

  -- Get combined languages (interaction + additional)
  local languages = self:getCombinedLanguages()

  -- Add each language as an option
  for _i, lang in ipairs(languages) do
    local lang_copy = lang
    table.insert(items, {
      text = getLanguageDisplay(lang_copy),
      checked_func = function()
        local f = self_ref.settings:readSetting("features") or {}
        return f.dictionary_language == lang_copy
      end,
      radio = true,
      callback = function()
        local f = self_ref.settings:readSetting("features") or {}
        f.dictionary_language = lang_copy
        self_ref.settings:saveSetting("features", f)
        self_ref.settings:flush()
        self_ref:updateConfigFromSettings()
      end,
    })
  end

  -- Add common fallback if no languages configured
  if #languages == 0 then
    local fallback_languages = {"English", "Spanish", "French", "German", "Chinese", "Japanese", "Korean"}
    for _idx, lang in ipairs(fallback_languages) do
      local lang_copy = lang
      table.insert(items, {
        text = getLanguageDisplay(lang_copy),
        checked_func = function()
          local f = self_ref.settings:readSetting("features") or {}
          return f.dictionary_language == lang_copy
        end,
        radio = true,
        callback = function()
          local f = self_ref.settings:readSetting("features") or {}
          f.dictionary_language = lang_copy
          self_ref.settings:saveSetting("features", f)
          self_ref.settings:flush()
          self_ref:updateConfigFromSettings()
        end,
      })
    end
  end

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

-- Show PathChooser for custom export path
function AskGPT:showExportPathPicker()
  local PathChooser = require("ui/widget/pathchooser")

  local features = self.settings:readSetting("features") or {}
  -- Use KOReader's fallback chain: home_dir setting → Device.home_dir → DataStorage
  local start_path = G_reader_settings:readSetting("home_dir") or Device.home_dir or DataStorage:getDataDir()
  local current_path = features.export_custom_path or start_path

  local path_chooser = PathChooser:new{
    title = _("Select Export Folder"),
    path = current_path,
    select_directory = true,
    onConfirm = function(selected_path)
      features.export_custom_path = selected_path
      self.settings:saveSetting("features", features)
      UIManager:show(InfoMessage:new{
        text = T(_("Export path set to:\n%1"), selected_path),
        timeout = 3,
      })
    end,
  }
  UIManager:show(path_chooser)
end

-- Register quick actions for highlight menu
-- Called during init to add user-configured actions directly to the highlight popup
function AskGPT:registerHighlightMenuActions()
  if not self.ui or not self.ui.highlight then return end

  -- Check if highlight quick actions are disabled
  local features = self.settings:readSetting("features") or {}
  if features.show_quick_actions_in_highlight == false then
    logger.info("KOAssistant: Highlight quick actions disabled")
    return
  end

  -- Filter out actions requiring open book if no book is open (should always be true in highlight menu)
  local has_open_book = self.ui and self.ui.document ~= nil
  local document_path = has_open_book and self.ui.document.file
  local quick_actions = self.action_service:getHighlightMenuActionObjects(has_open_book, document_path)
  if #quick_actions == 0 then
    logger.info("KOAssistant: No quick actions configured for highlight menu")
    return
  end

  logger.info("KOAssistant: Registering " .. #quick_actions .. " quick actions for highlight menu")

  for i, action in ipairs(quick_actions) do
    -- Use numeric prefix for ordering: KOReader's orderedPairs sorts keys alphabetically
    -- Format: "90_%02d_koassistant_%s" where 90_ comes after KOReader's built-in items (08_-11_)
    local dialog_id = string.format("90_%02d_koassistant_%s", i, action.id)
    local action_id = action.id  -- Capture ID for fresh lookup in callback

    self.ui.highlight:addToHighlightDialog(dialog_id, function(reader_highlight_instance)
      -- Re-fetch action to pick up mid-session override changes (flag toggles, etc.)
      local fresh_action = self.action_service:getAction("highlight", action_id)
      if not fresh_action or not fresh_action.enabled then return nil end
      local cur_features = self.settings:readSetting("features") or {}
      return {
        text = ActionService.getActionDisplayText(fresh_action, cur_features) .. " (KOA)",
        enabled = Device:hasClipboard(),
        callback = function()
          -- Capture text and extract context BEFORE closing highlight overlay
          local selected_text = reader_highlight_instance.selected_text.text
          local context = ""
          -- Check if highlight module has the getSelectedWordContext method
          -- Note: Method is on self.ui.highlight, not reader_highlight_instance
          if self.ui.highlight and self.ui.highlight.getSelectedWordContext then
            local context_mode = cur_features.dictionary_context_mode or "none"
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
              drawer = st.drawer or "lighten",
              color = st.color or "yellow",
            }
          end

          -- Close highlight overlay to prevent darkening on saved highlights
          reader_highlight_instance:onClose()

          if fresh_action.local_handler then
            -- Local actions don't need network
            self:updateConfigFromSettings()
            self:executeQuickAction(fresh_action, selected_text, context, selection_data)
          else
            NetworkMgr:runWhenOnline(function()
              self:updateConfigFromSettings()
              -- Pass extracted context and selection data to executeQuickAction
              self:executeQuickAction(fresh_action, selected_text, context, selection_data)
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

  -- Check if we have access to the reader's dictionary module
  if not self.ui or not self.ui.dictionary then
    logger.warn("KOAssistant: Cannot sync dictionary bypass - reader dictionary not available")
    return
  end

  local dictionary = self.ui.dictionary

  if bypass_enabled then
    -- Store original method if not already stored
    if not dictionary._koassistant_original_onLookupWord then
      dictionary._koassistant_original_onLookupWord = dictionary.onLookupWord
      logger.info("KOAssistant: Storing original ReaderDictionary:onLookupWord")
    end

    local self_ref = self
    dictionary.onLookupWord = function(dict_self, word, is_sane, boxes, highlight, link, dict_close_callback)
      -- Get the bypass action from settings (default: dictionary)
      local action_id = features.dictionary_bypass_action or "dictionary"
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
        local file = self_ref.ui and self_ref.ui.document and self_ref.ui.document.file
        local cached = file and ActionCache.getXrayCache(file)
        if not cached or not cached.result then
          logger.info("KOAssistant: Dictionary bypass - action requires X-Ray cache, falling through to dictionary")
          if dictionary._koassistant_original_onLookupWord then
            return dictionary._koassistant_original_onLookupWord(dict_self, word, is_sane, boxes, highlight, link, dict_close_callback)
          end
          return
        end
      end

      -- Check if this is a non-reader lookup (e.g., from ChatGPT viewer or nested dictionary).
      -- Context extraction from the book page would be irrelevant in these cases.
      local non_reader_lookup = dict_self._koassistant_non_reader_lookup
      dict_self._koassistant_non_reader_lookup = nil  -- Consume flag

      -- IMPORTANT: Extract context BEFORE clearing highlight
      -- The highlight object contains the selection state needed for context extraction.
      -- Once cleared, getSelectedWordContext() will return nil.
      -- Always extract regardless of mode, so compact view toggle can enable context later.
      local context = ""
      local context_mode = features.dictionary_context_mode or "none"
      local context_chars = features.dictionary_context_chars or 100
      -- Use "sentence" as extraction mode when setting is "none" (for toggle availability)
      local extraction_mode = (context_mode == "none") and "sentence" or context_mode
      if not non_reader_lookup and self_ref.ui and self_ref.ui.highlight then
        context = Dialogs.extractSurroundingContext(
          self_ref.ui,
          word,
          extraction_mode,
          context_chars
        )
        if context and context ~= "" then
          logger.info("KOAssistant BYPASS: Got context (" .. #context .. " chars)")
        else
          logger.info("KOAssistant BYPASS: No context available")
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
          drawer = st.drawer or "lighten",
          color = st.color or "yellow",
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
        Dialogs.executeDirectAction(self_ref.ui, bypass_action, word, configuration, self_ref)
      else
        NetworkMgr:runWhenOnline(function()
          -- Make sure we're using the latest configuration
          self_ref:updateConfigFromSettings()
          -- Get effective dictionary language
          local SystemPrompts = require("prompts.system_prompts")
          local dict_language = SystemPrompts.getEffectiveDictionaryLanguage({
            dictionary_language = features.dictionary_language,
            translation_language = features.translation_language,
            translation_use_primary = features.translation_use_primary,
            interaction_languages = features.interaction_languages,
            user_languages = features.user_languages,
            primary_language = features.primary_language,
          })

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
          dict_config.features.is_multi_book_context = nil

          -- Set dictionary-specific values
          if non_reader_lookup then
            -- Non-reader lookup: no context available, disable CTX toggle
            dict_config.features.dictionary_context = ""
            dict_config.features._original_context = ""
            dict_config.features._no_context_available = true
          else
            -- Only include context in the request if mode is not "none"
            dict_config.features.dictionary_context = (context_mode ~= "none") and context or ""
            -- Always store extracted context so compact view toggle can use it
            dict_config.features._original_context = context
            dict_config.features._original_context_mode = extraction_mode
          end
          dict_config.features.dictionary_language = dict_language
          dict_config.features.dictionary_context_mode = features.dictionary_context_mode or "none"
          -- Store selection_data for "Save to Note" feature (word position only)
          dict_config.features.selection_data = selection_data

          -- Skip auto-save for dictionary if setting is enabled (default: true)
          if features.dictionary_disable_auto_save ~= false then
            dict_config.features.storage_key = "__SKIP__"
          end

          -- Always use compact view for dictionary bypass
          dict_config.features.compact_view = true
          dict_config.features.hide_highlighted_text = true
          dict_config.features.minimal_buttons = true
          dict_config.features.large_stream_dialog = false

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
            logger.info("KOAssistant: Auto-added word to vocabulary builder (bypass): " .. word)
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
    logger.info("KOAssistant: Dictionary bypass enabled")
  else
    -- Restore original method
    if dictionary._koassistant_original_onLookupWord then
      dictionary.onLookupWord = dictionary._koassistant_original_onLookupWord
      dictionary._koassistant_original_onLookupWord = nil
      logger.info("KOAssistant: Dictionary bypass disabled, restored original dictionary lookup")
    end
  end
end

-- Highlight Bypass: immediately trigger an action when text is selected
function AskGPT:syncHighlightBypass()
  if not self.ui or not self.ui.highlight then
    logger.info("KOAssistant: Cannot sync highlight bypass - highlight not available")
    return
  end

  local highlight = self.ui.highlight
  local self_ref = self

  -- Store original if not already stored
  if not highlight._koassistant_original_onShowHighlightMenu then
    highlight._koassistant_original_onShowHighlightMenu = highlight.onShowHighlightMenu
  end

  -- Replace with our interceptor
  highlight.onShowHighlightMenu = function(hl_self, ...)
    local features = self_ref.settings:readSetting("features", {})

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
          local cached = file and ActionCache.getXrayCache(file)
          if not cached or not cached.result then
            logger.info("KOAssistant: Highlight bypass - action requires X-Ray cache, falling through to menu")
            return highlight._koassistant_original_onShowHighlightMenu(hl_self, ...)
          end
        end
        logger.info("KOAssistant: Highlight bypass active, executing action: " .. action_id)
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

  logger.info("KOAssistant: Highlight bypass synced")
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
        local current = f.dictionary_bypass_action or "dictionary"
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
function AskGPT:executeQuickAction(action, highlighted_text, context, selection_data)
  -- Clear context flags for highlight context (default context)
  configuration.features = configuration.features or {}
  configuration.features.is_general_context = nil
  configuration.features.is_book_context = nil
  configuration.features.is_multi_book_context = nil
  -- Pass surrounding context if provided (for dictionary actions)
  if context and context ~= "" then
    configuration.features.dictionary_context = context
  end
  -- Store selection data for "Save to Note" feature
  configuration.features.selection_data = selection_data
  -- Block actions when declared requirements are unmet
  if self:_checkRequirements(action) then
    return
  end
  Dialogs.executeDirectAction(self.ui, action, highlighted_text, configuration, self)
end

function AskGPT:restoreDefaultPrompts()
  -- Combined reset: custom actions + edits + menus
  -- Uses the granular reset functions internally
  self.settings:delSetting("custom_actions")
  self.settings:delSetting("builtin_action_overrides")
  self.settings:delSetting("disabled_actions")
  self.settings:delSetting("highlight_menu_actions")
  self.settings:delSetting("dictionary_popup_actions")
  self.settings:delSetting("_dismissed_highlight_actions")
  self.settings:delSetting("_dismissed_dictionary_actions")
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

  NetworkMgr:runWhenOnline(function()
    self:ensureInitialized()
    -- Make sure we're using the latest configuration
    self:updateConfigFromSettings()

    -- Set context flag on the original configuration (no copy needed)
    -- This ensures settings changes are immediately visible
    configuration.features = configuration.features or {}
    -- Clear other context flags and book metadata
    configuration.features.is_general_context = true
    configuration.features.is_book_context = nil
    configuration.features.is_multi_book_context = nil
    configuration.features.book_metadata = nil
    configuration.features.books_info = nil

    -- Show dialog with general context
    showChatGPTDialog(self.ui, nil, configuration, nil, self)
  end)
end

function AskGPT:showChatHistory()
  -- Load the chat history manager
  local ChatHistoryManager = require("koassistant_chat_history_manager")
  local chat_history_manager = ChatHistoryManager:new()
  
  -- Get the current document path if a document is open
  local document_path = nil
  if self.ui and self.ui.document and self.ui.document.file then
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
  NetworkMgr:runWhenOnline(function()
    local UpdateChecker = require("koassistant_update_checker")
    UpdateChecker.checkForUpdates(false) -- auto = false (manual check with UI feedback)
  end)
end

function AskGPT:showAbout()
  local UpdateChecker = require("koassistant_update_checker")
  UIManager:show(InfoMessage:new{
    text = _("KOAssistant Plugin\nVersion: ") ..
          (UpdateChecker.getCurrentVersion() or "Unknown") ..
          "\nProvides AI assistant capabilities via various API providers." ..
          "\n\nGesture Support:\nAssign gestures in Settings → Gesture Manager",
  })
end

-- Event handlers for registering buttons with different FileManager views
function AskGPT:onFileManagerReady(filemanager)
  logger.info("KOAssistant: onFileManagerReady event received")
  
  -- Register immediately since FileManager should be ready
  self:addFileDialogButtons()
  
  -- Also register with a delay as a fallback
  UIManager:scheduleIn(0.1, function()
    logger.info("KOAssistant: Late registration of file dialog buttons (onFileManagerReady)")
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
            logger.info("KOAssistant: Added multi-select button to dialog at end position " .. #o.buttons)
          end
        end
      end

      -- Call original constructor
      return ButtonDialog._orig_new_koassistant(self, o)
    end

    logger.info("KOAssistant: Patched ButtonDialog.new for multi-select support")
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
  })

  self.settings:saveSetting("features", new_features)

  -- Clear all other top-level settings (custom actions, overrides, menu configs)
  self.settings:delSetting("custom_actions")
  self.settings:delSetting("builtin_action_overrides")
  self.settings:delSetting("highlight_menu_actions")
  self.settings:delSetting("dictionary_popup_actions")
  self.settings:delSetting("disabled_actions")
  self.settings:delSetting("_dismissed_highlight_actions")
  self.settings:delSetting("_dismissed_dictionary_actions")

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
  self.settings:flush()

  if not silent then
    UIManager:show(InfoMessage:new{
      text = _("Action menus reset to defaults.") .. "\n" .. _("Restart KOReader for highlight menu changes to apply."),
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
    text = _("Highlight menu actions reset (restart to apply)"),
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
  self.settings:saveSetting("features", features)
  self.settings:flush()
  self:updateConfigFromSettings()
end

-- Internal: Reset feature settings using centralized defaults (no notification)
function AskGPT:_resetFeatureSettingsInternal()
  local features = self.settings:readSetting("features") or {}

  -- Apply defaults, preserving API keys, custom content, user customizations,
  -- language/behavior/domain choices, and migration flags
  local new_features = SettingsSchema.applyDefaults(features, {
    "features.api_keys",
    "features.custom_behaviors",
    "features.custom_models",
    "features.provider_default_models",
    "features.custom_providers",
    "features.gesture_actions",
    -- User choices (not toggleable feature settings)
    "features.selected_behavior",
    "features.selected_domain",
    "features.custom_domains",
    "features.trusted_providers",
    "features.translation_language",
    "features.dictionary_language",
    "features.interaction_languages",
    "features.additional_languages",
    "features.primary_language",
    "features.markdown_font_size",
    "features.export_custom_path",
    -- Migration flags (prevent re-migration)
    "features.languages_migrated",
  })

  self.settings:saveSetting("features", new_features)
  self.settings:flush()
  self:updateConfigFromSettings()
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
  UIManager:show(Notification:new{
    text = _("All action settings reset"),
    timeout = 2,
  })
end

-- Quick reset: Fresh start (everything except API keys and chats)
function AskGPT:quickResetFreshStart()
  self:_resetFeatureSettingsInternal()
  self:resetCustomActions(true)
  self:resetActionEdits(true)
  self:resetActionMenus(true)
  self:resetCustomProvidersModels(true)
  self:resetBehaviorsDomains()

  -- Fresh start: also clear user choices preserved by _resetFeatureSettingsInternal
  -- (keeps API keys, languages, and migration flags)
  local features = self.settings:readSetting("features") or {}
  features.selected_behavior = nil
  features.selected_domain = nil
  features.custom_domains = nil
  features.trusted_providers = nil
  features.gesture_actions = nil
  features.markdown_font_size = nil
  features.export_custom_path = nil
  self.settings:saveSetting("features", features)
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
  f.enable_progress_sharing = true
  f.enable_stats_sharing = true
  f.enable_book_text_extraction = false
  self.settings:saveSetting("features", f)
  self.settings:flush()
  self:updateConfigFromSettings()
  if touchmenu_instance then
    touchmenu_instance:updateItems()
  end
  UIManager:show(Notification:new{
    text = _("Default: Personal content private, basic context shared"),
    timeout = 2,
  })
end

-- Privacy preset: Minimal (maximum privacy)
function AskGPT:applyPrivacyPresetMinimal(touchmenu_instance)
  local f = self.settings:readSetting("features") or {}
  -- Disable all extended data sharing
  f.enable_highlights_sharing = false
  f.enable_annotations_sharing = false
  f.enable_notebook_sharing = false
  f.enable_progress_sharing = false
  f.enable_stats_sharing = false
  f.enable_book_text_extraction = false
  self.settings:saveSetting("features", f)
  self.settings:flush()
  self:updateConfigFromSettings()
  if touchmenu_instance then
    touchmenu_instance:updateItems()
  end
  UIManager:show(Notification:new{
    text = _("Minimal: All extended sharing disabled"),
    timeout = 2,
  })
end

-- Privacy preset: Full (enable all sharing except book text)
function AskGPT:applyPrivacyPresetFull(touchmenu_instance)
  local f = self.settings:readSetting("features") or {}
  -- Enable all data sharing (except book text which has cost implications)
  f.enable_highlights_sharing = true
  f.enable_annotations_sharing = true
  f.enable_notebook_sharing = true
  f.enable_progress_sharing = true
  f.enable_stats_sharing = true
  -- Note: enable_book_text_extraction not touched - user must enable manually
  self.settings:saveSetting("features", f)
  self.settings:flush()
  self:updateConfigFromSettings()
  if touchmenu_instance then
    touchmenu_instance:updateItems()
  end
  UIManager:show(Notification:new{
    text = _("Full: All data sharing enabled (Text extraction must be enabled separately)"),
    timeout = 2,
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

  -- Track selection state
  local selected = {}
  for _idx, provider_id in ipairs(current_trusted) do
    selected[provider_id] = true
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
        -- Rebuild dialog to show updated state
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
      text = toggleText(_("API keys"), state.reset_api_keys, " ⚠️"),
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
      text = _("No backups found.\n\nCreate a backup first using:\nSettings → Advanced → Settings Management → Create Backup"),
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
      backup_info = "🔄 " .. backup_info .. " (Restore Point)"
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
      backup_info = "🔄 " .. backup_info
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
      -- No old chats to migrate, just mark as v2
      logger.info("No old chats found, marking storage as v2")
      G_reader_settings:saveSetting("chat_storage_version", 2)
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
    G_reader_settings:saveSetting("chat_storage_version", 2)
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
          -- Read existing chats from metadata.lua (if any)
          local doc_settings = DocSettings:open(doc_path)
          local existing_chats = doc_settings:readSetting("koassistant_chats", {})

          -- Add all chats (keyed by ID)
          for _idx, chat in ipairs(chats) do
            existing_chats[chat.id] = chat
            stats.migrated = stats.migrated + 1
          end

          -- Save to metadata.lua
          doc_settings:saveSetting("koassistant_chats", existing_chats)
          doc_settings:flush()

          -- Update chat index
          ChatHistoryManager:updateChatIndex(doc_path, "save", nil, existing_chats)

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
      -- v2 = chats stored in metadata.lua for automatic move tracking
      G_reader_settings:saveSetting("chat_storage_version", 2)
      logger.info("Migration successful, marked as v2 storage (metadata.lua)")
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

  -- Check migration first (may show dialog if old chats exist)
  self:checkChatMigrationStatus()

  -- Check welcome dialog (only shows if storage is v2+ and not seen before)
  -- If migration is pending (v1), this will skip and show next time
  self:checkWelcomeDialog()
end

--[[
    Welcome Dialog
    Shows once for new users to explain privacy settings and key features.
    Only appears after storage is v2+ (skips users mid-migration).
--]]

-- Check if welcome dialog should be shown
function AskGPT:checkWelcomeDialog()
  local storage_version = G_reader_settings:readSetting("chat_storage_version", 1)
  local welcome_shown = self.settings:readSetting("welcome_shown")

  -- Only show for v2+ users who haven't seen welcome
  -- This skips users mid-migration (v1) to avoid dialog collision
  if storage_version >= 2 and not welcome_shown then
    self:showWelcomeDialog()
  end
end

-- Show welcome dialog to new users
function AskGPT:showWelcomeDialog()
  local text = _("Welcome to KOAssistant!") .. "\n\n" ..
    _("PRIVACY SETTINGS") .. "\n" ..
    _("Some features (like X-Ray) need to access document text and other content. Enable in: Settings → Privacy & Data") .. "\n\n" ..
    _("QUICK ACCESS") .. "\n" ..
    _("Assign Quick Settings (File browser) and Quick Actions (Reader) panels to gestures. See KOReader Settings (Gear icon) → Taps and Gestures") .. "\n\n" ..
    _("CUSTOM ACTIONS") .. "\n" ..
    _("Create your own prompts and actions or edit built in ones. Go to: Settings → Action Manager") .. "\n\n" ..
    _("MENU AND INFO ICONS") .. "\n" ..
    _("Setup KOReader with emoji support to get informative icons in menus and more. See the emoji section in the README for details.") 

  UIManager:show(InfoMessage:new{
    text = text,
    -- No timeout - user must tap to dismiss
  })

  self.settings:saveSetting("welcome_shown", true)
  self.settings:flush()
end

-- Patch DocSettings.updateLocation() to keep chat index in sync and move custom sidecar files
function AskGPT:patchDocSettingsForChatIndex()
  local DocSettings = require("docsettings")
  -- Note: lfs is already required at file scope (line 15)

  -- Only patch once
  if DocSettings._koassistant_patched then
    return
  end

  -- Save original function
  DocSettings._original_updateLocation = DocSettings.updateLocation

  -- Replace with patched version
  DocSettings.updateLocation = function(old_path, new_path)
    -- Move custom sidecar files BEFORE calling KOReader's original function
    -- This way, when KOReader's purge() runs, our files are already gone
    -- and the old .sdr directory will be cleaned up automatically

    -- Ensure new .sdr directory exists before moving files
    local new_sidecar_dir = DocSettings:getSidecarDir(new_path)
    -- Note: util is already required at file scope (line 18)
    util.makePath(new_sidecar_dir)

    for _idx, filename in ipairs(KOASSISTANT_SIDECAR_FILES) do
      local old_sidecar = DocSettings:getSidecarDir(old_path) .. "/" .. filename
      local new_sidecar = new_sidecar_dir .. "/" .. filename

      if lfs.attributes(old_sidecar, "mode") == "file" then
        logger.dbg("KOAssistant: Moving sidecar file:", filename)

        -- Try os.rename first (works for same filesystem)
        local success, err = os.rename(old_sidecar, new_sidecar)

        if success then
          logger.info("KOAssistant: Moved sidecar file:", filename)
        else
          -- Fallback: copy+delete for cross-filesystem moves
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

    -- Now call KOReader's original function
    -- Our files are gone, so purge() will successfully remove the old .sdr directory
    DocSettings._original_updateLocation(old_path, new_path)

    -- Update KOAssistant chat index (after KOReader's work is done)
    local chat_index = G_reader_settings:readSetting("koassistant_chat_index", {})
    if chat_index[old_path] then
      chat_index[new_path] = chat_index[old_path]
      chat_index[old_path] = nil
      G_reader_settings:saveSetting("koassistant_chat_index", chat_index)
      logger.info("KOAssistant: Updated chat index for moved file")
    end

    -- Update KOAssistant notebook index
    local notebook_index = G_reader_settings:readSetting("koassistant_notebook_index", {})
    if notebook_index[old_path] then
      notebook_index[new_path] = notebook_index[old_path]
      notebook_index[old_path] = nil
      G_reader_settings:saveSetting("koassistant_notebook_index", notebook_index)
      logger.info("KOAssistant: Updated notebook index for moved file")
    end

    -- Update KOAssistant artifact index
    local artifact_index = G_reader_settings:readSetting("koassistant_artifact_index", {})
    if artifact_index[old_path] then
      artifact_index[new_path] = artifact_index[old_path]
      artifact_index[old_path] = nil
      G_reader_settings:saveSetting("koassistant_artifact_index", artifact_index)
      logger.info("KOAssistant: Updated artifact index for moved file")
    end

    -- Flush settings once after all index updates
    G_reader_settings:flush()
  end

  DocSettings._koassistant_patched = true
  logger.info("KOAssistant: DocSettings.updateLocation() patched for sidecar file tracking")
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

--- Check if document has saved chats
--- @param file_path string The document file path
--- @return boolean has_chats Whether the document has saved chats
function AskGPT:documentHasChats(file_path)
  local index = G_reader_settings:readSetting("koassistant_chat_index", {})
  return index[file_path] and index[file_path].count and index[file_path].count > 0
end

--- Show chat history filtered to a specific book
--- @param file_path string The document file path
function AskGPT:showChatHistoryForFile(file_path)
  local ChatHistoryDialog = require("koassistant_chat_history_dialog")
  local ChatHistoryManager = require("koassistant_chat_history_manager")

  local chat_history_manager = ChatHistoryManager:new()
  ChatHistoryDialog:showChatHistoryBrowser(self.ui, file_path, chat_history_manager, self.CONFIG)
end

--- Open notebook for viewing or editing
--- @param file_path string The document file path
--- @param edit_mode boolean|nil If true, open in TextEditor (edit mode); otherwise open in reader (view mode)
function AskGPT:openNotebookForFile(file_path, edit_mode)
  local Notebook = require("koassistant_notebook")
  local notebook_path = Notebook.getPath(file_path)

  if not notebook_path then
    UIManager:show(InfoMessage:new{
      text = _("No notebook available for this document"),
      timeout = 2,
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
          -- Open in edit mode for new notebooks
          self:openNotebookEditor(notebook_path, file_path)
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

  local viewer = ChatGPTViewer:new{
    title = title,
    text = content,
    simple_view = true,
    configuration = viewer_config,
    on_edit = on_edit,
    on_open_reader = on_open_reader,
    on_export = on_export,
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