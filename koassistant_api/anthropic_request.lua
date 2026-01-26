-- Anthropic-specific request builder with caching support
-- This module creates properly structured requests for Claude API
-- including system array, prompt caching, and extended thinking
--
-- Usage:
--   local AnthropicRequest = require("koassistant_api.anthropic_request")
--   local request, adjustments = AnthropicRequest:build(config)
--   local headers = AnthropicRequest:getHeaders(config)

local Defaults = require("koassistant_api.defaults")
local ModelConstraints = require("model_constraints")

local AnthropicRequest = {}

-- Beta header required for prompt caching
AnthropicRequest.CACHE_BETA = "prompt-caching-2024-07-31"

-- Default API parameters
AnthropicRequest.DEFAULT_PARAMS = {
    max_tokens = 4096,
    temperature = 0.7,
}

-- Build request body for Anthropic API
-- @param config: {
--   model: Model ID (optional, uses default)
--   messages: Message history array (user/assistant messages only)
--   system: System content array (from ActionService.buildAnthropicSystem)
--   api_params: { temperature, max_tokens, thinking } (optional)
--   stream: Enable streaming (optional)
-- }
-- @return table: Request body ready for JSON encoding
function AnthropicRequest:build(config)
    config = config or {}
    local defaults = Defaults.ProviderDefaults.anthropic

    local request_body = {
        model = config.model or defaults.model,
    }

    -- Add system array if provided
    -- Handles two formats:
    --   1. Unified format (v0.5.2+): { text, enable_caching, components }
    --   2. Legacy array format: array of { type, text, cache_control } blocks
    if config.system then
        -- Check for unified format (has 'text' field)
        if config.system.text and config.system.text ~= "" then
            -- Convert unified format to Anthropic array format
            local block = {
                type = "text",
                text = config.system.text,
            }
            if config.system.enable_caching then
                block.cache_control = { type = "ephemeral" }
            end
            request_body.system = { block }
        elseif #config.system > 0 then
            -- Legacy array format - strip debug fields
            request_body.system = {}
            for _, block in ipairs(config.system) do
                local clean_block = {
                    type = block.type,
                    text = block.text,
                }
                if block.cache_control then
                    clean_block.cache_control = block.cache_control
                end
                table.insert(request_body.system, clean_block)
            end
        end
    end

    -- Add messages (user/assistant only, no system role)
    if config.messages then
        request_body.messages = self:filterMessages(config.messages)
    else
        request_body.messages = {}
    end

    -- Merge API parameters: defaults -> config additional_params -> action params
    local params = {}

    -- Start with defaults
    for k, v in pairs(AnthropicRequest.DEFAULT_PARAMS) do
        params[k] = v
    end

    -- Add defaults from provider config
    if defaults.additional_parameters then
        for k, v in pairs(defaults.additional_parameters) do
            if k ~= "anthropic_version" then  -- Skip header-only params
                params[k] = v
            end
        end
    end

    -- Override with config additional_parameters
    if config.additional_parameters then
        for k, v in pairs(config.additional_parameters) do
            params[k] = v
        end
    end

    -- Override with action-specific params
    if config.api_params then
        for k, v in pairs(config.api_params) do
            params[k] = v
        end
    end

    -- Apply parameters to request
    request_body.max_tokens = params.max_tokens or AnthropicRequest.DEFAULT_PARAMS.max_tokens
    request_body.temperature = params.temperature or AnthropicRequest.DEFAULT_PARAMS.temperature

    -- Get model for constraints and capability checking
    local model = config.model or defaults.model

    -- Apply model constraints (Anthropic max temperature is 1.0)
    local adjustments
    request_body, adjustments = ModelConstraints.apply("anthropic", model, request_body)

    -- Add extended thinking if enabled AND model supports it
    if params.thinking then
        -- Validate model supports extended thinking
        local supports_thinking = ModelConstraints.supportsCapability("anthropic", model, "extended_thinking")

        if supports_thinking then
            request_body.thinking = params.thinking
            -- Extended thinking has specific requirements:
            -- - budget_tokens must be >= 1024
            -- - max_tokens MUST be > budget_tokens
            -- - temperature MUST be exactly 1.0 (API rejects any other value)
            if request_body.temperature ~= 1.0 then
                adjustments.temperature = {
                    from = request_body.temperature,
                    to = 1.0,
                    reason = "extended thinking requires temp=1.0"
                }
                request_body.temperature = 1.0
            end

            -- Ensure max_tokens > budget_tokens (API requirement)
            local default_budget = ModelConstraints.reasoning_defaults.anthropic.budget
            local budget = params.thinking.budget_tokens or default_budget
            if request_body.max_tokens <= budget then
                local old_max = request_body.max_tokens
                request_body.max_tokens = budget + default_budget
                adjustments.max_tokens = {
                    from = old_max,
                    to = request_body.max_tokens,
                    reason = "must be > thinking budget"
                }
            end
        else
            -- Model doesn't support extended thinking - skip it
            adjustments.thinking_skipped = {
                reason = "model " .. model .. " does not support extended thinking"
            }
        end
    end

    -- Add streaming if requested
    if config.stream then
        request_body.stream = true
    end

    return request_body, adjustments
end

-- Filter messages to remove system role and empty content
-- @param messages: Array of message objects
-- @return table: Filtered messages
function AnthropicRequest:filterMessages(messages)
    local filtered = {}

    for _, msg in ipairs(messages) do
        -- Skip system messages (they go in system array)
        if msg.role ~= "system" and self:hasContent(msg) then
            table.insert(filtered, {
                role = msg.role == "assistant" and "assistant" or "user",
                content = msg.content,
            })
        end
    end

    return filtered
end

-- Check if message has non-empty content
function AnthropicRequest:hasContent(msg)
    if not msg or not msg.content then return false end
    if type(msg.content) == "string" then
        return msg.content:match("%S") ~= nil
    end
    return true  -- Non-string content (arrays) assumed valid
end

-- Get headers for Anthropic API request
-- @param config: { api_key, enable_caching }
-- @param content_length: Length of request body
-- @return table: HTTP headers
function AnthropicRequest:getHeaders(config, content_length)
    local defaults = Defaults.ProviderDefaults.anthropic

    local headers = {
        ["Content-Type"] = "application/json",
        ["x-api-key"] = config.api_key,
        ["anthropic-version"] = defaults.additional_parameters.anthropic_version,
    }

    -- Add caching beta header (always enabled for this module)
    headers["anthropic-beta"] = AnthropicRequest.CACHE_BETA

    -- Add content length if provided
    if content_length then
        headers["Content-Length"] = tostring(content_length)
    end

    return headers
end

-- Get streaming headers
-- @param config: Same as getHeaders
-- @param content_length: Length of request body
-- @return table: HTTP headers for SSE streaming
function AnthropicRequest:getStreamHeaders(config, content_length)
    local headers = self:getHeaders(config, content_length)
    headers["Accept"] = "text/event-stream"
    return headers
end

-- Build system array from legacy format (for migration)
-- Converts old consolidated message format to new system array
-- @param system_text: Old-style system prompt text
-- @param enable_caching: Whether to add cache_control
-- @return table: System array for Anthropic API
function AnthropicRequest:buildSystemFromLegacy(system_text, enable_caching)
    if not system_text or system_text == "" then
        return nil
    end

    local block = {
        type = "text",
        text = system_text,
    }

    if enable_caching ~= false then
        block.cache_control = { type = "ephemeral" }
    end

    return { block }
end

-- Create a cached content block
-- @param text: Content text
-- @return table: Content block with cache_control
function AnthropicRequest:createCachedBlock(text)
    return {
        type = "text",
        text = text,
        cache_control = { type = "ephemeral" },
    }
end

-- Create a non-cached content block
-- @param text: Content text
-- @return table: Content block without cache_control
function AnthropicRequest:createBlock(text)
    return {
        type = "text",
        text = text,
    }
end

-- Build extended thinking configuration
-- @param budget_tokens: Token budget for thinking (minimum 1024)
-- @return table: Thinking configuration
function AnthropicRequest:buildThinkingConfig(budget_tokens)
    local defaults = ModelConstraints.reasoning_defaults.anthropic
    budget_tokens = math.max(budget_tokens or defaults.budget, defaults.budget_min)

    return {
        type = "enabled",
        budget_tokens = budget_tokens,
    }
end

-- Parse cache usage from response
-- @param usage: Response usage object
-- @return table: { cache_write, cache_read, input, output }
function AnthropicRequest:parseCacheUsage(usage)
    if not usage then return nil end

    return {
        cache_write = usage.cache_creation_input_tokens or 0,
        cache_read = usage.cache_read_input_tokens or 0,
        input = usage.input_tokens or 0,
        output = usage.output_tokens or 0,
    }
end

-- Format cache usage for debug display
-- @param usage: Parsed usage from parseCacheUsage
-- @return string: Human-readable cache status
function AnthropicRequest:formatCacheUsage(usage)
    if not usage then return "No usage data" end

    local parts = {}

    if usage.cache_write > 0 then
        table.insert(parts, string.format("Cache write: %d tokens", usage.cache_write))
    end

    if usage.cache_read > 0 then
        table.insert(parts, string.format("Cache hit: %d tokens (90%% savings)", usage.cache_read))
    end

    table.insert(parts, string.format("Input: %d, Output: %d", usage.input, usage.output))

    return table.concat(parts, " | ")
end

return AnthropicRequest
