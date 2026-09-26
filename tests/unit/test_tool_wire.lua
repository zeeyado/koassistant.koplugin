-- Unit tests for koassistant_api/tool_wire.lua (provider tool-turn adapters)

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

local ToolWire = require("koassistant_api.tool_wire")
local TestRunner = require("test_runner"):new()

print("")
print(string.rep("=", 50))
print("  Unit Tests: Tool Wire (provider adapters)")
print(string.rep("=", 50))

TestRunner:test("hasAdapter recognizes registered providers only", function()
    TestRunner:assertTrue(ToolWire.hasAdapter("gemini"), "gemini")
    TestRunner:assertTrue(ToolWire.hasAdapter("anthropic"), "anthropic")
    TestRunner:assertTrue(ToolWire.hasAdapter("bedrock"), "bedrock")
    TestRunner:assertTrue(ToolWire.hasAdapter("openai"), "openai")
    TestRunner:assertFalse(ToolWire.hasAdapter("perplexity"), "perplexity (no adapter)")
    TestRunner:assertFalse(ToolWire.hasAdapter(nil), "nil provider")
end)

TestRunner:test("wave-1 providers alias the openai chat-wire adapter", function()
    for _idx, provider in ipairs({ "openrouter", "deepseek", "mistral", "groq", "xai" }) do
        TestRunner:assertTrue(ToolWire.hasAdapter(provider), provider .. " has adapter")
        TestRunner:assertTrue(ToolWire.adapters[provider] == ToolWire.adapters.openai,
            provider .. " aliases the openai adapter")
    end
    -- Z.AI deliberately excluded: tool_choice only supports "auto" (gather/final
    -- passes need required/none) — see model_constraints.lua zai note.
    TestRunner:assertFalse(ToolWire.hasAdapter("zai"), "zai stays out of wave 1")
end)

TestRunner:test("OpenAI Subscription reuses Responses replay after transport collection", function()
    TestRunner:assertTrue(ToolWire.hasAdapter("openai_codex"), "adapter registered")
    TestRunner:assertTrue(ToolWire.adapters.openai_codex == ToolWire.adapters.openai,
        "same Responses replay shape")
end)

TestRunner:test("openai adapter echo keeps reasoning_content (DeepSeek V3.2+ replay contract)", function()
    local messages = {}
    local raw = { role = "assistant", content = nil, reasoning_content = "thinking...", tool_calls = {
        { id = "c1", type = "function", ["function"] = { name = "search_book", arguments = "{}" } },
    } }
    local executed = { { call = { name = "search_book", id = "c1" }, result = { ok = true } } }
    ToolWire.appendToolTurn("deepseek", messages, raw, executed)
    TestRunner:assertEqual(messages[1].reasoning_content, "thinking...", "echo keeps reasoning_content")
    -- and the luajson null sentinel never rides the echo
    local messages2 = {}
    local raw2 = { role = "assistant", reasoning_content = function() end, tool_calls = {
        { id = "c2", type = "function", ["function"] = { name = "toc", arguments = "{}" } },
    } }
    ToolWire.appendToolTurn("deepseek", messages2, raw2,
        { { call = { name = "toc", id = "c2" }, result = { ok = true } } })
    TestRunner:assertTrue(messages2[1].reasoning_content == nil, "sentinel reasoning_content dropped")
end)

TestRunner:test("stringifyResult JSON-encodes a result table losslessly", function()
    local s = ToolWire.stringifyResult("search_book", { ok = true, total_hits = 3 })
    TestRunner:assertTrue(type(s) == "string", "returns string")
    TestRunner:assertTrue(s:find("total_hits", 1, true) ~= nil, "contains field name")
    TestRunner:assertTrue(s:find("3", 1, true) ~= nil, "contains value")
end)

TestRunner:test("gemini adapter echoes parts and appends functionResponse parts", function()
    local messages = { { role = "user", content = "hi" } }
    local raw = { role = "model", parts = { { functionCall = { name = "search_book", args = {} } } } }
    local executed = { { call = { name = "search_book", id = "c1" }, result = { ok = true } } }
    ToolWire.appendToolTurn("gemini", messages, raw, executed)
    TestRunner:assertEqual(#messages, 3, "two messages appended")
    TestRunner:assertEqual(messages[2].role, "model", "model echo role")
    TestRunner:assertTrue(messages[2].parts[1].functionCall ~= nil, "echoes functionCall part")
    TestRunner:assertEqual(messages[3].role, "tool", "tool turn role")
    TestRunner:assertEqual(messages[3].parts[1].functionResponse.name, "search_book", "functionResponse name")
    TestRunner:assertEqual(messages[3].parts[1].functionResponse.id, "c1", "functionResponse id")
end)

TestRunner:test("anthropic adapter echoes content and appends tool_result blocks", function()
    local messages = { { role = "user", content = "hi" } }
    local raw = { role = "assistant", content = {
        { type = "text", text = "let me look" },
        { type = "tool_use", id = "tu1", name = "search_book", input = {} },
    } }
    local executed = { { call = { name = "search_book", id = "tu1" }, result = { ok = true, total_hits = 2 } } }
    ToolWire.appendToolTurn("anthropic", messages, raw, executed)
    TestRunner:assertEqual(#messages, 3, "two messages appended")
    TestRunner:assertEqual(messages[2].role, "assistant", "assistant echo role")
    TestRunner:assertEqual(messages[2].content[2].type, "tool_use", "echoes tool_use block")
    TestRunner:assertEqual(messages[3].role, "user", "tool_result goes on a user turn")
    TestRunner:assertEqual(messages[3].content[1].type, "tool_result", "tool_result block")
    TestRunner:assertEqual(messages[3].content[1].tool_use_id, "tu1", "tool_use_id linkage")
    TestRunner:assertTrue(type(messages[3].content[1].content) == "string", "result stringified")
end)

TestRunner:test("openai adapter echoes tool_calls turn and appends role=tool messages", function()
    local messages = { { role = "user", content = "hi" } }
    local raw = { role = "assistant", content = nil, tool_calls = {
        { id = "c1", type = "function", ["function"] = { name = "search_book", arguments = '{"query":"x"}' } },
        { id = "c2", type = "function", ["function"] = { name = "toc", arguments = "{}" } },
    } }
    local executed = {
        { call = { name = "search_book", id = "c1" }, result = { ok = true, total_hits = 2 } },
        { call = { name = "toc", id = "c2" }, result = { ok = true } },
    }
    ToolWire.appendToolTurn("openai", messages, raw, executed)
    TestRunner:assertEqual(#messages, 4, "echo + one tool message per result")
    TestRunner:assertEqual(messages[2].role, "assistant", "assistant echo role")
    TestRunner:assertTrue(messages[2].tool_calls ~= nil, "echo keeps tool_calls")
    TestRunner:assertEqual(messages[3].role, "tool", "first result role")
    TestRunner:assertEqual(messages[3].tool_call_id, "c1", "first result keyed by tool_call_id")
    TestRunner:assertTrue(type(messages[3].content) == "string", "result stringified")
    TestRunner:assertEqual(messages[4].tool_call_id, "c2", "second result keyed by tool_call_id")
end)

TestRunner:test("openai adapter stubs unanswered echoed tool_call ids and keeps reasoning_details", function()
    local messages = {}
    local raw = { role = "assistant", tool_calls = {
        { id = "c1", type = "function", ["function"] = { name = "search_book", arguments = "{}" } },
        { id = "c2", type = "function", ["function"] = { name = "web_search", arguments = "{}" } },
    }, reasoning_details = { { type = "reasoning.text", text = "..." } } }
    -- only c1 was executed; c2 was filtered upstream
    local executed = { { call = { name = "search_book", id = "c1" }, result = { ok = true } } }
    ToolWire.appendToolTurn("openai", messages, raw, executed)
    TestRunner:assertEqual(#messages, 3, "echo + real result + stub for the unanswered id")
    TestRunner:assertTrue(messages[1].reasoning_details ~= nil, "echo keeps reasoning_details")
    TestRunner:assertEqual(messages[3].tool_call_id, "c2", "stub answers the filtered call")
    TestRunner:assertTrue(messages[3].content:find("not handled", 1, true) ~= nil, "stub is an error result")
end)

TestRunner:test("appendToolTurn is a no-op for an unknown provider", function()
    local messages = { { role = "user", content = "hi" } }
    ToolWire.appendToolTurn("perplexity", messages, { content = {} }, { { call = { name = "x" }, result = {} } })
    TestRunner:assertEqual(#messages, 1, "no messages appended")
end)

-- Audit quick wins: the custom_ fallback and the Responses branch

TestRunner:test("custom_ providers ride the openai adapter; the anchor is strict", function()
    TestRunner:assertEqual(ToolWire.hasAdapter("custom_lmstudio"), true, "custom_ prefix matches")
    TestRunner:assertEqual(ToolWire.hasAdapter("notcustom_x"), false, "prefix is anchored at start")
end)

TestRunner:test("custom_ appendToolTurn produces the openai chat shape", function()
    local messages = {}
    local turn = { role = "assistant", content = "", tool_calls = {
        { id = "c1", type = "function", ["function"] = { name = "toc", arguments = "{}" } },
    } }
    ToolWire.appendToolTurn("custom_lmstudio", messages, turn,
        { { call = { id = "c1", name = "toc" }, result = { ok = true } } })
    TestRunner:assertEqual(#messages, 2, "assistant echo + one tool message")
    TestRunner:assertEqual(messages[1].tool_calls[1].id, "c1", "echo carries the call")
    TestRunner:assertEqual(messages[2].role, "tool", "result role")
    TestRunner:assertEqual(messages[2].tool_call_id, "c1", "keyed by call id")
    TestRunner:assertEqual(type(messages[2].content), "string", "string content")
end)

TestRunner:test("_responses_output branch: junk dropped, order kept, outputs + auto-stub appended", function()
    local messages = {}
    local turn = { _responses_output = {
        { type = "reasoning", id = "r1" },
        { type = "function_call", call_id = "c1", name = "toc", arguments = "{}" },
        { type = "message", content = {} },
        { type = "web_search_call", id = "junk-item" },
        { type = "function_call", call_id = "c2", name = "search_book", arguments = "{}" },
    } }
    ToolWire.appendToolTurn("openai", messages, turn,
        { { call = { id = "c1", name = "toc" }, result = { ok = true } } })
    TestRunner:assertEqual(#messages, 1, "one _responses_items history entry")
    local items = messages[1]._responses_items
    TestRunner:assertEqual(items[1].type, "reasoning", "reasoning precedes its call")
    TestRunner:assertEqual(items[2].type, "function_call", "call order preserved")
    TestRunner:assertEqual(items[3].type, "message", "message kept")
    TestRunner:assertEqual(items[4].type, "function_call", "second call kept")
    TestRunner:assertEqual(items[5].type, "function_call_output", "executed output appended")
    TestRunner:assertEqual(items[5].call_id, "c1", "output keyed to the executed call")
    TestRunner:assertEqual(items[6].type, "function_call_output", "auto-stub for the unanswered call")
    TestRunner:assertEqual(items[6].call_id, "c2", "stub keyed to the unanswered id")
    TestRunner:assertEqual(#items, 6, "the junk item was dropped")
end)

return TestRunner:summary()
