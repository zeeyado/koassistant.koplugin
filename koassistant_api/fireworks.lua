--[[--
Fireworks API Handler

OpenAI-compatible handler with reasoning extraction support.
Some Fireworks models (like DeepSeek-R1) use <think> tags for reasoning.

@module fireworks
]]

local OpenAICompatibleHandler = require("koassistant_api.openai_compatible")

local FireworksHandler = OpenAICompatibleHandler:new()

function FireworksHandler:getProviderName()
    return "Fireworks"
end

function FireworksHandler:getProviderKey()
    return "fireworks"
end

-- Fireworks supports R1 models that use <think> tags for reasoning
function FireworksHandler:supportsReasoningExtraction()
    return true
end

return FireworksHandler
