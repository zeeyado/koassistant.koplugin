--[[
Unit Tests for X-Ray merge and entity index functions

Tests:
- buildEntityIndex(): fiction, nonfiction, aliases, empty data
- merge(): name matching, singletons, append categories, new categories, type preservation

Run: lua tests/run_tests.lua --unit
]]

-- Setup test environment
package.path = package.path .. ";./?.lua;./?/init.lua"
require("tests.lib.mock_koreader")

local XrayParser = require("koassistant_xray_parser")

-- Test suite
local TestXrayMerge = {
    passed = 0,
    failed = 0,
}

function TestXrayMerge:test(name, fn)
    local ok, err = pcall(fn)
    if ok then
        self.passed = self.passed + 1
        print(string.format("  \226\156\147 %s", name))
    else
        self.failed = self.failed + 1
        print(string.format("  \226\156\151 %s: %s", name, tostring(err)))
    end
end

function TestXrayMerge:assert(condition, message)
    if not condition then
        error(message or "Assertion failed", 2)
    end
end

function TestXrayMerge:assertEquals(actual, expected, message)
    if actual ~= expected then
        error(string.format("%s: expected %s, got %s",
            message or "Values not equal",
            tostring(expected),
            tostring(actual)), 2)
    end
end

-- Helper: deep copy a table to avoid mutation between tests
local function deepcopy(t)
    if type(t) ~= "table" then return t end
    local copy = {}
    for k, v in pairs(t) do
        copy[k] = deepcopy(v)
    end
    return copy
end

-- Sample fiction data
local function makeFictionData()
    return {
        type = "fiction",
        characters = {
            { name = "Elizabeth Bennet", aliases = {"Lizzy", "Eliza", "Miss Bennet"}, role = "Protagonist", description = "Witty and independent.", connections = {"Mr. Darcy (love interest)"} },
            { name = "Mr. Darcy", aliases = {"Darcy"}, role = "Love interest", description = "Proud but honorable.", connections = {"Elizabeth Bennet (love interest)"} },
        },
        locations = {
            { name = "Longbourn", description = "The Bennet family estate." },
        },
        themes = {
            { name = "Pride", description = "How pride affects relationships." },
        },
        lexicon = {
            { term = "Entailment", definition = "Legal restriction on inheritance." },
        },
        timeline = {
            { event = "The Bennets learn of Mr. Bingley's arrival", chapter = "Chapter 1", significance = "Sets the plot in motion" },
        },
        current_state = {
            summary = "Elizabeth has met Darcy at the ball.",
            conflicts = {"Class differences"},
            questions = {"Will Darcy's pride be overcome?"},
        },
    }
end

-- Sample nonfiction data
local function makeNonfictionData()
    return {
        type = "nonfiction",
        key_figures = {
            { name = "Charles Darwin", aliases = {"Darwin"}, role = "Naturalist", description = "Proposed natural selection." },
        },
        locations = {
            { name = "Galapagos Islands", description = "Key site for Darwin's observations." },
        },
        core_concepts = {
            { name = "Natural Selection", description = "Survival of the fittest." },
        },
        arguments = {},
        terminology = {
            { term = "Adaptation", definition = "Traits that improve survival." },
        },
        argument_development = {
            { event = "Darwin observes finch variation", chapter = "Chapter 3", significance = "Evidence for adaptation" },
        },
        current_position = {
            summary = "The argument for natural selection is being built.",
            questions_addressed = {"How do species change?"},
            building_toward = {"A unified theory of evolution"},
        },
    }
end

function TestXrayMerge:runAll()
    print("\n=== Testing X-Ray merge and entity index ===\n")

    -- ===== buildEntityIndex tests =====
    print("--- buildEntityIndex ---")

    self:test("fiction data with aliases", function()
        local data = makeFictionData()
        local index = XrayParser.buildEntityIndex(data)
        -- Should list characters with aliases
        self:assert(index:find("Elizabeth Bennet (Lizzy, Eliza)", 1, true), "Should include first 2 aliases for Elizabeth")
        self:assert(index:find("Mr. Darcy (Darcy)", 1, true), "Should include alias for Darcy")
        -- Should list locations without aliases
        self:assert(index:find("locations: Longbourn"), "Should list locations")
        -- Should list themes
        self:assert(index:find("themes: Pride"), "Should list themes")
        -- Should list lexicon
        self:assert(index:find("lexicon: Entailment"), "Should list lexicon terms")
        -- Should NOT list current_state (singleton)
        self:assert(not index:find("current_state"), "Should skip singleton current_state")
    end)

    self:test("nonfiction data", function()
        local data = makeNonfictionData()
        local index = XrayParser.buildEntityIndex(data)
        self:assert(index:find("key_figures: Charles Darwin (Darwin)", 1, true), "Should list key figures with aliases")
        self:assert(index:find("core_concepts: Natural Selection"), "Should list concepts")
        -- Should NOT list current_position (singleton)
        self:assert(not index:find("current_position"), "Should skip singleton current_position")
    end)

    self:test("empty data", function()
        local index = XrayParser.buildEntityIndex({ type = "fiction" })
        self:assertEquals(index, "", "Empty data should return empty string")
    end)

    self:test("items without aliases", function()
        local data = {
            type = "fiction",
            characters = {
                { name = "Solo Character", role = "Protagonist", description = "No aliases." },
            },
        }
        local index = XrayParser.buildEntityIndex(data)
        self:assert(index:find("characters: Solo Character"), "Should list name without parens")
        self:assert(not index:find("%("), "Should not have parentheses for no-alias items")
    end)

    self:test("max 2 aliases shown", function()
        local data = {
            type = "fiction",
            characters = {
                { name = "Many Names", aliases = {"A", "B", "C", "D"}, role = "Test", description = "Test." },
            },
        }
        local index = XrayParser.buildEntityIndex(data)
        self:assert(index:find("Many Names (A, B)", 1, true), "Should show only first 2 aliases")
        self:assert(not index:find("C"), "Should not show third alias")
    end)

    -- ===== merge tests =====
    print("\n--- merge ---")

    self:test("new items appended to existing category", function()
        local old = deepcopy(makeFictionData())
        local new_data = {
            type = "fiction",
            characters = {
                { name = "Mr. Wickham", role = "Antagonist", description = "Charming but deceitful." },
            },
        }
        local merged = XrayParser.merge(old, new_data)
        self:assertEquals(#merged.characters, 3, "Should have 3 characters after append")
        self:assertEquals(merged.characters[3].name, "Mr. Wickham", "New character appended")
        -- Existing should be preserved
        self:assertEquals(merged.characters[1].name, "Elizabeth Bennet", "Existing character preserved")
    end)

    self:test("existing items updated by name match (case-insensitive)", function()
        local old = deepcopy(makeFictionData())
        local new_data = {
            type = "fiction",
            characters = {
                { name = "elizabeth bennet", role = "Protagonist", description = "Updated description with new events.", aliases = {"Lizzy"} },
            },
        }
        local merged = XrayParser.merge(old, new_data)
        self:assertEquals(#merged.characters, 2, "Should still have 2 characters (replaced, not appended)")
        self:assert(merged.characters[1].description:find("Updated description"), "Description should be updated")
    end)

    self:test("singleton categories replaced entirely", function()
        local old = deepcopy(makeFictionData())
        local new_data = {
            type = "fiction",
            current_state = {
                summary = "New state after recent events.",
                conflicts = {"New conflict"},
                questions = {"New question"},
            },
        }
        local merged = XrayParser.merge(old, new_data)
        self:assertEquals(merged.current_state.summary, "New state after recent events.", "current_state should be replaced")
    end)

    self:test("missing categories preserved from old data", function()
        local old = deepcopy(makeFictionData())
        -- Update with only current_state, nothing else
        local new_data = {
            type = "fiction",
            current_state = {
                summary = "Updated.",
                conflicts = {},
                questions = {},
            },
        }
        local merged = XrayParser.merge(old, new_data)
        self:assertEquals(#merged.characters, 2, "Characters preserved when not in new_data")
        self:assertEquals(#merged.locations, 1, "Locations preserved when not in new_data")
        self:assertEquals(#merged.themes, 1, "Themes preserved when not in new_data")
    end)

    self:test("new category in new_data that old_data lacks", function()
        local old = deepcopy(makeFictionData())
        old.lexicon = nil  -- Simulate old data without lexicon
        local new_data = {
            type = "fiction",
            lexicon = {
                { term = "New Term", definition = "New definition." },
            },
        }
        local merged = XrayParser.merge(old, new_data)
        self:assert(merged.lexicon ~= nil, "New category should be added")
        self:assertEquals(#merged.lexicon, 1, "Should have 1 lexicon entry")
        self:assertEquals(merged.lexicon[1].term, "New Term", "New term added correctly")
    end)

    self:test("full replacement fallback (AI outputs everything)", function()
        local old = deepcopy(makeFictionData())
        local full_new = deepcopy(makeFictionData())
        full_new.characters[1].description = "Completely rewritten."
        local merged = XrayParser.merge(old, full_new)
        self:assertEquals(merged.characters[1].description, "Completely rewritten.", "Full output replaces via name match")
    end)

    self:test("type field preservation (old has type)", function()
        local old = deepcopy(makeFictionData())
        local new_data = { type = "fiction", current_state = { summary = "Updated." } }
        local merged = XrayParser.merge(old, new_data)
        self:assertEquals(merged.type, "fiction", "Type preserved from old_data")
    end)

    self:test("type field inherited (old lacks type)", function()
        local old = deepcopy(makeFictionData())
        old.type = nil
        local new_data = { type = "fiction", current_state = { summary = "Updated." } }
        local merged = XrayParser.merge(old, new_data)
        self:assertEquals(merged.type, "fiction", "Type inherited from new_data")
    end)

    self:test("timeline uses pure append (no dedup)", function()
        local old = deepcopy(makeFictionData())
        local new_data = {
            type = "fiction",
            timeline = {
                -- Same event text as existing — should still append (not deduplicate)
                { event = "The Bennets learn of Mr. Bingley's arrival", chapter = "Chapter 1", significance = "Duplicate" },
                { event = "Elizabeth dances with Darcy", chapter = "Chapter 3", significance = "New event" },
            },
        }
        local merged = XrayParser.merge(old, new_data)
        -- 1 original + 2 new = 3 (pure append, no dedup)
        self:assertEquals(#merged.timeline, 3, "Timeline should append without deduplication")
    end)

    self:test("argument_development uses pure append", function()
        local old = deepcopy(makeNonfictionData())
        local new_data = {
            type = "nonfiction",
            argument_development = {
                { event = "New development point", chapter = "Chapter 5", significance = "Advances thesis" },
            },
        }
        local merged = XrayParser.merge(old, new_data)
        self:assertEquals(#merged.argument_development, 2, "argument_development should append")
    end)

    self:test("nonfiction singleton: current_position replaced", function()
        local old = deepcopy(makeNonfictionData())
        local new_data = {
            type = "nonfiction",
            current_position = {
                summary = "Updated nonfiction position.",
                questions_addressed = {"New question"},
                building_toward = {"New direction"},
            },
        }
        local merged = XrayParser.merge(old, new_data)
        self:assertEquals(merged.current_position.summary, "Updated nonfiction position.", "current_position replaced")
    end)

    self:test("reader_engagement singleton replaced", function()
        local old = deepcopy(makeFictionData())
        old.reader_engagement = { pattern = "Original pattern." }
        local new_data = {
            type = "fiction",
            reader_engagement = { pattern = "Updated engagement pattern." },
        }
        local merged = XrayParser.merge(old, new_data)
        self:assertEquals(merged.reader_engagement.pattern, "Updated engagement pattern.", "reader_engagement replaced")
    end)

    self:test("nil new_data returns old_data", function()
        local old = deepcopy(makeFictionData())
        local merged = XrayParser.merge(old, nil)
        self:assertEquals(merged.type, "fiction", "Should return old_data when new_data is nil")
        self:assertEquals(#merged.characters, 2, "Old characters preserved")
    end)

    self:test("nil old_data returns new_data", function()
        local new_data = deepcopy(makeFictionData())
        local merged = XrayParser.merge(nil, new_data)
        self:assertEquals(merged.type, "fiction", "Should return new_data when old_data is nil")
    end)

    self:test("empty new_data preserves old_data", function()
        local old = deepcopy(makeFictionData())
        local merged = XrayParser.merge(old, {})
        self:assertEquals(#merged.characters, 2, "Characters preserved with empty new_data")
        self:assertEquals(#merged.locations, 1, "Locations preserved with empty new_data")
    end)

    -- Print summary
    print(string.format("\n%d passed, %d failed", self.passed, self.failed))
    return self.failed == 0
end

-- Run tests if executed directly
if arg and arg[0] and arg[0]:match("test_xray_merge%.lua$") then
    local success = TestXrayMerge:runAll()
    os.exit(success and 0 or 1)
end

return TestXrayMerge
