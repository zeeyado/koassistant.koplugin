local ResponseParser = {}

-- Truncation notice appended to responses that hit max tokens
-- This marker is checked by caching logic to avoid caching incomplete responses
ResponseParser.TRUNCATION_NOTICE = "\n\n---\n⚠ *Response truncated: output token limit reached*"

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
            local text_blocks = {}
            local thinking_content = nil
            local web_search_used = nil

            -- Look for thinking and text blocks (ignore tool_use blocks)
            local seen_search_tool = false
            for _, block in ipairs(response.content) do
                if block.type == "thinking" and block.thinking then
                    thinking_content = block.thinking
                elseif block.type == "text" and block.text then
                    table.insert(text_blocks, block.text)
                elseif block.type == "server_tool_use" or block.type == "web_search_tool_result" then
                    web_search_used = true
                    -- Only discard pre-search thinking text ("Let me search...")
                    -- on the first search tool encounter. Subsequent searches must
                    -- not wipe answer content from earlier searches.
                    if not seen_search_tool then
                        text_blocks = {}
                        seen_search_tool = true
                    end
                end
                -- Other blocks (tool_use) are silently ignored
                -- Web search results are integrated into the text blocks by Anthropic
            end

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
            -- Check for truncation (finish_reason: "length" means max tokens hit)
            local finish_reason = response.choices[1].finish_reason
            if content and content ~= "" and finish_reason == "length" then
                content = content .. ResponseParser.TRUNCATION_NOTICE
            end

            -- Check for web search tool usage in tool_calls
            local web_search_used = nil
            if message.tool_calls then
                for _, tool_call in ipairs(message.tool_calls) do
                    if tool_call.type == "web_search" or
                       (tool_call["function"] and tool_call["function"].name == "web_search") then
                        web_search_used = true
                        break
                    end
                end
            end

            return true, content, nil, web_search_used
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
                    web_search_used = true
                end
            end

            -- Check if MAX_TOKENS before content was generated (thinking models issue)
            if finish_reason == "MAX_TOKENS" and
               (not candidate.content or not candidate.content.parts or #candidate.content.parts == 0) then
                return false, "No content generated (MAX_TOKENS hit before output - increase max_tokens for thinking models)"
            end
            if candidate.content and candidate.content.parts then
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
            return true, response.choices[1].message.content
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

            return true, content, nil, web_search_used
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

            -- Check for web search usage via annotations (OpenRouter uses Exa search)
            -- When :online suffix is used, response includes annotations with url_citation type
            local web_search_used = nil
            if message.annotations then
                for _, annotation in ipairs(message.annotations) do
                    if annotation.type == "url_citation" then
                        web_search_used = true
                        break
                    end
                end
            end

            return true, content, nil, web_search_used
        end
        return false, "Unexpected response format"
    end,

    qwen = function(response)
        if response.error then
            return false, response.error.message or response.error.type or "Unknown error"
        end
        if response.choices and response.choices[1] and response.choices[1].message then
            return true, response.choices[1].message.content
        end
        return false, "Unexpected response format"
    end,

    kimi = function(response)
        if response.error then
            return false, response.error.message or response.error.type or "Unknown error"
        end
        if response.choices and response.choices[1] and response.choices[1].message then
            return true, response.choices[1].message.content
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
            return true, response.choices[1].message.content
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
--- @return boolean|nil: Web search used (true if web search was used, nil otherwise)
function ResponseParser:parseResponse(response, provider)
    local transform = RESPONSE_TRANSFORMERS[provider]
    if not transform then
        return false, "No response transformer found for provider: " .. tostring(provider)
    end

    -- Transform returns: success, content, reasoning, web_search_used (reasoning and web_search are optional)
    local success, result, reasoning, web_search_used = transform(response)
    if not success and result == "Unexpected response format" then
        -- Provide more details about what was received (show full response for debugging)
        local json = require("json")
        local response_str = "Unable to encode response"
        pcall(function() response_str = json.encode(response) end)
        return false, string.format("Unexpected response format from %s. Response: %s",
                                   provider, response_str)
    end

    return success, result, reasoning, web_search_used
end

return ResponseParser 