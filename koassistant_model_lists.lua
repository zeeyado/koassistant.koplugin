-- Model lists for each provider
-- SINGLE SOURCE OF TRUTH for all model data
-- Last updated: 2026-06-07
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
        -- Claude 4.x (current generation)
        "claude-sonnet-4-6",            -- flagship (default), 1M context
        "claude-opus-4-8",              -- reasoning (most capable, adaptive thinking only)
        "claude-haiku-4-5-20251001",    -- fast
    },

    openai = {
        -- GPT-5.5 (current flagship)
        "gpt-5.5",                      -- flagship (default), reasons by default (medium)
        -- GPT-5.4 (concurrent affordable tier)
        "gpt-5.4",
        "gpt-5.4-mini",                 -- standard
        "gpt-5.4-nano",                 -- fast/ultrafast
        -- NOTE: gpt-5.5-pro / gpt-5.4-pro are NOT chat-completions models
        -- (v1/responses only) — excluded so they don't 404 here.
    },

    deepseek = {
        -- DeepSeek V4 (current generation, 1M context, thinking on by default)
        "deepseek-v4-pro",              -- flagship (default) + reasoning
        "deepseek-v4-flash",            -- standard/fast
    },

    gemini = {
        -- Gemini 3.x (current generation)
        "gemini-3.5-flash",             -- standard (default), free tier
        "gemini-3.1-pro-preview",       -- flagship, reasoning (paid only)
        "gemini-3.1-flash-lite",        -- ultrafast, free tier
        -- Gemini 2.5 (kept for popularity)
        "gemini-2.5-flash",             -- still popular, free tier
    },

    ollama = {
        -- Llama (Meta) - most popular open models
        "llama4",                       -- latest Llama (default)
        "llama3.3",
        "llama3.3:70b",
        "llama3.2",
        "llama3.2:3b",                  -- fast
        -- Qwen (Alibaba) - excellent multilingual
        "qwen3.5",
        "qwen3",
        "qwen3:8b",
        "qwen3:32b",
        -- DeepSeek
        "deepseek-v4",
        "deepseek-r1",                  -- reasoning
        "deepseek-r1:8b",
        -- Gemma (Google)
        "gemma4",
        "gemma3",
        "gemma3:4b",
        "gemma3:27b",
        -- Mistral
        "mistral",
        "mistral-nemo",                 -- Apache 2.0, 12B
        -- Phi (Microsoft) - small but capable
        "phi4",
        -- Tiny models
        "tinyllama",                    -- ~637MB, good for testing
    },

    groq = {
        -- Production models (FREE tier with rate limits)
        "llama-3.3-70b-versatile",                      -- flagship (default)
        "llama-3.1-8b-instant",                         -- ultrafast
        "openai/gpt-oss-120b",                          -- OpenAI open-weight
        "openai/gpt-oss-20b",                           -- OpenAI open-weight (fast)
        -- Preview models
        "meta-llama/llama-4-scout-17b-16e-instruct",
        "qwen/qwen3-32b",
        -- Compound AI (agentic)
        "groq/compound",                                -- web search + code exec
        "groq/compound-mini",
    },

    mistral = {
        -- Flagship (Mistral Large 3 via -latest alias)
        "mistral-large-latest",         -- flagship (default)
        -- Medium (Mistral Medium 3.5)
        "mistral-medium-latest",        -- standard
        -- Small (Mistral Small 4 - unified reasoning/multimodal/coding, open-weight)
        "mistral-small-latest",         -- fast (open-weight)
        -- Reasoning (Magistral 1.2)
        "magistral-medium-latest",
        "magistral-small-latest",       -- open-weight (Apache 2.0)
        -- Coding
        "codestral-latest",
        "devstral-2512",                -- code agents (Devstral 2, Apache 2.0)
    },

    xai = {
        -- Grok 4.3 (current flagship, 1M context)
        "grok-4.3",                     -- flagship (default) + reasoning
        -- Grok 4.20 (1M context; reasoning toggle baked into the slug)
        "grok-4.20-0309-non-reasoning", -- standard/fast
        "grok-4.20-0309-reasoning",     -- reasoning
        -- Specialized
        "grok-build-0.1",               -- coding (256K context)
    },

    openrouter = {
        -- OpenRouter model naming differs from direct provider APIs
        -- Format: provider/model-name (no "-latest" suffixes, periods not dashes)

        -- Anthropic
        "anthropic/claude-sonnet-4.6",  -- default (flagship)
        "anthropic/claude-opus-4.8",
        "anthropic/claude-haiku-4.5",

        -- OpenAI
        "openai/gpt-5.5",
        "openai/gpt-5.5-pro",
        "openai/gpt-5.4",
        "openai/gpt-5.4-mini",

        -- Google
        "google/gemini-3.5-flash",
        "google/gemini-3-flash-preview",

        -- DeepSeek
        "deepseek/deepseek-v4-pro",
        "deepseek/deepseek-v4-flash",

        -- xAI Grok
        "x-ai/grok-4.3",
        "x-ai/grok-4.20",

        -- Meta Llama
        "meta-llama/llama-3.3-70b-instruct",

        -- Mistral
        "mistralai/mistral-large-2512",
        "mistralai/mistral-medium-3.1",

        -- Qwen
        "qwen/qwen3-max",
        "qwen/qwen3-235b-a22b",

        -- Perplexity (built-in web search)
        "perplexity/sonar-pro",
        "perplexity/sonar-reasoning-pro",
        "perplexity/sonar",

        -- Other notable
        "moonshotai/kimi-k2-thinking",
        "minimax/minimax-m2.1",
    },

    qwen = {
        -- Qwen3 / Qwen3.5 (current)
        "qwen3-max",                    -- flagship (default)
        "qwen3.5-plus",                 -- standard
        "qwen3.5-flash",                -- fast
        "qwen-turbo",                   -- ultrafast
        "qwen3-coder-plus",             -- coding
    },

    kimi = {
        -- Kimi K2.6 (current, multimodal)
        "kimi-k2.6",                    -- flagship (default)
        "kimi-k2.6-thinking",           -- reasoning
        "kimi-k2-turbo-preview",        -- fast
    },

    together = {
        -- DeepSeek V4 (current)
        "deepseek-ai/DeepSeek-V4-Pro",                       -- flagship + reasoning
        "deepseek-ai/DeepSeek-V4-Flash",
        -- Qwen
        "Qwen/Qwen3.5-397B-A17B",                            -- MoE flagship
        "Qwen/Qwen3-235B-A22B-Instruct-2507-tput",
        -- Llama 3.3
        "meta-llama/Llama-3.3-70B-Instruct-Turbo",           -- standard/fast
        -- Other
        "moonshotai/Kimi-K2.6",
        "zai-org/GLM-5",
        "MiniMaxAI/MiniMax-M2.7",
    },

    fireworks = {
        -- DeepSeek (current)
        "accounts/fireworks/models/deepseek-v4-pro",                 -- flagship + reasoning
        "accounts/fireworks/models/deepseek-r1",                     -- reasoning
        -- Llama 3.3
        "accounts/fireworks/models/llama-v3p3-70b-instruct",         -- standard/fast
        -- Qwen 3
        "accounts/fireworks/models/qwen3-235b-a22b",
        -- Other
        "accounts/fireworks/models/kimi-k2-thinking",                -- reasoning
        "accounts/fireworks/models/glm-5",
        "accounts/fireworks/models/gpt-oss-120b",
    },

    sambanova = {
        -- Llama 4
        "Llama-4-Maverick-17B-128E-Instruct",                -- flagship
        -- DeepSeek
        "DeepSeek-V3.1",                                     -- reasoning
        "DeepSeek-V3.2",
        -- Llama 3.x
        "Meta-Llama-3.3-70B-Instruct",                       -- standard/fast
        -- Other
        "MiniMax-M2.7",
        "gemma-4-31B-it",
        "gpt-oss-120b",
    },

    cohere = {
        -- Command A+ (latest, strongest - first MoE)
        "command-a-plus-05-2026",       -- flagship (default)
        -- Reasoning
        "command-a-reasoning-08-2025",  -- reasoning
        -- Smaller/fast
        "command-r7b-12-2024",          -- fast
    },

    doubao = {
        -- Doubao Seed 2.0 (current, Feb 2026)
        -- NOTE: native ARK may require date-suffixed snapshot or endpoint IDs;
        -- verify exact strings in the Volcengine console.
        "doubao-seed-2.0-pro-32k",      -- flagship (default)
        "doubao-seed-2.0-pro-256k",
        "doubao-seed-2.0-lite",         -- fast
        "doubao-seed-2.0-code",         -- coding
    },

    perplexity = {
        -- All Sonar models include built-in web search with citations
        "sonar-pro",                    -- flagship (default, advanced search)
        "sonar-reasoning-pro",          -- reasoning + search
        "sonar-deep-research",          -- deep research
        "sonar",                        -- fast search (lightweight)
    },

    zai = {
        -- GLM-5.x (200K context)
        "glm-5.1",                      -- flagship (default), coding leader
        "glm-5",
        "glm-5-turbo",                  -- fast
        -- GLM-4.7 (200K context)
        "glm-4.7",                      -- reasoning
        "glm-4.7-flash",                -- free tier
    },

    ---------------------------------------------------------------------------
    -- TIER MAPPINGS
    -- Maps tier -> provider -> recommended model_id
    -- Tiers: reasoning > flagship > standard > fast > ultrafast
    ---------------------------------------------------------------------------

    _tiers = {
        -- Models with explicit thinking/reasoning traces
        reasoning = {
            anthropic = "claude-opus-4-8",
            openai = "gpt-5.5",
            deepseek = "deepseek-v4-pro",
            gemini = "gemini-3.1-pro-preview",
            groq = "openai/gpt-oss-120b",            -- OpenAI open-weight
            mistral = "magistral-medium-latest",
            xai = "grok-4.3",
            cohere = "command-a-reasoning-08-2025",
            ollama = "deepseek-r1",
            openrouter = "deepseek/deepseek-v4-pro",
            together = "deepseek-ai/DeepSeek-V4-Pro",
            fireworks = "accounts/fireworks/models/deepseek-v4-pro",
            sambanova = "DeepSeek-V3.1",
            qwen = "qwen3-max",
            kimi = "kimi-k2.6-thinking",
            doubao = "doubao-seed-2.0-pro-256k",
            zai = "glm-4.7",
            perplexity = "sonar-reasoning-pro",
        },

        -- Provider's most capable general-purpose model
        flagship = {
            anthropic = "claude-sonnet-4-6",
            openai = "gpt-5.5",
            deepseek = "deepseek-v4-pro",
            gemini = "gemini-3.1-pro-preview",
            groq = "llama-3.3-70b-versatile",
            mistral = "mistral-large-latest",
            xai = "grok-4.3",
            cohere = "command-a-plus-05-2026",
            ollama = "llama4",
            openrouter = "anthropic/claude-sonnet-4.6",
            together = "deepseek-ai/DeepSeek-V4-Pro",
            fireworks = "accounts/fireworks/models/deepseek-v4-pro",
            sambanova = "Llama-4-Maverick-17B-128E-Instruct",
            qwen = "qwen3-max",
            kimi = "kimi-k2.6",
            doubao = "doubao-seed-2.0-pro-32k",
            zai = "glm-5.1",
            perplexity = "sonar-pro",
        },

        -- Balanced performance and cost
        standard = {
            anthropic = "claude-sonnet-4-6",
            openai = "gpt-5.4-mini",
            deepseek = "deepseek-v4-flash",
            gemini = "gemini-3.5-flash",
            groq = "llama-3.3-70b-versatile",
            mistral = "mistral-medium-latest",
            xai = "grok-4.20-0309-non-reasoning",
            cohere = "command-a-plus-05-2026",
            ollama = "llama3.3",
            openrouter = "google/gemini-3.5-flash",
            together = "meta-llama/Llama-3.3-70B-Instruct-Turbo",
            fireworks = "accounts/fireworks/models/llama-v3p3-70b-instruct",
            sambanova = "Meta-Llama-3.3-70B-Instruct",
            qwen = "qwen3.5-plus",
            kimi = "kimi-k2.6",
            doubao = "doubao-seed-2.0-pro-32k",
            zai = "glm-5",
            perplexity = "sonar",
        },

        -- Optimized for speed and lower cost
        fast = {
            anthropic = "claude-haiku-4-5-20251001",
            openai = "gpt-5.4-nano",
            deepseek = "deepseek-v4-flash",
            gemini = "gemini-3.5-flash",
            groq = "llama-3.1-8b-instant",
            mistral = "mistral-small-latest",
            xai = "grok-4.20-0309-non-reasoning",
            cohere = "command-r7b-12-2024",
            ollama = "llama3.2:3b",
            openrouter = "google/gemini-3.5-flash",
            together = "meta-llama/Llama-3.3-70B-Instruct-Turbo",
            fireworks = "accounts/fireworks/models/llama-v3p3-70b-instruct",
            sambanova = "Meta-Llama-3.3-70B-Instruct",
            qwen = "qwen3.5-flash",
            kimi = "kimi-k2-turbo-preview",
            doubao = "doubao-seed-2.0-lite",
            zai = "glm-5-turbo",
            perplexity = "sonar",
        },

        -- Smallest/cheapest models for basic tasks
        ultrafast = {
            anthropic = "claude-haiku-4-5-20251001",
            openai = "gpt-5.4-nano",
            deepseek = "deepseek-v4-flash",
            gemini = "gemini-3.1-flash-lite",
            groq = "llama-3.1-8b-instant",
            mistral = "mistral-small-latest",
            xai = "grok-4.20-0309-non-reasoning",
            cohere = "command-r7b-12-2024",
            ollama = "tinyllama",
            openrouter = "google/gemini-3.5-flash",   -- FREE tier
            together = "meta-llama/Llama-3.3-70B-Instruct-Turbo",
            fireworks = "accounts/fireworks/models/llama-v3p3-70b-instruct",
            sambanova = "Meta-Llama-3.3-70B-Instruct",
            qwen = "qwen-turbo",
            kimi = "kimi-k2-turbo-preview",
            doubao = "doubao-seed-2.0-lite",
            zai = "glm-4.7-flash",
            perplexity = "sonar",
        },
    },

    ---------------------------------------------------------------------------
    -- DOCUMENTATION SOURCES
    -- For update checking - where to find current model lists
    --
    -- NOTE: Each provider has unique model ID formats. No universal source.
    -- Always verify model strings against the provider's own API/docs.
    ---------------------------------------------------------------------------

    _docs = {
        anthropic = {
            api_list = "https://api.anthropic.com/v1/models",
            docs = "https://docs.anthropic.com/en/docs/about-claude/models",
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
        perplexity = {
            docs = "https://docs.perplexity.ai/",
        },
        zai = {
            api_list = "https://api.z.ai/api/paas/v4/models",
            docs = "https://docs.z.ai/api-reference/llm/chat-completion",
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

-- Get sorted list of all providers including custom ones
-- @param custom_providers table - Array of custom provider objects {id, name, base_url, ...}
-- @return table, table - Array of provider IDs, table mapping ID -> is_custom
function ModelLists.getAllProvidersWithCustom(custom_providers)
    local providers = ModelLists.getAllProviders()
    local is_custom = {}

    -- Add custom providers
    if custom_providers and type(custom_providers) == "table" then
        for _, cp in ipairs(custom_providers) do
            if cp.id then
                table.insert(providers, cp.id)
                is_custom[cp.id] = true
            end
        end
    end

    table.sort(providers)
    return providers, is_custom
end

-- Check if a provider ID is a built-in provider
-- @param provider_id string - Provider ID to check
-- @return boolean
function ModelLists.isBuiltInProvider(provider_id)
    return ModelLists[provider_id] ~= nil and type(ModelLists[provider_id]) == "table"
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
