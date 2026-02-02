--[[--
Groq API Handler

OpenAI-compatible handler with reasoning extraction support.
Some Groq models (like DeepSeek-R1) use <think> tags for reasoning.

@module groq
]]

local OpenAICompatibleHandler = require("koassistant_api.openai_compatible")

local GroqHandler = OpenAICompatibleHandler:new()

function GroqHandler:getProviderName()
    return "Groq"
end

function GroqHandler:getProviderKey()
    return "groq"
end

-- Groq supports R1 models that use <think> tags for reasoning
function GroqHandler:supportsReasoningExtraction()
    return true
end

return GroqHandler
