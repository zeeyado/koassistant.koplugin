local _ = require("gettext")
local logger = require("logger")
local T = require("ffi/util").template

local SettingsManager = {}

-- Generate menu items from settings schema (flat items structure)
function SettingsManager:generateMenuFromSchema(plugin, schema)
    local menu_items = {}

    for _, item in ipairs(schema.items) do
        local menu_item = self:createMenuItem(plugin, item, schema)
        if menu_item then
            table.insert(menu_items, menu_item)
        end
    end

    return menu_items
end

-- Create a single menu item based on its schema definition
function SettingsManager:createMenuItem(plugin, item, schema)
    -- Handle special item types
    if item.type == "separator" then
        return { 
            text = "────────────────────",
            enabled = false,
            callback = function() end,  -- Empty callback to prevent any action
        }
    elseif item.type == "header" then
        return { 
            text = item.text,
            enabled = false,
            bold = true,
            callback = function() end,  -- Empty callback to prevent any action
        }
    end
    
    local menu_item = {}

    -- Support for dynamic text labels via text_func
    if item.text_func then
        menu_item.text_func = function()
            return item.text_func(plugin)
        end
    else
        menu_item.text = item.text or item.id
    end

    -- Support for separator line after this item
    if item.separator then
        menu_item.separator = true
    end

    menu_item.enabled_func = function()
        -- First check if the item is explicitly disabled
        if item.enabled == false then
            return false
        end

        -- Then check dependencies
        if item.depends_on then
            if type(item.depends_on) == "table" then
                -- Complex dependency with id and value
                local SettingsSchema = require("settings_schema")
                local dep_path = SettingsSchema:getItemPath(item.depends_on.id)
                local dependency_value = self:getSettingValue(plugin, dep_path)

                -- If dependency value is nil, use the default from schema
                if dependency_value == nil then
                    local dep_item = SettingsSchema:getItemById(item.depends_on.id)
                    if dep_item then
                        dependency_value = dep_item.default
                    end
                end

                return dependency_value == item.depends_on.value
            else
                -- Simple dependency - just check if has value
                local dependency_value = self:getSettingValue(plugin, item.depends_on)
                return dependency_value ~= nil
            end
        end
        return true
    end

    -- Support for help_text
    if item.help_text then
        menu_item.help_text = item.help_text
    end
    
    if item.type == "toggle" then
        menu_item.checked_func = function()
            local value = self:getSettingValue(plugin, item.path or item.id)
            -- If value is nil, use the default from the schema
            if value == nil then
                return item.default == true
            end
            return value == true
        end
        menu_item.callback = function(touchmenu_instance)
            local current = self:getSettingValue(plugin, item.path or item.id)
            -- If value is nil, use the default from the schema
            if current == nil then
                current = item.default == true
            end
            self:setSettingValue(plugin, item.path or item.id, not current)
            plugin:updateConfigFromSettings()
            
            -- If this toggle affects dependencies, refresh the menu
            if item.id == "auto_save_all_chats" then
                if touchmenu_instance then
                    touchmenu_instance:updateItems()
                end
            end
        end
        menu_item.keep_menu_open = true
        
    elseif item.type == "radio" then
        -- Radio buttons need special handling
        -- Support text_func for dynamic labels on the parent item
        if item.text_func then
            menu_item.text_func = function()
                return item.text_func(plugin)
            end
        end
        menu_item.sub_item_table = {}
        for _, option in ipairs(item.options) do
            table.insert(menu_item.sub_item_table, {
                text = option.text,
                radio = true,
                checked_func = function()
                    local value = self:getSettingValue(plugin, item.path or item.id)
                    -- If value is nil, use the default from the schema
                    if value == nil then
                        value = item.default
                    end
                    return value == option.value
                end,
                callback = function()
                    self:setSettingValue(plugin, item.path or item.id, option.value)
                    plugin:updateConfigFromSettings()
                end,
                keep_menu_open = true,
            })
        end
        
    elseif item.type == "number" then
        menu_item.callback = function()
            local InputDialog = require("ui/widget/inputdialog")
            local UIManager = require("ui/uimanager")
            local current_value = self:getSettingValue(plugin, item.path or item.id) or item.default
            
            local dialog
            dialog = InputDialog:new{
                title = item.text,
                description = item.description,
                input = tostring(current_value),
                input_type = "number",
                buttons = {
                    {
                        {
                            text = _("Close"),
                            id = "close",
                            callback = function()
                                UIManager:close(dialog)
                            end,
                        },
                        {
                            text = _("OK"),
                            callback = function()
                                local value = tonumber(dialog:getInputText())
                                local valid, err = schema:validateSetting(item.id, value)
                                if valid then
                                    self:setSettingValue(plugin, item.path or item.id, value)
                                    plugin:updateConfigFromSettings()
                                    UIManager:close(dialog)
                                else
                                    local InfoMessage = require("ui/widget/infomessage")
                                    UIManager:show(InfoMessage:new{
                                        text = err or _("Invalid value"),
                                    })
                                end
                            end,
                        },
                    },
                },
            }
            UIManager:show(dialog)
            dialog:onShowKeyboard()
        end

    elseif item.type == "spinner" then
        -- Spinner widget for numbers (like Temperature, Thinking Budget)
        menu_item.text_func = function()
            local value = self:getSettingValue(plugin, item.path or item.id) or item.default
            local formatted
            if item.precision then
                formatted = string.format(item.precision, value)
            else
                formatted = tostring(value)
            end
            return T(item.text .. ": %1", formatted)
        end
        menu_item.callback = function(touchmenu_instance)
            local SpinWidget = require("ui/widget/spinwidget")
            local UIManager = require("ui/uimanager")
            local current = self:getSettingValue(plugin, item.path or item.id) or item.default
            local spin = SpinWidget:new{
                value = current,
                value_min = item.min or 0,
                value_max = item.max or 100,
                value_step = item.step or 1,
                precision = item.precision,
                ok_text = _("Set"),
                title_text = item.title or item.text,
                info_text = item.info_text or item.description,
                callback = function(spin)
                    self:setSettingValue(plugin, item.path or item.id, spin.value)
                    plugin:updateConfigFromSettings()
                    if touchmenu_instance then
                        touchmenu_instance:updateItems()
                    end
                end,
            }
            UIManager:show(spin)
        end
        menu_item.keep_menu_open = true

    elseif item.type == "text" then
        menu_item.callback = function()
            local InputDialog = require("ui/widget/inputdialog")
            local UIManager = require("ui/uimanager")
            local current_value = self:getSettingValue(plugin, item.path or item.id)
            -- Only use default if current_value is nil or empty string
            if current_value == nil or current_value == "" then
                current_value = item.default or ""
            end
            
            local dialog
            dialog = InputDialog:new{
                title = item.text,
                input = current_value,
                input_hint = item.description,
                buttons = {
                    {
                        {
                            text = _("Close"),
                            id = "close",
                            callback = function()
                                UIManager:close(dialog)
                            end,
                        },
                        {
                            text = _("OK"),
                            is_enter_default = true,
                            callback = function()
                                local value = dialog:getInputText()
                                self:setSettingValue(plugin, item.path or item.id, value)
                                plugin:updateConfigFromSettings()
                                UIManager:close(dialog)
                            end,
                        },
                    },
                },
            }
            UIManager:show(dialog)
            dialog:onShowKeyboard()
        end
        
    elseif item.type == "dynamic_select" then
        -- Dynamic select (like model selection)
        menu_item.sub_item_table_func = function()
            return plugin:getModelMenuItems()
        end
        
    elseif item.type == "action" then
        -- Action button
        if item.confirm then
            menu_item.callback = function()
                local ConfirmBox = require("ui/widget/confirmbox")
                local UIManager = require("ui/uimanager")
                UIManager:show(ConfirmBox:new{
                    text = item.confirm_text or _("Are you sure?"),
                    ok_callback = function()
                        if plugin[item.callback] then
                            plugin[item.callback](plugin)
                        else
                            logger.warn("Settings action callback not found:", item.callback)
                        end
                    end,
                })
            end
        else
            menu_item.callback = function()
                if plugin[item.callback] then
                    plugin[item.callback](plugin)
                else
                    logger.warn("Settings action callback not found:", item.callback)
                end
            end
        end
        
    elseif item.type == "submenu" then
        if item.callback then
            -- Callback-based submenu
            menu_item.sub_item_table_func = function()
                if plugin[item.callback] then
                    return plugin[item.callback](plugin)
                else
                    logger.warn("Submenu callback not found:", item.callback)
                    return {}
                end
            end
        elseif item.dynamic then
            -- Dynamic submenu (like provider config)
            menu_item.sub_item_table_func = function()
                return plugin:getProviderConfigMenuItems()
            end
        elseif item.items then
            -- Static submenu with predefined items
            menu_item.sub_item_table = {}
            for _, subitem in ipairs(item.items) do
                local submenu_item = self:createMenuItem(plugin, subitem, schema)
                if submenu_item then
                    table.insert(menu_item.sub_item_table, submenu_item)
                end
            end
        end
    end
    
    return menu_item
end

-- Get a setting value using dot notation path
function SettingsManager:getSettingValue(plugin, path)
    if not path then return nil end
    
    local parts = {}
    for part in string.gmatch(path, "[^%.]+") do
        table.insert(parts, part)
    end
    
    local value = plugin.settings.data
    for _, part in ipairs(parts) do
        if type(value) == "table" then
            value = value[part]
        else
            return nil
        end
    end
    
    return value
end

-- Set a setting value using dot notation path
function SettingsManager:setSettingValue(plugin, path, value)
    if not path then return end
    
    local parts = {}
    for part in path:gmatch("[^%.]+") do
        table.insert(parts, part)
    end
    
    local current = plugin.settings.data
    for i = 1, #parts - 1 do
        local part = parts[i]
        if type(current[part]) ~= "table" then
            current[part] = {}
        end
        current = current[part]
    end
    
    current[parts[#parts]] = value
    plugin.settings:flush()
end

return SettingsManager