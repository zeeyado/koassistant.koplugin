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
widget's lines. A render is a re-layout of the whole text by MuPDF and a
paint of its page (35 to 70 ms at 3,500 words on a desktop, several times
that on a device), so renders keep a floor between them that follows the cost
of the last one: FLOOR at least, COST_FACTOR times the layout and the paint.
Where a render is cheap the answer is drawn several times a second, close to
the plain view's pace; where it is not, rendering takes a quarter of the time
at most (the first version waited 1.5 s whatever a render cost: "big chunks",
the maintainer on the desktop app, 2026-11-13). A short text (the waiting
animation, the first words) renders at once; a render the floor held back is
scheduled for the floor's end, so a pause in the chunks (a web search, a slow
provider) still shows what arrived. The last line's unclosed bold or code
mark is closed for the render (healTail), so a phrase is bold from its first
letter instead of showing its asterisks until the closing pair arrives.
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
StreamMarkdown.FLOOR = 0.2          -- seconds between renders, at least
StreamMarkdown.COST_FACTOR = 4      -- the floor grows to this many times the last render's cost (layout and paint)
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

--- The text as it stands mid-stream, readied for the render: what its last
--- line opened and has not closed yet is closed (a bold pair, a code tick),
--- and a last line that is so far only a block's mark (a list item's dash or
--- number, a heading's hashes, a quote's bracket) waits for its first word
--- instead of showing as a stray "-". Only the last line, and never inside an
--- open code fence. Pure; display only (the text itself is never changed).
function StreamMarkdown.healTail(text)
    if type(text) ~= "string" or text == "" then return text end
    local last = text:match("([^\n]*)$")
    if last == "" or last:match("^%s*```") then return text end
    local fences = 0
    for line in text:gmatch("[^\n]+") do
        if line:match("^%s*```") then fences = fences + 1 end
    end
    if fences % 2 == 1 then return text end
    if last:match("^%s*[-*+>]%s*$") or last:match("^%s*%d+[.)]?%s*$") or last:match("^%s*#+%s*$") then
        return text:sub(1, #text - #last)
    end
    local _ticked, ticks = last:gsub("`", "")
    -- inside a code span nothing else is markup
    if ticks % 2 == 1 then return text .. "`" end
    local _paired, pairs_of_stars = last:gsub("%*%*", "")
    -- a pair that only just opened has nothing to make bold yet
    if pairs_of_stars % 2 == 1 and not last:match("%*%*%s*$") then return text .. "**" end
    return text
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
    local ok, html = pcall(Viewer.markdownHtml, StreamMarkdown.healTail(text),
        { features = opts.features, text_align = opts.text_align })
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
    -- the layout's cost now; the page is rastered when it is painted, and
    -- paintTo adds that
    self.cost = self.rendered_at - t0
    self._paint_owed = true
    self.floor = math.max(StreamMarkdown.FLOOR, self.cost * StreamMarkdown.COST_FACTOR)
    self.renders = (self.renders or 0) + 1
    -- "fast" as the plain stream widget repaints: the text area alone, no flash
    UIManager:setDirty(self.parent, function() return "fast", self.dimen end)
end

--- The first paint after a render rasters the new page: part of what the
--- render costs, counted into the floor
function StreamMarkdown:paintTo(bb, x, y)
    local t0 = StreamMarkdown._now()
    if InputContainer.paintTo then InputContainer.paintTo(self, bb, x, y) end
    if self._paint_owed then
        self._paint_owed = nil
        self.cost = (self.cost or 0) + (StreamMarkdown._now() - t0)
        self.floor = math.max(StreamMarkdown.FLOOR, self.cost * StreamMarkdown.COST_FACTOR)
    end
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

-- The words of a page of the document (one reader for every HTML widget: the
-- chat window keeps its place with the same)
local function pageText(box, n)
    return require("koassistant.ui.viewer_place").pageText(box, n)
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
