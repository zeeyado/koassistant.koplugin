--[[--
Together API Handler

OpenAI-compatible handler with reasoning effort support.
Together models (DeepSeek-R1, Qwen3, etc.) support reasoning_effort parameter
and use <think> tags for reasoning output.

@module together
]]

local OpenAICompatibleHandler = require("koassistant_api.openai_compatible")
local ModelConstraints = require("model_constraints")

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

-- Add reasoning_effort parameter for reasoning-capable models
function TogetherHandler:customizeRequestBody(body, config)
    local model = body.model or ""
    if ModelConstraints.supportsCapability("together", model, "reasoning") then
        if config.api_params and config.api_params.together_reasoning then
            body.reasoning_effort = config.api_params.together_reasoning.effort
        end
    end
    return body
end

return TogetherHandler
