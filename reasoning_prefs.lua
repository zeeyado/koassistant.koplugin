-- reasoning_prefs.lua
-- Storage + display layer for the per-model reasoning preference store
-- (features.reasoning_prefs). The resolution logic and per-model profiles live
-- in model_constraints.lua; this module is the thin, shared accessor/mutator used
-- by the Quick Settings popup and the Settings -> Reasoning page.
--
-- Store shape (sparse — keys exist only when the user customizes):
--   features.reasoning_prefs = {
--       stance = "minimal" | "default" | "maximum",   -- absent => "default"
--       providers = { [provider] = { state="on"|"off", effort=, budget= } },
--       models    = { ["provider/model"] = { state=, effort=, budget= } },
--   }
-- A nil field means "inherit from the layer below". We always use state="off"
-- (string), never false, so nil cleanly means inherit.
--
-- Reads are pure. Mutators mutate the passed `features` table in place; callers
-- persist via settings:saveSetting("features", f) + settings:flush(), matching
-- the existing Quick Settings callbacks.

local ModelConstraints = require("model_constraints")
local _ = require("koassistant_gettext")

local ReasoningPrefs = {}

local VALID_STANCES = { minimal = true, default = true, maximum = true }

local EFFORT_LABELS = {
    minimal = _("Minimal"),
    low = _("Low"),
    medium = _("Medium"),
    high = _("High"),
    xhigh = _("Extra High"),
    max = _("Max"),
    dynamic = _("Dynamic"),
    none = _("Off"),
}

--- Compose the per-model storage key.
--- @param provider string
--- @param model string
--- @return string
function ReasoningPrefs.modelKey(provider, model)
    return tostring(provider or "?") .. "/" .. tostring(model or "?")
end

-- Read-only view of the prefs root (never nil).
local function root(features)
    return (features and features.reasoning_prefs) or {}
end

--- @return "minimal"|"default"|"maximum"
function ReasoningPrefs.getStance(features)
    local s = root(features).stance
    if s and VALID_STANCES[s] then return s end
    return "default"
end

--- @return table|nil  { state=, effort=, budget= } or nil
function ReasoningPrefs.getProviderPref(features, provider)
    local p = root(features).providers
    return p and p[provider] or nil
end

--- @return table|nil
function ReasoningPrefs.getModelPref(features, provider, model)
    local m = root(features).models
    return m and m[ReasoningPrefs.modelKey(provider, model)] or nil
end

-- Ensure features.reasoning_prefs (and an optional sub-table) exists; return it.
local function ensure(features, subkey)
    features.reasoning_prefs = features.reasoning_prefs or {}
    local rp = features.reasoning_prefs
    if subkey then
        rp[subkey] = rp[subkey] or {}
    end
    return rp
end

--- Set the global stance. Mutates features.
function ReasoningPrefs.setStance(features, stance)
    if not VALID_STANCES[stance] then stance = "default" end
    ensure(features).stance = stance
end

--- Set (or clear, pref=nil) a per-provider preference. Mutates features.
function ReasoningPrefs.setProviderPref(features, provider, pref)
    ensure(features, "providers").providers[provider] = pref
end

function ReasoningPrefs.clearProviderPref(features, provider)
    local rp = root(features)
    if rp.providers then rp.providers[provider] = nil end
end

--- Set (or clear, pref=nil) a per-model preference. Mutates features.
function ReasoningPrefs.setModelPref(features, provider, model, pref)
    ensure(features, "models").models[ReasoningPrefs.modelKey(provider, model)] = pref
end

function ReasoningPrefs.clearModelPref(features, provider, model)
    local rp = root(features)
    if rp.models then rp.models[ReasoningPrefs.modelKey(provider, model)] = nil end
end

--- Resolve the effective decision for a provider/model from stored prefs only
--- (no per-action override). Used for the QS chip and the Settings effective view.
--- @return table decision (see ModelConstraints.resolveReasoning)
function ReasoningPrefs.resolve(features, provider, model)
    return ModelConstraints.resolveReasoning(provider, model, {
        global_stance = ReasoningPrefs.getStance(features),
        provider_pref = ReasoningPrefs.getProviderPref(features, provider),
        model_pref = ReasoningPrefs.getModelPref(features, provider, model),
    })
end

--- Human label for an effort/budget level key.
function ReasoningPrefs.effortLabel(opt)
    if not opt then return _("On") end
    return EFFORT_LABELS[opt] or (opt:sub(1, 1):upper() .. opt:sub(2))
end

--- Short label for the effective reasoning state of provider/model.
--- e.g. "Default", "Off", "High", "Dynamic", "Always on", "None".
function ReasoningPrefs.summaryLabel(features, provider, model)
    local d = ReasoningPrefs.resolve(features, provider, model)
    if d.axis == "none" then
        return (d.mode == "on") and _("Always on") or _("None")
    end
    if d.send_nothing then return _("Default") end
    if d.mode == "off" then return _("Off") end
    if d.option then return ReasoningPrefs.effortLabel(d.option) end
    return _("On")
end

return ReasoningPrefs
