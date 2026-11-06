-- Source guards for the 2026-11-06 sweep's main.lua fixes (batch A, items
-- A10 to A13 in docs/sweep_2026-11-06.md): the dictionary popup's local
-- actions and the bypass run on a scrubbed copy of the configuration, never
-- the shared table; the book-level direct run scrubs its copy; the Analyze
-- Notes popup acts on its own book; Add custom model goes through
-- switchModel and the removals guard the provider.
--
-- Run: lua tests/unit/test_sweep_guards.lua  (or lua tests/run_tests.lua --unit)

local function setupPaths()
    local info = debug.getinfo(1, "S")
    local script_path = info.source:match("@?(.*)")
    local unit_dir = script_path:match("(.+)/[^/]+$") or "."
    local tests_dir = unit_dir:match("(.+)/[^/]+$") or "."
    local plugin_dir = tests_dir:match("(.+)/[^/]+$") or "."
    package.path = table.concat({
        plugin_dir .. "/?.lua", tests_dir .. "/?.lua", tests_dir .. "/lib/?.lua", package.path,
    }, ";")
    return plugin_dir
end
local plugin_dir = setupPaths()
require("mock_koreader")
local TestRunner = require("test_runner"):new()

local function read(rel)
    local f = assert(io.open(plugin_dir .. "/" .. rel, "r"))
    local s = f:read("*a")
    f:close()
    return s
end
local function fnBody(src, name)
    local a = src:find("function AskGPT:" .. name .. "%(")
    assert(a, name)
    local b = src:find("\nfunction AskGPT:", a + 10) or #src
    return src:sub(a, b)
end
local main = read("main.lua")

print("Running: test_sweep_guards")
print("")
print("  [the dictionary popup and the bypass run local actions on a scrubbed copy]")

TestRunner:test("executeDictAction's local branch hands a scrubbed copy to executeDirectAction", function()
    local body = fnBody(main, "executeDictAction")
    TestRunner:assertTrue(body:find("self:_scrubContextFeatures(local_config.features)", 1, true) ~= nil, "the copy is scrubbed")
    TestRunner:assertTrue(body:find("Dialogs.executeDirectAction(self.ui, action, word, local_config, self,", 1, true) ~= nil, "the copy is passed")
    TestRunner:assertTrue(body:find("configuration.features._source_widget = dict_popup", 1, true) == nil, "nothing written on the shared table")
end)

TestRunner:test("the bypass's local branch does the same", function()
    local body = fnBody(main, "syncDictionaryBypass")
    TestRunner:assertTrue(body:find("self_ref:_scrubContextFeatures(local_config.features)", 1, true) ~= nil, "scrubbed")
    TestRunner:assertTrue(body:find("Dialogs.executeDirectAction(self_ref.ui, bypass_action, clean_word, local_config, self_ref,", 1, true) ~= nil, "the copy is passed")
end)

TestRunner:test("the scrub forgets the popup reference", function()
    local body = fnBody(main, "_scrubContextFeatures")
    TestRunner:assertTrue(body:find("features._source_widget = nil", 1, true) ~= nil)
end)

print("")
print("  [the book-level direct run and the Analyze Notes popup]")

TestRunner:test("_executeBookLevelActionDirect scrubs its copy before marking the book context", function()
    local body = fnBody(main, "_executeBookLevelActionDirect")
    local s = body:find("self:_scrubContextFeatures(config_copy.features)", 1, true)
    local b = body:find("config_copy.features.is_book_context = true", 1, true)
    TestRunner:assertTrue(s ~= nil and b ~= nil and s < b, "scrub first, then is_book_context")
end)

TestRunner:test("the Analyze Notes popup's View and requirement checks name its own book", function()
    local body = fnBody(main, "_showAnalyzeNotesScopePopup")
    TestRunner:assertTrue(body:find("viewCachedAction(action, action_id, cached_entry,\n          { file = target_file", 1, true) ~= nil, "View passes the book")
    local n = select(2, body:gsub("_checkRequirements%(action, target_file,", ""))
    TestRunner:assertEqual(n, 3)
    TestRunner:assertTrue(body:find("_checkRequirements(action, nil,", 1, true) == nil, "no open-book judgement left")
end)

print("")
print("  [custom models in another provider's panel]")

TestRunner:test("Add custom model goes through switchModel; the removals guard the provider", function()
    TestRunner:assertTrue(main:find("self_ref:switchModel(provider, new_model, provider_display_name)", 1, true) ~= nil, "the Add callback switches")
    local body = fnBody(main, "removeCustomModel")
    TestRunner:assertTrue(body:find("if self:getCurrentProvider() == provider and self:getCurrentModel() == model then", 1, true) ~= nil, "remove guards the provider")
    TestRunner:assertTrue(main:find("local was_custom = self_ref:getCurrentProvider() == provider\n            and self_ref:isCustomModel(provider, current_model)", 1, true) ~= nil, "Clear all guards the provider")
end)

return TestRunner:summary()
