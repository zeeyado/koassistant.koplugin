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

-- A block that begins in its message's main direction keeps it (2026-11-12:
-- in an English dictionary entry the line "Synonyms:" followed by four Arabic
-- words was laid out right-to-left by the majority, the label on the right
-- with its colon before it).
local SYN = "<strong>Synonyms:</strong> ظلام خفيف, عتمة, ضبابية, تغبيش"
local ENTRY = "<p><strong>غبش</strong> /ɣabaʃ/ — noun (lemma: غَبَش)</p>"
    .. "<ol><li>Dimness or haziness, the half-light of dawn or dusk.</li><li>Blurred sight.</li></ol>"
    .. "<p><strong>Etymology:</strong> From the root غ-ب-ش (gh-b-sh), dimness and indistinctness.</p>"
    .. "<p>" .. SYN .. "</p>"

TestRunner:test("the main direction of a text is the direction most of its words have", function()
    TestRunner:assertEqual(Bidi.mainDirection("An English answer that quotes كتاب once"), "ltr", "English")
    TestRunner:assertEqual(Bidi.mainDirection(AR .. " Avicenna"), "rtl", "Arabic")
    TestRunner:assertEqual(Bidi.mainDirection("book كتاب"), nil, "neither leads")
    TestRunner:assertEqual(Bidi.mainDirection("1. 2. 3."), "ltr", "no right-to-left letter at all")
    TestRunner:assertEqual(Bidi.mainDirection(""), nil, "empty")
end)

TestRunner:test("a block that begins in the main direction keeps it; any other block goes by its majority", function()
    local syn = "Synonyms: ظلام خفيف, عتمة, ضبابية, تغبيش"
    TestRunner:assertEqual(Bidi.blockDirection(syn), "rtl", "by the majority alone, the label line was right-to-left")
    TestRunner:assertEqual(Bidi.blockDirection(syn, { main = "ltr" }), "ltr", "in an English answer it is an English line")
    TestRunner:assertEqual(Bidi.blockDirection(syn, { main = "rtl" }), "rtl", "in an Arabic answer the majority decides")
    TestRunner:assertEqual(Bidi.blockDirection("Compare ظلام خفيف and عتمة and ضبابية", { main = "ltr" }), "ltr",
        "an English sentence with more Arabic words than English ones")
    TestRunner:assertEqual(Bidi.blockDirection("المرادفات: dim, haze, blur, fog", { main = "rtl" }), "rtl",
        "the mirror: an Arabic label before Latin words, in an Arabic answer")
    TestRunner:assertEqual(Bidi.blockDirection("المرادفات: dim, haze, blur, fog", { main = "ltr" }), "ltr",
        "the same line in an English answer: the majority")
    TestRunner:assertEqual(Bidi.blockDirection(AR, { main = "ltr" }), "rtl", "an Arabic quotation in an English answer")
    TestRunner:assertEqual(Bidi.blockDirection("API: " .. AR, { main = "rtl" }), "rtl",
        "a Latin term explained in Arabic, in an Arabic answer")
    TestRunner:assertEqual(Bidi.blockDirection("1. — " .. AR2, { main = "ltr" }), "rtl", "neutral tokens first: the first word decides")
    TestRunner:assertEqual(Bidi.blockDirection("noun " .. AR2, { use_starts_with_rtl = true, main = "ltr" }), "rtl",
        "the dictionary option outranks the text's own main direction")
end)

TestRunner:test("an English dictionary entry about an Arabic word: every line left-to-right, the label line too", function()
    local out = pass(ENTRY)
    TestRunner:assertTrue(out:find("<p>" .. SYN .. "</p>", 1, true) ~= nil, "the Synonyms line takes no dir")
    TestRunner:assertTrue(out:find('dir="rtl"', 1, true) == nil, "no block of the entry is right-to-left")
    -- the same line as a list item: the list stays a list
    local listed = pass("<p>An English lead-in sentence for the list below.</p><ul><li>" .. SYN .. "</li><li>Root: three letters</li></ul>")
    TestRunner:assertTrue(listed:find("<ul><li>", 1, true) ~= nil and listed:find('dir="rtl"', 1, true) == nil,
        "a list whose items begin in English keeps its markers")
end)

TestRunner:test("each message of a chat has its own main direction", function()
    local arabic_answer = "<p>" .. AR .. "</p><p>" .. AR2 .. "</p><p>المرادفات: dim, haze, blur, fog</p>"
    local chat = "<p>▶ User:</p><p>" .. AR2 .. "</p><p>◉ KOAssistant:</p>" .. arabic_answer
        .. "<p>▶ User:</p><p>And in English, with its synonyms?</p><p>◉ KOAssistant:</p>" .. ENTRY
    local out = pass(chat)
    TestRunner:assertTrue(out:find('<p dir="rtl">المرادفات: dim, haze, blur, fog</p>', 1, true) ~= nil,
        "the Arabic answer's label line is right-to-left")
    TestRunner:assertTrue(out:find("<p>" .. SYN .. "</p>", 1, true) ~= nil,
        "the English answer's label line is left-to-right, under a longer Arabic answer")
    local _, markers = out:gsub("<p>◉ KOAssistant:</p>", "")
    TestRunner:assertEqual(markers, 2, "the reply markers are untouched (the landing looks for them)")
    local _, users = out:gsub("<p>▶ User:</p>", "")
    TestRunner:assertEqual(users, 2, "and the question markers")
    -- a translation window: the original and the translation are two messages
    local translated = pass("<p>▶ A long English original, many words of it, far more than the translation holds.</p>"
        .. "<p>◉ Microsoft " .. AR .. "</p>")
    TestRunner:assertTrue(translated:find('<p dir="rtl">◉ Microsoft ' .. AR .. "</p>", 1, true) ~= nil,
        "an Arabic translation that opens with a Latin name is right-to-left whatever the original's length")
    TestRunner:assertTrue(translated:find("<p>▶ A long English original", 1, true) ~= nil, "the original left-to-right")
end)

TestRunner:test("a text without one right-to-left letter: no block is read, nothing is marked", function()
    -- what the shortcut rests on: such a block is left-to-right whatever the options say
    for _idx, text in ipairs({ "An English line.", "1234 - 5678", "", "日本語の文", "Ελληνικά", "русский текст", "☑ ✓ 🙂" }) do
        TestRunner:assertEqual(Bidi.blockDirection(text, { main = "rtl" }), "ltr", "main right-to-left: " .. text)
        TestRunner:assertEqual(Bidi.blockDirection(text, { use_starts_with_rtl = true }), "ltr", "a dictionary window: " .. text)
    end
    local html = "<h2>A heading</h2>\n<p>A paragraph with <strong>bold</strong> words.</p>\n"
        .. "<ul>\n<li>one</li>\n<li>two</li>\n</ul>\n<ol><li>first</li></ol>"
        .. '<table><thead><tr><th style="text-align:left">Key</th></tr></thead>'
        .. '<tbody><tr><td style="text-align:right">1</td></tr></tbody></table>'
        .. "<blockquote><p>a quote</p></blockquote><p>• one\n• two</p>"
    local want = "<h2>A heading</h2><p>A paragraph with <strong>bold</strong> words.</p>"
        .. "<ul><li>one</li><li>two</li></ul><ol><li>first</li></ol>"
        .. '<table><thead><tr><th style="text-align:left">Key</th></tr></thead>'
        .. '<tbody><tr><td style="text-align:right">1</td></tr></tbody></table>'
        .. "<blockquote><p>a quote</p></blockquote><p>• one</p><p>• two</p>"
    local read = 0
    local real = Bidi.blockDirection
    Bidi.blockDirection = function(...) read = read + 1; return real(...) end
    for _idx, opts in ipairs({ {}, { text_align = "left" }, { text_align = "right" }, { use_starts_with_rtl = true } }) do
        TestRunner:assertEqual(Bidi.addHtmlBidiAttributes(html, opts), want,
            "the blocks as they were, the fake bullets one paragraph each")
    end
    TestRunner:assertEqual(read, 0, "no block's words were read")
    Bidi.addHtmlBidiAttributes("<p>" .. AR .. "</p><p>English</p>", {})
    Bidi.blockDirection = real
    TestRunner:assertTrue(read >= 2, "with a right-to-left letter in the text every block is")
end)

TestRunner:test("the space between two marks inside a line stays; the gaps between blocks go", function()
    TestRunner:assertEqual(pass("<p><strong>bold</strong> <em>italic</em> and <strong>x</strong> <code>y</code></p>"),
        "<p><strong>bold</strong> <em>italic</em> and <strong>x</strong> <code>y</code></p>", "bold, italic and code side by side")
    TestRunner:assertEqual(pass('<p>See <a href="https://a.example">one</a> <a href="https://b.example">two</a>.</p>'),
        '<p>See <a href="https://a.example">one</a> <a href="https://b.example">two</a>.</p>', "two links in a row")
    TestRunner:assertEqual(pass("<p><em>first line</em>\n<strong>second line</strong></p>"),
        "<p><em>first line</em>\n<strong>second line</strong></p>", "a line break between two marks is a space too")
    TestRunner:assertEqual(pass("<p>x<sup>2</sup> <i>y</i></p>"), "<p>x<sup>2</sup> <i>y</i></p>", "the math pass's tags")
    TestRunner:assertEqual(pass("<h2>Title</h2>\n<p>Text</p>\n<ul>\n<li> <strong>one</strong> </li>\n<li>two</li>\n</ul>\n<hr>\n<p>End</p>"),
        "<h2>Title</h2><p>Text</p><ul><li><strong>one</strong></li><li>two</li></ul><hr><p>End</p>",
        "between blocks, and between a block's tag and a mark, the gap is layout noise")
    TestRunner:assertEqual(pass("<p>" .. AR .. " <strong>" .. AR2 .. "</strong> <em>" .. HE .. "</em></p>"),
        '<p dir="rtl">' .. AR .. " <strong>" .. AR2 .. "</strong> <em>" .. HE .. "</em></p>", "in a right-to-left block too")
end)

-- The maintainer's screenshot of 2026-11-17 (a Quick Define window on an
-- Arabic novel, English definitions): the definition, which opens with the
-- Arabic headword, was laid out right-to-left, its full stop at the left.
-- The sentence here is invented; the shape is the screenshot's.
TestRunner:test("a dictionary window: the book's sentence above the answer does not decide the answer's direction", function()
    local WORD = "النظر"
    local sentence = "⋯كان الطريق إلى المدينة طويلا والمطر لا يتوقف، فتوقف المسافر عند الجسر القديم وأطال <strong>"
        .. WORD .. "</strong> إلى النهر قبل أن يكمل سيره⋯"
    local definition = "<strong>" .. WORD .. "</strong>, noun — the act of looking, gazing, "
        .. "or directing one's sight toward someone or something."
    local html = "<p>" .. sentence .. "</p><p>" .. definition .. "</p>"
    -- counted together, the sentence's words make the window an Arabic text, and
    -- the definition, which opens with an Arabic word, keeps that direction
    TestRunner:assertEqual(Bidi.mainDirection((html:gsub("<[^>]*>", ""))), "rtl", "the sentence outvotes the definition")
    local counted = Bidi.addHtmlBidiAttributes(html, {})
    TestRunner:assertTrue(counted:find('<p dir="rtl">' .. definition, 1, true) ~= nil, "what the count alone gives: the definition right-to-left")
    -- the answer judged on its own words: an English line; the sentence stays right-to-left
    TestRunner:assertEqual(Bidi.mainDirection(definition), "ltr", "the answer's own direction")
    local named = Bidi.addHtmlBidiAttributes(html, { main = "ltr" })
    TestRunner:assertTrue(named:find("<p>" .. definition, 1, true) ~= nil, "the definition left-to-right")
    TestRunner:assertTrue(named:find('<p dir="rtl">' .. sentence, 1, true) ~= nil, "the sentence right-to-left, by its own words")
    -- the window: its answer's direction from the text after the excerpt, only where an excerpt is shown
    require("mock_koreader")   -- the window's module needs KOReader's widgets to load
    local Viewer = require("koassistant.ui.chatgptviewer")
    local plain = sentence:gsub("</?strong>", "**")
    local text = plain .. "\n\n**" .. WORD .. "**, noun — the act of looking."
    local window = { compact_view = true, original_history = { source_excerpt = plain } }
    TestRunner:assertEqual(Viewer._answerDirection(window, text), "ltr", "a dictionary window with its excerpt: the answer's words")
    TestRunner:assertEqual(Viewer._answerDirection({ compact_view = true, original_history = {} }, text), nil, "no excerpt shown: the pass counts")
    TestRunner:assertEqual(Viewer._answerDirection({ original_history = { source_excerpt = plain } }, text), nil, "a chat window: the pass counts")
    TestRunner:assertEqual(Viewer._answerDirection({ dictionary_view = true, _message_history = { source_excerpt = "other" } }, text), nil,
        "an excerpt that is not what the text opens with: the pass counts")
    TestRunner:assertEqual(Viewer._answerDirection(window, plain), nil, "no answer yet: nothing to judge by")
    -- a dictionary window of a right-to-left language keeps its own rule
    TestRunner:assertTrue(Bidi.addHtmlBidiAttributes("<p>" .. AR2 .. " noun, a thing</p>", { use_starts_with_rtl = true, main = "ltr" })
        :find('<p dir="rtl">', 1, true) ~= nil, "the headword rule of a right-to-left dictionary language stands")
end)

-- The plain-text paths (the Plain Text view, the minimal popup) say a mixed
-- line's direction with a mark at its start. Until 2026-11-17 every line that
-- held both scripts got the left-to-right mark, so an Arabic sentence with an
-- English name in it came out in the wrong order (the maintainer: "rtl mixed
-- also broken"; seen in the real app the same day).
TestRunner:test("plain text: a mixed line takes the Markdown view's direction, said with a mark at its start", function()
    require("mock_koreader")
    local strip = require("koassistant.ui.chatgptviewer").stripMarkdown
    local LRM, RLM = "\226\128\142", "\226\128\143"
    -- (the text opens with the widget's formatting header, U+FFF1: not part of a line)
    local function lines(text)
        local out = {}
        for l in (strip(text, nil):gsub("^\239\191\177", "") .. "\n"):gmatch("([^\n]*)\n") do out[#out + 1] = l end
        return out
    end
    local function starts(line, mark) return line:sub(1, 3) == mark end
    -- an Arabic answer: a sentence with English names in it, a list item, a line that opens with a Latin name
    local arabic = lines("عاصمة فرنسا هي باريس (Paris)، وهي أكبر مدن البلاد وأشهرها.\n\n"
        .. "1. المدينة تقع على نهر السين (the Seine).\n\n"
        .. "Paris هي عاصمة فرنسا وأكبر مدنها.\n\n"
        .. "اللغة الرسمية هي الفرنسية.\n\n"
        .. "A short English note with كلمة inside it, written in English.")
    TestRunner:assertTrue(starts(arabic[1], RLM), "an Arabic sentence with an English name: right-to-left")
    TestRunner:assertTrue(starts(arabic[3], RLM), "an Arabic list item with an English name: right-to-left")
    TestRunner:assertTrue(starts(arabic[5], RLM), "an Arabic line that opens with a Latin name: right-to-left")
    TestRunner:assertTrue(not starts(arabic[7], RLM) and not starts(arabic[7], LRM), "a line of one script: no mark, the widget reads it")
    TestRunner:assertTrue(starts(arabic[9], LRM), "an English line with an Arabic word, in an Arabic answer: left-to-right")
    -- an English answer: a definition that opens with the headword, a label with Arabic words after it
    local english = lines("**النظر**, noun, the act of looking or directing one's sight toward something.\n\n"
        .. "Synonyms: نظرة، رؤية، مشاهدة، بصر\n\n"
        .. "It is common in modern prose and in classical texts alike.")
    TestRunner:assertTrue(starts(english[1], LRM), "an English definition that opens with the Arabic headword: left-to-right")
    TestRunner:assertTrue(starts(english[3], LRM), "a label in the answer's language, then Arabic words: left-to-right (the Markdown view's rule)")
    TestRunner:assertTrue(not starts(english[5], LRM) and not starts(english[5], RLM), "an English line: no mark")
    -- each message of a chat on its own language
    local chat = lines("▶ User:\n\nWhat does كتاب mean?\n\n◉ KOAssistant:\n\nكتاب (book) هو مجموعة من الأوراق المكتوبة أو المطبوعة.")
    TestRunner:assertTrue(starts(chat[3], LRM), "the English question that quotes an Arabic word")
    TestRunner:assertTrue(starts(chat[7], RLM), "the Arabic answer that glosses in English")
    -- the left-to-right mark after a bold word belongs to left-to-right lines only
    local bold = lines("عاصمة فرنسا هي **باريس** (Paris)، وهي أكبر مدن البلاد.")
    TestRunner:assertTrue(not bold[1]:find(LRM, 1, true), "a right-to-left line: no left-to-right mark after its bold word")
    local headword = lines("**كتاب**, noun, a set of written pages bound together.")
    TestRunner:assertTrue(select(2, headword[1]:gsub(LRM, "")) == 2, "a left-to-right line: the mark at its start and after its bold headword")
    -- a window that is right-to-left as a whole says nothing per line
    local whole = strip("عاصمة فرنسا هي باريس (Paris).", true)
    TestRunner:assertTrue(not whole:find(LRM, 1, true) and not whole:find(RLM, 1, true), "a right-to-left window: no marks")
end)

return TestRunner:summary()
