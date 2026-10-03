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

TestRunner:test("spoiler protection off → tools get full-document reading scope", function()
    local scope_message
    local function query_fn(messages, _config, callback)
        scope_message = messages[#messages].content
        callback(true, "ok")
    end
    BookToolRunner.run({
        query_fn = query_fn,
        messages = { { role = "user", content = "hi" } },
        -- §4.3 flip: opting out now takes an explicit false
        config = { provider = "gemini", features = { is_book_context = true, spoiler_free_chat = false, tool_whole_text = false } },
        ui = makeUi(),
        on_complete = function() end,
    })
    TestRunner:assertTrue(scope_message:find("read the entire document", 1, true) ~= nil,
        "full-scope scope message")
end)

TestRunner:test("nothing set → tools clamp by default (the §4.3 flip)", function()
    local scope_message
    local function query_fn(messages, _config, callback)
        scope_message = messages[#messages].content
        callback(true, "ok")
    end
    BookToolRunner.run({
        query_fn = query_fn,
        messages = { { role = "user", content = "hi" } },
        config = { provider = "gemini", features = { is_book_context = true, tool_whole_text = false } },
        ui = makeUi(),
        on_complete = function() end,
    })
    TestRunner:assertTrue(scope_message:find("Do not request or infer content after page", 1, true) ~= nil,
        "default-protected scope message clamps")
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
        config = { provider = "gemini", features = { is_book_context = true, spoiler_free_chat = true, tool_whole_text = false } },
        ui = makeUi(),
        on_complete = function() end,
    })
    TestRunner:assertTrue(scope_message:find("Do not request or infer content after page", 1, true) ~= nil,
        "current-scope scope message clamps")
end)

TestRunner:test("session spoiler checkbox overrides global for tool scope", function()
    local function scope_msg_for(features)
        local captured
        features.tool_whole_text = false
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
    TestRunner:assertFalse(BookToolRunner.shouldUse(cfg, makeUi()),
        "untouched default (off since the 2026-08-17 flip) does not activate tools")
    cfg.features.enable_book_tools = true
    TestRunner:assertTrue(BookToolRunner.shouldUse(cfg, makeUi()),
        "explicit global on activates tools when consent+capability hold")
    cfg.features.enable_book_tools = nil
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
    -- tools wave 1 providers + capable models → eligible
    TestRunner:assertTrue(BookToolRunner.shouldUse(
        { provider = "deepseek", model = "deepseek-v4-pro", features = base }, makeUi()),
        "deepseek tools-capable model is eligible")
    TestRunner:assertTrue(BookToolRunner.shouldUse(
        { provider = "mistral", model = "mistral-large-latest", features = base }, makeUi()),
        "mistral tools-capable model is eligible")
    TestRunner:assertTrue(BookToolRunner.shouldUse(
        { provider = "groq", model = "llama-3.3-70b-versatile", features = base }, makeUi()),
        "groq tools-capable model is eligible")
    TestRunner:assertTrue(BookToolRunner.shouldUse(
        { provider = "xai", model = "grok-4.5", features = base }, makeUi()),
        "xai tools-capable model is eligible (chat wire)")
    -- groq compound rejects user-defined tools → gated off
    TestRunner:assertFalse(BookToolRunner.shouldUse(
        { provider = "groq", model = "groq/compound", features = base }, makeUi()),
        "groq compound (built-in tools only) is gated off")
    -- provider with no tools capability / adapter → gated off (falls through to normal path)
    TestRunner:assertFalse(BookToolRunner.shouldUse(
        { provider = "perplexity", model = "sonar-pro", features = base }, makeUi()),
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
        provider = "perplexity", -- no tools capability/adapter → shouldUse returns false (even with opt-in + consent)
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
        -- The two-page test book always fits the whole-text budget; the round-based
        -- tests below opt out so the rounds they exercise still run.
        tool_whole_text = false,
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
        on_complete = function(success, answer, _err, _reasoning, provenance)
            final = { success = success, answer = answer, provenance = provenance }
        end,
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
    TestRunner:assertEqual(final.answer, "The generated answer.",
        "answer text stays clean (no baked-in lookup note)")
    TestRunner:assertTrue(type(final.provenance) == "table"
        and type(final.provenance.book_tools) == "table"
        and final.provenance.book_tools.lookups == 1,
        "lookup count rides the provenance slot (5th arg)")
    TestRunner:assertTrue(type(final.provenance.book_tools.trace) == "table"
        and #final.provenance.book_tools.trace == 1,
        "per-lookup trace rides the provenance slot")
    TestRunner:assertTrue(final.provenance.web_search == nil,
        "tool-only provenance does not claim web search")
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
        on_complete = function(_s, answer, _err, _reasoning, provenance)
            final = { answer = answer, provenance = provenance }
        end,
    })
    TestRunner:assertEqual(calls, 2, "one gather probe + one generate")
    for _i, m in ipairs(gen_messages) do
        TestRunner:assertFalse(type(m.content) == "string"
            and m.content:find("Passages retrieved", 1, true) ~= nil,
            "no bundle message for a zero-lookup question")
    end
    TestRunner:assertEqual(final.answer, "Plain answer.", "answer text unchanged")
    TestRunner:assertTrue(final.provenance == nil,
        "no provenance when nothing was searched")
end)

TestRunner:test("gather: empty bundle note mentions web search when available", function()
    -- All lookups fail (unknown tool → ok=false → skipped by the bundle) so the
    -- honest "[Book lookup note]" fires; with web search on it must not read as an
    -- instruction to skip searching.
    local function run(features_extra)
        local calls = 0
        local gen_messages
        local function query_fn(messages, _config, callback)
            calls = calls + 1
            if calls == 1 then
                callback(true, {
                    _tool_calls = true,
                    calls = { { name = "bogus", args = {} } },
                    raw_assistant_turn = { role = "model", parts = {} },
                })
            elseif calls == 2 then
                callback(true, doneAnswer())
            else
                gen_messages = messages
                callback(true, "answer")
            end
        end
        local features = { is_book_context = true, tool_mode = "gather", tool_whole_text = false,
            enable_streaming = false }
        for k, v in pairs(features_extra or {}) do features[k] = v end
        BookToolRunner.run({
            query_fn = query_fn,
            messages = { { role = "user", content = "who were his parents?" } },
            config = { provider = "anthropic", features = features },
            ui = makeUi(),
            on_complete = function() end,
        })
        for _i, m in ipairs(gen_messages or {}) do
            if m.is_context and type(m.content) == "string"
                and m.content:find("Book lookup note", 1, true) then
                return m.content
            end
        end
        return nil
    end

    local with_web = run({ enable_web_search = true })
    TestRunner:assertTrue(with_web ~= nil, "note present with web on")
    TestRunner:assertTrue(with_web:find("Search the web", 1, true) ~= nil,
        "web-aware wording when web search is available")

    local without_web = run({ enable_web_search = false })
    TestRunner:assertTrue(without_web ~= nil, "note present with web off")
    TestRunner:assertTrue(without_web:find("Search the web", 1, true) == nil,
        "no web mention when web search is off")
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

TestRunner:test("gather: tool notes ride the phase-2 context block as lookup limits", function()
    local calls = 0
    local gen_messages
    local function query_fn(messages, _config, callback)
        calls = calls + 1
        if calls == 1 then
            callback(true, searchCallAnswer("Daisy"))
        elseif calls == 2 then
            callback(true, doneAnswer())
        else
            gen_messages = messages
            callback(true, "answer")
        end
    end
    local ui = makeUi()
    ui.view.state.page = 1  -- reader on page 1 of 2, spoiler protection on by default
    BookToolRunner.run({
        query_fn = query_fn,
        messages = { { role = "user", content = "Where is Daisy?" } },
        config = gatherConfig(),
        ui = ui,
        on_complete = function() end,
    })
    local bundle
    for _i, m in ipairs(gen_messages) do
        if type(m.content) == "string" and m.content:find("Passages retrieved", 1, true) then
            bundle = m.content
        end
    end
    TestRunner:assertTrue(bundle ~= nil, "bundle present")
    TestRunner:assertTrue(bundle:find("[Lookup limits]", 1, true) ~= nil, "lookup limits trailer present")
    TestRunner:assertTrue(bundle:find("pages 1-1 of 2 only", 1, true) ~= nil, "the range note is listed")
    TestRunner:assertTrue(bundle:find("only where it could change the answer", 1, true) ~= nil, "instruction to relay it only where it matters")
    local notes = BookToolRunner._collectNotes({ { executed = { { call = { name = "toc" },
        result = { notes = { "a", "b" }, queries = { { notes = { "b", "c" }, error = "The lookup budget for this call was spent" } }, results = { { notes = { "d" } } } } } } } })
    TestRunner:assertEqual(#notes, 5, "distinct notes across result, block and target levels, plus a block error")
    -- Routine caps never reach the reader's answer: no trailer when every note is routine.
    local routine = BookToolRunner._collectNotes({ { executed = { { call = { name = "search_book" },
        result = { queries = { { notes = {
            "Showing 12 of 42 hits for \"x\" (highest scoring first, at most 2 per page); total_hits is the exact count.",
            "page_summary lists the first 40 of 90 pages with hits.",
            "3 of the shown hits contain only some of the query words (match_type partial; the missing words are listed). Full matches rank above them.",
        } } }, results = { { notes = { "The passage was cut to 8000 characters; ask for fewer pages or a narrower target for the rest." } } } } } } } })
    TestRunner:assertEqual(#routine, 0, "routine notes filtered")
    TestRunner:assertEqual(BookToolRunner._lookupLimitsBlock({ { executed = { { call = { name = "search_book" },
        result = { notes = { "Showing 12 of 42 hits for \"x\" (highest scoring first, at most 2 per page); total_hits is the exact count." } } } } } }), nil, "no trailer for routine notes")
end)

TestRunner:test("summarizeToolCall: a toc line shows the filters that produced it", function()
    local line = BookToolRunner._summarizeToolCall({ name = "toc", args = { title_contains = "four archetypes", max_depth = 2 } }, { entry_count = 0 })
    TestRunner:assertEqual(line, 'toc: 0 entries (title contains "four archetypes", depth <= 2)', "filters shown")
    TestRunner:assertEqual(BookToolRunner._summarizeToolCall({ name = "toc" }, { entry_count = 3 }), "toc: 3 entries", "plain when unfiltered")
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

TestRunner:test("scope message names the book language and outlines the contents", function()
    local first_messages
    local calls = 0
    local function query_fn(messages, _config, callback)
        calls = calls + 1
        if calls == 1 then
            first_messages = messages
            callback(true, doneAnswer())
        else
            callback(true, "answer")
        end
    end
    local ui = makeUi()
    ui.doc_props = { language = "de" }
    ui.toc = { toc = {
        { title = "Erster Teil", page = 1, depth = 1 },
        { title = "Kapitel 1", page = 1, depth = 2 },
        { title = "Zweiter Teil", page = 2, depth = 1 },
    } }
    BookToolRunner.run({
        query_fn = query_fn,
        messages = { { role = "user", content = "what happens in the garden?" } },
        config = gatherConfig({ book_text_language = "metadata" }),
        ui = ui,
        on_complete = function() end,
    })
    local scope_msg
    for _i, msg in ipairs(first_messages or {}) do
        if type(msg.content) == "string" and msg.content:find("[Book tool scope]", 1, true) then
            scope_msg = msg
        end
    end
    TestRunner:assertTrue(scope_msg ~= nil, "scope message sent on round one")
    TestRunner:assertEqual(scope_msg.is_context, true, "rides as context")
    TestRunner:assertTrue(scope_msg.content:find("Book text language: de.", 1, true) ~= nil, "language named")
    TestRunner:assertTrue(scope_msg.content:find("queries in the language of the book text", 1, true) ~= nil, "query-language rule")
    TestRunner:assertTrue(scope_msg.content:find("Contents outline (3 of 3 entries", 1, true) ~= nil, "outline header")
    TestRunner:assertTrue(scope_msg.content:find("- Erster Teil > Kapitel 1 (pp. 1-1)", 1, true) ~= nil, "entry with parent path")
    TestRunner:assertTrue(scope_msg.content:find("- Zweiter Teil (pp. 2-2)", 1, true) ~= nil, "last entry within reach")

    -- Unknown language: the rule still rides, phrased as unknown.
    local plain = makeUi()
    first_messages = nil
    calls = 0
    BookToolRunner.run({
        query_fn = query_fn,
        messages = { { role = "user", content = "hi" } },
        config = gatherConfig(),
        ui = plain,
        on_complete = function() end,
    })
    local found = false
    for _i, msg in ipairs(first_messages or {}) do
        if type(msg.content) == "string" and msg.content:find("[Book tool scope]", 1, true) then
            found = true
            TestRunner:assertEqual(msg.content:find("Book text language:", 1, true), nil, "no language line when unknown")
            TestRunner:assertTrue(msg.content:find("Write search_book queries in the language the book text is in", 1, true) ~= nil, "rule still rides")
            TestRunner:assertTrue(msg.content:find("This book has no table of contents.", 1, true) ~= nil, "no-TOC line")
        end
    end
    TestRunner:assertTrue(found, "scope message present")
end)

TestRunner:test("book text language: off by default, per-book override wins over global", function()
    local function scopeContent(extra_features, doc_values)
        local first_messages
        local calls = 0
        local function query_fn(messages, _config, callback)
            calls = calls + 1
            if calls == 1 then
                first_messages = messages
                callback(true, doneAnswer())
            else
                callback(true, "answer")
            end
        end
        local ui = makeUi()
        ui.doc_props = { language = "de" }
        if doc_values then
            ui.doc_settings = { readSetting = function(_self, key) return doc_values[key] end }
        end
        BookToolRunner.run({
            query_fn = query_fn,
            messages = { { role = "user", content = "hi" } },
            config = gatherConfig(extra_features),
            ui = ui,
            on_complete = function() end,
        })
        for _i, msg in ipairs(first_messages or {}) do
            if type(msg.content) == "string" and msg.content:find("[Book tool scope]", 1, true) then
                return msg.content
            end
        end
    end
    local default = scopeContent({})
    TestRunner:assertEqual(default:find("Book text language", 1, true), nil, "global default off: no language line")
    TestRunner:assertTrue(default:find("Write search_book queries in the language the book text is in", 1, true) ~= nil, "rule rides anyway")
    local metadata = scopeContent({ book_text_language = "metadata" })
    TestRunner:assertTrue(metadata:find("Book text language: de.", 1, true) ~= nil, "global from-metadata sends the recorded language")
    local per_book_off = scopeContent({ book_text_language = "metadata" }, { koassistant_book_text_language = "off" })
    TestRunner:assertEqual(per_book_off:find("Book text language", 1, true), nil, "per-book off beats global on")
    local per_book_pick = scopeContent({}, { koassistant_book_text_language = "French" })
    TestRunner:assertTrue(per_book_pick:find("Book text language: French.", 1, true) ~= nil, "per-book pick beats global off, by its English name")
    local per_book_typed = scopeContent({}, { koassistant_book_text_language = "German and Latin" })
    TestRunner:assertTrue(per_book_typed:find("Book text language: German and Latin.", 1, true) ~= nil, "typed text rides as is")
end)

TestRunner:test("gather: a readable text that fits is sent whole, no rounds", function()
    local calls = 0
    local seen_messages, seen_config, final
    local function query_fn(messages, config, callback)
        calls = calls + 1
        seen_messages, seen_config = messages, config
        callback(true, "Answer from the text.")
    end
    local ui = makeUi()
    ui.view.state.page = 1  -- protection on: page 1 of 2 readable
    BookToolRunner.run({
        query_fn = query_fn,
        messages = { { role = "user", content = "who is mentioned in a letter?" } },
        config = gatherConfig({ tool_whole_text = true }),
        ui = ui,
        on_complete = function(_s, answer, _err, _reasoning, provenance)
            final = { answer = answer, provenance = provenance }
        end,
    })
    TestRunner:assertEqual(calls, 1, "one request: no gather round at all")
    TestRunner:assertTrue(seen_config.tools == nil, "phase 2 declares no tools")
    local block
    for _i, m in ipairs(seen_messages) do
        if type(m.content) == "string" and m.content:find("[The book's readable text, in full]", 1, true) then
            block = m
        end
    end
    TestRunner:assertTrue(block ~= nil, "whole-text block injected")
    TestRunner:assertEqual(block.is_context, true, "as context")
    TestRunner:assertTrue(block.content:find("Pages 1-1 of 2, up to the reader's current position", 1, true) ~= nil, "range line under protection")
    TestRunner:assertTrue(block.content:find("Daisy was mentioned in a letter", 1, true) ~= nil, "page 1 text present")
    TestRunner:assertEqual(block.content:find("garden path", 1, true), nil, "page 2 stays out of reach")
    TestRunner:assertEqual(final.answer, "Answer from the text.", "answer unchanged")
    TestRunner:assertTrue(type(final.provenance) == "table" and type(final.provenance.book_tools) == "table", "book provenance present")
    TestRunner:assertEqual(final.provenance.book_tools.lookups, 0, "zero lookups")
    TestRunner:assertEqual(final.provenance.book_tools.whole_text, true, "flagged as whole text")
    TestRunner:assertTrue(final.provenance.book_tools.trace[1]:find("read the readable text in full: pp. 1-1 of 2", 1, true) ~= nil, "trace line")

    -- Full reach: the range line says so and both pages ride.
    calls = 0
    BookToolRunner.run({
        query_fn = query_fn,
        messages = { { role = "user", content = "hi" } },
        config = gatherConfig({ tool_whole_text = true, spoiler_free_chat = false }),
        ui = makeUi(),
        on_complete = function() end,
    })
    for _i, m in ipairs(seen_messages) do
        if type(m.content) == "string" and m.content:find("[The book's readable text, in full]", 1, true) then
            TestRunner:assertTrue(m.content:find("Pages 1-2, the whole book.", 1, true) ~= nil, "whole-book range line")
            TestRunner:assertTrue(m.content:find("garden path", 1, true) ~= nil, "page 2 included")
        end
    end

    -- Over the size: the search rounds run as before (Medium, 64,000 characters, an oversized page).
    calls = 0
    local big = makeUi()
    local filler = string.rep("word ", 14000)  -- 70,000 chars on page 1
    big.document.getPageText = function(_self, page) return page == 1 and filler or "second page" end
    local function rounds_fn(messages, _config, callback)
        calls = calls + 1
        if calls == 1 then callback(true, doneAnswer()) else callback(true, "answer") end
    end
    BookToolRunner.run({
        query_fn = rounds_fn,
        messages = { { role = "user", content = "hi" } },
        config = gatherConfig({ tool_whole_text = true, tool_lookup_effort = "quick", spoiler_free_chat = false }),
        ui = big,
        on_complete = function() end,
    })
    TestRunner:assertEqual(calls, 2, "text over the budget: a gather round ran, then phase 2")
end)

TestRunner:test("gather: the whole-text check stops extracting as soon as the budget is exceeded", function()
    -- A 300-page book of 1,000-character pages: the check must give up after ~65 pages,
    -- never walk the book (that froze the device on an 18k-page book).
    local extracted = 0
    local ui = makeUi()
    ui.document.info.number_of_pages = 300
    ui.document.getPageText = function(_self, _page)
        extracted = extracted + 1
        return string.rep("x", 1000)
    end
    ui.view.state.page = 300
    local calls = 0
    BookToolRunner.run({
        query_fn = function(_m, _c, cb)
            calls = calls + 1
            if calls == 1 then cb(true, doneAnswer()) else cb(true, "answer") end
        end,
        messages = { { role = "user", content = "hi" } },
        config = gatherConfig({ tool_whole_text = true, spoiler_free_chat = false }),
        ui = ui,
        on_complete = function() end,
    })
    TestRunner:assertEqual(calls, 2, "over budget: the rounds ran")
    TestRunner:assertTrue(extracted <= 3, "three sampled pages decide it, pages extracted: " .. extracted)
    -- A huge range: the same three samples, never a walk.
    extracted = 0
    ui.document.info.number_of_pages = 5000
    ui.view.state.page = 5000
    calls = 0
    BookToolRunner.run({
        query_fn = function(_m, _c, cb)
            calls = calls + 1
            if calls == 1 then cb(true, doneAnswer()) else cb(true, "answer") end
        end,
        messages = { { role = "user", content = "hi" } },
        config = gatherConfig({ tool_whole_text = true, spoiler_free_chat = false }),
        ui = ui,
        on_complete = function() end,
    })
    TestRunner:assertTrue(extracted <= 3, "a 5,000-page range costs three samples, pages extracted: " .. extracted)
end)

TestRunner:test("gatherForAction: a readable text that fits is returned whole", function()
    local calls = 0
    local result, info_out
    BookToolRunner.gatherForAction({
        question = "Task: Explain",
        query_fn = function(_m, _c, callback) calls = calls + 1; callback(true, doneAnswer()) end,
        config = { provider = "gemini", features = { is_book_context = true, spoiler_free_chat = false } },
        ui = makeUi(),
        on_complete = function(bundle, info) result, info_out = bundle, info end,
    })
    TestRunner:assertEqual(calls, 0, "no gather request")
    TestRunner:assertTrue(type(result) == "string" and result:find("[The book's readable text, in full]", 1, true) ~= nil, "bundle is the text")
    TestRunner:assertTrue(result:find("garden path", 1, true) ~= nil, "both pages present")
    TestRunner:assertEqual(info_out.whole_text, true, "info flags whole text")
    TestRunner:assertEqual(info_out.tool_calls, 0, "no lookups")
end)

TestRunner:test("the whole-text size is the reader's setting, not the effort's (B402)", function()
    local L = BookToolRunner.wholeTextLimit
    TestRunner:assertEqual(L({}), 64000, "default: Medium")
    TestRunner:assertEqual(L({ tool_whole_text = true }), 64000, "the old switch's On reads as Medium")
    TestRunner:assertEqual(L({ tool_whole_text = false }), nil, "the old switch's Off stays Off")
    TestRunner:assertEqual(L({ tool_whole_text = "small" }), 16000, "Small")
    TestRunner:assertEqual(L({ tool_whole_text = "large" }), 128000, "Large")
    TestRunner:assertEqual(L({ tool_whole_text = true, tool_lookup_effort = "thorough" }), 64000, "effort no longer raises it")
    TestRunner:assertEqual(BookToolRunner.budgetFor({ tool_lookup_effort = "thorough" }).whole_chars, nil, "budgets carry no size")
    -- The settings row offers exactly the values the runner reads, Medium by default.
    local f = assert(io.open(package.searchpath("koassistant_settings_schema", package.path), "r"))
    local schema = f:read("*a")
    f:close()
    local row = schema:match('id = "tool_whole_text",(.-)\n                },')
    TestRunner:assertTrue(row ~= nil, "the settings row")
    local values = {}
    for v in row:gmatch("{ value = ([^,]+),") do values[#values + 1] = v end
    TestRunner:assertEqual(table.concat(values, " "), 'false "small" true "large"', "Off, Small, Medium, Large")
    TestRunner:assertTrue(row:find("default = true,", 1, true) ~= nil, "Medium by default")
end)

-- Two pages of 6,000 characters: inside every size from Medium up, over a small plan.
local function bigUi()
    local ui = makeUi()
    local page = string.rep("word ", 1200)
    ui.document.getPageText = function(_self, p) return p <= 2 and page or "" end
    return ui
end

local function wholeTextSent(config, ui)
    local calls, sent = 0, false
    BookToolRunner.run({
        query_fn = function(messages, _c, cb)
            calls = calls + 1
            for _i, m in ipairs(messages) do
                if type(m.content) == "string" and m.content:find("[The book's readable text, in full]", 1, true) then
                    sent = true
                end
            end
            if calls == 1 and not sent then cb(true, doneAnswer()) else cb(true, "answer") end
        end,
        messages = { { role = "user", content = "hi" } },
        config = config,
        ui = ui,
        on_complete = function() end,
    })
    return sent, calls
end

TestRunner:test("a text the model's known limits cannot take is searched instead (B402)", function()
    local ModelConstraints = require("model_constraints")
    local RateLimits = require("koassistant_rate_limits")
    local cfg = gatherConfig({ tool_whole_text = true, spoiler_free_chat = false })
    local model = ModelConstraints.dispatchModel(cfg)
    TestRunner:assertTrue(model ~= nil, "the dispatch model")
    TestRunner:assertEqual((wholeTextSent(cfg, bigUi())), true, "no known limit: sent whole")

    -- A per-minute plan this session learned: 2,000 tokens leave no room for 12,000 characters.
    RateLimits.record("gemini", model, { limit_tokens = 2000 }, "header")
    local sent, calls = wholeTextSent(gatherConfig({ tool_whole_text = true, spoiler_free_chat = false }), bigUi())
    TestRunner:assertEqual(sent, false, "over the plan: not sent")
    TestRunner:assertEqual(calls, 2, "the search rounds ran instead")
    TestRunner:assertEqual((wholeTextSent(gatherConfig({ tool_whole_text = true, spoiler_free_chat = false }), makeUi())), true,
        "a text that fits the plan still goes whole")
    RateLimits.forget("gemini", model)

    -- The model's context window.
    local windows = ModelConstraints._context_windows.gemini
    local saved = windows[model]
    windows[model] = 2000
    TestRunner:assertEqual((wholeTextSent(gatherConfig({ tool_whole_text = true, spoiler_free_chat = false }), bigUi())), false,
        "over the context window: not sent")
    windows[model] = saved
    TestRunner:assertEqual((wholeTextSent(gatherConfig({ tool_whole_text = true, spoiler_free_chat = false }), bigUi())), true,
        "restored")
end)

TestRunner:test("the readable text sits right after the opening context, the same place every turn (B402)", function()
    local seen
    local function query_fn(messages, _c, cb) seen = messages; cb(true, "answer") end
    local opening = { role = "user", content = "[Context]\nBook: A\n\n[User Question]\nwho writes letters?", is_context = true }
    local spoiler = { role = "user", content = "The reader is currently at 50%.", is_context = true }
    local function run(messages)
        BookToolRunner.run({ query_fn = query_fn, messages = messages,
            config = gatherConfig({ tool_whole_text = true }), ui = makeUi(), on_complete = function() end })
        return seen
    end
    local function isText(m) return m and type(m.content) == "string" and m.content:find("[The book's readable text, in full]", 1, true) end
    -- Turn 1: the opening, the text, then the live spoiler line, last as it should be.
    local t1 = run({ opening, spoiler })
    TestRunner:assertEqual(t1[1].content, opening.content, "turn 1: the opening first")
    TestRunner:assertTrue(isText(t1[2]), "turn 1: the text second")
    TestRunner:assertEqual(t1[3].content, spoiler.content, "turn 1: the spoiler line last")
    -- Turn 2: the same prefix (opening, text), then the exchange, the new question, the line.
    local t2 = run({ opening, { role = "assistant", content = "a letter writer" },
        { role = "user", content = "and who reads them?" }, spoiler })
    TestRunner:assertEqual(t2[1].content, opening.content, "turn 2: the opening first")
    TestRunner:assertTrue(isText(t2[2]), "turn 2: the text in the same place")
    TestRunner:assertEqual(t2[2].content, t1[2].content, "turn 2: the same text, so the prefix repeats")
    TestRunner:assertEqual(t2[4].content, "and who reads them?", "turn 2: the new question after the exchange")
    TestRunner:assertEqual(t2[5].content, spoiler.content, "turn 2: the spoiler line last")
    -- No opening context message: the text goes before the newest question, as before.
    local plain = run({ { role = "user", content = "hi" } })
    TestRunner:assertTrue(isText(plain[1]), "no opening context: before the question")
    TestRunner:assertEqual(plain[2].content, "hi", "the question after it")
end)

TestRunner:test("a page turn changes only the end of the text, so its start stays cached (B402)", function()
    local seen
    local function query_fn(messages, _c, cb) seen = messages; cb(true, "answer") end
    local function blockAt(page)
        local ui = makeUi()
        ui.view.state.page = page  -- protection on: the text ends at the reader's page
        BookToolRunner.run({ query_fn = query_fn, messages = { { role = "user", content = "hi" } },
            config = gatherConfig({ tool_whole_text = true }), ui = ui, on_complete = function() end })
        for _i, m in ipairs(seen) do
            if type(m.content) == "string" and m.content:find("[The book's readable text, in full]", 1, true) then
                return m.content
            end
        end
    end
    local at1, at2 = blockAt(1), blockAt(2)
    TestRunner:assertTrue(at1 ~= nil and at2 ~= nil, "both turns read the text whole")
    TestRunner:assertTrue(at2:find("garden path", 1, true) ~= nil, "the later turn reaches the new page")
    -- Byte for byte the same up to the end of the text read before: a cached prefix
    local _s, page1_end = at1:find("Daisy was mentioned in a letter.", 1, true)
    TestRunner:assertEqual(at2:sub(1, page1_end), at1:sub(1, page1_end), "the shared start covers page 1's text")
    TestRunner:assertTrue(at1:find("Pages 1-1 of 2", page1_end, true) ~= nil, "the page range comes after the text")
end)

TestRunner:test("gather: zero lookups leave a note saying the book was not consulted", function()
    local calls = 0
    local gen_messages
    local function query_fn(messages, _config, callback)
        calls = calls + 1
        if calls == 1 then
            callback(true, doneAnswer())
        else
            gen_messages = messages
            callback(true, "From memory.")
        end
    end
    local ui = makeUi()
    ui.view.state.page = 1  -- reader on page 1 of 2, protection on: one page within reach
    BookToolRunner.run({
        query_fn = query_fn,
        messages = { { role = "user", content = "what does this book say about gardens?" } },
        config = gatherConfig(),
        ui = ui,
        on_complete = function() end,
    })
    local note
    for _i, m in ipairs(gen_messages or {}) do
        if type(m.content) == "string" and m.content:find("[Book lookup note]", 1, true) then
            note = m
        end
    end
    TestRunner:assertTrue(note ~= nil, "note injected into phase 2")
    TestRunner:assertEqual(note.is_context, true, "as context")
    TestRunner:assertTrue(note.content:find("no lookups were made", 1, true) ~= nil, "says nothing was looked up")
    TestRunner:assertTrue(note.content:find("Only pages 1-1 of 2 were within reach", 1, true) ~= nil, "names the reach under protection")
    TestRunner:assertTrue(note.content:find("comes from general knowledge", 1, true) ~= nil, "asks for the disclosure")
    -- Full reach: the note still says the text was not consulted, without a range clause.
    calls, gen_messages = 0, nil
    local full = makeUi()
    BookToolRunner.run({
        query_fn = query_fn,
        messages = { { role = "user", content = "what does this book say about gardens?" } },
        config = gatherConfig({ spoiler_free_chat = false }),
        ui = full,
        on_complete = function() end,
    })
    for _i, m in ipairs(gen_messages or {}) do
        if type(m.content) == "string" and m.content:find("[Book lookup note]", 1, true) then
            TestRunner:assertEqual(m.content:find("within reach", 1, true), nil, "no range clause at full reach")
        end
    end
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
    cfg = { provider = "perplexity", model = "sonar-pro", features = {
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
        { provider = "perplexity", model = "sonar-pro",
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
        config = { provider = "gemini", features = { is_book_context = true, tool_whole_text = false } },
        ui = makeUi(),
        on_complete = function() end,
    })
    TestRunner:assertTrue(
        first_config.system.text:find("You may use at most 8 lookups in total, across at most 4 rounds.", 1, true) ~= nil,
        "standard budget stated in the gather instructions")

    first_config = nil
    BookToolRunner.run({
        query_fn = query_fn,
        messages = { { role = "user", content = "hi" } },
        config = { provider = "gemini",
            features = { is_book_context = true, tool_lookup_effort = "quick", tool_whole_text = false } },
        ui = makeUi(),
        on_complete = function() end,
    })
    TestRunner:assertTrue(
        first_config.system.text:find("You may use at most 4 lookups in total, across at most 2 rounds.", 1, true) ~= nil,
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
        config = { provider = "gemini", features = { is_book_context = true, tool_whole_text = false } },
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
    local final_answer, final_provenance
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
            features = { is_book_context = true, tool_lookup_effort = "quick", tool_whole_text = false } },
        ui = makeUi(),
        on_complete = function(_success, answer, _err, _reasoning, provenance)
            final_answer = answer
            final_provenance = provenance
        end,
    })
    TestRunner:assertEqual(calls, 3, "2 gather rounds + 1 generate call under the quick budget")
    TestRunner:assertEqual(final_answer, "capped answer", "clean answer from phase 2 (no baked note)")
    TestRunner:assertTrue(type(final_provenance) == "table"
        and final_provenance.book_tools and final_provenance.book_tools.lookups == 2,
        "provenance lookups reflect the capped session")
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
        config = { provider = "gemini", features = { is_book_context = true, tool_whole_text = false } },
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
        config = { provider = "gemini", features = { is_book_context = true, tool_whole_text = false } },
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
        config = { provider = "gemini", features = { is_book_context = true, tool_whole_text = false } },
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
            features = { is_book_context = true, tool_lookup_effort = "quick", tool_whole_text = false } },
        ui = makeUi(),
        on_complete = function(bundle, info) got_bundle, got_info = bundle, info end,
    })
    TestRunner:assertEqual(calls, 2, "quick budget stops after 2 rounds — no extra request")
    TestRunner:assertTrue(type(got_bundle) == "string" and #got_bundle > 0, "partial bundle delivered")
    TestRunner:assertEqual(got_info.tool_calls, 2, "both lookups counted")
end)

TestRunner:test("smartRetrievalAllowed: eligibility only (posture master switch retired)", function()
    local base = { provider = "gemini",
        features = { enable_book_text_extraction = true } }
    local ok, why = BookToolRunner.smartRetrievalAllowed(base, makeUi())
    TestRunner:assertTrue(ok, "eligible session allowed")
    -- Binary collapse 2026-08-12: tools OFF is a chip default, not a hard
    -- kill — smart retrieval stays offered on an eligible session
    base.features.enable_book_tools = false
    TestRunner:assertTrue(BookToolRunner.smartRetrievalAllowed(base, makeUi()),
        "global tools off no longer gates smart retrieval")
    base.features.enable_book_tools = nil
    base.features.tools_posture = "off"
    TestRunner:assertTrue(BookToolRunner.smartRetrievalAllowed(base, makeUi()),
        "legacy posture off no longer gates smart retrieval")
    base.features.tools_posture = nil
    local ui = makeUi()
    ui.doc_settings = {
        readSetting = function(_self, key)
            if key == "koassistant_book_tools" then return "off" end
        end,
    }
    TestRunner:assertTrue(BookToolRunner.smartRetrievalAllowed(base, ui),
        "per-book off no longer gates smart retrieval")
    -- ineligibility reasons pass through unchanged
    ok, why = BookToolRunner.smartRetrievalAllowed(
        { provider = "gemini", features = {} }, makeUi())
    TestRunner:assertEqual(why, "consent", "sessionEligible reasons pass through")
end)

-- decorateSpoilerMessages — live turn-level spoiler line (spoiler_posture_plan.md
-- C4 REVISED 2026-08-11): the pure decoration half. The impure half (posture +
-- live position) is the resolver pinned in test_book_settings.lua.

local LINE = "The reader is currently at 42% of this book. Do not reveal beyond."

TestRunner:test("nil line or no user message is a no-op (same table back)", function()
    local msgs = { { role = "user", content = "q", is_context = false } }
    TestRunner:assertEqual(BookToolRunner.decorateSpoilerMessages(msgs, nil), msgs,
        "nil line returns the original array")
    local no_user = { { role = "assistant", content = "a" } }
    TestRunner:assertEqual(BookToolRunner.decorateSpoilerMessages(no_user, LINE), no_user,
        "no user message returns the original array")
end)

TestRunner:test("line rides as its OWN final user message; history untouched", function()
    local q1 = { role = "user", content = "context+question", is_context = true }
    local a1 = { role = "assistant", content = "answer" }
    local q2 = { role = "user", content = "follow-up", is_context = false }
    local msgs = { q1, a1, q2 }
    local out = BookToolRunner.decorateSpoilerMessages(msgs, LINE)
    TestRunner:assertEqual(#out, 4, "one message appended")
    TestRunner:assertEqual(out[4].content, LINE, "the line is the final message")
    TestRunner:assertEqual(out[4].role, "user", "line rides the user role")
    TestRunner:assertTrue(out[4].is_context == true, "line is scaffolding, not the user's words")
    -- Prefix-cache invariant: every stored message is the SAME table, byte-identical
    -- across requests — only the line itself is ever uncached.
    TestRunner:assertEqual(out[1], q1, "history messages shared, not copied")
    TestRunner:assertEqual(out[3], q2, "the outgoing turn is not rewritten either")
    TestRunner:assertEqual(q2.content, "follow-up", "originals never mutate")
    TestRunner:assertEqual(#msgs, 3, "original array untouched")
end)

TestRunner:test("first request (all-context messages, attachments last) decorates at the end", function()
    -- Every chat's first request is [consolidated is_context (+ attachments is_context)]
    local consolidated = { role = "user", content = "[Context]...[User Question] q", is_context = true }
    local attach = { role = "user", content = "attachment block", is_context = true }
    local out = BookToolRunner.decorateSpoilerMessages({ consolidated, attach }, LINE)
    TestRunner:assertEqual(#out, 3, "line appended after the attachments")
    TestRunner:assertEqual(out[3].content, LINE, "line is the final message")
    TestRunner:assertEqual(out[1], consolidated, "consolidated message shared")
    TestRunner:assertEqual(out[2], attach, "attachment message shared")
end)

TestRunner:test("in_prompt skips the first request only (never both), replies decorate", function()
    local first = { { role = "user", content = "prompt with resolved nudge", is_context = true } }
    TestRunner:assertEqual(BookToolRunner.decorateSpoilerMessages(first, LINE, true), first,
        "first request of a placeholder prompt is left alone")
    local reply = {
        { role = "user", content = "prompt with resolved nudge", is_context = true },
        { role = "assistant", content = "answer" },
        { role = "user", content = "follow-up" },
    }
    local out = BookToolRunner.decorateSpoilerMessages(reply, LINE, true)
    TestRunner:assertEqual(#out, 4, "reply of the same chat decorates")
    TestRunner:assertEqual(out[4].content, LINE, "line is the final message")
end)

-- liveSpoilerLine: the per-send decision of whether the nudge rides and
-- whether the reader's position is disclosed (release-blocking six-pack [3])

TestRunner:test("liveSpoilerLine: nil unless _spoiler_live is exactly true", function()
    TestRunner:assertEqual(BookToolRunner._liveSpoilerLine({ features = {} }, nil), nil,
        "no eligibility flag -> no line")
    TestRunner:assertEqual(
        BookToolRunner._liveSpoilerLine({ features = { _spoiler_live = false } }, nil), nil,
        "explicit false -> no line")
    TestRunner:assertEqual(
        BookToolRunner._liveSpoilerLine({ features = { _spoiler_live = true, is_general_context = true } }, nil),
        nil, "general context never gets the line, whatever the flag claims")
end)

TestRunner:test("liveSpoilerLine: scope consent stands the nudge down ONCE", function()
    local features = { _spoiler_live = true, _spoiler_scope_consent = true }
    local line = BookToolRunner._liveSpoilerLine({ features = features }, nil)
    TestRunner:assertEqual(line, nil, "consented request carries no nudge")
    TestRunner:assertEqual(features._spoiler_scope_consent, nil, "one-shot flag consumed")
end)

TestRunner:test("liveSpoilerLine: stats off + untrusted -> no-progress variant, no position leak", function()
    local Templates = require("prompts/templates")
    local features = { _spoiler_live = true, enable_basic_stats = false }
    local line = BookToolRunner._liveSpoilerLine({ features = features, provider = "openai" }, nil)
    TestRunner:assertEqual(line, Templates.SPOILER_FREE_NUDGE_NO_PROGRESS,
        "protected default posture with stats sharing off uses the no-progress nudge")
    TestRunner:assertEqual(line:find("%d+%%"), nil, "no percentage anywhere in the line")
end)

TestRunner:test("liveSpoilerLine: substitutes the live position when stats allowed", function()
    local saved = package.loaded["koassistant_context_extractor"]
    package.loaded["koassistant_context_extractor"] = {
        new = function(_self, _ui)
            return { getReadingProgress = function() return { formatted = "42%" } end }
        end,
    }
    local fake_ds = { readSetting = function() return nil end }
    local ui = { document = { file = "/tmp/x.epub" }, doc_settings = fake_ds }
    local features = { _spoiler_live = true, book_metadata = { file = "/tmp/x.epub" } }
    local line = BookToolRunner._liveSpoilerLine({ features = features, provider = "anthropic" }, ui)
    package.loaded["koassistant_context_extractor"] = saved
    TestRunner:assertEqual(type(line), "string", "protected book chat gets the line")
    TestRunner:assertEqual(line:find("42%%") ~= nil, true, "position substituted")
    TestRunner:assertEqual(line:find("{reading_progress}", 1, true), nil, "placeholder resolved")
end)

return TestRunner:summary()
