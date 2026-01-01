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
local Screen = require("device").screen

local PromptsManager = {}

function PromptsManager:new(plugin)
    local o = {
        plugin = plugin,
        width = Screen:getWidth(),
        height = Screen:getHeight(),
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
    
    if not self.plugin.prompt_service then
        logger.warn("PromptsManager: PromptService not available")
        return
    end
    
    -- Load all prompts from all contexts
    local highlight_prompts = self.plugin.prompt_service:getAllPrompts("highlight", true)
    local book_prompts = self.plugin.prompt_service:getAllPrompts("book", true)
    local multi_book_prompts = self.plugin.prompt_service:getAllPrompts("multi_book", true)
    local general_prompts = self.plugin.prompt_service:getAllPrompts("general", true)
    
    -- Add highlight prompts
    for _, prompt in ipairs(highlight_prompts) do
        table.insert(self.prompts, {
            text = prompt.text,
            system_prompt = prompt.system_prompt,
            user_prompt = prompt.user_prompt,
            context = "highlight",
            source = prompt.source,
            enabled = prompt.enabled,
            requires = prompt.requires,
            id = prompt.id,
            include_book_context = prompt.include_book_context,
        })
    end
    
    -- Add book prompts (avoid duplicates for "both" context)
    for _, prompt in ipairs(book_prompts) do
        -- Check if this prompt already exists in highlight context
        local exists = false
        for _, existing in ipairs(self.prompts) do
            if existing.text == prompt.text and existing.source == prompt.source then
                -- Change context to "both"
                existing.context = "both"
                exists = true
                break
            end
        end
        
        if not exists then
            table.insert(self.prompts, {
                text = prompt.text,
                system_prompt = prompt.system_prompt,
                user_prompt = prompt.user_prompt,
                context = "book",
                source = prompt.source,
                enabled = prompt.enabled,
                requires = prompt.requires,
                id = prompt.id,
            })
        end
    end
    
    -- Add multi-book prompts
    for _, prompt in ipairs(multi_book_prompts) do
        table.insert(self.prompts, {
            text = prompt.text,
            system_prompt = prompt.system_prompt,
            user_prompt = prompt.user_prompt,
            context = "multi_book",
            source = prompt.source,
            enabled = prompt.enabled,
            requires = prompt.requires,
            id = prompt.id,
        })
    end
    
    -- Add general prompts
    for _, prompt in ipairs(general_prompts) do
        -- Check if this prompt already exists in other contexts
        local exists = false
        for _, existing in ipairs(self.prompts) do
            if existing.text == prompt.text and existing.source == prompt.source then
                -- Update context to include general
                if existing.context == "highlight" then
                    existing.context = "highlight+general"
                elseif existing.context == "book" then
                    existing.context = "book+general"
                elseif existing.context == "both" then
                    existing.context = "all"
                end
                exists = true
                break
            end
        end
        
        if not exists then
            table.insert(self.prompts, {
                text = prompt.text,
                system_prompt = prompt.system_prompt,
                user_prompt = prompt.user_prompt,
                context = "general",
                source = prompt.source,
                enabled = prompt.enabled,
                requires = prompt.requires,
                id = prompt.id,
            })
        end
    end
    
    logger.info("PromptsManager: Total prompts loaded: " .. #self.prompts)
end

function PromptsManager:setPromptEnabled(prompt_text, context, enabled)
    if self.plugin.prompt_service then
        self.plugin.prompt_service:setPromptEnabled(context, prompt_text, enabled)
    end
end

function PromptsManager:showPromptsMenu()
    local menu_items = {}
    
    -- Add help text at the top
    table.insert(menu_items, {
        text = _("Tap to toggle • Hold for details"),
        dim = true,
        enabled = false,
    })
    
    -- Add "Add New Prompt" item
    table.insert(menu_items, {
        text = _("+ Add New Prompt"),
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
                
                -- Add source indicator for user prompts
                if prompt.source == "user" then
                    item_text = item_text .. " ✏"
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
                        text = _("This will remove all custom prompts and reset all prompt settings. Continue?"),
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
        title = _("Manage Prompts"),
        item_table = menu_items,
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
        source_text = _("Custom (custom_prompts.lua)")
    elseif prompt.source == "ui" then
        source_text = _("User-defined (UI)")
    else
        source_text = prompt.source or _("Unknown")
    end
    
    local info_text = string.format(
        "%s\n\n%s: %s\n%s: %s\n%s: %s\n\n%s:\n%s\n\n%s:\n%s",
        prompt.text,
        _("Context"), self:getContextDisplayName(prompt.context),
        _("Source"), source_text,
        _("Status"), prompt.enabled and _("Enabled") or _("Disabled"),
        _("System Prompt"),
        prompt.system_prompt or _("(None)"),
        _("User Prompt"),
        prompt.user_prompt or _("(None)")
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
                        text = _("Delete this prompt?"),
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
                        text = _("This prompt is defined in custom_prompts.lua.\nPlease edit that file directly to modify it."),
                    })
                end,
            },
        })
    end

    self.details_dialog = TextViewer:new{
        title = _("Prompt Details"),
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
    -- For new prompts, default include_book_context to true (recommended)
    local state = {
        name = existing_prompt and existing_prompt.text or "",
        system_prompt = existing_prompt and existing_prompt.system_prompt or "",
        user_prompt = existing_prompt and existing_prompt.user_prompt or "",
        context = existing_prompt and existing_prompt.context or nil,
        include_book_context = existing_prompt and existing_prompt.include_book_context or (not existing_prompt and true) or false,
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
                self:showStep2_SystemPrompt(state)
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
        title = is_edit and _("Edit Prompt - Name") or _("Step 1/3: Name & Context"),
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
        -- Show context name, description, and what data is included
        local button_text = prefix .. info.text .. "\n   " .. info.desc
        if info.includes then
            button_text = button_text .. "\n   " .. info.includes
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

-- Step 2: System prompt (optional, fullscreen)
function PromptsManager:showStep2_SystemPrompt(state)
    local is_edit = state.existing_prompt ~= nil

    -- Get context info and default prompt
    local context_info = self:getContextInfo(state.context)
    local default_prompt = self:getDefaultSystemPrompt(state.context)

    local description, input_hint

    if default_prompt then
        -- Single context - show the specific default and what data is auto-included
        local context_data_note = ""
        if state.context == "book" then
            context_data_note = _("\n\nNote: Book title and author are automatically sent to the AI.")
        elseif state.context == "multi_book" then
            context_data_note = _("\n\nNote: The list of selected books is automatically sent to the AI.")
        elseif state.context == "highlight" then
            if state.include_book_context then
                context_data_note = _("\n\nNote: Selected text + book info are automatically sent to the AI.")
            else
                context_data_note = _("\n\nNote: Selected text is automatically sent to the AI.")
            end
        end

        description = string.format(
            _("Leave empty to use the context default.\n\n" ..
              "Examples:\n" ..
              "• 'You are an expert literary critic.'\n" ..
              "• 'Respond simply, as if explaining to a child.'\n" ..
              "• 'Be concise. Use bullet points.'")) .. context_data_note
        -- Show the default prompt as gray hint text in the input field
        input_hint = default_prompt
    else
        -- Compound context (both, all) - default varies by trigger
        description = string.format(
            _("For '%s', the default system prompt varies depending on how the prompt is triggered:\n" ..
              "• From highlight: reading assistant prompt\n" ..
              "• From book: book assistant prompt\n" ..
              "• From multi-book: comparison prompt\n" ..
              "• From general: general assistant prompt\n\n" ..
              "Leave empty to use these context-specific defaults, or write your own."),
            context_info.text)
        input_hint = _("Leave empty for context-specific defaults")
    end

    local dialog
    dialog = InputDialog:new{
        title = is_edit and _("Edit Prompt - System Instructions") or _("Step 2/3: System Instructions"),
        input = state.system_prompt or "",
        input_hint = input_hint,
        description = description,
        fullscreen = true,
        allow_newline = true,
        buttons = {
            {
                {
                    text = _("← Back"),
                    callback = function()
                        state.system_prompt = dialog:getInputText()
                        UIManager:close(dialog)
                        self:showStep1_NameAndContext(state)
                    end,
                },
                {
                    text = _("Skip (use default)"),
                    callback = function()
                        state.system_prompt = ""
                        UIManager:close(dialog)
                        self:showStep3_UserPrompt(state)
                    end,
                },
                {
                    text = _("Next →"),
                    callback = function()
                        state.system_prompt = dialog:getInputText()
                        UIManager:close(dialog)
                        self:showStep3_UserPrompt(state)
                    end,
                },
            },
        },
    }

    UIManager:show(dialog)
    dialog:onShowKeyboard()
end

-- Step 3: User prompt (required, fullscreen with Insert button)
function PromptsManager:showStep3_UserPrompt(state)
    local is_edit = state.existing_prompt ~= nil

    -- Build description based on context
    local available_placeholders = self:getPlaceholdersForContext(state.context)
    local placeholder_list = ""
    for _, p in ipairs(available_placeholders) do
        placeholder_list = placeholder_list .. "• " .. p.text .. ": " .. p.value .. "\n"
    end

    local dialog
    dialog = InputDialog:new{
        title = is_edit and _("Edit Prompt - User Prompt") or _("Step 3/3: User Prompt"),
        input = state.user_prompt or "",
        input_hint = _("What should be sent to the AI?"),
        description = _("Write your prompt here. Use placeholders to include context data:\n\n") .. placeholder_list,
        fullscreen = true,
        allow_newline = true,
        buttons = {
            {
                {
                    text = _("← Back"),
                    callback = function()
                        state.user_prompt = dialog:getInputText()
                        UIManager:close(dialog)
                        self:showStep2_SystemPrompt(state)
                    end,
                },
                {
                    text = _("Insert..."),
                    callback = function()
                        state.user_prompt = dialog:getInputText()
                        UIManager:close(dialog)
                        self:showPlaceholderSelectorWizard(state)
                    end,
                },
                {
                    text = is_edit and _("Save") or _("Create"),
                    callback = function()
                        local user_prompt = dialog:getInputText()
                        if user_prompt == "" then
                            UIManager:show(InfoMessage:new{
                                text = _("User prompt cannot be empty"),
                            })
                            return
                        end
                        state.user_prompt = user_prompt
                        UIManager:close(dialog)

                        -- Save the prompt
                        if is_edit then
                            self:updatePrompt(state.existing_prompt, state.name, state.system_prompt, state.user_prompt, state.context, state.include_book_context)
                        else
                            self:addPrompt(state.name, state.system_prompt, state.user_prompt, state.context, state.include_book_context)
                        end

                        -- Refresh prompts menu
                        if self.prompts_menu then
                            UIManager:close(self.prompts_menu)
                        end
                        self:show()
                    end,
                },
            },
        },
    }

    UIManager:show(dialog)
    dialog:onShowKeyboard()
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
                        -- Append placeholder to user prompt
                        state.user_prompt = (state.user_prompt or "") .. placeholder.value
                        self:showStep3_UserPrompt(state)
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
                self:showStep3_UserPrompt(state)
            end,
        },
    })

    self.placeholder_dialog = ButtonDialog:new{
        title = _("Insert Placeholder"),
        buttons = buttons,
    }

    UIManager:show(self.placeholder_dialog)
end

function PromptsManager:addPrompt(name, system_prompt, user_prompt, context, include_book_context)
    if self.plugin.prompt_service then
        -- Convert empty strings to nil so fallback system prompts work
        local sys_prompt = (system_prompt and system_prompt ~= "") and system_prompt or nil

        self.plugin.prompt_service:addUserPrompt({
            text = name,
            system_prompt = sys_prompt,
            user_prompt = user_prompt,
            context = context,
            include_book_context = include_book_context or nil,  -- Only store if true
            enabled = true,
        })

        UIManager:show(InfoMessage:new{
            text = _("Prompt added successfully"),
        })
    end
end

function PromptsManager:updatePrompt(existing_prompt, name, system_prompt, user_prompt, context, include_book_context)
    if self.plugin.prompt_service then
        -- Convert empty strings to nil so fallback system prompts work
        local sys_prompt = (system_prompt and system_prompt ~= "") and system_prompt or nil

        if existing_prompt.source == "ui" then
            -- Extract index from prompt ID (format: "ui_N")
            local index = nil
            if existing_prompt.id and existing_prompt.id:match("^ui_(%d+)$") then
                index = tonumber(existing_prompt.id:match("^ui_(%d+)$"))
            end

            if index then
                self.plugin.prompt_service:updateUserPrompt(index, {
                    text = name,
                    system_prompt = sys_prompt,
                    user_prompt = user_prompt,
                    context = context,
                    include_book_context = include_book_context or nil,  -- Only store if true
                    enabled = true,
                })

                UIManager:show(InfoMessage:new{
                    text = _("Prompt updated successfully"),
                })
            else
                -- Fallback: find by original name
                local custom_prompts = self.plugin.settings:readSetting("custom_prompts") or {}
                for i, prompt in ipairs(custom_prompts) do
                    if prompt.text == existing_prompt.text then
                        self.plugin.prompt_service:updateUserPrompt(i, {
                            text = name,
                            system_prompt = sys_prompt,
                            user_prompt = user_prompt,
                            context = context,
                            include_book_context = include_book_context or nil,  -- Only store if true
                            enabled = true,
                        })

                        UIManager:show(InfoMessage:new{
                            text = _("Prompt updated successfully"),
                        })
                        break
                    end
                end
            end
        elseif existing_prompt.source == "config" then
            -- Prompts from custom_prompts.lua cannot be edited via UI
            UIManager:show(InfoMessage:new{
                text = _("This prompt is defined in custom_prompts.lua.\nPlease edit that file directly to modify it."),
            })
        end
    end
end

function PromptsManager:deletePrompt(prompt)
    if self.plugin.prompt_service and prompt.source == "ui" then
        -- Find the index of this prompt in custom_prompts
        local custom_prompts = self.plugin.settings:readSetting("custom_prompts") or {}
        
        for i = #custom_prompts, 1, -1 do
            if custom_prompts[i].text == prompt.text then
                self.plugin.prompt_service:deleteUserPrompt(i)
                
                UIManager:show(InfoMessage:new{
                    text = _("Prompt deleted successfully"),
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