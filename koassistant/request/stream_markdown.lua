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
widget's lines.

A drawing is the text converted to HTML, the whole HTML laid out by MuPDF and
its page painted. The conversion was most of that (four fifths at 2,000 words,
measured in the app, 2026-11-14), and nearly all of it is the answer's
finished part converted again, so that part is converted once and kept
(convert, cut where safeCut says the pieces give the whole conversion's HTML);
what a drawing still does on the whole answer is the direction pass, the
script runs and MuPDF's layout. Drawings keep a floor between them that
follows the cost of the last one: FLOOR at least, COST_FACTOR times the
conversion, the layout and the paint. Where a drawing is cheap the answer is
drawn several times a second, close to the plain view's pace; where it is
not, drawing takes a quarter of the time at most (the first version waited
1.5 s whatever a drawing cost: "big chunks", the maintainer on the desktop
app, 2026-11-13). A short text (the waiting animation, the first words)
renders at once; a render the floor held back is scheduled for the floor's
end, so a pause in the chunks (a web search, a slow provider) still shows
what arrived. The last line's unclosed bold or code mark is closed for the
render (healTail), so a phrase is bold from its first letter instead of
showing its asterisks until the closing pair arrives.
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

-- How a line starts, as the Markdown library counts indentation: at the
-- margin unless its first byte is a space, a tab or a quote's bracket
local function atMargin(line)
    local first = line:byte(1)
    return first ~= 32 and first ~= 9 and first ~= 62
end

-- A line's count of a plain string
local function count(line, plain)
    local n, from = 0, 1
    while true do
        local _s, e = line:find(plain, from, true)
        if not e then return n end
        n, from = n + 1, e + 1
    end
end

-- Whether the math pass (koassistant/ui/math.lua, convertSegment) has nothing
-- open at the end of a stretch of text between code fences: its spans paired
-- as it pairs them, in its order (code spans, "$$", "\[", "\("), and no mark
-- left over that a later one could close
local function mathClosed(stretch)
    if not stretch:find("[`$\\]") then return true end
    local rest = stretch:gsub("(`+)(.-)%1", " ")
    if rest:find("`", 1, true) then return false end
    rest = rest:gsub("%$%$(.-)%$%$", " ")
    if rest:find("$$", 1, true) then return false end
    rest = rest:gsub("\\%[(.-)\\%]", " ")
    if rest:find("\\[", 1, true) then return false end
    rest = rest:gsub("\\%((.-)\\%)", " ")
    return not rest:find("\\(", 1, true)
end

-- Whether the passes that run before the Markdown library leave nothing open
-- at the end of a piece (text[from, cut - 1]; `stretch` = where its last
-- stretch between code fences starts). They pair marks across lines, each on
-- the text the pass before it left: the math pass first (it takes a "\[" and
-- its "\]" out, so the link passes after it see other brackets than the
-- source has), then the two link passes (a "[" with its "]", then balanced
-- parentheses), then the shield that keeps math from the emphasis pass
-- ("$$" pairs, through code too).
local function marksClosed(text, from, stretch, cut, math)
    if math and not mathClosed(text:sub(stretch, cut - 1)) then return false end
    local piece = text:sub(from, cut - 1)
    if math then piece = math(piece) end
    if piece:find("[", 1, true) then
        if piece:find("%[[^%]]*$") then return false end
        local at = 1
        while true do
            local _s, e = piece:find("](", at, true)
            if not e then break end
            if not piece:find("^%b()", e) then return false end
            at = e + 1
        end
    end
    return not piece:find("$$", 1, true) or count(piece, "$$") % 2 == 0
end

--- Where the text can be cut so that the part before the cut converts to
--- the same HTML alone as it does inside the whole text (the first half of
--- the viewer's pipeline, ChatGPTViewer.markdownBlocks): the answer's finished
--- part is then converted once and kept, and a drawing converts only what
--- came after. Returns the offset of the line the next piece starts with (the
--- last such line after `from`, itself a line start), or nil.
---
--- A cut sits after a blank line, where the Markdown library is back at its
--- top level: not inside a code fence, and not inside a list's indented
--- content, which runs across blank lines until a line at the margin (so
--- either the last line before the blank one is at the margin, or the line
--- after it is and is no list item, which could carry the list on). And the
--- passes before the library must have nothing open there (marksClosed). A
--- text that stays open (a stray backtick) is converted whole from there on,
--- as before.
--- opts.math: the math pass as the pipeline applies it, nil when math
--- rendering is off; opts.rejected: a table that remembers the lines already
--- found open, for the caller that asks again as the text grows (a verdict
--- on a line never changes: the text before it is final).
function StreamMarkdown.safeCut(text, from, opts)
    local pos = from or 1
    local first = pos
    local len = #text
    local in_fence, after_blank, prev_at_margin = false, false, true
    local stretch = pos         -- where the text since the last fence line starts
    local found = {}            -- the lines a piece may start with: offset, its stretch's start
    while pos <= len do
        local nl = text:find("\n", pos, true)
        local line = text:sub(pos, (nl or len + 1) - 1)
        if line:find("^%s*$") then
            after_blank = true
        else
            -- a line still arriving has no kind yet: there only the line before decides
            if after_blank and not in_fence and (prev_at_margin or (nl and atMargin(line)
                and not line:find("^[-*+]%s") and not line:find("^%d+[.)]%s"))) then
                found[#found + 1] = pos
                found[#found + 1] = stretch
            end
            if not nl then break end
            if line:find("^%s*```") then
                in_fence = not in_fence
                stretch = nl + 1
            end
            after_blank = false
            prev_at_margin = atMargin(line)
        end
        if not nl then break end
        pos = nl + 1
    end
    -- the last one with nothing open before it; a few tries a call, since a
    -- text that stays open is long and each try reads it
    local math, rejected = opts and opts.math, opts and opts.rejected
    local tries = 0
    for i = #found - 1, 1, -2 do
        local cut = found[i]
        if not (rejected and rejected[cut]) then
            if marksClosed(text, first, found[i + 1], cut, math) then return cut end
            if rejected then rejected[cut] = true end
            tries = tries + 1
            if tries >= 3 then break end
        end
    end
    return nil
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

-- The math pass as the viewer's pipeline applies it (applyMath), nil when
-- math rendering is off
local function mathPass(features)
    if features and features.render_math == false then return nil end
    local MathRender = require("koassistant.ui.math")
    return function(piece)
        if not MathRender.hasMath(piece) then return piece end
        return MathRender.render(piece)
    end
end

--- The text as HTML, the finished part of the answer converted once: `kept`
--- = { text = the part of the answer already converted (it ends at a safeCut),
--- html = its blocks, off = true once a piece failed to convert alone }.
--- Each call converts what came since the last cut, and the tail after the
--- newest cut with its open marks healed; the passes that read the whole
--- document run on the joined blocks. Another text than the kept one (the
--- reasoning shown before the answer, a cleared window) starts over. The
--- same HTML as ChatGPTViewer.markdownHtml(healTail(text)) gives.
function StreamMarkdown.convert(kept, text, opts)
    local Viewer = require("koassistant.ui.chatgptviewer")
    if not kept.off then
        if kept.text ~= "" and text:sub(1, #kept.text) ~= kept.text then
            kept.text, kept.html, kept.rejected = "", "", nil
        end
        kept.rejected = kept.rejected or {}
        local cut = StreamMarkdown.safeCut(text, #kept.text + 1,
            { math = mathPass(opts and opts.features), rejected = kept.rejected })
        if cut then
            local html = Viewer.markdownBlocks(text:sub(#kept.text + 1, cut - 1), opts)
            if html then
                kept.text, kept.html, kept.rejected = text:sub(1, cut - 1), kept.html .. html, nil
            else
                kept.off = true
            end
        end
        if not kept.off then
            local tail = Viewer.markdownBlocks(StreamMarkdown.healTail(text:sub(#kept.text + 1)), opts)
            if tail then return Viewer.markdownFinish(kept.html .. tail, opts) end
        end
    end
    return Viewer.markdownHtml(StreamMarkdown.healTail(text), opts)
end

--- The render: the text through the viewer's pipeline into a new HTML widget
--- in place of the old one; the last page while following, the reader's page
--- otherwise. The handler wraps this method to re-hook each new widget.
function StreamMarkdown:initTextBox()
    local text = self.text or ""
    local t0 = StreamMarkdown._now()
    local opts = self:_opts()
    self.kept = self.kept or { text = "", html = "" }
    local ok, html = pcall(StreamMarkdown.convert, self.kept, text,
        { features = opts.features, text_align = opts.text_align })
    if not ok or type(html) ~= "string" then
        logger.warn("KOAssistant: Markdown stream render failed:", tostring(html))
        self.kept.off = true
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
    -- what the drawings cost, for a report from a device (Console Debug)
    logger.dbg("KOAssistant: Markdown stream closed:", self.renders or 0, "drawings,", #(self.text or ""),
        "bytes,", self.kept and #self.kept.text or 0, "of them kept; the last drawing took",
        math.floor((self.cost or 0) * 1000 + 0.5), "ms")
    -- the renders repaint with "fast"; a flashui at the end clears e-ink
    -- ghosting, as the plain stream widget does
    UIManager:setDirty(self.parent, function() return "flashui", self.dimen end)
end

return StreamMarkdown
