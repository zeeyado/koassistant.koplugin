local MessageHistory = {}

-- Message roles
MessageHistory.ROLES = {
    SYSTEM = "system",
    USER = "user",
    ASSISTANT = "assistant"
}

function MessageHistory:new(system_prompt, prompt_action)
    local history = {
        messages = {},
        model = nil,  -- Will be set after first response
        chat_id = nil, -- Chat ID for existing chats
        prompt_action = prompt_action, -- Store the action/prompt type for naming
        launch_context = nil -- For general chats launched from within a book
    }
    
    if system_prompt then
        table.insert(history.messages, {
            role = self.ROLES.SYSTEM,
            content = system_prompt
        })
    end
    
    setmetatable(history, self)
    self.__index = self
    return history
end

function MessageHistory:addUserMessage(content, is_context)
    table.insert(self.messages, {
        role = self.ROLES.USER,
        content = content,
        is_context = is_context or false
    })
    return #self.messages
end

function MessageHistory:addAssistantMessage(content, model)
    table.insert(self.messages, {
        role = self.ROLES.ASSISTANT,
        content = content
    })
    if model then
        self.model = model
    end
    return #self.messages
end

function MessageHistory:getMessages()
    return self.messages
end

function MessageHistory:getLastMessage()
    if #self.messages > 0 then
        return self.messages[#self.messages]
    end
    return nil
end

function MessageHistory:getModel()
    return self.model
end

function MessageHistory:clear()
    -- Keep system message if it exists
    if self.messages[1] and self.messages[1].role == self.ROLES.SYSTEM then
        self.messages = {self.messages[1]}
    else
        self.messages = {}
    end
    return self
end

-- Create a new instance from saved messages
function MessageHistory:fromSavedMessages(messages, model, chat_id, prompt_action, launch_context)
    local history = self:new()

    -- Clear any default messages
    history.messages = {}

    -- Add all saved messages
    if messages and #messages > 0 then
        for _, msg in ipairs(messages) do
            table.insert(history.messages, msg)
        end
    end

    -- Set the model if provided
    if model then
        history.model = model
    end

    -- Set the chat ID if provided
    if chat_id then
        history.chat_id = chat_id
    end

    -- Set the prompt action if provided
    if prompt_action then
        history.prompt_action = prompt_action
    end

    -- Set the launch context if provided (for general chats launched from a book)
    if launch_context then
        history.launch_context = launch_context
    end

    return history
end

-- Get a title suggestion based on the first user message
function MessageHistory:getSuggestedTitle()
    -- Try to create a meaningful title based on context and content
    
    -- First, check if we have a prompt action stored
    local action_prefix = ""
    if self.prompt_action then
        action_prefix = self.prompt_action .. " - "
    end
    
    -- Look for highlighted text in messages
    local highlighted_text = nil
    
    -- Look through all messages for highlighted text or user content
    for _, msg in ipairs(self.messages) do
        if msg.role == self.ROLES.USER then
            -- Check if this is a consolidated message with sections
            if msg.content:match("%[Context%]") or msg.content:match("Highlighted text:") then
                -- Try to extract highlighted text from various formats
                local highlight_match = msg.content:match("Highlighted text:%s*\n?\"([^\"]+)\"")
                if not highlight_match then
                    highlight_match = msg.content:match("Selected text:%s*\n?\"([^\"]+)\"")
                end
                if highlight_match then
                    highlighted_text = highlight_match
                end
            end
            
            -- If we still don't have highlighted text, check for [Request] section
            if not highlighted_text and not msg.is_context then
                local request_match = msg.content:match("%[Request%]%s*\n([^\n]+)")
                if request_match then
                    -- This is likely the user's actual question/request
                    local snippet = request_match:sub(1, 40):gsub("\n", " ")
                    if #request_match > 40 then
                        snippet = snippet .. "..."
                    end
                    return action_prefix .. snippet
                end
            end
        end
    end
    
    -- If we found highlighted text, use it
    if highlighted_text then
        local snippet = highlighted_text:sub(1, 40):gsub("\n", " ")
        if #highlighted_text > 40 then
            snippet = snippet .. "..."
        end
        return action_prefix .. snippet
    end
    
    -- Otherwise, look for first actual user message/question
    for _, msg in ipairs(self.messages) do
        if msg.role == self.ROLES.USER and not msg.is_context then
            -- Try to extract the meaningful part
            local content = msg.content
            
            -- Skip system instructions and context sections
            local user_part = content:match("%[User Question%]%s*\n([^\n]+)") or
                            content:match("%[Additional user input%]%s*\n([^\n]+)") or
                            content
            
            -- Clean up and use first part
            local first_words = user_part:sub(1, 40):gsub("\n", " "):gsub("^%s*(.-)%s*$", "%1")
            if #user_part > 40 then
                first_words = first_words .. "..."
            end
            
            -- Don't return generic phrases
            if first_words ~= "I have a question for you." and first_words ~= "" then
                return action_prefix .. first_words
            end
        end
    end
    
    -- Ultimate fallback
    return action_prefix .. "Chat"
end

function MessageHistory:createResultText(highlightedText, config)
    local result = {}

    -- Show launch context header if this is a general chat launched from a book
    if self.launch_context and self.launch_context.title then
        local launch_note = "[Launched from: " .. self.launch_context.title
        if self.launch_context.author then
            launch_note = launch_note .. " by " .. self.launch_context.author
        end
        launch_note = launch_note .. "]\n\n"
        table.insert(result, launch_note)
    end

    -- Check if we should show the highlighted text
    local should_hide = config and config.features and (
        config.features.hide_highlighted_text or
        (config.features.hide_long_highlights and highlightedText and
         string.len(highlightedText) > (config.features.long_highlight_threshold or 280))
    )

    if not should_hide and highlightedText and highlightedText ~= "" then
        -- Check if this is file browser context
        if config and config.features and config.features.is_file_browser_context then
            table.insert(result, "Book metadata:\n" .. highlightedText .. "\n\n")
        else
            table.insert(result, "Highlighted text: \"" .. highlightedText .. "\"\n\n")
        end
    end

    -- Debug mode: show messages sent to AI
    if config and config.features and config.features.debug then
        local display_level = config.features.debug_display_level or "names"

        table.insert(result, "--- Debug Info ---\n\n")

        -- Show system config info based on display level
        if display_level == "names" or display_level == "full" then
            -- Show behavior variant, domain, model, and temperature
            local behavior = config.features.ai_behavior_variant or "full"
            local domain = config.features.selected_domain or "none"
            local model = config.model or "default"
            -- Truncate long model names (e.g., "claude-sonnet-4-5-20250929" -> "claude-sonnet-4-5")
            if #model > 20 then
                model = model:sub(1, 17) .. "..."
            end
            local temp = config.additional_parameters and config.additional_parameters.temperature or 0.7
            table.insert(result, string.format("● Config: behavior=%s, domain=%s\n", behavior, domain))

            -- Check for extended thinking
            local thinking_info = ""
            if config.api_params and config.api_params.thinking then
                local budget = config.api_params.thinking.budget_tokens or 0
                thinking_info = string.format(", thinking=%d", budget)
            end
            table.insert(result, string.format("  model=%s, temp=%.1f%s\n\n", model, temp, thinking_info))
        end

        if display_level == "full" and config.system then
            -- Show system array content with labels
            table.insert(result, "● System Array:\n")
            for _, block in ipairs(config.system) do
                local label = block.label or "unknown"
                local cached = block.cache_control and " [CACHED]" or ""
                local preview = block.text or ""
                -- Show first 100 chars of each block
                if #preview > 100 then
                    preview = preview:sub(1, 100):gsub("\n", " ") .. "..."
                else
                    preview = preview:gsub("\n", " ")
                end
                table.insert(result, string.format("  %s%s: %s\n", label, cached, preview))
            end
            table.insert(result, "\n")
        end

        -- Show messages (always, but label based on level)
        if display_level ~= "minimal" then
            table.insert(result, "● Messages:\n")
        end

        -- Find the last user message (current query)
        local last_user_index = #self.messages
        for i = #self.messages, 1, -1 do
            if self.messages[i].role == self.ROLES.USER then
                last_user_index = i
                break
            end
        end

        -- Show all messages up to and including the last user message
        for i = 1, last_user_index do
            local msg = self.messages[i]
            local role_text = msg.role:gsub("^%l", string.upper)
            local context_tag = msg.is_context and " [Initial]" or ""
            local prefix = ""
            if msg.role == self.ROLES.USER then
                prefix = "▶ "
            elseif msg.role == self.ROLES.ASSISTANT then
                prefix = "◉ "
            else
                prefix = "● "  -- For system messages
            end
            table.insert(result, prefix .. role_text .. context_tag .. ": " .. msg.content .. "\n\n")
        end
        table.insert(result, "------------------\n\n")
    end

    -- Show conversation (non-context messages)
    for i = 2, #self.messages do
        if not self.messages[i].is_context then
            local prefix = self.messages[i].role == self.ROLES.USER and "▶ User: " or "◉ KOAssistant: "
            table.insert(result, prefix .. self.messages[i].content .. "\n\n")
        end
    end
    
    return table.concat(result)
end

return MessageHistory 