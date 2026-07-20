-- Unit tests for the OpenAI Responses API path (responses_api_plan.md R1+R2):
-- routing decision + request builder in koassistant_api/openai.lua, the
-- openai_responses transformer in response_parser.lua, and the streaming
-- helpers in stream_handler.lua. No API calls — mock data only.

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

local OpenAIHandler = require("koassistant_api.openai")
local ResponseParser = require("koassistant_api.response_parser")
local StreamHandler = require("stream_handler")
local DebugUtils = require("koassistant_debug_utils")
local TestRunner = require("test_runner"):new()

print("")
print(string.rep("=", 50))
print("  Unit Tests: OpenAI Responses API")
print(string.rep("=", 50))

local HISTORY = {
    { role = "user", content = "What's new with capybaras?" },
}

local function webConfig(overrides)
    local config = {
        model = "gpt-5.5",
        api_key = "test",
        system = { text = "You are helpful." },
        features = { enable_web_search = true },
    }
    for k, v in pairs(overrides or {}) do config[k] = v end
    return config
end

--------------------------------------------------------------------------------
print("\n  [Routing: when the Responses endpoint is used]")
--------------------------------------------------------------------------------

TestRunner:test("web search on + capable model routes to /responses", function()
    local result = OpenAIHandler:buildRequestBody(HISTORY, webConfig())
    TestRunner:assertEqual(result.parser, "openai_responses", "parser key set")
    TestRunner:assertTrue(result.url:find("/responses", 1, true) ~= nil, "URL is the responses endpoint")
    TestRunner:assertTrue(result.url:find("/chat/completions", 1, true) == nil, "chat completions gone from URL")
    TestRunner:assertTrue(result.body.input ~= nil, "body uses input items")
    TestRunner:assertTrue(result.body.messages == nil, "body has no messages array")
end)

TestRunner:test("web search off stays on Chat Completions", function()
    local result = OpenAIHandler:buildRequestBody(HISTORY, webConfig({
        features = { enable_web_search = false },
    }))
    TestRunner:assertTrue(result.parser == nil, "no parser override")
    TestRunner:assertTrue(result.body.messages ~= nil, "chat body")
end)

TestRunner:test("per-action force-off beats global on (Web layering)", function()
    local config = webConfig()
    config.enable_web_search = false
    local result = OpenAIHandler:buildRequestBody(HISTORY, config)
    TestRunner:assertTrue(result.body.messages ~= nil, "chat body when action pins web off")
end)

TestRunner:test("per-action force-on works without the global", function()
    local config = webConfig({ features = {} })
    config.enable_web_search = true
    local result = OpenAIHandler:buildRequestBody(HISTORY, config)
    TestRunner:assertEqual(result.parser, "openai_responses", "routes on action override")
end)

TestRunner:test("book-tool sessions stay on Chat Completions (no Responses adapter yet)", function()
    local config = webConfig()
    config.tools = { specs = { { name = "search_book", description = "d", parameters = { type = "object" } } } }
    local result = OpenAIHandler:buildRequestBody(HISTORY, config)
    TestRunner:assertTrue(result.body.messages ~= nil, "chat body when config.tools present")
end)

TestRunner:test("non-capable model stays on Chat Completions", function()
    local result = OpenAIHandler:buildRequestBody(HISTORY, webConfig({ model = "gpt-4o" }))
    TestRunner:assertTrue(result.body.messages ~= nil, "chat body for unlisted model")
end)

TestRunner:test("prefix match covers -mini variants", function()
    local result = OpenAIHandler:buildRequestBody(HISTORY, webConfig({ model = "gpt-5.4-mini" }))
    TestRunner:assertEqual(result.parser, "openai_responses", "gpt-5.4-mini routes")
end)

--------------------------------------------------------------------------------
print("\n  [Request builder: Responses body shape]")
--------------------------------------------------------------------------------

TestRunner:test("system prompt rides as instructions, history as role items", function()
    local result = OpenAIHandler:buildRequestBody({
        { role = "system", content = "sneaky inline system" },
        { role = "user", content = "hi" },
        { role = "assistant", content = "hello" },
        { role = "user", content = "more" },
    }, webConfig())
    local body = result.body
    TestRunner:assertEqual(body.instructions, "You are helpful.", "instructions from config.system")
    TestRunner:assertEqual(#body.input, 3, "system role filtered from input")
    TestRunner:assertEqual(body.input[1].role, "user", "user role kept")
    TestRunner:assertEqual(body.input[2].role, "assistant", "assistant role kept")
end)

TestRunner:test("store=false always (stateless, no server-side retention)", function()
    local result = OpenAIHandler:buildRequestBody(HISTORY, webConfig())
    TestRunner:assertEqual(result.body.store, false, "store must be false")
end)

TestRunner:test("web_search tool declared; standard effort omits search_context_size", function()
    local result = OpenAIHandler:buildRequestBody(HISTORY, webConfig())
    TestRunner:assertEqual(result.body.tools[1].type, "web_search", "web_search tool present")
    TestRunner:assertEqual(result.body.tools[1].search_context_size, nil, "standard = API default")
end)

TestRunner:test("effort dial maps light/thorough to search_context_size", function()
    local light = OpenAIHandler:buildRequestBody(HISTORY, webConfig({
        features = { enable_web_search = true, web_search_effort = "light" },
    }))
    TestRunner:assertEqual(light.body.tools[1].search_context_size, "low", "light -> low")
    local thorough = OpenAIHandler:buildRequestBody(HISTORY, webConfig({
        features = { enable_web_search = true, web_search_effort = "thorough" },
    }))
    TestRunner:assertEqual(thorough.body.tools[1].search_context_size, "high", "thorough -> high")
end)

TestRunner:test("max_output_tokens gets the reasoning headroom bump", function()
    local result = OpenAIHandler:buildRequestBody(HISTORY, webConfig())
    TestRunner:assertEqual(result.body.max_output_tokens, 32768, "32K default for reasoning models")
    TestRunner:assertEqual(result.body.max_tokens, nil, "no chat-style max_tokens")
    TestRunner:assertEqual(result.body.max_completion_tokens, nil, "no max_completion_tokens")
end)

TestRunner:test("explicit action max_tokens wins over the bump", function()
    local result = OpenAIHandler:buildRequestBody(HISTORY, webConfig({
        api_params = { max_tokens = 4096 },
    }))
    TestRunner:assertEqual(result.body.max_output_tokens, 4096, "action cap respected")
end)

TestRunner:test("temperature omitted entirely", function()
    local result = OpenAIHandler:buildRequestBody(HISTORY, webConfig())
    TestRunner:assertEqual(result.body.temperature, nil, "no temperature on Responses path")
end)

TestRunner:test("reasoning effort rides nested, not top-level", function()
    local result = OpenAIHandler:buildRequestBody(HISTORY, webConfig({
        api_params = { reasoning = { effort = "high" } },
    }))
    TestRunner:assertEqual(result.body.reasoning.effort, "high", "nested reasoning.effort")
    TestRunner:assertEqual(result.body.reasoning_effort, nil, "no top-level reasoning_effort")
end)

TestRunner:test("custom base URL keeps its host", function()
    local result = OpenAIHandler:buildRequestBody(HISTORY, webConfig({
        base_url = "https://proxy.example.com/v1/chat/completions",
    }))
    TestRunner:assertEqual(result.url, "https://proxy.example.com/v1/responses", "substitution on custom base")
end)

--------------------------------------------------------------------------------
print("\n  [Response parser: openai_responses transformer]")
--------------------------------------------------------------------------------

local function msgItem(text, annotations)
    return {
        type = "message", role = "assistant",
        content = { { type = "output_text", text = text, annotations = annotations } },
    }
end

TestRunner:test("plain answer extracts", function()
    local ok, text = ResponseParser:parseResponse({
        status = "completed",
        output = { msgItem("Hello there.") },
    }, "openai_responses")
    TestRunner:assertTrue(ok, "parse succeeds")
    TestRunner:assertEqual(text, "Hello there.", "text extracted")
end)

TestRunner:test("search + citations produce provenance", function()
    local ok, text, _r, web = ResponseParser:parseResponse({
        status = "completed",
        output = {
            { type = "web_search_call", status = "completed", action = { query = "capybara news" } },
            msgItem("Capybaras are thriving.", {
                { type = "url_citation", url = "https://example.com/capy", title = "Capy News" },
            }),
        },
    }, "openai_responses")
    TestRunner:assertTrue(ok, "parse succeeds")
    TestRunner:assertEqual(text, "Capybaras are thriving.", "answer clean (no leading marker)")
    TestRunner:assertEqual(type(web), "table", "provenance table returned")
    TestRunner:assertEqual(web.sources[1].url, "https://example.com/capy", "source url captured")
    TestRunner:assertEqual(web.queries[1], "capybara news", "query captured")
end)

TestRunner:test("substantive pre-search prose is kept behind the marker", function()
    local long_prose = string.rep("Interesting context sentence. ", 5)
    local ok, text = ResponseParser:parseResponse({
        status = "completed",
        output = {
            msgItem(long_prose),
            { type = "web_search_call", action = { query = "q" } },
            msgItem("Post-search answer."),
        },
    }, "openai_responses")
    TestRunner:assertTrue(ok, "parse succeeds")
    TestRunner:assertTrue(text:find(ResponseParser.WEB_SEARCH_MARKER, 1, true) ~= nil, "marker present")
    TestRunner:assertTrue(text:find("Post-search answer.", 1, true) ~= nil, "post-search text present")
    TestRunner:assertTrue(text:find("Interesting context sentence.", 1, true) ~= nil, "pre-search prose kept")
end)

TestRunner:test("short pre-search filler is dropped without a marker", function()
    local ok, text = ResponseParser:parseResponse({
        status = "completed",
        output = {
            msgItem("Let me check."),
            { type = "web_search_call", action = { query = "q" } },
            msgItem("The answer."),
        },
    }, "openai_responses")
    TestRunner:assertTrue(ok, "parse succeeds")
    TestRunner:assertEqual(text, "The answer.", "filler and marker both gone")
end)

TestRunner:test("truncation notice on incomplete/max_output_tokens", function()
    local ok, text = ResponseParser:parseResponse({
        status = "incomplete",
        incomplete_details = { reason = "max_output_tokens" },
        output = { msgItem("Partial answ") },
    }, "openai_responses")
    TestRunner:assertTrue(ok, "parse succeeds")
    TestRunner:assertTrue(text:find("truncated", 1, true) ~= nil, "truncation notice appended")
end)

TestRunner:test("error object fails with its message", function()
    local ok, err = ResponseParser:parseResponse({
        error = { message = "Invalid API key" },
    }, "openai_responses")
    TestRunner:assertFalse(ok, "parse fails")
    TestRunner:assertEqual(err, "Invalid API key", "error message surfaced")
end)

TestRunner:test("luajson null sentinel in error field is tolerated", function()
    -- KOReader's json decodes JSON null to a truthy function sentinel
    local ok, text = ResponseParser:parseResponse({
        error = function() end,
        status = "completed",
        output = { msgItem("Fine.") },
    }, "openai_responses")
    TestRunner:assertTrue(ok, "sentinel error does not fail the parse")
    TestRunner:assertEqual(text, "Fine.", "text extracted")
end)

TestRunner:test("reasoning items are ignored, text still extracts", function()
    local ok, text = ResponseParser:parseResponse({
        status = "completed",
        output = {
            { type = "reasoning", summary = {} },
            msgItem("Answer."),
        },
    }, "openai_responses")
    TestRunner:assertTrue(ok, "parse succeeds")
    TestRunner:assertEqual(text, "Answer.", "text extracted past reasoning item")
end)

--------------------------------------------------------------------------------
print("\n  [Streaming: extractContentFromSSE on Responses events]")
--------------------------------------------------------------------------------

TestRunner:test("output_text.delta yields content", function()
    local content, reasoning = StreamHandler:extractContentFromSSE({
        type = "response.output_text.delta", delta = "Hel",
    })
    TestRunner:assertEqual(content, "Hel", "delta text")
    TestRunner:assertEqual(reasoning, nil, "no reasoning")
end)

TestRunner:test("reasoning_summary_text.delta yields reasoning", function()
    local content, reasoning = StreamHandler:extractContentFromSSE({
        type = "response.reasoning_summary_text.delta", delta = "thinking",
    })
    TestRunner:assertEqual(content, nil, "no content")
    TestRunner:assertEqual(reasoning, "thinking", "reasoning delta")
end)

TestRunner:test("web_search_call item start signals the search phase", function()
    local content = StreamHandler:extractContentFromSSE({
        type = "response.output_item.added",
        item = { type = "web_search_call", id = "ws_1" },
    })
    TestRunner:assertEqual(content, "__WEB_SEARCH_START__", "search marker")
end)

TestRunner:test("lifecycle events yield nothing", function()
    local content, reasoning = StreamHandler:extractContentFromSSE({
        type = "response.created", response = { id = "resp_1" },
    })
    TestRunner:assertEqual(content, nil, "no content")
    TestRunner:assertEqual(reasoning, nil, "no reasoning")
end)

TestRunner:test("null-sentinel delta yields nothing", function()
    local content = StreamHandler:extractContentFromSSE({
        type = "response.output_text.delta", delta = function() end,
    })
    TestRunner:assertEqual(content, nil, "sentinel delta ignored")
end)

--------------------------------------------------------------------------------
print("\n  [Streaming: source harvest, truncation, usage]")
--------------------------------------------------------------------------------

TestRunner:test("streamed annotation events harvest sources", function()
    local prov = { sources = {}, queries = {}, seen = {} }
    StreamHandler.harvestWebSources({
        type = "response.output_text.annotation.added",
        annotation = { type = "url_citation", url = "https://a.com", title = "A" },
    }, prov)
    TestRunner:assertEqual(#prov.sources, 1, "source harvested")
    TestRunner:assertEqual(prov.sources[1].title, "A", "title kept")
end)

TestRunner:test("terminal event sweeps queries + missed annotations, deduped", function()
    local prov = { sources = {}, queries = {}, seen = {} }
    local terminal = {
        type = "response.completed",
        response = {
            status = "completed",
            output = {
                { type = "web_search_call", action = { query = "capybara news" } },
                {
                    type = "message",
                    content = { {
                        type = "output_text", text = "t",
                        annotations = { { type = "url_citation", url = "https://a.com", title = "A" } },
                    } },
                },
            },
        },
    }
    StreamHandler.harvestWebSources(terminal, prov)
    StreamHandler.harvestWebSources(terminal, prov)  -- second pass must not duplicate
    TestRunner:assertEqual(#prov.queries, 1, "query harvested once")
    TestRunner:assertEqual(#prov.sources, 1, "source deduped")
end)

TestRunner:test("checkIfTruncated detects max_output_tokens", function()
    TestRunner:assertTrue(StreamHandler:checkIfTruncated({
        type = "response.incomplete",
        response = { status = "incomplete", incomplete_details = { reason = "max_output_tokens" } },
    }), "truncated")
    TestRunner:assertFalse(StreamHandler:checkIfTruncated({
        type = "response.completed",
        response = { status = "completed" },
    }), "completed is not truncated")
end)

TestRunner:test("usage extracted from the terminal event", function()
    local usage = DebugUtils.extractUsage({
        type = "response.completed",
        response = { usage = { input_tokens = 100, output_tokens = 40, total_tokens = 140 } },
    })
    TestRunner:assertEqual(usage.input_tokens, 100, "input tokens")
    TestRunner:assertEqual(usage.output_tokens, 40, "output tokens")
    TestRunner:assertEqual(usage.total_tokens, 140, "total tokens")
end)

return TestRunner:summary()
