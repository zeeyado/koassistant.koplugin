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

-- ============================================================
-- Canonical Summary Prompt
-- ============================================================
-- The "workhorse" prompt for building reusable document summaries
-- Used by summarize_full_document action and referenced by Smart actions
Actions.SUMMARY_PROMPT = [[Summarize: "{title}"{author_clause}.

{full_document_section}

Provide a comprehensive summary capturing the essential content. Adjust detail based on length - shorter works warrant more granularity, longer works need higher-level synthesis. The summary you make may be used as a replacement for the full text, to ask questions and do analysis. Keep this goal in mind when crafting the summary.]]

-- ============================================================
-- Open Book Flags - Centralized Definition
-- ============================================================
-- Actions that use these flags require an open book (reading mode)
-- and won't appear in file browser context

-- List of flags that indicate an action needs reading mode data
Actions.OPEN_BOOK_FLAGS = {
    "use_book_text",
    "use_reading_progress",
    "use_annotations",
    "use_reading_stats",
    "use_notebook",
}

-- Mapping from placeholders to the flags they require
-- Used for automatic flag inference from prompt text
Actions.PLACEHOLDER_TO_FLAG = {
    -- Reading progress placeholders
    ["{reading_progress}"] = "use_reading_progress",
    ["{progress_decimal}"] = "use_reading_progress",
    ["{time_since_last_read}"] = "use_reading_progress",

    -- Highlights/Annotations placeholders (same data, unified flag)
    ["{highlights}"] = "use_annotations",
    ["{highlights_section}"] = "use_annotations",
    ["{annotations}"] = "use_annotations",
    ["{annotations_section}"] = "use_annotations",

    -- Book text placeholders
    ["{book_text}"] = "use_book_text",
    ["{book_text_section}"] = "use_book_text",

    -- Reading stats placeholders
    ["{chapter_title}"] = "use_reading_stats",
    ["{chapters_read}"] = "use_reading_stats",

    -- Notebook placeholders
    ["{notebook}"] = "use_notebook",
    ["{notebook_section}"] = "use_notebook",

    -- Full document placeholders (same gate as book_text)
    ["{full_document}"] = "use_book_text",
    ["{full_document_section}"] = "use_book_text",

    -- Cached content placeholders (double-gated: require use_book_text since content derives from book text)
    ["{xray_cache}"] = "use_xray_cache",
    ["{xray_cache_section}"] = "use_xray_cache",
    ["{analyze_cache}"] = "use_analyze_cache",
    ["{analyze_cache_section}"] = "use_analyze_cache",
    ["{summary_cache}"] = "use_summary_cache",
    ["{summary_cache_section}"] = "use_summary_cache",

    -- Surrounding context placeholder (for highlight actions)
    ["{surrounding_context}"] = "use_surrounding_context",
    ["{surrounding_context_section}"] = "use_surrounding_context",
}

-- Flags that require use_book_text to be set (cascading requirement)
-- These flags derive from book text, so accessing them needs text extraction permission
Actions.REQUIRES_BOOK_TEXT = {
    "use_xray_cache",
    "use_analyze_cache",
    "use_summary_cache",
}

-- Flags that require use_annotations to be set (cascading requirement)
-- X-Ray cache includes annotation data, so accessing it needs annotation permission
Actions.REQUIRES_ANNOTATIONS = {
    "use_xray_cache",  -- X-Ray uses {highlights_section}
}

-- Flags that are double-gated (require global consent + explicit per-action checkbox)
-- These must NEVER be auto-inferred from placeholders - user must tick checkbox
-- Security model: prevents accidental data exposure when user adds a placeholder
Actions.DOUBLE_GATED_FLAGS = {
    "use_book_text",      -- gate: enable_book_text_extraction
    "use_annotations",    -- gate: enable_annotations_sharing
    "use_notebook",       -- gate: enable_notebook_sharing
    -- Document cache flags inherit from use_book_text
    "use_xray_cache",
    "use_analyze_cache",
    "use_summary_cache",
}

-- Built-in actions for highlight context
-- These use global behavior setting (no behavior_variant override)
Actions.highlight = {
    explain = {
        id = "explain",
        text = _("Explain"),
        context = "highlight",
        template = "explain",
        in_highlight_menu = 2,  -- Default in highlight menu
        -- Uses global behavior variant (full/minimal)
        api_params = {
            temperature = 0.5,  -- More focused for explanations
            max_tokens = 4096,
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
            max_tokens = 4096,
        },
        include_book_context = true,
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
            max_tokens = 4096,
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
            max_tokens = 4096,
        },
        include_book_context = true,
        builtin = true,
    },
    connect = {
        id = "connect",
        text = _("Connect"),
        context = "highlight",
        prompt = [[Draw connections from this passage:

{highlighted_text}

Explore how it relates to:
- Other themes or ideas in this work
- Other books, thinkers, or intellectual traditions
- Broader historical or cultural context

Surface connections that enrich understanding, not tangential trivia. {conciseness_nudge}]],
        include_book_context = true,
        api_params = {
            temperature = 0.7,
            max_tokens = 4096,
        },
        builtin = true,
    },
    connect_with_notes = {
        id = "connect_with_notes",
        text = _("Connect (With Notes)"),
        context = "highlight",
        behavior_variant = "reader_assistant",
        include_book_context = true,
        -- Context extraction flags
        use_annotations = true,
        use_notebook = true,
        prompt = [[I just highlighted this passage:

"{highlighted_text}"

{annotations_section}

{notebook_section}

Help me connect this to my reading journey:

## Echoes
Does this passage relate to anything I've already highlighted or written about? What patterns or connections do you see?

## Fresh Angle
What's new or different about this passage compared to what I've noted before?

## Worth Adding
Based on this highlight, is there anything I might want to add to my notebook? A question, connection, or thought?

If I have no prior highlights or notebook entries, just reflect on this passage and suggest what might be worth noting.

{conciseness_nudge}]],
        skip_domain = true,
        api_params = {
            temperature = 0.6,
            max_tokens = 4096,
        },
        builtin = true,
    },
    -- Context-aware highlight actions (use book text extraction)
    explain_in_context = {
        id = "explain_in_context",
        text = _("Explain in Context"),
        context = "highlight",
        use_book_text = true,
        include_book_context = true,
        prompt = [[Explain this passage in context:

"{highlighted_text}"

From "{title}"{author_clause}.

{book_text_section}

Help me understand:
1. What this passage means
2. How it connects to what came before
3. Key references or concepts it builds on

{conciseness_nudge}]],
        api_params = {
            temperature = 0.5,
            max_tokens = 4096,
        },
        builtin = true,
    },
    analyze_in_context = {
        id = "analyze_in_context",
        text = _("Analyze in Context"),
        context = "highlight",
        use_book_text = true,
        use_annotations = true,
        include_book_context = true,
        prompt = [[Analyze this passage in the broader context of what I've read:

"{highlighted_text}"

From "{title}"{author_clause}.

{book_text_section}

{annotations_section}

Provide deeper analysis:
1. **Significance**: Why might this passage matter in the larger work?
2. **Connections**: How does it relate to earlier themes, arguments, or events?
3. **Patterns**: Does it echo or develop something from before?
4. **My notes**: If I've highlighted related passages, show those connections.

{conciseness_nudge}]],
        api_params = {
            temperature = 0.6,
            max_tokens = 4096,
        },
        builtin = true,
    },
    -- Smart context-aware action using cached summary for efficiency
    explain_in_context_smart = {
        id = "explain_in_context_smart",
        text = _("Explain in Context (Smart)"),
        context = "highlight",
        use_book_text = true,        -- Gate for accessing _summary_cache (derives from book text)
        use_summary_cache = true,    -- Reference the cached summary
        include_book_context = true,
        requires_summary_cache = true,  -- Trigger pre-flight cache check
        prompt = [[Explain this passage in context:

"{highlighted_text}"

From "{title}"{author_clause}.

{summary_cache_section}

Using the document summary above as context, help me understand:
1. What this passage means
2. How it relates to the document's main themes and arguments
3. Key concepts or references it builds on

{conciseness_nudge}

Note: The summary may be in a different language than your response language. Translate or adapt as needed.]],
        api_params = {
            temperature = 0.5,
            max_tokens = 4096,
        },
        builtin = true,
    },
    -- Smart deep analysis using cached summary for efficiency
    analyze_in_context_smart = {
        id = "analyze_in_context_smart",
        text = _("Analyze in Context (Smart)"),
        context = "highlight",
        use_book_text = true,        -- Gate for accessing _summary_cache (derives from book text)
        use_summary_cache = true,    -- Reference the cached summary
        use_annotations = true,      -- Still include user's annotations
        include_book_context = true,
        requires_summary_cache = true,  -- Trigger pre-flight cache check
        prompt = [[Analyze this passage in the broader context of the document:

"{highlighted_text}"

From "{title}"{author_clause}.

{summary_cache_section}

{annotations_section}

Provide deeper analysis:
1. **Significance**: Why might this passage matter in the larger work?
2. **Connections**: How does it relate to the document's main themes and arguments?
3. **Patterns**: Does it echo or develop ideas mentioned in the summary?
4. **My notes**: If I've highlighted related passages, show those connections.

{conciseness_nudge}

Note: The summary may be in a different language than your response language. Translate or adapt as needed.]],
        api_params = {
            temperature = 0.6,
            max_tokens = 4096,
        },
        builtin = true,
    },
    -- Thematic Connection (Smart): Analyze how passage relates to larger themes
    thematic_connection_smart = {
        id = "thematic_connection_smart",
        text = _("Thematic Connection (Smart)"),
        context = "highlight",
        use_book_text = true,        -- Gate for accessing _summary_cache
        use_summary_cache = true,    -- Reference the cached summary
        include_book_context = true,
        requires_summary_cache = true,  -- Trigger pre-flight cache check
        prompt = [[Analyze how this passage connects to the larger themes of the work:

"{highlighted_text}"

From "{title}"{author_clause}.

{summary_cache_section}

Show me the connections:

## Theme Alignment
Which major themes from the summary does this passage touch on? How does it develop, reinforce, or complicate them?

## Significance
Why might this particular passage matter in the context of the whole work? What work is it doing?

## Echoes & Patterns
Does this passage echo earlier ideas, or introduce something new? Does it resolve, extend, or subvert established patterns?

## Craft
How does the author's choice of language, structure, or placement enhance the thematic resonance?

Keep analysis grounded in the specific passage while connecting to the broader context. {conciseness_nudge}

Note: The summary may be in a different language than your response language. Translate or adapt as needed.]],
        api_params = {
            temperature = 0.6,
            max_tokens = 4096,
        },
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
            max_tokens = 4096,
        },
        builtin = true,
        in_quick_actions = 3,     -- Appears in Quick Actions menu
    },
    similar_books = {
        id = "similar_books",
        text = _("Find Similar"),
        context = "book",
        template = "similar_books",
        api_params = {
            temperature = 0.8,  -- More creative for recommendations
            max_tokens = 4096,
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
            max_tokens = 4096,
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
            max_tokens = 4096,
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
        use_annotations = true,
        use_reading_progress = true,
        prompt = [[Create a reader's companion for "{title}"{author_clause}.

I'm at {reading_progress}.

{highlights_section}

{book_text_section}

First, determine if this is FICTION or NON-FICTION, then build a reference guide using the appropriate structure. Cover ONLY what's happened up to my current position.

---

**FOR FICTION, use this structure:**

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

---

**FOR NON-FICTION, use this structure:**

## Key Figures
People discussed or referenced (aim for 8-12):
**[Name]** — Who they are. Their role in the argument. Key ideas associated with them.

## Core Concepts
Main ideas and frameworks introduced so far (aim for 6-10):
**[Concept]** — What it means. How the author uses it.

## Arguments
The author's key claims so far (aim for 4-6):
**[Claim]** — The argument. Evidence or reasoning provided.

## Terminology
Technical terms or specialized vocabulary (aim for 5-8):
**[Term]** — Definition and how it's used in this work.

## Argument Development
How the thesis has built so far (chronological, 6-10 points):
- **[Chapter/Section]:** Key point made and how it advances the overall argument.

## Current Position
Where the argument stands at {reading_progress}:
- What was just established
- Questions being addressed
- What the author seems to be building toward
- Gaps or tensions in the argument so far

---

**Length guidance:** Keep this X-Ray concise and practical as a quick reference guide. Prioritize the most significant elements in each category rather than being exhaustive. For longer works, be selective.

CRITICAL: Do not reveal ANYTHING beyond {reading_progress}. This must be completely spoiler-free.

If you don't recognize this work or the content seems unclear, tell me honestly rather than guessing or making things up. I can provide more context if needed.]],
        skip_language_instruction = false,
        skip_domain = true,  -- X-Ray has specific structure
        -- Inherits global reasoning setting (user choice)
        api_params = {
            temperature = 0.5,
            max_tokens = 8192,
        },
        builtin = true,
        in_reading_features = 1,  -- Appears in Reading Features menu + default gesture
        in_quick_actions = 1,     -- Appears in Quick Actions menu
        -- Document cache: save result for other actions to reference via {xray_cache_section}
        cache_as_xray = true,
        -- Response caching: enables incremental updates as reading progresses
        use_response_caching = true,
        update_prompt = [[Update this X-Ray for "{title}"{author_clause}.

Previous analysis (at {cached_progress}):
{cached_result}

New content since then (now at {reading_progress}):
{incremental_book_text_section}

Update the X-Ray to incorporate new developments. Maintain the same structure (Cast/World/Ideas/Lexicon/Story Arc/Current State for fiction, or Key Figures/Core Concepts/Arguments/Terminology/Argument Development/Current Position for non-fiction).

Guidelines:
- Add new characters, locations, themes, or concepts that appeared
- Update the "Current State" or "Current Position" section for the new progress point
- Keep existing entries, modify only if new information changes them
- Do not remove anything unless clearly contradicted
- Preserve the original tone and formatting
- Keep total length practical - consolidate earlier content as needed to stay concise

CRITICAL: This must remain spoiler-free up to {reading_progress}. Do not reveal anything beyond the current position.]],
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
        prompt = [[Help me get back into "{title}"{author_clause}.

I'm at {reading_progress} and last read {time_since_last_read}.

{book_text_section}

Write a quick recap to help me re-immerse. Adapt your approach based on content type:

**For FICTION** - Use a "Previously on..." narrative style:
1. **Sets the scene** - The story's situation at this point
2. **Recent events** - What happened recently (prioritize recent over early)
3. **Active threads** - Conflicts, mysteries, or goals in play
4. **Where I stopped** - The specific moment or scene where I paused

**For NON-FICTION** - Use a "Where we left off..." refresher style:
1. **Main thesis** - The author's central argument (briefly)
2. **Recent ground covered** - Key points from recent chapters
3. **Current focus** - What the author is currently examining
4. **Building toward** - What questions or arguments are being developed

Style guidance:
- Match the work's tone (suspenseful for thrillers, rigorous for academic, accessible for popular non-fiction)
- Use **bold** for key names, terms, and concepts
- Use *italics* for important revelations or claims
- Keep it concise - this is a refresher, not a full summary
- No spoilers beyond {reading_progress}

If you don't recognize this work or the title/content seems unclear, tell me honestly rather than guessing. I can provide more context if needed.]],
        skip_language_instruction = false,
        skip_domain = true,
        -- Inherits global reasoning setting (user choice)
        api_params = {
            temperature = 0.7,
            max_tokens = 4096,
        },
        builtin = true,
        in_reading_features = 2,  -- Appears in Reading Features menu + default gesture
        in_quick_actions = 2,     -- Appears in Quick Actions menu
        -- Response caching: enables incremental updates as reading progresses
        use_response_caching = true,
        update_prompt = [[Update this Recap for "{title}"{author_clause}.

Previous recap (at {cached_progress}):
{cached_result}

New content since then (now at {reading_progress}):
{incremental_book_text_section}

Update the recap to reflect where the story/argument now stands.

Guidelines:
- Build on the previous recap, don't repeat it entirely
- Focus on what's NEW since {cached_progress}
- Update the "Where I stopped" or "Current focus" section for the new position
- Keep the same tone and style as the original recap
- Maintain the appropriate structure (fiction vs non-fiction)
- Keep total length concise - summarize earlier content more briefly as you go

CRITICAL: No spoilers beyond {reading_progress}.]],
    },
    -- Analyze Highlights: Insights from user's annotations and notebook
    analyze_highlights = {
        id = "analyze_highlights",
        text = _("Analyze Highlights"),
        context = "book",
        behavior_variant = "reader_assistant",
        -- Context extraction flags
        use_annotations = true,
        use_reading_progress = true,
        use_notebook = true,
        prompt = [[Reflect on my reading of "{title}"{author_clause} through my highlights and notes.

I'm at {reading_progress}. Here's what I've marked:

{annotations_section}

{notebook_section}

Analyze MY READING PATTERNS, not just the content:

## What Catches My Attention
What types of passages do I tend to highlight? (dialogue, descriptions, ideas, emotions, plot points?)
What does this suggest about what I find valuable in this work?

## Emerging Threads
Looking at my highlights as a collection, what themes or ideas am I tracking?
Are there connections between highlights I might not have noticed?

## My Notes Tell a Story
What do my notes reveal about my thinking? How is my understanding or reaction evolving?

## Questions I Seem to Be Asking
Based on what I highlight, what larger questions might I be exploring?
What am I curious about or paying attention to?

## Suggestions
Based on my highlighting patterns:
- Parts I might want to revisit
- Themes to watch for going forward
- Connections to other ideas or works

This is about understanding ME as a reader through my highlights and notes, not summarizing the work.

If you don't recognize this work or the highlights seem insufficient for meaningful analysis, let me know honestly rather than guessing.]],
        skip_language_instruction = false,
        skip_domain = true,
        -- Inherits global reasoning setting (user choice)
        api_params = {
            temperature = 0.5,
            max_tokens = 4096,
        },
        builtin = true,
        in_reading_features = 3,  -- Appears in Reading Features menu + default gesture
    },
    -- Related Thinkers: Intellectual landscape and influences
    related_thinkers = {
        id = "related_thinkers",
        text = _("Related Thinkers"),
        context = "book",
        -- No behavior_variant - uses user's global behavior
        -- No skip_domain - domain expertise helps here
        prompt = [[For "{title}"{author_clause}, map the intellectual landscape:

## Influences (Who shaped this author's thinking)
- Direct mentors or acknowledged influences
- Intellectual traditions they draw from
- Contemporary debates they're responding to

## Influenced (Who this author has shaped)
- Notable followers or critics
- Movements or fields impacted
- How the ideas spread or evolved

## Contemporaries (Working on similar problems)
- Other thinkers in the same space
- Key areas of agreement and disagreement
- Complementary perspectives worth exploring

If this is fiction, focus on literary influences, movements, and stylistic descendants instead.

Aim for the most significant connections, not an exhaustive list. {conciseness_nudge} {hallucination_nudge}]],
        api_params = {
            temperature = 0.7,
            max_tokens = 4096,
        },
        builtin = true,
    },
    -- Key Arguments: Thesis and argument analysis
    key_arguments = {
        id = "key_arguments",
        text = _("Key Arguments"),
        context = "book",
        use_book_text = true,  -- Gate for accessing {analyze_cache_section} cache
        -- No behavior_variant - uses user's global behavior
        -- No skip_domain - domain expertise shapes analysis approach
        prompt = [[Analyze the main arguments in "{title}"{author_clause}.
{analyze_cache_section}

## Core Thesis
What is the central claim or argument?

## Supporting Arguments
What are the key sub-claims that support the thesis?

## Evidence & Methodology
What types of evidence does the author use?
What's their approach to building the argument?

## Assumptions
What does the author take for granted?
What premises underlie the argument?

## Counterarguments
What would critics say?
What are the strongest objections to this position?

## Intellectual Context
What debates is this work participating in?
What's the "so what" — why does this argument matter?

If this is fiction, adapt to analyze themes, messages, and the author's apparent worldview instead of formal arguments.

This is an overview, not an essay. {conciseness_nudge} {hallucination_nudge}]],
        api_params = {
            temperature = 0.6,
            max_tokens = 4096,
        },
        builtin = true,
    },
    -- Discussion Questions: Book club and classroom prompts
    discussion_questions = {
        id = "discussion_questions",
        text = _("Discussion Questions"),
        context = "book",
        use_book_text = true,  -- Permission gate for text extraction
        -- User can mention reading progress in follow-up if needed
        prompt = [[Generate thoughtful discussion questions for "{title}"{author_clause}.
{full_document_section}

Create 8-10 questions that could spark good conversation:

## Comprehension Questions (2-3)
Questions that check understanding of key points/events

## Analytical Questions (3-4)
Questions about how and why — motivations, techniques, implications

## Interpretive Questions (2-3)
Questions with multiple valid answers that invite debate

## Personal Connection Questions (1-2)
Questions that connect the work to the reader's own experience/views

Adapt to content type:
- For fiction: Focus on character decisions, themes, craft choices
- For non-fiction: Focus on arguments, evidence, real-world applications
- For academic: Include questions about methodology and scholarly implications

{conciseness_nudge}

Note: These are general questions for the complete work. If the reader is mid-book, they can ask for spoiler-free questions in the follow-up. {hallucination_nudge}]],
        api_params = {
            temperature = 0.7,
            max_tokens = 4096,
        },
        builtin = true,
    },
    -- Discussion Questions (Smart): Generate discussion prompts using cached summary
    discussion_questions_smart = {
        id = "discussion_questions_smart",
        text = _("Discussion Questions (Smart)"),
        context = "book",
        use_book_text = true,        -- Gate for accessing _summary_cache
        use_summary_cache = true,    -- Reference the cached summary
        requires_summary_cache = true,  -- Trigger pre-flight cache check
        prompt = [[Generate thoughtful discussion questions for "{title}"{author_clause}.

{summary_cache_section}

Create 8-10 questions that could spark good conversation:

## Comprehension Questions (2-3)
Questions that check understanding of key points/events

## Analytical Questions (3-4)
Questions about how and why — motivations, techniques, implications

## Interpretive Questions (2-3)
Questions with multiple valid answers that invite debate

## Personal Connection Questions (1-2)
Questions that connect the work to the reader's own experience/views

Adapt to content type:
- For fiction: Focus on character decisions, themes, craft choices
- For non-fiction: Focus on arguments, evidence, real-world applications

{conciseness_nudge} {hallucination_nudge}

Note: The summary may be in a different language than your response language. Translate or adapt as needed.]],
        skip_domain = true,  -- Discussion format is standardized
        api_params = {
            temperature = 0.7,
            max_tokens = 4096,
        },
        builtin = true,
    },
    -- Generate Quiz (Smart): Create comprehension questions using cached summary
    generate_quiz_smart = {
        id = "generate_quiz_smart",
        text = _("Generate Quiz (Smart)"),
        context = "book",
        use_book_text = true,        -- Gate for accessing _summary_cache
        use_summary_cache = true,    -- Reference the cached summary
        requires_summary_cache = true,  -- Trigger pre-flight cache check
        prompt = [[Create a comprehension quiz for "{title}"{author_clause}.

{summary_cache_section}

Generate 8-10 questions with answers to test understanding:

## Multiple Choice (3-4 questions)
Test recall of key facts, characters, or concepts.
Format: Question, options A-D, correct answer with brief explanation.

## Short Answer (3-4 questions)
Test understanding of themes, arguments, or motivations.
Format: Question, then model answer (2-3 sentences).

## Discussion/Essay (2 questions)
Open-ended questions requiring synthesis or analysis.
Format: Question, then key points a good answer should cover.

Adapt to content type:
- Fiction: Focus on plot, characters, themes, narrative choices
- Non-fiction: Focus on arguments, evidence, key concepts, implications

{conciseness_nudge} {hallucination_nudge}

Note: The summary may be in a different language than your response language. Translate or adapt as needed.]],
        skip_domain = true,  -- Quiz format is standardized
        api_params = {
            temperature = 0.6,  -- Balanced variety
            max_tokens = 4096,
        },
        builtin = true,
    },
    -- Analyze Full Document: Complete document analysis for short content
    analyze_full_document = {
        id = "analyze_full_document",
        text = _("Analyze Document"),
        context = "book",
        use_book_text = true,  -- Permission gate (UI: "Allow text extraction")
        cache_as_analyze = true,  -- Save for other actions via {analyze_cache_section}
        prompt = [[Analyze this document: "{title}"{author_clause}.

{full_document_section}

Provide analysis appropriate to this document's type and purpose. Address what's relevant:
- Core thesis, argument, or narrative
- Structure and organization of ideas
- Key insights, findings, or themes
- Intended audience and context
- Strengths and areas for improvement]],
        -- No skip_domain, no skip_behavior - relies on user's configured settings
        api_params = {
            temperature = 0.5,
            max_tokens = 8192,
        },
        builtin = true,
    },
    -- Summarize Full Document: Condense content without evaluation
    -- Uses canonical SUMMARY_PROMPT - the "workhorse" for Smart actions
    summarize_full_document = {
        id = "summarize_full_document",
        text = _("Summarize Document"),
        context = "book",
        use_book_text = true,  -- Permission gate (UI: "Allow text extraction")
        cache_as_summary = true,  -- Save for other actions via {summary_cache_section}
        prompt = Actions.SUMMARY_PROMPT,  -- Canonical summary prompt
        api_params = {
            temperature = 0.4,
            max_tokens = 8192,
        },
        builtin = true,
    },
    -- Extract Key Insights: Actionable takeaways worth remembering
    extract_insights = {
        id = "extract_insights",
        text = _("Extract Key Insights"),
        context = "book",
        use_book_text = true,  -- Permission gate (UI: "Allow text extraction")
        prompt = [[Extract key insights from: "{title}"{author_clause}.

{full_document_section}

What are the most important takeaways? Focus on:
- Ideas worth remembering
- Novel perspectives or findings
- Actionable conclusions
- Connections to broader concepts]],
        api_params = {
            temperature = 0.5,
            max_tokens = 8192,
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
            max_tokens = 4096,
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
            max_tokens = 4096,
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
    reading_order = {
        id = "reading_order",
        text = _("Reading Order"),
        context = "multi_book",
        template = "reading_order",
        api_params = {
            temperature = 0.6,
            max_tokens = 4096,
        },
        builtin = true,
    },
}

-- Built-in actions for general context
Actions.general = {
    news_update = {
        id = "news_update",
        text = _("News Update"),
        context = "general",
        prompt = [[Get me a brief news update from Al Jazeera's most important stories today.

For each story provide:
- Headline
- 1-2 sentence summary
- Why it matters
- Link to the story on aljazeera.com

Focus on the top 3-5 most significant global news stories. Keep it concise and factual.]],
        enable_web_search = true,  -- Force web search even if global setting is off
        skip_domain = true,  -- News doesn't need domain context
        api_params = {
            temperature = 0.3,  -- Low temp for factual reporting
            max_tokens = 4096,  -- Buffer for Gemini 2.5 thinking tokens
        },
        builtin = true,
        in_gesture_menu = true,  -- Available in gesture menu by default
    },
}

-- Special actions (context-specific overrides)
Actions.special = {
    translate = {
        id = "translate",
        text = _("Translate"),
        context = "highlight",  -- Only for highlighted text
        behavior_variant = "translator_direct",  -- Use built-in translation behavior
        in_highlight_menu = 1,  -- Default in highlight menu
        prompt = "Translate this to {translation_language}: {highlighted_text}",
        include_book_context = false,
        extended_thinking = "off",  -- Translations don't benefit from extended thinking
        skip_language_instruction = true,  -- Target language already in prompt
        skip_domain = true,  -- Domain context not relevant for translations
        translate_view = true,  -- Use special translate view
        api_params = {
            temperature = 0.3,  -- Very deterministic for translations
            max_tokens = 8192,  -- Long passages need room
        },
        builtin = true,
    },
    quick_define = {
        id = "quick_define",
        text = _("Quick Define"),
        context = "highlight",  -- Only for highlighted text
        behavior_variant = "dictionary_direct",  -- Use built-in dictionary behavior
        in_dictionary_popup = 2,  -- Default order in dictionary popup
        prompt = [[Define "{highlighted_text}"

Write entirely in {dictionary_language}. Only the headword stays in original language.

**{highlighted_text}**, part of speech — definition

{context_section}

One line only. No etymology, no synonyms. No headers.]],
        include_book_context = false,  -- Word definitions don't typically need book metadata
        extended_thinking = "off",  -- Dictionary lookups don't benefit from extended thinking
        skip_language_instruction = true,  -- Target language already in prompt
        skip_domain = true,  -- Domain context not relevant for dictionary lookups
        compact_view = true,  -- Always use compact dictionary view
        minimal_buttons = true,  -- Use dictionary-specific buttons
        -- storage_key set dynamically based on dictionary_disable_auto_save setting
        api_params = {
            temperature = 0.3,  -- Deterministic for definitions
            max_tokens = 4096,  -- Buffer for Gemini 2.5 thinking tokens
        },
        builtin = true,
    },
    dictionary = {
        id = "dictionary",
        text = _("Dictionary"),
        context = "highlight",  -- Only for highlighted text
        behavior_variant = "dictionary_direct",  -- Use built-in dictionary behavior
        in_dictionary_popup = 1,  -- Default order in dictionary popup
        prompt = [[Dictionary entry for "{highlighted_text}"

Write entirely in {dictionary_language}. Only the headword, lemma, and synonyms stay in original language.

**{highlighted_text}** /IPA/ part of speech of **lemma**
Definition(s), numbered if multiple
Etymology (brief)
Synonyms

{context_section}

All labels and explanations in {dictionary_language}. Inline bold labels, no headers. Concise.]],
        include_book_context = false,  -- Word definitions don't typically need book metadata
        extended_thinking = "off",  -- Dictionary lookups don't benefit from extended thinking
        skip_language_instruction = true,  -- Target language already in prompt
        skip_domain = true,  -- Domain context not relevant for dictionary lookups
        compact_view = true,  -- Always use compact dictionary view
        minimal_buttons = true,  -- Use dictionary-specific buttons
        -- storage_key set dynamically based on dictionary_disable_auto_save setting
        api_params = {
            temperature = 0.3,  -- Deterministic for definitions
            max_tokens = 4096,  -- Buffer for Gemini 2.5 thinking tokens
        },
        builtin = true,
    },
    deep = {
        id = "dictionary_deep",
        text = _("Deep Analysis"),
        context = "highlight",  -- Only for highlighted text
        behavior_variant = "dictionary_detailed",  -- Use built-in detailed dictionary behavior
        in_dictionary_popup = 3,  -- Default order in dictionary popup
        prompt = [[Deep analysis of the word "{highlighted_text}":

**{highlighted_text}** /IPA/ _part of speech_ of **lemma**

**Morphology:** [Semitic: root + pattern/wazn + verb form if applicable | IE: stem + affixes + compounds | Other: what's morphologically salient]

**Word Family:** Related forms from same root/stem, showing how derivation affects meaning

**Etymology:** Origin → transmission path → semantic shifts

**Cognates:** Related words in sister languages; notable borrowings

{context_section}

When context is provided, note how this specific form or sense fits the passage, but still analyze the lemma comprehensively. Flag homographs or polysemy when relevant.

Write in {dictionary_language}. Headwords, lemmas, and cognates stay in original script. Inline bold labels, no headers. {conciseness_nudge}]],
        include_book_context = false,
        extended_thinking = "off",
        skip_language_instruction = true,
        skip_domain = true,  -- Domain context not relevant for dictionary lookups
        -- storage_key set dynamically based on dictionary_disable_auto_save setting
        api_params = {
            temperature = 0.3,
            max_tokens = 4096,  -- Detailed analysis needs more space
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

    -- Sort alphabetically by action text for predictable ordering
    table.sort(result, function(a, b)
        return (a.text or "") < (b.text or "")
    end)

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

-- Determine if an action requires an open book (dynamically inferred)
-- Returns true if action uses any data that requires reading mode
-- Uses centralized OPEN_BOOK_FLAGS list for consistency
-- @param action: Action definition
-- @return boolean: true if action requires an open book
function Actions.requiresOpenBook(action)
    if not action then return false end

    -- Explicit flag takes precedence
    if action.requires_open_book then
        return true
    end

    -- Check all centralized flags
    for _, flag in ipairs(Actions.OPEN_BOOK_FLAGS) do
        if action[flag] then
            return true
        end
    end

    return false
end

-- Infer open book flags from prompt/template text
-- Scans for placeholders that require reading mode and returns the flags to set
-- @param prompt_text: The action's prompt or template text
-- @return table: Map of flag_name -> true for inferred flags (empty if none)
function Actions.inferOpenBookFlags(prompt_text)
    if not prompt_text or prompt_text == "" then
        return {}
    end

    local inferred_flags = {}

    -- Scan for all known placeholders
    for placeholder, flag in pairs(Actions.PLACEHOLDER_TO_FLAG) do
        if prompt_text:find(placeholder, 1, true) then -- plain string match
            inferred_flags[flag] = true
        end
    end

    -- Cascade: flags that derive from book text also require use_book_text
    for _idx, flag in ipairs(Actions.REQUIRES_BOOK_TEXT) do
        if inferred_flags[flag] then
            inferred_flags["use_book_text"] = true
            break
        end
    end

    -- Cascade: flags that derive from annotations also require use_annotations
    for _idx, flag in ipairs(Actions.REQUIRES_ANNOTATIONS) do
        if inferred_flags[flag] then
            inferred_flags["use_annotations"] = true
            break
        end
    end

    return inferred_flags
end

-- Check if an action's requirements are met
-- @param action: Action definition
-- @param metadata: Available metadata (title, author, has_open_book, etc.)
--   - has_open_book: nil = don't filter (management mode), false = filter, true = show all
-- @return boolean: true if requirements are met
function Actions.checkRequirements(action, metadata)
    metadata = metadata or {}

    -- Check if action requires an open book (for reading data access)
    -- Uses dynamic inference from flags, not just explicit requires_open_book
    -- Only filter when has_open_book is explicitly false (not nil - nil means management mode)
    if Actions.requiresOpenBook(action) and metadata.has_open_book == false then
        return false
    end

    -- Check metadata requirements (author, title)
    if action.requires then
        if action.requires == "author" then
            return metadata.author and metadata.author ~= ""
        elseif action.requires == "title" then
            return metadata.title and metadata.title ~= ""
        end
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
