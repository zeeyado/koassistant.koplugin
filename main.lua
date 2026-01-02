local Device = require("device")
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local NetworkMgr = require("ui/network/manager")
local Dispatcher = require("dispatcher")
local _ = require("gettext")
local UIManager = require("ui/uimanager")
local InfoMessage = require("ui/widget/infomessage")
local Menu = require("ui/widget/menu")
local MultiInputDialog = require("ui/widget/multiinputdialog")
local ButtonDialog = require("ui/widget/buttondialog")
local SpinWidget = require("ui/widget/spinwidget")
local LuaSettings = require("luasettings")
local DataStorage = require("datastorage")
local T = require("ffi/util").template
local logger = require("logger")
local util = require("util")
local Screen = Device.screen

local showChatGPTDialog = require("dialogs")
local UpdateChecker = require("update_checker")
local SettingsSchema = require("settings_schema")
local SettingsManager = require("ui/settings_manager")
local PromptsManager = require("ui/prompts_manager")
local UIConstants = require("ui/constants")
local PromptService = require("prompt_service")
local ActionService = require("action_service")

-- Load model lists
local ModelLists = {}
local ok, loaded_lists = pcall(function() 
    local path = package.path
    -- Add the current directory to the package path if not already there
    if not path:match("%./%?%.lua") then
        package.path = "./?.lua;" .. path
    end
    return require("model_lists") 
end)
if ok and loaded_lists then
    ModelLists = loaded_lists
    logger.info("Loaded model lists from model_lists.lua: " .. #(ModelLists.anthropic or {}) .. " Anthropic models, " .. 
                #(ModelLists.openai or {}) .. " OpenAI models, " .. 
                #(ModelLists.deepseek or {}) .. " DeepSeek models, " ..
                #(ModelLists.gemini or {}) .. " Gemini models, " ..
                #(ModelLists.ollama or {}) .. " Ollama models")
else
    logger.warn("Could not load model_lists.lua: " .. tostring(loaded_lists) .. ", using empty lists")
    -- Fallback to basic model lists
    ModelLists = {
        anthropic = {"claude-3-opus-20240229", "claude-3-sonnet-20240229", "claude-3-haiku-20240307"},
        openai = {"gpt-4o", "gpt-4-turbo", "gpt-3.5-turbo"},
        deepseek = {"deepseek-chat"},
        gemini = {"gemini-1.5-pro", "gemini-1.0-pro"},
        ollama = {"llama3", "mistral", "mixtral"}
    }
end

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
  
  -- Initialize prompt service (legacy, kept for backwards compatibility)
  self.prompt_service = PromptService:new(self.settings)
  self.prompt_service:initialize()

  -- Initialize action service (new primary service)
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
  
  -- Perform one-time migration from old prompt format
  if not self.settings:readSetting("prompts_migrated_v2") then
    self:migratePromptsV2()
    self.settings:saveSetting("prompts_migrated_v2", true)
    self.settings:flush()
  end
  
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
      translate_to = configuration.features.translate_to or "English",
      debug = configuration.features.debug or false,
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
  if features.enable_extended_thinking then
    table.insert(config_parts, "thinking=" .. (features.thinking_budget_tokens or 4096))
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
  local providers = {"anthropic", "openai", "deepseek", "gemini", "ollama"}
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

-- Helper: Show temperature SpinWidget
function AskGPT:showTemperatureSpinner(touchmenu)
  local features = self.settings:readSetting("features") or {}
  UIManager:show(SpinWidget:new{
    title_text = _("Temperature"),
    info_text = _("Controls response randomness\n0 = focused, 2 = creative\n(Forced to 1.0 with extended thinking)"),
    value = features.default_temperature or 0.7,
    value_min = 0,
    value_max = 2,
    value_step = 0.1,
    precision = "%.1f",
    default_value = 0.7,
    callback = function(spin)
      features.default_temperature = spin.value
      self.settings:saveSetting("features", features)
      self.settings:flush()
      self:updateConfigFromSettings()
    end,
    close_callback = function()
      if touchmenu then touchmenu:updateItems() end
    end,
  })
end

-- Helper: Show thinking budget SpinWidget
function AskGPT:showThinkingBudgetSpinner(touchmenu)
  local features = self.settings:readSetting("features") or {}
  UIManager:show(SpinWidget:new{
    title_text = _("Thinking Token Budget"),
    info_text = _("Maximum tokens for AI reasoning\n(Anthropic extended thinking only)"),
    value = features.thinking_budget_tokens or 4096,
    value_min = 1024,
    value_max = 32000,
    value_step = 1024,
    default_value = 4096,
    callback = function(spin)
      features.thinking_budget_tokens = spin.value
      self.settings:saveSetting("features", features)
      self.settings:flush()
      self:updateConfigFromSettings()
    end,
    close_callback = function()
      if touchmenu then touchmenu:updateItems() end
    end,
  })
end

-- Helper: Build Display Settings sub-menu
function AskGPT:buildDisplaySettings()
  local self_ref = self
  return {
    {
      text = _("Render Markdown"),
      checked_func = function()
        local f = self_ref.settings:readSetting("features") or {}
        return f.render_markdown ~= false
      end,
      callback = function()
        local f = self_ref.settings:readSetting("features") or {}
        f.render_markdown = not (f.render_markdown ~= false)
        self_ref.settings:saveSetting("features", f)
        self_ref.settings:flush()
        self_ref:updateConfigFromSettings()
      end,
      keep_menu_open = true,
    },
    {
      text = _("Hide Highlighted Text"),
      checked_func = function()
        local f = self_ref.settings:readSetting("features") or {}
        return f.hide_highlighted_text == true
      end,
      callback = function()
        local f = self_ref.settings:readSetting("features") or {}
        f.hide_highlighted_text = not f.hide_highlighted_text
        self_ref.settings:saveSetting("features", f)
        self_ref.settings:flush()
        self_ref:updateConfigFromSettings()
      end,
      keep_menu_open = true,
    },
    {
      text = _("Hide Long Highlights"),
      checked_func = function()
        local f = self_ref.settings:readSetting("features") or {}
        return f.hide_long_highlights ~= false
      end,
      callback = function()
        local f = self_ref.settings:readSetting("features") or {}
        f.hide_long_highlights = not (f.hide_long_highlights ~= false)
        self_ref.settings:saveSetting("features", f)
        self_ref.settings:flush()
        self_ref:updateConfigFromSettings()
      end,
      keep_menu_open = true,
    },
    {
      text_func = function()
        local f = self_ref.settings:readSetting("features") or {}
        return T(_("Long Highlight Threshold: %1"), f.long_highlight_threshold or 280)
      end,
      enabled_func = function()
        local f = self_ref.settings:readSetting("features") or {}
        return f.hide_long_highlights ~= false
      end,
      callback = function()
        self_ref:showThresholdDialog()
      end,
      keep_menu_open = true,
    },
  }
end

-- Helper: Build Chat Settings sub-menu
function AskGPT:buildChatSettings()
  local self_ref = self
  return {
    {
      text = _("Auto-save All Chats"),
      checked_func = function()
        local f = self_ref.settings:readSetting("features") or {}
        return f.auto_save_all_chats ~= false
      end,
      callback = function()
        local f = self_ref.settings:readSetting("features") or {}
        f.auto_save_all_chats = not (f.auto_save_all_chats ~= false)
        self_ref.settings:saveSetting("features", f)
        self_ref.settings:flush()
        self_ref:updateConfigFromSettings()
      end,
      keep_menu_open = true,
    },
    {
      text = _("Auto-save Continued Chats"),
      enabled_func = function()
        local f = self_ref.settings:readSetting("features") or {}
        return f.auto_save_all_chats == false
      end,
      checked_func = function()
        local f = self_ref.settings:readSetting("features") or {}
        return f.auto_save_chats ~= false
      end,
      callback = function()
        local f = self_ref.settings:readSetting("features") or {}
        f.auto_save_chats = not (f.auto_save_chats ~= false)
        self_ref.settings:saveSetting("features", f)
        self_ref.settings:flush()
        self_ref:updateConfigFromSettings()
      end,
      keep_menu_open = true,
      separator = true,
    },
    {
      text = _("Enable Streaming"),
      checked_func = function()
        local f = self_ref.settings:readSetting("features") or {}
        return f.enable_streaming ~= false
      end,
      callback = function()
        local f = self_ref.settings:readSetting("features") or {}
        f.enable_streaming = not (f.enable_streaming ~= false)
        self_ref.settings:saveSetting("features", f)
        self_ref.settings:flush()
        self_ref:updateConfigFromSettings()
      end,
      keep_menu_open = true,
    },
    {
      text = _("Auto-scroll Streaming"),
      enabled_func = function()
        local f = self_ref.settings:readSetting("features") or {}
        return f.enable_streaming ~= false
      end,
      checked_func = function()
        local f = self_ref.settings:readSetting("features") or {}
        return f.stream_auto_scroll ~= false
      end,
      callback = function()
        local f = self_ref.settings:readSetting("features") or {}
        f.stream_auto_scroll = not (f.stream_auto_scroll ~= false)
        self_ref.settings:saveSetting("features", f)
        self_ref.settings:flush()
        self_ref:updateConfigFromSettings()
      end,
      keep_menu_open = true,
    },
    {
      text = _("Large Stream Dialog"),
      enabled_func = function()
        local f = self_ref.settings:readSetting("features") or {}
        return f.enable_streaming ~= false
      end,
      checked_func = function()
        local f = self_ref.settings:readSetting("features") or {}
        return f.large_stream_dialog ~= false
      end,
      callback = function()
        local f = self_ref.settings:readSetting("features") or {}
        f.large_stream_dialog = not (f.large_stream_dialog ~= false)
        self_ref.settings:saveSetting("features", f)
        self_ref.settings:flush()
        self_ref:updateConfigFromSettings()
      end,
      keep_menu_open = true,
    },
  }
end

-- Helper: Build Advanced Settings sub-menu
function AskGPT:buildAdvancedSettings()
  local self_ref = self
  return {
    -- AI Behavior
    {
      text_func = function()
        local f = self_ref.settings:readSetting("features") or {}
        local variant = f.ai_behavior_variant or "full"
        return T(_("AI Behavior: %1"), variant == "minimal" and _("Minimal") or _("Full"))
      end,
      sub_item_table = {
        {
          text = _("Minimal (~100 tokens)"),
          checked_func = function()
            local f = self_ref.settings:readSetting("features") or {}
            return (f.ai_behavior_variant or "full") == "minimal"
          end,
          radio = true,
          callback = function()
            local f = self_ref.settings:readSetting("features") or {}
            f.ai_behavior_variant = "minimal"
            self_ref.settings:saveSetting("features", f)
            self_ref.settings:flush()
            self_ref:updateConfigFromSettings()
          end,
          keep_menu_open = true,
        },
        {
          text = _("Full (~500 tokens)"),
          checked_func = function()
            local f = self_ref.settings:readSetting("features") or {}
            return (f.ai_behavior_variant or "full") == "full"
          end,
          radio = true,
          callback = function()
            local f = self_ref.settings:readSetting("features") or {}
            f.ai_behavior_variant = "full"
            self_ref.settings:saveSetting("features", f)
            self_ref.settings:flush()
            self_ref:updateConfigFromSettings()
          end,
          keep_menu_open = true,
        },
      },
      separator = true,
    },
    -- Extended Thinking
    {
      text = _("Enable Extended Thinking"),
      checked_func = function()
        local f = self_ref.settings:readSetting("features") or {}
        return f.enable_extended_thinking == true
      end,
      callback = function()
        local f = self_ref.settings:readSetting("features") or {}
        f.enable_extended_thinking = not f.enable_extended_thinking
        self_ref.settings:saveSetting("features", f)
        self_ref.settings:flush()
        self_ref:updateConfigFromSettings()
      end,
      keep_menu_open = true,
    },
    {
      text_func = function()
        local f = self_ref.settings:readSetting("features") or {}
        return T(_("Thinking Budget: %1"), f.thinking_budget_tokens or 4096)
      end,
      enabled_func = function()
        local f = self_ref.settings:readSetting("features") or {}
        return f.enable_extended_thinking == true
      end,
      callback = function(touchmenu)
        self_ref:showThinkingBudgetSpinner(touchmenu)
      end,
      keep_menu_open = true,
      separator = true,
    },
    -- Debug
    {
      text = _("Debug Mode"),
      checked_func = function()
        local f = self_ref.settings:readSetting("features") or {}
        return f.debug == true
      end,
      callback = function()
        local f = self_ref.settings:readSetting("features") or {}
        f.debug = not f.debug
        self_ref.settings:saveSetting("features", f)
        self_ref.settings:flush()
        self_ref:updateConfigFromSettings()
      end,
      keep_menu_open = true,
    },
    {
      text_func = function()
        local f = self_ref.settings:readSetting("features") or {}
        local level = f.debug_display_level or "names"
        local labels = { minimal = _("Minimal"), names = _("Names"), full = _("Full") }
        return T(_("Debug Display: %1"), labels[level] or level)
      end,
      enabled_func = function()
        local f = self_ref.settings:readSetting("features") or {}
        return f.debug == true
      end,
      sub_item_table = {
        {
          text = _("Minimal (user input only)"),
          checked_func = function()
            local f = self_ref.settings:readSetting("features") or {}
            return (f.debug_display_level or "names") == "minimal"
          end,
          radio = true,
          callback = function()
            local f = self_ref.settings:readSetting("features") or {}
            f.debug_display_level = "minimal"
            self_ref.settings:saveSetting("features", f)
            self_ref.settings:flush()
            self_ref:updateConfigFromSettings()
          end,
          keep_menu_open = true,
        },
        {
          text = _("Names (config summary)"),
          checked_func = function()
            local f = self_ref.settings:readSetting("features") or {}
            return (f.debug_display_level or "names") == "names"
          end,
          radio = true,
          callback = function()
            local f = self_ref.settings:readSetting("features") or {}
            f.debug_display_level = "names"
            self_ref.settings:saveSetting("features", f)
            self_ref.settings:flush()
            self_ref:updateConfigFromSettings()
          end,
          keep_menu_open = true,
        },
        {
          text = _("Full (system blocks)"),
          checked_func = function()
            local f = self_ref.settings:readSetting("features") or {}
            return (f.debug_display_level or "names") == "full"
          end,
          radio = true,
          callback = function()
            local f = self_ref.settings:readSetting("features") or {}
            f.debug_display_level = "full"
            self_ref.settings:saveSetting("features", f)
            self_ref.settings:flush()
            self_ref:updateConfigFromSettings()
          end,
          keep_menu_open = true,
        },
      },
      separator = true,
    },
    -- Connection test
    {
      text = _("Test Connection"),
      callback = function()
        self_ref:testProviderConnection()
      end,
    },
  }
end

function AskGPT:addToMainMenu(menu_items)
  local self_ref = self

  menu_items["koassistant"] = {
    text = _("KOAssistant"),
    sorting_hint = "tools",
    sorting_order = 1,
    sub_item_table_func = function()
      return {
        -- Quick actions
        {
          text = _("New General Chat"),
          callback = function()
            self_ref:startGeneralChat()
          end,
        },
        {
          text = _("Chat History"),
          callback = function()
            self_ref:showChatHistory()
          end,
          separator = true,
        },

        -- Top-level settings (Provider, Model, Temperature)
        {
          text_func = function()
            return T(_("Provider: %1"), self_ref:getCurrentProvider():gsub("^%l", string.upper))
          end,
          sub_item_table_func = function()
            return self_ref:buildProviderMenu()
          end,
        },
        {
          text_func = function()
            return T(_("Model: %1"), self_ref:getCurrentModel())
          end,
          sub_item_table_func = function()
            return self_ref:buildModelMenu()
          end,
        },
        {
          text_func = function()
            local f = self_ref.settings:readSetting("features") or {}
            return T(_("Temperature: %1"), string.format("%.1f", f.default_temperature or 0.7))
          end,
          callback = function(touchmenu)
            self_ref:showTemperatureSpinner(touchmenu)
          end,
          keep_menu_open = true,
          separator = true,
        },

        -- Settings categories
        {
          text = _("Display Settings"),
          sub_item_table_func = function()
            return self_ref:buildDisplaySettings()
          end,
        },
        {
          text = _("Chat Settings"),
          sub_item_table_func = function()
            return self_ref:buildChatSettings()
          end,
        },
        {
          text = _("Advanced"),
          sub_item_table_func = function()
            return self_ref:buildAdvancedSettings()
          end,
          separator = true,
        },

        -- Prompts and Domains
        {
          text = _("Manage Prompts"),
          callback = function()
            self_ref:showPromptsManager()
          end,
        },
        {
          text = _("View Domains"),
          callback = function()
            self_ref:showDomainsViewer()
          end,
          separator = true,
        },

        -- About
        {
          text = _("About KOAssistant"),
          callback = function()
            self_ref:showAboutInfo()
          end,
        },
        {
          text = _("Check for Updates"),
          callback = function()
            self_ref:checkForUpdates()
          end,
        },
      }
    end,
  }
end


function AskGPT:showManageModelsDialog()
  -- Show a message that this feature is now managed through model_lists.lua
  UIManager:show(InfoMessage:new{
    text = _("Model lists are now managed through the model_lists.lua file. Please edit this file to add or remove models."),
  })
end

function AskGPT:showThresholdDialog()
  local features = self.settings:readSetting("features")
  -- Store dialog in self to ensure it remains in scope during callbacks
  self.threshold_dialog = MultiInputDialog:new{
    title = _("Long Highlight Threshold"),
    fields = {
      {
        text = tostring(features.long_highlight_threshold or 280),
        hint = _("Number of characters"),
        input_type = "number",
      },
    },
    buttons = {
      {
        {
          text = _("Close"),
          id = "close",
          callback = function()
            UIManager:close(self.threshold_dialog)
          end,
        },
        {
          text = _("Save"),
          callback = function()
            local threshold = tonumber(self.threshold_dialog.fields[1].text)
            if threshold and threshold > 0 then
              features.long_highlight_threshold = threshold
              self.settings:saveSetting("features", features)
              self.settings:flush()
              self:updateConfigFromSettings()
              UIManager:close(self.threshold_dialog)
              UIManager:show(InfoMessage:new{
                text = T(_("Threshold set to %1 characters"), threshold),
              })
            else
              UIManager:show(InfoMessage:new{
                text = _("Please enter a valid positive number"),
              })
            end
          end,
        },
      },
    },
  }
  UIManager:show(self.threshold_dialog)
end

function AskGPT:toggleDebugMode()
  local features = self.settings:readSetting("features")
  features.debug = not features.debug
  self.settings:saveSetting("features", features)
  self.settings:flush()
  self:updateConfigFromSettings()
  UIManager:show(InfoMessage:new{
    text = features.debug and 
           _("Debug mode enabled") or
           _("Debug mode disabled"),
  })
end

function AskGPT:showTranslationDialog()
  local features = self.settings:readSetting("features")
  -- Store dialog in self to ensure it remains in scope during callbacks
  self.translation_dialog = MultiInputDialog:new{
    title = _("Translation Language"),
    fields = {
      {
        text = features.translate_to or "English",
        hint = _("Language name or leave blank to disable"),
      },
    },
    buttons = {
      {
        {
          text = _("Close"),
          id = "close",
          callback = function()
            UIManager:close(self.translation_dialog)
          end,
        },
        {
          text = _("Save"),
          callback = function()
            local language = self.translation_dialog.fields[1].text
            if language == "" then
              language = nil
            end
            features.translate_to = language
            self.settings:saveSetting("features", features)
            self.settings:flush()
            self:updateConfigFromSettings()
            UIManager:close(self.translation_dialog)
            UIManager:show(InfoMessage:new{
              text = language and 
                     T(_("Translation set to %1"), language) or
                     _("Translation disabled"),
            })
          end,
        },
      },
    },
  }
  UIManager:show(self.translation_dialog)
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
            if item.text == "KOAssistant" then
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

-- New settings system callback methods
function AskGPT:getModelMenuItems()
  local current_provider = self.settings:readSetting("provider")
  local current_model = self.settings:readSetting("model")
  local provider_models = ModelLists[current_provider] or {}
  
  local sub_item_table = {}
  
  -- Add models from the list
  for idx, model_name in ipairs(provider_models) do
    table.insert(sub_item_table, {
      text = model_name,
      callback = function()
        self.settings:saveSetting("model", model_name)
        self.settings:flush()
        self:updateConfigFromSettings()
        UIManager:show(InfoMessage:new{
          text = T(_("Model set to %1"), model_name),
        })
      end,
      checked_func = function()
        return self.settings:readSetting("model") == model_name
      end,
    })
  end
  
  -- Add option to use default model
  local Defaults = require("api_handlers/defaults")
  local current_provider = self.settings:readSetting("provider") or "anthropic"
  local default_model = Defaults.getDefaultModel(current_provider)
  table.insert(sub_item_table, {
    text = T(_("Use Default (%1)"), default_model),
    callback = function()
      self.settings:saveSetting("model", nil)
      self.settings:flush()
      self:updateConfigFromSettings()
      UIManager:show(InfoMessage:new{
        text = T(_("Using default model: %1"), default_model),
      })
    end,
    checked_func = function()
      return self.settings:readSetting("model") == nil
    end,
  })
  
  -- Add option to enter custom model
  table.insert(sub_item_table, {
    text = _("Enter Custom Model..."),
    callback = function()
      local current_provider = self.settings:readSetting("provider") or "anthropic"
      local provider_name = ({
        anthropic = _("Anthropic"),
        openai = _("OpenAI"),
        deepseek = _("DeepSeek"),
        gemini = _("Google Gemini"),
        ollama = _("Ollama")
      })[current_provider] or current_provider
      self:showCustomModelDialogForProvider(current_provider, provider_name)
    end,
  })
  
  return sub_item_table
end

function AskGPT:getProviderModelMenu()
  local providers = {
    { id = "anthropic", name = _("Anthropic") },
    { id = "openai", name = _("OpenAI") },
    { id = "deepseek", name = _("DeepSeek") },
    { id = "gemini", name = _("Google Gemini") },
    { id = "ollama", name = _("Ollama") },
  }
  
  local menu_items = {}
  
  -- Create a submenu for each provider
  for i, provider in ipairs(providers) do
    table.insert(menu_items, {
      text = provider.name,
      sub_item_table_func = function()
        -- Regenerate model items each time the submenu is opened
        return self:getProviderModelItems(provider.id, provider.name)
      end,
      checked_func = function()
        return self.settings:readSetting("provider") == provider.id
      end,
    })
  end
  
  return menu_items
end

function AskGPT:getFlatProviderModelMenu()
  local providers = {
    { id = "anthropic", name = _("Anthropic") },
    { id = "openai", name = _("OpenAI") },
    { id = "deepseek", name = _("DeepSeek") },
    { id = "gemini", name = _("Google Gemini") },
    { id = "ollama", name = _("Ollama") },
  }
  
  local current_provider = self.settings:readSetting("provider") or "anthropic"
  local current_model = self.settings:readSetting("model")
  
  local menu_items = {}
  
  -- Create flattened menu showing "Provider: Model" entries
  for idx, provider in ipairs(providers) do
    local provider_models = ModelLists[provider.id] or {}
    
    -- Add separator before each provider group (except first)
    if #menu_items > 0 then
      table.insert(menu_items, { 
        text = "────────────────────",
        enabled = false,
        callback = function() end,
      })
    end
    
    -- Add header for this provider
    table.insert(menu_items, {
      text = provider.name,
      enabled = false,
      bold = true,
    })
    
    -- Add default model option
    local Defaults = require("api_handlers/defaults")
    local default_model = Defaults.getDefaultModel(provider.id)
    table.insert(menu_items, {
      text = T(_("   Default (%1)"), default_model),
      checked_func = function()
        return self.settings:readSetting("provider") == provider.id and
               self.settings:readSetting("model") == nil
      end,
      callback = function()
        self.settings:saveSetting("provider", provider.id)
        self.settings:saveSetting("model", nil)
        self.settings:flush()
        self:updateConfigFromSettings()
        UIManager:show(InfoMessage:new{
          text = T(_("Using %1 with default: %2"), provider.name, default_model),
          timeout = 2,
        })
      end,
    })
    
    -- Add specific models
    for model_idx, model_name in ipairs(provider_models) do
      table.insert(menu_items, {
        text = "   " .. model_name,
        checked_func = function()
          return self.settings:readSetting("provider") == provider.id and 
                 self.settings:readSetting("model") == model_name
        end,
        callback = function()
          self.settings:saveSetting("provider", provider.id)
          self.settings:saveSetting("model", model_name)
          self.settings:flush()
          self:updateConfigFromSettings()
          UIManager:show(InfoMessage:new{
            text = T(_("Using %1: %2"), provider.name, model_name),
            timeout = 2,
          })
        end,
      })
    end
    
    -- Add custom model option
    table.insert(menu_items, {
      text = _("   Enter Custom Model..."),
      callback = function()
        self:showCustomModelDialogForProvider(provider.id, provider.name)
      end,
    })
  end
  
  return menu_items
end

function AskGPT:getProviderModelItems(provider_id, provider_name)
  local provider_models = ModelLists[provider_id] or {}
  local model_items = {}
  
  -- Add specific models for this provider
  for idx, model_name in ipairs(provider_models) do
    table.insert(model_items, {
      text = model_name,
      checked_func = function()
        return self.settings:readSetting("provider") == provider_id and 
               self.settings:readSetting("model") == model_name
      end,
      callback = function(touchmenu_instance)
        self.settings:saveSetting("provider", provider_id)
        self.settings:saveSetting("model", model_name)
        self.settings:flush()
        self:updateConfigFromSettings()
        
        UIManager:show(InfoMessage:new{
          text = T(_("Provider set to %1, Model set to %2"), provider_name, model_name),
          timeout = 2,
        })
        
        -- Go back to parent menu to see updated provider checkmark
        if touchmenu_instance then
          touchmenu_instance:onBack()
        end
      end,
    })
  end
  
  -- Add separator
  if #model_items > 0 then
    table.insert(model_items, { text = "----" })
  end
  
  -- Add "Use Default Model" option
  local Defaults = require("api_handlers/defaults")
  local default_model = Defaults.getDefaultModel(provider_id)
  table.insert(model_items, {
    text = T(_("Use Default (%1)"), default_model),
    checked_func = function()
      return self.settings:readSetting("provider") == provider_id and
             self.settings:readSetting("model") == nil
    end,
    callback = function(touchmenu_instance)
      self.settings:saveSetting("provider", provider_id)
      self.settings:saveSetting("model", nil)
      self.settings:flush()
      self:updateConfigFromSettings()

      UIManager:show(InfoMessage:new{
        text = T(_("Provider set to %1 with default: %2"), provider_name, default_model),
        timeout = 2,
      })

      -- Go back to parent menu to see updated provider checkmark
      if touchmenu_instance then
        touchmenu_instance:onBack()
      end
    end,
  })
  
  -- Add "Enter Custom Model" option
  table.insert(model_items, {
    text = _("Enter Custom Model..."),
    callback = function()
      self:showCustomModelDialogForProvider(provider_id, provider_name)
    end,
  })
  
  return model_items
end

function AskGPT:showCustomModelDialogForProvider(provider_id, provider_name)
  local InputDialog = require("ui/widget/inputdialog")
  
  local custom_model_dialog
  custom_model_dialog = InputDialog:new{
    title = T(_("Custom Model for %1"), provider_name),
    input = "",
    input_hint = _("Enter custom model name"),
    buttons = {
      {
        {
          text = _("Close"),
          id = "close",
          callback = function()
            UIManager:close(custom_model_dialog)
          end,
        },
        {
          text = _("OK"),
          is_enter_default = true,
          callback = function()
            local model = custom_model_dialog:getInputText()
            if model and model ~= "" then
              self.settings:saveSetting("provider", provider_id)
              self.settings:saveSetting("model", model)
              self.settings:flush()
              self:updateConfigFromSettings()
              UIManager:close(custom_model_dialog)
              UIManager:show(InfoMessage:new{
                text = T(_("Provider set to %1, Model set to %2"), provider_name, model),
              })
            end
          end,
        },
      },
    },
  }
  UIManager:show(custom_model_dialog)
  custom_model_dialog:onShowKeyboard()
end

function AskGPT:getProviderConfigMenuItems()
  -- TODO: Implement provider-specific configuration options
  return {
    {
      text = _("Provider configuration coming soon..."),
      callback = function()
        UIManager:show(InfoMessage:new{
          text = _("Provider-specific configuration will be available in a future update."),
        })
      end,
    },
  }
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

function AskGPT:importPrompts()
  UIManager:show(InfoMessage:new{
    text = _("Import prompts feature coming soon..."),
  })
end

function AskGPT:exportPrompts()
  UIManager:show(InfoMessage:new{
    text = _("Export prompts feature coming soon..."),
  })
end

function AskGPT:restoreDefaultPrompts()
  -- Clear custom prompts and disabled prompts
  self.settings:saveSetting("custom_prompts", {})
  self.settings:saveSetting("disabled_prompts", {})
  self.settings:flush()
  
  UIManager:show(InfoMessage:new{
    text = _("Default prompts restored"),
  })
end

function AskGPT:saveSettingsProfile()
  UIManager:show(InfoMessage:new{
    text = _("Settings profiles feature coming soon..."),
  })
end

function AskGPT:loadSettingsProfile()
  UIManager:show(InfoMessage:new{
    text = _("Settings profiles feature coming soon..."),
  })
end

function AskGPT:deleteSettingsProfile()
  UIManager:show(InfoMessage:new{
    text = _("Settings profiles feature coming soon..."),
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

function AskGPT:importSettings()
  UIManager:show(InfoMessage:new{
    text = _("Import settings feature coming soon..."),
  })
end

function AskGPT:exportSettings()
  UIManager:show(InfoMessage:new{
    text = _("Export settings feature coming soon..."),
  })
end

function AskGPT:editConfigurationFile()
  UIManager:show(InfoMessage:new{
    text = _("To edit advanced settings, please modify configuration.lua in the plugin directory."),
  })
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

-- These events don't actually exist in KOReader, but we keep them for future compatibility
function AskGPT:onFileManagerHistoryReady(filemanager_history)
  logger.info("KOAssistant: onFileManagerHistoryReady event received (deprecated)")
end

function AskGPT:onFileManagerCollectionReady(filemanager_collection)
  logger.info("KOAssistant: onFileManagerCollectionReady event received (deprecated)")
end

-- Support for FileSearcher (search results) - this event also doesn't exist
function AskGPT:onShowFileSearch()
  logger.info("KOAssistant: onShowFileSearch event received (deprecated)")
end


-- Legacy event handlers for compatibility
function AskGPT:onFileManagerShow(filemanager)
  logger.info("KOAssistant: onFileManagerShow event received")
  -- Don't register buttons immediately - let delayed registration handle it
  -- But do register ourselves for multi-select support
  if filemanager then
    filemanager.koassistant = self
    logger.info("KOAssistant: Registered with FileManager for multi-select support")
  end
end

-- Try to catch when file dialogs are about to be shown
function AskGPT:onSetDimensions(dimen)
  -- This event is fired when various UI elements are being set up
  -- Don't register immediately - let delayed registration handle it
  logger.info("KOAssistant: onSetDimensions event received")
end

function AskGPT:onFileManagerInstance(filemanager)
  logger.info("KOAssistant: onFileManagerInstance event received")
  -- Don't register immediately - let delayed registration handle it
end

-- Additional event handlers that might help catch FileManager initialization
function AskGPT:onFileManagerSetDimensions()
  logger.info("KOAssistant: onFileManagerSetDimensions event received")
  -- Don't register immediately - let delayed registration handle it
end

function AskGPT:onPathChanged()
  -- This event fires when FileManager changes directory
  -- Don't register immediately - let delayed registration handle it
  logger.info("KOAssistant: onPathChanged event received")
end

-- Hook into FileSearcher initialization
function AskGPT:onShowFileSearch(searcher)
  logger.info("KOAssistant: onShowFileSearch event received")
  -- Don't register immediately - let delayed registration handle it
end

-- Hook into Collections/History views
function AskGPT:onShowHistoryMenu()
  logger.info("KOAssistant: onShowHistoryMenu event received")
  -- Don't register immediately - let delayed registration handle it
end

function AskGPT:onShowCollectionMenu()
  logger.info("KOAssistant: onShowCollectionMenu event received")
  -- Don't register immediately - let delayed registration handle it
end

function AskGPT:migratePromptsV2()
  logger.info("KOAssistant: Performing one-time prompt migration to v2 format")
  
  -- Check if we have any old configuration that needs migration
  local old_config_path = script_path() .. "configuration.lua"
  local ok, old_config = pcall(dofile, old_config_path)
  
  local migrated = false
  local custom_prompts = self.settings:readSetting("custom_prompts") or {}
  
  -- First check for old format prompts (features.prompts)
  if ok and old_config and old_config.features and old_config.features.prompts then
    -- We have old format prompts that need migration
    logger.info("KOAssistant: Found old format prompts, migrating to custom_prompts")
    
    -- Migrate each old prompt to custom prompts
    for key, prompt in pairs(old_config.features.prompts) do
      if type(prompt) == "table" and prompt.text then
        -- Create a new custom prompt entry
        local migrated_prompt = {
          text = prompt.text,
          context = "highlight", -- Old prompts were for highlights
          system_prompt = prompt.system_prompt,
          user_prompt = prompt.user_prompt,
          provider = prompt.provider,
          model = prompt.model,
          include_book_context = prompt.include_book_context
        }
        
        -- Fix user_prompt to use template variable if needed
        if migrated_prompt.user_prompt and not migrated_prompt.user_prompt:find("{highlighted_text}") then
          migrated_prompt.user_prompt = migrated_prompt.user_prompt .. "{highlighted_text}"
        end
        
        -- Check if this prompt already exists (by text)
        local exists = false
        for _, existing in ipairs(custom_prompts) do
          if existing.text == migrated_prompt.text then
            exists = true
            break
          end
        end
        
        if not exists then
          table.insert(custom_prompts, migrated_prompt)
          logger.info("KOAssistant: Migrated prompt: " .. migrated_prompt.text)
          migrated = true
        end
      end
    end
  end
  
  -- Also check for custom_prompts in configuration.lua (since we're moving them to a separate file)
  if ok and old_config and old_config.custom_prompts then
    logger.info("KOAssistant: Found custom_prompts in configuration.lua, migrating to UI settings")
    
    for _, prompt in ipairs(old_config.custom_prompts) do
      if type(prompt) == "table" and prompt.text then
        -- Check if this prompt already exists (by text)
        local exists = false
        for _, existing in ipairs(custom_prompts) do
          if existing.text == prompt.text then
            exists = true
            break
          end
        end
        
        if not exists then
          table.insert(custom_prompts, prompt)
          logger.info("KOAssistant: Migrated custom prompt: " .. prompt.text)
          migrated = true
        end
      end
    end
  end
  
  -- Save migrated prompts
  if migrated and #custom_prompts > 0 then
    self.settings:saveSetting("custom_prompts", custom_prompts)
    self.settings:flush()
    logger.info("KOAssistant: Migration complete, saved " .. #custom_prompts .. " custom prompts")
  else
    logger.info("KOAssistant: No prompts found to migrate")
  end
end

return AskGPT