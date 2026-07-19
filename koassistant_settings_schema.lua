local _ = require("koassistant_gettext")
local T = require("ffi/util").template
local ModelConstraints = require("model_constraints")
local Constants = require("koassistant_constants")

-- Settings Schema Definition
-- This file defines the structure and metadata for all KOAssistant plugin settings
-- Used by SettingsManager to generate menus - SINGLE SOURCE OF TRUTH

local ModelLists = require("koassistant_model_lists")

-- Helper: radio options for an image-generation model picker
-- ("default" = first entry of the provider's image model list)
local function imageModelOptions(provider)
    local opts = {
        { value = "default", text = T(_("Default (%1)"), ModelLists.getDefaultImageModel(provider) or "?") },
    }
    for _idx, m in ipairs(ModelLists.getImageModels(provider) or {}) do
        table.insert(opts, { value = m, text = m })
    end
    return opts
end

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
            id = "library_actions",
            type = "action",
            text = _("Library Chat/Action"),
            emoji = "\u{1F4DA}",
            callback = "openLibraryDialog",
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
            separator = true,
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
                        { value = "bn", label = "বাংলা (Bengali)" },
                        { value = "cs", label = "Čeština (Czech)" },
                        { value = "de", label = "Deutsch (German)" },
                        { value = "es", label = "Español (Spanish)" },
                        { value = "fa", label = "فارسی (Persian)" },
                        { value = "fi", label = "Suomi (Finnish)" },
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
                        { value = "ur", label = "اردو (Urdu)" },
                        { value = "vi", label = "Tiếng Việt (Vietnamese)" },
                        { value = "zh", label = "中文 (Chinese)" },
                    },
                    on_change = function()
                        -- Invalidate the cached language resolution (gettext caches it to
                        -- avoid a settings-file disk read on every _() call). Menus built
                        -- from now on pick up the new language; already-built UI needs the
                        -- restart below.
                        require("koassistant_gettext").reload()
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
                -- Quick Answer preset (controls_parity_plan.md §2): what the ⚡ chip's
                -- tap applies for that chat. Also editable from the chip's hold menu
                -- ("Preset settings…"). Check patterns: posture toggles are opt-out
                -- (~= false), model mode is opt-in (default "none").
                {
                    id = "quick_answer_preset",
                    type = "submenu",
                    text = _("Quick Answer Preset"),
                    items = {
                        {
                            id = "quick_preset_nudge",
                            type = "toggle",
                            text = _("Concise Answer Nudge"),
                            path = "features.quick_preset_nudge",
                            default = true,
                            help_text = _("Ask for a short, direct reply (a few sentences, no preamble) while Quick Answer is on."),
                        },
                        {
                            id = "quick_preset_reasoning_off",
                            type = "toggle",
                            text = _("Turn Reasoning Off"),
                            path = "features.quick_preset_reasoning_off",
                            default = true,
                            help_text = _("Disable model reasoning/thinking for Quick Answer chats (models that can't disable it drop to their lowest level). A one-shot reasoning pick in the Quick chip's menu overrides this."),
                        },
                        {
                            id = "quick_preset_web_off",
                            type = "toggle",
                            text = _("Turn Web Search Off"),
                            path = "features.quick_preset_web_off",
                            default = true,
                        },
                        {
                            id = "quick_preset_tools_off",
                            type = "toggle",
                            text = _("Turn Book Tools Off"),
                            path = "features.quick_preset_tools_off",
                            default = true,
                            separator = true,
                        },
                        {
                            id = "quick_preset_model_mode",
                            type = "radio",
                            text_func = function(plugin)
                                local f = plugin.settings:readSetting("features") or {}
                                local mode = f.quick_preset_model_mode or "none"
                                local labels = {
                                    none = _("Keep current"),
                                    fastest = _("Fastest for provider"),
                                }
                                return T(_("Model: %1"), labels[mode] or mode)
                            end,
                            help_text = _("Optionally switch to your active provider's fastest listed model while Quick Answer is on (this chat only — your default model is untouched). Custom providers have no tier info and keep the current model. A one-shot model pick in the Quick chip's menu overrides this."),
                            path = "features.quick_preset_model_mode",
                            default = "none",
                            options = {
                                { value = "none", text = _("Keep current model") },
                                { value = "fastest", text = _("Fastest model for active provider") },
                            },
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
                    help_text = _("When enabled, instructs the AI not to reveal events beyond your current reading position in book and highlight chats. Custom actions can use the {spoiler_free_nudge} placeholder.\n\nFor a per-chat toggle, enable the Spoiler chip via the chat input's gear menu → Toolbar Buttons."),
                },
                {
                    id = "book_info_in_chat",
                    type = "dropdown",
                    text = _("Book Info in Chat"),
                    path = "features.book_info_in_chat",
                    default = "basic",
                    options = {
                        { value = "none", label = _("None") },
                        { value = "title", label = _("Title only") },
                        { value = "basic", label = _("Title & author") },
                        { value = "full", label = _("Title, author & position") },
                    },
                    help_text = _("Default book context sent with freeform chats and book-aware actions (Explain, etc.). 'None' sends no book line; 'Title only' omits the author; 'Title & author' is the default; 'Title, author & position' also adds reading progress, chapter, and page (when basic stats are enabled). Override per book in Book Settings. Actions that don't request book info (e.g. Translate) are unaffected."),
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

        -- Reading & Library settings
        -- Consolidates: chapter quiz, recap reminder, end-of-book, library scanning
        {
            id = "reading_and_library",
            type = "submenu",
            text = _("Reading & Library"),
            emoji = "📖",
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
                    text = _("Quiz Chapter Level"),
                    path = "features.quiz_chapter_depth",
                    default = 2,
                    options = {
                        { value = "auto", label = _("Auto-detect") },
                        { value = 1, label = _("Top level (Level 1)") },
                        { value = 2, label = _("Level 2") },
                        { value = 3, label = _("Level 3") },
                        { value = "toc_filter", label = _("All TOC headings") },
                    },
                    help_text = _("Which TOC level counts as a 'chapter' for end-of-chapter quizzes. A fixed level falls back to the deepest level the book actually has. 'Auto-detect' picks the deepest level whose chapters are at least the minimum length below. 'All TOC headings' follows KOReader's TOC tick settings. Short or skimmed chapters are skipped by the length setting below."),
                    depends_on = { id = "enable_chapter_quiz", value = true },
                },
                {
                    id = "quiz_min_chapter_pages",
                    type = "spinner",
                    text = _("Minimum Chapter Length (pages)"),
                    path = "features.quiz_min_chapter_pages",
                    default = 5,
                    min = 0,
                    max = 30,
                    step = 1,
                    precision = "%d",
                    help_text = _("Skip the chapter-end quiz for chapters shorter than this many pages (0 = no minimum). Also sets the threshold 'Auto-detect' uses to pick the chapter level. Can be overridden per book in Book Settings."),
                    depends_on = { id = "enable_chapter_quiz", value = true },
                },
                {
                    id = "quiz_min_chapter_time",
                    type = "spinner",
                    text = _("Minimum Reading Time (minutes)"),
                    path = "features.quiz_min_chapter_time",
                    default = 3,
                    min = 0,
                    max = 60,
                    step = 1,
                    precision = "%d",
                    help_text = _("Skip the chapter-end quiz unless you spent at least this many minutes reading the chapter (0 = no minimum). Catches flipping quickly through a long chapter. Uses KOReader's reading statistics; if those are unavailable the quiz is still offered. Can be overridden per book in Book Settings."),
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
                    text = _("Include Discussion"),
                    path = "features.quiz_essay_enabled",
                    default = true,
                    separator = true,
                },
                -- X-Ray background auto-update
                {
                    id = "xray_auto_header",
                    type = "header",
                    text = _("X-Ray"),
                },
                {
                    id = "xray_auto_update",
                    type = "toggle",
                    text = _("Auto-update X-Ray while reading"),
                    path = "features.xray_auto_update",
                    default = false,
                    help_text = _("Quietly bring this book's X-Ray up to your reading position in the background as you read. Each book must additionally be opted in from its X-Ray popup or Book Settings.\n\nSpend guards: never creates an X-Ray (only updates an existing incremental one — unless Auto-create below is also on), fires at most once per cooldown, only for progress gaps inside the window below (bigger gaps stay manual), and only when WiFi is already on. This makes API calls without a tap — leave off if every request should be explicit."),
                },
                {
                    id = "xray_auto_create",
                    type = "toggle",
                    text = _("Auto-create X-Ray (early in a book)"),
                    path = "features.xray_auto_create",
                    default = false,
                    help_text = _("For opted-in books with no X-Ray yet: quietly create the first one in the background once you've read past the minimum gap. The maximum gap still caps it — further into a book, create the first X-Ray manually (which shows the extraction size first). Books with an existing non-incremental X-Ray (complete, AI-knowledge, legacy) are never touched."),
                    depends_on = { id = "xray_auto_update", value = true },
                },
                {
                    id = "xray_auto_min_gap",
                    type = "spinner",
                    text = _("Minimum Progress Gap (%)"),
                    path = "features.xray_auto_min_gap",
                    default = 5,
                    min = 1,
                    max = 20,
                    step = 1,
                    precision = "%d",
                    help_text = _("Don't auto-update until you've read at least this much past the X-Ray's position. Lower = more frequent, smaller updates (more API calls); higher = fewer, larger ones."),
                    depends_on = { id = "xray_auto_update", value = true },
                },
                {
                    id = "xray_auto_max_gap",
                    type = "spinner",
                    text = _("Maximum Progress Gap (%)"),
                    path = "features.xray_auto_max_gap",
                    default = 25,
                    min = 10,
                    max = 60,
                    step = 5,
                    precision = "%d",
                    help_text = _("Spend guard: gaps bigger than this never auto-update — run the update manually from the X-Ray popup, which shows the size first. Raising this allows larger unattended extractions."),
                    depends_on = { id = "xray_auto_update", value = true },
                },
                {
                    id = "xray_auto_cooldown",
                    type = "spinner",
                    text = _("Cooldown (minutes)"),
                    path = "features.xray_auto_cooldown",
                    default = 15,
                    min = 0,
                    max = 120,
                    step = 1,
                    precision = "%d",
                    help_text = _("Minimum time between background attempts (0 = no cooldown). The progress-gap window still applies."),
                    depends_on = { id = "xray_auto_update", value = true },
                },
                {
                    id = "xray_auto_notify",
                    type = "toggle",
                    text = _("Notify on Auto-Update"),
                    path = "features.xray_auto_notify",
                    default = false,
                    help_text = _("Show a brief notification when a background X-Ray update starts and when it completes. Off = fully silent (the X-Ray popup always shows the current coverage)."),
                    depends_on = { id = "xray_auto_update", value = true },
                },
                {
                    id = "xray_versions_kept",
                    type = "spinner",
                    text = _("X-Ray Versions to Keep"),
                    path = "features.xray_versions_kept",
                    default = 5,
                    min = 0,
                    max = 20,
                    step = 1,
                    precision = "%d",
                    help_text = _("Whenever an update or redo overwrites the X-Ray, the outgoing version is archived — browse, view, or restore them via \"Previous versions\" in the X-Ray popup and browser menu. This sets how many are kept per book (oldest dropped first). 0 stops archiving new versions; already-archived ones stay until you delete them or the X-Ray itself."),
                    separator = true,
                },
                -- Recap Reminder
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
                -- End of Book
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
                -- Library
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
                -- (Popup visibility toggle + popup-actions manager live in
                -- Menus & Buttons; behavior settings stay here)
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
                    help_text = _("Action to trigger when dictionary bypass is enabled. With X-Ray Lookup, a tapped word that has an X-Ray entry opens it directly; any other word falls through to the normal dictionary."),
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
                    id = "translate_use_context",
                    type = "toggle",
                    text = _("Include Surrounding Context"),
                    path = "features.translate_use_context",
                    default = false,
                    help_text = _("Send the text around the highlight along with translations, so the AI can resolve pronouns, tone, and ambiguous words. Uses the Surrounding Context mode from Highlight Settings (sentence when that is off). Never applies to full-page translation."),
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
                    id = "highlight_context_mode",
                    type = "dropdown",
                    text = _("Surrounding Context"),
                    path = "features.highlight_context_mode",
                    default = "none",
                    options = {
                        { value = "none", label = _("None (off)") },
                        { value = "sentence", label = _("Sentence") },
                        { value = "paragraph", label = _("Paragraph(s)") },
                        { value = "characters", label = _("Characters") },
                    },
                    help_text = _("Automatically send the text around a highlight with highlight questions and actions, so the AI sees the passage in context. Capped at 2000 characters. Dictionary lookups and actions with their own scope selection are unaffected. Can be overridden per book in Book Settings."),
                },
                {
                    id = "highlight_context_paragraphs",
                    type = "spinner",
                    text = _("Context Paragraphs"),
                    path = "features.highlight_context_paragraphs",
                    default = 1,
                    min = 1,
                    max = 5,
                    step = 1,
                    help_text = _("Number of paragraphs to include on each side of the highlight when Surrounding Context is 'Paragraph(s)'. 1 = the paragraph containing the highlight."),
                    enabled_func = function(plugin)
                        local f = plugin.settings:readSetting("features") or {}
                        return f.highlight_context_mode == "paragraph"
                    end,
                },
                {
                    id = "highlight_context_chars",
                    type = "spinner",
                    text = _("Context Characters"),
                    path = "features.highlight_context_chars",
                    default = 100,
                    min = 20,
                    max = 1000,
                    step = 10,
                    help_text = _("Number of characters to include before/after the highlight when Surrounding Context is 'Characters'."),
                    enabled_func = function(plugin)
                        local f = plugin.settings:readSetting("features") or {}
                        return f.highlight_context_mode == "characters"
                    end,
                    separator = true,
                },
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
                -- (Highlight-menu visibility toggles + actions manager live in
                -- Menus & Buttons; behavior settings stay here)
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
                {
                    id = "default_domain_research",
                    type = "action",
                    text_func = function(plugin)
                        local f = plugin.settings:readSetting("features") or {}
                        local name = _("None")
                        if f.selected_domain then
                            local DomainLoader = require("domain_loader")
                            local d = DomainLoader.getDomainById(f.selected_domain, f.custom_domains or {})
                            name = d and (d.display_name or d.name) or f.selected_domain
                        end
                        return T(_("Default Domain & Research (%1)"), name)
                    end,
                    callback = "showDomainSettingsEntry",
                    info_text = _("The default domain and research mode for AI requests. Individual books can override both in Book Settings."),
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
                },
                -- (Notebook entry-point toggles — highlight menu / file browser —
                -- live in Menus & Buttons)
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
                    help_text = _("Enables library actions that analyze your book collection. Configure permanent scan folders in Reading & Library, or pick folders on the fly in the input dialog."),
                    on_change = function(new_value)
                        if new_value then
                            local InfoMessage = require("ui/widget/infomessage")
                            local UIManager = require("ui/uimanager")
                            UIManager:show(InfoMessage:new{
                                text = _("Enables library actions that analyze your book collection.\n\nConfigure permanent scan folders in Reading & Library, or pick folders on the fly in the input dialog."),
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

        -- Menus & Buttons submenu (entry-points audit 2026-07-16, Option A): every
        -- surface where KOAssistant appears gets one block — its visibility toggles
        -- plus a link to its action manager. Settings PATHS are unchanged (placement
        -- only); behavior-shaped settings stay in their feature sections.
        {
            id = "menus_and_buttons",
            type = "submenu",
            text = _("Menus & Buttons"),
            emoji = "🔌",
            items = {
                {
                    id = "integration_info",
                    type = "header",
                    text = _("Control where KOAssistant appears in KOReader"),
                },
                -- Highlight menu
                {
                    id = "highlight_menu_header",
                    type = "header",
                    text = _("Highlight menu"),
                },
                {
                    id = "show_koassistant_in_highlight",
                    type = "toggle",
                    text = _("Show Chat/Action button"),
                    path = "features.show_koassistant_in_highlight",
                    default = true,
                    help_text = _("Add the main 'Chat/Action' button to the highlight menu. Takes effect the next time the menu opens."),
                },
                {
                    id = "show_quick_actions_in_highlight",
                    type = "toggle",
                    text = _("Show quick actions"),
                    path = "features.show_quick_actions_in_highlight",
                    default = true,
                    help_text = _("Add action shortcuts (Explain, Translate, etc.) to the highlight menu. Takes effect the next time the menu opens."),
                },
                {
                    id = "show_notebook_in_highlight",
                    type = "toggle",
                    text = _("Show Add to Notebook button"),
                    path = "features.show_notebook_in_highlight",
                    default = true,
                    help_text = _("Add an 'Add to notebook' button to the highlight menu, saving the selected text directly to this book's notebook. Takes effect the next time the menu opens."),
                },
                {
                    id = "show_image_gen_in_highlight",
                    type = "toggle",
                    text = _("Show Generate Image button"),
                    path = "features.show_image_gen_in_highlight",
                    default = true,
                    help_text = _("Add a 'Generate Image' button to the highlight menu, visualizing the selected text with the current AI provider. Only shown when the provider supports image generation (OpenAI, xAI, Gemini). Takes effect the next time the menu opens."),
                },
                {
                    id = "highlight_menu_actions",
                    type = "action",
                    text = _("Highlight Menu Actions"),
                    callback = "showHighlightMenuManager",
                    help_text = _("Choose which actions appear in the highlight menu. Changes take effect the next time the menu opens (up to 15 shown)."),
                    separator = true,
                },
                -- Dictionary popup
                {
                    id = "dictionary_popup_header",
                    type = "header",
                    text = _("Dictionary popup"),
                },
                {
                    id = "enable_dictionary_hook",
                    type = "toggle",
                    text = _("Show AI buttons"),
                    path = "features.enable_dictionary_hook",
                    default = true,
                    help_text = _("Add AI buttons to KOReader's dictionary popup."),
                },
                {
                    id = "dictionary_popup_actions",
                    type = "action",
                    text = _("Dictionary Popup Actions"),
                    callback = "showDictionaryPopupManager",
                    help_text = _("Configure which actions appear in the dictionary popup"),
                    separator = true,
                },
                -- File browser
                {
                    id = "file_browser_header",
                    type = "header",
                    text = _("File browser"),
                },
                {
                    id = "show_in_file_browser",
                    type = "toggle",
                    text = _("Show KOAssistant actions"),
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
                    id = "show_notebook_in_file_browser",
                    type = "toggle",
                    text = _("Show Notebook button"),
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
                {
                    id = "file_browser_actions",
                    type = "action",
                    text = _("File Browser Actions"),
                    callback = "showFileBrowserActionsManager",
                    help_text = _("Choose which actions appear in the file browser long-press menu."),
                    separator = true,
                },
                -- Quick panels
                {
                    id = "panels_header",
                    type = "header",
                    text = _("Quick panels"),
                },
                {
                    id = "panel_actions",
                    type = "action",
                    text = _("Panel Actions"),
                    callback = "showQuickActionsManager",
                    help_text = _("Choose which actions appear on the Quick Actions panel."),
                },
                {
                    id = "panel_utilities",
                    type = "action",
                    text = _("Panel Utilities"),
                    callback = "showQaUtilitiesManager",
                    help_text = _("Choose and order the utility buttons on the Quick Actions panel."),
                },
                {
                    id = "quick_settings_items",
                    type = "action",
                    text = _("Quick Settings Items"),
                    callback = "showQsItemsManager",
                    help_text = _("Choose and order the tiles on the Quick Settings panel."),
                    separator = true,
                },
                -- Gestures
                {
                    id = "gestures_header",
                    type = "header",
                    text = _("Gestures"),
                },
                {
                    id = "show_in_gesture_menu",
                    type = "toggle",
                    text = _("Register gesture actions"),
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
                    separator = true,
                },
                -- KOReader viewers
                {
                    id = "viewers_header",
                    type = "header",
                    text = _("Text selection in viewers"),
                },
                {
                    id = "enhance_text_selection",
                    type = "toggle",
                    text = _("Enhance text selection"),
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
                    separator = true,
                },
                -- Input dialog (managers stay contextual — pointer only)
                {
                    id = "input_dialog_header",
                    type = "header",
                    text = _("Input dialog"),
                },
                {
                    id = "input_dialog_pointer",
                    type = "info",
                    text = _("Action rows and toolbar chips are configured from the input dialog's gear menu."),
                },
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
                },
                {
                    id = "rebuild_indexes",
                    type = "action",
                    text = _("Rebuild Data Indexes"),
                    help_text = _("Finds books whose KOAssistant data (artifacts, chats, notebooks, pinned) exists on disk but doesn't show in this device's browsers — e.g. after syncing sidecar files from another device, restoring a backup, or migrating devices.\n\nChecks your reading history, KOReader's sidecar locations, and the scan folders configured below, then removes stale entries. Books on unmounted storage get pruned; run again with the storage mounted to re-add them.\n\nMay take a while on large libraries."),
                    callback = "rebuildAllIndexes",
                },
                {
                    id = "index_scan_folders",
                    type = "submenu",
                    text_func = function(plugin)
                        local f = plugin.settings:readSetting("features") or {}
                        local folders = f.index_scan_folders or {}
                        if #folders == 0 then
                            return _("Index Scan Folders: None")
                        else
                            return T(_("Index Scan Folders: %1"), #folders)
                        end
                    end,
                    help_text = _("Folders to scan during index rebuild — point this at your synced book folders. Only these folders are ever scanned, and only when a rebuild runs. Folders that don't exist on this device are skipped.\n\nNote: a settings reset clears this list."),
                    callback = "getIndexScanFoldersMenuItems",
                },
                {
                    id = "index_rebuild_on_start",
                    type = "toggle",
                    text = _("Auto-Rebuild on Startup"),
                    path = "features.index_rebuild_on_start",
                    default = false,
                    help_text = _("Also run the index rebuild automatically after KOReader starts: at most once per day, only when scan folders are configured, quietly in the background."),
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
                -- Reasoning / Thinking — per-model reasoning system.
                -- Global Minimal/Default/Maximum stance + optional per-model overrides
                -- (features.reasoning_prefs), resolved in model_constraints.lua.
                {
                    id = "reasoning_submenu",
                    type = "submenu",
                    text = _("Reasoning"),
                    items = {
                        -- Global stance (base layer for every model)
                        {
                            id = "reasoning_stance",
                            type = "radio",
                            text_func = function(plugin)
                                local f = plugin.settings:readSetting("features") or {}
                                local stance = (f.reasoning_prefs and f.reasoning_prefs.stance) or "default"
                                local labels = { minimal = _("Minimal"), default = _("Default"), maximum = _("Maximum") }
                                return T(_("Global stance: %1"), labels[stance] or stance)
                            end,
                            help_text = _("How much reasoning across all models, as far as each model allows. Override individual models below."),
                            path = "features.reasoning_prefs.stance",
                            default = "default",
                            options = {
                                { value = "minimal", text = _("Minimal (off where possible)") },
                                { value = "default", text = _("Default (let each model decide)") },
                                { value = "maximum", text = _("Maximum (most reasoning)") },
                            },
                            separator = true,
                        },
                        -- Per-model overrides (dynamic, callback-built submenu)
                        {
                            id = "reasoning_per_model",
                            type = "submenu",
                            text = _("Per-model reasoning"),
                            callback = "buildReasoningModelProviderMenu",
                            separator = true,
                        },
                        -- Indicator in chat (display only, separate from "Show Reasoning" button)
                        {
                            id = "show_reasoning_indicator",
                            type = "toggle",
                            text = _("Show Indicator in Chat"),
                            help_text = _("Show '*[Reasoning was used]*' indicator in chat when reasoning is requested or used.\n\nFull reasoning content is always viewable via 'Show Reasoning' button."),
                            path = "features.show_reasoning_indicator",
                            default = true,
                            separator = true,
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
                            text = T(_("Supported: %1 (other providers currently ignore this)"),
                                ModelConstraints.getWebSearchProvidersLabel()),
                        },
                        {
                            id = "enable_web_search",
                            type = "toggle",
                            text = _("Enable Web Search"),
                            help_text = T(_("Allow AI to search the web for current information.\n\nSupported providers: %1.\n\nGemini supports it only on Search-grounding-capable models; Perplexity always searches (no toggle needed); OpenRouter works for any model via the :online suffix.\n\nOther providers currently ignore this setting.\n\nThis is a global default — per-request toggles (input dialog, chat viewer) adapt to the active provider.\n\nIncreases token usage/cost."),
                                ModelConstraints.getWebSearchProvidersLabel()),
                            path = "features.enable_web_search",
                            default = false,
                        },
                        {
                            id = "web_search_effort",
                            type = "radio",
                            text_func = function(plugin)
                                local f = plugin.settings:readSetting("features") or {}
                                local effort = f.web_search_effort or "standard"
                                local labels = {
                                    light = _("Light"),
                                    standard = _("Standard"),
                                    thorough = _("Thorough"),
                                }
                                return T(_("Web Search Effort: %1"), labels[effort] or effort)
                            end,
                            help_text = _("How much web searching the AI may do per question.\n\nLight: fewest searches — fastest and cheapest.\nStandard: balanced (provider defaults).\nThorough: most searches and context — slower and costlier.\n\nApplies where the provider offers control: Anthropic (up to 2/5/10 searches), Perplexity (search context size), OpenRouter (3/5/10 results). Gemini decides automatically."),
                            path = "features.web_search_effort",
                            default = "standard",
                            options = {
                                { value = "light", text = _("Light (fewest searches)") },
                                { value = "standard", text = _("Standard") },
                                { value = "thorough", text = _("Thorough (most searches)") },
                            },
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
                -- Image Generation submenu (PR #96 polish)
                {
                    id = "image_generation_submenu",
                    type = "submenu",
                    text = _("Image Generation"),
                    items = {
                        {
                            type = "info",
                            text = _("Generate images from highlighted text (button in the highlight menu)"),
                        },
                        {
                            id = "image_gen_provider",
                            type = "radio",
                            text_func = function(plugin)
                                local f = plugin.settings:readSetting("features") or {}
                                local v = f.image_gen_provider or "auto"
                                local labels = {
                                    auto = _("Follow main provider"),
                                    openai = "OpenAI",
                                    xai = "xAI (Grok)",
                                    gemini = "Gemini",
                                }
                                return T(_("Provider: %1"), labels[v] or v)
                            end,
                            help_text = _("Which provider generates images.\n\n'Follow main provider' uses your current chat provider when it supports images (OpenAI, xAI, Gemini). Picking one explicitly lets image generation work no matter which chat provider is active — it uses that provider's own API key.\n\nThe highlight-menu button only appears when the resolved provider has an API key."),
                            path = "features.image_gen_provider",
                            default = "auto",
                            options = {
                                { value = "auto", text = _("Follow main provider") },
                                { value = "openai", text = "OpenAI" },
                                { value = "xai", text = "xAI (Grok)" },
                                { value = "gemini", text = "Gemini" },
                            },
                            separator = true,
                        },
                        {
                            id = "image_gen_model_openai",
                            type = "radio",
                            text_func = function(plugin)
                                local f = plugin.settings:readSetting("features") or {}
                                return T(_("OpenAI model: %1"), f.image_gen_model_openai or _("Default"))
                            end,
                            help_text = _("gpt-image-1-mini is fast (~15 s) and cheapest; gpt-image-2 is highest quality but slow (~60 s)."),
                            path = "features.image_gen_model_openai",
                            default = "default",
                            options = imageModelOptions("openai"),
                            depends_on = { id = "image_gen_provider", value = "openai" },
                        },
                        {
                            id = "image_gen_model_xai",
                            type = "radio",
                            text_func = function(plugin)
                                local f = plugin.settings:readSetting("features") or {}
                                return T(_("xAI model: %1"), f.image_gen_model_xai or _("Default"))
                            end,
                            path = "features.image_gen_model_xai",
                            default = "default",
                            options = imageModelOptions("xai"),
                            depends_on = { id = "image_gen_provider", value = "xai" },
                        },
                        {
                            id = "image_gen_model_gemini",
                            type = "radio",
                            text_func = function(plugin)
                                local f = plugin.settings:readSetting("features") or {}
                                return T(_("Gemini model: %1"), f.image_gen_model_gemini or _("Default"))
                            end,
                            path = "features.image_gen_model_gemini",
                            default = "default",
                            options = imageModelOptions("gemini"),
                            depends_on = { id = "image_gen_provider", value = "gemini" },
                            separator = true,
                        },
                        {
                            id = "image_gen_size",
                            type = "radio",
                            text_func = function(plugin)
                                local f = plugin.settings:readSetting("features") or {}
                                return T(_("OpenAI size: %1"), f.image_gen_size or _("Default"))
                            end,
                            help_text = _("Image dimensions (OpenAI only). Default lets the API decide."),
                            path = "features.image_gen_size",
                            default = "default",
                            options = {
                                { value = "default", text = _("Default") },
                                { value = "1024x1024", text = "1024x1024" },
                                { value = "1536x1024", text = _("1536x1024 (landscape)") },
                                { value = "1024x1536", text = _("1024x1536 (portrait)") },
                            },
                            depends_on = { id = "image_gen_provider", value = "openai" },
                        },
                        {
                            id = "image_gen_quality",
                            type = "radio",
                            text_func = function(plugin)
                                local f = plugin.settings:readSetting("features") or {}
                                return T(_("OpenAI quality: %1"), f.image_gen_quality or _("Default"))
                            end,
                            help_text = _("Higher quality is slower and costs more (OpenAI only)."),
                            path = "features.image_gen_quality",
                            default = "default",
                            options = {
                                { value = "default", text = _("Default") },
                                { value = "low", text = _("Low") },
                                { value = "medium", text = _("Medium") },
                                { value = "high", text = _("High") },
                            },
                            depends_on = { id = "image_gen_provider", value = "openai" },
                        },
                        {
                            id = "image_gen_aspect",
                            type = "radio",
                            text_func = function(plugin)
                                local f = plugin.settings:readSetting("features") or {}
                                return T(_("Aspect ratio: %1"), f.image_gen_aspect or _("Default"))
                            end,
                            help_text = _("Output aspect ratio (xAI only). Default lets the API decide."),
                            path = "features.image_gen_aspect",
                            default = "default",
                            options = {
                                { value = "default", text = _("Default") },
                                { value = "1:1", text = "1:1" },
                                { value = "16:9", text = "16:9" },
                                { value = "9:16", text = "9:16" },
                                { value = "3:2", text = "3:2" },
                                { value = "2:3", text = "2:3" },
                            },
                            depends_on = { id = "image_gen_provider", value = "xai" },
                            separator = true,
                        },
                        {
                            id = "generated_images_browser",
                            type = "action",
                            text = _("Generated images…"),
                            callback = "showImageBrowser",
                            help_text = _("Browse, view, and delete the images generated so far."),
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
                    id = "tools_posture",
                    type = "radio",
                    text_func = function(plugin)
                        local f = plugin.settings:readSetting("features") or {}
                        local posture = f.tools_posture or "auto"
                        local labels = {
                            off = _("Off"),
                            manual = _("Manual"),
                            auto = _("Auto"),
                        }
                        return T(_("AI Book Tools: %1"), labels[posture] or posture)
                    end,
                    help_text = _("EXPERIMENTAL — Gemini, Claude (Anthropic), OpenAI, and OpenRouter (Claude/GPT/Gemini models). Book tools let the AI search the open book's text, read specific pages, and view the table of contents, so it can ground answers in the actual book instead of guessing. Requires \"Allow Text Extraction\".\n\nOff: no tool use anywhere — the Tools chip disappears from chats, and actions can't use smart retrieval.\nManual: the Tools chip in book chats starts OFF — tap it to allow tools for that chat.\nAuto (default): the Tools chip starts ON; the AI still decides per question whether to actually search. Manual and Auto only set the chip's starting position.\n\nPredefined actions are unaffected either way — they never use tools unless they explicitly offer smart retrieval. Override per book in Book Settings. Work in progress; behavior may change."),
                    path = "features.tools_posture",
                    default = "auto",
                    options = {
                        { value = "off", text = _("Off (no tool use at all)") },
                        { value = "manual", text = _("Manual (Tools chip starts OFF)") },
                        { value = "auto", text = _("Auto (Tools chip starts ON)") },
                    },
                },
                {
                    id = "tool_mode",
                    type = "radio",
                    text_func = function(plugin)
                        local f = plugin.settings:readSetting("features") or {}
                        local mode = f.tool_mode or "gather"
                        local labels = {
                            gather = _("Gather then answer"),
                            interactive = _("Interactive"),
                        }
                        return T(_("Book Tools Mode: %1"), labels[mode] or mode)
                    end,
                    help_text = _("How AI Book Tools answer.\n\nGather then answer: the AI quietly collects passages from the book first, then answers as a normal request — the answer streams and web search stays available.\n\nInteractive: the original agentic loop — the AI narrates its way through lookups; no streaming or web search while tools run."),
                    path = "features.tool_mode",
                    default = "gather",
                    options = {
                        { value = "gather", text = _("Gather then answer (streams; recommended)") },
                        { value = "interactive", text = _("Interactive agentic loop") },
                    },
                },
                {
                    id = "tool_lookup_effort",
                    type = "radio",
                    text_func = function(plugin)
                        local f = plugin.settings:readSetting("features") or {}
                        local effort = f.tool_lookup_effort or "standard"
                        local labels = {
                            quick = _("Quick"),
                            standard = _("Standard"),
                            thorough = _("Thorough"),
                        }
                        return T(_("Book Tools Lookup Effort: %1"), labels[effort] or effort)
                    end,
                    help_text = _("How much searching AI Book Tools may do per question.\n\nQuick: up to 4 lookups in 2 rounds — fastest, for simple factual questions.\nStandard: up to 8 lookups in 4 rounds — good balance.\nThorough: up to 16 lookups in 6 rounds, with a larger passage budget — slower and costlier, for questions that need evidence from many places in the book."),
                    path = "features.tool_lookup_effort",
                    default = "standard",
                    options = {
                        { value = "quick", text = _("Quick (up to 4 lookups)") },
                        { value = "standard", text = _("Standard (up to 8 lookups)") },
                        { value = "thorough", text = _("Thorough (up to 16 lookups)") },
                    },
                },
                {
                    id = "show_book_tools_indicator",
                    type = "toggle",
                    text = _("AI Book Tools: Show Indicator in Chat"),
                    help_text = _("Show '*[Searched the book — N lookups]*' indicator in chat when AI Book Tools ran for a response.\n\nThe individual lookups are always viewable via the chat menu's 'Show Sources' entry."),
                    path = "features.show_book_tools_indicator",
                    default = true,
                },
                {
                    id = "tool_workflow_diagnostics",
                    type = "toggle",
                    text = _("AI Book Tools: Show Lookups (debug)"),
                    path = "features.tool_workflow_diagnostics",
                    default = false,
                    help_text = _("Append the tool lookups, raw tool results, and token usage to each answer when AI Book Tools run. For debugging the experimental tools — leave off for clean answers. Note: the raw tool results can include book-text snippets."),
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
