--[[--
Z.AI API Handler

OpenAI-compatible handler for Z.AI (Zhipu AI) GLM models.
GLM-4.5+ models support reasoning via `reasoning_content` response field
(like DeepSeek) and toggleable thinking via request parameter.

Chat completions endpoint: https://api.z.ai/api/paas/v4/chat/completions
Docs: https://docs.z.ai/api-reference/llm/chat-completion

@module zai
]]

local OpenAICompatibleHandler = require("koassistant_api.openai_compatible")
local ModelConstraints = require("model_constraints")

local ZaiHandler = OpenAICompatibleHandler:new()

function ZaiHandler:getProviderName()
    return "Z.AI"
end

function ZaiHandler:getProviderKey()
    return "zai"
end

function ZaiHandler:customizeRequestBody(body, config)
    local model = body.model or ""

    -- Thinking parameter (GLM-4.5+ models)
    -- Set by koassistant_dialogs.lua when reasoning toggle is enabled
    if config.api_params and config.api_params.zai_thinking then
        if ModelConstraints.supportsCapability("zai", model, "thinking") then
            body.thinking = config.api_params.zai_thinking
        end
    end

    -- Web search tool
    local enable_web_search = false
    if config.enable_web_search ~= nil then
        enable_web_search = config.enable_web_search
    elseif config.features and config.features.enable_web_search then
        enable_web_search = true
    end

    if enable_web_search then
        if ModelConstraints.supportsCapability("zai", model, "web_search") then
            body.tools = {
                {
                    type = "web_search",
                    web_search = { enable = true },
                },
            }
        end
    end

    return body
end

return ZaiHandler
