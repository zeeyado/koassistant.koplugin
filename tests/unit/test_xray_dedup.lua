--[[
Unit tests: X-Ray entity dedup (koassistant_xray_dedup.lua) + never-merge
storage (koassistant_action_cache.lua reserved key) + the section-merge
prompts' never-pairs injection (koassistant_xray_merge.lua) —
xray_ecosystem_plan.md §6 slice 4.

Scan heuristics, merge application, sidecar absorb, AI-merge prompt sentinel
discipline, and a real-file round-trip of the __never_merge reserved key
through get/setUserAliases (incl. coexistence with normal alias entries).
Execution/UI are device territory.

Run: lua tests/unit/test_xray_dedup.lua  (auto-discovered by run_tests.lua --unit)
]]

local function setupPaths()
    local info = debug.getinfo(1, "S")
    local script_path = info.source:match("@?(.*)")
    local unit_dir = script_path:match("(.+)/[^/]+$") or "."
    local tests_dir = unit_dir:match("(.+)/[^/]+$") or "."
    local plugin_dir = tests_dir:match("(.+)/[^/]+$") or "."

    package.path = table.concat({
        plugin_dir .. "/?.lua",
        plugin_dir .. "/?/init.lua",
        tests_dir .. "/?.lua",
        tests_dir .. "/lib/?.lua",
        package.path,
    }, ";")
end
setupPaths()

-- ActionCache requires KOReader modules at load — mock with a real scratch
-- sidecar dir so the never-merge round-trip exercises the actual serializer.
-- run_tests.lua executes all unit files in ONE process: nil the modules that
-- captured a prior file's mocks before re-requiring (test_xray_auto pattern).
local TMP_ROOT = "/tmp/koassistant_xray_dedup_test_" .. tostring(os.time()) .. "_" .. tostring(math.random(10000))
local SIDECAR_DIR = TMP_ROOT .. "/book.sdr"
os.execute(string.format("mkdir -p %q", SIDECAR_DIR))
package.loaded["koassistant_action_cache"] = nil
package.loaded["koassistant_xray_dedup"] = nil
package.loaded["koassistant_xray_merge"] = nil
package.loaded["koassistant_gettext"] = nil
package.loaded["docsettings"] = nil
package.loaded["util"] = nil
package.loaded["luasettings"] = nil
require("mock_koreader")
_G.G_reader_settings = _G.G_reader_settings or {
    _store = {},
    readSetting = function(self, key, default)
        local v = self._store[key]
        if v == nil then return default end
        return v
    end,
    saveSetting = function(self, key, value) self._store[key] = value end,
    flush = function() end,
}
package.loaded["docsettings"] = {
    getSidecarDir = function(_self, _doc_path, _force) return SIDECAR_DIR end,
    isHashLocationEnabled = function() return false end,
}
package.loaded["util"] = {
    makePath = function(dir) os.execute(string.format("mkdir -p %q", dir)) end,
}
package.loaded["luasettings"] = {
    open = function() return { readSetting = function() return nil end, close = function() end } end,
}

local XrayDedup = require("koassistant_xray_dedup")
local XrayMerge = require("koassistant_xray_merge")
local ActionCache = require("koassistant_action_cache")
local TestRunner = require("test_runner"):new()
local DOC_PATH = TMP_ROOT .. "/book.epub"

print("Running: test_xray_dedup")
print("")
print("  [duplicate scan heuristics]")

local function fictionData()
    return {
        characters = {
            { name = "Jack Torrance", description = "the caretaker", aliases = { "the caretaker" } },
            { name = "Jack", description = "a man unraveling" },
            { name = "Danny Torrance", description = "his son", aliases = { "Doc" } },
            { name = "Tony", description = "imaginary friend", aliases = { "Doc" } },
            { name = "Wendy Torrance", description = "his wife" },
        },
        locations = {
            { name = "The Overlook Hotel", description = "a haunted hotel" },
            { name = "The Overlook", description = "the hotel" },
        },
        themes = {
            { name = "Isolation", description = "being alone" },
            { name = "Isolation", description = "duplicated theme" },
        },
        timeline = {
            { event = "Jack", description = "phrase-name category" },
            { event = "Jack Torrance", description = "must never pair" },
        },
    }
end

TestRunner:test("exact / alias / contained-name detection, same category only", function()
    local found, truncated = XrayDedup.findDuplicates(fictionData(), nil)
    TestRunner:assertEqual(truncated, false, "small scan not truncated")
    local by_key = {}
    for _idx, pair in ipairs(found) do
        by_key[pair.name_a .. "|" .. pair.name_b] = pair
    end
    local contained = by_key["Jack Torrance|Jack"]
    TestRunner:assertTrue(contained ~= nil and contained.reason == "name", "contained name (characters)")
    local alias = by_key["Danny Torrance|Tony"]
    TestRunner:assertTrue(alias ~= nil and alias.reason == "alias", "shared alias 'Doc'")
    local loc = by_key["The Overlook Hotel|The Overlook"]
    TestRunner:assertTrue(loc ~= nil and loc.reason == "name", "contained name (locations)")
    local theme = by_key["Isolation|Isolation"]
    TestRunner:assertTrue(theme ~= nil and theme.reason == "exact", "exact duplicate (themes)")
    for _idx, pair in ipairs(found) do
        TestRunner:assertTrue(pair.cat_key ~= "timeline", "phrase categories never scanned")
    end
    -- "Wendy Torrance" vs "Jack Torrance": equal token counts never pair
    TestRunner:assertTrue(by_key["Jack Torrance|Wendy Torrance"] == nil
        and by_key["Wendy Torrance|Jack Torrance"] == nil, "equal-token names not paired")
end)

TestRunner:test("CJK separators: '_' vs '・' spellings pair as exact; dotted names tokenize for contained-name", function()
    local found = XrayDedup.findDuplicates({
        characters = {
            { name = "カイ・ロ・サン", description = "a" },
            { name = "カイ_ロ_サン", description = "b" },
            { name = "カイ", description = "c" },
            { name = "ミラ・エル・ソーン", description = "d" },
        },
    }, nil)
    local by_key = {}
    for _idx, pair in ipairs(found) do by_key[pair.name_a .. "|" .. pair.name_b] = pair.reason end
    TestRunner:assertEqual(by_key["カイ・ロ・サン|カイ_ロ_サン"], "exact", "separator variants are one name")
    TestRunner:assertEqual(by_key["カイ・ロ・サン|カイ"], "name", "first part contained in the dotted full name")
    TestRunner:assertTrue(by_key["カイ・ロ・サン|ミラ・エル・ソーン"] == nil, "unrelated dotted names never pair")
    TestRunner:assertEqual(XrayDedup.pairKey("カイ_ロ_サン", "x"), XrayDedup.pairKey("カイ・ロ・サン", "x"),
        "never-merge keys are separator-insensitive")
end)

TestRunner:test("never-merge pairs suppress proposals (order/case-insensitive)", function()
    local never = { { "jack", "JACK TORRANCE" }, { "Tony", "Danny Torrance" } }
    local found = XrayDedup.findDuplicates(fictionData(), never)
    for _idx, pair in ipairs(found) do
        TestRunner:assertTrue(not (pair.name_a == "Jack Torrance" and pair.name_b == "Jack"),
            "never pair (reversed, lowercased) suppressed")
        TestRunner:assertTrue(not (pair.name_a == "Danny Torrance" and pair.name_b == "Tony"),
            "never pair suppressed")
    end
end)

TestRunner:test("unnamed items and short fragments never pair", function()
    local found = XrayDedup.findDuplicates({
        characters = {
            { description = "no name at all" },
            { description = "also unnamed" },
            { name = "J", description = "single letter" },
            { name = "J Smith", description = "initial" },
        },
    }, nil)
    TestRunner:assertEqual(#found, 0, "no proposals from unnamed/short entries")
end)

TestRunner:test("pairKey: unordered and case-insensitive", function()
    TestRunner:assertEqual(XrayDedup.pairKey("Alpha", "beta"), XrayDedup.pairKey("BETA", "alpha"),
        "same key both directions")
end)

print("")
print("  [merge application]")

TestRunner:test("applyMergeToData: drop removed, aliases baked, description kept", function()
    local data = fictionData()
    local changed, dropped = XrayDedup.applyMergeToData(data, "characters", "Jack Torrance", "Jack", nil)
    TestRunner:assertEqual(changed, true, "merge applied")
    TestRunner:assertEqual(dropped.name, "Jack", "dropped item returned")
    TestRunner:assertEqual(#data.characters, 4, "entry removed")
    local keep = data.characters[1]
    TestRunner:assertEqual(keep.description, "the caretaker", "description untouched (deterministic)")
    local has_jack = false
    for _idx, alias in ipairs(keep.aliases) do
        if alias == "Jack" then has_jack = true end
    end
    TestRunner:assertTrue(has_jack, "dropped name baked as alias")
end)

TestRunner:test("applyMergeToData: dropped entry's cross-book background moves to the kept one", function()
    local data = {
        characters = {
            { name = "Ada", description = "old",
              background = { { source = "First Book", text = "kept side" } } },
            { name = "Ada Lovelace", description = "richer",
              background = { { source = "First Book", text = "dropped side" },
                             { source = "Second Book", text = "companion note" } } },
        },
    }
    local changed = XrayDedup.applyMergeToData(data, "characters", "Ada", "Ada Lovelace", nil)
    TestRunner:assertEqual(changed, true, "merge applied")
    local bg = data.characters[1].background
    TestRunner:assertEqual(#bg, 2, "per-source dedupe across the absorb")
    TestRunner:assertEqual(bg[1].text, "dropped side", "same source: absorbed entry wins (later add)")
    TestRunner:assertEqual(bg[2].source, "Second Book", "unique source transferred")
end)

TestRunner:test("applyMergeToData: AI description replaces; alias dedup vs keep name", function()
    local data = {
        characters = {
            { name = "Ada", description = "old", aliases = { "Countess" } },
            { name = "Ada Lovelace", description = "richer", aliases = { "ada", "the Countess" } },
        },
    }
    local changed = XrayDedup.applyMergeToData(data, "characters", "Ada", "Ada Lovelace", "combined text")
    TestRunner:assertEqual(changed, true, "merge applied")
    TestRunner:assertEqual(data.characters[1].description, "combined text", "AI description written")
    local aliases = data.characters[1].aliases
    local seen = {}
    for _idx, alias in ipairs(aliases) do
        local low = alias:lower()
        TestRunner:assertTrue(not seen[low], "no duplicate aliases")
        seen[low] = true
    end
    TestRunner:assertTrue(seen["ada lovelace"], "dropped name absorbed")
    TestRunner:assertTrue(not seen["ada"], "keep's own name never becomes its alias")
end)

TestRunner:test("applyMergeToData: exact-duplicate pair resolved by position", function()
    local data = fictionData()
    local changed, dropped = XrayDedup.applyMergeToData(data, "themes", "Isolation", "Isolation", nil, 1, 2)
    TestRunner:assertEqual(changed, true, "exact-dup merge applied")
    TestRunner:assertEqual(#data.themes, 1, "second occurrence removed")
    TestRunner:assertEqual(data.themes[1].description, "being alone", "first occurrence kept")
    TestRunner:assertEqual(dropped.description, "duplicated theme", "second occurrence returned")
    -- Without positional identity an ambiguous name must REFUSE, not
    -- first-match-wins (gate finding: silent wrong-entry merges)
    local data2 = fictionData()
    local changed2 = XrayDedup.applyMergeToData(data2, "themes", "Isolation", "Isolation", nil)
    TestRunner:assertEqual(changed2, false, "ambiguous name without indices refused")
    TestRunner:assertEqual(#data2.themes, 2, "data untouched on refusal")
end)

TestRunner:test("applyMergeToData: repeated names — indices pick the entries the reader saw", function()
    local data = {
        characters = {
            { name = "Jack", description = "DESC-1" },
            { name = "Jack Torrance", description = "DESC-2" },
            { name = "Jack", description = "DESC-3" },
        },
    }
    -- The reader resolved the pair (idx 2, idx 3): keep "Jack Torrance",
    -- drop the SECOND "Jack" — the first "Jack" must be untouched
    local changed, dropped = XrayDedup.applyMergeToData(
        data, "characters", "Jack Torrance", "Jack", nil, 2, 3)
    TestRunner:assertEqual(changed, true, "positional merge applied")
    TestRunner:assertEqual(dropped.description, "DESC-3", "the entry the reader saw was dropped")
    TestRunner:assertEqual(#data.characters, 2, "one entry removed")
    TestRunner:assertEqual(data.characters[1].description, "DESC-1", "unrelated same-name entry untouched")
    -- Stale index + ambiguous name (disk changed underneath) → refuse
    local changed2 = XrayDedup.applyMergeToData(
        data, "characters", "Jack Torrance", "Jack", nil, 2, 9)
    TestRunner:assertEqual(changed2, true, "stale index, UNIQUE name → name fallback works")
end)

TestRunner:test("applyMergeToData: missing entity → no change", function()
    local data = fictionData()
    local changed = XrayDedup.applyMergeToData(data, "characters", "Jack Torrance", "Nobody", nil)
    TestRunner:assertEqual(changed, false, "unknown drop name refused")
    TestRunner:assertEqual(#data.characters, 5, "data untouched")
end)

TestRunner:test("absorbAliases: sidecar absorb, ignore respect, drop record retired", function()
    local user_aliases = {
        ["Jack Torrance"] = { add = { "Jackie" }, ignore = { "the caretaker" } },
        ["Jack"] = { add = { "Jacky boy" }, ignore = { "Johnny" } },
    }
    XrayDedup.absorbAliases(user_aliases, "Jack Torrance", "Jack",
        { name = "Jack", aliases = { "the caretaker", "Mr. Torrance" } })
    local add = user_aliases["Jack Torrance"].add
    local set = {}
    for _idx, alias in ipairs(add) do set[alias:lower()] = true end
    TestRunner:assertTrue(set["jack"], "dropped name absorbed")
    TestRunner:assertTrue(set["mr. torrance"], "dropped AI alias absorbed (regeneration survival)")
    TestRunner:assertTrue(set["jacky boy"], "dropped entry's user terms folded across")
    TestRunner:assertTrue(not set["the caretaker"], "explicitly ignored term stays out")
    TestRunner:assertTrue(set["jackie"], "existing user terms kept")
    -- Orphaned drop record would re-pair the names forever (gate finding)
    TestRunner:assertEqual(user_aliases["Jack"], nil, "dropped entity's record retired")
    local ignore_set = {}
    for _idx, alias in ipairs(user_aliases["Jack Torrance"].ignore) do
        ignore_set[alias:lower()] = true
    end
    TestRunner:assertTrue(ignore_set["johnny"], "dropped entity's rejected terms stay rejected")
end)

print("")
print("  [AI merge prompt + response]")

TestRunner:test("buildAiMergePrompt: sentinel discipline, keep-entry leads", function()
    local pair = {
        name_a = "Jack Torrance", name_b = "Jack",
        item_a = { name = "Jack Torrance", role = "caretaker", description = "In context, {title} caretaker" },
        item_b = { name = "Jack", description = "a man unraveling" },
        cat_key = "characters",
    }
    local prompt, payload = XrayDedup.buildAiMergePrompt(pair, "b")
    TestRunner:assertTrue(prompt:find("@@KOA_MERGE_INPUTS@@", 1, true) ~= nil, "sentinel in prompt")
    -- WIRE-SAFETY: artifact names/descriptions never in action.prompt
    TestRunner:assertTrue(prompt:find("Jack", 1, true) == nil, "no entity names in the prompt")
    TestRunner:assertTrue(prompt:find("unraveling", 1, true) == nil, "no descriptions in the prompt")
    TestRunner:assertTrue(payload.inputs:find('Entry to KEEP — "Jack"', 1, true) ~= nil,
        "requested keep entry leads the payload")
    TestRunner:assertTrue(payload.inputs:find("In context, {title} caretaker", 1, true) ~= nil,
        "hostile description rides the payload verbatim")
end)

TestRunner:test("cleanDescription: trim, unquote, reject JSON/empty", function()
    TestRunner:assertEqual(XrayDedup.cleanDescription('  "A combined text."  '),
        "A combined text.", "trimmed and unquoted")
    TestRunner:assertEqual(XrayDedup.cleanDescription('{"description": "x"}'), nil, "JSON rejected")
    TestRunner:assertEqual(XrayDedup.cleanDescription("   "), nil, "empty rejected")
    TestRunner:assertEqual(XrayDedup.cleanDescription(nil), nil, "nil rejected")
end)

print("")
print("  [never-merge storage round-trip]")

TestRunner:test("addNeverMergePair round-trips with alias entries intact", function()
    local aliases = {
        ["Jack Torrance"] = { add = { "Jackie" }, ignore = { "caretaker" } },
    }
    TestRunner:assertEqual(ActionCache.setUserAliases(DOC_PATH, aliases), true, "seed aliases")
    TestRunner:assertEqual(ActionCache.addNeverMergePair(DOC_PATH, "Big Tom", "Little Tom"), true, "add pair")
    TestRunner:assertEqual(ActionCache.addNeverMergePair(DOC_PATH, "little tom", "BIG TOM"), true,
        "reversed/case variant deduped (no error)")
    local pairs_list = ActionCache.getNeverMergePairs(DOC_PATH)
    TestRunner:assertEqual(#pairs_list, 1, "one pair stored")
    TestRunner:assertEqual(pairs_list[1][1], "Big Tom", "name A round-trips")
    TestRunner:assertEqual(pairs_list[1][2], "Little Tom", "name B round-trips")

    -- The alias-editor round-trip (get → modify → set) must preserve the pairs
    local all = ActionCache.getUserAliases(DOC_PATH)
    TestRunner:assertTrue(all["Jack Torrance"] ~= nil, "alias entry survived the pair write")
    all["Danny"] = { add = { "Doc" } }
    TestRunner:assertEqual(ActionCache.setUserAliases(DOC_PATH, all), true, "editor-style save")
    TestRunner:assertEqual(#ActionCache.getNeverMergePairs(DOC_PATH), 1, "pairs survive editor round-trip")
    local reread = ActionCache.getUserAliases(DOC_PATH)
    TestRunner:assertEqual(reread["Danny"].add[1], "Doc", "new alias entry saved alongside")
    TestRunner:assertEqual(reread["Jack Torrance"].ignore[1], "caretaker", "ignore list intact")
end)

TestRunner:test("second pair appends; quotes in names survive %q escaping", function()
    TestRunner:assertEqual(ActionCache.addNeverMergePair(DOC_PATH, 'The "Duke"', "El Duque"), true, "add quoted")
    local pairs_list = ActionCache.getNeverMergePairs(DOC_PATH)
    TestRunner:assertEqual(#pairs_list, 2, "two pairs")
    TestRunner:assertEqual(pairs_list[2][1], 'The "Duke"', "quoted name round-trips")
end)

TestRunner:test("removeNeverMergePair: order/case-insensitive removal round-trips", function()
    TestRunner:assertEqual(ActionCache.addNeverMergePair(DOC_PATH, "Ada", "Ada Lovelace"), true, "seed")
    local before = #ActionCache.getNeverMergePairs(DOC_PATH)
    TestRunner:assertEqual(ActionCache.removeNeverMergePair(DOC_PATH, "ADA LOVELACE", "ada"), true, "remove reversed/case")
    TestRunner:assertEqual(#ActionCache.getNeverMergePairs(DOC_PATH), before - 1, "pair removed")
    TestRunner:assertEqual(ActionCache.removeNeverMergePair(DOC_PATH, "Nobody", "Nothing"), true,
        "removing an absent pair is a no-op success")
    -- other entries untouched
    local all = ActionCache.getUserAliases(DOC_PATH)
    TestRunner:assertTrue(all["Jack Torrance"] ~= nil, "alias entries survive removal")
end)

TestRunner:test("empty inputs rejected; reserved key skipped by old-format normalization", function()
    TestRunner:assertEqual(ActionCache.addNeverMergePair(DOC_PATH, "", "X"), false, "empty name refused")
    -- getUserAliases must not wrap the reserved key as an add-table
    local all = ActionCache.getUserAliases(DOC_PATH)
    local raw = all[ActionCache.NEVER_MERGE_KEY]
    TestRunner:assertTrue(type(raw) == "table" and raw.add == nil, "reserved key not normalized")
    TestRunner:assertTrue(type(raw[1]) == "table", "still an array of pairs")
end)

TestRunner:test("addUserAlias: key reuse, add dedupe, ignore-removal (ref #63)", function()
    TestRunner:assertEqual(ActionCache.addUserAlias(DOC_PATH, "Veyra Sol", "The Cartographer"), true, "add")
    local all = ActionCache.getUserAliases(DOC_PATH)
    TestRunner:assertEqual(all["Veyra Sol"].add[1], "The Cartographer", "stored under entity key")
    -- case-variant entity name reuses the existing record key
    TestRunner:assertEqual(ActionCache.addUserAlias(DOC_PATH, "VEYRA SOL", "Vey"), true, "case-variant add")
    all = ActionCache.getUserAliases(DOC_PATH)
    TestRunner:assertTrue(all["VEYRA SOL"] == nil, "no duplicate case-variant record")
    TestRunner:assertEqual(#all["Veyra Sol"].add, 2, "second alias joined the same record")
    -- re-adding case-folded is a no-op success
    TestRunner:assertEqual(ActionCache.addUserAlias(DOC_PATH, "Veyra Sol", "vey"), true, "dupe ok")
    TestRunner:assertEqual(#ActionCache.getUserAliases(DOC_PATH)["Veyra Sol"].add, 2, "no growth")
    -- an explicit add outranks an old ignore
    all = ActionCache.getUserAliases(DOC_PATH)
    all["Veyra Sol"].ignore = { "Cartwright" }
    TestRunner:assertEqual(ActionCache.setUserAliases(DOC_PATH, all), true, "seed ignore")
    TestRunner:assertEqual(ActionCache.addUserAlias(DOC_PATH, "Veyra Sol", "CARTWRIGHT"), true, "add ignored term")
    all = ActionCache.getUserAliases(DOC_PATH)
    TestRunner:assertEqual(#(all["Veyra Sol"].ignore or {}), 0, "ignore entry removed")
    TestRunner:assertEqual(all["Veyra Sol"].add[3], "CARTWRIGHT", "asserted alias added")
    TestRunner:assertEqual(ActionCache.addUserAlias(DOC_PATH, "", "x"), false, "empty name refused")
end)

print("")
print("  [section-merge prompt injection]")

TestRunner:test("never pairs ride the sentinel into both merge prompts", function()
    local sections = {
        { key = "_xray_section:Ch. 1", label = "Ch. 1",
          data = { result = '{"characters":[]}', scope_page_summary = "pp 1–20" } },
    }
    local never = { { "Big Tom", "Little Tom" } }
    local p, payload = XrayMerge.buildCompletePrompt(sections, never)
    TestRunner:assertTrue(p:find("@@KOA_MERGE_NEVER@@", 1, true) ~= nil, "never token in complete prompt")
    TestRunner:assertTrue(p:find("Big Tom", 1, true) == nil, "names never in the prompt (wire-safety)")
    TestRunner:assertTrue(payload.never:find('"Big Tom" and "Little Tom"', 1, true) ~= nil,
        "pair line in the payload")
    local pd, payload_d = XrayMerge.buildDeltaPrompt(sections, { result = "{}", progress_decimal = 0.4 },
        "", never)
    TestRunner:assertTrue(pd:find("@@KOA_MERGE_NEVER@@", 1, true) ~= nil, "never token in delta prompt")
    TestRunner:assertEqual(payload_d.never, payload.never, "same payload lines")

    local injected = XrayMerge.injectPayload("A\n@@KOA_MERGE_NEVER@@\nB", { never = payload.never })
    TestRunner:assertTrue(injected:find("never merge them into one entry:", 1, true) ~= nil,
        "framing added on injection")
    TestRunner:assertTrue(injected:find('"Big Tom" and "Little Tom"', 1, true) ~= nil, "lines injected")
    local empty = XrayMerge.injectPayload("A @@KOA_MERGE_NEVER@@ B", { never = "" })
    TestRunner:assertEqual(empty, "A  B", "no pairs → empty block")
end)

TestRunner:test("no never pairs → builders emit empty payload slot", function()
    local sections = {
        { key = "_xray_section:Ch. 1", label = "Ch. 1", data = { result = "{}" } },
    }
    local _p, payload = XrayMerge.buildCompletePrompt(sections, nil)
    TestRunner:assertEqual(payload.never, "", "nil pairs → empty string")
end)

print("")
print("  [round 18 — offered-pairs memory / refusal verdict / ladder sweep]")

TestRunner:test("addDedupOfferedPairs: batch round-trip, dedupe, never-pairs coexist", function()
    TestRunner:assertEqual(ActionCache.addDedupOfferedPairs(DOC_PATH, {
        { "Mara Cole", "Mara Ellison" }, { "Bell", "Bell Tower" },
    }), true, "batch add")
    local all = ActionCache.getUserAliases(DOC_PATH)
    local offered = ActionCache.dedupOfferedPairsFrom(all)
    TestRunner:assertEqual(#offered, 2, "both pairs stored")
    -- re-add reversed/case-folded: no growth
    TestRunner:assertEqual(ActionCache.addDedupOfferedPairs(DOC_PATH, {
        { "MARA ELLISON", "mara cole" },
    }), true, "dupe add ok")
    TestRunner:assertEqual(#ActionCache.dedupOfferedPairsFrom(ActionCache.getUserAliases(DOC_PATH)), 2,
        "order/case-insensitive dedupe")
    -- reserved key not wrapped by old-format normalization
    local raw = all[ActionCache.DEDUP_OFFERED_KEY]
    TestRunner:assertTrue(type(raw) == "table" and raw.add == nil, "reserved key not normalized")
    -- never pairs still intact alongside
    TestRunner:assertTrue(#ActionCache.getNeverMergePairs(DOC_PATH) > 0, "never pairs coexist")
end)

TestRunner:test("isDifferentEntitiesVerdict: marker + reason; plain description passes through", function()
    local refused, reason = XrayDedup.isDifferentEntitiesVerdict(
        "DIFFERENT ENTITIES\nOne is a historical figure, the other a modern broadcaster.")
    TestRunner:assertTrue(refused, "marker detected")
    TestRunner:assertTrue(reason and reason:find("broadcaster") ~= nil, "reason carried")
    TestRunner:assertTrue(not XrayDedup.isDifferentEntitiesVerdict("A combined description of one person."),
        "normal answer not a refusal")
end)

TestRunner:test("keepBothText: both, one, neither", function()
    local t = XrayDedup.keepBothText("kept", "dropped", "Old Name")
    TestRunner:assertTrue(t:find("kept", 1, true) == 1 and t:find("dropped", 1, true) ~= nil
        and t:find("Old Name", 1, true) ~= nil, "labeled both-text")
    TestRunner:assertEqual(XrayDedup.keepBothText("kept", "", "X"), "kept", "keep-only")
    TestRunner:assertEqual(XrayDedup.keepBothText(nil, "dropped", "X"), "dropped", "drop-only")
    TestRunner:assertEqual(XrayDedup.keepBothText("", "", "X"), nil, "both empty = plain absorb")
end)

TestRunner:test("applyMergeToRungs: folds rungs holding both, leaves single-name rungs, keeps identity", function()
    local XrayParser = require("koassistant_xray_parser")
    local rungs = {
        { timestamp = 111, progress_decimal = 0.5,
          result = '{"characters":[{"name":"Mara Cole","description":"early"},{"name":"Mara Ellison","description":"older text","aliases":["Elli"]}]}' },
        { timestamp = 222, progress_decimal = 0.6,
          result = '{"characters":[{"name":"Mara Cole","description":"later"}]}' },
    }
    local before_r2 = rungs[2].result
    local changed = XrayDedup.applyMergeToRungs(rungs, "characters", "Mara Cole", "Mara Ellison")
    TestRunner:assertEqual(changed, 1, "one rung swept")
    local d1 = XrayParser.parse(rungs[1].result)
    TestRunner:assertEqual(#d1.characters, 1, "split folded in the rung")
    TestRunner:assertEqual(d1.characters[1].name, "Mara Cole", "survivor primary")
    TestRunner:assertTrue(d1.characters[1].description:find("older text", 1, true) ~= nil,
        "rung folds with its OWN texts (keep-both)")
    local aliases = table.concat(d1.characters[1].aliases or {}, "|")
    TestRunner:assertTrue(aliases:find("Mara Ellison", 1, true) ~= nil, "dropped name absorbed as alias")
    TestRunner:assertEqual(rungs[2].result, before_r2, "single-name rung untouched")
    TestRunner:assertEqual(rungs[1].timestamp, 111, "timestamp identity preserved")
end)

print("")
print("  [likely matches for the carried list (B314)]")

-- This book's entries and what it carries from the earlier ones: every way a
-- name drifts between two books, and the look-alikes that are not a match
local function carriedData()
    return {
        type = "fiction",
        characters = {
            { name = "Jory", description = "drives the cart" },
            { name = "the boy", aliases = { "Tobias" }, description = "a stowaway" },
            { name = "Abel", aliases = { "the smith" }, description = "this book's rival" },
            { name = "Mary Ann", description = "a cook" },
        },
        locations = { { name = "The Ford", description = "a crossing" } },
        lexicon = { { term = "inflation", definition = "prices rising" } },
        __dormant = {
            { name = "Jory Pell", category = "characters", source = "Vol 2" },
            { name = "Tobias Renn", category = "characters", source = "Vol 1" },
            { name = "Brann", aliases = { "The Smith" }, category = "characters", source = "Vol 1" },
            { name = "Mary-Ann", category = "characters", source = "Vol 1" },
            { name = "Dorrit", category = "characters", source = "Vol 1" },
            { name = "Dorrit Hale", category = "characters", source = "Vol 2" },
            { name = "Ford", category = "lexicon", source = "Vol 1" },
            { name = "grade inflation", category = "lexicon", source = "Vol 1" },
        },
    }
end
local function pairLines(found)
    local out = {}
    for i, p in ipairs(found) do
        out[i] = p.kind .. ":" .. p.stub.name .. "~" .. (p.item_name or p.other.name) .. ":" .. p.reason
    end
    return table.concat(out, " | ")
end

TestRunner:test("a name inside another, a shared alias, the same name spelled apart; entry pairs first", function()
    local found = XrayDedup.findCarriedMatches(carriedData(), nil)
    TestRunner:assertEqual(pairLines(found), table.concat({
        "entry:Brann~Abel:alias",
        "entry:Jory Pell~Jory:name",
        "entry:Mary-Ann~Mary Ann:exact",
        "entry:Tobias Renn~the boy:name",
        "carried:Dorrit~Dorrit Hale:name",
    }, " | "), "a term and a place of one name, and a term inside a term, are no match")
    local jory = found[2]
    TestRunner:assertEqual(jory.stub_idx, 1, "the carried row keeps its place in the list")
    TestRunner:assertEqual(jory.cat_key, "characters", "and the entry its category, for the link")
    TestRunner:assertEqual(jory.item.description, "drives the cart")
    TestRunner:assertEqual(found[5].stub_idx .. ">" .. found[5].other_idx, "5>6")
end)

TestRunner:test("never-merge pairs are skipped, in any case and order", function()
    local found = XrayDedup.findCarriedMatches(carriedData(), { { "jory", "JORY PELL" }, { "Dorrit Hale", "Dorrit" } })
    TestRunner:assertEqual(pairLines(found), table.concat({
        "entry:Brann~Abel:alias",
        "entry:Mary-Ann~Mary Ann:exact",
        "entry:Tobias Renn~the boy:name",
    }, " | "))
end)

TestRunner:test("two entries of this book are never a pair here, and no carried list means nothing", function()
    local data = fictionData()
    TestRunner:assertEqual(#XrayDedup.findCarriedMatches(data, nil), 0, "no carried list")
    data.type = "fiction"
    data.__dormant = { { name = "Halloran", category = "characters", source = "Vol 1" } }
    TestRunner:assertEqual(#XrayDedup.findCarriedMatches(data, nil), 0,
        "Jack and Jack Torrance are the duplicate review's")
    TestRunner:assertEqual(#XrayDedup.findCarriedMatches(nil, nil), 0)
end)

TestRunner:test("a one-character alias pairs nobody; a category family bridges its two names", function()
    local data = {
        type = "nonfiction",
        key_figures = { { name = "Kell", description = "the harbormaster" } },
        __dormant = {
            { name = "Kell Marsh", category = "characters", source = "Vol 1" },
            { name = "山田", aliases = { "彼" }, category = "characters", source = "Vol 1" },
            { name = "鈴木", aliases = { "彼" }, category = "characters", source = "Vol 2" },
            { name = "佐藤", aliases = { "太郎" }, category = "characters", source = "Vol 1" },
            { name = "田中", aliases = { "太郎" }, category = "characters", source = "Vol 2" },
        },
    }
    TestRunner:assertEqual(pairLines(XrayDedup.findCarriedMatches(data, nil)),
        "entry:Kell Marsh~Kell:name | carried:佐藤~田中:alias")
    TestRunner:assertEqual(XrayDedup.findCarriedMatches(data, nil)[1].cat_key, "key_figures")
end)

TestRunner:test("a word many rows share is a title or a family name, not an identity", function()
    local function lords(n)
        local data = { type = "fiction",
            characters = { { name = "Brannoch", aliases = { "Lord" }, description = "a lord" } },
            __dormant = {} }
        for i, name in ipairs({ "Lord Vetch", "Lord Ames", "Lord Pike", "Lord Hask" }) do
            if i <= n then
                data.__dormant[i] = { name = name, category = "characters", source = "Vol 1" }
            end
        end
        return data
    end
    TestRunner:assertEqual(#XrayDedup.findCarriedMatches(lords(3), nil), 3, "three names start with it: each is offered")
    TestRunner:assertEqual(#XrayDedup.findCarriedMatches(lords(4), nil), 0, "four: it is a title")
    local shared = { type = "fiction", characters = { { name = "Abel", aliases = { "the captain" } } },
        __dormant = {} }
    for i, name in ipairs({ "Pell", "Roy", "Hask" }) do
        shared.__dormant[i] = { name = name, aliases = { "the captain" }, category = "characters", source = "Vol 1" }
    end
    TestRunner:assertEqual(#XrayDedup.findCarriedMatches(shared, nil), 0, "an alias on four rows")
    table.remove(shared.__dormant)
    TestRunner:assertEqual(#XrayDedup.findCarriedMatches(shared, nil), 3, "on three: every pair of them")
end)

TestRunner:test("a pair found two ways is listed once, under the stronger reason", function()
    local data = { type = "fiction",
        characters = { { name = "Jory", description = "x" } },
        __dormant = { { name = "Jory Pell", aliases = { "jory" }, category = "characters", source = "Vol 2" } } }
    TestRunner:assertEqual(pairLines(XrayDedup.findCarriedMatches(data, nil)), "entry:Jory Pell~Jory:alias")
end)

TestRunner:test("the reasons read the same in both reviews", function()
    TestRunner:assertEqual(XrayDedup.reasonLabel("name"), "contained name")
    TestRunner:assertEqual(XrayDedup.reasonLabel("alias"), "shared alias")
    TestRunner:assertEqual(XrayDedup.reasonLabel("exact"), "same name")
    TestRunner:assertEqual(XrayDedup.snippet({ description = "a  b\nc" }), "a b c")
end)

os.execute(string.format("rm -rf %q", TMP_ROOT))

local ok = TestRunner:summary()
return ok
