-- Provider-neutral tool-call wiring for the book-tool runner.
--
-- The runner (koassistant_gemini_tool_runner.lua) is provider-agnostic: it executes tools and
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

local ToolWire = { adapters = {} }

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
