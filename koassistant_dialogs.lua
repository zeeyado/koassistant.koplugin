local Device = require("device")
local InputDialog = require("ui/widget/inputdialog")
local ButtonDialog = require("ui/widget/buttondialog")
local ChatGPTViewer = require("koassistant_chatgptviewer")
local UIManager = require("ui/uimanager")
local InfoMessage = require("ui/widget/infomessage")
local Screen = Device.screen
local _ = require("koassistant_gettext")
local T = require("ffi/util").template

local GptQuery = require("koassistant_gpt_query")
local queryChatGPT = GptQuery.query
local isStreamingInProgress = GptQuery.isStreamingInProgress
local ConfigHelper = require("koassistant_config_helper")
local MessageHistory = require("koassistant_message_history")
local ChatHistoryManager = require("koassistant_chat_history_manager")
local MessageBuilder = require("message_builder")
local ModelConstraints = require("model_constraints")
local Defaults = require("koassistant_api.defaults")
local Constants = require("koassistant_constants")
local logger = require("logger")

-- ActionService module (for static methods like getActionDisplayText)
local ActionServiceModule = require("action_service")

-- New request format modules (Phase 3)
local ActionService = nil
local function getActionService(settings)
    if not ActionService then
        local ok, AS = pcall(require, "action_service")
        if ok then
            ActionService = AS:new(settings)
            ActionService:initialize()
        end
    end
    return ActionService
end

local CONFIGURATION = nil
local input_dialog

-- Try to load configuration from the same directory as this script
local function script_path()
   local str = debug.getinfo(2, "S").source:sub(2)
   return str:match("(.*/)")
end

local plugin_dir = script_path()
local config_path = plugin_dir .. "configuration.lua"

local success, result = pcall(dofile, config_path)
if success then
    CONFIGURATION = result
else
    print("configuration.lua not found at " .. config_path .. ", skipping...")
end

-- Add a global variable to track active chat viewers
if not _G.ActiveChatViewer then
    _G.ActiveChatViewer = nil
end

-- Global reference to current loading dialog for closing
local _active_loading_dialog = nil
local _loading_animation_task = nil

-- Create bouncing dot animation for loading state
local function createLoadingAnimation()
    local frames = { ".", "..", "...", "..", "." }
    local currentIndex = 1
    return {
        getNextFrame = function()
            local frame = frames[currentIndex]
            currentIndex = currentIndex + 1
            if currentIndex > #frames then
                currentIndex = 1
            end
            return frame
        end,
    }
end

-- Show enhanced loading dialog with provider/model info and animation
-- @param config: Optional configuration for displaying provider/model info
local function showLoadingDialog(config)
    -- Close any existing loading dialog
    if _active_loading_dialog then
        UIManager:close(_active_loading_dialog)
        _active_loading_dialog = nil
    end
    if _loading_animation_task then
        UIManager:unschedule(_loading_animation_task)
        _loading_animation_task = nil
    end

    -- Build status text
    local status_lines = {}
    if config then
        local provider = config.features and config.features.provider or "AI"
        local model = ConfigHelper:getModelInfo(config) or "default"
        table.insert(status_lines, string.format("%s: %s", provider:gsub("^%l", string.upper), model))

        -- Check for reasoning/thinking enabled using computed api_params
        -- These are set by buildUnifiedRequestConfig based on action overrides and global settings
        local reasoning_enabled = false
        if config.api_params then
            -- Anthropic: thinking, OpenAI: reasoning, Gemini: thinking_level / thinking_budget
            if config.api_params.thinking or config.api_params.reasoning or config.api_params.thinking_level
               or (config.api_params.thinking_budget and config.api_params.thinking_budget ~= 0) then
                reasoning_enabled = true
            end
        end
        if reasoning_enabled then
            table.insert(status_lines, _("Reasoning enabled"))
        end

        -- Show action name if available
        if config.features and config.features.loading_action_name then
            table.insert(status_lines, config.features.loading_action_name)
        end
    end

    local base_text = #status_lines > 0 and table.concat(status_lines, "\n") .. "\n\n" or ""
    local animation = createLoadingAnimation()

    -- Create initial loading dialog
    local function createLoadingMessage()
        return InfoMessage:new{
            text = base_text .. _("Loading") .. animation:getNextFrame(),
            -- No timeout - will be closed when response arrives
        }
    end

    _active_loading_dialog = createLoadingMessage()
    UIManager:show(_active_loading_dialog)

    -- Animate the loading dots by recreating the dialog
    local function updateAnimation()
        if _active_loading_dialog then
            -- Close current and show updated
            UIManager:close(_active_loading_dialog)
            _active_loading_dialog = createLoadingMessage()
            UIManager:show(_active_loading_dialog)
            _loading_animation_task = UIManager:scheduleIn(0.4, updateAnimation)
        end
    end
    _loading_animation_task = UIManager:scheduleIn(0.4, updateAnimation)
end

-- Close the loading dialog (called when response is ready)
local function closeLoadingDialog()
    if _loading_animation_task then
        UIManager:unschedule(_loading_animation_task)
        _loading_animation_task = nil
    end
    if _active_loading_dialog then
        UIManager:close(_active_loading_dialog)
        _active_loading_dialog = nil
    end
end

-- Helper function to determine prompt context
local function getPromptContext(config)
    if config and config.features then
        if config.features.is_library_context then
            return "library"
        elseif config.features.is_book_context then
            return "book"
        elseif config.features.is_general_context then
            return "general"
        end
    end
    return "highlight"  -- default
end

-- Helper to persist domain selection to settings
-- This ensures domain selection survives restarts
local function persistDomainSelection(plugin, domain_id)
    if not plugin or not plugin.settings then return end
    local features = plugin.settings:readSetting("features") or {}
    features.selected_domain = domain_id
    plugin.settings:saveSetting("features", features)
    plugin.settings:flush()
end

-- Helper to persist per-book domain selection to DocSettings
local function persistBookDomain(doc_settings, domain_id)
    if not doc_settings then return end
    doc_settings:saveSetting("koassistant_book_domain", domain_id)
    doc_settings:flush()
end

-- Helper to read per-book domain from DocSettings
local function getBookDomain(doc_settings)
    if not doc_settings then return nil end
    return doc_settings:readSetting("koassistant_book_domain")
end

-- Extract surrounding context for dictionary lookups
-- Uses KOReader's highlight API to get text before/after selection
-- @param ui: KOReader UI instance with highlight module
-- @param highlighted_text: The selected text
-- @param mode: "sentence" (default), "paragraph", or "characters"
-- @param char_count: Number of characters for "characters" mode (default 100)
-- @return string: Formatted context or empty string if unavailable
--
-- Hard cap: 2000 chars maximum to prevent use as book text extraction bypass.
-- This is context for disambiguation, not document extraction.
local SURROUNDING_CONTEXT_MAX_CHARS = 2000

-- string.sub operates on bytes, splitting multibyte UTF-8 chars
local UTF8_CHAR_PATTERN = '[%z\1-\127\194-\253][\128-\191]*'

local function utf8_first(str, n)
    local count = 0
    local byte_end = 0
    for uchar in str:gmatch(UTF8_CHAR_PATTERN) do
        count = count + 1
        if count > n then
            return str:sub(1, byte_end), true
        end
        byte_end = byte_end + #uchar
    end
    return str:sub(1, byte_end), false
end

local function utf8_last(str, n)
    local offsets = {}
    local count = 0
    local pos = 1
    for uchar in str:gmatch(UTF8_CHAR_PATTERN) do
        count = count + 1
        offsets[count] = pos
        pos = pos + #uchar
    end
    if count <= n then
        return str, false
    end
    return str:sub(offsets[count - n + 1]), true
end

local function extractSurroundingContext(ui, highlighted_text, mode, char_count)
    mode = mode or "sentence"

    -- "none" mode: don't extract any context, just return empty string
    if mode == "none" then
        return ""
    end

    char_count = char_count or 100
    -- Enforce hard cap: char_count per side, so halve the max for characters mode
    local max_per_side = math.floor(SURROUNDING_CONTEXT_MAX_CHARS / 2)
    if char_count > max_per_side then
        char_count = max_per_side
    end

    local prev_context, next_context = nil, nil

    -- Try to get context from KOReader's highlight module
    -- Note: This works for text that was selected (hold-select), but NOT for
    -- single word taps (dictionary popup). For word taps, no selection exists.
    if ui and ui.highlight and ui.highlight.getSelectedWordContext then
        -- Get plenty of words to cover our needs (50 words should be enough)
        prev_context, next_context = ui.highlight:getSelectedWordContext(50)
    end

    if not prev_context and not next_context then
        return ""  -- No context available
    end

    prev_context = prev_context or ""
    next_context = next_context or ""

    -- Mark the highlighted word with >>> <<< markers
    local word_marker = ">>>" .. (highlighted_text or "") .. "<<<"

    if mode == "characters" then
        -- Return fixed character count before/after
        local before, before_truncated = utf8_last(prev_context, char_count)
        local after, after_truncated = utf8_first(next_context, char_count)
        -- Add ellipsis if text was truncated
        if before_truncated then
            before = "..." .. before
        end
        if after_truncated then
            after = after .. "..."
        end
        return before .. " " .. word_marker .. " " .. after

    elseif mode == "paragraph" then
        -- Return full context with word marked, but enforce hard cap
        local before = prev_context
        local after = next_context
        -- Truncate each side to half the max
        before = utf8_last(before, max_per_side)
        after = utf8_first(after, max_per_side)
        -- Add ellipsis to indicate this is an excerpt
        if #before > 0 then
            before = "..." .. before
        end
        if #after > 0 then
            after = after .. "..."
        end
        return before .. " " .. word_marker .. " " .. after

    else  -- "sentence" mode (default)
        -- Try to find sentence boundaries
        -- Look for sentence-ending punctuation followed by space or end of string
        local function findSentenceStart(text)
            -- Search backwards for sentence end (.!?) followed by space
            local last_end = text:match(".*[%.!%?]%s+()") or 1
            return text:sub(last_end)
        end

        local function findSentenceEnd(text)
            -- Search forwards for sentence end (.!?)
            local end_pos = text:find("[%.!%?]%s") or text:find("[%.!%?]$")
            if end_pos then
                return text:sub(1, end_pos)
            end
            return text
        end

        local sentence_before = findSentenceStart(prev_context)
        local sentence_after = findSentenceEnd(next_context)

        -- If sentence parsing results in very little text, fall back to characters mode
        local result = sentence_before .. " " .. word_marker .. " " .. sentence_after
        if #result < 30 then  -- Adjusted threshold to account for marker
            -- Fall back to characters mode
            return extractSurroundingContext(ui, highlighted_text, "characters", char_count)
        end

        -- Add leading ellipsis if we trimmed the start
        if #sentence_before < #prev_context then
            result = "..." .. result
        end
        -- Add trailing ellipsis if we trimmed the end
        if #sentence_after < #next_context then
            result = result .. "..."
        end

        -- Enforce hard cap on sentence mode result
        local _truncated
        result, _truncated = utf8_first(result, SURROUNDING_CONTEXT_MAX_CHARS)
        if _truncated then
            result = result .. "..."
        end

        return result
    end
end

-- Build unified request config for ALL providers (v0.5.2+)
--
-- All providers receive the same config structure:
--   config.system = { text, enable_caching, components }
--   config.api_params = { temperature, max_tokens, thinking }
--
-- Each handler then adapts to its native API format
--
-- Note: Reasoning indicator only shows when actual reasoning content is returned
-- in the API response. For streaming mode, reasoning content isn't captured,
-- so indicator won't show. This is intentional - we only indicate when
-- reasoning was actually USED, not just when it was requested.

-- @param config: Configuration to modify (modified in-place)
-- @param domain_context: Optional domain context string
-- @param action: Optional action definition with behavior/api_params
-- @param plugin: Plugin instance
-- @return boolean: true if config was successfully built
local function buildUnifiedRequestConfig(config, domain_context, action, plugin)
    if not config then return false end

    local features = config.features or {}
    local SystemPrompts = require("prompts.system_prompts")

    -- Build unified system prompt (works for all providers)
    local system_config = SystemPrompts.buildUnifiedSystem({
        -- Behavior resolution (priority: action override > action variant > global)
        behavior_variant = action and action.behavior_variant,
        behavior_override = action and action.behavior_override,
        global_variant = features.selected_behavior or "standard",
        custom_ai_behavior = features.custom_ai_behavior,  -- Legacy support (for migrated users)
        custom_behaviors = features.custom_behaviors,       -- NEW: array of UI-created behaviors
        -- Domain context
        domain_context = domain_context,
        -- Caching (only effective for Anthropic)
        enable_caching = (config.provider or config.default_provider) == "anthropic",
        -- Language settings (interaction_languages is new array format, user_languages is old string format)
        interaction_languages = features.interaction_languages,
        user_languages = features.user_languages or "",
        primary_language = features.primary_language,
        skip_language_instruction = action and action.skip_language_instruction,
        -- Research mode: DOI triggers academic nudge in system prompt
        book_metadata = features.book_metadata,
    })

    config.system = system_config

    -- Build api_params (works for all providers, handlers use what they support)
    config.api_params = {}

    -- Start with action-specific API params if available
    if action and action.api_params then
        for k, v in pairs(action.api_params) do
            config.api_params[k] = v
        end
    end

    -- Apply per-action temperature override, or fall back to global
    if action and action.temperature then
        config.api_params.temperature = action.temperature
    elseif not config.api_params.temperature and features.default_temperature then
        config.api_params.temperature = features.default_temperature
    end

    -- Note: max_tokens is NOT set here. If the action doesn't specify it,
    -- handlers fall back to their provider defaults (defaults.lua), then to 16384.
    -- Model-specific ceilings are enforced by ModelConstraints.clampMaxTokens().

    -- Reasoning/Thinking support (per-provider toggles)
    -- Priority: action.reasoning_config > action.reasoning > master toggle > per-provider setting
    -- Master toggle gates: Anthropic, Gemini (2.5+3), and OpenAI 5.1+ (reasoning_gated)
    -- Always-on models (o3, gpt-5, deepseek-reasoner): not affected, use factory defaults
    local provider = config.provider or config.default_provider or "anthropic"

    -- Master reasoning toggle
    local enable_reasoning_master = features.enable_reasoning

    -- Global defaults from settings (fall back to centralized defaults)
    local rd = ModelConstraints.reasoning_defaults
    local reasoning_budget = features.reasoning_budget or rd.anthropic.budget
    local reasoning_effort = features.reasoning_effort or rd.openai.effort
    local reasoning_depth = features.reasoning_depth or rd.gemini.level
    local gemini_thinking_budget = features.gemini_thinking_budget or rd.gemini.budget

    -- Anthropic adaptive thinking (4.6) settings
    -- Sub-toggles default true (opt-out): use ~= false so nil (unset) is treated as enabled
    local anthropic_adaptive = enable_reasoning_master and (features.anthropic_adaptive ~= false)
    local anthropic_effort = features.anthropic_effort or rd.anthropic_adaptive.effort

    -- Per-provider reasoning toggles (gated by master toggle + individual toggle)
    -- All sub-toggles default true: when master is ON, all providers reason by default
    local anthropic_reasoning = enable_reasoning_master and (features.anthropic_reasoning ~= false)
    local openai_reasoning = enable_reasoning_master and (features.openai_reasoning ~= false)
    local gemini_reasoning = enable_reasoning_master and (features.gemini_reasoning ~= false)
    local zai_reasoning = enable_reasoning_master and (features.zai_reasoning ~= false)
    local deepseek_reasoning = enable_reasoning_master and (features.deepseek_reasoning ~= false)
    local openrouter_reasoning = enable_reasoning_master and (features.openrouter_reasoning ~= false)
    local sambanova_reasoning = enable_reasoning_master and (features.sambanova_reasoning ~= false)

    -- Effort defaults for effort-based providers
    -- Toggleable (gated by master): OpenRouter
    local openrouter_effort = features.openrouter_effort or rd.openrouter.effort
    -- Always-on providers (effort only, not gated by master toggle):
    local groq_effort = features.groq_effort or rd.groq.effort
    local together_effort = features.together_effort or rd.together.effort
    local fireworks_effort = features.fireworks_effort or rd.fireworks.effort
    local xai_effort = features.xai_effort or rd.xai.effort
    local perplexity_effort = features.perplexity_effort or rd.perplexity.effort
    local openai_always_on_effort = features.openai_always_on_effort or "medium"

    -- Check for action overrides
    -- NEW format: action.reasoning_config = { anthropic: {...}, openai: {...}, ... } or "off"
    -- LEGACY format: action.reasoning = "on"/"off", action.thinking_budget, etc.
    local action_anthropic_override = nil  -- nil = use global, true = on, false = off
    local action_anthropic_adaptive_override = nil  -- nil = use global, true = on, false = off
    local action_openai_override = nil
    local action_gemini_override = nil
    local action_zai_override = nil
    local action_deepseek_override = nil
    local action_openrouter_override = nil
    local action_groq_override = nil
    local action_together_override = nil
    local action_fireworks_override = nil
    local action_sambanova_override = nil
    local action_xai_override = nil
    local action_perplexity_override = nil

    if action then
        -- NEW format: per-provider reasoning_config
        if action.reasoning_config then
            if action.reasoning_config == "off" then
                -- Force off for all providers
                action_anthropic_override = false
                action_anthropic_adaptive_override = false
                action_openai_override = false
                action_gemini_override = false
                action_zai_override = false
                action_deepseek_override = false
                action_openrouter_override = false
                action_groq_override = false
                action_together_override = false
                action_fireworks_override = false
                action_sambanova_override = false
                action_xai_override = false
                action_perplexity_override = false
            elseif type(action.reasoning_config) == "table" then
                -- Per-provider configuration
                local rc = action.reasoning_config

                -- Anthropic config
                if rc.anthropic ~= nil then
                    if rc.anthropic == "off" or rc.anthropic == false then
                        action_anthropic_override = false
                        action_anthropic_adaptive_override = false
                    elseif type(rc.anthropic) == "table" then
                        if rc.anthropic.effort then
                            action_anthropic_adaptive_override = true
                            anthropic_effort = rc.anthropic.effort
                        end
                        if rc.anthropic.budget then
                            action_anthropic_override = true
                            reasoning_budget = rc.anthropic.budget
                        end
                    end
                end

                -- OpenAI config
                if rc.openai ~= nil then
                    if rc.openai == "off" or rc.openai == false then
                        action_openai_override = false
                    elseif type(rc.openai) == "table" and rc.openai.effort then
                        action_openai_override = true
                        reasoning_effort = rc.openai.effort
                    end
                end

                -- Gemini config
                if rc.gemini ~= nil then
                    if rc.gemini == "off" or rc.gemini == false then
                        action_gemini_override = false
                    elseif type(rc.gemini) == "table" then
                        if rc.gemini.level then
                            action_gemini_override = true
                            reasoning_depth = rc.gemini.level
                        end
                        if rc.gemini.budget then
                            action_gemini_override = true
                            gemini_thinking_budget = rc.gemini.budget
                        end
                    end
                end

                -- Z.AI config (binary: on/off, no effort levels)
                if rc.zai ~= nil then
                    if rc.zai == "off" or rc.zai == false then
                        action_zai_override = false
                    else
                        action_zai_override = true
                    end
                end

                -- DeepSeek config (binary: on/off)
                if rc.deepseek ~= nil then
                    if rc.deepseek == "off" or rc.deepseek == false then
                        action_deepseek_override = false
                    else
                        action_deepseek_override = true
                    end
                end

                -- SambaNova config (binary: on/off)
                if rc.sambanova ~= nil then
                    if rc.sambanova == "off" or rc.sambanova == false then
                        action_sambanova_override = false
                    else
                        action_sambanova_override = true
                    end
                end

                -- Effort-based providers: override can be false (off) or { effort = "..." }
                -- OpenRouter
                if rc.openrouter ~= nil then
                    if rc.openrouter == "off" or rc.openrouter == false then
                        action_openrouter_override = false
                    elseif type(rc.openrouter) == "table" and rc.openrouter.effort then
                        action_openrouter_override = true
                        openrouter_effort = rc.openrouter.effort
                    else
                        action_openrouter_override = true
                    end
                end

                -- Groq
                if rc.groq ~= nil then
                    if rc.groq == "off" or rc.groq == false then
                        action_groq_override = false
                    elseif type(rc.groq) == "table" and rc.groq.effort then
                        action_groq_override = true
                        groq_effort = rc.groq.effort
                    else
                        action_groq_override = true
                    end
                end

                -- Together
                if rc.together ~= nil then
                    if rc.together == "off" or rc.together == false then
                        action_together_override = false
                    elseif type(rc.together) == "table" and rc.together.effort then
                        action_together_override = true
                        together_effort = rc.together.effort
                    else
                        action_together_override = true
                    end
                end

                -- Fireworks
                if rc.fireworks ~= nil then
                    if rc.fireworks == "off" or rc.fireworks == false then
                        action_fireworks_override = false
                    elseif type(rc.fireworks) == "table" and rc.fireworks.effort then
                        action_fireworks_override = true
                        fireworks_effort = rc.fireworks.effort
                    else
                        action_fireworks_override = true
                    end
                end

                -- xAI
                if rc.xai ~= nil then
                    if rc.xai == "off" or rc.xai == false then
                        action_xai_override = false
                    elseif type(rc.xai) == "table" and rc.xai.effort then
                        action_xai_override = true
                        xai_effort = rc.xai.effort
                    else
                        action_xai_override = true
                    end
                end

                -- Perplexity
                if rc.perplexity ~= nil then
                    if rc.perplexity == "off" or rc.perplexity == false then
                        action_perplexity_override = false
                    elseif type(rc.perplexity) == "table" and rc.perplexity.effort then
                        action_perplexity_override = true
                        perplexity_effort = rc.perplexity.effort
                    else
                        action_perplexity_override = true
                    end
                end
            end
        -- LEGACY format: action.reasoning = "on"/"off" or action.extended_thinking
        elseif action.reasoning == "off" or action.extended_thinking == "off" then
            -- Legacy: force off for all providers
            action_anthropic_override = false
            action_anthropic_adaptive_override = false
            action_openai_override = false
            action_gemini_override = false
            action_zai_override = false
            action_deepseek_override = false
            action_openrouter_override = false
            action_groq_override = false
            action_together_override = false
            action_fireworks_override = false
            action_sambanova_override = false
            action_xai_override = false
            action_perplexity_override = false
        elseif action.reasoning == "on" or action.extended_thinking == "on" then
            -- Legacy: force on with per-field overrides
            action_anthropic_override = true
            action_anthropic_adaptive_override = true
            action_openai_override = true
            action_gemini_override = true
            action_zai_override = true
            action_deepseek_override = true
            action_openrouter_override = true
            action_groq_override = true
            action_together_override = true
            action_fireworks_override = true
            action_sambanova_override = true
            action_xai_override = true
            action_perplexity_override = true
            if action.thinking_budget then reasoning_budget = action.thinking_budget end
            if action.reasoning_effort then reasoning_effort = action.reasoning_effort end
            if action.reasoning_depth then reasoning_depth = action.reasoning_depth end
        end
    end

    -- Apply reasoning parameters based on provider
    -- Note: Can't use `x ~= nil and x or default` pattern here because x=false
    -- is falsy in Lua, causing it to fall through to the default. Use explicit nil check.
    if provider == "anthropic" then
        local model = config.model or Defaults.ProviderDefaults.anthropic.model
        local use_adaptive = ModelConstraints.supportsCapability("anthropic", model, "adaptive_thinking")

        if use_adaptive then
            -- Adaptive thinking (4.6+ models): check adaptive toggle first
            local enabled = anthropic_adaptive
            if action_anthropic_adaptive_override ~= nil then enabled = action_anthropic_adaptive_override end
            if enabled then
                config.api_params.thinking = { type = "adaptive" }
                config.api_params.output_config = { effort = anthropic_effort }
            end
        end
        -- Fallback: manual mode for older models OR 4.6 when adaptive not enabled
        if not config.api_params.thinking then
            local enabled = anthropic_reasoning
            if action_anthropic_override ~= nil then enabled = action_anthropic_override end
            if enabled then
                config.api_params.thinking = {
                    type = "enabled",
                    budget_tokens = math.max(reasoning_budget, 1024),
                }
            end
        end
    elseif provider == "openai" then
        local model = config.model or Defaults.ProviderDefaults.openai.model
        local is_gated = ModelConstraints.supportsCapability("openai", model, "reasoning_gated")

        if action_openai_override ~= nil then
            -- Per-action override applies to all reasoning models
            if action_openai_override and ModelConstraints.supportsCapability("openai", model, "reasoning") then
                config.api_params.reasoning = { effort = reasoning_effort }
            end
        elseif is_gated then
            -- Gated models (5.1+): controlled by master + openai_reasoning toggle
            if openai_reasoning then
                config.api_params.reasoning = { effort = reasoning_effort }
            end
        elseif ModelConstraints.supportsCapability("openai", model, "reasoning") then
            -- Always-on models (o3, gpt-5): send configured effort level
            config.api_params.reasoning = { effort = openai_always_on_effort }
        end
    elseif provider == "gemini" then
        local model = config.model or Defaults.ProviderDefaults.gemini.model
        local enabled = gemini_reasoning
        if action_gemini_override ~= nil then enabled = action_gemini_override end

        if enabled then
            -- Gemini 3: set thinking level
            if ModelConstraints.supportsCapability("gemini", model, "thinking") then
                config.api_params.thinking_level = reasoning_depth:upper()
            end
            -- Gemini 2.5: set thinking budget (named level -> numeric value)
            if ModelConstraints.supportsCapability("gemini", model, "thinking_budget") then
                local budget_map = rd.gemini.budget_map
                config.api_params.thinking_budget = budget_map[gemini_thinking_budget] or -1
            end
        elseif action_gemini_override == false or enable_reasoning_master then
            -- Suppress thinking when per-action override says OFF or master is ON
            -- but sub-toggle is OFF. When master is OFF with no action override,
            -- don't send anything — let API defaults apply (Gemini 2.5 thinks by default).
            if ModelConstraints.supportsCapability("gemini", model, "thinking_budget") then
                config.api_params.thinking_budget = 0
            end
        end
    elseif provider == "zai" then
        local model = config.model or Defaults.ProviderDefaults.zai.model
        if ModelConstraints.supportsCapability("zai", model, "thinking") then
            local enabled = zai_reasoning
            if action_zai_override ~= nil then enabled = action_zai_override end
            if enabled then
                config.api_params.zai_thinking = { type = "enabled" }
            elseif action_zai_override == false or enable_reasoning_master then
                -- Suppress when per-action says OFF or master ON but sub-toggle OFF.
                -- When master OFF with no override: API default (GLM-4.5+ thinks).
                config.api_params.zai_thinking = { type = "disabled" }
            end
        end
    elseif provider == "deepseek" then
        local model = config.model or Defaults.ProviderDefaults.deepseek.model
        if ModelConstraints.supportsCapability("deepseek", model, "thinking") then
            local enabled = deepseek_reasoning
            if action_deepseek_override ~= nil then enabled = action_deepseek_override end
            if enabled then
                config.api_params.deepseek_thinking = { type = "enabled" }
            elseif action_deepseek_override == false or enable_reasoning_master then
                -- Suppress when per-action says OFF or master ON but sub-toggle OFF.
                -- When master OFF with no override: API default (reasoner thinks, chat doesn't).
                config.api_params.deepseek_thinking = { type = "disabled" }
            end
        end
    elseif provider == "openrouter" then
        local enabled = openrouter_reasoning
        if action_openrouter_override ~= nil then enabled = action_openrouter_override end
        if enabled then
            config.api_params.openrouter_reasoning = { effort = openrouter_effort }
        end
    elseif provider == "groq" then
        -- Always-on reasoning: send effort unless per-action override says off
        local model = config.model or Defaults.ProviderDefaults.groq.model
        if ModelConstraints.supportsCapability("groq", model, "reasoning") then
            if action_groq_override ~= false then
                config.api_params.groq_reasoning = { effort = groq_effort }
            end
        end
    elseif provider == "together" then
        -- Always-on reasoning: send effort unless per-action override says off
        local model = config.model or Defaults.ProviderDefaults.together.model
        if ModelConstraints.supportsCapability("together", model, "reasoning") then
            if action_together_override ~= false then
                config.api_params.together_reasoning = { effort = together_effort }
            end
        end
    elseif provider == "fireworks" then
        -- Always-on reasoning: send effort unless per-action override says off
        local model = config.model or Defaults.ProviderDefaults.fireworks.model
        if ModelConstraints.supportsCapability("fireworks", model, "reasoning") then
            if action_fireworks_override ~= false then
                config.api_params.fireworks_reasoning = { effort = fireworks_effort }
            end
        end
    elseif provider == "sambanova" then
        local model = config.model or Defaults.ProviderDefaults.sambanova.model
        if ModelConstraints.supportsCapability("sambanova", model, "thinking") then
            local enabled = sambanova_reasoning
            if action_sambanova_override ~= nil then enabled = action_sambanova_override end
            if enabled then
                config.api_params.sambanova_thinking = true
            end
            -- When disabled or nil: handler defaults to { enable_thinking = false }
        end
    elseif provider == "xai" then
        -- Always-on reasoning: send effort unless per-action override says off
        local model = config.model or Defaults.ProviderDefaults.xai.model
        if ModelConstraints.supportsCapability("xai", model, "reasoning") then
            if action_xai_override ~= false then
                config.api_params.xai_reasoning = { effort = xai_effort }
            end
        end
    elseif provider == "perplexity" then
        -- Always-on reasoning: send effort unless per-action override says off
        local model = config.model or Defaults.ProviderDefaults.perplexity.model
        if ModelConstraints.supportsCapability("perplexity", model, "reasoning") then
            if action_perplexity_override ~= false then
                config.api_params.perplexity_reasoning = { effort = perplexity_effort }
            end
        end
    end

    -- Web search support (per-action override)
    -- Global setting is in features.enable_web_search, per-action is action.enable_web_search
    -- nil = follow global, true = force on, false = force off
    if action and action.enable_web_search ~= nil then
        config.enable_web_search = action.enable_web_search
    end

    -- Set action name for loading dialog display (used by non-streaming loading dialog)
    if action and action.text then
        config.features = config.features or {}
        config.features.loading_action_name = action.text
    end

    return true
end

local function createTempConfig(prompt, base_config)
    -- Use the passed base_config if available, otherwise fall back to CONFIGURATION
    local source_config = base_config or CONFIGURATION or {}
    local temp_config = {}
    
    for k, v in pairs(source_config) do
        if type(v) ~= "table" then
            temp_config[k] = v
        else
            temp_config[k] = {}
            for k2, v2 in pairs(v) do
                temp_config[k][k2] = v2
            end
        end
    end
    
    -- Only override if provider/model are specified in the prompt
    if prompt.provider then 
        temp_config.provider = prompt.provider
        if prompt.model then
            temp_config.provider_settings = temp_config.provider_settings or {}
            temp_config.provider_settings[temp_config.provider] = temp_config.provider_settings[temp_config.provider] or {}
            temp_config.provider_settings[temp_config.provider].model = prompt.model
        end
    end
    
    return temp_config
end

local function getAllPrompts(configuration, plugin)
    local prompts = {}
    local prompt_keys = {}  -- Array to store keys in order

    -- Use the passed configuration or the global one
    local config = configuration or CONFIGURATION

    -- Determine context
    local context = config and getPromptContext(config) or "highlight"

    -- Check if a book is currently open (for filtering requires_open_book actions)
    local has_open_book = plugin and plugin.ui and plugin.ui.document ~= nil

    -- Debug logging
    local logger = require("logger")
    logger.info("getAllPrompts: context = " .. context .. ", has_open_book = " .. tostring(has_open_book))

    -- Use ActionService if available, fallback to PromptService
    local service = plugin and (plugin.action_service or plugin.prompt_service)
    if service then
        local service_prompts
        -- For general context, use the filtered general menu list
        -- (users can add/remove actions via Action Manager)
        if context == "general" and service.getGeneralMenuActionObjects then
            service_prompts = service:getGeneralMenuActionObjects()
            logger.info("getAllPrompts: Got " .. #service_prompts .. " prompts from general menu list")
        else
            service_prompts = service:getAllPrompts(context, false, has_open_book)
            logger.info("getAllPrompts: Got " .. #service_prompts .. " prompts from " ..
                        (plugin.action_service and "ActionService" or "PromptService"))
        end

        -- Convert from array to keyed table for compatibility
        for _idx, prompt in ipairs(service_prompts) do
            local key = prompt.id or ("prompt_" .. #prompt_keys + 1)
            prompts[key] = prompt
            table.insert(prompt_keys, key)
        end
    else
        logger.warn("getAllPrompts: No prompt service available, no prompts returned")
    end

    return prompts, prompt_keys
end

local function createSaveDialog(document_path, history, chat_history_manager, is_general_context, book_metadata, launch_context, highlighted_text, ui, config)
    -- Guard against missing document path - allow special case for general context
    if not document_path and not is_general_context then
        UIManager:show(InfoMessage:new{
            text = _("Cannot save: no document context"),
            timeout = 2,
        })
        return
    end
    
    -- Use special path for general context chats
    if is_general_context and not document_path then
        document_path = "__GENERAL_CHATS__"
    end
    
    -- Get a suggested title from the conversation
    local suggested_title = history:getSuggestedTitle()
    
    -- Create the dialog with proper variable handling
    local save_dialog
    save_dialog = InputDialog:new{
        title = _("Save Chat"),
        input = suggested_title,
        buttons = {
            {
                {
                    text = _("Close"),
                    id = "close",
                    callback = function()
                        -- Close the dialog and do nothing else
                        UIManager:close(save_dialog)
                    end,
                },
                {
                    text = _("Save"),
                    callback = function()
                        -- First get the title
                        local chat_title = save_dialog:getInputText()
                        
                        -- Then close the dialog
                        UIManager:close(save_dialog)
                        
                        -- Now handle the save operation with error protection
                        local success, result = pcall(function()
                            -- Check if this chat already has an ID (continuation of existing chat)
                            local metadata = {}
                            if history.chat_id then
                                metadata.id = history.chat_id
                            end

                            -- Add book metadata if available
                            if book_metadata then
                                metadata.book_title = book_metadata.title
                                metadata.book_author = book_metadata.author
                                logger.info("KOAssistant: Saving chat with metadata - title: " .. (book_metadata.title or "nil") .. ", author: " .. (book_metadata.author or "nil"))
                            else
                                logger.info("KOAssistant: No book metadata available for save")
                            end

                            -- Add launch context if available (for general chats launched from a book)
                            if launch_context then
                                metadata.launch_context = launch_context
                                logger.info("KOAssistant: Saving chat with launch context - from: " .. (launch_context.title or "nil"))
                            end

                            -- Store highlighted text for display toggle in continued chats
                            if highlighted_text and highlighted_text ~= "" then
                                metadata.original_highlighted_text = highlighted_text
                            end

                            -- Check storage version and route to appropriate method
                            if chat_history_manager:useDocSettingsStorage() then
                                -- v2: DocSettings-based storage
                                -- Build complete chat_data structure (matching old saveChat format)
                                local chat_id = metadata.id or chat_history_manager:generateChatId()

                                -- Preserve existing tags and starred when updating an existing chat
                                local existing_tags = {}
                                local existing_starred
                                if metadata.id then
                                    local existing = chat_history_manager:getChatById(document_path, metadata.id)
                                    if existing then
                                        existing_tags = existing.tags or {}
                                        existing_starred = existing.starred
                                    end
                                end

                                local chat_data = {
                                    id = chat_id,
                                    title = chat_title or "Conversation",
                                    document_path = document_path,
                                    timestamp = os.time(),
                                    messages = history:getMessages(),
                                    model = history:getModel(),
                                    metadata = metadata,
                                    book_title = metadata.book_title,
                                    book_author = metadata.book_author,
                                    prompt_action = history.prompt_action,
                                    launch_context = metadata.launch_context,
                                    domain = metadata.domain,
                                    tags = existing_tags,
                                    starred = existing_starred,
                                    original_highlighted_text = metadata.original_highlighted_text,
                                    -- Store system prompt metadata for debug display
                                    system_metadata = config and config.system,
                                    -- Store cache continuation info (for "Updated from X% cache" notice)
                                    used_cache = history.used_cache,
                                    cached_progress = history.cached_progress,
                                    cache_action_id = history.cache_action_id,
                                    -- Store book text truncation info
                                    book_text_truncated = history.book_text_truncated,
                                    book_text_coverage_start = history.book_text_coverage_start,
                                    book_text_coverage_end = history.book_text_coverage_end,
                                    -- Store unavailable data info
                                    unavailable_data = history.unavailable_data,
                                }

                                if document_path == "__GENERAL_CHATS__" then
                                    return chat_history_manager:saveGeneralChat(chat_data)
                                else
                                    return chat_history_manager:saveChatToDocSettings(ui, chat_data)
                                end
                            else
                                -- v1: Legacy hash-based storage
                                return chat_history_manager:saveChat(
                                    document_path,
                                    chat_title,
                                    history,
                                    metadata
                                )
                            end
                        end)
                        
                        -- Show appropriate message
                        if success and result then
                            -- Store the chat ID in history for future saves
                            if not history.chat_id then
                                history.chat_id = result
                            end

                            -- Mark as saved and update button on active viewer
                            local active_viewer = _G.ActiveChatViewer
                            if active_viewer then
                                local features = active_viewer.configuration and active_viewer.configuration.features
                                if features then
                                    features.chat_saved = true
                                end
                                if active_viewer.button_table then
                                    local will_auto_save = features and (
                                        features.auto_save_all_chats or
                                        features.auto_save_chats ~= false
                                    )
                                    local button_text = will_auto_save and _("Autosaved") or _("Saved")
                                    local save_button = active_viewer.button_table:getButtonById("save_chat")
                                    if save_button then
                                        save_button:setText(button_text, save_button.width)
                                        save_button:disable()
                                        UIManager:setDirty(active_viewer, function()
                                            return "ui", save_button.dimen
                                        end)
                                    end
                                end
                            end

                            UIManager:show(InfoMessage:new{
                                text = _("Chat saved successfully"),
                                timeout = 2,
                            })
                        else
                            UIManager:show(InfoMessage:new{
                                text = _("Failed to save chat: ") .. tostring(result),
                                timeout = 2,
                            })
                        end
                    end,
                },
            },
        },
    }

    -- Add rotation support to save dialog
    local recreate_save_dialog  -- Forward declaration for recursive calls
    recreate_save_dialog = function(input_text)
        local new_dialog
        new_dialog = InputDialog:new{
            title = _("Save Chat"),
            input = input_text or suggested_title,
            buttons = save_dialog.buttons,
        }
        new_dialog.onScreenResize = function(self, dimen)
            local current_input = self:getInputText()
            UIManager:close(self)
            UIManager:scheduleIn(0.2, function()
                recreate_save_dialog(current_input)
            end)
            return true
        end
        new_dialog.onSetRotationMode = function(self, rotation)
            return self:onScreenResize(nil)
        end
        UIManager:show(new_dialog)
    end

    save_dialog.onScreenResize = function(self, dimen)
        local current_input = self:getInputText()
        UIManager:close(self)
        UIManager:scheduleIn(0.2, function()
            recreate_save_dialog(current_input)
        end)
        return true
    end

    save_dialog.onSetRotationMode = function(self, rotation)
        return self:onScreenResize(nil)
    end

    -- Show the dialog now that it's fully defined
    UIManager:show(save_dialog)
end

-- Helper function to create exportable text from history
local function createExportText(history, format)
    local result = {}
    local is_markdown = format == "markdown"

    if is_markdown then
        table.insert(result, "# Chat")
        table.insert(result, "**Date:** " .. os.date("%Y-%m-%d %H:%M"))
        table.insert(result, "**Model:** " .. (history:getModel() or "Unknown"))
    else
        table.insert(result, "Chat")
        table.insert(result, "Date: " .. os.date("%Y-%m-%d %H:%M"))
        table.insert(result, "Model: " .. (history:getModel() or "Unknown"))
    end
    table.insert(result, "")

    -- Format messages
    for _idx, msg in ipairs(history:getMessages()) do
        local role = msg.role:gsub("^%l", string.upper)
        local content = msg.content

        -- Skip context messages in export by default
        if not msg.is_context then
            if is_markdown then
                table.insert(result, "### " .. role)
                table.insert(result, content)
            else
                table.insert(result, role .. ": " .. content)
            end
            table.insert(result, "")
        end
    end

    return table.concat(result, "\n")
end

-- Track current tags dialog for proper closing
local current_tags_dialog = nil

-- Show tags management menu for a chat
local function showTagsMenu(document_path, chat_id, chat_history_manager)
    local function refreshMenu()
        -- Close current dialog first
        if current_tags_dialog then
            UIManager:close(current_tags_dialog)
            current_tags_dialog = nil
        end
        showTagsMenu(document_path, chat_id, chat_history_manager)
    end

    -- Get fresh chat data
    local chat = chat_history_manager:getChatById(document_path, chat_id)
    if not chat then
        UIManager:show(InfoMessage:new{
            text = _("Chat not found"),
            timeout = 2,
        })
        return
    end

    local current_tags = chat.tags or {}
    local all_tags = chat_history_manager:getAllTags()

    local buttons = {}

    -- Show current tags with remove option
    if #current_tags > 0 then
        table.insert(buttons, {
            {
                text = _("Current tags:"),
                enabled = false,
            },
        })

        for _idx, tag in ipairs(current_tags) do
            table.insert(buttons, {
                {
                    text = "#" .. tag .. " ✕",
                    callback = function()
                        chat_history_manager:removeTagFromChat(document_path, chat_id, tag)
                        UIManager:show(InfoMessage:new{
                            text = T(_("Removed tag: %1"), tag),
                            timeout = 1,
                        })
                        UIManager:scheduleIn(0.3, refreshMenu)
                    end,
                },
            })
        end

        table.insert(buttons, {
            {
                text = "────────────────────",
                enabled = false,
            },
        })
    end

    -- Show existing tags that aren't on this chat (for quick add)
    local available_tags = {}
    for _idx, tag in ipairs(all_tags) do
        local already_has = false
        for _idx2, current in ipairs(current_tags) do
            if current == tag then
                already_has = true
                break
            end
        end
        if not already_has then
            table.insert(available_tags, tag)
        end
    end

    if #available_tags > 0 then
        table.insert(buttons, {
            {
                text = _("Add existing tag:"),
                enabled = false,
            },
        })

        -- Show up to 5 existing tags for quick add
        local shown_tags = 0
        for _idx, tag in ipairs(available_tags) do
            if shown_tags >= 5 then break end
            table.insert(buttons, {
                {
                    text = "#" .. tag,
                    callback = function()
                        chat_history_manager:addTagToChat(document_path, chat_id, tag)
                        UIManager:show(InfoMessage:new{
                            text = T(_("Added tag: %1"), tag),
                            timeout = 1,
                        })
                        UIManager:scheduleIn(0.3, refreshMenu)
                    end,
                },
            })
            shown_tags = shown_tags + 1
        end

        table.insert(buttons, {
            {
                text = "────────────────────",
                enabled = false,
            },
        })
    end

    -- Add new tag button
    table.insert(buttons, {
        {
            text = _("+ Add new tag"),
            callback = function()
                local tag_input
                tag_input = InputDialog:new{
                    title = _("New Tag"),
                    input_hint = _("Enter tag name"),
                    buttons = {
                        {
                            {
                                text = _("Cancel"),
                                id = "close",
                                callback = function()
                                    UIManager:close(tag_input)
                                    refreshMenu()
                                end,
                            },
                            {
                                text = _("Add"),
                                is_enter_default = true,
                                callback = function()
                                    local new_tag = tag_input:getInputText()
                                    UIManager:close(tag_input)
                                    if new_tag and new_tag ~= "" then
                                        -- Remove # if user typed it
                                        new_tag = new_tag:gsub("^#", "")
                                        new_tag = new_tag:match("^%s*(.-)%s*$")  -- trim
                                        if new_tag ~= "" then
                                            chat_history_manager:addTagToChat(document_path, chat_id, new_tag)
                                            UIManager:show(InfoMessage:new{
                                                text = T(_("Added tag: %1"), new_tag),
                                                timeout = 1,
                                            })
                                        end
                                    end
                                    UIManager:scheduleIn(0.3, refreshMenu)
                                end,
                            },
                        },
                    },
                }

                -- Add rotation support to tag input dialog
                local recreate_tag_dialog
                recreate_tag_dialog = function(input_text)
                    local new_tag_dialog
                    new_tag_dialog = InputDialog:new{
                        title = _("New Tag"),
                        input = input_text or "",
                        input_hint = _("Enter tag name"),
                        buttons = tag_input.buttons,
                    }
                    new_tag_dialog.onScreenResize = function(self, dimen)
                        local current = self:getInputText()
                        UIManager:close(self)
                        UIManager:scheduleIn(0.2, function()
                            recreate_tag_dialog(current)
                        end)
                        return true
                    end
                    new_tag_dialog.onSetRotationMode = function(self, rotation)
                        return self:onScreenResize(nil)
                    end
                    UIManager:show(new_tag_dialog)
                    new_tag_dialog:onShowKeyboard()
                end

                tag_input.onScreenResize = function(self, dimen)
                    local current_input = self:getInputText()
                    UIManager:close(self)
                    UIManager:scheduleIn(0.2, function()
                        recreate_tag_dialog(current_input)
                    end)
                    return true
                end

                tag_input.onSetRotationMode = function(self, rotation)
                    return self:onScreenResize(nil)
                end

                UIManager:show(tag_input)
                tag_input:onShowKeyboard()
            end,
        },
    })

    -- Done button
    table.insert(buttons, {
        {
            text = _("Done"),
            callback = function()
                if current_tags_dialog then
                    UIManager:close(current_tags_dialog)
                    current_tags_dialog = nil
                end
            end,
        },
    })

    current_tags_dialog = ButtonDialog:new{
        title = _("Manage Tags"),
        buttons = buttons,
    }
    UIManager:show(current_tags_dialog)
end

local function showResponseDialog(title, history, highlightedText, addMessage, temp_config, document_path, plugin, book_metadata, launch_context, ui_instance)
    -- For compact view (dictionary lookups), force debug OFF regardless of global setting
    -- Create a config copy for createResultText with debug disabled
    local config_for_text = temp_config or CONFIGURATION
    if config_for_text and config_for_text.features and (config_for_text.features.compact_view or config_for_text.features.dictionary_view) then
        -- Don't modify the original config, just note that debug should be off
        -- The createResultText will check show_debug_in_chat in the config
        -- We'll handle this by passing a modified config
        config_for_text = {}
        for k, v in pairs(temp_config or CONFIGURATION) do
            config_for_text[k] = v
        end
        config_for_text.features = {}
        for k, v in pairs((temp_config or CONFIGURATION).features or {}) do
            config_for_text.features[k] = v
        end
        config_for_text.features.show_debug_in_chat = false
    end
    local result_text = history:createResultText(highlightedText, config_for_text)
    local model_info = history:getModel() or ConfigHelper:getModelInfo(temp_config)

    -- Initialize chat history manager
    local chat_history_manager = ChatHistoryManager:new()

    -- Close existing chat viewer if any
    if _G.ActiveChatViewer then
        UIManager:close(_G.ActiveChatViewer)
        _G.ActiveChatViewer = nil
    end

    -- Forward declare for mutual reference
    local chatgpt_viewer
    local recreate_func

    -- Recreate function for rotation handling
    -- Takes state captured by ChatGPTViewer:captureState() and recreates the viewer
    recreate_func = function(state)
        -- Close existing viewer if any
        if _G.ActiveChatViewer then
            UIManager:close(_G.ActiveChatViewer)
            _G.ActiveChatViewer = nil
        end

        -- Create new viewer with captured state but new dimensions
        local new_viewer = ChatGPTViewer:new {
            title = state.title,
            text = state.text,
            configuration = state.configuration,
            render_markdown = state.render_markdown,
            show_debug_in_chat = state.show_debug_in_chat,
            -- Set BOTH property names for compatibility
            original_history = state.original_history,
            _message_history = state.original_history,
            original_highlighted_text = state.original_highlighted_text,
            reply_draft = state.reply_draft,
            selection_data = state.selection_data,  -- Preserve for "Save to Note" feature
            _plugin = state._plugin,  -- For text selection dictionary lookup
            _ui = state._ui,  -- For text selection dictionary lookup
            -- Callbacks from captured state
            onAskQuestion = state.onAskQuestion,
            save_callback = state.save_callback,
            export_callback = state.export_callback,
            tag_callback = state.tag_callback,
            pin_callback = state.pin_callback,
            star_callback = state.star_callback,
            get_pin_state = state.get_pin_state,
            get_star_state = state.get_star_state,
            settings_callback = state.settings_callback,
            update_debug_callback = state.update_debug_callback,
            -- Pass recreate function for subsequent rotations
            _recreate_func = recreate_func,
        }
        -- Set close_callback after creation so new_viewer is defined
        new_viewer.close_callback = function()
            if _G.ActiveChatViewer == new_viewer then
                _G.ActiveChatViewer = nil
            end
        end

        -- Set global reference
        _G.ActiveChatViewer = new_viewer

        -- Show the new viewer
        UIManager:show(new_viewer)

        -- Restore scroll position
        if state.scroll_ratio and state.scroll_ratio > 0 then
            new_viewer:restoreScrollPosition(state.scroll_ratio)
        end
    end

    -- Check if compact view should be used
    local use_compact_view = temp_config and temp_config.features and temp_config.features.compact_view
    -- Check if dictionary view should be used (full-size with dictionary buttons)
    local use_dictionary_view = temp_config and temp_config.features and temp_config.features.dictionary_view
    -- Check if minimal buttons should be used (for dictionary popup lookups)
    local use_minimal_buttons = temp_config and temp_config.features and temp_config.features.minimal_buttons
    -- Check if translate view should be used
    local use_translate_view = temp_config and temp_config.features and temp_config.features.translate_view
    local translate_hide_quote = temp_config and temp_config.features and temp_config.features.translate_hide_quote

    -- For translate view, use special text formatting
    local display_text = result_text
    if use_translate_view then
        display_text = history:createTranslateViewText(highlightedText, translate_hide_quote)
    end

    -- Debug info should NEVER show in compact/translate view
    -- regardless of the global setting
    local show_debug = false
    if not use_compact_view and not use_dictionary_view and not use_translate_view then
        show_debug = temp_config and temp_config.features and temp_config.features.show_debug_in_chat or false
    end

    -- Get selection data for "Save to Note" feature (only for highlight context)
    -- Must verify context is actually "highlight" to avoid stale data from previous operations
    local selection_data = nil
    local context = getPromptContext(temp_config)
    if context == "highlight" and temp_config and temp_config.features then
        selection_data = temp_config.features.selection_data
    end

    -- Ensure document_path is in configuration for export functionality
    -- This allows ChatGPTViewer to determine chat type (book/general/library)
    if temp_config and document_path then
        temp_config.document_path = document_path
    end

    -- Cache notice is now handled in MessageHistory:createResultText() so it persists through debug toggle

    -- Pin/Star helpers (closures shared by callbacks and state checkers)
    local pin_star_path = (function()
        local is_multi = temp_config and temp_config.features and temp_config.features.is_library_context
        if is_multi then return "__LIBRARY_CHATS__"
        elseif not document_path then return "__GENERAL_CHATS__"
        else return document_path end
    end)()

    -- Get last (most recent) AI response and the user prompt that preceded it
    local function getLastResponseAndPrompt()
        local msgs = history:getMessages()
        if not msgs then return "", "" end
        local last_response, last_prompt = "", ""
        for i = #msgs, 1, -1 do
            if msgs[i].role == "assistant" and msgs[i].content and last_response == "" then
                last_response = msgs[i].content
                -- Find the user prompt that preceded this response
                for j = i - 1, 1, -1 do
                    if msgs[j].role == "user" and not msgs[j].is_context then
                        last_prompt = msgs[j].content or ""
                        break
                    end
                end
                break
            end
        end
        return last_response, last_prompt
    end

    -- Check if last AI response is already pinned; returns (is_pinned, pin_id)
    local function getPinState()
        local last_response = getLastResponseAndPrompt()
        if last_response == "" then return false, nil end
        local ok_pm, PinnedManager = pcall(require, "koassistant_pinned_manager")
        if not ok_pm or not PinnedManager then return false, nil end
        local pinned = PinnedManager.getPinnedForDocument(pin_star_path)
        for _idx, pin in ipairs(pinned) do
            -- Strip trailing newline from loaded content (writeLongString legacy)
            local pin_result = pin.result or ""
            if pin_result:sub(-1) == "\n" then
                pin_result = pin_result:sub(1, -2)
            end
            if pin_result == last_response then
                return true, pin.id
            end
        end
        return false, nil
    end

    -- Check if chat is starred; returns is_starred
    local function getStarState()
        if not history.chat_id then return false end
        local chat = chat_history_manager:getChatById(pin_star_path, history.chat_id)
        return chat and chat.starred == true or false
    end

    chatgpt_viewer = ChatGPTViewer:new {
        title = title .. " (" .. model_info .. ")",
        text = display_text,
        configuration = temp_config or CONFIGURATION,  -- Pass configuration for debug toggle
        show_debug_in_chat = show_debug,
        compact_view = use_compact_view,  -- Use compact height for dictionary lookups
        dictionary_view = use_dictionary_view,  -- Full-size with dictionary buttons
        minimal_buttons = use_minimal_buttons,  -- Use minimal buttons for dictionary lookups
        translate_view = use_translate_view,  -- Use translate view for translations
        translate_hide_quote = translate_hide_quote,  -- Initial hide state for original text
        selection_data = selection_data,  -- For "Save to Note" feature
        -- Scroll to last question if setting enabled AND this is a follow-up response
        -- First response should always start from top (user needs to read it)
        scroll_to_last_question = (temp_config and temp_config.features and temp_config.features.scroll_to_last_message == true)
            and history and history.getAssistantTurnCount and history:getAssistantTurnCount() > 1,
        -- Set BOTH property names for compatibility:
        -- original_history: used by toggleDebugDisplay, toggleHighlightVisibility, etc.
        -- _message_history: used by expandToFullView for text regeneration
        original_history = history,
        _message_history = history,
        original_highlighted_text = highlightedText,
        _plugin = plugin,  -- For text selection dictionary lookup
        _ui = ui_instance,  -- For text selection dictionary lookup
        _recreate_func = recreate_func, -- For rotation handling
        settings_callback = function(path, value)
            -- Update plugin settings if plugin instance is available
            if plugin and plugin.settings then
                local parts = {}
                for part in path:gmatch("[^.]+") do
                    table.insert(parts, part)
                end
                
                -- Navigate to the setting and update it
                local setting = plugin.settings
                for i = 1, #parts - 1 do
                    setting = setting:readSetting(parts[i]) or {}
                end
                
                -- Update the final value
                if setting then
                    local existing = plugin.settings:readSetting(parts[1]) or {}
                    if #parts == 2 then
                        existing[parts[2]] = value
                    end
                    plugin.settings:saveSetting(parts[1], existing)
                    plugin.settings:flush()
                    
                    -- Also update configuration object
                    plugin:updateConfigFromSettings()

                    -- Update temp_config if it exists
                    if temp_config and temp_config.features and parts[1] == "features" and parts[2] == "show_debug_in_chat" then
                        temp_config.features.show_debug_in_chat = value
                    end
                end
            end
        end,
        update_debug_callback = function(enabled)
            -- Update debug display setting in history if available
            if history and history.show_debug_in_chat ~= nil then
                history.show_debug_in_chat = enabled
            end
        end,
        onAskQuestion = function(viewer, question)
            -- Use the viewer's configuration (which may have been updated by expand)
            -- This is critical for compact→full view transition to work correctly
            local cfg = viewer.configuration or temp_config or CONFIGURATION

            -- Apply session web search override if set on the viewer
            -- This allows per-query toggling of web search from the Reply dialog
            if viewer.session_web_search_override ~= nil then
                cfg.enable_web_search = viewer.session_web_search_override
            end

            -- Note: Loading dialog is now handled by handleNonStreamingBackground in gpt_query.lua
            -- which shows a cancellable dialog for non-streaming requests

            -- Function to update the viewer with new content
            local function updateViewer()
                -- Check if our global reference is still the same
                if _G.ActiveChatViewer == viewer then
                    -- Always close the existing viewer
                    UIManager:close(viewer)
                    _G.ActiveChatViewer = nil

                    -- Use viewer's configuration for replies (respects expand view changes)
                    local viewer_cfg = viewer.configuration or temp_config or CONFIGURATION

                    -- Create a new viewer with updated content
                    local new_viewer = ChatGPTViewer:new {
                        title = title .. " (" .. model_info .. ")",
                        text = history:createResultText(highlightedText, viewer_cfg),
                        configuration = viewer_cfg,  -- Use viewer's config to maintain state after expand
                        -- Scroll to last question if setting enabled AND this is a follow-up response
                        -- (This is for follow-up replies, so there should always be 2+ assistant messages here)
                        scroll_to_last_question = (viewer_cfg and viewer_cfg.features and viewer_cfg.features.scroll_to_last_message == true)
                            and history and history.getAssistantTurnCount and history:getAssistantTurnCount() > 1,
                        scroll_to_bottom = not ((viewer_cfg and viewer_cfg.features and viewer_cfg.features.scroll_to_last_message == true)
                            and history and history.getAssistantTurnCount and history:getAssistantTurnCount() > 1),
                        show_debug_in_chat = viewer.show_debug_in_chat,
                        -- Set BOTH property names for compatibility:
                        -- original_history: used by toggleDebugDisplay, toggleHighlightVisibility, etc.
                        -- _message_history: used by expandToFullView for text regeneration
                        original_history = history,
                        _message_history = history,
                        original_highlighted_text = highlightedText,
                        _plugin = viewer._plugin,  -- For text selection dictionary lookup
                        _ui = viewer._ui,  -- For text selection dictionary lookup
                        _recreate_func = recreate_func, -- For rotation handling
                        settings_callback = viewer.settings_callback,
                        update_debug_callback = viewer.update_debug_callback,
                        onAskQuestion = viewer.onAskQuestion,
                        save_callback = viewer.save_callback,
                        export_callback = viewer.export_callback,
                        tag_callback = viewer.tag_callback,
                        pin_callback = viewer.pin_callback,
                        star_callback = viewer.star_callback,
                        get_pin_state = viewer.get_pin_state,
                        get_star_state = viewer.get_star_state,
                        selection_data = viewer.selection_data,  -- Preserve for "Save to Note" feature
                        session_web_search_override = viewer.session_web_search_override,  -- Preserve session override
                    }
                    -- Set close_callback after creation so new_viewer is defined
                    new_viewer.close_callback = function()
                        if _G.ActiveChatViewer == new_viewer then
                            _G.ActiveChatViewer = nil
                        end
                    end

                    -- Set global reference to new viewer
                    _G.ActiveChatViewer = new_viewer

                    -- Show the new viewer
                    UIManager:show(new_viewer)
                end
            end

            -- Process the question with callback for streaming support
            -- IMPORTANT: Use viewer's cfg for the query, not the closure-captured temp_config
            -- This ensures expanded views use large_stream_dialog=true
            history:addUserMessage(question, false)
            queryChatGPT(history:getMessages(), cfg, function(success, answer, err, reasoning, web_search_used)
                if success and answer and answer ~= "" then
                    history:addAssistantMessage(answer, ConfigHelper:getModelInfo(cfg), reasoning, ConfigHelper:buildDebugInfo(cfg), web_search_used)

                    -- Determine if auto-save should apply:
                    -- auto_save_all_chats = always, OR auto_save_chats + chat already saved once
                    local should_auto_save = cfg.features and (
                        cfg.features.auto_save_all_chats or
                        (cfg.features.auto_save_chats ~= false and cfg.features.chat_saved)
                    )

                    -- Clear expanded_from_skip BEFORE recreating viewer, so new viewer
                    -- renders "Autosaved" (disabled) once auto-save will handle it
                    if cfg.features and cfg.features.expanded_from_skip and should_auto_save then
                        cfg.features.expanded_from_skip = nil
                    end

                    updateViewer()

                    -- Warn once if conversation context is getting large
                    if history:getAssistantTurnCount() > 1
                        and not history._context_warning_shown then
                        local system_text = cfg.system and cfg.system.text or ""
                        local token_estimate = history:estimateTokens(system_text)
                        if token_estimate > 50000 then
                            history._context_warning_shown = true
                            local token_k = math.floor(token_estimate / 1000)
                            UIManager:show(InfoMessage:new{
                                text = T(_("This conversation is using approximately %1K tokens. Each follow-up resends the full history. Consider starting a new chat to reduce costs and maintain quality."), token_k),
                            })
                        end
                    end

                    -- Auto-save after each follow-up message if enabled
                    if should_auto_save then
                        local is_general_context = cfg.features.is_general_context or false
                        local suggested_title = history:getSuggestedTitle()

                        local metadata = {}
                        if history.chat_id then
                            metadata.id = history.chat_id
                        end
                        if book_metadata then
                            metadata.book_title = book_metadata.title
                            metadata.book_author = book_metadata.author
                        end
                        if launch_context then
                            metadata.launch_context = launch_context
                        end
                        if history.domain then
                            metadata.domain = history.domain
                        end
                        -- Store highlighted text for display toggle in continued chats
                        if highlightedText and highlightedText ~= "" then
                            metadata.original_highlighted_text = highlightedText
                        end
                        -- Store books_info for library context
                        if cfg.features.is_library_context and cfg.features.books_info then
                            metadata.books_info = cfg.features.books_info
                        end

                        -- Determine save path: check for action storage_key override
                        local storage_key = cfg.features and cfg.features.storage_key
                        local save_path
                        local should_save = true
                        local is_library = cfg.features.is_library_context or false

                        if storage_key == "__SKIP__" then
                            -- Don't save this chat
                            should_save = false
                            logger.info("KOAssistant: Skipping auto-save due to storage_key = __SKIP__")
                        elseif storage_key then
                            -- Use custom storage location
                            save_path = storage_key
                        else
                            -- Default: document path, general chats, or library chats
                            save_path = document_path
                                or (is_general_context and "__GENERAL_CHATS__")
                                or (is_library and "__LIBRARY_CHATS__")
                                or nil
                        end

                        if not should_save then
                            -- Skip saving, but still consider it successful
                            logger.info("KOAssistant: Chat not saved (storage_key = __SKIP__)")
                        else
                            local save_result
                            -- Check storage version and route to appropriate method
                            if chat_history_manager:useDocSettingsStorage() then
                                -- v2: DocSettings-based storage
                                local chat_id = metadata.id or history.chat_id or chat_history_manager:generateChatId()

                                -- Preserve existing tags, starred, and title when updating an existing chat
                                local existing_tags = {}
                                local existing_starred
                                local existing_title = suggested_title
                                local effective_chat_id = metadata.id or history.chat_id
                                if effective_chat_id and save_path then
                                    local existing = chat_history_manager:getChatById(save_path, effective_chat_id)
                                    if existing then
                                        existing_tags = existing.tags or {}
                                        existing_starred = existing.starred
                                        existing_title = existing.title or suggested_title
                                    end
                                end

                                local chat_data = {
                                    id = chat_id,
                                    title = existing_title or "Conversation",
                                    document_path = save_path,
                                    timestamp = os.time(),
                                    messages = history:getMessages(),
                                    model = history:getModel(),
                                    metadata = metadata,
                                    book_title = metadata.book_title,
                                    book_author = metadata.book_author,
                                    prompt_action = history.prompt_action,
                                    launch_context = metadata.launch_context,
                                    domain = metadata.domain,
                                    tags = existing_tags,
                                    starred = existing_starred,
                                    original_highlighted_text = metadata.original_highlighted_text,
                                    -- Store system prompt metadata for debug display
                                    system_metadata = cfg.system,
                                    -- Store cache continuation info (for "Updated from X% cache" notice)
                                    used_cache = history.used_cache,
                                    cached_progress = history.cached_progress,
                                    cache_action_id = history.cache_action_id,
                                    -- Store book text truncation info
                                    book_text_truncated = history.book_text_truncated,
                                    book_text_coverage_start = history.book_text_coverage_start,
                                    book_text_coverage_end = history.book_text_coverage_end,
                                    -- Store unavailable data info
                                    unavailable_data = history.unavailable_data,
                                }

                                if save_path == "__GENERAL_CHATS__" then
                                    save_result = chat_history_manager:saveGeneralChat(chat_data)
                                elseif save_path == "__LIBRARY_CHATS__" then
                                    save_result = chat_history_manager:saveLibraryChat(chat_data)
                                else
                                    save_result = chat_history_manager:saveChatToDocSettings(ui_instance, chat_data)
                                end
                            else
                                -- v1: Legacy hash-based storage
                                save_result = chat_history_manager:saveChat(
                                    save_path,
                                    suggested_title,
                                    history,
                                    metadata
                                )
                            end

                            if save_result and save_result ~= false then
                                -- Store the chat ID in history for future saves (prevents duplicates)
                                if not history.chat_id then
                                    history.chat_id = save_result
                                end
                                -- Mark chat as saved so auto_save_chats applies to future replies
                                if cfg.features then
                                    cfg.features.chat_saved = true
                                end
                                logger.info("KOAssistant: Auto-saved chat after follow-up with id: " .. tostring(save_result))
                            else
                                logger.warn("KOAssistant: Failed to auto-save chat after follow-up")
                            end
                        end
                    end
                else
                    closeLoadingDialog()
                    UIManager:show(InfoMessage:new{
                        text = _("Failed to get response: ") .. (err or "Unknown error"),
                        timeout = 2,
                    })
                end
            end, plugin and plugin.settings)

            -- For non-streaming, the callback was already called, viewer will be updated
        end,
        save_callback = function()
            -- Must check the ACTIVE viewer's config, not temp_config, because expandToFullView
            -- creates a new config with expanded_from_skip that temp_config doesn't have
            local viewer = _G.ActiveChatViewer
            local viewer_features = viewer and viewer.configuration and viewer.configuration.features
            local expanded_from_skip = viewer_features and viewer_features.expanded_from_skip

            if expanded_from_skip or history.chat_id then
                -- Save directly without dialog:
                -- - expanded-from-skip: document path is known from expand
                -- - chat already has ID: was saved before, just update it
                local suggested_title = history:getSuggestedTitle()
                local metadata = {}
                if history.chat_id then
                    metadata.id = history.chat_id
                end
                if book_metadata then
                    metadata.book_title = book_metadata.title
                    metadata.book_author = book_metadata.author
                end
                if launch_context then
                    metadata.launch_context = launch_context
                end
                if history.domain then
                    metadata.domain = history.domain
                end
                if highlightedText and highlightedText ~= "" then
                    metadata.original_highlighted_text = highlightedText
                end
                local save_path = document_path or "__GENERAL_CHATS__"
                -- Get config from viewer for system metadata
                local viewer_config = viewer and viewer.configuration
                local success, save_result = pcall(function()
                    -- Check storage version and route to appropriate method
                    if chat_history_manager:useDocSettingsStorage() then
                        -- v2: DocSettings-based storage
                        local chat_id = metadata.id or history.chat_id or chat_history_manager:generateChatId()

                        -- Preserve existing tags, starred, and title when updating an existing chat
                        local existing_tags = {}
                        local existing_starred
                        local existing_title = suggested_title
                        local effective_chat_id = metadata.id or history.chat_id
                        if effective_chat_id then
                            local existing = chat_history_manager:getChatById(save_path, effective_chat_id)
                            if existing then
                                existing_tags = existing.tags or {}
                                existing_starred = existing.starred
                                existing_title = existing.title or suggested_title
                            end
                        end

                        local chat_data = {
                            id = chat_id,
                            title = existing_title or "Conversation",
                            document_path = save_path,
                            timestamp = os.time(),
                            messages = history:getMessages(),
                            model = history:getModel(),
                            metadata = metadata,
                            book_title = metadata.book_title,
                            book_author = metadata.book_author,
                            prompt_action = history.prompt_action,
                            launch_context = metadata.launch_context,
                            domain = metadata.domain,
                            tags = existing_tags,
                            starred = existing_starred,
                            original_highlighted_text = metadata.original_highlighted_text,
                            -- Store system prompt metadata for debug display
                            system_metadata = viewer_config and viewer_config.system,
                            -- Store cache continuation info (for "Updated from X% cache" notice)
                            used_cache = history.used_cache,
                            cached_progress = history.cached_progress,
                            cache_action_id = history.cache_action_id,
                            -- Store book text truncation info
                            book_text_truncated = history.book_text_truncated,
                            book_text_coverage_start = history.book_text_coverage_start,
                            book_text_coverage_end = history.book_text_coverage_end,
                            -- Store unavailable data info
                            unavailable_data = history.unavailable_data,
                        }

                        if save_path == "__GENERAL_CHATS__" then
                            return chat_history_manager:saveGeneralChat(chat_data)
                        else
                            return chat_history_manager:saveChatToDocSettings(ui_instance, chat_data)
                        end
                    else
                        -- v1: Legacy hash-based storage
                        return chat_history_manager:saveChat(save_path, suggested_title, history, metadata)
                    end
                end)
                if success and save_result then
                    if not history.chat_id then
                        history.chat_id = save_result
                    end
                    -- Mark as saved so auto_save_chats applies to future replies
                    if viewer_features then
                        viewer_features.chat_saved = true
                        if expanded_from_skip then
                            viewer_features.expanded_from_skip = nil
                        end
                    end
                    -- Button text: "Autosaved" if auto-save will handle future replies, else "Saved"
                    local will_auto_save = viewer_features and (
                        viewer_features.auto_save_all_chats or
                        viewer_features.auto_save_chats ~= false
                    )
                    local button_text = will_auto_save and _("Autosaved") or _("Saved")
                    local save_button = viewer.button_table and viewer.button_table:getButtonById("save_chat")
                    if save_button then
                        save_button:setText(button_text, save_button.width)
                        save_button:disable()
                        UIManager:setDirty(viewer, function()
                            return "ui", save_button.dimen
                        end)
                    end
                else
                    UIManager:show(InfoMessage:new{
                        text = _("Failed to save chat"),
                        timeout = 2,
                    })
                end
            elseif temp_config and temp_config.features and temp_config.features.auto_save_all_chats then
                UIManager:show(InfoMessage:new{
                    text = T("Auto-save all chats is on - this can be changed in the settings"),
                    timeout = 3,
                })
            else
                -- First-time manual save with dialog (no chat_id yet)
                local is_general_context = temp_config and temp_config.features and temp_config.features.is_general_context or false
                createSaveDialog(document_path, history, chat_history_manager, is_general_context, book_metadata, launch_context, highlightedText, ui_instance, temp_config)
            end
        end,
        export_callback = function()
            -- Copy chat using user's export settings
            local Device = require("device")
            local Notification = require("ui/widget/notification")
            local features = temp_config and temp_config.features or {}
            local content = features.copy_content or "full"
            local style = features.export_style or "markdown"

            -- Helper to perform the copy
            local function doCopy(selected_content)
                local Export = require("koassistant_export")
                -- Extract books_info for library context
                local books_info = features.is_library_context and features.books_info or nil
                local data = Export.fromHistory(history, highlightedText, book_metadata, books_info)
                local text = Export.format(data, selected_content, style)

                if text then
                    Device.input.setClipboardText(text)
                    UIManager:show(Notification:new{
                        text = _("Copied"),
                        timeout = 2,
                    })
                end
            end

            if content == "ask" then
                -- Show content picker dialog
                local content_dialog
                local options = {
                    { value = "full", label = _("Full (metadata + chat)") },
                    { value = "qa", label = _("Question + Response") },
                    { value = "response", label = _("Response only") },
                    { value = "everything", label = _("Everything (debug)") },
                }

                local buttons = {}
                for _idx, opt in ipairs(options) do
                    table.insert(buttons, {
                        {
                            text = opt.label,
                            callback = function()
                                UIManager:close(content_dialog)
                                doCopy(opt.value)
                            end,
                        },
                    })
                end
                table.insert(buttons, {
                    {
                        text = _("Cancel"),
                        callback = function()
                            UIManager:close(content_dialog)
                        end,
                    },
                })

                content_dialog = ButtonDialog:new{
                    title = _("Copy Content"),
                    buttons = buttons,
                }
                UIManager:show(content_dialog)
            else
                doCopy(content)
            end
        end,
        tag_callback = function()
            local Notification = require("ui/widget/notification")
            -- If chat not saved yet, force-save first
            if not history.chat_id then
                local viewer = _G.ActiveChatViewer
                if viewer and viewer.save_callback then
                    viewer.save_callback()
                end
                if not history.chat_id then
                    UIManager:show(Notification:new{
                        text = _("Save the chat first to add tags"),
                        timeout = 2,
                    })
                    return
                end
            end

            -- Show tag management dialog for this chat
            local chat_id = history.chat_id

            -- Get effective document path
            local effective_path = document_path
            if not effective_path then
                local is_general = temp_config and temp_config.features and temp_config.features.is_general_context
                if is_general then
                    effective_path = "__GENERAL_CHATS__"
                else
                    UIManager:show(InfoMessage:new{
                        text = _("Cannot tag: no document context"),
                        timeout = 2,
                    })
                    return
                end
            end

            showTagsMenu(effective_path, chat_id, chat_history_manager)
        end,
        get_pin_state = getPinState,
        get_star_state = getStarState,
        pin_callback = function()
            local Notification = require("ui/widget/notification")
            local last_response, last_prompt = getLastResponseAndPrompt()
            if last_response == "" then
                UIManager:show(Notification:new{
                    text = _("No response to pin"),
                    timeout = 2,
                })
                return
            end

            local PinnedManager = require("koassistant_pinned_manager")
            local is_pinned, existing_pin_id = getPinState()

            if is_pinned then
                -- Unpin
                if PinnedManager.removePin(pin_star_path, existing_pin_id) then
                    UIManager:show(Notification:new{
                        text = _("Unpinned from Artifacts"),
                        timeout = 2,
                    })
                end
            else
                -- Pin last AI response — show naming dialog
                local default_name = history:getPinTitle() or ""

                local pin_name_dialog
                pin_name_dialog = InputDialog:new{
                    title = _("Pin as Artifact"),
                    input = default_name,
                    input_hint = _("Enter a name for this artifact"),
                    buttons = {
                        {
                            {
                                text = _("Cancel"),
                                id = "close",
                                callback = function()
                                    UIManager:close(pin_name_dialog)
                                end,
                            },
                            {
                                text = _("Pin"),
                                is_enter_default = true,
                                callback = function()
                                    local pin_name = pin_name_dialog:getInputText()
                                    if not pin_name or pin_name == "" then
                                        UIManager:show(require("ui/widget/infomessage"):new{
                                            text = _("Please enter a name."),
                                            timeout = 2,
                                        })
                                        return
                                    end
                                    if #pin_name > 80 then pin_name = pin_name:sub(1, 80) end
                                    UIManager:close(pin_name_dialog)

                                    local is_multi = temp_config and temp_config.features and temp_config.features.is_library_context
                                    local pin_entry = {
                                        id = PinnedManager.generateId(),
                                        name = pin_name,
                                        action_id = history.prompt_action or "chat",
                                        action_text = history.prompt_action or _("Chat"),
                                        result = last_response,
                                        user_prompt = last_prompt,
                                        timestamp = os.time(),
                                        model = history:getModel() or "",
                                        context_type = is_multi and "library" or (document_path and "book" or "general"),
                                        book_title = book_metadata and book_metadata.title,
                                        book_author = book_metadata and book_metadata.author,
                                        document_path = pin_star_path,
                                    }

                                    if PinnedManager.addPin(pin_star_path, pin_entry) then
                                        UIManager:show(Notification:new{
                                            text = _("Pinned to Artifacts"),
                                            timeout = 2,
                                        })
                                    else
                                        UIManager:show(Notification:new{
                                            text = _("Failed to pin"),
                                            timeout = 2,
                                        })
                                    end
                                end,
                            },
                        },
                    },
                }
                UIManager:show(pin_name_dialog)
                pin_name_dialog:onShowKeyboard()
            end
        end,
        star_callback = function()
            local Notification = require("ui/widget/notification")
            -- If chat not saved yet, force-save first
            if not history.chat_id then
                local viewer = _G.ActiveChatViewer
                if viewer and viewer.save_callback then
                    viewer.save_callback()
                end
                if not history.chat_id then
                    UIManager:show(Notification:new{
                        text = _("Save the chat first to star it"),
                        timeout = 2,
                    })
                    return
                end
            end

            local is_starred = getStarState()
            if is_starred then
                chat_history_manager:unstarChat(pin_star_path, history.chat_id)
                UIManager:show(Notification:new{
                    text = _("Chat unstarred"),
                    timeout = 2,
                })
            else
                chat_history_manager:starChat(pin_star_path, history.chat_id)
                UIManager:show(Notification:new{
                    text = _("Chat starred"),
                    timeout = 2,
                })
            end
        end,
        close_callback = function()
            if _G.ActiveChatViewer == chatgpt_viewer then
                _G.ActiveChatViewer = nil
            end
        end
    }
    
    -- Set global reference
    _G.ActiveChatViewer = chatgpt_viewer
    
    -- Show the viewer
    UIManager:show(chatgpt_viewer)

    -- Auto-save if enabled
    if temp_config and temp_config.features and temp_config.features.auto_save_all_chats then
        -- Schedule auto-save to run after viewer is displayed
        UIManager:scheduleIn(0.1, function()
            local is_general_context = temp_config.features.is_general_context or false
            local suggested_title = history:getSuggestedTitle()

            -- Create metadata for saving
            local metadata = {}
            if history.chat_id then
                metadata.id = history.chat_id
            end
            if book_metadata then
                metadata.book_title = book_metadata.title
                metadata.book_author = book_metadata.author
            end
            if launch_context then
                metadata.launch_context = launch_context
            end
            if history.domain then
                metadata.domain = history.domain
            end
            -- Store highlighted text for display toggle in continued chats
            if highlightedText and highlightedText ~= "" then
                metadata.original_highlighted_text = highlightedText
            end
            -- Store books_info for library context
            if temp_config.features.is_library_context and temp_config.features.books_info then
                metadata.books_info = temp_config.features.books_info
            end

            -- Determine save path: check for action storage_key override
            local storage_key = temp_config.features and temp_config.features.storage_key
            local save_path
            local should_save = true
            local is_library = temp_config.features.is_library_context or false

            if storage_key == "__SKIP__" then
                -- Don't save this chat
                should_save = false
                logger.info("KOAssistant: Skipping auto-save due to storage_key = __SKIP__")
            elseif storage_key then
                -- Use custom storage location
                save_path = storage_key
            else
                -- Default: document path, general chats, or library chats
                save_path = document_path
                    or (is_general_context and "__GENERAL_CHATS__")
                    or (is_library and "__LIBRARY_CHATS__")
                    or nil
            end

            if should_save then
                local result
                -- Check storage version and route to appropriate method
                if chat_history_manager:useDocSettingsStorage() then
                    -- v2: DocSettings-based storage
                    local chat_id = metadata.id or history.chat_id or chat_history_manager:generateChatId()

                    -- Preserve existing tags, starred, and title when updating an existing chat
                    local existing_tags = {}
                    local existing_starred
                    local existing_title = suggested_title
                    local effective_chat_id = metadata.id or history.chat_id
                    if effective_chat_id and save_path then
                        local existing = chat_history_manager:getChatById(save_path, effective_chat_id)
                        if existing then
                            existing_tags = existing.tags or {}
                            existing_starred = existing.starred
                            existing_title = existing.title or suggested_title
                        end
                    end

                    local chat_data = {
                        id = chat_id,
                        title = existing_title or "Conversation",
                        document_path = save_path,
                        timestamp = os.time(),
                        messages = history:getMessages(),
                        model = history:getModel(),
                        metadata = metadata,
                        book_title = metadata.book_title,
                        book_author = metadata.book_author,
                        prompt_action = history.prompt_action,
                        launch_context = metadata.launch_context,
                        domain = metadata.domain,
                        tags = existing_tags,
                        starred = existing_starred,
                        original_highlighted_text = metadata.original_highlighted_text,
                        -- Store system prompt metadata for debug display
                        system_metadata = temp_config.system,
                        -- Store cache continuation info (for "Updated from X% cache" notice)
                        used_cache = history.used_cache,
                        cached_progress = history.cached_progress,
                        cache_action_id = history.cache_action_id,
                        -- Store book text truncation info
                        book_text_truncated = history.book_text_truncated,
                        book_text_coverage_start = history.book_text_coverage_start,
                        book_text_coverage_end = history.book_text_coverage_end,
                        -- Store unavailable data info
                        unavailable_data = history.unavailable_data,
                    }

                    if save_path == "__GENERAL_CHATS__" then
                        result = chat_history_manager:saveGeneralChat(chat_data)
                    elseif save_path == "__LIBRARY_CHATS__" then
                        result = chat_history_manager:saveLibraryChat(chat_data)
                    else
                        result = chat_history_manager:saveChatToDocSettings(ui_instance, chat_data)
                    end
                else
                    -- v1: Legacy hash-based storage
                    result = chat_history_manager:saveChat(
                        save_path,
                        suggested_title,
                        history,
                        metadata
                    )
                end

                if result and result ~= false then
                    -- Store the chat ID in history for future saves (prevents duplicates)
                    if not history.chat_id then
                        history.chat_id = result
                    end
                    -- Mark as saved so auto_save_chats applies to future replies
                    temp_config.features.chat_saved = true
                    logger.info("KOAssistant: Auto-saved chat with id: " .. tostring(result) .. ", title: " .. suggested_title)
                else
                    logger.warn("KOAssistant: Failed to auto-save chat")
                end
            else
                logger.info("KOAssistant: Chat not saved (storage_key = __SKIP__)")
            end
        end)
    end
end

-- Helper function to build consolidated messages
-- Delegates to shared MessageBuilder module for consistency with test framework
-- @param prompt: The prompt definition
-- @param context: The context type (highlight, book, library, general)
-- @param data: Context-specific data (highlighted_text, book_metadata, etc.)
-- @param system_prompt: Optional system prompt override
-- @param domain_context: Optional domain context text to prepend
-- @param using_new_format: If true, skip domain/system (they go in system array instead)
local function buildConsolidatedMessage(prompt, context, data, system_prompt, domain_context, using_new_format)
    return MessageBuilder.build({
        prompt = prompt,
        context = context,
        data = data,
        system_prompt = system_prompt,
        domain_context = domain_context,
        using_new_format = using_new_format,
    })
end

-- Forward declaration (assigned as function expression below)
local handlePredefinedPrompt

--- Handle a predefined prompt query
--- @param prompt_type_or_action string|table: The prompt type string ID or action object
--- @param highlightedText string: The highlighted text (optional)
--- @param ui table: The UI instance
--- @param configuration table: The configuration table
--- @param existing_history table: Existing message history (unused, for compatibility)
--- @param plugin table: The plugin instance
--- @param additional_input string: Additional user input (optional)
--- @param on_complete function: Optional callback for async streaming - receives (history, temp_config) or (nil, error_string)
--- @param book_metadata table: Optional book metadata {title, author} - used when ui.document is not available
--- @return history, temp_config when not streaming; nil when streaming (result comes via callback)
handlePredefinedPrompt = function(prompt_type_or_action, highlightedText, ui, configuration, existing_history, plugin, additional_input, on_complete, book_metadata)
    -- Use passed configuration or fall back to global
    local config = configuration or CONFIGURATION

    -- Support both action object and prompt_type string
    -- This allows executeDirectAction to pass special actions (like translate) directly
    -- without requiring them to be in the ActionService cache
    local prompt
    if type(prompt_type_or_action) == "table" then
        -- Action object passed directly - use it
        prompt = prompt_type_or_action
    else
        -- String ID - look it up from ActionService
        local prompts, _ = getAllPrompts(config, plugin)
        prompt = prompts[prompt_type_or_action]
        if not prompt then
            local err = "Prompt '" .. prompt_type_or_action .. "' not found"
            if on_complete then
                on_complete(nil, err)
                return nil
            end
            return nil, err
        end
    end

    -- Create a temporary configuration using the passed config as base
    local temp_config = createTempConfig(prompt, config)
    if prompt.provider then
        if not temp_config.provider_settings[prompt.provider] then
            temp_config.provider_settings[prompt.provider] = {}
        end
        temp_config.provider_settings[prompt.provider].model = prompt.model
        -- Set both provider and model at top level so they take precedence
        temp_config.provider = prompt.provider
        temp_config.model = prompt.model
    end

    -- Apply translate view settings if action has translate_view flag
    if prompt.translate_view then
        temp_config.features = temp_config.features or {}
        temp_config.features.translate_view = true

        -- Apply translate-specific settings from user preferences
        local f = config.features or {}

        -- Disable auto-save by default (like dictionary)
        if f.translate_disable_auto_save ~= false then
            temp_config.features.storage_key = "__SKIP__"
        end

        -- Streaming setting (defaults to enabled)
        if f.translate_enable_streaming == false then
            temp_config.features.enable_streaming = false
        end

        -- Determine initial hide state for original text
        -- Apply user's translate_hide_highlight_mode setting (default: hide_long per schema)
        local hide_mode = f.translate_hide_highlight_mode or "hide_long"
        local is_full_page = temp_config.features.is_full_page_translate

        if hide_mode == "always_hide" then
            temp_config.features.translate_hide_quote = true
        elseif hide_mode == "hide_long" then
            local threshold = f.translate_long_highlight_threshold or 200
            local text_length = highlightedText and #highlightedText or 0
            temp_config.features.translate_hide_quote = (text_length > threshold)
        elseif hide_mode == "follow_global" then
            -- Replicate global hide logic: hide_highlighted_text OR (hide_long_highlights AND over threshold)
            local text_length = highlightedText and #highlightedText or 0
            local global_threshold = f.long_highlight_threshold or 280
            temp_config.features.translate_hide_quote = f.hide_highlighted_text or
                (f.hide_long_highlights and text_length > global_threshold)
        elseif hide_mode == "never_hide" then
            temp_config.features.translate_hide_quote = false
        end

        -- Full page translate override: checkbox is the ultimate override when checked
        -- This ONLY affects full page translations, not regular highlight translations
        if is_full_page and f.translate_hide_full_page == true then
            temp_config.features.translate_hide_quote = true
        end
    end

    -- Apply dictionary view settings (shared between compact and dictionary views)
    if prompt.compact_view or prompt.dictionary_view then
        temp_config.features = temp_config.features or {}
        if prompt.compact_view then
            temp_config.features.compact_view = true
            temp_config.features.large_stream_dialog = false  -- Small streaming dialog for compact
        end
        if prompt.dictionary_view then
            temp_config.features.dictionary_view = true
        end
        temp_config.features.hide_highlighted_text = true  -- Hide quote by default in dictionary modes

        -- Apply dictionary-specific settings from user preferences
        local f = config.features or {}

        -- Disable auto-save by default
        if f.dictionary_disable_auto_save ~= false then
            temp_config.features.storage_key = "__SKIP__"
        end

        -- Streaming setting (defaults to enabled)
        if f.dictionary_enable_streaming == false then
            temp_config.features.enable_streaming = false
        end
    end

    -- Apply minimal buttons if action has minimal_buttons flag
    if prompt.minimal_buttons then
        temp_config.features = temp_config.features or {}
        temp_config.features.minimal_buttons = true
    end

    -- Propagate action-level storage_key to config features (e.g., "__SKIP__" for X-Ray)
    if prompt.storage_key then
        temp_config.features = temp_config.features or {}
        temp_config.features.storage_key = prompt.storage_key
    end

    -- NEW ARCHITECTURE (v0.5.2+): Unified request config for all providers
    -- System prompt is built by buildUnifiedRequestConfig and passed in config.system
    -- No longer embedded in the consolidated message

    -- Create history WITHOUT system prompt (we'll include it in the consolidated message)
    -- Pass prompt text for better chat naming
    local history = MessageHistory:new(nil, prompt.text)

    -- Store source data for title generation (avoids fragile regex on message content)
    -- Skip for book-level actions where highlightedText is synthetic book metadata (Title: X. Author: Y.)
    local is_book_level = config.features and config.features._is_book_level_action
    if highlightedText and highlightedText ~= "" and not is_book_level then
        history.source_highlight = highlightedText
    end
    -- For book-level actions with section scope, use section label for chat naming
    if is_book_level then
        local section_scope = config.features and (config.features._section_scope or config.features._section_xray)
        if section_scope and section_scope.label then
            history.source_highlight = section_scope.label
        end
    end
    if additional_input and additional_input ~= "" then
        history.source_input = additional_input
    end

    -- Determine context
    local context = getPromptContext(config)

    -- Resolve effective translation language (uses SystemPrompts for consistency)
    local SystemPrompts = require("prompts.system_prompts")
    local effective_translation_language = SystemPrompts.getEffectiveTranslationLanguage({
        translation_use_primary = config.features.translation_use_primary,
        interaction_languages = config.features.interaction_languages,
        user_languages = config.features.user_languages,
        primary_language = config.features.primary_language,
        translation_language = config.features.translation_language,
    })

    -- Resolve effective dictionary language (for dictionary action)
    local effective_dictionary_language = SystemPrompts.getEffectiveDictionaryLanguage({
        dictionary_language = config.features.dictionary_language,
        translation_use_primary = config.features.translation_use_primary,
        interaction_languages = config.features.interaction_languages,
        user_languages = config.features.user_languages,
        primary_language = config.features.primary_language,
        translation_language = config.features.translation_language,
    })
    -- Store resolved languages back to temp_config for viewer's RTL detection
    -- (temp_config.features is a separate copy from config.features)
    temp_config.features.dictionary_language = effective_dictionary_language
    temp_config.features.translation_language = effective_translation_language

    -- Build data for consolidated message
    logger.info("KOAssistant: buildConsolidatedMessage - highlightedText:", highlightedText and #highlightedText or "nil/empty")
    logger.info("KOAssistant: config.features.book_metadata=", config.features and config.features.book_metadata and "present" or "nil")
    if config.features and config.features.book_metadata then
        logger.info("KOAssistant: book_metadata.title=", config.features.book_metadata.title or "nil")
    end
    -- Consume X-Ray context prefix (transient flag set by action buttons from chatAboutItem)
    local xray_prefix = config.features and config.features._xray_context_prefix
    if config.features then config.features._xray_context_prefix = nil end

    local message_data = {
        highlighted_text = highlightedText,
        additional_input = additional_input,
        book_metadata = config.features.book_metadata,
        books_info = config.features.books_info,
        book_context = config.features.book_context,
        translation_language = effective_translation_language,
        dictionary_language = effective_dictionary_language,
        -- Context from dictionary hook (surrounding text)
        context = config.features.dictionary_context or "",
        dictionary_context_mode = config.features.dictionary_context_mode,
        -- X-Ray context prefix (injected before action prompt in message builder)
        request_prefix = xray_prefix,
    }
    logger.info("KOAssistant: message_data.book_metadata=", message_data.book_metadata and "present" or "nil")

    -- Add book info for highlight context when:
    -- 1. include_book_context is enabled for the prompt, OR
    -- 2. The prompt uses template variables that require book info
    -- Try to get from ui.document first, then fall back to passed book_metadata
    if context == "highlight" then
        local should_include_book = prompt.include_book_context

        -- Also include if prompt uses book-related placeholders
        local prompt_text = prompt.prompt
        if not should_include_book and prompt_text then
            should_include_book = prompt_text:find("{title}") or
                                  prompt_text:find("{author}") or
                                  prompt_text:find("{author_clause}")
        end

        if should_include_book then
            -- Try KOReader's merged props first (includes user edits from Book Info dialog)
            if ui and ui.doc_props then
                message_data.book_title = ui.doc_props.display_title or ui.doc_props.title
                local raw_author = ui.doc_props.authors
                if raw_author and raw_author:find("\n") then
                    raw_author = raw_author:gsub("\n", ", ")
                end
                message_data.book_author = raw_author
            end
            -- Fall back to passed book_metadata if not available
            if not message_data.book_title and book_metadata then
                message_data.book_title = book_metadata.title
                message_data.book_author = book_metadata.author
            end
            -- Pass DOI clause from book metadata (for {doi_clause} placeholder)
            if book_metadata and book_metadata.doi_clause then
                message_data.doi_clause = book_metadata.doi_clause
            end
        end

        -- Extract surrounding context for dictionary action if not already provided
        -- Check both string ID and action object ID
        local action_id = type(prompt_type_or_action) == "table" and prompt_type_or_action.id or prompt_type_or_action
        if action_id == "dictionary" and (not message_data.context or message_data.context == "") then
            local context_mode = config.features.dictionary_context_mode or "sentence"
            local context_chars = config.features.dictionary_context_chars or 100
            message_data.context = extractSurroundingContext(ui, highlightedText, context_mode, context_chars)
        end

        -- Extract surrounding context for any action with use_surrounding_context flag
        if prompt.use_surrounding_context then
            if config.features._forced_surrounding_context then
                message_data.surrounding_context = config.features._forced_surrounding_context
            else
                local context_mode = prompt.context_mode or config.features.dictionary_context_mode or "sentence"
                local context_chars = prompt.context_chars or config.features.dictionary_context_chars or 100
                message_data.surrounding_context = extractSurroundingContext(ui, highlightedText, context_mode, context_chars)
            end
        end
    end

    -- For book context, ensure book_metadata is populated
    -- This provides a fallback when config.features.book_metadata isn't set
    if context == "book" or context == "file_browser" then
        if not message_data.book_metadata and ui and ui.doc_props then
            local props = ui.doc_props
            local title = props.display_title or props.title or "Unknown"
            local authors = props.authors or ""
            if authors:find("\n") then
                authors = authors:gsub("\n", ", ")
            end
            message_data.book_metadata = {
                title = title,
                author = authors,
                author_clause = (authors ~= "") and (" by " .. authors) or "",
            }
            logger.info("KOAssistant: book_metadata populated from ui.doc_props for book context")
        end
    end

    -- DOI detected: swap to academic prompt track (if available)
    -- Must happen BEFORE full-document swap so doi_complete_prompt is available
    local doi_metadata = config.features and config.features.book_metadata
    if doi_metadata and doi_metadata.doi and prompt and prompt.doi_prompt then
        local original_prompt = prompt
        prompt = {}
        for k, v in pairs(original_prompt) do prompt[k] = v end
        prompt.prompt = original_prompt.doi_prompt
        if original_prompt.doi_complete_prompt then
            prompt.complete_prompt = original_prompt.doi_complete_prompt
        end
        if original_prompt.doi_update_prompt then
            prompt.update_prompt = original_prompt.doi_update_prompt
        end
    end

    -- Full-document X-Ray: use complete_prompt (different schema, no spoiler restrictions)
    -- Must happen BEFORE extractForAction() so placeholder detection picks {full_document_section}
    if config.features and config.features._full_document_xray and prompt and prompt.complete_prompt then
        local original_prompt = prompt
        prompt = {}
        for k, v in pairs(original_prompt) do
            prompt[k] = v
        end
        prompt.prompt = original_prompt.complete_prompt
    end

    -- Source mode: skip expensive text extraction when user chose summary or AI knowledge
    -- Also propagate _source_mode to message_data for {document_context_section} resolution
    -- Capture and clear transient flags to prevent leaking across invocations
    local source_mode = config.features and config.features._source_mode
    local highlight_section = config.features and config.features._highlight_section_scope
    if config.features then
        config.features._source_mode = nil
        config.features._highlight_section_scope = nil
    end

    -- Source mode: skip extraction for non-selected sources
    -- Also propagate _source_mode to message_data for {document_context_section} resolution
    if source_mode then
        message_data._source_mode = source_mode
        if source_mode ~= "full_text" then
            -- Summary or AI knowledge: skip text extraction
            if not prompt._is_copy then
                local original_prompt = prompt
                prompt = {}
                for k, v in pairs(original_prompt) do
                    prompt[k] = v
                end
                prompt._is_copy = true
            end
            prompt.use_book_text = false
        end
        if source_mode ~= "summary" then
            -- Full text or AI knowledge: skip summary cache loading
            if not prompt._is_copy then
                local original_prompt = prompt
                prompt = {}
                for k, v in pairs(original_prompt) do
                    prompt[k] = v
                end
                prompt._is_copy = true
            end
            prompt.use_summary_cache = false
        end
        -- AI knowledge only: allow web search to follow global setting
        -- (these actions have enable_web_search = false, but without document text
        -- web search becomes useful for verification)
        if source_mode == "ai_knowledge" and prompt.enable_web_search == false then
            prompt.enable_web_search = nil
        end
    end

    -- DOI web search override: academic papers benefit from web enrichment
    -- Actions with doi_web_override=true have their enable_web_search=false lifted to nil
    -- (follow global setting) when a DOI is detected in document metadata
    local doi_metadata = config.features and config.features.book_metadata
    if doi_metadata and doi_metadata.doi
            and prompt.doi_web_override and prompt.enable_web_search == false then
        prompt.enable_web_search = nil
    end

    -- Highlight section scope: limit text extraction to a specific section's page range.
    -- Set by unified action popup when highlight actions are scoped to a section.
    -- Only affects text extraction (book_text, full_document) — not cache saving.
    if highlight_section then
        if not prompt._is_copy then
            local original_prompt = prompt
            prompt = {}
            for k, v in pairs(original_prompt) do
                prompt[k] = v
            end
            prompt._is_copy = true
        end
        prompt._section_scope = highlight_section
    end

    -- Context extraction: auto-extract lightweight data when a document is open
    -- Lightweight data (progress, highlights, annotations, stats) is always available
    -- Book text extraction requires use_book_text flag (slow/expensive)
    if ui and ui.document then
        local extraction_success, ContextExtractor = pcall(require, "koassistant_context_extractor")
        if extraction_success and ContextExtractor then
            local extractor = ContextExtractor:new(ui, {
                -- Extraction limits
                enable_book_text_extraction = config.features and config.features.enable_book_text_extraction,
                max_book_text_chars = prompt and prompt.max_book_text_chars or (config.features and config.features.max_book_text_chars),
                max_pdf_pages = config.features and config.features.max_pdf_pages,
                -- Privacy settings
                provider = config.features and config.features.provider,
                trusted_providers = config.features and config.features.trusted_providers,
                enable_highlights_sharing = config.features and config.features.enable_highlights_sharing,
                enable_annotations_sharing = config.features and config.features.enable_annotations_sharing,
                enable_progress_sharing = config.features and config.features.enable_progress_sharing,
                enable_stats_sharing = config.features and config.features.enable_stats_sharing,
                enable_notebook_sharing = config.features and config.features.enable_notebook_sharing,
                -- Library scanning
                enable_library_scanning = config.features and config.features.enable_library_scanning,
                library_scan_folders = config.features and config.features.library_scan_folders,
            })
            logger.info("KOAssistant: Extractor settings - enable_book_text_extraction=",
                       config.features and config.features.enable_book_text_extraction and "true" or "false/nil")
            if extractor:isAvailable() then
                logger.info("KOAssistant: Context extraction starting for action:", prompt and prompt.id or "unknown")
                logger.info("KOAssistant: use_book_text=", prompt and prompt.use_book_text and "true" or "false")
                local extracted = extractor:extractForAction(prompt or {})
                -- Merge extracted data into message_data
                for key, value in pairs(extracted) do
                    message_data[key] = value
                    logger.info("KOAssistant: Extracted data key=", key, "value_len=", type(value) == "string" and #value or "non-string")
                end
                logger.info("KOAssistant: Context extraction complete")

                -- Compute flow fingerprint for cache staleness detection
                message_data.flow_visible_pages = ContextExtractor.getFlowFingerprint(ui.document)

                -- Truncation metadata (book_text_truncated, full_document_truncated, coverage_*)
                -- is stored in message_data via extraction merge above.
                -- Warning dialog fires later in the pre-send check chain.
            end
        else
            logger.warn("KOAssistant: Failed to load context extractor:", ContextExtractor)
        end
    elseif prompt and prompt.use_library then
        -- No open document but action needs library data — extract library only
        -- Read settings fresh from plugin (like Send button does) to avoid stale config
        local lib_features = plugin and plugin.settings and plugin.settings:readSetting("features") or {}
        local lib_scanning = lib_features.enable_library_scanning == true
        local lib_folders = lib_features.library_scan_folders
        if lib_scanning and lib_folders and #lib_folders > 0 then
            local scan_ok, LibraryScanner = pcall(require, "koassistant_library_scanner")
            if scan_ok and LibraryScanner then
                local scan_result = LibraryScanner.scan(lib_features)
                if scan_result and scan_result.books and #scan_result.books > 0 then
                    message_data.library_content = LibraryScanner.format(scan_result)
                else
                    message_data.library_content = ""
                end
            end
        else
            message_data.library_content = ""
        end
    end
    -- Note: Notebook extraction is now handled by ContextExtractor:extractForAction()

    -- Full-document or update-to-100%: override progress to 100% so cache is stored at 1.0
    -- and extraction covers the entire document
    if config.features and (config.features._full_document_xray or config.features._update_to_full_progress or config.features._complete_analysis)
            and ui and ui.document then
        message_data.progress_decimal = "1.0"
        message_data.reading_progress = "100%"
        message_data.progress_page = ui.document.info and ui.document.info.number_of_pages
    end

    -- Get domain context if a domain is set (skip if action opts out)
    -- Priority: prompt.domain (locked) > book domain (DocSettings) > global selected_domain
    -- Book domain "_none" = explicit override to no domain (blocks global fallthrough)
    local domain_context = nil
    local skip_domain = prompt and prompt.skip_domain
    local domain_id = nil
    if not skip_domain then
        if prompt and prompt.domain then
            domain_id = prompt.domain
        else
            -- Book domain: use the relevant book's DocSettings (not necessarily the open book)
            -- Prefer book_metadata.file (file browser/artifact target) over ui.document.file (open book)
            local book_file = (config.features and config.features.book_metadata and config.features.book_metadata.file)
                or (ui and ui.document and ui.document.file)
            local book_domain = nil
            if book_file then
                local relevant_ds
                if ui and ui.doc_settings and ui.document and ui.document.file == book_file then
                    relevant_ds = ui.doc_settings
                else
                    local DocSettings = require("docsettings")
                    relevant_ds = DocSettings:open(book_file)
                end
                book_domain = getBookDomain(relevant_ds)
            end
            if book_domain == "_none" then
                domain_id = nil  -- explicit none, skip global
            elseif book_domain then
                domain_id = book_domain
            else
                domain_id = config.features and config.features.selected_domain
            end
        end
    end
    if domain_id then
        local DomainLoader = require("domain_loader")
        -- Get custom domains from config for lookup
        local custom_domains = config.features and config.features.custom_domains or {}
        local domain = DomainLoader.getDomainById(domain_id, custom_domains)
        if domain then
            domain_context = domain.context
        end
    end

    -- Response caching: check for cached response and switch to update prompt if applicable
    -- Cache when: action supports it and file is known (open book or file browser metadata fallback)
    local using_cache = false
    local cached_progress_display = nil
    local cache_file = (ui and ui.document and ui.document.file)
        or (config.features and config.features.book_metadata and config.features.book_metadata.file)
    local cache_enabled = prompt and prompt.use_response_caching and cache_file

    if cache_enabled and not (config.features and config.features._full_document_xray) then
        local ActionCache = require("koassistant_action_cache")
        local cached_entry = ActionCache.get(cache_file, prompt.id)

        if cached_entry and message_data.progress_decimal then
            local current_progress = tonumber(message_data.progress_decimal) or 0
            local cached_progress = cached_entry.progress_decimal or 0

            -- For X-Ray: skip incremental update if cache is legacy markdown (not JSON)
            -- Force a full regeneration to produce structured JSON output
            local XrayParser = require("koassistant_xray_parser")
            local skip_legacy = prompt.id == "xray" and not XrayParser.isJSON(cached_entry.result)
            if skip_legacy then
                logger.info("KOAssistant: Legacy markdown X-Ray cache detected, forcing full regeneration for JSON output")
            end

            -- AI-knowledge source: skip incremental update_prompt (it expects {incremental_book_text_section})
            -- Use fresh prompt with updated {reading_progress} instead (pseudo-update like X-Ray Simple)
            local skip_incremental = source_mode == "ai_knowledge" and prompt.update_prompt

            -- Use cache if we've progressed by at least 1% since last time
            if not skip_legacy and not skip_incremental
                    and current_progress > cached_progress + 0.01 and prompt.update_prompt then
                using_cache = true
                cached_progress_display = math.floor(cached_progress * 100) .. "%"
                logger.info("KOAssistant: Using cached response from", cached_progress_display, "for", prompt.id)

                -- Switch to update prompt (create a shallow copy to avoid modifying original)
                local original_prompt = prompt
                prompt = {}
                for k, v in pairs(original_prompt) do
                    prompt[k] = v
                end
                prompt.prompt = original_prompt.update_prompt

                -- Add cache data for placeholder substitution
                message_data.cached_result = cached_entry.result
                message_data.cached_progress = cached_progress_display
                message_data.cached_progress_decimal = cached_progress
                -- Stash previous cache's metadata for sticky-true inheritance
                message_data.cached_used_book_text = cached_entry.used_book_text
                message_data.cached_used_highlights = cached_entry.used_highlights
                message_data.cached_used_annotations = cached_entry.used_annotations

                -- For X-Ray: parse cached result and build entity index for merge-based updates
                if prompt.id == "xray" and XrayParser.isJSON(cached_entry.result) then
                    local parsed_cache = XrayParser.parse(cached_entry.result)
                    if parsed_cache and not parsed_cache.error then
                        message_data.entity_index = XrayParser.buildEntityIndex(parsed_cache)
                        message_data._parsed_old_xray = parsed_cache
                    end
                end

                -- Get incremental book text (from cached to current position)
                -- If text extraction is disabled, getBookTextRange returns empty — AI updates from training knowledge
                local extraction_success, ContextExtractor = pcall(require, "koassistant_context_extractor")
                if extraction_success and ContextExtractor then
                    local extractor = ContextExtractor:new(ui, {
                        enable_book_text_extraction = config.features and config.features.enable_book_text_extraction,
                        max_book_text_chars = prompt.max_book_text_chars or (config.features and config.features.max_book_text_chars),
                        max_pdf_pages = config.features and config.features.max_pdf_pages,
                    })
                    -- Use raw page numbers for extraction range
                    -- (flow-aware progress * total_pages gives wrong pages when hidden flows active)
                    local total_pages = ui.document.info and ui.document.info.number_of_pages or 0
                    local from_page = cached_entry.progress_page
                        or math.floor(cached_progress * total_pages)
                    local to_page = tonumber(message_data.progress_page)
                        or math.floor(current_progress * total_pages)
                    local from_raw = total_pages > 0 and from_page / total_pages or cached_progress
                    local to_raw = total_pages > 0 and to_page / total_pages or current_progress
                    local range_result = extractor:getBookTextRange(from_raw, to_raw)
                    message_data.incremental_book_text = range_result.text
                    logger.info("KOAssistant: Extracted incremental book text:", range_result.char_count, "chars")

                    -- Store truncation metadata for pre-send warning dialog
                    if range_result.truncated and not range_result.disabled then
                        message_data.incremental_book_text_truncated = true
                        message_data.incremental_coverage_start = range_result.coverage_start
                        message_data.incremental_coverage_end = range_result.coverage_end
                    end
                end
            end
        end
    end

    -- Determine if web search will be active for this request
    -- Per-action override takes priority, otherwise follow global setting
    -- Used by MessageBuilder to select web-aware hallucination nudge
    local action_ws = prompt and prompt.enable_web_search
    if action_ws ~= nil then
        message_data.web_search_active = action_ws
    else
        message_data.web_search_active = config.features and config.features.enable_web_search == true
    end

    -- Build and add the consolidated message
    -- System prompt and domain are now in config.system (unified approach)
    local consolidated_message = buildConsolidatedMessage(prompt, context, message_data, nil, nil, true)
    history:addUserMessage(consolidated_message, true)

    -- Store domain in history for saving with chat
    if domain_id then
        history.domain = domain_id
    end

    -- Track if user provided additional input
    local has_additional_input = additional_input and additional_input ~= ""

    -- Build unified request config for ALL providers
    -- Pass the prompt/action object which contains behavior_variant/behavior_override
    local action = prompt._action or prompt  -- Use underlying action if available
    buildUnifiedRequestConfig(temp_config, domain_context, action, plugin)

    -- Capture the original action ID before any prompt modifications (for cache save)
    local original_action_id = prompt and prompt.id

    -- Get response from AI with callback for async streaming
    local function handleResponse(success, answer, err, reasoning, web_search_used)
        if success and answer and answer ~= "" then
            -- For X-Ray: parse structured JSON response and prepare display/cache versions
            -- display_answer = rendered markdown for chat history (human-readable)
            -- cache_answer = raw response for cache storage (JSON for structured browsing)
            local display_answer = answer
            local cache_answer = answer
            if action.cache_as_xray then
                local XrayParser = require("koassistant_xray_parser")
                local parsed = XrayParser.parse(answer)
                if parsed and parsed.error then
                    -- AI returned error (e.g., "I don't recognize this work") — show as plain text, skip caching
                    display_answer = parsed.error
                    cache_answer = nil  -- Signal to skip caching below
                    logger.info("KOAssistant: X-Ray returned error response, skipping cache:", parsed.error)
                elseif parsed then
                    -- Merge partial update into existing data when available
                    if using_cache and message_data._parsed_old_xray then
                        -- To debug X-Ray merge: uncomment koassistant_debug_utils.dumpXrayMerge() below
                        parsed = XrayParser.merge(message_data._parsed_old_xray, parsed)
                        logger.info("KOAssistant: Merged incremental X-Ray update into existing data")
                    end
                    local book_meta = message_data.book_metadata or {}
                    local display_progress = message_data.reading_progress or ""
                    if config.features and config.features._full_document_xray then
                        display_progress = "Complete"
                    end
                    display_answer = XrayParser.renderToMarkdown(
                        parsed,
                        book_meta.title or "",
                        display_progress
                    )
                    -- Pretty-print cached JSON so future updates receive readable structured data
                    local json_mod = require("json")
                    cache_answer = json_mod.encode(parsed, { pretty = true, indent = true })
                    logger.info("KOAssistant: X-Ray JSON parsed successfully, rendered to markdown for display")
                else
                    logger.info("KOAssistant: X-Ray response is not valid JSON, using as-is")
                end
            end

            -- If user typed additional input, add it as a visible message before the response
            if has_additional_input then
                history:addUserMessage(additional_input, false)
            end
            history:addAssistantMessage(display_answer, ConfigHelper:getModelInfo(temp_config), reasoning, ConfigHelper:buildDebugInfo(temp_config), web_search_used)

            -- Determine if book text was provided (for cache metadata tracking)
            -- Includes incremental text for update scenarios
            local ResponseParser = require("koassistant_api.response_parser")
            local is_truncated = answer:find(ResponseParser.TRUNCATION_NOTICE, 1, true) ~= nil
            local book_text_was_provided = (message_data.book_text and message_data.book_text ~= "")
                or (message_data.full_document and message_data.full_document ~= "")
                or (message_data.incremental_book_text and message_data.incremental_book_text ~= "")
                or false
            -- Sticky-true: if previous cache used text, keep it true even if this update didn't
            if using_cache and message_data.cached_used_book_text == true then
                book_text_was_provided = true
            end

            -- Pre-format unavailable data for cache metadata (artifact viewers use this)
            local unavailable_text
            if message_data._unavailable_data and #message_data._unavailable_data > 0 then
                unavailable_text = table.concat(message_data._unavailable_data, ", ")
            end

            -- Save to response cache if enabled (for incremental updates)
            -- Skip caching if response was truncated or was an error response (cache_answer set to nil)
            -- For progress actions: require progress_decimal (extraction must succeed)
            -- For non-progress actions (book_info, etc.): save with default 1.0 even without extraction
            if cache_enabled and original_action_id
                    and (message_data.progress_decimal or not (prompt and prompt.use_reading_progress))
                    and not is_truncated and cache_answer then
                local ActionCache = require("koassistant_action_cache")
                -- Track highlights for response cache (e.g., Recap uses highlights)
                local highlights_were_provided = (message_data.highlights and message_data.highlights ~= "")
                if using_cache and message_data.cached_used_highlights == true then
                    highlights_were_provided = true
                end
                -- Position-irrelevant actions (no use_reading_progress) store 1.0
                -- so the popup correctly shows "Redo" instead of misleading "Update to X%"
                local save_progress = prompt and prompt.use_reading_progress
                    and (tonumber(message_data.progress_decimal) or 0)
                    or 1.0
                local save_success = ActionCache.set(
                    cache_file,
                    original_action_id,
                    cache_answer,
                    save_progress,
                    { model = ConfigHelper:getModelInfo(temp_config), used_book_text = book_text_was_provided,
                      used_highlights = highlights_were_provided,
                      used_reasoning = (reasoning ~= nil and reasoning ~= ""),
                      web_search_used = web_search_used or false,
                      previous_progress_decimal = message_data.cached_progress_decimal,
                      flow_visible_pages = message_data.flow_visible_pages,
                      progress_page = message_data.progress_page,
                      full_document = config.features and config.features._full_document_xray or nil,
                      source_mode = source_mode,
                      unavailable_data_text = unavailable_text }
                )
                if save_success then
                    logger.info("KOAssistant: Saved response to cache for", original_action_id, "at", save_progress, "used_book_text=", book_text_was_provided, "used_highlights=", highlights_were_provided)
                end
            elseif is_truncated and cache_enabled then
                logger.info("KOAssistant: Skipping cache for", original_action_id, "- response was truncated")
            end

            -- Save to document caches if action has cache_as_* flags (for reuse by other actions)
            -- Always cache regardless of text extraction — tracks used_book_text for dynamic permission gating
            if not is_truncated and cache_file then
                local ActionCache = require("koassistant_action_cache")
                local progress = tonumber(message_data.progress_decimal) or 0
                local model_name = ConfigHelper:getModelInfo(temp_config)

                if action.cache_as_xray then
                    -- Track what data was used when building this cache
                    -- Reading the cache will only require permissions for data that was actually used
                    local used_highlights = (message_data.highlights and message_data.highlights ~= "")
                    -- Sticky-true: if previous cache used highlights, keep it true even if this update didn't
                    -- Legacy compat: old caches used used_annotations to mean highlights
                    if using_cache and (message_data.cached_used_highlights == true
                        or (message_data.cached_used_highlights == nil and message_data.cached_used_annotations == true)) then
                        used_highlights = true
                    end
                    local xray_metadata = {
                        model = model_name,
                        used_highlights = used_highlights,
                        used_book_text = book_text_was_provided,
                        used_reasoning = (reasoning ~= nil and reasoning ~= ""),
                        web_search_used = web_search_used or false,
                        previous_progress_decimal = message_data.cached_progress_decimal,
                        flow_visible_pages = message_data.flow_visible_pages,
                        progress_page = message_data.progress_page,
                        full_document = config.features and config.features._full_document_xray or nil,
                        unavailable_data_text = unavailable_text,
                    }
                    local xray_success = ActionCache.setXrayCache(cache_file, cache_answer, progress, xray_metadata)
                    if xray_success then
                        logger.info("KOAssistant: Saved X-Ray to reusable cache at", progress, "used_highlights=", used_highlights, "used_book_text=", book_text_was_provided)
                    end
                end

                -- Section scope: save to section-specific cache key (any action type)
                -- Transient flag: _section_scope for generic sections, _section_xray for legacy X-Ray path
                local section_scope = config.features and (config.features._section_scope or config.features._section_xray)
                if section_scope and cache_answer then
                    local section_metadata = {
                        model = model_name,
                        used_book_text = book_text_was_provided,
                        used_highlights = (message_data.highlights and message_data.highlights ~= "") or false,
                        used_reasoning = (reasoning ~= nil and reasoning ~= ""),
                        web_search_used = web_search_used or false,
                        full_document = true,
                        source_mode = source_mode,
                        scope_label = section_scope.label,
                        scope_start_page = section_scope.start_page,
                        scope_end_page = section_scope.end_page,
                        scope_start_xpointer = section_scope.start_xpointer,
                        scope_end_xpointer = section_scope.end_xpointer,
                        scope_page_summary = section_scope.page_summary,
                        unavailable_data_text = unavailable_text,
                    }
                    local section_success = ActionCache.set(cache_file, section_scope.cache_key, cache_answer, 1.0, section_metadata)
                    if section_success then
                        logger.info("KOAssistant: Saved section artifact to", section_scope.cache_key)
                    end
                end

                if action.cache_as_analyze then
                    local analyze_metadata = {
                        model = model_name,
                        used_book_text = book_text_was_provided,
                        used_reasoning = (reasoning ~= nil and reasoning ~= ""),
                        web_search_used = web_search_used or false,
                        flow_visible_pages = message_data.flow_visible_pages,
                        unavailable_data_text = unavailable_text,
                    }
                    local analyze_success = ActionCache.setAnalyzeCache(cache_file, answer, 1.0, analyze_metadata)
                    if analyze_success then
                        logger.info("KOAssistant: Saved document analysis to reusable cache, used_book_text=", book_text_was_provided)
                    end
                end

                if action.cache_as_summary then
                    -- Include language in metadata for cache viewer awareness
                    local summary_metadata = {
                        model = model_name,
                        language = temp_config.features and temp_config.features.translation_language or "English",
                        used_book_text = book_text_was_provided,
                        used_reasoning = (reasoning ~= nil and reasoning ~= ""),
                        web_search_used = web_search_used or false,
                        flow_visible_pages = message_data.flow_visible_pages,
                        unavailable_data_text = unavailable_text,
                    }
                    local summary_success = ActionCache.setSummaryCache(cache_file, answer, 1.0, summary_metadata)
                    if summary_success then
                        logger.info("KOAssistant: Saved document summary to reusable cache with language:", summary_metadata.language, "used_book_text=", book_text_was_provided)
                    end
                end
            end

            -- Invalidate file browser row cache so new artifacts appear immediately
            if plugin and plugin._file_dialog_row_cache then
                plugin._file_dialog_row_cache = { file = nil, rows = nil }
            end

            -- Store cache info in history for viewer to display notice
            if using_cache then
                history.used_cache = true
                history.cached_progress = cached_progress_display
                history.cache_action_id = original_action_id
            end

            -- Store book text truncation info in history for viewer to display notice
            if message_data.book_text_truncated then
                history.book_text_truncated = true
                history.book_text_coverage_start = message_data.book_text_coverage_start
                history.book_text_coverage_end = message_data.book_text_coverage_end
            end

            -- Store unavailable data info for viewer to display notice
            -- Shows when action requested data (book text, annotations, notebook) but didn't receive it
            if message_data._unavailable_data and #message_data._unavailable_data > 0 then
                history.unavailable_data = message_data._unavailable_data
            end

            if on_complete then
                on_complete(history, temp_config)
            end
        else
            -- Treat empty answer as error
            if success and (not answer or answer == "") then
                err = _("No response received from AI")
            end
            if on_complete then
                on_complete(nil, err or "Unknown error")
            end
        end
    end

    -- Wrap the API call so it can be deferred by the large extraction warning dialog
    local function sendQuery()
        local result = queryChatGPT(history:getMessages(), temp_config, handleResponse, plugin and plugin.settings)

        -- If streaming is in progress, return nil (result comes via callback)
        if isStreamingInProgress(result) then
            return nil
        end

        -- Non-streaming: handleResponse callback was already called by queryChatGPT
        -- Return history and config for backward compatibility with callers that don't use callback
        return history, temp_config
    end

    -- Pre-send check chain: truncation warning → large extraction warning → sendQuery
    -- Each check is blocking — user must Continue or Cancel before proceeding.

    -- Compute extracted chars for large extraction check
    local extracted_chars = 0
    if message_data.book_text then extracted_chars = extracted_chars + #message_data.book_text end
    if message_data.full_document then extracted_chars = extracted_chars + #message_data.full_document end

    -- Step 2: Large extraction warning (existing check, now wrapped in function for chaining)
    local function checkLargeExtractionAndSend()
        if extracted_chars > Constants.LARGE_EXTRACTION_THRESHOLD
                and not (config.features and config.features.suppress_large_extraction_warning) then
            local chars_k = math.floor(extracted_chars / 1000)
            local tokens_low = math.floor(extracted_chars / 4000)
            local tokens_high = math.floor(extracted_chars / 2000)
            local warning_dialog
            warning_dialog = ButtonDialog:new{
                title = T(_("Large text extraction: ~%1K characters (~%2K-%3K tokens). Make sure your model's context window can accommodate this.\n\nYou can focus on a specific Section instead of the full document, or use KOReader's Hidden Flows to exclude irrelevant content."), chars_k, tokens_low, tokens_high),
                buttons = {
                    {{
                        text = _("Cancel"),
                        callback = function()
                            UIManager:close(warning_dialog)
                        end,
                    }},
                    {{
                        text = _("Continue"),
                        callback = function()
                            UIManager:close(warning_dialog)
                            sendQuery()
                        end,
                    }},
                    {{
                        text = _("Don't warn again"),
                        callback = function()
                            UIManager:close(warning_dialog)
                            -- Persist the preference
                            if plugin and plugin.settings then
                                local features_tbl = plugin.settings:readSetting("features") or {}
                                features_tbl.suppress_large_extraction_warning = true
                                plugin.settings:saveSetting("features", features_tbl)
                                plugin.settings:flush()
                            end
                            -- Also update current config so it takes effect immediately
                            if config.features then
                                config.features.suppress_large_extraction_warning = true
                            end
                            sendQuery()
                        end,
                    }},
                },
            }
            UIManager:show(warning_dialog)
            return nil  -- Early return; continuation via callback
        end

        return sendQuery()
    end

    -- Step 1: Truncation warning (fires before large extraction check)
    -- Book text and full document truncation are mutually exclusive in practice;
    -- incremental truncation is a separate case that could theoretically co-occur.
    local truncation_msg
    if not (config.features and config.features.suppress_truncation_warning) then
        if message_data.book_text_truncated or message_data.full_document_truncated then
            local cs = (message_data.book_text_truncated and message_data.book_text_coverage_start)
                    or (message_data.full_document_truncated and message_data.full_document_coverage_start) or 0
            local ce = (message_data.book_text_truncated and message_data.book_text_coverage_end)
                    or (message_data.full_document_truncated and message_data.full_document_coverage_end) or 0
            truncation_msg = T(_("Extracted text was truncated (covers %1%–%2% of the document)."), cs, ce)
        end
        if message_data.incremental_book_text_truncated then
            local cs = message_data.incremental_coverage_start or 0
            local ce = message_data.incremental_coverage_end or 0
            local inc_msg = T(_("New text since last update was truncated (covers %1%–%2% of the update range)."), cs, ce)
            truncation_msg = truncation_msg and (truncation_msg .. "\n" .. inc_msg) or inc_msg
        end
    end

    if truncation_msg then
        truncation_msg = truncation_msg .. "\n\n"
            .. _("You can increase the limit in Settings → Privacy & Data → Text Extraction, use Hidden Flows to exclude irrelevant content, or focus on a specific section.")
        local truncation_dialog
        truncation_dialog = ButtonDialog:new{
            title = truncation_msg,
            buttons = {
                {{
                    text = _("Cancel"),
                    callback = function()
                        UIManager:close(truncation_dialog)
                    end,
                }},
                {{
                    text = _("Continue Anyway"),
                    callback = function()
                        UIManager:close(truncation_dialog)
                        checkLargeExtractionAndSend()
                    end,
                }},
                {{
                    text = _("Don't warn again"),
                    callback = function()
                        UIManager:close(truncation_dialog)
                        -- Persist the preference
                        if plugin and plugin.settings then
                            local features_tbl = plugin.settings:readSetting("features") or {}
                            features_tbl.suppress_truncation_warning = true
                            plugin.settings:saveSetting("features", features_tbl)
                            plugin.settings:flush()
                        end
                        if config.features then
                            config.features.suppress_truncation_warning = true
                        end
                        checkLargeExtractionAndSend()
                    end,
                }},
            },
        }
        UIManager:show(truncation_dialog)
        return nil  -- Early return; continuation via callback
    end

    return checkLargeExtractionAndSend()
end

--- Format artifact metadata for popup display (e.g., "X-Ray (100%, today)")
--- @param cache table Artifact cache entry with name, data.progress_decimal, data.timestamp
--- @return string Formatted display text
local function formatArtifactDisplayText(cache)
    local parts = {}
    if cache.data then
        if cache.data.progress_decimal and cache.data.progress_decimal < 1.0 then
            local pct = math.floor(cache.data.progress_decimal * 100 + 0.5)
            table.insert(parts, pct .. "%")
        end
        if cache.data.timestamp then
            local now = os.time()
            local today_t = os.date("*t", now)
            today_t.hour, today_t.min, today_t.sec = 0, 0, 0
            local cached_t = os.date("*t", cache.data.timestamp)
            cached_t.hour, cached_t.min, cached_t.sec = 0, 0, 0
            local days = math.floor((os.time(today_t) - os.time(cached_t)) / 86400)
            if days == 0 then
                table.insert(parts, _("today"))
            elseif days < 30 then
                table.insert(parts, string.format(_("%dd ago"), days))
            else
                local months = math.floor(days / 30)
                table.insert(parts, string.format(_("%dm ago"), months))
            end
        end
    end
    if #parts > 0 then
        return cache.name .. " (" .. table.concat(parts, ", ") .. ")"
    end
    return cache.name
end

local function showChatGPTDialog(ui_instance, highlighted_text, config, prompt_type, plugin, book_metadata, initial_input)
    -- Use the passed configuration or fall back to the global CONFIGURATION
    local configuration = config or CONFIGURATION

    -- Close any existing input dialog to prevent duplicates
    -- This handles the case where a new book chat is opened while one is already open
    if plugin and plugin.current_input_dialog then
        UIManager:close(plugin.current_input_dialog)
        plugin.current_input_dialog = nil
    end

    -- Consume transient config flags (set by X-Ray browser "Chat about this", etc.)
    -- Must read and clear immediately so they don't persist to subsequent calls
    local hide_artifacts = ((configuration or {}).features or {})._hide_artifacts
    local exclude_action_flags = ((configuration or {}).features or {})._exclude_action_flags
    local is_xray_chat = ((configuration or {}).features or {})._xray_chat_context
    local xray_context_prefix = ((configuration or {}).features or {})._xray_context_prefix
    local show_all_actions = ((configuration or {}).features or {})._show_all_actions or false
    if configuration and configuration.features then
        configuration.features._hide_artifacts = nil
        configuration.features._exclude_action_flags = nil
        configuration.features._xray_chat_context = nil
        configuration.features._xray_context_prefix = nil
        configuration.features._show_all_actions = nil
    end

    -- Log which provider we're using
    local logger = require("logger")
    logger.info("Using AI provider: " .. (configuration.provider or "anthropic"))
    
    -- Log configuration structure
    if configuration and configuration.features then
        logger.info("Configuration has features")
        if configuration.features.prompts then
            local count = 0
            for k, v in pairs(configuration.features.prompts) do
                count = count + 1
                logger.info("  Found configured prompt: " .. k)
            end
            logger.info("Total configured prompts: " .. count)
        else
            logger.warn("No prompts in configuration.features")
        end
    else
        logger.warn("Configuration missing or no features")
    end
    
    -- Check if this is a general context chat (no book association)
    -- Use getPromptContext() which properly prioritizes: library > book > general > highlight
    -- This prevents stale is_general_context flags from affecting book context dialogs
    local is_general_context = getPromptContext(configuration) == "general"

    -- Capture book info from KOReader's merged props (includes user edits from Book Info dialog)
    local ui_doc_props = ui_instance and ui_instance.doc_props
    local doc_title = ui_doc_props and (ui_doc_props.display_title or ui_doc_props.title) or nil
    local doc_author = ui_doc_props and ui_doc_props.authors or nil
    -- Normalize multi-author strings (KOReader stores as newline-separated)
    if doc_author and doc_author:find("\n") then
        doc_author = doc_author:gsub("\n", ", ")
    end
    local doc_file = ui_instance and ui_instance.document and ui_instance.document.file or nil

    -- For general/library context, don't use document_path - these chats aren't tied to a single document
    -- But capture launch_context so we know where the chat was started from
    local document_path = nil
    local launch_context = nil
    -- Reset book_metadata to allow conditional assignment below
    book_metadata = nil

    local is_library_context = configuration and configuration.features and configuration.features.is_library_context
    if is_general_context or is_library_context then
        -- General/library chat: don't associate with a document, but track launch context
        local ctx_label = is_library_context and "Library" or "General"
        if doc_title and doc_file then
            launch_context = {
                title = doc_title,
                author = doc_author,
                file = doc_file
            }
            logger.info("KOAssistant: " .. ctx_label .. " chat launched from book - " .. doc_title)
        else
            logger.info("KOAssistant: " .. ctx_label .. " chat with no launch context")
        end
    elseif doc_file then
        -- Document is open, use its metadata and path
        document_path = doc_file

        -- Extract filename as fallback for missing title metadata
        local filename_fallback = nil
        if doc_file then
            filename_fallback = doc_file:match("([^/\\]+)$")  -- Get filename
            if filename_fallback then
                filename_fallback = filename_fallback:gsub("%.[^%.]+$", "")  -- Remove extension
                filename_fallback = filename_fallback:gsub("[_-]", " ")  -- Convert separators to spaces
            end
        end

        book_metadata = {
            title = (doc_title and doc_title ~= "") and doc_title or filename_fallback or "Unknown",
            author = (doc_author and doc_author ~= "") and doc_author or ""  -- Empty, not "Unknown"
        }
        logger.info("KOAssistant: Document context - title: " .. (book_metadata.title or "nil") .. ", author: " .. (book_metadata.author or "nil"))
    elseif configuration and configuration.features and configuration.features.book_metadata then
        -- File browser context, use metadata from configuration
        book_metadata = {
            title = configuration.features.book_metadata.title,
            author = configuration.features.book_metadata.author
        }
        -- For file browser context, get the document path from configuration
        if configuration.features.book_metadata.file then
            document_path = configuration.features.book_metadata.file
        end
        logger.info("KOAssistant: File browser context - title: " .. (book_metadata.title or "nil") .. ", author: " .. (book_metadata.author or "nil"))
    else
        logger.info("KOAssistant: No metadata available in either context")
    end

    -- Determine input context for per-context action ordering
    local has_open_book = ui_instance and ui_instance.document ~= nil
    local input_context
    if is_general_context then
        input_context = "general"  -- Uses existing getGeneralMenuActionObjects()
    elseif is_xray_chat then
        input_context = "xray_chat"
    elseif configuration and configuration.features and configuration.features.is_library_context then
        input_context = "library"
    elseif configuration and configuration.features and configuration.features.is_book_context then
        if has_open_book then
            input_context = "book"
        else
            input_context = "book_filebrowser"
        end
    else
        input_context = "highlight"
    end

    -- Track selected domain for this dialog (initialize from config if set)
    local selected_domain = configuration and configuration.features and configuration.features.selected_domain or nil

    -- Track per-book domain for any context that targets a specific book
    -- General and library contexts explicitly disassociate from any specific book
    -- Use document_path (the relevant book) to load the right DocSettings,
    -- not ui_instance.doc_settings (which is the currently open book — may differ)
    local doc_settings = nil
    if document_path then
        if ui_instance and ui_instance.doc_settings
                and ui_instance.document and ui_instance.document.file == document_path then
            -- Currently open book — use in-memory settings
            doc_settings = ui_instance.doc_settings
        else
            -- Different book (file browser, artifact) — load from disk
            local DocSettings = require("docsettings")
            doc_settings = DocSettings:open(document_path)
        end
    end
    local book_domain_id = getBookDomain(doc_settings)

    -- Forward declaration (showDomainSelector uses refreshInputDialog, defined later)
    local refreshInputDialog

    -- Domain target: "book" or "global" — controls where selection is saved
    -- Default to "book" if a book override exists, otherwise "global"
    local domain_target = (doc_settings and book_domain_id) and "book" or "global"

    -- Function to show domain selector
    -- Single list with target toggle at top when a book is open
    local function showDomainSelector()
        -- Close the on-screen keyboard first to prevent z-order issues
        input_dialog:onCloseKeyboard()

        local DomainLoader = require("domain_loader")
        -- Get custom domains from settings
        local features = plugin and plugin.settings and plugin.settings:readSetting("features") or {}
        local custom_domains = features.custom_domains or {}
        -- Get all domains (folder + UI-created) sorted
        local sorted_domains = DomainLoader.getSortedDomains(custom_domains)

        local buttons = {}

        -- Helper to close and refresh input dialog
        local function closeAndRefresh()
            UIManager:close(_G.domain_selector_dialog)
            refreshInputDialog()
        end

        -- Helper to close and reopen this selector (for target toggle)
        local function reopenSelector()
            UIManager:close(_G.domain_selector_dialog)
            showDomainSelector()
        end

        local is_book_target = doc_settings and domain_target == "book"

        if doc_settings then
            -- Target toggle row: [For this book] [Global default]
            local book_label = is_book_target and ("● " .. _("For this book")) or ("○ " .. _("For this book"))
            local global_label = (not is_book_target) and ("● " .. _("Global")) or ("○ " .. _("Global"))
            table.insert(buttons, {
                {
                    text = book_label,
                    callback = function()
                        if domain_target ~= "book" then
                            domain_target = "book"
                            reopenSelector()
                        end
                    end,
                },
                {
                    text = global_label,
                    callback = function()
                        if domain_target ~= "global" then
                            domain_target = "global"
                            reopenSelector()
                        end
                    end,
                },
            })
        end

        if is_book_target then
            -- Book target: show "Use global default" option first
            local use_global_prefix = (not book_domain_id) and "● " or "○ "
            table.insert(buttons, {
                {
                    text = use_global_prefix .. _("Use global"),
                    callback = function()
                        book_domain_id = nil
                        persistBookDomain(doc_settings, nil)
                        closeAndRefresh()
                    end,
                },
            })

            -- "None" (explicit override to no domain)
            local none_prefix = (book_domain_id == "_none") and "● " or "○ "
            table.insert(buttons, {
                {
                    text = none_prefix .. _("None"),
                    callback = function()
                        book_domain_id = "_none"
                        persistBookDomain(doc_settings, "_none")
                        closeAndRefresh()
                    end,
                },
            })

            -- Domain options
            for _idx, domain in ipairs(sorted_domains) do
                local prefix = (book_domain_id == domain.id) and "● " or "○ "
                table.insert(buttons, {
                    {
                        text = prefix .. domain.display_name,
                        callback = function()
                            book_domain_id = domain.id
                            persistBookDomain(doc_settings, domain.id)
                            closeAndRefresh()
                        end,
                    },
                })
            end
        else
            -- Global target (or no book open): standard list
            local none_prefix = (not selected_domain) and "● " or "○ "
            table.insert(buttons, {
                {
                    text = none_prefix .. _("None"),
                    callback = function()
                        selected_domain = nil
                        configuration.features = configuration.features or {}
                        configuration.features.selected_domain = nil
                        persistDomainSelection(plugin, nil)
                        closeAndRefresh()
                    end,
                },
            })

            for _idx, domain in ipairs(sorted_domains) do
                local prefix = (selected_domain == domain.id) and "● " or "○ "
                table.insert(buttons, {
                    {
                        text = prefix .. domain.display_name,
                        callback = function()
                            selected_domain = domain.id
                            configuration.features = configuration.features or {}
                            configuration.features.selected_domain = domain.id
                            persistDomainSelection(plugin, domain.id)
                            closeAndRefresh()
                        end,
                    },
                })
            end
        end

        -- Close button
        table.insert(buttons, {
            {
                text = _("Close"),
                id = "close",
                callback = function()
                    UIManager:close(_G.domain_selector_dialog)
                end,
            },
        })

        local ButtonDialog = require("ui/widget/buttondialog")
        _G.domain_selector_dialog = ButtonDialog:new{
            title = _("Select Domain"),
            buttons = buttons,
        }
        UIManager:show(_G.domain_selector_dialog)
    end

    -- Get domain display name for button
    -- Shows effective domain: book domain takes priority over global
    -- "_none" sentinel = explicit no-domain override for this book
    local function getDomainDisplayName()
        if book_domain_id == "_none" then
            return _("None") .. _(" (book)")
        end
        local effective_id = book_domain_id or selected_domain
        if not effective_id then
            return _("None")
        end
        local DomainLoader = require("domain_loader")
        -- Get custom domains from settings for lookup
        local features = plugin and plugin.settings and plugin.settings:readSetting("features") or {}
        local custom_domains = features.custom_domains or {}
        local domain = DomainLoader.getDomainById(effective_id, custom_domains)
        if domain then
            if book_domain_id then
                return domain.display_name .. _(" (book)")
            end
            return domain.display_name
        end
        return effective_id
    end

    -- Emoji helper for this dialog (scoped to dialog lifecycle)
    local enable_emoji = configuration and configuration.features
        and configuration.features.enable_emoji_icons == true

    local function getWebToggleText()
        local web_on = configuration and configuration.features
            and configuration.features.enable_web_search
        local label = web_on and _("Web ON") or _("Web OFF")
        return Constants.getEmojiText("🔍", label, enable_emoji)
    end

    -- Shared action execution for grid buttons, More Actions, and expanded in-grid buttons.
    -- Handles: getInputText, close dialog, _checkRequirements, showCacheActionPopup,
    -- cache viewer redirect, and handlePredefinedPrompt with full onPromptComplete.
    local function executeInputAction(action, action_id)
        -- Pre-flight checks run BEFORE closing dialog so it stays open on failure

        -- Pre-flight: block when declared requirements are unmet
        if plugin and plugin._checkRequirements then
            if plugin:_checkRequirements(action) then
                return
            end
        end

        -- Pre-flight: block selection-required library actions when no books selected
        if action.requires_selected_books then
            local books = configuration and configuration.features and configuration.features.books_info
            if not books or #books < 2 then
                UIManager:show(InfoMessage:new{
                    text = _("Select at least 2 items first using [+ Add Items]."),
                    timeout = 3,
                })
                return
            end
        end

        local additional_input = input_dialog:getInputText()
        UIManager:close(input_dialog)
        if plugin then plugin.current_input_dialog = nil end

        local function runAction()
            UIManager:scheduleIn(0.1, function()
                local function onPromptComplete(history, temp_config_or_error)
                    if history then
                        local temp_config = temp_config_or_error
                        local function addMessage(message, is_context, on_complete)
                            history:addUserMessage(message, is_context)
                            local answer_result = queryChatGPT(history:getMessages(), temp_config, function(success, answer, err, reasoning, web_search_used)
                                if success and answer then
                                    history:addAssistantMessage(answer, ConfigHelper:getModelInfo(temp_config), reasoning, ConfigHelper:buildDebugInfo(temp_config), web_search_used)
                                end
                                if on_complete then on_complete(success, answer, err, reasoning, web_search_used) end
                            end, plugin and plugin.settings)
                            if not isStreamingInProgress(answer_result) then
                                return answer_result
                            end
                            return nil
                        end
                        closeLoadingDialog()

                        -- For cache-first actions (Recap, X-Ray Simple): open in simple viewer
                        if action.use_response_caching and action.id and plugin then
                            local ActionCache = require("koassistant_action_cache")
                            local file = ui_instance and ui_instance.document and ui_instance.document.file
                            if file then
                                local cached = ActionCache.get(file, action.id)
                                if cached and cached.result then
                                    plugin:viewCachedAction(action, action.id, cached)
                                    return
                                end
                            end
                        end

                        -- For document analysis/summary: open in cache viewer
                        if (action.cache_as_analyze or action.cache_as_summary) and plugin then
                            local ActionCache = require("koassistant_action_cache")
                            local file = ui_instance and ui_instance.document and ui_instance.document.file
                            if file then
                                local cached, cache_name, cache_key
                                if action.cache_as_analyze then
                                    cached = ActionCache.getAnalyzeCache(file)
                                    cache_name = _("Analysis")
                                    cache_key = "_analyze_cache"
                                else
                                    cached = ActionCache.getSummaryCache(file)
                                    cache_name = _("Summary")
                                    cache_key = "_summary_cache"
                                end
                                if cached and cached.result then
                                    plugin:showCacheViewer({ name = cache_name, key = cache_key, data = cached })
                                    return
                                end
                            end
                        end

                        showResponseDialog(_(action.text), history, highlighted_text, addMessage, temp_config, document_path, plugin, book_metadata, launch_context, ui_instance)
                    else
                        closeLoadingDialog()
                        local error_msg = temp_config_or_error or "Unknown error"
                        UIManager:show(InfoMessage:new{
                            text = _("Error: ") .. action_id .. " - " .. error_msg,
                            timeout = 2
                        })
                    end
                end

                -- Pass X-Ray context prefix to handlePredefinedPrompt via transient flag
                if xray_context_prefix then
                    configuration.features = configuration.features or {}
                    configuration.features._xray_context_prefix = xray_context_prefix
                end

                handlePredefinedPrompt(action_id, highlighted_text, ui_instance, configuration, nil, plugin, additional_input, onPromptComplete, book_metadata)
            end)
        end

        -- Pre-flight: cache actions with source_selection use View/Sections/New popup
        if action.use_response_caching and action.source_selection and plugin then
            local ActionCache = require("koassistant_action_cache")
            local file = (ui_instance and ui_instance.document and ui_instance.document.file)
                or (configuration and configuration.features and configuration.features.book_metadata
                    and configuration.features.book_metadata.file)
            local cached = file and ActionCache.get(file, action_id)
            -- Fallback: document-level cache (migration)
            if not cached or not cached.result then
                if action.cache_as_summary then
                    cached = ActionCache.getSummaryCache(file)
                elseif action.cache_as_analyze then
                    cached = ActionCache.getAnalyzeCache(file)
                end
            end
            if cached and cached.result then
                local action_name = action.text or action_id
                local view_detail = ""
                if cached.progress_decimal or cached.timestamp then
                    local parts = {}
                    if cached.progress_decimal and cached.progress_decimal < 1.0 then
                        table.insert(parts, math.floor(cached.progress_decimal * 100 + 0.5) .. "%")
                    end
                    if cached.timestamp then
                        local now = os.time()
                        local diff = now - cached.timestamp
                        local rel_time
                        if diff < 86400 then rel_time = _("today")
                        elseif diff < 172800 then rel_time = _("yesterday")
                        else rel_time = math.floor(diff / 86400) .. "d" end
                        table.insert(parts, rel_time)
                    end
                    if #parts > 0 then
                        view_detail = " (" .. table.concat(parts, ", ") .. ")"
                    end
                end
                local ButtonDialog = require("ui/widget/buttondialog")
                local dialog
                local popup_buttons = {}
                -- View existing artifact
                table.insert(popup_buttons, {{
                    text = T(_("View %1"), action_name .. view_detail),
                    callback = function()
                        UIManager:close(dialog)
                        plugin:viewCachedAction(action, action_id, cached, { file = file })
                    end,
                }})
                -- Surface in-range section artifacts
                local section_prefix = ActionCache.getSectionPrefix(action_id)
                local doc = ui_instance and ui_instance.document
                if section_prefix and file and doc then
                    local in_range = ActionCache.findMatchingSections(file, doc, section_prefix)
                    for _idx2, sec in ipairs(in_range) do
                        local page_info = ActionCache.reconvertPageSummary(sec.data, doc)
                        local sec_parts = {}
                        if page_info and page_info ~= "" then
                            table.insert(sec_parts, page_info)
                        end
                        local sec_rel_time = sec.data.timestamp and os.difftime(os.time(), sec.data.timestamp) or nil
                        local sec_rel = ""
                        if sec_rel_time then
                            local diff = sec_rel_time
                            if diff < 3600 then sec_rel = _("now")
                            elseif diff < 86400 then sec_rel = _("today")
                            else sec_rel = math.floor(diff / 86400) .. "d" end
                        end
                        if sec_rel ~= "" then
                            table.insert(sec_parts, sec_rel)
                        end
                        local sec_detail = #sec_parts > 0 and " (" .. table.concat(sec_parts, ", ") .. ")" or ""
                        local captured_sec = sec
                        table.insert(popup_buttons, {{
                            text = T(_("View \"%1\""), sec.label) .. sec_detail,
                            callback = function()
                                UIManager:close(dialog)
                                plugin:viewCachedAction(action, action_id, captured_sec.data, {
                                    file = file,
                                    section_key = captured_sec.key,
                                    section_label = captured_sec.label,
                                })
                            end,
                        }})
                    end
                end
                -- Update/Redo for position-relevant actions (e.g. Recap)
                if action.use_reading_progress and ui_instance and ui_instance.document then
                    local cached_progress = cached.progress_decimal or 0
                    local update_text
                    local ContextExtractor = require("koassistant_context_extractor")
                    local extractor = ContextExtractor:new(ui_instance)
                    local progress = extractor:getReadingProgress()
                    if progress.decimal > cached_progress + 0.01 then
                        update_text = T(_("Update %1"), action_name .. " (" .. T(_("to %1"), progress.formatted) .. ")")
                    else
                        update_text = T(_("Redo %1"), action_name)
                    end
                    table.insert(popup_buttons, {{
                        text = update_text,
                        callback = function()
                            UIManager:close(dialog)
                            -- Use cached source_mode for update/redo (same source)
                            configuration.features = configuration.features or {}
                            configuration.features._source_mode = cached.source_mode
                            runAction()
                        end,
                    }})
                end
                -- Browse remaining section artifacts (all sections in group)
                if section_prefix and file then
                    local sec_count = ActionCache.getSectionCount(file, section_prefix)
                    if sec_count > 0 then
                        table.insert(popup_buttons, {{
                            text = string.format("%s (%d)", ActionCache.getSectionGroupName(action_id) or _("Sections"), sec_count),
                            callback = function()
                                UIManager:close(dialog)
                                plugin:_showSectionList(action, action_id)
                            end,
                        }})
                    end
                end
                -- New generation (opens scope/source popup)
                table.insert(popup_buttons, {{
                    text = T(_("New %1…"), action_name),
                    callback = function()
                        UIManager:close(dialog)
                        local is_hl = action.context == "highlight" or action.context == "both"
                        plugin:_showUnifiedActionPopup(action, action_id, {
                            for_highlight = is_hl or nil,
                            on_execute = function(popup_state)
                                configuration.features = configuration.features or {}
                                configuration.features._source_mode = popup_state.source
                                if is_hl and popup_state.scope == "section" and popup_state.section_entry then
                                    configuration.features._highlight_section_scope = {
                                        start_page = popup_state.section_entry.start_page,
                                        end_page = popup_state.section_entry.end_page,
                                    }
                                end
                                runAction()
                            end,
                        })
                    end,
                }})
                table.insert(popup_buttons, {{
                    text = _("Cancel"),
                    callback = function()
                        UIManager:close(dialog)
                    end,
                }})
                dialog = ButtonDialog:new{
                    title = action_name,
                    buttons = popup_buttons,
                }
                UIManager:show(dialog)
                return
            end
            -- No cache: check for sections before falling through to source_selection
            local section_prefix = ActionCache.getSectionPrefix(action_id)
            local sec_count = section_prefix and file and ActionCache.getSectionCount(file, section_prefix) or 0
            if sec_count > 0 then
                local action_name = action.text or action_id
                local ButtonDialog = require("ui/widget/buttondialog")
                local nc_dialog
                local nc_buttons = {}
                table.insert(nc_buttons, {{
                    text = string.format("%s (%d)", ActionCache.getSectionGroupName(action_id) or _("Sections"), sec_count),
                    callback = function()
                        UIManager:close(nc_dialog)
                        plugin:_showSectionList(action, action_id)
                    end,
                }})
                table.insert(nc_buttons, {{
                    text = T(_("New %1…"), action_name),
                    callback = function()
                        UIManager:close(nc_dialog)
                        local is_hl = action.context == "highlight" or action.context == "both"
                        plugin:_showUnifiedActionPopup(action, action_id, {
                            for_highlight = is_hl or nil,
                            on_execute = function(popup_state)
                                configuration.features = configuration.features or {}
                                configuration.features._source_mode = popup_state.source
                                if is_hl and popup_state.scope == "section" and popup_state.section_entry then
                                    configuration.features._highlight_section_scope = {
                                        start_page = popup_state.section_entry.start_page,
                                        end_page = popup_state.section_entry.end_page,
                                    }
                                end
                                runAction()
                            end,
                        })
                    end,
                }})
                table.insert(nc_buttons, {{
                    text = _("Cancel"),
                    callback = function()
                        UIManager:close(nc_dialog)
                    end,
                }})
                nc_dialog = ButtonDialog:new{
                    title = action_name,
                    buttons = nc_buttons,
                }
                UIManager:show(nc_dialog)
                return
            end
            -- No cache, no sections: fall through to source_selection handler below
        end

        -- Pre-flight: show View/Update popup for other cached actions (without source_selection)
        if action.use_response_caching and not action.source_selection
                and plugin and plugin.showCacheActionPopup then
            local cache_opts
            local cfg_bm = configuration and configuration.features
                and configuration.features.book_metadata
            if cfg_bm and cfg_bm.file then
                cache_opts = {
                    file = cfg_bm.file,
                    book_title = cfg_bm.title,
                    book_author = cfg_bm.author,
                }
            end
            plugin:showCacheActionPopup(action, action_id, runAction, cache_opts)
            return
        end

        -- Unified action popup for source_selection actions
        if action.source_selection and plugin and plugin._showUnifiedActionPopup then
            local is_highlight = action.context == "highlight" or action.context == "both"
            plugin:_showUnifiedActionPopup(action, action_id, {
                for_highlight = is_highlight or nil,
                on_execute = function(popup_state)
                    configuration.features = configuration.features or {}
                    configuration.features._source_mode = popup_state.source
                    -- Highlight actions: set _highlight_section_scope for text extraction range
                    if is_highlight and popup_state.scope == "section" and popup_state.section_entry then
                        configuration.features._highlight_section_scope = {
                            start_page = popup_state.section_entry.start_page,
                            end_page = popup_state.section_entry.end_page,
                        }
                    end
                    runAction()
                end,
            })
            return
        end

        runAction()
    end

    -- Helper: merge new books into existing selection (dedup by file path)
    local function mergeBooks(new_books)
        configuration.features = configuration.features or {}
        local existing = configuration.features.books_info or {}
        local seen = {}
        for _idx, b in ipairs(existing) do
            if b.file then seen[b.file] = true end
        end
        local merged = {}
        for _idx, b in ipairs(existing) do
            table.insert(merged, b)
        end
        local added = 0
        for _idx, b in ipairs(new_books) do
            if not b.file or not seen[b.file] then
                table.insert(merged, b)
                if b.file then seen[b.file] = true end
                added = added + 1
            end
        end
        -- Rebuild book_context string
        local books_list = {}
        for i, book in ipairs(merged) do
            if book.authors and book.authors ~= "" then
                table.insert(books_list, string.format('%d. "%s" by %s', i, book.title, book.authors))
            else
                table.insert(books_list, string.format('%d. "%s"', i, book.title))
            end
        end
        configuration.features.books_info = merged
        configuration.features.book_context = string.format(
            "Selected %d books:\n\n%s", #merged, table.concat(books_list, "\n"))
        if #merged > 0 then
            configuration.features.book_metadata = {
                title = merged[1].title,
                author = merged[1].authors or "",
            }
        end
        return added, #merged
    end

    -- Library context: show Add Books menu with presets
    local add_books_dialog  -- forward declaration for closure
    local function showAddBooksMenu()
        local ButtonDialog = require("ui/widget/buttondialog")
        local books = configuration and configuration.features and configuration.features.books_info
        local book_count = books and #books or 0
        local menu_buttons = {}

        -- Preset: Last 5 from History
        table.insert(menu_buttons, {{
            text = _("Last 5 from History"),
            callback = function()
                UIManager:close(add_books_dialog)
                local ok, ReadHistory = pcall(require, "readhistory")
                if not ok or not ReadHistory then
                    UIManager:show(InfoMessage:new{
                        text = _("Reading history unavailable."),
                        timeout = 2,
                    })
                    return
                end
                ReadHistory:reload()
                local hist = ReadHistory.hist or {}
                if #hist == 0 then
                    UIManager:show(InfoMessage:new{
                        text = _("No reading history found."),
                        timeout = 2,
                    })
                    return
                end
                -- Take up to 5 most recent
                local new_books = {}
                local count = 0
                for _idx, entry in ipairs(hist) do
                    if entry.file and count < 5 then
                        -- Get title and author from DocSettings (most reliable)
                        local title = nil
                        local author = ""
                        local doc_ok, DocSettings = pcall(require, "docsettings")
                        if doc_ok and DocSettings then
                            local ds = DocSettings:open(entry.file)
                            local doc_props = ds:readSetting("doc_props")
                            if doc_props then
                                local dt = doc_props.display_title or doc_props.title
                                if dt and dt ~= "" then title = dt end
                                if doc_props.authors and doc_props.authors ~= "" then
                                    author = doc_props.authors:gsub("\n", ", ")
                                end
                            end
                        end
                        -- Fallback to ReadHistory text or filename
                        if not title then
                            title = entry.text or entry.file:match("([^/]+)%.[^%.]+$") or entry.file
                        end
                        table.insert(new_books, {
                            title = title,
                            authors = author,
                            file = entry.file,
                        })
                        count = count + 1
                    end
                end
                if #new_books == 0 then
                    UIManager:show(InfoMessage:new{
                        text = _("No books found in history."),
                        timeout = 2,
                    })
                    return
                end
                local added, total = mergeBooks(new_books)
                if added == 0 then
                    UIManager:show(InfoMessage:new{
                        text = T(_("All %1 already selected."), #new_books),
                        timeout = 2,
                    })
                    return
                end
                refreshInputDialog()
            end,
        }})

        -- Scanner-based presets (require library scanning enabled + folders configured)
        local features = plugin and plugin.settings and plugin.settings:readSetting("features") or {}
        local scanning_available = features.enable_library_scanning == true
            and features.library_scan_folders and #features.library_scan_folders > 0
        local function addScannerPreset(label, status_filter)
            table.insert(menu_buttons, {{
                text = scanning_available and label or (label .. " " .. _("(scanning off)")),
                callback = function()
                    UIManager:close(add_books_dialog)
                    if not scanning_available then
                        UIManager:show(InfoMessage:new{
                            text = _("Enable library scanning and configure folders in Settings → Library Settings."),
                            timeout = 3,
                        })
                        return
                    end
                    local LibraryScanner = require("koassistant_library_scanner")
                    local scan_result = LibraryScanner.scan(features)
                    local status_books = scan_result.by_status and scan_result.by_status[status_filter] or {}
                    if #status_books == 0 then
                        UIManager:show(InfoMessage:new{
                            text = T(_("No books with status '%1' found in library."), status_filter),
                            timeout = 2,
                        })
                        return
                    end
                    -- Convert scanner metadata to books_info format
                    local new_books = {}
                    for _idx, b in ipairs(status_books) do
                        table.insert(new_books, {
                            title = b.title,
                            authors = b.author or "",
                            file = b.file,
                        })
                    end
                    local added = mergeBooks(new_books)
                    if added == 0 then
                        UIManager:show(InfoMessage:new{
                            text = T(_("All %1 already selected."), #new_books),
                            timeout = 2,
                        })
                        return
                    end
                    refreshInputDialog()
                end,
            }})
        end
        addScannerPreset(_("Currently Reading"), "reading")
        addScannerPreset(_("Recently Finished"), "complete")

        -- Browse History (opens BookPicker)
        table.insert(menu_buttons, {{
            text = _("Browse History…"),
            callback = function()
                UIManager:close(add_books_dialog)
                local BookPicker = require("koassistant_book_picker")
                BookPicker:show({
                    on_confirm = function(selected_files)
                        -- Convert file hash to books_info with proper metadata
                        local DocSettings = require("docsettings")
                        local new_books = {}
                        for file, _v in pairs(selected_files) do
                            local title = nil
                            local author = ""
                            local ds = DocSettings:open(file)
                            local doc_props = ds:readSetting("doc_props")
                            if doc_props then
                                local dt = doc_props.display_title or doc_props.title
                                if dt and dt ~= "" then title = dt end
                                if doc_props.authors and doc_props.authors ~= "" then
                                    author = doc_props.authors:gsub("\n", ", ")
                                end
                            end
                            if not title then
                                title = file:match("([^/]+)%.[^%.]+$") or file
                            end
                            table.insert(new_books, {
                                title = title,
                                authors = author,
                                file = file,
                            })
                        end
                        mergeBooks(new_books)
                        refreshInputDialog()
                    end,
                })
            end,
        }})

        -- Clear Selection (only if books are selected)
        if book_count > 0 then
            table.insert(menu_buttons, {{
                text = _("Clear Selection"),
                callback = function()
                    UIManager:close(add_books_dialog)
                    configuration.features = configuration.features or {}
                    configuration.features.books_info = nil
                    configuration.features.book_context = nil
                    configuration.features.book_metadata = nil
                    refreshInputDialog()
                end,
            }})
        end

        add_books_dialog = ButtonDialog:new{
            title = book_count > 0
                and T(book_count == 1 and _("%1 item selected") or _("%1 items selected"), book_count)
                or _("Add Items"),
            buttons = menu_buttons,
        }
        UIManager:show(add_books_dialog)
    end

    -- Library context: view and remove selected books
    -- Rebuilds book_context after removal; reopens itself unless list is emptied
    local function showSelectedBooksEditor()
        local books = configuration and configuration.features and configuration.features.books_info
        if not books or #books == 0 then return end

        local ButtonDialog = require("ui/widget/buttondialog")
        local editor_dialog
        local menu_buttons = {}

        -- Helper: rebuild book_context from current books_info
        local function rebuildBookContext()
            local current = configuration.features.books_info
            if not current or #current == 0 then
                configuration.features.books_info = nil
                configuration.features.book_context = nil
                configuration.features.book_metadata = nil
                return
            end
            local parts = {}
            for i, b in ipairs(current) do
                if b.authors and b.authors ~= "" then
                    table.insert(parts, string.format('%d. "%s" by %s', i, b.title, b.authors))
                else
                    table.insert(parts, string.format('%d. "%s"', i, b.title))
                end
            end
            configuration.features.book_context = string.format(
                "Selected %d books:\n\n%s", #current, table.concat(parts, "\n"))
            configuration.features.book_metadata = {
                title = current[1].title,
                author = current[1].authors or "",
            }
        end

        for idx, book in ipairs(books) do
            local label = book.authors and book.authors ~= ""
                and string.format('"%s" by %s', book.title, book.authors)
                or string.format('"%s"', book.title)
            table.insert(menu_buttons, {{
                text = label,
                callback = function()
                    UIManager:close(editor_dialog)
                    table.remove(books, idx)
                    rebuildBookContext()
                    if books and #books > 0 then
                        -- Reopen editor with updated list
                        showSelectedBooksEditor()
                    else
                        refreshInputDialog()
                    end
                end,
            }})
        end

        table.insert(menu_buttons, {{
            text = _("Clear All"),
            callback = function()
                UIManager:close(editor_dialog)
                configuration.features = configuration.features or {}
                configuration.features.books_info = nil
                configuration.features.book_context = nil
                configuration.features.book_metadata = nil
                refreshInputDialog()
            end,
        }})

        table.insert(menu_buttons, {{
            text = _("Done"),
            callback = function()
                UIManager:close(editor_dialog)
                refreshInputDialog()
            end,
        }})

        editor_dialog = ButtonDialog:new{
            title = T(#books == 1 and _("%1 item selected — tap to remove") or _("%1 items selected — tap to remove"), #books),
            buttons = menu_buttons,
        }
        UIManager:show(editor_dialog)
    end

    -- Build all input dialog buttons (called on init and on refresh via reinit)
    local has_more_actions = false  -- Set by buildInputDialogButtons, read by gear menu
    local buildInputDialogButtons
    buildInputDialogButtons = function()
        -- Top row: [Web toggle] [Domain] [Send]
        local top_row = {
            -- 1. Web search toggle (persistent — writes to actual setting)
            {
                text = getWebToggleText(),
                callback = function()
                    configuration.features = configuration.features or {}
                    configuration.features.enable_web_search = not configuration.features.enable_web_search
                    -- Persist to settings
                    if plugin and plugin.settings then
                        local features = plugin.settings:readSetting("features") or {}
                        features.enable_web_search = configuration.features.enable_web_search
                        plugin.settings:saveSetting("features", features)
                        plugin.settings:flush()
                    end
                    refreshInputDialog()
                end,
                hold_callback = function()
                    UIManager:show(InfoMessage:new{
                        text = _("Toggle web search for AI requests"),
                        timeout = 2,
                    })
                end,
            },
            -- 2. Domain selector
            {
                text = _("Domain: ") .. getDomainDisplayName(),
                callback = function()
                    showDomainSelector()
                end,
            },
            -- 3. Send (freeform chat with context)
            {
                text = enable_emoji and (_("Send") .. " ➤") or _("Send"),
            callback = function()
                -- Block empty sends for contexts without highlighted text (nothing useful to send)
                local typed_text = input_dialog:getInputText()
                if (not typed_text or typed_text == "") and not highlighted_text then
                    UIManager:show(InfoMessage:new{
                        text = _("Type a message first, or tap an action button."),
                        timeout = 2,
                    })
                    return
                end
                UIManager:close(input_dialog)
                -- Note: Loading dialog now handled by handleNonStreamingBackground in gpt_query.lua
                UIManager:scheduleIn(0.1, function()
                    -- NEW ARCHITECTURE (v0.5.2+): Unified request config for all providers
                    -- System prompt and domain are built by buildUnifiedRequestConfig

                    -- Get domain context if a domain is selected (for passing to buildUnifiedRequestConfig)
                    -- Priority: book domain > global selected_domain
                    -- book_domain_id "_none" = explicit override to no domain
                    local domain_id
                    if book_domain_id == "_none" then
                        domain_id = nil
                    else
                        domain_id = book_domain_id or selected_domain
                    end
                    local domain_context = nil
                    if domain_id then
                        local DomainLoader = require("domain_loader")
                        -- Get custom domains from configuration for lookup
                        local custom_domains = configuration and configuration.features and configuration.features.custom_domains or {}
                        local domain = DomainLoader.getDomainById(domain_id, custom_domains)
                        if domain then
                            domain_context = domain.context
                        end
                    end

                    -- Create history WITHOUT system prompt (system is in config.system)
                    -- No prompt_action for Send — title uses user question or highlight directly
                    local history = MessageHistory:new(nil, nil)

                    -- Store source data for title generation
                    if highlighted_text and highlighted_text ~= "" then
                        history.source_highlight = highlighted_text
                    end

                    -- Store domain in history for saving with chat
                    if domain_id then
                        history.domain = domain_id
                    end

                    -- Build consolidated message parts (no system/domain - they're in config.system now)
                    local parts = {}

                    -- Add appropriate context
                    if configuration.features.is_library_context then
                        -- For library context, include selected books and/or library scan
                        local lib_context = configuration.features.book_context
                        if lib_context then
                            table.insert(parts, "[Context]")
                            table.insert(parts, lib_context)
                            table.insert(parts, "")
                        end
                        -- Auto-attach library scan data when scanning is available
                        local lib_features = plugin and plugin.settings and plugin.settings:readSetting("features") or {}
                        if lib_features.enable_library_scanning == true
                                and lib_features.library_scan_folders and #lib_features.library_scan_folders > 0 then
                            local scan_ok, LibraryScanner = pcall(require, "koassistant_library_scanner")
                            if scan_ok and LibraryScanner then
                                local scan_result = LibraryScanner.scan(lib_features)
                                if scan_result and scan_result.books and #scan_result.books > 0 then
                                    local formatted = LibraryScanner.format(scan_result)
                                    if formatted and formatted ~= "" then
                                        table.insert(parts, "My library:")
                                        table.insert(parts, formatted)
                                        table.insert(parts, "")
                                    end
                                end
                            end
                        end
                    elseif configuration.features.is_book_context then
                        -- For book context (file browser or gesture action), include book metadata
                        table.insert(parts, "[Context]")
                        if book_metadata then
                            table.insert(parts, string.format('Book: "%s"%s',
                                book_metadata.title or "Unknown",
                                (book_metadata.author and book_metadata.author ~= "") and (" by " .. book_metadata.author) or ""))
                        elseif highlighted_text then
                            -- Fallback to highlighted_text if it contains formatted book info
                            table.insert(parts, highlighted_text)
                        end
                        table.insert(parts, "")
                    elseif configuration.features.is_general_context then
                        -- For general context, no initial context needed
                        -- User will provide their question/prompt
                    elseif highlighted_text then
                        -- For highlighted text context - always include book info if available
                        table.insert(parts, "[Context]")
                        if book_metadata and book_metadata.title then
                            table.insert(parts, string.format('From "%s"%s',
                                book_metadata.title,
                                (book_metadata.author and book_metadata.author ~= "") and (" by " .. book_metadata.author) or ""))
                            table.insert(parts, "")
                        end
                        -- Inject X-Ray context framing before selected text (explains source)
                        if xray_context_prefix then
                            table.insert(parts, xray_context_prefix)
                            table.insert(parts, "")
                        end
                        table.insert(parts, "Selected text:")
                        table.insert(parts, '"' .. highlighted_text .. '"')
                        table.insert(parts, "")
                    end

                    -- Get user's typed question
                    local question = input_dialog:getInputText()
                    local has_user_question = question and question ~= ""

                    -- Store user question for title generation
                    if has_user_question then
                        history.source_input = question
                    end

                    -- Add user question to context message
                    if has_user_question then
                        table.insert(parts, "[User Question]")
                        table.insert(parts, question)
                    end

                    -- Create the consolidated message (sent to AI as context)
                    local consolidated_message = table.concat(parts, "\n")
                    history:addUserMessage(consolidated_message, true)

                    -- Build unified request config for ALL providers
                    -- No action specified, uses global behavior setting
                    buildUnifiedRequestConfig(configuration, domain_context, nil, plugin)

                    -- Callback to handle response (for both streaming and non-streaming)
                    local function onResponseReady(success, answer, err, reasoning, web_search_used)
                        if success and answer then
                            -- If user typed a question, add it as a visible message before the response
                            if has_user_question then
                                history:addUserMessage(question, false)
                            end
                            history:addAssistantMessage(answer, ConfigHelper:getModelInfo(configuration), reasoning, ConfigHelper:buildDebugInfo(configuration), web_search_used)

                            local function addMessage(message, is_context, on_complete)
                                history:addUserMessage(message, is_context)
                                local answer_result = queryChatGPT(history:getMessages(), configuration, function(msg_success, msg_answer, msg_err, msg_reasoning, msg_web_search_used)
                                    if msg_success and msg_answer then
                                        history:addAssistantMessage(msg_answer, ConfigHelper:getModelInfo(configuration), msg_reasoning, ConfigHelper:buildDebugInfo(configuration), msg_web_search_used)
                                    end
                                    if on_complete then on_complete(msg_success, msg_answer, msg_err, msg_reasoning, msg_web_search_used) end
                                end, plugin and plugin.settings)
                                if not isStreamingInProgress(answer_result) then
                                    return answer_result
                                end
                                return nil
                            end

                            closeLoadingDialog()
                            showResponseDialog(_("Chat"), history, highlighted_text, addMessage, configuration, document_path, plugin, book_metadata, launch_context, ui_instance)
                        else
                            closeLoadingDialog()
                            UIManager:show(InfoMessage:new{
                                text = _("Error: ") .. (err or "Unknown error"),
                                timeout = 3
                            })
                        end
                    end

                    -- Get initial response with callback
                    local result = queryChatGPT(history:getMessages(), configuration, onResponseReady, plugin and plugin.settings)
                    -- If not streaming, callback was already invoked
                end)
            end,
            hold_callback = function()
                local hint
                if highlighted_text then
                    hint = _("Send your typed message (or the selected text) as a freeform chat to the AI, without using any action template.")
                else
                    hint = _("Send your typed message as a freeform chat to the AI, without using any action template.")
                end
                UIManager:show(InfoMessage:new{
                    text = hint,
                    timeout = 4,
                })
            end,
        }
    }

        -- Action buttons (collected separately, then arranged in rows of 2)
        local action_buttons = {}
        local prompts, prompt_keys
        -- Use per-context ordering for non-general contexts
        local action_service = plugin and plugin.action_service
        if input_context ~= "general" and action_service then
            local ordered_actions = action_service:getInputActionObjects(input_context)
            prompts = {}
            prompt_keys = {}
            for _idx, action in ipairs(ordered_actions) do
                local key = action.id or ("prompt_" .. #prompt_keys + 1)
                prompts[key] = action
                table.insert(prompt_keys, key)
            end
            logger.info("buildInputDialogButtons: Got " .. #prompt_keys .. " prompts from input context: " .. input_context)
        else
            prompts, prompt_keys = getAllPrompts(configuration, plugin)
            logger.info("buildInputDialogButtons: Got " .. #prompt_keys .. " prompts from getAllPrompts")
        end
    -- Pre-compute availability state for button graying
    local selected_book_count = 0
    local avail_features = configuration and configuration.features or {}
    -- Library scan check applies to all contexts (suggest_from_library is a book action)
    local library_scan_available = avail_features.enable_library_scanning == true
        and avail_features.library_scan_folders and #avail_features.library_scan_folders > 0
    if input_context == "library" then
        local books = avail_features.books_info
        selected_book_count = books and #books or 0
    end

    -- Check if an action's prerequisites are met (for enabled/disabled state)
    local function isActionAvailable(action)
        if not action then return true end
        if action.requires_selected_books and selected_book_count < 2 then
            return false
        end
        if action.requires then
            for _idx2, req in ipairs(action.requires) do
                if req == "library" and not library_scan_available then
                    return false
                end
            end
        end
        return true
    end

    for _idx, custom_prompt_type in ipairs(prompt_keys) do
        local prompt = prompts[custom_prompt_type]
        if prompt and prompt.text then
            -- Skip actions with excluded flags (e.g., from X-Ray browser "Chat about this")
            local exclude_flags = exclude_action_flags
            local excluded = false
            if exclude_flags then
                for _idx2, flag in ipairs(exclude_flags) do
                    if prompt[flag] then excluded = true; break end
                end
            end
            if excluded then
                logger.info("Skipping excluded prompt: " .. custom_prompt_type)
            else
                logger.info("Adding button for prompt: " .. custom_prompt_type .. " with text: " .. prompt.text)
                local available = isActionAvailable(prompt)
                table.insert(action_buttons, {
                    text = ActionServiceModule.getActionDisplayText(prompt, (configuration or {}).features),
                    prompt_type = custom_prompt_type,
                    enabled = available,
                    callback = function()
                        executeInputAction(prompt, custom_prompt_type)
                    end
                })
            end
        else
            logger.warn("Skipping prompt " .. custom_prompt_type .. " - missing or invalid")
        end
    end

    -- "Show More Actions…" — compute remaining actions and optionally show in-grid button
    if action_service then
        -- Compute "more actions": enabled actions eligible for this context but not in the favorites list
        local shown_set = {}
        for _idx2, key in ipairs(prompt_keys) do shown_set[key] = true end
        local more_actions = {}
        if input_context == "general" then
            local all_general = action_service:getAllActions("general", false, has_open_book)
            for _idx2, action in ipairs(all_general) do
                if action.id and not shown_set[action.id] and action.enabled then
                    table.insert(more_actions, action)
                end
            end
        else
            local eligible_ids = action_service:_getEligibleInputActionIds(input_context)
            for _idx2, id in ipairs(eligible_ids) do
                if not shown_set[id] then
                    local action = action_service:getAction(nil, id)
                    if action and action.enabled then
                        -- Apply exclude_action_flags filter
                        local excluded = false
                        if exclude_action_flags then
                            for _idx3, flag in ipairs(exclude_action_flags) do
                                if action[flag] then excluded = true; break end
                            end
                        end
                        if not excluded then
                            table.insert(more_actions, action)
                        end
                    end
                end
            end
        end

        has_more_actions = #more_actions > 0

        if show_all_actions then
            -- Expanded: append all remaining actions after favorites
            for _idx2, action in ipairs(more_actions) do
                local available = isActionAvailable(action)
                table.insert(action_buttons, {
                    text = ActionServiceModule.getActionDisplayText(action, (configuration or {}).features),
                    prompt_type = action.id,
                    enabled = available,
                    callback = function()
                        executeInputAction(action, action.id)
                    end
                })
            end
        elseif #more_actions > 0 and input_context ~= "general" then
            -- Collapsed: show in-grid button (non-general only; general uses gear menu toggle)
            table.insert(action_buttons, {
                text = _("Show More Actions…"),
                callback = function()
                    show_all_actions = true
                    refreshInputDialog()
                end,
            })
        end
    end

    -- Build View Artifacts button (shows cached artifacts + pinned)
    -- Always "View Artifacts" text, always shows popup selector with metadata
    local artifact_button = nil
    if not is_general_context and plugin and not hide_artifacts then
        local artifact_file = document_path
        if artifact_file then
            local ActionCache = require("koassistant_action_cache")
            local open_doc = ui_instance and ui_instance.document or nil
            local caches = ActionCache.getAvailableArtifactsWithPinned(artifact_file, nil, open_doc)

            local function openArtifact(cache, on_select)
                if cache.is_section_xray_group then
                    local ArtifactBrowser = require("koassistant_artifact_browser")
                    local AskGPT = plugin
                    ArtifactBrowser:_showSectionXrayGroupPopup(
                        cache.data, artifact_file,
                        book_metadata and book_metadata.title, AskGPT,
                        cache._excluded_section_key, on_select)
                elseif cache.is_section_group then
                    local ArtifactBrowser = require("koassistant_artifact_browser")
                    ArtifactBrowser:_showSectionGroupPopup(
                        cache.data, artifact_file,
                        book_metadata and book_metadata.title, plugin,
                        cache.section_type, cache._excluded_section_key, on_select)
                elseif cache.is_wiki_group then
                    local ArtifactBrowser = require("koassistant_artifact_browser")
                    ArtifactBrowser:_showWikiGroupPopup(cache.data, artifact_file, plugin,
                        book_metadata and book_metadata.title, on_select)
                elseif cache.is_pinned_group then
                    local ArtifactBrowser = require("koassistant_artifact_browser")
                    ArtifactBrowser:_showPinnedGroupPopup(cache.data, artifact_file,
                        book_metadata and book_metadata.title, on_select)
                elseif cache.is_per_action then
                    plugin:viewCachedAction({ text = cache.name }, cache.key, cache.data,
                        { file = artifact_file, book_title = book_metadata and book_metadata.title })
                else
                    plugin:showCacheViewer(cache)
                end
            end

            local function formatDisplayText(cache)
                if cache.is_pinned_group or cache.is_section_group or cache.is_wiki_group then
                    return cache.name
                end
                return formatArtifactDisplayText(cache)
            end

            if #caches > 0 then
                artifact_button = {
                    text = Constants.getEmojiText("\u{1F4E6}", _("View Artifacts"), enable_emoji),
                    callback = function()
                        -- Don't close input dialog yet — only close when an artifact is selected
                        input_dialog:onCloseKeyboard()
                        local ButtonDialog = require("ui/widget/buttondialog")
                        local btn_rows = {}
                        for _idx, cache in ipairs(caches) do
                            table.insert(btn_rows, {{
                                text = formatDisplayText(cache),
                                callback = function()
                                    if cache.is_section_group or cache.is_wiki_group or cache.is_pinned_group then
                                        local selector = plugin._cache_selector
                                        openArtifact(cache, function()
                                            UIManager:close(selector)
                                            UIManager:close(input_dialog)
                                            if plugin then plugin.current_input_dialog = nil end
                                        end)
                                    else
                                        UIManager:close(plugin._cache_selector)
                                        UIManager:close(input_dialog)
                                        if plugin then plugin.current_input_dialog = nil end
                                        openArtifact(cache)
                                    end
                                end,
                            }})
                        end
                        table.insert(btn_rows, {{
                            text = _("Cancel"),
                            callback = function()
                                UIManager:close(plugin._cache_selector)
                            end,
                        }})
                        plugin._cache_selector = ButtonDialog:new{
                            title = _("View Artifacts"),
                            buttons = btn_rows,
                        }
                        UIManager:show(plugin._cache_selector)
                    end
                }
            end
        end
    end

        -- Organize into rows: top row (3 buttons), then action rows of 2
        local button_rows = { top_row }

        -- Library context: add book selection row below top row
        if input_context == "library" then
            local books = configuration and configuration.features and configuration.features.books_info
            local book_count = books and #books or 0
            local selection_row = {
                {
                    text = _("+ Add Items"),
                    callback = function()
                        showAddBooksMenu()
                    end,
                },
            }
            if book_count > 0 then
                table.insert(selection_row, {
                    text = T(_("View/Edit (%1)"), book_count),
                    callback = function()
                        showSelectedBooksEditor()
                    end,
                })
            end
            table.insert(button_rows, selection_row)
        end

        local current_row = {}
        for _idx, button in ipairs(action_buttons) do
            table.insert(current_row, button)
            if #current_row == 2 then
                table.insert(button_rows, current_row)
                current_row = {}
            end
        end
        -- Artifact pairing: pair with last action if odd count, else solo row
        if artifact_button then
            if #current_row == 1 then
                -- Odd action count: pair last action with artifact
                table.insert(current_row, artifact_button)
                table.insert(button_rows, current_row)
            else
                -- Even action count (or zero): flush remaining, then artifact solo
                if #current_row > 0 then
                    table.insert(button_rows, current_row)
                end
                table.insert(button_rows, { artifact_button })
            end
        elseif #current_row > 0 then
            table.insert(button_rows, current_row)
        end

        -- Non-bold buttons for lighter visual feel
        for _ri, btn_row in ipairs(button_rows) do
            for _bi, btn in ipairs(btn_row) do
                btn.font_bold = false
            end
        end

        return button_rows
    end

    -- Refresh dialog by close-and-reopen (reinit loses title bar X and causes visual glitches)
    refreshInputDialog = function()
        if not input_dialog then return end
        local current_text = input_dialog:getInputText()
        UIManager:close(input_dialog)
        if plugin then plugin.current_input_dialog = nil end
        -- Re-set transient flags for the reopen
        if configuration and configuration.features then
            if is_xray_chat then configuration.features._xray_chat_context = true end
            if hide_artifacts then configuration.features._hide_artifacts = true end
            if exclude_action_flags then configuration.features._exclude_action_flags = exclude_action_flags end
            if xray_context_prefix then configuration.features._xray_context_prefix = xray_context_prefix end
            if show_all_actions then configuration.features._show_all_actions = true end
        end
        showChatGPTDialog(ui_instance, highlighted_text, configuration, nil, plugin, book_metadata, current_text)
    end

    -- Show the dialog with the button rows
    local is_multi = config and config.features and config.features.is_library_context
    local multi_count = is_multi and config.features.books_info and #config.features.books_info or 0
    local dialog_title
    local input_hint_text
    if is_multi then
        if multi_count > 0 then
            dialog_title = T(multi_count == 1 and _("Library Actions \xC2\xB7 %1 item") or _("Library Actions \xC2\xB7 %1 items"), multi_count)
            input_hint_text = _("Add instructions or ask about selected items...")
        else
            dialog_title = _("Library Actions")
            input_hint_text = _("Chat about your library, or add items for multi-book actions...")
        end
    else
        dialog_title = _("KOAssistant Actions")
        input_hint_text = _("Type your question or additional instructions for any action...")
    end
    input_dialog = InputDialog:new{
        title = dialog_title,
        input = initial_input or "",
        input_hint = input_hint_text,
        input_type = "text",
        buttons = buildInputDialogButtons(),
        input_height = 6,
        allow_newline = true,
        input_multiline = true,
        text_height = 300,
        -- Settings icon in title bar — opens anchored gear menu
        title_bar_left_icon = "appbar.settings",
        title_bar_left_icon_tap_callback = function()
            input_dialog:onCloseKeyboard()
            local gear_menu
            gear_menu = ButtonDialog:new{
                buttons = {
                    {{ text = _("Quick Settings"), callback = function()
                        UIManager:close(gear_menu)
                        if plugin then
                            plugin:onKOAssistantAISettings(function()
                                plugin:updateConfigFromSettings()
                                refreshInputDialog()
                            end)
                        end
                    end }},
                    {{ text = _("Choose and Sort Actions…"), callback = function()
                        UIManager:close(gear_menu)
                        if not plugin then return end
                        local PromptsManager = require("koassistant_ui/prompts_manager")
                        PromptsManager:new(plugin):showInputActionsManager(input_context, function()
                            -- Defer refresh to next tick so sorting manager is fully removed first
                            UIManager:nextTick(function()
                                refreshInputDialog()
                            end)
                        end)
                    end }},
                    {{ text = show_all_actions and _("Show Fewer Actions") or _("Show More Actions…"),
                        enabled = show_all_actions or has_more_actions,
                        callback = function()
                        UIManager:close(gear_menu)
                        show_all_actions = not show_all_actions
                        refreshInputDialog()
                    end }},
                },
                shrink_unneeded_width = true,
                anchor = function()
                    return input_dialog.title_bar.left_button.image.dimen, true
                end,
            }
            UIManager:show(gear_menu)
        end,
    }

    -- Add close X to title bar (InputDialog doesn't natively pass close_callback to TitleBar)
    -- Also use regular weight font for title (default x_smalltfont is NotoSans-Bold)
    local Font = require("ui/font")
    input_dialog.title_bar.close_callback = function()
        UIManager:close(input_dialog)
        if plugin then plugin.current_input_dialog = nil end
    end
    input_dialog.title_bar.title_face = Font:getFace("smallinfofont")
    input_dialog.title_bar:init()

    -- Lighter input field border (default is COLOR_DARK_GRAY; use mid-gray for subtlety)
    local Blitbuffer = require("ffi/blitbuffer")
    input_dialog._input_widget._frame_textwidget.color = Blitbuffer.COLOR_GRAY

    -- Enable tap-outside-to-close (InputDialog's onCloseDialog looks for id="close" button
    -- which we removed; override to close directly)
    input_dialog.onCloseDialog = function()
        UIManager:close(input_dialog)
        if plugin then plugin.current_input_dialog = nil end
        return true
    end

    -- Rotation support via in-place refresh (no close-and-reopen gap)
    input_dialog.onScreenResize = function(self, dimen)
        refreshInputDialog()
        return true
    end
    input_dialog.onSetRotationMode = function(self, rotation)
        return self:onScreenResize(nil)
    end

    -- If a prompt_type is specified, automatically trigger it after dialog is shown
    if prompt_type then
        UIManager:show(input_dialog)
        UIManager:scheduleIn(0.1, function()
            UIManager:close(input_dialog)

            -- Find and trigger the corresponding button
            for _idx, row in ipairs(input_dialog.buttons or {}) do
                for _idx2, button in ipairs(row) do
                    if button.prompt_type == prompt_type then
                        button.callback()
                        return
                    end
                end
            end

            -- If no matching prompt found, just close
            UIManager:show(InfoMessage:new{
                text = _("Unknown prompt type: ") .. tostring(prompt_type),
                timeout = 2
            })
        end)
    else
        UIManager:show(input_dialog)
        -- Store reference so other entry points can close this dialog if needed
        if plugin then
            plugin.current_input_dialog = input_dialog
        end
    end
end

-- Calculate current reading progress as a decimal (0.0-1.0) directly from the document
-- Lightweight alternative to ContextExtractor:getReadingProgress() for quick checks
local function getProgressDecimal(ui)
    if not ui or not ui.document then return nil end
    local total_pages = ui.document.info and ui.document.info.number_of_pages or 0
    if total_pages == 0 then return nil end
    local current_page
    if ui.document.info.has_pages then
        current_page = ui.view and ui.view.state and ui.view.state.page or 1
    else
        local xp = ui.document:getXPointer()
        current_page = xp and ui.document:getPageFromXPointer(xp) or 1
    end
    -- Flow-aware progress when hidden flows active
    if ui.document.hasHiddenFlows and ui.document:hasHiddenFlows() then
        local visible_at_or_before = 0
        local total_visible = 0
        for page = 1, total_pages do
            if ui.document:getPageFlow(page) == 0 then
                total_visible = total_visible + 1
                if page <= current_page then
                    visible_at_or_before = visible_at_or_before + 1
                end
            end
        end
        if total_visible > 0 then
            return visible_at_or_before / total_visible
        end
    end
    return current_page / total_pages
end

-- Open X-Ray browser with cached data and metadata
-- Returns the XrayBrowser module for chaining (e.g., showItemDetail, showSearchResults)
local function openXrayBrowserFromCache(ui, data, cached, config, plugin, book_metadata, best, cleanup_widgets)
    local XrayBrowser = require("koassistant_xray_browser")
    local ActionCache = require("koassistant_action_cache")
    local Notification = require("ui/widget/notification")
    local config_features = (config or {}).features or {}

    local book_title = (book_metadata and book_metadata.title) or ""
    local source_label = cached.used_book_text == false
        and _("Based on AI training data knowledge")
        or _("Based on extracted document text")
    local formatted_date = cached.timestamp
        and os.date("%Y-%m-%d", cached.timestamp)

    local browser_metadata = {
        title = book_title,
        progress = cached.progress_decimal and
            (math.floor(cached.progress_decimal * 100 + 0.5) .. "%"),
        model = cached.model,
        timestamp = cached.timestamp,
        book_file = ui and ui.document and ui.document.file,
        enable_emoji = config_features.enable_emoji_icons == true,
        configuration = config,
        plugin = plugin,
        source_label = source_label,
        formatted_date = formatted_date,
        progress_decimal = cached.progress_decimal,
        full_document = cached.full_document,
        previous_progress = cached.previous_progress_decimal and
            (math.floor(cached.previous_progress_decimal * 100 + 0.5) .. "%"),
        cache_metadata = {
            cache_type = "xray",
            book_title = book_title,
            progress_decimal = cached.progress_decimal,
            model = cached.model,
            timestamp = cached.timestamp,
            used_annotations = cached.used_annotations,
            used_book_text = cached.used_book_text,
        },
    }

    -- Section X-Ray: set scope metadata and override progress display
    if best and best.is_section then
        local scope_start = cached.scope_start_page
        local scope_end = cached.scope_end_page
        local scope_summary = cached.scope_page_summary
        -- Reconvert XPointers to current pages if book is open
        local doc = ui and ui.document
        if doc and doc.getPageFromXPointer and cached.scope_start_xpointer then
            local new_start = doc:getPageFromXPointer(cached.scope_start_xpointer)
            if new_start then scope_start = new_start end
            if cached.scope_end_xpointer then
                local new_end = doc:getPageFromXPointer(cached.scope_end_xpointer)
                if new_end then scope_end = new_end - 1 end
            else
                local total = doc.info.number_of_pages or 0
                if doc.hasHiddenFlows and doc:hasHiddenFlows() then
                    for page = total, 1, -1 do
                        if doc:getPageFlow(page) == 0 then scope_end = page; break end
                    end
                else
                    scope_end = total
                end
            end
            local vis_start = doc.getPageNumberInFlow and doc:getPageNumberInFlow(scope_start) or scope_start
            local vis_end = doc.getPageNumberInFlow and doc:getPageNumberInFlow(scope_end) or scope_end
            scope_summary = T(_("pp %1–%2"), vis_start, vis_end)
        end
        browser_metadata.scope = {
            label = best.label or cached.scope_label,
            start_page = scope_start,
            end_page = scope_end,
            page_summary = scope_summary,
            cache_key = best.key,
        }
        browser_metadata.progress = _("Complete")
        browser_metadata.full_document = true
    end

    -- Pass cleanup widgets so browser can close them when launching book text search
    browser_metadata._cleanup_widgets = cleanup_widgets

    XrayBrowser:show(data, browser_metadata, ui, function()
        ActionCache.clearXrayCache(ui.document.file)
        UIManager:show(Notification:new{
            text = T(_("%1 deleted"), "X-Ray"),
            timeout = 2,
        })
    end)
    return XrayBrowser
end

-- Show cross-section X-Ray search results as a standalone picker Menu.
-- @param grouped_results table From ActionCache.searchAllXrays()
-- @param query string The search query
-- @param ui table UI context
-- @param config table Configuration
-- @param plugin table Plugin reference
-- @param book_metadata table Book metadata
local function showCrossSectionResults(grouped_results, query, ui, config, plugin, book_metadata, cleanup_widgets)
    local Menu = require("ui/widget/menu")
    local XrayParser = require("koassistant_xray_parser")

    -- Count total results across all X-Rays
    local total_results = 0
    for _idx, group in ipairs(grouped_results) do
        total_results = total_results + #group.results
    end

    local items = {}
    for _idx, group in ipairs(grouped_results) do
        -- Section header (non-tappable separator)
        local header_label
        if not group.is_section then
            header_label = _("Main X-Ray")
        else
            header_label = group.label or ""
            if group.scope_summary and group.scope_summary ~= "" then
                header_label = header_label .. " (" .. group.scope_summary .. ")"
            end
        end
        if group.in_range then
            header_label = "▸ " .. header_label
        end
        table.insert(items, {
            text = header_label,
            bold = true,
            dim = false,
            separator = true,
            callback = function() end, -- non-tappable but needs callback for Menu
        })

        -- Result items under this section
        for _idx2, result in ipairs(group.results) do
            local item_name = XrayParser.getItemName(result.item, result.category_key)
            local match_label = result.category_label
            if result.match_field == "alias" then
                match_label = match_label .. " (" .. _("alias") .. ")"
            elseif result.match_field == "description" then
                match_label = match_label .. " (" .. _("desc.") .. ")"
            end

            local captured_group = group
            local captured_result = result
            local captured_name = item_name
            table.insert(items, {
                text = "  " .. item_name,
                mandatory = match_label,
                mandatory_dim = true,
                callback = function()
                    -- Open that section's X-Ray browser at this item
                    local best = {
                        entry = captured_group.cache_entry,
                        key = captured_group.key,
                        is_section = captured_group.is_section,
                        label = captured_group.label,
                    }
                    local data = XrayParser.parse(captured_group.cache_entry.result)
                    if not data then return end
                    local XrayBrowser = openXrayBrowserFromCache(
                        ui, data, captured_group.cache_entry, config, plugin, book_metadata, best,
                        cleanup_widgets)
                    XrayBrowser:showItemDetail(
                        captured_result.item, captured_result.category_key, captured_name)
                end,
            })
        end
    end

    local title = T(_("Results for \"%1\" (%2 across %3)"),
        query, total_results, #grouped_results)

    local results_menu = Menu:new{
        title = title,
        item_table = items,
        is_borderless = true,
        is_popout = false,
        width = Screen:getWidth(),
        height = Screen:getHeight(),
        single_line = true,
        items_font_size = 18,
        items_mandatory_font_size = 14,
        -- No close_callback (Menu calls it after EVERY item tap, not just X button)
        -- No onReturn (hides the return arrow; X button works via Menu's default onClose)
    }

    -- Add results menu to cleanup list so browser can close it during book text search
    if cleanup_widgets then
        table.insert(cleanup_widgets, results_menu)
    end

    UIManager:show(results_menu)
end

-- Handle local X-Ray lookup: search cached X-Ray data for the query
-- @param override_best table|nil Pre-selected X-Ray result (from selection popup callback)
local function handleLocalXrayLookup(ui, query, document_path, book_metadata, config, plugin, override_best)
    local logger = require("logger")
    logger.info("KOAssistant: Local X-Ray lookup for: " .. tostring(query))

    if not document_path then
        UIManager:show(InfoMessage:new{
            text = _("No book open. X-Ray lookup requires an open book."),
            timeout = 3,
        })
        return
    end

    local ActionCache = require("koassistant_action_cache")
    local doc = ui and ui.document

    -- Build cleanup list: widgets to close when browser launches book text search.
    -- Prevents dictionary popup and cross-section results from blocking search highlights.
    local cleanup_widgets = {}
    local source_widget = config and config.features and config.features._source_widget
    if source_widget then
        table.insert(cleanup_widgets, source_widget)
    end

    -- Cross-section search: when multiple X-Rays exist and no override, search all
    if not override_best then
        local sections = ActionCache.getSectionXrays(document_path)
        local main = ActionCache.getXrayCache(document_path)
        local total_xrays = #sections + (main and main.result and 1 or 0)

        if total_xrays == 0 then
            UIManager:show(InfoMessage:new{
                text = _("No X-Ray cache found for this book. Generate one first via the X-Ray action."),
                timeout = 4,
            })
            return
        end

        if total_xrays > 1 then
            -- Multiple X-Rays: search across all (name + alias only for lookup)
            local grouped = ActionCache.searchAllXrays(document_path, query, doc, { skip_description = true })
            if #grouped == 0 then
                -- No results anywhere
                UIManager:show(InfoMessage:new{
                    text = T(_("No results for \"%1\" across %2 X-Rays."), query, total_xrays),
                    timeout = 5,
                })
                return
            elseif #grouped == 1 then
                -- Results in only 1 X-Ray: use standard single-X-Ray flow
                override_best = {
                    entry = grouped[1].cache_entry,
                    key = grouped[1].key,
                    is_section = grouped[1].is_section,
                    label = grouped[1].label,
                }
                -- Fall through to existing single-X-Ray handling below
            else
                -- Results in multiple X-Rays: show cross-section results
                showCrossSectionResults(grouped, query, ui, config, plugin, book_metadata, cleanup_widgets)
                return
            end
        end
    end

    -- Find best X-Ray: prefer section covering current page, fall back to main
    local best = override_best or ActionCache.findBestXray(document_path, doc)

    if not best then
        UIManager:show(InfoMessage:new{
            text = _("No X-Ray cache found for this book. Generate one first via the X-Ray action."),
            timeout = 4,
        })
        return
    end

    -- Multiple sections available: let user pick which one to search
    if best.needs_selection then
        local ButtonDialog = require("ui/widget/buttondialog")
        local sec_selector
        local btn_rows = {}
        for _idx, sec in ipairs(best.sections) do
            local page_info = ActionCache.reconvertPageSummary(sec.data, doc)
            local label = sec.label
            if page_info ~= "" then
                label = label .. " (" .. page_info .. ")"
            end
            local captured_sec = sec
            table.insert(btn_rows, {{
                text = label,
                callback = function()
                    UIManager:close(sec_selector)
                    handleLocalXrayLookup(ui, query, document_path, book_metadata, config, plugin,
                        { entry = captured_sec.data, key = captured_sec.key, is_section = true, label = captured_sec.label })
                end,
            }})
        end
        sec_selector = ButtonDialog:new{
            title = T(_("Look up \"%1\" in which X-Ray?"), query),
            buttons = btn_rows,
        }
        UIManager:show(sec_selector)
        return
    end

    local cached = best.entry

    -- Parse the cached JSON
    local XrayParser = require("koassistant_xray_parser")
    local data = XrayParser.parse(cached.result)

    if not data then
        UIManager:show(InfoMessage:new{
            text = _("Could not parse X-Ray data. Try regenerating the X-Ray cache."),
            timeout = 3,
        })
        return
    end

    -- Search name + alias only (description matches are noise for dictionary lookup)
    local results = XrayParser.searchAll(data, query, { skip_description = true })

    -- Calculate progress gap (only for main X-Ray; sections cover fixed ranges)
    local current_progress = getProgressDecimal(ui)
    local cache_progress = cached.progress_decimal
    local progress_gap = nil
    if not best.is_section and current_progress and cache_progress then
        progress_gap = current_progress - cache_progress
    end

    if #results == 0 then
        -- No results
        local msg = T(_("No results for \"%1\" in X-Ray."), query)
        if best.is_section and best.label then
            msg = T(_("No results for \"%1\" in Section X-Ray: %2."), query, best.label)
        end
        if progress_gap and progress_gap > 0.08 then
            local cache_pct = math.floor(cache_progress * 100 + 0.5)
            local current_pct = math.floor(current_progress * 100 + 0.5)
            msg = msg .. "\n\n" .. T(_("X-Ray covers to %1% (you're at %2%). Updating may find this entry."), cache_pct, current_pct)
        end
        UIManager:show(InfoMessage:new{
            text = msg,
            timeout = 5,
        })
    else
        -- Open X-Ray browser directly
        local XrayBrowser = openXrayBrowserFromCache(ui, data, cached, config, plugin, book_metadata, best,
            #cleanup_widgets > 0 and cleanup_widgets or nil)

        if #results == 1 then
            -- Single result: navigate directly to item detail
            local result = results[1]
            local name = XrayParser.getItemName(result.item, result.category_key)
            XrayBrowser:showItemDetail(result.item, result.category_key, name)
        else
            -- Multiple results: show search results in browser
            -- Skip "Search other X-Rays" button — cross-section search already ran
            XrayBrowser:showSearchResults(query, true)
        end

        -- Show progress staleness popup (main X-Ray only; sections cover fixed ranges)
        if not best.is_section then
            local book_file = ui.document and ui.document.file
            local dismissed = book_file and plugin._xray_stale_dismissed
                and plugin._xray_stale_dismissed[book_file] == cache_progress
            if not dismissed and progress_gap and progress_gap > 0.08 and plugin then
                local ButtonDialog = require("ui/widget/buttondialog")
                local cache_pct = math.floor(cache_progress * 100 + 0.5)
                local ContextExtractor = require("koassistant_context_extractor")
                local extractor = ContextExtractor:new(ui)
                local current = extractor:getReadingProgress()
                local info_text = T(_("X-Ray covers to %1%"), cache_pct)
                info_text = info_text .. "\n" .. T(_("You're now at %1%."), current.percent)

                local stale_dialog
                stale_dialog = ButtonDialog:new{
                    title = info_text,
                    buttons = {
                        {{
                            text = T(_("Update X-Ray (to %1)"), current.formatted),
                            callback = function()
                                UIManager:close(stale_dialog)
                                if XrayBrowser.menu then
                                    UIManager:close(XrayBrowser.menu)
                                end
                                local action = plugin.action_service:getAction("book", "xray")
                                if action then
                                    if plugin:_checkRequirements(action) then return end
                                    plugin:_executeBookLevelActionDirect(action, "xray")
                                end
                            end,
                        }},
                        {{
                            text = _("Don't remind me this session"),
                            callback = function()
                                UIManager:close(stale_dialog)
                                if not plugin._xray_stale_dismissed then
                                    plugin._xray_stale_dismissed = {}
                                end
                                plugin._xray_stale_dismissed[book_file] = cache_progress
                            end,
                        }},
                    },
                }
                UIManager:show(stale_dialog)
            end
        end
    end
end

-- Dispatch a local (non-AI) action handler
local function handleLocalAction(handler_name, ui, highlighted_text, document_path, book_metadata, config, plugin)
    local logger = require("logger")

    if handler_name == "xray_lookup" then
        handleLocalXrayLookup(ui, highlighted_text, document_path, book_metadata, config, plugin)
    else
        logger.warn("KOAssistant: Unknown local handler: " .. tostring(handler_name))
        UIManager:show(InfoMessage:new{
            text = _("Unknown local action handler"),
            timeout = 2,
        })
    end
end

-- Forward declaration (assigned below executeDirectAction; used by wiki artifact intercept)
local executeActionForResult

-- Execute an action directly without showing the intermediate dialog
-- Used for quick actions from highlight menu
-- @param ui table: The UI instance
-- @param action table: The action object (already resolved)
-- @param highlighted_text string: The highlighted text
-- @param configuration table: The configuration table
-- @param plugin table: The plugin instance
local function executeDirectAction(ui, action, highlighted_text, configuration, plugin)
    local logger = require("logger")

    if not action then
        logger.err("KOAssistant: executeDirectAction called without action")
        UIManager:show(InfoMessage:new{
            text = _("Error: No action specified"),
            timeout = 2
        })
        return
    end

    logger.info("KOAssistant: Executing quick action - " .. (action.text or action.id))
    logger.info("KOAssistant: executeDirectAction - configuration.features.book_metadata=",
               configuration and configuration.features and configuration.features.book_metadata and "present" or "nil")
    if configuration and configuration.features and configuration.features.book_metadata then
        logger.info("KOAssistant: executeDirectAction - book_metadata.title=", configuration.features.book_metadata.title or "nil")
    end

    -- Get document info if available
    local document_path = nil
    local book_metadata = nil

    if ui and ui.document then
        local props = ui.doc_props or {}
        document_path = ui.document.file

        -- Extract filename as fallback for missing title metadata
        -- This gives AI something meaningful instead of "Unknown Title"
        local filename_fallback = nil
        if document_path then
            filename_fallback = document_path:match("([^/\\]+)$")  -- Get filename (Unix or Windows path)
            if filename_fallback then
                filename_fallback = filename_fallback:gsub("%.[^%.]+$", "")  -- Remove extension
                filename_fallback = filename_fallback:gsub("[_-]", " ")  -- Convert separators to spaces
            end
        end

        -- Use KOReader's merged metadata (includes user edits), filename as fallback
        local title = props.display_title or props.title
        local author = props.authors
        -- Normalize multi-author strings (KOReader stores as newline-separated)
        if author and author:find("\n") then
            author = author:gsub("\n", ", ")
        end
        book_metadata = {
            title = (title and title ~= "") and title or filename_fallback or "Unknown",
            author = (author and author ~= "") and author or ""  -- Empty, not "Unknown" - less confusing for AI
        }
    end

    -- Fallback for file browser actions: no open document but book metadata has file path
    local cfg_metadata = configuration and configuration.features and configuration.features.book_metadata
    if not document_path and cfg_metadata and cfg_metadata.file then
        document_path = cfg_metadata.file
    end
    if not book_metadata and cfg_metadata then
        book_metadata = {
            title = cfg_metadata.title or "Unknown",
            author = cfg_metadata.author or "",
        }
    end

    -- Handle local-only actions (no AI call)
    if action.local_handler then
        handleLocalAction(action.local_handler, ui, highlighted_text, document_path, book_metadata, configuration, plugin)
        return
    end

    -- Callback for when response is ready
    local function onComplete(history, temp_config_or_error)
        if history then
            local temp_config = temp_config_or_error
            -- Store rerun info for compact/translate view buttons (context toggle, language change)
            -- NOTE: Only store simple/serializable data in features (deepCopy would overflow on complex objects)
            if temp_config and temp_config.features and (temp_config.features.minimal_buttons or temp_config.features.translate_view) then
                -- Store complex objects at config top level (not in features, to avoid deepCopy)
                temp_config._rerun_action = action
                temp_config._rerun_ui = ui
                temp_config._rerun_plugin = plugin
                -- Preserve original context across re-runs (don't overwrite if already set)
                if not temp_config.features._original_context then
                    temp_config.features._original_context = temp_config.features.dictionary_context or ""
                    temp_config.features._original_context_mode = temp_config.features.dictionary_context_mode or "sentence"
                end
            end
            -- For Section X-Ray: open browser directly from section cache
            if configuration and configuration.features and configuration.features._section_xray and ui and ui.document and ui.document.file then
                local ActionCache = require("koassistant_action_cache")
                local scope = configuration.features._section_xray
                local section_cache = ActionCache.get(ui.document.file, scope.cache_key)
                if section_cache and section_cache.result then
                    local XrayParser = require("koassistant_xray_parser")
                    local parsed = XrayParser.parse(section_cache.result)
                    if parsed then
                        local XrayBrowser = require("koassistant_xray_browser")
                        local book_title = (book_metadata and book_metadata.title) or ""
                        local Notification = require("ui/widget/notification")
                        local config_features = (configuration or CONFIGURATION or {}).features or {}
                        local source_label = section_cache.used_book_text == false
                            and _("Based on AI training data knowledge")
                            or _("Based on extracted document text")
                        local formatted_date = section_cache.timestamp
                            and (os.date("%Y-%m-%d", section_cache.timestamp) .. " (" .. _("today") .. ")")
                        XrayBrowser:show(parsed, {
                            title = book_title,
                            progress = "Complete",
                            model = section_cache.model,
                            timestamp = section_cache.timestamp,
                            book_file = ui.document.file,
                            enable_emoji = config_features.enable_emoji_icons == true,
                            configuration = configuration,
                            plugin = plugin,
                            source_label = source_label,
                            formatted_date = formatted_date,
                            progress_decimal = 1.0,
                            full_document = true,
                            used_reasoning = section_cache.used_reasoning,
                            web_search_used = section_cache.web_search_used,
                            scope = {
                                label = scope.label,
                                start_page = scope.start_page,
                                end_page = scope.end_page,
                                page_summary = scope.page_summary,
                                cache_key = scope.cache_key,
                            },
                            cache_metadata = {
                                cache_type = "xray",
                                book_title = book_title,
                                progress_decimal = 1.0,
                                model = section_cache.model,
                                timestamp = section_cache.timestamp,
                                used_book_text = section_cache.used_book_text,
                            },
                        }, ui, function()
                            ActionCache.clear(ui.document.file, scope.cache_key)
                            UIManager:show(Notification:new{
                                text = T(_("Section X-Ray '%1' deleted"), scope.label),
                                timeout = 2,
                            })
                        end)
                        return
                    end
                end
            end
            -- For X-Ray: open browser directly instead of chat viewer
            -- The result is already saved to the X-Ray cache; the chat viewer is unnecessary
            if action.cache_as_xray and ui and ui.document and ui.document.file then
                local ActionCache = require("koassistant_action_cache")
                local xray_cache = ActionCache.getXrayCache(ui.document.file)
                if xray_cache and xray_cache.result then
                    local XrayParser = require("koassistant_xray_parser")
                    local parsed = XrayParser.parse(xray_cache.result)
                    if parsed then
                        local XrayBrowser = require("koassistant_xray_browser")
                        local book_title = (book_metadata and book_metadata.title) or ""
                        local Notification = require("ui/widget/notification")
                        local config_features = (configuration or CONFIGURATION or {}).features or {}
                        local source_label = xray_cache.used_book_text == false
                            and _("Based on AI training data knowledge")
                            or _("Based on extracted document text")
                        local formatted_date = xray_cache.timestamp
                            and (os.date("%Y-%m-%d", xray_cache.timestamp) .. " (" .. _("today") .. ")")
                        XrayBrowser:show(parsed, {
                            title = book_title,
                            progress = xray_cache.progress_decimal and
                                (math.floor(xray_cache.progress_decimal * 100 + 0.5) .. "%"),
                            model = xray_cache.model,
                            timestamp = xray_cache.timestamp,
                            book_file = ui.document.file,
                            enable_emoji = config_features.enable_emoji_icons == true,
                            configuration = configuration,
                            plugin = plugin,
                            source_label = source_label,
                            formatted_date = formatted_date,
                            progress_decimal = xray_cache.progress_decimal,
                            full_document = xray_cache.full_document,
                            previous_progress = xray_cache.previous_progress_decimal and
                                (math.floor(xray_cache.previous_progress_decimal * 100 + 0.5) .. "%"),
                            cache_metadata = {
                                cache_type = "xray",
                                book_title = book_title,
                                progress_decimal = xray_cache.progress_decimal,
                                model = xray_cache.model,
                                timestamp = xray_cache.timestamp,
                                used_annotations = xray_cache.used_annotations,
                                used_book_text = xray_cache.used_book_text,
                            },
                        }, ui, function()
                            ActionCache.clearXrayCache(ui.document.file)
                            UIManager:show(Notification:new{
                                text = T(_("%1 deleted"), "X-Ray"),
                                timeout = 2,
                            })
                        end)
                        return
                    end
                end
            end

            -- For cache-first actions (Recap, X-Ray Simple): open in simple viewer
            -- The result is already saved to ActionCache; the full chat viewer is unnecessary
            if action.use_response_caching and action.id and plugin then
                local ActionCache = require("koassistant_action_cache")
                local file = ui and ui.document and ui.document.file or document_path
                if file then
                    local cached = ActionCache.get(file, action.id)
                    if cached and cached.result then
                        plugin:viewCachedAction(action, action.id, cached, {
                            file = file,
                            book_title = book_metadata and book_metadata.title,
                            book_author = book_metadata and book_metadata.author,
                        })
                        return
                    end
                end
            end

            -- For document analysis/summary: open in cache viewer
            -- (cache_as_xray already handled above with XrayBrowser)
            if (action.cache_as_analyze or action.cache_as_summary) and plugin then
                local ActionCache = require("koassistant_action_cache")
                local file = ui and ui.document and ui.document.file
                if file then
                    local cached, cache_name, cache_key
                    if action.cache_as_analyze then
                        cached = ActionCache.getAnalyzeCache(file)
                        cache_name = _("Analysis")
                        cache_key = "_analyze_cache"
                    else
                        cached = ActionCache.getSummaryCache(file)
                        cache_name = _("Summary")
                        cache_key = "_summary_cache"
                    end
                    if cached and cached.result then
                        plugin:showCacheViewer({ name = cache_name, key = cache_key, data = cached })
                        return
                    end
                end
            end

            local function addMessage(message, is_context, on_complete_msg)
                history:addUserMessage(message, is_context)
                local answer_result = queryChatGPT(history:getMessages(), temp_config, function(success, answer, err, reasoning, web_search_used)
                    if success and answer then
                        history:addAssistantMessage(answer, ConfigHelper:getModelInfo(temp_config), reasoning, ConfigHelper:buildDebugInfo(temp_config), web_search_used)
                    end
                    if on_complete_msg then on_complete_msg(success, answer, err, reasoning, web_search_used) end
                end, plugin and plugin.settings)
                if not isStreamingInProgress(answer_result) then
                    return answer_result
                end
                return nil
            end
            showResponseDialog(action.text, history, highlighted_text, addMessage, temp_config, document_path, plugin, book_metadata, nil, ui)
        else
            local error_msg = temp_config_or_error or "Unknown error"
            UIManager:show(InfoMessage:new{
                text = _("Error: ") .. error_msg,
                timeout = 3
            })
        end
    end

    -- Wiki artifact: intercept wiki action to cache as artifact (like X-Ray browser does)
    if action.id == "wiki" and highlighted_text and highlighted_text ~= "" and document_path then
        local ActionCache = require("koassistant_action_cache")
        local wiki_category = "highlight"
        -- Normalize: trim whitespace, truncate long selections for cache key
        local normalized = highlighted_text:match("^%s*(.-)%s*$") or highlighted_text
        if #normalized > 200 then
            normalized = normalized:sub(1, 200)
        end
        local wiki_key = ActionCache.WIKI_PREFIX .. wiki_category .. ":" .. normalized

        -- Helper: show wiki in simple_view with regenerate/delete
        local function showWikiArtifact(wiki_text)
            local Notification = require("ui/widget/notification")
            local wiki_viewer = ChatGPTViewer:new{
                title = T(_("AI Wiki: %1"), normalized),
                text = wiki_text,
                simple_view = true,
                cache_type_name = _("AI Wiki"),
                configuration = configuration,
                on_regenerate = function()
                    executeActionForResult(action, highlighted_text, ui, configuration, plugin, book_metadata,
                        function(result, meta)
                            if result then
                                ActionCache.setWikiEntry(document_path, wiki_category, normalized, result, meta)
                                showWikiArtifact(result)
                            else
                                UIManager:show(InfoMessage:new{
                                    text = _("Failed to regenerate wiki entry"),
                                    timeout = 3,
                                })
                            end
                        end)
                end,
                regenerate_label = _("Regenerate"),
                on_delete = function()
                    ActionCache.clearWikiEntry(document_path, wiki_category, normalized)
                    UIManager:show(Notification:new{
                        text = _("AI Wiki deleted"),
                        timeout = 2,
                    })
                end,
                _plugin = plugin,
                _artifact_file = document_path,
                _artifact_key = wiki_key,
                _artifact_book_title = book_metadata and book_metadata.title,
                _artifact_book_author = book_metadata and book_metadata.author,
                on_launch_chat = plugin and plugin._buildLaunchChatCallback
                    and plugin:_buildLaunchChatCallback(document_path, book_metadata and book_metadata.title, book_metadata and book_metadata.author, wiki_text, _("AI Wiki")) or nil,
            }
            UIManager:show(wiki_viewer)
        end

        local cached_wiki = ActionCache.getWikiEntry(document_path, wiki_category, normalized)
        if cached_wiki and cached_wiki.result then
            showWikiArtifact(cached_wiki.result)
            return
        end

        -- No cached wiki: run headless, store as artifact, show in simple_view
        executeActionForResult(action, highlighted_text, ui, configuration, plugin, book_metadata,
            function(result, metadata)
                if result then
                    ActionCache.setWikiEntry(document_path, wiki_category, normalized, result, metadata)
                    showWikiArtifact(result)
                else
                    UIManager:show(InfoMessage:new{
                        text = _("Error: ") .. (metadata or "Unknown error"),
                        timeout = 3,
                    })
                end
            end)
        return
    end

    -- Call handlePredefinedPrompt with the action object directly
    -- (avoids re-lookup which fails for special actions not in ActionService cache)
    logger.info("KOAssistant: executeDirectAction calling handlePredefinedPrompt with highlighted_text:", highlighted_text and #highlighted_text or "nil/empty")
    handlePredefinedPrompt(action, highlighted_text, ui, configuration, nil, plugin, nil, onComplete, book_metadata)
end

--- Execute an action and return just the result text + metadata via callback.
--- Thin wrapper around handlePredefinedPrompt for programmatic use (no viewer shown).
--- @param action table Action definition from prompts/actions.lua
--- @param highlighted_text string The text to act on
--- @param ui table KOReader UI instance
--- @param configuration table Plugin configuration
--- @param plugin table Plugin instance
--- @param book_metadata table Book title/author metadata
--- @param on_result function Callback: on_result(result_text, metadata) or on_result(nil, error_string)
executeActionForResult = function(action, highlighted_text, ui, configuration, plugin, book_metadata, on_result)
    handlePredefinedPrompt(action, highlighted_text, ui, configuration, nil, plugin, nil, function(history, temp_config_or_error)
        if history then
            local messages = history:getMessages()
            local last = messages[#messages]
            if last and last.content then
                local model_info = last.model_info
                on_result(last.content, {
                    model = model_info and model_info.model or "",
                    used_reasoning = last.reasoning ~= nil,
                    web_search_used = last.web_search_used or false,
                })
            else
                on_result(nil, "No response received")
            end
        else
            on_result(nil, temp_config_or_error or "Unknown error")
        end
    end, book_metadata)
end

--- Generate document summary cache, then call on_done(true) on success.
--- Used by unified action popup when user selects "Generate summary" source.
--- Chains handlePredefinedPrompt for summarize_full_document with a completion callback.
--- For section scope: clones the action, scopes text extraction, saves to section cache.
--- @param ui table: The UI instance
--- @param configuration table: The configuration table
--- @param plugin table: The plugin instance
--- @param book_metadata table: Book metadata {title, author}
--- @param on_done function(success): Called when summary generation completes
--- @param section_scope table|nil: Section scope for section summary generation
local function generateSummaryCache(ui, configuration, plugin, book_metadata, on_done, section_scope)
    local ok, Actions = pcall(require, "prompts.actions")
    local summary_action = ok and Actions and Actions.book and Actions.book.summarize_full_document

    if not summary_action then
        logger.warn("KOAssistant: summarize_full_document action not found for cache generation")
        UIManager:show(InfoMessage:new{
            text = _("Could not find summary action. Please try again."),
        })
        if on_done then on_done(false) end
        return
    end

    -- For section scope: clone and modify the action
    if section_scope then
        local section_action = {}
        for k, v in pairs(summary_action) do section_action[k] = v end
        section_action.cache_as_summary = false  -- Don't save to main summary cache
        section_action.update_prompt = nil
        section_action.use_reading_progress = false
        section_action.use_response_caching = false
        section_action._section_scope = section_scope  -- Scopes text extraction to section pages
        -- Inject section scope context into prompt
        if section_action.prompt then
            local scope_line = string.format(
                'This is a section of "{title}"{author_clause}.\nSection: "%s" (%s)\nFocus your summary on this section only.\n\n',
                section_scope.label, section_scope.page_summary)
            section_action.prompt = scope_line .. section_action.prompt
        end
        summary_action = section_action
    end

    -- Show progress notification
    local Notification = require("ui/widget/notification")
    UIManager:show(Notification:new{
        text = section_scope and _("Generating section summary...") or _("Generating document summary..."),
        timeout = 2,
    })

    -- Execute summarize action (saves to _summary_cache or section cache via _section_scope)
    handlePredefinedPrompt(
        summary_action, nil, ui, configuration,
        nil, plugin, nil,
        function(history, _config_result)
            if history then
                -- Cache is now populated, continue with original action
                UIManager:scheduleIn(0.3, function()
                    if on_done then on_done(true) end
                end)
            else
                UIManager:show(InfoMessage:new{
                    text = section_scope and _("Section summary generation failed. Please try again.")
                        or _("Summary generation failed. Please try again."),
                })
                if on_done then on_done(false) end
            end
        end,
        book_metadata
    )
end

--- Launch a chat about an artifact. Follows the Send button flow:
--- builds consolidated message with artifact as context, queries AI, opens chat viewer.
--- @param user_question string The user's typed question
--- @param artifact_content string The full artifact text
--- @param artifact_type_name string Display name of the artifact (e.g. "Key Arguments")
--- @param ui table KOReader UI instance
--- @param configuration table Plugin configuration
--- @param plugin table Plugin instance
--- @param book_metadata table {title, author, file}
local function launchArtifactChat(user_question, artifact_content, artifact_type_name, ui, configuration, plugin, book_metadata)
    local document_path = book_metadata and book_metadata.file
    local title = (artifact_type_name or _("Artifact")) .. ": " .. _("Chat")

    -- Build system prompt (standard book chat)
    buildUnifiedRequestConfig(configuration, nil, nil, plugin)

    -- Create history with artifact type as prompt_action for title generation
    local history = MessageHistory:new(nil, nil)
    history.prompt_action = artifact_type_name
    history.source_input = user_question

    -- Build consolidated message: book context + artifact framing + artifact content + user question
    local parts = {}

    table.insert(parts, "[Context]")
    if book_metadata and book_metadata.title then
        table.insert(parts, string.format('From "%s"%s',
            book_metadata.title,
            (book_metadata.author and book_metadata.author ~= "") and (" by " .. book_metadata.author) or ""))
        table.insert(parts, "")
    end

    -- Framing prefix (like _xray_context_prefix): explains this is a generated artifact, not book text
    local framing = "(Note: The following is a previously generated " .. (artifact_type_name or "artifact") .. " artifact for this book, not the book text itself.)"
    table.insert(parts, framing)
    table.insert(parts, "")

    table.insert(parts, "Artifact content:")
    table.insert(parts, '"' .. artifact_content .. '"')
    table.insert(parts, "")

    table.insert(parts, "[User Question]")
    table.insert(parts, user_question)

    local consolidated_message = table.concat(parts, "\n")
    history:addUserMessage(consolidated_message, true)

    -- Query AI with the consolidated message
    local function onResponseReady(success, answer, err, reasoning, web_search_used)
        if success and answer then
            -- Add user's visible question and AI response
            history:addUserMessage(user_question, false)
            history:addAssistantMessage(answer, ConfigHelper:getModelInfo(configuration), reasoning, ConfigHelper:buildDebugInfo(configuration), web_search_used)

            local function addMessage(message, is_context, on_complete)
                history:addUserMessage(message, is_context)
                local answer_result = queryChatGPT(history:getMessages(), configuration, function(msg_success, msg_answer, msg_err, msg_reasoning, msg_web_search_used)
                    if msg_success and msg_answer then
                        history:addAssistantMessage(msg_answer, ConfigHelper:getModelInfo(configuration), msg_reasoning, ConfigHelper:buildDebugInfo(configuration), msg_web_search_used)
                    end
                    if on_complete then on_complete(msg_success, msg_answer, msg_err, msg_reasoning, msg_web_search_used) end
                end, plugin and plugin.settings)
                if not isStreamingInProgress(answer_result) then
                    return answer_result
                end
                return nil
            end

            showResponseDialog(title, history, nil, addMessage, configuration, document_path, plugin, book_metadata, nil, ui)
        else
            UIManager:show(InfoMessage:new{
                text = _("Error: ") .. (err or "Unknown error"),
                timeout = 3,
            })
        end
    end

    queryChatGPT(history:getMessages(), configuration, onResponseReady, plugin and plugin.settings)
end

return {
    showChatGPTDialog = showChatGPTDialog,
    executeDirectAction = executeDirectAction,
    executeActionForResult = executeActionForResult,
    generateSummaryCache = generateSummaryCache,
    extractSurroundingContext = extractSurroundingContext,
    launchArtifactChat = launchArtifactChat,
}