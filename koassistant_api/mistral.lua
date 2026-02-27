--[[--
Mistral API Handler

OpenAI-compatible handler with thinking extraction for Magistral models.
Magistral models always think — there is no toggle to disable reasoning.
Thinking output comes as structured content blocks (type: "thinking")
rather than <think> tags.

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

-- Mistral uses structured content blocks, not <think> tags.
-- Extraction is handled by the response parser and stream handler.
-- Return false here to avoid processThinkTags() interfering.
function MistralHandler:supportsReasoningExtraction()
    return false
end

return MistralHandler
