--[[--
SambaNova API Handler

OpenAI-compatible handler with reasoning extraction and thinking toggle.
SambaNova uses chat_template_kwargs.enable_thinking to control reasoning
for models like DeepSeek-R1 and Qwen3.

@module sambanova
]]

local OpenAICompatibleHandler = require("koassistant_api.openai_compatible")
local ModelConstraints = require("model_constraints")

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

-- Add thinking toggle for reasoning-capable models
function SambaNovaHandler:customizeRequestBody(body, config)
    local model = body.model or ""
    if ModelConstraints.supportsCapability("sambanova", model, "thinking") then
        if config.api_params and config.api_params.sambanova_thinking then
            body.chat_template_kwargs = { enable_thinking = true }
        else
            -- Default: explicitly disable (R1/Qwen3 default ON)
            body.chat_template_kwargs = { enable_thinking = false }
        end
    end
    return body
end

return SambaNovaHandler
