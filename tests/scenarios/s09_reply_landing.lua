--[[
The chat window's reply landing, through KOReader's real HTML widget (MuPDF):
real transcripts (MessageHistory:createResultText), a real ChatGPTViewer, the
pages read back.

What a reader must see (B561, and the audit of 2026-11-12):
- a window that lands on its newest reply opens on a page whose first words
  are the reply's; the question and the "KOAssistant:" label end the page
  before;
- the landed page is never empty, whatever the question's length (the break
  used to ride an empty spacer block that spilled onto a page of its own when
  the label was a page's last line);
- a window that opens at the top (Open Chats at Latest Exchange off, the Chat
  button of a dictionary or translate window) keeps the released layout: the
  reply under a short question on the first page, and after a long one the
  label and its reply together at the top of a page;
- an answer with nothing before its label (an action run with nothing typed)
  has no page holding the label alone.
]]
local S = dofile(os.getenv("KOA_PLUGIN") .. "/tests/scenarios/boot.lua")
local UIManager = require("ui/uimanager")
local Viewer = require("koassistant.ui.chatgptviewer")
local MessageHistory = require("koassistant.request.message_history")

local function pageWords(box, n)
    local ok, page = pcall(box.document.openPage, box.document, n)
    if not ok or not page then return "" end
    local lines = page:getPageText()
    page:close()
    local out = {}
    for _i, line in ipairs(lines) do
        for _j, w in ipairs(line) do out[#out + 1] = w.word end
    end
    return table.concat(out, " ")
end

local function history(spec)
    local h = MessageHistory:new("system prompt")
    if spec.context then h:addUserMessage(spec.context, true) end
    if spec.question then h:addUserMessage(spec.question, false) end
    h:addAssistantMessage(spec.answer, "model-x")
    if spec.q2 then
        h:addUserMessage(spec.q2, false)
        h:addAssistantMessage(spec.a2, "model-x")
    end
    return h
end

-- Open a chat window on a transcript; returns the viewer and its pages
local function show(h, opts)
    opts = opts or {}
    local config = { features = opts.features or {} }
    local v = Viewer:new{
        title = "landing",
        text = h:createResultText(opts.highlight, config),
        configuration = config,
        original_history = h,
        _message_history = h,
        scroll_to_last_question = opts.land,
    }
    UIManager:show(v)
    S.settle()
    UIManager:forceRePaint()
    local box = v.scroll_text_w and v.scroll_text_w.htmlbox_widget
    local r = { viewer = v, count = box and box.page_count or 0, page = box and box.page_number or 0, pages = {} }
    for n = 1, r.count do r.pages[n] = pageWords(box, n) end
    return r
end
local function close(r)
    UIManager:close(r.viewer)
    S.settle(1)
end
local function emptyPages(r)
    local n = 0
    for _i, words in ipairs(r.pages) do
        if not words:find("%S") then n = n + 1 end
    end
    return n
end

local ANSWER = "Paris is the capital of France. It sits on the Seine."
local function question(lines)
    local out = {}
    for i = 1, lines do out[#out + 1] = "This is line " .. i .. " of a question the reader typed in full." end
    return table.concat(out, "\n\n")
end

-- 1. A typed question, the window lands
local r = show(history{ context = "ctx", question = "What is the capital of France?", answer = ANSWER }, { land = true })
S.check(r.count == 2 and r.page == 2, "a first answer lands on its own page (page " .. r.page .. " of " .. r.count .. ")")
S.check(r.pages[2] and r.pages[2]:find("^Paris") ~= nil, "the landed page opens with the reply's first words")
S.check(r.pages[1] and r.pages[1]:find("capital of France%?") ~= nil and r.pages[1]:find("KOAssistant:", 1, true) ~= nil,
    "the question and the label end the page before")
S.shot("landed")
close(r)

-- 2. The same chat opened at the top (Open Chats at Latest Exchange off; the
--    Chat button of a dictionary or translate window)
r = show(history{ context = "ctx", question = "What is the capital of France?", answer = ANSWER }, { land = false })
S.check(r.page == 1, "a window that does not land opens on its first page")
S.check(r.pages[1] and r.pages[1]:find("Paris", 1, true) ~= nil,
    "and the reply is on that page, under its question (" .. r.count .. " page)")
S.shot("top")
close(r)

-- 2b. A long question in a window that opens at the top: the released
--     layout, the label and its reply together at the top of a later page
r = show(history{ context = "ctx", question = question(40), answer = ANSWER }, { land = false })
S.check(r.page == 1 and r.pages[1]:find("line 1 of a question", 1, true) ~= nil, "a long question, no landing: the window opens on the question")
local with_reply
for n, words in ipairs(r.pages) do
    if words:find("Paris", 1, true) then with_reply = n end
end
S.check(with_reply and r.pages[with_reply]:find("KOAssistant:", 1, true) ~= nil
    and r.pages[with_reply]:find("^%s*◉?%s*KOAssistant:") ~= nil,
    "the label and its reply share a page, the label at its top (page " .. tostring(with_reply) .. " of " .. r.count .. ")")
close(r)

-- 3. An action run with nothing typed: the transcript starts with the label
r = show(history{ context = "Summarize the book.", answer = ANSWER }, { land = true })
S.check(emptyPages(r) == 0 and not r.pages[1]:match("^%s*◉?%s*KOAssistant:%s*$"),
    "an answer with nothing before its label has no page holding the label alone (page 1: "
    .. r.pages[1]:sub(1, 40) .. ")")
S.check(r.pages[r.page] and r.pages[r.page]:find("Paris", 1, true) ~= nil, "the reply is on the page the window opens on")
close(r)
r = show(history{ context = "Summarize the book.", answer = ANSWER }, { land = false })
S.check(r.page == 1 and r.pages[1]:find("Paris", 1, true) ~= nil, "the same without a landing: the reply on the first page")
close(r)

-- 4. Every question length from one line to two pages: the landed page opens
--    with the reply and no page of the window is empty (the label as a
--    page's last line used to leave an empty page, and the window on it)
local bad_landing, blank, counted = {}, {}, 0
for lines = 1, 48 do
    r = show(history{ context = "ctx", question = question(lines), answer = ANSWER }, { land = true })
    counted = counted + 1
    if not (r.pages[r.page] and r.pages[r.page]:find("^Paris")) then
        bad_landing[#bad_landing + 1] = lines .. " (page " .. r.page .. " of " .. r.count .. ": '"
            .. tostring(r.pages[r.page]):sub(1, 24) .. "')"
    end
    if emptyPages(r) > 0 then blank[#blank + 1] = tostring(lines) end
    close(r)
end
S.check(#bad_landing == 0, counted .. " question lengths: the landed page always opens with the reply"
    .. (#bad_landing > 0 and (", not at " .. table.concat(bad_landing, "; ")) or ""))
S.check(#blank == 0, "and no page is ever empty"
    .. (#blank > 0 and (" (empty at " .. table.concat(blank, ", ") .. " lines)") or ""))

-- 5. A second exchange: the newest reply is the one landed on
r = show(history{ context = "ctx", question = "What is the capital of France?", answer = ANSWER,
    q2 = "And of Italy?", a2 = "Rome is the capital of Italy." }, { land = true })
S.check(r.pages[r.page] and r.pages[r.page]:find("^Rome") ~= nil, "a second reply: the landed page opens with it")
S.check(r.pages[r.page - 1] and r.pages[r.page - 1]:find("And of Italy", 1, true) ~= nil,
    "its question is on the page before")
S.check(emptyPages(r) == 0, "no empty page")
close(r)

-- 6. A right-to-left reply
r = show(history{ context = "ctx", question = "What is the capital of France?",
    answer = "باريس هي عاصمة فرنسا. تقع على نهر السين." }, { land = true })
S.check(r.page == 2 and r.pages[2] and r.pages[2]:find("باريس", 1, true) ~= nil,
    "a right-to-left reply is landed on the same way")
close(r)

-- 7. "Latest reply on new page" off: no break at all, the landing by page
r = show(history{ context = "ctx", question = "What is the capital of France?", answer = ANSWER },
    { land = true, features = { chat_exchange_page_breaks = false } })
S.check(r.count == 1 and r.pages[1]:find("Paris", 1, true) ~= nil, "with the page break switched off the chat is one page")
close(r)

S.finish()
