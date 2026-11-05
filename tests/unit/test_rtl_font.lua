-- Unit tests for koassistant/ui/rtl_font.lua (B558, 2026-11-05): the font of
-- right-to-left blocks in the Markdown view. The CSS fragment (the four
-- @font-face rules under one family, the rule on the direction pass's class,
-- 'Noto Sans' after it), the shipped faces resolved by file, another family
-- through crengine, the memo, the Settings row's label and rows, the class
-- the direction pass writes, the viewer's five sites, and the two shipped
-- files in the installed KOReader when it is there.

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

local RtlFont = require("koassistant.ui.rtl_font")
local Bidi = require("koassistant.ui.bidi")

local TestRunner = { passed = 0, failed = 0 }
function TestRunner:test(name, fn)
    local ok, err = pcall(fn)
    if ok then
        self.passed = self.passed + 1
        print(string.format("  \226\156\147 %s", name))
    else
        self.failed = self.failed + 1
        print(string.format("  \226\156\151 %s: %s", name, tostring(err)))
    end
end
function TestRunner:assertEqual(actual, expected, msg)
    if actual ~= expected then
        error(string.format("%s: expected %s, got %s", msg or "eq", tostring(expected), tostring(actual)), 2)
    end
end
function TestRunner:assertTrue(v, msg) if not v then error((msg or "expected true"), 2) end end

print("\nRight-to-left font (B558)")

-- A fake fonts folder: which files exist is a set
local FAKE_DIR = "/fake/fonts"
local files = {}
local saved = { dir = RtlFont._fontsDir, exists = RtlFont._fileExists, cre = RtlFont._cre }
RtlFont._fontsDir = function() return FAKE_DIR end
RtlFont._fileExists = function(path) return files[path] == true end
RtlFont._cre = function() return nil end
local function have(...)
    files = {}
    for _idx, rel in ipairs({ ... }) do files[FAKE_DIR .. "/" .. rel] = true end
    RtlFont.reset()
end

TestRunner:test("the family in effect: the default, a pick, none", function()
    TestRunner:assertEqual(RtlFont.family(nil), "Noto Naskh Arabic", "no features")
    TestRunner:assertEqual(RtlFont.family({}), "Noto Naskh Arabic", "nothing set")
    TestRunner:assertEqual(RtlFont.family({ rtl_font = "Noto Sans Arabic UI" }), "Noto Sans Arabic UI", "a pick")
    TestRunner:assertEqual(RtlFont.family({ rtl_font = "Amiri" }), "Amiri", "another family")
    TestRunner:assertEqual(RtlFont.family({ rtl_font = false }), nil, "none")
    TestRunner:assertEqual(RtlFont.family({ rtl_font = "" }), "Noto Naskh Arabic", "an empty string is the default")
end)

TestRunner:test("a shipped face resolves by file: four entries, the styles it lacks on the nearest file", function()
    have("noto/NotoNaskhArabic-Regular.ttf", "noto/NotoNaskhArabic-Bold.ttf")
    local faces = RtlFont.faces("Noto Naskh Arabic")
    TestRunner:assertEqual(#faces, 4, "four combos")
    TestRunner:assertEqual(faces[1].path, FAKE_DIR .. "/noto/NotoNaskhArabic-Regular.ttf", "regular")
    TestRunner:assertTrue(not faces[1].bold and not faces[1].italic, "regular flags")
    TestRunner:assertEqual(faces[2].path, faces[1].path, "italic = the regular file, synthesized")
    TestRunner:assertTrue(faces[2].italic and not faces[2].bold, "italic flags")
    TestRunner:assertEqual(faces[3].path, FAKE_DIR .. "/noto/NotoNaskhArabic-Bold.ttf", "the real bold")
    TestRunner:assertTrue(faces[3].bold and not faces[3].italic, "bold flags")
    TestRunner:assertEqual(faces[4].path, faces[3].path, "bold italic = the bold file")
    TestRunner:assertTrue(faces[4].bold and faces[4].italic, "bold italic flags")
    have("noto/NotoSansArabicUI-Regular.ttf")
    local ui = RtlFont.faces("Noto Sans Arabic UI")
    TestRunner:assertEqual(ui[3].path, ui[1].path, "no bold file: the regular stands in, MuPDF emboldens")
    have()
    TestRunner:assertEqual(RtlFont.faces("Noto Naskh Arabic"), nil, "no regular file: nothing")
end)

TestRunner:test("another family resolves through crengine, its missing styles on the nearest file", function()
    have()
    local asked = {}
    RtlFont._cre = function()
        return {
            getFontFaceFilenameAndFaceIndex = function(family, bold, italic)
                asked[#asked + 1] = { family, bold, italic }
                if family ~= "Amiri" then return nil end
                if italic then return nil end
                return bold and "/ko/fonts/Amiri-Bold.ttf" or "/ko/fonts/Amiri-Regular.ttf", 0
            end,
        }
    end
    local faces = RtlFont.faces("Amiri")
    TestRunner:assertEqual(#faces, 4, "four combos")
    TestRunner:assertEqual(faces[1].path, "/ko/fonts/Amiri-Regular.ttf", "regular")
    TestRunner:assertEqual(faces[2].path, "/ko/fonts/Amiri-Regular.ttf", "italic from the regular")
    TestRunner:assertEqual(faces[3].path, "/ko/fonts/Amiri-Bold.ttf", "bold")
    TestRunner:assertEqual(faces[4].path, "/ko/fonts/Amiri-Bold.ttf", "bold italic from the bold")
    TestRunner:assertEqual(#asked, 4, "asked once per combo")
    TestRunner:assertEqual(RtlFont.faces("Gone Font"), nil, "a family crengine does not know")
    RtlFont._cre = function() return nil end
    TestRunner:assertEqual(RtlFont.faces("Amiri"), nil, "no engine: nothing")
end)

TestRunner:test("the CSS: the rules under one family, the class rule with Noto Sans after, nothing without a file", function()
    have("noto/NotoNaskhArabic-Regular.ttf", "noto/NotoNaskhArabic-Bold.ttf")
    local css = RtlFont.css({})
    local reg = FAKE_DIR .. "/noto/NotoNaskhArabic-Regular.ttf"
    local bold = FAKE_DIR .. "/noto/NotoNaskhArabic-Bold.ttf"
    TestRunner:assertTrue(css:find("@font-face { font-family: 'KOA RTL'; src: url('" .. reg .. "'); }", 1, true) ~= nil, "regular rule")
    TestRunner:assertTrue(css:find("@font-face { font-family: 'KOA RTL'; src: url('" .. reg .. "'); font-style: italic; }", 1, true) ~= nil, "italic rule")
    TestRunner:assertTrue(css:find("@font-face { font-family: 'KOA RTL'; src: url('" .. bold .. "'); font-weight: bold; }", 1, true) ~= nil, "bold rule")
    TestRunner:assertTrue(css:find("@font-face { font-family: 'KOA RTL'; src: url('" .. bold .. "'); font-weight: bold; font-style: italic; }", 1, true) ~= nil, "bold italic rule")
    TestRunner:assertTrue(css:find(".koa-rtl { font-family: 'KOA RTL', 'Noto Sans'; }", 1, true) ~= nil, "the class rule, Noto Sans after")
    local _, n = css:gsub("@font%-face", "")
    TestRunner:assertEqual(n, 4, "four rules")
    TestRunner:assertEqual(RtlFont.css({ rtl_font = false }), "", "none: no rule")
    TestRunner:assertEqual(RtlFont.css({ rtl_font = "Nowhere Font" }), "", "a family with no file: no rule, the window as before")
    -- memoized per family: the files going away does not change a built window's rules until reset
    files = {}
    TestRunner:assertEqual(RtlFont.css({}), css, "memoized")
    RtlFont.reset()
    TestRunner:assertEqual(RtlFont.css({}), "", "after reset the missing file counts")
end)

TestRunner:test("the Settings row's label", function()
    have("noto/NotoNaskhArabic-Regular.ttf")
    TestRunner:assertEqual(RtlFont.label({}), "Noto Naskh Arabic", "the default")
    TestRunner:assertEqual(RtlFont.label({ rtl_font = false }), "None (the window's font)", "none")
    TestRunner:assertEqual(RtlFont.label({ rtl_font = "Nowhere Font" }), "Nowhere Font (not found)", "a family with no file")
end)

TestRunner:test("the rows: the two shipped faces, None, then every font KOReader knows; a tap writes the key", function()
    have("noto/NotoNaskhArabic-Regular.ttf", "noto/NotoSansArabicUI-Regular.ttf")
    RtlFont._cre = function()
        return {
            getFontFaces = function() return { "Zeta Font", "Noto Naskh Arabic", "Alpha Font", "Noto Sans Arabic UI" } end,
            getFontFaceFilenameAndFaceIndex = function(family) return "/ko/fonts/" .. family .. ".ttf", 0 end,
        }
    end
    local features = {}
    local synced = 0
    local plugin = {
        settings = {
            readSetting = function(_self, key) if key == "features" then return features end end,
            saveSetting = function(_self, key, v) if key == "features" then features = v end end,
            flush = function() end,
        },
        updateConfigFromSettings = function() synced = synced + 1 end,
    }
    local items = RtlFont.menuItems(plugin)
    local texts = {}
    for _idx, it in ipairs(items) do texts[#texts + 1] = it.text end
    TestRunner:assertEqual(table.concat(texts, " | "),
        "Noto Naskh Arabic | Noto Sans Arabic UI | None (the window's font) | Alpha Font | Zeta Font",
        "the rows in order, the shipped ones once, the rest sorted")
    TestRunner:assertTrue(items[1].checked_func() and not items[2].checked_func() and not items[3].checked_func(),
        "the default ticked at first")
    TestRunner:assertTrue(items[3].separator == true, "a line after None")
    TestRunner:assertTrue(type(items[1].font_func) == "function" and type(items[4].font_func) == "function",
        "the font rows draw in their own face")
    TestRunner:assertEqual(items[3].font_func, nil, "None in the menu's font")
    items[4].callback()
    TestRunner:assertEqual(features.rtl_font, "Alpha Font", "a pick is the family name")
    TestRunner:assertTrue(items[4].checked_func() and not items[1].checked_func(), "the pick ticked")
    items[3].callback()
    TestRunner:assertEqual(features.rtl_font, false, "None is false")
    TestRunner:assertTrue(items[3].checked_func(), "None ticked")
    items[1].callback()
    TestRunner:assertEqual(features.rtl_font, nil, "the default pick clears the key")
    TestRunner:assertEqual(synced, 3, "every pick syncs the live config")
    for _idx, it in ipairs(items) do TestRunner:assertTrue(it.radio and it.keep_menu_open, "radio rows that keep the menu open") end
end)

TestRunner:test("the direction pass marks every right-to-left block with the class, no other", function()
    local AR = "هذا كتاب عن التاريخ"
    local html = Bidi.addHtmlBidiAttributes(
        "<p>" .. AR .. "</p><p>an English paragraph</p><h2>" .. AR .. "</h2><ul><li>" .. AR .. "</li></ul>"
        .. "<blockquote><p>" .. AR .. "</p></blockquote><table><tr><td>" .. AR .. "</td><td>text</td></tr></table>")
    local _, rtl = html:gsub('dir="rtl" class="koa%-rtl"', "")
    local _, any_class = html:gsub('class="koa%-rtl"', "")
    TestRunner:assertEqual(rtl, 6, "the paragraph, the heading, the list item, the quote and its paragraph, the cell")
    TestRunner:assertEqual(any_class, rtl, "the class only with dir=rtl")
    TestRunner:assertTrue(html:find("<p>an English paragraph</p>", 1, true) ~= nil, "a left-to-right block untouched")
    TestRunner:assertTrue(html:find("<td>text</td>", 1, true) ~= nil, "a left-to-right cell untouched")
end)

TestRunner:test("the viewer's five CSS sites pass the rules and the builder appends them", function()
    local f = assert(io.open(PLUGIN_DIR .. "/koassistant/ui/chatgptviewer.lua", "r"))
    local src = f:read("*a")
    f:close()
    local _, sites = src:gsub("getViewerCSS%(self%.text_align, self:_rtlFontCSS%(%)%)", "")
    TestRunner:assertEqual(sites, 5, "init, update, rebuild, the translate toggle, the markdown refresh")
    local _, bare = src:gsub("getViewerCSS%(self%.text_align%)", "")
    TestRunner:assertEqual(bare, 0, "no site without the rules")
    TestRunner:assertTrue(src:find("]], align_rule) .. (rtl_css or \"\")", 1, true) ~= nil, "the builder appends them last")
    TestRunner:assertTrue(src:find("function ChatGPTViewer:_rtlFontCSS()", 1, true) ~= nil, "the window's own reader of its configuration")
end)

TestRunner:test("the installed KOReader ships the two faces and they resolve by file", function()
    local bundle = "/Applications/KOReader.app/Contents/koreader/fonts"
    local h = io.open(bundle .. "/noto/NotoNaskhArabic-Regular.ttf", "rb")
    if not h then
        print("    (no KOReader bundle at " .. bundle .. ": the shipped files are not checked)")
        return
    end
    h:close()
    RtlFont._fontsDir = function() return bundle end
    RtlFont._fileExists = saved.exists
    RtlFont.reset()
    for _idx, face in ipairs(RtlFont.SHIPPED) do
        local faces = RtlFont.faces(face.family)
        TestRunner:assertTrue(faces ~= nil, face.family .. " resolves")
        TestRunner:assertEqual(faces[1].path, bundle .. "/" .. face.regular, face.family .. " regular")
        TestRunner:assertEqual(faces[3].path, bundle .. "/" .. face.bold, face.family .. " bold, a real file")
    end
    local css = RtlFont.css({})
    TestRunner:assertTrue(css:find(bundle .. "/noto/NotoNaskhArabic-Bold.ttf", 1, true) ~= nil, "the default's rules name the bundle's file")
end)

RtlFont._fontsDir, RtlFont._fileExists, RtlFont._cre = saved.dir, saved.exists, saved.cre
RtlFont.reset()

print(string.format("\n=== Results: %d passed, %d failed ===", TestRunner.passed, TestRunner.failed))
return TestRunner.failed == 0
