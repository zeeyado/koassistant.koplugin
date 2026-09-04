-- Unit tests: RateLimits.promptChars is the router's own prompt-size arithmetic
-- (request-sizing audit, build item B14).
--
-- The number that decides whether a request fits the plan's per-minute allowance
-- is computed in koassistant_gpt_query.lua's dispatch path. A pre-send check has
-- to ask the same question BEFORE that point, so the arithmetic moved into
-- koassistant_rate_limits.lua as a pure helper. This file is the guard that
-- keeps the two from drifting: it restates the router's original closure
-- verbatim and asserts the helper agrees with it, byte for byte.
--
-- Run: lua tests/unit/test_prompt_chars.lua   (or lua tests/run_tests.lua --unit)

local function setupPaths()
    local info = debug.getinfo(1, "S")
    local script_path = info.source:match("@?(.*)")
    local unit_dir = script_path:match("(.+)/[^/]+$") or "."
    local tests_dir = unit_dir:match("(.+)/[^/]+$") or "."
    local plugin_dir = tests_dir:match("(.+)/[^/]+$") or "."
    package.path = table.concat({
        plugin_dir .. "/?.lua",
        plugin_dir .. "/koassistant_api/?.lua",
        tests_dir .. "/?.lua",
        tests_dir .. "/lib/?.lua",
        package.path,
    }, ";")
end
setupPaths()
require("mock_koreader")

local TestRunner = { passed = 0, failed = 0, current_suite = "" }
function TestRunner:suite(name) self.current_suite = name; print(string.format("\n  [%s]", name)) end
function TestRunner:test(name, fn)
    local ok, err = pcall(fn)
    if ok then self.passed = self.passed + 1; print("    ✓ " .. name)
    else self.failed = self.failed + 1; print("    ✗ " .. name); print("      Error: " .. tostring(err)) end
end
function TestRunner:assertEqual(actual, expected, msg)
    if actual ~= expected then
        error(string.format("%s: expected %s, got %s", msg or "assert", tostring(expected), tostring(actual)))
    end
end

local RL = require("koassistant_rate_limits")

-- The router's arithmetic, restated exactly as koassistant_gpt_query.lua's
-- dispatch closure had it. If this ever has to change, the helper changes with
-- it and this file is where the two are compared.
local function routerPromptChars(config, message_history)
    local n = 0
    if config.system and type(config.system.text) == "string" then
        n = n + #config.system.text
    end
    for _idx = 1, #(message_history or {}) do
        local m = message_history[_idx]
        if m and type(m.content) == "string" then n = n + #m.content end
    end
    return n
end

--- Both ways of counting the same request must agree, and the value must be the
--- one we expect by hand.
local function bothAgree(label, config, history, expected)
    local router = routerPromptChars(config, history)
    local helper = RL.promptChars(config.system and config.system.text or nil, history)
    TestRunner:assertEqual(router, expected, label .. ": router arithmetic")
    TestRunner:assertEqual(helper, expected, label .. ": helper arithmetic")
end

TestRunner:suite("promptChars agrees with the router, case by case")

TestRunner:test("no system prompt", function()
    bothAgree("nil system", {}, { { role = "user", content = "hello" } }, 5)
    bothAgree("system table without text", { system = {} },
        { { role = "user", content = "hello" } }, 5)
end)

TestRunner:test("system prompt counts", function()
    bothAgree("system only", { system = { text = "abcdefgh" } }, {}, 8)
    bothAgree("system plus one message", { system = { text = "abcdefgh" } },
        { { role = "user", content = "hello" } }, 13)
end)

TestRunner:test("only string message contents count", function()
    -- Gemini `parts` and Anthropic content blocks arrive as tables; they are not
    -- counted (a known undercount, recorded in the audit as F11) and the guard
    -- exists so a fix lands in ONE place.
    bothAgree("mixed contents", { system = { text = "sys" } }, {
        { role = "user", content = "1234567890" },
        { role = "assistant", content = { { type = "text", text = "a very long block" } } },
        { role = "user", content = "abc" },
        { role = "user" },
    }, 3 + 10 + 3)
end)

TestRunner:test("empty and nil histories", function()
    bothAgree("empty list", { system = { text = "sys" } }, {}, 3)
    bothAgree("nil list", { system = { text = "sys" } }, nil, 3)
    bothAgree("nothing at all", {}, nil, 0)
end)

TestRunner:test("multi-byte text is counted in BYTES, like the wire", function()
    local arabic = "مرحبا"  -- 5 characters, 10 bytes in UTF-8
    bothAgree("utf-8", {}, { { role = "user", content = arabic } }, #arabic)
    TestRunner:assertEqual(#arabic, 10, "the fixture really is 10 bytes")
end)

TestRunner:suite("the cap the count feeds")

TestRunner:test("a pinned budget is cut down to the cap", function()
    -- The X-Ray pin against a plan that leaves 1077 tokens of room.
    local value, changed = RL.applyCap(65536, 1077)
    TestRunner:assertEqual(value, 1077, "pin shrunk to the cap")
    TestRunner:assertEqual(changed, true, "and the caller is told it changed")
end)

print(string.format("\n  test_prompt_chars: %d passed, %d failed", TestRunner.passed, TestRunner.failed))
return TestRunner.failed == 0
