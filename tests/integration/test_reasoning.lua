-- Reasoning Integration Tests (--reasoning flag)
-- Tests reasoning/thinking parameters with real API calls
-- Verifies each provider accepts reasoning params and returns valid responses
-- Requires real API keys and makes actual API calls

-- Setup paths (detect script location)
local function setupPaths()
    local info = debug.getinfo(1, "S")
    local script_path = info.source:match("@?(.*)")
    local integration_dir = script_path:match("(.+)/[^/]+$") or "."
    local tests_dir = integration_dir:match("(.+)/[^/]+$") or "."
    local plugin_dir = tests_dir:match("(.+)/[^/]+$") or "."

    package.path = table.concat({
        plugin_dir .. "/?.lua",
        tests_dir .. "/?.lua",
        tests_dir .. "/lib/?.lua",
        package.path,
    }, ";")

    return plugin_dir, tests_dir
end

local _PLUGIN_DIR, _TESTS_DIR = setupPaths()

-- Load mocks BEFORE any plugin modules
require("mock_koreader")

-- Load test configuration
local TestConfig = require("test_config")
local TestHelpers = require("test_helpers")

-- Test Framework
local ReasoningTests = {
    passed = 0,
    failed = 0,
    skipped = 0,
    results = {},
}

function ReasoningTests:reset()
    self.passed = 0
    self.failed = 0
    self.skipped = 0
    self.results = {}
end

function ReasoningTests:log(provider, test_name, status, message, elapsed, reasoning_found)
    table.insert(self.results, {
        provider = provider,
        test = test_name,
        status = status,
        message = message,
        elapsed = elapsed,
        reasoning_found = reasoning_found,
    })

    if status == "pass" then
        self.passed = self.passed + 1
    elseif status == "fail" then
        self.failed = self.failed + 1
    else
        self.skipped = self.skipped + 1
    end
end

-- Make a test request and return success, text, elapsed, reasoning
local socket = require("socket")
local function makeTestRequest(handler, messages, config)
    local start_time = socket.gettime()
    local ok, result = pcall(function()
        return handler:query(messages, config)
    end)
    local elapsed = socket.gettime() - start_time

    return TestHelpers.handleQueryResult(ok, result, elapsed)
end

--------------------------------------------------------------------------------
-- Provider reasoning test definitions
--------------------------------------------------------------------------------

-- Each entry defines how to test reasoning for one provider/model combination.
-- expect_reasoning:
--   true   = reasoning content MUST be in response (fail if missing)
--   "maybe" = reasoning may or may not appear in non-streaming mode (info only)
local REASONING_TESTS = {
    -- Toggleable providers: test with reasoning ON, verify reasoning content
    {
        provider = "anthropic",
        name = "Anthropic extended thinking",
        config = function()
            return { thinking = { type = "enabled", budget_tokens = 2048 }, temperature = 1.0 }
        end,
        max_tokens = 4096,
        expect_reasoning = true,
    },
    {
        provider = "deepseek",
        name = "DeepSeek thinking (reasoner)",
        model = "deepseek-reasoner",
        config = function()
            return { deepseek_thinking = { type = "enabled" } }
        end,
        expect_reasoning = true,
    },
    {
        provider = "zai",
        name = "Z.AI thinking",
        config = function()
            return { zai_thinking = { type = "enabled" } }
        end,
        expect_reasoning = true,
    },
    -- Always-on effort providers: verify response succeeds with effort param
    {
        provider = "groq",
        name = "Groq reasoning effort",
        model = "qwen/qwen3-32b",
        config = function()
            return { groq_reasoning = { effort = "low" } }
        end,
        expect_reasoning = "maybe",
    },
    {
        provider = "together",
        name = "Together reasoning effort",
        model = "Qwen/Qwen3-32B",
        config = function()
            return { together_reasoning = { effort = "low" } }
        end,
        expect_reasoning = "maybe",
    },
    {
        provider = "fireworks",
        name = "Fireworks reasoning effort",
        model = "accounts/fireworks/models/deepseek-r1",
        config = function()
            return { fireworks_reasoning = { effort = "low" } }
        end,
        expect_reasoning = "maybe",
    },
    {
        provider = "xai",
        name = "xAI reasoning (grok-3-mini)",
        model = "grok-3-mini",
        config = function()
            return { xai_reasoning = { effort = "low" } }
        end,
        expect_reasoning = "maybe",
    },
    {
        provider = "perplexity",
        name = "Perplexity reasoning effort",
        model = "sonar-reasoning-pro",
        config = function()
            return { perplexity_reasoning = { effort = "low" } }
        end,
        expect_reasoning = "maybe",
    },
    {
        provider = "sambanova",
        name = "SambaNova thinking",
        model = "Qwen3-32B",
        config = function()
            return { sambanova_thinking = true }
        end,
        expect_reasoning = "maybe",
    },
    {
        provider = "openrouter",
        name = "OpenRouter reasoning",
        model = "deepseek/deepseek-r1",
        config = function()
            return { openrouter_reasoning = { effort = "low" } }
        end,
        expect_reasoning = "maybe",
    },
    {
        provider = "mistral",
        name = "Mistral Magistral (always-on)",
        model = "magistral-small",
        config = function() return {} end,
        expect_reasoning = "maybe",
    },
}

--------------------------------------------------------------------------------
-- Test runner
--------------------------------------------------------------------------------

function ReasoningTests:runTest(test_def, api_key, verbose)
    local provider = test_def.provider

    -- Load handler
    local handler_ok, handler = pcall(require, "koassistant_api." .. provider)
    if not handler_ok then
        self:log(provider, test_def.name, "fail", "Failed to load handler: " .. tostring(handler), 0)
        return false
    end

    -- Patch for synchronous HTTP
    TestHelpers.patchHandlerForSync(handler)

    -- Build config
    local config = TestConfig.buildConfig(provider, api_key, {
        system_prompt = "You are a test assistant. Respond briefly.",
        model = test_def.model,
        max_tokens = test_def.max_tokens or 1024,
    })

    -- Set model if specified
    if test_def.model then
        config.model = test_def.model
    end

    -- Merge reasoning params into api_params
    local reasoning_params = test_def.config()
    for k, v in pairs(reasoning_params) do
        config.api_params[k] = v
    end

    -- Simple math prompt that encourages reasoning
    local messages = {{ role = "user", content = "What is 15 * 23? Show your work briefly." }}

    -- Make request
    local success, text, elapsed, reasoning = makeTestRequest(handler, messages, config)

    if not success then
        self:log(provider, test_def.name, "fail", text, elapsed)
        if verbose then
            print(string.format("        Error: %s", tostring(text):sub(1, 200)))
        end
        return false
    end

    -- Check reasoning content
    local reasoning_found = reasoning ~= nil and reasoning ~= ""
    local status = "pass"
    local message

    if test_def.expect_reasoning == true and not reasoning_found then
        status = "fail"
        message = "Response succeeded but no reasoning content found"
    elseif reasoning_found then
        message = string.format("Reasoning: %d chars", #reasoning)
    else
        message = "OK (no reasoning in non-streaming response)"
    end

    self:log(provider, test_def.name, status, message, elapsed, reasoning_found)

    if verbose then
        print(string.format("        Response: %s", text:sub(1, 80)))
        if reasoning_found then
            print(string.format("        Reasoning: %s...", reasoning:sub(1, 80)))
        end
    end

    return status == "pass"
end

function ReasoningTests:runAllTests(apikeys, args)
    local target = args and args.provider
    local verbose = args and args.verbose
    local all_passed = true

    for _idx, test_def in ipairs(REASONING_TESTS) do
        local provider = test_def.provider

        -- Skip if specific provider requested and this isn't it
        if target and target ~= provider then
            goto continue
        end

        -- Skip if provider disabled in local config
        if TestConfig.isProviderSkipped(provider) then
            self:log(provider, test_def.name, "skip", "disabled in local config", 0)
            goto continue
        end

        -- Skip if no API key
        local api_key = apikeys[provider]
        if not TestConfig.isValidApiKey(api_key) then
            self:log(provider, test_def.name, "skip", "no API key", 0)
            goto continue
        end

        -- Print test name
        io.write(string.format("  %-40s ", test_def.name))
        io.flush()

        -- Run test
        local success = self:runTest(test_def, api_key, verbose)
        if not success then
            all_passed = false
        end

        -- Print inline result
        local last = self.results[#self.results]
        if last.status == "pass" then
            local time_str = last.elapsed and TestConfig.formatTime(last.elapsed) or ""
            local reasoning_str = last.reasoning_found and " [reasoning found]" or ""
            print(string.format("\27[32m✓ PASS\27[0m  (%s)%s", time_str, reasoning_str))
        elseif last.status == "fail" then
            print("\27[31m✗ FAIL\27[0m")
            print(string.format("  %42s%s", "", tostring(last.message)))
        else
            print(string.format("\27[33m⊘ SKIP\27[0m  (%s)", last.message))
        end

        ::continue::
    end

    return all_passed
end

function ReasoningTests:printSummary()
    print("")
    print(string.rep("-", 70))
    print(string.format("  Reasoning Tests: \27[32m%d passed\27[0m, \27[31m%d failed\27[0m, \27[33m%d skipped\27[0m",
        self.passed, self.failed, self.skipped))

    if self.failed > 0 then
        print("")
        print("  Failed tests:")
        for _idx, r in ipairs(self.results) do
            if r.status == "fail" then
                print(string.format("    - %s: %s", r.test, tostring(r.message)))
            end
        end
    end

    -- Show reasoning detection summary
    local found, not_found = 0, 0
    for _idx, r in ipairs(self.results) do
        if r.status == "pass" then
            if r.reasoning_found then
                found = found + 1
            else
                not_found = not_found + 1
            end
        end
    end
    if found > 0 or not_found > 0 then
        print(string.format("  Reasoning detected: %d/%d passed tests", found, found + not_found))
    end

    print("")
end

return ReasoningTests
