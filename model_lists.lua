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
        "gpt-5.2-pro",
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
        -- Gemini 3 (preview)
        "gemini-3-pro-preview",
        "gemini-3-flash-preview",
        -- Gemini 2.5 (stable)
        "gemini-2.5-pro",
        "gemini-2.5-flash",
        "gemini-2.5-flash-lite",
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
    }
}
return ModelLists
