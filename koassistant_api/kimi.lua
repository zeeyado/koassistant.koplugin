--[[--
Kimi (Moonshot) API Handler

Pure OpenAI-compatible handler with no provider-specific customization.

@module kimi
]]

local OpenAICompatibleHandler = require("koassistant_api.openai_compatible")

local KimiHandler = OpenAICompatibleHandler:new()

function KimiHandler:getProviderName()
    return "Kimi"
end

function KimiHandler:getProviderKey()
    return "kimi"
end

return KimiHandler
