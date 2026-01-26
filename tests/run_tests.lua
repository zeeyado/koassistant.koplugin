#!/usr/bin/env lua
-- KOAssistant Test Runner
-- Runs unit tests (no API calls) and integration tests (real API calls)
--
-- Usage:
--   lua tests/run_tests.lua              # Run integration tests (providers)
--   lua tests/run_tests.lua --unit       # Run unit tests only (fast, free)
--   lua tests/run_tests.lua --all        # Run all tests
--   lua tests/run_tests.lua anthropic    # Test single provider
--   lua tests/run_tests.lua --verbose    # Show responses
--   lua tests/run_tests.lua openai -v    # Test one provider, verbose
--   lua tests/run_tests.lua groq --full  # Run comprehensive tests for a provider
--   lua tests/run_tests.lua --full       # Run comprehensive tests for all providers

-- Detect script location and set up paths
local function setupPaths()
    local info = debug.getinfo(1, "S")
    local script_path = info.source:match("@?(.*)")

    -- Get directory containing this script
    local tests_dir = script_path:match("(.+)/[^/]+$") or "."

    -- Go up one level to get plugin directory
    local plugin_dir = tests_dir:match("(.+)/[^/]+$") or "."

    -- Debug path detection
    -- print("Script path:", script_path)
    -- print("Tests dir:", tests_dir)
    -- print("Plugin dir:", plugin_dir)

    -- Set up package path to find our modules
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

-- Now load test configuration
local TestConfig = require("test_config")

-- Parse command line arguments
local function parseArgs()
    local args = {
        provider = nil,
        verbose = false,
        help = false,
        unit = false,
        all = false,
        full = false,
        models = false,
    }

    -- Apply defaults from local config
    args.verbose = TestConfig.isVerboseDefault()

    for i = 1, #arg do
        local a = arg[i]
        if a == "--verbose" or a == "-v" then
            args.verbose = true
        elseif a == "--help" or a == "-h" then
            args.help = true
        elseif a == "--unit" then
            args.unit = true
        elseif a == "--all" then
            args.all = true
        elseif a == "--full" then
            args.full = true
        elseif a == "--models" then
            args.models = true
        elseif not a:match("^%-") then
            args.provider = a
        end
    end

    return args
end

local function printUsage()
    print([[
KOAssistant Test Runner

Usage: lua tests/run_tests.lua [options] [provider]

Options:
  --unit           Run unit tests only (fast, no API calls)
  --all            Run both unit and integration tests
  --full           Run comprehensive tests (behaviors, temps, domains, languages)
  --models         Validate ALL models (minimal cost ~1 token per model)
  -v, --verbose    Show API responses
  -h, --help       Show this help

Examples:
  lua tests/run_tests.lua              # Basic connectivity test for all providers
  lua tests/run_tests.lua --unit       # Run unit tests only (fast, free)
  lua tests/run_tests.lua --all        # Run all tests (unit + integration)
  lua tests/run_tests.lua anthropic    # Test only Anthropic (basic)
  lua tests/run_tests.lua groq --full  # Comprehensive tests for Groq
  lua tests/run_tests.lua --full       # Comprehensive tests for all providers
  lua tests/run_tests.lua --models     # Validate all models (detects constraints)
  lua tests/run_tests.lua --models openai  # Validate only OpenAI models
  lua tests/run_tests.lua -v openai    # Test OpenAI with verbose output

Providers:
  anthropic, openai, deepseek, gemini, ollama, groq, mistral,
  xai, openrouter, qwen, kimi, together, fireworks, sambanova,
  cohere, doubao

Configuration:
  Create tests/local_config.lua from tests/local_config.lua.sample
  to customize paths and default settings.

Note: Providers without valid API keys in apikeys.lua will be skipped.
]])
end

-- Discover unit test files
local function discoverUnitTests()
    local tests = {}
    local unit_dir = TESTS_DIR .. "/unit"

    -- Use io.popen to list files (works on Unix-like systems)
    local handle = io.popen('ls "' .. unit_dir .. '"/*.lua 2>/dev/null')
    if handle then
        for file in handle:lines() do
            table.insert(tests, file)
        end
        handle:close()
    end

    return tests
end

-- Run unit tests
local function runUnitTests()
    print("")
    print(string.rep("=", 70))
    print("  Unit Tests (No API Calls)")
    print(string.rep("=", 70))

    local tests = discoverUnitTests()
    if #tests == 0 then
        print("\n  No unit tests found in tests/unit/")
        return true
    end

    local all_passed = true

    for _, test_file in ipairs(tests) do
        -- Extract test name
        local test_name = test_file:match("([^/]+)%.lua$")
        print(string.format("\n  Running: %s", test_name))

        -- Load and run the test
        local chunk, err = loadfile(test_file)
        if not chunk then
            print(string.format("    ✗ Failed to load: %s", err))
            all_passed = false
        else
            local ok, result = pcall(chunk)
            if not ok then
                print(string.format("    ✗ Error: %s", tostring(result)))
                all_passed = false
            elseif result == false then
                all_passed = false
            end
        end
    end

    return all_passed
end

-- Test a single provider
local function testProvider(provider, api_key, verbose)
    -- Validate API key
    if not TestConfig.isValidApiKey(api_key) then
        return nil, "No valid API key"
    end

    -- Load the handler
    local handler_ok, handler = pcall(require, "koassistant_api." .. provider)
    if not handler_ok then
        return false, "Failed to load handler: " .. tostring(handler)
    end

    -- Build test config
    -- Note: max_tokens defaults to 512 in test_config to handle thinking models
    local config = TestConfig.buildConfig(provider, api_key, {
        system_prompt = "You are a test assistant. Respond very briefly.",
        debug = verbose,
    })

    -- Get test messages
    local messages = TestConfig.getTestMessages()

    -- Make the request
    -- Use socket.gettime() for wall-clock time (os.clock() measures CPU time, not I/O wait)
    local socket = require("socket")
    local start_time = socket.gettime()
    local ok, result = pcall(function()
        return handler:query(messages, config)
    end)
    local elapsed = socket.gettime() - start_time

    if not ok then
        return false, "Exception: " .. tostring(result), elapsed
    end

    -- Check result
    if type(result) == "string" then
        if result:match("^Error:") then
            return false, result, elapsed
        else
            return true, result, elapsed
        end
    elseif type(result) == "function" then
        -- Handler returned streaming function (shouldn't happen with streaming disabled)
        return false, "Handler returned streaming function (streaming should be disabled)", elapsed
    else
        return false, "Unexpected result type: " .. type(result), elapsed
    end
end

-- Run model validation tests (--models flag)
local function runModelValidation(args)
    -- Load the model validation module
    local ModelValidation = require("integration.test_model_validation")
    ModelValidation:reset()

    return ModelValidation:runAllValidation(args)
end

-- Run comprehensive tests (--full flag)
local function runFullTests(args)
    -- Load the full provider test module
    local FullProviderTests = require("integration.test_full_provider")
    FullProviderTests:reset()

    -- Load API keys
    local apikeys = TestConfig.loadApiKeys()

    -- Print header
    print("")
    print(string.rep("=", 70))
    print("  KOAssistant Comprehensive Provider Tests (--full)")
    print(string.rep("=", 70))

    -- Get providers to test
    local providers = TestConfig.getAllProviders()
    local target = args.provider

    -- If no specific provider, use default from local config if set
    if not target and not args.full then
        -- This shouldn't happen, but just in case
        target = TestConfig.getDefaultProvider()
    end

    local all_passed = true

    -- Test each provider
    for _, provider in ipairs(providers) do
        -- Skip if specific provider requested and this isn't it
        if target and target ~= provider then
            goto continue
        end

        -- Check if provider should be skipped via local config
        if TestConfig.isProviderSkipped(provider) then
            print(string.format("\n  [%s] \27[33m⊘ SKIP\27[0m (disabled in local config)", provider))
            goto continue
        end

        -- Get API key for this provider
        local api_key = apikeys[provider]

        if not TestConfig.isValidApiKey(api_key) then
            print(string.format("\n  [%s] \27[33m⊘ SKIP\27[0m (no API key)", provider))
            goto continue
        end

        -- Run full tests for this provider
        local success = FullProviderTests:runAllTests(provider, api_key, args.verbose)
        if not success then
            all_passed = false
        end

        ::continue::
    end

    -- Print summary
    FullProviderTests:printSummary()

    return all_passed
end

-- Run integration tests (provider tests with real API calls)
local function runIntegrationTests(args)
    -- Load API keys
    local apikeys = TestConfig.loadApiKeys()

    -- Print header
    print("")
    print(string.rep("=", 70))
    print("  KOAssistant Provider Tests")
    print(string.rep("=", 70))
    print("")

    -- Get providers to test
    local providers = TestConfig.getAllProviders()
    local target = args.provider

    -- Track results
    local results = {
        passed = {},
        failed = {},
        skipped = {},
    }

    -- Test each provider
    for _, provider in ipairs(providers) do
        -- Skip if specific provider requested and this isn't it
        if target and target ~= provider then
            goto continue
        end

        -- Get API key for this provider
        local api_key = apikeys[provider]

        -- Run test
        io.write(string.format("  %-12s ", provider))
        io.flush()

        local success, response, elapsed = testProvider(provider, api_key, args.verbose)

        if success == nil then
            -- Skipped (no API key)
            print("\27[33m⊘ SKIP\27[0m  (no API key)")
            table.insert(results.skipped, provider)
        elseif success then
            -- Passed
            local time_str = elapsed and TestConfig.formatTime(elapsed) or ""
            print(string.format("\27[32m✓ PASS\27[0m  (%s)", time_str))
            table.insert(results.passed, provider)

            if args.verbose and response then
                -- Show truncated response
                local clean = response:gsub("\n", " "):sub(1, 80)
                print(string.format("           → %s%s", clean, #response > 80 and "..." or ""))
            end
        else
            -- Failed
            print("\27[31m✗ FAIL\27[0m")
            print(string.format("           %s", tostring(response)))
            table.insert(results.failed, { provider = provider, error = response })
        end

        ::continue::
    end

    -- Print summary
    print("")
    print(string.rep("-", 70))
    print(string.format("  Results: \27[32m%d passed\27[0m, \27[31m%d failed\27[0m, \27[33m%d skipped\27[0m",
        #results.passed, #results.failed, #results.skipped))

    if #results.failed > 0 then
        print("")
        print("  Failed providers:")
        for _, f in ipairs(results.failed) do
            print(string.format("    - %s: %s", f.provider, tostring(f.error)))
        end
    end

    print("")

    -- Exit with error code if any failed
    return #results.failed == 0
end

-- Main entry point
local args = parseArgs()

if args.help then
    printUsage()
    os.exit(0)
end

local success = true

-- Run unit tests if --unit or --all
if args.unit or args.all then
    local unit_success = runUnitTests()
    success = success and unit_success
end

-- Run model validation tests if --models flag is set
if args.models then
    local models_success = runModelValidation(args)
    success = success and models_success
-- Run full comprehensive tests if --full flag is set
elseif args.full then
    local full_success = runFullTests(args)
    success = success and full_success
-- Run basic integration tests if --all or no specific flag (default behavior)
elseif args.all or (not args.unit) then
    local integration_success = runIntegrationTests(args)
    success = success and integration_success
end

os.exit(success and 0 or 1)
