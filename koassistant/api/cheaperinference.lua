--[[--
Cheaper Inference API Handler (community set — M1, model_management_strategy.md
"End-state REVISION 2"). Plain OpenAI-compatible chat wire; capabilities come
from family fallbacks and the derived layer ("Test this provider"), not
curated lists.

@module cheaperinference
]]

local OpenAICompatibleHandler = require("koassistant.api.openai_compatible")

local Handler = OpenAICompatibleHandler:new()

function Handler:getProviderName()
    return "Cheaper Inference"
end

function Handler:getProviderKey()
    return "cheaperinference"
end

-- Shared OpenAI-shaped transformer (incl. tool-call extraction) — same parser
-- the custom-provider path uses; no per-provider parser for the community set.
function Handler:getResponseParserKey()
    return "openai"
end

return Handler
