-- B399: KOAssistant's row in the file browser's select-mode menu is added by the menu's
-- title, which KOReader writes in its own language. The helper is cut from main.lua and
-- run against a fake KOReader gettext, the way KOReader itself builds the title.

local function setupPaths()
    local info = debug.getinfo(1, "S")
    local script_path = info.source:match("@?(.*)")
    local unit_dir = script_path:match("(.+)/[^/]+$") or "."
    local tests_dir = unit_dir:match("(.+)/[^/]+$") or "."
    local plugin_dir = tests_dir:match("(.+)/[^/]+$") or "."

    package.path = table.concat({
        plugin_dir .. "/?.lua",
        tests_dir .. "/?.lua",
        tests_dir .. "/lib/?.lua",
        package.path,
    }, ";")
end

setupPaths()
require("mock_koreader")

local TestRunner = require("test_runner"):new()
local template = require("ffi/util").template

print("")
print(string.rep("=", 50))
print("  Unit Tests: Select-mode menu title (B399)")
print(string.rep("=", 50))

local f = assert(io.open(package.searchpath("main", package.path), "r"))
local main_src = f:read("*a")
f:close()

local body = main_src:match("\nfunction AskGPT%._isSelectModeTitle%(title, count%)\n(.-)\nend\n")
local make = body and assert(load("local T, require = ...\nreturn function(title, count)\n" .. body .. "\nend",
    "_isSelectModeTitle"))

-- KOReader's gettext in another language: a callable with ngettext, as in frontend/gettext.lua.
local function inLanguage(translations)
    local kgettext = setmetatable({
        ngettext = function(singular, plural, n)
            local msgid = n == 1 and singular or plural
            return translations[msgid] or msgid
        end,
    }, { __call = function(_self, msgid) return translations[msgid] or msgid end })
    return make(template, function(name)
        if name == "gettext" then return kgettext end
        return require(name)
    end)
end

local SPANISH = {
    ["1 file selected"] = "1 archivo seleccionado",
    ["%1 files selected"] = "%1 archivos seleccionados",
    ["No files selected"] = "Ningún archivo seleccionado",
}

TestRunner:test("the helper exists in main.lua", function()
    TestRunner:assertTrue(make ~= nil, "AskGPT._isSelectModeTitle")
end)

TestRunner:test("a translated title is recognized, as KOReader builds it", function()
    local isSel = inLanguage(SPANISH)
    TestRunner:assertTrue(isSel("3 archivos seleccionados", 3), "several files")
    TestRunner:assertTrue(isSel("1 archivo seleccionado", 1), "one file")
    TestRunner:assertTrue(isSel("Ningún archivo seleccionado", 0), "none selected")
end)

TestRunner:test("other menus are left alone", function()
    local isSel = inLanguage(SPANISH)
    TestRunner:assertTrue(not isSel("Abrir con…", 3), "another menu")
    TestRunner:assertTrue(not isSel("3 archivos seleccionados", 2), "a title for another count")
end)

TestRunner:test("English still matches, with or without KOReader's gettext", function()
    TestRunner:assertTrue(inLanguage({})("3 files selected", 3), "English through gettext")
    local no_gettext = make(template, function(name)
        if name == "gettext" then error("no gettext") end
        return require(name)
    end)
    TestRunner:assertTrue(no_gettext("3 files selected", 3), "the English patterns as a fallback")
    TestRunner:assertTrue(not no_gettext("Abrir con…", 3), "and nothing else")
end)

TestRunner:test("the multi-select patch asks the helper", function()
    TestRunner:assertTrue(main_src:find(
        "AskGPT._isSelectModeTitle(o.title, util.tableSize(FileManager.instance.selected_files))", 1, true) ~= nil,
        "ButtonDialog.new's check")
    TestRunner:assertTrue(not main_src:find('o.title:find("file.*selected")', 1, true), "no English-only check left")
end)

return TestRunner:summary()
