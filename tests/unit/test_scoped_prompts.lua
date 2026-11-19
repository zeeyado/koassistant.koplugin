--[[
Unit tests: the prompt a run on part of the work sends (Actions.scopedPrompt, B741)

A built-in prompt speaks of the whole work. A run on one section, or on the part
read so far, used to put "Focus your analysis on this section only" in front of
"Summarize: <the work>" and "Cover the entire work evenly", so one request asked
for both. These tests guard:
- a run on a section names the section where the work was named and holds none of
  the sentences that ask for the whole work;
- a so-far run keeps its boundary line, says the reader's real position where the
  prompt says {reading_progress}, and asks for that part;
- a prompt without the fields (a custom action) keeps the line it always got;
- the fields and the prompts cannot drift apart (a pair whose words left the
  prompt, a section-capable action without the field);
- the two places that start such a run build the prompt through the one writer,
  and the runner's own lines, cut from the source, hand it the right kind.

Run: lua tests/unit/test_scoped_prompts.lua  (auto-discovered by run_tests.lua --unit)
]]

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
-- The minimal KOReader surface the cache module needs to load (its list of
-- section groups is all this file reads), installed only when another test
-- file has not already stubbed it in this process.
package.loaded["docsettings"] = package.loaded["docsettings"] or {
    getSidecarDir = function(_self, _doc_path) return "/nonexistent/book.sdr" end,
    isHashLocationEnabled = function() return false end,
}
package.loaded["util"] = package.loaded["util"] or { makePath = function() end }
package.loaded["luasettings"] = package.loaded["luasettings"] or {
    open = function() return { readSetting = function() return nil end, close = function() end } end,
}
_G.G_reader_settings = _G.G_reader_settings or {
    readSetting = function(_self, _key, default) return default end,
    saveSetting = function() end,
    flush = function() end,
}

local Actions = require("koassistant.prompts.actions")
local ActionCache = require("koassistant.artifacts.action_cache")
local TestRunner = require("test_runner"):new()

print("Running: test_scoped_prompts")
print("")
print("  [The prompt of a run on part of the work]")

local SUBJECT = '"{title}"{author_clause}'
local SECTION = { kind = "section", label = "Part Two", pages = "pp 40–62" }
local SECTION_SUBJECT = 'the section "Part Two" (pp 40–62) of ' .. SUBJECT
local NEW_LEAD = "This request is about one section of a longer work, not the whole work.\n\n"
local BOUNDARY = "Cover only material up to this point — do not use, reference, or reveal anything beyond it (no later events, results, or conclusions).\n\n"

local function count(text, needle)
    local n, from = 0, 1
    while true do
        local s, e = text:find(needle, from, true)
        if not s then return n end
        n, from = n + 1, e + 1
    end
end

local function readSource(module_name)
    local path = assert(package.searchpath(module_name, package.path), module_name .. " not found")
    local f = assert(io.open(path, "r"))
    local src = f:read("*a")
    f:close()
    return src
end

-- The built-ins that can run on a section, by the section groups the cache knows
local SECTION_ACTION_IDS = {}
for key in pairs(ActionCache.SECTION_PREFIXES) do
    if key ~= "xray" then
        local id = key
        if key == "summary" then id = "summarize_full_document" end
        if key == "analyze" then id = "analyze_full_document" end
        SECTION_ACTION_IDS[#SECTION_ACTION_IDS + 1] = id
    end
end
table.sort(SECTION_ACTION_IDS)

TestRunner:test("every action that can run on a section names the section in its own first line", function()
    TestRunner:assertEqual(#SECTION_ACTION_IDS, 8, "eight section groups besides the X-Ray's")
    for _idx, id in ipairs(SECTION_ACTION_IDS) do
        local action = Actions.getById(id)
        assert(action, id .. " is a built-in")
        TestRunner:assertEqual(action.section_subject, true, id .. " has section_subject")
        assert(action.prompt:find(SUBJECT, 1, true), id .. ": the prompt names the work as " .. SUBJECT)
    end
end)

TestRunner:test("every pair of part_wording is in its prompt, once", function()
    local seen = 0
    for _ctx, group in pairs(Actions.getAllBuiltin()) do
        for id, action in pairs(group) do
            if type(action) == "table" and action.part_wording then
                for i, pair in ipairs(action.part_wording) do
                    seen = seen + 1
                    local where = id .. " pair " .. i
                    assert(type(pair.whole) == "string" and pair.whole ~= "", where .. ": no whole text")
                    TestRunner:assertEqual(count(action.prompt, pair.whole), 1, where .. ": the whole text is in the prompt once")
                    assert(pair.part or pair.section or pair.so_far, where .. ": nothing to say instead")
                    for _k, key in ipairs({ "part", "section", "so_far" }) do
                        assert(pair[key] == nil or type(pair[key]) == "string", where .. ": " .. key .. " is text")
                    end
                end
            end
        end
    end
    assert(seen >= 8, "the pairs were found (" .. seen .. ")")
end)

TestRunner:test("a run on a section: the section stands where the work stood, and nothing asks for the whole work", function()
    for _idx, id in ipairs(SECTION_ACTION_IDS) do
        local action = Actions.getById(id)
        local before = action.prompt
        local out = Actions.scopedPrompt(action, SECTION)
        TestRunner:assertEqual(out:sub(1, #NEW_LEAD), NEW_LEAD, id .. ": the lead")
        assert(out:find(SECTION_SUBJECT, 1, true), id .. ": the section is the subject")
        TestRunner:assertEqual(count(out, SUBJECT), count(before, SUBJECT), id .. ": the work is still named, inside the section's phrase")
        TestRunner:assertEqual(count(out, SECTION_SUBJECT), 1, id .. ": the section is named once")
        for _k, gone in ipairs({ "entire work", "complete work", "the full text", "on this section only",
                "{reading_progress}" }) do
            TestRunner:assertEqual(out:find(gone, 1, true), nil, id .. ': no "' .. gone .. '"')
        end
        -- Pure: the action keeps its prompt
        TestRunner:assertEqual(action.prompt, before, id .. ": the action is untouched")
    end
end)

TestRunner:test("Document Summary on a section asks for that part, as a stand-in for that part", function()
    local action = Actions.getById("summarize_full_document")
    assert(action.prompt:find("Cover the entire work evenly from beginning to end", 1, true),
        "the whole run still asks for the whole work")
    local out = Actions.scopedPrompt(action, SECTION)
    assert(out:find("Summarize: " .. SECTION_SUBJECT .. ".{doi_clause}", 1, true), "the first line")
    assert(out:find("Cover that part evenly from beginning to end", 1, true), "even coverage of the part")
    assert(out:find("leave out the rest of the work", 1, true), "the rest left out")
    assert(out:find("a stand-in for that part's text in future queries and analysis, so preserve key details", 1, true),
        "the sentence still joins what follows it")
    assert(out:find("{full_document_section}", 1, true), "the text placeholder is where it was")
end)

TestRunner:test("the other section wordings", function()
    local function section(id) return Actions.scopedPrompt(Actions.getById(id), SECTION) end
    assert(section("counterarguments"):find("Make the strongest case against what is argued in " .. SECTION_SUBJECT, 1, true),
        "counterarguments")
    assert(section("analyze_full_document"):find("Analyze this part of a document: " .. SECTION_SUBJECT, 1, true), "analysis")
    assert(section("extract_insights"):find("worth taking away from this part of the work.", 1, true), "insights")
    assert(section("discussion_questions"):find("Note: These are questions for the part named above alone. ", 1, true),
        "discussion questions")
    assert(section("quiz"):find("Create a comprehension quiz for " .. SECTION_SUBJECT .. ".", 1, true), "quiz")
    assert(section("key_arguments"):find("Analyze the main arguments in " .. SECTION_SUBJECT .. ".", 1, true), "key arguments")
end)

TestRunner:test("Reading Guide on a section is a guide to that section, with no position of the whole work", function()
    local out = Actions.scopedPrompt(Actions.getById("reading_guide"), SECTION)
    assert(out:find("reading guide for what lies ahead in " .. SECTION_SUBJECT, 1, true), "the subject")
    assert(out:find("I am about to read this section.", 1, true), "about to read it")
    assert(out:find("Help me read this section attentively:", 1, true), "the ask")
    assert(out:find("Do not give away how this section turns out or what it concludes.", 1, true), "the spoiler line")
    TestRunner:assertEqual(out:find("I'm at", 1, true), nil, "no position line")
end)

TestRunner:test("a so-far run: the boundary line, the real position, the part asked for", function()
    local summary = Actions.getById("summarize_full_document")
    local out = Actions.scopedPrompt(summary, { kind = "so_far", position = "42%", label = "Up to 42%" })
    local lead = "This concerns " .. SUBJECT .. " only up to the reader's current position (42%).\n" .. BOUNDARY
    TestRunner:assertEqual(out:sub(1, #lead), lead, "the lead names the position, not the scope's label")
    assert(out:find('Summarize: ' .. SUBJECT .. '.{doi_clause}', 1, true), "the work is still the subject")
    assert(out:find("Cover that part evenly", 1, true), "the part is asked for")
    TestRunner:assertEqual(out:find("entire work", 1, true), nil, "the whole work is not")

    -- The section pipeline resolves {reading_progress} to 100%: a so-far run says the real position
    local guide = Actions.scopedPrompt(Actions.getById("reading_guide"), { kind = "so_far", position = "7%" })
    assert(guide:find("I'm at 7%.", 1, true), "the position line")
    assert(guide:find("CRITICAL: No spoilers beyond 7%.", 1, true), "the spoiler line")
    TestRunner:assertEqual(guide:find("{reading_progress}", 1, true), nil, "no placeholder left for the pipeline's 100%")
    assert(guide:find("what lies ahead in " .. SUBJECT, 1, true), "a so-far guide is about the work ahead, not about a section")

    local chapter = Actions.scopedPrompt(Actions.getById("quiz"),
        { kind = "section_so_far", section = "Chapter 9", position = "61%" })
    local chapter_lead = 'This concerns the section "Chapter 9" of ' .. SUBJECT
        .. ", and only up to the reader's current position (61% of the whole work).\n" .. BOUNDARY
    TestRunner:assertEqual(chapter:sub(1, #chapter_lead), chapter_lead, "a section so far")
end)

TestRunner:test("a prompt without the fields keeps the line it always got", function()
    local custom = { id = "config_1", prompt = 'Review "{title}"{author_clause}.\n\n{full_document_section}\n\nI am at {reading_progress}.' }
    local section = Actions.scopedPrompt(custom, SECTION)
    TestRunner:assertEqual(section,
        'This is a section of "{title}"{author_clause}.\nSection: "Part Two" (pp 40–62)\nFocus your analysis on this section only.\n\n'
        .. custom.prompt, "a section run, byte for byte")
    local so_far = Actions.scopedPrompt(custom, { kind = "so_far", label = "Up to 42%" })
    TestRunner:assertEqual(so_far,
        'This concerns "{title}"{author_clause} only up to the reader\'s current position (Up to 42%).\n' .. BOUNDARY
        .. custom.prompt, "a so-far run without a position falls back to the label and leaves the placeholder")
    local placed = Actions.scopedPrompt(custom, { kind = "so_far", position = "42%" })
    assert(placed:find("I am at 42%.", 1, true), "with a position, the prompt says it")

    -- A built-in whose prompt the reader rewrote: the pairs find nothing, the line stays
    local rewritten = { id = "summarize_full_document", section_subject = true,
        part_wording = Actions.getById("summarize_full_document").part_wording,
        prompt = "Tell me what happens.\n\n{full_document_section}" }
    local out = Actions.scopedPrompt(rewritten, SECTION)
    TestRunner:assertEqual(out:sub(1, 20), "This is a section of", "no subject to rewrite: the old line")
    assert(out:find("Tell me what happens.", 1, true), "the reader's prompt as written")

    TestRunner:assertEqual(Actions.scopedPrompt({ id = "x" }, SECTION), nil, "no prompt, nothing")
    TestRunner:assertEqual(Actions.scopedPrompt(custom, nil), custom.prompt, "no scope, the prompt")
end)

TestRunner:test("both places that start such a run build the prompt through the one writer", function()
    local main_src = readSource("main")
    local dialogs_src = readSource("koassistant.ui.dialogs")
    for name, src in pairs({ ["main.lua"] = main_src, ["dialogs.lua"] = dialogs_src }) do
        TestRunner:assertEqual(src:find("on this section only", 1, true), nil, name .. " writes no scope line of its own")
        TestRunner:assertEqual(src:find("only up to the reader", 1, true), nil, name .. " writes no so-far line of its own")
        assert(src:find("scopedPrompt(section_action,", 1, true), name .. " calls the writer")
    end

    -- The runner's own lines, cut from the source and run: each framing hands the writer its kind
    local a = assert(main_src:find("    local prompt_scope\n", 1, true), "the runner's scope lines")
    local tail = "scopedPrompt(section_action, prompt_scope)\n"
    local b = assert(main_src:find(tail, a, true), "the runner's call")
    local block = main_src:sub(a, b + #tail - 1)
    local load_fn = loadstring or load
    local run = assert(load_fn("return function(opts, label, scope, section_action)\n" .. block
        .. "    return section_action.prompt, prompt_scope\nend"))()
    local function runner(opts)
        local action = {}
        for k, v in pairs(Actions.getById("summarize_full_document")) do action[k] = v end
        return run(opts, "Part Two", { page_summary = "pp 40–62" }, action)
    end
    local prompt, scope = runner({ source_mode = "full_text" })
    TestRunner:assertEqual(scope.kind, "section", "a section")
    assert(prompt:find("Summarize: " .. SECTION_SUBJECT, 1, true), "the section run's prompt")
    prompt, scope = runner({ read_so_far = true, position = "42%" })
    TestRunner:assertEqual(scope.kind, "so_far", "up to the position")
    assert(prompt:find("current position (42%)", 1, true), "the so-far run's prompt")
    prompt, scope = runner({ section_so_far = { section = "Chapter 9", position = "61%" } })
    TestRunner:assertEqual(scope.kind, "section_so_far", "a section so far")
    assert(prompt:find('the section "Chapter 9" of', 1, true) and prompt:find("(61% of the whole work)", 1, true),
        "the section-so-far run's prompt")

    -- The popup's "Up to current position" hands the position over with the run
    assert(main_src:find("read_so_far = true, data_once = state.data_once,\n                    position = reading_progress.formatted })", 1, true),
        "the popup passes the reading percentage")
end)

local ok = TestRunner:summary()
return ok
