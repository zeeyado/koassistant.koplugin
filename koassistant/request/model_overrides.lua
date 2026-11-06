-- Model Overrides — the non-curated layers of capability resolution (agenda item 19).
--
-- Two data layers, both lazy-loaded on first use:
--   USER    <plugin_dir>/custom_models.lua — hand-written grants/denies, reasoning
--           profiles, param constraints, output caps, tier placements (see
--           custom_models.lua.sample). Highest precedence at every
--           koassistant/request/model_constraints.lua chokepoint and in ModelLists.getModelForTier.
--   DERIVED <settings_dir>/koassistant_model_caps.lua — machine-owned cache of
--           provider-reported metadata (today: OpenRouter supported_parameters,
--           fetched per-model in main.lua). Consulted AFTER the curated lists.
--
-- This module is pure-loadable: no top-level KOReader requires (unit tests run it
-- under plain lua). File IO happens inside pcall on first access; when the KOReader
-- environment is absent everything degrades to "no data".
--
-- prefixMatch is duplicated from koassistant/request/model_constraints.lua (4 lines) so the require
-- direction stays one-way: model_constraints → here, never back.

local ModelOverrides = {}

-- Test seams: inject layers directly (also skips file loading).
ModelOverrides._user = nil     -- parsed custom_models.lua content
ModelOverrides._derived = nil  -- parsed koassistant_model_caps.lua content

-- GUI tier placements (tier GUI, docs/tier_gui_plan.md): the contents of
-- features.tier_overrides, pushed by main.lua's updateConfigFromSettings on
-- every request path — this module stays pure-loadable and never reads
-- settings itself. Precedence inside tierOverride: GUI > custom_models.lua.
ModelOverrides._gui_tiers = nil

function ModelOverrides.setGuiTiers(tbl)
    ModelOverrides._gui_tiers = type(tbl) == "table" and tbl or nil
end

-- Global tier pins (tier GUI phase 2): features.global_tier_models — tier →
-- {provider, model}. A usable pin re-points a tier-invoking request at that
-- provider+model regardless of the active provider; same push contract as
-- _gui_tiers. The key checker is a main.lua closure (isProviderConfigured, so
-- GUI-entered keys count); nil checker (tests / not yet pushed) treats pins as
-- usable. Consulted per walk step by ModelLists.resolveTierTarget.
ModelOverrides._global_tier_pins = nil
ModelOverrides._key_checker = nil

function ModelOverrides.setGlobalTierPins(tbl)
    ModelOverrides._global_tier_pins = type(tbl) == "table" and tbl or nil
end

function ModelOverrides.setKeyChecker(fn)
    ModelOverrides._key_checker = type(fn) == "function" and fn or nil
end

--- Usable global pin for a tier: shape-checked, then key-checked. A pin whose
--- provider has no usable key is invisible (the ladder applies) — a tier hint
--- must never fail a request over a revoked key.
--- @return string|nil provider, string|nil model
function ModelOverrides.globalTierPin(tier)
    local pins = ModelOverrides._global_tier_pins
    local p = type(pins) == "table" and pins[tier] or nil
    if type(p) ~= "table" then return nil end
    if type(p.provider) ~= "string" or p.provider == "" then return nil end
    if type(p.model) ~= "string" or p.model == "" then return nil end
    if ModelOverrides._key_checker and not ModelOverrides._key_checker(p.provider) then
        return nil
    end
    return p.provider, p.model
end

local function prefixMatch(model, pattern)
    if not model or not pattern then return false end
    -- every pattern character escaped: a "." in "gpt-5.6" used to match any character (B478)
    return model == pattern or model:match("^" .. pattern:gsub("[%^%$%(%)%%%.%[%]%*%+%-%?]", "%%%0")) ~= nil
end

local function pluginDir()
    return require("koassistant.core.paths").ROOT
end

local function settingsCapsPath()
    local ok, DataStorage = pcall(require, "datastorage")
    if not ok then return nil end
    return DataStorage:getSettingsDir() .. "/koassistant_model_caps.lua"
end

local function loadLuaFile(path)
    if not path then return nil end
    local f = io.open(path, "r")
    if not f then return nil end
    f:close()
    local ok, data = pcall(dofile, path)
    if ok and type(data) == "table" then return data end
    return nil
end

local function ensureUser()
    if ModelOverrides._user == nil then
        ModelOverrides._user = loadLuaFile(pluginDir() .. "custom_models.lua") or false
    end
    return ModelOverrides._user or nil
end

local function ensureDerived()
    if ModelOverrides._derived == nil then
        ModelOverrides._derived = loadLuaFile(settingsCapsPath()) or false
    end
    return ModelOverrides._derived or nil
end

--- User capability grant/deny for a provider/model. Longest matching prefix wins;
--- "" matches every model of the provider (lowest priority).
--- @return boolean|nil true=grant, false=deny, nil=no opinion
function ModelOverrides.capabilityOverride(provider, model, capability)
    local user = ensureUser()
    local map = user and user.capabilities and user.capabilities[provider]
    map = map and map[capability]
    if type(map) ~= "table" then return nil end
    local best, best_len
    for prefix, granted in pairs(map) do
        if type(prefix) == "string" and prefixMatch(model, prefix) then
            if not best_len or #prefix > best_len then
                best, best_len = granted, #prefix
            end
        end
    end
    if best == nil then return nil end
    return best and true or false
end

--- custom_models.lua tier placement only (item 18b) — the layer BELOW the GUI.
--- Exposed separately because the tier GUI's "Default (X)" row needs the
--- resolution a cleared override falls back to.
--- @return string|nil model id, nil = no opinion
function ModelOverrides.userTierOverride(provider, tier)
    local user = ensureUser()
    local map = user and user.tiers and user.tiers[provider]
    local model = type(map) == "table" and map[tier] or nil
    if type(model) == "string" and model ~= "" then return model end
    return nil
end

--- User tier placement: GUI (features.tier_overrides) first, then
--- custom_models.lua (item 18b). Exact keys, no prefix matching — a tier names
--- one concrete model. This is also how custom providers (id "custom_<slug>")
--- get tiers at all.
--- @return string|nil model id, nil = no opinion (curated _tiers applies)
function ModelOverrides.tierOverride(provider, tier)
    local gmap = ModelOverrides._gui_tiers and ModelOverrides._gui_tiers[provider]
    local gmodel = type(gmap) == "table" and gmap[tier] or nil
    if type(gmodel) == "string" and gmodel ~= "" then return gmodel end
    return ModelOverrides.userTierOverride(provider, tier)
end

--- First user reasoning profile matching the model (array order = user's order).
--- @return table|nil profile (builtin shape, optionally + `wire` for custom providers)
function ModelOverrides.findProfile(provider, model)
    local user = ensureUser()
    local list = user and user.reasoning_profiles and user.reasoning_profiles[provider]
    if type(list) ~= "table" then return nil end
    for _idx, p in ipairs(list) do
        if type(p) == "table" and p.match and prefixMatch(model, p.match) then
            return p
        end
    end
    return nil
end

--- User param constraints for a provider/model (like ModelConstraints[provider]
--- entries: { temperature = 1.0, ... }). Longest matching prefix wins.
--- @return table|nil
function ModelOverrides.constraintsFor(provider, model)
    local user = ensureUser()
    local map = user and user.constraints and user.constraints[provider]
    if type(map) ~= "table" then return nil end
    local best, best_len
    for prefix, values in pairs(map) do
        if type(prefix) == "string" and type(values) == "table"
                and prefixMatch(model, prefix) then
            if not best_len or #prefix > best_len then
                best, best_len = values, #prefix
            end
        end
    end
    return best
end

--- User output-token ceiling for a provider/model. Longest matching prefix wins.
--- @return number|nil
function ModelOverrides.maxOutputTokens(provider, model)
    local user = ensureUser()
    local map = user and user.max_output_tokens and user.max_output_tokens[provider]
    if type(map) ~= "table" then return nil end
    local best, best_len
    for prefix, cap in pairs(map) do
        if type(prefix) == "string" and type(cap) == "number"
                and prefixMatch(model, prefix) then
            if not best_len or #prefix > best_len then
                best, best_len = cap, #prefix
            end
        end
    end
    return best
end

--- Derived (provider-reported) support for a wire parameter, e.g. "tools",
--- "reasoning". Exact model id only — derived data is never prefix-matched.
--- @return boolean|nil true/false when metadata exists for the model, nil when not
function ModelOverrides.derivedParam(provider, model, param)
    local derived = ensureDerived()
    local entry = derived and derived[provider] and derived[provider][model]
    -- an entry written by the max_tokens self-heal alone (fetched = 0) holds
    -- no opinion on the wire params: its empty params read as "none
    -- supported" and took the catch-all profile away (the sweep of
    -- 2026-11-06; files already written heal the same way)
    if not entry or (entry.fetched or 0) == 0 or type(entry.params) ~= "table" then return nil end
    return entry.params[param] == true
end

--- Learned/derived max-output ceiling for a model, or nil. Written by the
--- max_tokens self-heal (a provider 400 stating its real limit) — empirical
--- ground truth, consulted between the user layer and the curated table.
--- Exact model id only — derived data is never prefix-matched.
--- @return number|nil
function ModelOverrides.derivedMaxOutput(provider, model)
    local derived = ensureDerived()
    local entry = derived and derived[provider] and derived[provider][model]
    local n = entry and entry.max_output
    return type(n) == "number" and n or nil
end

-- Flat serializer for the derived cache (shape: provider -> model ->
-- {fetched, params, max_output}). ⚠ Manual field-by-field, same convention as
-- ActionCache: a new entry field must ALSO be written here or it silently
-- vanishes on the next load.
local function serializeDerived(data)
    local out = { "-- Auto-generated by KOAssistant (provider model metadata cache).",
                  "-- Safe to delete; re-fetched via the custom-models menu (learned",
                  "-- output ceilings are re-learned on the next max_tokens rejection).",
                  "return {", string.format("    version = %d,", data.version or 1) }
    for provider, models in pairs(data) do
        if type(models) == "table" and provider ~= "version" then
            out[#out + 1] = string.format("    [%q] = {", provider)
            for model, entry in pairs(models) do
                local params = {}
                for p, v in pairs(entry.params or {}) do
                    if v == true then params[#params + 1] = string.format("[%q]=true", p) end
                end
                table.sort(params)
                local max_output = type(entry.max_output) == "number"
                    and string.format(" max_output = %d,", entry.max_output) or ""
                out[#out + 1] = string.format("        [%q] = { fetched = %d,%s params = { %s } },",
                    model, entry.fetched or 0, max_output, table.concat(params, ", "))
            end
            out[#out + 1] = "    },"
        end
    end
    out[#out + 1] = "}"
    return table.concat(out, "\n")
end

local function persistDerived(derived)
    ModelOverrides._derived = derived
    local path = settingsCapsPath()
    if not path then return false end
    local f = io.open(path, "w")
    if not f then return false end
    f:write(serializeDerived(derived))
    f:close()
    return true
end

--- Record fetched metadata for a model and persist the cache. MERGES into an
--- existing entry: a params refetch must not drop a learned max_output.
--- @param provider string e.g. "openrouter"
--- @param model string exact model id
--- @param params table set-table of supported wire params ({ tools = true, ... })
--- @return boolean persisted
function ModelOverrides.recordDerived(provider, model, params)
    local derived = ensureDerived() or { version = 1 }
    derived[provider] = derived[provider] or {}
    local prev = derived[provider][model]
    derived[provider][model] = {
        fetched = os.time(),
        params = params or {},
        max_output = prev and prev.max_output or nil,
    }
    return persistDerived(derived)
end

--- Record a max-output ceiling learned from a provider rejection, preserving
--- any fetched params. @return boolean persisted
function ModelOverrides.recordDerivedMaxOutput(provider, model, max_output)
    if type(max_output) ~= "number" then return false end
    local derived = ensureDerived() or { version = 1 }
    derived[provider] = derived[provider] or {}
    local entry = derived[provider][model] or { fetched = 0, params = {} }
    entry.max_output = max_output
    derived[provider][model] = entry
    return persistDerived(derived)
end

--- Test seams / reload hooks. nil re-arms lazy file loading; false = "loaded,
--- nothing there" (same sentinel the lazy loader stores for a missing file).
function ModelOverrides._setUserForTests(tbl)
    ModelOverrides._user = tbl
end
function ModelOverrides._setDerivedForTests(tbl)
    ModelOverrides._derived = tbl
end

return ModelOverrides
