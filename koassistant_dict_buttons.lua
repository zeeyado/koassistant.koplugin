--[[--
Pure helpers for registering KOAssistant actions as dictionary-popup buttons.

This module holds the dependency-free decision logic shared by the two
dictionary-button adapters in main.lua:
  * the new-API adapter (AskGPT:syncDictButtons → ReaderDictionary:addToDictButtons,
    KOReader PR #15184+), and
  * the legacy fallback (AskGPT:onDictButtonsReady, the DictButtonsReady event).

Keeping the id/row formatting, stale-key detection, visibility gating, and row
splitting here (no KOReader requires) makes them unit-testable in isolation —
main.lua itself can't be loaded under the test harness.
]]

local DictButtons = {}

-- Buttons per row in the popup (mirrors the legacy layout).
DictButtons.PER_ROW = 3

-- Prefix that marks a dict-button id as ours (used for stale-key clearing).
DictButtons.ID_PREFIX = "koassistant_dict_"

--- Stable button id for the i-th (1-based) action. Zero-padded so KOReader's
--- alphabetical `orderedPairs` iteration preserves our configured order.
function DictButtons.specId(index, action_id)
    return string.format("koassistant_dict_%02d_%s", index, tostring(action_id))
end

--- Row-group key for the i-th action — groups buttons into rows of PER_ROW.
function DictButtons.rowGroup(index)
    return "koassistant_dict_row" .. tostring(math.ceil(index / DictButtons.PER_ROW))
end

--- Button label: action display text + our " (KOA)" suffix.
function DictButtons.label(display_text)
    return tostring(display_text) .. " (KOA)"
end

--- Static spec scaffold for `addToDictButtons` (caller attaches show_func/callback,
--- which need plugin/runtime state). Buttons are `conditional` so they always
--- render (gated only by show_func) regardless of the user's saved button layout.
function DictButtons.scaffold(action, index, display_text)
    return {
        id = DictButtons.specId(index, action.id),
        text = DictButtons.label(display_text),
        font_bold = true,
        conditional = true,
        row_group = DictButtons.rowGroup(index),
    }
end

--- Collect the keys in a `_dict_buttons` table that belong to us, so the caller
--- can nil them before re-registering (KOReader exposes no removal API).
--- Returned as a list — never delete while iterating the source table.
function DictButtons.ourKeys(dict_buttons)
    local keys = {}
    for id in pairs(dict_buttons or {}) do
        if type(id) == "string" and id:sub(1, #DictButtons.ID_PREFIX) == DictButtons.ID_PREFIX then
            table.insert(keys, id)
        end
    end
    return keys
end

--- Visibility decision for a dict-popup button (the gating part of show_func).
--- Pure: `has_document` is a boolean; `has_xray_fn` is called only when the
--- action needs an X-Ray cache (so the lookup is skipped for normal actions).
--- Non-reader-lookup flag consumption is a side-effect handled by the caller.
function DictButtons.shouldShow(popup, action, has_document, has_xray_fn)
    if popup.is_wiki then return false end                       -- never on Wikipedia popups
    if not popup.word or popup.word == "" then return false end  -- skip no-result windows
    if action.requires_open_book and not has_document then return false end
    if action.requires_xray_cache then                           -- conditional X-Ray button
        if not (has_xray_fn and has_xray_fn()) then return false end
    end
    return true
end

--- Consume the pending non-reader-lookup flag once, transferring it from the
--- dictionary onto the popup. Idempotent: a later call (e.g. a pagination/resize
--- rebuild) keeps the value already captured for this popup. `dict` may be nil.
--- Returns the captured boolean.
function DictButtons.consumeNonReader(popup, dict)
    if popup._koassistant_non_reader == nil then
        popup._koassistant_non_reader = (dict and dict._koassistant_non_reader_lookup) or false
        if dict then dict._koassistant_non_reader_lookup = nil end
    end
    return popup._koassistant_non_reader
end

--- Split a flat list of buttons into rows of `per_row` (default PER_ROW),
--- last row partial. Used by the legacy path's row insertion.
function DictButtons.splitRows(buttons, per_row)
    per_row = per_row or DictButtons.PER_ROW
    local rows, current = {}, {}
    for _idx = 1, #buttons do
        table.insert(current, buttons[_idx])
        if #current == per_row then
            table.insert(rows, current)
            current = {}
        end
    end
    if #current > 0 then
        table.insert(rows, current)
    end
    return rows
end

return DictButtons
