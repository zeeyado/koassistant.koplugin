-- Test Configuration Helpers
-- Provides utilities for loading API keys and building test configs

local TestConfig = {}

-- Detect plugin directory from this script's location
function TestConfig.getPluginDir()
    -- Try environment variable first
    local env_dir = os.getenv("KOASSISTANT_DIR")
    if env_dir then
        return env_dir
    end

    -- Try to detect from script location
    local info = debug.getinfo(1, "S")
    if info and info.source then
        local source = info.source:match("@?(.*)")
        local dir = source:match("(.*/)")
        if dir then
            -- We're in tests/, go up one level
            return dir:gsub("/tests/$", "")
        end
    end

    -- Default fallback
    return "/Users/zzz/Library/Application Support/koreader/plugins/koassistant.koplugin"
end

-- Load API keys from plugin directory
function TestConfig.loadApiKeys()
    local plugin_dir = TestConfig.getPluginDir()

    -- Add plugin directory to package path if not already there
    if not package.path:find(plugin_dir, 1, true) then
        package.path = plugin_dir .. "/?.lua;" .. package.path
    end

    local success, keys = pcall(require, "apikeys")
    if not success then
        print("Error loading apikeys.lua: " .. tostring(keys))
        print("Ensure apikeys.lua exists in: " .. plugin_dir)
        print("\nCreate it from the sample:")
        print("  cp apikeys.lua.sample apikeys.lua")
        print("  # Then edit and add your API keys")
        os.exit(1)
    end

    return keys
end

-- Check if an API key is valid (not empty, not placeholder)
function TestConfig.isValidApiKey(key)
    if not key or key == "" then
        return false
    end
    if key:match("^YOUR_") then
        return false
    end
    if key == "not-needed" then
        return true  -- Special case for Ollama
    end
    return true
end

-- Build unified config for a provider (matches dialogs.lua:buildUnifiedRequestConfig)
function TestConfig.buildConfig(provider, api_key, options)
    options = options or {}

    return {
        provider = provider,
        api_key = api_key,
        model = options.model,  -- nil = use provider default

        -- Unified system config (matches what handlers expect)
        system = {
            text = options.system_prompt or "You are a helpful assistant. Keep responses brief.",
            enable_caching = options.enable_caching or false,
        },

        -- API parameters
        api_params = {
            temperature = options.temperature or 0.7,
            -- Use 512 tokens to accommodate thinking models (Gemini 3 uses ~60 tokens for thinking)
            max_tokens = options.max_tokens or 512,
        },

        -- Feature flags
        features = {
            enable_streaming = false,  -- Always false for standalone tests
            debug = options.debug or false,
        },
    }
end

-- Get list of all providers
function TestConfig.getAllProviders()
    return {
        -- Original providers
        "anthropic", "openai", "deepseek", "gemini", "ollama",
        -- New providers
        "groq", "mistral", "xai", "openrouter", "qwen", "kimi",
        "together", "fireworks", "sambanova", "cohere", "doubao"
    }
end

-- Simple test message history
function TestConfig.getTestMessages()
    return {
        { role = "user", content = "Say hello in exactly 5 words." }
    }
end

-- Format elapsed time
function TestConfig.formatTime(seconds)
    if seconds < 1 then
        return string.format("%.0fms", seconds * 1000)
    else
        return string.format("%.2fs", seconds)
    end
end

return TestConfig
