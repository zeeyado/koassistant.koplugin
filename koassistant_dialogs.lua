local Device = require("device")
local InputDialog = require("ui/widget/inputdialog")
local ButtonDialog = require("ui/widget/buttondialog")
local ChatGPTViewer = require("koassistant_chatgptviewer")
local UIManager = require("ui/uimanager")
local InfoMessage = require("ui/widget/infomessage")
local Screen = Device.screen
local _ = require("koassistant_gettext")
local T = require("ffi/util").template

local GptQuery = require("koassistant_gpt_query")
local queryChatGPT = GptQuery.query
local isStreamingInProgress = GptQuery.isStreamingInProgress
local ConfigHelper = require("koassistant_config_helper")
local MessageHistory = require("koassistant_message_history")
local ChatHistoryManager = require("koassistant_chat_history_manager")
local MessageBuilder = require("message_builder")
local ModelConstraints = require("model_constraints")
local logger = require("logger")

-- New request format modules (Phase 3)
local ActionService = nil
local function getActionService(settings)
    if not ActionService then
        local ok, AS = pcall(require, "action_service")
        if ok then
            ActionService = AS:new(settings)
            ActionService:initialize()
        end
    end
    return ActionService
end

local CONFIGURATION = nil
local input_dialog

-- Try to load configuration from the same directory as this script
local function script_path()
   local str = debug.getinfo(2, "S").source:sub(2)
   return str:match("(.*/)")
end

local plugin_dir = script_path()
local config_path = plugin_dir .. "configuration.lua"

local success, result = pcall(dofile, config_path)
if success then
    CONFIGURATION = result
else
    print("configuration.lua not found at " .. config_path .. ", skipping...")
end

-- Add a global variable to track active chat viewers
if not _G.ActiveChatViewer then
    _G.ActiveChatViewer = nil
end

-- Global reference to current loading dialog for closing
local _active_loading_dialog = nil
local _loading_animation_task = nil

-- Create bouncing dot animation for loading state
local function createLoadingAnimation()
    local frames = { ".", "..", "...", "..", "." }
    local currentIndex = 1
    return {
        getNextFrame = function()
            local frame = frames[currentIndex]
            currentIndex = currentIndex + 1
            if currentIndex > #frames then
                currentIndex = 1
            end
            return frame
        end,
    }
end

-- Show enhanced loading dialog with provider/model info and animation
-- @param config: Optional configuration for displaying provider/model info
local function showLoadingDialog(config)
    -- Close any existing loading dialog
    if _active_loading_dialog then
        UIManager:close(_active_loading_dialog)
        _active_loading_dialog = nil
    end
    if _loading_animation_task then
        UIManager:unschedule(_loading_animation_task)
        _loading_animation_task = nil
    end

    -- Build status text
    local status_lines = {}
    if config then
        local provider = config.features and config.features.provider or "AI"
        local model = ConfigHelper:getModelInfo(config) or "default"
        table.insert(status_lines, string.format("%s: %s", provider:gsub("^%l", string.upper), model))

        -- Check for reasoning/thinking enabled
        local reasoning_enabled = false
        if config.features then
            if config.features.anthropic_reasoning or config.features.openai_reasoning or config.features.gemini_reasoning then
                reasoning_enabled = true
            end
        end
        if reasoning_enabled then
            table.insert(status_lines, _("Reasoning enabled"))
        end
    end

    local base_text = #status_lines > 0 and table.concat(status_lines, "\n") .. "\n\n" or ""
    local animation = createLoadingAnimation()

    -- Create initial loading dialog
    local function createLoadingMessage()
        return InfoMessage:new{
            text = base_text .. _("Loading") .. animation:getNextFrame(),
            -- No timeout - will be closed when response arrives
        }
    end

    _active_loading_dialog = createLoadingMessage()
    UIManager:show(_active_loading_dialog)

    -- Animate the loading dots by recreating the dialog
    local function updateAnimation()
        if _active_loading_dialog then
            -- Close current and show updated
            UIManager:close(_active_loading_dialog)
            _active_loading_dialog = createLoadingMessage()
            UIManager:show(_active_loading_dialog)
            _loading_animation_task = UIManager:scheduleIn(0.4, updateAnimation)
        end
    end
    _loading_animation_task = UIManager:scheduleIn(0.4, updateAnimation)
end

-- Close the loading dialog (called when response is ready)
local function closeLoadingDialog()
    if _loading_animation_task then
        UIManager:unschedule(_loading_animation_task)
        _loading_animation_task = nil
    end
    if _active_loading_dialog then
        UIManager:close(_active_loading_dialog)
        _active_loading_dialog = nil
    end
end

-- Helper function to determine prompt context
local function getPromptContext(config)
    if config and config.features then
        if config.features.is_multi_book_context then
            return "multi_book"
        elseif config.features.is_book_context then
            return "book"
        elseif config.features.is_general_context then
            return "general"
        end
    end
    return "highlight"  -- default
end

-- Helper to persist domain selection to settings
-- This ensures domain selection survives restarts
local function persistDomainSelection(plugin, domain_id)
    if not plugin or not plugin.settings then return end
    local features = plugin.settings:readSetting("features") or {}
    features.selected_domain = domain_id
    plugin.settings:saveSetting("features", features)
    plugin.settings:flush()
end

-- Extract surrounding context for dictionary lookups
-- Uses KOReader's highlight API to get text before/after selection
-- @param ui: KOReader UI instance with highlight module
-- @param highlighted_text: The selected text
-- @param mode: "sentence" (default), "paragraph", or "characters"
-- @param char_count: Number of characters for "characters" mode (default 100)
-- @return string: Formatted context or empty string if unavailable
--
-- Hard cap: 2000 chars maximum to prevent use as book text extraction bypass.
-- This is context for disambiguation, not document extraction.
local SURROUNDING_CONTEXT_MAX_CHARS = 2000

local function extractSurroundingContext(ui, highlighted_text, mode, char_count)
    mode = mode or "sentence"

    -- "none" mode: don't extract any context, just return empty string
    if mode == "none" then
        return ""
    end

    char_count = char_count or 100
    -- Enforce hard cap: char_count per side, so halve the max for characters mode
    local max_per_side = math.floor(SURROUNDING_CONTEXT_MAX_CHARS / 2)
    if char_count > max_per_side then
        char_count = max_per_side
    end

    local prev_context, next_context = nil, nil

    -- Try to get context from KOReader's highlight module
    -- Note: This works for text that was selected (hold-select), but NOT for
    -- single word taps (dictionary popup). For word taps, no selection exists.
    if ui and ui.highlight and ui.highlight.getSelectedWordContext then
        -- Get plenty of words to cover our needs (50 words should be enough)
        prev_context, next_context = ui.highlight:getSelectedWordContext(50)
    end

    if not prev_context and not next_context then
        return ""  -- No context available
    end

    prev_context = prev_context or ""
    next_context = next_context or ""

    -- Mark the highlighted word with >>> <<< markers
    local word_marker = ">>>" .. (highlighted_text or "") .. "<<<"

    if mode == "characters" then
        -- Return fixed character count before/after
        local before = prev_context:sub(-char_count)
        local after = next_context:sub(1, char_count)
        -- Add ellipsis if text was truncated
        if #prev_context > char_count then
            before = "..." .. before
        end
        if #next_context > char_count then
            after = after .. "..."
        end
        return before .. " " .. word_marker .. " " .. after

    elseif mode == "paragraph" then
        -- Return full context with word marked, but enforce hard cap
        local before = prev_context
        local after = next_context
        -- Truncate each side to half the max
        if #before > max_per_side then
            before = before:sub(-max_per_side)
        end
        if #after > max_per_side then
            after = after:sub(1, max_per_side)
        end
        -- Add ellipsis to indicate this is an excerpt
        if #before > 0 then
            before = "..." .. before
        end
        if #after > 0 then
            after = after .. "..."
        end
        return before .. " " .. word_marker .. " " .. after

    else  -- "sentence" mode (default)
        -- Try to find sentence boundaries
        -- Look for sentence-ending punctuation followed by space or end of string
        local function findSentenceStart(text)
            -- Search backwards for sentence end (.!?) followed by space
            local last_end = text:match(".*[%.!%?]%s+()") or 1
            return text:sub(last_end)
        end

        local function findSentenceEnd(text)
            -- Search forwards for sentence end (.!?)
            local end_pos = text:find("[%.!%?]%s") or text:find("[%.!%?]$")
            if end_pos then
                return text:sub(1, end_pos)
            end
            return text
        end

        local sentence_before = findSentenceStart(prev_context)
        local sentence_after = findSentenceEnd(next_context)

        -- If sentence parsing results in very little text, fall back to characters mode
        local result = sentence_before .. " " .. word_marker .. " " .. sentence_after
        if #result < 30 then  -- Adjusted threshold to account for marker
            -- Fall back to characters mode
            return extractSurroundingContext(ui, highlighted_text, "characters", char_count)
        end

        -- Add leading ellipsis if we trimmed the start
        if #sentence_before < #prev_context then
            result = "..." .. result
        end
        -- Add trailing ellipsis if we trimmed the end
        if #sentence_after < #next_context then
            result = result .. "..."
        end

        -- Enforce hard cap on sentence mode result
        if #result > SURROUNDING_CONTEXT_MAX_CHARS then
            result = result:sub(1, SURROUNDING_CONTEXT_MAX_CHARS) .. "..."
        end

        return result
    end
end

-- Build unified request config for ALL providers (v0.5.2+)
--
-- All providers receive the same config structure:
--   config.system = { text, enable_caching, components }
--   config.api_params = { temperature, max_tokens, thinking }
--
-- Each handler then adapts to its native API format
--
-- Note: Reasoning indicator only shows when actual reasoning content is returned
-- in the API response. For streaming mode, reasoning content isn't captured,
-- so indicator won't show. This is intentional - we only indicate when
-- reasoning was actually USED, not just when it was requested.

-- @param config: Configuration to modify (modified in-place)
-- @param domain_context: Optional domain context string
-- @param action: Optional action definition with behavior/api_params
-- @param plugin: Plugin instance
-- @return boolean: true if config was successfully built
local function buildUnifiedRequestConfig(config, domain_context, action, plugin)
    if not config then return false end

    local features = config.features or {}
    local SystemPrompts = require("prompts.system_prompts")

    -- Build unified system prompt (works for all providers)
    local system_config = SystemPrompts.buildUnifiedSystem({
        -- Behavior resolution (priority: action override > action variant > global)
        behavior_variant = action and action.behavior_variant,
        behavior_override = action and action.behavior_override,
        global_variant = features.selected_behavior or "standard",
        custom_ai_behavior = features.custom_ai_behavior,  -- Legacy support (for migrated users)
        custom_behaviors = features.custom_behaviors,       -- NEW: array of UI-created behaviors
        -- Domain context
        domain_context = domain_context,
        -- Caching (only effective for Anthropic)
        enable_caching = (config.provider or config.default_provider) == "anthropic",
        -- Language settings (interaction_languages is new array format, user_languages is old string format)
        interaction_languages = features.interaction_languages,
        user_languages = features.user_languages or "",
        primary_language = features.primary_language,
        skip_language_instruction = action and action.skip_language_instruction,
    })

    config.system = system_config

    -- Build api_params (works for all providers, handlers use what they support)
    config.api_params = {}

    -- Start with action-specific API params if available
    if action and action.api_params then
        for k, v in pairs(action.api_params) do
            config.api_params[k] = v
        end
    end

    -- Apply per-action temperature override, or fall back to global
    if action and action.temperature then
        config.api_params.temperature = action.temperature
    elseif not config.api_params.temperature and features.default_temperature then
        config.api_params.temperature = features.default_temperature
    end

    -- Apply max_tokens from defaults if not set
    if not config.api_params.max_tokens then
        config.api_params.max_tokens = 16384
    end

    -- Reasoning/Thinking support (per-provider toggles)
    -- Priority: action.reasoning_config > action.reasoning > per-provider setting
    local provider = config.provider or config.default_provider or "anthropic"

    -- Global defaults from settings (fall back to centralized defaults)
    local rd = ModelConstraints.reasoning_defaults
    local reasoning_budget = features.reasoning_budget or rd.anthropic.budget
    local reasoning_effort = features.reasoning_effort or rd.openai.effort
    local reasoning_depth = features.reasoning_depth or rd.gemini.level

    -- Per-provider reasoning toggles (global settings)
    local anthropic_reasoning = features.anthropic_reasoning
    local openai_reasoning = features.openai_reasoning
    local gemini_reasoning = features.gemini_reasoning

    -- Check for action overrides
    -- NEW format: action.reasoning_config = { anthropic: {...}, openai: {...}, gemini: {...} } or "off"
    -- LEGACY format: action.reasoning = "on"/"off", action.thinking_budget, etc.
    local action_anthropic_override = nil  -- nil = use global, true = on, false = off
    local action_openai_override = nil
    local action_gemini_override = nil

    if action then
        -- NEW format: per-provider reasoning_config
        if action.reasoning_config then
            if action.reasoning_config == "off" then
                -- Force off for all providers
                action_anthropic_override = false
                action_openai_override = false
                action_gemini_override = false
            elseif type(action.reasoning_config) == "table" then
                -- Per-provider configuration
                local rc = action.reasoning_config

                -- Anthropic config
                if rc.anthropic then
                    if rc.anthropic == "off" then
                        action_anthropic_override = false
                    elseif rc.anthropic.budget then
                        action_anthropic_override = true
                        reasoning_budget = rc.anthropic.budget
                    end
                end

                -- OpenAI config
                if rc.openai then
                    if rc.openai == "off" then
                        action_openai_override = false
                    elseif rc.openai.effort then
                        action_openai_override = true
                        reasoning_effort = rc.openai.effort
                    end
                end

                -- Gemini config
                if rc.gemini then
                    if rc.gemini == "off" then
                        action_gemini_override = false
                    elseif rc.gemini.level then
                        action_gemini_override = true
                        reasoning_depth = rc.gemini.level
                    end
                end
            end
        -- LEGACY format: action.reasoning = "on"/"off" or action.extended_thinking
        elseif action.reasoning == "off" or action.extended_thinking == "off" then
            -- Legacy: force off for all providers
            action_anthropic_override = false
            action_openai_override = false
            action_gemini_override = false
        elseif action.reasoning == "on" or action.extended_thinking == "on" then
            -- Legacy: force on with per-field overrides
            action_anthropic_override = true
            action_openai_override = true
            action_gemini_override = true
            if action.thinking_budget then reasoning_budget = action.thinking_budget end
            if action.reasoning_effort then reasoning_effort = action.reasoning_effort end
            if action.reasoning_depth then reasoning_depth = action.reasoning_depth end
        end
    end

    -- Apply reasoning parameters based on provider
    if provider == "anthropic" then
        local enabled = action_anthropic_override ~= nil and action_anthropic_override or anthropic_reasoning
        if enabled then
            config.api_params.thinking = {
                type = "enabled",
                budget_tokens = math.max(reasoning_budget, 1024),
            }
        end
    elseif provider == "openai" then
        local enabled = action_openai_override ~= nil and action_openai_override or openai_reasoning
        if enabled then
            config.api_params.reasoning = {
                effort = reasoning_effort,
            }
        end
    elseif provider == "gemini" then
        local enabled = action_gemini_override ~= nil and action_gemini_override or gemini_reasoning
        if enabled then
            config.api_params.thinking_level = reasoning_depth:upper()
        end
    end
    -- DeepSeek: no parameter needed, reasoner model always reasons

    -- Note: Legacy enable_extended_thinking setting removed - use per-provider toggles instead
    -- (anthropic_reasoning, openai_reasoning, gemini_reasoning in AI Response Settings)

    -- Web search support (per-action override)
    -- Global setting is in features.enable_web_search, per-action is action.enable_web_search
    -- nil = follow global, true = force on, false = force off
    if action and action.enable_web_search ~= nil then
        config.enable_web_search = action.enable_web_search
    end

    return true
end

local function createTempConfig(prompt, base_config)
    -- Use the passed base_config if available, otherwise fall back to CONFIGURATION
    local source_config = base_config or CONFIGURATION or {}
    local temp_config = {}
    
    for k, v in pairs(source_config) do
        if type(v) ~= "table" then
            temp_config[k] = v
        else
            temp_config[k] = {}
            for k2, v2 in pairs(v) do
                temp_config[k][k2] = v2
            end
        end
    end
    
    -- Only override if provider/model are specified in the prompt
    if prompt.provider then 
        temp_config.provider = prompt.provider
        if prompt.model then
            temp_config.provider_settings = temp_config.provider_settings or {}
            temp_config.provider_settings[temp_config.provider] = temp_config.provider_settings[temp_config.provider] or {}
            temp_config.provider_settings[temp_config.provider].model = prompt.model
        end
    end
    
    return temp_config
end

local function getAllPrompts(configuration, plugin)
    local prompts = {}
    local prompt_keys = {}  -- Array to store keys in order

    -- Use the passed configuration or the global one
    local config = configuration or CONFIGURATION

    -- Determine context
    local context = config and getPromptContext(config) or "highlight"

    -- Check if a book is currently open (for filtering requires_open_book actions)
    local has_open_book = plugin and plugin.ui and plugin.ui.document ~= nil

    -- Debug logging
    local logger = require("logger")
    logger.info("getAllPrompts: context = " .. context .. ", has_open_book = " .. tostring(has_open_book))

    -- Use ActionService if available, fallback to PromptService
    local service = plugin and (plugin.action_service or plugin.prompt_service)
    if service then
        local service_prompts
        -- For general context, use the filtered general menu list
        -- (users can add/remove actions via Action Manager)
        if context == "general" and service.getGeneralMenuActionObjects then
            service_prompts = service:getGeneralMenuActionObjects()
            logger.info("getAllPrompts: Got " .. #service_prompts .. " prompts from general menu list")
        else
            service_prompts = service:getAllPrompts(context, false, has_open_book)
            logger.info("getAllPrompts: Got " .. #service_prompts .. " prompts from " ..
                        (plugin.action_service and "ActionService" or "PromptService"))
        end

        -- Convert from array to keyed table for compatibility
        for _, prompt in ipairs(service_prompts) do
            local key = prompt.id or ("prompt_" .. #prompt_keys + 1)
            prompts[key] = prompt
            table.insert(prompt_keys, key)
        end
    else
        logger.warn("getAllPrompts: No prompt service available, no prompts returned")
    end

    return prompts, prompt_keys
end

local function createSaveDialog(document_path, history, chat_history_manager, is_general_context, book_metadata, launch_context, highlighted_text, ui)
    -- Guard against missing document path - allow special case for general context
    if not document_path and not is_general_context then
        UIManager:show(InfoMessage:new{
            text = _("Cannot save: no document context"),
            timeout = 2,
        })
        return
    end
    
    -- Use special path for general context chats
    if is_general_context and not document_path then
        document_path = "__GENERAL_CHATS__"
    end
    
    -- Get a suggested title from the conversation
    local suggested_title = history:getSuggestedTitle()
    
    -- Create the dialog with proper variable handling
    local save_dialog
    save_dialog = InputDialog:new{
        title = _("Save Chat"),
        input = suggested_title,
        buttons = {
            {
                {
                    text = _("Close"),
                    id = "close",
                    callback = function()
                        -- Close the dialog and do nothing else
                        UIManager:close(save_dialog)
                    end,
                },
                {
                    text = _("Save"),
                    callback = function()
                        -- First get the title
                        local chat_title = save_dialog:getInputText()
                        
                        -- Then close the dialog
                        UIManager:close(save_dialog)
                        
                        -- Now handle the save operation with error protection
                        local success, result = pcall(function()
                            -- Check if this chat already has an ID (continuation of existing chat)
                            local metadata = {}
                            if history.chat_id then
                                metadata.id = history.chat_id
                            end

                            -- Add book metadata if available
                            if book_metadata then
                                metadata.book_title = book_metadata.title
                                metadata.book_author = book_metadata.author
                                logger.info("KOAssistant: Saving chat with metadata - title: " .. (book_metadata.title or "nil") .. ", author: " .. (book_metadata.author or "nil"))
                            else
                                logger.info("KOAssistant: No book metadata available for save")
                            end

                            -- Add launch context if available (for general chats launched from a book)
                            if launch_context then
                                metadata.launch_context = launch_context
                                logger.info("KOAssistant: Saving chat with launch context - from: " .. (launch_context.title or "nil"))
                            end

                            -- Store highlighted text for display toggle in continued chats
                            if highlighted_text and highlighted_text ~= "" then
                                metadata.original_highlighted_text = highlighted_text
                            end

                            -- Check storage version and route to appropriate method
                            if chat_history_manager:useDocSettingsStorage() then
                                -- v2: DocSettings-based storage
                                -- Build complete chat_data structure (matching old saveChat format)
                                local chat_id = metadata.id or chat_history_manager:generateChatId()
                                local chat_data = {
                                    id = chat_id,
                                    title = chat_title or "Conversation",
                                    document_path = document_path,
                                    timestamp = os.time(),
                                    messages = history:getMessages(),
                                    model = history:getModel(),
                                    metadata = metadata,
                                    book_title = metadata.book_title,
                                    book_author = metadata.book_author,
                                    prompt_action = history.prompt_action,
                                    launch_context = metadata.launch_context,
                                    domain = metadata.domain,
                                    tags = metadata.tags or {},
                                    original_highlighted_text = metadata.original_highlighted_text,
                                }

                                if document_path == "__GENERAL_CHATS__" then
                                    return chat_history_manager:saveGeneralChat(chat_data)
                                else
                                    return chat_history_manager:saveChatToDocSettings(ui, chat_data)
                                end
                            else
                                -- v1: Legacy hash-based storage
                                return chat_history_manager:saveChat(
                                    document_path,
                                    chat_title,
                                    history,
                                    metadata
                                )
                            end
                        end)
                        
                        -- Show appropriate message
                        if success and result then
                            -- Store the chat ID in history for future saves
                            if not history.chat_id then
                                history.chat_id = result
                            end

                            -- Mark as saved and update button on active viewer
                            local active_viewer = _G.ActiveChatViewer
                            if active_viewer then
                                local features = active_viewer.configuration and active_viewer.configuration.features
                                if features then
                                    features.chat_saved = true
                                end
                                if active_viewer.button_table then
                                    local will_auto_save = features and (
                                        features.auto_save_all_chats or
                                        features.auto_save_chats ~= false
                                    )
                                    local button_text = will_auto_save and _("Autosaved") or _("Saved")
                                    local save_button = active_viewer.button_table:getButtonById("save_chat")
                                    if save_button then
                                        save_button:setText(button_text, save_button.width)
                                        save_button:disable()
                                        UIManager:setDirty(active_viewer, function()
                                            return "ui", save_button.dimen
                                        end)
                                    end
                                end
                            end

                            UIManager:show(InfoMessage:new{
                                text = _("Chat saved successfully"),
                                timeout = 2,
                            })
                        else
                            UIManager:show(InfoMessage:new{
                                text = _("Failed to save chat: ") .. tostring(result),
                                timeout = 2,
                            })
                        end
                    end,
                },
            },
        },
    }

    -- Add rotation support to save dialog
    local recreate_save_dialog  -- Forward declaration for recursive calls
    recreate_save_dialog = function(input_text)
        local new_dialog
        new_dialog = InputDialog:new{
            title = _("Save Chat"),
            input = input_text or suggested_title,
            buttons = save_dialog.buttons,
        }
        new_dialog.onScreenResize = function(self, dimen)
            local current_input = self:getInputText()
            UIManager:close(self)
            UIManager:scheduleIn(0.2, function()
                recreate_save_dialog(current_input)
            end)
            return true
        end
        new_dialog.onSetRotationMode = function(self, rotation)
            return self:onScreenResize(nil)
        end
        UIManager:show(new_dialog)
    end

    save_dialog.onScreenResize = function(self, dimen)
        local current_input = self:getInputText()
        UIManager:close(self)
        UIManager:scheduleIn(0.2, function()
            recreate_save_dialog(current_input)
        end)
        return true
    end

    save_dialog.onSetRotationMode = function(self, rotation)
        return self:onScreenResize(nil)
    end

    -- Show the dialog now that it's fully defined
    UIManager:show(save_dialog)
end

-- Helper function to create exportable text from history
local function createExportText(history, format)
    local result = {}
    local is_markdown = format == "markdown"

    if is_markdown then
        table.insert(result, "# Chat")
        table.insert(result, "**Date:** " .. os.date("%Y-%m-%d %H:%M"))
        table.insert(result, "**Model:** " .. (history:getModel() or "Unknown"))
    else
        table.insert(result, "Chat")
        table.insert(result, "Date: " .. os.date("%Y-%m-%d %H:%M"))
        table.insert(result, "Model: " .. (history:getModel() or "Unknown"))
    end
    table.insert(result, "")

    -- Format messages
    for _, msg in ipairs(history:getMessages()) do
        local role = msg.role:gsub("^%l", string.upper)
        local content = msg.content

        -- Skip context messages in export by default
        if not msg.is_context then
            if is_markdown then
                table.insert(result, "### " .. role)
                table.insert(result, content)
            else
                table.insert(result, role .. ": " .. content)
            end
            table.insert(result, "")
        end
    end

    return table.concat(result, "\n")
end

-- Track current tags dialog for proper closing
local current_tags_dialog = nil

-- Show tags management menu for a chat
local function showTagsMenu(document_path, chat_id, chat_history_manager)
    local function refreshMenu()
        -- Close current dialog first
        if current_tags_dialog then
            UIManager:close(current_tags_dialog)
            current_tags_dialog = nil
        end
        showTagsMenu(document_path, chat_id, chat_history_manager)
    end

    -- Get fresh chat data
    local chat = chat_history_manager:getChatById(document_path, chat_id)
    if not chat then
        UIManager:show(InfoMessage:new{
            text = _("Chat not found"),
            timeout = 2,
        })
        return
    end

    local current_tags = chat.tags or {}
    local all_tags = chat_history_manager:getAllTags()

    local buttons = {}

    -- Show current tags with remove option
    if #current_tags > 0 then
        table.insert(buttons, {
            {
                text = _("Current tags:"),
                enabled = false,
            },
        })

        for _idx, tag in ipairs(current_tags) do
            table.insert(buttons, {
                {
                    text = "#" .. tag .. " ✕",
                    callback = function()
                        chat_history_manager:removeTagFromChat(document_path, chat_id, tag)
                        UIManager:show(InfoMessage:new{
                            text = T(_("Removed tag: %1"), tag),
                            timeout = 1,
                        })
                        UIManager:scheduleIn(0.3, refreshMenu)
                    end,
                },
            })
        end

        table.insert(buttons, {
            {
                text = "────────────────────",
                enabled = false,
            },
        })
    end

    -- Show existing tags that aren't on this chat (for quick add)
    local available_tags = {}
    for _, tag in ipairs(all_tags) do
        local already_has = false
        for _, current in ipairs(current_tags) do
            if current == tag then
                already_has = true
                break
            end
        end
        if not already_has then
            table.insert(available_tags, tag)
        end
    end

    if #available_tags > 0 then
        table.insert(buttons, {
            {
                text = _("Add existing tag:"),
                enabled = false,
            },
        })

        -- Show up to 5 existing tags for quick add
        local shown_tags = 0
        for _idx, tag in ipairs(available_tags) do
            if shown_tags >= 5 then break end
            table.insert(buttons, {
                {
                    text = "#" .. tag,
                    callback = function()
                        chat_history_manager:addTagToChat(document_path, chat_id, tag)
                        UIManager:show(InfoMessage:new{
                            text = T(_("Added tag: %1"), tag),
                            timeout = 1,
                        })
                        UIManager:scheduleIn(0.3, refreshMenu)
                    end,
                },
            })
            shown_tags = shown_tags + 1
        end

        table.insert(buttons, {
            {
                text = "────────────────────",
                enabled = false,
            },
        })
    end

    -- Add new tag button
    table.insert(buttons, {
        {
            text = _("+ Add new tag"),
            callback = function()
                local tag_input
                tag_input = InputDialog:new{
                    title = _("New Tag"),
                    input_hint = _("Enter tag name"),
                    buttons = {
                        {
                            {
                                text = _("Cancel"),
                                id = "close",
                                callback = function()
                                    UIManager:close(tag_input)
                                    refreshMenu()
                                end,
                            },
                            {
                                text = _("Add"),
                                is_enter_default = true,
                                callback = function()
                                    local new_tag = tag_input:getInputText()
                                    UIManager:close(tag_input)
                                    if new_tag and new_tag ~= "" then
                                        -- Remove # if user typed it
                                        new_tag = new_tag:gsub("^#", "")
                                        new_tag = new_tag:match("^%s*(.-)%s*$")  -- trim
                                        if new_tag ~= "" then
                                            chat_history_manager:addTagToChat(document_path, chat_id, new_tag)
                                            UIManager:show(InfoMessage:new{
                                                text = T(_("Added tag: %1"), new_tag),
                                                timeout = 1,
                                            })
                                        end
                                    end
                                    UIManager:scheduleIn(0.3, refreshMenu)
                                end,
                            },
                        },
                    },
                }

                -- Add rotation support to tag input dialog
                local recreate_tag_dialog
                recreate_tag_dialog = function(input_text)
                    local new_tag_dialog
                    new_tag_dialog = InputDialog:new{
                        title = _("New Tag"),
                        input = input_text or "",
                        input_hint = _("Enter tag name"),
                        buttons = tag_input.buttons,
                    }
                    new_tag_dialog.onScreenResize = function(self, dimen)
                        local current = self:getInputText()
                        UIManager:close(self)
                        UIManager:scheduleIn(0.2, function()
                            recreate_tag_dialog(current)
                        end)
                        return true
                    end
                    new_tag_dialog.onSetRotationMode = function(self, rotation)
                        return self:onScreenResize(nil)
                    end
                    UIManager:show(new_tag_dialog)
                    new_tag_dialog:onShowKeyboard()
                end

                tag_input.onScreenResize = function(self, dimen)
                    local current_input = self:getInputText()
                    UIManager:close(self)
                    UIManager:scheduleIn(0.2, function()
                        recreate_tag_dialog(current_input)
                    end)
                    return true
                end

                tag_input.onSetRotationMode = function(self, rotation)
                    return self:onScreenResize(nil)
                end

                UIManager:show(tag_input)
                tag_input:onShowKeyboard()
            end,
        },
    })

    -- Done button
    table.insert(buttons, {
        {
            text = _("Done"),
            callback = function()
                if current_tags_dialog then
                    UIManager:close(current_tags_dialog)
                    current_tags_dialog = nil
                end
            end,
        },
    })

    current_tags_dialog = ButtonDialog:new{
        title = _("Manage Tags"),
        buttons = buttons,
    }
    UIManager:show(current_tags_dialog)
end

local function showResponseDialog(title, history, highlightedText, addMessage, temp_config, document_path, plugin, book_metadata, launch_context, ui_instance)
    -- For compact view (dictionary lookups), force debug OFF regardless of global setting
    -- Create a config copy for createResultText with debug disabled
    local config_for_text = temp_config or CONFIGURATION
    if config_for_text and config_for_text.features and config_for_text.features.compact_view then
        -- Don't modify the original config, just note that debug should be off
        -- The createResultText will check show_debug_in_chat in the config
        -- We'll handle this by passing a modified config
        config_for_text = {}
        for k, v in pairs(temp_config or CONFIGURATION) do
            config_for_text[k] = v
        end
        config_for_text.features = {}
        for k, v in pairs((temp_config or CONFIGURATION).features or {}) do
            config_for_text.features[k] = v
        end
        config_for_text.features.show_debug_in_chat = false
    end
    local result_text = history:createResultText(highlightedText, config_for_text)
    local model_info = history:getModel() or ConfigHelper:getModelInfo(temp_config)

    -- Initialize chat history manager
    local chat_history_manager = ChatHistoryManager:new()

    -- Close existing chat viewer if any
    if _G.ActiveChatViewer then
        UIManager:close(_G.ActiveChatViewer)
        _G.ActiveChatViewer = nil
    end

    -- Forward declare for mutual reference
    local chatgpt_viewer
    local recreate_func

    -- Recreate function for rotation handling
    -- Takes state captured by ChatGPTViewer:captureState() and recreates the viewer
    recreate_func = function(state)
        -- Close existing viewer if any
        if _G.ActiveChatViewer then
            UIManager:close(_G.ActiveChatViewer)
            _G.ActiveChatViewer = nil
        end

        -- Create new viewer with captured state but new dimensions
        local new_viewer = ChatGPTViewer:new {
            title = state.title,
            text = state.text,
            configuration = state.configuration,
            render_markdown = state.render_markdown,
            show_debug_in_chat = state.show_debug_in_chat,
            -- Set BOTH property names for compatibility
            original_history = state.original_history,
            _message_history = state.original_history,
            original_highlighted_text = state.original_highlighted_text,
            reply_draft = state.reply_draft,
            selection_data = state.selection_data,  -- Preserve for "Save to Note" feature
            -- Callbacks from captured state
            onAskQuestion = state.onAskQuestion,
            save_callback = state.save_callback,
            export_callback = state.export_callback,
            tag_callback = state.tag_callback,
            settings_callback = state.settings_callback,
            update_debug_callback = state.update_debug_callback,
            -- Pass recreate function for subsequent rotations
            _recreate_func = recreate_func,
        }
        -- Set close_callback after creation so new_viewer is defined
        new_viewer.close_callback = function()
            if _G.ActiveChatViewer == new_viewer then
                _G.ActiveChatViewer = nil
            end
        end

        -- Set global reference
        _G.ActiveChatViewer = new_viewer

        -- Show the new viewer
        UIManager:show(new_viewer)

        -- Restore scroll position
        if state.scroll_ratio and state.scroll_ratio > 0 then
            new_viewer:restoreScrollPosition(state.scroll_ratio)
        end
    end

    -- Check if compact view should be used
    local use_compact_view = temp_config and temp_config.features and temp_config.features.compact_view
    -- Check if minimal buttons should be used (for dictionary popup lookups)
    local use_minimal_buttons = temp_config and temp_config.features and temp_config.features.minimal_buttons
    -- Check if translate view should be used
    local use_translate_view = temp_config and temp_config.features and temp_config.features.translate_view
    local translate_hide_quote = temp_config and temp_config.features and temp_config.features.translate_hide_quote

    -- For translate view, use special text formatting
    local display_text = result_text
    if use_translate_view then
        display_text = history:createTranslateViewText(highlightedText, translate_hide_quote)
    end

    -- Debug info should NEVER show in compact/translate view
    -- regardless of the global setting
    local show_debug = false
    if not use_compact_view and not use_translate_view then
        show_debug = temp_config and temp_config.features and temp_config.features.show_debug_in_chat or false
    end

    -- Get selection data for "Save to Note" feature (only for highlight context)
    -- Must verify context is actually "highlight" to avoid stale data from previous operations
    local selection_data = nil
    local context = getPromptContext(temp_config)
    if context == "highlight" and temp_config and temp_config.features then
        selection_data = temp_config.features.selection_data
    end

    -- Ensure document_path is in configuration for export functionality
    -- This allows ChatGPTViewer to determine chat type (book/general/multi-book)
    if temp_config and document_path then
        temp_config.document_path = document_path
    end

    -- Cache notice is now handled in MessageHistory:createResultText() so it persists through debug toggle

    chatgpt_viewer = ChatGPTViewer:new {
        title = title .. " (" .. model_info .. ")",
        text = display_text,
        configuration = temp_config or CONFIGURATION,  -- Pass configuration for debug toggle
        show_debug_in_chat = show_debug,
        compact_view = use_compact_view,  -- Use compact height for dictionary lookups
        minimal_buttons = use_minimal_buttons,  -- Use minimal buttons for dictionary lookups
        translate_view = use_translate_view,  -- Use translate view for translations
        translate_hide_quote = translate_hide_quote,  -- Initial hide state for original text
        selection_data = selection_data,  -- For "Save to Note" feature
        -- Scroll to last question if setting explicitly enabled (default false)
        scroll_to_last_question = (temp_config and temp_config.features and temp_config.features.scroll_to_last_message == true),
        -- Set BOTH property names for compatibility:
        -- original_history: used by toggleDebugDisplay, toggleHighlightVisibility, etc.
        -- _message_history: used by expandToFullView for text regeneration
        original_history = history,
        _message_history = history,
        original_highlighted_text = highlightedText,
        _recreate_func = recreate_func, -- For rotation handling
        settings_callback = function(path, value)
            -- Update plugin settings if plugin instance is available
            if plugin and plugin.settings then
                local parts = {}
                for part in path:gmatch("[^.]+") do
                    table.insert(parts, part)
                end
                
                -- Navigate to the setting and update it
                local setting = plugin.settings
                for i = 1, #parts - 1 do
                    setting = setting:readSetting(parts[i]) or {}
                end
                
                -- Update the final value
                if setting then
                    local existing = plugin.settings:readSetting(parts[1]) or {}
                    if #parts == 2 then
                        existing[parts[2]] = value
                    end
                    plugin.settings:saveSetting(parts[1], existing)
                    plugin.settings:flush()
                    
                    -- Also update configuration object
                    plugin:updateConfigFromSettings()

                    -- Update temp_config if it exists
                    if temp_config and temp_config.features and parts[1] == "features" and parts[2] == "show_debug_in_chat" then
                        temp_config.features.show_debug_in_chat = value
                    end
                end
            end
        end,
        update_debug_callback = function(enabled)
            -- Update debug display setting in history if available
            if history and history.show_debug_in_chat ~= nil then
                history.show_debug_in_chat = enabled
            end
        end,
        onAskQuestion = function(viewer, question)
            -- Use the viewer's configuration (which may have been updated by expand)
            -- This is critical for compact→full view transition to work correctly
            local cfg = viewer.configuration or temp_config or CONFIGURATION

            -- Apply session web search override if set on the viewer
            -- This allows per-query toggling of web search from the Reply dialog
            if viewer.session_web_search_override ~= nil then
                cfg.enable_web_search = viewer.session_web_search_override
            end

            -- Show loading dialog only when streaming is OFF (streaming has its own dialog)
            if not (cfg.features and cfg.features.enable_streaming) then
                showLoadingDialog(cfg)
            end

            -- Function to update the viewer with new content
            local function updateViewer()
                -- Close loading dialog before showing response
                closeLoadingDialog()
                -- Check if our global reference is still the same
                if _G.ActiveChatViewer == viewer then
                    -- Always close the existing viewer
                    UIManager:close(viewer)
                    _G.ActiveChatViewer = nil

                    -- Use viewer's configuration for replies (respects expand view changes)
                    local viewer_cfg = viewer.configuration or temp_config or CONFIGURATION

                    -- Create a new viewer with updated content
                    local new_viewer = ChatGPTViewer:new {
                        title = title .. " (" .. model_info .. ")",
                        text = history:createResultText(highlightedText, viewer_cfg),
                        configuration = viewer_cfg,  -- Use viewer's config to maintain state after expand
                        -- Scroll to last question if setting explicitly enabled, otherwise scroll to bottom (old behavior)
                        scroll_to_last_question = (viewer_cfg and viewer_cfg.features and viewer_cfg.features.scroll_to_last_message == true),
                        scroll_to_bottom = not (viewer_cfg and viewer_cfg.features and viewer_cfg.features.scroll_to_last_message == true),
                        show_debug_in_chat = viewer.show_debug_in_chat,
                        -- Set BOTH property names for compatibility:
                        -- original_history: used by toggleDebugDisplay, toggleHighlightVisibility, etc.
                        -- _message_history: used by expandToFullView for text regeneration
                        original_history = history,
                        _message_history = history,
                        original_highlighted_text = highlightedText,
                        _recreate_func = recreate_func, -- For rotation handling
                        settings_callback = viewer.settings_callback,
                        update_debug_callback = viewer.update_debug_callback,
                        onAskQuestion = viewer.onAskQuestion,
                        save_callback = viewer.save_callback,
                        export_callback = viewer.export_callback,
                        tag_callback = viewer.tag_callback,
                        selection_data = viewer.selection_data,  -- Preserve for "Save to Note" feature
                        session_web_search_override = viewer.session_web_search_override,  -- Preserve session override
                    }
                    -- Set close_callback after creation so new_viewer is defined
                    new_viewer.close_callback = function()
                        if _G.ActiveChatViewer == new_viewer then
                            _G.ActiveChatViewer = nil
                        end
                    end

                    -- Set global reference to new viewer
                    _G.ActiveChatViewer = new_viewer

                    -- Show the new viewer
                    UIManager:show(new_viewer)
                end
            end

            -- Process the question with callback for streaming support
            -- IMPORTANT: Use viewer's cfg for the query, not the closure-captured temp_config
            -- This ensures expanded views use large_stream_dialog=true
            history:addUserMessage(question, false)
            queryChatGPT(history:getMessages(), cfg, function(success, answer, err, reasoning, web_search_used)
                if success and answer and answer ~= "" then
                    history:addAssistantMessage(answer, ConfigHelper:getModelInfo(cfg), reasoning, ConfigHelper:buildDebugInfo(cfg), web_search_used)

                    -- Determine if auto-save should apply:
                    -- auto_save_all_chats = always, OR auto_save_chats + chat already saved once
                    local should_auto_save = cfg.features and (
                        cfg.features.auto_save_all_chats or
                        (cfg.features.auto_save_chats ~= false and cfg.features.chat_saved)
                    )

                    -- Clear expanded_from_skip BEFORE recreating viewer, so new viewer
                    -- renders "Autosaved" (disabled) once auto-save will handle it
                    if cfg.features and cfg.features.expanded_from_skip and should_auto_save then
                        cfg.features.expanded_from_skip = nil
                    end

                    updateViewer()

                    -- Auto-save after each follow-up message if enabled
                    if should_auto_save then
                        local is_general_context = cfg.features.is_general_context or false
                        local suggested_title = history:getSuggestedTitle()

                        local metadata = {}
                        if history.chat_id then
                            metadata.id = history.chat_id
                        end
                        if book_metadata then
                            metadata.book_title = book_metadata.title
                            metadata.book_author = book_metadata.author
                        end
                        if launch_context then
                            metadata.launch_context = launch_context
                        end
                        if history.domain then
                            metadata.domain = history.domain
                        end
                        -- Store highlighted text for display toggle in continued chats
                        if highlightedText and highlightedText ~= "" then
                            metadata.original_highlighted_text = highlightedText
                        end
                        -- Store books_info for multi-book context
                        if cfg.features.is_multi_book_context and cfg.features.books_info then
                            metadata.books_info = cfg.features.books_info
                        end

                        -- Determine save path: check for action storage_key override
                        local storage_key = cfg.features and cfg.features.storage_key
                        local save_path
                        local should_save = true
                        local is_multi_book = cfg.features.is_multi_book_context or false

                        if storage_key == "__SKIP__" then
                            -- Don't save this chat
                            should_save = false
                            logger.info("KOAssistant: Skipping auto-save due to storage_key = __SKIP__")
                        elseif storage_key then
                            -- Use custom storage location
                            save_path = storage_key
                        else
                            -- Default: document path, general chats, or multi-book chats
                            save_path = document_path
                                or (is_general_context and "__GENERAL_CHATS__")
                                or (is_multi_book and "__MULTI_BOOK_CHATS__")
                                or nil
                        end

                        if not should_save then
                            -- Skip saving, but still consider it successful
                            logger.info("KOAssistant: Chat not saved (storage_key = __SKIP__)")
                        else
                            local save_result
                            -- Check storage version and route to appropriate method
                            if chat_history_manager:useDocSettingsStorage() then
                                -- v2: DocSettings-based storage
                                local chat_id = metadata.id or history.chat_id or chat_history_manager:generateChatId()
                                local chat_data = {
                                    id = chat_id,
                                    title = suggested_title or "Conversation",
                                    document_path = save_path,
                                    timestamp = os.time(),
                                    messages = history:getMessages(),
                                    model = history:getModel(),
                                    metadata = metadata,
                                    book_title = metadata.book_title,
                                    book_author = metadata.book_author,
                                    prompt_action = history.prompt_action,
                                    launch_context = metadata.launch_context,
                                    domain = metadata.domain,
                                    tags = metadata.tags or {},
                                    original_highlighted_text = metadata.original_highlighted_text,
                                }

                                if save_path == "__GENERAL_CHATS__" then
                                    save_result = chat_history_manager:saveGeneralChat(chat_data)
                                elseif save_path == "__MULTI_BOOK_CHATS__" then
                                    save_result = chat_history_manager:saveMultiBookChat(chat_data)
                                else
                                    save_result = chat_history_manager:saveChatToDocSettings(ui_instance, chat_data)
                                end
                            else
                                -- v1: Legacy hash-based storage
                                save_result = chat_history_manager:saveChat(
                                    save_path,
                                    suggested_title,
                                    history,
                                    metadata
                                )
                            end

                            if save_result and save_result ~= false then
                                -- Store the chat ID in history for future saves (prevents duplicates)
                                if not history.chat_id then
                                    history.chat_id = save_result
                                end
                                -- Mark chat as saved so auto_save_chats applies to future replies
                                if cfg.features then
                                    cfg.features.chat_saved = true
                                end
                                logger.info("KOAssistant: Auto-saved chat after follow-up with id: " .. tostring(save_result))
                            else
                                logger.warn("KOAssistant: Failed to auto-save chat after follow-up")
                            end
                        end
                    end
                else
                    closeLoadingDialog()
                    UIManager:show(InfoMessage:new{
                        text = _("Failed to get response: ") .. (err or "Unknown error"),
                        timeout = 2,
                    })
                end
            end, plugin and plugin.settings)

            -- For non-streaming, the callback was already called, viewer will be updated
        end,
        save_callback = function()
            -- Must check the ACTIVE viewer's config, not temp_config, because expandToFullView
            -- creates a new config with expanded_from_skip that temp_config doesn't have
            local viewer = _G.ActiveChatViewer
            local viewer_features = viewer and viewer.configuration and viewer.configuration.features
            local expanded_from_skip = viewer_features and viewer_features.expanded_from_skip

            if expanded_from_skip or history.chat_id then
                -- Save directly without dialog:
                -- - expanded-from-skip: document path is known from expand
                -- - chat already has ID: was saved before, just update it
                local suggested_title = history:getSuggestedTitle()
                local metadata = {}
                if history.chat_id then
                    metadata.id = history.chat_id
                end
                if book_metadata then
                    metadata.book_title = book_metadata.title
                    metadata.book_author = book_metadata.author
                end
                if launch_context then
                    metadata.launch_context = launch_context
                end
                if history.domain then
                    metadata.domain = history.domain
                end
                if highlightedText and highlightedText ~= "" then
                    metadata.original_highlighted_text = highlightedText
                end
                local save_path = document_path or "__GENERAL_CHATS__"
                local success, save_result = pcall(function()
                    -- Check storage version and route to appropriate method
                    if chat_history_manager:useDocSettingsStorage() then
                        -- v2: DocSettings-based storage
                        local chat_id = metadata.id or history.chat_id or chat_history_manager:generateChatId()
                        local chat_data = {
                            id = chat_id,
                            title = suggested_title or "Conversation",
                            document_path = save_path,
                            timestamp = os.time(),
                            messages = history:getMessages(),
                            model = history:getModel(),
                            metadata = metadata,
                            book_title = metadata.book_title,
                            book_author = metadata.book_author,
                            prompt_action = history.prompt_action,
                            launch_context = metadata.launch_context,
                            domain = metadata.domain,
                            tags = metadata.tags or {},
                            original_highlighted_text = metadata.original_highlighted_text,
                        }

                        if save_path == "__GENERAL_CHATS__" then
                            return chat_history_manager:saveGeneralChat(chat_data)
                        else
                            return chat_history_manager:saveChatToDocSettings(ui_instance, chat_data)
                        end
                    else
                        -- v1: Legacy hash-based storage
                        return chat_history_manager:saveChat(save_path, suggested_title, history, metadata)
                    end
                end)
                if success and save_result then
                    if not history.chat_id then
                        history.chat_id = save_result
                    end
                    -- Mark as saved so auto_save_chats applies to future replies
                    if viewer_features then
                        viewer_features.chat_saved = true
                        if expanded_from_skip then
                            viewer_features.expanded_from_skip = nil
                        end
                    end
                    -- Button text: "Autosaved" if auto-save will handle future replies, else "Saved"
                    local will_auto_save = viewer_features and (
                        viewer_features.auto_save_all_chats or
                        viewer_features.auto_save_chats ~= false
                    )
                    local button_text = will_auto_save and _("Autosaved") or _("Saved")
                    local save_button = viewer.button_table and viewer.button_table:getButtonById("save_chat")
                    if save_button then
                        save_button:setText(button_text, save_button.width)
                        save_button:disable()
                        UIManager:setDirty(viewer, function()
                            return "ui", save_button.dimen
                        end)
                    end
                else
                    UIManager:show(InfoMessage:new{
                        text = _("Failed to save chat"),
                        timeout = 2,
                    })
                end
            elseif temp_config and temp_config.features and temp_config.features.auto_save_all_chats then
                UIManager:show(InfoMessage:new{
                    text = T("Auto-save all chats is on - this can be changed in the settings"),
                    timeout = 3,
                })
            else
                -- First-time manual save with dialog (no chat_id yet)
                local is_general_context = temp_config and temp_config.features and temp_config.features.is_general_context or false
                createSaveDialog(document_path, history, chat_history_manager, is_general_context, book_metadata, launch_context, highlightedText, ui_instance)
            end
        end,
        export_callback = function()
            -- Copy chat using user's export settings
            local Device = require("device")
            local Notification = require("ui/widget/notification")
            local features = temp_config and temp_config.features or {}
            local content = features.copy_content or "full"
            local style = features.export_style or "markdown"

            -- Helper to perform the copy
            local function doCopy(selected_content)
                local Export = require("koassistant_export")
                -- Extract books_info for multi-book context
                local books_info = features.is_multi_book_context and features.books_info or nil
                local data = Export.fromHistory(history, highlightedText, book_metadata, books_info)
                local text = Export.format(data, selected_content, style)

                if text then
                    Device.input.setClipboardText(text)
                    UIManager:show(Notification:new{
                        text = _("Copied"),
                        timeout = 2,
                    })
                end
            end

            if content == "ask" then
                -- Show content picker dialog
                local content_dialog
                local options = {
                    { value = "full", label = _("Full (metadata + chat)") },
                    { value = "qa", label = _("Question + Response") },
                    { value = "response", label = _("Response only") },
                    { value = "everything", label = _("Everything (debug)") },
                }

                local buttons = {}
                for _idx, opt in ipairs(options) do
                    table.insert(buttons, {
                        {
                            text = opt.label,
                            callback = function()
                                UIManager:close(content_dialog)
                                doCopy(opt.value)
                            end,
                        },
                    })
                end
                table.insert(buttons, {
                    {
                        text = _("Cancel"),
                        callback = function()
                            UIManager:close(content_dialog)
                        end,
                    },
                })

                content_dialog = ButtonDialog:new{
                    title = _("Copy Content"),
                    buttons = buttons,
                }
                UIManager:show(content_dialog)
            else
                doCopy(content)
            end
        end,
        tag_callback = function()
            -- Show tag management dialog for this chat
            local chat_id = history.chat_id
            if not chat_id then
                UIManager:show(InfoMessage:new{
                    text = _("Save the chat first to add tags"),
                    timeout = 2,
                })
                return
            end

            -- Get effective document path
            local effective_path = document_path
            if not effective_path then
                local is_general = temp_config and temp_config.features and temp_config.features.is_general_context
                if is_general then
                    effective_path = "__GENERAL_CHATS__"
                else
                    UIManager:show(InfoMessage:new{
                        text = _("Cannot tag: no document context"),
                        timeout = 2,
                    })
                    return
                end
            end

            showTagsMenu(effective_path, chat_id, chat_history_manager)
        end,
        close_callback = function()
            if _G.ActiveChatViewer == chatgpt_viewer then
                _G.ActiveChatViewer = nil
            end
        end
    }
    
    -- Set global reference
    _G.ActiveChatViewer = chatgpt_viewer
    
    -- Show the viewer
    UIManager:show(chatgpt_viewer)
    
    -- Auto-save if enabled
    if temp_config and temp_config.features and temp_config.features.auto_save_all_chats then
        -- Schedule auto-save to run after viewer is displayed
        UIManager:scheduleIn(0.1, function()
            local is_general_context = temp_config.features.is_general_context or false
            local suggested_title = history:getSuggestedTitle()

            -- Create metadata for saving
            local metadata = {}
            if history.chat_id then
                metadata.id = history.chat_id
            end
            if book_metadata then
                metadata.book_title = book_metadata.title
                metadata.book_author = book_metadata.author
            end
            if launch_context then
                metadata.launch_context = launch_context
            end
            if history.domain then
                metadata.domain = history.domain
            end
            -- Store highlighted text for display toggle in continued chats
            if highlightedText and highlightedText ~= "" then
                metadata.original_highlighted_text = highlightedText
            end
            -- Store books_info for multi-book context
            if temp_config.features.is_multi_book_context and temp_config.features.books_info then
                metadata.books_info = temp_config.features.books_info
            end

            -- Determine save path: check for action storage_key override
            local storage_key = temp_config.features and temp_config.features.storage_key
            local save_path
            local should_save = true
            local is_multi_book = temp_config.features.is_multi_book_context or false

            if storage_key == "__SKIP__" then
                -- Don't save this chat
                should_save = false
                logger.info("KOAssistant: Skipping auto-save due to storage_key = __SKIP__")
            elseif storage_key then
                -- Use custom storage location
                save_path = storage_key
            else
                -- Default: document path, general chats, or multi-book chats
                save_path = document_path
                    or (is_general_context and "__GENERAL_CHATS__")
                    or (is_multi_book and "__MULTI_BOOK_CHATS__")
                    or nil
            end

            if should_save then
                local result
                -- Check storage version and route to appropriate method
                if chat_history_manager:useDocSettingsStorage() then
                    -- v2: DocSettings-based storage
                    local chat_id = metadata.id or history.chat_id or chat_history_manager:generateChatId()
                    local chat_data = {
                        id = chat_id,
                        title = suggested_title or "Conversation",
                        document_path = save_path,
                        timestamp = os.time(),
                        messages = history:getMessages(),
                        model = history:getModel(),
                        metadata = metadata,
                        book_title = metadata.book_title,
                        book_author = metadata.book_author,
                        prompt_action = history.prompt_action,
                        launch_context = metadata.launch_context,
                        domain = metadata.domain,
                        tags = metadata.tags or {},
                        original_highlighted_text = metadata.original_highlighted_text,
                    }

                    if save_path == "__GENERAL_CHATS__" then
                        result = chat_history_manager:saveGeneralChat(chat_data)
                    elseif save_path == "__MULTI_BOOK_CHATS__" then
                        result = chat_history_manager:saveMultiBookChat(chat_data)
                    else
                        result = chat_history_manager:saveChatToDocSettings(ui_instance, chat_data)
                    end
                else
                    -- v1: Legacy hash-based storage
                    result = chat_history_manager:saveChat(
                        save_path,
                        suggested_title,
                        history,
                        metadata
                    )
                end

                if result and result ~= false then
                    -- Store the chat ID in history for future saves (prevents duplicates)
                    if not history.chat_id then
                        history.chat_id = result
                    end
                    -- Mark as saved so auto_save_chats applies to future replies
                    temp_config.features.chat_saved = true
                    logger.info("KOAssistant: Auto-saved chat with id: " .. tostring(result) .. ", title: " .. suggested_title)
                else
                    logger.warn("KOAssistant: Failed to auto-save chat")
                end
            else
                logger.info("KOAssistant: Chat not saved (storage_key = __SKIP__)")
            end
        end)
    end
end

-- Helper function to build consolidated messages
-- Delegates to shared MessageBuilder module for consistency with test framework
-- @param prompt: The prompt definition
-- @param context: The context type (highlight, book, multi_book, general)
-- @param data: Context-specific data (highlighted_text, book_metadata, etc.)
-- @param system_prompt: Optional system prompt override
-- @param domain_context: Optional domain context text to prepend
-- @param using_new_format: If true, skip domain/system (they go in system array instead)
local function buildConsolidatedMessage(prompt, context, data, system_prompt, domain_context, using_new_format)
    return MessageBuilder.build({
        prompt = prompt,
        context = context,
        data = data,
        system_prompt = system_prompt,
        domain_context = domain_context,
        using_new_format = using_new_format,
    })
end

-- Forward declaration for mutual recursion
local handlePredefinedPrompt

--- Helper to generate summary cache then continue with original action
--- Used by actions with requires_summary_cache = true
--- @param original_action table: The action that requires the summary cache
--- @param highlightedText string: The highlighted text
--- @param ui table: The UI instance
--- @param configuration table: The configuration table
--- @param existing_history table: Existing message history
--- @param plugin table: The plugin instance
--- @param additional_input string: Additional user input
--- @param on_complete function: Callback for when action completes
--- @param book_metadata table: Book metadata
local function generateSummaryCacheAndContinue(
    original_action, highlightedText, ui, configuration,
    existing_history, plugin, additional_input, on_complete, book_metadata
)
    -- Load Actions module directly to avoid ActionService settings dependency
    local ok, Actions = pcall(require, "prompts.actions")
    local summary_action = ok and Actions and Actions.book and Actions.book.summarize_full_document

    if not summary_action then
        logger.warn("KOAssistant: summarize_full_document action not found for cache generation")
        UIManager:show(InfoMessage:new{
            text = _("Could not find summary action. Please try again."),
        })
        return
    end

    -- Show progress notification
    local Notification = require("ui/widget/notification")
    UIManager:show(Notification:new{
        text = _("Generating document summary..."),
        timeout = 2,
    })

    -- Execute summarize_full_document (which saves to _summary_cache)
    -- Uses same handlePredefinedPrompt, so it inherits cache_as_summary behavior
    handlePredefinedPrompt(
        summary_action, nil, ui, configuration,
        nil, plugin, nil,
        function(history, _config_result)
            if history then
                -- Cache is now populated, run original action
                UIManager:scheduleIn(0.3, function()
                    handlePredefinedPrompt(
                        original_action, highlightedText, ui, configuration,
                        existing_history, plugin, additional_input,
                        on_complete, book_metadata
                    )
                end)
            else
                -- Summary generation failed
                UIManager:show(InfoMessage:new{
                    text = _("Summary generation failed. Please try again."),
                })
            end
        end,
        book_metadata
    )
end

--- Handle a predefined prompt query
--- @param prompt_type_or_action string|table: The prompt type string ID or action object
--- @param highlightedText string: The highlighted text (optional)
--- @param ui table: The UI instance
--- @param configuration table: The configuration table
--- @param existing_history table: Existing message history (unused, for compatibility)
--- @param plugin table: The plugin instance
--- @param additional_input string: Additional user input (optional)
--- @param on_complete function: Optional callback for async streaming - receives (history, temp_config) or (nil, error_string)
--- @param book_metadata table: Optional book metadata {title, author} - used when ui.document is not available
--- @return history, temp_config when not streaming; nil when streaming (result comes via callback)
handlePredefinedPrompt = function(prompt_type_or_action, highlightedText, ui, configuration, existing_history, plugin, additional_input, on_complete, book_metadata)
    -- Use passed configuration or fall back to global
    local config = configuration or CONFIGURATION

    -- Support both action object and prompt_type string
    -- This allows executeDirectAction to pass special actions (like translate) directly
    -- without requiring them to be in the ActionService cache
    local prompt
    if type(prompt_type_or_action) == "table" then
        -- Action object passed directly - use it
        prompt = prompt_type_or_action
    else
        -- String ID - look it up from ActionService
        local prompts, _ = getAllPrompts(config, plugin)
        prompt = prompts[prompt_type_or_action]
        if not prompt then
            local err = "Prompt '" .. prompt_type_or_action .. "' not found"
            if on_complete then
                on_complete(nil, err)
                return nil
            end
            return nil, err
        end
    end

    -- Pre-flight: Check if action requires summary cache
    if prompt and prompt.requires_summary_cache and ui and ui.document and ui.document.file then
        local ActionCache = require("koassistant_action_cache")
        local cache_entry = ActionCache.getSummaryCache(ui.document.file)

        if not cache_entry then
            -- Cache missing - show confirmation dialog
            local ConfirmBox = require("ui/widget/confirmbox")
            UIManager:show(ConfirmBox:new{
                text = _("This action uses a reusable document summary for context.\n\nGenerate summary now?\n• First time only\n• Processes up to character limit\n• Coverage shown in cache viewer"),
                ok_text = _("Generate"),
                cancel_text = _("Cancel"),
                ok_callback = function()
                    generateSummaryCacheAndContinue(
                        prompt, highlightedText, ui, configuration,
                        existing_history, plugin, additional_input,
                        on_complete, book_metadata
                    )
                end,
            })
            return nil  -- Early return, handled via callback
        end
    end

    -- Create a temporary configuration using the passed config as base
    local temp_config = createTempConfig(prompt, config)
    if prompt.provider then
        if not temp_config.provider_settings[prompt.provider] then
            temp_config.provider_settings[prompt.provider] = {}
        end
        temp_config.provider_settings[prompt.provider].model = prompt.model
        -- Set both provider and model at top level so they take precedence
        temp_config.provider = prompt.provider
        temp_config.model = prompt.model
    end

    -- Apply translate view settings if action has translate_view flag
    if prompt.translate_view then
        temp_config.features = temp_config.features or {}
        temp_config.features.translate_view = true

        -- Apply translate-specific settings from user preferences
        local f = config.features or {}

        -- Disable auto-save by default (like dictionary)
        if f.translate_disable_auto_save ~= false then
            temp_config.features.storage_key = "__SKIP__"
        end

        -- Streaming setting (defaults to enabled)
        if f.translate_enable_streaming == false then
            temp_config.features.enable_streaming = false
        end

        -- Determine initial hide state for original text
        -- Apply user's translate_hide_highlight_mode setting (default: hide_long per schema)
        local hide_mode = f.translate_hide_highlight_mode or "hide_long"
        local is_full_page = temp_config.features.is_full_page_translate

        if hide_mode == "always_hide" then
            temp_config.features.translate_hide_quote = true
        elseif hide_mode == "hide_long" then
            local threshold = f.translate_long_highlight_threshold or 200
            local text_length = highlightedText and #highlightedText or 0
            temp_config.features.translate_hide_quote = (text_length > threshold)
        elseif hide_mode == "follow_global" then
            -- Replicate global hide logic: hide_highlighted_text OR (hide_long_highlights AND over threshold)
            local text_length = highlightedText and #highlightedText or 0
            local global_threshold = f.long_highlight_threshold or 280
            temp_config.features.translate_hide_quote = f.hide_highlighted_text or
                (f.hide_long_highlights and text_length > global_threshold)
        elseif hide_mode == "never_hide" then
            temp_config.features.translate_hide_quote = false
        end

        -- Full page translate override: checkbox is the ultimate override when checked
        -- This ONLY affects full page translations, not regular highlight translations
        if is_full_page and f.translate_hide_full_page == true then
            temp_config.features.translate_hide_quote = true
        end
    end

    -- Apply compact dictionary view settings if action has compact_view flag
    if prompt.compact_view then
        temp_config.features = temp_config.features or {}
        temp_config.features.compact_view = true
        temp_config.features.hide_highlighted_text = true  -- Hide quote by default in compact mode
        temp_config.features.large_stream_dialog = false  -- Small streaming dialog

        -- Apply dictionary-specific settings from user preferences
        local f = config.features or {}

        -- Disable auto-save by default
        if f.dictionary_disable_auto_save ~= false then
            temp_config.features.storage_key = "__SKIP__"
        end

        -- Streaming setting (defaults to enabled)
        if f.dictionary_enable_streaming == false then
            temp_config.features.enable_streaming = false
        end
    end

    -- Apply minimal buttons if action has minimal_buttons flag
    if prompt.minimal_buttons then
        temp_config.features = temp_config.features or {}
        temp_config.features.minimal_buttons = true
    end

    -- NEW ARCHITECTURE (v0.5.2+): Unified request config for all providers
    -- System prompt is built by buildUnifiedRequestConfig and passed in config.system
    -- No longer embedded in the consolidated message

    -- Create history WITHOUT system prompt (we'll include it in the consolidated message)
    -- Pass prompt text for better chat naming
    local history = MessageHistory:new(nil, prompt.text)

    -- Determine context
    local context = getPromptContext(config)

    -- Resolve effective translation language (uses SystemPrompts for consistency)
    local SystemPrompts = require("prompts.system_prompts")
    local effective_translation_language = SystemPrompts.getEffectiveTranslationLanguage({
        translation_use_primary = config.features.translation_use_primary,
        interaction_languages = config.features.interaction_languages,
        user_languages = config.features.user_languages,
        primary_language = config.features.primary_language,
        translation_language = config.features.translation_language,
    })

    -- Resolve effective dictionary language (for dictionary action)
    local effective_dictionary_language = SystemPrompts.getEffectiveDictionaryLanguage({
        dictionary_language = config.features.dictionary_language,
        translation_use_primary = config.features.translation_use_primary,
        interaction_languages = config.features.interaction_languages,
        user_languages = config.features.user_languages,
        primary_language = config.features.primary_language,
        translation_language = config.features.translation_language,
    })
    -- Store resolved languages back to temp_config for viewer's RTL detection
    -- (temp_config.features is a separate copy from config.features)
    temp_config.features.dictionary_language = effective_dictionary_language
    temp_config.features.translation_language = effective_translation_language

    -- Build data for consolidated message
    logger.info("KOAssistant: buildConsolidatedMessage - highlightedText:", highlightedText and #highlightedText or "nil/empty")
    logger.info("KOAssistant: config.features.book_metadata=", config.features and config.features.book_metadata and "present" or "nil")
    if config.features and config.features.book_metadata then
        logger.info("KOAssistant: book_metadata.title=", config.features.book_metadata.title or "nil")
    end
    local message_data = {
        highlighted_text = highlightedText,
        additional_input = additional_input,
        book_metadata = config.features.book_metadata,
        books_info = config.features.books_info,
        book_context = config.features.book_context,
        translation_language = effective_translation_language,
        dictionary_language = effective_dictionary_language,
        -- Context from dictionary hook (surrounding text)
        context = config.features.dictionary_context or "",
        dictionary_context_mode = config.features.dictionary_context_mode,
    }
    logger.info("KOAssistant: message_data.book_metadata=", message_data.book_metadata and "present" or "nil")

    -- Add book info for highlight context when:
    -- 1. include_book_context is enabled for the prompt, OR
    -- 2. The prompt uses template variables that require book info
    -- Try to get from ui.document first, then fall back to passed book_metadata
    if context == "highlight" then
        local should_include_book = prompt.include_book_context

        -- Also include if prompt uses book-related placeholders
        local prompt_text = prompt.prompt
        if not should_include_book and prompt_text then
            should_include_book = prompt_text:find("{title}") or
                                  prompt_text:find("{author}") or
                                  prompt_text:find("{author_clause}")
        end

        if should_include_book then
            -- Try ui.document first
            if ui and ui.document then
                local props = ui.document:getProps()
                message_data.book_title = props and props.title
                message_data.book_author = props and props.authors
            end
            -- Fall back to passed book_metadata if not available
            if not message_data.book_title and book_metadata then
                message_data.book_title = book_metadata.title
                message_data.book_author = book_metadata.author
            end
        end

        -- Extract surrounding context for dictionary action if not already provided
        -- Check both string ID and action object ID
        local action_id = type(prompt_type_or_action) == "table" and prompt_type_or_action.id or prompt_type_or_action
        if action_id == "dictionary" and (not message_data.context or message_data.context == "") then
            local context_mode = config.features.dictionary_context_mode or "sentence"
            local context_chars = config.features.dictionary_context_chars or 100
            message_data.context = extractSurroundingContext(ui, highlightedText, context_mode, context_chars)
        end

        -- Extract surrounding context for any action with use_surrounding_context flag
        if prompt.use_surrounding_context then
            local context_mode = prompt.context_mode or config.features.dictionary_context_mode or "sentence"
            local context_chars = prompt.context_chars or config.features.dictionary_context_chars or 100
            message_data.surrounding_context = extractSurroundingContext(ui, highlightedText, context_mode, context_chars)
        end
    end

    -- For book context, ensure book_metadata is populated
    -- This provides a fallback when config.features.book_metadata isn't set
    if context == "book" or context == "file_browser" then
        if not message_data.book_metadata and ui and ui.document then
            local props = ui.document:getProps()
            if props then
                message_data.book_metadata = {
                    title = props.title or "Unknown",
                    author = props.authors or "",
                    author_clause = (props.authors and props.authors ~= "") and (" by " .. props.authors) or "",
                }
                logger.info("KOAssistant: book_metadata populated from ui.document for book context")
            end
        end
    end

    -- Context extraction: auto-extract lightweight data when a document is open
    -- Lightweight data (progress, highlights, annotations, stats) is always available
    -- Book text extraction requires use_book_text flag (slow/expensive)
    if ui and ui.document then
        local extraction_success, ContextExtractor = pcall(require, "koassistant_context_extractor")
        if extraction_success and ContextExtractor then
            local extractor = ContextExtractor:new(ui, {
                -- Extraction limits
                enable_book_text_extraction = config.features and config.features.enable_book_text_extraction,
                max_book_text_chars = prompt and prompt.max_book_text_chars or (config.features and config.features.max_book_text_chars) or 250000,
                max_pdf_pages = config.features and config.features.max_pdf_pages or 250,
                -- Privacy settings
                provider = config.features and config.features.provider,
                trusted_providers = config.features and config.features.trusted_providers,
                enable_annotations_sharing = config.features and config.features.enable_annotations_sharing,
                enable_progress_sharing = config.features and config.features.enable_progress_sharing,
                enable_stats_sharing = config.features and config.features.enable_stats_sharing,
                enable_notebook_sharing = config.features and config.features.enable_notebook_sharing,
            })
            logger.info("KOAssistant: Extractor settings - enable_book_text_extraction=",
                       config.features and config.features.enable_book_text_extraction and "true" or "false/nil")
            if extractor:isAvailable() then
                logger.info("KOAssistant: Context extraction starting for action:", prompt and prompt.id or "unknown")
                logger.info("KOAssistant: use_book_text=", prompt and prompt.use_book_text and "true" or "false")
                local extracted = extractor:extractForAction(prompt or {})
                -- Merge extracted data into message_data
                for key, value in pairs(extracted) do
                    message_data[key] = value
                    logger.info("KOAssistant: Extracted data key=", key, "value_len=", type(value) == "string" and #value or "non-string")
                end
                logger.info("KOAssistant: Context extraction complete")

                -- Show notification if book text was truncated (centered InfoMessage)
                if extracted.book_text_truncated then
                    local coverage_start = extracted.book_text_coverage_start or 0
                    local coverage_end = extracted.book_text_coverage_end or 0
                    UIManager:show(InfoMessage:new{
                        text = T(_("Book text truncated (covers %1 %–%2 %). Increase limit in Advanced Settings."),
                                 coverage_start, coverage_end),
                        timeout = 4,
                    })
                end

                -- Show notification if full document text was truncated
                if extracted.full_document_truncated then
                    local coverage_start = extracted.full_document_coverage_start or 0
                    local coverage_end = extracted.full_document_coverage_end or 0
                    UIManager:show(InfoMessage:new{
                        text = T(_("Full document text truncated (covers %1 %–%2 %). Increase limit in Advanced Settings."),
                                 coverage_start, coverage_end),
                        timeout = 4,
                    })
                end
            end
        else
            logger.warn("KOAssistant: Failed to load context extractor:", ContextExtractor)
        end
    end
    -- Note: Notebook extraction is now handled by ContextExtractor:extractForAction()

    -- Get domain context if a domain is set (skip if action opts out)
    -- Priority: prompt.domain (locked) > config.features.selected_domain (user choice)
    local domain_context = nil
    local skip_domain = prompt and prompt.skip_domain
    local domain_id = (not skip_domain) and (prompt.domain or (config.features and config.features.selected_domain))
    if domain_id then
        local DomainLoader = require("domain_loader")
        -- Get custom domains from config for lookup
        local custom_domains = config.features and config.features.custom_domains or {}
        local domain = DomainLoader.getDomainById(domain_id, custom_domains)
        if domain then
            domain_context = domain.context
        end
    end

    -- Response caching: check for cached response and switch to update prompt if applicable
    -- Only cache when: action supports it, uses book text, and book text extraction is enabled
    local using_cache = false
    local cached_progress_display = nil
    local cache_enabled = prompt and prompt.use_response_caching
        and prompt.use_book_text
        and config.features and config.features.enable_book_text_extraction
        and ui and ui.document

    if cache_enabled then
        local ActionCache = require("koassistant_action_cache")
        local cached_entry = ActionCache.get(ui.document.file, prompt.id)

        if cached_entry and message_data.progress_decimal then
            local current_progress = tonumber(message_data.progress_decimal) or 0
            local cached_progress = cached_entry.progress_decimal or 0

            -- Use cache if we've progressed by at least 1% since last time
            if current_progress > cached_progress + 0.01 then
                using_cache = true
                cached_progress_display = math.floor(cached_progress * 100) .. "%"
                logger.info("KOAssistant: Using cached response from", cached_progress_display, "for", prompt.id)

                -- Switch to update prompt (create a shallow copy to avoid modifying original)
                local original_prompt = prompt
                prompt = {}
                for k, v in pairs(original_prompt) do
                    prompt[k] = v
                end
                prompt.prompt = original_prompt.update_prompt

                -- Add cache data for placeholder substitution
                message_data.cached_result = cached_entry.result
                message_data.cached_progress = cached_progress_display

                -- Get incremental book text (from cached to current position)
                local extraction_success, ContextExtractor = pcall(require, "koassistant_context_extractor")
                if extraction_success and ContextExtractor then
                    local extractor = ContextExtractor:new(ui, {
                        enable_book_text_extraction = config.features.enable_book_text_extraction,
                        max_book_text_chars = prompt.max_book_text_chars or config.features.max_book_text_chars or 250000,
                        max_pdf_pages = config.features.max_pdf_pages or 250,
                    })
                    local range_result = extractor:getBookTextRange(cached_progress, current_progress)
                    message_data.incremental_book_text = range_result.text
                    logger.info("KOAssistant: Extracted incremental book text:", range_result.char_count, "chars")

                    -- Show notification if incremental text was truncated (centered InfoMessage)
                    if range_result.truncated then
                        local coverage_start = range_result.coverage_start or 0
                        local coverage_end = range_result.coverage_end or 0
                        UIManager:show(InfoMessage:new{
                            text = T(_("New content truncated (covers %1 %–%2 %). Increase limit in Advanced Settings."),
                                     coverage_start, coverage_end),
                            timeout = 4,
                        })
                    end
                end
            end
        end
    end

    -- Build and add the consolidated message
    -- System prompt and domain are now in config.system (unified approach)
    local consolidated_message = buildConsolidatedMessage(prompt, context, message_data, nil, nil, true)
    history:addUserMessage(consolidated_message, true)

    -- Store domain in history for saving with chat
    if domain_id then
        history.domain = domain_id
    end

    -- Track if user provided additional input
    local has_additional_input = additional_input and additional_input ~= ""

    -- Build unified request config for ALL providers
    -- Pass the prompt/action object which contains behavior_variant/behavior_override
    local action = prompt._action or prompt  -- Use underlying action if available
    buildUnifiedRequestConfig(temp_config, domain_context, action, plugin)

    -- Capture the original action ID before any prompt modifications (for cache save)
    local original_action_id = prompt and prompt.id

    -- Get response from AI with callback for async streaming
    local function handleResponse(success, answer, err, reasoning, web_search_used)
        if success and answer and answer ~= "" then
            -- If user typed additional input, add it as a visible message before the response
            if has_additional_input then
                history:addUserMessage(additional_input, false)
            end
            history:addAssistantMessage(answer, ConfigHelper:getModelInfo(temp_config), reasoning, ConfigHelper:buildDebugInfo(temp_config), web_search_used)

            -- Save to response cache if enabled
            -- Cache when: action supports it, uses book text, extraction enabled, we have progress
            -- Skip caching if response was truncated (contains truncation notice)
            local ResponseParser = require("koassistant_api.response_parser")
            local is_truncated = answer:find(ResponseParser.TRUNCATION_NOTICE, 1, true) ~= nil

            if cache_enabled and original_action_id and message_data.progress_decimal and not is_truncated then
                local ActionCache = require("koassistant_action_cache")
                local save_success = ActionCache.set(
                    ui.document.file,
                    original_action_id,
                    answer,
                    tonumber(message_data.progress_decimal) or 0,
                    { model = ConfigHelper:getModelInfo(temp_config).model }
                )
                if save_success then
                    logger.info("KOAssistant: Saved response to cache for", original_action_id, "at", message_data.progress_decimal)
                end
            elseif is_truncated and cache_enabled then
                logger.info("KOAssistant: Skipping cache for", original_action_id, "- response was truncated")
            end

            -- Save to document caches if action has cache_as_* flags (for reuse by other actions)
            if not is_truncated and ui.document and ui.document.file then
                local ActionCache = require("koassistant_action_cache")
                local progress = tonumber(message_data.progress_decimal) or 0
                local model_info = { model = ConfigHelper:getModelInfo(temp_config).model }

                if action.cache_as_xray then
                    -- Track whether annotations were used when building this cache
                    -- Reading the cache will only require annotation permission if annotations were included
                    local used_annotations = (message_data.highlights and message_data.highlights ~= "")
                        or (message_data.annotations and message_data.annotations ~= "")
                    local xray_metadata = {
                        model = model_info.model,
                        used_annotations = used_annotations,
                    }
                    local xray_success = ActionCache.setXrayCache(ui.document.file, answer, progress, xray_metadata)
                    if xray_success then
                        logger.info("KOAssistant: Saved X-Ray to reusable cache at", progress, "used_annotations=", used_annotations)
                    end
                end

                if action.cache_as_analyze then
                    local analyze_success = ActionCache.setAnalyzeCache(ui.document.file, answer, 1.0, model_info)
                    if analyze_success then
                        logger.info("KOAssistant: Saved document analysis to reusable cache")
                    end
                end

                if action.cache_as_summary then
                    -- Include language in metadata for cache viewer awareness
                    local summary_metadata = {
                        model = model_info.model,
                        language = temp_config.features and temp_config.features.translation_language or "English",
                    }
                    local summary_success = ActionCache.setSummaryCache(ui.document.file, answer, 1.0, summary_metadata)
                    if summary_success then
                        logger.info("KOAssistant: Saved document summary to reusable cache with language:", summary_metadata.language)
                    end
                end
            end

            -- Store cache info in history for viewer to display notice
            if using_cache then
                history.used_cache = true
                history.cached_progress = cached_progress_display
                history.cache_action_id = original_action_id
            end

            -- Store book text truncation info in history for viewer to display notice
            if message_data.book_text_truncated then
                history.book_text_truncated = true
                history.book_text_coverage_start = message_data.book_text_coverage_start
                history.book_text_coverage_end = message_data.book_text_coverage_end
            end

            if on_complete then
                on_complete(history, temp_config)
            end
        else
            -- Treat empty answer as error
            if success and (not answer or answer == "") then
                err = _("No response received from AI")
            end
            if on_complete then
                on_complete(nil, err or "Unknown error")
            end
        end
    end

    local result = queryChatGPT(history:getMessages(), temp_config, handleResponse, plugin and plugin.settings)

    -- If streaming is in progress, return nil (result comes via callback)
    if isStreamingInProgress(result) then
        return nil
    end

    -- Non-streaming: handleResponse callback was already called by queryChatGPT
    -- Return history and config for backward compatibility with callers that don't use callback
    return history, temp_config
end

local function showChatGPTDialog(ui_instance, highlighted_text, config, prompt_type, plugin, book_metadata, initial_input)
    -- Use the passed configuration or fall back to the global CONFIGURATION
    local configuration = config or CONFIGURATION
    
    -- Log which provider we're using
    local logger = require("logger")
    logger.info("Using AI provider: " .. (configuration.provider or "anthropic"))
    
    -- Log configuration structure
    if configuration and configuration.features then
        logger.info("Configuration has features")
        if configuration.features.prompts then
            local count = 0
            for k, v in pairs(configuration.features.prompts) do
                count = count + 1
                logger.info("  Found configured prompt: " .. k)
            end
            logger.info("Total configured prompts: " .. count)
        else
            logger.warn("No prompts in configuration.features")
        end
    else
        logger.warn("Configuration missing or no features")
    end
    
    -- Check if this is a general context chat (no book association)
    local is_general_context = configuration and configuration.features and configuration.features.is_general_context

    -- Capture book info from document if available (for launch_context even in general chats)
    local doc_title = ui_instance and ui_instance.document and ui_instance.document:getProps().title or nil
    local doc_author = ui_instance and ui_instance.document and ui_instance.document:getProps().authors or nil
    local doc_file = ui_instance and ui_instance.document and ui_instance.document.file or nil

    -- For general context, don't use document_path - these chats are context-free
    -- But capture launch_context so we know where the chat was started from
    local document_path = nil
    local launch_context = nil
    -- Reset book_metadata to allow conditional assignment below
    book_metadata = nil

    if is_general_context then
        -- General chat: don't associate with a document, but track launch context
        if doc_title and doc_file then
            launch_context = {
                title = doc_title,
                author = doc_author,
                file = doc_file
            }
            logger.info("KOAssistant: General chat launched from book - " .. doc_title)
        else
            logger.info("KOAssistant: General chat with no launch context")
        end
    elseif doc_file then
        -- Document is open, use its metadata and path
        document_path = doc_file

        -- Extract filename as fallback for missing title metadata
        local filename_fallback = nil
        if doc_file then
            filename_fallback = doc_file:match("([^/\\]+)$")  -- Get filename
            if filename_fallback then
                filename_fallback = filename_fallback:gsub("%.[^%.]+$", "")  -- Remove extension
                filename_fallback = filename_fallback:gsub("[_-]", " ")  -- Convert separators to spaces
            end
        end

        book_metadata = {
            title = (doc_title and doc_title ~= "") and doc_title or filename_fallback or "Unknown",
            author = (doc_author and doc_author ~= "") and doc_author or ""  -- Empty, not "Unknown"
        }
        logger.info("KOAssistant: Document context - title: " .. (book_metadata.title or "nil") .. ", author: " .. (book_metadata.author or "nil"))
    elseif configuration and configuration.features and configuration.features.book_metadata then
        -- File browser context, use metadata from configuration
        book_metadata = {
            title = configuration.features.book_metadata.title,
            author = configuration.features.book_metadata.author
        }
        -- For file browser context, get the document path from configuration
        if configuration.features.book_metadata.file then
            document_path = configuration.features.book_metadata.file
        end
        logger.info("KOAssistant: File browser context - title: " .. (book_metadata.title or "nil") .. ", author: " .. (book_metadata.author or "nil"))
    else
        logger.info("KOAssistant: No metadata available in either context")
    end

    -- Track selected domain for this dialog (initialize from config if set)
    local selected_domain = configuration and configuration.features and configuration.features.selected_domain or nil

    -- Function to show domain selector
    local function showDomainSelector()
        -- Close the on-screen keyboard first to prevent z-order issues
        input_dialog:onCloseKeyboard()

        local DomainLoader = require("domain_loader")
        -- Get custom domains from settings
        local features = plugin and plugin.settings and plugin.settings:readSetting("features") or {}
        local custom_domains = features.custom_domains or {}
        -- Get all domains (folder + UI-created) sorted
        local sorted_domains = DomainLoader.getSortedDomains(custom_domains)

        local buttons = {}

        -- "None" option
        local none_prefix = (not selected_domain) and "● " or "○ "
        table.insert(buttons, {
            {
                text = none_prefix .. _("None"),
                callback = function()
                    selected_domain = nil
                    configuration.features = configuration.features or {}
                    configuration.features.selected_domain = nil
                    -- Persist to settings so it survives restarts
                    persistDomainSelection(plugin, nil)
                    -- Capture current input text before closing
                    local current_input = input_dialog:getInputText()
                    UIManager:close(_G.domain_selector_dialog)
                    -- Refresh main dialog to show updated domain selection, preserving input
                    UIManager:close(input_dialog)
                    showChatGPTDialog(ui_instance, highlighted_text, configuration, nil, plugin, book_metadata, current_input)
                end,
            },
        })

        -- Domain options with source indicators
        for _, domain in ipairs(sorted_domains) do
            local prefix = (selected_domain == domain.id) and "● " or "○ "
            -- Use display_name which includes source indicator for UI-created domains
            local display_text = prefix .. domain.display_name
            table.insert(buttons, {
                {
                    text = display_text,
                    callback = function()
                        selected_domain = domain.id
                        configuration.features = configuration.features or {}
                        configuration.features.selected_domain = domain.id
                        -- Persist to settings so it survives restarts
                        persistDomainSelection(plugin, domain.id)
                        -- Capture current input text before closing
                        local current_input = input_dialog:getInputText()
                        UIManager:close(_G.domain_selector_dialog)
                        -- Refresh main dialog to show updated domain selection, preserving input
                        UIManager:close(input_dialog)
                        showChatGPTDialog(ui_instance, highlighted_text, configuration, nil, plugin, book_metadata, current_input)
                    end,
                },
            })
        end

        -- Close button
        table.insert(buttons, {
            {
                text = _("Close"),
                id = "close",
                callback = function()
                    UIManager:close(_G.domain_selector_dialog)
                end,
            },
        })

        local ButtonDialog = require("ui/widget/buttondialog")
        _G.domain_selector_dialog = ButtonDialog:new{
            title = _("Select Domain"),
            buttons = buttons,
        }
        UIManager:show(_G.domain_selector_dialog)
    end

    -- Get domain display name for button
    local function getDomainDisplayName()
        if not selected_domain then
            return _("None")
        end
        local DomainLoader = require("domain_loader")
        -- Get custom domains from settings for lookup
        local features = plugin and plugin.settings and plugin.settings:readSetting("features") or {}
        local custom_domains = features.custom_domains or {}
        local domain = DomainLoader.getDomainById(selected_domain, custom_domains)
        if domain then
            return domain.display_name
        end
        return selected_domain
    end

    -- Collect all buttons in priority order
    local all_buttons = {
        -- 1. Close
        {
            text = _("Close"),
            id = "close",
            callback = function()
                UIManager:close(input_dialog)
                -- Clear reference so other dialogs know we're closed
                if plugin then
                    plugin.current_input_dialog = nil
                end
            end
        },
        -- 2. Domain selector
        {
            text = _("Domain: ") .. getDomainDisplayName(),
            callback = function()
                showDomainSelector()
            end
        },
        -- 3. Ask
        {
            text = _("Ask"),
            callback = function()
                UIManager:close(input_dialog)
                -- Show loading dialog only when streaming is OFF
                if not (configuration.features and configuration.features.enable_streaming) then
                    showLoadingDialog(configuration)
                end
                UIManager:scheduleIn(0.1, function()
                    -- NEW ARCHITECTURE (v0.5.2+): Unified request config for all providers
                    -- System prompt and domain are built by buildUnifiedRequestConfig

                    -- Get domain context if a domain is selected (for passing to buildUnifiedRequestConfig)
                    local domain_id = selected_domain
                    local domain_context = nil
                    if domain_id then
                        local DomainLoader = require("domain_loader")
                        -- Get custom domains from configuration for lookup
                        local custom_domains = configuration and configuration.features and configuration.features.custom_domains or {}
                        local domain = DomainLoader.getDomainById(domain_id, custom_domains)
                        if domain then
                            domain_context = domain.context
                        end
                    end

                    -- Create history WITHOUT system prompt (system is in config.system)
                    local history = MessageHistory:new(nil, "Ask")

                    -- Store domain in history for saving with chat
                    if domain_id then
                        history.domain = domain_id
                    end

                    -- Build consolidated message parts (no system/domain - they're in config.system now)
                    local parts = {}

                    -- Add appropriate context
                    if configuration.features.is_book_context then
                        -- For book context (file browser or gesture action), include book metadata
                        table.insert(parts, "[Context]")
                        if book_metadata then
                            table.insert(parts, string.format('Book: "%s"%s',
                                book_metadata.title or "Unknown",
                                (book_metadata.author and book_metadata.author ~= "") and (" by " .. book_metadata.author) or ""))
                        elseif highlighted_text then
                            -- Fallback to highlighted_text if it contains formatted book info
                            table.insert(parts, highlighted_text)
                        end
                        table.insert(parts, "")
                    elseif configuration.features.is_general_context then
                        -- For general context, no initial context needed
                        -- User will provide their question/prompt
                    elseif highlighted_text then
                        -- For highlighted text context - always include book info if available
                        table.insert(parts, "[Context]")
                        if book_metadata and book_metadata.title then
                            table.insert(parts, string.format('From "%s"%s',
                                book_metadata.title,
                                (book_metadata.author and book_metadata.author ~= "") and (" by " .. book_metadata.author) or ""))
                            table.insert(parts, "")
                        end
                        table.insert(parts, "Selected text:")
                        table.insert(parts, '"' .. highlighted_text .. '"')
                        table.insert(parts, "")
                    end
                    
                    -- Get user's typed question
                    local question = input_dialog:getInputText()
                    local has_user_question = question and question ~= ""

                    -- Add user question to context message
                    if has_user_question then
                        table.insert(parts, "[User Question]")
                        table.insert(parts, question)
                    else
                        -- Default prompt if no question provided
                        table.insert(parts, "[User Question]")
                        table.insert(parts, "I have a question for you.")
                    end

                    -- Create the consolidated message (sent to AI as context)
                    local consolidated_message = table.concat(parts, "\n")
                    history:addUserMessage(consolidated_message, true)

                    -- Build unified request config for ALL providers
                    -- No action specified, uses global behavior setting
                    buildUnifiedRequestConfig(configuration, domain_context, nil, plugin)

                    -- Callback to handle response (for both streaming and non-streaming)
                    local function onResponseReady(success, answer, err, reasoning, web_search_used)
                        if success and answer then
                            -- If user typed a question, add it as a visible message before the response
                            if has_user_question then
                                history:addUserMessage(question, false)
                            end
                            history:addAssistantMessage(answer, ConfigHelper:getModelInfo(configuration), reasoning, ConfigHelper:buildDebugInfo(configuration), web_search_used)

                            local function addMessage(message, is_context, on_complete)
                                history:addUserMessage(message, is_context)
                                local answer_result = queryChatGPT(history:getMessages(), configuration, function(msg_success, msg_answer, msg_err, msg_reasoning, msg_web_search_used)
                                    if msg_success and msg_answer then
                                        history:addAssistantMessage(msg_answer, ConfigHelper:getModelInfo(configuration), msg_reasoning, ConfigHelper:buildDebugInfo(configuration), msg_web_search_used)
                                    end
                                    if on_complete then on_complete(msg_success, msg_answer, msg_err, msg_reasoning, msg_web_search_used) end
                                end, plugin and plugin.settings)
                                if not isStreamingInProgress(answer_result) then
                                    return answer_result
                                end
                                return nil
                            end

                            closeLoadingDialog()
                            showResponseDialog(_("Chat"), history, highlighted_text, addMessage, configuration, document_path, plugin, book_metadata, launch_context, ui_instance)
                        else
                            closeLoadingDialog()
                            UIManager:show(InfoMessage:new{
                                text = _("Error: ") .. (err or "Unknown error"),
                                timeout = 3
                            })
                        end
                    end

                    -- Get initial response with callback
                    local result = queryChatGPT(history:getMessages(), configuration, onResponseReady, plugin and plugin.settings)
                    -- If not streaming, callback was already invoked
                end)
            end
        }
    }

    -- 3. Custom actions (including Translate, which is now a built-in action)
    local prompts, prompt_keys = getAllPrompts(configuration, plugin)
    logger.info("showChatGPTDialog: Got " .. #prompt_keys .. " custom prompts")
    for _idx, custom_prompt_type in ipairs(prompt_keys) do
        local prompt = prompts[custom_prompt_type]
        if prompt and prompt.text then
            logger.info("Adding button for prompt: " .. custom_prompt_type .. " with text: " .. prompt.text)
            table.insert(all_buttons, {
                text = _(prompt.text),
            prompt_type = custom_prompt_type,
            callback = function()
                local additional_input = input_dialog:getInputText()
                UIManager:close(input_dialog)
                -- Show loading dialog only when streaming is OFF
                if not (configuration.features and configuration.features.enable_streaming) then
                    showLoadingDialog(configuration)
                end
                UIManager:scheduleIn(0.1, function()
                    -- Callback for when response is ready (handles both streaming and non-streaming)
                    local function onPromptComplete(history, temp_config_or_error)
                        if history then
                            local temp_config = temp_config_or_error
                            local function addMessage(message, is_context, on_complete)
                                history:addUserMessage(message, is_context)
                                -- For follow-up messages, use callback pattern too
                                local answer_result = queryChatGPT(history:getMessages(), temp_config, function(success, answer, err, reasoning, web_search_used)
                                    if success and answer then
                                        history:addAssistantMessage(answer, ConfigHelper:getModelInfo(temp_config), reasoning, ConfigHelper:buildDebugInfo(temp_config), web_search_used)
                                    end
                                    if on_complete then on_complete(success, answer, err, reasoning, web_search_used) end
                                end, plugin and plugin.settings)
                                -- For non-streaming, return the result directly
                                if not isStreamingInProgress(answer_result) then
                                    return answer_result
                                end
                                return nil -- Streaming will update via callback
                            end
                            closeLoadingDialog()
                            showResponseDialog(_(prompt.text), history, highlighted_text, addMessage, temp_config, document_path, plugin, book_metadata, launch_context, ui_instance)
                        else
                            closeLoadingDialog()
                            local error_msg = temp_config_or_error or "Unknown error"
                            UIManager:show(InfoMessage:new{
                                text = _("Error handling prompt: ") .. custom_prompt_type .. " - " .. error_msg,
                                timeout = 2
                            })
                        end
                    end

                    -- Call with callback for streaming support
                    local history, temp_config = handlePredefinedPrompt(custom_prompt_type, highlighted_text, ui_instance, configuration, nil, plugin, additional_input, onPromptComplete, book_metadata)

                    -- For non-streaming, history is returned directly and callback was also called
                    -- The callback handles showing the dialog, so we don't need to do anything here
                end)
            end
        })
        else
            logger.warn("Skipping prompt " .. custom_prompt_type .. " - missing or invalid")
        end
    end

    -- Add View Cache button if document has cached content
    if ui_instance and ui_instance.document and ui_instance.document.file then
        local ActionCache = require("koassistant_action_cache")
        local file = ui_instance.document.file
        local has_any_cache = ActionCache.getXrayCache(file)
            or ActionCache.getSummaryCache(file)
            or ActionCache.getAnalyzeCache(file)
        if has_any_cache and plugin then
            table.insert(all_buttons, {
                text = _("View Cache"),
                callback = function()
                    UIManager:close(input_dialog)
                    plugin:viewCache()
                end
            })
        end
    end

    -- Organize buttons into rows of three
    local button_rows = {}
    local current_row = {}
    for _, button in ipairs(all_buttons) do
        table.insert(current_row, button)
        if #current_row == 3 then
            table.insert(button_rows, current_row)
            current_row = {}
        end
    end
    
    -- Add any remaining buttons as the last row
    if #current_row > 0 then
        table.insert(button_rows, current_row)
    end

    -- Show the dialog with the button rows
    input_dialog = InputDialog:new{
        title = _("KOAssistant Actions"),
        input = initial_input or "",  -- Restore input if provided (e.g., after domain change)
        input_hint = _("Type your question or additional instructions for any action..."),
        input_type = "text",
        buttons = button_rows,
        input_height = 6,
        allow_newline = true,
        input_multiline = true,
        text_height = 300,
        -- Settings icon in title bar - opens AI Quick Settings panel
        title_bar_left_icon = "appbar.settings",
        title_bar_left_icon_tap_callback = function()
            input_dialog:onCloseKeyboard()
            if plugin then
                -- Capture current input before showing settings
                local current_input = input_dialog:getInputText()
                -- When settings closes, refresh the dialog to apply changes
                plugin:onKOAssistantAISettings(function()
                    -- Update configuration from settings (modifies the shared configuration object)
                    plugin:updateConfigFromSettings()
                    -- Refresh the input dialog (configuration is already updated in place)
                    UIManager:close(input_dialog)
                    showChatGPTDialog(ui_instance, highlighted_text, configuration, nil, plugin, book_metadata, current_input)
                end)
            end
        end,
    }

    -- Add rotation support to input dialog
    input_dialog.onScreenResize = function(self, dimen)
        local current_input = self:getInputText()
        UIManager:close(self)
        UIManager:scheduleIn(0.2, function()
            showChatGPTDialog(ui_instance, highlighted_text, configuration, nil, plugin, book_metadata, current_input)
        end)
        return true
    end

    input_dialog.onSetRotationMode = function(self, rotation)
        return self:onScreenResize(nil)
    end
    
    -- If a prompt_type is specified, automatically trigger it after dialog is shown
    if prompt_type then
        UIManager:show(input_dialog)
        UIManager:scheduleIn(0.1, function()
            UIManager:close(input_dialog)
            
            -- Find and trigger the corresponding button
            for _, row in ipairs(button_rows) do
                for _, button in ipairs(row) do
                    if button.prompt_type == prompt_type then
                        button.callback()
                        return
                    end
                end
            end
            
            -- If no matching prompt found, just close
            UIManager:show(InfoMessage:new{
                text = _("Unknown prompt type: ") .. tostring(prompt_type),
                timeout = 2
            })
        end)
    else
        UIManager:show(input_dialog)
        -- Store reference so other entry points can close this dialog if needed
        if plugin then
            plugin.current_input_dialog = input_dialog
        end
    end
end

-- Execute an action directly without showing the intermediate dialog
-- Used for quick actions from highlight menu
-- @param ui table: The UI instance
-- @param action table: The action object (already resolved)
-- @param highlighted_text string: The highlighted text
-- @param configuration table: The configuration table
-- @param plugin table: The plugin instance
local function executeDirectAction(ui, action, highlighted_text, configuration, plugin)
    local logger = require("logger")

    if not action then
        logger.err("KOAssistant: executeDirectAction called without action")
        UIManager:show(InfoMessage:new{
            text = _("Error: No action specified"),
            timeout = 2
        })
        return
    end

    logger.info("KOAssistant: Executing quick action - " .. (action.text or action.id))
    logger.info("KOAssistant: executeDirectAction - configuration.features.book_metadata=",
               configuration and configuration.features and configuration.features.book_metadata and "present" or "nil")
    if configuration and configuration.features and configuration.features.book_metadata then
        logger.info("KOAssistant: executeDirectAction - book_metadata.title=", configuration.features.book_metadata.title or "nil")
    end

    -- Get document info if available
    local document_path = nil
    local book_metadata = nil

    if ui and ui.document then
        local props = ui.document:getProps()
        document_path = ui.document.file

        -- Extract filename as fallback for missing title metadata
        -- This gives AI something meaningful instead of "Unknown Title"
        local filename_fallback = nil
        if document_path then
            filename_fallback = document_path:match("([^/\\]+)$")  -- Get filename (Unix or Windows path)
            if filename_fallback then
                filename_fallback = filename_fallback:gsub("%.[^%.]+$", "")  -- Remove extension
                filename_fallback = filename_fallback:gsub("[_-]", " ")  -- Convert separators to spaces
            end
        end

        -- Use actual metadata if available, filename as fallback, empty author if unknown
        local title = props and props.title
        local author = props and props.authors
        book_metadata = {
            title = (title and title ~= "") and title or filename_fallback or "Unknown",
            author = (author and author ~= "") and author or ""  -- Empty, not "Unknown" - less confusing for AI
        }
    end

    -- Callback for when response is ready
    local function onComplete(history, temp_config_or_error)
        if history then
            local temp_config = temp_config_or_error
            -- Store rerun info for compact/translate view buttons (context toggle, language change)
            -- NOTE: Only store simple/serializable data in features (deepCopy would overflow on complex objects)
            if temp_config and temp_config.features and (temp_config.features.minimal_buttons or temp_config.features.translate_view) then
                -- Store complex objects at config top level (not in features, to avoid deepCopy)
                temp_config._rerun_action = action
                temp_config._rerun_ui = ui
                temp_config._rerun_plugin = plugin
                -- Preserve original context across re-runs (don't overwrite if already set)
                if not temp_config.features._original_context then
                    temp_config.features._original_context = temp_config.features.dictionary_context or ""
                    temp_config.features._original_context_mode = temp_config.features.dictionary_context_mode or "sentence"
                end
            end
            local function addMessage(message, is_context, on_complete_msg)
                history:addUserMessage(message, is_context)
                local answer_result = queryChatGPT(history:getMessages(), temp_config, function(success, answer, err, reasoning, web_search_used)
                    if success and answer then
                        history:addAssistantMessage(answer, ConfigHelper:getModelInfo(temp_config), reasoning, ConfigHelper:buildDebugInfo(temp_config), web_search_used)
                    end
                    if on_complete_msg then on_complete_msg(success, answer, err, reasoning, web_search_used) end
                end, plugin and plugin.settings)
                if not isStreamingInProgress(answer_result) then
                    return answer_result
                end
                return nil
            end
            showResponseDialog(action.text, history, highlighted_text, addMessage, temp_config, document_path, plugin, book_metadata, nil, ui)
        else
            local error_msg = temp_config_or_error or "Unknown error"
            UIManager:show(InfoMessage:new{
                text = _("Error: ") .. error_msg,
                timeout = 3
            })
        end
    end

    -- Call handlePredefinedPrompt with the action object directly
    -- (avoids re-lookup which fails for special actions not in ActionService cache)
    logger.info("KOAssistant: executeDirectAction calling handlePredefinedPrompt with highlighted_text:", highlighted_text and #highlighted_text or "nil/empty")
    handlePredefinedPrompt(action, highlighted_text, ui, configuration, nil, plugin, nil, onComplete, book_metadata)
end

return {
    showChatGPTDialog = showChatGPTDialog,
    executeDirectAction = executeDirectAction,
    extractSurroundingContext = extractSurroundingContext,
}