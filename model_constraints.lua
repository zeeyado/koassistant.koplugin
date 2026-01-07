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
ModelConstraints.capabilities = {
    anthropic = {
        -- Models that support extended thinking
        -- Claude 3.5 Sonnet and Claude 3 Haiku do NOT support it
        extended_thinking = {
            "claude-sonnet-4-5-20250929",
            "claude-haiku-4-5-20251001",
            "claude-opus-4-5-20251101",
            "claude-opus-4-1-20250805",
            "claude-sonnet-4-20250514",
            "claude-opus-4-20250514",
            "claude-3-7-sonnet-20250219",
        },
    },
    openai = {
        -- Models that support reasoning.effort parameter
        reasoning = {
            "o3", "o3-mini", "o3-pro", "o4-mini",
            "gpt-5", "gpt-5-mini", "gpt-5-nano", "gpt-5.1", "gpt-5.2",
        },
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

return ModelConstraints
