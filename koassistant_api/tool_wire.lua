-- Provider-neutral tool-call wiring for the book-tool runner.
--
-- The runner (koassistant_book_tool_runner.lua) is provider-agnostic: it executes tools and
-- drives the agentic loop, but it must NOT know each provider's wire format. This registry holds,
-- per provider, how to serialize one completed tool turn back into the message history — i.e. echo
-- the model's tool-call turn, then append the tool results in the provider's native shape so the
-- provider's buildRequestBody can replay them.
--
-- The other two wire layers live where they naturally belong:
--   * tool DECLARATION  -> each provider's buildRequestBody reads the neutral config.tools
--                          ({ specs = {...}, mode = "auto" }) and emits its own format.
--   * tool-call DETECTION -> each provider's response_parser transformer emits the neutral shape
--                          { _tool_calls = true, calls = {{id,name,args}}, raw_assistant_turn = <native> }.
--
-- Adding a provider = register an adapter here + handle config.tools in its buildRequestBody
-- + detect tool calls in its response_parser transformer.

local json = require("json")

local ToolWire = { adapters = {} }

--- Serialize a tool result to a string, for providers whose tool-result content must be a string
--- (Anthropic, OpenAI). Gemini sends the raw result table instead. JSON keeps it lossless.
function ToolWire.stringifyResult(name, result)
    local ok, encoded = pcall(json.encode, result or {})
    if ok and type(encoded) == "string" then return encoded end
    return tostring(result)
end

-- Gemini: tool turns use parts; the model echo keeps its native parts, and each result becomes a
-- functionResponse part on a "tool" turn (gemini.lua maps the "tool" role to "user").
ToolWire.adapters.gemini = {
    --- @param messages table  the working message list (mutated in place)
    --- @param raw_assistant_turn table  the model's content as returned by the parser
    --- @param executed table  array of { call = {id,name,args}, result = <table> }
    appendToolTurn = function(messages, raw_assistant_turn, executed)
        if raw_assistant_turn and raw_assistant_turn.parts then
            table.insert(messages, {
                role = raw_assistant_turn.role or "model",
                parts = raw_assistant_turn.parts,
            })
        end
        local parts = {}
        for _, item in ipairs(executed or {}) do
            local response = { name = item.call.name, response = item.result }
            if item.call.id then response.id = item.call.id end
            table.insert(parts, { functionResponse = response })
        end
        if #parts > 0 then
            table.insert(messages, { role = "tool", parts = parts })
        end
    end,
}

-- Anthropic: tool turns use content blocks. The assistant echo keeps its native content array
-- (text + tool_use blocks); each result becomes a tool_result block on a user turn, with the
-- result stringified (Anthropic tool_result.content must be a string or content-block array).
ToolWire.adapters.anthropic = {
    appendToolTurn = function(messages, raw_assistant_turn, executed)
        if raw_assistant_turn and raw_assistant_turn.content then
            table.insert(messages, {
                role = raw_assistant_turn.role or "assistant",
                content = raw_assistant_turn.content,
            })
        end
        local blocks = {}
        for _, item in ipairs(executed or {}) do
            table.insert(blocks, {
                type = "tool_result",
                tool_use_id = item.call.id,
                content = ToolWire.stringifyResult(item.call.name, item.result),
            })
        end
        if #blocks > 0 then
            table.insert(messages, { role = "user", content = blocks })
        end
    end,
}

-- OpenAI Responses shape (R3, responses_api_plan.md): the parser hands us the raw
-- output[] array under raw_assistant_turn._responses_output. Echo reasoning /
-- function_call / message items verbatim (reasoning items must precede their
-- function calls — the builder requests their encrypted form for stateless
-- replay), then append one function_call_output item per result. The whole turn
-- goes into the history as ONE { _responses_items = {...} } entry that only
-- buildResponsesRequest consumes (endpoint routing is stable across a session).
local function appendResponsesToolTurn(messages, output, executed)
    local items = {}
    for _, item in ipairs(output) do
        if type(item) == "table" and (item.type == "reasoning"
                or item.type == "function_call" or item.type == "message") then
            table.insert(items, item)
        end
    end
    local answered = {}
    for _, ex in ipairs(executed or {}) do
        if ex.call.id then
            table.insert(items, {
                type = "function_call_output",
                call_id = ex.call.id,
                output = ToolWire.stringifyResult(ex.call.name, ex.result),
            })
            answered[ex.call.id] = true
        end
    end
    -- Every echoed function_call must receive an output (same rule as the chat
    -- shape below — the API rejects unanswered calls).
    for _, item in ipairs(output) do
        if type(item) == "table" and item.type == "function_call"
                and item.call_id and not answered[item.call_id] then
            table.insert(items, {
                type = "function_call_output",
                call_id = item.call_id,
                output = "{\"ok\":false,\"error\":\"tool call not handled\"}",
            })
        end
    end
    table.insert(messages, { _responses_items = items })
end

-- OpenAI: the assistant echo is the whole message object (carries tool_calls; content may be
-- nil/empty — buildRequestBody must preserve such turns), then one {role="tool"} message per
-- result, keyed by tool_call_id, with string content. reasoning_details rides along on the
-- echo: OpenRouter's reasoning backends (Anthropic thinking, Gemini thought signatures)
-- require it back verbatim on replayed tool-call turns.
ToolWire.adapters.openai = {
    appendToolTurn = function(messages, raw_assistant_turn, executed)
        if raw_assistant_turn and type(raw_assistant_turn._responses_output) == "table" then
            return appendResponsesToolTurn(messages, raw_assistant_turn._responses_output, executed)
        end
        local echoed_calls = nil
        if raw_assistant_turn and raw_assistant_turn.tool_calls then
            echoed_calls = raw_assistant_turn.tool_calls
            table.insert(messages, {
                role = raw_assistant_turn.role or "assistant",
                content = type(raw_assistant_turn.content) == "string"
                    and raw_assistant_turn.content or nil,
                tool_calls = echoed_calls,
                reasoning_details = raw_assistant_turn.reasoning_details,
            })
        end
        local answered = {}
        for _, item in ipairs(executed or {}) do
            table.insert(messages, {
                role = "tool",
                tool_call_id = item.call.id,
                content = ToolWire.stringifyResult(item.call.name, item.result),
            })
            if item.call.id then answered[item.call.id] = true end
        end
        -- Every echoed tool_call_id must receive a tool message (OpenAI rejects the request
        -- otherwise). Calls filtered upstream (e.g. web_search sentinels, malformed entries)
        -- get a stub result.
        if type(echoed_calls) == "table" then
            for _, tc in ipairs(echoed_calls) do
                if tc.id and not answered[tc.id] then
                    table.insert(messages, {
                        role = "tool",
                        tool_call_id = tc.id,
                        content = "{\"ok\":false,\"error\":\"tool call not handled\"}",
                    })
                end
            end
        end
    end,
}

-- OpenRouter speaks the OpenAI tool wire format verbatim (it normalizes across backends).
ToolWire.adapters.openrouter = ToolWire.adapters.openai

--- Whether a provider can wire tool turns (membership gate for the runner's shouldUse).
function ToolWire.hasAdapter(provider)
    return provider ~= nil and ToolWire.adapters[provider] ~= nil
end

--- Append one completed tool turn to the message history in the provider's native shape.
function ToolWire.appendToolTurn(provider, messages, raw_assistant_turn, executed)
    local adapter = ToolWire.adapters[provider]
    if adapter and adapter.appendToolTurn then
        adapter.appendToolTurn(messages, raw_assistant_turn, executed)
    end
end

return ToolWire
