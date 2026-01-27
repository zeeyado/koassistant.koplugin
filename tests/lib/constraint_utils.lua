--[[
Constraint Utilities for Test Suite

Wrapper around plugin's ModelConstraints and Defaults modules to prevent duplication.
Tests should use these functions instead of hardcoding constraint logic.

This ensures that tests always reflect the actual plugin's constraint behavior,
eliminating the risk of test/plugin divergence.

Usage:
    local ConstraintUtils = require("tests.lib.constraint_utils")
    local max_temp = ConstraintUtils.getMaxTemperature("anthropic")  -- Returns 1.0
    local defaults = ConstraintUtils.getReasoningDefaults("anthropic")  -- Returns {budget=4096, ...}
]]

local ModelConstraints = require("model_constraints")
local Defaults = require("koassistant_api.defaults")

local ConstraintUtils = {}

--- Get maximum temperature for provider
--- Delegates to plugin's ModelConstraints for single source of truth
--- @param provider string: Provider name (e.g., "anthropic", "openai")
--- @return number: Max temperature (1.0 for Anthropic, 2.0 for most others)
function ConstraintUtils.getMaxTemperature(provider)
    local constraints = ModelConstraints[provider]
    if constraints and constraints._provider_max_temperature then
        return constraints._provider_max_temperature
    end
    return 2.0  -- Default for most providers
end

--- Get default temperature for provider
--- Uses plugin's Defaults module for per-provider defaults
--- @param provider string: Provider name (e.g., "anthropic", "openai")
--- @return number: Default temperature (usually 0.7)
function ConstraintUtils.getDefaultTemperature(provider)
    local provider_defaults = Defaults.ProviderDefaults[provider]
    if provider_defaults and provider_defaults.temperature then
        return provider_defaults.temperature
    end
    return 0.7  -- Fallback if provider defaults not found
end

--- Get reasoning defaults for provider
--- Returns the official defaults for reasoning/thinking features
--- @param provider string: Provider name ("anthropic", "openai", "gemini")
--- @return table|nil: Reasoning config {budget, budget_min, ...} or nil if not supported
function ConstraintUtils.getReasoningDefaults(provider)
    return ModelConstraints.reasoning_defaults[provider]
end

--- Check if model supports capability
--- Wrapper around ModelConstraints.supportsCapability for consistency
--- @param provider string: Provider name
--- @param model string: Model name (e.g., "claude-sonnet-4-5-20250929")
--- @param capability string: Capability name ("extended_thinking", "reasoning", "thinking")
--- @return boolean: true if model supports the capability
function ConstraintUtils.supportsCapability(provider, model, capability)
    return ModelConstraints.supportsCapability(provider, model, capability)
end

--- Parse constraint error from API response
--- Extracted from test_model_validation.lua for reusability
--- Detects temperature/max_tokens constraints from provider error messages
--- @param error_msg string: Error message from API
--- @return table|nil: Constraint info {type="temperature"|"max_tokens"|"multiple", value=number, reason=string}
function ConstraintUtils.parseConstraintError(error_msg)
    if not error_msg then return nil end

    local lower = error_msg:lower()

    -- Multiple constraints detected in one error (check first!)
    -- Matches: "temperature and max_tokens", "also requires"
    if lower:find(" and ") or lower:find("also") then
        return {
            type = "multiple",
            reason = "Multiple parameter constraints detected"
        }
    end

    -- Temperature constraints (various provider formats)
    -- Matches: "temperature", "temp", "sampling_temperature"
    if lower:find("temperature") or
       lower:find("temp") or
       lower:find("sampling_temperature") then

        -- Extract required value if present (e.g., "temperature must be 1.0")
        local temp_val = error_msg:match("temperature[^%d]*([0-9.]+)")
        if not temp_val then
            temp_val = error_msg:match("temp[^%d]*([0-9.]+)")
        end

        if temp_val then
            return {
                type = "temperature",
                value = tonumber(temp_val),
                reason = "Model requires specific temperature"
            }
        else
            return {
                type = "temperature",
                reason = "Temperature constraint (value not detected)"
            }
        end
    end

    -- Max tokens constraints
    -- Matches: "max_tokens", "max_completion_tokens", "minimum token count"
    if lower:find("max_tokens") or
       lower:find("max_completion_tokens") or
       lower:find("minimum.*token") or
       lower:find("token.*minimum") then

        -- Extract minimum value (e.g., "max_tokens must be at least 16")
        local min_tokens = error_msg:match("([0-9]+)")
        if min_tokens then
            return {
                type = "max_tokens",
                value = tonumber(min_tokens),
                reason = "Model requires minimum token count"
            }
        else
            return {
                type = "max_tokens",
                reason = "Token limit constraint (value not detected)"
            }
        end
    end

    return nil  -- Not a constraint error
end

--- Build retry config from constraint
--- Generate corrected config based on detected constraint
--- Used for automatic retry with corrected parameters
--- @param original_config table: Original config that failed
--- @param constraint table: Constraint from parseConstraintError
--- @return table: Modified config to retry
function ConstraintUtils.buildRetryConfig(original_config, constraint)
    -- Simple deep copy function (no external dependencies)
    local function deepcopy(obj, seen)
        if type(obj) ~= 'table' then return obj end
        if seen and seen[obj] then return seen[obj] end

        local s = seen or {}
        local res = {}
        s[obj] = res

        for k, v in pairs(obj) do
            res[deepcopy(k, s)] = deepcopy(v, s)
        end

        return res
    end

    local new_config = deepcopy(original_config)

    -- Apply constraint-specific fixes
    if constraint.type == "temperature" and constraint.value then
        new_config.api_params = new_config.api_params or {}
        new_config.api_params.temperature = constraint.value
    elseif constraint.type == "max_tokens" and constraint.value then
        new_config.api_params = new_config.api_params or {}
        new_config.api_params.max_tokens = constraint.value
    elseif constraint.type == "multiple" then
        -- Apply common constraints that usually work
        new_config.api_params = new_config.api_params or {}
        new_config.api_params.temperature = 1.0
        new_config.api_params.max_tokens = 256
    end

    return new_config
end

--- Apply model constraints to parameters
--- Direct wrapper around ModelConstraints.apply
--- @param provider string: Provider name
--- @param model string: Model name
--- @param params table: Request parameters
--- @return table: Modified params
--- @return table: Adjustments made
function ConstraintUtils.applyConstraints(provider, model, params)
    return ModelConstraints.apply(provider, model, params)
end

--- Get all capabilities for a provider
--- Useful for testing which features a provider supports
--- @param provider string: Provider name
--- @return table: Map of capability -> model list
function ConstraintUtils.getProviderCapabilities(provider)
    return ModelConstraints.getProviderCapabilities(provider)
end

return ConstraintUtils
