-- Model lists for each provider
-- SINGLE SOURCE OF TRUTH for all model data
-- Last updated: 2026-01-25
--
-- Structure:
--   ModelLists[provider] = array of model IDs (for backward compat & dropdowns)
--   ModelLists._tiers = tier -> provider -> model_id mappings
--   ModelLists._docs = provider documentation URLs for update checking
--   ModelLists._model_info = model_id -> metadata (tier, context, status, etc.)

local ModelLists = {
    ---------------------------------------------------------------------------
    -- MODEL LISTS (flat arrays for backward compatibility)
    -- Order matters: first model is the default for each provider
    ---------------------------------------------------------------------------

    anthropic = {
        -- Claude 4.5 (latest generation)
        "claude-sonnet-4-5-20250929",   -- flagship (default)
        "claude-haiku-4-5-20251001",    -- fast
        "claude-opus-4-5-20251101",     -- reasoning
        -- Claude 4.x (legacy but still available)
        "claude-opus-4-1-20250805",
        "claude-sonnet-4-20250514",
        "claude-opus-4-20250514",
        -- Claude 3.x (legacy)
        "claude-3-7-sonnet-20250219",
        "claude-3-haiku-20240307",
    },

    openai = {
        -- GPT-5.2 (latest flagship, Dec 2025)
        "gpt-5.2",                      -- flagship (default)
        "gpt-5.1",
        -- GPT-5 family (Aug 2025)
        "gpt-5",
        "gpt-5-mini",                   -- standard
        "gpt-5-nano",                   -- fast
        -- GPT-4.1 family
        "gpt-4.1",
        "gpt-4.1-mini",
        "gpt-4.1-nano",                 -- ultrafast
        -- Reasoning models (o-series)
        "o3",                           -- reasoning
        "o3-pro",
        "o3-mini",
        "o4-mini",
        -- Legacy
        "gpt-4o",
        "gpt-4o-mini",
    },

    deepseek = {
        -- These are the only two official API model IDs
        "deepseek-chat",                -- flagship (default) - non-thinking
        "deepseek-reasoner",            -- reasoning - always thinks
    },

    gemini = {
        -- Gemini 2.5 (stable, recommended)
        "gemini-2.5-flash",             -- standard (default)
        "gemini-2.5-pro",               -- flagship
        "gemini-2.5-flash-lite",        -- fast
        -- Gemini 3 (preview - thinking models)
        "gemini-3-pro-preview",         -- reasoning
        "gemini-3-flash-preview",
        -- Gemini 2.0 (deprecated)
        "gemini-2.0-flash",
        "gemini-2.0-flash-lite",
    },

    ollama = {
        -- Llama 4 (Meta, Apr 2025) - multimodal MoE
        "llama4",
        "llama4:scout",
        "llama4:maverick",              -- flagship
        -- Llama 3.x (Meta)
        "llama3.3",
        "llama3.3:70b",
        "llama3.2",
        "llama3.2:3b",                  -- fast
        "llama3.2:1b",                  -- ultrafast
        "llama3.1",
        "llama3.1:8b",
        "llama3.1:70b",
        -- Qwen 3 (Alibaba, latest)
        "qwen3",
        "qwen3:0.6b",
        "qwen3:1.7b",
        "qwen3:4b",
        "qwen3:8b",
        "qwen3:14b",
        "qwen3:30b",
        "qwen3-coder",
        -- Qwen 2.5 (Alibaba)
        "qwen2.5",
        "qwen2.5:7b",
        "qwen2.5:14b",
        "qwen2.5:32b",
        "qwen2.5:72b",
        "qwen2.5-coder",
        -- DeepSeek (local)
        "deepseek-r1",                  -- reasoning
        "deepseek-r1:8b",
        "deepseek-r1:14b",
        "deepseek-r1:32b",
        "deepseek-r1:70b",
        -- Gemma 3 (Google, latest)
        "gemma3",
        "gemma3:1b",
        "gemma3:4b",
        "gemma3:12b",
        "gemma3:27b",
        -- Gemma 2 (Google)
        "gemma2",
        "gemma2:2b",
        "gemma2:9b",
        "gemma2:27b",
        -- Mistral/Mixtral
        "mistral",
        "mixtral",
        "mixtral:8x22b",
        -- Phi (Microsoft)
        "phi4",
        "phi3",
        "phi3:mini",
        "phi3:medium",
        -- Code models
        "codellama",
        "codellama:7b",
        "codellama:13b",
        "codellama:34b",
        "starcoder2",
        -- Other popular models
        "command-r",
        "neural-chat",
        "vicuna",
    },

    groq = {
        -- Llama 4 (fastest)
        "llama-4-scout-17b-16e-instruct",
        "llama-4-maverick-17b-128e-instruct",
        -- Llama 3.3
        "llama-3.3-70b-versatile",      -- flagship (default)
        "llama-3.3-70b-specdec",
        -- Qwen
        "qwen-qwq-32b",                 -- reasoning
        -- DeepSeek
        "deepseek-r1-distill-llama-70b",
        "deepseek-r1-distill-qwen-32b",
        -- Llama 3.1
        "llama-3.1-8b-instant",         -- ultrafast
    },

    mistral = {
        -- Flagship
        "mistral-large-latest",         -- flagship (default)
        "mistral-large-2411",
        -- Medium
        "mistral-medium-latest",        -- standard
        -- Coding
        "codestral-latest",
        "codestral-2501",
        -- Vision
        "pixtral-large-latest",
        "pixtral-12b-2409",
        -- Reasoning
        "magistral-medium-2507",
        "magistral-small-2507",
        -- Small/Fast
        "mistral-small-latest",         -- fast
        "ministral-8b-latest",
        "ministral-3b-latest",          -- ultrafast
        "open-mistral-nemo",
    },

    xai = {
        -- Grok 3 (current stable)
        "grok-3",                       -- flagship (default)
        "grok-3-fast",                  -- fast
        "grok-3-mini",                  -- standard (thinks)
        "grok-3-mini-fast",             -- ultrafast
        -- Grok 4.x (newer)
        "grok-4",                       -- reasoning
        "grok-4-fast",
        "grok-4-0709",
        -- Grok 4.1
        "grok-4.1-fast",
        -- Grok Code
        "grok-code-fast-1",
        -- Grok 2 Vision
        "grok-2-vision-1212",
    },

    openrouter = {
        -- Special: First entry is placeholder for custom model input
        "custom",                       -- UI shows text input
        -- Popular models (format: provider/model-name)
        "anthropic/claude-sonnet-4-5-20250929",
        "openai/gpt-5.2",
        "google/gemini-2.5-pro",
        "meta-llama/llama-4-maverick",
        "deepseek/deepseek-r1",
        "mistralai/mistral-large-2411",
        "qwen/qwen3-235b-a22b",
        "x-ai/grok-4",
    },

    qwen = {
        -- Qwen3 (latest)
        "qwen3-max",                    -- flagship (default)
        "qwen3-max-2025-09-23",
        -- Qwen Max
        "qwen-max",
        "qwen-max-2025-01-25",
        -- Qwen Plus
        "qwen-plus",                    -- standard
        "qwen-plus-latest",
        -- Turbo (fast)
        "qwen-turbo",                   -- fast
        -- Coding
        "qwen3-coder-flash",
        -- Math
        "qwen-math-plus",
    },

    kimi = {
        -- K2 (latest, 256K context)
        "kimi-k2-0711-preview",         -- flagship (default)
        "kimi-k2-thinking-preview",     -- reasoning
        -- Auto (routes to best model)
        "moonshot-v1-auto",             -- standard
        -- Specific context sizes
        "moonshot-v1-8k",               -- fast
        "moonshot-v1-32k",
        "moonshot-v1-128k",
    },

    together = {
        -- Llama 4
        "meta-llama/Llama-4-Maverick-17B-128E-Instruct-FP8",  -- flagship
        "meta-llama/Llama-4-Scout-17B-16E-Instruct",
        -- Llama 3.3
        "meta-llama/Llama-3.3-70B-Instruct-Turbo",           -- standard
        -- Qwen 3
        "Qwen/Qwen3-235B-A22B-fp8",
        "Qwen/Qwen3-32B",
        -- DeepSeek
        "deepseek-ai/DeepSeek-R1",                           -- reasoning
        "deepseek-ai/DeepSeek-R1-Distill-Llama-70B",
        -- Mistral
        "mistralai/Mistral-Large-2411",
    },

    fireworks = {
        -- Llama 4
        "accounts/fireworks/models/llama4-maverick-instruct-basic",  -- flagship
        "accounts/fireworks/models/llama4-scout-instruct-basic",
        -- Llama 3.3
        "accounts/fireworks/models/llama-v3p3-70b-instruct",         -- standard
        -- Qwen 3
        "accounts/fireworks/models/qwen3-235b-a22b",
        -- DeepSeek
        "accounts/fireworks/models/deepseek-r1",                     -- reasoning
        -- Mixtral
        "accounts/fireworks/models/mixtral-8x22b-instruct",
    },

    sambanova = {
        -- Llama 4
        "Meta-Llama-4-Maverick-17B-128E-Instruct",           -- flagship
        "Meta-Llama-4-Scout-17B-16E-Instruct",
        -- Llama 3.x
        "Meta-Llama-3.3-70B-Instruct",                       -- standard
        "Meta-Llama-3.1-405B-Instruct",
        "Meta-Llama-3.1-70B-Instruct",
        "Meta-Llama-3.1-8B-Instruct",                        -- ultrafast
        -- DeepSeek
        "DeepSeek-R1",                                       -- reasoning
        "DeepSeek-R1-Distill-Llama-70B",
        -- Qwen
        "Qwen3-32B",
    },

    cohere = {
        -- Command A (latest, strongest)
        "command-a-03-2025",            -- flagship (default)
        -- Command R+
        "command-r-plus-08-2024",       -- standard
        -- Command R
        "command-r-08-2024",            -- fast
        -- Smaller
        "command-r7b-12-2024",          -- ultrafast
    },

    doubao = {
        -- Pro models (latest)
        "doubao-1.5-pro-32k",           -- standard (default)
        "doubao-1.5-pro-256k",          -- flagship
        -- Vision
        "doubao-1.5-vision-pro-32k",
        -- Seed models (newest)
        "doubao-seed-1.6-flash",        -- fast
        -- Code
        "doubao-seed-code",
        -- Lite (fast/cheap)
        "doubao-lite-32k",              -- ultrafast
    },

    ---------------------------------------------------------------------------
    -- TIER MAPPINGS
    -- Maps tier -> provider -> recommended model_id
    -- Tiers: reasoning > flagship > standard > fast > ultrafast
    ---------------------------------------------------------------------------

    _tiers = {
        -- Models with explicit thinking/reasoning traces
        reasoning = {
            anthropic = "claude-opus-4-5-20251101",
            openai = "o3",
            deepseek = "deepseek-reasoner",
            gemini = "gemini-3-pro-preview",
            groq = "qwen-qwq-32b",
            mistral = "magistral-medium-2507",
            xai = "grok-4",
            cohere = nil,  -- No reasoning model
            ollama = "deepseek-r1",
            openrouter = "deepseek/deepseek-r1",
            together = "deepseek-ai/DeepSeek-R1",
            fireworks = "accounts/fireworks/models/deepseek-r1",
            sambanova = "DeepSeek-R1",
            qwen = "qwen3-max",
            kimi = "kimi-k2-thinking-preview",
            doubao = "doubao-1.5-pro-256k",
        },

        -- Provider's most capable general-purpose model
        flagship = {
            anthropic = "claude-sonnet-4-5-20250929",
            openai = "gpt-5.2",
            deepseek = "deepseek-chat",
            gemini = "gemini-2.5-pro",
            groq = "llama-3.3-70b-versatile",
            mistral = "mistral-large-latest",
            xai = "grok-3",
            cohere = "command-a-03-2025",
            ollama = "llama4:maverick",
            openrouter = "anthropic/claude-sonnet-4-5-20250929",
            together = "meta-llama/Llama-4-Maverick-17B-128E-Instruct-FP8",
            fireworks = "accounts/fireworks/models/llama4-maverick-instruct-basic",
            sambanova = "Meta-Llama-4-Maverick-17B-128E-Instruct",
            qwen = "qwen3-max",
            kimi = "kimi-k2-0711-preview",
            doubao = "doubao-1.5-pro-256k",
        },

        -- Balanced performance and cost
        standard = {
            anthropic = "claude-sonnet-4-5-20250929",
            openai = "gpt-5-mini",
            deepseek = "deepseek-chat",
            gemini = "gemini-2.5-flash",
            groq = "llama-3.3-70b-versatile",
            mistral = "mistral-medium-latest",
            xai = "grok-3-mini",
            cohere = "command-r-plus-08-2024",
            ollama = "llama3.3:70b",
            openrouter = "google/gemini-2.5-pro",
            together = "meta-llama/Llama-3.3-70B-Instruct-Turbo",
            fireworks = "accounts/fireworks/models/llama-v3p3-70b-instruct",
            sambanova = "Meta-Llama-3.3-70B-Instruct",
            qwen = "qwen-plus",
            kimi = "moonshot-v1-auto",
            doubao = "doubao-1.5-pro-32k",
        },

        -- Optimized for speed and lower cost
        fast = {
            anthropic = "claude-haiku-4-5-20251001",
            openai = "gpt-5-nano",
            deepseek = "deepseek-chat",
            gemini = "gemini-2.5-flash-lite",
            groq = "llama-3.1-8b-instant",
            mistral = "mistral-small-latest",
            xai = "grok-3-fast",
            cohere = "command-r-08-2024",
            ollama = "llama3.2:3b",
            openrouter = "google/gemini-2.5-flash",
            together = "Qwen/Qwen3-32B",
            fireworks = "accounts/fireworks/models/llama-v3p3-70b-instruct",
            sambanova = "Meta-Llama-3.1-8B-Instruct",
            qwen = "qwen-turbo",
            kimi = "moonshot-v1-8k",
            doubao = "doubao-seed-1.6-flash",
        },

        -- Smallest/cheapest models for basic tasks
        ultrafast = {
            anthropic = "claude-haiku-4-5-20251001",
            openai = "gpt-4.1-nano",
            deepseek = "deepseek-chat",
            gemini = "gemini-2.5-flash-lite",
            groq = "llama-3.1-8b-instant",
            mistral = "ministral-3b-latest",
            xai = "grok-3-mini-fast",
            cohere = "command-r7b-12-2024",
            ollama = "llama3.2:1b",
            openrouter = "mistralai/ministral-3b-latest",
            together = "Qwen/Qwen3-32B",
            fireworks = "accounts/fireworks/models/llama-v3p3-70b-instruct",
            sambanova = "Meta-Llama-3.1-8B-Instruct",
            qwen = "qwen-turbo",
            kimi = "moonshot-v1-8k",
            doubao = "doubao-lite-32k",
        },
    },

    ---------------------------------------------------------------------------
    -- DOCUMENTATION SOURCES
    -- For update checking - where to find current model lists
    ---------------------------------------------------------------------------

    _docs = {
        anthropic = {
            api_list = "https://api.anthropic.com/v1/models",
            docs = "https://docs.anthropic.com/en/docs/about-claude/models/all-models",
            curl = "curl https://api.anthropic.com/v1/models -H 'anthropic-version: 2023-06-01' -H 'x-api-key: $ANTHROPIC_API_KEY'",
        },
        openai = {
            api_list = "https://api.openai.com/v1/models",
            docs = "https://platform.openai.com/docs/models",
            curl = "curl https://api.openai.com/v1/models -H 'Authorization: Bearer $OPENAI_API_KEY'",
        },
        deepseek = {
            api_list = "https://api.deepseek.com/v1/models",
            docs = "https://api-docs.deepseek.com/quick_start/pricing",
        },
        gemini = {
            api_list = "https://generativelanguage.googleapis.com/v1beta/models",
            docs = "https://ai.google.dev/gemini-api/docs/models/gemini",
            curl = "curl 'https://generativelanguage.googleapis.com/v1beta/models?key=$GEMINI_API_KEY'",
        },
        groq = {
            api_list = "https://api.groq.com/openai/v1/models",
            docs = "https://console.groq.com/docs/models",
        },
        mistral = {
            api_list = "https://api.mistral.ai/v1/models",
            docs = "https://docs.mistral.ai/getting-started/models/models_overview/",
        },
        xai = {
            api_list = "https://api.x.ai/v1/models",
            docs = "https://docs.x.ai/docs/models",
        },
        openrouter = {
            api_list = "https://openrouter.ai/api/v1/models",
            docs = "https://openrouter.ai/models",
        },
        qwen = {
            docs = "https://help.aliyun.com/zh/model-studio/getting-started/models",
        },
        kimi = {
            docs = "https://platform.moonshot.cn/docs/intro",
        },
        together = {
            api_list = "https://api.together.xyz/v1/models",
            docs = "https://docs.together.ai/docs/inference-models",
        },
        fireworks = {
            docs = "https://docs.fireworks.ai/getting-started/quickstart",
        },
        sambanova = {
            api_list = "https://api.sambanova.ai/v1/models",
            docs = "https://community.sambanova.ai/t/supported-models/193",
        },
        cohere = {
            api_list = "https://api.cohere.com/v1/models",
            docs = "https://docs.cohere.com/docs/models",
        },
        doubao = {
            docs = "https://www.volcengine.com/docs/82379/1263482",
        },
        ollama = {
            api_list = "http://localhost:11434/api/tags",
            docs = "https://github.com/ollama/ollama/blob/main/docs/api.md",
            library = "https://ollama.com/library",
        },
    },

    ---------------------------------------------------------------------------
    -- TIER DEFINITIONS
    -- Human-readable descriptions for each tier
    ---------------------------------------------------------------------------

    _tier_info = {
        reasoning = {
            description = "Models with explicit thinking/reasoning traces",
            typical_use = "Complex analysis, multi-step reasoning, scholarly work, math",
        },
        flagship = {
            description = "Provider's most capable general-purpose model",
            typical_use = "Quality-critical tasks, comprehensive assistance",
        },
        standard = {
            description = "Balanced performance and cost",
            typical_use = "Daily reading assistance, general queries",
        },
        fast = {
            description = "Optimized for speed and lower cost",
            typical_use = "Quick lookups, simple explanations, definitions",
        },
        ultrafast = {
            description = "Smallest/cheapest models for basic tasks",
            typical_use = "Vocabulary, definitions, very basic tasks",
        },
    },
}

-------------------------------------------------------------------------------
-- HELPER FUNCTIONS
-------------------------------------------------------------------------------

-- Get sorted list of all provider names
function ModelLists.getAllProviders()
    local providers = {}
    for provider, _ in pairs(ModelLists) do
        -- Skip internal tables (start with _) and functions
        if type(ModelLists[provider]) == "table" and not provider:match("^_") then
            table.insert(providers, provider)
        end
    end
    table.sort(providers)
    return providers
end

-- Get model for a specific tier and provider (with fallback)
-- @param provider string - Provider name
-- @param tier string - Tier name (reasoning/flagship/standard/fast/ultrafast)
-- @param fallback boolean - If true, falls back to next tier (default: true)
-- @return string|nil - Model ID or nil
function ModelLists.getModelForTier(provider, tier, fallback)
    if fallback == nil then fallback = true end

    local tier_order = {"reasoning", "flagship", "standard", "fast", "ultrafast"}

    -- Direct lookup
    local tier_map = ModelLists._tiers[tier]
    if tier_map and tier_map[provider] then
        return tier_map[provider]
    end

    -- Fallback to next tier
    if fallback then
        local start_idx = 1
        for i, t in ipairs(tier_order) do
            if t == tier then
                start_idx = i + 1
                break
            end
        end

        for i = start_idx, #tier_order do
            local fallback_tier = tier_order[i]
            local fallback_map = ModelLists._tiers[fallback_tier]
            if fallback_map and fallback_map[provider] then
                return fallback_map[provider]
            end
        end
    end

    return nil
end

-- Get the tier for a given model
-- @param provider string - Provider name
-- @param model_id string - Model ID
-- @return string - Tier name (defaults to "standard")
function ModelLists.getTierForModel(provider, model_id)
    for tier_name, tier_map in pairs(ModelLists._tiers) do
        if tier_map[provider] == model_id then
            return tier_name
        end
    end
    return "standard"
end

-- Check if provider has a reasoning model
-- @param provider string - Provider name
-- @return boolean
function ModelLists.hasReasoningModel(provider)
    return ModelLists._tiers.reasoning[provider] ~= nil
end

-- Get tier info (description and typical use)
-- @param tier string - Tier name
-- @return table|nil - {description, typical_use}
function ModelLists.getTierInfo(tier)
    return ModelLists._tier_info[tier]
end

-- Get documentation URLs for a provider
-- @param provider string - Provider name
-- @return table|nil - {api_list, docs, curl, ...}
function ModelLists.getDocs(provider)
    return ModelLists._docs[provider]
end

return ModelLists
