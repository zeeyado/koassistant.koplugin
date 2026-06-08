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
local UIManager = require("ui/uimanager")
local ButtonDialog = require("ui/widget/buttondialog")
local DomainLoader = require("domain_loader")

local BookSettings = {}

--- Resolve the DocSettings instance for a per-book target.
-- Prefers the live in-memory instance when the target book is the open one
-- (avoids a stale-read/whole-file-flush clobber); otherwise opens from disk.
-- @return doc_settings|nil
local function resolveDocSettings(ui, document_path)
    if document_path then
        if ui and ui.doc_settings and ui.document and ui.document.file == document_path then
            return ui.doc_settings
        end
        local DocSettings = require("docsettings")
        return DocSettings:open(document_path)
    end
    if ui and ui.document and ui.doc_settings then
        return ui.doc_settings
    end
    return nil
end

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

--- Show the per-book settings dialog (currently the Domain & Research picker).
-- The single entry point used by every surface (Quick Settings popup now; input
-- dialog, Quick Actions panel, and file browser as they are wired). Owns its own
-- dialog handle, persistence, and post-write config re-sync.
--
-- @param opts table:
--   plugin          AskGPT instance (for plugin.settings + updateConfigFromSettings)
--   ui              KOReader UI (to find the open book's live doc_settings)
--   document_path   string|nil  -- explicit target book; nil = the open book
--   on_close        function|nil -- called after the dialog closes (e.g. reopen QS panel)
--   target_override "book" | "global" | nil  -- forces the editing layer (used by the toggle)
function BookSettings.show(opts)
    opts = opts or {}
    local plugin = opts.plugin
    local ui = opts.ui
    local on_close = opts.on_close
    local document_path = opts.document_path

    local doc_settings = resolveDocSettings(ui, document_path)

    local features = plugin and plugin.settings and plugin.settings:readSetting("features") or {}
    local custom_domains = features.custom_domains or {}
    local all_domains = DomainLoader.getSortedDomains(custom_domains)

    local book_domain = doc_settings and doc_settings:readSetting("koassistant_book_domain") or nil
    local book_research = doc_settings and doc_settings:readSetting("koassistant_book_research_mode") or nil

    -- Default to "book" when any per-book override exists, else "global"
    local domain_target = opts.target_override
        or (doc_settings and (book_domain or book_research ~= nil) and "book")
        or "global"

    local dialog

    local function closeDialog()
        if dialog then UIManager:close(dialog); dialog = nil end
    end
    -- After a write: close, re-sync in-memory config from disk, notify caller.
    local function commit()
        closeDialog()
        if plugin and plugin.updateConfigFromSettings then plugin:updateConfigFromSettings() end
        if on_close then on_close() end
    end
    local function setGlobalFeature(key, value)
        local f = plugin.settings:readSetting("features") or {}
        f[key] = value
        plugin.settings:saveSetting("features", f)
        plugin.settings:flush()
    end

    local state = {
        domains = all_domains,
        has_book = doc_settings ~= nil,
        is_book_target = (doc_settings and domain_target == "book") or false,
        book_domain = book_domain,
        global_domain = features.selected_domain,
        book_research = book_research,
        global_research = features.research_mode,
    }

    local cb = {
        set_target = function(new_target)
            closeDialog()
            BookSettings.show({
                plugin = plugin, ui = ui, document_path = document_path,
                on_close = on_close, target_override = new_target,
            })
        end,
        pick_book_domain = function(val)
            doc_settings:saveSetting("koassistant_book_domain", val)
            doc_settings:flush()
            commit()
        end,
        pick_global_domain = function(id)
            setGlobalFeature("selected_domain", id)
            commit()
        end,
        set_book_research = function(val)
            doc_settings:saveSetting("koassistant_book_research_mode", val)
            doc_settings:flush()
            commit()
        end,
        set_global_research = function(val)
            setGlobalFeature("research_mode", val)
            commit()
        end,
        close = function()
            closeDialog()
            if on_close then on_close() end
        end,
    }

    dialog = ButtonDialog:new{
        title = _("Domain & Research"),
        buttons = BookSettings.buildDomainResearchButtons(state, cb),
    }
    UIManager:show(dialog)
end

return BookSettings
