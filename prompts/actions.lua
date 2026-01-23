-- Action definitions for KOAssistant
-- Actions are UI elements (buttons) that trigger AI interactions
--
-- This module separates concerns:
--   - Actions: UI definition, context, behavior control, API parameters
--   - Templates: User prompt text (in templates.lua)
--   - System prompts: AI behavior variants (in system_prompts.lua)
--
-- NEW ARCHITECTURE (v0.5):
--   System array: behavior (from variant/override/none) + domain [CACHED]
--   User message: context data + action prompt (template) + runtime input
--
-- Action schema:
--   id               - Unique identifier (required)
--   text             - Button display text (required)
--   context          - Where it appears: "highlight", "book", "multi_book", "general", "all", "both" (required)
--   template         - User prompt template ID from templates.lua (required for builtin)
--   prompt           - Direct user prompt text (for custom actions without template)
--   behavior_variant - Override global behavior: "minimal", "full", "none" (optional)
--   behavior_override- Custom behavior text, replaces variant entirely (optional)
--   extended_thinking- Override global thinking: "off" to disable, "on" to enable (optional)
--   thinking_budget  - Token budget when extended_thinking="on" (1024-32000, default 4096)
--   api_params       - Optional API parameters: { temperature, max_tokens }
--   skip_language_instruction - Don't include user's language preferences in system prompt (optional)
--   requires         - Optional metadata requirement: "author", "title", etc.
--   include_book_context - Include book metadata with highlight context (optional)
--   enabled          - Default enabled state (default: true)
--   builtin          - Whether this is a built-in action (default: true for this file)
--   storage_key      - Override chat save location (optional):
--                      nil/unset: Default (current document, or __GENERAL_CHATS__ for general context)
--                      "__SKIP__": Don't save this chat at all
--                      Custom string: Save to that pseudo-document

local _ = require("koassistant_gettext")

local Actions = {}

-- Built-in actions for highlight context
-- These use global behavior setting (no behavior_variant override)
Actions.highlight = {
    explain = {
        id = "explain",
        text = _("Explain"),
        context = "highlight",
        template = "explain",
        -- Uses global behavior variant (full/minimal)
        api_params = {
            temperature = 0.5,  -- More focused for explanations
        },
        include_book_context = true,
        builtin = true,
    },
    eli5 = {
        id = "eli5",
        text = _("ELI5"),
        context = "highlight",
        template = "eli5",
        -- Uses global behavior variant
        api_params = {
            temperature = 0.6,
        },
        include_book_context = false,
        builtin = true,
    },
    summarize = {
        id = "summarize",
        text = _("Summarize"),
        context = "highlight",
        template = "summarize",
        -- Uses global behavior variant
        api_params = {
            temperature = 0.4,  -- More deterministic for summaries
        },
        include_book_context = true,
        builtin = true,
    },
    elaborate = {
        id = "elaborate",
        text = _("Elaborate"),
        context = "highlight",
        template = "elaborate",
        -- Uses global behavior variant
        api_params = {
            temperature = 0.7,  -- Balanced for expansive but coherent elaboration
        },
        include_book_context = true,
        builtin = true,
    },
}

-- Built-in actions for book context (single book from file browser)
Actions.book = {
    book_info = {
        id = "book_info",
        text = _("Book Info"),
        context = "book",
        template = "book_info",
        api_params = {
            temperature = 0.7,
        },
        builtin = true,
    },
    similar_books = {
        id = "similar_books",
        text = _("Find Similar"),
        context = "book",
        template = "similar_books",
        api_params = {
            temperature = 0.8,  -- More creative for recommendations
        },
        builtin = true,
    },
    explain_author = {
        id = "explain_author",
        text = _("About Author"),
        context = "book",
        template = "explain_author",
        requires = "author",
        api_params = {
            temperature = 0.7,
        },
        builtin = true,
    },
    historical_context = {
        id = "historical_context",
        text = _("Historical Context"),
        context = "book",
        template = "historical_context",
        api_params = {
            temperature = 0.6,
        },
        builtin = true,
    },
}

-- Built-in actions for multi-book context
Actions.multi_book = {
    compare_books = {
        id = "compare_books",
        text = _("Compare Books"),
        context = "multi_book",
        template = "compare_books",
        api_params = {
            temperature = 0.6,
            max_tokens = 4096,  -- Comparisons can be lengthy
        },
        builtin = true,
    },
    common_themes = {
        id = "common_themes",
        text = _("Find Common Themes"),
        context = "multi_book",
        template = "common_themes",
        api_params = {
            temperature = 0.7,
        },
        builtin = true,
    },
    collection_summary = {
        id = "collection_summary",
        text = _("Analyze Collection"),
        context = "multi_book",
        template = "collection_summary",
        api_params = {
            temperature = 0.7,
        },
        builtin = true,
    },
    quick_summaries = {
        id = "quick_summaries",
        text = _("Quick Summaries"),
        context = "multi_book",
        template = "quick_summaries",
        api_params = {
            temperature = 0.5,
            max_tokens = 4096,  -- Multiple summaries need space
        },
        builtin = true,
    },
}

-- Built-in actions for general context
Actions.general = {
    -- General context uses the "Ask" button directly without predefined actions
    -- Custom prompts can target general context
}

-- Special actions (context-specific overrides)
Actions.special = {
    translate = {
        id = "translate",
        text = _("Translate"),
        context = "highlight",  -- Only for highlighted text
        behavior_variant = "translator_direct",  -- Use built-in translation behavior
        prompt = "Translate this to {translation_language}: {highlighted_text}",
        include_book_context = false,
        extended_thinking = "off",  -- Translations don't benefit from extended thinking
        skip_language_instruction = true,  -- Target language already in prompt
        api_params = {
            temperature = 0.3,  -- Very deterministic for translations
        },
        builtin = true,
    },
    dictionary = {
        id = "dictionary",
        text = _("Dictionary"),
        context = "highlight",  -- Only for highlighted text
        behavior_variant = "dictionary_direct",  -- Use built-in dictionary behavior
        prompt = [[Define: {highlighted_text}

Format as a dictionary entry:
- First line: **word** _part of speech (of **lemma**), features_
- Definition(s) numbered if multiple
- **In context:** Brief explanation of usage in the given passage

Context: {context}

Respond in {dictionary_language}. Be concise.]],
        include_book_context = false,  -- Word definitions don't typically need book metadata
        extended_thinking = "off",  -- Dictionary lookups don't benefit from extended thinking
        skip_language_instruction = true,  -- Target language already in prompt
        -- storage_key set dynamically based on dictionary_disable_auto_save setting
        api_params = {
            temperature = 0.3,  -- Deterministic for definitions
            max_tokens = 1024,  -- Dictionary responses are typically short
        },
        builtin = true,
    },
    dictionary_detailed = {
        id = "dictionary_detailed",
        text = _("Detailed Dictionary"),
        context = "highlight",  -- Only for highlighted text
        behavior_variant = "dictionary_detailed",  -- Use built-in detailed dictionary behavior
        prompt = [[Deep analysis of: {highlighted_text}

**Headword**: word (transliteration if non-Latin), _part of speech_

**Morphological Structure**:
- Semitic languages (Arabic, Hebrew, etc.): Root in script, pattern/wazn, verb form (bāb) if applicable, semantic contribution of the pattern
- Indo-European languages: Base/stem, affixes, derivational components, compound structure if applicable
- Other languages: Adapt to what is morphologically salient

**Word Family**: Related words from the same root/stem with brief meanings, showing how derivation affects meaning

**Etymology**: Origin, transmission path, semantic shifts

**Cognates**: Related words in sister languages; notable borrowings

**In context**: Usage in this passage

Context: {context}
Respond in {dictionary_language}.]],
        include_book_context = false,
        extended_thinking = "off",
        skip_language_instruction = true,
        -- storage_key set dynamically based on dictionary_disable_auto_save setting
        api_params = {
            temperature = 0.3,
            max_tokens = 2048,  -- Detailed analysis needs more space
        },
        builtin = true,
    },
}

-- Get all actions for a specific context
-- @param context: "highlight", "book", "multi_book", "general"
-- @return table: Array of action definitions
function Actions.getForContext(context)
    local result = {}

    -- Get context-specific actions
    local context_actions = Actions[context] or {}
    for _idx,action in pairs(context_actions) do
        table.insert(result, action)
    end

    -- Add special actions that apply to this context
    for _idx,action in pairs(Actions.special) do
        if action.context == "all" or
           action.context == context or
           (action.context == "both" and (context == "highlight" or context == "book")) then
            table.insert(result, action)
        end
    end

    return result
end

-- Get a specific action by ID
-- @param action_id: The action's unique identifier
-- @return table or nil: Action definition if found
function Actions.getById(action_id)
    -- Search all context tables
    for _idx,context_table in pairs({Actions.highlight, Actions.book, Actions.multi_book, Actions.general, Actions.special}) do
        if context_table[action_id] then
            return context_table[action_id]
        end
    end
    return nil
end

-- Get all built-in actions grouped by context
-- @return table: { highlight = {...}, book = {...}, multi_book = {...}, general = {...} }
function Actions.getAllBuiltin()
    return {
        highlight = Actions.highlight,
        book = Actions.book,
        multi_book = Actions.multi_book,
        general = Actions.general,
        special = Actions.special,
    }
end

-- Check if an action's requirements are met
-- @param action: Action definition
-- @param metadata: Available metadata (title, author, etc.)
-- @return boolean: true if requirements are met
function Actions.checkRequirements(action, metadata)
    if not action.requires then
        return true
    end

    metadata = metadata or {}

    if action.requires == "author" then
        return metadata.author and metadata.author ~= ""
    elseif action.requires == "title" then
        return metadata.title and metadata.title ~= ""
    end

    return true
end

-- Get API parameters for an action, with defaults
-- @param action: Action definition
-- @param defaults: Default API parameters
-- @return table: Merged API parameters
function Actions.getApiParams(action, defaults)
    defaults = defaults or {}
    local params = {}

    -- Start with defaults
    for k, v in pairs(defaults) do
        params[k] = v
    end

    -- Override with action-specific params
    if action and action.api_params then
        for k, v in pairs(action.api_params) do
            params[k] = v
        end
    end

    return params
end

return Actions
