--[[--
Z.AI API Handler

OpenAI-compatible handler for Z.AI (Zhipu AI) GLM models.
GLM-4.5+ models support reasoning via `reasoning_content` response field
(like DeepSeek) and toggleable thinking via request parameter.

Chat completions endpoint: https://api.z.ai/api/paas/v4/chat/completions
Docs: https://docs.z.ai/api-reference/llm/chat-completion

@module zai
]]

local OpenAICompatibleHandler = require("koassistant_api.openai_compatible")
local ModelConstraints = require("model_constraints")

local ZaiHandler = OpenAICompatibleHandler:new()

-- Regional endpoints for Z.AI
-- Same API key works on both endpoints
local REGIONAL_ENDPOINTS = {
    international = "https://api.z.ai/api/paas/v4/chat/completions",
    china = "https://open.bigmodel.cn/api/paas/v4/chat/completions",
}

function ZaiHandler:getProviderName()
    return "Z.AI"
end

function ZaiHandler:getProviderKey()
    return "zai"
end

-- Use regional endpoint based on zai_region setting
function ZaiHandler:customizeUrl(url, config)
    if config.base_url then
        return config.base_url
    end
    local region = config.features and config.features.zai_region or "international"
    return REGIONAL_ENDPOINTS[region] or REGIONAL_ENDPOINTS.international
end

-- Add hint for auth errors about region setting
function ZaiHandler:enhanceErrorMessage(error_msg, config)
    local err_lower = error_msg:lower()
    if err_lower:find("401") or err_lower:find("auth") or err_lower:find("invalid") or err_lower:find("key") then
        return error_msg .. "\n\nHint: Check Settings → Advanced → Provider Settings → Z.AI Region."
    end
    return error_msg
end

function ZaiHandler:customizeRequestBody(body, config)
    local model = body.model or ""

    -- Thinking parameter (GLM-4.5+ models)
    -- Z.AI defaults to thinking ENABLED, so we must explicitly disable it
    -- when the toggle is off, otherwise all requests produce reasoning_content
    if ModelConstraints.supportsCapability("zai", model, "thinking") then
        if config.api_params and config.api_params.zai_thinking then
            body.thinking = config.api_params.zai_thinking
        else
            body.thinking = { type = "disabled" }
        end
    end

    -- Note: Z.AI web search only works via a separate endpoint (/api/paas/v4/tools)
    -- and NOT via the chat completions tools parameter (silently ignored).
    -- Web search is not supported for this provider.

    return body
end

return ZaiHandler
