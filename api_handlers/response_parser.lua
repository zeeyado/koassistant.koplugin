local ResponseParser = {}

-- Response format transformers for each provider
local RESPONSE_TRANSFORMERS = {
    anthropic = function(response)
        if response.type == "error" and response.error then
            return false, response.error.message
        end

        -- Handle extended thinking responses (content array with thinking + text blocks)
        -- Also handles regular responses (content array with just text block)
        if response.content then
            -- Look for text block by type (extended thinking has thinking block first)
            for _, block in ipairs(response.content) do
                if block.type == "text" and block.text then
                    return true, block.text
                end
            end
            -- Fallback: first block with text field (legacy format)
            if response.content[1] and response.content[1].text then
                return true, response.content[1].text
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
            if candidate.content and candidate.content.parts and candidate.content.parts[1] then
                return true, candidate.content.parts[1].text
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
            return true, response.choices[1].message.content
        end
        return false, "Unexpected response format"
    end,
    
    ollama = function(response)
        -- Check for error response
        if response.error then
            return false, response.error
        end

        if response.message and response.message.content then
            return true, response.message.content
        end
        return false, "Unexpected response format"
    end,

    -- New providers (OpenAI-compatible)
    groq = function(response)
        if response.error then
            return false, response.error.message or response.error.type or "Unknown error"
        end
        if response.choices and response.choices[1] and response.choices[1].message then
            return true, response.choices[1].message.content
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
            return true, response.choices[1].message.content
        end
        return false, "Unexpected response format"
    end,

    fireworks = function(response)
        if response.error then
            return false, response.error.message or response.error.type or "Unknown error"
        end
        if response.choices and response.choices[1] and response.choices[1].message then
            return true, response.choices[1].message.content
        end
        return false, "Unexpected response format"
    end,

    sambanova = function(response)
        if response.error then
            return false, response.error.message or response.error.type or "Unknown error"
        end
        if response.choices and response.choices[1] and response.choices[1].message then
            return true, response.choices[1].message.content
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

function ResponseParser:parseResponse(response, provider)
    local transform = RESPONSE_TRANSFORMERS[provider]
    if not transform then
        return false, "No response transformer found for provider: " .. tostring(provider)
    end
    
    -- Add detailed logging for debugging
    local success, result = transform(response)
    if not success and result == "Unexpected response format" then
        -- Provide more details about what was received (show full response for debugging)
        local json = require("json")
        local response_str = "Unable to encode response"
        pcall(function() response_str = json.encode(response) end)
        return false, string.format("Unexpected response format from %s. Response: %s",
                                   provider, response_str)
    end
    
    return success, result
end

return ResponseParser 