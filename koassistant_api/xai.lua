--[[--
xAI (Grok) API Handler

Pure OpenAI-compatible handler with no provider-specific customization.

@module xai
]]

local OpenAICompatibleHandler = require("koassistant_api.openai_compatible")

local XAIHandler = OpenAICompatibleHandler:new()

function XAIHandler:getProviderName()
    return "xAI"
end

function XAIHandler:getProviderKey()
    return "xai"
end

return XAIHandler
