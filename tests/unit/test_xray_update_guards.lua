-- The two guards of the reading-along update's merge (xray_parser.lua
-- mergeArrayCategory; B732, B733), found by reading the checkpoints of real
-- builds entry by entry:
--   * a second person of a name. An incoming entry whose name is only an
--     ALIAS of a stored entry was folded into that entry, and its description
--     replaced the stored one: a maid took over the entry of her mistress,
--     whose first name she shares; a grandfather took over the entry of his
--     grandson, who was first met under the title and surname both carry.
--     Now such an entry is its own entry, unless the update itself joins the
--     names (the bridge) or the alias is the reader's on that entry.
--   * a stub. An update wrote two words over a description of 576
--     characters, and seven later updates left it so. A missing, blank or
--     tiny text no longer replaces a stored description.
-- A merge of two books' X-Rays (artifact_writeback.lua) passes neither rule:
-- the same person under a shorter name in another book is what it is for.
--
-- Run: lua tests/unit/test_xray_update_guards.lua  (or lua tests/run_tests.lua --unit)

local function setupPaths()
    local info = debug.getinfo(1, "S")
    local script_path = info.source:match("@?(.*)")
    local unit_dir = script_path:match("(.+)/[^/]+$") or "."
    local tests_dir = unit_dir:match("(.+)/[^/]+$") or "."
    local plugin_dir = tests_dir:match("(.+)/[^/]+$") or "."
    package.path = table.concat({
        plugin_dir .. "/?.lua",
        tests_dir .. "/?.lua",
        tests_dir .. "/lib/?.lua",
        package.path,
    }, ";")
    return plugin_dir
end
local PLUGIN_DIR = setupPaths()
require("mock_koreader")

-- The artifact cache reads KOReader's docsettings when it loads; only its
-- pure readerNamesFrom is used here. What this file puts in place it takes
-- out again (the suite runs every file in one process).
local orig_docsettings = package.loaded["docsettings"]
local had_cache = package.loaded["koassistant.artifacts.action_cache"] ~= nil
if not orig_docsettings then
    package.loaded["docsettings"] = {
        open = function() return { readSetting = function() end } end,
        getSidecarDir = function(_, path) return path .. ".sdr" end,
        isHashLocationEnabled = function() return false end,
    }
end
local XrayParser = require("koassistant.xray.xray_parser")
local ActionCache = require("koassistant.artifacts.action_cache")
local TestRunner = require("test_runner"):new()

print("")
print(string.rep("=", 50))
print("  Unit Tests: the update merge's guards")
print(string.rep("=", 50))

local LONG = "The mistress of the upper house, mother of the two children there and wife of the magistrate. "
    .. "She visits the lower house during the fever, sets it in order and takes the convalescent home with her, "
    .. "where she and her husband both catch the fever and die within days of each other."

local function stored()
    return {
        type = "fiction",
        characters = {
            { name = "Mrs. Alder", aliases = { "old Mrs. Alder", "Ruth" }, role = "Minor", description = LONG,
              connections = { "Tobias Wren (neighbour)" } },
            { name = "Tobias Wren", aliases = { "Mr. Wren", "the young man" }, role = "Major",
              description = "A rough young man of the lower house whose bearing is free and almost haughty "
                  .. "though his speech and dress are a labourer's." },
            { name = "Miss Corra Vane", aliases = { "Corra" }, role = "Major",
              description = "The daughter of the lower house, wild and proud, who grows up beside the foundling." },
        },
        lexicon = {
            { term = "toll ledger", definition = string.rep("The book in which the road's dues are entered, kept at the gate. ", 4) },
        },
    }
end
local GUARD = { alias_needs_bridge = true, reader_names = {} }

local function find(data, name)
    for _i, e in ipairs(data.characters or {}) do
        if e.name == name then return e end
    end
end

-- ── a second person of a name ───────────────────────────────────────────────
TestRunner:test("a maid who shares her mistress's first name gets her own entry", function()
    local merged = XrayParser.merge(stored(), { characters = {
        { name = "Ruth", aliases = { "the thoughtless girl" }, role = "Minor",
          description = "A housemaid of the upper house who blurts out the news of the elopement." },
    } }, GUARD)
    TestRunner:assertEqual(#merged.characters, 4, "four people: the maid is a new entry")
    TestRunner:assertEqual(find(merged, "Mrs. Alder").description, LONG, "the mistress keeps her own description")
    TestRunner:assertTrue(find(merged, "Ruth") ~= nil and find(merged, "Ruth").description:find("housemaid", 1, true) ~= nil,
        "the maid is described under her own name")
end)

TestRunner:test("a grandfather who shares a title and surname gets his own entry", function()
    local merged = XrayParser.merge(stored(), { characters = {
        { name = "Mr. Wren", aliases = { "old Mr. Wren", "the old master" }, role = "Minor",
          description = "The old master of the lower house, who walked to the port and brought a foundling home." },
    } }, GUARD)
    TestRunner:assertEqual(#merged.characters, 4, "the grandfather is a new entry")
    TestRunner:assertTrue(find(merged, "Tobias Wren").description:find("rough young man", 1, true) ~= nil,
        "the grandson's entry still describes the grandson")
    TestRunner:assertTrue(find(merged, "Mr. Wren").description:find("foundling", 1, true) ~= nil,
        "and the grandfather has his own")
end)

TestRunner:test("the update's own bridge still folds: the stored main name among the incoming aliases", function()
    local merged = XrayParser.merge(stored(), { characters = {
        { name = "Ruth", aliases = { "Mrs. Alder" }, role = "Minor",
          description = "The mistress of the upper house, now dead of the fever she caught nursing a neighbour's child, "
              .. "as her husband died within days of her." },
    } }, GUARD)
    TestRunner:assertEqual(#merged.characters, 3, "no new entry: the update said the two names are one person")
    local e = find(merged, "Mrs. Alder")
    TestRunner:assertTrue(e ~= nil and e.description:find("now dead of the fever", 1, true) ~= nil,
        "the entry takes the update's text and keeps its stored name")
end)

TestRunner:test("the reader's own name for an entry still folds", function()
    -- the reader added "Ruth" to Mrs. Alder, or renamed the entry away from it
    local names = ActionCache.readerNamesFrom({
        ["Mrs. Alder"] = { add = { "Ruth" } },
        ["Tobias Wren"] = { ai_name = "Mr. Wren", typed = { "Tobias Wren" } },
        __never_merge = { { "A", "B" } },
    })
    TestRunner:assertTrue(names["mrs. alder"] ~= nil and names["mrs. alder"]["ruth"] == true, "an added name is the reader's")
    TestRunner:assertTrue(names["tobias wren"]["mr. wren"] == true, "the AI's name a reader renamed away from is the reader's")
    TestRunner:assertTrue(names["__never_merge"] == nil, "the pair lists are not entries")
    local merged = XrayParser.merge(stored(), { characters = {
        { name = "Ruth", role = "Minor", description = "The mistress of the upper house, seen again at the gate in the autumn of that year." },
        { name = "Mr. Wren", role = "Major", description = "The young man of the lower house, who now learns his letters by the fire." },
    } }, { alias_needs_bridge = true, reader_names = names })
    TestRunner:assertEqual(#merged.characters, 3, "both fold into the entries the reader named")
    TestRunner:assertTrue(find(merged, "Mrs. Alder").description:find("at the gate", 1, true) ~= nil, "the first")
    TestRunner:assertTrue(find(merged, "Tobias Wren").description:find("learns his letters", 1, true) ~= nil,
        "the second, under the reader's name for it")
end)

TestRunner:test("an exact main name and a rename through the bridge are untouched by the rule", function()
    local merged = XrayParser.merge(stored(), { characters = {
        { name = "Tobias Wren", role = "Major", description = "The heir of the lower house, kept from his letters by the man who ruined his father, and proud all the same." },
        { name = "Lady Ashby", aliases = { "Miss Corra Vane" }, role = "Major",
          description = "The daughter of the lower house, now married into the upper one and its mistress." },
    } }, GUARD)
    TestRunner:assertEqual(#merged.characters, 3, "no new entry")
    TestRunner:assertTrue(find(merged, "Tobias Wren").description:find("heir of the lower house", 1, true) ~= nil,
        "an exact name updates its entry")
    local renamed = find(merged, "Lady Ashby")
    TestRunner:assertTrue(renamed ~= nil and find(merged, "Miss Corra Vane") == nil, "the bridge renames the entry")
    local has_old = false
    for _i, a in ipairs(renamed and renamed.aliases or {}) do
        if a == "Miss Corra Vane" then has_old = true end
    end
    TestRunner:assertTrue(has_old, "and the old name stays an alias")
end)

TestRunner:test("a merge that passes no rule folds on an alias as before (two books' X-Rays)", function()
    local merged = XrayParser.merge(stored(), { characters = {
        { name = "Ruth", role = "Minor", description = "The mistress of the upper house, as the second volume first shows her, at the head of her table." },
    } })
    TestRunner:assertEqual(#merged.characters, 3, "folded: the same person under a shorter name in another book")
    TestRunner:assertTrue(find(merged, "Mrs. Alder").description:find("second volume", 1, true) ~= nil, "under the stored name")
end)

-- ── a stub ──────────────────────────────────────────────────────────────────
TestRunner:test("two words of housekeeping do not replace a description", function()
    local merged = XrayParser.merge(stored(), { characters = {
        { name = "Mrs. Alder", role = "Minor", description = "Placeholder removed." },
    } }, GUARD)
    local e = find(merged, "Mrs. Alder")
    TestRunner:assertEqual(e.description, LONG, "the stored description stays")
    TestRunner:assertEqual(e.role, "Minor", "the entry's other fields are the update's")
end)

TestRunner:test("an entry sent again without its description keeps it", function()
    local merged = XrayParser.merge(stored(), { characters = {
        { name = "Mrs. Alder", aliases = { "the dame" }, role = "Minor" },
        { name = "Tobias Wren", role = "Major", description = "   " },
    } }, GUARD)
    TestRunner:assertEqual(find(merged, "Mrs. Alder").description, LONG, "a missing description")
    TestRunner:assertTrue(find(merged, "Tobias Wren").description:find("rough young man", 1, true) ~= nil, "a blank one")
    local has = false
    for _i, a in ipairs(find(merged, "Mrs. Alder").aliases) do
        if a == "the dame" then has = true end
    end
    TestRunner:assertTrue(has, "and the new alias is taken")
end)

TestRunner:test("a real description replaces the stored one, shorter or not", function()
    local shorter = "The mistress of the upper house and mother of its two children, dead of the fever in the same week as her husband."
    local merged = XrayParser.merge(stored(), { characters = {
        { name = "Mrs. Alder", role = "Minor", description = shorter },
        { name = "Miss Corra Vane", role = "Major", description = "Wild and proud." },
    } }, GUARD)
    TestRunner:assertEqual(find(merged, "Mrs. Alder").description, shorter, "a third of the length is a description, not a stub")
    TestRunner:assertEqual(find(merged, "Miss Corra Vane").description, "Wild and proud.",
        "a short stored text has no fraction to judge by: the update's is taken")
end)

TestRunner:test("the same guard holds a word's definition, and holds with no rule passed", function()
    local merged = XrayParser.merge(stored(), { lexicon = { { term = "toll ledger", definition = "See above." } } })
    TestRunner:assertTrue(#merged.lexicon == 1 and merged.lexicon[1].definition:find("dues are entered", 1, true) ~= nil,
        "the definition stays")
end)

-- ── the hand-off ────────────────────────────────────────────────────────────
TestRunner:test("the reading-along update passes the rule, the merge of two books does not", function()
    local function src(rel)
        local f = assert(io.open(PLUGIN_DIR .. "/" .. rel, "r"))
        local s = f:read("*a")
        f:close()
        return s
    end
    local dialogs = src("koassistant/ui/dialogs.lua")
    local call = dialogs:match("local merge_opts = cache_file%s+and require%(\"koassistant%.artifacts%.action_cache\"%)%.updateMergeOptions%(cache_file%)%s+"
        .. "parsed = XrayParser%.merge%(message_data%._parsed_old_xray, parsed, merge_opts or nil%)")
    TestRunner:assertTrue(call ~= nil, "the update's merge is given ActionCache.updateMergeOptions of the book")
    local n = 0
    for _ in dialogs:gmatch("XrayParser%.merge%(") do n = n + 1 end
    TestRunner:assertEqual(n, 1, "dialogs.lua merges an update in one place")
    local writeback = src("koassistant/xray/artifact_writeback.lua")
    TestRunner:assertTrue(writeback:find("updateMergeOptions", 1, true) == nil and writeback:find("alias_needs_bridge", 1, true) == nil,
        "the shared write-back (merges of two X-Rays) does not pass it")
    -- the options are what the merge reads
    local cache = src("koassistant/artifacts/action_cache.lua")
    local body = cache:match("function ActionCache%.updateMergeOptions%(document_path%)(.-)\nend")
    TestRunner:assertTrue(body ~= nil and body:find("alias_needs_bridge = true", 1, true) ~= nil
        and body:find("reader_names = ActionCache.readerNamesFrom(all)", 1, true) ~= nil
        and body:find("never_pairs = ActionCache.neverMergePairsFrom(all)", 1, true) ~= nil,
        "one read of the reader's file gives the pairs, the rule and the reader's names")
end)

package.loaded["docsettings"] = orig_docsettings
if not had_cache then package.loaded["koassistant.artifacts.action_cache"] = nil end

return TestRunner:summary()
