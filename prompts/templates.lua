-- User prompt templates for KOAssistant
-- Templates define the actual text sent to the AI
--
-- Template variables (substituted at runtime):
--
-- Standard placeholders (always available):
--   {highlighted_text}     - Selected text from document (highlight context)
--   {title}                - Book title (book, highlight contexts)
--   {author}               - Book author (book, highlight contexts)
--   {author_clause}        - " by Author" or "" if no author
--   {count}                - Number of selected books (multi_book context)
--   {books_list}           - Formatted list of books (multi_book context)
--   {translation_language} - Target translation language from settings (all contexts)
--   {dictionary_language}  - Dictionary response language from settings (all contexts)
--   {context}              - Surrounding text context for dictionary lookups (highlight context)
--
-- Context extraction placeholders (require extraction flags on action + global setting enabled):
--   {reading_progress}     - Reading progress as "42%" (highlight, book contexts)
--   {progress_decimal}     - Reading progress as decimal "0.42" (highlight, book contexts)
--   {highlights}           - Formatted list of highlights (text only) (highlight, book contexts)
--   {annotations}          - Highlights with user notes attached (highlight, book contexts)
--   {book_text}            - Extracted text up to current position (highlight, book contexts)
--   {chapter_title}        - Current chapter name (highlight, book contexts)
--   {chapters_read}        - Number of chapters completed (highlight, book contexts)
--   {time_since_last_read} - Human-readable time since last read (highlight, book contexts)
--
-- Section-aware placeholders (include label, disappear when empty - RECOMMENDED):
--   {book_text_section}    - "Book content so far:\n[text]" or "" if disabled/empty
--   {highlights_section}   - "My highlights so far:\n[list]" or "" if no highlights
--   {annotations_section}  - "My annotations:\n[list]" or "" if no annotations
--
-- Empty placeholder handling (hybrid approach):
--   {reading_progress}     - Always has value (default "0%")
--   {progress_decimal}     - Always has value (default "0")
--   {highlights}           - Empty string "" if no highlights
--   {annotations}          - Empty string "" if no annotations
--   {book_text}            - Empty string "" if extraction disabled or unavailable
--   {chapter_title}        - Fallback: "(Chapter unavailable)"
--   {chapters_read}        - Fallback: "0"
--   {time_since_last_read} - Fallback: "Recently"
--
-- Utility placeholders (always available):
--   {conciseness_nudge}   - Standard conciseness instruction for verbose models
--   {hallucination_nudge} - Standard instruction to admit uncertainty rather than guess
--
-- Note: Book text extraction is OFF by default. Users must enable it in
-- Settings → Advanced → Context Extraction before {book_text} placeholders work.

local _ = require("koassistant_gettext")

local Templates = {}

-- Conciseness nudge - standard instruction to reduce verbosity
-- Available as {conciseness_nudge} placeholder in all contexts
Templates.CONCISENESS_NUDGE = "Be direct and concise. Don't restate or over-elaborate."

-- Hallucination nudge - standard instruction to admit uncertainty
-- Available as {hallucination_nudge} placeholder in all contexts
Templates.HALLUCINATION_NUDGE = "If you don't recognize this or the content seems unclear, say so rather than guessing."

-- Text fallback nudge - appears only when document text extraction is empty
-- Available as {text_fallback_nudge} conditional placeholder
-- The {title} placeholder inside will be substituted by MessageBuilder
Templates.TEXT_FALLBACK_NUDGE = 'Note: No document text was provided. Use your knowledge of "{title}" to provide the best response you can. If you don\'t recognize this work, say so honestly rather than fabricating details.'

-- Highlight context templates
Templates.highlight = {
    explain = [[Explain this passage:

{highlighted_text}

Be clear and thorough. Match the text's tone - a philosophy text deserves rigor, a thriller just needs clarity. {conciseness_nudge}]],

    eli5 = [[Explain this like I'm 5 - make it genuinely simple:

{highlighted_text}

Use simple words, analogies to everyday things, and concrete examples. Stay accurate - simplify the explanation, not the truth. {conciseness_nudge}]],

    summarize = [[Summarize this passage:

{highlighted_text}

Capture the main point and key supporting details. A good summary is shorter than the original but loses nothing important. {conciseness_nudge}]],

    elaborate = [[Elaborate on this passage:

{highlighted_text}

Unpack key concepts, add helpful context, explore implications and connections. Go deeper, but stay grounded in what the text actually says. {conciseness_nudge}]],
}

-- Book context templates
Templates.book = {
    book_info = [[Tell me about "{title}"{author_clause}. Include:

- What it's about (premise for fiction, thesis for non-fiction)
- Its significance and why it matters
- What type of reader typically loves this work
- Reading experience (accessible? dense? requires background?)

Adapt tone and focus to content type (fiction vs non-fiction vs academic). Be concise but informative. {hallucination_nudge}]],

    similar_books = [[Based on "{title}"{author_clause}, recommend 5-7 similar works.

For each recommendation, specify:
- WHY it's similar (themes? style? subject matter? reading experience?)
- Who would prefer the original vs the recommendation

Adapt to content type:
- Fiction: Similar narrative experience, themes, or style
- Non-fiction: Similar arguments, perspectives, or intellectual tradition
- Academic: Works that complement, extend, or debate this one

{hallucination_nudge}]],

    explain_author = [[Tell me about the author of "{title}"{author_clause}. Include:

- Brief biography and background
- Their major works and how their style evolved
- Writing style and recurring themes
- Historical/cultural context of their work
- Suggested reading order for their works (if they have multiple)

Be concise. For intellectual influences and lineage, the reader can use "Related Thinkers". {hallucination_nudge}]],

    historical_context = [[Provide historical context for "{title}"{author_clause}:
- When was it written and what was happening at that time
- Historical events or movements that influenced the work
- How the work reflects or responds to its historical moment
- Its historical significance or impact

{hallucination_nudge}]],
}

-- Multi-book context templates
Templates.multi_book = {
    compare_books = [[Compare these {count} books:

{books_list}

Focus on what makes each one distinct:
- Different perspectives, approaches, or conclusions
- Unique strengths — what each does better than the others
- Which readers would prefer which, and why

Don't just list similarities — find the meaningful contrasts. {hallucination_nudge}]],

    common_themes = [[What connects these {count} books?

{books_list}

Look for the shared DNA:
- Recurring themes, questions, or concerns
- Shared intellectual traditions or influences
- Why someone might have collected these together

Surface the patterns, not just surface-level genre labels. {hallucination_nudge}]],

    collection_summary = [[What does this collection of {count} books reveal about its reader?

{books_list}

Consider:
- What interests or questions drive this selection?
- What perspective or worldview emerges?
- What's notably absent that a complete picture might include?

Be specific about the reader you infer, not generic. {hallucination_nudge}]],

    quick_summaries = [[For each of these {count} books, give a 2-3 sentence summary:

{books_list}

Focus on premise and appeal — why would someone read this? {hallucination_nudge}]],

    reading_order = [[Suggest a reading order for these {count} books:

{books_list}

Consider:
- Conceptual dependencies (does one build on ideas from another?)
- Chronological or historical sequence
- Difficulty progression (easier → harder)
- Thematic arc (what order tells a coherent story?)

Explain your reasoning briefly. If order genuinely doesn't matter, say so. {hallucination_nudge}]],
}

-- Special templates (reserved for future use)
-- Note: translate action now uses inline prompt with {translation_language} placeholder
Templates.special = {
}

-- Get a template by ID
-- @param template_id: The template's identifier
-- @return string or nil: Template text if found
function Templates.get(template_id)
    -- Search all template tables
    for _, context_table in pairs({Templates.highlight, Templates.book, Templates.multi_book, Templates.special}) do
        if context_table[template_id] then
            return context_table[template_id]
        end
    end
    return nil
end

-- Substitute variables in a template
-- @param template: Template string with {variable} placeholders
-- @param variables: Table of variable values
-- @return string: Template with variables substituted
function Templates.substitute(template, variables)
    if not template then return "" end
    variables = variables or {}

    local result = template

    -- Substitute each variable
    for key, value in pairs(variables) do
        local pattern = "{" .. key .. "}"
        result = result:gsub(pattern, function()
            return tostring(value or "")
        end)
    end

    return result
end

-- Build variables table from context
-- @param context_type: "highlight", "book", "multi_book"
-- @param data: Context data (highlighted_text, book_metadata, books_info, etc.)
-- @return table: Variables for template substitution
function Templates.buildVariables(context_type, data)
    data = data or {}
    local vars = {}

    -- Utility placeholders (always available)
    vars.conciseness_nudge = Templates.CONCISENESS_NUDGE
    vars.hallucination_nudge = Templates.HALLUCINATION_NUDGE

    if context_type == "highlight" then
        vars.highlighted_text = data.highlighted_text or ""
        vars.title = data.title or ""
        vars.author = data.author or ""
        vars.author_clause = data.author and data.author ~= "" and (" by " .. data.author) or ""

    elseif context_type == "book" then
        vars.title = data.title or ""
        vars.author = data.author or ""
        vars.author_clause = data.author and data.author ~= "" and (" by " .. data.author) or ""

    elseif context_type == "multi_book" then
        vars.count = data.count or (data.books_info and #data.books_info) or 0
        vars.books_list = data.books_list or Templates.formatBooksList(data.books_info)
    end

    -- Add any additional variables passed in
    for key, value in pairs(data) do
        if not vars[key] then
            vars[key] = value
        end
    end

    return vars
end

-- Format a list of books for the {books_list} variable
-- @param books_info: Array of { title, author } tables
-- @return string: Formatted numbered list
function Templates.formatBooksList(books_info)
    if not books_info or #books_info == 0 then
        return ""
    end

    local lines = {}
    for i, book in ipairs(books_info) do
        local title = book.title or "Unknown Title"
        local author = book.author
        local line
        if author and author ~= "" then
            line = string.format('%d. "%s" by %s', i, title, author)
        else
            line = string.format('%d. "%s"', i, title)
        end
        table.insert(lines, line)
    end

    return table.concat(lines, "\n")
end

-- Render a complete user message from an action
-- @param action: Action definition from actions.lua
-- @param context_type: "highlight", "book", "multi_book", "general"
-- @param data: Context data for variable substitution
-- @return string: Rendered user message
function Templates.renderForAction(action, context_type, data)
    if not action or not action.template then
        return ""
    end

    local template = Templates.get(action.template)
    if not template then
        return ""
    end

    local variables = Templates.buildVariables(context_type, data)
    return Templates.substitute(template, variables)
end

return Templates
