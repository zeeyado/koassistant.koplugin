-- Test provider's requests (main.lua testProvider sends them). Each step is
-- built by the provider's own handler, so the probe sends what a real request
-- sends: thinking off in DeepSeek and Kimi tool sessions, the Responses
-- endpoint for OpenAI and xAI book tools, the renamed token field, forced
-- temperatures, the region host. A probe that wrote its own requests reported
-- book tools broken on DeepSeek, whose real tool requests switch thinking off.
-- docs/provider_probe_plan.md

local BaseHandler = require("koassistant_api.base")

local ProviderProbe = {}

-- One harmless function in the book-tools declaration shape
ProviderProbe.PING = {
    name = "ping",
    description = "Connectivity test.",
    parameters = { type = "object",
        properties = { ping = { type = "string", description = "Any value." } } },
}

-- 16 tokens keep a plain step cheap; a tool call needs room, and so does a
-- model that reasons before it calls
local PLAIN_TOKENS, TOOL_TOKENS = 16, 512

--- The request one probe step sends.
--- @param handler table  the provider's handler (custom providers: custom_openai)
--- @param base table  the request config after the router's merge (provider, model,
---   api_key, base_url, features)
--- @param step string  "plain" | "stream" | "tools" | "forced_tools" | "effort"
--- @return table { url, headers, payload, responses } (responses = the Responses endpoint)
function ProviderProbe.request(handler, base, step)
    local config = {}
    for k, v in pairs(base) do config[k] = v end
    local tools = step == "tools" or step == "forced_tools"
    local features = base.features or {}
    config.api_params = {
        max_tokens = tools and TOOL_TOKENS or PLAIN_TOKENS,
        temperature = features.default_temperature,  -- as buildUnifiedRequestConfig sets it
    }
    -- Web search off, as in the tool runner's rounds (buildToolConfig)
    config.enable_web_search = false
    if tools then
        config.tools = { specs = { ProviderProbe.PING }, mode = step == "tools" and "AUTO" or "ANY" }
    end

    local built = handler:buildRequestBody({ { role = "user", content = "Reply with only: ok" } }, config)
    local body = built.body
    local headers = {}
    for k, v in pairs(built.headers or {}) do headers[k] = v end
    if step == "stream" then
        body.stream = true
        headers["Accept"] = "text/event-stream"
    elseif step == "effort" then
        -- Whether the host accepts the parameter at all (custom and community hosts)
        body.reasoning_effort = "low"
    end
    local payload = BaseHandler.encodeBody(body)
    headers["Content-Length"] = tostring(#payload)
    return {
        url = built.url,
        headers = headers,
        payload = payload,
        responses = built.parser == "openai_responses",
    }
end

return ProviderProbe
