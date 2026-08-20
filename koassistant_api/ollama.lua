local BaseHandler = require("koassistant_api.base")
local http = require("socket.http")
local ltn12 = require("ltn12")
local json = require("json")
local Defaults = require("koassistant_api.defaults")
local ResponseParser = require("koassistant_api.response_parser")
local DebugUtils = require("koassistant_debug_utils")
local logger = require("koassistant_logger")
local _ = require("koassistant_gettext")
local T = require("ffi/util").template

local OllamaHandler = BaseHandler:new()

-- Helper: Check if message has non-empty content
local function hasContent(msg)
    if not msg or not msg.content then return false end
    if type(msg.content) == "string" then
        return msg.content:match("%S") ~= nil
    end
    return true
end

-- Ollama gives each request a context window and silently truncates anything
-- longer (its own default is 4096 tokens, which is why a ~20K-char recap once
-- came back reporting exactly 4096 input tokens, device 2026-08-15).
--
-- The plugin does NOT decide that window for you by default. It is memory on
-- someone else's machine: ollama never shrinks an oversized KV cache, it
-- offloads layers to CPU and refuses to load when RAM is short too, and a
-- request num_ctx OVERRIDES a Modelfile PARAMETER (probed on 0.17.7), so a
-- default of our own would quietly overrule a deliberately tuned server. What
-- the plugin owes the reader instead is the truth when a prompt was cut, which
-- the stream handler proves from ollama's own prompt_eval_count.
--
-- features.ollama_num_ctx: nil = send no num_ctx, the server's Modelfile /
-- OLLAMA_CONTEXT_LENGTH decides (default). A NUMBER = fit num_ctx to each
-- request, in power-of-two buckets, never above that many tokens. Bucketing is
-- load-bearing: a changed num_ctx forces ollama to reload the model, so nearby
-- request sizes must land in the same bucket to keep the runner warm. An
-- explicit api_params.num_ctx (configuration.lua) still wins over both.
local NUM_CTX_FLOOR = 8192

-- Characters per token, measured on a device log (515,522 chars evaluated as
-- 116,865 tokens on English prose). Used for what we SAY; the sizing below
-- keeps its more generous chars/3 margin for what we ASK FOR.
local CHARS_PER_TOKEN = 4.4

-- What the server was last seen to actually allow, learned from ollama's own
-- prompt_eval_count when a reply came back truncated (recorded by the stream
-- handler). Session-scoped and per model: it exists so the SECOND oversized
-- request can be warned about before it is sent, in the default mode where the
-- window is the server's business and we have no other way to know it.
OllamaHandler.observed_context = {}
OllamaHandler.probed = {}   -- models the server has already been asked about

function OllamaHandler.recordObservedContext(model, tokens)
    if type(model) == "string" and type(tokens) == "number" and tokens > 0 then
        OllamaHandler.observed_context[model] = tokens
    end
end

local function promptChars(messages)
    local chars = 0
    for _, m in ipairs(messages) do
        if type(m.content) == "string" then
            chars = chars + #m.content
        end
    end
    return chars
end

local function contextBucket(chars, features)
    local ceiling = (features or {}).ollama_num_ctx
    if type(ceiling) ~= "number" or ceiling < NUM_CTX_FLOOR then return nil end
    -- chars/3 is deliberately generous: dense scripts and JSON escaping run
    -- below the measured 4.4 chars per token.
    local needed = math.ceil(chars / 3) + 4096
    local bucket = NUM_CTX_FLOOR
    while bucket < needed and bucket * 2 <= ceiling do
        bucket = bucket * 2
    end
    return bucket
end

-- Said BEFORE the request goes out, because that is when it is worth anything:
-- a truncated whole-book prompt on a local model streams for minutes, and a
-- notice at the end arrives after the reader has already read a confident
-- answer built on a fraction of the book (device 2026-08-20: the reader waited,
-- saw nothing, and quit before the stream ever finished). Scheduled a beat late
-- so it lands on top of the streaming window rather than under it, and it does
-- not block: the request is already on its way and may still be useful.
local function warnBeforeSend(window, est_tokens, fitted)
    local ok_ui, UIManager = pcall(require, "ui/uimanager")
    local ok_msg, InfoMessage = pcall(require, "ui/widget/infomessage")
    if not (ok_ui and ok_msg) then return end
    local pct = math.max(1, math.floor((window / est_tokens) * 100 + 0.5))
    local text
    if fitted then
        text = T(_([[Only part of this request will reach the model.

It is about %1 tokens and the limit set here is %2, so roughly %3% of it gets through. The rest, usually the earliest book text, is cut by Ollama.

Raise the limit in the model menu ("Context window") if the machine running Ollama has the memory, or ask about a smaller part of the book.]]),
            tostring(est_tokens), tostring(window), tostring(pct))
    else
        text = T(_([[Only part of this request will reach the model.

It is about %1 tokens and your Ollama server allows %2, so roughly %3% of it gets through. The rest, usually the earliest book text, is cut by Ollama.

Raise Ollama's context window (OLLAMA_CONTEXT_LENGTH, or PARAMETER num_ctx on the model), or let KOAssistant set it per request in the model menu ("Context window").]]),
            tostring(est_tokens), tostring(window), tostring(pct))
    end
    UIManager:scheduleIn(0.8, function()
        UIManager:show(InfoMessage:new{ text = text })  -- no timeout: tap to dismiss
    end)
end

-- Nothing can be cut below this, so a request under it never pays for a probe.
-- (Ollama's own default window is 4096.)
local PROBE_MIN_TOKENS = 4096

local function serverRoot(config)
    local url = (config and config.base_url)
        or (Defaults.ProviderDefaults.ollama or {}).base_url or ""
    return (url:gsub("/api/chat$", ""))
end

-- ASK the server what window this model gets, rather than shrugging. Probed on
-- 0.17.7: /api/ps reports the loaded runner's context_length, which is the
-- EFFECTIVE window and reflects OLLAMA_CONTEXT_LENGTH and a Modelfile num_ctx
-- alike. /api/show is the wrong source and would cry wolf in reverse: it
-- reported 131072 (the model's TRAINED maximum) for a runner that in fact
-- allowed 4096. When nothing is loaded, ollama's own load-only call (POST
-- /api/generate with a model and no prompt, answering done_reason "load")
-- brings the runner up so ps can answer — and that is the same load the real
-- request was about to trigger anyway, so the reader waits for it once either
-- way. Answer cached per model for the session.
local function probeServerWindow(config, model)
    local Base = require("koassistant_api.base")
    local root = serverRoot(config)

    local function askPs()
        local code, body = Base.fetchInSubprocess(root .. "/api/ps", { timeout = 3 })
        if tonumber(code) ~= 200 or type(body) ~= "string" then return nil end
        local ok, decoded = pcall(json.decode, body)
        if not ok or type(decoded) ~= "table" or type(decoded.models) ~= "table" then
            return nil
        end
        for _, m in ipairs(decoded.models) do
            if m.name == model or m.model == model then
                return tonumber(m.context_length)
            end
        end
        return nil
    end

    local window = askPs()
    if window then return window end

    local payload = json.encode({ model = model })
    local code = Base.fetchInSubprocess(root .. "/api/generate", {
        method = "POST",
        timeout = 120,
        body = payload,
        headers = {
            ["Content-Type"] = "application/json",
            ["Content-Length"] = tostring(#payload),
        },
    })
    if tonumber(code) ~= 200 then return nil end
    return askPs()
end

-- The window this request will actually get: the limit the reader set, what the
-- model was last seen to allow, or — for a big request in the default mode,
-- which is exactly where readers meet truncation — what the server says when
-- asked. Only a request too small to be cut skips the question.
local function checkTruncation(messages, config, model)
    local features = config and config.features or {}
    local chars = promptChars(messages)
    local bucket = contextBucket(chars, features)
    local est_tokens = math.ceil(chars / CHARS_PER_TOKEN)
    local window = bucket or OllamaHandler.observed_context[model]

    if not window and type(model) == "string"
            and est_tokens > PROBE_MIN_TOKENS
            and not features._background_request
            and not OllamaHandler.probed[model] then
        OllamaHandler.probed[model] = true  -- one attempt per model per session
        local ok, probed = pcall(probeServerWindow, config, model)
        if ok and probed then
            OllamaHandler.recordObservedContext(model, probed)
            window = probed
            logger.dbg("KOAssistant: ollama window for", model, "=", probed)
        else
            logger.dbg("KOAssistant: could not read ollama's context window for", model)
        end
    end

    if not window then return bucket end
    if est_tokens <= window then return bucket end

    logger.warn(string.format(
        "Ollama: prompt is about %d tokens, window is %d. Ollama will truncate the prompt.",
        est_tokens, window))
    -- Background work (X-Ray checkpoint builds and the like) runs unattended:
    -- log those, never interrupt with them.
    if not features._background_request then
        warnBeforeSend(window, est_tokens, bucket ~= nil)
    end
    return bucket
end

-- Book tools (Track 35; every fact probed live on Ollama 0.17.7, 2026-08-14):
-- Ollama's /api/chat speaks the OpenAI tool dialect with two deltas — call
-- `arguments` arrive as a DECODED OBJECT (handled in response_parser), and
-- `tool_choice` is silently IGNORED (probed: "required" did not force a call,
-- "none" did not suppress one). So mode NONE (the interactive final pass)
-- omits the declarations entirely instead — tool-turn replay WITHOUT
-- declarations is accepted (probed), and with nothing declared the model
-- structurally cannot stray-call. mode ANY still sends tool_choice "required"
-- for forward-compat with a version that honors it; the runner's prose
-- fallback covers today's ignore.
local function appendHistoryMessages(request_body, message_history)
    for _, msg in ipairs(message_history) do
        if msg.role == "tool" then
            -- Tool result replay: OpenAI shape accepted verbatim (probed)
            table.insert(request_body.messages, {
                role = "tool",
                tool_call_id = msg.tool_call_id,
                content = msg.content,
            })
        elseif msg.role == "assistant" and msg.tool_calls then
            -- Tool-call echo: content is "" on these turns, so it must bypass
            -- the hasContent gate or replay silently drops the call turn
            table.insert(request_body.messages, {
                role = "assistant",
                content = type(msg.content) == "string" and msg.content or "",
                tool_calls = msg.tool_calls,
            })
        elseif msg.role ~= "system" and hasContent(msg) then
            table.insert(request_body.messages, {
                role = msg.role == "assistant" and "assistant" or "user",
                content = msg.content,
            })
        end
    end
end

local function applyToolDeclarations(request_body, config)
    if not (config.tools and type(config.tools.specs) == "table"
            and #config.tools.specs > 0) then
        return
    end
    if config.tools.mode == "NONE" then return end
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
    if config.tools.mode == "ANY" then
        request_body.tool_choice = "required"
    end
end

--- Build the request body, headers, and URL without making the API call.
--- @param message_history table: Array of message objects
--- @param config table: Unified config from buildUnifiedRequestConfig
--- @return table: { body = table, headers = table, url = string }
function OllamaHandler:buildRequestBody(message_history, config)
    local defaults = Defaults.ProviderDefaults.ollama
    local model = config.model or defaults.model

    local request_body = {
        model = model,
        messages = {},
        stream = false,  -- Default to non-streaming for inspection
    }

    if config.system and config.system.text and config.system.text ~= "" then
        table.insert(request_body.messages, {
            role = "system",
            content = config.system.text,
        })
    end

    appendHistoryMessages(request_body, message_history)
    applyToolDeclarations(request_body, config)

    -- Ollama uses options object for parameters
    local api_params = config.api_params or {}
    local default_params = defaults.additional_parameters or {}

    request_body.options = {
        temperature = api_params.temperature or default_params.temperature or 0.7,
        num_ctx = api_params.num_ctx
            or contextBucket(promptChars(request_body.messages), config.features),
    }

    local headers = {
        ["Content-Type"] = "application/json",
    }

    return {
        body = request_body,
        headers = headers,
        url = config.base_url or defaults.base_url,
        model = model,
        provider = "ollama",
    }
end

function OllamaHandler:query(message_history, config)
    local defaults = Defaults.ProviderDefaults.ollama
    local model = config.model or defaults.model

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

    -- Add conversation messages (filter out system role and empty content;
    -- tool turns replay in the OpenAI shape — see appendHistoryMessages)
    appendHistoryMessages(request_body, message_history)
    applyToolDeclarations(request_body, config)

    -- Apply API parameters from unified config
    local api_params = config.api_params or {}
    local default_params = defaults.additional_parameters or {}

    -- Ollama uses options object for parameters
    request_body.options = {
        temperature = api_params.temperature or default_params.temperature or 0.7,
        num_ctx = api_params.num_ctx
            or checkTruncation(request_body.messages, config, model),
    }

    -- Check if streaming is enabled
    local use_streaming = config.features and config.features.enable_streaming ~= false

    -- Set stream parameter based on config
    request_body.stream = use_streaming and true or false

    -- Debug: Print request body
    if config and config.features and config.features.debug then
        DebugUtils.print("Ollama Request Body:", request_body, config)
        print("Streaming enabled:", use_streaming and "yes" or "no")
    end

    local requestBody = json.encode(request_body)
    local headers = {
        ["Content-Type"] = "application/json",
        ["Content-Length"] = tostring(#requestBody),
    }

    local base_url = config.base_url or defaults.base_url

    -- If streaming is enabled, return the background request function
    if use_streaming then
        -- Ollama uses NDJSON format (newline-delimited JSON), not SSE
        -- The stream_handler will detect and handle this format
        return self:backgroundRequest(base_url, headers, requestBody)
    end

    -- Non-streaming mode: use background request for non-blocking UI
    local debug_enabled = config and config.features and config.features.debug

    local response_parser = function(response)
        -- Debug: Print parsed response
        if debug_enabled then
            DebugUtils.print("Ollama Parsed Response:", response, config)
        end

        local parse_success, result, reasoning = ResponseParser:parseResponse(response, "ollama")
        if not parse_success then
            return false, "Error: " .. result
        end

        -- Return with reasoning metadata if available (R1 models use <think> tags)
        return true, result, reasoning
    end

    return {
        _background_fn = self:backgroundRequest(base_url, headers, requestBody),
        _non_streaming = true,
        _response_parser = response_parser,
    }
end

return OllamaHandler
