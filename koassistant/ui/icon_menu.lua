--[[--
The menu that hangs from a title bar's icon (a page's ☰).

One way for every page that lists a few rows of its own behind the icon: the
rows under the icon that opened them, as wide as their text, left-aligned, no
title of their own (the page names itself); a tap closes the menu and then
runs the row.

@module koassistant.ui.icon_menu
]]

local ButtonDialog = require("ui/widget/buttondialog")
local UIManager = require("ui/uimanager")

local IconMenu = {}

--- Show the rows under the page's left title-bar icon.
--- @param menu table the page: a Menu whose title bar has a left icon
--- @param rows table { { text, callback, enabled }, ... }
--- @return table the dialog, shown
function IconMenu.show(menu, rows)
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
