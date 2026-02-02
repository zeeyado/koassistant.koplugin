--[[--
Qwen (DashScope) API Handler

OpenAI-compatible handler with regional endpoint selection.
API keys are region-specific and NOT interchangeable.

@module qwen
]]

local OpenAICompatibleHandler = require("koassistant_api.openai_compatible")

local QwenHandler = OpenAICompatibleHandler:new()

-- Regional endpoints for Qwen/DashScope
-- API keys are region-specific and NOT interchangeable
local REGIONAL_ENDPOINTS = {
    international = "https://dashscope-intl.aliyuncs.com/compatible-mode/v1/chat/completions",  -- Singapore
    china = "https://dashscope.aliyuncs.com/compatible-mode/v1/chat/completions",               -- Beijing
    us = "https://dashscope-us.aliyuncs.com/compatible-mode/v1/chat/completions",               -- Virginia
}

function QwenHandler:getProviderName()
    return "Qwen"
end

function QwenHandler:getProviderKey()
    return "qwen"
end

-- Use regional endpoint based on qwen_region setting
function QwenHandler:customizeUrl(url, config)
    -- config.base_url override takes precedence
    if config.base_url then
        return config.base_url
    end
    -- Otherwise use regional endpoint
    local region = config.features and config.features.qwen_region or "international"
    return REGIONAL_ENDPOINTS[region] or REGIONAL_ENDPOINTS.international
end

-- Add hint for auth errors about region setting
function QwenHandler:enhanceErrorMessage(error_msg, config)
    local err_lower = error_msg:lower()
    if err_lower:find("401") or err_lower:find("auth") or err_lower:find("invalid") or err_lower:find("key") then
        return error_msg .. "\n\nHint: Qwen API keys are region-specific. Check Settings → Advanced → Provider Settings → Qwen Region."
    end
    return error_msg
end

return QwenHandler
