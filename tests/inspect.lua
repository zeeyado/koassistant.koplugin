#!/usr/bin/env lua
-- Request Inspector & Explorer
-- Visualize exactly what requests are sent to each AI provider
--
-- Usage:
--   lua tests/inspect.lua --inspect anthropic              # Single provider
--   lua tests/inspect.lua --inspect openai --behavior full # With options
--   lua tests/inspect.lua --compare anthropic openai gemini # Compare providers
--   lua tests/inspect.lua --export anthropic               # Export JSON
--   lua tests/inspect.lua --list                           # List supported providers
--   lua tests/inspect.lua --preset thinking                # Use preset config
--   lua tests/inspect.lua --web                            # Start web UI server
--   lua tests/inspect.lua --web --port 3000                # Custom port
--
-- This tool uses the REAL plugin code to build requests, ensuring
-- tests always reflect actual plugin behavior.

-- Setup package path for plugin modules
local function setupPaths()
    local info = debug.getinfo(1, "S")
    local script_path = info.source:match("@?(.*)")
    local script_dir = script_path:match("(.*/)") or "./"
    local plugin_dir = script_dir:gsub("tests/$", ""):gsub("/$", "")

    -- Handle case where we're in plugin root
    if plugin_dir == "" then plugin_dir = "." end

    -- Add paths (order matters: lib first, then tests, then plugin root)
    package.path = script_dir .. "lib/?.lua;" ..
                   script_dir .. "?.lua;" ..
                   plugin_dir .. "/?.lua;" ..
                   package.path

    return plugin_dir
end

local plugin_dir = setupPaths()

-- Load mocks FIRST (before any plugin modules)
require("mock_koreader")

-- Load modules
local TestConfig = require("test_config")
local RequestInspector = require("request_inspector")
local TerminalFormatter = require("terminal_formatter")
local MessageBuilder = require("message_builder")

local c = TerminalFormatter.colors

-- Presets for common configurations
local presets = {
    minimal = {
        description = "Minimal behavior, default temperature",
        behavior_variant = "minimal",
        temperature = 0.7,
    },
    full = {
        description = "Full behavior with comprehensive AI guidelines",
        behavior_variant = "full",
        temperature = 0.7,
    },
    domain = {
        description = "Full behavior with sample domain context",
        behavior_variant = "full",
        domain_context = [[This conversation relates to Islamic religious sciences.
Key concepts include: Quran (holy book), Hadith (prophetic traditions),
Tafsir (Quranic exegesis), Fiqh (jurisprudence), and Aqidah (theology).
When discussing these topics, use proper Arabic transliteration.]],
        temperature = 0.7,
    },
    thinking = {
        description = "Extended thinking enabled (Anthropic only)",
        behavior_variant = "full",
        extended_thinking = true,
        thinking_budget = 8192,
        temperature = 1.0,  -- Required for thinking
    },
    multilingual = {
        description = "Multilingual user with language instructions",
        behavior_variant = "full",
        user_languages = "English, Spanish, Arabic",
        primary_language = "English",
        temperature = 0.7,
    },
    custom = {
        description = "Custom behavior override",
        behavior_override = "You are a concise technical assistant. Never use emojis. Always cite sources.",
        temperature = 0.5,
    },
}

-- Parse command line arguments
local function parseArgs(args)
    local parsed = {
        mode = nil,
        providers = {},
        options = {},
    }

    local i = 1
    while i <= #args do
        local arg = args[i]

        if arg == "--inspect" or arg == "-i" then
            parsed.mode = "inspect"
            -- Next arg should be provider name
            if args[i + 1] and not args[i + 1]:match("^%-") then
                i = i + 1
                table.insert(parsed.providers, args[i])
            end

        elseif arg == "--compare" or arg == "-c" then
            parsed.mode = "compare"
            -- Collect all following providers until next flag
            i = i + 1
            while args[i] and not args[i]:match("^%-") do
                table.insert(parsed.providers, args[i])
                i = i + 1
            end
            i = i - 1  -- Back up one since loop will increment

        elseif arg == "--export" or arg == "-e" then
            parsed.mode = "export"
            if args[i + 1] and not args[i + 1]:match("^%-") then
                i = i + 1
                table.insert(parsed.providers, args[i])
            end

        elseif arg == "--list" or arg == "-l" then
            parsed.mode = "list"

        elseif arg == "--help" or arg == "-h" then
            parsed.mode = "help"

        elseif arg == "--preset" or arg == "-p" then
            if args[i + 1] then
                i = i + 1
                parsed.options.preset = args[i]
            end

        elseif arg == "--behavior" or arg == "-b" then
            if args[i + 1] then
                i = i + 1
                parsed.options.behavior_variant = args[i]
            end

        elseif arg == "--temp" or arg == "-t" then
            if args[i + 1] then
                i = i + 1
                parsed.options.temperature = tonumber(args[i])
            end

        elseif arg == "--domain" or arg == "-d" then
            if args[i + 1] then
                i = i + 1
                parsed.options.domain_context = args[i]
            end

        elseif arg == "--languages" then
            if args[i + 1] then
                i = i + 1
                parsed.options.user_languages = args[i]
            end

        elseif arg == "--primary" then
            if args[i + 1] then
                i = i + 1
                parsed.options.primary_language = args[i]
            end

        elseif arg == "--thinking" then
            parsed.options.extended_thinking = true
            if args[i + 1] and tonumber(args[i + 1]) then
                i = i + 1
                parsed.options.thinking_budget = tonumber(args[i])
            else
                parsed.options.thinking_budget = 4096
            end

        elseif arg == "--model" or arg == "-m" then
            if args[i + 1] then
                i = i + 1
                parsed.options.model = args[i]
            end

        elseif arg == "--message" then
            if args[i + 1] then
                i = i + 1
                parsed.options.test_message = args[i]
            end

        elseif arg == "--full" then
            parsed.options.full_output = true

        elseif arg == "--live" then
            parsed.options.live = true

        elseif arg == "--web" or arg == "-w" then
            parsed.mode = "web"

        elseif arg == "--port" then
            if args[i + 1] then
                i = i + 1
                parsed.options.port = tonumber(args[i]) or 8080
            end

        elseif not arg:match("^%-") then
            -- Bare argument - assume it's a provider for inspect mode
            if not parsed.mode then
                parsed.mode = "inspect"
            end
            table.insert(parsed.providers, arg)
        end

        i = i + 1
    end

    return parsed
end

-- Show help
local function showHelp()
    print([[
Request Inspector & Explorer
============================

Visualize exactly what requests are sent to each AI provider.
Uses the REAL plugin code to ensure tests reflect actual behavior.

USAGE:
    lua tests/inspect.lua [MODE] [OPTIONS]

MODES:
    --inspect, -i <provider>     Inspect request for a single provider
    --compare, -c <p1> <p2> ...  Compare requests across providers
    --export, -e <provider>      Export request as JSON
    --list, -l                   List supported providers
    --web, -w                    Start web UI server (http://localhost:8080)
    --help, -h                   Show this help

OPTIONS:
    --preset, -p <name>          Use preset config (minimal, full, domain, thinking, multilingual, custom)
    --behavior, -b <variant>     Behavior variant (minimal, full, none)
    --temp, -t <value>           Temperature (0.0-2.0)
    --domain, -d <text>          Domain context
    --languages <list>           User languages (comma-separated)
    --primary <lang>             Primary language
    --thinking [budget]          Enable extended thinking (default: 4096)
    --model, -m <model>          Override model
    --message <text>             Custom test message
    --full                       Show full output (no truncation)
    --live                       Actually send request (requires API key)
    --port <number>              Port for web server (default: 8080)

EXAMPLES:
    # Basic inspection
    lua tests/inspect.lua anthropic
    lua tests/inspect.lua --inspect openai

    # With preset
    lua tests/inspect.lua anthropic --preset thinking
    lua tests/inspect.lua gemini --preset domain

    # With options
    lua tests/inspect.lua anthropic --behavior minimal --temp 0.5
    lua tests/inspect.lua openai --languages "English, Spanish" --primary Spanish

    # Compare providers
    lua tests/inspect.lua --compare anthropic openai gemini

    # Export JSON
    lua tests/inspect.lua --export anthropic > request.json

PRESETS:
    minimal      - Minimal behavior, default temperature
    full         - Full behavior with comprehensive guidelines
    domain       - Full behavior + sample Islamic studies domain
    thinking     - Extended thinking enabled (Anthropic only)
    multilingual - English/Spanish/Arabic with language instructions
    custom       - Custom behavior override example
]])
end

-- List supported providers
local function listProviders()
    print("")
    print(c.bold .. "Supported Providers for Inspection" .. c.reset)
    print("")

    local all_providers = TestConfig.getAllProviders()

    for _, provider in ipairs(all_providers) do
        local supported = RequestInspector:isSupported(provider)
        local status = supported and (c.green .. "✓ supported" .. c.reset) or (c.dim .. "○ pending" .. c.reset)
        print(string.format("  %-12s %s", provider, status))
    end

    print("")
    print(c.dim .. "Providers marked 'pending' need buildRequestBody() method added." .. c.reset)
    print("")
end

-- List presets
local function listPresets()
    print("")
    print(c.bold .. "Available Presets" .. c.reset)
    print("")

    for name, preset in pairs(presets) do
        print(string.format("  %s%-12s%s - %s", c.cyan, name, c.reset, preset.description))
    end
    print("")
end

-- Build config with options and presets
local function buildConfigWithOptions(provider, api_key, options)
    -- Start with preset if specified
    local config_opts = {}

    if options.preset and presets[options.preset] then
        for k, v in pairs(presets[options.preset]) do
            if k ~= "description" then
                config_opts[k] = v
            end
        end
    end

    -- Override with explicit options
    for k, v in pairs(options) do
        if k ~= "preset" and k ~= "full_output" and k ~= "live" and k ~= "test_message" then
            config_opts[k] = v
        end
    end

    -- Build using the real pipeline
    return TestConfig.buildFullConfig(provider, api_key, config_opts)
end

-- Inspect a single provider
local function inspectProvider(provider, options)
    -- Check if supported
    if not RequestInspector:isSupported(provider) then
        print("")
        print(c.red .. "Error: " .. c.reset .. "Provider '" .. provider .. "' is not yet supported for inspection.")
        print("")
        print("Supported providers: " .. table.concat(RequestInspector:getAllProviders(), ", "))
        print("")
        print(c.dim .. "To add support, implement buildRequestBody() in api_handlers/" .. provider .. ".lua" .. c.reset)
        print("")
        return false
    end

    -- Load API keys (for headers, even if not making live requests)
    local api_keys = TestConfig.loadApiKeys()
    local api_key = api_keys[provider] or ""

    -- Build config using real pipeline
    local config = buildConfigWithOptions(provider, api_key, options)

    -- Build test messages
    local messages = {
        { role = "user", content = options.test_message or "Say hello in exactly 5 words." }
    }

    -- Build request using real handler
    local request, err = RequestInspector:buildRequest(provider, config, messages)

    if not request then
        print("")
        print(c.red .. "Error building request: " .. c.reset .. (err or "unknown error"))
        print("")
        return false
    end

    -- Display the request
    RequestInspector:displayRequest(request, config, {
        full = options.full_output,
        width = 90,
    })

    return true
end

-- Export request as JSON
local function exportProvider(provider, options)
    -- Check if supported
    if not RequestInspector:isSupported(provider) then
        io.stderr:write("Error: Provider '" .. provider .. "' is not yet supported for inspection.\n")
        return false
    end

    -- Load API keys
    local api_keys = TestConfig.loadApiKeys()
    local api_key = api_keys[provider] or ""

    -- Build config using real pipeline
    local config = buildConfigWithOptions(provider, api_key, options)

    -- Build test messages
    local messages = {
        { role = "user", content = options.test_message or "Say hello in exactly 5 words." }
    }

    -- Build request
    local request, err = RequestInspector:buildRequest(provider, config, messages)

    if not request then
        io.stderr:write("Error building request: " .. (err or "unknown error") .. "\n")
        return false
    end

    -- Export as JSON (to stdout for redirection)
    print(RequestInspector:exportJSON(request, config))

    return true
end

-- Compare multiple providers
local function compareProviders(providers, options)
    if #providers < 2 then
        print(c.red .. "Error: " .. c.reset .. "Need at least 2 providers to compare.")
        print("Usage: lua tests/inspect.lua --compare anthropic openai gemini")
        return false
    end

    -- Load API keys
    local api_keys = TestConfig.loadApiKeys()

    -- Build test messages
    local messages = {
        { role = "user", content = options.test_message or "Say hello in exactly 5 words." }
    }

    -- Build requests for each provider
    local requests = {}
    local configs = {}

    for _, provider in ipairs(providers) do
        if not RequestInspector:isSupported(provider) then
            print(c.yellow .. "Skipping " .. provider .. c.reset .. " (not yet supported)")
        else
            local api_key = api_keys[provider] or ""
            local config = buildConfigWithOptions(provider, api_key, options)
            local request, err = RequestInspector:buildRequest(provider, config, messages)

            if request then
                requests[provider] = request
                configs[provider] = config
            else
                print(c.yellow .. "Skipping " .. provider .. ": " .. c.reset .. (err or "unknown error"))
            end
        end
    end

    -- Display comparison header
    local width = 100
    TerminalFormatter.header("REQUEST COMPARATOR: " .. table.concat(providers, " vs "), width)

    -- Show config used
    print("")
    print("  " .. c.bold .. "CONFIG" .. c.reset)
    if options.preset then
        TerminalFormatter.labeled("Preset", options.preset, 16)
    end
    TerminalFormatter.labeled("Behavior", options.behavior_variant or "full", 16)
    TerminalFormatter.labeled("Temperature", options.temperature or 0.7, 16)
    if options.domain_context then
        TerminalFormatter.labeled("Domain", options.domain_context:sub(1, 40) .. "...", 16)
    end
    if options.user_languages then
        TerminalFormatter.labeled("Languages", options.user_languages, 16)
    end

    -- Comparison sections
    local sections = {
        { name = "System Prompt Format", key = "system_format" },
        { name = "Message Role Mapping", key = "role_mapping" },
        { name = "Content Format", key = "content_format" },
        { name = "Auth Method", key = "auth" },
    }

    for _, section in ipairs(sections) do
        TerminalFormatter.section(section.name, width)
        print("")

        for provider, request in pairs(requests) do
            local value = ""

            if section.key == "system_format" then
                if request.body.system then
                    if type(request.body.system) == "table" then
                        value = "Array with " .. #request.body.system .. " block(s)"
                        if request.body.system[1] and request.body.system[1].cache_control then
                            value = value .. " + cache_control"
                        end
                    else
                        value = "String"
                    end
                elseif request.body.system_instruction then
                    value = "system_instruction.parts[]"
                elseif request.body.messages then
                    local has_system = false
                    for _, msg in ipairs(request.body.messages) do
                        if msg.role == "system" then
                            has_system = true
                            break
                        end
                    end
                    value = has_system and "First message (role=system)" or "None"
                else
                    value = "None"
                end

            elseif section.key == "role_mapping" then
                -- Check how assistant role is mapped
                local assistant_role = "assistant"
                if request.body.contents then
                    assistant_role = "model (Gemini)"
                end
                value = "user -> user, assistant -> " .. assistant_role

            elseif section.key == "content_format" then
                if request.body.contents then
                    value = "contents[].parts[].text"
                elseif request.body.messages and request.body.messages[1] then
                    if type(request.body.messages[1].content) == "table" then
                        value = "messages[].content[] (array)"
                    else
                        value = "messages[].content (string)"
                    end
                else
                    value = "messages[].content (string)"
                end

            elseif section.key == "auth" then
                for header, _ in pairs(request.headers) do
                    local h = header:lower()
                    if h == "x-api-key" then
                        value = "x-api-key header"
                    elseif h == "authorization" then
                        value = "Bearer token"
                    elseif h == "x-goog-api-key" then
                        value = "x-goog-api-key header"
                    end
                end
            end

            print(string.format("  %s%-12s%s %s", c.cyan, provider .. ":", c.reset, value))
        end
    end

    -- Show URL endpoints
    TerminalFormatter.section("API Endpoints", width)
    print("")
    for provider, request in pairs(requests) do
        TerminalFormatter.labeled(provider, request.url, 14)
    end

    -- Show individual system prompts
    TerminalFormatter.section("System Prompts (truncated)", width)

    for provider, request in pairs(requests) do
        print("")
        print("  " .. c.bold .. provider:upper() .. c.reset)

        local system_text = ""
        if request.body.system then
            if type(request.body.system) == "table" and request.body.system[1] then
                system_text = request.body.system[1].text or ""
            elseif type(request.body.system) == "string" then
                system_text = request.body.system
            end
        elseif request.body.system_instruction and request.body.system_instruction.parts then
            system_text = request.body.system_instruction.parts[1].text or ""
        elseif request.body.messages then
            for _, msg in ipairs(request.body.messages) do
                if msg.role == "system" then
                    system_text = msg.content or ""
                    break
                end
            end
        end

        if system_text ~= "" then
            local display = system_text:sub(1, 200)
            if #system_text > 200 then
                display = display .. "... [" .. #system_text .. " chars total]"
            end
            print("  " .. c.dim .. display .. c.reset)
        else
            print("  " .. c.dim .. "(none)" .. c.reset)
        end
    end

    print("")
    TerminalFormatter.divider(width, "=")
    print("")

    return true
end

-- Start web server with API handlers
local function startWebServer(options)
    local WebServer = require("web_server")
    local json = require("dkjson")

    -- Load API keys once
    local api_keys = TestConfig.loadApiKeys()

    -- Get script directory for loading index.html
    local info = debug.getinfo(1, "S")
    local script_path = info.source:match("@?(.*)")
    local script_dir = script_path:match("(.*/)") or "./"

    -- Load index.html content
    local index_path = script_dir .. "web/index.html"
    local index_file = io.open(index_path, "r")
    local index_html = ""
    if index_file then
        index_html = index_file:read("*all")
        index_file:close()
    else
        index_html = "<html><body><h1>Error: Could not load index.html</h1><p>Expected at: " .. index_path .. "</p></body></html>"
    end

    local server = WebServer:new()

    -- GET / - Serve index.html
    server:route("GET", "/", function(headers, body)
        return "200 OK", "text/html; charset=utf-8", index_html
    end)

    -- GET /api/providers - List all providers with models
    server:route("GET", "/api/providers", function(headers, body)
        local Defaults = require("api_handlers.defaults")
        local ModelLists = require("model_lists")

        local providers_data = {}
        for _, provider in ipairs(TestConfig.getAllProviders()) do
            local defaults = Defaults.ProviderDefaults[provider]
            local models = ModelLists[provider] or {}
            table.insert(providers_data, {
                id = provider,
                default_model = defaults and defaults.model or nil,
                base_url = defaults and defaults.base_url or nil,
                models = models,
                supported = RequestInspector:isSupported(provider),
            })
        end

        return "200 OK", "application/json", json.encode({
            success = true,
            providers = providers_data,
        })
    end)

    -- GET /api/presets - List available presets
    server:route("GET", "/api/presets", function(headers, body)
        local presets_data = {}
        for name, preset in pairs(presets) do
            presets_data[name] = {
                description = preset.description,
                behavior_variant = preset.behavior_variant,
                behavior_override = preset.behavior_override,
                temperature = preset.temperature,
                domain_context = preset.domain_context and preset.domain_context:sub(1, 100) .. "..." or nil,
                user_languages = preset.user_languages,
                extended_thinking = preset.extended_thinking,
            }
        end

        return "200 OK", "application/json", json.encode({
            success = true,
            presets = presets_data,
        })
    end)

    -- GET /api/domains - List available domains from domains/ folder
    server:route("GET", "/api/domains", function(headers, body)
        local domains_data = {}
        local domains_path = plugin_dir .. "/domains"

        -- List files in domains/ folder using ls command
        local handle = io.popen('ls -1 "' .. domains_path .. '" 2>/dev/null')
        if handle then
            for filename in handle:lines() do
                if filename:match("%.md$") or filename:match("%.txt$") then
                    local domain_id = filename:gsub("%.md$", ""):gsub("%.txt$", "")
                    local filepath = domains_path .. "/" .. filename

                    -- Read file content
                    local file = io.open(filepath, "r")
                    if file then
                        local content = file:read("*a")
                        file:close()

                        -- Parse: first # heading is name, rest is context
                        local name = domain_id:gsub("_", " "):gsub("(%a)([%w]*)", function(first, rest)
                            return first:upper() .. rest
                        end)
                        local context = content

                        local heading = content:match("^#%s*([^\n]+)")
                        if heading then
                            name = heading
                            context = content:gsub("^#[^\n]*\n*", "")
                        end

                        table.insert(domains_data, {
                            id = domain_id,
                            name = name,
                            context = context,
                            preview = context:sub(1, 100) .. (context:len() > 100 and "..." or ""),
                        })
                    end
                end
            end
            handle:close()
        end

        return "200 OK", "application/json", json.encode({
            success = true,
            domains = domains_data,
        })
    end)

    -- GET /api/settings - Load plugin settings (for Web UI defaults)
    server:route("GET", "/api/settings", function(headers, body)
        -- Try to load settings from the plugin's settings file
        local settings_data = {
            -- Language settings
            user_languages = "",
            primary_language = nil,
            translation_use_primary = true,
            translation_language = "English",
            -- Behavior settings
            ai_behavior_variant = "full",
            custom_ai_behavior = "",
            -- API settings
            default_temperature = 0.7,
            enable_extended_thinking = false,
            thinking_budget_tokens = 4096,
        }

        -- Try to load from koassistant_settings.lua (in KOReader's settings folder)
        -- Plugin is at plugins/koassistant.koplugin/, so go up two levels to koreader root
        local settings_path = plugin_dir .. "/../../settings/koassistant_settings.lua"
        local file = io.open(settings_path, "r")
        if file then
            file:close()
            local ok, loaded = pcall(dofile, settings_path)
            if ok and loaded and loaded.features then
                local f = loaded.features
                settings_data.user_languages = f.user_languages or ""
                settings_data.primary_language = f.primary_language
                settings_data.translation_use_primary = f.translation_use_primary ~= false
                settings_data.translation_language = f.translation_language or "English"
                settings_data.ai_behavior_variant = f.ai_behavior_variant or "full"
                settings_data.custom_ai_behavior = f.custom_ai_behavior or ""
                settings_data.default_temperature = f.default_temperature or 0.7
                settings_data.enable_extended_thinking = f.enable_extended_thinking or false
                settings_data.thinking_budget_tokens = f.thinking_budget_tokens or 4096
            end
        end

        return "200 OK", "application/json", json.encode({
            success = true,
            settings = settings_data,
        })
    end)

    -- GET /api/actions - List all built-in and custom actions
    server:route("GET", "/api/actions", function(headers, body)
        local Actions = require("prompts.actions")
        local Templates = require("prompts.templates")

        local actions_data = {
            highlight = {},
            book = {},
            multi_book = {},
            general = {},
        }

        -- Helper to get template text
        local function getTemplateText(template_id)
            if Templates and Templates[template_id] then
                return Templates[template_id]
            end
            return nil
        end

        -- Helper to add action to a specific context
        local function addActionToContext(out_context, action, is_custom)
            if actions_data[out_context] then
                table.insert(actions_data[out_context], {
                    id = action.id,
                    text = action.text,
                    template = action.template,
                    template_text = action.template and getTemplateText(action.template) or nil,
                    prompt = action.prompt,
                    behavior_variant = action.behavior_variant,
                    behavior_override = action.behavior_override,
                    api_params = action.api_params,
                    include_book_context = action.include_book_context,
                    extended_thinking = action.extended_thinking,
                    context = action.context,  -- Include original context for filtering
                    is_custom = is_custom or false,
                })
            end
        end

        -- Process each context (only the table properties, not methods)
        local contexts = {"highlight", "book", "multi_book", "general", "special"}
        for _, context in ipairs(contexts) do
            local context_actions = Actions[context]
            if context_actions and type(context_actions) == "table" then
                for id, action in pairs(context_actions) do
                    if type(action) == "table" and action.id then
                        if context == "special" then
                            -- Special actions: expand compound contexts properly
                            if action.context == "both" then
                                -- "both" means highlight AND book
                                addActionToContext("highlight", action)
                                addActionToContext("book", action)
                            elseif action.context == "all" then
                                -- "all" means ALL four contexts
                                addActionToContext("highlight", action)
                                addActionToContext("book", action)
                                addActionToContext("multi_book", action)
                                addActionToContext("general", action)
                            elseif action.context then
                                addActionToContext(action.context, action)
                            end
                        else
                            -- Regular context actions
                            addActionToContext(context, action)
                        end
                    end
                end
            end
        end

        -- Load custom actions from settings file
        -- Plugin is at plugins/koassistant.koplugin/, so go up two levels to koreader root
        local settings_path = plugin_dir .. "/../../settings/koassistant_settings.lua"
        local settings_file = io.open(settings_path, "r")
        if settings_file then
            settings_file:close()
            local ok, settings = pcall(dofile, settings_path)
            if ok and settings and settings.custom_actions then
                for i, action in ipairs(settings.custom_actions) do
                    if action.enabled ~= false then
                        -- Generate ID for custom action
                        local custom_action = {
                            id = "custom_" .. i,
                            text = action.text or ("Custom " .. i),
                            prompt = action.prompt,
                            behavior_variant = action.behavior_variant,
                            behavior_override = action.behavior_override,
                            api_params = action.api_params,
                            include_book_context = action.include_book_context,
                            extended_thinking = action.extended_thinking,
                            thinking_budget = action.thinking_budget,
                            provider = action.provider,
                            model = action.model,
                            context = action.context,
                        }

                        -- Add to appropriate contexts
                        if action.context == "both" then
                            addActionToContext("highlight", custom_action, true)
                            addActionToContext("book", custom_action, true)
                        elseif action.context == "all" then
                            addActionToContext("highlight", custom_action, true)
                            addActionToContext("book", custom_action, true)
                            addActionToContext("multi_book", custom_action, true)
                            addActionToContext("general", custom_action, true)
                        elseif action.context then
                            addActionToContext(action.context, custom_action, true)
                        end
                    end
                end
            end
        end

        -- Add "Ask" pseudo-action for general context (hardcoded in dialogs.lua, not in actions.lua)
        table.insert(actions_data.general, {
            id = "ask",
            text = "Ask",
            prompt = "",  -- Empty prompt, user provides the question
            behavior_variant = nil,  -- Uses global behavior
            context = "general",
            is_pseudo_action = true,  -- Flag to indicate this is a pseudo-action (free-form input)
        })

        return "200 OK", "application/json", json.encode({
            success = true,
            actions = actions_data,
        })
    end)

    -- POST /api/build - Build request without sending
    server:route("POST", "/api/build", function(headers, body)
        local request_data = json.decode(body)
        if not request_data then
            return "400 Bad Request", "application/json", json.encode({ success = false, error = "Invalid JSON" })
        end

        local provider = request_data.provider
        if not provider then
            return "400 Bad Request", "application/json", json.encode({ success = false, error = "Missing provider" })
        end

        if not RequestInspector:isSupported(provider) then
            return "400 Bad Request", "application/json", json.encode({
                success = false,
                error = "Provider '" .. provider .. "' is not supported for inspection"
            })
        end

        -- Build options from request
        local build_options = {
            behavior_variant = request_data.behavior or "full",
            behavior_override = request_data.custom_behavior,
            temperature = request_data.temperature or 0.7,
            domain_context = request_data.domain,
            user_languages = request_data.languages,
            primary_language = request_data.primary_language,
            model = request_data.model,
        }

        -- Handle thinking
        if request_data.thinking and request_data.thinking.enabled then
            build_options.extended_thinking = true
            build_options.thinking_budget = request_data.thinking.budget or 4096
        end

        -- Build config
        local api_key = api_keys[provider] or ""
        local config = buildConfigWithOptions(provider, api_key, build_options)

        -- Build messages using shared MessageBuilder (same as plugin)
        local context = request_data.context or {}
        local context_type = context.type or "general"

        -- Build the action/prompt object
        -- If an action was selected, it should have a prompt field
        -- Otherwise, use the user's message as a simple prompt
        local action = request_data.action or { prompt = request_data.message or "Say hello in exactly 5 words." }

        -- Build context data for MessageBuilder
        local context_data = {}

        if context_type == "highlight" then
            context_data.highlighted_text = context.highlighted_text
            context_data.book_title = context.book_title
            context_data.book_author = context.book_author
        elseif context_type == "book" then
            if context.book_title then
                context_data.book_metadata = {
                    title = context.book_title,
                    author = context.book_author,
                    author_clause = (context.book_author and context.book_author ~= "") and (" by " .. context.book_author) or ""
                }
            end
        elseif context_type == "multi_book" then
            context_data.books_info = context.books_info or {}
        end

        -- Add additional user input (if action was selected, the user's message is additional input)
        if request_data.action and request_data.message and request_data.message ~= "" then
            context_data.additional_input = request_data.message
        end

        -- Add translation language if applicable
        if request_data.translation_language then
            context_data.translation_language = request_data.translation_language
        end

        -- Load templates getter for template resolution
        local templates_getter = nil
        pcall(function()
            local Templates = require("prompts/templates")
            templates_getter = function(name) return Templates.get(name) end
        end)

        -- Build the message using shared MessageBuilder
        local user_content = MessageBuilder.build({
            prompt = action,
            context = context_type,
            data = context_data,
            using_new_format = true,  -- System/domain handled separately
            templates_getter = templates_getter,
        })

        local messages = {
            { role = "user", content = user_content }
        }

        -- Build request
        local request, err = RequestInspector:buildRequest(provider, config, messages)
        if not request then
            return "500 Internal Server Error", "application/json", json.encode({
                success = false,
                error = err or "Failed to build request"
            })
        end

        -- Extract system prompt info
        local system_text = ""
        local system_format = "unknown"
        if request.body.system then
            if type(request.body.system) == "table" and request.body.system[1] then
                system_text = request.body.system[1].text or ""
                system_format = "array"
            elseif type(request.body.system) == "string" then
                system_text = request.body.system
                system_format = "string"
            end
        elseif request.body.system_instruction and request.body.system_instruction.parts then
            system_text = request.body.system_instruction.parts[1].text or ""
            system_format = "system_instruction"
        elseif request.body.messages then
            for _, msg in ipairs(request.body.messages) do
                if msg.role == "system" then
                    system_text = msg.content or ""
                    system_format = "first_message"
                    break
                end
            end
        end

        -- Redact API key from headers
        local safe_headers = {}
        for k, v in pairs(request.headers) do
            local key_lower = k:lower()
            if key_lower == "authorization" or key_lower == "x-api-key" or key_lower == "x-goog-api-key" then
                safe_headers[k] = "[REDACTED]"
            else
                safe_headers[k] = v
            end
        end

        return "200 OK", "application/json", json.encode({
            success = true,
            request = {
                url = request.url,
                headers = safe_headers,
                body = request.body,
            },
            system_prompt = {
                text = system_text,
                format = system_format,
                token_estimate = math.ceil(#system_text / 4),  -- Rough estimate
            },
            provider = provider,
            model = request.model or config.model,
        })
    end)

    -- POST /api/compare - Compare multiple providers
    server:route("POST", "/api/compare", function(headers, body)
        local request_data = json.decode(body)
        if not request_data or not request_data.providers then
            return "400 Bad Request", "application/json", json.encode({ success = false, error = "Invalid request" })
        end

        local results = {}
        for _, provider in ipairs(request_data.providers) do
            if RequestInspector:isSupported(provider) then
                -- Build options
                local build_options = {
                    behavior_variant = request_data.behavior or "full",
                    temperature = request_data.temperature or 0.7,
                    domain_context = request_data.domain,
                }

                local api_key = api_keys[provider] or ""
                local config = buildConfigWithOptions(provider, api_key, build_options)
                local messages = {
                    { role = "user", content = request_data.message or "Say hello in exactly 5 words." }
                }

                local request, err = RequestInspector:buildRequest(provider, config, messages)
                if request then
                    results[provider] = {
                        success = true,
                        url = request.url,
                        body = request.body,
                    }
                else
                    results[provider] = { success = false, error = err }
                end
            else
                results[provider] = { success = false, error = "Not supported" }
            end
        end

        return "200 OK", "application/json", json.encode({
            success = true,
            results = results,
        })
    end)

    -- Start server
    local port = options.port or 8080
    server:start(port)
end

-- Main
local function main()
    local args = parseArgs(arg)

    -- Default mode
    if not args.mode then
        if #args.providers > 0 then
            args.mode = "inspect"
        else
            args.mode = "help"
        end
    end

    -- Execute mode
    if args.mode == "help" then
        showHelp()
        return 0

    elseif args.mode == "list" then
        listProviders()
        listPresets()
        return 0

    elseif args.mode == "inspect" then
        if #args.providers == 0 then
            print(c.red .. "Error: " .. c.reset .. "Please specify a provider to inspect.")
            print("Usage: lua tests/inspect.lua --inspect <provider>")
            print("       lua tests/inspect.lua --list")
            return 1
        end

        local success = inspectProvider(args.providers[1], args.options)
        return success and 0 or 1

    elseif args.mode == "export" then
        if #args.providers == 0 then
            io.stderr:write("Error: Please specify a provider to export.\n")
            return 1
        end

        local success = exportProvider(args.providers[1], args.options)
        return success and 0 or 1

    elseif args.mode == "compare" then
        local success = compareProviders(args.providers, args.options)
        return success and 0 or 1

    elseif args.mode == "web" then
        startWebServer(args.options)
        return 0
    end

    return 0
end

os.exit(main())
