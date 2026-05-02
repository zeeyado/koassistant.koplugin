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

TestRunner:test("appends verbose tool output and aggregate token usage", function()
    local calls = 0
    local final_answer = nil
    local function query_fn(_messages, _config, callback)
        calls = calls + 1
        if calls == 1 then
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
            },
        },
        ui = makeUi(),
        on_complete = function(success, answer)
            TestRunner:assertTrue(success, "runner success")
            final_answer = answer
        end,
    })

    TestRunner:assertEqual(calls, 2, "query calls")
    TestRunner:assertTrue(final_answer:find("Gemini tool output sent to model", 1, true) ~= nil, "verbose output")
    TestRunner:assertTrue(final_answer:find('"role":"user"', 1, true) ~= nil, "Gemini role in tool output")
    TestRunner:assertTrue(final_answer:find("Daisy was mentioned in a letter", 1, true) ~= nil, "tool result text")
    TestRunner:assertTrue(final_answer:find("38 total tokens", 1, true) ~= nil, "total token usage")
    TestRunner:assertTrue(final_answer:find("across 2 Gemini API calls", 1, true) ~= nil, "call count")
end)

return TestRunner:summary()
