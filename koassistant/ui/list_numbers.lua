--[[
The numbers of a numbered list, kept as the answer wrote them (B691).

The Markdown library gives a list its items and nothing else: the numbers are
gone, and it makes one list per item whenever a blank line separates the
items. MuPDF then numbers every list from 1 and has no way to be told another
start (its counter resets per block; no `start`, no `value`). So the shape
models write most for longer items showed 1., 1., 1., a list that goes on
after a paragraph, a quote, a table or bullets at the margin began again at
1, and a list that starts at 3 showed 1.

Two steps around the library, both pure:
  mark(source)   before it: every numbered item at the margin carries its own
                 number into its text, between two private-use characters;
  resolve(html)  after it, on the whole document: lists that only white space
                 separates are one list (CommonMark's own rule for items with
                 blank lines between them); a list that starts at 1 stays a
                 list, whatever numbers its later items were written with
                 (every item written "1." is a common way to write one, and
                 CommonMark reads the first number alone); a list that starts
                 anywhere else is written as paragraphs that count on from
                 its own first number, and so is the list it goes on from
                 (1. as a list item and 2. as a paragraph would not line up).
The mark is an item's own and the decision is taken on the whole document, so
a text converted in pieces cut at blank lines (the Markdown stream view) gives
the HTML the whole conversion gives.

Not covered: a numbered list inside another numbered list (the outer one is
left as the library made it), and an item indented under another item.
]]

local ListNumbers = {}

local OPEN, CLOSE = "\238\128\128", "\238\128\129"   -- U+E000, U+E001 (private use)
local MARK = OPEN .. "(%d+)" .. CLOSE

--- The source with each numbered item at the margin carrying its number.
--- Lines inside a code fence are left alone.
function ListNumbers.mark(source)
    if type(source) ~= "string" or not source:find("%d[.)]%s") then return source end
    local out, in_fence = {}, false
    for each in (source .. "\n"):gmatch("([^\n]*)\n") do
        local line = each   -- (a loop's own variable cannot be assigned to in Lua 5.5, which runs the unit suite)
        if line:find("^%s*```") or line:find("^%s*~~~") then
            in_fence = not in_fence
        elseif not in_fence then
            local num, sep, gap, rest = line:match("^(%d+)([.)])(%s+)(.*)$")
            if num and #num <= 9 then
                line = num .. sep .. gap .. OPEN .. num .. CLOSE .. rest
            end
        end
        out[#out + 1] = line
    end
    return table.concat(out, "\n")
end

-- Where an item's own line ends and a block inside it begins
local BLOCK_TAGS = { "<ul", "<ol", "<p[%s>]", "<pre", "<blockquote", "<table", "<div", "<h%d" }
local function leadAndRest(text)
    local at
    for _idx, tag in ipairs(BLOCK_TAGS) do
        local s = text:find(tag)
        if s and (not at or s < at) then at = s end
    end
    if not at then return text, "" end
    return text:sub(1, at - 1), text:sub(at)
end

-- The items of a list's body, each with what stands under it: the text of
-- the item itself and, after it, the lists that follow it before the next
-- item (the Markdown library puts an item's bullets after the item, not
-- inside it; either way they end up after the item's own line)
local function itemsOf(body)
    local opens, depth, pos = {}, 0, 1
    while true do
        local s, e, close, name = body:find("<(/?)(%a+)[^>]*>", pos)
        if not s then break end
        if name == "ul" or name == "ol" then
            depth = depth + (close == "" and 1 or -1)
        elseif name == "li" and depth == 0 then
            opens[#opens + 1] = { s = s, e = e, close = close == "/" }
        end
        pos = e + 1
    end
    local items = {}
    for i, tag in ipairs(opens) do
        if not tag.close then
            -- up to the next item's opening tag, the item's own closing tag taken out
            local stop, own_close = #body + 1, nil
            for j = i + 1, #opens do
                if opens[j].close then
                    own_close = own_close or opens[j]
                else
                    stop = opens[j].s
                    break
                end
            end
            local text
            if own_close then
                text = body:sub(tag.e + 1, own_close.s - 1) .. body:sub(own_close.e + 1, stop - 1)
            else
                text = body:sub(tag.e + 1, stop - 1)
            end
            items[#items + 1] = text
        end
    end
    return items
end

--- The HTML with its numbered lists as the answer numbered them.
function ListNumbers.resolve(html)
    if type(html) ~= "string" then return html end
    html = html:gsub("</ol>%s*<ol>", ""):gsub("</ul>%s*<ul>", "")
    if not html:find(OPEN, 1, true) then return html end

    -- Every numbered list whose items all carry a number, in document order
    local lists, pos = {}, 1
    while true do
        local s, e, body = html:find("<ol>(.-)</ol>", pos)
        if not s then break end
        if body:find("<ol>", 1, true) then
            pos = s + 4   -- a list inside a list: the outer one stays, the inner is looked at next
        else
            local items, first = {}, nil
            for _idx, item in ipairs(itemsOf(body)) do
                local num, text = item:match("^%s*" .. MARK .. "(.*)$")
                if not num then
                    items = nil
                    break
                end
                first = first or tonumber(num)
                items[#items + 1] = text
            end
            if items and #items > 0 then
                lists[#lists + 1] = { s = s, e = e, items = items, first = first, as_text = first ~= 1 }
            end
            pos = e + 1
        end
    end

    -- A list that the next one goes on from is written the way the next one is
    for k = #lists - 1, 1, -1 do
        local this, after = lists[k], lists[k + 1]
        if after.as_text and after.first == this.first + #this.items then
            this.as_text = true
        end
    end

    local out, at = {}, 1
    for _idx, list in ipairs(lists) do
        if list.as_text then
            out[#out + 1] = html:sub(at, list.s - 1)
            for n, text in ipairs(list.items) do
                local lead, rest = leadAndRest(text)
                out[#out + 1] = "<p>" .. (list.first + n - 1) .. ". " .. lead .. "</p>" .. rest
            end
            at = list.e + 1
        end
    end
    out[#out + 1] = html:sub(at)
    return (table.concat(out):gsub(MARK, ""))
end

return ListNumbers
