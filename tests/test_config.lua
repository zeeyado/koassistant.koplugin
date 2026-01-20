-- Test Configuration Helpers
-- Provides utilities for loading API keys and building test configs

local TestConfig = {}

-- Local configuration (optional, gitignored)
local local_config = nil
pcall(function()
    local_config = require("local_config")
end)

-- Detect plugin directory from this script's location
function TestConfig.getPluginDir()
    -- Try local config first (user-specified)
    if local_config and local_config.plugin_dir then
        return local_config.plugin_dir
    end

    -- Try environment variable
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

    -- Default fallback: current directory (user should run from plugin dir)
    return "."
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

-- Build full config using the real plugin pipeline
-- This mirrors dialogs.lua:buildUnifiedRequestConfig() and uses system_prompts.lua
-- Use this for integration tests that need realistic config building
function TestConfig.buildFullConfig(provider, api_key, options)
    options = options or {}

    -- Load SystemPrompts for behavior/language/domain building
    local SystemPrompts = require("prompts.system_prompts")

    -- Build unified system using the real pipeline
    local system = SystemPrompts.buildUnifiedSystem({
        behavior_variant = options.behavior_variant,
        behavior_override = options.behavior_override,
        global_variant = options.global_variant or "full",
        custom_ai_behavior = options.custom_ai_behavior,  -- DEPRECATED: legacy support
        custom_behaviors = options.custom_behaviors,      -- NEW: array of UI-created behaviors
        domain_context = options.domain_context,
        enable_caching = options.enable_caching,
        user_languages = options.user_languages,
        primary_language = options.primary_language,
    })

    local config = {
        provider = provider,
        api_key = api_key,
        model = options.model,  -- nil = use provider default

        -- Use the unified system from the real pipeline
        system = system,

        -- API parameters
        api_params = {
            temperature = options.temperature or 0.7,
            max_tokens = options.max_tokens or 512,
        },

        -- Feature flags
        features = {
            enable_streaming = false,  -- Always false for standalone tests
            debug = options.debug or false,
        },
    }

    -- Add extended thinking if enabled (Anthropic only)
    if options.extended_thinking then
        config.api_params.thinking = {
            type = "enabled",
            budget_tokens = options.thinking_budget or 4096
        }
        config.api_params.temperature = 1.0  -- Required for extended thinking
    end

    return config
end

-- Get list of all providers (derived from model_lists.lua - single source of truth)
function TestConfig.getAllProviders()
    local ModelLists = require("model_lists")
    -- Use the built-in function which correctly filters out non-table keys
    return ModelLists.getAllProviders()
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

-- Get local config value with default
function TestConfig.getLocalConfig(key, default)
    if local_config and local_config[key] ~= nil then
        return local_config[key]
    end
    return default
end

-- Check if a provider should be skipped (via local config)
function TestConfig.isProviderSkipped(provider)
    local skip_list = TestConfig.getLocalConfig("skip_providers", {})
    for _, p in ipairs(skip_list) do
        if p == provider then
            return true
        end
    end
    return false
end

-- Get default provider for quick tests
function TestConfig.getDefaultProvider()
    return TestConfig.getLocalConfig("default_provider", "anthropic")
end

-- Get API timeout
function TestConfig.getApiTimeout()
    return TestConfig.getLocalConfig("api_timeout", 60)
end

-- Get verbose setting
function TestConfig.isVerboseDefault()
    return TestConfig.getLocalConfig("verbose", false)
end

return TestConfig
