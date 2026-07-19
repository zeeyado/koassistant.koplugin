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
local BookToolRunner = require("koassistant_book_tool_runner")
local ConfigHelper = require("koassistant_config_helper")
local MessageHistory = require("koassistant_message_history")
local ChatHistoryManager = require("koassistant_chat_history_manager")
local SafeDocSettings = require("koassistant_doc_settings")
local BookSettings = require("koassistant_book_settings")
local MessageBuilder = require("message_builder")
local ModelConstraints = require("model_constraints")
local ReasoningPrefs = require("reasoning_prefs")
local Defaults = require("koassistant_api.defaults")
local Constants = require("koassistant_constants")
local ScopeResolver = require("koassistant_scope_resolver")
local PromptsActions = require("prompts.actions")
local logger = require("logger")

-- ActionService module (for static methods like getActionDisplayText)
local ActionServiceModule = require("action_service")

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

        -- Check for reasoning/thinking enabled using computed api_params
        -- These are set by buildUnifiedRequestConfig based on action overrides and global settings
        local reasoning_enabled = false
        if config.api_params then
            -- Anthropic: thinking, OpenAI: reasoning, Gemini: thinking_level / thinking_budget
            if config.api_params.thinking or config.api_params.reasoning or config.api_params.thinking_level
               or (config.api_params.thinking_budget and config.api_params.thinking_budget ~= 0) then
                reasoning_enabled = true
            end
        end
        if reasoning_enabled then
            table.insert(status_lines, _("Reasoning enabled"))
        end

        -- Show action name if available
        if config.features and config.features.loading_action_name then
            table.insert(status_lines, config.features.loading_action_name)
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
        if config.features.is_library_context then
            return "library"
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

-- Helper to persist per-book domain selection to DocSettings
local function persistBookDomain(doc_settings, domain_id)
    if not doc_settings then return end
    doc_settings:saveSetting(BookSettings.KEY_DOMAIN, domain_id)
    doc_settings:flush()
end

-- Helper to read per-book domain from DocSettings
local function getBookDomain(doc_settings)
    if not doc_settings then return nil end
    return doc_settings:readSetting(BookSettings.KEY_DOMAIN)
end

-- Helper to persist per-book research mode to DocSettings
local function persistBookResearchMode(doc_settings, value)
    if not doc_settings then return end
    doc_settings:saveSetting(BookSettings.KEY_RESEARCH, value)
    doc_settings:flush()
end

-- Helper to read per-book research mode from DocSettings
local function getBookResearchMode(doc_settings)
    if not doc_settings then return nil end
    return doc_settings:readSetting(BookSettings.KEY_RESEARCH)
end

-- Session chips shown above the input field (book_scoped_controls_plan.md §4). Canonical
-- order is fixed; membership is user-configurable via the input dialog's gear menu
-- ("Chat Buttons…"), stored as an ordered array in features.session_chips. nil = the
-- default set (the one-time migration in main.lua seeds it, folding the old
-- show_spoiler_toggle bool into "spoiler" membership).
local SESSION_CHIP_IDS = { "domain", "web_search", "book_tools", "quick", "scope", "attach", "spoiler" }
local SESSION_CHIPS_DEFAULT = { "domain", "web_search", "book_tools", "quick", "scope", "attach", "spoiler" }
local function getSessionChips(features)
    local chips = features and features.session_chips
    if type(chips) ~= "table" then return SESSION_CHIPS_DEFAULT end
    return chips
end

-- Surrounding-context extraction for highlight/dictionary requests.
-- Trimming is pure and lives in koassistant_scope_resolver.lua (hard 2000-char cap
-- included); this file provides the live-selection fetch. IMPORTANT: the selection
-- dies when the highlight overlay / dictionary popup closes (ReaderHighlight:
-- onClose → clear), so entry points must fetch the window BEFORE closing and ride
-- it into handlePredefinedPrompt / the input dialog via the
-- features._selection_context_window transient ({ prev, next, text }; `text`
-- fingerprints the selection so a stale window can never attach to a different
-- selection).

-- Words fetched per side. Generous enough for every trim mode's per-side cap
-- (1000 chars); the trim decides what is actually sent.
local CONTEXT_WINDOW_WORDS = 200

--- Fetch the raw text window around the live selection. Call while the selection
-- still exists (works for hold-select, not single word taps).
-- @return table { prev, next, text } or nil when unavailable
local function fetchSelectionContextWindow(ui, highlighted_text)
    if ui and ui.highlight and ui.highlight.getSelectedWordContext then
        local prev_context, next_context = ui.highlight:getSelectedWordContext(CONTEXT_WINDOW_WORDS)
        if prev_context or next_context then
            return { prev = prev_context or "", next = next_context or "", text = highlighted_text }
        end
    end
    return nil
end

--- Extract surrounding context from the live selection (fetch + trim in one step).
-- @param mode: "sentence" (default), "paragraph", "characters", or "none"
-- @param char_count: chars per side for "characters" mode (default 100)
-- @param paragraph_count: paragraphs per side for "paragraph" mode (default 1)
-- @return string: marked context or "" when unavailable
local function extractSurroundingContext(ui, highlighted_text, mode, char_count, paragraph_count)
    mode = mode or "sentence"
    if mode == "none" then
        return ""
    end
    local window = fetchSelectionContextWindow(ui, highlighted_text)
    if not window then
        return ""
    end
    return ScopeResolver.trimContext(window.prev, window.next, highlighted_text, mode,
        { char_count = char_count, paragraphs = paragraph_count })
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

-- Per-book web-search override (true/false, or nil = follow global). Resolved from the
-- book's sidecar via book_metadata — the same route as the response-language override in
-- buildUnifiedRequestConfig; general/library chats carry no book_metadata and fall through.
local function bookWebSearchOverride(features)
    local file = features and features.book_metadata and features.book_metadata.file
    if not file then return nil end
    return BookSettings.webSearchOverride(SafeDocSettings.resolve(file))
end

-- @param config: Configuration to modify (modified in-place)
-- @param domain_context: Optional domain context string
-- @param action: Optional action definition with behavior/api_params
-- @param plugin: Plugin instance
-- @return boolean: true if config was successfully built
local function buildUnifiedRequestConfig(config, domain_context, action, plugin)
    if not config then return false end

    local features = config.features or {}
    local SystemPrompts = require("prompts.system_prompts")

    -- Quick controls (controls_parity_plan.md §10): one-shot session overrides,
    -- set just-in-time at dispatch (*_active pattern, like the Web chip) and
    -- consumed here. Matrix rule: explicit action pins always win
    -- (action > session > book > global).
    local quick_answer = features._quick_answer_active
    local reasoning_override = features._reasoning_override_active
    local model_override = features._model_override_active
    features._quick_answer_active = nil
    features._reasoning_override_active = nil
    features._model_override_active = nil
    -- Quick Answer reaches predefined actions only by opt-in (accept_quick_answer
    -- = true on Explain-type actions; never X-Ray/translate/quiz — §10). This one
    -- gate covers the WHOLE preset (two-source rule, maintainer 2026-07-19): every
    -- preset component below derives from quick_answer, while manual ⚡-menu
    -- overrides (reasoning_override/model_override) keep their Web-pattern reach.
    if quick_answer and action and action.accept_quick_answer ~= true then
        quick_answer = nil
    end
    -- Preset model component (quick_preset_model_mode = "fastest"): switch to the
    -- active provider's fastest LISTED model for this chat. Manual ⚡-menu model
    -- picks win; custom providers have no tier info and keep the current model.
    if quick_answer and not model_override
        and features.quick_preset_model_mode == "fastest" then
        local MLists = require("koassistant_model_lists")
        local prov = config.provider or config.default_provider or "anthropic"
        for _idx, tier in ipairs({ "ultrafast", "fast", "standard", "flagship" }) do
            local tier_map = MLists._tiers[tier]
            if tier_map and tier_map[prov] then
                model_override = { provider = prov, model = tier_map[prov] }
                break
            end
        end
    end
    -- One-shot provider/model override — applied BEFORE every provider-dependent
    -- read below (caching gate, Perplexity check, reasoning resolution). An
    -- action's own provider pin (already applied by createTempConfig/
    -- handlePredefinedPrompt) wins.
    if model_override and model_override.provider and not (action and action.provider) then
        config.provider = model_override.provider
        config.model = model_override.model
        -- Clone the per-provider table before writing: the freeform rebase copy is
        -- shallow-2-level, so this sub-table can still be SHARED with the module
        -- config — a configuration.lua provider_settings entry must not absorb a
        -- one-shot override as its session default.
        config.provider_settings = config.provider_settings or {}
        local ps = {}
        for k, v in pairs(config.provider_settings[config.provider] or {}) do
            ps[k] = v
        end
        ps.model = model_override.model
        config.provider_settings[config.provider] = ps
    end
    if quick_answer and features.quick_preset_tools_off ~= false then
        -- Preset "no slow features": book tools off for this chat (explicit false —
        -- rides the viewer config into replies, same mechanics as the G6 clear).
        features._tools_active = false
    end

    -- Spoiler-free is a freeform-Send-only session flag; predefined actions (Summarize, X-Ray,
    -- …) are excluded by design. It persists on the shared configuration (main.lua keeps
    -- underscore keys across disk sync) and gets copied into temp_config, so a prior spoiler-free
    -- chat would leak the nudge into the next predefined action. Clear it for any predefined
    -- action (action ~= nil); freeform Send passes action=nil and keeps the flag it just set.
    -- (audit v0.20.0 finding G6) The per-chat tools checkbox (_tools_active) is cleared for
    -- the same reason — and set to EXPLICIT false, not nil (2026-07-11, with the auto
    -- posture default): this config rides into the action's chat viewer and its replies
    -- (addMessage → queryWith), and a nil would fall through to the posture there, so an
    -- "auto" posture would fire gather rounds on replies to translate/X-Ray/etc. chats.
    -- Actions engage tools ONLY via their explicit smart-retrieval source; their chats
    -- stay tools-free. Freeform Send passes action=nil and keeps the flag it just set.
    if action then
        features._spoiler_free_active = nil
        features._tools_active = false
        -- (The per-chat web toggle is NOT cleared here: unlike spoiler/tools, it applies
        -- to nil-flag actions launched from the dialog too — maintainer 2026-07-12, the
        -- action buttons' 🌐 indicator follows the chip. Forced action flags still win
        -- in the chain below; the dialog sets it just-in-time and this function's bake
        -- consumes it, so other entry points never see a stale value.)
    end

    -- Per-book MAIN response-language override (Book Settings ▸ Languages ▸ AI response
    -- language) — applies to every action's system prompt, distinct from translate/dictionary.
    -- Resolved from the book's sidecar; book/highlight only (general/library lack book_metadata).
    local lang_fields = {
        interaction_languages = features.interaction_languages,
        user_languages = features.user_languages or "",
        primary_language = features.primary_language,
    }
    local lang_file = features.book_metadata and features.book_metadata.file
    if lang_file then
        lang_fields = require("koassistant_book_settings").applyResponseLanguageOverride(
            lang_fields, SafeDocSettings.resolve(lang_file))
    end

    -- Web search: layered override baked into config.enable_web_search — handlers read it
    -- override-first, else features.enable_web_search (the global default).
    -- Priority: action flag (true = force on, false = force off, nil = follow) >
    -- per-chat toggle (freeform Send AND dialog-launched actions) > per-book override >
    -- nil = follow global at the wire layer. Always assigned, so a stale value on a
    -- shared/reused config can't leak into this request; the per-chat flag is consumed
    -- once baked (replies read the baked value off the viewer's configuration).
    -- Baked BEFORE the system prompt so the prose nudge below can see the decision.
    if action and action.enable_web_search ~= nil then
        config.enable_web_search = action.enable_web_search
    elseif features._web_search_active ~= nil then
        config.enable_web_search = features._web_search_active
    else
        config.enable_web_search = bookWebSearchOverride(features)
    end
    features._web_search_active = nil
    -- Quick Answer preset: web search off for this request unless the preset
    -- component is disabled or the action forces web on (explicit action flag
    -- wins — matrix §10).
    if quick_answer and features.quick_preset_web_off ~= false
        and not (action and action.enable_web_search == true) then
        config.enable_web_search = false
    end
    -- Effective boolean for the system-prompt nudge (mirrors the handlers' read:
    -- override-first, else global; Perplexity searches unconditionally)
    local web_search_effective
    if config.enable_web_search ~= nil then
        web_search_effective = config.enable_web_search == true
    else
        web_search_effective = features.enable_web_search == true
    end
    if (config.provider or config.default_provider) == "perplexity" then
        web_search_effective = true
    end

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
        -- Language settings (interaction_languages is new array format, user_languages is old
        -- string format). Folds in any per-book AI-response-language override (lang_fields above).
        interaction_languages = lang_fields.interaction_languages,
        user_languages = lang_fields.user_languages,
        primary_language = lang_fields.primary_language,
        skip_language_instruction = action and action.skip_language_instruction,
        -- Research mode: resolved flag triggers academic nudge in system prompt
        -- (DOI auto-detection, per-book toggle, global setting, or action override)
        research_mode = features._research_mode_active,
        -- Spoiler-free mode: inject nudge into system prompt for freeform chat
        spoiler_free = features._spoiler_free_active,
        reading_progress = features.book_metadata and features.book_metadata.reading_progress,
        -- Web search active → prose nudge (pre-search text is reader-visible)
        web_search = web_search_effective,
        -- Quick Answer posture → brevity nudge (session ⚡ chip / opted-in actions;
        -- preset component quick_preset_nudge, default on)
        quick_answer = (quick_answer and features.quick_preset_nudge ~= false) and true or nil,
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

    -- Note: max_tokens is NOT set here. If the action doesn't specify it,
    -- handlers fall back to their provider defaults (defaults.lua), then to 16384.
    -- Model-specific ceilings are enforced by ModelConstraints.clampMaxTokens().

    -- Reasoning/Thinking: resolved per-model via the central resolver.
    -- Precedence: action reasoning_config > per-model pref > per-provider pref >
    -- global stance > model natural default. The resolver returns a normalized
    -- decision; applyReasoningParams emits the existing per-provider api_params
    -- keys (wire format unchanged), or NOTHING when the model should behave at its
    -- API default (stance "default" with no overrides). See model_constraints.lua
    -- and reasoning_prefs.lua.
    local provider = config.provider or config.default_provider or "anthropic"
    local reasoning_model = config.model
    if not reasoning_model then
        local pd = Defaults.ProviderDefaults[provider]
        reasoning_model = pd and pd.model or nil
    end
    local reasoning_decision = ModelConstraints.resolveReasoning(provider, reasoning_model, {
        global_stance = ReasoningPrefs.getStance(features),
        model_pref = ReasoningPrefs.getModelPref(features, provider, reasoning_model),
        action_override = action and ModelConstraints.parseActionReasoning(action, provider) or nil,
        -- One-shot session layer (Quick controls — matrix §10): explicit reasoning
        -- pick wins over Quick Answer's preset off (quick_preset_reasoning_off,
        -- default on); both sit BELOW action_override.
        session_override = reasoning_override
            or ((quick_answer and features.quick_preset_reasoning_off ~= false)
                and { force = "off" } or nil),
    })
    config.api_params._reasoning = reasoning_decision
    ModelConstraints.applyReasoningParams(provider, config.api_params, reasoning_decision)

    -- (Web search baking moved above the system-prompt build — see the block before
    -- buildUnifiedSystem.)

    -- Set action name for loading dialog display (used by non-streaming loading dialog)
    if action and action.text then
        config.features = config.features or {}
        config.features.loading_action_name = action.text
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

-- Quick Answer preset editor — persistent GLOBAL settings for what the ⚡ tap
-- applies (controls_parity_plan.md §2, maintainer 2026-07-19). Reachable from
-- main settings (Chat & Export → Quick Answer Preset — schema is the source of
-- the defaults) and from the quick controls menu ("Preset settings…"). Rebuilds
-- itself per toggle so the marks stay fresh.
-- opts = { plugin, on_close }
local showQuickPresetEditor
showQuickPresetEditor = function(opts)
    local ButtonDialog = require("ui/widget/buttondialog")
    local plugin = opts.plugin
    local dialog
    local function mutate(fn)
        local f = plugin.settings:readSetting("features") or {}
        fn(f)
        plugin.settings:saveSetting("features", f)
        plugin.settings:flush()
        if plugin.updateConfigFromSettings then plugin:updateConfigFromSettings() end
        UIManager:close(dialog)
        showQuickPresetEditor(opts)
    end
    local f = plugin.settings:readSetting("features") or {}
    local function toggleRow(label, key)
        local on = f[key] ~= false
        return {{
            text = (on and "✓ " or "○ ") .. label,
            callback = function()
                mutate(function(feats) feats[key] = not on end)
            end,
        }}
    end
    local mode = f.quick_preset_model_mode or "none"
    dialog = ButtonDialog:new{
        title = _("Quick Answer preset · applies while Quick Answer is on"),
        -- Tap-outside dismissal must fire on_close too, or the dialog beneath
        -- keeps stale state (showSessionChipsManager precedent)
        tap_close_callback = function()
            if opts.on_close then opts.on_close() end
        end,
        buttons = {
            toggleRow(_("Concise answer nudge"), "quick_preset_nudge"),
            toggleRow(_("Reasoning off"), "quick_preset_reasoning_off"),
            toggleRow(_("Web search off"), "quick_preset_web_off"),
            toggleRow(_("Book tools off"), "quick_preset_tools_off"),
            {{
                text = T(_("Model: %1"), mode == "fastest"
                    and _("Fastest for provider") or _("Keep current")),
                callback = function()
                    mutate(function(feats)
                        feats.quick_preset_model_mode =
                            (feats.quick_preset_model_mode == "fastest") and "none" or "fastest"
                    end)
                end,
            }},
            {{
                text = _("Close"),
                callback = function()
                    UIManager:close(dialog)
                    if opts.on_close then opts.on_close() end
                end,
            }},
        },
    }
    UIManager:show(dialog)
end

-- Quick controls menu (controls_parity_plan.md §2/§9 — #86): one-shot session
-- overrides for THIS chat only — the Quick Answer posture, a reasoning override,
-- and a provider/model override. State lives on opts.configuration.features
-- (_session_quick_answer / _session_reasoning / _session_model) — config-resident
-- like the Scope chip (60-upvalue cap), consumed at dispatch via the *_active
-- transients (see buildUnifiedRequestConfig). Module-level so the reply dialog
-- (parity slice (b)) can reuse it with its own opts.
-- opts = { configuration, plugin, on_change }
local function showQuickControlsMenu(opts)
    local ButtonDialog = require("ui/widget/buttondialog")
    local configuration = opts.configuration
    local plugin = opts.plugin
    local on_change = opts.on_change or function() end
    configuration.features = configuration.features or {}
    local f = configuration.features

    local menu

    local function pickReasoning()
        local sub
        local so = f._session_reasoning
        local function row(label, value, is_current)
            return {{
                text = (is_current and "● " or "○ ") .. label,
                callback = function()
                    f._session_reasoning = value
                    UIManager:close(sub)
                    on_change()
                end,
            }}
        end
        sub = ButtonDialog:new{
            title = _("Reasoning · this chat only"),
            buttons = {
                row(_("Follow settings"), nil, so == nil),
                row(_("Off for this chat"), { force = "off" }, (so and so.force == "off") or false),
                row(_("On for this chat"), { force = "on" }, (so and so.force == "on") or false),
                {{ text = _("Cancel"), callback = function() UIManager:close(sub) end }},
            },
        }
        UIManager:show(sub)
    end

    local function pickModel(provider_id, provider_label)
        local ModelLists = require("koassistant_model_lists")
        local sub
        -- Built-in list, or for custom providers their default model + saved customs
        -- (same sources as the Quick Edit selector)
        local models
        local custom = plugin and plugin.getCustomProvider and plugin:getCustomProvider(provider_id)
        if custom then
            models = {}
            if custom.default_model and custom.default_model ~= "" then
                table.insert(models, custom.default_model)
            end
            for _idx, m in ipairs(plugin:getCustomModels(provider_id)) do
                if m ~= custom.default_model then
                    table.insert(models, m)
                end
            end
        else
            models = ModelLists[provider_id] or {}
        end
        local buttons = {}
        local current = f._session_model
        for _idx, m in ipairs(models) do
            local model_name = m
            local is_current = current and current.provider == provider_id
                and current.model == model_name
            table.insert(buttons, {{
                text = (is_current and "● " or "○ ") .. model_name,
                callback = function()
                    f._session_model = { provider = provider_id, model = model_name }
                    UIManager:close(sub)
                    on_change()
                end,
            }})
        end
        if #buttons == 0 then
            table.insert(buttons, {{ text = _("No models listed for this provider"), enabled = false }})
        end
        table.insert(buttons, {{ text = _("Cancel"), callback = function() UIManager:close(sub) end }})
        sub = ButtonDialog:new{
            title = T(_("Model · %1 · this chat only"), provider_label),
            buttons = buttons,
        }
        UIManager:show(sub)
    end

    local pickProvider
    pickProvider = function(show_all)
        local ModelLists = require("koassistant_model_lists")
        local sub
        local buttons = {}
        table.insert(buttons, {{
            text = (f._session_model == nil and "● " or "○ ") .. _("Default (follow settings)"),
            callback = function()
                f._session_model = nil
                UIManager:close(sub)
                on_change()
            end,
        }})
        local all_providers = {}
        for _idx, provider in ipairs(ModelLists.getAllProviders()) do
            table.insert(all_providers, { id = provider, name = provider:gsub("^%l", string.upper) })
        end
        if plugin and plugin.getCustomProviders then
            for _idx, cp in ipairs(plugin:getCustomProviders()) do
                if cp.id then
                    table.insert(all_providers, { id = cp.id, name = cp.name or cp.id, is_custom = true, config = cp })
                end
            end
        end
        table.sort(all_providers, function(a, b) return a.name:lower() < b.name:lower() end)
        -- Key-filtering: same rules as the slice-(a) pickers — configured providers
        -- (+ the current pick, marked), "Show all" reveals the rest, disarmed while
        -- no real key exists.
        local has_real_key = plugin and plugin.hasAnyRealApiKey and plugin:hasAnyRealApiKey()
        local hidden_count = 0
        for _idx, prov in ipairs(all_providers) do
            local configured = not has_real_key
                or plugin:isProviderConfigured(prov.id, prov.config)
            local is_current = f._session_model and f._session_model.provider == prov.id
            if configured or show_all or is_current then
                local label = prov.is_custom and ("★ " .. prov.name) or prov.name
                if not configured then
                    label = T(_("%1 (no key)"), label)
                end
                local prov_id, prov_name = prov.id, prov.name
                table.insert(buttons, {{
                    text = label,
                    callback = function()
                        UIManager:close(sub)
                        pickModel(prov_id, prov_name)
                    end,
                }})
            else
                hidden_count = hidden_count + 1
            end
        end
        if hidden_count > 0 then
            table.insert(buttons, {{
                text = T(_("Show all providers (%1 more)…"), hidden_count),
                callback = function()
                    UIManager:close(sub)
                    pickProvider(true)
                end,
            }})
        end
        table.insert(buttons, {{ text = _("Cancel"), callback = function() UIManager:close(sub) end }})
        sub = ButtonDialog:new{
            title = _("Model · pick a provider"),
            buttons = buttons,
        }
        UIManager:show(sub)
    end

    local qa_on = f._session_quick_answer == true
    local so = f._session_reasoning
    local reasoning_label
    if so == nil then
        -- Reflect the preset's implied state so the menu doesn't claim "Follow
        -- settings" while Quick Answer is forcing reasoning off.
        if qa_on and f.quick_preset_reasoning_off ~= false then
            reasoning_label = _("Off (Quick answer)")
        else
            reasoning_label = _("Follow settings")
        end
    elseif so.force == "off" then
        reasoning_label = _("Off for this chat")
    else
        reasoning_label = _("On for this chat")
    end
    local model_label
    if f._session_model then
        model_label = f._session_model.model or f._session_model.provider
    elseif qa_on and f.quick_preset_model_mode == "fastest" then
        model_label = _("Fastest (preset)")
    else
        model_label = _("Default")
    end
    local buttons = {
        {{
            text = (qa_on and "✓ " or "") .. _("Quick answer (apply preset)"),
            callback = function()
                f._session_quick_answer = (not qa_on) or nil
                UIManager:close(menu)
                on_change()
            end,
        }},
        {{
            text = T(_("Reasoning: %1"), reasoning_label),
            callback = function()
                UIManager:close(menu)
                pickReasoning()
            end,
        }},
        {{
            text = T(_("Model: %1"), model_label),
            callback = function()
                UIManager:close(menu)
                pickProvider()
            end,
        }},
    }
    if plugin and plugin.settings then
        table.insert(buttons, {{
            text = _("Preset settings…"),
            callback = function()
                UIManager:close(menu)
                showQuickPresetEditor({ plugin = plugin, on_close = on_change })
            end,
        }})
    end
    table.insert(buttons, {{ text = _("Close"), callback = function() UIManager:close(menu) end }})
    menu = ButtonDialog:new{
        title = _("Quick controls · this chat only"),
        buttons = buttons,
    }
    UIManager:show(menu)
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
        for _idx, prompt in ipairs(service_prompts) do
            local key = prompt.id or ("prompt_" .. #prompt_keys + 1)
            prompts[key] = prompt
            table.insert(prompt_keys, key)
        end
    else
        logger.warn("getAllPrompts: No prompt service available, no prompts returned")
    end

    return prompts, prompt_keys
end

local function createSaveDialog(document_path, history, chat_history_manager, is_general_context, book_metadata, launch_context, highlighted_text, ui, config)
    -- Library chats also have no document_path; treat them like general (audit C1 — the first
    -- manual save of a library chat previously errored "Cannot save: no document context").
    local is_library_context = config and config.features and config.features.is_library_context
    -- Guard against missing document path - allow special case for general/library context
    if not document_path and not is_general_context and not is_library_context then
        UIManager:show(InfoMessage:new{
            text = _("Cannot save: no document context"),
            timeout = 2,
        })
        return
    end

    -- Use special path for general/library context chats
    if not document_path then
        if is_library_context then
            document_path = "__LIBRARY_CHATS__"
        elseif is_general_context then
            document_path = "__GENERAL_CHATS__"
        end
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

                                -- Preserve existing tags and starred when updating an existing chat
                                local existing_tags = {}
                                local existing_starred
                                if metadata.id then
                                    local existing = chat_history_manager:getChatById(document_path, metadata.id)
                                    if existing then
                                        existing_tags = existing.tags or {}
                                        existing_starred = existing.starred
                                    end
                                end

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
                                    tags = existing_tags,
                                    starred = existing_starred,
                                    original_highlighted_text = metadata.original_highlighted_text,
                                    -- Store system prompt metadata for debug display
                                    system_metadata = config and config.system,
                                    -- Store cache continuation info (for "Updated from X% cache" notice)
                                    used_cache = history.used_cache,
                                    cached_progress = history.cached_progress,
                                    cache_action_id = history.cache_action_id,
                                    -- Store book text truncation info
                                    book_text_truncated = history.book_text_truncated,
                                    book_text_coverage_start = history.book_text_coverage_start,
                                    book_text_coverage_end = history.book_text_coverage_end,
                                    -- Store unavailable data info
                                    unavailable_data = history.unavailable_data,
                                }

                                if document_path == "__GENERAL_CHATS__" then
                                    return chat_history_manager:saveGeneralChat(chat_data)
                                elseif document_path == "__LIBRARY_CHATS__" then
                                    return chat_history_manager:saveLibraryChat(chat_data)
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
    for _idx, msg in ipairs(history:getMessages()) do
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
    for _idx, tag in ipairs(all_tags) do
        local already_has = false
        for _idx2, current in ipairs(current_tags) do
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

-- NOTE (review 2026-07-12): the addMessage parameter is currently DEAD — no code in this
-- function invokes it; every caller's replies run through the internal onAskQuestion below,
-- which does its own addUserMessage/queryWith (and failure rollback). The callers' closures
-- keep the rollback logic anyway so they are correct if ever wired up.
local function showResponseDialog(title, history, highlightedText, addMessage, temp_config, document_path, plugin, book_metadata, launch_context, ui_instance)
    -- For compact view (dictionary lookups), force debug OFF regardless of global setting
    -- Create a config copy for createResultText with debug disabled
    local config_for_text = temp_config or CONFIGURATION
    if config_for_text and config_for_text.features and (config_for_text.features.compact_view or config_for_text.features.dictionary_view) then
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

    -- Utility views (translate/compact/dictionary popups) STACK on top of an open chat
    -- viewer instead of replacing it — translating text selected inside a chat must not
    -- close the chat underneath (maintainer repro 2026-07-12; only affected viewers
    -- registered as ActiveChatViewer, which is why resumed chats appeared immune). They
    -- still take the ActiveChatViewer slot while open (their reply/update machinery
    -- checks it) and hand it back in close_callback below.
    local view_features = temp_config and temp_config.features or {}
    local is_utility_view = view_features.compact_view or view_features.dictionary_view
        or view_features.translate_view
    local restore_active_viewer = nil
    if _G.ActiveChatViewer then
        if is_utility_view then
            restore_active_viewer = _G.ActiveChatViewer
        else
            -- Full chat viewers replace the previous one (single-chat model)
            UIManager:close(_G.ActiveChatViewer)
            _G.ActiveChatViewer = nil
        end
    end

    -- Forward declare for mutual reference
    local chatgpt_viewer
    local recreate_func

    -- Recreate function for rotation handling
    -- Takes state captured by ChatGPTViewer:captureState() and recreates the viewer
    recreate_func = function(state)
        -- Do NOT close _G.ActiveChatViewer here: _handleScreenChange already closed the
        -- viewer being recreated (and cleared its own slot). With stacked utility views,
        -- two viewers can rotate at once — the slot may hold the OTHER viewer's fresh
        -- recreation, and closing it would destroy it (review finding 2026-07-12).

        -- Re-derive the text from the live history rather than the captured snapshot:
        -- a reply that completed during the ~0.2s rotation gap was appended to history but
        -- not to state.text, so using the snapshot would drop it (the narrow B5 race).
        -- ONLY for the default chat view: translate/compact/dictionary views format their
        -- text differently (createTranslateViewText, debug-suppressed) and re-deriving would
        -- corrupt them — keep their captured snapshot verbatim.
        local recreated_text = state.text
        local sf = state.configuration and state.configuration.features
        local is_special_view = sf and (sf.translate_view or sf.compact_view
            or sf.dictionary_view or sf.simple_view)
        if not is_special_view and state.original_history and state.original_history.createResultText then
            recreated_text = state.original_history:createResultText(
                state.original_highlighted_text, state.configuration) or state.text
        end

        -- Create new viewer with captured state but new dimensions
        local new_viewer = ChatGPTViewer:new {
            title = state.title,
            text = recreated_text,
            configuration = state.configuration,
            render_markdown = state.render_markdown,
            show_debug_in_chat = state.show_debug_in_chat,
            -- Set BOTH property names for compatibility
            original_history = state.original_history,
            _message_history = state.original_history,
            original_highlighted_text = state.original_highlighted_text,
            reply_draft = state.reply_draft,
            selection_data = state.selection_data,  -- Preserve for "Save to Note" feature
            _plugin = state._plugin,  -- For text selection dictionary lookup
            _ui = state._ui,  -- For text selection dictionary lookup
            -- Callbacks from captured state
            onAskQuestion = state.onAskQuestion,
            save_callback = state.save_callback,
            export_callback = state.export_callback,
            tag_callback = state.tag_callback,
            pin_callback = state.pin_callback,
            star_callback = state.star_callback,
            get_pin_state = state.get_pin_state,
            get_star_state = state.get_star_state,
            settings_callback = state.settings_callback,
            update_debug_callback = state.update_debug_callback,
            -- Pass recreate function for subsequent rotations
            _recreate_func = recreate_func,
        }
        -- Set close_callback after creation so new_viewer is defined.
        -- Inherits the stacked-view restore duty (see showResponseDialog's close_callback).
        new_viewer.close_callback = function()
            if _G.ActiveChatViewer == new_viewer or _G.ActiveChatViewer == nil then
                _G.ActiveChatViewer = restore_active_viewer
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
    -- Check if dictionary view should be used (full-size with dictionary buttons)
    local use_dictionary_view = temp_config and temp_config.features and temp_config.features.dictionary_view
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
    if not use_compact_view and not use_dictionary_view and not use_translate_view then
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
    -- This allows ChatGPTViewer to determine chat type (book/general/library)
    if temp_config and document_path then
        temp_config.document_path = document_path
    end

    -- Cache notice is now handled in MessageHistory:createResultText() so it persists through debug toggle

    -- Pin/Star helpers (closures shared by callbacks and state checkers)
    local pin_star_path = (function()
        local is_multi = temp_config and temp_config.features and temp_config.features.is_library_context
        if is_multi then return "__LIBRARY_CHATS__"
        elseif not document_path then return "__GENERAL_CHATS__"
        else return document_path end
    end)()

    -- Get last (most recent) AI response and the user prompt that preceded it
    local function getLastResponseAndPrompt()
        local msgs = history:getMessages()
        if not msgs then return "", "" end
        local last_response, last_prompt = "", ""
        for i = #msgs, 1, -1 do
            if msgs[i].role == "assistant" and msgs[i].content and last_response == "" then
                last_response = msgs[i].content
                -- Find the user prompt that preceded this response
                for j = i - 1, 1, -1 do
                    if msgs[j].role == "user" and not msgs[j].is_context then
                        last_prompt = msgs[j].content or ""
                        break
                    end
                end
                break
            end
        end
        return last_response, last_prompt
    end

    -- Check if last AI response is already pinned; returns (is_pinned, pin_id)
    local function getPinState()
        local last_response = getLastResponseAndPrompt()
        if last_response == "" then return false, nil end
        local ok_pm, PinnedManager = pcall(require, "koassistant_pinned_manager")
        if not ok_pm or not PinnedManager then return false, nil end
        local pinned = PinnedManager.getPinnedForDocument(pin_star_path)
        for _idx, pin in ipairs(pinned) do
            -- Strip trailing newline from loaded content (writeLongString legacy)
            local pin_result = pin.result or ""
            if pin_result:sub(-1) == "\n" then
                pin_result = pin_result:sub(1, -2)
            end
            if pin_result == last_response then
                return true, pin.id
            end
        end
        return false, nil
    end

    -- Check if chat is starred; returns is_starred
    local function getStarState()
        if not history.chat_id then return false end
        local chat = chat_history_manager:getChatById(pin_star_path, history.chat_id)
        return chat and chat.starred == true or false
    end

    chatgpt_viewer = ChatGPTViewer:new {
        title = title .. " (" .. model_info .. ")",
        text = display_text,
        configuration = temp_config or CONFIGURATION,  -- Pass configuration for debug toggle
        show_debug_in_chat = show_debug,
        compact_view = use_compact_view,  -- Use compact height for dictionary lookups
        dictionary_view = use_dictionary_view,  -- Full-size with dictionary buttons
        minimal_buttons = use_minimal_buttons,  -- Use minimal buttons for dictionary lookups
        translate_view = use_translate_view,  -- Use translate view for translations
        translate_hide_quote = translate_hide_quote,  -- Initial hide state for original text
        selection_data = selection_data,  -- For "Save to Note" feature
        -- Scroll to last question if setting enabled AND this is a follow-up response
        -- First response should always start from top (user needs to read it)
        scroll_to_last_question = (temp_config and temp_config.features and temp_config.features.scroll_to_last_message == true)
            and history and history.getAssistantTurnCount and history:getAssistantTurnCount() > 1,
        -- Set BOTH property names for compatibility:
        -- original_history: used by toggleDebugDisplay, toggleHighlightVisibility, etc.
        -- _message_history: used by expandToFullView for text regeneration
        original_history = history,
        _message_history = history,
        original_highlighted_text = highlightedText,
        _plugin = plugin,  -- For text selection dictionary lookup
        _ui = ui_instance,  -- For text selection dictionary lookup
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

            -- Note: Loading dialog is now handled by handleNonStreamingBackground in gpt_query.lua
            -- which shows a cancellable dialog for non-streaming requests

            -- Function to update the viewer with new content
            local function updateViewer()
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
                        -- Scroll to last question if setting enabled AND this is a follow-up response
                        -- (This is for follow-up replies, so there should always be 2+ assistant messages here)
                        scroll_to_last_question = (viewer_cfg and viewer_cfg.features and viewer_cfg.features.scroll_to_last_message == true)
                            and history and history.getAssistantTurnCount and history:getAssistantTurnCount() > 1,
                        scroll_to_bottom = not ((viewer_cfg and viewer_cfg.features and viewer_cfg.features.scroll_to_last_message == true)
                            and history and history.getAssistantTurnCount and history:getAssistantTurnCount() > 1),
                        show_debug_in_chat = viewer.show_debug_in_chat,
                        -- Set BOTH property names for compatibility:
                        -- original_history: used by toggleDebugDisplay, toggleHighlightVisibility, etc.
                        -- _message_history: used by expandToFullView for text regeneration
                        original_history = history,
                        _message_history = history,
                        original_highlighted_text = highlightedText,
                        _plugin = viewer._plugin,  -- For text selection dictionary lookup
                        _ui = viewer._ui,  -- For text selection dictionary lookup
                        _recreate_func = recreate_func, -- For rotation handling
                        settings_callback = viewer.settings_callback,
                        update_debug_callback = viewer.update_debug_callback,
                        onAskQuestion = viewer.onAskQuestion,
                        save_callback = viewer.save_callback,
                        export_callback = viewer.export_callback,
                        tag_callback = viewer.tag_callback,
                        pin_callback = viewer.pin_callback,
                        star_callback = viewer.star_callback,
                        get_pin_state = viewer.get_pin_state,
                        get_star_state = viewer.get_star_state,
                        selection_data = viewer.selection_data,  -- Preserve for "Save to Note" feature
                        session_web_search_override = viewer.session_web_search_override,  -- Preserve session override
                    }
                    -- Set close_callback after creation so new_viewer is defined.
                    -- Inherits the stacked-view restore duty (see the outer close_callback).
                    new_viewer.close_callback = function()
                        if _G.ActiveChatViewer == new_viewer or _G.ActiveChatViewer == nil then
                            _G.ActiveChatViewer = restore_active_viewer
                        end
                    end

                    -- Set global reference to new viewer
                    _G.ActiveChatViewer = new_viewer

                    -- Show the new viewer
                    UIManager:show(new_viewer)
                else
                    -- The active-viewer slot diverged while this reply was in flight
                    -- (screen rotation recreated the viewer via recreate_func, or a utility
                    -- view stacked on top). History and disk are updated below regardless;
                    -- without this branch the reply is silently never rendered and only
                    -- close/reopen recovers it (B5).
                    local target
                    if _G.ActiveChatViewer and _G.ActiveChatViewer.original_history == history then
                        -- Rotation recreated the viewer for THIS chat — render the live slot.
                        target = _G.ActiveChatViewer
                    elseif viewer and viewer.original_history == history then
                        -- A different viewer holds the slot (e.g. a stacked utility view);
                        -- the original reply viewer is still alive underneath — re-render it
                        -- so the reply is present when the stacked view is dismissed.
                        target = viewer
                    end
                    if target and target.update then
                        logger.info("KOAssistant: onAskQuestion fallback render — ActiveChatViewer slot changed under an in-flight reply")
                        local viewer_cfg = target.configuration or temp_config or CONFIGURATION
                        target:update(history:createResultText(highlightedText, viewer_cfg), true)
                    else
                        logger.warn("KOAssistant: onAskQuestion could not render the reply into a live viewer for this chat")
                    end
                end
            end

            -- Process the question with callback for streaming support
            -- IMPORTANT: Use viewer's cfg for the query, not the closure-captured temp_config
            -- This ensures expanded views use large_stream_dialog=true
            history:addUserMessage(question, false)
            BookToolRunner.queryWith(queryChatGPT, history:getMessages(), cfg, function(success, answer, err, reasoning, web_search_used)
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

                    -- Warn once if conversation context is getting large
                    if history:getAssistantTurnCount() > 1
                        and not history._context_warning_shown then
                        local system_text = cfg.system and cfg.system.text or ""
                        local token_estimate = history:estimateTokens(system_text)
                        if token_estimate > 50000 then
                            history._context_warning_shown = true
                            local token_k = math.floor(token_estimate / 1000)
                            UIManager:show(InfoMessage:new{
                                text = T(_("This conversation is using approximately %1K tokens. Each follow-up resends the full history. Consider starting a new chat to reduce costs and maintain quality."), token_k),
                            })
                        end
                    end

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
                        -- Store books_info for library context
                        if cfg.features.is_library_context and cfg.features.books_info then
                            metadata.books_info = cfg.features.books_info
                        end

                        -- Determine save path: check for action storage_key override
                        local storage_key = cfg.features and cfg.features.storage_key
                        local save_path
                        local should_save = true
                        local is_library = cfg.features.is_library_context or false

                        if storage_key == "__SKIP__" then
                            -- Don't save this chat
                            should_save = false
                            logger.info("KOAssistant: Skipping auto-save due to storage_key = __SKIP__")
                        elseif storage_key then
                            -- Use custom storage location
                            save_path = storage_key
                        else
                            -- Default: document path, general chats, or library chats
                            save_path = document_path
                                or (is_general_context and "__GENERAL_CHATS__")
                                or (is_library and "__LIBRARY_CHATS__")
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

                                -- Preserve existing tags, starred, and title when updating an existing chat
                                local existing_tags = {}
                                local existing_starred
                                local existing_title = suggested_title
                                local effective_chat_id = metadata.id or history.chat_id
                                if effective_chat_id and save_path then
                                    local existing = chat_history_manager:getChatById(save_path, effective_chat_id)
                                    if existing then
                                        existing_tags = existing.tags or {}
                                        existing_starred = existing.starred
                                        existing_title = existing.title or suggested_title
                                    end
                                end

                                local chat_data = {
                                    id = chat_id,
                                    title = existing_title or "Conversation",
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
                                    tags = existing_tags,
                                    starred = existing_starred,
                                    original_highlighted_text = metadata.original_highlighted_text,
                                    -- Store system prompt metadata for debug display
                                    system_metadata = cfg.system,
                                    -- Store cache continuation info (for "Updated from X% cache" notice)
                                    used_cache = history.used_cache,
                                    cached_progress = history.cached_progress,
                                    cache_action_id = history.cache_action_id,
                                    -- Store book text truncation info
                                    book_text_truncated = history.book_text_truncated,
                                    book_text_coverage_start = history.book_text_coverage_start,
                                    book_text_coverage_end = history.book_text_coverage_end,
                                    -- Store unavailable data info
                                    unavailable_data = history.unavailable_data,
                                }

                                if save_path == "__GENERAL_CHATS__" then
                                    save_result = chat_history_manager:saveGeneralChat(chat_data)
                                elseif save_path == "__LIBRARY_CHATS__" then
                                    save_result = chat_history_manager:saveLibraryChat(chat_data)
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
                    -- Roll the unanswered question back out of the history so it can't
                    -- silently ride into the next request (cancelled/failed replies).
                    history:removeLastUserMessage()
                    closeLoadingDialog()
                    UIManager:show(InfoMessage:new{
                        text = _("Failed to get response: ") .. (err or "Unknown error"),
                        timeout = 2,
                    })
                end
            end, plugin, ui_instance)

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
                -- Library chats have no document_path; route them to the library store, not general
                -- (audit C1: without this, Save duplicated the chat into general storage and
                --  getChatById searched the wrong store, dropping tags/title continuity).
                local is_library_context = temp_config and temp_config.features and temp_config.features.is_library_context
                local save_path = document_path
                    or (is_library_context and "__LIBRARY_CHATS__")
                    or "__GENERAL_CHATS__"
                -- Get config from viewer for system metadata
                local viewer_config = viewer and viewer.configuration
                local success, save_result = pcall(function()
                    -- Check storage version and route to appropriate method
                    if chat_history_manager:useDocSettingsStorage() then
                        -- v2: DocSettings-based storage
                        local chat_id = metadata.id or history.chat_id or chat_history_manager:generateChatId()

                        -- Preserve existing tags, starred, and title when updating an existing chat
                        local existing_tags = {}
                        local existing_starred
                        local existing_title = suggested_title
                        local effective_chat_id = metadata.id or history.chat_id
                        if effective_chat_id then
                            local existing = chat_history_manager:getChatById(save_path, effective_chat_id)
                            if existing then
                                existing_tags = existing.tags or {}
                                existing_starred = existing.starred
                                existing_title = existing.title or suggested_title
                            end
                        end

                        local chat_data = {
                            id = chat_id,
                            title = existing_title or "Conversation",
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
                            tags = existing_tags,
                            starred = existing_starred,
                            original_highlighted_text = metadata.original_highlighted_text,
                            -- Store system prompt metadata for debug display
                            system_metadata = viewer_config and viewer_config.system,
                            -- Store cache continuation info (for "Updated from X% cache" notice)
                            used_cache = history.used_cache,
                            cached_progress = history.cached_progress,
                            cache_action_id = history.cache_action_id,
                            -- Store book text truncation info
                            book_text_truncated = history.book_text_truncated,
                            book_text_coverage_start = history.book_text_coverage_start,
                            book_text_coverage_end = history.book_text_coverage_end,
                            -- Store unavailable data info
                            unavailable_data = history.unavailable_data,
                        }

                        if save_path == "__GENERAL_CHATS__" then
                            return chat_history_manager:saveGeneralChat(chat_data)
                        elseif save_path == "__LIBRARY_CHATS__" then
                            return chat_history_manager:saveLibraryChat(chat_data)
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
                createSaveDialog(document_path, history, chat_history_manager, is_general_context, book_metadata, launch_context, highlightedText, ui_instance, temp_config)
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
                -- Extract books_info for library context
                local books_info = features.is_library_context and features.books_info or nil
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
            local Notification = require("ui/widget/notification")
            -- If chat not saved yet, force-save first
            if not history.chat_id then
                local viewer = _G.ActiveChatViewer
                if viewer and viewer.save_callback then
                    viewer.save_callback()
                end
                if not history.chat_id then
                    UIManager:show(Notification:new{
                        text = _("Save the chat first to add tags"),
                        timeout = 2,
                    })
                    return
                end
            end

            -- Show tag management dialog for this chat
            local chat_id = history.chat_id

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
        get_pin_state = getPinState,
        get_star_state = getStarState,
        pin_callback = function()
            local Notification = require("ui/widget/notification")
            local last_response, last_prompt = getLastResponseAndPrompt()
            if last_response == "" then
                UIManager:show(Notification:new{
                    text = _("No response to pin"),
                    timeout = 2,
                })
                return
            end

            local PinnedManager = require("koassistant_pinned_manager")
            local is_pinned, existing_pin_id = getPinState()

            if is_pinned then
                -- Unpin
                if PinnedManager.removePin(pin_star_path, existing_pin_id) then
                    UIManager:show(Notification:new{
                        text = _("Unpinned from Artifacts"),
                        timeout = 2,
                    })
                end
            else
                -- Pin last AI response — show naming dialog
                local default_name = history:getPinTitle() or ""

                local pin_name_dialog
                pin_name_dialog = InputDialog:new{
                    title = _("Pin as Artifact"),
                    input = default_name,
                    input_hint = _("Enter a name for this artifact"),
                    buttons = {
                        {
                            {
                                text = _("Cancel"),
                                id = "close",
                                callback = function()
                                    UIManager:close(pin_name_dialog)
                                end,
                            },
                            {
                                text = _("Pin"),
                                is_enter_default = true,
                                callback = function()
                                    local pin_name = pin_name_dialog:getInputText()
                                    if not pin_name or pin_name == "" then
                                        UIManager:show(require("ui/widget/infomessage"):new{
                                            text = _("Please enter a name."),
                                            timeout = 2,
                                        })
                                        return
                                    end
                                    if #pin_name > 80 then pin_name = pin_name:sub(1, 80) end
                                    UIManager:close(pin_name_dialog)

                                    local is_multi = temp_config and temp_config.features and temp_config.features.is_library_context
                                    local pin_entry = {
                                        id = PinnedManager.generateId(),
                                        name = pin_name,
                                        action_id = history.prompt_action or "chat",
                                        action_text = history.prompt_action or _("Chat"),
                                        result = last_response,
                                        user_prompt = last_prompt,
                                        timestamp = os.time(),
                                        model = history:getModel() or "",
                                        context_type = is_multi and "library" or (document_path and "book" or "general"),
                                        book_title = book_metadata and book_metadata.title,
                                        book_author = book_metadata and book_metadata.author,
                                        document_path = pin_star_path,
                                    }

                                    if PinnedManager.addPin(pin_star_path, pin_entry) then
                                        UIManager:show(Notification:new{
                                            text = _("Pinned to Artifacts"),
                                            timeout = 2,
                                        })
                                    else
                                        UIManager:show(Notification:new{
                                            text = _("Failed to pin"),
                                            timeout = 2,
                                        })
                                    end
                                end,
                            },
                        },
                    },
                }
                UIManager:show(pin_name_dialog)
                pin_name_dialog:onShowKeyboard()
            end
        end,
        star_callback = function()
            local Notification = require("ui/widget/notification")
            -- If chat not saved yet, force-save first
            if not history.chat_id then
                local viewer = _G.ActiveChatViewer
                if viewer and viewer.save_callback then
                    viewer.save_callback()
                end
                if not history.chat_id then
                    UIManager:show(Notification:new{
                        text = _("Save the chat first to star it"),
                        timeout = 2,
                    })
                    return
                end
            end

            local is_starred = getStarState()
            if is_starred then
                chat_history_manager:unstarChat(pin_star_path, history.chat_id)
                UIManager:show(Notification:new{
                    text = _("Chat unstarred"),
                    timeout = 2,
                })
            else
                chat_history_manager:starChat(pin_star_path, history.chat_id)
                UIManager:show(Notification:new{
                    text = _("Chat starred"),
                    timeout = 2,
                })
            end
        end,
        close_callback = function()
            -- Hand the slot back to the chat viewer a utility view stacked over (nil in
            -- the normal, non-stacked case). Also fills an EMPTY slot: the expand-view
            -- wrappers (chatgptviewer expandToFullView/expandToDictionaryView) nil the
            -- slot before delegating here, so equality alone could never restore.
            if _G.ActiveChatViewer == chatgpt_viewer or _G.ActiveChatViewer == nil then
                _G.ActiveChatViewer = restore_active_viewer
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
            -- Store books_info for library context
            if temp_config.features.is_library_context and temp_config.features.books_info then
                metadata.books_info = temp_config.features.books_info
            end

            -- Determine save path: check for action storage_key override
            local storage_key = temp_config.features and temp_config.features.storage_key
            local save_path
            local should_save = true
            local is_library = temp_config.features.is_library_context or false

            if storage_key == "__SKIP__" then
                -- Don't save this chat
                should_save = false
                logger.info("KOAssistant: Skipping auto-save due to storage_key = __SKIP__")
            elseif storage_key then
                -- Use custom storage location
                save_path = storage_key
            else
                -- Default: document path, general chats, or library chats
                save_path = document_path
                    or (is_general_context and "__GENERAL_CHATS__")
                    or (is_library and "__LIBRARY_CHATS__")
                    or nil
            end

            if should_save then
                local result
                -- Check storage version and route to appropriate method
                if chat_history_manager:useDocSettingsStorage() then
                    -- v2: DocSettings-based storage
                    local chat_id = metadata.id or history.chat_id or chat_history_manager:generateChatId()

                    -- Preserve existing tags, starred, and title when updating an existing chat
                    local existing_tags = {}
                    local existing_starred
                    local existing_title = suggested_title
                    local effective_chat_id = metadata.id or history.chat_id
                    if effective_chat_id and save_path then
                        local existing = chat_history_manager:getChatById(save_path, effective_chat_id)
                        if existing then
                            existing_tags = existing.tags or {}
                            existing_starred = existing.starred
                            existing_title = existing.title or suggested_title
                        end
                    end

                    local chat_data = {
                        id = chat_id,
                        title = existing_title or "Conversation",
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
                        tags = existing_tags,
                        starred = existing_starred,
                        original_highlighted_text = metadata.original_highlighted_text,
                        -- Store system prompt metadata for debug display
                        system_metadata = temp_config.system,
                        -- Store cache continuation info (for "Updated from X% cache" notice)
                        used_cache = history.used_cache,
                        cached_progress = history.cached_progress,
                        cache_action_id = history.cache_action_id,
                        -- Store book text truncation info
                        book_text_truncated = history.book_text_truncated,
                        book_text_coverage_start = history.book_text_coverage_start,
                        book_text_coverage_end = history.book_text_coverage_end,
                        -- Store unavailable data info
                        unavailable_data = history.unavailable_data,
                    }

                    if save_path == "__GENERAL_CHATS__" then
                        result = chat_history_manager:saveGeneralChat(chat_data)
                    elseif save_path == "__LIBRARY_CHATS__" then
                        result = chat_history_manager:saveLibraryChat(chat_data)
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
-- @param context: The context type (highlight, book, library, general)
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

-- Forward declaration (assigned as function expression below)
local handlePredefinedPrompt

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

    -- Create a temporary configuration using the passed config as base
    local temp_config = createTempConfig(prompt, config)
    -- The per-chat Web value (if any) rode into temp_config with the features copy;
    -- consume it from the SOURCE config so it can't go stale on the shared table.
    if config and config.features then
        config.features._web_search_active = nil
        -- Quick controls: consume the dispatch consumables AND the chip state from
        -- the SOURCE config (same staleness rule — the copies already rode into
        -- temp_config; a direct entry with chip state lingering from an abandoned
        -- dialog also gets cleaned up here, and stays inert because bake reads
        -- only the *_active keys, which direct entries never set).
        config.features._quick_answer_active = nil
        config.features._reasoning_override_active = nil
        config.features._model_override_active = nil
        config.features._session_quick_answer = nil
        config.features._session_reasoning = nil
        config.features._session_model = nil
    end
    -- Attach chip: consume the just-in-time dispatch flag from the SOURCE config,
    -- same staleness rule as above. The block itself is built from the module
    -- staging list at the injection site below (never stored on features — the
    -- shared features table is settings-flush-exposed).
    local attachments_active = config and config.features and config.features._attachments_active
    if config and config.features then
        config.features._attachments_active = nil
    end
    -- Background auto-update (xray_background_plan.md §4): consume the dispatch flag
    -- (the fire path passes a config COPY, but consume defensively — same staleness
    -- rule as the transients above) and force the silent wire mode on the temp copy:
    -- non-streaming, no loading dialog, cancel handle registered with the auto module.
    -- Downstream checks read message_data._background_request (set below) — message_data
    -- is already captured by the closures here, so no new upvalues (60-upvalue cap).
    local background_request = config and config.features and config.features._background_request
    local background_create = config and config.features and config.features._background_create
    if config and config.features then
        config.features._background_request = nil
        config.features._background_create = nil
    end
    if background_request then
        temp_config.features = temp_config.features or {}
        temp_config.features.enable_streaming = false
        temp_config.features._suppress_loading_dialog = true
        temp_config.features._background_request = true
        temp_config._register_cancel = function(cancel)
            require("koassistant_xray_auto").registerCancel(cancel)
        end
    end
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

    -- Apply dictionary view settings (shared between compact and dictionary views)
    if prompt.compact_view or prompt.dictionary_view then
        temp_config.features = temp_config.features or {}
        if prompt.compact_view then
            temp_config.features.compact_view = true
            temp_config.features.large_stream_dialog = false  -- Small streaming dialog for compact
        end
        if prompt.dictionary_view then
            temp_config.features.dictionary_view = true
        end
        temp_config.features.hide_highlighted_text = true  -- Hide quote by default in dictionary modes

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

    -- Propagate action-level storage_key to config features (e.g., "__SKIP__" for X-Ray)
    if prompt.storage_key then
        temp_config.features = temp_config.features or {}
        temp_config.features.storage_key = prompt.storage_key
    end

    -- Hide streaming output for interactive quiz (avoid spoiling answers)
    if prompt.interactive_quiz then
        temp_config.features = temp_config.features or {}
        temp_config.features.hidden_streaming = true
    end

    -- NEW ARCHITECTURE (v0.5.2+): Unified request config for all providers
    -- System prompt is built by buildUnifiedRequestConfig and passed in config.system
    -- No longer embedded in the consolidated message

    -- Create history WITHOUT system prompt (we'll include it in the consolidated message)
    -- Pass prompt text for better chat naming
    local history = MessageHistory:new(nil, prompt.text)

    -- Store source data for title generation (avoids fragile regex on message content)
    -- Skip for book-level actions where highlightedText is synthetic book metadata (Title: X. Author: Y.)
    local is_book_level = config.features and config.features._is_book_level_action
    if highlightedText and highlightedText ~= "" and not is_book_level then
        history.source_highlight = highlightedText
    end
    -- For book-level actions with section scope, use section label for chat naming
    if is_book_level then
        local section_scope = config.features and (config.features._section_scope or config.features._section_xray)
        if section_scope and section_scope.label then
            history.source_highlight = section_scope.label
        end
    end
    if additional_input and additional_input ~= "" then
        history.source_input = additional_input
    end

    -- Determine context
    local context = getPromptContext(config)

    -- Resolve per-book DocSettings once here. Shared by the per-book language overrides
    -- (just below), the quiz overrides, the AI title/author override, the book-info level,
    -- and research-mode resolution further down.
    -- A highlight always belongs to the open book, so ui.document.file wins there:
    -- book_metadata on the shared configuration can be stale from an earlier file-browser/
    -- book-level action on a DIFFERENT book (quick actions and the dictionary popup don't
    -- repopulate it), which would resolve every per-book setting against the wrong book's
    -- sidecar. Other contexts keep preferring book_metadata.file (file browser/artifact
    -- target); book-level entries repopulate it for their target before reaching here.
    local per_book_file
    if context == "highlight" and ui and ui.document and ui.document.file then
        per_book_file = ui.document.file
    else
        per_book_file = (config.features and config.features.book_metadata and config.features.book_metadata.file)
            or (ui and ui.document and ui.document.file)
    end
    local per_book_ds = nil
    if per_book_file then
        per_book_ds = SafeDocSettings.resolve(per_book_file, ui)
    end

    -- Resolve effective translation + dictionary languages (uses SystemPrompts for
    -- consistency). A per-book language override (Book Settings ▸ Languages) is folded in
    -- first, so this book can target a different language than the global default.
    local SystemPrompts = require("prompts.system_prompts")
    local lang_config = require("koassistant_book_settings").applyLanguageOverride({
        dictionary_language = config.features.dictionary_language,
        translation_use_primary = config.features.translation_use_primary,
        interaction_languages = config.features.interaction_languages,
        user_languages = config.features.user_languages,
        primary_language = config.features.primary_language,
        translation_language = config.features.translation_language,
    }, per_book_ds)
    local effective_translation_language = SystemPrompts.getEffectiveTranslationLanguage(lang_config)
    local effective_dictionary_language = SystemPrompts.getEffectiveDictionaryLanguage(lang_config)
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
    -- Consume X-Ray context prefix (transient flag set by action buttons from chatAboutItem)
    local xray_prefix = config.features and config.features._xray_context_prefix
    if config.features then config.features._xray_context_prefix = nil end

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
        -- Mode: dict-popup/bypass launches mark their config copies with
        -- _dictionary_context_explicit — their mode is authoritative (the popup wrote
        -- the already-resolved value, and the compact viewer's CTX+ toggle re-runs
        -- inherit the marker so its session mode beats a per-book override). Every
        -- other path resolves per-book > global, matching what its entry extracted with.
        dictionary_context_mode = (config.features._dictionary_context_explicit
                and config.features.dictionary_context_mode)
            or BookSettings.resolveDictionaryContext(per_book_ds, config.features),
        -- X-Ray context prefix (injected before action prompt in message builder)
        request_prefix = xray_prefix,
        -- Background auto-update marker (read by the abort/guard/pre-send checks)
        _background_request = background_request or nil,
        -- Auto-create marker (§5 decision 1): permits the fresh path in the §4 abort
        _background_create = background_create or nil,
    }
    logger.info("KOAssistant: message_data.book_metadata=", message_data.book_metadata and "present" or "nil")

    -- Build dynamic quiz instructions from settings (for interactive quiz actions).
    -- Per-book quiz overrides (Book Settings ▸ Quiz) take precedence over the globals.
    if prompt and prompt.interactive_quiz then
        local quiz = BookSettings.resolveQuiz(per_book_ds, config.features)
        message_data.quiz_instructions = require("koassistant_quiz_prompt").build(quiz)
    end

    -- Add book info for highlight context when:
    -- 1. include_book_context is enabled for the prompt, OR
    -- 2. The prompt uses template variables that require book info
    -- Try to get from ui.document first, then fall back to passed book_metadata
    if context == "highlight" then
        -- Non-document selection (in-plugin viewer / dictionary popup / DQL origin): the
        -- selection is not the open book, so the request must not pull the open book's
        -- identity or surrounding context (B3 — tafsir/Quran leak). Consume once.
        local non_document_selection = config.features._non_document_selection
        config.features._non_document_selection = nil

        local should_include_book = prompt.include_book_context

        -- Also include if prompt uses book-related placeholders
        local prompt_text = prompt.prompt
        if not should_include_book and prompt_text then
            should_include_book = prompt_text:find("{title}") or
                                  prompt_text:find("{author}") or
                                  prompt_text:find("{author_clause}")
        end

        -- Skipped entirely for non-document selections: BOTH ui.doc_props AND the passed
        -- book_metadata (which executeDirectAction derives from the still-open document,
        -- unaware of this flag) are the OPEN book's identity — unrelated to the viewer/popup
        -- text. Injecting either is the identity leak (B3 — tafsir/Quran case).
        if should_include_book and not non_document_selection then
            -- Try KOReader's merged props first (includes user edits from Book Info dialog)
            if ui and ui.doc_props then
                message_data.book_title = ui.doc_props.display_title or ui.doc_props.title
                local raw_author = ui.doc_props.authors
                if raw_author and raw_author:find("\n") then
                    raw_author = raw_author:gsub("\n", ", ")
                end
                message_data.book_author = raw_author
            end
            -- Fall back to passed book_metadata if not available
            if not message_data.book_title and book_metadata then
                message_data.book_title = book_metadata.title
                message_data.book_author = book_metadata.author
            end
            -- Pass DOI clause from book metadata (for {doi_clause} placeholder)
            if book_metadata and book_metadata.doi_clause then
                message_data.doi_clause = book_metadata.doi_clause
            end
        end

        -- Extract surrounding context for dictionary action if not already provided
        -- Check both string ID and action object ID
        local action_id = type(prompt_type_or_action) == "table" and prompt_type_or_action.id or prompt_type_or_action
        -- non_document_selection guard: a dictionary lookup launched from a viewer/popup
        -- already had its context deliberately cleared — don't re-extract from the open
        -- book's live selection (B3).
        if action_id == "dictionary" and not non_document_selection
                and (not message_data.context or message_data.context == "") then
            -- Resolved per-book > global mode; "none" extracts nothing
            local context_chars = config.features.dictionary_context_chars or 100
            message_data.context = extractSurroundingContext(ui, highlightedText,
                message_data.dictionary_context_mode, context_chars)
        end

        -- Surrounding context (surrounding_context_plan.md): per-action tri-state over
        -- the ambient per-book/global mode. Entry points pre-extract the raw window into
        -- the _selection_context_window transient before the selection dies with the
        -- overlay; it is trimmed to the resolved mode here. The fingerprint check
        -- (window.text) makes a stale window from another selection self-discarding.
        -- X-Ray's forced context (wiki disambiguation) keeps its flag-gated priority,
        -- and X-Ray chat launches (xray_prefix) never get ambient context.
        local sc_window = config.features._selection_context_window
        config.features._selection_context_window = nil  -- consume: one launch per entry
        -- Session override (Scope chip, highlight facet — dialog-launched only): the
        -- just-in-time _highlight_context_active transient wins over per-book/global;
        -- "none" is an explicit session OFF. Explicit per-action modes still win
        -- inside effectiveSurroundingContextMode.
        local session_ctx = config.features._highlight_context_active
        config.features._highlight_context_active = nil  -- consume
        local sc_mode = PromptsActions.effectiveSurroundingContextMode(
            prompt, config.features,
            session_ctx or BookSettings.resolveHighlightContext(per_book_ds, config.features))
        if config.features._forced_surrounding_context then
            if prompt.use_surrounding_context then
                message_data.surrounding_context = config.features._forced_surrounding_context
            end
        elseif sc_mode and not xray_prefix then
            local sc_chars = prompt.context_chars or config.features.highlight_context_chars or 100
            local sc_paragraphs = config.features.highlight_context_paragraphs or 1
            local sc_text
            if sc_window and sc_window.text == highlightedText then
                sc_text = ScopeResolver.trimContext(sc_window.prev, sc_window.next, highlightedText,
                    sc_mode, { char_count = sc_chars, paragraphs = sc_paragraphs })
            elseif not non_document_selection then
                -- Surfaces that didn't pre-extract: try the live selection (may be gone).
                -- Skipped for non-document selections: the live selection is the open
                -- book's, unrelated to the viewer/popup text (B3).
                sc_text = extractSurroundingContext(ui, highlightedText, sc_mode, sc_chars, sc_paragraphs)
            end
            if sc_text and sc_text ~= "" then
                message_data.surrounding_context = sc_text
            end
        end
    end

    -- For book context, ensure book_metadata is populated
    -- This provides a fallback when config.features.book_metadata isn't set
    if context == "book" or context == "file_browser" then
        if not message_data.book_metadata and ui and ui.doc_props then
            local props = ui.doc_props
            local title = props.display_title or props.title or "Unknown"
            local authors = props.authors or ""
            if authors:find("\n") then
                authors = authors:gsub("\n", ", ")
            end
            message_data.book_metadata = {
                title = title,
                author = authors,
                author_clause = (authors ~= "") and (" by " .. authors) or "",
            }
            logger.info("KOAssistant: book_metadata populated from ui.doc_props for book context")
        end
    end

    -- per_book_ds (per-book DocSettings) is resolved earlier, just above the quiz builder.

    -- Apply per-book AI title/author override to what the AI sees (never library metadata).
    -- Covers the highlight path (book_title/book_author read straight from doc_props) and any
    -- book_metadata built from the doc_props fallback above.
    do
        local ai_title, ai_author = BookSettings.getMetadataOverride(per_book_ds)
        -- nil = no override; "" = send empty; string = custom (so test ~= nil, not truthiness)
        if ai_title ~= nil or ai_author ~= nil then
            if message_data.book_metadata then
                message_data.book_metadata = BookSettings.applyMetadataOverride(message_data.book_metadata, per_book_ds)
            end
            if ai_title ~= nil and message_data.book_title then message_data.book_title = ai_title end
            if ai_author ~= nil and message_data.book_author then message_data.book_author = ai_author end
        end
    end

    -- Resolve the per-book "book info" level for the generic [Context] auto-block (per-book > global).
    -- "none" suppresses it; explicit {title}/{author} placeholders are unaffected.
    message_data._book_info_level = require("koassistant_book_settings").resolveBookInfoLevel(
        per_book_ds, config.features)

    -- Resolve effective research mode
    -- Priority: action override > per-book setting > DOI auto-detection > global setting
    -- DOI scan always runs independently (for {doi_clause} placeholder) — this only controls behavior
    local research_mode_active = false
    local action_research = prompt and prompt.research_mode
    if action_research == true then
        research_mode_active = true
    elseif action_research == false then
        research_mode_active = false
    else
        local book_research = getBookResearchMode(per_book_ds)
        if book_research == true then
            research_mode_active = true
        elseif book_research == false then
            research_mode_active = false
        else
            local has_doi = config.features and config.features.book_metadata
                and config.features.book_metadata.doi
            if has_doi then
                research_mode_active = true
            else
                research_mode_active = config.features and config.features.research_mode == true
            end
        end
    end

    -- Research mode active: swap to academic prompt track (if available)
    -- Must happen BEFORE full-document swap so doi_complete_prompt is available
    -- Stash originals so cache update can revert if needed (cache was non-research but current is research)
    if research_mode_active and prompt and prompt.doi_prompt then
        local original_prompt = prompt
        prompt = {}
        for k, v in pairs(original_prompt) do prompt[k] = v end
        prompt._original_prompt_text = original_prompt.prompt
        prompt._original_update_prompt = original_prompt.update_prompt
        prompt._original_complete_prompt = original_prompt.complete_prompt
        prompt.prompt = original_prompt.doi_prompt
        if original_prompt.doi_complete_prompt then
            prompt.complete_prompt = original_prompt.doi_complete_prompt
        end
        if original_prompt.doi_update_prompt then
            prompt.update_prompt = original_prompt.doi_update_prompt
        end
    end

    -- Full-document X-Ray: use complete_prompt (different schema, no spoiler restrictions)
    -- Must happen BEFORE extractForAction() so placeholder detection picks {full_document_section}
    if config.features and config.features._full_document_xray and prompt and prompt.complete_prompt then
        local original_prompt = prompt
        prompt = {}
        for k, v in pairs(original_prompt) do
            prompt[k] = v
        end
        prompt.prompt = original_prompt.complete_prompt
    end

    -- Source mode: skip expensive text extraction when user chose summary or AI knowledge
    -- Also propagate _source_mode to message_data for {document_context_section} resolution
    -- Capture and clear transient flags to prevent leaking across invocations
    local source_mode = config.features and config.features._source_mode
    local highlight_section = config.features and config.features._highlight_section_scope
    local forced_document_context = config.features and config.features._forced_document_context
    local smart_retrieval_lookups = config.features and config.features._smart_retrieval_lookups
    if config.features then
        config.features._source_mode = nil
        config.features._highlight_section_scope = nil
        config.features._forced_document_context = nil
        config.features._smart_retrieval_lookups = nil
    end
    -- Smart retrieval (D3): thread the standalone gather's lookup info to handleResponse
    -- via this invocation's message_data (folded into the response provenance there)
    if smart_retrieval_lookups then
        message_data._smart_retrieval_lookups = smart_retrieval_lookups
    end

    -- Source mode: skip extraction for non-selected sources
    -- Also propagate _source_mode to message_data for {document_context_section} resolution
    if source_mode then
        message_data._source_mode = source_mode
        if source_mode ~= "full_text" then
            -- Summary or AI knowledge: skip text extraction
            if not prompt._is_copy then
                local original_prompt = prompt
                prompt = {}
                for k, v in pairs(original_prompt) do
                    prompt[k] = v
                end
                prompt._is_copy = true
            end
            prompt.use_book_text = false
        end
        if source_mode ~= "summary" then
            -- Full text or AI knowledge: skip summary cache loading
            if not prompt._is_copy then
                local original_prompt = prompt
                prompt = {}
                for k, v in pairs(original_prompt) do
                    prompt[k] = v
                end
                prompt._is_copy = true
            end
            prompt.use_summary_cache = false
        end
        -- AI knowledge only: allow web search to follow global setting
        -- (these actions have enable_web_search = false, but without document text
        -- web search becomes useful for verification)
        if source_mode == "ai_knowledge" and prompt.enable_web_search == false then
            prompt.enable_web_search = nil
        end
        -- Smart retrieval (D3 — tools_ux_plan.md §4): the pre-gathered bundle stands in
        -- for extracted text; {document_context_section} resolves it via the
        -- "smart_retrieval" branch in message_builder. Mirrors _forced_surrounding_context.
        -- Safe from overwrite: use_book_text was forced false above, so the extractor's
        -- full_document block never runs. An empty bundle (zero-gather) is NOT injected —
        -- the section resolves empty and {text_fallback_nudge} fires (honest degradation).
        if source_mode == "smart_retrieval" and forced_document_context
                and forced_document_context ~= "" then
            message_data.full_document = forced_document_context
        end
    end

    -- Research mode web search override: academic papers benefit from web enrichment
    -- Actions with doi_web_override=true have their enable_web_search=false lifted to nil
    -- (follow global setting) when research mode is active
    if research_mode_active
            and prompt.doi_web_override and prompt.enable_web_search == false then
        prompt.enable_web_search = nil
    end

    -- Highlight section scope: limit text extraction to a specific section's page range.
    -- Set by unified action popup when highlight actions are scoped to a section.
    -- Only affects text extraction (book_text, full_document) — not cache saving.
    if highlight_section then
        if not prompt._is_copy then
            local original_prompt = prompt
            prompt = {}
            for k, v in pairs(original_prompt) do
                prompt[k] = v
            end
            prompt._is_copy = true
        end
        prompt._section_scope = highlight_section
    end

    -- Context extraction: auto-extract data when a document is open or path is available
    -- Trust must be evaluated against the provider the request is ACTUALLY dispatched to.
    -- queryChatGPT dispatches on temp_config.provider (= the action's pinned provider when set,
    -- else the global). Evaluating trust against the global features.provider instead would let
    -- an action pinned to an untrusted provider bypass every data-sharing gate via a trusted
    -- global — data going to a provider the user never trusted. (audit v0.20.0 finding C4)
    local effective_provider = (temp_config and temp_config.provider)
        or (config.features and config.features.provider)

    -- Open book: full extraction (text, highlights, annotations, stats, etc.)
    -- File browser (sidecar): highlights, annotations, notebook, progress, caches from disk
    local cfg_metadata = config.features and config.features.book_metadata
    local open_doc_file = ui and ui.document and ui.document.file
    local fb_document_path = cfg_metadata and cfg_metadata.file or nil
    -- File browser target: book_metadata.file is set and it's NOT the currently open document
    -- When the target IS the open book, prefer live extraction (more data available)
    local is_file_browser_target = fb_document_path and fb_document_path ~= open_doc_file

    if ui and ui.document and not is_file_browser_target then
        local extraction_success, ContextExtractor = pcall(require, "koassistant_context_extractor")
        if extraction_success and ContextExtractor then
            local extractor = ContextExtractor:new(ui, {
                -- Extraction limits
                enable_book_text_extraction = config.features and config.features.enable_book_text_extraction,
                max_book_text_chars = prompt and prompt.max_book_text_chars or (config.features and config.features.max_book_text_chars),
                max_pdf_pages = config.features and config.features.max_pdf_pages,
                -- Privacy settings
                provider = effective_provider,
                trusted_providers = config.features and config.features.trusted_providers,
                enable_highlights_sharing = config.features and config.features.enable_highlights_sharing,
                enable_annotations_sharing = config.features and config.features.enable_annotations_sharing,
                enable_basic_stats = config.features and config.features.enable_basic_stats,
                enable_notebook_sharing = config.features and config.features.enable_notebook_sharing,
                -- Library scanning (session folders from library dialog override permanent config)
                enable_library_scanning = config.features and config.features.enable_library_scanning,
                enable_advanced_stats = config.features and config.features.enable_advanced_stats,
                library_scan_folders = config.features and config.features.library_scan_folders,
                _session_scan_folders = plugin and plugin._session_scan_folders,
            })
            logger.info("KOAssistant: Extractor settings - enable_book_text_extraction=",
                       config.features and config.features.enable_book_text_extraction and "true" or "false/nil")
            if extractor:isAvailable() then
                logger.info("KOAssistant: Context extraction starting for action:", prompt and prompt.id or "unknown")
                logger.info("KOAssistant: use_book_text=", prompt and prompt.use_book_text and "true" or "false")
                -- Background auto-update: the base prompt's {book_text_section} would trigger
                -- a full to-position extraction that the update prompt never consumes (it uses
                -- only the delta, extracted in the cache block below) — and a background run
                -- that does NOT engage the incremental path aborts anyway. Skip the expensive
                -- part on a pruned COPY (never mutate the shared action table); progress /
                -- highlights extraction still runs. EXCEPT auto-create (§5 decision 1):
                -- a first generation IS the base prompt — it needs the to-position text
                -- (bounded by the max-gap dial, same bound as an update's delta).
                local extract_prompt = prompt or {}
                if message_data._background_request and extract_prompt.use_book_text
                    and not message_data._background_create then
                    local pruned = {}
                    for k, v in pairs(extract_prompt) do pruned[k] = v end
                    pruned.use_book_text = false
                    extract_prompt = pruned
                end
                local extracted = extractor:extractForAction(extract_prompt)
                -- Merge extracted data into message_data
                for key, value in pairs(extracted) do
                    message_data[key] = value
                    logger.info("KOAssistant: Extracted data key=", key, "value_len=", type(value) == "string" and #value or "non-string")
                end
                logger.info("KOAssistant: Context extraction complete")

                -- Compute flow fingerprint for cache staleness detection
                message_data.flow_visible_pages = ContextExtractor.getFlowFingerprint(ui.document)

                -- Truncation metadata (book_text_truncated, full_document_truncated, coverage_*)
                -- is stored in message_data via extraction merge above.
                -- Warning dialog fires later in the pre-send check chain.
            end
        else
            logger.warn("KOAssistant: Failed to load context extractor:", ContextExtractor)
        end
    elseif fb_document_path then
        -- File browser context: extract sidecar data (highlights, annotations, notebook, progress, caches)
        -- No live document — LIVE_BOOK_FLAGS (book_text, page_text, reading_stats) will return empty
        local extraction_success, ContextExtractor = pcall(require, "koassistant_context_extractor")
        if extraction_success and ContextExtractor then
            local extractor = ContextExtractor:new(nil, {
                document_path = fb_document_path,
                -- Text extraction (needed for cache permission checks)
                enable_book_text_extraction = config.features and config.features.enable_book_text_extraction,
                -- Privacy settings
                provider = effective_provider,
                trusted_providers = config.features and config.features.trusted_providers,
                enable_highlights_sharing = config.features and config.features.enable_highlights_sharing,
                enable_annotations_sharing = config.features and config.features.enable_annotations_sharing,
                enable_basic_stats = config.features and config.features.enable_basic_stats,
                enable_notebook_sharing = config.features and config.features.enable_notebook_sharing,
            })
            logger.info("KOAssistant: Sidecar extraction for file browser:", fb_document_path)
            local extracted = extractor:extractForAction(prompt or {})
            for key, value in pairs(extracted) do
                message_data[key] = value
                logger.info("KOAssistant: Sidecar extracted key=", key, "value_len=", type(value) == "string" and #value or "non-string")
            end
        end
    elseif prompt and prompt.use_library then
        -- No open document but action needs library data — extract library only
        -- Global toggle is absolute gate; session folders bypass folder config only
        local lib_features = plugin and plugin.settings and plugin.settings:readSetting("features") or {}
        local lib_toggle = lib_features.enable_library_scanning == true
        -- Check trusted provider (against the effective dispatch provider — see C4 note above)
        if not lib_toggle and lib_features.trusted_providers and effective_provider then
            for _idx, tp in ipairs(lib_features.trusted_providers) do
                if tp == effective_provider then lib_toggle = true; break end
            end
        end
        local scan_folders_to_use
        if lib_toggle then
            scan_folders_to_use = plugin and plugin._session_scan_folders
            if not scan_folders_to_use then
                if lib_features.library_scan_folders and #lib_features.library_scan_folders > 0 then
                    scan_folders_to_use = lib_features.library_scan_folders
                end
            end
        end
        if scan_folders_to_use and #scan_folders_to_use > 0 then
            local scan_ok, LibraryScanner = pcall(require, "koassistant_library_scanner")
            if scan_ok and LibraryScanner then
                local scan_settings = { library_scan_folders = scan_folders_to_use }
                local scan_result = LibraryScanner.scan(scan_settings)
                if scan_result and scan_result.books and #scan_result.books > 0 then
                    -- Stats enrichment: engagement labels + group placeholders
                    -- Gated: enable_advanced_stats (opt-in) + use_advanced_stats per-action (double-gated)
                    local provider_trusted = lib_features.trusted_providers and effective_provider
                    if provider_trusted then
                        provider_trusted = false
                        for _idx, tp in ipairs(lib_features.trusted_providers) do
                            if tp == effective_provider then provider_trusted = true; break end
                        end
                    end
                    local stats_gated = prompt.use_advanced_stats
                        and (provider_trusted or lib_features.enable_advanced_stats == true)
                    if stats_gated then
                        local stats_ok, StatsReader = pcall(require, "koassistant_stats_reader")
                        if stats_ok and StatsReader then
                            local enriched = StatsReader.enrichBooks(scan_result.books)
                            if enriched then
                                -- Attach engagement labels for formatter display
                                for _idx, book in ipairs(scan_result.books) do
                                    book.engagement_label = StatsReader.getEngagementLabel(book)
                                end
                                -- Build group placeholders
                                message_data.stats_groups = StatsReader.buildAllGroups(scan_result.books)
                            end
                        end
                    end
                    local format_options = {}
                    if stats_gated and message_data.stats_groups then
                        format_options.include_engagement = true
                    end
                    message_data.library_content = LibraryScanner.format(scan_result, format_options)
                else
                    message_data.library_content = ""
                end
            end
        else
            message_data.library_content = ""
        end
    end

    -- Multi-book sidecar enrichment for library items actions
    -- When a library action declares sidecar flags (use_highlights, use_annotations, use_notebook),
    -- read per-book data from sidecars and attach to books_info entries for message_builder.
    if (context == "library" or context == "multi_file_browser")
            and message_data.books_info and prompt
            and (prompt.use_highlights or prompt.use_annotations or prompt.use_notebook) then
        local extraction_ok, ContextExtractor = pcall(require, "koassistant_context_extractor")
        if extraction_ok and ContextExtractor then
            -- Privacy checks (same gates as single-book sidecar extraction)
            -- Trust evaluated against the effective dispatch provider (see C4 note above)
            local provider_trusted = false
            local trusted_list = config.features and config.features.trusted_providers
            if trusted_list and effective_provider then
                for _idx, tp in ipairs(trusted_list) do
                    if tp == effective_provider then provider_trusted = true; break end
                end
            end
            local features = config.features or {}
            local highlights_allowed = provider_trusted
                or features.enable_highlights_sharing == true
                or features.enable_annotations_sharing == true
            local annotations_allowed = provider_trusted
                or features.enable_annotations_sharing == true
            local notebook_allowed = provider_trusted
                or features.enable_notebook_sharing == true

            local total_sidecar_chars = 0
            for _idx, book in ipairs(message_data.books_info) do
                if book.file then
                    -- Highlights
                    if prompt.use_highlights and highlights_allowed then
                        local annotations = ContextExtractor.readSidecarAnnotations(book.file)
                        local result = ContextExtractor.formatHighlights(annotations)
                        if result.formatted ~= "" then
                            book._highlights = result.formatted
                            book._highlights_count = result.count
                            total_sidecar_chars = total_sidecar_chars + #result.formatted
                        end
                    end

                    -- Annotations (with degradation)
                    if prompt.use_annotations and annotations_allowed then
                        local annotations = ContextExtractor.readSidecarAnnotations(book.file)
                        local result = ContextExtractor.formatAnnotations(annotations)
                        if result.formatted ~= "" then
                            book._annotations = result.formatted
                            book._annotations_count = result.count
                            book._annotations_degraded = false
                            total_sidecar_chars = total_sidecar_chars + #result.formatted
                        end
                    elseif prompt.use_annotations and highlights_allowed then
                        -- Degrade to highlights-only when annotations blocked
                        local annotations = ContextExtractor.readSidecarAnnotations(book.file)
                        local result = ContextExtractor.formatHighlights(annotations)
                        if result.formatted ~= "" then
                            book._annotations = result.formatted
                            book._annotations_count = result.count
                            book._annotations_degraded = true
                            total_sidecar_chars = total_sidecar_chars + #result.formatted
                        end
                    end

                    -- Notebook
                    if prompt.use_notebook and notebook_allowed then
                        local notebook_content = ContextExtractor.readSidecarNotebook(book.file)
                        if notebook_content ~= "" then
                            book._notebook = notebook_content
                            total_sidecar_chars = total_sidecar_chars + #notebook_content
                        end
                    end

                    -- Progress (for display in per-book headers)
                    local progress_allowed = provider_trusted or features.enable_basic_stats ~= false
                    if progress_allowed then
                        local progress = ContextExtractor.readSidecarProgress(book.file)
                        if progress.formatted ~= "" then
                            book._progress = progress.formatted
                        end
                    end
                end
            end
            message_data._total_sidecar_chars = total_sidecar_chars
        end
    end

    -- Full-document or update-to-100%: override progress to 100% so cache is stored at 1.0
    -- and extraction covers the entire document
    if config.features and (config.features._full_document_xray or config.features._update_to_full_progress or config.features._complete_analysis)
            and ui and ui.document then
        message_data.progress_decimal = "1.0"
        message_data.reading_progress = "100%"
        message_data.progress_page = ui.document.info and ui.document.info.number_of_pages
    end

    -- Get domain context if a domain is set (skip if action opts out)
    -- Priority: prompt.domain (locked) > book domain (DocSettings) > global selected_domain
    -- Book domain "_none" = explicit override to no domain (blocks global fallthrough)
    -- Uses per_book_ds hoisted earlier (shared with research mode resolution)
    local domain_context = nil
    local skip_domain = prompt and prompt.skip_domain
    local domain_id = nil
    if not skip_domain then
        if prompt and prompt.domain then
            domain_id = prompt.domain
        else
            local book_domain = getBookDomain(per_book_ds)
            if book_domain == "_none" then
                domain_id = nil  -- explicit none, skip global
            elseif book_domain then
                domain_id = book_domain
            else
                domain_id = config.features and config.features.selected_domain
            end
        end
    end
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
    -- Cache when: action supports it and file is known (open book or file browser metadata fallback)
    local using_cache = false
    local cached_progress_display = nil
    local cache_entry_existed = false
    local cache_file = (ui and ui.document and ui.document.file)
        or (config.features and config.features.book_metadata and config.features.book_metadata.file)
    local cache_enabled = prompt and prompt.use_response_caching and cache_file

    if cache_enabled and not (config.features and config.features._full_document_xray) then
        local ActionCache = require("koassistant_action_cache")
        local cached_entry = ActionCache.get(cache_file, prompt.id)
        cache_entry_existed = (cached_entry ~= nil and cached_entry.result ~= nil)

        if cached_entry and message_data.progress_decimal then
            local current_progress = tonumber(message_data.progress_decimal) or 0
            local cached_progress = cached_entry.progress_decimal or 0

            -- Research track consistency: force-match the track that built the cache.
            -- If cache was built with research mode ON but it's now OFF (or vice versa),
            -- re-swap prompts to maintain schema consistency during updates.
            -- Only applies when cache explicitly tracked research mode (non-nil).
            -- Legacy caches (nil) follow the current research mode setting.
            local cache_research = cached_entry.used_research_mode
            if cache_research ~= nil and cache_research ~= (research_mode_active or false) then
                research_mode_active = cache_research
                -- Re-apply (or undo) the academic prompt swap
                if cache_research and prompt.doi_prompt then
                    -- Cache was academic, current is not — swap to academic track
                    local original_prompt = prompt
                    prompt = {}
                    for k, v in pairs(original_prompt) do prompt[k] = v end
                    prompt.prompt = original_prompt.doi_prompt
                    if original_prompt.doi_complete_prompt then
                        prompt.complete_prompt = original_prompt.doi_complete_prompt
                    end
                    if original_prompt.doi_update_prompt then
                        prompt.update_prompt = original_prompt.doi_update_prompt
                    end
                end
                -- Note: if cache was NOT academic but current IS academic, the swap already
                -- happened at the top. We need to undo it by using the original non-doi prompts.
                -- The prompt was already copied, so doi_prompt fields are still on it.
                -- We can detect this: if prompt.prompt == prompt.doi_prompt (same swap), revert.
                -- Simpler: re-lookup the original action.
                if not cache_research and prompt._original_prompt_text then
                    local original_prompt = prompt
                    prompt = {}
                    for k, v in pairs(original_prompt) do prompt[k] = v end
                    prompt.prompt = original_prompt._original_prompt_text
                    prompt.update_prompt = original_prompt._original_update_prompt
                    prompt.complete_prompt = original_prompt._original_complete_prompt
                end
            end

            -- For X-Ray: skip incremental update if cache is legacy markdown (not JSON)
            -- Force a full regeneration to produce structured JSON output
            local XrayParser = require("koassistant_xray_parser")
            local skip_legacy = prompt.id == "xray" and not XrayParser.isJSON(cached_entry.result)
            if skip_legacy then
                logger.info("KOAssistant: Legacy markdown X-Ray cache detected, forcing full regeneration for JSON output")
            end

            -- AI-knowledge source: skip incremental update_prompt (it expects {incremental_book_text_section})
            -- Use fresh prompt with updated {reading_progress} instead (pseudo-update like X-Ray Simple)
            local skip_incremental = source_mode == "ai_knowledge" and prompt.update_prompt

            -- Cache permission re-check (audit v0.20.0 finding G5): the update path re-sends the
            -- cached result verbatim, so re-apply the same dynamic gate the extractor uses on
            -- cache-placeholder reads. A Recap/X-Ray cache built with text extraction / highlight
            -- sharing ON must not be re-sent after the user revokes consent (Recap has no
            -- `requires` field, so nothing else protects it). Trust is evaluated against the
            -- effective dispatch provider (consistent with C4). If a needed permission is now off,
            -- skip the cache and fall through to a fresh full generation.
            local cache_trusted = false
            if effective_provider and config.features and config.features.trusted_providers then
                for _idx, tid in ipairs(config.features.trusted_providers) do
                    if tid == effective_provider then
                        cache_trusted = true
                        break
                    end
                end
            end
            local cf = config.features or {}
            local cache_requires_text = cached_entry.used_book_text ~= false
            local cache_text_ok = not cache_requires_text
                or cache_trusted or cf.enable_book_text_extraction == true
            local cache_requires_highlights = cached_entry.used_highlights == true
                or (cached_entry.used_highlights == nil and cached_entry.used_annotations == true)
            local cache_highlights_ok = not cache_requires_highlights
                or cache_trusted or cf.enable_highlights_sharing == true
                or cf.enable_annotations_sharing == true
            local cache_read_allowed = cache_text_ok and cache_highlights_ok
            if not cache_read_allowed then
                logger.info("KOAssistant: Cached", prompt.id,
                    "result withheld from update - permission revoked since cache build")
            end

            -- Use cache if we've progressed by at least 1% since last time
            if not skip_legacy and not skip_incremental and cache_read_allowed
                    and current_progress > cached_progress + 0.01 and prompt.update_prompt then
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
                message_data.cached_progress_decimal = cached_progress
                -- Stash previous cache's metadata for sticky-true inheritance
                message_data.cached_used_book_text = cached_entry.used_book_text
                message_data.cached_used_highlights = cached_entry.used_highlights
                message_data.cached_used_annotations = cached_entry.used_annotations

                -- For X-Ray: parse cached result and build entity index for merge-based updates
                if prompt.id == "xray" and XrayParser.isJSON(cached_entry.result) then
                    local parsed_cache = XrayParser.parse(cached_entry.result)
                    if parsed_cache and not parsed_cache.error then
                        message_data.entity_index = XrayParser.buildEntityIndex(parsed_cache)
                        message_data._parsed_old_xray = parsed_cache
                    end
                end

                -- Get incremental book text (from cached to current position)
                -- If text extraction is disabled, getBookTextRange returns empty — AI updates from training knowledge
                local extraction_success, ContextExtractor = pcall(require, "koassistant_context_extractor")
                if extraction_success and ContextExtractor then
                    local extractor = ContextExtractor:new(ui, {
                        enable_book_text_extraction = config.features and config.features.enable_book_text_extraction,
                        max_book_text_chars = prompt.max_book_text_chars or (config.features and config.features.max_book_text_chars),
                        max_pdf_pages = config.features and config.features.max_pdf_pages,
                        -- Pass trust context so this extractor matches its siblings (audit G5 rider).
                        provider = effective_provider,
                        trusted_providers = config.features and config.features.trusted_providers,
                    })
                    -- Use raw page numbers for extraction range
                    -- (flow-aware progress * total_pages gives wrong pages when hidden flows active)
                    local total_pages = ui.document.info and ui.document.info.number_of_pages or 0
                    local from_page = cached_entry.progress_page
                        or math.floor(cached_progress * total_pages)
                    local to_page = tonumber(message_data.progress_page)
                        or math.floor(current_progress * total_pages)
                    local from_raw = total_pages > 0 and from_page / total_pages or cached_progress
                    local to_raw = total_pages > 0 and to_page / total_pages or current_progress
                    local range_result = extractor:getBookTextRange(from_raw, to_raw)
                    message_data.incremental_book_text = range_result.text
                    logger.info("KOAssistant: Extracted incremental book text:", range_result.char_count, "chars")

                    -- Store truncation metadata for pre-send warning dialog
                    if range_result.truncated and not range_result.disabled then
                        message_data.incremental_book_text_truncated = true
                        message_data.incremental_coverage_start = range_result.coverage_start
                        message_data.incremental_coverage_end = range_result.coverage_end
                    end
                end
            end
        end
    end

    -- Background auto-update invariant (xray_background_plan.md §4 — outcome-based,
    -- "abort, never fall through"): a user tap that misses the incremental path falls
    -- through to a FULL generation, which is correct; an unattended fire doing the same
    -- is an unconsented full-book spend. If `using_cache` did not engage — for ANY
    -- reason (missing entry, legacy cache, ai_knowledge source, revoked read gate,
    -- delta too small) — abort before any further extraction or send.
    if message_data._background_request and not using_cache then
        -- Auto-create carve-out (xray_ecosystem_plan.md §5 decision 1): the
        -- explicitly-flagged create path may run the fresh generation — but ONLY
        -- when no X-Ray exists at all. An existing-but-ineligible artifact
        -- (legacy, ai_knowledge, revoked read gate) stays manual.
        if message_data._background_create and not cache_entry_existed then
            logger.info("KOAssistant: background X-Ray create - fresh generation engaged")
        else
            logger.info("KOAssistant: background X-Ray update aborted - incremental path did not engage")
            if on_complete then on_complete(nil, "background: incremental update not applicable") end
            return nil
        end
    end

    -- Action-scoped history stopgap (action_history_plan.md v0.5): general
    -- actions whose prompt references {previous_results} get the assistant
    -- replies from their own recent saved runs injected. Matched by display
    -- text (stable for custom actions — user-authored, untranslated); needs
    -- saved runs (auto_save_all_chats default covers this). Inline requires:
    -- no new file-local upvalues in this function (60-upvalue cap).
    if context == "general" and prompt and type(prompt.prompt) == "string"
            and prompt.prompt:find("{previous_results", 1, true) then
        local ok_prev, prev = pcall(function()
            local Attachments = require("koassistant_attachments")
            local chats = require("koassistant_chat_history_manager"):new():getGeneralChats()
            return Attachments.buildPreviousResults(chats, prompt.text, 3)
        end)
        if ok_prev and prev then
            message_data.previous_results = prev
            logger.info("KOAssistant: previous_results injected, len=" .. #prev)
        end
    end

    -- Determine if web search will be active for this request
    -- Per-action override > per-chat toggle (dialog-launched actions) > per-book
    -- override > global setting
    -- Used by MessageBuilder to select web-aware hallucination nudge
    local action_ws = prompt and prompt.enable_web_search
    if action_ws == nil and config.features then
        action_ws = config.features._web_search_active
    end
    if action_ws == nil then
        action_ws = bookWebSearchOverride(config.features)
    end
    if action_ws ~= nil then
        message_data.web_search_active = action_ws
    else
        message_data.web_search_active = config.features and config.features.enable_web_search == true
    end

    -- Build and add the consolidated message
    -- System prompt and domain are now in config.system (unified approach)
    local consolidated_message = buildConsolidatedMessage(prompt, context, message_data, nil, nil, true)
    history:addUserMessage(consolidated_message, true)

    -- Attach chip (attach_plan.md §4): staged attachments follow the action's
    -- consolidated message as their own is_context message (gather-bundle
    -- pattern). AFTER, not before: Notebook.saveChat (and friends) treat the
    -- FIRST user message as THE context message.
    if attachments_active then
        local Attachments = require("koassistant_attachments")
        local attach_msg = Attachments.buildMessage(Attachments.getList())
        if attach_msg then
            history:addUserMessage(attach_msg, true)
        end
    end

    -- Store domain in history for saving with chat
    if domain_id then
        history.domain = domain_id
    end

    -- Track if user provided additional input
    local has_additional_input = additional_input and additional_input ~= ""

    -- Build unified request config for ALL providers
    -- Pass the prompt/action object which contains behavior_variant/behavior_override
    -- Pass resolved research mode as transient flag (consumed by buildUnifiedSystem)
    temp_config.features = temp_config.features or {}
    temp_config.features._research_mode_active = research_mode_active or nil
    local action = prompt._action or prompt  -- Use underlying action if available
    buildUnifiedRequestConfig(temp_config, domain_context, action, plugin)

    -- Capture the original action ID before any prompt modifications (for cache save)
    local original_action_id = prompt and prompt.id

    -- Get response from AI with callback for async streaming
    local function handleResponse(success, answer, err, reasoning, web_search_used)
        -- Smart retrieval (D3): the gather ran standalone before this request — fold its
        -- lookups into this response's provenance (per-message indicator + Show Sources)
        if success and message_data._smart_retrieval_lookups then
            if type(web_search_used) ~= "table" then
                web_search_used = web_search_used and { web_search = true } or {}
            end
            web_search_used.book_tools = web_search_used.book_tools
                or message_data._smart_retrieval_lookups
        end
        -- Plain boolean for cache metadata: a provenance TABLE means web search only
        -- when its web_search field says so (it may carry only book_tools)
        local web_search_flag = type(web_search_used) == "table"
            and (web_search_used.web_search == true)
            or (web_search_used == true)
        if success and answer and answer ~= "" then
            -- For X-Ray: parse structured JSON response and prepare display/cache versions
            -- display_answer = rendered markdown for chat history (human-readable)
            -- cache_answer = raw response for cache storage (JSON for structured browsing)
            local display_answer = answer
            local cache_answer = answer
            if action.cache_as_xray then
                local XrayParser = require("koassistant_xray_parser")
                local parsed = XrayParser.parse(answer)
                if parsed and parsed.error then
                    -- AI returned error (e.g., "I don't recognize this work") — show as plain text, skip caching
                    display_answer = parsed.error
                    cache_answer = nil  -- Signal to skip caching below
                    logger.info("KOAssistant: X-Ray returned error response, skipping cache:", parsed.error)
                elseif parsed then
                    -- Merge partial update into existing data when available
                    if using_cache and message_data._parsed_old_xray then
                        -- To debug X-Ray merge: uncomment koassistant_debug_utils.dumpXrayMerge() below
                        parsed = XrayParser.merge(message_data._parsed_old_xray, parsed)
                        logger.info("KOAssistant: Merged incremental X-Ray update into existing data")
                    end
                    local book_meta = message_data.book_metadata or {}
                    local display_progress = message_data.reading_progress or ""
                    if config.features and config.features._full_document_xray then
                        display_progress = "Complete"
                    end
                    display_answer = XrayParser.renderToMarkdown(
                        parsed,
                        book_meta.title or "",
                        display_progress
                    )
                    -- Pretty-print cached JSON so future updates receive readable structured data
                    local json_mod = require("json")
                    cache_answer = json_mod.encode(parsed, { pretty = true, indent = true })
                    logger.info("KOAssistant: X-Ray JSON parsed successfully, rendered to markdown for display")
                else
                    logger.info("KOAssistant: X-Ray response is not valid JSON, using as-is")
                end
            end

            -- If user typed additional input, add it as a visible message before the response
            if has_additional_input then
                history:addUserMessage(additional_input, false)
            end
            history:addAssistantMessage(display_answer, ConfigHelper:getModelInfo(temp_config), reasoning, ConfigHelper:buildDebugInfo(temp_config), web_search_used)

            -- Determine if book text was provided (for cache metadata tracking)
            -- Includes incremental text for update scenarios
            local ResponseParser = require("koassistant_api.response_parser")
            local is_truncated = answer:find(ResponseParser.TRUNCATION_NOTICE, 1, true) ~= nil
            local book_text_was_provided = (message_data.book_text and message_data.book_text ~= "")
                or (message_data.full_document and message_data.full_document ~= "")
                or (message_data.incremental_book_text and message_data.incremental_book_text ~= "")
                or false
            -- Sticky-true: if previous cache used text, keep it true even if this update didn't
            if using_cache and message_data.cached_used_book_text == true then
                book_text_was_provided = true
            end

            -- Pre-format unavailable data for cache metadata (artifact viewers use this)
            local unavailable_text
            if message_data._unavailable_data and #message_data._unavailable_data > 0 then
                unavailable_text = table.concat(message_data._unavailable_data, ", ")
            end

            -- Background completion guard (compare-and-write, xray_background_plan.md §4):
            -- re-load BOTH cache keys from disk and verify the entry this run started from
            -- is still there with the same progress. Deleted mid-flight → discard (never
            -- resurrect — delete paths clear different key sets). Progress moved → a manual
            -- update won the race; theirs is newer → discard. Disk-vs-disk compare with an
            -- epsilon — never against in-memory floats.
            local background_discard = false
            if message_data._background_request and using_cache then
                local ActionCache = require("koassistant_action_cache")
                local started_from = tonumber(message_data.cached_progress_decimal)
                local function still_current(e)
                    return e and e.result and tonumber(e.progress_decimal) and started_from
                        and math.abs(tonumber(e.progress_decimal) - started_from) < 1e-6
                end
                if not (still_current(ActionCache.get(cache_file, original_action_id))
                        and still_current(ActionCache.getXrayCache(cache_file))) then
                    background_discard = true
                    -- Let the fire callback classify this as a skip, not a success
                    require("koassistant_xray_auto").markDiscarded()
                    logger.info("KOAssistant: background X-Ray update DISCARDED - cache changed mid-flight")
                end
            elseif message_data._background_create then
                -- Create-mode guard (started from nothing): if any X-Ray appeared
                -- mid-flight, a manual run won the race — theirs is newer; discard
                local ActionCache = require("koassistant_action_cache")
                local e1 = ActionCache.get(cache_file, original_action_id)
                local e2 = ActionCache.getXrayCache(cache_file)
                if (e1 and e1.result) or (e2 and e2.result) then
                    background_discard = true
                    require("koassistant_xray_auto").markDiscarded()
                    logger.info("KOAssistant: background X-Ray create DISCARDED - an X-Ray appeared mid-flight")
                end
            end

            -- Save to response cache if enabled (for incremental updates)
            -- Skip caching if response was truncated or was an error response (cache_answer set to nil)
            -- For progress actions: require progress_decimal (extraction must succeed)
            -- For non-progress actions (book_info, etc.): save with default 1.0 even without extraction
            if cache_enabled and original_action_id and not background_discard
                    and (message_data.progress_decimal or not (prompt and prompt.use_reading_progress))
                    and not is_truncated and cache_answer then
                local ActionCache = require("koassistant_action_cache")
                -- Track highlights for response cache (e.g., Recap uses highlights)
                local highlights_were_provided = (message_data.highlights and message_data.highlights ~= "")
                if using_cache and message_data.cached_used_highlights == true then
                    highlights_were_provided = true
                end
                -- Position-irrelevant actions (no use_reading_progress) store 1.0
                -- so the popup correctly shows "Redo" instead of misleading "Update to X%"
                local save_progress = prompt and prompt.use_reading_progress
                    and (tonumber(message_data.progress_decimal) or 0)
                    or 1.0
                local save_success = ActionCache.set(
                    cache_file,
                    original_action_id,
                    cache_answer,
                    save_progress,
                    { model = ConfigHelper:getModelInfo(temp_config), used_book_text = book_text_was_provided,
                      used_highlights = highlights_were_provided,
                      used_reasoning = (reasoning ~= nil and reasoning ~= ""),
                      web_search_used = web_search_flag,
                      used_research_mode = research_mode_active or nil,
                      updated_by_auto = message_data._background_request or nil,
                      previous_progress_decimal = message_data.cached_progress_decimal,
                      flow_visible_pages = message_data.flow_visible_pages,
                      progress_page = message_data.progress_page,
                      full_document = config.features and config.features._full_document_xray or nil,
                      source_mode = source_mode,
                      unavailable_data_text = unavailable_text }
                )
                if save_success then
                    logger.info("KOAssistant: Saved response to cache for", original_action_id, "at", save_progress, "used_book_text=", book_text_was_provided, "used_highlights=", highlights_were_provided)
                end
            elseif is_truncated and cache_enabled then
                logger.info("KOAssistant: Skipping cache for", original_action_id, "- response was truncated")
            end

            -- Save to document caches if action has cache_as_* flags (for reuse by other actions)
            -- Always cache regardless of text extraction — tracks used_book_text for dynamic permission gating
            if not is_truncated and cache_file and not background_discard then
                local ActionCache = require("koassistant_action_cache")
                local progress = tonumber(message_data.progress_decimal) or 0
                local model_name = ConfigHelper:getModelInfo(temp_config)

                if action.cache_as_xray then
                    -- Track what data was used when building this cache
                    -- Reading the cache will only require permissions for data that was actually used
                    local used_highlights = (message_data.highlights and message_data.highlights ~= "")
                    -- Sticky-true: if previous cache used highlights, keep it true even if this update didn't
                    -- Legacy compat: old caches used used_annotations to mean highlights
                    if using_cache and (message_data.cached_used_highlights == true
                        or (message_data.cached_used_highlights == nil and message_data.cached_used_annotations == true)) then
                        used_highlights = true
                    end
                    local xray_metadata = {
                        model = model_name,
                        used_highlights = used_highlights,
                        used_book_text = book_text_was_provided,
                        used_reasoning = (reasoning ~= nil and reasoning ~= ""),
                        web_search_used = web_search_flag,
                        used_research_mode = research_mode_active or nil,
                        updated_by_auto = message_data._background_request or nil,
                        previous_progress_decimal = message_data.cached_progress_decimal,
                        flow_visible_pages = message_data.flow_visible_pages,
                        progress_page = message_data.progress_page,
                        full_document = config.features and config.features._full_document_xray or nil,
                        unavailable_data_text = unavailable_text,
                    }
                    -- Archive the pre-overwrite snapshot (ring of 5; incremental updates
                    -- AND redos/regenerations, manual AND background — xray_ecosystem_plan.md
                    -- §5 decision 2). Read disk truth rather than message_data.cached_*:
                    -- it carries the full permission metadata and archives whatever entry
                    -- is actually being overwritten (a racing write may be newer than the
                    -- one this run started from).
                    local prev_xray = ActionCache.getXrayCache(cache_file)
                    if prev_xray and prev_xray.result and prev_xray.result ~= cache_answer then
                        ActionCache.pushXrayCheckpoint(cache_file, prev_xray,
                            ActionCache.checkpointLimitFromFeatures(config.features))
                    end
                    local xray_success = ActionCache.setXrayCache(cache_file, cache_answer, progress, xray_metadata)
                    if xray_success then
                        logger.info("KOAssistant: Saved X-Ray to reusable cache at", progress, "used_highlights=", used_highlights, "used_book_text=", book_text_was_provided)
                        -- Keep the background auto-update pre-filter in sync with the fresh
                        -- cache: a book opted in BEFORE its first X-Ray existed (or whose
                        -- cache just moved via a manual update) would otherwise stay
                        -- stale in memory until reopen (plan §3 "refreshed best-effort
                        -- after popup actions and background completions")
                        if plugin and plugin._refreshXrayAutoState then
                            plugin:_refreshXrayAutoState()
                        end
                    end
                end

                -- Section scope: save to section-specific cache key (any action type)
                -- Transient flag: _section_scope for generic sections, _section_xray for legacy X-Ray path
                local section_scope = config.features and (config.features._section_scope or config.features._section_xray)
                if section_scope and cache_answer then
                    local section_metadata = {
                        model = model_name,
                        used_book_text = book_text_was_provided,
                        used_highlights = (message_data.highlights and message_data.highlights ~= "") or false,
                        used_reasoning = (reasoning ~= nil and reasoning ~= ""),
                        web_search_used = web_search_flag,
                        full_document = true,
                        source_mode = source_mode,
                        scope_label = section_scope.label,
                        scope_start_page = section_scope.start_page,
                        scope_end_page = section_scope.end_page,
                        scope_start_xpointer = section_scope.start_xpointer,
                        scope_end_xpointer = section_scope.end_xpointer,
                        scope_page_summary = section_scope.page_summary,
                        unavailable_data_text = unavailable_text,
                    }
                    local section_success = ActionCache.set(cache_file, section_scope.cache_key, cache_answer, 1.0, section_metadata)
                    if section_success then
                        logger.info("KOAssistant: Saved section artifact to", section_scope.cache_key)
                    end
                end

                if action.cache_as_analyze then
                    local analyze_metadata = {
                        model = model_name,
                        used_book_text = book_text_was_provided,
                        used_reasoning = (reasoning ~= nil and reasoning ~= ""),
                        web_search_used = web_search_flag,
                        flow_visible_pages = message_data.flow_visible_pages,
                        unavailable_data_text = unavailable_text,
                    }
                    local analyze_success = ActionCache.setAnalyzeCache(cache_file, answer, 1.0, analyze_metadata)
                    if analyze_success then
                        logger.info("KOAssistant: Saved document analysis to reusable cache, used_book_text=", book_text_was_provided)
                    end
                end

                if action.cache_as_summary then
                    -- Include language in metadata for cache viewer awareness
                    local summary_metadata = {
                        model = model_name,
                        language = temp_config.features and temp_config.features.translation_language or "English",
                        used_book_text = book_text_was_provided,
                        used_reasoning = (reasoning ~= nil and reasoning ~= ""),
                        web_search_used = web_search_flag,
                        flow_visible_pages = message_data.flow_visible_pages,
                        unavailable_data_text = unavailable_text,
                    }
                    local summary_success = ActionCache.setSummaryCache(cache_file, answer, 1.0, summary_metadata)
                    if summary_success then
                        logger.info("KOAssistant: Saved document summary to reusable cache with language:", summary_metadata.language, "used_book_text=", book_text_was_provided)
                    end
                end
            end

            -- Invalidate file browser row cache so new artifacts appear immediately
            if plugin and plugin._file_dialog_row_cache then
                plugin._file_dialog_row_cache = { file = nil, rows = nil }
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

            -- Store unavailable data info for viewer to display notice
            -- Shows when action requested data (book text, annotations, notebook) but didn't receive it
            if message_data._unavailable_data and #message_data._unavailable_data > 0 then
                history.unavailable_data = message_data._unavailable_data
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

    -- Wrap the API call so it can be deferred by the large extraction warning dialog
    local function sendQuery()
        local result = queryChatGPT(history:getMessages(), temp_config, handleResponse, plugin and plugin.settings)

        -- If streaming is in progress, return nil (result comes via callback)
        if isStreamingInProgress(result) then
            return nil
        end

        -- Non-streaming: handleResponse callback was already called by queryChatGPT
        -- Return history and config for backward compatibility with callers that don't use callback
        return history, temp_config
    end

    -- Pre-send check chain: truncation warning → large extraction warning → sendQuery
    -- Each check is blocking — user must Continue or Cancel before proceeding.

    -- Compute extracted chars for large extraction check
    local extracted_chars = 0
    if message_data.book_text then extracted_chars = extracted_chars + #message_data.book_text end
    if message_data.full_document then extracted_chars = extracted_chars + #message_data.full_document end

    -- Step 3: Large sidecar data warning for multi-book actions (always warn, no suppress)
    local sidecar_chars = message_data._total_sidecar_chars or 0
    local function checkSidecarDataAndSend()
        if sidecar_chars > Constants.LARGE_EXTRACTION_THRESHOLD then
            local chars_k = math.floor(sidecar_chars / 1000)
            local tokens_low = math.floor(sidecar_chars / 4000)
            local tokens_high = math.floor(sidecar_chars / 2000)
            local book_count = message_data.books_info and #message_data.books_info or 0
            local warning_dialog
            warning_dialog = ButtonDialog:new{
                title = T(_("Large sidecar data: ~%1K characters (~%2K-%3K tokens) across %4 books. Make sure your model's context window can accommodate this.\n\nConsider selecting fewer books or using actions that don't require highlights/annotations."), chars_k, tokens_low, tokens_high, book_count),
                buttons = {
                    {{
                        text = _("Cancel"),
                        callback = function()
                            UIManager:close(warning_dialog)
                        end,
                    }},
                    {{
                        text = _("Continue"),
                        callback = function()
                            UIManager:close(warning_dialog)
                            sendQuery()
                        end,
                    }},
                },
            }
            UIManager:show(warning_dialog)
            return nil
        end

        return sendQuery()
    end

    -- Step 2: Large extraction warning (existing check, now wrapped in function for chaining)
    local function checkLargeExtractionAndSend()
        if extracted_chars > Constants.LARGE_EXTRACTION_THRESHOLD
                and not (config.features and config.features.suppress_large_extraction_warning) then
            local chars_k = math.floor(extracted_chars / 1000)
            local tokens_low = math.floor(extracted_chars / 4000)
            local tokens_high = math.floor(extracted_chars / 2000)
            local warning_dialog
            warning_dialog = ButtonDialog:new{
                title = T(_("Large text extraction: ~%1K characters (~%2K-%3K tokens). Make sure your model's context window can accommodate this.\n\nYou can focus on a specific Section instead of the full document, or use KOReader's Hidden Flows to exclude irrelevant content."), chars_k, tokens_low, tokens_high),
                buttons = {
                    {{
                        text = _("Cancel"),
                        callback = function()
                            UIManager:close(warning_dialog)
                        end,
                    }},
                    {{
                        text = _("Continue"),
                        callback = function()
                            UIManager:close(warning_dialog)
                            checkSidecarDataAndSend()
                        end,
                    }},
                    {{
                        text = _("Don't warn again"),
                        callback = function()
                            UIManager:close(warning_dialog)
                            -- Persist the preference
                            if plugin and plugin.settings then
                                local features_tbl = plugin.settings:readSetting("features") or {}
                                features_tbl.suppress_large_extraction_warning = true
                                plugin.settings:saveSetting("features", features_tbl)
                                plugin.settings:flush()
                            end
                            -- Also update current config so it takes effect immediately
                            if config.features then
                                config.features.suppress_large_extraction_warning = true
                            end
                            checkSidecarDataAndSend()
                        end,
                    }},
                },
            }
            UIManager:show(warning_dialog)
            return nil  -- Early return; continuation via callback
        end

        return checkSidecarDataAndSend()
    end

    -- Background auto-update: no dialogs may fire. The only chain step reachable on an
    -- update run is the incremental-truncation warning (extracted_chars counts only
    -- book_text/full_document; the sidecar warning is multi-book only) — under
    -- _background_request that is an ABORT, not a suppression: a silently-sent truncated
    -- delta would record progress the artifact text doesn't cover.
    if message_data._background_request then
        if message_data.incremental_book_text_truncated then
            logger.info("KOAssistant: background X-Ray update aborted - delta exceeded extraction limit")
            if on_complete then on_complete(nil, "background: delta truncated") end
            return nil
        end
        -- Create mode: same honesty rule for the base to-position extraction — a
        -- silently-truncated first X-Ray would record progress its text doesn't cover
        if message_data._background_create and message_data.book_text_truncated then
            logger.info("KOAssistant: background X-Ray create aborted - extraction exceeded limit")
            if on_complete then on_complete(nil, "background: extraction truncated") end
            return nil
        end
        return sendQuery()
    end

    -- Step 1: Truncation warning (fires before large extraction check)
    -- Book text and full document truncation are mutually exclusive in practice;
    -- incremental truncation is a separate case that could theoretically co-occur.
    local truncation_msg
    if not (config.features and config.features.suppress_truncation_warning) then
        if message_data.book_text_truncated or message_data.full_document_truncated then
            local cs = (message_data.book_text_truncated and message_data.book_text_coverage_start)
                    or (message_data.full_document_truncated and message_data.full_document_coverage_start) or 0
            local ce = (message_data.book_text_truncated and message_data.book_text_coverage_end)
                    or (message_data.full_document_truncated and message_data.full_document_coverage_end) or 0
            truncation_msg = T(_("Extracted text was truncated (covers %1%–%2% of the document)."), cs, ce)
        end
        if message_data.incremental_book_text_truncated then
            local cs = message_data.incremental_coverage_start or 0
            local ce = message_data.incremental_coverage_end or 0
            local inc_msg = T(_("New text since last update was truncated (covers %1%–%2% of the update range)."), cs, ce)
            truncation_msg = truncation_msg and (truncation_msg .. "\n" .. inc_msg) or inc_msg
        end
    end

    if truncation_msg then
        truncation_msg = truncation_msg .. "\n\n"
            .. _("You can increase the limit in Settings → Privacy & Data → Text Extraction, use Hidden Flows to exclude irrelevant content, or focus on a specific section.")
        local truncation_dialog
        truncation_dialog = ButtonDialog:new{
            title = truncation_msg,
            buttons = {
                {{
                    text = _("Cancel"),
                    callback = function()
                        UIManager:close(truncation_dialog)
                    end,
                }},
                {{
                    text = _("Continue Anyway"),
                    callback = function()
                        UIManager:close(truncation_dialog)
                        checkLargeExtractionAndSend()
                    end,
                }},
                {{
                    text = _("Don't warn again"),
                    callback = function()
                        UIManager:close(truncation_dialog)
                        -- Persist the preference
                        if plugin and plugin.settings then
                            local features_tbl = plugin.settings:readSetting("features") or {}
                            features_tbl.suppress_truncation_warning = true
                            plugin.settings:saveSetting("features", features_tbl)
                            plugin.settings:flush()
                        end
                        if config.features then
                            config.features.suppress_truncation_warning = true
                        end
                        checkLargeExtractionAndSend()
                    end,
                }},
            },
        }
        UIManager:show(truncation_dialog)
        return nil  -- Early return; continuation via callback
    end

    return checkLargeExtractionAndSend()
end

--- Format artifact metadata for popup display (e.g., "X-Ray (100%, today)")
--- @param cache table Artifact cache entry with name, data.progress_decimal, data.timestamp
--- @return string Formatted display text
local function formatArtifactDisplayText(cache)
    local parts = {}
    if cache.data then
        if cache.data.progress_decimal and cache.data.progress_decimal < 1.0 then
            local pct = math.floor(cache.data.progress_decimal * 100 + 0.5)
            table.insert(parts, pct .. "%")
        end
        if cache.data.timestamp then
            local now = os.time()
            local today_t = os.date("*t", now)
            today_t.hour, today_t.min, today_t.sec = 0, 0, 0
            local cached_t = os.date("*t", cache.data.timestamp)
            cached_t.hour, cached_t.min, cached_t.sec = 0, 0, 0
            local days = math.floor((os.time(today_t) - os.time(cached_t)) / 86400)
            if days == 0 then
                table.insert(parts, _("today"))
            elseif days < 30 then
                table.insert(parts, string.format(_("%dd ago"), days))
            else
                local months = math.floor(days / 30)
                table.insert(parts, string.format(_("%dm ago"), months))
            end
        end
    end
    if #parts > 0 then
        return cache.name .. " (" .. table.concat(parts, ", ") .. ")"
    end
    return cache.name
end

-- Smart-retrieval pre-flight (D3 — tools_ux_plan.md §4), shared by the popup dispatch
-- (explicit source choice on the input-dialog path) and direct entry points (silent
-- default — maintainer 2026-07-11): runs the gather phase, stashes the bundle + source
-- transients on config.features, then proceed()s into the normal action flow (which
-- consumes them in handlePredefinedPrompt). On gather failure the action does NOT run
-- with a different source than intended (error popup; silent on user cancel).
local function runSmartRetrieval(action, action_id, highlighted_text, ui_instance, config, plugin, proceed)
    config.features = config.features or {}
    config.features._source_mode = "smart_retrieval"
    BookToolRunner.gatherForAction({
        -- Model-facing gather question (untranslated, like GATHER_INSTRUCTIONS)
        question = "Task: " .. (action.text or action_id)
            .. "\n\nSelected passage:\n" .. (highlighted_text or ""),
        query_fn = queryChatGPT,
        config = config,
        ui = ui_instance,
        settings = plugin and plugin.settings,
        on_complete = function(bundle, info)
            if bundle == nil then
                config.features._source_mode = nil
                config.features._highlight_section_scope = nil
                if not (info and info.cancelled) then
                    UIManager:show(InfoMessage:new{
                        text = _("Book search failed: ")
                            .. tostring(info and info.error or _("Unknown error")),
                        timeout = 3,
                    })
                end
                return
            end
            config.features._forced_document_context = bundle
            local n = info and info.tool_calls or 0
            local Notification = require("ui/widget/notification")
            local note
            if n == 0 then
                -- Model decided no lookups were needed (zero-gather): the action
                -- proceeds on AI knowledge with the fallback nudge.
                note = _("No book lookups needed")
            elseif n == 1 then
                note = _("Searched the book — 1 lookup")
            else
                note = T(_("Searched the book — %1 lookups"), n)
            end
            UIManager:show(Notification:new{ text = note, timeout = 2 })
            proceed()
        end,
    })
end

local function showChatGPTDialog(ui_instance, highlighted_text, config, prompt_type, plugin, book_metadata, initial_input)
    -- Use the passed configuration or fall back to the global CONFIGURATION
    local configuration = config or CONFIGURATION

    -- Close any existing input dialog to prevent duplicates
    -- This handles the case where a new book chat is opened while one is already open
    if plugin and plugin.current_input_dialog then
        UIManager:close(plugin.current_input_dialog)
        plugin.current_input_dialog = nil
    end

    -- Consume transient config flags (set by X-Ray browser "Chat about this", etc.)
    -- Must read and clear immediately so they don't persist to subsequent calls
    local hide_artifacts = ((configuration or {}).features or {})._hide_artifacts
    local exclude_action_flags = ((configuration or {}).features or {})._exclude_action_flags
    local is_xray_chat = ((configuration or {}).features or {})._xray_chat_context
    local xray_context_prefix = ((configuration or {}).features or {})._xray_context_prefix
    local show_all_actions = ((configuration or {}).features or {})._show_all_actions or false
    local session_spoiler_free = ((configuration or {}).features or {})._session_spoiler_free
    local session_book_tools = ((configuration or {}).features or {})._session_book_tools
    local session_web_search = ((configuration or {}).features or {})._session_web_search
    -- NOTE: the _selection_context_window transient (pre-extracted selection window,
    -- surrounding context) deliberately STAYS on configuration.features — no dialog
    -- local. It is consumed at its two read points (handlePredefinedPrompt + freeform
    -- Send), every highlight entry sets-or-clears it, and the {prev,next,text}
    -- fingerprint makes a stale value self-discarding. A dialog-local here would add
    -- upvalues to closures already at LuaJIT's 60-upvalue cap.
    if configuration and configuration.features then
        configuration.features._hide_artifacts = nil
        configuration.features._exclude_action_flags = nil
        configuration.features._xray_chat_context = nil
        configuration.features._xray_context_prefix = nil
        configuration.features._show_all_actions = nil
        configuration.features._session_spoiler_free = nil
        configuration.features._session_book_tools = nil
        configuration.features._session_web_search = nil
        -- Stale-request hygiene: a per-chat web value from an earlier session must not
        -- outlive its dialog (it is normally consumed at bake/dispatch).
        configuration.features._web_search_active = nil
        -- Quick-controls dispatch consumables: same hygiene (normally consumed at bake).
        configuration.features._quick_answer_active = nil
        configuration.features._reasoning_override_active = nil
        configuration.features._model_override_active = nil
        -- Scope-chip session state (flexible_scope_plan.md phase 3) is CONFIG-RESIDENT
        -- (no dialog local — the Send/chip closures sit at LuaJIT's 60-upvalue cap, see
        -- the _selection_context_window note below). A refresh preserves it via the
        -- _session_keep_scope marker; a fresh open clears it here.
        if not configuration.features._session_keep_scope then
            configuration.features._session_scope = nil
            configuration.features._session_highlight_context = nil
            -- Quick-controls chip state (controls_parity_plan.md §2/§9): same
            -- config-resident lifecycle as the scope pick — survives a refresh
            -- via the marker, cleared on a fresh open.
            configuration.features._session_quick_answer = nil
            configuration.features._session_reasoning = nil
            configuration.features._session_model = nil
            -- Attach chip staging (attach_plan.md): MODULE-resident, not on
            -- features — configuration.features shares identity with the
            -- persisted settings table, and staged text must never reach a
            -- settings flush (see koassistant_attachments.lua header). Same
            -- lifetime rules as the scope pick.
            require("koassistant_attachments").clear()
        end
        configuration.features._session_keep_scope = nil
        -- Stale-request hygiene (mirrors _web_search_active above): the
        -- attach-consume flag is normally consumed at dispatch.
        configuration.features._attachments_active = nil
    end

    -- session_spoiler_free is initialized further below, once the book's DocSettings is
    -- resolved (per-book override > global default) — unless it was restored from a refresh.

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
    -- Use getPromptContext() which properly prioritizes: library > book > general > highlight
    -- This prevents stale is_general_context flags from affecting book context dialogs
    local is_general_context = getPromptContext(configuration) == "general"

    -- Capture book info from KOReader's merged props (includes user edits from Book Info dialog)
    local ui_doc_props = ui_instance and ui_instance.doc_props
    local doc_title = ui_doc_props and (ui_doc_props.display_title or ui_doc_props.title) or nil
    local doc_author = ui_doc_props and ui_doc_props.authors or nil
    -- Normalize multi-author strings (KOReader stores as newline-separated)
    if doc_author and doc_author:find("\n") then
        doc_author = doc_author:gsub("\n", ", ")
    end
    local doc_file = ui_instance and ui_instance.document and ui_instance.document.file or nil

    -- For general/library context, don't use document_path - these chats aren't tied to a single document
    -- But capture launch_context so we know where the chat was started from
    local document_path = nil
    local launch_context = nil
    -- Reset book_metadata to allow conditional assignment below
    book_metadata = nil

    local is_library_context = configuration and configuration.features and configuration.features.is_library_context
    if is_general_context or is_library_context then
        -- General/library chat: don't associate with a document, but track launch context
        local ctx_label = is_library_context and "Library" or "General"
        if doc_title and doc_file then
            launch_context = {
                title = doc_title,
                author = doc_author,
                file = doc_file
            }
            logger.info("KOAssistant: " .. ctx_label .. " chat launched from book - " .. doc_title)
        else
            logger.info("KOAssistant: " .. ctx_label .. " chat with no launch context")
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

    -- AI-facing copy of the book identity: apply the per-book AI title/author override
    -- (Book Settings ▸ AI title/author). The freeform-Send [Context] block embeds this in
    -- the request, so it must honor the override; book_metadata itself stays raw for local
    -- bookkeeping (chat save metadata, artifact viewer titles). Predefined actions apply
    -- the override themselves in handlePredefinedPrompt.
    local ai_book_metadata = book_metadata
    if book_metadata and document_path then
        ai_book_metadata = require("koassistant_book_settings").applyMetadataOverride(
            book_metadata, SafeDocSettings.resolve(document_path, ui_instance))
    end

    -- Determine input context for per-context action ordering
    local has_open_book = ui_instance and ui_instance.document ~= nil
    local input_context
    if is_general_context then
        input_context = "general"  -- Uses existing getGeneralMenuActionObjects()
    elseif is_xray_chat then
        input_context = "xray_chat"
    elseif configuration and configuration.features and configuration.features.is_library_context then
        input_context = "library"
    elseif configuration and configuration.features and configuration.features.is_book_context then
        if has_open_book then
            input_context = "book"
        else
            input_context = "book_filebrowser"
        end
    else
        input_context = "highlight"
    end

    -- Track selected domain for this dialog (initialize from config if set)
    local selected_domain = configuration and configuration.features and configuration.features.selected_domain or nil

    -- Track per-book domain for any context that targets a specific book
    -- General and library contexts explicitly disassociate from any specific book
    -- Use document_path (the relevant book) to load the right DocSettings,
    -- not ui_instance.doc_settings (which is the currently open book — may differ)
    local doc_settings = nil
    if document_path then
        doc_settings = SafeDocSettings.resolve(document_path, ui_instance)
    end
    local book_domain_id = getBookDomain(doc_settings)
    local book_research_id = getBookResearchMode(doc_settings)

    -- Initialize session spoiler-free: per-book override > global default.
    -- Skipped when restored from a refresh (the user's session choice is preserved).
    if session_spoiler_free == nil then
        local book_spoiler = doc_settings and doc_settings:readSetting("koassistant_book_spoiler_free")
        if book_spoiler ~= nil then
            session_spoiler_free = book_spoiler
        else
            session_spoiler_free = configuration and configuration.features
                and configuration.features.spoiler_free_chat == true
        end
    end

    -- Initialize the session "Book tools" toggle (D1): effective posture sets the default
    -- (per-book koassistant_book_tools > global tools_posture; "auto" = checked), the user
    -- flips it per session. Skipped when restored from a refresh (session choice preserved).
    -- "off" additionally hides the checkbox at the render site below.
    local effective_tools_posture = require("koassistant_book_settings").resolveToolsPosture(
        doc_settings, configuration and configuration.features)
    if session_book_tools == nil then
        session_book_tools = effective_tools_posture == "auto"
    end

    -- Initialize the session web-search toggle: per-book override > global default.
    -- Skipped when restored from a refresh (session choice preserved). Session-only —
    -- the top-row Web button no longer writes the global setting (lasting defaults
    -- live in Quick Settings and Book Settings).
    if session_web_search == nil then
        session_web_search = BookSettings.resolveWebSearch(
            doc_settings, configuration and configuration.features)
    end

    -- Forward declaration (showDomainSelector uses refreshInputDialog, defined later)
    local refreshInputDialog

    -- Domain target: "book" or "global" — controls where selection is saved
    -- Default to "book" if any book override exists (domain or research mode), otherwise "global"
    local domain_target = (doc_settings and (book_domain_id or book_research_id ~= nil)) and "book" or "global"

    -- Function to show domain selector
    -- Single list with target toggle at top when a book is open
    local function showDomainSelector()
        -- Close the on-screen keyboard first to prevent z-order issues
        input_dialog:onCloseKeyboard()

        local DomainLoader = require("domain_loader")
        -- Get custom domains from settings
        local features = plugin and plugin.settings and plugin.settings:readSetting("features") or {}
        local custom_domains = features.custom_domains or {}
        -- Get all domains (folder + UI-created) sorted
        local sorted_domains = DomainLoader.getSortedDomains(custom_domains)

        -- Helper to close and refresh input dialog
        local function closeAndRefresh()
            UIManager:close(_G.domain_selector_dialog)
            refreshInputDialog()
        end

        local state = {
            domains = sorted_domains,
            has_book = doc_settings ~= nil,
            is_book_target = (doc_settings and domain_target == "book") or false,
            book_domain = book_domain_id,
            global_domain = selected_domain,
            book_research = book_research_id,
            global_research = configuration.features and configuration.features.research_mode,
        }

        local cb = {
            set_target = function(new_target)
                domain_target = new_target
                UIManager:close(_G.domain_selector_dialog)
                showDomainSelector()
            end,
            pick_book_domain = function(val)
                book_domain_id = val
                persistBookDomain(doc_settings, val)
                closeAndRefresh()
            end,
            pick_global_domain = function(id)
                selected_domain = id
                configuration.features = configuration.features or {}
                configuration.features.selected_domain = id
                persistDomainSelection(plugin, id)
                closeAndRefresh()
            end,
            set_book_research = function(val)
                book_research_id = val
                persistBookResearchMode(doc_settings, val)
                closeAndRefresh()
            end,
            set_global_research = function(val)
                configuration.features = configuration.features or {}
                configuration.features.research_mode = val
                if plugin and plugin.settings then
                    local f = plugin.settings:readSetting("features") or {}
                    f.research_mode = val
                    plugin.settings:saveSetting("features", f)
                    plugin.settings:flush()
                end
                closeAndRefresh()
            end,
            close = function()
                UIManager:close(_G.domain_selector_dialog)
            end,
        }

        local buttons = BookSettings.buildDomainResearchButtons(state, cb)

        local ButtonDialog = require("ui/widget/buttondialog")
        _G.domain_selector_dialog = ButtonDialog:new{
            title = _("Domain & Research"),
            buttons = buttons,
        }
        UIManager:show(_G.domain_selector_dialog)
    end

    -- Get domain display name for button
    -- Shows effective domain: book domain takes priority over global
    -- "_none" sentinel = explicit no-domain override for this book
    -- @param plain: true = bare name, no " (book)" override marker (the toolbar chip
    -- shows just the domain — maintainer 2026-07-12; pickers keep the marker)
    local function getDomainDisplayName(plain)
        if book_domain_id == "_none" then
            return plain and _("None") or (_("None") .. _(" (book)"))
        end
        local effective_id = book_domain_id or selected_domain
        if not effective_id then
            return _("None")
        end
        local DomainLoader = require("domain_loader")
        -- Get custom domains from settings for lookup
        local features = plugin and plugin.settings and plugin.settings:readSetting("features") or {}
        local custom_domains = features.custom_domains or {}
        local domain = DomainLoader.getDomainById(effective_id, custom_domains)
        if domain then
            -- Chip shows the bare name — provenance suffixes ("(file)"/"(custom)")
            -- stay in the picker lists only (maintainer 2026-07-17).
            local name = domain.name or domain.display_name or effective_id
            if book_domain_id and not plain then
                return name .. _(" (book)")
            end
            return name
        end
        return effective_id
    end

    -- Emoji helper for this dialog (scoped to dialog lifecycle)
    local enable_emoji = configuration and configuration.features
        and configuration.features.enable_emoji_icons == true

    local function getWebToggleText()
        -- Emoji SWAPS the word (globe = web) to keep the chip narrow; the state suffix
        -- stays. Unsupported provider/model: N/A (tap explains, doesn't toggle).
        if not ConfigHelper:supportsWebSearch(configuration) then
            return enable_emoji and ("\u{1F310} " .. _("N/A")) or _("Web N/A")
        end
        if enable_emoji then
            return "\u{1F310} " .. (session_web_search and _("ON") or _("OFF"))
        end
        return session_web_search and _("Web ON") or _("Web OFF")
    end

    -- Shared action execution for grid buttons, More Actions, and expanded in-grid buttons.
    -- Handles: getInputText, close dialog, _checkRequirements, showCacheActionPopup,
    -- cache viewer redirect, and handlePredefinedPrompt with full onPromptComplete.
    local function executeInputAction(action, action_id)
        -- Pre-flight checks run BEFORE closing dialog so it stays open on failure

        -- Pre-flight: block when declared requirements are unmet
        if plugin and plugin._checkRequirements then
            if plugin:_checkRequirements(action) then
                return
            end
        end

        -- Pre-flight: block selection-required library actions when no books selected
        if action.requires_selected_books then
            local books = configuration and configuration.features and configuration.features.books_info
            if not books or #books < 2 then
                UIManager:show(InfoMessage:new{
                    text = _("Select at least 2 items first using [Items]."),
                    timeout = 3,
                })
                return
            end
        end

        -- The CURRENT spoiler chip governs this launch's smart-retrieval reading scope
        -- (resolveReadingScope reads the flag; without this, a stale value from an
        -- earlier chat's Send would apply). The system-prompt nudge stays action-free —
        -- G6 clears the flag on the action's temp config.
        configuration.features = configuration.features or {}
        configuration.features._spoiler_free_active = session_spoiler_free == true

        local additional_input = input_dialog:getInputText()
        UIManager:close(input_dialog)
        if plugin then plugin.current_input_dialog = nil end

        local function runAction()
            UIManager:scheduleIn(0.1, function()
                local function onPromptComplete(history, temp_config_or_error)
                    if history then
                        local temp_config = temp_config_or_error
                        local function addMessage(message, is_context, on_complete)
                            history:addUserMessage(message, is_context)
                            local answer_result = BookToolRunner.queryWith(queryChatGPT, history:getMessages(), temp_config, function(success, answer, err, reasoning, web_search_used)
                                if success and answer then
                                    history:addAssistantMessage(answer, ConfigHelper:getModelInfo(temp_config), reasoning, ConfigHelper:buildDebugInfo(temp_config), web_search_used)
                                else
                                    -- Cancelled/failed: roll the unanswered question back out
                                    -- so it can't ride into the next request.
                                    history:removeLastUserMessage()
                                end
                                if on_complete then on_complete(success, answer, err, reasoning, web_search_used) end
                            end, plugin, ui_instance)
                            if not isStreamingInProgress(answer_result) then
                                return answer_result
                            end
                            return nil
                        end
                        closeLoadingDialog()

                        -- For cache-first actions (Recap, X-Ray Simple): open in simple viewer
                        if action.use_response_caching and action.id and plugin then
                            local ActionCache = require("koassistant_action_cache")
                            local file = ui_instance and ui_instance.document and ui_instance.document.file
                            if file then
                                local cached = ActionCache.get(file, action.id)
                                if cached and cached.result then
                                    plugin:viewCachedAction(action, action.id, cached)
                                    return
                                end
                            end
                        end

                        -- For document analysis/summary: open in cache viewer
                        if (action.cache_as_analyze or action.cache_as_summary) and plugin then
                            local ActionCache = require("koassistant_action_cache")
                            local file = ui_instance and ui_instance.document and ui_instance.document.file
                            if file then
                                local cached, cache_name, cache_key
                                if action.cache_as_analyze then
                                    cached = ActionCache.getAnalyzeCache(file)
                                    cache_name = _("Analysis")
                                    cache_key = "_analyze_cache"
                                else
                                    cached = ActionCache.getSummaryCache(file)
                                    cache_name = _("Summary")
                                    cache_key = "_summary_cache"
                                end
                                if cached and cached.result then
                                    plugin:showCacheViewer({ name = cache_name, key = cache_key, data = cached })
                                    return
                                end
                            end
                        end

                        showResponseDialog(_(action.text), history, highlighted_text, addMessage, temp_config, document_path, plugin, book_metadata, launch_context, ui_instance)
                    else
                        closeLoadingDialog()
                        local error_msg = temp_config_or_error or "Unknown error"
                        UIManager:show(InfoMessage:new{
                            text = _("Error: ") .. action_id .. " - " .. error_msg,
                            timeout = 2
                        })
                    end
                end

                -- Pass X-Ray context prefix to handlePredefinedPrompt via transient flag
                if xray_context_prefix then
                    configuration.features = configuration.features or {}
                    configuration.features._xray_context_prefix = xray_context_prefix
                end

                -- Thread the session Web chip into this action dispatch: actions with
                -- enable_web_search = nil follow the chip (as they used to follow the
                -- then-persisted global); forced true/false flags still win. Set
                -- just-in-time — handlePredefinedPrompt consumes it from this config
                -- right after copying, so it can't go stale on the shared table.
                configuration.features = configuration.features or {}
                configuration.features._web_search_active = session_web_search == true
                -- Quick controls (controls_parity_plan.md §10): same just-in-time
                -- pattern — the *_active consumables carry the one-shot session
                -- overrides into this action dispatch (handlePredefinedPrompt
                -- consumes them from the source right after copying). Model/
                -- reasoning follow the Web pattern (explicit action pins win at
                -- bake); Quick Answer additionally needs the action's opt-in
                -- (accept_quick_answer — gated at bake).
                configuration.features._quick_answer_active =
                    configuration.features._session_quick_answer
                configuration.features._reasoning_override_active =
                    configuration.features._session_reasoning
                configuration.features._model_override_active =
                    configuration.features._session_model
                -- Session context-mode override (Scope chip, highlight facet): same
                -- just-in-time pattern — set-or-clear at dispatch so direct entries
                -- (highlight menu, gestures) never see a stale value; consumed in
                -- handlePredefinedPrompt's ambient resolution.
                configuration.features._highlight_context_active =
                    configuration.features._session_highlight_context
                -- (The pre-extracted selection window already rides
                -- configuration.features._selection_context_window from the entry
                -- point; handlePredefinedPrompt consumes it.)
                -- Attach chip (attach_plan.md §4): dialog-launched actions consume
                -- staged attachments too — same just-in-time-at-dispatch pattern as
                -- the Web chip; direct entries (no dialog, no chip) never see this.
                -- Flag only (consumed in handlePredefinedPrompt, which builds the
                -- block from the module staging list) — no big string on the
                -- flush-exposed features table.
                configuration.features._attachments_active =
                    require("koassistant_attachments").count() > 0 or nil

                handlePredefinedPrompt(action_id, highlighted_text, ui_instance, configuration, nil, plugin, additional_input, onPromptComplete, book_metadata)
            end)
        end

        -- Shared dispatch for the unified popup's on_execute (all three popup call sites
        -- below): records the source/scope transients, and for smart retrieval (D3 —
        -- tools_ux_plan.md §4) runs the gather phase FIRST, stashes the bundle as
        -- _forced_document_context, then runs the action normally — its own prompt and
        -- placeholders consume the bundle in place of extracted text.
        local function runActionWithSource(popup_state, is_hl)
            configuration.features = configuration.features or {}
            configuration.features._source_mode = popup_state.source
            if is_hl and popup_state.scope == "section" and popup_state.section_entry then
                configuration.features._highlight_section_scope = {
                    start_page = popup_state.section_entry.start_page,
                    end_page = popup_state.section_entry.end_page,
                }
            end
            if popup_state.source == "smart_retrieval" then
                runSmartRetrieval(action, action_id, highlighted_text, ui_instance,
                    configuration, plugin, runAction)
                return
            end
            runAction()
        end

        -- Pre-flight: cache actions with source_selection use View/Sections/New popup
        if action.use_response_caching and action.source_selection and plugin then
            local ActionCache = require("koassistant_action_cache")
            local file = (ui_instance and ui_instance.document and ui_instance.document.file)
                or (configuration and configuration.features and configuration.features.book_metadata
                    and configuration.features.book_metadata.file)
            local cached = file and ActionCache.get(file, action_id)
            -- Fallback: document-level cache (migration)
            if not cached or not cached.result then
                if action.cache_as_summary then
                    cached = ActionCache.getSummaryCache(file)
                elseif action.cache_as_analyze then
                    cached = ActionCache.getAnalyzeCache(file)
                end
            end
            if cached and cached.result then
                local action_name = action.text or action_id
                local view_detail = ""
                if cached.progress_decimal or cached.timestamp then
                    local parts = {}
                    if cached.progress_decimal and cached.progress_decimal < 1.0 then
                        table.insert(parts, math.floor(cached.progress_decimal * 100 + 0.5) .. "%")
                    end
                    if cached.timestamp then
                        local now = os.time()
                        local diff = now - cached.timestamp
                        local rel_time
                        if diff < 86400 then rel_time = _("today")
                        elseif diff < 172800 then rel_time = _("yesterday")
                        else rel_time = math.floor(diff / 86400) .. "d" end
                        table.insert(parts, rel_time)
                    end
                    if #parts > 0 then
                        view_detail = " (" .. table.concat(parts, ", ") .. ")"
                    end
                end
                local ButtonDialog = require("ui/widget/buttondialog")
                local dialog
                local popup_buttons = {}
                -- View existing artifact
                table.insert(popup_buttons, {{
                    text = T(_("View %1"), action_name .. view_detail),
                    callback = function()
                        UIManager:close(dialog)
                        plugin:viewCachedAction(action, action_id, cached, { file = file })
                    end,
                }})
                -- Surface in-range section artifacts
                local section_prefix = ActionCache.getSectionPrefix(action_id)
                local doc = ui_instance and ui_instance.document
                if section_prefix and file and doc then
                    local in_range = ActionCache.findMatchingSections(file, doc, section_prefix)
                    for _idx2, sec in ipairs(in_range) do
                        local page_info = ActionCache.reconvertPageSummary(sec.data, doc)
                        local sec_parts = {}
                        if page_info and page_info ~= "" then
                            table.insert(sec_parts, page_info)
                        end
                        local sec_rel_time = sec.data.timestamp and os.difftime(os.time(), sec.data.timestamp) or nil
                        local sec_rel = ""
                        if sec_rel_time then
                            local diff = sec_rel_time
                            if diff < 3600 then sec_rel = _("now")
                            elseif diff < 86400 then sec_rel = _("today")
                            else sec_rel = math.floor(diff / 86400) .. "d" end
                        end
                        if sec_rel ~= "" then
                            table.insert(sec_parts, sec_rel)
                        end
                        local sec_detail = #sec_parts > 0 and " (" .. table.concat(sec_parts, ", ") .. ")" or ""
                        local captured_sec = sec
                        table.insert(popup_buttons, {{
                            text = T(_("View \"%1\""), sec.label) .. sec_detail,
                            callback = function()
                                UIManager:close(dialog)
                                plugin:viewCachedAction(action, action_id, captured_sec.data, {
                                    file = file,
                                    section_key = captured_sec.key,
                                    section_label = captured_sec.label,
                                })
                            end,
                        }})
                    end
                end
                -- Update/Redo for position-relevant actions (e.g. Recap)
                if action.use_reading_progress and ui_instance and ui_instance.document then
                    local cached_progress = cached.progress_decimal or 0
                    local update_text
                    local ContextExtractor = require("koassistant_context_extractor")
                    local extractor = ContextExtractor:new(ui_instance)
                    local progress = extractor:getReadingProgress()
                    if progress.decimal > cached_progress + 0.01 then
                        update_text = T(_("Update %1"), action_name .. " (" .. T(_("to %1"), progress.formatted) .. ")")
                    else
                        update_text = T(_("Redo %1"), action_name)
                    end
                    table.insert(popup_buttons, {{
                        text = update_text,
                        callback = function()
                            UIManager:close(dialog)
                            -- Use cached source_mode for update/redo (same source)
                            configuration.features = configuration.features or {}
                            configuration.features._source_mode = cached.source_mode
                            runAction()
                        end,
                    }})
                end
                -- Browse remaining section artifacts (all sections in group)
                if section_prefix and file then
                    local sec_count = ActionCache.getSectionCount(file, section_prefix)
                    if sec_count > 0 then
                        table.insert(popup_buttons, {{
                            text = string.format("%s (%d)", ActionCache.getSectionGroupName(action_id) or _("Sections"), sec_count),
                            callback = function()
                                UIManager:close(dialog)
                                plugin:_showSectionList(action, action_id)
                            end,
                        }})
                    end
                end
                -- New generation (opens scope/source popup)
                table.insert(popup_buttons, {{
                    text = T(_("New %1…"), action_name),
                    callback = function()
                        UIManager:close(dialog)
                        local is_hl = action.context == "highlight" or action.context == "both"
                        plugin:_showUnifiedActionPopup(action, action_id, {
                            for_highlight = is_hl or nil,
                            session_tools = session_book_tools == true,
                            on_execute = function(popup_state)
                                runActionWithSource(popup_state, is_hl)
                            end,
                        })
                    end,
                }})
                table.insert(popup_buttons, {{
                    text = _("Cancel"),
                    callback = function()
                        UIManager:close(dialog)
                    end,
                }})
                dialog = ButtonDialog:new{
                    title = action_name,
                    buttons = popup_buttons,
                }
                UIManager:show(dialog)
                return
            end
            -- No cache: check for sections before falling through to source_selection
            local section_prefix = ActionCache.getSectionPrefix(action_id)
            local sec_count = section_prefix and file and ActionCache.getSectionCount(file, section_prefix) or 0
            if sec_count > 0 then
                local action_name = action.text or action_id
                local ButtonDialog = require("ui/widget/buttondialog")
                local nc_dialog
                local nc_buttons = {}
                table.insert(nc_buttons, {{
                    text = string.format("%s (%d)", ActionCache.getSectionGroupName(action_id) or _("Sections"), sec_count),
                    callback = function()
                        UIManager:close(nc_dialog)
                        plugin:_showSectionList(action, action_id)
                    end,
                }})
                table.insert(nc_buttons, {{
                    text = T(_("New %1…"), action_name),
                    callback = function()
                        UIManager:close(nc_dialog)
                        local is_hl = action.context == "highlight" or action.context == "both"
                        plugin:_showUnifiedActionPopup(action, action_id, {
                            for_highlight = is_hl or nil,
                            session_tools = session_book_tools == true,
                            on_execute = function(popup_state)
                                runActionWithSource(popup_state, is_hl)
                            end,
                        })
                    end,
                }})
                table.insert(nc_buttons, {{
                    text = _("Cancel"),
                    callback = function()
                        UIManager:close(nc_dialog)
                    end,
                }})
                nc_dialog = ButtonDialog:new{
                    title = action_name,
                    buttons = nc_buttons,
                }
                UIManager:show(nc_dialog)
                return
            end
            -- No cache, no sections: fall through to source_selection handler below
        end

        -- Pre-flight: show View/Update popup for other cached actions (without source_selection)
        if action.use_response_caching and not action.source_selection
                and plugin and plugin.showCacheActionPopup then
            local cache_opts
            local cfg_bm = configuration and configuration.features
                and configuration.features.book_metadata
            if cfg_bm and cfg_bm.file then
                cache_opts = {
                    file = cfg_bm.file,
                    book_title = cfg_bm.title,
                    book_author = cfg_bm.author,
                }
            end
            plugin:showCacheActionPopup(action, action_id, runAction, cache_opts)
            return
        end

        -- Unified action popup for source_selection actions
        if action.source_selection and plugin and plugin._showUnifiedActionPopup then
            local is_highlight = action.context == "highlight" or action.context == "both"
            plugin:_showUnifiedActionPopup(action, action_id, {
                for_highlight = is_highlight or nil,
                session_tools = session_book_tools == true,
                on_execute = function(popup_state)
                    runActionWithSource(popup_state, is_highlight)
                end,
            })
            return
        end

        runAction()
    end

    -- Helper: merge new books into existing selection (dedup by file path)
    local function mergeBooks(new_books)
        configuration.features = configuration.features or {}
        local existing = configuration.features.books_info or {}
        local seen = {}
        for _idx, b in ipairs(existing) do
            if b.file then seen[b.file] = true end
        end
        local merged = {}
        for _idx, b in ipairs(existing) do
            table.insert(merged, b)
        end
        local added = 0
        for _idx, b in ipairs(new_books) do
            if not b.file or not seen[b.file] then
                table.insert(merged, b)
                if b.file then seen[b.file] = true end
                added = added + 1
            end
        end
        -- Rebuild book_context string
        local books_list = {}
        for i, book in ipairs(merged) do
            if book.authors and book.authors ~= "" then
                table.insert(books_list, string.format('%d. "%s" by %s', i, book.title, book.authors))
            else
                table.insert(books_list, string.format('%d. "%s"', i, book.title))
            end
        end
        configuration.features.books_info = merged
        configuration.features.book_context = string.format(
            "Selected %d books:\n\n%s", #merged, table.concat(books_list, "\n"))
        if #merged > 0 then
            configuration.features.book_metadata = {
                title = merged[1].title,
                author = merged[1].authors or "",
            }
        end
        return added, #merged
    end

    -- Library context: show Add Books menu with presets
    local add_books_dialog  -- forward declaration for closure
    local showSelectedBooksEditor  -- forward declaration for showAddBooksMenu

    -- Helper: get books from ReadHistory filtered by status via DocSettings
    -- status_filter: "reading", "complete", "abandoned", or nil (no filter)
    -- limit: max books to return (nil = no limit)
    local function getBooksFromHistory(status_filter, limit)
        local ok, ReadHistory = pcall(require, "readhistory")
        if not ok or not ReadHistory then return nil end
        ReadHistory:reload()
        local hist = ReadHistory.hist or {}
        if #hist == 0 then return {} end

        local DocSettings = require("docsettings")
        local new_books = {}
        for _idx, entry in ipairs(hist) do
            if not entry.file or entry.dim then goto continue end
            if limit and #new_books >= limit then break end

            -- Get metadata + status from DocSettings
            local title = nil
            local author = ""
            local ds = DocSettings:open(entry.file)
            local doc_props = ds:readSetting("doc_props")
            if doc_props then
                local dt = doc_props.display_title or doc_props.title
                if dt and dt ~= "" then title = dt end
                if doc_props.authors and doc_props.authors ~= "" then
                    author = doc_props.authors:gsub("\n", ", ")
                end
            end

            -- Status filtering via DocSettings sidecar (no scanner needed)
            if status_filter then
                local summary = ds:readSetting("summary")
                local status = summary and summary.status or nil
                if status_filter == "reading" then
                    -- Explicit reading status, or in-progress without explicit status
                    local progress = ds:readSetting("percent_finished")
                    local is_reading = status == "reading"
                        or (not status and progress and progress > 0 and progress < 0.95)
                    if not is_reading then goto continue end
                elseif status ~= status_filter then
                    goto continue
                end
            end

            -- Fallback title from history text or filename
            if not title then
                title = entry.text or entry.file:match("([^/]+)%.[^%.]+$") or entry.file
            end
            table.insert(new_books, {
                title = title,
                authors = author,
                file = entry.file,
            })
            ::continue::
        end
        return new_books
    end

    -- Helper: get effective scan folders for this session
    -- Returns array of folder paths (permanent enabled + ad-hoc)
    local function getEffectiveScanFolders()
        local session_state = configuration.features._session_library or {}
        local disabled_set = session_state.disabled_folders or {}
        local adhoc_folders = session_state.adhoc_folders or {}
        local perm_features = plugin and plugin.settings and plugin.settings:readSetting("features") or {}
        local perm_folders = perm_features.library_scan_folders or {}
        local result = {}
        for _idx, pf in ipairs(perm_folders) do
            if not disabled_set[pf] then
                table.insert(result, pf)
            end
        end
        for _idx, af in ipairs(adhoc_folders) do
            table.insert(result, af)
        end
        return result
    end

    -- Sync effective scan folders to plugin instance for _checkRequirements()
    local function syncLibraryState()
        if plugin then
            local folders = getEffectiveScanFolders()
            plugin._session_scan_folders = #folders > 0 and folders or nil
        end
    end

    -- Library folder management popup: enable/disable permanent folders, add/remove ad-hoc
    local library_folder_dialog  -- forward declaration
    local function showLibraryFolderPopup()
        local ButtonDialog = require("ui/widget/buttondialog")
        configuration.features._session_library = configuration.features._session_library or {}
        local session_state = configuration.features._session_library
        session_state.disabled_folders = session_state.disabled_folders or {}
        session_state.adhoc_folders = session_state.adhoc_folders or {}

        local perm_features = plugin and plugin.settings and plugin.settings:readSetting("features") or {}
        local perm_folders = perm_features.library_scan_folders or {}
        local menu_buttons = {}

        -- Permanent folders with checkmarks
        for _idx, folder_path in ipairs(perm_folders) do
            local display = folder_path:match("([^/]+)$") or folder_path
            local is_enabled = not session_state.disabled_folders[folder_path]
            table.insert(menu_buttons, {{
                text = (is_enabled and "\u{2611} " or "\u{2610} ") .. display,
                callback = function()
                    UIManager:close(library_folder_dialog)
                    if is_enabled then
                        session_state.disabled_folders[folder_path] = true
                    else
                        session_state.disabled_folders[folder_path] = nil
                    end
                    syncLibraryState()
                    refreshInputDialog()
                end,
                hold_callback = function()
                    UIManager:show(InfoMessage:new{
                        text = folder_path,
                        timeout = 5,
                    })
                end,
            }})
        end

        -- Ad-hoc folders with checkmarks (unchecking removes)
        for idx, folder_path in ipairs(session_state.adhoc_folders) do
            local display = folder_path:match("([^/]+)$") or folder_path
            table.insert(menu_buttons, {{
                text = "\u{2611} " .. display .. " \u{00B7}",
                callback = function()
                    UIManager:close(library_folder_dialog)
                    table.remove(session_state.adhoc_folders, idx)
                    syncLibraryState()
                    refreshInputDialog()
                end,
                hold_callback = function()
                    UIManager:show(InfoMessage:new{
                        text = T(_("%1\n\n(Session folder — uncheck to remove)"), folder_path),
                        timeout = 5,
                    })
                end,
            }})
        end

        -- Add Folder button
        table.insert(menu_buttons, {{
            text = _("+ Add Folder…"),
            callback = function()
                UIManager:close(library_folder_dialog)
                local PathChooser = require("ui/widget/pathchooser")
                local Device = require("device")
                local DataStorage = require("datastorage")
                local start_path = G_reader_settings:readSetting("home_dir") or Device.home_dir or DataStorage:getDataDir()
                local path_chooser = PathChooser:new{
                    title = _("Add Library Folder"),
                    path = start_path,
                    select_directory = true,
                    select_file = false,
                    onConfirm = function(selected_path)
                        -- Check if already in permanent or ad-hoc
                        for _idx2, pf in ipairs(perm_folders) do
                            if pf == selected_path then
                                -- Re-enable if disabled
                                session_state.disabled_folders[selected_path] = nil
                                syncLibraryState()
                                refreshInputDialog()
                                return
                            end
                        end
                        for _idx2, af in ipairs(session_state.adhoc_folders) do
                            if af == selected_path then
                                UIManager:show(InfoMessage:new{
                                    text = T(_("Folder already added:\n%1"), selected_path),
                                    timeout = 3,
                                })
                                return
                            end
                        end
                        table.insert(session_state.adhoc_folders, selected_path)
                        syncLibraryState()
                        refreshInputDialog()
                    end,
                }
                UIManager:show(path_chooser)
            end,
        }})

        local effective = getEffectiveScanFolders()
        library_folder_dialog = ButtonDialog:new{
            title = T(_("Scan Folders (%1 active)"), #effective),
            buttons = menu_buttons,
        }
        UIManager:show(library_folder_dialog)
    end

    local function showAddBooksMenu()
        local ButtonDialog = require("ui/widget/buttondialog")
        local books = configuration and configuration.features and configuration.features.books_info
        local book_count = books and #books or 0
        local menu_buttons = {}

        -- View/Edit existing items (when items are selected)
        if book_count > 0 then
            table.insert(menu_buttons, {{
                text = T(_("View/Edit Items (%1)"), book_count),
                callback = function()
                    UIManager:close(add_books_dialog)
                    showSelectedBooksEditor()
                end,
            }})
        end

        -- Status presets: history + DocSettings, always available (no scanner needed)
        local function addStatusPreset(label, status_filter)
            table.insert(menu_buttons, {{
                text = label,
                callback = function()
                    UIManager:close(add_books_dialog)
                    local new_books = getBooksFromHistory(status_filter)
                    if not new_books then
                        UIManager:show(InfoMessage:new{
                            text = _("Reading history unavailable."),
                            timeout = 2,
                        })
                        return
                    end
                    if #new_books == 0 then
                        UIManager:show(InfoMessage:new{
                            text = T(_("No %1 books found in history."), label:lower()),
                            timeout = 2,
                        })
                        return
                    end
                    local added = mergeBooks(new_books)
                    if added == 0 then
                        UIManager:show(InfoMessage:new{
                            text = T(_("All %1 already selected."), #new_books),
                            timeout = 2,
                        })
                        return
                    end
                    refreshInputDialog()
                end,
            }})
        end
        addStatusPreset(_("Currently Reading"), "reading")
        addStatusPreset(_("Recently Finished"), "complete")
        addStatusPreset(_("On Hold"), "abandoned")

        -- Last 5 from History (no status filter, just recency)
        table.insert(menu_buttons, {{
            text = _("Last 5 from History"),
            callback = function()
                UIManager:close(add_books_dialog)
                local new_books = getBooksFromHistory(nil, 5)
                if not new_books then
                    UIManager:show(InfoMessage:new{
                        text = _("Reading history unavailable."),
                        timeout = 2,
                    })
                    return
                end
                if #new_books == 0 then
                    UIManager:show(InfoMessage:new{
                        text = _("No books found in history."),
                        timeout = 2,
                    })
                    return
                end
                local added = mergeBooks(new_books)
                if added == 0 then
                    UIManager:show(InfoMessage:new{
                        text = T(_("All %1 already selected."), #new_books),
                        timeout = 2,
                    })
                    return
                end
                refreshInputDialog()
            end,
        }})

        -- Browse History (opens BookPicker with full filter/search UI)
        table.insert(menu_buttons, {{
            text = _("Browse History…"),
            callback = function()
                UIManager:close(add_books_dialog)
                -- Close input dialog to prevent event leaks (is_always_active)
                if input_dialog then UIManager:close(input_dialog) end
                local BookPicker = require("koassistant_book_picker")
                BookPicker:show({
                    on_close = function()
                        refreshInputDialog()
                    end,
                    on_confirm = function(selected_files)
                        local DocSettings = require("docsettings")
                        local new_books = {}
                        for file, _v in pairs(selected_files) do
                            local title = nil
                            local author = ""
                            local ds = DocSettings:open(file)
                            local doc_props = ds:readSetting("doc_props")
                            if doc_props then
                                local dt = doc_props.display_title or doc_props.title
                                if dt and dt ~= "" then title = dt end
                                if doc_props.authors and doc_props.authors ~= "" then
                                    author = doc_props.authors:gsub("\n", ", ")
                                end
                            end
                            if not title then
                                title = file:match("([^/]+)%.[^%.]+$") or file
                            end
                            table.insert(new_books, {
                                title = title,
                                authors = author,
                                file = file,
                            })
                        end
                        mergeBooks(new_books)
                        refreshInputDialog()
                    end,
                })
            end,
        }})

        -- Browse Folder: open BookPicker with folder source for cherry-picking
        table.insert(menu_buttons, {{
            text = _("Browse Folder…"),
            callback = function()
                UIManager:close(add_books_dialog)
                -- Close input dialog to prevent event leaks (is_always_active)
                if input_dialog then UIManager:close(input_dialog) end
                local PathChooser = require("ui/widget/pathchooser")
                local Device = require("device")
                local DataStorage = require("datastorage")
                local start_path = G_reader_settings:readSetting("home_dir") or Device.home_dir or DataStorage:getDataDir()
                local folder_confirmed = false
                local path_chooser = PathChooser:new{
                    title = _("Select Folder"),
                    path = start_path,
                    select_directory = true,
                    select_file = false,
                    onConfirm = function(selected_path)
                        folder_confirmed = true
                        local BookPicker = require("koassistant_book_picker")
                        BookPicker:show({
                            initial_source = selected_path,
                            on_close = function()
                                refreshInputDialog()
                            end,
                            on_confirm = function(selected_files)
                                local DocSettings = require("docsettings")
                                local new_books = {}
                                for file, _v in pairs(selected_files) do
                                    local title = nil
                                    local author = ""
                                    local ds = DocSettings:open(file)
                                    local doc_props = ds:readSetting("doc_props")
                                    if doc_props then
                                        local dt = doc_props.display_title or doc_props.title
                                        if dt and dt ~= "" then title = dt end
                                        if doc_props.authors and doc_props.authors ~= "" then
                                            author = doc_props.authors:gsub("\n", ", ")
                                        end
                                    end
                                    if not title then
                                        title = file:match("([^/]+)%.[^%.]+$") or file
                                    end
                                    table.insert(new_books, {
                                        title = title,
                                        authors = author,
                                        file = file,
                                    })
                                end
                                mergeBooks(new_books)
                                refreshInputDialog()
                            end,
                        })
                    end,
                }
                path_chooser.close_callback = function()
                    if not folder_confirmed then
                        refreshInputDialog()
                    end
                end
                UIManager:show(path_chooser)
            end,
        }})

        -- Clear Selection (only if books are selected)
        if book_count > 0 then
            table.insert(menu_buttons, {{
                text = _("Clear Selection"),
                callback = function()
                    UIManager:close(add_books_dialog)
                    configuration.features = configuration.features or {}
                    configuration.features.books_info = nil
                    configuration.features.book_context = nil
                    configuration.features.book_metadata = nil
                    refreshInputDialog()
                end,
            }})
        end

        add_books_dialog = ButtonDialog:new{
            title = book_count > 0
                and T(book_count == 1 and _("%1 item selected") or _("%1 items selected"), book_count)
                or _("Add Items"),
            buttons = menu_buttons,
        }
        UIManager:show(add_books_dialog)
    end

    -- Library context: view and remove selected books
    -- Rebuilds book_context after removal; reopens itself unless list is emptied
    showSelectedBooksEditor = function()
        local books = configuration and configuration.features and configuration.features.books_info
        if not books or #books == 0 then return end

        local ButtonDialog = require("ui/widget/buttondialog")
        local editor_dialog
        local menu_buttons = {}

        -- Helper: rebuild book_context from current books_info
        local function rebuildBookContext()
            local current = configuration.features.books_info
            if not current or #current == 0 then
                configuration.features.books_info = nil
                configuration.features.book_context = nil
                configuration.features.book_metadata = nil
                return
            end
            local parts = {}
            for i, b in ipairs(current) do
                if b.authors and b.authors ~= "" then
                    table.insert(parts, string.format('%d. "%s" by %s', i, b.title, b.authors))
                else
                    table.insert(parts, string.format('%d. "%s"', i, b.title))
                end
            end
            configuration.features.book_context = string.format(
                "Selected %d books:\n\n%s", #current, table.concat(parts, "\n"))
            configuration.features.book_metadata = {
                title = current[1].title,
                author = current[1].authors or "",
            }
        end

        for idx, book in ipairs(books) do
            local label = book.authors and book.authors ~= ""
                and string.format('"%s" by %s', book.title, book.authors)
                or string.format('"%s"', book.title)
            table.insert(menu_buttons, {{
                text = label,
                callback = function()
                    UIManager:close(editor_dialog)
                    table.remove(books, idx)
                    rebuildBookContext()
                    if books and #books > 0 then
                        -- Reopen editor with updated list
                        showSelectedBooksEditor()
                    else
                        refreshInputDialog()
                    end
                end,
            }})
        end

        table.insert(menu_buttons, {{
            text = _("Clear All"),
            callback = function()
                UIManager:close(editor_dialog)
                configuration.features = configuration.features or {}
                configuration.features.books_info = nil
                configuration.features.book_context = nil
                configuration.features.book_metadata = nil
                refreshInputDialog()
            end,
        }})

        table.insert(menu_buttons, {{
            text = _("Done"),
            callback = function()
                UIManager:close(editor_dialog)
                refreshInputDialog()
            end,
        }})

        editor_dialog = ButtonDialog:new{
            title = T(#books == 1 and _("%1 item selected — tap to remove") or _("%1 items selected — tap to remove"), #books),
            buttons = menu_buttons,
        }
        UIManager:show(editor_dialog)
    end

    -- Build all input dialog buttons (called on init and on refresh via reinit)
    -- Library scan state: computed here (outer scope) so both buildInputDialogButtons and hint text can use it
    -- Settings come from plugin.settings (KOReader settings system), not configuration.features
    local settings_features = plugin and plugin.settings and plugin.settings:readSetting("features") or {}
    local is_trusted = false
    if settings_features.trusted_providers and configuration and configuration.provider then
        for _idx, tp in ipairs(settings_features.trusted_providers) do
            if tp == configuration.provider then is_trusted = true; break end
        end
    end
    local library_toggle_on = settings_features.enable_library_scanning == true or is_trusted
    local has_session_scan = plugin and plugin._session_scan_folders and #plugin._session_scan_folders > 0
    local has_permanent_folders = settings_features.library_scan_folders and #settings_features.library_scan_folders > 0
    local library_scan_available = library_toggle_on and (has_session_scan or has_permanent_folders)

    local has_more_actions = false  -- Set by buildInputDialogButtons, read by gear menu
    local buildInputDialogButtons
    buildInputDialogButtons = function()
        -- Data-access indicator context: the 🌐 follows-default indicator tracks the
        -- SESSION Web chip (which dialog-launched nil-flag actions follow), and (🔍)
        -- marks smart-retrieval actions when tools could actually run this session AND
        -- the session Tools chip is on (the chip governs the popup's default pick).
        local indicator_opts = {
            effective_web_search = session_web_search == true,
            tools_allowed = session_book_tools == true
                and (BookToolRunner.smartRetrievalAllowed(configuration, ui_instance)) == true,
        }
        -- Session chips (book_scoped_controls_plan.md §4): [Domain][Web][Tools][Scope]
        -- [Spoiler] by membership (gear menu → "Toolbar Buttons…"), replacing the old
        -- checkbox pile + top-row Web/Domain buttons. Binary chips toggle their SESSION
        -- value on tap and open the scope-aware defaults picker (For this book / Global)
        -- on hold. Chips render compact (smaller font); Send anchors the end of the row.
        local chips_book_or_highlight = not is_general_context and not is_library_context
        local chip_defs = {
            domain = function()
                -- Just the active domain name (the emoji or the word "Domain" replaces
                -- the old "Domain: X" prefix — maintainer 2026-07-12). 🏛️ matches the
                -- Quick Settings domain chip.
                local has_domain = (book_domain_id or selected_domain) and book_domain_id ~= "_none"
                local label
                if enable_emoji then
                    label = "\u{1F3DB}\u{FE0F} " .. getDomainDisplayName(true)
                else
                    label = has_domain and getDomainDisplayName(true) or _("Domain")
                end
                return {
                    text = label,
                    callback = function()
                        showDomainSelector()
                    end,
                }
            end,
            web_search = function()
                return {
                    text = getWebToggleText(),
                    callback = function()
                        -- Gate: unsupported providers can't search — explain instead of toggling
                        if not ConfigHelper:supportsWebSearch(configuration) then
                            UIManager:show(InfoMessage:new{
                                text = T(_("Web search isn't currently available for %1.\n\nSupported providers: %2."),
                                    configuration.provider or _("this provider"),
                                    ConfigHelper:getWebSearchProvidersLabel()),
                            })
                            return
                        end
                        session_web_search = not session_web_search
                        refreshInputDialog()
                    end,
                    hold_callback = function()
                        BookSettings.showWebSearch({
                            plugin = plugin, ui = ui_instance, document_path = document_path,
                            on_close = function() refreshInputDialog() end,
                        })
                    end,
                }
            end,
            book_tools = function()
                -- Book contexts only (needs an open book) — those are STRUCTURAL hides.
                -- Otherwise ALWAYS visible like the Web chip (maintainer 2026-07-12):
                -- "N/A" when the session can't run tools (tap explains why), a locked
                -- OFF when the posture master switch is off (tap points at the picker).
                if not (chips_book_or_highlight and has_open_book) then
                    return nil
                end
                if is_xray_chat then
                    -- POLICY exclusion (tools are off in X-Ray chat by design), not a
                    -- structural one — gray with reason instead of hiding, matching the
                    -- capability/consent N/A pattern (maintainer 2026-07-16). Enabling
                    -- same-book tools here is a deferred controls-parity decision
                    -- (tools_ux_plan.md revisit note).
                    local function explainXray()
                        UIManager:show(InfoMessage:new{
                            text = _("Book tools aren't available in X-Ray chats."),
                        })
                    end
                    return {
                        text = enable_emoji and ("\u{1F50D} " .. _("N/A")) or _("Tools N/A"),
                        callback = explainXray,
                        hold_callback = explainXray,
                    }
                end
                local eligible, reason = BookToolRunner.sessionEligible(configuration, ui_instance)
                local posture_off = effective_tools_posture == "off"
                local function holdPicker()
                    BookSettings.showToolsPosture({
                        plugin = plugin, ui = ui_instance, document_path = document_path,
                        on_close = function() refreshInputDialog() end,
                    })
                end
                if not eligible then
                    return {
                        text = enable_emoji and ("\u{1F50D} " .. _("N/A")) or _("Tools N/A"),
                        callback = function()
                            local msg
                            if reason == "consent" then
                                msg = _("Book tools need \"Allow Text Extraction\" (Settings → Privacy & Data).")
                            else
                                msg = T(_("Book tools aren't available for %1.\n\nSupported providers: Gemini, Claude (Anthropic), OpenAI, OpenRouter."),
                                    configuration.provider or _("this provider"))
                            end
                            UIManager:show(InfoMessage:new{ text = msg })
                        end,
                        hold_callback = holdPicker,
                    }
                end
                if posture_off then
                    return {
                        text = enable_emoji and ("\u{1F50D} " .. _("OFF")) or _("Tools OFF"),
                        callback = function()
                            UIManager:show(InfoMessage:new{
                                text = _("AI Book Tools are turned off. Long-press to turn them on for this book or globally."),
                                timeout = 3,
                            })
                        end,
                        hold_callback = holdPicker,
                    }
                end
                if configuration.features.is_book_context and configuration.features._session_scope then
                    -- A Scope-chip pick attaches text directly — tools are redundant for
                    -- that send (chip wins, flexible_scope_plan.md §4). Gray with reason,
                    -- like the other policy exclusions.
                    return {
                        text = enable_emoji and ("\u{1F50D} " .. _("N/A")) or _("Tools N/A"),
                        callback = function()
                            UIManager:show(InfoMessage:new{
                                text = _("The Scope chip attaches book text directly, so book tools are off for this send. Clear the Scope pick to use tools."),
                            })
                        end,
                        hold_callback = holdPicker,
                    }
                end
                return {
                    text = enable_emoji
                        and ("\u{1F50D} " .. (session_book_tools and _("ON") or _("OFF")))
                        or (session_book_tools and _("Tools ON") or _("Tools OFF")),
                    callback = function()
                        session_book_tools = not session_book_tools
                        refreshInputDialog()
                    end,
                    hold_callback = holdPicker,
                }
            end,
            quick = function()
                -- Quick chip (controls_parity_plan.md §2/§9 — #86): tap toggles the
                -- Quick Answer posture for this chat (concise · reasoning off ·
                -- web/tools off); hold opens the quick controls menu (one-shot
                -- reasoning/model overrides). State is CONFIG-RESIDENT
                -- (_session_quick_answer/_session_reasoning/_session_model —
                -- 60-upvalue cap), consumed at dispatch via the *_active
                -- transients; a fresh dialog open clears it (scope-chip lifecycle).
                local qf = configuration.features
                local qa_on = qf._session_quick_answer == true
                local has_override = qf._session_reasoning ~= nil or qf._session_model ~= nil
                local label
                if enable_emoji then
                    label = "\u{26A1} " .. (qa_on and _("ON") or (has_override and _("SET") or _("OFF")))
                else
                    label = qa_on and _("Quick ON") or (has_override and _("Quick SET") or _("Quick"))
                end
                return {
                    text = label,
                    callback = function()
                        configuration.features._session_quick_answer = (not qa_on) or nil
                        refreshInputDialog()
                    end,
                    hold_callback = function()
                        -- Runtime self-require on purpose: a direct file-local
                        -- reference would add an upvalue to buildInputDialogButtons,
                        -- which sits AT LuaJIT's 60-upvalue cap.
                        require("koassistant_dialogs").showQuickControlsMenu({
                            configuration = configuration,
                            plugin = plugin,
                            on_change = function() refreshInputDialog() end,
                        })
                    end,
                }
            end,
            spoiler = function()
                if not chips_book_or_highlight then return nil end
                -- State labels name the OUTCOME ("ON/OFF" over a negated feature read
                -- backwards — maintainer 2026-07-12). No emoji variant: the words carry
                -- the state, an icon would just add width.
                local spoiler_state = session_spoiler_free and _("No spoilers") or _("Spoilers OK")
                return {
                    text = spoiler_state,
                    callback = function()
                        session_spoiler_free = not session_spoiler_free
                        refreshInputDialog()
                    end,
                    hold_callback = function()
                        BookSettings.showSpoilerFree({
                            plugin = plugin, ui = ui_instance, document_path = document_path,
                            on_close = function() refreshInputDialog() end,
                        })
                    end,
                }
            end,
            scope = function()
                -- Scope chip (flexible_scope_plan.md phase 3). Session-only (§7): seeds
                -- empty on every fresh open; survives refresh via _session_keep_scope.
                -- State is CONFIG-RESIDENT (_session_scope / _session_highlight_context —
                -- no dialog locals, 60-upvalue cap). Structural inapplicability hides the
                -- chip; consent problems explain at row level (Tools-chip pattern).
                if not (chips_book_or_highlight and has_open_book) then return nil end
                -- X-Ray chat: pseudo-selection — ambient context and book scope are both
                -- excluded there by design (structural, like the highlight branch's
                -- xray_context_prefix skip).
                if is_xray_chat then return nil end
                local feats = configuration.features
                if feats.is_book_context then
                    -- Book facet: pick a text range to attach to the sent message.
                    local pick = feats._session_scope
                    local label
                    -- Emoji SWAPS the word "Scope" (🎯), state suffix stays — same
                    -- pattern as the web/tools chips.
                    if not pick then
                        label = enable_emoji and ("\u{1F3AF} " .. _("OFF")) or _("Scope")
                    elseif pick.kind == "page" then
                        label = enable_emoji and ("\u{1F3AF} " .. _("page")) or _("Scope: page")
                    elseif pick.kind == "to_position" then
                        label = enable_emoji and ("\u{1F3AF} " .. _("so far")) or _("Scope: so far")
                    else
                        local short, truncated = require("koassistant_scope_resolver")
                            .utf8First(pick.title or _("section"), 10)
                        short = short .. (truncated and "…" or "")
                        label = enable_emoji and ("\u{1F3AF} " .. short) or T(_("Scope: %1"), short)
                    end
                    local function pickScope()
                        local ButtonDialog = require("ui/widget/buttondialog")
                        local cur_page = (ui_instance.view and ui_instance.view.state
                            and ui_instance.view.state.page) or 1
                        local toc_available = ui_instance.toc and ui_instance.toc.toc
                            and #ui_instance.toc.toc > 0
                        local consent = feats.enable_book_text_extraction == true
                        if not consent and feats.trusted_providers then
                            for _i, tp in ipairs(feats.trusted_providers) do
                                if tp == configuration.provider then consent = true break end
                            end
                        end
                        local progress_fmt
                        do
                            local okr, CE = pcall(require, "koassistant_context_extractor")
                            if okr and CE then
                                local ex = CE:new(ui_instance, feats or {})
                                local okp, p = pcall(function() return ex:getReadingProgress() end)
                                if okp and p then progress_fmt = p.formatted end
                            end
                        end
                        local dialog
                        local function explainConsent()
                            UIManager:show(InfoMessage:new{
                                text = _("This scope needs \"Allow Text Extraction\" (Settings → Privacy & Data). \"Current page\" works without it."),
                            })
                        end
                        local function setPick(new_pick)
                            feats._session_scope = new_pick
                            UIManager:close(dialog)
                            refreshInputDialog()
                        end
                        local cur_kind = (feats._session_scope and feats._session_scope.kind) or "none"
                        local function mark(kind) return (kind == cur_kind) and "● " or "○ " end
                        -- Untitled TOC entries: mirror the picker's own "Page N" display fallback
                        local function pickerEntryLabel(entry)
                            local lbl = entry.title or ""
                            if lbl == "" then
                                local vis_sp = ui_instance.document.getPageNumberInFlow
                                    and ui_instance.document:getPageNumberInFlow(entry.start_page)
                                    or entry.start_page
                                lbl = T(_("Page %1"), vis_sp)
                            end
                            return lbl
                        end
                        -- The section rows funnel through the shared TOC picker; the
                        -- picker closes itself before on_select fires.
                        local function sectionRowPick(kind, picker_title)
                            if not consent then explainConsent() return end
                            UIManager:close(dialog)
                            plugin:_showSectionPicker({}, {
                                title = picker_title,
                                on_select = function(entry)
                                    -- Pick-time validation mirrors the unified popup's
                                    -- rules; Send-time chipScope re-validates (the
                                    -- position/spoiler chip can change after the pick).
                                    if kind == "from_section" and entry.start_page > cur_page then
                                        UIManager:show(InfoMessage:new{
                                            text = _("That section starts after your current position — pick an earlier one."),
                                        })
                                        refreshInputDialog()
                                        return
                                    end
                                    if kind == "section" and session_spoiler_free
                                        and entry.start_page > cur_page then
                                        UIManager:show(InfoMessage:new{
                                            text = _("That section is beyond your current position (spoiler-free is on)."),
                                        })
                                        refreshInputDialog()
                                        return
                                    end
                                    feats._session_scope = {
                                        kind = kind,
                                        start_page = entry.start_page,
                                        end_page = entry.end_page,
                                        title = pickerEntryLabel(entry),
                                    }
                                    refreshInputDialog()
                                end,
                            })
                        end
                        -- Custom range (phase 4): two sequential picks, start then end.
                        -- Under spoiler a fully-unread START is rejected; a straddling
                        -- END is allowed — Send-time chipScope clamps it with an honest
                        -- "trimmed to position" label (chip policy: clamp; the popup's
                        -- policy is reject).
                        local function rangeRowPick()
                            if not consent then explainConsent() return end
                            UIManager:close(dialog)
                            plugin:_showSectionPicker({}, {
                                title = _("Range start: which section?"),
                                on_select = function(start_entry)
                                    if session_spoiler_free and start_entry.start_page > cur_page then
                                        UIManager:show(InfoMessage:new{
                                            text = _("That section is beyond your current position (spoiler-free is on)."),
                                        })
                                        refreshInputDialog()
                                        return
                                    end
                                    plugin:_showSectionPicker({}, {
                                        title = _("Range end: which section?"),
                                        on_select = function(end_entry)
                                            if end_entry.start_page < start_entry.start_page then
                                                UIManager:show(InfoMessage:new{
                                                    text = _("The end section comes before the start section."),
                                                })
                                            else
                                                local from_title = pickerEntryLabel(start_entry)
                                                local to_title = pickerEntryLabel(end_entry)
                                                feats._session_scope = {
                                                    kind = "range",
                                                    start_page = start_entry.start_page,
                                                    end_page = end_entry.end_page,
                                                    title = from_title .. " – " .. to_title,
                                                    from_title = from_title,
                                                    to_title = to_title,
                                                }
                                            end
                                            refreshInputDialog()
                                        end,
                                    })
                                end,
                            })
                        end
                        local rows = {
                            {{ text = mark("none") .. _("No book text (metadata only)"),
                                callback = function() setPick(nil) end }},
                            {{ text = mark("page") .. _("Current page"),
                                callback = function() setPick({ kind = "page" }) end }},
                        }
                        if cur_page > 1 then
                            table.insert(rows, {{
                                text = mark("to_position") .. (progress_fmt
                                    and T(_("Up to current position (%1)"), progress_fmt)
                                    or _("Up to current position")),
                                callback = function()
                                    if not consent then explainConsent() return end
                                    setPick({ kind = "to_position" })
                                end,
                            }})
                        end
                        if toc_available then
                            if cur_page > 1 then
                                table.insert(rows, {{
                                    text = mark("from_section") .. _("From section… (to current position)"),
                                    callback = function()
                                        sectionRowPick("from_section", _("Start from which section?"))
                                    end,
                                }})
                            end
                            table.insert(rows, {{
                                text = mark("range") .. _("Pick section range…"),
                                callback = rangeRowPick,
                            }})
                            table.insert(rows, {{
                                text = mark("section") .. _("Choose section…"),
                                callback = function()
                                    sectionRowPick("section", _("Which section?"))
                                end,
                            }})
                        end
                        table.insert(rows, {{ text = _("Close"),
                            callback = function() UIManager:close(dialog) end }})
                        dialog = ButtonDialog:new{
                            title = _("Text to include with your message"),
                            buttons = rows,
                        }
                        UIManager:show(dialog)
                    end
                    return { text = label, callback = pickScope, hold_callback = pickScope }
                elseif highlighted_text then
                    -- Highlight facet: session override of the ambient surrounding-context
                    -- mode (the deferred surrounding_context_plan.md step-3 control).
                    -- Applies to freeform Send AND dialog-launched nil-flag actions;
                    -- explicit per-action modes still win in effectiveSurroundingContextMode.
                    local mode = feats._session_highlight_context
                        or BookSettings.resolveHighlightContext(doc_settings, feats)
                    local label
                    if mode == "sentence" then
                        label = enable_emoji and ("\u{1F3AF} " .. _("sentence")) or _("Ctx: sentence")
                    elseif mode == "paragraph" then
                        label = enable_emoji and ("\u{1F3AF} " .. _("paragraph")) or _("Ctx: paragraph")
                    elseif mode == "characters" then
                        label = enable_emoji and ("\u{1F3AF} " .. _("characters")) or _("Ctx: characters")
                    else
                        label = enable_emoji and ("\u{1F3AF} " .. _("OFF")) or _("Ctx off")
                    end
                    local function pickMode()
                        local ButtonDialog = require("ui/widget/buttondialog")
                        local dialog
                        local function mark(m) return (m == mode) and "● " or "○ " end
                        local function setMode(m)
                            feats._session_highlight_context = m
                            UIManager:close(dialog)
                            refreshInputDialog()
                        end
                        dialog = ButtonDialog:new{
                            title = _("Context around the selection — for this chat"),
                            buttons = {
                                {{ text = mark("none") .. _("Off"), callback = function() setMode("none") end }},
                                {{ text = mark("sentence") .. _("Sentence"), callback = function() setMode("sentence") end }},
                                {{ text = mark("paragraph") .. _("Paragraph"), callback = function() setMode("paragraph") end }},
                                {{ text = mark("characters") .. _("Characters"), callback = function() setMode("characters") end }},
                                {{ text = _("Close"), callback = function() UIManager:close(dialog) end }},
                            },
                        }
                        UIManager:show(dialog)
                    end
                    return {
                        text = label,
                        callback = pickMode,
                        -- Hold = persistent defaults (book/global), tap = session — the
                        -- established chip pattern.
                        hold_callback = function()
                            BookSettings.showHighlightContext({
                                plugin = plugin, ui = ui_instance, document_path = document_path,
                                on_close = function() refreshInputDialog() end,
                            })
                        end,
                    }
                end
                return nil
            end,
            attach = function()
                -- Attach chip (attach_plan.md v1): material OTHER than the open
                -- book's text — notebook, saved artifacts/chats, text files, free
                -- notes. ALL input-dialog contexts, X-Ray chat included
                -- (maintainer 2026-07-17: it's a full input dialog, and unlike
                -- Scope's text ranges an attachment doesn't conflict with the
                -- item-pseudo-selection framing). Staged list is MODULE-RESIDENT
                -- in koassistant_attachments (no dialog locals — 60-upvalue cap;
                -- not on features — settings-flush exposure); inline requires on
                -- purpose.
                local feats = configuration.features
                local count = require("koassistant_attachments").count()
                -- Count, not ON/OFF — attach is a collection, not a toggle
                -- (maintainer 2026-07-17: no "OFF" legend; empty shows 0/plain)
                local label
                if count > 0 then
                    label = enable_emoji and ("\u{1F4CE} " .. tostring(count))
                        or T(_("Attach (%1)"), count)
                else
                    label = enable_emoji and "\u{1F4CE} 0" or _("Attach")
                end
                -- Manage list (hold, or the "manage…" row): stays open across
                -- removals, refreshes the input dialog once at close — the
                -- Toolbar-Buttons-manager pattern.
                local manage_dialog
                local showManage
                showManage = function(changed)
                    local Attachments = require("koassistant_attachments")
                    local list = Attachments.getList() or {}
                    local rows = {}
                    for i, entry in ipairs(list) do
                        local idx = i
                        local entry_label = entry.label
                        table.insert(rows, {{
                            text = T(_("Remove: %1"), entry_label),
                            callback = function()
                                UIManager:close(manage_dialog)
                                Attachments.remove(idx)
                                if Attachments.count() > 0 then
                                    showManage(true)
                                else
                                    refreshInputDialog()
                                end
                            end,
                        }})
                    end
                    if #list > 1 then
                        table.insert(rows, {{
                            text = _("Remove all"),
                            callback = function()
                                UIManager:close(manage_dialog)
                                Attachments.clear()
                                refreshInputDialog()
                            end,
                        }})
                    end
                    table.insert(rows, {{
                        text = _("Close"),
                        callback = function()
                            UIManager:close(manage_dialog)
                            if changed then refreshInputDialog() end
                        end,
                    }})
                    manage_dialog = require("ui/widget/buttondialog"):new{
                        title = _("Attached to this chat"),
                        buttons = rows,
                        tap_close_callback = function()
                            if changed then refreshInputDialog() end
                        end,
                    }
                    UIManager:show(manage_dialog)
                end
                local function showTypeMenu()
                    local Attachments = require("koassistant_attachments")
                    local book_path = document_path
                        or (ui_instance and ui_instance.document and ui_instance.document.file)
                    local type_dialog
                    local rows = {}
                    local n = Attachments.count()
                    if n > 0 then
                        table.insert(rows, {{
                            text = T(_("Attached (%1) — manage…"), n),
                            callback = function()
                                UIManager:close(type_dialog)
                                showManage()
                            end,
                        }})
                    end
                    if chips_book_or_highlight and book_path then
                        table.insert(rows, {{
                            text = _("Notebook (this book)"),
                            callback = function()
                                -- Same gate as use_notebook (attach_plan.md §4);
                                -- trusted providers bypass as elsewhere.
                                if feats.enable_notebook_sharing ~= true
                                        and not Attachments.isTrustedProvider(feats, configuration.provider) then
                                    UIManager:show(InfoMessage:new{
                                        text = _("Attaching your notebook needs \"Notebook sharing\" (Settings → Privacy & Data)."),
                                    })
                                    return
                                end
                                local entry, err = Attachments.makeNotebook(book_path)
                                if not entry then
                                    UIManager:show(InfoMessage:new{ text = err })
                                    return
                                end
                                Attachments.add(entry)
                                UIManager:close(type_dialog)
                                refreshInputDialog()
                            end,
                        }})
                    end
                    table.insert(rows, {{
                        text = _("Artifact…"),
                        callback = function()
                            UIManager:close(type_dialog)
                            -- With a current book: open ITS selector directly (no
                            -- browser stacked underneath — maintainer 2026-07-17);
                            -- the selector offers "All books…" when launched this
                            -- way. Bookless contexts go straight to the browser.
                            local AB = require("koassistant_artifact_browser")
                            local sel_opts = {
                                enable_emoji = enable_emoji,
                                select_mode = {
                                    on_select = function(entry)
                                        require("koassistant_attachments").add(entry)
                                        refreshInputDialog()
                                    end,
                                },
                            }
                            if book_path then
                                AB:showArtifactSelector(book_path, nil, sel_opts)
                            else
                                AB:showArtifactBrowser(sel_opts)
                            end
                        end,
                    }})
                    table.insert(rows, {{
                        text = _("Chat…"),
                        callback = function()
                            UIManager:close(type_dialog)
                            local chm = require("koassistant_chat_history_manager"):new()
                            require("koassistant_chat_history_dialog"):showChatHistoryBrowser(
                                ui_instance, book_path, chm, configuration, {
                                    level = "documents",
                                    came_from_document = book_path ~= nil,
                                    initial_document = book_path,
                                    select_mode = {
                                        on_select = function(entry)
                                            require("koassistant_attachments").add(entry)
                                            refreshInputDialog()
                                        end,
                                    },
                                })
                        end,
                    }})
                    table.insert(rows, {{
                        text = _("Text file…"),
                        callback = function()
                            UIManager:close(type_dialog)
                            local PathChooser = require("ui/widget/pathchooser")
                            local start_path = G_reader_settings:readSetting("home_dir")
                                or require("device").home_dir
                                or require("datastorage"):getDataDir()
                            UIManager:show(PathChooser:new{
                                title = _("Select a text file to attach"),
                                path = start_path,
                                select_file = true,
                                select_directory = false,
                                file_filter = function(filename)
                                    local lower = filename:lower()
                                    return lower:match("%.txt$") ~= nil or lower:match("%.md$") ~= nil
                                end,
                                onConfirm = function(file_path)
                                    local A = require("koassistant_attachments")
                                    local entry, err = A.makeFile(file_path)
                                    if not entry then
                                        UIManager:show(InfoMessage:new{ text = err })
                                        return
                                    end
                                    A.add(entry)
                                    refreshInputDialog()
                                end,
                            })
                        end,
                    }})
                    table.insert(rows, {{
                        text = _("Note…"),
                        callback = function()
                            UIManager:close(type_dialog)
                            local note_dialog
                            note_dialog = require("ui/widget/inputdialog"):new{
                                title = _("Attach a note"),
                                input_hint = _("Background context for this whole chat — sent alongside your messages as a note from you, not as a question.\ne.g. \"this is the 2nd edition\", \"I'm reading this for a course\", \"the file's author metadata is wrong\""),
                                allow_newline = true,
                                -- Multi-line by default; only text_height works for
                                -- InputDialog sizing (input_height is a no-op)
                                text_height = require("device").screen:scaleBySize(160),
                                buttons = {{
                                    {
                                        text = _("Cancel"),
                                        id = "close",
                                        callback = function()
                                            UIManager:close(note_dialog)
                                        end,
                                    },
                                    {
                                        text = _("Attach"),
                                        callback = function()
                                            local A = require("koassistant_attachments")
                                            local entry, err = A.makeNote(note_dialog:getInputText())
                                            if not entry then
                                                UIManager:show(InfoMessage:new{ text = err })
                                                return
                                            end
                                            UIManager:close(note_dialog)
                                            A.add(entry)
                                            refreshInputDialog()
                                        end,
                                    },
                                }},
                            }
                            UIManager:show(note_dialog)
                            note_dialog:onShowKeyboard()
                        end,
                    }})
                    table.insert(rows, {{
                        text = _("Cancel"),
                        callback = function() UIManager:close(type_dialog) end,
                    }})
                    type_dialog = require("ui/widget/buttondialog"):new{
                        title = _("Attach to this chat"),
                        buttons = rows,
                    }
                    UIManager:show(type_dialog)
                end
                return {
                    text = label,
                    callback = showTypeMenu,
                    hold_callback = function()
                        if require("koassistant_attachments").count() > 0 then
                            showManage()
                        else
                            showTypeMenu()
                        end
                    end,
                }
            end,
        }
        local session_chips = {}
        for _idx, chip_id in ipairs(getSessionChips(configuration and configuration.features)) do
            local build = chip_defs[chip_id]
            local def = build and build()
            if def then
                table.insert(session_chips, def)
            end
        end

        -- Send (freeform chat with context)
        local send_button = {
                text = enable_emoji and (_("Send") .. " ➤") or _("Send"),
                -- In library context, disable Send when there's nothing to chat about
                enabled = not (configuration.features.is_library_context
                    and not (library_toggle_on and (has_session_scan or has_permanent_folders))
                    and not (configuration.features.books_info and #configuration.features.books_info > 0)),
            callback = function()
                -- Block empty sends for contexts without highlighted text (nothing useful to send)
                local typed_text = input_dialog:getInputText()
                if (not typed_text or typed_text == "") and not highlighted_text then
                    UIManager:show(InfoMessage:new{
                        text = _("Type a message first, or tap an action button."),
                        timeout = 2,
                    })
                    return
                end
                -- Session Scope pick (flexible_scope_plan.md phase 3): resolve into an
                -- attachable text block BEFORE closing the dialog, so a Cancel on the
                -- size warning — or an invalid pick — keeps the typed input intact.
                -- Inline requires on purpose (60-upvalue cap).
                local scope_block
                local scope_pick = configuration.features and configuration.features._session_scope
                if scope_pick and configuration.features.is_book_context
                        and ui_instance and ui_instance.document then
                    local CE = require("koassistant_context_extractor")
                    if scope_pick.kind == "page" then
                        -- Current visible page: extraction-gating exempt (use_page_text precedent)
                        local okv, res = pcall(function()
                            return CE:new(ui_instance, configuration.features or {}):getVisiblePageText()
                        end)
                        local text = okv and res and res.text or ""
                        if text == "" then
                            UIManager:show(InfoMessage:new{
                                text = _("Couldn't extract the current page's text. Clear the Scope chip or pick another scope."),
                                timeout = 4,
                            })
                            return
                        end
                        scope_block = { label = "Text of the reader's current page:", text = text }
                    else
                        local consent = configuration.features.enable_book_text_extraction == true
                        if not consent and configuration.features.trusted_providers then
                            for _i, tp in ipairs(configuration.features.trusted_providers) do
                                if tp == configuration.provider then consent = true; break end
                            end
                        end
                        if not consent then
                            UIManager:show(InfoMessage:new{
                                text = _("The chosen scope needs \"Allow Text Extraction\" (Settings → Privacy & Data). Clear the Scope chip or enable extraction."),
                                timeout = 5,
                            })
                            return
                        end
                        local cur_page = (ui_instance.view and ui_instance.view.state
                            and ui_instance.view.state.page) or 1
                        local range, range_reason = require("koassistant_scope_resolver").chipScope(
                            scope_pick, {
                                current_page = cur_page,
                                spoiler_free = session_spoiler_free == true,
                            })
                        if not range then
                            UIManager:show(InfoMessage:new{
                                text = range_reason == "beyond_position"
                                    and _("The chosen section is beyond your current position (spoiler-free is on). Pick another scope.")
                                    or _("Nothing to include for the chosen scope yet. Pick another scope."),
                                timeout = 4,
                            })
                            return
                        end
                        -- Consent (incl. trusted bypass) checked above — pass a resolved flag
                        local okr, res = pcall(function()
                            return CE:new(ui_instance, {
                                enable_book_text_extraction = true,
                                max_book_text_chars = (configuration.features or {}).max_book_text_chars,
                            }):getPageRangeText(range.start_page, range.end_page, {})
                        end)
                        local text = okr and res and res.text or ""
                        if text == "" then
                            UIManager:show(InfoMessage:new{
                                text = _("Couldn't extract text for the chosen scope. Clear the Scope chip or pick another scope."),
                                timeout = 4,
                            })
                            return
                        end
                        local progress_fmt
                        do
                            local okp, p = pcall(function()
                                return CE:new(ui_instance, configuration.features or {}):getReadingProgress()
                            end)
                            if okp and p then progress_fmt = p.formatted end
                        end
                        progress_fmt = progress_fmt or "?"
                        -- Prompt text (untranslated, like the other parts labels):
                        -- self-describing so the model knows exactly what slice it has
                        -- (smart-retrieval labeling convention).
                        local label
                        if scope_pick.kind == "to_position" then
                            label = string.format(
                                "Text from the book, from the beginning to the reader's current position (%s):",
                                progress_fmt)
                        elseif scope_pick.kind == "from_section" then
                            label = string.format(
                                'Text from the book, from the start of the section "%s" to the reader\'s current position (%s):',
                                scope_pick.title or "", progress_fmt)
                        elseif scope_pick.kind == "range" then
                            if range.clamped then
                                label = string.format(
                                    'Text from the book, from the section "%s" through "%s", trimmed to the reader\'s current position (%s):',
                                    scope_pick.from_title or "", scope_pick.to_title or "", progress_fmt)
                            else
                                label = string.format(
                                    'Text from the book, from the section "%s" through "%s":',
                                    scope_pick.from_title or "", scope_pick.to_title or "")
                            end
                        elseif range.clamped then
                            label = string.format(
                                'Text of the section "%s" from the book, trimmed to the reader\'s current position (%s):',
                                scope_pick.title or "", progress_fmt)
                        else
                            label = string.format('Text of the section "%s" from the book:',
                                scope_pick.title or "")
                        end
                        scope_block = { label = label, text = text }
                    end
                end
                local function performSend()
                    -- NEW ARCHITECTURE (v0.5.2+): Unified request config for all providers
                    -- System prompt and domain are built by buildUnifiedRequestConfig

                    -- Get domain context if a domain is selected (for passing to buildUnifiedRequestConfig)
                    -- Priority: book domain > global selected_domain
                    -- book_domain_id "_none" = explicit override to no domain
                    local domain_id
                    if book_domain_id == "_none" then
                        domain_id = nil
                    else
                        domain_id = book_domain_id or selected_domain
                    end
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
                    -- No prompt_action for Send — title uses user question or highlight directly
                    local history = MessageHistory:new(nil, nil)

                    -- Store source data for title generation
                    if highlighted_text and highlighted_text ~= "" then
                        history.source_highlight = highlighted_text
                    end

                    -- Store domain in history for saving with chat
                    if domain_id then
                        history.domain = domain_id
                    end

                    -- Build consolidated message parts (no system/domain - they're in config.system now)
                    local parts = {}
                    local scope_attached = false  -- set by the book branch's Scope-chip block

                    -- For book-info level "full": gather reading position to append to the book
                    -- line. Respects Basic Stats; silently adds nothing when unavailable.
                    local function appendSendPosition()
                        if (configuration.features or {}).enable_basic_stats == false then return end
                        local prog = book_metadata and book_metadata.reading_progress
                        local chapter, page
                        local ok, CE = pcall(require, "koassistant_context_extractor")
                        if ok and CE and ui_instance and ui_instance.document then
                            local ex = CE:new(ui_instance, configuration.features or {})
                            local oks, stats = pcall(function() return ex:getReadingStats() end)
                            if oks and stats then chapter = stats.chapter_title; page = stats.page_number end
                            if not prog then
                                local okp, p = pcall(function() return ex:getReadingProgress() end)
                                if okp and p then prog = p.formatted end
                            end
                        end
                        if prog and prog ~= "" and prog ~= "0%" then table.insert(parts, "Reading progress: " .. prog) end
                        if chapter and chapter ~= "" and chapter ~= "(Chapter unavailable)" then table.insert(parts, "Current chapter: " .. chapter) end
                        if page and page ~= "" then table.insert(parts, "Page: " .. page) end
                    end

                    -- Add appropriate context
                    if configuration.features.is_library_context then
                        -- For library context, include selected books and/or library scan
                        local lib_context = configuration.features.book_context
                        if lib_context then
                            table.insert(parts, "[Context]")
                            table.insert(parts, lib_context)
                            table.insert(parts, "")
                        end
                        -- Auto-attach library scan data when scanning is enabled
                        -- Global toggle is absolute gate; session folders bypass folder config only
                        local scan_folders_to_use
                        if library_toggle_on then
                            scan_folders_to_use = plugin and plugin._session_scan_folders
                            if not scan_folders_to_use then
                                local lib_features = plugin and plugin.settings and plugin.settings:readSetting("features") or {}
                                if lib_features.library_scan_folders and #lib_features.library_scan_folders > 0 then
                                    scan_folders_to_use = lib_features.library_scan_folders
                                end
                            end
                        end
                        if scan_folders_to_use and #scan_folders_to_use > 0 then
                            local scan_ok, LibraryScanner = pcall(require, "koassistant_library_scanner")
                            if scan_ok and LibraryScanner then
                                local scan_settings = { library_scan_folders = scan_folders_to_use }
                                local scan_result = LibraryScanner.scan(scan_settings)
                                if scan_result and scan_result.books and #scan_result.books > 0 then
                                    local formatted = LibraryScanner.format(scan_result)
                                    if formatted and formatted ~= "" then
                                        table.insert(parts, "My library:")
                                        table.insert(parts, formatted)
                                        table.insert(parts, "")
                                    end
                                end
                            end
                        end
                    elseif configuration.features.is_book_context then
                        -- For book context (file browser or gesture action), include book metadata
                        -- unless the per-book "Book info" level is None.
                        local book_info_level = require("koassistant_book_settings")
                            .resolveBookInfoLevel(doc_settings, configuration.features)
                        if book_info_level ~= "none" then
                            table.insert(parts, "[Context]")
                            if ai_book_metadata then
                                local show_author = book_info_level ~= "title"
                                    and ai_book_metadata.author and ai_book_metadata.author ~= ""
                                table.insert(parts, string.format('Book: "%s"%s',
                                    ai_book_metadata.title or "Unknown",
                                    show_author and (" by " .. ai_book_metadata.author) or ""))
                            elseif highlighted_text then
                                -- Fallback to highlighted_text if it contains formatted book info
                                table.insert(parts, highlighted_text)
                            end
                            if book_info_level == "full" then appendSendPosition() end
                            table.insert(parts, "")
                        end
                        -- Session Scope chip block (flexible_scope_plan.md phase 3):
                        -- pre-extracted in the Send callback, consumed here one-shot.
                        local sb = configuration.features._session_scope_block
                        configuration.features._session_scope_block = nil
                        if sb then
                            scope_attached = true
                            table.insert(parts, sb.label)
                            table.insert(parts, sb.text)
                            table.insert(parts, "")
                        end
                    elseif configuration.features.is_general_context then
                        -- For general context, no initial context needed
                        -- User will provide their question/prompt
                    elseif highlighted_text then
                        -- For highlighted text context - include book info unless the per-book
                        -- "Book info" level is None (the selected text is always included).
                        local book_info_level = require("koassistant_book_settings")
                            .resolveBookInfoLevel(doc_settings, configuration.features)
                        table.insert(parts, "[Context]")
                        if ai_book_metadata and ai_book_metadata.title and book_info_level ~= "none" then
                            local show_author = book_info_level ~= "title"
                                and ai_book_metadata.author and ai_book_metadata.author ~= ""
                            table.insert(parts, string.format('From "%s"%s',
                                ai_book_metadata.title,
                                show_author and (" by " .. ai_book_metadata.author) or ""))
                            if book_info_level == "full" then appendSendPosition() end
                            table.insert(parts, "")
                        end
                        -- Inject X-Ray context framing before selected text (explains source)
                        if xray_context_prefix then
                            table.insert(parts, xray_context_prefix)
                            table.insert(parts, "")
                        end
                        table.insert(parts, "Selected text:")
                        table.insert(parts, '"' .. highlighted_text .. '"')
                        table.insert(parts, "")
                        -- Ambient surrounding context (surrounding_context_plan.md): freeform
                        -- Send follows the per-book > global mode. The window was pre-extracted
                        -- at the entry point (the live selection is long gone) and consumed
                        -- here; the fingerprint check discards a window from a different
                        -- selection, and X-Ray chat (item-name pseudo-selection) is excluded.
                        -- NOTE: inline requires on purpose — a file-local reference here would
                        -- add upvalues to a closure at LuaJIT's 60-upvalue cap.
                        local sc_window = configuration.features._selection_context_window
                        configuration.features._selection_context_window = nil
                        if sc_window and sc_window.text == highlighted_text
                            and not xray_context_prefix then
                            -- Session override (Scope chip, highlight facet) wins over the
                            -- per-book/global mode; "none" is an explicit session OFF.
                            local sc_mode = configuration.features._session_highlight_context
                                or require("koassistant_book_settings")
                                .resolveHighlightContext(doc_settings, configuration.features)
                            if sc_mode ~= "none" then
                                local sc_text = require("koassistant_scope_resolver").trimContext(
                                    sc_window.prev, sc_window.next,
                                    highlighted_text, sc_mode, {
                                        char_count = configuration.features.highlight_context_chars or 100,
                                        paragraphs = configuration.features.highlight_context_paragraphs or 1,
                                    })
                                if sc_text ~= "" then
                                    table.insert(parts, require("prompts.templates").SURROUNDING_CONTEXT_LABEL)
                                    table.insert(parts, sc_text)
                                    table.insert(parts, "")
                                end
                            end
                        end
                    end

                    -- Get user's typed question
                    local question = input_dialog:getInputText()
                    local has_user_question = question and question ~= ""

                    -- Store user question for title generation
                    if has_user_question then
                        history.source_input = question
                    end

                    -- Add user question to context message
                    if has_user_question then
                        table.insert(parts, "[User Question]")
                        table.insert(parts, question)
                    end

                    -- Create the consolidated message (sent to AI as context)
                    local consolidated_message = table.concat(parts, "\n")
                    history:addUserMessage(consolidated_message, true)

                    -- Attach chip (attach_plan.md §4): staged attachments ride as
                    -- their own is_context message — the gather-bundle wire
                    -- pattern, proven on all providers. AFTER the consolidated
                    -- message, not before: Notebook.saveChat (and friends) treat
                    -- the FIRST user message as THE context message. Context-
                    -- independent (works in general/library sends too). Inline
                    -- require on purpose (60-upvalue cap).
                    do
                        local A = require("koassistant_attachments")
                        local attach_msg = A.buildMessage(A.getList())
                        if attach_msg then
                            history:addUserMessage(attach_msg, true)
                        end
                    end

                    -- Quick controls (controls_parity_plan.md §10): with a one-shot
                    -- session override active, rebase THIS chat onto a config COPY.
                    -- The override must ride the chat's config (replies stay sticky on
                    -- viewer.configuration) without ever touching the shared module
                    -- table: updateConfigFromSettings gives top-level provider/model
                    -- no underscore protection, and direct entries must never inherit
                    -- session state. The *_active consumables go on the copy (consumed
                    -- at bake); the chip state is cleared from the SHARED features.
                    -- Rebinding `configuration` here is deliberate — every later use
                    -- in this Send (bake, queries, viewer, replies, model-info) must
                    -- see the same overridden config.
                    do
                        local shared_features = configuration.features
                        if shared_features._session_quick_answer
                            or shared_features._session_reasoning
                            or shared_features._session_model then
                            -- Inline shallow-2-level copy (createTempConfig's shape) on
                            -- purpose: referencing the file-local helper here would add
                            -- an upvalue to a closure at LuaJIT's 60-upvalue cap.
                            local copy = {}
                            for k, v in pairs(configuration) do
                                if type(v) ~= "table" then
                                    copy[k] = v
                                else
                                    copy[k] = {}
                                    for k2, v2 in pairs(v) do
                                        copy[k][k2] = v2
                                    end
                                end
                            end
                            configuration = copy
                            local cf = configuration.features
                            cf._quick_answer_active = shared_features._session_quick_answer
                            cf._reasoning_override_active = shared_features._session_reasoning
                            cf._model_override_active = shared_features._session_model
                            cf._session_quick_answer = nil
                            cf._session_reasoning = nil
                            cf._session_model = nil
                            shared_features._session_quick_answer = nil
                            shared_features._session_reasoning = nil
                            shared_features._session_model = nil
                        end
                    end

                    -- Set spoiler-free flag for system prompt injection (freeform chat only)
                    -- This is read by buildUnifiedRequestConfig → buildUnifiedSystem, and by the
                    -- tool runner's resolveReadingScope. Use an explicit true/false (not true/nil)
                    -- so an unchecked session box is authoritative for BOTH the nudge (truthy) and
                    -- the tool reading scope, even when global spoiler-free is on.
                    if not is_general_context and not is_library_context then
                        configuration.features = configuration.features or {}
                        configuration.features._spoiler_free_active = session_spoiler_free == true
                        -- Per-chat tools activation (D1): explicit true/false so an unchecked
                        -- box overrides a globally-enabled flag, and a checked box activates
                        -- tools even when the global flag is off. Read by shouldUse; inherits
                        -- across replies via viewer.configuration like the spoiler flag.
                        -- A Scope-chip attachment wins over tools for this send (the text
                        -- is already in the message — flexible_scope_plan.md §4).
                        configuration.features._tools_active = session_book_tools == true
                            and not scope_attached
                    else
                        if configuration.features then
                            configuration.features._spoiler_free_active = nil
                            configuration.features._tools_active = nil
                        end
                    end

                    -- Per-chat web-search toggle: applies in EVERY context (general and
                    -- library chats can search too). Explicit true/false, mirroring the
                    -- tools flag; baked into config.enable_web_search — and consumed —
                    -- by buildUnifiedRequestConfig below.
                    configuration.features = configuration.features or {}
                    configuration.features._web_search_active = session_web_search == true

                    -- Resolve research mode for freeform chat (no action override)
                    -- Priority: per-book setting > DOI auto-detection > global setting
                    local freeform_research = false
                    local book_research_setting = getBookResearchMode(doc_settings)
                    if book_research_setting == true then
                        freeform_research = true
                    elseif book_research_setting == false then
                        freeform_research = false
                    else
                        local has_doi = configuration.features and configuration.features.book_metadata
                            and configuration.features.book_metadata.doi
                        if has_doi then
                            freeform_research = true
                        else
                            freeform_research = configuration.features
                                and configuration.features.research_mode == true
                        end
                    end
                    configuration.features = configuration.features or {}
                    configuration.features._research_mode_active = freeform_research or nil
                    -- Persist x-ray flag for the chat session so reply paths can skip book tools
                    -- (BookToolRunner.shouldUse reads features._xray_chat_active).
                    configuration.features._xray_chat_active = is_xray_chat or nil

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
                                local answer_result = BookToolRunner.queryWith(queryChatGPT, history:getMessages(), configuration, function(msg_success, msg_answer, msg_err, msg_reasoning, msg_web_search_used)
                                    if msg_success and msg_answer then
                                        history:addAssistantMessage(msg_answer, ConfigHelper:getModelInfo(configuration), msg_reasoning, ConfigHelper:buildDebugInfo(configuration), msg_web_search_used)
                                    else
                                        -- Cancelled/failed: roll the unanswered question back out
                                        history:removeLastUserMessage()
                                    end
                                    if on_complete then on_complete(msg_success, msg_answer, msg_err, msg_reasoning, msg_web_search_used) end
                                end, plugin, ui_instance)
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
                    local result = BookToolRunner.queryWith(queryChatGPT, history:getMessages(), configuration, onResponseReady, plugin, ui_instance)
                    -- If not streaming, callback was already invoked
                end
                local function dispatchSend()
                    if scope_block then
                        -- Consumed one-shot by performSend's book branch
                        configuration.features._session_scope_block = scope_block
                    end
                    UIManager:close(input_dialog)
                    -- Note: Loading dialog now handled by handleNonStreamingBackground in gpt_query.lua
                    UIManager:scheduleIn(0.1, performSend)
                end
                -- Same cost guard as the action path (checkLargeExtractionAndSend);
                -- here Cancel keeps the dialog open with the typed input intact.
                if scope_block
                        and #scope_block.text > require("koassistant_constants").LARGE_EXTRACTION_THRESHOLD
                        and not (configuration.features and configuration.features.suppress_large_extraction_warning) then
                    local ButtonDialog = require("ui/widget/buttondialog")
                    local chars_k = math.floor(#scope_block.text / 1000)
                    local tokens_low = math.floor(#scope_block.text / 4000)
                    local tokens_high = math.floor(#scope_block.text / 2000)
                    local warning_dialog
                    warning_dialog = ButtonDialog:new{
                        title = T(_("Large text extraction: ~%1K characters (~%2K-%3K tokens). Make sure your model's context window can accommodate this.\n\nYou can pick a smaller scope on the Scope chip, or use KOReader's Hidden Flows to exclude irrelevant content."), chars_k, tokens_low, tokens_high),
                        buttons = {
                            {{
                                text = _("Cancel"),
                                callback = function()
                                    UIManager:close(warning_dialog)
                                end,
                            }},
                            {{
                                text = _("Continue"),
                                callback = function()
                                    UIManager:close(warning_dialog)
                                    dispatchSend()
                                end,
                            }},
                            {{
                                text = _("Don't warn again"),
                                callback = function()
                                    UIManager:close(warning_dialog)
                                    if plugin and plugin.settings then
                                        local features_tbl = plugin.settings:readSetting("features") or {}
                                        features_tbl.suppress_large_extraction_warning = true
                                        plugin.settings:saveSetting("features", features_tbl)
                                        plugin.settings:flush()
                                    end
                                    if configuration.features then
                                        configuration.features.suppress_large_extraction_warning = true
                                    end
                                    dispatchSend()
                                end,
                            }},
                        },
                    }
                    UIManager:show(warning_dialog)
                    return
                end
                dispatchSend()
            end,
            hold_callback = function()
                local hint
                if highlighted_text then
                    hint = _("Send your typed message (or the selected text) as a freeform chat to the AI, without using any action template.")
                else
                    hint = _("Send your typed message as a freeform chat to the AI, without using any action template.")
                end
                UIManager:show(InfoMessage:new{
                    text = hint,
                    timeout = 4,
                })
            end,
        }
        -- Chips + Send fill the TOP ROW ONLY, shrinking with count (maintainer
        -- 2026-07-12): all chips + Send share one row; font size steps down as the row
        -- fills. Current max is 7 chips + Send (Quick joined 2026-07-19); if the row
        -- gets too tight on device, revisit membership defaults in the defaults sweep
        -- (noted alternative: a gear-anchored controls menu).
        local top_chip_row = {}
        for _idx, chip in ipairs(session_chips) do
            table.insert(top_chip_row, chip)
        end
        table.insert(top_chip_row, send_button)
        local n_controls = #top_chip_row
        local control_font = (n_controls <= 3 and 18) or (n_controls == 4 and 16) or 14
        for _idx, btn in ipairs(top_chip_row) do
            btn.font_size = control_font
        end
        local chip_rows = { top_chip_row }

        -- Action buttons (collected separately, then arranged in rows of 2)
        local action_buttons = {}
        local prompts, prompt_keys
        -- Use per-context ordering for non-general contexts
        local action_service = plugin and plugin.action_service
        if input_context ~= "general" and action_service then
            local ordered_actions = action_service:getInputActionObjects(input_context)
            prompts = {}
            prompt_keys = {}
            for _idx, action in ipairs(ordered_actions) do
                local key = action.id or ("prompt_" .. #prompt_keys + 1)
                prompts[key] = action
                table.insert(prompt_keys, key)
            end
            logger.info("buildInputDialogButtons: Got " .. #prompt_keys .. " prompts from input context: " .. input_context)
        else
            prompts, prompt_keys = getAllPrompts(configuration, plugin)
            logger.info("buildInputDialogButtons: Got " .. #prompt_keys .. " prompts from getAllPrompts")
        end
    -- Pre-compute availability state for button graying (uses outer-scope library_scan_available)
    local selected_book_count = 0
    local avail_features = configuration and configuration.features or {}
    if input_context == "library" then
        local books = avail_features.books_info
        selected_book_count = books and #books or 0
    end

    -- Check if an action's prerequisites are met (for enabled/disabled state)
    -- Only gray out in library context; other contexts rely on _checkRequirements() error messages
    local function isActionAvailable(action)
        if not action then return true end
        if input_context ~= "library" then return true end
        if action.requires_selected_books and selected_book_count < 2 then
            return false
        end
        if action.requires then
            for _idx2, req in ipairs(action.requires) do
                if req == "library" and not library_scan_available then
                    return false
                end
            end
        end
        return true
    end

    for _idx, custom_prompt_type in ipairs(prompt_keys) do
        local prompt = prompts[custom_prompt_type]
        if prompt and prompt.text then
            -- Skip actions with excluded flags (e.g., from X-Ray browser "Chat about this")
            local exclude_flags = exclude_action_flags
            local excluded = false
            if exclude_flags then
                for _idx2, flag in ipairs(exclude_flags) do
                    if prompt[flag] then excluded = true; break end
                end
            end
            if excluded then
                logger.info("Skipping excluded prompt: " .. custom_prompt_type)
            else
                logger.info("Adding button for prompt: " .. custom_prompt_type .. " with text: " .. prompt.text)
                local available = isActionAvailable(prompt)
                table.insert(action_buttons, {
                    text = ActionServiceModule.getActionDisplayText(prompt, (configuration or {}).features, indicator_opts),
                    prompt_type = custom_prompt_type,
                    enabled = available,
                    allow_hold_when_disabled = true,
                    callback = function()
                        executeInputAction(prompt, custom_prompt_type)
                    end,
                    hold_callback = function()
                        if prompt.description then
                            UIManager:show(InfoMessage:new{
                                text = prompt.description,
                            })
                        end
                    end,
                })
            end
        else
            logger.warn("Skipping prompt " .. custom_prompt_type .. " - missing or invalid")
        end
    end

    -- "Show More Actions…" — compute remaining actions and optionally show in-grid button
    if action_service then
        -- Compute "more actions": enabled actions eligible for this context but not in the favorites list
        local shown_set = {}
        for _idx2, key in ipairs(prompt_keys) do shown_set[key] = true end
        local more_actions = {}
        if input_context == "general" then
            local all_general = action_service:getAllActions("general", false, has_open_book)
            for _idx2, action in ipairs(all_general) do
                if action.id and not shown_set[action.id] and action.enabled then
                    table.insert(more_actions, action)
                end
            end
        else
            local eligible_ids = action_service:_getEligibleInputActionIds(input_context)
            for _idx2, id in ipairs(eligible_ids) do
                if not shown_set[id] then
                    local action = action_service:getAction(nil, id)
                    if action and action.enabled then
                        -- Apply exclude_action_flags filter
                        local excluded = false
                        if exclude_action_flags then
                            for _idx3, flag in ipairs(exclude_action_flags) do
                                if action[flag] then excluded = true; break end
                            end
                        end
                        if not excluded then
                            table.insert(more_actions, action)
                        end
                    end
                end
            end
        end

        has_more_actions = #more_actions > 0

        if show_all_actions then
            -- Expanded: append all remaining actions after favorites
            for _idx2, action in ipairs(more_actions) do
                local available = isActionAvailable(action)
                table.insert(action_buttons, {
                    text = ActionServiceModule.getActionDisplayText(action, (configuration or {}).features, indicator_opts),
                    prompt_type = action.id,
                    enabled = available,
                    allow_hold_when_disabled = true,
                    callback = function()
                        executeInputAction(action, action.id)
                    end,
                    hold_callback = function()
                        if action.description then
                            UIManager:show(InfoMessage:new{
                                text = action.description,
                            })
                        end
                    end,
                })
            end
        elseif #more_actions > 0 and input_context ~= "general" then
            -- Collapsed: show in-grid button (non-general only; general uses gear menu toggle)
            table.insert(action_buttons, {
                text = _("Show More Actions…"),
                callback = function()
                    show_all_actions = true
                    refreshInputDialog()
                end,
            })
        end
    end

    -- Build View Artifacts button (shows cached artifacts + pinned)
    -- Always "View Artifacts" text, always shows popup selector with metadata
    local artifact_button = nil
    if not is_general_context and plugin and not hide_artifacts then
        local artifact_file = document_path
        if artifact_file then
            local ActionCache = require("koassistant_action_cache")
            local open_doc = ui_instance and ui_instance.document or nil
            local caches = ActionCache.getAvailableArtifactsWithPinned(artifact_file, nil, open_doc)

            local function openArtifact(cache, on_select)
                if cache.is_section_xray_group then
                    local ArtifactBrowser = require("koassistant_artifact_browser")
                    local AskGPT = plugin
                    ArtifactBrowser:_showSectionXrayGroupPopup(
                        cache.data, artifact_file,
                        book_metadata and book_metadata.title, AskGPT,
                        cache._excluded_section_key, on_select)
                elseif cache.is_section_group then
                    local ArtifactBrowser = require("koassistant_artifact_browser")
                    ArtifactBrowser:_showSectionGroupPopup(
                        cache.data, artifact_file,
                        book_metadata and book_metadata.title, plugin,
                        cache.section_type, cache._excluded_section_key, on_select)
                elseif cache.is_wiki_group then
                    local ArtifactBrowser = require("koassistant_artifact_browser")
                    ArtifactBrowser:_showWikiGroupPopup(cache.data, artifact_file, plugin,
                        book_metadata and book_metadata.title, on_select)
                elseif cache.is_pinned_group then
                    local ArtifactBrowser = require("koassistant_artifact_browser")
                    ArtifactBrowser:_showPinnedGroupPopup(cache.data, artifact_file,
                        book_metadata and book_metadata.title, on_select)
                elseif cache.is_image_group then
                    local ImageBrowser = require("koassistant_image_browser")
                    ImageBrowser.show({ book_file = artifact_file,
                        book_title = book_metadata and book_metadata.title })
                elseif cache.is_xray_versions_group then
                    plugin:_showXrayCheckpointList({ file = artifact_file,
                        book_title = book_metadata and book_metadata.title })
                elseif cache.is_per_action then
                    plugin:viewCachedAction({ text = cache.name }, cache.key, cache.data,
                        { file = artifact_file, book_title = book_metadata and book_metadata.title })
                else
                    plugin:showCacheViewer(cache)
                end
            end

            local function formatDisplayText(cache)
                if cache.is_pinned_group or cache.is_section_group or cache.is_wiki_group
                    or cache.is_image_group or cache.is_xray_versions_group then
                    return cache.name
                end
                return formatArtifactDisplayText(cache)
            end

            if #caches > 0 then
                artifact_button = {
                    text = Constants.getEmojiText("\u{1F4E6}", _("View Artifacts"), enable_emoji),
                    callback = function()
                        -- Don't close input dialog yet — only close when an artifact is selected
                        input_dialog:onCloseKeyboard()
                        local ButtonDialog = require("ui/widget/buttondialog")
                        local btn_rows = {}
                        for _idx, cache in ipairs(caches) do
                            table.insert(btn_rows, {{
                                text = formatDisplayText(cache),
                                callback = function()
                                    if cache.is_section_group or cache.is_wiki_group or cache.is_pinned_group then
                                        local selector = plugin._cache_selector
                                        openArtifact(cache, function()
                                            UIManager:close(selector)
                                            UIManager:close(input_dialog)
                                            if plugin then plugin.current_input_dialog = nil end
                                        end)
                                    else
                                        UIManager:close(plugin._cache_selector)
                                        UIManager:close(input_dialog)
                                        if plugin then plugin.current_input_dialog = nil end
                                        openArtifact(cache)
                                    end
                                end,
                            }})
                        end
                        table.insert(btn_rows, {{
                            text = _("Cancel"),
                            callback = function()
                                UIManager:close(plugin._cache_selector)
                            end,
                        }})
                        plugin._cache_selector = ButtonDialog:new{
                            title = _("View Artifacts"),
                            buttons = btn_rows,
                        }
                        UIManager:show(plugin._cache_selector)
                    end
                }
            end
        end
    end

        -- Helper: lay out buttons in rows of 2
        local function addButtonRows(button_rows, buttons)
            local current_row = {}
            for _idx, button in ipairs(buttons) do
                table.insert(current_row, button)
                if #current_row == 2 then
                    table.insert(button_rows, current_row)
                    current_row = {}
                end
            end
            if #current_row > 0 then
                table.insert(button_rows, current_row)
            end
        end

        -- Organize into rows: chip/control rows first, then action rows of 2
        local button_rows = {}
        local control_row_set = {}
        for _idx, row in ipairs(chip_rows) do
            table.insert(button_rows, row)
            control_row_set[row] = true
        end

        -- Library context: split actions into scan-based and selection-based zones
        if input_context == "library" then
            -- Classify actions
            local scan_buttons = {}
            local selection_buttons = {}
            for _idx, button in ipairs(action_buttons) do
                local action = button.prompt_type and prompts[button.prompt_type]
                local is_scan = action and action.requires
                    and type(action.requires) == "table"
                local scan_req = false
                if is_scan then
                    for _idx2, req in ipairs(action.requires) do
                        if req == "library" then scan_req = true; break end
                    end
                end
                if scan_req then
                    table.insert(scan_buttons, button)
                else
                    table.insert(selection_buttons, button)
                end
            end

            -- Library scan zone: folder button + scan actions
            -- Previously gated by library_toggle_on; now always visible, hideable via gear menu
            local hide_scan = settings_features.hide_library_scan_actions == true
            if not hide_scan then
                local session_state = configuration.features._session_library or {}
                local perm_folders = plugin and plugin.settings and plugin.settings:readSetting("features") or {}
                local perm_folder_list = perm_folders.library_scan_folders or {}
                local adhoc_folders = session_state.adhoc_folders or {}
                local disabled_set = session_state.disabled_folders or {}
                local active_count = 0
                for _idx2, pf in ipairs(perm_folder_list) do
                    if not disabled_set[pf] then active_count = active_count + 1 end
                end
                active_count = active_count + #adhoc_folders
                local total_count = #perm_folder_list + #adhoc_folders
                local library_label
                if total_count == 0 then
                    library_label = _("Library Scan \u{25BE}")
                elseif active_count == total_count then
                    library_label = T(_("Library Scan (%1) \u{25BE}"), total_count)
                else
                    library_label = T(_("Library Scan (%1/%2) \u{25BE}"), active_count, total_count)
                end
                table.insert(button_rows, {{
                    text = library_label,
                    callback = function()
                        if library_toggle_on then
                            showLibraryFolderPopup()
                        else
                            UIManager:show(InfoMessage:new{
                                text = _("To use library scan actions, enable Allow Library Scanning in Settings → Privacy & Data → Library Settings.\n\nIf you don't need these actions, you can hide this section from the gear menu."),
                            })
                        end
                    end,
                }})

                -- Scan-based action rows (grayed out via isActionAvailable when prerequisites not met)
                addButtonRows(button_rows, scan_buttons)
            end

            -- Item selection row (single button, opens popup with view/edit + add presets)
            local books = configuration and configuration.features and configuration.features.books_info
            local book_count = books and #books or 0
            local items_label
            if book_count == 0 then
                items_label = _("Items \u{25BE}")
            else
                items_label = T(_("Items (%1) \u{25BE}"), book_count)
            end
            table.insert(button_rows, {{
                text = items_label,
                callback = function()
                    showAddBooksMenu()
                end,
            }})

            -- Selection-based action rows
            addButtonRows(button_rows, selection_buttons)

            -- Artifact button
            if artifact_button then
                table.insert(button_rows, { artifact_button })
            end
        else
            -- Non-library contexts: flat layout
            addButtonRows(button_rows, action_buttons)

            -- Artifact pairing: pair with last action if odd count, else solo row
            if artifact_button then
                local last_row = button_rows[#button_rows]
                if last_row and #last_row == 1 and not control_row_set[last_row] then
                    -- Odd action count: pair last action with artifact
                    table.insert(last_row, artifact_button)
                else
                    table.insert(button_rows, { artifact_button })
                end
            end
        end

        -- Non-bold buttons for lighter visual feel
        for _ri, btn_row in ipairs(button_rows) do
            for _bi, btn in ipairs(btn_row) do
                btn.font_bold = false
            end
        end

        return button_rows
    end

    -- Refresh dialog by close-and-reopen (reinit loses title bar X and causes visual glitches)
    refreshInputDialog = function()
        if not input_dialog then return end
        local current_text = input_dialog:getInputText()
        UIManager:close(input_dialog)
        if plugin then plugin.current_input_dialog = nil end
        -- Re-set transient flags for the reopen
        if configuration and configuration.features then
            if is_xray_chat then configuration.features._xray_chat_context = true end
            if hide_artifacts then configuration.features._hide_artifacts = true end
            if exclude_action_flags then configuration.features._exclude_action_flags = exclude_action_flags end
            if xray_context_prefix then configuration.features._xray_context_prefix = xray_context_prefix end
            if show_all_actions then configuration.features._show_all_actions = true end
            if session_spoiler_free then configuration.features._session_spoiler_free = true end
            -- Preserve false too (unlike spoiler): an explicit uncheck must survive the
            -- refresh even when the global tools flag would re-default it to checked.
            if session_book_tools ~= nil then configuration.features._session_book_tools = session_book_tools end
            -- Web: same explicit-false preservation as tools.
            if session_web_search ~= nil then configuration.features._session_web_search = session_web_search end
            -- Scope-chip state is config-resident; this marker keeps it across the reopen
            -- (a fresh open clears it — see the consume block at the dialog top).
            configuration.features._session_keep_scope = true
            -- (The pre-extracted selection window survives the reopen by itself — it
            -- lives on configuration.features until consumed at dispatch/Send.)
        end
        showChatGPTDialog(ui_instance, highlighted_text, configuration, nil, plugin, book_metadata, current_text)
    end

    -- "Toolbar Buttons…" manager (gear menu): toggle which session chips appear above
    -- the input field. Membership persists in features.session_chips; the canonical
    -- order is fixed (SESSION_CHIP_IDS) — only membership is configurable. Stays open
    -- for multiple toggles; the input dialog refreshes once, when the manager closes.
    local showSessionChipsManager
    showSessionChipsManager = function(changed)
        local labels = {
            domain = _("Domain"),
            web_search = _("Web search"),
            book_tools = _("Book tools"),
            quick = _("Quick controls"),
            spoiler = _("Spoiler-free chat"),
            scope = _("Scope & context"),
            attach = _("Attach"),
        }
        -- Membership is GLOBAL (any view can edit it), but chips with a
        -- structural hide won't appear in THIS view — say so instead of
        -- offering a toggle that seems to do nothing (maintainer 2026-07-17).
        -- Keep these conditions in sync with the chip_defs visibility guards.
        local mf = (configuration and configuration.features) or {}
        local m_book_or_hl = not mf.is_general_context and not mf.is_library_context
        local m_has_book = ui_instance and ui_instance.document ~= nil
        local applicable = {
            domain = true,
            web_search = true,
            quick = true,
            attach = true,
            book_tools = (m_book_or_hl and m_has_book) or false,
            scope = (m_book_or_hl and m_has_book and not mf._xray_chat_context) or false,
            spoiler = m_book_or_hl,
        }
        local enabled = {}
        for _idx, id in ipairs(getSessionChips(configuration and configuration.features)) do
            enabled[id] = true
        end
        local manager
        local rows = {}
        for _idx, id in ipairs(SESSION_CHIP_IDS) do
            table.insert(rows, {{
                text = (enabled[id] and "● " or "○ ") .. labels[id]
                    .. (applicable[id] and "" or (" " .. _("(not in this view)"))),
                callback = function()
                    if enabled[id] then enabled[id] = nil else enabled[id] = true end
                    local new_list = {}
                    for _j, cid in ipairs(SESSION_CHIP_IDS) do
                        if enabled[cid] then table.insert(new_list, cid) end
                    end
                    if configuration and configuration.features then
                        configuration.features.session_chips = new_list
                    end
                    if plugin and plugin.settings then
                        local f = plugin.settings:readSetting("features") or {}
                        f.session_chips = new_list
                        plugin.settings:saveSetting("features", f)
                        plugin.settings:flush()
                    end
                    -- Stay open: reopen with fresh ●/○ marks, defer the dialog refresh
                    UIManager:close(manager)
                    showSessionChipsManager(true)
                end,
            }})
        end
        table.insert(rows, {{ text = _("Close"), id = "close", callback = function()
            UIManager:close(manager)
            if changed then refreshInputDialog() end
        end }})
        manager = ButtonDialog:new{
            title = _("Toolbar buttons"),
            buttons = rows,
            tap_close_callback = function()
                -- Tap-outside dismiss counts as Close
                if changed then refreshInputDialog() end
            end,
        }
        UIManager:show(manager)
    end

    -- Show the dialog with the button rows
    local is_multi = config and config.features and config.features.is_library_context
    local multi_count = is_multi and config.features.books_info and #config.features.books_info or 0
    local has_scan = library_toggle_on and (has_session_scan or has_permanent_folders)
    local dialog_title
    local input_hint_text

    -- Rolling context-sensitive hint suggestions
    local function pickHint(hints)
        return hints[(os.time() % #hints) + 1]
    end

    if is_multi then
        if has_scan and multi_count > 0 then
            dialog_title = T(multi_count == 1 and _("Library Chat/Action \xC2\xB7 %1 item") or _("Library Chat/Action \xC2\xB7 %1 items"), multi_count)
            input_hint_text = pickHint({
                _("Chat about your library and selected items..."),
                _("\"Something exciting to read next\""),
                _("\"How do these books connect?\""),
                _("\"A short, light book from my library\""),
            })
        elseif has_scan then
            dialog_title = _("Library Chat/Action")
            input_hint_text = pickHint({
                _("Chat about your library..."),
                _("\"What should I read next?\""),
                _("\"What are my reading blind spots?\""),
                _("\"A book I've been neglecting\""),
            })
        elseif multi_count > 0 then
            dialog_title = T(multi_count == 1 and _("Library Chat/Action \xC2\xB7 %1 item") or _("Library Chat/Action \xC2\xB7 %1 items"), multi_count)
            input_hint_text = pickHint({
                _("Chat about your selected items..."),
                _("\"How do these books connect?\""),
                _("\"Which should I read first?\""),
                _("\"What's unique about each one?\""),
            })
        elseif library_toggle_on then
            -- Toggle on but no folders configured yet
            dialog_title = _("Library Chat/Action")
            input_hint_text = _("Add library scan folders or items to run any action...")
        else
            -- Toggle off
            dialog_title = _("Library Chat/Action")
            input_hint_text = _("Add items to chat about them or run any action...")
        end
    else
        dialog_title = _("KOAssistant Actions")
        -- Rolling hints — a fresh pick per dialog open (the hint is the input
        -- field's placeholder; it cannot change while the dialog is up). The
        -- empty-input-Send hint is gated on the HIGHLIGHT input context, not on
        -- highlighted_text (book launches can carry a text payload too —
        -- maintainer 2026-07-19); book/general empty Send stays blocked by the
        -- Send guard, so the hint would be wrong there.
        local hints = {
            _("Type your question or additional instructions for any action..."),
            _("Tip: long-press toolbar buttons for their settings, action buttons for descriptions..."),
        }
        if input_context == "highlight" then
            -- Empty-input Send is first-class on a highlight — "talk about this"
            -- (controls_parity_plan.md §9.3): lead the rotation with it.
            table.insert(hints, 1, _("Just tap Send to discuss the highlighted text, or type a question..."))
        end
        input_hint_text = pickHint(hints)
    end
    input_dialog = InputDialog:new{
        title = dialog_title,
        input = initial_input or "",
        input_hint = input_hint_text,
        input_type = "text",
        buttons = buildInputDialogButtons(),
        allow_newline = true,
        input_multiline = true,
        -- ~3 lines, scaled by screen size (like fonts) so the box holds a
        -- consistent line-count across e-readers / phones / desktop.
        -- (Was a raw, unscaled 300px — device-inconsistent and oversized.)
        text_height = Screen:scaleBySize(96),
        -- Settings icon in title bar — opens anchored gear menu
        title_bar_left_icon = "appbar.settings",
        title_bar_left_icon_tap_callback = function()
            input_dialog:onCloseKeyboard()
            local gear_menu
            local gear_buttons = {
                {{ text = _("Quick Settings"), callback = function()
                    UIManager:close(gear_menu)
                    if plugin then
                        plugin:onKOAssistantAISettings(function()
                            plugin:updateConfigFromSettings()
                            refreshInputDialog()
                        end)
                    end
                end }},
                {{ text = _("Choose and Sort Actions…"), callback = function()
                    UIManager:close(gear_menu)
                    if not plugin then return end
                    local PromptsManager = require("koassistant_ui/prompts_manager")
                    PromptsManager:new(plugin):showInputActionsManager(input_context, function()
                        -- Defer refresh to next tick so sorting manager is fully removed first
                        UIManager:nextTick(function()
                            refreshInputDialog()
                        end)
                    end)
                end }},
                {{ text = show_all_actions and _("Show Fewer Actions") or _("Show More Actions…"),
                    enabled = show_all_actions or has_more_actions,
                    callback = function()
                    UIManager:close(gear_menu)
                    show_all_actions = not show_all_actions
                    refreshInputDialog()
                end }},
            }
            -- Toolbar buttons manager: which session chips appear above the input field
            table.insert(gear_buttons, {{ text = _("Toolbar Buttons…"), callback = function()
                UIManager:close(gear_menu)
                showSessionChipsManager()
            end }})
            -- Book Settings entry — only when a book is in scope (book/highlight contexts)
            if document_path then
                table.insert(gear_buttons, {{ text = _("Book Settings"), callback = function()
                    UIManager:close(gear_menu)
                    BookSettings.show({
                        plugin = plugin,
                        ui = ui_instance,
                        document_path = document_path,
                        on_close = function() refreshInputDialog() end,
                    })
                end }})
            end
            -- Library context: toggle to hide/show library scan actions
            if input_context == "library" then
                local cur_features = plugin and plugin.settings and plugin.settings:readSetting("features") or {}
                local is_hidden = cur_features.hide_library_scan_actions == true
                table.insert(gear_buttons, {{ text = is_hidden and _("Show Library Scan Actions") or _("Hide Library Scan Actions"),
                    callback = function()
                    UIManager:close(gear_menu)
                    if plugin and plugin.settings then
                        local f = plugin.settings:readSetting("features") or {}
                        f.hide_library_scan_actions = f.hide_library_scan_actions ~= true
                        plugin.settings:saveSetting("features", f)
                        plugin.settings:flush()
                        refreshInputDialog()
                    end
                end }})
            end
            gear_menu = ButtonDialog:new{
                buttons = gear_buttons,
                shrink_unneeded_width = true,
                anchor = function()
                    return input_dialog.title_bar.left_button.image.dimen, true
                end,
            }
            UIManager:show(gear_menu)
        end,
    }

    -- (The old spoiler-free / book-tools checkboxes were replaced by the session chips
    -- row built in buildInputDialogButtons — book_scoped_controls_plan.md §4.)

    -- Add close X to title bar (InputDialog doesn't natively pass close_callback to TitleBar)
    -- Also use regular weight font for title (default x_smalltfont is NotoSans-Bold)
    local Font = require("ui/font")
    input_dialog.title_bar.close_callback = function()
        UIManager:close(input_dialog)
        if plugin then
            plugin.current_input_dialog = nil
            plugin._session_scan_folders = nil
        end
        if configuration and configuration.features then
            configuration.features._session_library = nil
        end
    end
    input_dialog.title_bar.title_face = Font:getFace("smallinfofont")
    input_dialog.title_bar:init()

    -- Lighter input field border (default is COLOR_DARK_GRAY; use mid-gray for subtlety)
    local Blitbuffer = require("ffi/blitbuffer")
    input_dialog._input_widget._frame_textwidget.color = Blitbuffer.COLOR_GRAY

    -- Enable tap-outside-to-close (InputDialog's onCloseDialog looks for id="close" button
    -- which we removed; override to close directly)
    input_dialog.onCloseDialog = function()
        UIManager:close(input_dialog)
        if plugin then
            plugin.current_input_dialog = nil
            plugin._session_scan_folders = nil
        end
        if configuration and configuration.features then
            configuration.features._session_library = nil
        end
        return true
    end

    -- Rotation support via in-place refresh (no close-and-reopen gap)
    input_dialog.onScreenResize = function(self, dimen)
        refreshInputDialog()
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
            for _idx, row in ipairs(input_dialog.buttons or {}) do
                for _idx2, button in ipairs(row) do
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

-- Calculate current reading progress as a decimal (0.0-1.0) directly from the document
-- Lightweight alternative to ContextExtractor:getReadingProgress() for quick checks
local function getProgressDecimal(ui)
    if not ui or not ui.document then return nil end
    local total_pages = ui.document.info and ui.document.info.number_of_pages or 0
    if total_pages == 0 then return nil end
    local current_page
    if ui.document.info.has_pages then
        current_page = ui.view and ui.view.state and ui.view.state.page or 1
    else
        local xp = ui.document:getXPointer()
        current_page = xp and ui.document:getPageFromXPointer(xp) or 1
    end
    -- Flow-aware progress when hidden flows active
    if ui.document.hasHiddenFlows and ui.document:hasHiddenFlows() then
        local visible_at_or_before = 0
        local total_visible = 0
        for page = 1, total_pages do
            if ui.document:getPageFlow(page) == 0 then
                total_visible = total_visible + 1
                if page <= current_page then
                    visible_at_or_before = visible_at_or_before + 1
                end
            end
        end
        if total_visible > 0 then
            return visible_at_or_before / total_visible
        end
    end
    return current_page / total_pages
end

-- Open X-Ray browser with cached data and metadata
-- Returns the XrayBrowser module for chaining (e.g., showItemDetail, showSearchResults)
local function openXrayBrowserFromCache(ui, data, cached, config, plugin, book_metadata, best, cleanup_widgets)
    local XrayBrowser = require("koassistant_xray_browser")
    local ActionCache = require("koassistant_action_cache")
    local Notification = require("ui/widget/notification")
    local config_features = (config or {}).features or {}

    local book_title = (book_metadata and book_metadata.title) or ""
    local source_label = cached.used_book_text == false
        and _("Based on AI training data knowledge")
        or _("Based on extracted document text")
    local formatted_date = cached.timestamp
        and os.date("%Y-%m-%d", cached.timestamp)

    local browser_metadata = {
        title = book_title,
        progress = cached.progress_decimal and
            (math.floor(cached.progress_decimal * 100 + 0.5) .. "%"),
        model = cached.model,
        timestamp = cached.timestamp,
        book_file = ui and ui.document and ui.document.file,
        enable_emoji = config_features.enable_emoji_icons == true,
        configuration = config,
        plugin = plugin,
        source_label = source_label,
        formatted_date = formatted_date,
        progress_decimal = cached.progress_decimal,
        full_document = cached.full_document,
        previous_progress = cached.previous_progress_decimal and
            (math.floor(cached.previous_progress_decimal * 100 + 0.5) .. "%"),
        cache_metadata = {
            cache_type = "xray",
            book_title = book_title,
            progress_decimal = cached.progress_decimal,
            model = cached.model,
            timestamp = cached.timestamp,
            used_annotations = cached.used_annotations,
            used_book_text = cached.used_book_text,
        },
    }

    -- Section X-Ray: set scope metadata and override progress display
    if best and best.is_section then
        local scope_start = cached.scope_start_page
        local scope_end = cached.scope_end_page
        local scope_summary = cached.scope_page_summary
        -- Reconvert XPointers to current pages if book is open
        local doc = ui and ui.document
        if doc and doc.getPageFromXPointer and cached.scope_start_xpointer then
            local new_start = doc:getPageFromXPointer(cached.scope_start_xpointer)
            if new_start then scope_start = new_start end
            if cached.scope_end_xpointer then
                local new_end = doc:getPageFromXPointer(cached.scope_end_xpointer)
                if new_end then scope_end = new_end - 1 end
            else
                local total = doc.info.number_of_pages or 0
                if doc.hasHiddenFlows and doc:hasHiddenFlows() then
                    for page = total, 1, -1 do
                        if doc:getPageFlow(page) == 0 then scope_end = page; break end
                    end
                else
                    scope_end = total
                end
            end
            local vis_start = doc.getPageNumberInFlow and doc:getPageNumberInFlow(scope_start) or scope_start
            local vis_end = doc.getPageNumberInFlow and doc:getPageNumberInFlow(scope_end) or scope_end
            scope_summary = T(_("pp %1–%2"), vis_start, vis_end)
        end
        browser_metadata.scope = {
            label = best.label or cached.scope_label,
            start_page = scope_start,
            end_page = scope_end,
            page_summary = scope_summary,
            cache_key = best.key,
        }
        browser_metadata.progress = _("Complete")
        browser_metadata.full_document = true
    end

    -- Pass cleanup widgets so browser can close them when launching book text search
    browser_metadata._cleanup_widgets = cleanup_widgets

    XrayBrowser:show(data, browser_metadata, ui, function()
        -- Clear all three homes like main.lua's on_delete: doc-level key, the per-action
        -- "xray" entry (update eligibility reads it), and derived wiki entries. A
        -- doc-key-only clear leaves a live per-action entry that background auto-update
        -- would resurrect from.
        ActionCache.clearXrayCache(ui.document.file)
        ActionCache.clear(ui.document.file, "xray")
        ActionCache.clearWikiEntries(ui.document.file)
        ActionCache.clearXrayCheckpoints(ui.document.file)
        UIManager:show(Notification:new{
            text = T(_("%1 deleted"), "X-Ray"),
            timeout = 2,
        })
    end)
    return XrayBrowser
end

-- Show cross-section X-Ray search results as a standalone picker Menu.
-- @param grouped_results table From ActionCache.searchAllXrays()
-- @param query string The search query
-- @param ui table UI context
-- @param config table Configuration
-- @param plugin table Plugin reference
-- @param book_metadata table Book metadata
local function showCrossSectionResults(grouped_results, query, ui, config, plugin, book_metadata, cleanup_widgets)
    local Menu = require("ui/widget/menu")
    local XrayParser = require("koassistant_xray_parser")

    -- Count total results across all X-Rays
    local total_results = 0
    for _idx, group in ipairs(grouped_results) do
        total_results = total_results + #group.results
    end

    local items = {}
    for _idx, group in ipairs(grouped_results) do
        -- Section header (non-tappable separator)
        local header_label
        if not group.is_section then
            header_label = _("Main X-Ray")
        else
            header_label = group.label or ""
            if group.scope_summary and group.scope_summary ~= "" then
                header_label = header_label .. " (" .. group.scope_summary .. ")"
            end
        end
        if group.in_range then
            header_label = "▸ " .. header_label
        end
        table.insert(items, {
            text = header_label,
            bold = true,
            dim = false,
            separator = true,
            callback = function() end, -- non-tappable but needs callback for Menu
        })

        -- Result items under this section
        for _idx2, result in ipairs(group.results) do
            local item_name = XrayParser.getItemName(result.item, result.category_key)
            local match_label = result.category_label
            if result.match_field == "alias" then
                match_label = match_label .. " (" .. _("alias") .. ")"
            elseif result.match_field == "description" then
                match_label = match_label .. " (" .. _("desc.") .. ")"
            end

            local captured_group = group
            local captured_result = result
            local captured_name = item_name
            table.insert(items, {
                text = "  " .. item_name,
                mandatory = match_label,
                mandatory_dim = true,
                callback = function()
                    -- Open that section's X-Ray browser at this item
                    local best = {
                        entry = captured_group.cache_entry,
                        key = captured_group.key,
                        is_section = captured_group.is_section,
                        label = captured_group.label,
                    }
                    local data = XrayParser.parse(captured_group.cache_entry.result)
                    if not data then return end
                    local XrayBrowser = openXrayBrowserFromCache(
                        ui, data, captured_group.cache_entry, config, plugin, book_metadata, best,
                        cleanup_widgets)
                    XrayBrowser:showItemDetail(
                        captured_result.item, captured_result.category_key, captured_name)
                end,
            })
        end
    end

    local title = T(_("Results for \"%1\" (%2 across %3)"),
        query, total_results, #grouped_results)

    local results_menu = Menu:new{
        title = title,
        item_table = items,
        is_borderless = true,
        is_popout = false,
        width = Screen:getWidth(),
        height = Screen:getHeight(),
        single_line = true,
        items_font_size = 18,
        items_mandatory_font_size = 14,
        -- No close_callback (Menu calls it after EVERY item tap, not just X button)
        -- No onReturn (hides the return arrow; X button works via Menu's default onClose)
    }

    -- Add results menu to cleanup list so browser can close it during book text search
    if cleanup_widgets then
        table.insert(cleanup_widgets, results_menu)
    end

    UIManager:show(results_menu)
end

-- Handle local X-Ray lookup: search cached X-Ray data for the query
-- @param override_best table|nil Pre-selected X-Ray result (from selection popup callback)
local function handleLocalXrayLookup(ui, query, document_path, book_metadata, config, plugin, override_best)
    local logger = require("logger")
    logger.info("KOAssistant: Local X-Ray lookup for: " .. tostring(query))

    if not document_path then
        UIManager:show(InfoMessage:new{
            text = _("No book open. X-Ray lookup requires an open book."),
            timeout = 3,
        })
        return
    end

    local ActionCache = require("koassistant_action_cache")
    local doc = ui and ui.document

    -- Build cleanup list: widgets to close when browser launches book text search.
    -- Prevents dictionary popup and cross-section results from blocking search highlights.
    local cleanup_widgets = {}
    local source_widget = config and config.features and config.features._source_widget
    if source_widget then
        table.insert(cleanup_widgets, source_widget)
    end

    -- Cross-section search: when multiple X-Rays exist and no override, search all
    if not override_best then
        local sections = ActionCache.getSectionXrays(document_path)
        local main = ActionCache.getXrayCache(document_path)
        local total_xrays = #sections + (main and main.result and 1 or 0)

        if total_xrays == 0 then
            UIManager:show(InfoMessage:new{
                text = _("No X-Ray cache found for this book. Generate one first via the X-Ray action."),
                timeout = 4,
            })
            return
        end

        if total_xrays > 1 then
            -- Multiple X-Rays: search across all (name + alias only for lookup)
            local grouped = ActionCache.searchAllXrays(document_path, query, doc, { skip_description = true })
            if #grouped == 0 then
                -- No results anywhere
                UIManager:show(InfoMessage:new{
                    text = T(_("No results for \"%1\" across %2 X-Rays."), query, total_xrays),
                    timeout = 5,
                })
                return
            elseif #grouped == 1 then
                -- Results in only 1 X-Ray: use standard single-X-Ray flow
                override_best = {
                    entry = grouped[1].cache_entry,
                    key = grouped[1].key,
                    is_section = grouped[1].is_section,
                    label = grouped[1].label,
                }
                -- Fall through to existing single-X-Ray handling below
            else
                -- Results in multiple X-Rays: show cross-section results
                showCrossSectionResults(grouped, query, ui, config, plugin, book_metadata, cleanup_widgets)
                return
            end
        end
    end

    -- Find best X-Ray: prefer section covering current page, fall back to main
    local best = override_best or ActionCache.findBestXray(document_path, doc)

    if not best then
        UIManager:show(InfoMessage:new{
            text = _("No X-Ray cache found for this book. Generate one first via the X-Ray action."),
            timeout = 4,
        })
        return
    end

    -- Multiple sections available: let user pick which one to search
    if best.needs_selection then
        local ButtonDialog = require("ui/widget/buttondialog")
        local sec_selector
        local btn_rows = {}
        for _idx, sec in ipairs(best.sections) do
            local page_info = ActionCache.reconvertPageSummary(sec.data, doc)
            local label = sec.label
            if page_info ~= "" then
                label = label .. " (" .. page_info .. ")"
            end
            local captured_sec = sec
            table.insert(btn_rows, {{
                text = label,
                callback = function()
                    UIManager:close(sec_selector)
                    handleLocalXrayLookup(ui, query, document_path, book_metadata, config, plugin,
                        { entry = captured_sec.data, key = captured_sec.key, is_section = true, label = captured_sec.label })
                end,
            }})
        end
        sec_selector = ButtonDialog:new{
            title = T(_("Look up \"%1\" in which X-Ray?"), query),
            buttons = btn_rows,
        }
        UIManager:show(sec_selector)
        return
    end

    local cached = best.entry

    -- Parse the cached JSON
    local XrayParser = require("koassistant_xray_parser")
    local data = XrayParser.parse(cached.result)

    if not data then
        UIManager:show(InfoMessage:new{
            text = _("Could not parse X-Ray data. Try regenerating the X-Ray cache."),
            timeout = 3,
        })
        return
    end

    -- Search name + alias only (description matches are noise for dictionary lookup)
    local results = XrayParser.searchAll(data, query, { skip_description = true })

    -- Calculate progress gap (only for main X-Ray; sections cover fixed ranges)
    local current_progress = getProgressDecimal(ui)
    local cache_progress = cached.progress_decimal
    local progress_gap = nil
    if not best.is_section and current_progress and cache_progress then
        progress_gap = current_progress - cache_progress
    end

    if #results == 0 then
        -- No results
        local msg = T(_("No results for \"%1\" in X-Ray."), query)
        if best.is_section and best.label then
            msg = T(_("No results for \"%1\" in Section X-Ray: %2."), query, best.label)
        end
        if progress_gap and progress_gap > 0.08 then
            local cache_pct = math.floor(cache_progress * 100 + 0.5)
            local current_pct = math.floor(current_progress * 100 + 0.5)
            msg = msg .. "\n\n" .. T(_("X-Ray covers to %1% (you're at %2%). Updating may find this entry."), cache_pct, current_pct)
        end
        UIManager:show(InfoMessage:new{
            text = msg,
            timeout = 5,
        })
    else
        -- Open X-Ray browser directly
        local XrayBrowser = openXrayBrowserFromCache(ui, data, cached, config, plugin, book_metadata, best,
            #cleanup_widgets > 0 and cleanup_widgets or nil)

        if #results == 1 then
            -- Single result: navigate directly to item detail
            local result = results[1]
            local name = XrayParser.getItemName(result.item, result.category_key)
            XrayBrowser:showItemDetail(result.item, result.category_key, name)
        else
            -- Multiple results: show search results in browser
            -- Skip "Search other X-Rays" button — cross-section search already ran
            XrayBrowser:showSearchResults(query, true)
        end

        -- Show progress staleness popup (main X-Ray only; sections cover fixed ranges)
        if not best.is_section then
            local book_file = ui.document and ui.document.file
            local dismissed = book_file and plugin._xray_stale_dismissed
                and plugin._xray_stale_dismissed[book_file] == cache_progress
            if not dismissed and progress_gap and progress_gap > 0.08 and plugin then
                local ButtonDialog = require("ui/widget/buttondialog")
                local cache_pct = math.floor(cache_progress * 100 + 0.5)
                local ContextExtractor = require("koassistant_context_extractor")
                local extractor = ContextExtractor:new(ui)
                local current = extractor:getReadingProgress()
                local info_text = T(_("X-Ray covers to %1%"), cache_pct)
                info_text = info_text .. "\n" .. T(_("You're now at %1%."), current.percent)

                local stale_dialog
                stale_dialog = ButtonDialog:new{
                    title = info_text,
                    buttons = {
                        {{
                            text = T(_("Update X-Ray (to %1)"), current.formatted),
                            callback = function()
                                UIManager:close(stale_dialog)
                                if XrayBrowser.menu then
                                    UIManager:close(XrayBrowser.menu)
                                end
                                local action = plugin.action_service:getAction("book", "xray")
                                if action then
                                    if plugin:_checkRequirements(action) then return end
                                    plugin:_executeBookLevelActionDirect(action, "xray")
                                end
                            end,
                        }},
                        {{
                            text = _("Don't remind me this session"),
                            callback = function()
                                UIManager:close(stale_dialog)
                                if not plugin._xray_stale_dismissed then
                                    plugin._xray_stale_dismissed = {}
                                end
                                plugin._xray_stale_dismissed[book_file] = cache_progress
                            end,
                        }},
                    },
                }
                UIManager:show(stale_dialog)
            end
        end
    end
end

-- Dispatch a local (non-AI) action handler
local function handleLocalAction(handler_name, ui, highlighted_text, document_path, book_metadata, config, plugin)
    local logger = require("logger")

    if handler_name == "xray_lookup" then
        handleLocalXrayLookup(ui, highlighted_text, document_path, book_metadata, config, plugin)
    else
        logger.warn("KOAssistant: Unknown local handler: " .. tostring(handler_name))
        UIManager:show(InfoMessage:new{
            text = _("Unknown local action handler"),
            timeout = 2,
        })
    end
end

-- Forward declaration (assigned below executeDirectAction; used by wiki artifact intercept)
local executeActionForResult

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
        local props = ui.doc_props or {}
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

        -- Use KOReader's merged metadata (includes user edits), filename as fallback
        local title = props.display_title or props.title
        local author = props.authors
        -- Normalize multi-author strings (KOReader stores as newline-separated)
        if author and author:find("\n") then
            author = author:gsub("\n", ", ")
        end
        book_metadata = {
            title = (title and title ~= "") and title or filename_fallback or "Unknown",
            author = (author and author ~= "") and author or ""  -- Empty, not "Unknown" - less confusing for AI
        }
    end

    -- Fallback for file browser actions: no open document but book metadata has file path
    local cfg_metadata = configuration and configuration.features and configuration.features.book_metadata
    if not document_path and cfg_metadata and cfg_metadata.file then
        document_path = cfg_metadata.file
    end
    if not book_metadata and cfg_metadata then
        book_metadata = {
            title = cfg_metadata.title or "Unknown",
            author = cfg_metadata.author or "",
        }
    end

    -- Apply per-book AI title/author override to what the AI sees (never library metadata)
    if book_metadata then
        local override_ds
        if document_path then
            override_ds = SafeDocSettings.resolve(document_path, ui)
        end
        book_metadata = require("koassistant_book_settings").applyMetadataOverride(book_metadata, override_ds)
    end

    -- Handle local-only actions (no AI call)
    if action.local_handler then
        handleLocalAction(action.local_handler, ui, highlighted_text, document_path, book_metadata, configuration, plugin)
        return
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
            -- For Section X-Ray: open browser directly from section cache
            if configuration and configuration.features and configuration.features._section_xray and ui and ui.document and ui.document.file then
                local ActionCache = require("koassistant_action_cache")
                local scope = configuration.features._section_xray
                local section_cache = ActionCache.get(ui.document.file, scope.cache_key)
                if section_cache and section_cache.result then
                    local XrayParser = require("koassistant_xray_parser")
                    local parsed = XrayParser.parse(section_cache.result)
                    if parsed then
                        local XrayBrowser = require("koassistant_xray_browser")
                        local book_title = (book_metadata and book_metadata.title) or ""
                        local Notification = require("ui/widget/notification")
                        local config_features = (configuration or CONFIGURATION or {}).features or {}
                        local source_label = section_cache.used_book_text == false
                            and _("Based on AI training data knowledge")
                            or _("Based on extracted document text")
                        local formatted_date = section_cache.timestamp
                            and (os.date("%Y-%m-%d", section_cache.timestamp) .. " (" .. _("today") .. ")")
                        XrayBrowser:show(parsed, {
                            title = book_title,
                            progress = "Complete",
                            model = section_cache.model,
                            timestamp = section_cache.timestamp,
                            book_file = ui.document.file,
                            enable_emoji = config_features.enable_emoji_icons == true,
                            configuration = configuration,
                            plugin = plugin,
                            source_label = source_label,
                            formatted_date = formatted_date,
                            progress_decimal = 1.0,
                            full_document = true,
                            used_reasoning = section_cache.used_reasoning,
                            web_search_used = section_cache.web_search_used,
                            scope = {
                                label = scope.label,
                                start_page = scope.start_page,
                                end_page = scope.end_page,
                                page_summary = scope.page_summary,
                                cache_key = scope.cache_key,
                            },
                            cache_metadata = {
                                cache_type = "xray",
                                book_title = book_title,
                                progress_decimal = 1.0,
                                model = section_cache.model,
                                timestamp = section_cache.timestamp,
                                used_book_text = section_cache.used_book_text,
                            },
                        }, ui, function()
                            ActionCache.clear(ui.document.file, scope.cache_key)
                            UIManager:show(Notification:new{
                                text = T(_("Section X-Ray '%1' deleted"), scope.label),
                                timeout = 2,
                            })
                        end)
                        return
                    end
                end
            end
            -- For generic section actions: open in simple viewer from section cache
            -- (skip interactive_quiz — has its own routing below that handles section cache keys)
            if not action.interactive_quiz and configuration and configuration.features and configuration.features._section_scope and plugin then
                local ActionCache = require("koassistant_action_cache")
                local scope = configuration.features._section_scope
                local file = ui and ui.document and ui.document.file or document_path
                if scope.cache_key and file then
                    local section_cache = ActionCache.get(file, scope.cache_key)
                    if section_cache and section_cache.result then
                        plugin:viewCachedAction(action, action.id, section_cache, {
                            file = file,
                            section_key = scope.cache_key,
                            section_label = scope.label,
                            book_title = book_metadata and book_metadata.title,
                            book_author = book_metadata and book_metadata.author,
                        })
                        return
                    end
                end
            end
            -- For X-Ray: open browser directly instead of chat viewer
            -- The result is already saved to the X-Ray cache; the chat viewer is unnecessary
            if action.cache_as_xray and ui and ui.document and ui.document.file then
                local ActionCache = require("koassistant_action_cache")
                local xray_cache = ActionCache.getXrayCache(ui.document.file)
                if xray_cache and xray_cache.result then
                    local XrayParser = require("koassistant_xray_parser")
                    local parsed = XrayParser.parse(xray_cache.result)
                    if parsed then
                        local XrayBrowser = require("koassistant_xray_browser")
                        local book_title = (book_metadata and book_metadata.title) or ""
                        local Notification = require("ui/widget/notification")
                        local config_features = (configuration or CONFIGURATION or {}).features or {}
                        local source_label = xray_cache.used_book_text == false
                            and _("Based on AI training data knowledge")
                            or _("Based on extracted document text")
                        local formatted_date = xray_cache.timestamp
                            and (os.date("%Y-%m-%d", xray_cache.timestamp) .. " (" .. _("today") .. ")")
                        XrayBrowser:show(parsed, {
                            title = book_title,
                            progress = xray_cache.progress_decimal and
                                (math.floor(xray_cache.progress_decimal * 100 + 0.5) .. "%"),
                            model = xray_cache.model,
                            timestamp = xray_cache.timestamp,
                            book_file = ui.document.file,
                            enable_emoji = config_features.enable_emoji_icons == true,
                            configuration = configuration,
                            plugin = plugin,
                            source_label = source_label,
                            formatted_date = formatted_date,
                            progress_decimal = xray_cache.progress_decimal,
                            full_document = xray_cache.full_document,
                            previous_progress = xray_cache.previous_progress_decimal and
                                (math.floor(xray_cache.previous_progress_decimal * 100 + 0.5) .. "%"),
                            cache_metadata = {
                                cache_type = "xray",
                                book_title = book_title,
                                progress_decimal = xray_cache.progress_decimal,
                                model = xray_cache.model,
                                timestamp = xray_cache.timestamp,
                                used_annotations = xray_cache.used_annotations,
                                used_book_text = xray_cache.used_book_text,
                            },
                        }, ui, function()
                            -- Same triple clear as main.lua's on_delete (see the other
                            -- XrayBrowser:show delete callback above).
                            ActionCache.clearXrayCache(ui.document.file)
                            ActionCache.clear(ui.document.file, "xray")
                            ActionCache.clearWikiEntries(ui.document.file)
                            ActionCache.clearXrayCheckpoints(ui.document.file)
                            UIManager:show(Notification:new{
                                text = T(_("%1 deleted"), "X-Ray"),
                                timeout = 2,
                            })
                        end)
                        return
                    end
                end
            end

            -- For interactive quiz: parse JSON and open quiz viewer
            if action.interactive_quiz then
                local messages = history:getMessages()
                local last_msg = messages[#messages]
                local result_text = last_msg and last_msg.content or ""
                local QuizParser = require("koassistant_quiz_parser")
                local parsed = QuizParser.parse(result_text)
                if parsed and parsed.questions and #parsed.questions > 0 then
                    local QuizViewer = require("koassistant_quiz_viewer")
                    local quiz_title = book_metadata and book_metadata.title or ""
                    local chapter_title = configuration and configuration.features
                        and configuration.features._chapter_quiz_title
                    local quiz_file = ui and ui.document and ui.document.file
                    -- Determine cache key: section-scoped quizzes use the section cache key
                    local section_scope = configuration and configuration.features
                        and configuration.features._section_scope
                    local quiz_cache_key = (section_scope and section_scope.cache_key)
                        or action.id or "quiz"
                    UIManager:show(QuizViewer:new{
                        quiz_data = parsed,
                        opts = {
                            title = quiz_title,
                            chapter = chapter_title,
                            book_author = book_metadata and book_metadata.author,
                            on_save_notebook = quiz_file and function(text)
                                local Notebook = require("koassistant_notebook")
                                local notebook_path = Notebook.getPath(quiz_file)
                                if notebook_path then
                                    Notebook.append(notebook_path, "\n---\n\n" .. text .. "\n")
                                end
                            end,
                            on_save_state = quiz_file and function(state)
                                local ActionCache = require("koassistant_action_cache")
                                ActionCache.updateField(quiz_file, quiz_cache_key, "quiz_state", state)
                            end,
                        },
                    })
                    return
                end
                -- Fallback: if JSON parsing failed, show raw text in normal viewer
                logger.warn("KOAssistant: Quiz JSON parsing failed, falling back to text viewer")
            end

            -- For cache-first actions (Recap, X-Ray Simple): open in simple viewer
            -- The result is already saved to ActionCache; the full chat viewer is unnecessary
            if action.use_response_caching and action.id and plugin then
                local ActionCache = require("koassistant_action_cache")
                local file = ui and ui.document and ui.document.file or document_path
                if file then
                    local cached = ActionCache.get(file, action.id)
                    if cached and cached.result then
                        plugin:viewCachedAction(action, action.id, cached, {
                            file = file,
                            book_title = book_metadata and book_metadata.title,
                            book_author = book_metadata and book_metadata.author,
                        })
                        return
                    end
                end
            end

            -- For document analysis/summary: open in cache viewer
            -- (cache_as_xray already handled above with XrayBrowser)
            if (action.cache_as_analyze or action.cache_as_summary) and plugin then
                local ActionCache = require("koassistant_action_cache")
                local file = ui and ui.document and ui.document.file
                if file then
                    local cached, cache_name, cache_key
                    if action.cache_as_analyze then
                        cached = ActionCache.getAnalyzeCache(file)
                        cache_name = _("Analysis")
                        cache_key = "_analyze_cache"
                    else
                        cached = ActionCache.getSummaryCache(file)
                        cache_name = _("Summary")
                        cache_key = "_summary_cache"
                    end
                    if cached and cached.result then
                        plugin:showCacheViewer({ name = cache_name, key = cache_key, data = cached })
                        return
                    end
                end
            end

            local function addMessage(message, is_context, on_complete_msg)
                history:addUserMessage(message, is_context)
                local answer_result = BookToolRunner.queryWith(queryChatGPT, history:getMessages(), temp_config, function(success, answer, err, reasoning, web_search_used)
                    if success and answer then
                        history:addAssistantMessage(answer, ConfigHelper:getModelInfo(temp_config), reasoning, ConfigHelper:buildDebugInfo(temp_config), web_search_used)
                    else
                        -- Cancelled/failed: roll the unanswered question back out
                        history:removeLastUserMessage()
                    end
                    if on_complete_msg then on_complete_msg(success, answer, err, reasoning, web_search_used) end
                end, plugin, ui)
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

    -- Wiki artifact: intercept wiki action to cache as artifact (like X-Ray browser does)
    if action.id == "wiki" and highlighted_text and highlighted_text ~= "" and document_path then
        local ActionCache = require("koassistant_action_cache")
        local wiki_category = "highlight"
        -- Normalize: trim whitespace, truncate long selections for cache key
        local normalized = highlighted_text:match("^%s*(.-)%s*$") or highlighted_text
        if #normalized > 200 then
            normalized = normalized:sub(1, 200)
        end
        local wiki_key = ActionCache.WIKI_PREFIX .. wiki_category .. ":" .. normalized

        -- Helper: show wiki in simple_view with regenerate/delete
        local function showWikiArtifact(wiki_text)
            local Notification = require("ui/widget/notification")
            local wiki_viewer = ChatGPTViewer:new{
                title = T(_("AI Wiki: %1"), normalized),
                text = wiki_text,
                simple_view = true,
                cache_type_name = _("AI Wiki"),
                configuration = configuration,
                on_regenerate = function()
                    executeActionForResult(action, highlighted_text, ui, configuration, plugin, book_metadata,
                        function(result, meta)
                            if result then
                                ActionCache.setWikiEntry(document_path, wiki_category, normalized, result, meta)
                                showWikiArtifact(result)
                            else
                                UIManager:show(InfoMessage:new{
                                    text = _("Failed to regenerate wiki entry"),
                                    timeout = 3,
                                })
                            end
                        end)
                end,
                regenerate_label = _("Regenerate"),
                on_delete = function()
                    ActionCache.clearWikiEntry(document_path, wiki_category, normalized)
                    UIManager:show(Notification:new{
                        text = _("AI Wiki deleted"),
                        timeout = 2,
                    })
                end,
                _plugin = plugin,
                _artifact_file = document_path,
                _artifact_key = wiki_key,
                _artifact_book_title = book_metadata and book_metadata.title,
                _artifact_book_author = book_metadata and book_metadata.author,
                on_launch_chat = plugin and plugin._buildLaunchChatCallback
                    and plugin:_buildLaunchChatCallback(document_path, book_metadata and book_metadata.title, book_metadata and book_metadata.author, wiki_text, _("AI Wiki")) or nil,
            }
            UIManager:show(wiki_viewer)
        end

        local cached_wiki = ActionCache.getWikiEntry(document_path, wiki_category, normalized)
        if cached_wiki and cached_wiki.result then
            showWikiArtifact(cached_wiki.result)
            return
        end

        -- No cached wiki: run headless, store as artifact, show in simple_view
        executeActionForResult(action, highlighted_text, ui, configuration, plugin, book_metadata,
            function(result, metadata)
                if result then
                    ActionCache.setWikiEntry(document_path, wiki_category, normalized, result, metadata)
                    showWikiArtifact(result)
                else
                    UIManager:show(InfoMessage:new{
                        text = _("Error: ") .. (metadata or "Unknown error"),
                        timeout = 3,
                    })
                end
            end)
        return
    end

    -- Silent smart-retrieval default on direct entries (maintainer 2026-07-11): flagged
    -- actions gather first when the session allows it — the same default the popup gives
    -- on the input-dialog path, without adding a tap. Posture "off" or an ineligible
    -- session falls through to the action's normal flags (full extraction).
    if action.smart_retrieval == true
            and BookToolRunner.smartRetrievalAllowed(configuration, ui) then
        runSmartRetrieval(action, action.id or (action.text or "action"), highlighted_text,
            ui, configuration, plugin, function()
                handlePredefinedPrompt(action, highlighted_text, ui, configuration, nil,
                    plugin, nil, onComplete, book_metadata)
            end)
        return
    end

    -- Call handlePredefinedPrompt with the action object directly
    -- (avoids re-lookup which fails for special actions not in ActionService cache)
    logger.info("KOAssistant: executeDirectAction calling handlePredefinedPrompt with highlighted_text:", highlighted_text and #highlighted_text or "nil/empty")
    handlePredefinedPrompt(action, highlighted_text, ui, configuration, nil, plugin, nil, onComplete, book_metadata)
end

--- Execute an action and return just the result text + metadata via callback.
--- Thin wrapper around handlePredefinedPrompt for programmatic use (no viewer shown).
--- @param action table Action definition from prompts/actions.lua
--- @param highlighted_text string The text to act on
--- @param ui table KOReader UI instance
--- @param configuration table Plugin configuration
--- @param plugin table Plugin instance
--- @param book_metadata table Book title/author metadata
--- @param on_result function Callback: on_result(result_text, metadata) or on_result(nil, error_string)
executeActionForResult = function(action, highlighted_text, ui, configuration, plugin, book_metadata, on_result)
    handlePredefinedPrompt(action, highlighted_text, ui, configuration, nil, plugin, nil, function(history, temp_config_or_error)
        if history then
            local messages = history:getMessages()
            local last = messages[#messages]
            if last and last.content then
                local model_info = last.model_info
                on_result(last.content, {
                    model = model_info and model_info.model or "",
                    used_reasoning = last.reasoning ~= nil,
                    web_search_used = last.web_search_used or false,
                })
            else
                on_result(nil, "No response received")
            end
        else
            on_result(nil, temp_config_or_error or "Unknown error")
        end
    end, book_metadata)
end

--- Generate document summary cache, then call on_done(true) on success.
--- Used by unified action popup when user selects "Generate summary" source.
--- Chains handlePredefinedPrompt for summarize_full_document with a completion callback.
--- For section scope: clones the action, scopes text extraction, saves to section cache.
--- @param ui table: The UI instance
--- @param configuration table: The configuration table
--- @param plugin table: The plugin instance
--- @param book_metadata table: Book metadata {title, author}
--- @param on_done function(success): Called when summary generation completes
--- @param section_scope table|nil: Section scope for section summary generation
local function generateSummaryCache(ui, configuration, plugin, book_metadata, on_done, section_scope)
    local ok, Actions = pcall(require, "prompts.actions")
    local summary_action = ok and Actions and Actions.book and Actions.book.summarize_full_document

    if not summary_action then
        logger.warn("KOAssistant: summarize_full_document action not found for cache generation")
        UIManager:show(InfoMessage:new{
            text = _("Could not find summary action. Please try again."),
        })
        if on_done then on_done(false) end
        return
    end

    -- For section scope: clone and modify the action
    if section_scope then
        local section_action = {}
        for k, v in pairs(summary_action) do section_action[k] = v end
        section_action.cache_as_summary = false  -- Don't save to main summary cache
        section_action.update_prompt = nil
        section_action.use_reading_progress = false
        section_action.use_response_caching = false
        section_action._section_scope = section_scope  -- Scopes text extraction to section pages
        -- Inject section scope context into prompt
        if section_action.prompt then
            local scope_line = string.format(
                'This is a section of "{title}"{author_clause}.\nSection: "%s" (%s)\nFocus your summary on this section only.\n\n',
                section_scope.label, section_scope.page_summary)
            section_action.prompt = scope_line .. section_action.prompt
        end
        summary_action = section_action
    end

    -- Show progress notification
    local Notification = require("ui/widget/notification")
    UIManager:show(Notification:new{
        text = section_scope and _("Generating section summary...") or _("Generating document summary..."),
        timeout = 2,
    })

    -- Execute summarize action (saves to _summary_cache or section cache via _section_scope)
    handlePredefinedPrompt(
        summary_action, nil, ui, configuration,
        nil, plugin, nil,
        function(history, _config_result)
            if history then
                -- Cache is now populated, continue with original action
                UIManager:scheduleIn(0.3, function()
                    if on_done then on_done(true) end
                end)
            else
                UIManager:show(InfoMessage:new{
                    text = section_scope and _("Section summary generation failed. Please try again.")
                        or _("Summary generation failed. Please try again."),
                })
                if on_done then on_done(false) end
            end
        end,
        book_metadata
    )
end

--- Launch a chat about an artifact. Follows the Send button flow:
--- builds consolidated message with artifact as context, queries AI, opens chat viewer.
--- @param user_question string The user's typed question
--- @param artifact_content string The full artifact text
--- @param artifact_type_name string Display name of the artifact (e.g. "Key Arguments")
--- @param ui table KOReader UI instance
--- @param configuration table Plugin configuration
--- @param plugin table Plugin instance
--- @param book_metadata table {title, author, file}
local function launchArtifactChat(user_question, artifact_content, artifact_type_name, ui, configuration, plugin, book_metadata)
    local document_path = book_metadata and book_metadata.file
    local title = (artifact_type_name or _("Artifact")) .. ": " .. _("Chat")

    -- Resolve research mode for artifact chat (no action override). The same DocSettings
    -- also carries the per-book AI title/author override, applied to the AI-facing copy of
    -- the identity below (callers pass raw doc_props/cache metadata); book_metadata itself
    -- stays raw for local bookkeeping (chat save metadata).
    local artifact_research = false
    local ai_book_metadata = book_metadata
    if document_path then
        local artifact_ds = SafeDocSettings.resolve(document_path, ui)
        ai_book_metadata = require("koassistant_book_settings").applyMetadataOverride(book_metadata, artifact_ds)
        local book_research_setting = getBookResearchMode(artifact_ds)
        if book_research_setting == true then
            artifact_research = true
        elseif book_research_setting == false then
            artifact_research = false
        else
            local has_doi = book_metadata and book_metadata.doi
            if has_doi then
                artifact_research = true
            else
                artifact_research = configuration.features
                    and configuration.features.research_mode == true
            end
        end
    end
    configuration.features = configuration.features or {}
    configuration.features._research_mode_active = artifact_research or nil
    -- Artifact chat is spoiler-free-excluded and passes action=nil, so the predefined-action
    -- guard in buildUnifiedRequestConfig won't clear a leaked flag — clear it explicitly here so
    -- a prior spoiler-free freeform chat can't inject the nudge into artifact chat. (audit G6)
    -- Same for the per-chat tools checkbox: artifact chat follows the global flag only.
    -- And the per-chat web toggle: artifact chat follows the per-book/global defaults.
    configuration.features._spoiler_free_active = nil
    configuration.features._tools_active = nil
    configuration.features._web_search_active = nil
    -- Quick controls: artifact chat follows the global settings too — clear the
    -- dispatch consumables and any lingering chip state (matrix §10).
    configuration.features._quick_answer_active = nil
    configuration.features._reasoning_override_active = nil
    configuration.features._model_override_active = nil
    configuration.features._session_quick_answer = nil
    configuration.features._session_reasoning = nil
    configuration.features._session_model = nil

    -- Build system prompt (standard book chat)
    buildUnifiedRequestConfig(configuration, nil, nil, plugin)

    -- Create history with artifact type as prompt_action for title generation
    local history = MessageHistory:new(nil, nil)
    history.prompt_action = artifact_type_name
    history.source_input = user_question

    -- Build consolidated message: book context + artifact framing + artifact content + user question
    local parts = {}

    table.insert(parts, "[Context]")
    if ai_book_metadata and ai_book_metadata.title then
        table.insert(parts, string.format('From "%s"%s',
            ai_book_metadata.title,
            (ai_book_metadata.author and ai_book_metadata.author ~= "") and (" by " .. ai_book_metadata.author) or ""))
        table.insert(parts, "")
    end

    -- Framing prefix (like _xray_context_prefix): explains this is a generated artifact, not book text
    local framing = "(Note: The following is a previously generated " .. (artifact_type_name or "artifact") .. " artifact for this book, not the book text itself.)"
    table.insert(parts, framing)
    table.insert(parts, "")

    table.insert(parts, "Artifact content:")
    table.insert(parts, '"' .. artifact_content .. '"')
    table.insert(parts, "")

    table.insert(parts, "[User Question]")
    table.insert(parts, user_question)

    local consolidated_message = table.concat(parts, "\n")
    history:addUserMessage(consolidated_message, true)

    -- Query AI with the consolidated message
    local function onResponseReady(success, answer, err, reasoning, web_search_used)
        if success and answer then
            -- Add user's visible question and AI response
            history:addUserMessage(user_question, false)
            history:addAssistantMessage(answer, ConfigHelper:getModelInfo(configuration), reasoning, ConfigHelper:buildDebugInfo(configuration), web_search_used)

            local function addMessage(message, is_context, on_complete)
                history:addUserMessage(message, is_context)
                local answer_result = BookToolRunner.queryWith(queryChatGPT, history:getMessages(), configuration, function(msg_success, msg_answer, msg_err, msg_reasoning, msg_web_search_used)
                    if msg_success and msg_answer then
                        history:addAssistantMessage(msg_answer, ConfigHelper:getModelInfo(configuration), msg_reasoning, ConfigHelper:buildDebugInfo(configuration), msg_web_search_used)
                    else
                        -- Cancelled/failed: roll the unanswered question back out
                        history:removeLastUserMessage()
                    end
                    if on_complete then on_complete(msg_success, msg_answer, msg_err, msg_reasoning, msg_web_search_used) end
                end, plugin, ui)
                if not isStreamingInProgress(answer_result) then
                    return answer_result
                end
                return nil
            end

            showResponseDialog(title, history, nil, addMessage, configuration, document_path, plugin, book_metadata, nil, ui)
        else
            UIManager:show(InfoMessage:new{
                text = _("Error: ") .. (err or "Unknown error"),
                timeout = 3,
            })
        end
    end

    BookToolRunner.queryWith(queryChatGPT, history:getMessages(), configuration, onResponseReady, plugin, ui)
end

return {
    showChatGPTDialog = showChatGPTDialog,
    executeDirectAction = executeDirectAction,
    executeActionForResult = executeActionForResult,
    generateSummaryCache = generateSummaryCache,
    extractSurroundingContext = extractSurroundingContext,
    fetchSelectionContextWindow = fetchSelectionContextWindow,
    launchArtifactChat = launchArtifactChat,
    -- Exported for runtime self-require from the quick chip's hold (60-upvalue
    -- cap) and for the reply-dialog reuse planned in parity slice (b).
    showQuickControlsMenu = showQuickControlsMenu,
}
