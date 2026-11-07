-- The chat viewer's direction pass (koassistant/ui/bidi.lua): a block's
-- direction by the majority of its words, dir attributes on right-to-left
-- blocks only, lists with a right-to-left item as marked paragraphs, an
-- explicit alignment swapped on right-to-left blocks (logical under dir="rtl").
-- The MuPDF facts behind it were probed headless on 2026-10-19
-- (docs/competitor_delta_2026-10.md section 3.2).
--
-- Run: lua tests/unit/test_bidi.lua  (or lua tests/run_tests.lua --unit)

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

local Bidi = require("koassistant.ui.bidi")
local TestRunner = require("test_runner"):new()

print("")
print(string.rep("=", 50))
print("  Unit Tests: Direction pass (bidi)")
print(string.rep("=", 50))

local AR = "هذا كتاب عن التاريخ"
local AR2 = "كان ابن سينا طبيبا"
local HE = "זהו ספר על ההיסטוריה"
local FA = "این کتاب درباره تاریخ"

TestRunner:test("tokens: right-to-left letters of every script, other letters, neutrals", function()
    TestRunner:assertEqual(Bidi.tokenDirection("كتاب"), "rtl", "Arabic")
    TestRunner:assertEqual(Bidi.tokenDirection("ספר"), "rtl", "Hebrew")
    TestRunner:assertEqual(Bidi.tokenDirection("کتاب"), "rtl", "Persian")
    TestRunner:assertEqual(Bidi.tokenDirection("ܟܬܒܐ"), "rtl", "Syriac")
    TestRunner:assertEqual(Bidi.tokenDirection("book"), "ltr", "Latin")
    TestRunner:assertEqual(Bidi.tokenDirection("Ünïcode"), "ltr", "Latin with accents")
    TestRunner:assertEqual(Bidi.tokenDirection("книга"), "ltr", "Cyrillic")
    TestRunner:assertEqual(Bidi.tokenDirection("日本語"), "ltr", "CJK")
    TestRunner:assertEqual(Bidi.tokenDirection("123"), nil, "digits")
    TestRunner:assertEqual(Bidi.tokenDirection("—"), nil, "an em dash")
    TestRunner:assertEqual(Bidi.tokenDirection("•"), nil, "a bullet")
    TestRunner:assertEqual(Bidi.tokenDirection("(2.5)"), nil, "punctuation")
end)

TestRunner:test("a block follows the majority of its words, the first strong word breaks a tie", function()
    TestRunner:assertEqual(Bidi.blockDirection(AR .. " Avicenna"), "rtl", "Arabic naming a Latin author")
    TestRunner:assertEqual(Bidi.blockDirection("the word " .. AR2 .. " means something here"), "ltr", "English quoting Arabic")
    TestRunner:assertEqual(Bidi.blockDirection("كتاب book"), "rtl", "tie: first word right-to-left")
    TestRunner:assertEqual(Bidi.blockDirection("book كتاب"), "ltr", "tie: first word left-to-right")
    TestRunner:assertEqual(Bidi.blockDirection(HE), "rtl", "Hebrew")
    TestRunner:assertEqual(Bidi.blockDirection(FA), "rtl", "Persian")
    TestRunner:assertEqual(Bidi.blockDirection(""), "ltr", "empty")
    TestRunner:assertEqual(Bidi.blockDirection("1. 2. 3."), "ltr", "no letters at all")
    TestRunner:assertEqual(Bidi.blockDirection("&amp; " .. AR2), "rtl", "an entity is not a word")
end)

TestRunner:test("the dictionary window of a right-to-left language: a headword first makes the block RTL", function()
    local entry = "كتاب /kitaab/ noun: a book, a written work of many pages"
    TestRunner:assertEqual(Bidi.blockDirection(entry), "ltr", "by the majority")
    TestRunner:assertEqual(Bidi.blockDirection(entry, { use_starts_with_rtl = true }), "rtl", "by the headword")
    TestRunner:assertEqual(Bidi.blockDirection("noun " .. AR2, { use_starts_with_rtl = true }), "rtl",
        "the option only decides when the first word is right-to-left; here the majority does")
end)

TestRunner:test("Auto RTL mode's test counts right-to-left letters of every script", function()
    TestRunner:assertTrue(Bidi.hasDominantRTL(AR), "Arabic")
    TestRunner:assertTrue(Bidi.hasDominantRTL(HE), "Hebrew")
    TestRunner:assertTrue(Bidi.hasDominantRTL("see " .. AR), "a Latin word does not outweigh it")
    TestRunner:assertFalse(Bidi.hasDominantRTL("An English answer that quotes كتاب once"), "English quoting Arabic")
    TestRunner:assertFalse(Bidi.hasDominantRTL("English only"), "no right-to-left letters")
    TestRunner:assertTrue(Bidi.hasDominantRTL(AR .. string.rep(" english", 20), #AR), "the sample bounds the scan")
end)

local function pass(html, opts) return Bidi.addHtmlBidiAttributes(html, opts) end

TestRunner:test("paragraphs: dir=\"rtl\" on right-to-left blocks, nothing on the others", function()
    TestRunner:assertEqual(pass("<p>" .. AR .. "</p>"), '<p dir="rtl">' .. AR .. "</p>", "Arabic")
    TestRunner:assertEqual(pass("<p>An English paragraph.</p>"), "<p>An English paragraph.</p>", "English untouched")
    TestRunner:assertEqual(pass("<p>◉ KOAssistant:</p>"), "<p>◉ KOAssistant:</p>", "the exchange marker untouched")
    TestRunner:assertEqual(pass('<p class="koa-math">x = 1</p>'), '<p class="koa-math">x = 1</p>', "a math paragraph untouched")
    TestRunner:assertEqual(pass("<p><b>" .. AR2 .. "</b> " .. AR .. "</p>"), '<p dir="rtl"><b>' .. AR2 .. "</b> " .. AR .. "</p>",
        "inline tags do not count as words")
end)

TestRunner:test("lists: a right-to-left item turns the list into marked paragraphs; a list without one stays a list", function()
    TestRunner:assertEqual(pass("<ul>\n<li>one</li>\n<li>two</li>\n</ul>"), "<ul><li>one</li><li>two</li></ul>",
        "a left-to-right list keeps its markers and nesting (whitespace between tags collapsed)")
    TestRunner:assertEqual(pass("<ul><li>" .. AR2 .. "</li><li>an English item</li></ul>"),
        '<p dir="rtl">• ' .. AR2 .. "</p><p>• an English item</p>", "each item in its own direction")
    TestRunner:assertEqual(pass("<ol><li>" .. AR2 .. "</li><li>" .. HE .. "</li></ol>"),
        '<p dir="rtl">1. ' .. AR2 .. '</p><p dir="rtl">2. ' .. HE .. "</p>", "ordered items keep their numbers")
    TestRunner:assertEqual(pass("<p>• " .. AR2 .. "\n• second item</p>"),
        '<p dir="rtl">• ' .. AR2 .. "</p><p>• second item</p>", "a fake bullet list, one paragraph per line")
end)

TestRunner:test("an explicit alignment is swapped on right-to-left blocks (logical under dir=\"rtl\")", function()
    TestRunner:assertEqual(pass("<p>" .. AR .. "</p>", { text_align = "right" }),
        '<p dir="rtl" style="text-align: left;">' .. AR .. "</p>", "Right: the physical right is the logical start")
    TestRunner:assertEqual(pass("<p>" .. AR .. "</p>", { text_align = "left" }),
        '<p dir="rtl" style="text-align: right;">' .. AR .. "</p>", "Left: the physical left is the logical end")
    TestRunner:assertEqual(pass("<p>" .. AR .. "</p>", { text_align = "justify" }), '<p dir="rtl">' .. AR .. "</p>", "justify needs no swap")
    TestRunner:assertEqual(pass("<p>plain</p>", { text_align = "right" }), "<p>plain</p>", "a left-to-right block relies on the stylesheet")
    TestRunner:assertEqual(pass("<ul><li>" .. AR2 .. "</li></ul>", { text_align = "right" }),
        '<p dir="rtl" style="text-align: left;">• ' .. AR2 .. "</p>", "list paragraphs too")
end)

TestRunner:test("headings, quotes and table cells", function()
    TestRunner:assertEqual(pass("<h2>" .. HE .. "</h2>"), '<h2 dir="rtl">' .. HE .. "</h2>", "heading")
    TestRunner:assertEqual(pass("<h2>Title</h2>"), "<h2>Title</h2>", "heading untouched")
    TestRunner:assertEqual(pass("<blockquote><p>" .. AR .. "</p></blockquote>"),
        '<blockquote dir="rtl" style="border-left: none; border-right: 3px solid #ccc; padding-left: 0; padding-right: 1em;">'
        .. '<p dir="rtl">' .. AR .. "</p></blockquote>", "a right-to-left quote mirrors its border and inset")
    TestRunner:assertEqual(pass("<blockquote><p>quoted</p></blockquote>"), "<blockquote><p>quoted</p></blockquote>", "quote untouched")
    TestRunner:assertEqual(pass('<td style="text-align:right">' .. AR .. "</td>"),
        '<td dir="rtl" style="text-align:left">' .. AR .. "</td>", "a cell keeps its attributes, its alignment swapped")
    TestRunner:assertEqual(pass('<th style="text-align:left">Column</th>'), '<th style="text-align:left">Column</th>', "cell untouched")
    TestRunner:assertEqual(pass("<td>" .. AR2 .. "</td>"), '<td dir="rtl">' .. AR2 .. "</td>", "a bare cell")
end)

return TestRunner:summary()
