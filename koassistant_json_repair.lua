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

--- Drop closing braces/brackets that close more than was opened — the other
--- common LLM JSON defect (2026-08-18, root-caused from a live checkpoint
--- build): one stray `}` or `]` in a 16 KB response makes KOReader's bundled
--- LuaJSON die with "decode/state.lua:81: attempt to index field 'active'
--- (a nil value)" instead of a syntax error, which surfaced as the
--- intermittent "X-Ray response is not valid JSON" build failures. Reproduced
--- against the bundled decoder: every unbalanced-close shape crashes there.
---
--- String-aware single pass (escapes honored): a closer is dropped when
--- nothing is open or when it does not match the innermost open bracket;
--- everything else passes through untouched. Balanced input is returned
--- byte-identical, and a MISSING closer is left alone (that failure decodes
--- to a clean syntax error and truncation must not be papered over).
--- @param text string
--- @return string
--- Restore a key's missing OPENING quote: `\n    themes_resolved": [` (seen live
--- 2026-08-25 on a 166K-token flash-lite build; one such key fails the whole
--- artifact). Only a bare identifier that sits at the start of a line (after
--- optional whitespace) and is immediately followed by `":` qualifies, so text
--- inside string values is never touched. Also covers the fully unquoted form
--- `\n    key: ` when the value that follows is structural or a string.
--- @param text string
--- @return string
function JsonRepair.quoteBareKeys(text)
    if type(text) ~= "string" then return text end
    local out = text:gsub('(\n[ \t]*)([%a_][%w_]*)("%s*:)', '%1"%2%3')
    out = out:gsub('(\n[ \t]*)([%a_][%w_]*)(%s*:%s*[%[{"])', '%1"%2"%3')
    return out
end

function JsonRepair.dropExtraClosers(text)
    if type(text) ~= "string" or text == "" then return text end
    local out = {}
    local stack = {}
    local in_string = false
    local i, n = 1, #text
    while i <= n do
        local c = text:sub(i, i)
        if in_string then
            if c == "\\" then
                out[#out + 1] = text:sub(i, i + 1)
                i = i + 2
            else
                if c == '"' then in_string = false end
                out[#out + 1] = c
                i = i + 1
            end
        else
            if c == '"' then
                in_string = true
                out[#out + 1] = c
            elseif c == "{" or c == "[" then
                stack[#stack + 1] = c
                out[#out + 1] = c
            elseif c == "}" or c == "]" then
                local want = (c == "}") and "{" or "["
                if stack[#stack] == want then
                    stack[#stack] = nil
                    out[#out + 1] = c
                end
                -- stray (nothing open, or mismatched): dropped
            else
                out[#out + 1] = c
            end
            i = i + 1
        end
    end
    return table.concat(out)
end

--- Close unclosed braces/brackets on a COMPLETE-looking document — the mirror
--- of dropExtraClosers (2026-08-18, from a live rejected rung the same
--- evening): a response can end on end_turn with full content and one `}` too
--- few, which the bundled decoder reports as "Unclosed elements present".
---
--- The gate is deliberately conservative so real truncation keeps failing
--- visibly: the string-aware scan must end OUTSIDE any string, and the last
--- non-whitespace character must be a COMPLETED value (`}`, `]`, or `"`).
--- A cut mid-string fails the in-string check; a cut after `,` or `:` fails
--- the last-character check; a number cut short (12 of 123) is excluded
--- because digits never pass the gate. Only then are the missing closers
--- appended, innermost first.
--- @param text string
--- @return string
function JsonRepair.closeUnclosed(text)
    if type(text) ~= "string" or text == "" then return text end
    local stack = {}
    local in_string = false
    local i, n = 1, #text
    while i <= n do
        local c = text:sub(i, i)
        if in_string then
            if c == "\\" then
                i = i + 2
            else
                if c == '"' then in_string = false end
                i = i + 1
            end
        else
            if c == '"' then
                in_string = true
            elseif c == "{" or c == "[" then
                stack[#stack + 1] = c
            elseif c == "}" or c == "]" then
                local want = (c == "}") and "{" or "["
                if stack[#stack] == want then stack[#stack] = nil end
            end
            i = i + 1
        end
    end
    if #stack == 0 or in_string then return text end
    local trimmed = text:gsub("%s+$", "")
    local last = trimmed:sub(-1)
    if last ~= "}" and last ~= "]" and last ~= '"' then return text end
    local closers = {}
    for j = #stack, 1, -1 do
        closers[#closers + 1] = (stack[j] == "{") and "}" or "]"
    end
    return trimmed .. table.concat(closers)
end

return JsonRepair
