--[[--
Minimal response popup ("minimal popup" view mode).

A small window with just the answer: no title bar, no buttons. Tap inside =
hand off to the full viewer (on_expand); tap outside = dismiss. As tall as its
answer up to a cap (CAP of the screen); a longer answer scrolls inside it (a
swipe up or down, or the page keys, which close the popup once there is
nothing more that way). A word or a passage held in the text is its caller's
(on_select): for an answer, what the chat window does with one (a word is
looked up, a passage gets the selection menu).

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
showResponseDialog decides; this module never reads settings) and the X-Ray
card. "When it fits" mode rides opts.only_if_fits: the caller asks whether the
whole answer fits under the cap (hasOverflow: the laid-out content, so script
density and font size are handled by construction) and falls back to the full
viewer when it does not.
]]

local BD = require("ui/bidi")
local Blitbuffer = require("ffi/blitbuffer")
local BottomContainer = require("ui/widget/container/bottomcontainer")
local Device = require("device")
local Font = require("ui/font")
local FrameContainer = require("ui/widget/container/framecontainer")
local Geom = require("ui/geometry")
local GestureRange = require("ui/gesturerange")
local InputContainer = require("ui/widget/container/inputcontainer")
local LineWidget = require("ui/widget/linewidget")
local MovableContainer = require("ui/widget/container/movablecontainer")
local Size = require("ui/size")
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
}

-- How tall the text may be, of the screen's height, before it scrolls
MinimalPopup.CAP = 0.45
MinimalPopup.STYLES = { box = true, panel = true }

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

    self.frame = FrameContainer:new{
        radius = not g.panel and Size.radius.window or nil,
        bordersize = g.border,
        padding = inset,
        padding_bottom = MinimalPopup.footPadding(inset, blankUnder(self.scroll_w, self.text_h), Size.padding.small),
        margin = 0,
        background = Blitbuffer.COLOR_WHITE,
        self.scroll_w,
    }
    local whole = Geom:new{ x = 0, y = 0, w = screen_w, h = screen_h }
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
                self.frame,
            },
        }
    else
        self.movable = MovableContainer:new{
            anchor = self:buildAnchor(),
            -- A hold is the text's first (a word to look up); one the text
            -- does not take is handed on to the box below, as before
            ignore_events = self.on_select and { "hold", "hold_pan", "hold_release" } or nil,
            self.frame,
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
        if self.on_select then
            -- The content widget selects (these events reach it first, the
            -- chat window's wiring); the release hands it this callback
            self.ges_events.HoldStartText = { GestureRange:new{ ges = "hold", range = whole } }
            self.ges_events.HoldPanText = { GestureRange:new{ ges = "hold_pan", range = whole,
                rate = Screen.low_pan_rate and 5.0 or 30.0 } }
            self.ges_events.HoldReleaseText = {
                GestureRange:new{ ges = "hold_release", range = whole },
                args = function(text, hold_duration)
                    self.on_select(text, hold_duration, function() self:clearHighlight() end)
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
    return Geom:new{ x = d.x, y = d.y - (self.rule_h or 0), w = d.w, h = d.h + (self.rule_h or 0) }
end

function MinimalPopup:onTap(_arg, ges)
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

-- A hold the text did not take (on the frame's edge): the box's own
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
--               on_expand, on_close; without a viewer also rtl_language,
--               features, is_dictionary }
--        viewer: the chat window a tap opens (built, not shown). The popup
--        shows the answer the way that window would (answerWidget): its view
--        mode, font, size, alignment and direction; a word or a passage held
--        in it goes to that window's own handler (handleTextSelection).
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
    local text
    if msgs then
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

return MinimalPopup
