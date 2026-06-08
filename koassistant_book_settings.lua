--[[--
Per-book (per-document) settings.

Shared home for settings that can be overridden per book: domain, research mode,
and (incrementally) spoiler-free, book-info inclusion, AI title/author overrides,
and per-action settings (quiz, language). Reachable from the input dialog, the
Quick Settings panel, the Quick Actions panel, and the file browser.

Step 1 extracts the Domain & Research picker that was duplicated between
koassistant_dialogs.lua (input-dialog closure) and main.lua (Quick Settings popup).
The button-building logic lives here once; each caller supplies the current state
and callbacks that perform the actual persistence + UI refresh, so each keeps its
own integration (in-memory config mutation + refreshInputDialog vs
saveSetting/flush + updateConfigFromSettings).
]]

local _ = require("koassistant_gettext")

local BookSettings = {}

--- Build the Domain & Research picker button rows (pure — no I/O).
-- The caller supplies the current state and callbacks; each callback fully
-- performs its write + close/refresh.
--
-- @param state table:
--   domains         array of {id, display_name|name, ...} (already sorted)
--   has_book        bool   -- a book/doc_settings is in scope (show target toggle + book rows)
--   is_book_target  bool   -- currently editing the per-book layer (vs global)
--   book_domain     id | "_none" | nil
--   global_domain   id | nil
--   book_research   true | false | nil
--   global_research bool
-- @param cb table (each fully performs write + close/refresh):
--   set_target(new_target)               "book" | "global"
--   pick_book_domain(id | "_none" | nil)
--   pick_global_domain(id | nil)
--   set_book_research(true | false | nil)
--   set_global_research(true | nil)
--   close()
-- @return table buttons (ButtonDialog rows)
function BookSettings.buildDomainResearchButtons(state, cb)
    local buttons = {}
    local function dot(active) return active and "● " or "○ " end

    -- Target toggle row: [For this book] [Global] — only when a book is in scope
    if state.has_book then
        table.insert(buttons, {
            {
                text = dot(state.is_book_target) .. _("For this book"),
                callback = function()
                    if not state.is_book_target then cb.set_target("book") end
                end,
            },
            {
                text = dot(not state.is_book_target) .. _("Global"),
                callback = function()
                    if state.is_book_target then cb.set_target("global") end
                end,
            },
        })
    end

    if state.is_book_target then
        -- Book target: "Use global" + "None" + each domain
        table.insert(buttons, {{
            text = dot(state.book_domain == nil) .. _("Use global"),
            callback = function() cb.pick_book_domain(nil) end,
        }})
        table.insert(buttons, {{
            text = dot(state.book_domain == "_none") .. _("None"),
            callback = function() cb.pick_book_domain("_none") end,
        }})
        for _idx, domain in ipairs(state.domains) do
            local id = domain.id
            table.insert(buttons, {{
                text = dot(state.book_domain == id) .. (domain.display_name or domain.name or id),
                callback = function() cb.pick_book_domain(id) end,
            }})
        end
    else
        -- Global target (or no book open): "None" + each domain
        table.insert(buttons, {{
            text = dot(state.global_domain == nil) .. _("None"),
            callback = function() cb.pick_global_domain(nil) end,
        }})
        for _idx, domain in ipairs(state.domains) do
            local id = domain.id
            table.insert(buttons, {{
                text = dot(state.global_domain == id) .. (domain.display_name or domain.name or id),
                callback = function() cb.pick_global_domain(id) end,
            }})
        end
    end

    -- Research mode section (shares the same book/global target as domain)
    table.insert(buttons, {{
        text = "─── " .. _("Research Mode") .. " ───",
        enabled = false,
    }})

    if state.is_book_target then
        -- Book target: Use global / On / Off
        table.insert(buttons, {
            {
                text = dot(state.book_research == nil) .. _("Use global"),
                callback = function() cb.set_book_research(nil) end,
            },
            {
                text = dot(state.book_research == true) .. _("On"),
                callback = function() cb.set_book_research(true) end,
            },
            {
                text = dot(state.book_research == false) .. _("Off"),
                callback = function() cb.set_book_research(false) end,
            },
        })
    else
        -- Global target: Off / On
        table.insert(buttons, {
            {
                text = dot(not state.global_research) .. _("Off"),
                callback = function() cb.set_global_research(nil) end,
            },
            {
                text = dot(state.global_research == true) .. _("On"),
                callback = function() cb.set_global_research(true) end,
            },
        })
    end

    table.insert(buttons, {{
        text = _("Close"),
        id = "close",
        callback = function() cb.close() end,
    }})

    return buttons
end

return BookSettings
