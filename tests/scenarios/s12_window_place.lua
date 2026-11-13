--[[
The place a chat window shows, through KOReader's real widgets (TextBoxWidget
for the plain-text view, MuPDF for the Markdown view), on a chat of four long
exchanges: real transcripts (MessageHistory:createResultText), real
ChatGPTViewers.

What a reader must see (the maintainer's device round of 2026-11-13):
- the plain-text view lands on the reply's first line of text. It used to look
  the label up in the stored transcript and use that position in the text the
  widget shows, which is another text (a rule is drawn as fifteen characters,
  bold marks are taken out): a fifth reply opened five lines above its label,
  and a cursor was drawn there, whose placing scrolled the view back;
- switching the view between Markdown and plain text keeps the place (it
  started at the top);
- a window rebuilt for a size toggle or a rotation opens where the reader was
  (the ratio it carried landed a page or several lines off).
]]
local S = dofile(os.getenv("KOA_PLUGIN") .. "/tests/scenarios/boot.lua")
local UIManager = require("ui/uimanager")
local Viewer = require("koassistant.ui.chatgptviewer")
local UIConstants = require("koassistant.ui.constants")
local MessageHistory = require("koassistant.request.message_history")

-- An answer of fourteen paragraphs. Every third word is a mark of its own
-- paragraph (k2p7), so any few words in a row stand at one place in the chat.
local SENTENCE = "the lantern keeper counted the steps to the harbour and wrote each number down one "
    .. "after another until the page was full and the ink ran thin and the tide came in"
local function answer(k)
    local parts = { "# Answer " .. k .. " begins here", "" }
    for p = 1, 14 do
        local mark = "k" .. k .. "p" .. p
        local words, n = { "Paragraph", tostring(p), "of", "answer", k .. ":" }, 0
        for word in SENTENCE:gmatch("%S+") do
            n = n + 1
            -- one bold word an answer: many of them would hide the shift the
            -- rules add (a bold word shortens the shown text, a rule lengthens it)
            words[#words + 1] = (p == 2 and n == 2) and "**lantern**" or word
            if n % 3 == 0 then words[#words + 1] = mark end
        end
        parts[#parts + 1] = table.concat(words, " ") .. "."
        parts[#parts + 1] = ""
        if p == 5 then
            parts[#parts + 1] = "## A second heading in answer " .. k
            parts[#parts + 1] = ""
            parts[#parts + 1] = "- a first point\n- a second point with *emphasis*\n- a third point"
            parts[#parts + 1] = ""
            parts[#parts + 1] = "---"
            parts[#parts + 1] = ""
        end
    end
    return table.concat(parts, "\n")
end

local function chat(exchanges)
    local h = MessageHistory:new("system prompt")
    h:addUserMessage("ctx", true)
    for k = 1, exchanges do
        h:addUserMessage("Question " .. k .. ", please?", false)
        h:addAssistantMessage(answer(k), "model-x")
    end
    return h
end

-- Characters first..last of a UTF-8 string
local function charSlice(text, first, last)
    local out, n = {}, 0
    for ch in text:gmatch("[%z\1-\127\194-\244][\128-\191]*") do
        n = n + 1
        if n > last then break end
        if n >= first then out[#out + 1] = ch end
    end
    return table.concat(out)
end

--- What the window shows: { view, top = the first line or words, all = every
--- word on screen, at, of, cursor }
local function shown(v)
    local w = v.scroll_text_w
    local box = w and w.htmlbox_widget
    if box then
        local page = box.document:openPage(box.page_number)
        local lines = page:getPageText()
        page:close()
        local words = {}
        for _i, line in ipairs(lines) do
            for _j, word in ipairs(line) do words[#words + 1] = word.word end
        end
        return { view = "md", top = table.concat(words, " ", 1, math.min(6, #words)),
            all = table.concat(words, " "), at = box.page_number, of = box.page_count }
    end
    local tw = w.text_widget
    local lines, top = {}, nil
    for i = tw.virtual_line_num, math.min(#tw.vertical_string_list, tw.virtual_line_num + tw.lines_per_page - 1) do
        local line = tw.vertical_string_list[i]
        local text = (line and line.end_offset and line.end_offset >= line.offset)
            and charSlice(tw.text, line.offset, line.end_offset) or ""
        if i == tw.virtual_line_num then top = text end
        lines[#lines + 1] = text
    end
    return { view = "txt", top = top or "", all = table.concat(lines, " "), at = tw.virtual_line_num,
        of = #tw.vertical_string_list, cursor = tw.cursor_restore_bb ~= nil }
end

local function where(s)
    return string.format("%s %s of %s: '%s'", s.view, tostring(s.at), tostring(s.of), (s.top or ""):sub(1, 40))
end

-- Letters and digits only, single spaces: the same in both views
local function plain(text)
    return (text:gsub("[^%w%s]", " "):gsub("%s+", " "):gsub("^ ", ""))
end

-- The first words on screen, to find on the next one
local function firstWords(s)
    local words = {}
    for word in plain(s.all):gmatch("%S+") do
        words[#words + 1] = word
        if #words >= 5 then break end
    end
    return table.concat(words, " ")
end

local function open(h, fields)
    local config = { features = {} }
    local spec = {
        title = "place",
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
local function close(v)
    UIManager:close(v)
    S.settle(1)
end
local function repaint()
    S.settle()
    UIManager:forceRePaint()
end

local h = chat(4)

-- 1. The plain-text view lands on the newest reply's first line of text
local v = open(h, { render_markdown_override = false, scroll_to_last_question = true })
local s = shown(v)
S.check(s.view == "txt", "the chat opens in the plain-text view")
S.check(s.top:find("Answer 4 begins here", 1, true) ~= nil,
    "plain text: the fourth reply's first line tops the window (" .. where(s) .. ")")
S.check(s.cursor ~= true, "and no cursor is drawn in the text")
S.shot("txt_landing")

-- every exchange count: the label's position drifts further with each rule
close(v)
local wrong = {}
for exchanges = 2, 6 do
    local hk = chat(exchanges)
    local vk = open(hk, { render_markdown_override = false, scroll_to_last_question = true })
    local sk = shown(vk)
    if not sk.top:find("Answer " .. exchanges .. " begins here", 1, true) or sk.cursor then
        wrong[#wrong + 1] = exchanges .. " (" .. where(sk) .. ")"
    end
    close(vk)
end
S.check(#wrong == 0, "chats of two to six exchanges all land on their newest reply's first line"
    .. (#wrong > 0 and (", not " .. table.concat(wrong, "; ")) or ""))

-- 2. The view switch keeps the place, both ways, from a place that is no
--    reply's start
v = open(h, { render_markdown_override = false, scroll_to_last_question = true })
v.scroll_text_w:scrollText(1)
repaint()
local before = shown(v)
local needle = firstWords(before)
v:toggleMarkdown()
repaint()
s = shown(v)
S.check(s.view == "md", "the switch shows the Markdown view")
S.check(plain(s.all):find(needle, 1, true) ~= nil,
    "the switch to Markdown shows the words that topped the screen ('" .. needle .. "'; was " .. where(before)
    .. ", now " .. where(s) .. ")")
S.shot("md_after_switch")
v.scroll_text_w:scrollText(-1)
v.scroll_text_w:scrollText(-1)
repaint()
before = shown(v)
needle = firstWords(before)
v:toggleMarkdown()
repaint()
s = shown(v)
-- the line holding the page's first words tops the window: they stand in its
-- first two lines
local at = plain(s.all):find(needle, 1, true)
S.check(s.view == "txt" and at ~= nil and at < 120,
    "the switch to plain text tops the line the page began in ('" .. needle .. "'; was " .. where(before)
    .. ", now " .. where(s) .. ")")
S.shot("txt_after_switch")

-- 3. A window rebuilt in another size opens where the reader was: plain text
before = shown(v)
needle = firstWords(before)
local state = v:captureState()
close(v)
S.check(type(state.place) == "table" and type(state.place.words) == "table",
    "the captured state carries the place (its words: " .. table.concat(state.place and state.place.words or {}, " ") .. ")")
local was_expanded = UIConstants.expandedWindows()
UIConstants.setExpandedWindows(not was_expanded)
v = open(h, { render_markdown_override = false, _initial_place = state.place })
s = shown(v)
S.check(s.view == "txt" and plain(s.top):find(needle:sub(1, 12), 1, true) ~= nil,
    "plain text, the other window size: the same line tops the window ('" .. needle .. "'; was " .. where(before)
    .. ", now " .. where(s) .. ")")
S.shot("txt_other_size")

-- and the Markdown view, from the middle of an older answer
v:toggleMarkdown()
repaint()
v.scroll_text_w:scrollToRatio(0)
v.scroll_text_w:scrollText(1)
v.scroll_text_w:scrollText(1)
v.scroll_text_w:scrollText(1)
repaint()
before = shown(v)
needle = firstWords(before)
state = v:captureState()
close(v)
UIConstants.setExpandedWindows(was_expanded)
v = open(h, { render_markdown_override = true, _initial_place = state.place })
s = shown(v)
S.check(s.view == "md" and plain(s.all):find(needle, 1, true) ~= nil,
    "Markdown, the other window size: the page shown holds the words that topped the old one ('" .. needle
    .. "'; was " .. where(before) .. ", now " .. where(s) .. ")")
S.shot("md_other_size")

-- 4. The top stays the top
v.scroll_text_w:scrollToRatio(0)
repaint()
S.check(v:captureState().place == nil, "a window at its top has no place to carry")
v:toggleMarkdown()
repaint()
s = shown(v)
S.check(s.view == "txt" and s.at == 1, "and a view switch at the top stays at the top")
close(v)

S.finish()
