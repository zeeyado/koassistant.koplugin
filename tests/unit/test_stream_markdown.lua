-- Unit tests for koassistant/request/stream_markdown.lua (B562, 2026-11-07):
-- the Markdown view of the streaming window. The render policy (the first
-- text, a short text, any change past the floor, the floor following the
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

-- The real viewer, for the hand-off test below (the stub replaces it for the widget tests)
local RealViewer = require("koassistant.ui.chatgptviewer")

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
local last_refresh = nil    -- the refresh type the newest setDirty asked for
local queued = {}
package.loaded["ui/uimanager"] = { setDirty = function(_s, _w, how)
        dirty = dirty + 1
        if type(how) == "function" then last_refresh = how() else last_refresh = how end
    end, show = function() end, close = function() end,
    scheduleIn = function(_s, sec, fn) queued[#queued + 1] = { sec = sec, fn = fn } end,
    unschedule = function(_s, fn) for i, q in ipairs(queued) do if q.fn == fn then table.remove(queued, i); break end end end }
package.loaded["ui/widget/container/framecontainer"].getSize = function() return { w = 600, h = 400 } end
local rendered_texts = {}
local whole_texts = {}
local failing_piece = nil   -- a piece the stand-in's first half fails on
package.loaded["koassistant.ui.chatgptviewer"] = {
    -- the pipeline's two halves: the text of a piece to its blocks, the joined blocks finished
    markdownBlocks = function(text)
        if failing_piece and text:find(failing_piece, 1, true) then return nil, "the library failed" end
        rendered_texts[#rendered_texts + 1] = text
        return "<p>" .. text .. "</p>"
    end,
    markdownFinish = function(html) return html end,
    -- the whole conversion, for a text the pieces gave up on
    markdownHtml = function(text) whole_texts[#whole_texts + 1] = text; return "<pre>" .. text .. "</pre>" end,
    viewerCSS = function() return "" end,
    extractCarryAnchor = function(s) return s:match("^(%S+%s+%S+%s+%S+)") end,
    dictionaryPlainText = RealViewer.dictionaryPlainText,   -- the window's own rule, pure
}
package.loaded["koassistant.request.stream_markdown"] = nil
local SM = require("koassistant.request.stream_markdown")

local clock = 100
SM._now = function() return clock end

TestRunner:test("the render policy: the first text, a short text, any change past the floor, the seconds left inside it", function()
    local due = SM.renderDue
    TestRunner:assertTrue(due({}, "anything", 0), "nothing rendered yet: due")
    local long = string.rep("word ", 100) .. "\n" .. string.rep("more ", 100)
    local st = { rendered = long, rendered_at = 10, floor = 1.5 }
    local d, left = due(st, long, 20)
    TestRunner:assertTrue(not d and left == nil, "the same text: never, nothing to wait for")
    TestRunner:assertTrue(due(st, "short", 10.1), "a short text renders at once")
    d, left = due(st, long .. " tail", 10.5)
    TestRunner:assertTrue(not d and math.abs(left - 1.0) < 1e-9, "inside the floor: no, a second left")
    TestRunner:assertTrue(due(st, long .. " tail", 11.5), "past the floor: any change renders (a one-paragraph answer never waits for a line end)")
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
    -- the tail grows inside the floor: no render now, one scheduled for the floor's end
    local renders = w.renders
    queued = {}
    w:setText(w.text .. "tail")
    TestRunner:assertEqual(w.renders, renders, "no render inside the floor")
    TestRunner:assertEqual(#queued, 1, "a catch-up render scheduled")
    TestRunner:assertTrue(queued[1].sec > 0 and queued[1].sec <= w.floor, "for the floor's end")
    w:setText(w.text .. " more")
    TestRunner:assertEqual(#queued, 1, "one catch-up at a time")
    clock = clock + 10
    queued[1].fn()
    TestRunner:assertEqual(w.renders, renders + 1, "the catch-up rendered what arrived")
    TestRunner:assertEqual(w.rendered, w.text, "all of it")
    TestRunner:assertEqual(#queued, 1, "the fired task is left to the mock; nothing new scheduled")
    -- following resumed: the last page through the widget's own scroll
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
    TestRunner:assertEqual(w.floor, SM.COST_FACTOR * 2, "the floor from the conversion's and the layout's cost (a second each)")
    -- the page is rastered at the first paint after a render: that second counts too
    w:paintTo(nil, 0, 0)
    TestRunner:assertEqual(w.floor, SM.COST_FACTOR * 3, "and from the paint's")
    w:paintTo(nil, 0, 0)
    TestRunner:assertEqual(w.floor, SM.COST_FACTOR * 3, "a later paint of the same render adds nothing")
    SM._now = real_now
end)

TestRunner:test("the floor: the reader's shortest interval at least, a rest as long as the drawing took (half of the time at most)", function()
    TestRunner:assertEqual(SM.FLOOR, 0.1)
    TestRunner:assertEqual(SM.COST_FACTOR, 1)
    local long = string.rep("a line of the answer\n", 40)
    local st = { rendered = long, rendered_at = 10, floor = math.max(SM.FLOOR, 0.035 * SM.COST_FACTOR) }
    TestRunner:assertTrue(not SM.renderDue(st, long .. "x", 10.05), "a twentieth of a second after: not yet")
    TestRunner:assertTrue(SM.renderDue(st, long .. "x", 10.11), "a tenth of a second after a 35 ms drawing: due")
    st.floor = math.max(SM.FLOOR, 0.15 * SM.COST_FACTOR)
    TestRunner:assertTrue(SM.renderDue(st, long .. "x", 10.31),
        "a 150 ms drawing: due at the handler's next tick (a quarter of a second after the last), as the plain view is")
    st.floor = math.max(SM.FLOOR, 0.5 * SM.COST_FACTOR)
    TestRunner:assertTrue(not SM.renderDue(st, long .. "x", 10.4), "a half-second drawing: half a second of rest after it")
    TestRunner:assertTrue(SM.renderDue(st, long .. "x", 10.51))
end)

TestRunner:test("a text that shows nothing new is not drawn again", function()
    built = {}
    local w = widget()
    clock = clock + 10
    local head = string.rep("A line of the answer.\n", 30) .. "\n| Device | Screen |\n|---|---|\n"
    w:setText(head)
    local renders, widgets = w.renders, #built
    clock = clock + 10
    w:setText(head .. "| Kobo Cl")
    TestRunner:assertEqual(w.renders, renders, "a row still arriving: the same page, no drawing")
    TestRunner:assertEqual(#built, widgets, "no new widget (the handler's hooks stay on the one there is)")
    TestRunner:assertEqual(w.rendered, head .. "| Kobo Cl", "the text counts as shown")
    TestRunner:assertEqual(w.same, 1)
    clock = clock + 10
    w:setText(head .. "| Kobo Clara | 6 inch |\n")
    TestRunner:assertEqual(w.renders, renders + 1, "the whole row is drawn")
    TestRunner:assertEqual(#built, widgets + 1)
end)

TestRunner:test("a drawing is sent to the screen as the plain view's updates reach it: no quick refresh", function()
    TestRunner:assertEqual(SM.REFRESH, "ui", "the type KOReader uses for a text box being typed into")
    last_refresh = nil
    local w = widget()
    TestRunner:assertEqual(last_refresh, "ui", "the first drawing")
    clock = clock + 10
    last_refresh = nil
    w:setText(string.rep("A line of the answer.\n", 40))
    TestRunner:assertEqual(last_refresh, "ui", "every drawing (the quick type draws black and white only on e-ink)")
    w:onCloseWidget()
    TestRunner:assertEqual(last_refresh, "flashui", "and one clean refresh at close")
end)

TestRunner:test("the stream's own numbers: every drawing's work, closed by the paint that shows it", function()
    local st = SM.Stats.new()
    TestRunner:assertEqual(st:line(), "no update of a long text (0 bytes at the most)")
    st:work("layout", 0.5, 100)     -- a short text (the waiting animation): left out
    st:painted(1, 0.1)
    TestRunner:assertEqual(st.n, 0)
    st:work("conversion", 0.010, 1000)
    st:work("layout", 0.030, 1000)
    st:painted(10, 0.020)
    st:work("layout", 0.050, 1000)  -- the plain view lays its text out twice a tick
    st:work("layout", 0.050, 1000)
    st:painted(10.5, 0.020)
    st:painted(11, 0.5)             -- a paint with no new drawing is no update
    TestRunner:assertEqual(st.n, 2)
    TestRunner:assertEqual(st:line(), "2 updates in 0.5 s (2.0 a second); an update took 90 ms on average "
        .. "(conversion 5, layout 65, paint 20), 120 ms at most; the longest wait between two 0.50 s; 1000 bytes at the most")
end)

TestRunner:test("healTail: the last line's open bold or code mark is closed for the render, nothing else", function()
    local heal = SM.healTail
    TestRunner:assertEqual(heal("A title\n\n**The Last Bak"), "A title\n\n**The Last Bak**", "an open bold pair")
    TestRunner:assertEqual(heal("He said **yes** and **no"), "He said **yes** and **no**", "the second pair open")
    TestRunner:assertEqual(heal("Run `luac -p fi"), "Run `luac -p fi`", "an open code tick")
    TestRunner:assertEqual(heal("Run `a ** b"), "Run `a ** b`", "inside code the stars are not markup")
    TestRunner:assertEqual(heal("All **closed** here"), "All **closed** here")
    TestRunner:assertEqual(heal("Then **"), "Then **", "a pair that only just opened")
    TestRunner:assertEqual(heal("**open on the line before\nplain last line"), "**open on the line before\nplain last line",
        "only the last line")
    TestRunner:assertEqual(heal("text\n```lua\nlocal a = b ** c"), "text\n```lua\nlocal a = b ** c", "inside an open fence")
    TestRunner:assertEqual(heal("text\n```"), "text\n```", "a fence line itself")
    TestRunner:assertEqual(heal("- one\n- two\n-"), "- one\n- two\n", "a list item's dash alone waits for its first word")
    TestRunner:assertEqual(heal("1. one\n2."), "1. one\n", "a number alone")
    TestRunner:assertEqual(heal("text\n\n##"), "text\n\n", "a heading's hashes alone")
    TestRunner:assertEqual(heal("text\n\n> "), "text\n\n", "a quote's bracket alone")
    TestRunner:assertEqual(heal("- one\n- t"), "- one\n- t", "an item with its first letter is shown")
    TestRunner:assertEqual(heal("ends with a newline\n"), "ends with a newline\n")
    TestRunner:assertEqual(heal(""), "")
    TestRunner:assertEqual(heal(nil), nil)
end)

TestRunner:test("healTail: a table's row waits until it is whole, its header until the line under it", function()
    local heal = SM.healTail
    local lead = "Here it is:\n\n"
    TestRunner:assertEqual(heal(lead .. "| Device | Scr"), lead, "a header still arriving is held back")
    TestRunner:assertEqual(heal(lead .. "| Device | Screen |\n"), lead, "a whole header waits for the line under it")
    TestRunner:assertEqual(heal(lead .. "| Device | Screen |\n|---"), lead, "which is still arriving")
    local head = lead .. "| Device | Screen |\n|---|---|"
    TestRunner:assertEqual(heal(head), head, "the line under it makes the two a table: shown")
    TestRunner:assertEqual(heal(head .. "\n"), head .. "\n")
    TestRunner:assertEqual(heal(head .. "\n| Kobo Cl"), head .. "\n", "a row still arriving waits")
    TestRunner:assertEqual(heal(head .. "\n| Kobo Clara | 6 inch |"), head .. "\n", "until its line ends")
    TestRunner:assertEqual(heal(head .. "\n| Kobo Clara | 6 inch |\n"), head .. "\n| Kobo Clara | 6 inch |\n", "then it is shown")
    TestRunner:assertEqual(heal(head .. "\n| Kobo Clara | 6 inch |\n| Kin"), head .. "\n| Kobo Clara | 6 inch |\n",
        "and the next one waits")
    TestRunner:assertEqual(heal(head .. "\n| a | b |\n\nAfter the ta"), head .. "\n| a | b |\n\nAfter the ta",
        "text after the table is text")
    TestRunner:assertEqual(heal("A paragraph.\n| Device | Scr"), "A paragraph.\n", "a table right under a paragraph")
    TestRunner:assertEqual(heal("- a point\n  | Device | Scr"), "- a point\n", "an indented one")
    -- what is no table shows as it arrives
    TestRunner:assertEqual(heal("|x| is the absolute value of x.\n"), "|x| is the absolute value of x.\n",
        "a line of prose that ends without a pipe")
    local long = "| " .. string.rep("a long line of prose ", 10)
    TestRunner:assertEqual(heal(long), long, "a line longer than a header is")
    TestRunner:assertEqual(heal("| a | b |\n| c | d"), "| a | b |\n| c | d", "two lines of pipes with no line under the first")
    TestRunner:assertEqual(heal("```\n| a | b"), "```\n| a | b", "nothing inside an open code fence")
end)

TestRunner:test("healTail: a link shows its words while its address arrives", function()
    local heal = SM.healTail
    TestRunner:assertEqual(heal("See [the guide](https://exam"), "See [the guide](https://exam)", "the parenthesis closed")
    TestRunner:assertEqual(heal("See [the guide]("), "See [the guide]()", "from its first character")
    TestRunner:assertEqual(heal("**See [the guide](https://exam"), "**See [the guide](https://exam)**", "inside an open bold pair")
    TestRunner:assertEqual(heal("See [the guide](https://example.org/a) and more"), "See [the guide](https://example.org/a) and more",
        "a closed link is left")
    TestRunner:assertEqual(heal("See [the gui"), "See [the gui", "a bracket still open is left")
    TestRunner:assertEqual(heal("Call `f[0](x` then g[1](y z"), "Call `f[0](x` then g[1](y z",
        "not in a code span, not with a space after it")
    TestRunner:assertEqual(heal("A [link](https://en.example.org/wiki/Name_(disambig"), "A [link](https://en.example.org/wiki/Name_(disambig",
        "nor an address with a parenthesis of its own")
end)

-- The math pass as the pipeline applies it (the real module: it is pure)
local MathRender = require("koassistant.ui.math")
local function mathPass(piece)
    if not MathRender.hasMath(piece) then return piece end
    return MathRender.render(piece)
end

TestRunner:test("safeCut: an answer is cut after a blank line, where the Markdown library is back at its top level", function()
    local function cut(text, from, no_math)
        return SM.safeCut(text, from, { math = not no_math and mathPass or nil })
    end
    local function lineAt(text, offset) return offset and text:sub(offset):match("^[^\n]*") end
    TestRunner:assertEqual(cut("One paragraph.\nIts second line.\n"), nil, "no blank line, no cut")
    local t = "One paragraph.\n\nThe next one, still arriv"
    TestRunner:assertEqual(lineAt(t, cut(t)), "The next one, still arriv", "before a line still arriving, after a line at the margin")
    t = "One.\n\nTwo.\n\nThree.\n"
    TestRunner:assertEqual(lineAt(t, cut(t)), "Three.", "the last cut of several")
    TestRunner:assertEqual(lineAt(t, cut(t, t:find("Two", 1, true))), "Three.", "from an earlier cut on")
    TestRunner:assertEqual(cut(t, t:find("Three", 1, true)), nil, "nothing after the last one")
    -- a code fence
    t = "Before.\n\n```\ncode\n\nmore code\n"
    TestRunner:assertEqual(lineAt(t, cut(t)), "```", "before the fence, never inside it")
    t = t .. "```\n\nAfter the fence.\n"
    TestRunner:assertEqual(lineAt(t, cut(t)), "After the fence.", "once it is closed")
    -- a list's indented content runs across blank lines
    t = "1. First\n   - sub\n\n2. Second\n"
    TestRunner:assertEqual(lineAt(t, cut(t)), "2. Second",
        "an item after indented content is a cut: the piece starts a list the finished pieces join to the one before (B691)")
    t = "1. First\n   - sub\n\nAfter the list.\n"
    TestRunner:assertEqual(lineAt(t, cut(t)), "After the list.", "a line at the margin that is no item ends it")
    TestRunner:assertEqual(cut("1. First\n   - sub\n\nAfter the li"), nil, "but not while that line is still arriving")
    TestRunner:assertEqual(cut("1. First\n   - sub\n\n  indented again\n"), nil, "nor before an indented line")
    TestRunner:assertEqual(cut("1. First\n   - sub\n\n> a quote\n"), nil, "nor before a quote (the library counts its bracket as indentation)")
    t = "- one\n\n- two\n"
    TestRunner:assertEqual(lineAt(t, cut(t)), "- two", "after an item at the margin the library has closed the list")
    -- marks the passes before the library pair across lines
    TestRunner:assertEqual(cut("A stray ` tick.\n\nNext.\n"), nil, "an open code span (the math pass pairs it)")
    t = "A stray ` tick.\n\nNext.\n"
    TestRunner:assertEqual(lineAt(t, cut(t, nil, true)), "Next.", "which matters only while math is rendered")
    TestRunner:assertEqual(cut("A display $$ opens\n\nand goes on\n"), nil, "an open display")
    TestRunner:assertEqual(cut("\\(a +\n\nb\\) closes\n"), nil, "an open \\( span")
    t = "\\(a +\n\nb\\) closes.\n\nNext.\n"
    TestRunner:assertEqual(lineAt(t, cut(t)), "Next.", "closed again")
    TestRunner:assertEqual(cut("An open [bracket\n\nand its ](https://example.org) end.\n"), nil, "an open bracket")
    TestRunner:assertEqual(cut("A [link](https://example.org/a\n\nb) goes on.\n"), nil, "a link's open parentheses")
    TestRunner:assertEqual(cut("```\necho $$\n```\n\nBetween.\n", nil, true), nil, "an odd $$, in code too")
    -- the math pass takes "\[" and "\]" out: the brackets left are what the link pass sees
    TestRunner:assertEqual(cut("Code `\\[` and a display \\[ y \\] after.\n\nand then ](https://example.org) later.\n"), nil,
        "a bracket the math pass uncovers")
    -- a verdict on a line is final, and remembered
    local rejected = {}
    t = "A stray ` tick.\n\nNext.\n\nAnd more.\n"
    TestRunner:assertEqual(SM.safeCut(t, 1, { math = mathPass, rejected = rejected }), nil)
    TestRunner:assertTrue(rejected[t:find("Next", 1, true)] and rejected[t:find("And more", 1, true)], "both lines remembered as open")
    local asked = 0
    SM.safeCut(t, 1, { math = function(piece) asked = asked + 1; return piece end, rejected = rejected })
    TestRunner:assertEqual(asked, 0, "and not read again")
end)

TestRunner:test("convert: the finished part is converted once, the tail again each time", function()
    rendered_texts, whole_texts = {}, {}
    local kept = { text = "", html = "" }
    local opts = { features = {}, text_align = "auto" }
    TestRunner:assertEqual(SM.convert(kept, "One.\n\nTwo", opts), "<p>One.\n\n</p><p>Two</p>", "the piece, then the tail")
    TestRunner:assertEqual(kept.text, "One.\n\n", "the part before the cut is kept")
    rendered_texts = {}
    TestRunner:assertEqual(SM.convert(kept, "One.\n\nTwo more.\n\nThree **bo", opts),
        "<p>One.\n\n</p><p>Two more.\n\n</p><p>Three **bo**</p>", "the joined blocks, the tail's open bold closed")
    TestRunner:assertEqual(#rendered_texts, 2, "two conversions")
    TestRunner:assertEqual(rendered_texts[1], "Two more.\n\n", "the new piece")
    TestRunner:assertEqual(rendered_texts[2], "Three **bo**", "and the tail: the first piece is not converted again")
    TestRunner:assertEqual(kept.text, "One.\n\nTwo more.\n\n")
    -- another text than the kept one (the reasoning shown before the answer): start over
    TestRunner:assertEqual(SM.convert(kept, "The answer.\n\nIts second paragraph", opts),
        "<p>The answer.\n\n</p><p>Its second paragraph</p>")
    TestRunner:assertEqual(kept.text, "The answer.\n\n", "the kept part is the new text's")
    -- a piece the library fails on alone: the whole conversion from there on
    failing_piece = "breaks"
    local html = SM.convert(kept, "The answer.\n\nA piece that breaks.\n\nAfter", opts)
    failing_piece = nil
    TestRunner:assertTrue(kept.off == true, "the pieces are given up")
    TestRunner:assertEqual(html, "<pre>The answer.\n\nA piece that breaks.\n\nAfter</pre>", "the whole text converted")
    whole_texts = {}
    SM.convert(kept, "The answer.\n\nA piece that breaks.\n\nAfter more", opts)
    TestRunner:assertEqual(#whole_texts, 1, "and on every later call")
    -- a tail the library fails on is converted whole that time only
    kept = { text = "", html = "" }
    failing_piece = "tail"
    whole_texts = {}
    SM.convert(kept, "Fine.\n\nA failing tail", opts)
    failing_piece = nil
    TestRunner:assertTrue(#whole_texts == 1 and not kept.off, "the tail alone failed: the kept part stays")
    TestRunner:assertEqual(kept.text, "Fine.\n\n")
end)

TestRunner:test("the pieces give the whole conversion's HTML through the real pipeline (where the app is installed)", function()
    local md_path = "/Applications/KOReader.app/Contents/koreader/frontend/apps/filemanager/lib/md.lua"
    local probe = io.open(md_path, "r")
    if not probe then
        print("    (skipped: KOReader's Markdown library is not at " .. md_path .. ")")
        return
    end
    probe:close()
    -- the real library and the real viewer, in place of this file's stand-ins
    local keys = { "apps/filemanager/lib/md", "koassistant.ui.chatgptviewer", "koassistant.request.stream_markdown", "ffi/util" }
    local before = {}
    for _idx, k in ipairs(keys) do before[k] = package.loaded[k] end
    local util = package.loaded["ffi/util"] or {}
    local ordered = util.orderedPairs
    util.orderedPairs = util.orderedPairs or function(t)
        local names = {}
        for k in pairs(t) do names[#names + 1] = k end
        table.sort(names)
        local i = 0
        return function() i = i + 1; if names[i] ~= nil then return names[i], t[names[i]] end end
    end
    package.loaded["ffi/util"] = util
    package.loaded["apps/filemanager/lib/md"] = dofile(md_path)
    package.loaded["koassistant.ui.chatgptviewer"] = nil
    package.loaded["koassistant.request.stream_markdown"] = nil
    local ok, err = pcall(function()
        local Viewer = require("koassistant.ui.chatgptviewer")
        local Pieces = require("koassistant.request.stream_markdown")
        local quiet = require("koassistant.core.logger")
        local warn = quiet.warn
        quiet.warn = function() end
        local samples = dofile(PLUGIN_DIR .. "/tests/lib/markdown_samples.lua")
        local opts = { features = {}, text_align = "auto" }
        local steps, bad, first, kept_bytes = 0, 0, nil, 0
        for _idx, sample in ipairs(samples) do
            local text = sample.text
            local kept = { text = "", html = "" }
            local at = 0
            while at < #text do
                -- every line's end and its first bytes (where a cut is decided), and a point inside it
                local nl = text:find("\n", at + 1, true) or #text
                at = (at + 4 < nl - 1) and math.min(nl - 1, at + 23) or at + 1
                while at < #text and text:byte(at + 1) >= 128 and text:byte(at + 1) < 192 do at = at + 1 end
                local prefix = text:sub(1, at)
                local a = Pieces.convert(kept, prefix, opts)
                local b = Viewer.markdownHtml(Pieces.healTail(prefix), opts)
                steps = steps + 1
                if a ~= b then
                    bad = bad + 1
                    first = first or (sample.name .. ", byte " .. at)
                end
            end
            kept_bytes = kept_bytes + #kept.text
        end
        quiet.warn = warn
        TestRunner:assertEqual(bad, 0, "steps that differ of " .. steps .. (first and (" (first: " .. first .. ")") or ""))
        TestRunner:assertTrue(kept_bytes > 1000, "and pieces were kept (" .. kept_bytes .. " bytes)")
        -- a code block under a list item, its closing fence not here yet: closed
        -- at its own depth, so the answer stays rendered while the block streams
        for _idx, open in ipairs({ "Steps:\n\n1. Run:\n   ```\n   code line\n", "- first:\n  ```lua\n  local a = 1\n\n  more" }) do
            local html = Viewer.markdownHtml(Pieces.healTail(open), opts)
            TestRunner:assertTrue(html:find("<pre><code", 1, true) ~= nil and not html:find("^<pre>"),
                "an open fence under a list item renders as code: " .. html)
        end
        local margin = Viewer.markdownHtml("Text.\n\n```\ncode", opts)
        TestRunner:assertTrue(margin:find("<p>Text.</p>", 1, true) ~= nil and margin:find("<pre><code>code", 1, true) ~= nil,
            "an open fence at the margin as before")
    end)
    util.orderedPairs = ordered
    for _idx, k in ipairs(keys) do package.loaded[k] = before[k] end
    if not ok then error(err, 0) end
end)

TestRunner:test("the position capture: the page's first words and the anchor's ordinal across the pages before", function()
    local pages = {
        { { { word = "The" }, { word = "quick" }, { word = "brown" } }, { { word = "fox" } } },
        { { { word = "Once" }, { word = "again" }, { word = "here" }, { word = "The" }, { word = "quick" }, { word = "brown" } } },
        { { { word = "The" }, { word = "quick" }, { word = "brown" }, { word = "dog" } } },
        { { { word = "これは" }, { word = "日" }, { word = "本" }, { word = "語" }, { word = "の長" }, { word = "い段" }, { word = "落" }, { word = "and" }, { word = "then" } } },
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
    box.page_count = 4
    box.page_number = 4
    snippet = w:capturePosition()
    TestRunner:assertEqual(snippet, "これは日本語の長い段落 and then", "spaceless-script segments join without spaces, a space before Latin")
    FakeScroll.doc = nil
end)

TestRunner:test("the hand-off: the captured words land through the viewer's own split and ordinal", function()
    -- the snippet the capture builds (the page's words joined by spaces) is what
    -- the viewer's landing reads: the anchor it extracts splits the holding
    -- paragraph at those words, at the counted occurrence
    -- a lead of over forty characters: a spot within the reply's first words is
    -- the reply start to the viewer (the marker break already tops it)
    local para = "Long before the story begins there is a quiet morning in the valley and then the fox jumps over the lazy dog and keeps running far away from the farm"
    local html = "<p>a question</p><p>◉ KOAssistant:</p><p>" .. para .. ". Again: " .. para .. ".</p>"
    local snippet = "jumps over the lazy dog and keeps running far away from the farm"
    local anchor = RealViewer.extractCarryAnchor(snippet)
    TestRunner:assertEqual(anchor, "jumps over the lazy dog and", "six words of the page's first line")
    local cfg = { features = { chat_exchange_page_breaks = true } }
    local out = RealViewer._applyExchangePageBreaks(html, cfg, anchor, 2)
    local div = '<div class="koa-exchange-break"></div>'
    local first = out:find(anchor, 1, true)
    local second = out:find(anchor, first + 1, true)
    local split = out:find(div .. "<p>" .. anchor, 1, true)
    TestRunner:assertTrue(split ~= nil, "the paragraph is split at the anchor")
    TestRunner:assertTrue(split + #div + 3 == second, "at the second occurrence, the one the capture counted")
    out = RealViewer._applyExchangePageBreaks(html, cfg, anchor, 1)
    TestRunner:assertTrue(out:find(div .. "<p>" .. anchor, 1, true) + #div + 3 == out:find(anchor, 1, true), "the first occurrence with ordinal 1")
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
    TestRunner:assertTrue(gq:find('stream_markdown = require("koassistant.request.stream_markdown").applies(config.features),', 1, true) ~= nil,
        "the stream settings ask the one rule")
    TestRunner:assertTrue(not gq:find("_chat_view_mode", 1, true), "and spell no part of it themselves")
end)

TestRunner:test("which answers stream as Markdown: on by default, prose only, a window that shows Markdown", function()
    local applies = SM.applies
    TestRunner:assertTrue(applies({}), "nothing set: on (the default), the View Mode is Markdown")
    TestRunner:assertTrue(applies({ stream_markdown = true }))
    TestRunner:assertTrue(not applies({ stream_markdown = false }), "the reader turned it off")
    TestRunner:assertTrue(not applies(nil), "no features")
    -- the window the answer lands in
    TestRunner:assertTrue(not applies({ render_markdown = false }), "Plain Text is the View Mode")
    TestRunner:assertTrue(applies({ render_markdown = false, _chat_view_mode = true }), "this chat was switched to Markdown")
    TestRunner:assertTrue(not applies({ _chat_view_mode = false }), "this chat was switched to Plain Text")
    -- a dictionary window with Text Mode for Dictionary shows Plain Text whatever else says
    TestRunner:assertTrue(applies({ compact_view = true }), "a dictionary popup shows Markdown by default")
    TestRunner:assertTrue(not applies({ compact_view = true, dictionary_text_mode = true }), "Text Mode for Dictionary, the popup")
    TestRunner:assertTrue(not applies({ dictionary_view = true, dictionary_text_mode = true, _chat_view_mode = true }),
        "and the full-size dictionary window, whatever the chat's own mode")
    TestRunner:assertTrue(applies({ dictionary_text_mode = true }), "the setting alone does not touch a chat")
    -- an answer that is data
    TestRunner:assertTrue(not applies({ plain_streaming = true }), "an X-Ray build's JSON streams as the text it is")
    -- the same rule the window itself applies, its caller's marks included
    TestRunner:assertTrue(RealViewer.dictionaryPlainText({ dictionary_text_mode = true }, { compact_view = true }),
        "a window marked by its caller")
    TestRunner:assertTrue(not RealViewer.dictionaryPlainText({ dictionary_text_mode = true }, {}), "a chat window")
    TestRunner:assertTrue(not RealViewer.dictionaryPlainText({ compact_view = true }, { compact_view = true }), "the setting off")
end)

TestRunner:test("the default and the marks the rule reads, at their sources", function()
    local function read(rel)
        local f = assert(io.open(PLUGIN_DIR .. "/" .. rel, "r"))
        local src = f:read("*a")
        f:close()
        return src
    end
    local row = read("koassistant/ui/settings_schema.lua"):match('id = "stream_markdown",(.-)help_text')
    TestRunner:assertTrue(row and row:find('path = "features.stream_markdown"', 1, true) ~= nil
        and row:find("default = true", 1, true) ~= nil, "the schema's default is on, as the rule reads a missing value")
    local dialogs = read("koassistant/ui/dialogs.lua")
    TestRunner:assertTrue(dialogs:find("if prompt.cache_as_xray then\n        temp_config.features = temp_config.features or {}\n"
        .. "        temp_config.features.plain_streaming = true", 1, true) ~= nil, "an X-Ray build marks its answer as data")
    local viewer = read("koassistant/ui/chatgptviewer.lua")
    TestRunner:assertTrue(viewer:find("if ChatGPTViewer.dictionaryPlainText(self.configuration.features, self) then\n"
        .. "        self.render_markdown = false", 1, true) ~= nil, "the window asks the rule the stream asks")
    local handler = read("koassistant/request/stream_handler.lua")
    TestRunner:assertTrue(handler:find("settings.stream_markdown == true and not hidden_streaming", 1, true) ~= nil,
        "and a hidden stream never shows it")
end)

TestRunner:test("the plain stream widget's own request is the released one", function()
    -- it asks for "fast"; what reaches the screen is mostly "ui", joined with
    -- the dialog's own refresh (the module's comment has the numbers). A
    -- change here changes how every plain stream looks on e-ink.
    local f = assert(io.open(PLUGIN_DIR .. "/koassistant/request/stream_handler.lua", "r"))
    local src = f:read("*a")
    f:close()
    local plain = src:match("function StreamText:initTextBox%(text, char_added%)(.-)\nend\n")
    TestRunner:assertTrue(plain and plain:find('UIManager:setDirty(self.parent, function() return "fast", self.dimen end)', 1, true) ~= nil,
        "the text area, the quick type")
    TestRunner:assertTrue(src:find('UIManager:setDirty(self.parent, function() return "flashui", self.dimen end)', 1, true) ~= nil,
        "and a clean refresh at close")
end)

for k, v in pairs(SAVED) do package.loaded[k] = v end
package.loaded["koassistant.request.stream_markdown"] = nil
package.loaded["ui/widget/container/framecontainer"].getSize = nil

print(string.format("\nResults: %d passed, %d failed", TestRunner.passed, TestRunner.failed))
return TestRunner.failed == 0
