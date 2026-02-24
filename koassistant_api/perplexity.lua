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

return PerplexityHandler
