-- Unit tests for Gemini tool runner diagnostics

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

local GeminiToolRunner = require("koassistant_gemini_tool_runner")
local TestRunner = require("test_runner"):new()

local function makeUi()
    local pages = {
        "Alice saw the white rabbit. Daisy was mentioned in a letter.",
        "The garden path curved behind the old house.",
    }
    return {
        document = {
            info = {
                has_pages = true,
                number_of_pages = 2,
            },
            getPageText = function(_self, page)
                return pages[page] or ""
            end,
        },
        view = {
            state = {
                page = 2,
            },
        },
    }
end

print("")
print(string.rep("=", 50))
print("  Unit Tests: Gemini Tool Runner")
print(string.rep("=", 50))

TestRunner:test("formats tool results as plain text and appends token usage", function()
    local calls = 0
    local final_answer = nil
    local scope_message = nil
    local function query_fn(messages, _config, callback)
        calls = calls + 1
        if calls == 1 then
            scope_message = messages[#messages].content
            callback(true, {
                _gemini_function_calls = true,
                calls = {
                    {
                        name = "search_book",
                        args = { query = "Daisy" },
                    },
                },
                model_content = {
                    role = "model",
                    parts = {
                        {
                            functionCall = {
                                name = "search_book",
                                args = { query = "Daisy" },
                            },
                        },
                    },
                },
            }, nil, nil, nil, {
                input_tokens = 10,
                output_tokens = 3,
                total_tokens = 13,
            })
        else
            callback(true, "Daisy is mentioned in a letter.", nil, nil, nil, {
                input_tokens = 20,
                output_tokens = 5,
                total_tokens = 25,
            })
        end
    end

    GeminiToolRunner.run({
        query_fn = query_fn,
        messages = {
            { role = "user", content = "Where is Daisy?" },
        },
        config = {
            provider = "gemini",
            features = {
                is_book_context = true,
                -- diagnostics are now gated behind in-chat debug; this test asserts they appear
                show_debug_in_chat = true,
                -- spoiler-free keeps the current-page scope wording asserted below
                spoiler_free_chat = true,
            },
        },
        ui = makeUi(),
        on_complete = function(success, answer)
            TestRunner:assertTrue(success, "runner success")
            final_answer = answer
        end,
    })

    TestRunner:assertEqual(calls, 2, "query calls")
    TestRunner:assertTrue(scope_message:find("Current page: 2 of 2", 1, true) ~= nil, "current page scope")
    TestRunner:assertTrue(scope_message:find("Readable page range: 1-2", 1, true) ~= nil, "readable range scope")
    TestRunner:assertTrue(final_answer:find("Tool results sent to model", 1, true) ~= nil, "verbose output header")
    TestRunner:assertTrue(final_answer:find("search_book: 1 query, 1 total hit", 1, true) ~= nil, "search result summary")
    TestRunner:assertTrue(final_answer:find("Daisy was mentioned in a letter", 1, true) ~= nil, "tool result text")
    TestRunner:assertTrue(final_answer:find("38 total tokens", 1, true) ~= nil, "total token usage")
    TestRunner:assertTrue(final_answer:find("across 2 Gemini API calls", 1, true) ~= nil, "call count")
end)

TestRunner:test("spoiler-free off → tools get full-document reading scope", function()
    local scope_message
    local function query_fn(messages, _config, callback)
        scope_message = messages[#messages].content
        callback(true, "ok")
    end
    GeminiToolRunner.run({
        query_fn = query_fn,
        messages = { { role = "user", content = "hi" } },
        config = { provider = "gemini", features = { is_book_context = true } }, -- no spoiler-free → full
        ui = makeUi(),
        on_complete = function() end,
    })
    TestRunner:assertTrue(scope_message:find("read the entire document", 1, true) ~= nil,
        "full-scope scope message")
end)

TestRunner:test("spoiler-free on → tools are clamped to the current page", function()
    local scope_message
    local function query_fn(messages, _config, callback)
        scope_message = messages[#messages].content
        callback(true, "ok")
    end
    GeminiToolRunner.run({
        query_fn = query_fn,
        messages = { { role = "user", content = "hi" } },
        config = { provider = "gemini", features = { is_book_context = true, spoiler_free_chat = true } },
        ui = makeUi(),
        on_complete = function() end,
    })
    TestRunner:assertTrue(scope_message:find("Do not request or infer content after page", 1, true) ~= nil,
        "current-scope scope message clamps")
end)

TestRunner:test("session spoiler checkbox overrides global for tool scope", function()
    local function scope_msg_for(features)
        local captured
        GeminiToolRunner.run({
            query_fn = function(messages, _c, cb) captured = messages[#messages].content; cb(true, "ok") end,
            messages = { { role = "user", content = "hi" } },
            config = { provider = "gemini", features = features },
            ui = makeUi(),
            on_complete = function() end,
        })
        return captured
    end
    -- global spoiler-free ON, but the session box was explicitly unchecked → full document
    TestRunner:assertTrue(
        scope_msg_for({ spoiler_free_chat = true, _spoiler_free_active = false }):find("read the entire document", 1, true) ~= nil,
        "session off overrides global on")
    -- session box explicitly checked → clamp to current page
    TestRunner:assertTrue(
        scope_msg_for({ spoiler_free_chat = false, _spoiler_free_active = true }):find("Do not request or infer content after page", 1, true) ~= nil,
        "session on clamps")
end)

TestRunner:test("shouldUse skips when _xray_chat_active is set", function()
    local cfg = {
        provider = "gemini",
        features = { is_book_context = true, _xray_chat_active = true,
            -- opt-in + consent satisfied so _xray_chat_active is the isolated cause
            enable_tool_workflows = true, enable_book_text_extraction = true },
    }
    TestRunner:assertFalse(GeminiToolRunner.shouldUse(cfg, makeUi()),
        "x-ray chat session must skip book tools")
end)

TestRunner:test("shouldUse requires the experimental enable_tool_workflows flag", function()
    local cfg = {
        provider = "gemini",
        features = { is_book_context = true, enable_book_text_extraction = true },
    }
    TestRunner:assertFalse(GeminiToolRunner.shouldUse(cfg, makeUi()),
        "tools stay off until enable_tool_workflows is set")
    cfg.features.enable_tool_workflows = true
    TestRunner:assertTrue(GeminiToolRunner.shouldUse(cfg, makeUi()),
        "tools enabled once the flag and extraction consent are set")
end)

TestRunner:test("shouldUse respects the text-extraction consent gate", function()
    local cfg = {
        provider = "gemini",
        features = { is_book_context = true, enable_tool_workflows = true },
    }
    TestRunner:assertFalse(GeminiToolRunner.shouldUse(cfg, makeUi()),
        "no tools when book-text extraction is not allowed")
    cfg.features.enable_book_text_extraction = true
    TestRunner:assertTrue(GeminiToolRunner.shouldUse(cfg, makeUi()),
        "tools allowed once extraction consent is granted")
end)

TestRunner:test("shouldUse lets a trusted provider bypass the extraction gate", function()
    local cfg = {
        provider = "gemini",
        features = {
            is_book_context = true,
            enable_tool_workflows = true,
            -- extraction OFF, but the provider is trusted
            trusted_providers = { "gemini" },
        },
    }
    TestRunner:assertTrue(GeminiToolRunner.shouldUse(cfg, makeUi()),
        "trusted provider bypasses the extraction-consent gate")
end)

TestRunner:test("diagnostics are suppressed unless show_debug_in_chat is set", function()
    local calls = 0
    local function query_fn(_messages, _config, callback)
        calls = calls + 1
        if calls == 1 then
            callback(true, {
                _gemini_function_calls = true,
                calls = { { name = "search_book", args = { query = "Daisy" } } },
                model_content = { role = "model", parts = {
                    { functionCall = { name = "search_book", args = { query = "Daisy" } } } } },
            }, nil, nil, nil, { input_tokens = 10, output_tokens = 3, total_tokens = 13 })
        else
            callback(true, "Daisy is mentioned in a letter.", nil, nil, nil,
                { input_tokens = 20, output_tokens = 5, total_tokens = 25 })
        end
    end
    local final_answer
    GeminiToolRunner.run({
        query_fn = query_fn,
        messages = { { role = "user", content = "Where is Daisy?" } },
        config = { provider = "gemini", features = { is_book_context = true } }, -- no show_debug_in_chat
        ui = makeUi(),
        on_complete = function(_success, answer) final_answer = answer end,
    })
    TestRunner:assertEqual(final_answer, "Daisy is mentioned in a letter.",
        "answer is clean (no diagnostic blocks) when debug-in-chat is off")
end)

TestRunner:test("queryWith delegates to query_fn when shouldUse is false", function()
    local captured = {}
    local function query_fn(messages, cfg, callback, settings)
        captured.messages = messages
        captured.cfg = cfg
        captured.settings = settings
        callback(true, "direct answer")
    end
    local cfg = {
        provider = "openai", -- not gemini → shouldUse returns false (even with opt-in + consent)
        features = { is_book_context = true, enable_tool_workflows = true, enable_book_text_extraction = true },
    }
    local final
    GeminiToolRunner.queryWith(query_fn, { { role = "user", content = "hi" } }, cfg,
        function(success, answer) final = { success = success, answer = answer } end,
        { settings = "settings-handle" }, makeUi())
    TestRunner:assertEqual(captured.cfg, cfg, "query_fn received the original config")
    TestRunner:assertEqual(captured.settings, "settings-handle", "query_fn received plugin.settings")
    TestRunner:assertTrue(final.success, "direct path success propagated")
    TestRunner:assertEqual(final.answer, "direct answer", "direct path answer propagated")
end)

TestRunner:test("queryWith routes through tool runner when shouldUse is true", function()
    local query_calls = 0
    local function query_fn(_messages, _cfg, callback)
        query_calls = query_calls + 1
        -- First call: function call. Second call: final answer.
        if query_calls == 1 then
            callback(true, {
                _gemini_function_calls = true,
                calls = { { name = "search_book", args = { query = "Alice" } } },
                model_content = {
                    role = "model",
                    parts = { { functionCall = { name = "search_book", args = { query = "Alice" } } } },
                },
            })
        else
            callback(true, "Alice answer")
        end
    end
    local cfg = {
        provider = "gemini",
        features = { is_book_context = true, enable_tool_workflows = true, enable_book_text_extraction = true },
    }
    local final
    GeminiToolRunner.queryWith(query_fn, { { role = "user", content = "Who is Alice?" } }, cfg,
        function(success, answer) final = { success = success, answer = answer } end,
        nil, makeUi())
    TestRunner:assertEqual(query_calls, 2, "tool runner issued initial + final calls")
    TestRunner:assertTrue(final.success, "tool runner success propagated")
    TestRunner:assertTrue(final.answer:find("Alice answer", 1, true) ~= nil,
        "tool runner final answer reaches callback")
end)

TestRunner:test("cancel method sets cancelled flag", function()
    GeminiToolRunner._cancelled = false
    GeminiToolRunner.cancel()
    TestRunner:assertTrue(GeminiToolRunner._cancelled, "cancel sets the flag")
    -- run() resets the flag
    local function query_fn(_messages, _config, callback)
        callback(true, "ok")
    end
    GeminiToolRunner.run({
        query_fn = query_fn,
        messages = { { role = "user", content = "test" } },
        config = { provider = "gemini", features = { is_book_context = true } },
        ui = makeUi(),
        on_complete = function() end,
    })
    TestRunner:assertFalse(GeminiToolRunner._cancelled, "run resets cancelled flag")
end)

return TestRunner:summary()
