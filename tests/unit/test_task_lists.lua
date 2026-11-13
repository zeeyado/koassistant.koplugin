-- Task lists in the chat window ("- [ ] to do", "- [x] done"): the Markdown
-- library knows no task items, so both views showed the brackets as typed
-- (the maintainer, 2026-11-13). The box is now a character at the item's
-- start, in the bullet's place: taskListBoxes rewrites the source for both
-- views, taskListItems takes the bullet off the Markdown view's item. The look
-- through MuPDF and the text widget was checked in a headless render
-- (docs/research/2026-11-13/shots/).
--
-- Run: lua tests/unit/test_task_lists.lua  (or lua tests/run_tests.lua --unit)

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
local Viewer = require("koassistant.ui.chatgptviewer")
local boxes, items, strip = Viewer._taskListBoxes, Viewer._taskListItems, Viewer.stripMarkdown

local OPEN, DONE = "☐", "☑"

print("Running: test_task_lists")
print("")

TestRunner:test("an open and a done item, with any list mark, upper or lower x", function()
    TestRunner:assertEqual(boxes("- [ ] to do\n- [x] done\n* [X] also done\n+ [ ] plus"),
        "- " .. OPEN .. " to do\n- " .. DONE .. " done\n* " .. DONE .. " also done\n+ " .. OPEN .. " plus")
    TestRunner:assertEqual(boxes("  - [ ] nested"), "  - " .. OPEN .. " nested", "an indented item")
    TestRunner:assertEqual(boxes("1. [x] first\n2) [ ] second"), "1. " .. DONE .. " first\n2) " .. OPEN .. " second",
        "a numbered item")
end)

TestRunner:test("only a list item's own start is a task box", function()
    for _idx, text in ipairs({
        "an array a[ ] in prose",
        "[ ] no list mark before it",
        "- a link [x](https://example.org) later in the item",
        "- [y] another letter",
        "- [ ]no space after the box",
        "plain text without brackets",
        "",
    }) do
        TestRunner:assertEqual(boxes(text), text, text)
    end
    TestRunner:assertEqual(boxes(nil), nil)
end)

TestRunner:test("a line inside a code fence is left as typed", function()
    local text = "- [ ] before\n```\n- [ ] in the fence\n```\n- [x] after"
    TestRunner:assertEqual(boxes(text), "- " .. OPEN .. " before\n```\n- [ ] in the fence\n```\n- " .. DONE .. " after")
end)

TestRunner:test("the Markdown view: a bulleted task item gets no bullet, a numbered one keeps its number", function()
    local html = "<ul>\n<li>" .. DONE .. " done</li>\n<li>plain item</li>\n<li><p>" .. OPEN .. " loose</p></li>\n</ul>"
        .. "<ol>\n<li>" .. DONE .. " numbered</li>\n</ol>"
    local out = items(html)
    TestRunner:assertTrue(out:find('<li style="list-style-type: none">' .. DONE .. " done", 1, true) ~= nil, "a done item")
    TestRunner:assertTrue(out:find('<li style="list-style-type: none"><p>' .. OPEN .. " loose", 1, true) ~= nil, "a loose item")
    TestRunner:assertTrue(out:find("<li>plain item</li>", 1, true) ~= nil, "a plain item keeps its bullet")
    TestRunner:assertTrue(out:find("<ol>\n<li>" .. DONE .. " numbered", 1, true) ~= nil, "a numbered item keeps its number")
    TestRunner:assertEqual(items("<ul><li>no boxes here</li></ul>"), "<ul><li>no boxes here</li></ul>")
end)

TestRunner:test("the plain-text view: the box in the bullet's place", function()
    local shown = strip("Packing:\n\n- [x] passport\n- [ ] charger\n- a plain item")
    TestRunner:assertTrue(shown:find("\n" .. DONE .. " passport", 1, true) ~= nil, "done: " .. shown)
    TestRunner:assertTrue(shown:find("\n" .. OPEN .. " charger", 1, true) ~= nil, "open")
    TestRunner:assertTrue(shown:find("\n• a plain item", 1, true) ~= nil, "a plain item keeps its bullet")
    TestRunner:assertTrue(shown:find("[", 1, true) == nil, "no bracket left")
end)

return TestRunner:summary()
