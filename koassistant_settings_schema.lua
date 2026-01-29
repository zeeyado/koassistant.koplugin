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

        -- Reading Features submenu (visible only when document is open)
        {
            id = "reading_features",
            type = "submenu",
            text = _("Reading Features"),
            visible_func = function(plugin)
                return plugin.ui and plugin.ui.document ~= nil
            end,
            separator = true,
            items = {
                {
                    id = "xray",
                    type = "action",
                    text = _("X-Ray"),
                    info_text = _("Generate a structured reference guide for the book up to your current position. Includes characters, locations, themes, and plot events."),
                    callback = "onKOAssistantXRay",
                },
                {
                    id = "recap",
                    type = "action",
                    text = _("Recap"),
                    info_text = _("Get a 'Previously on...' style summary to refresh your memory when returning to a book."),
                    callback = "onKOAssistantRecap",
                },
                {
                    id = "analyze_highlights",
                    type = "action",
                    text = _("Analyze Highlights"),
                    info_text = _("Analyze your highlights and annotations to discover reading patterns and connections."),
                    callback = "onKOAssistantAnalyzeHighlights",
                },
            },
        },

        -- Provider, Model, Temperature (top-level)
        {
            id = "provider",
            type = "submenu",
            text_func = function(plugin)
                local f = plugin.settings:readSetting("features") or {}
                local provider = f.provider or "anthropic"
                return T(_("Provider: %1"), plugin:getProviderDisplayName(provider))
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
                    separator = true,
                },
                -- Export settings
                {
                    id = "export_style",
                    type = "dropdown",
                    text = _("Export Style"),
                    path = "features.export_style",
                    default = "markdown",
                    options = {
                        { value = "markdown", label = _("Markdown") },
                        { value = "text", label = _("Plain Text") },
                    },
                    help_text = _("Markdown uses # headers and **bold**. Plain text uses simple formatting."),
                },
                {
                    id = "copy_content",
                    type = "dropdown",
                    text = _("Copy Content"),
                    path = "features.copy_content",
                    default = "full",
                    options = {
                        { value = "ask", label = _("Ask every time") },
                        { value = "full", label = _("Full (metadata + chat)") },
                        { value = "qa", label = _("Question + Response") },
                        { value = "response", label = _("Response only") },
                        { value = "everything", label = _("Everything (debug)") },
                    },
                    help_text = _("What to include when copying chat to clipboard."),
                },
                {
                    id = "note_content",
                    type = "dropdown",
                    text = _("Note Content"),
                    path = "features.note_content",
                    default = "response",
                    options = {
                        { value = "ask", label = _("Ask every time") },
                        { value = "full", label = _("Full (metadata + chat)") },
                        { value = "qa", label = _("Question + Response") },
                        { value = "response", label = _("Response only") },
                        { value = "everything", label = _("Everything (debug)") },
                    },
                    help_text = _("What to include when saving to note."),
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
                -- Provider-specific settings
                {
                    id = "provider_settings",
                    type = "submenu",
                    text = _("Provider Settings"),
                    items = {
                        {
                            id = "qwen_region",
                            type = "radio",
                            text_func = function(plugin)
                                local f = plugin.settings:readSetting("features") or {}
                                local region = f.qwen_region or "international"
                                local labels = {
                                    international = _("International"),
                                    china = _("China"),
                                    us = _("US"),
                                }
                                return T(_("Qwen Region: %1"), labels[region] or region)
                            end,
                            help_text = _("Select your Alibaba Cloud region.\n\nAPI keys are region-specific and NOT interchangeable:\n- International: Singapore (dashscope-intl)\n- China: Beijing (dashscope)\n- US: Virginia (dashscope-us)"),
                            path = "features.qwen_region",
                            default = "international",
                            options = {
                                { value = "international", text = _("International (Singapore)") },
                                { value = "china", text = _("China (Beijing)") },
                                { value = "us", text = _("US (Virginia)") },
                            },
                        },
                    },
                },
                -- Context Extraction settings
                {
                    id = "context_extraction",
                    type = "submenu",
                    text = _("Book Text Extraction"),
                    items = {
                        {
                            id = "context_extraction_info",
                            type = "header",
                            text = _("Book text extraction is slow and uses many tokens. Enable only if needed."),
                        },
                        {
                            id = "enable_book_text_extraction",
                            type = "toggle",
                            text = _("Allow Book Text Extraction"),
                            path = "features.enable_book_text_extraction",
                            default = false,
                            help_text = _("When enabled, actions that request book text (like X-Ray, Recap) can extract and send it to the AI. This is slow and uses many tokens.\n\nNote: Lightweight data (reading progress, highlights, annotations) is always available and doesn't need this setting."),
                        },
                        {
                            id = "max_book_text_chars",
                            type = "spinner",
                            text = _("Max Text Characters"),
                            path = "features.max_book_text_chars",
                            default = 50000,
                            min = 10000,
                            max = 500000,
                            step = 10000,
                            precision = "%d",
                            help_text = _("Maximum characters to extract from the book (10,000-500,000). Higher values provide more context but use more tokens. Default: 50,000 (~12k tokens)."),
                            depends_on = { id = "enable_book_text_extraction", value = true },
                        },
                        {
                            id = "max_pdf_pages",
                            type = "spinner",
                            text = _("Max PDF Pages"),
                            path = "features.max_pdf_pages",
                            default = 250,
                            min = 50,
                            max = 500,
                            step = 50,
                            precision = "%d",
                            help_text = _("Maximum PDF pages to extract text from (50-500). Higher values provide more context but take longer."),
                            depends_on = { id = "enable_book_text_extraction", value = true },
                        },
                    },
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
                    separator = true,
                },
                -- Settings Management submenu
                {
                    id = "settings_management",
                    type = "submenu",
                    text = _("Settings Management"),
                    items = {
                        {
                            id = "create_backup",
                            type = "action",
                            text = _("Create Backup"),
                            info_text = _("Create a backup of your settings, API keys, and custom content."),
                            callback = "showCreateBackupDialog",
                        },
                        {
                            id = "restore_backup",
                            type = "action",
                            text = _("Restore from Backup"),
                            info_text = _("Restore settings from a previous backup."),
                            callback = "showRestoreBackupDialog",
                        },
                        {
                            id = "manage_backups",
                            type = "action",
                            text = _("View Backups"),
                            info_text = _("View and manage existing backups."),
                            callback = "showBackupListDialog",
                            separator = true,
                        },
                        {
                            id = "backup_settings_info",
                            type = "header",
                            text = _("Backups are stored in: koassistant_backups/"),
                        },
                    },
                },
                -- Reset Settings submenu
                {
                    id = "reset_settings",
                    type = "submenu",
                    text = _("Reset Settings..."),
                    items = {
                        -- Feature settings (toggles only)
                        {
                            id = "reset_feature_settings",
                            type = "action",
                            text = _("Reset feature settings"),
                            info_text = _("Resets provider, model, temperature, streaming, reasoning, and other toggles.\n\nPreserves: API keys, all actions, behaviors, custom models, chat history."),
                            confirm = true,
                            confirm_text = _("Reset feature settings to defaults?\n\nResets: Provider, model, temperature, streaming, reasoning toggles.\n\nPreserves: API keys, custom actions, action edits, behaviors, custom models, chat history."),
                            callback = "resetFeatureSettings",
                            separator = true,
                        },
                        -- Action resets submenu
                        {
                            id = "reset_actions_submenu",
                            type = "submenu",
                            text = _("Reset actions..."),
                            items = {
                                {
                                    id = "reset_custom_actions",
                                    type = "action",
                                    text = _("Reset custom actions"),
                                    info_text = _("Deletes all user-created actions.\n\nPreserves: Built-in actions, action edits, menu configurations."),
                                    confirm = true,
                                    confirm_text = _("Delete all custom actions?\n\nThis removes actions you created.\n\nBuilt-in actions and their edits are preserved."),
                                    callback = "resetCustomActions",
                                },
                                {
                                    id = "reset_action_edits",
                                    type = "action",
                                    text = _("Reset action edits"),
                                    info_text = _("Resets all edits to built-in actions back to defaults. Also re-enables any disabled actions.\n\nPreserves: Custom actions, menu configurations."),
                                    confirm = true,
                                    confirm_text = _("Reset all action edits?\n\nThis reverts any changes you made to built-in actions and re-enables disabled actions.\n\nCustom actions are preserved."),
                                    callback = "resetActionEdits",
                                },
                                {
                                    id = "reset_action_menus",
                                    type = "action",
                                    text = _("Reset action menus"),
                                    info_text = _("Resets highlight menu and dictionary popup configurations back to defaults.\n\nPreserves: Actions themselves (both custom and built-in)."),
                                    confirm = true,
                                    confirm_text = _("Reset action menu configurations?\n\nThis resets the ordering and selection in highlight menu and dictionary popup back to defaults.\n\nYour actions (custom and built-in) are preserved."),
                                    callback = "resetActionMenus",
                                },
                            },
                        },
                        -- Provider/model reset
                        {
                            id = "reset_providers_models",
                            type = "action",
                            text = _("Reset custom providers/models"),
                            info_text = _("Removes custom providers, custom models, and per-provider default model selections.\n\nPreserves: API keys, actions, behaviors."),
                            confirm = true,
                            confirm_text = _("Reset custom providers and models?\n\nThis removes:\n• Custom providers you added\n• Custom models for any provider\n• Per-provider default model selections\n\nAPI keys and actions are preserved."),
                            callback = "resetCustomProvidersModels",
                            separator = true,
                        },
                        -- Combined resets
                        {
                            id = "reset_all_customizations",
                            type = "action",
                            text = _("Reset all customizations"),
                            info_text = _("Resets ALL customizations: actions, edits, menus, behaviors, domains, providers, models.\n\nPreserves: API keys, chat history."),
                            confirm = true,
                            confirm_text = _("Reset ALL customizations?\n\nThis resets:\n• Custom actions and action edits\n• Menu configurations\n• Behaviors and domains\n• Custom providers and models\n• Feature settings\n\nOnly API keys and chat history are preserved."),
                            callback = "resetAllCustomizations",
                        },
                        {
                            id = "reset_everything",
                            type = "action",
                            text = _("Reset everything (nuclear)"),
                            info_text = _("⚠️ COMPLETE RESET: Deletes ALL settings including API keys.\n\nPreserves: Chat history only."),
                            confirm = true,
                            confirm_text = _("⚠️ RESET EVERYTHING?\n\nThis will DELETE:\n• All settings and configurations\n• Custom actions, behaviors, domains\n• Custom models and providers\n• API keys (you'll need to re-enter)\n• Action menu customizations\n\nOnly chat history will be preserved.\n\nThis CANNOT be undone!"),
                            callback = "resetEverything",
                            separator = true,
                        },
                        -- Chat history (separate concern)
                        {
                            id = "clear_chat_history",
                            type = "action",
                            text = _("Clear all chat history"),
                            info_text = _("Deletes all saved conversations across all books."),
                            confirm = true,
                            confirm_text = _("Delete all chat history?\n\nThis removes all saved conversations across all books.\n\nThis cannot be undone."),
                            callback = "clearAllChatHistory",
                        },
                    },
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
                    text = _("AI Buttons in Dictionary Popup"),
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
                        elseif lang == "__FOLLOW_PRIMARY__" then
                            return _("Response Language: (Follow Primary)")
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
                        local mode = f.dictionary_context_mode or "none"
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
                    id = "dictionary_disable_auto_save",
                    type = "toggle",
                    text = _("Disable Auto-save for Dictionary"),
                    path = "features.dictionary_disable_auto_save",
                    default = true,
                    help_text = _("When enabled, dictionary lookups are not auto-saved. When disabled, dictionary chats follow your general chat saving settings. You can always save manually from an expanded view."),
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
                {
                    id = "dictionary_bypass_vocab_add",
                    type = "toggle",
                    text = _("Bypass: Follow Vocab Builder Auto-add"),
                    path = "features.dictionary_bypass_vocab_add",
                    default = true,
                    help_text = _("When enabled, dictionary bypass follows KOReader's Vocabulary Builder auto-add setting. Disable if you use bypass for analysis of words you already know and don't want them added."),
                },
            },
        },

        -- Translate Settings
        {
            id = "translate_settings",
            type = "submenu",
            text = _("Translate Settings"),
            items = {
                -- Translation target (moved from Language Settings)
                {
                    id = "translation_use_primary",
                    type = "toggle",
                    text = _("Translate to Primary Language"),
                    path = "features.translation_use_primary",
                    default = true,
                    help_text = _("Use your primary language as the translation target. Disable to choose a different target."),
                    on_change = function(new_value, plugin)
                        local f = plugin.settings:readSetting("features") or {}
                        if new_value then
                            f.translation_language = "__PRIMARY__"
                            plugin.settings:saveSetting("features", f)
                            plugin.settings:flush()
                        end
                    end,
                },
                {
                    id = "translation_language",
                    type = "submenu",
                    text_func = function(plugin)
                        local f = plugin.settings:readSetting("features") or {}
                        local target = f.translation_language
                        if target == "__PRIMARY__" or target == nil or target == "" then
                            local primary = plugin:getEffectivePrimaryLanguage() or "English"
                            target = primary
                        end
                        return T(_("Translation Target: %1"), target)
                    end,
                    callback = "buildTranslationLanguageMenu",
                    depends_on = { id = "translation_use_primary", value = false },
                    separator = true,
                },
                -- Translate view settings
                {
                    id = "translate_disable_auto_save",
                    type = "toggle",
                    text = _("Disable Auto-Save for Translate"),
                    path = "features.translate_disable_auto_save",
                    default = true,
                    help_text = _("Translations are not auto-saved. Save manually via → Chat button."),
                },
                {
                    id = "translate_enable_streaming",
                    type = "toggle",
                    text = _("Enable Streaming"),
                    path = "features.translate_enable_streaming",
                    default = true,
                    help_text = _("Stream translation responses in real-time."),
                },
                {
                    id = "translate_copy_content",
                    type = "dropdown",
                    text = _("Copy Content"),
                    path = "features.translate_copy_content",
                    default = "response",
                    options = {
                        { value = "global", label = _("Follow global setting") },
                        { value = "ask", label = _("Ask every time") },
                        { value = "full", label = _("Full (metadata + chat)") },
                        { value = "qa", label = _("Question + Response") },
                        { value = "response", label = _("Translation only") },
                        { value = "everything", label = _("Everything (debug)") },
                    },
                    help_text = _("What to include when copying in translate view."),
                },
                {
                    id = "translate_note_content",
                    type = "dropdown",
                    text = _("Note Content"),
                    path = "features.translate_note_content",
                    default = "response",
                    options = {
                        { value = "global", label = _("Follow global setting") },
                        { value = "ask", label = _("Ask every time") },
                        { value = "full", label = _("Full (metadata + chat)") },
                        { value = "qa", label = _("Question + Response") },
                        { value = "response", label = _("Translation only") },
                        { value = "everything", label = _("Everything (debug)") },
                    },
                    help_text = _("What to include when saving to note in translate view."),
                    separator = true,
                },
                -- Original text visibility
                {
                    id = "translate_hide_highlight_mode",
                    type = "radio",
                    text_func = function(plugin)
                        local f = plugin.settings:readSetting("features") or {}
                        local mode = f.translate_hide_highlight_mode or "follow_global"
                        local labels = {
                            follow_global = _("Follow Global"),
                            always_hide = _("Always Hide"),
                            hide_long = _("Hide Long"),
                            never_hide = _("Never Hide"),
                        }
                        return T(_("Original Text: %1"), labels[mode] or mode)
                    end,
                    path = "features.translate_hide_highlight_mode",
                    default = "follow_global",
                    options = {
                        { value = "follow_global", text = _("Follow Global (Display Settings)") },
                        { value = "always_hide", text = _("Always Hide") },
                        { value = "hide_long", text = _("Hide Long (by character count)") },
                        { value = "never_hide", text = _("Never Hide") },
                    },
                },
                {
                    id = "translate_long_highlight_threshold",
                    type = "spinner",
                    text = _("Long Text Threshold"),
                    path = "features.translate_long_highlight_threshold",
                    default = 200,
                    min = 50,
                    max = 1000,
                    step = 10,
                    help_text = _("Character count above which text is considered 'long'. Used when Original Text is set to 'Hide Long'."),
                    enabled_func = function(plugin)
                        local f = plugin.settings:readSetting("features") or {}
                        return f.translate_hide_highlight_mode == "hide_long"
                    end,
                },
                {
                    id = "translate_hide_full_page",
                    type = "toggle",
                    text = _("Hide for Full Page Translate"),
                    path = "features.translate_hide_full_page",
                    default = true,
                    help_text = _("Always hide original text when translating full page."),
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
