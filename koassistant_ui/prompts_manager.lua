local _ = require("koassistant_gettext")
local T = require("ffi/util").template
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
local UIConstants = require("koassistant_ui.constants")
local ModelConstraints = require("model_constraints")
local SystemPrompts = require("prompts/system_prompts")
local Actions = require("prompts/actions")
local ActionService = require("action_service")
local Constants = require("koassistant_constants")

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
                desc = T(_("~%1 tokens"), tokens),
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
        return T(_("On (%1 tokens)"), budget)
    elseif obj.extended_thinking == "off" then
        return _("Force OFF")
    end

    return _("Global")
end

-- Alias for backward compatibility (same function, different name)
function PromptsManager:getStateReasoningDisplayText(state)
    return self:getReasoningDisplayText(state)
end

-- Check if a context is gesture-compatible (can be registered as a gesture)
-- Only book and general contexts are compatible - highlight requires text selection,
-- multi_book requires file browser multi-select
function PromptsManager:isGestureCompatibleContext(context)
    return context == "book" or context == "general" or context == "book+general"
end

-- Check if an action is registered as a gesture
function PromptsManager:isGestureEnabled(prompt)
    if not self:isGestureCompatibleContext(prompt.context) then
        return false
    end
    local features = self.plugin.settings:readSetting("features") or {}
    local gesture_actions = features.gesture_actions or {}
    local key = prompt.context .. ":" .. prompt.id
    return gesture_actions[key] == true
end

-- Toggle gesture registration for an action
function PromptsManager:setGestureEnabled(prompt, enabled)
    if not self:isGestureCompatibleContext(prompt.context) then
        return
    end
    local features = self.plugin.settings:readSetting("features") or {}
    local gesture_actions = features.gesture_actions or {}
    local key = prompt.context .. ":" .. prompt.id
    if enabled then
        gesture_actions[key] = true
    else
        gesture_actions[key] = nil
    end
    features.gesture_actions = gesture_actions
    self.plugin.settings:saveSetting("features", features)
    self.plugin.settings:flush()
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
    -- Preserves compound contexts (both) from original_context
    local function addPromptEntry(prompt, context_override)
        -- Use original context if it's a compound context (both)
        local context = prompt.original_context
        if context == "both" then
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
            description = prompt.description,
            id = prompt.id,
            include_book_context = prompt.include_book_context,
            skip_language_instruction = prompt.skip_language_instruction,
            skip_domain = prompt.skip_domain,
            temperature = temperature,
            extended_thinking = prompt.extended_thinking,
            thinking_budget = prompt.thinking_budget,
            reasoning_config = prompt.reasoning_config,
            provider = prompt.provider,
            model = prompt.model,
            has_override = false,
            -- Context extraction flags
            use_book_text = prompt.use_book_text,
            use_highlights = prompt.use_highlights,
            use_annotations = prompt.use_annotations,
            use_reading_progress = prompt.use_reading_progress,
            use_reading_stats = prompt.use_reading_stats,
            use_notebook = prompt.use_notebook,
            -- Requirement flags
            requires_open_book = prompt.requires_open_book,
            -- View mode flags
            translate_view = prompt.translate_view,
            compact_view = prompt.compact_view,
            minimal_buttons = prompt.minimal_buttons,
            -- Duplication control
            no_duplicate = prompt.no_duplicate,
            -- Local handler (no AI call)
            local_handler = prompt.local_handler,
            -- Menu flags
            in_quick_actions = prompt.in_quick_actions,
            in_reading_features = prompt.in_reading_features,
            in_highlight_menu = prompt.in_highlight_menu,
            in_dictionary_popup = prompt.in_dictionary_popup,
            -- Web search
            enable_web_search = prompt.enable_web_search,
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
                if override.skip_domain ~= nil then entry.skip_domain = override.skip_domain end
                if override.include_book_context ~= nil then entry.include_book_context = override.include_book_context end
                -- Context extraction flag overrides
                if override.use_book_text ~= nil then entry.use_book_text = override.use_book_text end
                if override.use_highlights ~= nil then entry.use_highlights = override.use_highlights end
                if override.use_annotations ~= nil then entry.use_annotations = override.use_annotations end
                if override.use_reading_progress ~= nil then entry.use_reading_progress = override.use_reading_progress end
                if override.use_reading_stats ~= nil then entry.use_reading_stats = override.use_reading_stats end
                if override.use_notebook ~= nil then entry.use_notebook = override.use_notebook end
                -- View mode flag overrides
                if override.translate_view ~= nil then entry.translate_view = override.translate_view end
                if override.compact_view ~= nil then entry.compact_view = override.compact_view end
                if override.minimal_buttons ~= nil then entry.minimal_buttons = override.minimal_buttons end
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
            for _j,existing in ipairs(self.prompts) do
                if existing.text == prompt.text and existing.source == prompt.source then
                    -- Change context to "both" (unless it's already a compound)
                    if existing.context ~= "both" then
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
            for _j,existing in ipairs(self.prompts) do
                if existing.text == prompt.text and existing.source == prompt.source then
                    -- Update context to include general (unless it's already a compound)
                    if existing.context == "highlight" then
                        existing.context = "highlight+general"
                    elseif existing.context == "book" then
                        existing.context = "book+general"
                    elseif existing.context == "both" then
                        existing.context = "both+general"
                    end
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

function PromptsManager:_buildActionManagerItems()
    local menu_items = {}

    -- Add help text at the top
    table.insert(menu_items, {
        text = _("Tap to toggle • Hold for details • ★ = custom • ⚙ = modified • [gesture] = in gesture menu"),
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

    -- Group prompts by context
    local contexts = {
        { id = "highlight", text = _("Highlight Context") },
        { id = "book", text = _("Book Context") },
        { id = "multi_book", text = _("Multi-Book Context") },
        { id = "general", text = _("General Context") },
        { id = "both", text = _("Highlight & Book") },
        { id = "highlight+general", text = _("Highlight & General") },
        { id = "book+general", text = _("Book & General") },
        { id = "both+general", text = _("Highlight, Book & General") },
    }

    local features = self.plugin.settings:readSetting("features") or {}

    for _idx,context_info in ipairs(contexts) do
        local context_prompts = {}
        for _j,prompt in ipairs(self.prompts) do
            if prompt.context == context_info.id then
                table.insert(context_prompts, prompt)
            end
        end

        if #context_prompts > 0 then
            -- Add context header with spacing
            table.insert(menu_items, {
                text = "▶ " .. context_info.text:upper(),
                enabled = false,
                dim = false,
                bold = true,
            })

            -- Add prompts for this context
            for _k,prompt in ipairs(context_prompts) do
                local item_text = ActionService.getActionDisplayText(prompt, features)

                -- Add source indicator
                if prompt.source == "ui" then
                    item_text = "★ " .. item_text
                elseif prompt.source == "config" then
                    item_text = "★ " .. item_text .. " (file)"
                elseif prompt.source == "builtin" and prompt.has_override then
                    item_text = "⚙ " .. item_text
                end

                -- Add open book indicator
                if prompt.context ~= "highlight" and Actions.requiresOpenBook(prompt) then
                    item_text = item_text .. " [reading]"
                end

                -- Add gesture indicator
                if self:isGestureEnabled(prompt) then
                    item_text = item_text .. " [gesture]"
                end

                -- Add checkbox with better spacing
                local checkbox = prompt.enabled and "☑" or "☐"
                item_text = checkbox .. "  " .. item_text

                table.insert(menu_items, {
                    text = item_text,
                    prompt = prompt,  -- Store reference to prompt
                    callback = function()
                        -- Toggle enabled state and flip local copy for instant refresh
                        self:setPromptEnabled(prompt.id, prompt.context, not prompt.enabled)
                        prompt.enabled = not prompt.enabled
                        self:_refreshActionManagerMenu()
                    end,
                    hold_callback = function()
                        self:showPromptDetails(prompt)
                    end,
                })
            end
        end
    end

    return menu_items
end

function PromptsManager:_refreshActionManagerMenu()
    if not self.prompts_menu then return end
    local menu_items = self:_buildActionManagerItems()
    self.prompts_menu:switchItemTable(_("Manage Actions"), menu_items, -1)
end

function PromptsManager:showPromptsMenu()
    if not self.prompts then
        self:loadPrompts()
    end
    local menu_items = self:_buildActionManagerItems()
    
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
                            if self.plugin.restoreDefaultPrompts then
                                self.plugin:restoreDefaultPrompts()
                            end
                            self:refreshMenu()
                        end,
                    })
                end,
            },
        },
    }
    
    local self_ref = self
    self.prompts_menu = Menu:new{
        title = _("Manage Actions"),
        title_bar_left_icon = "appbar.menu",
        onLeftButtonTap = function()
            self_ref:showMenuOptions()
        end,
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

-- Hamburger menu options for Manage Actions
function PromptsManager:showMenuOptions()
    local self_ref = self
    local from = "prompts_menu"
    local buttons = {
        self:_makeNavButton(_("Highlight Menu"), from, function() self_ref:showHighlightMenuManager() end),
        self:_makeNavButton(_("Dictionary Popup"), from, function() self_ref:showDictionaryPopupManager() end),
        self:_makeNavButton(_("Quick Actions"), from, function() self_ref:showQuickActionsManager() end),
        self:_makeNavButton(_("File Browser Actions"), from, function() self_ref:showFileBrowserActionsManager() end),
        {{ text = _("Reset custom actions"), align = "left", callback = function()
            if self_ref._anchored_menu then UIManager:close(self_ref._anchored_menu) end
            UIManager:show(ConfirmBox:new{
                text = _("Delete all custom actions?\n\nThis removes actions you created.\n\nBuilt-in actions and their edits are preserved."),
                ok_callback = function()
                    self_ref.plugin:resetCustomActions()
                    self_ref.plugin.action_service:loadActions()
                    self_ref:refreshMenu()
                end,
            })
        end }},
        {{ text = _("Reset action edits"), align = "left", callback = function()
            if self_ref._anchored_menu then UIManager:close(self_ref._anchored_menu) end
            UIManager:show(ConfirmBox:new{
                text = _("Reset all action edits?\n\nThis reverts any changes you made to built-in actions and re-enables disabled actions.\n\nCustom actions are preserved."),
                ok_callback = function()
                    self_ref.plugin:resetActionEdits()
                    self_ref.plugin.action_service:loadActions()
                    self_ref:refreshMenu()
                end,
            })
        end }},
        {{ text = _("Reset action menus…"), align = "left", callback = function()
            if self_ref._anchored_menu then UIManager:close(self_ref._anchored_menu) end
            self_ref:showResetMenusDialog()
        end }},
    }
    self:_showAnchoredMenu(self.prompts_menu, buttons)
end

-- Sub-popup for resetting individual action menus
function PromptsManager:showResetMenusDialog()
    local self_ref = self
    local dialog
    dialog = ButtonDialog:new{
        title = _("Reset Action Menus"),
        buttons = {
            {{ text = _("Reset Highlight Menu"), callback = function()
                UIManager:close(dialog)
                UIManager:show(ConfirmBox:new{
                    text = _("Reset highlight menu actions to defaults?"),
                    ok_callback = function()
                        self_ref.plugin:resetHighlightMenuActions()
                        self_ref:refreshMenu()
                    end,
                })
            end }},
            {{ text = _("Reset Dictionary Popup"), callback = function()
                UIManager:close(dialog)
                UIManager:show(ConfirmBox:new{
                    text = _("Reset dictionary popup actions to defaults?"),
                    ok_callback = function()
                        self_ref.plugin:resetDictionaryPopupActions()
                        self_ref:refreshMenu()
                    end,
                })
            end }},
            {{ text = _("Reset Quick Actions"), callback = function()
                UIManager:close(dialog)
                UIManager:show(ConfirmBox:new{
                    text = _("Reset Quick Actions panel to defaults?"),
                    ok_callback = function()
                        self_ref.plugin:resetQuickActions()
                        self_ref:refreshMenu()
                    end,
                })
            end }},
            {{ text = _("Reset File Browser Actions"), callback = function()
                UIManager:close(dialog)
                UIManager:show(ConfirmBox:new{
                    text = _("Reset file browser actions to defaults?"),
                    ok_callback = function()
                        self_ref.plugin:resetFileBrowserActions()
                        self_ref:refreshMenu()
                    end,
                })
            end }},
            {{ text = _("Reset QA Utilities"), callback = function()
                UIManager:close(dialog)
                UIManager:show(ConfirmBox:new{
                    text = _("Reset QA panel utilities to defaults?"),
                    ok_callback = function()
                        self_ref.plugin:resetQaUtilities()
                        self_ref:refreshMenu()
                    end,
                })
            end }},
            {{ text = _("Reset QS Panel Items"), callback = function()
                UIManager:close(dialog)
                UIManager:show(ConfirmBox:new{
                    text = _("Reset QS panel items to defaults?"),
                    ok_callback = function()
                        self_ref.plugin:resetQsItems()
                        self_ref:refreshMenu()
                    end,
                })
            end }},
            {{ text = _("Reset Input Dialog Actions"), callback = function()
                UIManager:close(dialog)
                UIManager:show(ConfirmBox:new{
                    text = _("Reset input dialog actions to defaults for all contexts (book, file browser, highlight, X-Ray chat)?"),
                    ok_callback = function()
                        self_ref.plugin:resetInputDialogActions()
                        self_ref:refreshMenu()
                    end,
                })
            end }},
            {{ text = _("Reset All Menus"), callback = function()
                UIManager:close(dialog)
                UIManager:show(ConfirmBox:new{
                    text = _("Reset ALL action menu configurations?\n\nThis resets ordering and selection in all menus back to defaults.\n\nYour actions (custom and built-in) are preserved."),
                    ok_callback = function()
                        self_ref.plugin:resetActionMenus()
                        self_ref.plugin:resetQaUtilities()
                        self_ref.plugin:resetQsItems()
                        self_ref:refreshMenu()
                    end,
                })
            end }},
        },
    }
    UIManager:show(dialog)
end

function PromptsManager:refreshMenu()
    -- Full reload: re-read prompts from action service and refresh in-place
    if self.prompts_menu then
        self:loadPrompts()
        local menu_items = self:_buildActionManagerItems()
        self.prompts_menu:switchItemTable(_("Manage Actions"), menu_items, -1)
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

    -- Build info text with organized sections
    -- Basic info
    local info_text = prompt.text

    -- Description (if available)
    if prompt.description and prompt.description ~= "" then
        info_text = info_text .. "\n\n" .. prompt.description
    end

    -- Note about open book requirement (shown prominently at top)
    -- Uses dynamic inference from flags, not just explicit requires_open_book
    if Actions.requiresOpenBook(prompt) then
        info_text = info_text .. "\n\n" .. _("(Only available when reading, not from file browser)")
    end

    info_text = info_text .. string.format(
        "\n\n%s: %s\n%s: %s\n%s: %s",
        _("Context"), self:getContextDisplayName(prompt.context),
        _("Source"), source_text,
        _("Status"), prompt.enabled and _("Enabled") or _("Disabled")
    )

    if prompt.local_handler then
        -- Local handler actions don't use AI — skip flags, AI settings, and prompt sections
        info_text = info_text .. "\n\n" .. _("This is a local action — no AI call is made.")
    else
        -- Flags section (grouped together)
        info_text = info_text .. "\n\n" .. _("─── Flags ───")

        -- Skip language/domain
        local skip_lang_text = prompt.skip_language_instruction and _("Yes") or _("No")
        local skip_domain_text = prompt.skip_domain and _("Yes") or _("No")
        info_text = info_text .. "\n" .. _("Skip Language") .. ": " .. skip_lang_text
        info_text = info_text .. "  |  " .. _("Skip Domain") .. ": " .. skip_domain_text

        -- Include book info (for highlight contexts)
        if self:contextIncludesHighlight(prompt.context) then
            local book_context_text = prompt.include_book_context and _("Yes") or _("No")
            info_text = info_text .. "\n" .. _("Include Book Info") .. ": " .. book_context_text
        end

        -- Book text extraction (for contexts that can run in reading mode)
        -- Note: Lightweight data (progress, highlights, annotations, stats) is always available
        if self:canUseTextExtraction(prompt) then
            local book_text_status = prompt.use_book_text and _("Yes") or _("No")
            info_text = info_text .. "\n" .. _("Allow text extraction") .. ": " .. book_text_status
        end

        -- Web search override
        local web_search_text
        if prompt.enable_web_search == true then
            web_search_text = _("Always")
        elseif prompt.enable_web_search == false then
            web_search_text = _("Never")
        else
            web_search_text = _("Global")
        end
        info_text = info_text .. "\n" .. _("Web Search") .. ": " .. web_search_text

        -- AI Settings section
        info_text = info_text .. "\n\n" .. _("─── AI Settings ───")
        info_text = info_text .. "\n" .. _("Temperature") .. ": " .. temp_text
        info_text = info_text .. "\n" .. _("Reasoning") .. ": " .. thinking_text
        info_text = info_text .. "\n" .. _("Provider/Model") .. ": " .. provider_text .. " / " .. model_text
        info_text = info_text .. "\n" .. _("AI Behavior") .. ": " .. behavior_text

        -- Prompt section (at the end since it's longest)
        info_text = info_text .. "\n\n" .. _("─── Action Prompt ───") .. "\n" .. (prompt.prompt or _("(None)"))

    end

    local buttons = {}

    -- Duplicate button (reused across source types)
    local duplicate_btn
    if self.plugin.action_service and not prompt.no_duplicate then
        duplicate_btn = {
            text = _("Duplicate"),
            callback = function()
                UIManager:close(self.details_dialog)
                self:duplicateAction(prompt)
            end,
        }
    end

    -- Top rows: Edit/Quick Edit + Duplicate (or Delete for UI-created)
    if prompt.source == "ui" then
        -- Row 1: [Quick Edit] [Duplicate]
        local row = {
            {
                text = _("Quick Edit"),
                callback = function()
                    if self.details_dialog then
                        UIManager:close(self.details_dialog)
                    end
                    self:showCustomQuickSettings(prompt)
                end,
            },
        }
        if duplicate_btn then table.insert(row, duplicate_btn) end
        table.insert(buttons, row)
    elseif prompt.source == "config" then
        -- Row 1: [Edit file] [Duplicate]
        local row = {
            {
                text = _("Edit file"),
                callback = function()
                    UIManager:show(InfoMessage:new{
                        text = _("This action is defined in custom_actions.lua.\nPlease edit that file directly to modify it."),
                    })
                end,
            },
        }
        if duplicate_btn then table.insert(row, duplicate_btn) end
        table.insert(buttons, row)
    elseif prompt.source == "builtin" and not prompt.local_handler then
        -- Row 1: [Edit Settings] [Duplicate]
        local row = {
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
        if duplicate_btn then table.insert(row, duplicate_btn) end
        table.insert(buttons, row)
        -- Optional: [Reset to Default] row if overrides exist
        if prompt.has_override then
            table.insert(buttons, {
                {
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
                },
            })
        end
    elseif duplicate_btn then
        -- Other sources (e.g., builtin local_handler): just Duplicate
        table.insert(buttons, { duplicate_btn })
    end

    -- Collect menu/toggle buttons, then pair them 2 per row to save space
    local toggle_buttons = {}
    local is_highlight_context = self:contextIncludesHighlight(prompt.context)
    local requires_input = prompt.id == "ask" or (prompt.prompt and prompt.prompt:find("{user_input}"))

    -- Highlight menu toggle
    if is_highlight_context and not requires_input and self.plugin.action_service then
        local in_menu = self.plugin.action_service:isInHighlightMenu(prompt.id)
        table.insert(toggle_buttons, {
            text = in_menu and _("✓ Highlight Menu") or _("+ Highlight Menu"),
            callback = function()
                local now_in_menu = self.plugin.action_service:toggleHighlightMenuAction(prompt.id)
                UIManager:close(self.details_dialog)
                UIManager:show(InfoMessage:new{
                    text = now_in_menu
                        and _("Added to highlight menu.\nRestart KOReader to apply.")
                        or _("Removed from highlight menu.\nRestart KOReader to apply."),
                    timeout = 3,
                })
            end,
        })
    end

    -- Dictionary popup toggle
    if is_highlight_context and not requires_input and self.plugin.action_service then
        local in_popup = self.plugin.action_service:isInDictionaryPopup(prompt.id)
        table.insert(toggle_buttons, {
            text = in_popup and _("✓ Dict. Popup") or _("+ Dict. Popup"),
            callback = function()
                local now_in_popup = self.plugin.action_service:toggleDictionaryPopupAction(prompt.id)
                UIManager:close(self.details_dialog)
                UIManager:show(InfoMessage:new{
                    text = now_in_popup and _("Removed from dictionary popup.") or _("Added to dictionary popup."),
                    timeout = 2,
                })
            end,
        })
    end

    -- Quick Actions toggle (book context only)
    if prompt.context == "book" and prompt.enabled and self.plugin.action_service then
        local in_quick_actions = self.plugin.action_service:isInQuickActions(prompt.id)
        table.insert(toggle_buttons, {
            text = in_quick_actions and _("✓ Quick Actions") or _("+ Quick Actions"),
            callback = function()
                local self_ref = self
                self.plugin.action_service:toggleQuickAction(prompt.id)
                UIManager:close(self_ref.details_dialog)
                UIManager:show(InfoMessage:new{
                    text = in_quick_actions
                        and _("Removed from Quick Actions.")
                        or _("Added to Quick Actions."),
                    timeout = 2,
                })
                self_ref:refreshMenu()
            end,
        })
    end

    -- Input Dialog toggle (book and highlight contexts)
    if self.plugin.action_service then
        local input_ctx = ActionService.getInputContextForAction(prompt)
        if input_ctx and prompt.enabled then
            local in_input = self.plugin.action_service:isInInput(input_ctx, prompt.id)
            table.insert(toggle_buttons, {
                text = in_input and _("✓ Input Dialog") or _("+ Input Dialog"),
                callback = function()
                    local self_ref = self
                    self.plugin.action_service:toggleInputAction(input_ctx, prompt.id)
                    UIManager:close(self_ref.details_dialog)
                    UIManager:show(InfoMessage:new{
                        text = in_input
                            and _("Removed from input dialog.")
                            or _("Added to input dialog."),
                        timeout = 2,
                    })
                    self_ref:refreshMenu()
                end,
            })
        end
    end

    -- General Input toggle (general context only)
    if prompt.context == "general" and prompt.enabled and self.plugin.action_service then
        local in_general_menu = self.plugin.action_service:isInGeneralMenu(prompt.id)
        table.insert(toggle_buttons, {
            text = in_general_menu and _("✓ General Input") or _("+ General Input"),
            callback = function()
                local self_ref = self
                self.plugin.action_service:toggleGeneralMenuAction(prompt.id)
                UIManager:close(self_ref.details_dialog)
                UIManager:show(InfoMessage:new{
                    text = in_general_menu
                        and _("Removed from general input dialog.")
                        or _("Added to general input dialog."),
                    timeout = 2,
                })
                self_ref:refreshMenu()
            end,
        })
    end

    -- File Browser toggle (book-context, non-reading actions)
    local is_book_eligible = self:contextIncludesBook(prompt.context)
    if is_book_eligible and prompt.enabled and not Actions.requiresOpenBook(prompt) and self.plugin.action_service then
        local in_file_browser = self.plugin.action_service:isInFileBrowser(prompt.id)
        table.insert(toggle_buttons, {
            text = in_file_browser and _("✓ File Browser") or _("+ File Browser"),
            callback = function()
                local self_ref = self
                self.plugin.action_service:toggleFileBrowserAction(prompt.id)
                UIManager:close(self_ref.details_dialog)
                UIManager:show(InfoMessage:new{
                    text = in_file_browser
                        and _("Removed from file browser.")
                        or _("Added to file browser."),
                    timeout = 2,
                })
                self_ref:refreshMenu()
            end,
        })
    end

    -- Gesture menu toggle (last among feature toggles)
    if self:isGestureCompatibleContext(prompt.context) and prompt.enabled then
        local in_gesture = self:isGestureEnabled(prompt)
        table.insert(toggle_buttons, {
            text = in_gesture and _("✓ Gesture Menu") or _("+ Gesture Menu"),
            callback = function()
                local self_ref = self
                self_ref:setGestureEnabled(prompt, not in_gesture)
                UIManager:close(self_ref.details_dialog)
                UIManager:show(InfoMessage:new{
                    text = in_gesture
                        and _("Removed from gesture menu.\nRestart KOReader to apply.")
                        or _("Added to gesture menu.\nRestart KOReader to apply."),
                    timeout = 3,
                })
                self_ref:refreshMenu()
            end,
        })
    end

    -- Pair toggle buttons into rows of 2
    for i = 1, #toggle_buttons, 2 do
        if toggle_buttons[i + 1] then
            table.insert(buttons, { toggle_buttons[i], toggle_buttons[i + 1] })
        else
            table.insert(buttons, { toggle_buttons[i] })
        end
    end

    -- Delete button at the bottom for UI-created actions
    if prompt.source == "ui" then
        table.insert(buttons, {
            {
                text = _("Delete"),
                callback = function()
                    UIManager:show(ConfirmBox:new{
                        text = _("Delete this action?"),
                        ok_callback = function()
                            self:deletePrompt(prompt)
                            if self.details_dialog then
                                UIManager:close(self.details_dialog)
                            end
                            self:refreshMenu()
                        end,
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
        skip_domain = duplicate.skip_domain,
        reasoning_config = duplicate.reasoning_config,
        extended_thinking = duplicate.extended_thinking,
        thinking_budget = duplicate.thinking_budget,
        provider = duplicate.provider,
        model = duplicate.model,
        -- Context extraction flags (for reading-only actions)
        use_book_text = duplicate.use_book_text,
        use_highlights = duplicate.use_highlights,
        use_annotations = duplicate.use_annotations,
        use_reading_progress = duplicate.use_reading_progress,
        use_reading_stats = duplicate.use_reading_stats,
        use_notebook = duplicate.use_notebook,
        -- View mode flags
        translate_view = duplicate.translate_view,
        compact_view = duplicate.compact_view,
        minimal_buttons = duplicate.minimal_buttons,
    }

    -- Add temperature if set
    if duplicate.temperature then
        action_data.api_params = action_data.api_params or {}
        action_data.api_params.temperature = duplicate.temperature
    end

    -- Save immediately as a new custom action (will have star icon as source = "ui")
    self.plugin.action_service:addUserAction(action_data)

    -- Show success notification
    UIManager:show(InfoMessage:new{
        text = T(_("Created: %1"), duplicate.text),
        timeout = 2,
    })

    -- Refresh in-place (preserves current page)
    self:refreshMenu()
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
        skip_domain = existing_prompt and existing_prompt.skip_domain or false,
        domain = existing_prompt and existing_prompt.domain or nil,
        temperature = existing_prompt and existing_prompt.temperature or nil,  -- nil = use global
        -- New format: reasoning_config (nil = global, "off" = force off, table = per-provider)
        reasoning_config = existing_prompt and existing_prompt.reasoning_config or nil,
        -- Legacy format (for backward compatibility)
        extended_thinking = existing_prompt and existing_prompt.extended_thinking or nil,
        thinking_budget = existing_prompt and existing_prompt.thinking_budget or nil,
        provider = existing_prompt and existing_prompt.provider or nil,  -- nil = use global
        model = existing_prompt and existing_prompt.model or nil,  -- nil = use global
        -- Context extraction flags (off by default for custom actions)
        use_book_text = existing_prompt and existing_prompt.use_book_text or false,
        use_highlights = existing_prompt and existing_prompt.use_highlights or false,
        use_annotations = existing_prompt and existing_prompt.use_annotations or false,
        use_reading_progress = existing_prompt and existing_prompt.use_reading_progress or false,
        use_reading_stats = existing_prompt and existing_prompt.use_reading_stats or false,
        use_notebook = existing_prompt and existing_prompt.use_notebook or false,
        -- View mode flags
        translate_view = existing_prompt and existing_prompt.translate_view or false,
        compact_view = existing_prompt and existing_prompt.compact_view or false,
        minimal_buttons = existing_prompt and existing_prompt.minimal_buttons or false,
        -- Web search (tri-state: nil/true/false)
        enable_web_search = existing_prompt and existing_prompt.enable_web_search or nil,
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
                text = checkbox .. _("Include book info"),
                callback = function()
                    state.name = self.step1_dialog:getInputText()
                    state.include_book_context = not state.include_book_context
                    UIManager:close(self.step1_dialog)
                    self:showStep1_NameAndContext(state)
                end,
            },
        })
    end

    -- Row 3: Skip language | Skip domain (two columns)
    local lang_checkbox = state.skip_language_instruction and "☑ " or "☐ "
    local domain_checkbox = state.skip_domain and "☑ " or "☐ "
    table.insert(button_rows, {
        {
            text = lang_checkbox .. _("Skip language"),
            callback = function()
                state.name = self.step1_dialog:getInputText()
                state.skip_language_instruction = not state.skip_language_instruction
                UIManager:close(self.step1_dialog)
                self:showStep1_NameAndContext(state)
            end,
        },
        {
            text = domain_checkbox .. _("Skip domain"),
            callback = function()
                state.name = self.step1_dialog:getInputText()
                state.skip_domain = not state.skip_domain
                UIManager:close(self.step1_dialog)
                self:showStep1_NameAndContext(state)
            end,
        },
    })

    -- Row 4: Add to Highlight Menu | Add to Dictionary Popup (two columns, highlight contexts only)
    if state.context and self:contextIncludesHighlight(state.context) then
        local highlight_checkbox = state.add_to_highlight_menu and "☑ " or "☐ "
        local dict_checkbox = state.add_to_dictionary_popup and "☑ " or "☐ "
        table.insert(button_rows, {
            {
                text = highlight_checkbox .. _("Highlight Menu"),
                callback = function()
                    state.name = self.step1_dialog:getInputText()
                    state.add_to_highlight_menu = not state.add_to_highlight_menu
                    UIManager:close(self.step1_dialog)
                    self:showStep1_NameAndContext(state)
                end,
            },
            {
                text = dict_checkbox .. _("Dictionary Popup"),
                callback = function()
                    state.name = self.step1_dialog:getInputText()
                    state.add_to_dictionary_popup = not state.add_to_dictionary_popup
                    UIManager:close(self.step1_dialog)
                    self:showStep1_NameAndContext(state)
                end,
            },
        })
    end

    -- Book text extraction toggle (for contexts that can run in reading mode)
    -- Note: Lightweight data (progress, highlights, annotations, stats) is auto-extracted
    if state.context and self:canUseTextExtraction(state, true) then  -- is_new_action=true
        local book_text_checkbox = state.use_book_text and "☑ " or "☐ "
        table.insert(button_rows, {
            {
                text = book_text_checkbox .. _("Allow text extraction"),
                callback = function()
                    state.name = self.step1_dialog:getInputText()
                    state.use_book_text = not state.use_book_text
                    -- Show explanation when turning on
                    if state.use_book_text then
                        local features = self.plugin.settings:readSetting("features") or {}
                        if not features.enable_book_text_extraction then
                            UIManager:show(Notification:new{
                                text = _("Text extraction enabled. Note: Enable in Settings → Advanced first."),
                                timeout = 4,
                            })
                        else
                            UIManager:show(Notification:new{
                                text = _("Text extraction enabled for this action."),
                                timeout = 2,
                            })
                        end
                    end
                    UIManager:close(self.step1_dialog)
                    self:showStep1_NameAndContext(state)
                end,
            },
        })
    end

    -- Highlight and annotation use toggles (for per-book contexts)
    if state.context and self:canUsePerBookData(state.context) then
        local highlights_locked = state.use_annotations == true
        local highlights_checkbox = highlights_locked and "☑ " or (state.use_highlights and "☑ " or "☐ ")
        local highlights_suffix = highlights_locked and " ←" or ""
        table.insert(button_rows, {
            {
                text = highlights_checkbox .. _("Allow highlight use") .. highlights_suffix,
                callback = function()
                    if highlights_locked then
                        UIManager:show(Notification:new{
                            text = _("Highlights are always on when annotations are enabled."),
                            timeout = 3,
                        })
                        return
                    end
                    state.name = self.step1_dialog:getInputText()
                    state.use_highlights = not state.use_highlights
                    if state.use_highlights then
                        local features = self.plugin.settings:readSetting("features") or {}
                        if features.enable_highlights_sharing ~= true and features.enable_annotations_sharing ~= true then
                            UIManager:show(Notification:new{
                                text = _("Highlight use enabled. Note: Enable in Settings → Privacy & Data first."),
                                timeout = 4,
                            })
                        end
                    end
                    UIManager:close(self.step1_dialog)
                    self:showStep1_NameAndContext(state)
                end,
            },
        })
        local annotation_checkbox = state.use_annotations and "☑ " or "☐ "
        table.insert(button_rows, {
            {
                text = annotation_checkbox .. _("Allow annotation use (notes)"),
                callback = function()
                    state.name = self.step1_dialog:getInputText()
                    state.use_annotations = not state.use_annotations
                    if state.use_annotations then
                        -- Annotations imply highlights
                        state.use_highlights = true
                        local features = self.plugin.settings:readSetting("features") or {}
                        if features.enable_annotations_sharing ~= true then
                            UIManager:show(Notification:new{
                                text = _("Annotation use enabled. Note: Enable in Settings → Privacy & Data first."),
                                timeout = 4,
                            })
                        end
                    end
                    UIManager:close(self.step1_dialog)
                    self:showStep1_NameAndContext(state)
                end,
            },
        })
    end

    -- Notebook use toggle (for per-book contexts)
    if state.context and self:canUsePerBookData(state.context) then
        local notebook_checkbox = state.use_notebook and "☑ " or "☐ "
        table.insert(button_rows, {
            {
                text = notebook_checkbox .. _("Allow notebook use"),
                callback = function()
                    state.name = self.step1_dialog:getInputText()
                    state.use_notebook = not state.use_notebook
                    if state.use_notebook then
                        local features = self.plugin.settings:readSetting("features") or {}
                        if features.enable_notebook_sharing ~= true then
                            UIManager:show(Notification:new{
                                text = _("Notebook use enabled. Note: Enable in Settings → Privacy & Data first."),
                                timeout = 4,
                            })
                        else
                            UIManager:show(Notification:new{
                                text = _("Notebook use enabled for this action."),
                                timeout = 2,
                            })
                        end
                    end
                    UIManager:close(self.step1_dialog)
                    self:showStep1_NameAndContext(state)
                end,
            },
        })
    end

    -- View mode selector (for highlight contexts - affects result display)
    if state.context and self:contextIncludesHighlight(state.context) then
        table.insert(button_rows, {
            {
                text = _("View: ") .. self:getViewModeDisplayText(state),
                callback = function()
                    state.name = self.step1_dialog:getInputText()
                    self.step1_dialog:onCloseKeyboard()
                    self:showViewModeSelector(state, function()
                        UIManager:close(self.step1_dialog)
                        self:showStep1_NameAndContext(state)
                    end)
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
            desc = _("File browser selection or 'New Book Chat/Action' gesture"),
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
    return context == "highlight" or context == "both" or context == "both+general" or context == "highlight+general"
end

-- Check if a context includes book context (where context extraction flags apply)
function PromptsManager:contextIncludesBook(context)
    return context == "book" or context == "both" or context == "both+general" or context == "book+general"
end

-- Check if a context can use per-book data (annotations, notebook)
-- These are single-book contexts where per-book data gates make sense
function PromptsManager:canUsePerBookData(context)
    return context == "highlight" or context == "book" or context == "both"
        or context == "both+general" or context == "highlight+general" or context == "book+general"
end

-- Determine if an action can use text extraction (runs in reading mode)
-- Used to show/hide the "Allow text extraction" toggle in action settings
-- @param action_or_context: Action table, state table, or context string
-- @param is_new_action: boolean, true if creating a new action (more permissive)
-- @return boolean: true if text extraction toggle should be shown
function PromptsManager:canUseTextExtraction(action_or_context, is_new_action)
    local context, action
    if type(action_or_context) == "table" then
        context = action_or_context.context
        action = action_or_context
    else
        context = action_or_context
        action = nil
    end

    -- Highlight context: always in reading mode (can't highlight without open book)
    if context == "highlight" or context == "highlight+general" then
        return true
    end

    -- "both" context: includes highlight, always in reading mode
    if context == "both" or context == "both+general" then
        return true
    end

    -- Book context: depends on whether action requires open book
    if context == "book" or context == "book+general" then
        if is_new_action then
            -- New custom actions: show toggle (user may add text placeholders)
            return true
        elseif action then
            -- Existing actions: only if it requires reading mode
            return Actions.requiresOpenBook(action)
        end
        return false
    end

    -- "multi_book", "general": cannot reliably extract text
    return false
end

-- Get default system prompt for a context
-- For compound contexts (both), returns nil since the actual default varies by trigger
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
    }

    local buttons = {}

    for _idx,option in ipairs(context_options) do
        local info = self:getContextInfo(option.value, state.include_book_context)
        local prefix = (state.context == option.value) and "● " or "○ "
        table.insert(buttons, {
            {
                text = prefix .. info.text,
                callback = function()
                    state.context = option.value
                    UIManager:close(self.context_dialog)
                    self:showStep1_NameAndContext(state)
                end,
            },
        })
    end

    -- Info button
    table.insert(buttons, {
        {
            text = "ⓘ " .. _("Info"),
            callback = function()
                local InfoMessage = require("ui/widget/infomessage")
                UIManager:show(InfoMessage:new{
                    text = _("Context determines when your action appears and what data is available:") .. "\n\n" ..
                           "• " .. _("Highlight") .. " — " .. _("When text is selected. Gets: selected text, optionally book info") .. "\n\n" ..
                           "• " .. _("Book") .. " — " .. _("File browser or 'New Book Chat/Action'. Gets: title, author") .. "\n\n" ..
                           "• " .. _("Multi-Book") .. " — " .. _("Multiple books selected. Gets: book list with count") .. "\n\n" ..
                           "• " .. _("General") .. " — " .. _("Standalone chat. No automatic context") .. "\n\n" ..
                           "• " .. _("Highlight & Book") .. " — " .. _("Both highlight and single-book menus"),
                })
            end,
        },
    })

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
        { id = "global", text = _("Use global setting"), desc = _("Inherits from Actions & Prompts → Manage Behaviors") },
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

    local dialog
    dialog = InputDialog:new{
        title = is_edit and _("Edit Action - Action Prompt") or _("Step 3/4: Action Prompt"),
        input = state.prompt or "",
        input_hint = _("What should the AI do?"),
        description = _("Write the AI instruction. Tap 'Help' for tips, 'Insert...' for placeholders."),
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
                    text = _("Help"),
                    callback = function()
                        UIManager:show(InfoMessage:new{
                            text = _([[Writing Action Prompts

• Use 'Insert...' to add placeholders like {title}, {author}, {highlighted_text}

• Tip: When using this action, there's an input field for optional additional context

• Reading-mode placeholders ({reading_progress}, {book_text}, {highlights}, {annotations}) auto-hide this action in File Browser — it only appears when reading

• Test actions with the web inspector: 'lua tests/inspect.lua --web' from the plugin folder

• See README for full placeholder list and examples]]),
                        })
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
        -- Row 4: Web Search
        {
            {
                text = _("Web Search:") .. " " .. (state.enable_web_search == true and _("Always")
                    or state.enable_web_search == false and _("Never")
                    or _("Global")),
                callback = function()
                    self:showWebSearchSelector(state, function()
                        UIManager:close(self.advanced_dialog)
                        self:showStep4_Advanced(state)
                    end)
                end,
            },
        },
        -- Row 5: Back / Save
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

-- Get display text for current view mode
function PromptsManager:getViewModeDisplayText(state)
    if state.translate_view then
        return _("Translate")
    elseif state.compact_view then
        return _("Dictionary Compact")
    else
        return _("Standard")
    end
end

-- View mode selector dialog
-- @param state: Action state being edited
-- @param refresh_callback: Callback to refresh the parent dialog after selection
function PromptsManager:showViewModeSelector(state, refresh_callback)
    local view_modes = {
        { id = "standard", text = _("Standard"), desc = _("Full dialog with all buttons") },
        { id = "compact", text = _("Dictionary Compact"), desc = _("Compact with language buttons") },
        { id = "translate", text = _("Translate"), desc = _("With language switch and original toggle") },
    }

    -- Determine current selection
    local current = "standard"
    if state.translate_view then
        current = "translate"
    elseif state.compact_view then
        current = "compact"
    end

    local buttons = {}

    for _idx, mode in ipairs(view_modes) do
        local prefix = (current == mode.id) and "● " or "○ "
        table.insert(buttons, {
            {
                text = prefix .. mode.text,
                callback = function()
                    UIManager:close(self.view_mode_dialog)
                    -- Reset all view flags
                    state.translate_view = false
                    state.compact_view = false
                    state.minimal_buttons = false
                    -- Set based on selection
                    if mode.id == "compact" then
                        state.compact_view = true
                        state.minimal_buttons = true
                    elseif mode.id == "translate" then
                        state.translate_view = true
                    end
                    -- Refresh parent dialog
                    if refresh_callback then
                        refresh_callback()
                    end
                end,
            },
        })
    end

    -- Info button
    table.insert(buttons, {
        {
            text = "ⓘ " .. _("Info"),
            callback = function()
                local InfoMessage = require("ui/widget/infomessage")
                UIManager:show(InfoMessage:new{
                    text = _("View modes control how results are displayed:") .. "\n\n" ..
                           "• " .. _("Standard") .. " — " .. _("Full dialog with all response action buttons") .. "\n\n" ..
                           "• " .. _("Dictionary Compact") .. " — " .. _("Smaller dialog optimized for quick lookups, with language buttons for word-by-word translation") .. "\n\n" ..
                           "• " .. _("Translate") .. " — " .. _("Translation view with language switch button and toggle to show/hide the original text"),
                })
            end,
        },
    })

    -- Cancel button
    table.insert(buttons, {
        {
            text = _("Cancel"),
            callback = function()
                UIManager:close(self.view_mode_dialog)
                -- Restore parent dialog with keyboard
                if refresh_callback then
                    refresh_callback()
                end
            end,
        },
    })

    self.view_mode_dialog = ButtonDialog:new{
        title = _("View Mode"),
        buttons = buttons,
    }

    UIManager:show(self.view_mode_dialog)
end

-- Web search selector dialog (shared between builtin and custom editors)
-- @param state: Action state being edited (state.enable_web_search: nil/true/false)
-- @param refresh_callback: Callback to refresh the parent dialog
function PromptsManager:showWebSearchSelector(state, refresh_callback)
    local options = {
        { value = "global", text = _("Follow global setting"), desc = _("Uses your web search setting from AI Response Settings") },
        { value = true, text = _("Always use web search"), desc = _("Force web search on, even if global setting is off") },
        { value = false, text = _("Never use web search"), desc = _("Force web search off, even if global setting is on") },
    }

    -- Map current state to option value
    local current
    if state.enable_web_search == true then
        current = true
    elseif state.enable_web_search == false then
        current = false
    else
        current = "global"
    end

    local buttons = {}

    for _idx, opt in ipairs(options) do
        local is_selected = current == opt.value
        table.insert(buttons, {
            {
                text = (is_selected and "● " or "○ ") .. opt.text,
                callback = function()
                    -- Convert back to tri-state
                    if opt.value == "global" then
                        state.enable_web_search = nil
                    else
                        state.enable_web_search = opt.value
                    end
                    UIManager:close(self.web_search_dialog)
                    if refresh_callback then
                        refresh_callback()
                    end
                end,
            },
        })
    end

    -- Cancel button
    table.insert(buttons, {
        {
            text = _("Cancel"),
            callback = function()
                UIManager:close(self.web_search_dialog)
                if refresh_callback then
                    refresh_callback()
                end
            end,
        },
    })

    self.web_search_dialog = ButtonDialog:new{
        title = _("Web Search"),
        buttons = buttons,
    }

    UIManager:show(self.web_search_dialog)
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
            return T(_("ON (%1 tokens)"), cfg.budget)
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
        info_text = T(_("Token budget for extended thinking.\nHigher = more complex reasoning.\nRange: %1 - %2"),
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
        info_text = T(_("Token budget for reasoning (Anthropic).\nHigher = more complex reasoning.\nRange: %1 - %2"),
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
    local ModelLists = require("koassistant_model_lists")

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
    local ModelLists = require("koassistant_model_lists")

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
    -- Get base action values (from Actions.lua, without overrides)
    -- Actions is already required at file top
    local base_action = Actions.getById(prompt.id)
    local base_skip_lang = base_action and base_action.skip_language_instruction or false
    local base_skip_domain = base_action and base_action.skip_domain or false
    local base_include_book_context = base_action and base_action.include_book_context or false

    -- Get base action extraction flags for comparison
    local base_use_book_text = base_action and base_action.use_book_text or false
    local base_use_highlights = base_action and base_action.use_highlights or false
    local base_use_annotations = base_action and base_action.use_annotations or false
    local base_use_reading_progress = base_action and base_action.use_reading_progress or false
    local base_use_reading_stats = base_action and base_action.use_reading_stats or false
    local base_use_notebook = base_action and base_action.use_notebook or false

    -- Get base view mode flags for comparison
    local base_translate_view = base_action and base_action.translate_view or false
    local base_compact_view = base_action and base_action.compact_view or false
    local base_minimal_buttons = base_action and base_action.minimal_buttons or false

    -- Get base web search setting (tri-state: nil/true/false)
    local base_enable_web_search = base_action and base_action.enable_web_search

    -- Initialize state from current prompt values
    local state = {
        prompt = prompt,  -- Reference to the original prompt
        behavior_variant = prompt.behavior_variant,
        behavior_override = prompt.behavior_override or "",
        temperature = prompt.temperature,
        skip_language_instruction = prompt.skip_language_instruction or false,
        skip_language_instruction_base = base_skip_lang,  -- Track base for comparison on save
        skip_domain = prompt.skip_domain or false,
        skip_domain_base = base_skip_domain,  -- Track base for comparison on save
        include_book_context = prompt.include_book_context or false,
        include_book_context_base = base_include_book_context,
        -- New format: reasoning_config
        reasoning_config = prompt.reasoning_config,
        -- Legacy format (backward compatibility)
        extended_thinking = prompt.extended_thinking,
        thinking_budget = prompt.thinking_budget,
        provider = prompt.provider,
        model = prompt.model,
        -- Context extraction flags
        use_book_text = prompt.use_book_text or false,
        use_book_text_base = base_use_book_text,
        use_highlights = prompt.use_highlights or false,
        use_highlights_base = base_use_highlights,
        use_annotations = prompt.use_annotations or false,
        use_annotations_base = base_use_annotations,
        use_reading_progress = prompt.use_reading_progress or false,
        use_reading_progress_base = base_use_reading_progress,
        use_reading_stats = prompt.use_reading_stats or false,
        use_reading_stats_base = base_use_reading_stats,
        use_notebook = prompt.use_notebook or false,
        use_notebook_base = base_use_notebook,
        -- View mode flags
        translate_view = prompt.translate_view or false,
        translate_view_base = base_translate_view,
        compact_view = prompt.compact_view or false,
        compact_view_base = base_compact_view,
        minimal_buttons = prompt.minimal_buttons or false,
        minimal_buttons_base = base_minimal_buttons,
        -- Web search (tri-state: nil/true/false)
        enable_web_search = prompt.enable_web_search,
        enable_web_search_base = base_enable_web_search,
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

    local buttons = {}

    -- Collect all items, then lay out 2 per row
    -- Options first, then checkboxes
    local items = {}

    -- Options
    table.insert(items, {
        text = _("AI Behavior: ") .. behavior_display,
        callback = function()
            UIManager:close(self.builtin_settings_dialog)
            self:showBuiltinBehaviorSelector(state)
        end,
    })

    table.insert(items, {
        text = _("Temp: ") .. temp_display,
        callback = function()
            self:showBuiltinTemperatureSelector(state)
        end,
    })

    table.insert(items, {
        text = _("Reasoning: ") .. thinking_display,
        callback = function()
            self:showThinkingSelector(state)  -- Use shared dialog
        end,
    })

    -- Web search setting (tri-state)
    local web_display = state.enable_web_search == true and _("Always")
        or state.enable_web_search == false and _("Never")
        or _("Global")
    table.insert(items, {
        text = _("Web:") .. " " .. web_display,
        callback = function()
            self:showWebSearchSelector(state, function()
                UIManager:close(self.builtin_settings_dialog)
                self:showBuiltinSettingsDialog(state)
            end)
        end,
    })

    table.insert(items, {
        text = _("Provider: ") .. provider_display,
        callback = function()
            self:showBuiltinProviderSelector(state)
        end,
    })

    table.insert(items, {
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
    })

    if self:contextIncludesHighlight(prompt.context) then
        table.insert(items, {
            text = _("View: ") .. self:getViewModeDisplayText(state),
            callback = function()
                self:showViewModeSelector(state, function()
                    UIManager:close(self.builtin_settings_dialog)
                    self:showBuiltinSettingsDialog(state)
                end)
            end,
        })
    end

    -- Checkboxes
    table.insert(items, {
        text = (state.skip_language_instruction and "☑ " or "☐ ") .. _("Skip language"),
        callback = function()
            state.skip_language_instruction = not state.skip_language_instruction
            UIManager:close(self.builtin_settings_dialog)
            self:showBuiltinSettingsDialog(state)
        end,
    })

    table.insert(items, {
        text = (state.skip_domain and "☑ " or "☐ ") .. _("Skip domain"),
        callback = function()
            state.skip_domain = not state.skip_domain
            UIManager:close(self.builtin_settings_dialog)
            self:showBuiltinSettingsDialog(state)
        end,
    })

    if self:contextIncludesHighlight(prompt.context) then
        table.insert(items, {
            text = (state.include_book_context and "☑ " or "☐ ") .. _("Include book info"),
            callback = function()
                state.include_book_context = not state.include_book_context
                UIManager:close(self.builtin_settings_dialog)
                self:showBuiltinSettingsDialog(state)
            end,
        })
    end

    if self:canUseTextExtraction(prompt) then
        table.insert(items, {
            text = (state.use_book_text and "☑ " or "☐ ") .. _("Allow text extraction"),
            callback = function()
                state.use_book_text = not state.use_book_text
                if state.use_book_text then
                    local features = self.plugin.settings:readSetting("features") or {}
                    if not features.enable_book_text_extraction then
                        UIManager:show(Notification:new{
                            text = _("Text extraction enabled. Note: Enable in Settings → Advanced first."),
                            timeout = 4,
                        })
                    else
                        UIManager:show(Notification:new{
                            text = _("Text extraction enabled for this action."),
                            timeout = 2,
                        })
                    end
                end
                UIManager:close(self.builtin_settings_dialog)
                self:showBuiltinSettingsDialog(state)
            end,
        })
    end

    if prompt.context and self:canUsePerBookData(prompt.context) then
        local hl_locked = state.use_annotations == true
        local hl_checkbox = hl_locked and "☑ " or (state.use_highlights and "☑ " or "☐ ")
        local hl_suffix = hl_locked and " ←" or ""
        table.insert(items, {
            text = hl_checkbox .. _("Allow highlight use") .. hl_suffix,
            callback = function()
                if hl_locked then
                    UIManager:show(Notification:new{
                        text = _("Highlights are always on when annotations are enabled."),
                        timeout = 3,
                    })
                    return
                end
                state.use_highlights = not state.use_highlights
                if state.use_highlights then
                    local features = self.plugin.settings:readSetting("features") or {}
                    if features.enable_highlights_sharing ~= true and features.enable_annotations_sharing ~= true then
                        UIManager:show(Notification:new{
                            text = _("Highlight use enabled. Note: Enable in Settings → Privacy & Data first."),
                            timeout = 4,
                        })
                    end
                end
                UIManager:close(self.builtin_settings_dialog)
                self:showBuiltinSettingsDialog(state)
            end,
        })
        table.insert(items, {
            text = (state.use_annotations and "☑ " or "☐ ") .. _("Allow annotation use (notes)"),
            callback = function()
                state.use_annotations = not state.use_annotations
                if state.use_annotations then
                    state.use_highlights = true
                    local features = self.plugin.settings:readSetting("features") or {}
                    if features.enable_annotations_sharing ~= true then
                        UIManager:show(Notification:new{
                            text = _("Annotation use enabled. Note: Enable in Settings → Privacy & Data first."),
                            timeout = 4,
                        })
                    end
                end
                UIManager:close(self.builtin_settings_dialog)
                self:showBuiltinSettingsDialog(state)
            end,
        })

        table.insert(items, {
            text = (state.use_notebook and "☑ " or "☐ ") .. _("Allow notebook use"),
            callback = function()
                state.use_notebook = not state.use_notebook
                if state.use_notebook then
                    local features = self.plugin.settings:readSetting("features") or {}
                    if features.enable_notebook_sharing ~= true then
                        UIManager:show(Notification:new{
                            text = _("Notebook use enabled. Note: Enable in Settings → Privacy & Data first."),
                            timeout = 4,
                        })
                    else
                        UIManager:show(Notification:new{
                            text = _("Notebook use enabled for this action."),
                            timeout = 2,
                        })
                    end
                end
                UIManager:close(self.builtin_settings_dialog)
                self:showBuiltinSettingsDialog(state)
            end,
        })
    end

    -- Add items in rows of 2
    for i = 1, #items, 2 do
        if items[i + 1] then
            table.insert(buttons, { items[i], items[i + 1] })
        else
            table.insert(buttons, { items[i] })
        end
    end

    -- Cancel / Help / Save row
    table.insert(buttons, {
        {
            text = _("Cancel"),
            callback = function()
                UIManager:close(self.builtin_settings_dialog)
            end,
        },
        {
            text = _("Help"),
            callback = function()
                UIManager:show(InfoMessage:new{
                    text = _([[These settings override the defaults for this built-in action.

Set to "Global" to use the default setting.

Tip: To edit the action prompt, use 'Duplicate' to create a custom copy.]]),
                })
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
    })

    self.builtin_settings_dialog = ButtonDialog:new{
        title = T(_("Edit Built-in: %1"), prompt.text),
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
    local ModelLists = require("koassistant_model_lists")

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
    local ModelLists = require("koassistant_model_lists")

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
    -- Save skip_domain if it differs from the base action's default
    local base_skip_domain = state.skip_domain_base or false
    if state.skip_domain ~= base_skip_domain then
        override.skip_domain = state.skip_domain
        has_any = true
    end
    -- Save include_book_context if it differs from the base action's default
    local base_include_book_context = state.include_book_context_base or false
    if state.include_book_context ~= base_include_book_context then
        override.include_book_context = state.include_book_context
        has_any = true
    end

    -- Save context extraction flags if they differ from base
    if state.use_book_text ~= (state.use_book_text_base or false) then
        override.use_book_text = state.use_book_text
        has_any = true
    end
    if state.use_highlights ~= (state.use_highlights_base or false) then
        override.use_highlights = state.use_highlights
        has_any = true
    end
    if state.use_annotations ~= (state.use_annotations_base or false) then
        override.use_annotations = state.use_annotations
        has_any = true
    end
    if state.use_reading_progress ~= (state.use_reading_progress_base or false) then
        override.use_reading_progress = state.use_reading_progress
        has_any = true
    end
    if state.use_reading_stats ~= (state.use_reading_stats_base or false) then
        override.use_reading_stats = state.use_reading_stats
        has_any = true
    end
    if state.use_notebook ~= (state.use_notebook_base or false) then
        override.use_notebook = state.use_notebook
        has_any = true
    end

    -- Save enable_web_search if it differs from base (tri-state: nil/true/false)
    -- Use "global" sentinel to represent overriding to nil (follow global)
    if state.enable_web_search ~= state.enable_web_search_base then
        if state.enable_web_search == nil then
            override.enable_web_search = "global"  -- Sentinel: reset to follow global
        else
            override.enable_web_search = state.enable_web_search
        end
        has_any = true
    end

    -- Save view mode flags if they differ from base
    if state.translate_view ~= (state.translate_view_base or false) then
        override.translate_view = state.translate_view
        has_any = true
    end
    if state.compact_view ~= (state.compact_view_base or false) then
        override.compact_view = state.compact_view
        has_any = true
    end
    if state.minimal_buttons ~= (state.minimal_buttons_base or false) then
        override.minimal_buttons = state.minimal_buttons
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

-- Quick settings editor for custom (UI-created) actions
-- Shows a single dialog for quick edits, with option to go to full wizard
function PromptsManager:showCustomQuickSettings(prompt)
    -- Initialize state from current prompt values
    local state = {
        prompt_ref = prompt,  -- Reference to the original prompt
        name = prompt.text or "",
        behavior_variant = prompt.behavior_variant,
        behavior_override = prompt.behavior_override or "",
        prompt = prompt.prompt or "",
        context = prompt.context,
        include_book_context = prompt.include_book_context or false,
        skip_language_instruction = prompt.skip_language_instruction or false,
        skip_domain = prompt.skip_domain or false,
        domain = prompt.domain,
        temperature = prompt.temperature,
        reasoning_config = prompt.reasoning_config,
        extended_thinking = prompt.extended_thinking,
        thinking_budget = prompt.thinking_budget,
        provider = prompt.provider,
        model = prompt.model,
        use_book_text = prompt.use_book_text or false,
        use_highlights = prompt.use_highlights or false,
        use_annotations = prompt.use_annotations or false,
        use_reading_progress = prompt.use_reading_progress or false,
        use_reading_stats = prompt.use_reading_stats or false,
        use_notebook = prompt.use_notebook or false,
        -- View mode flags
        translate_view = prompt.translate_view or false,
        compact_view = prompt.compact_view or false,
        minimal_buttons = prompt.minimal_buttons or false,
        -- Web search (tri-state: nil/true/false)
        enable_web_search = prompt.enable_web_search,
        existing_prompt = prompt,  -- For updatePrompt compatibility
    }

    self:showCustomQuickSettingsDialog(state)
end

-- The actual dialog for custom action quick settings
function PromptsManager:showCustomQuickSettingsDialog(state)
    local prompt = state.prompt_ref

    -- Behavior display
    local behavior_display
    if state.behavior_override and state.behavior_override ~= "" then
        behavior_display = _("Custom")
    elseif state.behavior_variant == "none" then
        behavior_display = _("None")
    elseif state.behavior_variant then
        local behavior = SystemPrompts.getBehaviorById(state.behavior_variant, nil)
        if behavior then
            behavior_display = behavior.name
        else
            behavior_display = state.behavior_variant
        end
    else
        behavior_display = _("Global")
    end

    -- Temperature display
    local temp_display = state.temperature and string.format("%.1f", state.temperature) or _("Global")

    -- Reasoning display
    local thinking_display = self:getStateReasoningDisplayText(state)

    -- Provider/model display
    local provider_display = state.provider or _("Global")
    local model_display = state.model or _("Global")

    local buttons = {
        -- Name (editable, full width)
        {
            {
                text = _("Name: ") .. state.name,
                callback = function()
                    UIManager:close(self.custom_quick_dialog)
                    self:showCustomNameEditor(state)
                end,
            },
        },
    }

    -- Collect all items after Name, then lay out 2 per row
    -- Options first, then checkboxes
    local items = {}

    -- Options
    table.insert(items, {
        text = _("AI Behavior: ") .. behavior_display,
        callback = function()
            UIManager:close(self.custom_quick_dialog)
            self:showCustomBehaviorQuickSelector(state)
        end,
    })

    table.insert(items, {
        text = _("Temp: ") .. temp_display,
        callback = function()
            self:showCustomTemperatureSelector(state)
        end,
    })

    table.insert(items, {
        text = _("Reasoning: ") .. thinking_display,
        callback = function()
            self:showThinkingSelector(state, function()
                UIManager:close(self.custom_quick_dialog)
                self:showCustomQuickSettingsDialog(state)
            end)
        end,
    })

    -- Web search setting (tri-state)
    local custom_web_display = state.enable_web_search == true and _("Always")
        or state.enable_web_search == false and _("Never")
        or _("Global")
    table.insert(items, {
        text = _("Web:") .. " " .. custom_web_display,
        callback = function()
            self:showWebSearchSelector(state, function()
                UIManager:close(self.custom_quick_dialog)
                self:showCustomQuickSettingsDialog(state)
            end)
        end,
    })

    table.insert(items, {
        text = _("Provider: ") .. provider_display,
        callback = function()
            self:showCustomProviderSelector(state)
        end,
    })

    table.insert(items, {
        text = _("Model: ") .. model_display,
        callback = function()
            if not state.provider then
                UIManager:show(InfoMessage:new{
                    text = _("Please select a provider first"),
                })
                return
            end
            self:showCustomModelSelector(state)
        end,
    })

    if self:contextIncludesHighlight(state.context) then
        table.insert(items, {
            text = _("View: ") .. self:getViewModeDisplayText(state),
            callback = function()
                self:showViewModeSelector(state, function()
                    UIManager:close(self.custom_quick_dialog)
                    self:showCustomQuickSettingsDialog(state)
                end)
            end,
        })
    end

    -- Checkboxes
    table.insert(items, {
        text = (state.skip_language_instruction and "☑ " or "☐ ") .. _("Skip language"),
        callback = function()
            state.skip_language_instruction = not state.skip_language_instruction
            UIManager:close(self.custom_quick_dialog)
            self:showCustomQuickSettingsDialog(state)
        end,
    })

    table.insert(items, {
        text = (state.skip_domain and "☑ " or "☐ ") .. _("Skip domain"),
        callback = function()
            state.skip_domain = not state.skip_domain
            UIManager:close(self.custom_quick_dialog)
            self:showCustomQuickSettingsDialog(state)
        end,
    })

    if self:contextIncludesHighlight(state.context) then
        table.insert(items, {
            text = (state.include_book_context and "☑ " or "☐ ") .. _("Include book info"),
            callback = function()
                state.include_book_context = not state.include_book_context
                UIManager:close(self.custom_quick_dialog)
                self:showCustomQuickSettingsDialog(state)
            end,
        })
    end

    if self:canUseTextExtraction(state) then
        table.insert(items, {
            text = (state.use_book_text and "☑ " or "☐ ") .. _("Allow text extraction"),
            callback = function()
                state.use_book_text = not state.use_book_text
                if state.use_book_text then
                    local features = self.plugin.settings:readSetting("features") or {}
                    if not features.enable_book_text_extraction then
                        UIManager:show(Notification:new{
                            text = _("Text extraction enabled. Note: Enable in Settings → Advanced first."),
                            timeout = 4,
                        })
                    else
                        UIManager:show(Notification:new{
                            text = _("Text extraction enabled for this action."),
                            timeout = 2,
                        })
                    end
                end
                UIManager:close(self.custom_quick_dialog)
                self:showCustomQuickSettingsDialog(state)
            end,
        })
    end

    if state.context and self:canUsePerBookData(state.context) then
        local hl_locked = state.use_annotations == true
        local hl_checkbox = hl_locked and "☑ " or (state.use_highlights and "☑ " or "☐ ")
        local hl_suffix = hl_locked and " ←" or ""
        table.insert(items, {
            text = hl_checkbox .. _("Allow highlight use") .. hl_suffix,
            callback = function()
                if hl_locked then
                    UIManager:show(Notification:new{
                        text = _("Highlights are always on when annotations are enabled."),
                        timeout = 3,
                    })
                    return
                end
                state.use_highlights = not state.use_highlights
                if state.use_highlights then
                    local features = self.plugin.settings:readSetting("features") or {}
                    if features.enable_highlights_sharing ~= true and features.enable_annotations_sharing ~= true then
                        UIManager:show(Notification:new{
                            text = _("Highlight use enabled. Note: Enable in Settings → Privacy & Data first."),
                            timeout = 4,
                        })
                    end
                end
                UIManager:close(self.custom_quick_dialog)
                self:showCustomQuickSettingsDialog(state)
            end,
        })
        table.insert(items, {
            text = (state.use_annotations and "☑ " or "☐ ") .. _("Allow annotation use (notes)"),
            callback = function()
                state.use_annotations = not state.use_annotations
                if state.use_annotations then
                    state.use_highlights = true
                    local features = self.plugin.settings:readSetting("features") or {}
                    if features.enable_annotations_sharing ~= true then
                        UIManager:show(Notification:new{
                            text = _("Annotation use enabled. Note: Enable in Settings → Privacy & Data first."),
                            timeout = 4,
                        })
                    end
                end
                UIManager:close(self.custom_quick_dialog)
                self:showCustomQuickSettingsDialog(state)
            end,
        })

        table.insert(items, {
            text = (state.use_notebook and "☑ " or "☐ ") .. _("Allow notebook use"),
            callback = function()
                state.use_notebook = not state.use_notebook
                if state.use_notebook then
                    local features = self.plugin.settings:readSetting("features") or {}
                    if features.enable_notebook_sharing ~= true then
                        UIManager:show(Notification:new{
                            text = _("Notebook use enabled. Note: Enable in Settings → Privacy & Data first."),
                            timeout = 4,
                        })
                    else
                        UIManager:show(Notification:new{
                            text = _("Notebook use enabled for this action."),
                            timeout = 2,
                        })
                    end
                end
                UIManager:close(self.custom_quick_dialog)
                self:showCustomQuickSettingsDialog(state)
            end,
        })
    end

    -- Add items in rows of 2
    for i = 1, #items, 2 do
        if items[i + 1] then
            table.insert(buttons, { items[i], items[i + 1] })
        else
            table.insert(buttons, { items[i] })
        end
    end

    -- Action row: Cancel | Full Editor | Save
    table.insert(buttons, {
        {
            text = _("Cancel"),
            callback = function()
                UIManager:close(self.custom_quick_dialog)
            end,
        },
        {
            text = _("Full Editor"),
            callback = function()
                UIManager:close(self.custom_quick_dialog)
                -- Go to full wizard with current state
                self:showPromptEditor(state.existing_prompt)
            end,
        },
        {
            text = _("Save"),
            callback = function()
                UIManager:close(self.custom_quick_dialog)
                self:updatePrompt(state.existing_prompt, state)
                self:refreshMenu()
            end,
        },
    })

    local info = T(_([[Quick edit: %1

For name, context, or prompt text changes, use Full Editor.]]), state.name)

    self.custom_quick_dialog = ButtonDialog:new{
        title = _("Edit Custom Action"),
        info_text = info,
        buttons = buttons,
    }

    UIManager:show(self.custom_quick_dialog)
end

-- Name editor for custom quick settings
function PromptsManager:showCustomNameEditor(state)
    local dialog
    dialog = InputDialog:new{
        title = _("Action Name"),
        input = state.name,
        input_hint = _("Enter action name"),
        buttons = {
            {
                {
                    text = _("Cancel"),
                    id = "close",
                    callback = function()
                        UIManager:close(dialog)
                        self:showCustomQuickSettingsDialog(state)
                    end,
                },
                {
                    text = _("OK"),
                    callback = function()
                        local name = dialog:getInputText()
                        if name and name ~= "" then
                            state.name = name
                        end
                        UIManager:close(dialog)
                        self:showCustomQuickSettingsDialog(state)
                    end,
                },
            },
        },
    }
    UIManager:show(dialog)
    dialog:onShowKeyboard()
end

-- Behavior selector for custom quick settings (reuses builtin behavior logic)
function PromptsManager:showCustomBehaviorQuickSelector(state)
    -- Reuse the builtin behavior selector, just change the return path
    local current_selection = "global"
    if state.behavior_override and state.behavior_override ~= "" then
        current_selection = "custom"
    elseif state.behavior_variant == "none" then
        current_selection = "none"
    elseif isBuiltinBehavior(state.behavior_variant) then
        current_selection = state.behavior_variant
    end

    local buttons = {}

    -- Global option
    table.insert(buttons, {
        {
            text = (current_selection == "global" and "● " or "○ ") .. _("Global (use setting)"),
            callback = function()
                state.behavior_variant = nil
                state.behavior_override = ""
                UIManager:close(self.custom_behavior_dialog)
                self:showCustomQuickSettingsDialog(state)
            end,
        },
    })

    -- None option
    table.insert(buttons, {
        {
            text = (current_selection == "none" and "● " or "○ ") .. _("None (no behavior)"),
            callback = function()
                state.behavior_variant = "none"
                state.behavior_override = ""
                UIManager:close(self.custom_behavior_dialog)
                self:showCustomQuickSettingsDialog(state)
            end,
        },
    })

    -- Built-in behaviors
    local builtin_options = getBuiltinBehaviorOptions()
    for _idx, opt in ipairs(builtin_options) do
        local is_selected = current_selection == opt.id
        table.insert(buttons, {
            {
                text = (is_selected and "● " or "○ ") .. opt.text .. " (" .. opt.desc .. ")",
                callback = function()
                    state.behavior_variant = opt.id
                    state.behavior_override = ""
                    UIManager:close(self.custom_behavior_dialog)
                    self:showCustomQuickSettingsDialog(state)
                end,
            },
        })
    end

    -- Custom option
    table.insert(buttons, {
        {
            text = (current_selection == "custom" and "● " or "○ ") .. _("Custom behavior..."),
            callback = function()
                UIManager:close(self.custom_behavior_dialog)
                self:showCustomBehaviorQuickInput(state)
            end,
        },
    })

    -- Cancel
    table.insert(buttons, {
        {
            text = _("Cancel"),
            callback = function()
                UIManager:close(self.custom_behavior_dialog)
                self:showCustomQuickSettingsDialog(state)
            end,
        },
    })

    self.custom_behavior_dialog = ButtonDialog:new{
        title = _("Select AI Behavior"),
        buttons = buttons,
    }
    UIManager:show(self.custom_behavior_dialog)
end

-- Custom behavior input for custom quick settings
function PromptsManager:showCustomBehaviorQuickInput(state)
    local dialog
    dialog = InputDialog:new{
        title = _("Custom AI Behavior"),
        input = state.behavior_override or "",
        input_hint = _("Enter custom behavior instructions..."),
        input_type = "text",
        allow_newline = true,
        buttons = {
            {
                {
                    text = _("Cancel"),
                    id = "close",
                    callback = function()
                        UIManager:close(dialog)
                        self:showCustomBehaviorQuickSelector(state)
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
                        self:showCustomQuickSettingsDialog(state)
                    end,
                },
            },
        },
    }
    UIManager:show(dialog)
    dialog:onShowKeyboard()
end

-- Temperature selector for custom quick settings
function PromptsManager:showCustomTemperatureSelector(state)
    local buttons = {}

    -- Global option
    table.insert(buttons, {
        {
            text = (state.temperature == nil and "● " or "○ ") .. _("Global (use setting)"),
            callback = function()
                state.temperature = nil
                UIManager:close(self.custom_temp_dialog)
                UIManager:close(self.custom_quick_dialog)
                self:showCustomQuickSettingsDialog(state)
            end,
        },
    })

    -- Temperature presets
    local temps = { 0.0, 0.3, 0.5, 0.7, 1.0 }
    for _idx, temp in ipairs(temps) do
        local is_selected = state.temperature == temp
        table.insert(buttons, {
            {
                text = (is_selected and "● " or "○ ") .. string.format("%.1f", temp),
                callback = function()
                    state.temperature = temp
                    UIManager:close(self.custom_temp_dialog)
                    UIManager:close(self.custom_quick_dialog)
                    self:showCustomQuickSettingsDialog(state)
                end,
            },
        })
    end

    -- Cancel
    table.insert(buttons, {
        {
            text = _("Cancel"),
            callback = function()
                UIManager:close(self.custom_temp_dialog)
            end,
        },
    })

    self.custom_temp_dialog = ButtonDialog:new{
        title = _("Select Temperature"),
        buttons = buttons,
    }
    UIManager:show(self.custom_temp_dialog)
end

-- Provider selector for custom quick settings
function PromptsManager:showCustomProviderSelector(state)
    local ModelLists = require("koassistant_model_lists")
    local buttons = {}

    -- Global option
    table.insert(buttons, {
        {
            text = (state.provider == nil and "● " or "○ ") .. _("Global (use setting)"),
            callback = function()
                state.provider = nil
                state.model = nil
                UIManager:close(self.custom_provider_dialog)
                UIManager:close(self.custom_quick_dialog)
                self:showCustomQuickSettingsDialog(state)
            end,
        },
    })

    -- Provider list
    local providers = ModelLists.getAllProvidersWithCustom(self.plugin.settings)
    for _idx, provider in ipairs(providers) do
        local is_selected = state.provider == provider.id
        table.insert(buttons, {
            {
                text = (is_selected and "● " or "○ ") .. provider.name,
                callback = function()
                    state.provider = provider.id
                    state.model = nil  -- Reset model when provider changes
                    UIManager:close(self.custom_provider_dialog)
                    UIManager:close(self.custom_quick_dialog)
                    self:showCustomQuickSettingsDialog(state)
                end,
            },
        })
    end

    -- Cancel
    table.insert(buttons, {
        {
            text = _("Cancel"),
            callback = function()
                UIManager:close(self.custom_provider_dialog)
            end,
        },
    })

    self.custom_provider_dialog = ButtonDialog:new{
        title = _("Select Provider"),
        buttons = buttons,
    }
    UIManager:show(self.custom_provider_dialog)
end

-- Model selector for custom quick settings
function PromptsManager:showCustomModelSelector(state)
    local ModelLists = require("koassistant_model_lists")
    local buttons = {}

    -- Get models for selected provider
    local models = ModelLists.getModelsForProvider(state.provider, self.plugin.settings)

    for _idx, model in ipairs(models) do
        local is_selected = state.model == model
        table.insert(buttons, {
            {
                text = (is_selected and "● " or "○ ") .. model,
                callback = function()
                    state.model = model
                    UIManager:close(self.custom_model_dialog)
                    UIManager:close(self.custom_quick_dialog)
                    self:showCustomQuickSettingsDialog(state)
                end,
            },
        })
    end

    -- Custom model option
    table.insert(buttons, {
        {
            text = _("Custom model..."),
            callback = function()
                UIManager:close(self.custom_model_dialog)
                self:showCustomModelQuickInput(state)
            end,
        },
    })

    -- Cancel
    table.insert(buttons, {
        {
            text = _("Cancel"),
            callback = function()
                UIManager:close(self.custom_model_dialog)
            end,
        },
    })

    self.custom_model_dialog = ButtonDialog:new{
        title = _("Select Model"),
        buttons = buttons,
    }
    UIManager:show(self.custom_model_dialog)
end

-- Custom model input for custom quick settings
function PromptsManager:showCustomModelQuickInput(state)
    local dialog
    dialog = InputDialog:new{
        title = _("Custom Model"),
        input = state.model or "",
        input_hint = _("Enter model name"),
        buttons = {
            {
                {
                    text = _("Cancel"),
                    id = "close",
                    callback = function()
                        UIManager:close(dialog)
                        self:showCustomModelSelector(state)
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
                        UIManager:close(self.custom_quick_dialog)
                        self:showCustomQuickSettingsDialog(state)
                    end,
                },
            },
        },
    }
    UIManager:show(dialog)
    dialog:onShowKeyboard()
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
        -- Basic placeholders
        { value = "{highlighted_text}", text = _("Selected Text"), contexts = {"highlight", "both"} },
        { value = "{title}", text = _("Book Title"), contexts = {"highlight", "book", "both"} },
        { value = "{author}", text = _("Author Name"), contexts = {"highlight", "book", "both"} },
        { value = "{author_clause}", text = _("Author Clause"), contexts = {"highlight", "book", "both"} },
        { value = "{count}", text = _("Book Count"), contexts = {"multi_book"} },
        { value = "{books_list}", text = _("Books List"), contexts = {"multi_book"} },
        { value = "{translation_language}", text = _("Translation Language"), contexts = {"highlight", "book", "multi_book", "general", "both"} },
        -- Context extraction placeholders (require extraction flags + global settings)
        { value = "{reading_progress}", text = _("Reading Progress (%)"), contexts = {"highlight", "book", "both"} },
        { value = "{progress_decimal}", text = _("Progress (0.0-1.0)"), contexts = {"highlight", "book", "both"} },
        { value = "{book_text_section}", text = _("Book Text (with label)"), contexts = {"highlight", "book", "both"} },
        { value = "{book_text}", text = _("Book Text (raw)"), contexts = {"highlight", "book", "both"} },
        { value = "{highlights_section}", text = _("Highlights (with label)"), contexts = {"highlight", "book", "both"} },
        { value = "{highlights}", text = _("Highlights (raw)"), contexts = {"highlight", "book", "both"} },
        { value = "{annotations_section}", text = _("Annotations (with label)"), contexts = {"highlight", "book", "both"} },
        { value = "{annotations}", text = _("Annotations (raw)"), contexts = {"highlight", "book", "both"} },
        { value = "{chapter_title}", text = _("Current Chapter"), contexts = {"highlight", "book", "both"} },
        { value = "{chapters_read}", text = _("Chapters Read Count"), contexts = {"highlight", "book", "both"} },
        { value = "{time_since_last_read}", text = _("Time Since Last Read"), contexts = {"highlight", "book", "both"} },
        { value = "{notebook_section}", text = _("Notebook (with label)"), contexts = {"highlight", "book", "both"} },
        { value = "{notebook}", text = _("Notebook (raw)"), contexts = {"highlight", "book", "both"} },
        -- Full document placeholders
        { value = "{full_document_section}", text = _("Full Document (with label)"), contexts = {"highlight", "book", "both"} },
        { value = "{full_document}", text = _("Full Document (raw)"), contexts = {"highlight", "book", "both"} },
        -- Document cache placeholders (require text extraction + cache to exist)
        { value = "{xray_cache_section}", text = _("X-Ray Cache (with label)"), contexts = {"book", "both"} },
        { value = "{xray_cache}", text = _("X-Ray Cache (raw)"), contexts = {"book", "both"} },
        { value = "{analyze_cache_section}", text = _("Analysis Cache (with label)"), contexts = {"book", "both"} },
        { value = "{analyze_cache}", text = _("Analysis Cache (raw)"), contexts = {"book", "both"} },
        { value = "{summary_cache_section}", text = _("Summary Cache (with label)"), contexts = {"book", "both"} },
        { value = "{summary_cache}", text = _("Summary Cache (raw)"), contexts = {"book", "both"} },
        -- Surrounding context placeholder (for highlight actions)
        { value = "{surrounding_context_section}", text = _("Surrounding Context (with label)"), contexts = {"highlight", "both"} },
        { value = "{surrounding_context}", text = _("Surrounding Context (raw)"), contexts = {"highlight", "both"} },
    }

    local result = {}
    for _idx,p in ipairs(all_placeholders) do
        for _j,ctx in ipairs(p.contexts) do
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
        tap_close_callback = function()
            self:showStep3_ActionPrompt(state)
        end,
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
            skip_domain = state.skip_domain or nil,
            domain = state.domain,
            api_params = api_params,
            reasoning_config = state.reasoning_config,  -- nil = global, "off" = force off, table = per-provider
            -- Legacy fields (backward compatibility)
            extended_thinking = state.extended_thinking,
            thinking_budget = state.thinking_budget,
            provider = state.provider,  -- nil = use global
            model = state.model,        -- nil = use global
            -- Context extraction flags (off by default)
            use_book_text = state.use_book_text or nil,
            use_highlights = state.use_highlights or nil,
            use_annotations = state.use_annotations or nil,
            use_reading_progress = state.use_reading_progress or nil,
            use_reading_stats = state.use_reading_stats or nil,
            use_notebook = state.use_notebook or nil,
            -- View mode flags
            translate_view = state.translate_view or nil,
            compact_view = state.compact_view or nil,
            minimal_buttons = state.minimal_buttons or nil,
            -- Web search (tri-state: nil/true/false - nil means follow global)
            enable_web_search = state.enable_web_search,
            enabled = true,
        })

        -- Add to highlight menu if requested (only for highlight-compatible contexts)
        local added_to_highlight_menu = false
        if state.add_to_highlight_menu and self:contextIncludesHighlight(state.context) then
            service:addToHighlightMenu(new_action_id)
            added_to_highlight_menu = true
        end

        -- Add to dictionary popup if requested (only for highlight-compatible contexts)
        if state.add_to_dictionary_popup and self:contextIncludesHighlight(state.context) then
            service:addToDictionaryPopup(new_action_id)
        end

        local msg = _("Action added successfully")
        if added_to_highlight_menu then
            msg = msg .. "\n" .. _("Restart KOReader for highlight menu changes to apply.")
        end
        UIManager:show(InfoMessage:new{
            text = msg,
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
                skip_domain = state.skip_domain or nil,
                domain = state.domain,
                api_params = api_params,
                reasoning_config = state.reasoning_config,  -- nil = global, "off" = force off, table = per-provider
                -- Legacy fields (backward compatibility)
                extended_thinking = state.extended_thinking,
                thinking_budget = state.thinking_budget,
                provider = state.provider,
                model = state.model,
                -- Context extraction flags (off by default)
                use_book_text = state.use_book_text or nil,
                use_highlights = state.use_highlights or nil,
                use_annotations = state.use_annotations or nil,
                use_reading_progress = state.use_reading_progress or nil,
                use_reading_stats = state.use_reading_stats or nil,
                use_notebook = state.use_notebook or nil,
                -- View mode flags
                translate_view = state.translate_view or nil,
                compact_view = state.compact_view or nil,
                minimal_buttons = state.minimal_buttons or nil,
                -- Web search (tri-state: nil/true/false - nil means follow global)
                enable_web_search = state.enable_web_search,
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
        return _("Book")
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
    elseif context == "both+general" then
        return _("Highlight, Book & General")
    else
        return context
    end
end

-- Sorting menus should NOT auto-close on item tap.
-- KOReader's Menu:onMenuSelect() calls close_callback after each tap,
-- which is wrong for multi-toggle sorting managers. Override to skip that.
local function _sortingMenuOnSelect(this, item)
    if item.sub_item_table == nil then
        if item.select_enabled == false then return true end
        if item.select_enabled_func and not item.select_enabled_func() then return true end
        this:onMenuChoice(item)
    else
        item.table.title = this.title
        table.insert(this.item_table_stack, this.item_table)
        this:switchItemTable(item.text, item.sub_item_table)
    end
    return true
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

    local features = self.plugin.settings:readSetting("features") or {}
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
        text = _("✓ = in menu | Tap = toggle | Hold = move | ☰ = navigate"),
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
            text = prefix .. position .. ActionService.getActionDisplayText(action, features) .. source_indicator,
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
        title = T(_("Highlight Menu (%1 enabled)"), menu_count),
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
                    UIManager:show(Notification:new{
                        text = _("Changes require restart to take effect"),
                        timeout = 2,
                    })
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
                    UIManager:show(Notification:new{
                        text = _("Changes require restart to take effect"),
                        timeout = 2,
                    })
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
                UIManager:show(Notification:new{
                    text = _("Changes require restart to take effect"),
                    timeout = 2,
                })
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
-- Shared anchored hamburger menu helpers
-- ============================================================

-- Show an anchored dropdown menu at the hamburger button of the given menu widget
function PromptsManager:_showAnchoredMenu(menu_widget, buttons)
    if self._anchored_menu then UIManager:close(self._anchored_menu) end
    self._anchored_menu = ButtonDialog:new{
        buttons = buttons,
        shrink_unneeded_width = true,
        anchor = function()
            return menu_widget.title_bar.left_button.image.dimen, true
        end,
    }
    UIManager:show(self._anchored_menu)
end

-- Smooth cross-navigation: close anchored menu + current window, open target in nextTick
function PromptsManager:_navigateToManager(from_field, show_fn)
    if self._anchored_menu then UIManager:close(self._anchored_menu) end
    local menu_to_close = self[from_field]
    self[from_field] = nil
    UIManager:nextTick(function()
        if menu_to_close then UIManager:close(menu_to_close) end
        show_fn()
    end)
end

-- Build a single navigation button row for an anchored menu
function PromptsManager:_makeNavButton(text, from_field, show_fn)
    return {
        { text = text, align = "left", callback = function()
            self:_navigateToManager(from_field, show_fn)
        end },
    }
end

-- Confirm and execute a reset action, then reopen the manager via nextTick
function PromptsManager:_confirmAndReset(confirm_text, reset_fn, menu_field, reshow_fn)
    if self._anchored_menu then UIManager:close(self._anchored_menu) end
    UIManager:show(ConfirmBox:new{
        text = confirm_text,
        ok_callback = function()
            reset_fn()
            local menu_to_close = self[menu_field]
            self[menu_field] = nil
            UIManager:nextTick(function()
                if menu_to_close then UIManager:close(menu_to_close) end
                reshow_fn()
            end)
        end,
    })
end

-- ============================================================
-- Highlight Menu Actions Manager
-- ============================================================

function PromptsManager:_buildHighlightMenuItems(bold_id)
    local features = self.plugin.settings:readSetting("features") or {}
    local all_actions = self.plugin.action_service:getAllHighlightActionsWithMenuState()
    local menu_count = 0
    local menu_items = {}

    table.insert(menu_items, {
        text = _("✓ = in menu | Tap = toggle | Hold = move | ☰ = navigate"),
        dim = true,
        callback = function() end,
    })

    for _idx, item in ipairs(all_actions) do
        local action = item.action
        if item.in_menu then menu_count = menu_count + 1 end
        local prefix = item.in_menu and "✓ " or "  "
        local position = item.in_menu and string.format("[%d] ", item.menu_position) or ""
        local source_indicator = ""
        if action.source == "ui" then source_indicator = " ★"
        elseif action.source == "config" then source_indicator = " ◆" end

        table.insert(menu_items, {
            text = prefix .. position .. ActionService.getActionDisplayText(action, features) .. source_indicator,
            action = action,
            in_menu = item.in_menu,
            menu_position = item.menu_position,
            bold = (item.in_menu and action.id == bold_id),
            callback = function()
                self.plugin.action_service:toggleHighlightMenuAction(action.id)
                UIManager:nextTick(function() self:_refreshHighlightMenu() end)
            end,
        })
    end
    return menu_items, menu_count
end

function PromptsManager:_refreshHighlightMenu(bold_id)
    if not self.highlight_menu_manager then return end
    local menu_items, menu_count = self:_buildHighlightMenuItems(bold_id)
    self.highlight_menu_manager:switchItemTable(
        T(_("Highlight Menu (%1 enabled)"), menu_count), menu_items, -1)
end

function PromptsManager:showHighlightMenuManager()
    if not self.plugin.action_service then
        UIManager:show(InfoMessage:new{ text = _("Action service not available.") })
        return
    end

    local all_actions = self.plugin.action_service:getAllHighlightActionsWithMenuState()
    if #all_actions == 0 then
        UIManager:show(InfoMessage:new{ text = _("No highlight actions available.") })
        return
    end

    local menu_items, menu_count = self:_buildHighlightMenuItems()
    local self_ref = self
    self.highlight_menu_manager = Menu:new{
        title = T(_("Highlight Menu (%1 enabled)"), menu_count),
        title_bar_left_icon = "appbar.menu",
        onLeftButtonTap = function()
            local from = "highlight_menu_manager"
            local buttons = {
                self_ref:_makeNavButton(_("Manage Actions"), from, function() self_ref:showPromptsMenu() end),
                self_ref:_makeNavButton(_("Dictionary Popup"), from, function() self_ref:showDictionaryPopupManager() end),
                self_ref:_makeNavButton(_("Quick Actions"), from, function() self_ref:showQuickActionsManager() end),
                self_ref:_makeNavButton(_("File Browser Actions"), from, function() self_ref:showFileBrowserActionsManager() end),
                {{ text = _("Reset to defaults"), align = "left", callback = function()
                    self_ref:_confirmAndReset(
                        _("Reset highlight menu actions to defaults?\n\nThis restores the default ordering and selection.\n\nYour actions (custom and built-in) are preserved."),
                        function() self_ref.plugin:resetHighlightMenuActions() end,
                        from, function() self_ref:showHighlightMenuManager() end)
                end }},
            }
            self_ref:_showAnchoredMenu(self_ref.highlight_menu_manager, buttons)
        end,
        item_table = menu_items,
        width = self.width,
        height = self.height,
        covers_fullscreen = true,
        is_borderless = true,
        is_popout = false,
        onMenuHold = function(_menu_widget, menu_item)
            if menu_item and menu_item.action then
                if menu_item.in_menu then
                    self_ref:_refreshHighlightMenu(menu_item.action.id)
                    local move_fn = function(id, dir) self_ref.plugin.action_service:moveHighlightMenuAction(id, dir) end
                    local function find_pos(target_id)
                        local all = self_ref.plugin.action_service:getAllHighlightActionsWithMenuState()
                        local total, pos = 0, nil
                        for _i, a in ipairs(all) do
                            if a.in_menu then
                                total = total + 1
                                if a.action.id == target_id then pos = a.menu_position end
                            end
                        end
                        return pos, total
                    end
                    local function reshow(moved_id)
                        self_ref:_refreshHighlightMenu(moved_id)
                        local pos, total = find_pos(moved_id)
                        if pos then
                            self_ref:showOrderItemOptions(moved_id, pos, total,
                                move_fn, reshow, function() self_ref:_refreshHighlightMenu() end)
                        end
                    end
                    local pos, total = find_pos(menu_item.action.id)
                    if pos then
                        self_ref:showOrderItemOptions(menu_item.action.id, pos, total,
                            move_fn, reshow, function() self_ref:_refreshHighlightMenu() end)
                    end
                else
                    UIManager:show(InfoMessage:new{
                        text = string.format("%s\n\nSource: %s\n\nTap to add to highlight menu.",
                            menu_item.action.text or menu_item.action.id,
                            menu_item.action.source or "builtin"),
                        timeout = 3,
                    })
                end
            end
        end,
    }
    UIManager:show(self.highlight_menu_manager)
end

-- ============================================================
-- Quick Actions Panel Manager
-- ============================================================

function PromptsManager:_buildQuickActionsItems(bold_id)
    local features = self.plugin.settings:readSetting("features") or {}
    local all_actions = self.plugin.action_service:getAllBookActionsWithQuickActionsState()
    local quick_count = 0
    local menu_items = {}

    table.insert(menu_items, {
        text = _("✓ = in panel | Tap = toggle | Hold = move | ☰ = navigate"),
        dim = true,
        callback = function() end,
    })

    for _idx, item in ipairs(all_actions) do
        local action = item.action
        if item.in_quick_actions then quick_count = quick_count + 1 end
        local prefix = item.in_quick_actions and "✓ " or "  "
        local position = item.in_quick_actions and string.format("[%d] ", item.quick_actions_position) or ""
        local source_indicator = ""
        if action.source == "ui" then source_indicator = " ★"
        elseif action.source == "config" then source_indicator = " ◆" end

        table.insert(menu_items, {
            text = prefix .. position .. ActionService.getActionDisplayText(action, features) .. source_indicator,
            action = action,
            in_quick_actions = item.in_quick_actions,
            quick_actions_position = item.quick_actions_position,
            bold = (item.in_quick_actions and action.id == bold_id),
            callback = function()
                self.plugin.action_service:toggleQuickAction(action.id)
                UIManager:nextTick(function() self:_refreshQuickActionsMenu() end)
            end,
        })
    end
    return menu_items, quick_count
end

function PromptsManager:_refreshQuickActionsMenu(bold_id)
    if not self.quick_actions_menu then return end
    local menu_items, quick_count = self:_buildQuickActionsItems(bold_id)
    self.quick_actions_menu:switchItemTable(
        T(_("Quick Actions (%1 enabled)"), quick_count), menu_items, -1)
end

function PromptsManager:showQuickActionsManager(on_close_callback)
    if not self.plugin.action_service then
        UIManager:show(InfoMessage:new{ text = _("Action service not available.") })
        return
    end

    local all_actions = self.plugin.action_service:getAllBookActionsWithQuickActionsState()
    if #all_actions == 0 then
        UIManager:show(InfoMessage:new{ text = _("No book actions available.") })
        return
    end

    local menu_items, quick_count = self:_buildQuickActionsItems()
    local self_ref = self
    self.quick_actions_menu = Menu:new{
        title = T(_("Quick Actions (%1 enabled)"), quick_count),
        title_bar_left_icon = "appbar.menu",
        onLeftButtonTap = function()
            local from = "quick_actions_menu"
            local buttons = {
                self_ref:_makeNavButton(_("Manage Actions"), from, function() self_ref:showPromptsMenu() end),
                self_ref:_makeNavButton(_("Highlight Menu"), from, function() self_ref:showHighlightMenuManager() end),
                self_ref:_makeNavButton(_("Dictionary Popup"), from, function() self_ref:showDictionaryPopupManager() end),
                self_ref:_makeNavButton(_("File Browser Actions"), from, function() self_ref:showFileBrowserActionsManager() end),
                self_ref:_makeNavButton(_("QA Panel Utilities"), from, function() self_ref:showQaUtilitiesManager() end),
                self_ref:_makeNavButton(_("QS Panel Items"), from, function() self_ref:showQsItemsManager() end),
                {{ text = _("Reset to defaults"), align = "left", callback = function()
                    self_ref:_confirmAndReset(
                        _("Reset Quick Actions panel?\n\nThis restores the default actions shown in the Quick Actions menu.\n\nYour actions (custom and built-in) are preserved."),
                        function() self_ref.plugin:resetQuickActions() end,
                        from, function() self_ref:showQuickActionsManager(on_close_callback) end)
                end }},
            }
            self_ref:_showAnchoredMenu(self_ref.quick_actions_menu, buttons)
        end,
        item_table = menu_items,
        width = self.width,
        height = self.height,
        covers_fullscreen = true,
        is_borderless = true,
        is_popout = false,
        onMenuHold = function(_menu_widget, menu_item)
            if menu_item and menu_item.action then
                if menu_item.in_quick_actions then
                    self_ref:_refreshQuickActionsMenu(menu_item.action.id)
                    local move_fn = function(id, dir) self_ref.plugin.action_service:moveQuickAction(id, dir) end
                    local function find_pos(target_id)
                        local all = self_ref.plugin.action_service:getAllBookActionsWithQuickActionsState()
                        local total, pos = 0, nil
                        for _i, a in ipairs(all) do
                            if a.in_quick_actions then
                                total = total + 1
                                if a.action.id == target_id then pos = a.quick_actions_position end
                            end
                        end
                        return pos, total
                    end
                    local function reshow(moved_id)
                        self_ref:_refreshQuickActionsMenu(moved_id)
                        local pos, total = find_pos(moved_id)
                        if pos then
                            self_ref:showOrderItemOptions(moved_id, pos, total,
                                move_fn, reshow, function() self_ref:_refreshQuickActionsMenu() end)
                        end
                    end
                    local pos, total = find_pos(menu_item.action.id)
                    if pos then
                        self_ref:showOrderItemOptions(menu_item.action.id, pos, total,
                            move_fn, reshow, function() self_ref:_refreshQuickActionsMenu() end)
                    end
                else
                    UIManager:show(InfoMessage:new{
                        text = string.format("%s\n\nSource: %s\n\nTap to add to Quick Actions panel.",
                            menu_item.action.text or menu_item.action.id,
                            menu_item.action.source or "builtin"),
                        timeout = 3,
                    })
                end
            end
        end,
        close_callback = on_close_callback,
    }
    self.quick_actions_menu.onMenuSelect = _sortingMenuOnSelect
    UIManager:show(self.quick_actions_menu)
end

-- ============================================================
-- QA Utilities Manager
-- ============================================================

function PromptsManager:_buildQaUtilitiesItems(bold_id)
    local features = self.plugin.settings:readSetting("features") or {}
    local order = self.plugin.action_service:getQaUtilitiesOrder()
    local enabled_count = 0
    local menu_items = {}

    table.insert(menu_items, {
        text = _("✓ = visible | Tap = toggle | Hold = move | ☰ = navigate"),
        dim = true,
        callback = function() end,
    })

    for pos, util_id in ipairs(order) do
        local enabled = features["qa_show_" .. util_id]
        if enabled == nil then
            for _i, u in ipairs(Constants.QUICK_ACTION_UTILITIES) do
                if u.id == util_id then enabled = u.default; break end
            end
        end
        if enabled then enabled_count = enabled_count + 1 end

        local prefix = enabled and "✓ " or "  "
        local position = string.format("[%d] ", pos)
        local display_text = Constants.getQuickActionUtilityText(util_id, _) or util_id

        table.insert(menu_items, {
            text = prefix .. position .. display_text,
            util_id = util_id,
            position = pos,
            enabled = enabled,
            bold = (util_id == bold_id),
            callback = function()
                local f = self.plugin.settings:readSetting("features") or {}
                f["qa_show_" .. util_id] = not enabled
                self.plugin.settings:saveSetting("features", f)
                self.plugin.settings:flush()
                UIManager:nextTick(function() self:_refreshQaUtilitiesMenu() end)
            end,
        })
    end
    return menu_items, enabled_count
end

function PromptsManager:_refreshQaUtilitiesMenu(bold_id)
    if not self.qa_utilities_menu then return end
    local menu_items, enabled_count = self:_buildQaUtilitiesItems(bold_id)
    self.qa_utilities_menu:switchItemTable(
        T(_("QA Panel Utilities (%1 visible)"), enabled_count), menu_items, -1)
end

function PromptsManager:showQaUtilitiesManager(restore_page, on_close_callback)
    if not self.plugin.action_service then
        UIManager:show(InfoMessage:new{ text = _("Action service not available.") })
        return
    end

    local menu_items, enabled_count = self:_buildQaUtilitiesItems()
    local self_ref = self
    self.qa_utilities_menu = Menu:new{
        title = T(_("QA Panel Utilities (%1 visible)"), enabled_count),
        title_bar_left_icon = "appbar.menu",
        onLeftButtonTap = function()
            local from = "qa_utilities_menu"
            local buttons = {
                self_ref:_makeNavButton(_("QA Panel Actions"), from, function() self_ref:showQuickActionsManager() end),
                self_ref:_makeNavButton(_("QS Panel Items"), from, function() self_ref:showQsItemsManager() end),
                {{ text = _("Reset to defaults"), align = "left", callback = function()
                    self_ref:_confirmAndReset(
                        _("Reset QA panel utilities to defaults?\n\nThis restores the default order and visibility of utility buttons."),
                        function() self_ref.plugin:resetQaUtilities() end,
                        from, function() self_ref:showQaUtilitiesManager(nil, on_close_callback) end)
                end }},
            }
            self_ref:_showAnchoredMenu(self_ref.qa_utilities_menu, buttons)
        end,
        item_table = menu_items,
        width = self.width,
        height = self.height,
        covers_fullscreen = true,
        is_borderless = true,
        is_popout = false,
        onMenuHold = function(_menu_widget, menu_item)
            if menu_item and menu_item.util_id then
                self_ref:_refreshQaUtilitiesMenu(menu_item.util_id)
                local move_fn = function(id, dir) self_ref.plugin.action_service:moveQaUtility(id, dir) end
                local function reshow(moved_id)
                    self_ref:_refreshQaUtilitiesMenu(moved_id)
                    local new_order = self_ref.plugin.action_service:getQaUtilitiesOrder()
                    for i, id in ipairs(new_order) do
                        if id == moved_id then
                            self_ref:showOrderItemOptions(moved_id, i, #new_order,
                                move_fn, reshow, function() self_ref:_refreshQaUtilitiesMenu() end)
                            break
                        end
                    end
                end
                local cur_order = self_ref.plugin.action_service:getQaUtilitiesOrder()
                self_ref:showOrderItemOptions(
                    menu_item.util_id, menu_item.position, #cur_order,
                    move_fn, reshow, function() self_ref:_refreshQaUtilitiesMenu() end)
            end
        end,
        close_callback = on_close_callback,
    }
    self.qa_utilities_menu.onMenuSelect = _sortingMenuOnSelect
    UIManager:show(self.qa_utilities_menu)
    if restore_page and restore_page > 1 then
        self.qa_utilities_menu:onGotoPage(restore_page)
    end
end

-- ============================================================
-- QS Items Manager
-- ============================================================

-- Build the item table for QS Items Manager.
-- bold_id: optional item_id to render bold (currently being moved).
function PromptsManager:_buildQsMenuItems(bold_id)
    local features = self.plugin.settings:readSetting("features") or {}
    local order = self.plugin.action_service:getQsItemsOrder()

    local enabled_count = 0
    local menu_items = {}

    -- Help text item
    table.insert(menu_items, {
        text = _("✓ = visible | Tap = toggle | Hold = move | ☰ = navigate"),
        dim = true,
        callback = function() end,
    })

    for pos, item_id in ipairs(order) do
        local enabled = features["qs_show_" .. item_id]
        if enabled == nil then enabled = true end
        if enabled then enabled_count = enabled_count + 1 end

        local prefix = enabled and "✓ " or "  "
        local position = string.format("[%d] ", pos)
        local display_text = Constants.getQsItemText(item_id, _)
        local dynamic = Constants.QS_DYNAMIC_ITEMS[item_id]
        if dynamic then
            display_text = display_text .. " " .. _("(dynamic)")
        end

        table.insert(menu_items, {
            text = prefix .. position .. display_text,
            item_id = item_id,
            position = pos,
            enabled = enabled,
            bold = (item_id == bold_id),
            callback = function()
                -- Toggle visibility
                local f = self.plugin.settings:readSetting("features") or {}
                f["qs_show_" .. item_id] = not enabled
                self.plugin.settings:saveSetting("features", f)
                self.plugin.settings:flush()
                -- Defer: switchItemTable from within a MenuItem tap handler
                -- destroys the MenuItem while it's still processing the event.
                UIManager:nextTick(function()
                    self:_refreshQsItemsMenu()
                end)
            end,
        })
    end

    return menu_items, enabled_count
end

-- Refresh the QS Items menu in-place (no close/reopen).
-- bold_id: optional item_id to render bold.
function PromptsManager:_refreshQsItemsMenu(bold_id)
    if not self.qs_items_menu then return end
    local menu_items, enabled_count = self:_buildQsMenuItems(bold_id)
    -- itemnumber=-1 preserves current page (bypasses page-setting logic)
    self.qs_items_menu:switchItemTable(
        T(_("QS Panel Items (%1 visible)"), enabled_count),
        menu_items, -1)
end

function PromptsManager:showQsItemsManager(restore_page, on_close_callback)
    if not self.plugin.action_service then
        UIManager:show(InfoMessage:new{
            text = _("Action service not available."),
        })
        return
    end

    local menu_items, enabled_count = self:_buildQsMenuItems()

    local self_ref = self
    self.qs_items_menu = Menu:new{
        title = T(_("QS Panel Items (%1 visible)"), enabled_count),
        title_bar_left_icon = "appbar.menu",
        onLeftButtonTap = function()
            local from = "qs_items_menu"
            local buttons = {
                self_ref:_makeNavButton(_("QA Panel Actions"), from, function() self_ref:showQuickActionsManager() end),
                self_ref:_makeNavButton(_("QA Panel Utilities"), from, function() self_ref:showQaUtilitiesManager() end),
                {{ text = _("Reset to defaults"), align = "left", callback = function()
                    self_ref:_confirmAndReset(
                        _("Reset QS panel items to defaults?\n\nThis restores the default order and visibility of Quick Settings items."),
                        function() self_ref.plugin:resetQsItems() end,
                        from, function() self_ref:showQsItemsManager(nil, on_close_callback) end)
                end }},
            }
            self_ref:_showAnchoredMenu(self_ref.qs_items_menu, buttons)
        end,
        item_table = menu_items,
        width = self.width,
        height = self.height,
        covers_fullscreen = true,
        is_borderless = true,
        is_popout = false,
        onMenuHold = function(_menu_widget, menu_item)
            if menu_item and menu_item.item_id then
                -- Bold the held item immediately
                self_ref:_refreshQsItemsMenu(menu_item.item_id)
                local current_order = self_ref.plugin.action_service:getQsItemsOrder()
                local move_fn = function(id, direction) self_ref.plugin.action_service:moveQsItem(id, direction) end
                local function reshow(moved_id)
                    self_ref:_refreshQsItemsMenu(moved_id)
                    local new_order = self_ref.plugin.action_service:getQsItemsOrder()
                    for i, id in ipairs(new_order) do
                        if id == moved_id then
                            self_ref:showOrderItemOptions(moved_id, i, #new_order,
                                move_fn, reshow, function() self_ref:_refreshQsItemsMenu() end)
                            break
                        end
                    end
                end
                local dismiss_fn = function() self_ref:_refreshQsItemsMenu() end
                self_ref:showOrderItemOptions(
                    menu_item.item_id, menu_item.position, #current_order,
                    move_fn, reshow, dismiss_fn)
            end
        end,
        close_callback = on_close_callback,
    }
    self.qs_items_menu.onMenuSelect = _sortingMenuOnSelect
    UIManager:show(self.qs_items_menu)
    if restore_page and restore_page > 1 then
        self.qs_items_menu:onGotoPage(restore_page)
    end
end

-- Shared hold options for ordered items — persistent ↑/↓ arrows.
-- No title, shrinks to fit. Tap outside to dismiss (calls dismiss_fn).
-- reshow_fn(item_id): refreshes parent menu in-place and re-shows this dialog.
-- dismiss_fn: called when user taps outside to close (e.g. unbold item).
function PromptsManager:showOrderItemOptions(item_id, index, total, move_fn, reshow_fn, dismiss_fn)
    if total <= 1 then return end

    local at_top = index <= 1
    local at_bottom = index >= total
    self.order_options_dialog = ButtonDialog:new{
        buttons = { {
            {
                text = "\u{2191}",
                enabled = not at_top,
                callback = function()
                    move_fn(item_id, "up")
                    UIManager:close(self.order_options_dialog)
                    reshow_fn(item_id)
                end,
            },
            {
                text = "\u{2193}",
                enabled = not at_bottom,
                callback = function()
                    move_fn(item_id, "down")
                    UIManager:close(self.order_options_dialog)
                    reshow_fn(item_id)
                end,
            },
        } },
        shrink_unneeded_width = true,
        tap_close_callback = dismiss_fn,
    }
    UIManager:show(self.order_options_dialog)
end

-- ============================================================
-- File Browser Actions Manager
-- ============================================================

function PromptsManager:_buildFileBrowserItems(bold_id)
    local features = self.plugin.settings:readSetting("features") or {}
    local all_actions = self.plugin.action_service:getAllBookActionsWithFileBrowserState()
    local fb_count = 0
    local menu_items = {}

    table.insert(menu_items, {
        text = _("✓ = pinned | Tap = toggle | Hold = move | ☰ = navigate"),
        dim = true,
        callback = function() end,
    })

    for _idx, item in ipairs(all_actions) do
        local action = item.action
        if item.in_file_browser then fb_count = fb_count + 1 end
        local prefix = item.in_file_browser and "✓ " or "  "
        local position = item.in_file_browser and string.format("[%d] ", item.file_browser_position) or ""
        local source_indicator = ""
        if action.source == "ui" then source_indicator = " ★"
        elseif action.source == "config" then source_indicator = " ◆" end

        table.insert(menu_items, {
            text = prefix .. position .. ActionService.getActionDisplayText(action, features) .. source_indicator,
            action = action,
            in_file_browser = item.in_file_browser,
            file_browser_position = item.file_browser_position,
            bold = (item.in_file_browser and action.id == bold_id),
            callback = function()
                self.plugin.action_service:toggleFileBrowserAction(action.id)
                UIManager:nextTick(function() self:_refreshFileBrowserMenu() end)
            end,
        })
    end
    return menu_items, fb_count
end

function PromptsManager:_refreshFileBrowserMenu(bold_id)
    if not self.file_browser_menu then return end
    local menu_items, fb_count = self:_buildFileBrowserItems(bold_id)
    self.file_browser_menu:switchItemTable(
        T(_("File Browser Actions (%1 pinned)"), fb_count), menu_items, -1)
end

function PromptsManager:showFileBrowserActionsManager()
    if not self.plugin.action_service then
        UIManager:show(InfoMessage:new{ text = _("Action service not available.") })
        return
    end

    local all_actions = self.plugin.action_service:getAllBookActionsWithFileBrowserState()
    if #all_actions == 0 then
        UIManager:show(InfoMessage:new{ text = _("No eligible book actions available.") })
        return
    end

    local menu_items, fb_count = self:_buildFileBrowserItems()
    local self_ref = self
    self.file_browser_menu = Menu:new{
        title = T(_("File Browser Actions (%1 pinned)"), fb_count),
        title_bar_left_icon = "appbar.menu",
        onLeftButtonTap = function()
            local from = "file_browser_menu"
            local buttons = {
                self_ref:_makeNavButton(_("Manage Actions"), from, function() self_ref:showPromptsMenu() end),
                self_ref:_makeNavButton(_("Highlight Menu"), from, function() self_ref:showHighlightMenuManager() end),
                self_ref:_makeNavButton(_("Dictionary Popup"), from, function() self_ref:showDictionaryPopupManager() end),
                self_ref:_makeNavButton(_("Quick Actions"), from, function() self_ref:showQuickActionsManager() end),
                {{ text = _("Reset to defaults"), align = "left", callback = function()
                    self_ref:_confirmAndReset(
                        _("Reset file browser actions to defaults?\n\nThis restores the default actions pinned to the file browser.\n\nYour actions (custom and built-in) are preserved."),
                        function() self_ref.plugin:resetFileBrowserActions() end,
                        from, function() self_ref:showFileBrowserActionsManager() end)
                end }},
            }
            self_ref:_showAnchoredMenu(self_ref.file_browser_menu, buttons)
        end,
        item_table = menu_items,
        width = self.width,
        height = self.height,
        covers_fullscreen = true,
        is_borderless = true,
        is_popout = false,
        onMenuHold = function(_menu_widget, menu_item)
            if menu_item and menu_item.action then
                if menu_item.in_file_browser then
                    self_ref:_refreshFileBrowserMenu(menu_item.action.id)
                    local move_fn = function(id, dir) self_ref.plugin.action_service:moveFileBrowserAction(id, dir) end
                    local function find_pos(target_id)
                        local all = self_ref.plugin.action_service:getAllBookActionsWithFileBrowserState()
                        local total, pos = 0, nil
                        for _i, a in ipairs(all) do
                            if a.in_file_browser then
                                total = total + 1
                                if a.action.id == target_id then pos = a.file_browser_position end
                            end
                        end
                        return pos, total
                    end
                    local function reshow(moved_id)
                        self_ref:_refreshFileBrowserMenu(moved_id)
                        local pos, total = find_pos(moved_id)
                        if pos then
                            self_ref:showOrderItemOptions(moved_id, pos, total,
                                move_fn, reshow, function() self_ref:_refreshFileBrowserMenu() end)
                        end
                    end
                    local pos, total = find_pos(menu_item.action.id)
                    if pos then
                        self_ref:showOrderItemOptions(menu_item.action.id, pos, total,
                            move_fn, reshow, function() self_ref:_refreshFileBrowserMenu() end)
                    end
                else
                    UIManager:show(InfoMessage:new{
                        text = string.format("%s\n\nSource: %s\n\nTap to pin to file browser.",
                            menu_item.action.text or menu_item.action.id,
                            menu_item.action.source or "builtin"),
                        timeout = 3,
                    })
                end
            end
        end,
    }
    UIManager:show(self.file_browser_menu)
end

-- ============================================================
-- Dictionary Popup Actions Manager
-- ============================================================

function PromptsManager:_buildDictionaryPopupItems(bold_id)
    local features = self.plugin.settings:readSetting("features") or {}
    local all_actions = self.plugin.action_service:getAllHighlightActionsWithPopupState()
    local popup_count = 0
    local menu_items = {}

    table.insert(menu_items, {
        text = _("✓ = in popup | Tap = toggle | Hold = move | ☰ = navigate"),
        dim = true,
        callback = function() end,
    })

    for _idx, item in ipairs(all_actions) do
        local action = item.action
        if item.in_popup then popup_count = popup_count + 1 end
        local prefix = item.in_popup and "✓ " or "  "
        local position = item.in_popup and string.format("[%d] ", item.popup_position) or ""
        local source_indicator = ""
        if action.source == "ui" then source_indicator = " ★"
        elseif action.source == "config" then source_indicator = " ◆" end

        table.insert(menu_items, {
            text = prefix .. position .. ActionService.getActionDisplayText(action, features) .. source_indicator,
            action = action,
            in_popup = item.in_popup,
            popup_position = item.popup_position,
            bold = (item.in_popup and action.id == bold_id),
            callback = function()
                self.plugin.action_service:toggleDictionaryPopupAction(action.id)
                UIManager:nextTick(function() self:_refreshDictionaryPopupMenu() end)
            end,
        })
    end
    return menu_items, popup_count
end

function PromptsManager:_refreshDictionaryPopupMenu(bold_id)
    if not self.dictionary_popup_menu then return end
    local menu_items, popup_count = self:_buildDictionaryPopupItems(bold_id)
    self.dictionary_popup_menu:switchItemTable(
        T(_("Dictionary Popup (%1 enabled)"), popup_count), menu_items, -1)
end

function PromptsManager:showDictionaryPopupManager()
    if not self.plugin.action_service then
        UIManager:show(InfoMessage:new{ text = _("Action service not available.") })
        return
    end

    local all_actions = self.plugin.action_service:getAllHighlightActionsWithPopupState()
    if #all_actions == 0 then
        UIManager:show(InfoMessage:new{ text = _("No highlight actions available.") })
        return
    end

    local menu_items, popup_count = self:_buildDictionaryPopupItems()
    local self_ref = self
    self.dictionary_popup_menu = Menu:new{
        title = T(_("Dictionary Popup (%1 enabled)"), popup_count),
        title_bar_left_icon = "appbar.menu",
        onLeftButtonTap = function()
            local from = "dictionary_popup_menu"
            local buttons = {
                self_ref:_makeNavButton(_("Manage Actions"), from, function() self_ref:showPromptsMenu() end),
                self_ref:_makeNavButton(_("Highlight Menu"), from, function() self_ref:showHighlightMenuManager() end),
                self_ref:_makeNavButton(_("Quick Actions"), from, function() self_ref:showQuickActionsManager() end),
                self_ref:_makeNavButton(_("File Browser Actions"), from, function() self_ref:showFileBrowserActionsManager() end),
                {{ text = _("Reset to defaults"), align = "left", callback = function()
                    self_ref:_confirmAndReset(
                        _("Reset dictionary popup actions to defaults?\n\nThis restores the default ordering and selection.\n\nYour actions (custom and built-in) are preserved."),
                        function() self_ref.plugin:resetDictionaryPopupActions() end,
                        from, function() self_ref:showDictionaryPopupManager() end)
                end }},
            }
            self_ref:_showAnchoredMenu(self_ref.dictionary_popup_menu, buttons)
        end,
        item_table = menu_items,
        width = self.width,
        height = self.height,
        covers_fullscreen = true,
        is_borderless = true,
        is_popout = false,
        onMenuHold = function(_menu_widget, menu_item)
            if menu_item and menu_item.action then
                if menu_item.in_popup then
                    self_ref:_refreshDictionaryPopupMenu(menu_item.action.id)
                    local move_fn = function(id, dir) self_ref.plugin.action_service:moveDictionaryPopupAction(id, dir) end
                    local function find_pos(target_id)
                        local all = self_ref.plugin.action_service:getAllHighlightActionsWithPopupState()
                        local total, pos = 0, nil
                        for _i, a in ipairs(all) do
                            if a.in_popup then
                                total = total + 1
                                if a.action.id == target_id then pos = a.popup_position end
                            end
                        end
                        return pos, total
                    end
                    local function reshow(moved_id)
                        self_ref:_refreshDictionaryPopupMenu(moved_id)
                        local pos, total = find_pos(moved_id)
                        if pos then
                            self_ref:showOrderItemOptions(moved_id, pos, total,
                                move_fn, reshow, function() self_ref:_refreshDictionaryPopupMenu() end)
                        end
                    end
                    local pos, total = find_pos(menu_item.action.id)
                    if pos then
                        self_ref:showOrderItemOptions(menu_item.action.id, pos, total,
                            move_fn, reshow, function() self_ref:_refreshDictionaryPopupMenu() end)
                    end
                else
                    UIManager:show(InfoMessage:new{
                        text = string.format("%s\n\nSource: %s\n\nTap to add to dictionary popup.",
                            menu_item.action.text or menu_item.action.id,
                            menu_item.action.source or "builtin"),
                        timeout = 3,
                    })
                end
            end
        end,
    }
    UIManager:show(self.dictionary_popup_menu)
end

-- ============================================================
-- Input Dialog Actions Manager (Generic for all 4 input contexts)
-- ============================================================

local INPUT_CONTEXT_TITLES = {
    general = _("General Input Actions"),
    book = _("Book Input Actions"),
    book_filebrowser = _("File Browser Input Actions"),
    highlight = _("Highlight Input Actions"),
    xray_chat = _("X-Ray Chat Actions"),
}

function PromptsManager:_buildInputActionsItems(ctx_name, bold_id)
    local features = self.plugin.settings:readSetting("features") or {}
    local as = self.plugin.action_service
    local is_general = ctx_name == "general"
    local all_actions
    if is_general then
        -- General context uses dedicated general menu API
        local raw = as:getAllGeneralActionsWithMenuState()
        all_actions = {}
        for _idx, item in ipairs(raw) do
            table.insert(all_actions, {
                action = item.action,
                in_input = item.in_menu,
                input_position = item.menu_position,
            })
        end
    else
        all_actions = as:getAllActionsWithInputState(ctx_name)
    end
    local input_count = 0
    local menu_items = {}

    table.insert(menu_items, {
        text = _("✓ = shown | Tap = toggle | Hold = move | ☰ = menu"),
        dim = true,
        callback = function() end,
    })

    for _idx, item in ipairs(all_actions) do
        local action = item.action
        if item.in_input then input_count = input_count + 1 end
        local prefix = item.in_input and "✓ " or "  "
        local position = item.in_input and string.format("[%d] ", item.input_position) or ""
        local source_indicator = ""
        if action.source == "ui" then source_indicator = " ★"
        elseif action.source == "config" then source_indicator = " ◆" end

        table.insert(menu_items, {
            text = prefix .. position .. ActionService.getActionDisplayText(action, features) .. source_indicator,
            action = action,
            in_input = item.in_input,
            input_position = item.input_position,
            bold = (item.in_input and action.id == bold_id),
            callback = function()
                if is_general then
                    as:toggleGeneralMenuAction(action.id)
                else
                    as:toggleInputAction(ctx_name, action.id)
                end
                UIManager:nextTick(function() self:_refreshInputActionsMenu(ctx_name) end)
            end,
        })
    end
    return menu_items, input_count
end

function PromptsManager:_refreshInputActionsMenu(ctx_name, bold_id)
    if not self.input_actions_menu then return end
    local menu_items, input_count = self:_buildInputActionsItems(ctx_name, bold_id)
    local title = INPUT_CONTEXT_TITLES[ctx_name] or _("Input Actions")
    self.input_actions_menu:switchItemTable(
        T(_("%1 (%2 shown)"), title, input_count), menu_items, -1)
end

function PromptsManager:showInputActionsManager(ctx_name, on_close_callback)
    if not self.plugin or not self.plugin.action_service then
        UIManager:show(InfoMessage:new{
            text = _("Action service not available."),
            timeout = 2,
        })
        return
    end

    local is_general = ctx_name == "general"
    local menu_items, input_count = self:_buildInputActionsItems(ctx_name)
    local self_ref = self
    local title = INPUT_CONTEXT_TITLES[ctx_name] or _("Input Actions")
    local as = self.plugin.action_service

    -- Reset handler differs for general (clears dismissed list) vs other (resetInputActions)
    local reset_callback = function()
        if is_general then
            self_ref.plugin.settings:delSetting("general_menu_actions")
            self_ref.plugin.settings:delSetting("_dismissed_general_menu_actions")
            self_ref.plugin.settings:flush()
        else
            as:resetInputActions(ctx_name)
        end
        self_ref:_refreshInputActionsMenu(ctx_name)
    end

    self.input_actions_menu = Menu:new{
        title = T(_("%1 (%2 shown)"), title, input_count),
        title_bar_left_icon = "appbar.menu",
        onLeftButtonTap = function()
            local buttons = {
                {{ text = _("Reset to defaults"), align = "left", callback = function()
                    if self_ref._anchored_menu then UIManager:close(self_ref._anchored_menu) end
                    UIManager:show(ConfirmBox:new{
                        text = _("Reset input actions to defaults?\n\nThis restores the default ordering and selection."),
                        ok_callback = reset_callback,
                    })
                end }},
            }
            self_ref:_showAnchoredMenu(self_ref.input_actions_menu, buttons)
        end,
        item_table = menu_items,
        width = self.width,
        height = self.height,
        covers_fullscreen = true,
        is_borderless = true,
        is_popout = false,
        close_callback = on_close_callback,
        onMenuHold = function(_menu_widget, menu_item)
            if menu_item and menu_item.action then
                if not menu_item.in_input or is_general then
                    -- Not in input list, or general context (no reordering) — show info
                    UIManager:show(InfoMessage:new{
                        text = string.format("%s\n\nSource: %s\n\nTap to toggle.",
                            menu_item.action.text or menu_item.action.id,
                            menu_item.action.source or "builtin"),
                        timeout = 3,
                    })
                else
                    -- Non-general: hold to reorder
                    self_ref:_refreshInputActionsMenu(ctx_name, menu_item.action.id)
                    local move_fn = function(id, dir) as:moveInputAction(ctx_name, id, dir) end
                    local function find_pos(target_id)
                        local all = as:getAllActionsWithInputState(ctx_name)
                        local total, pos = 0, nil
                        for _i, a in ipairs(all) do
                            if a.in_input then
                                total = total + 1
                                if a.action.id == target_id then pos = a.input_position end
                            end
                        end
                        return pos, total
                    end
                    local function reshow(moved_id)
                        self_ref:_refreshInputActionsMenu(ctx_name, moved_id)
                        local pos, total = find_pos(moved_id)
                        if pos then
                            self_ref:showOrderItemOptions(moved_id, pos, total,
                                move_fn, reshow, function() self_ref:_refreshInputActionsMenu(ctx_name) end)
                        end
                    end
                    local pos, total = find_pos(menu_item.action.id)
                    if pos then
                        self_ref:showOrderItemOptions(menu_item.action.id, pos, total,
                            move_fn, reshow, function() self_ref:_refreshInputActionsMenu(ctx_name) end)
                    end
                end
            end
        end,
    }
    self.input_actions_menu.onMenuSelect = _sortingMenuOnSelect
    UIManager:show(self.input_actions_menu)
end

return PromptsManager