-- The place a chat window shows across a re-layout: the view switched between
-- Markdown and plain text, the window's size toggled, the screen rotated.
--
-- History: captureState once asked the scroll widget for two methods no
-- KOReader ever had, so every rebuilt window opened at the top (B611,
-- 2026-11-05); the ratio it carried after that landed a page or several lines
-- off (a page is a whole screen), a chat continued from Chat History handed it
-- to a field nothing read, and the view switch started at the top (the
-- maintainer's device round, 2026-11-13). The place is now the first words on
-- screen plus how far through they stood (koassistant/ui/viewer_place.lua),
-- captured and restored by the viewer for all three.
--
-- The widgets here are stand-ins holding the fields the viewer reads; those
-- names are checked against the installed KOReader's own widget files when
-- the bundle is present. The real widgets run in
-- tests/scenarios/s12_window_place.lua.
--
-- Run: lua tests/unit/test_viewer_place.lua  (or lua tests/run_tests.lua --unit)

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
local Place = require("koassistant.ui.viewer_place")
local UIManager = require("ui/uimanager")

local function viewer(fields)
    return setmetatable(fields, { __index = ChatGPTViewer })
end

local LRM = "\226\128\142"

-- A stand-in for the HTML widget: pages of words, the page shown
local function htmlWidget(pages, shown)
    local box = { page_number = shown, page_count = #pages }
    box.document = {
        openPage = function(_self, n)
            return {
                getPageText = function()
                    local line = {}
                    for word in (pages[n] or ""):gmatch("%S+") do line[#line + 1] = { word = word } end
                    return { line }
                end,
                close = function() end,
            }
        end,
    }
    local w = { htmlbox_widget = box }
    function w:scrollToRatio(ratio)
        self.scrolled = ratio
        box.page_number = math.min(box.page_count, 1 + math.floor(box.page_count * ratio))
    end
    return w
end

-- A stand-in for the plain-text widget: a text cut into lines of `width`
-- characters (ASCII here), the line shown at the top
local function textWidget(text, width, top, lines_per_page)
    local lines = {}
    for offset = 1, #text, width do lines[#lines + 1] = { offset = offset } end
    local tw = { text = text, vertical_string_list = lines, virtual_line_num = top, lines_per_page = lines_per_page or 4 }
    local w = { text_widget = tw }
    function w:scrollToRatio(ratio, to_page)
        self.scrolled, self.to_page = ratio, to_page
        -- TextBoxWidget:scrollToRatio(ratio, false)
        local line = 1 + math.floor(ratio * #lines - tw.lines_per_page / 2)
        if line + tw.lines_per_page > #lines then line = #lines - tw.lines_per_page + 1 end
        if line < 1 then line = 1 end
        tw.virtual_line_num = line
    end
    return w
end

print("Running: test_viewer_place")
print("")
print("  [the words of a place]")

TestRunner:test("words: whitespace and punctuation separate, the plain-text view's decoration is left out", function()
    TestRunner:assertEqual(table.concat(Place.words("▉ Answer 4, begins *here*!"), "|"), "Answer|4|begins|here")
    TestRunner:assertEqual(table.concat(Place.words("• a point\n│ a quote\n───────────────\nlantern" .. LRM .. " keeper"), "|"),
        "a|point|a|quote|lantern|keeper")
    TestRunner:assertEqual(#Place.words("one two three four", 2), 2, "at most the limit")
    TestRunner:assertEqual(#Place.words(nil), 0)
end)

TestRunner:test("anchor: the first eight words; too little names no place", function()
    local words = Place.anchor("one two three four five six seven eight nine ten")
    TestRunner:assertEqual(#words, 8)
    TestRunner:assertEqual(words[8], "eight")
    TestRunner:assertEqual(Place.anchor("a b c"), nil, "three letters")
    TestRunner:assertEqual(Place.anchor("─────"), nil, "a rule alone")
    TestRunner:assertEqual(Place.anchor(""), nil)
end)

TestRunner:test("anchor: a script written without spaces is one long word, cut on a whole character", function()
    local kana = string.rep("\227\129\130", 60)  -- 180 bytes, no space
    local words = Place.anchor(kana)
    TestRunner:assertEqual(#words, 1)
    TestRunner:assertEqual(#words[1], 96, "cut at the byte budget")
    TestRunner:assertEqual(#words[1] % 3, 0, "between two characters")
end)

TestRunner:test("find: the words in order, whatever separates them", function()
    local words = Place.anchor("the lantern keeper counted the steps")
    TestRunner:assertEqual(Place.find("xx the lantern keeper counted the steps yy", words), 4)
    TestRunner:assertEqual(Place.find("xx the **lantern**" .. LRM .. " keeper,\ncounted — the\n\n• steps", words), 4,
        "bold marks, a direction mark, a line end, a dash, a bullet")
    TestRunner:assertEqual(Place.find("the lantern keeper counted steps", words), nil, "a word missing")
    TestRunner:assertEqual(Place.find("", words), nil)
    TestRunner:assertEqual(Place.find("text", {}), nil)
end)

TestRunner:test("find: of several copies, the one nearest the expected position", function()
    local text = "alpha beta gamma delta | alpha beta gamma delta | alpha beta gamma delta"
    local words = Place.anchor("alpha beta gamma delta")
    TestRunner:assertEqual(Place.find(text, words), 1, "no expectation: the first")
    TestRunner:assertEqual(Place.find(text, words, 30), 26)
    TestRunner:assertEqual(Place.find(text, words, 70), 51)
    TestRunner:assertEqual(Place.find(text, words, 2), 1)
end)

TestRunner:test("findPage: the page the copy starts on, a copy that runs over a page's end included", function()
    local pages = {
        { number = 4, text = "intro words here and more of them" },
        { number = 5, text = "then the lantern keeper" },
        { number = 6, text = "counted the steps to the harbour" },
    }
    TestRunner:assertEqual(Place.findPage(pages, Place.anchor("counted the steps to the"), 5), 6)
    TestRunner:assertEqual(Place.findPage(pages, Place.anchor("the lantern keeper counted the steps"), 6), 5,
        "starts on page 5, ends on 6")
    TestRunner:assertEqual(Place.findPage(pages, Place.anchor("nothing of the kind here"), 5), nil)
    TestRunner:assertEqual(Place.findPage({}, Place.anchor("counted the steps to the"), 5), nil)
end)

TestRunner:test("characters and bytes", function()
    local text = "aé▉b"  -- 1 + 2 + 3 + 1 bytes
    TestRunner:assertEqual(Place.byteOfChar(text, 1), 1)
    TestRunner:assertEqual(Place.byteOfChar(text, 3), 4)
    TestRunner:assertEqual(Place.byteOfChar(text, 4), 7)
    TestRunner:assertEqual(Place.byteOfChar(text, 9), 8, "past the end")
    TestRunner:assertEqual(Place.charOfByte(text, 4), 3)
    TestRunner:assertEqual(Place.charOfByte(text, 7), 4)
    TestRunner:assertEqual(Place.lineOfChar({ { offset = 1 }, { offset = 10 }, { offset = 20 } }, 12), 2)
end)

print("")
print("  [the viewer captures the place]")

TestRunner:test("the Markdown view: how far through, and the page's first words", function()
    local v = viewer({ scroll_text_w = htmlWidget({ "p1", "p2", "the lantern keeper counted the steps to the harbour", "p4" }, 3) })
    local place = v:capturePlace()
    TestRunner:assertEqual(place.ratio, 0.5)
    TestRunner:assertEqual(table.concat(place.words, " "), "the lantern keeper counted the steps to the")
end)

TestRunner:test("the plain-text view: the first visible line", function()
    local text = "0123456789 the lantern keeper counted the steps to the harbour and wrote"
    local place = viewer({ scroll_text_w = textWidget(text, 11, 2) }):capturePlace()
    TestRunner:assertEqual(place.ratio, 1 / 7)
    TestRunner:assertEqual(place.words[1], "the")
    TestRunner:assertEqual(place.words[2], "lantern")
end)

TestRunner:test("the top, or nothing to read: no place", function()
    TestRunner:assertEqual(viewer({ scroll_text_w = htmlWidget({ "a", "b" }, 1) }):capturePlace(), nil)
    TestRunner:assertEqual(viewer({ scroll_text_w = textWidget("some words here", 5, 1) }):capturePlace(), nil)
    TestRunner:assertEqual(viewer({ scroll_text_w = {} }):capturePlace(), nil)
    TestRunner:assertEqual(viewer({}):capturePlace(), nil)
end)

print("")
print("  [and finds it again in another layout]")

TestRunner:test("Markdown: the page holding the words, not the page the ratio gives", function()
    -- as far through as page 2 of 4; in this layout the words are on page 4 of 8
    local w = htmlWidget({ "a", "b", "c", "the lantern keeper counted the steps", "e", "f", "g", "h" }, 1)
    local v = viewer({ scroll_text_w = w })
    TestRunner:assertTrue(v:restorePlace({ ratio = 0.25, words = Place.anchor("the lantern keeper counted the steps") }))
    TestRunner:assertEqual(w.htmlbox_widget.page_number, 4)
end)

TestRunner:test("Markdown: words that are not found, or none: as far through", function()
    local w = htmlWidget({ "a", "b", "c", "d", "e", "f", "g", "h" }, 1)
    viewer({ scroll_text_w = w }):restorePlace({ ratio = 0.5, words = Place.anchor("nothing of the kind here") })
    TestRunner:assertEqual(w.htmlbox_widget.page_number, 5)
    w = htmlWidget({ "a", "b", "c", "d" }, 1)
    viewer({ scroll_text_w = w }):restorePlace({ ratio = 0.5 })
    TestRunner:assertEqual(w.htmlbox_widget.page_number, 3)
end)

TestRunner:test("plain text: the line the words start on tops the window, with no cursor asked for", function()
    local filler = string.rep("x", 55)
    local text = filler .. "the lantern keeper counted the steps " .. filler
    local w = textWidget(text, 11, 1)
    w.moveCursorToCharPos = function() error("a cursor draws a mark and scrolls the view back") end
    local v = viewer({ scroll_text_w = w })
    TestRunner:assertTrue(v:restorePlace({ ratio = 0.9, words = Place.anchor("the lantern keeper counted the steps") }))
    TestRunner:assertEqual(w.text_widget.virtual_line_num, 6, "character 56 is on line 6")
    TestRunner:assertEqual(w.to_page, false, "a line, not a page")
end)

TestRunner:test("plain text: no words: the line as far through", function()
    local w = textWidget(string.rep("x", 220), 11, 1)
    viewer({ scroll_text_w = w }):restorePlace({ ratio = 0.5 })
    TestRunner:assertEqual(w.text_widget.virtual_line_num, 11)
end)

TestRunner:test("nothing to restore with", function()
    TestRunner:assertEqual(viewer({}):restorePlace({ ratio = 0.5 }), false)
    TestRunner:assertEqual(viewer({ scroll_text_w = htmlWidget({ "only" }, 1) }):restorePlace({ ratio = 0.5 }), false)
    TestRunner:assertEqual(viewer({ scroll_text_w = textWidget("abc", 5, 1) }):restorePlace(nil), false)
end)

print("")
print("  [a re-layout hands the place to the rebuilt window]")

TestRunner:test("a size toggle or a rotation: the state carries the place, the rebuilt window lands on it when shown", function()
    local saved_tick, saved_close, saved_dirty = UIManager.nextTick, UIManager.close, UIManager.setDirty
    UIManager.nextTick = function(_self, fn) fn() end
    UIManager.close = function() end
    UIManager.setDirty = function() end
    local ok, err = pcall(function()
        local got
        local v = viewer({ scroll_text_w = htmlWidget({ "a", "the lantern keeper counted the steps", "c", "d" }, 2) })
        v._recreate_func = function(state) got = state end
        TestRunner:assertTrue(v:_handleScreenChange(true) == true, "rebuilt")
        TestRunner:assertEqual(got and got.place and got.place.ratio, 0.25, "the place rides the state")
        local w = htmlWidget({ "a", "b", "c", "the lantern keeper counted the steps", "e", "f", "g", "h" }, 1)
        local rebuilt = viewer({ scroll_text_w = w, _initial_place = got.place, frame = { dimen = {} } })
        rebuilt:onShow()
        TestRunner:assertEqual(w.htmlbox_widget.page_number, 4, "the rebuilt window opens on the words")
        TestRunner:assertEqual(rebuilt._initial_place, nil, "once")
    end)
    UIManager.nextTick, UIManager.close, UIManager.setDirty = saved_tick, saved_close, saved_dirty
    if not ok then error(err, 0) end
end)

TestRunner:test("both recreate paths hand the state's place to the new window", function()
    local function read(rel)
        local f = assert(io.open(plugin_dir .. "/" .. rel, "r"))
        local s = f:read("*a")
        f:close()
        return s
    end
    TestRunner:assertTrue(read("koassistant/ui/dialogs.lua"):find("_initial_place = state.place", 1, true) ~= nil,
        "a chat window")
    TestRunner:assertTrue(read("koassistant/chat/chat_history_dialog.lua"):find("_initial_place = state and state.place", 1, true) ~= nil,
        "a chat continued from Chat History")
    local src = read("koassistant/ui/chatgptviewer.lua")
    TestRunner:assertTrue(src:find("self._initial_place", 1, true) ~= nil, "and the viewer reads it")
    for _idx, dead in ipairs({ "_initial_scroll_ratio", "restoreScrollPosition" }) do
        for _j, rel in ipairs({ "koassistant/ui/dialogs.lua", "koassistant/chat/chat_history_dialog.lua", "koassistant/ui/chatgptviewer.lua" }) do
            TestRunner:assertTrue(read(rel):find(dead, 1, true) == nil, dead .. " is gone from " .. rel)
        end
    end
end)

print("")
print("  [the names are KOReader's]")

TestRunner:test("the viewer asks for nothing KOReader lacks; the names it uses exist in the installed bundle", function()
    local f = assert(io.open(plugin_dir .. "/koassistant/ui/chatgptviewer.lua", "r"))
    local src = f:read("*a")
    f:close()
    for _idx, invented in ipairs({ "getScrolledRatio", "getScrollPercent", "scrollToPercent" }) do
        TestRunner:assertTrue(src:find(invented, 1, true) == nil, invented .. " existed in no KOReader")
    end
    local bundle = "/Applications/KOReader.app/Contents/koreader/frontend/ui/widget/"
    local function read(name)
        local h = io.open(bundle .. name, "r")
        if not h then return nil end
        local s = h:read("*a")
        h:close()
        return s
    end
    local html = read("scrollhtmlwidget.lua")
    if not html then
        print("    (no KOReader bundle at " .. bundle .. ": the widget names are not checked)")
        return
    end
    TestRunner:assertTrue(html:find("function ScrollHtmlWidget:scrollToRatio", 1, true) ~= nil, "scrollToRatio")
    TestRunner:assertTrue(html:find("self.htmlbox_widget.page_count", 1, true) ~= nil
        and html:find("self.htmlbox_widget.page_number", 1, true) ~= nil, "the HTML box's page_number and page_count")
    local box = read("htmlboxwidget.lua")
    TestRunner:assertTrue(box:find("self.document:openPage", 1, true) ~= nil and box:find("getPageText", 1, true) ~= nil,
        "the HTML box's document, a page's getPageText")
    local text = read("textboxwidget.lua")
    for _idx, name in ipairs({ "self.virtual_line_num", "self.vertical_string_list", "self.lines_per_page" }) do
        TestRunner:assertTrue(text:find(name, 1, true) ~= nil, name)
    end
    TestRunner:assertTrue(text:find('self.text = table.concat(charlist, "")', 1, true) ~= nil,
        "the text widget keeps the text it shows, the bold marks taken out, in self.text")
    TestRunner:assertTrue(read("scrolltextwidget.lua"):find("function ScrollTextWidget:scrollToRatio", 1, true) ~= nil,
        "the plain-text scrollToRatio")
end)

return TestRunner:summary()
