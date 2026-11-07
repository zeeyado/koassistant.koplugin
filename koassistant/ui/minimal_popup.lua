--[[--
Minimal chrome-less response popup ("minimal popup" view mode).

A small anchored window with just the response text: no title bar, no buttons.
Tap inside = hand off to the full viewer (on_expand); tap outside = dismiss.
Anchors next to the highlight via MovableContainer's `anchor` when selection
geometry is available (EPUB — sboxes are already screen coordinates; paging/PDF
and geometry-less launches fall back to centered). Deliberately independent of
KOReader's own "highlight dialog position" setting: this mode is opted into via
the plugin's Translation Settings and always anchors when it can.

Consumers: actions registered in the Minimal Popup settings
(features.minimal_popup_actions — Translate and Quick Define by default;
showResponseDialog decides; this module never reads settings). "When it fits"
mode rides opts.only_if_fits: the caller asks this module whether the whole
response fits without the ellipsis (hasOverflow — rendered lines, so script
density and font size are handled by construction) and falls back to the full
viewer when it does not.
]]

local Blitbuffer = require("ffi/blitbuffer")
local Device = require("device")
local Font = require("ui/font")
local FrameContainer = require("ui/widget/container/framecontainer")
local Geom = require("ui/geometry")
local GestureRange = require("ui/gesturerange")
local InputContainer = require("ui/widget/container/inputcontainer")
local MovableContainer = require("ui/widget/container/movablecontainer")
local Size = require("ui/size")
local TextBoxWidget = require("ui/widget/textboxwidget")
local UIManager = require("ui/uimanager")
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local Screen = Device.screen
local _ = require("koassistant.core.gettext")

local MinimalPopup = InputContainer:extend{
    text = nil,             -- the response text (markdown already stripped by the
                            -- viewer's shared text-mode pass in showForResponse)
    selection_data = nil,   -- {sboxes, ...} captured at highlight time (read-only!)
    ui = nil,               -- ReaderUI-like (paging check only)
    para_direction_rtl = nil,  -- nil = auto-detect per paragraph
    lang = nil,             -- BCP-ish language hint for xtext, optional
    on_expand = nil,        -- tap inside the popup
    on_close = nil,         -- dismissed without expanding
}

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
    local padding = Size.padding.large
    self.width = math.floor(screen_w * 0.85)
    local max_text_h = math.floor(screen_h * 0.45)
    -- Same face the chat viewer renders plain text with
    self.textw = TextBoxWidget:new{
        text = self.text,
        face = Font:getFace("x_smallinfofont"),
        width = self.width - 2 * padding,
        height = max_text_h,               -- cap; shrinks to content below it
        height_adjust = true,
        height_overflow_show_ellipsis = true, -- overflow hint: tap to expand
        para_direction_rtl = self.para_direction_rtl,
        auto_para_direction = self.para_direction_rtl == nil,
        lang = self.lang,
    }
    -- Overflow affordance (device round 2026-08-15): in "Always" mode a long
    -- response renders ellipsized, and the bare "…" read as "that's all of
    -- it" — make the way out visible (the footnote card's muted "Tap for the
    -- full entry" precedent). Fitting popups stay chrome-free.
    local content = self.textw
    if self:hasOverflow() then
        local TextWidget = require("ui/widget/textwidget")
        local VerticalGroup = require("ui/widget/verticalgroup")
        local VerticalSpan = require("ui/widget/verticalspan")
        content = VerticalGroup:new{
            align = "left",
            self.textw,
            VerticalSpan:new{ width = Size.padding.small },
            TextWidget:new{
                text = _("Tap to show the full response"),
                face = Font:getFace("xx_smallinfofont"),
                fgcolor = Blitbuffer.COLOR_DARK_GRAY,
                max_width = self.width - 2 * padding,
            },
        }
    end
    self.frame = FrameContainer:new{
        radius = Size.radius.window,
        bordersize = Size.border.window,
        padding = padding,
        background = Blitbuffer.COLOR_WHITE,
        content,
    }
    self.movable = MovableContainer:new{
        anchor = self:buildAnchor(),
        self.frame,
    }
    self[1] = WidgetContainer:new{
        align = "center",
        dimen = Geom:new{ x = 0, y = 0, w = screen_w, h = screen_h },
        self.movable,
    }
    if Device:isTouchDevice() then
        self.ges_events = {
            Tap = {
                GestureRange:new{
                    ges = "tap",
                    range = Geom:new{ x = 0, y = 0, w = screen_w, h = screen_h },
                },
            },
        }
    end
    if Device:hasKeys() then
        -- Page-turn buttons dismiss (device 2026-08-13: the reader pressing
        -- next-page is moving on). The press is CONSUMED — the next one turns
        -- the page — matching how modals eat their dismissing tap. Back
        -- dismisses too (previously unhandled, so it fell through the popup
        -- to whatever sat below). All map onto the existing onClose path.
        self.key_events.Close = {
            { Device.input.group.PgFwd },
            { Device.input.group.PgBack },
            { Device.input.group.Back },
        }
    end
end

--- Did the response overflow the popup's height cap (ellipsis showing)?
-- Reads TextBoxWidget's own overflow condition — the exact test it uses to
-- decide `height_overflow_show_ellipsis` (#vertical_string_list >
-- lines_per_page after init). Language- and font-agnostic: this is rendered
-- lines, not characters, so CJK/Arabic density and the user's font size are
-- accounted for by construction. Defensive nil-checks in case a future
-- KOReader renames the internals (then: never overflows → popup always shown,
-- same as "Always" mode — degraded but not broken).
function MinimalPopup:hasOverflow()
    local tw = self.textw
    if tw and tw.vertical_string_list and tw.lines_per_page then
        return #tw.vertical_string_list > tw.lines_per_page
    end
    return false
end

function MinimalPopup:onTap(_arg, ges)
    if ges.pos:intersectWith(self.frame.dimen) then
        UIManager:close(self)
        if self.on_expand then self.on_expand() end
    else
        UIManager:close(self)
        if self.on_close then self.on_close() end
    end
    return true
end

function MinimalPopup:onClose()
    UIManager:close(self)
    if self.on_close then self.on_close() end
    return true
end

function MinimalPopup:onShow()
    UIManager:setDirty(self, function()
        return "ui", self.movable.dimen
    end)
    return true
end

function MinimalPopup:onCloseWidget()
    UIManager:setDirty(nil, function()
        return "partial", self.movable.dimen
    end)
end

--- Convenience for the response flow: pull the latest assistant message out of
-- a MessageHistory, resolve RTL from the caller-supplied language, show.
-- @param opts { history, selection_data, ui, rtl_language, only_if_fits,
--               features, is_dictionary, on_expand, on_close }
--        rtl_language: the language the response renders in (caller resolves
--        which setting that is — translation vs dictionary language); nil =
--        auto-detect direction per paragraph.
--        only_if_fits: "When it fits" mode — build the popup, and if the whole
--        response does not fit without the ellipsis, discard it and return
--        false so the caller opens the full viewer instead.
--        features: the request's features table — read for the SAME text-mode
--        settings the chat viewer honors (strip_markdown_in_text_mode).
--        is_dictionary: dict-family launch (compact/dictionary view) — gates the
--        IPA bidi reorder exactly like the viewer's needs_rtl_fix.
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
    if not text then return false end
    local para_direction_rtl = nil
    if opts.rtl_language then
        local ok, Languages = pcall(require, "koassistant.core.languages")
        if ok and Languages and Languages.isRTL and Languages.isRTL(opts.rtl_language) then
            para_direction_rtl = true
        end
    end
    -- The chat viewer's text-mode pipeline, reused verbatim (the viewer module is
    -- already loaded — showResponseDialog built the full viewer before deciding on
    -- the popup). This popup IS the text-mode rendering of that viewer, so it
    -- follows the same settings in the same order:
    --   1. Direction. Dict/translate launches resolve from the language setting
    --      (rtl_language, handled above — mirrors the viewer's explicit-RTL
    --      branches). Other registered actions get the standard-chat auto-detect:
    --      hasDominantRTL on the response (the popup is plain text by
    --      construction, so its direction is always detected; the Markdown
    --      windows need no switch, every block takes its own direction).
    --   2. stripMarkdown (strip_markdown_in_text_mode, default on): **bold** →
    --      PTF markers TextBoxWidget renders as real bold, LRM bidi fixes so an
    --      Arabic headword in a Latin-script definition keeps the line LTR-based.
    --   3. fixIPABidi under an RTL base, dict family only — the viewer's
    --      needs_rtl_fix gate.
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
    -- Trailing whitespace becomes a visible blank bottom line in a
    -- height-adjusted box (and counts against the fit test) — trim it whatever
    -- path produced the text (strip pipeline or raw model output).
    text = text:gsub("%s+$", "")
    if text == "" then return false end
    local popup = MinimalPopup:new{
        text = text,
        selection_data = opts.selection_data,
        ui = opts.ui,
        para_direction_rtl = para_direction_rtl,
        on_expand = opts.on_expand,
        on_close = opts.on_close,
    }
    if opts.only_if_fits and popup:hasOverflow() then
        popup:free()  -- constructed but never shown — release the text blitbuffers
        return false
    end
    UIManager:show(popup)
    return true
end

return MinimalPopup
