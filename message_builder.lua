--[[--
Shared message builder for KOAssistant.

This module is used by both the plugin (dialogs.lua) and the test framework (inspect.lua)
to ensure consistent message formatting.

@module message_builder
]]

local MessageBuilder = {}

-- Try to load logger, but make it optional for standalone testing
local logger
pcall(function()
    logger = require("logger")
end)

local function log_warn(msg)
    if logger then
        logger.warn(msg)
    end
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
            local ok, Templates = pcall(require, "prompts/templates")
            if ok and Templates then
                user_prompt = Templates.get(prompt.template)
            end
        end
    end
    if not user_prompt then
        log_warn("Action missing prompt field: " .. (prompt.text or "unknown"))
        user_prompt = ""
    end

    -- Substitute language placeholders early (applies to all contexts)
    if data.translation_language then
        user_prompt = user_prompt:gsub("{translation_language}", data.translation_language)
    end
    if data.dictionary_language then
        user_prompt = user_prompt:gsub("{dictionary_language}", data.dictionary_language)
    end
    -- Substitute {context} placeholder for surrounding text (dictionary lookups)
    if data.context then
        user_prompt = user_prompt:gsub("{context}", data.context)
    end

    -- Handle different contexts
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
            user_prompt = user_prompt:gsub("{count}", tostring(count))
            user_prompt = user_prompt:gsub("{books_list}", table.concat(books_list, "\n"))
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
            -- Replace template variables in user prompt
            user_prompt = user_prompt:gsub("{title}", metadata.title or "Unknown")
            user_prompt = user_prompt:gsub("{author}", metadata.author or "")
            user_prompt = user_prompt:gsub("{author_clause}", metadata.author_clause or "")
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

            -- Add highlighted text only if not already in prompt template
            if data.highlighted_text and not prompt_has_highlight_var then
                if data.book_title then
                    table.insert(parts, "")  -- Add spacing if book info was shown
                end
                table.insert(parts, "Selected text:")
                table.insert(parts, '"' .. data.highlighted_text .. '"')
            end
            table.insert(parts, "")
        end

        -- Support template variables
        if data.book_title then
            user_prompt = user_prompt:gsub("{title}", data.book_title or "Unknown")
            user_prompt = user_prompt:gsub("{author}", data.book_author or "")
            user_prompt = user_prompt:gsub("{author_clause}",
                (data.book_author and data.book_author ~= "") and (" by " .. data.book_author) or "")
        end
        if data.highlighted_text then
            user_prompt = user_prompt:gsub("{highlighted_text}", data.highlighted_text)
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
-- @param prompt_text string the prompt with placeholders
-- @param data table with values for substitution
-- @return string the prompt with placeholders replaced
function MessageBuilder.substituteVariables(prompt_text, data)
    local result = prompt_text

    -- Common substitutions
    if data.translation_language then
        result = result:gsub("{translation_language}", data.translation_language)
    end
    if data.dictionary_language then
        result = result:gsub("{dictionary_language}", data.dictionary_language)
    end
    if data.context then
        result = result:gsub("{context}", data.context)
    end
    if data.title then
        result = result:gsub("{title}", data.title)
    end
    if data.author then
        result = result:gsub("{author}", data.author)
    end
    if data.author_clause then
        result = result:gsub("{author_clause}", data.author_clause)
    end
    if data.highlighted_text then
        result = result:gsub("{highlighted_text}", data.highlighted_text)
    end
    if data.count then
        result = result:gsub("{count}", tostring(data.count))
    end
    if data.books_list then
        result = result:gsub("{books_list}", data.books_list)
    end

    return result
end

return MessageBuilder
