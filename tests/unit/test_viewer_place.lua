-- The place in an answer across a re-layout (B611, 2026-11-05): rotation, a
-- screen resize and the gear's window-size toggle rebuild the chat window
-- from captureState, which asked the scroll widget for two methods no
-- KOReader ever had (getScrolledRatio, getScrollPercent), so the ratio was
-- always 0 and every rebuilt window opened at the answer's top. Now it reads
-- ScrollHtmlWidget:getCurrentRatio (the Markdown view) or the plain-text
-- widget's TextBoxWidget:getVisibleHeightRatios, both checked here against
-- the installed KOReader's own widget files when the bundle is present.
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
local UIManager = require("ui/uimanager")

local function viewer(fields)
    return setmetatable(fields, { __index = ChatGPTViewer })
end

print("Running: test_viewer_place")
print("")
print("  [the place captured (B611)]")

TestRunner:test("the Markdown view: the HTML widget's page ratio", function()
    local v = viewer({ scroll_text_w = { getCurrentRatio = function() return 0.4 end } })
    TestRunner:assertEqual(v:captureState().scroll_ratio, 0.4)
end)

TestRunner:test("the plain-text view: the text widget's first visible line", function()
    local v = viewer({ scroll_text_w = { text_widget = { getVisibleHeightRatios = function() return 0.3, 0.55 end } } })
    TestRunner:assertEqual(v:captureState().scroll_ratio, 0.3)
end)

TestRunner:test("nothing to read: the top", function()
    TestRunner:assertEqual(viewer({ scroll_text_w = {} }):captureState().scroll_ratio, 0)
    TestRunner:assertEqual(viewer({}):captureState().scroll_ratio, 0)
end)

print("")
print("  [a re-layout hands the place to the rebuilt window]")

TestRunner:test("rotation: the rebuild gets the ratio, and restoring scrolls there; the top restores nothing", function()
    local saved_tick, saved_sched, saved_close, saved_dirty =
        UIManager.nextTick, UIManager.scheduleIn, UIManager.close, UIManager.setDirty
    UIManager.nextTick = function(_self, fn) fn() end
    UIManager.scheduleIn = function(_self, _seconds, fn) fn() end
    UIManager.close = function() end
    UIManager.setDirty = function() end
    local ok, err = pcall(function()
        local got
        local v = viewer({ scroll_text_w = { getCurrentRatio = function() return 0.4 end } })
        v._recreate_func = function(state) got = state end
        TestRunner:assertTrue(v:_handleScreenChange(true) == true, "rebuilt")
        TestRunner:assertEqual(got and got.scroll_ratio, 0.4, "the place rides the state")
        local landed
        local rebuilt = viewer({ scroll_text_w = { scrollToRatio = function(_self, ratio) landed = ratio end } })
        rebuilt:restoreScrollPosition(got.scroll_ratio)
        TestRunner:assertEqual(landed, 0.4, "scrolled back to it")
        landed = nil
        rebuilt:restoreScrollPosition(0)
        TestRunner:assertEqual(landed, nil, "the top needs no scroll")
    end)
    UIManager.nextTick, UIManager.scheduleIn, UIManager.close, UIManager.setDirty =
        saved_tick, saved_sched, saved_close, saved_dirty
    if not ok then error(err, 0) end
end)

print("")
print("  [the names are KOReader's]")

TestRunner:test("the viewer asks for nothing KOReader lacks; the two names it uses exist in the installed bundle", function()
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
    TestRunner:assertTrue(html:find("function ScrollHtmlWidget:getCurrentRatio", 1, true) ~= nil, "getCurrentRatio")
    TestRunner:assertTrue(html:find("function ScrollHtmlWidget:scrollToRatio", 1, true) ~= nil, "scrollToRatio")
    TestRunner:assertTrue(read("textboxwidget.lua"):find("function TextBoxWidget:getVisibleHeightRatios", 1, true) ~= nil,
        "getVisibleHeightRatios")
    TestRunner:assertTrue(read("scrolltextwidget.lua"):find("function ScrollTextWidget:scrollToRatio", 1, true) ~= nil,
        "the plain-text scrollToRatio")
end)

return TestRunner:summary()
