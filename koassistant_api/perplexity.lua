--[[--
Perplexity API Handler

Perplexity's Agent API (POST /v1/agent, Responses-shaped). The Sonar chat
completions wire this handler used before retired 2026-09-27 (B078).

Model ids on this wire:
- A "provider/model" id is a model (e.g. "perplexity/sonar", the default; the
  model list holds only these), sent as `model`. With web search on it rides
  with the fast preset (SEARCH_PRESET), which swaps in the model and keeps the
  preset's search and citation rules, as picking a model in Perplexity's own app
  does. Alone, a model searches only when it decides to and writes no [n]
  markers (probed 2026-09-28). With web search off it goes alone, without tools.
  Models the preset's settings break are listed in
  ModelConstraints.capabilities.perplexity (no_sampling_params,
  reasoning_mandatory, no_search_preset; the whole catalog probed 2026-09-28).
- A bare id is a PRESET ("fast", "low", "medium", "high"): Perplexity's managed
  bundle of search setup + system prompt with citation rules + a model it picks,
  sent as `preset`. None is listed (a preset is not a model), but a typed one
  works. A preset ALWAYS searches: the API has no public way to take its
  web_search tool away (`tool_choice` and `max_tool_calls` are ignored, probed
  2026-09-27), so a request with web search off goes to Perplexity's own Sonar
  model without tools instead (WEB_OFF_MODEL).
- A retired Sonar id (sonar-pro, ...) maps to perplexity/sonar
  (ModelLists._retired), so an old pick anywhere in the settings keeps working.

Our system prompt rides as a system INPUT item, never `instructions`: that field
replaces a preset's own prompt and its citation rules with it (probed: the answer
came back without markers). Citations are inline markers ([n] on the fast preset,
[web:n] on the others); the response parser turns them into footnotes.

Endpoint: https://api.perplexity.ai/v1/agent
Docs: https://docs.perplexity.ai/docs/agent-api/quickstart

@module perplexity
]]

local OpenAICompatibleHandler = require("koassistant_api.openai_compatible")
local Defaults = require("koassistant_api.defaults")
local ModelConstraints = require("model_constraints")
local ModelLists = require("koassistant_model_lists")

local PerplexityHandler = OpenAICompatibleHandler:new()

-- Where a request with web search off goes when the chosen id is a preset
local WEB_OFF_MODEL = "perplexity/sonar"
PerplexityHandler.WEB_OFF_MODEL = WEB_OFF_MODEL
-- The preset a direct model rides with while web search is on
local SEARCH_PRESET = "fast"
PerplexityHandler.SEARCH_PRESET = SEARCH_PRESET

function PerplexityHandler:getProviderName()
    return "Perplexity"
end

function PerplexityHandler:getProviderKey()
    return "perplexity"
end

-- A direct model may still write <think> tags into its answer
function PerplexityHandler:supportsReasoningExtraction()
    return true
end

local function hasContent(msg)
    if not msg or not msg.content then return false end
    if type(msg.content) == "string" then
        return msg.content:match("%S") ~= nil
    end
    return true
end

--- Resolved web decision: explicit false (action pin, Web chip off, book/global
--- via the bake) turns search off; nil falls to the global, and an untouched
--- global keeps Perplexity's native default (search on). The Web chip seeds ON
--- for this provider (BookSettings.resolveWebSearch) so the default is truthful.
local function webSearchEnabled(config)
    if config.enable_web_search ~= nil then
        return config.enable_web_search and true or false
    end
    if config.features and config.features.enable_web_search ~= nil then
        return config.features.enable_web_search and true or false
    end
    return true
end

--- Build the Agent API request.
--- @return table { body, headers, url, model, provider, parser, adjustments }
function PerplexityHandler:buildRequestBody(message_history, config)
    local defaults = Defaults.ProviderDefaults.perplexity or {}
    -- Non-empty config.model > provider default, as ModelConstraints.dispatchModel reads it
    local configured = (config.model ~= "" and config.model) or defaults.model
    -- Adjustment entries must be {from, to, reason} tables (logAdjustments indexes them)
    local adjustments = {}

    local target = ModelLists.retiredReplacement("perplexity", configured)
    if target then
        adjustments.retired_model = { from = configured, to = target,
            reason = "the Sonar chat wire retired 2026-09-27" }
    else
        target = configured
    end
    local web_on = webSearchEnabled(config)
    local is_preset = not target:find("/", 1, true)
    if is_preset and not web_on then
        adjustments.web_off = { from = target, to = WEB_OFF_MODEL, reason = "a preset always searches" }
        target, is_preset = WEB_OFF_MODEL, false
    end

    local request_body = {
        input = {},
        -- Stateless by design: the full history is resent each turn and chats
        -- must never be retained server-side.
        store = false,
    }
    if is_preset then
        request_body.preset = target
    else
        request_body.model = target
        if web_on and not ModelConstraints.supportsCapability("perplexity", target, "no_search_preset") then
            request_body.preset = SEARCH_PRESET
            adjustments.preset = { from = "none", to = SEARCH_PRESET,
                reason = "the preset searches and cites for the chosen model" }
            -- The preset turns reasoning off, which some models refuse
            if ModelConstraints.supportsCapability("perplexity", target, "reasoning_mandatory") then
                request_body.reasoning = { effort = "low" }
            end
        end
    end

    if config.system and config.system.text and config.system.text ~= "" then
        table.insert(request_body.input, {
            type = "message", role = "system", content = config.system.text,
        })
    end
    -- One item per turn: the agent wire takes consecutive same-role items
    -- (probed), so the context message and the question stay separate.
    for _idx, msg in ipairs(message_history) do
        if msg.role ~= "system" and hasContent(msg) then
            table.insert(request_body.input, {
                type = "message",
                role = msg.role == "assistant" and "assistant" or "user",
                content = msg.content,
            })
        end
    end

    local api_params = config.api_params or {}
    local default_params = defaults.additional_parameters or {}
    -- A preset carries its own sampling: the low preset refuses any temperature
    -- ("invalid request", probed 2026-09-27) while fast accepts one. A direct
    -- model takes one, alone or with the search preset, unless it refuses
    -- sampling params (no_sampling_params, probed 2026-09-28).
    if not is_preset and not ModelConstraints.supportsCapability("perplexity", target, "no_sampling_params") then
        request_body.temperature = api_params.temperature or default_params.temperature or 0.7
    end
    local max_tokens = api_params.max_tokens
        or ModelConstraints.resolveMaxTokens("perplexity", target, default_params.max_tokens or 16384)
    request_body.max_output_tokens = ModelConstraints.clampMaxTokens("perplexity", target, max_tokens)

    -- Model parameter constraints (curated + custom_models.lua)
    local constrained
    request_body, constrained = ModelConstraints.apply("perplexity", target, request_body)
    for param, adj in pairs(constrained or {}) do adjustments[param] = adj end

    -- Reasoning effort from the per-model resolver, forwarded to a typed preset
    -- only. The profiles that yield one belong to the retired Sonar reasoning
    -- ids, which now land on perplexity/sonar (no reasoning), so on the listed
    -- models nothing reaches here (docs/perplexity_agent_plan.md, open question).
    local reasoning = api_params.perplexity_reasoning
    if is_preset and type(reasoning) == "table" and reasoning.effort then
        request_body.reasoning = { effort = reasoning.effort }
    end

    -- Web search: a preset brings its own web_search tool (listing it here only
    -- overrides that tool's options); a model riding alone (no_search_preset)
    -- searches only with the tool given, when it decides to. The effort dial
    -- maps to search_context_size; standard sends nothing.
    if web_on then
        local tool = { type = "web_search" }
        local effort = ModelConstraints.webSearchEffort(config.features)
        if effort ~= "standard" then
            tool.search_context_size = effort == "light" and "low" or "high"
        end
        if not request_body.preset or tool.search_context_size then
            request_body.tools = { tool }
        end
    end

    local headers = {
        ["Content-Type"] = "application/json",
        ["Authorization"] = "Bearer " .. (config.api_key or ""),
    }

    -- A base URL override written for the retired chat wire points at the agent endpoint
    local url = (config.base_url or defaults.base_url or ""):gsub("/chat/completions$", "/v1/agent")

    return {
        body = request_body,
        headers = headers,
        url = url,
        model = target,
        provider = "perplexity",
        parser = "perplexity",
        adjustments = adjustments,
    }
end

return PerplexityHandler
