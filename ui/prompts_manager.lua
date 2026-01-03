local _ = require("gettext")
local logger = require("logger")
local DataStorage = require("datastorage")
local UIManager = require("ui/uimanager")
local Menu = require("ui/widget/menu")
local InfoMessage = require("ui/widget/infomessage")
local ConfirmBox = require("ui/widget/confirmbox")
local InputDialog = require("ui/widget/inputdialog")
local ButtonDialog = require("ui/widget/buttondialog")
local TextViewer = require("ui/widget/textviewer")
local UIConstants = require("ui/constants")

local PromptsManager = {}

function PromptsManager:new(plugin)
    local o = {
        plugin = plugin,
        width = UIConstants.DIALOG_WIDTH(),
        height = UIConstants.DIALOG_HEIGHT(),
    }
    setmetatable(o, self)
    self.__index = self
    return o
end

function PromptsManager:show()
    self:loadPrompts()
    self:showPromptsMenu()
end

function PromptsManager:loadPrompts()
    self.prompts = {}

    local service = self.plugin.action_service
    if not service then
        logger.warn("PromptsManager: No prompt service available")
        return
    end

    -- Load all prompts from all contexts
    local highlight_prompts = service:getAllPrompts("highlight", true)
    local book_prompts = service:getAllPrompts("book", true)
    local multi_book_prompts = service:getAllPrompts("multi_book", true)
    local general_prompts = service:getAllPrompts("general", true)

    -- Helper to add prompt with new field names
    -- Preserves compound contexts (all, both) from original_context
    local function addPromptEntry(prompt, context_override)
        -- Use original context if it's a compound context (all, both)
        local context = prompt.original_context
        if context == "all" or context == "both" then
            -- Keep compound context as-is
        else
            -- Use the override for simple contexts
            context = context_override or prompt.original_context or "highlight"
        end

        -- Extract temperature from api_params if present
        local temperature = prompt.api_params and prompt.api_params.temperature or nil

        return {
            text = prompt.text,
            behavior_variant = prompt.behavior_variant,
            behavior_override = prompt.behavior_override,
            prompt = prompt.prompt,
            context = context,
            source = prompt.source,
            enabled = prompt.enabled,
            requires = prompt.requires,
            id = prompt.id,
            include_book_context = prompt.include_book_context,
            temperature = temperature,
            extended_thinking = prompt.extended_thinking,
            thinking_budget = prompt.thinking_budget,
        }
    end

    -- Track seen prompts to avoid duplicates from compound contexts
    local seen = {}

    -- Add highlight prompts
    for _, prompt in ipairs(highlight_prompts) do
        local key = prompt.text .. "|" .. (prompt.source or "")
        if not seen[key] then
            table.insert(self.prompts, addPromptEntry(prompt, "highlight"))
            seen[key] = true
        end
    end

    -- Add book prompts (avoid duplicates for "both" context)
    for _, prompt in ipairs(book_prompts) do
        local key = prompt.text .. "|" .. (prompt.source or "")
        if not seen[key] then
            -- Check if this prompt already exists in highlight context
            local exists = false
            for _, existing in ipairs(self.prompts) do
                if existing.text == prompt.text and existing.source == prompt.source then
                    -- Change context to "both" (unless it's already a compound)
                    if existing.context ~= "all" and existing.context ~= "both" then
                        existing.context = "both"
                    end
                    exists = true
                    break
                end
            end

            if not exists then
                table.insert(self.prompts, addPromptEntry(prompt, "book"))
            end
            seen[key] = true
        end
    end

    -- Add multi-book prompts
    for _, prompt in ipairs(multi_book_prompts) do
        local key = prompt.text .. "|" .. (prompt.source or "")
        if not seen[key] then
            table.insert(self.prompts, addPromptEntry(prompt, "multi_book"))
            seen[key] = true
        end
    end

    -- Add general prompts
    for _, prompt in ipairs(general_prompts) do
        local key = prompt.text .. "|" .. (prompt.source or "")
        if not seen[key] then
            -- Check if this prompt already exists in other contexts
            local exists = false
            for _, existing in ipairs(self.prompts) do
                if existing.text == prompt.text and existing.source == prompt.source then
                    -- Update context to include general (unless it's already a compound)
                    if existing.context == "highlight" then
                        existing.context = "highlight+general"
                    elseif existing.context == "book" then
                        existing.context = "book+general"
                    elseif existing.context == "both" then
                        existing.context = "all"
                    end
                    -- Don't change if already "all"
                    exists = true
                    break
                end
            end

            if not exists then
                table.insert(self.prompts, addPromptEntry(prompt, "general"))
            end
            seen[key] = true
        end
    end

    logger.info("PromptsManager: Total prompts loaded: " .. #self.prompts)
end

function PromptsManager:setPromptEnabled(prompt_text, context, enabled)
    if self.plugin.action_service then
        self.plugin.action_service:setActionEnabled(context, prompt_text, enabled)
    end
end

function PromptsManager:showPromptsMenu()
    local menu_items = {}
    
    -- Add help text at the top
    table.insert(menu_items, {
        text = _("Tap to toggle • Hold for details • ★ = editable"),
        dim = true,
        enabled = false,
    })
    
    -- Add "Add New Prompt" item
    table.insert(menu_items, {
        text = _("+ Add Action"),
        callback = function()
            UIManager:close(self.prompts_menu)
            self:showPromptEditor(nil)  -- nil = new prompt
        end,
    })
    
    -- No separator needed here
    
    -- Group prompts by context
    local contexts = {
        { id = "highlight", text = _("Highlight Context") },
        { id = "book", text = _("Book Context (File Browser)") },
        { id = "multi_book", text = _("Multi-Book Context") },
        { id = "general", text = _("General Context") },
        { id = "both", text = _("Highlight & Book") },
        { id = "highlight+general", text = _("Highlight & General") },
        { id = "book+general", text = _("Book & General") },
        { id = "all", text = _("All Contexts") },
    }
    
    for _, context_info in ipairs(contexts) do
        local context_prompts = {}
        for _, prompt in ipairs(self.prompts) do
            if prompt.context == context_info.id then
                table.insert(context_prompts, prompt)
            end
        end
        
        if #context_prompts > 0 then
            -- Add context header with spacing
            -- No empty line needed, the section header provides visual separation
            table.insert(menu_items, {
                text = "▶ " .. context_info.text:upper(),
                enabled = false,
                dim = false,
                bold = true,
            })
            
            -- Add prompts for this context
            for _, prompt in ipairs(context_prompts) do
                local item_text = prompt.text

                -- Add source indicator for user-created prompts (editable/deletable)
                if prompt.source == "ui" then
                    item_text = "★ " .. item_text
                elseif prompt.source == "config" then
                    item_text = item_text .. " (file)"
                end

                -- Add requires indicator
                if prompt.requires then
                    item_text = item_text .. " [" .. prompt.requires .. "]"
                end

                -- Add checkbox with better spacing
                local checkbox = prompt.enabled and "☑" or "☐"
                item_text = checkbox .. "  " .. item_text
                
                table.insert(menu_items, {
                    text = item_text,
                    prompt = prompt,  -- Store reference to prompt
                    callback = function()
                        -- Toggle enabled state
                        self:setPromptEnabled(prompt.text, prompt.context, not prompt.enabled)
                        -- Refresh the menu
                        self:refreshMenu()
                    end,
                    hold_callback = function()
                        -- Show details on hold
                        -- Don't close the menu, just show the details dialog on top
                        self:showPromptDetails(prompt)
                    end,
                })
            end
        end
    end
    
    -- Create footer buttons
    local buttons = {
        {
            {
                text = _("Import"),
                enabled = false,
                callback = function()
                    UIManager:show(InfoMessage:new{
                        text = _("Import feature coming soon..."),
                    })
                end,
            },
            {
                text = _("Export"),
                enabled = false,
                callback = function()
                    UIManager:show(InfoMessage:new{
                        text = _("Export feature coming soon..."),
                    })
                end,
            },
            {
                text = _("Restore Defaults"),
                callback = function()
                    UIManager:show(ConfirmBox:new{
                        text = _("This will remove all custom actions and reset all action settings. Continue?"),
                        ok_callback = function()
                            UIManager:close(self.prompts_menu)
                            if self.plugin.restoreDefaultPrompts then
                                self.plugin:restoreDefaultPrompts()
                            end
                            -- Refresh the menu
                            UIManager:scheduleIn(0.1, function()
                                self:show()
                            end)
                        end,
                    })
                end,
            },
        },
    }
    
    self.prompts_menu = Menu:new{
        title = _("Manage Actions"),
        item_table = menu_items,
        width = self.width,
        height = self.height,
        is_borderless = true,
        is_popout = false,
        onMenuSelect = function(_, item)
            if item and item.callback then
                item.callback()
            end
        end,
        onMenuHold = function(_, item)
            if item and item.hold_callback then
                item.hold_callback()
            end
        end,
        close_callback = function()
            UIManager:close(self.prompts_menu)
        end,
        buttons_table = buttons,
    }
    
    UIManager:show(self.prompts_menu)
end

function PromptsManager:refreshMenu()
    -- Close and reopen the menu to refresh it
    if self.prompts_menu then
        local menu = self.prompts_menu
        UIManager:close(menu)
        -- Schedule reopening after close
        UIManager:scheduleIn(0.1, function()
            self:show()
        end)
    end
end

function PromptsManager:showPromptDetails(prompt)
    local source_text
    if prompt.source == "builtin" then
        source_text = _("Built-in")
    elseif prompt.source == "config" then
        source_text = _("Custom (custom_actions.lua)")
    elseif prompt.source == "ui" then
        source_text = _("User-defined (UI)")
    else
        source_text = prompt.source or _("Unknown")
    end

    -- Determine behavior display text
    local behavior_text
    if prompt.behavior_override and prompt.behavior_override ~= "" then
        behavior_text = _("Custom: ") .. prompt.behavior_override
    elseif prompt.behavior_variant == "none" then
        behavior_text = _("None (disabled)")
    elseif prompt.behavior_variant then
        behavior_text = prompt.behavior_variant
    else
        behavior_text = _("(Use global setting)")
    end

    -- Temperature display
    local temp_text = prompt.temperature and string.format("%.1f", prompt.temperature) or _("Global")

    -- Extended thinking display
    local thinking_text
    if prompt.extended_thinking == "on" then
        local budget = prompt.thinking_budget or 4096
        thinking_text = string.format(_("On (%d tokens)"), budget)
    elseif prompt.extended_thinking == "off" then
        thinking_text = _("Off")
    else
        thinking_text = _("Global")
    end

    local info_text = string.format(
        "%s\n\n%s: %s\n%s: %s\n%s: %s\n%s: %s\n%s: %s\n\n%s:\n%s\n\n%s:\n%s",
        prompt.text,
        _("Context"), self:getContextDisplayName(prompt.context),
        _("Source"), source_text,
        _("Status"), prompt.enabled and _("Enabled") or _("Disabled"),
        _("Temperature"), temp_text,
        _("Extended Thinking"), thinking_text,
        _("AI Behavior"),
        behavior_text,
        _("Action Prompt"),
        prompt.prompt or _("(None)")
    )

    if prompt.requires then
        info_text = info_text .. "\n\n" .. _("Requires") .. ": " .. prompt.requires
    end
    
    local buttons = {}

    -- Edit button (only for UI-created prompts)
    if prompt.source == "ui" then
        -- Row with Edit and Delete buttons
        table.insert(buttons, {
            {
                text = _("Edit"),
                callback = function()
                    -- Close the details dialog first
                    if self.details_dialog then
                        UIManager:close(self.details_dialog)
                    end
                    self:showPromptEditor(prompt)
                end,
            },
            {
                text = _("Delete"),
                callback = function()
                    UIManager:show(ConfirmBox:new{
                        text = _("Delete this action?"),
                        ok_callback = function()
                            self:deletePrompt(prompt)
                            -- Close details and prompts menu, then refresh
                            if self.details_dialog then
                                UIManager:close(self.details_dialog)
                            end
                            if self.prompts_menu then
                                UIManager:close(self.prompts_menu)
                            end
                            self:show()
                        end,
                    })
                end,
            },
        })
    elseif prompt.source == "config" then
        -- Prompts from custom_prompts.lua - show info about editing
        table.insert(buttons, {
            {
                text = _("Edit file"),
                callback = function()
                    UIManager:show(InfoMessage:new{
                        text = _("This action is defined in custom_actions.lua.\nPlease edit that file directly to modify it."),
                    })
                end,
            },
        })
    end

    self.details_dialog = TextViewer:new{
        title = _("Action Details"),
        text = info_text,
        buttons_table = buttons,
        width = self.width * 0.9,
        height = self.height * 0.8,
    }
    UIManager:show(self.details_dialog)
end

-- Wizard Step 1: Enter prompt name and select context
function PromptsManager:showPromptEditor(existing_prompt)
    local is_edit = existing_prompt ~= nil

    -- Initialize wizard state
    local state = {
        name = existing_prompt and existing_prompt.text or "",
        behavior_variant = existing_prompt and existing_prompt.behavior_variant or nil,  -- nil = use global
        behavior_override = existing_prompt and existing_prompt.behavior_override or "",
        prompt = existing_prompt and existing_prompt.prompt or "",
        context = existing_prompt and existing_prompt.context or nil,
        include_book_context = existing_prompt and existing_prompt.include_book_context or (not existing_prompt and true) or false,
        domain = existing_prompt and existing_prompt.domain or nil,
        temperature = existing_prompt and existing_prompt.temperature or nil,  -- nil = use global
        extended_thinking = existing_prompt and existing_prompt.extended_thinking or nil,  -- nil = use global, "off" = force off, "on" = force on
        thinking_budget = existing_prompt and existing_prompt.thinking_budget or nil,  -- nil = use global default
        existing_prompt = existing_prompt,
    }

    self:showStep1_NameAndContext(state)
end

-- Step 1: Name and Context selection
function PromptsManager:showStep1_NameAndContext(state)
    local is_edit = state.existing_prompt ~= nil

    -- Build button rows
    local button_rows = {}

    -- Row 1: Cancel, Context, Next
    table.insert(button_rows, {
        {
            text = _("Cancel"),
            id = "close",
            callback = function()
                UIManager:close(self.step1_dialog)
            end,
        },
        {
            text = _("Context: ") .. (state.context and self:getContextDisplayName(state.context) or _("Not set")),
            callback = function()
                state.name = self.step1_dialog:getInputText()
                UIManager:close(self.step1_dialog)
                self:showContextSelectorWizard(state)
            end,
        },
        {
            text = _("Next →"),
            callback = function()
                local name = self.step1_dialog:getInputText()
                if name == "" then
                    UIManager:show(InfoMessage:new{
                        text = _("Please enter a prompt name"),
                    })
                    return
                end
                if not state.context then
                    UIManager:show(InfoMessage:new{
                        text = _("Please select a context first"),
                    })
                    return
                end
                state.name = name
                UIManager:close(self.step1_dialog)
                self:showStep2_Behavior(state)
            end,
        },
    })

    -- Row 2: Book Info toggle (only for contexts that include highlight)
    if state.context and self:contextIncludesHighlight(state.context) then
        local checkbox = state.include_book_context and "☑ " or "☐ "
        table.insert(button_rows, {
            {
                text = checkbox .. _("Include book info (title, author)"),
                callback = function()
                    state.name = self.step1_dialog:getInputText()
                    state.include_book_context = not state.include_book_context
                    UIManager:close(self.step1_dialog)
                    self:showStep1_NameAndContext(state)
                end,
            },
        })
    end

    -- Build description based on context
    local description = _("Example: 'Summarize', 'Explain Simply', 'Find Themes'")
    if state.context then
        local info = self:getContextInfo(state.context, state.include_book_context)
        if info and info.includes then
            description = description .. "\n\n" .. info.includes
        end
    end

    self.step1_dialog = InputDialog:new{
        title = is_edit and _("Edit Action - Name") or _("Step 1/3: Name & Context"),
        input = state.name,
        input_hint = _("Enter a short name (shown as button)"),
        description = description,
        buttons = button_rows,
    }

    UIManager:show(self.step1_dialog)
    self.step1_dialog:onShowKeyboard()
end

-- Get context info including what data is available
function PromptsManager:getContextInfo(context_value, include_book_context)
    local context_info = {
        highlight = {
            text = _("Highlight"),
            desc = _("When text is selected in a book"),
            -- Note: book info can be optionally included via include_book_context flag
            includes = include_book_context
                and _("Includes: selected text + book title, author")
                or _("Includes: selected text only"),
        },
        book = {
            text = _("Book"),
            desc = _("File browser selection or 'Chat about book' gesture"),
            includes = _("Includes: book title, author (automatic)"),
        },
        multi_book = {
            text = _("Multi-Book"),
            desc = _("When multiple books are selected"),
            includes = _("Includes: list of books with titles/authors, count"),
        },
        general = {
            text = _("General"),
            desc = _("General chat, no specific context"),
            includes = _("No automatic context data"),
        },
        both = {
            text = _("Highlight & Book"),
            desc = _("Both highlight and book contexts"),
            includes = _("Highlight: selected text; Book: title/author"),
        },
        all = {
            text = _("All Contexts"),
            desc = _("Available everywhere"),
            includes = _("Varies by trigger"),
        },
    }
    return context_info[context_value]
end

-- Check if a context includes highlight context (where include_book_context applies)
function PromptsManager:contextIncludesHighlight(context)
    return context == "highlight" or context == "both" or context == "all"
end

-- Get default system prompt for a context
-- For compound contexts (both, all), returns nil since the actual default varies by trigger
function PromptsManager:getDefaultSystemPrompt(context)
    local defaults = {
        highlight = "You are a helpful reading assistant. The user has highlighted text from a book and wants help understanding or exploring it.",
        book = "You are an AI assistant helping with questions about books. The user has selected a book from their library and wants to know more about it.",
        multi_book = "You are an AI assistant helping analyze and compare books. The user has selected multiple books from their library and wants insights about the collection.",
        general = "You are a helpful AI assistant ready to engage in conversation, answer questions, and help with various tasks.",
        -- Compound contexts don't have a single default - it varies by how the prompt is triggered
        both = nil,
        all = nil,
    }
    return defaults[context]
end

-- Context selector for wizard
function PromptsManager:showContextSelectorWizard(state)
    local context_options = {
        { value = "highlight" },
        { value = "book" },
        { value = "multi_book" },
        { value = "general" },
        { value = "both" },
        { value = "all" },
    }

    local buttons = {}

    for _, option in ipairs(context_options) do
        -- For highlight context, show info based on current include_book_context setting
        local info = self:getContextInfo(option.value, state.include_book_context)
        local prefix = (state.context == option.value) and "● " or "○ "
        -- Show context name on first line, description and includes on subsequent lines
        local button_text = prefix .. info.text
        if info.desc then
            button_text = button_text .. "\n    " .. info.desc
        end
        if info.includes then
            button_text = button_text .. "\n    " .. info.includes
        end
        table.insert(buttons, {
            {
                text = button_text,
                callback = function()
                    state.context = option.value
                    UIManager:close(self.context_dialog)
                    self:showStep1_NameAndContext(state)
                end,
            },
        })
    end

    table.insert(buttons, {
        {
            text = _("Cancel"),
            callback = function()
                UIManager:close(self.context_dialog)
                self:showStep1_NameAndContext(state)
            end,
        },
    })

    self.context_dialog = ButtonDialog:new{
        title = _("Select Context"),
        buttons = buttons,
    }

    UIManager:show(self.context_dialog)
end

-- Step 2: AI Behavior (optional)
-- NEW ARCHITECTURE (v0.5): Select behavior variant or enter custom override
function PromptsManager:showStep2_Behavior(state)
    local is_edit = state.existing_prompt ~= nil

    -- Determine current selection for radio button display
    local current_selection = "global"  -- Default
    if state.behavior_override and state.behavior_override ~= "" then
        current_selection = "custom"
    elseif state.behavior_variant == "none" then
        current_selection = "none"
    elseif state.behavior_variant == "minimal" then
        current_selection = "minimal"
    elseif state.behavior_variant == "full" then
        current_selection = "full"
    end

    -- Build behavior options as buttons
    local behavior_options = {
        { id = "global", text = _("Use global setting"), desc = _("Inherits from Settings → Advanced → AI Behavior Style") },
        { id = "minimal", text = _("Minimal"), desc = _("Brief, focused responses (~100 tokens)") },
        { id = "full", text = _("Full"), desc = _("Comprehensive Claude-style guidelines (~500 tokens)") },
        { id = "none", text = _("None"), desc = _("No behavior instructions - just your action prompt") },
        { id = "custom", text = _("Custom..."), desc = _("Define your own AI personality/role") },
    }

    local buttons = {}

    for _, option in ipairs(behavior_options) do
        local prefix = (current_selection == option.id) and "● " or "○ "
        table.insert(buttons, {
            {
                text = prefix .. option.text .. "\n    " .. option.desc,
                callback = function()
                    UIManager:close(self.behavior_dialog)
                    if option.id == "custom" then
                        -- Show custom behavior input
                        self:showCustomBehaviorInput(state)
                    else
                        -- Set the variant
                        if option.id == "global" then
                            state.behavior_variant = nil
                            state.behavior_override = ""
                        elseif option.id == "none" then
                            state.behavior_variant = "none"
                            state.behavior_override = ""
                        else
                            state.behavior_variant = option.id
                            state.behavior_override = ""
                        end
                        self:showStep3_ActionPrompt(state)
                    end
                end,
            },
        })
    end

    -- Navigation buttons
    table.insert(buttons, {
        {
            text = _("← Back"),
            callback = function()
                UIManager:close(self.behavior_dialog)
                self:showStep1_NameAndContext(state)
            end,
        },
        {
            text = _("Skip (use global)"),
            callback = function()
                state.behavior_variant = nil
                state.behavior_override = ""
                UIManager:close(self.behavior_dialog)
                self:showStep3_ActionPrompt(state)
            end,
        },
    })

    self.behavior_dialog = ButtonDialog:new{
        title = is_edit and _("Edit Action - AI Behavior") or _("Step 2/3: AI Behavior"),
        buttons = buttons,
    }

    UIManager:show(self.behavior_dialog)
end

-- Custom behavior input dialog
function PromptsManager:showCustomBehaviorInput(state)
    local is_edit = state.existing_prompt ~= nil

    local dialog
    dialog = InputDialog:new{
        title = is_edit and _("Edit Action - Custom Behavior") or _("Step 2/3: Custom Behavior"),
        input = state.behavior_override or "",
        input_hint = _("Describe how the AI should behave or what role it should play"),
        description = _("Examples:\n" ..
            "• 'You are a grammar expert. Be precise and analytical.'\n" ..
            "• 'You are a literary critic specializing in 19th century fiction.'\n" ..
            "• 'Respond concisely. Use bullet points when helpful.'\n\n" ..
            "This replaces the global AI behavior setting for this action."),
        fullscreen = true,
        allow_newline = true,
        buttons = {
            {
                {
                    text = _("← Back"),
                    callback = function()
                        state.behavior_override = dialog:getInputText()
                        UIManager:close(dialog)
                        self:showStep2_Behavior(state)
                    end,
                },
                {
                    text = _("Next →"),
                    callback = function()
                        local custom_behavior = dialog:getInputText()
                        if custom_behavior == "" then
                            UIManager:show(InfoMessage:new{
                                text = _("Please enter custom behavior text, or go back and choose a different option"),
                            })
                            return
                        end
                        state.behavior_override = custom_behavior
                        state.behavior_variant = nil  -- Override takes precedence
                        UIManager:close(dialog)
                        self:showStep3_ActionPrompt(state)
                    end,
                },
            },
        },
    }

    UIManager:show(dialog)
    dialog:onShowKeyboard()
end

-- Step 3: Action Prompt (required, fullscreen with Insert button)
function PromptsManager:showStep3_ActionPrompt(state)
    local is_edit = state.existing_prompt ~= nil

    -- Build description based on context
    local available_placeholders = self:getPlaceholdersForContext(state.context)
    local placeholder_list = ""
    for _, p in ipairs(available_placeholders) do
        placeholder_list = placeholder_list .. "• " .. p.text .. ": " .. p.value .. "\n"
    end

    local dialog
    dialog = InputDialog:new{
        title = is_edit and _("Edit Action - Action Prompt") or _("Step 3/4: Action Prompt"),
        input = state.prompt or "",
        input_hint = _("What should the AI do?"),
        description = _("This is the main instruction sent to the AI. Use placeholders to include context:\n\n") .. placeholder_list .. _("\nTip: Users can add extra input when using this action."),
        fullscreen = true,
        allow_newline = true,
        buttons = {
            {
                {
                    text = _("← Back"),
                    callback = function()
                        state.prompt = dialog:getInputText()
                        UIManager:close(dialog)
                        self:showStep2_Behavior(state)
                    end,
                },
                {
                    text = _("Insert..."),
                    callback = function()
                        state.prompt = dialog:getInputText()
                        UIManager:close(dialog)
                        self:showPlaceholderSelectorWizard(state)
                    end,
                },
                {
                    text = _("Next →"),
                    callback = function()
                        local prompt_text = dialog:getInputText()
                        if prompt_text == "" then
                            UIManager:show(InfoMessage:new{
                                text = _("Action prompt cannot be empty"),
                            })
                            return
                        end
                        state.prompt = prompt_text
                        UIManager:close(dialog)
                        self:showStep4_Advanced(state)
                    end,
                },
            },
        },
    }

    UIManager:show(dialog)
    dialog:onShowKeyboard()
end

-- Step 4: Advanced Settings (temperature, extended thinking)
function PromptsManager:showStep4_Advanced(state)
    local is_edit = state.existing_prompt ~= nil

    -- Get current temperature display
    local temp_display = state.temperature and string.format("%.1f", state.temperature) or _("Global")

    -- Get current extended thinking display
    local thinking_display
    if state.extended_thinking == "on" then
        local budget = state.thinking_budget or 4096
        thinking_display = string.format(_("On (%d tokens)"), budget)
    elseif state.extended_thinking == "off" then
        thinking_display = _("Off")
    else
        thinking_display = _("Global")
    end

    local buttons = {
        -- Row 1: Temperature
        {
            {
                text = _("Temperature: ") .. temp_display,
                callback = function()
                    self:showTemperatureSelector(state)
                end,
            },
        },
        -- Row 2: Extended Thinking
        {
            {
                text = _("Extended Thinking: ") .. thinking_display,
                callback = function()
                    self:showThinkingSelector(state)
                end,
            },
        },
        -- Row 3: Back / Save
        {
            {
                text = _("← Back"),
                callback = function()
                    UIManager:close(self.advanced_dialog)
                    self:showStep3_ActionPrompt(state)
                end,
            },
            {
                text = is_edit and _("Save") or _("Create"),
                callback = function()
                    UIManager:close(self.advanced_dialog)

                    -- Save the action
                    if is_edit then
                        self:updatePrompt(state.existing_prompt, state)
                    else
                        self:addPrompt(state)
                    end

                    -- Refresh prompts menu
                    if self.prompts_menu then
                        UIManager:close(self.prompts_menu)
                    end
                    self:show()
                end,
            },
        },
    }

    local info = _([[Advanced settings for this action.

Temperature: ]] .. temp_display .. [[

  Range 0.0-2.0 (Anthropic max 1.0)
  Lower = focused, Higher = creative

Extended Thinking: ]] .. thinking_display .. [[

  Anthropic-only. Enables complex reasoning.
  Forces temperature to 1.0 when active.]])

    self.advanced_dialog = ButtonDialog:new{
        title = is_edit and _("Edit Action - Advanced") or _("Step 4/4: Advanced Settings"),
        info_text = info,
        buttons = buttons,
    }

    UIManager:show(self.advanced_dialog)
end

-- Temperature selector dialog
function PromptsManager:showTemperatureSelector(state)
    local SpinWidget = require("ui/widget/spinwidget")

    -- Current value or default to 0.7
    local current_temp = state.temperature or 0.7

    -- Build value table for 0.0 to 2.0 in 0.1 increments
    local value_table = {}
    for i = 0, 20 do
        table.insert(value_table, i / 10)
    end

    -- Find current index in table
    local value_index = math.floor(current_temp * 10) + 1
    if value_index < 1 then value_index = 1 end
    if value_index > 21 then value_index = 21 end

    local spin_widget = SpinWidget:new{
        title_text = _("Temperature"),
        info_text = _("Range: 0.0-2.0 (Anthropic max 1.0)\nLower = focused, deterministic\nHigher = creative, varied"),
        value_table = value_table,
        value_index = value_index,
        default_value = 8,  -- Index for 0.7
        extra_text = _("Use global"),
        extra_callback = function()
            state.temperature = nil
            UIManager:close(self.advanced_dialog)
            self:showStep4_Advanced(state)
        end,
        callback = function(spin)
            state.temperature = spin.value
            UIManager:close(self.advanced_dialog)
            self:showStep4_Advanced(state)
        end,
    }

    UIManager:show(spin_widget)
end

-- Extended thinking selector dialog
function PromptsManager:showThinkingSelector(state)
    local buttons = {
        {
            {
                text = _("Use global setting"),
                callback = function()
                    state.extended_thinking = nil
                    state.thinking_budget = nil
                    UIManager:close(self.thinking_dialog)
                    UIManager:close(self.advanced_dialog)
                    self:showStep4_Advanced(state)
                end,
            },
        },
        {
            {
                text = _("Force OFF for this action"),
                callback = function()
                    state.extended_thinking = "off"
                    state.thinking_budget = nil
                    UIManager:close(self.thinking_dialog)
                    UIManager:close(self.advanced_dialog)
                    self:showStep4_Advanced(state)
                end,
            },
        },
        {
            {
                text = _("Force ON..."),
                callback = function()
                    UIManager:close(self.thinking_dialog)
                    self:showThinkingBudgetSelector(state)
                end,
            },
        },
        {
            {
                text = _("Cancel"),
                callback = function()
                    UIManager:close(self.thinking_dialog)
                end,
            },
        },
    }

    self.thinking_dialog = ButtonDialog:new{
        title = _("Extended Thinking"),
        info_text = _([[Extended thinking enables Claude's complex reasoning capability.

• Global: Follow the setting in Settings → Advanced
• Force OFF: Never use thinking for this action
• Force ON: Always use thinking (set budget)

Note: Anthropic/Claude only. Forces temperature to 1.0.]]),
        buttons = buttons,
    }

    UIManager:show(self.thinking_dialog)
end

-- Thinking budget selector
function PromptsManager:showThinkingBudgetSelector(state)
    local SpinWidget = require("ui/widget/spinwidget")

    local current_budget = state.thinking_budget or 4096

    local spin_widget = SpinWidget:new{
        title_text = _("Thinking Budget"),
        info_text = _("Token budget for extended thinking.\nHigher = more complex reasoning.\nRange: 1024 - 32000"),
        value = current_budget,
        value_min = 1024,
        value_max = 32000,
        value_step = 1024,
        default_value = 4096,
        callback = function(spin)
            state.extended_thinking = "on"
            state.thinking_budget = spin.value
            UIManager:close(self.advanced_dialog)
            self:showStep4_Advanced(state)
        end,
    }

    UIManager:show(spin_widget)
end

-- Get placeholders available for a given context
function PromptsManager:getPlaceholdersForContext(context)
    local all_placeholders = {
        { value = "{highlighted_text}", text = _("Selected Text"), contexts = {"highlight", "both", "all"} },
        { value = "{title}", text = _("Book Title"), contexts = {"highlight", "book", "both", "all"} },
        { value = "{author}", text = _("Author Name"), contexts = {"highlight", "book", "both", "all"} },
        { value = "{author_clause}", text = _("Author Clause"), contexts = {"highlight", "book", "both", "all"} },
        { value = "{count}", text = _("Book Count"), contexts = {"multi_book", "all"} },
        { value = "{books_list}", text = _("Books List"), contexts = {"multi_book", "all"} },
    }

    local result = {}
    for _, p in ipairs(all_placeholders) do
        for _, ctx in ipairs(p.contexts) do
            if ctx == context then
                table.insert(result, p)
                break
            end
        end
    end

    -- For general context, show a note
    if context == "general" and #result == 0 then
        table.insert(result, { value = "", text = _("(No placeholders for general context)") })
    end

    return result
end

-- Placeholder selector for wizard
function PromptsManager:showPlaceholderSelectorWizard(state)
    local placeholders = self:getPlaceholdersForContext(state.context)

    local buttons = {}

    for _, placeholder in ipairs(placeholders) do
        if placeholder.value ~= "" then
            table.insert(buttons, {
                {
                    text = placeholder.text .. "  →  " .. placeholder.value,
                    callback = function()
                        UIManager:close(self.placeholder_dialog)
                        -- Append placeholder to action prompt
                        state.prompt = (state.prompt or "") .. placeholder.value
                        self:showStep3_ActionPrompt(state)
                    end,
                },
            })
        end
    end

    table.insert(buttons, {
        {
            text = _("Cancel"),
            callback = function()
                UIManager:close(self.placeholder_dialog)
                self:showStep3_ActionPrompt(state)
            end,
        },
    })

    self.placeholder_dialog = ButtonDialog:new{
        title = _("Insert Placeholder"),
        buttons = buttons,
    }

    UIManager:show(self.placeholder_dialog)
end

function PromptsManager:addPrompt(state)
    local service = self.plugin.action_service
    if service then
        -- Convert empty strings to nil
        local behavior_override = (state.behavior_override and state.behavior_override ~= "") and state.behavior_override or nil

        -- Build api_params if temperature is set
        local api_params = nil
        if state.temperature then
            api_params = { temperature = state.temperature }
        end

        service:addUserAction({
            text = state.name,
            behavior_variant = state.behavior_variant,
            behavior_override = behavior_override,
            prompt = state.prompt,
            context = state.context,
            include_book_context = state.include_book_context or nil,
            domain = state.domain,
            api_params = api_params,
            extended_thinking = state.extended_thinking,  -- nil = global, "off" = force off, "on" = force on
            thinking_budget = state.thinking_budget,      -- only used when extended_thinking = "on"
            enabled = true,
        })

        UIManager:show(InfoMessage:new{
            text = _("Action added successfully"),
        })
    end
end

function PromptsManager:updatePrompt(existing_prompt, state)
    local service = self.plugin.action_service
    if service then
        -- Convert empty strings to nil
        local behavior_override = (state.behavior_override and state.behavior_override ~= "") and state.behavior_override or nil

        -- Build api_params if temperature is set
        local api_params = nil
        if state.temperature then
            api_params = { temperature = state.temperature }
        end

        if existing_prompt.source == "ui" then
            -- Extract index from prompt ID (format: "ui_N")
            local index = nil
            if existing_prompt.id and existing_prompt.id:match("^ui_(%d+)$") then
                index = tonumber(existing_prompt.id:match("^ui_(%d+)$"))
            end

            local prompt_data = {
                text = state.name,
                behavior_variant = state.behavior_variant,
                behavior_override = behavior_override,
                prompt = state.prompt,
                context = state.context,
                include_book_context = state.include_book_context or nil,
                domain = state.domain,
                api_params = api_params,
                extended_thinking = state.extended_thinking,
                thinking_budget = state.thinking_budget,
                enabled = true,
            }

            if index then
                service:updateUserAction(index, prompt_data)
                UIManager:show(InfoMessage:new{
                    text = _("Action updated successfully"),
                })
            else
                -- Fallback: find by original name
                local custom_prompts = self.plugin.settings:readSetting("custom_actions") or {}
                for i, prompt in ipairs(custom_prompts) do
                    if prompt.text == existing_prompt.text then
                        service:updateUserPrompt(i, prompt_data)
                        UIManager:show(InfoMessage:new{
                            text = _("Action updated successfully"),
                        })
                        break
                    end
                end
            end
        elseif existing_prompt.source == "config" then
            -- Prompts from custom_actions.lua cannot be edited via UI
            UIManager:show(InfoMessage:new{
                text = _("This action is defined in custom_actions.lua.\nPlease edit that file directly to modify it."),
            })
        end
    end
end

function PromptsManager:deletePrompt(prompt)
    if self.plugin.action_service and prompt.source == "ui" then
        -- Find the index of this action in custom_actions
        local custom_actions = self.plugin.settings:readSetting("custom_actions") or {}

        for i = #custom_actions, 1, -1 do
            if custom_actions[i].text == prompt.text then
                self.plugin.action_service:deleteUserAction(i)

                UIManager:show(InfoMessage:new{
                    text = _("Action deleted successfully"),
                })
                break
            end
        end
    end
end

function PromptsManager:getContextDisplayName(context)
    if context == "highlight" then
        return _("Highlight")
    elseif context == "book" then
        return _("Book (File Browser)")
    elseif context == "multi_book" then
        return _("Multi-Book")
    elseif context == "general" then
        return _("General")
    elseif context == "both" then
        return _("Highlight & Book")
    elseif context == "highlight+general" then
        return _("Highlight & General")
    elseif context == "book+general" then
        return _("Book & General")
    elseif context == "all" then
        return _("All Contexts")
    else
        return context
    end
end

return PromptsManager