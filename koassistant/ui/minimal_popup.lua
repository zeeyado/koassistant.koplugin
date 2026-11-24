--[[--
Minimal response popup ("minimal popup" view mode).

A small window with just the answer: no title bar, no buttons. Tap inside =
hand off to the full viewer (on_expand); tap outside = dismiss. As tall as its
answer up to a cap (CAP of the screen); a longer answer scrolls inside it (a
swipe up or down, or the page keys, which close the popup once there is
nothing more that way). A word or a passage held in the text is its caller's
(on_select): for an answer, what the chat window does with one (a word is
looked up, a passage gets the selection menu).

The box moves as KOReader's own windows do, by a hold and a drag, and a hold
is the box's wherever it lands on no text (holdOwner): on the frame's margin,
in a strip just outside its border, on the white inside the text's area. A
hold on a line of text is the text's, so every selection stays. Lifted where
it began, a hold on the box puts it back where it first stood, and there it
turns the box see-through, or solid again (onBoxLifted: KOReader's own switch
for its windows, which would send a box placed by a selection to the middle
of the screen first).

The text sits as far from the frame's top and bottom as from its sides: the
content starts at the top of its area (no margin of its own above the first
line, see ChatGPTViewer:answerWidget), and under a text that fits the frame
pads only what the fit did not already leave blank there (footPadding).

Two shapes (`style`, features.minimal_popup_style):
- "box" (default): a rounded box next to the highlight via MovableContainer's
  `anchor` when selection geometry is available (EPUB: sboxes are already
  screen coordinates; paging/PDF and geometry-less launches fall back to
  centered). As wide as the chat window, with its text inset, so the popup's
  lines are the lines of the window a tap opens. Deliberately independent of
  KOReader's own "highlight dialog position" setting.
- "panel": a panel at the foot of the screen, from edge to edge under a rule,
  the look of KOReader's footnote popup (KOReader's own FootnoteWidget passes
  no resource folder, so it cannot load the Markdown view's fonts on MuPDF
  1.28: this is the plugin's frame around the same content widget).

An answer that can be kept with the passage carries a small mark (`keep`,
its caller's): a plus until the answer is kept, a tick once it is, a bare
sign inside the frame's foot corner (keepPlace). It takes no room: the frame
is the size it is without the mark, and the sign's strokes lie in the blank
the frame keeps beside and under its text. A tap on it keeps the answer or
takes it back out; a hold opens its caller's choices while the finger still
rests there, as a held button's do, and they hang from the popup's corner
that holds the sign (menuAnchor), outside the frame: the answer stays whole.

What it shows is its caller's: `content(width, height, dialog)` returns the
scrolling widget that shows the answer in a text area that size. For an
answer that is the chat window's own drawing (ChatGPTViewer:answerWidget: the
Markdown view where the window a tap opens would show Markdown, the plain-text
widget where it would show Plain Text), so the popup IS that window's view of
the answer and this module builds no HTML of its own. Without a builder the
popup shows `text` as plain text in KOReader's interface font (the X-Ray
card's popup style).

Consumers: actions registered in the Minimal Popup settings
(features.minimal_popup_actions, Translate and Quick Define by default;
showResponseDialog decides; this module never reads settings), the X-Ray
card, and a kept answer shown again when its passage is tapped (showForNote:
the same popup, with no keep mark and KOReader's own note window behind a tap). "When it fits" mode rides opts.only_if_fits: the caller asks whether the
whole answer fits under the cap (hasOverflow: the laid-out content, so script
density and font size are handled by construction) and falls back to the full
viewer when it does not.
]]

local BD = require("ui/bidi")
local Blitbuffer = require("ffi/blitbuffer")
local BottomContainer = require("ui/widget/container/bottomcontainer")
local CenterContainer = require("ui/widget/container/centercontainer")
local Device = require("device")
local Font = require("ui/font")
local FrameContainer = require("ui/widget/container/framecontainer")
local Geom = require("ui/geometry")
local GestureRange = require("ui/gesturerange")
local InputContainer = require("ui/widget/container/inputcontainer")
local LineWidget = require("ui/widget/linewidget")
local MovableContainer = require("ui/widget/container/movablecontainer")
local OverlapGroup = require("ui/widget/overlapgroup")
local Size = require("ui/size")
local TextWidget = require("ui/widget/textwidget")
local UIManager = require("ui/uimanager")
local VerticalGroup = require("ui/widget/verticalgroup")
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local Screen = Device.screen

local MinimalPopup = InputContainer:extend{
    content = nil,          -- function(width, height, dialog): the scrolling widget that shows the answer
    text = nil,             -- plain text, shown when there is no `content` (markdown already stripped)
    font_size = nil,        -- the content's font size (the fit leaves the last line its leading)
    style = "box",          -- "box" by the selection | "panel" at the foot of the screen
    selection_data = nil,   -- {sboxes, ...} captured at highlight time (read-only!)
    ui = nil,               -- ReaderUI-like (paging check only)
    para_direction_rtl = nil,  -- plain text only; nil = auto-detect per paragraph
    lang = nil,             -- BCP-ish language hint for xtext, optional (plain text only)
    on_expand = nil,        -- tap inside the popup
    on_close = nil,         -- dismissed without expanding
    on_select = nil,        -- function(text, hold_duration, clear_highlight): a word or a passage held in the text
    keep = nil,             -- { kept, toggle = function(set), menu = function(set, close, anchor) }: the mark that keeps the answer
}

-- How tall the text may be, of the screen's height, before it scrolls
MinimalPopup.CAP = 0.45
MinimalPopup.STYLES = { box = true, panel = true }
-- The keep mark: its sign's box and a finger's margin around it, in
-- KOReader's screen units (scaleBySize), and each sign's font size (the tick
-- is the larger glyph of the two: the sizes make them one height)
MinimalPopup.KEEP_SIDE = 22
MinimalPopup.KEEP_MARGIN = 14
MinimalPopup.KEEP_FONT = { plus = 28, tick = 22 }

-- A hold on the box (KOReader's screen units): how far outside the frame's
-- border a hold still takes the box (with the frame's own margin inside it,
-- the border is a handle about 5 mm wide, and the box looks the same), and
-- how near a line of text a finger still counts as on it
MinimalPopup.GRAB = 15
MinimalPopup.LINE_SLACK = 4
-- How much of the page shows through a box made see-through (KOReader's own
-- value for its windows)
MinimalPopup.SEE_THROUGH = 0.7

--- Whose a hold is, pure: "box" (the popup itself: dragged it moves, lifted
--- where it began it is KOReader's own switch, see-through and back) or
--- "text" (the answer's: a word to look up, a passage to select). The box's
--- wherever the finger lands on no text: on the frame's margin, in a strip
--- just outside its border, and on the white inside the text area (after a
--- short line, between paragraphs, under the last line) where the lines'
--- boxes are known. Every selection stays as it was: a hold on a line of
--- text is the text's.
-- @param pos {x, y} a point of the screen
-- @param frame {x, y, w, h} the frame on screen
-- @param text {x, y, w, h} the text's area on screen
-- @param strip number how far outside the frame still counts
-- @param lines table|nil the lines of text in that area, { x0, y0, x1, y1 }
--   each in the area's own coordinates; nil = not known, and every point of
--   the area is the text's
-- @param slack number how near a line still counts as on it
-- @return "box" | "text" | nil (neither: beyond the strip)
function MinimalPopup.holdOwner(pos, frame, text, strip, lines, slack)
    if pos.x < frame.x - strip or pos.x >= frame.x + frame.w + strip
            or pos.y < frame.y - strip or pos.y >= frame.y + frame.h + strip then
        return nil
    end
    local x, y = pos.x - text.x, pos.y - text.y
    if x < 0 or x >= text.w or y < 0 or y >= text.h then return "box" end
    if type(lines) ~= "table" then return "text" end
    for _idx, line in ipairs(lines) do
        if type(line) == "table" and line.x0 and line.y0 and line.x1 and line.y1
                and y >= line.y0 - slack and y < line.y1 + slack
                and x >= line.x0 - slack and x < line.x1 + slack then
            return "text"
        end
    end
    return "box"
end

--- Where the text sits, pure. The box is the chat window's rectangle: its
--- content width and its text inset, so the same text wraps the same way in
--- the popup and in the window a tap opens. The panel is the screen's width.
--- @return table { panel, border, text_w, cap }
function MinimalPopup.geometry(style, screen_w, screen_h, chat_w, inset, border)
    local panel = style == "panel"
    return {
        panel = panel,
        border = panel and 0 or border,
        text_w = (panel and screen_w or chat_w) - 2 * inset,
        cap = math.floor(screen_h * MinimalPopup.CAP),
    }
end

--- The frame's padding under the text, pure. A text that fits ends above the
--- foot of its area (the fit measures ink and leaves the last line its
--- leading): the frame adds only what is missing to the inset the text has on
--- its other sides, and never less than `least`.
function MinimalPopup.footPadding(inset, blank, least)
    return math.max(least, inset - blank)
end

-- What a content widget leaves blank under its last line, in a text area
-- text_h tall: the Markdown view on one page says where its ink ends. Nothing
-- for a text that scrolls (it ends where its page does) and for the plain
-- widget (its area is its lines exactly).
local function blankUnder(widget, text_h)
    if widget.htmlbox_widget and widget.getSinglePageHeight then
        local used = widget:getSinglePageHeight()
        if used then return math.max(0, text_h - used) end
    end
    return 0
end

--- Where the keep mark sits, pure: a bare sign in the frame's foot corner, on
--- the right (the left in a mirrored layout), flush with the frame's inner
--- edge. Its upright stroke then stands in the blank beside the text and its
--- level one in the blank under the last line, so it covers no letter
--- whichever way the text runs; nothing sticks out of the frame, which is
--- placed by the selection exactly as it is without a mark.
-- @param s { side = the sign's box, gap = its distance from the frame's foot, border = the frame's,
--             margin = a finger's margin around the sign }
-- @return table two rectangles in the frame, each { x, y, w, h }: sign = the sign's box, zone = where a touch is the mark's
function MinimalPopup.keepPlace(frame_w, frame_h, s, mirrored)
    local x = mirrored and s.border or (frame_w - s.border - s.side)
    local y = frame_h - s.border - s.gap - s.side
    return {
        sign = { x = x, y = y, w = s.side, h = s.side },
        zone = { x = x - s.margin, y = y - s.margin, w = s.side + 2 * s.margin, h = s.side + 2 * s.margin },
    }
end

-- The mark: a plus until the answer is kept, a tick once it is (the tick of
-- KOReader's own menus). Signs of the interface font: only their strokes are
-- drawn, over whatever the frame shows there
local function keepMark(kept, side)
    return CenterContainer:new{
        dimen = Geom:new{ w = side, h = side },
        TextWidget:new{
            text = kept and "\u{2713}" or "+",
            face = Font:getFace("cfont", kept and MinimalPopup.KEEP_FONT.tick or MinimalPopup.KEEP_FONT.plus),
            bold = true,
        },
    }
end

--- The plain-text content, for a caller with no chat window of its own
function MinimalPopup.plainWidget(text, width, height, dialog, opts)
    opts = opts or {}
    return require("ui/widget/scrolltextwidget"):new{
        text = text,
        face = Font:getFace("x_smallinfofont"),  -- the face the chat viewer renders plain text with
        width = width,
        height = height,
        dialog = dialog,
        para_direction_rtl = opts.para_direction_rtl,
        auto_para_direction = opts.para_direction_rtl == nil,
        lang = opts.lang,
    }
end

function MinimalPopup:buildAnchor()
    if not MovableContainer.ensureAnchor then return nil end -- older KOReader
    local boxes = self.selection_data and self.selection_data.sboxes
    if not boxes or #boxes == 0 then return nil end
    if not self.ui or self.ui.paging then return nil end -- EPUB only for now
    return function()
        local box0, box1 = boxes[1], boxes[#boxes]
        if not (box0 and box0.y and box0.h and box1 and box1.y and box1.h) then return nil end
        if box0.y > box1.y then box0, box1 = box1, box0 end
        -- Stale-coordinates guard (rotation/page turn while the request was in
        -- flight): off-screen boxes fall back to centered.
        if box0.y < 0 or (box1.y + box1.h) > Screen:getHeight() then return nil end
        -- Fresh table, never a live sbox: ensureAnchor writes onto the table
        -- it is given, and selection_data is shared by reference with KOReader
        -- (SKIP_DEEP_COPY). All four fields must be set: ensureAnchor only
        -- nil-defaults missing ones since KOReader v2026.07 -- older releases
        -- crash comparing nil at paint time (#102). x/w chosen so both the
        -- LTR (left = x) and mirrored-layout (left = x + w - content_w) paths
        -- center the popup horizontally.
        -- Padding keeps the popup from abutting the selection.
        local pad = Size.padding.small
        local w = self.frame:getSize().w
        return {
            x = math.floor((Screen:getWidth() - w) / 2),
            w = w,
            y = box0.y - pad,
            h = (box1.y + box1.h) - box0.y + 2 * pad,
        }, true -- prefer below
    end
end

function MinimalPopup:init()
    local screen_w, screen_h = Screen:getWidth(), Screen:getHeight()
    local Viewer = require("koassistant.ui.chatgptviewer")
    local inset = Viewer.text_padding + Viewer.text_margin
    local g = MinimalPopup.geometry(self.style, screen_w, screen_h,
        require("koassistant.ui.constants").CHAT_WIDTH(), inset, Size.border.window)
    local build = self.content or function(w, h, dialog)
        return MinimalPopup.plainWidget(self.text, w, h, dialog, self)
    end
    -- As tall as the text needs, up to the cap: measured laid out, the way the
    -- fitted windows are (two layouts either way: a text that fits at its own
    -- height, a longer one at what its first page holds)
    self.cap = g.cap
    self.scroll_w, self.text_h = Viewer.fitContent(function(h) return build(g.text_w, h, self) end,
        Screen:scaleBySize(10), g.cap, g.cap, self.font_size, true)
    -- A tap inside opens the full window, so the content widget's own tap (a
    -- scroll step by the half of the screen it lands in) stands down. On the
    -- instance: the switch for it is newer than some KOReader releases
    self.scroll_w.onTapScrollText = function() return false end

    local pad_bottom = MinimalPopup.footPadding(inset, blankUnder(self.scroll_w, self.text_h), Size.padding.small)
    -- The keep mark's sizes, when the answer can be kept. Under a text that
    -- scrolls the foot is as tall as the sign, so the scroll bar ends above it
    local sign
    if self.keep then
        sign = {
            side = Screen:scaleBySize(MinimalPopup.KEEP_SIDE), gap = Screen:scaleBySize(1),
            border = g.border, margin = Screen:scaleBySize(MinimalPopup.KEEP_MARGIN),
        }
        if self:hasOverflow() then
            pad_bottom = math.max(pad_bottom, sign.gap + sign.side)
        end
    end
    self.frame = FrameContainer:new{
        radius = not g.panel and Size.radius.window or nil,
        bordersize = g.border,
        padding = inset,
        padding_bottom = pad_bottom,
        margin = 0,
        background = Blitbuffer.COLOR_WHITE,
        self.scroll_w,
    }
    local whole = Geom:new{ x = 0, y = 0, w = screen_w, h = screen_h }
    -- The mark is drawn over the frame's foot corner
    local framed = self.frame
    if sign then
        -- by the frame's own measure (a content widget is not always exactly
        -- as tall as the area it was asked to fill)
        local size = self.frame:getSize()
        local place = MinimalPopup.keepPlace(size.w, size.h, sign, BD.mirroredUILayout() == true)
        self.keep_place = place
        self.kept = self.keep.kept == true
        self.keep_mark = keepMark(self.kept, place.sign.w)
        self.keep_holder = WidgetContainer:new{
            dimen = Geom:new{ w = place.sign.w, h = place.sign.h },
            self.keep_mark,
        }
        self.keep_holder.overlap_offset = { place.sign.x, place.sign.y }
        framed = OverlapGroup:new{
            allow_mirroring = false,
            dimen = Geom:new{ w = size.w, h = size.h },
            self.frame,
            self.keep_holder,
        }
    end
    if g.panel then
        self.rule_h = Size.line.thick
        self[1] = BottomContainer:new{
            dimen = whole:copy(),
            VerticalGroup:new{
                align = "left",
                LineWidget:new{
                    dimen = Geom:new{ w = screen_w, h = self.rule_h },
                    background = Blitbuffer.COLOR_BLACK,
                },
                framed,
            },
        }
    else
        self.movable = MovableContainer:new{
            anchor = self:buildAnchor(),
            -- A hold is this popup's to hand out (onPopupHold): the text's
            -- where it lands on text, else the box's
            ignore_events = { "hold", "hold_pan", "hold_release" },
            framed,
        }
        self[1] = WidgetContainer:new{
            align = "center",
            dimen = whole:copy(),
            self.movable,
        }
    end
    if Device:isTouchDevice() then
        self.ges_events = {
            Tap = { GestureRange:new{ ges = "tap", range = whole } },
        }
        if g.panel then
            -- as KOReader's footnote popup closes: a swipe down or back. One
            -- that starts on the text is the content's (it scrolls)
            self.ges_events.Swipe = { GestureRange:new{ ges = "swipe", range = whole } }
        end
        if self.on_select or self.keep or self.movable then
            -- A hold is this popup's to hand out (onPopupHold): the keep
            -- mark's when it starts on the mark, the box's where it lands on
            -- no text, else the text's (the content widget selects, the chat
            -- window's wiring; the release hands it this callback)
            self.ges_events.PopupHold = { GestureRange:new{ ges = "hold", range = whole } }
            self.ges_events.PopupHoldPan = { GestureRange:new{ ges = "hold_pan", range = whole,
                rate = Screen.low_pan_rate and 5.0 or 30.0 } }
            self.ges_events.PopupHoldRelease = {
                GestureRange:new{ ges = "hold_release", range = whole },
                args = function(text, hold_duration)
                    if self.on_select then
                        self.on_select(text, hold_duration, function() self:clearHighlight() end)
                    end
                end,
            }
        end
    end
    if Device:hasKeys() then
        -- Page-turn buttons dismiss (device 2026-08-13: the reader pressing
        -- next-page is moving on), once there is nothing more that way: the
        -- content widget gets the key first and scrolls while it can. The
        -- press is CONSUMED either way (the next one turns the page), matching
        -- how modals eat their dismissing tap. Back dismisses too.
        self.key_events.Close = {
            { Device.input.group.PgFwd },
            { Device.input.group.PgBack },
            { Device.input.group.Back },
        }
    end
end

--- Is the answer taller than the cap (it scrolls)? Read off the laid-out
--- content: the HTML view's page count, the plain widget's lines. Language-
--- and font-agnostic by construction. Defensive nil-checks in case a future
--- KOReader renames the internals (then: never overflows, so the popup is
--- always shown, as in "Always" mode: degraded but not broken).
function MinimalPopup:hasOverflow()
    local w = self.scroll_w
    if not w then return false end
    if w.htmlbox_widget then
        return (w.htmlbox_widget.page_count or 1) > 1
    end
    local tw = w.text_widget
    if tw and tw.getAllLineCount and w.getLineHeight and self.text_h then
        return tw:getAllLineCount() * w:getLineHeight() > self.text_h
    end
    return false
end

--- Release what the layout made, for a popup that was built and is not shown
function MinimalPopup:release()
    local w = self.scroll_w
    if not w then return end
    if w.htmlbox_widget then
        if w.htmlbox_widget.free then w.htmlbox_widget:free() end
    elseif w.text_widget and w.text_widget.free then
        w.text_widget:free(true)
    end
end

--- The popup's own rectangle on screen (after a paint)
function MinimalPopup:region()
    if self.movable then return self.movable.dimen end
    local d = self.frame.dimen
    if not d then return nil end
    local above = self.rule_h or 0
    return Geom:new{ x = d.x, y = d.y - above, w = d.w, h = d.h + above }
end

-- A rectangle of the frame (keepPlace's), where it was painted
local function onScreen(frame, r)
    local d = frame.dimen
    if not (d and d.x and r) then return nil end
    return Geom:new{ x = d.x + r.x, y = d.y + r.y, w = r.w, h = r.h }
end

--- Whether a point is on the keep mark (the sign and a finger's margin around it)
function MinimalPopup:onKeepMark(pos)
    local z = pos and self.keep_place and onScreen(self.frame, self.keep_place.zone)
    if not z then return false end
    return pos.x >= z.x and pos.x <= z.x + z.w and pos.y >= z.y and pos.y <= z.y + z.h
end

--- Where the mark's choices open, pure: the rectangle to hand KOReader as a
--- window's anchor (MovableContainer puts a window's near edge on its anchor's,
--- under the anchor where there is room, else over it). The choices hang from
--- the popup's corner that holds the sign: their far edge on the popup's, under
--- the popup, or over it when no room is left under, so nothing of the answer
--- is covered while the reader picks what the note holds. A popup too tall for
--- either gets them right at the sign.
-- @param popup, sign rectangles on screen { x, y, w, h }
-- @param menu_w, menu_h the choices' own size
-- @return table { x, y, w, h }: as wide as the choices, so the window's near
--   edge lands on x whichever way the interface runs
function MinimalPopup.menuAnchor(popup, sign, menu_w, menu_h, screen_h, mirrored)
    local span = sign
    if popup.y + popup.h + menu_h <= screen_h or popup.y - menu_h >= 0 then span = popup end
    return {
        x = mirrored and popup.x or (popup.x + popup.w - menu_w),
        y = span.y,
        w = menu_w,
        h = span.h,
    }
end

--- KOReader's anchor for a window that belongs to the mark (its choices): a
--- function, called with that window once its size is known (the chat
--- window's picker hands it over). A new rectangle at every call
--- (MovableContainer writes on the one it is given); `true` = under the
--- anchor where there is room.
function MinimalPopup:keepAnchor()
    return function(dialog)
        local sign = self.keep_place and onScreen(self.frame, self.keep_place.sign)
        if not sign then return nil end
        local popup = self:region()
        local size = dialog and dialog.movable and dialog.movable.dimen
        if not (popup and popup.x and size and size.w and size.h) then return sign, true end
        return Geom:new(MinimalPopup.menuAnchor(popup, sign, size.w, size.h, Screen:getHeight(),
            BD.mirroredUILayout() == true)), true
    end
end

--- Show the mark as kept or not (its caller says which, after a save or a removal)
function MinimalPopup:setKept(kept)
    kept = kept == true
    if not self.keep_holder or self.kept == kept then return end
    self.kept = kept
    self.keep_mark = keepMark(kept, self.keep_place.sign.w)
    self.keep_holder[1] = self.keep_mark
    -- the popup is drawn again (the sign has no ground of its own to cover
    -- the old one), the screen refreshed where the sign is
    UIManager:setDirty(self, function()
        return "ui", onScreen(self.frame, self.keep_place.sign) or self:region()
    end)
end

function MinimalPopup:onTap(_arg, ges)
    if self.keep and self:onKeepMark(ges.pos) then
        self.keep.toggle(function(kept) self:setKept(kept) end)
        return true
    end
    if self.frame.dimen and ges.pos:intersectWith(self.frame.dimen) then
        UIManager:close(self)
        if self.on_expand then self.on_expand() end
    else
        UIManager:close(self)
        if self.on_close then self.on_close() end
    end
    return true
end

function MinimalPopup:onSwipe(_arg, ges)
    local direction = BD.flipDirectionIfMirroredUILayout(ges.direction)
    if direction == "south" or direction == "east" then
        return self:onClose()
    end
    return false
end

-- A hold, handed out. On the keep mark it is the mark's: its choices open at
-- once, while the finger still rests there (the window they open in gets the
-- release). Anywhere else it is the text's, under the names the content
-- widget knows (it comes first, then the handlers below)
local function toText(self, name, arg, ges)
    return self:handleEvent(require("ui/event"):new(name, arg, ges))
end

-- The lines of text on the page the answer shows, as boxes in the text
-- area's own coordinates: what tells a hold on text from a hold on white.
-- Read once a page from the page engine (KOReader's own text widget reads the
-- same boxes for a selection). nil in the Plain Text view, whose widget has
-- none to give: every point of its area is then the text's.
function MinimalPopup:textLines()
    local inner = self.scroll_w and self.scroll_w.htmlbox_widget
    if not (inner and inner.document and inner.page_number) then return nil end
    self.lines_of = self.lines_of or {}
    local lines = self.lines_of[inner.page_number]
    if lines == nil then
        local ok, got = pcall(function()
            local page = inner.document:openPage(inner.page_number)
            local boxes = page:getPageText()
            page:close()
            return boxes
        end)
        lines = ok and type(got) == "table" and got or false
        self.lines_of[inner.page_number] = lines
    end
    return lines or nil
end

-- A gesture as the box is handed it: the finger's place moved by `by`. A hold
-- that began in the strip outside the border is handed over as one that
-- began on the border (KOReader's movable container takes a hold that starts
-- on it), and every later point moves the same way, so the box travels
-- exactly as far as the finger did.
local function shifted(ges, by)
    local copy = {}
    for k, v in pairs(ges) do copy[k] = v end
    copy.pos = Geom:new{ x = ges.pos.x + by.x, y = ges.pos.y + by.y, w = 0, h = 0 }
    return copy
end

-- Where the box first stood (the place its selection gave it is an offset
-- of KOReader's container, set at its first paint): what a hold lifted in
-- place goes back to
function MinimalPopup:paintTo(bb, x, y)
    InputContainer.paintTo(self, bb, x, y)
    if self.movable and not self.home then
        local at = self.movable:getMovedOffset()
        self.home = { x = at.x, y = at.y }
    end
end

--- A hold on the box lifted where it began: the box goes back to where it
--- first stood; there, it turns see-through, and solid again at the next
function MinimalPopup:onBoxLifted()
    local movable = self.movable
    local before = movable.dimen and movable.dimen:copy()
    local at, home = movable:getMovedOffset(), self.home
    if home and (at.x ~= home.x or at.y ~= home.y) then
        movable:setMovedOffset(Geom:new{ x = home.x, y = home.y })
    elseif movable.alpha == nil then
        movable.alpha = MinimalPopup.SEE_THROUGH
    else
        movable.alpha = nil
    end
    -- everything between the old place and the new is drawn again, as
    -- KOReader's container does after a move
    UIManager:setDirty("all", function()
        local now = movable.dimen
        return "ui", before and now and before:combine(now) or now
    end)
    return true
end

function MinimalPopup:onPopupHold(arg, ges)
    self.keep_held = self.keep ~= nil and self:onKeepMark(ges.pos)
    if self.keep_held then
        self.keep.menu(function(kept) self:setKept(kept) end, function() self:onClose() end, self:keepAnchor())
        return true
    end
    self.box_held = nil
    local frame = self.movable and self.frame.dimen
    if frame then
        local strip = Screen:scaleBySize(MinimalPopup.GRAB)
        local owner
        if self.on_select or self.keep then
            local inner = self.scroll_w.htmlbox_widget or self.scroll_w.text_widget
            local area = inner and inner.dimen and inner.dimen.x and inner.dimen or self.scroll_w.dimen
            owner = area and MinimalPopup.holdOwner(ges.pos, frame, area, strip, self:textLines(),
                Screen:scaleBySize(MinimalPopup.LINE_SLACK))
        else
            -- a popup with no chat window behind it (the X-Ray card's):
            -- nothing in it takes a selection, the whole box is the box's
            owner = MinimalPopup.holdOwner(ges.pos, frame, { x = 0, y = 0, w = 0, h = 0 }, strip)
        end
        if owner == "box" then
            -- (a point is on a rectangle for KOReader past its left and top
            -- edges, not on them)
            self.box_held = {
                x = math.max(frame.x + 1, math.min(ges.pos.x, frame.x + frame.w - 1)) - ges.pos.x,
                y = math.max(frame.y + 1, math.min(ges.pos.y, frame.y + frame.h - 1)) - ges.pos.y,
                from = { x = ges.pos.x, y = ges.pos.y },
            }
            return self.movable:onMovableHold(arg, shifted(ges, self.box_held))
        end
    end
    return toText(self, "HoldStartText", arg, ges)
end

function MinimalPopup:onPopupHoldPan(arg, ges)
    if self.keep_held then return true end
    if self.box_held then return self.movable:onMovableHoldPan(arg, shifted(ges, self.box_held)) end
    return toText(self, "HoldPanText", arg, ges)
end

function MinimalPopup:onPopupHoldRelease(arg, ges)
    if self.keep_held then
        self.keep_held = false
        return true
    end
    if self.box_held then
        local held = self.box_held
        self.box_held = nil
        local least = self.movable.move_threshold or Screen:scaleBySize(5)
        if math.abs(ges.pos.x - held.from.x) < least and math.abs(ges.pos.y - held.from.y) < least then
            -- lifted where it began: the box's own switch, not KOReader's
            -- (whose container is told its hold is over)
            if self.movable.resetEventState then self.movable:resetEventState() end
            return self:onBoxLifted()
        end
        return self.movable:onMovableHoldRelease(arg, shifted(ges, held))
    end
    return toText(self, "HoldReleaseText", arg, ges)
end

-- A hold the text did not take and the test above could not place (a view
-- whose lines are not known): the box's own
function MinimalPopup:onHoldStartText(arg, ges)
    return self.movable and self.movable:onMovableHold(arg, ges) or false
end

function MinimalPopup:onHoldPanText(arg, ges)
    return self.movable and self.movable:onMovableHoldPan(arg, ges) or false
end

function MinimalPopup:onHoldReleaseText(arg, ges)
    return self.movable and self.movable:onMovableHoldRelease(arg, ges) or false
end

--- Take a selection's highlight off the text
function MinimalPopup:clearHighlight()
    local w = self.scroll_w
    local inner = w and (w.htmlbox_widget or w.text_widget)
    if inner and inner.clearHighlight and inner:clearHighlight() and inner.redrawHighlight then
        inner:redrawHighlight()
    end
end

function MinimalPopup:onClose()
    UIManager:close(self)
    if self.on_close then self.on_close() end
    return true
end

function MinimalPopup:onShow()
    UIManager:setDirty(self, function()
        return "ui", self:region()
    end)
    return true
end

function MinimalPopup:onCloseWidget()
    UIManager:setDirty(nil, function()
        return "partial", self:region()
    end)
end

--- Convenience for the response flow: pull the latest assistant message out of
-- a MessageHistory and show it.
-- @param opts { history, viewer, style, selection_data, ui, only_if_fits,
--               on_expand, on_close, kept, auto; without a viewer also
--               rtl_language, features, is_dictionary; text = the answer
--               itself, for a caller that has no history (showForNote) }
--        viewer: the chat window a tap opens (built, not shown). The popup
--        shows the answer the way that window would (answerWidget): its view
--        mode, font, size, alignment and direction; a word or a passage held
--        in it goes to that window's own handler (handleTextSelection).
--        A viewer whose answer can be kept as a note (canKeepNote) gives the
--        popup its keep mark: a tap is that window's Save to Note or takes
--        the answer back out, a hold its choices. kept: what an automatic
--        save returned (the answer arrives kept). auto: the caller's switch
--        for saving this action's answers automatically, a row under the
--        hold's choices: { text = function() label, flip = function() -> on }.
--        style: "box" (default) or "panel".
--        only_if_fits: "When it fits" mode: build the popup, and if the whole
--        answer does not fit under the cap, discard it and return false so
--        the caller opens the full viewer instead.
--        Without a viewer (a caller that has none) the answer is shown as
--        plain text through the viewer's text-mode steps: rtl_language = the
--        language the response renders in (nil = auto-detect direction per
--        paragraph), features = the request's (strip_markdown_in_text_mode),
--        is_dictionary = dict-family launch (gates the IPA bidi reorder).
-- @return boolean shown (false = nothing to show / does not fit; caller
--         should fall back to the full viewer)
function MinimalPopup.showForResponse(opts)
    opts = opts or {}
    local msgs = opts.history and opts.history.getMessages and opts.history:getMessages()
    local text = opts.text
    if msgs and not text then
        for i = #msgs, 1, -1 do
            local m = msgs[i]
            if m.role == "assistant" and m.content and m.content ~= "" then
                text = m.content
                break
            end
        end
    end
    if not text or not text:find("%S") then return false end
    local spec = {
        style = MinimalPopup.STYLES[opts.style] and opts.style or "box",
        selection_data = opts.selection_data,
        ui = opts.ui,
        on_expand = opts.on_expand,
        on_close = opts.on_close,
    }
    local viewer = opts.viewer
    if viewer and viewer.answerWidget then
        spec.content = function(w, h, dialog) return viewer:answerWidget(text, w, h, dialog) end
        spec.font_size = viewer.markdown_font_size
        if viewer.handleTextSelection then
            -- what that window does with a held word or passage, here
            spec.on_select = function(selected, hold_duration, clear_highlight)
                viewer:handleTextSelection(selected, hold_duration, nil, nil, nil,
                    { clear_highlight = clear_highlight })
            end
        end
        if viewer.canKeepNote and viewer:canKeepNote() then
            -- that window's Save to Note, on the popup's mark. `kept` = the
            -- save this answer is kept by, while it is
            local kept = opts.kept
            local function save(set, pick, extra, close, anchor)
                viewer:saveToNote(pick, {
                    popup = true,
                    extra = extra,
                    before_edit = close,
                    anchor = anchor,
                    on_saved = function(saved)
                        kept = saved
                        set(true)
                    end,
                })
            end
            spec.keep = {
                kept = kept ~= nil,
                toggle = function(set)
                    if not kept then return save(set, false) end
                    if viewer:dropNote(kept) then kept = nil end
                    set(kept ~= nil)
                end,
                menu = function(set, close, anchor)
                    local extra
                    if opts.auto then
                        -- a setting, under the double line: this action's
                        -- answers saved automatically from now on, this one too
                        extra = { { separator = true }, {
                            text = opts.auto.text(),
                            callback = function()
                                if opts.auto.flip() and not kept then save(set, false) end
                            end,
                        } }
                    end
                    save(set, true, extra, close, anchor)
                end,
            }
        end
    else
        local para_direction_rtl = nil
        if opts.rtl_language then
            local ok, Languages = pcall(require, "koassistant.core.languages")
            if ok and Languages and Languages.isRTL and Languages.isRTL(opts.rtl_language) then
                para_direction_rtl = true
            end
        end
        -- The chat viewer's text-mode steps, in its order: the direction (the
        -- language's, else the answer's dominant one), stripMarkdown
        -- (strip_markdown_in_text_mode, default on), the IPA reorder under a
        -- right-to-left base for the dictionary family
        local f = opts.features
        local ok_v, Viewer = pcall(require, "koassistant.ui.chatgptviewer")
        if ok_v and Viewer then
            if para_direction_rtl == nil and not opts.rtl_language
                    and Viewer.hasDominantRTL and Viewer.hasDominantRTL(text) then
                para_direction_rtl = true
            end
            local strip = not f or f.strip_markdown_in_text_mode ~= false
            if strip and Viewer.stripMarkdown then
                text = Viewer.stripMarkdown(text, para_direction_rtl)
            end
            if opts.is_dictionary and para_direction_rtl and Viewer.fixIPABidi then
                text = Viewer.fixIPABidi(text)
            end
        end
        -- Trailing whitespace becomes a visible blank bottom line (and counts
        -- against the fit test): trim it whatever path produced the text
        spec.text = (text:gsub("%s+$", ""))
        spec.para_direction_rtl = para_direction_rtl
    end
    local popup = MinimalPopup:new(spec)
    if opts.only_if_fits and popup:hasOverflow() then
        popup:release()  -- constructed but never shown
        return false
    end
    UIManager:show(popup)
    return true
end

--- The one kind of window a note's pieces belong to, pure: the kind they all
--- share, else "chat" (a translation and an explanation kept on one passage)
function MinimalPopup.noteKind(parts)
    local kind = parts[1] and parts[1].kind or "chat"
    for _idx, part in ipairs(parts) do
        if part.kind ~= kind then return "chat" end
    end
    return kind
end

--- A kept answer shown again: the note of a highlighted passage, when its
--- saved answers came from actions that show in this popup
--- (HighlightNote.popupParts decides; its caller is the tap on the passage).
--- The popup the answer came in when it was new: the drawing of a chat
--- window of the note's kind (a translate window keeps a translation's lines
--- apart, a dictionary window follows Text Mode for Dictionary and the
--- dictionary language), built for this and never shown, so a word or a
--- passage held in the text is that window's too. The note is shown as it
--- is now, what the reader has written in it since included. No keep mark:
--- the answer is kept, and its note is the reader's to change in KOReader's
--- own window, which a tap inside opens (on_expand).
-- @param opts { parts = the note's saved answers on record (HighlightNote.piecesOf: each with its kind,
--               and with from and text where it still stands as saved); note = the note's text as it is now
--               (without it the pieces' texts are shown one under the other); features = the reader's settings;
--               plugin, ui = the reader; boxes = the highlight's rectangles on screen; on_expand }
-- @return boolean shown (false = it does not fit under "When it fits": KOReader's window is the caller's to open)
function MinimalPopup.showForNote(opts)
    local parts = opts.parts
    if type(parts) ~= "table" or #parts == 0 then return false end
    local features = opts.features or {}
    local kind = MinimalPopup.noteKind(parts)
    local Viewer = require("koassistant.ui.chatgptviewer")
    -- The note's text as that window draws it. In a note of several kinds a
    -- translation is a guest in a Markdown view, which reads one line break
    -- as a space: its lines are told apart first, as its own window does
    local markdown = features.render_markdown ~= false
    local function drawn(part)
        if kind == "chat" and part.kind == "translate" and markdown and Viewer._lineParagraphs then
            return Viewer._lineParagraphs(part.text)
        end
        return part.text
    end
    local text
    if type(opts.note) == "string" then
        -- The note as it is NOW: each answer that still stands as it was
        -- saved, drawn by its kind, and around them whatever the reader has
        -- written since (or in place of an answer), as they wrote it
        local out, at = {}, 1
        for _idx, part in ipairs(parts) do
            if part.text and type(part.from) == "number" and part.from >= at then
                out[#out + 1] = opts.note:sub(at, part.from - 1)
                out[#out + 1] = drawn(part)
                at = part.from + #part.text
            end
        end
        out[#out + 1] = opts.note:sub(at)
        text = table.concat(out)
    else
        -- a caller with the pieces alone: one under the other
        local pieces = {}
        for i, part in ipairs(parts) do pieces[i] = part.text and drawn(part) or "" end
        text = table.concat(pieces, "\n\n")
    end
    -- A copy of the settings for that window: it reads its view from them,
    -- and the marks of the last request have no business on a note
    local f = {}
    for k, v in pairs(features) do f[k] = v end
    f.compact_view, f.dictionary_view, f.translate_view, f.minimal_buttons = nil, nil, nil, nil
    f.page_printed_lines, f.is_full_page_translate = nil, nil
    local viewer = Viewer:new{
        title = "",
        text = text,
        configuration = { features = f, document_path = opts.ui and opts.ui.document and opts.ui.document.file },
        compact_view = kind == "dictionary" or nil,
        translate_view = kind == "translate" or nil,
        _plugin = opts.plugin,
        _ui = opts.ui,
    }
    -- That window is never shown: what its own layout made is let go once
    -- the popup is done with it (the popup's content is a widget of its own)
    local function release()
        if viewer.free then pcall(viewer.free, viewer) end
    end
    local shown = MinimalPopup.showForResponse({
        text = text,
        viewer = viewer,
        style = features.minimal_popup_style,
        selection_data = opts.boxes and { sboxes = opts.boxes } or nil,
        ui = opts.ui,
        only_if_fits = (features.minimal_popup_mode or "short") == "short",
        on_expand = function()
            release()
            if opts.on_expand then opts.on_expand() end
        end,
        on_close = release,
    })
    if not shown then release() end
    return shown
end

return MinimalPopup
