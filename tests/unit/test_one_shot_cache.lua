-- A request whose answer is saved as a result sends no prompt-cache mark for
-- its messages (B728).
--
-- The mark makes the provider write the whole prompt to its cache, billed above
-- the input price (Anthropic: 1.25 times). A chat reads that cache back on its
-- next turn; an X-Ray, a summary or any other saved result has no next turn, so
-- the write bought nothing: 18% of a whole-book X-Ray, measured 2026-11-18.
--
-- What is checked: the rule (Dialogs._markOneShot), the hand-off from the real
-- request bake to both handlers that send a mark, that a chat keeps its mark,
-- that the mark does not outlive its request, that the one send function of an
-- action calls the rule, and that every handler which sends a mark reads it.
--
-- Run: lua tests/unit/test_one_shot_cache.lua  (or lua tests/run_tests.lua --unit)

local function setupPaths()
    local info = debug.getinfo(1, "S")
    local script_path = info.source:match("@?(.*)")
    local unit_dir = script_path:match("(.+)/[^/]+$") or "."
    local tests_dir = unit_dir:match("(.+)/[^/]+$") or "."
    local plugin_dir = tests_dir:match("(.+)/[^/]+$") or "."
    package.path = table.concat({
        plugin_dir .. "/?.lua",
        plugin_dir .. "/koassistant/api/?.lua",
        tests_dir .. "/?.lua",
        tests_dir .. "/lib/?.lua",
        package.path,
    }, ";")
    return plugin_dir
end
local PLUGIN_DIR = setupPaths()
require("mock_koreader")

local Dialogs = require("koassistant.ui.dialogs")
local AnthropicHandler = require("koassistant.api.anthropic")
local OpenRouterHandler = require("koassistant.api.openrouter")
local TestRunner = require("test_runner"):new()

print("")
print(string.rep("=", 50))
print("  Unit Tests: no cache mark on a one-shot request")
print(string.rep("=", 50))

local MESSAGES = { { role = "user", content = "the book's text, then the task" } }

-- The request config as the dispatch bakes it
local function bake(provider, model, features, action)
    local cfg = {
        provider = provider, model = model,
        provider_settings = {}, features = features or {}, api_key = "test",
    }
    Dialogs._buildUnifiedRequestConfig(cfg, nil, action, nil)
    return cfg
end

local XRAY_LIKE = { id = "saved_result", use_response_caching = true, enable_web_search = false }

TestRunner:test("the rule: marked only when the answer is saved and web search is off", function()
    local cfg = { system = { text = "s" }, features = {} }
    TestRunner:assertEqual(Dialogs._markOneShot(cfg, "/books/a.epub"), true, "a saved result: marked")
    TestRunner:assertEqual(cfg.system.one_shot, true, "the mark is on the request's system table")

    cfg = { system = { text = "s" }, features = {} }
    TestRunner:assertEqual(Dialogs._markOneShot(cfg, nil), false, "nothing saved (a chat): not marked")
    TestRunner:assertEqual(cfg.system.one_shot, nil)
    TestRunner:assertEqual(Dialogs._markOneShot(cfg, false), false, "false: not marked")
    TestRunner:assertEqual(cfg.system.one_shot, nil)

    cfg = { system = { text = "s" }, features = {}, enable_web_search = true }
    TestRunner:assertEqual(Dialogs._markOneShot(cfg, true), false, "web search on for this request: not marked")
    TestRunner:assertEqual(cfg.system.one_shot, nil)

    cfg = { system = { text = "s" }, features = { enable_web_search = true } }
    TestRunner:assertEqual(Dialogs._markOneShot(cfg, true), false,
        "the request follows the global web setting, which is on: not marked")

    cfg = { system = { text = "s" }, features = { enable_web_search = true }, enable_web_search = false }
    TestRunner:assertEqual(Dialogs._markOneShot(cfg, true), true,
        "the action's own web off beats the global on: marked")

    TestRunner:assertEqual(Dialogs._markOneShot({ features = {} }, true), false, "no system table: nothing to mark")
    TestRunner:assertEqual(Dialogs._markOneShot(nil, true), false, "no config: no error")
end)

TestRunner:test("Anthropic: a one-shot request has no top-level mark and keeps the system block's own", function()
    local cfg = bake("anthropic", "claude-sonnet-5-5", {}, XRAY_LIKE)
    TestRunner:assertEqual(cfg.system.enable_caching, true, "the bake asks for caching on Anthropic")

    local chat = AnthropicHandler:buildRequestBody(MESSAGES, cfg)
    TestRunner:assertEqual(chat.body.cache_control and chat.body.cache_control.type, "ephemeral",
        "before the rule runs the request carries the top-level mark (what a chat sends)")

    TestRunner:assertEqual(Dialogs._markOneShot(cfg, "/books/a.epub"), true, "the dispatch marks it")
    local one = AnthropicHandler:buildRequestBody(MESSAGES, cfg)
    TestRunner:assertEqual(one.body.cache_control, nil, "one-shot: no top-level mark")
    local block = one.body.system and one.body.system[1]
    TestRunner:assertTrue(block ~= nil, "the system block is sent")
    TestRunner:assertEqual(block.cache_control and block.cache_control.type, "ephemeral",
        "the system block keeps its own mark (a chain of steps reads it back)")
    TestRunner:assertEqual(one.body.one_shot, nil, "the flag itself is never sent")
    TestRunner:assertEqual(block.one_shot, nil, "nor inside the system block")
    TestRunner:assertEqual(#one.body.messages, 1, "the messages are untouched")
end)

TestRunner:test("OpenRouter: a one-shot request has no mark, a chat keeps it", function()
    local cfg = bake("openrouter", "anthropic/claude-sonnet-5.5", {}, XRAY_LIKE)
    local chat = OpenRouterHandler:buildRequestBody(MESSAGES, cfg)
    TestRunner:assertEqual(chat.body.cache_control and chat.body.cache_control.type, "ephemeral",
        "a chat carries the auto-advancing mark")
    Dialogs._markOneShot(cfg, "/books/a.epub")
    local one = OpenRouterHandler:buildRequestBody(MESSAGES, cfg)
    TestRunner:assertEqual(one.body.cache_control, nil, "one-shot: no mark")
    TestRunner:assertEqual(one.body.one_shot, nil, "the flag itself is never sent")
end)

TestRunner:test("the mark ends with its request: the next bake starts clean", function()
    local cfg = bake("anthropic", "claude-sonnet-5-5", {}, XRAY_LIKE)
    Dialogs._markOneShot(cfg, true)
    TestRunner:assertEqual(cfg.system.one_shot, true)
    -- the same config baked for another request (a chat that follows)
    Dialogs._buildUnifiedRequestConfig(cfg, nil, nil, nil)
    TestRunner:assertEqual(cfg.system.one_shot, nil, "a new system table per request")
    local body = AnthropicHandler:buildRequestBody(MESSAGES, cfg).body
    TestRunner:assertEqual(body.cache_control and body.cache_control.type, "ephemeral",
        "the chat that follows carries the mark again")
end)

local function readFile(rel)
    local f = assert(io.open(PLUGIN_DIR .. "/" .. rel, "r"))
    local s = f:read("*a")
    f:close()
    return s
end

TestRunner:test("the one send function of an action applies the rule before it sends", function()
    local src = readFile("koassistant/ui/dialogs.lua")
    local from = src:find("local function sendQuery()", 1, true)
    TestRunner:assertTrue(from ~= nil, "sendQuery found")
    local body = src:sub(from, (src:find("\n    end\n", from, true) or from) + 8)
    local mark = body:find("markOneShot(temp_config, cache_enabled)", 1, true)
    local send = body:find("BookToolRunner.queryWith(", 1, true)
    TestRunner:assertTrue(mark ~= nil, "sendQuery calls the rule with the request's config and whether it saves")
    TestRunner:assertTrue(send ~= nil, "sendQuery sends through the funnel")
    TestRunner:assertEqual(mark ~= nil and send ~= nil and mark < send, true, "the rule runs before the send")
    -- and every send of handlePredefinedPrompt goes through sendQuery: the
    -- function holds one queryWith call for the action's own request
    local count = 0
    for _ in body:gmatch("BookToolRunner%.queryWith%(") do count = count + 1 end
    TestRunner:assertEqual(count, 1, "one send in sendQuery")
end)

TestRunner:test("every handler that sends a mark for the messages reads the one-shot flag", function()
    local lfs = require("lfs")
    local dir = PLUGIN_DIR .. "/koassistant/api"
    local senders = {}
    for name in lfs.dir(dir) do
        if name:match("%.lua$") then
            local src = readFile("koassistant/api/" .. name)
            -- a mark on the request body itself (not the system block's own)
            if src:find("body%.cache_control%s*=") then
                senders[#senders + 1] = name
                TestRunner:assertTrue(src:find("one_shot", 1, true) ~= nil,
                    name .. " sends a top-level cache mark and must leave it off a one-shot request")
            end
        end
    end
    table.sort(senders)
    TestRunner:assertEqual(table.concat(senders, " "), "anthropic_request.lua openrouter.lua",
        "the handlers that send a top-level mark (a new one joins this list and reads the flag)")
end)

return TestRunner:summary()
