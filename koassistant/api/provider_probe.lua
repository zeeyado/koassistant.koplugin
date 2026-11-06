-- Test provider's requests (main.lua testProvider sends them). Each step is
-- built by the provider's own handler, so the probe sends what a real request
-- sends: thinking off in DeepSeek and Kimi tool sessions, the Responses
-- endpoint for OpenAI and xAI book tools, the renamed token field, forced
-- temperatures, the region host. A probe that wrote its own requests reported
-- book tools broken on DeepSeek, whose real tool requests switch thinking off.
-- docs/provider_probe_plan.md

local BaseHandler = require("koassistant.api.base")

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

--- What the plugin's own parser makes of the plain step's 200 (B484): a host
--- that answers in a shape the parser cannot read used to pass "reachable"
--- and fail on the first real request.
--- @param handler table  the provider's handler
--- @param body string  the response body
--- @param responses boolean  the step went to the Responses endpoint
--- @return string kind  "text" (an answer) | "empty" (a readable answer with no
---   text: the 16-token probe starves a model that reasons first) | "unreadable"
--- @return string|nil text  the answer, for "text"
function ProviderProbe.answer(handler, body, responses, provider_id)
    local json = require("json")
    local ok, parsed = pcall(json.decode, body)
    if not ok or type(parsed) ~= "table" then return "unreadable" end
    -- The OpenAI and DeepSeek handlers extend BaseHandler and name no parser
    -- key, so the provider id is the last resort (without it the Reachability
    -- step called their correct answers unreadable; sweep 2026-11-06)
    local key = responses and "openai_responses"
        or (handler.getResponseParserKey and handler:getResponseParserKey())
        or handler.provider_name
        or provider_id
    local ResponseParser = require("koassistant.api.response_parser")
    local called, success, content = pcall(ResponseParser.parseResponse, ResponseParser, parsed, key)
    if not called or not success then return "unreadable" end
    if type(content) == "string" and content:match("%S") then
        return "text", (content:gsub("%s+", " "))
    end
    return "empty"
end

return ProviderProbe
