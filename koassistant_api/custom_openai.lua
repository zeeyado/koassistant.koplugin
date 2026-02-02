--[[--
Custom OpenAI-Compatible Handler

Generic handler for user-defined providers that follow the OpenAI API format.
Supports optional authentication (for local servers like LM Studio) and
max_completion_tokens for newer OpenAI-style models.

@module custom_openai
]]

local OpenAICompatibleHandler = require("koassistant_api.openai_compatible")

local CustomOpenAIHandler = OpenAICompatibleHandler:new()

function CustomOpenAIHandler:getProviderName()
    return "Custom Provider"
end

function CustomOpenAIHandler:getProviderKey()
    return "custom"
end

-- Custom providers require base_url, not api_key
function CustomOpenAIHandler:validateConfig(config)
    if not config or not config.base_url or config.base_url == "" then
        return false, "Error: Missing base URL for custom provider"
    end
    return true
end

-- API key is optional for local servers like LM Studio
function CustomOpenAIHandler:customizeHeaders(headers, config)
    if not config.api_key or config.api_key == "" then
        headers["Authorization"] = nil
    end
    return headers
end

-- Handle max_completion_tokens for newer OpenAI models
function CustomOpenAIHandler:customizeRequestBody(body, config)
    local model = body.model or ""
    -- Newer OpenAI models use max_completion_tokens instead of max_tokens
    local needs_new_param = model:match("^gpt%-5") or model:match("^o%d") or model:match("^gpt%-4%.1")
    if needs_new_param and body.max_tokens then
        body.max_completion_tokens = body.max_tokens
        body.max_tokens = nil
    end
    return body
end

-- Use "openai" parser for maximum compatibility
function CustomOpenAIHandler:getResponseParserKey()
    return "openai"
end

-- Support R1-style reasoning models that users might run locally
function CustomOpenAIHandler:supportsReasoningExtraction()
    return true
end

return CustomOpenAIHandler
