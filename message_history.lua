local ModelConstraints = require("model_constraints")

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

function MessageHistory:addAssistantMessage(content, model, reasoning)
    local message = {
        role = self.ROLES.ASSISTANT,
        content = content
    }
    -- Store reasoning if provided (for models with visible thinking)
    if reasoning then
        message.reasoning = reasoning
    end
    table.insert(self.messages, message)
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
        -- Check context type and use appropriate label
        if config and config.features then
            if config.features.is_book_context then
                -- Single book context from file browser
                table.insert(result, "Book: " .. highlightedText .. "\n\n")
            elseif config.features.is_multi_book_context then
                -- Multiple books selected
                table.insert(result, "Selected books:\n" .. highlightedText .. "\n\n")
            else
                -- Default: highlighted text from reader
                table.insert(result, "Highlighted text: \"" .. highlightedText .. "\"\n\n")
            end
        else
            table.insert(result, "Highlighted text: \"" .. highlightedText .. "\"\n\n")
        end
    end

    -- Debug display: show messages sent to AI (controlled by show_debug_in_chat, independent of console debug)
    if config and config.features and config.features.show_debug_in_chat then
        local display_level = config.features.debug_display_level or "names"

        table.insert(result, "--- Debug Info ---\n\n")

        -- Show system config info based on display level
        if display_level == "names" or display_level == "full" then
            -- Show provider, behavior variant, domain, model, and temperature
            local provider = config.provider or config.default_provider or "unknown"
            local behavior = config.features.ai_behavior_variant or "full"
            local domain = config.features.selected_domain or "none"

            -- Get actual model from provider settings if available
            local model = config.model
            if (not model or model == "default") and config.provider_settings and config.provider_settings[provider] then
                model = config.provider_settings[provider].model
            end
            model = model or "default"

            -- Truncate long model names (e.g., "claude-sonnet-4-5-20250929" -> "claude-sonnet-4-5")
            if #model > 25 then
                model = model:sub(1, 22) .. "..."
            end

            local temp = config.additional_parameters and config.additional_parameters.temperature or 0.7
            -- Also check api_params for temperature (new location)
            if config.api_params and config.api_params.temperature then
                temp = config.api_params.temperature
            end

            -- Check for reasoning/thinking configuration (per-provider toggles)
            -- Show provider-specific reasoning info based on SETTINGS (features.*_reasoning)
            -- not api_params (which is only set during API call)
            local reasoning_info = ""
            local features = config.features or {}
            local full_model = config.model or model

            -- Determine if reasoning is enabled for this provider+model (check settings)
            if provider == "anthropic" and features.anthropic_reasoning then
                -- Anthropic: check if model supports extended thinking
                if ModelConstraints.supportsCapability("anthropic", full_model, "extended_thinking") then
                    local budget = features.reasoning_budget or 4096
                    reasoning_info = string.format(", thinking=%d", budget)
                end
            elseif provider == "openai" and features.openai_reasoning then
                -- OpenAI: check if model supports reasoning
                if ModelConstraints.supportsCapability("openai", full_model, "reasoning") then
                    local effort = features.reasoning_effort or "medium"
                    reasoning_info = string.format(", reasoning=%s", effort)
                end
            elseif provider == "gemini" and features.gemini_reasoning then
                -- Gemini: check if model supports thinking
                if ModelConstraints.supportsCapability("gemini", full_model, "thinking") then
                    local depth = features.reasoning_depth or "high"
                    reasoning_info = string.format(", thinking=%s", depth:lower())
                end
            elseif provider == "deepseek" then
                -- DeepSeek: reasoner always reasons, chat doesn't
                if ModelConstraints.supportsCapability("deepseek", full_model, "reasoning") then
                    reasoning_info = ", reasoning=auto"
                end
            end

            -- Apply model constraints to get effective temperature
            -- (e.g., gpt-5/o3 require temp=1.0, Anthropic max is 1.0, extended thinking requires 1.0)
            local effective_temp = temp
            local temp_adjusted = false
            local temp_reason = nil

            -- Check model constraints
            local test_params = { temperature = temp }
            local full_model = config.model or model
            local _, adjustments = ModelConstraints.apply(provider, full_model, test_params)
            if adjustments and adjustments.temperature then
                effective_temp = adjustments.temperature.to
                temp_adjusted = true
                temp_reason = adjustments.temperature.reason
            end

            -- Extended thinking always forces temp=1.0 (Anthropic only, when model supports it)
            if has_thinking and provider == "anthropic" and effective_temp ~= 1.0 then
                if ModelConstraints.supportsCapability("anthropic", full_model, "extended_thinking") then
                    effective_temp = 1.0
                    temp_adjusted = true
                    temp_reason = "extended thinking"
                end
            end

            -- Format temperature display
            local temp_display
            if temp_adjusted then
                temp_display = string.format("%.1f→%.1f (%s)", temp, effective_temp, temp_reason or "model constraint")
            else
                temp_display = string.format("%.1f", temp)
            end

            table.insert(result, string.format("● Config: provider=%s, behavior=%s, domain=%s\n", provider, behavior, domain))
            table.insert(result, string.format("  model=%s, temp=%s%s\n\n", model, temp_display, reasoning_info))
        end

        if display_level == "full" and config.system then
            -- Determine header based on provider (Anthropic uses array format)
            local provider = config.provider or config.default_provider or "unknown"
            local header = (provider == "anthropic") and "● System Array:\n" or "● System Prompt:\n"
            table.insert(result, header)

            -- Handle unified format (v0.5.2+): { text, enable_caching, components }
            if config.system.text ~= nil then
                local cached = config.system.enable_caching and " [CACHED]" or ""

                -- Build component names list for the header
                local comp_names = {}
                local comps = config.system.components or {}
                if comps.behavior then table.insert(comp_names, "behavior") end
                if comps.domain then table.insert(comp_names, "domain") end
                if comps.language then table.insert(comp_names, "language") end

                if #comp_names > 0 then
                    -- Show combined header like "behavior+domain+language [CACHED]:"
                    local combined = table.concat(comp_names, "+")
                    table.insert(result, string.format("  %s%s:\n", combined, cached))

                    -- Show each component as sub-item
                    if comps.behavior then
                        local preview = comps.behavior:sub(1, 80):gsub("\n", " ")
                        if #comps.behavior > 80 then preview = preview .. "..." end
                        table.insert(result, string.format("    - behavior: %s\n", preview))
                    end
                    if comps.domain then
                        local preview = comps.domain:sub(1, 80):gsub("\n", " ")
                        if #comps.domain > 80 then preview = preview .. "..." end
                        table.insert(result, string.format("    - domain: %s\n", preview))
                    end
                    if comps.language then
                        local preview = comps.language:sub(1, 80):gsub("\n", " ")
                        if #comps.language > 80 then preview = preview .. "..." end
                        table.insert(result, string.format("    - language: %s\n", preview))
                    end
                else
                    -- Fallback: show combined text
                    local preview = config.system.text or ""
                    if #preview > 100 then
                        preview = preview:sub(1, 100):gsub("\n", " ") .. "..."
                    else
                        preview = preview:gsub("\n", " ")
                    end
                    table.insert(result, string.format("  text%s: %s\n", cached, preview))
                end
            -- Legacy array format (for backwards compatibility)
            elseif #config.system > 0 then
                for _, block in ipairs(config.system) do
                    local label = block.label or "unknown"
                    local cached_flag = block.cache_control and " [CACHED]" or ""
                    local preview = block.text or ""
                    if #preview > 100 then
                        preview = preview:sub(1, 100):gsub("\n", " ") .. "..."
                    else
                        preview = preview:gsub("\n", " ")
                    end
                    table.insert(result, string.format("  %s%s: %s\n", label, cached_flag, preview))
                end
            else
                table.insert(result, "  (empty)\n")
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

    -- Check if reasoning display is enabled
    local show_reasoning = config and config.features and config.features.show_reasoning_in_chat

    -- Show conversation (non-context messages)
    for i = 2, #self.messages do
        if not self.messages[i].is_context then
            local msg = self.messages[i]
            local prefix = msg.role == self.ROLES.USER and "▶ User: " or "◉ KOAssistant: "

            -- If this is an assistant message with reasoning, show indicator
            -- msg.reasoning can be: string (actual content) or true (detected but not captured)
            if msg.role == self.ROLES.ASSISTANT and msg.reasoning then
                if show_reasoning and type(msg.reasoning) == "string" then
                    -- Show full reasoning content (only available for non-streaming)
                    table.insert(result, "**[Extended Thinking]**\n")
                    table.insert(result, "> " .. msg.reasoning:gsub("\n", "\n> ") .. "\n\n")
                else
                    -- Just show indicator that reasoning was used
                    table.insert(result, "*[Reasoning/Thinking was used]*\n\n")
                end
            end

            table.insert(result, prefix .. msg.content .. "\n\n")
        end
    end

    return table.concat(result)
end

return MessageHistory 