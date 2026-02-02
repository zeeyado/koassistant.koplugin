--[[--
SambaNova API Handler

OpenAI-compatible handler with reasoning extraction support.
Some SambaNova models (like DeepSeek-R1) use <think> tags for reasoning.

@module sambanova
]]

local OpenAICompatibleHandler = require("koassistant_api.openai_compatible")

local SambaNovaHandler = OpenAICompatibleHandler:new()

function SambaNovaHandler:getProviderName()
    return "SambaNova"
end

function SambaNovaHandler:getProviderKey()
    return "sambanova"
end

-- SambaNova supports R1 models that use <think> tags for reasoning
function SambaNovaHandler:supportsReasoningExtraction()
    return true
end

return SambaNovaHandler
