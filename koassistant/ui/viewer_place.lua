--[[
The place a chat window shows, found again in another layout of the same text:
the view switched between Markdown and plain text, the window's size toggled,
the screen rotated.

Pages and lines do not carry over between two layouts (a ratio of them lands a
page or several lines off, and a page is a whole screen), so the place is kept
as the first words on screen plus how far through the text they stood. The new
layout shows the copy of those words nearest that far through.

The viewer reads its widgets and calls these (koassistant/ui/chatgptviewer.lua
capturePlace / restorePlace); pageText also serves the Markdown stream view.
tests/unit/test_viewer_place.lua, tests/scenarios/s12_window_place.lua.
]]
local ScopeResolver = require("koassistant.request.scope_resolver")

local Place = {}

-- What the plain-text view writes into a line and the Markdown view draws
-- instead of writing: the heading marks, the bullet, the quote bar, the rule,
-- and the direction marks put after a bold run.
local DECORATION = { "▉", "◤", "◆", "✿", "❖", "·", "•", "│", "─", "\226\128\142", "\226\128\143" }

-- What may stand between two words: whitespace, ASCII punctuation (the plain
-- text keeps *italic* and 'code' marks the Markdown view drops), and the bytes
-- of the decoration above (the middle dot and the no-break space, lead byte
-- C2; the rest in U+2000 to U+2FFF, lead byte E2).
local SEPARATOR = "[%s%p\194\226\128-\191]+"

-- A place is named by at most this many words and bytes (a script written
-- without spaces gives one long word: it is cut), and needs this many bytes
-- to be told from another
local MAX_WORDS, MAX_BYTES, MIN_BYTES = 8, 96, 12

--- The words of a text: runs of bytes that are neither whitespace nor ASCII
--- punctuation, the plain-text view's decoration left out. At most `limit`.
function Place.words(text, limit)
    local out = {}
    if type(text) ~= "string" then return out end
    for _i, mark in ipairs(DECORATION) do
        text = text:gsub(mark, " ")
    end
    for word in text:gmatch("[^%s%p]+") do
        out[#out + 1] = word
        if limit and #out >= limit then break end
    end
    return out
end

--- The words that name a place: the first ones of what the window shows, nil
--- when there is too little to find again.
function Place.anchor(visible_text)
    local words, bytes = {}, 0
    for _i, word in ipairs(Place.words(visible_text, MAX_WORDS)) do
        if bytes + #word > MAX_BYTES then
            word = ScopeResolver.utf8Head(word, MAX_BYTES - bytes)
            if word ~= "" then
                words[#words + 1] = word
                bytes = bytes + #word
            end
            break
        end
        words[#words + 1] = word
        bytes = bytes + #word
    end
    if bytes < MIN_BYTES then return nil end
    return words
end

--- Where `words` stand in `text`, in order, whatever separates them: the byte
--- position of the copy nearest `expected` (a byte position; the first copy
--- without one), nil when the text does not hold them.
function Place.find(text, words, expected)
    if type(text) ~= "string" or type(words) ~= "table" or #words == 0 then return nil end
    -- no word boundary is asked before the first word: a direction mark may
    -- stand right against it, and several words in a row name one place anyway
    local pattern = table.concat(words, SEPARATOR)
    local best, best_distance
    local from = 1
    while true do
        local at = text:find(pattern, from)
        if not at then break end
        local distance = expected and math.abs(at - expected) or 0
        if not best or distance < best_distance then
            best, best_distance = at, distance
        end
        -- copies only get farther once past the expected position
        if not expected or at >= expected then break end
        from = at + 1
    end
    return best
end

--- The page on which the copy of `words` nearest `expected_page` starts.
--- `pages` = { { number = n, text = "the page's words" }, ... } in order (the
--- pages around the expected one; a copy may run over a page's end). Nil when
--- none of them holds the words.
function Place.findPage(pages, words, expected_page)
    if type(pages) ~= "table" or #pages == 0 then return nil end
    local parts, starts, at, expected = {}, {}, 1, nil
    for i, page in ipairs(pages) do
        starts[i] = at
        parts[i] = page.text or ""
        if page.number == expected_page then expected = at end
        at = at + #parts[i] + 1
    end
    local found = Place.find(table.concat(parts, " "), words, expected)
    if not found then return nil end
    for i = #starts, 1, -1 do
        if starts[i] <= found then return pages[i].number end
    end
    return pages[1].number
end

--- The line of a line table (TextBoxWidget's vertical_string_list: each entry's
--- `offset` = its first character) that holds character `char_pos`.
function Place.lineOfChar(lines, char_pos)
    if type(lines) ~= "table" then return nil end
    for i = #lines, 1, -1 do
        if (lines[i].offset or 1) <= char_pos then return i end
    end
    return 1
end

--- The byte at which character `n` of a UTF-8 text starts (past the end: the
--- text's length plus one).
function Place.byteOfChar(text, n)
    local count, i, len = 0, 1, #text
    while i <= len do
        count = count + 1
        if count >= n then return i end
        local b = text:byte(i)
        i = i + (b < 0x80 and 1 or b < 0xE0 and 2 or b < 0xF0 and 3 or 4)
    end
    return len + 1
end

--- The character a byte position falls in (1-based)
function Place.charOfByte(text, byte_pos)
    local _stripped, chars = text:sub(1, byte_pos - 1):gsub("[^\128-\191]", "")
    return chars + 1
end

-- A character of a script written without spaces (CJK, kana, Hangul): MuPDF
-- hands such text back in odd segments, which join back without a space
local function spaceless(ch)
    local b = ch:byte(1)
    return b ~= nil and b >= 0xE3 and b <= 0xED
end

--- The words of a page of an HTML widget's document (`box` = the
--- HtmlBoxWidget), joined by a space except between two spaceless-script
--- segments. "" when the page cannot be read.
function Place.pageText(box, n)
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

return Place
