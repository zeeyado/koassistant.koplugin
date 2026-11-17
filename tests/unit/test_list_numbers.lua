-- Numbered lists as the answer numbered them (koassistant/ui/list_numbers.lua,
-- B691; the maintainer, 2026-11-17: "Md often numbered list only 1"). The
-- Markdown library drops an item's number and makes one list per item when a
-- blank line separates the items; MuPDF numbers every list from 1. mark()
-- carries each number through the library, resolve() reads it back on the
-- whole document. The HTML here is what the library gives for each shape
-- (read in the app's own runtime, 2026-11-17); the shapes are streamed piece
-- by piece against the whole conversion in tests/scenarios/s13_stream_pieces.
--
-- Run: lua tests/unit/test_list_numbers.lua  (or lua tests/run_tests.lua --unit)

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

local LN = require("koassistant.ui.list_numbers")
local TestRunner = require("test_runner"):new()

print("")
print(string.rep("=", 50))
print("  Unit Tests: Numbered lists keep their numbers")
print(string.rep("=", 50))

local O, C = "\238\128\128", "\238\128\129"
local function m(n) return O .. n .. C end
-- what the Markdown library makes of marked items: one list per run of items
local function ol(...)
    local items = {}
    for _i, item in ipairs({ ... }) do items[#items + 1] = "<li>" .. item .. "</li>" end
    return "<ol>" .. table.concat(items) .. "</ol>"
end
local function clean(html) return not html:find(O, 1, true) and not html:find(C, 1, true) end

TestRunner:test("mark: a numbered item at the margin carries its number; nothing else changes", function()
    TestRunner:assertEqual(LN.mark("1. first\n2. second"), "1. " .. m(1) .. "first\n2. " .. m(2) .. "second", "two items")
    TestRunner:assertEqual(LN.mark("12) twelfth"), "12) " .. m(12) .. "twelfth", "a bracket after the number")
    TestRunner:assertEqual(LN.mark("3.  **bold** first"), "3.  " .. m(3) .. "**bold** first", "the gap kept as written")
    TestRunner:assertEqual(LN.mark("   2. indented under an item"), "   2. indented under an item", "an indented item is its parent's")
    TestRunner:assertEqual(LN.mark("In 1986. A year"), "In 1986. A year", "a number inside a line")
    TestRunner:assertEqual(LN.mark("3.14 is pi"), "3.14 is pi", "no space after the dot")
    TestRunner:assertEqual(LN.mark("```\n1. code\n```\n1. item"), "```\n1. code\n```\n1. " .. m(1) .. "item", "a line inside a code fence is code")
    TestRunner:assertEqual(LN.mark("~~~\n1. code\n~~~"), "~~~\n1. code\n~~~", "a tilde fence too")
    local plain = "No list here.\n\nJust two paragraphs."
    TestRunner:assertTrue(LN.mark(plain) == plain, "a text with no numbered item comes back as it is")
    TestRunner:assertEqual(LN.mark("1. a\n"), "1. " .. m(1) .. "a\n", "the last line's end kept")
    TestRunner:assertEqual(LN.mark(nil), nil, "no text")
end)

TestRunner:test("resolve: items with blank lines between them are one list, numbered 1, 2, 3", function()
    local html = ol(m(1) .. "first") .. ol(m(2) .. "second") .. "\n" .. ol(m(3) .. "third")
    TestRunner:assertEqual(LN.resolve(html), "<ol><li>first</li><li>second</li><li>third</li></ol>", "one list")
    TestRunner:assertEqual(LN.resolve("<ul><li>a</li></ul><ul><li>b</li></ul>"), "<ul><li>a</li><li>b</li></ul>", "bullets too")
    TestRunner:assertEqual(LN.resolve(ol(m(1) .. "a", m(2) .. "b")), "<ol><li>a</li><li>b</li></ol>", "a tight list as it was")
    TestRunner:assertEqual(LN.resolve(ol(m(1) .. "a", m(1) .. "b", m(1) .. "c")), "<ol><li>a</li><li>b</li><li>c</li></ol>",
        "every item written 1.: a list (the first number alone says where it starts)")
end)

TestRunner:test("resolve: a list that goes on after another block keeps the answer's numbers, and so does the list it goes on from", function()
    local html = ol(m(1) .. "first") .. "<p>About it.</p>" .. ol(m(2) .. "second") .. "<p>More.</p>" .. ol(m(3) .. "third")
    TestRunner:assertEqual(LN.resolve(html), "<p>1. first</p><p>About it.</p><p>2. second</p><p>More.</p><p>3. third</p>",
        "1, 2, 3 as written (they showed 1, 1, 1)")
    local two = ol(m(1) .. "a", m(2) .. "b") .. "<pre><code>x</code></pre>" .. ol(m(3) .. "c", m(4) .. "d")
    TestRunner:assertEqual(LN.resolve(two), "<p>1. a</p><p>2. b</p><pre><code>x</code></pre><p>3. c</p><p>4. d</p>", "two items, a code block, two more")
    TestRunner:assertEqual(LN.resolve(ol(m(3) .. "third", m(4) .. "fourth")), "<p>3. third</p><p>4. fourth</p>", "a list that starts at 3")
    TestRunner:assertEqual(LN.resolve(ol(m(3) .. "a", m(3) .. "b")), "<p>3. a</p><p>4. b</p>", "counted on from its first number")
    -- two lists that each start at 1 are two lists
    local apart = ol(m(1) .. "a", m(2) .. "b") .. "<p>Then another:</p>" .. ol(m(1) .. "c", m(2) .. "d")
    TestRunner:assertEqual(LN.resolve(apart), "<ol><li>a</li><li>b</li></ol><p>Then another:</p><ol><li>c</li><li>d</li></ol>", "two lists of their own")
    -- a list that does not go on from the one before it leaves that one alone
    local jump = ol(m(1) .. "a", m(2) .. "b") .. "<p>Later:</p>" .. ol(m(7) .. "g")
    TestRunner:assertEqual(LN.resolve(jump), "<ol><li>a</li><li>b</li></ol><p>Later:</p><p>7. g</p>", "7 after 2: only the second as text")
end)

TestRunner:test("resolve: what stands under an item stays under it; a list inside a list is left alone; no mark is left anywhere", function()
    local sub = ol(m(1) .. "<strong>One</strong>") .. "<ul><li>sub a</li></ul>" .. ol(m(2) .. "<strong>Two</strong><ul><li>inside</li></ul>")
    local out = LN.resolve(sub)
    TestRunner:assertEqual(out, "<p>1. <strong>One</strong></p><ul><li>sub a</li></ul><p>2. <strong>Two</strong></p><ul><li>inside</li></ul>",
        "an item's own line as a paragraph, the bullets inside it after")
    -- the library's own shape: an item's indented bullets after the item, inside the numbered list
    local under = "<ol><li>" .. m(2) .. "<strong>Two</strong></li><ul><li>sub c</li><li>sub d</li></ul><li>" .. m(3) .. "Three</li></ol>"
    TestRunner:assertEqual(LN.resolve(under), "<p>2. <strong>Two</strong></p><ul><li>sub c</li><li>sub d</li></ul><p>3. Three</p>",
        "bullets the library put after their item stay with it")
    local kept = "<ol><li>" .. m(1) .. "One</li><ul><li>sub a</li></ul><li>" .. m(2) .. "Two</li></ol>"
    TestRunner:assertEqual(LN.resolve(kept), "<ol><li>One</li><ul><li>sub a</li></ul><li>Two</li></ol>", "and a list that starts at 1 keeps its shape")
    local nested = "<ol><li>" .. m(2) .. "outer<ol><li>inner</li></ol></li></ol>"
    TestRunner:assertEqual(LN.resolve(nested), "<ol><li>outer<ol><li>inner</li></ol></li></ol>", "a numbered list inside one: as the library made it")
    local stray = "<p>" .. m(4) .. "a line the library read as text</p>"
    TestRunner:assertEqual(LN.resolve(stray), "<p>a line the library read as text</p>", "a mark outside a list is taken out")
    for _i, html in ipairs({ sub, nested, stray, ol(m(1) .. "a"), ol(m(5) .. "a"), ol("unmarked", m(2) .. "b") }) do
        TestRunner:assertTrue(clean(LN.resolve(html)), "no private-use character in the result")
    end
    TestRunner:assertEqual(LN.resolve(ol("unmarked", m(2) .. "b")), "<ol><li>unmarked</li><li>b</li></ol>", "a list with an unmarked item: left as it is")
    local none = "<p>No list.</p><ul><li>a</li><li>b</li></ul>"
    TestRunner:assertTrue(LN.resolve(none) == none, "nothing to do: the same HTML")
    TestRunner:assertEqual(LN.resolve(nil), nil, "no HTML")
end)

TestRunner:test("the pipeline: marked before the library, resolved first of the passes that read the whole document", function()
    local f = assert(io.open(PLUGIN_DIR .. "/koassistant/ui/chatgptviewer.lua", "r"))
    local src = f:read("*a")
    f:close()
    TestRunner:assertTrue(src:find('MD(require("koassistant.ui.list_numbers").mark(preprocessed_text), {})', 1, true) ~= nil,
        "the library is given the marked text")
    local resolve_at = src:find('html_body = require("koassistant.ui.list_numbers").resolve(html_body)', 1, true)
    local bidi_at = src:find("html_body = addHtmlBidiAttributes(html_body,", 1, true)
    TestRunner:assertTrue(resolve_at ~= nil and bidi_at ~= nil and resolve_at < bidi_at,
        "resolved in the second half (the stream view's pieces are joined by then), before the direction pass counts a list's items")
end)

return TestRunner:summary()
