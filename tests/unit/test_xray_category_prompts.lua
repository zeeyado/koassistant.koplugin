--[[
Unit tests: X-Ray category prompt assembly (presets v0.21)

The fiction/nonfiction schema+guidance blocks were split into per-group
fragments so a category selection can assemble a narrowed create prompt.
These tests guard:
- the FULL assembly still carries every category key + guidance bullet
  (the default path must be the pre-split prompt),
- filtered assemblies contain exactly the selected groups' keys and drop
  the rest (schema AND guidance),
- normalizeXrayCategories canonicalization (order, full → nil, junk → nil),
- xrayCategoryKeysFor per-type key mapping (the update-clause helper).

Run: lua tests/unit/test_xray_category_prompts.lua  (auto-discovered by run_tests.lua --unit)
]]

-- Setup test environment
package.path = package.path .. ";./?.lua;./?/init.lua;./tests/?.lua;./tests/lib/?.lua"
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

require("mock_koreader")

local Actions = require("prompts.actions")
local TestRunner = require("test_runner"):new()

print("Running: test_xray_category_prompts")
print("")
print("  [X-Ray category prompt assembly]")

local FICTION_KEYS = { people = '"characters"', places = '"locations"',
    ideas = '"themes"', terms = '"lexicon"', events = '"timeline"' }
local NONFICTION_KEYS_BY_GROUP = {
    people = { '"key_figures"' }, places = { '"locations"' },
    ideas = { '"core_concepts"', '"arguments"' }, terms = { '"terminology"' },
    events = { '"argument_development"' },
}
local GUIDANCE_MARKS = { people = "**Characters**", places = "**Locations**",
    ideas = "**Themes**", terms = "**Lexicon**", events = "**Timeline**" }

TestRunner:test("full assembly (action fields) carries every category", function()
    local x = Actions.book.xray
    for _idx, which in ipairs({ x.prompt, x.complete_prompt }) do
        for _g, key in pairs(FICTION_KEYS) do
            assert(which:find(key, 1, true), "full prompt missing " .. key)
        end
        for _g, keys in pairs(NONFICTION_KEYS_BY_GROUP) do
            for _k, key in ipairs(keys) do
                assert(which:find(key, 1, true), "full prompt missing " .. key)
            end
        end
        for _g, mark in pairs(GUIDANCE_MARKS) do
            assert(which:find(mark, 1, true), "full prompt missing guidance " .. mark)
        end
    end
end)

TestRunner:test("full assembly keeps status singletons per variant", function()
    local x = Actions.book.xray
    assert(x.prompt:find('"current_state"', 1, true), "partial should carry current_state")
    assert(x.complete_prompt:find('"conclusion"', 1, true), "complete should carry conclusion")
end)

TestRunner:test("people-only assembly drops the other four groups", function()
    local p = Actions.buildXrayCategoryPrompt("people", "partial")
    assert(p:find('"characters"', 1, true), "characters should stay")
    assert(p:find('"key_figures"', 1, true), "key_figures should stay")
    assert(not p:find('"themes"', 1, true), "themes should drop")
    assert(not p:find('"lexicon"', 1, true), "lexicon should drop")
    assert(not p:find('"timeline"', 1, true), "timeline should drop")
    assert(not p:find('"locations"', 1, true), "locations should drop")
    assert(not p:find('"argument_development"', 1, true), "argument_development should drop")
    assert(not p:find("**Themes**", 1, true), "themes guidance should drop")
    assert(p:find('"current_state"', 1, true), "status singleton should stay")
    -- schema block stays comma-valid: category block flows into the status object
    assert(p:find('%]%],?\n  "current_state"') or p:find('%],\n  "current_state"'),
        "characters block should join current_state cleanly")
end)

TestRunner:test("two-group assembly keeps both, complete variant", function()
    local p = Actions.buildXrayCategoryPrompt("people,events", "complete")
    assert(p:find('"characters"', 1, true), "characters should stay")
    assert(p:find('"timeline"', 1, true), "timeline should stay")
    assert(p:find('"argument_development"', 1, true), "argument_development should stay")
    assert(not p:find('"themes"', 1, true), "themes should drop")
    assert(p:find('"conclusion"', 1, true), "complete status should be conclusion")
end)

TestRunner:test("ideas group spans both nonfiction categories", function()
    local p = Actions.buildXrayCategoryPrompt("ideas", "partial")
    assert(p:find('"themes"', 1, true), "fiction themes should stay")
    assert(p:find('"core_concepts"', 1, true), "core_concepts should stay")
    assert(p:find('"arguments"', 1, true), "arguments should stay")
    assert(not p:find('"characters"', 1, true), "characters should drop")
end)

TestRunner:test("normalizeXrayCategories canonicalizes", function()
    TestRunner:assertEqual(Actions.normalizeXrayCategories("events, people"), "people,events",
        "order canonicalized")
    TestRunner:assertEqual(Actions.normalizeXrayCategories("people,places,ideas,terms,events"), nil,
        "full set is nil")
    TestRunner:assertEqual(Actions.normalizeXrayCategories("bogus"), nil, "junk is nil")
    TestRunner:assertEqual(Actions.normalizeXrayCategories(""), nil, "empty is nil")
    TestRunner:assertEqual(Actions.normalizeXrayCategories(nil), nil, "nil is nil")
    TestRunner:assertEqual(Actions.normalizeXrayCategories("people,bogus"), "people",
        "junk ids drop, valid ones stay")
end)

TestRunner:test("xrayCategoryKeysFor maps per type and unions unknown", function()
    local fk = Actions.xrayCategoryKeysFor("people,events", "fiction")
    TestRunner:assertEqual(table.concat(fk, ","), "characters,timeline", "fiction keys")
    local nk = Actions.xrayCategoryKeysFor("people,events", "nonfiction")
    TestRunner:assertEqual(table.concat(nk, ","), "key_figures,argument_development",
        "nonfiction keys")
    local uk = Actions.xrayCategoryKeysFor("ideas", nil)
    TestRunner:assertEqual(table.concat(uk, ","), "themes,core_concepts,arguments",
        "union keys for unknown type")
    TestRunner:assertEqual(#Actions.xrayCategoryKeysFor("", "fiction"), 0, "empty selection")
end)

TestRunner:test("depth axis: nil and standard are the shipped wording, light/deep differ", function()
    local base = Actions.buildXrayCategoryPrompt(nil, "partial")
    TestRunner:assertEqual(Actions.buildXrayCategoryPrompt(nil, "partial", "standard"), base)
    TestRunner:assertEqual(Actions.buildXrayCategoryPrompt(nil, "partial", "bogus"), base)
    local light = Actions.buildXrayCategoryPrompt(nil, "partial", "light")
    local deep = Actions.buildXrayCategoryPrompt(nil, "partial", "deep")
    TestRunner:assertTrue(light ~= base and deep ~= base and light ~= deep)
    TestRunner:assertTrue(light:find("Only turning points", 1, true) ~= nil)
    TestRunner:assertTrue(deep:find("3-5 sentences", 1, true) ~= nil)
    -- No marker leaks at any depth
    for _i, p in ipairs({ base, light, deep }) do
        TestRunner:assertTrue(not p:find("__[A-Z_]+__"))
    end
    -- Depth composes with the category axis
    local lp = Actions.buildXrayCategoryPrompt("people", "complete", "light")
    TestRunner:assertTrue(lp:find("Leave out figures who appear once", 1, true) ~= nil)
    TestRunner:assertTrue(not lp:find('"timeline"', 1, true))
    TestRunner:assertEqual(Actions.normalizeXrayDepth("deep"), "deep")
    TestRunner:assertEqual(Actions.normalizeXrayDepth("standard"), nil)
    TestRunner:assertEqual(#Actions.XRAY_DEPTH_ORDER, 3)
end)

TestRunner:test("section prompt stays full", function()
    local sec = Actions.buildSectionXrayPrompt("Part 1", "pp 1-10", false)
    for _g, key in pairs(FICTION_KEYS) do
        assert(sec:find(key, 1, true), "section prompt missing " .. key)
    end
end)

local ok = TestRunner:summary()
return ok
