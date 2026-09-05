-- Conversation ids (B285 / issue #107, 2026-09-05).
--
-- A chat carries ONE id from its first message: MessageHistory mints
-- `conversation_id` at creation, a resumed chat takes its saved id, and the
-- save sites adopt it as the chat id (so the id on disk equals the id the
-- wire saw). Providers that route by conversation get it: OpenCode's
-- x-opencode-session header (required by OpenCode), OpenRouter's session_id,
-- OpenAI's prompt_cache_key. Every other host gets nothing.
--
-- Run: lua tests/run_tests.lua --unit

local function setupPaths()
    local info = debug.getinfo(1, "S")
    local script_path = info.source:match("@?(.*)")
    local unit_dir = script_path:match("(.+)/[^/]+$") or "."
    local tests_dir = unit_dir:match("(.+)/[^/]+$") or "."
    local plugin_dir = tests_dir:match("(.+)/[^/]+$") or "."

    package.path = table.concat({
        plugin_dir .. "/?.lua",
        plugin_dir .. "/koassistant_api/?.lua",
        tests_dir .. "/?.lua",
        tests_dir .. "/lib/?.lua",
        package.path,
    }, ";")
end

setupPaths()
require("mock_koreader")

local TestRunner = { passed = 0, failed = 0 }

function TestRunner.assert(condition, message)
    if condition then
        TestRunner.passed = TestRunner.passed + 1
    else
        TestRunner.failed = TestRunner.failed + 1
        print("  FAIL: " .. message)
    end
end

print("test_conversation_ids: one id per chat, from the first message to the wire")

local MessageHistory = require("koassistant_message_history")
local MESSAGES = { { role = "user", content = "hi" } }

local function cfg(provider, extra)
    local c = {
        provider = provider,
        model = "any-model",
        api_key = "test-key",
        system = { text = "sys" },
        api_params = {},
        features = { enable_streaming = false },
    }
    for k, v in pairs(extra or {}) do c[k] = v end
    return c
end

-- 1. Minted at birth, unique, chat-id shaped (time_random, like generateChatId)
do
    local a = MessageHistory:new(nil, nil)
    local b = MessageHistory:new(nil, nil)
    TestRunner.assert(type(a.conversation_id) == "string" and a.conversation_id:match("^%d+_%d+$"),
        "a fresh chat carries a conversation id of the chat-id shape")
    TestRunner.assert(a.conversation_id ~= b.conversation_id,
        "two fresh chats get different ids")
    TestRunner.assert(a.chat_id == nil,
        "chat_id stays nil until the chat is saved (presence still means 'on disk')")
end

-- 2. A resumed chat keeps its saved id
do
    local h = MessageHistory:fromSavedMessages(MESSAGES, "m", "1700000000_123456", nil, nil, nil)
    TestRunner.assert(h.conversation_id == "1700000000_123456",
        "fromSavedMessages adopts the saved chat id as the conversation id")
    TestRunner.assert(h.chat_id == "1700000000_123456", "and keeps chat_id as before")
    local legacy = MessageHistory:fromSavedMessages(MESSAGES, "m", nil, nil, nil, nil)
    TestRunner.assert(type(legacy.conversation_id) == "string",
        "a saved chat without an id still gets a conversation id")
end

-- 3. OpenCode: header present with an id, absent without one
do
    local H = require("opencode")
    local built = H:buildRequestBody(MESSAGES, cfg("opencode", { conversation_id = "17_1" }))
    TestRunner.assert(built.headers["x-opencode-session"] == "17_1",
        "opencode sends x-opencode-session = the conversation id")
    TestRunner.assert(built.headers["Authorization"] == "Bearer test-key", "opencode keeps Bearer auth")
    local bare = H:buildRequestBody(MESSAGES, cfg("opencode"))
    TestRunner.assert(bare.headers["x-opencode-session"] == nil,
        "no conversation (probe / fetch) = no session header")
    TestRunner.assert(built.url == "https://opencode.ai/zen/v1/chat/completions",
        "default base URL is the Zen endpoint, got " .. tostring(built.url))
end

-- 4. OpenCode Go is its own provider: own endpoint, same header, key falls back to Zen's
do
    local G = require("opencode_go")
    local built = G:buildRequestBody(MESSAGES, cfg("opencode_go", { conversation_id = "17_9" }))
    TestRunner.assert(built.headers["x-opencode-session"] == "17_9", "opencode_go sends the session header")
    local ConfigHelper = require("koassistant_config_helper")
    local merged = ConfigHelper:mergeWithDefaults({ provider = "opencode_go", features = {} })
    TestRunner.assert(merged.base_url == "https://opencode.ai/zen/go/v1/chat/completions",
        "opencode_go merges to the Go endpoint, got " .. tostring(merged.base_url))
    local zen = ConfigHelper:mergeWithDefaults({ provider = "opencode", features = {} })
    TestRunner.assert(zen.base_url == "https://opencode.ai/zen/v1/chat/completions",
        "opencode merges to the Zen endpoint, got " .. tostring(zen.base_url))

    local Base = require("koassistant_api.base")
    local saved = package.loaded["apikeys"]
    package.loaded["apikeys"] = { opencode = "zen-key" }
    local keys = Base.listApiKeys("opencode_go", nil)
    TestRunner.assert(keys[1] and keys[1].key == "zen-key", "a Go user with only the Zen key stored still has a key")
    package.loaded["apikeys"] = { opencode = "zen-key", opencode_go = "go-key" }
    keys = Base.listApiKeys("opencode_go", nil)
    TestRunner.assert(keys[1] and keys[1].key == "go-key" and keys[2] and keys[2].key == "zen-key",
        "an own Go key ranks first, the Zen key stays reachable")
    TestRunner.assert(#Base.listApiKeys("opencode", nil) == 1, "the Zen provider never borrows the Go key")
    package.loaded["apikeys"] = saved
end

-- 5. A custom provider pointed at opencode.ai gets the header too; other hosts never do
do
    local C = require("custom_openai")
    local oc = C:buildRequestBody(MESSAGES, cfg("custom_oc",
        { base_url = "https://opencode.ai/zen/go/v1/chat/completions", conversation_id = "17_2" }))
    TestRunner.assert(oc.headers["x-opencode-session"] == "17_2",
        "custom provider on opencode.ai sends the session header")
    local other = C:buildRequestBody(MESSAGES, cfg("custom_x",
        { base_url = "https://example.com/v1/chat/completions", conversation_id = "17_3" }))
    TestRunner.assert(other.headers["x-opencode-session"] == nil,
        "custom provider on another host sends no session header")
    local lookalike = C:buildRequestBody(MESSAGES, cfg("custom_y",
        { base_url = "https://opencode.ai.example.com/v1/chat/completions", conversation_id = "17_4" }))
    TestRunner.assert(lookalike.headers["x-opencode-session"] == nil,
        "a look-alike host is not opencode.ai")
end

-- 6. OpenRouter session_id + OpenAI prompt_cache_key ride the same id; absent without one
do
    local OR = require("openrouter")
    local b = OR:buildRequestBody(MESSAGES, cfg("openrouter", { conversation_id = "17_5" }))
    TestRunner.assert(b.body.session_id == "17_5", "openrouter sends session_id")
    TestRunner.assert(OR:buildRequestBody(MESSAGES, cfg("openrouter")).body.session_id == nil,
        "openrouter sends no session_id without a conversation")

    local OA = require("openai")
    local chat = OA:buildRequestBody(MESSAGES, cfg("openai", { model = "gpt-4o-mini", conversation_id = "17_6" }))
    TestRunner.assert(chat.body.prompt_cache_key == "17_6", "openai chat wire sends prompt_cache_key")
    local resp = OA:buildRequestBody(MESSAGES, cfg("openai",
        { model = "gpt-5.5", conversation_id = "17_7", enable_web_search = true }))
    TestRunner.assert(resp.body.prompt_cache_key == "17_7",
        "openai Responses wire sends prompt_cache_key too, url " .. tostring(resp.url))
    TestRunner.assert(OA:buildRequestBody(MESSAGES, cfg("openai", { model = "gpt-4o-mini" })).body.prompt_cache_key == nil,
        "openai sends no prompt_cache_key without a conversation")
end

-- 7. Hosts that documented no use for it get nothing (deliberate, maintainer 2026-09-04)
do
    for _idx, name in ipairs({ "deepseek", "groq", "cerebras" }) do
        local H = require(name)
        local b = H:buildRequestBody(MESSAGES, cfg(name, { conversation_id = "17_8" }))
        local leaked = b.headers["x-opencode-session"] or b.body.session_id or b.body.prompt_cache_key
        TestRunner.assert(leaked == nil, name .. " sends no conversation id in any form")
    end
end

-- 8. Every transport names the plugin
do
    local Base = require("koassistant_api.base")
    TestRunner.assert(type(Base.USER_AGENT) == "string" and Base.USER_AGENT:match("^KOAssistant/%S+$"),
        "USER_AGENT is KOAssistant/<version>, got " .. tostring(Base.USER_AGENT))
    local h = Base.withUserAgent({ ["Content-Type"] = "application/json" })
    TestRunner.assert(h["User-Agent"] == Base.USER_AGENT, "withUserAgent adds the header")
    local kept = Base.withUserAgent({ ["User-Agent"] = "Custom/1" })
    TestRunner.assert(kept["User-Agent"] == "Custom/1", "an explicit User-Agent (Codex) is kept")
    TestRunner.assert(Base.withUserAgent(nil)["User-Agent"] == Base.USER_AGENT, "nil headers become a table with the agent")
end

print(string.format("\n%d passed, %d failed", TestRunner.passed, TestRunner.failed))
return TestRunner.failed == 0
