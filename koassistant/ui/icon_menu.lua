--[[--
The menu that hangs from a title bar's icon (a page's ☰).

One way for every page that lists a few rows of its own behind the icon: the
rows under the icon that opened them, as wide as their text, left-aligned, no
title of their own (the page names itself); a tap closes the menu and then
runs the row.

A full page of the plugin covers the reader, and with it KOReader's gestures
(the one that opens Quick Settings among them), so every such page's menu
ends with the way to the settings: one row, Quick Settings, under a double
line (settingsRow; the panel's own More Settings tile leads to the rest).
`show` adds it when handed the plugin; a menu a page still builds by hand
adds it with `withSettings`.

@module koassistant.ui.icon_menu
]]

local ButtonDialog = require("ui/widget/buttondialog")
local UIManager = require("ui/uimanager")
local _ = require("koassistant.core.gettext")

local IconMenu = {}

--- The row every full page's menu ends with: the Quick Settings panel, over
--- the page.
-- @param plugin the plugin's instance (nil = no row)
-- @return table|nil { text, callback }
function IconMenu.settingsRow(plugin)
    if not (plugin and plugin.onKOAssistantAISettings) then return nil end
    return { text = _("Quick Settings"), callback = function() plugin:onKOAssistantAISettings() end }
end

--- A hand-built page menu's rows (a ButtonDialog's `buttons`) with the
--- settings row added under a double line.
-- @param buttons the dialog's rows, written to and returned
-- @param plugin the plugin's instance (nil = nothing added)
-- @param close function that closes the menu, run before the panel opens
function IconMenu.withSettings(buttons, plugin, close)
    local row = IconMenu.settingsRow(plugin)
    if not row then return buttons end
    buttons[#buttons + 1] = {}
    buttons[#buttons + 1] = {{
        text = row.text,
        align = "left",
        callback = function()
            if close then close() end
            row.callback()
        end,
    }}
    return buttons
end

--- Show the rows under the page's left title-bar icon.
--- @param menu table the page: a Menu whose title bar has a left icon
--- @param rows table { { text, callback, enabled }, ... }
--- @param plugin the plugin's instance: the settings row is added last (nil = the rows alone)
--- @return table the dialog, shown
function IconMenu.show(menu, rows, plugin)
    local dialog
    local buttons = {}
    for _idx, row in ipairs(rows) do
        local run = row.callback
        buttons[#buttons + 1] = {{
            text = row.text,
            enabled = row.enabled,
            align = "left",
            callback = function()
                UIManager:close(dialog)
                run()
            end,
        }}
    end
    IconMenu.withSettings(buttons, plugin, function() UIManager:close(dialog) end)
    dialog = ButtonDialog:new{
        buttons = buttons,
        shrink_unneeded_width = true,
        anchor = function()
            return menu.title_bar.left_button.image.dimen, true
        end,
    }
    UIManager:show(dialog)
    return dialog
end

return IconMenu
