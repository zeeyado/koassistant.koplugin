--[[
Markdown while streaming (B562), headless: a child process writes SSE chunks
as a provider would, the stream dialog opens with the Markdown view, the
chunks are rendered through the viewer's pipeline by the app's own MuPDF
(a heading, a list, an emoji span), following shows the last page, a pause
keeps the reader's page while the tail grows, the first step up only stops
the following and the next one goes back a page, which a drawing that was
being held back keeps, and the stream completes with the whole text.
Run: sh tests/scenarios/run.sh <scratch dir> s08_stream_markdown
]]
local S = dofile(os.getenv("KOA_PLUGIN") .. "/tests/scenarios/boot.lua")
local UIManager = require("ui/uimanager")
local ffiutil = require("ffi/util")
local StreamHandler = require("koassistant.request.stream_handler")
local StreamMarkdown = require("koassistant.request.stream_markdown")
-- The stream's child process writes canned chunks to its pipe and never
-- touches the network (the boot's blocks are inherited and would fail it)
S.allowForks()

-- Sixty list items, a heading and an emoji, in chunks of two lines
local function chunkText(i)
    if i == 1 then return "# The title\\n\\nA first line with an emoji 🔍 and **bold**.\\n\\n" end
    return string.format("- Item %d of the list, long enough to wrap on a narrow screen once or twice\\n", i)
end
local N = 60
local function sse(text)
    return 'data: {"choices":[{"index":0,"delta":{"content":"' .. text .. '"},"finish_reason":null}]}\n\n'
end
-- n chunks; after chunk `pause_after` nothing arrives for `pause_seconds`
local function childOf(n, pause_after, pause_seconds)
    return function(_pid, fd)
        for i = 1, n do
            ffiutil.writeToFD(fd, sse(chunkText(i)))
            ffiutil.usleep(60000)
            if i == pause_after then ffiutil.usleep(pause_seconds * 1000000) end
        end
        ffiutil.writeToFD(fd, 'data: {"choices":[{"index":0,"delta":{},"finish_reason":"stop"}]}\n\ndata: [DONE]\n\n')
    end
end
local function expectedOf(n)
    local parts = {}
    for i = 1, n do parts[#parts + 1] = (chunkText(i):gsub("\\n", "\n")) end
    return table.concat(parts)
end

-- The widget's renders, counted through the method the handler wraps too
local renders, last_widget = 0, nil
local orig_init = StreamMarkdown.initTextBox
StreamMarkdown.initTextBox = function(self)
    orig_init(self)
    renders = renders + 1
    last_widget = self
end

--- opts: n = the chunks, pause_after / pause_seconds = a gap in the stream,
--- on_poll(widget) = called while the stream runs
local function run(label, on_first_content, opts)
    opts = opts or {}
    local n = opts.n or N
    local child = childOf(n, opts.pause_after, opts.pause_seconds)
    local expected = expectedOf(n)
    renders, last_widget = 0, nil
    local done, result = false, nil
    local first_seen = false
    StreamHandler:new():showStreamDialog(child, "openai", "gpt-test", {
        stream_markdown = true, features = { render_math = true, enable_emoji_icons = false },
        text_align = "auto", provider_name = "openai", model = "gpt-test",
        poll_interval_ms = 50, display_interval_ms = 100, prompt_chars = 100,
        stream_auto_scroll = true, stream_page_scroll = true, response_font_size = 20,
        large_stream_dialog = true, stream_keep_read_position = true,
    }, function(ok, content) done = true; result = { ok = ok, content = content } end)
    S.waitFor(function()
        if not first_seen and last_widget and last_widget.rendered and last_widget.rendered:find("Item 3", 1, true) then
            first_seen = true
            if on_first_content then on_first_content(last_widget) end
        end
        if opts.on_poll and not done then opts.on_poll(last_widget) end
        return done
    end, 40)
    S.check(done, label .. ": the stream finished")
    S.check(result and result.ok == true, label .. ": completed")
    -- the handler trims the answer's trailing newline, as for every stream
    local want = expected:gsub("%s+$", "")
    S.check(result and result.content == want, label .. ": the whole text arrived")
    if result and result.content ~= want then
        local got = result.content or ""
        local _, items = got:gsub("%- Item ", "")
        S.note(label .. ": got " .. #got .. " bytes, " .. items .. " items, expected " .. #expected
            .. "; tail: " .. got:sub(-80):gsub("\n", "|"))
        local i = 1
        while i <= #expected and expected:sub(i, i) == got:sub(i, i) do i = i + 1 end
        S.note(label .. ": first difference at byte " .. i .. ": expected '" .. expected:sub(i, i + 30):gsub("\n", "|")
            .. "' got '" .. got:sub(i, i + 30):gsub("\n", "|") .. "'")
    end
    S.check(renders >= 3, label .. ": rendered more than twice (" .. tostring(renders) .. " renders)")
    local html = last_widget and last_widget.scroll_w and last_widget.scroll_w.html_body or ""
    S.check(html:find("<h1>The title</h1>", 1, true) ~= nil, label .. ": the heading rendered")
    S.check(html:find('<span class="koa-emoji">🔍</span>', 1, true) ~= nil, label .. ": the emoji in its span")
    -- the render pending at the finish is dropped with the dialog (the finished
    -- chat renders the whole text), and the floor between renders is wall-clock:
    -- the last render holds at least the second half (timing decides the rest)
    local last_item = 0
    for n in html:gmatch("<li>Item (%d+)") do last_item = math.max(last_item, tonumber(n)) end
    S.check(last_item >= n / 2, label .. ": the last render reached past the middle (item " .. last_item .. " of " .. n .. ")")
    return last_widget
end

-- Following: the last page at the end
local w = run("following")
S.check(w and w:pageCount() > 1, "more than one page (" .. tostring(w and w:pageCount()) .. ")")
S.check(w and w:currentPage() == w:pageCount(), "the last page shown while following")
S.shot("following")

-- Paused on page 1 after the first content: the page kept while the tail grows
local w2 = run("paused", function(widget)
    local dialog = widget.parent
    local btn = dialog.button_table:getButtonById("scroll_control")
    if btn then btn.callback() end   -- Autoscroll OFF
    widget.scroll_w:scrollToRatio(0)
end)
S.check(w2 and w2:pageCount() > 1, "paused: more than one page")
S.check(w2 and w2:currentPage() == 1, "paused: the first page kept (page " .. tostring(w2 and w2:currentPage()) .. ")")

-- Steps up while a drawing is held back. On a device a drawing costs enough
-- that the floor between drawings holds one back most of the time (here the
-- floor is set to what a drawing of 0.6 s gives), and the answer stops
-- arriving for a while, so no tick of the handler comes between the reader's
-- steps and the held drawing. The first step up while the view follows only
-- stops the following, the page stays ("stop the page where it is"); the next
-- one goes back a page: the held drawing must keep that page. It showed the
-- last page again, since the view was told about the pause only at the
-- handler's next tick (a reader with page keys, 2026-11-14).
local floor = StreamMarkdown.FLOOR
StreamMarkdown.FLOOR = 2.5
local burst = #expectedOf(60)   -- the text when the answer stops arriving
local step = {}
local w3 = run("steps up before a held drawing", nil, {
    n = 70, pause_after = 60, pause_seconds = 3,
    on_poll = function(widget)
        if not widget then return end
        if step.pressed then
            -- the page the held drawing leaves
            if not step.after_held and not widget._pending then step.after_held = widget:currentPage() end
            return
        end
        -- the whole burst has reached the view, and its drawing is held back
        if widget._pending and #(widget.text or "") == burst and widget:currentPage() > 1 then
            step.pressed = true
            step.before = widget:currentPage()
            widget.text_widget:onScrollUp()   -- what a press of the previous-page key calls
            step.first = widget:currentPage()
            local btn = widget.parent.button_table:getButtonById("scroll_control")
            step.button = btn and btn.text
            widget.text_widget:onScrollUp()
            step.after = widget:currentPage()
        end
    end,
})
StreamMarkdown.FLOOR = floor
S.check(step.pressed == true, "a drawing was held back when the answer stopped arriving, past the first page")
S.check(step.pressed and step.first == step.before and step.button == "Autoscroll OFF ↓",
    "the first step up only stops the following: the page stays (page " .. tostring(step.before) .. " to "
    .. tostring(step.first) .. ", " .. tostring(step.button) .. ")")
S.check(step.pressed and step.after == step.before - 1,
    "the next one goes back a page (page " .. tostring(step.after) .. ")")
S.check(step.pressed and step.after_held == step.after,
    "the held drawing keeps the reader's page (page " .. tostring(step.after_held) .. ", the steps left page "
    .. tostring(step.after) .. ")")
S.check(w3 and step.pressed and w3:currentPage() == step.after,
    "and so does the rest of the answer (page " .. tostring(w3 and w3:currentPage()) .. " of "
    .. tostring(w3 and w3:pageCount()) .. ")")

-- A quiet stream shows the waiting dots in a paragraph after its text (B709).
-- Where the text ends at the foot of a page, the dots land alone on a new
-- one: the view that follows must stay on the text's page, or the answer is
-- gone for as long as the pause lasts. Answers that grow a line at a time, so
-- one of them ends at the foot of the page, each going quiet at its end.
local function lineChunk(i)
    if i == 1 then return "# The title\\n\\nA first line of the answer, with a few words in it.\\n\\n" end
    return string.format("Paragraph %d of the answer.\\n", i)
end
local ViewerPlace = require("koassistant.ui.viewer_place")
local quiet = { runs = 0, measured = 0, spilled = 0, lost = 0 }
for n = 31, 43 do
    last_widget = nil
    local done = false
    local before, with_dots
    StreamHandler:new():showStreamDialog(function(_pid, fd)
        for i = 1, n do
            ffiutil.writeToFD(fd, sse(lineChunk(i)))
            ffiutil.usleep(20000)
        end
        ffiutil.usleep(2000000)
        ffiutil.writeToFD(fd, 'data: {"choices":[{"index":0,"delta":{},"finish_reason":"stop"}]}\n\ndata: [DONE]\n\n')
    end, "openai", "gpt-test", {
        stream_markdown = true, features = { render_math = true }, text_align = "auto",
        provider_name = "openai", model = "gpt-test", poll_interval_ms = 50, display_interval_ms = 100,
        prompt_chars = 100, stream_auto_scroll = true, stream_page_scroll = true, response_font_size = 20,
        large_stream_dialog = true, stream_keep_read_position = true,
    }, function() done = true end)
    S.waitFor(function()
        local widget = last_widget
        if widget and widget.rendered and not done then
            local dots = widget.rendered:find("\n\n%.+%s*$") ~= nil
            if not before and not dots and widget.rendered:find("Paragraph " .. n .. " of the answer", 1, true) then
                before = widget:pageCount()
            elseif before and dots and not with_dots then
                local box = widget.scroll_w.htmlbox_widget
                with_dots = { pages = widget:pageCount(), page = widget:currentPage(),
                    words = ViewerPlace.pageText(box, box.page_number) or "" }
            end
        end
        return done
    end, 30)
    quiet.runs = quiet.runs + 1
    if before and with_dots then
        quiet.measured = quiet.measured + 1
        if with_dots.pages > before then quiet.spilled = quiet.spilled + 1 end
        if not with_dots.words:find("answer", 1, true) then
            quiet.lost = quiet.lost + 1
            S.note("a quiet stream of " .. n .. " lines: page " .. with_dots.page .. " of " .. with_dots.pages
                .. " holds [" .. with_dots.words:sub(1, 40) .. "]")
        end
    end
end
S.check(quiet.measured == quiet.runs, "every quiet stream showed the waiting dots after its text (" .. quiet.measured .. " of " .. quiet.runs .. ")")
S.check(quiet.spilled >= 1, "in one of them at least the dots landed on a page of their own (" .. quiet.spilled .. ")")
S.check(quiet.lost == 0, "and the view kept the page of the answer's last words in every one (" .. quiet.lost .. " lost)")

StreamMarkdown.initTextBox = orig_init
S.finish()
