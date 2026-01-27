local _ = require("koassistant_gettext")
local T = require("ffi/util").template
local logger = require("logger")
local UIManager = require("ui/uimanager")
local Menu = require("ui/widget/menu")
local InfoMessage = require("ui/widget/infomessage")
local ConfirmBox = require("ui/widget/confirmbox")
local InputDialog = require("ui/widget/inputdialog")
local ButtonDialog = require("ui/widget/buttondialog")
local TextViewer = require("ui/widget/textviewer")
local UIConstants = require("koassistant_ui.constants")
local SystemPrompts = require("prompts/system_prompts")

local BehaviorManager = {}

function BehaviorManager:new(plugin)
    local o = {
        plugin = plugin,
        width = UIConstants.DIALOG_WIDTH(),
        height = UIConstants.DIALOG_HEIGHT(),
    }
    setmetatable(o, self)
    self.__index = self
    return o
end

-- Get the currently selected behavior ID
function BehaviorManager:getSelectedBehavior()
    local features = self.plugin.settings:readSetting("features") or {}
    return features.selected_behavior or "standard"
end

-- Set the selected behavior ID
function BehaviorManager:setSelectedBehavior(behavior_id)
    local features = self.plugin.settings:readSetting("features") or {}
    features.selected_behavior = behavior_id
    self.plugin.settings:saveSetting("features", features)
    self.plugin.settings:flush()
end

-- Get custom behaviors array from settings
function BehaviorManager:getCustomBehaviors()
    local features = self.plugin.settings:readSetting("features") or {}
    return features.custom_behaviors or {}
end

-- Save custom behaviors array to settings
function BehaviorManager:saveCustomBehaviors(custom_behaviors)
    local features = self.plugin.settings:readSetting("features") or {}
    features.custom_behaviors = custom_behaviors
    self.plugin.settings:saveSetting("features", features)
    self.plugin.settings:flush()
end

-- Generate a unique ID for a new custom behavior
function BehaviorManager:generateBehaviorId()
    local custom = self:getCustomBehaviors()
    local max_num = 0
    for _idx, b in ipairs(custom) do
        local num = tonumber(b.id:match("custom_(%d+)"))
        if num and num > max_num then
            max_num = num
        end
    end
    return "custom_" .. (max_num + 1)
end

-- Add a new custom behavior
function BehaviorManager:addCustomBehavior(name, text)
    local custom = self:getCustomBehaviors()
    local id = self:generateBehaviorId()
    table.insert(custom, {
        id = id,
        name = name,
        text = text,
    })
    self:saveCustomBehaviors(custom)
    return id
end

-- Update an existing custom behavior
function BehaviorManager:updateCustomBehavior(id, name, text)
    local custom = self:getCustomBehaviors()
    for i, b in ipairs(custom) do
        if b.id == id then
            custom[i].name = name
            custom[i].text = text
            self:saveCustomBehaviors(custom)
            return true
        end
    end
    return false
end

-- Delete a custom behavior
function BehaviorManager:deleteCustomBehavior(id)
    local custom = self:getCustomBehaviors()
    for i, b in ipairs(custom) do
        if b.id == id then
            table.remove(custom, i)
            self:saveCustomBehaviors(custom)
            -- If deleted behavior was selected, switch to default
            if self:getSelectedBehavior() == id then
                self:setSelectedBehavior("standard")
            end
            return true
        end
    end
    return false
end

function BehaviorManager:show()
    self:showBehaviorMenu()
end

function BehaviorManager:showBehaviorMenu()
    local menu_items = {}
    local selected_id = self:getSelectedBehavior()
    local custom_behaviors = self:getCustomBehaviors()

    -- Add help text at the top
    table.insert(menu_items, {
        text = _("Tap to select • Hold for details"),
        dim = true,
        enabled = false,
    })

    -- Add "Create New" button
    table.insert(menu_items, {
        text = _("+ Create New Behavior"),
        callback = function()
            self:showBehaviorEditor(nil)
        end,
    })

    -- Get all behaviors sorted
    local all_behaviors = SystemPrompts.getSortedBehaviors(custom_behaviors)

    -- Group by source: built-in first, then folder, then UI
    local current_source = nil

    for _idx, behavior in ipairs(all_behaviors) do
        -- Add section header when source changes
        if behavior.source ~= current_source then
            current_source = behavior.source
            local header_text
            if current_source == "builtin" then
                header_text = _("BUILT-IN")
            elseif current_source == "folder" then
                header_text = _("FROM BEHAVIORS/ FOLDER")
            elseif current_source == "ui" then
                header_text = _("CUSTOM (UI-CREATED)")
            end
            if header_text then
                table.insert(menu_items, {
                    text = "▶ " .. header_text,
                    enabled = false,
                    dim = false,
                    bold = true,
                })
            end
        end

        -- Build item text
        local is_selected = (behavior.id == selected_id)
        local radio = is_selected and "●" or "○"
        local item_text = radio .. "  " .. behavior.display_name

        table.insert(menu_items, {
            text = item_text,
            behavior = behavior,
            callback = function()
                self:setSelectedBehavior(behavior.id)
                self:refreshMenu()
                UIManager:show(InfoMessage:new{
                    text = T(_("Selected: %1"), behavior.display_name),
                    timeout = 1,
                })
            end,
            hold_callback = function()
                self:showBehaviorDetails(behavior)
            end,
        })
    end

    -- Create footer buttons
    local buttons = {
        {
            {
                text = _("Restore Defaults"),
                callback = function()
                    UIManager:show(ConfirmBox:new{
                        text = _("This will delete all custom behaviors and reset selection to Standard. Continue?"),
                        ok_callback = function()
                            self:saveCustomBehaviors({})
                            self:setSelectedBehavior("standard")
                            self:refreshMenu()
                        end,
                    })
                end,
            },
        },
    }

    self.behavior_menu = Menu:new{
        title = _("Manage Behaviors"),
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
            UIManager:close(self.behavior_menu)
        end,
        buttons_table = buttons,
    }

    UIManager:show(self.behavior_menu)
end

function BehaviorManager:refreshMenu()
    if self.behavior_menu then
        local current_page = self.behavior_menu.page
        UIManager:close(self.behavior_menu)
        UIManager:scheduleIn(0.1, function()
            self:show()
            if self.behavior_menu and current_page and current_page > 1 then
                self.behavior_menu:onGotoPage(current_page)
            end
        end)
    end
end

function BehaviorManager:showBehaviorDetails(behavior)
    local source_text
    if behavior.source == "builtin" then
        source_text = _("Built-in")
    elseif behavior.source == "folder" then
        source_text = _("File (behaviors/ folder)")
    elseif behavior.source == "ui" then
        source_text = _("Custom (UI-created)")
    else
        source_text = behavior.source or _("Unknown")
    end

    -- Calculate approximate token count (rough estimate: 4 chars per token)
    local token_estimate = math.ceil(#behavior.text / 4)

    -- Build info text
    local info_parts = {
        behavior.display_name,
        "",
        _("Source") .. ": " .. source_text,
    }

    -- Add metadata if available (from file-based behaviors)
    local metadata = behavior.metadata
    if metadata then
        if metadata.source then
            table.insert(info_parts, _("Based on") .. ": " .. metadata.source)
        end
        if metadata.date then
            table.insert(info_parts, _("Date") .. ": " .. metadata.date)
        end
        if metadata.notes then
            table.insert(info_parts, _("Notes") .. ": " .. metadata.notes)
        end
    end

    table.insert(info_parts, _("Size") .. ": ~" .. token_estimate .. " tokens")
    table.insert(info_parts, "")
    table.insert(info_parts, _("Content") .. ":")
    table.insert(info_parts, behavior.text)

    local info_text = table.concat(info_parts, "\n")

    local buttons = {}

    if behavior.source == "ui" then
        -- UI-created: Edit, Delete, Duplicate
        table.insert(buttons, {
            {
                text = _("Edit"),
                callback = function()
                    UIManager:close(self.details_dialog)
                    self:showBehaviorEditor(behavior)
                end,
            },
            {
                text = _("Delete"),
                callback = function()
                    UIManager:close(self.details_dialog)
                    UIManager:show(ConfirmBox:new{
                        text = T(_("Delete '%1'?"), behavior.name),
                        ok_callback = function()
                            self:deleteCustomBehavior(behavior.id)
                            self:refreshMenu()
                        end,
                    })
                end,
            },
        })
        table.insert(buttons, {
            {
                text = _("Duplicate"),
                callback = function()
                    UIManager:close(self.details_dialog)
                    local new_id = self:addCustomBehavior(
                        behavior.name .. " (copy)",
                        behavior.text
                    )
                    self:refreshMenu()
                    UIManager:show(InfoMessage:new{
                        text = _("Behavior duplicated"),
                        timeout = 1,
                    })
                end,
            },
        })
    elseif behavior.source == "folder" then
        -- Folder: View only, show file path info
        table.insert(buttons, {
            {
                text = _("About File-Based Behaviors"),
                callback = function()
                    local BehaviorLoader = require("behavior_loader")
                    UIManager:show(InfoMessage:new{
                        text = string.format(
                            _("This behavior is loaded from a file in:\n\n%s\n\nTo edit, modify the file directly."),
                            BehaviorLoader.getFolderPath()
                        ),
                    })
                end,
            },
        })
        table.insert(buttons, {
            {
                text = _("Use as Template"),
                callback = function()
                    UIManager:close(self.details_dialog)
                    self:showBehaviorEditor(nil, behavior.text, behavior.name .. " (copy)")
                end,
            },
        })
    elseif behavior.source == "builtin" then
        -- Built-in: View only, can use as template
        table.insert(buttons, {
            {
                text = _("Use as Template"),
                callback = function()
                    UIManager:close(self.details_dialog)
                    self:showBehaviorEditor(nil, behavior.text, behavior.name .. " (custom)")
                end,
            },
        })
    end

    -- Add Close button
    table.insert(buttons, {
        {
            text = _("Close"),
            callback = function()
                UIManager:close(self.details_dialog)
            end,
        },
    })

    self.details_dialog = TextViewer:new{
        title = _("Behavior Details"),
        text = info_text,
        width = self.width,
        height = self.height,
        buttons_table = buttons,
    }

    UIManager:show(self.details_dialog)
end

-- Show behavior editor dialog
-- @param behavior: Existing behavior to edit (nil for new)
-- @param template_text: Optional text to pre-fill (for "Use as Template")
-- @param template_name: Optional name to pre-fill
function BehaviorManager:showBehaviorEditor(behavior, template_text, template_name)
    local is_new = (behavior == nil)
    local initial_name = behavior and behavior.name or template_name or ""
    local initial_text = behavior and behavior.text or template_text or ""

    -- Step 1: Name input
    local name_dialog
    name_dialog = InputDialog:new{
        title = is_new and _("New Behavior - Name") or _("Edit Behavior - Name"),
        input = initial_name,
        input_hint = _("Enter behavior name..."),
        description = _("Give this behavior a descriptive name."),
        buttons = {
            {
                {
                    text = _("Cancel"),
                    id = "close",
                    callback = function()
                        UIManager:close(name_dialog)
                        self:refreshMenu()
                    end,
                },
                {
                    text = _("Use Template..."),
                    callback = function()
                        local current_name = name_dialog:getInputText()
                        UIManager:close(name_dialog)
                        self:showTemplateSelector(function(selected_text, selected_name)
                            -- Reopen editor with template
                            local use_name = current_name ~= "" and current_name or (selected_name and selected_name .. " (custom)")
                            self:showBehaviorEditor(behavior, selected_text, use_name)
                        end)
                    end,
                },
                {
                    text = _("Next"),
                    is_enter_default = true,
                    callback = function()
                        local name = name_dialog:getInputText()
                        if name == "" then
                            UIManager:show(InfoMessage:new{
                                text = _("Please enter a name"),
                                timeout = 2,
                            })
                            return
                        end
                        UIManager:close(name_dialog)
                        -- Step 2: Text editor
                        self:showBehaviorTextEditor(behavior, name, initial_text)
                    end,
                },
            },
        },
    }

    UIManager:show(name_dialog)
end

-- Step 2: Full-screen text editor for behavior content
function BehaviorManager:showBehaviorTextEditor(behavior, name, initial_text)
    local is_new = (behavior == nil)

    local text_dialog
    text_dialog = InputDialog:new{
        title = is_new and _("New Behavior - Content") or _("Edit Behavior - Content"),
        input = initial_text,
        input_hint = _("Enter behavior instructions for the AI..."),
        description = T(_("Name: %1\n\nDefine how the AI should behave. This text is sent as part of the system prompt."), name),
        input_type = "text",
        allow_newline = true,
        fullscreen = true,
        buttons = {
            {
                {
                    text = _("Cancel"),
                    id = "close",
                    callback = function()
                        UIManager:close(text_dialog)
                        self:refreshMenu()
                    end,
                },
                {
                    text = _("Load Built-in..."),
                    callback = function()
                        self:showBuiltinTemplateSelector(function(selected_text)
                            if selected_text then
                                text_dialog:setInputText(selected_text)
                            end
                        end)
                    end,
                },
                {
                    text = _("Save"),
                    is_enter_default = true,
                    callback = function()
                        local text = text_dialog:getInputText()
                        if text == "" then
                            UIManager:show(InfoMessage:new{
                                text = _("Please enter behavior content"),
                                timeout = 2,
                            })
                            return
                        end

                        UIManager:close(text_dialog)

                        if is_new then
                            local new_id = self:addCustomBehavior(name, text)
                            UIManager:show(InfoMessage:new{
                                text = T(_("Created: %1"), name),
                                timeout = 1,
                            })
                        else
                            self:updateCustomBehavior(behavior.id, name, text)
                            UIManager:show(InfoMessage:new{
                                text = T(_("Updated: %1"), name),
                                timeout = 1,
                            })
                        end

                        self:refreshMenu()
                    end,
                },
            },
        },
    }

    UIManager:show(text_dialog)
end

-- Show built-in template selector (only built-in behaviors)
function BehaviorManager:showBuiltinTemplateSelector(callback)
    local all_behaviors = SystemPrompts.getSortedBehaviors(nil)
    local buttons = {}

    for _idx, behavior in ipairs(all_behaviors) do
        if behavior.source == "builtin" then
            local tokens = behavior.text and math.floor(#behavior.text / 4) or 0
            table.insert(buttons, {
                {
                    text = string.format("%s (~%d tokens)", behavior.name, tokens),
                    callback = function()
                        UIManager:close(self.builtin_template_dialog)
                        callback(behavior.text)
                    end,
                },
            })
        end
    end

    -- Add cancel button
    table.insert(buttons, {
        {
            text = _("Cancel"),
            callback = function()
                UIManager:close(self.builtin_template_dialog)
            end,
        },
    })

    self.builtin_template_dialog = ButtonDialog:new{
        title = _("Load Built-in Behavior"),
        buttons = buttons,
    }

    UIManager:show(self.builtin_template_dialog)
end

-- Show template selector dialog
function BehaviorManager:showTemplateSelector(callback)
    local custom_behaviors = self:getCustomBehaviors()
    local all_behaviors = SystemPrompts.getSortedBehaviors(custom_behaviors)

    local buttons = {}

    -- "Start blank" option
    table.insert(buttons, {
        {
            text = _("Start Blank"),
            callback = function()
                UIManager:close(self.template_dialog)
                callback("", nil)
            end,
        },
    })

    -- Add all behaviors as template options
    for _idx, behavior in ipairs(all_behaviors) do
        local source_indicator = ""
        if behavior.source == "folder" then
            source_indicator = " (file)"
        elseif behavior.source == "ui" then
            source_indicator = " (custom)"
        end

        table.insert(buttons, {
            {
                text = behavior.name .. source_indicator,
                callback = function()
                    UIManager:close(self.template_dialog)
                    callback(behavior.text, behavior.name)
                end,
            },
        })
    end

    -- Add cancel button
    table.insert(buttons, {
        {
            text = _("Cancel"),
            callback = function()
                UIManager:close(self.template_dialog)
            end,
        },
    })

    self.template_dialog = ButtonDialog:new{
        title = _("Use as Template"),
        buttons = buttons,
    }

    UIManager:show(self.template_dialog)
end

return BehaviorManager
