local _ = require("koassistant_gettext")
local T = require("ffi/util").template
local ModelConstraints = require("model_constraints")

-- Settings Schema Definition
-- This file defines the structure and metadata for all KOAssistant plugin settings
-- Used by SettingsManager to generate menus - SINGLE SOURCE OF TRUTH

-- Helper: Build model list string from capabilities
local function getModelList(provider, capability)
    local caps = ModelConstraints.capabilities[provider]
    if not caps or not caps[capability] then return "" end

    local models = {}
    for _, model in ipairs(caps[capability]) do
        -- Shorten model names for display (remove date suffixes)
        local short = model:gsub("%-20%d%d%d%d%d%d$", "-*")
        table.insert(models, "- " .. short)
    end
    return table.concat(models, "\n")
end

local SettingsSchema = {
    -- Menu items in display order (flat structure matching main menu)
    items = {
        -- Quick actions
        {
            id = "chat_about_book",
            type = "action",
            text = _("Chat about Book"),
            callback = "onKOAssistantBookChat",
            visible_func = function(plugin)
                return plugin.ui and plugin.ui.document ~= nil
            end,
        },
        {
            id = "new_general_chat",
            type = "action",
            text = _("New General Chat"),
            callback = "startGeneralChat",
        },
        {
            id = "chat_history",
            type = "action",
            text = _("Chat History"),
            callback = "showChatHistory",
            separator = true,
        },

        -- Provider, Model, Temperature (top-level)
        {
            id = "provider",
            type = "submenu",
            text_func = function(plugin)
                local f = plugin.settings:readSetting("features") or {}
                local provider = f.provider or "anthropic"
                return T(_("Provider: %1"), provider:gsub("^%l", string.upper))
            end,
            callback = "buildProviderMenu",
        },
        {
            id = "model",
            type = "submenu",
            text_func = function(plugin)
                return T(_("Model: %1"), plugin:getCurrentModel())
            end,
            callback = "buildModelMenu",
        },
        {
            id = "api_keys",
            type = "submenu",
            text = _("API Keys"),
            callback = "buildApiKeysMenu",
            separator = true,
        },
        -- Display Settings submenu
        {
            id = "display_settings",
            type = "submenu",
            text = _("Display Settings"),
            items = {
                {
                    id = "render_markdown",
                    type = "toggle",
                    text = _("Render Markdown"),
                    path = "features.render_markdown",
                    default = true,
                },
                {
                    id = "hide_highlighted_text",
                    type = "toggle",
                    text = _("Hide Highlighted Text"),
                    path = "features.hide_highlighted_text",
                    default = false,
                },
                {
                    id = "hide_long_highlights",
                    type = "toggle",
                    text = _("Hide Long Highlights"),
                    path = "features.hide_long_highlights",
                    default = true,
                    depends_on = { id = "hide_highlighted_text", value = false },
                },
                {
                    id = "long_highlight_threshold",
                    type = "spinner",
                    text = _("Long Highlight Threshold"),
                    path = "features.long_highlight_threshold",
                    default = 280,
                    min = 50,
                    max = 1000,
                    step = 10,
                    precision = "%d",
                    depends_on = { id = "hide_long_highlights", value = true },
                },
            },
        },

        -- Chat Settings submenu
        {
            id = "chat_settings",
            type = "submenu",
            text = _("Chat Settings"),
            items = {
                {
                    id = "auto_save_all_chats",
                    type = "toggle",
                    text = _("Auto-save All Chats"),
                    path = "features.auto_save_all_chats",
                    default = true,
                },
                {
                    id = "auto_save_chats",
                    type = "toggle",
                    text = _("Auto-save Continued Chats"),
                    path = "features.auto_save_chats",
                    default = true,
                    depends_on = { id = "auto_save_all_chats", value = false },
                    separator = true,
                },
                {
                    id = "enable_streaming",
                    type = "toggle",
                    text = _("Enable Streaming"),
                    path = "features.enable_streaming",
                    default = true,
                },
                {
                    id = "stream_auto_scroll",
                    type = "toggle",
                    text = _("Auto-scroll Streaming"),
                    path = "features.stream_auto_scroll",
                    default = false,
                    depends_on = { id = "enable_streaming", value = true },
                },
                {
                    id = "large_stream_dialog",
                    type = "toggle",
                    text = _("Large Stream Dialog"),
                    path = "features.large_stream_dialog",
                    default = true,
                    depends_on = { id = "enable_streaming", value = true },
                },
                {
                    id = "stream_poll_interval",
                    type = "spinner",
                    text = _("Stream Poll Interval (ms)"),
                    path = "features.stream_poll_interval",
                    default = 125,
                    min = 25,
                    max = 1000,
                    step = 25,
                    precision = "%d",
                    info_text = _("How often to check for new stream data.\nLower = snappier but uses more battery."),
                    depends_on = { id = "enable_streaming", value = true },
                },
                {
                    id = "stream_display_interval",
                    type = "spinner",
                    text = _("Display Refresh Interval (ms)"),
                    path = "features.stream_display_interval",
                    default = 250,
                    min = 100,
                    max = 500,
                    step = 50,
                    precision = "%d",
                    info_text = _("How often to refresh the display during streaming.\nHigher = better performance on slower devices."),
                    depends_on = { id = "enable_streaming", value = true },
                },
            },
        },

        -- Advanced submenu
        {
            id = "advanced",
            type = "submenu",
            text = _("Advanced"),
            separator = true,
            items = {
                {
                    id = "manage_behaviors",
                    type = "action",
                    text_func = function(plugin)
                        local f = plugin.settings:readSetting("features") or {}
                        local selected = f.selected_behavior or "standard"
                        -- Get display name for selected behavior
                        local SystemPrompts = require("prompts/system_prompts")
                        local behavior = SystemPrompts.getBehaviorById(selected, f.custom_behaviors)
                        local name = behavior and behavior.display_name or selected
                        return T(_("Manage Behaviors (%1)"), name)
                    end,
                    callback = "showBehaviorManager",
                    info_text = _("Select or create AI behavior styles that define how the AI communicates."),
                },
                {
                    id = "manage_domains",
                    type = "action",
                    text = _("Manage Domains..."),
                    callback = "showDomainManager",
                    info_text = _("Manage knowledge domains. Domains are selected per-chat."),
                    separator = true,
                },
                {
                    id = "temperature",
                    type = "spinner",
                    text = _("Temperature"),
                    path = "features.default_temperature",
                    default = 0.7,
                    min = 0,
                    max = 2,
                    step = 0.1,
                    precision = "%.1f",
                    info_text = _("Range: 0.0-2.0 (Anthropic max 1.0)\nLower = focused, deterministic\nHigher = creative, varied"),
                    separator = true,
                },
                -- Reasoning / Thinking submenu (per-provider toggles)
                {
                    id = "reasoning_submenu",
                    type = "submenu",
                    text = _("Reasoning"),
                    items = {
                        -- Hint about long-press for model info
                        {
                            type = "info",
                            text = _("Long-press provider for supported models"),
                        },
                        {
                            type = "separator",
                        },
                        -- Anthropic Extended Thinking
                        {
                            id = "anthropic_reasoning",
                            type = "toggle",
                            text = _("Anthropic Extended Thinking"),
                            help_text = _("Supported models:\n") .. getModelList("anthropic", "extended_thinking") .. _("\n\nLet Claude think through complex problems before responding."),
                            path = "features.anthropic_reasoning",
                            default = false,
                        },
                        {
                            id = "reasoning_budget",
                            type = "spinner",
                            text = _("Thinking Budget (tokens)"),
                            help_text = _("Token budget for extended thinking (1024-32000)\nHigher = more thorough reasoning, slower, more expensive"),
                            path = "features.reasoning_budget",
                            default = 4096,
                            min = 1024,
                            max = 32000,
                            step = 1024,
                            precision = "%d",
                            depends_on = { id = "anthropic_reasoning", value = true },
                            separator = true,
                        },
                        -- OpenAI Reasoning
                        {
                            id = "openai_reasoning",
                            type = "toggle",
                            text = _("OpenAI Reasoning"),
                            help_text = _("Supported models:\n") .. getModelList("openai", "reasoning") .. _("\n\nReasoning is encrypted/hidden from user."),
                            path = "features.openai_reasoning",
                            default = false,
                        },
                        {
                            id = "reasoning_effort",
                            type = "radio",
                            text_func = function(plugin)
                                local f = plugin.settings:readSetting("features") or {}
                                local effort = f.reasoning_effort or "medium"
                                local labels = { low = _("Low"), medium = _("Medium"), high = _("High") }
                                return T(_("Reasoning Effort: %1"), labels[effort] or effort)
                            end,
                            help_text = _("Low = faster, cheaper\nMedium = balanced\nHigh = thorough reasoning"),
                            path = "features.reasoning_effort",
                            default = "medium",
                            depends_on = { id = "openai_reasoning", value = true },
                            separator = true,
                            options = {
                                { value = "low", text = _("Low (faster, cheaper)") },
                                { value = "medium", text = _("Medium (balanced)") },
                                { value = "high", text = _("High (thorough)") },
                            },
                        },
                        -- Gemini Thinking
                        {
                            id = "gemini_reasoning",
                            type = "toggle",
                            text = _("Gemini Thinking"),
                            help_text = _("Supported models:\n") .. getModelList("gemini", "thinking") .. _("\n\nThinking is encrypted/hidden from user."),
                            path = "features.gemini_reasoning",
                            default = false,
                        },
                        {
                            id = "reasoning_depth",
                            type = "radio",
                            text_func = function(plugin)
                                local f = plugin.settings:readSetting("features") or {}
                                local depth = f.reasoning_depth or "high"
                                local labels = { minimal = _("Minimal"), low = _("Low"), medium = _("Medium"), high = _("High") }
                                return T(_("Thinking Depth: %1"), labels[depth] or depth)
                            end,
                            help_text = _("Minimal = fastest\nLow/Medium = balanced\nHigh = deepest thinking"),
                            path = "features.reasoning_depth",
                            default = "high",
                            depends_on = { id = "gemini_reasoning", value = true },
                            separator = true,
                            options = {
                                { value = "minimal", text = _("Minimal (fastest)") },
                                { value = "low", text = _("Low") },
                                { value = "medium", text = _("Medium") },
                                { value = "high", text = _("High (default)") },
                            },
                        },
                        -- Indicator in chat (separate from "Show Reasoning" button)
                        {
                            id = "show_reasoning_indicator",
                            type = "toggle",
                            text = _("Show Indicator in Chat"),
                            help_text = _("Show '*[Reasoning was used]*' indicator in chat when reasoning is requested or used.\n\nFull reasoning content is always viewable via 'Show Reasoning' button."),
                            path = "features.show_reasoning_indicator",
                            default = true,
                        },
                    },
                },
                {
                    id = "debug",
                    type = "toggle",
                    text = _("Console Debug"),
                    help_text = _("Enable console/terminal debug logging (for developers)"),
                    path = "features.debug",
                    default = false,
                },
                {
                    id = "show_debug_in_chat",
                    type = "toggle",
                    text = _("Show Debug in Chat"),
                    help_text = _("Display debug information in chat viewer"),
                    path = "features.show_debug_in_chat",
                    default = false,
                },
                {
                    id = "debug_display_level",
                    type = "radio",
                    text_func = function(plugin)
                        local f = plugin.settings:readSetting("features") or {}
                        local level = f.debug_display_level or "names"
                        local labels = { minimal = _("Minimal"), names = _("Names"), full = _("Full") }
                        return T(_("Debug Detail Level: %1"), labels[level] or level)
                    end,
                    path = "features.debug_display_level",
                    default = "names",
                    depends_on = { id = "show_debug_in_chat", value = true },
                    separator = true,
                    options = {
                        { value = "minimal", text = _("Minimal (user input only)") },
                        { value = "names", text = _("Names (config summary)") },
                        { value = "full", text = _("Full (system blocks)") },
                    },
                },
                {
                    id = "test_connection",
                    type = "action",
                    text = _("Test Connection"),
                    callback = "testProviderConnection",
                },
            },
        },

        -- Language Settings submenu
        {
            id = "language_settings",
            type = "submenu",
            text = _("Language"),
            items = {
                {
                    id = "ui_language_info",
                    type = "header",
                    text = _("Disable to show English UI (requires restart)"),
                },
                {
                    id = "ui_language_auto",
                    type = "toggle",
                    text = _("Match KOReader UI Language"),
                    path = "features.ui_language_auto",
                    default = true,
                    separator = true,
                    on_change = function()
                        local InfoMessage = require("ui/widget/infomessage")
                        local UIManager = require("ui/uimanager")
                        UIManager:show(InfoMessage:new{
                            text = _("Please restart KOReader for the language change to take effect."),
                        })
                    end,
                },
                {
                    id = "user_languages",
                    type = "text",
                    text = _("Your Languages"),
                    path = "features.user_languages",
                    default = "",
                    help_text = _("Languages you speak, separated by commas. Leave empty for default AI behavior.\n\nExamples:\n• \"English\"\n• \"German, English, French\""),
                },
                {
                    id = "primary_language",
                    type = "submenu",
                    text_func = function(plugin)
                        local primary = plugin:getEffectivePrimaryLanguage()
                        if not primary or primary == "" then
                            return _("Primary Language: (not set)")
                        end
                        return T(_("Primary Language: %1"), primary)
                    end,
                    callback = "buildPrimaryLanguageMenu",
                    separator = true,
                },
                {
                    id = "translation_use_primary",
                    type = "toggle",
                    text = _("Translate to Primary Language"),
                    path = "features.translation_use_primary",
                    default = true,
                    help_text = _("Use your primary language as the translation target. Disable to choose a different target."),
                    -- Sync translation_language when toggle changes
                    on_change = function(new_value, plugin)
                        local f = plugin.settings:readSetting("features") or {}
                        if new_value then
                            -- When turning ON, set sentinel to keep in sync
                            f.translation_language = "__PRIMARY__"
                            plugin.settings:saveSetting("features", f)
                            plugin.settings:flush()
                        end
                        -- When turning OFF, leave translation_language as is
                        -- (user can then pick a specific language from the submenu)
                    end,
                },
                {
                    id = "translation_language",
                    type = "submenu",
                    text_func = function(plugin)
                        local f = plugin.settings:readSetting("features") or {}
                        local target = f.translation_language
                        -- Show actual language, handle sentinel values
                        if target == "__PRIMARY__" or target == nil or target == "" then
                            local primary = plugin:getEffectivePrimaryLanguage() or "English"
                            target = primary
                        end
                        return T(_("Translation Target: %1"), target)
                    end,
                    callback = "buildTranslationLanguageMenu",
                    depends_on = { id = "translation_use_primary", value = false },
                },
            },
        },

        -- Dictionary Settings
        {
            id = "dictionary_settings",
            type = "submenu",
            text = _("Dictionary Settings"),
            items = {
                {
                    id = "enable_dictionary_hook",
                    type = "toggle",
                    text = _("AI Button in Dictionary Popup"),
                    path = "features.enable_dictionary_hook",
                    default = true,
                    help_text = _("Show AI Dictionary button when tapping on a word"),
                },
                {
                    id = "dictionary_language",
                    type = "submenu",
                    text_func = function(plugin)
                        local f = plugin.settings:readSetting("features") or {}
                        local lang = f.dictionary_language or "__FOLLOW_TRANSLATION__"
                        if lang == "__FOLLOW_TRANSLATION__" then
                            return _("Response Language: (Follow Translation)")
                        end
                        return T(_("Response Language: %1"), lang)
                    end,
                    callback = "buildDictionaryLanguageMenu",
                },
                {
                    id = "dictionary_context_mode",
                    type = "submenu",
                    text_func = function(plugin)
                        local f = plugin.settings:readSetting("features") or {}
                        local mode = f.dictionary_context_mode or "sentence"
                        local labels = {
                            sentence = _("Sentence"),
                            paragraph = _("Paragraph"),
                            characters = _("Characters"),
                            none = _("None"),
                        }
                        return T(_("Context Mode: %1"), labels[mode] or mode)
                    end,
                    callback = "buildDictionaryContextModeMenu",
                },
                {
                    id = "dictionary_context_chars",
                    type = "spinner",
                    text = _("Context Characters"),
                    path = "features.dictionary_context_chars",
                    default = 100,
                    min = 20,
                    max = 500,
                    step = 10,
                    help_text = _("Number of characters to include before/after the word when Context Mode is 'Characters'"),
                    enabled_func = function(plugin)
                        local f = plugin.settings:readSetting("features") or {}
                        return f.dictionary_context_mode == "characters"
                    end,
                },
                {
                    id = "dictionary_save_mode",
                    type = "submenu",
                    text_func = function(plugin)
                        local f = plugin.settings:readSetting("features") or {}
                        local mode = f.dictionary_save_mode or "none"
                        local labels = {
                            default = _("Default (Document)"),
                            none = _("Don't Save"),
                            dictionary = _("Dictionary Chats"),
                        }
                        return T(_("Save Mode: %1"), labels[mode] or mode)
                    end,
                    callback = "buildDictionarySaveModeMenu",
                },
                {
                    id = "dictionary_enable_streaming",
                    type = "toggle",
                    text = _("Enable Streaming"),
                    path = "features.dictionary_enable_streaming",
                    default = true,
                    help_text = _("Stream dictionary responses in real-time. Disable to wait for complete response."),
                },
                {
                    id = "dictionary_popup_actions",
                    type = "action",
                    text = _("Dictionary Popup Actions"),
                    callback = "showDictionaryPopupManager",
                    help_text = _("Configure which actions appear in the dictionary popup"),
                },
                {
                    id = "dictionary_bypass_enabled",
                    type = "toggle",
                    text = _("Bypass KOReader Dictionary"),
                    path = "features.dictionary_bypass_enabled",
                    default = false,
                    help_text = _("Skip KOReader's dictionary and go directly to AI when tapping words. Can also be toggled via gesture."),
                    on_change = function(new_value, plugin)
                        -- Re-sync the bypass when setting changes
                        if plugin.syncDictionaryBypass then
                            local UIManager = require("ui/uimanager")
                            UIManager:nextTick(function()
                                plugin:syncDictionaryBypass()
                            end)
                        end
                    end,
                },
                {
                    id = "dictionary_bypass_action",
                    type = "submenu",
                    text_func = function(plugin)
                        local f = plugin.settings:readSetting("features") or {}
                        local action_id = f.dictionary_bypass_action or "dictionary"
                        -- Try to get action name
                        local Actions = require("prompts/actions")
                        local action = Actions.getById(action_id)
                        if action then
                            return T(_("Bypass Action: %1"), action.text)
                        end
                        -- Check special actions
                        if Actions.special and Actions.special[action_id] then
                            return T(_("Bypass Action: %1"), Actions.special[action_id].text)
                        end
                        return T(_("Bypass Action: %1"), action_id)
                    end,
                    callback = "buildDictionaryBypassActionMenu",
                    help_text = _("Action to trigger when dictionary bypass is enabled"),
                },
            },
        },

        -- Highlight Settings
        {
            id = "highlight_settings",
            type = "submenu",
            text = _("Highlight Settings"),
            items = {
                {
                    id = "highlight_bypass_enabled",
                    type = "toggle",
                    text = _("Enable Highlight Bypass"),
                    path = "features.highlight_bypass_enabled",
                    default = false,
                    help_text = _("Immediately trigger an action when text is selected, skipping the highlight menu. Can also be toggled via gesture."),
                },
                {
                    id = "highlight_bypass_action",
                    type = "submenu",
                    text_func = function(plugin)
                        local f = plugin.settings:readSetting("features") or {}
                        local action_id = f.highlight_bypass_action or "translate"
                        -- Try to get action name
                        local Actions = require("prompts/actions")
                        local action = Actions.getById(action_id)
                        if action then
                            return T(_("Bypass Action: %1"), action.text)
                        end
                        -- Check special actions
                        if Actions.special and Actions.special[action_id] then
                            return T(_("Bypass Action: %1"), Actions.special[action_id].text)
                        end
                        return T(_("Bypass Action: %1"), action_id)
                    end,
                    callback = "buildHighlightBypassActionMenu",
                    help_text = _("Action to trigger when highlight bypass is enabled"),
                },
                {
                    id = "highlight_menu_actions",
                    type = "action",
                    text = _("Highlight Menu Actions"),
                    callback = "showHighlightMenuManager",
                    help_text = _("Choose which actions appear in the highlight menu (requires restart)"),
                },
            },
        },

        -- Actions and Domains
        {
            id = "manage_actions",
            type = "action",
            text = _("Manage Actions"),
            callback = "showPromptsManager",
            separator = true,
        },

        -- About
        {
            id = "about",
            type = "action",
            text = _("About KOAssistant"),
            callback = "showAbout",
        },
        {
            id = "check_updates",
            type = "action",
            text = _("Check for Updates"),
            callback = "checkForUpdates",
        },
    },

    -- Helper functions for schema usage
    getItemById = function(self, item_id, items_list)
        items_list = items_list or self.items
        for _, item in ipairs(items_list) do
            if item.id == item_id then
                return item
            end
            -- Check submenu items
            if item.type == "submenu" and item.items then
                local found = self:getItemById(item_id, item.items)
                if found then
                    return found
                end
            end
        end
        return nil
    end,

    -- Get the path for dependency resolution
    getItemPath = function(self, item_id, items_list)
        local item = self:getItemById(item_id, items_list)
        if item then
            return item.path or item.id
        end
        return item_id
    end,

    -- Validate a settings value against its schema
    validateSetting = function(self, item_id, value)
        local item = self:getItemById(item_id)
        if not item then
            return false, "Unknown setting: " .. item_id
        end

        if item.type == "toggle" then
            return type(value) == "boolean", "Value must be true or false"
        elseif item.type == "number" or item.type == "spinner" then
            if type(value) ~= "number" then
                return false, "Value must be a number"
            end
            if item.min and value < item.min then
                return false, string.format("Value must be at least %d", item.min)
            end
            if item.max and value > item.max then
                return false, string.format("Value must be at most %d", item.max)
            end
            return true
        elseif item.type == "text" then
            return type(value) == "string", "Value must be text"
        elseif item.type == "radio" then
            for _, option in ipairs(item.options) do
                if option.value == value then
                    return true
                end
            end
            return false, "Invalid option selected"
        end

        return true -- No validation for other types
    end,
}

return SettingsSchema
