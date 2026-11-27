-- The translation language is ONE control, and every door runs the reader's
-- Translate.
--
-- Settings showed a switch ("Translate to Primary Language") and, under it, a
-- list whose first row was that same choice. Unticking the switch alone
-- changed nothing (the stored language was still the "follow" value), and
-- the list, the Settings row and the resolver each spelled the rule: a stored
-- language whose switch had never been written was ticked in the list while
-- translations went into the primary language. Now there is the list alone,
-- and one rule (SystemPrompts.translationFollowsPrimary) that the resolver,
-- the row's label and the list's ticks all read. The list is main.lua's own
-- buildTranslationLanguageMenu, cut from the source and run on a stand-in.
--
-- And Translate Page and the Translate row of a window's selection popup ran
-- the shipped Translate whatever the reader had set in the action's editor
-- (a stronger model, a behavior), where the highlight menu and the bypass ran
-- the edited one (B438).
--
-- Run: lua tests/unit/test_translate_settings.lua  (or lua tests/run_tests.lua --unit)

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
local PLUGIN_DIR = setupPaths()
require("mock_koreader")
local TestRunner = require("test_runner"):new()

print("")
print(string.rep("=", 50))
print("  The translation language, and whose Translate runs")
print(string.rep("=", 50))

local SystemPrompts = require("koassistant.prompts.system_prompts")
local Schema = require("koassistant.ui.settings_schema")
local T = require("ffi/util").template
local _ = require("koassistant.core.gettext")

local function source(rel)
    local handle = assert(io.open(PLUGIN_DIR .. "/" .. rel, "r"))
    local text = handle:read("*a")
    handle:close()
    return text
end
local main_src = source("main.lua")
local function cut(name)
    local s = main_src:find("\nfunction AskGPT:" .. name .. "(", 1, true)
    assert(s, "main.lua has no AskGPT:" .. name)
    local e = assert(main_src:find("\nend\n", s, true))
    return main_src:sub(s + 1, e + 4)
end

-- a plugin as the Settings rows and the list see it
local function plugin(features, methods)
    local store = { features = features }
    local p = {
        settings = {
            readSetting = function(_self, key) return store[key] end,
            saveSetting = function(_self, key, value) store[key] = value end,
            flush = function() end,
        },
        getEffectivePrimaryLanguage = function() return "English" end,
        getCombinedLanguages = function() return { "English", "French", "German" } end,
        getLanguageDisplay = function(_self, lang) return lang end,
    }
    for name, fn in pairs(methods or {}) do p[name] = fn end
    return p, store
end

local function row(id, items)
    for _idx, item in ipairs(items or Schema.items) do
        if item.id == id then return item end
        local below = item.items and row(id, item.items)
        if below then return below end
    end
    return nil
end

-- The stored states a reader can be in: what was written by the list, by the
-- old switch alone, or never.
local STATES = {
    { name = "nothing stored",                           f = {},                                                                       follows = true },
    { name = "the list's Follow Primary row",            f = { translation_use_primary = true, translation_language = "__PRIMARY__" }, follows = true },
    { name = "a language picked in the list",            f = { translation_use_primary = false, translation_language = "French" },     follows = false },
    { name = "the old switch unticked, nothing picked",  f = { translation_use_primary = false, translation_language = "__PRIMARY__" }, follows = true },
    { name = "a language stored, the switch never",      f = { translation_language = "French" },                                      follows = true },
    { name = "the switch ticked over a stored language", f = { translation_use_primary = true, translation_language = "French" },      follows = true },
    { name = "an empty language",                        f = { translation_use_primary = false, translation_language = "" },           follows = true },
}

TestRunner:test("one rule says whether translations follow the primary language, and the resolver reads it", function()
    for _idx, state in ipairs(STATES) do
        TestRunner:assertEqual(SystemPrompts.translationFollowsPrimary(state.f), state.follows, state.name)
        local config = { user_languages = "English, German" }
        for k, v in pairs(state.f) do config[k] = v end
        TestRunner:assertEqual(SystemPrompts.getEffectiveTranslationLanguage(config),
            state.follows and "English" or "French", state.name .. ": what a translation uses")
    end
    TestRunner:assertEqual(SystemPrompts.translationFollowsPrimary(nil), true, "no settings at all")
end)

TestRunner:test("Settings has the list alone: no switch beside it, the row never greyed", function()
    TestRunner:assertEqual(row("translation_use_primary"), nil, "the switch is gone")
    local list = row("translation_language")
    TestRunner:assertTrue(list ~= nil, "the list's row")
    TestRunner:assertEqual(list.depends_on, nil, "nothing greys it")
    TestRunner:assertEqual(list.callback, "buildTranslationLanguageMenu")
    -- the key the list writes still has no default of its own: unset reads as follow
    TestRunner:assertEqual(Schema.getDefaults().translation_use_primary, nil)
end)

TestRunner:test("the row names the language a translation uses, under one name", function()
    local list = row("translation_language")
    for _idx, state in ipairs(STATES) do
        local expected = state.follows and "Translation Language: Follow Primary (English)" or "Translation Language: French"
        TestRunner:assertEqual(list.text_func(plugin(state.f)), expected, state.name)
    end
end)

TestRunner:test("the dictionary's row has the same name everywhere and says what it follows", function()
    local dict = row("dictionary_language")
    TestRunner:assertEqual(dict.text_func(plugin({})), "Dictionary Language: Follow Translation (English)")
    TestRunner:assertEqual(dict.text_func(plugin({ translation_use_primary = false, translation_language = "French" })),
        "Dictionary Language: Follow Translation (French)", "the translation language a lookup follows")
    TestRunner:assertEqual(dict.text_func(plugin({ dictionary_language = "__FOLLOW_TRANSLATION__", translation_language = "French" })),
        "Dictionary Language: Follow Translation (English)", "a stored language whose switch was never written is not used")
    TestRunner:assertEqual(dict.text_func(plugin({ dictionary_language = "__FOLLOW_PRIMARY__", translation_use_primary = false,
        translation_language = "French" })), "Dictionary Language: Follow Primary (English)")
    TestRunner:assertEqual(dict.text_func(plugin({ dictionary_language = "German" })), "Dictionary Language: German")
    local schema_src = source("koassistant/ui/settings_schema.lua")
    TestRunner:assertEqual(schema_src:find('_("Response Language', 1, true), nil, "the old name")
    TestRunner:assertEqual(schema_src:find('_("Translation Target', 1, true), nil, "the old name")
end)

-- main.lua's list, cut and run
local shown = {}
local chunk = table.concat({
    "local UIManager, Notification, T, _, getLanguageDisplay = ...",
    "local AskGPT = {}",
    cut("buildTranslationLanguageMenu"),
    "return AskGPT",
}, "\n")
local AskGPT = assert(load(chunk, "=main.lua (cut)"))(
    { show = function(_self, widget) shown[#shown + 1] = widget end, close = function() end },
    { new = function(_self, o) return o end }, T, _, function(lang) return lang end)

local function ticked(items)
    local names = {}
    for _idx, item in ipairs(items) do
        if item.radio and item.checked_func() then names[#names + 1] = item.text end
    end
    return table.concat(names, " + ")
end
local function tap(items, text)
    for _idx, item in ipairs(items) do
        if item.text == text then return item.callback() end
    end
    error("no row " .. text)
end

TestRunner:test("the list ticks what a translation uses, in every stored state", function()
    for _idx, state in ipairs(STATES) do
        local features = {}
        for k, v in pairs(state.f) do features[k] = v end
        local p = plugin(features, { buildTranslationLanguageMenu = AskGPT.buildTranslationLanguageMenu })
        local items = p:buildTranslationLanguageMenu()
        TestRunner:assertEqual(ticked(items), state.follows and "Follow Primary (English)" or "French", state.name)
    end
end)

TestRunner:test("a pick in the list is the whole change: the language, then back to following", function()
    local p, store = plugin({}, { buildTranslationLanguageMenu = AskGPT.buildTranslationLanguageMenu })
    local items = p:buildTranslationLanguageMenu()
    tap(items, "French")
    TestRunner:assertEqual(store.features.translation_language, "French")
    TestRunner:assertEqual(store.features.translation_use_primary, false)
    TestRunner:assertEqual(ticked(items), "French", "one row ticked")
    TestRunner:assertEqual(SystemPrompts.getEffectiveTranslationLanguage(store.features), "French")
    TestRunner:assertEqual(row("translation_language").text_func(p), "Translation Language: French", "and the row says it")
    tap(items, "Follow Primary (English)")
    TestRunner:assertEqual(store.features.translation_language, "__PRIMARY__")
    TestRunner:assertEqual(store.features.translation_use_primary, true)
    TestRunner:assertEqual(ticked(items), "Follow Primary (English)")
    TestRunner:assertEqual(SystemPrompts.translationFollowsPrimary(store.features), true)
end)

TestRunner:test("nobody but the rule compares the stored switch", function()
    local list = assert(io.popen('cd "' .. PLUGIN_DIR .. '" && ls main.lua && find koassistant -name "*.lua" | LC_ALL=C sort'))
    local others = {}
    for rel in list:lines() do
        if rel ~= "koassistant/prompts/system_prompts.lua" and source(rel):find("translation_use_primary%s*[=~]=") then
            others[#others + 1] = rel
        end
    end
    list:close()
    TestRunner:assertEqual(table.concat(others, ", "), "", "a second spelling of the rule")
end)

-- Whose Translate runs. The service's copy carries what the reader set in the
-- action's editor; the two doors that took the shipped table now ask it.
TestRunner:test("the action service hands out Translate with the reader's edits", function()
    local ActionService = require("koassistant.prompts.action_service")
    local Actions = require("koassistant.prompts.actions")
    local data = { builtin_action_overrides = { ["highlight:translate"] = { provider = "anthropic", model = "a-stronger-model" } } }
    local service = ActionService:new({
        readSetting = function(_self, key) return data[key] end,
        saveSetting = function(_self, key, value) data[key] = value end,
        flush = function() end,
    })
    service.Actions = Actions
    local edited = service:getAction("highlight", "translate")
    TestRunner:assertTrue(edited ~= nil, "Translate is one of the highlight actions the service loads")
    TestRunner:assertEqual(edited.model, "a-stronger-model")
    TestRunner:assertEqual(edited.translate_view, true, "still the translate window's action")
    TestRunner:assertEqual(Actions.special.translate.model, nil, "the shipped table has no such pin")
end)

TestRunner:test("Translate Page and the selection popup's Translate ask the service first", function()
    local page = cut("translateCurrentPage")
    local ask = 'action_service:getAction("highlight", "translate")'
    local at = page:find(ask, 1, true)
    TestRunner:assertTrue(at ~= nil, "Translate Page reads the reader's Translate")
    local shipped = page:find("Actions.special.translate", 1, true)
    TestRunner:assertTrue(shipped ~= nil and shipped > at, "the shipped one only after it, as the fallback")
    local viewer = source("koassistant/ui/chatgptviewer.lua")
    local from = assert(viewer:find('text = _("Translate"),', 1, true), "the selection popup's Translate row")
    local body = viewer:sub(from, from + 900)
    local v_at = body:find('plugin.' .. ask, 1, true)
    TestRunner:assertTrue(v_at ~= nil, "the selection popup's Translate reads it too")
    local v_shipped = body:find('Actions.getById("translate")', 1, true)
    TestRunner:assertTrue(v_shipped ~= nil and v_shipped > v_at, "the shipped one only as the fallback")
end)

return TestRunner:summary()
