--[[--
Shared message builder for KOAssistant.

This module is used by both the plugin (dialogs.lua) and the test framework (inspect.lua)
to ensure consistent message formatting.

@module message_builder
]]

local Constants = require("koassistant_constants")

local MessageBuilder = {}

-- Try to load logger, but make it optional for standalone testing
local logger
pcall(function()
    logger = require("logger")
end)

-- Try to load Templates for utility placeholder constants
local Templates
pcall(function()
    Templates = require("prompts/templates")
end)

local function log_warn(msg)
    if logger then
        logger.warn(msg)
    end
end

-- Escape % characters in replacement strings for gsub
-- In Lua gsub, % has special meaning in the replacement string
local function escape_replacement(str)
    if not str then return str end
    return str:gsub("%%", "%%%%")
end

-- Replace a placeholder using plain string operations (find+sub)
-- This avoids gsub escaping issues with long content or special characters
-- @param text string the text containing the placeholder
-- @param placeholder string the placeholder to find (e.g., "{book_text_section}")
-- @param replacement string the value to substitute
-- @return string the text with placeholder replaced
local function replace_placeholder(text, placeholder, replacement)
    if not text or not placeholder then return text end
    replacement = replacement or ""
    -- Replace ALL occurrences (plain text search, no pattern interpretation)
    -- search_start advances past each replacement to avoid infinite loops
    -- when the replacement text itself contains the placeholder pattern
    -- (e.g., summarizing a document that documents placeholder syntax)
    local search_start = 1
    while true do
        local start_pos, end_pos = text:find(placeholder, search_start, true)
        if not start_pos then break end
        text = text:sub(1, start_pos - 1) .. replacement .. text:sub(end_pos + 1)
        search_start = start_pos + #replacement
    end
    return text
end

--- Build the complete user message from action prompt and context data.
-- @param params table with fields:
--   prompt: action object with prompt/template field
--   context: string ("highlight", "book", "general", "multi_book", etc.)
--   data: table with context data (highlighted_text, book_title, book_author, etc.)
--   system_prompt: string (only used when using_new_format is false)
--   domain_context: string (only used when using_new_format is false)
--   using_new_format: boolean (true = system/domain go in system array, not message)
--   templates_getter: function(template_name) returns template string (optional)
-- @return string the consolidated message
function MessageBuilder.build(params)
    local prompt = params.prompt or {}
    local context = params.context or "general"
    local data = params.data or {}
    local system_prompt = params.system_prompt
    local domain_context = params.domain_context
    local using_new_format = params.using_new_format
    local templates_getter = params.templates_getter

    -- Validate context against known context types
    if context and not Constants.isValidContext(context) then
        log_warn("MessageBuilder: Invalid context '" .. tostring(context) .. "', using 'general' as fallback")
        context = "general"
    end

    if logger then
        logger.info("MessageBuilder.build: context=", context, "data.highlighted_text=", data.highlighted_text and #data.highlighted_text or "nil/empty")
        logger.info("MessageBuilder.build: data.book_metadata=", data.book_metadata and "present" or "nil", "data.book_title=", data.book_title or "nil")
        if data.book_metadata then
            logger.info("MessageBuilder.build: book_metadata.title=", data.book_metadata.title or "nil", "author=", data.book_metadata.author or "nil")
        end
    end

    local parts = {}

    -- Add domain context if provided (background knowledge about the topic area)
    -- Skip if using new format - domain will go in system array instead
    if not using_new_format and domain_context and domain_context ~= "" then
        table.insert(parts, "[Domain Context]")
        table.insert(parts, domain_context)
        table.insert(parts, "")
    end

    -- Add system prompt if provided
    -- Skip if using new format - system prompt will go in system array instead
    if not using_new_format and system_prompt then
        table.insert(parts, "[Instructions]")
        table.insert(parts, system_prompt)
        table.insert(parts, "")
    end

    -- Get the action prompt template
    -- Actions can have either `prompt` (direct text) or `template` (reference to templates.lua)
    local user_prompt = prompt.prompt
    if not user_prompt and prompt.template then
        -- Resolve template reference
        if templates_getter then
            user_prompt = templates_getter(prompt.template)
        else
            -- Try to load Templates module (works in plugin context)
            local ok, _Templates = pcall(require, "prompts/templates")
            if ok and _Templates then
                user_prompt = _Templates.get(prompt.template)
            end
        end
    end
    if not user_prompt then
        log_warn("Action missing prompt field: " .. (prompt.text or "unknown"))
        user_prompt = ""
    end

    -- Substitute utility placeholders (conciseness/hallucination nudges)
    -- These are defined in Templates but used in both template and direct-prompt actions
    if Templates then
        user_prompt = replace_placeholder(user_prompt, "{conciseness_nudge}", Templates.CONCISENESS_NUDGE or "")
        user_prompt = replace_placeholder(user_prompt, "{hallucination_nudge}", Templates.HALLUCINATION_NUDGE or "")
    end

    -- Substitute language placeholders early (applies to all contexts)
    -- Using replace_placeholder (find+sub) to avoid gsub escaping issues
    if data.translation_language then
        user_prompt = replace_placeholder(user_prompt, "{translation_language}", data.translation_language)
    end
    if data.dictionary_language then
        user_prompt = replace_placeholder(user_prompt, "{dictionary_language}", data.dictionary_language)
    end
    if data.dictionary_context_mode == "none" then
        -- Context explicitly disabled: strip lines with {context} and "In context" markers
        local lines = {}
        for line in (user_prompt .. "\n"):gmatch("([^\n]*)\n") do
            if not line:find("{context}", 1, true) and
               not line:find("In context", 1, true) then
                table.insert(lines, line)
            end
        end
        -- Remove trailing blank lines from stripped content
        while #lines > 0 and lines[#lines]:match("^%s*$") do
            table.remove(lines)
        end
        user_prompt = table.concat(lines, "\n")
    elseif data.context then
        user_prompt = replace_placeholder(user_prompt, "{context}", data.context)
    end

    -- Substitute context extraction placeholders (applies to all contexts)
    -- Using replace_placeholder to avoid issues with % in reading_progress
    if data.reading_progress then
        user_prompt = replace_placeholder(user_prompt, "{reading_progress}", data.reading_progress)
    end
    if data.progress_decimal then
        user_prompt = replace_placeholder(user_prompt, "{progress_decimal}", data.progress_decimal)
    end

    -- Section-aware placeholders: include label when content exists, empty string when not
    -- Use replace_placeholder (find+sub) instead of gsub to avoid escaping issues with long content

    -- {book_text_section} - includes "Book content so far:\n" label
    local book_text_section = ""
    if data.book_text and data.book_text ~= "" then
        book_text_section = "Book content so far:\n" .. data.book_text
    end
    if logger then
        logger.info("MessageBuilder: book_text_section len=", #book_text_section)
    end
    user_prompt = replace_placeholder(user_prompt, "{book_text_section}", book_text_section)

    -- {highlights_section} - includes "My highlights so far:\n" label
    local highlights_section = ""
    if data.highlights and data.highlights ~= "" then
        highlights_section = "My highlights so far:\n" .. data.highlights
    end
    if logger then
        logger.info("MessageBuilder: highlights_section len=", #highlights_section)
    end
    user_prompt = replace_placeholder(user_prompt, "{highlights_section}", highlights_section)

    -- {annotations_section} - adaptive label based on degradation state
    -- Full annotations: "My annotations:" / Degraded to highlights: "My highlights so far:"
    local annotations_section = ""
    if data.annotations and data.annotations ~= "" then
        if data._annotations_degraded then
            annotations_section = "My highlights so far:\n" .. data.annotations
        else
            annotations_section = "My annotations:\n" .. data.annotations
        end
    end
    user_prompt = replace_placeholder(user_prompt, "{annotations_section}", annotations_section)

    -- {notebook_section} - includes "My notebook entries:\n" label
    local notebook_section = ""
    if data.notebook_content and data.notebook_content ~= "" then
        notebook_section = "My notebook entries:\n" .. data.notebook_content
    end
    user_prompt = replace_placeholder(user_prompt, "{notebook_section}", notebook_section)

    -- {full_document_section} - includes "Full document:\n" label
    local full_document_section = ""
    if data.full_document and data.full_document ~= "" then
        full_document_section = "Full document:\n" .. data.full_document
    end
    user_prompt = replace_placeholder(user_prompt, "{full_document_section}", full_document_section)

    -- {text_fallback_nudge} - conditional: appears only when document text is empty
    -- Helps actions degrade gracefully by telling AI to use training knowledge
    local has_document_text = (book_text_section ~= "") or (full_document_section ~= "")
    local text_fallback_nudge = ""
    if not has_document_text and Templates and Templates.TEXT_FALLBACK_NUDGE then
        text_fallback_nudge = Templates.TEXT_FALLBACK_NUDGE
    end
    user_prompt = replace_placeholder(user_prompt, "{text_fallback_nudge}", text_fallback_nudge)

    -- {highlight_analysis_nudge} - conditional: appears only when highlights are provided
    -- Adds reader_engagement section instruction to X-Ray prompts
    local highlight_analysis_nudge = ""
    if highlights_section ~= "" and Templates and Templates.HIGHLIGHT_ANALYSIS_NUDGE then
        highlight_analysis_nudge = Templates.HIGHLIGHT_ANALYSIS_NUDGE
    end
    user_prompt = replace_placeholder(user_prompt, "{highlight_analysis_nudge}", highlight_analysis_nudge)

    -- {context_section} - includes label (for dictionary actions)
    -- Resolves to labeled context when present, empty string when not
    -- Each action's prompt structure determines how context is used
    local context_section = ""
    if data.context and data.context ~= "" and data.dictionary_context_mode ~= "none" then
        context_section = "Word appears in this context: " .. data.context
    end
    user_prompt = replace_placeholder(user_prompt, "{context_section}", context_section)

    -- {surrounding_context_section} - text around highlight, for any highlight action
    local surrounding_context_section = ""
    if data.surrounding_context and data.surrounding_context ~= "" then
        surrounding_context_section = "Surrounding text:\n" .. data.surrounding_context
    end
    user_prompt = replace_placeholder(user_prompt, "{surrounding_context_section}", surrounding_context_section)
    -- Raw placeholder
    if data.surrounding_context then
        user_prompt = replace_placeholder(user_prompt, "{surrounding_context}", data.surrounding_context)
    end

    -- Raw placeholders (for custom prompts that want their own labels)
    if data.highlights ~= nil then
        user_prompt = replace_placeholder(user_prompt, "{highlights}", data.highlights)
    end
    if data.annotations ~= nil then
        user_prompt = replace_placeholder(user_prompt, "{annotations}", data.annotations)
    end
    if data.book_text then
        user_prompt = replace_placeholder(user_prompt, "{book_text}", data.book_text)
    end
    if data.chapter_title then
        user_prompt = replace_placeholder(user_prompt, "{chapter_title}", data.chapter_title)
    end
    if data.chapters_read then
        user_prompt = replace_placeholder(user_prompt, "{chapters_read}", data.chapters_read)
    end
    if data.time_since_last_read then
        user_prompt = replace_placeholder(user_prompt, "{time_since_last_read}", data.time_since_last_read)
    end
    if data.notebook_content ~= nil then
        user_prompt = replace_placeholder(user_prompt, "{notebook}", data.notebook_content)
    end
    if data.full_document then
        user_prompt = replace_placeholder(user_prompt, "{full_document}", data.full_document)
    end

    -- Cache-related placeholders (for X-Ray/Recap incremental updates)
    -- {cached_result} - the previous AI response
    if data.cached_result then
        user_prompt = replace_placeholder(user_prompt, "{cached_result}", data.cached_result)
    end
    -- {cached_progress} - formatted progress when cached (e.g., "30%")
    if data.cached_progress then
        user_prompt = replace_placeholder(user_prompt, "{cached_progress}", data.cached_progress)
    end
    -- {incremental_book_text_section} - text from cached position to current, with label
    local incremental_section = ""
    if data.incremental_book_text and data.incremental_book_text ~= "" then
        incremental_section = "New content since your last analysis:\n" .. data.incremental_book_text
    end
    user_prompt = replace_placeholder(user_prompt, "{incremental_book_text_section}", incremental_section)
    -- Raw placeholder (for custom prompts that want their own labels)
    if data.incremental_book_text then
        user_prompt = replace_placeholder(user_prompt, "{incremental_book_text}", data.incremental_book_text)
    end
    -- {entity_index} - compact listing of existing entity names for merge-based updates
    local entity_index_section = ""
    if data.entity_index and data.entity_index ~= "" then
        entity_index_section = "Existing entities in previous analysis:\n" .. data.entity_index
    end
    user_prompt = replace_placeholder(user_prompt, "{entity_index}", entity_index_section)

    -- Document cache placeholders (cached AI responses from previous X-Ray/Summary)
    -- {xray_cache_section} - previous X-Ray with progress label
    -- If the cache is structured JSON, render to markdown so other actions receive readable text
    local xray_cache_section = ""
    if data.xray_cache and data.xray_cache ~= "" then
        local cache_text = data.xray_cache
        local XrayParser = require("koassistant_xray_parser")
        if XrayParser.isJSON(cache_text) then
            local parsed = XrayParser.parse(cache_text)
            if parsed then
                cache_text = XrayParser.renderToMarkdown(parsed, "", "")
            end
        end
        local label = "Previous X-Ray"
        if data.xray_cache_progress then
            label = label .. " (as of " .. data.xray_cache_progress .. ")"
        end
        xray_cache_section = label .. ":\n" .. cache_text
    end
    user_prompt = replace_placeholder(user_prompt, "{xray_cache_section}", xray_cache_section)
    -- Raw placeholder (preserves original format - JSON or markdown)
    if data.xray_cache then
        user_prompt = replace_placeholder(user_prompt, "{xray_cache}", data.xray_cache)
    end

    -- {analyze_cache_section} - previous full document analysis
    local analyze_cache_section = ""
    if data.analyze_cache and data.analyze_cache ~= "" then
        analyze_cache_section = "Document analysis:\n" .. data.analyze_cache
    end
    user_prompt = replace_placeholder(user_prompt, "{analyze_cache_section}", analyze_cache_section)
    -- Raw placeholder
    if data.analyze_cache then
        user_prompt = replace_placeholder(user_prompt, "{analyze_cache}", data.analyze_cache)
    end

    -- {summary_cache_section} - previous full document summary
    local summary_cache_section = ""
    if data.summary_cache and data.summary_cache ~= "" then
        summary_cache_section = "Document summary:\n" .. data.summary_cache
    end
    user_prompt = replace_placeholder(user_prompt, "{summary_cache_section}", summary_cache_section)
    -- Raw placeholder
    if data.summary_cache then
        user_prompt = replace_placeholder(user_prompt, "{summary_cache}", data.summary_cache)
    end

    -- Handle different contexts
    if logger then
        logger.info("MessageBuilder: Entering context switch, context=", context)
    end
    if context == "multi_book" or context == "multi_file_browser" then
        -- Multi-book context with {count} and {books_list} substitution
        if data.books_info then
            local count = #data.books_info
            local books_list = {}
            for i, book in ipairs(data.books_info) do
                local book_str = string.format('%d. "%s"', i, book.title or "Unknown Title")
                if book.authors and book.authors ~= "" then
                    book_str = book_str .. " by " .. book.authors
                end
                table.insert(books_list, book_str)
            end
            user_prompt = replace_placeholder(user_prompt, "{count}", tostring(count))
            user_prompt = replace_placeholder(user_prompt, "{books_list}", table.concat(books_list, "\n"))
        elseif data.book_context then
            -- Fallback: use pre-formatted book context if books_info not available
            table.insert(parts, "[Context]")
            table.insert(parts, data.book_context)
            table.insert(parts, "")
        end
        table.insert(parts, "[Request]")
        table.insert(parts, user_prompt)

    elseif context == "book" or context == "file_browser" then
        -- Book context: add book info and substitute template variables
        if data.book_metadata then
            local metadata = data.book_metadata
            -- Add book context so AI knows which book we're discussing
            table.insert(parts, "[Context]")
            local book_info = string.format('Book: "%s"', metadata.title or "Unknown")
            if metadata.author and metadata.author ~= "" then
                book_info = book_info .. " by " .. metadata.author
            end
            table.insert(parts, book_info)
            table.insert(parts, "")
            -- Replace template variables in user prompt using replace_placeholder (avoids gsub escaping issues)
            if logger then
                logger.info("MessageBuilder: BOOK CONTEXT - substituting {title} with:", metadata.title or "Unknown")
            end
            user_prompt = replace_placeholder(user_prompt, "{title}", metadata.title or "Unknown")
            user_prompt = replace_placeholder(user_prompt, "{author}", metadata.author or "")
            user_prompt = replace_placeholder(user_prompt, "{author_clause}", metadata.author_clause or "")
        elseif data.book_context then
            -- Fallback: use pre-formatted book context string if metadata not available
            table.insert(parts, "[Context]")
            table.insert(parts, data.book_context)
            table.insert(parts, "")
        end
        table.insert(parts, "[Request]")
        table.insert(parts, user_prompt)

    elseif context == "general" then
        -- General context - just the prompt
        table.insert(parts, "[Request]")
        table.insert(parts, user_prompt)

    else  -- highlight context
        -- Check if prompt already includes {highlighted_text} - if so, don't duplicate in context
        local prompt_has_highlight_var = user_prompt:find("{highlighted_text}", 1, true) ~= nil

        -- Build context section
        -- Only include highlighted_text in context if the prompt doesn't already have the variable
        local has_context = data.book_title or (data.highlighted_text and not prompt_has_highlight_var)

        if has_context then
            table.insert(parts, "[Context]")

            -- Add book info if available (controlled by include_book_context flag)
            if data.book_title then
                table.insert(parts, string.format('From "%s"%s',
                    data.book_title,
                    (data.book_author and data.book_author ~= "") and (" by " .. data.book_author) or ""))
            end

            -- Inject request prefix before selected text (e.g., X-Ray source framing)
            if data.request_prefix then
                if data.book_title then
                    table.insert(parts, "")  -- Spacing after book info
                end
                table.insert(parts, data.request_prefix)
            end

            -- Add highlighted text only if not already in prompt template
            if data.highlighted_text and not prompt_has_highlight_var then
                if data.book_title or data.request_prefix then
                    table.insert(parts, "")  -- Add spacing if book info or prefix was shown
                end
                table.insert(parts, "Selected text:")
                table.insert(parts, '"' .. data.highlighted_text .. '"')
            end
            table.insert(parts, "")
        end

        -- Support template variables using replace_placeholder (avoids gsub escaping issues)
        if data.book_title then
            user_prompt = replace_placeholder(user_prompt, "{title}", data.book_title or "Unknown")
            user_prompt = replace_placeholder(user_prompt, "{author}", data.book_author or "")
            user_prompt = replace_placeholder(user_prompt, "{author_clause}",
                (data.book_author and data.book_author ~= "") and (" by " .. data.book_author) or "")
        end
        if data.highlighted_text then
            user_prompt = replace_placeholder(user_prompt, "{highlighted_text}", data.highlighted_text)
        end

        table.insert(parts, "[Request]")
        table.insert(parts, user_prompt)
    end

    -- Add additional user input if provided
    if data.additional_input and data.additional_input ~= "" then
        table.insert(parts, "")
        table.insert(parts, "[Additional user input]")
        table.insert(parts, data.additional_input)
    end

    return table.concat(parts, "\n")
end

--- Substitute template variables in a prompt string.
-- Uses replace_placeholder (find+sub) to avoid gsub escaping issues
-- @param prompt_text string the prompt with placeholders
-- @param data table with values for substitution
-- @return string the prompt with placeholders replaced
function MessageBuilder.substituteVariables(prompt_text, data)
    local result = prompt_text

    -- Utility placeholders (conciseness/hallucination nudges)
    if Templates then
        result = replace_placeholder(result, "{conciseness_nudge}", Templates.CONCISENESS_NUDGE or "")
        result = replace_placeholder(result, "{hallucination_nudge}", Templates.HALLUCINATION_NUDGE or "")
        -- Text fallback nudge (always empty in preview since we don't have extraction data)
        result = replace_placeholder(result, "{text_fallback_nudge}", "")
        -- Highlight analysis nudge (always empty in preview since we don't have extraction data)
        result = replace_placeholder(result, "{highlight_analysis_nudge}", "")
    end

    -- Common substitutions
    if data.translation_language then
        result = replace_placeholder(result, "{translation_language}", data.translation_language)
    end
    if data.dictionary_language then
        result = replace_placeholder(result, "{dictionary_language}", data.dictionary_language)
    end
    if data.context then
        result = replace_placeholder(result, "{context}", data.context)
    end
    if data.title then
        result = replace_placeholder(result, "{title}", data.title)
    end
    if data.author then
        result = replace_placeholder(result, "{author}", data.author)
    end
    if data.author_clause then
        result = replace_placeholder(result, "{author_clause}", data.author_clause)
    end
    if data.highlighted_text then
        result = replace_placeholder(result, "{highlighted_text}", data.highlighted_text)
    end
    if data.count then
        result = replace_placeholder(result, "{count}", tostring(data.count))
    end
    if data.books_list then
        result = replace_placeholder(result, "{books_list}", data.books_list)
    end

    -- Context extraction placeholders (from koassistant_context_extractor)
    if data.reading_progress then
        result = replace_placeholder(result, "{reading_progress}", data.reading_progress)
    end
    if data.progress_decimal then
        result = replace_placeholder(result, "{progress_decimal}", data.progress_decimal)
    end

    -- Section-aware placeholders: include label when content exists, empty string when not
    local book_text_section = ""
    if data.book_text and data.book_text ~= "" then
        book_text_section = "Book content so far:\n" .. data.book_text
    end
    result = replace_placeholder(result, "{book_text_section}", book_text_section)

    local highlights_section = ""
    if data.highlights and data.highlights ~= "" then
        highlights_section = "My highlights so far:\n" .. data.highlights
    end
    result = replace_placeholder(result, "{highlights_section}", highlights_section)

    local annotations_section = ""
    if data.annotations and data.annotations ~= "" then
        annotations_section = "My annotations:\n" .. data.annotations
    end
    result = replace_placeholder(result, "{annotations_section}", annotations_section)

    local notebook_section = ""
    if data.notebook_content and data.notebook_content ~= "" then
        notebook_section = "My notebook entries:\n" .. data.notebook_content
    end
    result = replace_placeholder(result, "{notebook_section}", notebook_section)

    -- {full_document_section}
    local full_document_section = ""
    if data.full_document and data.full_document ~= "" then
        full_document_section = "Full document:\n" .. data.full_document
    end
    result = replace_placeholder(result, "{full_document_section}", full_document_section)

    -- {surrounding_context_section}
    local surrounding_context_section = ""
    if data.surrounding_context and data.surrounding_context ~= "" then
        surrounding_context_section = "Surrounding text:\n" .. data.surrounding_context
    end
    result = replace_placeholder(result, "{surrounding_context_section}", surrounding_context_section)
    if data.surrounding_context then
        result = replace_placeholder(result, "{surrounding_context}", data.surrounding_context)
    end

    -- Raw placeholders (for custom prompts that want their own labels)
    if data.highlights ~= nil then
        result = replace_placeholder(result, "{highlights}", data.highlights)
    end
    if data.annotations ~= nil then
        result = replace_placeholder(result, "{annotations}", data.annotations)
    end
    if data.book_text then
        result = replace_placeholder(result, "{book_text}", data.book_text)
    end
    -- Reading stats (with fallbacks per hybrid approach)
    if data.chapter_title then
        result = replace_placeholder(result, "{chapter_title}", data.chapter_title)
    end
    if data.chapters_read then
        result = replace_placeholder(result, "{chapters_read}", data.chapters_read)
    end
    if data.time_since_last_read then
        result = replace_placeholder(result, "{time_since_last_read}", data.time_since_last_read)
    end
    if data.notebook_content ~= nil then
        result = replace_placeholder(result, "{notebook}", data.notebook_content)
    end
    if data.full_document then
        result = replace_placeholder(result, "{full_document}", data.full_document)
    end

    -- Cache-related placeholders (for X-Ray/Recap incremental updates)
    if data.cached_result then
        result = replace_placeholder(result, "{cached_result}", data.cached_result)
    end
    if data.cached_progress then
        result = replace_placeholder(result, "{cached_progress}", data.cached_progress)
    end
    local incremental_section = ""
    if data.incremental_book_text and data.incremental_book_text ~= "" then
        incremental_section = "New content since your last analysis:\n" .. data.incremental_book_text
    end
    result = replace_placeholder(result, "{incremental_book_text_section}", incremental_section)
    if data.incremental_book_text then
        result = replace_placeholder(result, "{incremental_book_text}", data.incremental_book_text)
    end
    local entity_index_section = ""
    if data.entity_index and data.entity_index ~= "" then
        entity_index_section = "Existing entities in previous analysis:\n" .. data.entity_index
    end
    result = replace_placeholder(result, "{entity_index}", entity_index_section)

    -- Document cache placeholders
    local xray_cache_section = ""
    if data.xray_cache and data.xray_cache ~= "" then
        local label = "Previous X-Ray"
        if data.xray_cache_progress then
            label = label .. " (as of " .. data.xray_cache_progress .. ")"
        end
        xray_cache_section = label .. ":\n" .. data.xray_cache
    end
    result = replace_placeholder(result, "{xray_cache_section}", xray_cache_section)
    if data.xray_cache then
        result = replace_placeholder(result, "{xray_cache}", data.xray_cache)
    end

    local analyze_cache_section = ""
    if data.analyze_cache and data.analyze_cache ~= "" then
        analyze_cache_section = "Document analysis:\n" .. data.analyze_cache
    end
    result = replace_placeholder(result, "{analyze_cache_section}", analyze_cache_section)
    if data.analyze_cache then
        result = replace_placeholder(result, "{analyze_cache}", data.analyze_cache)
    end

    local summary_cache_section = ""
    if data.summary_cache and data.summary_cache ~= "" then
        summary_cache_section = "Document summary:\n" .. data.summary_cache
    end
    result = replace_placeholder(result, "{summary_cache_section}", summary_cache_section)
    if data.summary_cache then
        result = replace_placeholder(result, "{summary_cache}", data.summary_cache)
    end

    return result
end

return MessageBuilder
