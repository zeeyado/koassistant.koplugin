--[[--
Notebook module for KOAssistant - Per-book markdown notebooks

Handles:
- Notebook file path resolution (sidecar-based)
- Page/chapter info extraction
- Entry formatting (Q+A with highlighted text)
- Appending entries to notebook files
- File stats for indexing

@module koassistant_notebook
]]

local DocSettings = require("docsettings")
local lfs = require("libs/libkoreader-lfs")
local logger = require("logger")

local Notebook = {}

--- Get notebook file path for a document
--- Returns nil for general/multi-book chats (no per-book context)
--- @param document_path string|nil The document file path
--- @return string|nil notebook_path The full path to the notebook file
function Notebook.getPath(document_path)
    if not document_path
        or document_path == "__GENERAL_CHATS__"
        or document_path == "__MULTI_BOOK_CHATS__" then
        return nil
    end
    local sidecar_dir = DocSettings:getSidecarDir(document_path)
    return sidecar_dir .. "/koassistant_notebook.md"
end

--- Check if notebook exists for a document
--- @param document_path string The document file path
--- @return boolean exists Whether the notebook file exists
function Notebook.exists(document_path)
    local path = Notebook.getPath(document_path)
    if not path then return false end
    local attr = lfs.attributes(path)
    return attr and attr.mode == "file"
end

--- Get current page info from ReaderUI
--- Extracts page number, progress percentage, and chapter title
--- @param ui table|nil ReaderUI instance (optional, will use ReaderUI.instance if not provided)
--- @return table page_info Table with page, progress, chapter, timestamp fields
function Notebook.getPageInfo(ui)
    local info = {
        page = nil,
        total_pages = nil,
        progress = nil,
        chapter = nil,
        timestamp = os.date("%Y-%m-%d %H:%M:%S"),
    }

    -- Use passed ui or try to get from ReaderUI.instance
    local reader_ui = ui
    if not reader_ui then
        local ReaderUI = require("apps/reader/readerui")
        reader_ui = ReaderUI.instance
    end

    if reader_ui and reader_ui.document then
        -- Get total pages
        info.total_pages = reader_ui.document.info and reader_ui.document.info.number_of_pages

        -- Get page number (same pattern as context_extractor)
        if reader_ui.document.info.has_pages then
            -- PDF/page-based document
            info.page = reader_ui.view and reader_ui.view.state and reader_ui.view.state.page
        else
            -- EPUB/flowing document
            local xp = reader_ui.document:getXPointer()
            if xp then
                info.page = reader_ui.document:getPageFromXPointer(xp)
            end
        end

        -- Get progress percentage
        if info.page and info.total_pages and info.total_pages > 0 then
            info.progress = math.floor((info.page / info.total_pages) * 100)
        end

        -- Get chapter title from TOC
        if reader_ui.toc and info.page then
            info.chapter = reader_ui.toc:getTocTitleByPage(info.page)
        end
    end

    return info
end

--- Format a notebook entry
--- Creates a markdown-formatted entry with timestamp, page info, and content based on format setting
---
--- Entry format (qa - default):
---   # [2026-01-31 14:30:00] (Page 42 - 15%) - Chapter Title
---   ## Explain
---
---   **Highlighted:**
---   > The selected passage that triggered this action
---
---   **Question:** User's follow-up question (if any)
---
---   **Response:**
---   AI's response here...
---
---   ---
---
--- @param data table Entry data: action_name, highlighted_text, question, response, context_messages
--- @param page_info table Page info from getPageInfo()
--- @param content_format string "response" | "qa" | "full_qa" (default: "qa")
--- @return string entry The formatted markdown entry
function Notebook.formatEntry(data, page_info, content_format)
    content_format = content_format or "qa"
    local parts = {}

    -- Header: timestamp + page info (always included)
    local header = "# [" .. page_info.timestamp .. "]"
    if page_info.page then
        header = header .. " (Page " .. page_info.page
        if page_info.progress then
            header = header .. " - " .. page_info.progress .. "%"
        end
        header = header .. ")"
    end
    if page_info.chapter then
        header = header .. " - " .. page_info.chapter
    end
    table.insert(parts, header)

    -- Action name as subheader (always included)
    table.insert(parts, "## " .. (data.action_name or "KOAssistant Chat"))
    table.insert(parts, "")

    -- Context messages (only for full_qa)
    if content_format == "full_qa" and data.context_messages then
        for _idx, msg in ipairs(data.context_messages) do
            local role = (msg.role or "context"):gsub("^%l", string.upper)
            table.insert(parts, "**" .. role .. " (context):**")
            table.insert(parts, msg.content or "")
            table.insert(parts, "")
        end
    end

    -- Highlighted text (qa and full_qa only)
    if content_format ~= "response" and data.highlighted_text and data.highlighted_text ~= "" then
        table.insert(parts, "**Highlighted:**")
        -- Convert newlines in highlighted text to blockquote continuation
        local quoted_text = "> " .. data.highlighted_text:gsub("\n", "\n> ")
        table.insert(parts, quoted_text)
        table.insert(parts, "")
    end

    -- Question (qa and full_qa only)
    if content_format ~= "response" and data.question and data.question ~= "" then
        table.insert(parts, "**Question:** " .. data.question)
        table.insert(parts, "")
    end

    -- Response (always included)
    if data.response and data.response ~= "" then
        table.insert(parts, "**Response:**")
        table.insert(parts, data.response)
        table.insert(parts, "")
    end

    -- Entry separator
    table.insert(parts, "---")
    table.insert(parts, "")

    return table.concat(parts, "\n")
end

--- Append entry to notebook file
--- Creates sidecar directory if needed
--- @param notebook_path string Full path to the notebook file
--- @param entry string Formatted entry text to append
--- @return boolean success Whether the append succeeded
--- @return string|nil error Error message if failed
function Notebook.append(notebook_path, entry)
    if not notebook_path then
        return false, "No notebook path"
    end

    -- Ensure sidecar directory exists
    local util = require("util")
    local dir = notebook_path:match("(.*/)")
    if dir then
        util.makePath(dir)
    end

    local file, err = io.open(notebook_path, "a")
    if not file then
        logger.err("KOAssistant Notebook: Failed to open file:", err)
        return false, "Failed to open: " .. (err or "unknown")
    end

    file:write(entry)
    file:close()
    return true, nil
end

--- Save chat to notebook (convenience function)
--- Extracts Q+A from history and formats as notebook entry
--- @param document_path string The document file path
--- @param history table MessageHistory object
--- @param highlighted_text string|nil Selected text (if any)
--- @param ui table|nil ReaderUI instance
--- @param content_format string|nil "response" | "qa" | "full_qa" (default: "qa")
--- @return boolean success Whether save succeeded
--- @return string|nil error Error message if failed
function Notebook.saveChat(document_path, history, highlighted_text, ui, content_format)
    local notebook_path = Notebook.getPath(document_path)
    if not notebook_path then
        return false, "No document open"
    end

    local page_info = Notebook.getPageInfo(ui)
    content_format = content_format or "qa"

    -- Extract messages from history
    local messages = history:getMessages() or {}
    local question, response = nil, nil
    local context_messages = {}

    for _idx, msg in ipairs(messages) do
        if msg.is_context then
            -- Collect context messages for full_qa mode
            table.insert(context_messages, msg)
        else
            if msg.role == "user" then
                question = msg.content
            elseif msg.role == "assistant" then
                response = msg.content
            end
        end
    end

    local entry = Notebook.formatEntry({
        question = question,
        response = response or "",
        action_name = history.prompt_action,
        highlighted_text = highlighted_text,
        context_messages = content_format == "full_qa" and context_messages or nil,
    }, page_info, content_format)

    return Notebook.append(notebook_path, entry)
end

--- Read notebook content
--- @param document_path string The document file path
--- @return string|nil content The notebook content or nil if not found
function Notebook.read(document_path)
    local path = Notebook.getPath(document_path)
    if not path then return nil end

    local file = io.open(path, "r")
    if not file then return nil end

    local content = file:read("*all")
    file:close()
    return content
end

--- Get file stats for index
--- @param document_path string The document file path
--- @return table|nil stats Table with size and modified timestamp, or nil if not found
function Notebook.getStats(document_path)
    local path = Notebook.getPath(document_path)
    if not path then return nil end

    local attr = lfs.attributes(path)
    if not attr or attr.mode ~= "file" then return nil end

    return {
        size = attr.size,
        modified = attr.modification,
    }
end

--- Create empty notebook with header
--- @param document_path string The document file path
--- @return boolean success Whether creation succeeded
--- @return string|nil error Error message if failed
function Notebook.create(document_path)
    local notebook_path = Notebook.getPath(document_path)
    if not notebook_path then
        return false, "Invalid document path"
    end

    -- Extract book name from path
    local book_name = document_path:match("([^/]+)%.[^%.]+$") or "Unknown"

    local header = "# Notebook: " .. book_name .. "\n\n---\n\n"

    -- Ensure sidecar directory exists
    local util = require("util")
    local dir = notebook_path:match("(.*/)")
    if dir then
        util.makePath(dir)
    end

    local file, err = io.open(notebook_path, "w")
    if not file then
        logger.err("KOAssistant Notebook: Failed to create file:", err)
        return false, "Failed to create: " .. (err or "unknown")
    end

    file:write(header)
    file:close()
    return true, nil
end

return Notebook
