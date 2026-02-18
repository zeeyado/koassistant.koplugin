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
local Constants = require("koassistant_constants")

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
-- @param has_open_book: Whether a book is currently open (for filtering requires_open_book actions)
-- @return table: Array of action definitions
function ActionService:getAllActions(context, include_disabled, has_open_book)
    if not self.actions_cache then
        self:loadActions()
    end

    local actions = {}
    local context_actions = self.actions_cache[context] or {}
    local metadata = { has_open_book = has_open_book }

    for _, action in ipairs(context_actions) do
        if include_disabled or action.enabled then
            -- Filter actions that require an open book when no book is open
            if self.Actions.checkRequirements(action, metadata) then
                table.insert(actions, action)
            end
        end
    end

    -- Sort alphabetically by action text (case-insensitive) for predictable ordering
    table.sort(actions, function(a, b)
        return (a.text or ""):lower() < (b.text or ""):lower()
    end)

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
        for _, ctx in ipairs(Constants.getAllContexts()) do
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
        for _, context in ipairs(Constants.getAllContexts()) do
            local builtin_actions = self.Actions.getForContext(context)
            for _, action in ipairs(builtin_actions) do
                local key = context .. ":" .. action.id
                local action_data = self:copyAction(action)
                action_data.enabled = not disabled_actions[key]
                action_data.source = "builtin"
                -- Preserve original context for compound contexts (both)
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
                    if override.reasoning_config then
                        action_data.reasoning_config = override.reasoning_config
                    end
                    if override.skip_language_instruction ~= nil then
                        action_data.skip_language_instruction = override.skip_language_instruction
                    end
                    if override.skip_domain ~= nil then
                        action_data.skip_domain = override.skip_domain
                    end
                    if override.include_book_context ~= nil then
                        action_data.include_book_context = override.include_book_context
                    end
                    -- Context extraction flag overrides
                    if override.use_book_text ~= nil then
                        action_data.use_book_text = override.use_book_text
                    end
                    if override.use_highlights ~= nil then
                        action_data.use_highlights = override.use_highlights
                    end
                    if override.use_annotations ~= nil then
                        action_data.use_annotations = override.use_annotations
                    end
                    if override.use_reading_progress ~= nil then
                        action_data.use_reading_progress = override.use_reading_progress
                    end
                    if override.use_reading_stats ~= nil then
                        action_data.use_reading_stats = override.use_reading_stats
                    end
                    if override.use_notebook ~= nil then
                        action_data.use_notebook = override.use_notebook
                    end
                    -- Web search override (tri-state: true/false/"global")
                    if override.enable_web_search ~= nil then
                        if override.enable_web_search == "global" then
                            action_data.enable_web_search = nil  -- Reset to follow global
                        else
                            action_data.enable_web_search = override.enable_web_search
                        end
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

    -- 2.5. Migrate custom actions (infer open book flags from prompt text)
    -- This ensures actions created before flag inference was added get their flags set
    self:migrateCustomActionsOpenBookFlags()

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
        -- Preserve original context for compound contexts (both)
        action_data.original_context = action.context
        table.insert(self.actions_cache[context], action_data)
    end
end

-- Expand context specifiers to array
-- Delegates to Constants.expandContext() for single source of truth
function ActionService:expandContexts(context)
    return Constants.expandContext(context)
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

-- Migrate custom actions to infer open book flags from prompt text
-- This runs once per session to fix actions created before flag inference was added
-- SECURITY: Never infers double-gated flags - those require explicit user checkbox
-- @return boolean: true if any actions were migrated
function ActionService:migrateCustomActionsOpenBookFlags()
    if not self.Actions or not self.Actions.inferOpenBookFlags then
        return false
    end

    local custom_actions = self.settings:readSetting("custom_actions") or {}
    if #custom_actions == 0 then
        return false
    end

    local migrated_count = 0
    local open_book_flags = self.Actions.OPEN_BOOK_FLAGS or {}

    -- Build lookup table for double-gated flags (must never be auto-inferred)
    local double_gated = {}
    for _, flag in ipairs(self.Actions.DOUBLE_GATED_FLAGS or {}) do
        double_gated[flag] = true
    end

    for _idx, action in ipairs(custom_actions) do
        -- Check if action already has any open book flags set
        local has_existing_flags = false
        for _, flag in ipairs(open_book_flags) do
            if action[flag] then
                has_existing_flags = true
                break
            end
        end

        -- If no existing flags, try to infer from prompt text
        -- But SKIP double-gated flags - those require explicit user consent
        if not has_existing_flags and action.prompt then
            local inferred = self.Actions.inferOpenBookFlags(action.prompt)
            local flags_added = false
            for flag, value in pairs(inferred) do
                -- Only set non-sensitive flags (e.g., use_reading_progress, use_reading_stats)
                if value and not double_gated[flag] then
                    action[flag] = true
                    flags_added = true
                end
            end
            if flags_added then
                migrated_count = migrated_count + 1
            end
        end
    end

    if migrated_count > 0 then
        self.settings:saveSetting("custom_actions", custom_actions)
        self.settings:flush()
        logger.info("ActionService: Migrated " .. migrated_count .. " custom action(s) with inferred open book flags")
    end

    return migrated_count > 0
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
    return features.selected_behavior or "standard"
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

    -- Get language settings (auto-detects from KOReader when empty)
    local features = self.settings:readSetting("features") or {}
    local interaction_languages = features.interaction_languages  -- New array format
    local user_languages = features.user_languages or ""  -- Old string format (backward compat)
    local primary_language = features.primary_language  -- Optional override
    local custom_ai_behavior = features.custom_ai_behavior  -- Custom behavior text

    return self.SystemPrompts.buildAnthropicSystemArray({
        behavior_variant = behavior_variant,
        behavior_override = behavior_override,
        global_variant = global_variant,
        domain_context = config.domain_context,
        enable_caching = true,
        interaction_languages = interaction_languages,
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

    -- Get language settings (auto-detects from KOReader when empty)
    local features = self.settings:readSetting("features") or {}
    local interaction_languages = features.interaction_languages  -- New array format
    local user_languages = features.user_languages or ""  -- Old string format (backward compat)
    local primary_language = features.primary_language  -- Optional override
    local custom_ai_behavior = features.custom_ai_behavior  -- Custom behavior text

    return self.SystemPrompts.buildFlattenedPrompt({
        behavior_variant = behavior_variant,
        behavior_override = behavior_override,
        global_variant = global_variant,
        domain_context = config.domain_context,
        interaction_languages = interaction_languages,
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

    -- Fallback: no requirements to check
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
-- @param has_open_book: Whether a book is currently open (for filtering requires_open_book actions)
function ActionService:getAllPrompts(context, include_disabled, has_open_book)
    return self:getAllActions(context, include_disabled, has_open_book)
end

-- Adapter: getPrompt -> getAction (used by dialogs.lua)
function ActionService:getPrompt(context, prompt_id)
    return self:getAction(context, prompt_id)
end

-- ============================================================
-- Highlight Menu Quick Actions
-- ============================================================

-- Build default action list from flags on action definitions
-- Scans highlight (and special) actions for the given flag field
-- Flag value is a number used for sort order
local function buildDefaultFromFlags(actions_module, flag_field)
    local result = {}
    if not actions_module then return result end
    -- Scan highlight actions
    if actions_module.highlight then
        for _id, action in pairs(actions_module.highlight) do
            if action[flag_field] then
                table.insert(result, { id = action.id, order = action[flag_field] })
            end
        end
    end
    -- Scan special actions (translate, etc.)
    if actions_module.special then
        for _id, action in pairs(actions_module.special) do
            if action[flag_field] then
                table.insert(result, { id = action.id, order = action[flag_field] })
            end
        end
    end
    table.sort(result, function(a, b) return a.order < b.order end)
    local ids = {}
    for _i, item in ipairs(result) do
        table.insert(ids, item.id)
    end
    return ids
end

-- Process a saved action list: prune stale IDs and inject new flagged defaults
-- Returns the processed list (may be modified) and whether changes were made
local function processActionList(service, saved, flag_field, dismissed_key)
    local dismissed = service.settings:readSetting(dismissed_key) or {}
    local dismissed_set = {}
    for _i, id in ipairs(dismissed) do dismissed_set[id] = true end

    -- Prune stale IDs (actions that no longer exist)
    local pruned = {}
    for _i, id in ipairs(saved) do
        if service:getAction("highlight", id) then
            table.insert(pruned, id)
        end
    end

    -- Build set of current IDs for quick lookup
    local current_set = {}
    for _i, id in ipairs(pruned) do current_set[id] = true end

    -- Inject new flagged defaults not in list and not dismissed
    local defaults = buildDefaultFromFlags(service.Actions, flag_field)
    for _i, id in ipairs(defaults) do
        if not current_set[id] and not dismissed_set[id] then
            local action = service:getAction("highlight", id)
            local pos = action and action[flag_field] or (#pruned + 1)
            pos = math.min(pos, #pruned + 1)
            table.insert(pruned, pos, id)
            current_set[id] = true
        end
    end

    return pruned
end

-- Get ordered list of highlight menu action IDs
function ActionService:getHighlightMenuActions()
    local saved = self.settings:readSetting("highlight_menu_actions")
    if not saved then
        return buildDefaultFromFlags(self.Actions, "in_highlight_menu")
    end
    local processed = processActionList(self, saved, "in_highlight_menu", "_dismissed_highlight_menu_actions")
    -- Always save processed list (handles prune and inject)
    self.settings:saveSetting("highlight_menu_actions", processed)
    return processed
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
        -- Remove from dismissed list if present
        local dismissed = self.settings:readSetting("_dismissed_highlight_menu_actions") or {}
        for i, id in ipairs(dismissed) do
            if id == action_id then
                table.remove(dismissed, i)
                self.settings:saveSetting("_dismissed_highlight_menu_actions", dismissed)
                break
            end
        end
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
            -- Add to dismissed list so it won't be auto-injected again
            local dismissed = self.settings:readSetting("_dismissed_highlight_menu_actions") or {}
            table.insert(dismissed, action_id)
            self.settings:saveSetting("_dismissed_highlight_menu_actions", dismissed)
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
-- @param has_open_book: boolean indicating if a book is currently open (for filtering)
-- @param document_path: optional string path to check cache requirements
function ActionService:getHighlightMenuActionObjects(has_open_book, document_path)
    local action_ids = self:getHighlightMenuActions()
    local result = {}
    local metadata = { has_open_book = has_open_book }
    for _, id in ipairs(action_ids) do
        local action = self:getAction("highlight", id)
        if action and action.enabled and self.Actions.checkRequirements(action, metadata) then
            local include = true
            if action.requires_xray_cache and document_path then
                local ActionCache = require("koassistant_action_cache")
                local cached = ActionCache.getXrayCache(document_path)
                if not cached or not cached.result then
                    include = false
                end
            end
            if include then
                table.insert(result, action)
            end
        end
    end
    return result
end

-- Get all highlight context actions with their menu inclusion state
-- Returns array of { action, in_menu, menu_position }
-- Used by the highlight menu manager UI
function ActionService:getAllHighlightActionsWithMenuState()
    -- Get all highlight-context actions (including from 'both' contexts)
    local all_actions = self:getAllActions("highlight", true)  -- Include disabled
    local menu_ids = self:getHighlightMenuActions()

    -- Create lookup for menu positions
    local menu_positions = {}
    for i, id in ipairs(menu_ids) do
        menu_positions[id] = i
    end

    local result = {}
    for _, action in ipairs(all_actions) do
        table.insert(result, {
            action = action,
            in_menu = menu_positions[action.id] ~= nil,
            menu_position = menu_positions[action.id],
        })
    end

    -- Sort: menu items first (by position), then non-menu items (alphabetically)
    table.sort(result, function(a, b)
        if a.in_menu and b.in_menu then
            return a.menu_position < b.menu_position
        elseif a.in_menu then
            return true
        elseif b.in_menu then
            return false
        else
            return (a.action.text or "") < (b.action.text or "")
        end
    end)

    return result
end

-- Toggle action inclusion in highlight menu
-- Returns: true if now in menu, false if removed from menu
function ActionService:toggleHighlightMenuAction(action_id)
    if self:isInHighlightMenu(action_id) then
        self:removeFromHighlightMenu(action_id)
        return false
    else
        self:addToHighlightMenu(action_id)
        return true
    end
end

-- ============================================================
-- Dictionary Popup Actions (similar to highlight menu)
-- ============================================================

-- Get ordered list of dictionary popup action IDs
function ActionService:getDictionaryPopupActions()
    local saved = self.settings:readSetting("dictionary_popup_actions")
    if not saved then
        return buildDefaultFromFlags(self.Actions, "in_dictionary_popup")
    end
    local processed = processActionList(self, saved, "in_dictionary_popup", "_dismissed_dictionary_popup_actions")
    -- Always save processed list (handles prune and inject)
    self.settings:saveSetting("dictionary_popup_actions", processed)
    return processed
end

-- Check if action is in dictionary popup
function ActionService:isInDictionaryPopup(action_id)
    local actions = self:getDictionaryPopupActions()
    for _i, id in ipairs(actions) do
        if id == action_id then
            return true
        end
    end
    return false
end

-- Add action to dictionary popup
function ActionService:addToDictionaryPopup(action_id)
    local actions = self:getDictionaryPopupActions()
    -- Don't add duplicates
    if not self:isInDictionaryPopup(action_id) then
        table.insert(actions, action_id)
        self.settings:saveSetting("dictionary_popup_actions", actions)
        -- Remove from dismissed list if present
        local dismissed = self.settings:readSetting("_dismissed_dictionary_popup_actions") or {}
        for i, id in ipairs(dismissed) do
            if id == action_id then
                table.remove(dismissed, i)
                self.settings:saveSetting("_dismissed_dictionary_popup_actions", dismissed)
                break
            end
        end
        self.settings:flush()
    end
end

-- Remove action from dictionary popup
function ActionService:removeFromDictionaryPopup(action_id)
    local actions = self:getDictionaryPopupActions()
    for i, id in ipairs(actions) do
        if id == action_id then
            table.remove(actions, i)
            self.settings:saveSetting("dictionary_popup_actions", actions)
            -- Add to dismissed list so it won't be auto-injected again
            local dismissed = self.settings:readSetting("_dismissed_dictionary_popup_actions") or {}
            table.insert(dismissed, action_id)
            self.settings:saveSetting("_dismissed_dictionary_popup_actions", dismissed)
            self.settings:flush()
            return
        end
    end
end

-- Move action in dictionary popup order
function ActionService:moveDictionaryPopupAction(action_id, direction)
    local actions = self:getDictionaryPopupActions()
    for i, id in ipairs(actions) do
        if id == action_id then
            local new_index = direction == "up" and i - 1 or i + 1
            if new_index >= 1 and new_index <= #actions then
                actions[i], actions[new_index] = actions[new_index], actions[i]
                self.settings:saveSetting("dictionary_popup_actions", actions)
                self.settings:flush()
            end
            return
        end
    end
end

-- Get full action objects for dictionary popup (resolved, in order)
-- @param has_open_book: boolean indicating if a book is currently open (for filtering)
-- @param document_path: optional string path to check cache requirements
function ActionService:getDictionaryPopupActionObjects(has_open_book, document_path)
    local action_ids = self:getDictionaryPopupActions()
    local result = {}
    local metadata = { has_open_book = has_open_book }
    for _i, id in ipairs(action_ids) do
        local action = self:getAction("highlight", id)
        if action and action.enabled and self.Actions.checkRequirements(action, metadata) then
            local include = true
            if action.requires_xray_cache and document_path then
                local ActionCache = require("koassistant_action_cache")
                local cached = ActionCache.getXrayCache(document_path)
                if not cached or not cached.result then
                    include = false
                end
            end
            if include then
                table.insert(result, action)
            end
        end
    end
    return result
end

-- Get all highlight context actions with their dictionary popup inclusion state
-- Returns array of { action, in_popup, popup_position }
-- Used by the dictionary popup manager UI
function ActionService:getAllHighlightActionsWithPopupState()
    -- Get all highlight-context actions (including from 'both' contexts)
    local all_actions = self:getAllActions("highlight", true)  -- Include disabled
    local popup_ids = self:getDictionaryPopupActions()

    -- Create lookup for popup positions
    local popup_positions = {}
    for i, id in ipairs(popup_ids) do
        popup_positions[id] = i
    end

    local result = {}
    for _i, action in ipairs(all_actions) do
        table.insert(result, {
            action = action,
            in_popup = popup_positions[action.id] ~= nil,
            popup_position = popup_positions[action.id],
        })
    end

    -- Sort: popup items first (by position), then non-popup items (alphabetically)
    table.sort(result, function(a, b)
        if a.in_popup and b.in_popup then
            return a.popup_position < b.popup_position
        elseif a.in_popup then
            return true
        elseif b.in_popup then
            return false
        else
            return (a.action.text or "") < (b.action.text or "")
        end
    end)

    return result
end

-- Toggle action inclusion in dictionary popup
-- Returns: true if now in popup, false if removed from popup
function ActionService:toggleDictionaryPopupAction(action_id)
    if self:isInDictionaryPopup(action_id) then
        self:removeFromDictionaryPopup(action_id)
        return false
    else
        self:addToDictionaryPopup(action_id)
        return true
    end
end

-- ============================================================
-- General Menu Actions (for general context chat input dialog)
-- ============================================================

-- Build default general menu list from in_general_menu flag
local function buildDefaultGeneralMenuFlags(actions_module)
    local result = {}
    if not actions_module then return result end
    -- Scan general actions
    if actions_module.general then
        for _id, action in pairs(actions_module.general) do
            if action.in_general_menu then
                table.insert(result, { id = action.id, order = action.in_general_menu })
            end
        end
    end
    table.sort(result, function(a, b) return a.order < b.order end)
    local ids = {}
    for _i, item in ipairs(result) do
        table.insert(ids, item.id)
    end
    return ids
end

-- Process general menu list: prune stale IDs and inject new flagged defaults
local function processGeneralMenuList(service, saved)
    local dismissed = service.settings:readSetting("_dismissed_general_menu_actions") or {}
    local dismissed_set = {}
    for _i, id in ipairs(dismissed) do dismissed_set[id] = true end

    -- Prune stale IDs (actions that no longer exist)
    local pruned = {}
    for _i, id in ipairs(saved) do
        if service:getAction("general", id) then
            table.insert(pruned, id)
        end
    end

    -- Build set of current IDs for quick lookup
    local current_set = {}
    for _i, id in ipairs(pruned) do current_set[id] = true end

    -- Inject new flagged defaults not in list and not dismissed
    local defaults = buildDefaultGeneralMenuFlags(service.Actions)
    for _i, id in ipairs(defaults) do
        if not current_set[id] and not dismissed_set[id] then
            local action = service:getAction("general", id)
            local pos = action and action.in_general_menu or (#pruned + 1)
            pos = math.min(pos, #pruned + 1)
            table.insert(pruned, pos, id)
            current_set[id] = true
        end
    end

    return pruned
end

-- Get ordered list of general menu action IDs
function ActionService:getGeneralMenuActions()
    local saved = self.settings:readSetting("general_menu_actions")
    if not saved then
        return buildDefaultGeneralMenuFlags(self.Actions)
    end
    local processed = processGeneralMenuList(self, saved)
    -- Always save processed list (handles prune and inject)
    self.settings:saveSetting("general_menu_actions", processed)
    return processed
end

-- Check if action is in general menu
function ActionService:isInGeneralMenu(action_id)
    local actions = self:getGeneralMenuActions()
    for _, id in ipairs(actions) do
        if id == action_id then return true end
    end
    return false
end

-- Add action to general menu (appends to end)
function ActionService:addToGeneralMenu(action_id)
    local actions = self:getGeneralMenuActions()
    -- Don't add duplicates
    if not self:isInGeneralMenu(action_id) then
        table.insert(actions, action_id)
        self.settings:saveSetting("general_menu_actions", actions)
        -- Remove from dismissed list if present
        local dismissed = self.settings:readSetting("_dismissed_general_menu_actions") or {}
        for i, id in ipairs(dismissed) do
            if id == action_id then
                table.remove(dismissed, i)
                self.settings:saveSetting("_dismissed_general_menu_actions", dismissed)
                break
            end
        end
        self.settings:flush()
    end
end

-- Remove action from general menu
function ActionService:removeFromGeneralMenu(action_id)
    local actions = self:getGeneralMenuActions()
    for i, id in ipairs(actions) do
        if id == action_id then
            table.remove(actions, i)
            self.settings:saveSetting("general_menu_actions", actions)
            -- Add to dismissed list so it won't be auto-injected again
            local dismissed = self.settings:readSetting("_dismissed_general_menu_actions") or {}
            table.insert(dismissed, action_id)
            self.settings:saveSetting("_dismissed_general_menu_actions", dismissed)
            self.settings:flush()
            return
        end
    end
end

-- Toggle action inclusion in general menu
-- Returns: true if now in menu, false if removed from menu
function ActionService:toggleGeneralMenuAction(action_id)
    if self:isInGeneralMenu(action_id) then
        self:removeFromGeneralMenu(action_id)
        return false
    else
        self:addToGeneralMenu(action_id)
        return true
    end
end

-- Get full action objects for general menu (resolved, in order)
function ActionService:getGeneralMenuActionObjects()
    local action_ids = self:getGeneralMenuActions()
    local result = {}
    for _, id in ipairs(action_ids) do
        local action = self:getAction("general", id)
        if action and action.enabled then
            table.insert(result, action)
        end
    end
    return result
end

-- Get all general context actions with their menu inclusion state
-- Returns array of { action, in_menu, menu_position }
-- Used by the prompts manager UI
function ActionService:getAllGeneralActionsWithMenuState()
    local all_actions = self:getAllActions("general", true)  -- Include disabled
    local menu_ids = self:getGeneralMenuActions()

    -- Create lookup for menu positions
    local menu_positions = {}
    for i, id in ipairs(menu_ids) do
        menu_positions[id] = i
    end

    local result = {}
    for _, action in ipairs(all_actions) do
        table.insert(result, {
            action = action,
            in_menu = menu_positions[action.id] ~= nil,
            menu_position = menu_positions[action.id],
        })
    end

    -- Sort: menu items first (by position), then non-menu items (alphabetically)
    table.sort(result, function(a, b)
        if a.in_menu and b.in_menu then
            return a.menu_position < b.menu_position
        elseif a.in_menu then
            return true
        elseif b.in_menu then
            return false
        else
            return (a.action.text or ""):lower() < (b.action.text or ""):lower()
        end
    end)

    return result
end

-- ============================================================
-- Reading Features Actions (X-Ray, Recap, Analyze My Notes)
-- ============================================================

-- Get ordered list of reading features actions (from in_reading_features flag)
-- Unlike highlight/dictionary menus, this returns full action objects
-- Used by settings schema and gesture registration
function ActionService:getReadingFeaturesActions()
    if not self.Actions then
        return {}
    end

    local result = {}

    -- Scan book context actions for in_reading_features flag
    if self.Actions.book then
        for _id, action in pairs(self.Actions.book) do
            if action.in_reading_features then
                table.insert(result, {
                    id = action.id,
                    text = action.text,
                    info_text = action.info_text,
                    order = action.in_reading_features,
                })
            end
        end
    end

    -- Sort by order
    table.sort(result, function(a, b) return a.order < b.order end)

    return result
end

-- ============================================================
-- Quick Actions Menu Support
-- ============================================================

-- Build default quick actions list from in_quick_actions flag (book context)
local function buildQuickActionsDefaults(actions_module)
    local result = {}
    if not actions_module or not actions_module.book then return result end
    for _id, action in pairs(actions_module.book) do
        if action.in_quick_actions then
            table.insert(result, { id = action.id, order = action.in_quick_actions })
        end
    end
    table.sort(result, function(a, b) return a.order < b.order end)
    local ids = {}
    for _i, item in ipairs(result) do
        table.insert(ids, item.id)
    end
    return ids
end

-- Process a saved quick actions list: prune stale IDs and inject new flagged defaults
local function processQuickActionsList(service, saved, dismissed_key)
    local dismissed = service.settings:readSetting(dismissed_key) or {}
    local dismissed_set = {}
    for _i, id in ipairs(dismissed) do dismissed_set[id] = true end

    -- Prune stale IDs (actions that no longer exist)
    local pruned = {}
    for _i, id in ipairs(saved) do
        if service:getAction("book", id) then
            table.insert(pruned, id)
        end
    end

    -- Build set of current IDs for quick lookup
    local current_set = {}
    for _i, id in ipairs(pruned) do current_set[id] = true end

    -- Inject new flagged defaults not in list and not dismissed
    local defaults = buildQuickActionsDefaults(service.Actions)
    for _i, id in ipairs(defaults) do
        if not current_set[id] and not dismissed_set[id] then
            local action = service:getAction("book", id)
            local pos = action and action.in_quick_actions or (#pruned + 1)
            pos = math.min(pos, #pruned + 1)
            table.insert(pruned, pos, id)
            current_set[id] = true
        end
    end

    return pruned
end

-- Get ordered list of quick action IDs
-- Returns array of action IDs (strings), includes both built-in defaults and user-added
-- Preserves user-defined order (sortable via Quick Actions Settings)
function ActionService:getQuickActions()
    local saved = self.settings:readSetting("quick_actions_list")
    if not saved then
        -- No saved list yet, build defaults sorted by in_quick_actions flag
        local defaults = buildQuickActionsDefaults(self.Actions)
        return defaults
    end
    local processed = processQuickActionsList(self, saved, "_dismissed_quick_actions")
    -- Always save processed list (handles prune and inject)
    self.settings:saveSetting("quick_actions_list", processed)
    return processed
end

-- Check if action is in quick actions
function ActionService:isInQuickActions(action_id)
    local actions = self:getQuickActions()
    for _i, id in ipairs(actions) do
        if id == action_id then
            return true
        end
    end
    return false
end

-- Add action to quick actions (appends to end)
function ActionService:addToQuickActions(action_id)
    local actions = self:getQuickActions()
    -- Don't add duplicates
    if not self:isInQuickActions(action_id) then
        table.insert(actions, action_id)
        self.settings:saveSetting("quick_actions_list", actions)
        -- Remove from dismissed list if present
        local dismissed = self.settings:readSetting("_dismissed_quick_actions") or {}
        for i, id in ipairs(dismissed) do
            if id == action_id then
                table.remove(dismissed, i)
                self.settings:saveSetting("_dismissed_quick_actions", dismissed)
                break
            end
        end
        self.settings:flush()
    end
end

-- Remove action from quick actions
function ActionService:removeFromQuickActions(action_id)
    local actions = self:getQuickActions()
    for i, id in ipairs(actions) do
        if id == action_id then
            table.remove(actions, i)
            self.settings:saveSetting("quick_actions_list", actions)
            -- Add to dismissed list so it won't be auto-injected again
            local dismissed = self.settings:readSetting("_dismissed_quick_actions") or {}
            table.insert(dismissed, action_id)
            self.settings:saveSetting("_dismissed_quick_actions", dismissed)
            self.settings:flush()
            return
        end
    end
end

-- Toggle action inclusion in quick actions
-- Returns: true if now in quick actions, false if removed
function ActionService:toggleQuickAction(action_id)
    if self:isInQuickActions(action_id) then
        self:removeFromQuickActions(action_id)
        return false
    else
        self:addToQuickActions(action_id)
        return true
    end
end

-- Move action in quick actions order
function ActionService:moveQuickAction(action_id, direction)
    local actions = self:getQuickActions()
    for i, id in ipairs(actions) do
        if id == action_id then
            local new_index = direction == "up" and i - 1 or i + 1
            if new_index >= 1 and new_index <= #actions then
                actions[i], actions[new_index] = actions[new_index], actions[i]
                self.settings:saveSetting("quick_actions_list", actions)
                self.settings:flush()
            end
            return
        end
    end
end

-- Get all book actions with their quick actions inclusion state
-- Returns array of { action, in_quick_actions, quick_actions_position }
-- Used by the quick actions manager UI
function ActionService:getAllBookActionsWithQuickActionsState()
    -- Get all book-context actions (including from 'both' contexts)
    local all_actions = self:getAllActions("book", true)  -- Include disabled
    local quick_ids = self:getQuickActions()

    -- Create lookup for quick actions positions
    local quick_positions = {}
    for i, id in ipairs(quick_ids) do
        quick_positions[id] = i
    end

    local result = {}
    for _i, action in ipairs(all_actions) do
        table.insert(result, {
            action = action,
            in_quick_actions = quick_positions[action.id] ~= nil,
            quick_actions_position = quick_positions[action.id],
        })
    end

    -- Sort: quick action items first (by position), then non-quick items (alphabetically)
    table.sort(result, function(a, b)
        if a.in_quick_actions and b.in_quick_actions then
            return a.quick_actions_position < b.quick_actions_position
        elseif a.in_quick_actions then
            return true
        elseif b.in_quick_actions then
            return false
        else
            return (a.action.text or "") < (b.action.text or "")
        end
    end)

    return result
end

-- Legacy method for backwards compatibility - now just calls getQuickActions
function ActionService:getUserQuickActions()
    return self:getQuickActions()
end

-- ============================================================
-- Generic Ordered List Processing
-- ============================================================
-- Shared by QA utilities ordering and QS items ordering.
-- Prunes stale IDs, deduplicates, and appends new valid IDs.

local function processOrderedList(stored_order, valid_ids)
    local valid_set = {}
    for _i, id in ipairs(valid_ids) do valid_set[id] = true end

    local result = {}
    local seen = {}
    -- Keep stored items that are still valid
    for _i, id in ipairs(stored_order) do
        if valid_set[id] and not seen[id] then
            table.insert(result, id)
            seen[id] = true
        end
    end
    -- Append new valid IDs not in stored order
    for _i, id in ipairs(valid_ids) do
        if not seen[id] then
            table.insert(result, id)
        end
    end

    return result
end

-- ============================================================
-- QA Utilities Ordering
-- ============================================================

-- Get default QA utility IDs from Constants
local function getQaUtilitiesDefaultOrder()
    local ids = {}
    for _i, util in ipairs(Constants.QUICK_ACTION_UTILITIES) do
        table.insert(ids, util.id)
    end
    return ids
end

-- Get ordered list of QA utility IDs
function ActionService:getQaUtilitiesOrder()
    local saved = self.settings:readSetting("qa_utilities_order")
    if not saved then
        return getQaUtilitiesDefaultOrder()
    end
    local processed = processOrderedList(saved, getQaUtilitiesDefaultOrder())
    self.settings:saveSetting("qa_utilities_order", processed)
    return processed
end

-- Move QA utility in order
function ActionService:moveQaUtility(util_id, direction)
    local order = self:getQaUtilitiesOrder()
    for i, id in ipairs(order) do
        if id == util_id then
            local new_index = direction == "up" and i - 1 or i + 1
            if new_index >= 1 and new_index <= #order then
                order[i], order[new_index] = order[new_index], order[i]
                self.settings:saveSetting("qa_utilities_order", order)
                self.settings:flush()
            end
            return
        end
    end
end

-- ============================================================
-- QS Items Ordering
-- ============================================================

-- Get ordered list of QS item IDs
function ActionService:getQsItemsOrder()
    local saved = self.settings:readSetting("qs_items_order")
    if not saved then
        -- Return a copy to avoid callers mutating the constant
        local copy = {}
        for _i, id in ipairs(Constants.QS_ITEMS_DEFAULT_ORDER) do
            copy[#copy + 1] = id
        end
        return copy
    end
    local processed = processOrderedList(saved, Constants.QS_ITEMS_DEFAULT_ORDER)
    -- Migration: insert text_extraction before chat_history for existing users
    -- (processOrderedList appends new items at end; relocate if needed)
    local te_idx, ch_idx
    for i, id in ipairs(processed) do
        if id == "text_extraction" then te_idx = i end
        if id == "chat_history" then ch_idx = i end
    end
    if te_idx and ch_idx and te_idx > ch_idx then
        table.remove(processed, te_idx)
        -- Re-find chat_history after removal (index may have shifted)
        for i, id in ipairs(processed) do
            if id == "chat_history" then
                table.insert(processed, i, "text_extraction")
                break
            end
        end
    end
    self.settings:saveSetting("qs_items_order", processed)
    return processed
end

-- Move QS item in order
function ActionService:moveQsItem(item_id, direction)
    local order = self:getQsItemsOrder()
    for i, id in ipairs(order) do
        if id == item_id then
            local new_index = direction == "up" and i - 1 or i + 1
            if new_index >= 1 and new_index <= #order then
                order[i], order[new_index] = order[new_index], order[i]
                self.settings:saveSetting("qs_items_order", order)
                self.settings:flush()
            end
            return
        end
    end
end

-- ============================================================
-- File Browser Actions Support
-- ============================================================
-- Users can pin non-reading book actions directly to the file browser
-- long-press menu for quick access without opening the action selector.
-- Storage: {id, text} pairs (text stored at add-time since ActionService
-- may not be initialized when generateFileDialogRows() renders buttons).

-- Build default file browser actions list from in_file_browser flag (book context)
local function buildFileBrowserDefaults(actions_module)
    local result = {}
    if not actions_module or not actions_module.book then return result end
    for _id, action in pairs(actions_module.book) do
        if action.in_file_browser then
            table.insert(result, { id = action.id, text = action.text, order = action.in_file_browser })
        end
    end
    table.sort(result, function(a, b) return a.order < b.order end)
    local items = {}
    for _i, item in ipairs(result) do
        table.insert(items, { id = item.id, text = item.text })
    end
    return items
end

-- Process a saved file browser actions list: prune stale IDs and inject new flagged defaults
local function processFileBrowserList(service, saved, dismissed_key)
    local dismissed = service.settings:readSetting(dismissed_key) or {}
    local dismissed_set = {}
    for _i, id in ipairs(dismissed) do dismissed_set[id] = true end

    -- Prune stale IDs (actions that no longer exist)
    local pruned = {}
    for _i, item in ipairs(saved) do
        if service:getAction("book", item.id) then
            table.insert(pruned, item)
        end
    end

    -- Build set of current IDs for quick lookup
    local current_set = {}
    for _i, item in ipairs(pruned) do current_set[item.id] = true end

    -- Inject new flagged defaults not in list and not dismissed
    local defaults = buildFileBrowserDefaults(service.Actions)
    for _i, item in ipairs(defaults) do
        if not current_set[item.id] and not dismissed_set[item.id] then
            table.insert(pruned, item)
            current_set[item.id] = true
        end
    end

    return pruned
end

-- Get ordered list of file browser action {id, text} pairs
function ActionService:getFileBrowserActions()
    local saved = self.settings:readSetting("file_browser_actions")
    if not saved then
        local defaults = buildFileBrowserDefaults(self.Actions)
        return defaults
    end
    local processed = processFileBrowserList(self, saved, "_dismissed_file_browser_actions")
    self.settings:saveSetting("file_browser_actions", processed)
    return processed
end

-- Check if action is in file browser actions
function ActionService:isInFileBrowser(action_id)
    local actions = self:getFileBrowserActions()
    for _i, item in ipairs(actions) do
        if item.id == action_id then
            return true
        end
    end
    return false
end

-- Add action to file browser actions (appends to end)
function ActionService:addToFileBrowser(action_id)
    if self:isInFileBrowser(action_id) then return end
    local actions = self:getFileBrowserActions()
    -- Look up display text from the action object
    local action = self:getAction("book", action_id)
    local text = action and action.text or action_id
    table.insert(actions, { id = action_id, text = text })
    self.settings:saveSetting("file_browser_actions", actions)
    -- Remove from dismissed list if present
    local dismissed = self.settings:readSetting("_dismissed_file_browser_actions") or {}
    for i, id in ipairs(dismissed) do
        if id == action_id then
            table.remove(dismissed, i)
            self.settings:saveSetting("_dismissed_file_browser_actions", dismissed)
            break
        end
    end
    self.settings:flush()
end

-- Remove action from file browser actions
function ActionService:removeFromFileBrowser(action_id)
    local actions = self:getFileBrowserActions()
    for i, item in ipairs(actions) do
        if item.id == action_id then
            table.remove(actions, i)
            self.settings:saveSetting("file_browser_actions", actions)
            -- Add to dismissed list so it won't be auto-injected again
            local dismissed = self.settings:readSetting("_dismissed_file_browser_actions") or {}
            table.insert(dismissed, action_id)
            self.settings:saveSetting("_dismissed_file_browser_actions", dismissed)
            self.settings:flush()
            return
        end
    end
end

-- Toggle action inclusion in file browser actions
-- Returns: true if now in file browser, false if removed
function ActionService:toggleFileBrowserAction(action_id)
    if self:isInFileBrowser(action_id) then
        self:removeFromFileBrowser(action_id)
        return false
    else
        self:addToFileBrowser(action_id)
        return true
    end
end

-- Move action in file browser actions order
function ActionService:moveFileBrowserAction(action_id, direction)
    local actions = self:getFileBrowserActions()
    for i, item in ipairs(actions) do
        if item.id == action_id then
            local new_index = direction == "up" and i - 1 or i + 1
            if new_index >= 1 and new_index <= #actions then
                actions[i], actions[new_index] = actions[new_index], actions[i]
                self.settings:saveSetting("file_browser_actions", actions)
                self.settings:flush()
            end
            return
        end
    end
end

-- Get all eligible book actions with their file browser inclusion state
-- Returns array of { action, in_file_browser, file_browser_position }
-- Only includes non-reading actions (eligible for file browser pinning)
function ActionService:getAllBookActionsWithFileBrowserState()
    local Actions = require("prompts.actions")
    local all_actions = self:getAllActions("book", true)  -- include disabled
    local fb_list = self:getFileBrowserActions()

    -- Build position lookup from {id, text} pairs
    local fb_positions = {}
    for i, item in ipairs(fb_list) do
        fb_positions[item.id] = i
    end

    local result = {}
    for _i, action in ipairs(all_actions) do
        -- Only include non-reading actions (eligible for file browser)
        if not Actions.requiresOpenBook(action) then
            table.insert(result, {
                action = action,
                in_file_browser = fb_positions[action.id] ~= nil,
                file_browser_position = fb_positions[action.id],
            })
        end
    end

    -- Sort: file browser items first (by position), then non-FB items (alphabetically)
    table.sort(result, function(a, b)
        if a.in_file_browser and b.in_file_browser then
            return a.file_browser_position < b.file_browser_position
        elseif a.in_file_browser then
            return true
        elseif b.in_file_browser then
            return false
        else
            return (a.action.text or "") < (b.action.text or "")
        end
    end)

    return result
end

-- ============================================================
-- Action Duplication
-- ============================================================

-- Create a duplicate of an action as data for a new custom action
-- Generate a unique name for a duplicate action
-- If "Name Copy" exists, tries "Name Copy (2)", "Name Copy (3)", etc.
function ActionService:generateUniqueDuplicateName(base_name)
    -- Must check ALL contexts since actions can have different contexts
    local all_names = {}
    for _i, context in ipairs(Constants.getAllContexts()) do
        local actions = self:getAllActions(context, true)  -- include_disabled = true
        for _j, action in ipairs(actions) do
            all_names[action.text] = true
        end
    end
    local candidate = base_name .. " Copy"

    -- Check if candidate exists
    local function nameExists(name)
        return all_names[name] == true
    end

    if not nameExists(candidate) then
        return candidate
    end

    -- Try with incrementing numbers
    local counter = 2
    while counter <= 100 do  -- Safety limit
        local numbered = base_name .. " Copy (" .. counter .. ")"
        if not nameExists(numbered) then
            return numbered
        end
        counter = counter + 1
    end

    -- Fallback with timestamp
    return base_name .. " Copy (" .. os.time() .. ")"
end

-- Returns a table suitable for the wizard state (NOT saved yet)
-- @param action: The action to duplicate
-- @return table: Duplicate action data
function ActionService:createDuplicateAction(action)
    local duplicate = {
        text = self:generateUniqueDuplicateName(action.text or "Action"),
        context = action.context or "highlight",
        behavior_variant = action.behavior_variant,
        behavior_override = action.behavior_override,
        extended_thinking = action.extended_thinking,
        thinking_budget = action.thinking_budget,
        reasoning_config = action.reasoning_config,
        provider = action.provider,
        model = action.model,
        include_book_context = action.include_book_context,
        skip_language_instruction = action.skip_language_instruction,
        skip_domain = action.skip_domain,
        -- Context extraction flags (for reading-only actions)
        use_book_text = action.use_book_text,
        use_highlights = action.use_highlights,
        use_annotations = action.use_annotations,
        use_reading_progress = action.use_reading_progress,
        use_reading_stats = action.use_reading_stats,
        use_notebook = action.use_notebook,
        -- View mode flags
        translate_view = action.translate_view,
        compact_view = action.compact_view,
        minimal_buttons = action.minimal_buttons,
        -- NOT copying: id (auto-generated), source (will be "ui"), enabled (default true)
        -- NOT copying: requires_open_book (dynamically inferred from flags above)
    }

    -- Handle prompt: copy directly if exists, or resolve from template
    if action.prompt then
        duplicate.prompt = action.prompt
    elseif action.template then
        -- For builtin actions with templates, resolve the template to prompt text
        local ok, Templates = pcall(require, "prompts/templates")
        if ok and Templates and Templates.get then
            duplicate.prompt = Templates.get(action.template)
        end
    end

    -- Handle temperature: check both top-level (from prompt entries) and api_params (from raw actions)
    if action.temperature then
        duplicate.temperature = action.temperature
    elseif action.api_params and action.api_params.temperature then
        duplicate.temperature = action.api_params.temperature
    end

    -- Handle max_tokens from api_params if present
    if action.api_params and action.api_params.max_tokens then
        duplicate.max_tokens = action.api_params.max_tokens
    end

    return duplicate
end

-- ============================================================
-- Gesture Menu Actions (Default Injection)
-- ============================================================

-- Build default gesture actions from in_gesture_menu flags
-- Scans all contexts for actions with in_gesture_menu = true
-- Returns map of "context:action_id" -> true
local function buildDefaultGestureActions(actions_module)
    local result = {}
    if not actions_module then return result end

    -- Contexts that support gesture menu (book and general only)
    local gesture_contexts = { "book", "general" }

    for _, context in ipairs(gesture_contexts) do
        if actions_module[context] then
            for _id, action in pairs(actions_module[context]) do
                if action.in_gesture_menu then
                    local key = context .. ":" .. action.id
                    result[key] = true
                end
            end
        end
    end

    return result
end

--- Get processed gesture actions map (with defaults injected)
--- This should be called instead of directly reading features.gesture_actions
--- @return table: Map of "context:action_id" -> true
function ActionService:getGestureActions()
    local features = self.settings:readSetting("features") or {}
    local saved = features.gesture_actions

    -- If no saved settings, inject defaults
    if not saved then
        local defaults = buildDefaultGestureActions(self.Actions)
        -- Save defaults to settings
        features.gesture_actions = defaults
        self.settings:saveSetting("features", features)
        self.settings:flush()
        return defaults
    end

    -- Check if we need to inject new defaults (actions added since last save)
    local defaults = buildDefaultGestureActions(self.Actions)
    local changed = false

    for key, _val in pairs(defaults) do
        if saved[key] == nil then
            -- New default action not in saved settings - add it
            saved[key] = true
            changed = true
        end
    end

    if changed then
        features.gesture_actions = saved
        self.settings:saveSetting("features", features)
        self.settings:flush()
    end

    return saved
end

-- ============================================================
-- Display Text with Data Access Indicators
-- ============================================================

-- Get action display text with data access emoji indicators (static method)
-- When enable_data_access_indicators is enabled, appends emoji showing what data the action accesses:
--   📄 = document text (use_book_text, use_xray_cache, use_analyze_cache, use_summary_cache)
--   📝 = annotations (use_annotations; degrades to highlights-only)
--   📓 = notebook (use_notebook)
--   🌐 = web search active (per-action force-on, or follows global when global is on)
-- @param action: Action definition table (needs flag fields)
-- @param features: Features settings table (needs enable_data_access_indicators, enable_web_search)
-- @return string: Display text with optional emoji suffix
function ActionService.getActionDisplayText(action, features)
    local text = action.text or action.id
    if not features or features.enable_data_access_indicators ~= true then
        return text
    end

    local indicators = {}
    -- Document text (direct or via caches derived from document text)
    if action.use_book_text or action.use_xray_cache
       or action.use_analyze_cache or action.use_summary_cache then
        table.insert(indicators, "📄")
    end
    -- Highlights only (no annotations)
    if action.use_highlights and not action.use_annotations then
        table.insert(indicators, "🔖")
    end
    -- Annotations (implies highlights — show single icon)
    if action.use_annotations then
        table.insert(indicators, "📝")
    end
    -- Notebook
    if action.use_notebook then
        table.insert(indicators, "📓")
    end
    -- Web search: show when effectively enabled (per-action override or global setting)
    if action.enable_web_search == true then
        -- Forced on: solid icon
        table.insert(indicators, "🌐")
    elseif action.enable_web_search == nil and features.enable_web_search == true then
        -- Follows global (currently on): parenthesized to distinguish from forced
        table.insert(indicators, "(🌐)")
    end

    if #indicators > 0 then
        text = text .. " " .. table.concat(indicators)
    end
    return text
end

-- ============================================================
-- Input Dialog Per-Context Action Ordering (Generic)
-- ============================================================
-- Parameterized system for 4 input dialog contexts:
-- book, book_filebrowser, highlight, xray_chat
-- Each context has its own ordered list of actions stored in settings.

local INPUT_CONTEXTS = {
    book = {
        settings_key = "input_book_actions",
        dismissed_key = "_dismissed_input_book_actions",
        action_context = "book",
        has_open_book = true,
        -- Curated defaults: conversational actions for asking about a book
        default_ids = {"book_info", "xray_simple", "similar_books", "key_arguments",
            "extract_insights", "discussion_questions", "explain_author", "book_reviews"},
    },
    book_filebrowser = {
        settings_key = "input_book_fb_actions",
        dismissed_key = "_dismissed_input_book_fb_actions",
        action_context = "book",
        has_open_book = false,  -- filters out requiresOpenBook actions
        -- Curated defaults: non-open-book actions suitable for file browser context
        default_ids = {"book_info", "similar_books", "related_thinkers", "explain_author", "historical_context", "book_reviews"},
    },
    highlight = {
        settings_key = "input_highlight_actions",
        dismissed_key = "_dismissed_input_highlight_actions",
        action_context = "highlight",
        has_open_book = true,
        -- Curated defaults: core highlight actions without heavy data requirements
        default_ids = {"translate", "eli5", "explain", "elaborate", "summarize",
            "connect", "fact_check", "explain_in_context_smart"},
    },
    xray_chat = {
        settings_key = "input_xray_chat_actions",
        dismissed_key = "_dismissed_input_xray_chat_actions",
        action_context = "highlight",
        has_open_book = true,
        -- Curated defaults: core actions + context-aware smart actions for X-Ray items
        default_ids = {"explain", "elaborate", "eli5", "fact_check",
            "explain_in_context_smart", "thematic_connection_smart", "connect"},
    },
}

-- Get all eligible action IDs for an input context (respects enabled state and open book filtering)
function ActionService:_getEligibleInputActionIds(ctx_name)
    local ctx = INPUT_CONTEXTS[ctx_name]
    if not ctx then return {} end
    local all = self:getAllActions(ctx.action_context, false, ctx.has_open_book)
    local ids = {}
    for _, action in ipairs(all) do
        if action.id then
            table.insert(ids, action.id)
        end
    end
    return ids
end

-- Build default ordered list for an input context
function ActionService:_buildInputDefaults(ctx_name)
    local ctx = INPUT_CONTEXTS[ctx_name]
    if not ctx then return {} end
    if ctx.default_ids then
        -- Curated defaults: filter to only those that actually exist and are eligible
        local eligible_set = {}
        for _, id in ipairs(self:_getEligibleInputActionIds(ctx_name)) do
            eligible_set[id] = true
        end
        local result = {}
        for _, id in ipairs(ctx.default_ids) do
            if eligible_set[id] then
                table.insert(result, id)
            end
        end
        return result
    else
        -- Default all: return all eligible actions
        return self:_getEligibleInputActionIds(ctx_name)
    end
end

-- Process a saved input action list: prune stale, inject new defaults (respecting dismissals)
function ActionService:_processInputList(ctx_name, saved)
    local ctx = INPUT_CONTEXTS[ctx_name]
    if not ctx then return saved end

    local dismissed = self.settings:readSetting(ctx.dismissed_key) or {}
    local dismissed_set = {}
    for _, id in ipairs(dismissed) do dismissed_set[id] = true end

    -- Build set of all eligible IDs
    local eligible_ids = self:_getEligibleInputActionIds(ctx_name)
    local eligible_set = {}
    for _, id in ipairs(eligible_ids) do eligible_set[id] = true end

    -- Prune stale IDs (actions that no longer exist or aren't eligible)
    local pruned = {}
    for _, id in ipairs(saved) do
        if eligible_set[id] then
            table.insert(pruned, id)
        end
    end

    -- For non-curated contexts: inject new eligible actions not yet in list and not dismissed
    if not ctx.default_ids then
        local current_set = {}
        for _, id in ipairs(pruned) do current_set[id] = true end
        for _, id in ipairs(eligible_ids) do
            if not current_set[id] and not dismissed_set[id] then
                table.insert(pruned, id)
            end
        end
    end

    return pruned
end

-- Get ordered list of action IDs for an input context
function ActionService:getInputActions(ctx_name)
    local ctx = INPUT_CONTEXTS[ctx_name]
    if not ctx then return {} end
    local saved = self.settings:readSetting(ctx.settings_key)
    if not saved then
        return self:_buildInputDefaults(ctx_name)
    end
    local processed = self:_processInputList(ctx_name, saved)
    self.settings:saveSetting(ctx.settings_key, processed)
    return processed
end

-- Get ordered action objects for an input context (resolved, enabled only)
function ActionService:getInputActionObjects(ctx_name)
    local action_ids = self:getInputActions(ctx_name)
    local result = {}
    for _, id in ipairs(action_ids) do
        -- Search across contexts since "both" actions appear in highlight and book
        local action = self:getAction(nil, id)
        if action and action.enabled then
            table.insert(result, action)
        end
    end
    return result
end

-- Check if action is in input context
function ActionService:isInInput(ctx_name, action_id)
    local actions = self:getInputActions(ctx_name)
    for _, id in ipairs(actions) do
        if id == action_id then return true end
    end
    return false
end

-- Add action to input context (appends to end)
function ActionService:addToInput(ctx_name, action_id)
    local ctx = INPUT_CONTEXTS[ctx_name]
    if not ctx then return end
    if self:isInInput(ctx_name, action_id) then return end
    local actions = self:getInputActions(ctx_name)
    table.insert(actions, action_id)
    self.settings:saveSetting(ctx.settings_key, actions)
    -- Remove from dismissed list if present
    local dismissed = self.settings:readSetting(ctx.dismissed_key) or {}
    for i, id in ipairs(dismissed) do
        if id == action_id then
            table.remove(dismissed, i)
            self.settings:saveSetting(ctx.dismissed_key, dismissed)
            break
        end
    end
    self.settings:flush()
end

-- Remove action from input context
function ActionService:removeFromInput(ctx_name, action_id)
    local ctx = INPUT_CONTEXTS[ctx_name]
    if not ctx then return end
    local actions = self:getInputActions(ctx_name)
    for i, id in ipairs(actions) do
        if id == action_id then
            table.remove(actions, i)
            self.settings:saveSetting(ctx.settings_key, actions)
            -- Add to dismissed list so it won't be auto-injected again
            local dismissed = self.settings:readSetting(ctx.dismissed_key) or {}
            table.insert(dismissed, action_id)
            self.settings:saveSetting(ctx.dismissed_key, dismissed)
            self.settings:flush()
            return
        end
    end
end

-- Toggle action in input context
-- Returns: true if now in context, false if removed
function ActionService:toggleInputAction(ctx_name, action_id)
    if self:isInInput(ctx_name, action_id) then
        self:removeFromInput(ctx_name, action_id)
        return false
    else
        self:addToInput(ctx_name, action_id)
        return true
    end
end

-- Move action within input context (reorder)
function ActionService:moveInputAction(ctx_name, action_id, direction)
    local ctx = INPUT_CONTEXTS[ctx_name]
    if not ctx then return end
    local actions = self:getInputActions(ctx_name)
    for i, id in ipairs(actions) do
        if id == action_id then
            local new_index = direction == "up" and i - 1 or i + 1
            if new_index >= 1 and new_index <= #actions then
                actions[i], actions[new_index] = actions[new_index], actions[i]
                self.settings:saveSetting(ctx.settings_key, actions)
                self.settings:flush()
            end
            return
        end
    end
end

-- Get all eligible actions with input membership info (for sorting manager UI)
-- Returns array of { action, in_input, input_position }
function ActionService:getAllActionsWithInputState(ctx_name)
    local ctx = INPUT_CONTEXTS[ctx_name]
    if not ctx then return {} end
    local input_ids = self:getInputActions(ctx_name)

    -- Create position lookup
    local input_positions = {}
    for i, id in ipairs(input_ids) do
        input_positions[id] = i
    end

    local all_actions = self:getAllActions(ctx.action_context, true, ctx.has_open_book)
    local result = {}
    for _, action in ipairs(all_actions) do
        if action.id then
            table.insert(result, {
                action = action,
                in_input = input_positions[action.id] ~= nil,
                input_position = input_positions[action.id],
            })
        end
    end

    -- Sort: input items first (by position), then non-input items (alphabetically)
    table.sort(result, function(a, b)
        if a.in_input and b.in_input then
            return a.input_position < b.input_position
        elseif a.in_input then
            return true
        elseif b.in_input then
            return false
        else
            return (a.action.text or ""):lower() < (b.action.text or ""):lower()
        end
    end)

    return result
end

-- Reset input context to defaults
function ActionService:resetInputActions(ctx_name)
    local ctx = INPUT_CONTEXTS[ctx_name]
    if not ctx then return end
    self.settings:delSetting(ctx.settings_key)
    self.settings:delSetting(ctx.dismissed_key)
    self.settings:flush()
end

-- Get the input context name for an action based on its context type
-- Returns ctx_name or nil if action doesn't belong to any input context
function ActionService.getInputContextForAction(action)
    if not action then return nil end
    local context = action.context
    if context == "book" then
        return "book"
    elseif context == "highlight" or context == "both" then
        return "highlight"
    end
    -- general context actions use the existing general menu system, not input contexts
    return nil
end

return ActionService
