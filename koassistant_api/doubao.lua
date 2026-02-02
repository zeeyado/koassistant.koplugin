--[[--
Doubao (ByteDance) API Handler

Pure OpenAI-compatible handler with no provider-specific customization.

@module doubao
]]

local OpenAICompatibleHandler = require("koassistant_api.openai_compatible")

local DoubaoHandler = OpenAICompatibleHandler:new()

function DoubaoHandler:getProviderName()
    return "Doubao"
end

function DoubaoHandler:getProviderKey()
    return "doubao"
end

return DoubaoHandler
