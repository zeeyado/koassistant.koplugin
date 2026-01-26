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

local UIConstants = {}

-- Standard dialog sizing (full screen)
-- Used for: Chat History, Domain/Tag browsers, Prompts Manager
function UIConstants.DIALOG_WIDTH()
    return Screen:getWidth()
end

function UIConstants.DIALOG_HEIGHT()
    return Screen:getHeight()
end

-- Chat viewer sizing (95% - slightly smaller than full screen)
-- Used for: ChatGPTViewer, streaming dialog (large mode)
function UIConstants.CHAT_WIDTH()
    return math.floor(Screen:getWidth() * 0.95)
end

function UIConstants.CHAT_HEIGHT()
    return math.floor(Screen:getHeight() * 0.95)
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
    local Size = require("ui/size")
    return Size.padding.large
end

function UIConstants.TEXT_MARGIN()
    local Size = require("ui/size")
    return Size.margin.small
end

-- Calculate content width (dialog width minus padding/margins)
function UIConstants.CONTENT_WIDTH()
    local Size = require("ui/size")
    return UIConstants.DIALOG_WIDTH() - 2 * Size.padding.large - 2 * Size.margin.small
end

return UIConstants
