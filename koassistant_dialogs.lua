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
local Constants = require("koassistant_constants")
local ScopeResolver = require("koassistant_scope_resolver")
local PromptsActions = require("prompts.actions")
local logger = require("koassistant_logger")

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
    require("koassistant_logger").dbg("KOAssistant: no configuration.lua at " .. config_path)
end

-- Add a global variable to track active chat viewers
if not _G.ActiveChatViewer then
    _G.ActiveChatViewer = nil
end

-- Global reference to current loading dialog for closing
local _active_loading_dialog = nil
local _loading_animation_task = nil

-- Close the loading dialog (called when response is ready). The showLoadingDialog
-- that once set _active_loading_dialog is gone (dead since the gpt_query loading
-- dialog took over — it also carried a stale bare-truthiness reasoning check);
-- call sites remain as harmless no-ops guarding the shared slot.
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

-- ButtonDialog sizes its title to the text with no max-height clamp, so a long message
-- runs the buttons off the screen (confirmed on device: a fully decorated 429 filled
-- the screen and the buttons were unreachable). Past this length the rate-limit dialog
-- becomes a scrollable TextViewer carrying the same buttons instead.
local ERROR_DIALOG_MAX_CHARS = 400

--- Show a failed request. Rate/quota refusals and overload/503s get a persistent
--- dialog with a retry button instead of the usual 3-second toast: they are the
--- failure classes where trying again is the correct response (a per-minute limit
--- recovers in seconds, an overloaded model in moments, and the 429 message now says
--- how long to wait), and a toast that vanishes leaves the reader with nothing to act
--- on. Every other error keeps the toast — making all of them unmissable would be
--- worse. `retry_fn` is optional; without one this is just a toast.
--- @param err_text string: message to display (already decorated by ModelConstraints)
--- @param retry_fn function|nil: re-runs the same request; called as retry_fn() for a
---        plain retry, retry_fn(true) to retry with the offered extras dropped (the
---        call site knows which were active and builds the stripped request)
--- @param timeout number|nil: toast timeout in seconds (default 3; ignored by the dialog)
--- @param drop_offer table|nil: { web = bool, tools = bool } — which optional request
---        extras were active on the failed request. When either is true, a labelled
---        "Try again without …" row re-runs via retry_fn(true). Free-tier Gemini 3.x
---        rejects requests carrying web search (grounding) OR book tools (function
---        calling) even when plain requests work (probed 2026-08-14), so the identical
---        request minus the extras often succeeds; the drop is one-shot, the chat's
---        settings are untouched.
local function showRequestError(err_text, retry_fn, timeout, drop_offer)
    -- Overload/503 joins the persistent-dialog class (2026-08-15 device round: a
    -- high-demand 503 vanished as a toast with no retry button), but the drop row
    -- stays rate-limit-only — dropping web/tools does not heal an overloaded model.
    -- An account wall (credits, balance, a spending cap) joins the persistent
    -- class too: its tip is several lines a 3-second toast cannot show, and
    -- "Try again" is right once the account is topped up. It is NOT a rate
    -- limit here even when its wording says "quota" (OpenAI's
    -- insufficient_quota): dropping web search or book tools cannot pay for it.
    local is_billing = ModelConstraints.isBillingWall(err_text)
    local is_rate_limit = not is_billing and ModelConstraints.isRateLimitError(err_text)
    if retry_fn and type(err_text) == "string"
            and (is_rate_limit or is_billing or ModelConstraints.isOverloadError(err_text)) then
        local dialog
        local buttons = {{
            {
                text = _("Close"),
                callback = function() UIManager:close(dialog) end,
            },
            {
                text = _("Try again"),
                callback = function()
                    UIManager:close(dialog)
                    retry_fn()
                end,
            },
        }}
        if is_rate_limit and drop_offer and (drop_offer.web or drop_offer.tools) then
            local label
            if drop_offer.web and drop_offer.tools then
                label = _("Try again without web search or book tools")
            elseif drop_offer.web then
                label = _("Try again without web search")
            else
                label = _("Try again without book tools")
            end
            table.insert(buttons, {
                {
                    text = label,
                    callback = function()
                        UIManager:close(dialog)
                        retry_fn(true)
                    end,
                },
            })
        end
        if #err_text <= ERROR_DIALOG_MAX_CHARS then
            dialog = ButtonDialog:new{
                title = err_text,
                title_align = "left",
                buttons = buttons,
            }
        else
            -- Long decorated errors (quota facts + tips): scrollable, buttons always
            -- reachable. TextViewer adds no default buttons when buttons_table is set,
            -- so the rows above carry their own Close.
            local TextViewer = require("ui/widget/textviewer")
            dialog = TextViewer:new{
                title = _("Request failed"),
                text = err_text,
                buttons_table = buttons,
            }
        end
        UIManager:show(dialog)
        return
    end
    UIManager:show(InfoMessage:new{
        text = err_text,
        timeout = timeout or 3,
    })
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
-- Canonical order + the membership registry now live in koassistant_constants.lua so a NEW
-- chip reaches existing users automatically (defaults_propagation_plan.md G1). Chips used to
-- be the only membership list with no auto-injection, which is why scope/attach/quick each
-- needed a hand-written `_session_chips_*` migration; that pattern is retired.
local SESSION_CHIP_IDS = Constants.SESSION_CHIP_IDS
local function getSessionChips(features)
    return Constants.resolveSessionChips(
        features and features.session_chips,
        features and features._dismissed_session_chips)
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

-- Words fetched per side. Must clear every trim mode's per-side cap (1000
-- chars) with room to spare: 200 words (~1140 chars) sat barely above the cap,
-- so paragraph mode's outermost segments were almost always the raw window's
-- ragged edge (device 2026-08-17). The trim decides what is actually sent.
local CONTEXT_WINDOW_WORDS = 300

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
local function extractSurroundingContext(ui, highlighted_text, mode, char_count, paragraph_count, after_limit)
    mode = mode or "sentence"
    if mode == "none" then
        return ""
    end
    local window = fetchSelectionContextWindow(ui, highlighted_text)
    if not window then
        return ""
    end
    return ScopeResolver.trimContext(window.prev, window.next, highlighted_text, mode,
        { char_count = char_count, paragraphs = paragraph_count, after_limit = after_limit })
end

--- After-side limit for context windows (consolidation P5, granularity round 2):
-- the global "before only" direction pick maps to "none"; otherwise, when
-- spoiler protection applies, the configured clamp (features.spoiler_context_limit,
-- default "paragraph" since round 3 — maintainer: the selection's own paragraph
-- is on the visible page, and context is only sent when the user chose to send
-- it). "off" = no clamp, the deliberate escape hatch. Returns nil (unlimited)
-- | "none" | "sentence" | "paragraph".
local function contextAfterLimit(features, spoiler_on)
    -- Session dials (rounds 5+7): the Ctx chip's per-request picks win
    local dir = features._session_ctx_direction or features.highlight_context_direction
    if dir == "before" then return "none" end
    if not spoiler_on then return nil end
    local lim = features._session_ctx_spoiler_limit
        or features.spoiler_context_limit or "paragraph"
    if lim == "off" then return nil end
    if lim == "selection" then return "none" end
    if lim == "sentence" then return "sentence" end
    return "paragraph"
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
-- Resolve the Quick Answer preset's model component (controls_parity_plan.md §2
-- round 3): quick_preset_model_mode = "none" | "fastest" (fastest listed tier for
-- the active provider) | "tier" (quick_preset_tier for the active provider — or,
-- when quick_preset_tier_provider is set, that PINNED provider's tier; tier
-- fallback toward faster) | "model" (pinned quick_preset_provider/_model).
-- Shared by the request bake AND the quick-menu provenance label — keep them
-- agreeing. Returns { provider, model } or nil (no override).
local function resolveQuickPresetModel(features, provider)
    local mode = features.quick_preset_model_mode or "none"
    if mode == "none" then return nil end
    local MLists = require("koassistant_model_lists")
    if mode == "model" then
        if features.quick_preset_provider and features.quick_preset_model then
            return { provider = features.quick_preset_provider, model = features.quick_preset_model }
        end
        return nil
    end
    if mode == "tier" then
        local tier = features.quick_preset_tier or "fast"
        local pinned = features.quick_preset_tier_provider
        if pinned then
            -- Explicit provider pin: ladder only, never global tier pins —
            -- same ruling as action provider+tier pins (maintainer 2026-08-09:
            -- a named provider must not be hijacked to another one). Tier miss
            -- (exact tiers, 2026-08-14) still honors the provider half: switch
            -- with model nil = that provider's default (the action-pin shape).
            local m = MLists.resolveTierModel(pinned, tier)
            return { provider = pinned, model = m }
        end
        -- Active provider: tier miss = nil = keep the current model
        local p2, m = MLists.resolveTierTarget(provider, tier)
        if m then return { provider = p2, model = m } end
        return nil
    end
    -- "fastest": shared walk (ModelLists.resolveTierTarget — also the 18e
    -- per-action tier resolver; global tier pins consulted per step, so the
    -- returned provider may differ from the active one; without any placement
    -- → nil → keep the current model).
    local p2, m = MLists.resolveTierTarget(provider, "fastest")
    if m then return { provider = p2, model = m } end
    return nil
end

-- Resolve the provider this request will ACTUALLY dispatch to, accounting for the
-- pending one-shot session model override (⚡ menu pick / Quick preset model) the
-- way buildUnifiedRequestConfig will apply it. The extraction trust gate runs
-- BEFORE the bake — judging trust against the pre-override provider would let data
-- extracted under a trusted provider's bypass be dispatched to an untrusted one
-- (injection_gating_audit; extends audit v0.20.0 finding C4). Mirrors the bake's
-- precedence exactly: action pin > manual ⚡ model pick > Quick preset model (only
-- when the action accepts quick) > base provider. Reads only; consumption stays in
-- the bake.
local function effectiveDispatchProvider(features, action, base_provider)
    if action and action.provider then return base_provider end
    features = features or {}
    -- The *_active consumables are set just-in-time at dispatch; before that point
    -- (freeform Send's scope-consent check) the same pending state lives in the
    -- _session_* chip keys. Direct entries drop inherited chip state, then may
    -- seed the quick consumable from the Quick Answer DEFAULT (accept-gated,
    -- handlePredefinedPrompt's direct-entry guard) — covered here by the
    -- _quick_answer_active read.
    local override = features._model_override_active or features._session_model
    if override and override.provider then return override.provider end
    local quick = features._quick_answer_active or features._session_quick_answer
    if quick and action and action.accept_quick_answer ~= true then quick = nil end
    if quick then
        local preset = resolveQuickPresetModel(features, base_provider)
        if preset and preset.provider then return preset.provider end
    end
    -- Per-action tier hint (weakest rung): a usable GLOBAL tier pin re-points
    -- the dispatch provider (tier GUI phase 2) — mirror the bake's resolution
    -- with the same guards. Ladder hits return the base provider unchanged.
    if features.use_action_tiers ~= false and action and action.model_tier
            and not action.provider and not action.model then
        local p2 = require("koassistant_model_lists")
            .resolveTierTarget(base_provider, action.model_tier)
        if p2 then return p2 end
    end
    return base_provider
end

-- Reasoning headroom (#98): thinking tokens bill against max_tokens on every
-- provider, so a pinned max_tokens (sized for the answer alone) can be consumed
-- entirely by reasoning, ending the stream with zero answer text. Built-in
-- actions no longer pin (item 27); this covers USER-authored custom actions and
-- copies of built-ins duplicated before that change. Dropping the pin hands the
-- request to the handler's own ceiling-aware default, which is already what an
-- unpinned request sends — so this can never exceed a real ceiling.
--
-- Fires when the model IS reasoning, OR when we do not recognize the model at
-- all. That second case is the one that matters in practice: anything pulled in
-- via "Fetch models", any custom/local provider model, gets the passthrough
-- profile, which reports mode "off" — so gating on mode alone skipped exactly
-- the models most likely to need this. The asymmetry justifies it: guessing
-- "might reason" costs a larger response than asked for, guessing the other way
-- costs an EMPTY one, which the reader cannot diagnose.
--
-- The floor is a constant, not the provider's fallback: on providers whose
-- fallback IS 4096 a pinned 4096 is not "< fallback", so the net never fired
-- precisely where the budget was tightest.
local REASONING_HEADROOM_FLOOR = 16384
-- The ⚡ Quick preset's facet-off rule, ONE implementation (six-pack [1] —
-- this was hand-duplicated at ~12 dispatch/label/toast sites and the copies
-- could drift silently). Returns true when the preset forces `facet`
-- ("web" | "tools") OFF. `quick_on` is passed by the site because two signals
-- exist: the bake reads the dispatch consumable _quick_answer_active, chip
-- labels and the reply window read the session state. Pin-beats-preset: a
-- facet TOUCHED while Quick is on keeps its own value. Web exempts an action
-- that explicitly forces web on (matrix §10); tools carry NO action exemption
-- here because the bake separately forces tools off for every predefined
-- action — that asymmetry is deliberate and pinned by the unit test.
local function quickPresetForces(facet, quick_on, features, action)
    if not quick_on or not features then return false end
    if facet == "web" then
        if action and action.enable_web_search == true then return false end
        return features.quick_preset_web_off ~= false
            and not features._session_web_touched
    end
    if facet == "tools" then
        return features.quick_preset_tools_off ~= false
            and not features._session_tools_touched
    end
    return false
end

local function ensureReasoningHeadroom(api_params, provider, decision)
    if not (api_params and api_params.max_tokens and decision) then return end
    local might_reason = decision.mode == "on"
        or (decision.profile and decision.profile.unknown)
    if not might_reason then return end
    if api_params.max_tokens < REASONING_HEADROOM_FLOOR then
        api_params.max_tokens = nil
    end
end

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
        -- Also drop the chip-state key from this chat's config: it would ride
        -- into the action chat's replies, where applyQuickReplyOverrides has no
        -- accept gate — the posture would reach non-accepting actions (and then
        -- persist via control_state). Reasoning/model session picks stay —
        -- Web-pattern reach (round-2 gate, governance hole).
        features._session_quick_answer = nil
    end
    -- Preset model component: switch model for this chat per quick_preset_model_mode
    -- (fastest / tier / pinned model — resolveQuickPresetModel above). Manual
    -- ⚡-menu model picks win.
    if quick_answer and not model_override then
        model_override = resolveQuickPresetModel(features,
            config.provider or config.default_provider or "anthropic")
    end
    -- Per-action model tier (item 18e, on unless disabled via Advanced → Faster
    -- Models for Quick Actions): actions carrying a model_tier hint switch to a
    -- faster model — the active provider's ladder pick, or a GLOBAL tier pin's
    -- provider+model (tier GUI phase 2; effectiveDispatchProvider mirrors this
    -- so extraction trust is judged against the pin's provider). Weakest rung
    -- of the model precedence: action provider/model pins, the ⚡ session pick,
    -- and the Quick preset model all win; the hint fills in only when nothing
    -- else chose. No placement anywhere → nil → current model kept.
    -- Default-true check pattern (~= false).
    if not model_override and features.use_action_tiers ~= false
            and action and action.model_tier
            and not action.provider and not action.model then
        local tier_provider = config.provider or config.default_provider or "anthropic"
        local target_provider, tier_model = require("koassistant_model_lists")
            .resolveTierTarget(tier_provider, action.model_tier)
        if tier_model then
            model_override = { provider = target_provider, model = tier_model }
            -- The hint belongs to THIS action, but the bake below writes the
            -- resolved model onto the dispatch config — which becomes the viewer's
            -- config. Switching to an action with no hint re-dispatches from it and
            -- has nothing to re-derive, so the fast model would silently persist.
            -- Record what it replaces; the dispatch seam restores it. `false` = the
            -- field was unset (nil cannot be stored as "I stashed nothing"). The
            -- provider is recorded too: the stash is only valid for it — restoring
            -- provider P's model onto a config whose next action pinned provider Q
            -- would send a foreign model id. (_tier_model_prev_ps is the bucket the
            -- bake clobbers below — [target_provider], not [tier_provider].)
            features._tier_model_prev = config.model or false
            features._tier_model_prev_ps = (config.provider_settings
                and config.provider_settings[target_provider]
                and config.provider_settings[target_provider].model) or false
            features._tier_model_prev_provider = target_provider
            if target_provider ~= tier_provider then
                -- A global pin moved the WHOLE dispatch to another provider.
                -- Record the original so the next non-hinted action comes home
                -- (the model stash alone can't: its provider guard would see a
                -- foreign provider and drop it, stranding the chat on the pin).
                features._tier_prev_provider = config.provider or false
                features._tier_installed_provider = target_provider
            end
        end
    end
    -- Provider-only action pin + tier hint (maintainer 2026-08-09): the pin
    -- names the provider, the tier picks the model class INSIDE it — ladder
    -- only, never global pins (an explicit action pin is the stronger intent
    -- and must not be hijacked to another provider). createTempConfig applied
    -- the provider; without this the action would sit on the provider's
    -- default model and the hint would be dead. Written like the override
    -- apply above (model + cloned per-provider table) — the model_override
    -- path skips pinned actions by design. No stash: a pinned action's chat
    -- staying on its pin is existing semantics.
    if features.use_action_tiers ~= false and action and action.model_tier
            and action.provider and not action.model then
        local m = require("koassistant_model_lists")
            .resolveTierModel(action.provider, action.model_tier)
        if m then
            config.model = m
            config.provider_settings = config.provider_settings or {}
            local ps = {}
            for k, v in pairs(config.provider_settings[action.provider] or {}) do
                ps[k] = v
            end
            ps.model = m
            config.provider_settings[action.provider] = ps
        end
    end
    -- One-shot provider/model override — applied BEFORE every provider-dependent
    -- read below (caching gate, Perplexity check, reasoning resolution). An
    -- action's own provider pin (already applied by createTempConfig/
    -- handlePredefinedPrompt) wins.
    if model_override and model_override.provider and not (action and action.provider) then
        config.provider = model_override.provider
        -- model may be NIL (provider+tier pin whose exact tier the provider
        -- lacks, 2026-08-14): clear the top-level model (never send the old
        -- provider's id across the switch) and leave the per-provider bucket
        -- alone, so the pinned provider's own configured/default model applies.
        config.model = model_override.model
        if model_override.model then
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
    end
    if quickPresetForces("tools", quick_answer, features) then
        -- Preset "no slow features": book tools off for this chat (explicit false —
        -- rides the viewer config into replies, same mechanics as the G6 clear).
        -- Pin-beats-preset (A9 sitting 2026-08-17, option (b)): a chip TOUCHED
        -- while Quick is on is the user's pin for that facet — the preset stands
        -- down and the baked chip value (just written by performSend) rides.
        features._tools_active = false
    end

    -- The per-chat tools checkbox (_tools_active) is cleared for predefined actions —
    -- and set to EXPLICIT false, not nil (2026-07-11, with the auto posture default):
    -- this config rides into the action's chat viewer and its replies (addMessage →
    -- queryWith), and a nil would fall through to the posture there, so an "auto"
    -- posture would fire gather rounds on replies to translate/X-Ray/etc. chats.
    -- Actions engage tools ONLY via their explicit smart-retrieval source; their chats
    -- stay tools-free. Freeform Send passes action=nil and keeps the flag it just set.
    -- (Spoiler protection no longer gets the audit-G6 blanket clear here: since
    -- spoiler_posture_plan.md §3 the flag is RESOLVED per action — chip > research >
    -- book > global, skip_spoiler opts out — in the eff_ds block below, where the
    -- book's DocSettings are in scope. The per-chat web toggle is likewise not
    -- cleared: it applies to nil-flag actions launched from the dialog too —
    -- maintainer 2026-07-12, the action buttons' 🌐 indicator follows the chip.
    -- Forced action flags still win in the chain below; the dialog sets both
    -- just-in-time and this function's bake consumes them, so other entry points
    -- never see a stale value.)
    if action then
        features._tools_active = false
    end

    -- Per-book MAIN response-language override (Book Settings ▸ Languages ▸ AI response
    -- language) — applies to every action's system prompt, distinct from translate/dictionary.
    local lang_fields = {
        interaction_languages = features.interaction_languages,
        user_languages = features.user_languages or "",
        primary_language = features.primary_language,
    }
    -- THE per-book identity for this request (response language, effort dials,
    -- Background — one rule so they always resolve against the SAME book, the
    -- identity invariant from ai-metadata-override-leaks): explicit book_metadata
    -- target for book context (file browser / book chat), the OPEN book for
    -- highlight context. Highlight entries null out book_metadata, which used to
    -- leave the language override and effort dials inert on every highlight
    -- request while Background had its own fallback (injection_gating_audit).
    -- General/library: no single book → globals (library keeps its first-book
    -- metadata behavior for the language override, as before).
    local lang_file = features.book_metadata and features.book_metadata.file
    if not features.is_general_context and not features.is_library_context then
        local doc_file = plugin and plugin.ui and plugin.ui.document
            and plugin.ui.document.file
        if features.is_book_context then
            lang_file = lang_file or doc_file   -- explicit target (file browser) wins
        else
            lang_file = doc_file or lang_file   -- highlight: the open book wins
        end
    end
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

    -- Effort dials (Book Tools lookup effort / Web search depth): per-book override >
    -- global. `features` here is config.features, a private per-request copy
    -- (createTempConfig 2-level copy — the sole buildUnifiedRequestConfig call site), so
    -- writing the resolved value back is flush-safe and both readers pick it up with no
    -- wire change: BookToolRunner.budgetFor(config.features) and
    -- ModelConstraints.webSearchEffort(config.features). Book resolved from the same
    -- sidecar route as the web override (book_metadata.file); general/library fall to
    -- global. Always assigned so a stale value can't linger; no-op when there's no book
    -- override (resolver returns the global).
    -- The same block resolves the per-book Background (see below).
    local book_background = nil
    do
        local eff_ds = lang_file and SafeDocSettings.resolve(lang_file) or nil
        features.tool_lookup_effort = BookSettings.resolveToolEffort(eff_ds, features)
        features.web_search_effort = BookSettings.resolveWebEffort(eff_ds, features)

        -- Per-book Background (book_background_plan.md §2/§3): the reader's standing
        -- note about this book, injected into the system prompt next to
        -- behavior/domain. This one chokepoint is why Background reaches EVERY entry
        -- point (direct actions, gestures, artifact chat), unlike the dialog-scoped
        -- Attach note. Per-action gating is a read-through: skip_background nil =
        -- follow skip_domain, true = never, false = always (book_reviews opts back in).
        -- Resolves from lang_file/eff_ds: since the unified per-book identity rule
        -- above (open-book fallback for highlight, explicit target for book context),
        -- Background, language and effort dials all read the SAME book by
        -- construction. General/library are excluded here (Background is a
        -- single-book note; library's first-book metadata must not leak in).
        local skip_background = action and action.skip_background
        if skip_background == nil then skip_background = action and action.skip_domain end
        if not skip_background and eff_ds
                and not features.is_general_context and not features.is_library_context then
            book_background = BookSettings.getBackground(eff_ds)
        end

        -- Spoiler protection reach into actions (spoiler_posture_plan.md §3 + C1):
        -- the old audit-G6 blanket clear becomes the REQUEST-layer resolution —
        -- session chip (rode in as _spoiler_free_active from the dialog's
        -- just-in-time set; nil for direct entries, which scrub) > research >
        -- per-book override > global. skip_spoiler = true (artifact / translate /
        -- dictionary families, the mechanical merge actions) opts out, and only
        -- book/highlight-context requests resolve — posture is book-scoped. The
        -- resolved boolean is written back so the tool reading clamp and this
        -- chat's replies read one decision. Freeform (action = nil) keeps the
        -- flag Send just wrote — already the session layer of the same rule.
        -- C4 REVISED (2026-08-11, PROVISIONAL — plan §4.2): the nudge itself is
        -- TURN-level and LIVE — BookToolRunner.queryWith appends it to each
        -- protected send with the posture and position of that moment; it is
        -- never baked into the system prompt or MessageHistory. This block only
        -- marks eligibility: _spoiler_live = this chat participates in live
        -- resolution at all; _spoiler_in_prompt = the action resolves
        -- {spoiler_free_nudge} in place, so the first request must not get the
        -- line too (never both — replies do).
        local spoiler_excluded = features._spoiler_exclude == true
        features._spoiler_exclude = nil  -- one-shot marker (launchArtifactChat)
        features._spoiler_live = nil
        features._spoiler_in_prompt = nil
        if spoiler_excluded then
            -- Artifact chat: EXPLICIT false — it must survive save/resume (the
            -- restore's legacy book-chat default would otherwise re-enable it).
            features._spoiler_live = false
        elseif not (features.is_general_context or features.is_library_context
                or (action and action.skip_spoiler == true)) then
            features._spoiler_live = true
        end
        if action then
            if features._spoiler_live then
                features._spoiler_free_active = BookSettings.resolveSpoilerPosture(
                    eff_ds, features, { session = features._spoiler_free_active }).protected
                -- Template-based actions (book_info) carry the placeholder in
                -- the resolved template, not action.prompt — consult it too
                local tpl = type(action.template) == "string"
                    and require("prompts.templates").get(action.template)
                if (type(action.prompt) == "string"
                        and action.prompt:find("{spoiler_free_nudge}", 1, true))
                    or (type(tpl) == "string"
                        and tpl:find("{spoiler_free_nudge}", 1, true))
                    or (type(action.update_prompt) == "string"
                        and action.update_prompt:find("{spoiler_free_nudge}", 1, true)) then
                    features._spoiler_in_prompt = true
                end
            else
                features._spoiler_free_active = nil
            end
        end
    end

    -- ⚡ quick-answer retry eligibility (S3): the stream window offers a quick retry only
    -- for freeform sends (action == nil) and actions that opted into quick
    -- (accept_quick_answer). Artifact/JSON actions (X-Ray, Summarize, …) would break under
    -- the brevity posture, so no ⚡ on their streams. Read into stream_settings by queryChatGPT.
    features._quick_eligible = (action == nil) or (action.accept_quick_answer == true)
    -- Quick Answer preset: web search off for this request unless the preset
    -- component is disabled, the action forces web on (explicit action flag
    -- wins — matrix §10), or the chip was touched while Quick was on (the pin,
    -- A9 sitting 2026-08-17 option (b) — the manual chip value baked at line
    -- ~635 stays authoritative).
    if quickPresetForces("web", quick_answer, features, action) then
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

    -- Quick preset identity components (A6, picker rework 2026-08-11 —
    -- maintainer: behavior component OFF by default; users may already run a
    -- brief or None behavior, and identity layers are cached prefix so
    -- skipping buys no speed — controls_parity §11). quick_preset_behavior:
    -- nil/"keep" = leave the behavior alone (default) · "mini_of_current" =
    -- the §11 lever, swap to the mini sibling family-aware · "none" = drop the
    -- layer · any other value = pin that behavior id (the built-in terse is
    -- the intended pick). quick_preset_skip_domain stays a separate opt-in.
    -- Action pins win (matrix §10): a pinned behavior/domain is never touched.
    -- quick_preset_skip_background (maintainer 2026-08-12) is the same opt-in
    -- shape for the per-book Background; an action's explicit
    -- skip_background = false ("always include") counts as a pin and wins.
    local quick_behavior
    if quick_answer then
        if features.quick_preset_skip_domain == true
            and not (action and action.domain) then
            domain_context = nil
        end
        if features.quick_preset_skip_background == true
            and not (action and action.skip_background == false) then
            book_background = nil
        end
        local qb = features.quick_preset_behavior
        if qb and qb ~= "keep"
            and not (action and (action.behavior_variant or action.behavior_override)) then
            if qb == "none" then
                quick_behavior = "none"
            elseif qb == "mini_of_current" then
                local base = features.selected_behavior or "standard"
                local candidate
                if base == "full" or base == "standard" then
                    candidate = "mini"
                else
                    candidate = base:gsub("_full$", "_mini"):gsub("_standard$", "_mini")
                end
                if candidate ~= base and SystemPrompts.getBehaviorById(
                        candidate, features.custom_behaviors) then
                    quick_behavior = candidate
                end
            elseif SystemPrompts.getBehaviorById(qb, features.custom_behaviors) then
                -- Pinned id: apply only while it still resolves — a renamed or
                -- deleted behavior degrades to "keep", never to a broken layer.
                quick_behavior = qb
            end
        end
    end

    -- Build unified system prompt (works for all providers)
    local system_config = SystemPrompts.buildUnifiedSystem({
        -- Behavior resolution (priority: action override > action variant >
        -- quick preset swap/skip > global)
        behavior_variant = (action and action.behavior_variant) or quick_behavior,
        behavior_override = action and action.behavior_override,
        global_variant = features.selected_behavior or "standard",
        custom_ai_behavior = features.custom_ai_behavior,  -- Legacy support (for migrated users)
        custom_behaviors = features.custom_behaviors,       -- NEW: array of UI-created behaviors
        -- Domain context
        domain_context = domain_context,
        -- Per-book Background (resolved + gated above)
        book_background = book_background,
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
        -- Spoiler protection deliberately absent here (C4 revised): the nudge is
        -- turn-level and live, appended per send in BookToolRunner.queryWith — a
        -- system copy would freeze the percent for the life of the chat.
        -- Web search active → prose nudge (pre-search text is reader-visible)
        web_search = web_search_effective,
        -- Quick Answer posture → brevity nudge (session ⚡ chip / opted-in actions;
        -- preset component quick_preset_nudge, default on; "strict" = the opt-in
        -- ultra-brief ceiling replaces the standard text)
        quick_answer = (quick_answer and features.quick_preset_nudge ~= false)
            and ((features.quick_preset_nudge_strict == true) and "strict" or true)
            or nil,
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
    -- handlers resolve the default via ModelConstraints.resolveMaxTokens
    -- (item 27 raise-where-known: min(32768, known ceiling), else the provider
    -- fallback from defaults.lua). Explicit values are still clamped by
    -- ModelConstraints.clampMaxTokens().

    -- Reasoning/Thinking: resolved per-model via the central resolver.
    -- Precedence: action reasoning_config > per-model pref > per-provider pref >
    -- global stance > model natural default. The resolver returns a normalized
    -- decision; applyReasoningParams emits the existing per-provider api_params
    -- keys (wire format unchanged), or NOTHING when the model should behave at its
    -- API default (stance "default" with no overrides). See model_constraints.lua
    -- and reasoning_prefs.lua.
    local provider = config.provider or config.default_provider or "anthropic"
    -- One model id per request (audit B3): the shared resolver, so reasoning is
    -- resolved for the model that will be sent (covers custom providers too,
    -- which Defaults.ProviderDefaults never did).
    local reasoning_model = ModelConstraints.dispatchModel({
        provider = provider, model = config.model, features = config.features })
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
    ensureReasoningHeadroom(config.api_params, provider, reasoning_decision)

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
            -- Per-chat view mode never rides a FRESH copy: it belongs to the
            -- chat that tapped it (continueChat restores it for resumed chats
            -- AFTER its own copy; tap re-sets it on this chat's config)
            if k == "features" then
                temp_config[k]._chat_view_mode = nil
            end
        end
    end
    
    -- Only override if provider/model are specified in the prompt
    if prompt.provider then
        temp_config.provider = prompt.provider
        if prompt.model then
            -- Clone before writing: the copy above is 2 levels deep, so the
            -- per-provider sub-table is still SHARED with the source config —
            -- a pin must not absorb into configuration.lua's provider_settings
            temp_config.provider_settings = temp_config.provider_settings or {}
            local ps = {}
            for k, v in pairs(temp_config.provider_settings[prompt.provider] or {}) do
                ps[k] = v
            end
            ps.model = prompt.model
            temp_config.provider_settings[prompt.provider] = ps
        end
    end

    return temp_config
end

-- Shared provider→model picker (module-level): used by the ⚡ menu's one-shot
-- model pick and by the Quick Answer preset's pinned-model pick. Key-filtered
-- like every quick picker (slice (a)): configured providers (+ the current pick,
-- marked), "Show all" reveals the rest, disarmed while no real key exists.
-- opts = { plugin, current = {provider, model}|nil,
--          top_row = { text, callback }|nil (prepended row, closes first),
--          on_pick(provider_id, model_name),
--          on_provider(provider_id, provider_label)|nil — when set, picking a
--            provider ends the flow here (no model stage; used by the Quick
--            preset's provider+tier pick),
--          provider_title|nil (title for the provider stage) }
local function pickProviderModel(opts)
    local ButtonDialog = require("ui/widget/buttondialog")
    local ModelLists = require("koassistant_model_lists")
    local plugin = opts.plugin
    local current = opts.current

    local function pickModelFor(provider_id, provider_label)
        local sub
        -- Built-in list, or for custom providers their default model + saved
        -- customs (same sources as the Quick Edit selector)
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
        for _idx, m in ipairs(models) do
            local model_name = m
            local is_current = current and current.provider == provider_id
                and current.model == model_name
            table.insert(buttons, {{
                text = (is_current and "● " or "○ ") .. model_name,
                callback = function()
                    UIManager:close(sub)
                    opts.on_pick(provider_id, model_name)
                end,
            }})
        end
        if #buttons == 0 then
            table.insert(buttons, {{ text = _("No models listed for this provider"), enabled = false }})
        end
        table.insert(buttons, {{ text = _("Cancel"), callback = function() UIManager:close(sub) end }})
        sub = ButtonDialog:new{
            title = T(_("Model · %1"), provider_label),
            buttons = buttons,
        }
        UIManager:show(sub)
    end

    local pickProvider
    pickProvider = function(show_all)
        local sub
        local buttons = {}
        if opts.top_row then
            table.insert(buttons, {{
                text = opts.top_row.text,
                callback = function()
                    UIManager:close(sub)
                    opts.top_row.callback()
                end,
            }})
        end
        local all_providers = {}
        for _idx, provider in ipairs(ModelLists.getAllProviders()) do
            local name = plugin and plugin.getProviderDisplayName
                and plugin:getProviderDisplayName(provider)
                or provider:gsub("^%l", string.upper)
            table.insert(all_providers, { id = provider, name = name })
        end
        if plugin and plugin.getCustomProviders then
            for _idx, cp in ipairs(plugin:getCustomProviders()) do
                if cp.id then
                    table.insert(all_providers, { id = cp.id, name = cp.name or cp.id, is_custom = true, config = cp })
                end
            end
        end
        table.sort(all_providers, function(a, b) return a.name:lower() < b.name:lower() end)
        local has_real_key = plugin and plugin.hasAnyRealApiKey and plugin:hasAnyRealApiKey()
        local hidden_count = 0
        for _idx, prov in ipairs(all_providers) do
            local configured = not has_real_key
                or plugin:isProviderConfigured(prov.id, prov.config)
            local is_current = current and current.provider == prov.id
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
                        if opts.on_provider then
                            opts.on_provider(prov_id, prov_name)
                        else
                            pickModelFor(prov_id, prov_name)
                        end
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
            title = opts.provider_title or _("Model · pick a provider"),
            buttons = buttons,
        }
        UIManager:show(sub)
    end

    pickProvider(false)
end

-- Quick Answer preset: model-component mode picker — Keep current / Fastest /
-- Tier for active provider / Specific pinned model (controls_parity_plan.md §2
-- round 3, maintainer: "more complete settings" + clearer provenance).
-- Persistent settings. Reachable from the preset editor AND main settings
-- (schema action row → AskGPT:showQuickPresetModelMode).
-- opts = { plugin, on_close }
local showQuickPresetModelMode
showQuickPresetModelMode = function(opts)
    local ButtonDialog = require("ui/widget/buttondialog")
    local plugin = opts.plugin
    local dialog
    local function mutate(fn)
        local f = plugin.settings:readSetting("features") or {}
        fn(f)
        plugin.settings:saveSetting("features", f)
        plugin.settings:flush()
        if plugin.updateConfigFromSettings then plugin:updateConfigFromSettings() end
    end
    local function finish()
        if opts.on_close then opts.on_close() end
    end
    local f = plugin.settings:readSetting("features") or {}
    local mode = f.quick_preset_model_mode or "none"
    local active_provider = (plugin.getCurrentProvider and plugin:getCurrentProvider()) or "anthropic"
    local function providerLabel(provider_id)
        return plugin.getProviderDisplayName
            and plugin:getProviderDisplayName(provider_id) or provider_id
    end

    -- pin = true stores the provider with the tier (quick_preset_tier_provider —
    -- the pick follows THAT provider's ladder regardless of the active one);
    -- pin = false/nil keeps the tier relative to the active provider.
    local function pickTier(provider_id, provider_label, pin)
        local ModelLists = require("koassistant_model_lists")
        local sub
        local buttons = {}
        local TIERS = {
            { id = "ultrafast", label = _("Ultrafast") },
            { id = "fast", label = _("Fast") },
            { id = "standard", label = _("Standard") },
            { id = "flagship", label = _("Flagship") },
            { id = "frontier", label = _("Frontier") },
        }
        for _idx, tier in ipairs(TIERS) do
            -- Not every provider lists every tier: show what the pick resolves
            -- to for THIS provider (EXACT — named tiers never walk, 2026-08-14;
            -- unlisted tiers show "(not available)" and stay unpickable)
            local resolved = ModelLists.getModelForTier(provider_id, tier.id, false)
            local is_current = mode == "tier"
                and ModelLists.normalizeTier(f.quick_preset_tier or "fast") == tier.id
                and f.quick_preset_tier_provider == (pin and provider_id or nil)
            local tier_id = tier.id
            table.insert(buttons, {{
                text = (is_current and "● " or "○ ")
                    .. (resolved and T(_("%1 (%2)"), tier.label, resolved)
                        or T(_("%1 (not available)"), tier.label)),
                enabled = resolved ~= nil,
                callback = function()
                    mutate(function(feats)
                        feats.quick_preset_model_mode = "tier"
                        feats.quick_preset_tier = tier_id
                        feats.quick_preset_tier_provider = pin and provider_id or nil
                    end)
                    UIManager:close(sub)
                    finish()
                end,
            }})
        end
        table.insert(buttons, {{ text = _("Cancel"), callback = function() UIManager:close(sub) end }})
        sub = ButtonDialog:new{
            title = T(_("Tier for %1"), provider_label),
            buttons = buttons,
        }
        UIManager:show(sub)
    end

    local function row(label, is_current, cb)
        return {{ text = (is_current and "● " or "○ ") .. label, callback = cb }}
    end
    dialog = ButtonDialog:new{
        title = _("Quick Answer preset · model"),
        -- Tap-outside behaves like Close (plugin tenet): return to the editor
        tap_close_callback = function() if opts.on_close then opts.on_close() end end,
        buttons = {
            row(_("Keep current model"), mode == "none", function()
                mutate(function(feats) feats.quick_preset_model_mode = "none" end)
                UIManager:close(dialog)
                finish()
            end),
            row(_("Fastest for active provider"), mode == "fastest", function()
                mutate(function(feats) feats.quick_preset_model_mode = "fastest" end)
                UIManager:close(dialog)
                finish()
            end),
            row((mode == "tier" and not f.quick_preset_tier_provider)
                    and T(_("Tier: %1 (change…)"),
                        require("koassistant_model_lists").normalizeTier(f.quick_preset_tier or "fast"))
                    or _("A tier of the active provider…"),
                mode == "tier" and not f.quick_preset_tier_provider, function()
                UIManager:close(dialog)
                pickTier(active_provider, providerLabel(active_provider), false)
            end),
            row((mode == "tier" and f.quick_preset_tier_provider)
                    and T(_("Tier: %1 · %2 (change…)"),
                        providerLabel(f.quick_preset_tier_provider),
                        require("koassistant_model_lists").normalizeTier(f.quick_preset_tier or "fast"))
                    or _("A provider + tier…"),
                mode == "tier" and f.quick_preset_tier_provider ~= nil, function()
                UIManager:close(dialog)
                -- Provider+tier combo: pinned provider, ladder-only resolution
                -- (mirrors the action provider+tier pin)
                pickProviderModel({
                    plugin = plugin,
                    current = f.quick_preset_tier_provider
                        and { provider = f.quick_preset_tier_provider } or nil,
                    provider_title = _("Tier · pick a provider"),
                    on_provider = function(provider_id, provider_label)
                        pickTier(provider_id, provider_label, true)
                    end,
                })
            end),
            row(mode == "model"
                    and T(_("Pinned: %1 (change…)"), f.quick_preset_model or "?")
                    or _("A specific model…"),
                mode == "model", function()
                UIManager:close(dialog)
                pickProviderModel({
                    plugin = plugin,
                    current = f.quick_preset_provider
                        and { provider = f.quick_preset_provider, model = f.quick_preset_model }
                        or nil,
                    on_pick = function(provider_id, model_name)
                        mutate(function(feats)
                            feats.quick_preset_model_mode = "model"
                            feats.quick_preset_provider = provider_id
                            feats.quick_preset_model = model_name
                        end)
                        finish()
                    end,
                })
            end),
            {{ text = _("Cancel"), callback = function() UIManager:close(dialog) end }},
        },
    }
    UIManager:show(dialog)
end

-- Label for the two-key brevity-nudge state (quick_preset_nudge on/off +
-- quick_preset_nudge_strict): ONE user-facing 3-way control, because the two
-- texts are mutually exclusive (maintainer 2026-08-11). Storage stays the two
-- keys — reads elsewhere are unchanged.
local function quickPresetNudgeLabel(features)
    local f = features or {}
    if f.quick_preset_nudge == false then return _("Off") end
    if f.quick_preset_nudge_strict == true then return _("Ultra-brief") end
    return _("Standard")
end

-- Quick Answer preset: brevity-nudge picker — Standard (soft wording, default)
-- / Ultra-brief (hard ceiling) / Off. Reachable from the preset editor AND
-- main settings (schema action row → AskGPT:showQuickPresetNudge).
-- opts = { plugin, on_close }
local showQuickPresetNudge
showQuickPresetNudge = function(opts)
    local ButtonDialog = require("ui/widget/buttondialog")
    local plugin = opts.plugin
    local dialog
    local function set(nudge, strict)
        local f = plugin.settings:readSetting("features") or {}
        f.quick_preset_nudge = nudge
        f.quick_preset_nudge_strict = strict
        plugin.settings:saveSetting("features", f)
        plugin.settings:flush()
        if plugin.updateConfigFromSettings then plugin:updateConfigFromSettings() end
        UIManager:close(dialog)
        if opts.on_close then opts.on_close() end
    end
    local f = plugin.settings:readSetting("features") or {}
    local cur = (f.quick_preset_nudge == false and "off")
        or (f.quick_preset_nudge_strict == true and "strict") or "standard"
    local function row(label, id, cb)
        return {{ text = (cur == id and "● " or "○ ") .. label, callback = cb }}
    end
    dialog = ButtonDialog:new{
        title = _("Quick Answer preset · brevity nudge"),
        tap_close_callback = function() if opts.on_close then opts.on_close() end end,
        buttons = {
            row(_("Standard (a few short sentences)"), "standard", function() set(true, nil) end),
            row(_("Ultra-brief (3 sentences max)"), "strict", function() set(true, true) end),
            row(_("Off"), "off", function() set(false, nil) end),
            {{ text = _("Cancel"), callback = function() UIManager:close(dialog) end }},
        },
    }
    UIManager:show(dialog)
end

-- Label for the quick_preset_behavior value (shared: preset editor row + the
-- schema action row's text_func via Dialogs export).
local function quickPresetBehaviorLabel(features)
    local qb = (features or {}).quick_preset_behavior
    if not qb or qb == "keep" then return _("Keep current") end
    if qb == "none" then return _("None") end
    if qb == "mini_of_current" then return _("Mini of current style") end
    local SystemPrompts = require("prompts.system_prompts")
    local b = SystemPrompts.getBehaviorById(qb, (features or {}).custom_behaviors)
    return b and (b.display_name or b.name or qb) or T(_("%1 (missing)"), qb)
end

-- Quick Answer preset: behavior component picker (A6 rework, maintainer
-- 2026-08-11: off by default — "you can turn it on or select a behavior or
-- None instead"). Keep current / Mini of current (§11 family swap) / a
-- specific behavior (built-in terse is the intended pick; specialized
-- action-pinned behaviors filtered out) / None. Persistent settings; reachable
-- from the preset editor AND main settings (schema action row →
-- AskGPT:showQuickPresetBehavior).
-- opts = { plugin, on_close }
local showQuickPresetBehavior
showQuickPresetBehavior = function(opts)
    local ButtonDialog = require("ui/widget/buttondialog")
    local plugin = opts.plugin
    local dialog
    local function mutate(fn)
        local f = plugin.settings:readSetting("features") or {}
        fn(f)
        plugin.settings:saveSetting("features", f)
        plugin.settings:flush()
        if plugin.updateConfigFromSettings then plugin:updateConfigFromSettings() end
    end
    local function finish()
        if opts.on_close then opts.on_close() end
    end
    local f = plugin.settings:readSetting("features") or {}
    local qb = f.quick_preset_behavior or "keep"

    local function setMode(value)
        mutate(function(feats) feats.quick_preset_behavior = value end)
        UIManager:close(dialog)
        finish()
    end

    local function pickBehavior()
        local SystemPrompts = require("prompts.system_prompts")
        local behaviors = SystemPrompts.getSortedBehaviors(f.custom_behaviors) or {}
        local sub
        local buttons = {}
        for _idx, b in ipairs(behaviors) do
            if not b.specialized then
                local bid = b.id
                table.insert(buttons, {{
                    text = (qb == bid and "● " or "○ ") .. (b.display_name or b.name or bid),
                    callback = function()
                        mutate(function(feats) feats.quick_preset_behavior = bid end)
                        UIManager:close(sub)
                        finish()
                    end,
                }})
            end
        end
        table.insert(buttons, {{ text = _("Cancel"), callback = function() UIManager:close(sub) end }})
        sub = ButtonDialog:new{
            title = _("Quick Answer behavior · pick"),
            buttons = buttons,
        }
        UIManager:show(sub)
    end

    local function row(label, is_current, cb)
        return {{ text = (is_current and "● " or "○ ") .. label, callback = cb }}
    end
    -- Terse gets a direct row (maintainer 2026-08-17): the intended pick, one
    -- tap instead of the behavior list. Stored value is the same "terse" id the
    -- picker would set, so the two stay in agreement — and it is excluded from
    -- the pinned state below so only its own row dots for it.
    local pinned = qb ~= "keep" and qb ~= "none" and qb ~= "mini_of_current" and qb ~= "terse"
    dialog = ButtonDialog:new{
        title = _("Quick Answer preset · behavior"),
        tap_close_callback = function() if opts.on_close then opts.on_close() end end,
        buttons = {
            row(_("Keep current behavior"), qb == "keep", function() setMode(nil) end),
            row(_("Mini version of current style"), qb == "mini_of_current", function()
                setMode("mini_of_current")
            end),
            row(_("Terse"), qb == "terse", function() setMode("terse") end),
            row(pinned
                    and T(_("Behavior: %1 (change…)"), quickPresetBehaviorLabel(f))
                    or _("A specific behavior…"),
                pinned, function()
                UIManager:close(dialog)
                pickBehavior()
            end),
            row(_("None (no behavior layer)"), qb == "none", function() setMode("none") end),
            {{ text = _("Cancel"), callback = function() UIManager:close(dialog) end }},
        },
    }
    UIManager:show(dialog)
end

-- Quick Answer preset editor — persistent GLOBAL settings for what the ⚡ tap
-- applies (controls_parity_plan.md §2, maintainer 2026-07-19). Reachable from
-- main settings (Chat & Export → Quick Answer Preset — schema is the source of
-- the defaults) and from the ⚡ chip / reply-window hold picker ("Preset
-- settings…" row on the book/global default popup). Rebuilds
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
    -- opt_in = keys whose schema default is FALSE (== true check pattern);
    -- default rows keep the ~= false opt-out shape.
    local function toggleRow(label, key, opt_in)
        local on
        if opt_in then on = f[key] == true else on = f[key] ~= false end
        return {{
            text = (on and "✓ " or "○ ") .. label,
            callback = function()
                mutate(function(feats) feats[key] = not on end)
            end,
        }}
    end
    local mode = f.quick_preset_model_mode or "none"
    local model_mode_label
    if mode == "fastest" then
        model_mode_label = _("Fastest for provider")
    elseif mode == "tier" then
        local tier_label = require("koassistant_model_lists")
            .normalizeTier(f.quick_preset_tier or "fast")
        if f.quick_preset_tier_provider then
            local prov = f.quick_preset_tier_provider
            model_mode_label = T(_("%1 · %2 tier"),
                plugin.getProviderDisplayName
                    and plugin:getProviderDisplayName(prov) or prov,
                tier_label)
        else
            model_mode_label = T(_("%1 tier"), tier_label)
        end
    elseif mode == "model" then
        model_mode_label = f.quick_preset_model or "?"
    else
        model_mode_label = _("Keep current")
    end
    dialog = ButtonDialog:new{
        title = _("Quick Answer preset · applies while Quick Answer is on"),
        -- Tap-outside dismissal must fire on_close too, or the dialog beneath
        -- keeps stale state (showSessionChipsManager precedent)
        tap_close_callback = function()
            if opts.on_close then opts.on_close() end
        end,
        buttons = {
            {{
                text = T(_("Brevity nudge: %1"), quickPresetNudgeLabel(f)),
                callback = function()
                    UIManager:close(dialog)
                    showQuickPresetNudge({
                        plugin = plugin,
                        on_close = function() showQuickPresetEditor(opts) end,
                    })
                end,
            }},
            toggleRow(_("Reasoning off"), "quick_preset_reasoning_off"),
            toggleRow(_("Web search off"), "quick_preset_web_off"),
            toggleRow(_("Book tools off"), "quick_preset_tools_off"),
            toggleRow(_("Skip domain lens"), "quick_preset_skip_domain", true),
            toggleRow(_("Skip book background"), "quick_preset_skip_background", true),
            {{
                text = T(_("Behavior: %1"), quickPresetBehaviorLabel(f)),
                callback = function()
                    UIManager:close(dialog)
                    showQuickPresetBehavior({
                        plugin = plugin,
                        on_close = function() showQuickPresetEditor(opts) end,
                    })
                end,
            }},
            {{
                text = T(_("Model: %1"), model_mode_label),
                callback = function()
                    UIManager:close(dialog)
                    showQuickPresetModelMode({
                        plugin = plugin,
                        on_close = function() showQuickPresetEditor(opts) end,
                    })
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

-- Every api_params key applyReasoningParams can emit, plus the decision record.
-- The reply-override re-bake must wipe these before re-applying — a stale
-- same-provider key (e.g. thinking={enabled}) would survive a send_nothing/off
-- decision (applyReasoningParams only writes, never clears).
local REASONING_WIRE_KEYS = ModelConstraints.REASONING_WIRE_KEYS

-- Reply-time Quick overrides (controls parity §8c, "live parts only" decision
-- 2026-07-20): applies the chip/menu state on the chat's config
-- (features._session_quick_answer / _session_reasoning / _session_model) at
-- reply dispatch — model, reasoning, and the preset's web/tools-off. The Quick
-- Answer NUDGE is deliberately NOT retro-applied (the system prompt is baked at
-- chat creation — the "baked class" stays a chat-creation control).
-- IDEMPOTENT: the first application stashes the chat's baseline
-- (features._quick_reply_orig); every later call restores the baseline before
-- applying the current picks, so clearing a pick honestly reverts the chat.
-- Callers MUST pass a config private to the chat (never the shared module
-- table) and should run this BEFORE applying the explicit reply Web/Tools
-- toggles so those still win over the preset. `plugin` is used only to
-- resolve the CURRENT global provider/model for the {follow=true} model
-- sentinel (reply-time "Global setting" pick on a baked-model chat).
local function applyQuickReplyOverrides(config, plugin)
    local f = config and config.features
    if not f then return end
    local qa = f._session_quick_answer == true
    -- Explicit false counts as a pick: it COUNTERACTS a chat that was CREATED
    -- under the ⚡ posture (reasoning re-resolves from prefs/stance instead of
    -- the baked quick-off) — the baked config has no pre-quick state to
    -- restore, so "off" must be an active re-resolution, not just a revert.
    local has_picks = f._session_quick_answer ~= nil
        or f._session_reasoning ~= nil or f._session_model ~= nil
    if not has_picks and not f._quick_reply_orig then return end

    local orig = f._quick_reply_orig
    if not orig then
        orig = {
            provider = config.provider,
            model = config.model,
            provider_settings = config.provider_settings,
            enable_web_search = config.enable_web_search,
            tools_active = f._tools_active,
            api_params = {},
        }
        for k, v in pairs(config.api_params or {}) do orig.api_params[k] = v end
        f._quick_reply_orig = orig
    end
    -- Restore the baseline (idempotent base for the current picks)
    config.provider = orig.provider
    config.model = orig.model
    config.provider_settings = orig.provider_settings
    config.enable_web_search = orig.enable_web_search
    f._tools_active = orig.tools_active
    config.api_params = {}
    for k, v in pairs(orig.api_params) do config.api_params[k] = v end
    if not has_picks then
        -- Fully reverted; drop the stash so a later pick re-stashes fresh.
        f._quick_reply_orig = nil
        return
    end

    -- Model: manual menu pick > Quick preset model mode (fastest/tier/pinned).
    -- Re-pin to the CURRENT GLOBAL selection when either (a) the {follow=true}
    -- sentinel is set (reply-time "Use global setting" pick), or (b) ⚡ was
    -- toggled OFF with no explicit pick — ⚡ OFF must undo the preset's model
    -- switch too (maintainer 2026-07-20: a quick chat's baked config IS the
    -- quick state, so "off" re-derives from globals — and thereby follows a
    -- global provider change). Only an explicit per-chat pick pins a model.
    local model_override = f._session_model
    local qa_off = f._session_quick_answer == false
    if (model_override and model_override.follow) or (qa_off and not model_override) then
        local gp = plugin and plugin.getCurrentProvider and plugin:getCurrentProvider()
        local gm = plugin and plugin.getCurrentModel and plugin:getCurrentModel()
        model_override = gp and { provider = gp, model = gm } or nil
    end
    if not model_override and qa then
        model_override = resolveQuickPresetModel(f,
            config.provider or config.default_provider or "anthropic")
    end
    if model_override and model_override.provider then
        config.provider = model_override.provider
        -- model may be NIL (provider+tier pin whose exact tier the provider
        -- lacks): clear the top level, leave the bucket — the pinned provider's
        -- own configured/default model applies (same shape as the bake site)
        config.model = model_override.model
        if model_override.model then
            -- Copy-on-write: never mutate the original provider_settings tables
            -- (they can be shared with the module config / configuration.lua).
            local new_ps = {}
            for prov, entry in pairs(orig.provider_settings or {}) do new_ps[prov] = entry end
            local entry = {}
            for k, v in pairs(new_ps[config.provider] or {}) do entry[k] = v end
            entry.model = model_override.model
            new_ps[config.provider] = entry
            config.provider_settings = new_ps
        end
    end

    -- Preset "no slow features" (only under the ⚡ posture; explicit reply
    -- toggles are applied after this by the callers and win). Pin-beats-preset
    -- (A9 (b) verify round 2026-08-17): a facet PINNED in the input dialog
    -- rides in as a touch mark on the chat's config copy — the preset stands
    -- down and the stashed baseline (the pinned value) survives replies.
    if quickPresetForces("web", qa, f) then
        config.enable_web_search = false
    end
    if quickPresetForces("tools", qa, f) then
        f._tools_active = false
    end

    -- Reasoning: wipe the wire keys, then re-resolve for the (possibly new)
    -- model. Same layering as the Send-time bake minus the action layer — a
    -- reply-time pick is the user's most explicit signal for THIS chat.
    for _idx, key in ipairs(REASONING_WIRE_KEYS) do config.api_params[key] = nil end
    local provider = config.provider or config.default_provider or "anthropic"
    -- One model id per request (audit B3): the shared resolver (see the bake).
    local model = ModelConstraints.dispatchModel({
        provider = provider, model = config.model, features = config.features })
    -- {follow=true} sentinel = reply-time "Follow settings" pick on a chat with
    -- a baked reasoning override: resolve WITHOUT a session layer (prefs/stance).
    local sr = f._session_reasoning
    if sr and sr.follow then sr = nil end
    local decision = ModelConstraints.resolveReasoning(provider, model, {
        global_stance = ReasoningPrefs.getStance(f),
        model_pref = ReasoningPrefs.getModelPref(f, provider, model),
        session_override = sr
            or ((qa and f.quick_preset_reasoning_off ~= false) and { force = "off" } or nil),
    })
    config.api_params._reasoning = decision
    ModelConstraints.applyReasoningParams(provider, config.api_params, decision)
    ensureReasoningHeadroom(config.api_params, provider, decision)
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
    local logger = require("koassistant_logger")
    logger.dbg("getAllPrompts: context = " .. context .. ", has_open_book = " .. tostring(has_open_book))

    -- Use ActionService if available, fallback to PromptService
    local service = plugin and (plugin.action_service or plugin.prompt_service)
    if service then
        local service_prompts
        -- For general context, use the filtered general menu list
        -- (users can add/remove actions via Action Manager)
        if context == "general" and service.getGeneralMenuActionObjects then
            service_prompts = service:getGeneralMenuActionObjects()
            logger.dbg("getAllPrompts: Got " .. #service_prompts .. " prompts from general menu list")
        else
            service_prompts = service:getAllPrompts(context, false, has_open_book)
            logger.dbg("getAllPrompts: Got " .. #service_prompts .. " prompts from " ..
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
                                logger.dbg("KOAssistant: Saving chat with metadata - title: " .. (book_metadata.title or "nil") .. ", author: " .. (book_metadata.author or "nil"))
                            else
                                logger.dbg("KOAssistant: No book metadata available for save")
                            end

                            -- Add launch context if available (for general chats launched from a book)
                            if launch_context then
                                metadata.launch_context = launch_context
                                logger.dbg("KOAssistant: Saving chat with launch context - from: " .. (launch_context.title or "nil"))
                            end

                            -- Store highlighted text for display toggle in continued chats
                            if highlighted_text and highlighted_text ~= "" then
                                metadata.original_highlighted_text = highlighted_text
                            end

                            -- Group stamp (item 48(a)): label group-launched library chats
                            do
                                local cf = config and config.features
                                local gl = cf and cf.is_library_context and cf._group_launch
                                if gl then
                                    metadata.group_launch = { id = gl.id, name = gl.name }
                                end
                            end

                            -- Check storage version and route to appropriate method
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
                                launched_from = history.launched_from,
                                launch_context = metadata.launch_context,
                                domain = metadata.domain,
                                tags = existing_tags,
                                starred = existing_starred,
                                original_highlighted_text = metadata.original_highlighted_text,
                                -- Store system prompt metadata for debug display
                                system_metadata = config and config.system,
                                -- Per-chat control state — resume reactivates it (parity §8c)
                                control_state = chat_history_manager.captureControlState(config),
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
                                        features.auto_save_all_chats ~= false or
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
-- NOTE: pre-existing dead code (zero callers as of 2026-08-15 — the live export
-- path is koassistant_export.lua). Kept per repo convention; role branding fixed
-- alongside the debug-panel fix so it isn't a landmine for a future caller.
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
        local role = msg.role == "assistant" and "KOAssistant"
            or msg.role:gsub("^%l", string.upper)
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
            render_markdown_override = state.render_markdown,
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
        scroll_to_last_question = not (temp_config and temp_config.features and temp_config.features.scroll_to_last_message == false)
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

            -- Reply-time Quick overrides (parity §8c, "live parts"): the chat's
            -- cfg can share identity with the module config (freeform chats
            -- without Send-time overrides), so REBASE onto a private copy on
            -- first use, then apply model/reasoning/preset picks. Runs BEFORE
            -- the explicit Web/Tools reply toggles below so those still win.
            do
                local qf = cfg.features
                -- Presence checks, NOT truthiness: ⚡ OFF is an EXPLICIT false
                -- (counteract) and must reach the helper — truthiness here
                -- silently skipped it and the baked quick model went out
                -- unchanged (maintainer device log 2026-07-20).
                if qf and (qf._session_quick_answer ~= nil
                    or qf._session_reasoning ~= nil
                    or qf._session_model ~= nil
                    or qf._quick_reply_orig ~= nil) then
                    if not qf._quick_reply_private then
                        local copy = {}
                        for k, v in pairs(cfg) do
                            if type(v) ~= "table" then
                                copy[k] = v
                            else
                                copy[k] = {}
                                for k2, v2 in pairs(v) do copy[k][k2] = v2 end
                            end
                        end
                        copy.features = copy.features or {}
                        copy.features._quick_reply_private = true
                        -- The picks now live on the copy — strip them from the
                        -- source so a shared module config can't leak them into
                        -- later chats (fresh-open clears are the backstop).
                        qf._session_quick_answer = nil
                        qf._chat_view_mode = nil
                        qf._session_reasoning = nil
                        qf._session_model = nil
                        qf._quick_reply_orig = nil
                        viewer.configuration = copy
                        cfg = copy
                    end
                    -- Runtime self-require on purpose (zero new upvalues — the
                    -- enclosing closures sit near LuaJIT's 60-upvalue cap).
                    require("koassistant_dialogs").applyQuickReplyOverrides(cfg, plugin)
                end
            end

            -- Apply session web search override if set on the viewer
            -- This allows per-query toggling of web search from the Reply dialog
            if viewer.session_web_search_override ~= nil then
                cfg.enable_web_search = viewer.session_web_search_override
            end
            -- Apply session tools override (Reply-dialog Tools toggle — parity
            -- slice (b)): _tools_active is read at dispatch by
            -- BookToolRunner.shouldUse; explicit true/false, overriding the baked
            -- per-chat flag for this chat's replies.
            if viewer.session_tools_override ~= nil then
                cfg.features = cfg.features or {}
                cfg.features._tools_active = viewer.session_tools_override
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

                    -- A8 landing rule (maintainer 2026-08-12: streamed replies too —
                    -- round 1's streamed-keeps-bottom carve-out is REVERTED): every
                    -- follow-up reply lands at the START of the new exchange (last
                    -- "▶ User:" turn). During streaming the view still follows the
                    -- growing text; the completion viewer then re-anchors on the
                    -- exchange. The scroll_to_last_message toggle keeps governing the
                    -- OPEN/resume paths only.
                    local to_last_question = history and history.getAssistantTurnCount
                        and history:getAssistantTurnCount() > 1
                    logger.dbg("KOAssistant: reply landing — to_last_question:",
                        to_last_question and true or false)
                    -- Create a new viewer with updated content
                    local new_viewer = ChatGPTViewer:new {
                        title = title .. " (" .. model_info .. ")",
                        text = history:createResultText(highlightedText, viewer_cfg),
                        configuration = viewer_cfg,  -- Use viewer's config to maintain state after expand
                        scroll_to_last_question = to_last_question,
                        scroll_to_bottom = not to_last_question,
                        -- Per-chat view mode survives the reply — the config
                        -- table can't carry it (settings re-merge), see
                        -- ChatGPTViewer init's override-first rule
                        render_markdown_override = viewer.render_markdown,
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
                        session_tools_override = viewer.session_tools_override,  -- Preserve session override
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
                        logger.dbg("KOAssistant: onAskQuestion fallback render — ActiveChatViewer slot changed under an in-flight reply")
                        local viewer_cfg = target.configuration or temp_config or CONFIGURATION
                        -- Same A8 landing rule as the main branch: land on the exchange
                        target:update(history:createResultText(highlightedText, viewer_cfg), false)
                        if target.scrollToLastQuestion then
                            UIManager:scheduleIn(0.15, function()
                                if target.scroll_text_w then target:scrollToLastQuestion() end
                            end)
                        end
                    else
                        logger.warn("KOAssistant: onAskQuestion could not render the reply into a live viewer for this chat")
                    end
                end
            end

            -- Attach chip on replies (parity slice (b)): staged attachments ride as
            -- their own is_context message BEFORE the reply turn, then the module
            -- list is cleared so the next reply doesn't re-attach (a reply has no
            -- fresh-dialog-open to clear it, unlike the input dialog). Inline require
            -- (60-upvalue cap). The list is empty unless the user staged via the reply
            -- Attach chip — every initial-send site consume-and-clears.
            do
                local A = require("koassistant_attachments")
                local attach_msg = A.buildMessage(A.getList())
                if attach_msg then
                    history:addUserMessage(attach_msg, true)
                    A.clear()
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
                        cfg.features.auto_save_all_chats ~= false or
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
                        -- Group stamp (item 48(a)): label group-launched library chats
                        local gl = cfg.features.is_library_context and cfg.features._group_launch
                        if gl then
                            metadata.group_launch = { id = gl.id, name = gl.name }
                        end

                        -- Determine save path: check for action storage_key override
                        local storage_key = cfg.features and cfg.features.storage_key
                        local save_path
                        local should_save = true
                        local is_library = cfg.features.is_library_context or false

                        if storage_key == "__SKIP__" then
                            -- Don't save this chat
                            should_save = false
                            logger.dbg("KOAssistant: Skipping auto-save due to storage_key = __SKIP__")
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
                            logger.dbg("KOAssistant: Chat not saved (storage_key = __SKIP__)")
                        else
                            local save_result
                            -- Check storage version and route to appropriate method
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
                                launched_from = history.launched_from,
                                launch_context = metadata.launch_context,
                                domain = metadata.domain,
                                tags = existing_tags,
                                starred = existing_starred,
                                original_highlighted_text = metadata.original_highlighted_text,
                                -- Store system prompt metadata for debug display
                                system_metadata = cfg.system,
                                -- Per-chat control state — resume reactivates it (parity §8c)
                                control_state = chat_history_manager.captureControlState(cfg),
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

                            if save_result and save_result ~= false then
                                -- Store the chat ID in history for future saves (prevents duplicates)
                                if not history.chat_id then
                                    history.chat_id = save_result
                                end
                                -- Mark chat as saved so auto_save_chats applies to future replies
                                if cfg.features then
                                    cfg.features.chat_saved = true
                                end
                                logger.dbg("KOAssistant: Auto-saved chat after follow-up with id: " .. tostring(save_result))
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
                -- Group stamp (item 48(a)): label group-launched library chats
                do
                    local tf = temp_config and temp_config.features
                    local gl = tf and tf.is_library_context and tf._group_launch
                    if gl then
                        metadata.group_launch = { id = gl.id, name = gl.name }
                    end
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
                        launched_from = history.launched_from,
                        launch_context = metadata.launch_context,
                        domain = metadata.domain,
                        tags = existing_tags,
                        starred = existing_starred,
                        original_highlighted_text = metadata.original_highlighted_text,
                        -- Store system prompt metadata for debug display
                        system_metadata = viewer_config and viewer_config.system,
                        -- Per-chat control state — resume reactivates it (parity §8c)
                        control_state = chat_history_manager.captureControlState(viewer_config),
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
                        viewer_features.auto_save_all_chats ~= false or
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
            elseif temp_config and temp_config.features and temp_config.features.auto_save_all_chats ~= false then
                UIManager:show(InfoMessage:new{
                    text = T("Auto-save all chats is on - this can be changed in the settings"),
                    timeout = 3,
                })
            else
                -- First-time manual save with dialog (no chat_id yet). Use the
                -- viewer's LIVE config, not the creation-time temp_config: the
                -- first reply-time Quick pick rebases viewer.configuration to a
                -- new copy and strips the session state from the old table —
                -- capturing control_state from temp_config would save nothing
                -- (round-2 gate CONFIRMED-2).
                local is_general_context = temp_config and temp_config.features and temp_config.features.is_general_context or false
                createSaveDialog(document_path, history, chat_history_manager, is_general_context, book_metadata, launch_context, highlightedText, ui_instance, (viewer and viewer.configuration) or temp_config)
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

    -- Minimal popup view (Minimal Popup settings): registered highlight actions
    -- open their response in a chrome-less popup next to the selection; tapping
    -- it opens this full viewer. Eligibility (registration, highlight launch,
    -- not full-page translate) was decided at dispatch (createTempConfig,
    -- _minimal_popup_eligible); the fit decision is made HERE because it needs
    -- the finished response ("When it fits" = only_if_fits below — the popup
    -- reports whether the whole response renders without the ellipsis, so
    -- script density and font size are handled by construction). The viewer is
    -- fully built either way — the popup only defers showing it, so expand
    -- keeps every callback/history wire intact and dismissing leaves
    -- ActiveChatViewer untouched (no restore needed: it was never claimed).
    local mp_f = temp_config and temp_config.features
    local use_minimal_popup = mp_f and mp_f._minimal_popup_eligible == true
        and not mp_f.is_full_page_translate
    if use_minimal_popup then
        -- Dict-window guard: a DictQuickLookup on screen covers the book, so an
        -- anchored popup buys nothing there (and drops the compact viewer's
        -- dict buttons for nothing) — skip whenever one is open at show time.
        -- Launches where the book is visible (highlight menu, dictionary
        -- bypass, gesture) keep the popup. State is checked at RESPONSE time,
        -- so a dict window closed while the request ran correctly un-skips.
        local ok_dql, DictQuickLookup = pcall(require, "ui/widget/dictquicklookup")
        if ok_dql and DictQuickLookup and DictQuickLookup.window_list
                and #DictQuickLookup.window_list > 0 then
            use_minimal_popup = false
        end
    end
    -- The dispatch gate disabled streaming for the popup's own request only;
    -- REPLIES are a regular chat and must follow the user's streaming setting
    -- again. Restore BEFORE any show path: most popup-registered actions build
    -- a plain viewer whose Reply is immediate, so the expand-button resets
    -- never run for them (device 2026-08-17). Spelled out, not
    -- `cond and false or nil` (that idiom always yields nil).
    if mp_f and mp_f._minimal_popup_eligible then
        local gf = plugin and plugin.settings
            and plugin.settings:readSetting("features")
        if gf and gf.enable_streaming == false then
            mp_f.enable_streaming = false
        else
            mp_f.enable_streaming = nil
        end
    end
    local popup_shown = false
    if use_minimal_popup then
        popup_shown = require("koassistant_minimal_popup").showForResponse({
            history = history,
            selection_data = selection_data,
            ui = ui_instance,
            only_if_fits = (mp_f.minimal_popup_mode or "short") == "short",
            -- RTL hint: translate renders in the translation language, the
            -- dictionary family in the dictionary language; anything else
            -- auto-detects (dominant-RTL, same gate as the standard chat view).
            rtl_language = (use_translate_view and mp_f.translation_language)
                or ((use_compact_view or use_dictionary_view) and mp_f.dictionary_language)
                or nil,
            -- Text-mode settings + the dict-family gate for the IPA bidi fix:
            -- the popup renders through the viewer's shared text-mode pipeline
            -- and honors the same settings (strip_markdown_in_text_mode,
            -- rtl_chat_text_mode).
            features = mp_f,
            is_dictionary = (use_compact_view or use_dictionary_view) or nil,
            on_expand = function()
                _G.ActiveChatViewer = chatgpt_viewer
                UIManager:show(chatgpt_viewer)
            end,
        })
    end
    if not popup_shown then
        -- Set global reference
        _G.ActiveChatViewer = chatgpt_viewer

        -- Show the viewer
        UIManager:show(chatgpt_viewer)
    end

    -- Auto-save if enabled
    if temp_config and temp_config.features and temp_config.features.auto_save_all_chats ~= false then
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
            -- Group stamp (item 48(a)): label group-launched library chats
            local gl = temp_config.features.is_library_context and temp_config.features._group_launch
            if gl then
                metadata.group_launch = { id = gl.id, name = gl.name }
            end

            -- Determine save path: check for action storage_key override
            local storage_key = temp_config.features and temp_config.features.storage_key
            local save_path
            local should_save = true
            local is_library = temp_config.features.is_library_context or false

            if storage_key == "__SKIP__" then
                -- Don't save this chat
                should_save = false
                logger.dbg("KOAssistant: Skipping auto-save due to storage_key = __SKIP__")
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
                    launched_from = history.launched_from,
                    launch_context = metadata.launch_context,
                    domain = metadata.domain,
                    tags = existing_tags,
                    starred = existing_starred,
                    original_highlighted_text = metadata.original_highlighted_text,
                    -- Store system prompt metadata for debug display
                    system_metadata = temp_config.system,
                    -- Per-chat control state — resume reactivates it (parity §8c)
                    control_state = chat_history_manager.captureControlState(temp_config),
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

                if result and result ~= false then
                    -- Store the chat ID in history for future saves (prevents duplicates)
                    if not history.chat_id then
                        history.chat_id = result
                    end
                    -- Mark as saved so auto_save_chats applies to future replies
                    temp_config.features.chat_saved = true
                    logger.dbg("KOAssistant: Auto-saved chat with id: " .. tostring(result) .. ", title: " .. suggested_title)
                else
                    logger.warn("KOAssistant: Failed to auto-save chat")
                end
            else
                logger.dbg("KOAssistant: Chat not saved (storage_key = __SKIP__)")
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
        -- temp_config for dialog launches, where they are the chat's live state).
        config.features._quick_answer_active = nil
        config.features._reasoning_override_active = nil
        config.features._model_override_active = nil
        config.features._session_quick_answer = nil
        config.features._chat_view_mode = nil
        config.features._session_reasoning = nil
        config.features._session_model = nil
    end
    -- DIRECT entries (highlight menu / gestures / QA tiles — no dialog) must not
    -- inherit chip state: a reply-⚡ write on a shared-identity chat config can
    -- leave _session_* on the shared table, and the copy above would hand it to
    -- this unrelated chat, whose replies would then silently apply it
    -- (round-2 gate CONFIRMED-1). The just-in-time *_active consumables are the
    -- dialog-launch signature — absent all three, this is a direct entry.
    do
        local tf = temp_config.features
        if tf and tf._quick_answer_active == nil
            and tf._reasoning_override_active == nil
            and tf._model_override_active == nil then
            tf._session_quick_answer = nil
            tf._session_reasoning = nil
            tf._session_model = nil
            -- Quick-pin touch marks are dialog-scoped (A9 (b) verify round):
            -- inherited stale marks would exempt a facet from the preset on a
            -- direct-entry quick request (bypass wrappers copy features wholesale)
            tf._session_web_touched = nil
            tf._session_tools_touched = nil
            -- Quick Answer DEFAULT reaches direct entries too (maintainer
            -- 2026-08-11: "if quick mode global is on it should touch all
            -- receptive requests regardless of entry point"). The dialog seeds
            -- its ⚡ chip from this resolver at open; a direct launch has no
            -- chip, so seed the request here — accept-gated, so only the
            -- Explain-family opt-ins are receptive. Both keys go on the REQUEST
            -- config: the consumable applies the preset at bake, the session
            -- key greys the stream ⚡ (quick_already_active) and keeps replies
            -- quick, exactly like a dialog-launched quick chat.
            if prompt and prompt.accept_quick_answer == true
                and require("koassistant_book_settings")
                    .resolveQuickAnswerDefault(
                        require("koassistant_doc_settings").resolve((tf.book_metadata or {}).file, ui)
                            or (ui and ui.doc_settings), tf) then
                tf._quick_answer_active = true
                tf._session_quick_answer = true
            end
        end
    end
    -- Minimal popup: consume its dispatch-scoped transients. The block further
    -- down re-derives them for THIS action, but only when the action is
    -- REGISTERED — so an inherited copy (viewer config → switchToAction /
    -- executeDirectAction → here) would otherwise survive untouched and label the
    -- loading window with the previous action's name, keep streaming off, and
    -- route an unregistered action into the popup (registry bypass).
    do
        local tf = temp_config.features
        if tf then
            -- Per-request by nature: whoever wants a custom notice sets it below.
            tf.loading_message = nil
            if tf._minimal_popup_eligible then
                tf._minimal_popup_eligible = nil
                -- Streaming was forced off by the popup dispatch, not chosen by the
                -- user. Restore the GLOBAL setting rather than nil'ing: nil reads as
                -- "on" everywhere (`enable_streaming ~= false`), so it would switch
                -- streaming back on for someone who keeps it off. The per-view
                -- dictionary/translate blocks re-apply their own overrides below.
                -- Spelled out, not `cond and false or nil`: that idiom ALWAYS
                -- yields nil, because `false or nil` is nil.
                local gf = plugin and plugin.settings
                    and plugin.settings:readSetting("features")
                if gf and gf.enable_streaming == false then
                    tf.enable_streaming = false
                else
                    tf.enable_streaming = nil
                end
            end
        end
    end
    -- Per-action model tier (item 18e): undo a previous action's baked tier model.
    -- The hint is per-action, but buildUnifiedRequestConfig writes the RESOLVED
    -- model onto the dispatch config; inherited, it outlives the action that asked
    -- for it (quick_define's fast model answering a dictionary action). This
    -- dispatch re-bakes below if its own action carries a hint.
    do
        local tf = temp_config.features
        if tf and tf._tier_model_prev ~= nil then
            local prev, prev_ps = tf._tier_model_prev, tf._tier_model_prev_ps
            local prev_prov = tf._tier_model_prev_provider
            local orig_provider = tf._tier_prev_provider
            local installed = tf._tier_installed_provider
            tf._tier_model_prev, tf._tier_model_prev_ps = nil, nil
            tf._tier_model_prev_provider = nil
            tf._tier_prev_provider, tf._tier_installed_provider = nil, nil
            -- The stash is only valid for the provider it was made under. If THIS
            -- action pinned a different provider (createTempConfig already applied
            -- it), the stashed model is a foreign id — drop the stash, the pinned
            -- provider's own defaults apply. nil prev_prov = pre-guard stash from
            -- a live config; same-provider was the only shape then, so restore.
            local valid
            if orig_provider ~= nil then
                -- Cross-provider stash (a GLOBAL tier pin moved the dispatch):
                -- valid only while the config still sits on the installed provider
                -- AND this action didn't pin its own (a pin — even to the same
                -- provider — wins; restoring would clobber it).
                valid = temp_config.provider == installed
                    and not (prompt and prompt.provider)
            else
                valid = prev_prov == nil or prev_prov == temp_config.provider
            end
            if valid then
                if orig_provider ~= nil then
                    temp_config.provider = (orig_provider ~= false) and orig_provider or nil
                end
                temp_config.model = (prev ~= false) and prev or nil
                -- Restore into the bucket the bake clobbered (prev_prov = the
                -- provider the stash was made under — equals temp_config.provider
                -- in the same-provider shape, the PIN provider in the cross shape).
                local prov = prev_prov or temp_config.provider
                local ps_src = prov and temp_config.provider_settings
                    and temp_config.provider_settings[prov]
                if ps_src then
                    -- Clone before writing: createTempConfig's copy is 2 levels deep,
                    -- so this per-provider sub-table is still SHARED with the source.
                    local ps = {}
                    for k, v in pairs(ps_src) do ps[k] = v end
                    ps.model = (prev_ps ~= false) and prev_ps or nil
                    temp_config.provider_settings[prov] = ps
                end
            end
        end
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
    -- Version ladder build (xray_ecosystem_plan.md §6 slice 1, ref #73 #90): consume
    -- the chain's per-rung transients from the SOURCE config (the fire path passes a
    -- config COPY, but consume defensively — same staleness rule as above). All
    -- downstream reads go through message_data fields set below (message_data is
    -- already captured by the closures here — 60-upvalue cap).
    local ladder_build_flag = config and config.features and config.features._ladder_build
    local ladder_target = config and config.features and tonumber(config.features._ladder_target_ratio)
    local ladder_base = config and config.features and config.features._ladder_base
    local ladder_chapter_label = config and config.features and config.features._ladder_chapter_label
    local ladder_intro = config and config.features and config.features._ladder_intro
    local ladder_fresh = config and config.features and config.features._ladder_fresh
    if config and config.features then
        config.features._ladder_build = nil
        config.features._ladder_target_ratio = nil
        config.features._ladder_base = nil
        config.features._ladder_chapter_label = nil
        config.features._ladder_intro = nil
        config.features._ladder_fresh = nil
    end
    -- Merge engine (§6 slice 3): sentinel payload. Artifact JSON must NEVER pass
    -- through the placeholder machinery (the early passes strip lines and
    -- substitute placeholder literals INSIDE it; the late passes rescan injected
    -- content) — it is injected into the BUILT message below, after
    -- MessageBuilder.build has fully finished (XrayMerge.injectPayload).
    local merge_payload = config and config.features and config.features._merge_payload
    if config and config.features then
        config.features._merge_payload = nil
    end
    if merge_payload and temp_config.features then
        -- createTempConfig copied the features table before this consume — drop
        -- the (potentially large) payload reference from the copy too
        temp_config.features._merge_payload = nil
    end
    if prompt.provider then
        -- Set both provider and model at top level so they take precedence.
        -- provider_settings can be NIL here: it comes only from a
        -- configuration.lua that defines one (GUI-only setups have none), and
        -- createTempConfig creates it only for provider+model pins — a
        -- provider+tier pin (model nil, tier baked later) crashed on the index
        -- (device 2026-08-14). Only mirror an actual model pin into the
        -- per-provider bucket, and clone before writing: the 2-level copy
        -- leaves sub-tables SHARED with the module config.
        temp_config.provider = prompt.provider
        temp_config.model = prompt.model
        if prompt.model then
            temp_config.provider_settings = temp_config.provider_settings or {}
            local ps = {}
            for k, v in pairs(temp_config.provider_settings[prompt.provider] or {}) do
                ps[k] = v
            end
            ps.model = prompt.model
            temp_config.provider_settings[prompt.provider] = ps
        end
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
            local threshold = f.translate_long_highlight_threshold or 280
            local text_length = highlightedText and #highlightedText or 0
            temp_config.features.translate_hide_quote = (text_length > threshold)
        elseif hide_mode == "follow_global" then
            -- Replicate global hide logic: hide_highlighted_text OR (hide_long_highlights AND over threshold)
            local text_length = highlightedText and #highlightedText or 0
            local global_threshold = f.long_highlight_threshold or 280
            temp_config.features.translate_hide_quote = f.hide_highlighted_text or
                (f.hide_long_highlights ~= false and text_length > global_threshold)
        elseif hide_mode == "never_hide" then
            temp_config.features.translate_hide_quote = false
        end

        -- Full page translate override: checkbox is the ultimate override when checked
        -- This ONLY affects full page translations, not regular highlight translations
        if is_full_page and f.translate_hide_full_page ~= false then
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

    -- Minimal popup routing (Minimal Popup settings), dispatch side: actions
    -- REGISTERED for the minimal popup (features.minimal_popup_actions, defaults
    -- in Constants) open their response in the chrome-less anchored popup. The
    -- response appears on completion — a full streaming dialog first would be a
    -- jarring two-stage UX, so skip streaming, and swap the provider/model status
    -- dialog for a one-line notice (still tap-to-cancel: that dialog's dismiss is
    -- the only way to terminate the request subprocess, so it cannot be
    -- suppressed outright). The fit decision ("When it fits") needs the
    -- FINISHED response, so it lives at the seam (showResponseDialog) behind
    -- the _minimal_popup_eligible marker set here. Highlight-only
    -- actions; never full-page translation.
    do
        local f = config.features or {}
        if (f.minimal_popup_mode or "short") ~= "off"
                and prompt.id and prompt.context == "highlight"
                and not (temp_config.features and temp_config.features.is_full_page_translate) then
            local registered = require("koassistant_constants")
                .resolveMinimalPopupActions(f.minimal_popup_actions)
            -- Dict-window guard, dispatch side: launched FROM an open dictionary
            -- window (KOA buttons on DictQuickLookup — it stays up during the
            -- request), the show-time guard would skip the popup anyway, so don't
            -- burn streaming on it either — take the normal streamed route now.
            -- The show-time guard stays for the inverse race (a dict window that
            -- opens or closes while the request runs). Dictionary BYPASS opens no
            -- dict window, so it correctly keeps the popup.
            local dict_open = false
            local ok_dql, DictQuickLookup = pcall(require, "ui/widget/dictquicklookup")
            if ok_dql and DictQuickLookup and DictQuickLookup.window_list
                    and #DictQuickLookup.window_list > 0 then
                dict_open = true
            end
            if registered[prompt.id] and not dict_open then
                temp_config.features = temp_config.features or {}
                temp_config.features.enable_streaming = false
                temp_config.features.loading_message = prompt.translate_view
                    and _("Translating…") or (prompt.text and (prompt.text .. "…")) or nil
                temp_config.features._minimal_popup_eligible = true
            end
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
    -- Response language for prompt-LOCAL naming ({response_language} — the
    -- X-Ray JSON tails): the SAME primary the system instruction announces,
    -- incl. the per-book response-language override. Named again at the JSON
    -- rules because thousands of chars of non-primary source text pull models
    -- off the far-away system instruction (device report 2026-08-02: Arabic
    -- book → Arabic X-Ray despite "Always respond in English" on the wire).
    local response_lang_fields = require("koassistant_book_settings").applyResponseLanguageOverride({
        interaction_languages = config.features.interaction_languages,
        user_languages = config.features.user_languages,
        primary_language = config.features.primary_language,
    }, per_book_ds)
    local effective_response_language = SystemPrompts.parseUserLanguages(
        response_lang_fields.interaction_languages or response_lang_fields.user_languages,
        response_lang_fields.primary_language)

    -- Build data for consolidated message
    logger.dbg("KOAssistant: buildConsolidatedMessage - highlightedText:", highlightedText and #highlightedText or "nil/empty")
    logger.dbg("KOAssistant: config.features.book_metadata=", config.features and config.features.book_metadata and "present" or "nil")
    if config.features and config.features.book_metadata then
        logger.dbg("KOAssistant: book_metadata.title=", config.features.book_metadata.title or "nil")
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
        response_language = effective_response_language,
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
        -- Recon 2e (2026-08-16): the entry body is not book prose — label it.
        -- Only the X-Ray chat prefix flows through request_prefix, so the gate
        -- is exact. Model-facing string, untranslated like the prefix.
        selection_label = xray_prefix and "From the X-Ray entry:" or nil,
        -- Background auto-update marker (read by the abort/guard/pre-send checks)
        _background_request = background_request or nil,
        -- Auto-create marker (§5 decision 1): permits the fresh path in the §4 abort
        _background_create = background_create or nil,
        -- Ladder chain markers (§6 slice 1): _ladder_build diverts saves to the
        -- ladder file; _ladder_target re-anchors the request at the rung boundary;
        -- _ladder_base seeds the incremental path with the previous rung instead of
        -- the live cache (rungs never touch the live X-Ray until promotion)
        _ladder_build = ladder_build_flag or nil,
        _ladder_target = ladder_target,
        _ladder_base = ladder_base,
        -- P3 chapter snapping: the planned rung's chapter title, stamped into the
        -- rung entry at save so the versions list can label it
        _ladder_chapter_label = ladder_chapter_label,
        -- Round 20: introductory step — the rung saves at progress 0 with the
        -- intro flag (premise-only version, openable at any position)
        _ladder_intro = ladder_intro or nil,
        -- Pre-swap rebuild rung (2026-08-15): no-base-by-design marker — the
        -- cache-engagement fallback must not read the surviving old live
        _ladder_fresh = ladder_fresh or nil,
    }
    message_data._merge_payload = merge_payload
    logger.dbg("KOAssistant: message_data.book_metadata=", message_data.book_metadata and "present" or "nil")

    -- Build dynamic quiz instructions from settings (for interactive quiz actions).
    -- Per-book quiz overrides (Book Settings ▸ Quiz) take precedence over the globals.
    if prompt and prompt.interactive_quiz then
        local quiz = BookSettings.resolveQuiz(per_book_ds, config.features)
        message_data.quiz_instructions = require("koassistant_quiz_prompt").build(quiz)
        -- Requested count for the honesty toast at parse time (consumed once in
        -- executeDirectAction's onComplete — same transient channel as
        -- _chapter_quiz_title). Models routinely under-deliver ("asked 10, got
        -- 9") and nothing compared the counts anywhere.
        config.features._quiz_requested_count = quiz.count or 8
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
        -- Whole dictionary family (and custom dict-style actions): any action
        -- whose prompt carries the {context}/{context_section} channel. The old
        -- literal-id "dictionary" scoping left quick_define/dictionary_deep
        -- permanently context-less off the dict-popup path (audit #37b) — with
        -- the rerun row now live there, that read as a stuck "Ctx: OFF".
        local dc_prompt_text = (prompt and prompt.prompt) or ""
        local has_dict_channel = dc_prompt_text:find("{context_section}", 1, true) ~= nil
            or dc_prompt_text:find("{context}", 1, true) ~= nil
        -- P5 (2026-08-16): after-side limiting for context windows — the global
        -- "before only" direction pick, and the configurable spoiler clamp while
        -- protection resolves on for this request (contextAfterLimit). Covers
        -- the dictionary AND highlight context channels; viewer/popup selections
        -- (non_document_selection) skip the spoiler half — their "after" text
        -- is chat text, not unread book.
        local ctx_spoiler_on = false
        if not non_document_selection then
            -- Session Spoiler chip first (set just-in-time for dialog-launched
            -- requests; read without consuming — buildUnifiedRequestConfig owns
            -- consumption), else the book/global posture.
            local sess_sp = config.features._spoiler_free_active
            if sess_sp ~= nil then
                ctx_spoiler_on = sess_sp and true or false
            else
                ctx_spoiler_on = BookSettings.resolveSpoilerFree(per_book_ds, config.features) or false
            end
        end
        local ctx_after_limit = contextAfterLimit(config.features, ctx_spoiler_on)
        if has_dict_channel and not non_document_selection
                and (not message_data.context or message_data.context == "") then
            -- Resolved per-book > global mode; "none" extracts nothing
            local context_chars = config.features.dictionary_context_chars or 100
            message_data.context = extractSurroundingContext(ui,
                highlightedText, message_data.dictionary_context_mode, context_chars,
                nil, ctx_after_limit)
            -- Input-dialog launches: the live selection died when the dialog opened
            -- (main.lua onClose), so the extraction above finds nothing — fall back
            -- to the pre-extracted raw window (audit #37 starve; also what makes
            -- the compact viewer's Ctx toggle meaningful on this path). Read-only:
            -- the ambient block below still owns consumption of the transient.
            if (not message_data.context or message_data.context == "")
                    and message_data.dictionary_context_mode
                    and message_data.dictionary_context_mode ~= "none" then
                local w = config.features._selection_context_window
                if w and w.text == highlightedText then
                    message_data.context = ScopeResolver.trimContext(w.prev, w.next,
                        highlightedText, message_data.dictionary_context_mode,
                        { char_count = context_chars, after_limit = ctx_after_limit })
                end
            end
        end
        -- Mirror the resolved mode (and any context extracted here) back onto
        -- temp_config, like the languages above: the compact viewer's Ctx label and
        -- the rerun baseline (_original_context/_original_context_mode) read
        -- features — without this, a per-book mode override showed "Ctx: OFF" while
        -- context rode the request, and the Ctx toggle had nothing to restore.
        temp_config.features.dictionary_context_mode = message_data.dictionary_context_mode
        if message_data.context and message_data.context ~= ""
                and (not temp_config.features.dictionary_context or temp_config.features.dictionary_context == "") then
            temp_config.features.dictionary_context = message_data.context
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
            -- Session amounts (round 5): per-request Ctx-chip picks beat the
            -- globals; an action's own context_chars pin still wins.
            local sc_chars = prompt.context_chars or config.features._session_ctx_chars
                or config.features.highlight_context_chars or 100
            local sc_paragraphs = config.features._session_ctx_paragraphs
                or config.features.highlight_context_paragraphs or 1
            local sc_text
            if sc_window and sc_window.text == highlightedText then
                sc_text = ScopeResolver.trimContext(sc_window.prev, sc_window.next, highlightedText,
                    sc_mode, { char_count = sc_chars, paragraphs = sc_paragraphs,
                        after_limit = ctx_after_limit })
            elseif not non_document_selection then
                -- Surfaces that didn't pre-extract: try the live selection (may be gone).
                -- Skipped for non-document selections: the live selection is the open
                -- book's, unrelated to the viewer/popup text (B3).
                sc_text = extractSurroundingContext(ui, highlightedText, sc_mode, sc_chars,
                    sc_paragraphs, ctx_after_limit)
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
            logger.dbg("KOAssistant: book_metadata populated from ui.doc_props for book context")
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
        local has_doi = config.features and config.features.book_metadata
            and config.features.book_metadata.doi
        research_mode_active = require("koassistant_book_settings").resolveResearch(
            per_book_ds, config.features, { doi = has_doi })
    end

    -- Research mode active: swap to academic prompt track (if available)
    -- Must happen BEFORE full-document swap so doi_complete_prompt is available
    -- Stash originals so cache update can revert if needed (cache was non-research but current is research)
    if research_mode_active and prompt and prompt.doi_prompt then
        local original_prompt = prompt
        prompt = {}
        for k, v in pairs(original_prompt) do prompt[k] = v end
        prompt._is_copy = true
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
        prompt._is_copy = true
        prompt.prompt = original_prompt.complete_prompt
    end

    -- X-Ray category selection (presets v0.21): the per-book sidecar pick
    -- narrows which categories a NEW X-Ray tracks — the create prompt is
    -- assembled with only the selected schema blocks. Research/DOI and section
    -- builds stay full; UPDATE requests follow the cache STAMP instead (the
    -- update branch below overwrites prompt.prompt anyway and appends its own
    -- clause). Covers attended creates, background/auto establishment and
    -- rebuild-chain fresh rungs alike — they all pass through here.
    if prompt and prompt.id == "xray" and prompt.cache_as_xray
        and not (research_mode_active and prompt.doi_prompt)
        and not (config.features and (config.features._section_scope
            or config.features._section_xray)) then
        local xr_file = (ui and ui.document and ui.document.file)
            or (config.features and config.features.book_metadata
                and config.features.book_metadata.file)
        local xr_ds
        if xr_file then
            local ok_ds, got_ds = pcall(function()
                return require("koassistant_doc_settings").resolve(xr_file, ui)
            end)
            if ok_ds then xr_ds = got_ds end
        end
        -- Book pick > global default > full (the resolver handles the
        -- explicit-full "full" sentinel; a nil ds still lets the global
        -- default apply)
        local xr_sel = require("koassistant_book_settings")
            .resolveXrayCategories(xr_ds, config.features)
        -- Depth rung (docs/xray_depth_axis_plan.md): same book > global > standard
        -- chain; nil = the shipped wording, so a nil/nil pair leaves the prompt
        -- untouched
        local xr_depth = require("koassistant_book_settings")
            .resolveXrayDepth(xr_ds, config.features)
        if xr_sel or xr_depth then
            if not prompt._is_copy then
                local original_prompt = prompt
                prompt = {}
                for k, v in pairs(original_prompt) do prompt[k] = v end
                prompt._is_copy = true
            end
            prompt.prompt = PromptsActions.buildXrayCategoryPrompt(xr_sel,
                (config.features and config.features._full_document_xray)
                    and "complete" or "partial", xr_depth)
            message_data._xray_categories_applied = xr_sel
            message_data._xray_depth_applied = xr_depth
            logger.dbg("KOAssistant: X-Ray create narrowed to categories:", xr_sel,
                "depth:", xr_depth)
        end
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
    -- (follow global setting) when research mode is active.
    -- Copy-on-write like every other prompt mutation here: without it this writes through
    -- to the LIVE ActionService cache entry, permanently stripping the action's web-off
    -- for every book until the cache is invalidated (injection_gating_audit).
    if research_mode_active
            and prompt.doi_web_override and prompt.enable_web_search == false then
        if not prompt._is_copy then
            local original_prompt = prompt
            prompt = {}
            for k, v in pairs(original_prompt) do
                prompt[k] = v
            end
            prompt._is_copy = true
        end
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
    -- The pending session ⚡ model override re-points dispatch at bake time, AFTER this
    -- gate — fold it in here so trust is judged against the post-override provider.
    local effective_provider = effectiveDispatchProvider(
        temp_config and temp_config.features, prompt,
        (temp_config and temp_config.provider)
            or (config.features and config.features.provider))

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
                -- Ladder rung 1 (create from nothing): bound {book_text} extraction at
                -- the rung boundary instead of the reader's position (§6 slice 1)
                _ladder_target_ratio = message_data._ladder_target,
            })
            logger.dbg("KOAssistant: Extractor settings - enable_book_text_extraction=",
                       config.features and config.features.enable_book_text_extraction and "true" or "false/nil")
            if extractor:isAvailable() then
                logger.dbg("KOAssistant: Context extraction starting for action:", prompt and prompt.id or "unknown")
                logger.dbg("KOAssistant: use_book_text=", prompt and prompt.use_book_text and "true" or "false")
                -- Background auto-update: the base prompt's {book_text_section} would trigger
                -- a full to-position extraction that the update prompt never consumes (it uses
                -- only the delta, extracted in the cache block below) — and a background run
                -- that does NOT engage the incremental path aborts anyway. Skip the expensive
                -- part on a pruned COPY (never mutate the shared action table); progress /
                -- highlights extraction still runs. EXCEPT auto-create (§5 decision 1):
                -- a first generation IS the base prompt — it needs the to-position text
                -- (bounded by the max-gap dial, same bound as an update's delta).
                local extract_prompt = prompt or {}
                local prune_book_text = message_data._background_request and extract_prompt.use_book_text
                    and not message_data._background_create
if prune_book_text then
                    local pruned = {}
                    for k, v in pairs(extract_prompt) do pruned[k] = v end
                    pruned.use_book_text = false
                    extract_prompt = pruned
                end
                local extracted = extractor:extractForAction(extract_prompt)
                -- Merge extracted data into message_data
                for key, value in pairs(extracted) do
                    message_data[key] = value
                    logger.dbg("KOAssistant: Extracted data key=", key, "value_len=", type(value) == "string" and #value or "non-string")
                end
                logger.dbg("KOAssistant: Context extraction complete")

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
            logger.dbg("KOAssistant: Sidecar extraction for file browser:", fb_document_path)
            local extracted = extractor:extractForAction(prompt or {})
            for key, value in pairs(extracted) do
                message_data[key] = value
                logger.dbg("KOAssistant: Sidecar extracted key=", key, "value_len=", type(value) == "string" and #value or "non-string")
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
                    -- Per-book privacy overrides (Book Settings ▸ Privacy): each
                    -- scanned book can allow/deny its own channels; deny beats
                    -- trusted — same semantics as the single-book extractor.
                    local b_ov = {}
                    do
                        local sds_ok, b_ds = pcall(function()
                            return require("koassistant_doc_settings").resolve(book.file, ui)
                        end)
                        if sds_ok and b_ds then
                            b_ov = require("koassistant_book_settings").effectivePrivacyOverrides(b_ds)
                        end
                    end
                    local b_highlights = highlights_allowed
                    if b_ov.highlights ~= nil then b_highlights = b_ov.highlights end
                    local b_annotations = annotations_allowed
                    if b_ov.annotations ~= nil then b_annotations = b_ov.annotations end
                    local b_notebook = notebook_allowed
                    if b_ov.notebook ~= nil then b_notebook = b_ov.notebook end

                    -- Highlights
                    if prompt.use_highlights and b_highlights then
                        local annotations = ContextExtractor.readSidecarAnnotations(book.file)
                        local result = ContextExtractor.formatHighlights(annotations)
                        if result.formatted ~= "" then
                            book._highlights = result.formatted
                            book._highlights_count = result.count
                            total_sidecar_chars = total_sidecar_chars + #result.formatted
                        end
                    end

                    -- Annotations (with degradation)
                    if prompt.use_annotations and b_annotations then
                        local annotations = ContextExtractor.readSidecarAnnotations(book.file)
                        local result = ContextExtractor.formatAnnotations(annotations)
                        if result.formatted ~= "" then
                            book._annotations = result.formatted
                            book._annotations_count = result.count
                            book._annotations_degraded = false
                            total_sidecar_chars = total_sidecar_chars + #result.formatted
                        end
                    elseif prompt.use_annotations and b_highlights then
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
                    if prompt.use_notebook and b_notebook then
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

    -- Ladder rung (§6 slice 1): generate AS IF the reader stood at the rung boundary.
    -- This one override anchors everything downstream — prompt placeholders
    -- ({reading_progress}, the spoiler line), the incremental extraction's to_page,
    -- and the progress the rung is saved at.
    if message_data._ladder_target and ui and ui.document then
        local lt = message_data._ladder_target
        message_data.progress_decimal = tostring(lt)
        message_data.reading_progress = math.floor(lt * 100 + 0.5) .. "%"
        local lt_total = ui.document.info and ui.document.info.number_of_pages
        if lt_total and lt_total > 0 then
            message_data.progress_page = math.max(1, math.floor(lt * lt_total))
        end
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
            domain_id = require("koassistant_book_settings").resolveDomain(
                per_book_ds, config.features)
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

    -- A deferred rebuild leaves the outgoing X-Ray on disk while the new one is
    -- generated (round 25) — it must never be read as an incremental base
    if cache_enabled and not (config.features and (config.features._full_document_xray
            or config.features._xray_rebuild)) then
        local ActionCache = require("koassistant_action_cache")
        -- Ladder chain: rung N+1 continues from rung N (injected by the fire path),
        -- never from the live cache — the live X-Ray tracks the reader throughout
        -- the build (§6 slice 1). A pre-swap REBUILD rung carries no base BY
        -- DESIGN (_ladder_fresh): nil here must not fall through to the
        -- surviving old artifact, or the rebuild silently merges the very
        -- lineage it is replacing back in (2026-08-15 device round, log:
        -- "Using cached response from 9%" on a from-scratch rebuild step)
        local cached_entry = message_data._ladder_base
        if not cached_entry and not message_data._ladder_fresh then
            cached_entry = ActionCache.get(cache_file, prompt.id)
        end
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
                logger.dbg("KOAssistant: Legacy markdown X-Ray cache detected, forcing full regeneration for JSON output")
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
            -- Per-book privacy overrides for the cache's book (deny beats trusted;
            -- allow satisfies the global gate) — the update path re-sends cached
            -- text/highlight-derived content, so it must honor them like fresh reads.
            local cache_book_priv = {}
            do
                local cb_ok, cb_ds = pcall(function()
                    return require("koassistant_doc_settings").resolve(cache_file, ui)
                end)
                if cb_ok and cb_ds then
                    cache_book_priv = require("koassistant_book_settings").effectivePrivacyOverrides(cb_ds)
                end
            end
            local cache_requires_text = cached_entry.used_book_text ~= false
            local cache_text_ok = not cache_requires_text
                or cache_trusted or cf.enable_book_text_extraction == true
            if cache_requires_text and cache_book_priv.book_text ~= nil then
                cache_text_ok = cache_book_priv.book_text
            end
            local cache_requires_highlights = cached_entry.used_highlights == true
                or (cached_entry.used_highlights == nil and cached_entry.used_annotations == true)
            local cache_highlights_ok = not cache_requires_highlights
                or cache_trusted or cf.enable_highlights_sharing == true
                or cf.enable_annotations_sharing == true
            if cache_requires_highlights and cache_book_priv.highlights ~= nil then
                cache_highlights_ok = cache_book_priv.highlights
            end
            local cache_read_allowed = cache_text_ok and cache_highlights_ok
            if not cache_read_allowed then
                logger.dbg("KOAssistant: Cached", prompt.id,
                    "result withheld from update - permission revoked since cache build")
            end

            -- Use cache if we've progressed by at least 1% since last time
            if not skip_legacy and not skip_incremental and cache_read_allowed
                    and current_progress > cached_progress + 0.01 and prompt.update_prompt then
                using_cache = true
                cached_progress_display = math.floor(cached_progress * 100) .. "%"
                logger.dbg("KOAssistant: Using cached response from", cached_progress_display, "for", prompt.id)

                -- Switch to update prompt (create a shallow copy to avoid modifying original)
                local original_prompt = prompt
                prompt = {}
                for k, v in pairs(original_prompt) do
                    prompt[k] = v
                end
                prompt.prompt = original_prompt.update_prompt

                -- Add cache data for placeholder substitution (neither the
                -- dormant carry ledger — item 49 — nor the mechanical
                -- background lines — round 28 — ever ride an update prompt;
                -- safe no-op on prose caches)
                message_data.cached_result = XrayParser.stripForPromptJSON(cached_entry.result)
                message_data.cached_progress = cached_progress_display
                message_data.cached_progress_decimal = cached_progress
                -- Stash previous cache's metadata for sticky-true inheritance
                message_data.cached_used_book_text = cached_entry.used_book_text
                message_data.cached_used_highlights = cached_entry.used_highlights
                message_data.cached_used_annotations = cached_entry.used_annotations
                -- Timeline slice 1: base identity + coverage union at save time
                message_data.cached_timestamp = cached_entry.timestamp
                message_data.cached_coverage_spans = cached_entry.coverage_spans

                -- For X-Ray: parse cached result and build entity index for merge-based updates
                if prompt.id == "xray" and XrayParser.isJSON(cached_entry.result) then
                    local parsed_cache = XrayParser.parse(cached_entry.result)
                    if parsed_cache and not parsed_cache.error then
                        message_data.entity_index = XrayParser.buildEntityIndex(parsed_cache)
                        message_data._parsed_old_xray = parsed_cache
                    end
                end

                -- Category-filtered lineage (presets v0.21): the update prompt's
                -- generic "add new characters/timeline entries" lines could
                -- reintroduce categories the create dropped — the STAMP rides
                -- as an explicit restriction clause (the cached JSON's key set
                -- already self-enforces most of it). On UPDATES the stamp is
                -- the lineage truth in BOTH directions: it must also OVERWRITE
                -- a sidecar selection the create-side block staged (a filtered
                -- preference over a full lineage must not mis-stamp the save).
                if prompt.id == "xray" then
                    if cached_entry.xray_categories then
                        local cat_keys = PromptsActions.xrayCategoryKeysFor(
                            cached_entry.xray_categories,
                            message_data._parsed_old_xray and message_data._parsed_old_xray.type)
                        if #cat_keys > 0 then
                            prompt.prompt = prompt.prompt
                                .. "\n\nThis X-Ray deliberately tracks ONLY these entry categories: "
                                .. table.concat(cat_keys, ", ")
                                .. ". Do not add entries in any other category or introduce new category keys. The always-required status object is unaffected."
                        end
                    end
                    message_data._xray_categories_applied =
                        PromptsActions.normalizeXrayCategories(cached_entry.xray_categories)
                    -- Depth is lineage truth too (change only at lineage start):
                    -- the update carries the stamp and tells the model the
                    -- per-entry budget it must keep, so Light lineages do not
                    -- grow Standard-sized entries on every update
                    local cached_depth = PromptsActions.normalizeXrayDepth(cached_entry.xray_depth)
                    message_data._xray_depth_applied = cached_depth
                    if cached_depth == "light" then
                        prompt.prompt = prompt.prompt
                            .. "\n\nThis X-Ray is kept LIGHT: one sentence per entry (two for the central few), only figures who return or shape what happens, only turning points in the timeline, connections only where needed to follow the work. Write new and re-emitted entries at that depth."
                    elseif cached_depth == "deep" then
                        prompt.prompt = prompt.prompt
                            .. "\n\nThis X-Ray is kept DEEP: 3-5 sentences for major entries and 1-2 for minor ones including why they matter, every figure the reader encounters, every development in the timeline, connections carrying the relationship and what it changes. Write new and re-emitted entries at that depth."
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
                    logger.dbg("KOAssistant: Extracted incremental book text:", range_result.char_count, "chars")

                    -- Store truncation metadata for pre-send warning dialog
                    if range_result.truncated and not range_result.disabled then
                        message_data.incremental_book_text_truncated = true
                        message_data.incremental_coverage_start = range_result.coverage_start
                        message_data.incremental_coverage_end = range_result.coverage_end
                    end
                end

                -- The update prompt sends only {cached_result} + the incremental
                -- delta; the generic to-position extraction (book_text) never
                -- rides an update request. Drop it so the large-extraction
                -- warning counts what is actually sent (a 73->83% extend of a
                -- big book warned at ~1M chars while the request carried the
                -- ~119K delta) and the dead string is freed before the send.
                -- Guarded on the placeholders so a custom update_prompt that
                -- DOES reference them keeps its text.
                if type(prompt.prompt) == "string"
                        and not prompt.prompt:find("{book_text", 1, true)
                        and not prompt.prompt:find("{full_document", 1, true) then
                    message_data.book_text = nil
                    message_data.full_document = nil
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
            logger.dbg("KOAssistant: background X-Ray create - fresh generation engaged")
        else
            logger.dbg("KOAssistant: background X-Ray update aborted - incremental path did not engage")
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
            logger.dbg("KOAssistant: previous_results injected, len=" .. #prev)
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

    -- Spoiler protection, message side (spoiler_posture_plan.md §3, B3/B4): resolve
    -- the request-layer posture for this action so prompts carrying
    -- {spoiler_free_nudge} (wiki, custom actions) resolve it in place. Same rule as
    -- the system-side bake in buildUnifiedRequestConfig — session chip (the copy that
    -- rode into temp_config at dispatch; direct/headless entries carry none) >
    -- research > book > global; skip_spoiler = true opts out; book/highlight
    -- contexts only. B4: prefer the live position over the (possibly scrubbed)
    -- metadata table so the nudge keeps its progress-bounded variant.
    if context ~= "general" and context ~= "library"
            and not (prompt and prompt.skip_spoiler == true) then
        local sp = BookSettings.resolveSpoilerPosture(per_book_ds, config.features,
            { session = temp_config.features and temp_config.features._spoiler_free_active })
        if sp.protected then
            message_data.spoiler_free = true
            if not message_data.reading_progress then
                message_data.reading_progress =
                    (message_data.book_metadata and message_data.book_metadata.reading_progress)
                    or (ui and ui.document and require("koassistant_context_extractor")
                        :new(ui):getReadingProgress().formatted)
            end
        end
    end

    -- Build and add the consolidated message
    -- System prompt and domain are now in config.system (unified approach)
    local consolidated_message = buildConsolidatedMessage(prompt, context, message_data, nil, nil, true)
    -- Merge payload injection (§6 slice 3 wire-safety): the artifact JSON enters
    -- the message ONLY here — after every placeholder pass has run — via
    -- brace-free sentinel tokens (single-pass replace, inserted content never
    -- rescanned). Inline require: no new file-local upvalues (60-upvalue cap).
    if message_data._merge_payload then
        consolidated_message = require("koassistant_xray_merge").injectPayload(
            consolidated_message, message_data._merge_payload)
    end
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
        -- Consume-and-clear: attachments are single-send context. Clearing here
        -- (not only at the next fresh input-open) keeps the module list empty when
        -- the viewer opens, so a reply's Attach chip starts fresh and can't inherit
        -- this send's leftovers (reply parity, slice (b)).
        Attachments.clear()
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

    -- Round 28 (#90): exact-retry handle for the unusable-X-Ray dialog in
    -- handleResponse — one upvalue instead of nine (upvalue-cap discipline)
    local retry_args = { prompt_type_or_action, highlightedText, ui, configuration,
        existing_history, plugin, additional_input, on_complete, book_metadata }

    -- Get response from AI with callback for async streaming
    local function handleResponse(success, answer, err, reasoning, web_search_used, usage)
        -- Token usage rides on message_data (a captured table; no new upvalue for the
        -- nested cache-write closures) and is stamped into every artifact cache entry
        -- (tokens_in/out/reasoning) so builds can be compared afterwards
        message_data._usage = type(usage) == "table" and usage or nil
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
            local xray_unusable  -- round 28 (#90): reason text when the response must not become the artifact
            if action.cache_as_xray then
                local XrayParser = require("koassistant_xray_parser")
                local parsed, parse_err = XrayParser.parse(answer)
                if parsed and parsed.error then
                    -- AI returned error (e.g., "I don't recognize this work") — show as plain text, skip caching
                    display_answer = parsed.error
                    cache_answer = nil  -- Signal to skip caching below
                    logger.warn("KOAssistant: X-Ray returned error response, skipping cache:", parsed.error)
                elseif parsed and not using_cache and not XrayParser.hasEntityContent(parsed) then
                    -- Round 28 (#90 field report): a CREATE that parsed but holds no
                    -- entity categories (e.g. a lone current_state — seen from
                    -- flash-lite) must not become the artifact: nothing is browsable,
                    -- and on a rebuild it would replace a real X-Ray with dead
                    -- weight. Updates are exempt — a small delta touching only
                    -- current_state is legitimate.
                    xray_unusable = _("the response was missing X-Ray content (no characters or other entries)")
                    cache_answer = nil
                    logger.dbg("KOAssistant: X-Ray create had no entity categories, skipping cache")
                elseif parsed then
                    -- Carry ledger (item 49): the model never authors the ledger
                    parsed[XrayParser.DORMANT_KEY] = nil
                    -- Round 28 (#90): background is code-owned end-to-end. A model
                    -- that has seen the mechanical background lines in a prompt can
                    -- echo them back (mangled, self-labeled) and a rewrite carrying
                    -- a background field would replace the stored one — drop them
                    -- from every fresh response before any merge
                    XrayParser.dropModelBackground(parsed)
                    -- 2026-08-15 (A0): drop foreign-schema/no-content entries
                    -- before they can become (or merge into) the artifact —
                    -- weak local models emitted entries with no description
                    -- that polluted the installed X-Ray verbatim
                    XrayParser.sanitizeEntries(parsed)
                    -- Merge partial update into existing data when available
                    if using_cache and message_data._parsed_old_xray then
                        -- To debug X-Ray merge: uncomment koassistant_debug_utils.dumpXrayMerge() below
                        local never_pairs = cache_file
                            and require("koassistant_action_cache").getNeverMergePairs(cache_file)
                        parsed = XrayParser.merge(message_data._parsed_old_xray, parsed,
                            never_pairs and { never_pairs = never_pairs } or nil)
                        logger.dbg("KOAssistant: Merged incremental X-Ray update into existing data")
                        -- Wake-pass (carry layer 2): entities arriving in this
                        -- slice promote their carried history
                        local woken = XrayParser.wakeDormant(parsed)
                        if #woken > 0 then
                            logger.dbg("KOAssistant: X-Ray update woke", #woken, "dormant entit(y/ies)")
                        end
                    elseif not (config.features and (config.features._section_scope
                            or config.features._section_xray)) then
                        -- Carry layer 3(i): a fresh (or rebuilt) main X-Ray seeds
                        -- its dormant ledger from the nearest X-Rayed predecessor
                        -- in the book's group — locally, zero tokens, visible
                        -- content untouched — then the wake-pass promotes any
                        -- skip-volume entities already present. Runs for
                        -- background and ladder creates too (the seed never
                        -- interrupts).
                        -- Round 25: FIRST carry the outgoing X-Ray's own ledger
                        -- across. Re-seeding alone silently lost carried history
                        -- whenever the predecessor walk came back empty (its
                        -- X-Ray deleted, its text-extraction consent revoked) —
                        -- a rebuild must never cost knowledge the book already
                        -- held. populateDormant unions by name, so the seed
                        -- below refreshes these rather than duplicating them.
                        local prev_live = require("koassistant_action_cache").getXrayCache(cache_file)
                        if prev_live and prev_live.result
                            and XrayParser.isJSON(prev_live.result) then
                            local prev_parsed = XrayParser.parse(prev_live.result)
                            local prev_ledger = prev_parsed and not prev_parsed.error
                                and prev_parsed[XrayParser.DORMANT_KEY]
                            if type(prev_ledger) == "table" and #prev_ledger > 0 then
                                parsed[XrayParser.DORMANT_KEY] = prev_ledger
                                logger.dbg("KOAssistant: X-Ray rebuild carried",
                                    #prev_ledger, "dormant entit(y/ies) from the outgoing version")
                            end
                            -- Round 26: the ledger alone was half the promise —
                            -- background already folded onto LIVE entities died
                            -- with the replaced artifact. Re-stub those carriers
                            -- so the wake-pass below restores them onto the
                            -- fresh read (device-confirmed loss).
                            if prev_parsed and not prev_parsed.error then
                                local carried = require("koassistant_xray_merge")
                                    .carryActiveBackground(prev_parsed, parsed)
                                if carried > 0 then
                                    logger.dbg("KOAssistant: X-Ray rebuild carried background of",
                                        carried, "entit(y/ies) from the outgoing version")
                                end
                            end
                        end
                        local seeded, seed_src = require("koassistant_xray_merge").seedDormant(
                            cache_file, parsed, config.features,
                            temp_config and temp_config.provider, ui)
                        if seeded > 0 then
                            logger.dbg("KOAssistant: X-Ray create seeded", seeded,
                                "dormant entit(y/ies) from", seed_src)
                        end
                        local woken = XrayParser.wakeDormant(parsed)
                        if #woken > 0 then
                            logger.dbg("KOAssistant: X-Ray create woke", #woken, "dormant entit(y/ies)")
                        end
                    end
                    -- Round 28 (#90): reconcile mechanical background against the
                    -- book's group — backfill file identities onto legacy labeled
                    -- lines, drop self-lines, dedupe per source book, order by
                    -- series position. Heals existing artifacts on their next write.
                    if cache_file then
                        pcall(function()
                            require("koassistant_xray_merge").reconcileBackground(
                                parsed, cache_file, ui)
                        end)
                    end
                    if not using_cache and not XrayParser.hasEntityContent(parsed) then
                        -- Post-sanitize re-check (2026-08-15, A0): a create whose
                        -- entries were ALL dropped as malformed must not become an
                        -- empty artifact — same verdict as the round-28 no-entity
                        -- gate above (updates stay exempt: a small delta may
                        -- legitimately touch only singletons). Raw text stays on
                        -- display so the user can see what the model produced.
                        xray_unusable = _("the response was missing X-Ray content (no characters or other entries)")
                        cache_answer = nil
                        logger.warn("KOAssistant: X-Ray create had only malformed entries after sanitize, skipping cache")
                    else
                        local book_meta = message_data.book_metadata or {}
                        local display_progress = message_data.reading_progress or ""
                        if config.features and config.features._full_document_xray then
                            display_progress = "Complete"
                        end
                        -- Round 28 (#90 crash.log): a render crash must cost the
                        -- markdown view only — never the merged artifact or the app
                        local render_ok, rendered = pcall(XrayParser.renderToMarkdown,
                            parsed,
                            book_meta.title or "",
                            display_progress
                        )
                        if render_ok then
                            display_answer = rendered
                        else
                            logger.warn("KOAssistant: X-Ray render failed, showing raw response:", rendered)
                        end
                        -- Pretty-print cached JSON so future updates receive readable structured data
                        local json_mod = require("json")
                        cache_answer = json_mod.encode(parsed, { pretty = true, indent = true })
                        logger.dbg("KOAssistant: X-Ray JSON parsed successfully, rendered to markdown for display")
                    end
                else
                    -- Round 28 (#90): junk must never OVERWRITE a real X-Ray. With
                    -- no previous X-Ray the legacy behavior stands (the raw text is
                    -- cached and readable — some models produce usable prose);
                    -- over an existing artifact the write is skipped instead.
                    local prev = cache_file
                        and require("koassistant_action_cache").getXrayCache(cache_file)
                    if prev and prev.result then
                        xray_unusable = _("the response was not valid X-Ray data")
                        cache_answer = nil
                        -- Dump the offending response. Two rungs of a real
                        -- ladder failed here on 2026-08-18 and the cause was
                        -- unrecoverable afterwards: the run log keeps only a
                        -- few KB of the response, so "not valid JSON" was the
                        -- whole evidence. A parse failure is rare, so the
                        -- bytes cost nothing in normal operation.
                        logger.warn("KOAssistant: X-Ray response is not valid JSON - keeping existing X-Ray, skipping cache")
                        logger.dbg("KOAssistant: X-Ray parse rejected because:",
                            tostring(parse_err))
                        logger.dbg("KOAssistant: unparseable X-Ray response, length",
                            type(answer) == "string" and #answer or "n/a",
                            "head:", type(answer) == "string" and answer:sub(1, 1200) or "n/a")
                        logger.dbg("KOAssistant: unparseable X-Ray response, tail:",
                            type(answer) == "string" and answer:sub(-1200) or "n/a")
                    else
                        logger.dbg("KOAssistant: X-Ray response is not valid JSON, using as-is")
                    end
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
            -- Both markers count: a provider-interrupted answer is as incomplete
            -- as a token-truncated one and must not be cached as whole.
            local is_truncated = ResponseParser.isIncomplete(answer)
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
            -- Ladder rungs never write the live cache, so the live-cache guards below
            -- don't apply — a manual run racing a rung is fine (promotion re-checks
            -- disk truth, and pickPromotableRung only ever moves the live entry
            -- FORWARD past whatever won the race).
            if message_data._ladder_build then --luacheck: ignore 542
                -- no guard: the rung write below is additive
            elseif message_data._background_request and using_cache then
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

            -- Timeline slice 1 (xray_ecosystem_plan.md item 37): coverage spans +
            -- provenance for X-Ray-lineage writes, computed ONCE and stamped into
            -- both cache keys and rung writes below. Spans record what the content
            -- honestly covers: fresh prefix builds claim [1→page]; updates claim
            -- base spans ∪ [base end+1→page] (a base with holes keeps its holes).
            -- Whole-book one-shots stay flag-based (full_document — page totals
            -- drift on reflow); intro rungs claim nothing (premise-only).
            local xray_spans, xray_producer, xray_base_ts, xray_fold_ts
            if action.cache_as_xray then
                local WriteBack = require("koassistant_artifact_writeback")
                xray_producer = message_data._ladder_build and "ladder"
                    or ((message_data._background_request or message_data._background_create) and "auto")
                    or "manual"
                xray_base_ts = using_cache and message_data.cached_timestamp or nil
                -- Slice 2 (item 37(c)): a MANUAL incremental point joins the
                -- timeline as a KEPT grid point (auto fills stay
                -- overwrite+ring — item 9: fills are prunable). One timestamp
                -- shared by the live write and the rung push below gives them
                -- the identity the shared archive rule matches on.
                if xray_producer == "manual"
                    and not (config.features and (config.features._full_document_xray
                        or config.features._section_scope or config.features._section_xray))
                    and source_mode ~= "ai_knowledge" then
                    xray_fold_ts = os.time()
                end
                local end_page = tonumber(message_data.progress_page)
                if not message_data._ladder_intro
                    and not (config.features and config.features._full_document_xray)
                    -- Whole-book claims (incl. update-to-100 and the terminal
                    -- ladder rung) stay FLAG-based per decision 37(b): a
                    -- stamped page total would go stale on reflow, while
                    -- progress 1.0 derives correctly at read time
                    and (tonumber(message_data.progress_decimal) or 0) < 1
                    and end_page and end_page > 0 then
                    local base_spans = using_cache and message_data.cached_coverage_spans or nil
                    local from_page = 1
                    local norm = WriteBack.parseSpans(base_spans)
                    if norm[#norm] then from_page = norm[#norm].to + 1 end
                    if from_page <= end_page then
                        xray_spans = WriteBack.unionSpans(base_spans, from_page .. "-" .. end_page)
                    else
                        xray_spans = WriteBack.formatSpans(base_spans)
                    end
                end
            end

            -- Save to response cache if enabled (for incremental updates)
            -- Skip caching if response was truncated or was an error response (cache_answer set to nil)
            -- For progress actions: require progress_decimal (extraction must succeed)
            -- For non-progress actions (book_info, etc.): save with default 1.0 even without extraction
            if cache_enabled and original_action_id and not background_discard
                    and not message_data._ladder_build
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
                      tokens_in = message_data._usage and message_data._usage.input_tokens or nil,
                      tokens_out = message_data._usage and message_data._usage.output_tokens or nil,
                      tokens_reasoning = message_data._usage and message_data._usage.reasoning_tokens or nil,
                      web_search_used = web_search_flag,
                      used_research_mode = research_mode_active or nil,
                      updated_by_auto = message_data._background_request or nil,
                      previous_progress_decimal = message_data.cached_progress_decimal,
                      flow_visible_pages = message_data.flow_visible_pages,
                      progress_page = message_data.progress_page,
                      full_document = config.features and config.features._full_document_xray or nil,
                      source_mode = source_mode,
                      coverage_spans = xray_spans,
                      producer = xray_producer,
                      base_timestamp = xray_base_ts,
                      timestamp = xray_fold_ts,
                      -- The category selection is a LINEAGE stamp, and this
                      -- generic entry is the one the incremental-update branch
                      -- reads back (ActionCache.get(cache_file, prompt.id)).
                      -- Without it here a narrowed X-Ray kept its narrowing for
                      -- exactly one write: the next attended update found no
                      -- stamp, skipped the restriction clause, and the generic
                      -- guidelines re-invited every dropped category. The X-Ray
                      -- twin, promotions and ring restores already carry it.
                      xray_categories = message_data._xray_categories_applied,
                      xray_depth = message_data._xray_depth_applied,
                      unavailable_data_text = unavailable_text }
                )
                if save_success then
                    logger.dbg("KOAssistant: Saved response to cache for", original_action_id, "at", save_progress, "used_book_text=", book_text_was_provided, "used_highlights=", highlights_were_provided)
                end
            elseif is_truncated and cache_enabled then
                logger.warn("KOAssistant: Skipping cache for", original_action_id, "- response was truncated")
            end

            -- Save to document caches if action has cache_as_* flags (for reuse by other actions)
            -- Always cache regardless of text extraction — tracks used_book_text for dynamic permission gating
            if not is_truncated and cache_file and not background_discard then
                local ActionCache = require("koassistant_action_cache")
                local progress = tonumber(message_data.progress_decimal) or 0
                local model_name = ConfigHelper:getModelInfo(temp_config)

                if action.cache_as_xray and message_data._ladder_build then
                    -- Ladder rung (§6 slice 1): the rung goes to the ladder sidecar, never
                    -- the live cache — the live X-Ray keeps tracking the reader while the
                    -- chain runs ahead; promotion swaps rungs in locally later. Same
                    -- sticky-true permission reconciliation as the live write below.
                    -- DEFERRED REBUILD SWAP (2026-08-14, the absolute round-25 rule):
                    -- a rebuild chain touches nothing until THIS moment — its first
                    -- successful real rung. Archive the outgoing live (even a promoted
                    -- rung: the old ladder dies in the same breath, so this is the only
                    -- copy kept), clear the live cache and the OLD ladder, then store
                    -- the new rung below. A chain cancelled or failed before this point
                    -- leaves the book exactly as it was.
                    local xa_build = require("koassistant_xray_auto").ladderBuild()
                    if xa_build and xa_build.rebuild and not xa_build.rebuild_swapped
                        and cache_answer and not message_data._ladder_intro then
                        local prev_live = ActionCache.getXrayCache(cache_file)
                        if prev_live and prev_live.result then
                            ActionCache.pushXrayCheckpoint(cache_file, prev_live,
                                ActionCache.checkpointLimitFromFeatures(config.features))
                        end
                        ActionCache.clearXrayCache(cache_file)
                        ActionCache.clear(cache_file, "xray")
                        ActionCache.clearXrayLadder(cache_file)
                        xa_build.rebuild_swapped = true
                        logger.info("KOAssistant: rebuild swap - outgoing X-Ray archived, old checkpoints cleared")
                    end
                    local rung_used_highlights = (message_data.highlights and message_data.highlights ~= "")
                    if using_cache and (message_data.cached_used_highlights == true
                        or (message_data.cached_used_highlights == nil and message_data.cached_used_annotations == true)) then
                        rung_used_highlights = true
                    end
                    -- Intro step (round 20): saved at progress 0 — the version is
                    -- premise-only and must be promotable at ANY position; storing
                    -- the extraction target would spoiler-gate it AND collide with
                    -- rung 1 in the ladder's tolerance dedup
                    local rung_ok = cache_answer and ActionCache.pushXrayLadderRung(cache_file, {
                        result = cache_answer,
                        progress_decimal = message_data._ladder_intro and 0 or progress,
                        progress_page = message_data._ladder_intro and 0 or message_data.progress_page,
                        timestamp = os.time(),
                        model = model_name,
                        used_highlights = rung_used_highlights,
                        used_book_text = book_text_was_provided,
                        flow_visible_pages = message_data.flow_visible_pages,
                        source_mode = source_mode,
                        chapter_label = message_data._ladder_chapter_label,
                        intro = message_data._ladder_intro or nil,
                        coverage_spans = xray_spans,
                        producer = xray_producer,
                        base_timestamp = xray_base_ts,
                        xray_categories = message_data._xray_categories_applied,
                      xray_depth = message_data._xray_depth_applied,
                    })
                    if rung_ok then
                        logger.dbg("KOAssistant: ladder rung saved at", progress)
                    else
                        -- A built rung that did not land on disk: paid work lost.
                        logger.warn("KOAssistant: ladder rung SAVE FAILED at", progress)
                    end
                elseif action.cache_as_xray then
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
                        tokens_in = message_data._usage and message_data._usage.input_tokens or nil,
                        tokens_out = message_data._usage and message_data._usage.output_tokens or nil,
                        tokens_reasoning = message_data._usage and message_data._usage.reasoning_tokens or nil,
                        web_search_used = web_search_flag,
                        used_research_mode = research_mode_active or nil,
                        updated_by_auto = message_data._background_request or nil,
                        previous_progress_decimal = message_data.cached_progress_decimal,
                        flow_visible_pages = message_data.flow_visible_pages,
                        progress_page = message_data.progress_page,
                        full_document = config.features and config.features._full_document_xray or nil,
                        coverage_spans = xray_spans,
                        producer = xray_producer,
                        base_timestamp = xray_base_ts,
                        timestamp = xray_fold_ts,
                        unavailable_data_text = unavailable_text,
                        xray_categories = message_data._xray_categories_applied,
                      xray_depth = message_data._xray_depth_applied,
                    }
                    -- Archive the pre-overwrite snapshot (ring of 5; incremental updates
                    -- AND redos/regenerations, manual AND background — xray_ecosystem_plan.md
                    -- §5 decision 2). Read disk truth rather than message_data.cached_*:
                    -- it carries the full permission metadata and archives whatever entry
                    -- is actually being overwritten (a racing write may be newer than the
                    -- one this run started from). SKIP when the outgoing entry is a ladder
                    -- rung (shared archive rule, slice 2): a promoted rung getting
                    -- ring-archived on the next update would dup it and evict real history.
                    -- Deferred rebuild (round 25): this IS the rebuild's
                    -- destructive moment. The outgoing version is archived even
                    -- when it is a promoted rung — the rebuild deletes the old
                    -- lineage's ladder right below, so the rung would otherwise
                    -- be the copy nothing kept.
                    local rebuilding = config.features and config.features._xray_rebuild
                    local prev_xray = ActionCache.getXrayCache(cache_file)
                    -- cache_answer guard (round 28): a skipped write must not
                    -- ring-archive the survivor it is leaving in place
                    if cache_answer and prev_xray and prev_xray.result and prev_xray.result ~= cache_answer
                        and (rebuilding or not ActionCache.isXrayLadderRung(cache_file, prev_xray)) then
                        ActionCache.pushXrayCheckpoint(cache_file, prev_xray,
                            ActionCache.checkpointLimitFromFeatures(config.features))
                    end
                    local xray_success = ActionCache.setXrayCache(cache_file, cache_answer, progress, xray_metadata)
                    if xray_success then
                        -- Post-update dedup ask (round 18): ATTENDED X-Ray
                        -- writes offer a duplicate review when the scan finds
                        -- pairs never offered before (background/ladder runs
                        -- stay silent — xray_producer gates them out)
                        if xray_producer == "manual" and plugin and plugin.maybeOfferDedupAsk then
                            local ask_file = cache_file
                            UIManager:scheduleIn(1, function()
                                plugin:maybeOfferDedupAsk(ask_file)
                            end)
                        end
                        -- Old-lineage rungs die WITH the successful write, never
                        -- before it (must precede this run's own rung push)
                        if rebuilding then
                            ActionCache.clearXrayLadder(cache_file)
                            logger.info("KOAssistant: rebuild committed - old X-Ray archived, old ladder cleared")
                        end
                        logger.dbg("KOAssistant: Saved X-Ray to reusable cache at", progress, "used_highlights=", used_highlights, "used_book_text=", book_text_was_provided)
                        -- Slice 2 (item 37(c)): fold the manual point into the
                        -- ladder — it is now a timeline point kept like any
                        -- checkpoint, not just live until the ring prunes its
                        -- archive. Non-JSON results stay out (rungs feed delta
                        -- merges); the shared timestamp makes isXrayLadderRung
                        -- recognize live == this rung on the next overwrite.
                        if xray_fold_ts and progress > 0
                            and require("koassistant_xray_parser").isJSON(cache_answer) then
                            ActionCache.pushXrayLadderRung(cache_file, {
                                result = cache_answer,
                                progress_decimal = progress,
                                progress_page = message_data.progress_page,
                                timestamp = xray_fold_ts,
                                model = model_name,
                                used_highlights = used_highlights,
                                used_book_text = book_text_was_provided,
                                flow_visible_pages = message_data.flow_visible_pages,
                                source_mode = source_mode,
                                coverage_spans = xray_spans,
                                producer = xray_producer,
                                base_timestamp = xray_base_ts,
                            })
                        end
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
                        tokens_in = message_data._usage and message_data._usage.input_tokens or nil,
                        tokens_out = message_data._usage and message_data._usage.output_tokens or nil,
                        tokens_reasoning = message_data._usage and message_data._usage.reasoning_tokens or nil,
                        web_search_used = web_search_flag,
                        full_document = true,
                        source_mode = source_mode,
                        scope_label = section_scope.label,
                        scope_start_page = section_scope.start_page,
                        scope_end_page = section_scope.end_page,
                        scope_start_xpointer = section_scope.start_xpointer,
                        scope_end_xpointer = section_scope.end_xpointer,
                        scope_page_summary = section_scope.page_summary,
                        -- Timeline slice 1: a section point covers exactly its scope
                        coverage_spans = (section_scope.start_page and section_scope.end_page)
                            and (section_scope.start_page .. "-" .. section_scope.end_page) or nil,
                        producer = "manual",
                        unavailable_data_text = unavailable_text,
                    }
                    local section_success = ActionCache.set(cache_file, section_scope.cache_key, cache_answer, 1.0, section_metadata)
                    if section_success then
                        logger.dbg("KOAssistant: Saved section artifact to", section_scope.cache_key)
                    end
                end

                if action.cache_as_analyze then
                    local analyze_metadata = {
                        model = model_name,
                        used_book_text = book_text_was_provided,
                        used_reasoning = (reasoning ~= nil and reasoning ~= ""),
                        tokens_in = message_data._usage and message_data._usage.input_tokens or nil,
                        tokens_out = message_data._usage and message_data._usage.output_tokens or nil,
                        tokens_reasoning = message_data._usage and message_data._usage.reasoning_tokens or nil,
                        web_search_used = web_search_flag,
                        flow_visible_pages = message_data.flow_visible_pages,
                        unavailable_data_text = unavailable_text,
                    }
                    local analyze_success = ActionCache.setAnalyzeCache(cache_file, answer, 1.0, analyze_metadata)
                    if analyze_success then
                        logger.dbg("KOAssistant: Saved document analysis to reusable cache, used_book_text=", book_text_was_provided)
                    end
                end

                if action.cache_as_summary then
                    -- Include language in metadata for cache viewer awareness
                    local summary_metadata = {
                        model = model_name,
                        language = temp_config.features and temp_config.features.translation_language or "English",
                        used_book_text = book_text_was_provided,
                        used_reasoning = (reasoning ~= nil and reasoning ~= ""),
                        tokens_in = message_data._usage and message_data._usage.input_tokens or nil,
                        tokens_out = message_data._usage and message_data._usage.output_tokens or nil,
                        tokens_reasoning = message_data._usage and message_data._usage.reasoning_tokens or nil,
                        web_search_used = web_search_flag,
                        flow_visible_pages = message_data.flow_visible_pages,
                        unavailable_data_text = unavailable_text,
                    }
                    local summary_success = ActionCache.setSummaryCache(cache_file, answer, 1.0, summary_metadata)
                    if summary_success then
                        logger.dbg("KOAssistant: Saved document summary to reusable cache with language:", summary_metadata.language, "used_book_text=", book_text_was_provided)
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

            -- Carry layer 3(iii): the pre-create fold ask already ran (Step 0)
            -- — an accepted fold now executes against the freshly written
            -- cache; when no ask applied, the one uncovered case (previous
            -- book without an X-Ray) gets its informational gap note.
            -- Background and ladder builds seed silently instead — no dialog
            -- while reading (maintainer decision 2026-08-06); updates never
            -- re-offer
            if action.cache_as_xray and cache_answer and cache_file
                and not is_truncated and not background_discard
                and xray_producer == "manual" and not using_cache
                and not (config.features and (config.features._section_scope
                    or config.features._section_xray))
                and require("koassistant_xray_parser").isJSON(cache_answer) then
                local offer_meta = message_data.book_metadata or {}
                local fold_mode = message_data._fold_after_create
                local was_asked = message_data._precreate_fold_asked
                UIManager:nextTick(function()
                    local XrayMerge = require("koassistant_xray_merge")
                    if fold_mode then
                        XrayMerge.runPostCreateFold({
                            file = cache_file,
                            title = offer_meta.title,
                            author = offer_meta.author,
                            ui = ui, plugin = plugin, configuration = config,
                            mode = fold_mode,
                        })
                    elseif not was_asked then
                        XrayMerge.maybeNotePredecessorGap({ file = cache_file, ui = ui })
                    end
                end)
            end

            -- Round 28 (#90, field-requested): an unusable X-Ray response on an
            -- ATTENDED run gets a one-tap retry — same action, same scope, full
            -- re-run (extraction is local). The artifact was left untouched
            -- above. Unattended machinery (auto/ladder) keeps its own
            -- transient-retry path and must not pop dialogs mid-read.
            if xray_unusable and not (message_data._background_request
                or message_data._background_create or message_data._ladder_build) then
                local ConfirmBox = require("ui/widget/confirmbox")
                UIManager:nextTick(function()
                    UIManager:show(ConfirmBox:new{
                        text = T(_("X-Ray not saved: %1.\n\nNothing was overwritten. Models sometimes return a broken response; trying again usually works."), xray_unusable),
                        ok_text = _("Try again"),
                        ok_callback = function()
                            handlePredefinedPrompt(unpack(retry_args, 1, 9))
                        end,
                        cancel_text = _("Close"),
                    })
                end)
            end

            if on_complete then
                on_complete(history, temp_config)
            end
        else
            -- Treat empty answer as error. When the model returned REASONING but
            -- no answer, say so — the generic message sent issue #98 chasing the
            -- wrong cause for two rounds. The streaming path makes the same
            -- distinction; this branch is its non-streaming twin (no truncation
            -- signal is available here, so it uses the softer of the two).
            if success and (not answer or answer == "") then
                if type(reasoning) == "string" and reasoning ~= "" then
                    err = _("The model produced only reasoning and no answer text. Try again.")
                else
                    err = _("No response received from AI")
                end
            end
            if on_complete then
                on_complete(nil, err or "Unknown error")
            end
        end
    end

    -- Wrap the API call so it can be deferred by the large extraction warning dialog
    local function sendQuery()
        -- Route through queryWith (not queryChatGPT directly) so the ⚡ quick-retry is
        -- intercepted here too (input safety net S3): predefined actions send their FIRST
        -- answer on this path, and without the wrapper the retry sentinel would leak into
        -- handleResponse's error display. Predefined actions carry _tools_active=false, so
        -- shouldUse returns false and this stays a plain send — queryWith just adds the
        -- quick-retry interception. This is the only send path that bypassed queryWith.
        local result = BookToolRunner.queryWith(queryChatGPT, history:getMessages(), temp_config, handleResponse, plugin, ui)

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
    -- Item 50 follow-up 2: deltas count everywhere — a manual "update to 100%"
    -- of a big book is as large as a create, and book_text/full_document miss it
    if message_data.incremental_book_text then extracted_chars = extracted_chars + #message_data.incremental_book_text end

    -- Model-aware context pre-check (fail-open): speaks only when the dispatch
    -- model's input window is KNOWN (ModelConstraints._context_windows) and even
    -- the LOW token estimate exceeds it — so it can fire BELOW the char
    -- threshold on small-window models, and stays silent on unknown models.
    -- Rides the same warning dialogs and the same suppress flag.
    local function contextWindowNote(chars)
        -- One model id per request (audit B3): the same resolver the memo key
        -- and the answer budget use, so a nil config.model (first API key save,
        -- a tier pin the provider lacks) still checks the model that is sent.
        -- The per-request config, when there is one, answers ALONE: an action
        -- pinned to another provider carries no model of its own, and falling
        -- back to the global model here would check a foreign provider's id
        -- (re-audit 2026-09-04).
        local src = temp_config or config
        local p = src.provider
        local m = ModelConstraints.dispatchModel({ provider = p, model = src.model,
            features = src.features })
        local exceeded, window = ModelConstraints.checkContextWindow(p, m, chars)
        if not exceeded then return nil end
        return T(_("This likely exceeds the current model's context window (%1: ~%2K tokens). Pick a smaller scope or switch models."),
            m, math.floor(window / 1000))
    end

    -- Step 3: Large sidecar data warning for multi-book actions (always warn, no suppress)
    local sidecar_chars = message_data._total_sidecar_chars or 0
    local function checkSidecarDataAndSend()
        local cw_note = contextWindowNote(sidecar_chars)
        if sidecar_chars > Constants.LARGE_EXTRACTION_THRESHOLD or cw_note then
            local chars_k = math.floor(sidecar_chars / 1000)
            local tokens_low = math.floor(sidecar_chars / 4000)
            local tokens_high = math.floor(sidecar_chars / 2000)
            local book_count = message_data.books_info and #message_data.books_info or 0
            local warning_title = T(_("Large sidecar data: ~%1K characters (~%2K-%3K tokens) across %4 books. Make sure your model's context window can accommodate this.\n\nConsider selecting fewer books or using actions that don't require highlights/annotations."), chars_k, tokens_low, tokens_high, book_count)
            if cw_note then warning_title = warning_title .. "\n\n" .. cw_note end
            local warning_dialog
            warning_dialog = ButtonDialog:new{
                title = warning_title,
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
        local cw_note = contextWindowNote(extracted_chars)
        if (extracted_chars > Constants.LARGE_EXTRACTION_THRESHOLD or cw_note)
                and not (config.features and config.features.suppress_large_extraction_warning) then
            local chars_k = math.floor(extracted_chars / 1000)
            local tokens_low = math.floor(extracted_chars / 4000)
            local tokens_high = math.floor(extracted_chars / 2000)
            -- Round 22 (§25(f)): for a one-request X-Ray run on an open
            -- flowing book, the checkpoint escape is a button, not just prose.
            -- Item 50 follow-up 3: incremental UPDATES offer it too — an
            -- extend-from-base ladder covers the same base→goal range in
            -- bounded steps (the round-22 exclusion predates extend
            -- planning). Section-scoped runs stay excluded: a checkpoint
            -- build would silently change their scope.
            local is_incremental = message_data.incremental_book_text ~= nil
            local section_scoped = config.features
                and (config.features._section_scope or config.features._section_xray) or false
            local xray_checkpoint_offer = prompt and prompt.cache_as_xray
                and not section_scoped
                and plugin and plugin._startXrayLadderBuild
                and ui and ui.document and ui.document.info and not ui.document.info.has_pages
            -- Item 50 follow-up 4: the advice line matches what is actually
            -- being sent — section-scoped runs must not be told to "use
            -- sections", and the checkpoint sentence appears only when the
            -- checkpoint button actually exists (it was showing on non-X-Ray
            -- actions too)
            local warning_title = T(_("Large text extraction: ~%1K characters (~%2K-%3K tokens). Make sure your model's context window can accommodate this."), chars_k, tokens_low, tokens_high)
            local advice
            if is_incremental then
                advice = xray_checkpoint_offer
                    and _("This update reads the rest of the range in one request. \"Continue in checkpoints instead\" covers it in bounded steps, so each individual request stays small.")
                    or nil
            elseif section_scoped then
                advice = _("This section scope is still a large request. You can pick a smaller range, or use KOReader's Hidden Flows to exclude irrelevant content.")
            else
                advice = _("You can focus on a specific section or section range instead, or use KOReader's Hidden Flows to exclude irrelevant content.")
            end
            if xray_checkpoint_offer and not is_incremental then
                advice = advice .. " " .. _("\"Build in checkpoints\" reads the same text in bounded steps, so each individual request stays small.")
            end
            if advice then
                warning_title = warning_title .. "\n\n" .. advice
            end
            if cw_note then
                warning_title = warning_title .. "\n\n" .. cw_note
            end
            local warning_dialog
            local warning_buttons = {}
            warning_buttons[#warning_buttons + 1] = {{
                text = _("Cancel"),
                callback = function()
                    UIManager:close(warning_dialog)
                end,
            }}
            if xray_checkpoint_offer then
                warning_buttons[#warning_buttons + 1] = {{
                    text = is_incremental and _("Continue in checkpoints instead…")
                        or _("Build in checkpoints instead…"),
                    callback = function()
                        UIManager:close(warning_dialog)
                        local target
                        local to_full = is_incremental and config.features
                            and config.features._update_to_full_progress
                        if not message_data.full_document and not to_full then
                            -- "Up to where I am" (create) or a position-target
                            -- update: bound the checkpoint build to the same
                            -- coverage
                            local ContextExtractor = require("koassistant_context_extractor")
                            local prog = ContextExtractor:new(ui):getReadingProgress()
                            local d = prog and tonumber(prog.decimal)
                            if d and d > 0.01 and d < 0.995 then target = d end
                        end
                        plugin:_startXrayLadderBuild(target and { target = target } or nil)
                    end,
                }}
            end
            warning_buttons[#warning_buttons + 1] = {{
                text = _("Continue"),
                callback = function()
                    UIManager:close(warning_dialog)
                    checkSidecarDataAndSend()
                end,
            }}
            warning_buttons[#warning_buttons + 1] = {{
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
            }}
            warning_dialog = ButtonDialog:new{
                title = warning_title,
                buttons = warning_buttons,
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
            logger.dbg("KOAssistant: background X-Ray update aborted - delta exceeded extraction limit")
            if on_complete then on_complete(nil, "background: delta truncated") end
            return nil
        end
        -- Create mode: same honesty rule for the base to-position extraction — a
        -- silently-truncated first X-Ray would record progress its text doesn't cover
        if message_data._background_create and message_data.book_text_truncated then
            logger.dbg("KOAssistant: background X-Ray create aborted - extraction exceeded limit")
            if on_complete then on_complete(nil, "background: extraction truncated") end
            return nil
        end
        -- A2 naming canon on the DEFAULT create path (maintainer 2026-08-11:
        -- silent injection). Background and ladder creates never reach the
        -- attended fold ask (Step 0 below), so grouped background creates
        -- named recurring entities without the alias bridge — diverging from
        -- attended ones. Same gate and same post-build injection as Step 0;
        -- no dialog, and the fold itself stays manual at the group screen /
        -- attended surfaces. `not using_cache` scopes this to name-birthing
        -- requests (first rung, intro, one-shot create, rebuild) — updates
        -- carry the entity index instead.
        if prompt and prompt.cache_as_xray and not using_cache and cache_file
            and not (config.features and (config.features._section_scope
                or config.features._section_xray)) then
            local XrayMerge = require("koassistant_xray_merge")
            local src = XrayMerge.seedSource(cache_file, config.features,
                temp_config and temp_config.provider, ui)
            local canon = src and XrayMerge.namingCanonBlock(src.parsed, src.title)
            if canon then
                local msgs = history:getMessages()
                for i = 1, #msgs do
                    if msgs[i].role == "user" and msgs[i].is_context then
                        msgs[i].content = msgs[i].content .. "\n\n" .. canon
                        break
                    end
                end
                logger.dbg("KOAssistant: naming canon injected into background X-Ray create, source:",
                    src.title)
            end
        end
        -- Item 50 follow-up (rounds 2): background size safeguard. The FIRST
        -- request of a user-initiated build may dialog — it fires right after
        -- the confirm tap, so that moment is attended; acceptance sticks on
        -- the build state (module singleton, same channel as the retry
        -- counter). LATER steps never dialog: an oversized one with no
        -- standing acceptance PAUSES the chain for review (resuming re-arms
        -- the attended warning). Non-ladder background requests (scheduled
        -- auto updates) keep today's silent send. The announce toast rides
        -- _ladder_send_toast and fires only when the request actually goes —
        -- nothing may announce a build the size warning can still cancel.
        local xb_build = config.features and config.features._ladder_build
            and require("koassistant_xray_auto").ladderBuild() or nil
        local function ladderSendToast()
            local toast = config.features and config.features._ladder_send_toast
            if toast then
                UIManager:show(require("ui/widget/notification"):new{ text = toast })
            end
        end
        local ladder_cw_note = contextWindowNote(extracted_chars)
        local size_ok = (extracted_chars <= Constants.LARGE_EXTRACTION_THRESHOLD
                and not ladder_cw_note)
            or (config.features and config.features.suppress_large_extraction_warning)
            or (xb_build and xb_build.size_ack)
        if not size_ok and config.features and config.features._ladder_size_check then
            local chars_k = math.floor(extracted_chars / 1000)
            local tokens_low = math.floor(extracted_chars / 4000)
            local tokens_high = math.floor(extracted_chars / 2000)
            local size_dialog
            local size_buttons = {}
            size_buttons[#size_buttons + 1] = {{
                text = _("Cancel"),
                callback = function()
                    UIManager:close(size_dialog)
                    if on_complete then on_complete(nil, "size_warning_declined") end
                end,
            }}
            -- Follow-up 3: one-shots offer the checkpoint escape here too
            -- (chains don't — they ARE checkpoints; their recourse is the
            -- confirm's spacing adjuster)
            if xb_build and xb_build.total == 1 then
                size_buttons[#size_buttons + 1] = {{
                    text = _("In checkpoints instead…"),
                    callback = function()
                        UIManager:close(size_dialog)
                        if on_complete then on_complete(nil, "size_switch_checkpoints") end
                    end,
                }}
            end
            size_buttons[#size_buttons + 1] = {{
                text = _("Don't warn again"),
                callback = function()
                    UIManager:close(size_dialog)
                    if plugin and plugin.settings then
                        local features_tbl = plugin.settings:readSetting("features") or {}
                        features_tbl.suppress_large_extraction_warning = true
                        plugin.settings:saveSetting("features", features_tbl)
                        plugin.settings:flush()
                    end
                    if config.features then
                        config.features.suppress_large_extraction_warning = true
                    end
                    if xb_build then xb_build.size_ack = true end
                    ladderSendToast()
                    sendQuery()
                end,
            }}
            size_buttons[#size_buttons + 1] = {{
                text = _("Continue"),
                callback = function()
                    UIManager:close(size_dialog)
                    if xb_build then xb_build.size_ack = true end
                    ladderSendToast()
                    sendQuery()
                end,
            }}
            size_dialog = ButtonDialog:new{
                title = T(_("Large text extraction: ~%1K characters (~%2K-%3K tokens) in this background request. Make sure your model's context window can accommodate this."), chars_k, tokens_low, tokens_high)
                    .. (ladder_cw_note and ("\n\n" .. ladder_cw_note) or ""),
                buttons = size_buttons,
            }
            UIManager:show(size_dialog)
            return nil
        elseif not size_ok and xb_build then
            logger.dbg("KOAssistant: ladder step paused - oversized request needs review")
            if on_complete then on_complete(nil, "size_needs_review") end
            return nil
        end
        ladderSendToast()
        return sendQuery()
    end

    -- Steps 1-3 bundled (the fold ask below must be able to defer them): the
    -- attended warning chain exactly as it always ran.
    local function runPreSendWarnings()

    -- Step 0.5 (A8): extraction attempted but produced ZERO text — a scanned
    -- or image-only file is the real case. Without this the request sends
    -- with {text_fallback_nudge} and the reader pays for an answer that never
    -- saw their book. Attended paths only; background X-Ray machinery is
    -- flowing-only and never reaches this with an empty extraction.
    if not message_data._background_request
            and (message_data.book_text_extraction_empty
                or message_data.full_document_extraction_empty) then
        local empty_dialog
        local empty_title = message_data.extraction_empty_at_start
            and _("You're at the very beginning of this book, so there is no text before your position to send.\n\nSending anyway means the AI answers from general knowledge, not this book's text.")
            or _("No text could be extracted from this document — it may be a scanned or image-only file.\n\nSending anyway means the AI answers from general knowledge, not this book's text.")
        empty_dialog = ButtonDialog:new{
            title = empty_title,
            buttons = {
                {{
                    text = _("Cancel"),
                    callback = function()
                        UIManager:close(empty_dialog)
                    end,
                }},
                {{
                    text = _("Send anyway"),
                    callback = function()
                        UIManager:close(empty_dialog)
                        checkLargeExtractionAndSend()
                    end,
                }},
            },
        }
        UIManager:show(empty_dialog)
        return nil  -- Early return; continuation via callback
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
        -- Item 50 follow-up 4: same source-awareness as the size warning —
        -- no "use sections" advice on already-section-scoped runs, and the
        -- checkpoint sentence only on runs the escape actually applies to
        local trunc_section_scoped = config.features
            and (config.features._section_scope or config.features._section_xray)
        truncation_msg = truncation_msg .. "\n\n"
            .. (trunc_section_scoped
                and _("You can increase the limit in Settings → Privacy & Data → Text Extraction, pick a smaller range, or use Hidden Flows to exclude irrelevant content.")
                or _("You can increase the limit in Settings → Privacy & Data → Text Extraction, use Hidden Flows to exclude irrelevant content, or focus on a specific section or section range."))
        if prompt and prompt.cache_as_xray and not trunc_section_scoped
                and not message_data.incremental_book_text then
            truncation_msg = truncation_msg .. " " .. _("\"Build in checkpoints\" reads the same text in bounded steps, so each individual request stays small.")
        end
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

    end -- runPreSendWarnings

    -- Step 0 (carry layer 3(iii), 2026-08-06): pre-create fold ask — an
    -- attended FRESH main X-Ray of a grouped book whose previous book has an
    -- X-Ray asks about folding BEFORE the create runs. Accepting stashes the
    -- choice for handleResponse (auto-fold when the create lands) and injects
    -- the naming canon into the already-built context message — post-build,
    -- so the canon never meets the placeholder pass (merge-module
    -- wire-safety rule). Declining sends the create untouched. Background
    -- and ladder paths returned above and never reach this — their creates
    -- get the canon SILENTLY in the background branch (A2, same gate).
    if prompt and prompt.cache_as_xray and not using_cache and cache_file
        and not (config.features and (config.features._section_scope
            or config.features._section_xray)) then
        local XrayMerge = require("koassistant_xray_merge")
        local asked = XrayMerge.preCreateFoldAsk(
            { file = cache_file, ui = ui, configuration = config },
            function(mode)
                -- Round 28: explicit abort — nothing was sent, so there is
                -- nothing to clean up; just don't continue the pre-send chain
                if mode == "cancel" then return end
                message_data._precreate_fold_asked = true
                if mode then
                    message_data._fold_after_create = mode
                    local src = XrayMerge.seedSource(cache_file, config.features,
                        temp_config and temp_config.provider, ui)
                    local canon = src and XrayMerge.namingCanonBlock(src.parsed, src.title)
                    if canon then
                        local msgs = history:getMessages()
                        for i = 1, #msgs do
                            if msgs[i].role == "user" and msgs[i].is_context then
                                msgs[i].content = msgs[i].content .. "\n\n" .. canon
                                break
                            end
                        end
                    end
                end
                runPreSendWarnings()
            end)
        if asked then return nil end -- continuation via the ask's callback
    end

    return runPreSendWarnings()
end

--- Format artifact metadata for popup display (e.g., "X-Ray (100%, today)")
--- Shared meta (A4 parity with the Book Hub rows): percent always when tracked
--- @param cache table Artifact cache entry with name, data.progress_decimal, data.timestamp
--- @return string Formatted display text
local function formatArtifactDisplayText(cache)
    local meta = Constants.formatArtifactMeta(cache.data)
    if meta then return cache.name .. " (" .. meta .. ")" end
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
                note = _("Searched the book: 1 lookup")
            else
                note = T(_("Searched the book: %1 lookups"), n)
            end
            UIManager:show(Notification:new{ text = note, timeout = 2 })
            proceed()
        end,
    })
end

-- Attach chip label (attach_plan.md v1): a count, not ON/OFF — attach is a
-- collection, not a toggle (empty shows 0/plain). Shared by the input dialog's
-- Attach chip and the reply dialog's Attach chip.
local function attachChipLabel(enable_emoji)
    local count = require("koassistant_attachments").count()
    if count > 0 then
        return enable_emoji and ("\u{1F4CE} " .. tostring(count))
            or T(_("Attach (%1)"), count)
    end
    return enable_emoji and "\u{1F4CE} 0" or _("Attach")
end

-- Attach chip menu (attach_plan.md v1) — the type-picker + manage submenu, factored
-- out of showChatGPTDialog so the reply dialog (chatgptviewer) can open the SAME menu
-- via a runtime require (runtime self-require pattern; no load-time cycle). The
-- staged list is MODULE-resident in koassistant_attachments; `on_change` re-renders
-- whichever dialog opened the menu (the input dialog's refreshInputDialog, or the
-- reply dialog's reopenWithDraft). Returns { open = typeMenuFn, manage = manageFn } so
-- callers can wire tap vs hold. opts = { configuration, ui, document_path, enable_emoji,
-- chips_book_or_highlight, on_change }.
local function showAttachMenu(opts)
    opts = opts or {}
    local configuration = opts.configuration or {}
    local feats = configuration.features or {}
    local enable_emoji = opts.enable_emoji == true
    local ui_instance = opts.ui
    local document_path = opts.document_path
    local chips_book_or_highlight = opts.chips_book_or_highlight
    local on_change = opts.on_change or function() end

    -- Manage list (hold, or the "manage…" row): stays open across removals,
    -- fires on_change once at close — the Toolbar-Buttons-manager pattern.
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
                        on_change()
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
                    on_change()
                end,
            }})
        end
        table.insert(rows, {{
            text = _("Close"),
            callback = function()
                UIManager:close(manage_dialog)
                if changed then on_change() end
            end,
        }})
        manage_dialog = require("ui/widget/buttondialog"):new{
            title = _("Attached to this chat"),
            buttons = rows,
            tap_close_callback = function()
                if changed then on_change() end
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
                text = T(_("Attached (%1): manage…"), n),
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
                    -- Same gate as use_notebook (attach_plan.md §4); trusted
                    -- providers bypass as elsewhere; the per-book privacy
                    -- override wins in both directions (deny beats trusted).
                    local allowed = feats.enable_notebook_sharing == true
                        or Attachments.isTrustedProvider(feats, configuration.provider)
                    local nb_ok, nb_ds = pcall(function()
                        return require("koassistant_doc_settings").resolve(book_path, ui_instance)
                    end)
                    if nb_ok and nb_ds then
                        local ov = require("koassistant_book_settings").effectivePrivacyOverrides(nb_ds).notebook
                        if ov ~= nil then allowed = ov end
                    end
                    if not allowed then
                        UIManager:show(InfoMessage:new{
                            text = _("Attaching your notebook needs \"Notebook sharing\" (Settings → Privacy & Data, or this book's Privacy overrides)."),
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
                    on_change()
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
                            on_change()
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
                                on_change()
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
                        on_change()
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
                    input_hint = _("Background context for this whole chat. Sent alongside your messages as a note from you, not as a question.\ne.g. \"this is the 2nd edition\", \"I'm reading this for a course\", \"the file's author metadata is wrong\""),
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
                                on_change()
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
    return { open = showTypeMenu, manage = showManage }
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
        -- Same hygiene for the X-Ray-chat marker: performSend re-derives it per
        -- send (is_xray_chat), but a fresh non-X-Ray dialog must not inherit a
        -- stale true from an earlier X-Ray chat (reply Tools toggle + shouldUse
        -- both read it off the chat's config).
        configuration.features._xray_chat_active = nil
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
            -- Quick-pin touch marks (A9 (b)): same lifecycle as the chip state —
            -- survive a refresh, cleared on a fresh open
            configuration.features._session_web_touched = nil
            configuration.features._session_tools_touched = nil
            -- Per-request context dials (round 5, maintainer): direction and
            -- amount overrides picked from the Ctx chip's tap popup — same
            -- config-resident session lifecycle as the mode above.
            configuration.features._session_ctx_direction = nil
            configuration.features._session_ctx_chars = nil
            configuration.features._session_ctx_paragraphs = nil
            configuration.features._session_ctx_spoiler_limit = nil
            configuration.features._session_ctx_label_stale = nil
            -- Quick-controls chip state (controls_parity_plan.md §2/§9): same
            -- config-resident lifecycle as the scope pick — survives a refresh
            -- via the marker, cleared on a fresh open — then SEEDED from the
            -- resolved Quick Answer DEFAULT (global + per-book override, §8c.7
            -- tools-posture parity, 2026-07-20): true = chip starts ON; the
            -- session chip wins once touched. Book-scoped contexts consult the
            -- open book's override; general/library follow the global only.
            local qa_ds
            if not (configuration.features.is_general_context
                or configuration.features.is_library_context) then
                -- Resolve the TARGET book (closed-book / X-Ray chat / Book
                -- Hub launches carry it in book_metadata.file), not the
                -- open one (injection_gating_audit #55).
                qa_ds = require("koassistant_doc_settings").resolve(
                    (configuration.features.book_metadata or {}).file, ui_instance)
                    or (ui_instance and ui_instance.doc_settings) or nil
            end
            configuration.features._session_quick_answer =
                BookSettings.resolveQuickAnswerDefault(qa_ds, configuration.features)
                and true or nil
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
    local logger = require("koassistant_logger")
    logger.dbg("Using AI provider: " .. (configuration.provider or "anthropic"))
    
    -- Log configuration structure
    if configuration and configuration.features then
        logger.dbg("Configuration has features")
        if configuration.features.prompts then
            local count = 0
            for k, v in pairs(configuration.features.prompts) do
                count = count + 1
                logger.dbg("  Found configured prompt: " .. k)
            end
            logger.dbg("Total configured prompts: " .. count)
        else
            logger.dbg("No prompts in configuration.features")
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
            logger.dbg("KOAssistant: " .. ctx_label .. " chat launched from book - " .. doc_title)
        else
            logger.dbg("KOAssistant: " .. ctx_label .. " chat with no launch context")
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
        logger.dbg("KOAssistant: Document context - title: " .. (book_metadata.title or "nil") .. ", author: " .. (book_metadata.author or "nil"))
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
        logger.dbg("KOAssistant: File browser context - title: " .. (book_metadata.title or "nil") .. ", author: " .. (book_metadata.author or "nil"))
    else
        logger.dbg("KOAssistant: No metadata available in either context")
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

    -- Initialize session spoiler-free from the resolved posture (request layer:
    -- research mode > per-book override > global — spoiler_posture_plan.md §2, so
    -- an actively researched book seeds unchecked; tapping the chip back on is the
    -- session override and wins). Skipped when restored from a refresh (the user's
    -- session choice is preserved).
    if session_spoiler_free == nil then
        session_spoiler_free = require("koassistant_book_settings").resolveSpoilerFree(
            doc_settings, configuration and configuration.features)
    end

    -- Initialize the session "Book tools" toggle (D1): the effective default
    -- (per-book koassistant_book_tools > global enable_book_tools, binary since
    -- the 2026-08-12 collapse) sets the chip's starting state, the user flips it
    -- per session. Skipped when restored from a refresh (session choice preserved).
    if session_book_tools == nil then
        session_book_tools = require("koassistant_book_settings").resolveBookTools(
            doc_settings, configuration and configuration.features)
    end

    -- Initialize the session web-search toggle: per-book override > global default
    -- > provider native default (Perplexity seeds ON — it searches unless told not
    -- to, so the chip reflects reality and tapping it off actually disables via
    -- disable_search). Skipped when restored from a refresh (session choice
    -- preserved). Session-only — the top-row Web button no longer writes the global
    -- setting (lasting defaults live in Quick Settings and Book Settings).
    if session_web_search == nil then
        session_web_search = BookSettings.resolveWebSearch(
            doc_settings, configuration and configuration.features,
            configuration and configuration.provider)
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

        local global_domain_label = nil
        for _i, d in ipairs(sorted_domains) do
            if d.id == selected_domain then
                global_domain_label = d.name or d.display_name or d.id
                break
            end
        end
        local state = {
            domains = sorted_domains,
            has_book = doc_settings ~= nil,
            is_book_target = (doc_settings and domain_target == "book") or false,
            book_domain = book_domain_id,
            global_domain = selected_domain,
            global_domain_label = global_domain_label,
            book_research = book_research_id,
            global_research = configuration.features and configuration.features.research_mode,
            background_label = doc_settings and BookSettings.backgroundRowLabel(doc_settings) or nil,
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
            -- Background (book_background_plan.md §4): book target only. Reopens this
            -- picker so the row's preview refreshes; the input dialog itself is
            -- refreshed on close (the Domain chip label doesn't show Background).
            edit_background = function()
                UIManager:close(_G.domain_selector_dialog)
                BookSettings.showBackgroundEditor({
                    plugin = plugin, doc_settings = doc_settings,
                    on_close = showDomainSelector,
                })
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
        -- Effective state (A9 sitting 2026-08-17, pin-beats-preset (b)): while
        -- Quick holds an UNTOUCHED facet off, the chip says so instead of lying
        -- ON; a touched chip shows its own value (the pin), which dispatch honors.
        local eff = session_web_search
        local qf = configuration.features
        if require("koassistant_dialogs")
                .quickPresetForces("web", qf._session_quick_answer, qf) then
            eff = false
        end
        if enable_emoji then
            return "\u{1F310} " .. (eff and _("ON") or _("OFF"))
        end
        return eff and _("Web ON") or _("Web OFF")
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

        -- The CURRENT spoiler chip governs this action launch (spoiler_posture_plan.md
        -- §3 + C1): the smart-retrieval gather's reading scope reads the flag directly,
        -- and buildUnifiedRequestConfig folds it in as the SESSION layer of the
        -- per-action posture resolution (chip > research > book > global;
        -- skip_spoiler actions ignore it). Set just-in-time so a stale value from an
        -- earlier chat's Send never applies.
        configuration.features = configuration.features or {}
        configuration.features._spoiler_free_active = session_spoiler_free == true

        local additional_input = input_dialog:getInputText()
        -- Input safety net: stash typed input on the plugin instance (session-scoped,
        -- never flushed to disk) so a failed/cancelled send is recoverable via the
        -- gear's "Restore last input". See the gear menu + performSend stash below.
        if plugin and additional_input and additional_input ~= "" then
            plugin._last_input = additional_input
        end
        UIManager:close(input_dialog)
        if plugin then plugin.current_input_dialog = nil end

        -- Local-only actions (X-Ray Lookup): run the local handler and stop —
        -- this dispatch used to fall through to the API path, context-extracting
        -- and sending an EMPTY-prompt chat (device log 2026-08-13). Runtime
        -- self-require like attachRerunContext below (executeDirectAction is
        -- defined later in the file; a file-local ref would add an upvalue to
        -- showChatGPTDialog, which sits near the 60-upvalue LuaJIT cap). The
        -- dialog's own book beats whatever the reader has open.
        if action.local_handler then
            require("koassistant_dialogs").executeDirectAction(
                ui_instance, action, highlighted_text or "", configuration, plugin,
                document_path and { document_path = document_path } or nil)
            return
        end

        local function runAction()
            UIManager:scheduleIn(0.1, function()
                local function onPromptComplete(history, temp_config_or_error)
                    if history then
                        local temp_config = temp_config_or_error
                        -- Rerun row (switcher/Language/Ctx) for compact/translate views.
                        -- Runtime self-require: a file-local reference here would add an
                        -- upvalue to showChatGPTDialog (60-upvalue LuaJIT cap).
                        require("koassistant_dialogs").attachRerunContext(temp_config, action, ui_instance, plugin)
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
                            -- Same closed-book fallback as the WRITE path (book_metadata.file):
                            -- ui.document is nil for fb-dialog launches and mid-flight book
                            -- closes, and the bare read skipped the just-written artifact,
                            -- dropping it into the chat viewer (device 2026-08-17)
                            local file = (ui_instance and ui_instance.document and ui_instance.document.file)
                                or (temp_config.features and temp_config.features.book_metadata
                                    and temp_config.features.book_metadata.file)
                                or document_path
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
                            local file = (ui_instance and ui_instance.document and ui_instance.document.file)
                                or (temp_config.features and temp_config.features.book_metadata
                                    and temp_config.features.book_metadata.file)
                                or document_path
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
            if is_hl and popup_state.section_entry
                    and (popup_state.scope == "section" or popup_state.scope == "range") then
                configuration.features._highlight_section_scope = {
                    start_page = popup_state.section_entry.start_page,
                    end_page = popup_state.section_entry.end_page,
                }
            elseif is_hl and (popup_state.scope == "read_so_far"
                    or popup_state.scope == "from_section") then
                -- Consolidation P5: bounded so-far scopes for highlight actions —
                -- page 1 (or the picked section's start) up to the current page,
                -- riding the same extraction bound as the section scope above.
                local cur_page = ui_instance and ui_instance.view and ui_instance.view.state
                    and ui_instance.view.state.page or nil
                if cur_page then
                    configuration.features._highlight_section_scope = {
                        start_page = popup_state.scope == "from_section"
                            and popup_state.section_entry
                            and popup_state.section_entry.start_page or 1,
                        end_page = cur_page,
                    }
                end
            end
            if popup_state.source == "smart_retrieval" then
                -- Round 4 (maintainer): the SCOPE pick governs the tool session —
                -- "full" = the whole document (the Run consent covered unread
                -- reach under protection), "read_so_far" = tools clamped to the
                -- current position whatever the posture. The section-extraction
                -- transient is dropped: the tools own the bound here, and the
                -- gathered bundle replaces extraction. Consumed once by
                -- gatherForAction so it can never leak into a later chat session.
                configuration.features._highlight_section_scope = nil
                configuration.features._tool_reading_scope =
                    popup_state.scope == "read_so_far" and "current" or "full"
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
                    if cached.progress_decimal then
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
            local doc_props = SafeDocSettings.overlayCustomProps(ds:readSetting("doc_props"), entry.file)
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
                text = "\u{2611} " .. display .. " ·",
                callback = function()
                    UIManager:close(library_folder_dialog)
                    table.remove(session_state.adhoc_folders, idx)
                    syncLibraryState()
                    refreshInputDialog()
                end,
                hold_callback = function()
                    UIManager:show(InfoMessage:new{
                        text = T(_("%1\n\n(Session folder: uncheck to remove)"), folder_path),
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

        -- From a group (item 48(f)(i)): a group's members as a selection source
        local all_groups = require("koassistant_book_groups").all()
        if #all_groups > 0 then
            table.insert(menu_buttons, {{
                text = _("From a Group…"),
                callback = function()
                    UIManager:close(add_books_dialog)
                    local group_dialog
                    local group_rows = {}
                    for _idx, g in ipairs(all_groups) do
                        local captured = g
                        group_rows[#group_rows + 1] = {{
                            text = T(_("%1 (%2 books)"), captured.name, #captured.books),
                            align = "left",
                            callback = function()
                                UIManager:close(group_dialog)
                                local new_books = require("koassistant_book_groups")
                                    .booksInfoFor(captured, ui_instance)
                                if #new_books == 0 then
                                    UIManager:show(InfoMessage:new{
                                        text = _("No books from this group are available on this device."),
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
                        }}
                    end
                    group_dialog = ButtonDialog:new{
                        title = _("Add books from a group"),
                        buttons = group_rows,
                    }
                    UIManager:show(group_dialog)
                end,
            }})
        end

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
                            local doc_props = SafeDocSettings.overlayCustomProps(ds:readSetting("doc_props"), file)
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
                                    local doc_props = SafeDocSettings.overlayCustomProps(ds:readSetting("doc_props"), file)
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
                    configuration.features._group_launch = nil
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
            title = T(#books == 1 and _("%1 item selected: tap to remove") or _("%1 items selected: tap to remove"), #books),
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
            -- A9 (b) verify round: hide an ACCEPTING action's follows-default
            -- (🌐) when the ⚡ preset would strip web from its send — the chip
            -- label describes the freeform posture, the button badge the action
            quick_web_strip = require("koassistant_dialogs").quickPresetForces("web",
                configuration.features._session_quick_answer == true,
                configuration.features),
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
                -- Research indicator v2 (maintainer 2026-08-12): FRONT-positioned —
                -- chips truncate at the END, so the v1 suffix clipped behind any
                -- active domain. Emoji mode SWAPS the leading 🏛️ for 🔬 (zero width,
                -- reads as a mode flip); text mode prefixes "(research)" and lets the
                -- NAME truncate instead — research-on is the exceptional state, and
                -- the full name is one tap away. Book > global, matching the freeform
                -- resolution; per-request DOI auto-detection can't be known at chip
                -- time. The selector this chip opens is where research is toggled, so
                -- the marker sits on its own entry point and refreshes with it.
                local has_domain = (book_domain_id or selected_domain) and book_domain_id ~= "_none"
                local research_on = book_research_id == true
                    or (book_research_id == nil and configuration.features
                        and configuration.features.research_mode == true)
                local label
                if enable_emoji then
                    label = (research_on and "\u{1F52C} " or "\u{1F3DB}\u{FE0F} ")
                        .. getDomainDisplayName(true)
                else
                    label = has_domain and getDomainDisplayName(true) or _("Domain")
                    if research_on then
                        label = _("(research)") .. " " .. label
                    end
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
                        -- Pin-beats-preset (b): the tap flips the EFFECTIVE state
                        -- (an untouched facet reads OFF while Quick holds it), and
                        -- the touch is the pin — this chat's chip beats the preset.
                        local qf = configuration.features
                        local eff = session_web_search
                        if require("koassistant_dialogs")
                                .quickPresetForces("web", qf._session_quick_answer, qf) then
                            eff = false
                        end
                        session_web_search = not eff
                        qf._session_web_touched = true
                        -- Refresh FIRST so the toast paints above the reopened dialog
                        refreshInputDialog()
                        if qf._session_quick_answer and qf.quick_preset_web_off ~= false
                            and session_web_search then
                            UIManager:show(require("ui/widget/notification"):new{
                                text = _("Web search on (overrides Quick preset)"),
                            })
                        end
                    end,
                    hold_callback = function()
                        -- A general/library chat has no book subject even when a book is
                        -- open in the reader: withhold ui/document_path so the picker offers
                        -- Global only (no bogus "For this book" — and no per-book Search-depth
                        -- row — for an unrelated open book).
                        BookSettings.showWebSearch({
                            plugin = plugin,
                            ui = chips_book_or_highlight and ui_instance or nil,
                            document_path = chips_book_or_highlight and document_path or nil,
                            -- Re-seed from the (possibly changed) setting: a nil
                            -- session value skips the refresh marshal, so the
                            -- reopened dialog re-derives the chip from disk
                            -- (device 2026-08-05: hold-picker changes didn't
                            -- reach the chip until a fresh dialog)
                            on_close = function()
                                session_web_search = nil
                                -- Back to defaults = the pin dissolves too
                                configuration.features._session_web_touched = nil
                                refreshInputDialog()
                            end,
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
                local function holdPicker()
                    BookSettings.showToolsPosture({
                        plugin = plugin, ui = ui_instance, document_path = document_path,
                        -- Same re-seed as the Web chip: picker changes reach the chip
                        on_close = function()
                            session_book_tools = nil
                            -- Back to defaults = the pin dissolves too
                            configuration.features._session_tools_touched = nil
                            refreshInputDialog()
                        end,
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
                                msg = T(_("Book tools aren't available for %1.\n\nSupported providers: Gemini, Claude (Anthropic), OpenAI, OpenRouter, DeepSeek, Mistral, Groq, xAI."),
                                    configuration.provider or _("this provider"))
                            end
                            UIManager:show(InfoMessage:new{ text = msg })
                        end,
                        hold_callback = holdPicker,
                    }
                end
                if configuration.features._session_scope then
                    -- A Scope-chip pick attaches text directly — tools are redundant for
                    -- that send (chip wins, flexible_scope_plan.md §4; covers the
                    -- highlight facet's "Also send" pick too since 2026-08-17). Gray
                    -- with reason, like the other policy exclusions.
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
                -- Effective state under Quick (A9 sitting 2026-08-17, pin (b)):
                -- untouched + preset component on = reads OFF; touched = the pin.
                local tools_eff = session_book_tools
                do
                    local qf = configuration.features
                    if require("koassistant_dialogs")
                            .quickPresetForces("tools", qf._session_quick_answer, qf) then
                        tools_eff = false
                    end
                end
                return {
                    text = enable_emoji
                        and ("\u{1F50D} " .. (tools_eff and _("ON") or _("OFF")))
                        or (tools_eff and _("Tools ON") or _("Tools OFF")),
                    callback = function()
                        -- Pin-beats-preset (b): flip the EFFECTIVE state, touch = pin
                        local qf = configuration.features
                        local eff = session_book_tools
                        if require("koassistant_dialogs")
                                .quickPresetForces("tools", qf._session_quick_answer, qf) then
                            eff = false
                        end
                        session_book_tools = not eff
                        qf._session_tools_touched = true
                        -- Refresh FIRST so the toast paints above the reopened dialog
                        refreshInputDialog()
                        if qf._session_quick_answer and qf.quick_preset_tools_off ~= false
                            and session_book_tools then
                            UIManager:show(require("ui/widget/notification"):new{
                                text = _("Book tools on (overrides Quick preset)"),
                            })
                        end
                    end,
                    hold_callback = holdPicker,
                }
            end,
            quick = function()
                -- Quick chip (controls_parity_plan.md §2/§9 — #86): tap toggles the
                -- Quick Answer posture for this chat (concise · reasoning off ·
                -- web/tools off); hold opens the book/global DEFAULT picker with a
                -- "Preset settings…" row on top (Web/Tools-chip shape — the
                -- one-shot session reasoning/model menu retired 2026-08-11,
                -- maintainer: crowded, the preset covers it; on-the-fly picks
                -- move to the future per-action hold callbacks). State is
                -- CONFIG-RESIDENT (_session_quick_answer — 60-upvalue cap),
                -- consumed at dispatch via the *_active transients; a fresh
                -- dialog open clears it (scope-chip lifecycle).
                local qf = configuration.features
                local qa_on = qf._session_quick_answer == true
                local label
                if enable_emoji then
                    label = "\u{26A1} " .. (qa_on and _("ON") or _("OFF"))
                else
                    label = qa_on and _("Quick ON") or _("Quick")
                end
                return {
                    text = label,
                    callback = function()
                        -- A9 sitting 2026-08-17: the tap also tells the reader what
                        -- visibly changed (maintainer: short conditional toast).
                        -- Turning ON starts a FRESH preset application — pins form
                        -- from touches made WHILE Quick is on (option (b)), so
                        -- stale touch marks clear first. Chip labels recompute to
                        -- effective state on the refresh; values are not mutated.
                        -- (qf = the chip def's configuration.features local.)
                        local turning_on = not qa_on
                        local supports_web = ConfigHelper:supportsWebSearch(configuration)
                        -- Tools may only be NAMED in the toast when they could
                        -- actually flip: chip present AND session-eligible AND no
                        -- Scope pick forcing them off (A9 (b) verify round — the
                        -- consent/provider N/A states made the toast overclaim)
                        local tools_present = chips_book_or_highlight and has_open_book
                            and not is_xray_chat and not qf._session_scope
                        if tools_present then
                            tools_present = BookToolRunner.sessionEligible(configuration,
                                ui_instance) == true
                        end
                        local msg
                        if turning_on then
                            qf._session_web_touched = nil
                            qf._session_tools_touched = nil
                            local web_flips = qf.quick_preset_web_off ~= false
                                and session_web_search == true and supports_web
                            local tools_flips = qf.quick_preset_tools_off ~= false
                                and session_book_tools == true and tools_present
                            if web_flips and tools_flips then
                                msg = _("Quick answer: web search and book tools off for this chat")
                            elseif web_flips then
                                msg = _("Quick answer: web search off for this chat")
                            elseif tools_flips then
                                msg = _("Quick answer: book tools off for this chat")
                            end
                        else
                            -- Quick just turned OFF: was the preset holding the
                            -- facet? (quick_on=true names that prior state)
                            local QPF = require("koassistant_dialogs").quickPresetForces
                            local web_back = QPF("web", true, qf)
                                and session_web_search == true and supports_web
                            local tools_back = QPF("tools", true, qf)
                                and session_book_tools == true and tools_present
                            if web_back and tools_back then
                                msg = _("Quick answer off: web search and book tools back on")
                            elseif web_back then
                                msg = _("Quick answer off: web search back on")
                            elseif tools_back then
                                msg = _("Quick answer off: book tools back on")
                            end
                        end
                        qf._session_quick_answer = turning_on or nil
                        -- Refresh FIRST so the toast paints above the reopened dialog
                        refreshInputDialog()
                        if msg then
                            UIManager:show(require("ui/widget/notification"):new{ text = msg })
                        end
                    end,
                    hold_callback = function()
                        -- Same book-subject gate as the Web chip: in general/library
                        -- the picker targets Global only, never an unrelated open
                        -- book. On close the chip re-seeds from the (possibly
                        -- changed) default — spoiler/web-chip parity.
                        BookSettings.showQuickAnswerDefault({
                            plugin = plugin,
                            ui = chips_book_or_highlight and ui_instance or nil,
                            document_path = chips_book_or_highlight and document_path or nil,
                            preset_settings = function(chain_close)
                                -- Runtime self-require: a direct file-local ref would
                                -- add an upvalue to buildInputDialogButtons, which
                                -- sits AT LuaJIT's 60-upvalue cap.
                                require("koassistant_dialogs").showQuickPresetEditor({
                                    plugin = plugin,
                                    on_close = chain_close,
                                })
                            end,
                            on_close = function()
                                local qa_ds = chips_book_or_highlight
                                    and (require("koassistant_doc_settings").resolve(
                                        (configuration.features.book_metadata or {}).file,
                                        ui_instance)
                                    or (ui_instance and ui_instance.doc_settings)) or nil
                                local was_on = configuration.features._session_quick_answer == true
                                local now_on = BookSettings.resolveQuickAnswerDefault(qa_ds,
                                    configuration.features) and true or nil
                                if now_on and not was_on then
                                    -- OFF->ON through the picker = the same fresh
                                    -- preset application as the tap path (A9 (b)
                                    -- verify round): stale pre-Quick touches must
                                    -- not ride in as pins
                                    configuration.features._session_web_touched = nil
                                    configuration.features._session_tools_touched = nil
                                end
                                configuration.features._session_quick_answer = now_on
                                refreshInputDialog()
                            end,
                        })
                    end,
                }
            end,
            spoiler = function()
                if not chips_book_or_highlight then return nil end
                -- Shield + ON/OFF states the PROTECTION directly (maintainer 2026-08-16:
                -- now that the feature is named "Spoiler Protection" with the shield icon,
                -- the chip follows it; the old No-spoilers/Spoilers-OK outcome labels read
                -- inverted against the feature name). Emoji off: the name substitutes.
                local spoiler_state
                if session_spoiler_free then
                    spoiler_state = enable_emoji and ("\u{1F6E1}\u{FE0F} " .. _("ON")) or _("Spoiler Protection ON")
                else
                    spoiler_state = enable_emoji and ("\u{1F6E1}\u{FE0F} " .. _("OFF")) or _("Spoiler Protection OFF")
                end
                return {
                    text = spoiler_state,
                    callback = function()
                        session_spoiler_free = not session_spoiler_free
                        refreshInputDialog()
                    end,
                    hold_callback = function()
                        BookSettings.showSpoilerFree({
                            plugin = plugin, ui = ui_instance, document_path = document_path,
                            -- Same re-seed as the Web chip: picker changes reach the chip
                            on_close = function()
                                session_spoiler_free = nil
                                refreshInputDialog()
                            end,
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
                local pick = feats._session_scope
                -- pickScope serves BOTH facets (2026-08-17): the book facet's tap
                -- target, and the highlight facet's "Also send book text" row —
                -- same rows, same _session_scope, same Send-time machinery.
                -- (Body keeps its book-arm indentation for a minimal diff.)
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
                        -- Per-book privacy override — must agree with the Send-time
                        -- gate (deny beats trusted). Runtime requires only (60-cap).
                        do
                            local pv_ok, pv_ds = pcall(function()
                                return require("koassistant_doc_settings").resolve(nil, ui_instance)
                            end)
                            if pv_ok and pv_ds then
                                local ov = require("koassistant_book_settings")
                                    .effectivePrivacyOverrides(pv_ds).book_text
                                if ov ~= nil then consent = ov end
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
                        -- Chapter preset rows share the section/from_section kinds;
                        -- `preset` disambiguates the marks (round 6)
                        local cur_preset = feats._session_scope and feats._session_scope.preset or nil
                        local function mark(kind, preset)
                            return (kind == cur_kind and preset == cur_preset) and "● " or "○ "
                        end
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
                                            text = _("That section starts after your current position: pick an earlier one."),
                                        })
                                        refreshInputDialog()
                                        return
                                    end
                                    if kind == "section" and session_spoiler_free
                                        and entry.start_page > cur_page then
                                        -- Consent instead of rejection (device
                                        -- 2026-08-17): the reader may deliberately
                                        -- ask about an unread span; consenting also
                                        -- stands the spoiler nudge down for that
                                        -- request (spoiler_consented, read at Send)
                                        UIManager:show(require("ui/widget/confirmbox"):new{
                                            text = _("That section is beyond your current position and spoiler protection is on. Include it anyway? The answer will discuss that section."),
                                            ok_text = _("Include it"),
                                            ok_callback = function()
                                                feats._session_scope = {
                                                    kind = kind,
                                                    start_page = entry.start_page,
                                                    end_page = entry.end_page,
                                                    title = pickerEntryLabel(entry),
                                                    spoiler_consented = true,
                                                }
                                                refreshInputDialog()
                                            end,
                                            cancel_callback = function()
                                                refreshInputDialog()
                                            end,
                                        })
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
                        local function pickRangeEnd(start_entry, consented)
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
                                            spoiler_consented = consented or nil,
                                        }
                                    end
                                    refreshInputDialog()
                                end,
                            })
                        end
                        local function rangeRowPick()
                            if not consent then explainConsent() return end
                            UIManager:close(dialog)
                            plugin:_showSectionPicker({}, {
                                title = _("Range start: which section?"),
                                on_select = function(start_entry)
                                    if session_spoiler_free and start_entry.start_page > cur_page then
                                        -- Consent instead of rejection (device
                                        -- 2026-08-17), the section rows' sibling
                                        UIManager:show(require("ui/widget/confirmbox"):new{
                                            text = _("That range starts beyond your current position and spoiler protection is on. Use it anyway? The answer will discuss that part of the book."),
                                            ok_text = _("Use the range"),
                                            ok_callback = function()
                                                pickRangeEnd(start_entry, true)
                                            end,
                                            cancel_callback = function()
                                                refreshInputDialog()
                                            end,
                                        })
                                        return
                                    end
                                    pickRangeEnd(start_entry, false)
                                end,
                            })
                        end
                        local rows = {
                            {{ text = mark("none") .. (feats.is_book_context
                                and _("No book text (metadata only)")
                                or _("No extra book text")),
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
                        -- Current-chapter quick picks (round 6, maintainer): the chapter
                        -- containing the position, whole or up to the position — no TOC
                        -- navigation. Same chapter resolution as the quiz presets
                        -- (_currentChapterInfo), same show/hide product rules
                        -- (chapterPresets: so-far only mid-chapter; whole hidden under
                        -- protection mid-chapter where it would equal so-far).
                        if toc_available then
                            local ch_info = plugin and plugin._currentChapterInfo
                                and plugin:_currentChapterInfo() or nil
                            local presets = require("koassistant_scope_resolver").chapterPresets({
                                chapter = ch_info,
                                current_page = cur_page,
                                spoiler_free = session_spoiler_free,
                                -- Round 7: the to-position row also shows on the
                                -- chapter's first page (quiz keeps the strict rule)
                                include_first_page = true,
                            })
                            if presets.chapter then
                                table.insert(rows, {{
                                    text = mark("section", "chapter") .. _("Current chapter"),
                                    callback = function()
                                        if not consent then explainConsent() return end
                                        setPick({
                                            kind = "section", preset = "chapter",
                                            start_page = presets.chapter.start_page,
                                            end_page = presets.chapter.end_page,
                                            title = ch_info.title,
                                        })
                                    end,
                                }})
                            end
                            if presets.chapter_so_far then
                                table.insert(rows, {{
                                    text = mark("from_section", "chapter_so_far")
                                        .. _("Current chapter (to current position)"),
                                    callback = function()
                                        if not consent then explainConsent() return end
                                        setPick({
                                            kind = "from_section", preset = "chapter_so_far",
                                            start_page = presets.chapter_so_far.start_page,
                                            title = ch_info.title,
                                        })
                                    end,
                                }})
                            end
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
                if feats.is_book_context then
                    -- Book facet: pick a text range to attach to the sent message.
                    -- Label is a COUNT like the Attach chip (maintainer 2026-08-17):
                    -- the chip is too small for content names — tap shows the detail.
                    local label
                    if not pick then
                        label = enable_emoji and ("\u{1F3AF} " .. _("OFF")) or _("Scope")
                    else
                        label = enable_emoji and "\u{1F3AF} 1" or _("Scope (1)")
                    end
                    return { text = label, callback = pickScope, hold_callback = pickScope }
                elseif highlighted_text then
                    -- Highlight facet: session override of the ambient surrounding-context
                    -- mode (the deferred surrounding_context_plan.md step-3 control).
                    -- Applies to freeform Send AND dialog-launched nil-flag actions;
                    -- explicit per-action modes still win in effectiveSurroundingContextMode.
                    -- Label is a COUNT (maintainer 2026-08-17): the number reflects
                    -- what actually rides — ambient/default context counts, an
                    -- "Also send" book scope counts — OFF only when nothing does.
                    -- Tap shows the detail (the popup names mode and scope).
                    local mode = feats._session_highlight_context
                        or BookSettings.resolveHighlightContext(doc_settings, feats)
                    local count = 0
                    if mode == "sentence" or mode == "paragraph" or mode == "characters" then
                        count = count + 1
                    end
                    if feats._session_scope then
                        count = count + 1
                    end
                    local label
                    if count == 0 then
                        label = enable_emoji and ("\u{1F3AF} " .. _("OFF")) or _("Ctx off")
                    else
                        label = enable_emoji and ("\u{1F3AF} " .. tostring(count))
                            or T(_("Ctx (%1)"), count)
                    end
                    local function pickMode()
                        local ButtonDialog = require("ui/widget/buttondialog")
                        local dialog
                        -- Re-resolved per (re)show: mode picks and dial taps
                        -- RE-SHOW this popup instead of closing it, so the
                        -- number appears the moment its mode is picked
                        -- (device round 6 — the separate Amount row was
                        -- invisible until the popup was reopened).
                        local cur_mode = feats._session_highlight_context
                            or BookSettings.resolveHighlightContext(doc_settings, feats)
                        local function reshow()
                            UIManager:close(dialog)
                            pickMode()
                        end
                        local function setMode(m)
                            feats._session_highlight_context = m
                            -- Chip label shows the mode — refresh once at close
                            feats._session_ctx_label_stale = true
                            reshow()
                        end
                        -- The picked numbered mode carries its count as a
                        -- companion button (maintainer design): tap cycles.
                        local function modeRow(m, row_label)
                            local row = { {
                                text = ((m == cur_mode) and "● " or "○ ") .. row_label,
                                callback = function() setMode(m) end,
                            } }
                            if m == cur_mode and m == "paragraph" then
                                local cur_n = tonumber(feats._session_ctx_paragraphs)
                                    or tonumber(feats.highlight_context_paragraphs) or 1
                                row[#row + 1] = {
                                    text = tostring(cur_n),
                                    callback = function()
                                        feats._session_ctx_paragraphs = cur_n >= 5 and 1 or cur_n + 1
                                        reshow()
                                    end,
                                }
                            elseif m == cur_mode and m == "characters" then
                                local cur_n = tonumber(feats._session_ctx_chars)
                                    or tonumber(feats.highlight_context_chars) or 100
                                row[#row + 1] = {
                                    text = tostring(cur_n),
                                    callback = function()
                                        feats._session_ctx_chars =
                                            ({ [100] = 250, [250] = 500, [500] = 1000, [1000] = 100 })[cur_n] or 100
                                        reshow()
                                    end,
                                }
                            end
                            return row
                        end
                        local rows = {
                            modeRow("none", _("Off")),
                            modeRow("sentence", _("Sentence")),
                            modeRow("paragraph", _("Paragraph")),
                            modeRow("characters", _("Characters")),
                        }
                        local cur_dir = feats._session_ctx_direction
                            or (feats.highlight_context_direction == "before" and "before" or "both")
                        table.insert(rows, {{
                            text = T(_("Direction: %1 (this chat)"),
                                cur_dir == "before" and _("Before only") or _("Both sides")),
                            callback = function()
                                feats._session_ctx_direction =
                                    (cur_dir == "before") and "both" or "before"
                                reshow()
                            end,
                        }})
                        -- Per-request spoiler clamp (round 7, maintainer: "is
                        -- there a principled reason why we cant have the
                        -- spoiler one on the tap?" — there isn't): shown while
                        -- the session is protected, cycles like the hold
                        -- picker's global row but only for this chat.
                        if session_spoiler_free then
                            local cur_lim = feats._session_ctx_spoiler_limit
                                or feats.spoiler_context_limit or "paragraph"
                            table.insert(rows, {{
                                text = T(_("Under spoiler protection: %1 (this chat)"),
                                    BookSettings.spoilerLimitLabel(cur_lim)),
                                callback = function()
                                    feats._session_ctx_spoiler_limit =
                                        ({ selection = "sentence", sentence = "paragraph",
                                           paragraph = "off", off = "selection" })[cur_lim] or "paragraph"
                                    reshow()
                                end,
                            }})
                        end
                        local function closeAndRefresh()
                            if feats._session_ctx_label_stale then
                                feats._session_ctx_label_stale = nil
                                refreshInputDialog()
                            end
                        end
                        -- "Also send" book scope (maintainer 2026-08-17, filing §3
                        -- item 4): highlight chats get the book-facet scope rows one
                        -- link away — the pick attaches a text range BESIDE the
                        -- selection at Send (same _session_scope, consent, spoiler
                        -- and size machinery).
                        do
                            local as_pick = feats._session_scope
                            local as_label
                            if not as_pick then
                                as_label = _("Also send book text...")
                            elseif as_pick.kind == "page" then
                                as_label = T(_("Also send: %1"), _("Current page"))
                            elseif as_pick.kind == "to_position" then
                                as_label = T(_("Also send: %1"), _("Up to current position"))
                            else
                                as_label = T(_("Also send: %1"), as_pick.title or _("section"))
                            end
                            table.insert(rows, {{
                                text = as_label,
                                callback = function()
                                    UIManager:close(dialog)
                                    closeAndRefresh()
                                    pickScope()
                                end,
                            }})
                        end
                        table.insert(rows, {{ text = _("Close"),
                            callback = function()
                                UIManager:close(dialog)
                                closeAndRefresh()
                            end }})
                        dialog = ButtonDialog:new{
                            title = _("Context around the selection (for this chat)"),
                            buttons = rows,
                            tap_close_callback = closeAndRefresh,
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
                -- notes. Menu factored into the file-local showAttachMenu so the
                -- reply dialog reuses the SAME menu (koassistant_chatgptviewer);
                -- staged list is MODULE-RESIDENT in koassistant_attachments.
                -- Inline require, NOT a file-local reference: the enclosing chip
                -- closure sits at LuaJIT's 60-upvalue cap, and a direct reference
                -- to showAttachMenu/attachChipLabel would add two upvalues and
                -- break the whole-plugin load (runtime self-require pattern).
                local D = require("koassistant_dialogs")
                local menu = D.showAttachMenu({
                    configuration = configuration,
                    ui = ui_instance,
                    document_path = document_path,
                    enable_emoji = enable_emoji,
                    chips_book_or_highlight = chips_book_or_highlight,
                    on_change = refreshInputDialog,
                })
                return {
                    text = D.attachChipLabel(enable_emoji),
                    callback = menu.open,
                    hold_callback = function()
                        if require("koassistant_attachments").count() > 0 then
                            menu.manage()
                        else
                            menu.open()
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
                -- Book AND highlight context (2026-08-17): the highlight facet's
                -- "Also send" pick rides the same extraction; the chip never
                -- renders elsewhere and fresh opens scrub the pick.
                if scope_pick and ui_instance and ui_instance.document then
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
                            -- Trust is judged against the provider this Send will actually
                            -- dispatch to — a pending ⚡ model override re-points it at bake
                            -- time (injection_gating_audit; C4 pattern). Runtime self-require:
                            -- a file-local reference here would add an upvalue (60-cap).
                            local send_provider = require("koassistant_dialogs")
                                .effectiveDispatchProvider(
                                    configuration.features, nil, configuration.provider)
                            for _i, tp in ipairs(configuration.features.trusted_providers) do
                                if tp == send_provider then consent = true; break end
                            end
                        end
                        -- Per-book privacy override (Book Settings ▸ Privacy): wins in
                        -- both directions — deny beats trusted. Runtime requires only,
                        -- no new upvalues (60-cap).
                        local sc_ok, sc_ds = pcall(function()
                            return require("koassistant_doc_settings").resolve(nil, ui_instance)
                        end)
                        if sc_ok and sc_ds then
                            local ov = require("koassistant_book_settings")
                                .effectivePrivacyOverrides(sc_ds).book_text
                            if ov ~= nil then consent = ov end
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
                                -- A consented beyond-position pick is neither
                                -- clamped nor rejected (the pick-time ConfirmBox
                                -- was the decision)
                                spoiler_free = session_spoiler_free == true
                                    and not scope_pick.spoiler_consented,
                            })
                        if not range then
                            UIManager:show(InfoMessage:new{
                                text = range_reason == "beyond_position"
                                    and _("The chosen section is beyond your current position (spoiler protection is on). Pick another scope.")
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
                        if scope_pick.spoiler_consented then
                            -- One-shot stand-down for THIS request: the reader
                            -- explicitly included a beyond-position span, so the
                            -- live spoiler nudge steps aside once (consumed in
                            -- BookToolRunner.liveSpoilerLine; strays die in
                            -- _scrubContextFeatures at every entry point)
                            configuration.features._spoiler_scope_consent = true
                        end
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
                                -- P5 after-side limit: global direction pick, or the
                                -- configurable spoiler clamp (session chip first — set
                                -- just-in-time at Send — else book/global). The mapping is
                                -- INLINED (contextAfterLimit's logic): a file-local
                                -- reference here would add an upvalue at the 60 cap.
                                local sc_after
                                if (configuration.features._session_ctx_direction
                                        or configuration.features.highlight_context_direction) == "before" then
                                    sc_after = "none"
                                else
                                    local sess_sp = configuration.features._spoiler_free_active
                                    local sp_on
                                    if sess_sp ~= nil then
                                        sp_on = sess_sp and true or false
                                    else
                                        sp_on = require("koassistant_book_settings")
                                            .resolveSpoilerFree(doc_settings, configuration.features)
                                    end
                                    if sp_on then
                                        local lim = configuration.features._session_ctx_spoiler_limit
                                            or configuration.features.spoiler_context_limit or "paragraph"
                                        if lim == "selection" then sc_after = "none"
                                        elseif lim == "sentence" then sc_after = "sentence"
                                        elseif lim ~= "off" then sc_after = "paragraph" end
                                    end
                                end
                                local sc_text = require("koassistant_scope_resolver").trimContext(
                                    sc_window.prev, sc_window.next,
                                    highlighted_text, sc_mode, {
                                        char_count = configuration.features._session_ctx_chars
                                            or configuration.features.highlight_context_chars or 100,
                                        paragraphs = configuration.features._session_ctx_paragraphs
                                            or configuration.features.highlight_context_paragraphs or 1,
                                        after_limit = sc_after,
                                    })
                                if sc_text ~= "" then
                                    table.insert(parts, require("prompts.templates").SURROUNDING_CONTEXT_LABEL)
                                    table.insert(parts, sc_text)
                                    table.insert(parts, "")
                                end
                            end
                        end
                        -- "Also send" book scope (highlight facet, 2026-08-17): the
                        -- same one-shot block the book arm consumes — the scope
                        -- rides beside the selection and its surrounding context
                        local hsb = configuration.features._session_scope_block
                        configuration.features._session_scope_block = nil
                        if hsb then
                            scope_attached = true
                            table.insert(parts, hsb.label)
                            table.insert(parts, hsb.text)
                            table.insert(parts, "")
                        end
                    end

                    -- Get user's typed question
                    local question = input_dialog:getInputText()
                    local has_user_question = question and question ~= ""

                    -- Store user question for title generation
                    if has_user_question then
                        history.source_input = question
                        -- Input safety net: keep the last typed input (session-scoped on
                        -- the plugin instance, never flushed) so a failed/cancelled send
                        -- or wrong-options mistap is recoverable via the gear.
                        if plugin then plugin._last_input = question end
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
                        -- Consume-and-clear (see the action path): single-send
                        -- context, keeps the list empty for the reply Attach chip.
                        A.clear()
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
                        -- ALWAYS rebind `configuration` to a private per-Send copy (shallow
                        -- 2-level, createTempConfig's shape; inline to stay under this closure's
                        -- 60-upvalue cap). Every later use in this Send — bake, queries, viewer,
                        -- replies, model-info, AND the ⚡ quick-retry's applyQuickReplyOverrides
                        -- (input safety net S3) — then mutates the copy, never the shared module
                        -- config. (Previously this copy happened only when a session override
                        -- already existed, leaving a plain Send on the shared config; the ⚡
                        -- retry would then leak quick posture globally.)
                        local shared_features = configuration.features
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
                        if shared_features._session_quick_answer
                            or shared_features._session_reasoning
                            or shared_features._session_model then
                            local cf = configuration.features
                            cf._quick_answer_active = shared_features._session_quick_answer
                            cf._reasoning_override_active = shared_features._session_reasoning
                            cf._model_override_active = shared_features._session_model
                            -- Keep the _session_* state on the chat's private copy (2026-07-20
                            -- maintainer report: the reply ⚡ chip showed OFF on a quick chat) —
                            -- it is the chat's live control state; only the SHARED table is cleared.
                            shared_features._session_quick_answer = nil
                            shared_features._chat_view_mode = nil
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
                    local freeform_research = require("koassistant_book_settings").resolveResearch(
                        doc_settings, configuration.features,
                        { doi = configuration.features and configuration.features.book_metadata
                            and configuration.features.book_metadata.doi })
                    configuration.features = configuration.features or {}
                    configuration.features._research_mode_active = freeform_research or nil
                    -- Persist x-ray flag for the chat session so reply paths can skip book tools
                    -- (BookToolRunner.shouldUse reads features._xray_chat_active).
                    configuration.features._xray_chat_active = is_xray_chat or nil
                    -- Launch tag (device round 2): lets future surfaces group
                    -- X-Ray-launched chats; persisted with the chat, restored on resume
                    history.launched_from = is_xray_chat and "xray_chat" or nil

                    -- Build unified request config for ALL providers
                    -- No action specified, uses global behavior setting
                    buildUnifiedRequestConfig(configuration, domain_context, nil, plugin)

                    -- The config of the CURRENT attempt: the web/tools-off retry rebases
                    -- this onto its stripped copy, so a further failure computes its
                    -- drop offer from what was actually sent (device round: the dialog
                    -- re-offered "without web search" after a stripped retry failed)
                    -- and a plain "Try again" keeps the stripped state instead of
                    -- silently re-adding the extras. Success paths keep using
                    -- `configuration` — the chat's own settings are untouched.
                    local send_cfg = configuration

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
                            -- Input safety net S2: on a failure OR a user cancel, point at
                            -- the gear recovery so the typed input is obviously recoverable
                            -- rather than gone (maintainer 2026-07-21: show on cancel too).
                            -- Reuses this message = maximally discoverable (no separate toast).
                            local is_cancel = err == _("Request cancelled by user.")
                            local err_text = is_cancel and (err or "")
                                or (_("Error: ") .. (err or "Unknown error"))
                            local recoverable = plugin and plugin._last_input
                                and plugin._last_input ~= ""
                            if recoverable then
                                err_text = err_text .. "\n\n" .. _("Your typed input was saved. Reopen this dialog and tap the gear ⚙, then \"Restore last input\".")
                            end
                            -- Rate-limit retry: nothing was appended to this history on
                            -- failure, so re-issuing is the same call (the query layer
                            -- shows its own loading dialog). drop = the "without …" row:
                            -- re-issue on a config copy with web search and/or book
                            -- tools forced off (Config Copy Pattern; rebased into
                            -- send_cfg so retries stay stripped and a further failure
                            -- offers no second drop; on success the viewer keeps the
                            -- original config, so replies keep the chat's settings).
                            local had_web = send_cfg.enable_web_search == true
                                or (send_cfg.enable_web_search == nil
                                    and send_cfg.features
                                    and send_cfg.features.enable_web_search == true)
                            local had_tools = BookToolRunner.shouldUse(send_cfg, ui_instance)
                            showRequestError(err_text, function(drop)
                                if drop then
                                    local cfg = {}
                                    for k, v in pairs(send_cfg) do cfg[k] = v end
                                    cfg.features = {}
                                    for k, v in pairs(send_cfg.features or {}) do
                                        cfg.features[k] = v
                                    end
                                    if had_web then
                                        cfg.enable_web_search = false
                                        cfg.features.enable_web_search = false
                                    end
                                    if had_tools then
                                        cfg.features._tools_active = false
                                    end
                                    send_cfg = cfg
                                end
                                BookToolRunner.queryWith(queryChatGPT, history:getMessages(),
                                    send_cfg, onResponseReady, plugin, ui_instance)
                            end, recoverable and 6 or 3,
                                (had_web or had_tools)
                                and { web = had_web, tools = had_tools } or nil)
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
                -- Model-aware pre-check mirrors the action path (inline require:
                -- showChatGPTDialog closures sit near the 60-upvalue cap).
                local scope_cw_note
                if scope_block then
                    -- One model id per request (audit B3): the shared resolver, so a
                    -- nil configuration.model still checks the model that is sent.
                    local cw_model = require("model_constraints").dispatchModel(configuration)
                    local exceeded, window = require("model_constraints").checkContextWindow(
                        configuration.provider, cw_model, #scope_block.text)
                    if exceeded then
                        scope_cw_note = T(_("This likely exceeds the current model's context window (%1: ~%2K tokens). Pick a smaller scope or switch models."),
                            cw_model, math.floor(window / 1000))
                    end
                end
                if scope_block
                        and (#scope_block.text > require("koassistant_constants").LARGE_EXTRACTION_THRESHOLD
                            or scope_cw_note)
                        and not (configuration.features and configuration.features.suppress_large_extraction_warning) then
                    local ButtonDialog = require("ui/widget/buttondialog")
                    local chars_k = math.floor(#scope_block.text / 1000)
                    local tokens_low = math.floor(#scope_block.text / 4000)
                    local tokens_high = math.floor(#scope_block.text / 2000)
                    local warning_dialog
                    warning_dialog = ButtonDialog:new{
                        title = T(_("Large text extraction: ~%1K characters (~%2K-%3K tokens). Make sure your model's context window can accommodate this.\n\nYou can pick a smaller scope on the Scope chip, or use KOReader's Hidden Flows to exclude irrelevant content."), chars_k, tokens_low, tokens_high)
                            .. (scope_cw_note and ("\n\n" .. scope_cw_note) or ""),
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
            -- document_path = the DIALOG's book (open doc or fb book_metadata),
            -- so the requires_xray_cache gate keys on the right book
            local ordered_actions = action_service:getInputActionObjects(input_context, document_path)
            prompts = {}
            prompt_keys = {}
            for _idx, action in ipairs(ordered_actions) do
                local key = action.id or ("prompt_" .. #prompt_keys + 1)
                prompts[key] = action
                table.insert(prompt_keys, key)
            end
            logger.dbg("buildInputDialogButtons: Got " .. #prompt_keys .. " prompts from input context: " .. input_context)
        else
            prompts, prompt_keys = getAllPrompts(configuration, plugin)
            logger.dbg("buildInputDialogButtons: Got " .. #prompt_keys .. " prompts from getAllPrompts")
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
                logger.dbg("Skipping excluded prompt: " .. custom_prompt_type)
            else
                logger.dbg("Adding button for prompt: " .. custom_prompt_type .. " with text: " .. prompt.text)
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
                        -- Same X-Ray-cache gate as the favorites list above
                        if not excluded and action.requires_xray_cache and document_path then
                            local ActionCache = require("koassistant_action_cache")
                            if not ActionCache.hasAnyXray(document_path) then
                                excluded = true
                            end
                        end
                        -- Same provider gate as the action_service getters
                        if not excluded and action.requires_image_provider then
                            local ImageGenerator = require("koassistant_image_generator")
                            local feats = (configuration and configuration.features) or {}
                            excluded = ImageGenerator.effectiveProvider(feats,
                                feats.provider or "anthropic",
                                plugin and plugin.settings) == nil
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
    -- Toggleable via Menus & Buttons ▸ Input dialogs (A9 round 2 2026-08-17)
    local artifact_button = nil
    if not is_general_context and plugin and not hide_artifacts
        and settings_features.show_artifacts_in_input ~= false then
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
                            text = require("koassistant_book_page").entryLabel(),
                            callback = function()
                                UIManager:close(plugin._cache_selector)
                                UIManager:close(input_dialog)
                                plugin.current_input_dialog = nil
                                require("koassistant_book_page").show({
                                    file = artifact_file,
                                    plugin = plugin,
                                    ui = ui_instance,
                                    title = book_metadata and book_metadata.title,
                                    author = book_metadata and book_metadata.author,
                                    enable_emoji = enable_emoji,
                                })
                            end,
                        }})
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

    -- Group button (round 28): same lazy, dynamic rule as View Artifacts —
    -- built only when this book actually belongs to a group, so it never shows
    -- for readers who don't use groups. Opens the members popup (jump to any
    -- volume's artifacts), the same idiom the artifact viewers' "→ Group" uses.
    local group_button = nil
    if not is_general_context and plugin and document_path
        and settings_features.show_group_in_input ~= false
        and plugin._inBookGroup and plugin:_inBookGroup(document_path) then
        group_button = {
            text = Constants.getEmojiText("\u{1F5C2}\u{FE0F}", _("Group"), enable_emoji),
            callback = function()
                UIManager:close(input_dialog)
                if plugin then plugin.current_input_dialog = nil end
                plugin:_showGroupMembersPopup(document_path, "artifacts")
            end,
        }
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
                    library_label = _("Library Scan ▾")
                elseif active_count == total_count then
                    library_label = T(_("Library Scan (%1) ▾"), total_count)
                else
                    library_label = T(_("Library Scan (%1/%2) ▾"), active_count, total_count)
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
                items_label = _("Items ▾")
            else
                items_label = T(_("Items (%1) ▾"), book_count)
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

            -- Artifact/Group pairing: fill the last odd row, else start one.
            -- Artifacts first (the more common destination), Group beside it —
            -- the two together make one navigation row.
            local nav_buttons = {}
            if artifact_button then nav_buttons[#nav_buttons + 1] = artifact_button end
            if group_button then nav_buttons[#nav_buttons + 1] = group_button end
            for _idx, nav_button in ipairs(nav_buttons) do
                local last_row = button_rows[#button_rows]
                if last_row and #last_row == 1 and not control_row_set[last_row] then
                    table.insert(last_row, nav_button)
                else
                    table.insert(button_rows, { nav_button })
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
        -- Suppress the leave-stash (input safety net): this is an internal
        -- close-and-reopen, not a user exit — the text is carried straight back
        -- via initial_input, so it must NOT churn plugin._last_input.
        input_dialog._koa_internal_close = true
        UIManager:close(input_dialog)
        if plugin then plugin.current_input_dialog = nil end
        -- Re-set transient flags for the reopen
        if configuration and configuration.features then
            if is_xray_chat then configuration.features._xray_chat_context = true end
            if hide_artifacts then configuration.features._hide_artifacts = true end
            if exclude_action_flags then configuration.features._exclude_action_flags = exclude_action_flags end
            if xray_context_prefix then configuration.features._xray_context_prefix = xray_context_prefix end
            if show_all_actions then configuration.features._show_all_actions = true end
            -- Preserve false too: an explicit "Spoilers OK" tap must survive the
            -- refresh even when the book/global setting would re-seed it to on
            -- (was true-only — the chip could never be toggled OFF under a
            -- spoiler-on book/global setting; every tap refreshed back to on).
            if session_spoiler_free ~= nil then configuration.features._session_spoiler_free = session_spoiler_free end
            -- Same explicit-false preservation for tools.
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
            spoiler = _("Spoiler protection"),
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
                    -- Record the OFF chips so auto-injection cannot resurrect a chip the
                    -- user deliberately turned off (defaults_propagation_plan.md G1).
                    local new_dismissed = {}
                    for _j, cid in ipairs(SESSION_CHIP_IDS) do
                        if not enabled[cid] then table.insert(new_dismissed, cid) end
                    end
                    if configuration and configuration.features then
                        configuration.features.session_chips = new_list
                        configuration.features._dismissed_session_chips = new_dismissed
                    end
                    if plugin and plugin.settings then
                        local f = plugin.settings:readSetting("features") or {}
                        f.session_chips = new_list
                        f._dismissed_session_chips = new_dismissed
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
        -- Context-specific titles (A9 sitting 2026-08-17). input_context is the
        -- safe discriminator: X-Ray chat is its OWN context value (titled since
        -- the same-day follow-up) and artifact chat never reaches this dialog,
        -- so general/library-side entries keep the generic title deliberately.
        if input_context == "highlight" then
            dialog_title = _("KOAssistant: Highlight")
        elseif input_context == "book" then
            dialog_title = _("KOAssistant: Book")
        elseif input_context == "book_filebrowser" then
            dialog_title = _("KOAssistant: Book (not open)")
        elseif input_context == "xray_chat" then
            dialog_title = _("KOAssistant: X-Ray Chat")
        else
            dialog_title = _("KOAssistant Actions")
        end
        -- Rolling hints — a fresh pick per dialog open (the hint is the input
        -- field's placeholder; it cannot change while the dialog is up). The
        -- empty-input-Send hint is gated on the HIGHLIGHT input context, not on
        -- highlighted_text (book launches can carry a text payload too —
        -- maintainer 2026-07-19); book/general empty Send stays blocked by the
        -- Send guard, so the hint would be wrong there.
        local hints = {
            _("Type your question or additional instructions for any action..."),
            _("Tip: long-press toolbar buttons for their settings, action buttons for descriptions..."),
            _("Tip: your typed input is kept if you close this. Reopen and use the gear to restore it..."),
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
            -- Input safety net: recover the last typed input after a failed/cancelled send
            -- or a wrong-options mistap (stashed on plugin._last_input at Send). Only shown
            -- when something is stashed. Appends when the field already has text (never
            -- clobbers), sets it when empty (the common post-failure case).
            if plugin and plugin._last_input and plugin._last_input ~= "" then
                table.insert(gear_buttons, {{ text = _("Restore last input"), callback = function()
                    UIManager:close(gear_menu)
                    local cur = input_dialog:getInputText()
                    if cur and cur ~= "" then
                        input_dialog:addTextToInput(plugin._last_input)
                    else
                        input_dialog:setInputText(plugin._last_input)
                    end
                end }})
            end
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

    -- Input safety net (leave-stash): exiting the input window with text typed saves it
    -- for recovery via gear → Restore last input — so the user can leave to copy more
    -- text or re-read something, then come back. Both user-exit paths (title-bar X ~8080,
    -- tap-outside ~8100) route through UIManager:close → onCloseWidget, so wrapping it
    -- catches them all. Internal close-and-reopen (refreshInputDialog, rotation) sets
    -- _koa_internal_close so it is skipped; Send/action closes already stash via their own
    -- paths (redundant-harmless here). Read the text before teardown; pcall for safety.
    local koaOrigOnCloseWidget = input_dialog.onCloseWidget
    input_dialog.onCloseWidget = function(self_dlg)
        if plugin and not self_dlg._koa_internal_close then
            local ok, txt = pcall(function() return self_dlg:getInputText() end)
            if ok and txt and txt ~= "" then plugin._last_input = txt end
        end
        return koaOrigOnCloseWidget(self_dlg)
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
local function openXrayBrowserFromCache(ui, data, cached, config, plugin, book_metadata, best, cleanup_widgets, document_path)
    local XrayBrowser = require("koassistant_xray_browser")
    local ActionCache = require("koassistant_action_cache")
    local Notification = require("ui/widget/notification")
    local config_features = (config or {}).features or {}
    -- The lookup's target book — may differ from the open document (chat-
    -- launched lookups); the browser identity AND the delete callback must
    -- key on it, never on whatever the reader happens to have open
    local target_file = document_path or (ui and ui.document and ui.document.file)

    local book_title = (book_metadata and book_metadata.title) or ""
    local source_label = cached.used_book_text == false
        and _("Based on AI training data knowledge")
        or _("Based on extracted document text")
    local formatted_date = cached.timestamp
        and os.date("%Y-%m-%d %H:%M", cached.timestamp)

    local browser_metadata = {
        title = book_title,
        progress = cached.progress_decimal and
            (math.floor(cached.progress_decimal * 100 + 0.5) .. "%"),
        model = cached.model,
        timestamp = cached.timestamp,
        book_file = target_file,
        enable_emoji = config_features.enable_emoji_icons == true,
        configuration = config,
        plugin = plugin,
        source_label = source_label,
        formatted_date = formatted_date,
        progress_decimal = cached.progress_decimal,
        full_document = cached.full_document,
        previous_progress = cached.previous_progress_decimal and
            (math.floor(cached.previous_progress_decimal * 100 + 0.5) .. "%"),
        merged_from_books = cached.merged_from_books,
        merged_from = cached.merged_from,
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
        -- Reconvert XPointers to current pages if book is open (identity-
        -- guarded: another open book's pages would be garbage for this one)
        local doc = ui and ui.document
        if doc and target_file and doc.file ~= target_file then doc = nil end
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

    XrayBrowser:show(data, browser_metadata, ui, function(keep_versions)
        -- Round 28: ONE lineage-delete helper (ActionCache.deleteXray) — doc-level
        -- key, the per-action "xray" entry (a doc-key-only clear leaves an entry
        -- background auto-update resurrects from), wiki entries and the ladder;
        -- the archived versions only when the reader chose so in the confirm.
        -- target_file, NOT ui.document.file: a cross-book lookup deleting the
        -- OPEN book's X-Ray would be silent data loss (2026-08-13)
        ActionCache.deleteXray(target_file, { keep_versions = keep_versions })
        require("koassistant_book_settings").clearXrayLineageState(
            SafeDocSettings.resolve(target_file, ui), config and config.features)
        UIManager:show(Notification:new{
            text = keep_versions and _("X-Ray deleted — archived versions kept")
                or T(_("%1 deleted"), "X-Ray"),
            timeout = 2,
        })
    end)
    return XrayBrowser
end

-- S1 (ref #90): the carried tier for lookups — the MAIN artifact's dormant
-- ledger. Parsed lazily: the searched artifact may be a section, which never
-- holds a ledger; when the caller already parsed the main artifact, reuse it.
local function mainLedgerData(document_path, maybe_main_data, best)
    if best and not best.is_section and maybe_main_data then return maybe_main_data end
    local ActionCache = require("koassistant_action_cache")
    local XrayParser = require("koassistant_xray_parser")
    local main = ActionCache.getXrayCache(document_path)
    if not (main and main.result and XrayParser.isJSON(main.result)) then return nil end
    local data = XrayParser.parse(main.result)
    if not data or data.error then return nil end
    XrayParser.mergeUserAliases(data, ActionCache.getUserAliases(document_path))
    return data
end

-- Land on one carried stub's page: browser root (main artifact) under the
-- carried list under the stub — its natural group, mirroring the exact
-- landing's stacked-on-home-category rule.
local function openCarriedStubDetail(ui, main_data, config, plugin, book_metadata,
        cleanup_widgets, document_path, stub_idx, stub)
    local ActionCache = require("koassistant_action_cache")
    local main = ActionCache.getXrayCache(document_path)
    if not (main and main.result) then return end
    local XrayBrowser = openXrayBrowserFromCache(ui, main_data, main, config, plugin,
        book_metadata, { entry = main }, cleanup_widgets, document_path)
    XrayBrowser:showDormantList()
    local rows = XrayBrowser:_dormantRows()
    local display_i
    for ri, r in ipairs(rows) do
        if r.idx == stub_idx then
            display_i = ri
            break
        end
    end
    XrayBrowser:showDormantDetail(stub_idx, stub,
        display_i and { rows = rows, index = display_i } or nil)
end

-- The carried tier's miss handling, shared by the lookup's no-result seams:
-- an exact stub goes straight to its page (a chooser when several share the
-- handle across families); substring-only stubs land on the main results
-- list, where the carried group renders. Returns true when it presented
-- something (the caller's own no-results UI stands down).
local function carriedLookupHandled(ui, mdata, query, config, plugin,
        book_metadata, cleanup_widgets, document_path)
    local XrayParser = require("koassistant_xray_parser")
    local cw = cleanup_widgets and #cleanup_widgets > 0 and cleanup_widgets or nil
    local ex = XrayParser.searchLedger(mdata, query, { exact = true })
    if #ex == 1 then
        openCarriedStubDetail(ui, mdata, config, plugin, book_metadata, cw,
            document_path, ex[1].stub_idx, ex[1].stub)
        return true
    end
    if #ex > 1 then
        local chooser
        local rows = {}
        for _idx, s in ipairs(ex) do
            local captured = s
            rows[#rows + 1] = { {
                text = captured.stub.name .. "  ·  " .. T(_("Carried from %1"),
                    captured.source_title or _("earlier books")),
                align = "left",
                callback = function()
                    UIManager:close(chooser)
                    openCarriedStubDetail(ui, mdata, config, plugin, book_metadata, cw,
                        document_path, captured.stub_idx, captured.stub)
                end,
            } }
        end
        rows[#rows + 1] = { { text = _("Close"), callback = function() UIManager:close(chooser) end } }
        chooser = ButtonDialog:new{
            title = T(_("\"%1\" matches %2 carried entries"), query, #ex),
            buttons = rows,
        }
        UIManager:show(chooser)
        return true
    end
    if #XrayParser.searchLedger(mdata, query, { skip_description = true }) > 0 then
        local ActionCache = require("koassistant_action_cache")
        local main = ActionCache.getXrayCache(document_path)
        if main and main.result then
            local XrayBrowser = openXrayBrowserFromCache(ui, mdata, main, config, plugin,
                book_metadata, { entry = main }, cw, document_path)
            XrayBrowser:showSearchResults(query, true)
            return true
        end
    end
    return false
end

-- Read-only view of an entry found in an EARLIER book's X-Ray (S2, ref
-- #90): the card's full-detail body (provenance line + item detail +
-- background lines) plus the two actions — open that book's X-Ray at the
-- entry, or carry the entry into THIS book's carried list (the manual
-- single-entity seed: consent-gated like the create-time seed, no model
-- request, wake-pass merges it when an update later brings the entity).
-- Reached from the card tap-through, the lookup's exact hits, the
-- predecessor results list and the earlier-books sweep.
-- @param opts table { ui, config, plugin, book_metadata, cleanup_widgets,
--   document_path (CURRENT book), hit { name, item, category_key,
--   category_label, source_title, pred_file, pred_title, pred_stub } }
local function showPredecessorEntity(opts)
    local ActionCache = require("koassistant_action_cache")
    local XrayCard = require("koassistant_xray_card")
    local XrayParser = require("koassistant_xray_parser")
    local hit = opts.hit
    hit.source = "predecessor" -- the shared provenance line renders off this
    local pred_entry = hit.pred_file and ActionCache.getXrayCache(hit.pred_file) or nil
    local viewer
    local action_row = {}
    if pred_entry and pred_entry.result and opts.plugin then
        action_row[#action_row + 1] = {
            text = T(_("Open in %1's X-Ray"), hit.pred_title or _("that book")),
            callback = function()
                UIManager:close(viewer)
                if not hit.pred_stub then
                    local aliases = {}
                    if type(hit.item) == "table" and type(hit.item.aliases) == "table" then
                        for _idx, a in ipairs(hit.item.aliases) do aliases[#aliases + 1] = a end
                    end
                    -- The members-popup jump recipe: land on the entity, one
                    -- fallback level at a time (a stub target skips this and
                    -- opens at the root — stubs live in the carried list)
                    require("koassistant_xray_browser")._pending_navigate_to = {
                        category_key = hit.category_key,
                        item_name = hit.name,
                        item_aliases = aliases,
                        book_file = hit.pred_file,
                        fallback = true,
                    }
                end
                opts.plugin:showCacheViewer({ name = _("X-Ray"), key = "_xray_cache",
                    data = pred_entry, book_title = hit.pred_title, file = hit.pred_file })
            end,
        }
    end
    local live = ActionCache.getXrayCache(opts.document_path)
    local live_data = live and live.result and XrayParser.isJSON(live.result)
        and XrayParser.parse(live.result) or nil
    if live_data and live_data.error then live_data = nil end
    -- Q14 (device round 4): already here, in either form, is said instead
    -- of offered — the whole-chain list shows an earlier book's entry even
    -- after it was carried
    local state
    if live_data then
        local names = { hit.name }
        if type(hit.item) == "table" and type(hit.item.aliases) == "table" then
            for _idx, a in ipairs(hit.item.aliases) do
                if type(a) == "string" and a ~= "" then names[#names + 1] = a end
            end
        end
        if XrayParser.findByIdentity(live_data, names, hit.category_key) then
            state = "live"
        elseif XrayParser.findDormantByIdentity(live_data, names) then
            state = "carried"
        end
    end
    if state == "live" then
        action_row[#action_row + 1] = { text = _("Already in this book's X-Ray"), enabled = false }
    elseif state == "carried" then
        action_row[#action_row + 1] = { text = _("Already on this book's carried list"), enabled = false }
    elseif live_data then
        action_row[#action_row + 1] = {
            text = _("Add to this book's carried list"),
            callback = function()
                local XrayMerge = require("koassistant_xray_merge")
                local features = (opts.config and opts.config.features) or {}
                local provider = opts.config and opts.config.provider
                if pred_entry and not XrayMerge.consentOk({ pred_entry }, features,
                        provider, hit.pred_file, opts.ui) then
                    UIManager:show(InfoMessage:new{
                        text = T(_("Adding this entry needs text extraction allowed for %1 (Book Settings, Privacy) or a trusted provider."),
                            hit.pred_title or _("that book")),
                        timeout = 6,
                    })
                    return
                end
                local WriteBack = require("koassistant_artifact_writeback")
                local ok, err, new_data = WriteBack.editLiveXray(opts.document_path,
                    function(data)
                        return XrayMerge.carryOne(data, hit.item, hit.category_key, {
                            source = hit.source_title or hit.pred_title,
                            file = hit.pred_stub and (hit.item.file or hit.pred_file)
                                or hit.pred_file,
                        })
                    end, { features = features })
                if not ok then
                    UIManager:show(InfoMessage:new{
                        text = err == "no_xray" and _("This book has no X-Ray to add it to.")
                            or _("Could not save the X-Ray."),
                        timeout = 4,
                    })
                    return
                end
                UIManager:close(viewer)
                -- A hand-added entry cancels an earlier removal (S4 tombstones)
                ActionCache.clearRemovedStub(opts.document_path, hit.name)
                local Notification = require("ui/widget/notification")
                UIManager:show(Notification:new{
                    text = T(_("Added to the carried list: %1"), hit.name),
                })
                -- Land on the fresh carried entry when the caller threaded
                -- book_metadata (the lookup paths); the card path just toasts
                if opts.book_metadata and new_data then
                    local s2, i2 = XrayParser.findDormantByIdentity(new_data, { hit.name })
                    if s2 then
                        openCarriedStubDetail(opts.ui, new_data, opts.config, opts.plugin,
                            opts.book_metadata,
                            opts.cleanup_widgets and #opts.cleanup_widgets > 0
                                and opts.cleanup_widgets or nil,
                            opts.document_path, i2, s2)
                    end
                end
            end,
        }
    end
    local rows = {}
    if #action_row > 0 then rows[#rows + 1] = action_row end
    rows[#rows + 1] = { { text = _("Close"), callback = function() UIManager:close(viewer) end } }
    viewer = XrayCard.showFullDetail(hit, { buttons_table = rows })
end

-- Grouped results Menu for earlier-book hits (S2/S3): a "From <title>"
-- header per book, rows open the read-only predecessor entry view. groups =
-- { { file, title, entry, rows = { hit, ... } } }, nearest book first.
local showEarlierBooksSweep
-- S5 (ref #90): the reveal for later books in the series — the in-book
-- "next checkpoint behind a confirm" pattern applied across books. Offered
-- on every lookup list whenever this book's spoiler protection is holding
-- later X-Rayed books back, regardless of hits (so the offer itself says
-- nothing about the query); the confirmed sweep walks every group book,
-- later ones labeled. Marks, cards and the selection intercept never show
-- later books under protection — "later books" has no bound.
-- S7 (2026-09-04, maintainer): ONE book per confirm, following the chain.
-- `nextLaterBook(opts)` = the nearest X-Rayed later book the chain does not
-- reach and `opts.reveal` confirms have not yet revealed (nil = nothing held
-- back); the row names it, the confirm names it, and the reveal page carries
-- the row for the book after it. A reveal never sticks: every search starts
-- from the chain again. Each reveal is its OWN page holding only that book's
-- hits, stacked on the page it was confirmed from (maintainer 2026-09-04:
-- one book per confirm = one book per page; back = the previous book).
local function nextLaterBook(opts)
    if not opts.document_path then return nil end
    return require("koassistant_action_cache").nextHeldBackLaterXray(opts.document_path, opts.reveal or 0)
end
local function bookLabel(book)
    return book.title or (book.file and book.file:match("([^/]+)$")) or "?"
end
local function laterBookRowText(book)
    return T(_("Search %1 too (may contain spoilers)…"), bookLabel(book))
end
local function confirmLaterBooksSweep(opts)
    local book = nextLaterBook(opts)
    if not book then return end
    local ConfirmBox = require("ui/widget/confirmbox")
    UIManager:show(ConfirmBox:new{
        text = T(_("%1 comes later in the series and can reveal what happens in the books before it. Search it anyway?"), bookLabel(book)),
        ok_text = _("Search this book"),
        ok_callback = function()
            local o = {}
            for k, v in pairs(opts) do o[k] = v end
            o.reveal = (opts.reveal or 0) + 1
            showEarlierBooksSweep(o)
        end,
    })
end
local function predGroupsMenu(opts, groups, title)
    local Menu = require("ui/widget/menu")
    local items = {}
    for _g, g in ipairs(groups) do
        table.insert(items, {
            text = g.direction == "later" and T(_("From %1 (later in the series)"), g.title)
                or T(_("From %1"), g.title),
            bold = true,
            separator = true,
            callback = function() end,
        })
        for _r, ghit in ipairs(g.rows) do
            local captured = ghit
            local match_label = captured.category_label or ""
            if captured.match_field == "alias" then
                match_label = match_label .. " (" .. _("alias") .. ")"
            end
            table.insert(items, {
                text = "  " .. captured.name,
                mandatory = match_label,
                mandatory_dim = true,
                callback = function()
                    showPredecessorEntity{
                        ui = opts.ui, config = opts.config, plugin = opts.plugin,
                        book_metadata = opts.book_metadata,
                        cleanup_widgets = opts.cleanup_widgets,
                        document_path = opts.document_path,
                        hit = captured,
                    }
                end,
            })
        end
    end
    local next_book = nextLaterBook(opts)
    if next_book then
        table.insert(items, {
            text = laterBookRowText(next_book),
            bold = true,
            separator = true,
            -- The next book's page stacks on this one (S7)
            callback = function() confirmLaterBooksSweep(opts) end,
        })
    end
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
    }
    if opts.cleanup_widgets then
        table.insert(opts.cleanup_widgets, results_menu)
    end
    UIManager:show(results_menu)
end

-- Earlier-book result groups (S3, ref #90): every earlier X-Rayed book,
-- nearest first, one group per book with hits. `exact` = exact handle
-- matching (the direct-landing pass); otherwise substring over names and
-- aliases, description skipped (noise for a lookup). Rows carry the
-- provenance the entity view and the chooser render.
local function collectPredGroups(preds, query, exact)
    local XrayParser = require("koassistant_xray_parser")
    local sopts = exact and { exact = true } or { skip_description = true }
    local groups = {}
    for _idx, pred in ipairs(preds) do
        local rows = {}
        for _i, r in ipairs(XrayParser.searchAll(pred.data, query, sopts)) do
            rows[#rows + 1] = {
                name = XrayParser.getItemName(r.item, r.category_key),
                item = r.item, category_key = r.category_key,
                category_label = r.category_label, match_field = r.match_field,
                source_title = pred.title, pred_file = pred.file, pred_title = pred.title,
                direction = pred.direction,
            }
        end
        for _i, s in ipairs(XrayParser.searchLedger(pred.data, query, sopts)) do
            rows[#rows + 1] = {
                name = s.stub.name, item = s.stub,
                category_key = s.category_key,
                category_label = XrayParser.categoryLabel(pred.data, s.category_key),
                match_field = s.match_field,
                source_title = s.source_title or pred.title,
                pred_file = pred.file, pred_title = pred.title, pred_stub = true,
                direction = pred.direction,
            }
        end
        if #rows > 0 then
            groups[#groups + 1] = { file = pred.file, title = pred.title,
                entry = pred.entry, rows = rows, direction = pred.direction }
        end
    end
    return groups
end

-- "Search all earlier books…": the explicit whole-chain LIST, kept on the
-- lists where this book had hits of its own (the browser's search results).
-- The lookup's no-result seams no longer need it — predLookupHandled walks
-- the chain itself (S3).
-- True when the group walk reaches beyond earlier books (a later volume
-- while unprotected, or every member of a project) — the wording follows.
local function walkIsWide(list)
    for _idx, g in ipairs(list) do
        if g.direction ~= "earlier" then return true end
    end
    return false
end

showEarlierBooksSweep = function(opts)
    local ActionCache = require("koassistant_action_cache")
    -- opts.reveal = the confirmed later-books reveal (S5; one book per
    -- confirm since S7): ONLY the book THIS confirm revealed — the newest
    -- revealed entry (revealed entries come in series order). Every surface
    -- carrying the confirm row already shows the earlier books' hits and the
    -- later books the chain reaches (the auto-walked lookup lists, the
    -- browser's folded groups since 2026-09-04), and the books earlier
    -- confirms revealed stay on their own pages underneath, so nothing is
    -- listed twice
    local reveal = tonumber(opts.reveal) or 0
    local preds = ActionCache.groupXrays(opts.document_path, { reveal = reveal })
    if reveal > 0 then
        local newest
        for _idx, p in ipairs(preds) do
            if p.revealed then newest = p end
        end
        preds = newest and { newest } or {}
    end
    local wide = walkIsWide(preds)
    local groups = collectPredGroups(preds, opts.query, false)
    if #groups == 0 then
        local text
        if reveal > 0 then
            text = #preds == 1
                and T(_("No results for \"%1\" in %2."), opts.query, bookLabel(preds[1]))
                or T(_("No results for \"%1\" in the later books of the series."), opts.query)
            -- The chain goes on from a no-hit page too (S7): the next book's
            -- row rides a dialog instead of a plain message
            local next_book = nextLaterBook(opts)
            if next_book then
                local dlg
                dlg = ButtonDialog:new{
                    title = text,
                    buttons = {
                        { { text = laterBookRowText(next_book), callback = function()
                            UIManager:close(dlg)
                            confirmLaterBooksSweep(opts)
                        end } },
                        { { text = _("Close"), callback = function() UIManager:close(dlg) end } },
                    },
                }
                UIManager:show(dlg)
                return
            end
        elseif wide then
            text = #preds == 1
                and T(_("No results for \"%1\" in the other book of the group."), opts.query)
                or T(_("No results for \"%1\" in the %2 other books of the group."), opts.query, #preds)
        else
            text = #preds == 1
                and T(_("No results for \"%1\" in the earlier book."), opts.query)
                or T(_("No results for \"%1\" in %2 earlier books."), opts.query, #preds)
        end
        UIManager:show(InfoMessage:new{ text = text, timeout = 4 })
        return
    end
    local title
    if reveal > 0 then
        title = T(_("Results for \"%1\" in %2"), opts.query, bookLabel(preds[1]))
    elseif wide then
        title = T(_("Results for \"%1\" in the other books of the group"), opts.query)
    else
        title = T(_("Results for \"%1\" in earlier books"), opts.query)
    end
    predGroupsMenu(opts, groups, title)
end

-- Predecessor tier of the lookup (S2 + S3, ref #90): after a full local
-- miss, walk EVERY earlier X-Rayed book in the ordered group, nearest first.
-- Exact pass first: the first book holding the handle wins (one hit = the
-- read-only entity view, several = a chooser of that book's hits). Then the
-- substring pass, auto-shown as one grouped list (nearest book first) — the
-- maintainer's call over a tap row, since the nearest book already
-- auto-showed and every book parses once per stamp. Returns true when it
-- showed something.
local function predLookupHandled(ui, query, config, plugin, book_metadata,
        cleanup_widgets, document_path)
    local ActionCache = require("koassistant_action_cache")
    local preds = ActionCache.groupXrays(document_path)
    if #preds == 0 then return false end
    local show_opts = { ui = ui, config = config, plugin = plugin,
        book_metadata = book_metadata, cleanup_widgets = cleanup_widgets,
        document_path = document_path, query = query }
    local exact_groups = collectPredGroups(preds, query, true)
    if #exact_groups > 0 then
        local hits, in_title = exact_groups[1].rows, exact_groups[1].title
        if #hits == 1 then
            show_opts.hit = hits[1]
            showPredecessorEntity(show_opts)
            return true
        end
        local chooser
        local rows = {}
        for _idx, h in ipairs(hits) do
            local captured = h
            local from = captured.direction == "later"
                and T(_("From %1 (later in the series)"), captured.source_title or in_title)
                or T(_("From %1"), captured.source_title or in_title)
            rows[#rows + 1] = { {
                text = captured.name .. "  \u{00B7}  " .. from,
                align = "left",
                callback = function()
                    UIManager:close(chooser)
                    show_opts.hit = captured
                    showPredecessorEntity(show_opts)
                end,
            } }
        end
        rows[#rows + 1] = { { text = _("Close"),
            callback = function() UIManager:close(chooser) end } }
        chooser = ButtonDialog:new{
            title = T(_("\"%1\" matches %2 entries in %3"), query, #hits, in_title),
            buttons = rows,
        }
        UIManager:show(chooser)
        return true
    end
    local groups = collectPredGroups(preds, query, false)
    if #groups == 0 then return false end
    local n = 0
    for _idx, g in ipairs(groups) do n = n + #g.rows end
    predGroupsMenu(show_opts, groups, T(_("Results for \"%1\" (%2)"), query, n))
    return true
end

-- Show cross-section X-Ray search results as a standalone picker Menu.
-- @param grouped_results table From ActionCache.searchAllXrays()
-- @param query string The search query
-- @param ui table UI context
-- @param config table Configuration
-- @param plugin table Plugin reference
-- @param book_metadata table Book metadata
local function showCrossSectionResults(grouped_results, query, ui, config, plugin, book_metadata, cleanup_widgets, document_path, carried)
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
                        cleanup_widgets, document_path)
                    XrayBrowser:showItemDetail(
                        captured_result.item, captured_result.category_key, captured_name)
                end,
            })
        end
    end

    -- Carried group (S1, ref #90): the main ledger's matches, one section
    -- like the artifact groups; a row opens the stub's carried-detail page
    if carried and carried.hits and #carried.hits > 0 then
        table.insert(items, {
            text = _("Carried from earlier books"),
            bold = true,
            dim = false,
            separator = true,
            callback = function() end,
        })
        for _idx2, sh in ipairs(carried.hits) do
            local captured_sh = sh
            table.insert(items, {
                text = "  " .. captured_sh.stub.name,
                mandatory = captured_sh.source_title or "",
                mandatory_dim = true,
                callback = function()
                    openCarriedStubDetail(ui, carried.data, config, plugin, book_metadata,
                        cleanup_widgets, document_path, captured_sh.stub_idx, captured_sh.stub)
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

--- Shared "Add as alias of…" target picker (ref #63): word-overlap
--- suggestions first, category → paged entity pick as the fallback; commit
--- through ActionCache.addUserAlias into the user-aliases sidecar (survives
--- installs; marking/lookup/intercept re-key off its stamp) and fold the
--- fresh alias into ctx.data IN PLACE so the caller's open views show it.
--- Callers own the landing via ctx.on_committed — the no-hits dialog builds
--- a browser, the browser's search-results row navigates within itself
--- (which requires this module-level home + export: the browser reaches it
--- by inline require, avoiding a top-level circular require).
--- @param ctx table { data, query, document_path, on_committed(item, cat_key, name) }
local function showAliasTargetPicker(ctx)
    local XrayParser = require("koassistant_xray_parser")
    local ActionCache = require("koassistant_action_cache")
    local data, query, document_path = ctx.data, ctx.query, ctx.document_path

    local alias_cats = {}
    for _c_idx, cat in ipairs(XrayParser.getCategories(data) or {}) do
        if not XrayParser.TEXT_MATCH_EXCLUDED[cat.key] and #cat.items > 0 then
            table.insert(alias_cats, cat)
        end
    end
    -- Carried stubs (S1, ref #90) are alias targets too — the write goes
    -- onto the STUB in the live artifact's ledger (D6/Q3), never the
    -- user-aliases sidecar (that store attaches by a live entry's primary
    -- name and would dangle for a stub). Stubs always come from the MAIN
    -- artifact, whatever artifact ctx.data is.
    local main_ledger
    do
        local main = ActionCache.getXrayCache(document_path)
        local mdata = main and main.result and XrayParser.isJSON(main.result)
            and XrayParser.parse(main.result) or nil
        if type(mdata) == "table" and not mdata.error
            and type(mdata[XrayParser.DORMANT_KEY]) == "table" then
            main_ledger = mdata[XrayParser.DORMANT_KEY]
        end
    end
    local function commitStubAlias(stub)
        local WriteBack = require("koassistant_artifact_writeback")
        local ok, err, new_data = WriteBack.editLiveXray(document_path, function(d)
            return XrayParser.addStubAlias(d, stub.name, query)
        end, {})
        if not ok then
            UIManager:show(InfoMessage:new{
                text = err == "stale"
                    and _("The carried list changed on disk. Reopen it and try again.")
                    or _("Could not save the alias."),
                timeout = 3,
            })
            return
        end
        UIManager:show(InfoMessage:new{
            text = T(_("Added \"%1\" as alias of %2."), query, stub.name),
            timeout = 3,
        })
        if ctx.on_stub_committed then
            ctx.on_stub_committed(stub, new_data)
        end
    end
    if #alias_cats == 0 and not (main_ledger and #main_ledger > 0) then
        UIManager:show(InfoMessage:new{
            text = _("This X-Ray has no entries an alias could be added to."),
            timeout = 3,
        })
        return
    end

    local function commitAlias(target_item, target_cat_key)
        local target_name = XrayParser.getItemName(target_item, target_cat_key)
        if not target_name then return end
        if not ActionCache.addUserAlias(document_path, target_name, query) then
            UIManager:show(InfoMessage:new{ text = _("Could not save the alias."), timeout = 3 })
            return
        end
        -- Fold into the caller's parsed data so open views show it now
        XrayParser.mergeUserAliases(data, ActionCache.getUserAliases(document_path))
        UIManager:show(InfoMessage:new{
            text = T(_("Added \"%1\" as alias of %2."), query, target_name),
            timeout = 3,
        })
        if ctx.on_committed then
            ctx.on_committed(target_item, target_cat_key, target_name)
        end
    end

    local show_target_picker, show_category_pick, show_entity_page, show_stub_page

    -- Word-overlap suggestions first (a reintroduced character usually
    -- keeps part of the name), manual category pick as the fallback
    show_target_picker = function()
        local pd
        local rows = {}
        for _s_idx, r in ipairs(XrayParser.suggestAliasTargets(data, query, 6)) do
            local s_item, s_cat = r.item, r.category_key
            local nm = XrayParser.getItemName(s_item, s_cat)
            if nm then
                rows[#rows + 1] = { {
                    text = nm .. "  ·  " .. tostring(r.category_label or s_cat),
                    callback = function()
                        UIManager:close(pd)
                        commitAlias(s_item, s_cat)
                    end,
                } }
            end
        end
        -- Carried stubs sharing a word with the query rank alongside
        if main_ledger then
            local q_words = {}
            for w in query:lower():gmatch("%S+") do
                if #w > 2 then q_words[#q_words + 1] = w end
            end
            local added = 0
            for _s_i, stub in ipairs(main_ledger) do
                if added >= 4 then break end
                if type(stub) == "table" and type(stub.name) == "string" and #q_words > 0 then
                    local hay = stub.name:lower()
                    if type(stub.aliases) == "table" then
                        for _a_idx, a in ipairs(stub.aliases) do
                            if type(a) == "string" then hay = hay .. "\n" .. a:lower() end
                        end
                    end
                    local hit = false
                    for _w_idx, w in ipairs(q_words) do
                        if hay:find(w, 1, true) then
                            hit = true
                            break
                        end
                    end
                    if hit then
                        local captured = stub
                        rows[#rows + 1] = { {
                            text = captured.name .. "  ·  " .. T(_("Carried from %1"),
                                captured.source or _("earlier books")),
                            callback = function()
                                UIManager:close(pd)
                                commitStubAlias(captured)
                            end,
                        } }
                        added = added + 1
                    end
                end
            end
        end
        if #rows == 0 then
            -- No word overlap to rank by — straight to the category pick
            show_category_pick()
            return
        end
        rows[#rows + 1] = { { text = _("Pick from all entries…"), callback = function()
            UIManager:close(pd)
            show_category_pick()
        end } }
        rows[#rows + 1] = { { text = _("Cancel"), callback = function() UIManager:close(pd) end } }
        pd = ButtonDialog:new{
            title = T(_("Add \"%1\" as an alias of which entry?"), query),
            buttons = rows,
        }
        UIManager:show(pd)
    end

    show_category_pick = function()
        local pd
        local rows = {}
        for _c_idx, cat in ipairs(alias_cats) do
            local c = cat
            rows[#rows + 1] = { {
                text = tostring(c.label or c.key) .. " (" .. tostring(#c.items) .. ")",
                callback = function()
                    UIManager:close(pd)
                    show_entity_page(c, 1)
                end,
            } }
        end
        if main_ledger and #main_ledger > 0 then
            rows[#rows + 1] = { {
                text = T(_("Carried from earlier books (%1)"), #main_ledger),
                callback = function()
                    UIManager:close(pd)
                    show_stub_page(1)
                end,
            } }
        end
        rows[#rows + 1] = { { text = _("Cancel"), callback = function() UIManager:close(pd) end } }
        pd = ButtonDialog:new{
            title = T(_("Add \"%1\" as an alias of which entry?"), query),
            buttons = rows,
        }
        UIManager:show(pd)
    end

    show_stub_page = function(page)
        local pd
        local per_page = 8
        local stubs = main_ledger or {}
        local total_pages = math.max(1, math.ceil(#stubs / per_page))
        page = math.max(1, math.min(page, total_pages))
        local rows = {}
        for i = (page - 1) * per_page + 1, math.min(page * per_page, #stubs) do
            local stub = stubs[i]
            if type(stub) == "table" and type(stub.name) == "string" then
                local captured = stub
                rows[#rows + 1] = { {
                    text = captured.name .. "  ·  " .. T(_("Carried from %1"),
                        captured.source or _("earlier books")),
                    callback = function()
                        UIManager:close(pd)
                        commitStubAlias(captured)
                    end,
                } }
            end
        end
        local nav = {}
        if total_pages > 1 then
            table.insert(nav, { text = "◀", enabled = page > 1, callback = function()
                UIManager:close(pd)
                show_stub_page(page - 1)
            end })
        end
        table.insert(nav, { text = _("Back"), callback = function()
            UIManager:close(pd)
            show_category_pick()
        end })
        if total_pages > 1 then
            table.insert(nav, { text = "▶", enabled = page < total_pages, callback = function()
                UIManager:close(pd)
                show_stub_page(page + 1)
            end })
        end
        rows[#rows + 1] = nav
        pd = ButtonDialog:new{
            title = T(_("Add \"%1\" as an alias of which entry?"), query)
                .. (total_pages > 1 and ("  (" .. page .. "/" .. total_pages .. ")") or ""),
            buttons = rows,
        }
        UIManager:show(pd)
    end

    show_entity_page = function(cat, page)
        local pd
        local per_page = 8
        local total_pages = math.max(1, math.ceil(#cat.items / per_page))
        page = math.max(1, math.min(page, total_pages))
        local rows = {}
        for i = (page - 1) * per_page + 1, math.min(page * per_page, #cat.items) do
            local it = cat.items[i]
            local nm = XrayParser.getItemName(it, cat.key)
            if nm then
                rows[#rows + 1] = { {
                    text = nm,
                    callback = function()
                        UIManager:close(pd)
                        commitAlias(it, cat.key)
                    end,
                } }
            end
        end
        local nav = {}
        if total_pages > 1 then
            table.insert(nav, { text = "◀", enabled = page > 1, callback = function()
                UIManager:close(pd)
                show_entity_page(cat, page - 1)
            end })
        end
        table.insert(nav, { text = _("Back"), callback = function()
            UIManager:close(pd)
            show_category_pick()
        end })
        if total_pages > 1 then
            table.insert(nav, { text = "▶", enabled = page < total_pages, callback = function()
                UIManager:close(pd)
                show_entity_page(cat, page + 1)
            end })
        end
        rows[#rows + 1] = nav
        pd = ButtonDialog:new{
            title = T(_("Add \"%1\" as an alias of which entry?"), query)
                .. (total_pages > 1 and ("  (" .. page .. "/" .. total_pages .. ")") or ""),
            buttons = rows,
        }
        UIManager:show(pd)
    end

    show_target_picker()
end

-- The lookup's no-results dialog: message + "Add as alias of an entry…"
-- (ref #63) — shared by the single-artifact seam AND the cross-section
-- zero-hit (2026-09-01 device round: that seam was a bare InfoMessage, and
-- on a book with section X-Rays it is the ONLY no-results surface the book
-- ever shows, so the alias offer was unreachable there). data/cached/best
-- describe the artifact the alias picker targets (the MAIN X-Ray at the
-- cross-section seam); without them, or for a non-handle-shaped query, the
-- message shows plain. The model can miss an identity the reader KNOWS —
-- the live case was a reintroduction under a changed name that two of three
-- runs failed to bridge; the shared picker (showAliasTargetPicker above,
-- also reachable from the browser's search-results row) does the ranking
-- and the write.
local function showLookupNoResults(opts)
    local ActionCache = require("koassistant_action_cache")
    local query, msg = opts.query, opts.msg
    -- S3 (ref #90): by the time any seam lands here the lookup has walked
    -- every earlier X-Rayed book too (predLookupHandled), so say so in one
    -- short sentence; opts.note (the "updating may find it" hint) follows
    local walked = ActionCache.groupXrays(opts.document_path)
    local n_earlier = #walked
    if walkIsWide(walked) then
        if n_earlier == 1 then
            msg = msg .. " " .. _("The other book in the group has nothing either.")
        elseif n_earlier > 1 then
            msg = msg .. " " .. T(_("The %1 other books in the group have nothing either."), n_earlier)
        end
    elseif n_earlier == 1 then
        msg = msg .. " " .. _("The earlier book in the group has nothing either.")
    elseif n_earlier > 1 then
        msg = msg .. " " .. T(_("The %1 earlier books in the group have nothing either."), n_earlier)
    end
    if opts.note then msg = msg .. "\n\n" .. opts.note end
    local XrayParser = require("koassistant_xray_parser")
    local ui, config, plugin = opts.ui, opts.config, opts.plugin
    local book_metadata, document_path = opts.book_metadata, opts.document_path
    local data, cached, best = opts.data, opts.cached, opts.best
    local cw = opts.cleanup_widgets and #opts.cleanup_widgets > 0 and opts.cleanup_widgets or nil
    local nores
    local nores_buttons = {}
    local alias_ok = opts.data and opts.cached and opts.document_path
            and #query > 2 and #query <= 120
            and ActionCache.getUserAliasesPath(opts.document_path)
    if alias_ok then
        nores_buttons[#nores_buttons + 1] =
            { { text = _("Add as alias of an entry…"), callback = function()
                UIManager:close(nores)
                showAliasTargetPicker{
                    data = data,
                    query = query,
                    document_path = document_path,
                    on_stub_committed = function(stub, new_data)
                        if not new_data then return end
                        local s2, i2 = XrayParser.findDormantByIdentity(new_data, { stub.name })
                        if s2 then
                            openCarriedStubDetail(ui, new_data, config, plugin,
                                book_metadata, cw, document_path, i2, s2)
                        end
                    end,
                    on_committed = function(target_item, target_cat_key, target_name)
                        local XrayBrowser = openXrayBrowserFromCache(ui, data, cached, config, plugin,
                            book_metadata, best, cw, document_path)
                        for _c_idx, cat in ipairs(XrayParser.getCategories(data) or {}) do
                            if cat.key == target_cat_key then
                                XrayBrowser:showCategoryItems(cat)
                                break
                            end
                        end
                        -- Q6: direct entry — one X exits the browser
                        XrayBrowser._direct_entry_exit = true
                        XrayBrowser:showItemDetail(target_item, target_cat_key, target_name)
                    end,
                }
            end } }
    end
    -- S5 (ref #90): the later-books reveal, offered whenever the chain holds
    -- an X-Rayed later book back (one book per confirm since S7)
    local next_later = nextLaterBook{ document_path = document_path }
    if next_later then
        nores_buttons[#nores_buttons + 1] =
            { { text = laterBookRowText(next_later), callback = function()
                UIManager:close(nores)
                confirmLaterBooksSweep{ ui = ui, config = config, plugin = plugin,
                    book_metadata = book_metadata, cleanup_widgets = cw,
                    document_path = document_path, query = query }
            end } }
    end
    if #nores_buttons == 0 then
        UIManager:show(InfoMessage:new{
            text = msg,
            timeout = 5,
        })
        return
    end
    nores_buttons[#nores_buttons + 1] =
        { { text = _("Close"), callback = function() UIManager:close(nores) end } }
    nores = ButtonDialog:new{
        title = msg,
        buttons = nores_buttons,
    }
    UIManager:show(nores)
end

-- Handle local X-Ray lookup: search cached X-Ray data for the query
-- @param override_best table|nil Pre-selected X-Ray result (from selection popup callback)
local function handleLocalXrayLookup(ui, query, document_path, book_metadata, config, plugin, override_best)
    local logger = require("koassistant_logger")
    logger.dbg("KOAssistant: Local X-Ray lookup for: " .. tostring(query))

    if not document_path then
        UIManager:show(InfoMessage:new{
            text = _("No book open. X-Ray lookup requires an open book."),
            timeout = 3,
        })
        return
    end

    local ActionCache = require("koassistant_action_cache")
    local doc = ui and ui.document
    -- Identity guard (artifact_browser precedent): the live doc informs page
    -- context only when it IS the target book — chat-launched lookups can
    -- target a book other than the one the reader has open (2026-08-13)
    if doc and doc.file ~= document_path then doc = nil end

    -- Card target (round 19): the entity card already resolved ONE entity —
    -- its "full entry" tap must open exactly that one, never a re-search
    -- (device: two entries sharing a handle landed the tap on an unranked
    -- search list instead of the entity the card had just shown). Consume-
    -- once transient; the card threads it for live-main hits only, so the
    -- target branch below reads the main artifact directly.
    local card_target = config and config.features and config.features._xray_lookup_target
    if config and config.features then config.features._xray_lookup_target = nil end
    if card_target then
        local main = ActionCache.getXrayCache(document_path)
        if not (main and main.result) then
            card_target = nil -- artifact vanished since the card resolved
        end
    end

    -- Build cleanup list: widgets to close when browser launches book text search.
    -- Prevents dictionary popup and cross-section results from blocking search highlights.
    local cleanup_widgets = {}
    local source_widget = config and config.features and config.features._source_widget
    if source_widget then
        table.insert(cleanup_widgets, source_widget)
    end

    -- Cross-section search: when multiple X-Rays exist and no override, search all
    -- (a card target skips this — its entity lives in the main artifact)
    if not override_best and not card_target then
        local sections = ActionCache.getSectionXrays(document_path)
        local main = ActionCache.getXrayCache(document_path)
        local total_xrays = #sections + (main and main.result and 1 or 0)

        if total_xrays == 0 then
            -- S2 (ref #90): a book with no X-Ray of its own still answers
            -- from its group's earlier books — the reporter's "never
            -- X-Rayed this volume" case. On a miss the shared no-results
            -- surface offers the whole-chain sweep (no alias target here).
            if predLookupHandled(ui, query, config, plugin, book_metadata,
                    cleanup_widgets, document_path) then
                return
            end
            showLookupNoResults{
                ui = ui, config = config, plugin = plugin,
                book_metadata = book_metadata, cleanup_widgets = cleanup_widgets,
                document_path = document_path, query = query,
                msg = _("No X-Ray found for this book. Generate one first via the X-Ray action."),
            }
            return
        end

        if total_xrays > 1 then
            -- Multiple X-Rays: search across all (name + alias only for lookup)
            local grouped = ActionCache.searchAllXrays(document_path, query, doc, { skip_description = true })
            if #grouped == 0 then
                -- Carried tier (S1, ref #90): the main ledger answers before
                -- "no results anywhere"
                local mdata = mainLedgerData(document_path, nil, nil)
                if mdata and carriedLookupHandled(ui, mdata, query, config, plugin,
                        book_metadata, cleanup_widgets, document_path) then
                    return
                end
                -- Predecessor tier (S2, ref #90): the nearest earlier
                -- X-Rayed book answers before "no results anywhere"
                if predLookupHandled(ui, query, config, plugin, book_metadata,
                        cleanup_widgets, document_path) then
                    return
                end
                -- No results anywhere: the shared dialog, so the alias
                -- offer exists on multi-X-Ray books too. It targets the
                -- MAIN artifact; without one the message shows plain.
                showLookupNoResults{
                    ui = ui, config = config, plugin = plugin,
                    book_metadata = book_metadata, cleanup_widgets = cleanup_widgets,
                    document_path = document_path, query = query,
                    msg = T(_("No results for \"%1\" in this book's X-Rays."), query),
                    data = mdata,
                    cached = (main and main.result) and main or nil,
                    best = (main and main.result) and { entry = main } or nil,
                }
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
                -- (the carried group rides along — S1, ref #90)
                local mdata = mainLedgerData(document_path, nil, nil)
                local carried_hits = mdata
                    and require("koassistant_xray_parser")
                        .searchLedger(mdata, query, { skip_description = true }) or {}
                showCrossSectionResults(grouped, query, ui, config, plugin, book_metadata,
                    cleanup_widgets, document_path,
                    #carried_hits > 0 and { data = mdata, hits = carried_hits } or nil)
                return
            end
        end
    end

    -- Find best X-Ray: prefer section covering current page, fall back to main
    -- (card target forces the MAIN artifact — that is where its entity lives,
    -- and findBestXray could prefer a section covering the current page)
    local best
    if card_target then
        best = { entry = ActionCache.getXrayCache(document_path) }
    else
        best = override_best or ActionCache.findBestXray(document_path, doc)
    end

    if not best then
        UIManager:show(InfoMessage:new{
            text = _("No X-Ray found for this book. Generate one first via the X-Ray action."),
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
            text = _("Could not parse X-Ray data. Try regenerating the X-Ray."),
            timeout = 3,
        })
        return
    end

    -- User search terms must match in lookup too, not only in the browser
    -- (F1, xray_marking_plan.md, ref #63)
    XrayParser.mergeUserAliases(data, ActionCache.getUserAliases(document_path))

    -- Carried card target (S1, ref #90): the card resolved a LEDGER stub —
    -- open its carried-detail page directly (a stale target falls through)
    if card_target and card_target.carried and card_target.name then
        local ledger = data[XrayParser.DORMANT_KEY]
        if type(ledger) == "table" then
            for s_i, s in ipairs(ledger) do
                if type(s) == "table" and s.name == card_target.name then
                    openCarriedStubDetail(ui, data, config, plugin, book_metadata,
                        #cleanup_widgets > 0 and cleanup_widgets or nil, document_path, s_i, s)
                    return
                end
            end
        end
    end

    -- Card target (round 19): open the card's own entity, stacked on its
    -- category — no search at all. A stale target (entity renamed/removed
    -- since the card resolved) falls through to the normal flow.
    if card_target and card_target.name and card_target.category_key then
        local titems = data[card_target.category_key]
        if type(titems) == "table" then
            for _t_idx, titem in ipairs(titems) do
                if XrayParser.getItemName(titem, card_target.category_key) == card_target.name then
                    local XrayBrowser = openXrayBrowserFromCache(ui, data, cached, config, plugin,
                        book_metadata, best, #cleanup_widgets > 0 and cleanup_widgets or nil, document_path)
                    for _c_idx, cat in ipairs(XrayParser.getCategories(data) or {}) do
                        if cat.key == card_target.category_key then
                            XrayBrowser:showCategoryItems(cat)
                            break
                        end
                    end
                    -- Q6: direct entry — one X from the entity page exits the browser
                    XrayBrowser._direct_entry_exit = true
                    XrayBrowser:showItemDetail(titem, card_target.category_key, card_target.name)
                    return
                end
            end
        end
    end

    -- Search name + alias only (description matches are noise for dictionary lookup)
    local results = XrayParser.searchAll(data, query, { skip_description = true })

    -- Calculate progress gap (only for main X-Ray; sections cover fixed ranges;
    -- doc-guarded — the live position means nothing for another book's X-Ray)
    local current_progress = doc and getProgressDecimal(ui) or nil
    local cache_progress = cached.progress_decimal
    local progress_gap = nil
    if not best.is_section and current_progress and cache_progress then
        progress_gap = current_progress - cache_progress
    end

    if #results == 0 then
        -- Carried tier (S1, ref #90): stubs answer before the no-results
        -- dialog (exact -> the stub's page; substring -> the results list,
        -- which renders the carried group)
        local carried_mdata = mainLedgerData(document_path, data, best)
        if carried_mdata and carriedLookupHandled(ui, carried_mdata, query, config, plugin,
                book_metadata, cleanup_widgets, document_path) then
            return
        end
        -- Predecessor tier (S2, ref #90): the nearest earlier X-Rayed book
        -- answers before the no-results dialog
        if predLookupHandled(ui, query, config, plugin, book_metadata,
                cleanup_widgets, document_path) then
            return
        end
        -- No results
        local msg = T(_("No results for \"%1\" in this book's X-Ray."), query)
        if best.is_section and best.label then
            msg = T(_("No results for \"%1\" in Section X-Ray: %2."), query, best.label)
        end
        local note
        if progress_gap and progress_gap > 0.08 then
            local cache_pct = math.floor(cache_progress * 100 + 0.5)
            local current_pct = math.floor(current_progress * 100 + 0.5)
            note = T(_("X-Ray covers to %1% (you're at %2%). Updating may find this entry."), cache_pct, current_pct)
        end
        -- Shared no-results dialog (ref #63): message + the alias offer —
        -- extracted to showLookupNoResults so the cross-section zero-hit
        -- shows the same surface.
        showLookupNoResults{
            ui = ui, config = config, plugin = plugin, book_metadata = book_metadata,
            cleanup_widgets = cleanup_widgets, document_path = document_path,
            query = query, msg = msg, note = note, data = data, cached = cached, best = best,
        }
    else
        -- Exact-identity fast path (device round 2026-08-13, ref #63): a query
        -- that IS an entity's name or alias goes straight to that entity —
        -- searchAll matches by substring, so a full name also hits every
        -- entry whose name/alias CONTAINS it and the lookup landed on a results
        -- list instead of the obvious entry. Exactness outranks fuzzy hits;
        -- the results list remains for fuzzy-only matches and for
        -- disambiguation when several entities share the exact name.
        local query_exact = XrayParser.normalizeArabic(
            (query:lower():gsub("^%s+", ""):gsub("%s+$", "")))
        local exact = {}
        for _idx, r in ipairs(results) do
            local handles = { XrayParser.getItemName(r.item, r.category_key) }
            local r_aliases = r.item.aliases
            if type(r_aliases) == "string" then r_aliases = { r_aliases } end
            if type(r_aliases) == "table" then
                for _idx2, a in ipairs(r_aliases) do table.insert(handles, a) end
            end
            for _idx2, h in ipairs(handles) do
                if type(h) == "string"
                    and XrayParser.normalizeArabic(h:lower()) == query_exact then
                    table.insert(exact, r)
                    break
                end
            end
        end

        -- Carried tier (S1, ref #90): exact stub handles join the exact set.
        -- A same-handle stub in the SAME family cannot coexist with a live
        -- entity (the wake-pass would have woken it); a different family can
        -- (lexicon "Warden" vs a carried character) and the chooser shows both.
        local carried_mdata = mainLedgerData(document_path, data, best)
        local stub_exact = carried_mdata
            and XrayParser.searchLedger(carried_mdata, query, { exact = true }) or {}
        local carried_cw = #cleanup_widgets > 0 and cleanup_widgets or nil
        if #exact == 0 and #stub_exact == 1 then
            openCarriedStubDetail(ui, carried_mdata, config, plugin, book_metadata,
                carried_cw, document_path, stub_exact[1].stub_idx, stub_exact[1].stub)
            return
        end

        -- Open X-Ray browser directly
        local XrayBrowser = openXrayBrowserFromCache(ui, data, cached, config, plugin, book_metadata, best,
            #cleanup_widgets > 0 and cleanup_widgets or nil, document_path)

        -- Exact only (device 2026-08-17): a LONE fuzzy hit used to auto-open
        -- too ("or #results == 1"), which read as landing on an unrelated
        -- entry — substring hits inside names are results-list material
        if #exact == 1 and #stub_exact == 0 then
            -- One clear target: the entity page, stacked on its home
            -- category so the back arrow lands in the entry's natural group
            -- (not the search carousel — maintainer 2026-08-13)
            local result = exact[1] or results[1]
            local name = XrayParser.getItemName(result.item, result.category_key)
            for _idx, cat in ipairs(XrayParser.getCategories(data) or {}) do
                if cat.key == result.category_key then
                    XrayBrowser:showCategoryItems(cat)
                    break
                end
            end
            -- Q6 (consolidation round): a directly-entered entity page exits
            -- the whole browser in one X — the category stack underneath is
            -- chrome the reader never opened; ← still reveals it for browsing
            XrayBrowser._direct_entry_exit = true
            XrayBrowser:showItemDetail(result.item, result.category_key, name)
        elseif #exact + #stub_exact > 1 then
            -- Several entities share the exact handle (round 19, device: a
            -- place and a lexicon term under one name): a compact
            -- DISAMBIGUATION of just the exact matches, with the full search
            -- one row away — the old path dumped straight into the browser's
            -- full search, where the exact entries were not even on top. The
            -- browser root is already open underneath as the landing base.
            local ButtonDialog = require("ui/widget/buttondialog")
            local chooser
            local rows = {}
            for _idx, r in ipairs(exact) do
                local captured = r
                local nm = XrayParser.getItemName(captured.item, captured.category_key)
                rows[#rows + 1] = {{
                    text = nm .. "  ·  " .. tostring(captured.category_label or captured.category_key),
                    align = "left",
                    callback = function()
                        UIManager:close(chooser)
                        for _c_idx, cat in ipairs(XrayParser.getCategories(data) or {}) do
                            if cat.key == captured.category_key then
                                XrayBrowser:showCategoryItems(cat)
                                break
                            end
                        end
                        -- Q6: still the direct lookup flow — one X exits
                        XrayBrowser._direct_entry_exit = true
                        XrayBrowser:showItemDetail(captured.item, captured.category_key, nm)
                    end,
                }}
            end
            for _idx, s in ipairs(stub_exact) do
                local captured = s
                rows[#rows + 1] = {{
                    text = captured.stub.name .. "  ·  " .. T(_("Carried from %1"),
                        captured.source_title or _("earlier books")),
                    align = "left",
                    callback = function()
                        UIManager:close(chooser)
                        if best.is_section then
                            openCarriedStubDetail(ui, carried_mdata, config, plugin,
                                book_metadata, carried_cw, document_path,
                                captured.stub_idx, captured.stub)
                        else
                            XrayBrowser:showDormantList()
                            local d_rows = XrayBrowser:_dormantRows()
                            local display_i
                            for ri, r in ipairs(d_rows) do
                                if r.idx == captured.stub_idx then
                                    display_i = ri
                                    break
                                end
                            end
                            XrayBrowser:showDormantDetail(captured.stub_idx, captured.stub,
                                display_i and { rows = d_rows, index = display_i } or nil)
                        end
                    end,
                }}
            end
            rows[#rows + 1] = {{
                text = _("Full search results…"),
                callback = function()
                    UIManager:close(chooser)
                    XrayBrowser:showSearchResults(query, true)
                end,
            }}
            chooser = ButtonDialog:new{
                title = T(_("\"%1\" matches %2 entries"), query, #exact + #stub_exact),
                buttons = rows,
            }
            UIManager:show(chooser)
        else
            -- Fuzzy-only matches: show search results in browser
            -- Skip "Search other X-Rays" button — cross-section search already ran
            XrayBrowser:showSearchResults(query, true)
        end

    end
end

-- Dispatch a local (non-AI) action handler
local function handleLocalAction(handler_name, ui, highlighted_text, document_path, book_metadata, config, plugin)
    local logger = require("koassistant_logger")

    if handler_name == "xray_lookup" then
        handleLocalXrayLookup(ui, highlighted_text, document_path, book_metadata, config, plugin)
    elseif handler_name == "image_gen" then
        -- The old hardcoded highlight button as a local action (2026-08-13):
        -- same network gate + settings refresh; book association now follows
        -- document_path too, so viewer/file-browser launches credit the right
        -- book in the images index instead of silently dropping it.
        local book_info
        if ui and ui.document and ui.document.file
            and (not document_path or ui.document.file == document_path) then
            book_info = {
                file = ui.document.file,
                title = ui.doc_props and (ui.doc_props.display_title or ui.doc_props.title),
            }
        elseif document_path then
            book_info = {
                file = document_path,
                title = book_metadata and book_metadata.title,
            }
        end
        -- Consume-once framing context: the pre-extracted selection window
        -- rides _selection_context_window only for this handler (the entry
        -- points nil it for other local handlers)
        local window = config and config.features and config.features._selection_context_window
        if config and config.features then config.features._selection_context_window = nil end
        local NetworkMgr = require("ui/network/manager")
        NetworkMgr:runWhenConnected(function()
            if plugin and plugin.updateConfigFromSettings then plugin:updateConfigFromSettings() end
            require("koassistant_image_generator").generate(highlighted_text, config,
                plugin and plugin.settings, book_info,
                { window = window, book_metadata = book_metadata })
        end)
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
-- Store rerun info for the compact/translate viewer's re-run row (action switcher,
-- Language, Ctx toggle). Shared by executeDirectAction's onComplete and the input
-- dialog's onPromptComplete so the two launch paths can't drift (the input-dialog
-- path historically skipped this, leaving the row dead with a "?" switcher).
-- NOTE: Only store complex objects at config top level, not in features (deepCopy
-- would overflow on them); the viewer's re-run callbacks exclude ^_rerun_ keys.
local function attachRerunContext(temp_config, action, ui, plugin)
    if temp_config and temp_config.features and (temp_config.features.minimal_buttons or temp_config.features.translate_view) then
        temp_config._rerun_action = action
        temp_config._rerun_ui = ui
        temp_config._rerun_plugin = plugin
        -- Preserve original context across re-runs (don't overwrite if already set)
        if not temp_config.features._original_context then
            temp_config.features._original_context = temp_config.features.dictionary_context or ""
            temp_config.features._original_context_mode = temp_config.features.dictionary_context_mode or "sentence"
        end
    end
end

local function executeDirectAction(ui, action, highlighted_text, configuration, plugin, opts)
    local logger = require("koassistant_logger")

    if not action then
        logger.err("KOAssistant: executeDirectAction called without action")
        UIManager:show(InfoMessage:new{
            text = _("Error: No action specified"),
            timeout = 2
        })
        return
    end

    logger.dbg("KOAssistant: Executing quick action - " .. (action.text or action.id))
    logger.dbg("KOAssistant: executeDirectAction - configuration.features.book_metadata=",
               configuration and configuration.features and configuration.features.book_metadata and "present" or "nil")
    if configuration and configuration.features and configuration.features.book_metadata then
        logger.dbg("KOAssistant: executeDirectAction - book_metadata.title=", configuration.features.book_metadata.title or "nil")
    end

    -- Get document info if available
    local document_path = nil
    local book_metadata = nil
    -- Originating-surface book override (opts.document_path — set by the
    -- chat-viewer/selection-popup X-Ray lookup chain): the chat may be about a
    -- different book than the open one, so its identity beats the live
    -- document (device 2026-08-13: wrong-book lookups)
    local forced_path = opts and opts.document_path

    if ui and ui.document and (not forced_path or ui.document.file == forced_path) then
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

    if forced_path then
        document_path = forced_path
    end

    -- Fallback for file browser actions: no open document but book metadata has file path
    local cfg_metadata = configuration and configuration.features and configuration.features.book_metadata
    if not document_path and cfg_metadata and cfg_metadata.file then
        document_path = cfg_metadata.file
    end
    if not book_metadata and cfg_metadata
        and (not forced_path or cfg_metadata.file == forced_path) then
        book_metadata = {
            title = cfg_metadata.title or "Unknown",
            author = cfg_metadata.author or "",
        }
    end
    -- Forced path with no matching metadata source: read the book's own
    -- sidecar props (the stale global book_metadata may name a THIRD book)
    if forced_path and not book_metadata then
        local ds = SafeDocSettings.resolve(forced_path, ui)
        local props = SafeDocSettings.overlayCustomProps(ds and ds:readSetting("doc_props"), forced_path) or {}
        local author = props.authors
        if author and author:find("\n") then
            author = author:gsub("\n", ", ")
        end
        local fname = forced_path:match("([^/\\]+)$")
        if fname then
            fname = fname:gsub("%.[^%.]+$", ""):gsub("[_-]", " ")
        end
        book_metadata = {
            title = (props.title and props.title ~= "") and props.title or fname or "Unknown",
            author = (author and author ~= "") and author or "",
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

    -- Rate-limit retry (see showRequestError): re-runs this action from the same inputs.
    -- Forward-declared because onComplete below closes over it, and assigned only after
    -- the early-return paths (local handlers, cached artifacts) are out of the way.
    -- retry_web_was_on: whether web search resolved ON for this request (drives the
    -- "Try again without web search" offer); assigned beside retryDirect below.
    local retryDirect
    local retry_web_was_on = false

    -- Callback for when response is ready
    local function onComplete(history, temp_config_or_error)
        if history then
            local temp_config = temp_config_or_error
            attachRerunContext(temp_config, action, ui, plugin)
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
                            and (os.date("%Y-%m-%d %H:%M", section_cache.timestamp) .. " (" .. _("today") .. ")")
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
                            and (os.date("%Y-%m-%d %H:%M", xray_cache.timestamp) .. " (" .. _("today") .. ")")
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
                            merged_from_books = xray_cache.merged_from_books,
                            merged_from = xray_cache.merged_from,
                            cache_metadata = {
                                cache_type = "xray",
                                book_title = book_title,
                                progress_decimal = xray_cache.progress_decimal,
                                model = xray_cache.model,
                                timestamp = xray_cache.timestamp,
                                used_annotations = xray_cache.used_annotations,
                                used_book_text = xray_cache.used_book_text,
                            },
                        }, ui, function(keep_versions)
                            -- Same shared lineage delete as the other
                            -- XrayBrowser:show callback above (round 28)
                            ActionCache.deleteXray(ui.document.file, { keep_versions = keep_versions })
                            require("koassistant_book_settings").clearXrayLineageState(
                                SafeDocSettings.resolve(ui.document.file, ui),
                                configuration and configuration.features)
                            UIManager:show(Notification:new{
                                text = keep_versions and _("X-Ray deleted — archived versions kept")
                                    or T(_("%1 deleted"), "X-Ray"),
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
                -- Requested-vs-delivered honesty (consume-once transient from the
                -- quiz-instruction build). Surfaced as a toast, never a retry —
                -- the shortfall costs nothing but candor.
                local requested_count = configuration and configuration.features
                    and configuration.features._quiz_requested_count
                if requested_count then
                    configuration.features._quiz_requested_count = nil
                end
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
                            ui = ui,
                            plugin = plugin,
                            document_path = quiz_file,
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
                    if requested_count and #parsed.questions ~= requested_count then
                        local Notification = require("ui/widget/notification")
                        UIManager:show(Notification:new{
                            text = T(_("The model generated %1 of %2 requested questions."),
                                #parsed.questions, requested_count),
                            timeout = 3,
                        })
                    end
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
            showRequestError(_("Error: ") .. error_msg, retryDirect, nil,
                retry_web_was_on and { web = true } or nil)
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

    -- Rate-limit retry: re-run the whole action so both dispatch paths below (smart
    -- retrieval and the plain call) are covered. The selection-context window is a
    -- consume-once transient and the selection itself died with the popup, so stash it
    -- and put it back — otherwise a retried highlight action would silently lose its
    -- ambient context. It is the only transient a direct entry consumes (attachments and
    -- the quick-chip overrides are dialog-launch only).
    local sc_window = configuration and configuration.features
        and configuration.features._selection_context_window
    -- A stripped retry re-enters this function recursively with the web-off session
    -- transient still set (it is consumed later, inside handlePredefinedPrompt) —
    -- stash it so the stripped state STICKS across further retries and this
    -- invocation's failure dialog offers no second drop row (device round: the
    -- dialog re-offered "without web search" after a stripped retry failed).
    local web_off = configuration and configuration.features
        and configuration.features._web_search_active == false
    -- Web-off retry offer: only when web resolved ON for this request from the
    -- book/global layer. An action's own enable_web_search pin wins over the session
    -- layer (governance matrix), so a pinned action (fact_check) is never offered a
    -- web-off retry it could not honor.
    if action.enable_web_search == nil and not web_off then
        local ws = bookWebSearchOverride(configuration and configuration.features)
        if ws ~= nil then
            retry_web_was_on = ws == true
        else
            retry_web_was_on = (configuration and configuration.features
                and configuration.features.enable_web_search == true) or false
        end
    end
    retryDirect = function(drop)
        if configuration and configuration.features then
            configuration.features._selection_context_window = sc_window
            -- Web-off retry rides the session-layer transient: createTempConfig copies
            -- it into the request config and buildUnifiedRequestConfig bakes-and-
            -- consumes it, so the whole rebuild runs web-off exactly once per attempt;
            -- web_off re-arms it so plain retries after a strip stay stripped. (Tools
            -- are never in the direct-action offer: predefined actions get explicit
            -- _tools_active = false at bake, so tools were off on the failed request.)
            if drop or web_off then
                configuration.features._web_search_active = false
            end
        end
        executeDirectAction(ui, action, highlighted_text, configuration, plugin)
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
    logger.dbg("KOAssistant: executeDirectAction calling handlePredefinedPrompt with highlighted_text:", highlighted_text and #highlighted_text or "nil/empty")
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
    -- Headless one-shot execution has no session chip: clear any spoiler session
    -- residue a prior chat's Send left on this (possibly shared) config, so the §3
    -- resolution falls through to research/book/global. The X-Ray browser's wiki
    -- call rides the shared configuration, where an X-Ray chat's explicit
    -- true/false would otherwise pose as this request's session layer.
    if configuration and configuration.features then
        configuration.features._spoiler_free_active = nil
    end
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
    local artifact_ds = document_path and SafeDocSettings.resolve(document_path, ui) or nil
    if document_path then
        ai_book_metadata = require("koassistant_book_settings").applyMetadataOverride(book_metadata, artifact_ds)
        artifact_research = require("koassistant_book_settings").resolveResearch(
            artifact_ds, configuration.features,
            { doi = book_metadata and book_metadata.doi })
    end
    configuration.features = configuration.features or {}
    configuration.features._research_mode_active = artifact_research or nil
    -- Artifact chat is spoiler-excluded (chatting ABOUT an artifact that may span the
    -- whole book — a position nudge would contradict the context itself): clear any
    -- leaked chip value AND raise the one-shot _spoiler_exclude marker so the hub's
    -- C4-revised block below marks this chat ineligible for the live turn-level
    -- nudge (_spoiler_live stays nil for the chat's whole life, replies included).
    -- Same for the per-chat tools checkbox: artifact chat follows the global flag only.
    -- And the per-chat web toggle: artifact chat follows the per-book/global defaults.
    configuration.features._spoiler_free_active = nil
    configuration.features._spoiler_exclude = true
    configuration.features._tools_active = nil
    configuration.features._web_search_active = nil
    -- Stale X-Ray-chat marker from a prior freeform send would mislabel this
    -- chat's reply Tools toggle "N/A (X-Ray)" AND suppress tools in shouldUse —
    -- artifact chats are never X-Ray chats.
    configuration.features._xray_chat_active = nil
    -- Artifact chats start at the global view mode — never another chat's tap
    configuration.features._chat_view_mode = nil
    -- Quick controls: artifact chat follows the global settings too — clear the
    -- dispatch consumables and any lingering chip state (matrix §10).
    configuration.features._quick_answer_active = nil
    configuration.features._reasoning_override_active = nil
    configuration.features._model_override_active = nil
    configuration.features._session_quick_answer = nil
    configuration.features._session_reasoning = nil
    configuration.features._session_model = nil

    -- Domain layer (injection_gating_audit): artifact chat used to pass a literal
    -- nil domain_context — the only chat surface with no domain at all, silently
    -- dropping the book's (or global) domain for every reply in the chat. Same
    -- priority as freeform Send (no action layer): the ARTIFACT's book domain >
    -- global selected_domain; "_none" sentinel blocks the global fallthrough.
    local domain_context = nil
    local artifact_domain_id = nil
    do
        artifact_domain_id = require("koassistant_book_settings").resolveDomain(
            artifact_ds, configuration.features)
        if artifact_domain_id then
            local DomainLoader = require("domain_loader")
            local custom_domains = configuration.features
                and configuration.features.custom_domains or {}
            local domain = DomainLoader.getDomainById(artifact_domain_id, custom_domains)
            if domain then
                domain_context = domain.context
            end
        end
    end

    -- Build system prompt (standard book chat)
    buildUnifiedRequestConfig(configuration, domain_context, nil, plugin)

    -- Create history with artifact type as prompt_action for title generation
    local history = MessageHistory:new(nil, nil)
    history.prompt_action = artifact_type_name
    -- Store domain for chat-save parity with freeform Send
    history.domain = artifact_domain_id
    -- Launch tag (device round 2): prompt_action holds the display name; this is
    -- the stable "came from an artifact viewer" marker for future grouping surfaces
    history.launched_from = "artifact"
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

    -- Query AI with the consolidated message.
    -- send_cfg = the config of the CURRENT attempt (see the freeform site): the
    -- web/tools-off retry rebases it onto its stripped copy so retries stay
    -- stripped and a further failure offers no second drop row.
    local send_cfg = configuration
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
            -- Rate-limit retry: the history/config are already built, so re-issuing is
            -- literally the same call. Nothing was appended to the history on failure.
            -- The "without …" row re-issues on a copy with web search and/or book tools
            -- forced off, rebased into send_cfg (sticky across retries, no second drop
            -- offer; the chat's own settings are untouched).
            local had_web = send_cfg.enable_web_search == true
                or (send_cfg.enable_web_search == nil
                    and send_cfg.features
                    and send_cfg.features.enable_web_search == true)
            local had_tools = BookToolRunner.shouldUse(send_cfg, ui)
            showRequestError(_("Error: ") .. (err or "Unknown error"), function(drop)
                if drop then
                    local cfg = {}
                    for k, v in pairs(send_cfg) do cfg[k] = v end
                    cfg.features = {}
                    for k, v in pairs(send_cfg.features or {}) do
                        cfg.features[k] = v
                    end
                    if had_web then
                        cfg.enable_web_search = false
                        cfg.features.enable_web_search = false
                    end
                    if had_tools then
                        cfg.features._tools_active = false
                    end
                    send_cfg = cfg
                end
                BookToolRunner.queryWith(queryChatGPT, history:getMessages(), send_cfg,
                    onResponseReady, plugin, ui)
            end, nil, (had_web or had_tools)
                and { web = had_web, tools = had_tools } or nil)
        end
    end

    BookToolRunner.queryWith(queryChatGPT, history:getMessages(), configuration, onResponseReady, plugin, ui)
end

return {
    showChatGPTDialog = showChatGPTDialog,
    -- Exported for the X-Ray browser's search-results "Add as alias…" row
    -- (inline require there — a top-level require would be circular)
    showAliasTargetPicker = showAliasTargetPicker,
    showPredecessorEntity = showPredecessorEntity,
    showEarlierBooksSweep = showEarlierBooksSweep,
    confirmLaterBooksSweep = confirmLaterBooksSweep,
    collectPredGroups = collectPredGroups,
    executeDirectAction = executeDirectAction,
    executeActionForResult = executeActionForResult,
    generateSummaryCache = generateSummaryCache,
    extractSurroundingContext = extractSurroundingContext,
    fetchSelectionContextWindow = fetchSelectionContextWindow,
    launchArtifactChat = launchArtifactChat,
    -- Exported for runtime self-require from the quick chip's hold (60-upvalue
    -- cap) and for the reply-dialog reuse planned in parity slice (b).
    showQuickPresetEditor = showQuickPresetEditor,
    showQuickPresetNudge = showQuickPresetNudge,
    quickPresetNudgeLabel = quickPresetNudgeLabel,
    applyQuickReplyOverrides = applyQuickReplyOverrides,
    quickPresetForces = quickPresetForces,
    showAttachMenu = showAttachMenu,
    attachChipLabel = attachChipLabel,
    -- Exported for the main-settings action row (AskGPT:showQuickPresetModelMode)
    showQuickPresetModelMode = showQuickPresetModelMode,
    showQuickPresetBehavior = showQuickPresetBehavior,
    quickPresetBehaviorLabel = quickPresetBehaviorLabel,
    -- Exported for runtime self-require from performSend's scope-consent check
    -- (60-upvalue cap — a direct file-local reference inside that closure breaks
    -- the whole-plugin load)
    effectiveDispatchProvider = effectiveDispatchProvider,
    -- Exported for runtime self-require from the input dialog's onPromptComplete
    -- (same 60-upvalue cap)
    attachRerunContext = attachRerunContext,
    -- Exported for main.lua's global tier pins screen (tier GUI phase 2) — the
    -- same key-filtered provider→model picker the ⚡ menu uses
    pickProviderModel = pickProviderModel,
}
