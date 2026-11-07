-- Unit tests for koassistant/ui/script_fonts.lua (B558 2026-11-05, B621
-- 2026-11-07): the fonts of the scripts the window's font lacks, in the
-- Markdown view. The CSS fragment (four @font-face rules per face under one
-- family, the class rule with 'Noto Sans' after), the Arabic face by file or
-- through crengine, the fixed faces (Hebrew, Devanagari, Bengali from
-- KOReader's folder, emoji from the plugin's), the memo, the Settings row's
-- label and rows, the run pass (script runs and emoji in spans), the
-- direction pass writing direction alone, the viewer's one pipeline, and the
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

local SF = require("koassistant.ui.script_fonts")
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

print("\nScript fonts (B558, B621)")

-- A fake fonts folder and plugin folder: which files exist is a set
local FAKE_DIR = "/fake/fonts"
local FAKE_PLUGIN = "/fake/plugin"
local files = {}
local saved = { dir = SF._fontsDir, plugin = SF._pluginDir, exists = SF._fileExists, cre = SF._cre }
SF._fontsDir = function() return FAKE_DIR end
SF._pluginDir = function() return FAKE_PLUGIN end
SF._fileExists = function(path) return files[path] == true end
SF._cre = function() return nil end
local function have(...)
    files = {}
    for _idx, rel in ipairs({ ... }) do
        if rel:sub(1, 6) == "fonts/" then files[FAKE_PLUGIN .. "/" .. rel] = true
        else files[FAKE_DIR .. "/" .. rel] = true end
    end
    SF.reset()
end

TestRunner:test("the Arabic family in effect: the default, a pick, none", function()
    TestRunner:assertEqual(SF.family(nil), "Noto Naskh Arabic", "no features")
    TestRunner:assertEqual(SF.family({}), "Noto Naskh Arabic", "nothing set")
    TestRunner:assertEqual(SF.family({ rtl_font = "Noto Sans Arabic UI" }), "Noto Sans Arabic UI", "a pick")
    TestRunner:assertEqual(SF.family({ rtl_font = "Amiri" }), "Amiri", "another family")
    TestRunner:assertEqual(SF.family({ rtl_font = false }), nil, "none")
    TestRunner:assertEqual(SF.family({ rtl_font = "" }), "Noto Naskh Arabic", "an empty string is the default")
end)

TestRunner:test("a shipped face resolves by file: four entries, the styles it lacks on the nearest file", function()
    have("noto/NotoNaskhArabic-Regular.ttf", "noto/NotoNaskhArabic-Bold.ttf")
    local faces = SF.faces("Noto Naskh Arabic")
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
    local ui = SF.faces("Noto Sans Arabic UI")
    TestRunner:assertEqual(ui[3].path, ui[1].path, "no bold file: the regular stands in, MuPDF emboldens")
    have()
    TestRunner:assertEqual(SF.faces("Noto Naskh Arabic"), nil, "no regular file: nothing")
end)

TestRunner:test("another family resolves through crengine, its missing styles on the nearest file", function()
    have()
    local asked = {}
    SF._cre = function()
        return {
            getFontFaceFilenameAndFaceIndex = function(family, bold, italic)
                asked[#asked + 1] = { family, bold, italic }
                if family ~= "Amiri" then return nil end
                if italic then return nil end
                return bold and "/ko/fonts/Amiri-Bold.ttf" or "/ko/fonts/Amiri-Regular.ttf", 0
            end,
        }
    end
    local faces = SF.faces("Amiri")
    TestRunner:assertEqual(#faces, 4, "four combos")
    TestRunner:assertEqual(faces[1].path, "/ko/fonts/Amiri-Regular.ttf", "regular")
    TestRunner:assertEqual(faces[2].path, "/ko/fonts/Amiri-Regular.ttf", "italic from the regular")
    TestRunner:assertEqual(faces[3].path, "/ko/fonts/Amiri-Bold.ttf", "bold")
    TestRunner:assertEqual(faces[4].path, "/ko/fonts/Amiri-Bold.ttf", "bold italic from the bold")
    TestRunner:assertEqual(#asked, 4, "asked once per combo")
    TestRunner:assertEqual(SF.faces("Gone Font"), nil, "a family crengine does not know")
    SF._cre = function() return nil end
    TestRunner:assertEqual(SF.faces("Amiri"), nil, "no engine: nothing")
end)

TestRunner:test("the fixed faces: KOReader's files for Hebrew, Devanagari and Bengali, the plugin's emoji file; none without the file", function()
    have("freefont/FreeSans.ttf", "noto/NotoSansDevanagariUI-Regular.ttf", "noto/NotoSansDevanagariUI-Bold.ttf",
        "fonts/NotoEmoji-Regular.ttf")
    local by_class = {}
    for _idx, entry in ipairs(SF.FIXED) do by_class[entry.class] = SF.fixedFaces(entry) end
    TestRunner:assertEqual(by_class["koa-hebr"][1].path, FAKE_DIR .. "/freefont/FreeSans.ttf", "Hebrew: FreeSans")
    TestRunner:assertEqual(by_class["koa-hebr"][3].path, by_class["koa-hebr"][1].path, "its bold synthesized")
    TestRunner:assertEqual(by_class["koa-deva"][3].path, FAKE_DIR .. "/noto/NotoSansDevanagariUI-Bold.ttf", "Devanagari's real bold")
    TestRunner:assertEqual(by_class["koa-beng"], nil, "Bengali's file missing: no face")
    TestRunner:assertEqual(by_class["koa-emoji"][1].path, FAKE_PLUGIN .. "/fonts/NotoEmoji-Regular.ttf", "emoji from the plugin's folder")
    TestRunner:assertEqual(#by_class["koa-emoji"], 4, "four combos on the one file")
end)

TestRunner:test("the CSS: two rules per face under its family, the class rule with Noto Sans after, nothing without a file", function()
    have("noto/NotoNaskhArabic-Regular.ttf", "noto/NotoNaskhArabic-Bold.ttf", "fonts/NotoEmoji-Regular.ttf")
    local css = SF.css({})
    local reg = FAKE_DIR .. "/noto/NotoNaskhArabic-Regular.ttf"
    local bold = FAKE_DIR .. "/noto/NotoNaskhArabic-Bold.ttf"
    TestRunner:assertTrue(css:find("@font-face { font-family: 'KOA RTL'; src: url('" .. reg .. "'); }", 1, true) ~= nil, "regular rule")
    TestRunner:assertTrue(css:find("@font-face { font-family: 'KOA RTL'; src: url('" .. bold .. "'); font-weight: bold; }", 1, true) ~= nil, "bold rule")
    TestRunner:assertTrue(css:find("font-style: italic", 1, true) == nil, "no italic rules (an italic span takes the regular face)")
    TestRunner:assertTrue(css:find(".koa-arab { font-family: 'KOA RTL', 'Noto Sans'; }", 1, true) ~= nil, "the Arabic class rule, Noto Sans after")
    TestRunner:assertTrue(css:find(".koa-emoji { font-family: 'KOA Emoji', 'Noto Sans'; }", 1, true) ~= nil, "the emoji class rule")
    TestRunner:assertTrue(css:find("src: url('" .. FAKE_PLUGIN .. "/fonts/NotoEmoji-Regular.ttf')", 1, true) ~= nil, "the emoji file")
    TestRunner:assertTrue(css:find("koa-hebr", 1, true) == nil and css:find("koa-deva", 1, true) == nil, "no rule for a face without its file")
    local _, n = css:gsub("@font%-face", "")
    TestRunner:assertEqual(n, 3, "regular and bold for the Arabic face, the regular alone for emoji")
    TestRunner:assertTrue(css:find("koa-rtl", 1, true) == nil, "no block class rule")
    -- a document declares only the faces its spans name: MuPDF reads every declared file
    TestRunner:assertEqual(SF.css({}, "<p>plain english</p>"), "", "an English document declares no face")
    local arabic_only = SF.css({}, '<p>the word <span class="koa-arab">x</span></p>')
    TestRunner:assertTrue(arabic_only:find("KOA RTL", 1, true) ~= nil and arabic_only:find("koa-emoji", 1, true) == nil, "the Arabic face alone")
    local emoji_only = SF.css({}, '<p>ok <span class="koa-emoji">x</span></p>')
    TestRunner:assertTrue(emoji_only:find("KOA RTL", 1, true) == nil and emoji_only:find("koa-emoji", 1, true) ~= nil, "the emoji face alone")
    TestRunner:assertEqual(SF.css({}, '<p><span class="koa-hebr">x</span></p>'), "", "a named face without its file: nothing")
    local none = SF.css({ rtl_font = false })
    TestRunner:assertTrue(none:find("KOA RTL", 1, true) == nil and none:find("koa-emoji", 1, true) ~= nil, "none: no Arabic rule, the fixed faces stay")
    TestRunner:assertEqual(SF.arabicCSS({ rtl_font = "Nowhere Font" }), "", "a family with no file: no Arabic rule")
    have()
    TestRunner:assertEqual(SF.css({}), "", "no files at all: nothing")
    -- memoized: the files going away does not change a built window's rules until reset
    have("noto/NotoNaskhArabic-Regular.ttf", "fonts/NotoEmoji-Regular.ttf")
    local built = SF.css({})
    files = {}
    TestRunner:assertEqual(SF.css({}), built, "memoized")
    SF.reset()
    TestRunner:assertEqual(SF.css({}), "", "after reset the missing files count")
    -- a fixed face with one file: the regular again under bold (MuPDF emboldens)
    have("freefont/FreeSans.ttf")
    local hebrew = SF.css({}, '<p><span class="koa-hebr">x</span></p>')
    local _, rules = hebrew:gsub("@font%-face", "")
    TestRunner:assertEqual(rules, 2, "regular and bold on the one file")
    TestRunner:assertTrue(hebrew:find("src: url('" .. FAKE_DIR .. "/freefont/FreeSans.ttf'); font-weight: bold; }", 1, true) ~= nil, "the bold rule on the regular file")
end)

TestRunner:test("the Settings row's label", function()
    have("noto/NotoNaskhArabic-Regular.ttf")
    TestRunner:assertEqual(SF.label({}), "Noto Naskh Arabic", "the default")
    TestRunner:assertEqual(SF.label({ rtl_font = false }), "None (the window's font)", "none")
    TestRunner:assertEqual(SF.label({ rtl_font = "Nowhere Font" }), "Nowhere Font (not found)", "a family with no file")
end)

TestRunner:test("the rows: the two shipped faces, None, then every font KOReader knows; a tap writes the key", function()
    have("noto/NotoNaskhArabic-Regular.ttf", "noto/NotoSansArabicUI-Regular.ttf")
    SF._cre = function()
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
    local items = SF.menuItems(plugin)
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
    SF._cre = function() return nil end
end)

local AR = "كتاب"
local AR2 = "القراءة متعة"
local HE = "ספר טוב"
local DEVA = "किताब अच्छी"
local BENG = "বই ভালো"

TestRunner:test("the run pass: a script's run in its span, inside any block, merged across the spaces between its words", function()
    TestRunner:assertEqual(SF.markRuns("<p>The word " .. AR .. " means book.</p>"),
        '<p>The word <span class="koa-arab">' .. AR .. "</span> means book.</p>", "an Arabic word inside an English sentence")
    TestRunner:assertEqual(SF.markRuns('<p dir="rtl">' .. AR2 .. " <b>" .. AR .. "</b> (reading is fun) " .. AR .. ".</p>"),
        '<p dir="rtl"><span class="koa-arab">' .. AR2 .. '</span> <b><span class="koa-arab">' .. AR .. "</span></b> (reading is fun) "
        .. '<span class="koa-arab">' .. AR .. ".</span></p>", "a right-to-left paragraph: the runs, the Latin between them in the block's font")
    TestRunner:assertEqual(SF.markRuns("<p>" .. HE .. " and " .. DEVA .. " and " .. BENG .. "</p>"),
        '<p><span class="koa-hebr">' .. HE .. '</span> and <span class="koa-deva">' .. DEVA .. '</span> and <span class="koa-beng">' .. BENG .. "</span></p>",
        "Hebrew, Devanagari and Bengali, each run merged across its space")
    TestRunner:assertEqual(SF.markRuns("<p>123 " .. AR .. " 456 " .. AR .. "</p>"),
        '<p>123 <span class="koa-arab">' .. AR .. '</span> 456 <span class="koa-arab">' .. AR .. "</span></p>", "digits between two runs stay outside")
    TestRunner:assertEqual(SF.markRuns("<p>&quot;" .. AR .. "&quot; &amp; <code>x = " .. AR .. '</code> <a href="http://a.b/?q=1">' .. AR .. "</a></p>"),
        '<p><span class="koa-arab">&quot;' .. AR .. '&quot;</span> &amp; <code>x = <span class="koa-arab">' .. AR .. '</span></code> <a href="http://a.b/?q=1"><span class="koa-arab">' .. AR .. "</span></a></p>",
        "entities ride with their token, tags and attributes untouched, code and links inside")
    TestRunner:assertEqual(SF.markRuns("<pre>  " .. AR .. "\n\t" .. AR .. "  </pre>"),
        '<pre>  <span class="koa-arab">' .. AR .. "\n\t" .. AR .. "</span>  </pre>", "whitespace kept to the byte, a run across a line break")
end)

TestRunner:test("the run pass: emoji each in their own span, sequences whole, text symbols untouched", function()
    local out = SF.markRuns("<p>Search 🔍 and 🔗 link, family 👨‍👩‍👧, flag 🇫🇷, keycap 1️⃣ and #⃣, warn ⚠️, ©️ check ✓, arrow →, bullet • and ★ star, ✅ done, (📚).</p>")
    local function has(s) return out:find(s, 1, true) ~= nil end
    TestRunner:assertTrue(has('Search <span class="koa-emoji">🔍</span> and <span class="koa-emoji">🔗</span> link'), "each emoji alone, the space between in the block's font")
    TestRunner:assertTrue(has('<span class="koa-emoji">👨‍👩‍👧</span>'), "a joiner sequence whole")
    TestRunner:assertTrue(has('<span class="koa-emoji">🇫🇷</span>'), "a flag's two letters together")
    TestRunner:assertTrue(has('<span class="koa-emoji">1️⃣</span> and <span class="koa-emoji">#⃣</span>'), "keycaps")
    TestRunner:assertTrue(has('<span class="koa-emoji">⚠️</span>') and has('<span class="koa-emoji">©️</span>'), "a text symbol with the emoji selector")
    TestRunner:assertTrue(has("check ✓, arrow →, bullet • and ★ star,"), "a check mark, an arrow, a bullet and a star stay in the window's font")
    TestRunner:assertTrue(has('<span class="koa-emoji">✅</span> done, (<span class="koa-emoji">📚</span>).'), "a default emoji among the three-byte symbols; punctuation around stays outside")
    TestRunner:assertEqual(SF.markRuns("<p>word🔍word " .. AR .. "📚</p>"),
        '<p>word<span class="koa-emoji">🔍</span>word <span class="koa-arab">' .. AR .. '<span class="koa-emoji">📚</span></span></p>',
        "an emoji glued to a word, and inside a script run")
end)

TestRunner:test("the run pass: a word's class is its first script letter; a tag ends outside quotes; a bare '<' is text", function()
    TestRunner:assertEqual(SF.markRuns("<p>আমি ভাত খাই। তুমি</p>"), '<p><span class="koa-beng">আমি ভাত খাই। তুমি</span></p>',
        "a Bengali sentence ending in the danda (a Devanagari character) stays Bengali")
    TestRunner:assertEqual(SF.markRuns("<p>שלום، x</p>"), '<p><span class="koa-hebr">שלום،</span> x</p>', "a Hebrew word with an Arabic comma stays Hebrew")
    TestRunner:assertEqual(SF.markRuns('<p><a href="http://x/?a>b" title="c>d">' .. AR .. "</a></p>"),
        '<p><a href="http://x/?a>b" title="c>d"><span class="koa-arab">' .. AR .. "</span></a></p>", "a '>' inside a quoted attribute does not end the tag")
    TestRunner:assertEqual(SF.markRuns("<p>if x < 3 🔍 " .. AR .. " and y > 2</p>"),
        '<p>if x < 3 <span class="koa-emoji">🔍</span> <span class="koa-arab">' .. AR .. "</span> and y > 2</p>", "a '<' that starts no tag is text")
    TestRunner:assertEqual(SF.markRuns("<p>ݐ and ㊗️ and ↔️</p>"),
        '<p><span class="koa-arab">ݐ</span> and <span class="koa-emoji">㊗️</span> and <span class="koa-emoji">↔️</span></p>',
        "an Arabic Supplement letter, a CJK symbol and an arrow with the emoji selector")
    TestRunner:assertEqual(SF.markRuns("<!-- a comment > here --><p>" .. AR .. "</p>"), '<!-- a comment > here --><p><span class="koa-arab">' .. AR .. "</span></p>", "a comment is a tag")
end)

TestRunner:test("the run pass: text with nothing to wrap comes back as the same string", function()
    local plain = "<p>plain english, nothing here: 100% fine, yes. <b>bold</b> ◉ KOAssistant: ✓ → •</p>"
    TestRunner:assertTrue(SF.markRuns(plain) == plain, "unchanged")
    TestRunner:assertEqual(SF.markRuns(""), "", "empty")
    TestRunner:assertEqual(SF.markRuns(nil), nil, "nil")
end)

TestRunner:test("the direction pass writes direction alone: no class on a right-to-left block", function()
    local html = Bidi.addHtmlBidiAttributes(
        "<p>" .. AR2 .. "</p><p>an English paragraph</p><h2>" .. AR2 .. "</h2><ul><li>" .. AR2 .. "</li></ul>"
        .. "<blockquote><p>" .. AR2 .. "</p></blockquote><table><tr><td>" .. AR2 .. "</td><td>text</td></tr></table>")
    local _, rtl = html:gsub('dir="rtl"', "")
    TestRunner:assertEqual(rtl, 6, "the paragraph, the heading, the list item, the quote and its paragraph, the cell")
    TestRunner:assertTrue(html:find("class=", 1, true) == nil, "no class from the direction pass")
    TestRunner:assertTrue(html:find("<p>an English paragraph</p>", 1, true) ~= nil, "a left-to-right block untouched")
    -- the span pass after it: the runs inside the directed blocks
    local spanned = SF.markRuns(html)
    TestRunner:assertTrue(spanned:find('<p dir="rtl"><span class="koa-arab">' .. AR2 .. "</span></p>", 1, true) ~= nil, "direction on the block, the font on the run")
end)

TestRunner:test("the viewer: one CSS site with the rules, the pipeline ends with the span pass", function()
    local f = assert(io.open(PLUGIN_DIR .. "/koassistant/ui/chatgptviewer.lua", "r"))
    local src = f:read("*a")
    f:close()
    local _, sites = src:gsub("getViewerCSS%(self%.text_align, self:_scriptFontCSS%(html_body%)%)", "")
    TestRunner:assertEqual(sites, 1, "the content widget's one builder, the document's HTML passed for its faces")
    local _, bare = src:gsub("getViewerCSS%(self%.text_align%)", "")
    TestRunner:assertEqual(bare, 0, "no site without the rules")
    TestRunner:assertTrue(src:find("]], align_rule) .. (rtl_css or \"\")", 1, true) ~= nil, "the builder appends them last")
    TestRunner:assertTrue(src:find("function ChatGPTViewer:_scriptFontCSS(html_body)", 1, true) ~= nil, "the window's own reader of its configuration, per document")
    TestRunner:assertTrue(src:find("return ScriptFonts.markRuns(html_body), reply_break", 1, true) ~= nil, "the span pass last")
    TestRunner:assertTrue(src:find("function ChatGPTViewer.markdownHtml(text, opts)", 1, true) ~= nil
        and src:find("function ChatGPTViewer.viewerCSS(text_align, features, html_body)", 1, true) ~= nil, "the exports for the streaming window")
end)

TestRunner:test("the installed KOReader ships the faces and they resolve by file; the plugin carries the emoji font", function()
    local bundle = "/Applications/KOReader.app/Contents/koreader/fonts"
    local h = io.open(bundle .. "/noto/NotoNaskhArabic-Regular.ttf", "rb")
    if not h then
        print("    (no KOReader bundle at " .. bundle .. ": the shipped files are not checked)")
        return
    end
    h:close()
    SF._fontsDir = function() return bundle end
    SF._pluginDir = function() return PLUGIN_DIR end
    SF._fileExists = saved.exists
    SF.reset()
    for _idx, face in ipairs(SF.SHIPPED) do
        local faces = SF.faces(face.family)
        TestRunner:assertTrue(faces ~= nil, face.family .. " resolves")
        TestRunner:assertTrue(faces[3].path:find("Bold", 1, true) ~= nil, face.family .. " has its bold file")
    end
    for _idx, entry in ipairs(SF.FIXED) do
        TestRunner:assertTrue(SF.fixedFaces(entry) ~= nil, entry.family .. " resolves")
    end
    local css = SF.css({})
    for _idx, class in ipairs({ "koa-arab", "koa-hebr", "koa-deva", "koa-beng", "koa-emoji" }) do
        TestRunner:assertTrue(css:find("." .. class .. " {", 1, true) ~= nil, class .. " has its rule")
    end
end)

SF._fontsDir, SF._pluginDir, SF._fileExists, SF._cre = saved.dir, saved.plugin, saved.exists, saved.cre
SF.reset()

print(string.format("\nResults: %d passed, %d failed", TestRunner.passed, TestRunner.failed))
return TestRunner.failed == 0
