--[[--
OpenRouter API Handler

OpenAI-compatible handler with custom headers required by OpenRouter.

@module openrouter
]]

local OpenAICompatibleHandler = require("koassistant_api.openai_compatible")
local Constants = require("koassistant_constants")

local OpenRouterHandler = OpenAICompatibleHandler:new()

function OpenRouterHandler:getProviderName()
    return "OpenRouter"
end

function OpenRouterHandler:getProviderKey()
    return "openrouter"
end

-- OpenRouter requires HTTP-Referer and X-Title headers
function OpenRouterHandler:customizeHeaders(headers, config)
    headers["HTTP-Referer"] = Constants.GITHUB.URL
    headers["X-Title"] = "KOAssistant"
    return headers
end

return OpenRouterHandler
