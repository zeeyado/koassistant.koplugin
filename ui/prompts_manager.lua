local _ = require("koassistant_gettext")
local logger = require("logger")
local DataStorage = require("datastorage")
local UIManager = require("ui/uimanager")
local Menu = require("ui/widget/menu")
local InfoMessage = require("ui/widget/infomessage")
local Notification = require("ui/widget/notification")
local ConfirmBox = require("ui/widget/confirmbox")
local InputDialog = require("ui/widget/inputdialog")
local ButtonDialog = require("ui/widget/buttondialog")
local TextViewer = require("ui/widget/textviewer")
local UIConstants = require("ui/constants")
local ModelConstraints = require("model_constraints")
local SystemPrompts = require("prompts/system_prompts")

local PromptsManager = {}

-- Helper: Get built-in behavior options for action editing
-- Returns array of { id, text, desc } for radio button display
local function getBuiltinBehaviorOptions()
    local options = {}
    local builtin_behaviors = SystemPrompts.getSortedBehaviors(nil)  -- Only built-ins, no custom

    for _idx,behavior in ipairs(builtin_behaviors) do
        if behavior.source == "builtin" then
            -- Estimate tokens from text length (rough: chars/4)
            local tokens = behavior.text and math.floor(#behavior.text / 4) or 0
            table.insert(options, {
                id = behavior.id,
                text = behavior.name,
                desc = string.format(_("~%d tokens"), tokens),
            })
        end
    end

    return options
end

-- Helper: Check if a behavior_variant is a known built-in
local function isBuiltinBehavior(variant)
    if not variant then return false end
    local behavior = SystemPrompts.getBehaviorById(variant, nil)
    return behavior and behavior.source == "builtin"
end

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

-- Helper: Get display text for reasoning config (handles both legacy and new format)
-- Works with both action prompts and edit state objects
function PromptsManager:getReasoningDisplayText(obj)
    -- New format: reasoning_config
    if obj.reasoning_config ~= nil then
        if obj.reasoning_config == "off" then
            return _("Force OFF")
        elseif type(obj.reasoning_config) == "table" then
            -- Per-provider config
            local parts = {}
            if obj.reasoning_config.anthropic then
                if type(obj.reasoning_config.anthropic) == "table" and obj.reasoning_config.anthropic.budget then
                    table.insert(parts, string.format("A:%d", obj.reasoning_config.anthropic.budget))
                end
            end
            if obj.reasoning_config.openai then
                if type(obj.reasoning_config.openai) == "table" and obj.reasoning_config.openai.effort then
                    table.insert(parts, "O:" .. obj.reasoning_config.openai.effort:sub(1,1):upper())
                end
            end
            if obj.reasoning_config.gemini then
                if type(obj.reasoning_config.gemini) == "table" and obj.reasoning_config.gemini.level then
                    table.insert(parts, "G:" .. obj.reasoning_config.gemini.level:sub(1,1):upper())
                end
            end
            if #parts > 0 then
                return table.concat(parts, ", ")
            end
            return _("Configured")
        end
    end

    -- Legacy format: extended_thinking
    if obj.extended_thinking == "on" then
        local budget = obj.thinking_budget or ModelConstraints.reasoning_defaults.anthropic.budget
        return string.format(_("On (%d tokens)"), budget)
    elseif obj.extended_thinking == "off" then
        return _("Force OFF")
    end

    return _("Global")
end

-- Alias for backward compatibility (same function, different name)
function PromptsManager:getStateReasoningDisplayText(state)
    return self:getReasoningDisplayText(state)
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

    -- Load builtin action overrides
    local builtin_overrides = self.plugin.settings:readSetting("builtin_action_overrides") or {}

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

        -- Resolve template to prompt text if needed (for built-in actions)
        local prompt_text = prompt.prompt
        if not prompt_text and prompt.template then
            local ok, Templates = pcall(require, "prompts/templates")
            if ok and Templates and Templates.get then
                prompt_text = Templates.get(prompt.template)
            end
        end

        -- Build the entry
        local entry = {
            text = prompt.text,
            behavior_variant = prompt.behavior_variant,
            behavior_override = prompt.behavior_override,
            prompt = prompt_text,
            context = context,
            source = prompt.source,
            enabled = prompt.enabled,
            requires = prompt.requires,
            id = prompt.id,
            include_book_context = prompt.include_book_context,
            skip_language_instruction = prompt.skip_language_instruction,
            temperature = temperature,
            extended_thinking = prompt.extended_thinking,
            thinking_budget = prompt.thinking_budget,
            reasoning_config = prompt.reasoning_config,
            provider = prompt.provider,
            model = prompt.model,
            has_override = false,
        }

        -- Apply builtin action overrides if this is a builtin action
        if prompt.source == "builtin" and prompt.id then
            local override_key = context_override .. ":" .. prompt.id
            local override = builtin_overrides[override_key]
            if override then
                entry.has_override = true
                -- Merge override fields
                if override.temperature then entry.temperature = override.temperature end
                if override.extended_thinking then entry.extended_thinking = override.extended_thinking end
                if override.thinking_budget then entry.thinking_budget = override.thinking_budget end
                if override.provider then entry.provider = override.provider end
                if override.model then entry.model = override.model end
                if override.behavior_variant then entry.behavior_variant = override.behavior_variant end
                if override.behavior_override then entry.behavior_override = override.behavior_override end
                if override.reasoning_config then entry.reasoning_config = override.reasoning_config end
                if override.skip_language_instruction ~= nil then entry.skip_language_instruction = override.skip_language_instruction end
            end
        end

        return entry
    end

    -- Track seen prompts to avoid duplicates from compound contexts
    local seen = {}

    -- Add highlight prompts
    for _idx,prompt in ipairs(highlight_prompts) do
        local key = prompt.text .. "|" .. (prompt.source or "")
        if not seen[key] then
            table.insert(self.prompts, addPromptEntry(prompt, "highlight"))
            seen[key] = true
        end
    end

    -- Add book prompts (avoid duplicates for "both" context)
    for _idx,prompt in ipairs(book_prompts) do
        local key = prompt.text .. "|" .. (prompt.source or "")
        if not seen[key] then
            -- Check if this prompt already exists in highlight context
            local exists = false
            for _idx,existing in ipairs(self.prompts) do
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
    for _idx,prompt in ipairs(multi_book_prompts) do
        local key = prompt.text .. "|" .. (prompt.source or "")
        if not seen[key] then
            table.insert(self.prompts, addPromptEntry(prompt, "multi_book"))
            seen[key] = true
        end
    end

    -- Add general prompts
    for _idx,prompt in ipairs(general_prompts) do
        local key = prompt.text .. "|" .. (prompt.source or "")
        if not seen[key] then
            -- Check if this prompt already exists in other contexts
            local exists = false
            for _idx,existing in ipairs(self.prompts) do
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

function PromptsManager:setPromptEnabled(action_id, context, enabled)
    if self.plugin.action_service then
        self.plugin.action_service:setActionEnabled(context, action_id, enabled)
    end
end

function PromptsManager:showPromptsMenu()
    local menu_items = {}
    
    -- Add help text at the top
    table.insert(menu_items, {
        text = _("Tap to toggle • Hold for details • ★ = custom • ⚙ = modified"),
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
    
    for _idx,context_info in ipairs(contexts) do
        local context_prompts = {}
        for _idx,prompt in ipairs(self.prompts) do
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
            for _idx,prompt in ipairs(context_prompts) do
                local item_text = prompt.text

                -- Add source indicator
                -- ★ = custom action (UI-created or from file)
                -- ⚙ = built-in action with user overrides
                if prompt.source == "ui" then
                    item_text = "★ " .. item_text
                elseif prompt.source == "config" then
                    item_text = "★ " .. item_text .. " (file)"
                elseif prompt.source == "builtin" and prompt.has_override then
                    item_text = "⚙ " .. item_text
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
                        -- Toggle enabled state (use prompt.id, not prompt.text)
                        self:setPromptEnabled(prompt.id, prompt.context, not prompt.enabled)
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
    -- Close and reopen the menu to refresh it, preserving the current page
    if self.prompts_menu then
        local menu = self.prompts_menu
        -- Save current page before closing
        local current_page = menu.page
        UIManager:close(menu)
        -- Schedule reopening after close
        UIManager:scheduleIn(0.1, function()
            self:show()
            -- Restore page after menu is shown
            if self.prompts_menu and current_page and current_page > 1 then
                self.prompts_menu:onGotoPage(current_page)
            end
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
        -- Look up the behavior name from built-ins
        local behavior = SystemPrompts.getBehaviorById(prompt.behavior_variant, nil)
        if behavior then
            behavior_text = behavior.name
        else
            behavior_text = prompt.behavior_variant  -- Fallback to ID
        end
    else
        behavior_text = _("(Use global setting)")
    end

    -- Temperature display
    local temp_text = prompt.temperature and string.format("%.1f", prompt.temperature) or _("Global")

    -- Reasoning display (handles both legacy and new format)
    local thinking_text = self:getReasoningDisplayText(prompt)

    -- Provider/model display
    local provider_text = prompt.provider or _("Global")
    local model_text = prompt.model or _("Global")

    local info_text = string.format(
        "%s\n\n%s: %s\n%s: %s\n%s: %s\n%s: %s\n%s: %s\n%s: %s / %s\n\n%s:\n%s\n\n%s:\n%s",
        prompt.text,
        _("Context"), self:getContextDisplayName(prompt.context),
        _("Source"), source_text,
        _("Status"), prompt.enabled and _("Enabled") or _("Disabled"),
        _("Temperature"), temp_text,
        _("Reasoning"), thinking_text,
        _("Provider/Model"), provider_text, model_text,
        _("AI Behavior"),
        behavior_text,
        _("Action Prompt"),
        prompt.prompt or _("(None)")
    )

    -- Show include_book_context for highlight-related contexts
    if prompt.context == "highlight" or prompt.context == "both" or prompt.context == "all" then
        local book_context_text = prompt.include_book_context and _("Yes") or _("No")
        info_text = info_text .. "\n\n" .. _("Include Book Info") .. ": " .. book_context_text
    end

    -- Show skip_language_instruction (always show for visibility)
    local skip_lang_text = prompt.skip_language_instruction and _("Yes") or _("No")
    info_text = info_text .. "\n" .. _("Skip Language Instruction") .. ": " .. skip_lang_text

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
    elseif prompt.source == "builtin" then
        -- Built-in actions - allow editing settings (not the prompt itself)
        local button_row = {
            {
                text = _("Edit Settings"),
                callback = function()
                    if self.details_dialog then
                        UIManager:close(self.details_dialog)
                    end
                    self:showBuiltinSettingsEditor(prompt)
                end,
            },
        }
        -- Add Reset button if there are overrides
        if prompt.has_override then
            table.insert(button_row, {
                text = _("Reset to Default"),
                callback = function()
                    UIManager:show(ConfirmBox:new{
                        text = _("Reset this action to default settings?"),
                        ok_callback = function()
                            self:resetBuiltinOverride(prompt)
                            if self.details_dialog then
                                UIManager:close(self.details_dialog)
                            end
                            self:refreshMenu()
                        end,
                    })
                end,
            })
        end
        table.insert(buttons, button_row)
    end

    -- Add highlight menu toggle for highlight-context actions that don't require input
    local is_highlight_context = prompt.context == "highlight" or prompt.context == "both" or prompt.context == "all"
    local requires_input = prompt.id == "ask" or (prompt.prompt and prompt.prompt:find("{user_input}"))
    if is_highlight_context and not requires_input and self.plugin.action_service then
        local in_menu = self.plugin.action_service:isInHighlightMenu(prompt.id)
        table.insert(buttons, {
            {
                text = in_menu and _("✓ In Highlight Menu") or _("Add to Highlight Menu"),
                callback = function()
                    local now_in_menu = self.plugin.action_service:toggleHighlightMenuAction(prompt.id)
                    UIManager:close(self.details_dialog)
                    UIManager:show(InfoMessage:new{
                        text = now_in_menu and _("Added to highlight menu.") or _("Removed from highlight menu."),
                        timeout = 2,
                    })
                end,
            },
        })
    end

    -- Add dictionary popup toggle for highlight-context actions that don't require input
    if is_highlight_context and not requires_input and self.plugin.action_service then
        local in_popup = self.plugin.action_service:isInDictionaryPopup(prompt.id)
        table.insert(buttons, {
            {
                text = in_popup and _("✓ In Dictionary Popup") or _("Add to Dictionary Popup"),
                callback = function()
                    local now_in_popup = self.plugin.action_service:toggleDictionaryPopupAction(prompt.id)
                    UIManager:close(self.details_dialog)
                    UIManager:show(InfoMessage:new{
                        text = now_in_popup and _("Added to dictionary popup.") or _("Removed from dictionary popup."),
                        timeout = 2,
                    })
                end,
            },
        })
    end

    -- Add "Duplicate as Custom" button for all action types
    if self.plugin.action_service then
        table.insert(buttons, {
            {
                text = _("Duplicate as Custom"),
                callback = function()
                    UIManager:close(self.details_dialog)
                    self:duplicateAction(prompt)
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

-- Duplicate an action and save immediately as a new custom action
function PromptsManager:duplicateAction(action)
    if not self.plugin.action_service then
        UIManager:show(InfoMessage:new{
            text = _("Action service not available."),
        })
        return
    end

    -- Get duplicate data from action service
    local duplicate = self.plugin.action_service:createDuplicateAction(action)

    -- Build action data for saving
    local action_data = {
        text = duplicate.text,
        context = duplicate.context,
        prompt = duplicate.prompt or "",
        behavior_variant = duplicate.behavior_variant,
        behavior_override = duplicate.behavior_override,
        include_book_context = duplicate.include_book_context,
        skip_language_instruction = duplicate.skip_language_instruction,
        reasoning_config = duplicate.reasoning_config,
        extended_thinking = duplicate.extended_thinking,
        thinking_budget = duplicate.thinking_budget,
        provider = duplicate.provider,
        model = duplicate.model,
    }

    -- Add temperature if set
    if duplicate.temperature then
        action_data.api_params = action_data.api_params or {}
        action_data.api_params.temperature = duplicate.temperature
    end

    -- Save immediately as a new custom action (will have star icon as source = "ui")
    self.plugin.action_service:addUserAction(action_data)

    -- Close the prompts menu if open
    if self.prompts_menu then
        UIManager:close(self.prompts_menu)
    end

    -- Show success notification
    UIManager:show(InfoMessage:new{
        text = string.format(_("Created: %s\n\nYou can find and edit it in the Actions list."), duplicate.text),
        timeout = 2,
    })

    -- Refresh the actions list after a delay (must reload prompts first!)
    UIManager:scheduleIn(0.3, function()
        self:loadPrompts()  -- Reload prompts from action_service
        self:showPromptsMenu()
    end)
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
        skip_language_instruction = existing_prompt and existing_prompt.skip_language_instruction or false,
        domain = existing_prompt and existing_prompt.domain or nil,
        temperature = existing_prompt and existing_prompt.temperature or nil,  -- nil = use global
        -- New format: reasoning_config (nil = global, "off" = force off, table = per-provider)
        reasoning_config = existing_prompt and existing_prompt.reasoning_config or nil,
        -- Legacy format (for backward compatibility)
        extended_thinking = existing_prompt and existing_prompt.extended_thinking or nil,
        thinking_budget = existing_prompt and existing_prompt.thinking_budget or nil,
        provider = existing_prompt and existing_prompt.provider or nil,  -- nil = use global
        model = existing_prompt and existing_prompt.model or nil,  -- nil = use global
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

    -- Row 3: Skip language instruction toggle
    local lang_checkbox = state.skip_language_instruction and "☑ " or "☐ "
    table.insert(button_rows, {
        {
            text = lang_checkbox .. _("Skip language instruction"),
            callback = function()
                state.name = self.step1_dialog:getInputText()
                state.skip_language_instruction = not state.skip_language_instruction
                UIManager:close(self.step1_dialog)
                self:showStep1_NameAndContext(state)
            end,
        },
    })

    -- Row 4: Add to Highlight Menu toggle (only for highlight-compatible contexts)
    if state.context and self:contextIncludesHighlight(state.context) then
        local highlight_checkbox = state.add_to_highlight_menu and "☑ " or "☐ "
        table.insert(button_rows, {
            {
                text = highlight_checkbox .. _("Add to Highlight Menu"),
                callback = function()
                    state.name = self.step1_dialog:getInputText()
                    state.add_to_highlight_menu = not state.add_to_highlight_menu
                    UIManager:close(self.step1_dialog)
                    self:showStep1_NameAndContext(state)
                end,
            },
        })
    end

    -- Row 5: Add to Dictionary Popup toggle (only for highlight-compatible contexts)
    if state.context and self:contextIncludesHighlight(state.context) then
        local dict_checkbox = state.add_to_dictionary_popup and "☑ " or "☐ "
        table.insert(button_rows, {
            {
                text = dict_checkbox .. _("Add to Dictionary Popup"),
                callback = function()
                    state.name = self.step1_dialog:getInputText()
                    state.add_to_dictionary_popup = not state.add_to_dictionary_popup
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
            includes = _("Available: translation language"),
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

    for _idx,option in ipairs(context_options) do
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
    elseif isBuiltinBehavior(state.behavior_variant) then
        current_selection = state.behavior_variant
    end

    -- Build behavior options dynamically from built-in behaviors
    local behavior_options = {
        { id = "global", text = _("Use global setting"), desc = _("Inherits from Settings → Advanced → AI Behavior Style") },
    }

    -- Add all built-in behaviors
    local builtin_options = getBuiltinBehaviorOptions()
    for _idx,opt in ipairs(builtin_options) do
        table.insert(behavior_options, opt)
    end

    -- Add none and custom options
    table.insert(behavior_options, { id = "none", text = _("None"), desc = _("No behavior instructions - just your action prompt") })
    table.insert(behavior_options, { id = "custom", text = _("Custom..."), desc = _("Define your own AI personality/role") })

    local buttons = {}

    for _idx,option in ipairs(behavior_options) do
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
            text = _("Next →"),
            callback = function()
                -- Preserve current state (don't reset to global)
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
    for _idx,p in ipairs(available_placeholders) do
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

-- Step 4: Advanced Settings (temperature, extended thinking, provider/model)
function PromptsManager:showStep4_Advanced(state)
    local is_edit = state.existing_prompt ~= nil

    -- Get current temperature display
    local temp_display = state.temperature and string.format("%.1f", state.temperature) or _("Global")

    -- Get current reasoning display (handles both legacy and new format)
    local thinking_display = self:getStateReasoningDisplayText(state)

    -- Get current provider/model display
    local provider_display = state.provider or _("Global")
    local model_display = state.model or _("Global")

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
        -- Row 2: Reasoning/Thinking
        {
            {
                text = _("Reasoning: ") .. thinking_display,
                callback = function()
                    self:showThinkingSelector(state)
                end,
            },
        },
        -- Row 3: Provider/Model
        {
            {
                text = _("Provider: ") .. provider_display,
                callback = function()
                    self:showProviderSelector(state)
                end,
            },
            {
                text = _("Model: ") .. model_display,
                callback = function()
                    if not state.provider then
                        UIManager:show(InfoMessage:new{
                            text = _("Please select a provider first"),
                        })
                        return
                    end
                    self:showModelSelector(state)
                end,
            },
        },
        -- Row 4: Back / Save
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

Reasoning: ]] .. thinking_display .. [[

  Anthropic/OpenAI/Gemini. May force temp to 1.0.

Provider/Model: ]] .. provider_display .. " / " .. model_display .. [[

  Override global provider/model for this action.]])

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
-- @param state: Action state being edited
-- @param refresh_callback: Optional callback to refresh the parent dialog (for builtin actions)
function PromptsManager:showThinkingSelector(state, refresh_callback)
    -- Determine refresh behavior
    local function refreshParent()
        if refresh_callback then
            refresh_callback()
        elseif state.prompt and state.prompt.source then
            -- Builtin action: has prompt reference with source field
            UIManager:close(self.builtin_settings_dialog)
            self:showBuiltinSettingsDialog(state)
        else
            -- Custom action wizard: refresh step 4
            UIManager:close(self.advanced_dialog)
            self:showStep4_Advanced(state)
        end
    end

    local buttons = {
        {
            {
                text = _("Use global setting"),
                callback = function()
                    state.reasoning_config = nil  -- Use per-provider global settings
                    UIManager:close(self.thinking_dialog)
                    refreshParent()
                end,
            },
        },
        {
            {
                text = _("Force OFF for all providers"),
                callback = function()
                    state.reasoning_config = "off"  -- Disable for all
                    UIManager:close(self.thinking_dialog)
                    refreshParent()
                end,
            },
        },
        {
            {
                text = _("Configure per-provider..."),
                callback = function()
                    UIManager:close(self.thinking_dialog)
                    self:showPerProviderReasoningMenu(state, refresh_callback)
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
        title = _("Reasoning/Thinking"),
        info_text = _([[Reasoning enables complex thinking for supported models.

• Global: Follow per-provider settings in Settings menu
• Force OFF: Never use thinking for this action
• Configure: Set per-provider reasoning (Anthropic budget, OpenAI effort, Gemini level)

May force temperature to 1.0 for some models.]]),
        buttons = buttons,
    }

    UIManager:show(self.thinking_dialog)
end

-- Per-provider reasoning configuration menu
-- @param state: Action state being edited
-- @param refresh_callback: Optional callback to refresh the parent dialog
function PromptsManager:showPerProviderReasoningMenu(state, refresh_callback)
    -- Store refresh callback in state for use by sub-dialogs
    state._refresh_callback = refresh_callback

    -- Initialize reasoning_config if needed
    if type(state.reasoning_config) ~= "table" then
        state.reasoning_config = {
            anthropic = nil,  -- nil = use global, false = off, { budget = N } = on
            openai = nil,     -- nil = use global, false = off, { effort = "..." } = on
            gemini = nil,     -- nil = use global, false = off, { level = "..." } = on
        }
    end

    local function getStatusText(provider)
        local cfg = state.reasoning_config[provider]
        if cfg == nil then return _("(global)") end
        if cfg == false then return _("OFF") end
        if provider == "anthropic" and cfg.budget then
            return string.format(_("ON (%d tokens)"), cfg.budget)
        elseif provider == "openai" and cfg.effort then
            return _("ON (") .. cfg.effort .. ")"
        elseif provider == "gemini" and cfg.level then
            return _("ON (") .. cfg.level .. ")"
        end
        return _("ON")
    end

    -- Determine refresh behavior for Done button
    local function refreshParent()
        if refresh_callback then
            refresh_callback()
        elseif state.prompt and state.prompt.source then
            -- Builtin action: has prompt reference with source field
            UIManager:close(self.builtin_settings_dialog)
            self:showBuiltinSettingsDialog(state)
        else
            -- Custom action wizard: refresh step 4
            UIManager:close(self.advanced_dialog)
            self:showStep4_Advanced(state)
        end
    end

    local buttons = {
        {
            {
                text = _("Anthropic: ") .. getStatusText("anthropic"),
                callback = function()
                    UIManager:close(self.per_provider_dialog)
                    self:showAnthropicReasoningConfig(state)
                end,
            },
        },
        {
            {
                text = _("OpenAI: ") .. getStatusText("openai"),
                callback = function()
                    UIManager:close(self.per_provider_dialog)
                    self:showOpenAIReasoningConfig(state)
                end,
            },
        },
        {
            {
                text = _("Gemini: ") .. getStatusText("gemini"),
                callback = function()
                    UIManager:close(self.per_provider_dialog)
                    self:showGeminiReasoningConfig(state)
                end,
            },
        },
        {
            {
                text = _("Done"),
                callback = function()
                    UIManager:close(self.per_provider_dialog)
                    refreshParent()
                end,
            },
        },
    }

    self.per_provider_dialog = ButtonDialog:new{
        title = _("Per-Provider Reasoning"),
        info_text = _("Configure reasoning for each provider independently.\nDeepSeek reasoner model always uses reasoning automatically."),
        buttons = buttons,
    }

    UIManager:show(self.per_provider_dialog)
end

-- Anthropic reasoning config
function PromptsManager:showAnthropicReasoningConfig(state)
    local buttons = {
        {
            {
                text = _("Use global setting"),
                callback = function()
                    state.reasoning_config.anthropic = nil
                    UIManager:close(self.anthropic_dialog)
                    self:showPerProviderReasoningMenu(state)
                end,
            },
        },
        {
            {
                text = _("OFF"),
                callback = function()
                    state.reasoning_config.anthropic = false
                    UIManager:close(self.anthropic_dialog)
                    self:showPerProviderReasoningMenu(state)
                end,
            },
        },
        {
            {
                text = _("ON (set budget)..."),
                callback = function()
                    UIManager:close(self.anthropic_dialog)
                    self:showAnthropicBudgetSelector(state)
                end,
            },
        },
        {
            {
                text = _("Cancel"),
                callback = function()
                    UIManager:close(self.anthropic_dialog)
                    self:showPerProviderReasoningMenu(state)
                end,
            },
        },
    }

    self.anthropic_dialog = ButtonDialog:new{
        title = _("Anthropic Extended Thinking"),
        info_text = _("Extended thinking for Claude models.\nSupports: Sonnet 4.5, Opus 4.x, Haiku 4.5, Sonnet 3.7"),
        buttons = buttons,
    }

    UIManager:show(self.anthropic_dialog)
end

-- Anthropic budget selector
function PromptsManager:showAnthropicBudgetSelector(state)
    local SpinWidget = require("ui/widget/spinwidget")
    local defaults = ModelConstraints.reasoning_defaults.anthropic

    local current = state.reasoning_config.anthropic
    local current_budget = (type(current) == "table" and current.budget) or defaults.budget

    local spin_widget = SpinWidget:new{
        title_text = _("Thinking Budget"),
        info_text = string.format(_("Token budget for extended thinking.\nHigher = more complex reasoning.\nRange: %d - %d"),
            defaults.budget_min, defaults.budget_max),
        value = current_budget,
        value_min = defaults.budget_min,
        value_max = defaults.budget_max,
        value_step = defaults.budget_step,
        default_value = defaults.budget,
        ok_always_enabled = true,
        callback = function(spin)
            state.reasoning_config.anthropic = { budget = spin.value }
            self:showPerProviderReasoningMenu(state)
        end,
    }

    UIManager:show(spin_widget)
end

-- OpenAI reasoning config
function PromptsManager:showOpenAIReasoningConfig(state)
    local buttons = {
        {
            {
                text = _("Use global setting"),
                callback = function()
                    state.reasoning_config.openai = nil
                    UIManager:close(self.openai_dialog)
                    self:showPerProviderReasoningMenu(state)
                end,
            },
        },
        {
            {
                text = _("OFF"),
                callback = function()
                    state.reasoning_config.openai = false
                    UIManager:close(self.openai_dialog)
                    self:showPerProviderReasoningMenu(state)
                end,
            },
        },
        {
            {
                text = _("Low effort"),
                callback = function()
                    state.reasoning_config.openai = { effort = "low" }
                    UIManager:close(self.openai_dialog)
                    self:showPerProviderReasoningMenu(state)
                end,
            },
        },
        {
            {
                text = _("Medium effort"),
                callback = function()
                    state.reasoning_config.openai = { effort = "medium" }
                    UIManager:close(self.openai_dialog)
                    self:showPerProviderReasoningMenu(state)
                end,
            },
        },
        {
            {
                text = _("High effort"),
                callback = function()
                    state.reasoning_config.openai = { effort = "high" }
                    UIManager:close(self.openai_dialog)
                    self:showPerProviderReasoningMenu(state)
                end,
            },
        },
        {
            {
                text = _("Cancel"),
                callback = function()
                    UIManager:close(self.openai_dialog)
                    self:showPerProviderReasoningMenu(state)
                end,
            },
        },
    }

    self.openai_dialog = ButtonDialog:new{
        title = _("OpenAI Reasoning"),
        info_text = _("Reasoning effort for OpenAI models.\nSupports: o3, o3-mini, o4-mini, GPT-5.x"),
        buttons = buttons,
    }

    UIManager:show(self.openai_dialog)
end

-- Gemini reasoning config
function PromptsManager:showGeminiReasoningConfig(state)
    local buttons = {
        {
            {
                text = _("Use global setting"),
                callback = function()
                    state.reasoning_config.gemini = nil
                    UIManager:close(self.gemini_dialog)
                    self:showPerProviderReasoningMenu(state)
                end,
            },
        },
        {
            {
                text = _("OFF"),
                callback = function()
                    state.reasoning_config.gemini = false
                    UIManager:close(self.gemini_dialog)
                    self:showPerProviderReasoningMenu(state)
                end,
            },
        },
        {
            {
                text = _("Low"),
                callback = function()
                    state.reasoning_config.gemini = { level = "low" }
                    UIManager:close(self.gemini_dialog)
                    self:showPerProviderReasoningMenu(state)
                end,
            },
        },
        {
            {
                text = _("Medium"),
                callback = function()
                    state.reasoning_config.gemini = { level = "medium" }
                    UIManager:close(self.gemini_dialog)
                    self:showPerProviderReasoningMenu(state)
                end,
            },
        },
        {
            {
                text = _("High"),
                callback = function()
                    state.reasoning_config.gemini = { level = "high" }
                    UIManager:close(self.gemini_dialog)
                    self:showPerProviderReasoningMenu(state)
                end,
            },
        },
        {
            {
                text = _("Cancel"),
                callback = function()
                    UIManager:close(self.gemini_dialog)
                    self:showPerProviderReasoningMenu(state)
                end,
            },
        },
    }

    self.gemini_dialog = ButtonDialog:new{
        title = _("Gemini Thinking"),
        info_text = _("Thinking level for Gemini models.\nSupports: gemini-3-*-preview"),
        buttons = buttons,
    }

    UIManager:show(self.gemini_dialog)
end

-- Legacy: Thinking budget selector (for backward compatibility)
function PromptsManager:showThinkingBudgetSelector(state)
    local SpinWidget = require("ui/widget/spinwidget")
    local defaults = ModelConstraints.reasoning_defaults.anthropic

    local current_budget = state.thinking_budget or defaults.budget

    local spin_widget = SpinWidget:new{
        title_text = _("Thinking Budget"),
        info_text = string.format(_("Token budget for reasoning (Anthropic).\nHigher = more complex reasoning.\nRange: %d - %d"),
            defaults.budget_min, defaults.budget_max),
        value = current_budget,
        value_min = defaults.budget_min,
        value_max = defaults.budget_max,
        value_step = defaults.budget_step,
        default_value = defaults.budget,
        ok_always_enabled = true,
        callback = function(spin)
            -- Convert to new format
            state.reasoning_config = {
                anthropic = { budget = spin.value },
            }
            UIManager:close(self.advanced_dialog)
            self:showStep4_Advanced(state)
        end,
    }

    UIManager:show(spin_widget)
end

-- Provider selector dialog
function PromptsManager:showProviderSelector(state)
    local ModelLists = require("model_lists")

    local providers = ModelLists.getAllProviders()

    local buttons = {
        -- Use global option
        {
            {
                text = _("Use global setting"),
                callback = function()
                    state.provider = nil
                    state.model = nil  -- Clear model when clearing provider
                    UIManager:close(self.provider_dialog)
                    UIManager:close(self.advanced_dialog)
                    self:showStep4_Advanced(state)
                end,
            },
        },
    }

    -- Add provider options
    for _idx,provider in ipairs(providers) do
        local prefix = (state.provider == provider) and "● " or "○ "
        local model_count = ModelLists[provider] and #ModelLists[provider] or 0
        table.insert(buttons, {
            {
                text = prefix .. provider .. " (" .. model_count .. " models)",
                callback = function()
                    state.provider = provider
                    -- Set default model for this provider
                    if ModelLists[provider] and #ModelLists[provider] > 0 then
                        state.model = ModelLists[provider][1]
                    else
                        state.model = nil
                    end
                    UIManager:close(self.provider_dialog)
                    UIManager:close(self.advanced_dialog)
                    self:showStep4_Advanced(state)
                end,
            },
        })
    end

    -- Cancel button
    table.insert(buttons, {
        {
            text = _("Cancel"),
            callback = function()
                UIManager:close(self.provider_dialog)
            end,
        },
    })

    self.provider_dialog = ButtonDialog:new{
        title = _("Select Provider"),
        buttons = buttons,
    }

    UIManager:show(self.provider_dialog)
end

-- Model selector dialog
function PromptsManager:showModelSelector(state)
    local ModelLists = require("model_lists")

    local models = ModelLists[state.provider] or {}

    local buttons = {}

    -- Add model options
    for _idx,model in ipairs(models) do
        local prefix = (state.model == model) and "● " or "○ "
        table.insert(buttons, {
            {
                text = prefix .. model,
                callback = function()
                    state.model = model
                    UIManager:close(self.model_dialog)
                    UIManager:close(self.advanced_dialog)
                    self:showStep4_Advanced(state)
                end,
            },
        })
    end

    -- Custom model option
    table.insert(buttons, {
        {
            text = _("Custom model..."),
            callback = function()
                UIManager:close(self.model_dialog)
                self:showCustomModelInput(state)
            end,
        },
    })

    -- Cancel button
    table.insert(buttons, {
        {
            text = _("Cancel"),
            callback = function()
                UIManager:close(self.model_dialog)
            end,
        },
    })

    self.model_dialog = ButtonDialog:new{
        title = _("Select Model for ") .. state.provider,
        buttons = buttons,
    }

    UIManager:show(self.model_dialog)
end

-- Custom model input dialog
function PromptsManager:showCustomModelInput(state)
    local dialog
    dialog = InputDialog:new{
        title = _("Custom Model"),
        input = state.model or "",
        input_hint = _("Enter model ID"),
        description = _("Enter the exact model ID for ") .. state.provider,
        buttons = {
            {
                {
                    text = _("Cancel"),
                    callback = function()
                        UIManager:close(dialog)
                        UIManager:close(self.advanced_dialog)
                        self:showStep4_Advanced(state)
                    end,
                },
                {
                    text = _("OK"),
                    callback = function()
                        local model = dialog:getInputText()
                        if model and model ~= "" then
                            state.model = model
                        end
                        UIManager:close(dialog)
                        UIManager:close(self.advanced_dialog)
                        self:showStep4_Advanced(state)
                    end,
                },
            },
        },
    }

    UIManager:show(dialog)
    dialog:onShowKeyboard()
end

-- Built-in action settings editor
-- Shows a combined dialog with behavior + advanced settings
function PromptsManager:showBuiltinSettingsEditor(prompt)
    -- Get base action value for skip_language_instruction (from Actions.lua, without overrides)
    local Actions = require("prompts/actions")
    local base_action = Actions.getById(prompt.id)
    local base_skip_lang = base_action and base_action.skip_language_instruction or false

    -- Initialize state from current prompt values
    local state = {
        prompt = prompt,  -- Reference to the original prompt
        behavior_variant = prompt.behavior_variant,
        behavior_override = prompt.behavior_override or "",
        temperature = prompt.temperature,
        skip_language_instruction = prompt.skip_language_instruction or false,
        skip_language_instruction_base = base_skip_lang,  -- Track base for comparison on save
        -- New format: reasoning_config
        reasoning_config = prompt.reasoning_config,
        -- Legacy format (backward compatibility)
        extended_thinking = prompt.extended_thinking,
        thinking_budget = prompt.thinking_budget,
        provider = prompt.provider,
        model = prompt.model,
    }

    self:showBuiltinSettingsDialog(state)
end

-- The actual dialog for builtin settings
function PromptsManager:showBuiltinSettingsDialog(state)
    local prompt = state.prompt

    -- Behavior display
    local behavior_display
    if state.behavior_override and state.behavior_override ~= "" then
        behavior_display = _("Custom")
    elseif state.behavior_variant == "none" then
        behavior_display = _("None")
    elseif state.behavior_variant then
        -- Look up the behavior name from built-ins
        local behavior = SystemPrompts.getBehaviorById(state.behavior_variant, nil)
        if behavior then
            behavior_display = behavior.name
        else
            behavior_display = state.behavior_variant  -- Fallback to ID
        end
    else
        behavior_display = _("Global")
    end

    -- Temperature display
    local temp_display = state.temperature and string.format("%.1f", state.temperature) or _("Global")

    -- Reasoning display (handles both legacy and new format)
    local thinking_display = self:getStateReasoningDisplayText(state)

    -- Provider/model display
    local provider_display = state.provider or _("Global")
    local model_display = state.model or _("Global")

    local buttons = {
        -- Row 1: AI Behavior
        {
            {
                text = _("AI Behavior: ") .. behavior_display,
                callback = function()
                    UIManager:close(self.builtin_settings_dialog)
                    self:showBuiltinBehaviorSelector(state)
                end,
            },
        },
        -- Row 2: Temperature
        {
            {
                text = _("Temperature: ") .. temp_display,
                callback = function()
                    self:showBuiltinTemperatureSelector(state)
                end,
            },
        },
        -- Row 3: Reasoning/Thinking
        {
            {
                text = _("Reasoning: ") .. thinking_display,
                callback = function()
                    self:showThinkingSelector(state)  -- Use shared dialog
                end,
            },
        },
        -- Row 4: Provider/Model
        {
            {
                text = _("Provider: ") .. provider_display,
                callback = function()
                    self:showBuiltinProviderSelector(state)
                end,
            },
            {
                text = _("Model: ") .. model_display,
                callback = function()
                    if not state.provider then
                        UIManager:show(InfoMessage:new{
                            text = _("Please select a provider first"),
                        })
                        return
                    end
                    self:showBuiltinModelSelector(state)
                end,
            },
        },
        -- Row 5: Skip language instruction toggle
        {
            {
                text = (state.skip_language_instruction and "☑ " or "☐ ") .. _("Skip language instruction"),
                callback = function()
                    state.skip_language_instruction = not state.skip_language_instruction
                    UIManager:close(self.builtin_settings_dialog)
                    self:showBuiltinSettingsDialog(state)
                end,
            },
        },
        -- Row 6: Cancel / Save
        {
            {
                text = _("Cancel"),
                callback = function()
                    UIManager:close(self.builtin_settings_dialog)
                end,
            },
            {
                text = _("Save"),
                callback = function()
                    UIManager:close(self.builtin_settings_dialog)
                    self:saveBuiltinOverride(prompt, state)
                    self:refreshMenu()
                end,
            },
        },
    }

    local info = string.format(_([[Edit settings for: %s

These settings override the defaults for this built-in action.
Set to "Global" to use the default setting.]]), prompt.text)

    self.builtin_settings_dialog = ButtonDialog:new{
        title = _("Edit Built-in Action Settings"),
        info_text = info,
        buttons = buttons,
    }

    UIManager:show(self.builtin_settings_dialog)
end

-- Behavior selector for builtin actions
function PromptsManager:showBuiltinBehaviorSelector(state)
    -- Determine current selection
    local current_selection = "global"
    if state.behavior_override and state.behavior_override ~= "" then
        current_selection = "custom"
    elseif state.behavior_variant == "none" then
        current_selection = "none"
    elseif isBuiltinBehavior(state.behavior_variant) then
        current_selection = state.behavior_variant
    end

    -- Build behavior options dynamically from built-in behaviors
    local behavior_options = {
        { id = "global", text = _("Use global setting") },
    }

    -- Add all built-in behaviors
    local builtin_options = getBuiltinBehaviorOptions()
    for _idx,opt in ipairs(builtin_options) do
        table.insert(behavior_options, { id = opt.id, text = opt.text .. " (" .. opt.desc .. ")" })
    end

    -- Add none and custom options
    table.insert(behavior_options, { id = "none", text = _("None (no behavior)") })
    table.insert(behavior_options, { id = "custom", text = _("Custom...") })

    local buttons = {}
    for _idx,option in ipairs(behavior_options) do
        local prefix = (current_selection == option.id) and "● " or "○ "
        table.insert(buttons, {
            {
                text = prefix .. option.text,
                callback = function()
                    UIManager:close(self.builtin_behavior_dialog)
                    if option.id == "custom" then
                        self:showBuiltinCustomBehaviorInput(state)
                    else
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
                        self:showBuiltinSettingsDialog(state)
                    end
                end,
            },
        })
    end

    table.insert(buttons, {
        {
            text = _("Cancel"),
            callback = function()
                UIManager:close(self.builtin_behavior_dialog)
                self:showBuiltinSettingsDialog(state)
            end,
        },
    })

    self.builtin_behavior_dialog = ButtonDialog:new{
        title = _("AI Behavior"),
        buttons = buttons,
    }

    UIManager:show(self.builtin_behavior_dialog)
end

-- Custom behavior input for builtin actions
function PromptsManager:showBuiltinCustomBehaviorInput(state)
    local dialog
    dialog = InputDialog:new{
        title = _("Custom Behavior"),
        input = state.behavior_override or "",
        input_hint = _("Describe how the AI should behave"),
        fullscreen = true,
        allow_newline = true,
        buttons = {
            {
                {
                    text = _("Cancel"),
                    callback = function()
                        UIManager:close(dialog)
                        self:showBuiltinBehaviorSelector(state)
                    end,
                },
                {
                    text = _("OK"),
                    callback = function()
                        local text = dialog:getInputText()
                        if text and text ~= "" then
                            state.behavior_override = text
                            state.behavior_variant = nil
                        end
                        UIManager:close(dialog)
                        self:showBuiltinSettingsDialog(state)
                    end,
                },
            },
        },
    }

    UIManager:show(dialog)
    dialog:onShowKeyboard()
end

-- Temperature selector for builtin actions
function PromptsManager:showBuiltinTemperatureSelector(state)
    local SpinWidget = require("ui/widget/spinwidget")

    local current_temp = state.temperature or 0.7

    local value_table = {}
    for i = 0, 20 do
        table.insert(value_table, i / 10)
    end

    local value_index = math.floor(current_temp * 10) + 1
    if value_index < 1 then value_index = 1 end
    if value_index > 21 then value_index = 21 end

    local spin_widget = SpinWidget:new{
        title_text = _("Temperature"),
        info_text = _("Range: 0.0-2.0 (Anthropic max 1.0)\nLower = focused\nHigher = creative"),
        value_table = value_table,
        value_index = value_index,
        default_value = 8,
        extra_text = _("Use global"),
        extra_callback = function()
            state.temperature = nil
            UIManager:close(self.builtin_settings_dialog)
            self:showBuiltinSettingsDialog(state)
        end,
        callback = function(spin)
            state.temperature = spin.value
            UIManager:close(self.builtin_settings_dialog)
            self:showBuiltinSettingsDialog(state)
        end,
    }

    UIManager:show(spin_widget)
end

-- Provider selector for builtin actions
function PromptsManager:showBuiltinProviderSelector(state)
    local ModelLists = require("model_lists")

    local providers = ModelLists.getAllProviders()

    local buttons = {
        {
            {
                text = _("Use global setting"),
                callback = function()
                    state.provider = nil
                    state.model = nil
                    UIManager:close(self.builtin_provider_dialog)
                    UIManager:close(self.builtin_settings_dialog)
                    self:showBuiltinSettingsDialog(state)
                end,
            },
        },
    }

    for _idx,provider in ipairs(providers) do
        local prefix = (state.provider == provider) and "● " or "○ "
        local model_count = ModelLists[provider] and #ModelLists[provider] or 0
        table.insert(buttons, {
            {
                text = prefix .. provider .. " (" .. model_count .. " models)",
                callback = function()
                    state.provider = provider
                    if ModelLists[provider] and #ModelLists[provider] > 0 then
                        state.model = ModelLists[provider][1]
                    else
                        state.model = nil
                    end
                    UIManager:close(self.builtin_provider_dialog)
                    UIManager:close(self.builtin_settings_dialog)
                    self:showBuiltinSettingsDialog(state)
                end,
            },
        })
    end

    table.insert(buttons, {
        {
            text = _("Cancel"),
            callback = function()
                UIManager:close(self.builtin_provider_dialog)
            end,
        },
    })

    self.builtin_provider_dialog = ButtonDialog:new{
        title = _("Select Provider"),
        buttons = buttons,
    }

    UIManager:show(self.builtin_provider_dialog)
end

-- Model selector for builtin actions
function PromptsManager:showBuiltinModelSelector(state)
    local ModelLists = require("model_lists")

    local models = ModelLists[state.provider] or {}

    local buttons = {}

    for _idx,model in ipairs(models) do
        local prefix = (state.model == model) and "● " or "○ "
        table.insert(buttons, {
            {
                text = prefix .. model,
                callback = function()
                    state.model = model
                    UIManager:close(self.builtin_model_dialog)
                    UIManager:close(self.builtin_settings_dialog)
                    self:showBuiltinSettingsDialog(state)
                end,
            },
        })
    end

    table.insert(buttons, {
        {
            text = _("Custom model..."),
            callback = function()
                UIManager:close(self.builtin_model_dialog)
                self:showBuiltinCustomModelInput(state)
            end,
        },
    })

    table.insert(buttons, {
        {
            text = _("Cancel"),
            callback = function()
                UIManager:close(self.builtin_model_dialog)
            end,
        },
    })

    self.builtin_model_dialog = ButtonDialog:new{
        title = _("Select Model for ") .. state.provider,
        buttons = buttons,
    }

    UIManager:show(self.builtin_model_dialog)
end

-- Custom model input for builtin actions
function PromptsManager:showBuiltinCustomModelInput(state)
    local dialog
    dialog = InputDialog:new{
        title = _("Custom Model"),
        input = state.model or "",
        input_hint = _("Enter model ID"),
        description = _("Enter the exact model ID for ") .. state.provider,
        buttons = {
            {
                {
                    text = _("Cancel"),
                    callback = function()
                        UIManager:close(dialog)
                        UIManager:close(self.builtin_settings_dialog)
                        self:showBuiltinSettingsDialog(state)
                    end,
                },
                {
                    text = _("OK"),
                    callback = function()
                        local model = dialog:getInputText()
                        if model and model ~= "" then
                            state.model = model
                        end
                        UIManager:close(dialog)
                        UIManager:close(self.builtin_settings_dialog)
                        self:showBuiltinSettingsDialog(state)
                    end,
                },
            },
        },
    }

    UIManager:show(dialog)
    dialog:onShowKeyboard()
end

-- Save builtin action override
function PromptsManager:saveBuiltinOverride(prompt, state)
    local all_overrides = self.plugin.settings:readSetting("builtin_action_overrides") or {}
    local key = prompt.context .. ":" .. prompt.id

    -- Build override object with only non-nil/non-global values
    local override = {}
    local has_any = false

    if state.temperature then
        override.temperature = state.temperature
        has_any = true
    end
    -- New format: reasoning_config
    if state.reasoning_config then
        override.reasoning_config = state.reasoning_config
        has_any = true
    end
    -- Legacy format (backward compatibility)
    if state.extended_thinking then
        override.extended_thinking = state.extended_thinking
        has_any = true
    end
    if state.thinking_budget then
        override.thinking_budget = state.thinking_budget
        has_any = true
    end
    if state.provider then
        override.provider = state.provider
        has_any = true
    end
    if state.model then
        override.model = state.model
        has_any = true
    end
    if state.behavior_variant then
        override.behavior_variant = state.behavior_variant
        has_any = true
    end
    if state.behavior_override and state.behavior_override ~= "" then
        override.behavior_override = state.behavior_override
        has_any = true
    end
    -- Save skip_language_instruction if it differs from the base action's default
    local base_skip_lang = state.skip_language_instruction_base or false
    if state.skip_language_instruction ~= base_skip_lang then
        override.skip_language_instruction = state.skip_language_instruction
        has_any = true
    end

    if has_any then
        all_overrides[key] = override
    else
        all_overrides[key] = nil  -- Remove if no overrides
    end

    self.plugin.settings:saveSetting("builtin_action_overrides", all_overrides)
    self.plugin.settings:flush()

    -- Invalidate action_service cache so it reloads with new overrides
    if self.plugin.action_service then
        self.plugin.action_service.actions_cache = nil
    end

    UIManager:show(InfoMessage:new{
        text = has_any and _("Settings saved") or _("Settings reset to default"),
    })
end

-- Reset builtin action override
function PromptsManager:resetBuiltinOverride(prompt)
    local all_overrides = self.plugin.settings:readSetting("builtin_action_overrides") or {}
    local key = prompt.context .. ":" .. prompt.id

    all_overrides[key] = nil

    self.plugin.settings:saveSetting("builtin_action_overrides", all_overrides)
    self.plugin.settings:flush()

    -- Invalidate action_service cache
    if self.plugin.action_service then
        self.plugin.action_service.actions_cache = nil
    end

    UIManager:show(InfoMessage:new{
        text = _("Settings reset to default"),
    })
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
        { value = "{translation_language}", text = _("Translation Language"), contexts = {"highlight", "book", "multi_book", "general", "both", "all"} },
    }

    local result = {}
    for _idx,p in ipairs(all_placeholders) do
        for _idx,ctx in ipairs(p.contexts) do
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

    for _idx,placeholder in ipairs(placeholders) do
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

        -- Calculate the action ID that will be assigned
        -- UI actions get IDs like "ui_1", "ui_2", etc.
        local current_ui_actions = self.plugin.settings:readSetting("custom_actions") or {}
        local new_action_id = "ui_" .. (#current_ui_actions + 1)

        service:addUserAction({
            text = state.name,
            behavior_variant = state.behavior_variant,
            behavior_override = behavior_override,
            prompt = state.prompt,
            context = state.context,
            include_book_context = state.include_book_context or nil,
            skip_language_instruction = state.skip_language_instruction or nil,
            domain = state.domain,
            api_params = api_params,
            reasoning_config = state.reasoning_config,  -- nil = global, "off" = force off, table = per-provider
            -- Legacy fields (backward compatibility)
            extended_thinking = state.extended_thinking,
            thinking_budget = state.thinking_budget,
            provider = state.provider,  -- nil = use global
            model = state.model,        -- nil = use global
            enabled = true,
        })

        -- Add to highlight menu if requested (only for highlight-compatible contexts)
        if state.add_to_highlight_menu and self:contextIncludesHighlight(state.context) then
            service:addToHighlightMenu(new_action_id)
        end

        -- Add to dictionary popup if requested (only for highlight-compatible contexts)
        if state.add_to_dictionary_popup and self:contextIncludesHighlight(state.context) then
            service:addToDictionaryPopup(new_action_id)
        end

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
                skip_language_instruction = state.skip_language_instruction or nil,
                domain = state.domain,
                api_params = api_params,
                reasoning_config = state.reasoning_config,  -- nil = global, "off" = force off, table = per-provider
                -- Legacy fields (backward compatibility)
                extended_thinking = state.extended_thinking,
                thinking_budget = state.thinking_budget,
                provider = state.provider,
                model = state.model,
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

-- ============================================================
-- Highlight Menu Manager
-- ============================================================

-- Show the enhanced highlight menu manager with ALL highlight actions
-- Tap = toggle menu inclusion, Hold = move options (if in menu)
function PromptsManager:showHighlightMenuManager()
    if not self.plugin.action_service then
        UIManager:show(InfoMessage:new{
            text = _("Action service not available."),
        })
        return
    end

    local all_actions = self.plugin.action_service:getAllHighlightActionsWithMenuState()

    if #all_actions == 0 then
        UIManager:show(InfoMessage:new{
            text = _("No highlight actions available."),
        })
        return
    end

    -- Count items in menu for display
    local menu_count = 0
    for _idx,item in ipairs(all_actions) do
        if item.in_menu then menu_count = menu_count + 1 end
    end

    local menu_items = {}

    -- Help text item
    table.insert(menu_items, {
        text = _("✓ = in menu | Tap = toggle | Hold = move"),
        dim = true,
        callback = function() end,  -- No action
    })

    for _idx,item in ipairs(all_actions) do
        local action = item.action
        local prefix = item.in_menu and "✓ " or "  "
        local position = item.in_menu and string.format("[%d] ", item.menu_position) or ""
        local source_indicator = ""
        if action.source == "ui" then
            source_indicator = " ★"
        elseif action.source == "config" then
            source_indicator = " ◆"
        end

        table.insert(menu_items, {
            text = prefix .. position .. (action.text or action.id) .. source_indicator,
            action = action,
            in_menu = item.in_menu,
            menu_position = item.menu_position,
            callback = function()
                -- Toggle menu inclusion
                self.plugin.action_service:toggleHighlightMenuAction(action.id)
                -- Show restart reminder
                UIManager:show(Notification:new{
                    text = _("Changes require restart to take effect"),
                    timeout = 2,
                })
                -- Refresh the menu after close completes
                UIManager:close(self.highlight_menu)
                UIManager:scheduleIn(0.1, function()
                    self:showHighlightMenuManager()
                end)
            end,
        })
    end

    self.highlight_menu = Menu:new{
        title = string.format(_("Highlight Menu (%d enabled)"), menu_count),
        item_table = menu_items,
        width = self.width,
        height = self.height,
        covers_fullscreen = true,
        is_borderless = true,
        is_popout = false,
        onMenuHold = function(menu_widget, menu_item)
            if menu_item and menu_item.action then
                if menu_item.in_menu then
                    -- Show move options for items in menu
                    self:showHighlightMenuActionOptions(menu_item.action, menu_item.menu_position, menu_count)
                else
                    -- Show info for items not in menu
                    UIManager:show(InfoMessage:new{
                        text = string.format(
                            "%s\n\nSource: %s\n\nTap to add to highlight menu.",
                            menu_item.action.text or menu_item.action.id,
                            menu_item.action.source or "builtin"
                        ),
                        timeout = 3,
                    })
                end
            end
        end,
        close_callback = function()
            UIManager:close(self.highlight_menu)
        end,
    }
    UIManager:show(self.highlight_menu)
end

-- Show options for a highlight menu action (move up/down, remove)
function PromptsManager:showHighlightMenuActionOptions(action, index, total)
    local buttons = {}

    if index > 1 then
        table.insert(buttons, {
            {
                text = _("↑ Move Up"),
                callback = function()
                    self.plugin.action_service:moveHighlightMenuAction(action.id, "up")
                    UIManager:close(self.options_dialog)
                    UIManager:close(self.highlight_menu)
                    self:showHighlightMenuManager()
                end,
            },
        })
    end

    if index < total then
        table.insert(buttons, {
            {
                text = _("↓ Move Down"),
                callback = function()
                    self.plugin.action_service:moveHighlightMenuAction(action.id, "down")
                    UIManager:close(self.options_dialog)
                    UIManager:close(self.highlight_menu)
                    self:showHighlightMenuManager()
                end,
            },
        })
    end

    table.insert(buttons, {
        {
            text = _("Remove from Menu"),
            callback = function()
                self.plugin.action_service:removeFromHighlightMenu(action.id)
                UIManager:close(self.options_dialog)
                UIManager:close(self.highlight_menu)
                self:showHighlightMenuManager()
            end,
        },
    })

    table.insert(buttons, {
        {
            text = _("Cancel"),
            callback = function()
                UIManager:close(self.options_dialog)
            end,
        },
    })

    self.options_dialog = ButtonDialog:new{
        title = action.text or action.id,
        info_text = _("Position: ") .. index .. "/" .. total,
        buttons = buttons,
    }
    UIManager:show(self.options_dialog)
end

-- ============================================================
-- Dictionary Popup Actions Manager
-- ============================================================

function PromptsManager:showDictionaryPopupManager()
    if not self.plugin.action_service then
        UIManager:show(InfoMessage:new{
            text = _("Action service not available."),
        })
        return
    end

    local all_actions = self.plugin.action_service:getAllHighlightActionsWithPopupState()

    if #all_actions == 0 then
        UIManager:show(InfoMessage:new{
            text = _("No highlight actions available."),
        })
        return
    end

    -- Count items in popup for display
    local popup_count = 0
    for _idx,item in ipairs(all_actions) do
        if item.in_popup then popup_count = popup_count + 1 end
    end

    local menu_items = {}

    -- Help text item
    table.insert(menu_items, {
        text = _("✓ = in popup | Tap = toggle | Hold = move"),
        dim = true,
        callback = function() end,  -- No action
    })

    for _idx,item in ipairs(all_actions) do
        local action = item.action
        local prefix = item.in_popup and "✓ " or "  "
        local position = item.in_popup and string.format("[%d] ", item.popup_position) or ""
        local source_indicator = ""
        if action.source == "ui" then
            source_indicator = " ★"
        elseif action.source == "config" then
            source_indicator = " ◆"
        end

        table.insert(menu_items, {
            text = prefix .. position .. (action.text or action.id) .. source_indicator,
            action = action,
            in_popup = item.in_popup,
            popup_position = item.popup_position,
            callback = function()
                -- Toggle popup inclusion
                self.plugin.action_service:toggleDictionaryPopupAction(action.id)
                -- Refresh the menu after close completes
                UIManager:close(self.dictionary_popup_menu)
                UIManager:scheduleIn(0.1, function()
                    self:showDictionaryPopupManager()
                end)
            end,
        })
    end

    self.dictionary_popup_menu = Menu:new{
        title = string.format(_("Dictionary Popup (%d enabled)"), popup_count),
        item_table = menu_items,
        width = self.width,
        height = self.height,
        covers_fullscreen = true,
        is_borderless = true,
        is_popout = false,
        onMenuHold = function(menu_widget, menu_item)
            if menu_item and menu_item.action then
                if menu_item.in_popup then
                    -- Show move options for items in popup
                    self:showDictionaryPopupActionOptions(menu_item.action, menu_item.popup_position, popup_count)
                else
                    -- Show info for items not in popup
                    UIManager:show(InfoMessage:new{
                        text = string.format(
                            "%s\n\nSource: %s\n\nTap to add to dictionary popup.",
                            menu_item.action.text or menu_item.action.id,
                            menu_item.action.source or "builtin"
                        ),
                        timeout = 3,
                    })
                end
            end
        end,
        close_callback = function()
            UIManager:close(self.dictionary_popup_menu)
        end,
    }
    UIManager:show(self.dictionary_popup_menu)
end

-- Show options for a dictionary popup action (move up/down, remove)
function PromptsManager:showDictionaryPopupActionOptions(action, index, total)
    local buttons = {}

    if index > 1 then
        table.insert(buttons, {
            {
                text = _("↑ Move Up"),
                callback = function()
                    self.plugin.action_service:moveDictionaryPopupAction(action.id, "up")
                    UIManager:close(self.options_dialog)
                    UIManager:close(self.dictionary_popup_menu)
                    self:showDictionaryPopupManager()
                end,
            },
        })
    end

    if index < total then
        table.insert(buttons, {
            {
                text = _("↓ Move Down"),
                callback = function()
                    self.plugin.action_service:moveDictionaryPopupAction(action.id, "down")
                    UIManager:close(self.options_dialog)
                    UIManager:close(self.dictionary_popup_menu)
                    self:showDictionaryPopupManager()
                end,
            },
        })
    end

    table.insert(buttons, {
        {
            text = _("Remove from Popup"),
            callback = function()
                self.plugin.action_service:removeFromDictionaryPopup(action.id)
                UIManager:close(self.options_dialog)
                UIManager:close(self.dictionary_popup_menu)
                self:showDictionaryPopupManager()
            end,
        },
    })

    table.insert(buttons, {
        {
            text = _("Cancel"),
            callback = function()
                UIManager:close(self.options_dialog)
            end,
        },
    })

    self.options_dialog = ButtonDialog:new{
        title = action.text or action.id,
        info_text = _("Position: ") .. index .. "/" .. total,
        buttons = buttons,
    }
    UIManager:show(self.options_dialog)
end

return PromptsManager