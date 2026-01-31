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

--- Generate formatted text based on content and style settings
-- @param data table with: messages, model, title, date, document_path, launch_context, last_response
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

    -- Full/Everything content: Include metadata header
    if content == "full" or content == "everything" then
        if is_md then
            table.insert(result, "# " .. (data.title or "Chat"))
            table.insert(result, "**Date:** " .. (data.date or "Unknown"))
            if data.document_path and data.document_path ~= "" then
                table.insert(result, "**Document:** " .. data.document_path)
            end
            table.insert(result, "**Model:** " .. (data.model or "Unknown"))
            if data.launch_context and data.launch_context ~= "" then
                table.insert(result, "**Context:** " .. data.launch_context)
            end
        else
            table.insert(result, data.title or "Chat")
            table.insert(result, "Date: " .. (data.date or "Unknown"))
            if data.document_path and data.document_path ~= "" then
                table.insert(result, "Document: " .. data.document_path)
            end
            table.insert(result, "Model: " .. (data.model or "Unknown"))
            if data.launch_context and data.launch_context ~= "" then
                table.insert(result, "Context: " .. data.launch_context)
            end
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
-- @return table data suitable for Export.format()
function Export.fromHistory(history, highlighted_text)
    local messages = history:getMessages() or {}
    local last_msg = history:getLastMessage()

    return {
        messages = messages,
        model = history:getModel(),
        title = history.prompt_action or "Chat",
        date = os.date("%Y-%m-%d %H:%M"),
        last_response = last_msg and last_msg.content or "",
        highlighted_text = highlighted_text,
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
        if book_path and book_path ~= "" and book_path ~= "__GENERAL_CHATS__" then
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
