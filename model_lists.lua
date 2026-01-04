-- Model lists for each provider
-- Last updated: January 2026
local ModelLists = {
    anthropic = {
        -- Claude 4.5 (latest)
        "claude-sonnet-4-5-20250929",
        "claude-haiku-4-5-20251001",
        "claude-opus-4-5-20251101",
    },
    openai = {
        -- GPT-5 family (flagship)
        "gpt-5.2",
        "gpt-5.2-mini",
        "gpt-5.1",
        "gpt-5",
        "gpt-5-mini",
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
        -- Llama 3.x (Meta)
        "llama3.3",
        "llama3.3:70b",
        "llama3.2",
        "llama3.2:3b",
        "llama3.2:1b",
        "llama3.1",
        "llama3.1:8b",
        "llama3.1:70b",
        "llama3",
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
        "deepseek-v3",
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
        "orca-mini",
    }
}
return ModelLists
