-- Action Service for KOAssistant
-- Coordinates actions, templates, and system prompts
--
-- Architecture:
--   - Actions: UI buttons with behavior control & API parameters (prompts/actions.lua)
--   - Templates: User prompt text (prompts/templates.lua)
--   - System prompts: AI behavior variants (prompts/system_prompts.lua)
--
-- Request structure:
--   System array: behavior (from variant/override/none) + domain [CACHED]
--   User message: context data + action prompt + runtime input
--
-- Key features:
--   - Per-action behavior control (variant, override, or none)
--   - Per-action API parameters (temperature, max_tokens, thinking)
--   - Prompt caching support for Anthropic

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
    local builtin_overrides = self.settings:readSetting("builtin_action_overrides") or {}

    -- 1. Load built-in actions from prompts/actions.lua
    if self.Actions then
        for _, context in ipairs({"highlight", "book", "multi_book", "general"}) do
            local builtin_actions = self.Actions.getForContext(context)
            for _, action in ipairs(builtin_actions) do
                local key = context .. ":" .. action.id
                local action_data = self:copyAction(action)
                action_data.enabled = not disabled_actions[key]
                action_data.source = "builtin"
                -- Preserve original context for compound contexts (all, both)
                action_data.original_context = action.context

                -- Apply user overrides for built-in actions
                local override = builtin_overrides[key]
                if override then
                    action_data.has_override = true
                    -- Apply each override field
                    if override.behavior_variant then
                        action_data.behavior_variant = override.behavior_variant
                    end
                    if override.behavior_override then
                        action_data.behavior_override = override.behavior_override
                    end
                    if override.temperature then
                        action_data.temperature = override.temperature
                    end
                    if override.extended_thinking then
                        action_data.extended_thinking = override.extended_thinking
                    end
                    if override.thinking_budget then
                        action_data.thinking_budget = override.thinking_budget
                    end
                    if override.provider then
                        action_data.provider = override.provider
                    end
                    if override.model then
                        action_data.model = override.model
                    end
                end

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
        -- Preserve original context for compound contexts (all, both)
        action_data.original_context = action.context
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
    else
        -- Default to highlight + book
        return {"highlight", "book"}
    end
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
-- Handles compound contexts (all, both) by expanding to individual contexts
function ActionService:setActionEnabled(context, action_id, enabled)
    local disabled_actions = self.settings:readSetting("disabled_actions") or {}

    -- Expand compound contexts to individual contexts
    local contexts = self:expandContexts(context)

    for _, ctx in ipairs(contexts) do
        local key = ctx .. ":" .. action_id
        if enabled then
            disabled_actions[key] = nil
        else
            disabled_actions[key] = true
        end
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
    -- Custom actions have prompt directly
    local prompt_text = action.prompt
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

    -- Get language settings (empty = no language instruction)
    local features = self.settings:readSetting("features") or {}
    local user_languages = features.user_languages or ""
    local primary_language = features.primary_language  -- Optional override
    local custom_ai_behavior = features.custom_ai_behavior  -- Custom behavior text

    return self.SystemPrompts.buildAnthropicSystemArray({
        behavior_variant = behavior_variant,
        behavior_override = behavior_override,
        global_variant = global_variant,
        domain_context = config.domain_context,
        enable_caching = true,
        user_languages = user_languages,
        primary_language = primary_language,
        custom_ai_behavior = custom_ai_behavior,
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

    -- Get language settings (empty = no language instruction)
    local features = self.settings:readSetting("features") or {}
    local user_languages = features.user_languages or ""
    local primary_language = features.primary_language  -- Optional override
    local custom_ai_behavior = features.custom_ai_behavior  -- Custom behavior text

    return self.SystemPrompts.buildFlattenedPrompt({
        behavior_variant = behavior_variant,
        behavior_override = behavior_override,
        global_variant = global_variant,
        domain_context = config.domain_context,
        user_languages = user_languages,
        primary_language = primary_language,
        custom_ai_behavior = custom_ai_behavior,
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

-- Get template text for a template ID
function ActionService:getTemplateText(template_id)
    if self.Templates and self.Templates.get then
        return self.Templates.get(template_id)
    end
    return nil
end

-- Adapter: getAllPrompts -> getAllActions (used by dialogs.lua, prompts_manager.lua)
function ActionService:getAllPrompts(context, include_disabled)
    return self:getAllActions(context, include_disabled)
end

-- Adapter: getPrompt -> getAction (used by dialogs.lua)
function ActionService:getPrompt(context, prompt_id)
    return self:getAction(context, prompt_id)
end

-- ============================================================
-- Highlight Menu Quick Actions
-- ============================================================

-- Get ordered list of highlight menu action IDs
function ActionService:getHighlightMenuActions()
    return self.settings:readSetting("highlight_menu_actions") or {}
end

-- Check if action is in highlight menu
function ActionService:isInHighlightMenu(action_id)
    local actions = self:getHighlightMenuActions()
    for _, id in ipairs(actions) do
        if id == action_id then return true end
    end
    return false
end

-- Add action to highlight menu (appends to end)
function ActionService:addToHighlightMenu(action_id)
    local actions = self:getHighlightMenuActions()
    -- Don't add duplicates
    if not self:isInHighlightMenu(action_id) then
        table.insert(actions, action_id)
        self.settings:saveSetting("highlight_menu_actions", actions)
        self.settings:flush()
    end
end

-- Remove action from highlight menu
function ActionService:removeFromHighlightMenu(action_id)
    local actions = self:getHighlightMenuActions()
    for i, id in ipairs(actions) do
        if id == action_id then
            table.remove(actions, i)
            self.settings:saveSetting("highlight_menu_actions", actions)
            self.settings:flush()
            return
        end
    end
end

-- Move action in highlight menu order
function ActionService:moveHighlightMenuAction(action_id, direction)
    local actions = self:getHighlightMenuActions()
    for i, id in ipairs(actions) do
        if id == action_id then
            local new_index = direction == "up" and i - 1 or i + 1
            if new_index >= 1 and new_index <= #actions then
                actions[i], actions[new_index] = actions[new_index], actions[i]
                self.settings:saveSetting("highlight_menu_actions", actions)
                self.settings:flush()
            end
            return
        end
    end
end

-- Get full action objects for highlight menu (resolved, in order)
function ActionService:getHighlightMenuActionObjects()
    local action_ids = self:getHighlightMenuActions()
    local result = {}
    for _, id in ipairs(action_ids) do
        local action = self:getAction("highlight", id)
        if action and action.enabled then
            table.insert(result, action)
        end
    end
    return result
end

return ActionService
