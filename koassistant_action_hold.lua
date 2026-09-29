--[[
koassistant_action_hold.lua - one long-press menu for every action trigger surface
(docs/action_hold_unification_plan.md, 2026-09-07; backlog B122 / D9).

A hold on an action button used to show the description on some surfaces and
nothing on others, and every add/remove lived in a manager screen under
Settings. Now every surface opens the same small menu: the description, add to
or remove from THIS menu, the other placements, and the editor.

Surfaces that can run the action pass `opts.run(variant, label)`: the menu
then opens with run buttons on top (B345, docs/run_options_plan.md), each
running the action once another way (Quick, a model, no reasoning, web), then
a double line, then the rows that change the action for good.

`plan(action, surface, on_surface)` and `layout(rows)` are pure (rows as data,
unit-tested); `show(plugin, action, opts)` renders them as a ButtonDialog.
]]

local UIManager = require("ui/uimanager")
local InfoMessage = require("ui/widget/infomessage")
local Notification = require("ui/widget/notification")
local logger = require("koassistant_logger")
local _ = require("koassistant_gettext")
local T = require("ffi/util").template

local ActionHold = {}

-- Surface id -> the membership pair on action_service + the words used in rows
-- and toasts. "input" is per context (ctx): isInInput/toggleInputAction, and the
-- general dialog's own pair.
ActionHold.SURFACES = {
    highlight     = { is_in = "isInHighlightMenu",   toggle = "toggleHighlightMenuAction" },
    dictionary    = { is_in = "isInDictionaryPopup", toggle = "toggleDictionaryPopupAction" },
    quick_actions = { is_in = "isInQuickActions",    toggle = "toggleQuickAction" },
    file_browser  = { is_in = "isInFileBrowser",     toggle = "toggleFileBrowserAction" },
    input         = {},
}

function ActionHold.surfaceLabel(surface)
    if surface == "highlight" then return _("the highlight menu")
    elseif surface == "dictionary" then return _("the dictionary popup")
    elseif surface == "quick_actions" then return _("Quick Actions")
    elseif surface == "file_browser" then return _("the file browser menu")
    elseif surface == "input" then return _("this input dialog")
    end
    return nil
end

--- Is the action on the surface right now?
--- @return boolean|nil nil when the surface has no membership
function ActionHold.isOn(action_service, surface, ctx, action_id)
    if not action_service then return nil end
    if surface == "input" then
        if ctx == "general" then return action_service:isInGeneralMenu(action_id) and true or false end
        if not ctx then return nil end
        return action_service:isInInput(ctx, action_id) and true or false
    end
    local spec = ActionHold.SURFACES[surface]
    if not spec or not spec.is_in then return nil end
    return action_service[spec.is_in](action_service, action_id) and true or false
end

--- Flip membership on the surface.
--- @return boolean|nil the new state, nil when nothing was toggled
function ActionHold.toggle(action_service, surface, ctx, action_id)
    local before = ActionHold.isOn(action_service, surface, ctx, action_id)
    if before == nil then return nil end
    if surface == "input" then
        if ctx == "general" then
            action_service:toggleGeneralMenuAction(action_id)
        else
            action_service:toggleInputAction(ctx, action_id)
        end
    else
        local spec = ActionHold.SURFACES[surface]
        action_service[spec.toggle](action_service, action_id)
    end
    return ActionHold.isOn(action_service, surface, ctx, action_id)
end

--- The rows the menu shows, as data.
--- @param action table Action object (source: builtin | ui | config)
--- @param surface string|nil Surface id the reader is holding on
--- @param on_surface boolean|nil Membership right now (nil = no membership here)
--- @return table rows { {id = "membership", on = bool} | {id = "placements"} |
---   {id = "edit", kind = "builtin"|"ui"|"config"} | {id = "duplicate"} | {id = "reset"} }
function ActionHold.plan(action, surface, on_surface)
    local rows = {}
    if surface and on_surface ~= nil then
        table.insert(rows, { id = "membership", on = on_surface })
    end
    table.insert(rows, { id = "placements" })
    local source = action.source or "builtin"
    if source == "builtin" then
        if not action.local_handler then
            table.insert(rows, { id = "edit", kind = "builtin" })
        end
    elseif source == "ui" then
        table.insert(rows, { id = "edit", kind = "ui" })
    elseif source == "config" then
        table.insert(rows, { id = "edit", kind = "config" })
    end
    if not action.local_handler then
        table.insert(rows, { id = "duplicate" })
    end
    if source == "builtin" and action.has_override then
        table.insert(rows, { id = "reset" })
    end
    return rows
end

function ActionHold.rowLabel(row, surface)
    if row.id == "membership" then
        local where = ActionHold.surfaceLabel(surface) or _("this menu")
        return row.on and T(_("Remove from %1"), where) or T(_("Add to %1"), where)
    elseif row.id == "placements" then return _("Other placements…")
    elseif row.id == "edit" then
        return row.kind == "config" and _("Edit (custom_actions.lua)…") or _("Edit…")
    elseif row.id == "duplicate" then return _("Duplicate as custom action…")
    elseif row.id == "reset" then return _("Reset to default")
    end
    return row.id
end

local function toast(text)
    UIManager:show(Notification:new{ text = text, timeout = 2 })
end

--- Run one row.
function ActionHold.run(plugin, action, row, opts)
    local svc = plugin.action_service
    if row.id == "membership" then
        local now_on = ActionHold.toggle(svc, opts.surface, opts.ctx, action.id)
        local where = ActionHold.surfaceLabel(opts.surface) or _("this menu")
        toast(now_on and T(_("Added to %1"), where) or T(_("Removed from %1"), where))
        if opts.on_change then opts.on_change(now_on) end
        return
    end
    local PromptsManager = require("koassistant_ui.prompts_manager")
    local pm = PromptsManager:new(plugin)
    -- The manager screens key on context + id; take the service's object when
    -- the caller's copy lacks it
    local prompt = action
    if not prompt.context or not prompt.source then
        prompt = (svc and svc:getAction(action.context, action.id)) or action
    end
    if row.id == "placements" then
        pm:showPromptDetails(prompt)
    elseif row.id == "edit" then
        if row.kind == "builtin" then
            pm:showBuiltinSettingsEditor(prompt)
        elseif row.kind == "ui" then
            pm:showPromptEditor(prompt)
        else
            UIManager:show(InfoMessage:new{
                text = _("This action is defined in custom_actions.lua.\nPlease edit that file directly to modify it."),
            })
        end
    elseif row.id == "duplicate" then
        pm:duplicateAction(prompt)
    elseif row.id == "reset" then
        pm:resetBuiltinOverride(prompt)
    end
end

--- Split the manage rows (run_options_plan.md Q1): membership and Edit stay in
--- the menu; the other placements, duplicate and reset go under "More…". A
--- single folded row is shown directly (a group of one is a detour).
--- @return table primary, table more
function ActionHold.layout(rows)
    local primary, more = {}, {}
    for _idx, r in ipairs(rows) do
        if r.id == "membership" or r.id == "edit" then
            primary[#primary + 1] = r
        else
            more[#more + 1] = r
        end
    end
    if #more == 1 then
        primary[#primary + 1] = more[1]
        more = {}
    end
    return primary, more
end

--- The run buttons: the run options that apply to this action here, then
--- "More models…". Each entry is { label, run = function() }.
function ActionHold.runButtons(plugin, action, opts)
    local RunOptions = require("koassistant_run_options")
    local st = RunOptions.stateFor(plugin, action, opts)
    local features = (plugin.settings and plugin.settings:readSetting("features")) or {}
    local out = {}
    for _idx, b in ipairs(RunOptions.buttons(RunOptions.list(features), action, st)) do
        local variant, label = b.variant, b.label
        out[#out + 1] = { label = label, run = function() opts.run(variant, label) end }
    end
    out[#out + 1] = {
        label = (st.emoji and "\u{1F916} " or "") .. _("More models…"),
        run = function()
            require("koassistant_dialogs").pickProviderModel({
                plugin = plugin,
                current = st.base,
                -- Opens on the models of the provider a tap would use
                start_provider = st.base.provider,
                on_pick = function(provider, model)
                    -- The pick fills a model spot from now on
                    RunOptions.rememberPick(plugin, provider, model)
                    opts.run({ provider = provider, model = model }, model)
                end,
            })
        end,
    }
    return out
end

local function showMore(plugin, action, rows, opts)
    local ButtonDialog = require("ui/widget/buttondialog")
    local dialog
    local buttons = {}
    for _idx, row in ipairs(rows) do
        local r = row
        table.insert(buttons, { {
            text = ActionHold.rowLabel(r, opts.surface),
            callback = function()
                UIManager:close(dialog)
                ActionHold.run(plugin, action, r, opts)
            end,
        } })
    end
    dialog = ButtonDialog:new{
        title = action.text or action.id or "",
        title_align = "left",
        buttons = buttons,
    }
    UIManager:show(dialog)
end

--- Open the hold menu.
--- @param plugin table The AskGPT instance (action_service, settings)
--- @param action table The action held
--- @param opts table { surface = string|nil, ctx = input context|nil, on_change = function(now_on)|nil,
---   run = function(variant, label)|nil (the surface runs the action once with a run option),
---   session = { quick, web }|nil (input dialog chips), book_file = string|nil (file-browser row) }
function ActionHold.show(plugin, action, opts)
    opts = opts or {}
    if not action then return end
    if not (plugin and plugin.action_service) then
        if action.description then UIManager:show(InfoMessage:new{ text = action.description }) end
        return
    end
    local on = ActionHold.isOn(plugin.action_service, opts.surface, opts.ctx, action.id)
    local primary, more = ActionHold.layout(ActionHold.plan(action, opts.surface, on))
    local ButtonDialog = require("ui/widget/buttondialog")
    local dialog
    local buttons = {}
    -- Run once with… (B345): a failure here must never cost the reader the menu
    local run_buttons
    if opts.run and not action.local_handler then
        local ok, res = pcall(ActionHold.runButtons, plugin, action, opts)
        if ok then
            run_buttons = res
        else
            logger.warn("KOAssistant: hold menu run options failed:", res)
        end
    end
    if run_buttons then
        local row = {}
        for _idx, b in ipairs(run_buttons) do
            local rb = b
            table.insert(row, {
                text = rb.label,
                callback = function()
                    UIManager:close(dialog)
                    rb.run()
                end,
            })
            if #row == 2 then
                table.insert(buttons, row)
                row = {}
            end
        end
        if #row > 0 then table.insert(buttons, row) end
    end
    local manage = {}
    for _idx, row in ipairs(primary) do
        local r = row
        table.insert(manage, {
            text = ActionHold.rowLabel(r, opts.surface),
            callback = function()
                UIManager:close(dialog)
                ActionHold.run(plugin, action, r, opts)
            end,
        })
    end
    if #more > 0 then
        table.insert(manage, {
            text = _("More…"),
            callback = function()
                UIManager:close(dialog)
                showMore(plugin, action, more, opts)
            end,
        })
    end
    if #buttons > 0 and #manage > 0 then
        -- KOReader's group separator (an empty row, as in the file browser's
        -- long-press dialog): what runs now above, what changes the action below
        table.insert(buttons, {})
    end
    -- The membership row reads longest, so it stands alone; the rest pair up
    local i = 1
    if primary[1] and primary[1].id == "membership" then
        table.insert(buttons, { manage[1] })
        i = 2
    end
    while i <= #manage do
        table.insert(buttons, { manage[i], manage[i + 1] })
        i = i + 2
    end
    -- The description alone: the reader knows which action they held
    local title
    if action.description and action.description ~= "" then
        title = action.description
    end
    dialog = ButtonDialog:new{
        title = title,
        title_align = "left",
        -- Narrower than the 0.9 default, so the menu underneath shows at the edges
        width_factor = 0.7,
        buttons = buttons,
    }
    UIManager:show(dialog)
end

return ActionHold
