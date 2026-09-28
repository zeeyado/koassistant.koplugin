-- Perplexity on the Agent API (B078): the request koassistant_api/perplexity.lua
-- builds for POST /v1/agent. The Sonar chat wire retired 2026-09-27; the wire
-- facts asserted here were probed live that day (docs/backlog_v0.22.md B078).
--
-- Run: lua tests/unit/test_perplexity_agent.lua

local function setupPaths()
    local info = debug.getinfo(1, "S")
    local script_path = info.source:match("@?(.*)")
    local unit_dir = script_path:match("(.+)/[^/]+$") or "."
    local tests_dir = unit_dir:match("(.+)/[^/]+$") or "."
    local plugin_dir = tests_dir:match("(.+)/[^/]+$") or "."

    package.path = table.concat({
        plugin_dir .. "/?.lua",
        tests_dir .. "/?.lua",
        tests_dir .. "/lib/?.lua",
        package.path,
    }, ";")
end

setupPaths()
require("mock_koreader")

local json = require("json")
local Handler = require("koassistant_api.perplexity")
local TestRunner = require("test_runner"):new()

print("")
print(string.rep("=", 50))
print("  Unit Tests: Perplexity Agent API request")
print(string.rep("=", 50))

local HISTORY = {
    { role = "user", content = "[Context] a book" },
    { role = "user", content = "Who is the narrator?" },
}

local function build(model, features, extra)
    local config = {
        provider = "perplexity", model = model, api_key = "k",
        system = { text = "sys" }, api_params = {}, features = features or {},
    }
    for k, v in pairs(extra or {}) do config[k] = v end
    return Handler:buildRequestBody(HISTORY, config)
end

TestRunner:test("a preset rides as preset, the system prompt as an input item", function()
    local built = build("fast")
    local body = built.body
    TestRunner:assertEqual(body.preset, "fast", "preset")
    TestRunner:assertEqual(body.model, nil, "no model beside the preset")
    TestRunner:assertEqual(body.instructions, nil, "instructions would replace the preset's citation prompt")
    TestRunner:assertEqual(body.input[1].type, "message", "typed input item")
    TestRunner:assertEqual(body.input[1].role, "system", "system item first")
    TestRunner:assertEqual(body.input[1].content, "sys", "system text")
    TestRunner:assertEqual(body.messages, nil, "no chat-wire messages")
    TestRunner:assertEqual(body.store, false, "never retained server-side")
    TestRunner:assertTrue(type(body.max_output_tokens) == "number", "max_output_tokens")
    TestRunner:assertEqual(body.max_tokens, nil, "no chat-wire max_tokens")
    TestRunner:assertEqual(built.url, "https://api.perplexity.ai/v1/agent", "agent endpoint")
    TestRunner:assertEqual(built.parser, "perplexity", "agent parser")
end)

TestRunner:test("no model or an empty one falls to the default preset", function()
    TestRunner:assertEqual(build(nil).body.preset, "fast", "nil")
    TestRunner:assertEqual(build("").body.preset, "fast", "empty string")
end)

TestRunner:test("each turn stays its own item (consecutive user turns are accepted)", function()
    local body = build("fast").body
    TestRunner:assertEqual(#body.input, 3, "system + two user items")
    TestRunner:assertEqual(body.input[2].content, "[Context] a book", "context item")
    TestRunner:assertEqual(body.input[3].content, "Who is the narrator?", "question item")
    local replay = Handler:buildRequestBody({
        { role = "user", content = "q1" }, { role = "assistant", content = "a1" }, { role = "user", content = "q2" },
    }, { model = "fast", api_key = "k", features = {} }).body
    TestRunner:assertEqual(replay.input[2].role, "assistant", "assistant turn replayed")
end)

TestRunner:test("a provider/model id rides with the search preset while web search is on", function()
    local built = build("perplexity/sonar")
    local body = built.body
    TestRunner:assertEqual(body.model, "perplexity/sonar", "the chosen model")
    TestRunner:assertEqual(body.preset, Handler.SEARCH_PRESET, "the preset searches and cites for it")
    TestRunner:assertEqual(Handler.SEARCH_PRESET, "fast", "Perplexity's own mapping for Sonar and Sonar Pro")
    TestRunner:assertEqual(body.tools, nil, "standard effort: the preset's own search")
    TestRunner:assertEqual(built.adjustments.preset and built.adjustments.preset.to, "fast", "adjustment logged")
    local thorough = build("anthropic/claude-haiku-4-5", { web_search_effort = "thorough" }).body
    TestRunner:assertEqual(thorough.preset, "fast", "any catalog model")
    TestRunner:assertEqual(thorough.tools and thorough.tools[1].search_context_size, "high",
        "the effort dial still reaches the search")
end)

TestRunner:test("retired Sonar ids map to Perplexity's suggested presets", function()
    local cases = { sonar = "fast", ["sonar-pro"] = "fast", ["sonar-reasoning-pro"] = "low",
        ["sonar-deep-research"] = "high" }
    for old_id, preset in pairs(cases) do
        local built = build(old_id)
        TestRunner:assertEqual(built.body.preset, preset, old_id)
        TestRunner:assertEqual(built.adjustments.retired_model and built.adjustments.retired_model.to, preset,
            old_id .. " adjustment logged")
    end
end)

TestRunner:test("web search off leaves the preset for the direct Sonar model, without tools", function()
    local built = build("low", { enable_web_search = false, web_search_effort = "thorough" })
    TestRunner:assertEqual(built.body.preset, nil, "a preset always searches")
    TestRunner:assertEqual(built.body.model, Handler.WEB_OFF_MODEL, "web-off model")
    TestRunner:assertEqual(built.body.tools, nil, "no tool")
    TestRunner:assertEqual(built.adjustments.web_off and built.adjustments.web_off.from, "low", "adjustment logged")
    -- The per-request decision wins over the global in both directions
    TestRunner:assertEqual(build("low", { enable_web_search = true }, { enable_web_search = false }).body.model,
        Handler.WEB_OFF_MODEL, "chip off beats global on")
    TestRunner:assertEqual(build("low", { enable_web_search = false }, { enable_web_search = true }).body.preset,
        "low", "chip on beats global off")
    -- Untouched: Perplexity's native default, search on
    TestRunner:assertEqual(build("low").body.preset, "low", "untouched global searches")
    local direct = build("perplexity/sonar", { enable_web_search = false }).body
    TestRunner:assertEqual(direct.model, "perplexity/sonar", "a direct model stays")
    TestRunner:assertEqual(direct.preset, nil, "and goes alone, without the search preset")
    TestRunner:assertEqual(direct.tools, nil, "and without a tool")
end)

TestRunner:test("a preset gets no temperature, a direct model keeps it and its constraints", function()
    TestRunner:assertEqual(build("low").body.temperature, nil, "the low preset refuses one")
    local ModelOverrides = require("koassistant_model_overrides")
    local saved = ModelOverrides._user
    ModelOverrides._setUserForTests({ constraints = { perplexity = { ["perplexity/sonar"] = { temperature = 0.3 } } } })
    local direct = build("perplexity/sonar").body.temperature
    local web_off = build("fast", { enable_web_search = false }).body.temperature
    ModelOverrides._setUserForTests(saved)
    TestRunner:assertEqual(direct, 0.3, "custom_models.lua constraint reaches a direct model")
    TestRunner:assertEqual(web_off, 0.3, "and the web-off Sonar request")
end)

TestRunner:test("a direct model that refuses sampling gets no temperature, with or without the preset", function()
    local ModelConstraints = require("model_constraints")
    for _idx, model in ipairs({ "anthropic/claude-opus-4-7", "anthropic/claude-opus-5-5",
            "anthropic/claude-fable-5-1", "anthropic/claude-sonnet-5", "openai/gpt-6-astra" }) do
        TestRunner:assertEqual(build(model).body.temperature, nil, model)
        TestRunner:assertEqual(build(model, { enable_web_search = false }).body.temperature, nil, model .. " alone")
        TestRunner:assertEqual(ModelConstraints.temperatureSupport("perplexity", model), "rejected",
            model .. " reads as rejected in the UI")
    end
    TestRunner:assertEqual(build("anthropic/claude-opus-4-6").body.temperature, 0.7, "an older Claude keeps it")
end)

TestRunner:test("models the search preset breaks: the lowest effort on top, or alone with the tool", function()
    local gemini = build("google/gemini-3.1-pro-preview").body
    TestRunner:assertEqual(gemini.preset, "fast", "rides the preset")
    TestRunner:assertEqual(gemini.reasoning and gemini.reasoning.effort, "low", "the preset's effort none is refused")
    TestRunner:assertEqual(build("openai/gpt-6-luna").body.reasoning, nil, "others keep the preset's effort")
    TestRunner:assertEqual(build("google/gemini-3.1-pro-preview", { enable_web_search = false }).body.reasoning, nil,
        "alone, nothing to override")
    local grok = build("xai/grok-4.20-reasoning").body
    TestRunner:assertEqual(grok.model, "xai/grok-4.20-reasoning", "the chosen model")
    TestRunner:assertEqual(grok.preset, nil, "refuses the preset whatever effort rides on it")
    TestRunner:assertEqual(grok.reasoning, nil, "and no reasoning setting")
    TestRunner:assertEqual(grok.tools and grok.tools[1].type, "web_search", "alone it searches with the tool")
    TestRunner:assertEqual(build("xai/grok-4.20-non-reasoning").body.preset, "fast", "its sibling rides the preset")
end)

TestRunner:test("a base URL override for the old chat wire points at the agent endpoint", function()
    TestRunner:assertEqual(build("fast", nil, { base_url = "https://api.perplexity.ai/chat/completions" }).url,
        "https://api.perplexity.ai/v1/agent", "rewritten")
    TestRunner:assertEqual(build("fast", nil, { base_url = "https://proxy.example/v1/agent" }).url,
        "https://proxy.example/v1/agent", "an agent URL is kept")
end)

TestRunner:test("the streamed request adds stream=true to the same body", function()
    local own = rawget(Handler, "backgroundRequest")
    local sent_url, sent_headers, sent_body
    rawset(Handler, "backgroundRequest", function(_self, url, headers, body)
        sent_url, sent_headers, sent_body = url, headers, body
        return function() end
    end)
    local ok, err = pcall(Handler.query, Handler, HISTORY, {
        provider = "perplexity", model = "fast", api_key = "k", system = { text = "sys" },
        api_params = {}, features = { enable_streaming = true },
    })
    rawset(Handler, "backgroundRequest", own)
    TestRunner:assertTrue(ok, tostring(err))
    local body = json.decode(sent_body)
    TestRunner:assertEqual(body.stream, true, "stream flag")
    TestRunner:assertEqual(body.preset, "fast", "same body")
    TestRunner:assertEqual(sent_headers["Accept"], "text/event-stream", "SSE accept header")
    TestRunner:assertEqual(sent_url, "https://api.perplexity.ai/v1/agent", "agent endpoint")
end)

return TestRunner:summary()
