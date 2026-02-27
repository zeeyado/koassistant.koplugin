--[[--
Fireworks API Handler

OpenAI-compatible handler with reasoning effort support.
Fireworks models (DeepSeek-R1, Qwen3, etc.) support reasoning_effort parameter
and use <think> tags for reasoning output.

@module fireworks
]]

local OpenAICompatibleHandler = require("koassistant_api.openai_compatible")
local ModelConstraints = require("model_constraints")

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

-- Add reasoning_effort parameter for reasoning-capable models
function FireworksHandler:customizeRequestBody(body, config)
    local model = body.model or ""
    if ModelConstraints.supportsCapability("fireworks", model, "reasoning") then
        if config.api_params and config.api_params.fireworks_reasoning then
            body.reasoning_effort = config.api_params.fireworks_reasoning.effort
        end
    end
    return body
end

return FireworksHandler
