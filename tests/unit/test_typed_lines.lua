-- The reader's own lines in the Markdown view (B712). A message typed with
-- line breaks in it showed as one block: Markdown reads a line break as a
-- space, while the Plain Text view showed the lines as typed. The step under
-- test makes each typed line of plain text a paragraph (a blank line between
-- two of them, the translate window's rule), inside the reader's own messages
-- only, and leaves every line the Markdown library gives a meaning alone.
--
-- Run: lua tests/unit/test_typed_lines.lua  (or lua tests/run_tests.lua --unit)

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
local MessageHistory = require("koassistant.request.message_history")
local typed = ChatGPTViewer._typedLineParagraphs

print("")
print(string.rep("=", 50))
print("  Unit Tests: the reader's typed lines")
print(string.rep("=", 50))

-- A chat window's text as MessageHistory writes it
local function chat(...)
    local h = MessageHistory:new("system prompt")
    h:addUserMessage("ctx", true)
    for i, text in ipairs({ ... }) do
        if i % 2 == 1 then h:addUserMessage(text, false) else h:addAssistantMessage(text, "model-x") end
    end
    return h:createResultText(nil, { features = {} })
end

-- A text with its blank lines taken out: what the step may add, nothing else
local function joined(text)
    local out = text
    repeat
        local n
        out, n = out:gsub("\n\n", "\n")
    until n == 0
    return out
end

TestRunner:test("each typed line is a paragraph", function()
    local text = chat("first line\nsecond line\nthird line", "An answer.")
    local out = typed(text)
    TestRunner:assertTrue(out:find("▶ User:\n\nfirst line\n\nsecond line\n\nthird line\n\n", 1, true) ~= nil,
        "a blank line between the typed lines: " .. out:gsub("\n", " / "))
    TestRunner:assertEqual(joined(out), joined(text), "only blank lines are added")
    TestRunner:assertEqual(typed("no label at all\nsecond line"), "no label at all\nsecond line")
    TestRunner:assertEqual(typed(""), "")
    TestRunner:assertEqual(typed(nil), nil)
end)

TestRunner:test("an answer's own line breaks are still Markdown's", function()
    local text = chat("one\ntwo", "An answer whose line\ngoes on here.\n\nAnd a second\nparagraph.", "three\nfour", "Short.")
    local out = typed(text)
    TestRunner:assertTrue(out:find("An answer whose line\ngoes on here.\n\nAnd a second\nparagraph.", 1, true) ~= nil,
        "the answer is as it was")
    TestRunner:assertTrue(out:find("\none\n\ntwo\n", 1, true) ~= nil, "the first question")
    TestRunner:assertTrue(out:find("\nthree\n\nfour\n", 1, true) ~= nil, "and the reply after the answer")
    TestRunner:assertEqual(#out - #text, 2, "two blank lines in all")
end)

TestRunner:test("paragraphs the reader typed apart stay as they are", function()
    local text = chat("first\n\nsecond\nthird\n\n\nfourth", "Yes.")
    local out = typed(text)
    TestRunner:assertTrue(out:find("first\n\nsecond\n\nthird\n\n\nfourth\n", 1, true) ~= nil, out:gsub("\n", " / "))
end)

TestRunner:test("lines the Markdown library gives a meaning are left alone", function()
    for _idx, message in ipairs({
        "Compare:\n- one\n- two",                            -- a list under its line
        "1. first\n2. second",                               -- numbered items
        "# Heading\ntext under it",                          -- a heading
        "Title\n=====\ntext",                                -- a heading by its underline
        "> a quote\n> its second line",                      -- a quote
        "| a | b |\n|---|---|\n| 1 | 2 |",                   -- a table
        "    indented code\n    its second line",            -- indented code
        "```\nline one\nline two\n```",                      -- a code fence
        "so\n$$\nx = y\ny = z\n$$",                          -- a display formula
    }) do
        local text = chat(message, "Yes.")
        TestRunner:assertEqual(typed(text), text, "untouched: " .. message:gsub("\n", " / "))
    end
    local mixed = typed(chat("intro one\nintro two\n- an item\nafter one\nafter two", "Yes."))
    TestRunner:assertTrue(mixed:find("intro one\n\nintro two\n- an item\nafter one\n\nafter two\n", 1, true) ~= nil,
        "text lines around a list: " .. mixed:gsub("\n", " / "))
end)

TestRunner:test("windows without the reader's label are as they were", function()
    local h = MessageHistory:new("system prompt")
    h:addUserMessage("Translate: a\nb", true)
    h:addAssistantMessage("line one\nline two", "model-x")
    local translate = h:createTranslateViewText("a first line\na second line", false)
    TestRunner:assertEqual(typed(translate), translate, "a translate window (its own rule makes its lines paragraphs)")
    local compact = h:createResultText("word", { features = { compact_view = true } })
    TestRunner:assertEqual(typed(compact), compact, "a compact window shows no labels")
    local quoted = "*A notice\nof two lines*\n\n---\n\n" .. chat("a question", "Yes.")
    TestRunner:assertEqual(typed(quoted), quoted, "what stands above the first label")
end)

TestRunner:test("the chat window's own conversion applies it, the shared pipeline does not", function()
    local f = assert(io.open(PLUGIN_DIR .. "/koassistant/ui/chatgptviewer.lua", "r"))
    local src = f:read("*a")
    f:close()
    TestRunner:assertTrue(src:find("markdownHtml(self, typedLineParagraphs(text), {", 1, true) ~= nil,
        "ChatGPTViewer:_markdownHtml, the one conversion of a window's whole text")
    local _s, calls = src:gsub("typedLineParagraphs%(", "")
    TestRunner:assertEqual(calls, 2, "its definition and that one call: the stream view's pieces never see it")
end)

return TestRunner:summary()
