--[[
    koassistant_storage_registry.lua

    SINGLE SOURCE OF TRUTH for every file, directory, and settings key the
    KOAssistant plugin owns on disk. Track 33 (docs/storage_lifecycle_plan.md).

    Before this module, the inventory was tracked by three disjoint
    hand-maintained lists (`USER_FILES`/`USER_DIRS` in koassistant_update_checker.lua,
    `KOASSISTANT_SIDECAR_FILES` in main.lua, and hardcoded copy lists in
    koassistant_backup_manager.lua) plus several managers in none of them. This
    registry replaces them: update-preservation, backup, reset, and (future)
    in-plugin wipe all derive from one declarative table.

    NOTE: KOReader's `deletePluginSettings` plugin hook (issue #77) was evaluated
    and DROPPED — its synchronous, no-preview/no-confirm teardown is weaker than
    the plugin's own backup/reset/wipe. KOReader only deletes the plugin *folder*;
    the plugin owns its complete data-delete lifecycle in-app. The `uninstall`
    field below is retained as declarative teardown metadata for that in-plugin wipe.

    NO file merging — files stay where they are. The registry only *describes*
    them. Paths are resolved lazily (DataStorage) so this module is pure data at
    load time and unit-testable without heavy mocking.

    Phase 1 (this commit) wires `updateFiles()/updateDirs()/sidecarFiles()` into
    the update checker + main.lua and adds a coverage-guard test. The remaining
    accessors (backup/reset/wipe/uninstall enumeration) are declared here and
    consumed in later phases.

    ── Entry fields ───────────────────────────────────────────────────────────
      id            unique string id
      label         user-facing name (for previews / README)
      location      settings_dir | settings_subkey | global_key | sidecar_file
                    | sidecar_dockey | plugin_file | plugin_dir | data_dir
      ref           filename / key name / dir name (string), OR a function
                    returning a list of keys (for dockey groups)
      category      credentials | config | assets | conversations | artifacts
                    | notebooks | exports | backups | index | internal
      backup        true | false | "opt_in"   (does createBackup() include it)
      rebuildable   true for indexes (derivable from on-disk data; safe to clear)
      reset_in      list of presets that FORCE-clear it by default
                    (subset of: "fresh_start", "wipe_all")
      opt_in_reset  true if it appears as an opt-in checkbox in reset/wipe UI
      update_preserve  true if performUpdate() must carry it across (USER_FILES role)
      uninstall     teardown disposition for the in-plugin complete-wipe:
                    true = part of the plugin's global footprint (removed by a full
                    wipe); false = preserved (backups/exports/default vault)
      index_key     for sidecar items: the global index listing which books have it
      legacy        true for migrated-away names (clean but never create)
      notes         freeform

    See docs/storage_lifecycle_plan.md "Deletion semantics" for the full matrix.
]]

local Registry = {}

-- Storage roots resolved lazily AT CALL TIME (require, not a captured upvalue) so
-- the registry never holds a stale DataStorage reference — robust to module
-- load-order and any test that re-mocks `datastorage`.
local function settingsDir() return require("datastorage"):getSettingsDir() end
local function dataDir() return require("datastorage"):getDataDir() end

-- G_reader_settings keys we own that are NOT koassistant_-prefixed. The
-- coverage-guard test consults this so it knows these are deliberate, not drift.
Registry.UNPREFIXED_GLOBAL_KEYS = {
    "chat_storage_version",
    "chat_migration_in_progress",
}

-- Settings sub-key categories (inside koassistant_settings.lua). Used by the
-- reset engine (Phase 2): "config" = every sub-key NOT listed here (the plain
-- feature toggles + action menus/ordering/edits). These four buckets are the
-- non-config sub-keys, each with a different reset disposition. This replaces the
-- hardcoded preserve list in main.lua `_resetFeatureSettingsInternal`.
--
-- Reset disposition by bucket (decided 2026-06-19; Fresh Start = clean-slate):
--   credentials  preserved by Reset Settings + Fresh Start; cleared on wipe/uninstall
--   assets       user-authored customizations. Preserved by Reset Settings;
--                WIPED by Fresh Start (clean-slate); cleared on wipe/uninstall
--   languages    personal language setup. Preserved by Reset Settings + Fresh Start
--                (worth keeping across a fresh start); cleared on wipe/uninstall
--   preferences  selections/gestures/fonts. Preserved by Reset Settings;
--                RESET by Fresh Start
--   internal     migration/version flags. Preserved by Reset Settings + Fresh Start
--                (track data state — clearing risks re-migration); cleared on
--                wipe/uninstall — EXCEPT setup_wizard_completed, which Fresh Start
--                clears so onboarding re-runs.
Registry.SETTINGS_SUBKEYS = {
    credentials = { "api_keys" },
    assets = {
        "custom_actions", "custom_prompts",                 -- top-level (see TOPLEVEL_SUBKEYS)
        "custom_behaviors", "custom_domains",
        "custom_providers", "custom_models", "provider_default_models",
    },
    languages = {
        "translation_language", "dictionary_language",
        "interaction_languages", "additional_languages", "primary_language",
    },
    preferences = {
        "selected_behavior", "selected_domain", "trusted_providers",
        "gesture_actions", "markdown_font_size", "export_custom_path",
        "session_chips",
    },
    internal = {
        "languages_migrated", "behavior_migrated", "prompts_migrated_v2",
        "_reasoning_v2_migrated", "_reasoning_hint_shown",
        "_tools_posture_migrated", "_session_chips_migrated",
        "setup_wizard_completed",                            -- top-level (see TOPLEVEL_SUBKEYS)
    },
}

-- Sub-keys that live at the TOP LEVEL of koassistant_settings.lua (siblings of
-- the `features` table), not inside features.*. `applyDefaults` only rebuilds the
-- `features` table, so these are excluded from its preserve list and handled by
-- their own delSetting() resets.
Registry.TOPLEVEL_SUBKEYS = {
    custom_actions = true,
    custom_prompts = true,
    setup_wizard_completed = true,
}

-- ── The inventory ────────────────────────────────────────────────────────────
Registry.entries = {
    --========================= Settings-dir files =============================
    {
        id = "settings", label = "Settings & customizations",
        location = "settings_dir", ref = "koassistant_settings.lua",
        category = "config", backup = true,
        reset_in = { "wipe_all" }, uninstall = true,
        notes = "Container file. In-place resets edit its sub-keys (see SETTINGS_SUBKEYS); it is only *deleted* on wipe/uninstall.",
    },
    {
        id = "general_chats", label = "General chats",
        location = "settings_dir", ref = "koassistant_general_chats.lua",
        category = "conversations", backup = true,
        reset_in = { "wipe_all" }, opt_in_reset = true, uninstall = true,
    },
    {
        id = "library_chats", label = "Library chats",
        location = "settings_dir", ref = "koassistant_library_chats.lua",
        category = "conversations", backup = true,
        reset_in = { "wipe_all" }, opt_in_reset = true, uninstall = true,
    },
    {
        id = "last_opened", label = "Last-opened chat pointer",
        location = "settings_dir", ref = "koassistant_last_opened.lua",
        category = "internal", backup = false,
        reset_in = { "wipe_all" }, uninstall = true,
    },
    {
        id = "pinned_general", label = "Pinned (general)",
        location = "settings_dir", ref = "koassistant_pinned_general.lua",
        category = "artifacts", backup = true,
        reset_in = { "wipe_all" }, opt_in_reset = true, uninstall = true,
    },
    {
        id = "pinned_library", label = "Pinned (library)",
        location = "settings_dir", ref = "koassistant_pinned_library.lua",
        category = "artifacts", backup = true,
        reset_in = { "wipe_all" }, opt_in_reset = true, uninstall = true,
    },
    {
        id = "legacy_multi_book_chats", label = "Legacy multi-book chats",
        location = "settings_dir", ref = "koassistant_multi_book_chats.lua",
        category = "conversations", backup = false, legacy = true,
        reset_in = { "wipe_all" }, uninstall = true,
        notes = "Renamed to koassistant_library_chats.lua on load; clean if stragglers remain.",
    },
    {
        id = "legacy_pinned_multi_book", label = "Legacy multi-book pinned",
        location = "settings_dir", ref = "koassistant_pinned_multi_book.lua",
        category = "artifacts", backup = false, legacy = true,
        reset_in = { "wipe_all" }, uninstall = true,
        notes = "Renamed to koassistant_pinned_library.lua on load; clean if stragglers remain.",
    },

    --========================= Global keys (G_reader_settings) ================
    {
        id = "chat_index", label = "Chat index",
        location = "global_key", ref = "koassistant_chat_index",
        category = "index", rebuildable = true, backup = false,
        reset_in = { "wipe_all" }, uninstall = true,
    },
    {
        id = "notebook_index", label = "Notebook index",
        location = "global_key", ref = "koassistant_notebook_index",
        category = "index", rebuildable = true, backup = false,
        reset_in = { "wipe_all" }, uninstall = true,
    },
    {
        id = "artifact_index", label = "Artifact index",
        location = "global_key", ref = "koassistant_artifact_index",
        category = "index", rebuildable = true, backup = false,
        reset_in = { "wipe_all" }, uninstall = true,
    },
    {
        id = "pinned_index", label = "Pinned index",
        location = "global_key", ref = "koassistant_pinned_index",
        category = "index", rebuildable = true, backup = false,
        reset_in = { "wipe_all" }, uninstall = true,
    },
    {
        id = "last_update_check", label = "Last successful update-check timestamp",
        location = "global_key", ref = "koassistant_last_update_check",
        category = "internal", backup = false,
        reset_in = { "wipe_all" }, uninstall = true,
    },
    {
        id = "artifact_index_version", label = "Artifact index schema version",
        location = "global_key", ref = "koassistant_artifact_index_version",
        category = "internal", backup = false,
        reset_in = { "wipe_all" }, uninstall = true,
    },
    {
        id = "chat_storage_version", label = "Chat storage schema version",
        location = "global_key", ref = "chat_storage_version",
        category = "internal", backup = false,
        reset_in = { "wipe_all" }, uninstall = true,
        notes = "NOT koassistant_-prefixed (see UNPREFIXED_GLOBAL_KEYS).",
    },
    {
        id = "chat_migration_in_progress", label = "Chat migration lock",
        location = "global_key", ref = "chat_migration_in_progress",
        category = "internal", backup = false,
        reset_in = { "wipe_all" }, uninstall = true,
        notes = "Transient lock; NOT koassistant_-prefixed.",
    },

    --========================= Sidecar files (per-book .sdr) ==================
    {
        id = "sidecar_notebook", label = "Per-book notebook",
        location = "sidecar_file", ref = "koassistant_notebook.md",
        category = "notebooks", backup = "opt_in",
        index_key = "koassistant_notebook_index",
        opt_in_reset = true,
    },
    {
        id = "sidecar_cache", label = "Per-book artifact cache",
        location = "sidecar_file", ref = "koassistant_cache.lua",
        category = "artifacts", backup = "opt_in",
        index_key = "koassistant_artifact_index",
        opt_in_reset = true,
    },
    {
        id = "sidecar_user_aliases", label = "Per-book X-Ray search terms",
        location = "sidecar_file", ref = "koassistant_user_aliases.lua",
        category = "artifacts", backup = "opt_in",
        index_key = "koassistant_artifact_index",  -- best-effort: shares the artifact sidecar dir; has no dedicated index
        opt_in_reset = true,
    },
    {
        id = "sidecar_pinned", label = "Per-book pinned",
        location = "sidecar_file", ref = "koassistant_pinned.lua",
        category = "artifacts", backup = "opt_in",
        index_key = "koassistant_pinned_index",
        opt_in_reset = true,
    },

    --========================= Sidecar DocSettings keys (per-book) ============
    {
        id = "dockey_book_settings", label = "Per-book settings",
        location = "sidecar_dockey",
        ref = function() return require("koassistant_book_settings").SIDECAR_KEYS end,
        category = "config", backup = false,
        notes = "12 per-book override keys; SIDECAR_KEYS is the owner's source of truth (no dedicated index; per-book DocSettings).",
    },
    {
        id = "dockey_chats", label = "Per-book chats",
        location = "sidecar_dockey", ref = "koassistant_chats",
        category = "conversations", backup = true,  -- backed up as JSON today
        index_key = "koassistant_chat_index",
        opt_in_reset = true,
    },
    {
        id = "dockey_notebook_ref", label = "Per-book notebook reference",
        location = "sidecar_dockey", ref = "koassistant_notebook_ref",
        category = "notebooks", backup = false,
        index_key = "koassistant_notebook_index",
        notes = "Currently never cleaned on notebook delete (Track 33 cleanup item).",
    },
    {
        id = "dockey_doi", label = "Per-book DOI cache",
        location = "sidecar_dockey", ref = "koassistant_doi",
        category = "artifacts", rebuildable = true, backup = false,
        notes = "No index; re-resolvable. Registered for visibility.",
    },
    {
        id = "dockey_last_opened", label = "Per-book last-opened timestamp",
        location = "sidecar_dockey", ref = "koassistant_last_opened",
        category = "internal", backup = false,
        notes = "Distinct from the settings-dir koassistant_last_opened.lua pointer.",
    },

    --========================= Plugin-folder files (USER_FILES) ===============
    {
        id = "apikeys", label = "API keys file",
        location = "plugin_file", ref = "apikeys.lua",
        category = "credentials", backup = "opt_in",
        update_preserve = true, uninstall = true,
        notes = "Removed by KOReader's folder purge on uninstall.",
    },
    {
        id = "configuration", label = "Configuration file",
        location = "plugin_file", ref = "configuration.lua",
        category = "config", backup = true,
        update_preserve = true, uninstall = true,
    },
    {
        id = "custom_actions", label = "Custom actions file",
        location = "plugin_file", ref = "custom_actions.lua",
        category = "assets", backup = true,
        update_preserve = true, uninstall = true,
    },

    --========================= Plugin-folder dirs (USER_DIRS) =================
    {
        id = "behaviors_dir", label = "Custom behaviors",
        location = "plugin_dir", ref = "behaviors",
        category = "assets", backup = true,
        update_preserve = true, uninstall = true,
    },
    {
        id = "domains_dir", label = "Custom domains",
        location = "plugin_dir", ref = "domains",
        category = "assets", backup = true,
        update_preserve = true, uninstall = true,
    },

    --========================= Data dirs (getDataDir) =========================
    {
        id = "chats_v1_dir", label = "Legacy v1 chats",
        location = "data_dir", ref = "koassistant_chats",
        category = "internal", legacy = true, backup = false,
        reset_in = { "fresh_start", "wipe_all" }, uninstall = true,
        notes = "v1 hash-dir storage; superseded by DocSettings v2.",
    },
    {
        id = "chats_backup_dir", label = "v1→v2 migration backup",
        location = "data_dir", ref = "koassistant_chats.backup",
        category = "internal", backup = false,
        reset_in = { "fresh_start", "wipe_all" }, uninstall = true,
        notes = "Never purged today (Track 33 cleanup item).",
    },
    {
        id = "backups_dir", label = "Backups",
        location = "data_dir", ref = "koassistant_backups",
        category = "backups", backup = false,
        -- NEVER auto-deleted: the survival point across uninstall/reinstall.
        uninstall = false,
    },
    {
        id = "exports_dir", label = "Exports",
        location = "data_dir", ref = "koassistant_exports",
        category = "exports", backup = false,
        opt_in_reset = true, uninstall = false,
        notes = "User-materialized files; preserved on teardown (user decision 2026-06-19).",
    },
    {
        id = "notebooks_vault_dir", label = "Notebook vault (default)",
        location = "data_dir", ref = "koassistant_notebooks",
        category = "notebooks", backup = false,
        opt_in_reset = true, uninstall = false,
        notes = "Default vault only. A CUSTOM/Obsidian notebook path is never touched by any path.",
    },
}

-- ── Path resolution ──────────────────────────────────────────────────────────
-- Returns the absolute path for settings_dir / data_dir entries (nil otherwise).
function Registry.resolvePath(entry)
    if entry.location == "settings_dir" then
        return settingsDir() .. "/" .. entry.ref
    elseif entry.location == "data_dir" then
        return dataDir() .. "/" .. entry.ref
    end
    return nil
end

-- ── Accessors ────────────────────────────────────────────────────────────────
function Registry.all()
    return Registry.entries
end

function Registry.byLocation(loc)
    local out = {}
    for _, e in ipairs(Registry.entries) do
        if e.location == loc then out[#out + 1] = e end
    end
    return out
end

function Registry.byCategory(cat)
    local out = {}
    for _, e in ipairs(Registry.entries) do
        if e.category == cat then out[#out + 1] = e end
    end
    return out
end

local function refsForLocation(loc)
    local out = {}
    for _, e in ipairs(Registry.entries) do
        if e.location == loc then out[#out + 1] = e.ref end
    end
    return out
end

-- CONSUMED IN PHASE 1: replace the three hand-maintained lists.
-- Plugin-folder files/dirs that must survive auto-updates (USER_FILES/USER_DIRS).
function Registry.updateFiles()
    return refsForLocation("plugin_file")
end

function Registry.updateDirs()
    return refsForLocation("plugin_dir")
end

-- Per-book sidecar filenames tracked on book move/copy/delete (KOASSISTANT_SIDECAR_FILES).
function Registry.sidecarFiles()
    return refsForLocation("sidecar_file")
end

-- Plugin-folder config files the backup includes, as { ref, credential }. The
-- `credential` ones (api keys) are gated by include_api_keys at the call site.
-- Single source for the list that used to be hardcoded in BOTH createBackup and
-- restoreBackup.
function Registry.backupPluginFiles()
    local out = {}
    for _, e in ipairs(Registry.entries) do
        if e.location == "plugin_file" and e.backup then
            out[#out + 1] = { ref = e.ref, credential = (e.category == "credentials") }
        end
    end
    return out
end

-- Plugin-folder dirs the backup includes (domains/, behaviors/).
function Registry.backupPluginDirs()
    local out = {}
    for _, e in ipairs(Registry.entries) do
        if e.location == "plugin_dir" and e.backup then
            out[#out + 1] = e.ref
        end
    end
    return out
end

-- Global indices (KOASSISTANT_INDICES analogue): rebuildable index keys.
function Registry.indexKeys()
    local out = {}
    for _, e in ipairs(Registry.entries) do
        if e.location == "global_key" and e.category == "index" then
            out[#out + 1] = e.ref
        end
    end
    return out
end

-- ── Reset preserve-lists (CONSUMED IN PHASE 2) ───────────────────────────────
-- Build the `features.*` dotted preserve paths for SettingsSchema.applyDefaults
-- from a set of sub-key buckets. Top-level sub-keys are excluded (applyDefaults
-- only rebuilds the features table; top-level keys are reset by their own delSetting).
function Registry.featuresPreserveList(buckets)
    local out = {}
    for _, bucket in ipairs(buckets) do
        for _, key in ipairs(Registry.SETTINGS_SUBKEYS[bucket] or {}) do
            if not Registry.TOPLEVEL_SUBKEYS[key] then
                out[#out + 1] = "features." .. key
            end
        end
    end
    return out
end

-- "Reset Settings": keep credentials, assets, languages, preferences, and internal
-- flags; reset only the plain feature toggles.
function Registry.settingsResetPreserve()
    return Registry.featuresPreserveList({ "credentials", "assets", "languages", "preferences", "internal" })
end

-- "Fresh Start" (clean-slate): keep credentials, languages, and internal flags.
-- Custom assets (no schema default) and preferences are dropped/reset; the wizard
-- flag is cleared separately (top-level) so onboarding re-runs.
function Registry.freshStartPreserve()
    return Registry.featuresPreserveList({ "credentials", "languages", "internal" })
end

-- Discrete (non-settings-subkey) entries that a reset preset force-clears by
-- default. preset is "fresh_start" | "wipe_all". (Settings sub-keys are handled
-- via the preserve-lists above, not here.)
function Registry.resetEntries(preset)
    local out = {}
    for _, e in ipairs(Registry.entries) do
        if e.reset_in then
            for _, p in ipairs(e.reset_in) do
                if p == preset then
                    out[#out + 1] = e
                    break
                end
            end
        end
    end
    return out
end

return Registry
