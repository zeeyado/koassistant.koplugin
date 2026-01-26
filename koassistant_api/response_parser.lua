local ResponseParser = {}

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
        if response.content then
            local text_content = nil
            local thinking_content = nil

            -- Look for both thinking and text blocks
            for _, block in ipairs(response.content) do
                if block.type == "thinking" and block.thinking then
                    thinking_content = block.thinking
                elseif block.type == "text" and block.text then
                    text_content = block.text
                end
            end

            -- Fallback: first block with text field (legacy format)
            if not text_content and response.content[1] and response.content[1].text then
                text_content = response.content[1].text
            end

            if text_content then
                return true, text_content, thinking_content
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
            return true, response.choices[1].message.content
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
            -- Check if MAX_TOKENS before content was generated (thinking models issue)
            if candidate.finishReason == "MAX_TOKENS" and
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
                if content ~= "" then
                    return true, content, thinking
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
            return true, response.choices[1].message.content
        end
        return false, "Unexpected response format"
    end,

    openrouter = function(response)
        if response.error then
            return false, response.error.message or response.error.type or "Unknown error"
        end
        if response.choices and response.choices[1] and response.choices[1].message then
            return true, response.choices[1].message.content
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
function ResponseParser:parseResponse(response, provider)
    local transform = RESPONSE_TRANSFORMERS[provider]
    if not transform then
        return false, "No response transformer found for provider: " .. tostring(provider)
    end

    -- Transform returns: success, content, reasoning (reasoning is optional)
    local success, result, reasoning = transform(response)
    if not success and result == "Unexpected response format" then
        -- Provide more details about what was received (show full response for debugging)
        local json = require("json")
        local response_str = "Unable to encode response"
        pcall(function() response_str = json.encode(response) end)
        return false, string.format("Unexpected response format from %s. Response: %s",
                                   provider, response_str)
    end

    return success, result, reasoning
end

return ResponseParser 