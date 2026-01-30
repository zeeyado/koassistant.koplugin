--[[
UI Constants for KOAssistant Plugin

Shared sizing and styling constants to ensure consistent appearance
across all dialogs, menus, and widgets.

Usage:
    local UIConstants = require("koassistant_ui.constants")
    local width = UIConstants.DIALOG_WIDTH()
    local height = UIConstants.DIALOG_HEIGHT()
]]

local Device = require("device")
local Screen = Device.screen
local Size = require("ui/size")

local UIConstants = {}

-- Standard dialog sizing (full screen)
-- Used for: Chat History, Domain/Tag browsers, Prompts Manager
function UIConstants.DIALOG_WIDTH()
    return Screen:getWidth()
end

function UIConstants.DIALOG_HEIGHT()
    return Screen:getHeight()
end

-- Full viewer sizing (Wikipedia-style: near-100% with tiny margin)
-- Used for: ChatGPTViewer (standard), streaming dialog (large mode)
-- Matches KOReader's DictQuickLookup full-page Wikipedia viewer
function UIConstants.FULL_VIEWER_WIDTH()
    return Screen:getWidth() - 2 * Size.margin.default
end

function UIConstants.FULL_VIEWER_HEIGHT()
    return Screen:getHeight() - 2 * Size.margin.default
end

-- Chat viewer sizing (95% - slightly smaller than full screen)
-- DEPRECATED: Use FULL_VIEWER_WIDTH/HEIGHT instead
-- Kept for backward compatibility
function UIConstants.CHAT_WIDTH()
    return UIConstants.FULL_VIEWER_WIDTH()
end

function UIConstants.CHAT_HEIGHT()
    return UIConstants.FULL_VIEWER_HEIGHT()
end

-- Compact dialog sizing (90% width, 60% height)
-- Used for: Smaller dialogs, confirmations
function UIConstants.COMPACT_DIALOG_WIDTH()
    return math.floor(Screen:getWidth() * 0.9)
end

function UIConstants.COMPACT_DIALOG_HEIGHT()
    return math.floor(Screen:getHeight() * 0.6)
end

-- Standard window margin (padding from screen edge)
function UIConstants.WINDOW_MARGIN()
    return Screen:scaleBySize(30)
end

-- Input dialog height ratio (for reply dialogs, etc.)
UIConstants.INPUT_HEIGHT_RATIO = 0.3

-- Menu item threshold for single vs double column layout
UIConstants.MAX_SINGLE_COLUMN = 12

-- Standard text padding and margins
function UIConstants.TEXT_PADDING()
    return Size.padding.large
end

function UIConstants.TEXT_MARGIN()
    return Size.margin.small
end

-- Calculate content width (dialog width minus padding/margins)
function UIConstants.CONTENT_WIDTH()
    return UIConstants.DIALOG_WIDTH() - 2 * Size.padding.large - 2 * Size.margin.small
end

-- Get margin used for Wikipedia-style viewers
function UIConstants.VIEWER_MARGIN()
    return Size.margin.default
end

return UIConstants
