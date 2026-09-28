-- Unit tests for ModelConstraints.checkContextWindow (model-aware extraction
-- pre-check, model_tooling_plan.md queue item 2). Pure, no API calls.
--
-- Run: lua tests/run_tests.lua --unit  (or directly from the repo root)

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
local ModelConstraints = require("model_constraints")

local TestRunner = { passed = 0, failed = 0 }
function TestRunner:check(name, condition)
    if condition then
        self.passed = self.passed + 1
        print("  PASS: " .. name)
    else
        self.failed = self.failed + 1
        print("  FAIL: " .. name)
    end
end

print("== checkContextWindow: fail-open contract ==")

TestRunner:check("unknown provider -> nil (no claim)",
    ModelConstraints.checkContextWindow("groq", "llama-3.3-70b-versatile", 10000000) == nil)
TestRunner:check("unknown model in known provider -> nil (no matching prefix)",
    ModelConstraints.checkContextWindow("xai", "totally-new-9", 10000000) == nil)
TestRunner:check("nil chars -> nil",
    ModelConstraints.checkContextWindow("gemini", "gemini-3.6-flash", nil) == nil)
TestRunner:check("zero chars -> nil",
    ModelConstraints.checkContextWindow("gemini", "gemini-3.6-flash", 0) == nil)

print("== checkContextWindow: verdicts ==")

-- grok-build: 256000-token window; threshold = 0.9 * 256000 = 230400 tokens;
-- est = chars/4.
local ex_small = ModelConstraints.checkContextWindow("xai", "grok-build-0.1", 800000)
TestRunner:check("under the window -> exceeded false (800K chars ~ 200K tokens vs 256K window)",
    ex_small == false)
local ex_big, win_big, est_big =
    ModelConstraints.checkContextWindow("xai", "grok-build-0.1", 1000000)
TestRunner:check("over the window -> exceeded true (1M chars ~ 250K tokens vs 256K window)",
    ex_big == true)
TestRunner:check("window and estimate returned for the message",
    win_big == 256000 and est_big == 250000)

print("== checkContextWindow: prefix matching ==")

-- 1M is the no-beta-header default on all 1M Claude models (T2, 2026-08-14);
-- only Haiku 4.5 and the uncurated-family floor stay 200K.
local _ex1, win1 = ModelConstraints.checkContextWindow("anthropic", "claude-sonnet-5", 400000)
TestRunner:check("exact id wins (claude-sonnet-5 -> 1M)", win1 == 1000000)
local _exh, winh = ModelConstraints.checkContextWindow("anthropic", "claude-haiku-4-5-20251001", 400000)
TestRunner:check("prefix id (claude-haiku-4-5-20251001 -> 200K)", winh == 200000)
local _exf, winf = ModelConstraints.checkContextWindow("anthropic", "claude-newthing-9", 400000)
TestRunner:check("family floor (uncurated claude-* -> 200K)", winf == 200000)
local _ex2, win2 = ModelConstraints.checkContextWindow("xai", "grok-4.6", 400000)
TestRunner:check("exact id wins (grok-4.6 -> 500K)", win2 == 500000)
TestRunner:check("escaped dot: gemini-2x5-x must NOT match the gemini-2.5 prefix",
    ModelConstraints.checkContextWindow("gemini", "gemini-2x5-flash", 10000000) == nil)
local ex3 = ModelConstraints.checkContextWindow("gemini", "gemini-3.6-flash", 400000)
TestRunner:check("1M-window model: 400K chars is comfortably under", ex3 == false)

print("== checkContextWindow: new providers (T2 table) ==")

local _exz1, winz1 = ModelConstraints.checkContextWindow("zai", "glm-5.2", 400000)
local _exz2, winz2 = ModelConstraints.checkContextWindow("zai", "glm-5-turbo", 400000)
TestRunner:check("longest prefix: glm-5.2 (1M) beats glm-5 (200K); glm-5-turbo gets glm-5",
    winz1 == 1000000 and winz2 == 200000)
local _exp1, winp1 = ModelConstraints.checkContextWindow("perplexity", "perplexity/sonar", 400000)
local _exp2, winp2 = ModelConstraints.checkContextWindow("perplexity", "fast", 400000)
TestRunner:check("perplexity: the direct Sonar model 127072; a preset publishes none (fail-open)",
    winp1 == 127072 and winp2 == nil)
local _exc, winc = ModelConstraints.checkContextWindow("openai_codex", "gpt-5.6-terra", 400000)
TestRunner:check("openai_codex aliases the openai table (gpt-5.6 -> 922K max input)",
    winc == 922000)
local _exm, winm = ModelConstraints.checkContextWindow("mistral", "ministral-3b-latest", 400000)
TestRunner:check("mistral probe values (ministral-3b -> 131072)", winm == 131072)
TestRunner:check("magistral-medium-latest fails open (delisted, no entry on purpose)",
    ModelConstraints.checkContextWindow("mistral", "magistral-medium-latest", 10000000) == nil)

print(string.format("\n%d passed, %d failed", TestRunner.passed, TestRunner.failed))
return TestRunner.failed == 0
