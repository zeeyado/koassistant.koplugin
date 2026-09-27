--[[--
A2Agent API Handler (curated, issue #108).

A2Agent (https://a2agent.me) is a paid gateway to DeepSeek, GLM, Kimi, Qwen
and MiniMax models behind one key. This handler rides its OpenAI chat door,
https://api.a2agent.me/v1/chat/completions; the Anthropic and Gemini doors
it also offers are not used.

Reasoning wire (probed 2026-09-27 with a donated key: the model_audit
battery plus a check that each control changes the reply, since this
gateway answers 200 to values some backends ignore):
  - reasoning_effort sets the level where the backend honors it (the Qwen
    ids, kimi-k3, deepseek-v4-pro, deepseek-v4.1-flash, GLM low/high/max).
  - "none" does NOT turn reasoning off on deepseek-v4-flash or MiniMax-M3
    (any value keeps them thinking); thinking = {type="disabled"} turns it
    off on every backend that can, so that is the one off switch.
  - GLM always thinks and refuses every disable (its profile never
    resolves to off).

@module a2agent
]]

local OpenAICompatibleHandler = require("koassistant_api.openai_compatible")
local ModelConstraints = require("model_constraints")

local Handler = OpenAICompatibleHandler:new()

function Handler:getProviderName()
    return "A2Agent"
end

function Handler:getProviderKey()
    return "a2agent"
end

-- Shared OpenAI-shaped transformer (incl. tool-call extraction and <think>
-- tags, which MiniMax-M3 uses for its reasoning).
function Handler:getResponseParserKey()
    return "openai"
end

-- The resolver emits api_params.a2agent_reasoning: { effort = X } to reason
-- at a level, { enabled = true } on a binary model, { enabled = false } off.
function Handler:customizeRequestBody(body, config)
    local model = body.model or ""
    if not ModelConstraints.supportsCapability(self:getProviderKey(), model, "reasoning") then
        return body
    end
    local r = config.api_params and config.api_params.a2agent_reasoning
    if type(r) == "table" then
        if r.enabled == false then
            body.thinking = { type = "disabled" }
        elseif r.effort then
            body.reasoning_effort = r.effort
        elseif r.enabled == true then
            body.thinking = { type = "enabled" }
        end
    end
    return body
end

return Handler
