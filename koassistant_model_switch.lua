--[[
koassistant_model_switch.lua - the model button in the highlight menu and the
dictionary popup (issue #86; B345 step 4, docs/run_options_plan.md 3.6 and Q5).

The button shows your model. A tap lists your favorites and recent picks, then
"More models…"; a pick switches your model for good (AskGPT:switchModel, the
model menu's own switch) and the button relabels in place, so the menu and the
selection stay open. Actions with their own model keep it: this changes what
"your model" is, while an action's long-press menu runs it once on another one.

`entries()` is pure (unit-tested); `show()` draws the list.
]]

local UIManager = require("ui/uimanager")
local _ = require("koassistant_gettext")
local T = require("ffi/util").template

local ModelSwitch = {}

--- The button's text: the model in effect, as the Quick Settings Model button reads.
function ModelSwitch.label(plugin)
    local features = plugin.settings:readSetting("features") or {}
    local model = plugin:getCurrentModel() or "?"
    if features.enable_emoji_icons == true then
        return "\u{1F916} " .. model
    end
    return T(_("Model: %1"), model)
end

--- The list's models: the favorites in their order, then the recent "More
--- models…" picks not already listed. A provider without a key is left out.
--- @param features table
--- @param configured function|nil (provider) -> boolean; nil = no key filter
--- @return table { { provider, model, favorite }, ... }
function ModelSwitch.entries(features, configured)
    local RunOptions = require("koassistant_run_options")
    local out, seen = {}, {}
    local function add(e, favorite)
        local key = e.provider .. "/" .. e.model
        if seen[key] or (configured and not configured(e.provider)) then return end
        seen[key] = true
        out[#out + 1] = { provider = e.provider, model = e.model, favorite = favorite }
    end
    for _idx, f in ipairs(RunOptions.favoriteModels(features)) do add(f, true) end
    for _idx, r in ipairs(RunOptions.recentModels(features)) do add(r, false) end
    return out
end

local function providerName(plugin, provider)
    local cp = plugin.getCustomProvider and plugin:getCustomProvider(provider)
    if cp then return cp.name or provider end
    return plugin.getProviderDisplayName and plugin:getProviderDisplayName(provider) or provider
end

--- Show the list over the menu that holds the button.
--- @param on_switched function|nil runs after a switch (the caller relabels its button)
function ModelSwitch.show(plugin, on_switched)
    local RunOptions = require("koassistant_run_options")
    local features = plugin.settings:readSetting("features") or {}
    local cur_provider, cur_model = plugin:getCurrentProvider(), plugin:getCurrentModel()
    local function switchTo(provider, model)
        plugin:switchModel(provider, model)
        if on_switched then on_switched() end
    end
    local function more()
        require("koassistant_dialogs").pickProviderModel({
            plugin = plugin,
            current = { provider = cur_provider, model = cur_model },
            start_provider = cur_provider,
            on_pick = function(provider, model)
                RunOptions.rememberPick(plugin, provider, model)
                switchTo(provider, model)
            end,
        })
    end
    local filter = plugin.hasAnyRealApiKey and plugin:hasAnyRealApiKey()
    local list = ModelSwitch.entries(features,
        filter and function(p) return plugin:isProviderConfigured(p) end or nil)
    if #list == 0 then
        -- Nothing to list yet: the full picker at once
        more()
        return
    end
    local ButtonDialog = require("ui/widget/buttondialog")
    local dialog
    local buttons = {}
    for _idx, e in ipairs(list) do
        local entry = e
        local is_current = entry.provider == cur_provider and entry.model == cur_model
        local text = (is_current and "● " or "○ ")
            .. (entry.favorite and RunOptions.FAVORITE_MARK or "") .. entry.model
        if entry.provider ~= cur_provider then
            text = text .. " · " .. providerName(plugin, entry.provider)
        end
        table.insert(buttons, {{
            text = text,
            callback = function()
                UIManager:close(dialog)
                if not is_current then switchTo(entry.provider, entry.model) end
            end,
            -- Long-press: add to or remove from the favorites, as in every picker
            hold_callback = function()
                UIManager:close(dialog)
                RunOptions.toggleFavorite(plugin, entry.provider, entry.model)
                ModelSwitch.show(plugin, on_switched)
            end,
        }})
    end
    table.insert(buttons, {{
        text = (features.enable_emoji_icons == true and "\u{1F916} " or "") .. _("More models…"),
        callback = function()
            UIManager:close(dialog)
            more()
        end,
    }})
    dialog = ButtonDialog:new{
        width_factor = 0.7,
        buttons = buttons,
    }
    UIManager:show(dialog)
end

return ModelSwitch
