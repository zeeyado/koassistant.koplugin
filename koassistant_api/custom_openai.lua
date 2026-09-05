--[[--
Custom OpenAI-Compatible Handler

Generic handler for user-defined providers that follow the OpenAI API format.
Supports optional authentication (for local servers like LM Studio) and
max_completion_tokens for newer OpenAI-style models.

@module custom_openai
]]

local OpenAICompatibleHandler = require("koassistant_api.openai_compatible")

local CustomOpenAIHandler = OpenAICompatibleHandler:new()

function CustomOpenAIHandler:getProviderName()
    return "Custom Provider"
end

function CustomOpenAIHandler:getProviderKey()
    return "custom"
end

--- Every custom provider shares this handler, so the static key above cannot
--- identify one. Capability data (ceilings in _max_output_tokens, user layers in
--- custom_models.lua) is keyed by the RUNTIME id `custom_<slug>` — which arrives
--- on config.provider (koassistant_gpt_query.lua matches it against
--- features.custom_providers[].id). Without this, no ceiling and no user
--- override could ever resolve for a custom provider.
function CustomOpenAIHandler:getConstraintsKey(config)
    local id = config and config.provider
    if type(id) == "string" and id ~= "" then return id end
    return self:getProviderKey()
end

-- Custom providers require base_url, not api_key
function CustomOpenAIHandler:validateConfig(config)
    if not config or not config.base_url or config.base_url == "" then
        return false, "Error: Missing base URL for custom provider"
    end
    return true
end

-- API key is optional for local servers like LM Studio
function CustomOpenAIHandler:customizeHeaders(headers, config)
    if not config.api_key or config.api_key == "" then
        headers["Authorization"] = nil
    end
    -- A custom provider pointed at opencode.ai (users who added OpenCode by
    -- hand before the built-in landed, #107) gets the header OpenCode requires;
    -- wire correctness for a documented protocol, never sent to any other host.
    local url = config.base_url or ""
    local cid = config.conversation_id
    if type(cid) == "string" and cid ~= "" and url:match("^https?://opencode%.ai/") then
        headers["x-opencode-session"] = cid
    end
    return headers
end

-- Handle max_completion_tokens for newer OpenAI models
function CustomOpenAIHandler:customizeRequestBody(body, config)
    local model = body.model or ""
    -- Newer OpenAI models use max_completion_tokens instead of max_tokens
    local needs_new_param = model:match("^gpt%-5") or model:match("^o%d") or model:match("^gpt%-4%.1")
    if needs_new_param and body.max_tokens then
        body.max_completion_tokens = body.max_tokens
        body.max_tokens = nil
    end

    -- Reasoning for custom providers (item 19): a user profile in custom_models.lua
    -- names an OpenAI-compatible wire via `wire`; applyReasoningParams emits the
    -- neutral api_params.custom_reasoning record, translated here.
    --   "effort"          -> reasoning_effort = <level>  (vLLM, gateways; off_option if declared)
    --   "enable_thinking" -> chat_template_kwargs.enable_thinking = <bool> (vLLM/SGLang Qwen-style)
    local cr = config.api_params and config.api_params.custom_reasoning
    if cr then
        if cr.wire == "effort" then
            if cr.on then
                body.reasoning_effort = cr.effort
            elseif cr.off_option then
                body.reasoning_effort = cr.off_option
            end
        elseif cr.wire == "enable_thinking" then
            body.chat_template_kwargs = { enable_thinking = cr.on and true or false }
        end
        if cr.on and cr.needs_temp_1 and body.temperature and body.temperature ~= 1.0 then
            body.temperature = 1.0
        end
    end
    return body
end

-- Use "openai" parser for maximum compatibility
function CustomOpenAIHandler:getResponseParserKey()
    return "openai"
end

-- Support R1-style reasoning models that users might run locally
function CustomOpenAIHandler:supportsReasoningExtraction()
    return true
end

return CustomOpenAIHandler
