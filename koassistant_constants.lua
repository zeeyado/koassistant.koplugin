--[[
Core Constants for KOAssistant Plugin

Centralized definitions for values used across multiple modules.
Prevents drift when adding features or changing configuration.

Pattern follows: koassistant_ui/constants.lua (UI sizing constants)

Usage:
    local Constants = require("koassistant_constants")
    for _, ctx in ipairs(Constants.getAllContexts()) do
        -- Process each context
    end
]]

local Constants = {}

-- Context types (used in actions, message building, dialogs)
-- These are the four standard contexts for AI interactions
Constants.CONTEXTS = {
    HIGHLIGHT = "highlight",      -- Selected text context
    BOOK = "book",                -- Single book metadata
    MULTI_BOOK = "multi_book",    -- Multiple books
    GENERAL = "general",          -- Standalone questions
}

-- Compound contexts (shorthand for multiple contexts)
-- These are convenience values that expand to multiple standard contexts
Constants.COMPOUND_CONTEXTS = {
    BOTH = "both",                -- highlight + book
    ALL = "all",                  -- All four contexts
}

--- Get ordered list of all standard contexts
--- Returns contexts in display order (not alphabetical)
--- @return table: Array of context names ["highlight", "book", "multi_book", "general"]
function Constants.getAllContexts()
    return {
        Constants.CONTEXTS.HIGHLIGHT,
        Constants.CONTEXTS.BOOK,
        Constants.CONTEXTS.MULTI_BOOK,
        Constants.CONTEXTS.GENERAL,
    }
end

--- Expand compound context to individual contexts
--- Handles special compound values like "all" and "both"
--- @param context string: Context name (can be compound like "all", "both", or standard)
--- @return table: Array of individual context names
function Constants.expandContext(context)
    if context == Constants.COMPOUND_CONTEXTS.ALL then
        return Constants.getAllContexts()
    elseif context == Constants.COMPOUND_CONTEXTS.BOTH then
        return {
            Constants.CONTEXTS.HIGHLIGHT,
            Constants.CONTEXTS.BOOK,
        }
    else
        -- Return as single-item array for standard contexts
        return { context }
    end
end

--- Check if a context name is valid
--- Validates against both standard and compound contexts
--- @param context string: Context name to validate
--- @return boolean: true if valid context (standard or compound)
function Constants.isValidContext(context)
    -- Check standard contexts
    for _, ctx in ipairs(Constants.getAllContexts()) do
        if context == ctx then return true end
    end

    -- Check compound contexts
    if context == Constants.COMPOUND_CONTEXTS.BOTH or
       context == Constants.COMPOUND_CONTEXTS.ALL then
        return true
    end

    return false
end

-- GitHub repository URLs
-- Used for update checking and HTTP headers (OpenRouter)
-- Single source of truth for repository location
Constants.GITHUB = {
    REPO_OWNER = "zeeyado",
    REPO_NAME = "koassistant.koplugin",
    URL = "https://github.com/zeeyado/koassistant.koplugin",
    API_URL = "https://api.github.com/repos/zeeyado/koassistant.koplugin/releases",
}

-- Quick Actions Panel Utilities
-- Non-action items shown in the Quick Actions panel (below the actions)
-- Each utility has: id (settings key suffix), callback (method name), default (enabled by default)
-- Display text is handled by consumers using gettext
-- Settings path: features.qa_show_{id}
Constants.QUICK_ACTION_UTILITIES = {
    { id = "translate_page",     callback = "onKOAssistantTranslatePage",       default = true },
    { id = "view_notebook",      callback = "onKOAssistantViewNotebook",        default = true },
    { id = "edit_notebook",      callback = "onKOAssistantEditNotebook",        default = true },
    { id = "chat_history",       callback = "onKOAssistantChatHistory",         default = true },
    { id = "continue_last_chat", callback = "onKOAssistantContinueLastOpened",  default = true },
    { id = "new_book_chat",      callback = "onKOAssistantBookChat",            default = true },
    { id = "general_chat",       callback = "startGeneralChat",                 default = true },
    { id = "summary",            callback = "handleSummary",                    default = true },  -- Special handling
    { id = "view_caches",        callback = "handleViewCaches",                 default = true },  -- "View Artifacts": only visible if X-Ray or Analysis exists
    { id = "ai_quick_settings",  callback = "onKOAssistantAISettings",          default = true },
}

--- Get display text for a Quick Action utility
--- Must be called from a context where _ (gettext) is available
--- @param id string: Utility ID
--- @param _ function: gettext function
--- @return string: Translated display text
function Constants.getQuickActionUtilityText(id, _)
    local texts = {
        translate_page = _("Translate Page"),
        view_notebook = _("View Notebook"),
        edit_notebook = _("Edit Notebook"),
        chat_history = _("Chat History"),
        continue_last_chat = _("Continue Last Chat"),
        new_book_chat = _("New Book Chat/Action"),
        general_chat = _("General Chat/Action"),
        summary = nil,  -- Special: dynamic text based on cache state
        view_caches = _("View Artifacts"),
        ai_quick_settings = _("Quick Settings"),
    }
    return texts[id]
end

--- Get text with optional emoji prefix
--- Returns emoji version if enable_emoji_icons is true, otherwise text-only version
--- @param emoji string: The emoji to show when enabled (e.g., "🔍")
--- @param text string: The text to show (e.g., "Web ON")
--- @param enable_emoji boolean: Whether emoji icons are enabled
--- @return string: Either "🔍 Web ON" or "Web ON" depending on setting
function Constants.getEmojiText(emoji, text, enable_emoji)
    if enable_emoji then
        return emoji .. " " .. text
    end
    return text
end

return Constants
