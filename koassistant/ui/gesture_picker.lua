--[[
The gesture picker (B489, ruled 2026-10-19): ONE picker over every gesture
slot KOReader's Gestures plugin has, in KOReader's own sections, for the
Setup Wizard's "Open it fast" step (both faces) and the Gestures screen
(Settings → Gestures). A free slot is assigned on a tap; a taken slot shows
what holds it and asks before it is replaced (the slot's other actions are
removed: this picker gives a gesture one action, KOReader's own gesture
manager stacks); a slot holding this action offers Remove. The write goes
through the live Gestures plugin when it is loaded (applies at once), else
through gestures.lua's own settings object (after a restart).

The slot ids, sections and words are a frozen copy of gestures.koplugin's
section_titles, section_items and gestures_list (file-local there, not
reachable from a plugin; read from KOReader 2026-10-19), checked by
tests/unit/test_gesture_picker.lua against the installed KOReader's file
whenever it is present. Pure: SECTIONS, sectionOf, slotLabel, freeCount,
plan, holder, bindingsFor.
]]

local _ = require("koassistant.core.gettext")
local T = require("ffi/util").template
local logger = require("koassistant.core.logger")

local GesturePicker = {}

-- The multiswipes as KOReader draws them (symbols, not words; no _())
local MULTISWIPES = {
    { "multiswipe_west_east", "⬅ ➡" }, { "multiswipe_east_west", "➡ ⬅" },
    { "multiswipe_north_east", "⬆ ➡" }, { "multiswipe_north_west", "⬆ ⬅" },
    { "multiswipe_north_south", "⬆ ⬇" }, { "multiswipe_east_north", "➡ ⬆" },
    { "multiswipe_west_north", "⬅ ⬆" }, { "multiswipe_east_south", "➡ ⬇" },
    { "multiswipe_south_north", "⬇ ⬆" }, { "multiswipe_south_east", "⬇ ➡" },
    { "multiswipe_south_west", "⬇ ⬅" }, { "multiswipe_west_south", "⬅ ⬇" },
    { "multiswipe_north_south_north", "⬆ ⬇ ⬆" }, { "multiswipe_south_north_south", "⬇ ⬆ ⬇" },
    { "multiswipe_west_east_west", "⬅ ➡ ⬅" }, { "multiswipe_east_west_east", "➡ ⬅ ➡" },
    { "multiswipe_south_west_north", "⬇ ⬅ ⬆" }, { "multiswipe_north_east_south", "⬆ ➡ ⬇" },
    { "multiswipe_north_west_south", "⬆ ⬅ ⬇" }, { "multiswipe_west_south_east", "⬅ ⬇ ➡" },
    { "multiswipe_west_north_east", "⬅ ⬆ ➡" }, { "multiswipe_east_south_west", "➡ ⬇ ⬅" },
    { "multiswipe_east_north_west", "➡ ⬆ ⬅" }, { "multiswipe_south_east_north", "⬇ ➡ ⬆" },
    { "multiswipe_east_north_west_east", "➡ ⬆ ⬅ ➡" }, { "multiswipe_south_east_north_south", "⬇ ➡ ⬆ ⬇" },
    { "multiswipe_east_south_west_north", "➡ ⬇ ⬅ ⬆" }, { "multiswipe_west_south_east_north", "⬅ ⬇ ➡ ⬆" },
    { "multiswipe_south_east_north_west", "⬇ ➡ ⬆ ⬅" }, { "multiswipe_south_west_north_east", "⬇ ⬅ ⬆ ➡" },
    { "multiswipe_southeast_northeast", "⬊ ⬈" }, { "multiswipe_northeast_southeast", "⬈ ⬊" },
    { "multiswipe_northwest_southwest_northwest", "⬉ ⬋ ⬉" },
    { "multiswipe_southeast_southwest_northwest", "⬊ ⬋ ⬉" },
    { "multiswipe_southeast_northeast_northwest", "⬊ ⬈ ⬉" },
}

local function slots(list)
    local out = {}
    for _idx, s in ipairs(list) do out[#out + 1] = { id = s[1], label = s[2] } end
    return out
end

local multiswipe_slots = {}
for _idx, m in ipairs(MULTISWIPES) do
    multiswipe_slots[#multiswipe_slots + 1] = { id = m[1], label = T(_("Multiswipe %1"), m[2]) }
end

--- KOReader's sections, in its order, each with its slots. `enable_setting`
--- names the G_reader_settings switch the section needs on; `ignore_setting`
--- the one that makes KOReader ignore it while on (a note on its page).
GesturePicker.SECTIONS = {
    { key = "tap_corner", label = _("Tap corner"), slots = slots({
        { "tap_top_left_corner", _("Tap top-left corner") },
        { "tap_top_right_corner", _("Tap top-right corner") },
        { "tap_left_bottom_corner", _("Tap bottom-left corner") },
        { "tap_right_bottom_corner", _("Tap bottom-right corner") },
    }) },
    { key = "hold_corner", label = _("Long-press on corner"), ignore_setting = "ignore_hold_corners", slots = slots({
        { "hold_top_left_corner", _("Long-press top-left corner") },
        { "hold_top_right_corner", _("Long-press top-right corner") },
        { "hold_bottom_left_corner", _("Long-press bottom-left corner") },
        { "hold_bottom_right_corner", _("Long-press bottom-right corner") },
    }) },
    { key = "one_finger_swipe", label = _("One-finger swipe"), slots = slots({
        { "short_diagonal_swipe", _("Short diagonal swipe") },
        { "one_finger_swipe_left_edge_down", _("Swipe down the left edge") },
        { "one_finger_swipe_left_edge_up", _("Swipe up the left edge") },
        { "one_finger_swipe_right_edge_down", _("Swipe down the right edge") },
        { "one_finger_swipe_right_edge_up", _("Swipe up the right edge") },
        { "one_finger_swipe_top_edge_right", _("Swipe right along the top edge") },
        { "one_finger_swipe_top_edge_left", _("Swipe left along the top edge") },
        { "one_finger_swipe_bottom_edge_right", _("Swipe right along the bottom edge") },
        { "one_finger_swipe_bottom_edge_left", _("Swipe left along the bottom edge") },
    }) },
    { key = "double_tap", label = _("Double tap"), slots = slots({
        { "double_tap_left_side", _("Double-tap left side") },
        { "double_tap_right_side", _("Double-tap right side") },
        { "double_tap_top_left_corner", _("Double-tap top-left corner") },
        { "double_tap_top_right_corner", _("Double-tap top-right corner") },
        { "double_tap_bottom_left_corner", _("Double-tap bottom-left corner") },
        { "double_tap_bottom_right_corner", _("Double-tap bottom-right corner") },
    }) },
    { key = "two_finger_tap", label = _("Two-finger tap corner"), slots = slots({
        { "two_finger_tap_top_left_corner", _("Two-finger tap top-left corner") },
        { "two_finger_tap_top_right_corner", _("Two-finger tap top-right corner") },
        { "two_finger_tap_bottom_left_corner", _("Two-finger tap bottom-left corner") },
        { "two_finger_tap_bottom_right_corner", _("Two-finger tap bottom-right corner") },
    }) },
    { key = "two_finger_swipe", label = _("Two-finger swipe"), slots = slots({
        { "two_finger_swipe_east", _("Two-finger swipe east") },
        { "two_finger_swipe_west", _("Two-finger swipe west") },
        { "two_finger_swipe_south", _("Two-finger swipe south") },
        { "two_finger_swipe_north", _("Two-finger swipe north") },
        { "two_finger_swipe_northeast", _("Two-finger swipe northeast") },
        { "two_finger_swipe_northwest", _("Two-finger swipe northwest") },
        { "two_finger_swipe_southeast", _("Two-finger swipe southeast") },
        { "two_finger_swipe_southwest", _("Two-finger swipe southwest") },
    }) },
    { key = "spread_and_pinch", label = _("Spread and pinch"), slots = slots({
        { "spread_gesture", _("Spread") },
        { "pinch_gesture", _("Pinch") },
    }) },
    { key = "two_finger_rotation", label = _("Two-finger rotation"), slots = slots({
        { "rotate_cw", _("Rotate clockwise") },
        { "rotate_ccw", _("Rotate counterclockwise") },
    }) },
    { key = "multiswipes", label = _("Multiswipes"), enable_setting = "multiswipes_enabled", slots = multiswipe_slots },
}

local BY_ID = {}
local order = 0
for _idx, section in ipairs(GesturePicker.SECTIONS) do
    for _jdx, slot in ipairs(section.slots) do
        order = order + 1
        BY_ID[slot.id] = { section = section, slot = slot, order = order }
    end
end

--- The section a slot id belongs to (nil for an id this copy does not know).
function GesturePicker.sectionOf(slot_id)
    local hit = BY_ID[slot_id]
    return hit and hit.section or nil
end

--- A slot's words, or the raw id prettified for a slot this copy does not
--- know (a newer KOReader's gesture bound in its own manager).
function GesturePicker.slotLabel(slot_id)
    local hit = BY_ID[slot_id]
    if hit then return hit.slot.label end
    return (tostring(slot_id):gsub("_", " "))
end

--- The mode a gestures section key stands for, in words.
function GesturePicker.modeLabel(section_key)
    return section_key == "gesture_fm" and _("file browser") or _("reader")
end

-- Free/taken state of one slot entry (the wizard's rule): nil or an empty
-- table is free; the `settings` subtable never counts as an action.
local function slotState(entry)
    if entry == nil or (type(entry) == "table" and next(entry) == nil) then return "free", 0 end
    local n = 0
    if type(entry) == "table" then
        for k in pairs(entry) do
            if k ~= "settings" then n = n + 1 end
        end
    end
    -- a slot keeping only its settings subtable has no action: free
    if n == 0 then return "free", 0 end
    return "taken", n
end
GesturePicker.slotState = slotState

--- How many of a section's slots are free in one mode's data. Pure.
--- @return number free, number total
function GesturePicker.freeCount(section, mode_data)
    local free = 0
    for _idx, slot in ipairs(section.slots) do
        if slotState((mode_data or {})[slot.id]) == "free" then free = free + 1 end
    end
    return free, #section.slots
end

--- What a tap on a slot does for this action: "free" assigns, "mine" offers
--- Remove, "taken" asks before replacing. Pure.
function GesturePicker.plan(entry, action_id)
    if slotState(entry) == "free" then return "free" end
    if type(entry) == "table" and entry[action_id] then return "mine" end
    return "taken"
end

--- The words for what holds a slot: describe(entry) (the Dispatcher's menu
--- text in the live module), "taken" when it cannot say. Pure.
function GesturePicker.holder(entry, describe)
    if type(describe) == "function" then
        local ok, text = pcall(describe, entry)
        if ok and type(text) == "string" and text ~= "" then return text end
    end
    return _("taken")
end

--- Every slot holding an action, in both modes, sorted for a steady display
--- (pairs order is unstable). Pure.
--- @return table { { section = "gesture_reader"|"gesture_fm", slot = id }, ... }
function GesturePicker.bindingsFor(data, action_id)
    local out = {}
    for _idx, section_key in ipairs({ "gesture_reader", "gesture_fm" }) do
        local section = (data or {})[section_key]
        if type(section) == "table" then
            for slot, entry in pairs(section) do
                if type(entry) == "table" and entry[action_id] then
                    out[#out + 1] = { section = section_key, slot = slot }
                end
            end
        end
    end
    -- by mode, then in the picker's own order (tap corners first, multiswipes
    -- last), so a panel's corner reads before any other gesture bound to it
    -- (the maintainer, 2026-10-19: alphabetical put a device's multiswipes
    -- first and they read as defaults); an unknown slot id last, by name
    table.sort(out, function(a, b)
        if a.section ~= b.section then return a.section < b.section end
        local oa = BY_ID[a.slot] and BY_ID[a.slot].order or math.huge
        local ob = BY_ID[b.slot] and BY_ID[b.slot].order or math.huge
        if oa ~= ob then return oa < ob end
        return a.slot < b.slot
    end)
    return out
end

--- Every action id bound in either mode that starts with `prefix` and is
--- not in the set `except`, sorted (B609: the Gestures screen's rows for
--- bindings whose plugin id no longer resolves, so they can be removed where
--- KOReader's gesture manager shows "Unknown item"). Pure.
--- @return table ids
function GesturePicker.boundIds(data, prefix, except)
    local seen, out = {}, {}
    for _idx, section_key in ipairs({ "gesture_reader", "gesture_fm" }) do
        local section = (data or {})[section_key]
        if type(section) == "table" then
            for _slot, entry in pairs(section) do
                if type(entry) == "table" then
                    for id in pairs(entry) do
                        if type(id) == "string" and id ~= "settings" and id:sub(1, #prefix) == prefix
                            and not (except and except[id]) and not seen[id] then
                            seen[id] = true
                            out[#out + 1] = id
                        end
                    end
                end
            end
        end
    end
    table.sort(out)
    return out
end

--- One action's bindings in words: "Tap bottom-right corner (reader), …" or nil.
function GesturePicker.bindingsText(data, action_id)
    local parts = {}
    for _idx, b in ipairs(GesturePicker.bindingsFor(data, action_id)) do
        parts[#parts + 1] = T(_("%1 (%2)"), GesturePicker.slotLabel(b.slot), GesturePicker.modeLabel(b.section))
    end
    if #parts == 0 then return nil end
    return table.concat(parts, ", ")
end

--========================================================================--
--  The live side: KOReader's gesture data and the writes
--========================================================================--

--- KOReader's gesture data: the live Gestures plugin's settings object when
--- it is loaded (its writes apply at once; the object is class-level, shared
--- by the reader and the file browser), else gestures.lua opened here (a
--- write then needs a restart).
--- @return table data, table|nil live (the Gestures instance), table settings
function GesturePicker.access(plugin)
    local ges = plugin and plugin.ui and plugin.ui.gestures
    if ges and ges.settings and ges.settings.data then
        return ges.settings.data, ges, ges.settings
    end
    local DataStorage = require("datastorage")
    local LuaSettings = require("luasettings")
    local settings = LuaSettings:open(DataStorage:getSettingsDir() .. "/gestures.lua")
    settings.data = settings.data or {}
    return settings.data, nil, settings
end

--- Whether KOReader has any gesture data yet (the Gestures plugin ran once).
function GesturePicker.ready(data)
    return type(data) == "table" and (data.gesture_reader ~= nil or data.gesture_fm ~= nil or next(data) ~= nil)
end

local function describeEntry(entry)
    local Dispatcher = require("dispatcher")
    return Dispatcher:menuTextFunc(entry)
end

--- Bind action_id to a slot (the slot's other actions are removed: one
--- action per gesture here). opts.wizard = the wizard's session (the write
--- is recorded in features._wizard_gesture_writes for the undo audit).
--- @return string "live" (applies now) | "restart"
function GesturePicker.assign(plugin, section_key, slot, action_id, opts)
    local data, live, settings = GesturePicker.access(plugin)
    data[section_key] = data[section_key] or {}
    data[section_key][slot] = { [action_id] = true }
    if live then
        -- Re-point the fire-time table in case the section table was
        -- created fresh (normally the same reference, a no-op)
        if live.ges_mode then live.gestures = data[live.ges_mode] end
    end
    settings:flush()
    if opts and opts.wizard and plugin.settings then
        local f = plugin.settings:readSetting("features") or {}
        f._wizard_gesture_writes = f._wizard_gesture_writes or {}
        table.insert(f._wizard_gesture_writes, { section = section_key, slot = slot, action = action_id })
        plugin.settings:saveSetting("features", f)
        plugin.settings:flush()
    end
    logger.dbg("KOAssistant gestures: assigned", action_id, "to", slot, "in", section_key,
        live and "live" or "after a restart")
    return live and "live" or "restart"
end

--- Remove action_id from a slot, as KOReader's own uncheck does (the order
--- table trimmed too); a slot left with nothing goes back to nil, so a tap
--- that used to fall through (to a page turn, say) falls through again.
--- @return string "live" | "restart"
function GesturePicker.remove(plugin, section_key, slot, action_id)
    local data, live, settings = GesturePicker.access(plugin)
    local sec = data[section_key]
    local entry = sec and sec[slot]
    if type(entry) ~= "table" then return live and "live" or "restart" end
    entry[action_id] = nil
    local ok, Dispatcher = pcall(require, "dispatcher")
    if ok and Dispatcher and Dispatcher._removeFromOrder then
        pcall(Dispatcher._removeFromOrder, sec, slot, action_id)
    end
    local remaining = 0
    for k in pairs(entry) do
        if k ~= "settings" then remaining = remaining + 1 end
    end
    if remaining == 0 then sec[slot] = nil end
    if live and live.ges_mode then live.gestures = data[live.ges_mode] end
    settings:flush()
    logger.dbg("KOAssistant gestures: removed", action_id, "from", slot, "in", section_key,
        live and "live" or "after a restart")
    return live and "live" or "restart"
end

--- Every binding of action_id taken down, in both modes (a deleted action's
--- gestures go with it, B609).
--- @return number how many, string "live" | "restart"
function GesturePicker.forget(plugin, action_id)
    local data = GesturePicker.access(plugin)
    local bindings = GesturePicker.bindingsFor(data, action_id)
    local how = "live"
    for _idx, b in ipairs(bindings) do
        how = GesturePicker.remove(plugin, b.section, b.slot, action_id)
    end
    return #bindings, how
end

--- The picker. opts = { plugin, action_id, action_label, section_key
--- ("gesture_reader" | "gesture_fm"), wizard (the wizard's session, or nil),
--- on_done(slot_id | nil, how) (how = "live" | "restart" | "removed"),
--- on_cancel() }. Both callbacks run once.
function GesturePicker.show(opts)
    local UIManager = require("ui/uimanager")
    local ButtonDialog = require("ui/widget/buttondialog")
    local ConfirmBox = require("ui/widget/confirmbox")
    local plugin = opts.plugin
    local action_id = opts.action_id
    local section_key = opts.section_key or "gesture_reader"
    local finished = false
    local function finish(fn, ...)
        if finished then return end
        finished = true
        if fn then fn(...) end
    end
    local function cancel() finish(opts.on_cancel) end
    local function done(slot, how) finish(opts.on_done, slot, how) end

    local data, live = GesturePicker.access(plugin)
    local mode_data = data[section_key] or {}
    local G = rawget(_G, "G_reader_settings")
    local function settingOn(key) return G ~= nil and G:isTrue(key) end
    local where = live and _("A pick starts working right away.") or _("A pick takes effect after a restart.")
    local head = T(_("%1 (%2)"), opts.action_label or action_id, GesturePicker.modeLabel(section_key))

    local sections_dialog
    local function showSection(section)
        if sections_dialog then UIManager:close(sections_dialog); sections_dialog = nil end
        local dialog
        local function back()
            if dialog then UIManager:close(dialog); dialog = nil end
            GesturePicker.show(opts)
        end
        local buttons = {}
        for _idx, slot in ipairs(section.slots) do
            local entry = mode_data[slot.id]
            local plan = GesturePicker.plan(entry, action_id)
            local text = slot.label
            if plan == "mine" then
                text = T(_("%1 (this one)"), slot.label)
            elseif plan == "taken" then
                text = T(_("%1: %2"), slot.label, GesturePicker.holder(entry, describeEntry))
            end
            buttons[#buttons + 1] = {{ text = text, callback = function()
                if plan == "free" then
                    UIManager:close(dialog); dialog = nil
                    done(slot.id, GesturePicker.assign(plugin, section_key, slot.id, action_id, { wizard = opts.wizard }))
                elseif plan == "mine" then
                    UIManager:close(dialog); dialog = nil
                    UIManager:show(ConfirmBox:new{
                        text = T(_("Remove %1 from %2?"), opts.action_label or action_id, slot.label),
                        ok_text = _("Remove"),
                        ok_callback = function()
                            GesturePicker.remove(plugin, section_key, slot.id, action_id)
                            done(nil, "removed")
                        end,
                        cancel_callback = function() GesturePicker.show(opts) end,
                    })
                else
                    UIManager:close(dialog); dialog = nil
                    UIManager:show(ConfirmBox:new{
                        text = T(_("Replace %1 on %2 with %3?"), GesturePicker.holder(entry, describeEntry),
                            slot.label, opts.action_label or action_id) .. "\n" ..
                            _("The gesture then does only this; the action it had is unbound."),
                        ok_text = _("Replace"),
                        ok_callback = function()
                            done(slot.id, GesturePicker.assign(plugin, section_key, slot.id, action_id, { wizard = opts.wizard }))
                        end,
                        cancel_callback = function() GesturePicker.show(opts) end,
                    })
                end
            end }}
        end
        buttons[#buttons + 1] = {{ text = _("Back"), id = "close", callback = back }}
        local title = head .. "\n" .. section.label .. "\n" .. where
        if section.ignore_setting and settingOn(section.ignore_setting) then
            title = title .. "\n" .. _("KOReader ignores corner long-presses while its \"Ignore long-press on corners\" setting is on (Taps and gestures).")
        end
        dialog = ButtonDialog:new{ title = title, buttons = buttons, tap_close_callback = back }
        UIManager:show(dialog)
    end

    local buttons = {}
    for _idx, section in ipairs(GesturePicker.SECTIONS) do
        local off = section.enable_setting and not settingOn(section.enable_setting)
        local free, total = GesturePicker.freeCount(section, mode_data)
        local text
        if off then
            text = T(_("%1 (off in KOReader's gesture settings)"), section.label)
        else
            text = T(_("%1: %2 of %3 free"), section.label, free, total)
        end
        buttons[#buttons + 1] = {{ text = text, enabled = not off, callback = function() showSection(section) end }}
    end
    buttons[#buttons + 1] = {{ text = _("Cancel"), id = "close", callback = function()
        if sections_dialog then UIManager:close(sections_dialog); sections_dialog = nil end
        cancel()
    end }}
    sections_dialog = ButtonDialog:new{
        title = head .. "\n" .. _("Pick a gesture. A gesture in use shows what holds it; it can be replaced.") .. "\n" .. where,
        buttons = buttons,
        tap_close_callback = function() sections_dialog = nil; cancel() end,
    }
    UIManager:show(sections_dialog)
end

return GesturePicker
