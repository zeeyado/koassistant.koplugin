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
        local thinking = config.api_params and config.api_params.sambanova_thinking
        -- Emit chat_template_kwargs only when the reasoning resolver made an explicit
        -- on/off decision. When nil (resolver sent nothing) we omit it so the model
        -- behaves at its API default (R1/Qwen3 think by default).
        if thinking ~= nil then
            body.chat_template_kwargs = { enable_thinking = thinking and true or false }
        end
    end
    return body
end

return SambaNovaHandler
