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
            -- A4: the open book's home page — peer destinations below all
            -- have a main-menu row, this was the audit's discoverability find
            id = "book_hub",
            type = "action",
            text = _("Book Hub"),
            emoji = "📖",
            callback = "onKOAssistantBookOverview",
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
        },
        {
            id = "book_groups",
            type = "action",
            text = _("Groups"),
            -- 🗂️ (round 29): ONE icon for groups everywhere — the newer entry
            -- points had drifted to 📚, which is already Library Chat/Action.
            -- Dividers, not a folder: a group is a curated ordered list that
            -- survives file moves and does NOT follow a directory, so 📁 would
            -- read as filesystem-backed — exactly the wrong idea next to the
            -- "add all books in a folder" import.
            emoji = "\u{1F5C2}\u{FE0F}",
            callback = "showBookGroupsManager",
            separator = true,
        },

        -- Provider & Model hub (top-level; merged from the old two rows,
        -- maintainer 2026-08-14 — one entry, providers unfold their model
        -- panels, model pick switches provider+model in one tap)
        {
            id = "provider_model",
            type = "submenu",
            emoji = "🤖",
            text_func = function(plugin)
                local f = plugin.settings:readSetting("features") or {}
                local provider = f.provider or "anthropic"
                return T(_("Model: %1 (%2)"), plugin:getCurrentModel(),
                    plugin:getProviderDisplayName(provider))
            end,
            callback = "buildProviderModelHub",
        },
        {
            id = "api_keys",
            type = "submenu",
            -- "& Auth" (maintainer 2026-08-14): the menu also hosts non-key access
            -- methods — OpenAI Subscription's OAuth connect today, the planned
            -- item-25a subscription providers later.
            text = _("API Keys & Auth"),
            emoji = "🔑",
            callback = "buildApiKeysMenu",
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
                            id = "chat_exchange_page_breaks",
                            type = "toggle",
                            text = _("Latest Reply on New Page"),
                            path = "features.chat_exchange_page_breaks",
                            default = true,
                            help_text = _("Present the newest reply from the top of a fresh page. Markdown chats get a real page break before it (older exchanges stay compact — the break moves forward with each reply and never touches saves or exports); Plain Text chats align the view so the reply starts the screen. Chat viewer only."),
                        },
                        {
                            id = "scroll_to_last_message",
                            type = "toggle",
                            text = _("Open Chats at Latest Exchange"),
                            path = "features.scroll_to_last_message",
                            default = true,
                            help_text = _("When opening a saved chat, jump to the newest question and reply instead of the top. Replies always land on the newest exchange regardless of this setting. Independent of New Page per Exchange (that one changes the page layout; this one changes where an opened chat starts)."),
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
                            -- Deliberately false while qs_left_align is true (maintainer
                            -- 2026-07-25): the QA panel has always rendered centered by
                            -- default; the old default=true here only made the toggle
                            -- DISPLAY on while code behaved off (defaults sweep M8).
                            default = false,
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
                    id = "chat_window_size",
                    type = "dropdown",
                    text = _("Window Size"),
                    path = "features.chat_window_size",
                    default = "standard",
                    options = {
                        { value = "standard", label = _("Standard") },
                        { value = "expanded", label = _("Expanded") },
                    },
                    help_text = _("How much of the screen chat, artifact, translate, dictionary and quiz windows take. Expanded leaves only a hairline around them (and keeps KOReader's status bar visible while a book is open), which fits more text but leaves less room to tap outside. Also on each window's gear menu. Compact dictionary popups are not affected."),
                    -- Dropdown on_change is (value, plugin, old_value). Push
                    -- straight into the constants so windows opened before the
                    -- next updateConfigFromSettings already follow it.
                    on_change = function(value, plugin)
                        require("koassistant_ui.constants").setExpandedWindows(value == "expanded")
                        if plugin and plugin.updateConfigFromSettings then
                            plugin:updateConfigFromSettings()
                        end
                    end,
                    separator = true,
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
                        { value = "nb_NO", label = "Norsk bokmål (Norwegian)" },
                        { value = "nl_NL", label = "Nederlands (Dutch)" },
                        { value = "pl", label = "Polski (Polish)" },
                        { value = "pt", label = "Português (Portuguese)" },
                        { value = "pt_BR", label = "Português do Brasil" },
                        { value = "ru", label = "Русский (Russian)" },
                        { value = "sv", label = "Svenska (Swedish)" },
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
                            help_text = _("Follow the arriving text while a response streams. Scrolling up pauses the follow for that response so you can read in place while the rest arrives; the Autoscroll button in the streaming window turns it back on."),
                        },
                        {
                            id = "stream_keep_read_position",
                            type = "toggle",
                            text = _("Keep Reading Position"),
                            path = "features.stream_keep_read_position",
                            default = true,
                            depends_on = { id = "enable_streaming", value = true },
                            help_text = _("If auto-scroll is off or paused and you are reading while the response streams, the finished chat opens where you were reading instead of at the newest reply. In Markdown it opens on the page containing your spot; in Plain Text your spot starts the view."),
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
                            id = "quick_answer_default",
                            type = "toggle",
                            text = _("Quick Answer On by Default"),
                            path = "features.quick_answer_default",
                            default = false,
                            help_text = _("Start new chats with the Quick Answer (⚡) button already on. You can still turn it off per chat: and override the default per book from Book Settings or the ⚡ button's menu."),
                        },
                        {
                            -- One 3-way control over the two stored keys
                            -- (quick_preset_nudge default true, _strict default
                            -- false — read patterns unchanged): the two nudge
                            -- texts are mutually exclusive, so two toggles were
                            -- misleading (maintainer 2026-08-11).
                            id = "quick_preset_nudge_mode",
                            type = "action",
                            text_func = function(plugin)
                                local f = plugin.settings:readSetting("features") or {}
                                return T(_("Brevity nudge: %1"),
                                    require("koassistant_dialogs").quickPresetNudgeLabel(f))
                            end,
                            help_text = _("How strongly Quick Answer asks for brevity: Standard requests a short, direct reply (a few sentences, no preamble); Ultra-brief enforces a hard ceiling (at most 3 short sentences, one plain paragraph, never restate the question); Off sends no brevity instruction."),
                            callback = "showQuickPresetNudge",
                            keep_menu_open = true,
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
                        },
                        {
                            id = "quick_preset_skip_domain",
                            type = "toggle",
                            text = _("Skip Domain Lens"),
                            path = "features.quick_preset_skip_domain",
                            default = false,
                            help_text = _("Leave the selected domain lens out of Quick Answer chats. Off by default: the domain shapes identity rather than length, and costs almost nothing in speed."),
                        },
                        {
                            id = "quick_preset_skip_background",
                            type = "toggle",
                            text = _("Skip Book Background"),
                            path = "features.quick_preset_skip_background",
                            default = false,
                            help_text = _("Leave the per-book Background note out of Quick Answer chats. Off by default: the Background frames how you read this book, and costs almost nothing in speed."),
                        },
                        {
                            id = "quick_preset_behavior",
                            type = "action",
                            text_func = function(plugin)
                                local f = plugin.settings:readSetting("features") or {}
                                return T(_("Behavior: %1"),
                                    require("koassistant_dialogs").quickPresetBehaviorLabel(f))
                            end,
                            help_text = _("Optionally change the AI behavior while Quick Answer is on: keep the current one (default), swap to its Mini variant (same style family when one exists), pin a specific behavior (the built-in Terse suits Quick Answer), or send none at all. Actions that pin a behavior are unaffected."),
                            callback = "showQuickPresetBehavior",
                            keep_menu_open = true,
                            separator = true,
                        },
                        {
                            id = "quick_preset_model_mode",
                            type = "action",
                            text_func = function(plugin)
                                local f = plugin.settings:readSetting("features") or {}
                                local mode = f.quick_preset_model_mode or "none"
                                local label
                                if mode == "fastest" then
                                    label = _("Fastest for provider")
                                elseif mode == "tier" then
                                    local ModelLists = require("koassistant_model_lists")
                                    label = T(_("%1 tier"), ModelLists.normalizeTier(f.quick_preset_tier or "fast"))
                                elseif mode == "model" then
                                    label = f.quick_preset_model or "?"
                                else
                                    label = _("Keep current")
                                end
                                return T(_("Model override: %1"), label)
                            end,
                            help_text = _("Optionally switch models while Quick Answer is on (that chat only: your default model is untouched): the active provider's fastest listed model, a tier of the active provider, or a pinned specific model. Custom providers keep the current model unless custom_models.lua gives them tier placements. A one-shot model pick in the Quick chip's menu overrides this."),
                            callback = "showQuickPresetModelMode",
                            keep_menu_open = true,
                        },
                    },
                },
                {
                    id = "spoiler_free_chat",
                    type = "toggle",
                    text = _("Spoiler Protection"),
                    path = "features.spoiler_free_chat",
                    -- §4.3 flip (2026-08-11): protection ON by default. Read
                    -- sites check ~= false; the resolver's "default" branch is
                    -- the single flip point for requests AND X-Ray promotion.
                    default = true,
                    help_text = _("On by default: the AI is told not to reveal events beyond your current reading position in book and highlight chats, and X-Ray checkpoint updates follow your position instead of installing the newest version. Research mode disables protection. Override per book in Book Settings; per chat via the Spoiler chip (chat input's gear menu → Toolbar Buttons). Custom actions can use the {spoiler_free_nudge} placeholder."),
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
        -- Chapter Quiz and X-Ray are nested submenus (2026-08-12 split — the flat
        -- section ran 27 rows / 3 pages); recap reminder, end-of-book and library
        -- scanning stay flat under their headers
        {
            id = "reading_and_library",
            type = "submenu",
            text = _("Reading & Library"),
            emoji = "📖",
            items = {
                -- Chapter Quiz (own submenu since the 2026-08-12 section split)
                {
                    id = "chapter_quiz_menu",
                    type = "submenu",
                    text_func = function(plugin)
                        local f = plugin.settings:readSetting("features") or {}
                        return T(_("Chapter Quiz: %1"),
                            f.enable_chapter_quiz == true and _("On") or _("Off"))
                    end,
                    items = {
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
                        },
                    },
                },
                -- X-Ray settings home (2026-08-12 split): automation, checkpoints,
                -- versions, and the spoiler mirror that steers checkpoint promotion
                {
                    id = "xray_settings_menu",
                    type = "submenu",
                    text = _("X-Ray"),
                    items = {
                        {
                            id = "xray_auto_update",
                            type = "toggle",
                            text = _("Automatic X-Ray (all books)"),
                            path = "features.xray_auto_update",
                            default = false,
                            help_text = _("Automatically build and maintain every book's X-Ray as you read (flowing formats like EPUB only): a spoiler-free introduction first, then checkpoints at chapter-sized steps, always keeping the next checkpoint ready ahead of you; reaching it installs it instantly and the one after starts building. Individual books can override this either way: X-Ray popup or Book Settings → Automatic X-Ray; a per-book On works even with this off, and a per-book Off always wins.\n\nSpend guards: at most one background build per cooldown, WiFi only, and text-extraction consent (or a trusted provider) required; background runs extract book text and use API tokens without a per-request tap. Leave off if every request should be explicit."),
                            on_change = function(new_value, plugin)
                                -- Round 22 (R4 / known gap (a)): flipping the master with a
                                -- book open must reach that book immediately — refresh the
                                -- per-page state and, when turning ON, run the same engine
                                -- entry a book-open would (the coverage ask fires for
                                -- first-spend books; established books just restore the
                                -- one-ahead invariant).
                                if not plugin or not plugin._refreshXrayAutoState then return end
                                plugin:_refreshXrayAutoState()
                                if new_value == true and plugin._fireXrayAutoCheckpoints
                                        and plugin.ui and plugin.ui.document then
                                    local UIManager = require("ui/uimanager")
                                    UIManager:scheduleIn(1, function()
                                        plugin:_fireXrayAutoCheckpoints()
                                    end)
                                end
                            end,
                        },
                        {
                            id = "xray_auto_create",
                            type = "toggle",
                            text = _("Also Start X-Rays Automatically"),
                            path = "features.xray_auto_create",
                            default = false,
                            help_text = _("A sub-setting of Automatic X-Ray (all books), for books that have NO X-Ray yet: allow automation to make the FIRST build (introduction + checkpoints to your position; the first build asks how you want coverage, once per book). With this off, \"all books\" automation only maintains X-Rays you started yourself. Books with an existing non-incremental X-Ray (complete, AI-knowledge, legacy) are never touched.\n\nBooks switched to Automatic individually (per-book On) always build the first one, regardless of this setting."),
                            depends_on = { id = "xray_auto_update", value = true },
                        },
                        {
                            id = "xray_coverage_mode",
                            type = "dropdown",
                            text = _("First Build for New Books"),
                            path = "features.xray_coverage_mode",
                            default = "ask",
                            options = {
                                { label = _("Ask each book"), value = "ask" },
                                { label = _("Catch up, then follow"), value = "follow" },
                                { label = _("Build all checkpoints"), value = "build" },
                            },
                            help_text = _("How Automatic X-Ray handles its first build for a book. \"Ask each book\" shows a one-time choice per book. \"Catch up, then follow\" quietly builds checkpoints to your position and keeps one ahead. \"Build all checkpoints\" offers the full checkpoint build with its cost confirmation. The ask dialog's \"Always do this, for every book\" writes this setting too."),
                        },
                        {
                            id = "xray_offer_auto",
                            type = "toggle",
                            text = _("Offer Automatic X-Ray for New Books"),
                            path = "features.xray_offer_auto",
                            default = false,
                            help_text = _("When you open a book that has no X-Ray, ask once whether to turn on Automatic X-Ray for it. Only asks when it could act right away (flowing format, text-extraction consent in place). Declining turns the book's Automatic X-Ray off, so it never asks again for that book."),
                        },
                        -- (Round 21, unified engine: the min/max progress-gap dials are
                        -- retired — checkpoint spacing IS the increment. Stored values
                        -- are still read by dialsFromFeatures for the promotion
                        -- jump cap.)
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
                            help_text = _("Minimum wait before retrying an automatic checkpoint after one was declined, failed or cancelled (0 = no cooldown). A completed build does not wait."),
                            depends_on = { id = "xray_auto_update", value = true },
                        },
                        {
                            id = "xray_auto_notify",
                            type = "toggle",
                            text = _("Notify on Background Activity"),
                            path = "features.xray_auto_notify",
                            default = false,
                            help_text = _("Show a brief notification when a background X-Ray update or create starts and completes, and when a checkpoint is silently swapped in. Off = fully silent (the X-Ray popup always shows the current coverage)."),
                            separator = true,
                        },
                        {
                            id = "xray_ladder_chapter_snap",
                            type = "toggle",
                            text = _("Checkpoints at Chapter Ends"),
                            path = "features.xray_ladder_chapter_snap",
                            default = true,
                            help_text = _("When building X-Ray checkpoints, place each checkpoint at the nearest chapter end (within a few percent) instead of an exact percentage; checkpoints then read as \"up to the end of a chapter\", and the versions list shows the chapter names. Needs a table of contents. Checkpoint spacing itself adapts to book length: about every 10% of a normal-length book, larger steps for short ones."),
                        },
                        {
                            id = "xray_default_categories_picker",
                            type = "action",
                            text = _("Categories for New X-Rays"),
                            callback = "showXrayDefaultCategoriesPicker",
                            help_text = _("Which category groups a new X-Ray tracks by default: everything, or a narrower preset such as Reference (no timeline) or Characters only. Applies when an X-Ray is created or rebuilt; individual books can pick their own categories in Book Settings."),
                        },
                        {
                            id = "xray_default_depth_picker",
                            type = "action",
                            text = _("Depth of New X-Rays"),
                            callback = "showXrayDefaultDepthPicker",
                            help_text = _("How much each X-Ray entry carries by default. Light: one line per entry, only recurring figures and turning points, about half the cost. Standard: a few sentences per entry, everything the reader meets. Deep: longer entries, every figure and development, richer connections. Applies when an X-Ray is created or rebuilt; checkpoints and updates keep the depth the X-Ray was started with. Individual books can pick their own depth in Book Settings."),
                        },
                        {
                            id = "xray_selection_intercept",
                            type = "toggle",
                            text = _("X-Ray Entry for Matching Selections"),
                            path = "features.xray_selection_intercept",
                            default = true,
                            help_text = _("When a tapped word or selected text exactly matches an X-Ray entity's name or alias, open that X-Ray entry directly — skipping ahead of the dictionary and the highlight menu (including any bypass actions you have set there). Anything that doesn't match falls through to your normal dictionary/highlight behavior. Only does anything for books that have an X-Ray. A very long press at the end of a selection always shows the normal highlight menu."),
                            on_change = function(new_value, plugin)
                                -- The dictionary wrapper is installed/removed at sync
                                -- time (the highlight side reads per call)
                                if plugin.syncDictionaryBypass then
                                    local UIManager = require("ui/uimanager")
                                    UIManager:nextTick(function()
                                        plugin:syncDictionaryBypass()
                                    end)
                                end
                            end,
                        },
                        {
                            id = "xray_marking",
                            type = "toggle",
                            text = _("Passive Marking"),
                            path = "features.xray_marking",
                            default = true,
                            help_text = _("Discreetly underline words on the page that match an X-Ray entity's name or alias, as you read (dotted gray, drawn shortly after the page settles; entirely on-device). Tap a marked word to open its entry. Only active for books that have an X-Ray. EPUB page mode only."),
                            on_change = function(new_value, plugin)
                                if plugin.syncXrayMarks then
                                    local UIManager = require("ui/uimanager")
                                    UIManager:nextTick(function()
                                        plugin:syncXrayMarks()
                                    end)
                                end
                            end,
                        },
                        {
                            id = "xray_marking_tap",
                            type = "toggle",
                            text = _("Tap Marked Words to Open"),
                            path = "features.xray_marking_tap",
                            default = true,
                            help_text = _("With passive marking on, a plain tap on a marked word opens its X-Ray entry, like a link (real links in the text still win). Off = marks are visual only; a long press still opens matching entries via \"X-Ray Entry for Matching Selections\"."),
                            on_change = function(new_value, plugin)
                                if plugin.syncXrayMarks then
                                    local UIManager = require("ui/uimanager")
                                    UIManager:nextTick(function()
                                        plugin:syncXrayMarks()
                                    end)
                                end
                            end,
                        },
                        {
                            id = "xray_show_ahead_entities",
                            type = "toggle",
                            text = _("Upcoming Entities"),
                            path = "features.xray_show_ahead_entities",
                            default = true,
                            help_text = _("Let marking, matching selections and entity cards recognize entities that first appear past your installed X-Ray coverage, using only the next checkpoint built past your reading position (never a later one). Identification only: such names get short-dash marks and a card that, by default, shows just the tapped name until you ask for the entry. Off = the plugin only knows entities up to your installed coverage."),
                            on_change = function(new_value, plugin)
                                if plugin.syncXrayMarks then
                                    local UIManager = require("ui/uimanager")
                                    UIManager:nextTick(function()
                                        plugin:syncXrayMarks()
                                    end)
                                end
                            end,
                        },
                        {
                            id = "xray_ahead_card",
                            type = "radio",
                            text_func = function(plugin)
                                local f = plugin.settings:readSetting("features") or {}
                                return T(_("Upcoming Entity Cards: %1"),
                                    require("koassistant_book_settings").xrayAheadCardLabel(f.xray_ahead_card))
                            end,
                            path = "features.xray_ahead_card",
                            default = "name",
                            options = {
                                { value = "name", text = _("Name only, tap to show a one-line description") },
                                { value = "entry", text = _("First sentence right away") },
                            },
                            help_text = _("What the card shows first for an upcoming entity, known only from the next checkpoint built ahead of you. Name only shows the tapped name and its category; a tap on the card adds the entry's first sentence, and another tap opens the full entry behind a spoiler confirmation. First sentence right away skips the first step (it can reveal that a name is another character's alias). Can be overridden per book."),
                            enabled_func = function(plugin)
                                local f = plugin.settings:readSetting("features") or {}
                                return f.xray_show_ahead_entities ~= false
                            end,
                        },
                        {
                            id = "xray_card_length",
                            type = "radio",
                            text_func = function(plugin)
                                local f = plugin.settings:readSetting("features") or {}
                                return T(_("Card Shows: %1"),
                                    require("koassistant_book_settings").xrayCardLengthLabel(f.xray_card_length))
                            end,
                            path = "features.xray_card_length",
                            default = "sentence",
                            options = {
                                { value = "sentence", text = _("First sentence only") },
                                { value = "full", text = _("Full entry") },
                            },
                            help_text = _("How much of an entry the card shows for entities already in your installed X-Ray. First sentence keeps the card to a one-line identification, with the full entry a tap away. Full entry shows the whole description (swipe to scroll the footnote panel; the floating popup cuts it where it runs out of room). Can be overridden per book."),
                        },
                        {
                            id = "xray_card_landing",
                            type = "toggle",
                            text = _("Entity Card First"),
                            path = "features.xray_card_landing",
                            default = true,
                            help_text = _("Exact entity hits (tapping a marked word, or selecting text that matches an entity) open a compact card first: the name, category and role, and a one-line identification, with the full entry a tap on the card away. The identification may come from the newest built checkpoint, so newly appearing names are known on sight — the full entry stays at your reading position, behind a confirmation, while spoiler protection is on. Off = open the full entry directly."),
                            on_change = function(new_value, plugin)
                                if plugin.syncXrayMarks then
                                    local UIManager = require("ui/uimanager")
                                    UIManager:nextTick(function()
                                        plugin:syncXrayMarks()
                                    end)
                                end
                            end,
                        },
                        {
                            id = "xray_card_style",
                            type = "radio",
                            text_func = function(plugin)
                                local f = plugin.settings:readSetting("features") or {}
                                local mode = f.xray_card_style or "footnote"
                                local labels = {
                                    footnote = _("Footnote Panel"),
                                    popup = _("Floating Popup"),
                                }
                                return T(_("Card Style: %1"), labels[mode] or mode)
                            end,
                            path = "features.xray_card_style",
                            default = "footnote",
                            options = {
                                { value = "footnote", text = _("Footnote panel (bottom of the screen)") },
                                { value = "popup", text = _("Floating popup (near the tapped word)") },
                            },
                            help_text = _("How the entity card is presented. The footnote panel slides in at the bottom of the screen, like KOReader's footnote popups, and follows the book's margins and font size. The floating popup is a small window anchored next to the tapped word. In both, tapping the card opens the full entry; tapping elsewhere dismisses it."),
                        },
                        {
                            id = "xray_marking_density",
                            type = "radio",
                            text_func = function(plugin)
                                local f = plugin.settings:readSetting("features") or {}
                                local mode = f.xray_marking_density or "10"
                                local labels = {
                                    all = _("All Occurrences"),
                                    first = _("Once per Page"),
                                    ["10"] = _("After 10 Unseen Pages"),
                                    ["25"] = _("After 25 Unseen Pages"),
                                    once = _("First Appearance Only"),
                                }
                                return T(_("Marking Density: %1"), labels[mode] or mode)
                            end,
                            path = "features.xray_marking_density",
                            default = "10",
                            options = {
                                { value = "first", text = _("Once per page") },
                                { value = "10", text = _("Only after 10 unseen pages") },
                                { value = "25", text = _("Only after 25 unseen pages") },
                                { value = "once", text = _("First appearance only") },
                                { value = "all", text = _("All occurrences") },
                            },
                            help_text = _("How often an entity gets marked. Once per page marks its first occurrence on every page it appears. The unseen-pages options re-mark it only after it has been absent that long, so newly returning names stand out while constant companions stay quiet. First appearance marks it once in the whole book; all occurrences marks every one."),
                            on_change = function(new_value, plugin)
                                if plugin.syncXrayMarks then
                                    local UIManager = require("ui/uimanager")
                                    UIManager:nextTick(function()
                                        plugin:syncXrayMarks()
                                    end)
                                end
                            end,
                        },
                        {
                            id = "xray_marking_families",
                            type = "radio",
                            text_func = function(plugin)
                                local f = plugin.settings:readSetting("features") or {}
                                local mode = f.xray_marking_families or "all"
                                local labels = {
                                    all = _("All Entities"),
                                    people = _("People Only"),
                                    people_places = _("People & Places"),
                                }
                                return T(_("Mark: %1"), labels[mode] or mode)
                            end,
                            path = "features.xray_marking_families",
                            default = "all",
                            options = {
                                { value = "all", text = _("All entities") },
                                { value = "people", text = _("People only") },
                                { value = "people_places", text = _("People and places") },
                            },
                            help_text = _("Which kinds of X-Ray entities get marked on the page. People covers characters and key figures; places adds locations."),
                            on_change = function(new_value, plugin)
                                if plugin.syncXrayMarks then
                                    local UIManager = require("ui/uimanager")
                                    UIManager:nextTick(function()
                                        plugin:syncXrayMarks()
                                    end)
                                end
                            end,
                        },
                        {
                            id = "xray_appearances_rows",
                            type = "radio",
                            text_func = function(plugin)
                                local f = plugin.settings:readSetting("features") or {}
                                local mode = f.xray_appearances_rows or "compact"
                                return T(_("Chapter Appearances Rows: %1"),
                                    mode == "follow_toc" and _("KOReader ToC Settings") or _("Compact"))
                            end,
                            path = "features.xray_appearances_rows",
                            default = "compact",
                            options = {
                                { value = "compact", text = _("Compact (20 rows per page)") },
                                { value = "follow_toc", text = _("Follow KOReader's ToC settings") },
                            },
                            help_text = _("Row density for the Chapter Appearances tree in the X-Ray browser. Compact fits 20 rows per page; the other option follows KOReader's own Table of Contents items-per-page and font-size settings."),
                            separator = true,
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
                            help_text = _("Whenever an update or redo overwrites the X-Ray, the outgoing version is archived: browse, view, or restore them via \"All versions\" in the X-Ray popup and browser menu. This sets how many are kept per book; the versions covering the least of the book are dropped first, oldest first among equally covering ones. 0 stops archiving new versions; already-archived ones stay until you delete them or the X-Ray itself. Checkpoints are stored separately and are never trimmed by this."),
                            separator = true,
                        },
                        {
                            id = "xray_connection_buttons",
                            type = "spinner",
                            text = _("Connection Buttons per Entry"),
                            path = "features.xray_connection_buttons",
                            default = 9,
                            min = 0,
                            max = 30,
                            step = 1,
                            precision = "%d",
                            help_text = _("An entity page turns each of its connections into a tappable button. A richly connected character can carry dozens, which crowd the description off the screen. This caps how many BOXES the connection block may use: past it the last box becomes an overflow row opening the full list. At or under it every connection is drawn and the list lives in the entry's More menu. Repeated links to the same entity are always collapsed, whatever this is set to. 0 draws no buttons and lists every connection instead."),
                            separator = true,
                        },
                        {
                            id = "spoiler_free_chat_xray",
                            type = "toggle",
                            text = _("Spoiler Protection"),
                            path = "features.spoiler_free_chat",
                            default = true,
                            help_text = _("Mirrors the Spoiler Protection setting in Chat & Export Settings. It also lives here because it steers X-Ray updates: when on, checkpoint installs follow your reading position; when off, the newest built checkpoint installs right away. Override per book in Book Settings (the Spoiler Protection and X-Ray updates rows)."),
                        },
                    },
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
            -- 🌍 like every other language surface (QS Language/Translate/Dictionary
            -- chips, Translate Settings) — 🌐 is the web-search glyph (action
            -- indicators, Web chip) and must not double as language
            emoji = "🌍",
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
                        -- Must match BookSettings.resolveDictionaryContext (D1: "sentence")
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
                    help_text = _("How much text around the looked-up word is sent with dictionary actions. The Ctx button on the dictionary popup toggles it per lookup; Book Settings can override it per book."),
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
                        local action_id = f.dictionary_bypass_action or "quick_define"
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
                        return (f.translate_hide_highlight_mode or "hide_long") == "hide_long"
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

        -- Minimal Popup (chrome-less anchored response popup — registered actions only)
        {
            id = "minimal_popup_settings",
            type = "submenu",
            text = _("Minimal Popup"),
            emoji = "💬",
            items = {
                {
                    id = "minimal_popup_mode",
                    type = "dropdown",
                    text = _("Minimal Popup View"),
                    path = "features.minimal_popup_mode",
                    -- Internal value "short" predates the fit-based rename; it now
                    -- means "when it fits" (no migration — semantics only sharpened).
                    default = "short",
                    options = {
                        { value = "off", label = _("Off") },
                        { value = "short", label = _("When it fits") },
                        { value = "always", label = _("Always") },
                    },
                    help_text = _("Show responses from the actions below in a small popup next to the highlighted text: just the response, no buttons. Tap the popup to open the full window; tap outside to dismiss. 'When it fits' shows the popup only when the whole response fits inside it; longer responses open the full window directly. 'Always' shows the popup regardless, trimmed with an ellipsis. Streaming is skipped for these requests. Never applies to full-page translation."),
                },
                {
                    id = "minimal_popup_actions",
                    type = "submenu",
                    text_func = function(plugin)
                        local f = plugin.settings:readSetting("features") or {}
                        local set = Constants.resolveMinimalPopupActions(f.minimal_popup_actions)
                        local n = 0
                        for _k in pairs(set) do n = n + 1 end
                        return T(_("Actions Using Minimal Popup: %1"), n)
                    end,
                    callback = "buildMinimalPopupActionsMenu",
                    help_text = _("Which highlight actions open in the minimal popup. Translate and Quick Define by default."),
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
                    id = "highlight_context_direction",
                    type = "dropdown",
                    text = _("Context Direction"),
                    path = "features.highlight_context_direction",
                    default = "both",
                    options = {
                        { value = "both", label = _("Both sides") },
                        { value = "before", label = _("Before the selection only") },
                    },
                    help_text = _("Which side of the selection surrounding context is taken from. Also applies to dictionary context. While spoiler protection is on for a book, the after side is additionally limited by the next setting."),
                },
                {
                    id = "spoiler_context_limit",
                    type = "dropdown",
                    text = _("Context Under Spoiler Protection"),
                    path = "features.spoiler_context_limit",
                    default = "paragraph",
                    options = {
                        { value = "selection", label = _("Nothing after the selection") },
                        { value = "sentence", label = _("To the end of its sentence") },
                        { value = "paragraph", label = _("To the end of its paragraph") },
                        { value = "off", label = _("No limit") },
                    },
                    help_text = _("How far past the selection context may reach while spoiler protection is on. The context window can otherwise include up to 1000 characters after the selection, which may be text you have not read yet; the sentence or paragraph you are selecting from is on the page in front of you. Applies to highlight and dictionary context."),
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
                    -- Not "browse_notebooks" — that id belongs to the main-menu
                    -- row and getItemById requires uniqueness across the schema
                    id = "browse_notebooks_settings",
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
                    help_text = _("What to include when saving to notebook.\nQ&A includes the highlighted text + your question + the response. Full Q&A adds anything you attached with the paperclip (notes, artifacts, chats, files)."),
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
                    help_text = _("Providers you trust bypass all data sharing controls below AND text extraction. All data types (highlights, annotations, notebook, book text) are available without toggling individual settings. Use for local Ollama instances or providers you fully trust.\n\nTrust also satisfies the consent that background features (such as Automatic X-Ray and X-Ray checkpoint builds) check before running; those can then extract text and spend tokens without a per-request tap."),
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
                -- Per-book override pattern, made explicit (device note 2026-08-13)
                {
                    id = "privacy_per_book_tip",
                    type = "action",
                    text = _("Tip: Per-book overrides"),
                    help_text = _("Every sharing toggle here can be overridden per book (Book Settings → Privacy). Two patterns: keep a global toggle off and allow it for specific books, or keep it on and deny it for sensitive books. A per-book deny always wins — even over trusted providers."),
                    callback = "showPrivacyOverridesTip",
                    keep_menu_open = true,
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
                    help_text = _("Share your highlighted text passages with the AI. Used by Recap, Analyze Notes, and actions with {highlights} placeholders. Does not include personal notes. X-Ray does not send them: it only matches them locally, to offer them on an entity page."),
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
                            help_text = _("When enabled, actions can extract and send book text to the AI. Used by X-Ray, Recap, and actions with text placeholders.\n\nThis consent also covers background features you opt into separately (such as Automatic X-Ray and X-Ray checkpoint builds): those extract text and spend API tokens without a per-request confirmation, within their own size guards. Revoking this consent stops them.\n\nTip: Use Hidden Flows to exclude front matter, appendices, etc. You can also focus actions on a specific section or section range to extract only a chapter or part; for X-Ray, checkpoints cover the book in bounded incremental steps."),
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
                                        text = _("Text extraction sends actual book content to the AI. This uses tokens (increases API costs) and processing time. Features like X-Ray and Recap use this to analyze your reading progress.\n\nBackground features you opt into separately (such as Automatic X-Ray) will also extract text without asking per request.\n\nTip: Use Hidden Flows to exclude front matter, appendices, etc. You can also focus actions on a specific section or section range to extract only a chapter or part; for X-Ray, checkpoints cover the book in bounded incremental steps."),
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
                            help_text = _("When unchecked, a blocking warning is shown before sending requests when extracted text was truncated to fit the character limit. Shows coverage percentage so you know how much of the book was included.\n\nBackground runs (Automatic X-Ray, checkpoint builds) never show this warning: a truncated background extraction aborts the run instead of sending dishonest coverage.\n\nCheck this if you don't need the reminder."),
                            depends_on = { id = "enable_book_text_extraction", value = true },
                        },
                        {
                            id = "suppress_large_extraction_warning",
                            type = "toggle",
                            text = _("Don't warn about large extractions"),
                            path = "features.suppress_large_extraction_warning",
                            default = false,
                            help_text = _("When unchecked, a warning is shown before sending requests with large text extractions (over 500K characters / ~125K tokens). Most models have smaller context windows and will reject oversized requests.\n\nBackground runs (Automatic X-Ray, checkpoint builds) never show this warning; their size is bounded instead: automatic updates by the Maximum Progress Gap, checkpoints by their incremental steps.\n\nCheck this if you know your model's limits and don't need the reminder."),
                            depends_on = { id = "enable_book_text_extraction", value = true },
                        },
                        {
                            id = "clear_action_cache",
                            type = "action",
                            text = _("Delete Book Artifacts"),
                            help_text = _("Delete every saved artifact for the current book: the X-Ray (with its archived versions and checkpoints), summaries, analyses and wiki entries. They regenerate from scratch next time you run the actions."),
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
                    -- Opt-in since the A9 follow-up 2026-08-17 (pare-down;
                    -- read pattern in main.lua is `== true` to match)
                    default = false,
                    help_text = _("Add an 'Add to notebook' button to the highlight menu, saving the selected text directly to this book's notebook. Takes effect the next time the menu opens."),
                },
                -- (The old "Show Generate Image button" toggle is retired:
                -- image generation is the image_gen ACTION since 2026-08-13 —
                -- visibility/order via Highlight Menu Actions below; an
                -- explicit old OFF was migrated to a menu dismissal.)
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
                -- Input dialogs (A9 round 2 2026-08-17: the utility buttons
                -- were the only input-dialog rows without a settings surface —
                -- action rows have the managers, chips have Toolbar Buttons)
                {
                    id = "input_dialog_header",
                    type = "header",
                    text = _("Input dialogs"),
                },
                {
                    id = "show_artifacts_in_input",
                    type = "toggle",
                    text = _("Show View Artifacts button"),
                    path = "features.show_artifacts_in_input",
                    default = true,
                    help_text = _("Show the 'View Artifacts' button in book and highlight input dialogs. It only appears for books that have artifacts. Takes effect the next time the dialog opens."),
                },
                {
                    id = "show_group_in_input",
                    type = "toggle",
                    text = _("Show Group button"),
                    path = "features.show_group_in_input",
                    default = true,
                    help_text = _("Show the 'Group' button in input dialogs for books that belong to a group. Takes effect the next time the dialog opens."),
                },
                {
                    id = "input_dialog_actions",
                    type = "action",
                    text = _("Input Dialog Actions"),
                    callback = "showInputActionsChooser",
                    help_text = _("Choose which actions appear in each input dialog (open book, closed book, highlight, X-Ray chat, library, general). Toolbar chips are configured from the input dialog's gear menu (Toolbar Buttons)."),
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
                    help_text = _("Add KOAssistant buttons to file browser context menus."),
                    on_change = function(new_value, plugin)
                        -- Live since the A9 sitting 2026-08-17 (maintainer: "are you
                        -- sure it can't be re-registered?"): the registered rows are
                        -- closures rebuilt per dialog open, so only this
                        -- register/unregister pair needed wiring — the old row said
                        -- "requires restart" while removeFileDialogButtons sat
                        -- uncalled. The setting is written before on_change runs, so
                        -- addFileDialogButtons' fresh feature read passes its gate.
                        if not plugin then return end
                        if new_value == false then
                            if plugin.removeFileDialogButtons then
                                plugin:removeFileDialogButtons()
                            end
                        elseif plugin.addFileDialogButtons then
                            plugin:addFileDialogButtons()
                        end
                    end,
                },
                -- Utility-button toggles in POPUP ORDER (File Browser Items
                -- round 2026-08-13); the File Browser Items manager mirrors
                -- these rows — same features.* keys, both surfaces in sync
                {
                    id = "show_chat_action_in_file_browser",
                    type = "toggle",
                    text = _("Show Chat/Action button"),
                    path = "features.show_chat_action_in_file_browser",
                    default = true,
                    help_text = _("Show 'Chat/Action' button when long-pressing books in the file browser."),
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
                    id = "show_chat_history_in_file_browser",
                    type = "toggle",
                    text = _("Show Chat History button"),
                    path = "features.show_chat_history_in_file_browser",
                    default = true,
                    help_text = _("Show 'Chat History' button when long-pressing books in the file browser. Only appears for books with saved chats."),
                },
                {
                    id = "show_artifacts_in_file_browser",
                    type = "toggle",
                    text = _("Show View Artifacts button"),
                    path = "features.show_artifacts_in_file_browser",
                    default = true,
                    help_text = _("Show 'View Artifacts' button when long-pressing books in the file browser. Only appears for books with artifacts."),
                },
                {
                    -- A4 follow-up (2026-08-11): the Book Hub utility button gets
                    -- the Notebook button's visibility-toggle shape
                    id = "show_book_hub_in_file_browser",
                    type = "toggle",
                    text = _("Show Book Hub button"),
                    path = "features.show_book_hub_in_file_browser",
                    default = true,
                    help_text = _("Show 'Book Hub' button when long-pressing books in the file browser."),
                },
                {
                    id = "show_book_settings_in_file_browser",
                    type = "toggle",
                    text = _("Show Book Settings button"),
                    path = "features.show_book_settings_in_file_browser",
                    default = true,
                    help_text = _("Show 'Book Settings' button when long-pressing books in the file browser."),
                },
                {
                    id = "file_browser_actions",
                    type = "action",
                    text = _("File Browser Items"),
                    callback = "showFileBrowserActionsManager",
                    help_text = _("Choose which buttons and actions appear in the file browser long-press menu."),
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
                    id = "shortcuts_screen",
                    type = "action",
                    text = _("Shortcuts"),
                    callback = "showShortcutsScreen",
                    help_text = _("See and change the gestures bound to KOAssistant's panels and actions. Assignments apply immediately, no restart needed."),
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
                -- (The old tail "Input dialog" header + gear-pointer info row is
                -- gone since round 4 2026-08-17: superseded by the Input dialogs
                -- section above — its id also collided with that section's header.)
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
                    help_text = _("Finds books whose KOAssistant data (artifacts, chats, notebooks, pinned) exists on disk but doesn't show in this device's browsers, e.g. after syncing sidecar files from another device, restoring a backup, or migrating devices.\n\nChecks your reading history, KOReader's sidecar locations, and the scan folders configured below, then removes stale entries. Books on unmounted storage get pruned; run again with the storage mounted to re-add them.\n\nMay take a while on large libraries."),
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
                    help_text = _("Folders to scan during index rebuild: point this at your synced book folders. Only these folders are ever scanned, and only when a rebuild runs. Folders that don't exist on this device are skipped.\n\nNote: a settings reset clears this list."),
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
                            help_text = _("Include reasoning in the combined usage indicator line (e.g. '*[Reasoning/Thinking was used]*') when reasoning is requested or used.\n\nFull reasoning content is always viewable via 'Show Reasoning' button."),
                            path = "features.show_reasoning_indicator",
                            default = true,
                            separator = true,
                        },
                    },
                },
                -- Temperature (moved from the top level 2026-08-14: a dial a growing
                -- share of models ignore doesn't earn a slot beside the provider hub;
                -- Reasoning is its natural sibling — both are model-behavior dials).
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
                    info_text = _("Range: 0.0-2.0 (Anthropic max 1.0)\nLower = focused, deterministic\nHigher = creative, varied\n\nApplies to free-form chat: most built-in actions set their own temperature."),
                    -- Item 19c: a growing share of models ignore or pin temperature. Annotate
                    -- rather than disable — this is a GLOBAL default that still applies to every
                    -- other model the reader switches to (same rule as the QS web-search tile).
                    suffix_func = function(plugin)
                        local f = plugin.settings:readSetting("features") or {}
                        local mode = ModelConstraints.temperatureSupport(
                            f.provider or "anthropic", plugin:getCurrentModel())
                        if mode == "rejected" then return _("ignored by this model") end
                        if mode == "forced" then return _("fixed by this model") end
                        return nil
                    end,
                    -- Static on purpose: settings_manager evaluates help_text ONCE at menu-build
                    -- time, so a model-specific string would go stale after switching models via
                    -- the Model row without leaving the menu. The live per-model state rides on
                    -- suffix_func above, which is re-evaluated on every render.
                    help_text = _("Applies to free-form chat: most built-in actions set their own temperature.\nSome models ignore this setting or accept only a fixed value; the row says so when the current model is one of them."),
                    separator = true,
                },
                -- Per-action model tiers (feature plan item 18e): actions carrying a
                -- model_tier hint switch to a faster model of the SAME provider for
                -- that request — model only, prompt/reasoning unchanged. ON by default
                -- (maintainer 2026-08-03: a tier set in the action editor must just
                -- work — hiding it behind an opt-in was a trap); this toggle is the
                -- global kill-switch for users who want uniform model behavior.
                {
                    id = "use_action_tiers",
                    type = "toggle",
                    text = _("Faster Models for Quick Actions"),
                    path = "features.use_action_tiers",
                    default = true,
                    help_text = _("Actions that declare a speed tier (Translate and Quick Define by default; configurable per action in the action editor) use a faster model from your current provider for that request. Only the model changes — the prompt and settings stay the same. Providers without tier data keep the current model. Turn off to always use your configured model."),
                },
                -- Global tier pins (tier GUI phase 2, docs/tier_gui_plan.md):
                -- each slot follows the active provider's ladder by default, or
                -- pins one provider+model that tier-invoking requests switch to
                -- for that request only. Screen built in main.lua.
                {
                    id = "global_tier_pins",
                    type = "submenu",
                    text = _("Tier Models (Global)"),
                    callback = "buildGlobalTierMenu",
                    separator = true,
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
                            help_text = T(_("Allow AI to search the web for current information.\n\nSupported providers: %1.\n\nGemini supports it only on Search-grounding-capable models; OpenAI on GPT-5 models and xAI on Grok-4 models (via their Responses APIs); OpenRouter works for any model via the :online suffix.\n\nPerplexity searches BY DEFAULT (its native behavior) — the Web toggle can now actually turn it off per chat or per book.\n\nOther providers currently ignore this setting.\n\nThis is a global default: per-request toggles (input dialog, chat viewer) adapt to the active provider.\n\nIncreases token usage/cost."),
                                ModelConstraints.getWebSearchProvidersLabel())
                                -- Appended as its own sentence rather than folded into the
                                -- string above so the existing translations survive. Field
                                -- report 2026-07-26: a user read grounding 429s as "some
                                -- plugin features are broken" -- search runs on a quota of
                                -- its own, which nothing in the UI said.
                                .. "\n\n" .. _("Note: on Gemini, web search means Google Search grounding, which is billed against its own quota -- separate from normal requests, and on the free tier sometimes zero. If searching actions fail with a quota error while plain ones work, that is the usual cause."),
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
                            help_text = _("How much web searching the AI may do per question.\n\nLight: fewest searches, fastest and cheapest.\nStandard: balanced (provider defaults).\nThorough: most searches and context, slower and costlier.\n\nApplies where the provider offers control: Anthropic (up to 2/5/10 searches), OpenAI and Perplexity (search context size), OpenRouter (3/5/10 results), Z.AI (result count and snippet size). Gemini and xAI decide automatically."),
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
                            help_text = _("Include web search in the combined usage indicator line (e.g. '*[Web search was used]*') when web search is used.\n\nStreaming indicator ('Searching the web...') is always shown."),
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
                            help_text = _("Which provider generates images.\n\n'Follow main provider' uses your current chat provider when it supports images (OpenAI, xAI, Gemini). Picking one explicitly lets image generation work no matter which chat provider is active: it uses that provider's own API key.\n\nThe highlight-menu button only appears when the resolved provider has an API key."),
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
                        -- Prompt framing (2026-08-13): what surrounds the raw
                        -- selection in the prompt sent to the image API. Both
                        -- opt-out (default true) — ImageGenerator.buildPrompt
                        -- reads them with ~= false
                        {
                            id = "image_gen_frame_identity",
                            type = "toggle",
                            text = _("Include book title/author in prompt"),
                            path = "features.image_gen_frame_identity",
                            default = true,
                            help_text = _("Frame image prompts with the book's title and author, so illustrations can match the work's setting and era.\n\nApplies when generating from a book."),
                        },
                        {
                            id = "image_gen_frame_context",
                            type = "toggle",
                            text = _("Include surrounding text in prompt"),
                            path = "features.image_gen_frame_context",
                            default = true,
                            help_text = _("Add a short slice of the text around the selection, marked as context only, so the illustration reflects the scene the passage sits in."),
                        },
                        {
                            id = "image_gen_prompt_template",
                            type = "action",
                            text = _("Prompt template…"),
                            callback = "showImageGenPromptTemplate",
                            help_text = _("Shows the exact prompt sent to the image API, with your current framing toggles applied."),
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
                        -- NOTE: the zai/qwen/kimi region rows and the Z.AI
                        -- search engine row are MIRRORED in the provider/model
                        -- hub panels (main.lua buildModelMenu
                        -- provider_radio_rows) — same features keys; keep the
                        -- option lists in sync in both places.
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
                            id = "zai_search_engine",
                            type = "radio",
                            text_func = function(plugin)
                                local f = plugin.settings:readSetting("features") or {}
                                local engine = f.zai_search_engine or "search_pro_jina"
                                local labels = {
                                    search_pro_jina = _("Jina (international)"),
                                    search_pro_bing = _("Bing (international)"),
                                    search_pro_quark = _("Quark (Chinese web)"),
                                    search_pro_sogou = _("Sogou (Chinese web)"),
                                    search_pro = _("Pro (Chinese web)"),
                                    search_std = _("Basic (Chinese web)"),
                                }
                                return T(_("Z.AI Search Engine: %1"), labels[engine] or engine)
                            end,
                            help_text = _("Search engine used for Z.AI web search.\n\nThe international engines (Jina, Bing) return much better sources for non-Chinese queries. The Chinese-web engines suit Chinese-language content."),
                            path = "features.zai_search_engine",
                            default = "search_pro_jina",
                            options = {
                                { value = "search_pro_jina", text = _("Jina (international, default)") },
                                { value = "search_pro_bing", text = _("Bing (international)") },
                                { value = "search_pro_quark", text = _("Quark (Chinese web)") },
                                { value = "search_pro_sogou", text = _("Sogou (Chinese web)") },
                                { value = "search_pro", text = _("Pro (Chinese web)") },
                                { value = "search_std", text = _("Basic (Chinese web)") },
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
                        {
                            id = "kimi_region",
                            type = "radio",
                            text_func = function(plugin)
                                local f = plugin.settings:readSetting("features") or {}
                                local region = f.kimi_region or "international"
                                local labels = {
                                    international = _("International"),
                                    china = _("China"),
                                }
                                return T(_("Kimi Region: %1"), labels[region] or region)
                            end,
                            help_text = _("Select the Kimi (Moonshot) platform your API key was issued on.\n\nKeys are NOT interchangeable between the two platforms:\n- International: platform.kimi.ai (api.moonshot.ai)\n- China: platform.moonshot.cn (api.moonshot.cn)"),
                            path = "features.kimi_region",
                            default = "international",
                            options = {
                                { value = "international", text = _("International (api.moonshot.ai)") },
                                { value = "china", text = _("China (api.moonshot.cn)") },
                            },
                        },
                    },
                },
                {
                    -- Binary since the 2026-08-12 collapse (web-search model);
                    -- the old 3-way tools_posture migrates via _tools_binary_migrated
                    id = "enable_book_tools",
                    type = "toggle",
                    text = _("AI Book Tools"),
                    help_text = _("EXPERIMENTAL: Gemini, Claude (Anthropic), OpenAI, OpenRouter (Claude/GPT/Gemini models), DeepSeek, Mistral, Groq, and xAI. Book tools let the AI search the open book's text, read specific pages, and view the table of contents, so it can ground answers in the actual book instead of guessing. Requires \"Allow Text Extraction\".\n\nThis sets whether the Tools chip in book chats starts ON or OFF; you can always flip it per chat, and the AI still decides per question whether to actually search.\n\nPredefined actions are unaffected either way; they never use tools unless they explicitly offer smart retrieval. Override per book in Book Settings. Work in progress; behavior may change."),
                    path = "features.enable_book_tools",
                    default = false,
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
                    help_text = _("How AI Book Tools answer.\n\nGather then answer: the AI quietly collects passages from the book first, then answers as a normal request: the answer streams and web search stays available.\n\nInteractive: the original agentic loop; the AI narrates its way through lookups; no streaming or web search while tools run."),
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
                    help_text = _("How much searching AI Book Tools may do per question.\n\nQuick: up to 4 lookups in 2 rounds, fastest, for simple factual questions.\nStandard: up to 8 lookups in 4 rounds, a good balance.\nThorough: up to 16 lookups in 6 rounds, with a larger passage budget; slower and costlier, for questions that need evidence from many places in the book."),
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
                    help_text = _("Include book lookups in the combined usage indicator line (e.g. '*[Book search (3 lookups) was used]*') when AI Book Tools ran for a response.\n\nThe individual lookups are always viewable via the chat menu's 'Show Sources' entry."),
                    path = "features.show_book_tools_indicator",
                    default = true,
                },
                {
                    id = "tool_workflow_diagnostics",
                    type = "toggle",
                    text = _("AI Book Tools: Show Lookups (debug)"),
                    path = "features.tool_workflow_diagnostics",
                    default = false,
                    help_text = _("Append the tool lookups, raw tool results, and token usage to each answer when AI Book Tools run. For debugging the experimental tools: leave off for clean answers. Note: the raw tool results can include book-text snippets."),
                    separator = true,
                },
                {
                    id = "debug",
                    type = "toggle",
                    text = _("Console Debug"),
                    help_text = _("Log requests, responses, routing decisions and feature diagnostics to the console/crash log, for developers. Large content is truncated (see below); API keys are never logged. Slows page turns slightly while X-Ray marking is on."),
                    path = "features.debug",
                    default = false,
                    on_change = function(new_value, plugin)
                        -- Routine tracing lives at logger.dbg, which KOReader's
                        -- default level discards (issue #104) — raise the level
                        -- so this toggle actually delivers the diagnostics it
                        -- promises above.
                        require("koassistant_debug_utils").syncLogLevel(new_value)
                        -- Most consumers read the flag per request; the marks
                        -- module caches it at sync — resync so the toggle is
                        -- live there too
                        if plugin.syncXrayMarks then
                            local UIManager = require("ui/uimanager")
                            UIManager:nextTick(function()
                                plugin:syncXrayMarks()
                            end)
                        end
                    end,
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
                {
                    -- Setup Wizard v2 (2026-08-11): INERT until the release
                    -- flip — this debug-gated row is its ONLY entry; the old
                    -- wizard still serves first-run and Re-run.
                    id = "setup_wizard_dev",
                    type = "action",
                    text = _("Setup Wizard v2 (dev)"),
                    callback = "showSetupWizardDev",
                    depends_on = { id = "debug", value = true },
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
            -- One level of nesting (features.reasoning_prefs.stance) — a dotted key
            -- must land in a subtable, not as a junk flat key (audit settings MEDIUM).
            local parent, child = key:match("^([^%.]+)%.(.+)$")
            if parent then
                if type(new_features[parent]) ~= "table" then new_features[parent] = {} end
                new_features[parent][child] = default
            else
                new_features[key] = default
            end
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
