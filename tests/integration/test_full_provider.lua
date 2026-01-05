-- Comprehensive Provider Tests (--full flag)
-- Tests behaviors, temperatures, domains, languages, and provider-specific features
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

local PLUGIN_DIR, TESTS_DIR = setupPaths()

-- Load mocks BEFORE any plugin modules
require("mock_koreader")

-- Load test configuration
local TestConfig = require("test_config")

-- Test Framework
local FullProviderTests = {
    passed = 0,
    failed = 0,
    skipped = 0,
    results = {},
}

function FullProviderTests:log(provider, test_name, status, message, elapsed)
    table.insert(self.results, {
        provider = provider,
        test = test_name,
        status = status,
        message = message,
        elapsed = elapsed,
    })

    if status == "pass" then
        self.passed = self.passed + 1
    elseif status == "fail" then
        self.failed = self.failed + 1
    else
        self.skipped = self.skipped + 1
    end
end

-- Get max temperature for a provider
local function getMaxTemperature(provider)
    if provider == "anthropic" then
        return 1.0  -- Anthropic caps at 1.0
    else
        return 2.0  -- Most others support 2.0
    end
end

-- Make a test request and verify it succeeds
local function makeTestRequest(handler, messages, config, provider)
    local start_time = os.clock()
    local ok, result = pcall(function()
        return handler:query(messages, config)
    end)
    local elapsed = os.clock() - start_time

    if not ok then
        return false, "Exception: " .. tostring(result), elapsed
    end

    if type(result) == "string" then
        if result:match("^Error:") then
            return false, result, elapsed
        else
            return true, result, elapsed
        end
    elseif type(result) == "function" then
        return false, "Unexpected streaming function", elapsed
    else
        return false, "Unexpected result type: " .. type(result), elapsed
    end
end

-- Test 1: Basic connectivity
function FullProviderTests:testBasicConnectivity(provider, handler, api_key, verbose)
    local config = TestConfig.buildConfig(provider, api_key, {
        system_prompt = "You are a test assistant. Respond with just 'OK'.",
        max_tokens = 256,  -- Increased for Gemini 2.5+ models
    })
    local messages = {{ role = "user", content = "Say OK" }}

    local success, result, elapsed = makeTestRequest(handler, messages, config, provider)
    self:log(provider, "Basic connectivity", success and "pass" or "fail",
        success and "Response received" or result, elapsed)

    if verbose and success then
        print(string.format("        Response: %s", result:sub(1, 50)))
    end

    return success
end

-- Test 2: Minimal behavior
function FullProviderTests:testMinimalBehavior(provider, handler, api_key, verbose)
    local config = TestConfig.buildFullConfig(provider, api_key, {
        behavior_variant = "minimal",
        max_tokens = 256,  -- Increased for Gemini 2.5+ models
    })
    local messages = {{ role = "user", content = "What is 2+2? Just the number." }}

    local success, result, elapsed = makeTestRequest(handler, messages, config, provider)
    self:log(provider, "Minimal behavior", success and "pass" or "fail",
        success and "Minimal behavior applied" or result, elapsed)

    if verbose and success then
        print(string.format("        Response: %s", result:sub(1, 50)))
    end

    return success
end

-- Test 3: Full behavior
function FullProviderTests:testFullBehavior(provider, handler, api_key, verbose)
    local config = TestConfig.buildFullConfig(provider, api_key, {
        behavior_variant = "full",
        max_tokens = 512,  -- Full behavior adds ~500 tokens system prompt
    })
    local messages = {{ role = "user", content = "Hello, who are you?" }}

    local success, result, elapsed = makeTestRequest(handler, messages, config, provider)
    self:log(provider, "Full behavior", success and "pass" or "fail",
        success and "Full behavior applied" or result, elapsed)

    if verbose and success then
        print(string.format("        Response: %s", result:sub(1, 80)))
    end

    return success
end

-- Test 4: Temperature 0.0 (deterministic)
function FullProviderTests:testTemperatureZero(provider, handler, api_key, verbose)
    local config = TestConfig.buildConfig(provider, api_key, {
        temperature = 0.0,
        max_tokens = 256,  -- Increased for Gemini 2.5+ models
    })
    local messages = {{ role = "user", content = "What is the capital of France? One word." }}

    local success, result, elapsed = makeTestRequest(handler, messages, config, provider)
    self:log(provider, "Temperature 0.0", success and "pass" or "fail",
        success and "Deterministic mode works" or result, elapsed)

    if verbose and success then
        print(string.format("        Response: %s", result:sub(1, 50)))
    end

    return success
end

-- Test 5: Temperature max
function FullProviderTests:testTemperatureMax(provider, handler, api_key, verbose)
    local max_temp = getMaxTemperature(provider)
    local config = TestConfig.buildConfig(provider, api_key, {
        temperature = max_temp,
        max_tokens = 2048,  -- Gemini 2.5+ needs more tokens at high temp
    })
    local messages = {{ role = "user", content = "Write a creative one-sentence story." }}

    local success, result, elapsed = makeTestRequest(handler, messages, config, provider)
    self:log(provider, string.format("Temperature %.1f", max_temp), success and "pass" or "fail",
        success and "Max temperature works" or result, elapsed)

    if verbose and success then
        print(string.format("        Response: %s", result:sub(1, 80)))
    end

    return success
end

-- Test 6: Domain context
function FullProviderTests:testDomainContext(provider, handler, api_key, verbose)
    local config = TestConfig.buildFullConfig(provider, api_key, {
        behavior_variant = "minimal",
        domain_context = "This conversation is about astronomy and space science.",
        max_tokens = 2048,  -- Gemini 2.5+ may need more tokens
    })
    local messages = {{ role = "user", content = "What is a popular thing to observe?" }}

    local success, result, elapsed = makeTestRequest(handler, messages, config, provider)

    -- Check if response mentions astronomy-related terms
    local space_related = result and (
        result:lower():find("star") or
        result:lower():find("planet") or
        result:lower():find("moon") or
        result:lower():find("galaxy") or
        result:lower():find("telescope") or
        result:lower():find("celestial") or
        result:lower():find("cosmos") or
        result:lower():find("astro")
    )

    local status = success and (space_related and "pass" or "fail")
    local message = success and (space_related and "Domain context applied" or "Response didn't reflect domain") or result

    self:log(provider, "Domain context", status or "fail", message, elapsed)

    if verbose and success then
        print(string.format("        Response: %s", result:sub(1, 100)))
    end

    return status == "pass"
end

-- Test 7: Language instruction
function FullProviderTests:testLanguageInstruction(provider, handler, api_key, verbose)
    local config = TestConfig.buildFullConfig(provider, api_key, {
        behavior_variant = "minimal",
        user_languages = "Spanish, English",
        primary_language = "Spanish",
        max_tokens = 1024,  -- Gemini 2.5+ may need more tokens
    })
    local messages = {{ role = "user", content = "Say hello" }}

    local success, result, elapsed = makeTestRequest(handler, messages, config, provider)

    -- Check if response is in Spanish
    local in_spanish = result and (
        result:lower():find("hola") or
        result:lower():find("buenos") or
        result:lower():find("saludo")
    )

    local status = success and (in_spanish and "pass" or "fail")
    local message = success and (in_spanish and "Language instruction applied" or "Response not in Spanish") or result

    self:log(provider, "Language instruction", status or "fail", message, elapsed)

    if verbose and success then
        print(string.format("        Response: %s", result:sub(1, 80)))
    end

    return status == "pass"
end

-- Test 8: Extended thinking (Anthropic only)
function FullProviderTests:testExtendedThinking(provider, handler, api_key, verbose)
    if provider ~= "anthropic" then
        self:log(provider, "Extended thinking", "skip", "Only supported by Anthropic", 0)
        return true  -- Not a failure, just not applicable
    end

    local config = TestConfig.buildFullConfig(provider, api_key, {
        extended_thinking = true,
        thinking_budget = 2048,
        max_tokens = 4096,  -- Must be > thinking_budget
    })
    local messages = {{ role = "user", content = "What is 17 * 23?" }}

    local success, result, elapsed = makeTestRequest(handler, messages, config, provider)
    self:log(provider, "Extended thinking", success and "pass" or "fail",
        success and "Extended thinking works" or result, elapsed)

    if verbose and success then
        print(string.format("        Response: %s", result:sub(1, 80)))
    end

    return success
end

-- Run all tests for a provider
function FullProviderTests:runAllTests(provider, api_key, verbose)
    -- Load handler
    local handler_ok, handler = pcall(require, "api_handlers." .. provider)
    if not handler_ok then
        self:log(provider, "Load handler", "fail", "Failed to load: " .. tostring(handler), 0)
        return false
    end

    print(string.format("\n  [%s] Running comprehensive tests...", provider))

    local all_passed = true

    -- Run each test
    local tests = {
        { name = "Basic connectivity", fn = self.testBasicConnectivity },
        { name = "Minimal behavior", fn = self.testMinimalBehavior },
        { name = "Full behavior", fn = self.testFullBehavior },
        { name = "Temperature 0.0", fn = self.testTemperatureZero },
        { name = "Temperature max", fn = self.testTemperatureMax },
        { name = "Domain context", fn = self.testDomainContext },
        { name = "Language instruction", fn = self.testLanguageInstruction },
        { name = "Extended thinking", fn = self.testExtendedThinking },
    }

    for _, test in ipairs(tests) do
        io.write(string.format("    %-24s ", test.name))
        io.flush()

        local ok, result = pcall(test.fn, self, provider, handler, api_key, verbose)

        if not ok then
            print("\27[31m✗ ERROR\27[0m")
            print(string.format("      Exception: %s", tostring(result)))
            self:log(provider, test.name, "fail", "Exception: " .. tostring(result), 0)
            all_passed = false
        else
            -- Result already logged by test function, just print status
            local last_result = self.results[#self.results]
            if last_result.status == "pass" then
                local time_str = last_result.elapsed and TestConfig.formatTime(last_result.elapsed) or ""
                print(string.format("\27[32m✓ PASS\27[0m  (%s)", time_str))
            elseif last_result.status == "skip" then
                print("\27[33m⊘ SKIP\27[0m")
            else
                print("\27[31m✗ FAIL\27[0m")
                -- Show full error message for debugging
                print(string.format("      %s", last_result.message))
                all_passed = false
            end
        end
    end

    return all_passed
end

-- Print summary
function FullProviderTests:printSummary()
    print("")
    print(string.rep("-", 70))
    print(string.format("  Full Test Results: \27[32m%d passed\27[0m, \27[31m%d failed\27[0m, \27[33m%d skipped\27[0m",
        self.passed, self.failed, self.skipped))

    if self.failed > 0 then
        print("")
        print("  Failed tests:")
        for _, r in ipairs(self.results) do
            if r.status == "fail" then
                -- Show full error message in summary for debugging
                print(string.format("    - %s: %s", r.provider, r.test))
                print(string.format("      %s", r.message))
            end
        end
    end

    print("")
end

-- Reset state for new test run
function FullProviderTests:reset()
    self.passed = 0
    self.failed = 0
    self.skipped = 0
    self.results = {}
end

-- Export for use by run_tests.lua
return FullProviderTests
