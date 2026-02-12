local ModelConstraints = require("model_constraints")
local DebugUtils = require("koassistant_debug_utils")

local MessageHistory = {}

-- Message roles
MessageHistory.ROLES = {
    SYSTEM = "system",
    USER = "user",
    ASSISTANT = "assistant"
}

-- Debug truncation settings for chat view (smaller than terminal for readability)
local DEBUG_MAX_CONTENT = 5000  -- Total chars to show in debug
local DEBUG_EDGE_SIZE = 2000   -- Chars to show from each end

--- Truncate long text for debug display
--- Uses shared DebugUtils for consistent truncation format across all contexts
--- @param text string The text to truncate
--- @return string Truncated text with notice, or original if short enough
local function truncateForDebug(text)
    return DebugUtils.truncate(text, DEBUG_MAX_CONTENT, DEBUG_EDGE_SIZE)
end

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

function MessageHistory:addAssistantMessage(content, model, reasoning, debug_info, web_search_used)
    local message = {
        role = self.ROLES.ASSISTANT,
        content = content
    }
    -- Store reasoning if provided (for models with visible thinking)
    if reasoning then
        message.reasoning = reasoning
    end
    -- Store web search indicator if search was used
    if web_search_used then
        message.web_search_used = true
    end
    -- Store debug info for accurate historical display (NOT exported with chat)
    if debug_info then
        message._debug_info = debug_info
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

-- Count user messages (for determining if this is a multi-turn conversation)
-- Returns the number of user messages, excluding system messages
function MessageHistory:getUserTurnCount()
    local count = 0
    for _idx, msg in ipairs(self.messages) do
        if msg.role == self.ROLES.USER then
            count = count + 1
        end
    end
    return count
end

-- Count assistant messages (responses) for scroll behavior
-- Returns the number of AI responses, used to determine if this is a follow-up
function MessageHistory:getAssistantTurnCount()
    local count = 0
    for _idx, msg in ipairs(self.messages) do
        if msg.role == self.ROLES.ASSISTANT then
            count = count + 1
        end
    end
    return count
end

-- Estimate total tokens in conversation (messages + system prompt)
-- Uses rough heuristic: 1 token ≈ 4 characters
-- @param system_text string Optional system prompt text to include
-- @return number Estimated token count
function MessageHistory:estimateTokens(system_text)
    local total_chars = 0
    for _idx, msg in ipairs(self.messages) do
        if msg.content then
            total_chars = total_chars + #msg.content
        end
    end
    if system_text then
        total_chars = total_chars + #system_text
    end
    return math.floor(total_chars / 4)
end

-- Get all reasoning content from assistant messages (for "View Reasoning" feature)
-- Returns array of { index, reasoning, has_content } for messages with reasoning
function MessageHistory:getReasoningEntries()
    local entries = {}
    local msg_num = 0

    for i, msg in ipairs(self.messages) do
        if msg.role == self.ROLES.ASSISTANT and not msg.is_context then
            msg_num = msg_num + 1
            if msg.reasoning then
                local entry = {
                    index = i,
                    msg_num = msg_num,
                    has_content = type(msg.reasoning) == "string",
                    reasoning = msg.reasoning,
                }
                -- For OpenAI requested reasoning
                if type(msg.reasoning) == "table" and msg.reasoning._requested then
                    entry.requested_only = true
                    entry.effort = msg.reasoning.effort
                end
                table.insert(entries, entry)
            end
        end
    end

    return entries
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
-- @param messages array The saved messages
-- @param model string The model name
-- @param chat_id string The chat ID
-- @param prompt_action string The action that created this chat
-- @param launch_context table Launch context for general chats from a book
-- @param chat_metadata table Additional chat-level metadata (cache info, truncation info)
function MessageHistory:fromSavedMessages(messages, model, chat_id, prompt_action, launch_context, chat_metadata)
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

    -- Restore chat-level metadata (cache info, truncation info)
    if chat_metadata then
        -- Cache continuation info (for "Updated from X% cache" notice)
        if chat_metadata.used_cache then
            history.used_cache = chat_metadata.used_cache
            history.cached_progress = chat_metadata.cached_progress
            history.cache_action_id = chat_metadata.cache_action_id
        end
        -- Book text truncation info
        if chat_metadata.book_text_truncated then
            history.book_text_truncated = chat_metadata.book_text_truncated
            history.book_text_coverage_start = chat_metadata.book_text_coverage_start
            history.book_text_coverage_end = chat_metadata.book_text_coverage_end
        end
        -- Unavailable data info
        if chat_metadata.unavailable_data then
            history.unavailable_data = chat_metadata.unavailable_data
        end
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

    -- Show cache notice if this response was generated from cached data
    -- This must be first so it appears at the top and persists through debug toggle
    if self.used_cache and self.cached_progress then
        table.insert(result, string.format("*Updated from %s cache*\n\n---\n\n", self.cached_progress))
    end

    -- Show book text truncation notice if extraction was limited
    -- Helps user understand why AI might not know about earlier content
    if self.book_text_truncated then
        local start_pct = self.book_text_coverage_start or 0
        local end_pct = self.book_text_coverage_end or 0
        table.insert(result, string.format(
            "*Book text truncated (~%d%%–%d%% coverage). Increase limit in Advanced Settings → Book Text Extraction. You can also use Hidden Flows to exclude irrelevant sections.*\n\n---\n\n",
            start_pct, end_pct))
    end

    -- Show unavailable data notice if action requested data but didn't receive it
    if self.unavailable_data and #self.unavailable_data > 0 then
        local items = table.concat(self.unavailable_data, ", ")
        table.insert(result, string.format(
            "*Response generated without: %s*\n\n---\n\n", items))
    end

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
        local is_book = config and config.features and config.features.is_book_context
        local is_multi = config and config.features and config.features.is_multi_book_context
        -- Detect book context from content when flag isn't set (e.g., continued from history)
        if not is_book and not is_multi and (highlightedText:match("^Title:") or highlightedText:match("^Book:")) then
            is_book = true
        end
        if is_book then
            -- Book context: self-describing string (Title: ... Author: ...)
            table.insert(result, highlightedText .. "\n\n")
        elseif is_multi then
            -- Multiple books selected
            table.insert(result, "Selected books:\n" .. highlightedText .. "\n\n")
        else
            -- Default: highlighted text from reader
            table.insert(result, "Highlighted text: \"" .. highlightedText .. "\"\n\n")
        end
    end

    -- Debug display: show messages sent to AI (controlled by show_debug_in_chat, independent of console debug)
    if config and config.features and config.features.show_debug_in_chat then
        local display_level = config.features.debug_display_level or "names"

        table.insert(result, "--- Debug Info ---\n\n")

        -- Show system config info based on display level
        if display_level == "names" or display_level == "full" then
            -- Find stored debug info from the last assistant message (what was USED)
            local stored_debug = nil
            for i = #self.messages, 1, -1 do
                if self.messages[i].role == self.ROLES.ASSISTANT and self.messages[i]._debug_info then
                    stored_debug = self.messages[i]._debug_info
                    break
                end
            end

            -- Use stored debug info if available, otherwise fall back to current config
            local provider, model, temp, behavior, domain, reasoning_info

            if stored_debug then
                -- Use what was ACTUALLY used for this chat
                provider = stored_debug.provider or "unknown"
                model = stored_debug.model or "default"
                temp = stored_debug.temperature or 0.7
                behavior = stored_debug.behavior or "standard"
                domain = stored_debug.domain or "none"

                -- Build reasoning info from stored data
                reasoning_info = ""
                if stored_debug.reasoning then
                    local r = stored_debug.reasoning
                    if r.type == "anthropic" and r.budget then
                        reasoning_info = string.format(", thinking=%d", r.budget)
                    elseif r.type == "openai" and r.effort then
                        reasoning_info = string.format(", reasoning=%s", r.effort)
                    elseif r.type == "gemini" and r.level then
                        reasoning_info = string.format(", thinking=%s", r.level:lower())
                    elseif r.type == "deepseek" then
                        reasoning_info = ", reasoning=auto"
                    end
                end
            else
                -- Fall back to current config (for chats created before debug storage)
                provider = config.provider or config.default_provider or "unknown"
                behavior = config.features.selected_behavior or "standard"
                domain = config.features.selected_domain or "none"

                -- Get actual model from provider settings if available
                model = config.model
                if (not model or model == "default") and config.provider_settings and config.provider_settings[provider] then
                    model = config.provider_settings[provider].model
                end
                model = model or "default"

                temp = config.additional_parameters and config.additional_parameters.temperature or 0.7
                if config.api_params and config.api_params.temperature then
                    temp = config.api_params.temperature
                end

                -- Build reasoning info from current settings
                reasoning_info = ""
                local features = config.features or {}
                local full_model = config.model or model

                if provider == "anthropic" and features.anthropic_reasoning then
                    if ModelConstraints.supportsCapability("anthropic", full_model, "extended_thinking") then
                        local budget = features.reasoning_budget or 4096
                        reasoning_info = string.format(", thinking=%d", budget)
                    end
                elseif provider == "openai" and features.openai_reasoning then
                    if ModelConstraints.supportsCapability("openai", full_model, "reasoning") then
                        local effort = features.reasoning_effort or "medium"
                        reasoning_info = string.format(", reasoning=%s", effort)
                    end
                elseif provider == "gemini" and features.gemini_reasoning then
                    if ModelConstraints.supportsCapability("gemini", full_model, "thinking") then
                        local depth = features.reasoning_depth or "high"
                        reasoning_info = string.format(", thinking=%s", depth:lower())
                    end
                elseif provider == "deepseek" then
                    if ModelConstraints.supportsCapability("deepseek", full_model, "reasoning") then
                        reasoning_info = ", reasoning=auto"
                    end
                end
            end

            -- Truncate long model names (e.g., "claude-sonnet-4-5-20250929" -> "claude-sonnet-4-5")
            if #model > 25 then
                model = model:sub(1, 22) .. "..."
            end

            -- Format temperature display (simple for stored, with constraints check for fallback)
            local temp_display = string.format("%.1f", temp)

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
            table.insert(result, prefix .. role_text .. context_tag .. ": " .. truncateForDebug(msg.content) .. "\n\n")
        end
        table.insert(result, "------------------\n\n")
    end

    -- Check if reasoning indicator should be shown in chat
    -- Controlled by show_reasoning_indicator setting (default: true)
    local show_reasoning_indicator = config and config.features and config.features.show_reasoning_indicator
    if show_reasoning_indicator == nil then show_reasoning_indicator = true end  -- Default to showing indicator

    -- Check if web search indicator should be shown in chat
    -- Controlled by show_web_search_indicator setting (default: true)
    local show_web_search_indicator = config and config.features and config.features.show_web_search_indicator
    if show_web_search_indicator == nil then show_web_search_indicator = true end  -- Default to showing indicator

    -- Show conversation (non-context messages)
    -- In compact mode (dictionary lookups), hide prefixes for cleaner display
    local hide_prefixes = config and config.features and config.features.compact_view
    local added_first_message = false
    for i = 2, #self.messages do
        if not self.messages[i].is_context then
            local msg = self.messages[i]

            -- Add separator between messages (renders as <hr> in markdown, --- in plain text)
            if added_first_message then
                table.insert(result, "---\n\n")
            end
            added_first_message = true

            local prefix = ""
            if not hide_prefixes then
                -- Paragraph break after label (works in both markdown and plain text)
                prefix = msg.role == self.ROLES.USER and "▶ User:\n\n" or "◉ KOAssistant:\n\n"
            end

            -- If this is an assistant message with reasoning, show indicator
            -- msg.reasoning can be:
            --   string: actual reasoning content (Anthropic, DeepSeek, Gemini - non-streaming)
            --   true: reasoning detected but not captured (streaming mode)
            --   { _requested = true, effort = "..." }: requested but API doesn't expose (OpenAI)
            -- Note: Full reasoning content is viewable via "Show Reasoning" button in ChatGPTViewer
            if show_reasoning_indicator and msg.role == self.ROLES.ASSISTANT and msg.reasoning then
                if type(msg.reasoning) == "table" and msg.reasoning._requested then
                    -- OpenAI: reasoning was requested but API doesn't expose content
                    local effort = msg.reasoning.effort and (" (" .. msg.reasoning.effort .. ")") or ""
                    table.insert(result, "*[Reasoning requested" .. effort .. "]*\n\n")
                else
                    -- Reasoning confirmed (content may or may not be captured)
                    table.insert(result, "*[Reasoning/Thinking was used]*\n\n")
                end
            end

            -- If this is an assistant message with web search used, show indicator
            if show_web_search_indicator and msg.role == self.ROLES.ASSISTANT and msg.web_search_used then
                table.insert(result, "*[Web search was used]*\n\n")
            end

            table.insert(result, prefix .. msg.content .. "\n\n")
        end
    end

    return table.concat(result)
end

--- Create formatted text for translate view
-- Shows original text and translation with minimal markers (▶ and ◉)
-- @param highlighted_text string The original highlighted text
-- @param hide_quote boolean Whether to hide the original text
-- @return string Formatted text for display
function MessageHistory:createTranslateViewText(highlighted_text, hide_quote)
    local result = {}

    -- Show original with User marker (unless hidden)
    if not hide_quote and highlighted_text and highlighted_text ~= "" then
        table.insert(result, "▶ " .. highlighted_text .. "\n\n")
        table.insert(result, "---\n\n")
    end

    -- Show translation with KOAssistant marker
    for _idx, msg in ipairs(self.messages) do
        if msg.role == self.ROLES.ASSISTANT then
            table.insert(result, "◉ " .. msg.content .. "\n\n")
        end
    end

    return table.concat(result)
end

return MessageHistory 