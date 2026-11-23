-- The minimal popup (B695; the maintainer, 2026-11-17: "minimal popup can go
-- to edges? or close to edges. perhaps make scrollable if no room?"). The
-- popup shows an answer the way the window a tap opens would, in a box as
-- wide as the chat window or in a panel at the foot of the screen; an answer
-- taller than its cap scrolls, or goes to the full window in "When it fits".
-- Here: where the text sits (pure), which answers are shown (the flow on
-- stand-ins for KOReader's widgets), and the wiring between the files. The
-- real widgets are tests/scenarios/s15_minimal_popup.lua.
--
-- Run: lua tests/unit/test_minimal_popup.lua  (or lua tests/run_tests.lua --unit)

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

-- the panel's two widgets, which the shared mock has no stub for
local stubbed = {}
for _i, name in ipairs({ "ui/widget/container/bottomcontainer", "ui/widget/linewidget",
        "ui/widget/textwidget", "ui/widget/overlapgroup", "ui/event" }) do
    if not package.loaded[name] then
        local C = {}
        function C:new(o) return setmetatable(o or {}, { __index = self }) end
        package.loaded[name] = C
        stubbed[#stubbed + 1] = name
    end
end

local MinimalPopup = require("koassistant.ui.minimal_popup")
local Viewer = require("koassistant.ui.chatgptviewer")
local UIManager = require("ui/uimanager")

-- The suite runs every file in one process and several files swap the device
-- mock, so each module holds whichever screen was loaded when IT was: the
-- tables completed here are the ones the two modules under test captured,
-- found among their upvalues. Everything added is taken away at the end.
local function captured(fn, name)
    for i = 1, 80 do
        local n, v = debug.getupvalue(fn, i)
        if not n then return nil end
        if n == name then return v end
    end
end
local added = {}
local function add(tbl, key, value)
    if tbl[key] == nil then
        tbl[key] = value
        added[#added + 1] = { tbl, key }
    end
end
local Device = assert(captured(MinimalPopup.init, "Device"), "the popup's device")
local Screen = assert(captured(MinimalPopup.init, "Screen"), "the popup's screen")
local Size = assert(captured(MinimalPopup.init, "Size"), "the popup's sizes")
add(Device, "isTouchDevice", function() return false end)
add(Device, "hasKeys", function() return false end)
add(Screen, "getWidth", function() return 800 end)
add(Screen, "getHeight", function() return 600 end)
add(Screen, "scaleBySize", function(_self, n) return n end)
add(Size, "radius", { window = 0 })
add(Size, "border", { window = 1 })
add(Size, "line", { thick = 1 })
add(Size, "padding", { small = 0 })
add(Size.padding, "small", 0)
add(UIManager, "setDirty", function() end)
-- a frame measures itself: the one every case below is painted as (`painted`)
add(assert(captured(MinimalPopup.init, "FrameContainer"), "the popup's frame class"), "getSize", function()
    return { w = 600, h = 200 }
end)
add(assert(captured(MinimalPopup.init, "Geom")), "copy", function(self)
    return setmetatable({ x = self.x, y = self.y, w = self.w, h = self.h }, getmetatable(self))
end)
-- the chat window's side: its fit scales a font size, its inset is two sizes
add(assert(captured(Viewer._fitContent, "Screen"), "the chat window's screen"), "scaleBySize", function(_self, n) return n end)
add(Viewer, "text_padding", 0)
add(Viewer, "text_margin", 0)

print("")
print(string.rep("=", 50))
print("  Unit Tests: the minimal popup")
print(string.rep("=", 50))

local function read(path)
    local f = assert(io.open(PLUGIN_DIR .. "/" .. path, "r"))
    local s = f:read("*a")
    f:close()
    return s
end

TestRunner:test("where the text sits: the box is the chat window's rectangle, the panel the screen's width", function()
    -- a 1072x1448 screen: the chat window 1018 wide, its text inset 22, a border of 2
    local box = MinimalPopup.geometry("box", 1072, 1448, 1018, 22, 2)
    TestRunner:assertEqual(box.text_w, 1018 - 44, "the chat window's text width: the same lines in the popup and the window")
    TestRunner:assertEqual(box.border, 2)
    TestRunner:assertEqual(box.panel, false)
    TestRunner:assertEqual(box.cap, math.floor(1448 * 0.45), "the text's height cap")
    local panel = MinimalPopup.geometry("panel", 1072, 1448, 1018, 22, 2)
    TestRunner:assertEqual(panel.text_w, 1072 - 44, "edge to edge, the same inset")
    TestRunner:assertEqual(panel.border, 0, "no frame, a rule above it")
    TestRunner:assertEqual(panel.panel, true)
    TestRunner:assertEqual(panel.cap, box.cap, "one cap for both shapes")
    TestRunner:assertEqual(MinimalPopup.geometry(nil, 1072, 1448, 1018, 22, 2).panel, false, "the box when no shape is named")
    TestRunner:assertEqual(MinimalPopup.geometry("sideways", 1072, 1448, 1018, 22, 2).panel, false, "and for a shape that is not one")
end)

-- ── The flow, on stand-ins ──────────────────────────────────────────────────
-- A content widget the way the chat window's builder returns one: an HTML
-- view that needs `needs` pixels (one page when the area is tall enough), or
-- a plain widget of `lines` lines
local built = {}
local function htmlWidget(needs)
    return function(width, height)
        local w = { width = width, height = height, freed = false }
        w.htmlbox_widget = { page_count = needs <= height and 1 or math.ceil(needs / height), free = function() w.freed = true end }
        function w.getSinglePageHeight() return needs <= height and needs or nil end
        built[#built + 1] = w
        return w
    end
end
local function plainWidget(lines, line_h)
    return function(width, height)
        local w = { width = width, height = height, freed = false }
        w.text_widget = { getAllLineCount = function() return lines end, free = function() w.freed = true end }
        function w.getLineHeight() return line_h end
        built[#built + 1] = w
        return w
    end
end
local function history(text)
    return { getMessages = function()
        return { { role = "user", content = "q" }, { role = "assistant", content = text } }
    end }
end

-- KOReader's Widget:new runs init; the mock's class stub does not
local real_new, real_show = MinimalPopup.new, UIManager.show
local shown
local function withWidgets(fn)
    MinimalPopup.new = function(self, o)
        local p = real_new(self, o)
        p.key_events = p.key_events or {}
        p:init()
        return p
    end
    UIManager.show = function(_self, w) shown = w end
    shown, built = nil, {}
    local ok, err = pcall(fn)
    MinimalPopup.new, UIManager.show = real_new, real_show
    if not ok then error(err, 0) end
end

local CAP = math.floor(Screen:getHeight() * MinimalPopup.CAP)

TestRunner:test("an answer that fits is shown as tall as it is, in the chat window's own drawing", function()
    withWidgets(function()
        local asked = {}
        local viewer = { markdown_font_size = 20, answerWidget = function(_self, text, w, h, dialog)
            asked[#asked + 1] = { text = text, w = w, dialog = dialog }
            return htmlWidget(100)(w, h)
        end }
        local ok = MinimalPopup.showForResponse({ history = history("**An answer.**"), viewer = viewer, only_if_fits = true })
        TestRunner:assertEqual(ok, true)
        TestRunner:assertTrue(shown ~= nil and shown.scroll_w ~= nil, "the popup is shown")
        TestRunner:assertEqual(asked[1].text, "**An answer.**", "the answer as the model wrote it: the window's pipeline draws it")
        TestRunner:assertEqual(asked[1].dialog, shown, "the content widget belongs to the popup (its scrolling redraws the popup)")
        TestRunner:assertEqual(shown:hasOverflow(), false)
        TestRunner:assertTrue(shown.text_h < CAP and shown.text_h >= 100, "as tall as the answer needs (" .. tostring(shown.text_h) .. ")")
        TestRunner:assertEqual(shown.scroll_w.onTapScrollText(), false, "a tap inside is the popup's (it opens the full window), not a scroll step")
        -- the layouts tried on the way are let go
        local kept = 0
        for _i, w in ipairs(built) do if not w.freed then kept = kept + 1 end end
        TestRunner:assertEqual(kept, 1, "one content widget is kept of " .. #built)
    end)
end)

TestRunner:test("When it fits hands an answer taller than the cap back; Always shows it, scrolling", function()
    withWidgets(function()
        local viewer = { markdown_font_size = 20, answerWidget = function(_self, _text, w, h) return htmlWidget(CAP * 3)(w, h) end }
        local ok = MinimalPopup.showForResponse({ history = history("long"), viewer = viewer, only_if_fits = true })
        TestRunner:assertEqual(ok, false, "the caller opens the full window")
        TestRunner:assertEqual(shown, nil, "nothing is shown")
        for _i, w in ipairs(built) do TestRunner:assertEqual(w.freed, true, "what the layout made is released") end
    end)
    withWidgets(function()
        local viewer = { markdown_font_size = 20, answerWidget = function(_self, _text, w, h) return htmlWidget(CAP * 3)(w, h) end }
        local ok = MinimalPopup.showForResponse({ history = history("long"), viewer = viewer })
        TestRunner:assertEqual(ok, true)
        TestRunner:assertTrue(shown ~= nil and shown:hasOverflow(), "shown, and it scrolls")
        TestRunner:assertEqual(shown.text_h, CAP, "at its cap")
    end)
end)

TestRunner:test("the plain-text view fits and overflows by its lines", function()
    withWidgets(function()
        local viewer = { markdown_font_size = 20, answerWidget = function(_self, _text, w, h) return plainWidget(3, 20)(w, h) end }
        TestRunner:assertEqual(MinimalPopup.showForResponse({ history = history("short"), viewer = viewer, only_if_fits = true }), true)
        TestRunner:assertEqual(shown.text_h, 60, "three lines tall")
        TestRunner:assertEqual(shown:hasOverflow(), false)
    end)
    withWidgets(function()
        local viewer = { markdown_font_size = 20, answerWidget = function(_self, _text, w, h) return plainWidget(200, 20)(w, h) end }
        TestRunner:assertEqual(MinimalPopup.showForResponse({ history = history("long"), viewer = viewer, only_if_fits = true }), false)
        TestRunner:assertEqual(MinimalPopup.showForResponse({ history = history("long"), viewer = viewer }), true)
        TestRunner:assertEqual(shown:hasOverflow(), true)
    end)
end)

TestRunner:test("the shape is the caller's: the box unless the panel is asked for", function()
    for _i, case in ipairs({ { nil, true }, { "box", true }, { "panel", false }, { "nonsense", true } }) do
        withWidgets(function()
            local viewer = { answerWidget = function(_self, _text, w, h) return htmlWidget(50)(w, h) end }
            MinimalPopup.showForResponse({ history = history("a"), viewer = viewer, style = case[1] })
            TestRunner:assertEqual(shown.movable ~= nil, case[2], "style " .. tostring(case[1]))
        end)
    end
end)

TestRunner:test("nothing to show: no answer, an empty one", function()
    withWidgets(function()
        local viewer = { answerWidget = function() error("never asked") end }
        TestRunner:assertEqual(MinimalPopup.showForResponse({ history = history(""), viewer = viewer }), false)
        TestRunner:assertEqual(MinimalPopup.showForResponse({ history = history("  \n "), viewer = viewer }), false)
        TestRunner:assertEqual(MinimalPopup.showForResponse({ viewer = viewer }), false)
        TestRunner:assertEqual(shown, nil)
    end)
end)

TestRunner:test("a caller with no chat window gets plain text: the text-mode steps, then the trim", function()
    withWidgets(function()
        local ScrollText = require("ui/widget/scrolltextwidget")
        local real = ScrollText.new
        local given
        ScrollText.new = function(_self, o)
            given = o
            return plainWidget(2, 20)(o.width, o.height)
        end
        local ok, err = pcall(function()
            TestRunner:assertEqual(MinimalPopup.showForResponse({ history = history("**Bold** answer.\n\n"), features = {} }), true)
            TestRunner:assertTrue(given.text:find("%*%*") == nil, "the Markdown marks are stripped")
            TestRunner:assertTrue(given.text:find("%s$") == nil, "and the trailing line break is gone")
            TestRunner:assertEqual(given.dialog, shown)
        end)
        ScrollText.new = real
        if not ok then error(err, 0) end
    end)
end)

-- ── The wiring ──────────────────────────────────────────────────────────────
TestRunner:test("the response dialog hands the popup its chat window and the reader's shape", function()
    local src = read("koassistant/ui/dialogs.lua")
    local a = assert(src:find('require("koassistant.ui.minimal_popup").showForResponse({', 1, true))
    local call = src:sub(a, src:find("\n        })\n", a, true))
    TestRunner:assertTrue(call:find("viewer = chatgpt_viewer,", 1, true) ~= nil, "the window a tap opens")
    TestRunner:assertTrue(call:find("style = mp_f.minimal_popup_style,", 1, true) ~= nil, "the shape setting")
    TestRunner:assertTrue(call:find('only_if_fits = (mp_f.minimal_popup_mode or "short") == "short",', 1, true) ~= nil,
        "When it fits is the mode's default")
    local schema = read("koassistant/ui/settings_schema.lua")
    local row = schema:match('id = "minimal_popup_style",(.-)help_text')
    TestRunner:assertTrue(row ~= nil and row:find('default = "box"', 1, true) ~= nil, "the box is the default shape")
    for style in pairs(MinimalPopup.STYLES) do
        TestRunner:assertTrue(row:find('value = "' .. style .. '"', 1, true) ~= nil, "the setting offers " .. style)
    end
    local main = read("main.lua")
    TestRunner:assertTrue(main:find('setStyle("box")', 1, true) ~= nil and main:find('setStyle("panel")', 1, true) ~= nil,
        "and so does the tile's hold menu")
end)

TestRunner:test("the popup builds no HTML of its own; the chat window has one builder per view", function()
    local popup = read("koassistant/ui/minimal_popup.lua")
    TestRunner:assertTrue(popup:find("ScrollHtmlWidget:new", 1, true) == nil and popup:find("HtmlBoxWidget", 1, true) == nil
        and popup:find("TextBoxWidget:new", 1, true) == nil,
        "so every HTML widget still gets the fonts' folder (B694) from the one place that builds them")
    local viewer = read("koassistant/ui/chatgptviewer.lua")
    local _, plain_sites = viewer:gsub("ScrollTextWidget:new", "")
    TestRunner:assertEqual(plain_sites, 1, "the plain-text widget is built in one place")
    local _, plain_uses = viewer:gsub("self:_plainWidget%(", "")
    TestRunner:assertEqual(plain_uses, 5, "init, update, rebuild, the translate toggle, one answer for the popup")
    local answer = viewer:match("function ChatGPTViewer:answerWidget%(text, width, height, dialog%)(.-)\nend\n")
    TestRunner:assertTrue(answer ~= nil and answer:find("self:_markdownHtml(", 1, true) == nil,
        "one answer's drawing leaves the window's own state alone (its landing reads what its own pipeline call recorded)")
    TestRunner:assertTrue(answer:find("return self:_htmlWidget(html_body, width, height, dialog)", 1, true) ~= nil
        and answer:find("width, height, dialog)", 1, true) ~= nil, "both views are handed the window that shows them")
    -- the X-Ray card's popup style is this popup
    local card = read("koassistant/xray/xray_card.lua")
    TestRunner:assertTrue(card:find("MinimalPopup:new{", 1, true) ~= nil, "the X-Ray card's popup style")
end)

TestRunner:test("the chat window's builders work for a window that is not it", function()
    -- fitContent: the viewer's own fit, with the font size given
    local tried = {}
    local w, h = Viewer.fitContent(function(height)
        tried[#tried + 1] = height
        return htmlWidget(120)(300, height)
    end, 10, 400, 400, 20)
    TestRunner:assertEqual(tried[1], 400, "laid out at the cap first")
    TestRunner:assertTrue(h >= 120 and h < 400 and w.height == h, "then at the height the text needs (" .. tostring(h) .. ")")
end)

-- ── No blank the text does not need ─────────────────────────────────────────
-- (the maintainer, 2026-11-17: "why so much padding at top and bottom of
-- them? no need")
TestRunner:test("under a text that fits the frame pads only what the fit left out", function()
    -- an inset of 22: the fit leaves 22 under the ink, the frame adds its least
    TestRunner:assertEqual(MinimalPopup.footPadding(22, 22, 4), 4)
    TestRunner:assertEqual(MinimalPopup.footPadding(22, 30, 4), 4, "never less than the least")
    TestRunner:assertEqual(MinimalPopup.footPadding(22, 10, 4), 12, "what is missing to the inset")
    TestRunner:assertEqual(MinimalPopup.footPadding(22, 0, 4), 22, "nothing left blank (plain text, a text that scrolls): the inset")
    withWidgets(function()
        local viewer = { markdown_font_size = 20, answerWidget = function(_self, _text, w, h) return htmlWidget(100)(w, h) end }
        MinimalPopup.showForResponse({ history = history("fits"), viewer = viewer })
        local blank = shown.text_h - 100
        TestRunner:assertTrue(blank > 0, "the fit leaves the last line its leading (" .. blank .. ")")
        TestRunner:assertEqual(shown.frame.padding_bottom, MinimalPopup.footPadding(shown.frame.padding, blank, Size.padding.small),
            "the frame's foot is the inset less that blank")
    end)
    local viewer_src = read("koassistant/ui/chatgptviewer.lua")
    local answer = viewer_src:match("function ChatGPTViewer:answerWidget%(text, width, height, dialog%)(.-)\nend\n")
    TestRunner:assertTrue(answer:find("flushTop(markdownHtml(", 1, true) ~= nil,
        "one answer's first block has no margin above it: the popup's frame is the blank above the text")
end)

TestRunner:test("the first block loses its top margin, and only that", function()
    local flush = Viewer._flushTop
    TestRunner:assertEqual(flush("<p>One.</p>\n<p>Two.</p>"), '<p style="margin-top:0">One.</p>\n<p>Two.</p>')
    TestRunner:assertEqual(flush('\n<p dir="rtl" style="text-align:right">One.</p>'),
        '\n<p dir="rtl" style="margin-top:0;text-align:right">One.</p>', "a style the direction pass wrote is kept")
    TestRunner:assertEqual(flush("<ul>\n<li>a</li>\n</ul>"), '<ul style="margin-top:0">\n<li>a</li>\n</ul>')
    TestRunner:assertEqual(flush("<hr/>\n<p>a</p>"), '<hr style="margin-top:0"/>\n<p>a</p>', "a tag that closes itself stays closed")
    TestRunner:assertEqual(flush("Plain words, <b>then</b> a tag."), "Plain words, <b>then</b> a tag.", "text before any tag: nothing to take off")
    TestRunner:assertEqual(flush(""), "")
end)

-- A Markdown view of lines 26 px tall (ink ends 8 px above a line's foot): a
-- page holds the whole lines its height has room for
local function pagedHtml(lines, first_page_ink)
    return function(height)
        local width = 300
        local w = { width = width, height = height, freed = false }
        local per_page = math.floor(height / 26)
        local ink = first_page_ink or (26 * math.min(per_page, lines) - 8)
        w.htmlbox_widget = {
            page_count = math.max(1, math.ceil(lines / math.max(1, per_page))),
            free = function() w.freed = true end,
            document = { openPage = function()
                return { getUsedBBox = function() return 0, 0, width, ink end, close = function() end }
            end },
        }
        function w.getSinglePageHeight() return w.htmlbox_widget.page_count == 1 and ink or nil end
        built[#built + 1] = w
        return w
    end
end

TestRunner:test("a text that scrolls gets an area as tall as its first page", function()
    built = {}
    -- 400 px hold 15 lines: their ink ends at 382, the last line's slack is 12
    local w, h = Viewer.fitContent(pagedHtml(60), 10, 400, 400, 20, true)
    TestRunner:assertEqual(h, 394, "the first page's ink and the last line's slack")
    TestRunner:assertEqual(w.height, 394)
    TestRunner:assertTrue(w.htmlbox_widget.page_count > 1, "it still scrolls")
    local kept = 0
    for _i, b in ipairs(built) do if not b.freed then kept = kept + 1 end end
    TestRunner:assertEqual(kept, 1, "the first layout is let go")
    -- the other fitted windows (a button row under their text) keep the ceiling
    local _w2, h2 = Viewer.fitContent(pagedHtml(60), 10, 400, 400, 20)
    TestRunner:assertEqual(h2, 400, "only a window that asks for it")
    -- something that cannot break went to the next page: the room stays
    local _w3, h3 = Viewer.fitContent(pagedHtml(60, 100), 10, 400, 400, 20, true)
    TestRunner:assertEqual(h3, 400, "a first page that ends far above the foot is not hugged")
    -- plain text: its whole lines
    local w4, h4 = Viewer.fitContent(function(height) return plainWidget(200, 26)(300, height) end, 10, 400, 400, 20, true)
    TestRunner:assertEqual(h4, 390, "fifteen whole lines")
    TestRunner:assertEqual(w4.height, 390)
    -- a text that fits is as before
    local _w5, h5 = Viewer.fitContent(pagedHtml(3), 10, 400, 400, 20, true)
    TestRunner:assertEqual(h5, 26 * 3 - 8 + 12)
end)

-- ── A word held in the popup ────────────────────────────────────────────────
TestRunner:test("a word or a passage held in the popup goes to the chat window's own handler", function()
    withWidgets(function()
        local got
        local viewer = {
            markdown_font_size = 20,
            answerWidget = function(_self, _text, w, h) return htmlWidget(50)(w, h) end,
            handleTextSelection = function(_self, ...) got = { n = select("#", ...), ... } end,
        }
        MinimalPopup.showForResponse({ history = history("An answer."), viewer = viewer })
        TestRunner:assertTrue(type(shown.on_select) == "function", "the popup is given the handler")
        local cleared = false
        shown.on_select("ledger", 123, function() cleared = true end)
        TestRunner:assertEqual(got[1], "ledger")
        TestRunner:assertEqual(got[2], 123, "how long it was held decides between the lookup and the menu")
        TestRunner:assertEqual(got.n, 6)
        got[6].clear_highlight()
        TestRunner:assertEqual(cleared, true, "the highlight to clear is the popup's")
    end)
    -- a caller with no chat window (the X-Ray card's popup style) is as before
    withWidgets(function()
        local ScrollText = require("ui/widget/scrolltextwidget")
        local real = ScrollText.new
        ScrollText.new = function(_self, o) return plainWidget(2, 20)(o.width, o.height) end
        local ok, err = pcall(function()
            MinimalPopup.showForResponse({ history = history("An answer."), features = {} })
            TestRunner:assertEqual(shown.on_select, nil)
        end)
        ScrollText.new = real
        if not ok then error(err, 0) end
    end)
end)

TestRunner:test("the chat window does with a selection made elsewhere what it does with its own", function()
    local real_build = Viewer.buildTextSelectionPopup
    local given
    Viewer.buildTextSelectionPopup = function(text, opts) given = { text = text, opts = opts } end
    local ok, err = pcall(function()
        local looked, own_cleared, popup_cleared = nil, 0, 0
        local window = {
            _ui = { dictionary = { onLookupWord = function(_d, word) looked = word end } },
            configuration = { document_path = "/books/a.epub" },
            onAskQuestion = function() end,  -- a window with a reply box
            clearTextHighlight = function() own_cleared = own_cleared + 1 end,
            showTextSelectionPopup = Viewer.showTextSelectionPopup,
        }
        local elsewhere = { clear_highlight = function() popup_cleared = popup_cleared + 1 end }
        -- one word: looked up, in the book the chat is about
        Viewer.handleTextSelection(window, "ledger", nil, nil, nil, nil, elsewhere)
        TestRunner:assertEqual(looked, "ledger")
        TestRunner:assertEqual(window._ui.dictionary._koassistant_lookup_book, "/books/a.epub")
        TestRunner:assertEqual(popup_cleared, 1, "the other window's highlight is cleared")
        TestRunner:assertEqual(own_cleared, 0, "not this window's, which is not on screen")
        TestRunner:assertEqual(given, nil, "no menu for a word")
        -- a passage: the selection menu, without Add to reply
        Viewer.handleTextSelection(window, "the toll ledger", nil, nil, nil, nil, elsewhere)
        TestRunner:assertEqual(given.text, "the toll ledger")
        TestRunner:assertEqual(given.opts.add_to_reply, nil, "its reply box is not on screen")
        TestRunner:assertEqual(given.opts.clear_highlight, elsewhere.clear_highlight)
        TestRunner:assertTrue(type(given.opts.append_to_notebook) == "function", "the rest of the menu is the window's")
        -- in the window itself nothing changed
        given = nil
        Viewer.handleTextSelection(window, "the toll ledger")
        TestRunner:assertTrue(type(given.opts.add_to_reply) == "function", "the window's own selection keeps Add to reply")
        given.opts.clear_highlight()
        TestRunner:assertEqual(own_cleared, 1)
    end)
    Viewer.buildTextSelectionPopup = real_build
    if not ok then error(err, 0) end
end)

-- ── The keep mark ───────────────────────────────────────────────────────────
TestRunner:test("where the mark's choices open: outside the popup, their far edge on the popup's, under it or over it", function()
    -- KOReader's own rule for an anchored window, as MovableContainer:ensureAnchor has it
    -- (the caller prefers under): where the window's top-left corner lands
    local function koreader(a, w, h, screen_w, screen_h, mirrored)
        local left = mirrored and (a.x + a.w - w) or a.x
        if left < 0 then left = 0 elseif left + w > screen_w then left = screen_w - w end
        local above, below = a.y - h, screen_h - (a.y + a.h + h)
        local top
        if below >= 0 then top = a.y + a.h
        elseif above >= 0 then top = a.y - h
        elseif above >= below then top = 0
        else top = screen_h - h end
        return left, math.max(top, 0)
    end
    local W, H = 1072, 1448
    local menu_w, menu_h = 584, 699
    -- a box under a selected line near the page's top: the sign in its foot corner
    local popup = { x = 24, y = 282, w = 1024, h = 145 }
    local sign = { x = 1005, y = 382, w = 40, h = 40 }
    local a = MinimalPopup.menuAnchor(popup, sign, menu_w, menu_h, H, false)
    local left, top = koreader(a, menu_w, menu_h, W, H, false)
    TestRunner:assertEqual(left + menu_w, popup.x + popup.w, "the choices' right edge is the popup's: nothing sticks out past it")
    TestRunner:assertEqual(top, popup.y + popup.h, "under the popup: the answer stays whole")
    -- a box over a line at the page's foot: no room under, so over the popup, not over its text
    popup = { x = 24, y = 1155, w = 1024, h = 145 }
    sign = { x = 1005, y = 1255, w = 40, h = 40 }
    a = MinimalPopup.menuAnchor(popup, sign, menu_w, menu_h, H, false)
    left, top = koreader(a, menu_w, menu_h, W, H, false)
    TestRunner:assertEqual(left + menu_w, popup.x + popup.w)
    TestRunner:assertEqual(top + menu_h, popup.y, "over the popup: its foot on the popup's head")
    -- the panel at the foot of the screen, from edge to edge
    popup = { x = 0, y = 1307, w = 1072, h = 141 }
    sign = { x = 1032, y = 1406, w = 40, h = 40 }
    a = MinimalPopup.menuAnchor(popup, sign, menu_w, menu_h, H, false)
    left, top = koreader(a, menu_w, menu_h, W, H, false)
    TestRunner:assertEqual(left + menu_w, W)
    TestRunner:assertEqual(top + menu_h, popup.y)
    -- a popup too tall for either: right at the sign, over it
    popup = { x = 24, y = 595, w = 1024, h = 705 }
    sign = { x = 1005, y = 1255, w = 40, h = 40 }
    a = MinimalPopup.menuAnchor(popup, sign, menu_w, menu_h, H, false)
    left, top = koreader(a, menu_w, menu_h, W, H, false)
    TestRunner:assertEqual(left + menu_w, popup.x + popup.w)
    TestRunner:assertEqual(top + menu_h, sign.y, "its foot on the sign's head")
    -- an interface that runs right to left: the sign is in the left corner, the choices' left edge on the popup's
    popup = { x = 24, y = 282, w = 1024, h = 145 }
    sign = { x = 27, y = 382, w = 40, h = 40 }
    a = MinimalPopup.menuAnchor(popup, sign, menu_w, menu_h, H, true)
    left, top = koreader(a, menu_w, menu_h, W, H, true)
    TestRunner:assertEqual(left, popup.x)
    TestRunner:assertEqual(top, popup.y + popup.h)
end)

TestRunner:test("where the keep mark sits: inside the frame's foot corner, flush with its inner edge", function()
    -- a box 1024 wide and 145 tall with a border of 3: a sign of 40, 2 above the foot, a finger's margin of 25
    local s = { side = 40, gap = 2, border = 3, margin = 25 }
    local place = MinimalPopup.keepPlace(1024, 145, s, false)
    TestRunner:assertEqual(place.sign.x + place.sign.w, 1024 - 3, "its right edge is the frame's inner edge")
    TestRunner:assertEqual(place.sign.y + place.sign.h, 145 - 3 - 2, "its foot just above the frame's")
    TestRunner:assertEqual(place.sign.w, 40)
    TestRunner:assertEqual(place.sign.h, 40)
    TestRunner:assertTrue(place.sign.x >= 0 and place.sign.y >= 0, "inside the frame: nothing sticks out of it")
    -- the touch zone: the sign and the margin around it, the frame's edge included
    TestRunner:assertEqual(place.zone.x, place.sign.x - 25)
    TestRunner:assertEqual(place.zone.y, place.sign.y - 25)
    TestRunner:assertEqual(place.zone.w, 40 + 50)
    TestRunner:assertEqual(place.zone.h, 40 + 50)
    -- a panel has no border: the screen's own corner
    local panel = MinimalPopup.keepPlace(1072, 139, { side = 40, gap = 2, border = 0, margin = 25 }, false)
    TestRunner:assertEqual(panel.sign.x + panel.sign.w, 1072)
    TestRunner:assertEqual(panel.sign.y + panel.sign.h, 139 - 2)
    -- a mirrored layout: the other corner
    local mirrored = MinimalPopup.keepPlace(1024, 145, s, true)
    TestRunner:assertEqual(mirrored.sign.x, 3, "flush with the left inner edge")
    TestRunner:assertEqual(mirrored.sign.y, place.sign.y)
end)

-- A chat window whose answer can be kept: what saveToNote and dropNote were asked
local function keepingViewer(calls, needs)
    return {
        markdown_font_size = 20,
        answerWidget = function(_self, _text, w, h) return htmlWidget(needs or 100)(w, h) end,
        canKeepNote = function() return calls.can ~= false end,
        saveToNote = function(_self, pick, opts)
            calls[#calls + 1] = { what = pick and "pick" or "save", opts = opts }
            if not pick and opts.on_saved then opts.on_saved({ created = true, text = "x" }) end
        end,
        dropNote = function(_self, saved)
            calls[#calls + 1] = { what = "drop", saved = saved }
            return calls.drop ~= false
        end,
    }
end
local function at(x, y)
    return { x = x, y = y, intersectWith = function(self, d)
        return self.x >= d.x and self.x <= d.x + d.w and self.y >= d.y and self.y <= d.y + d.h
    end }
end
-- What a paint leaves on the frame, which every touch is judged against. The
-- stand-in screen scales nothing: the sign is KEEP_SIDE wide, flush with the
-- frame's inner edge (a border of 1), one above its foot
local SIDE, MARGIN = MinimalPopup.KEEP_SIDE, MinimalPopup.KEEP_MARGIN
local SIGN = { x = 100 + 600 - 1 - SIDE, y = 100 + 200 - 1 - 1 - SIDE }
local ON_SIGN = { SIGN.x + SIDE / 2, SIGN.y + SIDE / 2 }
local function painted(p)
    p.frame.dimen = { x = 100, y = 100, w = 600, h = 200 }
    if p.movable then p.movable.dimen = { x = 100, y = 100, w = 600, h = 200 } end
    -- the events a hold is handed on under, as KOReader's containers pass
    -- them: the popup's own handler here (the stand-in content takes none)
    p.handleEvent = function(self, event)
        local handler = self["on" .. event.name]
        return handler and handler(self, (table.unpack or unpack)(event.args, 1, event.n)) or false
    end
end
-- (another file's stand-in for the event class may be the one loaded: its own
-- constructor is put back at the end)
local Event = package.loaded["ui/event"]
local real_event_new = Event.new
Event.new = function(_self, name, ...)
    return { name = name, args = { ... }, n = select("#", ...) }
end

TestRunner:test("an answer that can be kept carries the mark; one that cannot has none", function()
    withWidgets(function()
        local calls = {}
        MinimalPopup.showForResponse({ history = history("An answer."), viewer = keepingViewer(calls) })
        TestRunner:assertTrue(shown.keep ~= nil and shown.keep_mark ~= nil, "the mark")
        TestRunner:assertEqual(shown.kept, false, "not kept yet")
        TestRunner:assertEqual(shown.keep_mark[1].text, "+", "a plus")
        TestRunner:assertEqual(shown.keep_holder.overlap_offset[1], 600 - 1 - SIDE, "placed by the frame's own size")
        TestRunner:assertEqual(shown.frame.padding_bottom, 0, "the frame's foot is what it is without a mark")
        calls.can = false
        MinimalPopup.showForResponse({ history = history("An answer."), viewer = keepingViewer(calls) })
        TestRunner:assertEqual(shown.keep, nil, "no selection to keep it with: no mark")
        TestRunner:assertEqual(shown.keep_mark, nil)
    end)
end)

TestRunner:test("under an answer that scrolls the foot is as tall as the sign, so the scroll bar ends above it", function()
    withWidgets(function()
        local calls = {}
        MinimalPopup.showForResponse({ history = history("long"), viewer = keepingViewer(calls, CAP * 3) })
        TestRunner:assertTrue(shown:hasOverflow(), "it scrolls")
        TestRunner:assertEqual(shown.frame.padding_bottom, SIDE + 1, "the sign's box and its gap")
        -- the same answer with no mark keeps the plain foot
        calls.can = false
        MinimalPopup.showForResponse({ history = history("long"), viewer = keepingViewer(calls, CAP * 3) })
        TestRunner:assertEqual(shown.frame.padding_bottom, 0)
    end)
end)

TestRunner:test("a tap on the mark keeps the answer through the chat window, and takes it back out", function()
    withWidgets(function()
        local calls = {}
        local expanded = 0
        MinimalPopup.showForResponse({ history = history("An answer."), viewer = keepingViewer(calls),
            on_expand = function() expanded = expanded + 1 end })
        local p = shown
        painted(p)
        TestRunner:assertEqual(p:onTap(nil, { pos = at(ON_SIGN[1], ON_SIGN[2]) }), true)
        TestRunner:assertEqual(calls[1].what, "save")
        TestRunner:assertEqual(calls[1].opts.popup, true, "the chat window is told the popup shows the answer: no notice, nothing to close")
        TestRunner:assertEqual(p.kept, true)
        TestRunner:assertEqual(p.keep_mark[1].text, "\u{2713}", "the mark is a tick")
        TestRunner:assertEqual(expanded, 0, "a tap on the mark does not open the full window")
        -- a finger's margin around the sign counts too, the frame's edge and just past it included
        TestRunner:assertEqual(p:onKeepMark(at(SIGN.x - MARGIN + 1, SIGN.y - MARGIN + 1)), true, "beside it, over the text's last line")
        TestRunner:assertEqual(p:onKeepMark(at(100 + 600 + 5, 100 + 200 + 5)), true, "on the frame's corner")
        TestRunner:assertEqual(p:onKeepMark(at(SIGN.x - MARGIN - 2, SIGN.y + 5)), false, "further into the text: not the mark's")
        TestRunner:assertEqual(p:onKeepMark(at(SIGN.x + 5, SIGN.y - MARGIN - 2)), false)
        -- a tap on the tick: out again
        p:onTap(nil, { pos = at(ON_SIGN[1], ON_SIGN[2]) })
        TestRunner:assertEqual(calls[2].what, "drop")
        TestRunner:assertEqual(calls[2].saved.text, "x", "the save it was kept by")
        TestRunner:assertEqual(p.kept, false)
        TestRunner:assertEqual(p.keep_mark[1].text, "+")
        -- a note that could not be taken out stays ticked
        p:onTap(nil, { pos = at(ON_SIGN[1], ON_SIGN[2]) })
        calls.drop = false
        p:onTap(nil, { pos = at(ON_SIGN[1], ON_SIGN[2]) })
        TestRunner:assertEqual(p.kept, true)
    end)
end)

TestRunner:test("a tap elsewhere in the popup still opens the full window", function()
    withWidgets(function()
        local calls = {}
        local expanded = 0
        MinimalPopup.showForResponse({ history = history("An answer."), viewer = keepingViewer(calls),
            on_expand = function() expanded = expanded + 1 end })
        painted(shown)
        shown:onTap(nil, { pos = at(300, 150) })
        TestRunner:assertEqual(expanded, 1)
        TestRunner:assertEqual(#calls, 0, "nothing was saved")
    end)
end)

TestRunner:test("an answer saved automatically arrives ticked; a tap takes that one out", function()
    withWidgets(function()
        local calls = {}
        local auto_saved = { created = true, text = "x" }
        MinimalPopup.showForResponse({ history = history("An answer."), viewer = keepingViewer(calls), kept = auto_saved })
        local p = shown
        TestRunner:assertEqual(p.kept, true)
        TestRunner:assertEqual(p.keep_mark[1].text, "\u{2713}")
        painted(p)
        p:onTap(nil, { pos = at(ON_SIGN[1], ON_SIGN[2]) })
        TestRunner:assertEqual(calls[1].what, "drop")
        TestRunner:assertEqual(calls[1].saved, auto_saved)
        TestRunner:assertEqual(p.kept, false)
    end)
end)

TestRunner:test("a hold on the mark opens the chat window's choices at once, with the switch for saving automatically", function()
    withWidgets(function()
        local calls = {}
        local flips, on = 0, false
        local closed = 0
        MinimalPopup.showForResponse({ history = history("An answer."), viewer = keepingViewer(calls),
            on_close = function() closed = closed + 1 end,
            auto = {
                text = function() return on and "● Auto-save Translate answers" or "○ Auto-save Translate answers" end,
                flip = function() flips = flips + 1; on = not on; return on end,
            } })
        local p = shown
        painted(p)
        TestRunner:assertEqual(p:onPopupHold(nil, { pos = at(ON_SIGN[1], ON_SIGN[2]) }), true, "the hold is the mark's")
        TestRunner:assertEqual(#calls, 1, "the choices open while the finger still rests there, not when it is lifted")
        TestRunner:assertEqual(calls[1].what, "pick")
        -- they open from the popup's corner that holds the sign: KOReader's anchor, worked out
        -- from the choices' own size once their window has one (a box at 100,100, 600 by 200,
        -- on a screen 600 tall: choices 300 by 250 fit under it)
        local where, below = calls[1].opts.anchor({ movable = { dimen = { w = 300, h = 250 } } })
        TestRunner:assertEqual(where.x, 100 + 600 - 300, "the choices' far edge on the popup's")
        TestRunner:assertEqual(where.w, 300)
        TestRunner:assertEqual(where.y, 100, "the popup's own height: the choices go under it or over it")
        TestRunner:assertEqual(where.h, 200)
        TestRunner:assertEqual(below, true, "under it where there is room")
        TestRunner:assertTrue(calls[1].opts.anchor({ movable = { dimen = { w = 300, h = 250 } } }) ~= where,
            "a rectangle of its own at every call (KOReader writes on the one it is given)")
        -- choices too tall to stand under or over the popup: right at the sign
        where = calls[1].opts.anchor({ movable = { dimen = { w = 300, h = 450 } } })
        TestRunner:assertEqual(where.y, SIGN.y)
        TestRunner:assertEqual(where.h, SIDE)
        -- a window whose size is not known yet: the sign's own rectangle
        where, below = calls[1].opts.anchor()
        TestRunner:assertEqual(where.x, SIGN.x)
        TestRunner:assertEqual(where.y, SIGN.y)
        TestRunner:assertEqual(where.w, SIDE)
        TestRunner:assertEqual(below, true)
        -- what follows of that hold is swallowed, and opens nothing more
        TestRunner:assertEqual(p:onPopupHoldPan(nil, { pos = at(ON_SIGN[1], ON_SIGN[2]) }), true)
        TestRunner:assertEqual(p:onPopupHoldRelease(nil, { pos = at(ON_SIGN[1], ON_SIGN[2]) }), true)
        TestRunner:assertEqual(#calls, 1)
        local extra = calls[1].opts.extra
        TestRunner:assertEqual(extra[1].separator, true, "a setting sits under the double line")
        TestRunner:assertEqual(extra[2].text, "○ Auto-save Translate answers")
        -- turned on: this answer is kept too
        extra[2].callback()
        TestRunner:assertEqual(flips, 1)
        TestRunner:assertEqual(calls[2].what, "save")
        TestRunner:assertEqual(p.kept, true)
        -- the editor closes the popup first
        calls[1].opts.before_edit()
        TestRunner:assertEqual(closed, 1)
    end)
end)

TestRunner:test("a hold anywhere else is the text's, then the box's, as before; a hold whose release never comes leaves nothing behind", function()
    withWidgets(function()
        local calls = {}
        MinimalPopup.showForResponse({ history = history("An answer."), viewer = keepingViewer(calls) })
        local p = shown
        painted(p)
        local moved, released = 0, 0
        p.movable.onMovableHold = function() moved = moved + 1; return false end
        p.movable.onMovableHoldPan = function() return false end
        p.movable.onMovableHoldRelease = function() released = released + 1; return false end
        -- a hold on the mark whose release went to the window it opened
        p:onPopupHold(nil, { pos = at(ON_SIGN[1], ON_SIGN[2]) })
        TestRunner:assertEqual(#calls, 1)
        -- the next hold is on the text: handed on under the names the content widget knows
        local seen = {}
        local handle = p.handleEvent
        p.handleEvent = function(self, event)
            seen[#seen + 1] = event.name
            return handle(self, event)
        end
        TestRunner:assertEqual(p:onPopupHold(nil, { pos = at(300, 150) }), false)
        p:onPopupHoldPan(nil, { pos = at(320, 150) })
        p:onPopupHoldRelease("the selection's callback", { pos = at(320, 150) })
        TestRunner:assertEqual(table.concat(seen, ","), "HoldStartText,HoldPanText,HoldReleaseText")
        TestRunner:assertEqual(moved, 1, "one the text does not take is the box's")
        TestRunner:assertEqual(released, 1, "its release too: the hold before left nothing behind")
        TestRunner:assertEqual(#calls, 1, "and no choices opened")
    end)
end)

Event.new = real_event_new
for i = #added, 1, -1 do added[i][1][added[i][2]] = nil end
for _i, name in ipairs(stubbed) do package.loaded[name] = nil end

return TestRunner:summary()
