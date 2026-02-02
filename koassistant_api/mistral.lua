--[[--
Mistral API Handler

Pure OpenAI-compatible handler with no provider-specific customization.

@module mistral
]]

local OpenAICompatibleHandler = require("koassistant_api.openai_compatible")

local MistralHandler = OpenAICompatibleHandler:new()

function MistralHandler:getProviderName()
    return "Mistral"
end

function MistralHandler:getProviderKey()
    return "mistral"
end

return MistralHandler
