--[[--
Together API Handler

OpenAI-compatible handler with reasoning extraction support.
Some Together models (like DeepSeek-R1) use <think> tags for reasoning.

@module together
]]

local OpenAICompatibleHandler = require("koassistant_api.openai_compatible")

local TogetherHandler = OpenAICompatibleHandler:new()

function TogetherHandler:getProviderName()
    return "Together"
end

function TogetherHandler:getProviderKey()
    return "together"
end

-- Together supports R1 models that use <think> tags for reasoning
function TogetherHandler:supportsReasoningExtraction()
    return true
end

return TogetherHandler
