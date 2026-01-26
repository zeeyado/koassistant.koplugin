-- Model Validation Tests (--models flag)
-- Tests ALL models across ALL providers with minimal cost
-- Detects: invalid model names, parameter constraints, API issues

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

-- Load dependencies
local TestConfig = require("test_config")
local json = require("json")
local https = require("ssl.https")
local http = require("socket.http")
local ltn12 = require("ltn12")
local socket = require("socket")

-- Test Framework
local ModelValidation = {
    passed = 0,
    failed = 0,
    skipped = 0,
    constraints = {},  -- Detected parameter constraints
    invalid_models = {},  -- Models not found in API
    results = {},
}

function ModelValidation:log(provider, model, status, message, elapsed, constraint_info)
    table.insert(self.results, {
        provider = provider,
        model = model,
        status = status,
        message = message,
        elapsed = elapsed,
        constraint = constraint_info,
    })

    if status == "pass" then
        self.passed = self.passed + 1
    elseif status == "fail" then
        self.failed = self.failed + 1
    elseif status == "constraint" then
        self.passed = self.passed + 1  -- Constraint detected but model works
        table.insert(self.constraints, {
            provider = provider,
            model = model,
            constraint = constraint_info,
        })
    else
        self.skipped = self.skipped + 1
    end
end

-- Reset state for new test run
function ModelValidation:reset()
    self.passed = 0
    self.failed = 0
    self.skipped = 0
    self.constraints = {}
    self.invalid_models = {}
    self.results = {}
end

--------------------------------------------------------------------------------
-- Model List Fetchers (Pre-validation)
--------------------------------------------------------------------------------

-- Fetch available models from OpenAI API
local function fetchOpenAIModels(api_key)
    if not api_key or api_key == "" then return nil, "No API key" end

    local responseBody = {}
    local success, code = https.request({
        url = "https://api.openai.com/v1/models",
        method = "GET",
        headers = {
            ["Authorization"] = "Bearer " .. api_key,
        },
        sink = ltn12.sink.table(responseBody),
    })

    if not success or code ~= 200 then
        return nil, string.format("HTTP %s", tostring(code))
    end

    local response_text = table.concat(responseBody)
    local ok, data = pcall(json.decode, response_text)
    if not ok or not data or not data.data then
        return nil, "Invalid response"
    end

    local models = {}
    for _, model in ipairs(data.data) do
        models[model.id] = true
    end
    return models, nil
end

-- Fetch available models from Gemini API
local function fetchGeminiModels(api_key)
    if not api_key or api_key == "" then return nil, "No API key" end

    local responseBody = {}
    local url = "https://generativelanguage.googleapis.com/v1beta/models?key=" .. api_key
    local success, code = https.request({
        url = url,
        method = "GET",
        sink = ltn12.sink.table(responseBody),
    })

    if not success or code ~= 200 then
        return nil, string.format("HTTP %s", tostring(code))
    end

    local response_text = table.concat(responseBody)
    local ok, data = pcall(json.decode, response_text)
    if not ok or not data or not data.models then
        return nil, "Invalid response"
    end

    local models = {}
    for _, model in ipairs(data.models) do
        -- Gemini returns names like "models/gemini-2.5-pro"
        local name = model.name:match("models/(.+)") or model.name
        models[name] = true
    end
    return models, nil
end

-- Fetch available models from Ollama (local)
local function fetchOllamaModels()
    local responseBody = {}
    local success, code = http.request({
        url = "http://localhost:11434/api/tags",
        method = "GET",
        sink = ltn12.sink.table(responseBody),
    })

    if not success or code ~= 200 then
        return nil, string.format("HTTP %s (is Ollama running?)", tostring(code))
    end

    local response_text = table.concat(responseBody)
    local ok, data = pcall(json.decode, response_text)
    if not ok or not data or not data.models then
        return nil, "Invalid response"
    end

    local models = {}
    for _, model in ipairs(data.models) do
        -- Ollama returns names like "llama3:latest", store both full and base name
        models[model.name] = true
        local base = model.name:match("^([^:]+)")
        if base then
            models[base] = true
        end
    end
    return models, nil
end

-- Get model fetcher for provider (if available)
local function getModelFetcher(provider)
    local fetchers = {
        openai = fetchOpenAIModels,
        gemini = fetchGeminiModels,
        ollama = fetchOllamaModels,
    }
    return fetchers[provider]
end

--------------------------------------------------------------------------------
-- Constraint Error Detection
--------------------------------------------------------------------------------

-- Parse error message to detect constraint type
local function parseConstraintError(error_msg)
    if not error_msg then return nil end

    local lower = error_msg:lower()

    -- Temperature constraints (various formats from different providers)
    -- OpenAI: "Unsupported value: 'temperature' is not supported"
    -- OpenAI: "temperature must be"
    -- Generic: "temperature" in error
    if lower:find("temperature") or
       (lower:find("unsupported") and lower:find("value")) or
       lower:find("'temperature'") then
        -- Try to extract allowed value
        local allowed = error_msg:match("must be (%d+%.?%d*)") or
                       error_msg:match("should be (%d+%.?%d*)") or
                       error_msg:match("only supports? (%d+%.?%d*)") or
                       error_msg:match("expected (%d+%.?%d*)")
        return {
            type = "temperature",
            message = error_msg,
            allowed = allowed and tonumber(allowed) or 1.0,
        }
    end

    -- Max tokens constraints (must check before "unsupported parameter")
    -- Also handles Gemini thinking models: "MAX_TOKENS hit before output"
    if lower:find("max_tokens") or lower:find("max_completion_tokens") or
       lower:find("max_tokens hit") or lower:find("increase max_tokens") then
        local min_value = error_msg:match("at least (%d+)") or
                         error_msg:match("minimum.-%s(%d+)") or
                         error_msg:match(">=%s*(%d+)") or
                         error_msg:match("greater than (%d+)")
        -- For Gemini thinking models (2.5+), need much higher tokens
        -- gemini-2.5-pro especially needs more for internal reasoning
        if lower:find("thinking") or lower:find("before output") then
            min_value = 256  -- Gemini 2.5+ may use 50-100+ tokens for thinking
        end
        return {
            type = "max_tokens",
            message = error_msg,
            min_value = min_value and tonumber(min_value) or 16,
        }
    end

    -- Model not found (check before generic unsupported parameter)
    if lower:find("not found") or lower:find("does not exist") or
       lower:find("invalid model") or lower:find("unknown model") or
       lower:find("not a chat model") then
        return {
            type = "model_not_found",
            message = error_msg,
        }
    end

    -- Unsupported parameter (generic - could be temperature or other)
    -- OpenAI o-series: "Unsupported parameter: 'temperature'"
    if lower:find("unsupported parameter") then
        return {
            type = "temperature",  -- Most common unsupported param
            message = error_msg,
            allowed = 1.0,
        }
    end

    return nil
end

--------------------------------------------------------------------------------
-- Minimal Test Request
--------------------------------------------------------------------------------

-- Make ultra-minimal test request (1 token output)
local function makeMinimalRequest(handler, model, api_key, config_overrides)
    config_overrides = config_overrides or {}

    local config = {
        provider = handler.provider_name or "unknown",
        api_key = api_key,
        model = model,
        system = {
            text = "",  -- Empty system prompt to minimize tokens
            enable_caching = false,
        },
        api_params = {
            temperature = config_overrides.temperature or 0.7,
            max_tokens = config_overrides.max_tokens or 1,
        },
        features = {
            enable_streaming = false,
            debug = false,
        },
    }

    local messages = {{ role = "user", content = "Reply: 1" }}

    local start_time = socket.gettime()
    local ok, result = pcall(function()
        return handler:query(messages, config)
    end)
    local elapsed = socket.gettime() - start_time

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

--------------------------------------------------------------------------------
-- Test Runner
--------------------------------------------------------------------------------

-- Test a single model with auto-retry on constraint errors
function ModelValidation:testModel(provider, model, handler, api_key, verbose)
    -- First attempt with default parameters
    local success, result, elapsed = makeMinimalRequest(handler, model, api_key)

    if success then
        self:log(provider, model, "pass", "OK", elapsed)
        if verbose then
            print(string.format("        Response: %s", (result or ""):sub(1, 30)))
        end
        return true
    end

    -- Check if it's a constraint error
    local constraint = parseConstraintError(result)

    if constraint then
        if constraint.type == "model_not_found" then
            self:log(provider, model, "fail", result, elapsed)
            table.insert(self.invalid_models, {
                provider = provider,
                model = model,
                error = result,
            })
            return false
        end

        -- Try retry with adjusted parameters (single param first)
        local retry_config = {}
        local param_name = ""
        local param_value = ""

        if constraint.type == "temperature" then
            retry_config.temperature = constraint.allowed or 1.0
            param_name = "temp"
            param_value = tostring(retry_config.temperature)
        end

        if constraint.type == "max_tokens" then
            retry_config.max_tokens = constraint.min_value or 16
            param_name = "max_tokens"
            param_value = tostring(retry_config.max_tokens)
        end

        -- Retry with adjusted single param
        local retry_success, retry_result, retry_elapsed = makeMinimalRequest(
            handler, model, api_key, retry_config
        )

        if retry_success then
            local constraint_msg = string.format(
                "%s (default rejected, %s=%s works)",
                constraint.type, param_name, param_value
            )
            self:log(provider, model, "constraint", constraint_msg, retry_elapsed, constraint)
            return true
        end

        -- Single param retry failed - try with BOTH adjustments
        local both_config = {
            temperature = 1.0,
            max_tokens = 16,
        }

        local both_success, both_result, both_elapsed = makeMinimalRequest(
            handler, model, api_key, both_config
        )

        if both_success then
            -- Both params needed
            local constraint_msg = "multiple constraints (temp=1.0 + max_tokens=16 works)"
            local combined_constraint = {
                type = "multiple",
                message = result,
                temperature = 1.0,
                max_tokens = 16,
            }
            self:log(provider, model, "constraint", constraint_msg, both_elapsed, combined_constraint)
            return true
        end

        -- Both retries failed
        self:log(provider, model, "fail", result, elapsed)
        return false
    end

    -- Non-constraint error
    self:log(provider, model, "fail", result, elapsed)
    return false
end

-- Run validation for a single provider
function ModelValidation:runProviderValidation(provider, api_key, verbose)
    local ModelLists = require("koassistant_model_lists")
    local models = ModelLists[provider]

    if not models or #models == 0 then
        print(string.format("  [%s] \27[33m? No models defined\27[0m", provider))
        return true
    end

    -- Load handler
    local handler_ok, handler = pcall(require, "koassistant_api." .. provider)
    if not handler_ok then
        print(string.format("  [%s] \27[31m? Failed to load handler\27[0m: %s", provider, tostring(handler)))
        return false
    end

    print(string.format("\n  [%s] Testing %d models...", provider, #models))

    -- Pre-validation: check model list if available
    local fetcher = getModelFetcher(provider)
    local api_models, fetch_error

    if fetcher then
        io.write(string.format("    Pre-check: "))
        io.flush()

        if provider == "ollama" then
            api_models, fetch_error = fetcher()
        else
            api_models, fetch_error = fetcher(api_key)
        end

        if api_models then
            -- Check which models in our list are not in API
            local not_in_api = {}
            for _, model in ipairs(models) do
                if not api_models[model] then
                    table.insert(not_in_api, model)
                end
            end

            if #not_in_api > 0 then
                print(string.format("\27[33m%d models not in API list\27[0m", #not_in_api))
                for _, m in ipairs(not_in_api) do
                    print(string.format("      \27[33m?\27[0m %s", m))
                end
            else
                print("\27[32mAll models found in API\27[0m")
            end
        else
            print(string.format("\27[33mN/A\27[0m (%s)", fetch_error or "unknown error"))
        end
    else
        print(string.format("    Pre-check: \27[33mN/A\27[0m (no list endpoint)"))
    end

    -- Test each model
    local all_passed = true
    for _, model in ipairs(models) do
        -- Skip "custom" placeholder for OpenRouter
        if model == "custom" then
            goto continue
        end

        io.write(string.format("    %-40s ", model:sub(1, 40)))
        io.flush()

        local ok = self:testModel(provider, model, handler, api_key, verbose)

        -- Print result
        local last_result = self.results[#self.results]
        if last_result.status == "pass" then
            local time_str = last_result.elapsed and TestConfig.formatTime(last_result.elapsed) or ""
            print(string.format("\27[32m? OK\27[0m (%s)", time_str))
        elseif last_result.status == "constraint" then
            print(string.format("\27[33m? CONSTRAINT\27[0m: %s", last_result.message))
        elseif last_result.status == "skip" then
            print("\27[33m? SKIP\27[0m")
        else
            print("\27[31m? FAIL\27[0m")
            -- Show full error message
            print(string.format("      %s", last_result.message or ""))
            all_passed = false
        end

        ::continue::
    end

    return all_passed
end

-- Run validation for all providers
function ModelValidation:runAllValidation(args)
    local apikeys = TestConfig.loadApiKeys()
    local providers = TestConfig.getAllProviders()
    local target = args.provider

    print("")
    print(string.rep("=", 70))
    print("  Model Validation Tests (--models)")
    print(string.rep("=", 70))

    local all_passed = true

    for _, provider in ipairs(providers) do
        -- Skip if specific provider requested
        if target and target ~= provider then
            goto continue
        end

        -- Check if provider should be skipped via local config
        if TestConfig.isProviderSkipped(provider) then
            print(string.format("\n  [%s] \27[33m? SKIP\27[0m (disabled in local config)", provider))
            goto continue
        end

        -- Get API key
        local api_key = apikeys[provider]

        if not TestConfig.isValidApiKey(api_key) then
            print(string.format("\n  [%s] \27[33m? SKIP\27[0m (no API key)", provider))
            goto continue
        end

        -- Run validation
        local success = self:runProviderValidation(provider, api_key, args.verbose)
        if not success then
            all_passed = false
        end

        ::continue::
    end

    -- Print summary
    self:printSummary()

    return all_passed
end

-- Print summary
function ModelValidation:printSummary()
    print("")
    print(string.rep("-", 70))
    print(string.format("  Model Validation Results:"))
    print(string.format("    \27[32m%d passed\27[0m, \27[33m%d constraints detected\27[0m, \27[31m%d failed\27[0m, \27[90m%d skipped\27[0m",
        self.passed - #self.constraints,  -- Pure passes (no constraint)
        #self.constraints,
        self.failed,
        self.skipped))

    -- Show detected constraints
    if #self.constraints > 0 then
        print("")
        print("  Detected Constraints:")
        for _, c in ipairs(self.constraints) do
            local constraint = c.constraint
            if constraint.type == "temperature" then
                print(string.format("    %s/%s: requires temperature=%s",
                    c.provider, c.model, tostring(constraint.allowed)))
            elseif constraint.type == "max_tokens" then
                print(string.format("    %s/%s: requires max_tokens >= %s",
                    c.provider, c.model, tostring(constraint.min_value)))
            elseif constraint.type == "multiple" then
                print(string.format("    %s/%s: requires temp=%s + max_tokens >= %s",
                    c.provider, c.model,
                    tostring(constraint.temperature),
                    tostring(constraint.max_tokens)))
            else
                print(string.format("    %s/%s: %s",
                    c.provider, c.model, constraint.message or "unknown"))
            end
        end
    end

    -- Show invalid models
    if #self.invalid_models > 0 then
        print("")
        print("  Invalid Models:")
        for _, m in ipairs(self.invalid_models) do
            print(string.format("    %s/%s: not found (check model_lists.lua)",
                m.provider, m.model))
        end
    end

    print("")
end

-- Export
return ModelValidation
