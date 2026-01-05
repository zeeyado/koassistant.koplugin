-- Request Inspector
-- Builds and displays requests using the REAL plugin code
-- This ensures the test suite stays in sync with the actual implementation

local TerminalFormatter = require("terminal_formatter")
local TestConfig = require("test_config")

local RequestInspector = {}

-- Check if a provider is supported for inspection
-- (dynamically checks if handler exists and has buildRequestBody method)
function RequestInspector:isSupported(provider)
    local ok, handler = pcall(require, "api_handlers." .. provider)
    if not ok or not handler then return false end
    return handler.buildRequestBody ~= nil
end

-- Get list of all supported providers (derived from model_lists.lua)
function RequestInspector:getAllProviders()
    local TestConfig = require("test_config")
    return TestConfig.getAllProviders()
end

-- Build a request using the REAL handler code
-- @param provider string: Provider name
-- @param config table: Unified config from buildFullConfig
-- @param messages table: Message history
-- @return table: { body, headers, url, model, provider } or nil, error
function RequestInspector:buildRequest(provider, config, messages)
    if not self:isSupported(provider) then
        return nil, string.format("Provider '%s' does not have buildRequestBody() implemented yet", provider)
    end

    -- Load the real handler
    local ok, handler = pcall(require, "api_handlers." .. provider)
    if not ok then
        return nil, string.format("Failed to load handler for '%s': %s", provider, tostring(handler))
    end

    -- Check if handler has buildRequestBody
    if not handler.buildRequestBody then
        return nil, string.format("Handler '%s' does not have buildRequestBody() method", provider)
    end

    -- Call the real handler's buildRequestBody
    local request_ok, request = pcall(function()
        return handler:buildRequestBody(messages, config)
    end)

    if not request_ok then
        return nil, string.format("Failed to build request for '%s': %s", provider, tostring(request))
    end

    return request
end

-- Extract config summary for display
function RequestInspector:getConfigSummary(config)
    local summary = {}

    -- Get components from unified system if available
    local components = config.system and config.system.components or {}

    -- Behavior
    local behavior = "none"
    if config.system and config.system.text then
        local text_len = #config.system.text
        if text_len > 400 then
            behavior = "full (~" .. math.floor(text_len / 4) .. " tokens)"
        elseif text_len > 100 then
            behavior = "minimal (~" .. math.floor(text_len / 4) .. " tokens)"
        elseif text_len > 0 then
            behavior = "custom (" .. text_len .. " chars)"
        end
    end
    table.insert(summary, { "Behavior", behavior })

    -- Domain (from components)
    local domain = "None"
    if components.domain and components.domain ~= "" then
        domain = components.domain:sub(1, 30) .. (#components.domain > 30 and "..." or "")
    end
    table.insert(summary, { "Domain", domain })

    -- Languages (from components)
    local languages = "Default"
    if components.language and components.language ~= "" then
        -- Extract primary from language instruction or show presence
        languages = "Configured"
        local primary_match = components.language:match("respond in (%w+)")
        if primary_match then
            languages = primary_match .. " (with instruction)"
        end
    end
    table.insert(summary, { "Languages", languages })

    -- API params
    local api_params = config.api_params or {}
    table.insert(summary, { "Temperature", api_params.temperature or "default" })
    table.insert(summary, { "Max Tokens", api_params.max_tokens or "default" })

    -- Thinking
    local thinking = "Disabled"
    if api_params.thinking then
        thinking = "Enabled (budget: " .. (api_params.thinking.budget_tokens or "?") .. ")"
    end
    table.insert(summary, { "Thinking", thinking })

    return summary
end

-- Display a single request in the terminal
function RequestInspector:displayRequest(request, config, options)
    options = options or {}
    local width = options.width or 80
    local json = require("json")

    -- Header
    local title = string.format("REQUEST INSPECTOR: %s (%s)",
        request.provider:sub(1,1):upper() .. request.provider:sub(2),
        request.model or "default model")
    TerminalFormatter.header(title, width)

    -- Config summary
    print("")
    print("  " .. TerminalFormatter.colors.bold .. "CONFIG SUMMARY" .. TerminalFormatter.colors.reset)
    TerminalFormatter.tree(self:getConfigSummary(config))

    -- System prompt section
    TerminalFormatter.section("SYSTEM PROMPT (" .. request.provider .. " format)", width)

    if request.provider == "anthropic" then
        -- Anthropic uses array format with cache_control
        local system = request.body.system
        if system and #system > 0 then
            for i, block in ipairs(system) do
                local cache_info = block.cache_control and " | cache_control: " .. block.cache_control.type or ""
                print(string.format("\n  [%d] type: \"%s\"%s", i, block.type or "text", cache_info))

                if block.text then
                    -- Truncate for display
                    local display_text = block.text
                    if #display_text > 500 and not options.full then
                        display_text = display_text:sub(1, 500) .. "\n... [truncated, " .. #block.text .. " chars total]"
                    end
                    TerminalFormatter.box_content(display_text, width - 4)
                end
            end
        else
            print("  " .. TerminalFormatter.colors.dim .. "(no system prompt)" .. TerminalFormatter.colors.reset)
        end

        -- Token estimate
        local total_chars = 0
        if system then
            for _, block in ipairs(system) do
                if block.text then total_chars = total_chars + #block.text end
            end
        end
        print(string.format("  Token estimate: ~%d tokens", math.floor(total_chars / 4)))

    elseif request.provider == "gemini" then
        -- Gemini uses system_instruction with parts
        local si = request.body.system_instruction
        if si and si.parts and #si.parts > 0 then
            for i, part in ipairs(si.parts) do
                print(string.format("\n  [%d] parts[%d].text:", 1, i))
                local display_text = part.text or ""
                if #display_text > 500 and not options.full then
                    display_text = display_text:sub(1, 500) .. "\n... [truncated, " .. #part.text .. " chars total]"
                end
                TerminalFormatter.box_content(display_text, width - 4)
            end
        else
            print("  " .. TerminalFormatter.colors.dim .. "(no system instruction)" .. TerminalFormatter.colors.reset)
        end

    else
        -- OpenAI-compatible: system in first message
        local messages = request.body.messages or {}
        local system_msg = nil
        for _, msg in ipairs(messages) do
            if msg.role == "system" then
                system_msg = msg
                break
            end
        end

        if system_msg then
            print("\n  [role: \"system\"]")
            local display_text = system_msg.content or ""
            if #display_text > 500 and not options.full then
                display_text = display_text:sub(1, 500) .. "\n... [truncated, " .. #system_msg.content .. " chars total]"
            end
            TerminalFormatter.box_content(display_text, width - 4)
        else
            print("  " .. TerminalFormatter.colors.dim .. "(no system message)" .. TerminalFormatter.colors.reset)
        end
    end

    -- Messages section
    TerminalFormatter.section("MESSAGES", width)

    local messages = request.body.messages or request.body.contents or {}
    local non_system_count = 0

    for _, msg in ipairs(messages) do
        local role = msg.role
        if role ~= "system" then
            non_system_count = non_system_count + 1
            local content = msg.content

            -- Handle Gemini's parts format
            if msg.parts and msg.parts[1] then
                content = msg.parts[1].text
            end

            print(string.format("\n  [%d] role: %s", non_system_count, role))
            if content then
                local display_text = content
                if #display_text > 200 and not options.full then
                    display_text = display_text:sub(1, 200) .. "..."
                end
                TerminalFormatter.box_content(display_text, width - 4)
            end
        end
    end

    if non_system_count == 0 then
        print("  " .. TerminalFormatter.colors.dim .. "(no messages)" .. TerminalFormatter.colors.reset)
    end

    -- Raw request body
    TerminalFormatter.section("RAW REQUEST BODY (JSON)", width)
    print("")
    TerminalFormatter.json(request.body, 1)

    -- Headers
    TerminalFormatter.section("HTTP HEADERS", width)
    print("")
    for key, value in pairs(request.headers) do
        -- Redact sensitive values
        local display_value = value
        if key:lower():match("key") or key:lower():match("auth") then
            if #value > 10 then
                display_value = value:sub(1, 4) .. "..." .. value:sub(-4)
            end
        end
        TerminalFormatter.labeled(key, display_value, 20)
    end

    -- URL
    print("")
    TerminalFormatter.labeled("URL", request.url, 20)

    -- Footer
    print("")
    TerminalFormatter.divider(width, "=")
    print("")
end

-- Export request as JSON
function RequestInspector:exportJSON(request, config)
    local json = require("json")

    local export = {
        timestamp = os.date("!%Y-%m-%dT%H:%M:%SZ"),
        provider = request.provider,
        model = request.model,
        config = {
            behavior_variant = config.behavior_variant,
            temperature = config.api_params and config.api_params.temperature,
            max_tokens = config.api_params and config.api_params.max_tokens,
            domain_context = config.domain_context,
            user_languages = config.user_languages,
            primary_language = config.primary_language,
            extended_thinking = config.api_params and config.api_params.thinking and true or false,
        },
        request = {
            url = request.url,
            headers = {},
            body = request.body,
        },
    }

    -- Redact sensitive headers
    for key, value in pairs(request.headers) do
        if key:lower():match("key") or key:lower():match("auth") then
            export.request.headers[key] = "[REDACTED]"
        else
            export.request.headers[key] = value
        end
    end

    return json.encode(export)
end

return RequestInspector
