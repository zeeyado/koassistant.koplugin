--[[--
OpenCode Go API Handler (curated, issue #107, 2026-09-05).

The OpenCode subscription plan: same key mechanism and wire as OpenCode Zen
(opencode.lua, which this extends), its own endpoint and its own smaller
catalog (/zen/go/v1/models, public). Its own key entry `opencode_go` (one
key per provider, like every other provider; the same string may sit under
both names — maintainer 2026-09-05, no hidden fallback).
Battery facts per model live in model_constraints.lua (capabilities /
reasoning_profiles .opencode_go), probed on THIS endpoint.

@module opencode_go
]]

local OpencodeHandler = require("koassistant_api.opencode")

local Handler = OpencodeHandler:new()

function Handler:getProviderName()
    return "OpenCode Go"
end

function Handler:getProviderKey()
    return "opencode_go"
end

return Handler
