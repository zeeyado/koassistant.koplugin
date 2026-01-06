-- User prompt templates for KOAssistant
-- Templates define the actual text sent to the AI
--
-- Template variables (substituted at runtime):
--   {highlighted_text} - Selected text from document (highlight context)
--   {title}            - Book title (book, highlight contexts)
--   {author}           - Book author (book, highlight contexts)
--   {author_clause}    - " by Author" or "" if no author
--   {count}            - Number of selected books (multi_book context)
--   {books_list}       - Formatted list of books (multi_book context)
--   {language}         - Target language for translations
--   {text}             - Text to translate

local _ = require("koassistant_gettext")

local Templates = {}

-- Highlight context templates
Templates.highlight = {
    explain = [[Please explain the following text: {highlighted_text}]],

    eli5 = [[Please ELI5 (Explain Like I'm 5) the following text: {highlighted_text}]],

    summarize = [[Please provide a concise summary of the following text: {highlighted_text}]],
}

-- Book context templates
Templates.book = {
    book_info = [[Tell me about the book "{title}"{author_clause}. Include information about:
- What the book is about
- Its significance and impact
- Why someone might want to read it
- Any interesting facts about it

Please be concise but informative.]],

    similar_books = [[Based on the book "{title}"{author_clause}, recommend 5-7 similar books that readers might enjoy. For each recommendation, briefly explain why it's similar or why the reader might like it.]],

    explain_author = [[Tell me about the author of "{title}"{author_clause}. Include:
- Brief biography
- Their major works and contributions
- Writing style and themes
- Historical/cultural context of their work]],

    historical_context = [[Provide historical context for "{title}"{author_clause}:
- When was it written and what was happening at that time
- Historical events or movements that influenced the work
- How the book reflects or responds to its historical moment
- Its historical significance or impact]],
}

-- Multi-book context templates
Templates.multi_book = {
    compare_books = [[Compare and contrast these {count} books:

{books_list}

Please analyze:
- Common themes or topics
- Key differences in approach or perspective
- Target audiences
- Writing styles (if authors are known)
- Which readers might prefer which book and why

Be concise but insightful.]],

    common_themes = [[Looking at these {count} books:

{books_list}

What common themes, topics, or patterns can you identify across this selection? Consider:
- Subject matter overlap
- Shared historical contexts
- Similar literary techniques or genres
- Common target audiences or purposes]],

    collection_summary = [[Analyze this collection of {count} books:

{books_list}

Provide insights about:
- What kind of reader would have this collection
- What the selection reveals about their interests
- Any notable gaps or missing perspectives
- Recommendations for what to add next]],

    quick_summaries = [[For each of these {count} books, provide a 2-3 sentence summary:

{books_list}

Focus on the main premise and why someone might want to read it.]],
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
