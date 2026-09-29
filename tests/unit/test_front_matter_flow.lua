-- B353, the whole hand-off: a create whose text held only front matter saves
-- nothing and marks the config it ran on; the checkpoint step (headless, via
-- executeActionForResult) skips the step, and an attended run shows the answer
-- instead of opening an X-Ray from disk.
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

-- The mark's name, from the line that sets it in the response handler
local MARK = dialogs_src:match(
    "temp_config%.([%w_]+) = true\n%s*logger%.dbg%(\"KOAssistant: X%-Ray found only front matter")

print("\n  [the headless hand-off carries the request's config]")

TestRunner:test("the response handler marks the config it ran on", function()
    TestRunner:assertTrue(MARK, "the front-matter branch sets a mark on temp_config")
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

print("\n  [the checkpoint step skips a front-matter step]")

TestRunner:test("the step's own read finds the mark in the real hand-off", function()
    local read = readerFrom(main_src, "local front_matter = (.-)\n%s*if front_matter and create_mode",
        "meta_or_err", "main.lua front_matter")
    local _text, meta = Dialogs._headlessResult(history("No X-Ray was built"), { [MARK] = true })
    TestRunner:assertTrue(read(meta), "marked: skip")
    local _t2, plain = Dialogs._headlessResult(history("{}"), {})
    TestRunner:assertFalse(read(plain), "unmarked: no skip")
    TestRunner:assertFalse(read("503 overloaded"), "an error string: no skip")
    TestRunner:assertFalse(read(nil), "nothing: no skip")
end)

TestRunner:test("and the skip is what it does with it", function()
    TestRunner:assertTrue(main_src:find(
        "if front_matter and create_mode and XrayAuto.skipFrontMatterStep() then", 1, true),
        "create-mode steps skip on the mark")
end)

print("\n  [an attended run shows the answer]")

TestRunner:test("the attended completion reads the same mark", function()
    local read = readerFrom(dialogs_src, "local nothing_saved = (.-)\n", "temp_config",
        "dialogs nothing_saved")
    TestRunner:assertTrue(read({ [MARK] = true }), "marked")
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

return TestRunner:summary()
