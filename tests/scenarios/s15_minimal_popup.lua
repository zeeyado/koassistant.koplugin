--[[
The minimal popup on KOReader's real widgets (B695): a real chat window built
but not shown, as the response dialog builds it, and the popup that stands in
for it.

What a reader must see:
- the popup shows the answer the way the window a tap opens would: the
  Markdown view (an italic is an italic, a script's face is its own), or the
  plain-text widget when the reader's view is Plain Text;
- the box is as wide as the chat window and as tall as its answer, up to its
  cap; the panel runs from edge to edge at the foot of the screen;
- "When it fits" hands an answer taller than the cap back (the full window
  opens instead); "Always" shows it and it scrolls: a swipe, or a page key,
  which closes the popup once there is nothing more that way;
- a tap inside opens the full window, a tap outside closes the popup;
- the X-Ray card's popup style (plain text, no chat window behind it) still
  shows and opens its entry.
]]
local S = dofile(os.getenv("KOA_PLUGIN") .. "/tests/scenarios/boot.lua")
local Device = require("device")
local Event = require("ui/event")
local Geom = require("ui/geometry")
local UIManager = require("ui/uimanager")
local Screen = Device.screen
local Viewer = require("koassistant.ui.chatgptviewer")
local UIConstants = require("koassistant.ui.constants")
local MinimalPopup = require("koassistant.ui.minimal_popup")
local MessageHistory = require("koassistant.request.message_history")

-- page keys exist on the readers this is for; the headless device has none
local has_keys = Device.hasKeys
Device.hasKeys = function() return true end

local SHORT = "**The toll ledger** was moved.\n\n*Here:* the book in which the Toll House records what each traveller paid, عاصمة."
local function long()
    local out = {}
    for k = 1, 12 do
        out[#out + 1] = "Paragraph " .. k .. " of the translation. The old keeper wrote three lines in the margin and passed "
            .. "the page across the table without a word, and for a long moment nobody in the room spoke."
    end
    return table.concat(out, "\n\n")
end

-- the HTML the content widget is given
local Box = require("ui/widget/htmlboxwidget")
local setContent, last_html = Box.setContent, ""
Box.setContent = function(self, body, ...)
    last_html = body
    return setContent(self, body, ...)
end

-- A translate window for an answer, built and not shown (as showResponseDialog
-- has it when it decides on the popup), and the popup asked for it
local function ask(answer, opts)
    opts = opts or {}
    local features = { translate_view = true }
    for k, v in pairs(opts.features or {}) do features[k] = v end
    local config = { features = features }
    local h = MessageHistory:new("system prompt")
    h:addUserMessage("Translate: The toll ledger was moved.", true)
    h:addAssistantMessage(answer, "model-x")
    local v = Viewer:new{
        title = "Translate",
        text = h:createTranslateViewText("The toll ledger was moved.", true),
        configuration = config,
        original_history = h,
        _message_history = h,
    }
    local r = { viewer = v, expanded = 0, closed = 0 }
    r.shown = MinimalPopup.showForResponse({
        history = h,
        viewer = not opts.no_viewer and v or nil,
        style = opts.style,
        selection_data = opts.boxes and { sboxes = opts.boxes } or nil,
        ui = opts.boxes and {} or nil,
        only_if_fits = opts.only_if_fits,
        features = features,
        on_expand = function() r.expanded = r.expanded + 1 end,
        on_close = function() r.closed = r.closed + 1 end,
    })
    S.settle()
    UIManager:forceRePaint()
    local top = S.top()
    r.popup = (r.shown and type(top) == "table" and top.scroll_w and top.hasOverflow) and top or nil
    return r
end
local function isUp(r)
    return r.popup ~= nil and S.top() == r.popup
end
local function done(r)
    if isUp(r) then UIManager:close(r.popup) end
    if r.viewer.free then pcall(r.viewer.free, r.viewer) end
    S.settle(1)
end
local function key(name)
    UIManager:sendEvent(Event:new("KeyPress", require("device/key"):new(name, Device.input.modifiers or {})))
    S.settle(1)
end
local function gesture(kind, x, y, direction)
    UIManager:sendEvent(Event:new("Gesture", { ges = kind, direction = direction, distance = 200,
        pos = Geom:new{ x = x, y = y, w = 0, h = 0 }, time = require("ui/time").now() }))
    S.settle(1)
end
local function page(r) return r.popup.scroll_w.htmlbox_widget.page_number end

local chat_text_w = UIConstants.CHAT_WIDTH() - 2 * (Viewer.text_padding + Viewer.text_margin)
local sw, sh = Screen:getWidth(), Screen:getHeight()

-- 1. A short answer, "When it fits", the box
local r = ask(SHORT, { only_if_fits = true })
S.check(r.shown == true and r.popup ~= nil, "a short answer is shown in the popup")
if r.popup then
    local p = r.popup
    S.check(p.scroll_w.htmlbox_widget ~= nil, "it is the Markdown view, as the window a tap opens shows it")
    S.check(last_html:find("<em>Here:</em>", 1, true) ~= nil and last_html:find("*Here:*", 1, true) == nil,
        "an italic is an italic")
    S.check(last_html:find('class="koa-arab"', 1, true) ~= nil, "a word in another script is in its face's span")
    S.check(p.scroll_w.width == chat_text_w, "the text is as wide as the chat window's (" .. p.scroll_w.width .. " of " .. chat_text_w .. ")")
    S.check(not p:hasOverflow() and p.text_h < p.cap, "as tall as its answer (" .. p.text_h .. " px under a cap of " .. p.cap .. ")")
    S.check(p.movable ~= nil and p.frame.dimen.x > 0, "the default shape is the box")
    S.shot("popup_box_short")
    local f = p.frame.dimen
    gesture("tap", f.x + math.floor(f.w / 2), f.y + math.floor(f.h / 2))
    S.check(not isUp(r) and r.expanded == 1 and r.closed == 0, "a tap inside opens the full window")
end
done(r)

-- 2. An answer taller than the cap, "When it fits": handed back
r = ask(long(), { only_if_fits = true })
S.check(r.shown == false and r.popup == nil, "When it fits: an answer taller than the cap is handed to the full window")
done(r)

-- 3. The same answer, "Always": it scrolls
r = ask(long(), {})
S.check(r.shown == true and r.popup ~= nil and r.popup:hasOverflow(), "Always: the long answer is shown, and scrolls")
if r.popup then
    local p = r.popup
    local pages = p.scroll_w.htmlbox_widget.page_count
    S.check(p.text_h == p.cap and pages > 1 and page(r) == 1, "at its cap, page 1 of " .. pages)
    S.shot("popup_box_long")
    key("RPgFwd")
    S.check(isUp(r) and page(r) == 2, "the next-page key scrolls it")
    key("RPgBack")
    S.check(isUp(r) and page(r) == 1, "the previous-page key scrolls back")
    local f = p.frame.dimen
    gesture("swipe", f.x + math.floor(f.w / 2), f.y + math.floor(f.h / 2), "north")
    S.check(isUp(r) and page(r) == 2, "a swipe up scrolls it")
    gesture("swipe", f.x + math.floor(f.w / 2), f.y + math.floor(f.h / 2), "south")
    S.check(isUp(r) and page(r) == 1, "a swipe down scrolls back")
    key("RPgBack")
    S.check(not isUp(r) and r.closed == 1 and r.expanded == 0, "with nothing more that way the page key closes the popup")
end
done(r)
r = ask(long(), {})
if r.popup then
    local pages = r.popup.scroll_w.htmlbox_widget.page_count
    for _k = 2, pages do key("RPgFwd") end
    S.check(isUp(r) and page(r) == pages, "the next-page key reaches the last page (" .. pages .. ")")
    key("RPgFwd")
    S.check(not isUp(r) and r.closed == 1, "and the next press closes the popup")
end
done(r)
r = ask(long(), {})
if r.popup then
    gesture("tap", 5, 5)
    S.check(not isUp(r) and r.closed == 1 and r.expanded == 0, "a tap outside closes the popup")
end
done(r)

-- 4. The box by a selection
r = ask(SHORT, { boxes = { { x = 100, y = math.floor(sh * 0.2), w = 120, h = 30 } } })
if S.check(r.popup ~= nil, "the box is shown by a selection") then
    S.check(r.popup.frame.dimen.y > math.floor(sh * 0.2) + 30, "under the selection (y " .. r.popup.frame.dimen.y .. ")")
end
done(r)

-- 5. The panel at the foot of the screen
r = ask(SHORT, { style = "panel" })
if S.check(r.popup ~= nil, "the panel is shown") then
    local f = r.popup.frame.dimen
    S.check(r.popup.movable == nil and f.x == 0 and f.w == sw, "from edge to edge (" .. f.w .. " of " .. sw .. ")")
    S.check(f.y + f.h == sh, "on the foot of the screen")
    S.check(r.popup.scroll_w.width == sw - 2 * (Viewer.text_padding + Viewer.text_margin), "its text inset is the chat window's")
    S.shot("popup_panel_short")
    gesture("swipe", math.floor(sw / 2), math.floor(f.y / 2), "south")
    S.check(not isUp(r) and r.closed == 1, "a swipe down above the panel closes it, as KOReader's footnote popup closes")
end
done(r)
r = ask(long(), { style = "panel" })
if S.check(r.popup ~= nil and r.popup:hasOverflow(), "the panel scrolls a long answer") then
    local f = r.popup.frame.dimen
    gesture("tap", math.floor(sw / 2), f.y + math.floor(f.h / 2))
    S.check(not isUp(r) and r.expanded == 1, "a tap inside the panel opens the full window")
end
done(r)

-- 6. The reader's view is Plain Text: the popup shows what that window would
r = ask(long(), { features = { render_markdown = false } })
if S.check(r.popup ~= nil, "Plain Text view: the popup is shown") then
    local p = r.popup
    S.check(p.scroll_w.text_widget ~= nil and p.scroll_w.htmlbox_widget == nil, "it is the plain-text widget")
    S.check(p:hasOverflow() and p.scroll_w.width == chat_text_w, "the long answer scrolls, at the chat window's width")
    local first = p.scroll_w.text_widget.virtual_line_num
    key("RPgFwd")
    S.check(isUp(r) and p.scroll_w.text_widget.virtual_line_num > first, "the page key scrolls it")
end
done(r)
r = ask(long(), { features = { render_markdown = false }, only_if_fits = true })
S.check(r.shown == false, "Plain Text view, When it fits: the long answer is handed back as well")
done(r)

-- 7. A caller with no chat window (the fallback) and the X-Ray card's popup style
r = ask(SHORT, { no_viewer = true })
S.check(r.popup ~= nil and r.popup.scroll_w.text_widget ~= nil, "without a chat window the answer is shown as plain text")
done(r)
local opened = 0
local card = MinimalPopup:new{
    text = Viewer.stripMarkdown("**Old Venn** · Person\n\nThe keeper of the Toll House."),
    on_expand = function() opened = opened + 1 end,
}
UIManager:show(card)
S.settle()
UIManager:forceRePaint()
S.check(S.top() == card and card.scroll_w.text_widget ~= nil and not card:hasOverflow(), "the X-Ray card's popup style shows its text")
S.check(card.scroll_w.width == chat_text_w, "in the same box")
S.shot("popup_card")
local cf = card.frame.dimen
gesture("tap", cf.x + math.floor(cf.w / 2), cf.y + math.floor(cf.h / 2))
S.check(S.top() ~= card and opened == 1, "and a tap opens its entry")

Box.setContent = setContent
Device.hasKeys = has_keys
S.finish()
