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

--- Button label: action display text + our " (KOA)" suffix, unless the reader
--- unticked it for the dictionary popup (`features`, B348).
function DictButtons.label(display_text, features)
    return require("koassistant.core.constants").koaLabel(tostring(display_text), "dictionary", features)
end

--- Static spec scaffold for `addToDictButtons` (caller attaches show_func/callback,
--- which need plugin/runtime state). Buttons are `conditional` so they always
--- render (gated only by show_func) regardless of the user's saved button layout.
function DictButtons.scaffold(action, index, display_text, features)
    return {
        id = DictButtons.specId(index, action.id),
        text = DictButtons.label(display_text, features),
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
--- Also transfers `_koassistant_lookup_book` (the originating surface's own
--- book, set by chat-viewer/selection-popup lookups) so the X-Ray button can
--- target the chat's book instead of whatever the reader has open.
--- Returns the captured boolean.
function DictButtons.consumeNonReader(popup, dict)
    if popup._koassistant_non_reader == nil then
        popup._koassistant_non_reader = (dict and dict._koassistant_non_reader_lookup) or false
        popup._koassistant_lookup_book = dict and dict._koassistant_lookup_book or nil
        if dict then
            dict._koassistant_non_reader_lookup = nil
            dict._koassistant_lookup_book = nil
        end
    end
    return popup._koassistant_non_reader
end

--- The passage a dictionary window's definition would be kept on: the
--- selection KOReader handed the window (a lookup made in the book), else the
--- one the plugin sent along when it opened the window itself from one of its
--- answers (ChatGPTViewer.lookupNative; taken over by takeKeepSelection). Pure.
-- @return table|nil { pos0, pos1, text, ... }
function DictButtons.selectionOf(popup)
    if not popup then return nil end
    local hl = popup.highlight
    local live = hl and hl.selected_text
    if type(live) == "table" and live.pos0 ~= nil and live.pos1 ~= nil then return live end
    local sent = popup._koassistant_keep_selection
    if type(sent) == "table" and sent.pos0 ~= nil and sent.pos1 ~= nil then return sent end
    return nil
end

--- Move the selection the plugin sent along with a lookup from the dictionary
--- module onto the window that shows it, once (as consumeNonReader does for
--- its flags; a rebuild of the window's buttons keeps what was taken).
function DictButtons.takeKeepSelection(popup, dict)
    if popup._koassistant_keep_selection == nil then
        popup._koassistant_keep_selection = (dict and dict._koassistant_keep_selection) or false
        if dict then dict._koassistant_keep_selection = nil end
    end
    return popup._koassistant_keep_selection or nil
end

--- Whether a definition on KOReader's dictionary window can be kept as the
--- looked-up word's note (the "+Note" button, a selected part of a definition):
--- there is a passage to keep it on (selectionOf); a real result is shown;
--- never on a Wikipedia window. Pure.
function DictButtons.canKeepDefinition(popup)
    if not popup or popup.is_wiki then return false end
    if not popup.word or popup.word == "" then return false end
    local result = type(popup.results) == "table" and popup.results[popup.dict_index or 1]
    if not result or result.no_result then return false end
    return DictButtons.selectionOf(popup) ~= nil
end

--- Whether the "+Note" button shows: the reader's switch for the button
--- (Menus & Buttons, Show +Note; on unless turned off) and something to keep.
--- The switch is the button's alone: a selected part of a definition is saved
--- by its own switch or its own row, whatever this one says. Pure.
function DictButtons.showNoteButton(popup, features)
    if features and features.show_note_in_dictionary == false then return false end
    return DictButtons.canKeepDefinition(popup)
end

--- The result a dictionary window shows, as a note's text, and where it came
--- from. Pure: `to_plain` turns an HTML definition into text (KOReader's own
--- helper). The window's own `definition` field is not read: KOReader adds a
--- "(query : word)" line to it under a fuzzy match.
-- @return string|nil the definition
-- @return table|nil { dictionary = its name, headword }
function DictButtons.shownDefinition(popup, to_plain)
    local result = popup and type(popup.results) == "table" and popup.results[popup.dict_index or 1]
    if not result or result.no_result or type(result.definition) ~= "string" then return nil end
    local text = result.definition
    if result.is_html and to_plain then text = to_plain(text) end
    text = text:gsub("^%s+", ""):gsub("%s+$", "")
    if text == "" then return nil end
    return text, { dictionary = result.dict, headword = result.word }
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
