--[[--
NVIDIA API Handler (build.nvidia.com / NIM hosted catalog).

OpenAI-compatible chat wire at integrate.api.nvidia.com. Curated rather than
community: the catalog was probed live 2026-08-20 and only ids that actually
answered are shipped (see koassistant_model_lists.lua) — NVIDIA's public
/v1/models lists ~100 ids of which most 404 or accept the connection and never
respond, so "Fetch models" here hands users mostly-dead ids.

Reasoning: the nemotron-3 family honours `reasoning_effort` (probed — low ~140
chars of reasoning_content vs high ~540 on the same prompt, 3 samples each) and
disables cleanly on "none". Reasoning arrives as `reasoning_content`, the
DeepSeek-shaped field the shared OpenAI parser already extracts.

NO web search: the chat wire rejects any non-`function` tool outright, and the
Responses endpoint SILENTLY DISCARDS {type="web_search"} (probed — it 200s but
tool_choice="required" then reports "needs at least one tool definition", the
annotations come back empty and the model states it has no internet access).
Never grant a web-search capability here or the UI would badge searches that
never happened.

@module nvidia
]]

local OpenAICompatibleHandler = require("koassistant_api.openai_compatible")
local ModelConstraints = require("model_constraints")

local NvidiaHandler = OpenAICompatibleHandler:new()

function NvidiaHandler:getProviderName()
    return "NVIDIA"
end

function NvidiaHandler:getProviderKey()
    return "nvidia"
end

-- reasoning_content on the message (same shape DeepSeek/Groq use).
function NvidiaHandler:supportsReasoningExtraction()
    return true
end

function NvidiaHandler:customizeRequestBody(body, config)
    local model = body.model or ""
    if ModelConstraints.supportsCapability("nvidia", model, "reasoning") then
        local r = config.api_params and config.api_params.nvidia_reasoning
        if r and r.effort then
            body.reasoning_effort = r.effort
        end
    end
    return body
end

return NvidiaHandler
