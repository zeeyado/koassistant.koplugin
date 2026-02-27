--[[--
Perplexity API Handler

OpenAI-compatible handler for Perplexity Sonar models.
Web search is always-on — every response is web-grounded with citations.
Citations are appended as clickable footnotes by the response parser.

Reasoning models (sonar-reasoning-pro) support reasoning_effort parameter
and use <think> tags for reasoning output. Reasoning is always-on for these
models — effort controls depth, not whether reasoning occurs.

Endpoint: https://api.perplexity.ai/chat/completions
Docs: https://docs.perplexity.ai/

@module perplexity
]]

local OpenAICompatibleHandler = require("koassistant_api.openai_compatible")
local ModelConstraints = require("model_constraints")

local PerplexityHandler = OpenAICompatibleHandler:new()

function PerplexityHandler:getProviderName()
    return "Perplexity"
end

function PerplexityHandler:getProviderKey()
    return "perplexity"
end

-- Perplexity sonar-reasoning-pro uses <think> tags for reasoning
function PerplexityHandler:supportsReasoningExtraction()
    return true
end

-- Perplexity requires strict user/assistant message alternation.
-- Merge consecutive same-role messages to avoid 400 errors
-- (e.g., context message + user question are both role="user").
-- Also add reasoning_effort for reasoning models.
function PerplexityHandler:customizeRequestBody(body, config)
    local messages = body.messages
    if messages and #messages > 1 then
        local merged = { messages[1] }
        for i = 2, #messages do
            local prev = merged[#merged]
            if messages[i].role == prev.role then
                prev.content = prev.content .. "\n\n" .. messages[i].content
            else
                table.insert(merged, messages[i])
            end
        end
        body.messages = merged
    end

    -- Add reasoning_effort for reasoning models
    local model = body.model or ""
    if ModelConstraints.supportsCapability("perplexity", model, "reasoning") then
        if config.api_params and config.api_params.perplexity_reasoning then
            body.reasoning_effort = config.api_params.perplexity_reasoning.effort
        end
    end

    return body
end

return PerplexityHandler
