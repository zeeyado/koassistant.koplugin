#!/usr/bin/env lua
-- KOAssistant Test Runner
-- Tests all AI providers with real API calls
--
-- Usage:
--   lua tests/run_tests.lua              # Test all providers
--   lua tests/run_tests.lua anthropic    # Test single provider
--   lua tests/run_tests.lua --verbose    # Show responses
--   lua tests/run_tests.lua openai -v    # Test one provider, verbose

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
    }

    for i = 1, #arg do
        local a = arg[i]
        if a == "--verbose" or a == "-v" then
            args.verbose = true
        elseif a == "--help" or a == "-h" then
            args.help = true
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
  -v, --verbose    Show API responses
  -h, --help       Show this help

Examples:
  lua tests/run_tests.lua              # Test all providers
  lua tests/run_tests.lua anthropic    # Test only Anthropic
  lua tests/run_tests.lua -v openai    # Test OpenAI with verbose output

Providers:
  anthropic, openai, deepseek, gemini, ollama, groq, mistral,
  xai, openrouter, qwen, kimi, together, fireworks, sambanova,
  cohere, doubao

Note: Providers without valid API keys in apikeys.lua will be skipped.
]])
end

-- Test a single provider
local function testProvider(provider, api_key, verbose)
    -- Validate API key
    if not TestConfig.isValidApiKey(api_key) then
        return nil, "No valid API key"
    end

    -- Load the handler
    local handler_ok, handler = pcall(require, "api_handlers." .. provider)
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
    local start_time = os.clock()
    local ok, result = pcall(function()
        return handler:query(messages, config)
    end)
    local elapsed = os.clock() - start_time

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

-- Main test runner
local function runTests(args)
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
            print(string.format("           %s", tostring(response):sub(1, 100)))
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
            print(string.format("    - %s: %s", f.provider, tostring(f.error):sub(1, 60)))
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

local success = runTests(args)
os.exit(success and 0 or 1)
