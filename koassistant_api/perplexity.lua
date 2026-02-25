--[[--
Perplexity API Handler

OpenAI-compatible handler for Perplexity Sonar models.
Web search is always-on — every response is web-grounded with citations.
Citations are appended as clickable footnotes by the response parser.

Endpoint: https://api.perplexity.ai/chat/completions
Docs: https://docs.perplexity.ai/

@module perplexity
]]

local OpenAICompatibleHandler = require("koassistant_api.openai_compatible")

local PerplexityHandler = OpenAICompatibleHandler:new()

function PerplexityHandler:getProviderName()
    return "Perplexity"
end

function PerplexityHandler:getProviderKey()
    return "perplexity"
end

-- Perplexity requires strict user/assistant message alternation.
-- Merge consecutive same-role messages to avoid 400 errors
-- (e.g., context message + user question are both role="user").
function PerplexityHandler:customizeRequestBody(body, config)
    local messages = body.messages
    if messages and #messages > 1 then
        local merged = { messages[1] }
        for i = 2, #messages do
            local prev = merged[#merged]
            if messages[i].role == prev.role then
                prev.content = prev.content .. "\n\n" .. messages[i].content
            else
                table.insert(merged, messages[i])
            end
        end
        body.messages = merged
    end
    return body
end

return PerplexityHandler
