-- Action Service for KOAssistant
-- Coordinates actions, templates, and system prompts
--
-- This module replaces prompt_service.lua with a cleaner architecture:
--   - Actions: UI buttons with behavior control & API parameters (prompts/actions.lua)
--   - Templates: User prompt text (prompts/templates.lua)
--   - System prompts: AI behavior variants (prompts/system_prompts.lua)
--
-- NEW ARCHITECTURE (v0.5):
--   System array: behavior (from variant/override/none) + domain [CACHED]
--   User message: context data + action prompt + runtime input
--
-- Key features:
--   - Per-action behavior control (variant, override, or none)
--   - Per-action API parameters (temperature, max_tokens, thinking)
--   - Prompt caching support for Anthropic
--   - Migration support from legacy prompt_service data

local logger = require("logger")

local ActionService = {}

function ActionService:new(settings)
    local o = {
        settings = settings,
        actions_cache = nil,
        -- Modules loaded lazily
        SystemPrompts = nil,
        Actions = nil,
        Templates = nil,
    }
    setmetatable(o, self)
    self.__index = self
    return o
end

function ActionService:init()
    -- Load modules
    local ok, SystemPrompts = pcall(require, "prompts.system_prompts")
    if ok then
        self.SystemPrompts = SystemPrompts
        logger.info("ActionService: Loaded system_prompts module")
    else
        logger.err("ActionService: Failed to load prompts/system_prompts.lua: " .. tostring(SystemPrompts))
    end

    local ok2, Actions = pcall(require, "prompts.actions")
    if ok2 then
        self.Actions = Actions
        logger.info("ActionService: Loaded actions module")
    else
        logger.err("ActionService: Failed to load prompts/actions.lua: " .. tostring(Actions))
    end

    local ok3, Templates = pcall(require, "prompts.templates")
    if ok3 then
        self.Templates = Templates
        logger.info("ActionService: Loaded templates module")
    else
        logger.err("ActionService: Failed to load prompts/templates.lua: " .. tostring(Templates))
    end

    -- Check for migration needed
    self:checkMigration()
end

-- Check if legacy prompts need migration
function ActionService:checkMigration()
    local migrated = self.settings:readSetting("actions_migrated_v1")
    if migrated then
        return
    end

    local custom_actions = self.settings:readSetting("custom_actions")
    if custom_actions and #custom_actions > 0 then
        logger.info("ActionService: Found custom_actions with " .. #custom_actions .. " entries")
    end
end

-- Get all actions for a specific context
-- @param context: "highlight", "book", "multi_book", "general"
-- @param include_disabled: Include disabled actions
-- @return table: Array of action definitions
function ActionService:getAllActions(context, include_disabled)
    if not self.actions_cache then
        self:loadActions()
    end

    local actions = {}
    local context_actions = self.actions_cache[context] or {}

    for _, action in ipairs(context_actions) do
        if include_disabled or action.enabled then
            table.insert(actions, action)
        end
    end

    return actions
end

-- Get a specific action by ID
-- @param context: Context to search in (or nil for all)
-- @param action_id: The action's unique identifier
-- @return table or nil: Action definition if found
function ActionService:getAction(context, action_id)
    if not self.actions_cache then
        self:loadActions()
    end

    if context then
        local context_actions = self.actions_cache[context] or {}
        for _, action in ipairs(context_actions) do
            if action.id == action_id then
                return action
            end
        end
    else
        -- Search all contexts
        for _, ctx in ipairs({"highlight", "book", "multi_book", "general"}) do
            local context_actions = self.actions_cache[ctx] or {}
            for _, action in ipairs(context_actions) do
                if action.id == action_id then
                    return action
                end
            end
        end
    end

    return nil
end

-- Load all actions into cache
function ActionService:loadActions()
    logger.info("ActionService: Loading all actions")

    self.actions_cache = {
        highlight = {},
        book = {},
        multi_book = {},
        general = {},
    }

    local disabled_actions = self.settings:readSetting("disabled_actions") or {}

    -- 1. Load built-in actions from prompts/actions.lua
    if self.Actions then
        for _, context in ipairs({"highlight", "book", "multi_book", "general"}) do
            local builtin_actions = self.Actions.getForContext(context)
            for _, action in ipairs(builtin_actions) do
                local key = context .. ":" .. action.id
                local action_data = self:copyAction(action)
                action_data.enabled = not disabled_actions[key]
                action_data.source = "builtin"
                table.insert(self.actions_cache[context], action_data)
            end
        end
    end

    -- 2. Load custom actions from custom_actions.lua (future)
    local custom_actions_path = self:getCustomActionsPath()
    if custom_actions_path then
        local ok, custom_actions = pcall(dofile, custom_actions_path)
        if ok and custom_actions then
            logger.info("ActionService: Loading custom actions from custom_actions.lua")
            for i, action in ipairs(custom_actions) do
                local id = "config_" .. i
                self:addCustomAction(id, action, "config", disabled_actions)
            end
        end
    end

    -- 3. Load UI-created actions from settings
    local ui_actions = self.settings:readSetting("custom_actions") or {}
    logger.info("ActionService: Loading " .. #ui_actions .. " UI-created actions")
    for i, action in ipairs(ui_actions) do
        local id = "ui_" .. i
        self:addCustomAction(id, action, "ui", disabled_actions)
    end

    -- 4. Also load legacy prompts for backwards compatibility
    self:loadLegacyPrompts(disabled_actions)

    -- Log summary
    self:logLoadSummary()
end

-- Copy action with all fields
function ActionService:copyAction(action)
    local copy = {}
    for k, v in pairs(action) do
        if type(v) == "table" then
            copy[k] = {}
            for k2, v2 in pairs(v) do
                copy[k][k2] = v2
            end
        else
            copy[k] = v
        end
    end
    return copy
end

-- Add a custom action to the cache
function ActionService:addCustomAction(id, action, source, disabled_actions)
    local contexts = self:expandContexts(action.context)

    for _, context in ipairs(contexts) do
        local key = context .. ":" .. id
        local action_data = self:copyAction(action)
        action_data.id = id
        action_data.enabled = not disabled_actions[key]
        action_data.source = source
        action_data.builtin = false
        table.insert(self.actions_cache[context], action_data)
    end
end

-- Expand context specifiers to array
function ActionService:expandContexts(context)
    if context == "all" then
        return {"highlight", "book", "multi_book", "general"}
    elseif context == "both" then
        return {"highlight", "book"}
    elseif context == "highlight" or context == "book" or context == "multi_book" or context == "general" then
        return {context}
    -- Legacy names
    elseif context == "file_browser" then
        return {"book"}
    elseif context == "multi_file_browser" then
        return {"multi_book"}
    else
        -- Default to highlight + book
        return {"highlight", "book"}
    end
end

-- Load legacy prompts - handles disabled_prompts format only
-- Note: custom_actions are already loaded in step 3, don't load them again here
function ActionService:loadLegacyPrompts(disabled_actions)
    -- Only handle legacy disabled_prompts setting for backwards compatibility
    -- The actual actions are loaded from custom_actions in loadActions() step 3
    local disabled_prompts = self.settings:readSetting("disabled_prompts") or {}

    -- Apply legacy disabled state to already-loaded UI actions
    for _, context in ipairs({"highlight", "book", "multi_book", "general"}) do
        for _, action in ipairs(self.actions_cache[context]) do
            if action.source == "ui" then
                local legacy_key = context .. ":" .. (action.text or action.id)
                if disabled_prompts[legacy_key] then
                    action.enabled = false
                end
            end
        end
    end
end

-- Convert legacy prompt format to action format
-- Maps old system_prompt to behavior_override for backwards compatibility
function ActionService:convertLegacyPrompt(prompt)
    -- Map legacy system_prompt to behavior_override
    local behavior_override = nil
    if prompt.system_prompt and prompt.system_prompt ~= "" then
        behavior_override = prompt.system_prompt
        logger.dbg("ActionService: Migrating legacy system_prompt to behavior_override for: " .. (prompt.text or "unnamed"))
    end

    return {
        text = prompt.text,
        context = prompt.context or "both",
        template = nil,  -- Custom prompts use prompt directly
        prompt = prompt.user_prompt,  -- Renamed from user_prompt
        -- NEW: behavior fields replace system_prompt
        behavior_override = behavior_override,
        behavior_variant = nil,  -- Use global setting
        -- Legacy field kept for reference during migration
        _legacy_system_prompt = prompt.system_prompt,
        provider = prompt.provider,
        model = prompt.model,
        requires = prompt.requires,
        include_book_context = prompt.include_book_context,
        domain = prompt.domain,
        api_params = {
            temperature = 0.7,  -- Default
        },
        builtin = false,
    }
end

-- Log summary of loaded actions
function ActionService:logLoadSummary()
    local counts = {}
    for context, actions in pairs(self.actions_cache) do
        counts[context] = #actions
    end
    logger.info(string.format(
        "ActionService: Loaded %d highlight, %d book, %d multi_book, %d general actions",
        counts.highlight or 0,
        counts.book or 0,
        counts.multi_book or 0,
        counts.general or 0
    ))
end

-- Set action enabled state
function ActionService:setActionEnabled(context, action_id, enabled)
    local disabled_actions = self.settings:readSetting("disabled_actions") or {}
    local key = context .. ":" .. action_id

    if enabled then
        disabled_actions[key] = nil
    else
        disabled_actions[key] = true
    end

    self.settings:saveSetting("disabled_actions", disabled_actions)
    self.settings:flush()

    -- Invalidate cache
    self.actions_cache = nil
end

-- Add a user-created action
function ActionService:addUserAction(action_data)
    local custom_actions = self.settings:readSetting("custom_actions") or {}
    table.insert(custom_actions, action_data)
    self.settings:saveSetting("custom_actions", custom_actions)
    self.settings:flush()
    self.actions_cache = nil
end

-- Update a user-created action
function ActionService:updateUserAction(index, action_data)
    local custom_actions = self.settings:readSetting("custom_actions") or {}
    if custom_actions[index] then
        custom_actions[index] = action_data
        self.settings:saveSetting("custom_actions", custom_actions)
        self.settings:flush()
        self.actions_cache = nil
    end
end

-- Delete a user-created action
function ActionService:deleteUserAction(index)
    local custom_actions = self.settings:readSetting("custom_actions") or {}
    if custom_actions[index] then
        table.remove(custom_actions, index)
        self.settings:saveSetting("custom_actions", custom_actions)
        self.settings:flush()
        self.actions_cache = nil
    end
end

-- Get the behavior variant setting
function ActionService:getBehaviorVariant()
    local features = self.settings:readSetting("features") or {}
    return features.ai_behavior_variant or "full"
end

-- Build user message for an action
-- @param action: Action definition
-- @param context_type: "highlight", "book", "multi_book", "general"
-- @param data: Context data for variable substitution
-- @return string: Rendered user message
function ActionService:buildUserMessage(action, context_type, data)
    -- Custom actions have prompt directly (new field name)
    -- Also check user_prompt for backwards compatibility
    local prompt_text = action.prompt or action.user_prompt
    if prompt_text then
        if self.Templates then
            local variables = self.Templates.buildVariables(context_type, data)
            return self.Templates.substitute(prompt_text, variables)
        else
            return prompt_text
        end
    end

    -- Built-in actions use template reference
    if action.template and self.Templates then
        return self.Templates.renderForAction(action, context_type, data)
    end

    return ""
end

-- Build system prompts for Anthropic (structured array)
--
-- NEW ARCHITECTURE (v0.5):
--   System array contains only: behavior (or none) + domain [CACHED]
--   Action can override behavior via behavior_variant or behavior_override
--
-- @param config: {
--   action: Action definition (optional),
--   domain_context: Domain context string (optional),
-- }
-- @return table: Array of content blocks for Anthropic system parameter
function ActionService:buildAnthropicSystem(config)
    config = config or {}

    if not self.SystemPrompts then
        -- Fallback if module not loaded
        return {{
            type = "text",
            text = "You are a helpful assistant.",
        }}
    end

    -- Get behavior settings from action (if any) or use global
    local behavior_variant = nil
    local behavior_override = nil

    if config.action then
        behavior_variant = config.action.behavior_variant
        behavior_override = config.action.behavior_override
    end

    -- Get global setting as fallback
    local global_variant = self:getBehaviorVariant()

    return self.SystemPrompts.buildAnthropicSystemArray({
        behavior_variant = behavior_variant,
        behavior_override = behavior_override,
        global_variant = global_variant,
        domain_context = config.domain_context,
        enable_caching = true,
    })
end

-- Build flattened system prompt for non-Anthropic providers
--
-- NEW ARCHITECTURE (v0.5):
--   Only includes behavior (or none) + domain
--   Action can override behavior via behavior_variant or behavior_override
--
-- @param config: Same as buildAnthropicSystem
-- @return string: Combined system prompt
function ActionService:buildFlattenedSystem(config)
    config = config or {}

    if not self.SystemPrompts then
        return "You are a helpful assistant."
    end

    -- Get behavior settings from action (if any) or use global
    local behavior_variant = nil
    local behavior_override = nil

    if config.action then
        behavior_variant = config.action.behavior_variant
        behavior_override = config.action.behavior_override
    end

    -- Get global setting as fallback
    local global_variant = self:getBehaviorVariant()

    return self.SystemPrompts.buildFlattenedPrompt({
        behavior_variant = behavior_variant,
        behavior_override = behavior_override,
        global_variant = global_variant,
        domain_context = config.domain_context,
    })
end

-- Get API parameters for an action
-- @param action: Action definition
-- @param defaults: Default parameters from config
-- @return table: Merged API parameters
function ActionService:getApiParams(action, defaults)
    defaults = defaults or {}
    local params = {}

    -- Start with defaults
    for k, v in pairs(defaults) do
        params[k] = v
    end

    -- Override with action-specific params
    if action and action.api_params then
        for k, v in pairs(action.api_params) do
            params[k] = v
        end
    end

    return params
end

-- Check if action requirements are met
function ActionService:checkRequirements(action, metadata)
    if self.Actions then
        return self.Actions.checkRequirements(action, metadata)
    end

    -- Fallback check
    if not action.requires then
        return true
    end

    metadata = metadata or {}
    if action.requires == "author" then
        return metadata.author and metadata.author ~= ""
    elseif action.requires == "title" then
        return metadata.title and metadata.title ~= ""
    end

    return true
end

-- Path helpers
function ActionService:getPluginDir()
    local str = debug.getinfo(2, "S").source:sub(2)
    return str:match("(.*/)")
end

function ActionService:getCustomActionsPath()
    local plugin_dir = self:getPluginDir()
    local path = plugin_dir .. "custom_actions.lua"

    local f = io.open(path, "r")
    if f then
        f:close()
        return path
    end
    return nil
end

-- Initialize the service
function ActionService:initialize()
    self:init()
end

--------------------------------------------------------------------------------
-- Legacy API Adapters
-- These methods provide backwards compatibility with prompt_service.lua API
-- so dialogs.lua can switch to ActionService without breaking
--------------------------------------------------------------------------------

-- Get all prompts for a context (legacy API adapter)
-- Converts actions to the legacy prompt format expected by dialogs.lua
-- @param context: "highlight", "book", "multi_book", "general"
-- @param include_disabled: Include disabled prompts
-- @return table: Array of prompts in legacy format
function ActionService:getAllPrompts(context, include_disabled)
    local actions = self:getAllActions(context, include_disabled)
    local prompts = {}

    for _, action in ipairs(actions) do
        -- Convert action to legacy prompt format
        -- Note: system_prompt is deprecated, use behavior_override instead
        local prompt = {
            id = action.id,
            text = action.text,
            -- NEW: behavior fields
            behavior_variant = action.behavior_variant,
            behavior_override = action.behavior_override,
            -- Legacy field for backwards compatibility (deprecated)
            system_prompt = action.behavior_override or action.system_prompt,
            -- Prompt field (new name) with fallback to user_prompt (old name)
            prompt = action.prompt or action.user_prompt or (action.template and self:getTemplateText(action.template)),
            user_prompt = action.prompt or action.user_prompt or (action.template and self:getTemplateText(action.template)),
            enabled = action.enabled,
            source = action.source,
            provider = action.provider,
            model = action.model,
            requires = action.requires,
            include_book_context = action.include_book_context,
            original_context = action.context,
            domain = action.domain,
            -- Keep action reference for new features
            _action = action,
        }
        table.insert(prompts, prompt)
    end

    return prompts
end

-- Get a specific prompt by ID (legacy API adapter)
-- @param context: Context to search in
-- @param prompt_id: The prompt's unique identifier
-- @return table or nil: Prompt in legacy format if found
function ActionService:getPrompt(context, prompt_id)
    local action = self:getAction(context, prompt_id)
    if not action then
        return nil
    end

    -- Convert to legacy format
    -- Note: system_prompt is deprecated, use behavior_override instead
    return {
        id = action.id,
        text = action.text,
        -- NEW: behavior fields
        behavior_variant = action.behavior_variant,
        behavior_override = action.behavior_override,
        -- Legacy field for backwards compatibility (deprecated)
        system_prompt = action.behavior_override or action.system_prompt,
        -- Prompt field (new name) with fallback to user_prompt (old name)
        prompt = action.prompt or action.user_prompt or (action.template and self:getTemplateText(action.template)),
        user_prompt = action.prompt or action.user_prompt or (action.template and self:getTemplateText(action.template)),
        enabled = action.enabled,
        source = action.source,
        provider = action.provider,
        model = action.model,
        requires = action.requires,
        include_book_context = action.include_book_context,
        original_context = action.context,
        domain = action.domain,
        _action = action,
    }
end

-- Get template text for a template ID
-- Helper for legacy API conversion
function ActionService:getTemplateText(template_id)
    if self.Templates and self.Templates.get then
        return self.Templates.get(template_id)
    end
    return nil
end

-- Get action template (legacy API adapter)
-- Alias for getTemplateText to match PromptService API
function ActionService:getActionTemplate(template_name)
    return self:getTemplateText(template_name)
end

-- Get system prompt for a context (legacy API adapter)
-- This uses the new layered system but returns a flat string for compatibility
--
-- DEPRECATED: In the new architecture, system prompts are just behavior + domain.
-- Context-specific instructions are no longer included in system array.
--
-- @param context: "highlight", "book", "multi_book", "general" (ignored in new architecture)
-- @param prompt_type: Optional specific prompt type (ignored in new architecture)
-- @return string: System prompt text (behavior only)
function ActionService:getSystemPrompt(context, prompt_type)
    -- In the new architecture, getSystemPrompt just returns the global behavior
    -- Context and action-specific prompts go in the user message now
    return self:buildFlattenedSystem({
        domain_context = nil,  -- Domain handled separately in dialogs.lua
        action = nil,  -- No action-specific behavior override
    })
end

-- Set prompt enabled state (legacy API adapter)
-- @param context: Context (can be "all", "both", or specific)
-- @param prompt_text: The prompt's display text
-- @param enabled: Boolean enabled state
function ActionService:setPromptEnabled(context, prompt_text, enabled)
    -- Find the action with matching text
    local contexts_to_check = {}
    if context == "all" then
        contexts_to_check = {"highlight", "book", "multi_book", "general"}
    elseif context == "both" then
        contexts_to_check = {"highlight", "book"}
    else
        contexts_to_check = {context}
    end

    for _, ctx in ipairs(contexts_to_check) do
        local actions = self:getAllActions(ctx, true)
        for _, action in ipairs(actions) do
            if action.text == prompt_text then
                self:setActionEnabled(ctx, action.id, enabled)
            end
        end
    end
end

-- Add a user-created prompt (legacy API adapter)
-- Converts legacy prompt format to action format
-- @param prompt_data: Prompt data (supports both old and new field names)
function ActionService:addUserPrompt(prompt_data)
    local action_data = {
        text = prompt_data.text,
        context = prompt_data.context or "both",
        -- NEW: prompt field (also accepts user_prompt for backwards compatibility)
        prompt = prompt_data.prompt or prompt_data.user_prompt,
        -- NEW: behavior fields (also accepts system_prompt for backwards compatibility)
        behavior_variant = prompt_data.behavior_variant,
        behavior_override = prompt_data.behavior_override or prompt_data.system_prompt,
        provider = prompt_data.provider,
        model = prompt_data.model,
        requires = prompt_data.requires,
        include_book_context = prompt_data.include_book_context,
        domain = prompt_data.domain,
        api_params = {
            temperature = 0.7,
        },
    }
    self:addUserAction(action_data)
end

-- Update a user-created prompt (legacy API adapter)
-- @param index: Index of the prompt to update
-- @param prompt_data: New prompt data (supports both old and new field names)
function ActionService:updateUserPrompt(index, prompt_data)
    local action_data = {
        text = prompt_data.text,
        context = prompt_data.context or "both",
        -- NEW: prompt field (also accepts user_prompt for backwards compatibility)
        prompt = prompt_data.prompt or prompt_data.user_prompt,
        -- NEW: behavior fields (also accepts system_prompt for backwards compatibility)
        behavior_variant = prompt_data.behavior_variant,
        behavior_override = prompt_data.behavior_override or prompt_data.system_prompt,
        provider = prompt_data.provider,
        model = prompt_data.model,
        requires = prompt_data.requires,
        include_book_context = prompt_data.include_book_context,
        domain = prompt_data.domain,
        api_params = {
            temperature = 0.7,
        },
    }
    self:updateUserAction(index, action_data)
end

-- Delete a user-created prompt (legacy API adapter)
-- @param index: Index of the prompt to delete
function ActionService:deleteUserPrompt(index)
    self:deleteUserAction(index)
end

return ActionService
