local json = require("json")

local ResponseParser = {}

-- Truncation notice appended to responses that hit max tokens
-- This marker is checked by caching logic to avoid caching incomplete responses
ResponseParser.TRUNCATION_NOTICE = "\n\n---\n⚠ *Response truncated: output token limit reached*"

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
    
    -- OpenAI Responses API (/v1/responses) — used by the openai handler when native
    -- web search routes there (responses_api_plan.md R1). Typed output[] items:
    -- message (output_text parts + url_citation annotations), web_search_call
    -- (queries), reasoning (summaries — not requested in R1, ignored). Pre-search
    -- prose keeps the same segment/marker rules as the Anthropic transformer.
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
        local segment_start = 1
        local last_was_search = false

        for _, item in ipairs(response.output) do
            if type(item) == "table" then
                if item.type == "message" and type(item.content) == "table" then
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
            local reasoning = message.reasoning_content  -- DeepSeek reasoner returns this
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

        if response.message and response.message.content then
            local content = response.message.content
            -- Extract <think> tags from R1 models running locally
            local clean_content, reasoning = extractThinkTags(content)
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
            local content = response.choices[1].message.content
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
            return true, content  -- Non-Magistral models return string
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

            -- Check for live_search tool usage in tool_calls (xAI's web search)
            local web_search_used = nil
            if message.tool_calls then
                for _, tool_call in ipairs(message.tool_calls) do
                    -- xAI uses "live_search" type (not "web_search")
                    if tool_call.type == "live_search" or tool_call.type == "web_search" or
                       (tool_call["function"] and tool_call["function"].name == "live_search") then
                        web_search_used = true
                        break
                    end
                end
            end

            -- xAI returns reasoning_content for grok-3-mini
            local reasoning = message.reasoning_content
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
            -- Passive extraction: Qwen thinking models return reasoning_content
            local reasoning = message.reasoning_content
            return true, message.content, reasoning
        end
        return false, "Unexpected response format"
    end,

    kimi = function(response)
        if response.error then
            return false, response.error.message or response.error.type or "Unknown error"
        end
        if response.choices and response.choices[1] and response.choices[1].message then
            local message = response.choices[1].message
            -- Passive extraction: Kimi thinking models return reasoning_content
            local reasoning = message.reasoning_content
            return true, message.content, reasoning
        end
        return false, "Unexpected response format"
    end,

    together = function(response)
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

    fireworks = function(response)
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
        -- Cohere v2 returns message.content as array of content blocks
        if response.message and response.message.content then
            local content = response.message.content
            if type(content) == "table" and content[1] and content[1].text then
                return true, content[1].text
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
            -- Perplexity always searches the web — every response is web-grounded
            return true, content, reasoning, finishProv(web_prov)
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
