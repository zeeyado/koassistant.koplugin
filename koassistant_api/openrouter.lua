--[[--
OpenRouter API Handler

OpenAI-compatible handler with custom headers required by OpenRouter.

@module openrouter
]]

local OpenAICompatibleHandler = require("koassistant_api.openai_compatible")
local Constants = require("koassistant_constants")
local ModelConstraints = require("model_constraints")

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
        local effort = ModelConstraints.webSearchEffort(config.features)
        if effort ~= "standard" then
            -- Non-default effort: use the explicit web plugin (the :online suffix is
            -- shorthand for it with defaults and takes no options) so max_results
            -- applies; strip a baked-in suffix to avoid double activation
            body.model = body.model:gsub(":online$", "")
            body.plugins = { {
                id = "web",
                max_results = effort == "light" and 3 or 10,
            } }
        elseif not body.model:match(":online$") then
            -- Avoid double-appending if already has :online
            body.model = body.model .. ":online"
        end
    elseif not enable_web_search and body.model then
        -- Strip a baked-in :online (e.g. saved in a custom model id) when web search is
        -- off — the tool runner forces it off during tool turns, and a lingering suffix
        -- would keep paid Exa search active on every turn.
        body.model = body.model:gsub(":online$", "")
    end

    -- Add reasoning object (OpenRouter auto-translates to backend provider format)
    if config.api_params and config.api_params.openrouter_reasoning then
        body.reasoning = { effort = config.api_params.openrouter_reasoning.effort }
    end

    return body
end

return OpenRouterHandler
