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

local function stripTags(s)
    return (s:gsub("<[^>]+>", ""))
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

-- The blocks of one message (or of a whole document that has no messages)
local function addPieceAttributes(html, opts)
    local align = alignStyle(opts.text_align)
    local block_opts = { use_starts_with_rtl = opts.use_starts_with_rtl, main = Bidi.mainDirection(stripTags(html)) }
    local function dirOf(content)
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
    html = html:gsub("<ol>(.-)</ol>", function(c) return convertList("ol", c) end)
    html = html:gsub("<ul>(.-)</ul>", function(c) return convertList("ul", c) end)

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

    -- Headings
    for _, tag in ipairs({ "h1", "h2", "h3", "h4", "h5", "h6" }) do
        html = html:gsub("<" .. tag .. ">(.-)</" .. tag .. ">", function(content)
            return open(tag, content) .. content .. "</" .. tag .. ">"
        end)
    end
    -- Table cells keep their own attributes (the column's inline alignment),
    -- whose left/right are logical on a right-to-left cell and swap with it
    for _, tag in ipairs({ "th", "td" }) do
        html = html:gsub("<" .. tag .. "(%s[^>]*)>(.-)</" .. tag .. ">", function(attrs, content)
            if dirOf(content) ~= "rtl" then return nil end
            attrs = attrs:gsub("text%-align:%s*left", "text-align:\1")
                :gsub("text%-align:%s*right", "text-align:left")
                :gsub("text%-align:\1", "text-align:right")
            return "<" .. tag .. RTL_ATTRS .. attrs .. ">" .. content .. "</" .. tag .. ">"
        end)
        html = html:gsub("<" .. tag .. ">(.-)</" .. tag .. ">", function(content)
            return open(tag, content) .. content .. "</" .. tag .. ">"
        end)
    end

    -- A right-to-left quote (its paragraphs already carry their own dir)
    html = html:gsub("<blockquote>(.-)</blockquote>", function(content)
        if dirOf(content) == "rtl" then
            return "<blockquote" .. RTL_ATTRS .. QUOTE_RTL .. ">" .. content .. "</blockquote>"
        end
        return "<blockquote>" .. content .. "</blockquote>"
    end)
    return html
end

-- A message starts at a paragraph that opens with its marker: "▶ User:" and
-- "◉ KOAssistant:" in a chat, "▶ " and "◉ " before the text in the compact
-- and translate views
local MESSAGE_STARTS = { "<p>▶", "<p>◉" }

--- Give every block of the HTML its direction.
--- opts.use_starts_with_rtl: see blockDirection; opts.text_align: the viewer's
--- setting ("auto" | "left" | "right" | "justify"). Each message of a chat is
--- judged on its own: its main direction is its own language's (a chat can
--- change language, and a translation follows its original).
function Bidi.addHtmlBidiAttributes(html, opts)
    if not html then return html end
    opts = opts or {}
    -- Whitespace between tags is layout noise to the patterns of the pass
    html = html:gsub(">%s+<", "><")
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
