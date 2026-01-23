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
local T = require("ffi/util").template
local logger = require("logger")
local util = require("util")
local Screen = Device.screen

local Dialogs = require("dialogs")
local showChatGPTDialog = Dialogs.showChatGPTDialog
local UpdateChecker = require("update_checker")
local SettingsSchema = require("settings_schema")
local SettingsManager = require("ui/settings_manager")
local PromptsManager = require("ui/prompts_manager")
local UIConstants = require("ui/constants")
local ActionService = require("action_service")

local ModelLists = require("model_lists")

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

local AskGPT = WidgetContainer:extend{
  name = "koassistant",
  is_doc_only = false,
}

-- Flag to ensure the update message is shown only once per session
local updateMessageShown = false

-- Helper function to check for updates if auto-check is enabled
local function maybeCheckForUpdates(plugin_instance)
    if updateMessageShown then
        return
    end
    -- Check if auto-check is enabled (default: true)
    local auto_check = true
    if plugin_instance and plugin_instance.settings then
        local features = plugin_instance.settings:readSetting("features") or {}
        if features.auto_check_updates == false then
            auto_check = false
        end
    end
    if auto_check then
        -- Mark as shown immediately to prevent duplicate checks
        updateMessageShown = true
        -- Run update check in background after a short delay
        -- This allows the main action (chat dialog) to proceed first
        UIManager:scheduleIn(0.5, function()
            UpdateChecker.checkForUpdates(true) -- silent = true for auto-check
        end)
    end
end

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
  
  -- Add to highlight dialog if highlight feature is available
  if self.ui and self.ui.highlight then
    self.ui.highlight:addToHighlightDialog("koassistant_dialog", function(_reader_highlight_instance)
      return {
        text = _("KOAssistant"),
        enabled = Device:hasClipboard(),
        callback = function()
          NetworkMgr:runWhenOnline(function()
            maybeCheckForUpdates(self)
            -- Make sure we're using the latest configuration
            self:updateConfigFromSettings()
            -- Clear context flags for highlight context (default context)
            configuration.features = configuration.features or {}
            configuration.features.is_general_context = nil
            configuration.features.is_book_context = nil
            configuration.features.is_multi_book_context = nil
            showChatGPTDialog(self.ui, _reader_highlight_instance.selected_text.text, configuration, nil, self)
          end)
        end,
      }
    end)
    logger.info("Added KOAssistant to highlight dialog")

    -- Register quick actions for highlight menu
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

-- Button generator for single file actions
function AskGPT:generateFileDialogButtons(file, is_file, book_props)
  logger.info("KOAssistant: generateFileDialogButtons called with file=" .. tostring(file) ..
              ", is_file=" .. tostring(is_file) .. ", has_book_props=" .. tostring(book_props ~= nil))

  -- Only show buttons for document files
  if is_file and self:isDocumentFile(file) then
    logger.info("KOAssistant: File is a document, creating KOAssistant button")
    
    -- Get metadata
    local title = book_props and book_props.title or file:match("([^/]+)$")
    local authors = book_props and book_props.authors or ""
    
    -- Return a row with the KOAssistant button
    -- FileManagerHistory expects a row (array of buttons)
    local buttons = {
      {
        text = _("KOAssistant"),
        callback = function()
          -- Close any open file dialog
          local UIManager = require("ui/uimanager")
          local current_dialog = UIManager:getTopmostVisibleWidget()
          if current_dialog and current_dialog.close then
            UIManager:close(current_dialog)
          end
          -- Show KOAssistant dialog with book context
          self:showKOAssistantDialogForFile(file, title, authors, book_props)
        end,
      }
    }

    logger.info("KOAssistant: Returning button row")
    return buttons
  else
    logger.info("KOAssistant: Not a document file or is_file=false, returning nil")
    return nil
  end
end

-- Button generator for multiple file selection
function AskGPT:generateMultiSelectButtons(file, is_file, book_props)
  local FileManager = require("apps/filemanager/filemanager")
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

  logger.info("KOAssistant: Attempting to add file dialog buttons")
  
  local FileManager = require("apps/filemanager/filemanager")
  
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
  local single_file_generator = function(file, is_file, book_props)
    local buttons = self:generateFileDialogButtons(file, is_file, book_props)
    if buttons then
      logger.info("KOAssistant: Generated buttons for file: " .. tostring(file))
    end
    return buttons
  end
  
  local multi_file_generator = function(file, is_file, book_props)
    return self:generateMultiSelectButtons(file, is_file, book_props)
  end
  
  local success_count = 0
  
  -- Method 1: Register via instance method if available
  if FileManager.instance and FileManager.instance.addFileDialogButtons then
    local success = pcall(function()
      FileManager.instance:addFileDialogButtons("zzz_koassistant_file_actions", single_file_generator)
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
        FileManager.addFileDialogButtons(widget_class, "zzz_koassistant_file_actions", single_file_generator)
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
  
  local FileManager = require("apps/filemanager/filemanager")
  local FileManagerHistory = require("apps/filemanager/filemanagerhistory")
  local FileManagerCollection = require("apps/filemanager/filemanagercollection")
  local FileManagerFileSearcher = require("apps/filemanager/filemanagerfilesearcher")
  
  -- Remove from instance if available
  if FileManager.instance and FileManager.instance.removeFileDialogButtons then
    pcall(function()
      FileManager.instance:removeFileDialogButtons("zzz_koassistant_multi_select")
      FileManager.instance:removeFileDialogButtons("zzz_koassistant_file_actions")
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
        FileManager.removeFileDialogButtons(widget_class, "zzz_koassistant_multi_select")
        FileManager.removeFileDialogButtons(widget_class, "zzz_koassistant_file_actions")
      end)
    end
  end

  self.file_dialog_buttons_added = false
  logger.info("KOAssistant: File dialog buttons removed")
end

function AskGPT:checkButtonVisibility()
  local FileManager = require("apps/filemanager/filemanager")

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
  -- Create book context string
  local book_context = string.format("Book: %s", title)
  if authors and authors ~= "" then
    book_context = book_context .. string.format("\nAuthor: %s", authors)
  end
  if book_props then
    if book_props.series then
      book_context = book_context .. string.format("\nSeries: %s", book_props.series)
    end
    if book_props.language then
      book_context = book_context .. string.format("\nLanguage: %s", book_props.language)
    end
    if book_props.year then
      book_context = book_context .. string.format("\nYear: %s", book_props.year)
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
    maybeCheckForUpdates(self)
    -- Show dialog with book context instead of highlighted text
    showChatGPTDialog(self.ui, book_context, configuration, nil, self)
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
  local FileManager = require("apps/filemanager/filemanager")
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
    maybeCheckForUpdates(self)
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
    title = _("KOAssistant: General Chat"),
    general = true
  })

  -- Register file browser context action
  Dispatcher:registerAction("koassistant_book_chat", {
    category = "none",
    event = "KOAssistantBookChat",
    title = _("KOAssistant: Chat About Book"),
    general = true
  })

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
    title = _("KOAssistant: AI Quick Settings"),
    general = true,
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
    general = true,
    reader = true,
    separator = true
  })

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
      stream_auto_scroll = false,  -- Default to no auto-scroll during streaming
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

    -- Ensure selected_behavior has a value
    if not features.selected_behavior then
      features.selected_behavior = "standard"
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
  configuration.features = features

  -- Ensure transient flags are cleared (these are only set at runtime for dictionary lookups)
  -- This prevents compact_view from "leaking" to non-dictionary actions
  configuration.features.compact_view = nil
  configuration.features.minimal_buttons = nil

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

-- Helper: Build provider selection sub-menu
function AskGPT:buildProviderMenu()
  local self_ref = self
  local current = self:getCurrentProvider()
  local ModelLists = require("model_lists")
  local providers = ModelLists.getAllProviders()
  local Defaults = require("api_handlers.defaults")
  local items = {}

  for _i, provider in ipairs(providers) do
    local prov_copy = provider  -- Capture for closure
    table.insert(items, {
      text = prov_copy:gsub("^%l", string.upper),  -- Capitalize
      checked_func = function() return self_ref:getCurrentProvider() == prov_copy end,
      radio = true,
      callback = function()
        local features = self_ref.settings:readSetting("features") or {}
        local old_provider = features.provider

        -- Reset model to new provider's default when provider changes
        if old_provider ~= prov_copy then
          local provider_defaults = Defaults.ProviderDefaults[prov_copy]
          if provider_defaults and provider_defaults.model then
            features.model = provider_defaults.model
          else
            features.model = nil  -- Clear if no default
          end
        end

        features.provider = prov_copy
        self_ref.settings:saveSetting("features", features)
        self_ref.settings:flush()
        self_ref:updateConfigFromSettings()
        -- Show toast confirmation
        UIManager:show(Notification:new{
          text = string.format(_("Provider: %s"), prov_copy:gsub("^%l", string.upper)),
          timeout = 1.5,
        })
      end,
      keep_menu_open = true,
    })
  end

  return items
end

-- Helper: Build model selection sub-menu for current provider
function AskGPT:buildModelMenu()
  local self_ref = self
  local provider = self:getCurrentProvider()
  local models = ModelLists[provider] or {}
  local Defaults = require("api_handlers.defaults")
  local provider_defaults = Defaults.ProviderDefaults[provider]
  local default_model = provider_defaults and provider_defaults.model or nil
  local items = {}

  for i = 1, #models do
    local model = models[i]
    -- Show full model name
    local display_name = model

    -- Mark default model
    local is_default = (model == default_model)
    if is_default then
      display_name = display_name .. " " .. _("(default)")
    end

    table.insert(items, {
      text = display_name,
      checked_func = function()
        local f = self_ref.settings:readSetting("features") or {}
        local selected = f.model or default_model
        return selected == model
      end,
      radio = true,
      callback = function()
        local f = self_ref.settings:readSetting("features") or {}
        f.model = model
        self_ref.settings:saveSetting("features", f)
        self_ref.settings:flush()
        self_ref:updateConfigFromSettings()
        -- Show toast confirmation
        UIManager:show(Notification:new{
          text = string.format(_("Model: %s"), model),
          timeout = 1.5,
        })
      end,
      keep_menu_open = true,
    })
  end

  -- Add custom model input option
  table.insert(items, {
    text = _("Custom model..."),
    callback = function()
      local f = self_ref.settings:readSetting("features") or {}
      local current_model = f.model or ""
      local InputDialog = require("ui/widget/inputdialog")
      local input_dialog
      input_dialog = InputDialog:new{
        title = _("Enter Custom Model Name"),
        input = current_model,
        input_hint = _("e.g., claude-3-opus-20240229"),
        description = _("Enter the exact model identifier for this provider."),
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
                local new_model = input_dialog:getInputText()
                if new_model and new_model ~= "" then
                  f.model = new_model
                  self_ref.settings:saveSetting("features", f)
                  self_ref.settings:flush()
                  self_ref:updateConfigFromSettings()
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

  if #items == 1 then
    -- Only the custom option exists, add a note
    table.insert(items, 1, {
      text = _("No predefined models"),
      enabled = false,
    })
  end

  return items
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

-- Helper: Build API Keys management menu
function AskGPT:buildApiKeysMenu()
  local self_ref = self
  local items = {}
  local providers = ModelLists.getAllProviders()
  local features = self.settings:readSetting("features") or {}
  local gui_keys = features.api_keys or {}

  for _i, provider in ipairs(providers) do
    local prov_copy = provider
    local has_gui_key = gui_keys[provider] and gui_keys[provider] ~= ""
    local has_file_key = hasFileApiKey(provider)

    -- Status indicator
    local status = ""
    if has_gui_key then
      status = " [set]"
    elseif has_file_key then
      status = " (file)"
    end

    table.insert(items, {
      text = prov_copy:gsub("^%l", string.upper) .. status,
      keep_menu_open = true,
      callback = function()
        self_ref:showApiKeyDialog(prov_copy)
      end,
    })
  end
  return items
end

-- Show dialog to enter/edit API key for a provider
function AskGPT:showApiKeyDialog(provider)
  local self_ref = self
  local features = self.settings:readSetting("features") or {}
  local gui_keys = features.api_keys or {}
  local current_key = gui_keys[provider] or ""
  local masked = maskApiKey(current_key)
  local has_file_key = hasFileApiKey(provider)

  -- Build hint text
  local hint_text
  if masked ~= "" then
    hint_text = string.format(_("Current: %s"), masked)
  elseif has_file_key then
    hint_text = _("Using key from apikeys.lua")
  else
    hint_text = _("Enter API key...")
  end

  local InputDialog = require("ui/widget/inputdialog")
  local input_dialog
  input_dialog = InputDialog:new{
    title = provider:gsub("^%l", string.upper) .. " " .. _("API Key"),
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
              text = string.format(_("%s API key cleared"), provider:gsub("^%l", string.upper)),
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
              f.api_keys[provider] = new_key
              self_ref.settings:saveSetting("features", f)
              self_ref.settings:flush()
              UIManager:close(input_dialog)
              UIManager:show(InfoMessage:new{
                text = string.format(_("%s API key saved"), provider:gsub("^%l", string.upper)),
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
function AskGPT:getEffectivePrimaryLanguage()
  local features = self.settings:readSetting("features") or {}
  local user_languages = features.user_languages or ""
  local override = features.primary_language

  if user_languages == "" then
    return nil
  end

  -- Parse languages
  local languages = {}
  for lang in user_languages:gmatch("([^,]+)") do
    local trimmed = lang:match("^%s*(.-)%s*$")
    if trimmed ~= "" then
      table.insert(languages, trimmed)
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

-- Build primary language picker menu
function AskGPT:buildPrimaryLanguageMenu()
  local self_ref = self
  local features = self.settings:readSetting("features") or {}
  local user_languages = features.user_languages or ""

  if user_languages == "" then
    return {
      {
        text = _("Set your languages first"),
        enabled = false,
      },
    }
  end

  -- Parse languages
  local languages = {}
  for lang in user_languages:gmatch("([^,]+)") do
    local trimmed = lang:match("^%s*(.-)%s*$")
    if trimmed ~= "" then
      table.insert(languages, trimmed)
    end
  end

  if #languages == 0 then
    return {
      {
        text = _("No valid languages found"),
        enabled = false,
      },
    }
  end

  local current_primary = self:getEffectivePrimaryLanguage()
  local menu_items = {}

  for i, lang in ipairs(languages) do
    local is_first = (i == 1)
    local lang_copy = lang  -- Capture for closure

    table.insert(menu_items, {
      text = is_first and lang .. " " .. _("(default)") or lang,
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
          text = string.format(_("Primary: %s"), lang_copy),
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
    text = string.format(_("Use Primary (%s)"), effective_primary),
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
        text = string.format(_("Translate: %s"), prim),
        timeout = 1.5,
      })
    end,
  })

  -- Parse languages from user_languages
  local features = self.settings:readSetting("features") or {}
  local user_languages = features.user_languages or ""
  local languages = {}
  for lang in user_languages:gmatch("([^,]+)") do
    local trimmed = lang:match("^%s*(.-)%s*$")
    if trimmed ~= "" then
      table.insert(languages, trimmed)
    end
  end

  -- Add each language as an option
  for _i, lang in ipairs(languages) do
    local lang_copy = lang  -- Capture for closure
    table.insert(menu_items, {
      text = lang,
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
          text = string.format(_("Translate: %s"), lang_copy),
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
  local features = self.settings:readSetting("features") or {}
  local user_languages = features.user_languages or ""
  local primary_language = features.primary_language or "English"

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
    separator = true,
  })

  -- Parse user's language list
  local languages = {}
  for lang in user_languages:gmatch("[^,]+") do
    local trimmed = lang:match("^%s*(.-)%s*$")
    if trimmed ~= "" then
      table.insert(languages, trimmed)
    end
  end

  -- Add each language as an option
  for _i, lang in ipairs(languages) do
    local lang_copy = lang
    table.insert(menu_items, {
      text = lang,
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
          text = string.format(_("Dictionary: %s"), lang_copy),
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
          text = string.format(_("Context: %s"), mode.text),
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
  local BehaviorManager = require("ui/behavior_manager")
  local manager = BehaviorManager:new(self)
  manager:show()
end

-- Show domain manager UI
function AskGPT:showDomainManager()
  local DomainManager = require("ui/domain_manager")
  local manager = DomainManager:new(self)
  manager:show()
end

function AskGPT:addToMainMenu(menu_items)
  menu_items["koassistant"] = {
    text = _("KOAssistant"),
    sorting_hint = "tools",
    sorting_order = 1,
    sub_item_table_func = function()
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

  local self_ref = self

  -- Extract the word from the dictionary popup
  local word = dict_popup and dict_popup.word
  if not word or word == "" then
    return
  end

  -- Get configured actions for dictionary popup
  local popup_actions = self.action_service:getDictionaryPopupActionObjects()
  if #popup_actions == 0 then
    return  -- No actions configured
  end

  -- Helper function to create a button for an action
  local function createActionButton(action)
    return {
      text = action.text .. " (AI)",
      font_bold = true,
      callback = function()
        -- CRITICAL: Extract context BEFORE closing the popup
        -- The highlight/selection is cleared when the popup closes
        local context = ""
        local context_mode = features.dictionary_context_mode or "sentence"

        if context_mode ~= "none" then
          local context_chars = features.dictionary_context_chars or 100

          -- Method 1: Try KOReader's highlight module (works for hold-select, NOT for word tap)
          -- Note: For single word taps, getSelectedWordContext returns nil because
          -- no actual text selection exists - only the word at tap position is identified
          if self_ref.ui and self_ref.ui.highlight and self_ref.ui.highlight.getSelectedWordContext then
            context = Dialogs.extractSurroundingContext(
              self_ref.ui,
              word,
              context_mode,
              context_chars
            )
          end

          -- Log result (helpful for debugging)
          if context ~= "" then
            logger.info("KOAssistant DICT: Got context (" .. #context .. " chars)")
          else
            -- Context extraction failed - this is expected for word taps
            -- For context to work, user needs to hold-select the word instead of tapping
            logger.info("KOAssistant DICT: No context available (word tap, not selection)")
          end
        end

        -- Now close the dictionary popup
        if dict_popup.onClose then
          dict_popup:onClose()
        end

        -- Ensure network is available
        NetworkMgr:runWhenOnline(function()
          -- Get effective dictionary language
          local SystemPrompts = require("prompts.system_prompts")
          local dict_language = SystemPrompts.getEffectiveDictionaryLanguage({
            dictionary_language = features.dictionary_language,
            translation_language = features.translation_language,
            translation_use_primary = features.translation_use_primary,
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
          dict_config.features.dictionary_context = context
          dict_config.features.dictionary_language = dict_language
          dict_config.features.dictionary_context_mode = features.dictionary_context_mode or "sentence"

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
          local Dialogs = require("dialogs")
          Dialogs.executeDirectAction(
            self_ref.ui,   -- ui
            action,        -- action (from closure)
            word,          -- highlighted_text
            dict_config,   -- local config copy (not global)
            self_ref       -- plugin
          )
        end)
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
  local ChatHistoryManager = require("chat_history_manager")
  local ChatHistoryDialog = require("chat_history_dialog")

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
  local ChatHistoryManager = require("chat_history_manager")
  local ChatHistoryDialog = require("chat_history_dialog")

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

  NetworkMgr:runWhenOnline(function()
    maybeCheckForUpdates(self)
    -- Make sure we're using the latest configuration
    self:updateConfigFromSettings()

    -- Set context flag on the original configuration (no copy needed)
    -- This ensures settings changes are immediately visible
    configuration.features = configuration.features or {}
    -- Clear other context flags first
    configuration.features.is_general_context = true
    configuration.features.is_book_context = nil
    configuration.features.is_multi_book_context = nil

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
  
  -- Get book metadata and use the same implementation as showAssistantDialogForFile
  local doc_props = self.ui.document:getProps()
  local title = doc_props.title or "Unknown"
  local authors = doc_props.authors or ""
  
  -- Call the existing function that handles file browser context properly
  self:showKOAssistantDialogForFile(self.ui.document.file, title, authors, doc_props)
  return true
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
  local menu_items = self:buildProviderMenu()
  self:showQuickSettingsPopup(_("Provider"), menu_items)
  return true
end

function AskGPT:onKOAssistantChangeModel()
  local menu_items = self:buildModelMenu()
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

  return items
end

--- Combined AI Quick Settings popup (for gesture action)
--- Two-column layout with commonly used settings
--- @param on_close_callback function: Optional callback called when user closes the dialog
function AskGPT:onKOAssistantAISettings(on_close_callback)
  local ButtonDialog = require("ui/widget/buttondialog")
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
  local model = self:getCurrentModel() or "default"
  local behavior_id = features.selected_behavior or "standard"
  local temp = features.default_temperature or 0.7
  local streaming = features.enable_streaming ~= false  -- Default true

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

  -- Get primary language display
  local user_languages = features.user_languages or ""
  local primary_lang = features.primary_language
  local lang_display = _("Default")
  if user_languages ~= "" then
    local first_lang = user_languages:match("^%s*([^,]+)")
    if first_lang then
      first_lang = first_lang:match("^%s*(.-)%s*$")  -- trim
    end
    lang_display = primary_lang or first_lang or _("Default")
  end

  -- Get translation language display
  local trans_lang = features.translation_language
  local trans_display
  if trans_lang == nil or trans_lang == "" or trans_lang == "__PRIMARY__" then
    trans_display = lang_display  -- Use primary language
  else
    trans_display = trans_lang
  end

  -- Get dictionary language display
  local dict_lang = features.dictionary_language
  local dict_display
  if dict_lang == nil or dict_lang == "" or dict_lang == "__FOLLOW_TRANSLATION__" then
    dict_display = trans_display .. " ↵"  -- Follow translation (arrow indicates "same as")
  else
    dict_display = dict_lang
  end

  -- Flag to track if we're closing for a sub-dialog (vs true dismissal)
  local opening_subdialog = false

  local dialog
  dialog = ButtonDialog:new{
    title = _("AI Quick Settings"),
    buttons = {
      -- Row 1: Provider | Model
      {
        {
          text = string.format(_("Provider: %s"), provider:gsub("^%l", string.upper)),
          callback = function()
            opening_subdialog = true
            UIManager:close(dialog)
            local menu_items = self_ref:buildProviderMenu()
            self_ref:showQuickSettingsPopup(_("Provider"), menu_items, true, reopenQuickSettings)
          end,
        },
        {
          text = string.format(_("Model: %s"), model),
          callback = function()
            opening_subdialog = true
            UIManager:close(dialog)
            local menu_items = self_ref:buildModelMenu()
            self_ref:showQuickSettingsPopup(_("Model"), menu_items, true, reopenQuickSettings)
          end,
        },
      },
      -- Row 2: Behavior | Domain
      {
        {
          text = string.format(_("Behavior: %s"), behavior_display),
          callback = function()
            opening_subdialog = true
            UIManager:close(dialog)
            local menu_items = self_ref:buildBehaviorMenu()
            self_ref:showQuickSettingsPopup(_("AI Behavior"), menu_items, true, reopenQuickSettings)
          end,
        },
        {
          text = string.format(_("Domain: %s"), domain_display),
          callback = function()
            opening_subdialog = true
            UIManager:close(dialog)
            local menu_items = self_ref:buildDomainMenu()
            self_ref:showQuickSettingsPopup(_("Knowledge Domain"), menu_items, true, reopenQuickSettings)
          end,
        },
      },
      -- Row 3: Temperature | Streaming
      {
        {
          text = string.format(_("Temp: %.1f"), temp),
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
        },
        {
          text = streaming and _("Streaming: ON") or _("Streaming: OFF"),
          callback = function()
            -- Toggle streaming directly
            local f = self_ref.settings:readSetting("features") or {}
            f.enable_streaming = not (f.enable_streaming ~= false)
            self_ref.settings:saveSetting("features", f)
            self_ref.settings:flush()
            self_ref:updateConfigFromSettings()
            -- Reopen to show updated state
            opening_subdialog = true
            UIManager:close(dialog)
            reopenQuickSettings()
          end,
        },
      },
      -- Row 4: Language | Translation
      {
        {
          text = string.format(_("Language: %s"), lang_display),
          callback = function()
            opening_subdialog = true
            UIManager:close(dialog)
            local menu_items = self_ref:buildPrimaryLanguageMenu()
            if #menu_items == 0 then
              -- No languages configured, show info
              local InfoMessage = require("ui/widget/infomessage")
              UIManager:show(InfoMessage:new{
                text = _("Configure your languages in Settings → Language first."),
                timeout = 3,
              })
              reopenQuickSettings()
            else
              self_ref:showQuickSettingsPopup(_("Primary Language"), menu_items, true, reopenQuickSettings)
            end
          end,
        },
        {
          text = string.format(_("Translate: %s"), trans_display),
          callback = function()
            opening_subdialog = true
            UIManager:close(dialog)
            local menu_items = self_ref:buildTranslationLanguageMenu()
            self_ref:showQuickSettingsPopup(_("Translation Language"), menu_items, true, reopenQuickSettings)
          end,
        },
      },
      -- Row 5: Dictionary | More Settings
      {
        {
          text = string.format(_("Dictionary: %s"), dict_display),
          callback = function()
            opening_subdialog = true
            UIManager:close(dialog)
            local menu_items = self_ref:buildDictionaryLanguageMenu()
            self_ref:showQuickSettingsPopup(_("Dictionary Language"), menu_items, true, reopenQuickSettings)
          end,
        },
        {
          text = _("More Settings..."),
          callback = function()
            opening_subdialog = true
            UIManager:close(dialog)
            -- Open full settings menu
            self_ref:onKOAssistantSettings()
          end,
        },
      },
      -- Row 6: Close (full width)
      {
        {
          text = _("Close"),
          callback = function()
            opening_subdialog = true
            UIManager:close(dialog)
            if on_close_callback then
              on_close_callback()
            end
          end,
        },
      },
    },
    -- Handle all forms of dismissal (back button, tap outside, etc.)
    close_callback = function()
      if not opening_subdialog and on_close_callback then
        on_close_callback()
      end
    end,
  }
  UIManager:show(dialog)
  return true
end

function AskGPT:testProviderConnection()
  local InfoMessage = require("ui/widget/infomessage")
  local UIManager = require("ui/uimanager")
  local GptQuery = require("gpt_query")
  local queryChatGPT = GptQuery.query
  local isStreamingInProgress = GptQuery.isStreamingInProgress
  local MessageHistory = require("message_history")

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
            text = string.format(_("Connection test successful!\n\nProvider: %s\nModel: %s\n\nResponse: %s"),
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
  local config_copy = {}
  for k, v in pairs(configuration) do
    config_copy[k] = v
  end
  config_copy.features = config_copy.features or {}
  for k, v in pairs(configuration.features or {}) do
    config_copy.features[k] = v
  end
  config_copy.context = "highlight"
  -- Explicitly ensure full view (not compact)
  config_copy.features.compact_view = false
  config_copy.features.minimal_buttons = false

  -- Execute translation
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
function AskGPT:buildDictionaryLanguageMenu()
  local self_ref = self
  local features = self.settings:readSetting("features") or {}
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

  -- Parse user languages if available
  local user_languages = features.user_languages or ""
  if user_languages ~= "" then
    for lang in user_languages:gmatch("[^,]+") do
      local trimmed = lang:match("^%s*(.-)%s*$")
      if trimmed and trimmed ~= "" then
        local lang_copy = trimmed
        table.insert(items, {
          text = lang_copy,
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
  end

  -- Add common languages if no user languages configured
  if #items == 1 then
    local common_languages = {"English", "Spanish", "French", "German", "Chinese", "Japanese", "Korean"}
    for _idx, lang in ipairs(common_languages) do
      local lang_copy = lang
      table.insert(items, {
        text = lang_copy,
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

-- Register quick actions for highlight menu
-- Called during init to add user-configured actions directly to the highlight popup
function AskGPT:registerHighlightMenuActions()
  if not self.ui or not self.ui.highlight then return end

  local quick_actions = self.action_service:getHighlightMenuActionObjects()
  if #quick_actions == 0 then
    logger.info("KOAssistant: No quick actions configured for highlight menu")
    return
  end

  logger.info("KOAssistant: Registering " .. #quick_actions .. " quick actions for highlight menu")

  for _i, action in ipairs(quick_actions) do
    local dialog_id = "koassistant_quick_" .. action.id
    local action_copy = action  -- Capture in closure

    self.ui.highlight:addToHighlightDialog(dialog_id, function(_reader_highlight_instance)
      return {
        text = action_copy.text .. " (KOA)",
        enabled = Device:hasClipboard(),
        callback = function()
          -- Extract context BEFORE network callback, while selection is still active
          -- This is important for dictionary actions that need surrounding text
          local context = ""
          -- Check if highlight module has the getSelectedWordContext method
          -- Note: Method is on self.ui.highlight, not _reader_highlight_instance
          if self.ui.highlight and self.ui.highlight.getSelectedWordContext then
            local features = self.settings:readSetting("features") or {}
            local context_mode = features.dictionary_context_mode or "sentence"
            -- Skip context extraction if mode is "none"
            if context_mode ~= "none" then
              local context_chars = features.dictionary_context_chars or 100
              context = Dialogs.extractSurroundingContext(
                self.ui,
                _reader_highlight_instance.selected_text.text,
                context_mode,
                context_chars
              )
            end
          end

          NetworkMgr:runWhenOnline(function()
            self:updateConfigFromSettings()
            -- Pass extracted context to executeQuickAction
            self:executeQuickAction(action_copy, _reader_highlight_instance.selected_text.text, context)
          end)
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

      -- IMPORTANT: Extract context BEFORE clearing highlight
      -- The highlight object contains the selection state needed for context extraction.
      -- Once cleared, getSelectedWordContext() will return nil.
      local context = ""
      local context_mode = features.dictionary_context_mode or "sentence"
      if context_mode ~= "none" then
        local context_chars = features.dictionary_context_chars or 100
        if self_ref.ui and self_ref.ui.highlight then
          context = Dialogs.extractSurroundingContext(
            self_ref.ui,
            word,
            context_mode,
            context_chars
          )
          if context and context ~= "" then
            logger.info("KOAssistant BYPASS: Got context (" .. #context .. " chars)")
          else
            logger.info("KOAssistant BYPASS: No context available")
          end
        end
      end

      -- NOW clear the selection highlight (after context extraction)
      -- KOReader uses highlight:clear() to remove the selection highlight
      if highlight and highlight.clear then
        highlight:clear()
      end
      -- Also call the close callback if provided (for additional cleanup)
      if dict_close_callback then
        dict_close_callback()
      end

      -- Execute the default action directly (context already captured above)
      NetworkMgr:runWhenOnline(function()
        -- Get effective dictionary language
        local SystemPrompts = require("prompts.system_prompts")
        local dict_language = SystemPrompts.getEffectiveDictionaryLanguage({
          dictionary_language = features.dictionary_language,
          translation_language = features.translation_language,
          translation_use_primary = features.translation_use_primary,
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
        dict_config.features.dictionary_context = context
        dict_config.features.dictionary_language = dict_language
        dict_config.features.dictionary_context_mode = features.dictionary_context_mode or "sentence"

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
  local config_copy = {}
  for k, v in pairs(configuration) do
    config_copy[k] = v
  end
  config_copy.features = config_copy.features or {}
  for k, v in pairs(configuration.features or {}) do
    config_copy.features[k] = v
  end
  config_copy.context = "highlight"

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
    local action_text = action.text
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
    local action_text = action.text
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
function AskGPT:executeQuickAction(action, highlighted_text, context)
  -- Clear context flags for highlight context (default context)
  configuration.features = configuration.features or {}
  configuration.features.is_general_context = nil
  configuration.features.is_book_context = nil
  configuration.features.is_multi_book_context = nil
  -- Pass surrounding context if provided (for dictionary actions)
  if context and context ~= "" then
    configuration.features.dictionary_context = context
  end
  Dialogs.executeDirectAction(self.ui, action, highlighted_text, configuration, self)
end

function AskGPT:restoreDefaultPrompts()
  -- Clear custom actions and disabled prompts
  self.settings:saveSetting("custom_actions", {})
  self.settings:saveSetting("disabled_prompts", {})
  self.settings:flush()

  UIManager:show(InfoMessage:new{
    text = _("Default actions restored"),
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

  NetworkMgr:runWhenOnline(function()
    maybeCheckForUpdates(self)
    -- Make sure we're using the latest configuration
    self:updateConfigFromSettings()

    -- Set context flag on the original configuration (no copy needed)
    -- This ensures settings changes are immediately visible
    configuration.features = configuration.features or {}
    -- Clear other context flags first
    configuration.features.is_general_context = true
    configuration.features.is_book_context = nil
    configuration.features.is_multi_book_context = nil

    -- Show dialog with general context
    showChatGPTDialog(self.ui, nil, configuration, nil, self)
  end)
end

function AskGPT:showChatHistory()
  -- Load the chat history manager
  local ChatHistoryManager = require("chat_history_manager")
  local chat_history_manager = ChatHistoryManager:new()
  
  -- Get the current document path if a document is open
  local document_path = nil
  if self.ui and self.ui.document and self.ui.document.file then
      document_path = self.ui.document.file
  end
  
  -- Show the chat history browser
  local ChatHistoryDialog = require("chat_history_dialog")
  ChatHistoryDialog:showChatHistoryBrowser(
      self.ui, 
      document_path,
      chat_history_manager, 
      configuration
  )
end

function AskGPT:checkForUpdates()
  NetworkMgr:runWhenOnline(function()
    UpdateChecker.checkForUpdates(false) -- false = not silent
  end)
end

function AskGPT:showAbout()
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
  local FileManager = require("apps/filemanager/filemanager")
  local ButtonDialog = require("ui/widget/buttondialog")

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
          -- Find insertion point (after coverbrowser button if present)
          local insert_position = 7
          for i, row in ipairs(o.buttons) do
            if row and row[1] and row[1].text == _("Refresh cached book information") then
              insert_position = i + 1
              break
            end
          end
          
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
            table.insert(o.buttons, insert_position, koassistant_button)
            logger.info("KOAssistant: Added multi-select button to dialog at position " .. insert_position)
          end
        end
      end

      -- Call original constructor
      return ButtonDialog._orig_new_koassistant(self, o)
    end

    logger.info("KOAssistant: Patched ButtonDialog.new for multi-select support")
  end
end

return AskGPT