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
local T = require("ffi/util").template
local UIManager = require("ui/uimanager")
local ButtonDialog = require("ui/widget/buttondialog")
local DomainLoader = require("domain_loader")

local BookSettings = {}

-- Per-book DocSettings sidecar keys.
-- AI title/author are tri-state: nil = use the book's real metadata; "" = send empty
-- (suppress entirely); any other string = that custom value.
BookSettings.KEY_AI_TITLE = "koassistant_book_ai_title"
BookSettings.KEY_AI_AUTHOR = "koassistant_book_ai_author"
BookSettings.KEY_SPOILER_FREE = "koassistant_book_spoiler_free"  -- true | false | nil(=follow global)

--- Read the per-book AI title/author overrides (what the AI sees for this book).
-- @return title, author  -- each: nil (use metadata) | "" (send empty) | string (custom)
function BookSettings.getMetadataOverride(doc_settings)
    if not doc_settings then return nil, nil end
    return doc_settings:readSetting(BookSettings.KEY_AI_TITLE),
           doc_settings:readSetting(BookSettings.KEY_AI_AUTHOR)
end

--- Apply the per-book AI title/author override to a book_metadata table.
-- Returns a NEW table when an override exists (never mutates the input, which may
-- be a shared config table); returns the input unchanged when no override is set.
-- A nil override leaves the field as-is; "" sends an empty value; a string replaces it.
-- Affects only what KOAssistant sends to the AI — never KOReader's library metadata.
-- @param metadata table|nil  book_metadata { title, author, author_clause, ... }
-- @param doc_settings table|nil
-- @return table|nil
function BookSettings.applyMetadataOverride(metadata, doc_settings)
    local t, a = BookSettings.getMetadataOverride(doc_settings)
    if t == nil and a == nil then return metadata end
    local m = {}
    if metadata then for k, v in pairs(metadata) do m[k] = v end end
    if t ~= nil then m.title = t end
    if a ~= nil then
        m.author = a
        m.author_clause = (a ~= "") and (" by " .. a) or ""
    end
    return m
end

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
-- @param opts table|nil: { omit_close = bool }  -- caller appends its own rows + Close
-- @return table buttons (ButtonDialog rows)
function BookSettings.buildDomainResearchButtons(state, cb, opts)
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

    if not (opts and opts.omit_close) then
        table.insert(buttons, {{
            text = _("Close"),
            id = "close",
            callback = function() cb.close() end,
        }})
    end

    return buttons
end

-- Look up a domain's display name by id (nil id → nil).
local function domainDisplayName(id, features)
    if not id then return nil end
    for _i, d in ipairs(DomainLoader.getSortedDomains(features.custom_domains or {})) do
        if d.id == id then return d.display_name or d.name or id end
    end
    return id
end

--- Domain & Research quick-picker (scope-aware: For this book / Global toggle).
-- A fast domain/research switch — used by the Quick Settings panel domain chip and the
-- input-dialog domain button. This is NOT the per-book Book Settings screen (see
-- BookSettings.show); it is the place to set the GLOBAL domain/research default.
-- @param opts table:
--   plugin          AskGPT instance (for plugin.settings + updateConfigFromSettings)
--   ui              KOReader UI (to find the open book's live doc_settings)
--   document_path   string|nil  -- explicit target book; nil = the open book
--   on_close        function|nil -- called after the dialog closes (e.g. reopen QS panel)
--   target_override "book" | "global" | nil  -- forces the editing layer (used by the toggle)
function BookSettings.showDomainResearch(opts)
    opts = opts or {}
    local plugin = opts.plugin
    local ui = opts.ui
    local on_close = opts.on_close
    local document_path = opts.document_path

    local doc_settings = resolveDocSettings(ui, document_path)
    local features = plugin and plugin.settings and plugin.settings:readSetting("features") or {}
    local all_domains = DomainLoader.getSortedDomains(features.custom_domains or {})

    local book_domain = doc_settings and doc_settings:readSetting("koassistant_book_domain") or nil
    local book_research = doc_settings and doc_settings:readSetting("koassistant_book_research_mode") or nil

    -- Default to "book" only when the book already has an override, else "global".
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
            BookSettings.showDomainResearch({
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

--- Per-book "Book Settings" — a dedicated per-book configuration screen. Every row is
-- about THIS book (no For-this-book/Global toggle); each setting offers "Follow global"
-- plus per-book overrides. Compact rows that open small sub-pickers, so the screen scales
-- as more per-book settings are added. For the Quick Actions panel, file browser, and the
-- input-dialog button. (Reader/file-browser only — a book must be in scope.)
-- @param opts table: { plugin, ui, document_path, on_close }
function BookSettings.show(opts)
    opts = opts or {}
    local plugin = opts.plugin
    local ui = opts.ui
    local on_close = opts.on_close

    local doc_settings = resolveDocSettings(ui, opts.document_path)
    if not doc_settings then return end  -- per-book screen; nothing to configure without a book

    local features = plugin and plugin.settings and plugin.settings:readSetting("features") or {}

    local dialog
    local function closeDialog()
        if dialog then UIManager:close(dialog); dialog = nil end
    end
    local function reopen()
        closeDialog()
        BookSettings.show(opts)
    end
    local function syncConfig()
        if plugin and plugin.updateConfigFromSettings then plugin:updateConfigFromSettings() end
    end
    local function dot(active) return active and "● " or "○ " end

    -- Sub-picker: this book's domain (Follow global / None / a specific domain)
    local function showDomainSubPicker()
        closeDialog()
        local sorted = DomainLoader.getSortedDomains(features.custom_domains or {})
        local cur = doc_settings:readSetting("koassistant_book_domain")  -- id | "_none" | nil
        local picker
        local function pick(val)
            doc_settings:saveSetting("koassistant_book_domain", val)
            doc_settings:flush()
            syncConfig()
            UIManager:close(picker)
            BookSettings.show(opts)
        end
        local global_name = domainDisplayName(features.selected_domain, features) or _("None")
        local rows = {
            {{ text = dot(cur == nil) .. T(_("Follow global (%1)"), global_name),
                callback = function() pick(nil) end }},
            {{ text = dot(cur == "_none") .. _("None"), callback = function() pick("_none") end }},
        }
        for _i, d in ipairs(sorted) do
            local id = d.id
            table.insert(rows, {{ text = dot(cur == id) .. (d.display_name or d.name or id),
                callback = function() pick(id) end }})
        end
        table.insert(rows, {{ text = _("Cancel"), id = "close",
            callback = function() UIManager:close(picker); BookSettings.show(opts) end }})
        picker = ButtonDialog:new{ title = _("Domain (this book)"), buttons = rows }
        UIManager:show(picker)
    end

    -- Sub-picker for a tri-state per-book boolean (Follow global / On / Off).
    -- Used by Research mode, Spoiler-free, and future on/off per-book settings.
    local function showBoolSubPicker(key, dialog_title, global_on)
        closeDialog()
        local cur = doc_settings:readSetting(key)  -- true | false | nil
        local picker
        local function pick(val)
            doc_settings:saveSetting(key, val)
            doc_settings:flush()
            syncConfig()
            UIManager:close(picker)
            BookSettings.show(opts)
        end
        local rows = {
            {{ text = dot(cur == nil) .. T(_("Follow global (%1)"), global_on and _("On") or _("Off")),
                callback = function() pick(nil) end }},
            {{ text = dot(cur == true) .. _("On"), callback = function() pick(true) end }},
            {{ text = dot(cur == false) .. _("Off"), callback = function() pick(false) end }},
            {{ text = _("Cancel"), id = "close",
                callback = function() UIManager:close(picker); BookSettings.show(opts) end }},
        }
        picker = ButtonDialog:new{ title = dialog_title, buttons = rows }
        UIManager:show(picker)
    end

    -- Custom-value text input for an AI title/author override (stored as-is; "" = send empty,
    -- but that state is normally reached via the "Send empty" sub-picker option).
    local function editOverride(key, dialog_title)
        local InputDialog = require("ui/widget/inputdialog")
        local input
        input = InputDialog:new{
            title = dialog_title,
            input = doc_settings:readSetting(key) or "",
            input_hint = _("What the AI should see for this book"),
            buttons = {{
                { text = _("Cancel"), id = "close", callback = function() UIManager:close(input) end },
                {
                    text = _("Save"),
                    is_enter_default = true,
                    callback = function()
                        doc_settings:saveSetting(key, input:getInputText())
                        doc_settings:flush()
                        syncConfig()
                        UIManager:close(input)
                        reopen()
                    end,
                },
            }},
        }
        UIManager:show(input)
        input:onShowKeyboard()
    end

    -- Sub-picker for a tri-state metadata override: Use real metadata / Custom… / Send empty.
    -- nil = real metadata, "" = send empty (suppressed), string = custom.
    local function showOverrideSubPicker(key, dialog_title, custom_input_title)
        closeDialog()
        local cur = doc_settings:readSetting(key)  -- nil | "" | string
        local picker
        local function setVal(val)
            doc_settings:saveSetting(key, val)
            doc_settings:flush()
            syncConfig()
            UIManager:close(picker)
            BookSettings.show(opts)
        end
        local custom_text = (cur ~= nil and cur ~= "") and T(_("Custom: %1"), cur) or _("Custom…")
        local rows = {
            {{ text = dot(cur == nil) .. _("Use the book's real metadata"),
                callback = function() setVal(nil) end }},
            {{ text = dot(cur ~= nil and cur ~= "") .. custom_text,
                callback = function() UIManager:close(picker); editOverride(key, custom_input_title) end }},
            {{ text = dot(cur == "") .. _("Send empty"),
                callback = function() setVal("") end }},
            {{ text = _("Cancel"), id = "close",
                callback = function() UIManager:close(picker); BookSettings.show(opts) end }},
        }
        picker = ButtonDialog:new{ title = dialog_title, buttons = rows }
        UIManager:show(picker)
    end

    -- Current per-book values → row labels
    local function boolLabel(v)
        if v == true then return _("On")
        elseif v == false then return _("Off")
        else return _("Follow global") end
    end

    local book_domain = doc_settings:readSetting("koassistant_book_domain")
    local domain_label
    if book_domain == "_none" then domain_label = _("None")
    elseif book_domain == nil then domain_label = _("Follow global")
    else domain_label = domainDisplayName(book_domain, features) or book_domain end

    local research_label = boolLabel(doc_settings:readSetting("koassistant_book_research_mode"))
    local spoiler_label = boolLabel(doc_settings:readSetting(BookSettings.KEY_SPOILER_FREE))

    -- AI title/author tri-state label: nil = real metadata, "" = empty/suppressed, string = custom
    local function overrideLabel(v)
        if v == nil then return _("using metadata")
        elseif v == "" then return _("empty") end
        return v
    end
    local title_ov, author_ov = BookSettings.getMetadataOverride(doc_settings)

    local buttons = {
        {{ text = T(_("Domain: %1"), domain_label), callback = showDomainSubPicker }},
        {{ text = T(_("Research mode: %1"), research_label),
            callback = function()
                showBoolSubPicker("koassistant_book_research_mode",
                    _("Research mode (this book)"), features.research_mode == true)
            end }},
        {{ text = T(_("Spoiler-free chat: %1"), spoiler_label),
            callback = function()
                showBoolSubPicker(BookSettings.KEY_SPOILER_FREE,
                    _("Spoiler-free chat (this book)"), features.spoiler_free_chat == true)
            end }},
        {{ text = T(_("AI title: %1"), overrideLabel(title_ov)),
            callback = function()
                showOverrideSubPicker(BookSettings.KEY_AI_TITLE,
                    _("AI title (this book)"), _("Custom AI title"))
            end }},
        {{ text = T(_("AI author: %1"), overrideLabel(author_ov)),
            callback = function()
                showOverrideSubPicker(BookSettings.KEY_AI_AUTHOR,
                    _("AI author (this book)"), _("Custom AI author"))
            end }},
        {{ text = _("Close"), id = "close", callback = function()
            closeDialog()
            if on_close then on_close() end
        end }},
    }

    dialog = ButtonDialog:new{ title = _("Book Settings"), buttons = buttons }
    UIManager:show(dialog)
end

return BookSettings
