local _ = require("gettext")
local T = require("ffi/util").template

-- Settings Schema Definition
-- This file defines the structure and metadata for all KOAssistant plugin settings
-- Used by SettingsManager to generate menus - SINGLE SOURCE OF TRUTH

local SettingsSchema = {
    -- Menu items in display order (flat structure matching main menu)
    items = {
        -- Quick actions
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
                    default = true,
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
                    id = "ai_behavior_variant",
                    type = "radio",
                    text_func = function(plugin)
                        local f = plugin.settings:readSetting("features") or {}
                        local variant = f.ai_behavior_variant or "full"
                        return T(_("AI Behavior: %1"), variant == "minimal" and _("Minimal") or _("Full"))
                    end,
                    path = "features.ai_behavior_variant",
                    default = "full",
                    separator = true,
                    options = {
                        { value = "minimal", text = _("Minimal (~100 tokens)") },
                        { value = "full", text = _("Full (~500 tokens)") },
                    },
                },
                {
                    id = "enable_extended_thinking",
                    type = "toggle",
                    text = _("Enable Extended Thinking"),
                    path = "features.enable_extended_thinking",
                    default = false,
                },
                {
                    id = "thinking_budget_tokens",
                    type = "spinner",
                    text = _("Thinking Budget"),
                    path = "features.thinking_budget_tokens",
                    default = 4096,
                    min = 1024,
                    max = 32000,
                    step = 1024,
                    precision = "%d",
                    depends_on = { id = "enable_extended_thinking", value = true },
                    separator = true,
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
                    id = "user_languages",
                    type = "text",
                    text = _("Your Languages (first is primary)"),
                    path = "features.user_languages",
                    default = "",
                    help_text = _("Languages you speak, separated by commas. Leave empty for default AI behavior.\n\nThe FIRST language is your primary. AI will:\n• Respond in your primary language by default\n• Switch to another language if you type in it\n\nExamples:\n• \"English\" - always respond in English\n• \"German, English\" - German by default, English if you type in English"),
                    separator = true,
                },
                {
                    id = "translation_use_primary",
                    type = "toggle",
                    text = _("Translate to Primary Language"),
                    path = "features.translation_use_primary",
                    default = true,
                    help_text = _("Use your first language as the translation target. Disable to set a custom target."),
                },
                {
                    id = "translation_language",
                    type = "text",
                    text = _("Translation Target"),
                    path = "features.translation_language",
                    default = "English",
                    depends_on = { id = "translation_use_primary", value = false },
                    help_text = _("Target language for the Translate action."),
                },
            },
        },

        -- Actions and Domains
        {
            id = "manage_actions",
            type = "action",
            text = _("Manage Actions"),
            callback = "showPromptsManager",
        },
        {
            id = "highlight_menu_actions",
            type = "action",
            text = _("Highlight Menu Actions"),
            callback = "showHighlightMenuManager",
        },
        {
            id = "view_domains",
            type = "action",
            text = _("View Domains"),
            callback = "showDomainsViewer",
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
