-- Unit tests for koassistant/request/stream_markdown.lua (B562, 2026-11-07):
-- the Markdown view of the streaming window. The render policy (the first
-- text, a short text, a line end past the floor, the floor growing with the
-- render's cost), the widget replacing its HTML widget in place (the last
-- page while following, the reader's page kept while paused, the old widget
-- freed), the position capture (the page's first words, the anchor's ordinal
-- across the pages before), and the handler's branches by source.

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

print("\nMarkdown while streaming (B562)")

-- The mocks this widget needs beyond the shared ones, restored at the end
local SAVED = {}
for _idx, k in ipairs({ "ui/widget/scrollhtmlwidget", "device", "ui/uimanager", "koassistant.ui.chatgptviewer",
    "koassistant.request.stream_markdown" }) do SAVED[k] = package.loaded[k] end

-- A fake HTML widget: one page per 200 bytes of HTML, a document whose pages
-- carry the words the test gives
local FakeScroll = {}
FakeScroll.__index = FakeScroll
local built = {}
function FakeScroll:new(o)
    o = o or {}
    setmetatable(o, FakeScroll)
    local pages = math.max(1, math.ceil(#(o.html_body or "") / 200))
    o.htmlbox_widget = {
        page_count = pages, page_number = 1,
        document = o.fake_doc or FakeScroll.doc,
        setPageNumber = function(self_box, n) self_box.page_number = n end,
        free = function(self_box) self_box.freed = true end,
    }
    built[#built + 1] = o
    return o
end
function FakeScroll:_updateScrollBar() end
function FakeScroll:scrollText(d)
    local b = self.htmlbox_widget
    b.page_number = math.max(1, math.min(b.page_count, b.page_number + d))
end
function FakeScroll:scrollToRatio(r) self.htmlbox_widget.page_number = r == 0 and 1 or self.htmlbox_widget.page_count end
package.loaded["ui/widget/scrollhtmlwidget"] = FakeScroll
package.loaded["device"] = { screen = { scaleBySize = function(_s, n) return n end, getWidth = function() return 600 end, getHeight = function() return 800 end } }
local dirty = 0
package.loaded["ui/uimanager"] = { setDirty = function() dirty = dirty + 1 end, show = function() end, close = function() end, scheduleIn = function() end, unschedule = function() end }
package.loaded["ui/widget/container/framecontainer"].getSize = function() return { w = 600, h = 400 } end
local rendered_texts = {}
package.loaded["koassistant.ui.chatgptviewer"] = {
    markdownHtml = function(text) rendered_texts[#rendered_texts + 1] = text; return "<p>" .. text .. "</p>" end,
    viewerCSS = function() return "" end,
    extractCarryAnchor = function(s) return s:match("^(%S+%s+%S+%s+%S+)") end,
}
package.loaded["koassistant.request.stream_markdown"] = nil
local SM = require("koassistant.request.stream_markdown")

local clock = 100
SM._now = function() return clock end

TestRunner:test("the render policy: the first text, a short text, a line end past the floor", function()
    local due = SM.renderDue
    TestRunner:assertTrue(due({}, "anything", 0), "nothing rendered yet: due")
    local long = string.rep("word ", 100) .. "\n" .. string.rep("more ", 100)
    local st = { rendered = long, rendered_at = 10, floor = 1.5 }
    TestRunner:assertTrue(not due(st, long, 20), "the same text: never")
    TestRunner:assertTrue(due(st, "short", 10.1), "a short text renders at once")
    TestRunner:assertTrue(not due(st, long .. " tail", 10.5), "a longer tail on the same line, inside the floor: no")
    TestRunner:assertTrue(not due(st, long .. " tail", 20), "past the floor but no new line end: no")
    TestRunner:assertTrue(not due(st, long .. "\nnext line", 10.5), "a new line inside the floor: not yet")
    TestRunner:assertTrue(due(st, long .. "\nnext line", 11.5), "a new line past the floor: due")
    st.floor = 6
    TestRunner:assertTrue(not due(st, long .. "\nnext line", 14), "a grown floor holds longer")
    TestRunner:assertTrue(due(st, long .. "\nnext line", 16.1), "then renders")
end)

local function widget(opts)
    local parent = { koa_stream = opts or { features = {}, text_align = "auto", font_size = 20 } }
    local w = SM:new{ text = "", width = 500, height = 400, padding = 0, margin = 0, parent = parent }
    w:init()   -- KOReader's Widget:new calls init; the mock's class stub does not
    return w
end

TestRunner:test("the widget renders through the viewer's pipeline into a new HTML widget, the old one freed", function()
    built, rendered_texts, dirty = {}, {}, 0
    local w = widget()
    TestRunner:assertEqual(w.renders, 1, "init renders the empty text")
    TestRunner:assertEqual(#built, 1, "one HTML widget")
    w:setText("Hello **world**")
    TestRunner:assertEqual(w.renders, 2, "a short text renders at once")
    TestRunner:assertEqual(rendered_texts[2], "Hello **world**", "through the pipeline")
    TestRunner:assertTrue(built[1].htmlbox_widget.freed, "the first widget freed when replaced")
    TestRunner:assertEqual(w.text_widget, built[2], "the inner widget the handler's hooks find")
    TestRunner:assertTrue(w[1][1] == built[2], "placed in the frame")
    TestRunner:assertTrue(dirty >= 2, "a repaint per render")
    TestRunner:assertEqual(w:getText(), "Hello **world**")
    TestRunner:assertTrue(w.markdown_stream and not w:isTextEditable() and not w:isKeyboardVisible(), "the InputText face")
end)

TestRunner:test("following shows the last page; paused keeps the reader's page while the tail grows", function()
    built = {}
    local w = widget()
    local long = string.rep("line of text that fills some space\n", 30)   -- 5 pages at 200 bytes a page
    w.follow = true
    clock = clock + 10
    w:setText(long)
    TestRunner:assertEqual(w:pageCount(), 6, "pages")
    TestRunner:assertEqual(w:currentPage(), 6, "the last page while following")
    -- the reader pauses on page 2 (the handler sets follow = false), the text grows
    w.follow = false
    w:scrollUp(); w:scrollUp(); w:scrollUp(); w:scrollUp()
    TestRunner:assertEqual(w:currentPage(), 2, "scrolled up")
    clock = clock + 10
    w:setText(long .. string.rep("more lines arriving later\n", 30))
    TestRunner:assertTrue(w:pageCount() > 6, "more pages")
    TestRunner:assertEqual(w:currentPage(), 2, "the page kept across the render")
    -- the tail is one line longer inside the floor: no render
    local renders = w.renders
    w:setText(w.text .. "tail")
    TestRunner:assertEqual(w.renders, renders, "no render inside the floor")
    -- following resumed: the last page
    w.follow = true
    w:jumpToEnd()
    TestRunner:assertEqual(w:currentPage(), w:pageCount(), "the end")
    -- the floor grows with a slow render
    local real_now = SM._now
    local t = 200
    SM._now = function() t = t + 1; return t end   -- each call a second later: a 1 s render
    clock = t
    w.follow = true
    w:setText(w.text .. "\nanother line")
    TestRunner:assertTrue(w.floor >= SM.FLOOR and w.floor <= 6 * 1.01 * 1, "the floor from the cost: " .. tostring(w.floor))
    SM._now = real_now
end)

TestRunner:test("the position capture: the page's first words and the anchor's ordinal across the pages before", function()
    local pages = {
        { { { word = "The" }, { word = "quick" }, { word = "brown" } }, { { word = "fox" } } },
        { { { word = "Once" }, { word = "again" }, { word = "here" }, { word = "The" }, { word = "quick" }, { word = "brown" } } },
        { { { word = "The" }, { word = "quick" }, { word = "brown" }, { word = "dog" } } },
    }
    local doc = {
        openPage = function(_self, n)
            return { getPageText = function() return pages[n] end, close = function() end }
        end,
    }
    FakeScroll.doc = doc
    built = {}
    local w = widget()
    w.follow = false
    clock = clock + 10
    w:setText(string.rep("x", 700))   -- 4 pages of HTML
    local box = w.scroll_w.htmlbox_widget
    box.page_count = 3
    box.page_number = 1
    TestRunner:assertEqual(w:capturePosition(), nil, "the first page: nothing to keep")
    box.page_number = 3
    local snippet, occurrence = w:capturePosition()
    TestRunner:assertEqual(snippet, "The quick brown dog", "the page's words")
    TestRunner:assertEqual(occurrence, 3, "the anchor seen twice on the pages before: the third")
    box.page_number = 2
    snippet, occurrence = w:capturePosition()
    TestRunner:assertEqual(snippet, "Once again here The quick brown")
    TestRunner:assertEqual(occurrence, 1, "its own anchor is new")
    FakeScroll.doc = nil
end)

TestRunner:test("the stream handler: the Markdown view where the plain widget's lines were read", function()
    local f = assert(io.open(PLUGIN_DIR .. "/koassistant/request/stream_handler.lua", "r"))
    local src = f:read("*a")
    f:close()
    TestRunner:assertTrue(src:find("inputtext_class = markdown_stream and StreamMarkdown or StreamText", 1, true) ~= nil, "the class by setting")
    TestRunner:assertTrue(src:find("if iw and iw.markdown_stream then return iw:capturePosition() end", 1, true) ~= nil, "the capture")
    TestRunner:assertTrue(src:find("iw.follow = auto_scroll_active\n                    iw:setText(display)", 1, true) ~= nil, "the tick")
    TestRunner:assertTrue(src:find("if stw and stw.htmlbox_widget then return stw.htmlbox_widget.page_number end", 1, true) ~= nil, "the hooks' position")
    TestRunner:assertTrue(src:find("not hidden_streaming or false", 1, true) ~= nil, "never for a hidden stream")
    local g = assert(io.open(PLUGIN_DIR .. "/koassistant/request/gpt_query.lua", "r"))
    local gq = g:read("*a")
    g:close()
    TestRunner:assertTrue(gq:find("config.features._chat_view_mode ~= false) or false", 1, true) ~= nil, "the chat's own tap counts")
    TestRunner:assertTrue(gq:find("stream_markdown = (config.features and config.features.stream_markdown == true", 1, true) ~= nil, "the setting")
end)

for k, v in pairs(SAVED) do package.loaded[k] = v end
package.loaded["koassistant.request.stream_markdown"] = nil
package.loaded["ui/widget/container/framecontainer"].getSize = nil

print(string.format("\nResults: %d passed, %d failed", TestRunner.passed, TestRunner.failed))
return TestRunner.failed == 0
