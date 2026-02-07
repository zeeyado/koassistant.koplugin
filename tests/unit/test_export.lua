--[[
Unit Tests for koassistant_export.lua

Tests export formatting (pure data transforms, no filesystem tests):
- Export.format() for all content modes x styles
- Export.getFilename() sanitization and formatting
- Export.formatCacheContent() for cache types
- Export.fromHistory() and Export.fromSavedChat() data extraction

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

local Export = require("koassistant_export")

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

function TestRunner:assertType(value, expected_type, message)
    if type(value) ~= expected_type then
        error(string.format("%s: expected type '%s', got '%s'",
            message or "Type mismatch", expected_type, type(value)), 2)
    end
end

-- Helper: build standard test data
local function buildTestData(overrides)
    local data = {
        messages = {
            { role = "user", content = "What is this about?", is_context = false },
            { role = "assistant", content = "This is about testing." },
        },
        model = "gpt-4",
        title = "Explain",
        date = "2026-01-15 10:30",
        last_response = "This is about testing.",
        book_title = "The Great Gatsby",
        book_author = "F. Scott Fitzgerald",
    }
    if overrides then
        for k, v in pairs(overrides) do
            data[k] = v
        end
    end
    return data
end

-- =============================================================================
-- Export.format() - Response mode
-- =============================================================================

local function runResponseModeTests()
    print("\n--- Export.format(): response mode ---")

    TestRunner:test("response mode returns raw last_response", function()
        local data = buildTestData()
        local result = Export.format(data, "response", "markdown")
        TestRunner:assertEqual(result, "This is about testing.")
    end)

    TestRunner:test("response mode returns empty when no last_response", function()
        local data = buildTestData({ last_response = nil })
        local result = Export.format(data, "response", "text")
        TestRunner:assertEqual(result, "")
    end)

    TestRunner:test("response mode ignores style parameter", function()
        local data = buildTestData()
        local md = Export.format(data, "response", "markdown")
        local txt = Export.format(data, "response", "text")
        TestRunner:assertEqual(md, txt, "same output regardless of style")
    end)
end

-- =============================================================================
-- Export.format() - QA mode
-- =============================================================================

local function runQAModeTests()
    print("\n--- Export.format(): qa mode ---")

    TestRunner:test("qa markdown: has context line", function()
        local data = buildTestData()
        local result = Export.format(data, "qa", "markdown")
        TestRunner:assertContains(result, "[Explain")
        TestRunner:assertContains(result, "gpt-4")
    end)

    TestRunner:test("qa markdown: includes non-context messages", function()
        local data = buildTestData()
        local result = Export.format(data, "qa", "markdown")
        TestRunner:assertContains(result, "What is this about?")
        TestRunner:assertContains(result, "This is about testing.")
    end)

    TestRunner:test("qa markdown: excludes context messages", function()
        local data = buildTestData({
            messages = {
                { role = "user", content = "Context info", is_context = true },
                { role = "user", content = "My question" },
                { role = "assistant", content = "My answer" },
            },
        })
        local result = Export.format(data, "qa", "markdown")
        TestRunner:assertNotContains(result, "Context info")
        TestRunner:assertContains(result, "My question")
    end)

    TestRunner:test("qa text: has context line", function()
        local data = buildTestData()
        local result = Export.format(data, "qa", "text")
        TestRunner:assertContains(result, "[Explain")
    end)

    TestRunner:test("qa: no book metadata header", function()
        local data = buildTestData()
        local result = Export.format(data, "qa", "markdown")
        TestRunner:assertNotContains(result, "**Book:**")
        TestRunner:assertNotContains(result, "**Date:**")
    end)
end

-- =============================================================================
-- Export.format() - Full QA mode
-- =============================================================================

local function runFullQAModeTests()
    print("\n--- Export.format(): full_qa mode ---")

    TestRunner:test("full_qa: has context line", function()
        local data = buildTestData()
        local result = Export.format(data, "full_qa", "markdown")
        TestRunner:assertContains(result, "[Explain")
    end)

    TestRunner:test("full_qa: includes context messages", function()
        local data = buildTestData({
            messages = {
                { role = "user", content = "Context info", is_context = true },
                { role = "user", content = "My question" },
                { role = "assistant", content = "My answer" },
            },
        })
        local result = Export.format(data, "full_qa", "markdown")
        TestRunner:assertContains(result, "Context info")
        TestRunner:assertContains(result, "My question")
    end)

    TestRunner:test("full_qa: includes highlighted text", function()
        local data = buildTestData({ highlighted_text = "quantum entanglement" })
        local result = Export.format(data, "full_qa", "markdown")
        TestRunner:assertContains(result, "quantum entanglement")
    end)

    TestRunner:test("full_qa: no book metadata header", function()
        local data = buildTestData()
        local result = Export.format(data, "full_qa", "markdown")
        TestRunner:assertNotContains(result, "**Book:**")
    end)
end

-- =============================================================================
-- Export.format() - Full mode
-- =============================================================================

local function runFullModeTests()
    print("\n--- Export.format(): full mode ---")

    TestRunner:test("full markdown: has header with title", function()
        local data = buildTestData()
        local result = Export.format(data, "full", "markdown")
        TestRunner:assertContains(result, "# Explain")
    end)

    TestRunner:test("full markdown: has date", function()
        local data = buildTestData()
        local result = Export.format(data, "full", "markdown")
        TestRunner:assertContains(result, "**Date:** 2026-01-15 10:30")
    end)

    TestRunner:test("full markdown: has book info", function()
        local data = buildTestData()
        local result = Export.format(data, "full", "markdown")
        TestRunner:assertContains(result, "The Great Gatsby")
        TestRunner:assertContains(result, "F. Scott Fitzgerald")
    end)

    TestRunner:test("full markdown: has model", function()
        local data = buildTestData()
        local result = Export.format(data, "full", "markdown")
        TestRunner:assertContains(result, "**Model:** gpt-4")
    end)

    TestRunner:test("full text: plain format header", function()
        local data = buildTestData()
        local result = Export.format(data, "full", "text")
        TestRunner:assertContains(result, "Explain")
        TestRunner:assertContains(result, "Date: 2026-01-15 10:30")
        TestRunner:assertContains(result, "Model: gpt-4")
    end)

    TestRunner:test("full: excludes context messages", function()
        local data = buildTestData({
            messages = {
                { role = "user", content = "System context", is_context = true },
                { role = "user", content = "My question" },
                { role = "assistant", content = "My answer" },
            },
        })
        local result = Export.format(data, "full", "markdown")
        TestRunner:assertNotContains(result, "System context")
        TestRunner:assertContains(result, "My question")
    end)

    TestRunner:test("full: includes highlighted text", function()
        local data = buildTestData({ highlighted_text = "selected passage" })
        local result = Export.format(data, "full", "markdown")
        TestRunner:assertContains(result, "selected passage")
        TestRunner:assertContains(result, "### Highlighted")
    end)

    TestRunner:test("full: includes domain and tags", function()
        local data = buildTestData({ domain = "Science", tags = { "physics", "quantum" } })
        local result = Export.format(data, "full", "markdown")
        TestRunner:assertContains(result, "**Domain:** Science")
        TestRunner:assertContains(result, "physics, quantum")
    end)

    TestRunner:test("full: includes launch context", function()
        local data = buildTestData({
            launch_context = { title = "Dune", author = "Herbert" },
        })
        local result = Export.format(data, "full", "markdown")
        TestRunner:assertContains(result, "Launched from:")
        TestRunner:assertContains(result, "Dune")
    end)

    TestRunner:test("full: multi-book display", function()
        local data = buildTestData({
            book_title = nil,
            books_info = {
                { title = "Book A", authors = "Author 1" },
                { title = "Book B", authors = "Author 2" },
            },
        })
        local result = Export.format(data, "full", "markdown")
        TestRunner:assertContains(result, "**Books:**")
        TestRunner:assertContains(result, "Book A")
        TestRunner:assertContains(result, "Book B")
    end)
end

-- =============================================================================
-- Export.format() - Everything mode
-- =============================================================================

local function runEverythingModeTests()
    print("\n--- Export.format(): everything mode ---")

    TestRunner:test("everything: includes context messages", function()
        local data = buildTestData({
            messages = {
                { role = "user", content = "Context info here", is_context = true },
                { role = "user", content = "My question" },
                { role = "assistant", content = "My answer" },
            },
        })
        local result = Export.format(data, "everything", "markdown")
        TestRunner:assertContains(result, "Context info here")
        TestRunner:assertContains(result, "My question")
    end)

    TestRunner:test("everything: has metadata header", function()
        local data = buildTestData()
        local result = Export.format(data, "everything", "markdown")
        TestRunner:assertContains(result, "# Explain")
        TestRunner:assertContains(result, "**Date:**")
    end)

    TestRunner:test("everything: includes highlighted text", function()
        local data = buildTestData({ highlighted_text = "important passage" })
        local result = Export.format(data, "everything", "markdown")
        TestRunner:assertContains(result, "important passage")
    end)
end

-- =============================================================================
-- Export.getFilename()
-- =============================================================================

local function runGetFilenameTests()
    print("\n--- Export.getFilename() ---")

    TestRunner:test("basic filename with book and chat title", function()
        local result = Export.getFilename("My Book", "Explain", 0, "md")
        TestRunner:assertContains(result, "My_Book")
        TestRunner:assertContains(result, "Explain")
        TestRunner:assertContains(result, ".md")
    end)

    TestRunner:test("sanitizes special characters", function()
        local result = Export.getFilename('Book: "Test"', "Chat?", 0, "md")
        TestRunner:assertNotContains(result, ":")
        TestRunner:assertNotContains(result, '"')
        TestRunner:assertNotContains(result, "?")
    end)

    TestRunner:test("truncates long titles", function()
        local long_title = string.rep("A", 100)
        local result = Export.getFilename(long_title, "Chat", 0, "md")
        -- Should be reasonable length
        if #result > 100 then
            error("Filename too long: " .. #result)
        end
    end)

    TestRunner:test("handles nil book_title", function()
        local result = Export.getFilename(nil, "Explain", 0, "md")
        TestRunner:assertContains(result, "Explain")
        TestRunner:assertContains(result, ".md")
    end)

    TestRunner:test("handles nil chat_title", function()
        local result = Export.getFilename("Book", nil, 0, "md")
        TestRunner:assertContains(result, "Book")
        TestRunner:assertContains(result, ".md")
    end)

    TestRunner:test("uses txt extension", function()
        local result = Export.getFilename("Book", "Chat", 0, "txt")
        TestRunner:assertContains(result, ".txt")
    end)

    TestRunner:test("skip_book_title omits book from filename", function()
        local result = Export.getFilename("My Book", "Explain", 0, "md", true)
        TestRunner:assertNotContains(result, "My_Book")
        TestRunner:assertContains(result, "Explain")
    end)

    TestRunner:test("spaces replaced with underscores", function()
        local result = Export.getFilename("My Great Book", "My Chat", 0, "md")
        TestRunner:assertNotContains(result, " ")
    end)
end

-- =============================================================================
-- Export.formatCacheContent()
-- =============================================================================

local function runFormatCacheContentTests()
    print("\n--- Export.formatCacheContent() ---")

    TestRunner:test("xray markdown format", function()
        local result = Export.formatCacheContent("X-Ray content here", {
            cache_type = "xray",
            book_title = "Test Book",
            book_author = "Author",
            progress_decimal = 0.5,
            model = "claude-3",
            timestamp = os.time(),
        }, "markdown")
        TestRunner:assertContains(result, "# X-Ray: Test Book")
        TestRunner:assertContains(result, "**Author:** Author")
        TestRunner:assertContains(result, "**Coverage:** 50%")
        TestRunner:assertContains(result, "**Model:** claude-3")
        TestRunner:assertContains(result, "X-Ray content here")
    end)

    TestRunner:test("summary text format", function()
        local result = Export.formatCacheContent("Summary here", {
            cache_type = "summary",
            book_title = "Test Book",
        }, "text")
        TestRunner:assertContains(result, "SUMMARY: Test Book")
        TestRunner:assertContains(result, "Summary here")
    end)

    TestRunner:test("analyze format", function()
        local result = Export.formatCacheContent("Analysis content", {
            cache_type = "analyze",
        }, "markdown")
        TestRunner:assertContains(result, "# Analysis")
    end)

    TestRunner:test("coverage rounding", function()
        local result = Export.formatCacheContent("content", {
            cache_type = "xray",
            progress_decimal = 0.456,
        }, "markdown")
        TestRunner:assertContains(result, "**Coverage:** 46%")
    end)

    TestRunner:test("used_annotations=true shown for xray", function()
        local result = Export.formatCacheContent("content", {
            cache_type = "xray",
            used_annotations = true,
        }, "markdown")
        TestRunner:assertContains(result, "Includes annotations")
    end)

    TestRunner:test("used_annotations=false not shown", function()
        local result = Export.formatCacheContent("content", {
            cache_type = "xray",
            used_annotations = false,
        }, "markdown")
        TestRunner:assertNotContains(result, "Includes annotations")
    end)

    TestRunner:test("unknown cache type uses raw name", function()
        local result = Export.formatCacheContent("content", {
            cache_type = "custom",
        }, "markdown")
        TestRunner:assertContains(result, "# custom")
    end)
end

-- =============================================================================
-- Export.fromHistory()
-- =============================================================================

local function runFromHistoryTests()
    print("\n--- Export.fromHistory() ---")

    -- Create a minimal mock MessageHistory
    local function createMockHistory(messages, model, prompt_action)
        return {
            prompt_action = prompt_action,
            getMessages = function(self_hist)
                return messages
            end,
            getLastMessage = function(self_hist)
                return messages[#messages]
            end,
            getModel = function(self_hist)
                return model
            end,
        }
    end

    TestRunner:test("extracts messages from history", function()
        local msgs = {
            { role = "user", content = "Hello" },
            { role = "assistant", content = "Hi there" },
        }
        local history = createMockHistory(msgs, "gpt-4", "Explain")
        local data = Export.fromHistory(history, nil, nil, nil)
        TestRunner:assertEqual(#data.messages, 2)
        TestRunner:assertEqual(data.model, "gpt-4")
        TestRunner:assertEqual(data.title, "Explain")
    end)

    TestRunner:test("includes highlighted text", function()
        local history = createMockHistory({}, "gpt-4", nil)
        local data = Export.fromHistory(history, "selected text", nil, nil)
        TestRunner:assertEqual(data.highlighted_text, "selected text")
    end)

    TestRunner:test("includes book metadata", function()
        local history = createMockHistory({}, "gpt-4", nil)
        local data = Export.fromHistory(history, nil, { title = "Dune", author = "Herbert" }, nil)
        TestRunner:assertEqual(data.book_title, "Dune")
        TestRunner:assertEqual(data.book_author, "Herbert")
    end)

    TestRunner:test("includes books_info for multi-book", function()
        local books = { { title = "A", authors = "X" }, { title = "B", authors = "Y" } }
        local history = createMockHistory({}, "gpt-4", nil)
        local data = Export.fromHistory(history, nil, nil, books)
        TestRunner:assertEqual(#data.books_info, 2)
    end)

    TestRunner:test("last_response from last message", function()
        local msgs = {
            { role = "user", content = "Q" },
            { role = "assistant", content = "Answer text" },
        }
        local history = createMockHistory(msgs, "gpt-4", nil)
        local data = Export.fromHistory(history, nil, nil, nil)
        TestRunner:assertEqual(data.last_response, "Answer text")
    end)
end

-- =============================================================================
-- Export.fromSavedChat()
-- =============================================================================

local function runFromSavedChatTests()
    print("\n--- Export.fromSavedChat() ---")

    TestRunner:test("extracts fields from saved chat", function()
        local chat = {
            messages = {
                { role = "user", content = "Hello" },
                { role = "assistant", content = "Hi" },
            },
            model = "claude-3",
            title = "Chat Title",
            timestamp = 1700000000,
            book_title = "Book",
            book_author = "Author",
            domain = "Science",
            tags = { "physics" },
        }
        local data = Export.fromSavedChat(chat)
        TestRunner:assertEqual(data.model, "claude-3")
        TestRunner:assertEqual(data.title, "Chat Title")
        TestRunner:assertEqual(data.book_title, "Book")
        TestRunner:assertEqual(data.domain, "Science")
        TestRunner:assertEqual(#data.tags, 1)
    end)

    TestRunner:test("extracts highlighted text from metadata", function()
        local chat = {
            messages = {},
            metadata = { original_highlighted_text = "selected" },
        }
        local data = Export.fromSavedChat(chat)
        TestRunner:assertEqual(data.highlighted_text, "selected")
    end)

    TestRunner:test("extracts books_info from metadata", function()
        local chat = {
            messages = {},
            metadata = {
                books_info = { { title = "A" }, { title = "B" } },
            },
        }
        local data = Export.fromSavedChat(chat)
        TestRunner:assertEqual(#data.books_info, 2)
    end)

    TestRunner:test("extracts launch_context", function()
        local chat = {
            messages = {},
            launch_context = { title = "Dune", author = "Herbert" },
        }
        local data = Export.fromSavedChat(chat)
        TestRunner:assertEqual(data.launch_context.title, "Dune")
    end)

    TestRunner:test("last_response from last message", function()
        local chat = {
            messages = {
                { role = "user", content = "Q" },
                { role = "assistant", content = "Final answer" },
            },
        }
        local data = Export.fromSavedChat(chat)
        TestRunner:assertEqual(data.last_response, "Final answer")
    end)

    TestRunner:test("handles empty messages", function()
        local chat = { messages = {} }
        local data = Export.fromSavedChat(chat)
        TestRunner:assertEqual(data.last_response, "")
    end)
end

-- =============================================================================
-- Run All Tests
-- =============================================================================

local function runAll()
    print("\n=== Testing Export Module ===")

    runResponseModeTests()
    runQAModeTests()
    runFullQAModeTests()
    runFullModeTests()
    runEverythingModeTests()
    runGetFilenameTests()
    runFormatCacheContentTests()
    runFromHistoryTests()
    runFromSavedChatTests()

    print(string.format("\n=== Results: %d passed, %d failed ===\n", TestRunner.passed, TestRunner.failed))
    return TestRunner.failed == 0
end

-- Run tests if executed directly
if arg and arg[0] and arg[0]:match("test_export%.lua$") then
    local success = runAll()
    os.exit(success and 0 or 1)
end

return {
    runAll = runAll,
    TestRunner = TestRunner,
}
