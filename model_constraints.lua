-- Model Constraints
-- Centralized definitions for model-specific parameter constraints
-- Add new constraints here as they are discovered via --models testing
--
-- Also defines model capabilities (reasoning/thinking support)

local ModelConstraints = {
    openai = {
        -- Models requiring temperature=1.0 (reject other values)
        -- Discovered via: lua tests/run_tests.lua --models openai
        ["gpt-5"] = { temperature = 1.0 },
        ["gpt-5-mini"] = { temperature = 1.0 },
        ["gpt-5-nano"] = { temperature = 1.0 },
        ["o3"] = { temperature = 1.0 },
        ["o3-mini"] = { temperature = 1.0 },
        ["o3-pro"] = { temperature = 1.0 },
        ["o4-mini"] = { temperature = 1.0 },
    },
    anthropic = {
        -- Max temperature is 1.0 for all Anthropic models (vs 2.0 for others)
        _provider_max_temperature = 1.0,
        -- Extended thinking also requires temp=1.0, handled separately in handler
    },
    -- Add more providers/models as discovered
}

-- Model capabilities (reasoning/thinking support)
-- Used to determine if a model supports specific features
-- NOTE: Use base model names (without dates) to enable prefix matching
-- e.g., "claude-sonnet-4-5" matches "claude-sonnet-4-5-20250929", "claude-sonnet-4-5-latest", etc.
ModelConstraints.capabilities = {
    anthropic = {
        -- Models that support adaptive thinking (4.6+)
        -- New mode: thinking = {type = "adaptive"}, output_config = {effort = "..."}
        adaptive_thinking = {
            "claude-sonnet-4-6",      -- 4.6 Sonnet
            "claude-opus-4-6",        -- 4.6 Opus
        },
        -- Models that support extended thinking (manual budget mode)
        -- Still works on 4.6 but deprecated in favor of adaptive
        extended_thinking = {
            "claude-sonnet-4-6",      -- 4.6 Sonnet
            "claude-opus-4-6",        -- 4.6 Opus
            "claude-sonnet-4-5",      -- 4.5 Sonnet
            "claude-haiku-4-5",       -- 4.5 Haiku
            "claude-opus-4-5",        -- 4.5 Opus
            "claude-opus-4-1",        -- 4.1 Opus
            "claude-sonnet-4",        -- 4 Sonnet (not 4.5)
            "claude-opus-4",          -- 4 Opus (not 4.1 or 4.5)
            "claude-3-7-sonnet",      -- 3.7 Sonnet
        },
    },
    openai = {
        -- Models that support reasoning.effort parameter
        reasoning = {
            "o3", "o3-mini", "o3-pro", "o4-mini",
            "gpt-5", "gpt-5-mini", "gpt-5-nano", "gpt-5.1", "gpt-5.2",
        },
        -- Models where reasoning is opt-in (default=none from OpenAI)
        -- Gated by master reasoning toggle + openai_reasoning sub-toggle
        -- Other reasoning models (o3, gpt-5, etc.) always reason at factory defaults
        reasoning_gated = {
            "gpt-5.1", "gpt-5.2",
        },
        -- Note: OpenAI Chat Completions API does NOT have native web search.
        -- Web search requires Responses API or function calling with external tools.
    },
    deepseek = {
        -- deepseek-reasoner always reasons (no parameter needed)
        -- deepseek-chat does NOT support reasoning
        reasoning = { "deepseek-reasoner" },
    },
    gemini = {
        -- Gemini 3 preview models support thinking_level
        -- Gemini 2.x does NOT
        thinking = { "gemini-3-pro-preview", "gemini-3-flash-preview" },
        -- Google Search grounding (most Gemini 2.x+ models)
        google_search = {
            "gemini-2.5-pro", "gemini-2.5-flash",
            "gemini-2.0-flash", "gemini-2.0-flash-lite",
            "gemini-3-pro-preview", "gemini-3-flash-preview",
        },
    },
    -- Note: xAI web search requires Responses API (/v1/responses) which is
    -- not compatible with Chat Completions. Deprecated Feb 20, 2026 (410 Gone).
}

-- Maximum output token limits per model
-- Used by handlers to clamp max_tokens before sending requests
-- Models with known output token ceilings (prevents API 400 errors)
ModelConstraints._max_output_tokens = {
    anthropic = {
        ["claude-opus-4-6"] = 128000,    -- 128K max output
        ["claude-sonnet-4-6"] = 64000,
        ["claude-sonnet-4-5"] = 64000,
        ["claude-opus-4-5"] = 64000,
        ["claude-haiku-4-5"] = 64000,
    },
    deepseek = {
        ["deepseek-chat"] = 8192,
        -- deepseek-reasoner: no cap needed (64K limit)
    },
    groq = {
        ["groq/compound"] = 8192,
        ["groq/compound-mini"] = 8192,
        ["meta-llama/llama-4-maverick"] = 8192,
        ["meta-llama/llama-4-scout"] = 8192,
    },
}

-- Default values for reasoning/thinking settings
-- Use these instead of hardcoding values throughout the codebase
ModelConstraints.reasoning_defaults = {
    -- Anthropic adaptive thinking (4.6+)
    anthropic_adaptive = {
        effort = "high",     -- Default effort level
        effort_options = { "low", "medium", "high" },  -- Common options
        effort_options_opus = { "low", "medium", "high", "max" },  -- Opus 4.6 only
    },
    -- Anthropic extended thinking (manual budget mode)
    anthropic = {
        budget = 32000,      -- Default budget_tokens (max cap, model uses what it needs)
        budget_min = 1024,   -- Minimum allowed
        budget_max = 32000,  -- Maximum allowed
        budget_step = 1024,  -- SpinWidget step
    },
    -- OpenAI reasoning effort (for gated models: 5.1+)
    openai = {
        effort = "medium",   -- Default effort level
        effort_options = { "low", "medium", "high", "xhigh" },
    },
    -- Gemini thinking level
    gemini = {
        level = "high",      -- Default thinking level
        level_options = { "low", "medium", "high" },  -- Common options
        level_options_flash = { "minimal", "low", "medium", "high" },  -- Flash-specific
    },
}

--- Check if a model supports a specific capability
--- @param provider string: Provider name (e.g., "anthropic", "openai")
--- @param model string: Model name (e.g., "claude-sonnet-4-5-20250929")
--- @param capability string: Capability name (e.g., "extended_thinking", "reasoning")
--- @return boolean: true if model supports the capability
function ModelConstraints.supportsCapability(provider, model, capability)
    local caps = ModelConstraints.capabilities[provider]
    if not caps or not caps[capability] then
        return false
    end

    for _, supported in ipairs(caps[capability]) do
        -- Exact match or prefix match (for versioned models)
        if model == supported or model:match("^" .. supported:gsub("%-", "%%-")) then
            return true
        end
    end

    return false
end

--- Get all capabilities for a provider
--- @param provider string: Provider name
--- @return table: Map of capability name -> list of supported models
function ModelConstraints.getProviderCapabilities(provider)
    return ModelConstraints.capabilities[provider] or {}
end

--- Apply model constraints to request parameters
--- @param provider string: Provider name (e.g., "openai", "anthropic")
--- @param model string: Model name (e.g., "gpt-5-mini")
--- @param params table: Request parameters (temperature, max_tokens, etc.)
--- @return table: Modified params
--- @return table: Adjustments made { param = { from = old, to = new, reason = optional } }
function ModelConstraints.apply(provider, model, params)
    local adjustments = {}

    -- Check provider-level constraints
    local provider_constraints = ModelConstraints[provider]
    if not provider_constraints then
        return params, adjustments
    end

    -- Check model-specific constraints (prefix match for versioned models)
    -- e.g., "o3-mini" matches "o3-mini", "o3-mini-high", "o3-mini-2025-01-31"
    local model_constraints = nil
    for constraint_model, constraints in pairs(provider_constraints) do
        -- Skip special keys starting with _
        if type(constraint_model) == "string" and not constraint_model:match("^_") then
            -- Check for exact match or prefix match
            if model == constraint_model or model:match("^" .. constraint_model:gsub("%-", "%%-")) then
                model_constraints = constraints
                break
            end
        end
    end

    if model_constraints then
        for param, required_value in pairs(model_constraints) do
            if params[param] ~= nil and params[param] ~= required_value then
                adjustments[param] = { from = params[param], to = required_value }
                params[param] = required_value
            end
        end
    end

    -- Check provider-level max temperature (e.g., Anthropic max 1.0)
    local max_temp = provider_constraints._provider_max_temperature
    if max_temp and params.temperature and params.temperature > max_temp then
        adjustments.temperature = {
            from = params.temperature,
            to = max_temp,
            reason = "provider max"
        }
        params.temperature = max_temp
    end

    return params, adjustments
end

--- Print debug output for applied constraints
--- @param provider string: Provider name for log prefix
--- @param adjustments table: Adjustments from apply()
function ModelConstraints.logAdjustments(provider, adjustments)
    if not adjustments or not next(adjustments) then
        return
    end

    print(string.format("%s: Model constraints applied:", provider))
    for param, adj in pairs(adjustments) do
        local reason_str = adj.reason and (" (" .. adj.reason .. ")") or ""
        print(string.format("  %s: %s -> %s%s",
            param,
            tostring(adj.from),
            tostring(adj.to),
            reason_str))
    end
end

--- Clamp max_tokens to model-specific ceiling (if any)
--- Acts as a ceiling: values below the cap pass through unchanged.
--- @param provider string: Provider name (e.g., "deepseek", "groq")
--- @param model string: Model name (e.g., "deepseek-chat")
--- @param value number|nil: The max_tokens value to clamp
--- @return number|nil: Clamped value, or original if no cap applies
function ModelConstraints.clampMaxTokens(provider, model, value)
    if not value then return value end
    local provider_caps = ModelConstraints._max_output_tokens[provider]
    if not provider_caps then return value end

    for cap_model, max_val in pairs(provider_caps) do
        -- Prefix match (e.g., "deepseek-chat" matches "deepseek-chat-v2")
        if model == cap_model or model:match("^" .. cap_model:gsub("%-", "%%-")) then
            return math.min(value, max_val)
        end
    end

    return value
end

return ModelConstraints
