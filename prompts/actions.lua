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

local Constants = require("koassistant_constants")
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
    -- X-Ray: Structured book reference guide
    xray = {
        id = "xray",
        text = _("X-Ray"),
        context = "book",
        behavior_variant = "reader_assistant",
        -- Context extraction flags
        use_book_text = true,
        use_highlights = true,
        use_reading_progress = true,
        prompt = [[Create a reader's companion for "{title}" by {author}.

I'm at {reading_progress} through the book.

{highlights_section}

{book_text_section}

Build a reference guide covering ONLY what's happened up to my current position:

## Cast
For each significant character (aim for 8-12):
**[Name]** — Role in the story. Key traits. Current allegiances or conflicts.

## World
For each important setting (aim for 5-8):
**[Place]** — What it is. Why it matters. What happened there.

## Ideas
The main themes emerging so far (aim for 4-6):
**[Theme]** — How it's being explored in the story.

## Lexicon
Terms, concepts, or in-world vocabulary (aim for 5-8):
**[Term]** — Definition and significance.

## Story Arc
Major turning points so far (chronological, 6-10 events):
- **[Event/Chapter]:** What happened and why it mattered.

## Current State
Where the story stands at {reading_progress}:
- What just happened
- Active conflicts or mysteries
- The protagonist's immediate situation
- Unanswered questions

CRITICAL: Do not reveal ANYTHING beyond {reading_progress}. This must be completely spoiler-free.]],
        skip_language_instruction = false,
        skip_domain = true,  -- X-Ray has specific structure
        extended_thinking = "off",
        api_params = {
            temperature = 0.5,
            max_tokens = 4096,
        },
        builtin = true,
    },
    -- Recap: Story summary for re-immersion
    recap = {
        id = "recap",
        text = _("Recap"),
        context = "book",
        behavior_variant = "reader_assistant",
        -- Context extraction flags
        use_book_text = true,
        use_reading_progress = true,
        use_reading_stats = true,
        prompt = [[Help me get back into "{title}" by {author}.

I'm at {reading_progress} and last read {time_since_last_read}.

{book_text_section}

Write a quick "Previously on..." style recap that:

1. **Sets the scene** - Briefly remind me of the story's situation at this point
2. **Recent events** - What happened in the last few chapters I read (prioritize recent over early)
3. **Active threads** - What conflicts, mysteries, or goals are in play
4. **Where I stopped** - The specific moment or scene where I paused

Style guidance:
- Write in a way that fits the book's genre (suspenseful for thrillers, whimsical for fantasy, etc.)
- Use **bold** for character names and important terms
- Use *italics* for key revelations or turning points
- Keep it concise - this is a refresher, not a full summary
- No spoilers beyond {reading_progress}

Think of this as the "Last time on..." narration before a TV episode continues.]],
        skip_language_instruction = false,
        skip_domain = true,
        extended_thinking = "off",
        api_params = {
            temperature = 0.7,
            max_tokens = 2048,
        },
        builtin = true,
    },
    -- Analyze Highlights: Insights from user's annotations
    analyze_highlights = {
        id = "analyze_highlights",
        text = _("Analyze Highlights"),
        context = "book",
        behavior_variant = "reader_assistant",
        -- Context extraction flags
        use_annotations = true,
        use_reading_progress = true,
        prompt = [[Reflect on my reading of "{title}" by {author} through my highlights.

I'm at {reading_progress}. Here's what I've marked:

{annotations_section}

Analyze MY READING PATTERNS, not just the book content:

## What Catches My Attention
What types of passages do I tend to highlight? (dialogue, descriptions, ideas, emotions, plot points?)
What does this suggest about what I find valuable in this book?

## Emerging Threads
Looking at my highlights as a collection, what themes or ideas am I tracking?
Are there connections between highlights I might not have noticed?

## My Notes Tell a Story
If I've added notes, what do they reveal about my thinking?
How is my understanding or reaction evolving?

## Questions I Seem to Be Asking
Based on what I highlight, what larger questions might I be exploring?
What am I curious about or paying attention to?

## Suggestions
Based on my highlighting patterns:
- Parts of the book I might want to revisit
- Themes to watch for going forward
- Connections to other ideas or books

This is about understanding ME as a reader through my highlights, not summarizing the book.]],
        skip_language_instruction = false,
        skip_domain = true,
        extended_thinking = "off",
        api_params = {
            temperature = 0.5,
            max_tokens = 2048,
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
        skip_domain = true,  -- Domain context not relevant for translations
        api_params = {
            temperature = 0.3,  -- Very deterministic for translations
        },
        builtin = true,
    },
    quick_define = {
        id = "quick_define",
        text = _("Quick Define"),
        context = "highlight",  -- Only for highlighted text
        behavior_variant = "dictionary_direct",  -- Use built-in dictionary behavior
        in_dictionary_popup = 2,  -- Default order in dictionary popup
        prompt = [[Define: {highlighted_text}

Format as a dictionary entry with these language rules:
- **Headword line:** **word** _part of speech_ of **lemma** - do NOT translate
- **Definition(s):** {dictionary_language}, numbered if multiple
- **In context:** In {dictionary_language}, usage in the passage

Context: {context}

No section headers. Inline bold labels. Concise.]],
        include_book_context = false,  -- Word definitions don't typically need book metadata
        extended_thinking = "off",  -- Dictionary lookups don't benefit from extended thinking
        skip_language_instruction = true,  -- Target language already in prompt
        skip_domain = true,  -- Domain context not relevant for dictionary lookups
        -- storage_key set dynamically based on dictionary_disable_auto_save setting
        api_params = {
            temperature = 0.3,  -- Deterministic for definitions
            max_tokens = 512,  -- Quick definitions are short
        },
        builtin = true,
    },
    dictionary = {
        id = "dictionary",
        text = _("Dictionary"),
        context = "highlight",  -- Only for highlighted text
        behavior_variant = "dictionary_direct",  -- Use built-in dictionary behavior
        in_dictionary_popup = 1,  -- Default order in dictionary popup
        prompt = [[Define: {highlighted_text}

Format as a dictionary entry with these language rules:
- **Headword line:** **word** _part of speech_ of **lemma** - do NOT translate
- **Definition(s):** {dictionary_language}, numbered if multiple
- **Etymology:** In {dictionary_language}, brief
- **Synonyms:** Same language as the word (not translated)
- **In context:** In {dictionary_language}, usage in the passage

Context: {context}

No section headers. Inline bold labels. Concise.]],
        include_book_context = false,  -- Word definitions don't typically need book metadata
        extended_thinking = "off",  -- Dictionary lookups don't benefit from extended thinking
        skip_language_instruction = true,  -- Target language already in prompt
        skip_domain = true,  -- Domain context not relevant for dictionary lookups
        -- storage_key set dynamically based on dictionary_disable_auto_save setting
        api_params = {
            temperature = 0.3,  -- Deterministic for definitions
            max_tokens = 1024,  -- Dictionary responses are typically short
        },
        builtin = true,
    },
    deep = {
        id = "dictionary_deep",
        text = _("Deep Analysis"),
        context = "highlight",  -- Only for highlighted text
        behavior_variant = "dictionary_detailed",  -- Use built-in detailed dictionary behavior
        in_dictionary_popup = 3,  -- Default order in dictionary popup
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
        skip_domain = true,  -- Domain context not relevant for dictionary lookups
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
    -- Search all context tables using Constants for context names
    local context_tables = {
        Actions[Constants.CONTEXTS.HIGHLIGHT],
        Actions[Constants.CONTEXTS.BOOK],
        Actions[Constants.CONTEXTS.MULTI_BOOK],
        Actions[Constants.CONTEXTS.GENERAL],
        Actions.special
    }
    for _idx, context_table in pairs(context_tables) do
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
