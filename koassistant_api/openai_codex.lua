local OpenAIHandler = require("koassistant_api.openai")
local BaseHandler = require("koassistant_api.base")
local ResponseParser = require("koassistant_api.response_parser")
local DebugUtils = require("koassistant_debug_utils")
local ModelConstraints = require("model_constraints")
local OAuth = require("koassistant_openai_codex_oauth")
local ffi = require("ffi")
local json = require("json")
local meta = require("_meta")

local CodexHandler = OpenAIHandler:new()

local CODEX_URL = "https://chatgpt.com/backend-api/codex/responses"
local USER_AGENT = "KOAssistant/" .. tostring(meta.version or "unknown")
    .. " (unofficial OpenAI Codex subscription client)"
local ORIGINATOR = "koassistant"

local function buildHeaders(config)
    local account_id = config.oauth and config.oauth.chatgpt_account_id
    return {
        ["Content-Type"] = "application/json",
        ["Authorization"] = "Bearer " .. (config.api_key or ""),
        ["ChatGPT-Account-ID"] = account_id or "",
        ["User-Agent"] = USER_AGENT,
        ["originator"] = ORIGINATOR,
    }
end

-- Codex requires SSE even when KOAssistant's caller expects one buffered
-- response. Keep that transport quirk local while reusing BaseHandler's
-- fork-safe HTTP implementation and pipe protocol.
local function makeCollectedRequest(url, headers, body, response_transform)
    local resolved_ip = BaseHandler.resolveForSubprocess(url)
    return function(pid, child_write_fd)
        if not pid or not child_write_fd then return end

        local subprocess_ok, subprocess_err = pcall(function()
            local status_code, response_body = BaseHandler.fetchInSubprocess(url, {
                method = "POST",
                headers = headers or {},
                body = body or "",
                resolved_ip = resolved_ip,
                timeout = 180,
            })
            if status_code ~= 200 then
                local message = status_code
                    and BaseHandler.formatNon200(status_code, response_body)
                    or ("Connection error: " .. tostring(response_body))
                BaseHandler.writeAllToFD(child_write_fd,
                    string.format("\r\n%s%s\n\n", BaseHandler.PROTOCOL_NON_200, message))
                return
            end

            local transform_ok, transformed = pcall(response_transform, response_body)
            if not transform_ok then
                BaseHandler.writeAllToFD(child_write_fd,
                    string.format("\r\n%sResponse transform error: %s\n\n",
                        BaseHandler.PROTOCOL_NON_200, tostring(transformed)))
                return
            end
            BaseHandler.writeAllToFD(child_write_fd, tostring(transformed or ""))
        end)

        if not subprocess_ok then
            BaseHandler.writeAllToFD(child_write_fd,
                string.format("\r\n%sSubprocess error: %s\n\n",
                    BaseHandler.PROTOCOL_NON_200, tostring(subprocess_err)))
        end
        ffi.C.close(child_write_fd)
        pcall(function() ffi.C._exit(0) end)
    end
end

function CodexHandler:buildRequestBody(message_history, config)
    local model = config.model or "gpt-5.6-terra"
    local built = self:buildResponsesRequest(message_history, config, model)
    built.url = CODEX_URL
    built.provider = "openai_codex"
    built.headers = buildHeaders(config)
    -- ChatGPT's Codex backend chooses its own output ceiling and rejects the
    -- public Responses API's max_output_tokens field.
    built.body.max_output_tokens = nil
    return built
end

function CodexHandler:query(message_history, config)
    if not config or not config.api_key then
        return "Error: Missing OAuth access token in configuration"
    end
    if not (config.oauth and config.oauth.chatgpt_account_id) then
        return "Error: Missing ChatGPT account id in OAuth configuration"
    end

    local built = self:buildRequestBody(message_history, config)
    local request_body = built.body
    local base_url = built.url
    local headers = built.headers
    local use_streaming = config.features and config.features.enable_streaming ~= false

    if config and config.features and config.features.debug then
        ModelConstraints.logAdjustments("OpenAI Subscription", built.adjustments)
        DebugUtils.print("OpenAI Codex Request Body:", request_body, config)
        print("Streaming enabled:", use_streaming and "yes" or "no")
    end

    -- This backend rejects non-streaming requests. Always use SSE on the wire;
    -- non-streaming callers (including book-tool gather rounds) collect it in
    -- the subprocess and receive an ordinary Responses object.
    request_body.stream = true
    local requestBody = BaseHandler.encodeBody(request_body)
    headers["Content-Length"] = tostring(#requestBody)
    headers["Accept"] = "text/event-stream"

    if use_streaming then
        local stream_fn = self:backgroundRequest(base_url, headers, requestBody)
        local effort = request_body.reasoning and request_body.reasoning.effort
        -- "none" is the off setting (gpt-6 sol/luna), not a reasoning request
        if effort and effort ~= "none" then
            return {
                _stream_fn = stream_fn,
                _reasoning_requested = true,
                _reasoning_effort = effort,
            }
        end
        return stream_fn
    end

    local parser_key = built.parser or "openai_responses"
    local reasoning_effort = request_body.reasoning and request_body.reasoning.effort
    if reasoning_effort == "none" then reasoning_effort = nil end  -- the off setting
    local debug_enabled = config and config.features and config.features.debug

    local response_parser = function(response)
        if debug_enabled then
            DebugUtils.print("OpenAI Codex Parsed Response:", response, config)
        end
        local parse_success, result, reasoning, web_search_used = ResponseParser:parseResponse(response, parser_key)
        if not parse_success then
            return false, "Error: " .. result
        end
        if reasoning_effort then
            return true, result, { _requested = true, effort = reasoning_effort }, web_search_used
        end
        return true, result, reasoning, web_search_used
    end

    return {
        _background_fn = makeCollectedRequest(
            base_url, headers, requestBody, ResponseParser.collectResponsesSSE),
        _non_streaming = true,
        _response_parser = response_parser,
    }
end

function CodexHandler:getOAuthModule()
    return OAuth
end

return CodexHandler
