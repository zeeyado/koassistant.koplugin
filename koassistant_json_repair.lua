--[[--
Best-effort repair of common LLM JSON errors, shared by the quiz and X-Ray parsers.

These run only AFTER strict parsing (direct / fence-stripped / brace-extracted) has already
failed, so they can never make a parseable response worse — at worst they fail to help and the
caller falls through to its next fallback.
]]

local JsonRepair = {}

--- Escape double quotes left unescaped *inside* JSON string values — a common LLM error, e.g.
---   "explanation": "the existence of an "I," a self-aware self"
--- A double quote is treated as the string's closing quote only when the next non-space
--- character is structural (: , } ]) or end of input; otherwise it's an inner quote and gets
--- escaped. Best-effort: genuinely ambiguous cases (an inner quote immediately followed by a
--- comma) can't be resolved and will still fail to decode rather than be silently miscut.
--- @param text string
--- @return string
function JsonRepair.escapeInnerQuotes(text)
    if type(text) ~= "string" then return text end
    local out = {}
    local in_string = false
    local i, n = 1, #text
    while i <= n do
        local c = text:sub(i, i)
        if not in_string then
            out[#out + 1] = c
            if c == '"' then in_string = true end
        elseif c == "\\" then
            -- copy an escape sequence (backslash + next char) verbatim
            out[#out + 1] = c
            if i < n then out[#out + 1] = text:sub(i + 1, i + 1); i = i + 1 end
        elseif c == '"' then
            local j = i + 1
            while j <= n and text:sub(j, j):match("%s") do j = j + 1 end
            local nxt = (j <= n) and text:sub(j, j) or ""
            if nxt == "" or nxt == ":" or nxt == "," or nxt == "}" or nxt == "]" then
                out[#out + 1] = c            -- structural closing quote
                in_string = false
            else
                out[#out + 1] = '\\"'         -- inner quote → escape
            end
        else
            out[#out + 1] = c
        end
        i = i + 1
    end
    return table.concat(out)
end

return JsonRepair
