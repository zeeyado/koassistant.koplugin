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
script runs and MuPDF's layout. The pace is the handler's tick, the reader's
Display Refresh Interval, as for the plain view: measured in the app on the
same stream, an update costs about the same in both views (7 to 12 ms plain,
5 to 20 ms here, 2 KB to 40 KB, on a desktop). The floor between drawings
only keeps a slow drawing from taking the device: FLOOR at least, COST_FACTOR
times the conversion, the layout and the paint, counted from the drawing's
end, so a drawing is followed by a rest as long as it took and drawing takes
half of the time at most. (The first version waited 1.5 s whatever a drawing
cost: "big chunks", the maintainer on the desktop app, 2026-11-13; the second
rested four times a drawing's cost, a fifth of the time at most: "chunkier
than text streaming" on a Kobo, 2026-11-14. With an update made to cost
150 ms in the app, the plain view, which has no such floor, was drawn 2.5
times a second and this one 1.3 times; now 2.5 too.) A short text (the waiting animation, the first words)
renders at once; a render the floor held back is scheduled for the floor's
end, so a pause in the chunks (a web search, a slow provider) still shows
what arrived; a text that shows nothing new (what arrived is held back) is
not drawn again. What is still arriving is readied for the render (healTail):
the last line's unclosed bold or code mark is closed, so a phrase is bold
from its first letter instead of showing its asterisks until the closing pair
arrives; a link shows its words while its address arrives; a table's row
waits until it is whole, and its header until the line under it says it is a
table, instead of showing as a line of pipes that then jumps into the table
("tables struggle a bit", the same round). A drawing is sent to the screen
as "ui" (REFRESH), the type KOReader uses for a text box being typed into.
It was "fast", copied from the plain stream widget's request, which on e-ink
draws black and white only (KOReader's Kobo, Kindle and PocketBook drivers:
the letters lose their grey edges, and where drawn text moves remnants
stay): "the text while streaming on kobo is not as clear as it becomes once
the answer is complete ... only when the page is actively refreshing" (the
maintainer, 2026-11-14). The plain view never looked so, though it asks for
"fast" too: its two layouts a tick flip the scroll buttons' state,
KOReader's InputDialog then refreshes its whole frame as "ui", and UIManager
joins overlapping requests under the higher type (measured in the app: 86 of
103 updates of a plain stream reach the screen as "ui"; 102 of 104 of this
view's reached it as "fast").
Pagination is stable top-down (probed 2026-10-28), so a paused reader keeps
their page while the tail grows; following shows the last page. The reader's
spot for the completion viewer is the first line of their page, read from the
page's text (capturePosition; CJK segments joined without spaces, as the text
has none). Settings: features.stream_markdown, on by default (since
2026-11-15, the maintainer after the Kobo round: "it workes very well, clean
and crisp"); which requests stream into this view is `applies` (an answer
that is prose, a window that will show it as Markdown; never a hidden
stream, the handler's rule). koassistant/request/gpt_query.lua builds the
stream settings with it; the dialog carries `koa_stream` = the features, the
alignment and the font size for the render.
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
StreamMarkdown.FLOOR = 0.1          -- seconds between renders, at least (the shortest Display Refresh Interval)
StreamMarkdown.COST_FACTOR = 1      -- the floor grows to this many times the last render's cost: half the time at most
StreamMarkdown.CAPTURE_PAGES = 10   -- pages read back for the occurrence count at most (each a text extraction)
StreamMarkdown.HEADER_HOLD = 160    -- bytes: a table's first lines are held back up to this size

-- Wall-clock seconds (a floor between renders must not count CPU time, which
-- barely moves while the window waits for the next chunk); the precise clock
-- where there is one (the coarse one steps by 10 ms on some devices, and a
-- drawing's cost is read from it)
local function nowSeconds()
    local ok, time = pcall(require, "ui/time")
    if ok and type(time) == "table" and time.to_s then
        local read = time.monotonic or time.now
        if read then return time.to_s(read()) end
    end
    return os.time()
end
StreamMarkdown._now = nowSeconds

-- How a drawing is sent to the screen: as the plain view's updates reach it
-- (the header says how that was found)
StreamMarkdown.REFRESH = "ui"

--- Whether a request's answer streams into this view, pure (`features` = the
--- request's own): the setting, on unless turned off; an answer that is
--- prose (features.plain_streaming marks one that is data, an X-Ray build's
--- JSON, which this view would flow into one paragraph); and a window that
--- will show the answer as Markdown: Plain Text in a dictionary window when
--- Text Mode for Dictionary says so (the viewer's own rule), else the chat's
--- own MD/TXT tap, else the View Mode.
function StreamMarkdown.applies(features)
    if type(features) ~= "table" or features.stream_markdown == false or features.plain_streaming then
        return false
    end
    if require("koassistant.ui.chatgptviewer").dictionaryPlainText(features) then return false end
    if features._chat_view_mode ~= nil then return features._chat_view_mode == true end
    return features.render_markdown ~= false
end

-- What a stream's updates cost, for a report from a device (Console Debug):
-- the work of every drawing since the last paint (the conversion, the
-- layout), closed by the paint that shows it. Texts under SHORT bytes (the
-- waiting animation, the first words) are left out. One counter for both
-- stream views.
local Stats = {}
Stats.__index = Stats

function Stats.new()
    return setmetatable({ n = 0, conversion = 0, layout = 0, paint = 0, max = 0, gap = 0 }, Stats)
end

function Stats:work(kind, seconds, bytes)
    bytes = bytes or 0
    if bytes > (self.bytes or 0) then self.bytes = bytes end
    if bytes < StreamMarkdown.SHORT then return end
    local open = self.open or { conversion = 0, layout = 0 }
    self.open = open
    open[kind] = open[kind] + seconds
end

function Stats:painted(at, seconds)
    local open = self.open
    if not open then return end
    self.open = nil
    self.n = self.n + 1
    self.conversion = self.conversion + open.conversion
    self.layout = self.layout + open.layout
    self.paint = self.paint + seconds
    local cost = open.conversion + open.layout + seconds
    if cost > self.max then self.max = cost end
    if self.last_at and at - self.last_at > self.gap then self.gap = at - self.last_at end
    self.first_at = self.first_at or at
    self.last_at = at
end

function Stats:line()
    if self.n == 0 then return string.format("no update of a long text (%d bytes at the most)", self.bytes or 0) end
    local seconds = self.last_at - self.first_at
    local n = self.n
    local function ms(total) return math.floor(total * 1000 / n + 0.5) end
    return string.format("%d updates in %.1f s (%.1f a second); an update took %d ms on average "
        .. "(conversion %d, layout %d, paint %d), %d ms at most; the longest wait between two %.2f s; "
        .. "%d bytes at the most",
        n, seconds, seconds > 0 and (n - 1) / seconds or 0, ms(self.conversion + self.layout + self.paint),
        ms(self.conversion), ms(self.layout), ms(self.paint), math.floor(self.max * 1000 + 0.5), self.gap,
        self.bytes or 0)
end
StreamMarkdown.Stats = Stats

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
--- after it is). A list item after the cut is no trouble: the library would
--- have carried the list on where the piece starts a new one, and the lists
--- that only white space separates are joined when the pieces are finished
--- (koassistant/ui/list_numbers.lua; until then such a line was no cut). And
--- the passes before the library must have nothing open there (marksClosed).
--- A text that stays open (a stray backtick) is converted whole from there
--- on, as before.
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
            if after_blank and not in_fence and (prev_at_margin or (nl and atMargin(line))) then
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

-- The line under a table's header as the viewer's table pass reads it
-- (preprocessMarkdownTables: that line makes the two a table), a line of a
-- table as it reads one, and a line that may still become the first
local TABLE_RULE = "^%s*|?[%s%-:]+|[%s%-:|]+$"
local TABLE_ROW = "^%s*|.*|%s*$"
local TABLE_RULE_SO_FAR = "^%s*|[%s%-:|]*$"

-- A table still arriving: the offset from which the text is held back for
-- the render, or nil. The lines at the text's end that start with a pipe are
-- read (the last one may have no line end yet):
-- - the second of them is the line under a header: the table is there, and
--   a row after it that is still arriving waits until its line ends (it
--   showed as a line of pipes under the table, then jumped into it);
-- - a single such line, or one with the start of the line under a header
--   below it: it may become a table's header, and waits to be one (up to
--   HEADER_HOLD bytes; a line of prose that starts with a pipe shows once it
--   is longer than that, or ends without a closing pipe).
local function tableHold(text)
    local stop = #text
    local open = text:byte(stop) ~= 10      -- the last line has no line end yet
    if not open then stop = stop - 1 end
    local lines, first, last_start = 0, nil, nil
    while stop >= 1 do
        local from = stop
        while from >= 1 and text:byte(from) ~= 10 do from = from - 1 end
        local at = from + 1
        -- starts with a pipe, after spaces or tabs only
        local i = at
        while i <= stop and (text:byte(i) == 32 or text:byte(i) == 9) do i = i + 1 end
        if i > stop or text:byte(i) ~= 124 then break end
        lines = lines + 1
        first = at
        last_start = last_start or at
        stop = from - 1
    end
    if lines == 0 then return nil end
    local first_end = text:find("\n", first, true)
    local header = text:sub(first, (first_end or #text + 1) - 1)
    if lines == 1 then
        if #header > StreamMarkdown.HEADER_HOLD then return nil end
        if open or header:find(TABLE_ROW) then return first end
        return nil
    end
    local second_end = text:find("\n", first_end + 1, true)
    local second = text:sub(first_end + 1, (second_end or #text + 1) - 1)
    if second:find(TABLE_RULE) then
        -- a table: its newest row waits for its line end
        if open and lines >= 3 then return last_start end
        return nil
    end
    if lines == 2 and open and second:find(TABLE_RULE_SO_FAR) and header:find(TABLE_ROW)
        and #header + #second <= StreamMarkdown.HEADER_HOLD then
        return first
    end
    return nil
end

--- The text as it stands mid-stream, readied for the render: what its last
--- line opened and has not closed yet is closed (a bold pair, a code tick, a
--- link's parenthesis: the link shows its words while its address arrives),
--- a last line that is so far only a block's mark (a list item's dash or
--- number, a heading's hashes, a quote's bracket) waits for its first word
--- instead of showing as a stray "-", and a table's row waits until it is
--- whole (tableHold). Never inside an open code fence. Pure; display only
--- (the text itself is never changed).
function StreamMarkdown.healTail(text)
    if type(text) ~= "string" or text == "" then return text end
    local from = #text
    while from >= 1 and text:byte(from) ~= 10 do from = from - 1 end
    local last = text:sub(from + 1)
    if last:match("^%s*```") then return text end
    local hold = tableHold(text)
    if last == "" and not hold then return text end
    local fences = 0
    for line in text:gmatch("[^\n]+") do
        if line:match("^%s*```") then fences = fences + 1 end
    end
    if fences % 2 == 1 then return text end
    if hold then return text:sub(1, hold - 1) end
    if last:match("^%s*[-*+>]%s*$") or last:match("^%s*%d+[.)]?%s*$") or last:match("^%s*#+%s*$") then
        return text:sub(1, #text - #last)
    end
    local _ticked, ticks = last:gsub("`", "")
    -- inside a code span nothing else is markup
    if ticks % 2 == 1 then return text .. "`" end
    local closing = ""
    -- a link whose address is still arriving (no space, no parenthesis in it so far)
    if last:find("](", 1, true) and last:gsub("`[^`]*`", ""):find("%[[^%[%]]+%]%([^%s()]*$") then
        closing = ")"
    end
    local _paired, pairs_of_stars = last:gsub("%*%*", "")
    -- a pair that only just opened has nothing to make bold yet
    if pairs_of_stars % 2 == 1 and not last:match("%*%*%s*$") then closing = closing .. "**" end
    if closing ~= "" then return text .. closing end
    return text
end

--- Where the HTML widget sits inside the box InputDialog gives its input
--- widget, pure: `box` = { width, height, padding, margin } as InputDialog
--- hands them over, `dialog_width` the dialog's own width, `inset` the chat
--- window's space between its frame and its text (its text padding and
--- margin). The chat window that takes the stream's place lays its text out
--- at that inset and at the width it leaves; InputDialog's own insets put
--- this view's text a pixel to the side and made it two pixels wider on a
--- 300 dpi screen, so a word could wrap on another line when the stream ended
--- (B696). The outer size stays what InputDialog expects of the widget.
--- @return table { left, right, top, bottom, width, height }
function StreamMarkdown.place(box, dialog_width, inset)
    local own = (box.padding or 0) + (box.margin or 0)
    local outer_w, outer_h = box.width + 2 * own, box.height + 2 * own
    local place = { left = own, right = own, top = own, bottom = own, width = box.width, height = box.height }
    if not (dialog_width and inset) then return place end
    local width, height = dialog_width - 2 * inset, outer_h - 2 * inset
    local side = (outer_w - width) / 2
    -- a dialog narrower than its input's box, or no room left: its own insets
    if width <= 0 or height <= 0 or side < 0 or side ~= math.floor(side) then return place end
    return { left = side, right = side, top = inset, bottom = inset, width = width, height = height }
end

function StreamMarkdown:init()
    self.text = self.text or ""
    local Viewer = require("koassistant.ui.chatgptviewer")
    local place = StreamMarkdown.place(self, self.parent and self.parent.width,
        Viewer.text_padding and Viewer.text_margin and (Viewer.text_padding + Viewer.text_margin) or nil)
    self.inner_width, self.inner_height = place.width, place.height
    self[1] = FrameContainer:new{
        bordersize = 0,
        margin = 0,
        padding = 0,
        padding_left = place.left,
        padding_right = place.right,
        padding_top = place.top,
        padding_bottom = place.bottom,
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
    local css, font_dir = Viewer.viewerCSS(opts.text_align, opts.features, html_body)
    return ScrollHtmlWidget:new{
        html_body = html_body,
        css = css,
        html_resource_directory = font_dir,
        default_font_size = Screen:scaleBySize(opts.font_size or 20),
        width = self.inner_width or self.width,
        height = self.inner_height or self.height,
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

-- The text as HTML for a drawing: the kept conversion, the raw text when the
-- pipeline fails
function StreamMarkdown:_html(text)
    local opts = self:_opts()
    self.kept = self.kept or { text = "", html = "" }
    local ok, html = pcall(StreamMarkdown.convert, self.kept, text,
        { features = opts.features, text_align = opts.text_align })
    if not ok or type(html) ~= "string" then
        logger.warn("KOAssistant: Markdown stream render failed:", tostring(html))
        self.kept.off = true
        html = "<pre>" .. text:gsub("&", "&amp;"):gsub("<", "&lt;") .. "</pre>"
    end
    return html
end

-- A drawing of the text as it stands, unless it would show what is shown:
-- what arrived since is held back for now (a table's row still arriving, a
-- list item's dash), and laying the same page out again would only cost
function StreamMarkdown:_draw()
    local text = self.text or ""
    local t0 = StreamMarkdown._now()
    local html = self:_html(text)
    if html == self.html and self.scroll_w then
        self:_dropPending()
        self.rendered = text
        self.same = (self.same or 0) + 1
        return
    end
    self._ready = { html = html, cost = StreamMarkdown._now() - t0 }
    self:initTextBox()
end

--- The render: the text through the viewer's pipeline into a new HTML widget
--- in place of the old one; the last page while following, the reader's page
--- otherwise. The handler wraps this method to re-hook each new widget.
function StreamMarkdown:initTextBox()
    local text = self.text or ""
    local ready = self._ready
    self._ready = nil
    local started = StreamMarkdown._now()
    local html, conversion = ready and ready.html, ready and ready.cost
    if not html then
        html = self:_html(text)
        local now = StreamMarkdown._now()
        conversion, started = now - started, now
    end
    self.html = html
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
    -- the conversion's and the layout's cost now; the page is rastered when
    -- it is painted, and paintTo adds that
    local layout = self.rendered_at - started
    self.cost = conversion + layout
    self._paint_owed = true
    self.floor = math.max(StreamMarkdown.FLOOR, self.cost * StreamMarkdown.COST_FACTOR)
    self.renders = (self.renders or 0) + 1
    self.stats = self.stats or Stats.new()
    self.stats:work("conversion", conversion, #text)
    self.stats:work("layout", layout, #text)
    -- the text area alone, no flash
    UIManager:setDirty(self.parent, function() return StreamMarkdown.REFRESH, self.dimen end)
end

--- The first paint after a render rasters the new page: part of what the
--- render costs, counted into the floor
function StreamMarkdown:paintTo(bb, x, y)
    local t0 = StreamMarkdown._now()
    if InputContainer.paintTo then InputContainer.paintTo(self, bb, x, y) end
    if self._paint_owed then
        self._paint_owed = nil
        local seconds = StreamMarkdown._now() - t0
        self.cost = (self.cost or 0) + seconds
        self.floor = math.max(StreamMarkdown.FLOOR, self.cost * StreamMarkdown.COST_FACTOR)
        if self.stats then self.stats:painted(t0, seconds) end
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
        if not self._closed and self.text ~= self.rendered then self:_draw() end
    end
    self._pending = task
    UIManager:scheduleIn(seconds, task)
end

function StreamMarkdown:setText(text)
    self.text = text or ""
    local due, left = StreamMarkdown.renderDue(self, self.text, StreamMarkdown._now())
    if due then
        self:_draw()
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
    logger.dbg("KOAssistant: Markdown stream closed:", (self.stats or Stats.new()):line()
        .. string.format(", %d of them converted once; %d drawings left out as nothing new showed",
            self.kept and #self.kept.text or 0, self.same or 0))
    -- one clean refresh at the end, as the plain stream widget does
    UIManager:setDirty(self.parent, function() return "flashui", self.dimen end)
end

return StreamMarkdown
