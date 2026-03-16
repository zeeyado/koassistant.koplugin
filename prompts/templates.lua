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
--   {count}                - Number of selected books (library context)
--   {books_list}           - Formatted list of books (library context)
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
-- MessageBuilder selects the web-aware variant when web search is active for the request
Templates.HALLUCINATION_NUDGE = "If you don't recognize this or the content seems unclear, say so rather than guessing."
Templates.HALLUCINATION_NUDGE_WEB = "If you don't recognize this or the content seems unclear, search the web to verify. If you still can't confirm, say so rather than guessing."

-- Text fallback nudge - appears only when document text extraction is empty
-- Available as {text_fallback_nudge} conditional placeholder
-- The {title} placeholder inside will be substituted by MessageBuilder
Templates.TEXT_FALLBACK_NUDGE = 'Note: No document text was provided. Use your knowledge of "{title}" to provide the best response you can. If you don\'t recognize this work, say so honestly rather than fabricating details.'

-- Research nudge - added to system prompt when DOI detected and web search active
-- Guides AI on academic-appropriate use of web search
-- Injected by system_prompts.lua buildUnifiedSystem(), not a user prompt placeholder
Templates.RESEARCH_NUDGE = [[This is an academic/research paper. Ground your analysis primarily in the provided text. If web search is available, use it to verify technical claims, understand the paper's position within its field, look up referenced works or foundational concepts, and search for the DOI directly for citation context and related work. Use relevant academic sources as you see fit — adapt to the discipline and field.]]

-- Highlight analysis nudge - appears only when highlights are provided
-- Available as {highlight_analysis_nudge} conditional placeholder in X-Ray prompts
Templates.HIGHLIGHT_ANALYSIS_NUDGE = [[If highlights are provided, add a "reader_engagement" section to the JSON:

For fiction: {"reader_engagement":{"patterns":"What the reader's highlights reveal about their interests or reading focus.","notable_highlights":[{"passage":"Brief quote or reference","why_notable":"Why this highlight is interesting in context"}],"connections":"How highlighted passages connect to each other or to major themes."}}

For non-fiction: {"reader_engagement":{"patterns":"What the reader's highlights reveal about their interests or focus areas.","notable_highlights":[{"passage":"Brief quote or reference","why_notable":"Why this highlight is interesting in context"}],"connections":"How highlighted passages connect to each other or to the author's main arguments."}}

Include 3-5 notable highlights maximum. Focus on what makes each highlight interesting given the reader's apparent interests. Omit reader_engagement entirely if no highlights are provided.]]

-- Highlight context templates
Templates.highlight = {
    explain = [[Explain this passage:

{highlighted_text}

Be clear and precise. Match the text's tone - a philosophy text deserves rigor, a thriller just needs clarity. {conciseness_nudge}]],

    eli5 = [[Explain this like I'm 5 - make it genuinely simple:

{highlighted_text}

Use simple words and a concrete analogy/example. Stay accurate - simplify the explanation, not the truth. {conciseness_nudge}]],

    summarize = [[Summarize this passage:

{highlighted_text}

Capture the main point and key supporting details. A good summary is shorter than the original but loses nothing important. {conciseness_nudge}]],

    elaborate = [[Elaborate on this passage:

{highlighted_text}

Unpack key concepts, add helpful context, explore implications and connections. Go deeper, but stay grounded in what the text actually says. {conciseness_nudge}]],
}

-- Book context templates
Templates.book = {
    book_info = [[Tell me about "{title}"{author_clause}.{doi_clause} Provide a comprehensive overview:

## About the Work
- What it's about — premise and central conflict (fiction) or thesis and scope (non-fiction)
- Historical and cultural context — when and why this work appeared, what it responded to

## Themes and Ideas
- Major themes, questions, or arguments the work explores
- What makes its perspective distinctive

## Significance
- Why this work matters — its influence, reception, or lasting contribution
- Where it fits in its genre or field

## The Reading Experience
- Style and structure — what to expect as a reader
- Accessibility — does it require background knowledge?
- Who tends to enjoy this work, and why

Avoid spoilers: do not reveal plot twists, endings, character deaths, or major surprises. Describe the premise and central tensions without spoiling their resolution.

Adapt depth and focus to the type of work — a literary novel deserves attention to craft, a popular science book to clarity of explanation, a classic to historical context.

Be substantive but not exhaustive. {hallucination_nudge}]],

    suggest_from_library = [[I'm reading "{title}"{author_clause} ({reading_progress}).

Here is my library:

{library}

Suggest what I should read next **from books I already own**. Consider:
- Thematic connections to what I'm currently reading
- My reading patterns (what I've finished, started but stopped, or left unread)
- Natural follow-ups — same author, same series, related topics
- Variety — consider what would complement or contrast well, not just the most similar book

For each suggestion (3-5 books):
- Why this book specifically, given what I'm reading now
- What it offers that connects to or extends my current read
- If relevant, why now rather than later in my reading queue

Only suggest books from my library. Do not recommend books I don't own. {hallucination_nudge}]],

    similar_books = [[Based on "{title}"{author_clause},{doi_clause} recommend 5-7 similar works.

For each recommendation, specify:
- WHY it's similar (themes? style? subject matter? reading experience?)
- Who would prefer the original vs the recommendation

Adapt to content type:
- Fiction: Similar narrative experience, themes, or style
- Non-fiction: Similar arguments, perspectives, or intellectual tradition
- Academic: Works that complement, extend, or debate this one

{library_section}

{hallucination_nudge}]],

    explain_author = [[Tell me about the author of "{title}"{author_clause}.{doi_clause} Include:

- Brief biography and background
- Their major works and how their style evolved
- Writing style and recurring themes
- Historical/cultural context of their work
- Suggested reading order for their works (if they have multiple)

Be concise. For intellectual influences and lineage, the reader can use "Related Thinkers". {hallucination_nudge}]],

    historical_context = [[Provide historical context for "{title}"{author_clause}:{doi_clause}
- When was it written and what was happening at that time
- Historical events or movements that influenced the work
- How the work reflects or responds to its historical moment
- Its historical significance or impact

Adapt to the work's nature — a novel reflects its era differently than a manifesto, a religious text, or a research paper.

{hallucination_nudge}]],
}

-- Library context templates (multi-book)
Templates.library = {
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

    recommend_books = [[Based on these {count} books, recommend new books to read:

{books_list}

{library_section}

First, briefly identify the pattern — what do these books suggest about this reader's taste? Then recommend 5-8 books, prioritizing:
- Books that match the *intersection* of interests these books reveal, not just "similar to one of them"
- A mix: some that lean into the reader's clear preferences, some that stretch in a direction they'd likely appreciate
- Lesser-known works alongside well-known ones

For each recommendation:
- Why this reader specifically would enjoy it (connect to the pattern you identified)
- What it offers that none of the listed books do

If the reader's library is included above, note which recommendations they already own and prioritize unread books from their library before suggesting new purchases. Skip obvious picks the reader has almost certainly encountered. {hallucination_nudge}]],

    -- Scan-based actions (no book selection needed)
    next_from_library = [[Here is my library:

{library}

What should I read next **from books I already own**? Consider:
- What's unread or started but not finished
- My reading patterns — what genres, authors, and topics I gravitate toward
- What I've finished recently and what would complement or follow well
- Books I started but set aside — are any worth returning to?

Suggest 3-5 books. For each:
- Why this one, given my reading patterns
- What it offers that my recent reads don't

Only suggest books from my library. {hallucination_nudge}]],

    discover_books = [[Here is my library:

{library}

Based on what I own, recommend 5-8 new books I should get. First, briefly identify the pattern — what does this library say about the reader's taste?

Then recommend books I don't already own, prioritizing:
- Works that match the intersection of interests my library reveals
- A mix: some that lean into clear preferences, some that stretch in a new direction
- Lesser-known works alongside well-known ones

For each:
- Why this reader specifically would enjoy it
- What it offers that nothing in the library already covers

Skip obvious picks I've almost certainly encountered. {hallucination_nudge}]],

    reading_patterns = [[Here is my library:

{library}

Analyze my reading patterns based on this collection. Consider:
- Genres, topics, and themes I gravitate toward
- Authors or styles that recur
- Completion patterns — what I finish vs what I abandon or leave unread
- Gaps — areas my collection doesn't cover that someone with these interests might expect
- Any progression or evolution visible in my reading

Be specific to what you see, not generic. Use the actual titles and authors to illustrate patterns.

Note: this analysis is based on catalog metadata only (titles, authors, reading status, progress). Detailed reading time and session data is not included. {hallucination_nudge}]],
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
    for _idx, context_table in pairs({Templates.highlight, Templates.book, Templates.library, Templates.special}) do
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
-- @param context_type: "highlight", "book", "library"
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
        vars.doi_clause = data.doi_clause or ""

    elseif context_type == "book" then
        vars.title = data.title or ""
        vars.author = data.author or ""
        vars.author_clause = data.author and data.author ~= "" and (" by " .. data.author) or ""
        vars.doi_clause = data.doi_clause or ""

    elseif context_type == "library" then
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
-- @param context_type: "highlight", "book", "library", "general"
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
