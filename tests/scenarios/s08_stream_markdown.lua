--[[
Markdown while streaming (B562), headless: a child process writes SSE chunks
as a provider would, the stream dialog opens with the Markdown view, the
chunks are rendered through the viewer's pipeline by the app's own MuPDF
(a heading, a list, an emoji span), following shows the last page, a pause
keeps the reader's page while the tail grows, and the stream completes with
the whole text. Run: sh tests/scenarios/run.sh <scratch dir> s08_stream_markdown
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
local function child(_pid, fd)
    for i = 1, N do
        ffiutil.writeToFD(fd, sse(chunkText(i)))
        ffiutil.usleep(60000)
    end
    ffiutil.writeToFD(fd, 'data: {"choices":[{"index":0,"delta":{},"finish_reason":"stop"}]}\n\ndata: [DONE]\n\n')
end
local expected = {}
for i = 1, N do expected[#expected + 1] = (chunkText(i):gsub("\\n", "\n")) end
expected = table.concat(expected)

-- The widget's renders, counted through the method the handler wraps too
local renders, last_widget = 0, nil
local orig_init = StreamMarkdown.initTextBox
StreamMarkdown.initTextBox = function(self)
    orig_init(self)
    renders = renders + 1
    last_widget = self
end

local function run(label, on_first_content)
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
    S.check(last_item >= N / 2, label .. ": the last render reached past the middle (item " .. last_item .. " of " .. N .. ")")
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

StreamMarkdown.initTextBox = orig_init
S.finish()
