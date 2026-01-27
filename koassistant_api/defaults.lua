-- Load model lists to get default models dynamically
local ModelLists = require("koassistant_model_lists")

-- Helper function to get the default model for a provider (first in the list)
-- Uses ModelLists as the primary source of truth, with fallbacks as a safety net
local function getDefaultModel(provider)
    local models = ModelLists[provider]
    if models and #models > 0 then
        return models[1]  -- Primary source: koassistant_model_lists.lua
    end
    -- Fallback models - ONLY used if ModelLists module fails to load
    -- This is intentional duplication for reliability (don't remove!)
    -- Primary source of truth remains: koassistant_model_lists.lua
    local fallbacks = {
        anthropic = "claude-sonnet-4-5-20250929",
        openai = "gpt-4.1",
        deepseek = "deepseek-chat",
        gemini = "gemini-2.5-pro",
        ollama = "llama3",
        -- New providers
        groq = "llama-3.3-70b-versatile",
        mistral = "mistral-large-latest",
        xai = "grok-3",  -- Grok 4.x doesn't exist yet (Jan 2025)
        openrouter = "anthropic/claude-sonnet-4-5",
        qwen = "qwen-max",
        kimi = "moonshot-v1-auto",
        together = "meta-llama/Llama-3.3-70B-Instruct-Turbo",
        fireworks = "accounts/fireworks/models/llama-v3p3-70b-instruct",
        sambanova = "Meta-Llama-3.3-70B-Instruct",
        cohere = "command-r-plus-08-2024",
        doubao = "doubao-1.5-pro-32k",
    }
    return fallbacks[provider] or "unknown"
end

--[[
Provider API Defaults

These are the base defaults for each provider. They define:
- Base API URLs
- Default models (via getDefaultModel from koassistant_model_lists.lua)
- Default temperature (0.7 for most providers)
- Default max_tokens (varies by provider)

IMPORTANT: Per-action temperature/token tuning is in prompts/actions.lua
Don't consolidate those here - they're intentional action-specific overrides.

Examples of per-action tuning:
- Dictionary: temperature = 0.3 (factual accuracy)
- Creative Writing: temperature = 0.8 (more creative)
- Book Summary: max_tokens = 4096 (long-form response)

Each action can override these defaults based on its specific needs.
]]
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
    },
    -- New providers (OpenAI-compatible)
    groq = {
        provider = "groq",
        model = getDefaultModel("groq"),
        base_url = "https://api.groq.com/openai/v1/chat/completions",
        additional_parameters = {
            temperature = 0.7,
            max_tokens = 4096
        }
    },
    mistral = {
        provider = "mistral",
        model = getDefaultModel("mistral"),
        base_url = "https://api.mistral.ai/v1/chat/completions",
        additional_parameters = {
            temperature = 0.7,
            max_tokens = 4096
        }
    },
    xai = {
        provider = "xai",
        model = getDefaultModel("xai"),
        base_url = "https://api.x.ai/v1/chat/completions",
        additional_parameters = {
            temperature = 0.7,
            max_tokens = 4096
        }
    },
    openrouter = {
        provider = "openrouter",
        model = getDefaultModel("openrouter"),
        base_url = "https://openrouter.ai/api/v1/chat/completions",
        additional_parameters = {
            temperature = 0.7,
            max_tokens = 4096
        }
    },
    qwen = {
        provider = "qwen",
        model = getDefaultModel("qwen"),
        base_url = "https://dashscope-intl.aliyuncs.com/compatible-mode/v1/chat/completions",
        additional_parameters = {
            temperature = 0.7,
            max_tokens = 4096
        }
    },
    kimi = {
        provider = "kimi",
        model = getDefaultModel("kimi"),
        base_url = "https://api.moonshot.cn/v1/chat/completions",
        additional_parameters = {
            temperature = 0.7,
            max_tokens = 4096
        }
    },
    together = {
        provider = "together",
        model = getDefaultModel("together"),
        base_url = "https://api.together.xyz/v1/chat/completions",
        additional_parameters = {
            temperature = 0.7,
            max_tokens = 4096
        }
    },
    fireworks = {
        provider = "fireworks",
        model = getDefaultModel("fireworks"),
        base_url = "https://api.fireworks.ai/inference/v1/chat/completions",
        additional_parameters = {
            temperature = 0.7,
            max_tokens = 4096
        }
    },
    sambanova = {
        provider = "sambanova",
        model = getDefaultModel("sambanova"),
        base_url = "https://api.sambanova.ai/v1/chat/completions",
        additional_parameters = {
            temperature = 0.7,
            max_tokens = 4096
        }
    },
    cohere = {
        provider = "cohere",
        model = getDefaultModel("cohere"),
        base_url = "https://api.cohere.com/v2/chat",
        additional_parameters = {
            temperature = 0.7,
            max_tokens = 4096
        }
    },
    doubao = {
        provider = "doubao",
        model = getDefaultModel("doubao"),
        base_url = "https://ark.cn-beijing.volces.com/api/v3/chat/completions",
        additional_parameters = {
            temperature = 0.7,
            max_tokens = 4096
        }
    }
}

--- Build defaults for a custom provider
--- @param custom_provider table: Custom provider config {id, name, base_url, default_model, api_key_required}
--- @return table: Provider defaults compatible with ProviderDefaults format
local function buildCustomProviderDefaults(custom_provider)
    return {
        provider = custom_provider.id,
        model = custom_provider.default_model or "default",
        base_url = custom_provider.base_url or "",
        is_custom = true,
        api_key_required = custom_provider.api_key_required ~= false,  -- default true
        additional_parameters = {
            temperature = 0.7,
            max_tokens = 4096
        }
    }
end

--- Get defaults for a provider (built-in or custom)
--- @param provider_id string: Provider ID
--- @param custom_providers table: Array of custom provider configs (optional)
--- @return table|nil: Provider defaults or nil if not found
local function getProviderDefaults(provider_id, custom_providers)
    -- Check built-in first
    if ProviderDefaults[provider_id] then
        return ProviderDefaults[provider_id]
    end

    -- Check custom providers
    if custom_providers then
        for _, cp in ipairs(custom_providers) do
            if cp.id == provider_id then
                return buildCustomProviderDefaults(cp)
            end
        end
    end

    return nil
end

return {
    ProviderDefaults = ProviderDefaults,
    getDefaultModel = getDefaultModel,
    getProviderDefaults = getProviderDefaults,
    buildCustomProviderDefaults = buildCustomProviderDefaults,
}
