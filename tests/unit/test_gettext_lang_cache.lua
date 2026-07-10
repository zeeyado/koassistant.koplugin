--[[
Unit tests: koassistant_gettext language-resolution caching

Guards audit v0.20.0 finding (gettext perf): translate() used to resolve the UI language
from disk on EVERY _() call — LuaSettings:open() = stat + full parse of the settings file,
hundreds of times per screen render on e-ink. The fix short-circuits on the cached language
before resolving; reload() (called from the ui_language setting's on_change) is the only
invalidation path.

Run: lua tests/unit/test_gettext_lang_cache.lua  (auto-discovered by run_tests.lua --unit)
]]

-- Setup test environment
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

-- Stub the settings modules BEFORE requiring gettext, with an open() counter so the test
-- can observe every disk resolution. ui_language is explicit ("de") so resolution never
-- falls through to G_reader_settings.
local open_count = 0
local stub_lang = "de"
local saved_datastorage = package.loaded["datastorage"]
local saved_luasettings = package.loaded["luasettings"]
package.loaded["datastorage"] = { getSettingsDir = function() return "/tmp" end }
package.loaded["luasettings"] = {
    open = function()
        open_count = open_count + 1
        return {
            readSetting = function(_, key)
                if key == "features" then return { ui_language = stub_lang } end
            end,
        }
    end,
}

-- Reset module cache before requiring (matters under run_tests.lua)
package.loaded["koassistant_gettext"] = nil
local Gettext = require("koassistant_gettext")
local TestRunner = require("test_runner"):new()

print("")
print(string.rep("=", 50))
print("  Unit Tests: gettext language-resolution cache")
print(string.rep("=", 50))

TestRunner:test("first _() resolves the language from settings once", function()
    Gettext("Hello")
    TestRunner:assertEqual(open_count, 1, "one settings open on first call")
end)

TestRunner:test("subsequent _() calls do NOT re-open the settings file", function()
    Gettext("World")
    Gettext("Again")
    Gettext("And again")
    TestRunner:assertEqual(open_count, 1, "still one settings open after further calls")
end)

TestRunner:test("a settings change alone does not invalidate (restart semantics)", function()
    stub_lang = "fr"
    Gettext("Stale is fine")
    TestRunner:assertEqual(open_count, 1, "cached language survives external change")
end)

TestRunner:test("reload() re-resolves from settings", function()
    Gettext.reload()
    TestRunner:assertEqual(open_count, 2, "reload triggers exactly one fresh resolution")
    Gettext("After reload")
    TestRunner:assertEqual(open_count, 2, "and the new language is cached again")
end)

-- Restore whatever the harness had loaded so later test files see the original modules
package.loaded["datastorage"] = saved_datastorage
package.loaded["luasettings"] = saved_luasettings
package.loaded["koassistant_gettext"] = nil

return TestRunner:summary()
