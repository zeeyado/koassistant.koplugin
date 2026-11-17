-- A translate window's lines are paragraphs (B697, the maintainer's note of
-- 2026-11-17 about Translate Page on an Arabic book: "line breaks issue").
-- KOReader hands a page over with one line break between its paragraphs, the
-- model answers the same way, and Markdown reads a single line break as a
-- space: the paragraphs showed as one block. The step under test puts a blank
-- line between two lines of plain text and leaves every line the Markdown
-- library gives a meaning alone.
--
-- Run: lua tests/unit/test_translate_lines.lua  (or lua tests/run_tests.lua --unit)

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
    return plugin_dir
end
local PLUGIN_DIR = setupPaths()
require("mock_koreader")

local TestRunner = require("test_runner"):new()
local ChatGPTViewer = require("koassistant.ui.chatgptviewer")
local lines = ChatGPTViewer._lineParagraphs

print("")
print(string.rep("=", 50))
print("  Unit Tests: a translate window's lines are paragraphs")
print(string.rep("=", 50))

TestRunner:test("two lines of plain text get a blank line between them", function()
    TestRunner:assertEqual(lines("first\nsecond\nthird"), "first\n\nsecond\n\nthird")
    TestRunner:assertEqual(lines("first\nsecond\n"), "first\n\nsecond\n", "the text's own end is kept")
    TestRunner:assertEqual(lines("one line"), "one line")
    TestRunner:assertEqual(lines(""), "")
    TestRunner:assertEqual(lines(nil), nil)
    TestRunner:assertEqual(lines("first\n\nsecond"), "first\n\nsecond", "paragraphs that are apart already stay as they are")
    TestRunner:assertEqual(lines("first\n\n\nsecond\nthird"), "first\n\n\nsecond\n\nthird")
end)

TestRunner:test("the translate window's own text: the original and the translation, each line apart", function()
    -- MessageHistory:createTranslateViewText's shape
    local text = "▶ سطر أول\nسطر ثان\n\n---\n\n◉ A first line\nA second line\n\n"
    TestRunner:assertEqual(lines(text), "▶ سطر أول\n\nسطر ثان\n\n---\n\n◉ A first line\n\nA second line\n\n")
end)

TestRunner:test("lines the Markdown library gives a meaning are left alone", function()
    for _idx, text in ipairs({
        "Intro:\n- one\n- two\n- three",                    -- a list under its line
        "1. first\n2. second",                               -- numbered items
        "- item\n  its second line",                         -- an item's own continuation
        "# Heading\ntext under it",                          -- a heading
        "Title\n=====\ntext",                                -- a heading by its underline
        "> a quote\n> its second line",                      -- a quote
        "| a | b |\n|---|---|\n| 1 | 2 |",                   -- a table
        "a | b\n--- | ---\n1 | 2",                           -- a table without its outer pipes
        "text\n---\nmore",                                   -- a rule (or an underline)
        "<div>\ninside\n</div>",                             -- an HTML block
        "    indented code\n    its second line",            -- indented code
        "\tindented with a tab\n\tsecond",
    }) do
        TestRunner:assertEqual(lines(text), text, "untouched: " .. text:gsub("\n", " / "))
    end
end)

TestRunner:test("nothing inside a code fence or a display formula", function()
    local fence = "before\n```\nline one\nline two\n```\nafter"
    TestRunner:assertEqual(lines(fence), fence, "a fence, and the lines that touch it")
    local tilde = "~~~\na\nb\n~~~"
    TestRunner:assertEqual(lines(tilde), tilde)
    local formula = "so\n$$\nx = y\ny = z\n$$\nthen"
    TestRunner:assertEqual(lines(formula), formula, "a display formula across lines")
    local bracket = "so\n\\[\nx = y\ny = z\n\\]\nthen"
    TestRunner:assertEqual(lines(bracket), bracket, "and one in brackets")
    TestRunner:assertEqual(lines("a $$x$$ b\nnext"), "a $$x$$ b\n\nnext", "a formula closed on its line is text")
    TestRunner:assertEqual(lines("```\ncode\n```\n\nfirst\nsecond"), "```\ncode\n```\n\nfirst\n\nsecond", "after the fence, lines are paragraphs again")
end)

TestRunner:test("a line's fate rests on the line before it, never across a blank line", function()
    -- what lets the Markdown stream view convert a translation in pieces cut
    -- at blank lines: each piece alone gives what the whole gives
    local a, b = "one\ntwo\n- item\nthree\nfour\n", "five\nsix\n"
    TestRunner:assertEqual(lines(a) .. "\n" .. lines(b), lines(a .. "\n" .. b))
end)

TestRunner:test("only a translate window does it: the viewer's mark, else the request's", function()
    local f = assert(io.open(PLUGIN_DIR .. "/koassistant/ui/chatgptviewer.lua", "r"))
    local src = f:read("*a")
    f:close()
    TestRunner:assertTrue(src:find("if linesAreParagraphs(viewer) then source_text = lineParagraphs(source_text) end", 1, true) ~= nil,
        "the pipeline's first half applies it, so the window and the stream view that fills it agree")
    local rule = src:match("local function linesAreParagraphs%(viewer%)(.-)\nend\n")
    TestRunner:assertTrue(rule and rule:find("viewer.translate_view == true", 1, true) ~= nil
        and rule:find("f.translate_view == true", 1, true) ~= nil, "the window's own mark, else the request's features")
end)

return TestRunner:summary()
