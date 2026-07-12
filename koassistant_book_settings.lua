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
local Languages = require("koassistant_languages")

local BookSettings = {}

-- Per-book DocSettings sidecar keys.
-- AI title/author are tri-state: nil = use the book's real metadata; "" = send empty
-- (suppress entirely); any other string = that custom value.
BookSettings.KEY_AI_TITLE = "koassistant_book_ai_title"
BookSettings.KEY_AI_AUTHOR = "koassistant_book_ai_author"
BookSettings.KEY_SPOILER_FREE = "koassistant_book_spoiler_free"  -- true | false | nil(=follow global)
-- Book-info level for the generic [Context] book-info block (freeform Send + include_book_context
-- actions). "none" | "basic" (title+author) | "full" (+position) | nil(=follow global).
BookSettings.KEY_BOOK_INFO = "koassistant_book_info_level"
-- Per-book quiz overrides. Sparse table; each field nil = follow global:
--   enabled (true|false; suppress-only — can't force-on a globally-disabled chapter quiz),
--   count, difficulty, mc, sa, essay, chapter_depth, min_pages, min_minutes.
BookSettings.KEY_QUIZ = "koassistant_book_quiz"

--- Resolve the effective book-info level for a book: per-book override > global default ("basic").
-- @return "none" | "basic" | "full"
function BookSettings.resolveBookInfoLevel(doc_settings, features)
    local per_book = doc_settings and doc_settings:readSetting(BookSettings.KEY_BOOK_INFO)
    if per_book ~= nil then return per_book end
    return (features and features.book_info_in_chat) or "basic"
end

--- Resolve effective spoiler-free state for a book: per-book override (true/false) wins,
-- else follow the global spoiler_free_chat setting. (Session toggle is the caller's concern.)
-- @return boolean
function BookSettings.resolveSpoilerFree(doc_settings, features)
    local per_book = doc_settings and doc_settings:readSetting(BookSettings.KEY_SPOILER_FREE)
    if per_book ~= nil then return per_book == true end
    return (features and features.spoiler_free_chat) == true
end

-- Per-book AI Book Tools posture ("off" | "manual" | "auto" | nil = follow global).
BookSettings.KEY_TOOLS = "koassistant_book_tools"

--- Resolve the effective AI Book Tools posture for a book: per-book override > global
-- tools_posture > "auto" (the schema default — the fallback MUST match it, per the
-- check-pattern rule; existing pre-posture users get an explicit "manual"/"auto" from
-- the migration, so nil only means fresh install or post-reset). Pure. Unknown stored
-- values fall through so a future/corrupt sidecar value can't wedge the checkbox.
-- @return "off" | "manual" | "auto"
function BookSettings.resolveToolsPosture(doc_settings, features)
    local valid = { off = true, manual = true, auto = true }
    local per_book = doc_settings and doc_settings:readSetting(BookSettings.KEY_TOOLS)
    if valid[per_book] then return per_book end
    local global = features and features.tools_posture
    if valid[global] then return global end
    return "auto"
end

--- Translated label for a tools-posture value (shared by the Book Settings row, the
-- posture picker, and the Quick Settings chip).
function BookSettings.toolsPostureLabel(v)
    if v == "off" then return _("Off")
    elseif v == "auto" then return _("Auto") end
    return _("Manual")
end

-- Per-book domain ("<domain id>" | "_none" = explicitly no domain | nil = follow global)
-- and research mode (true | false | nil = follow global). Constants only — resolution
-- stays with the callers (the domain chain layers action > book > global and handles
-- the "_none" sentinel in place).
BookSettings.KEY_DOMAIN = "koassistant_book_domain"
BookSettings.KEY_RESEARCH = "koassistant_book_research_mode"

-- Per-book web-search override (true | false | nil = follow global).
BookSettings.KEY_WEB_SEARCH = "koassistant_book_web_search"

--- Raw per-book web-search override (tri-state). Callers layer this between the
-- per-chat toggle and the global default.
-- @return true | false | nil
function BookSettings.webSearchOverride(doc_settings)
    local v = doc_settings and doc_settings:readSetting(BookSettings.KEY_WEB_SEARCH)
    if v == nil then return nil end
    return v == true
end

--- Resolve effective web-search state for a book: per-book override > global
-- enable_web_search (opt-in, schema default false — check pattern matches). The
-- per-chat toggle is the caller's concern (mirrors resolveSpoilerFree).
-- @return boolean
function BookSettings.resolveWebSearch(doc_settings, features)
    local per_book = BookSettings.webSearchOverride(doc_settings)
    if per_book ~= nil then return per_book end
    return (features and features.enable_web_search) == true
end

-- Per-book surrounding-context overrides (surrounding_context_plan.md §2): a mode
-- string ("none" | "sentence" | "paragraph" | "characters") or nil = follow global.
-- "none" = explicitly off for this book. Sizes (chars/paragraphs) stay global.
-- Two parallel channels: highlight requests (ambient) and dictionary lookups.
BookSettings.KEY_HIGHLIGHT_CONTEXT = "koassistant_book_highlight_context"
BookSettings.KEY_DICTIONARY_CONTEXT = "koassistant_book_dictionary_context"

local VALID_CONTEXT_MODES = { none = true, sentence = true, paragraph = true, characters = true }

--- Resolve the effective ambient surrounding-context mode for highlight requests:
-- per-book override > global highlight_context_mode > "none" (the schema default —
-- ambient is opt-in; matches the check-pattern rule). Pure. Unknown stored values
-- fall through so a corrupt sidecar value can't wedge the feature.
-- @return "none" | "sentence" | "paragraph" | "characters"
function BookSettings.resolveHighlightContext(doc_settings, features)
    local per_book = doc_settings and doc_settings:readSetting(BookSettings.KEY_HIGHLIGHT_CONTEXT)
    if VALID_CONTEXT_MODES[per_book] then return per_book end
    local global = features and features.highlight_context_mode
    if VALID_CONTEXT_MODES[global] then return global end
    return "none"
end

--- Resolve the effective dictionary-context mode (the {context_section} channel):
-- per-book override > global dictionary_context_mode > "none" (matches the schema
-- default). Pure.
-- @return "none" | "sentence" | "paragraph" | "characters"
function BookSettings.resolveDictionaryContext(doc_settings, features)
    local per_book = doc_settings and doc_settings:readSetting(BookSettings.KEY_DICTIONARY_CONTEXT)
    if VALID_CONTEXT_MODES[per_book] then return per_book end
    local global = features and features.dictionary_context_mode
    if VALID_CONTEXT_MODES[global] then return global end
    return "none"
end

--- Translated label for a context-mode value (Book Settings rows + pickers).
function BookSettings.contextModeLabel(v)
    if v == "none" then return _("None")
    elseif v == "sentence" then return _("Sentence")
    elseif v == "paragraph" then return _("Paragraph(s)")
    elseif v == "characters" then return _("Characters") end
    return _("Follow global")
end

--- Resolve effective quiz settings for a book: per-book field > global > built-in default.
-- Pure (no I/O beyond the one sidecar read). The quiz-instruction builder consumes the
-- count/difficulty/mc/sa/essay/chapter_depth fields; the chapter-end trigger consumes
-- enabled (suppress-only), min_pages, and min_minutes. Booleans collapse the global's "nil = on" rule.
-- @return table { count, difficulty, mc, sa, essay, chapter_depth, enabled, min_pages, min_minutes }
function BookSettings.resolveQuiz(doc_settings, features)
    features = features or {}
    local bq = (doc_settings and doc_settings:readSetting(BookSettings.KEY_QUIZ)) or {}
    -- For required fields: book value, else global, else built-in default.
    local function pick(book_val, global_val, default)
        if book_val ~= nil then return book_val end
        if global_val ~= nil then return global_val end
        return default
    end
    return {
        count = pick(bq.count, features.quiz_question_count, 8),
        difficulty = pick(bq.difficulty, features.quiz_difficulty, "medium"),
        mc = pick(bq.mc, features.quiz_mc_enabled, true),
        sa = pick(bq.sa, features.quiz_short_answer_enabled, true),
        essay = pick(bq.essay, features.quiz_essay_enabled, true),
        chapter_depth = pick(bq.chapter_depth, features.quiz_chapter_depth, 2),
        -- Trigger-gate fields: enabled is suppress-only (raw per-book value, no global fallback
        -- here — the global enable gate is checked separately, before this is read);
        -- min_pages / min_minutes fall back to the global thresholds, then the schema defaults
        -- (5 pages / 3 min) — NOT 0 — so the gates are active out of the box (schema defaults
        -- aren't persisted to disk). An explicit 0 still means "no minimum" (0 is truthy in Lua,
        -- so it isn't replaced by the default).
        enabled = bq.enabled,
        min_pages = pick(bq.min_pages, features.quiz_min_chapter_pages, 5),
        min_minutes = pick(bq.min_minutes, features.quiz_min_chapter_time, 3),
    }
end

--- Set one field of the sparse per-book quiz table (nil clears it). Shallow-copies so a shared
-- reference isn't mutated, and drops an emptied table so a reset book carries no override.
-- Shared by the Book Settings quiz screen and the chapter-quiz popup's "Not for this book".
function BookSettings.setQuizField(doc_settings, field, value)
    if not doc_settings then return end
    local new = {}
    for k, v in pairs(doc_settings:readSetting(BookSettings.KEY_QUIZ) or {}) do new[k] = v end
    new[field] = value
    if next(new) == nil then new = nil end
    doc_settings:saveSetting(BookSettings.KEY_QUIZ, new)
    doc_settings:flush()
end

-- Per-book target-language overrides (string language id, or nil/"" = follow global).
BookSettings.KEY_TRANSLATION_LANG = "koassistant_book_translation_language"
BookSettings.KEY_DICTIONARY_LANG = "koassistant_book_dictionary_language"
-- Per-book MAIN AI response language (the "Always respond in X" system-prompt directive that
-- applies to every action — distinct from the translate/dictionary target languages above).
BookSettings.KEY_RESPONSE_LANG = "koassistant_book_response_language"

--- Fold per-book translation/dictionary language overrides into a language-resolver config
-- (the table passed to SystemPrompts.getEffective*Language). Pure: returns the input
-- unchanged when there's no override, else a shallow copy with the fields overridden.
-- A translation override also forces translation_use_primary=false so the resolver actually
-- uses the override instead of the user's primary language.
-- @param config table  the resolver config { translation_language, dictionary_language, ... }
-- @param doc_settings table|nil
-- @return table
function BookSettings.applyLanguageOverride(config, doc_settings)
    if not doc_settings then return config end
    local t = doc_settings:readSetting(BookSettings.KEY_TRANSLATION_LANG)
    local d = doc_settings:readSetting(BookSettings.KEY_DICTIONARY_LANG)
    local has_t = t ~= nil and t ~= ""
    local has_d = d ~= nil and d ~= ""
    if not has_t and not has_d then return config end
    local c = {}
    for k, v in pairs(config) do c[k] = v end
    if has_t then
        c.translation_use_primary = false
        c.translation_language = t
    end
    if has_d then
        c.dictionary_language = d
    end
    return c
end

--- Fold a per-book MAIN response-language override into a buildUnifiedSystem language config
-- ({ interaction_languages, user_languages, primary_language }). Pure: returns the input
-- unchanged when there's no override, else a shallow copy. parseUserLanguages only honours a
-- primary override that's already in the list, so the override language is prepended (deduped)
-- AND set as primary — the user's other languages stay in the "understands" list, preserving
-- the same switch-on-explicit behaviour as the global multi-language setting.
-- @param config table { interaction_languages, user_languages, primary_language }
-- @param doc_settings table|nil
-- @return table
function BookSettings.applyResponseLanguageOverride(config, doc_settings)
    if not doc_settings then return config end
    local lang = doc_settings:readSetting(BookSettings.KEY_RESPONSE_LANG)
    if lang == nil or lang == "" then return config end
    local c = {}
    for k, v in pairs(config) do c[k] = v end
    local list = { lang }
    local existing = config.interaction_languages or config.user_languages
    if type(existing) == "table" then
        for _i, l in ipairs(existing) do
            if l ~= lang and l ~= "" then table.insert(list, l) end
        end
    elseif type(existing) == "string" and existing ~= "" then
        for l in existing:gmatch("([^,]+)") do
            local trimmed = l:match("^%s*(.-)%s*$")
            if trimmed ~= "" and trimmed ~= lang then table.insert(list, trimmed) end
        end
    end
    c.interaction_languages = list
    c.primary_language = lang
    return c
end

-- Every DocSettings sidecar key this module owns. Single source of truth for the
-- "reset book settings" action, the customized-count indicator, and (later) Track 33's
-- storage registry. Keep in sync when adding a per-book setting.
BookSettings.SIDECAR_KEYS = {
    BookSettings.KEY_DOMAIN,
    BookSettings.KEY_RESEARCH,
    BookSettings.KEY_SPOILER_FREE,
    BookSettings.KEY_BOOK_INFO,
    BookSettings.KEY_AI_TITLE,
    BookSettings.KEY_AI_AUTHOR,
    BookSettings.KEY_QUIZ,
    BookSettings.KEY_TRANSLATION_LANG,
    BookSettings.KEY_DICTIONARY_LANG,
    BookSettings.KEY_RESPONSE_LANG,
    BookSettings.KEY_TOOLS,
    BookSettings.KEY_WEB_SEARCH,
    BookSettings.KEY_HIGHLIGHT_CONTEXT,
    BookSettings.KEY_DICTIONARY_CONTEXT,
}

--- Count how many per-book settings deviate from the global defaults (any non-nil key).
-- @return number
function BookSettings.countCustomized(doc_settings)
    if not doc_settings then return 0 end
    local n = 0
    for _i, key in ipairs(BookSettings.SIDECAR_KEYS) do
        if doc_settings:readSetting(key) ~= nil then n = n + 1 end
    end
    return n
end

--- Clear every per-book override so this book follows the global defaults again.
function BookSettings.resetBook(doc_settings)
    if not doc_settings then return end
    for _i, key in ipairs(BookSettings.SIDECAR_KEYS) do
        doc_settings:saveSetting(key, nil)
    end
    doc_settings:flush()
end

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
-- Delegates to SafeDocSettings: always the live in-memory instance when the
-- target book is the open one (avoids a stale-read/whole-file-flush clobber,
-- issue #72); a fresh disk instance only when the book is not open.
-- @return doc_settings|nil
local function resolveDocSettings(ui, document_path)
    return (require("koassistant_doc_settings").resolve(document_path, ui))
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

    local book_domain = doc_settings and doc_settings:readSetting(BookSettings.KEY_DOMAIN) or nil
    local book_research = doc_settings and doc_settings:readSetting(BookSettings.KEY_RESEARCH) or nil

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
            doc_settings:saveSetting(BookSettings.KEY_DOMAIN, val)
            doc_settings:flush()
            commit()
        end,
        pick_global_domain = function(id)
            setGlobalFeature("selected_domain", id)
            commit()
        end,
        set_book_research = function(val)
            doc_settings:saveSetting(BookSettings.KEY_RESEARCH, val)
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

--- Quick AI Book Tools posture picker with a For-this-book ↔ Global target toggle
-- (tools_ux_plan.md §3) — mirrors the Domain & Research picker. Shared entry point for
-- the Quick Settings chip; the Book Settings screen has its own per-book-only row.
-- Book target: Follow global / Off / Manual / Auto (KEY_TOOLS sidecar key).
-- Global target: Off / Manual / Auto (features.tools_posture).
-- @param opts table: { plugin, ui, document_path, on_close, target_override }
function BookSettings.showToolsPosture(opts)
    opts = opts or {}
    local plugin = opts.plugin
    local ui = opts.ui
    local on_close = opts.on_close
    local document_path = opts.document_path

    local doc_settings = resolveDocSettings(ui, document_path)
    local features = plugin and plugin.settings and plugin.settings:readSetting("features") or {}
    local book_val = doc_settings and doc_settings:readSetting(BookSettings.KEY_TOOLS) or nil
    local global_val = features.tools_posture or "manual"

    -- Default to "book" only when the book already has an override, else "global".
    local target = opts.target_override
        or (doc_settings and book_val ~= nil and "book")
        or "global"
    local is_book_target = doc_settings ~= nil and target == "book"

    local dialog
    local function closeDialog()
        if dialog then UIManager:close(dialog); dialog = nil end
    end
    local function commit()
        closeDialog()
        if plugin and plugin.updateConfigFromSettings then plugin:updateConfigFromSettings() end
        if on_close then on_close() end
    end
    local function pickBook(val)
        doc_settings:saveSetting(BookSettings.KEY_TOOLS, val)
        doc_settings:flush()
        commit()
    end
    local function pickGlobal(val)
        local f = plugin.settings:readSetting("features") or {}
        f.tools_posture = val
        plugin.settings:saveSetting("features", f)
        plugin.settings:flush()
        commit()
    end
    local function setTarget(new_target)
        closeDialog()
        BookSettings.showToolsPosture({
            plugin = plugin, ui = ui, document_path = document_path,
            on_close = on_close, target_override = new_target,
        })
    end
    local function dot(active) return active and "● " or "○ " end

    local buttons = {}
    -- Target toggle row: [For this book] [Global] — only when a book is in scope
    if doc_settings then
        table.insert(buttons, {
            {
                text = dot(is_book_target) .. _("For this book"),
                callback = function()
                    if not is_book_target then setTarget("book") end
                end,
            },
            {
                text = dot(not is_book_target) .. _("Global"),
                callback = function()
                    if is_book_target then setTarget("global") end
                end,
            },
        })
    end

    local postures = {
        { value = "off", label = _("Off (no tool use at all)") },
        { value = "manual", label = _("Manual (Tools chip starts OFF)") },
        { value = "auto", label = _("Auto (Tools chip starts ON)") },
    }
    if is_book_target then
        table.insert(buttons, {{
            text = dot(book_val == nil) .. T(_("Follow global (%1)"), BookSettings.toolsPostureLabel(global_val)),
            callback = function() pickBook(nil) end,
        }})
        for _idx, p in ipairs(postures) do
            table.insert(buttons, {{
                text = dot(book_val == p.value) .. p.label,
                callback = function() pickBook(p.value) end,
            }})
        end
    else
        for _idx, p in ipairs(postures) do
            table.insert(buttons, {{
                text = dot(global_val == p.value) .. p.label,
                callback = function() pickGlobal(p.value) end,
            }})
        end
    end
    table.insert(buttons, {{
        text = _("Close"), id = "close",
        callback = function()
            closeDialog()
            if on_close then on_close() end
        end,
    }})

    dialog = ButtonDialog:new{ title = _("AI Book Tools"), buttons = buttons }
    UIManager:show(dialog)
end

--- Quick web-search picker with a For-this-book ↔ Global target toggle — mirrors the
-- AI Book Tools picker. Shared entry point for the Quick Settings chip; the Book
-- Settings screen has its own per-book-only row. Book target: Follow global / On / Off
-- (KEY_WEB_SEARCH sidecar key). Global target: On / Off (features.enable_web_search).
-- @param opts table: { plugin, ui, document_path, on_close, target_override }
function BookSettings.showWebSearch(opts)
    opts = opts or {}
    local plugin = opts.plugin
    local ui = opts.ui
    local on_close = opts.on_close
    local document_path = opts.document_path

    local doc_settings = resolveDocSettings(ui, document_path)
    local features = plugin and plugin.settings and plugin.settings:readSetting("features") or {}
    local book_val = doc_settings and doc_settings:readSetting(BookSettings.KEY_WEB_SEARCH)
    local global_on = features.enable_web_search == true

    -- Default to "book" only when the book already has an override, else "global".
    local target = opts.target_override
        or (doc_settings and book_val ~= nil and "book")
        or "global"
    local is_book_target = doc_settings ~= nil and target == "book"

    local dialog
    local function closeDialog()
        if dialog then UIManager:close(dialog); dialog = nil end
    end
    local function commit()
        closeDialog()
        if plugin and plugin.updateConfigFromSettings then plugin:updateConfigFromSettings() end
        if on_close then on_close() end
    end
    local function pickBook(val)
        doc_settings:saveSetting(BookSettings.KEY_WEB_SEARCH, val)
        doc_settings:flush()
        commit()
    end
    local function pickGlobal(val)
        local f = plugin.settings:readSetting("features") or {}
        f.enable_web_search = val
        plugin.settings:saveSetting("features", f)
        plugin.settings:flush()
        commit()
    end
    local function setTarget(new_target)
        closeDialog()
        BookSettings.showWebSearch({
            plugin = plugin, ui = ui, document_path = document_path,
            on_close = on_close, target_override = new_target,
        })
    end
    local function dot(active) return active and "● " or "○ " end

    local buttons = {}
    -- Target toggle row: [For this book] [Global] — only when a book is in scope
    if doc_settings then
        table.insert(buttons, {
            {
                text = dot(is_book_target) .. _("For this book"),
                callback = function()
                    if not is_book_target then setTarget("book") end
                end,
            },
            {
                text = dot(not is_book_target) .. _("Global"),
                callback = function()
                    if is_book_target then setTarget("global") end
                end,
            },
        })
    end

    if is_book_target then
        table.insert(buttons, {{
            text = dot(book_val == nil) .. T(_("Follow global (%1)"), global_on and _("On") or _("Off")),
            callback = function() pickBook(nil) end,
        }})
        table.insert(buttons, {{
            text = dot(book_val == true) .. _("On"),
            callback = function() pickBook(true) end,
        }})
        table.insert(buttons, {{
            text = dot(book_val == false) .. _("Off"),
            callback = function() pickBook(false) end,
        }})
    else
        table.insert(buttons, {{
            text = dot(global_on) .. _("On"),
            callback = function() pickGlobal(true) end,
        }})
        table.insert(buttons, {{
            text = dot(not global_on) .. _("Off"),
            callback = function() pickGlobal(false) end,
        }})
    end
    table.insert(buttons, {{
        text = _("Close"), id = "close",
        callback = function()
            closeDialog()
            if on_close then on_close() end
        end,
    }})

    dialog = ButtonDialog:new{ title = _("Web Search"), buttons = buttons }
    UIManager:show(dialog)
end

--- Quick spoiler-free picker with a For-this-book ↔ Global target toggle — the hold
-- target of the input dialog's Spoiler chip (same shape as showWebSearch). Book target:
-- Follow global / On / Off (KEY_SPOILER_FREE). Global target: On / Off
-- (features.spoiler_free_chat).
-- @param opts table: { plugin, ui, document_path, on_close, target_override }
function BookSettings.showSpoilerFree(opts)
    opts = opts or {}
    local plugin = opts.plugin
    local ui = opts.ui
    local on_close = opts.on_close
    local document_path = opts.document_path

    local doc_settings = resolveDocSettings(ui, document_path)
    local features = plugin and plugin.settings and plugin.settings:readSetting("features") or {}
    local book_val = doc_settings and doc_settings:readSetting(BookSettings.KEY_SPOILER_FREE)
    local global_on = features.spoiler_free_chat == true

    -- Default to "book" only when the book already has an override, else "global".
    local target = opts.target_override
        or (doc_settings and book_val ~= nil and "book")
        or "global"
    local is_book_target = doc_settings ~= nil and target == "book"

    local dialog
    local function closeDialog()
        if dialog then UIManager:close(dialog); dialog = nil end
    end
    local function commit()
        closeDialog()
        if plugin and plugin.updateConfigFromSettings then plugin:updateConfigFromSettings() end
        if on_close then on_close() end
    end
    local function pickBook(val)
        doc_settings:saveSetting(BookSettings.KEY_SPOILER_FREE, val)
        doc_settings:flush()
        commit()
    end
    local function pickGlobal(val)
        local f = plugin.settings:readSetting("features") or {}
        f.spoiler_free_chat = val
        plugin.settings:saveSetting("features", f)
        plugin.settings:flush()
        commit()
    end
    local function setTarget(new_target)
        closeDialog()
        BookSettings.showSpoilerFree({
            plugin = plugin, ui = ui, document_path = document_path,
            on_close = on_close, target_override = new_target,
        })
    end
    local function dot(active) return active and "● " or "○ " end

    local buttons = {}
    -- Target toggle row: [For this book] [Global] — only when a book is in scope
    if doc_settings then
        table.insert(buttons, {
            {
                text = dot(is_book_target) .. _("For this book"),
                callback = function()
                    if not is_book_target then setTarget("book") end
                end,
            },
            {
                text = dot(not is_book_target) .. _("Global"),
                callback = function()
                    if is_book_target then setTarget("global") end
                end,
            },
        })
    end

    if is_book_target then
        table.insert(buttons, {{
            text = dot(book_val == nil) .. T(_("Follow global (%1)"), global_on and _("On") or _("Off")),
            callback = function() pickBook(nil) end,
        }})
        table.insert(buttons, {{
            text = dot(book_val == true) .. _("On"),
            callback = function() pickBook(true) end,
        }})
        table.insert(buttons, {{
            text = dot(book_val == false) .. _("Off"),
            callback = function() pickBook(false) end,
        }})
    else
        table.insert(buttons, {{
            text = dot(global_on) .. _("On"),
            callback = function() pickGlobal(true) end,
        }})
        table.insert(buttons, {{
            text = dot(not global_on) .. _("Off"),
            callback = function() pickGlobal(false) end,
        }})
    end
    table.insert(buttons, {{
        text = _("Close"), id = "close",
        callback = function()
            closeDialog()
            if on_close then on_close() end
        end,
    }})

    dialog = ButtonDialog:new{ title = _("Spoiler-Free Chat"), buttons = buttons }
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
        local cur = doc_settings:readSetting(BookSettings.KEY_DOMAIN)  -- id | "_none" | nil
        local picker
        local function pick(val)
            doc_settings:saveSetting(BookSettings.KEY_DOMAIN, val)
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

    -- Book-info level: label + sub-picker (None / Title & author / +position)
    local function bookInfoLabel(v)
        if v == "none" then return _("None")
        elseif v == "title" then return _("Title only")
        elseif v == "full" then return _("Title, author & position")
        elseif v == "basic" then return _("Title & author") end
        return _("Follow global")
    end
    local function showBookInfoSubPicker()
        closeDialog()
        local cur = doc_settings:readSetting(BookSettings.KEY_BOOK_INFO)  -- nil | "none" | "basic" | "full"
        local picker
        local function setVal(val)
            doc_settings:saveSetting(BookSettings.KEY_BOOK_INFO, val)
            doc_settings:flush()
            syncConfig()
            UIManager:close(picker)
            BookSettings.show(opts)
        end
        local rows = {
            {{ text = dot(cur == nil) .. T(_("Follow global (%1)"), bookInfoLabel(features.book_info_in_chat or "basic")),
                callback = function() setVal(nil) end }},
            {{ text = dot(cur == "none") .. _("None"), callback = function() setVal("none") end }},
            {{ text = dot(cur == "title") .. _("Title only"), callback = function() setVal("title") end }},
            {{ text = dot(cur == "basic") .. _("Title & author"), callback = function() setVal("basic") end }},
            {{ text = dot(cur == "full") .. _("Title, author & position"), callback = function() setVal("full") end }},
            {{ text = _("Cancel"), id = "close",
                callback = function() UIManager:close(picker); BookSettings.show(opts) end }},
        }
        picker = ButtonDialog:new{ title = _("Book info in chat (this book)"), buttons = rows }
        UIManager:show(picker)
    end

    -- Surrounding-context mode: shared sub-picker for the highlight/dictionary channels
    -- (Follow global / None / Sentence / Paragraph(s) / Characters)
    local function showContextModeSubPicker(key, dialog_title, global_mode)
        closeDialog()
        local cur = doc_settings:readSetting(key)  -- nil | "none" | "sentence" | "paragraph" | "characters"
        local picker
        local function setVal(val)
            doc_settings:saveSetting(key, val)
            doc_settings:flush()
            syncConfig()
            UIManager:close(picker)
            BookSettings.show(opts)
        end
        local rows = {
            {{ text = dot(cur == nil) .. T(_("Follow global (%1)"), BookSettings.contextModeLabel(global_mode)),
                callback = function() setVal(nil) end }},
            {{ text = dot(cur == "none") .. _("None"), callback = function() setVal("none") end }},
            {{ text = dot(cur == "sentence") .. _("Sentence"), callback = function() setVal("sentence") end }},
            {{ text = dot(cur == "paragraph") .. _("Paragraph(s)"), callback = function() setVal("paragraph") end }},
            {{ text = dot(cur == "characters") .. _("Characters"), callback = function() setVal("characters") end }},
            {{ text = _("Cancel"), id = "close",
                callback = function() UIManager:close(picker); BookSettings.show(opts) end }},
        }
        picker = ButtonDialog:new{ title = dialog_title, buttons = rows }
        UIManager:show(picker)
    end
    local function contextRowLabel(v)
        if v == nil then return _("Follow global") end
        return BookSettings.contextModeLabel(v)
    end

    -- AI Book Tools posture: label + sub-picker (Follow global / Off / Manual / Auto)
    local function toolsRowLabel(v)
        if v == nil then return _("Follow global") end
        return BookSettings.toolsPostureLabel(v)
    end
    local function showToolsSubPicker()
        closeDialog()
        local cur = doc_settings:readSetting(BookSettings.KEY_TOOLS)  -- nil | "off" | "manual" | "auto"
        local picker
        local function setVal(val)
            doc_settings:saveSetting(BookSettings.KEY_TOOLS, val)
            doc_settings:flush()
            syncConfig()
            UIManager:close(picker)
            BookSettings.show(opts)
        end
        local global_label = BookSettings.toolsPostureLabel(features.tools_posture or "manual")
        local rows = {
            {{ text = dot(cur == nil) .. T(_("Follow global (%1)"), global_label),
                callback = function() setVal(nil) end }},
            {{ text = dot(cur == "off") .. _("Off (no tool use at all)"),
                callback = function() setVal("off") end }},
            {{ text = dot(cur == "manual") .. _("Manual (Tools chip starts OFF)"),
                callback = function() setVal("manual") end }},
            {{ text = dot(cur == "auto") .. _("Auto (Tools chip starts ON)"),
                callback = function() setVal("auto") end }},
            {{ text = _("Cancel"), id = "close",
                callback = function() UIManager:close(picker); BookSettings.show(opts) end }},
        }
        picker = ButtonDialog:new{ title = _("AI Book Tools (this book)"), buttons = rows }
        UIManager:show(picker)
    end

    local book_domain = doc_settings:readSetting(BookSettings.KEY_DOMAIN)
    local domain_label
    if book_domain == "_none" then domain_label = _("None")
    elseif book_domain == nil then domain_label = _("Follow global")
    else domain_label = domainDisplayName(book_domain, features) or book_domain end

    local research_label = boolLabel(doc_settings:readSetting(BookSettings.KEY_RESEARCH))
    local spoiler_label = boolLabel(doc_settings:readSetting(BookSettings.KEY_SPOILER_FREE))

    -- AI title/author tri-state label: nil = real metadata, "" = empty/suppressed, string = custom
    local function overrideLabel(v)
        if v == nil then return _("using metadata")
        elseif v == "" then return _("empty") end
        return v
    end
    local title_ov, author_ov = BookSettings.getMetadataOverride(doc_settings)

    -- Grouped sections (book_scoped_controls_plan.md §7): disabled rows as headers.
    -- Order mirrors the input dialog's chips row where the controls overlap.
    local function header(text)
        return {{ text = "—  " .. text .. "  —", enabled = false }}
    end
    local buttons = {
        header(_("AI behavior")),
        {{ text = T(_("Domain: %1"), domain_label), callback = showDomainSubPicker }},
        {{ text = T(_("Research mode: %1"), research_label),
            callback = function()
                showBoolSubPicker(BookSettings.KEY_RESEARCH,
                    _("Research mode (this book)"), features.research_mode == true)
            end }},
        {{ text = T(_("Spoiler-free chat: %1"), spoiler_label),
            callback = function()
                showBoolSubPicker(BookSettings.KEY_SPOILER_FREE,
                    _("Spoiler-free chat (this book)"), features.spoiler_free_chat == true)
            end }},
        {{ text = T(_("AI Book Tools: %1"), toolsRowLabel(doc_settings:readSetting(BookSettings.KEY_TOOLS))),
            callback = showToolsSubPicker }},
        {{ text = T(_("Web search: %1"), boolLabel(doc_settings:readSetting(BookSettings.KEY_WEB_SEARCH))),
            callback = function()
                showBoolSubPicker(BookSettings.KEY_WEB_SEARCH,
                    _("Web search (this book)"), features.enable_web_search == true)
            end }},
        {{ text = T(_("Book info: %1"), bookInfoLabel(doc_settings:readSetting(BookSettings.KEY_BOOK_INFO))),
            callback = showBookInfoSubPicker }},
        {{ text = T(_("Highlight context: %1"), contextRowLabel(doc_settings:readSetting(BookSettings.KEY_HIGHLIGHT_CONTEXT))),
            callback = function()
                showContextModeSubPicker(BookSettings.KEY_HIGHLIGHT_CONTEXT,
                    _("Highlight context (this book)"), features.highlight_context_mode or "none")
            end }},
        {{ text = T(_("Dictionary context: %1"), contextRowLabel(doc_settings:readSetting(BookSettings.KEY_DICTIONARY_CONTEXT))),
            callback = function()
                showContextModeSubPicker(BookSettings.KEY_DICTIONARY_CONTEXT,
                    _("Dictionary context (this book)"), features.dictionary_context_mode or "none")
            end }},
        header(_("Identity")),
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
        header(_("More")),
        {{ text = _("Quiz settings ▸"), callback = function()
            closeDialog()
            BookSettings.showQuizConfig({
                plugin = plugin, ui = ui, document_path = opts.document_path,
                on_close = function() BookSettings.show(opts) end,
            })
        end }},
        {{ text = _("Languages ▸"), callback = function()
            closeDialog()
            BookSettings.showLanguageConfig({
                plugin = plugin, ui = ui, document_path = opts.document_path,
                on_close = function() BookSettings.show(opts) end,
            })
        end }},
        {{ text = _("Close"), id = "close", callback = function()
            closeDialog()
            if on_close then on_close() end
        end }},
    }

    -- Surface customizations: count deviations from global, offer a one-tap reset.
    -- Without this, sticky per-book overrides are easy to forget (and then global changes
    -- appear not to take effect for this book).
    local n_custom = BookSettings.countCustomized(doc_settings)
    if n_custom > 0 then
        table.insert(buttons, #buttons, {{ text = _("Reset book settings"), callback = function()
            local ConfirmBox = require("ui/widget/confirmbox")
            UIManager:show(ConfirmBox:new{
                text = _("Reset all KOAssistant settings for this book to follow the global defaults?"),
                ok_text = _("Reset"),
                ok_callback = function()
                    BookSettings.resetBook(doc_settings)
                    syncConfig()
                    reopen()
                end,
            })
        end }})
    end

    local title = (n_custom > 0) and T(_("Book Settings (%1 customized)"), n_custom) or _("Book Settings")
    dialog = ButtonDialog:new{ title = title, buttons = buttons }
    UIManager:show(dialog)
end

-- Human labels for the quiz "Follow global (X)" rows.
local function quizDifficultyLabel(v)
    if v == "easy" then return _("Easy")
    elseif v == "hard" then return _("Hard") end
    return _("Medium")
end
local function quizLevelLabel(v)
    if v == "auto" then return _("Auto-detect")
    elseif v == 1 then return _("Top level (Level 1)")
    elseif v == 2 then return _("Level 2")
    elseif v == 3 then return _("Level 3")
    elseif v == "toc_filter" or v == "all" then return _("All TOC headings") end
    return _("Level 2")
end

--- Per-book QUIZ overrides — a sub-screen of Book Settings. Each row shows the per-book
-- value (or "Follow global (X)") and opens a small picker; "Follow global" clears that
-- field from the sparse KEY_QUIZ table. `enabled` is suppress-only (it can only turn the
-- chapter-end auto-quiz OFF for this book, never force it on past the global gate).
-- @param opts table: { plugin, ui, document_path, on_close }
function BookSettings.showQuizConfig(opts)
    opts = opts or {}
    local plugin = opts.plugin
    local ui = opts.ui
    local on_close = opts.on_close

    local doc_settings = resolveDocSettings(ui, opts.document_path)
    if not doc_settings then return end

    local features = plugin and plugin.settings and plugin.settings:readSetting("features") or {}

    local dialog
    local function closeDialog()
        if dialog then UIManager:close(dialog); dialog = nil end
    end
    local function reopen()
        closeDialog()
        BookSettings.showQuizConfig(opts)
    end
    local function dot(active) return active and "● " or "○ " end

    -- Fresh read of the sparse per-book quiz table.
    local function bq() return doc_settings:readSetting(BookSettings.KEY_QUIZ) or {} end
    -- Set one field (nil clears it → follow global), then re-sync in-memory config.
    local function setField(field, value)
        BookSettings.setQuizField(doc_settings, field, value)
        if plugin and plugin.updateConfigFromSettings then plugin:updateConfigFromSettings() end
    end

    -- Tri-state picker (Follow global / On / Off) for a boolean field.
    local function showTriState(field, dialog_title, global_on)
        closeDialog()
        local cur = bq()[field]
        local picker
        local function setVal(v)
            UIManager:close(picker)
            setField(field, v)
            BookSettings.showQuizConfig(opts)
        end
        picker = ButtonDialog:new{ title = dialog_title, buttons = {
            {{ text = dot(cur == nil) .. T(_("Follow global (%1)"), global_on and _("On") or _("Off")),
                callback = function() setVal(nil) end }},
            {{ text = dot(cur == true) .. _("On"), callback = function() setVal(true) end }},
            {{ text = dot(cur == false) .. _("Off"), callback = function() setVal(false) end }},
            {{ text = _("Cancel"), id = "close",
                callback = function() UIManager:close(picker); BookSettings.showQuizConfig(opts) end }},
        } }
        UIManager:show(picker)
    end

    -- Option-list picker: "Follow global (X)" + each { value, label }.
    local function showOptions(field, dialog_title, global_label, options)
        closeDialog()
        local cur = bq()[field]
        local picker
        local function setVal(v)
            UIManager:close(picker)
            setField(field, v)
            BookSettings.showQuizConfig(opts)
        end
        local rows = {
            {{ text = dot(cur == nil) .. T(_("Follow global (%1)"), global_label),
                callback = function() setVal(nil) end }},
        }
        for _i, opt in ipairs(options) do
            local v = opt.value
            table.insert(rows, {{ text = dot(cur == v) .. opt.label, callback = function() setVal(v) end }})
        end
        table.insert(rows, {{ text = _("Cancel"), id = "close",
            callback = function() UIManager:close(picker); BookSettings.showQuizConfig(opts) end }})
        picker = ButtonDialog:new{ title = dialog_title, buttons = rows }
        UIManager:show(picker)
    end

    -- Numeric spinner with a "Follow global" escape (clears the field on the extra button).
    local function showSpinner(field, dialog_title, vmin, vmax, default_val)
        closeDialog()
        local SpinWidget = require("ui/widget/spinwidget")
        UIManager:show(SpinWidget:new{
            title_text = dialog_title,
            value = bq()[field] or default_val,
            value_min = vmin,
            value_max = vmax,
            value_step = 1,
            ok_always_enabled = true,
            extra_text = _("Follow global"),
            extra_callback = function() setField(field, nil); reopen() end,
            callback = function(spin) setField(field, spin.value); reopen() end,
            cancel_callback = function() reopen() end,
        })
    end

    local cur = bq()
    local function triLabel(v)
        if v == true then return _("On")
        elseif v == false then return _("Off") end
        return _("Follow global")
    end
    local function numLabel(v) return (v == nil) and _("Follow global") or tostring(v) end
    local function minPagesLabel(v)
        if v == nil then return _("Follow global")
        elseif v == 0 then return _("No minimum") end
        return T(_("%1 pages"), v)
    end
    local function minTimeLabel(v)
        if v == nil then return _("Follow global")
        elseif v == 0 then return _("No minimum") end
        return T(_("%1 min"), v)
    end

    -- `enabled` is suppress-only (the global gate runs before the per-book read in the
    -- page-turn hot path), so it's an honest two-state: Follow global / Off-for-this-book.
    -- It can silence the chapter-end auto-quiz for one book, never force it on past a
    -- globally-disabled quiz.
    local function enabledLabel(v)
        if v == false then return _("Off (this book)") end
        return _("Follow global")
    end

    local buttons = {
        {{ text = T(_("Chapter-end quiz: %1"), enabledLabel(cur.enabled)),
            callback = function()
                showOptions("enabled", _("Chapter-end quiz (this book)"),
                    features.enable_chapter_quiz == true and _("On") or _("Off"),
                    { { value = false, label = _("Off — never quiz this book") } })
            end }},
        {{ text = T(_("Question count: %1"), numLabel(cur.count)),
            callback = function()
                showSpinner("count", _("Question count (this book)"), 3, 15,
                    features.quiz_question_count or 8)
            end }},
        {{ text = T(_("Difficulty: %1"), (cur.difficulty == nil) and _("Follow global") or quizDifficultyLabel(cur.difficulty)),
            callback = function()
                showOptions("difficulty", _("Difficulty (this book)"),
                    quizDifficultyLabel(features.quiz_difficulty or "medium"), {
                        { value = "easy", label = _("Easy") },
                        { value = "medium", label = _("Medium") },
                        { value = "hard", label = _("Hard") },
                    })
            end }},
        {{ text = T(_("Multiple choice: %1"), triLabel(cur.mc)),
            callback = function()
                showTriState("mc", _("Multiple choice (this book)"), features.quiz_mc_enabled ~= false)
            end }},
        {{ text = T(_("Short answer: %1"), triLabel(cur.sa)),
            callback = function()
                showTriState("sa", _("Short answer (this book)"), features.quiz_short_answer_enabled ~= false)
            end }},
        {{ text = T(_("Discussion: %1"), triLabel(cur.essay)),
            callback = function()
                showTriState("essay", _("Discussion (this book)"), features.quiz_essay_enabled ~= false)
            end }},
        {{ text = T(_("Chapter level: %1"), (cur.chapter_depth == nil) and _("Follow global") or quizLevelLabel(cur.chapter_depth)),
            callback = function()
                showOptions("chapter_depth", _("Quiz chapter level (this book)"),
                    quizLevelLabel(features.quiz_chapter_depth or 2), {
                        { value = "auto", label = _("Auto-detect") },
                        { value = 1, label = _("Top level (Level 1)") },
                        { value = 2, label = _("Level 2") },
                        { value = 3, label = _("Level 3") },
                        { value = "toc_filter", label = _("All TOC headings") },
                    })
            end }},
        {{ text = T(_("Min chapter length: %1"), minPagesLabel(cur.min_pages)),
            callback = function()
                showSpinner("min_pages", _("Min chapter length, pages (this book)"), 0, 30,
                    features.quiz_min_chapter_pages or 5)
            end }},
        {{ text = T(_("Min reading time: %1"), minTimeLabel(cur.min_minutes)),
            callback = function()
                showSpinner("min_minutes", _("Min reading time, minutes (this book)"), 0, 60,
                    features.quiz_min_chapter_time or 3)
            end }},
        {{ text = _("Close"), id = "close", callback = function()
            closeDialog()
            if on_close then on_close() end
        end }},
    }

    dialog = ButtonDialog:new{ title = _("Quiz settings (this book)"), buttons = buttons }
    UIManager:show(dialog)
end

--- Per-book TRANSLATION / DICTIONARY target-language overrides — a sub-screen of Book
-- Settings. Each row shows the per-book value (or "Follow global (X)") and opens a language
-- picker (Follow global / a language from the list / Custom… / Cancel). Stored values are
-- language ids (same as the global pickers), so the request pipeline treats them identically.
-- @param opts table: { plugin, ui, document_path, on_close }
function BookSettings.showLanguageConfig(opts)
    opts = opts or {}
    local plugin = opts.plugin
    local ui = opts.ui
    local on_close = opts.on_close

    local doc_settings = resolveDocSettings(ui, opts.document_path)
    if not doc_settings then return end

    local features = plugin and plugin.settings and plugin.settings:readSetting("features") or {}

    local dialog
    local function closeDialog()
        if dialog then UIManager:close(dialog); dialog = nil end
    end
    local function syncConfig()
        if plugin and plugin.updateConfigFromSettings then plugin:updateConfigFromSettings() end
    end
    local function dot(active) return active and "● " or "○ " end

    -- Free-text custom language (matches the global picker's "Custom language…" input).
    local function editCustom(key, dialog_title)
        local InputDialog = require("ui/widget/inputdialog")
        local input
        input = InputDialog:new{
            title = dialog_title,
            input = doc_settings:readSetting(key) or "",
            input_hint = _("Language name (e.g. Spanish)"),
            buttons = {{
                { text = _("Cancel"), id = "close", callback = function() UIManager:close(input) end },
                {
                    text = _("Save"),
                    is_enter_default = true,
                    callback = function()
                        local v = input:getInputText()
                        doc_settings:saveSetting(key, (v ~= "" and v) or nil)
                        doc_settings:flush()
                        syncConfig()
                        UIManager:close(input)
                        BookSettings.showLanguageConfig(opts)
                    end,
                },
            }},
        }
        UIManager:show(input)
        input:onShowKeyboard()
    end

    -- Language picker for one key: Follow global / each language / Custom… / Cancel.
    local function showLangPicker(key, dialog_title, global_display)
        closeDialog()
        local cur = doc_settings:readSetting(key)
        local picker
        local function setVal(v)
            doc_settings:saveSetting(key, v)
            doc_settings:flush()
            syncConfig()
            UIManager:close(picker)
            BookSettings.showLanguageConfig(opts)
        end
        local rows = {
            {{ text = dot(cur == nil or cur == "") .. T(_("Follow global (%1)"), global_display),
                callback = function() setVal(nil) end }},
        }
        for _i, id in ipairs(Languages.getAllIds()) do
            table.insert(rows, {{ text = dot(cur == id) .. Languages.getDisplay(id),
                callback = function() setVal(id) end }})
        end
        table.insert(rows, {{ text = _("Custom…"),
            callback = function() UIManager:close(picker); editCustom(key, dialog_title) end }})
        table.insert(rows, {{ text = _("Cancel"), id = "close",
            callback = function() UIManager:close(picker); BookSettings.showLanguageConfig(opts) end }})
        picker = ButtonDialog:new{ title = dialog_title, buttons = rows }
        UIManager:show(picker)
    end

    local function gdisp(v)
        if v == nil or v == "" then return _("primary language") end
        return Languages.getDisplay(v)
    end
    local function langLabel(v)
        if v == nil or v == "" then return _("Follow global") end
        return Languages.getDisplay(v)
    end

    -- Effective global target languages (for the "Follow global (X)" hints).
    local SystemPrompts = require("prompts.system_prompts")
    local global_trans = SystemPrompts.getEffectiveTranslationLanguage({
        translation_use_primary = features.translation_use_primary,
        interaction_languages = features.interaction_languages,
        user_languages = features.user_languages,
        primary_language = features.primary_language,
        translation_language = features.translation_language,
    })
    local global_dict = SystemPrompts.getEffectiveDictionaryLanguage({
        dictionary_language = features.dictionary_language,
        translation_use_primary = features.translation_use_primary,
        interaction_languages = features.interaction_languages,
        user_languages = features.user_languages,
        primary_language = features.primary_language,
        translation_language = features.translation_language,
    })

    -- Global main response language (the "Always respond in X" directive's primary).
    local global_response = SystemPrompts.parseUserLanguages(
        features.interaction_languages or features.user_languages, features.primary_language)

    local cur_r = doc_settings:readSetting(BookSettings.KEY_RESPONSE_LANG)
    local cur_t = doc_settings:readSetting(BookSettings.KEY_TRANSLATION_LANG)
    local cur_d = doc_settings:readSetting(BookSettings.KEY_DICTIONARY_LANG)

    local buttons = {
        {{ text = T(_("AI response language: %1"), langLabel(cur_r)),
            callback = function()
                showLangPicker(BookSettings.KEY_RESPONSE_LANG,
                    _("AI response language (this book)"), gdisp(global_response))
            end }},
        {{ text = T(_("Translation language: %1"), langLabel(cur_t)),
            callback = function()
                showLangPicker(BookSettings.KEY_TRANSLATION_LANG,
                    _("Translation language (this book)"), gdisp(global_trans))
            end }},
        {{ text = T(_("Dictionary language: %1"), langLabel(cur_d)),
            callback = function()
                showLangPicker(BookSettings.KEY_DICTIONARY_LANG,
                    _("Dictionary language (this book)"), gdisp(global_dict))
            end }},
        {{ text = _("Close"), id = "close", callback = function()
            closeDialog()
            if on_close then on_close() end
        end }},
    }

    dialog = ButtonDialog:new{ title = _("Languages (this book)"), buttons = buttons }
    UIManager:show(dialog)
end

return BookSettings
