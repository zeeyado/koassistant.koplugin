-- Unit tests for the book tool runner (interactive loop + gather mode)

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

local BookToolRunner = require("koassistant_book_tool_runner")
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
print("  Unit Tests: Book Tool Runner")
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
                _tool_calls = true,
                calls = {
                    {
                        name = "search_book",
                        args = { query = "Daisy" },
                    },
                },
                raw_assistant_turn = {
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

    BookToolRunner.run({
        query_fn = query_fn,
        messages = {
            { role = "user", content = "Where is Daisy?" },
        },
        config = {
            provider = "gemini",
            features = {
                is_book_context = true,
                tool_mode = "interactive",  -- exercises the interactive loop explicitly
                -- diagnostics are gated behind their own opt-in; this test asserts they appear
                tool_workflow_diagnostics = true,
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
    TestRunner:assertTrue(final_answer:find("across 2 API calls", 1, true) ~= nil, "call count")
end)

TestRunner:test("spoiler-free off → tools get full-document reading scope", function()
    local scope_message
    local function query_fn(messages, _config, callback)
        scope_message = messages[#messages].content
        callback(true, "ok")
    end
    BookToolRunner.run({
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
    BookToolRunner.run({
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
        BookToolRunner.run({
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

TestRunner:test("runner serializes tool turns with the provider's adapter (anthropic)", function()
    local captured_messages
    local calls = 0
    local function query_fn(messages, _config, callback)
        calls = calls + 1
        if calls == 1 then
            callback(true, {
                _tool_calls = true,
                calls = { { id = "tu1", name = "search_book", args = { query = "Daisy" } } },
                raw_assistant_turn = { role = "assistant", content = {
                    { type = "tool_use", id = "tu1", name = "search_book", input = { query = "Daisy" } },
                } },
            })
        else
            captured_messages = messages
            callback(true, "answer")
        end
    end
    BookToolRunner.run({
        query_fn = query_fn,
        messages = { { role = "user", content = "where is daisy?" } },
        config = { provider = "anthropic", model = "claude-sonnet-4-6",
            features = { is_book_context = true, tool_mode = "interactive" } },
        ui = makeUi(),
        on_complete = function() end,
    })
    local found_tool_result = false
    for _, m in ipairs(captured_messages or {}) do
        if type(m.content) == "table" and m.content[1] and m.content[1].type == "tool_result" then
            found_tool_result = true
        end
    end
    TestRunner:assertTrue(found_tool_result, "anthropic tool_result turn appended via adapter")
end)

TestRunner:test("runner serializes tool turns with the provider's adapter (openai)", function()
    local captured_messages
    local calls = 0
    local function query_fn(messages, _config, callback)
        calls = calls + 1
        if calls == 1 then
            callback(true, {
                _tool_calls = true,
                calls = { { id = "c1", name = "search_book", args = { query = "Daisy" } } },
                raw_assistant_turn = { role = "assistant", content = nil, tool_calls = {
                    { id = "c1", type = "function",
                      ["function"] = { name = "search_book", arguments = "{\"query\":\"Daisy\"}" } },
                } },
            })
        else
            captured_messages = messages
            callback(true, "answer")
        end
    end
    BookToolRunner.run({
        query_fn = query_fn,
        messages = { { role = "user", content = "where is daisy?" } },
        config = { provider = "openai", model = "gpt-5.5",
            features = { is_book_context = true, tool_mode = "interactive" } },
        ui = makeUi(),
        on_complete = function() end,
    })
    local found_echo, found_result = false, false
    for _, m in ipairs(captured_messages or {}) do
        if m.role == "assistant" and m.tool_calls then found_echo = true end
        if m.role == "tool" and m.tool_call_id == "c1" and type(m.content) == "string" then
            found_result = true
        end
    end
    TestRunner:assertTrue(found_echo, "assistant echo keeps tool_calls")
    TestRunner:assertTrue(found_result, "openai role=tool result turn appended via adapter")
end)

TestRunner:test("every tool call in a turn is answered (no mid-turn drop past the cap)", function()
    local captured_messages
    local calls_made = 0
    local function query_fn(messages, _config, callback)
        calls_made = calls_made + 1
        if calls_made == 1 then
            local many, parts = {}, {}
            for i = 1, 10 do
                many[i] = { name = "search_book", args = { query = "q" .. i } }
                parts[i] = { functionCall = { name = "search_book", args = { query = "q" .. i } } }
            end
            callback(true, { _tool_calls = true, calls = many,
                raw_assistant_turn = { role = "model", parts = parts } })
        else
            captured_messages = messages
            callback(true, "answer")
        end
    end
    BookToolRunner.run({
        query_fn = query_fn,
        messages = { { role = "user", content = "hi" } },
        config = { provider = "gemini", features = { is_book_context = true, tool_mode = "interactive" } },
        ui = makeUi(),
        on_complete = function() end,
    })
    local answered = 0
    for _, m in ipairs(captured_messages or {}) do
        if m.role == "tool" and m.parts then answered = #m.parts end
    end
    TestRunner:assertEqual(answered, 10, "all 10 tool_use calls answered despite MAX_TOOL_CALLS=8")
end)

TestRunner:test("shouldUse skips when _xray_chat_active is set", function()
    local cfg = {
        provider = "gemini",
        features = { is_book_context = true, _xray_chat_active = true,
            -- opt-in + consent satisfied so _xray_chat_active is the isolated cause
            tools_posture = "auto", enable_book_text_extraction = true },
    }
    TestRunner:assertFalse(BookToolRunner.shouldUse(cfg, makeUi()),
        "x-ray chat session must skip book tools")
end)

TestRunner:test("shouldUse follows the tools posture when no session choice exists", function()
    local cfg = {
        provider = "gemini",
        features = { is_book_context = true, enable_book_text_extraction = true },
    }
    TestRunner:assertTrue(BookToolRunner.shouldUse(cfg, makeUi()),
        "default posture (auto, schema default) activates tools when consent+capability hold")
    cfg.features.tools_posture = "manual"
    TestRunner:assertFalse(BookToolRunner.shouldUse(cfg, makeUi()),
        "manual posture does not auto-activate tools")
    cfg.features.tools_posture = "off"
    TestRunner:assertFalse(BookToolRunner.shouldUse(cfg, makeUi()),
        "off posture does not activate tools")
    cfg.features.tools_posture = "auto"
    TestRunner:assertTrue(BookToolRunner.shouldUse(cfg, makeUi()),
        "auto posture activates tools when consent + capability are satisfied")
end)

TestRunner:test("shouldUse honours a per-book posture override via ui.doc_settings", function()
    local cfg = {
        provider = "gemini",
        features = { is_book_context = true, enable_book_text_extraction = true,
            tools_posture = "manual" },
    }
    local ui = makeUi()
    ui.doc_settings = {
        readSetting = function(_self, key)
            if key == "koassistant_book_tools" then return "auto" end
        end,
    }
    TestRunner:assertTrue(BookToolRunner.shouldUse(cfg, ui),
        "per-book auto override wins over global manual")
    ui.doc_settings = {
        readSetting = function(_self, key)
            if key == "koassistant_book_tools" then return "off" end
        end,
    }
    cfg.features.tools_posture = "auto"
    TestRunner:assertFalse(BookToolRunner.shouldUse(cfg, ui),
        "per-book off override wins over global auto")
end)

TestRunner:test("shouldUse respects the text-extraction consent gate", function()
    local cfg = {
        provider = "gemini",
        features = { is_book_context = true, tools_posture = "auto" },
    }
    TestRunner:assertFalse(BookToolRunner.shouldUse(cfg, makeUi()),
        "no tools when book-text extraction is not allowed")
    cfg.features.enable_book_text_extraction = true
    TestRunner:assertTrue(BookToolRunner.shouldUse(cfg, makeUi()),
        "tools allowed once extraction consent is granted")
end)

TestRunner:test("shouldUse lets a trusted provider bypass the extraction gate", function()
    local cfg = {
        provider = "gemini",
        features = {
            is_book_context = true,
            tools_posture = "auto",
            -- extraction OFF, but the provider is trusted
            trusted_providers = { "gemini" },
        },
    }
    TestRunner:assertTrue(BookToolRunner.shouldUse(cfg, makeUi()),
        "trusted provider bypasses the extraction-consent gate")
end)

TestRunner:test("shouldUse requires a tools-capable provider/model with an adapter", function()
    local base = { is_book_context = true, tools_posture = "auto", enable_book_text_extraction = true }
    -- gemini + a tools-capable model → eligible
    TestRunner:assertTrue(BookToolRunner.shouldUse(
        { provider = "gemini", model = "gemini-3.5-flash", features = base }, makeUi()),
        "gemini tools-capable model is eligible")
    -- anthropic (Phase 2) + a tools-capable model → eligible
    TestRunner:assertTrue(BookToolRunner.shouldUse(
        { provider = "anthropic", model = "claude-sonnet-4-6", features = base }, makeUi()),
        "anthropic tools-capable model is eligible")
    -- openai (Phase 3) + a tools-capable model → eligible
    TestRunner:assertTrue(BookToolRunner.shouldUse(
        { provider = "openai", model = "gpt-5.5", features = base }, makeUi()),
        "openai tools-capable model is eligible")
    -- provider with no tools capability / adapter → gated off (falls through to normal path)
    TestRunner:assertFalse(BookToolRunner.shouldUse(
        { provider = "mistral", model = "mistral-large-2", features = base }, makeUi()),
        "provider without tools capability/adapter is gated off")
    -- gemini but a model lacking the tools capability → gated off
    TestRunner:assertFalse(BookToolRunner.shouldUse(
        { provider = "gemini", model = "gemini-1.0-ancient", features = base }, makeUi()),
        "gemini non-tools model is gated off")
end)

TestRunner:test("diagnostics are suppressed unless tool_workflow_diagnostics is set", function()
    local calls = 0
    local function query_fn(_messages, _config, callback)
        calls = calls + 1
        if calls == 1 then
            callback(true, {
                _tool_calls = true,
                calls = { { name = "search_book", args = { query = "Daisy" } } },
                raw_assistant_turn = { role = "model", parts = {
                    { functionCall = { name = "search_book", args = { query = "Daisy" } } } } },
            }, nil, nil, nil, { input_tokens = 10, output_tokens = 3, total_tokens = 13 })
        else
            callback(true, "Daisy is mentioned in a letter.", nil, nil, nil,
                { input_tokens = 20, output_tokens = 5, total_tokens = 25 })
        end
    end
    local final_answer
    BookToolRunner.run({
        query_fn = query_fn,
        messages = { { role = "user", content = "Where is Daisy?" } },
        config = { provider = "gemini", features = { is_book_context = true, tool_mode = "interactive" } }, -- no show_debug_in_chat
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
        provider = "mistral", -- no tools capability/adapter → shouldUse returns false (even with opt-in + consent)
        features = { is_book_context = true, tools_posture = "auto", enable_book_text_extraction = true },
    }
    local final
    BookToolRunner.queryWith(query_fn, { { role = "user", content = "hi" } }, cfg,
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
                _tool_calls = true,
                calls = { { name = "search_book", args = { query = "Alice" } } },
                raw_assistant_turn = {
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
        features = { is_book_context = true, tools_posture = "auto", enable_book_text_extraction = true,
            tool_mode = "interactive" },
    }
    local final
    BookToolRunner.queryWith(query_fn, { { role = "user", content = "Who is Alice?" } }, cfg,
        function(success, answer) final = { success = success, answer = answer } end,
        nil, makeUi())
    TestRunner:assertEqual(query_calls, 2, "tool runner issued initial + final calls")
    TestRunner:assertTrue(final.success, "tool runner success propagated")
    TestRunner:assertTrue(final.answer:find("Alice answer", 1, true) ~= nil,
        "tool runner final answer reaches callback")
end)

-- ============================================================
-- Gather mode (D2 — gather_then_generate_plan.md)
-- ============================================================

-- Shared helper: gather-mode config. enable_streaming=false keeps the status window
-- out of unit tests (the dialog path is UI-only); gather is also the schema default,
-- set explicitly here for clarity.
local function gatherConfig(extra)
    local features = {
        is_book_context = true,
        tool_mode = "gather",
        enable_streaming = false,
    }
    for k, v in pairs(extra or {}) do features[k] = v end
    return { provider = "gemini", features = features }
end

local function searchCallAnswer(query)
    return {
        _tool_calls = true,
        calls = { { name = "search_book", args = { query = query } } },
        raw_assistant_turn = { role = "model", parts = {
            { functionCall = { name = "search_book", args = { query = query } } } } },
    }
end

local function doneAnswer()
    return {
        _tool_calls = true,
        calls = { { name = "done", args = {} } },
        raw_assistant_turn = { role = "model", parts = {
            { functionCall = { name = "done", args = {} } } } },
    }
end

TestRunner:test("gather: done triggers a fresh generate call with bundle, no tools", function()
    local calls = 0
    local gen_messages, gen_config
    local final
    local function query_fn(messages, config, callback)
        calls = calls + 1
        if calls == 1 then
            callback(true, searchCallAnswer("Daisy"))
        elseif calls == 2 then
            callback(true, doneAnswer())
        else
            gen_messages, gen_config = messages, config
            callback(true, "The generated answer.")
        end
    end
    BookToolRunner.run({
        query_fn = query_fn,
        messages = { { role = "user", content = "Where is Daisy?" } },
        config = gatherConfig(),
        ui = makeUi(),
        on_complete = function(success, answer) final = { success = success, answer = answer } end,
    })
    TestRunner:assertEqual(calls, 3, "two gather rounds + one generate")
    TestRunner:assertTrue(gen_config.tools == nil, "generate request declares no tools")
    TestRunner:assertEqual(gen_config.features.enable_streaming, false,
        "generate keeps the user's streaming setting (not force-disabled)")
    -- Fresh history: no provider-native tool turns
    local has_tool_turn = false
    local bundle_idx, question_idx
    for i, m in ipairs(gen_messages) do
        if m.role == "tool" or (m.parts ~= nil) then has_tool_turn = true end
        if m.is_context and type(m.content) == "string"
            and m.content:find("Passages retrieved from the book", 1, true) then
            bundle_idx = i
        end
        if m.role == "user" and not m.is_context then question_idx = i end
    end
    TestRunner:assertFalse(has_tool_turn, "generate history contains no tool turns")
    TestRunner:assertTrue(bundle_idx ~= nil, "bundle context message present")
    TestRunner:assertTrue(question_idx ~= nil and bundle_idx < question_idx,
        "bundle inserted before the user question")
    TestRunner:assertTrue(final.success, "gather flow completes successfully")
    TestRunner:assertTrue(final.answer:find("Searched the book — 1 lookup", 1, true) ~= nil,
        "lookup indicator line appended")
end)

TestRunner:test("gather: immediate done (zero lookups) → plain generate, no bundle/indicator", function()
    local calls = 0
    local gen_messages
    local final
    local function query_fn(messages, _config, callback)
        calls = calls + 1
        if calls == 1 then
            callback(true, doneAnswer())
        else
            gen_messages = messages
            callback(true, "Plain answer.")
        end
    end
    BookToolRunner.run({
        query_fn = query_fn,
        messages = { { role = "user", content = "What do you think of the title?" } },
        config = gatherConfig(),
        ui = makeUi(),
        on_complete = function(_s, answer) final = answer end,
    })
    TestRunner:assertEqual(calls, 2, "one gather probe + one generate")
    for _i, m in ipairs(gen_messages) do
        TestRunner:assertFalse(type(m.content) == "string"
            and m.content:find("Passages retrieved", 1, true) ~= nil,
            "no bundle message for a zero-lookup question")
    end
    TestRunner:assertEqual(final, "Plain answer.", "no indicator line when nothing was searched")
end)

TestRunner:test("gather: done alongside lookups in one turn executes the lookups first", function()
    local calls = 0
    local gen_messages
    local function query_fn(messages, _config, callback)
        calls = calls + 1
        if calls == 1 then
            callback(true, {
                _tool_calls = true,
                calls = {
                    { name = "search_book", args = { query = "Daisy" } },
                    { name = "done", args = {} },
                },
                raw_assistant_turn = { role = "model", parts = {} },
            })
        else
            gen_messages = messages
            callback(true, "answer")
        end
    end
    BookToolRunner.run({
        query_fn = query_fn,
        messages = { { role = "user", content = "Where is Daisy?" } },
        config = gatherConfig(),
        ui = makeUi(),
        on_complete = function() end,
    })
    TestRunner:assertEqual(calls, 2, "mixed done turn goes straight to generate")
    local has_bundle = false
    for _i, m in ipairs(gen_messages) do
        if type(m.content) == "string" and m.content:find("Passages retrieved", 1, true) then
            has_bundle = true
        end
    end
    TestRunner:assertTrue(has_bundle, "the non-done lookups in the done turn reach the bundle")
end)

TestRunner:test("gather: budget exhaustion generates from what was gathered", function()
    local calls = 0
    local gen_messages
    local function query_fn(messages, _config, callback)
        calls = calls + 1
        if calls <= 4 then  -- MAX_TOOL_TURNS rounds, never calls done
            callback(true, searchCallAnswer("q" .. calls))
        else
            gen_messages = messages
            callback(true, "capped answer")
        end
    end
    BookToolRunner.run({
        query_fn = query_fn,
        messages = { { role = "user", content = "everything about everything" } },
        config = gatherConfig(),
        ui = makeUi(),
        on_complete = function() end,
    })
    TestRunner:assertEqual(calls, 5, "4 gather rounds (MAX_TOOL_TURNS) + generate")
    local has_bundle, has_tool_turn = false, false
    for _i, m in ipairs(gen_messages) do
        if type(m.content) == "string" and m.content:find("Passages retrieved", 1, true) then
            has_bundle = true
        end
        if m.role == "tool" or m.parts ~= nil then has_tool_turn = true end
    end
    TestRunner:assertTrue(has_bundle, "bundle built from pre-cap lookups")
    TestRunner:assertFalse(has_tool_turn, "no tool-turn replay in generate history")
end)

TestRunner:test("gather: duplicate lookups deduplicate in the bundle", function()
    local calls = 0
    local gen_messages
    local function query_fn(messages, _config, callback)
        calls = calls + 1
        if calls <= 2 then
            -- Same query twice → identical formatted sections → one bundle section
            callback(true, searchCallAnswer("Daisy"))
        elseif calls == 3 then
            callback(true, doneAnswer())
        else
            gen_messages = messages
            callback(true, "answer")
        end
    end
    BookToolRunner.run({
        query_fn = query_fn,
        messages = { { role = "user", content = "Where is Daisy?" } },
        config = gatherConfig(),
        ui = makeUi(),
        on_complete = function() end,
    })
    local bundle
    for _i, m in ipairs(gen_messages) do
        if type(m.content) == "string" and m.content:find("Passages retrieved", 1, true) then
            bundle = m.content
        end
    end
    local _count_str, section_count = bundle:gsub("search_book: 1 query", "")
    TestRunner:assertEqual(section_count, 1, "identical sections appear once in the bundle")
end)

TestRunner:test("gather: prose response in gather phase is accepted as the answer", function()
    local calls = 0
    local final
    local function query_fn(_messages, _config, callback)
        calls = calls + 1
        callback(true, "I ignored the gather protocol and just answered.")
    end
    BookToolRunner.run({
        query_fn = query_fn,
        messages = { { role = "user", content = "hi" } },
        config = gatherConfig(),
        ui = makeUi(),
        on_complete = function(success, answer) final = { success = success, answer = answer } end,
    })
    TestRunner:assertEqual(calls, 1, "no extra generate round for a prose answer")
    TestRunner:assertTrue(final.success, "prose answer accepted")
    TestRunner:assertEqual(final.answer, "I ignored the gather protocol and just answered.",
        "answer passed through unchanged (no indicator — no lookups ran)")
end)

TestRunner:test("gather: gather rounds declare the done tool; instructions injected", function()
    local calls = 0
    local gather_config
    local function query_fn(_messages, config, callback)
        calls = calls + 1
        if calls == 1 then
            gather_config = config
            callback(true, doneAnswer())
        else
            callback(true, "answer")
        end
    end
    BookToolRunner.run({
        query_fn = query_fn,
        messages = { { role = "user", content = "hi" } },
        config = gatherConfig(),
        ui = makeUi(),
        on_complete = function() end,
    })
    local has_done = false
    for _i, spec in ipairs(gather_config.tools.specs) do
        if spec.name == "done" then has_done = true end
    end
    TestRunner:assertTrue(has_done, "gather declarations include the done tool")
    TestRunner:assertEqual(gather_config.tools.mode, "ANY",
        "gather rounds force a tool call (mode ANY) so prose can't bypass streamed phase 2")
    TestRunner:assertEqual(gather_config.features.enable_streaming, false,
        "gather rounds are non-streaming")
    TestRunner:assertTrue(gather_config.system.text:find("GATHER PHASE", 1, true) ~= nil,
        "gather instructions injected")
end)

-- ============================================================
-- Per-chat activation (D1) — _tools_active override
-- ============================================================

TestRunner:test("shouldUse: session checkbox overrides the posture both ways", function()
    -- posture auto, session explicitly unchecked → off
    local cfg = { provider = "gemini", features = {
        is_book_context = true, enable_book_text_extraction = true,
        tools_posture = "auto", _tools_active = false } }
    TestRunner:assertFalse(BookToolRunner.shouldUse(cfg, makeUi()),
        "explicit session false wins over posture auto")
    -- posture manual (unchecked default), session explicitly checked → on
    cfg = { provider = "gemini", features = {
        is_book_context = true, enable_book_text_extraction = true,
        tools_posture = "manual", _tools_active = true } }
    TestRunner:assertTrue(BookToolRunner.shouldUse(cfg, makeUi()),
        "explicit session true wins over posture manual")
    -- session true still can't bypass capability/consent gates
    cfg = { provider = "mistral", model = "mistral-large-2", features = {
        is_book_context = true, enable_book_text_extraction = true, _tools_active = true } }
    TestRunner:assertFalse(BookToolRunner.shouldUse(cfg, makeUi()),
        "session checkbox never bypasses capability gates")
end)

TestRunner:test("sessionEligible: capability+consent+document, independent of activation", function()
    -- eligible despite posture manual (that's the point — the checkbox needs to render)
    local cfg = { provider = "gemini", features = {
        tools_posture = "manual", enable_book_text_extraction = true } }
    TestRunner:assertTrue(BookToolRunner.sessionEligible(cfg, makeUi()),
        "eligible with consent + capable provider even when posture is manual")
    -- reason returns (drive the smart-retrieval row's grayed-out labels)
    local ok_r, why = BookToolRunner.sessionEligible(
        { provider = "mistral", model = "mistral-large-2",
          features = { enable_book_text_extraction = true } }, makeUi())
    TestRunner:assertFalse(ok_r, "incapable provider ineligible")
    TestRunner:assertEqual(why, "provider", "provider reason reported")
    ok_r, why = BookToolRunner.sessionEligible(
        { provider = "gemini", features = {} }, makeUi())
    TestRunner:assertEqual(why, "consent", "consent reason reported")
    ok_r, why = BookToolRunner.sessionEligible(
        { provider = "gemini", features = { enable_book_text_extraction = true } }, nil)
    TestRunner:assertEqual(why, "no_book", "no-book reason reported")
    -- not eligible without extraction consent
    cfg = { provider = "gemini", features = { tools_posture = "auto" } }
    TestRunner:assertFalse(BookToolRunner.sessionEligible(cfg, makeUi()),
        "not eligible without extraction consent")
    -- not eligible without an open document
    cfg = { provider = "gemini", features = { enable_book_text_extraction = true } }
    TestRunner:assertFalse(BookToolRunner.sessionEligible(cfg, nil),
        "not eligible without a ui/document")
end)

TestRunner:test("cancel method sets cancelled flag", function()
    BookToolRunner._cancelled = false
    BookToolRunner.cancel()
    TestRunner:assertTrue(BookToolRunner._cancelled, "cancel sets the flag")
    -- run() resets the flag
    local function query_fn(_messages, _config, callback)
        callback(true, "ok")
    end
    BookToolRunner.run({
        query_fn = query_fn,
        messages = { { role = "user", content = "test" } },
        config = { provider = "gemini", features = { is_book_context = true, tool_mode = "interactive" } },
        ui = makeUi(),
        on_complete = function() end,
    })
    TestRunner:assertFalse(BookToolRunner._cancelled, "run resets cancelled flag")
end)

-- ============================================================
-- Lookup-effort budgets (tools_ux_plan.md §2)
-- ============================================================

TestRunner:test("budgetFor maps the effort dial; unknown/missing fall back to standard", function()
    local q = BookToolRunner.budgetFor({ tool_lookup_effort = "quick" })
    TestRunner:assertEqual(q.turns, 2, "quick turns")
    TestRunner:assertEqual(q.calls, 4, "quick calls")
    TestRunner:assertEqual(q.bundle_chars, 32000, "quick bundle")
    local st = BookToolRunner.budgetFor({})
    TestRunner:assertEqual(st.turns, 4, "standard turns (default)")
    TestRunner:assertEqual(st.calls, 8, "standard calls (default)")
    TestRunner:assertEqual(st.bundle_chars, 32000, "standard bundle")
    local th = BookToolRunner.budgetFor({ tool_lookup_effort = "thorough" })
    TestRunner:assertEqual(th.turns, 6, "thorough turns")
    TestRunner:assertEqual(th.calls, 16, "thorough calls")
    TestRunner:assertEqual(th.bundle_chars, 48000, "thorough bundle")
    local bogus = BookToolRunner.budgetFor({ tool_lookup_effort = "extreme" })
    TestRunner:assertEqual(bogus.calls, 8, "unknown effort value falls back to standard")
    TestRunner:assertEqual(BookToolRunner.budgetFor(nil).calls, 8, "nil features falls back to standard")
end)

TestRunner:test("gather instructions state the total lookup budget", function()
    local first_config
    local function query_fn(_messages, config, callback)
        if not first_config then
            first_config = config
            callback(true, {
                _tool_calls = true,
                calls = { { name = "done", args = {} } },
                raw_assistant_turn = { role = "model", parts = {} },
            })
        else
            callback(true, "answer")
        end
    end
    BookToolRunner.run({
        query_fn = query_fn,
        messages = { { role = "user", content = "hi" } },
        config = { provider = "gemini", features = { is_book_context = true } },
        ui = makeUi(),
        on_complete = function() end,
    })
    TestRunner:assertTrue(
        first_config.system.text:find("You may use at most 8 lookups in total.", 1, true) ~= nil,
        "standard budget stated in the gather instructions")

    first_config = nil
    BookToolRunner.run({
        query_fn = query_fn,
        messages = { { role = "user", content = "hi" } },
        config = { provider = "gemini",
            features = { is_book_context = true, tool_lookup_effort = "quick" } },
        ui = makeUi(),
        on_complete = function() end,
    })
    TestRunner:assertTrue(
        first_config.system.text:find("You may use at most 4 lookups in total.", 1, true) ~= nil,
        "quick budget stated in the gather instructions")
end)

TestRunner:test("the round's last tool result carries the remaining lookup budget", function()
    local calls = 0
    local second_round_messages
    local function query_fn(messages, _config, callback)
        calls = calls + 1
        if calls == 1 then
            callback(true, {
                _tool_calls = true,
                calls = { { name = "search_book", args = { query = "Daisy" } } },
                raw_assistant_turn = { role = "model", parts = {
                    { functionCall = { name = "search_book", args = { query = "Daisy" } } } } },
            })
        elseif calls == 2 then
            second_round_messages = messages
            callback(true, {
                _tool_calls = true,
                calls = { { name = "done", args = {} } },
                raw_assistant_turn = { role = "model", parts = {} },
            })
        else
            callback(true, "answer")
        end
    end
    BookToolRunner.run({
        query_fn = query_fn,
        messages = { { role = "user", content = "Where is Daisy?" } },
        config = { provider = "gemini", features = { is_book_context = true } },
        ui = makeUi(),
        on_complete = function() end,
    })
    local budget_note
    for _idx, m in ipairs(second_round_messages or {}) do
        if m.role == "tool" and m.parts then
            for _jdx, part in ipairs(m.parts) do
                local resp = part.functionResponse and part.functionResponse.response
                if type(resp) == "table" and resp.lookup_budget then
                    budget_note = resp.lookup_budget
                end
            end
        end
    end
    TestRunner:assertEqual(budget_note, "7 of 8 lookups remaining",
        "remaining budget rides the round's last tool result")
end)

TestRunner:test("quick effort caps the gather loop at 2 turns", function()
    local calls = 0
    local final_answer
    local function query_fn(_messages, _config, callback)
        calls = calls + 1
        if calls <= 2 then
            -- never call done: only the budget can end the gather phase
            callback(true, {
                _tool_calls = true,
                calls = { { name = "search_book", args = { query = "rabbit" } } },
                raw_assistant_turn = { role = "model", parts = {
                    { functionCall = { name = "search_book", args = { query = "rabbit" } } } } },
            })
        else
            callback(true, "capped answer")
        end
    end
    BookToolRunner.run({
        query_fn = query_fn,
        messages = { { role = "user", content = "hi" } },
        config = { provider = "gemini",
            features = { is_book_context = true, tool_lookup_effort = "quick" } },
        ui = makeUi(),
        on_complete = function(_success, answer) final_answer = answer end,
    })
    TestRunner:assertEqual(calls, 3, "2 gather rounds + 1 generate call under the quick budget")
    TestRunner:assertTrue(final_answer:find("capped answer", 1, true) ~= nil, "answer from phase 2")
    TestRunner:assertTrue(final_answer:find("2 lookups", 1, true) ~= nil,
        "lookups note reflects the capped session")
end)

-- ============================================================
-- gatherForAction (D3 smart retrieval — tools_ux_plan.md §4)
-- ============================================================

TestRunner:test("gatherForAction: search then done returns the bundle and call count", function()
    local calls = 0
    local first_config
    local function query_fn(_messages, config, callback)
        calls = calls + 1
        if calls == 1 then
            first_config = config
            callback(true, {
                _tool_calls = true,
                calls = { { name = "search_book", args = { query = "Daisy" } } },
                raw_assistant_turn = { role = "model", parts = {
                    { functionCall = { name = "search_book", args = { query = "Daisy" } } } } },
            })
        else
            callback(true, {
                _tool_calls = true,
                calls = { { name = "done", args = {} } },
                raw_assistant_turn = { role = "model", parts = {} },
            })
        end
    end
    local got_bundle, got_info
    BookToolRunner.gatherForAction({
        question = "Task: Explain in Context\n\nSelected passage:\nDaisy",
        query_fn = query_fn,
        config = { provider = "gemini", features = { is_book_context = true } },
        ui = makeUi(),
        on_complete = function(bundle, info) got_bundle, got_info = bundle, info end,
    })
    TestRunner:assertEqual(calls, 2, "two gather rounds, no generate phase")
    TestRunner:assertTrue(type(got_bundle) == "string" and #got_bundle > 0, "bundle returned")
    TestRunner:assertTrue(got_bundle:find("Daisy", 1, true) ~= nil, "bundle carries the hit")
    TestRunner:assertEqual(got_info.tool_calls, 1, "lookup count reported")
    TestRunner:assertTrue(first_config.system.text:find("GATHER PHASE", 1, true) ~= nil,
        "gather instructions used")
    TestRunner:assertEqual(first_config.tools.mode, "ANY", "gather rounds force a tool call")
end)

TestRunner:test("gatherForAction: immediate done returns an empty bundle (zero-gather)", function()
    local function query_fn(_messages, _config, callback)
        callback(true, {
            _tool_calls = true,
            calls = { { name = "done", args = {} } },
            raw_assistant_turn = { role = "model", parts = {} },
        })
    end
    local got_bundle, got_info
    BookToolRunner.gatherForAction({
        question = "q",
        query_fn = query_fn,
        config = { provider = "gemini", features = { is_book_context = true } },
        ui = makeUi(),
        on_complete = function(bundle, info) got_bundle, got_info = bundle, info end,
    })
    TestRunner:assertEqual(got_bundle, "", "zero-gather yields empty string, not nil")
    TestRunner:assertEqual(got_info.tool_calls, 0, "no lookups")
end)

TestRunner:test("gatherForAction: request failure reports error, nil bundle", function()
    local function query_fn(_messages, _config, callback)
        callback(false, nil, "boom")
    end
    local got_bundle, got_info
    BookToolRunner.gatherForAction({
        question = "q",
        query_fn = query_fn,
        config = { provider = "gemini", features = { is_book_context = true } },
        ui = makeUi(),
        on_complete = function(bundle, info) got_bundle, got_info = bundle, info end,
    })
    TestRunner:assertEqual(got_bundle, nil, "nil bundle on failure")
    TestRunner:assertEqual(got_info.error, "boom", "error message surfaced")
end)

TestRunner:test("gatherForAction: budget caps the loop and delivers what was gathered", function()
    local calls = 0
    local function query_fn(_messages, _config, callback)
        calls = calls + 1
        -- never call done: only the budget can end the loop
        callback(true, {
            _tool_calls = true,
            calls = { { name = "search_book", args = { query = "rabbit" } } },
            raw_assistant_turn = { role = "model", parts = {
                { functionCall = { name = "search_book", args = { query = "rabbit" } } } } },
        })
    end
    local got_bundle, got_info
    BookToolRunner.gatherForAction({
        question = "q",
        query_fn = query_fn,
        config = { provider = "gemini",
            features = { is_book_context = true, tool_lookup_effort = "quick" } },
        ui = makeUi(),
        on_complete = function(bundle, info) got_bundle, got_info = bundle, info end,
    })
    TestRunner:assertEqual(calls, 2, "quick budget stops after 2 rounds — no extra request")
    TestRunner:assertTrue(type(got_bundle) == "string" and #got_bundle > 0, "partial bundle delivered")
    TestRunner:assertEqual(got_info.tool_calls, 2, "both lookups counted")
end)

TestRunner:test("smartRetrievalAllowed: posture off is the master switch", function()
    local base = { provider = "gemini",
        features = { enable_book_text_extraction = true } }
    local ok, why = BookToolRunner.smartRetrievalAllowed(base, makeUi())
    TestRunner:assertTrue(ok, "eligible session with default (auto) posture allowed")
    base.features.tools_posture = "manual"
    TestRunner:assertTrue(BookToolRunner.smartRetrievalAllowed(base, makeUi()),
        "manual posture allows per-action smart retrieval")
    base.features.tools_posture = "off"
    ok, why = BookToolRunner.smartRetrievalAllowed(base, makeUi())
    TestRunner:assertFalse(ok, "posture off gates smart retrieval")
    TestRunner:assertEqual(why, "posture_off", "posture reason reported")
    -- per-book off wins over global manual
    base.features.tools_posture = "manual"
    local ui = makeUi()
    ui.doc_settings = {
        readSetting = function(_self, key)
            if key == "koassistant_book_tools" then return "off" end
        end,
    }
    ok, why = BookToolRunner.smartRetrievalAllowed(base, ui)
    TestRunner:assertFalse(ok, "per-book off gates smart retrieval")
    TestRunner:assertEqual(why, "posture_off", "per-book posture reason reported")
    -- ineligibility reasons pass through unchanged
    ok, why = BookToolRunner.smartRetrievalAllowed(
        { provider = "gemini", features = {} }, makeUi())
    TestRunner:assertEqual(why, "consent", "sessionEligible reasons pass through")
end)

return TestRunner:summary()
