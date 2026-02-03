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

-- Add web search via :online suffix if enabled
-- OpenRouter uses Exa search ($0.02/request, 5 results default)
-- Works with ALL models - no capability check needed
function OpenRouterHandler:customizeRequestBody(body, config)
    -- Check if web search is enabled (per-action > global)
    local enable_web_search = false
    if config.enable_web_search ~= nil then
        enable_web_search = config.enable_web_search
    elseif config.features and config.features.enable_web_search then
        enable_web_search = true
    end

    -- Append :online suffix to model name
    -- Only if model looks valid (OpenRouter models contain "/" like "anthropic/claude-3")
    if enable_web_search and body.model and body.model:find("/") then
        -- Avoid double-appending if already has :online
        if not body.model:match(":online$") then
            body.model = body.model .. ":online"
        end
    end

    return body
end

return OpenRouterHandler
