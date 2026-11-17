-- Waits that keep something moving on screen (B709, #126): some Android
-- e-readers put the processor to sleep about 5 s after the last touch or
-- screen update, even with a page on screen, and KOReader stopped with them
-- until the next tap (a reader's log, 2026-11-17: a 9-minute wait stayed
-- awake with only the chat window's waiting dots moving). One module builds
-- the dots, the tick, the waiting line and the waiting message; this file
-- checks them on stand-ins shaped like KOReader's InfoMessage and TrapWidget
-- (the real widgets: tests/scenarios/s14_waiting.lua), and that no wait
-- builds its own ticker.
--
-- Run: lua tests/unit/test_waiting.lua  (or lua tests/run_tests.lua --unit)

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
local function suite(name) print(string.format("\n  [%s]", name)) end

-- A UIManager whose scheduler is a queue (faithful to KOReader: scheduleIn
-- returns nothing, unschedule takes the function), and a record of setDirty
local SAVED_KEYS = { "ui/uimanager", "ui/widget/infomessage", "ui/widget/trapwidget", "ui/geometry" }
local saved = {}
for _idx, k in ipairs(SAVED_KEYS) do saved[k] = package.loaded[k] end

local queue, dirty = {}, {}
package.loaded["ui/uimanager"] = {
    scheduleIn = function(_self, sec, fn) queue[#queue + 1] = { sec = sec, fn = fn } end,
    unschedule = function(_self, fn)
        for i = #queue, 1, -1 do if queue[i].fn == fn then table.remove(queue, i) end end
    end,
    setDirty = function(_self, widget, refresh) dirty[#dirty + 1] = { widget = widget, refresh = refresh } end,
}
package.loaded["ui/geometry"] = {
    new = function(_self, o) return o end,
}
local function runQueue(max)
    local n = 0
    while #queue > 0 and n < (max or 50) do
        n = n + 1
        local task = table.remove(queue, 1)
        task.fn()
    end
    return n
end

-- Stand-ins with KOReader's nesting: InfoMessage keeps its text box only in
-- its children (centre > movable > frame > row > { icon, span, text });
-- TrapWidget names its frame (self.frame) and holds its text widget in it
local function textWidget(text)
    local w = { text = text, dimen = { x = 10, y = 20, w = 300, h = 40 } }
    function w:setText(t) self.text = t end
    return w
end
local InfoMessageStub = {}
InfoMessageStub.__index = InfoMessageStub
function InfoMessageStub:new(o)
    o = setmetatable(o or {}, self)
    o.text_box = textWidget(o.text)
    o[1] = { { { { { icon = true }, { span = true }, o.text_box } } } }
    return o
end
function InfoMessageStub:onShow() self.shown = true; return true end
function InfoMessageStub:onCloseWidget()
    -- KOReader's InfoMessage runs its dismiss_callback on any close
    if self.dismiss_callback then self.dismiss_callback() end
end
package.loaded["ui/widget/infomessage"] = InfoMessageStub

local TrapWidgetStub = {}
TrapWidgetStub.__index = TrapWidgetStub
function TrapWidgetStub:new(o)
    o = setmetatable(o or {}, self)
    local textw = textWidget(o.text)
    o.frame = { textw, dimen = { x = 0, y = 500, w = 0, h = 30 } }
    function o.frame:getSize() return { w = 7 * #self[1].text, h = 30 } end
    o[1] = { { { o.frame } } }
    return o
end
package.loaded["ui/widget/trapwidget"] = TrapWidgetStub

package.loaded["koassistant.ui.waiting"] = nil
local Waiting = require("koassistant.ui.waiting")

print("Running: test_waiting")
print("")

suite("the dots, the tick, the line")

TestRunner:test("the dots cycle as the chat window's do, and start over on reset", function()
    local d = Waiting.dots()
    local seen = {}
    for i = 1, 7 do seen[i] = d.getNextFrame() end
    TestRunner:assertEqual(table.concat(seen, " "), ". .. ... .. . . ..")
    d.reset()
    TestRunner:assertEqual(d.getNextFrame(), ".")
    TestRunner:assertEqual(Waiting.INTERVAL, 0.4, "the chat window's pace")
end)

TestRunner:test("a tick runs every interval until stopped, or until its step says its window is gone", function()
    queue = {}
    local runs = 0
    local stop = Waiting.tick(function() runs = runs + 1 end)
    TestRunner:assertEqual(queue[1].sec, 0.4)
    runQueue(3)
    TestRunner:assertEqual(runs, 3)
    stop()
    TestRunner:assertEqual(#queue, 0, "stop takes the pending tick")
    stop()  -- twice is harmless
    queue = {}
    runs = 0
    Waiting.tick(function()
        runs = runs + 1
        if runs >= 2 then return false end
    end)
    runQueue(10)
    TestRunner:assertEqual(runs, 2, "false ends it")
    queue = {}
    Waiting.tick(function() error("window gone") end)
    TestRunner:assertEqual(runQueue(10), 1, "a failing step ends it")
end)

TestRunner:test("the waiting line is the picture window's: the seconds and the dots", function()
    TestRunner:assertEqual(Waiting.line(12, ".."), "Elapsed: 12 s  ..")
end)

TestRunner:test("the text widget is found through the children alone", function()
    local leaf = textWidget("hello")
    local tree = { text = "hello", { { leaf } }, parent = { text = "hello", setText = function() end } }
    TestRunner:assertTrue(Waiting.findTextWidget(tree, "hello") == leaf,
        "the root shows the text but cannot change it; the named field is not walked")
    TestRunner:assertTrue(Waiting.findTextWidget(tree, "other") == nil)
end)

suite("the waiting message")

TestRunner:test("a centred message moves from its show to its close, and its close still runs the dismiss", function()
    queue, dirty = {}, {}
    local dismissed = 0
    local msg = Waiting.message{ text = "Gemini: model\n\nLoading...", dismiss_callback = function() dismissed = dismissed + 1 end }
    TestRunner:assertEqual(msg.text_box.text, "Gemini: model\n\nLoading...\nElapsed: 0 s  .", "the line from the start")
    TestRunner:assertEqual(#queue, 0, "nothing moves before it is shown")
    msg:onShow()
    TestRunner:assertTrue(msg.shown, "KOReader's own show runs")
    runQueue(2)
    TestRunner:assertTrue(msg.text_box.text:find("Loading%.%.%.\nElapsed: %d+ s  %.%.%.$") ~= nil,
        "the dots moved: " .. msg.text_box.text)
    TestRunner:assertEqual(#dirty, 2, "each tick asks for a redraw")
    local mode, region = dirty[1].refresh()
    TestRunner:assertEqual(mode, "fast", "the chat window's dots' refresh")
    TestRunner:assertEqual(region.x .. "," .. region.y .. "," .. region.w .. "," .. region.h, "10,20,300,40",
        "the text widget's own area, read after the paint")
    msg:onCloseWidget()
    TestRunner:assertEqual(dismissed, 1, "the close runs the dismiss, as any InfoMessage")
    TestRunner:assertEqual(#queue, 0, "and stops the dots")
end)

TestRunner:test("a corner notice keeps its widest width, so shorter dots leave nothing behind", function()
    queue, dirty = {}, {}
    local trap = Waiting.message{ text = "Explaining", corner = true }
    local widest = 7 * #"Explaining  ..."
    TestRunner:assertEqual(trap.frame.width, widest, "held at the width of its widest frame")
    trap:onShow()
    runQueue(1)
    TestRunner:assertEqual(trap.frame[1].text, "Explaining  .", "the dots after the text")
    local _mode, region = dirty[1].refresh()
    TestRunner:assertEqual(region.w, widest, "the redraw covers the held width")
    TestRunner:assertEqual(region.y, 500)
    trap:onCloseWidget()
    TestRunner:assertEqual(#queue, 0, "the close stops the dots")
end)

TestRunner:test("a message whose text widget cannot be found still shows, standing still", function()
    queue = {}
    local Plain = setmetatable({}, { __index = InfoMessageStub })
    Plain.__index = Plain
    function Plain:new(o) return setmetatable(o or {}, self) end
    package.loaded["ui/widget/infomessage"] = Plain
    local msg = Waiting.message{ text = "Odd layout" }
    package.loaded["ui/widget/infomessage"] = InfoMessageStub
    TestRunner:assertTrue(msg ~= nil, "the widget comes back")
    msg:onShow()
    TestRunner:assertEqual(#queue, 0, "nothing ticks")
end)

suite("every wait moves through this module")

local function source(rel)
    local f = assert(io.open(plugin_dir .. "/" .. rel, "r"))
    local s = f:read("*a")
    f:close()
    return s
end

local function pluginFiles()
    local p = io.popen('cd "' .. plugin_dir .. '" && ls main.lua && find koassistant -name "*.lua" | LC_ALL=C sort')
    local files = {}
    for line in p:lines() do files[#files + 1] = line end
    p:close()
    return files
end

TestRunner:test("no wait writes the pace by hand: a ticker is Waiting.tick", function()
    local files = pluginFiles()
    TestRunner:assertTrue(#files > 100, "the tree was listed")
    local hits = {}
    for _idx, rel in ipairs(files) do
        if source(rel):find("scheduleIn%(%s*0%.4%s*,") then hits[#hits + 1] = rel end
    end
    TestRunner:assertEqual(table.concat(hits, ", "), "", "a 0.4 s ticker outside Waiting.INTERVAL")
end)

TestRunner:test("every tap-to-cancel wait hands KOReader a moving message", function()
    local files = pluginFiles()
    local sites, bare = 0, {}
    for _idx, rel in ipairs(files) do
        local lines = {}
        for line in (source(rel) .. "\n"):gmatch("([^\n]*)\n") do lines[#lines + 1] = line end
        for i, line in ipairs(lines) do
            if line:find("dismissableRunInSubprocess%(") and not line:find("^%s*%-%-") then
                sites = sites + 1
                local found = false
                for j = math.max(1, i - 8), i do
                    if lines[j]:find('koassistant.ui.waiting"%)%.message') then found = true end
                end
                if not found then bare[#bare + 1] = rel .. ":" .. i end
            end
        end
    end
    TestRunner:assertTrue(sites >= 4, "the whole-book searches were found: " .. sites)
    TestRunner:assertEqual(table.concat(bare, ", "), "", "a tap-to-cancel wait with a message that stands still")
end)

TestRunner:test("the lookup's Loading box, the update's waits and the catalog fetch are waiting messages", function()
    local gq = source("koassistant/request/gpt_query.lua")
    TestRunner:assertTrue(gq:find('loading_dialog = require%("koassistant%.ui%.waiting"%)%.message{') ~= nil, "gpt_query")
    TestRunner:assertTrue(not gq:find("TrapWidget:new", 1, true), "the corner notice is the module's")
    local uc = source("koassistant/storage/update_checker.lua")
    local _a, n = uc:gsub('require%("koassistant%.ui%.waiting"%)%.message{', "")
    TestRunner:assertEqual(n, 2, "checking and downloading")
    TestRunner:assertTrue(source("main.lua"):find('require%("koassistant%.ui%.waiting"%)%.message{ text = _%("Fetching OpenRouter') ~= nil,
        "the OpenRouter catalog")
end)

for _idx, k in ipairs(SAVED_KEYS) do package.loaded[k] = saved[k] end
package.loaded["koassistant.ui.waiting"] = nil

print(string.format("\n  test_waiting: %d passed, %d failed", TestRunner.passed, TestRunner.failed))
return TestRunner.failed == 0
