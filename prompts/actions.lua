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
--   context          - Where it appears: "highlight", "book", "multi_book", "general", "both" (required)
--   template         - User prompt template ID from templates.lua (required for builtin)
--   prompt           - Direct user prompt text (for custom actions without template)
--   behavior_variant - Override global behavior: "minimal", "full", "none" (optional)
--   behavior_override- Custom behavior text, replaces variant entirely (optional)
--   extended_thinking- Override global thinking: "off" to disable, "on" to enable (optional)
--   thinking_budget  - Token budget when extended_thinking="on" (1024-32000, default 4096)
--   api_params       - Optional API parameters: { temperature, max_tokens }
--   skip_language_instruction - Don't include user's language preferences in system prompt (optional)
--   include_book_context - Include book metadata with highlight context (optional)
--   description      - Human-readable summary of what the action does (optional, shown in details view)
--   enabled          - Default enabled state (default: true)
--   builtin          - Whether this is a built-in action (default: true for this file)
--   storage_key      - Override chat save location (optional):
--                      nil/unset: Default (current document, or __GENERAL_CHATS__ for general context)
--                      "__SKIP__": Don't save this chat at all
--                      Custom string: Save to that pseudo-document

local _ = require("koassistant_gettext")

local Actions = {}

-- ============================================================
-- Open Book Flags - Centralized Definition
-- ============================================================
-- Actions that use these flags require an open book (reading mode)
-- and won't appear in file browser context

-- List of flags that indicate an action needs reading mode data
Actions.OPEN_BOOK_FLAGS = {
    "use_book_text",
    "use_reading_progress",
    "use_highlights",
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

    -- Highlights placeholders (just highlighted text, no notes)
    ["{highlights}"] = "use_highlights",
    ["{highlights_section}"] = "use_highlights",

    -- Annotations placeholders (highlights + user notes; degrades to highlights-only)
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

-- Flags that require use_highlights to be set (cascading requirement)
-- X-Ray cache includes highlight data, so accessing it needs highlight permission
Actions.REQUIRES_HIGHLIGHTS = {
    "use_xray_cache",  -- X-Ray uses {highlights_section}
}

-- Flags that are double-gated (require global consent + explicit per-action checkbox)
-- These must NEVER be auto-inferred from placeholders - user must tick checkbox
-- Security model: prevents accidental data exposure when user adds a placeholder
Actions.DOUBLE_GATED_FLAGS = {
    "use_book_text",      -- gate: enable_book_text_extraction
    "use_highlights",     -- gate: enable_highlights_sharing
    "use_annotations",    -- gate: enable_annotations_sharing (degrades to highlights)
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
        description = _("Explains the selected passage clearly, matching the tone of the source material."),
        context = "highlight",
        template = "explain",
        in_highlight_menu = 4,  -- Default in highlight menu
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
        enable_web_search = false,
        text = _("ELI5"),
        description = _("Simplifies the passage into everyday language using analogies and concrete examples, without sacrificing accuracy."),
        context = "highlight",
        template = "eli5",
        -- Uses global behavior variant
        api_params = {
            temperature = 0.6,
            max_tokens = 4096,
        },
        include_book_context = true,
        builtin = true,
        in_highlight_menu = 3,    -- Appears in Highlight menu
    },
    summarize = {
        id = "summarize",
        enable_web_search = false,
        text = _("Summarize"),
        description = _("Condenses the selected passage to its essential points, keeping what matters and trimming the rest."),
        context = "highlight",
        template = "summarize",
        -- Uses global behavior variant
        api_params = {
            temperature = 0.4,  -- More deterministic for summaries
            max_tokens = 4096,
        },
        include_book_context = true,
        in_highlight_menu = 6,
        builtin = true,
    },
    elaborate = {
        id = "elaborate",
        enable_web_search = false,
        text = _("Elaborate"),
        description = _("Expands on the passage by unpacking concepts, adding context, and exploring implications."),
        context = "highlight",
        template = "elaborate",
        -- Uses global behavior variant
        api_params = {
            temperature = 0.7,  -- Balanced for expansive but coherent elaboration
            max_tokens = 4096,
        },
        include_book_context = true,
        in_highlight_menu = 5,
        builtin = true,
    },
    connect = {
        id = "connect",
        text = _("Connect"),
        description = _("Finds connections between the passage and broader themes, other works, thinkers, and intellectual traditions."),
        context = "highlight",
        prompt = [[Draw connections from this passage:

{highlighted_text}

Explore how it relates to:
- Other themes or ideas in this work
- Other books, thinkers, or intellectual traditions
- Broader historical or cultural context

Surface connections that enrich understanding, not tangential trivia. {conciseness_nudge} {hallucination_nudge}]],
        include_book_context = true,
        api_params = {
            temperature = 0.7,
            max_tokens = 4096,
        },
        in_highlight_menu = 7,
        builtin = true,
    },
    connect_with_notes = {
        id = "connect_with_notes",
        enable_web_search = false,
        text = _("Connect (With Notes)"),
        description = _("Connects the passage to your own highlights and notebook entries, revealing patterns and echoes in your reading. Requires annotations and notebook sharing to be enabled."),
        context = "highlight",
        behavior_variant = "reader_assistant",
        include_book_context = true,
        requires = {"highlights"},      -- Block if no highlight-type data can reach the prompt
        -- Context extraction flags
        use_highlights = true,
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
        enable_web_search = false,
        text = _("Explain in Context"),
        description = _("Explains the passage using the full document text for deeper, contextualized understanding. Requires text extraction; without it, falls back to AI knowledge of the work."),
        context = "highlight",
        use_book_text = true,
        include_book_context = true,
        prompt = [[Explain this passage in context:

"{highlighted_text}"

From "{title}"{author_clause}.

{full_document_section}

Help me understand:
1. What this passage means
2. How it connects to the broader work
3. Key references or concepts it builds on

{conciseness_nudge}

{text_fallback_nudge}]],
        api_params = {
            temperature = 0.5,
            max_tokens = 4096,
        },
        builtin = true,
    },
    analyze_in_context = {
        id = "analyze_in_context",
        enable_web_search = false,
        text = _("Analyze in Context"),
        description = _("Deep analysis of the passage within the full document, connecting it to themes and your annotations. Requires text extraction; also uses your annotations if shared."),
        context = "highlight",
        use_book_text = true,
        use_highlights = true,           -- Annotations imply highlights
        use_annotations = true,
        include_book_context = true,
        prompt = [[Analyze this passage in the broader context of the work:

"{highlighted_text}"

From "{title}"{author_clause}.

{full_document_section}

{annotations_section}

Provide deeper analysis:
1. **Significance**: Why might this passage matter in the larger work?
2. **Connections**: How does it relate to the work's themes, arguments, or events?
3. **Patterns**: Does it echo or develop ideas from elsewhere in the text?
4. **My notes**: If I've highlighted related passages, show those connections.

{conciseness_nudge}

{text_fallback_nudge}]],
        api_params = {
            temperature = 0.6,
            max_tokens = 4096,
        },
        builtin = true,
    },
    -- Smart context-aware action using cached summary for efficiency
    explain_in_context_smart = {
        id = "explain_in_context_smart",
        enable_web_search = false,
        text = _("Explain in Context") .. " (Smart)",
        description = _("Like Explain in Context, but uses a pre-built Summary Cache instead of the full text — faster and cheaper, though less detailed. Requires generating a Summary Cache first."),
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
        enable_web_search = false,
        text = _("Analyze in Context") .. " (Smart)",
        description = _("Like Analyze in Context, but uses a pre-built Summary Cache instead of the full text. Still includes your annotations if shared. Requires generating a Summary Cache first."),
        context = "highlight",
        use_book_text = true,        -- Gate for accessing _summary_cache (derives from book text)
        use_highlights = true,       -- Annotations imply highlights
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
        enable_web_search = false,
        text = _("Thematic Connection") .. " (Smart)",
        description = _("Analyzes how a passage connects to the work's major themes — alignment, significance, recurring patterns, and the author's craft. Uses Summary Cache."),
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
    -- Web-enhanced highlight actions (force web search on)
    fact_check = {
        id = "fact_check",
        enable_web_search = true,  -- Force web search even if global setting is off
        text = _("Fact Check"),
        description = _("Searches the web to verify claims in the selected passage, rating accuracy and citing current sources as evidence."),
        context = "highlight",
        include_book_context = true,
        in_highlight_menu = 8,
        skip_domain = true,  -- Fact-checking format is standardized
        prompt = [[Fact-check this claim or statement:

"{highlighted_text}"

Search for current, reliable sources to verify accuracy. For each claim:

**Verdict:** Accurate / Partially accurate / Misleading / Inaccurate / Unverifiable

**Evidence:** What do current sources say? Cite specific findings.

**Nuance:** Important context, caveats, or recent developments that affect the claim's accuracy.

If multiple claims are present, address each separately. If the passage is opinion rather than factual claim, note that and assess the underlying factual premises instead.

{conciseness_nudge} {hallucination_nudge}]],
        api_params = {
            temperature = 0.3,  -- Low temp for factual accuracy
            max_tokens = 4096,
        },
        builtin = true,
    },
    current_context = {
        id = "current_context",
        enable_web_search = true,  -- Force web search even if global setting is off
        text = _("Current Context"),
        description = _("Searches the web for the latest developments on the topic discussed in the selected passage — what has changed since the book was written."),
        context = "highlight",
        include_book_context = true,
        skip_domain = true,  -- Current events format is standardized
        prompt = [[What is the current state of this topic?

"{highlighted_text}"

Search for the latest information and tell me:

**Current State:** What's the situation now? What has changed or developed recently?

**Key Developments:** Major events, discoveries, or shifts since this was written.

**Outlook:** Where are things heading? What to watch for.

Focus on what's genuinely new or different from what the text describes. If the text is still fully current, say so.

{conciseness_nudge} {hallucination_nudge}]],
        api_params = {
            temperature = 0.5,
            max_tokens = 4096,
        },
        builtin = true,
    },
    -- Local X-Ray lookup: search cached X-Ray data for selected text (no AI call)
    xray_lookup = {
        id = "xray_lookup",
        enable_web_search = false,
        text = _("Look up in X-Ray"),
        description = _("Search X-Ray cache for selected text. Local lookup — no AI call, works offline."),
        context = "highlight",
        local_handler = "xray_lookup",
        requires_open_book = true,
        requires_xray_cache = true,
        in_highlight_menu = 2,
        in_dictionary_popup = 6,
        no_duplicate = true,
        builtin = true,
    },
}

-- ============================================================
-- X-Ray Prompt Template (Two-Track: Incremental + Complete)
-- ============================================================
-- One template with __MARKER__ placeholders, two sets of replacements:
--   Incremental (partial): Spoiler-free, current_state/current_position
--   Complete (holistic):   Entire document, conclusion
-- Resolved at file load time into prompt and complete_prompt fields.

local function build_xray_prompt(template, replacements)
    local result = template
    for key, value in pairs(replacements) do
        result = result:gsub(key, function() return value end)
    end
    return result
end

local XRAY_PROMPT_TEMPLATE = [[Create a structured reader's companion for "{title}"{author_clause}.

__SCOPE_LINE__

{highlights_section}

__TEXT_SECTION__

First, determine if this is FICTION or NON-FICTION. Then output ONLY a valid JSON object (no markdown, no code fences, no explanation) using the appropriate schema below. __SCOPE_INSTRUCTION__. Order characters by narrative importance.

---

FOR FICTION, use this JSON schema:
{
  "type": "fiction",
  "characters": [
    {
      "name": "Full Name",
      "aliases": ["Nickname", "Title", "Shortened Name"],
      "role": "Protagonist / Supporting / Antagonist",
      "description": "Who they are, their journey, pivotal moments, and key developments.",
      "connections": ["Other Character (relationship)"]
    }
  ],
  "locations": [
    {
      "name": "Place Name",
      "description": "What it is, its atmosphere, and what the reader encounters there.",
      "significance": "Key events here and why this place matters to the narrative.",
      "references": ["Character or item name"]
    }
  ],
  "themes": [
    {
      "name": "Theme Name",
      "description": "How this theme manifests through characters, conflicts, and events.",
      "references": ["Character or item name"]
    }
  ],
  "lexicon": [
    {
      "term": "Term",
      "definition": "Meaning and relevance to the story."
    }
  ],
  "timeline": [
    {
      "event": "What happened",
      "chapter": "Chapter/Section reference",
      "significance": "Why it mattered and what it changed",
      "characters": ["Names involved"]
    }
  ],
  __FICTION_STATUS__
}

Guidance for fiction:
- **Characters**: The heart of the X-Ray. Be thorough — include all named characters, groups, and entities the reader encounters, not just protagonists. For major characters (protagonist, antagonist, key supporting), write 3-5 sentences covering personality, their arc through the story, pivotal moments or turning points, and their current situation. For minor characters, 1-2 sentences suffice. Always include aliases and connections with relationship type.
- **Locations**: For significant locations, convey atmosphere and what unfolds there. Minor locations need only a brief note. Include references to characters or items associated with each location.
- **Themes**: Be thorough — include all themes, motifs, and recurring ideas, not just the central ones. For major themes, trace how they develop through specific characters, conflicts, and events. For minor motifs or recurring ideas, a brief note suffices. Include references to characters or items that embody each theme.
- **Lexicon**: In-world terms, cultural references, or specialized vocabulary. Keep definitions concise — this is reference material.
- **Timeline**: Be thorough — include all significant events, not just major plot points. Cover character moments, revelations, turning points, and developments across each chapter. Each event should have a chapter reference and involved characters.
- __FICTION_STATUS_GUIDANCE__
- **Output size**: Be comprehensive. Prioritize both depth and breadth. Give detailed entries for significant items and keep minor entries concise.

---

FOR NON-FICTION, use this JSON schema:
{
  "type": "nonfiction",
  "key_figures": [
    {
      "name": "Person Name",
      "aliases": ["Alternate Name", "Shortened Name"],
      "role": "Their role or significance.",
      "description": "Who they are, their key contributions or ideas, how the author engages with them, and their importance to the argument.",
      "connections": ["Related Person (relationship)"]
    }
  ],
  "locations": [
    {
      "name": "Place Name",
      "description": "What it is, its historical or conceptual significance in the text.",
      "significance": "Key events, arguments, or developments associated with this place.",
      "references": ["Key figure or concept name"]
    }
  ],
  "core_concepts": [
    {
      "name": "Concept",
      "description": "What it means and how the author introduces it.",
      "significance": "How the author develops it through evidence, examples, or argument, and why it matters to the thesis.",
      "references": ["Key figure or concept name"]
    }
  ],
  "arguments": [
    {
      "name": "Claim",
      "description": "The argument being made and its stakes.",
      "evidence": "Key evidence, reasoning, and any counter-arguments addressed.",
      "references": ["Key figure or concept name"]
    }
  ],
  "terminology": [
    {
      "term": "Term",
      "definition": "Definition and how it's used in context."
    }
  ],
  "argument_development": [
    {
      "event": "Key point or development",
      "chapter": "Chapter/Section",
      "significance": "How it advances the overall argument or shifts the discussion",
      "references": ["Key figure or concept name"]
    }
  ],
  __NONFICTION_STATUS__
}

Guidance for non-fiction:
- **Key Figures**: Be thorough — include all people, groups, institutions, and historical actors discussed or referenced, not just central figures. For central figures (the author's main interlocutors, key researchers, historical actors), write 3-5 sentences covering who they are, what ideas or work they contribute, how the author engages with them (agrees, critiques, builds on), and their significance to the argument. For briefly mentioned figures, 1-2 sentences. Always include aliases (alternate names, shortened forms, titles the text uses to refer to them) and connections where figures relate to each other.
- **Locations**: Cities, regions, institutions, and historically significant places discussed in the text. For each, note what it is, its significance to the subject matter, and what events or arguments are connected to it. Include references to key figures or concepts associated with each place.
- **Core Concepts**: Be thorough — include all concepts, theories, frameworks, and ideas the author introduces, develops, or critiques. For central concepts, explain what they mean and how the author develops them through evidence, examples, or reasoning. For peripheral concepts, a brief definition suffices. Include references to key figures or other items that develop each concept.
- **Arguments**: Be thorough — include all claims, propositions, and arguments the author advances or engages with, not just the central thesis. For major arguments, capture the claim, evidence or reasoning, and counter-arguments addressed. For minor or supporting arguments, a brief statement suffices. Include references to key figures or concepts involved.
- **Terminology**: Specialized vocabulary, jargon, or terms the author defines. Keep concise — this is reference material.
- **Argument Development**: Track the intellectual progression across the work. Include developments, turning points, and shifts in each chapter or section — not just the main thesis but subsidiary arguments and case studies. Each entry should show how it advances or complicates the discussion. Include references to key figures or concepts involved.
- __NONFICTION_STATUS_GUIDANCE__
- **Output size**: Be comprehensive. Prioritize both depth and breadth. Give detailed entries for significant items and keep minor entries concise.

---

{highlight_analysis_nudge}

__CLOSING__

If you don't recognize this work or lack sufficient detail to provide accurate information, respond with ONLY this JSON:
{"error": "I don't recognize this work. Please provide more context."}
Do NOT attempt to construct an X-Ray with fabricated or uncertain details.]]

local XRAY_PARTIAL_REPLACEMENTS = {
    __SCOPE_LINE__ = [[I'm at {reading_progress}.]],
    __TEXT_SECTION__ = "{book_text_section}",
    __SCOPE_INSTRUCTION__ = "Cover ONLY what's happened up to my current position",
    __FICTION_STATUS__ = [["current_state": {
    "summary": "Where the story stands now — the immediate situation, emotional tone, and narrative momentum.",
    "conflicts": ["Active conflict, tension, or unresolved mystery"],
    "questions": ["Unanswered question the reader is likely thinking about"]
  }]],
    __FICTION_STATUS_GUIDANCE__ = "**Current State**: A paragraph-length summary capturing where things stand, plus active conflicts and open questions.",
    __NONFICTION_STATUS__ = [["current_position": {
    "summary": "Where the argument stands now — what has been established, the current focus, and the intellectual trajectory.",
    "questions_addressed": ["Question or problem being addressed"],
    "building_toward": ["What the author appears to be building toward"]
  }]],
    __NONFICTION_STATUS_GUIDANCE__ = "**Current Position**: A paragraph-length summary of what's been established so far, the current line of inquiry, and where the author seems to be heading.",
    __CLOSING__ = [[CRITICAL: Do not reveal ANYTHING beyond {reading_progress}. This must be completely spoiler-free. Output ONLY valid JSON — no other text. JSON keys must remain in English. Character names, location names, terms, and aliases must be in the same language and script as the source text. All other string values (descriptions, summaries, significance, definitions, connections, etc.) must follow your language instructions.]],
}

local XRAY_COMPLETE_REPLACEMENTS = {
    __SCOPE_LINE__ = "Analyzing the complete document.",
    __TEXT_SECTION__ = "{full_document_section}",
    __SCOPE_INSTRUCTION__ = "Cover the ENTIRE document comprehensively, including all events, resolutions, and conclusions",
    __FICTION_STATUS__ = [["conclusion": {
    "summary": "How the story concludes — the resolution, final state of affairs, and lasting impact.",
    "resolutions": ["How major conflict or tension was resolved"],
    "themes_resolved": ["How key theme played out across the entire work"]
  }]],
    __FICTION_STATUS_GUIDANCE__ = "**Conclusion**: A paragraph-length summary of how the story resolves, plus key resolutions and how themes played out across the work.",
    __NONFICTION_STATUS__ = [["conclusion": {
    "summary": "The document's overall conclusions, key findings, and lasting significance.",
    "key_findings": ["Major conclusion or finding"],
    "implications": ["Practical implication, recommendation, or open question"]
  }]],
    __NONFICTION_STATUS_GUIDANCE__ = "**Conclusion**: A paragraph-length summary of the document's overall conclusions and key findings, plus practical implications.",
    __CLOSING__ = [[Output ONLY valid JSON — no other text. Cover the work comprehensively, including all events, resolutions, and conclusions. JSON keys must remain in English. Character names, location names, terms, and aliases must be in the same language and script as the source text. All other string values (descriptions, summaries, significance, definitions, connections, etc.) must follow your language instructions.]],
}

-- Built-in actions for book context (single book from file browser)
Actions.book = {
    book_info = {
        id = "book_info",
        text = _("Book Info"),
        description = _("Comprehensive overview: what the work is about, its themes, significance, and reading experience. Based on AI knowledge — no book data needed."),
        context = "book",
        template = "book_info",
        use_response_caching = true,
        api_params = {
            temperature = 0.7,
        },
        builtin = true,
        in_quick_actions = 3,     -- Appears in Quick Actions menu
        in_file_browser = 1,
        in_reading_features = 5,  -- After X-Ray Simple (4), AI-knowledge companion
    },
    similar_books = {
        id = "similar_books",
        text = _("Find Similar"),
        description = _("Recommends 5-7 similar works, explaining what makes each one similar and who would prefer which."),
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
        description = _("Biography, major works, writing style, and suggested reading order for the book's author."),
        context = "book",
        template = "explain_author",
        api_params = {
            temperature = 0.7,
            max_tokens = 4096,
        },
        builtin = true,
    },
    historical_context = {
        id = "historical_context",
        text = _("Historical Context"),
        description = _("Explores when the book was written, what was happening at the time, and how the work reflects or responds to its era."),
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
        enable_web_search = false,
        text = _("X-Ray"),
        description = _("Builds a structured reference guide — characters, themes, locations, timeline — up to your current reading position. Completely spoiler-free. When highlights are shared, adds a personal reader engagement section analyzing what catches your attention and patterns in your highlighting. Without highlights, focuses purely on the text content. Requires text extraction; updates incrementally as you read further. Can also generate a complete analysis of the entire document."),
        context = "book",
        behavior_variant = "reader_assistant",
        requires = {"book_text"},       -- Block if text extraction is off
        blocked_hint = _("Or use X-Ray (Simple) for an overview based on AI knowledge."),
        -- Context extraction flags
        use_book_text = true,
        use_highlights = true,
        use_reading_progress = true,
        prompt = build_xray_prompt(XRAY_PROMPT_TEMPLATE, XRAY_PARTIAL_REPLACEMENTS),
        complete_prompt = build_xray_prompt(XRAY_PROMPT_TEMPLATE, XRAY_COMPLETE_REPLACEMENTS),
        skip_language_instruction = false,
        skip_domain = true,  -- X-Ray has specific structure
        -- Inherits global reasoning setting (user choice)
        api_params = {
            temperature = 0.5,
            max_tokens = 65536,  -- X-Ray JSON can be large; Sonnet 4.5 max is 64000
        },
        builtin = true,
        no_duplicate = true,  -- JSON output requires X-Ray browser; duplicates would produce unusable raw JSON in chat
        in_reading_features = 1,  -- Appears in Reading Features menu + default gesture
        in_quick_actions = 1,     -- Appears in Quick Actions menu
        -- Document cache: save result for other actions to reference via {xray_cache_section}
        cache_as_xray = true,
        storage_key = "__SKIP__",  -- Result lives in X-Ray cache, not chat history
        -- Response caching: enables incremental updates as reading progresses
        use_response_caching = true,
        update_prompt = [[Update this X-Ray for "{title}"{author_clause}.

Previous analysis (at {cached_progress}):
{cached_result}

{entity_index}

New content since then (now at {reading_progress}):
{incremental_book_text_section}

{highlights_section}

Output ONLY the new or changed entries as a JSON object. Use exactly the same JSON keys and structure as shown in the previous analysis. Your output will be programmatically merged with the existing data, so:
- OMIT categories entirely if nothing changed in them — they will be preserved as-is
- When adding a new entry to a category, include ONLY the new entries in that category's array
- When modifying an existing entry, output the COMPLETE entry with all fields (it will replace the old version)
- To reference an existing entity, use the EXACT name from the entity list above
- You MUST always include "current_state" (fiction) or "current_position" (nonfiction) — these are always considered changed

If the previous analysis is in plain text rather than JSON, produce a fresh COMPLETE JSON analysis using the appropriate schema for the content type (fiction or nonfiction).

Guidelines:
- Add new characters, locations, themes, concepts, or key figures that appeared in the new content
- Add aliases and connections for new characters/key figures
- Update existing entries only when the new content reveals significant new information (arc developments, turning points, shifting relationships)
- Add new timeline/argument_development entries for events in the new content
- If highlights are provided, consider what the reader found notable

{highlight_analysis_nudge}

CRITICAL: This must remain spoiler-free up to {reading_progress}. Output ONLY valid JSON — no other text. JSON keys must remain in English. Character names, location names, terms, and aliases must be in the same language and script as the source text. All other string values must follow your language instructions.]],
    },
    -- X-Ray (Simple): Prose companion from AI knowledge (no text extraction)
    xray_simple = {
        id = "xray_simple",
        text = _("X-Ray (Simple)"),
        description = _("A prose companion guide from AI knowledge — characters, themes, settings, key terms. No text extraction needed. Uses reading progress to avoid spoilers. Highlights add personal context when shared."),
        context = "book",
        behavior_variant = "reader_assistant",
        use_highlights = true,          -- Optional, gated by enable_highlights_sharing
        use_reading_progress = true,    -- For spoiler avoidance
        -- NO use_book_text — intentionally omitted
        prompt = [[Create a reader's companion for "{title}"{author_clause}.

I'm currently at {reading_progress}. Using your knowledge of this work, provide a spoiler-free reference guide covering ONLY what happens up to approximately this point.

{highlights_section}

## Characters
For each significant character the reader has encountered by this point:
- **Name** — Role and who they are
- Key relationships and connections to other characters
- Their arc and motivations so far (3-5 sentences for major, 1-2 for minor)

## Themes
Major themes emerging up to this point:
- **Theme** — How it manifests through characters, events, or arguments
- How it's developing (not how it resolves)

## Setting
Significant places and world-building:
- **Place** — What it is, its atmosphere, significance, key events there

## Key Terms
Important terminology, in-world vocabulary, or specialized concepts:
- **Term** — Definition and relevance

## Where Things Stand
A paragraph capturing the current state of the narrative or argument — active tensions, open questions, the momentum carrying the reader forward.

Adapt section names for the work type (e.g., "Key Figures" and "Arguments" for non-fiction). Use **bold** for names and terms. If highlights are provided, note what caught the reader's attention and how it connects to the broader work.

CRITICAL: Do not reveal ANYTHING beyond {reading_progress}. No foreshadowing, no future developments, no hints about what comes next.

{conciseness_nudge}
{hallucination_nudge}]],
        skip_domain = true,
        api_params = {
            temperature = 0.5,
            max_tokens = 8192,
        },
        builtin = true,
        in_reading_features = 4,        -- After X-Ray(1), Recap(2), Analyze My Notes(3)
        storage_key = "__SKIP__",       -- Cache, not chat history
        use_response_caching = true,    -- Saves result to ActionCache for cache-first viewing
        -- NO update_prompt — every generation is fresh (regenerate, not incremental)
    },
    -- Recap: Story summary for re-immersion
    recap = {
        id = "recap",
        enable_web_search = false,
        text = _("Recap"),
        description = _("A 'Previously on...' refresher to help you get back into a book after time away. Covers recent events, active threads, and where you left off. Adapts to fiction or non-fiction. When highlights are shared, weaves in what you found notable. Requires text extraction; updates incrementally as you read."),
        context = "book",
        behavior_variant = "reader_assistant",
        -- Context extraction flags
        use_book_text = true,
        use_highlights = true,
        use_reading_progress = true,
        use_reading_stats = true,
        prompt = [[Help me get back into "{title}"{author_clause}.

I'm at {reading_progress} and last read {time_since_last_read}.

{book_text_section}

{highlights_section}

{text_fallback_nudge}

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
- If the reader has highlighted passages, note what they found notable
- No spoilers beyond {reading_progress}

If you don't recognize this work or the title/content seems unclear, tell me honestly rather than guessing. I can provide more context if needed.]],
        skip_language_instruction = false,
        skip_domain = true,
        -- Inherits global reasoning setting (user choice)
        api_params = {
            temperature = 0.7,
            max_tokens = 8192,
        },
        builtin = true,
        in_reading_features = 2,  -- Appears in Reading Features menu + default gesture
        in_quick_actions = 2,     -- Appears in Quick Actions menu
        -- Response caching: enables incremental updates as reading progresses
        storage_key = "__SKIP__",       -- Cache, not chat history
        use_response_caching = true,
        update_prompt = [[Update this Recap for "{title}"{author_clause}.

Previous recap (at {cached_progress}):
{cached_result}

New content since then (now at {reading_progress}):
{incremental_book_text_section}

{highlights_section}

Update the recap to reflect where the story/argument now stands.

Guidelines:
- Build on the previous recap, don't repeat it entirely
- Focus on what's NEW since {cached_progress}
- Update the "Where I stopped" or "Current focus" section for the new position
- Keep the same tone and style as the original recap
- Maintain the appropriate structure (fiction vs non-fiction)
- Keep total length concise - summarize earlier content more briefly as you go
- If the reader has highlighted passages, note what they found notable

CRITICAL: No spoilers beyond {reading_progress}.]],
    },
    -- Analyze My Notes: Insights from user's annotations and notebook
    analyze_highlights = {
        id = "analyze_highlights",
        enable_web_search = false,
        text = _("Analyze My Notes"),
        description = _("Analyzes your note-taking and highlighting patterns to reveal what catches your attention, emerging themes, and connections between your notes. This is about understanding you as a reader, not summarizing the book. Requires highlights or annotations sharing."),
        context = "book",
        behavior_variant = "reader_assistant",
        requires = {"highlights"},      -- Block if no highlight-type data can reach the prompt
        use_response_caching = true,    -- View/Update popup + per-action cache (pseudo-update)
        -- Context extraction flags
        use_highlights = true,
        use_annotations = true,
        use_reading_progress = true,
        use_notebook = true,
        use_summary_cache = true,       -- Optional enrichment: helps AI understand what reader is engaging with
        prompt = [[Reflect on my reading of "{title}"{author_clause} through my highlights and notes.

I'm at {reading_progress}. Do not reference or spoil any events, reveals, or developments beyond this point.

Here's what I've marked:

{annotations_section}

{notebook_section}

{summary_cache_section}

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
        in_quick_actions = 5,
    },
    -- Related Thinkers: Intellectual landscape and influences
    related_thinkers = {
        id = "related_thinkers",
        text = _("Related Thinkers"),
        description = _("Maps the intellectual landscape: who influenced the author, who the author influenced, and contemporary thinkers working on similar problems. For fiction, focuses on literary influences and movements."),
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
        enable_web_search = false,
        text = _("Key Arguments"),
        description = _("Breaks down the book's thesis, supporting arguments, evidence, assumptions, and potential counterarguments. For fiction, analyzes themes and the author's worldview instead. Requires text extraction; without it, falls back to AI knowledge."),
        context = "book",
        use_book_text = true,  -- Permission gate for text extraction
        -- No behavior_variant - uses user's global behavior
        -- No skip_domain - domain expertise shapes analysis approach
        prompt = [[Analyze the main arguments in "{title}"{author_clause}.
{full_document_section}

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

This is an overview, not an essay. {conciseness_nudge} {hallucination_nudge}

{text_fallback_nudge}]],
        api_params = {
            temperature = 0.6,
            max_tokens = 4096,
        },
        builtin = true,
        in_quick_actions = 7,
    },
    -- Key Arguments (Smart): Thesis and argument analysis using cached summary
    key_arguments_smart = {
        id = "key_arguments_smart",
        enable_web_search = false,
        text = _("Key Arguments") .. " (Smart)",
        description = _("Same analysis as Key Arguments, but uses a pre-built Summary Cache instead of the full text — faster and cheaper. Requires generating a Summary Cache first."),
        context = "book",
        use_book_text = true,        -- Gate for accessing _summary_cache
        use_summary_cache = true,    -- Reference the cached summary
        requires_summary_cache = true,  -- Trigger pre-flight cache check
        prompt = [[Analyze the main arguments in "{title}"{author_clause}.

{summary_cache_section}

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

This is an overview, not an essay. {conciseness_nudge} {hallucination_nudge}

Note: The summary may be in a different language than your response language. Translate or adapt as needed.]],
        skip_domain = true,  -- Analysis format is standardized
        api_params = {
            temperature = 0.6,
            max_tokens = 4096,
        },
        builtin = true,
    },
    -- Discussion Questions: Book club and classroom prompts
    discussion_questions = {
        id = "discussion_questions",
        enable_web_search = false,
        text = _("Discussion Questions"),
        description = _("Generates 8-10 discussion questions spanning comprehension, analysis, interpretation, and personal connection. Good for book clubs or classroom use. Requires text extraction; without it, falls back to AI knowledge."),
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

Note: These are general questions for the complete work. If the reader is mid-book, they can ask for spoiler-free questions in the follow-up. {hallucination_nudge}

{text_fallback_nudge}]],
        api_params = {
            temperature = 0.7,
            max_tokens = 4096,
        },
        builtin = true,
    },
    -- Discussion Questions (Smart): Generate discussion prompts using cached summary
    discussion_questions_smart = {
        id = "discussion_questions_smart",
        enable_web_search = false,
        text = _("Discussion Questions") .. " (Smart)",
        description = _("Same as Discussion Questions, but uses a pre-built Summary Cache instead of the full text. Requires generating a Summary Cache first."),
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
    -- Generate Quiz: Create comprehension questions from full book text
    generate_quiz = {
        id = "generate_quiz",
        enable_web_search = false,
        text = _("Generate Quiz"),
        description = _("Creates a comprehension quiz with multiple choice, short answer, and essay questions with model answers. Requires text extraction; without it, falls back to AI knowledge."),
        context = "book",
        use_book_text = true,  -- Permission gate for text extraction
        prompt = [[Create a comprehension quiz for "{title}"{author_clause}.

{full_document_section}

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
- Academic: Include questions about methodology and scholarly implications

{conciseness_nudge}

Note: These are general questions for the complete work. If the reader is mid-book, they can ask for spoiler-free questions in the follow-up. {hallucination_nudge}

{text_fallback_nudge}]],
        api_params = {
            temperature = 0.6,  -- Balanced variety
            max_tokens = 4096,
        },
        builtin = true,
    },
    -- Generate Quiz (Smart): Create comprehension questions using cached summary
    generate_quiz_smart = {
        id = "generate_quiz_smart",
        enable_web_search = false,
        text = _("Generate Quiz") .. " (Smart)",
        description = _("Same as Generate Quiz, but uses a pre-built Summary Cache instead of the full text. Requires generating a Summary Cache first."),
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
        enable_web_search = false,
        text = _("Document Analysis"),
        description = _("Analyzes the document's thesis, structure, key insights, and audience. The result is saved as an Analyze artifact that other actions can reference. Requires text extraction."),
        context = "book",
        requires = {"book_text"},       -- Block if text extraction is off
        use_book_text = true,  -- Permission gate (UI: "Allow text extraction")
        cache_as_analyze = true,  -- Save for other actions via {analyze_cache_section}
        use_response_caching = true,  -- View/Redo popup + per-action cache
        in_reading_features = 7,  -- After Document Summary (6)
        storage_key = "__SKIP__",  -- Result lives in document cache, not chat history
        prompt = [[Analyze this document: "{title}"{author_clause}.

{full_document_section}

Provide analysis appropriate to this document's type and purpose. Address what's relevant:
- Core thesis, argument, or narrative
- Structure and organization of ideas
- Key insights, findings, or themes
- Intended audience and context
- Strengths and areas for improvement

{conciseness_nudge}]],
        -- No skip_domain, no skip_behavior - relies on user's configured settings
        api_params = {
            temperature = 0.5,
        },
        builtin = true,
    },
    -- Summarize Full Document: Condense content without evaluation
    -- Foundation for Smart actions — pre-flight generates this automatically
    summarize_full_document = {
        id = "summarize_full_document",
        enable_web_search = false,
        text = _("Document Summary"),
        description = _("Creates a comprehensive summary preserving key details and structure. The result is saved as a Summary artifact — the foundation that all Smart actions rely on. Requires text extraction."),
        context = "book",
        requires = {"book_text"},       -- Block if text extraction is off
        use_book_text = true,  -- Permission gate (UI: "Allow text extraction")
        cache_as_summary = true,  -- Save for other actions via {summary_cache_section}
        use_response_caching = true,  -- View/Redo popup + per-action cache
        in_reading_features = 6,  -- After Book Info (5)
        in_quick_actions = 4,  -- After Book Info (3)
        storage_key = "__SKIP__",  -- Result lives in document cache, not chat history
        prompt = [[Summarize: "{title}"{author_clause}.

{full_document_section}

Provide a comprehensive summary capturing the essential content. Cover the entire work evenly from beginning to end — do not front-load detail on early sections at the expense of later ones. This summary will be used as a stand-in for the full text in future queries and analysis, so preserve key details, arguments, and structure while being as concise as the content's length and density allow.]],
        api_params = {
            temperature = 0.4,
        },
        builtin = true,
    },
    -- Extract Key Insights: Actionable takeaways worth remembering
    extract_insights = {
        id = "extract_insights",
        enable_web_search = false,
        text = _("Extract Key Insights"),
        description = _("Distills the most important takeaways: ideas worth remembering, novel perspectives, actionable conclusions, and connections to broader concepts. Requires text extraction."),
        context = "book",
        use_book_text = true,  -- Permission gate (UI: "Allow text extraction")
        prompt = [[Extract key insights from: "{title}"{author_clause}.

{full_document_section}

What are the most important takeaways? Focus on:
- Ideas worth remembering
- Novel perspectives or findings
- Actionable conclusions
- Connections to broader concepts

{conciseness_nudge}

{text_fallback_nudge}]],
        api_params = {
            temperature = 0.5,
        },
        builtin = true,
        in_quick_actions = 6,
    },
    -- Web-enhanced book actions (force web search on)
    book_reviews = {
        id = "book_reviews",
        enable_web_search = true,  -- Force web search even if global setting is off
        text = _("Book Reviews"),
        description = _("Searches the web for critical and reader reviews, awards, and any controversy around the book."),
        context = "book",
        skip_domain = true,  -- Reviews format is standardized
        prompt = [[Find reviews and reception for "{title}"{author_clause}.

Search for critical and reader responses, then summarize:

**Critical Reception:** What do professional reviewers and critics say? Key praise and criticism.

**Reader Response:** How do general readers respond? Common likes and dislikes.

**Awards & Recognition:** Notable awards, shortlists, or cultural impact.

**Controversy:** Any notable debates or divisive reactions (if applicable).

Attribute opinions to their sources where possible. Distinguish between critical consensus and minority views.

{conciseness_nudge} {hallucination_nudge}]],
        api_params = {
            temperature = 0.5,
            max_tokens = 4096,
        },
        builtin = true,
    },
}

-- Built-in actions for multi-book context
Actions.multi_book = {
    compare_books = {
        id = "compare_books",
        enable_web_search = false,
        text = _("Compare Books"),
        description = _("Compares the selected books, focusing on meaningful contrasts: different approaches, unique strengths, and which readers would prefer which."),
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
        enable_web_search = false,
        text = _("Find Common Themes"),
        description = _("Identifies shared themes, intellectual traditions, and deeper patterns across the selected books — beyond surface-level genre labels."),
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
        enable_web_search = false,
        text = _("Analyze Collection"),
        description = _("Analyzes what the collection reveals about the reader's interests, perspective, and what might be missing for a more complete picture."),
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
        enable_web_search = false,
        text = _("Quick Summaries"),
        description = _("A brief 2-3 sentence summary of each selected book, focusing on premise and appeal."),
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
        enable_web_search = false,
        text = _("Reading Order"),
        description = _("Suggests an optimal reading order based on conceptual dependencies, difficulty progression, and thematic arc."),
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
        description = _("Fetches today's top global news stories from Al Jazeera with headlines, summaries, and links. Uses web search."),
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
        enable_web_search = false,
        text = _("Translate"),
        description = _("Translates the selected text into your configured translation language. This action also controls the Translate Current Page function."),
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
        enable_web_search = false,
        text = _("Quick Define"),
        description = _("A brief, one-line dictionary definition of the selected word in your dictionary language."),
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
        enable_web_search = false,
        text = _("Dictionary"),
        description = _("Full dictionary entry with pronunciation, definitions, etymology, and synonyms."),
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
        enable_web_search = false,
        text = _("Deep Analysis"),
        description = _("Deep linguistic analysis covering morphology, word family, etymology, cognates, and cross-language borrowings. Adapts to the word's language family (Semitic roots, Indo-European stems, etc.)."),
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
        if action.context == context or
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
    for _idx, flag in ipairs(Actions.OPEN_BOOK_FLAGS) do
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

    -- Cascade: flags that derive from highlights also require use_highlights
    for _idx, flag in ipairs(Actions.REQUIRES_HIGHLIGHTS) do
        if inferred_flags[flag] then
            inferred_flags["use_highlights"] = true
            break
        end
    end

    -- Cascade: annotations imply highlights (you can't have notes without highlighted text)
    if inferred_flags["use_annotations"] then
        inferred_flags["use_highlights"] = true
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
