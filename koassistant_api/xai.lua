--[[--
xAI (Grok) API Handler

OpenAI-compatible handler for xAI's Grok models.
grok-3-mini supports reasoning_effort parameter (low/high).
Other Grok models reason internally but don't expose content via Chat Completions.

Note: Web search requires xAI's Responses API (/v1/responses) which uses a
different format than Chat Completions. The Chat Completions API deprecated
web search on Feb 20, 2026 (returns 410 Gone). Web search is not currently
supported for xAI.

@module xai
]]

local OpenAICompatibleHandler = require("koassistant_api.openai_compatible")
local ModelConstraints = require("model_constraints")

local XAIHandler = OpenAICompatibleHandler:new()

function XAIHandler:getProviderName()
    return "xAI"
end

function XAIHandler:getProviderKey()
    return "xai"
end

-- Add reasoning_effort parameter for grok-3-mini
function XAIHandler:customizeRequestBody(body, config)
    local model = body.model or ""
    if ModelConstraints.supportsCapability("xai", model, "reasoning") then
        if config.api_params and config.api_params.xai_reasoning then
            body.reasoning_effort = config.api_params.xai_reasoning.effort
        end
    end
    return body
end

return XAIHandler
