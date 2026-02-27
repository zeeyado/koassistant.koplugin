--[[--
Groq API Handler

OpenAI-compatible handler with reasoning effort support.
Groq models (GPT-OSS, Qwen3, etc.) support reasoning_effort parameter
and use <think> tags for reasoning output.

@module groq
]]

local OpenAICompatibleHandler = require("koassistant_api.openai_compatible")
local ModelConstraints = require("model_constraints")

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

-- Add reasoning_effort parameter for reasoning-capable models
function GroqHandler:customizeRequestBody(body, config)
    local model = body.model or ""
    if ModelConstraints.supportsCapability("groq", model, "reasoning") then
        if config.api_params and config.api_params.groq_reasoning then
            body.reasoning_effort = config.api_params.groq_reasoning.effort
            -- GPT-OSS models also need include_reasoning for structured output
            if model:match("^openai/gpt%-oss") then
                body.include_reasoning = true
            end
        end
    end
    return body
end

return GroqHandler
