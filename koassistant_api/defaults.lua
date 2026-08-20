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
        anthropic = "claude-sonnet-5",
        openai = "gpt-5.5",
        deepseek = "deepseek-v4-pro",
        gemini = "gemini-3.5-flash",
        ollama = "llama4",
        groq = "openai/gpt-oss-120b",
        mistral = "mistral-large-latest",
        xai = "grok-4.5",
        openrouter = "anthropic/claude-sonnet-5",
        requesty = "openai/gpt-4o-mini",
        qwen = "qwen3-max",
        kimi = "kimi-k2.6",
        together = "deepseek-ai/DeepSeek-V4-Pro",
        fireworks = "accounts/fireworks/models/deepseek-v4-pro",
        sambanova = "gpt-oss-120b",
        cohere = "command-a-plus-05-2026",
        doubao = "doubao-seed-2.0-pro-32k",
        zai = "glm-5.2",
        perplexity = "sonar-pro",
    }
    return fallbacks[provider] or "unknown"
end

--[[
Provider API Defaults

These are the base defaults for each provider. They define:
- Base API URLs
- Default models (via getDefaultModel from koassistant_model_lists.lua)
- Default temperature (0.7 for most providers)
- FALLBACK max_tokens (16384 curated / 4096 community — community models often
  cap low and have no ceiling data, so their low fallback is load-bearing).
  Since item 27 (2026-08-06) the fallback only applies to UNKNOWN models:
  handlers route defaults through ModelConstraints.resolveMaxTokens, which
  raises known-ceiling models to min(32768, ceiling) so reasoning/thinking
  (billed against the same budget everywhere) can't starve the answer.

IMPORTANT: Per-action temperature tuning is in prompts/actions.lua. The old
per-action max_tokens pins (4096/8192) were removed with item 27 — max_tokens
is a guillotine, not a style control, and starved pins were truncating
reasoning models to nothing (issue #98). Only deliberate RAISES above the 32K
target remain pinned (X-Ray/merge 65536).
]]
local ProviderDefaults = {
    anthropic = {
        provider = "anthropic",
        model = getDefaultModel("anthropic"),
        base_url = "https://api.anthropic.com/v1/messages",
        additional_parameters = {
            anthropic_version = "2023-06-01",
            max_tokens = 16384,
            temperature = 0.7,  -- Added: Anthropic defaults to 1.0 without this
        }
    },
    openai = {
        provider = "openai",
        model = getDefaultModel("openai"),
        base_url = "https://api.openai.com/v1/chat/completions",
        additional_parameters = {
            temperature = 0.7,
            max_tokens = 16384
        }
    },
    openai_codex = {
        provider = "openai_codex",
        model = getDefaultModel("openai_codex"),
        base_url = "https://chatgpt.com/backend-api/codex/responses",
        additional_parameters = {
            max_tokens = 16384
        }
    },
    deepseek = {
        provider = "deepseek",
        model = getDefaultModel("deepseek"),
        base_url = "https://api.deepseek.com/v1/chat/completions",
        additional_parameters = {
            temperature = 0.7,
            max_tokens = 16384
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
            max_tokens = 16384
        }
    },
    mistral = {
        provider = "mistral",
        model = getDefaultModel("mistral"),
        base_url = "https://api.mistral.ai/v1/chat/completions",
        additional_parameters = {
            temperature = 0.7,
            max_tokens = 16384
        }
    },
    xai = {
        provider = "xai",
        model = getDefaultModel("xai"),
        base_url = "https://api.x.ai/v1/chat/completions",
        additional_parameters = {
            temperature = 0.7,
            max_tokens = 16384
        }
    },
    openrouter = {
        provider = "openrouter",
        model = getDefaultModel("openrouter"),
        base_url = "https://openrouter.ai/api/v1/chat/completions",
        additional_parameters = {
            temperature = 0.7,
            max_tokens = 16384
        }
    },
    requesty = {
        provider = "requesty",
        model = getDefaultModel("requesty"),
        base_url = "https://router.requesty.ai/v1/chat/completions",
        additional_parameters = {
            temperature = 0.7,
            max_tokens = 16384
        }
    },
    qwen = {
        provider = "qwen",
        model = getDefaultModel("qwen"),
        base_url = "https://dashscope-intl.aliyuncs.com/compatible-mode/v1/chat/completions",
        additional_parameters = {
            temperature = 0.7,
            max_tokens = 16384
        }
    },
    kimi = {
        provider = "kimi",
        model = getDefaultModel("kimi"),
        -- International platform (the default since 2026-08-14; was .cn).
        -- kimi.lua:customizeUrl swaps per features.kimi_region — the two
        -- platforms' keys are NOT interchangeable (T9 2026-08-14); a one-time
        -- migration stamps pre-split keyed installs "china".
        base_url = "https://api.moonshot.ai/v1/chat/completions",
        additional_parameters = {
            temperature = 0.7,
            max_tokens = 16384
        }
    },
    together = {
        provider = "together",
        model = getDefaultModel("together"),
        base_url = "https://api.together.xyz/v1/chat/completions",
        additional_parameters = {
            temperature = 0.7,
            max_tokens = 16384
        }
    },
    fireworks = {
        provider = "fireworks",
        model = getDefaultModel("fireworks"),
        base_url = "https://api.fireworks.ai/inference/v1/chat/completions",
        additional_parameters = {
            temperature = 0.7,
            max_tokens = 16384
        }
    },
    sambanova = {
        provider = "sambanova",
        model = getDefaultModel("sambanova"),
        base_url = "https://api.sambanova.ai/v1/chat/completions",
        additional_parameters = {
            temperature = 0.7,
            max_tokens = 16384
        }
    },
    cohere = {
        provider = "cohere",
        model = getDefaultModel("cohere"),
        base_url = "https://api.cohere.com/v2/chat",
        additional_parameters = {
            temperature = 0.7,
            max_tokens = 16384
        }
    },
    doubao = {
        provider = "doubao",
        model = getDefaultModel("doubao"),
        base_url = "https://ark.cn-beijing.volces.com/api/v3/chat/completions",
        additional_parameters = {
            temperature = 0.7,
            max_tokens = 16384
        }
    },
    zai = {
        provider = "zai",
        model = getDefaultModel("zai"),
        base_url = "https://api.z.ai/api/paas/v4/chat/completions",
        additional_parameters = {
            temperature = 0.7,
            max_tokens = 16384
        }
    },
    perplexity = {
        provider = "perplexity",
        model = getDefaultModel("perplexity"),
        base_url = "https://api.perplexity.ai/chat/completions",
        additional_parameters = {
            temperature = 0.7,
            max_tokens = 16384
        }
    },

    -- Community set (M1, model_management_strategy.md "End-state REVISION 2"):
    -- docs-based, no maintainer key yet.
    --
    -- These fallbacks are the LAST resort — they apply only to a model with no
    -- ceiling entry in ModelConstraints._max_output_tokens. Raising one is the
    -- single riskiest edit in this file: too high is an unconditional 400 on
    -- every request, and there is no in-app way for a user to lower it. Prefer
    -- adding a ceiling entry (which can only help) over raising a fallback.
    --
    -- Round 3 (2026-08-09) raised the three where documentation is strong:
    -- cerebras/minimax/deepinfra 4096 -> 16384. The rest deliberately STAY at
    -- 4096, against the instinct to flatten them, because their live catalogs
    -- disprove it:
    --   vercel      floor 4000 across the gateway (30 of 209 models < 16384) --
    --               4096 already exceeds 5 Mistral models; needs ceiling entries
    --   featherless 2048 context floor over a ~21k-model catalog (~35% < 16384)
    --   novita      floor 3200; llama-3.3-70b-instruct's output cap EQUALS its
    --               12288 context, so a bigger ask is an instant 400
    --   chutes      per-chute default is 1024, templates 2048-8192
    --   hyperbolic  no data of any kind; an honest unknown beats a confident guess
    -- The real fix for these is per-model ceilings (see _max_output_tokens) or a
    -- self-healing retry on a max_tokens 400 -- not a flat number.
    cerebras = {
        provider = "cerebras",
        model = getDefaultModel("cerebras"),
        base_url = "https://api.cerebras.ai/v1/chat/completions",
        additional_parameters = { temperature = 0.7, max_tokens = 16384 }
    },
    minimax = {
        provider = "minimax",
        model = getDefaultModel("minimax"),
        base_url = "https://api.minimax.io/v1/chat/completions",
        additional_parameters = { temperature = 0.7, max_tokens = 16384 }
    },
    deepinfra = {
        provider = "deepinfra",
        model = getDefaultModel("deepinfra"),
        base_url = "https://api.deepinfra.com/v1/openai/chat/completions",
        additional_parameters = { temperature = 0.7, max_tokens = 16384 }
    },
    novita = {
        provider = "novita",
        model = getDefaultModel("novita"),
        base_url = "https://api.novita.ai/openai/chat/completions",
        additional_parameters = { temperature = 0.7, max_tokens = 4096 }
    },
    hyperbolic = {
        provider = "hyperbolic",
        model = getDefaultModel("hyperbolic"),
        base_url = "https://api.hyperbolic.xyz/v1/chat/completions",
        additional_parameters = { temperature = 0.7, max_tokens = 4096 }
    },
    nvidia = {
        provider = "nvidia",
        model = getDefaultModel("nvidia"),
        base_url = "https://integrate.api.nvidia.com/v1/chat/completions",
        additional_parameters = { temperature = 0.7, max_tokens = 4096 }
    },
    nebius = {
        provider = "nebius",
        model = getDefaultModel("nebius"),
        base_url = "https://api.studio.nebius.com/v1/chat/completions",
        additional_parameters = { temperature = 0.7, max_tokens = 4096 }
    },
    chutes = {
        provider = "chutes",
        model = getDefaultModel("chutes"),
        base_url = "https://llm.chutes.ai/v1/chat/completions",
        additional_parameters = { temperature = 0.7, max_tokens = 4096 }
    },
    featherless = {
        provider = "featherless",
        model = getDefaultModel("featherless"),
        base_url = "https://api.featherless.ai/v1/chat/completions",
        additional_parameters = { temperature = 0.7, max_tokens = 4096 }
    },
    vercel = {
        provider = "vercel",
        model = getDefaultModel("vercel"),
        base_url = "https://ai-gateway.vercel.sh/v1/chat/completions",
        additional_parameters = { temperature = 0.7, max_tokens = 4096 }
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
            max_tokens = 16384
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
