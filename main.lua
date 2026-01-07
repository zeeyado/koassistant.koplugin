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
  
  -- Register to main menu immediately
  self:registerToMainMenu()
  
  -- Also register when reader is ready as a backup
  self.onReaderReady = function()
    self:registerToMainMenu()
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
  
  -- Create a copy of configuration with file browser context
  local temp_config = {}
  for k, v in pairs(configuration) do
    if type(v) == "table" then
      temp_config[k] = {}
      for k2, v2 in pairs(v) do
        temp_config[k][k2] = v2
      end
    else
      temp_config[k] = v
    end
  end
  
  -- Ensure features exists
  temp_config.features = temp_config.features or {}
  
  -- Get book context configuration
  local book_context_config = temp_config.features.book_context or {
    prompts = {}
  }
  
  logger.info("Book context has " .. 
    (book_context_config.prompts and tostring(table_count(book_context_config.prompts)) or "0") .. 
    " prompts defined")
  
  -- Don't set system prompt here - let dialogs.lua handle it based on context
  -- Store book metadata separately for use in prompts
  if book_context and book_context ~= "" then
    temp_config.features.book_context = book_context
  end
  
  -- Mark this as book context
  temp_config.features.is_book_context = true
  
  -- Store the book metadata for template substitution
  temp_config.features.book_metadata = {
    title = title,
    author = authors,
    author_clause = authors ~= "" and string.format(" by %s", authors) or "",
    file = file  -- Add file path for chat saving
  }
  
  NetworkMgr:runWhenOnline(function()
    maybeCheckForUpdates(self)
    -- Show dialog with book context instead of highlighted text
    showChatGPTDialog(self.ui, book_context, temp_config, nil, self)
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
  
  -- Create a copy of configuration with file browser context
  local temp_config = {}
  for k, v in pairs(configuration) do
    if type(v) == "table" then
      temp_config[k] = {}
      for k2, v2 in pairs(v) do
        temp_config[k][k2] = v2
      end
    else
      temp_config[k] = v
    end
  end
  
  -- Ensure features exists
  temp_config.features = temp_config.features or {}
  
  -- Mark this as multi book context
  temp_config.features.is_multi_book_context = true
  
  -- Store the books list as context
  temp_config.features.book_context = prompt_text
  temp_config.features.books_info = books_info  -- Store the parsed book info for template substitution
  
  -- Store metadata for template substitution (using first book's info)
  if #books_info > 0 then
    temp_config.features.book_metadata = {
      title = books_info[1].title,
      author = books_info[1].authors,
      author_clause = books_info[1].authors ~= "" and string.format(" by %s", books_info[1].authors) or ""
    }
  end
  
  NetworkMgr:runWhenOnline(function()
    maybeCheckForUpdates(self)
    -- Don't update from settings as we want our temp_config
    -- Pass the prompt as book context with book configuration
    -- Use FileManager.instance as the UI context
    local ui_context = self.ui or FileManager.instance
    showChatGPTDialog(ui_context, prompt_text, temp_config, nil, self)
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
      large_stream_dialog = true,  -- Default to full-screen streaming dialog
      -- Anthropic settings
      ai_behavior_variant = "full", -- AI behavior style: "minimal" (~100 tokens) or "full" (~500 tokens)
    })
  end

  -- Migration for existing users: add new settings with defaults
  -- This runs even if features already exists (for users upgrading from older versions)
  local features = self.settings:readSetting("features")
  if features then
    local needs_save = false

    -- Add ai_behavior_variant if missing
    if features.ai_behavior_variant == nil then
      features.ai_behavior_variant = "full"
      needs_save = true
    end

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

    if needs_save then
      self.settings:saveSetting("features", features)
      logger.info("KOAssistant: Migrated settings - added new request format options")
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

  -- Log the current configuration for debugging
  local config_parts = {
    "provider=" .. (configuration.provider or "nil"),
    "model=" .. (configuration.model or "default"),
  }

  -- Always show AI behavior variant
  table.insert(config_parts, "behavior=" .. (features.ai_behavior_variant or "full"))

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

  for _, provider in ipairs(providers) do
    table.insert(items, {
      text = provider:gsub("^%l", string.upper),  -- Capitalize
      checked_func = function() return self_ref:getCurrentProvider() == provider end,
      radio = true,
      callback = function()
        local features = self_ref.settings:readSetting("features") or {}
        local old_provider = features.provider

        -- Reset model to new provider's default when provider changes
        if old_provider ~= provider then
          local provider_defaults = Defaults.ProviderDefaults[provider]
          if provider_defaults and provider_defaults.model then
            features.model = provider_defaults.model
          else
            features.model = nil  -- Clear if no default
          end
        end

        features.provider = provider
        self_ref.settings:saveSetting("features", features)
        self_ref.settings:flush()
        self_ref:updateConfigFromSettings()
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
    for _, lang in ipairs(languages) do
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
      end,
      keep_menu_open = true,
    })
  end

  return menu_items
end

-- Build translation language picker menu
function AskGPT:buildTranslationLanguageMenu()
  local self_ref = self
  local features = self.settings:readSetting("features") or {}
  local user_languages = features.user_languages or ""

  local menu_items = {}

  -- Parse languages from user_languages
  local languages = {}
  for lang in user_languages:gmatch("([^,]+)") do
    local trimmed = lang:match("^%s*(.-)%s*$")
    if trimmed ~= "" then
      table.insert(languages, trimmed)
    end
  end

  -- Add each language as an option
  for _, lang in ipairs(languages) do
    local lang_copy = lang  -- Capture for closure
    table.insert(menu_items, {
      text = lang,
      checked_func = function()
        local f = self_ref.settings:readSetting("features") or {}
        return (f.translation_language or "English") == lang_copy
      end,
      radio = true,
      callback = function()
        local f = self_ref.settings:readSetting("features") or {}
        f.translation_language = lang_copy
        self_ref.settings:saveSetting("features", f)
        self_ref.settings:flush()
      end,
      keep_menu_open = true,
    })
  end

  -- Add separator if we have languages
  if #languages > 0 then
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

    -- Create a temp config with general context flag
    local temp_config = {}
    for k, v in pairs(configuration) do
      if type(v) ~= "table" then
        temp_config[k] = v
      else
        temp_config[k] = {}
        for k2, v2 in pairs(v) do
          temp_config[k][k2] = v2
        end
      end
    end
    temp_config.features = temp_config.features or {}
    temp_config.features.is_general_context = true
    
    -- Show dialog with general context
    showChatGPTDialog(self.ui, nil, temp_config, nil, self)
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

function AskGPT:showPromptsManager()
  local prompts_manager = PromptsManager:new(self)
  prompts_manager:show()
end

function AskGPT:showHighlightMenuManager()
  local prompts_manager = PromptsManager:new(self)
  prompts_manager:showHighlightMenuManager()
end

function AskGPT:showDomainsViewer()
  local DomainLoader = require("domain_loader")
  local all_domains = DomainLoader.load()
  local sorted_ids = DomainLoader.getSortedIds(all_domains)

  -- Build info text showing all domains
  local lines = {}
  table.insert(lines, _("WHAT ARE DOMAINS?"))
  table.insert(lines, _("Knowledge domains provide background context for AI conversations. When you select a domain, its context is prepended to every message you send."))
  table.insert(lines, "")
  table.insert(lines, _("HOW THEY WORK:"))
  table.insert(lines, _("• Domain context is sent with each message to frame the conversation"))
  table.insert(lines, _("• Larger domains give better results but use more tokens"))
  table.insert(lines, _("• Anthropic supports prompt caching - consecutive messages reuse cached context (~90% cost savings)"))
  table.insert(lines, "")
  table.insert(lines, _("CREATING DOMAINS:"))
  table.insert(lines, _("Create .md or .txt files in the domains/ folder."))
  table.insert(lines, _("See domains.sample/ for examples."))
  table.insert(lines, "")
  table.insert(lines, "────────────────────")
  table.insert(lines, "")

  for _, id in ipairs(sorted_ids) do
    local domain = all_domains[id]
    table.insert(lines, "▸ " .. (domain.name or id))
    -- Show a brief preview of the context (first line or first 100 chars)
    if domain.context then
      local preview = domain.context:match("^[^\n]+") or domain.context
      if #preview > 100 then
        preview = preview:sub(1, 97) .. "..."
      end
      table.insert(lines, "  " .. preview)
    end
    table.insert(lines, "")
  end

  if #sorted_ids == 0 then
    table.insert(lines, _("No domains defined."))
    table.insert(lines, "")
  end

  table.insert(lines, "────────────────────")
  table.insert(lines, "")
  table.insert(lines, string.format(_("Total: %d domains"), #sorted_ids))

  -- Show in a scrollable text viewer
  local TextViewer = require("ui/widget/textviewer")
  UIManager:show(TextViewer:new{
    title = _("Available Domains"),
    text = table.concat(lines, "\n"),
    width = UIConstants.DIALOG_WIDTH(),
    height = UIConstants.DIALOG_HEIGHT(),
  })
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

  for _, action in ipairs(quick_actions) do
    local dialog_id = "koassistant_quick_" .. action.id
    local action_copy = action  -- Capture in closure

    self.ui.highlight:addToHighlightDialog(dialog_id, function(_reader_highlight_instance)
      return {
        text = action_copy.text .. " (KOA)",
        enabled = Device:hasClipboard(),
        callback = function()
          NetworkMgr:runWhenOnline(function()
            self:updateConfigFromSettings()
            self:executeQuickAction(action_copy, _reader_highlight_instance.selected_text.text)
          end)
        end,
      }
    end)
  end
end

-- Execute a quick action directly without showing intermediate dialog
function AskGPT:executeQuickAction(action, highlighted_text)
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
  -- Same logic as onAssistantGeneralChat
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

    -- Create a temp config with general context flag
    local temp_config = {}
    for k, v in pairs(configuration) do
      if type(v) ~= "table" then
        temp_config[k] = v
      else
        temp_config[k] = {}
        for k2, v2 in pairs(v) do
          temp_config[k][k2] = v2
        end
      end
    end
    temp_config.features = temp_config.features or {}
    temp_config.features.is_general_context = true

    -- Show dialog with general context
    showChatGPTDialog(self.ui, nil, temp_config, nil, self)
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