--[[
koassistant_run_options.lua - run an action another way, once (B345,
docs/run_options_plan.md), plus the dispatch-scoped model stash.

A run option is a one-run pick from an action's hold menu: Quick on/off, a
model (up to three spots: the reader's recent "More models…" picks, then the
provider's Fast model), no reasoning, web on/off. It stands in for the chips
for that run, so the action's own settings still win over its Quick, reasoning
and web parts; a picked MODEL also beats the action's own model pin. Artifact
actions (cached, parsed or incremental) take the model only.

Request side: the pick rides features._run_variant, always with an exact
provider/model (the Fast tier is resolved here, when the button is built, so
the label and the request agree). Dialogs.executeDirectAction and the input
dialog set it just-in-time; buildUnifiedRequestConfig consumes it.

`buttons()` and `addRecent()` are pure (unit-tested); `stateFor()` reads the
live settings.

The stash: a dispatch-scoped model write (an action's pin, a tier hint, the
Quick preset's model, a run option) must not outlive the chat it was made for.
The next dispatch from the same config (a compact-window action swap, a re-run)
undoes it first. beginDispatch() does that and opens the new dispatch's stash;
stashBucket() records a per-provider model slot before a write overwrites it.
]]

local _ = require("koassistant_gettext")

local RunOptions = {}

-- The shipped options, in menu order. Each pair shows only the half that
-- changes something for the run; list() puts the recent picks ahead of Fast.
RunOptions.DEFAULTS = {
    { id = "quick_on", quick = true },
    { id = "quick_off", quick = false },
    { id = "fast", tier = "fast" },
    { id = "reasoning_off", reasoning = "off" },
    { id = "web_off", web = false },
    { id = "web_on", web = true },
}

-- Model buttons in the hold menu (recent picks, then Fast), before "More models…"
RunOptions.MODEL_SPOTS = 3
-- Recent picks kept: more than the spots, since some are hidden for an action
RunOptions.RECENT_KEEP = 5

--- The reader's recent "More models…" picks, newest first.
function RunOptions.recentModels(features)
    local out = {}
    local l = features and features.run_recent_models
    if type(l) ~= "table" then return out end
    for _idx, r in ipairs(l) do
        if type(r) == "table" and type(r.provider) == "string" and type(r.model) == "string" then
            out[#out + 1] = { provider = r.provider, model = r.model }
        end
    end
    return out
end

--- The hold menu's options: the defaults, with the recent picks ahead of Fast.
function RunOptions.list(features)
    local out = {}
    for _idx, e in ipairs(RunOptions.DEFAULTS) do
        if e.tier then
            for _idx2, r in ipairs(RunOptions.recentModels(features)) do
                out[#out + 1] = r
            end
        end
        out[#out + 1] = e
    end
    return out
end

--- A "More models…" pick joins the recent list: a new model goes first, one
--- already there keeps its place (the spots stay put), the oldest drops.
--- @return table|nil the new list, nil when nothing changes
function RunOptions.addRecent(list, provider, model)
    if not (provider and model) then return nil end
    for _idx, r in ipairs(list or {}) do
        if r.provider == provider and r.model == model then return nil end
    end
    local out = { { provider = provider, model = model } }
    for _idx, r in ipairs(list or {}) do
        if #out >= RunOptions.RECENT_KEEP then break end
        out[#out + 1] = r
    end
    return out
end

--- Save a "More models…" pick to the recent list.
function RunOptions.rememberPick(plugin, provider, model)
    if not (plugin and plugin.settings) then return end
    local f = plugin.settings:readSetting("features") or {}
    local nxt = RunOptions.addRecent(RunOptions.recentModels(f), provider, model)
    if not nxt then return end
    f.run_recent_models = nxt
    plugin.settings:saveSetting("features", f)
    plugin.settings:flush()
end

--- Artifact actions take the model part of a run option only: their output is
--- cached, parsed or merged, and their reasoning / Quick settings protect that.
function RunOptions.isModelOnly(action)
    if type(action) ~= "table" then return false end
    return action.use_response_caching == true
        or action.cache_as_xray == true
        or action.cache_as_analyze == true
        or action.cache_as_summary == true
        or action.update_prompt ~= nil
        or action.interactive_quiz == true
        -- AI Wiki: cached per selection by the dispatch (executeDirectAction)
        or action.id == "wiki"
end

--- The provider/model an entry's model part points at.
--- @param e table list entry ({ tier = ... } or { provider = ..., model = ... })
--- @param base_provider string provider a tier resolves against
--- @param resolve_tier function|nil (provider, tier) -> provider, model
--- @return string|nil provider, string|nil model
function RunOptions.variantTarget(e, base_provider, resolve_tier)
    if type(e) ~= "table" then return nil end
    if e.provider then return e.provider, e.model end
    if e.tier then
        resolve_tier = resolve_tier or require("koassistant_model_lists").resolveTierTarget
        return resolve_tier(base_provider, e.tier)
    end
    return nil
end

-- The facet's icon (the chips' and Quick Settings' own) when emoji icons are on
local function withIcon(icon, text, st)
    return st.emoji and (icon .. " " .. text) or text
end

local function labelFor(v, st)
    if v.provider then
        return withIcon("\u{1F916}", v.model, st)
    elseif v.quick == true then
        return withIcon("\u{26A1}", _("Quick answer"), st)
    elseif v.quick == false then
        return withIcon("\u{26A1}", _("Without Quick"), st)
    elseif v.reasoning == "off" then
        return withIcon("\u{1F9E0}", _("No reasoning"), st)
    elseif v.web == true then
        return withIcon("\u{1F310}", _("With web search"), st)
    end
    return withIcon("\u{1F310}", _("Without web search"), st)
end

--- One entry as a button for this action, or nil when it cannot apply here or
--- would change nothing.
--- @param e table list entry
--- @param model_only boolean the action takes the model part only
--- @param st table state (see stateFor)
--- @return table|nil { label = string, variant = table }
function RunOptions.button(e, model_only, st)
    if type(e) ~= "table" then return nil end
    local v = {}
    if e.tier ~= nil or e.provider ~= nil then
        local p, m = RunOptions.variantTarget(e, st.tier_base, st.resolveTier)
        if not p or not m then return nil end
        if st.configured and not st.configured(p) then return nil end
        -- The model a normal tap already uses changes nothing
        if p == st.base.provider and m == st.base.model then return nil end
        v.provider, v.model = p, m
    elseif model_only then
        return nil
    elseif e.quick ~= nil then
        if not st.quick.receptive or (e.quick == true) == st.quick.on then return nil end
        v.quick = e.quick == true
    elseif e.reasoning == "off" then
        local r = st.reasoning
        if r.pinned or r.mode ~= "on" or not r.can_disable then return nil end
        v.reasoning = "off"
    elseif e.web ~= nil then
        local w = st.web
        if w.pinned or not w.capable or (e.web == true) == w.on then return nil end
        v.web = e.web == true
    else
        return nil
    end
    return { label = labelFor(v, st), variant = v }
end

--- The run buttons for an action, in list order; at most MODEL_SPOTS model
--- buttons, each model once (a recent pick can be the Fast model).
function RunOptions.buttons(list, action, st)
    local out, seen, models = {}, {}, 0
    local model_only = RunOptions.isModelOnly(action)
    for _idx, e in ipairs(list or {}) do
        local b = RunOptions.button(e, model_only, st)
        if b and b.variant.provider then
            local key = b.variant.provider .. "/" .. b.variant.model
            if seen[key] or models >= RunOptions.MODEL_SPOTS then
                b = nil
            else
                seen[key] = true
                models = models + 1
            end
        end
        if b then out[#out + 1] = b end
    end
    return out
end

--- Live state for an action's hold menu: what the action would run on without
--- a run option, mirroring the request bake (pin > Quick preset model > tier
--- hint > global), and the Quick / reasoning / web state for that run.
--- @param plugin table AskGPT instance
--- @param action table
--- @param opts table { surface, book_file (file-browser row), session = { quick, web, web_touched } (input dialog chips) }
function RunOptions.stateFor(plugin, action, opts)
    opts = opts or {}
    local ModelConstraints = require("model_constraints")
    local ModelLists = require("koassistant_model_lists")
    local BookSettings = require("koassistant_book_settings")
    local features = (plugin.settings and plugin.settings:readSetting("features")) or {}
    local global_provider = plugin:getCurrentProvider()
    local global_model = plugin:getCurrentModel()

    local ds
    if opts.book_file then
        ds = require("koassistant_doc_settings").resolve(opts.book_file, plugin.ui)
    elseif plugin._openBookDS then
        ds = plugin:_openBookDS()
    end
    local session = opts.session or {}

    local model_only = RunOptions.isModelOnly(action)
    local receptive = not model_only and action.accept_quick_answer == true
    local quick_on
    if session.quick ~= nil then
        quick_on = receptive and session.quick == true
    else
        quick_on = receptive and BookSettings.resolveQuickAnswerDefault(ds, features)
    end

    local function withDefault(provider, model)
        return { provider = provider, model = model
            or ModelConstraints.dispatchModel({ provider = provider, features = features }) }
    end
    local base
    if action.provider then
        local m = action.model
        if not m and action.model_tier and features.use_action_tiers ~= false then
            m = ModelLists.resolveTierModel(action.provider, action.model_tier)
        end
        base = withDefault(action.provider, m)
    else
        local preset = quick_on
            and require("koassistant_dialogs").resolveQuickPresetModel(features, global_provider)
        if preset and preset.provider then
            base = withDefault(preset.provider, preset.model)
        elseif action.model_tier and features.use_action_tiers ~= false then
            local p, m = ModelLists.resolveTierTarget(global_provider, action.model_tier)
            if m then base = { provider = p, model = m } end
        end
        base = base or { provider = global_provider, model = global_model }
    end

    local action_reasoning = ModelConstraints.parseActionReasoning(action, base.provider)
    local ReasoningPrefs = require("reasoning_prefs")
    local decision = ModelConstraints.resolveReasoning(base.provider, base.model, {
        global_stance = ReasoningPrefs.getStance(features),
        model_pref = ReasoningPrefs.getModelPref(features, base.provider, base.model),
        action_override = action_reasoning,
        session_override = (quick_on and features.quick_preset_reasoning_off ~= false)
            and { force = "off" } or nil,
    })
    local prof = decision.profile or {}
    local controllable = decision.axis ~= "none"

    local web_on
    if session.web ~= nil then
        web_on = session.web == true
    else
        -- Book entries follow the book's override; highlight and dictionary
        -- requests carry no book identity to the bake, so they follow the global
        local book_scoped = opts.surface == "quick_actions" or opts.surface == "file_browser"
        web_on = BookSettings.resolveWebSearch(book_scoped and ds or nil, features, base.provider)
    end
    -- The Quick preset strips web, unless the dialog's Web chip was touched
    -- while Quick was on (pin-beats-preset)
    if quick_on and not session.web_touched
            and require("koassistant_dialogs").quickPresetForces("web", true, features, action) then
        web_on = false
    end

    -- Key filter, as in every quick picker: disarmed while no real key exists
    local filter_on = plugin.hasAnyRealApiKey and plugin:hasAnyRealApiKey()
    return {
        base = base,
        tier_base = action.provider or global_provider,
        quick = { receptive = receptive, on = quick_on == true },
        reasoning = {
            pinned = action_reasoning ~= nil,
            mode = decision.mode,
            can_disable = controllable and prof.can_disable == true,
        },
        web = {
            pinned = action.enable_web_search ~= nil,
            on = web_on == true,
            capable = ModelConstraints.supportsWebSearch(base.provider, base.model),
        },
        configured = function(p)
            if not filter_on then return true end
            return plugin:isProviderConfigured(p)
        end,
        resolveTier = ModelLists.resolveTierTarget,
        emoji = features.enable_emoji_icons == true,
    }
end

-- ---------------------------------------------------------------------------
-- Dispatch-scoped model writes (the stash). The per-chat model state of the
-- source config is dropped too: a new dispatch starts a new chat.
-- ---------------------------------------------------------------------------

--- Undo the previous dispatch's model writes and open this dispatch's stash.
--- Call once per predefined dispatch, right after createTempConfig (which
--- copied the source config and applied the action's provider pin; the caller
--- re-applies the pin after this).
function RunOptions.beginDispatch(temp_config, source_config, action)
    local tf = temp_config and temp_config.features
    if type(tf) ~= "table" then return end
    local src = source_config or {}
    temp_config.provider = src.provider
    temp_config.model = src.model
    if action and action.provider and type(temp_config.provider_settings) == "table" then
        temp_config.provider_settings[action.provider] =
            src.provider_settings and src.provider_settings[action.provider]
    end
    local st = tf._model_stash
    if type(st) == "table" and type(st.orig) == "table" then
        temp_config.provider = st.orig.provider or nil
        temp_config.model = st.orig.model or nil
        for prov, val in pairs(st.ps or {}) do
            temp_config.provider_settings = temp_config.provider_settings or {}
            -- Clone: the per-provider tables are shared with the source config
            local ps = {}
            for k, v in pairs(temp_config.provider_settings[prov] or {}) do ps[k] = v end
            ps.model = val or nil
            temp_config.provider_settings[prov] = ps
        end
    end
    tf._model_stash = {
        orig = { provider = temp_config.provider or false, model = temp_config.model or false },
        ps = {},
    }
    -- The previous chat's reply baseline and run-option records
    tf._quick_reply_orig = nil
    tf._run_model = nil
    tf._run_reasoning = nil
end

--- Record a per-provider model slot before this dispatch overwrites it.
function RunOptions.stashBucket(config, provider)
    local st = config and config.features and config.features._model_stash
    if type(st) ~= "table" or not provider then return end
    st.ps = st.ps or {}
    if st.ps[provider] == nil then
        local b = config.provider_settings and config.provider_settings[provider]
        st.ps[provider] = (b and b.model) or false
    end
end

return RunOptions
