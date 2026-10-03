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

TestRunner:test("the type is the work's, never its front matter's (B337a)", function()
    -- Device 2026-09-28: a novella opening with an editor's introduction was
    -- typed nonfiction from that introduction, and the type sticks for the
    -- lineage. Every create prompt lets a known title and author decide the
    -- type, names front matter, and keeps the entries to the text.
    local x = Actions.book.xray
    local prompts = {
        x.prompt, x.complete_prompt,
        Actions.buildXrayCategoryPrompt("people", "partial"),
        Actions.buildXrayCategoryPrompt("people,events", "complete", "light"),
        Actions.buildSectionXrayPrompt("Part 1", "pp 1-10", false),
    }
    for _i, p in ipairs(prompts) do
        assert(p:find("decide whether the WORK is FICTION or NON-FICTION", 1, true),
            "the type sentence names the work")
        assert(p:find("that decides it", 1, true), "a known title and author decide the type")
        assert(p:find("never from front matter", 1, true), "front matter never decides it")
        assert(p:find("settle fiction or non-fiction, nothing else", 1, true),
            "knowledge settles the type only; the entries come from the text")
        assert(not p:find("First, determine if this is FICTION", 1, true), "the old sentence is gone")
    end
end)

TestRunner:test("aliases are names, never pronouns (B339)", function()
    -- Device 2026-09-28: a pronoun alias ("he") marked 39 of 45 pages
    local x = Actions.book.xray
    local Merge = require("koassistant_xray_merge")
    local prompts = {
        create = x.prompt, complete = x.complete_prompt, update = x.update_prompt,
        section = Actions.buildSectionXrayPrompt("Part 1", "pp 1-10", false),
        merge = Merge.COMPLETE_PROMPT, delta = Merge.DELTA_PROMPT,
        cross_book = Merge.CROSS_BOOK_DELTA_PROMPT,
    }
    for name, p in pairs(prompts) do
        assert(p:find("never pronouns", 1, true), name .. " prompt says aliases are never pronouns")
    end
end)

TestRunner:test("the checkpoint introduction keeps its instruction (B336)", function()
    -- v0.22.1: the fire site appended the premise-only clause to the action's
    -- prompt, and the category assembly then replaced that prompt whole, so
    -- every default introduction was a full X-Ray of rung 1's slice. The clause
    -- now has one home and is applied after every create-prompt swap.
    local clause = Actions.XRAY_INTRO_CLAUSE
    assert(type(clause) == "string" and clause:find("INTRODUCTORY X-RAY", 1, true), "one home for the clause")
    local here = debug.getinfo(1, "S").source:match("@?(.*)")
    local plugin_dir = here:match("(.+)/tests/unit/[^/]+$") or "."
    local function source(path)
        local f = assert(io.open(plugin_dir .. "/" .. path, "r"))
        local s = f:read("*a")
        f:close()
        return s
    end
    local main_src = source("main.lua")
    assert(not main_src:find("INTRODUCTORY X-RAY", 1, true), "main.lua no longer writes the clause")
    local dialogs = source("koassistant_dialogs.lua")
    local assembled = dialogs:find("PromptsActions.buildXrayCategoryPrompt(", 1, true)
    local applied = dialogs:find("PromptsActions.XRAY_INTRO_CLAUSE", 1, true)
    assert(assembled and applied, "both sites present in the request assembly")
    assert(applied > assembled, "the clause is applied after the category assembly")
end)

TestRunner:test("no create prompt asks the model to name front matter (B378)", function()
    -- B353 added a front-matter answer; light models gave it for the work
    -- itself (an author's own introduction, a slice with a whole chapter).
    -- Each create keeps only its decline, and a checkpoint step the model
    -- builds nothing from is skipped (test_front_matter_flow.lua)
    local x = Actions.book.xray
    -- Every create prompt a checkpoint step can send: the default, a narrowed
    -- or deeper assembly, a type the reader set, and the research track
    local creates = {
        default = x.prompt,
        narrowed = Actions.buildXrayCategoryPrompt("people,places", "partial"),
        light = Actions.buildXrayCategoryPrompt("people,places,ideas,terms", "partial", "light"),
        deep = Actions.buildXrayCategoryPrompt("people,places,ideas,terms", "partial", "deep"),
        fiction = Actions.applyXrayType(x.prompt, "fiction"),
        nonfiction = Actions.applyXrayType(x.prompt, "nonfiction"),
        academic = x.doi_prompt,
    }
    for name, p in pairs(creates) do
        assert(type(p) == "string" and not p:find("front_matter_only", 1, true), name .. ": no front-matter answer")
        assert(not p:find("none of the work itself", 1, true), name .. ": no front-matter question")
        local decline = name == "academic" and "cannot identify this as an academic paper"
            or "so no X-Ray can be built from it."
        assert(p:find(decline, 1, true), name .. ": its decline stays")
    end
    assert(creates.fiction ~= x.prompt and creates.nonfiction ~= x.prompt, "fixture: the type swaps applied")
    -- The endings as they were before the front-matter answer (58c22dc^)
    local tail = 'empty or unusable, so no X-Ray can be built from it."}'
    assert(x.prompt:sub(-#tail) == tail, "the create ends on its decline")
    assert(x.doi_prompt:find("broader field.\n\nIf you cannot identify", 1, true), "academic: the decline follows the web line")
    -- What happens to a create the model builds nothing from (the checkpoint
    -- skip, the attended viewer): test_front_matter_flow.lua
end)

TestRunner:test("a section X-Ray is built whatever the section holds: the reader picked it (B361)", function()
    for _idx, academic in ipairs({ false, true }) do
        local p = Actions.buildSectionXrayPrompt("Introduction", "pp. 1-12", academic)
        local name = academic and "academic section" or "section"
        assert(not p:find("front_matter_only", 1, true), name .. ": no front-matter answer")
        assert(p:find("respond with ONLY this JSON", 1, true), name .. ": its decline stays")
        assert(not p:find("%s$"), name .. ": no trailing whitespace")
    end
    assert(Actions.buildSectionXrayPrompt("I", "pp. 1-5", true):find("broader field.\n\nIf you cannot identify", 1, true),
        "academic section: the decline follows the web line")
end)

TestRunner:test("an X-Ray create carries its text's contents, after the placeholder pass (B337b)", function()
    local here = debug.getinfo(1, "S").source:match("@?(.*)")
    local plugin_dir = here:match("(.+)/tests/unit/[^/]+$") or "."
    local f = assert(io.open(plugin_dir .. "/koassistant_dialogs.lua", "r"))
    local dialogs = f:read("*a")
    f:close()
    local built = dialogs:find("local consolidated_message = buildConsolidatedMessage(prompt, context, message_data", 1, true)
    local outline = dialogs:find('require("koassistant_book_tools").xrayOutlineBlock(', 1, true)
    local added = dialogs:find("history:addUserMessage(consolidated_message, true)", 1, true)
    assert(built and outline and added, "all three sites present")
    assert(built < outline and outline < added, "appended to the built context message, before it is added")
end)

TestRunner:test("a type set for the book sends that schema alone (B337c)", function()
    local x = Actions.book.xray
    for _idx, case in ipairs({
        { x.prompt, "default" },
        { x.complete_prompt, "complete" },
        { Actions.buildXrayCategoryPrompt("people,events", "partial", "light"), "narrowed" },
    }) do
        local p, name = case[1], case[2]
        local f = Actions.applyXrayType(p, "fiction")
        local n = Actions.applyXrayType(p, "nonfiction")
        assert(f:find("FOR FICTION", 1, true) and not f:find("FOR NON-FICTION", 1, true), name .. ": fiction schema alone")
        assert(n:find("FOR NON-FICTION", 1, true) and not n:find("FOR FICTION,", 1, true), name .. ": nonfiction schema alone")
        assert(f:find("This work is FICTION", 1, true) and not f:find("First, decide", 1, true), name .. ": no type decision")
        assert(n:find("This work is NON-FICTION", 1, true), name .. ": nonfiction stated")
        -- The closing and the no-text answer survive; no front-matter answer
        for _k, s in ipairs({ n, f }) do
            assert(s:find("empty or unusable", 1, true) and not s:find("front_matter_only", 1, true), name .. ": decline kept")
            assert(s:find("JSON keys must remain in English", 1, true), name .. ": closing kept")
        end
    end
    assert(Actions.applyXrayType(x.prompt, "academic") == x.prompt, "academic is the research template, not a cut")
    assert(Actions.applyXrayType(x.prompt, nil) == x.prompt, "auto leaves the prompt alone")
    assert(Actions.applyXrayType("custom prompt", "fiction") == "custom prompt", "another shape comes back unchanged")
    assert(Actions.normalizeXrayType("academic") == "academic" and Actions.normalizeXrayType("auto") == nil, "normalize")
    -- Wiring: the type is resolved before the research swap and cut in after
    -- the category assembly, before the introduction clause
    local here = debug.getinfo(1, "S").source:match("@?(.*)")
    local plugin_dir = here:match("(.+)/tests/unit/[^/]+$") or "."
    local fh = assert(io.open(plugin_dir .. "/koassistant_dialogs.lua", "r"))
    local dialogs = fh:read("*a")
    fh:close()
    local resolved = dialogs:find(".resolveXrayType(per_book_ds, config.features)", 1, true)
    local swap = dialogs:find("if research_mode_active and prompt and prompt.doi_prompt then", 1, true)
    local assembled = dialogs:find("PromptsActions.buildXrayCategoryPrompt(xr_sel,", 1, true)
    local cut = dialogs:find("PromptsActions.applyXrayType(prompt.prompt, xray_type)", 1, true)
    local intro = dialogs:find("PromptsActions.XRAY_INTRO_CLAUSE", 1, true)
    assert(resolved and swap and assembled and cut and intro, "all sites present")
    assert(resolved < swap and assembled < cut and cut < intro, "resolved before the swap, cut after the categories")
    assert(dialogs:find("lineage_type == \"fiction\" or lineage_type == \"nonfiction\"", 1, true),
        "an update keeps its lineage's track")
end)

TestRunner:test("a section prompt with no settings passed is the full set", function()
    local sec = Actions.buildSectionXrayPrompt("Part 1", "pp 1-10", false)
    for _g, key in pairs(FICTION_KEYS) do
        assert(sec:find(key, 1, true), "section prompt missing " .. key)
    end
    assert(Actions.buildSectionXrayPrompt("Part 1", "pp 1-10", false, nil, nil) == sec, "nil settings: unchanged")
end)

TestRunner:test("a section X-Ray takes the book's categories, depth and type (B388)", function()
    local scope_line = 'Analyzing section "Part 1" (pp 1-10) of the document.'
    local sel = "people,places"
    local sec = Actions.buildSectionXrayPrompt("Part 1", "pp 1-10", false, sel)
    assert(sec:find(scope_line, 1, true), "the section's own scope line stays")
    assert(sec:find("Cover the section comprehensively", 1, true), "the section's own closing stays")
    for group, key in pairs(FICTION_KEYS) do
        local picked = (group == "people" or group == "places")
        assert((sec:find(key, 1, true) ~= nil) == picked, group .. (picked and ": kept" or ": left out"))
    end
    -- Depth: the section gains exactly what the depth adds to a new X-Ray
    local function lines(s) local t = {} for l in s:gmatch("[^\n]+") do t[l] = true end return t end
    local std = lines(Actions.buildXrayCategoryPrompt(sel, "partial"))
    local added = 0
    local sec_light = Actions.buildSectionXrayPrompt("Part 1", "pp 1-10", false, sel, "light")
    for l in pairs(lines(Actions.buildXrayCategoryPrompt(sel, "partial", "light"))) do
        if not std[l] and not l:find("I'm at", 1, true) then
            added = added + 1
            assert(sec_light:find(l, 1, true), "a light section carries the light wording: " .. l:sub(1, 60))
        end
    end
    assert(added > 0, "fixture: light depth changes the wording")
    -- Type: the reader's fiction or nonfiction pick cuts a section prompt too
    local f = Actions.applyXrayType(sec, "fiction")
    assert(f:find("This work is FICTION", 1, true) and not f:find("FOR NON-FICTION", 1, true), "fiction schema alone")
    assert(f:find(scope_line, 1, true), "the scope line survives the cut")
end)

TestRunner:test("the section X-Ray reaches the settings in the request assembly (B388, the real hand-off)", function()
    local here = debug.getinfo(1, "S").source:match("@?(.*)")
    local plugin_dir = here:match("(.+)/tests/unit/[^/]+$") or "."
    local function source(path)
        local fh = assert(io.open(plugin_dir .. "/" .. path, "r"))
        local s = fh:read("*a")
        fh:close()
        return s
    end
    local dialogs, main_src = source("koassistant_dialogs.lua"), source("main.lua")
    -- What main.lua hands over: the section action's id, and the scope on features
    assert(main_src:find('section_action.id = "section_xray"', 1, true), "the section action's id")
    assert(main_src:find("config_copy.features._section_xray = opts.section_xray", 1, true), "the scope on features")
    -- The assembly's own condition, cut from the source and run on it
    local expr = dialogs:match("local xray_dials = (.-)\n%s*local xray_type")
    assert(expr, "the settings condition is found")
    local dials = assert(load("local prompt, config = ...; return " .. expr:gsub("\n", " ")))
    local scope = { label = "Part 1", page_summary = "pp 1-10" }
    assert(dials({ id = "section_xray", cache_as_xray = false }, { features = { _section_xray = scope } }),
        "a section X-Ray follows the settings")
    assert(dials({ id = "xray", cache_as_xray = true }, { features = {} }), "a new X-Ray does")
    assert(not dials({ id = "xray", cache_as_xray = true }, { features = { _section_scope = scope } }),
        "the X-Ray action on another section scope does not")
    assert(not dials({ id = "key_arguments" }, { features = { _section_scope = scope } }), "other section actions do not")
    assert(not dials({ id = "section_xray" }, { features = {} }), "no scope, no section")
    assert(not dials(nil, { features = {} }), "no prompt")
    -- The category step builds the section's own prompt from that scope
    assert(dialogs:find("PromptsActions.buildSectionXrayPrompt(section.label, section.page_summary,", 1, true),
        "the section keeps its scope line with the book's settings")
end)

print("")
print("  [the status block as a switch (B271)]")

-- The schema example the model is shown for one type, as text
local function schemaOf(prompt, which)
    local head = which == "fiction" and "FOR FICTION, use this JSON schema:\n"
        or "FOR NON-FICTION, use this JSON schema:\n"
    local tail = which == "fiction" and "\n\nGuidance for fiction:" or "\n\nGuidance for non-fiction:"
    local s = assert(prompt:find(head, 1, true), "schema head")
    local e = assert(prompt:find(tail, s, true), "schema tail")
    return prompt:sub(s + #head, e - 1)
end

TestRunner:test("status on is the shipped prompt, byte for byte, however it is spelled", function()
    for _idx, which in ipairs({ "partial", "complete" }) do
        for _d, depth in ipairs({ "standard", "light", "deep" }) do
            local base = Actions.buildXrayCategoryPrompt("people,places", which, depth)
            assert(Actions.buildXrayCategoryPrompt("people,places", which, depth, nil) == base)
            assert(Actions.buildXrayCategoryPrompt("people,places", which, depth, "on") == base, "any value but off is on")
        end
    end
    assert(Actions.buildXrayCategoryPrompt(nil, "partial", nil, nil) == Actions.book.xray.prompt, "the default create prompt")
    assert(Actions.buildSectionXrayPrompt("Part 1", "pp 1-9", false, nil, nil, nil)
        == Actions.buildSectionXrayPrompt("Part 1", "pp 1-9", false, nil, nil), "the section prompt")
    assert(Actions.normalizeXrayStatus("off") == "off" and Actions.normalizeXrayStatus(false) == "off")
    assert(Actions.normalizeXrayStatus("on") == nil and Actions.normalizeXrayStatus(nil) == nil
        and Actions.normalizeXrayStatus(true) == nil, "everything else is on")
end)

TestRunner:test("status off: no status object in either schema, no guidance bullet, still valid JSON", function()
    local json = require("json")
    for _idx, which in ipairs({ "partial", "complete" }) do
        local p = Actions.buildXrayCategoryPrompt("people", which, nil, "off")
        for _k, key in ipairs({ '"current_state"', '"current_position"', '"conclusion"',
                "**Current State**", "**Current Position**", "**Conclusion**", "__" }) do
            assert(not p:find(key, 1, true), which .. " still carries " .. key)
        end
        assert(p:find('"characters"', 1, true) and p:find('"key_figures"', 1, true), "the categories stay")
        assert(p:find("**Connections and references**", 1, true), "and so does the rest of the guidance")
        for _t, kind in ipairs({ "fiction", "nonfiction" }) do
            local schema = schemaOf(p, kind)
            assert(not schema:find(",%s*}%s*$"), kind .. " schema ends on a dangling comma")
            assert(not schema:find("\n%s*\n"), kind .. " schema has a blank line where the status was")
            local ok_decode, decoded = pcall(json.decode, schema)
            assert(ok_decode and type(decoded) == "table" and decoded.type, kind .. " schema is not valid JSON")
        end
    end
    -- Same for a full category set and a depth
    local deep = Actions.buildXrayCategoryPrompt(nil, "partial", "deep", "off")
    assert(not deep:find('"current_state"', 1, true) and deep:find('"timeline"', 1, true))
    assert(pcall(json.decode, schemaOf(deep, "fiction")), "full set, deep, no status: valid JSON")
    -- And the shipped prompt's schema is valid too (the comma belongs to it)
    assert(pcall(json.decode, schemaOf(Actions.book.xray.prompt, "fiction")))
end)

TestRunner:test("status off: a section X-Ray drops its conclusion; the academic template never changes", function()
    local sec = Actions.buildSectionXrayPrompt("Part 1", "pp 1-9", false, "people", nil, "off")
    assert(not sec:find('"conclusion"', 1, true) and not sec:find("**Conclusion**", 1, true))
    assert(sec:find('Analyzing section "Part 1" (pp 1-9)', 1, true), "its scope line stays")
    assert(Actions.buildSectionXrayPrompt("Part 1", "pp 1-9", true, "people", nil, "off")
        == Actions.buildSectionXrayPrompt("Part 1", "pp 1-9", true), "academic ignores the switch, like the categories")
end)

TestRunner:test("status off: a set type still narrows the prompt to one schema", function()
    local p = Actions.applyXrayType(Actions.buildXrayCategoryPrompt("people", "partial", nil, "off"), "fiction")
    assert(p:find("This work is FICTION", 1, true) and not p:find("FOR NON-FICTION", 1, true))
    assert(not p:find('"current_state"', 1, true))
end)

TestRunner:test("status off: the update prompt asks for no status object and allows an empty answer", function()
    local x = Actions.book.xray
    for _idx, text in ipairs({ x.update_prompt, x.doi_update_prompt }) do
        assert(text:find("You MUST always include", 1, true), "the shipped line is there to replace")
        local off = Actions.xrayUpdateWithoutStatus(text)
        assert(not off:find("You MUST always include", 1, true), "the always-include line is gone")
        assert(off:find("This X-Ray keeps no status object", 1, true), "replaced in place")
        assert(off:find("output an empty JSON object: {}", 1, true), "nothing new has an answer")
        assert(#off > #text - 200 and off:find("{entity_index}", 1, true), "nothing else changed")
    end
    local custom = Actions.xrayUpdateWithoutStatus("Update it.")
    assert(custom:find("^Update it%.\n\nThis X%-Ray keeps no status object"), "a custom update prompt gets it appended")
end)

TestRunner:test("status off: the request assembly applies it, stamps it, and accepts an empty update", function()
    local info = debug.getinfo(1, "S")
    local root = info.source:match("@?(.*)/tests/unit/[^/]+$") or "."
    local f = assert(io.open(root .. "/koassistant_dialogs.lua", "r"))
    local dialogs = f:read("*a")
    f:close()
    -- A create builds its prompt with the resolved switch and stamps it
    assert(dialogs:find('"complete" or "partial", xr_depth, xr_status)', 1, true), "the create prompt takes the switch")
    assert(dialogs:find("false, xr_sel, xr_depth, xr_status)", 1, true), "and so does a section X-Ray")
    assert(dialogs:find("message_data._xray_status_applied = xr_status", 1, true), "stamped for the save")
    -- An update follows the X-Ray's own stamp, never the setting
    assert(dialogs:find("local cached_status = PromptsActions.normalizeXrayStatus(cached_entry.xray_status)", 1, true))
    assert(dialogs:find("prompt.prompt = PromptsActions.xrayUpdateWithoutStatus(prompt.prompt)", 1, true))
    -- All three saves carry the stamp (the live entry, a checkpoint, the X-Ray twin)
    local _s, n = dialogs:gsub("xray_status = message_data%._xray_status_applied", "")
    assert(n == 3, "three save sites, got " .. n)
    -- The empty answer: the parser's own test, run on what a model would send
    local XrayParser = require("koassistant_xray_parser")
    assert(XrayParser.isEmptyObject("{}") and XrayParser.isEmptyObject(" { }\n")
        and XrayParser.isEmptyObject("```json\n{}\n```"), "an empty object, bare or fenced")
    assert(not XrayParser.isEmptyObject('{"characters":[]}') and not XrayParser.isEmptyObject("")
        and not XrayParser.isEmptyObject(nil) and not XrayParser.isEmptyObject("nothing new"), "anything else is not")
    assert(dialogs:find('if not parsed and using_cache and message_data._xray_status_applied == "off"\n'
        .. '                        and XrayParser.isEmptyObject(answer) then\n'
        .. '                    parsed = {}', 1, true), "accepted only for an update of an X-Ray without a status block")
    -- Merged onto the old X-Ray it changes nothing
    local old = XrayParser.parse('{"type":"fiction","characters":[{"name":"A","description":"a"}]}')
    local merged = XrayParser.merge(old, {})
    assert(#merged.characters == 1 and merged.type == "fiction", "an empty delta leaves the X-Ray as it was")
end)

local ok = TestRunner:summary()
return ok
