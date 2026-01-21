-- Centralized system prompts for KOAssistant
-- This module provides behavior prompts for AI interactions
--
-- Structure:
--   Behaviors are loaded from prompts/behaviors/ (built-in) and behaviors/ (user)
--   context  = Context-specific instructions (DEPRECATED - kept for reference)
--
-- System Array (Anthropic):
--   [1] Behavior (from variant, override, or none) + Domain [CACHED]
--
-- User Message:
--   [Context data] + [Action prompt] + [Runtime input]
--
-- Actions can control behavior via:
--   behavior_variant = "minimal" | "full" | "none"  (pick from list)
--   behavior_override = "custom text..."            (replace entirely)

local _ = require("koassistant_gettext")

local SystemPrompts = {}

-- Fallback behavior text (used if no behaviors can be loaded)
local FALLBACK_BEHAVIOR = "You are a helpful assistant."

-- Cache for loaded behaviors (cleared on reload)
local _builtin_cache = nil
local _all_cache = nil

-- Get built-in behaviors (cached)
local function getBuiltinBehaviors()
    if _builtin_cache then
        return _builtin_cache
    end
    local BehaviorLoader = require("behavior_loader")
    _builtin_cache = BehaviorLoader.loadBuiltin()
    return _builtin_cache
end

-- Get all behaviors from builtin + user folders (cached)
local function getAllFileBehaviors()
    if _all_cache then
        return _all_cache
    end
    local BehaviorLoader = require("behavior_loader")
    _all_cache = BehaviorLoader.loadAll()
    return _all_cache
end

-- Clear behavior cache (call when behaviors might have changed)
function SystemPrompts.clearBehaviorCache()
    _builtin_cache = nil
    _all_cache = nil
end

-- Context Instructions
-- These describe the specific context of the current interaction
-- Added to requests but NOT cached (they provide context, not behavior)
SystemPrompts.context = {
    -- Default fallback
    default = "You are a helpful assistant.",

    -- When user has highlighted text in a book
    highlight = [[The user is reading a book and has highlighted a passage they want to understand better. They may ask for explanations, summaries, context, or analysis of the highlighted text.

Book context may be provided including title, author, and surrounding text. Use this information to provide more relevant and contextualized responses.]],

    -- When user selects a single book from file browser
    book = [[The user has selected a book from their library and wants to learn more about it. They may ask about the book's content, themes, author, historical context, or similar works.

Book metadata will be provided including title and possibly author. Use this to provide relevant information about the specific work.]],

    -- When user selects multiple books
    multi_book = [[The user has selected multiple books from their library and wants comparative analysis or insights about the collection.

A list of books with titles and authors will be provided. Consider relationships between the works, common themes, contrasts, and what the selection reveals about the reader's interests.]],

    -- Standalone chat without book context
    general = [[This is a general conversation without specific book context. The user may want to discuss ideas, ask questions, get help with tasks, or just have a conversation.

If the chat was launched from within a book, that context may be provided, but it's optional background information rather than the focus of the discussion.]],

    -- Note: Translation is now handled via built-in action with behavior_override
    -- See prompts/actions.lua Actions.special.translate
}

-- Helper function to get behavior prompt by variant name
-- Falls back to 'minimal' if variant not found
-- @param variant: "minimal", "full", "custom", or nil
-- @param custom_text: Custom behavior text (used when variant is "custom")
-- @return string: Behavior prompt text
function SystemPrompts.getBehavior(variant, custom_text)
    variant = variant or "minimal"
    if variant == "custom" then
        local builtin = getBuiltinBehaviors()
        return custom_text or (builtin.minimal and builtin.minimal.text) or FALLBACK_BEHAVIOR
    end
    local builtin = getBuiltinBehaviors()
    if builtin[variant] then
        return builtin[variant].text
    end
    return (builtin.minimal and builtin.minimal.text) or FALLBACK_BEHAVIOR
end

-- Helper function to get context prompt by context type
-- Falls back to 'default' if context not found
-- DEPRECATED: Context instructions are no longer added to system array
-- Kept for backwards compatibility and reference
-- @param context_type: "highlight", "book", "multi_book", "general"
-- @return string: Context prompt text
function SystemPrompts.getContext(context_type)
    context_type = context_type or "default"
    return SystemPrompts.context[context_type] or SystemPrompts.context.default
end

-- Resolve behavior for an action
-- Handles priority: override > variant > global setting
-- @param config: {
--   behavior_override: custom behavior text (highest priority),
--   behavior_variant: "minimal", "full", "custom", "none", or any behavior ID,
--   global_variant: global setting fallback (features.selected_behavior),
--   custom_ai_behavior: user's custom behavior text (used when variant is "custom") - DEPRECATED
--   custom_behaviors: array of UI-created behaviors from settings (NEW)
-- }
-- @return behavior_text (string or nil), source (string)
--   behavior_text: The resolved behavior text, or nil if disabled
--   source: "override", "variant", "none", or "global"
function SystemPrompts.resolveBehavior(config)
    config = config or {}
    local builtin = getBuiltinBehaviors()

    -- Priority 1: Custom override text (per-action)
    if config.behavior_override and config.behavior_override ~= "" then
        return config.behavior_override, "override"
    end

    -- Priority 2: Named variant (including "none", "custom", or any behavior ID)
    if config.behavior_variant then
        if config.behavior_variant == "none" then
            return nil, "none"  -- Behavior disabled
        end
        -- Legacy "custom" variant support
        if config.behavior_variant == "custom" then
            return config.custom_ai_behavior or (builtin.minimal and builtin.minimal.text) or FALLBACK_BEHAVIOR, "variant"
        end
        -- Check built-in first
        if builtin[config.behavior_variant] then
            return builtin[config.behavior_variant].text, "variant"
        end
        -- Check all sources (folder, UI) for custom behavior ID
        local behavior = SystemPrompts.getBehaviorById(config.behavior_variant, config.custom_behaviors)
        if behavior then
            return behavior.text, "variant"
        end
        -- Unknown variant, fall through to global
    end

    -- Priority 3: Global setting (supports behavior ID or legacy values)
    local global_variant = config.global_variant or "standard"
    if global_variant == "none" then
        return nil, "none"
    end
    -- Legacy "custom" support
    if global_variant == "custom" then
        return config.custom_ai_behavior or (builtin.minimal and builtin.minimal.text) or FALLBACK_BEHAVIOR, "global"
    end
    -- Check built-in first
    if builtin[global_variant] then
        return builtin[global_variant].text, "global"
    end
    -- Check all sources for behavior ID
    local behavior = SystemPrompts.getBehaviorById(global_variant, config.custom_behaviors)
    if behavior then
        return behavior.text, "global"
    end
    -- Final fallback to "full" built-in or FALLBACK
    return (builtin.full and builtin.full.text) or FALLBACK_BEHAVIOR, "global"
end

-- Get combined cacheable content (behavior + domain)
-- This is what should be cached in Anthropic requests
-- @param behavior_text: Resolved behavior text (or nil if disabled)
-- @param domain_context: Optional domain context string
-- @return string or nil: Combined content for caching
function SystemPrompts.getCacheableContent(behavior_text, domain_context)
    local has_behavior = behavior_text and behavior_text ~= ""
    local has_domain = domain_context and domain_context ~= ""

    if has_behavior and has_domain then
        return behavior_text .. "\n\n---\n\n" .. domain_context
    elseif has_behavior then
        return behavior_text
    elseif has_domain then
        return domain_context
    end

    return nil  -- Nothing to cache
end

-- Build complete system prompt array for Anthropic
-- Returns array of content blocks suitable for Anthropic's system parameter
--
-- NEW ARCHITECTURE (v0.5):
--   System array contains only: behavior (or none) + domain [CACHED] + language instruction
--   Context instructions and action prompts go in user message
--
-- @param config: {
--   behavior_variant: "minimal", "full", "none", or nil (use global),
--   behavior_override: custom behavior text (overrides variant),
--   global_variant: global setting fallback (features.selected_behavior),
--   domain_context: optional domain context string,
--   enable_caching: boolean (default true for Anthropic),
--   user_languages: comma-separated languages (first is primary), empty = no instruction
-- }
-- @return table: Array of content blocks for Anthropic system parameter
-- Each block includes a `label` field for debug display (stripped before API call)
function SystemPrompts.buildAnthropicSystemArray(config)
    config = config or {}
    local blocks = {}

    -- Resolve behavior using priority: override > variant > global
    local behavior_text, behavior_source = SystemPrompts.resolveBehavior({
        behavior_override = config.behavior_override,
        behavior_variant = config.behavior_variant,
        global_variant = config.global_variant,
        custom_ai_behavior = config.custom_ai_behavior,
        custom_behaviors = config.custom_behaviors,  -- NEW: array of UI-created behaviors
    })

    -- Build language instruction if user has configured languages
    local language_instruction = nil
    if config.user_languages and config.user_languages ~= "" then
        language_instruction = SystemPrompts.buildLanguageInstruction(config.user_languages, config.primary_language)
    end

    -- Get cacheable content (behavior + domain, or just domain if behavior disabled)
    local cacheable = SystemPrompts.getCacheableContent(behavior_text, config.domain_context)

    -- Append language instruction to cacheable content if present
    if language_instruction then
        if cacheable then
            cacheable = cacheable .. "\n\n" .. language_instruction
        else
            cacheable = language_instruction
        end
    end

    -- If nothing to put in system array, return empty
    if not cacheable then
        return blocks
    end

    -- Determine label based on what's included
    local label
    local has_domain = config.domain_context and config.domain_context ~= ""
    local has_language = language_instruction ~= nil
    if behavior_source == "none" then
        if has_domain and has_language then
            label = "domain+language"
        elseif has_domain then
            label = "domain"
        elseif has_language then
            label = "language"
        end
    elseif has_domain and has_language then
        label = "behavior+domain+language"
    elseif has_domain then
        label = "behavior+domain"
    elseif has_language then
        label = "behavior+language"
    else
        label = "behavior"
    end

    local block = {
        type = "text",
        text = cacheable,
        label = label,  -- For debug display (stripped before API call)
    }

    -- Store individual components for debug display (stripped before API call)
    block.debug_components = {}
    if behavior_text and behavior_source ~= "none" then
        table.insert(block.debug_components, { name = "behavior", text = behavior_text })
    end
    if config.domain_context and config.domain_context ~= "" then
        table.insert(block.debug_components, { name = "domain", text = config.domain_context })
    end
    if language_instruction then
        table.insert(block.debug_components, { name = "language", text = language_instruction })
    end

    -- Add cache_control if caching is enabled (default true)
    if config.enable_caching ~= false then
        block.cache_control = { type = "ephemeral" }
    end

    table.insert(blocks, block)

    return blocks
end

-- Build flattened system prompt for non-Anthropic providers
-- Combines behavior + domain + language instruction into a single string
--
-- NEW ARCHITECTURE (v0.5):
--   Only includes behavior (or none) + domain + language instruction
--   Context instructions and action prompts go in user message
--
-- @param config: Same as buildAnthropicSystemArray
-- @return string: Combined system prompt (may be empty string)
function SystemPrompts.buildFlattenedPrompt(config)
    config = config or {}

    -- Resolve behavior using priority: override > variant > global
    local behavior_text, _ = SystemPrompts.resolveBehavior({
        behavior_override = config.behavior_override,
        behavior_variant = config.behavior_variant,
        global_variant = config.global_variant,
        custom_ai_behavior = config.custom_ai_behavior,
        custom_behaviors = config.custom_behaviors,  -- NEW: array of UI-created behaviors
    })

    -- Get combined content
    local content = SystemPrompts.getCacheableContent(behavior_text, config.domain_context)

    -- Append language instruction if user has configured languages
    if config.user_languages and config.user_languages ~= "" then
        local language_instruction = SystemPrompts.buildLanguageInstruction(config.user_languages, config.primary_language)
        if content then
            content = content .. "\n\n" .. language_instruction
        else
            content = language_instruction
        end
    end

    return content or ""
end

-- Build unified system prompt configuration for ALL providers
-- Returns a unified format that each provider handler can adapt to its native API
--
-- This is the NEW unified approach (v0.5.2+):
--   All providers receive the same config.system structure
--   Each handler transforms to its native format:
--     - Anthropic: array with cache_control
--     - OpenAI/DeepSeek: first message with role="system"
--     - Gemini: system_instruction field
--     - Ollama: included in messages
--
-- @param config: {
--   behavior_variant: "minimal", "full", "custom", "none", or nil,
--   behavior_override: custom behavior text (overrides variant),
--   global_variant: global setting fallback,
--   custom_ai_behavior: user's custom behavior text,
--   domain_context: optional domain context string,
--   enable_caching: boolean (only used by Anthropic),
--   user_languages: comma-separated languages,
--   primary_language: explicit primary language override,
--   skip_language_instruction: boolean, don't include language instruction (e.g., for translate)
-- }
-- @return table: {
--   text: Combined system prompt string (may be empty),
--   enable_caching: Whether to enable caching (Anthropic only),
--   components: { behavior, domain, language } for debugging,
-- }
function SystemPrompts.buildUnifiedSystem(config)
    config = config or {}

    -- Resolve behavior using priority: override > variant > global
    local behavior_text, behavior_source = SystemPrompts.resolveBehavior({
        behavior_override = config.behavior_override,
        behavior_variant = config.behavior_variant,
        global_variant = config.global_variant,
        custom_ai_behavior = config.custom_ai_behavior,
        custom_behaviors = config.custom_behaviors,  -- NEW: array of UI-created behaviors
    })

    -- Build language instruction if user has configured languages
    -- Skip if action has opted out (e.g., translate action already specifies target language)
    local language_instruction = nil
    if not config.skip_language_instruction and
       config.user_languages and config.user_languages ~= "" then
        language_instruction = SystemPrompts.buildLanguageInstruction(
            config.user_languages, config.primary_language
        )
    end

    -- Get combined content (behavior + domain)
    local content = SystemPrompts.getCacheableContent(behavior_text, config.domain_context)

    -- Append language instruction if present
    if language_instruction then
        if content then
            content = content .. "\n\n" .. language_instruction
        else
            content = language_instruction
        end
    end

    return {
        text = content or "",
        enable_caching = config.enable_caching ~= false,
        components = {
            behavior = (behavior_source ~= "none") and behavior_text or nil,
            domain = config.domain_context,
            language = language_instruction,
        },
    }
end

-- Get list of available behavior variant names (built-in only)
-- @return table: Array of variant names
function SystemPrompts.getVariantNames()
    local builtin = getBuiltinBehaviors()
    local names = {}
    for name, _ in pairs(builtin) do
        table.insert(names, name)
    end
    table.sort(names)
    return names
end

-- Get all behaviors from all sources: built-in, folder, and UI-created
-- @param custom_behaviors: Array of UI-created behaviors from settings (optional)
-- @return table: { id = { id, name, text, source, display_name } }
function SystemPrompts.getAllBehaviors(custom_behaviors)
    local all_behaviors = {}

    -- Load all file-based behaviors (builtin + user folder)
    local file_behaviors = getAllFileBehaviors()
    for id, behavior in pairs(file_behaviors) do
        local display_suffix = behavior.source == "builtin" and "" or " (file)"
        all_behaviors[id] = {
            id = id,
            name = behavior.name,
            text = behavior.text,
            source = behavior.source,
            display_name = behavior.name .. display_suffix,
            external = behavior.source ~= "builtin",
            metadata = behavior.metadata,  -- Source, Notes, Date from file comments
        }
    end

    -- Add UI-created behaviors
    if custom_behaviors and type(custom_behaviors) == "table" then
        for _, behavior in ipairs(custom_behaviors) do
            if behavior.id and behavior.text then
                all_behaviors[behavior.id] = {
                    id = behavior.id,
                    name = behavior.name or behavior.id,
                    text = behavior.text,
                    source = "ui",
                    display_name = (behavior.name or behavior.id) .. " (custom)",
                }
            end
        end
    end

    return all_behaviors
end

-- Get sorted list of behavior entries for UI display
-- @param custom_behaviors: Array of UI-created behaviors from settings (optional)
-- @return table: Array of behavior entries sorted by display_name
function SystemPrompts.getSortedBehaviors(custom_behaviors)
    local all = SystemPrompts.getAllBehaviors(custom_behaviors)
    local sorted = {}

    for _, behavior in pairs(all) do
        table.insert(sorted, behavior)
    end

    table.sort(sorted, function(a, b)
        -- Built-ins first, then folders, then UI
        local order = { builtin = 1, folder = 2, ui = 3 }
        if order[a.source] ~= order[b.source] then
            return order[a.source] < order[b.source]
        end
        return (a.display_name or a.name) < (b.display_name or b.name)
    end)

    return sorted
end

-- Get a specific behavior by ID
-- @param id: Behavior ID to look up
-- @param custom_behaviors: Array of UI-created behaviors from settings (optional)
-- @return table or nil: Behavior entry or nil if not found
function SystemPrompts.getBehaviorById(id, custom_behaviors)
    if not id then return nil end

    -- Check all file-based behaviors (builtin + user folder)
    local file_behaviors = getAllFileBehaviors()
    if file_behaviors[id] then
        local behavior = file_behaviors[id]
        local display_suffix = behavior.source == "builtin" and "" or " (file)"
        return {
            id = id,
            name = behavior.name,
            text = behavior.text,
            source = behavior.source,
            display_name = behavior.name .. display_suffix,
            external = behavior.source ~= "builtin",
            metadata = behavior.metadata,  -- Source, Notes, Date from file comments
        }
    end

    -- Check UI-created behaviors
    if custom_behaviors and type(custom_behaviors) == "table" then
        for _, behavior in ipairs(custom_behaviors) do
            if behavior.id == id then
                return {
                    id = behavior.id,
                    name = behavior.name or behavior.id,
                    text = behavior.text,
                    source = "ui",
                    display_name = (behavior.name or behavior.id) .. " (custom)",
                }
            end
        end
    end

    return nil
end

-- Parse user languages string into primary and full list
-- @param user_languages: Comma-separated string of languages
-- @param primary_override: Optional explicit primary language override
-- @return primary: Primary language (override if valid, else first in list)
-- @return languages_list: Full trimmed string of all languages
function SystemPrompts.parseUserLanguages(user_languages, primary_override)
    if not user_languages or user_languages == "" then
        return "English", "English"
    end

    -- Trim and normalize
    local trimmed = user_languages:match("^%s*(.-)%s*$")
    if trimmed == "" then
        return "English", "English"
    end

    -- Parse all languages into a list
    local languages = {}
    for lang in trimmed:gmatch("([^,]+)") do
        local lang_trimmed = lang:match("^%s*(.-)%s*$")
        if lang_trimmed ~= "" then
            table.insert(languages, lang_trimmed)
        end
    end

    if #languages == 0 then
        return "English", "English"
    end

    -- Determine primary: override if valid, else first
    local primary = languages[1]
    if primary_override and primary_override ~= "" then
        for _, lang in ipairs(languages) do
            if lang == primary_override then
                primary = primary_override
                break
            end
        end
    end

    return primary, trimmed
end

-- Build language instruction for system prompt
-- @param user_languages: Comma-separated string of languages
-- @param primary_override: Optional explicit primary language override
-- @return string: Language instruction text
function SystemPrompts.buildLanguageInstruction(user_languages, primary_override)
    local primary, languages_list = SystemPrompts.parseUserLanguages(user_languages, primary_override)

    return string.format(
        "The user speaks: %s. Always respond in %s unless the user writes in a different language from this list, in which case respond in that language.",
        languages_list,
        primary
    )
end

-- Get effective translation language
-- @param config: {
--   translation_use_primary: boolean,
--   user_languages: string (comma-separated),
--   primary_language: string (optional explicit override),
--   translation_language: string (fallback when not using primary)
-- }
-- @return string: Effective translation target language
function SystemPrompts.getEffectiveTranslationLanguage(config)
    config = config or {}

    local primary, _ = SystemPrompts.parseUserLanguages(config.user_languages, config.primary_language)

    -- Use primary if: toggle is on, OR translation_language is the __PRIMARY__ sentinel
    local lang = config.translation_language
    if config.translation_use_primary ~= false or
       lang == "__PRIMARY__" or lang == nil or lang == "" then
        return primary
    end

    return lang
end

return SystemPrompts
