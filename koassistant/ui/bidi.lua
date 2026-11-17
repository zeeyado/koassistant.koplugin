--[[
The direction pass of the chat viewer's Markdown (HTML) view, pure Lua.

MuPDF lays a block out by its `dir` attribute (probed 2026-10-19 against the
bundled libwrap-mupdf, docs/competitor_delta_2026-10.md section 3.2): an RTL
block aligns to the right, puts a trailing period at its end, orders a Latin
word inside Arabic text correctly, and takes inline `style` (a quote's border
and inset can be mirrored). `text-align: left/right` are LOGICAL under
dir="rtl", so an explicit alignment is swapped on an RTL block. dir="auto" is
first-strong only, so the pass decides the direction itself: a block that
begins in the main direction of its message keeps it, any other block takes
the majority of its tokens, the first strong token breaking a tie. A list
with dir="rtl"
draws NO marker in any configuration, so a list with a right-to-left item
becomes paragraphs with a literal marker; a list without one stays a list.
A table's columns run left to right whatever its direction, so a
right-to-left table's rows are written in reverse (B693).
LTR blocks are left as they are (the body is LTR), so the markers other
passes look for ("<p>◉ KOAssistant:</p>") stay untouched. Direction only:
the fonts of the scripts are the script_fonts pass, which runs after this one.
]]
local Bidi = {}

-- Right-to-left strong letters as UTF-8 byte patterns: Hebrew (U+0590-05FF),
-- Arabic, Syriac, Arabic Supplement, Thaana and NKo (U+0600-07FF), Arabic
-- Extended-A (U+08A0-08FF), the Hebrew and Arabic presentation forms
-- (U+FB1D-FDFF, U+FE70-FEFF)
Bidi.RTL_PATTERNS = {
    "\214[\144-\191]", "\215[\128-\191]",
    "[\216-\223][\128-\191]",
    "\224[\162-\163][\128-\191]",
    "\239\172[\157-\191]", "\239[\173-\183][\128-\191]", "\239[\185-\187][\128-\191]",
}
-- The lead bytes those patterns start with: one find rules most text out
local RTL_LEAD = "[\214-\224\239]"

--- Whether the text holds a right-to-left letter
function Bidi.hasRTL(s)
    if not s or not s:find(RTL_LEAD) then return false end
    for _, p in ipairs(Bidi.RTL_PATTERNS) do
        if s:find(p) then return true end
    end
    return false
end

--- The number of right-to-left letters in the text
function Bidi.countRTL(s)
    if not s or not s:find(RTL_LEAD) then return 0 end
    local n = 0
    for _, p in ipairs(Bidi.RTL_PATTERNS) do
        for _ in s:gmatch(p) do n = n + 1 end
    end
    return n
end

--- A token's direction by its letters: "rtl" when it holds a right-to-left
--- letter, "ltr" for a letter of any other script, nil for digits, punctuation
--- and symbols alone (U+0080-00BF, U+2000-2FFF, U+3000-303F, emoji and the
--- other supplementary planes)
function Bidi.tokenDirection(token)
    if Bidi.hasRTL(token) then return "rtl" end
    if token:find("[A-Za-z]") or token:find("[\195-\225]") or token:find("\227[\129-\191]")
        or token:find("[\228-\239]") then
        return "ltr"
    end
    return nil
end

--- The main direction of a text (tags stripped): the one most of its strong
--- tokens have, nil when neither leads. A message's main direction is the
--- direction of the language it is written in.
--- @return string|nil "rtl" | "ltr"
function Bidi.mainDirection(text)
    if not text or text == "" then return nil end
    if not Bidi.hasRTL(text) then return "ltr" end
    text = text:gsub("&[#%w]+;", " ")
    local rtl, ltr = 0, 0
    for token in text:gmatch("%S+") do
        local d = Bidi.tokenDirection(token)
        if d == "rtl" then rtl = rtl + 1 elseif d == "ltr" then ltr = ltr + 1 end
    end
    if rtl > ltr then return "rtl" elseif ltr > rtl then return "ltr" end
    return nil
end

--- The direction of a block of text (tags stripped). A block whose first
--- strong token has the main direction of its message (opts.main) keeps that
--- direction whatever follows: in an English answer, "Synonyms:" and four
--- Arabic words is an English line (by the majority it was laid out
--- right-to-left, the label on the right with its colon before it), and in
--- an Arabic answer a line that opens in Arabic and lists Latin terms is an
--- Arabic one. Any other block takes the majority of its tokens, the first
--- strong token breaking a tie, so an Arabic paragraph that opens with a
--- Latin name stays right-to-left and an English one that quotes Arabic
--- stays left-to-right. opts.use_starts_with_rtl: the main direction is
--- right-to-left whatever the text holds (the dictionary window of a
--- right-to-left language: a headword, then IPA and an English gloss).
--- @return string "rtl" | "ltr"
function Bidi.blockDirection(text, opts)
    if not text or text == "" then return "ltr" end
    text = text:gsub("&[#%w]+;", " ")
    local rtl, ltr, first = 0, 0, nil
    for token in text:gmatch("%S+") do
        local d = Bidi.tokenDirection(token)
        if d then
            first = first or d
            if d == "rtl" then rtl = rtl + 1 else ltr = ltr + 1 end
        end
    end
    local main = opts and (opts.use_starts_with_rtl and "rtl" or opts.main) or nil
    if first and first == main then return main end
    if rtl > ltr then return "rtl" elseif ltr > rtl then return "ltr" end
    return first or "ltr"
end

--- The minimal popup's direction test: right-to-left letters outnumber
--- Latin ones in the text, or in its first sample_size bytes
function Bidi.hasDominantRTL(text, sample_size)
    if not text or text == "" then return false end
    local check = sample_size and text:sub(1, sample_size) or text
    local rtl = Bidi.countRTL(check)
    if rtl == 0 then return false end
    local latin = 0
    for _ in check:gmatch("[a-zA-Z]") do latin = latin + 1 end
    return rtl > latin
end

-- The tags a word ends at: the words on the two sides of one are two words
local WORD_ENDS = {}
for _i, name in ipairs({ "p", "div", "li", "td", "th", "tr", "h1", "h2", "h3", "h4", "h5", "h6", "blockquote",
    "pre", "table", "ul", "ol" }) do
    WORD_ENDS[name] = true
end

-- The text of a piece of HTML: its tags taken out, a space where a block, a
-- cell or a line ends. (With nothing there, the last word of a block and the
-- first of the next counted as one word, a right-to-left one whenever either
-- was: a table with one Arabic column read as right-to-left as a whole, and
-- so did the paragraph the Markdown library wraps it in, B693.)
local function stripTags(s)
    s = s:gsub("</(%w+)>", function(name)
        if WORD_ENDS[name] then return " " end
    end)
    return (s:gsub("<br%s*/?>", " "):gsub("<[^>]+>", ""))
end

-- An explicit alignment is logical under dir="rtl": the physical side the
-- reader chose needs the other keyword on a right-to-left block
local function alignStyle(text_align)
    if text_align == "left" then return ' style="text-align: right;"' end
    if text_align == "right" then return ' style="text-align: left;"' end
    return ""
end

-- The quote's border and inset mirrored (MuPDF has no logical properties and
-- no attribute selectors, so they ride inline)
local QUOTE_RTL = ' style="border-left: none; border-right: 3px solid #ccc; padding-left: 0; padding-right: 1em;"'

-- A right-to-left block carries its direction alone: the fonts ride the
-- script runs' spans (koassistant/ui/script_fonts.lua, B558, B621)
local RTL_ATTRS = ' dir="rtl"'
-- A left-to-right cell says so: a block that names no direction takes the
-- one of the block it stands in
local LTR_ATTRS = ' dir="ltr"'

-- A cell's inline alignment the other way round
local function swapAlign(attrs)
    return (attrs:gsub("text%-align:%s*left", "text-align:\1")
        :gsub("text%-align:%s*right", "text-align:left")
        :gsub("text%-align:\1", "text-align:right"))
end

-- A row of a table too wide for a grid, stacked as "header: value" lines
-- (the viewer's table step writes these tags; the pass finds them by them)
Bidi.STACK_OPEN = '<div style="margin:0.6em 0; padding-left:0.6em; border-left:2px solid #ccc">'
Bidi.STACK_LINE = '<p style="margin:0.15em 0">'
Bidi.STACK_OPEN_RTL = '<div dir="rtl" style="margin:0.6em 0; padding-right:0.6em; border-right:2px solid #ccc">'
Bidi.STACK_LINE_RTL = '<p dir="rtl" style="margin:0.15em 0">'
local function asPattern(plain_text) return (plain_text:gsub("%p", "%%%0")) end
local STACK_OPEN_PATTERN, STACK_LINE_PATTERN = asPattern(Bidi.STACK_OPEN), asPattern(Bidi.STACK_LINE)

-- The blocks of one message (or of a whole document that has no messages)
local function addPieceAttributes(html, opts)
    local align = alignStyle(opts.text_align)
    -- A piece without one right-to-left letter has no block to mark: a
    -- block's direction is then left-to-right whatever the options say
    -- (blockDirection), and reading every block's words to learn it was most
    -- of this pass on such a text, on every window build and stream drawing.
    -- All that changes there is a "fake" bullet list.
    local plain = not Bidi.hasRTL(html)
    if plain and not html:find("<p>•", 1, true) then return html end
    local block_opts = { use_starts_with_rtl = opts.use_starts_with_rtl,
        main = plain and "ltr" or opts.main or Bidi.mainDirection(stripTags(html)) }
    local function dirOf(content)
        if plain then return "ltr" end
        return Bidi.blockDirection(stripTags(content), block_opts)
    end
    local function open(tag, content)
        if dirOf(content) == "rtl" then
            return "<" .. tag .. RTL_ATTRS .. align .. ">"
        end
        return "<" .. tag .. ">"
    end
    -- Lists: a list with a right-to-left item becomes paragraphs with a literal
    -- marker, each in its own direction (MuPDF draws no marker for a list with
    -- dir="rtl"); a list with none stays a list, with real markers and nesting
    local function convertList(kind, list_content)
        local items, any_rtl = {}, false
        for item in list_content:gmatch("<li>(.-)</li>") do
            local dir = dirOf(item)
            any_rtl = any_rtl or dir == "rtl"
            table.insert(items, { text = item, dir = dir })
        end
        if not any_rtl then return nil end
        local out = {}
        for n, item in ipairs(items) do
            local marker = kind == "ol" and (n .. ". ") or "• "
            if item.dir == "rtl" then
                table.insert(out, "<p" .. RTL_ATTRS .. align .. ">" .. marker .. item.text .. "</p>")
            else
                table.insert(out, "<p>" .. marker .. item.text .. "</p>")
            end
        end
        return table.concat(out)
    end
    if not plain then
        html = html:gsub("<ol>(.-)</ol>", function(c) return convertList("ol", c) end)
        html = html:gsub("<ul>(.-)</ul>", function(c) return convertList("ul", c) end)
    end

    -- Paragraphs; a "fake" bullet list (lines starting with •, which models
    -- write) becomes one paragraph per line, each in its own direction
    html = html:gsub("<p>(.-)</p>", function(content)
        if content:match("\n") and content:match("^•") then
            local out = {}
            for line in content:gmatch("[^\n]+") do
                local text = line:match("^•%s*(.*)$")
                if text then
                    if text ~= "" then table.insert(out, open("p", text) .. "• " .. text .. "</p>") end
                elseif line ~= "" then
                    table.insert(out, open("p", line) .. line .. "</p>")
                end
            end
            return table.concat(out)
        end
        return open("p", content) .. content .. "</p>"
    end)
    if plain then return html end

    -- Headings
    for _, tag in ipairs({ "h1", "h2", "h3", "h4", "h5", "h6" }) do
        html = html:gsub("<" .. tag .. ">(.-)</" .. tag .. ">", function(content)
            return open(tag, content) .. content .. "</" .. tag .. ">"
        end)
    end
    -- Tables (B693). A table has one direction, found the way every block's
    -- is, and a right-to-left table is the left-to-right one mirrored: its
    -- first column on the right, a column's "left" its right side. MuPDF lays
    -- columns out left to right whatever the direction, so the rows of a
    -- right-to-left table are written in reverse, a short row filled up first
    -- so its cells stay in their columns. Each cell keeps the direction of
    -- its own words (a Latin cell in an Arabic table keeps its full stop at
    -- its end) and says it: the Markdown library wraps a table in a
    -- paragraph, a right-to-left one where the table is, and a cell that
    -- named no direction took that paragraph's, so every Latin cell was laid
    -- out right-to-left and every cell sat on the far side of its column.
    -- A column's alignment is logical on a right-to-left cell and physical on
    -- a left-to-right one (MuPDF), so its keyword is swapped where the cell's
    -- direction is not the table's. A table without one right-to-left letter
    -- is left as it is.
    html = html:gsub("(<table[^>]*>)(.-)(</table>)", function(table_open, body, table_close)
        if not Bidi.hasRTL(body) then return nil end
        local table_rtl = dirOf(body) == "rtl"
        local columns = 0
        for row in body:gmatch("<tr[^>]*>(.-)</tr>") do
            local _cells, n = row:gsub("<t[hd][%s>]", "")
            if n > columns then columns = n end
        end
        body = body:gsub("(<tr[^>]*>)(.-)(</tr>)", function(row_open, row, row_close)
            local cells, kind = {}, "td"
            for tag, attrs, content in row:gmatch("<(t[hd])([^>]*)>(.-)</t[hd]>") do
                kind = tag
                local cell_rtl = dirOf(content) == "rtl"
                if cell_rtl ~= table_rtl then attrs = swapAlign(attrs) end
                cells[#cells + 1] = "<" .. tag .. (cell_rtl and RTL_ATTRS or LTR_ATTRS) .. attrs .. ">"
                    .. content .. "</" .. tag .. ">"
            end
            if #cells == 0 then return nil end
            if table_rtl then
                for _n = #cells + 1, columns do cells[#cells + 1] = "<" .. kind .. "></" .. kind .. ">" end
                local n = #cells
                for i = 1, math.floor(n / 2) do cells[i], cells[n + 1 - i] = cells[n + 1 - i], cells[i] end
            end
            return row_open .. table.concat(cells) .. row_close
        end)
        return table_open .. body .. table_close
    end)
    -- A table too wide for a grid is shown as its rows stacked, each a block
    -- of "header: value" lines: a right-to-left row has its rule on the right
    -- and every line laid out right-to-left whatever its own words, so a
    -- Latin line stands at the right under the others
    html = html:gsub(STACK_OPEN_PATTERN .. "(.-)</div>", function(content)
        if dirOf(content) ~= "rtl" then return nil end
        return Bidi.STACK_OPEN_RTL .. content:gsub(STACK_LINE_PATTERN, Bidi.STACK_LINE_RTL) .. "</div>"
    end)

    -- A right-to-left quote (its paragraphs already carry their own dir)
    html = html:gsub("<blockquote>(.-)</blockquote>", function(content)
        if dirOf(content) == "rtl" then
            return "<blockquote" .. RTL_ATTRS .. QUOTE_RTL .. ">" .. content .. "</blockquote>"
        end
        return "<blockquote>" .. content .. "</blockquote>"
    end)
    return html
end

-- The tags that sit inside a line of text (the Markdown library's, the math
-- pass's, the ones a model writes)
local INLINE_TAGS = {}
for _, name in ipairs({ "a", "b", "i", "u", "s", "em", "strong", "code", "strike", "del", "span", "sub", "sup",
    "small", "mark", "kbd", "q", "cite", "abbr", "img", "br" }) do
    INLINE_TAGS[name] = true
end

-- A message starts at a paragraph that opens with its marker: "▶ User:" and
-- "◉ KOAssistant:" in a chat, "▶ " and "◉ " before the text in the compact
-- and translate views
local MESSAGE_STARTS = { "<p>▶", "<p>◉" }

--- Give every block of the HTML its direction.
--- opts.use_starts_with_rtl: see blockDirection; opts.text_align: the viewer's
--- setting ("auto" | "left" | "right" | "justify"). Each message of a chat is
--- judged on its own: its main direction is its own language's (a chat can
--- change language, and a translation follows its original). opts.main
--- ("rtl" | "ltr"): the main direction where the caller knows it and the
--- words would mislead: a dictionary window shows the book's own sentence
--- above the answer with no marker between them, and a long Arabic sentence
--- outvoted a short English definition.
function Bidi.addHtmlBidiAttributes(html, opts)
    if not html then return html end
    opts = opts or {}
    -- Whitespace between two tags is layout noise to the patterns of the
    -- pass, unless both sit inside a line of text: there it is the space
    -- between two words ("**bold** *italic*", two links in a row), which
    -- taking every such gap out glued together
    html = html:gsub("(</?(%w+)[^<>]*>)%s+()%f[<]", function(tag, name, at)
        if INLINE_TAGS[name] and INLINE_TAGS[html:match("^</?(%w+)", at) or ""] then return nil end
        return tag
    end)
    local out, at = {}, 1
    while true do
        local next_start
        for _, marker in ipairs(MESSAGE_STARTS) do
            local s = html:find(marker, at + 1, true)
            if s and (not next_start or s < next_start) then next_start = s end
        end
        out[#out + 1] = addPieceAttributes(html:sub(at, (next_start or 0) - 1), opts)
        if not next_start then break end
        at = next_start
    end
    return table.concat(out)
end

return Bidi
