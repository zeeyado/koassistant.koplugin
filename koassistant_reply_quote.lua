--[[
Pure helpers for the chat viewer's "Add to reply" selection-popup action
(koassistant_chatgptviewer.lua). The viewer itself can't be loaded under the
test harness (it pulls in the KOReader UI stack), so the decision/formatting
logic lives here and is covered by tests/unit/test_reply_quote.lua — same
pattern as koassistant_dict_buttons.lua.
]]

local ReplyQuote = {}

--- Append a selection to a reply draft as a markdown quote block.
--- Every selection line gets a "> " prefix; the result ends with a blank
--- line so typing continues below the quote. An existing draft is kept,
--- separated from the new quote by one blank line.
--- @param draft string|nil Existing saved reply draft (may be nil/empty)
--- @param selection string Selected text to quote
--- @return string New draft text
function ReplyQuote.append(draft, selection)
    local sel = (selection or ""):gsub("%s+$", "")
    if sel == "" then
        -- Whitespace-only selection: don't emit a bare "> " marker
        return draft or ""
    end
    local quoted = "> " .. sel:gsub("\n", "\n> ")
    if draft and draft ~= "" then
        return draft:gsub("%s+$", "") .. "\n\n" .. quoted .. "\n\n"
    end
    return quoted .. "\n\n"
end

--- Does this viewer get "Add to reply" in its selection popup?
--- Only the full chat layout has a live Reply seam: artifact (simple_view),
--- translate, and minimal (compact/dictionary) layouts hide the Reply button,
--- and a viewer without onAskQuestion has nowhere to send the reply.
--- KEEP IN SYNC with the viewer's button-layout branch (the
--- minimal_buttons/simple_view/translate_view chain in ChatGPTViewer:init's
--- button assembly) — a new view mode added there needs excluding here too.
--- @param viewer table ChatGPTViewer instance (or any table with the same flags)
--- @return boolean
function ReplyQuote.eligible(viewer)
    if not viewer then return false end
    if viewer.minimal_buttons or viewer.simple_view or viewer.translate_view then
        return false
    end
    return viewer.onAskQuestion ~= nil
end

return ReplyQuote
