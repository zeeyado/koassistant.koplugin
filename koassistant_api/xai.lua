--[[--
xAI (Grok) API Handler

OpenAI-compatible handler for xAI's Grok models.
grok-4.x reasoning models support reasoning_effort (none/low/medium/high).

Web search (responses_api_plan.md R4): xAI's native web_search agent tool lives
on their Responses endpoint (/v1/responses, OpenAI-compatible wire — parsed by
the shared openai_responses transformer). The old chat-completions live search
returns 410 Gone since 2026-01-12. Web-on requests AND book-tool sessions on
capable models (the responses_web_search list) route to Responses (tools since
2026-08-14, campaign T3 probe P9 — the only wire where tools and native web
search coexist); everything else stays on Chat Completions.

@module xai
]]

local OpenAICompatibleHandler = require("koassistant_api.openai_compatible")
local Defaults = require("koassistant_api.defaults")
local ModelConstraints = require("model_constraints")

local XAIHandler = OpenAICompatibleHandler:new()

function XAIHandler:getProviderName()
    return "xAI"
end

function XAIHandler:getProviderKey()
    return "xai"
end

-- Helper: Check if message has non-empty content
local function hasContent(msg)
    if not msg or not msg.content then return false end
    if type(msg.content) == "string" then
        return msg.content:match("%S") ~= nil
    end
    return true
end

--- Resolve the effective web-search decision (per-action override > global),
--- same pattern as openai.lua / anthropic_request.lua.
local function webSearchEnabled(config)
    if config.enable_web_search ~= nil then
        return config.enable_web_search and true or false
    end
    return (config.features and config.features.enable_web_search) and true or false
end

--- Route this request to xAI's Responses endpoint? Capable models (the
--- responses_web_search list) route there for native web search AND for
--- book-tool sessions (campaign T3 probe P9, 2026-08-14: flat function tools +
--- tool_choice "required" + encrypted reasoning all accepted with
--- OpenAI-identical function_call items) — this is what lets tools and native
--- web search COEXIST in one xAI chat, impossible on the chat wire (live
--- search 410 since 2026-01-12). Same one-endpoint-per-session logic as
--- openai.lua: every tool-turn config carries config.tools, so
--- _responses_items history entries are only ever replayed here. Models
--- outside the capability list keep tool sessions on the chat wire end-to-end.
local function shouldUseResponses(config, model)
    if not ModelConstraints.supportsCapability("xai", model, "responses_web_search") then
        return false
    end
    if config.tools ~= nil then return true end
    return webSearchEnabled(config)
end

--- Build a Responses API request. xAI deltas from openai.lua's builder:
--- temperature is kept (grok models accept the full 0-2 range), reasoning rides
--- the resolver's xai_reasoning effort (incl. "none" = explicit off), and the
--- web_search tool has no context-size dial (bare tool — the web_search_effort
--- setting doesn't apply here).
--- @return table: { body, headers, url, model, provider, parser, adjustments }
function XAIHandler:buildResponsesRequest(message_history, config, model)
    local defaults = Defaults.ProviderDefaults.xai or {}
    -- Adjustment entries must be {from, to, reason} tables — logAdjustments
    -- indexes them (a bare boolean here crashed debug-enabled requests).
    local adjustments = {
        responses_api = { to = "/v1/responses", reason = "native web search" },
    }

    local request_body = {
        model = model,
        input = {},
        -- Stateless by design: full history is resent each turn and chats must
        -- never be retained server-side.
        store = false,
    }

    if config.system and config.system.text and config.system.text ~= "" then
        request_body.instructions = config.system.text
    end

    for _idx, msg in ipairs(message_history) do
        if type(msg._responses_items) == "table" then
            -- A completed tool turn appended by tool_wire's Responses branch
            -- (xai aliases the openai adapter): raw output items (reasoning/
            -- function_call/message) + our function_call_output items, replayed
            -- verbatim — the documented stateless pattern for store=false.
            for _i, item in ipairs(msg._responses_items) do
                table.insert(request_body.input, item)
            end
        elseif msg.role ~= "system" and hasContent(msg) then
            table.insert(request_body.input, {
                role = msg.role == "assistant" and "assistant" or "user",
                content = msg.content,
            })
        end
    end

    local api_params = config.api_params or {}
    local default_params = defaults.additional_parameters or {}
    request_body.temperature = api_params.temperature or default_params.temperature or 0.7
    -- Default via the ceiling-aware resolver (raise-where-known, item 27):
    -- grok-4 family resolves to 32768 (reasoning draws from max_output_tokens).
    local max_tokens = api_params.max_tokens
        or ModelConstraints.resolveMaxTokens("xai", model, default_params.max_tokens or 16384)
    request_body.max_output_tokens = ModelConstraints.clampMaxTokens("xai", model, max_tokens)

    -- Model parameter constraints (curated + custom_models.lua), as on the chat wire
    local constrained
    request_body, constrained = ModelConstraints.apply("xai", model, request_body)
    for param, adj in pairs(constrained) do adjustments[param] = adj end

    -- Reasoning effort from the per-model resolver, nested like OpenAI's
    -- Responses shape ("none" is xAI's explicit-off effort value).
    if api_params.xai_reasoning and api_params.xai_reasoning.effort then
        if ModelConstraints.supportsCapability("xai", model, "reasoning") then
            request_body.reasoning = { effort = api_params.xai_reasoning.effort }
        else
            adjustments.reasoning_skipped = {
                reason = "model " .. model .. " does not support reasoning"
            }
        end
    end

    -- Native web_search agent tool (when active — tool-turn configs may have
    -- web off). Citations come back as url_citation annotations, which the
    -- shared parser/stream harvest already turn into provenance. No
    -- context-size dial on xAI's tool (the web_search_effort setting doesn't
    -- apply here).
    if webSearchEnabled(config) then
        request_body.tools = { { type = "web_search" } }
    end

    -- Book-tool declarations (T3 P9): Responses takes FLAT function defs (no
    -- nested "function" wrapper). Same mode mapping as openai.lua's builder.
    if config.tools and config.tools.specs then
        request_body.tools = request_body.tools or {}
        for _idx, spec in ipairs(config.tools.specs) do
            table.insert(request_body.tools, {
                type = "function",
                name = spec.name,
                description = spec.description,
                parameters = spec.parameters,
            })
        end
        if config.tools.mode == "NONE" then
            request_body.tool_choice = "none"
        elseif config.tools.mode == "ANY" then
            request_body.tool_choice = "required"
        else
            request_body.tool_choice = "auto"
        end
        -- Stateless tool loop: reasoning items must be replayed alongside
        -- their function calls, which with store=false requires their
        -- encrypted form (probe-verified accepted on grok-4.x).
        request_body.include = { "reasoning.encrypted_content" }
    end

    local headers = {
        ["Content-Type"] = "application/json",
        ["Authorization"] = "Bearer " .. (config.api_key or ""),
    }

    -- Derive the endpoint from the configured base URL so custom bases keep
    -- working; a nonstandard base without /chat/completions passes through
    -- unchanged (visible 404 rather than a silent wrong host).
    local url = (config.base_url or defaults.base_url or ""):gsub("/chat/completions", "/responses")

    return {
        body = request_body,
        headers = headers,
        url = url,
        model = model,
        provider = "xai",
        parser = "openai_responses",
        adjustments = adjustments,
    }
end

--- Route between Chat Completions (parent implementation) and Responses.
function XAIHandler:buildRequestBody(message_history, config)
    local defaults = Defaults.ProviderDefaults.xai or {}
    local model = config.model or defaults.model
    if shouldUseResponses(config, model) then
        return self:buildResponsesRequest(message_history, config, model)
    end
    return OpenAICompatibleHandler.buildRequestBody(self, message_history, config)
end

-- Add reasoning_effort parameter for reasoning-capable models (chat wire)
function XAIHandler:customizeRequestBody(body, config)
    local model = body.model or ""
    if ModelConstraints.supportsCapability("xai", model, "reasoning") then
        if config.api_params and config.api_params.xai_reasoning then
            body.reasoning_effort = config.api_params.xai_reasoning.effort
        end
    end
    return body
end

return XAIHandler
