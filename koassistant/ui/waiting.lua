--[[--
Waits that keep something moving on screen (B709, #126; docs/waits_keep_awake_plan.md).

Some Android e-readers put the processor to sleep about 5 seconds after the
last touch or screen update, even with a page on screen, and KOReader stops
with them until the next touch. A window that redraws keeps such a device
awake: in a reader's log a 9-minute wait stayed awake with only the chat
window's waiting dots moving. So every wait that can run past a few seconds
shows something that moves at this pace, built here once: the dots, the tick,
the waiting line and the waiting message. A wait whose loop is blocked (a
synchronous fetch) cannot move, and waits with no window are left as they are
(the maintainer's ruling of 2026-11-17).
]]

local _ = require("koassistant.core.gettext")
local logger = require("koassistant.core.logger")
local T = require("ffi/util").template

local Waiting = {}

--- The chat window's pace: a redraw every 0.4 s
Waiting.INTERVAL = 0.4
--- The chat window's waiting dots
Waiting.FRAMES = { ".", "..", "...", "..", "." }
--- The widest frame: a corner notice is held at the width it gives
Waiting.WIDEST = "..."

-- Resolved at each call, so the UIManager in use (a test's too) schedules
local function uiManager()
    return require("ui/uimanager")
end

--- A frame source: getNextFrame() cycles through FRAMES, reset() starts over.
function Waiting.dots()
    local i = 1
    return {
        getNextFrame = function()
            local frame = Waiting.FRAMES[i]
            i = i % #Waiting.FRAMES + 1
            return frame
        end,
        reset = function() i = 1 end,
    }
end

--- step() every INTERVAL until the returned stop() is called or step returns
--- false (its window is gone); a step that fails stops the tick.
--- @param step function
--- @return function stop
function Waiting.tick(step)
    local running = true
    local fn
    fn = function()
        if not running then return end
        local ok, keep = pcall(step)
        if not ok then
            running = false
            logger.warn("KOAssistant: a waiting tick stopped:", keep)
            return
        end
        if keep == false then
            running = false
            return
        end
        uiManager():scheduleIn(Waiting.INTERVAL, fn)
    end
    uiManager():scheduleIn(Waiting.INTERVAL, fn)
    return function()
        if not running then return end
        running = false
        uiManager():unschedule(fn)
    end
end

--- The waiting line under a wait's own text: the seconds it has run and the
--- dots (the picture window's line).
--- @param seconds number
--- @param frame string one of FRAMES
--- @return string
function Waiting.line(seconds, frame)
    return T(_("Elapsed: %1 s"), seconds) .. "  " .. frame
end

--- The widget at or below `widget` that shows exactly `text` and can change
--- it. Only the array children are walked, so no field of KOReader's own
--- layout is named (a container's named fields point back up the tree).
--- @return table|nil
function Waiting.findTextWidget(widget, text, depth)
    depth = depth or 0
    if type(widget) ~= "table" or depth > 12 then return nil end
    if widget.text == text and type(widget.setText) == "function" then
        return widget
    end
    for _idx, child in ipairs(widget) do
        local found = Waiting.findTextWidget(child, text, depth + 1)
        if found then return found end
    end
    return nil
end

--- The screen area a tick redraws, read after the paint (UIManager calls a
--- refresh function once the widgets are painted): the corner notice's frame
--- at its held width, else the text widget's own area.
local function tickRegion(widget, text_widget, corner)
    local Geom = require("ui/geometry")
    local frame = corner and widget.frame
    if frame and frame.dimen then
        return Geom:new{ x = frame.dimen.x, y = frame.dimen.y,
            w = frame.width or frame.dimen.w, h = frame.dimen.h }
    end
    local d = text_widget.dimen
    if d then
        return Geom:new{ x = d.x, y = d.y, w = d.w, h = d.h }
    end
end

--- A waiting message that moves from the moment it is shown until it closes;
--- the caller shows and closes it as any KOReader widget. By default
--- KOReader's InfoMessage (centred; a tap closes it and runs its
--- dismiss_callback, as with any InfoMessage) with the waiting line right
--- under its text. With opts.corner, KOReader's TrapWidget (the small corner notice:
--- any tap, key or swipe dismisses it) with the dots after its text, held at
--- the width of its widest frame: its frame paints the background and the
--- border at that width, so a shorter frame leaves no dots behind.
--- @param opts table { text, corner, dismiss_callback, dismissable }
--- @return table widget
function Waiting.message(opts)
    local dots = Waiting.dots()
    local started = os.time()
    local base = opts.text or ""
    local corner = opts.corner == true
    local compose, widget
    if corner then
        compose = function(frame) return base .. "  " .. frame end
        widget = require("ui/widget/trapwidget"):new{
            text = compose(Waiting.WIDEST),
            dismiss_callback = opts.dismiss_callback,
        }
        if widget.frame and widget.frame.getSize then
            widget.frame.width = widget.frame:getSize().w
        end
    else
        compose = function(frame)
            return base .. "\n" .. Waiting.line(os.time() - started, frame)
        end
        widget = require("ui/widget/infomessage"):new{
            text = compose(dots.getNextFrame()),
            dismissable = opts.dismissable,
        }
        widget.dismiss_callback = opts.dismiss_callback
    end
    local text_widget = Waiting.findTextWidget(widget, widget.text)
    if not text_widget then
        logger.dbg("KOAssistant: a waiting message has no text widget to move")
        return widget
    end
    local stop
    local onShow, onCloseWidget = widget.onShow, widget.onCloseWidget
    widget.onShow = function(self, ...)
        if not stop then
            stop = Waiting.tick(function()
                text_widget:setText(compose(dots.getNextFrame()))
                uiManager():setDirty(self, function()
                    -- No area yet, no refresh (a refresh without one is the whole screen)
                    local region = tickRegion(self, text_widget, corner)
                    if region then return "fast", region end
                end)
            end)
        end
        if onShow then return onShow(self, ...) end
    end
    widget.onCloseWidget = function(self, ...)
        if stop then
            stop()
            stop = nil
        end
        if onCloseWidget then return onCloseWidget(self, ...) end
    end
    return widget
end

return Waiting
