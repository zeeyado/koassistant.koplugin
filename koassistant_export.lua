--[[
    Unified export formatting module for KOAssistant.

    Handles all export formatting with two dimensions:
    - Content: full | qa | response | everything (what to include)
    - Style: markdown | text (how to format)

    Used by: Copy button, Note button, Chat History export, Save to File
]]

local DataStorage = require("datastorage")
local lfs = require("libs/libkoreader-lfs")
local logger = require("logger")

local Export = {}

--- Build minimal context line for Q+A mode
-- Format: [Action • model] - minimal since notes have implicit book context
-- @param data table export data
-- @return string context line
local function buildContextLine(data)
    local action = data.title or "Chat"
    local model = data.model or "Unknown"
    return string.format("[%s • %s]", action, model)
end

--- Generate formatted text based on content and style settings
-- @param data table with: messages, model, title, date, book_title, book_author, books_info,
--                         domain, tags, launch_context, last_response, document_path (fallback)
-- @param content string: "full" | "qa" | "response" | "everything"
-- @param style string: "markdown" | "text"
-- @return string formatted export text
function Export.format(data, content, style)
    -- Response only - no styling needed, just raw text
    if content == "response" then
        return data.last_response or ""
    end

    local is_md = (style == "markdown")
    local result = {}

    -- Q+A mode: Add minimal context line before messages
    if content == "qa" then
        local context_line = buildContextLine(data)
        if context_line then
            table.insert(result, context_line)
            table.insert(result, "")
        end
    end

    -- Full/Everything content: Include metadata header
    if content == "full" or content == "everything" then
        if is_md then
            table.insert(result, "# " .. (data.title or "Chat"))
            table.insert(result, "**Date:** " .. (data.date or "Unknown"))

            -- Smart book display: multi-book > single book > document path (fallback)
            if data.books_info and #data.books_info > 0 then
                -- Multi-book: numbered list
                table.insert(result, "**Books:**")
                for i, book in ipairs(data.books_info) do
                    local book_line = string.format('%d. "%s"', i, book.title or "Unknown")
                    if book.authors and book.authors ~= "" then
                        book_line = book_line .. " by " .. book.authors
                    end
                    table.insert(result, book_line)
                end
            elseif data.book_title then
                -- Single book: title format
                local book_line = string.format('**Book:** "%s"', data.book_title)
                if data.book_author and data.book_author ~= "" then
                    book_line = book_line .. " by " .. data.book_author
                end
                table.insert(result, book_line)
            elseif data.document_path and data.document_path ~= ""
                   and data.document_path ~= "__GENERAL_CHATS__"
                   and data.document_path ~= "__MULTI_BOOK_CHATS__" then
                -- Fallback: show document path only if it's a real file
                table.insert(result, "**Document:** " .. data.document_path)
            end

            -- Domain and tags (Full/Everything only)
            if data.domain and data.domain ~= "" then
                table.insert(result, "**Domain:** " .. data.domain)
            end
            if data.tags and #data.tags > 0 then
                table.insert(result, "**Tags:** " .. table.concat(data.tags, ", "))
            end

            table.insert(result, "**Model:** " .. (data.model or "Unknown"))

            -- Launch context (general chats launched from a book)
            if data.launch_context and data.launch_context.title then
                local launch_info = string.format('**Launched from:** "%s"', data.launch_context.title)
                if data.launch_context.author then
                    launch_info = launch_info .. " by " .. data.launch_context.author
                end
                table.insert(result, launch_info)
            end
        else
            -- Plain text version
            table.insert(result, data.title or "Chat")
            table.insert(result, "Date: " .. (data.date or "Unknown"))

            -- Smart book display: multi-book > single book > document path (fallback)
            if data.books_info and #data.books_info > 0 then
                table.insert(result, "Books:")
                for i, book in ipairs(data.books_info) do
                    local book_line = string.format('%d. "%s"', i, book.title or "Unknown")
                    if book.authors and book.authors ~= "" then
                        book_line = book_line .. " by " .. book.authors
                    end
                    table.insert(result, book_line)
                end
            elseif data.book_title then
                local book_line = string.format('Book: "%s"', data.book_title)
                if data.book_author and data.book_author ~= "" then
                    book_line = book_line .. " by " .. data.book_author
                end
                table.insert(result, book_line)
            elseif data.document_path and data.document_path ~= ""
                   and data.document_path ~= "__GENERAL_CHATS__"
                   and data.document_path ~= "__MULTI_BOOK_CHATS__" then
                table.insert(result, "Document: " .. data.document_path)
            end

            -- Domain and tags
            if data.domain and data.domain ~= "" then
                table.insert(result, "Domain: " .. data.domain)
            end
            if data.tags and #data.tags > 0 then
                table.insert(result, "Tags: " .. table.concat(data.tags, ", "))
            end

            table.insert(result, "Model: " .. (data.model or "Unknown"))

            -- Launch context
            if data.launch_context and data.launch_context.title then
                local launch_info = string.format('Launched from: "%s"', data.launch_context.title)
                if data.launch_context.author then
                    launch_info = launch_info .. " by " .. data.launch_context.author
                end
                table.insert(result, launch_info)
            end
        end
        table.insert(result, "")
    end

    -- For Full/Everything: Show highlighted text as the user's initial input
    -- This represents what the user selected/requested (hidden from normal message display)
    if (content == "full" or content == "everything") and data.highlighted_text and data.highlighted_text ~= "" then
        if is_md then
            table.insert(result, "### User")
            table.insert(result, data.highlighted_text)
        else
            table.insert(result, "User:")
            table.insert(result, data.highlighted_text)
        end
        table.insert(result, "")
    end

    -- Messages (for "full", "qa", and "everything" content types)
    local messages = data.messages or {}
    local include_context = (content == "everything")
    for _idx, msg in ipairs(messages) do
        -- Skip context messages unless "everything" mode
        if include_context or not msg.is_context then
            local role = (msg.role or "unknown"):gsub("^%l", string.upper)
            if is_md then
                table.insert(result, "### " .. role)
                table.insert(result, msg.content or "")
            else
                table.insert(result, role .. ":")
                table.insert(result, msg.content or "")
            end
            table.insert(result, "")
        end
    end

    return table.concat(result, "\n")
end

--- Build export data from a MessageHistory object (live chats)
-- @param history MessageHistory instance
-- @param highlighted_text string optional original highlighted text
-- @param book_metadata table optional {title, author} for current book
-- @param books_info table optional array of {title, authors} for multi-book context
-- @return table data suitable for Export.format()
function Export.fromHistory(history, highlighted_text, book_metadata, books_info)
    local messages = history:getMessages() or {}
    local last_msg = history:getLastMessage()

    return {
        messages = messages,
        model = history:getModel(),
        title = history.prompt_action or "Chat",
        date = os.date("%Y-%m-%d %H:%M"),
        last_response = last_msg and last_msg.content or "",
        highlighted_text = highlighted_text,
        book_title = book_metadata and book_metadata.title,
        book_author = book_metadata and book_metadata.author,
        books_info = books_info,
    }
end

--- Build export data from a saved chat object (chat history)
-- @param chat table saved chat data from ChatHistoryManager
-- @return table data suitable for Export.format()
function Export.fromSavedChat(chat)
    local messages = chat.messages or {}
    local last_msg = messages[#messages]

    return {
        messages = messages,
        model = chat.model,
        title = chat.title or "Chat",
        date = os.date("%Y-%m-%d %H:%M", chat.timestamp or os.time()),
        document_path = chat.document_path,
        book_title = chat.book_title,
        book_author = chat.book_author,
        books_info = chat.metadata and chat.metadata.books_info,
        highlighted_text = chat.metadata and chat.metadata.original_highlighted_text,
        domain = chat.domain,
        tags = chat.tags,
        launch_context = chat.launch_context,
        last_response = last_msg and last_msg.content or "",
    }
end

--- Sanitize a string for use in filenames
-- @param str string Input string
-- @param max_len number Maximum length (default 30)
-- @return string Sanitized string safe for filenames
local function sanitizeForFilename(str, max_len)
    max_len = max_len or 30
    if not str or str == "" then
        return ""
    end

    -- Remove/replace problematic characters for filenames
    local safe = str:gsub("[/\\:*?\"<>|]", "_")
    -- Replace spaces with underscores
    safe = safe:gsub("%s+", "_")
    -- Collapse multiple consecutive underscores
    safe = safe:gsub("_+", "_")
    -- Remove leading/trailing underscores
    safe = safe:gsub("^_+", ""):gsub("_+$", "")

    -- Truncate if too long, try to break at underscore
    if #safe > max_len then
        safe = safe:sub(1, max_len)
        -- Remove partial word if we cut mid-word
        local last_underscore = safe:match(".*()_")
        if last_underscore and last_underscore > (max_len / 2) then
            safe = safe:sub(1, last_underscore - 1)
        end
        -- Remove trailing underscores after truncation
        safe = safe:gsub("_+$", "")
    end

    return safe
end

--- Generate a safe filename from book title, chat title, and timestamp
-- @param book_title string|nil Book title (optional)
-- @param chat_title string|nil Chat display name (optional, e.g. "Explain", or user-renamed "My Analysis")
-- @param chat_timestamp number|nil Unix timestamp of chat (optional, uses current time if nil)
-- @param extension string File extension ("md" or "txt")
-- @return string Safe filename
-- Format: [book]_[chat_title]_[YYYYMMDD_HHMMSS].[ext]
-- Example: "The_Clear_Quran_Explain_20260131_123559.md"
function Export.getFilename(book_title, chat_title, chat_timestamp, extension)
    extension = extension or "md"
    local timestamp = os.date("%Y%m%d_%H%M%S", chat_timestamp)

    local safe_book = sanitizeForFilename(book_title, 30)
    local safe_chat = sanitizeForFilename(chat_title, 25)

    -- Build filename parts
    local parts = {}
    if safe_book ~= "" then
        table.insert(parts, safe_book)
    end
    if safe_chat ~= "" then
        table.insert(parts, safe_chat)
    end
    table.insert(parts, timestamp)

    return table.concat(parts, "_") .. "." .. extension
end

--- Get the export directory based on settings
-- @param settings table Features settings table
-- @param book_path string|nil Path to the current book (for "book_folder" option)
-- @return string|nil Directory path, or nil if "ask" mode
-- @return string|nil Error message if path is invalid
function Export.getDirectory(settings, book_path)
    settings = settings or {}
    local dir_option = settings.export_save_directory or "book_folder"

    if dir_option == "ask" then
        -- Caller should show PathChooser
        return nil, nil
    end

    local target_dir
    local custom_path = settings.export_custom_path

    -- Helper to get book's folder
    local function getBookFolder()
        if book_path and book_path ~= "" and book_path ~= "__GENERAL_CHATS__" and book_path ~= "__MULTI_BOOK_CHATS__" then
            local dir = book_path:match("(.*/)")
            if not dir then
                dir = book_path:match("(.*\\)")  -- Windows path
            end
            return dir
        end
        return nil
    end

    if dir_option == "book_folder" then
        -- Same folder as book + /chats/ subfolder, fallback to exports folder
        local book_folder = getBookFolder()
        if book_folder then
            target_dir = book_folder .. "chats"
        else
            target_dir = DataStorage:getDataDir() .. "/koassistant_exports"
        end
    elseif dir_option == "book_folder_custom" then
        -- Same folder as book + /chats/ subfolder, fallback to custom path
        local book_folder = getBookFolder()
        if book_folder then
            target_dir = book_folder .. "chats"
        else
            target_dir = custom_path
            if not target_dir or target_dir == "" then
                return nil, "Custom path not set (required for general chats)"
            end
        end
    elseif dir_option == "exports_folder" then
        target_dir = DataStorage:getDataDir() .. "/koassistant_exports"
    elseif dir_option == "custom" then
        target_dir = custom_path
        if not target_dir or target_dir == "" then
            return nil, "Custom path not set"
        end
    else
        -- Default fallback
        target_dir = DataStorage:getDataDir() .. "/koassistant_exports"
    end

    -- Ensure directory exists
    if target_dir then
        local attr = lfs.attributes(target_dir)
        if not attr then
            -- Try to create the directory
            local ok, err = lfs.mkdir(target_dir)
            if not ok then
                logger.warn("Export: Failed to create directory:", target_dir, err)
                return nil, "Failed to create directory: " .. (err or "unknown error")
            end
        elseif attr.mode ~= "directory" then
            return nil, "Path exists but is not a directory"
        end
    end

    return target_dir, nil
end

--- Save formatted export text to a file
-- @param text string Formatted text to save
-- @param filepath string Full path to the output file
-- @return boolean Success status
-- @return string|nil Error message on failure
function Export.saveToFile(text, filepath)
    if not text or text == "" then
        return false, "No content to export"
    end

    if not filepath or filepath == "" then
        return false, "No file path specified"
    end

    local file, err = io.open(filepath, "w")
    if not file then
        logger.warn("Export: Failed to open file for writing:", filepath, err)
        return false, "Failed to open file: " .. (err or "unknown error")
    end

    local ok, write_err = file:write(text)
    file:close()

    if not ok then
        logger.warn("Export: Failed to write to file:", filepath, write_err)
        return false, "Failed to write file: " .. (write_err or "unknown error")
    end

    logger.info("Export: Successfully saved to:", filepath)
    return true, nil
end

--- Export chat to a file (convenience function combining format + save)
-- @param data table Export data (from fromHistory or fromSavedChat)
-- @param content string Content type: "full" | "qa" | "response" | "everything"
-- @param style string Style type: "markdown" | "text"
-- @param filepath string Full path to output file
-- @return boolean Success status
-- @return string|nil Error message on failure
function Export.exportToFile(data, content, style, filepath)
    local text = Export.format(data, content, style)
    return Export.saveToFile(text, filepath)
end

return Export
