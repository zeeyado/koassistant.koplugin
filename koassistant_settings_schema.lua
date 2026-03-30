local _ = require("koassistant_gettext")
local T = require("ffi/util").template
local ModelConstraints = require("model_constraints")
local Constants = require("koassistant_constants")

-- Settings Schema Definition
-- This file defines the structure and metadata for all KOAssistant plugin settings
-- Used by SettingsManager to generate menus - SINGLE SOURCE OF TRUTH

-- Helper: Build model list string from capabilities
local function getModelList(provider, capability)
    local caps = ModelConstraints.capabilities[provider]
    if not caps or not caps[capability] then return "" end

    local models = {}
    for _idx, model in ipairs(caps[capability]) do
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
            text = _("Book Chat/Action"),
            emoji = "💬",
            callback = "onKOAssistantBookChat",
            visible_func = function(plugin)
                return plugin.ui and plugin.ui.document ~= nil
            end,
        },
        {
            id = "new_general_chat",
            type = "action",
            text = _("General Chat/Action"),
            emoji = "🗨️",
            callback = "startGeneralChat",
        },
        {
            id = "chat_history",
            type = "action",
            text = _("Chat History"),
            emoji = "📜",
            callback = "showChatHistory",
        },
        {
            id = "browse_notebooks",
            type = "action",
            text = _("Browse Notebooks"),
            emoji = "📓",
            callback = "showNotebookBrowser",
        },
        {
            id = "browse_artifacts",
            type = "action",
            text = _("Browse Artifacts"),
            emoji = "\u{1F4E6}",
            callback = "showArtifactBrowser",
        },
        {
            id = "library_actions",
            type = "action",
            text = _("Library Actions"),
            emoji = "\u{1F4DA}",
            callback = "openLibraryDialog",
            separator = true,
        },

        -- Reading & Library settings (always visible)
        -- Consolidates: chapter quiz, recap reminder, end-of-book, library scanning
        {
            id = "reading_and_library",
            type = "submenu",
            text = _("Reading & Library"),
            emoji = "📖",
            separator = true,
            items = {
                -- Chapter Quiz
                {
                    id = "chapter_quiz_header",
                    type = "header",
                    text = _("Chapter Quiz"),
                },
                {
                    id = "enable_chapter_quiz",
                    type = "toggle",
                    text = _("Quiz on Chapter End"),
                    path = "features.enable_chapter_quiz",
                    default = false,
                    help_text = _("Offer a comprehension quiz when you finish reading a chapter. Requires a book with a table of contents."),
                },
                {
                    id = "quiz_chapter_depth",
                    type = "dropdown",
                    text = _("Chapter Depth"),
                    path = "features.quiz_chapter_depth",
                    default = "toc_filter",
                    options = {
                        { value = "toc_filter", label = _("Follow KOReader TOC") },
                        { value = 1, label = _("Level 1 only") },
                        { value = 2, label = _("Level 1-2") },
                        { value = 3, label = _("Level 1-3") },
                    },
                    help_text = _("Which TOC levels trigger a quiz. 'Follow KOReader TOC' uses your existing TOC filter settings."),
                    depends_on = { id = "enable_chapter_quiz", value = true },
                },
                {
                    id = "quiz_question_count",
                    type = "spinner",
                    text = _("Question Count"),
                    path = "features.quiz_question_count",
                    default = 8,
                    min = 3,
                    max = 15,
                    step = 1,
                    precision = "%d",
                    help_text = _("Total number of questions to generate per quiz."),
                },
                {
                    id = "quiz_difficulty",
                    type = "dropdown",
                    text = _("Difficulty"),
                    path = "features.quiz_difficulty",
                    default = "medium",
                    options = {
                        { value = "easy", label = _("Easy") },
                        { value = "medium", label = _("Medium") },
                        { value = "hard", label = _("Hard") },
                    },
                    help_text = _("Easy: straightforward recall. Medium: comprehension and application. Hard: analysis and synthesis."),
                },
                {
                    id = "quiz_mc_enabled",
                    type = "toggle",
                    text = _("Include Multiple Choice"),
                    path = "features.quiz_mc_enabled",
                    default = true,
                },
                {
                    id = "quiz_short_answer_enabled",
                    type = "toggle",
                    text = _("Include Short Answer"),
                    path = "features.quiz_short_answer_enabled",
                    default = true,
                },
                {
                    id = "quiz_essay_enabled",
                    type = "toggle",
                    text = _("Include Essay / Discussion"),
                    path = "features.quiz_essay_enabled",
                    default = true,
                    separator = true,
                },
                -- Recap Reminder (moved from KOReader Integration)
                {
                    id = "recap_reminder_header",
                    type = "header",
                    text = _("Recap Reminder"),
                },
                {
                    id = "enable_recap_reminder",
                    type = "toggle",
                    text = _("Remind to Recap on Book Open"),
                    path = "features.enable_recap_reminder",
                    default = false,
                    help_text = _("Show a reminder to run Recap when you open a book you haven't read in a while."),
                },
                {
                    id = "recap_reminder_days",
                    type = "spinner",
                    text = _("Days Before Reminder"),
                    path = "features.recap_reminder_days",
                    default = 7,
                    min = 1,
                    max = 90,
                    step = 1,
                    precision = "%d",
                    help_text = _("Number of days since last reading before the reminder appears."),
                    depends_on = { id = "enable_recap_reminder", value = true },
                    separator = true,
                },
                -- End of Book (moved from KOReader Integration)
                {
                    id = "end_of_book_header",
                    type = "header",
                    text = _("End of Book"),
                },
                {
                    id = "enable_end_of_book_suggestion",
                    type = "toggle",
                    text = _("Suggest Next Read on Finish"),
                    path = "features.enable_end_of_book_suggestion",
                    default = true,
                    help_text = _("When you reach the end of a book, offer to suggest what to read next from your library. Requires library scanning to be enabled with at least one folder configured."),
                    separator = true,
                },
                -- Library (moved from Library Settings)
                {
                    id = "library_header",
                    type = "header",
                    text = _("Library"),
                },
                {
                    id = "enable_library_scanning_reading",
                    type = "toggle",
                    text = _("Allow Library Scanning"),
                    path = "features.enable_library_scanning",
                    default = false,
                    help_text = _("Enables library actions that analyze your book collection. Add permanent scan folders below, or pick folders on the fly in the input dialog."),
                    on_change = function(new_value)
                        if new_value then
                            local InfoMessage = require("ui/widget/infomessage")
                            local UIManager = require("ui/uimanager")
                            UIManager:show(InfoMessage:new{
                                text = _("Enables library actions that analyze your book collection.\n\nAdd permanent scan folders below, or pick folders on the fly in the input dialog."),
                            })
                        end
                    end,
                },
                {
                    id = "library_scan_folders_reading",
                    type = "submenu",
                    text_func = function(plugin)
                        local f = plugin.settings:readSetting("features") or {}
                        local folders = f.library_scan_folders or {}
                        if #folders == 0 then
                            return _("Permanent Scan Folders: None")
                        else
                            return T(_("Permanent Scan Folders: %1"), #folders)
                        end
                    end,
                    depends_on = { id = "enable_library_scanning_reading", value = true },
                    help_text = _("Folders always scanned for library actions. You can also pick folders on the fly in the input dialog."),
                    callback = "getLibraryFoldersMenuItems",
                },
            },
        },

        -- Provider, Model, Temperature (top-level)
        {
            id = "provider",
            type = "submenu",
            emoji = "🔗",
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
            emoji = "🤖",
            text_func = function(plugin)
                return T(_("Model: %1"), plugin:getCurrentModel())
            end,
            callback = "buildModelMenu",
        },
        {
            id = "api_keys",
            type = "submenu",
            text = _("API Keys"),
            emoji = "🔑",
            callback = "buildApiKeysMenu",
        },
        {
            id = "temperature",
            type = "spinner",
            text = _("Temperature"),
            emoji = "🌡️",
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
            emoji = "🎨",
            items = {
                {
                    id = "rendering_settings",
                    type = "submenu",
                    text = _("Rendering"),
                    items = {
                        {
                            id = "render_markdown",
                            type = "dropdown",
                            text = _("View Mode"),
                            path = "features.render_markdown",
                            default = true,
                            options = {
                                { value = true, label = _("Markdown") },
                                { value = false, label = _("Plain Text") },
                            },
                            help_text = _("Markdown renders formatting. Plain Text has better font support for Arabic/CJK."),
                        },
                        {
                            id = "plain_text_options",
                            type = "submenu",
                            text = _("Plain Text Options"),
                            separator = true,
                            items = {
                                {
                                    id = "strip_markdown_in_text_mode",
                                    type = "toggle",
                                    text = _("Apply Markdown Stripping"),
                                    path = "features.strip_markdown_in_text_mode",
                                    default = true,
                                    help_text = _("Convert markdown syntax to readable plain text (headers, lists, etc). Disable to show raw markdown."),
                                },
                            },
                        },
                        {
                            id = "dictionary_text_mode",
                            type = "toggle",
                            text = _("Text Mode for Dictionary"),
                            path = "features.dictionary_text_mode",
                            default = false,
                            help_text = _("Use Plain Text mode for dictionary popup. Better font support for non-Latin scripts."),
                        },
                        {
                            id = "rtl_dictionary_text_mode",
                            type = "toggle",
                            text = _("Text Mode for RTL Dictionary"),
                            path = "features.rtl_dictionary_text_mode",
                            default = true,
                            enabled_func = function(plugin)
                                local f = plugin.settings:readSetting("features") or {}
                                return not f.dictionary_text_mode
                            end,
                            help_text = _("Use Plain Text mode for dictionary popup when dictionary language is Arabic, Persian, or Urdu. Grayed out when Text Mode for Dictionary is enabled."),
                        },
                        {
                            id = "rtl_translate_text_mode",
                            type = "toggle",
                            text = _("Text Mode for RTL Translate"),
                            path = "features.rtl_translate_text_mode",
                            default = true,
                            help_text = _("Use Plain Text mode for translate popup when translation language is Arabic, Persian, or Urdu."),
                        },
                        {
                            id = "rtl_chat_text_mode",
                            type = "toggle",
                            text = _("Auto RTL mode for Chat"),
                            path = "features.rtl_chat_text_mode",
                            default = true,
                            enabled_func = function(plugin)
                                local f = plugin.settings:readSetting("features") or {}
                                return f.render_markdown ~= false
                            end,
                            help_text = _("Automatically detect RTL content and switch to RTL mode (right-aligned text + Plain Text). Activates when the latest response has more RTL than Latin characters. Disabling removes all automatic RTL adjustments. Grayed out when markdown is disabled."),
                        },
                    },
                },
                {
                    id = "emoji_settings",
                    type = "submenu",
                    text = _("Emoji"),
                    items = {
                        {
                            id = "enable_emoji_icons",
                            type = "toggle",
                            text = _("Emoji Menu Icons"),
                            path = "features.enable_emoji_icons",
                            default = false,
                            help_text = _("Show emoji icons (🔍, 📖) in UI buttons and status indicators. Requires emoji font support in KOReader. Does not work on all devices. If icons appear as question marks, disable this option."),
                        },
                        {
                            id = "enable_emoji_panel_icons",
                            type = "toggle",
                            text = _("Emoji Panel Icons"),
                            path = "features.enable_emoji_panel_icons",
                            default = false,
                            help_text = _("Show emoji icons on Quick Settings and Quick Actions panel buttons (🔗 Provider, 🎭 Behavior, 📜 Chat History, etc.). Requires emoji font support."),
                        },
                        {
                            id = "enable_data_access_indicators",
                            type = "toggle",
                            text = _("Emoji Data Access Indicators"),
                            path = "features.enable_data_access_indicators",
                            default = false,
                            help_text = _("Show emoji indicators on action names showing what data they access: 📄 document text, 🔖 highlights, 📝 annotations, 📓 notebook, 📚 library, 🌐 web search. Requires emoji font support."),
                        },
                    },
                },
                {
                    id = "panel_alignment_settings",
                    type = "submenu",
                    text = _("Panel Alignment"),
                    items = {
                        {
                            id = "qs_left_align",
                            type = "toggle",
                            text = _("Align Quick Settings"),
                            path = "features.qs_left_align",
                            default = true,
                            help_text = _("Left-align button text in the Quick Settings panel instead of centering. Also available from the panel's gear menu."),
                        },
                        {
                            id = "qa_left_align",
                            type = "toggle",
                            text = _("Align Quick Actions"),
                            path = "features.qa_left_align",
                            default = true,
                            help_text = _("Left-align button text in the Quick Actions panel instead of centering. Also available from the panel's gear menu."),
                        },
                    },
                },
                {
                    id = "highlight_display_settings",
                    type = "submenu",
                    text = _("Highlights"),
                    items = {
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
                {
                    id = "plugin_ui_language",
                    type = "dropdown",
                    text = _("Plugin UI Language"),
                    path = "features.ui_language",
                    default = "auto",
                    help_text = _("Language for plugin menus and dialogs. Does not affect AI responses. Requires restart."),
                    options = {
                        { value = "auto", label = _("Match KOReader") },
                        { value = "en", label = "English" },
                        { value = "ar", label = "العربية (Arabic)" },
                        { value = "cs", label = "Čeština (Czech)" },
                        { value = "de", label = "Deutsch (German)" },
                        { value = "es", label = "Español (Spanish)" },
                        { value = "fr", label = "Français (French)" },
                        { value = "hi", label = "हिन्दी (Hindi)" },
                        { value = "id", label = "Bahasa Indonesia" },
                        { value = "it", label = "Italiano (Italian)" },
                        { value = "ja", label = "日本語 (Japanese)" },
                        { value = "ko_KR", label = "한국어 (Korean)" },
                        { value = "nl_NL", label = "Nederlands (Dutch)" },
                        { value = "pl", label = "Polski (Polish)" },
                        { value = "pt", label = "Português (Portuguese)" },
                        { value = "pt_BR", label = "Português do Brasil" },
                        { value = "ru", label = "Русский (Russian)" },
                        { value = "th", label = "ไทย (Thai)" },
                        { value = "tr", label = "Türkçe (Turkish)" },
                        { value = "uk", label = "Українська (Ukrainian)" },
                        { value = "vi", label = "Tiếng Việt (Vietnamese)" },
                        { value = "zh", label = "中文 (Chinese)" },
                    },
                    on_change = function()
                        local InfoMessage = require("ui/widget/infomessage")
                        local UIManager = require("ui/uimanager")
                        UIManager:show(InfoMessage:new{
                            text = _("Please restart KOReader for the language change to take effect."),
                        })
                    end,
                },
            },
        },

        -- Chat & Export submenu
        {
            id = "chat_settings",
            type = "submenu",
            text = _("Chat & Export Settings"),
            emoji = "💬",
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
                -- Streaming sub-menu
                {
                    id = "streaming_settings",
                    type = "submenu",
                    text = _("Streaming"),
                    items = {
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
                            id = "stream_page_scroll",
                            type = "toggle",
                            text = _("Page-based Scroll (e-ink)"),
                            path = "features.stream_page_scroll",
                            default = true,
                            depends_on = {
                                { id = "enable_streaming", value = true },
                                { id = "stream_auto_scroll", value = true },
                            },
                            help_text = _("Stream text into empty page space instead of scrolling from the bottom. Reduces full-screen refreshes on e-ink. Disable for continuous bottom-scrolling."),
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
                {
                    id = "scroll_to_last_message",
                    type = "toggle",
                    text = _("Scroll to Last Message (Experimental)"),
                    path = "features.scroll_to_last_message",
                    default = false,
                    help_text = _("When resuming or replying to a chat, try to scroll so your last question is visible. When off, shows top for new chats and bottom for replies."),
                },
                {
                    id = "spoiler_free_chat",
                    type = "toggle",
                    text = _("Spoiler-free Chat"),
                    path = "features.spoiler_free_chat",
                    default = false,
                    help_text = _("When enabled, instructs the AI not to reveal events beyond your current reading position in book and highlight chats. Custom actions can use the {spoiler_free_nudge} placeholder."),
                },
                {
                    id = "show_spoiler_toggle",
                    type = "toggle",
                    text = _("Show Spoiler-free Chat Checkbox"),
                    path = "features.show_spoiler_toggle",
                    default = false,
                    help_text = _("Show a session checkbox in the book/highlight input dialog to toggle spoiler-free chat on the fly. When the global setting above is on, the checkbox starts checked but can be unchecked per session."),
                    separator = true,
                },
                -- Content Format submenu
                {
                    id = "content_format",
                    type = "submenu",
                    text = _("Content Format"),
                    items = {
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
                                { value = "response", label = _("Last response only") },
                                { value = "everything", label = _("Everything (debug)") },
                            },
                            help_text = _("What to include when copying chat to clipboard."),
                        },
                        {
                            id = "note_content",
                            type = "dropdown",
                            text = _("Note Content"),
                            path = "features.note_content",
                            default = "qa",
                            options = {
                                { value = "ask", label = _("Ask every time") },
                                { value = "full", label = _("Full (metadata + chat)") },
                                { value = "qa", label = _("Question + Response") },
                                { value = "response", label = _("Last response only") },
                                { value = "everything", label = _("Everything (debug)") },
                            },
                            help_text = _("What to include when saving to note."),
                        },
                        {
                            id = "export_content",
                            type = "dropdown",
                            text = _("Save to File Content"),
                            path = "features.export_content",
                            default = "global",
                            options = {
                                { value = "global", label = _("Follow Copy Content") },
                                { value = "ask", label = _("Ask every time") },
                                { value = "full", label = _("Full (metadata + chat)") },
                                { value = "qa", label = _("Question + Response") },
                                { value = "response", label = _("Last response only") },
                                { value = "everything", label = _("Everything (debug)") },
                            },
                            help_text = _("What to include when saving chat to file. 'Follow Copy Content' uses your Copy Content setting."),
                        },
                        {
                            id = "history_copy_content",
                            type = "dropdown",
                            text = _("Chat History Export"),
                            path = "features.history_copy_content",
                            default = "ask",
                            options = {
                                { value = "global", label = _("Follow Copy Content") },
                                { value = "ask", label = _("Ask every time") },
                                { value = "full", label = _("Full (metadata + chat)") },
                                { value = "qa", label = _("Question + Response") },
                                { value = "response", label = _("Last response only") },
                                { value = "everything", label = _("Everything (debug)") },
                            },
                            help_text = _("What to include when exporting from Chat History."),
                        },
                    },
                },
                -- Save Location
                {
                    id = "export_save_directory",
                    type = "dropdown",
                    text = _("Save Location"),
                    path = "features.export_save_directory",
                    default = "exports_folder",
                    options = {
                        { value = "exports_folder", label = _("KOAssistant exports folder") },
                        { value = "custom", label = _("Custom folder") },
                        { value = "ask", label = _("Ask every time") },
                    },
                    help_text = function(plugin)
                        local DataStorage = require("datastorage")
                        local default_path = DataStorage:getDataDir() .. "/koassistant_exports"
                        local f = plugin.settings:readSetting("features") or {}
                        local custom = f.export_custom_path
                        if custom and custom ~= "" then
                            return T(_("Where to save exported chat files. Creates subfolders for book/general/multi-book chats.\n\nDefault folder:\n%1\n\nCustom folder:\n%2"), default_path, custom)
                        end
                        return T(_("Where to save exported chat files. Creates subfolders for book/general/multi-book chats.\n\nDefault folder:\n%1"), default_path)
                    end,
                    on_change = function(new_value, plugin, old_value)
                        if new_value == "custom" then
                            -- Re-selecting custom when already on custom: just reopen picker (no revert needed)
                            if old_value == "custom" then
                                plugin:showExportPathPicker()
                            else
                                plugin:showExportPathPicker(true)  -- revert_on_cancel
                            end
                        end
                    end,
                },
                {
                    id = "export_book_to_book_folder",
                    type = "toggle",
                    text = _("Save book chats alongside books"),
                    path = "features.export_book_to_book_folder",
                    default = false,
                    help_text = _("When enabled, book chats are saved to a 'chats' subfolder next to the book file instead of the central location."),
                },
            },
        },

        -- AI Language Settings submenu
        {
            id = "ai_language_settings",
            type = "submenu",
            text = _("AI Language Settings"),
            emoji = "🌐",
            items = {
                {
                    id = "interaction_languages",
                    type = "submenu",
                    text_func = function(plugin)
                        local f = plugin.settings:readSetting("features") or {}
                        local langs = f.interaction_languages or {}
                        if #langs == 0 then
                            -- Fall back to old format for display
                            local old = f.user_languages or ""
                            if old == "" then
                                -- Show auto-detected language if available
                                local Languages = require("koassistant_languages")
                                local detected = Languages.detectFromKOReader()
                                if detected then
                                    return T(_("Your Languages: %1 (auto)"), Languages.getDisplay(detected))
                                end
                                return _("Your Languages: (not set)")
                            end
                            return T(_("Your Languages: %1"), old)
                        end
                        -- Convert to native script display
                        local display_langs = {}
                        for _i, lang in ipairs(langs) do
                            table.insert(display_langs, plugin:getLanguageDisplay(lang))
                        end
                        return T(_("Your Languages: %1"), table.concat(display_langs, ", "))
                    end,
                    callback = "buildInteractionLanguagesSubmenu",
                },
                {
                    id = "primary_language",
                    type = "submenu",
                    text_func = function(plugin)
                        local primary = plugin:getEffectivePrimaryLanguage()
                        if not primary or primary == "" then
                            return _("Primary Language: (not set)")
                        end
                        return T(_("Primary Language: %1"), plugin:getLanguageDisplay(primary))
                    end,
                    callback = "buildPrimaryLanguageMenu",
                },
                {
                    id = "additional_languages",
                    type = "submenu",
                    text_func = function(plugin)
                        local f = plugin.settings:readSetting("features") or {}
                        local langs = f.additional_languages or {}
                        if #langs == 0 then
                            return _("Additional Languages: (none)")
                        end
                        -- Convert to native script display
                        local display_langs = {}
                        for _i, lang in ipairs(langs) do
                            table.insert(display_langs, plugin:getLanguageDisplay(lang))
                        end
                        return T(_("Additional Languages: %1"), table.concat(display_langs, ", "))
                    end,
                    callback = "buildAdditionalLanguagesSubmenu",
                },
            },
        },

        -- Dictionary Settings
        {
            id = "dictionary_settings",
            type = "submenu",
            text = _("Dictionary Settings"),
            emoji = "📖",
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
                        return T(_("Response Language: %1"), plugin:getLanguageDisplay(lang))
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
                    id = "dictionary_copy_content",
                    type = "dropdown",
                    text = _("Copy Content"),
                    path = "features.dictionary_copy_content",
                    default = "response",
                    options = {
                        { value = "global", label = _("Follow global setting") },
                        { value = "ask", label = _("Ask every time") },
                        { value = "full", label = _("Full (metadata + chat)") },
                        { value = "qa", label = _("Question + Response") },
                        { value = "response", label = _("Definition only (Recommended)") },
                        { value = "everything", label = _("Everything (debug)") },
                    },
                    help_text = _("What to include when copying in dictionary view."),
                },
                {
                    id = "dictionary_note_content",
                    type = "dropdown",
                    text = _("Note Content"),
                    path = "features.dictionary_note_content",
                    default = "response",
                    options = {
                        { value = "global", label = _("Follow global setting") },
                        { value = "ask", label = _("Ask every time") },
                        { value = "full", label = _("Full (metadata + chat)") },
                        { value = "qa", label = _("Question + Response") },
                        { value = "response", label = _("Definition only (Recommended)") },
                        { value = "everything", label = _("Everything (debug)") },
                    },
                    help_text = _("What to include when saving dictionary results to a note."),
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
            emoji = "🌍",
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
                        return T(_("Translation Target: %1"), plugin:getLanguageDisplay(target))
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
                        -- Default matches schema default (hide_long)
                        local mode = f.translate_hide_highlight_mode or "hide_long"
                        local labels = {
                            follow_global = _("Follow Global"),
                            always_hide = _("Always Hide"),
                            hide_long = _("Hide Long"),
                            never_hide = _("Never Hide"),
                        }
                        return T(_("Original Text: %1"), labels[mode] or mode)
                    end,
                    path = "features.translate_hide_highlight_mode",
                    default = "hide_long",
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
                    default = 280,
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
                    help_text = _("Always hide original text for full page translations. Overrides all other visibility settings when enabled. Disable to use your normal Original Text setting above."),
                },
            },
        },

        -- Highlight Settings
        {
            id = "highlight_settings",
            type = "submenu",
            text = _("Highlight Settings"),
            emoji = "✏️",
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

        -- Actions & Prompts submenu
        {
            id = "actions_and_prompts",
            type = "submenu",
            text = _("Actions & Prompts"),
            emoji = "🔧",
            items = {
                {
                    id = "manage_actions",
                    type = "action",
                    text = _("Manage Actions"),
                    callback = "showPromptsManager",
                },
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
                },
            },
        },

        -- Notebook Settings submenu
        {
            id = "notebooks",
            type = "submenu",
            text = _("Notebook Settings"),
            emoji = "📓",
            items = {
                {
                    id = "browse_notebooks",
                    type = "action",
                    text = _("Browse Notebooks..."),
                    callback = "showNotebookBrowser",
                    separator = true,
                },
                {
                    id = "notebook_content_format",
                    type = "dropdown",
                    text = _("Content Format"),
                    path = "features.notebook_content_format",
                    default = "full_qa",
                    options = {
                        { value = "response", label = _("Response only") },
                        { value = "qa", label = _("Q&A") },
                        { value = "full_qa", label = _("Full Q&A (recommended)") },
                    },
                    help_text = _("What to include when saving to notebook.\nFull Q&A includes all context messages + highlighted text + question + response."),
                },
                {
                    id = "notebook_viewer",
                    type = "dropdown",
                    text = _("Viewer Mode"),
                    path = "features.notebook_viewer",
                    default = "chatviewer",
                    options = {
                        { value = "chatviewer", label = _("Chat Viewer") },
                        { value = "reader", label = _("KOReader") },
                    },
                    help_text = _("Chat Viewer shows notebook with editing and export buttons. KOReader opens as a full document with navigation."),
                    separator = true,
                },
                -- Save Location
                {
                    id = "notebook_save_location_dropdown",
                    type = "dropdown",
                    text = _("Save Location"),
                    path = "features.notebook_save_location",
                    default = "sidecar",
                    options = {
                        { value = "sidecar", label = _("Alongside book") },
                        { value = "central", label = _("KOAssistant notebooks folder") },
                        { value = "custom", label = _("Custom folder") },
                    },
                    help_text = function(plugin)
                        local DataStorage = require("datastorage")
                        local central = DataStorage:getDataDir() .. "/koassistant_notebooks"
                        local f = plugin.settings:readSetting("features") or {}
                        local custom = f.notebook_custom_path
                        if custom and custom ~= "" then
                            return T(_("Where to save notebook files.\n\nAlongside book: in the book's sidecar directory (current default).\n\nKOAssistant notebooks folder:\n%1\n\nCustom folder:\n%2"), central, custom)
                        end
                        return T(_("Where to save notebook files.\n\nAlongside book: in the book's sidecar directory (current default).\n\nKOAssistant notebooks folder:\n%1\n\nCustom folder: choose your own location (e.g. an Obsidian vault)."), central)
                    end,
                    on_change = function(new_value, plugin, old_value)
                        -- Re-selecting custom when already on custom: just reopen picker (no migration)
                        if new_value == "custom" and old_value == "custom" then
                            plugin:showNotebookPathPicker()  -- no revert_to = picker only
                            return
                        end
                        if new_value == old_value then return end
                        -- Revert immediately — setting only commits after migration
                        local features = plugin.settings:readSetting("features") or {}
                        features.notebook_save_location = old_value or "sidecar"
                        plugin.settings:saveSetting("features", features)
                        plugin:updateConfigFromSettings()

                        if new_value == "custom" then
                            -- Pick folder first, then migration is offered on confirm
                            plugin:showNotebookPathPicker(old_value or "sidecar")
                        else
                            -- Direct switch — offer migration
                            plugin:offerNotebookMigration(old_value or "sidecar", new_value)
                        end
                    end,
                    separator = true,
                },
                {
                    id = "show_notebook_in_file_browser",
                    type = "toggle",
                    text = _("Show in file browser menu"),
                    path = "features.show_notebook_in_file_browser",
                    default = true,
                    help_text = _("Show 'Notebook' button when long-pressing books in the file browser."),
                },
                {
                    id = "notebook_button_require_existing",
                    type = "toggle",
                    text = _("Only for books with notebooks"),
                    path = "features.notebook_button_require_existing",
                    default = true,
                    depends_on = { id = "show_notebook_in_file_browser", value = true },
                    help_text = _("Only show button if notebook already exists. Disable to allow creating new notebooks from file browser."),
                },
            },
        },

        -- (Library Settings moved to Reading & Library section above)

        -- Privacy & Data submenu
        {
            id = "privacy_data",
            type = "submenu",
            text = _("Privacy & Data"),
            emoji = "🔒",
            items = {
                -- Trusted Providers
                {
                    id = "trusted_providers",
                    type = "action",
                    text_func = function(plugin)
                        local f = plugin.settings:readSetting("features") or {}
                        local trusted = f.trusted_providers or {}
                        if #trusted == 0 then
                            return _("Trusted Providers: None")
                        else
                            return T(_("Trusted Providers: %1"), table.concat(trusted, ", "))
                        end
                    end,
                    help_text = _("Providers you trust bypass all data sharing controls below AND text extraction. All data types (highlights, annotations, notebook, book text) are available without toggling individual settings. Use for local Ollama instances or providers you fully trust."),
                    callback = "showTrustedProvidersDialog",
                    separator = true,
                },
                -- Quick Presets
                {
                    id = "privacy_preset_default",
                    type = "action",
                    text = _("Preset: Default"),
                    help_text = _("Recommended balance. Share reading progress and chapter info for context-aware features. Personal content (highlights, annotations, notebook) stays private."),
                    callback = "applyPrivacyPresetDefault",
                    keep_menu_open = true,
                },
                {
                    id = "privacy_preset_minimal",
                    type = "action",
                    text = _("Preset: Minimal"),
                    help_text = _("Maximum privacy. Disable all extended data sharing including progress and chapter info. Only your question and book metadata are sent."),
                    callback = "applyPrivacyPresetMinimal",
                    keep_menu_open = true,
                },
                {
                    id = "privacy_preset_full",
                    type = "action",
                    text = _("Preset: Full"),
                    help_text = _("Enable all data sharing for full functionality. Does not enable text extraction (see Text Extraction submenu)."),
                    callback = "applyPrivacyPresetFull",
                    keep_menu_open = true,
                    separator = true,
                },
                -- Individual toggles
                {
                    id = "enable_annotations_sharing",
                    type = "toggle",
                    text = _("Allow Annotation Notes"),
                    path = "features.enable_annotations_sharing",
                    default = false,
                    help_text = _("Share your personal notes attached to highlights with the AI. Automatically enables highlight sharing. Used by Analyze Notes, Connect with Notes, and actions with {annotations} placeholders."),
                    on_change = function(new_value, plugin)
                        if new_value then
                            -- Auto-enable highlights (annotations implies highlights)
                            local f = plugin.settings:readSetting("features") or {}
                            f.enable_highlights_sharing = true
                            plugin.settings:saveSetting("features", f)
                            plugin.settings:flush()
                            plugin:updateConfigFromSettings()
                        end
                    end,
                    refresh_menu = true,
                },
                {
                    id = "enable_highlights_sharing",
                    type = "toggle",
                    text = _("Allow Highlights"),
                    path = "features.enable_highlights_sharing",
                    default = false,
                    help_text = _("Share your highlighted text passages with the AI. Used by X-Ray, Recap, and actions with {highlights} placeholders. Does not include personal notes."),
                    enabled_func = function(plugin)
                        -- Grayed out when annotations is enabled (annotations implies highlights)
                        local f = plugin.settings:readSetting("features") or {}
                        return f.enable_annotations_sharing ~= true
                    end,
                },
                {
                    id = "enable_notebook_sharing",
                    type = "toggle",
                    text = _("Allow Notebook"),
                    path = "features.enable_notebook_sharing",
                    default = false,
                    help_text = _("Send notebook entries to AI. Used by Connect with Notes and actions with {notebook} placeholder."),
                },
                {
                    id = "enable_basic_stats",
                    type = "toggle",
                    text = _("Allow Basic Stats"),
                    path = "features.enable_basic_stats",
                    default = true,
                    help_text = _("Send reading progress (percentage), current chapter title, chapters read count, and time since last opened. Used by X-Ray, Recap."),
                },
                {
                    id = "enable_library_scanning",
                    type = "toggle",
                    text = _("Allow Library Scanning"),
                    path = "features.enable_library_scanning",
                    default = false,
                    help_text = _("Enables library actions that analyze your book collection. Configure permanent scan folders in Library Settings, or pick folders on the fly in the input dialog."),
                    on_change = function(new_value)
                        if new_value then
                            local InfoMessage = require("ui/widget/infomessage")
                            local UIManager = require("ui/uimanager")
                            UIManager:show(InfoMessage:new{
                                text = _("Enables library actions that analyze your book collection.\n\nConfigure permanent scan folders in Library Settings, or pick folders on the fly in the input dialog."),
                            })
                        end
                    end,
                },
                {
                    id = "enable_advanced_stats",
                    type = "toggle",
                    text = _("Allow Advanced Stats"),
                    path = "features.enable_advanced_stats",
                    default = false,
                    help_text = _("Share reading engagement data with AI. Includes curated groups based on reading time and completion patterns (e.g. books read extensively, stalled reads, briefly started)."),
                    separator = true,
                },
                -- Text Extraction settings (moved from Advanced)
                {
                    id = "text_extraction",
                    type = "submenu",
                    text_func = function(plugin)
                        local f = plugin.settings:readSetting("features") or {}
                        if f.enable_book_text_extraction then
                            return _("Text Extraction (enabled)")
                        else
                            return _("Text Extraction (disabled)")
                        end
                    end,
                    items = {
                        {
                            id = "enable_book_text_extraction",
                            type = "toggle",
                            text = _("Allow Text Extraction"),
                            path = "features.enable_book_text_extraction",
                            default = false,
                            help_text = _("When enabled, actions can extract and send book text to the AI. Used by X-Ray, Recap, and actions with text placeholders.\n\nTip: Use Hidden Flows to exclude front matter, appendices, etc. You can also focus actions on a specific section to extract only a chapter or part."),
                            on_change = function(new_value, plugin)
                                if new_value then
                                    -- Unlock QS panel toggle after first manual enable
                                    local f = plugin.settings:readSetting("features") or {}
                                    if not f._text_extraction_acknowledged then
                                        f._text_extraction_acknowledged = true
                                        plugin.settings:saveSetting("features", f)
                                        plugin.settings:flush()
                                    end
                                    local InfoMessage = require("ui/widget/infomessage")
                                    local UIManager = require("ui/uimanager")
                                    UIManager:show(InfoMessage:new{
                                        text = _("Text extraction sends actual book content to the AI. This uses tokens (increases API costs) and processing time. Features like X-Ray and Recap use this to analyze your reading progress.\n\nTip: Use Hidden Flows to exclude front matter, appendices, etc. You can also focus actions on a specific section to extract only a chapter or part."),
                                    })
                                end
                            end,
                        },
                        {
                            id = "max_book_text_chars",
                            type = "spinner",
                            text = _("Max Text Characters"),
                            path = "features.max_book_text_chars",
                            default = Constants.EXTRACTION_DEFAULTS.MAX_BOOK_TEXT_CHARS,
                            min = 100000,
                            max = 10000000,
                            step = 100000,
                            precision = "%d",
                            help_text = _("Maximum characters to extract (100,000-10,000,000). Higher = more context but more tokens. Default: 4,000,000 (~1M tokens). The API will reject requests that exceed the model's context window.\n\nTip: Use Hidden Flows to exclude irrelevant content, or focus on a specific section instead of the full document."),
                            depends_on = { id = "enable_book_text_extraction", value = true },
                        },
                        {
                            id = "max_pdf_pages",
                            type = "spinner",
                            text = _("Max Pages (PDF, DJVU, CBZ…)"),
                            path = "features.max_pdf_pages",
                            default = Constants.EXTRACTION_DEFAULTS.MAX_PDF_PAGES,
                            min = 100,
                            max = 5000,
                            step = 100,
                            precision = "%d",
                            help_text = _("Maximum pages to extract from page-based formats like PDF, DJVU, and CBZ (100-5,000). Higher = more context but slower. Default: 2,000.\n\nTip: Use Hidden Flows to exclude irrelevant pages, or focus on a specific section instead of the full document."),
                            depends_on = { id = "enable_book_text_extraction", value = true },
                        },
                        {
                            id = "suppress_truncation_warning",
                            type = "toggle",
                            text = _("Don't warn about truncated extractions"),
                            path = "features.suppress_truncation_warning",
                            default = false,
                            help_text = _("When unchecked, a blocking warning is shown before sending requests when extracted text was truncated to fit the character limit. Shows coverage percentage so you know how much of the book was included.\n\nCheck this if you don't need the reminder."),
                            depends_on = { id = "enable_book_text_extraction", value = true },
                        },
                        {
                            id = "suppress_large_extraction_warning",
                            type = "toggle",
                            text = _("Don't warn about large extractions"),
                            path = "features.suppress_large_extraction_warning",
                            default = false,
                            help_text = _("When unchecked, a warning is shown before sending requests with large text extractions (over 500K characters / ~125K tokens). Most models have smaller context windows and will reject oversized requests.\n\nCheck this if you know your model's limits and don't need the reminder."),
                            depends_on = { id = "enable_book_text_extraction", value = true },
                        },
                        {
                            id = "clear_action_cache",
                            type = "action",
                            text = _("Clear Action Cache"),
                            help_text = _("Clear cached X-Ray and Recap responses for the current book. Use to regenerate from scratch."),
                            callback = "clearActionCache",
                            depends_on = { id = "enable_book_text_extraction", value = true },
                        },
                    },
                },
            },
        },

        -- KOReader Integration submenu
        {
            id = "koreader_integration",
            type = "submenu",
            text = _("KOReader Integration"),
            emoji = "🔌",
            items = {
                {
                    id = "integration_info",
                    type = "header",
                    text = _("Control where KOAssistant appears in KOReader"),
                },
                {
                    id = "show_in_file_browser",
                    type = "toggle",
                    text = _("Show in File Browser"),
                    path = "features.show_in_file_browser",
                    default = true,
                    help_text = _("Add KOAssistant buttons to file browser context menus. Requires restart."),
                    on_change = function()
                        local InfoMessage = require("ui/widget/infomessage")
                        local UIManager = require("ui/uimanager")
                        UIManager:show(InfoMessage:new{
                            text = _("Please restart KOReader for this change to take effect."),
                        })
                    end,
                },
                {
                    id = "show_koassistant_in_highlight",
                    type = "toggle",
                    text = _("Show in Highlight Menu"),
                    path = "features.show_koassistant_in_highlight",
                    default = true,
                    help_text = _("Add main 'Chat/Action' button to highlight menu. Requires restart."),
                    on_change = function()
                        local InfoMessage = require("ui/widget/infomessage")
                        local UIManager = require("ui/uimanager")
                        UIManager:show(InfoMessage:new{
                            text = _("Please restart KOReader for this change to take effect."),
                        })
                    end,
                },
                {
                    id = "show_quick_actions_in_highlight",
                    type = "toggle",
                    text = _("Show Highlight Quick Actions"),
                    path = "features.show_quick_actions_in_highlight",
                    default = true,
                    help_text = _("Add action shortcuts (Explain, Translate, etc.) to highlight menu. Requires restart."),
                    on_change = function()
                        local InfoMessage = require("ui/widget/infomessage")
                        local UIManager = require("ui/uimanager")
                        UIManager:show(InfoMessage:new{
                            text = _("Please restart KOReader for this change to take effect."),
                        })
                    end,
                },
                {
                    id = "show_in_dictionary_popup",
                    type = "toggle",
                    text = _("Show in Dictionary Popup"),
                    path = "features.enable_dictionary_hook",
                    default = true,
                    help_text = _("Add AI buttons to KOReader's dictionary popup."),
                },
                {
                    id = "enhance_text_selection",
                    type = "toggle",
                    text = _("Enhance Text Selection"),
                    path = "features.enhance_text_selection",
                    default = false,
                    help_text = _("Add dictionary lookup and action popup to text selection in KOReader viewers (Dictionary, TextViewer, etc.). Single word → dictionary, long press single word or multi-word → popup with Copy, Dictionary, Translate. Requires restart."),
                    on_change = function()
                        local InfoMessage = require("ui/widget/infomessage")
                        local UIManager = require("ui/uimanager")
                        UIManager:show(InfoMessage:new{
                            text = _("Please restart KOReader for this change to take effect."),
                        })
                    end,
                },
                {
                    id = "show_in_gesture_menu",
                    type = "toggle",
                    text = _("Show in Gesture Menu"),
                    path = "features.show_in_gesture_menu",
                    default = true,
                    help_text = _("Register KOAssistant actions in KOReader's gesture dispatcher. Requires restart."),
                    on_change = function()
                        local InfoMessage = require("ui/widget/infomessage")
                        local UIManager = require("ui/uimanager")
                        UIManager:show(InfoMessage:new{
                            text = _("Please restart KOReader for this change to take effect."),
                        })
                    end,
                },
                -- (Recap Reminder and End of Book moved to Reading & Library section)
            },
        },

        -- Backup & Reset submenu
        {
            id = "backup_and_reset",
            type = "submenu",
            text = _("Backup & Reset"),
            emoji = "💾",
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
                    separator = true,
                },
                -- Maintenance
                {
                    id = "validate_indexes",
                    type = "action",
                    text = _("Validate Data Indexes"),
                    help_text = _("Checks chat history, artifact, notebook, and pinned indexes for stale entries (books that were moved or deleted outside KOReader) and fixes count mismatches.\n\nThis runs automatically for individual entries when browsing, but you can run a full validation here if needed."),
                    callback = "validateAllIndexes",
                    separator = true,
                },
                -- Reset Settings submenu
                {
                    id = "reset_settings",
                    type = "submenu",
                    text = _("Reset Settings..."),
                    items = {
                        -- Re-run setup wizard
                        {
                            id = "rerun_setup_wizard",
                            type = "action",
                            text = _("Re-run Setup Wizard"),
                            help_text = _("Run the initial setup wizard again to reconfigure language, emoji settings, and gesture assignments."),
                            callback = "rerunSetupWizard",
                            separator = true,
                        },
                        -- Quick: Settings only
                        {
                            id = "quick_reset_settings",
                            type = "action",
                            text = _("Quick: Settings only"),
                            help_text = _("Resets ALL settings in this menu to defaults:\n• Provider, model, temperature\n• Streaming, display, export settings\n• Dictionary & translation settings\n• Reasoning & debug settings\n• Language preferences\n\nKeeps: API keys, all actions, custom behaviors/domains, custom providers/models, gesture registrations, chat history."),
                            confirm = true,
                            confirm_text = _("Reset all settings to defaults?\n\nResets ALL settings in Settings menu:\n• Provider, model, temperature\n• Streaming, display, export settings\n• Dictionary & translation settings\n• Reasoning & debug settings\n• Language preferences\n\nKeeps: API keys, all actions, custom behaviors/domains, custom providers/models, gesture registrations, chat history."),
                            callback = "quickResetSettings",
                        },
                        -- Quick: Actions only
                        {
                            id = "quick_reset_actions",
                            type = "action",
                            text = _("Quick: Actions only"),
                            help_text = _("Resets all action-related settings:\n• Custom actions you created\n• Edits to built-in actions\n• Disabled actions (re-enables all)\n• All action menus (highlight, dictionary, quick actions, general, file browser)\n\nKeeps: All settings, API keys, custom behaviors/domains, custom providers/models, gesture registrations, chat history."),
                            confirm = true,
                            confirm_text = _("Reset all action settings?\n\nResets:\n• Custom actions you created\n• Edits to built-in actions\n• Disabled actions (re-enables all)\n• All action menus (highlight, dictionary, quick actions, general, file browser)\n\nKeeps: All settings, API keys, custom behaviors/domains, custom providers/models, gesture registrations, chat history."),
                            callback = "quickResetActions",
                        },
                        -- Quick: Fresh start
                        {
                            id = "quick_reset_fresh_start",
                            type = "action",
                            text = _("Quick: Fresh start"),
                            help_text = _("Resets everything except API keys and chat history:\n• All settings (provider, model, temperature, all toggles)\n• All actions (custom, edits, menus)\n• Custom behaviors & domains\n• Custom providers & models\n\nKeeps: API keys, gesture registrations, chat history only."),
                            confirm = true,
                            confirm_text = _("Fresh start?\n\nResets:\n• All settings (provider, model, temperature, all toggles)\n• All actions (custom, edits, menus)\n• Custom behaviors & domains\n• Custom providers & models\n\nKeeps: API keys, gesture registrations, chat history only."),
                            callback = "quickResetFreshStart",
                            separator = true,
                        },
                        -- Custom reset
                        {
                            id = "custom_reset",
                            type = "action",
                            text = _("Custom reset..."),
                            help_text = _("Opens a checklist to choose exactly what to reset:\n• Settings (all toggles and preferences)\n• Custom actions\n• Action edits\n• Action menus\n• Custom providers & models\n• Behaviors & domains\n• API keys (with warning)"),
                            callback = "showCustomResetDialog",
                            separator = true,
                        },
                        -- Clear chat history
                        {
                            id = "clear_chat_history",
                            type = "action",
                            text = _("Clear all chat history"),
                            help_text = _("Deletes all saved conversations across all books."),
                            confirm = true,
                            confirm_text = _("Delete all chat history?\n\nThis removes all saved conversations across all books.\n\nThis cannot be undone."),
                            callback = "clearAllChatHistory",
                        },
                    },
                },
            },
        },

        -- Advanced submenu
        {
            id = "advanced",
            type = "submenu",
            text = _("Advanced"),
            emoji = "⚙️",
            items = {
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
                            separator = true,
                        },
                        -- Master reasoning toggle
                        {
                            id = "enable_reasoning",
                            type = "toggle",
                            text = _("Enable Reasoning"),
                            help_text = _("Controls reasoning/thinking for providers that support configurable reasoning.\n\nWhen ON, all sub-toggles below are enabled by default. You can selectively disable individual providers.\n\n• Anthropic: Adaptive thinking (4.6+) / Extended thinking\n• Gemini: Thinking budget (2.5) / Thinking depth (3)\n• OpenAI: Reasoning for GPT-5.1+ models\n• DeepSeek: Thinking for V3.2+ models\n• Z.AI: Thinking for GLM-4.5+ models\n• OpenRouter: Reasoning effort (translates to backend)\n• SambaNova: Thinking toggle (R1, Qwen3)\n\nWhen OFF, models keep their natural behavior (e.g. Gemini 2.5 and DeepSeek Reasoner still think by default).\n\nAlways-on models (o3, GPT-5, Grok-3-mini, Magistral, etc.) are not affected by this toggle. Effort controls for always-on providers are in a separate section below."),
                            path = "features.enable_reasoning",
                            default = false,
                            separator = true,
                        },
                        -- Anthropic Adaptive Thinking (4.6+)
                        {
                            id = "anthropic_adaptive",
                            type = "toggle",
                            text = _("Anthropic Adaptive Thinking (4.6+)"),
                            help_text = _("Supported models:\n") .. getModelList("anthropic", "adaptive_thinking") .. _("\n\nClaude decides when and how much to think based on the task.\nRecommended for 4.6 models. Takes priority over Extended Thinking when the model supports both."),
                            path = "features.anthropic_adaptive",
                            default = true,
                            depends_on = { id = "enable_reasoning", value = true },
                        },
                        {
                            id = "anthropic_effort",
                            type = "radio",
                            text_func = function(plugin)
                                local f = plugin.settings:readSetting("features") or {}
                                local effort = f.anthropic_effort or "high"
                                local labels = { low = _("Low"), medium = _("Medium"), high = _("High"), max = _("Max") }
                                return T(_("Effort: %1"), labels[effort] or effort)
                            end,
                            help_text = _("Low = may skip thinking for simple tasks\nMedium = balanced\nHigh = almost always thinks\nMax = deepest thinking (Opus 4.6 only)"),
                            path = "features.anthropic_effort",
                            default = "high",
                            depends_on = {
                                { id = "enable_reasoning", value = true },
                                { id = "anthropic_adaptive", value = true },
                            },
                            separator = true,
                            options = {
                                { value = "low", text = _("Low (may skip thinking)") },
                                { value = "medium", text = _("Medium") },
                                { value = "high", text = _("High (default)") },
                                { value = "max", text = _("Max (Opus 4.6 only)") },
                            },
                        },
                        -- Anthropic Extended Thinking (4.5)
                        {
                            id = "anthropic_reasoning",
                            type = "toggle",
                            text = _("Anthropic Extended Thinking"),
                            help_text = _("Supported models:\n") .. getModelList("anthropic", "extended_thinking") .. _("\n\nManual thinking budget mode. Works on all thinking-capable models.\nOn 4.6 models, Adaptive Thinking takes priority if both are enabled."),
                            path = "features.anthropic_reasoning",
                            default = true,
                            depends_on = { id = "enable_reasoning", value = true },
                        },
                        {
                            id = "reasoning_budget",
                            type = "spinner",
                            text = _("Thinking Budget (tokens)"),
                            help_text = _("Maximum tokens for extended thinking (1024-32000).\nThis is a cap - Claude uses what it needs up to this limit."),
                            path = "features.reasoning_budget",
                            default = 32000,
                            min = 1024,
                            max = 32000,
                            step = 1024,
                            precision = "%d",
                            depends_on = {
                                { id = "enable_reasoning", value = true },
                                { id = "anthropic_reasoning", value = true },
                            },
                            separator = true,
                        },
                        -- Gemini Thinking
                        {
                            id = "gemini_reasoning",
                            type = "toggle",
                            text = _("Gemini Thinking"),
                            help_text = _("Supported models:\n") .. getModelList("gemini", "thinking") .. "\n" .. getModelList("gemini", "thinking_budget") .. _("\n\nControl thinking for Gemini models.\n\nGemini 3: Configurable thinking depth (level).\nGemini 2.5: Configurable thinking budget.\n\nGemini 2.5 models think by default — when the master toggle is off, their natural behavior is preserved."),
                            path = "features.gemini_reasoning",
                            default = true,
                            depends_on = { id = "enable_reasoning", value = true },
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
                            help_text = _("Thinking depth for Gemini 3 models.\n\nMinimal = fastest\nLow/Medium = balanced\nHigh = deepest thinking"),
                            path = "features.reasoning_depth",
                            default = "high",
                            depends_on = {
                                { id = "enable_reasoning", value = true },
                                { id = "gemini_reasoning", value = true },
                            },
                            options = {
                                { value = "minimal", text = _("Minimal (fastest)") },
                                { value = "low", text = _("Low") },
                                { value = "medium", text = _("Medium") },
                                { value = "high", text = _("High (default)") },
                            },
                        },
                        {
                            id = "gemini_thinking_budget",
                            type = "radio",
                            text_func = function(plugin)
                                local f = plugin.settings:readSetting("features") or {}
                                local budget = f.gemini_thinking_budget or "dynamic"
                                local labels = {
                                    dynamic = _("Dynamic"),
                                    low = _("Low"),
                                    medium = _("Medium"),
                                    high = _("High"),
                                    max = _("Max"),
                                }
                                return T(_("Thinking Budget: %1"), labels[budget] or budget)
                            end,
                            help_text = _("Token budget for Gemini 2.5 thinking.\n\nDynamic = model decides how much to think\nLow = minimal thinking (fastest)\nMedium = balanced\nHigh = deep thinking\nMax = maximum thinking budget"),
                            path = "features.gemini_thinking_budget",
                            default = "dynamic",
                            depends_on = {
                                { id = "enable_reasoning", value = true },
                                { id = "gemini_reasoning", value = true },
                            },
                            separator = true,
                            options = {
                                { value = "dynamic", text = _("Dynamic (model decides)") },
                                { value = "low", text = _("Low (1,024 tokens)") },
                                { value = "medium", text = _("Medium (8,192 tokens)") },
                                { value = "high", text = _("High (16,384 tokens)") },
                                { value = "max", text = _("Max (24,576 tokens)") },
                            },
                        },
                        -- OpenAI Reasoning (5.1+)
                        {
                            id = "openai_reasoning",
                            type = "toggle",
                            text = _("OpenAI Reasoning (5.1+)"),
                            help_text = _("Supported models:\n") .. getModelList("openai", "reasoning_gated") .. _("\n\nEnables reasoning for models where it is off by default.\n\nOther OpenAI reasoning models (o3, GPT-5) always reason at their factory defaults and are not affected by this toggle."),
                            path = "features.openai_reasoning",
                            default = true,
                            depends_on = { id = "enable_reasoning", value = true },
                        },
                        {
                            id = "reasoning_effort",
                            type = "radio",
                            text_func = function(plugin)
                                local f = plugin.settings:readSetting("features") or {}
                                local effort = f.reasoning_effort or "medium"
                                local labels = { low = _("Low"), medium = _("Medium"), high = _("High"), xhigh = _("Extra High") }
                                return T(_("Effort: %1"), labels[effort] or effort)
                            end,
                            help_text = _("Low = faster, less reasoning\nMedium = balanced (recommended)\nHigh = thorough reasoning\nExtra High = maximum reasoning (GPT-5.2+ only)"),
                            path = "features.reasoning_effort",
                            default = "medium",
                            depends_on = {
                                { id = "enable_reasoning", value = true },
                                { id = "openai_reasoning", value = true },
                            },
                            separator = true,
                            options = {
                                { value = "low", text = _("Low (faster)") },
                                { value = "medium", text = _("Medium (default)") },
                                { value = "high", text = _("High (thorough)") },
                                { value = "xhigh", text = _("Extra High (5.2+ only)") },
                            },
                        },
                        -- Z.AI Thinking
                        {
                            id = "zai_reasoning",
                            type = "toggle",
                            text = _("Z.AI Thinking"),
                            help_text = _("Supported models:\n") .. getModelList("zai", "thinking") .. _("\n\nToggle thinking for GLM models. Returns reasoning traces viewable via 'Show Reasoning' button.\n\nGLM-4.5+ models think by default — when the master toggle is off, their natural behavior is preserved."),
                            path = "features.zai_reasoning",
                            default = true,
                            depends_on = { id = "enable_reasoning", value = true },
                            separator = true,
                        },
                        -- DeepSeek Thinking
                        {
                            id = "deepseek_reasoning",
                            type = "toggle",
                            text = _("DeepSeek Thinking"),
                            help_text = _("Supported models:\n") .. getModelList("deepseek", "thinking") .. _("\n\nToggle thinking for DeepSeek V3.2+ models.\n\nWhen the master toggle is off, models keep their natural behavior (deepseek-reasoner thinks by default, deepseek-chat does not)."),
                            path = "features.deepseek_reasoning",
                            default = true,
                            depends_on = { id = "enable_reasoning", value = true },
                            separator = true,
                        },
                        -- OpenRouter Reasoning
                        {
                            id = "openrouter_reasoning",
                            type = "toggle",
                            text = _("OpenRouter Reasoning"),
                            help_text = _("Enable reasoning for models accessed via OpenRouter.\n\nOpenRouter translates the effort level to each backend provider's native format automatically."),
                            path = "features.openrouter_reasoning",
                            default = true,
                            depends_on = { id = "enable_reasoning", value = true },
                        },
                        {
                            id = "openrouter_effort",
                            type = "radio",
                            text_func = function(plugin)
                                local f = plugin.settings:readSetting("features") or {}
                                local effort = f.openrouter_effort or "high"
                                local labels = { low = _("Low"), medium = _("Medium"), high = _("High") }
                                return T(_("Effort: %1"), labels[effort] or effort)
                            end,
                            help_text = _("Reasoning effort level.\n\nLow = faster, less reasoning\nMedium = balanced\nHigh = thorough reasoning"),
                            path = "features.openrouter_effort",
                            default = "high",
                            depends_on = {
                                { id = "enable_reasoning", value = true },
                                { id = "openrouter_reasoning", value = true },
                            },
                            separator = true,
                            options = {
                                { value = "low", text = _("Low (faster)") },
                                { value = "medium", text = _("Medium") },
                                { value = "high", text = _("High (default)") },
                            },
                        },
                        -- SambaNova Thinking
                        {
                            id = "sambanova_reasoning",
                            type = "toggle",
                            text = _("SambaNova Thinking"),
                            help_text = _("Supported models:\n") .. getModelList("sambanova", "thinking") .. _("\n\nToggle thinking for SambaNova-hosted reasoning models (DeepSeek-R1, Qwen3)."),
                            path = "features.sambanova_reasoning",
                            default = true,
                            depends_on = { id = "enable_reasoning", value = true },
                            separator = true,
                        },
                        -- Indicator in chat (separate from "Show Reasoning" button)
                        {
                            id = "show_reasoning_indicator",
                            type = "toggle",
                            text = _("Show Indicator in Chat"),
                            help_text = _("Show '*[Reasoning was used]*' indicator in chat when reasoning is requested or used.\n\nFull reasoning content is always viewable via 'Show Reasoning' button."),
                            path = "features.show_reasoning_indicator",
                            default = true,
                            separator = true,
                        },
                        -- Always-on reasoning: effort level controls (not gated by master toggle)
                        -- These models always reason — controls below adjust effort depth only
                        {
                            type = "info",
                            text = _("Always-on reasoning (effort level):"),
                        },
                        -- OpenAI always-on effort (o3, gpt-5 family)
                        {
                            id = "openai_always_on_effort",
                            type = "radio",
                            text_func = function(plugin)
                                local f = plugin.settings:readSetting("features") or {}
                                local effort = f.openai_always_on_effort or "medium"
                                local labels = { low = _("Low"), medium = _("Medium"), high = _("High") }
                                return T(_("OpenAI (o3, GPT-5): %1"), labels[effort] or effort)
                            end,
                            help_text = _("Reasoning effort for always-on OpenAI models (o3, o3-mini, o4-mini, GPT-5, GPT-5-mini, GPT-5-nano).\n\nThese models always reason — this controls depth, not on/off.\nDefault matches factory setting (medium)."),
                            path = "features.openai_always_on_effort",
                            default = "medium",
                            separator = true,
                            options = {
                                { value = "low", text = _("Low (faster)") },
                                { value = "medium", text = _("Medium (default)") },
                                { value = "high", text = _("High (thorough)") },
                            },
                        },
                        -- xAI Reasoning Effort
                        {
                            id = "xai_effort",
                            type = "radio",
                            text_func = function(plugin)
                                local f = plugin.settings:readSetting("features") or {}
                                local effort = f.xai_effort or "high"
                                local labels = { low = _("Low"), high = _("High") }
                                return T(_("xAI (Grok-3-mini): %1"), labels[effort] or effort)
                            end,
                            help_text = _("Reasoning effort for Grok-3-mini.\n\nThis model always reasons — this controls depth, not on/off."),
                            path = "features.xai_effort",
                            default = "high",
                            separator = true,
                            options = {
                                { value = "low", text = _("Low (faster)") },
                                { value = "high", text = _("High (default)") },
                            },
                        },
                        -- Perplexity Reasoning Effort
                        {
                            id = "perplexity_effort",
                            type = "radio",
                            text_func = function(plugin)
                                local f = plugin.settings:readSetting("features") or {}
                                local effort = f.perplexity_effort or "high"
                                local labels = { low = _("Low"), medium = _("Medium"), high = _("High") }
                                return T(_("Perplexity: %1"), labels[effort] or effort)
                            end,
                            help_text = _("Reasoning effort for Perplexity Sonar reasoning models.\n\nThese models always reason — this controls depth, not on/off."),
                            path = "features.perplexity_effort",
                            default = "high",
                            separator = true,
                            options = {
                                { value = "low", text = _("Low (faster)") },
                                { value = "medium", text = _("Medium") },
                                { value = "high", text = _("High (default)") },
                            },
                        },
                        -- Groq Reasoning Effort
                        {
                            id = "groq_effort",
                            type = "radio",
                            text_func = function(plugin)
                                local f = plugin.settings:readSetting("features") or {}
                                local effort = f.groq_effort or "high"
                                local labels = { low = _("Low"), medium = _("Medium"), high = _("High") }
                                return T(_("Groq: %1"), labels[effort] or effort)
                            end,
                            help_text = _("Supported models:\n") .. getModelList("groq", "reasoning") .. _("\n\nReasoning effort for Groq-hosted reasoning models.\nThese models always reason — this controls depth, not on/off."),
                            path = "features.groq_effort",
                            default = "high",
                            separator = true,
                            options = {
                                { value = "low", text = _("Low (faster)") },
                                { value = "medium", text = _("Medium") },
                                { value = "high", text = _("High (default)") },
                            },
                        },
                        -- Together Reasoning Effort
                        {
                            id = "together_effort",
                            type = "radio",
                            text_func = function(plugin)
                                local f = plugin.settings:readSetting("features") or {}
                                local effort = f.together_effort or "high"
                                local labels = { low = _("Low"), medium = _("Medium"), high = _("High") }
                                return T(_("Together: %1"), labels[effort] or effort)
                            end,
                            help_text = _("Supported models:\n") .. getModelList("together", "reasoning") .. _("\n\nReasoning effort for Together-hosted reasoning models.\nThese models always reason — this controls depth, not on/off."),
                            path = "features.together_effort",
                            default = "high",
                            separator = true,
                            options = {
                                { value = "low", text = _("Low (faster)") },
                                { value = "medium", text = _("Medium") },
                                { value = "high", text = _("High (default)") },
                            },
                        },
                        -- Fireworks Reasoning Effort
                        {
                            id = "fireworks_effort",
                            type = "radio",
                            text_func = function(plugin)
                                local f = plugin.settings:readSetting("features") or {}
                                local effort = f.fireworks_effort or "high"
                                local labels = { low = _("Low"), medium = _("Medium"), high = _("High") }
                                return T(_("Fireworks: %1"), labels[effort] or effort)
                            end,
                            help_text = _("Supported models:\n") .. getModelList("fireworks", "reasoning") .. _("\n\nReasoning effort for Fireworks-hosted reasoning models.\nThese models always reason — this controls depth, not on/off."),
                            path = "features.fireworks_effort",
                            default = "high",
                            separator = true,
                            options = {
                                { value = "low", text = _("Low (faster)") },
                                { value = "medium", text = _("Medium") },
                                { value = "high", text = _("High (default)") },
                            },
                        },
                    },
                },
                -- Web Search submenu
                {
                    id = "web_search_submenu",
                    type = "submenu",
                    text = _("Web Search"),
                    items = {
                        {
                            type = "info",
                            text = _("Supported: Anthropic, Gemini, OpenRouter"),
                        },
                        {
                            id = "enable_web_search",
                            type = "toggle",
                            text = _("Enable Web Search"),
                            help_text = _("Allow AI to search the web for current information.\n\nSupported providers:\n• Anthropic (Claude)\n• Gemini\n• OpenRouter (all models)\n\nPerplexity always searches the web (no toggle needed).\n\nOther providers ignore this setting.\n\nIncreases token usage/cost."),
                            path = "features.enable_web_search",
                            default = false,
                        },
                        {
                            id = "web_search_max_uses",
                            type = "spinner",
                            text = _("Max Searches per Query"),
                            help_text = _("Maximum number of web searches per query (1-10).\nApplies to Anthropic only.\nGemini decides search count automatically."),
                            path = "features.web_search_max_uses",
                            default = 5,
                            min = 1,
                            max = 10,
                            step = 1,
                            precision = "%d",
                            depends_on = { id = "enable_web_search", value = true },
                            separator = true,
                        },
                        {
                            id = "show_web_search_indicator",
                            type = "toggle",
                            text = _("Show Indicator in Chat"),
                            help_text = _("Show '*[Web search was used]*' indicator in chat when web search is used.\n\nStreaming indicator ('Searching the web...') is always shown."),
                            path = "features.show_web_search_indicator",
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
                            id = "zai_region",
                            type = "radio",
                            text_func = function(plugin)
                                local f = plugin.settings:readSetting("features") or {}
                                local region = f.zai_region or "international"
                                local labels = {
                                    international = _("International"),
                                    china = _("China"),
                                }
                                return T(_("Z.AI Region: %1"), labels[region] or region)
                            end,
                            help_text = _("Select the Z.AI API endpoint.\n\nThe same API key works on both endpoints:\n- International: api.z.ai\n- China: open.bigmodel.cn"),
                            path = "features.zai_region",
                            default = "international",
                            options = {
                                { value = "international", text = _("International (api.z.ai)") },
                                { value = "china", text = _("China (open.bigmodel.cn)") },
                            },
                        },
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
                    id = "debug_truncate_content",
                    type = "toggle",
                    text = _("Truncate Large Content (debug)"),
                    help_text = _("Truncate long content (book text, cached responses) in debug output. Shows first and last ~1500 characters with truncation notice."),
                    path = "features.debug_truncate_content",
                    default = true,
                    depends_on = { id = "debug", value = true },
                    separator = true,
                },
                {
                    id = "test_connection",
                    type = "action",
                    text = _("Test Connection"),
                    callback = "testProviderConnection",
                },
            },
        },

        -- About
        {
            id = "about",
            type = "action",
            text = _("About KOAssistant"),
            callback = "showAbout",
        },
        {
            id = "auto_check_updates",
            type = "toggle",
            text = _("Auto-check for updates on startup"),
            path = "features.auto_check_updates",
            default = true,
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
        for _idx, item in ipairs(items_list) do
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
            for _idx, option in ipairs(item.options) do
                if option.value == value then
                    return true
                end
            end
            return false, "Invalid option selected"
        end

        return true -- No validation for other types
    end,
}

-- Extract all defaults from schema into a flat table
-- Returns: { ["features.render_markdown"] = true, ["features.default_temperature"] = 0.7, ... }
function SettingsSchema.getDefaults()
    local defaults = {}

    local function extractFromItems(items)
        for _idx, item in ipairs(items) do
            -- Extract default from item if it has path and default
            if item.path and item.default ~= nil then
                defaults[item.path] = item.default
            end
            -- Recurse into submenus
            if item.items then
                extractFromItems(item.items)
            end
        end
    end

    extractFromItems(SettingsSchema.items)
    return defaults
end

-- Apply defaults to features table (used by reset functions)
-- @param features: current features table
-- @param preserve: table of paths to preserve (e.g., {"features.api_keys", "features.custom_behaviors"})
-- @return: new features table with defaults applied
function SettingsSchema.applyDefaults(features, preserve)
    local defaults = SettingsSchema.getDefaults()
    local preserved_values = {}

    -- Save preserved values
    for _idx, path in ipairs(preserve or {}) do
        local key = path:match("^features%.(.+)$")
        if key and features[key] ~= nil then
            preserved_values[key] = features[key]
        end
    end

    -- Build new features with defaults
    local new_features = {}
    for path, default in pairs(defaults) do
        local key = path:match("^features%.(.+)$")
        if key then
            new_features[key] = default
        end
    end

    -- Restore preserved values
    for key, value in pairs(preserved_values) do
        new_features[key] = value
    end

    -- Keep migration flags
    new_features.behavior_migrated = true
    new_features.prompts_migrated_v2 = true

    return new_features
end

return SettingsSchema
