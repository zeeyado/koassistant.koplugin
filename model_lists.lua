-- Model lists for each provider
-- Last updated: January 2026
local ModelLists = {
    anthropic = {
        -- Claude 4.5 (latest generation)
        "claude-sonnet-4-5-20250929",
        "claude-haiku-4-5-20251001",
        "claude-opus-4-5-20251101",
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
        "gpt-5.2",
        -- "gpt-5.2-pro",  -- Not a chat model (use v1/completions instead)
        -- GPT-5.1
        "gpt-5.1",
        -- GPT-5 family (Aug 2025)
        "gpt-5",
        "gpt-5-mini",
        "gpt-5-nano",
        -- GPT-4.1 family
        "gpt-4.1",
        "gpt-4.1-mini",
        "gpt-4.1-nano",
        -- Reasoning models (o-series)
        "o3",
        "o3-pro",
        "o3-mini",
        "o4-mini",
        -- Legacy
        "gpt-4o",
        "gpt-4o-mini",
    },
    deepseek = {
        -- These are the only two official API model IDs
        -- deepseek-chat = DeepSeek-V3.2 (non-thinking mode)
        -- deepseek-reasoner = DeepSeek-V3.2 (thinking/reasoning mode)
        "deepseek-chat",
        "deepseek-reasoner",
    },
    gemini = {
        -- Gemini 2.5 (stable, recommended)
        "gemini-2.5-pro",
        "gemini-2.5-flash",
        "gemini-2.5-flash-lite",
        -- Gemini 3 (preview - thinking models, use more tokens)
        "gemini-3-pro-preview",
        "gemini-3-flash-preview",
        -- Gemini 2.0
        "gemini-2.0-flash",
        "gemini-2.0-flash-lite",
    },
    ollama = {
        -- Llama 4 (Meta, Apr 2025) - multimodal MoE
        "llama4",
        "llama4:scout",
        "llama4:maverick",
        -- Llama 3.x (Meta)
        "llama3.3",
        "llama3.3:70b",
        "llama3.2",
        "llama3.2:3b",
        "llama3.2:1b",
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
        "deepseek-r1",
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
    -- New providers
    groq = {
        -- Llama 4 (fastest)
        "llama-4-scout-17b-16e-instruct",
        "llama-4-maverick-17b-128e-instruct",
        -- Llama 3.3
        "llama-3.3-70b-versatile",
        "llama-3.3-70b-specdec",
        -- Qwen
        "qwen-qwq-32b",
        -- DeepSeek
        "deepseek-r1-distill-llama-70b",
        "deepseek-r1-distill-qwen-32b",
        -- Llama 3.1
        "llama-3.1-8b-instant",
    },
    mistral = {
        -- Flagship
        "mistral-large-latest",
        "mistral-large-2411",
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
        "mistral-small-latest",
        "open-mistral-nemo",
    },
    xai = {
        -- Grok 4.1 (latest, 2025)
        "grok-4-1-fast-reasoning",
        "grok-4-1-fast-non-reasoning",
        -- Grok 4
        "grok-4-fast-reasoning",
        "grok-4-fast-non-reasoning",
        "grok-4-0709",
        -- Grok Code
        "grok-code-fast-1",
        -- Grok 3
        "grok-3",
        "grok-3-mini",
        -- Grok 2 Vision
        "grok-2-vision-1212",
    },
    openrouter = {
        -- Curated popular choices
        -- Special: First entry is a placeholder for custom model input
        "custom",  -- UI will show text input when selected
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
        "qwen3-max",
        "qwen3-max-2025-09-23",
        -- Qwen Max
        "qwen-max",
        "qwen-max-2025-01-25",
        -- Qwen Plus
        "qwen-plus",
        "qwen-plus-latest",
        -- Coding
        "qwen3-coder-flash",
        -- Math
        "qwen-math-plus",
    },
    kimi = {
        -- K2 (latest, 256K context)
        "kimi-k2-0711-preview",
        "kimi-k2-thinking-preview",
        -- Auto (routes to best model)
        "moonshot-v1-auto",
        -- Specific context sizes
        "moonshot-v1-8k",
        "moonshot-v1-32k",
        "moonshot-v1-128k",
    },
    together = {
        -- Llama 4
        "meta-llama/Llama-4-Maverick-17B-128E-Instruct-FP8",
        "meta-llama/Llama-4-Scout-17B-16E-Instruct",
        -- Llama 3.3
        "meta-llama/Llama-3.3-70B-Instruct-Turbo",
        -- Qwen 3
        "Qwen/Qwen3-235B-A22B-fp8",
        "Qwen/Qwen3-32B",
        -- DeepSeek
        "deepseek-ai/DeepSeek-R1",
        "deepseek-ai/DeepSeek-R1-Distill-Llama-70B",
        -- Mistral
        "mistralai/Mistral-Large-2411",
    },
    fireworks = {
        -- Llama 4
        "accounts/fireworks/models/llama4-maverick-instruct-basic",
        "accounts/fireworks/models/llama4-scout-instruct-basic",
        -- Llama 3.3
        "accounts/fireworks/models/llama-v3p3-70b-instruct",
        -- Qwen 3
        "accounts/fireworks/models/qwen3-235b-a22b",
        -- DeepSeek
        "accounts/fireworks/models/deepseek-r1",
        -- Mixtral
        "accounts/fireworks/models/mixtral-8x22b-instruct",
    },
    sambanova = {
        -- Llama 4
        "Meta-Llama-4-Maverick-17B-128E-Instruct",
        "Meta-Llama-4-Scout-17B-16E-Instruct",
        -- Llama 3.x
        "Meta-Llama-3.3-70B-Instruct",
        "Meta-Llama-3.1-405B-Instruct",
        "Meta-Llama-3.1-70B-Instruct",
        "Meta-Llama-3.1-8B-Instruct",
        -- DeepSeek
        "DeepSeek-R1",
        "DeepSeek-R1-Distill-Llama-70B",
        -- Qwen
        "Qwen3-32B",
    },
    cohere = {
        -- Command A (latest, strongest)
        "command-a-03-2025",
        -- Command R+
        "command-r-plus-08-2024",
        -- Command R
        "command-r-08-2024",
        -- Smaller
        "command-r7b-12-2024",
    },
    doubao = {
        -- Pro models (latest)
        "doubao-1.5-pro-32k",
        "doubao-1.5-pro-256k",
        -- Vision
        "doubao-1.5-vision-pro-32k",
        -- Seed models (newest)
        "doubao-seed-1.6-flash",
        -- Code
        "doubao-seed-code",
        -- Lite (fast/cheap)
        "doubao-lite-32k",
    }
}

-- Get sorted list of all provider names (single source of truth)
function ModelLists.getAllProviders()
    local providers = {}
    for provider, _ in pairs(ModelLists) do
        if type(ModelLists[provider]) == "table" then
            table.insert(providers, provider)
        end
    end
    table.sort(providers)
    return providers
end

return ModelLists
