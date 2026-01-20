local _ = require("koassistant_gettext")
local logger = require("logger")
local UIManager = require("ui/uimanager")
local Menu = require("ui/widget/menu")
local InfoMessage = require("ui/widget/infomessage")
local ConfirmBox = require("ui/widget/confirmbox")
local InputDialog = require("ui/widget/inputdialog")
local ButtonDialog = require("ui/widget/buttondialog")
local TextViewer = require("ui/widget/textviewer")
local UIConstants = require("ui/constants")
local DomainLoader = require("domain_loader")

local DomainManager = {}

function DomainManager:new(plugin)
    local o = {
        plugin = plugin,
        width = UIConstants.DIALOG_WIDTH(),
        height = UIConstants.DIALOG_HEIGHT(),
    }
    setmetatable(o, self)
    self.__index = self
    return o
end

-- Get custom domains array from settings
function DomainManager:getCustomDomains()
    local features = self.plugin.settings:readSetting("features") or {}
    return features.custom_domains or {}
end

-- Save custom domains array to settings
function DomainManager:saveCustomDomains(custom_domains)
    local features = self.plugin.settings:readSetting("features") or {}
    features.custom_domains = custom_domains
    self.plugin.settings:saveSetting("features", features)
    self.plugin.settings:flush()
end

-- Generate a unique ID for a new custom domain
function DomainManager:generateDomainId()
    local custom = self:getCustomDomains()
    local max_num = 0
    for _idx, d in ipairs(custom) do
        local num = tonumber(d.id:match("custom_(%d+)"))
        if num and num > max_num then
            max_num = num
        end
    end
    return "custom_" .. (max_num + 1)
end

-- Add a new custom domain
function DomainManager:addCustomDomain(name, context)
    local custom = self:getCustomDomains()
    local id = self:generateDomainId()
    table.insert(custom, {
        id = id,
        name = name,
        context = context,
    })
    self:saveCustomDomains(custom)
    return id
end

-- Update an existing custom domain
function DomainManager:updateCustomDomain(id, name, context)
    local custom = self:getCustomDomains()
    for i, d in ipairs(custom) do
        if d.id == id then
            custom[i].name = name
            custom[i].context = context
            self:saveCustomDomains(custom)
            return true
        end
    end
    return false
end

-- Delete a custom domain
function DomainManager:deleteCustomDomain(id)
    local custom = self:getCustomDomains()
    for i, d in ipairs(custom) do
        if d.id == id then
            table.remove(custom, i)
            self:saveCustomDomains(custom)
            -- If deleted domain was selected, clear selection
            local features = self.plugin.settings:readSetting("features") or {}
            if features.selected_domain == id then
                features.selected_domain = nil
                self.plugin.settings:saveSetting("features", features)
                self.plugin.settings:flush()
            end
            return true
        end
    end
    return false
end

function DomainManager:show()
    self:showDomainMenu()
end

function DomainManager:showDomainMenu()
    local menu_items = {}
    local custom_domains = self:getCustomDomains()

    -- Add help text at the top
    table.insert(menu_items, {
        text = _("Hold for details • Domains are selected when starting a chat"),
        dim = true,
        enabled = false,
    })

    -- Add "Create New" button
    table.insert(menu_items, {
        text = _("+ Create New Domain"),
        callback = function()
            self:showDomainEditor(nil)
        end,
    })

    -- Get all domains sorted
    local all_domains = DomainLoader.getSortedDomains(custom_domains)

    if #all_domains == 0 then
        table.insert(menu_items, {
            text = _("No domains available"),
            dim = true,
            enabled = false,
        })
        table.insert(menu_items, {
            text = _("Create custom domains here or add .md/.txt files to the domains/ folder"),
            dim = true,
            enabled = false,
        })
    else
        -- Group by source: folder first, then UI
        local current_source = nil

        for _idx, domain in ipairs(all_domains) do
            -- Add section header when source changes
            if domain.source ~= current_source then
                current_source = domain.source
                local header_text
                if current_source == "folder" then
                    header_text = _("FROM DOMAINS/ FOLDER")
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

            -- Build item text with preview
            local preview = domain.context:sub(1, 50):gsub("\n", " ")
            if #domain.context > 50 then
                preview = preview .. "..."
            end

            local item_text = domain.display_name

            table.insert(menu_items, {
                text = item_text,
                domain = domain,
                -- No tap callback - domains are selected per-chat
                callback = function()
                    -- Show hint about how domains work
                    UIManager:show(InfoMessage:new{
                        text = _("Domains are selected when starting a chat.\n\nHold to view details or edit."),
                        timeout = 2,
                    })
                end,
                hold_callback = function()
                    self:showDomainDetails(domain)
                end,
            })
        end
    end

    -- Create footer buttons
    local buttons = {
        {
            {
                text = _("About Domains"),
                callback = function()
                    UIManager:show(InfoMessage:new{
                        text = _("Domains provide specialized knowledge context to the AI.\n\nUnlike behaviors (which set communication style), domains give the AI expertise in specific subject areas.\n\nDomains are selected per-chat, not globally, making them like 'projects' you can switch between."),
                    })
                end,
            },
            {
                text = _("Delete All Custom"),
                callback = function()
                    local custom = self:getCustomDomains()
                    if #custom == 0 then
                        UIManager:show(InfoMessage:new{
                            text = _("No custom domains to delete"),
                            timeout = 1,
                        })
                        return
                    end
                    UIManager:show(ConfirmBox:new{
                        text = string.format(_("Delete all %d custom domains?"), #custom),
                        ok_callback = function()
                            self:saveCustomDomains({})
                            self:refreshMenu()
                        end,
                    })
                end,
            },
        },
    }

    self.domain_menu = Menu:new{
        title = _("Manage Domains"),
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
            UIManager:close(self.domain_menu)
        end,
        buttons_table = buttons,
    }

    UIManager:show(self.domain_menu)
end

function DomainManager:refreshMenu()
    if self.domain_menu then
        local current_page = self.domain_menu.page
        UIManager:close(self.domain_menu)
        UIManager:scheduleIn(0.1, function()
            self:show()
            if self.domain_menu and current_page and current_page > 1 then
                self.domain_menu:onGotoPage(current_page)
            end
        end)
    end
end

function DomainManager:showDomainDetails(domain)
    local source_text
    if domain.source == "folder" then
        source_text = _("File (domains/ folder)")
    elseif domain.source == "ui" then
        source_text = _("Custom (UI-created)")
    else
        source_text = domain.source or _("Unknown")
    end

    -- Calculate approximate token count
    local token_estimate = math.ceil(#domain.context / 4)

    local info_text = string.format(
        "%s\n\n%s: %s\n%s: ~%d tokens\n\n%s:\n%s",
        domain.display_name,
        _("Source"), source_text,
        _("Size"), token_estimate,
        _("Content"),
        domain.context
    )

    local buttons = {}

    if domain.source == "ui" then
        -- UI-created: Edit, Delete, Duplicate
        table.insert(buttons, {
            {
                text = _("Edit"),
                callback = function()
                    UIManager:close(self.details_dialog)
                    self:showDomainEditor(domain)
                end,
            },
            {
                text = _("Delete"),
                callback = function()
                    UIManager:close(self.details_dialog)
                    UIManager:show(ConfirmBox:new{
                        text = string.format(_("Delete '%s'?"), domain.name),
                        ok_callback = function()
                            self:deleteCustomDomain(domain.id)
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
                    self:addCustomDomain(
                        domain.name .. " (copy)",
                        domain.context
                    )
                    self:refreshMenu()
                    UIManager:show(InfoMessage:new{
                        text = _("Domain duplicated"),
                        timeout = 1,
                    })
                end,
            },
        })
    elseif domain.source == "folder" then
        -- Folder: View only, show file path info
        table.insert(buttons, {
            {
                text = _("About File-Based Domains"),
                callback = function()
                    UIManager:show(InfoMessage:new{
                        text = string.format(
                            _("This domain is loaded from a file in:\n\n%s\n\nTo edit, modify the file directly."),
                            DomainLoader.getFolderPath()
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
                    self:showDomainEditor(nil, domain.context, domain.name .. " (copy)")
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
        title = _("Domain Details"),
        text = info_text,
        width = self.width,
        height = self.height,
        buttons_table = buttons,
    }

    UIManager:show(self.details_dialog)
end

-- Show domain editor dialog
-- @param domain: Existing domain to edit (nil for new)
-- @param template_context: Optional context to pre-fill (for "Use as Template")
-- @param template_name: Optional name to pre-fill
function DomainManager:showDomainEditor(domain, template_context, template_name)
    local is_new = (domain == nil)
    local initial_name = domain and domain.name or template_name or ""
    local initial_context = domain and domain.context or template_context or ""

    -- Step 1: Name input
    local name_dialog
    name_dialog = InputDialog:new{
        title = is_new and _("New Domain - Name") or _("Edit Domain - Name"),
        input = initial_name,
        input_hint = _("Enter domain name..."),
        description = _("Give this domain a descriptive name (e.g., 'Research', 'Creative Writing', 'Philosophy')."),
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
                        self:showTemplateSelector(function(selected_context, selected_name)
                            -- Reopen editor with template
                            local use_name = current_name ~= "" and current_name or (selected_name and selected_name .. " (custom)")
                            self:showDomainEditor(domain, selected_context, use_name)
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
                        -- Step 2: Context editor
                        self:showDomainContextEditor(domain, name, initial_context)
                    end,
                },
            },
        },
    }

    UIManager:show(name_dialog)
end

-- Step 2: Full-screen text editor for domain context
function DomainManager:showDomainContextEditor(domain, name, initial_context)
    local is_new = (domain == nil)

    local context_dialog
    context_dialog = InputDialog:new{
        title = is_new and _("New Domain - Context") or _("Edit Domain - Context"),
        input = initial_context,
        input_hint = _("Enter domain knowledge context..."),
        description = string.format(_("Name: %s\n\nDescribe the knowledge area, terminology, and how the AI should approach topics in this domain."), name),
        input_type = "text",
        allow_newline = true,
        fullscreen = true,
        buttons = {
            {
                {
                    text = _("Cancel"),
                    id = "close",
                    callback = function()
                        UIManager:close(context_dialog)
                        self:refreshMenu()
                    end,
                },
                {
                    text = _("Save"),
                    is_enter_default = true,
                    callback = function()
                        local context = context_dialog:getInputText()
                        if context == "" then
                            UIManager:show(InfoMessage:new{
                                text = _("Please enter domain context"),
                                timeout = 2,
                            })
                            return
                        end

                        UIManager:close(context_dialog)

                        if is_new then
                            self:addCustomDomain(name, context)
                            UIManager:show(InfoMessage:new{
                                text = string.format(_("Created: %s"), name),
                                timeout = 1,
                            })
                        else
                            self:updateCustomDomain(domain.id, name, context)
                            UIManager:show(InfoMessage:new{
                                text = string.format(_("Updated: %s"), name),
                                timeout = 1,
                            })
                        end

                        self:refreshMenu()
                    end,
                },
            },
        },
    }

    UIManager:show(context_dialog)
end

-- Show template selector dialog
function DomainManager:showTemplateSelector(callback)
    local custom_domains = self:getCustomDomains()
    local all_domains = DomainLoader.getSortedDomains(custom_domains)

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

    if #all_domains == 0 then
        table.insert(buttons, {
            {
                text = _("(No existing domains to use as template)"),
                enabled = false,
            },
        })
    else
        -- Add all domains as template options
        for _idx, domain in ipairs(all_domains) do
            local source_indicator = ""
            if domain.source == "ui" then
                source_indicator = " (custom)"
            end

            table.insert(buttons, {
                {
                    text = domain.name .. source_indicator,
                    callback = function()
                        UIManager:close(self.template_dialog)
                        callback(domain.context, domain.name)
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

return DomainManager
