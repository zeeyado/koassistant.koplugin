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
print("  [the break on the newest label]")

-- The break rides the label's own paragraph (audit 2026-11-12): as an empty
-- spacer block after it, the block spilled onto a page of its own whenever
-- the label was a page's last line, and the window landed on that empty page
-- (tests/scenarios/s09_reply_landing.lua shows it in the real widget)
local BREAK_LABEL = '<p class="koa-exchange-break">◉ KOAssistant:</p>'

TestRunner:test("the question, the usage line and the label stay before the break", function()
    local body = "<p>▶ User:</p><p>q</p><p>🧠 Reasoning used</p>" .. LABEL .. "<p>the answer</p><p>more</p>"
    local out, placed = breaks(body, ON, nil, nil)
    TestRunner:assertEqual(placed, true)
    TestRunner:assertEqual(count(out, BREAK_LABEL), 1)
    TestRunner:assertEqual(count(out, SPACER), 0)
    TestRunner:assertTrue(out:find(BREAK_LABEL .. "<p>the answer</p>", 1, true) ~= nil,
        "the label carries the break and the reply's first paragraph follows it")
    TestRunner:assertTrue(out:find("<p>🧠 Reasoning used</p>" .. BREAK_LABEL, 1, true) ~= nil,
        "the usage line keeps its place before the label")
    TestRunner:assertEqual(#out, #body + #BREAK_LABEL - #LABEL)
end)

TestRunner:test("the newest reply only", function()
    local body = "<p>▶ User:</p><p>q1</p>" .. LABEL .. "<p>a1</p><p>▶ User:</p><p>q2</p>" .. LABEL .. "<p>a2</p>"
    local out, placed = breaks(body, ON, nil, nil)
    TestRunner:assertEqual(placed, true)
    TestRunner:assertEqual(count(out, BREAK_LABEL), 1)
    TestRunner:assertTrue(out:find(BREAK_LABEL .. "<p>a2</p>", 1, true) ~= nil, "on the second label")
    TestRunner:assertTrue(out:find(LABEL .. "<p>a1</p>", 1, true) ~= nil, "the first exchange untouched")
end)

TestRunner:test("a window that opens at the top keeps the released rule: the break before the label, none after a short prefix", function()
    local body = "<p>▶ User:</p><p>q</p>" .. LABEL .. "<p>the answer</p>"
    local out, placed = breaks(body, ON, nil, nil, false)
    TestRunner:assertEqual(out, body)
    TestRunner:assertEqual(placed, false)
    local _landed, placed_landing = breaks(body, ON, nil, nil, true)
    TestRunner:assertEqual(placed_landing, true)
    -- a long question: the label and its reply start the new page together
    local long = "<p>▶ User:</p><p>" .. string.rep("a long question ", 40) .. "</p>" .. LABEL .. "<p>the answer</p>"
    local out_long, placed_long = breaks(long, ON, nil, nil, false)
    TestRunner:assertEqual(placed_long, false)
    TestRunner:assertTrue(out_long:find("</p>" .. SPACER .. LABEL .. "<p>the answer</p>", 1, true) ~= nil,
        "the spacer sits before the label, which keeps its reply")
    TestRunner:assertEqual(count(out_long, BREAK_LABEL), 0)
end)

TestRunner:test("nothing before the label: no page for the label alone", function()
    local body = LABEL .. "<p>the answer</p><p>more</p>"
    local out, placed = breaks(body, ON, nil, nil, true)
    TestRunner:assertEqual(out, body)
    TestRunner:assertEqual(placed, false)
    local blank_before = "<p> </p>" .. LABEL .. "<p>the answer</p>"
    local out2, placed2 = breaks(blank_before, ON, nil, nil, true)
    TestRunner:assertEqual(out2, blank_before)
    TestRunner:assertEqual(placed2, false)
end)

TestRunner:test("the viewer hands its landing flag to the break", function()
    local src = read("koassistant/ui/chatgptviewer.lua")
    TestRunner:assertTrue(src:find("opts.carry_anchor, opts.carry_occurrence, viewer.scroll_to_last_question)", 1, true) ~= nil,
        "markdownHtml passes scroll_to_last_question")
    TestRunner:assertTrue(src:find("\n.koa%-exchange%-break {") ~= nil,
        "the CSS rule serves the label paragraph and the carry's spacer div alike")
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

print("")
print("  [the sweep of 2026-11-06: the counted occurrence, one Markdown pipeline, the per-chat tap under Auto RTL]")

TestRunner:test("plain text: the landing takes the occurrence the stream window counted, from the label", function()
    local anchor = "one two three four five six"
    local text = "▶ User: q\n\n◉ KOAssistant:\nIntro " .. anchor .. " seven.\nMiddle filler text here.\nLater "
        .. anchor .. " eight.\nEnd."
    local first = text:find(anchor, 1, true)
    local second = text:find(anchor, first + 1, true)
    local _s1, c1 = text:sub(1, first - 1):gsub("[^\128-\191]", "")
    local _s2, c2 = text:sub(1, second - 1):gsub("[^\128-\191]", "")
    local function land(occ)
        local got
        local v = setmetatable({ text = text, render_markdown = false, _stream_carry_anchor = anchor,
            _stream_carry_occurrence = occ,
            scroll_text_w = { moveCursorToCharPos = function(_self, pos) got = pos end } },
            { __index = ChatGPTViewer })
        TestRunner:assertTrue(v:landOnStreamPosition(), "landed")
        return got
    end
    TestRunner:assertEqual(land(2), c2 + 1, "the second copy")
    TestRunner:assertEqual(land(1), c1 + 1, "the first copy")
    TestRunner:assertEqual(land(nil), c1 + 1, "no count: the first, as before")
    TestRunner:assertEqual(land(5), c2 + 1, "past the count: the last copy found")
end)

TestRunner:test("Markdown: the pages from the marker's are walked by their match counts", function()
    local anchor = "one two three four five six"
    local function land(occ, per_page)
        local scrolled
        local box = { page_number = 1, page_count = 6 }
        function box:findText(needle)
            if needle:find("KOAssistant", 1, true) then
                self._search_index = { [1] = { {} } }
                self._match_page_list = { 1 }
            else
                self._search_index = {}
                self._match_page_list = {}
                for page, n in pairs(per_page) do
                    local rects = {}
                    for _i = 1, n do rects[#rects + 1] = {} end
                    self._search_index[page] = rects
                    table.insert(self._match_page_list, page)
                end
                table.sort(self._match_page_list)
            end
            return true
        end
        function box:clearSearch() end
        local v = setmetatable({ text = "x", render_markdown = true, _stream_carry_anchor = anchor,
            _stream_carry_occurrence = occ,
            scroll_text_w = { htmlbox_widget = box, scrollToRatio = function(_self, r) scrolled = r end } },
            { __index = ChatGPTViewer })
        TestRunner:assertTrue(v:landOnStreamPosition(), "landed")
        return scrolled
    end
    local function ratio(page) return (page - 0.5) / 6 end
    TestRunner:assertEqual(land(1, { [2] = 1, [4] = 1 }), ratio(2), "the first copy's page")
    TestRunner:assertEqual(land(2, { [2] = 1, [4] = 1 }), ratio(4), "the second copy's page")
    TestRunner:assertEqual(land(2, { [2] = 2, [4] = 1 }), ratio(2), "two copies on one page: still that page")
    TestRunner:assertEqual(land(3, { [2] = 2, [4] = 1 }), ratio(4), "the third is on the next")
    TestRunner:assertEqual(land(9, { [2] = 2, [4] = 1 }), ratio(4), "past the count: the last page holding it")
end)

TestRunner:test("the late carry path reads the counted occurrence too", function()
    local src = read("koassistant/ui/chatgptviewer.lua")
    local a = src:find("function ChatGPTViewer:landOnStreamPosition()", 1, true)
    local head = src:sub(a, a + 1200)
    TestRunner:assertTrue(head:find("self._stream_carry_occurrence = pending.occurrence", 1, true) ~= nil)
end)

TestRunner:test("the refresh rebuilds through the one Markdown pipeline; the translate toggle keeps the math", function()
    local src = read("koassistant/ui/chatgptviewer.lua")
    local a = src:find("function ChatGPTViewer:refreshMarkdownDisplay()", 1, true)
    local body = src:sub(a, src:find("\nend\n", a, true))
    TestRunner:assertTrue(body:find("self:rebuildScrollWidget()", 1, true) ~= nil, "rebuildScrollWidget")
    TestRunner:assertTrue(body:find("ScrollHtmlWidget:new", 1, true) == nil, "no hand copy of the pipeline left")
    local t = src:find("function ChatGPTViewer:toggleTranslateQuoteVisibility()", 1, true)
    local tbody = src:sub(t, src:find("\nend\n", t, true))
    TestRunner:assertTrue(tbody:find("self:_markdownHtml(self.text)", 1, true) ~= nil, "the one pipeline, the math pass inside it")
    TestRunner:assertTrue(tbody:find("autoLinkUrls(", 1, true) == nil, "no hand copy of the pipeline")
end)

TestRunner:test("no plain-text switch for right-to-left text is left; the windows keep direction only (B621)", function()
    local src = read("koassistant/ui/chatgptviewer.lua")
    for _idx, gone in ipairs({ "rtl_chat_text_mode", "rtl_translate_text_mode", "rtl_dictionary_text_mode",
        "reapplyRtlMode", "getLatestResponse" }) do
        TestRunner:assertTrue(src:find(gone, 1, true) == nil, gone .. " is gone from the viewer")
    end
    -- the dictionary and translate windows set the plain-text widget's direction, nothing else
    local a = src:find("if self.compact_view or self.dictionary_view then\n      if self.configuration.features.dictionary_text_mode then", 1, true)
    TestRunner:assertTrue(a ~= nil, "the dictionary block")
    local block = src:sub(a, src:find("  end\n", src:find("translate_view and Languages.isRTL", a, true), true))
    local _, forced = block:gsub("self%.render_markdown = false", "")
    TestRunner:assertEqual(forced, 1, "Plain Text only on the reader's own Text Mode for Dictionary")
    -- the schema and the quick settings carry no such row
    local schema = read("koassistant/ui/settings_schema.lua")
    TestRunner:assertTrue(schema:find("rtl_chat_text_mode", 1, true) == nil and schema:find("rtl_translate_text_mode", 1, true) == nil
        and schema:find("rtl_dictionary_text_mode", 1, true) == nil, "no schema row")
end)

TestRunner:test("one Markdown pipeline: every HTML build goes through it, the span pass last", function()
    local src = read("koassistant/ui/chatgptviewer.lua")
    local _, md_calls = src:gsub("MD%(preprocessed_text, {}%)", "")
    TestRunner:assertEqual(md_calls, 1, "luamd is called in one place")
    local _, builds = src:gsub("self:_markdownHtml%(", "")
    TestRunner:assertEqual(builds, 4, "init, update, rebuild, the translate toggle")
    local _, widgets = src:gsub("self:_htmlWidget%(", "")
    TestRunner:assertEqual(widgets, 4, "the content widget built in one place, used four times")
    local _, css_sites = src:gsub("getViewerCSS%(self%.text_align, self:_scriptFontCSS%(html_body%)%)", "")
    TestRunner:assertEqual(css_sites, 1, "one CSS site")
    local a = src:find("local function markdownHtml(viewer, text, opts)", 1, true)
    local body = src:sub(a, src:find("\nend\n", a, true))
    local breaks = body:find("applyExchangePageBreaks(", 1, true)
    local spans = body:find("ScriptFonts.markRuns(", 1, true)
    TestRunner:assertTrue(breaks and spans and spans > breaks, "the spans after the page breaks")
end)

return TestRunner:summary()
