-- DEPRECATED (v0.5.2): This module is no longer used.
-- All providers now build their own request bodies directly using unified config.
-- Kept for reference during migration period. Safe to delete after testing.

local Defaults = require("api_handlers.defaults")

local RequestBuilder = {}

function RequestBuilder:new(o)
    o = o or {}
    setmetatable(o, self)
    self.__index = self
    return o
end

-- Helper function to check if content is non-empty
local function hasContent(msg)
    if not msg or not msg.content then return false end
    if type(msg.content) == "string" then
        return msg.content:match("%S") ~= nil  -- Has at least one non-whitespace char
    end
    return true  -- For non-string content (like arrays), assume valid
end

-- Helper: Split consolidated message at [User Question] marker
-- Returns: system_part, user_part (either can be nil)
local function splitConsolidatedMessage(content)
    local marker = "%[User Question%]"
    local start_pos = content:find(marker)

    if start_pos then
        local system_part = content:sub(1, start_pos - 1):match("^%s*(.-)%s*$")  -- trim
        local user_part = content:sub(start_pos + 15):match("^%s*(.-)%s*$")  -- skip marker, trim
        return system_part ~= "" and system_part or nil,
               user_part ~= "" and user_part or nil
    end

    -- No marker found - treat entire content as system
    return content, nil
end

-- Helper: Transform messages for OpenAI-compatible APIs
-- Strips internal fields, handles first is_context message by splitting system/user
local function transformForOpenAICompat(messages)
    local transformed = {}
    local first_context_handled = false

    for _, msg in ipairs(messages) do
        if hasContent(msg) then
            -- First user message with is_context=true contains system + user content
            -- Split it into separate system and user messages
            if not first_context_handled and msg.role == "user" and msg.is_context then
                first_context_handled = true
                local system_part, user_part = splitConsolidatedMessage(msg.content)

                if system_part then
                    table.insert(transformed, {
                        role = "system",
                        content = system_part
                    })
                end

                if user_part then
                    table.insert(transformed, {
                        role = "user",
                        content = user_part
                    })
                else
                    -- No user part found - add minimal user message
                    table.insert(transformed, {
                        role = "user",
                        content = "Please respond."
                    })
                end
            else
                -- Strip internal fields, only keep role and content
                table.insert(transformed, {
                    role = msg.role,
                    content = msg.content
                })
            end
        end
    end
    return transformed
end

-- Message format transformers for each provider
local MESSAGE_TRANSFORMERS = {
    anthropic = function(messages)
        local transformed = {}
        for _, msg in ipairs(messages) do
            if msg.role ~= "system" and hasContent(msg) then
                table.insert(transformed, {
                    role = msg.role == "assistant" and "assistant" or "user",
                    content = msg.content
                })
            end
        end
        return transformed
    end,

    gemini = function(messages)
        local transformed = {}
        local first_context_handled = false

        for _, msg in ipairs(messages) do
            -- Skip system role messages (Gemini handles via system_instruction)
            if msg.role == "system" then
                -- Skip - handled separately via system_instruction
            elseif not first_context_handled and msg.role == "user" and msg.is_context then
                -- Extract user question part from consolidated message
                first_context_handled = true
                local _, user_part = splitConsolidatedMessage(msg.content)
                if user_part then
                    table.insert(transformed, {
                        role = "user",
                        parts = {{ text = user_part }}
                    })
                else
                    -- No user part found - add minimal user message
                    table.insert(transformed, {
                        role = "user",
                        parts = {{ text = "Please respond." }}
                    })
                end
            elseif hasContent(msg) then
                table.insert(transformed, {
                    role = msg.role == "assistant" and "model" or "user",
                    parts = {{ text = msg.content }}
                })
            end
        end
        return transformed
    end,

    -- OpenAI: first is_context message becomes system, strip internal fields
    openai = transformForOpenAICompat,

    -- DeepSeek: OpenAI-compatible API
    deepseek = transformForOpenAICompat,

    ollama = function(messages)
        local transformed = {}
        for _, msg in ipairs(messages) do
            if hasContent(msg) then
                -- Strip internal fields, only keep role and content
                table.insert(transformed, {
                    role = msg.role,
                    content = msg.content
                })
            end
        end
        return transformed
    end
}

function RequestBuilder:buildRequestBody(message_history, config, provider)
    local defaults = Defaults.ProviderDefaults[provider]
    if not defaults then
        return nil, "Unsupported provider: " .. tostring(provider)
    end

    -- Transform messages according to provider format
    local transform = MESSAGE_TRANSFORMERS[provider]
    if not transform then
        return nil, "No message transformer found for provider: " .. tostring(provider)
    end

    local transformed_messages = transform(message_history)

    -- Build base request body
    local request_body = {
        model = config.model or defaults.model
    }

    -- Add messages/contents based on provider format
    if provider == "gemini" then
        request_body.contents = transformed_messages
    else
        request_body.messages = transformed_messages
    end

    -- Add additional parameters from defaults and config
    if defaults.additional_parameters then
        for key, default_value in pairs(defaults.additional_parameters) do
            -- Skip parameters that should be in headers
            if key ~= "anthropic_version" then
                request_body[key] = (config.additional_parameters and config.additional_parameters[key]) 
                    or default_value
            end
        end
    end

    return request_body
end

return RequestBuilder 