local BaseHandler = require("koassistant_api.base")
local https = require("ssl.https")
local ltn12 = require("ltn12")
local json = require("json")
local Defaults = require("koassistant_api.defaults")
local ResponseParser = require("koassistant_api.response_parser")
local ModelConstraints = require("model_constraints")
local DebugUtils = require("koassistant_debug_utils")

local OpenAIHandler = BaseHandler:new()

-- Helper: Check if message has non-empty content
local function hasContent(msg)
    if not msg or not msg.content then return false end
    if type(msg.content) == "string" then
        return msg.content:match("%S") ~= nil
    end
    return true
end

--- Resolve the effective web-search decision (per-action override > global),
--- same pattern as anthropic_request.lua.
local function webSearchEnabled(config)
    if config.enable_web_search ~= nil then
        return config.enable_web_search and true or false
    end
    return (config.features and config.features.enable_web_search) and true or false
end

--- Route this request to the Responses API (/v1/responses)? Capable models
--- (the responses_web_search list) route there when native web search is
--- wanted (R1) OR when book tools are declared (R3): on Responses, reasoning
--- state persists across tool rounds via encrypted reasoning items — Chat
--- Completions re-reasons from scratch every round. The runner keeps one
--- endpoint per session: every tool-turn config carries config.tools (gather /
--- tools / final modes), so _responses_items history entries are only ever
--- replayed by buildResponsesRequest.
local function shouldUseResponses(config, model)
    if not ModelConstraints.supportsCapability("openai", model, "responses_web_search") then
        return false
    end
    if config.tools ~= nil then return true end
    return webSearchEnabled(config)
end

--- Build a Responses API request. Differences from Chat Completions: `input`
--- items instead of `messages`, system prompt as `instructions`,
--- `max_output_tokens`, flat tool defs, and the native web_search tool.
--- @return table: { body, headers, url, model, provider, parser, adjustments }
function OpenAIHandler:buildResponsesRequest(message_history, config, model)
    local defaults = Defaults.ProviderDefaults.openai
    -- Adjustment entries must be {from, to, reason} tables — logAdjustments
    -- indexes them (a bare boolean here crashed debug-enabled requests).
    local adjustments = {
        responses_api = { to = "/v1/responses", reason = "native web search / book tools" },
    }

    local request_body = {
        model = model,
        input = {},
        -- Stateless by design: full history is resent each turn and chats must
        -- never be retained server-side (the API default is store=true).
        store = false,
    }

    if config.system and config.system.text and config.system.text ~= "" then
        request_body.instructions = config.system.text
    end

    for _, msg in ipairs(message_history) do
        if type(msg._responses_items) == "table" then
            -- A completed tool turn appended by tool_wire's Responses branch:
            -- raw output items (reasoning/function_call/message) + our
            -- function_call_output items, replayed verbatim (the documented
            -- stateless pattern for store=false).
            for _idx, item in ipairs(msg._responses_items) do
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
    local max_tokens = api_params.max_tokens or default_params.max_tokens or 16384
    -- Same reasoning-headroom bump as the Chat Completions path
    if not api_params.max_tokens and ModelConstraints.supportsCapability("openai", model, "reasoning") then
        max_tokens = 32768
    end
    request_body.max_output_tokens = max_tokens

    -- Temperature is deliberately OMITTED: every model in responses_web_search
    -- is a gpt-5.x that accepts only its default (the chat path forces 1.0);
    -- sending nothing yields the same behavior with zero reject risk.

    -- Reasoning effort rides nested on this API (not top-level reasoning_effort)
    if api_params.reasoning and api_params.reasoning.effort then
        if ModelConstraints.supportsCapability("openai", model, "reasoning") then
            request_body.reasoning = { effort = api_params.reasoning.effort }
        else
            adjustments.reasoning_skipped = {
                reason = "model " .. model .. " does not support reasoning"
            }
        end
    end

    -- Native web search (when active — tool-turn configs force it off).
    -- Effort dial → search_context_size (standard omits = API default), matching
    -- the Perplexity mapping convention.
    if webSearchEnabled(config) then
        local EFFORT_CONTEXT_SIZE = { light = "low", thorough = "high" }
        local effort = ModelConstraints.webSearchEffort(config.features)
        request_body.tools = {
            { type = "web_search", search_context_size = EFFORT_CONTEXT_SIZE[effort] },
        }
    end

    -- Book-tool declarations (R3): Responses takes FLAT function defs (no
    -- nested "function" wrapper). Same mode mapping as the chat path.
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
        -- Stateless tool loop: reasoning items must be replayed alongside their
        -- function calls (gpt-5.x rejects orphaned function_call items), which
        -- with store=false requires their encrypted form.
        request_body.include = { "reasoning.encrypted_content" }
    end

    local headers = {
        ["Content-Type"] = "application/json",
        ["Authorization"] = "Bearer " .. (config.api_key or ""),
    }

    -- Derive the endpoint from the configured base URL so custom bases keep
    -- working; a nonstandard base without /chat/completions passes through
    -- unchanged (visible 404 rather than a silent wrong host).
    local url = (config.base_url or defaults.base_url):gsub("/chat/completions", "/responses")

    return {
        body = request_body,
        headers = headers,
        url = url,
        model = model,
        provider = "openai",
        parser = "openai_responses",
        adjustments = adjustments,
    }
end

--- Build the request body, headers, and URL without making the API call.
--- This is used by the test inspector to see exactly what would be sent.
--- @param message_history table: Array of message objects
--- @param config table: Unified config from buildUnifiedRequestConfig
--- @return table: { body = table, headers = table, url = string }
function OpenAIHandler:buildRequestBody(message_history, config)
    local defaults = Defaults.ProviderDefaults.openai
    local model = config.model or defaults.model

    -- Native web search lives on the Responses API — route there when wanted
    if shouldUseResponses(config, model) then
        return self:buildResponsesRequest(message_history, config, model)
    end

    -- Build request body using unified config
    local request_body = {
        model = model,
        messages = {},
    }

    -- Add system message from unified config
    if config.system and config.system.text and config.system.text ~= "" then
        table.insert(request_body.messages, {
            role = "system",
            content = config.system.text,
        })
    end

    -- Add conversation messages (filter out system role and empty content).
    -- Tool turns must survive intact: an assistant tool-call turn keeps tool_calls (its content
    -- may legitimately be nil), and a tool-result turn keeps role="tool" + tool_call_id.
    for _, msg in ipairs(message_history) do
        if msg.role == "tool" and msg.tool_call_id then
            table.insert(request_body.messages, {
                role = "tool",
                tool_call_id = msg.tool_call_id,
                content = msg.content,
            })
        elseif msg.role == "assistant" and msg.tool_calls then
            table.insert(request_body.messages, {
                role = "assistant",
                content = msg.content,
                tool_calls = msg.tool_calls,
                -- OpenRouter reasoning backends need this back verbatim on replay
                reasoning_details = msg.reasoning_details,
            })
        elseif msg.role ~= "system" and hasContent(msg) then
            table.insert(request_body.messages, {
                role = msg.role == "assistant" and "assistant" or "user",
                content = msg.content,
            })
        end
    end

    -- Apply API parameters from unified config
    local api_params = config.api_params or {}
    local default_params = defaults.additional_parameters or {}

    request_body.temperature = api_params.temperature or default_params.temperature or 0.7
    request_body.max_tokens = api_params.max_tokens or default_params.max_tokens or 16384

    -- Reasoning models (o3, o4-mini, GPT-5) share max_completion_tokens between
    -- reasoning and content. Bump default to give headroom (like Gemini's 32768).
    -- Only when action didn't explicitly set max_tokens.
    if not api_params.max_tokens and ModelConstraints.supportsCapability("openai", model, "reasoning") then
        request_body.max_tokens = 32768
    end

    -- OpenAI's newer models (GPT-5.x, o-series, GPT-4.1) require max_completion_tokens instead of max_tokens
    local needs_new_param = model:match("^gpt%-5") or model:match("^o%d") or model:match("^gpt%-4%.1")
    if needs_new_param and request_body.max_tokens then
        request_body.max_completion_tokens = request_body.max_tokens
        request_body.max_tokens = nil
    end

    -- Apply model-specific constraints (e.g., temperature=1.0 for gpt-5/o3 models)
    local adjustments
    request_body, adjustments = ModelConstraints.apply("openai", model, request_body)

    -- Add reasoning effort for o-series and GPT-5 models if enabled
    -- OpenAI uses reasoning_effort as a top-level parameter (low/medium/high)
    if api_params.reasoning and api_params.reasoning.effort then
        if ModelConstraints.supportsCapability("openai", model, "reasoning") then
            request_body.reasoning_effort = api_params.reasoning.effort
        else
            adjustments.reasoning_skipped = {
                reason = "model " .. model .. " does not support reasoning"
            }
        end
    end

    -- Note: OpenAI Chat Completions has no native web search — web-search-on
    -- requests route to the Responses API above (models outside the
    -- responses_web_search capability list fall through here without search).

    -- Book-tool declarations from the neutral config.tools (set by the tool runner).
    -- mode NONE = the runner's final pass: declarations must stay (tool turns are being
    -- replayed in the history) but no further calls are allowed.
    if config.tools and config.tools.specs then
        request_body.tools = {}
        for _, spec in ipairs(config.tools.specs) do
            table.insert(request_body.tools, {
                type = "function",
                ["function"] = {
                    name = spec.name,
                    description = spec.description,
                    parameters = spec.parameters,
                },
            })
        end
        if config.tools.mode == "NONE" then
            request_body.tool_choice = "none"
        elseif config.tools.mode == "ANY" then
            -- Gather rounds force a tool call (search or done) so the model can never
            -- answer in prose on the non-streamed gather path.
            request_body.tool_choice = "required"
        else
            request_body.tool_choice = "auto"
        end
    end

    local headers = {
        ["Content-Type"] = "application/json",
        ["Authorization"] = "Bearer " .. (config.api_key or ""),
    }

    local url = config.base_url or defaults.base_url

    return {
        body = request_body,
        headers = headers,
        url = url,
        model = model,
        provider = "openai",
        adjustments = adjustments,  -- Include for test inspector visibility
    }
end

function OpenAIHandler:query(message_history, config)
    if not config or not config.api_key then
        return "Error: Missing API key in configuration"
    end

    -- Use buildRequestBody to construct the request (single source of truth)
    local built = self:buildRequestBody(message_history, config)
    local request_body = built.body
    local base_url = built.url
    local adjustments = built.adjustments

    -- Check if streaming is enabled
    local use_streaming = config.features and config.features.enable_streaming

    -- Debug: Print constraint adjustments and request body
    if config and config.features and config.features.debug then
        ModelConstraints.logAdjustments("OpenAI", adjustments)
        DebugUtils.print("OpenAI Request Body:", request_body, config)
        print("Streaming enabled:", use_streaming and "yes" or "no")
    end

    local requestBody = json.encode(request_body)
    local headers = {
        ["Content-Type"] = "application/json",
        ["Authorization"] = "Bearer " .. config.api_key,
        ["Content-Length"] = tostring(#requestBody),
    }

    -- If streaming is enabled, return the background request function
    if use_streaming then
        -- Add stream parameter to request body
        local stream_request_body = json.decode(requestBody)
        stream_request_body.stream = true
        local stream_body = json.encode(stream_request_body)
        headers["Content-Length"] = tostring(#stream_body)
        headers["Accept"] = "text/event-stream"

        local stream_fn = self:backgroundRequest(base_url, headers, stream_body)

        -- If reasoning was requested, wrap the function with metadata
        -- so gpt_query.lua knows to show "reasoning requested" indicator
        -- (top-level reasoning_effort on Chat Completions, nested on Responses)
        local stream_reasoning_effort = request_body.reasoning_effort
            or (type(request_body.reasoning) == "table" and request_body.reasoning.effort)
        if stream_reasoning_effort then
            return {
                _stream_fn = stream_fn,
                _reasoning_requested = true,
                _reasoning_effort = stream_reasoning_effort,
            }
        end

        return stream_fn
    end

    -- Non-streaming mode: use background request for non-blocking UI
    local reasoning_effort = request_body.reasoning_effort
        or (type(request_body.reasoning) == "table" and request_body.reasoning.effort)
    local parser_key = built.parser or "openai"
    local debug_enabled = config and config.features and config.features.debug

    local response_parser = function(response)
        -- Debug: Print parsed response
        if debug_enabled then
            DebugUtils.print("OpenAI Parsed Response:", response, config)
        end

        local parse_success, result, reasoning, web_search_used = ResponseParser:parseResponse(response, parser_key)
        if not parse_success then
            return false, "Error: " .. result
        end

        -- Return with reasoning metadata if requested
        if reasoning_effort then
            return true, result, { _requested = true, effort = reasoning_effort }, web_search_used
        end

        return true, result, reasoning, web_search_used
    end

    return {
        _background_fn = self:backgroundRequest(base_url, headers, requestBody),
        _non_streaming = true,
        _response_parser = response_parser,
    }
end

return OpenAIHandler
