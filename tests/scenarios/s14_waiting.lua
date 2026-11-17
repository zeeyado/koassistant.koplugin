--[[
Waits that keep moving (B709, #126), through KOReader's real widgets. Some
Android e-readers put the processor to sleep about 5 s after the last screen
update, even with a page on screen, and a wait whose window stood still
waited for the next tap (a reader's log, 2026-11-17).

What must hold:
- the waiting message is KOReader's InfoMessage: its text box is found, the
  waiting line under its text moves at each tick (0.4 s), each tick is a
  "fast" refresh of the text box's own area (what the chat window's dots use,
  and what kept the device awake in the log), and the close stops it;
- the corner notice is KOReader's TrapWidget, held at the width of its widest
  frame: when the dots grow shorter nothing of the longer ones stays on the
  screen (the control without the held width shows that they would);
- the stream window's pause dots are not here: the replay in
  tests/unit/test_stream_ratelimit_marker.lua drives the real loop.
]]
local S = dofile(os.getenv("KOA_PLUGIN") .. "/tests/scenarios/boot.lua")
local UIManager = require("ui/uimanager")
local Blitbuffer = require("ffi/blitbuffer")
local Waiting = require("koassistant.ui.waiting")
local Screen = S.Screen

local refreshes = {}
local real_refresh = UIManager._refresh
UIManager._refresh = function(self, mode, region, dither)
    refreshes[#refreshes + 1] = { mode = mode, region = region }
    return real_refresh(self, mode, region, dither)
end

--- Run what is due now (a tick of the dots) and paint it
local function tick(n)
    for _i = 1, n or 1 do
        S.settle(1)
        UIManager:forceRePaint()
    end
end

local function blank()
    Screen.bb:fill(Blitbuffer.COLOR_WHITE)
end

--- Dark pixels in a rectangle of the screen
local function dark(x0, y0, x1, y1)
    local n = 0
    for x = math.max(0, x0), math.min(Screen.bb:getWidth() - 1, x1) do
        for y = math.max(0, y0), math.min(Screen.bb:getHeight() - 1, y1) do
            if Screen.bb:getPixel(x, y):getColor8().a < 128 then n = n + 1 end
        end
    end
    return n
end

-- 1. The waiting message
blank()
local BASE = "Gemini: gemini-3.5-flash-lite\nExplain\n\nLoading..."
-- The waiting line in whatever language the run is in (an earlier scenario
-- may leave the interface translated): one of the module's own lines
local function isWaitingLine(text)
    if type(text) ~= "string" or text:sub(1, #BASE + 1) ~= BASE .. "\n" then return false end
    local rest = text:sub(#BASE + 2)
    for n = 0, 60 do
        for _idx, frame in ipairs(Waiting.FRAMES) do
            if rest == Waiting.line(n, frame) then return true end
        end
    end
    return false
end
local msg = Waiting.message{ text = BASE }
local box = Waiting.findTextWidget(msg, msg.text)
S.check(box ~= nil and type(box.setText) == "function", "the InfoMessage's text box is found through its children")
UIManager:show(msg)
UIManager:forceRePaint()
local first = box and box.text
refreshes = {}
tick(3)
S.check(box ~= nil and box.text ~= first and isWaitingLine(first) and isWaitingLine(box.text),
    "the waiting line moved under the text: " .. tostring(box and box.text:gsub("\n", " / ")))
local fast_on_box = 0
for _idx, r in ipairs(refreshes) do
    if r.mode == "fast" and r.region and box and r.region.x == box.dimen.x and r.region.y == box.dimen.y
            and r.region.w == box.dimen.w and r.region.h == box.dimen.h then
        fast_on_box = fast_on_box + 1
    end
end
S.check(fast_on_box >= 2, "each tick is a fast refresh of the text box's own area (" .. fast_on_box .. " of 3)")
S.shot("message")
UIManager:close(msg)
S.settle(1)
refreshes = {}
tick(3)
local after_close = 0
for _idx, r in ipairs(refreshes) do
    if r.mode == "fast" then after_close = after_close + 1 end
end
S.check(after_close == 0, "the close stops the dots")

-- 2. The corner notice, and the control without the held width
local function cornerLeftovers(hold)
    blank()
    local trap = Waiting.message{ text = "Explaining", corner = true }
    local frame = trap.frame
    local widest_w = frame:getSize().w  -- built on the widest frame
    if not hold then frame.width = nil end
    UIManager:show(trap)
    UIManager:forceRePaint()
    tick(1)  -- the first frame: one dot, the shortest
    local textw = frame[1]
    local d = frame.dimen
    local left = d.x + frame.margin + frame.bordersize + (frame.padding_left or frame.padding or 0)
    -- From the end of the shorter text to just inside where the widest
    -- frame's right border was: the longer dots stood there
    local x0 = left + textw:getSize().w + 2
    local x1 = d.x + widest_w - frame.bordersize - 2
    local n = dark(x0, d.y + frame.bordersize + 1, x1, d.y + d.h - frame.bordersize - 2)
    local width, shown = frame.width, textw.text
    return trap, n, width, shown
end

local trap, held_dark, width, shown = cornerLeftovers(true)
S.check(width ~= nil and width > 0, "the corner notice is held at its widest width (" .. tostring(width) .. " px)")
S.check(shown == "Explaining  .", "the dots after its text, the shortest frame now: " .. tostring(shown))
S.shot("corner")
UIManager:close(trap)
S.settle(1)
local bare, bare_dark = cornerLeftovers(false)
UIManager:close(bare)
S.settle(1)
S.check(bare_dark > 0, "control: without the held width the longer dots stay (" .. bare_dark .. " dark pixels)")
S.check(held_dark == 0, "held, nothing of the longer dots stays (" .. held_dark .. " dark pixels right of the text)")

UIManager._refresh = real_refresh
S.finish()
