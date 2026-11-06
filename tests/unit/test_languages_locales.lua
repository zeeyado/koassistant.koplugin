-- Every UI language KOReader offers (frontend/ui/language.lua of the
-- installed app) resolves to a plugin language, except Hebrew, which the
-- plugin has no language for yet (the sweep of 2026-11-06: Irish,
-- Indonesian and Slovenian were missing from the map, so those readers got
-- the English default).
--
-- Run: lua tests/unit/test_languages_locales.lua  (or lua tests/run_tests.lua --unit)

local function setupPaths()
    local info = debug.getinfo(1, "S")
    local script_path = info.source:match("@?(.*)")
    local unit_dir = script_path:match("(.+)/[^/]+$") or "."
    local tests_dir = unit_dir:match("(.+)/[^/]+$") or "."
    local plugin_dir = tests_dir:match("(.+)/[^/]+$") or "."
    package.path = table.concat({
        plugin_dir .. "/?.lua", tests_dir .. "/?.lua", tests_dir .. "/lib/?.lua", package.path,
    }, ";")
end
setupPaths()
require("mock_koreader")
local TestRunner = require("test_runner"):new()
local Languages = require("koassistant.core.languages")

print("Running: test_languages_locales")
print("")

local KO = "/Applications/KOReader.app/Contents/koreader/frontend/ui/language.lua"

TestRunner:test("the three locales the map lacked resolve to their plugin languages", function()
    TestRunner:assertEqual(Languages.KOREADER_LOCALE_MAP.ga, "Irish")
    TestRunner:assertEqual(Languages.KOREADER_LOCALE_MAP.id, "Indonesian")
    TestRunner:assertEqual(Languages.KOREADER_LOCALE_MAP.sl, "Slovenian")
    local ids = {}
    for _idx, lang in ipairs(Languages.REGULAR) do ids[lang.id] = true end
    TestRunner:assertTrue(ids.Irish and ids.Indonesian and ids.Slovenian, "and those languages exist")
end)

TestRunner:test("every locale of the installed KOReader resolves, except Hebrew", function()
    local f = io.open(KO, "r")
    if not f then
        print("    (no installed KOReader at " .. KO .. ": the list is not checked)")
        return
    end
    local src = f:read("*a")
    f:close()
    local saved_G = _G.G_reader_settings
    local cur
    _G.G_reader_settings = { readSetting = function(_s, k) if k == "language" then return cur end end }
    local unmapped, n = {}, 0
    -- the active rows only (KOReader keeps a few commented out: ml, zh, zh_TW.Big5)
    for line in src:gmatch("[^\n]+") do
        local code = not line:match("^%s*%-%-") and line:match('genLanguageSubItem%("([^"]+)"')
        if code then
            n = n + 1
            cur = code
            if not Languages.detectFromKOReader() then unmapped[#unmapped + 1] = code end
        end
    end
    _G.G_reader_settings = saved_G
    TestRunner:assertTrue(n >= 40, "the list was read (" .. n .. ")")
    TestRunner:assertEqual(table.concat(unmapped, ","), "he", "only Hebrew is unmapped")
end)

return TestRunner:summary()
