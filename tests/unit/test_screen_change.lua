-- A turned screen under KOAssistant's windows (B713). Found by the first
-- rotation runs in the real app:
--   1. the chat's input box replaced itself inside the resize event. KOReader
--      BROADCASTS a resize to every window and starts over whenever a new
--      window appears, so the new box was told again, and again: the app hung
--      (in every release that had the handler);
--   2. a rebuilt chat window came back on top of the windows that stood over
--      it: Save Chat, New Tag, the reply box;
--   3. a device whose own sensor KOReader reads hands a turn to the window on
--      top alone: the chat window kept it and never turned the screen.
--
-- Run: lua tests/unit/test_screen_change.lua  (or lua tests/run_tests.lua --unit)

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
local TestRunner = require("test_runner"):new()
local ChatGPTViewer = require("koassistant.ui.chatgptviewer")
local UIManager = require("ui/uimanager")

print("")
print(string.rep("=", 50))
print("  Unit Tests: a turned screen")
print(string.rep("=", 50))

local function source(path)
    local f = assert(io.open(PLUGIN_DIR .. "/" .. path, "r"))
    local s = f:read("*a")
    f:close()
    return s
end
local dialogs_src = source("koassistant/ui/dialogs.lua")
local viewer_src = source("koassistant/ui/chatgptviewer.lua")

-- ------------------------------------------------------------------ the window list
local function names(stack)
    local out = {}
    for _i, entry in ipairs(stack) do out[#out + 1] = entry.widget.name end
    return table.concat(out, " ")
end
local function withStack(widgets, fn)
    local saved_stack, saved_dirty = UIManager._window_stack, rawget(UIManager, "setDirty")
    local stack, dirtied = {}, 0
    for _i, w in ipairs(widgets) do stack[#stack + 1] = { x = 0, y = 0, widget = w } end
    UIManager._window_stack = stack
    UIManager.setDirty = function() dirtied = dirtied + 1 end
    local ok, err = pcall(fn, stack, function() return dirtied end)
    UIManager._window_stack, UIManager.setDirty = saved_stack, saved_dirty
    if not ok then error(err, 0) end
end

TestRunner:test("a rebuilt chat window goes back under the windows that stood over it", function()
    local reader, chat, reply, keys = { name = "reader" }, { name = "chat" }, { name = "reply" }, { name = "keys" }
    withStack({ reader, chat, reply, keys }, function(stack, dirtied)
        local above = ChatGPTViewer._windowsAbove(chat)
        TestRunner:assertEqual(#above, 2)
        TestRunner:assertTrue(above[1] == reply and above[2] == keys, "bottom to top")
        -- the old window closes, the new one is shown: on top, where KOReader puts it
        table.remove(stack, 2)
        stack[#stack + 1] = { x = 0, y = 0, widget = { name = "chat2" } }
        TestRunner:assertEqual(names(stack), "reader reply keys chat2")
        ChatGPTViewer._settleBelow(above)
        TestRunner:assertEqual(names(stack), "reader chat2 reply keys", "back under them, in their order")
        TestRunner:assertEqual(dirtied(), 1, "and the screen is drawn again in that order")
    end)
end)

TestRunner:test("nothing moves when nothing stood over it, or they are gone, or nothing new is on top", function()
    local reader, chat, reply = { name = "reader" }, { name = "chat" }, { name = "reply" }
    withStack({ reader, chat }, function(stack, dirtied)
        local above = ChatGPTViewer._windowsAbove(chat)
        TestRunner:assertEqual(#above, 0, "the window on top has nothing over it")
        stack[2] = { widget = { name = "chat2" } }
        ChatGPTViewer._settleBelow(above)
        TestRunner:assertEqual(names(stack), "reader chat2")
        TestRunner:assertEqual(dirtied(), 0)
    end)
    withStack({ reader, chat, reply }, function(stack, dirtied)
        local above = ChatGPTViewer._windowsAbove(chat)
        -- the reply box was closed in the meantime
        table.remove(stack, 3)
        table.remove(stack, 2)
        stack[#stack + 1] = { widget = { name = "chat2" } }
        ChatGPTViewer._settleBelow(above)
        TestRunner:assertEqual(names(stack), "reader chat2", "the windows over it are gone: it stays on top")
        TestRunner:assertEqual(dirtied(), 0)
    end)
    withStack({ reader, chat, reply }, function(stack, dirtied)
        local above = ChatGPTViewer._windowsAbove(chat)
        -- no new window was shown (the rebuild did not happen)
        ChatGPTViewer._settleBelow(above)
        TestRunner:assertEqual(names(stack), "reader chat reply")
        TestRunner:assertEqual(dirtied(), 0)
    end)
    TestRunner:assertEqual(#ChatGPTViewer._windowsAbove({ name = "not shown" }), 0)
end)

TestRunner:test("the window keeps the order through its own rebuild", function()
    local body = viewer_src:match("\nfunction ChatGPTViewer:_handleScreenChange%(immediate%)\n(.-)\nend\n")
    TestRunner:assertTrue(body ~= nil, "the handler is where it was")
    local taken, closed = body:find("local above = windowsAbove(self)", 1, true), body:find("UIManager:close(self)", 1, true)
    TestRunner:assertTrue(taken ~= nil and closed ~= nil and taken < closed, "what stands over it is read before it closes")
    TestRunner:assertTrue(body:find("self._recreate_func(state)\n    settleBelow(above)", 1, true) ~= nil,
        "and the rebuilt window is put back right after it is shown")
end)

-- ------------------------------------------------------------------ the broadcast
-- KOReader's UIManager:broadcastEvent: every window is told, and the walk
-- starts over from the top whenever the list changed (a new window appears)
local function broadcast(stack, event, limit)
    local checked, told = {}, 0
    local i = #stack
    while i > 0 do
        local widget = stack[i]
        if not checked[widget] then
            checked[widget] = true
            told = told + 1
            if told > limit then error("the walk does not end: " .. told .. " windows told") end
            if widget[event] then widget[event](widget) end
            i = #stack
        else
            i = i - 1
        end
    end
    return told
end

-- The chat input's own handler, cut from the source
local handler_src = dialogs_src:match("\n(    input_dialog%.onScreenResize = function%(self, dimen%)\n.-\n    end)\n")

TestRunner:test("the chat's input box under a broadcast resize: one rebuild, after the event", function()
    TestRunner:assertTrue(handler_src ~= nil, "the handler is where it was")
    local stack, ticks, rebuilds = {}, {}, 0
    local ui = { nextTick = function(_self, fn) ticks[#ticks + 1] = fn end }
    local makeBox
    makeBox = function()
        local box = { name = "input" }
        local refresh = function()
            -- refreshInputDialog: the box closes and a new one is shown at once
            rebuilds = rebuilds + 1
            for i = #stack, 1, -1 do
                if stack[i] == box then table.remove(stack, i) end
            end
            box._koa_closed = true
            makeBox()
        end
        assert(load("local UIManager, refreshInputDialog, input_dialog = ...\n" .. handler_src, "=dialogs.lua (cut)"))(ui, refresh, box)
        stack[#stack + 1] = box
        return box
    end
    stack[1] = { name = "reader" }
    local first = makeBox()
    local told = broadcast(stack, "onScreenResize", 50)
    TestRunner:assertEqual(told, 2, "the reader and the box, once each")
    TestRunner:assertEqual(rebuilds, 0, "nothing is rebuilt inside the event")
    TestRunner:assertEqual(#ticks, 1, "the rebuild waits for the next tick")
    -- the system sends more than one event for one turn
    broadcast(stack, "onScreenResize", 50)
    TestRunner:assertEqual(#ticks, 1, "a second event asks for no second rebuild")
    ticks[1]()
    TestRunner:assertEqual(rebuilds, 1, "one rebuild")
    TestRunner:assertTrue(stack[#stack] ~= first and stack[#stack].name == "input", "a new box is on top")
    TestRunner:assertEqual(#stack, 2)
end)

TestRunner:test("a box closed before its tick is not rebuilt", function()
    local ticks, rebuilds = {}, 0
    local ui = { nextTick = function(_self, fn) ticks[#ticks + 1] = fn end }
    local box = {}
    assert(load("local UIManager, refreshInputDialog, input_dialog = ...\n" .. handler_src, "=dialogs.lua (cut)"))(
        ui, function() rebuilds = rebuilds + 1 end, box)
    box:onScreenResize()
    box._koa_closed = true  -- what the box's onCloseWidget sets
    ticks[1]()
    TestRunner:assertEqual(rebuilds, 0)
    TestRunner:assertTrue(dialogs_src:find("self_dlg._koa_closed = true", 1, true) ~= nil,
        "the box marks itself closed when it closes")
end)

TestRunner:test("the old way did hang: a box that replaces itself inside the event is told for ever", function()
    -- the control: the handler as it was in every release that had it
    local stack = { { name = "reader" } }
    local makeBox
    makeBox = function()
        local box = { name = "input" }
        box.onScreenResize = function(self)
            for i = #stack, 1, -1 do
                if stack[i] == self then table.remove(stack, i) end
            end
            makeBox()
            return true
        end
        stack[#stack + 1] = box
    end
    makeBox()
    local ok, err = pcall(broadcast, stack, "onScreenResize", 50)
    TestRunner:assertFalse(ok, "the walk never ends")
    TestRunner:assertTrue(tostring(err):find("does not end", 1, true) ~= nil, tostring(err))
end)

-- ------------------------------------------------------------------ the dialogs over the chat window
TestRunner:test("Save Chat, New Tag and the reply box lay themselves out again in place", function()
    for _idx, name in ipairs({ "save_dialog", "tag_input" }) do
        local handler = dialogs_src:match("\n%s*" .. name .. "%.onScreenResize = function%(self, dimen%)\n(.-)\n%s*end\n")
        TestRunner:assertTrue(handler ~= nil and handler:find("self:reinit()", 1, true) ~= nil,
            name .. " asks KOReader's InputDialog to lay itself out again")
        TestRunner:assertTrue(handler:find("UIManager:close", 1, true) == nil and handler:find("scheduleIn", 1, true) == nil,
            name .. " neither closes nor comes back later as a new dialog")
    end
    TestRunner:assertTrue(dialogs_src:find("recreate_save_dialog", 1, true) == nil
        and dialogs_src:find("recreate_tag_dialog", 1, true) == nil, "the come-back-later copies are gone")
    local reply = viewer_src:match("\n  input_dialog%.onScreenResize = function%(dialog%)\n(.-)\n  end\n")
    TestRunner:assertTrue(reply ~= nil and reply:find("dialog:reinit()", 1, true) ~= nil, "the reply box too")
    TestRunner:assertTrue(reply:find("styleReplyBox()", 1, true) ~= nil, "with its own title face and border put back")
end)

-- ------------------------------------------------------------------ the sensor's turn
TestRunner:test("a turn handed to the chat window turns the screen through the app underneath", function()
    -- the screen object the window itself holds (one Lua process runs the whole
    -- suite: another file's stand-in for the device may be the one in the cache)
    local Screen
    for i = 1, 60 do
        local name, value = debug.getupvalue(ChatGPTViewer.onSetRotationMode, i)
        if not name then break end
        if name == "Screen" then Screen = value end
    end
    TestRunner:assertTrue(type(Screen) == "table", "the window reads the screen")
    local saved_mode, saved_live = rawget(Screen, "getRotationMode"), ChatGPTViewer.liveUI
    local mode, asked, changes = 0, {}, 0
    Screen.getRotationMode = function() return mode end
    local function window(with_recreate)
        return setmetatable({
            _recreate_func = with_recreate and function() end or nil,
            _handleScreenChange = function() changes = changes + 1 return true end,
        }, { __index = ChatGPTViewer })
    end
    local ok, err = pcall(function()
        -- the reader underneath: its view turns the screen and lays the page out again
        ChatGPTViewer.liveUI = function()
            return { view = { onSetRotationMode = function(_self, m) asked[#asked + 1] = "view " .. m; mode = m end } }
        end
        TestRunner:assertEqual(window(true):onSetRotationMode(1), true)
        TestRunner:assertEqual(table.concat(asked, ", "), "view 1", "the reader's view is asked to turn the screen")
        TestRunner:assertEqual(changes, 1, "then the window is rebuilt")
        -- the mode the screen already has: nothing to turn, the window still follows
        window(true):onSetRotationMode(1)
        TestRunner:assertEqual(#asked, 1, "no second turn")
        TestRunner:assertEqual(changes, 2)
        -- the file browser underneath
        ChatGPTViewer.liveUI = function()
            return { onSetRotationMode = function(_self, m) asked[#asked + 1] = "browser " .. m; mode = m end }
        end
        window(true):onSetRotationMode(0)
        TestRunner:assertEqual(asked[#asked], "browser 0")
        -- a window that cannot be rebuilt leaves the screen alone
        window(false):onSetRotationMode(1)
        TestRunner:assertEqual(#asked, 2)
    end)
    Screen.getRotationMode, ChatGPTViewer.liveUI = saved_mode, saved_live
    if not ok then error(err, 0) end
end)

TestRunner:test("the names are KOReader's (where the app is installed)", function()
    local base = "/Applications/KOReader.app/Contents/koreader/frontend/"
    local function bundle(path)
        local f = io.open(base .. path, "r")
        if not f then return nil end
        local s = f:read("*a")
        f:close()
        return s
    end
    local input = bundle("ui/widget/inputdialog.lua")
    if not input then
        print("    (skipped: KOReader's frontend is not at " .. base .. ")")
        return
    end
    TestRunner:assertTrue(input:find("function InputDialog:reinit()", 1, true) ~= nil, "InputDialog:reinit")
    TestRunner:assertTrue(bundle("apps/reader/modules/readerview.lua"):find("function ReaderView:onSetRotationMode(mode)", 1, true) ~= nil,
        "ReaderView:onSetRotationMode")
    TestRunner:assertTrue(bundle("apps/filemanager/filemanager.lua"):find("function FileManager:onSetRotationMode(mode)", 1, true) ~= nil,
        "FileManager:onSetRotationMode")
    local ui = bundle("ui/uimanager.lua")
    TestRunner:assertTrue(ui:find("self._window_stack", 1, true) ~= nil, "UIManager's window list")
    TestRunner:assertTrue(ui:find("function UIManager:broadcastEvent(event)", 1, true) ~= nil
        and ui:find("i = #self._window_stack", 1, true) ~= nil, "its broadcast starts over when the list changes")
end)

return TestRunner:summary()
