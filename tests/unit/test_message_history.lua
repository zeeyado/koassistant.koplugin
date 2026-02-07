--[[
Unit Tests for koassistant_message_history.lua

Tests MessageHistory creation, message management, turn counting,
reasoning entries, clear, fromSavedMessages, getSuggestedTitle,
and createResultText.

Run: lua tests/run_tests.lua --unit
]]

-- Setup test environment
local function setupPaths()
    local info = debug.getinfo(1, "S")
    local script_path = info.source:match("@?(.*)")
    local unit_dir = script_path:match("(.+)/[^/]+$") or "."
    local tests_dir = unit_dir:match("(.+)/[^/]+$") or "."
    local plugin_dir = tests_dir:match("(.+)/[^/]+$") or "."

    package.path = table.concat({
        plugin_dir .. "/?.lua",
        plugin_dir .. "/?/init.lua",
        tests_dir .. "/?.lua",
        tests_dir .. "/lib/?.lua",
        package.path,
    }, ";")
end
setupPaths()

require("mock_koreader")

local MessageHistory = require("koassistant_message_history")

-- Test suite
local TestRunner = {
    passed = 0,
    failed = 0,
}

function TestRunner:test(name, fn)
    local ok, err = pcall(fn)
    if ok then
        self.passed = self.passed + 1
        print(string.format("  \226\156\147 %s", name))
    else
        self.failed = self.failed + 1
        print(string.format("  \226\156\151 %s: %s", name, tostring(err)))
    end
end

function TestRunner:assertEqual(actual, expected, message)
    if actual ~= expected then
        error(string.format("%s: expected '%s', got '%s'",
            message or "Values not equal",
            tostring(expected),
            tostring(actual)), 2)
    end
end

function TestRunner:assertContains(str, substring, message)
    if not str or not str:find(substring, 1, true) then
        error(string.format("%s: '%s' not found in output",
            message or "Substring not found",
            substring), 2)
    end
end

function TestRunner:assertNotContains(str, substring, message)
    if str and str:find(substring, 1, true) then
        error(string.format("%s: '%s' should not be in output",
            message or "Unexpected substring",
            substring), 2)
    end
end

function TestRunner:assertNotNil(value, message)
    if value == nil then
        error(string.format("%s: expected non-nil", message or "Assertion failed"), 2)
    end
end

function TestRunner:assertNil(value, message)
    if value ~= nil then
        error(string.format("%s: expected nil, got '%s'", message or "Assertion failed", tostring(value)), 2)
    end
end

function TestRunner:assertType(value, expected_type, message)
    if type(value) ~= expected_type then
        error(string.format("%s: expected type '%s', got '%s'",
            message or "Type mismatch", expected_type, type(value)), 2)
    end
end

-- =============================================================================
-- new() Tests
-- =============================================================================

local function runNewTests()
    print("\n--- MessageHistory:new() ---")

    TestRunner:test("new without system prompt has empty messages", function()
        local h = MessageHistory:new()
        TestRunner:assertEqual(#h.messages, 0)
    end)

    TestRunner:test("new with system prompt adds system message", function()
        local h = MessageHistory:new("You are helpful")
        TestRunner:assertEqual(#h.messages, 1)
        TestRunner:assertEqual(h.messages[1].role, "system")
        TestRunner:assertEqual(h.messages[1].content, "You are helpful")
    end)

    TestRunner:test("new stores prompt_action", function()
        local h = MessageHistory:new(nil, "Explain")
        TestRunner:assertEqual(h.prompt_action, "Explain")
    end)

    TestRunner:test("new initializes model as nil", function()
        local h = MessageHistory:new()
        TestRunner:assertNil(h.model)
    end)

    TestRunner:test("new initializes chat_id as nil", function()
        local h = MessageHistory:new()
        TestRunner:assertNil(h.chat_id)
    end)
end

-- =============================================================================
-- addUserMessage / addAssistantMessage Tests
-- =============================================================================

local function runAddMessageTests()
    print("\n--- addUserMessage / addAssistantMessage ---")

    TestRunner:test("addUserMessage stores role and content", function()
        local h = MessageHistory:new()
        h:addUserMessage("Hello")
        TestRunner:assertEqual(h.messages[1].role, "user")
        TestRunner:assertEqual(h.messages[1].content, "Hello")
    end)

    TestRunner:test("addUserMessage stores is_context flag", function()
        local h = MessageHistory:new()
        h:addUserMessage("Context data", true)
        TestRunner:assertEqual(h.messages[1].is_context, true)
    end)

    TestRunner:test("addUserMessage defaults is_context to false", function()
        local h = MessageHistory:new()
        h:addUserMessage("Question")
        TestRunner:assertEqual(h.messages[1].is_context, false)
    end)

    TestRunner:test("addUserMessage returns message index", function()
        local h = MessageHistory:new()
        local idx = h:addUserMessage("First")
        TestRunner:assertEqual(idx, 1)
        local idx2 = h:addUserMessage("Second")
        TestRunner:assertEqual(idx2, 2)
    end)

    TestRunner:test("addAssistantMessage stores content", function()
        local h = MessageHistory:new()
        h:addAssistantMessage("Response text", "gpt-4")
        TestRunner:assertEqual(h.messages[1].role, "assistant")
        TestRunner:assertEqual(h.messages[1].content, "Response text")
    end)

    TestRunner:test("addAssistantMessage sets model", function()
        local h = MessageHistory:new()
        h:addAssistantMessage("text", "claude-3")
        TestRunner:assertEqual(h.model, "claude-3")
    end)

    TestRunner:test("addAssistantMessage stores reasoning", function()
        local h = MessageHistory:new()
        h:addAssistantMessage("text", nil, "thinking process")
        TestRunner:assertEqual(h.messages[1].reasoning, "thinking process")
    end)

    TestRunner:test("addAssistantMessage stores debug_info", function()
        local h = MessageHistory:new()
        local debug_info = { provider = "anthropic", model = "claude-3" }
        h:addAssistantMessage("text", nil, nil, debug_info)
        TestRunner:assertNotNil(h.messages[1]._debug_info)
        TestRunner:assertEqual(h.messages[1]._debug_info.provider, "anthropic")
    end)

    TestRunner:test("addAssistantMessage stores web_search_used", function()
        local h = MessageHistory:new()
        h:addAssistantMessage("text", nil, nil, nil, true)
        TestRunner:assertEqual(h.messages[1].web_search_used, true)
    end)

    TestRunner:test("addAssistantMessage without reasoning has no reasoning field", function()
        local h = MessageHistory:new()
        h:addAssistantMessage("text", nil)
        TestRunner:assertNil(h.messages[1].reasoning)
    end)
end

-- =============================================================================
-- Turn Counts Tests
-- =============================================================================

local function runTurnCountTests()
    print("\n--- Turn Counts ---")

    TestRunner:test("getUserTurnCount counts user messages", function()
        local h = MessageHistory:new("system")
        h:addUserMessage("Q1")
        h:addAssistantMessage("A1")
        h:addUserMessage("Q2")
        TestRunner:assertEqual(h:getUserTurnCount(), 2)
    end)

    TestRunner:test("getUserTurnCount excludes system messages", function()
        local h = MessageHistory:new("system prompt")
        TestRunner:assertEqual(h:getUserTurnCount(), 0)
    end)

    TestRunner:test("getAssistantTurnCount counts assistant messages", function()
        local h = MessageHistory:new()
        h:addUserMessage("Q1")
        h:addAssistantMessage("A1")
        h:addUserMessage("Q2")
        h:addAssistantMessage("A2")
        TestRunner:assertEqual(h:getAssistantTurnCount(), 2)
    end)

    TestRunner:test("getAssistantTurnCount zero when no responses", function()
        local h = MessageHistory:new()
        h:addUserMessage("Q1")
        TestRunner:assertEqual(h:getAssistantTurnCount(), 0)
    end)

    TestRunner:test("getLastMessage returns last message", function()
        local h = MessageHistory:new()
        h:addUserMessage("Q1")
        h:addAssistantMessage("A1")
        local last = h:getLastMessage()
        TestRunner:assertEqual(last.content, "A1")
    end)

    TestRunner:test("getLastMessage returns nil when empty", function()
        local h = MessageHistory:new()
        TestRunner:assertNil(h:getLastMessage())
    end)
end

-- =============================================================================
-- getReasoningEntries() Tests
-- =============================================================================

local function runReasoningTests()
    print("\n--- getReasoningEntries() ---")

    TestRunner:test("returns empty array when no reasoning", function()
        local h = MessageHistory:new()
        h:addAssistantMessage("text")
        local entries = h:getReasoningEntries()
        TestRunner:assertEqual(#entries, 0)
    end)

    TestRunner:test("captures string reasoning", function()
        local h = MessageHistory:new()
        h:addAssistantMessage("text", nil, "thinking deeply")
        local entries = h:getReasoningEntries()
        TestRunner:assertEqual(#entries, 1)
        TestRunner:assertEqual(entries[1].has_content, true)
        TestRunner:assertEqual(entries[1].reasoning, "thinking deeply")
    end)

    TestRunner:test("captures boolean reasoning (streaming)", function()
        local h = MessageHistory:new()
        h:addAssistantMessage("text", nil, true)
        local entries = h:getReasoningEntries()
        TestRunner:assertEqual(#entries, 1)
        TestRunner:assertEqual(entries[1].has_content, false)
    end)

    TestRunner:test("captures table reasoning with _requested (OpenAI)", function()
        local h = MessageHistory:new()
        h:addAssistantMessage("text", nil, { _requested = true, effort = "medium" })
        local entries = h:getReasoningEntries()
        TestRunner:assertEqual(#entries, 1)
        TestRunner:assertEqual(entries[1].requested_only, true)
        TestRunner:assertEqual(entries[1].effort, "medium")
    end)

    TestRunner:test("mixed reasoning types across messages", function()
        local h = MessageHistory:new()
        h:addAssistantMessage("text1", nil, "thinking")
        h:addAssistantMessage("text2", nil)  -- no reasoning
        h:addAssistantMessage("text3", nil, true)
        local entries = h:getReasoningEntries()
        TestRunner:assertEqual(#entries, 2, "only 2 entries with reasoning")
    end)

    TestRunner:test("msg_num counts correctly (skips context)", function()
        local h = MessageHistory:new("system")
        h:addUserMessage("context", true)
        h:addAssistantMessage("text1", nil, "thinking")
        local entries = h:getReasoningEntries()
        TestRunner:assertEqual(entries[1].msg_num, 1, "first assistant message")
    end)
end

-- =============================================================================
-- clear() Tests
-- =============================================================================

local function runClearTests()
    print("\n--- clear() ---")

    TestRunner:test("clear preserves system message", function()
        local h = MessageHistory:new("system prompt")
        h:addUserMessage("Q1")
        h:addAssistantMessage("A1")
        h:clear()
        TestRunner:assertEqual(#h.messages, 1)
        TestRunner:assertEqual(h.messages[1].role, "system")
    end)

    TestRunner:test("clear removes all when no system message", function()
        local h = MessageHistory:new()
        h:addUserMessage("Q1")
        h:addAssistantMessage("A1")
        h:clear()
        TestRunner:assertEqual(#h.messages, 0)
    end)

    TestRunner:test("clear returns self for chaining", function()
        local h = MessageHistory:new()
        local result = h:clear()
        TestRunner:assertEqual(result, h)
    end)
end

-- =============================================================================
-- fromSavedMessages() Tests
-- =============================================================================

local function runFromSavedMessagesTests()
    print("\n--- fromSavedMessages() ---")

    TestRunner:test("restores messages from saved data", function()
        local msgs = {
            { role = "system", content = "system" },
            { role = "user", content = "question" },
            { role = "assistant", content = "answer" },
        }
        local h = MessageHistory:fromSavedMessages(msgs, "gpt-4", "chat123", "Explain")
        TestRunner:assertEqual(#h.messages, 3)
        TestRunner:assertEqual(h.model, "gpt-4")
        TestRunner:assertEqual(h.chat_id, "chat123")
        TestRunner:assertEqual(h.prompt_action, "Explain")
    end)

    TestRunner:test("restores launch_context", function()
        local h = MessageHistory:fromSavedMessages({}, nil, nil, nil, { title = "Dune", author = "Herbert" })
        TestRunner:assertNotNil(h.launch_context)
        TestRunner:assertEqual(h.launch_context.title, "Dune")
    end)

    TestRunner:test("restores cache metadata", function()
        local metadata = {
            used_cache = true,
            cached_progress = "30%",
            cache_action_id = "xray",
        }
        local h = MessageHistory:fromSavedMessages({}, nil, nil, nil, nil, metadata)
        TestRunner:assertEqual(h.used_cache, true)
        TestRunner:assertEqual(h.cached_progress, "30%")
    end)

    TestRunner:test("restores truncation metadata", function()
        local metadata = {
            book_text_truncated = true,
            book_text_coverage_start = 20,
            book_text_coverage_end = 80,
        }
        local h = MessageHistory:fromSavedMessages({}, nil, nil, nil, nil, metadata)
        TestRunner:assertEqual(h.book_text_truncated, true)
        TestRunner:assertEqual(h.book_text_coverage_start, 20)
    end)

    TestRunner:test("restores unavailable_data metadata", function()
        local metadata = {
            unavailable_data = { "annotations", "notebook" },
        }
        local h = MessageHistory:fromSavedMessages({}, nil, nil, nil, nil, metadata)
        TestRunner:assertEqual(#h.unavailable_data, 2)
    end)

    TestRunner:test("handles nil messages", function()
        local h = MessageHistory:fromSavedMessages(nil)
        TestRunner:assertEqual(#h.messages, 0)
    end)

    TestRunner:test("handles nil metadata", function()
        local h = MessageHistory:fromSavedMessages({}, nil, nil, nil, nil, nil)
        TestRunner:assertNil(h.used_cache)
    end)
end

-- =============================================================================
-- getSuggestedTitle() Tests
-- =============================================================================

local function runGetSuggestedTitleTests()
    print("\n--- getSuggestedTitle() ---")

    TestRunner:test("uses prompt_action as prefix", function()
        local h = MessageHistory:new(nil, "Explain")
        h:addUserMessage("[Request]\nWhat is quantum physics?")
        local title = h:getSuggestedTitle()
        TestRunner:assertContains(title, "Explain")
    end)

    TestRunner:test("extracts highlighted text from Selected text", function()
        local h = MessageHistory:new(nil, "Explain")
        h:addUserMessage('[Context]\nSelected text:\n"quantum entanglement"\n\n[Request]\nExplain this')
        local title = h:getSuggestedTitle()
        TestRunner:assertContains(title, "quantum entanglement")
    end)

    TestRunner:test("truncates long highlighted text to 40 chars", function()
        local long_text = string.rep("a", 60)
        local h = MessageHistory:new(nil, "Explain")
        h:addUserMessage('[Context]\nSelected text:\n"' .. long_text .. '"\n\n[Request]\nExplain')
        local title = h:getSuggestedTitle()
        TestRunner:assertContains(title, "...")
        -- Title should be reasonable length
        if #title > 60 then
            error("Title too long: " .. #title)
        end
    end)

    TestRunner:test("falls back to request text when no highlight", function()
        local h = MessageHistory:new(nil, "Chat")
        h:addUserMessage("[Request]\nWhat is the meaning of life?")
        local title = h:getSuggestedTitle()
        TestRunner:assertContains(title, "What is the meaning")
    end)

    TestRunner:test("ultimate fallback is 'Chat'", function()
        local h = MessageHistory:new()
        local title = h:getSuggestedTitle()
        TestRunner:assertContains(title, "Chat")
    end)

    TestRunner:test("skips context messages", function()
        local h = MessageHistory:new(nil, "Test")
        h:addUserMessage("This is context", true)  -- is_context = true
        h:addUserMessage("[Request]\nActual question")
        local title = h:getSuggestedTitle()
        TestRunner:assertContains(title, "Actual question")
    end)
end

-- =============================================================================
-- createResultText() Tests
-- =============================================================================

local function runCreateResultTextTests()
    print("\n--- createResultText() ---")

    local function emptyConfig()
        return { features = {} }
    end

    TestRunner:test("basic result with highlighted text", function()
        local h = MessageHistory:new()
        h:addUserMessage("Q")
        h:addAssistantMessage("Response text")
        local result = h:createResultText("selected word", emptyConfig())
        TestRunner:assertContains(result, "selected word")
        TestRunner:assertContains(result, "Response text")
    end)

    TestRunner:test("cache notice shown when used_cache", function()
        local h = MessageHistory:new()
        h.used_cache = true
        h.cached_progress = "30%"
        h:addAssistantMessage("text")
        local result = h:createResultText(nil, emptyConfig())
        TestRunner:assertContains(result, "Updated from 30% cache")
    end)

    TestRunner:test("truncation notice shown", function()
        local h = MessageHistory:new()
        h.book_text_truncated = true
        h.book_text_coverage_start = 20
        h.book_text_coverage_end = 80
        h:addAssistantMessage("text")
        local result = h:createResultText(nil, emptyConfig())
        TestRunner:assertContains(result, "Book text truncated")
        TestRunner:assertContains(result, "20%")
        TestRunner:assertContains(result, "80%")
    end)

    TestRunner:test("unavailable_data notice shown", function()
        local h = MessageHistory:new()
        h.unavailable_data = { "annotations", "notebook" }
        h:addAssistantMessage("text")
        local result = h:createResultText(nil, emptyConfig())
        TestRunner:assertContains(result, "without: annotations, notebook")
    end)

    TestRunner:test("launch_context header shown", function()
        local h = MessageHistory:new()
        h.launch_context = { title = "Dune", author = "Herbert" }
        h:addAssistantMessage("text")
        local result = h:createResultText(nil, emptyConfig())
        TestRunner:assertContains(result, "Launched from: Dune")
        TestRunner:assertContains(result, "Herbert")
    end)

    TestRunner:test("debug section shown when show_debug_in_chat=true", function()
        local h = MessageHistory:new()
        h:addUserMessage("Q")
        h:addAssistantMessage("A")
        local config = {
            features = { show_debug_in_chat = true, debug_display_level = "names" },
            provider = "openai",
        }
        local result = h:createResultText(nil, config)
        TestRunner:assertContains(result, "Debug Info")
    end)

    TestRunner:test("reasoning indicator shown by default", function()
        local h = MessageHistory:new()
        h:addAssistantMessage("text", nil, "deep thinking")
        local result = h:createResultText(nil, emptyConfig())
        TestRunner:assertContains(result, "Reasoning/Thinking was used")
    end)

    TestRunner:test("OpenAI requested reasoning indicator", function()
        local h = MessageHistory:new()
        h:addAssistantMessage("text", nil, { _requested = true, effort = "high" })
        local result = h:createResultText(nil, emptyConfig())
        TestRunner:assertContains(result, "Reasoning requested")
        TestRunner:assertContains(result, "high")
    end)

    TestRunner:test("web search indicator shown", function()
        local h = MessageHistory:new()
        h:addAssistantMessage("text", nil, nil, nil, true)
        local result = h:createResultText(nil, emptyConfig())
        TestRunner:assertContains(result, "Web search was used")
    end)

    TestRunner:test("compact_view hides prefixes", function()
        local h = MessageHistory:new()
        h:addUserMessage("Q")
        h:addAssistantMessage("A")
        local config = { features = { compact_view = true } }
        local result = h:createResultText(nil, config)
        TestRunner:assertNotContains(result, "User:")
        TestRunner:assertNotContains(result, "KOAssistant:")
    end)

    TestRunner:test("book context label", function()
        local h = MessageHistory:new()
        h:addAssistantMessage("text")
        local config = { features = { is_book_context = true } }
        local result = h:createResultText("1984", config)
        TestRunner:assertContains(result, "Book: 1984")
    end)

    TestRunner:test("multi_book context label", function()
        local h = MessageHistory:new()
        h:addAssistantMessage("text")
        local config = { features = { is_multi_book_context = true } }
        local result = h:createResultText("Book A\nBook B", config)
        TestRunner:assertContains(result, "Selected books:")
    end)

    TestRunner:test("hide_highlighted_text hides text", function()
        local h = MessageHistory:new()
        h:addAssistantMessage("text")
        local config = { features = { hide_highlighted_text = true } }
        local result = h:createResultText("should be hidden", config)
        TestRunner:assertNotContains(result, "should be hidden")
    end)

    TestRunner:test("multi-turn conversation has separators", function()
        local h = MessageHistory:new()
        h:addUserMessage("Q1")
        h:addAssistantMessage("A1")
        h:addUserMessage("Q2")
        h:addAssistantMessage("A2")
        local result = h:createResultText(nil, emptyConfig())
        TestRunner:assertContains(result, "---")
    end)
end

-- =============================================================================
-- Run All Tests
-- =============================================================================

local function runAll()
    print("\n=== Testing MessageHistory ===")

    runNewTests()
    runAddMessageTests()
    runTurnCountTests()
    runReasoningTests()
    runClearTests()
    runFromSavedMessagesTests()
    runGetSuggestedTitleTests()
    runCreateResultTextTests()

    print(string.format("\n=== Results: %d passed, %d failed ===\n", TestRunner.passed, TestRunner.failed))
    return TestRunner.failed == 0
end

-- Run tests if executed directly
if arg and arg[0] and arg[0]:match("test_message_history%.lua$") then
    local success = runAll()
    os.exit(success and 0 or 1)
end

return {
    runAll = runAll,
    TestRunner = TestRunner,
}
