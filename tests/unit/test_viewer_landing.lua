-- The landing on a reply (B561, 2026-11-06): the page break that opens the
-- newest reply on a fresh page sits AFTER the reply's label, so the question,
-- the usage line and the label stay on the page before and the landed page
-- starts with the reply's first line; a short first question gets the page
-- too (the 2026-08-12 skip is gone); the first answer of a chat lands like
-- any other; and a step up while the stream is followed pauses the follow
-- AND scrolls (the consumed press of 2026-08-15 is gone), except on the
-- first page where it only pauses.
--
-- Run: lua tests/unit/test_viewer_landing.lua  (or lua tests/run_tests.lua --unit)

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
local plugin_dir = setupPaths()
require("mock_koreader")

local TestRunner = require("test_runner"):new()
local ChatGPTViewer = require("koassistant.ui.chatgptviewer")
local breaks = ChatGPTViewer._applyExchangePageBreaks

local SPACER = '<div class="koa-exchange-break"></div>'
local LABEL = "<p>◉ KOAssistant:</p>"
local ON = { features = {} }

local function count(s, needle)
    local n, from = 0, 1
    while true do
        local a, b = s:find(needle, from, true)
        if not a then return n end
        n = n + 1
        from = b + 1
    end
end

local function read(rel)
    local f = assert(io.open(plugin_dir .. "/" .. rel, "r"))
    local s = f:read("*a")
    f:close()
    return s
end

print("Running: test_viewer_landing")
print("")
print("  [the spacer after the newest label]")

TestRunner:test("the question, the usage line and the label stay before the break", function()
    local body = "<p>▶ User:</p><p>q</p><p>🧠 Reasoning used</p>" .. LABEL .. "<p>the answer</p><p>more</p>"
    local out, placed = breaks(body, ON, nil, nil)
    TestRunner:assertEqual(placed, true)
    TestRunner:assertEqual(count(out, SPACER), 1)
    TestRunner:assertTrue(out:find(LABEL .. SPACER .. "<p>the answer</p>", 1, true) ~= nil,
        "the spacer sits between the label and the reply's first paragraph")
    TestRunner:assertTrue(out:find("<p>🧠 Reasoning used</p>" .. LABEL, 1, true) ~= nil,
        "the usage line keeps its place before the label")
end)

TestRunner:test("the newest reply only", function()
    local body = "<p>▶ User:</p><p>q1</p>" .. LABEL .. "<p>a1</p><p>▶ User:</p><p>q2</p>" .. LABEL .. "<p>a2</p>"
    local out, placed = breaks(body, ON, nil, nil)
    TestRunner:assertEqual(placed, true)
    TestRunner:assertEqual(count(out, SPACER), 1)
    TestRunner:assertTrue(out:find(LABEL .. SPACER .. "<p>a2</p>", 1, true) ~= nil, "after the second label")
    TestRunner:assertTrue(out:find(LABEL .. "<p>a1</p>", 1, true) ~= nil, "the first exchange untouched")
end)

TestRunner:test("a short first question gets the page too", function()
    local body = "<p>▶ User:</p><p>hi</p>" .. LABEL .. "<p>hello</p>"
    local _out, placed = breaks(body, ON, nil, nil)
    TestRunner:assertEqual(placed, true)
end)

TestRunner:test("the setting off: untouched", function()
    local body = "<p>▶ User:</p><p>q</p>" .. LABEL .. "<p>a</p>"
    local out, placed = breaks(body, { features = { chat_exchange_page_breaks = false } }, nil, nil)
    TestRunner:assertEqual(out, body)
    TestRunner:assertEqual(placed, false)
end)

TestRunner:test("no label (a streamed artifact text): untouched", function()
    local body = "<p>plain text</p><p>more</p>"
    local out, placed = breaks(body, ON, nil, nil)
    TestRunner:assertEqual(out, body)
    TestRunner:assertEqual(placed, false)
end)

TestRunner:test("nothing after the label: no blank last page", function()
    local body = "<p>▶ User:</p><p>q</p>" .. LABEL .. "<p> </p>"
    local out, placed = breaks(body, ON, nil, nil)
    TestRunner:assertEqual(out, body)
    TestRunner:assertEqual(placed, false)
end)

print("")
print("  [the plain-text landing tops the reply's first line]")

TestRunner:test("the line after the label and its blank line", function()
    local text = "▶ User:\n\nq\n\n◉ KOAssistant:\n\nanswer line\n\nmore"
    local lines = {
        { offset = 1, end_offset = 7 }, { offset = 9, end_offset = 8 },
        { offset = 10, end_offset = 10 }, { offset = 12, end_offset = 11 },
        { offset = 13, end_offset = 26 }, { offset = 28, end_offset = 27 },
        { offset = 29, end_offset = 39 }, { offset = 41, end_offset = 40 },
        { offset = 42, end_offset = 45 },
    }
    local got_ratio, got_force
    local v = setmetatable({
        text = text,
        render_markdown = false,
        configuration = { features = {} },
        scroll_text_w = {
            text_widget = { lines_per_page = 4, vertical_string_list = lines },
            scrollToRatio = function(_self, ratio, force) got_ratio, got_force = ratio, force end,
            moveCursorToCharPos = function() end,
        },
    }, { __index = ChatGPTViewer })
    v:scrollToLastQuestion()
    TestRunner:assertEqual(got_force, false)
    -- line 7 ("answer line") on top: (R - 1 + lpp / 2 + 0.5) / #lines
    TestRunner:assertTrue(got_ratio and math.abs(got_ratio - (7 - 1 + 2 + 0.5) / 9) < 1e-9,
        "the reply's first text line is the top line, got " .. tostring(got_ratio))
end)

print("")
print("  [the first answer lands, the stream's first step up scrolls]")

TestRunner:test("dialogs.lua lands the first answer too", function()
    local src = read("koassistant/ui/dialogs.lua")
    TestRunner:assertTrue(src:find("scroll_to_last_question = not (temp_config and temp_config.features and temp_config.features.scroll_to_last_message == false)\n"
        .. "            and history and history.getAssistantTurnCount and history:getAssistantTurnCount() >= 1,", 1, true) ~= nil,
        "the first viewer lands from the first answer on")
    TestRunner:assertTrue(src:find("local to_last_question = history and history.getAssistantTurnCount\n"
        .. "                        and history:getAssistantTurnCount() >= 1", 1, true) ~= nil,
        "the reply viewer lands on every reply")
end)

TestRunner:test("the stream window's up hooks pause and then scroll", function()
    local src = read("koassistant/request/stream_handler.lua")
    TestRunner:assertTrue(src:find('turnOffAutoScroll%("scroll%-up button"%)\n%s*end\n%s*return original_scrollUp%(self_widget, %.%.%.%)') ~= nil,
        "the dialog's up button scrolls after the pause")
    TestRunner:assertTrue(src:find('turnOffAutoScroll%("swipe/key up"%)\n%s*end\n%s*return orig_scrollText%(self_w, direction, %.%.%.%)') ~= nil,
        "a swipe or key up scrolls after the pause")
    TestRunner:assertTrue(src:find('turnOffAutoScroll%("page%-up"%)\n%s*local handled = orig_onScrollUp%(self_w, %.%.%.%)') ~= nil,
        "page-up scrolls after the pause and is consumed only on the first page")
end)

return TestRunner:summary()
