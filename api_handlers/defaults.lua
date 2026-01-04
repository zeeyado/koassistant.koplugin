-- Load model lists to get default models dynamically
local ModelLists = require("model_lists")

-- Helper function to get the default model for a provider (first in the list)
local function getDefaultModel(provider)
    local models = ModelLists[provider]
    if models and #models > 0 then
        return models[1]
    end
    -- Fallback models in case model_lists.lua is missing entries
    local fallbacks = {
        anthropic = "claude-sonnet-4-5-20250929",
        openai = "gpt-4.1",
        deepseek = "deepseek-chat",
        gemini = "gemini-2.5-pro",
        ollama = "llama3",
    }
    return fallbacks[provider] or "unknown"
end

local ProviderDefaults = {
    anthropic = {
        provider = "anthropic",
        model = getDefaultModel("anthropic"),
        base_url = "https://api.anthropic.com/v1/messages",
        additional_parameters = {
            anthropic_version = "2023-06-01",
            max_tokens = 4096,
            temperature = 0.7,  -- Added: Anthropic defaults to 1.0 without this
        }
    },
    openai = {
        provider = "openai",
        model = getDefaultModel("openai"),
        base_url = "https://api.openai.com/v1/chat/completions",
        additional_parameters = {
            temperature = 0.7,
            max_tokens = 4096
        }
    },
    deepseek = {
        provider = "deepseek",
        model = getDefaultModel("deepseek"),
        base_url = "https://api.deepseek.com/v1/chat/completions",
        additional_parameters = {
            temperature = 0.7,
            max_tokens = 4096
        }
    },
    ollama = {
        provider = "ollama",
        model = getDefaultModel("ollama"),
        base_url = "http://localhost:11434/api/chat",
        additional_parameters = {
            temperature = 0.7
        }
    },
    gemini = {
        provider = "gemini",
        model = getDefaultModel("gemini"),
        -- Base URL without model - model is inserted dynamically by the handler
        base_url = "https://generativelanguage.googleapis.com/v1beta/models",
        additional_parameters = {
            temperature = 0.7
        }
    }
}

return {
    ProviderDefaults = ProviderDefaults,
    getDefaultModel = getDefaultModel,
    ParameterDocs = ParameterDocs
}
