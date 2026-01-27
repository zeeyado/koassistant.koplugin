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

return Constants
