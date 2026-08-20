local json = require("json")

local ResponseParser = {}

-- Truncation notice appended to responses that hit max tokens
-- This marker is checked by caching logic to avoid caching incomplete responses
ResponseParser.TRUNCATION_NOTICE = "\n\n---\n⚠ *Response truncated: output token limit reached*"

-- Companion marker for a stream the PROVIDER ended early — a mid-stream 5xx, a
-- dropped connection. Distinct from TRUNCATION_NOTICE because the causes are
-- unrelated and so are the remedies: a token limit means ask for less, a provider
-- error means retry. Sharing one notice sent a device report chasing model size and
-- JSON parsing over a Gemini 503 ("experiencing high demand") on a request that had
-- used 2310 of its 32768 tokens. The PREFIX is the stable part — interruptedNotice
-- appends the provider's own message when we have it, so isIncomplete matches on the
-- prefix rather than the whole string.
ResponseParser.INTERRUPTED_PREFIX = "\n\n---\n⚠ *Response interrupted"
ResponseParser.INTERRUPTED_NOTICE = ResponseParser.INTERRUPTED_PREFIX .. ": the provider ended the stream early*"

--- Build the interrupted notice, naming the provider's own error when available.
--- @param detail string|nil Provider error message
--- @return string
function ResponseParser.interruptedNotice(detail)
    if type(detail) == "string" and detail ~= "" then
        -- Flattened: the notice renders as one italic run, and extractApiError can
        -- return a multi-line body (quota details).
        local flat = detail:gsub("%s+", " "):gsub("^%s+", ""):gsub("%s+$", "")
        if flat ~= "" then
            return ResponseParser.INTERRUPTED_PREFIX .. ": " .. flat .. "*"
        end
    end
    return ResponseParser.INTERRUPTED_NOTICE
end

--- True when a response carries EITHER incomplete-response marker. Cache guards
--- must use this rather than a bare TRUNCATION_NOTICE find, or an interrupted
--- response gets stored as if it were whole.
--- @param text string|nil
--- @return boolean
function ResponseParser.isIncomplete(text)
    if type(text) ~= "string" then return false end
    return text:find(ResponseParser.TRUNCATION_NOTICE, 1, true) ~= nil
        or text:find(ResponseParser.INTERRUPTED_PREFIX, 1, true) ~= nil
end

-- Inline marker inserted where a web search ran mid-answer (report 3(b) decision,
-- 2026-07-12): prose the model wrote BEFORE searching is kept — it is a completed
-- text block the model composed knowing it stays visible (there is no overwrite
-- semantic in any provider API; post-search text often references it). Only short
-- pre-search filler ("Let me search the web.") is dropped. Positional, so it lives
-- in the answer text — unlike the per-message indicators.
ResponseParser.WEB_SEARCH_MARKER = "*[Searched the web]*"
-- Pre-search prose segments shorter than this (trimmed) are treated as filler
ResponseParser.WEB_PRESEARCH_FILLER_CHARS = 80

-- Helper to extract <think> tags from content (used by inference providers hosting R1)
local function extractThinkTags(content)
    if not content or type(content) ~= "string" then
        return content, nil
    end
    -- Match <think>...</think> tags (case insensitive, handles newlines)
    local thinking = content:match("<[Tt]hink>(.-)</[Tt]hink>")
    if thinking then
        -- Remove the tags from the content
        local clean = content:gsub("<[Tt]hink>.-</[Tt]hink>", "")
        -- Clean up leading/trailing whitespace
        clean = clean:gsub("^%s+", ""):gsub("%s+$", "")
        return clean, thinking
    end
    return content, nil
end

-- Web-search provenance helpers. Transformers that can see source data return a
-- provenance TABLE in the web_search slot (4th return) instead of bare `true`:
--   { web_search = true, sources = { {url, title}, ... }, queries = { "...", ... } }
-- All existing consumers only test truthiness, so `true` and the table are
-- interchangeable; detailed fields feed the "Show Sources" viewer.
local function addProvSource(prov, url, title)
    if type(url) ~= "string" or url == "" then return end
    prov._seen = prov._seen or {}
    if prov._seen[url] then return end
    prov._seen[url] = true
    prov.sources = prov.sources or {}
    table.insert(prov.sources, {
        url = url,
        title = (type(title) == "string" and title ~= "") and title or nil,
    })
end

local function addProvQuery(prov, query)
    if type(query) ~= "string" or query == "" then return end
    for _idx, existing in ipairs(prov.queries or {}) do
        if existing == query then return end
    end
    prov.queries = prov.queries or {}
    table.insert(prov.queries, query)
end

-- Collapse a provenance accumulator: table when details were captured, else `true`.
local function finishProv(prov)
    prov._seen = nil
    if (prov.sources and #prov.sources > 0) or (prov.queries and #prov.queries > 0) then
        prov.web_search = true
        return prov
    end
    return true
end

-- Book-tool function calls on the OpenAI chat wire → neutral calls array (or nil).
-- Shared by the wave-1 compatible transformers (deepseek/mistral/groq/xai).
-- function.arguments is a JSON STRING (Gemini/Anthropic give tables); type check,
-- not truthiness — an explicit tool_calls:null is the luajson function sentinel.
local function extractOpenAIToolCalls(message)
    if type(message.tool_calls) ~= "table" then return nil end
    local calls = {}
    for _, tool_call in ipairs(message.tool_calls) do
        local fn = tool_call["function"]
        if fn and fn.name and fn.name ~= "web_search" then
            local ok, decoded = pcall(json.decode, fn.arguments or "{}")
            table.insert(calls, {
                id = tool_call.id,
                name = fn.name,
                args = (ok and type(decoded) == "table") and decoded or {},
            })
        end
    end
    if #calls > 0 then return calls end
    return nil
end

-- Format Perplexity citations as clickable footnotes
-- @param citations table: Array of URL strings from Perplexity response
-- @return string: Formatted sources section (or empty string if no citations)
local function formatCitations(citations)
    if not citations or type(citations) ~= "table" or #citations == 0 then
        return ""
    end
    local parts = {}
    for i, url in ipairs(citations) do
        if type(url) == "string" and url ~= "" then
            -- Sanitize URL: strip whitespace (API artifacts break markdown links)
            url = url:gsub("%s", "")
            -- Extract domain for readable link text
            local domain = url:match("^https?://([^/]+)") or url
            -- Remove www. prefix for cleaner display
            domain = domain:gsub("^www%.", "")
            table.insert(parts, string.format("- [%d] [%s](%s)", i, domain, url))
        end
    end
    if #parts == 0 then
        return ""
    end
    -- Markdown list items are block-level — guaranteed separate lines in any renderer
    return "\n\n---\n**Sources:**\n\n" .. table.concat(parts, "\n")
end

-- Collect a mandatory Responses SSE stream into the ordinary response object used
-- by non-streaming parsers. Terminal output is authoritative; output_item.done
-- events backfill items omitted from response.completed at their protocol index.
local function responsesOutputItemKey(item)
    if type(item) ~= "table" then return nil end
    local item_type = tostring(item.type or "item")
    if type(item.id) == "string" and item.id ~= "" then
        return item_type .. ":id:" .. item.id
    end
    if item_type == "function_call" and type(item.call_id) == "string" and item.call_id ~= "" then
        return item_type .. ":call_id:" .. item.call_id
    end
    local ok, encoded = pcall(json.encode, item)
    return ok and (item_type .. ":json:" .. encoded) or nil
end

local function mergeResponsesOutput(completed_items, terminal_items)
    local merged = {}
    local seen = {}
    local function keySeen(item)
        local key = responsesOutputItemKey(item)
        return key, key and seen[key] == true
    end
    local function mark(item, key)
        if key then seen[key] = true end
        return item
    end

    for _, item in ipairs(terminal_items or {}) do
        if type(item) == "table" then
            local key, duplicate = keySeen(item)
            if not duplicate then merged[#merged + 1] = mark(item, key) end
        end
    end

    table.sort(completed_items, function(a, b)
        local ai = type(a.output_index) == "number" and a.output_index or math.huge
        local bi = type(b.output_index) == "number" and b.output_index or math.huge
        if ai == bi then return a.sequence < b.sequence end
        return ai < bi
    end)
    for _, completed in ipairs(completed_items) do
        local item = completed.item
        if type(item) == "table" then
            local key, duplicate = keySeen(item)
            if not duplicate then
                local pos = type(completed.output_index) == "number"
                    and math.max(1, math.min(#merged + 1, completed.output_index + 1))
                    or (#merged + 1)
                table.insert(merged, pos, mark(item, key))
            end
        end
    end
    return merged
end

local function normalizeResponsesStreamError(err)
    -- KOReader's json decodes JSON null to a truthy non-table sentinel; only
    -- tables and strings carry real error information.
    if type(err) == "table" then return err end
    if type(err) == "string" and err ~= "" then return { message = err } end
    return { message = "Unknown streaming error" }
end

function ResponseParser.collectResponsesSSE(body)
    local output = {}
    local terminal
    local stream_error

    -- raw_line stays untouched: generic-for variables are const in Lua 5.4+.
    for raw_line in (tostring(body or "") .. "\n"):gmatch("([^\n]*)\n") do
        local line = raw_line:gsub("\r$", "")
        local data = line:match("^data:%s*(.*)$")
        if data and data ~= "" and data ~= "[DONE]" then
            local ok, event = pcall(json.decode, data)
            if ok and type(event) == "table" then
                if event.type == "response.output_item.done" and type(event.item) == "table" then
                    output[#output + 1] = {
                        item = event.item,
                        output_index = event.output_index,
                        sequence = #output + 1,
                    }
                elseif (event.type == "response.completed" or event.type == "response.incomplete")
                        and type(event.response) == "table" then
                    terminal = event.response
                elseif event.type == "response.failed" then
                    terminal = type(event.response) == "table" and event.response or terminal
                    stream_error = event.error or (terminal and terminal.error)
                elseif event.type == "error" then
                    stream_error = event.error or event
                end
            end
        end
    end

    if not terminal then
        if stream_error then
            terminal = {
                status = "failed",
                error = normalizeResponsesStreamError(stream_error),
                output = {},
            }
        else
            error("Responses SSE ended without a terminal response event")
        end
    end
    terminal.output = mergeResponsesOutput(output, terminal.output)
    if stream_error and not terminal.error then
        terminal.error = normalizeResponsesStreamError(stream_error)
    end
    return json.encode(terminal)
end

-- Response format transformers for each provider
-- Returns: success, content, reasoning (reasoning is optional third return value)
local RESPONSE_TRANSFORMERS = {
    anthropic = function(response)
        if response.type == "error" and response.error then
            return false, response.error.message
        end

        -- Handle extended thinking responses (content array with thinking + text blocks)
        -- Also handles regular responses (content array with just text block)
        -- Web search responses may have multiple text blocks (tool_use blocks are ignored)
        if response.content then
            -- Book-tool function calls: collect tool_use blocks (distinct from web search's
            -- server_tool_use). If present, emit the provider-neutral tool-call shape the runner
            -- + koassistant_api/tool_wire.lua consume. raw_assistant_turn echoes the native content.
            local tool_uses = {}
            for _, block in ipairs(response.content) do
                if block.type == "tool_use" and block.name then
                    table.insert(tool_uses, { id = block.id, name = block.name, args = block.input or {} })
                end
            end
            if #tool_uses > 0 then
                return true, {
                    _tool_calls = true,
                    calls = tool_uses,
                    raw_assistant_turn = { role = "assistant", content = response.content },
                }, nil, nil
            end

            local text_blocks = {}
            local thinking_content = nil
            local web_prov = nil

            -- Look for thinking and text blocks (ignore tool_use blocks).
            -- Prose interleaved with web searches is assembled as SEGMENTS: each
            -- search closes the current segment — substantive prose is kept behind
            -- an inline WEB_SEARCH_MARKER, short filler ("Let me search...") is
            -- dropped. Nothing substantive is ever discarded (report 3(b) decision).
            local segment_start = 1
            local last_was_search = false
            for _, block in ipairs(response.content) do
                if block.type == "thinking" and block.thinking then
                    thinking_content = block.thinking
                elseif block.type == "text" and block.text then
                    table.insert(text_blocks, block.text)
                    last_was_search = false
                elseif block.type == "server_tool_use" or block.type == "web_search_tool_result" then
                    web_prov = web_prov or {}
                    -- Provenance: search queries ride server_tool_use input, result
                    -- URLs ride web_search_tool_result content items
                    if block.type == "server_tool_use" and type(block.input) == "table" then
                        addProvQuery(web_prov, block.input.query)
                    elseif type(block.content) == "table" then
                        for _idx, item in ipairs(block.content) do
                            if type(item) == "table" then
                                addProvSource(web_prov, item.url, item.title)
                            end
                        end
                    end
                    -- Close the current prose segment on the first search block of a
                    -- burst (server_tool_use + its web_search_tool_result = one burst)
                    if not last_was_search then
                        local segment = table.concat(text_blocks, "\n\n", segment_start, #text_blocks)
                        local trimmed = segment:gsub("^%s+", ""):gsub("%s+$", "")
                        if #trimmed < ResponseParser.WEB_PRESEARCH_FILLER_CHARS then
                            -- Filler (or nothing): drop the segment, no marker
                            while #text_blocks >= segment_start do
                                table.remove(text_blocks)
                            end
                        else
                            table.insert(text_blocks, ResponseParser.WEB_SEARCH_MARKER)
                        end
                        segment_start = #text_blocks + 1
                        last_was_search = true
                    end
                end
                -- Other blocks (tool_use) are silently ignored
            end
            -- A search with no prose after it leaves a dangling trailing marker
            if text_blocks[#text_blocks] == ResponseParser.WEB_SEARCH_MARKER then
                table.remove(text_blocks)
            end
            local web_search_used = web_prov and finishProv(web_prov) or nil

            -- Concatenate all text blocks (web search may produce multiple)
            local text_content = nil
            if #text_blocks > 0 then
                text_content = table.concat(text_blocks, "\n\n")
            end

            -- Fallback: first block with text field (legacy format)
            if not text_content and response.content[1] and response.content[1].text then
                text_content = response.content[1].text
            end

            -- Check for truncation (stop_reason: "max_tokens")
            if text_content and response.stop_reason == "max_tokens" then
                text_content = text_content .. ResponseParser.TRUNCATION_NOTICE
            end

            if text_content then
                return true, text_content, thinking_content, web_search_used
            end
        end
        return false, "Unexpected response format"
    end,
    
    openai = function(response)
        -- Check for error response
        if response.error then
            return false, response.error.message or response.error.type or "Unknown error"
        end

        if response.choices and response.choices[1] and response.choices[1].message then
            local message = response.choices[1].message
            local content = message.content
            -- Tool-call messages carry content:null, which KOReader's luajson decodes to a
            -- truthy FUNCTION sentinel — normalize so the truncation concat below can't crash
            -- and the sentinel can't escape as the answer.
            if type(content) ~= "string" then content = nil end
            -- Check for truncation (finish_reason: "length" means max tokens hit)
            local finish_reason = response.choices[1].finish_reason
            if content and content ~= "" and finish_reason == "length" then
                content = content .. ResponseParser.TRUNCATION_NOTICE
            end

            -- Check for web search tool usage in tool_calls
            -- (type check, not truthiness: an explicit tool_calls:null is the luajson sentinel)
            local web_search_used = nil
            if type(message.tool_calls) == "table" then
                for _, tool_call in ipairs(message.tool_calls) do
                    if tool_call.type == "web_search" or
                       (tool_call["function"] and tool_call["function"].name == "web_search") then
                        web_search_used = true
                        break
                    end
                end
            end

            -- Book-tool function calls → neutral shape for the tool runner.
            -- OpenAI's function.arguments is a JSON STRING (Gemini/Anthropic give tables).
            if type(message.tool_calls) == "table" then
                local calls = {}
                for _, tool_call in ipairs(message.tool_calls) do
                    local fn = tool_call["function"]
                    if fn and fn.name and fn.name ~= "web_search" then
                        local ok, decoded = pcall(json.decode, fn.arguments or "{}")
                        table.insert(calls, {
                            id = tool_call.id,
                            name = fn.name,
                            args = (ok and type(decoded) == "table") and decoded or {},
                        })
                    end
                end
                if #calls > 0 then
                    return true, {
                        _tool_calls = true,
                        calls = calls,
                        raw_assistant_turn = message,
                    }, nil, web_search_used
                end
            end

            return true, content, nil, web_search_used
        end
        return false, "Unexpected response format"
    end,
    
    -- OpenAI Responses API (/v1/responses) — used by the openai handler for native
    -- web search (R1) and book-tool sessions (R3, responses_api_plan.md). Typed
    -- output[] items: message (output_text parts + url_citation annotations),
    -- web_search_call (queries), function_call (book tools → neutral shape),
    -- reasoning (summaries — not requested, ignored; replayed via tool_wire).
    -- Pre-search prose keeps the same segment/marker rules as the Anthropic
    -- transformer.
    openai_responses = function(response)
        if type(response.error) == "table" and (response.error.message or response.error.code) then
            return false, response.error.message or response.error.code
        end
        if response.status == "failed" then
            return false, "Request failed"
        end
        if type(response.output) ~= "table" then
            return false, "Unexpected response format"
        end

        local text_blocks = {}
        local web_prov = nil
        local tool_calls = {}
        local segment_start = 1
        local last_was_search = false

        for _, item in ipairs(response.output) do
            if type(item) == "table" then
                if item.type == "function_call" and type(item.name) == "string" then
                    -- Book-tool call → neutral shape for the runner. The matching
                    -- key for function_call_output is call_id (NOT the item id);
                    -- arguments is a JSON STRING like Chat Completions.
                    local args = {}
                    if type(item.arguments) == "string" then
                        local ok, decoded = pcall(json.decode, item.arguments)
                        if ok and type(decoded) == "table" then args = decoded end
                    end
                    table.insert(tool_calls, {
                        id = item.call_id,
                        name = item.name,
                        args = args,
                    })
                elseif item.type == "message" and type(item.content) == "table" then
                    for _idx, part in ipairs(item.content) do
                        if type(part) == "table" and part.type == "output_text"
                                and type(part.text) == "string" and part.text ~= "" then
                            table.insert(text_blocks, part.text)
                            last_was_search = false
                            if type(part.annotations) == "table" then
                                web_prov = web_prov or {}
                                for _j, ann in ipairs(part.annotations) do
                                    if type(ann) == "table" and ann.type == "url_citation" then
                                        addProvSource(web_prov, ann.url, ann.title)
                                    end
                                end
                            end
                        end
                    end
                elseif item.type == "web_search_call" then
                    web_prov = web_prov or {}
                    if type(item.action) == "table" then
                        addProvQuery(web_prov, item.action.query)
                    end
                    -- Close the current prose segment on the first search of a burst
                    if not last_was_search then
                        local segment = table.concat(text_blocks, "\n\n", segment_start, #text_blocks)
                        local trimmed = segment:gsub("^%s+", ""):gsub("%s+$", "")
                        if #trimmed < ResponseParser.WEB_PRESEARCH_FILLER_CHARS then
                            -- Filler (or nothing): drop the segment, no marker
                            while #text_blocks >= segment_start do
                                table.remove(text_blocks)
                            end
                        else
                            table.insert(text_blocks, ResponseParser.WEB_SEARCH_MARKER)
                        end
                        segment_start = #text_blocks + 1
                        last_was_search = true
                    end
                end
                -- reasoning items and other types are silently ignored
            end
        end

        -- A search with no prose after it leaves a dangling trailing marker
        if text_blocks[#text_blocks] == ResponseParser.WEB_SEARCH_MARKER then
            table.remove(text_blocks)
        end
        local web_search_used = web_prov and finishProv(web_prov) or nil

        -- Tool calls take precedence over prose (mirrors the openai transformer);
        -- raw_assistant_turn carries the FULL output array so tool_wire can replay
        -- it verbatim (reasoning items must precede their function calls).
        if #tool_calls > 0 then
            return true, {
                _tool_calls = true,
                calls = tool_calls,
                raw_assistant_turn = { _responses_output = response.output },
            }, nil, web_search_used
        end

        local text_content = #text_blocks > 0 and table.concat(text_blocks, "\n\n") or nil

        -- Truncation: status=incomplete with reason max_output_tokens
        if text_content and response.status == "incomplete"
                and type(response.incomplete_details) == "table"
                and response.incomplete_details.reason == "max_output_tokens" then
            text_content = text_content .. ResponseParser.TRUNCATION_NOTICE
        end

        if text_content then
            return true, text_content, nil, web_search_used
        end
        return false, "Unexpected response format"
    end,

    gemini = function(response)
        -- Check for error response
        if response.error then
            return false, response.error.message or response.error.code or "Unknown error"
        end

        -- Check for direct text response (some Gemini endpoints return this)
        if response.text then
            return true, response.text
        end

        -- Check for standard candidates format
        if response.candidates and response.candidates[1] then
            local candidate = response.candidates[1]
            local finish_reason = candidate.finishReason

            -- Check if web search (grounding) was actually used
            -- Gemini returns groundingMetadata when Google Search grounding is enabled,
            -- but it only contains actual results if search was performed
            local web_search_used = nil
            local gm = candidate.groundingMetadata
            if gm then
                -- Check if any search results are present (not just metadata existence)
                -- webSearchQueries: queries sent to Google Search
                -- groundingChunks: web results with URLs
                -- groundingSupports: text segments with source attribution
                if (gm.webSearchQueries and #gm.webSearchQueries > 0) or
                   (gm.groundingChunks and #gm.groundingChunks > 0) or
                   (gm.groundingSupports and #gm.groundingSupports > 0) then
                    local web_prov = {}
                    if type(gm.webSearchQueries) == "table" then
                        for _idx, q in ipairs(gm.webSearchQueries) do
                            addProvQuery(web_prov, q)
                        end
                    end
                    if type(gm.groundingChunks) == "table" then
                        for _idx, chunk in ipairs(gm.groundingChunks) do
                            local web = type(chunk) == "table" and type(chunk.web) == "table" and chunk.web
                            if web then
                                addProvSource(web_prov, web.uri, web.title)
                            end
                        end
                    end
                    web_search_used = finishProv(web_prov)
                end
            end

            -- Check if MAX_TOKENS before content was generated (thinking models issue)
            if finish_reason == "MAX_TOKENS" and
               (not candidate.content or not candidate.content.parts or #candidate.content.parts == 0) then
                return false, "No content generated (MAX_TOKENS hit before output - increase max_tokens for thinking models)"
            end
            if candidate.content and candidate.content.parts then
                local function_calls = {}
                for _, part in ipairs(candidate.content.parts) do
                    local function_call = part.functionCall or part.function_call
                    if function_call and function_call.name then
                        table.insert(function_calls, {
                            id = function_call.id,
                            name = function_call.name,
                            args = function_call.args or {},
                        })
                    end
                end
                if #function_calls > 0 then
                    -- Provider-neutral tool-call shape consumed by the book-tool runner +
                    -- koassistant_api/tool_wire.lua. raw_assistant_turn is the provider-native
                    -- echo payload (Gemini's candidate.content here).
                    return true, {
                        _tool_calls = true,
                        calls = function_calls,
                        raw_assistant_turn = candidate.content,
                    }, nil, web_search_used
                end

                -- Gemini 3 thinking: parts have thought=true for thinking, thought=false/nil for answer
                local thinking_parts = {}
                local content_parts = {}
                for _, part in ipairs(candidate.content.parts) do
                    if part.text then
                        if part.thought then
                            table.insert(thinking_parts, part.text)
                        else
                            table.insert(content_parts, part.text)
                        end
                    end
                end
                local content = table.concat(content_parts, "\n")
                local thinking = #thinking_parts > 0 and table.concat(thinking_parts, "\n") or nil

                -- If MAX_TOKENS with partial content, append truncation notice
                if content ~= "" and finish_reason == "MAX_TOKENS" then
                    content = content .. ResponseParser.TRUNCATION_NOTICE
                end

                if content ~= "" then
                    return true, content, thinking, web_search_used
                end
            end
        end

        return false, "Unexpected response format"
    end,
    
    deepseek = function(response)
        -- Check for error response
        if response.error then
            return false, response.error.message or response.error.type or "Unknown error"
        end

        if response.choices and response.choices[1] and response.choices[1].message then
            local message = response.choices[1].message
            local content = message.content
            -- Tool-call messages carry content:null → luajson's truthy function sentinel
            if type(content) ~= "string" then content = nil end
            local reasoning = message.reasoning_content  -- DeepSeek reasoner returns this

            -- Book-tool function calls → neutral shape for the tool runner.
            -- raw_assistant_turn keeps message.reasoning_content: DeepSeek V3.2+
            -- REQUIRES it back on replayed tool-call turns (tool_wire echoes it,
            -- deepseek.lua's copy loop forwards it on the wire).
            local calls = extractOpenAIToolCalls(message)
            if calls then
                return true, {
                    _tool_calls = true,
                    calls = calls,
                    raw_assistant_turn = message,
                }, reasoning
            end

            -- Check for truncation
            local finish_reason = response.choices[1].finish_reason
            if content and content ~= "" and finish_reason == "length" then
                content = content .. ResponseParser.TRUNCATION_NOTICE
            end
            return true, content, reasoning
        end
        return false, "Unexpected response format"
    end,
    
    ollama = function(response)
        -- Check for error response
        if response.error then
            return false, response.error
        end

        -- Tool calls (Track 35; probed Ollama 0.17.7): OpenAI-shaped entries,
        -- except `arguments` arrives as a DECODED OBJECT, not a JSON string.
        -- ids are present on 0.17.x. Type-check every level — luajson decodes
        -- JSON null to a truthy function sentinel.
        if response.message and type(response.message.tool_calls) == "table"
                and #response.message.tool_calls > 0 then
            local calls = {}
            for _, tc in ipairs(response.message.tool_calls) do
                local fn = type(tc) == "table" and type(tc["function"]) == "table"
                    and tc["function"] or nil
                if fn and type(fn.name) == "string" then
                    table.insert(calls, {
                        id = type(tc.id) == "string" and tc.id or nil,
                        name = fn.name,
                        args = type(fn.arguments) == "table" and fn.arguments or {},
                    })
                end
            end
            if #calls > 0 then
                return true, {
                    _tool_calls = true,
                    calls = calls,
                    raw_assistant_turn = response.message,
                }, nil, nil
            end
        end

        if response.message and response.message.content then
            local content = response.message.content
            -- Extract <think> tags from R1 models running locally
            local clean_content, reasoning = extractThinkTags(content)
            -- Native think API delivers reasoning in message.thinking instead of
            -- inline tags (#98). Type-checked: luajson null is a truthy sentinel.
            if not reasoning and type(response.message.thinking) == "string"
                    and response.message.thinking ~= "" then
                reasoning = response.message.thinking
            end
            return true, clean_content, reasoning
        end
        return false, "Unexpected response format"
    end,

    -- New providers (OpenAI-compatible)
    groq = function(response)
        if response.error then
            return false, response.error.message or response.error.type or "Unknown error"
        end
        if response.choices and response.choices[1] and response.choices[1].message then
            local message = response.choices[1].message
            local content = message.content
            -- Tool-call messages carry content:null → luajson's truthy function sentinel
            if type(content) ~= "string" then content = nil end

            -- Book-tool function calls → neutral shape for the tool runner
            local calls = extractOpenAIToolCalls(message)
            if calls then
                return true, {
                    _tool_calls = true,
                    calls = calls,
                    raw_assistant_turn = message,
                }
            end

            -- Extract <think> tags from R1 models
            local clean_content, reasoning = extractThinkTags(content)
            return true, clean_content, reasoning
        end
        return false, "Unexpected response format"
    end,

    mistral = function(response)
        if response.error then
            return false, response.error.message or response.error.type or "Unknown error"
        end
        if response.choices and response.choices[1] and response.choices[1].message then
            local message = response.choices[1].message
            local content = message.content

            -- Book-tool function calls → neutral shape for the tool runner.
            -- (The echo replays with content dropped unless it's a string —
            -- tool_wire's openai adapter handles Magistral's table content safely.)
            local calls = extractOpenAIToolCalls(message)
            if calls then
                return true, {
                    _tool_calls = true,
                    calls = calls,
                    raw_assistant_turn = message,
                }
            end

            -- Magistral models return structured content blocks
            if type(content) == "table" then
                local text_parts, think_parts = {}, {}
                for _idx, block in ipairs(content) do
                    if type(block) == "table" then
                        if block.type == "thinking" and block.thinking then
                            for _j, t in ipairs(block.thinking) do
                                if t.text then table.insert(think_parts, t.text) end
                            end
                        elseif block.type == "text" and block.text then
                            table.insert(text_parts, block.text)
                        end
                    end
                end
                local text = table.concat(text_parts, "\n")
                local thinking = #think_parts > 0 and table.concat(think_parts, "\n") or nil
                return true, text, thinking
            end
            -- Non-Magistral models return a string (null sentinel normalized)
            if type(content) ~= "string" then content = nil end
            return true, content
        end
        return false, "Unexpected response format"
    end,

    xai = function(response)
        if response.error then
            return false, response.error.message or response.error.type or "Unknown error"
        end
        if response.choices and response.choices[1] and response.choices[1].message then
            local message = response.choices[1].message
            local content = message.content
            -- Tool-call messages carry content:null → luajson's truthy function sentinel
            if type(content) ~= "string" then content = nil end

            -- Check for live_search tool usage in tool_calls (xAI's web search)
            -- (type check, not truthiness: an explicit tool_calls:null is the sentinel)
            local web_search_used = nil
            if type(message.tool_calls) == "table" then
                for _, tool_call in ipairs(message.tool_calls) do
                    -- xAI uses "live_search" type (not "web_search")
                    if tool_call.type == "live_search" or tool_call.type == "web_search" or
                       (tool_call["function"] and tool_call["function"].name == "live_search") then
                        web_search_used = true
                        break
                    end
                end
            end

            -- xAI returns reasoning_content for grok reasoning models
            local reasoning = message.reasoning_content

            -- Book-tool function calls → neutral shape for the tool runner
            -- (chat wire only — xai.lua never routes tool sessions to Responses)
            local calls = extractOpenAIToolCalls(message)
            if calls then
                return true, {
                    _tool_calls = true,
                    calls = calls,
                    raw_assistant_turn = message,
                }, reasoning, web_search_used
            end

            return true, content, reasoning, web_search_used
        end
        return false, "Unexpected response format"
    end,

    openrouter = function(response)
        if response.error then
            return false, response.error.message or response.error.type or "Unknown error"
        end
        if response.choices and response.choices[1] and response.choices[1].message then
            local message = response.choices[1].message
            local content = message.content
            -- content:null on tool-call messages decodes to luajson's truthy function sentinel
            if type(content) ~= "string" then content = nil end

            -- Check for web search usage via annotations (OpenRouter uses Exa search)
            -- When :online suffix is used, response includes annotations with url_citation type
            local web_search_used = nil
            if type(message.annotations) == "table" then
                local web_prov
                for _, annotation in ipairs(message.annotations) do
                    if type(annotation) == "table" and annotation.type == "url_citation" then
                        web_prov = web_prov or {}
                        if type(annotation.url_citation) == "table" then
                            addProvSource(web_prov, annotation.url_citation.url, annotation.url_citation.title)
                        end
                    end
                end
                web_search_used = web_prov and finishProv(web_prov) or nil
            end

            -- OpenRouter normalizes reasoning to message.reasoning field
            local reasoning = message.reasoning

            -- Book-tool function calls → neutral shape (OpenAI wire: arguments is a JSON string;
            -- type check, not truthiness: an explicit tool_calls:null is the luajson sentinel)
            if type(message.tool_calls) == "table" then
                local calls = {}
                for _, tool_call in ipairs(message.tool_calls) do
                    local fn = tool_call["function"]
                    if fn and fn.name and fn.name ~= "web_search" then
                        local ok, decoded = pcall(json.decode, fn.arguments or "{}")
                        table.insert(calls, {
                            id = tool_call.id,
                            name = fn.name,
                            args = (ok and type(decoded) == "table") and decoded or {},
                        })
                    end
                end
                if #calls > 0 then
                    return true, {
                        _tool_calls = true,
                        calls = calls,
                        raw_assistant_turn = message,
                    }, reasoning, web_search_used
                end
            end

            return true, content, reasoning, web_search_used
        end
        return false, "Unexpected response format"
    end,

    requesty = function(response)
        if response.error then
            return false, response.error.message or response.error.type or "Unknown error"
        end
        if response.choices and response.choices[1] and response.choices[1].message then
            local message = response.choices[1].message
            local content = message.content

            -- Requesty normalizes reasoning to message.reasoning (like OpenRouter);
            -- fall back to reasoning_content used by some backends.
            local reasoning = message.reasoning or message.reasoning_content
            return true, content, reasoning
        end
        return false, "Unexpected response format"
    end,

    qwen = function(response)
        if response.error then
            return false, response.error.message or response.error.type or "Unknown error"
        end
        if response.choices and response.choices[1] and response.choices[1].message then
            local message = response.choices[1].message
            local content = message.content
            -- Tool turns carry content:null (luajson sentinel) or "" — normalize
            if type(content) ~= "string" then content = nil end

            -- Book-tool function calls → neutral shape (tools wave 2, qwen3-max)
            local calls = extractOpenAIToolCalls(message)
            if calls then
                return true, {
                    _tool_calls = true,
                    calls = calls,
                    raw_assistant_turn = message,
                }
            end

            -- Passive extraction: Qwen thinking models return reasoning_content
            local reasoning = type(message.reasoning_content) == "string"
                and message.reasoning_content or nil
            return true, content, reasoning
        end
        return false, "Unexpected response format"
    end,

    kimi = function(response)
        if response.error then
            return false, response.error.message or response.error.type or "Unknown error"
        end
        if response.choices and response.choices[1] and response.choices[1].message then
            local message = response.choices[1].message
            local content = message.content
            -- Tool turns carry content:null (luajson sentinel) or "" — normalize
            if type(content) ~= "string" then content = nil end

            -- Book-tool function calls → neutral shape (kimi-k2.6; kimi.lua
            -- forces thinking off on tool sessions — see model_constraints)
            local calls = extractOpenAIToolCalls(message)
            if calls then
                return true, {
                    _tool_calls = true,
                    calls = calls,
                    raw_assistant_turn = message,
                }
            end

            -- Passive extraction: Kimi thinking models return reasoning_content
            local reasoning = type(message.reasoning_content) == "string"
                and message.reasoning_content or nil
            return true, content, reasoning
        end
        return false, "Unexpected response format"
    end,

    together = function(response)
        if response.error then
            return false, response.error.message or response.error.type or "Unknown error"
        end
        if response.choices and response.choices[1] and response.choices[1].message then
            local message = response.choices[1].message
            local content = message.content
            -- Tool turns carry content:null (luajson sentinel) or "" — normalize
            if type(content) ~= "string" then content = nil end

            -- Book-tool function calls → neutral shape (tools wave 2; same
            -- dropped-tool_calls class the fireworks device round exposed)
            local calls = extractOpenAIToolCalls(message)
            if calls then
                return true, {
                    _tool_calls = true,
                    calls = calls,
                    raw_assistant_turn = message,
                }
            end

            -- Passive reasoning_content, <think> tags as fallback
            local reasoning = type(message.reasoning_content) == "string"
                and message.reasoning_content or nil
            local clean_content, think_reasoning = extractThinkTags(content)
            return true, clean_content, reasoning or think_reasoning
        end
        return false, "Unexpected response format"
    end,

    fireworks = function(response)
        if response.error then
            return false, response.error.message or response.error.type or "Unknown error"
        end
        if response.choices and response.choices[1] and response.choices[1].message then
            local message = response.choices[1].message
            local content = message.content
            -- Tool turns carry content:null (luajson sentinel) or "" — normalize
            if type(content) ~= "string" then content = nil end

            -- Book-tool function calls → neutral shape for the tool runner.
            -- Device 2026-08-15: the old content-only read DROPPED tool_calls
            -- (fireworks sends content:"" beside them), so the gather loop saw
            -- an empty answer and ended the chat with no round 2.
            local calls = extractOpenAIToolCalls(message)
            if calls then
                return true, {
                    _tool_calls = true,
                    calls = calls,
                    raw_assistant_turn = message,
                }
            end

            -- Passive: every fireworks-hosted thinking model returns
            -- reasoning_content (probed 2026-08-15); <think> tags as fallback.
            local reasoning = type(message.reasoning_content) == "string"
                and message.reasoning_content or nil
            local clean_content, think_reasoning = extractThinkTags(content)
            return true, clean_content, reasoning or think_reasoning
        end
        return false, "Unexpected response format"
    end,

    -- NVIDIA (build.nvidia.com). OpenAI chat wire + reasoning_content, PLUS a
    -- duplication guard: several nemotron models return `content` that repeats
    -- reasoning_content verbatim (device 2026-08-20 --
    -- nemotron-3.5-lightning-30b-a3b did it on every constraint-shaped prompt,
    -- content == reasoning byte-for-byte with no answer after it). Without the
    -- strip the reader gets raw chain-of-thought presented as the answer.
    nvidia = function(response)
        if response.error then
            return false, response.error.message or response.error.type or "Unknown error"
        end
        if response.choices and response.choices[1] and response.choices[1].message then
            local message = response.choices[1].message
            local content = message.content
            -- Tool-call messages carry content:null -> luajson's truthy function sentinel
            if type(content) ~= "string" then content = nil end

            local calls = extractOpenAIToolCalls(message)
            if calls then
                return true, {
                    _tool_calls = true,
                    calls = calls,
                    raw_assistant_turn = message,
                }
            end

            local reasoning = type(message.reasoning_content) == "string"
                and message.reasoning_content or nil

            -- Duplication guard. Plain-substring prefix check (no patterns: the
            -- reasoning is arbitrary user-facing text and would be read as a Lua
            -- pattern). Whole-duplicate leaves no answer at all -- say so rather
            -- than rendering the thinking, which reads as a broken reply.
            if reasoning and content then
                if content == reasoning then
                    content = nil
                elseif #content > #reasoning and content:sub(1, #reasoning) == reasoning then
                    content = content:sub(#reasoning + 1)
                end
                if content then
                    content = content:gsub("^%s+", "")
                    if content == "" then content = nil end
                end
            end

            local finish_reason = response.choices[1].finish_reason
            if not content or content == "" then
                -- Reasoning ran to the token ceiling without producing an answer.
                return true, ResponseParser.interruptedNotice(
                    "the model returned only its reasoning"), reasoning
            end
            if finish_reason == "length" then
                content = content .. ResponseParser.TRUNCATION_NOTICE
            end

            local clean_content, think_reasoning = extractThinkTags(content)
            return true, clean_content, reasoning or think_reasoning
        end
        return false, "Unexpected response format"
    end,

    sambanova = function(response)
        if response.error then
            return false, response.error.message or response.error.type or "Unknown error"
        end
        if response.choices and response.choices[1] and response.choices[1].message then
            local content = response.choices[1].message.content
            -- Extract <think> tags from R1 models
            local clean_content, reasoning = extractThinkTags(content)
            return true, clean_content, reasoning
        end
        return false, "Unexpected response format"
    end,

    cohere = function(response)
        -- Cohere v2 API response format
        if response.error then
            return false, response.message or response.error or "Unknown error"
        end
        -- Cohere v2 returns message.content as array of content blocks.
        -- Reasoning models (command-a-reasoning) put a {type="thinking"} block
        -- FIRST, then the {type="text"} answer (probed 2026-08-15) — walk all
        -- blocks: concatenate text, surface thinking as reasoning (3rd return,
        -- doubao pattern). The old first-block-only read failed every
        -- reasoning response with "Unexpected response format".
        if response.message and response.message.content then
            local content = response.message.content
            if type(content) == "table" then
                local texts, thinks = {}, {}
                for _idx, block in ipairs(content) do
                    if type(block) == "table" then
                        if type(block.text) == "string" and block.type ~= "thinking" then
                            table.insert(texts, block.text)
                        elseif type(block.thinking) == "string" then
                            table.insert(thinks, block.thinking)
                        end
                    end
                end
                if #texts > 0 or #thinks > 0 then
                    local reasoning = #thinks > 0 and table.concat(thinks, "\n") or nil
                    return true, table.concat(texts, ""), reasoning
                end
            elseif type(content) == "string" then
                return true, content
            end
        end
        return false, "Unexpected response format"
    end,

    doubao = function(response)
        if response.error then
            return false, response.error.message or response.error.type or "Unknown error"
        end
        if response.choices and response.choices[1] and response.choices[1].message then
            local message = response.choices[1].message
            -- Passive extraction: Doubao thinking models return reasoning_content
            local reasoning = message.reasoning_content
            return true, message.content, reasoning
        end
        return false, "Unexpected response format"
    end,

    zai = function(response)
        if response.error then
            return false, response.error.message or response.error.type or "Unknown error"
        end
        if response.choices and response.choices[1] and response.choices[1].message then
            local message = response.choices[1].message
            local content = message.content
            local reasoning = message.reasoning_content  -- GLM-4.5+ returns this
            -- Check for truncation
            local finish_reason = response.choices[1].finish_reason
            if content and content ~= "" and finish_reason == "length" then
                content = content .. ResponseParser.TRUNCATION_NOTICE
            end
            -- Check for web search usage (top-level array in Z.AI responses)
            local web_search_used = nil
            if type(response.web_search) == "table" and #response.web_search > 0 then
                local web_prov = {}
                for _idx, item in ipairs(response.web_search) do
                    if type(item) == "table" then
                        addProvSource(web_prov, item.link or item.url, item.title)
                    end
                end
                web_search_used = finishProv(web_prov)
            end
            return true, content, reasoning, web_search_used
        end
        return false, "Unexpected response format"
    end,

    perplexity = function(response)
        if response.error then
            return false, response.error.message or response.error.type or "Unknown error"
        end
        if response.choices and response.choices[1] and response.choices[1].message then
            local content = response.choices[1].message.content
            -- Extract <think> tags from reasoning models (sonar-reasoning-pro)
            local reasoning = nil
            if content then
                content, reasoning = extractThinkTags(content)
            end
            -- Check for truncation
            local finish_reason = response.choices[1].finish_reason
            if content and content ~= "" and finish_reason == "length" then
                content = content .. ResponseParser.TRUNCATION_NOTICE
            end
            -- Append citation footnotes (Perplexity returns citations as top-level array)
            if content and response.citations then
                content = content .. formatCitations(response.citations)
            end
            -- Provenance: prefer search_results (title+url) over bare citation URLs
            local web_prov = {}
            if type(response.search_results) == "table" then
                for _idx, item in ipairs(response.search_results) do
                    if type(item) == "table" then
                        addProvSource(web_prov, item.url, item.title)
                    end
                end
            end
            if not web_prov.sources and type(response.citations) == "table" then
                for _idx, url in ipairs(response.citations) do
                    addProvSource(web_prov, url)
                end
            end
            -- Honest provenance (2026-08-14): web_search_used only when search
            -- artifacts actually came back — with disable_search (the toggle is
            -- real, probed) a response carries no citations/search_results and
            -- must not claim a search happened.
            local searched = (type(response.search_results) == "table" and #response.search_results > 0)
                or (type(response.citations) == "table" and #response.citations > 0)
            return true, content, reasoning, searched and finishProv(web_prov) or nil
        end
        return false, "Unexpected response format"
    end
}

--- Parse a response from an AI provider
--- @param response table: The raw response from the provider
--- @param provider string: The provider name (e.g., "anthropic", "openai")
--- @return boolean: Success flag
--- @return string: Content (main response text) or error message
--- @return string|nil: Reasoning content (thinking/reasoning if available, nil otherwise)
--- @return boolean|table|nil: Web search used — nil (not used), true (used, no details),
---         or { web_search = true, sources = {{url,title},...}, queries = {...} }.
---         Consumers testing truthiness need no change; details feed "Show Sources".
function ResponseParser:parseResponse(response, provider)
    local transform = RESPONSE_TRANSFORMERS[provider]
    if not transform then
        return false, "No response transformer found for provider: " .. tostring(provider)
    end

    -- Transform returns: success, content, reasoning, web_search_used (reasoning and web_search are optional)
    local success, result, reasoning, web_search_used = transform(response)
    if not success and result == "Unexpected response format" then
        -- Provide more details about what was received (show full response for debugging)
        local response_str = "Unable to encode response"
        pcall(function() response_str = json.encode(response) end)
        return false, string.format("Unexpected response format from %s. Response: %s",
                                   provider, response_str)
    end

    return success, result, reasoning, web_search_used
end

-- Expose citation formatter for stream handler
ResponseParser.formatCitations = formatCitations

return ResponseParser
