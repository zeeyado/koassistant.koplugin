local _ = require("gettext")

-- Settings Schema Definition
-- This file defines the structure and metadata for all KOAssistant plugin settings
-- Used to generate UI and validate settings

local SettingsSchema = {
    -- Main categories
    categories = {
        {
            id = "provider_model",
            text = _("AI Provider & Model"),
            icon = "appbar.provider",
            description = _("Select AI provider and model"),
            items = {
                {
                    id = "provider_model_select",
                    type = "submenu",
                    text = _("Provider & Model"),
                    description = _("Select AI provider and model"),
                    callback = "getFlatProviderModelMenu",
                },
                {
                    id = "test_connection",
                    type = "action",
                    text = _("Test Connection"),
                    description = _("Verify API credentials and connection"),
                    callback = "testProviderConnection",
                },
                {
                    id = "provider_config",
                    type = "submenu",
                    text = _("Provider-specific Settings (planned)"),
                    description = _("Advanced settings for the selected provider"),
                    dynamic = true,
                    enabled = false,
                },
            },
        },
        {
            id = "conversations",
            text = _("Conversations"),
            icon = "appbar.menu",
            description = _("Chat management and history"),
            items = {
                {
                    id = "new_general_chat",
                    type = "action",
                    text = _("New General Chat"),
                    description = _("Start a new conversation without context"),
                    callback = "startGeneralChat",
                },
                {
                    id = "chat_history",
                    type = "action",
                    text = _("Chat History"),
                    description = _("View and manage saved conversations"),
                    callback = "showChatHistory",
                },
                {
                    id = "separator_1",
                    type = "separator",
                },
                {
                    id = "auto_save_chats",
                    type = "toggle",
                    text = _("Auto-save Continued Chats"),
                    description = _("Automatically save chats when continued from history"),
                    default = true,
                    path = "features.auto_save_chats",
                    depends_on = { id = "auto_save_all_chats", value = false },
                },
                {
                    id = "auto_save_all_chats",
                    type = "toggle",
                    text = _("Auto-save All Chats"),
                    description = _("Automatically save all new chats with default naming"),
                    default = true,
                    path = "features.auto_save_all_chats",
                },
            },
        },
        {
            id = "prompts_responses",
            text = _("Prompts & Responses"),
            icon = "appbar.menu",
            description = _("Manage prompts and response display"),
            items = {
                {
                    id = "manage_prompts",
                    type = "action",
                    text = _("Manage Prompts"),
                    description = _("Add, edit, or remove custom prompts"),
                    callback = "showPromptsManager",
                },
                {
                    id = "view_domains",
                    type = "action",
                    text = _("View Domains"),
                    description = _("View available knowledge domains for AI context"),
                    callback = "showDomainsViewer",
                },
                {
                    id = "translation_language",
                    type = "text",
                    text = _("Translation Language"),
                    description = _("Default target language for translations"),
                    default = "English",
                    path = "features.translate_to",
                },
                {
                    id = "separator_2",
                    type = "separator",
                },
                {
                    id = "response_display_header",
                    type = "header",
                    text = _("Response Display"),
                },
                {
                    id = "render_markdown",
                    type = "toggle",
                    text = _("Render Markdown"),
                    description = _("Display AI responses with formatted text (bold, italic, lists, etc.)"),
                    default = true,
                    path = "features.render_markdown",
                },
                {
                    id = "markdown_font_size",
                    type = "number",
                    text = _("Markdown Font Size (planned)"),
                    description = _("Font size for markdown-rendered text"),
                    default = 20,
                    min = 14,
                    max = 30,
                    step = 2,
                    path = "features.markdown_font_size",
                    depends_on = { id = "render_markdown", value = true },
                    enabled = false,
                },
                {
                    id = "separator_3",
                    type = "separator",
                },
                {
                    id = "highlight_display_header",
                    type = "header",
                    text = _("Highlight Display"),
                },
                {
                    id = "hide_highlighted_text",
                    type = "toggle",
                    text = _("Hide Highlighted Text"),
                    description = _("Don't show the highlighted text in AI responses"),
                    default = false,
                    path = "features.hide_highlighted_text",
                },
                {
                    id = "hide_long_highlights",
                    type = "toggle",
                    text = _("Hide Long Highlights"),
                    description = _("Replace long highlights with '...' in display"),
                    default = true,
                    path = "features.hide_long_highlights",
                },
                {
                    id = "long_highlight_threshold",
                    type = "number",
                    text = _("Long Highlight Threshold"),
                    description = _("Number of characters before a highlight is considered long"),
                    default = 280,
                    min = 50,
                    max = 1000,
                    step = 50,
                    path = "features.long_highlight_threshold",
                    depends_on = { id = "hide_long_highlights", value = true },
                },
            },
        },
        {
            id = "advanced",
            text = _("Advanced"),
            icon = "appbar.settings",
            description = _("Debug mode and advanced options"),
            items = {
                {
                    id = "debug_mode",
                    type = "toggle",
                    text = _("Debug Mode"),
                    description = _("Enable detailed logging for troubleshooting"),
                    default = false,
                    path = "features.debug",
                },
                {
                    id = "debug_display_level",
                    type = "radio",
                    text = _("Debug Display"),
                    description = _("What to show in debug view"),
                    default = "names",
                    path = "features.debug_display_level",
                    depends_on = { id = "debug_mode", value = true },
                    options = {
                        { value = "minimal", text = _("User input only") },
                        { value = "names", text = _("Show config names") },
                        { value = "full", text = _("Full system content") },
                    },
                },
                {
                    id = "enable_streaming",
                    type = "toggle",
                    text = _("Enable Streaming"),
                    description = _("Show AI responses as they're generated"),
                    default = true,
                    path = "features.enable_streaming",
                },
                {
                    id = "stream_auto_scroll",
                    type = "toggle",
                    text = _("Auto-scroll Streaming"),
                    description = _("Automatically scroll to show new text while streaming"),
                    default = true,
                    path = "features.stream_auto_scroll",
                    depends_on = { id = "enable_streaming", value = true },
                },
                {
                    id = "large_stream_dialog",
                    type = "toggle",
                    text = _("Large Stream Dialog"),
                    description = _("Use full-screen dialog for streaming responses"),
                    default = true,
                    path = "features.large_stream_dialog",
                    depends_on = { id = "enable_streaming", value = true },
                },
                {
                    id = "separator_4",
                    type = "separator",
                },
                {
                    id = "api_settings_header",
                    type = "header",
                    text = _("API Settings"),
                },
                {
                    id = "use_new_request_format",
                    type = "toggle",
                    text = _("Use Structured Requests"),
                    description = _("Enable optimized request format with prompt caching (Anthropic only)"),
                    default = true,
                    path = "features.use_new_request_format",
                },
                {
                    id = "ai_behavior_variant",
                    type = "radio",
                    text = _("AI Behavior Style"),
                    description = _("How detailed should the AI's behavioral guidelines be"),
                    default = "full",
                    path = "features.ai_behavior_variant",
                    options = {
                        { value = "minimal", text = _("Minimal (~100 tokens)") },
                        { value = "full", text = _("Full (~500 tokens)") },
                    },
                },
                {
                    id = "default_temperature",
                    type = "number",
                    text = _("Temperature"),
                    description = _("Creativity level (0=focused, 2=creative). Forced to 1.0 with extended thinking."),
                    default = 0.7,
                    min = 0,
                    max = 2,
                    step = 0.1,
                    path = "features.default_temperature",
                },
                {
                    id = "extended_thinking_header",
                    type = "header",
                    text = _("Extended Thinking"),
                },
                {
                    id = "enable_extended_thinking",
                    type = "toggle",
                    text = _("Enable Extended Thinking"),
                    description = _("Allow AI to reason through complex problems (Anthropic only, slower)"),
                    default = false,
                    path = "features.enable_extended_thinking",
                },
                {
                    id = "thinking_budget_tokens",
                    type = "number",
                    text = _("Thinking Token Budget"),
                    description = _("Maximum tokens for thinking process (1024-32000)"),
                    default = 4096,
                    min = 1024,
                    max = 32000,
                    step = 1024,
                    path = "features.thinking_budget_tokens",
                    depends_on = { id = "enable_extended_thinking", value = true },
                },
                {
                    id = "separator_5",
                    type = "separator",
                },
                {
                    id = "settings_profiles",
                    type = "submenu",
                    text = _("Settings Profiles (planned)"),
                    description = _("Save and load named configurations"),
                    enabled = false,
                    items = {
                        {
                            id = "save_profile",
                            type = "action",
                            text = _("Save Current Profile..."),
                            callback = "saveSettingsProfile",
                        },
                        {
                            id = "load_profile",
                            type = "action",
                            text = _("Load Profile..."),
                            callback = "loadSettingsProfile",
                        },
                        {
                            id = "delete_profile",
                            type = "action",
                            text = _("Delete Profile..."),
                            callback = "deleteSettingsProfile",
                        },
                    },
                },
                {
                    id = "import_settings",
                    type = "action",
                    text = _("Import Settings... (planned)"),
                    description = _("Import settings from a file"),
                    callback = "importSettings",
                    enabled = false,
                },
                {
                    id = "export_settings",
                    type = "action",
                    text = _("Export Settings... (planned)"),
                    description = _("Export all settings to a file"),
                    callback = "exportSettings",
                    enabled = false,
                },
                {
                    id = "edit_configuration",
                    type = "action",
                    text = _("Edit configuration.lua (planned)"),
                    description = _("Open configuration file for advanced editing"),
                    callback = "editConfigurationFile",
                    enabled = false,
                },
            },
        },
        {
            id = "about",
            text = _("About"),
            icon = "appbar.info",
            description = _("Updates and version information"),
            items = {
                {
                    id = "check_updates",
                    type = "action",
                    text = _("Check for Updates"),
                    description = _("Check for new plugin versions"),
                    callback = "checkForUpdates",
                },
                {
                    id = "auto_check_updates",
                    type = "toggle",
                    text = _("Auto-check for Updates"),
                    description = _("Check for updates on first use each session"),
                    default = true,
                    path = "features.auto_check_updates",
                },
                {
                    id = "separator_updates",
                    type = "separator",
                },
                {
                    id = "version_info",
                    type = "action",
                    text = _("Version Info"),
                    description = _("Show version and gesture information"),
                    callback = "showAbout",
                },
            },
        },
    },

    -- Helper functions for schema usage
    getCategoryById = function(self, id)
        for _, category in ipairs(self.categories) do
            if category.id == id then
                return category
            end
        end
        return nil
    end,

    getItemById = function(self, item_id)
        for _, category in ipairs(self.categories) do
            for _, item in ipairs(category.items) do
                if item.id == item_id then
                    return item, category
                end
                -- Check submenu items
                if item.type == "submenu" and item.items then
                    for _, subitem in ipairs(item.items) do
                        if subitem.id == item_id then
                            return subitem, item
                        end
                    end
                end
            end
        end
        return nil
    end,

    -- Validate a settings value against its schema
    validateSetting = function(self, item_id, value)
        local item = self:getItemById(item_id)
        if not item then
            return false, "Unknown setting: " .. item_id
        end

        if item.type == "toggle" then
            return type(value) == "boolean", "Value must be true or false"
        elseif item.type == "number" then
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