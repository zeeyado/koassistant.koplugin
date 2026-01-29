--[[
    Unified export formatting module for KOAssistant.

    Handles all export formatting with two dimensions:
    - Content: full | qa | response | everything (what to include)
    - Style: markdown | text (how to format)

    Used by: Copy button, Note button, Chat History export
]]

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

return Export
