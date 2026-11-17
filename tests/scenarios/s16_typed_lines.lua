--[[
A message the reader typed with line breaks in it, in the chat window's two
views, through KOReader's real widgets (B712): a real transcript
(MessageHistory:createResultText), a real ChatGPTViewer, the page MuPDF lays
out.

What a reader must see:
- the Markdown view shows each typed line apart, a paragraph each, as it shows
  a quoted highlight's and a translated page's (it read a line break as a
  space: the message was one block); the Plain Text view shows the lines as
  typed, as it did;
- the typed lines are evenly spaced (a line break tag was tried first: MuPDF
  puts a paragraph's bottom margin after its first tag and after no later one);
- a list the reader typed is still a list, and an answer's own single line
  break is still a space.
]]
local S = dofile(os.getenv("KOA_PLUGIN") .. "/tests/scenarios/boot.lua")
local UIManager = require("ui/uimanager")
local Viewer = require("koassistant.ui.chatgptviewer")
local MessageHistory = require("koassistant.request.message_history")

local QUESTION = "Alpha asks first\nBravo asks second\nCharlie asks third\n\nDelta opens a paragraph\n- echo item\n- foxtrot item"
local ANSWER = "Golf answers\nhotel too.\n\nIndia is next."

local h = MessageHistory:new("system prompt")
h:addUserMessage("ctx", true)
h:addUserMessage(QUESTION, false)
h:addAssistantMessage(ANSWER, "model-x")

local function open(fields)
    local config = { features = {} }
    local spec = {
        title = "typed lines",
        text = h:createResultText(nil, config),
        configuration = config,
        original_history = h,
        _message_history = h,
    }
    for k, value in pairs(fields or {}) do spec[k] = value end
    local v = Viewer:new(spec)
    UIManager:show(v)
    S.settle()
    UIManager:forceRePaint()
    return v
end

-- The lines on screen: { first = the line's first word, text, y } top to bottom
local function lines(v)
    local w = v.scroll_text_w
    local box = w and w.htmlbox_widget
    local out = {}
    if box then
        local page = box.document:openPage(box.page_number)
        for _i, line in ipairs(page:getPageText()) do
            local words = {}
            for _j, word in ipairs(line) do words[#words + 1] = word.word end
            if #words > 0 then
                out[#out + 1] = { first = words[1], text = table.concat(words, " "), y = line.y0 or line[1].y0,
                    x = line[1].x0 }
            end
        end
        page:close()
        return out, "md"
    end
    local tw = w.text_widget
    for i = tw.virtual_line_num, math.min(#tw.vertical_string_list, tw.virtual_line_num + tw.lines_per_page - 1) do
        local line = tw.vertical_string_list[i]
        local text = ""
        if line and line.end_offset and line.end_offset >= line.offset then
            local chars, n = {}, 0
            for ch in tw.text:gmatch("[%z\1-\127\194-\244][\128-\191]*") do
                n = n + 1
                if n > line.end_offset then break end
                if n >= line.offset then chars[#chars + 1] = ch end
            end
            text = table.concat(chars)
        end
        if text:find("%S") then
            out[#out + 1] = { first = text:match("%S+"), text = text, y = i }
        end
    end
    return out, "txt"
end

local function lineOf(list, first)
    for i, line in ipairs(list) do
        if line.first == first then return line, i end
    end
end

local function describe(list)
    local parts = {}
    for _i, line in ipairs(list) do parts[#parts + 1] = line.text end
    return table.concat(parts, " | ")
end

-- 1. The Markdown view
local v = open({ render_markdown_override = true })
local md, view = lines(v)
S.note("Markdown view: " .. describe(md))
S.check(view == "md", "the chat opens in the Markdown view")
local alpha, bravo, charlie, delta = lineOf(md, "Alpha"), lineOf(md, "Bravo"), lineOf(md, "Charlie"), lineOf(md, "Delta")
S.check(alpha and bravo and charlie and alpha.text == "Alpha asks first" and bravo.text == "Bravo asks second"
    and charlie.text == "Charlie asks third", "each typed line stands on a line of its own")
if alpha and bravo and charlie and delta then
    local step = bravo.y - alpha.y
    S.check(math.abs((charlie.y - bravo.y) - step) < 1 and math.abs((delta.y - charlie.y) - step) < 1,
        "evenly spaced, the typed lines and the reader's own paragraph alike ("
        .. string.format("%.1f, %.1f, %.1f", step, charlie.y - bravo.y, delta.y - charlie.y) .. ")")
else
    S.check(false, "the typed lines and the next paragraph are on the page")
end
local echo, foxtrot = lineOf(md, "echo"), lineOf(md, "foxtrot")
S.check(alpha and echo and foxtrot and echo.x > alpha.x + 10 and foxtrot.x == echo.x,
    "the list the reader typed is still a list (its items stand in from the text"
    .. ((alpha and echo) and string.format(": %.0f against %.0f", echo.x, alpha.x) or "") .. ")")
local golf = lineOf(md, "Golf")
S.check(golf and golf.text == "Golf answers hotel too." and lineOf(md, "hotel") == nil,
    "an answer's single line break is still a space")
S.shot("typed_lines_md")
UIManager:close(v)
S.settle(1)

-- 2. The Plain Text view shows the same lines, as it did
v = open({ render_markdown_override = false })
local txt, txt_view = lines(v)
S.note("Plain Text view: " .. describe(txt))
S.check(txt_view == "txt", "the chat opens in the Plain Text view")
S.check(lineOf(txt, "Alpha") and lineOf(txt, "Bravo") and lineOf(txt, "Charlie") and lineOf(txt, "Delta"),
    "plain text: each typed line on a line of its own")
local t_alpha, t_bravo, t_charlie = lineOf(txt, "Alpha"), lineOf(txt, "Bravo"), lineOf(txt, "Charlie")
S.check(t_alpha and t_bravo and t_charlie and t_bravo.y == t_alpha.y + 1 and t_charlie.y == t_bravo.y + 1,
    "with no blank line added between them")
S.shot("typed_lines_txt")

-- 3. The view switch: the window converts its text again, with the lines
v:toggleMarkdown()
S.settle()
UIManager:forceRePaint()
local again = lines(v)
S.check(lineOf(again, "Bravo") ~= nil and lineOf(again, "Charlie") ~= nil,
    "switched to Markdown: the typed lines are apart there too")
UIManager:close(v)
S.settle(1)

S.finish()
