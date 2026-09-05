-- Unit tests for the tier system (items 18a-d + 19d, 2026-07-28):
-- canonical 5-tier ladder (frontier/flagship/standard/fast/ultrafast), retired
-- "reasoning" tier read-through, descend-only fallback, and custom_models.lua
-- tier placements via the ModelOverrides seam.
--
-- The array-membership invariant exists because of a real bug: Requesty's
-- standard/fast/ultrafast tiers pointed at google/gemini-3.5-flash, an id that
-- does not exist in the Requesty catalog (and was never in our curated array).
--
-- Run: lua tests/run_tests.lua --unit

-- Setup paths
local function setupPaths()
    local info = debug.getinfo(1, "S")
    local script_path = info.source:match("@?(.*)")
    local unit_dir = script_path:match("(.+)/[^/]+$") or "."
    local tests_dir = unit_dir:match("(.+)/[^/]+$") or "."
    local plugin_dir = tests_dir:match("(.+)/[^/]+$") or "."

    package.path = table.concat({
        plugin_dir .. "/?.lua",
        plugin_dir .. "/koassistant_api/?.lua",
        tests_dir .. "/?.lua",
        tests_dir .. "/lib/?.lua",
        package.path,
    }, ";")

    return plugin_dir, tests_dir
end

setupPaths()

-- Load mocks BEFORE any plugin modules
require("mock_koreader")

-- Test framework
local TestRunner = {
    passed = 0,
    failed = 0,
}

function TestRunner.assert(condition, message)
    if condition then
        TestRunner.passed = TestRunner.passed + 1
    else
        TestRunner.failed = TestRunner.failed + 1
        print("  FAIL: " .. (message or "assertion failed"))
    end
end

local ModelLists = require("koassistant_model_lists")
local ModelOverrides = require("koassistant_model_overrides")

-- Hermeticity: a developer's local custom_models.lua must not leak in
-- (mock_koreader already does this; explicit here because these tests depend on it)
ModelOverrides._setUserForTests(false)

local CANONICAL = { frontier = true, flagship = true, standard = true, fast = true, ultrafast = true }

print("== tier table shape ==")

-- Only canonical tier names exist
for tier_name in pairs(ModelLists._tiers) do
    TestRunner.assert(CANONICAL[tier_name],
        "unexpected tier name in _tiers: " .. tostring(tier_name))
end
TestRunner.assert(ModelLists._tiers.reasoning == nil, "reasoning tier retired")
TestRunner.assert(ModelLists._tiers.frontier ~= nil, "frontier tier exists")

-- _tier_info matches the tier set
for tier_name in pairs(CANONICAL) do
    TestRunner.assert(ModelLists._tier_info[tier_name] ~= nil,
        "_tier_info missing entry for " .. tier_name)
end
TestRunner.assert(ModelLists._tier_info.reasoning == nil, "_tier_info reasoning entry removed")

print("== every tier id exists in its provider's model array ==")

local function inArray(provider, model_id)
    local arr = ModelLists[provider]
    if type(arr) ~= "table" then return false end
    for _idx, id in ipairs(arr) do
        if id == model_id then return true end
    end
    return false
end

for tier_name, tier_map in pairs(ModelLists._tiers) do
    for provider, model_id in pairs(tier_map) do
        TestRunner.assert(inArray(provider, model_id),
            string.format("_tiers.%s.%s = %q is not in the %s array",
                tier_name, provider, model_id, provider))
    end
end

-- Non-frontier ladder stays complete for every CURATED provider (frontier is
-- sparse by design; everything else should resolve without fallback).
-- COMMUNITY-set providers (ModelLists._community — docs-based, no maintainer
-- key; REVISION 2) have NO tier placements by design: tier features no-op for
-- them until the keys pipeline promotes them. Their ids, when someone does add
-- a placement, are still validated by the array-membership loop above.
-- META ROUTERS are exempt the other way (maintainer ruling 2026-08-17): a
-- router's curated ladder would hop sub-vendors on a tier hint, so openrouter
-- (curated) and requesty (community) carry NO curated placements — asserted
-- absent below; users add router tiers via the GUI/custom_models override layer.
local META_ROUTERS = { openrouter = true, requesty = true, opencode = true, opencode_go = true }  -- opencode Zen/Go: curated 2026-09-05, meta routers
for _idx, tier_name in ipairs({ "flagship", "standard", "fast", "ultrafast" }) do
    for _pidx, provider in ipairs(ModelLists.getAllProviders()) do
        if not ModelLists.isCommunity(provider) and not META_ROUTERS[provider] then
            TestRunner.assert(ModelLists._tiers[tier_name][provider] ~= nil,
                string.format("curated provider %s missing from tier %s", provider, tier_name))
        end
    end
end
for router in pairs(META_ROUTERS) do
    for tier_name, tier_map in pairs(ModelLists._tiers) do
        TestRunner.assert(tier_map[router] == nil,
            string.format("meta router %s must have no curated %s placement (2026-08-17 ruling)",
                router, tier_name))
    end
end

-- The relabeling is honest but must not LOSE placements that already exist:
-- pre-2026-08 community members keep their curated tier rows until promotion.
-- (fireworks + cohere promoted OUT 2026-08-15: keyed, catalog-validated,
-- probed — they now assert NOT-community while keeping their tier rows.
-- requesty left this list 2026-08-17: meta router, placements removed.)
for _idx, legacy in ipairs({ "groq", "together", "sambanova", "doubao" }) do
    TestRunner.assert(ModelLists.isCommunity(legacy),
        legacy .. " is in the community set (never maintainer-tested)")
    TestRunner.assert(ModelLists._tiers.standard[legacy] ~= nil,
        legacy .. " keeps its existing tier placements despite community relabel")
end
for _idx, promoted in ipairs({ "fireworks", "cohere", "qwen", "kimi" }) do
    TestRunner.assert(not ModelLists.isCommunity(promoted),
        promoted .. " was promoted out of the community set (2026-08-15 keys session)")
    TestRunner.assert(ModelLists._tiers.standard[promoted] ~= nil,
        promoted .. " keeps its tier placements after promotion")
end

print("== normalizeTier ==")

TestRunner.assert(ModelLists.normalizeTier("reasoning") == "flagship",
    "legacy reasoning pick reads through to flagship")
TestRunner.assert(ModelLists.normalizeTier("frontier") == "frontier", "frontier passes through")
TestRunner.assert(ModelLists.normalizeTier("ultrafast") == "ultrafast", "ultrafast passes through")
TestRunner.assert(ModelLists.normalizeTier("bogus") == "standard", "unknown tier -> standard")
TestRunner.assert(ModelLists.normalizeTier(nil) == "standard", "nil tier -> standard")

print("== getModelForTier ==")

-- Direct hits
TestRunner.assert(ModelLists.getModelForTier("anthropic", "frontier", false) == "claude-fable-5",
    "anthropic frontier = claude-fable-5")
TestRunner.assert(ModelLists.getModelForTier("anthropic", "flagship", false) == "claude-opus-5",
    "anthropic flagship = claude-opus-5")

-- Legacy "reasoning" request resolves to the flagship entry, never frontier
TestRunner.assert(ModelLists.getModelForTier("anthropic", "reasoning", true) == "claude-opus-5",
    "reasoning alias resolves to flagship model")

-- Fallback only DESCENDS: providers without frontier fall to flagship...
TestRunner.assert(ModelLists.getModelForTier("openai", "frontier", true) == "gpt-5.6-sol",
    "openai frontier request falls back to flagship")
-- ...and without fallback a sparse tier returns nil
TestRunner.assert(ModelLists.getModelForTier("openai", "frontier", false) == nil,
    "openai has no frontier entry")
-- A flagship request never climbs into frontier
TestRunner.assert(ModelLists.getModelForTier("anthropic", "flagship", true) ~= "claude-fable-5",
    "flagship request must not climb to frontier")

-- Unknown provider (e.g. custom without overrides) resolves to nothing
TestRunner.assert(ModelLists.getModelForTier("custom_nope", "fast", true) == nil,
    "custom provider without overrides has no tiers")

print("== custom_models.lua tier placements (item 18b) ==")

ModelOverrides._setUserForTests({
    tiers = {
        custom_lm_studio = { fast = "qwen3-4b-instruct" },
        anthropic = { ultrafast = "claude-haiku-x" },
    },
})

TestRunner.assert(ModelLists.getModelForTier("custom_lm_studio", "fast", false) == "qwen3-4b-instruct",
    "custom provider gets a user-defined tier")
TestRunner.assert(ModelLists.getModelForTier("custom_lm_studio", "standard", true) == "qwen3-4b-instruct",
    "fallback walk consults user tiers per step (standard descends to user fast)")
-- Descend-only: an ultrafast request never climbs back up to fast
TestRunner.assert(ModelLists.getModelForTier("custom_lm_studio", "ultrafast", true) == nil,
    "ultrafast is the floor — no upward fallback")
TestRunner.assert(ModelLists.getModelForTier("anthropic", "ultrafast", false) == "claude-haiku-x",
    "user tier overrides curated entry")
TestRunner.assert(ModelLists.getModelForTier("anthropic", "flagship", false) == "claude-opus-5",
    "unrelated curated tiers unaffected by user override")
TestRunner.assert(ModelOverrides.tierOverride("anthropic", "flagship") == nil,
    "tierOverride returns nil where the user has no opinion")

-- Reset the seam so later tests in the same interpreter see no user layer
ModelOverrides._setUserForTests(false)

print("== resolveTierModel (item 18e per-action tier hints + ⚡ fastest walk) ==")

-- "fastest" walks ultrafast toward slower, never frontier
local fastest = ModelLists.resolveTierModel("anthropic", "fastest")
TestRunner.assert(fastest ~= nil, "fastest resolves for a curated provider")
TestRunner.assert(fastest == ModelLists.getModelForTier("anthropic", "ultrafast", false)
    or fastest == ModelLists.getModelForTier("anthropic", "fast", false),
    "fastest picks the quickest listed tier")
TestRunner.assert(fastest ~= "claude-fable-5", "fastest never lands on frontier")

-- Named tiers are EXACT (2026-08-14): a tier is a class pick, not a direction —
-- a miss returns nil (caller keeps the current/default model); only "fastest"
-- walks the ladder
TestRunner.assert(ModelLists.resolveTierModel("anthropic", "fast")
    == ModelLists.getModelForTier("anthropic", "fast", false),
    "named tier matches getModelForTier WITHOUT fallback")

-- No placements → nil (caller keeps the current model)
TestRunner.assert(ModelLists.resolveTierModel("custom_nope", "fastest") == nil,
    "fastest on a provider without tiers returns nil")
TestRunner.assert(ModelLists.resolveTierModel("custom_nope", "fast") == nil,
    "named tier on a provider without tiers returns nil")

-- Strict tier names: garbage and sentinels must NOT normalize into a model switch
TestRunner.assert(ModelLists.resolveTierModel("anthropic", "none") == nil,
    "'none' sentinel resolves to nothing (not normalized to standard)")
TestRunner.assert(ModelLists.resolveTierModel("anthropic", "fastst") == nil,
    "typo'd tier resolves to nothing")
TestRunner.assert(ModelLists.resolveTierModel(nil, "fast") == nil
    and ModelLists.resolveTierModel("anthropic", nil) == nil,
    "nil provider/tier resolve to nothing")

-- User tier placements feed the fastest walk (custom providers work)
ModelOverrides._setUserForTests({
    tiers = {
        custom_lm_studio = { fast = "qwen3-4b-instruct" },
        -- Discriminating never-frontier case: a provider whose ONLY placement is
        -- frontier. The fastest walk must come up empty — if anyone ever appends
        -- "frontier" to the walk list, THIS assertion fails (the anthropic check
        -- above short-circuits at ultrafast and would not).
        custom_only_frontier = { frontier = "giant-model" },
    },
})
TestRunner.assert(ModelLists.resolveTierModel("custom_lm_studio", "fastest") == "qwen3-4b-instruct",
    "fastest walk consults user tier placements on custom providers")
TestRunner.assert(ModelLists.resolveTierModel("custom_only_frontier", "fastest") == nil,
    "fastest walk NEVER consults frontier (frontier-only provider resolves to nothing)")
-- Exact named tiers (2026-08-14): standard missing + fast present must NOT
-- resolve — the miss means "no override", never a silent class substitution
TestRunner.assert(ModelLists.resolveTierModel("custom_lm_studio", "standard") == nil,
    "named tier miss returns nil even when a faster placement exists")
local sp, sm = ModelLists.resolveTierTarget("custom_lm_studio", "standard")
TestRunner.assert(sp == nil and sm == nil,
    "resolveTierTarget named miss is exact too (no down-ladder walk)")
ModelOverrides._setUserForTests(false)

print("== GUI tier placements (tier GUI, features.tier_overrides) ==")

-- GUI layer beats curated
ModelOverrides.setGuiTiers({ anthropic = { ultrafast = "claude-haiku-gui" } })
TestRunner.assert(ModelLists.getModelForTier("anthropic", "ultrafast", false) == "claude-haiku-gui",
    "GUI placement overrides curated entry")
TestRunner.assert(ModelLists.getModelForTier("anthropic", "flagship", false) == "claude-opus-5",
    "unrelated tiers unaffected by GUI placement")

-- GUI layer beats the custom_models.lua file layer on the same slot
ModelOverrides._setUserForTests({
    tiers = { anthropic = { ultrafast = "claude-haiku-file" } },
})
TestRunner.assert(ModelOverrides.tierOverride("anthropic", "ultrafast") == "claude-haiku-gui",
    "GUI beats custom_models.lua on the same slot")
TestRunner.assert(ModelOverrides.userTierOverride("anthropic", "ultrafast") == "claude-haiku-file",
    "userTierOverride reads the file layer only (Default-row resolution)")

-- Invalid GUI values fall through to the file layer
ModelOverrides.setGuiTiers({ anthropic = { ultrafast = "" }, openai = "not-a-table" })
TestRunner.assert(ModelOverrides.tierOverride("anthropic", "ultrafast") == "claude-haiku-file",
    "empty-string GUI value falls through to the file layer")
TestRunner.assert(ModelLists.getModelForTier("openai", "fast", false) == "gpt-5.6-luna",
    "non-table GUI provider entry is ignored (curated applies)")
ModelOverrides._setUserForTests(false)

-- Clearing re-exposes curated
ModelOverrides.setGuiTiers(nil)
TestRunner.assert(ModelLists.getModelForTier("anthropic", "ultrafast", false) == "claude-haiku-4-5-20251001",
    "setGuiTiers(nil) clears the GUI layer")

-- Custom provider with only a GUI placement: tier hints + fastest walk work
ModelOverrides.setGuiTiers({ custom_lm_studio = { fast = "qwen3-4b-gui" } })
TestRunner.assert(ModelLists.getModelForTier("custom_lm_studio", "fast", false) == "qwen3-4b-gui",
    "custom provider gets a GUI-defined tier")
TestRunner.assert(ModelLists.resolveTierModel("custom_lm_studio", "fastest") == "qwen3-4b-gui",
    "fastest walk consults GUI placements on custom providers")

-- getTierForModel honors overrides and walks TIER_ORDER deterministically
ModelOverrides.setGuiTiers({ anthropic = { ultrafast = "claude-haiku-gui" } })
TestRunner.assert(ModelLists.getTierForModel("anthropic", "claude-haiku-gui") == "ultrafast",
    "getTierForModel labels a GUI-placed model with its tier")
TestRunner.assert(ModelLists.getTierForModel("anthropic", "claude-haiku-4-5-20251001") == "fast",
    "model in two tiers labels as the higher one (TIER_ORDER walk)")
ModelOverrides.setGuiTiers(nil)

print("== global tier pins (resolveTierTarget, tier GUI phase 2) ==")

-- No pins: provider passthrough, same model as the ladder resolver
local p, m = ModelLists.resolveTierTarget("anthropic", "fast")
TestRunner.assert(p == "anthropic" and m == ModelLists.getModelForTier("anthropic", "fast", false),
    "no pins: resolveTierTarget == same-provider EXACT ladder resolution")

-- A pin re-points the tier anywhere (provider + model)
ModelOverrides.setGlobalTierPins({ fast = { provider = "groq", model = "llama-3.1-8b-instant" } })
p, m = ModelLists.resolveTierTarget("anthropic", "fast")
TestRunner.assert(p == "groq" and m == "llama-3.1-8b-instant",
    "fast pin wins over the active provider's ladder")
p, m = ModelLists.resolveTierTarget("anthropic", "flagship")
TestRunner.assert(p == "anthropic",
    "unpinned tier stays on the active provider")

-- Walk order: each STEP consults pin then ladder — an ultrafast LADDER hit
-- beats a fast PIN in the fastest walk (ultrafast step resolves first)
p, m = ModelLists.resolveTierTarget("anthropic", "fastest")
TestRunner.assert(p == "anthropic" and m == "claude-haiku-4-5-20251001",
    "fastest: anthropic's own ultrafast beats a later-step fast pin")
ModelOverrides.setGlobalTierPins({ ultrafast = { provider = "groq", model = "llama-3.1-8b-instant" } })
p, m = ModelLists.resolveTierTarget("anthropic", "fastest")
TestRunner.assert(p == "groq",
    "fastest: an ultrafast pin wins the first step")

-- Key checker gates pins (revoked key → pin invisible, ladder applies)
ModelOverrides.setKeyChecker(function(pid) return pid ~= "groq" end)
p, m = ModelLists.resolveTierTarget("anthropic", "fastest")
TestRunner.assert(p == "anthropic" and m == "claude-haiku-4-5-20251001",
    "unusable pin is invisible — ladder fallback")
ModelOverrides.setKeyChecker(nil)

-- Exact named tiers (2026-08-14): a fast request never descends to an
-- ultrafast pin — the miss means "no override", even on a ladder-less provider
p, m = ModelLists.resolveTierTarget("custom_nope", "fast")
TestRunner.assert(p == nil and m == nil,
    "named tier miss does NOT reach a faster-step pin (exact, no descend)")

-- Frontier pin: never consulted by fastest, honored on explicit request
ModelOverrides.setGlobalTierPins({ frontier = { provider = "anthropic", model = "claude-fable-5" } })
p, m = ModelLists.resolveTierTarget("anthropic", "fastest")
TestRunner.assert(m ~= "claude-fable-5",
    "fastest never consults a frontier pin")
p, m = ModelLists.resolveTierTarget("openai", "frontier")
TestRunner.assert(p == "anthropic" and m == "claude-fable-5",
    "explicit frontier request honors the frontier pin")

-- Invalid pin shapes are ignored; strictness matches resolveTierModel
ModelOverrides.setGlobalTierPins({ fast = { provider = "", model = "x" }, ultrafast = "junk" })
p, m = ModelLists.resolveTierTarget("anthropic", "fast")
TestRunner.assert(p == "anthropic",
    "malformed pins are invisible")
TestRunner.assert(ModelLists.resolveTierTarget("anthropic", "none") == nil,
    "'none' sentinel resolves to nothing (strict, like resolveTierModel)")

-- The ladder-only resolvers never see pins
ModelOverrides.setGlobalTierPins({ ultrafast = { provider = "groq", model = "llama-3.1-8b-instant" } })
TestRunner.assert(ModelLists.resolveTierModel("anthropic", "fastest") == "claude-haiku-4-5-20251001",
    "resolveTierModel stays ladder-only (per-provider GUI default rows depend on it)")
TestRunner.assert(ModelLists.getModelForTier("anthropic", "ultrafast", false) == "claude-haiku-4-5-20251001",
    "getModelForTier stays ladder-only")
ModelOverrides.setGlobalTierPins(nil)

-- Summary
print(string.format("\n%d passed, %d failed", TestRunner.passed, TestRunner.failed))
return TestRunner.failed == 0
