-- B353, the whole hand-off: a create the model built nothing from (at a book's
-- start, front matter) saves nothing and marks the config it ran on; the
-- checkpoint step (headless, via executeActionForResult) skips the step. B378:
-- the prompt no longer asks the model to name front matter (light models
-- answered it for the work itself), so the mark follows any create the model
-- declined or answered with no entries. B361: any X-Ray answer that saved
-- nothing marks the config too, and an attended run then shows the answer
-- instead of opening an X-Ray from disk. B362: a cut-off answer is one of
-- them, and a background update that saved nothing is a failure, never
-- "X-Ray updated".
--
-- The first build of this read the mark from a hand-picked meta copy that never
-- carried it, and its guard only checked that each side's source text existed,
-- so every checkpoint build still stopped at a front-matter step. These tests
-- run the real hand-off (Dialogs._headlessResult) and evaluate the readers' own
-- expressions, cut from the source, against what it returns.
--
-- Run: lua tests/unit/test_front_matter_flow.lua  (or lua tests/run_tests.lua --unit)

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
    return plugin_dir
end
local plugin_dir = setupPaths()
require("mock_koreader")
local Dialogs = require("koassistant_dialogs")
local TestRunner = require("test_runner"):new()

local function source(rel)
    local f = assert(io.open(plugin_dir .. "/" .. rel, "r"))
    local s = f:read("*a")
    f:close()
    return s
end
local dialogs_src = source("koassistant_dialogs.lua")
local main_src = source("main.lua")

--- A reader's expression, cut from the source and compiled as a function of
--- the one variable it reads.
local function readerFrom(src, pattern, var, what)
    local expr = src:match(pattern)
    assert(expr, what .. ": expression not found")
    return assert(load("local " .. var .. " = ...; return " .. expr, what))
end

--- What handlePredefinedPrompt's completion passes on success (content nil =
--- a reply with no text).
local function history(content)
    return { getMessages = function()
        return { { role = "user", content = "q" },
            { role = "assistant", content = content, model_info = { model = "m" } } }
    end }
end

-- The marks' names, from the lines that set them in the response handler
local MARK_COND, MARK = dialogs_src:match(
    "\n%s*if (not using_cache and not incomplete and parsed.-) then\n%s*temp_config%.([%w_]+) = true")
local NOT_SAVED = dialogs_src:match("if cache_answer == nil then\n%s*temp_config%.([%w_]+) = ")

print("\n  [the headless hand-off carries the request's config]")

TestRunner:test("the response handler marks the config it ran on", function()
    TestRunner:assertTrue(MARK, "a create that built nothing sets a mark on temp_config")
    TestRunner:assertTrue(NOT_SAVED, "an answer that saved nothing sets a mark on temp_config")
end)

TestRunner:test("the mark follows what the model answered, through the real parser (B378)", function()
    -- The handler's own condition, cut from the source
    local built_nothing = assert(load("local using_cache, incomplete, parsed, XrayParser = ...; return "
        .. MARK_COND:gsub("\n", " "), "dialogs mark condition"))
    local XrayParser = require("koassistant_xray_parser")
    local RP = require("koassistant_api.response_parser")
    local function marks(answer, using_cache)
        return built_nothing(using_cache or false, RP.isIncomplete(answer), XrayParser.parse(answer), XrayParser)
            and true or false
    end
    TestRunner:assertTrue(marks('{"error": "The extracted text is empty or unusable, so no X-Ray can be built from it."}'),
        "a create the model declined")
    TestRunner:assertTrue(marks("```json\n{\"error\": \"front_matter_only\"}\n```"), "any decline, fenced too")
    TestRunner:assertTrue(marks('{"type": "fiction", "characters": [], "current_state": {"summary": "Only front matter."}}'),
        "a create with no entries")
    TestRunner:assertFalse(marks('{"type": "fiction", "characters": [{"name": "Anna", "description": "A doctor."}]}'),
        "an X-Ray")
    TestRunner:assertFalse(marks('{"error": "The extracted text is empty or unusable."}', true),
        "an update: never (the chain has an X-Ray)")
    -- Cut before its first entry, the repair reads it as a whole answer with none
    local cut = '{"type": "fiction", "current_state": {"summary": "The story opens."}, "characters": [{"name": "An'
        .. RP.TRUNCATION_NOTICE
    TestRunner:assertTrue(XrayParser.parse(cut) and not XrayParser.hasEntityContent(XrayParser.parse(cut)),
        "fixture: parsed, no entries")
    TestRunner:assertFalse(marks(cut), "a cut-off answer: never (a longer slice cuts off too)")
    TestRunner:assertFalse(marks("I cannot build an X-Ray from this."), "prose: not parsed, not marked")
end)

TestRunner:test("the marks describe this request only", function()
    -- A re-run from a window builds its config from that window's (the earlier
    -- request's): its marks must not ride in
    local body = dialogs_src:match("local temp_config = createTempConfig%(prompt, config%)\n(.-)\n%s*if config and config%.features then")
    TestRunner:assertTrue(body, "the request's config is created")
    TestRunner:assertTrue(body:find("temp_config." .. MARK .. " = nil", 1, true), "built-nothing mark cleared")
    TestRunner:assertTrue(body:find("temp_config." .. NOT_SAVED .. " = nil", 1, true), "nothing-saved mark cleared")
end)

TestRunner:test("success: the reply, the old fields, and the very config the request ran on", function()
    local temp_config = { provider = "anthropic", features = {} }
    local text, meta = Dialogs._headlessResult(history("No X-Ray was built"), temp_config)
    TestRunner:assertEqual(text, "No X-Ray was built", "reply text")
    TestRunner:assertEqual(meta.model, "m", "model")
    TestRunner:assertEqual(meta.used_reasoning, false, "reasoning")
    TestRunner:assertEqual(meta.web_search_used, false, "web")
    TestRunner:assertTrue(meta.config == temp_config, "the config itself, so any mark arrives")
end)

TestRunner:test("failures pass through unchanged", function()
    local text, err = Dialogs._headlessResult(nil, "503 overloaded")
    TestRunner:assertEqual(text, nil, "no text")
    TestRunner:assertEqual(err, "503 overloaded", "the error")
    TestRunner:assertEqual(select(2, Dialogs._headlessResult(nil, nil)), "Unknown error", "no error given")
    TestRunner:assertEqual(select(2, Dialogs._headlessResult(history(nil), {})), "No response received",
        "no reply")
end)

TestRunner:test("executeActionForResult hands back exactly this", function()
    TestRunner:assertTrue(dialogs_src:find("on_result(headlessResult(history, temp_config_or_error))", 1, true),
        "the headless completion routes through headlessResult")
end)

print("\n  [the checkpoint step skips a step the model built nothing from]")

TestRunner:test("the step's own read finds the mark in the real hand-off", function()
    local read = readerFrom(main_src, "local nothing_built = (.-)\n%s*if nothing_built and create_mode",
        "meta_or_err", "main.lua nothing_built")
    local _text, meta = Dialogs._headlessResult(history("No X-Ray was built"), { [MARK] = true })
    TestRunner:assertTrue(read(meta), "marked: skip")
    local _t2, plain = Dialogs._headlessResult(history("{}"), {})
    TestRunner:assertFalse(read(plain), "unmarked: no skip")
    TestRunner:assertFalse(read("503 overloaded"), "an error string: no skip")
    TestRunner:assertFalse(read(nil), "nothing: no skip")
end)

TestRunner:test("and the skip is what it does with it", function()
    TestRunner:assertTrue(main_src:find(
        "if nothing_built and create_mode and XrayAuto.skipFrontMatterStep() then", 1, true),
        "create-mode steps skip on the mark")
    -- A step it cannot skip stops with a reason the popup names
    local stop = main_src:match('local err_text = %(nothing_built and "([^"]+)"%)')
    TestRunner:assertEqual(require("koassistant_xray_auto").classifyStopReason(stop), "nothing_built",
        "the stop text is the classifier's")
    TestRunner:assertTrue(main_src:find('if kind == "nothing_built" then return _(', 1, true), "and it has a label")
end)

print("\n  [an attended run shows the answer]")

TestRunner:test("the attended completion reads the nothing-saved mark", function()
    local read = readerFrom(dialogs_src, "local nothing_saved = (.-)\n", "temp_config",
        "dialogs nothing_saved")
    TestRunner:assertTrue(read({ [NOT_SAVED] = true }), "marked")
    TestRunner:assertFalse(read({}), "unmarked")
    TestRunner:assertFalse(read(nil), "no config")
end)

TestRunner:test("no branch opens an X-Ray from disk for it", function()
    for _idx, cond in ipairs({
        "if not nothing_saved and configuration and configuration.features and configuration.features._section_xray",
        "if action.cache_as_xray and not nothing_saved and ui",
        "if action.use_response_caching and not nothing_saved and action.id",
    }) do
        TestRunner:assertTrue(dialogs_src:find(cond, 1, true), cond)
    end
end)

print("\n  [a cut-off answer saves nothing, and nothing opens an older copy (B362)]")

local RP = require("koassistant_api.response_parser")

TestRunner:test("the parser's repair reads a cut-off answer as whole, so the X-Ray block checks the cut itself", function()
    local XrayParser = require("koassistant_xray_parser")
    local answer = '{"type": "fiction", "characters": [{"name": "Anna", "description": "A doctor."}, '
        .. '{"name": "Bert", "description": "Her bro' .. RP.TRUNCATION_NOTICE
    TestRunner:assertTrue(RP.isIncomplete(answer), "the notice marks it")
    local parsed = XrayParser.parse(answer)
    TestRunner:assertTrue(parsed and XrayParser.hasEntityContent(parsed), "the repair keeps the finished entries")
    TestRunner:assertTrue(dialogs_src:find("local incomplete = RP.isIncomplete(answer)", 1, true), "the cut is read once")
    local cut = dialogs_src:find("if incomplete then\n%s*xray_unusable = answer:find%(RP%.TRUNCATION_NOTICE")
    local mark = dialogs_src:find("if cache_answer == nil then\n%s*temp_config%." .. NOT_SAVED)
    TestRunner:assertTrue(cut and mark and cut < mark, "checked before the nothing-saved mark")
    local block = dialogs_src:sub(cut or 1, mark or 1)
    TestRunner:assertTrue(block:find("cache_answer = nil", 1, true), "nothing from it is saved")
    TestRunner:assertTrue(block:find("display_answer = RP.withNoticeOf(display_answer, answer)", 1, true),
        "its notice stays under the rendered part")
end)

TestRunner:test("any cut-off answer is marked: every write checks is_truncated, so nothing was saved", function()
    local body = dialogs_src:match("local is_truncated = ResponseParser%.isIncomplete%(answer%)\n(.-)\n%s*local book_text_was_provided")
    TestRunner:assertTrue(body and body:find("if is_truncated and not temp_config." .. NOT_SAVED .. " then", 1, true),
        "the mark follows the cut for every action")
end)

TestRunner:test("the notice survives rendering and the checkpoint step reads it (the real hand-off)", function()
    local raw = '{"characters": [{"name": "A"' .. RP.TRUNCATION_NOTICE
    local shown = RP.withNoticeOf("# X-Ray\n\nA", raw)
    TestRunner:assertTrue(RP.isIncomplete(shown), "the rendered answer still carries the cut")
    TestRunner:assertEqual(RP.withNoticeOf("# X-Ray", "{}"), "# X-Ray", "no notice: unchanged")
    TestRunner:assertEqual(RP.withNoticeOf(raw, raw), raw, "unrendered: never doubled")
    local expr = main_src:match("its notice rides the reply\n%s*local cut = (.-)\n%s*local err_text")
    TestRunner:assertTrue(expr, "the step's read is found")
    local read = assert(load("local result = ...; return " .. expr:gsub("\n", " ")))
    TestRunner:assertTrue(read((Dialogs._headlessResult(history(shown), {}))), "cut: the step names it")
    TestRunner:assertFalse(read((Dialogs._headlessResult(history("# X-Ray"), {}))), "whole: not")
    TestRunner:assertFalse(read(nil), "no reply: not")
    local kind = require("koassistant_xray_auto").classifyStopReason(
        main_src:match('or %(cut and "([^"]+)"%)'))
    TestRunner:assertEqual(kind, "cut_off", "the stop text is the classifier's")
end)

TestRunner:test("a background update that saved nothing is not reported as done, and a cut is named", function()
    local expr = main_src:match('elseif (result and not %(type%(meta_or_err%) == "table".-' .. NOT_SAVED .. '%)) then')
    TestRunner:assertTrue(expr, "the success test is found")
    local succeeded = assert(load("local result, meta_or_err = ...; return " .. expr:gsub("\n", " ")))
    TestRunner:assertFalse(succeeded(Dialogs._headlessResult(history("the X-Ray"),
        { [NOT_SAVED] = "the answer was cut off" })), "marked: a failure")
    TestRunner:assertTrue(succeeded(Dialogs._headlessResult(history("the X-Ray"), {})), "unmarked: done")
    TestRunner:assertFalse(succeeded(Dialogs._headlessResult(nil, "503 overloaded")), "an error: a failure")
    local msg = main_src:match('local msg = %(cut and "([^"]+)"%)')
    TestRunner:assertEqual(require("koassistant_xray_auto").classifyStopReason(msg), "cut_off",
        "the recorded reason is one the popup names")
end)

TestRunner:test("no completion opens an older copy for an answer that saved nothing", function()
    for _idx, cond in ipairs({
        -- executeDirectAction
        "if not action.interactive_quiz and not nothing_saved and configuration and configuration.features and configuration.features._section_scope and plugin then",
        "if (action.cache_as_analyze or action.cache_as_summary) and not nothing_saved and plugin then",
        -- the input dialog
        "local nothing_saved = temp_config and temp_config." .. NOT_SAVED,
        "if action.use_response_caching and not nothing_saved and action.id and plugin then",
    }) do
        TestRunner:assertTrue(dialogs_src:find(cond, 1, true), cond)
    end
    local _s, n = dialogs_src:gsub("if %(action%.cache_as_analyze or action%.cache_as_summary%) and not nothing_saved and plugin then", "")
    TestRunner:assertEqual(n, 2, "both analysis/summary openers (the input dialog and a direct run)")
end)

return TestRunner:summary()
