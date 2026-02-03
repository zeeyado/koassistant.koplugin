--[[--
xAI (Grok) API Handler

OpenAI-compatible handler for xAI's Grok models.

Note: Web search requires xAI's Responses API (/v1/responses) which uses a
different format than Chat Completions. The Chat Completions API deprecated
web search on Feb 20, 2026 (returns 410 Gone). Web search is not currently
supported for xAI.

@module xai
]]

local OpenAICompatibleHandler = require("koassistant_api.openai_compatible")

local XAIHandler = OpenAICompatibleHandler:new()

function XAIHandler:getProviderName()
    return "xAI"
end

function XAIHandler:getProviderKey()
    return "xai"
end

return XAIHandler
