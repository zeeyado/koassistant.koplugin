-- Model lists for each provider
local ModelLists = {
    anthropic = {
        "claude-sonnet-4-5-20250929",
        "claude-haiku-4-5-20251001",
        "claude-opus-4-5-20251101",
    },
    oopenai = {
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
        -- Reasoning models
        "o3",
        "o3-pro",
        "o4-mini",
        -- Legacy
        "gpt-4o",
        "gpt-4o-mini",
    },
    deepseek = {
        "deepseek-chat",      -
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
        -- Gemini 2.0 (previous gen)
        "gemini-2.0-flash",
    },
    ollama = {
        "llama3",
        "llama3:8b",
        "llama3:70b",
        "mistral",
        "mixtral",
        "phi3",
        "phi3:mini",
        "phi3:medium",
        "phi3:small",
        "qwen",
        "qwen:14b",
        "qwen:72b",
        "codellama",
        "codellama:7b",
        "codellama:13b",
        "codellama:34b",
        "neural-chat",
        "vicuna",
        "orca-mini",
    }
}
return ModelLists