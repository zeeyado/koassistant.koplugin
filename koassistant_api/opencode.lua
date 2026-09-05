--[[--
OpenCode Zen API Handler (curated, issue #107, 2026-09-05).

OpenCode sells two things under one account and one API key (both copied
from the Zen console at https://opencode.ai/auth):
  - OpenCode Zen: pay-as-you-go credit, https://opencode.ai/zen/v1/...
    (this handler, provider id "opencode")
  - OpenCode Go:  a monthly subscription with a usage allowance and its own
                  smaller catalog, https://opencode.ai/zen/go/v1/...
                  (opencode_go.lua, extends this handler; its key falls back
                  to the Zen key via BaseHandler.KEY_FALLBACKS)
Two providers on purpose (maintainer 2026-09-05): different billing, different
reach, different catalogs — the OpenAI / OpenAI Subscription precedent.

Wire facts (probed 2026-09-05 with a Zen key, both endpoints):
  - The OpenAI chat door (/chat/completions) serves the open-weight models
    (GLM, DeepSeek, Kimi, MiniMax, Qwen, MiMo, grok...). GPT models answer
    only on /responses and Claude/Gemini only on /messages, each a 500
    ("Internal server error") on the chat door. Those doors are v2 work
    (docs/prompt_caching_plan.md D5); "Fetch models" imports their ids,
    which then fail politely.
  - A Zen key opens the Go endpoint too (kimi-k2.6 answered on
    /zen/go/v1 without a Go subscription).
  - max_tokens 16384 accepted on glm-5.3-flash and deepseek-v4-flash.
  - Responses carry usage.prompt_tokens_details.cached_tokens and a `cost`
    field; the OpenAI-shaped parser reads the rest (reasoning_content /
    reasoning are both emitted, depending on the backend).

OpenCode REQUIRES two things of every client (their Go docs, and an email
to the #107 reporter): a self-identifying User-Agent (BaseHandler adds
"KOAssistant/<version>" on every transport) and the `x-opencode-session`
header carrying one id per conversation, the same on every request of that
conversation, follow-ups included. That id is the chat's conversation id
(koassistant_message_history.lua mints it when the chat starts; the send
sites stamp it on the request config as `conversation_id`).

@module opencode
]]

local OpenAICompatibleHandler = require("koassistant_api.openai_compatible")
local ModelConstraints = require("model_constraints")

local Handler = OpenAICompatibleHandler:new()

function Handler:getProviderName()
    return "OpenCode Zen"
end

function Handler:getProviderKey()
    return "opencode"
end

-- Shared OpenAI-shaped transformer (incl. tool-call extraction), like the
-- rest of the community set.
function Handler:getResponseParserKey()
    return "openai"
end

-- Reasoning rides reasoning_effort (probed 2026-09-05 on every seed model);
-- the resolver emits api_params.opencode_reasoning = { effort } for on AND
-- for the profile's off_option ("none") where the model can disable.
function Handler:customizeRequestBody(body, config)
    local model = body.model or ""
    if ModelConstraints.supportsCapability(self:getProviderKey(), model, "reasoning") then
        local r = config.api_params and config.api_params.opencode_reasoning
        if r and r.effort then
            body.reasoning_effort = r.effort
        end
    end
    return body
end

--- The conversation header OpenCode requires. Absent only when no
--- conversation exists (the Test-provider probe, the models fetch).
function Handler:customizeHeaders(headers, config)
    local cid = config and config.conversation_id
    if type(cid) == "string" and cid ~= "" then
        headers["x-opencode-session"] = cid
    end
    return headers
end

return Handler
