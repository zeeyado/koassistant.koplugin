--[[
The Markdown view of the streaming window (B562, the maintainer's ruling of
2026-11-07): the answer rendered as it streams, through the viewer's own
Markdown pipeline (bold, headings, lists, the fonts of every script, emoji),
instead of plain text swapped for the rendered view at the end.

It stands in for InputText inside the stream handler's InputDialog
(inputtext_class), so the dialog's chrome (the title bar, Stop, Autoscroll,
Quick, the scroll buttons) and the handler's cadence stay as they are; it
answers the subset of InputText's interface the dialog and the handler call,
and the handler branches on `markdown_stream` where it reads the plain
widget's lines. A render is a re-layout of the whole text by MuPDF (about
0.2 s at 3,000 words on the device, 0.5 s at 9,000), so it happens at line
ends with a floor between renders that grows with the cost of the last one,
and at once for a short text (the waiting animation, the first words); a
render the floor held back is scheduled for the floor's end, so a pause in
the chunks (a web search, a slow provider) still shows what arrived.
Pagination is stable top-down (probed 2026-10-28), so a paused reader keeps
their page while the tail grows; following shows the last page. The reader's
spot for the completion viewer is the first line of their page, read from the
page's text (capturePosition; CJK segments joined without spaces, as the text
has none). Settings: features.stream_markdown (off by
default), applied when the chat shows Markdown (koassistant/request/gpt_query.lua
builds the stream settings; the dialog carries `koa_stream` = the features,
the alignment and the font size for the render).
]]

local Device = require("device")
local FrameContainer = require("ui/widget/container/framecontainer")
local Geom = require("ui/geometry")
local InputContainer = require("ui/widget/container/inputcontainer")
local ScrollHtmlWidget = require("ui/widget/scrollhtmlwidget")
local UIManager = require("ui/uimanager")
local logger = require("koassistant.core.logger")
local Screen = Device.screen

local StreamMarkdown = InputContainer:extend{
    markdown_stream = true,     -- what the stream handler branches on
    text = "",
    follow = true,              -- show the last page after a render (the handler sets it)
    width = nil,
    height = nil,
    padding = 0,
    margin = 0,
    parent = nil,               -- the InputDialog; parent.koa_stream = { features, text_align, font_size }
    -- fields InputDialog reads off its input widget
    top_line_num = nil,
    charpos = nil,
    keyboard = nil,
}

StreamMarkdown.SHORT = 400          -- bytes: a text this short renders at once
StreamMarkdown.FLOOR = 1.5          -- seconds between renders, at least
StreamMarkdown.COST_FACTOR = 6      -- the floor grows to this many times the last render's cost
StreamMarkdown.CAPTURE_PAGES = 10   -- pages read back for the occurrence count at most (each a text extraction)

-- Wall-clock seconds (a floor between renders must not count CPU time, which
-- barely moves while the window waits for the next chunk)
local function nowSeconds()
    local ok, time = pcall(require, "ui/time")
    if ok and type(time) == "table" and time.now and time.to_s then
        return time.to_s(time.now())
    end
    return os.time()
end
StreamMarkdown._now = nowSeconds

--- Whether a render is due, pure: state = { rendered = the text last rendered
--- (nil before the first), rendered_at = seconds, floor = seconds }. Returns
--- true, or false and the seconds left on the floor when that is what holds
--- it (nil when nothing changed).
function StreamMarkdown.renderDue(state, text, now)
    if state.rendered == nil then return true end
    if text == state.rendered then return false, nil end
    if #text < StreamMarkdown.SHORT then return true end
    local left = (state.floor or StreamMarkdown.FLOOR) - (now - (state.rendered_at or 0))
    if left > 0 then return false, left end
    return true
end

function StreamMarkdown:init()
    self.text = self.text or ""
    self[1] = FrameContainer:new{
        bordersize = 0,
        padding = self.padding,
        margin = self.margin,
    }
    self:initTextBox()
end

-- The render options the handler put on the dialog
function StreamMarkdown:_opts()
    return (self.parent and self.parent.koa_stream) or {}
end

function StreamMarkdown:_buildScrollWidget(html_body)
    local opts = self:_opts()
    local Viewer = require("koassistant.ui.chatgptviewer")
    return ScrollHtmlWidget:new{
        html_body = html_body,
        css = Viewer.viewerCSS(opts.text_align, opts.features, html_body),
        default_font_size = Screen:scaleBySize(opts.font_size or 20),
        width = self.width,
        height = self.height,
        dialog = self.parent,
        highlight_text_selection = false,
    }
end

--- The render: the text through the viewer's pipeline into a new HTML widget
--- in place of the old one; the last page while following, the reader's page
--- otherwise. The handler wraps this method to re-hook each new widget.
function StreamMarkdown:initTextBox()
    local text = self.text or ""
    local t0 = StreamMarkdown._now()
    local Viewer = require("koassistant.ui.chatgptviewer")
    local opts = self:_opts()
    local ok, html = pcall(Viewer.markdownHtml, text, { features = opts.features, text_align = opts.text_align })
    if not ok or type(html) ~= "string" then
        logger.warn("KOAssistant: Markdown stream render failed:", tostring(html))
        html = "<pre>" .. text:gsub("&", "&amp;"):gsub("<", "&lt;") .. "</pre>"
    end
    local old = self.scroll_w
    local old_box = old and old.htmlbox_widget
    local keep_page = old_box and old_box.page_number or 1
    local new = self:_buildScrollWidget(html)
    self.scroll_w = new
    self.text_widget = new   -- the handler's scroll hooks find the inner widget here
    self[1][1] = new
    if not self.dimen then
        self.dimen = Geom:new(self[1]:getSize())
    end
    local box = new.htmlbox_widget
    if box and box.page_count then
        local page = self.follow and box.page_count or math.min(keep_page, box.page_count)
        if page ~= box.page_number and box.setPageNumber then
            box:setPageNumber(page)
        end
    end
    -- The dialog's scroll buttons hear the page once, at its final value (the
    -- widget's init reported page 1 to nobody)
    new.scroll_callback = self.scroll_callback
    if new._updateScrollBar then new:_updateScrollBar() end
    if old_box and old_box.free then old_box:free() end
    self:_dropPending()
    self.rendered = text
    self.rendered_at = StreamMarkdown._now()
    local cost = self.rendered_at - t0
    self.floor = math.max(StreamMarkdown.FLOOR, cost * StreamMarkdown.COST_FACTOR)
    self.renders = (self.renders or 0) + 1
    -- "fast" as the plain stream widget repaints: the text area alone, no flash
    UIManager:setDirty(self.parent, function() return "fast", self.dimen end)
end

-- The render the floor held back, scheduled for the floor's end; dropped by
-- a render that comes first and at close
function StreamMarkdown:_dropPending()
    if self._pending then
        UIManager:unschedule(self._pending)
        self._pending = nil
    end
end

function StreamMarkdown:_schedulePending(seconds)
    if self._pending or self._closed then return end
    local task
    task = function()
        if self._pending ~= task then return end
        self._pending = nil
        if not self._closed and self.text ~= self.rendered then self:initTextBox() end
    end
    self._pending = task
    UIManager:scheduleIn(seconds, task)
end

function StreamMarkdown:setText(text)
    self.text = text or ""
    local due, left = StreamMarkdown.renderDue(self, self.text, StreamMarkdown._now())
    if due then
        self:initTextBox()
    elseif left then
        self:_schedulePending(left)
    end
end

function StreamMarkdown:getText() return self.text end
function StreamMarkdown:addChars() end
function StreamMarkdown:getSize() return self.dimen end
function StreamMarkdown:getPasswordToggleWidget() return nil end
function StreamMarkdown:isTextEditable() return false end
function StreamMarkdown:isTextEdited() return false end
function StreamMarkdown:getLineNums() return 1, 1 end
function StreamMarkdown:getTextHeight() return self.height end
function StreamMarkdown:getKeyboardDimen() return Geom:new{ w = 0, h = 0 } end
function StreamMarkdown:onShowKeyboard() end
function StreamMarkdown:onCloseKeyboard() end
function StreamMarkdown:isKeyboardVisible() return false end
function StreamMarkdown:lockKeyboard() end
function StreamMarkdown:resyncPos() end

function StreamMarkdown:currentPage()
    local box = self.scroll_w and self.scroll_w.htmlbox_widget
    return box and box.page_number or 1
end

function StreamMarkdown:pageCount()
    local box = self.scroll_w and self.scroll_w.htmlbox_widget
    return box and box.page_count or 1
end

function StreamMarkdown:scrollUp()
    if self.scroll_w and self.scroll_w.scrollText then self.scroll_w:scrollText(-1) end
end

function StreamMarkdown:scrollDown()
    if self.scroll_w and self.scroll_w.scrollText then self.scroll_w:scrollText(1) end
end

function StreamMarkdown:scrollToTop()
    if self.scroll_w and self.scroll_w.scrollToRatio then self.scroll_w:scrollToRatio(0) end
end

--- The last page, painted (following resumed, the tail wanted): the
--- widget's own scroll, which drops the page's old bitmap and redraws
function StreamMarkdown:jumpToEnd()
    if self.scroll_w and self.scroll_w.scrollToRatio then self.scroll_w:scrollToRatio(1) end
end
StreamMarkdown.scrollToBottom = StreamMarkdown.jumpToEnd

-- A character of a script written without spaces (CJK, kana, Hangul): MuPDF
-- hands such text back in odd segments, which join back without a space
local function spaceless(ch)
    local b = ch:byte(1)
    return b ~= nil and b >= 0xE3 and b <= 0xED
end

-- The words of a page of the document, joined by a space except between two
-- spaceless-script segments
local function pageText(box, n)
    local ok, page = pcall(box.document.openPage, box.document, n)
    if not ok or not page then return "" end
    local ok_t, lines = pcall(page.getPageText, page)
    pcall(page.close, page)
    if not ok_t or type(lines) ~= "table" then return "" end
    local out = {}
    for _idx, line in ipairs(lines) do
        if type(line) == "table" then
            for _jdx, w in ipairs(line) do
                if type(w) == "table" and type(w.word) == "string" and w.word ~= "" then
                    local prev = out[#out]
                    if prev and not (spaceless(prev:sub(-3)) and spaceless(w.word:sub(1, 3))) then
                        out[#out + 1] = " "
                    end
                    out[#out + 1] = w.word
                end
            end
        end
    end
    return table.concat(out)
end

--- The reader's spot for the completion viewer: the first words of their
--- page, and the ordinal of that text's anchor among the pages before it
--- (the viewer's landing counts occurrences the same way). Nil on the first
--- page, where there is nothing to keep, and without a document.
function StreamMarkdown:capturePosition()
    local box = self.scroll_w and self.scroll_w.htmlbox_widget
    if not box or not box.document or not box.page_number or box.page_number <= 1 then return nil end
    local snippet = pageText(box, box.page_number):sub(1, 320)
    if snippet:match("^%s*$") then return nil end
    local occurrence = 1
    local Viewer = require("koassistant.ui.chatgptviewer")
    local anchor = Viewer.extractCarryAnchor and Viewer.extractCarryAnchor(snippet)
    if anchor then
        local first = math.max(1, box.page_number - StreamMarkdown.CAPTURE_PAGES)
        for n = first, box.page_number - 1 do
            local t = pageText(box, n)
            local from = 1
            while true do
                local s = t:find(anchor, from, true)
                if not s then break end
                occurrence = occurrence + 1
                from = s + 1
            end
        end
    end
    return snippet, occurrence
end

function StreamMarkdown:onCloseWidget()
    self._closed = true
    self:_dropPending()
    -- the renders repaint with "fast"; a flashui at the end clears e-ink
    -- ghosting, as the plain stream widget does
    UIManager:setDirty(self.parent, function() return "flashui", self.dimen end)
end

return StreamMarkdown
