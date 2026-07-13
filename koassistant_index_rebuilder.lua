--[[--
Index rebuilder for KOAssistant (issue #92).

The four global browsers (artifacts, chats, notebooks, pinned) run on
device-local G_reader_settings indexes; the data itself travels with the book
(.sdr sidecars). This module heals those indexes without automatic scanning:
discovery is explicit (maintenance menu action / opt-in throttled startup run)
and folder scanning is limited to user-designated folders.

Discovery phases (union, merge semantics — never wipes an index):
  A. Local knowledge: ReadHistory + all four existing indexes (cross-pollination)
  B. Central sidecar locations (dir/hash storage modes; via ChatHistoryManager)
  C. User-designated folders (features.index_scan_folders)

Per candidate book: stat gate (book file must exist locally) -> multi-location
sidecar fast-skip -> per-index refresh helpers in no_flush mode; one
settings flush at the end; prune pass last.

@module koassistant_index_rebuilder
]]

local DocSettings = require("docsettings")
local lfs = require("libs/libkoreader-lfs")
local logger = require("logger")

local IndexRebuilder = {}

local INDEX_KEYS = {
    "koassistant_artifact_index",
    "koassistant_chat_index",
    "koassistant_notebook_index",
    "koassistant_pinned_index",
}

local SPECIAL_KEYS = {
    ["__GENERAL_CHATS__"] = true,
    ["__LIBRARY_CHATS__"] = true,
}

-- Plugin files that mark a sidecar as "has KOAssistant data" (used to report
-- sidecars that couldn't be mapped back to a local book)
local PLUGIN_SIDECAR_FILES = {
    "koassistant_cache.lua",
    "koassistant_pinned.lua",
    "koassistant_notebook.md",
}

--- Does this book have a sidecar dir at ANY candidate location?
-- Checking only the current storage mode would miss data stranded by a
-- storage-mode switch, and doc-mode books on read-only storage whose
-- metadata.lua lives at the dir location (DocSettings:flush falls back
-- there). Hash is checked last: that lookup computes a partial MD5 of the
-- book file (file open + seeked reads), the others are pure string ops.
local function hasAnySidecarDir(book_path)
    for _idx, loc in ipairs({ "doc", "dir" }) do
        local ok, dir = pcall(DocSettings.getSidecarDir, DocSettings, book_path, loc)
        if ok and dir and lfs.attributes(dir, "mode") == "directory" then
            return true
        end
    end
    if DocSettings.isHashLocationEnabled() then
        local ok, dir = pcall(DocSettings.getSidecarDir, DocSettings, book_path, "hash")
        if ok and dir and lfs.attributes(dir, "mode") == "directory" then
            return true
        end
    end
    return false
end

local function sdrHasPluginData(sdr_path)
    for _idx, name in ipairs(PLUGIN_SIDECAR_FILES) do
        if lfs.attributes(sdr_path .. "/" .. name, "mode") == "file" then
            return true
        end
    end
    return false
end

local function countIndexEntries(key)
    local n = 0
    for k in pairs(G_reader_settings:readSetting(key, {})) do
        if not SPECIAL_KEYS[k] then n = n + 1 end
    end
    return n
end

--- Prune stale entries (book file gone) from all four indexes.
--- Extracted from the old AskGPT:validateAllIndexes prune loop; also runs at
--- the end of a rebuild so one action is a full heal (add + remove).
--- @param opts table|nil { no_flush = true } to skip G_reader_settings:flush()
--- @return number pruned Total entries removed
function IndexRebuilder.pruneAllIndexes(opts)
    local pruned = 0
    for _idx, key in ipairs(INDEX_KEYS) do
        local index = G_reader_settings:readSetting(key, {})
        local removed = 0
        for doc_path in pairs(index) do
            if not SPECIAL_KEYS[doc_path] and lfs.attributes(doc_path, "mode") ~= "file" then
                logger.info("KOAssistant: Pruning stale entry from", key, ":", doc_path)
                index[doc_path] = nil
                removed = removed + 1
            end
        end
        if removed > 0 then
            G_reader_settings:saveSetting(key, index)
            pruned = pruned + removed
        end
    end
    if pruned > 0 and not (opts and opts.no_flush) then
        G_reader_settings:flush()
    end
    return pruned
end

--- Run a merge-based rebuild of all four indexes.
--- @param ui table|nil ReaderUI/FileManager instance (live DocSettings resolution)
--- @param features table|nil Plugin features table (index_scan_folders, notebook_save_location)
--- @return table report { candidates = {a,b,c}, with_data, skipped_missing,
---   unmapped_sidecars, totals = {key->n}, added = {key->net}, pruned }
function IndexRebuilder.run(ui, features)
    local report = {
        candidates = { a = 0, b = 0, c = 0 },
        with_data = 0,
        skipped_missing = 0,
        unmapped_sidecars = 0,
        totals = {},
        added = {},
        pruned = 0,
    }

    local before = {}
    for _idx, key in ipairs(INDEX_KEYS) do
        before[key] = countIndexEntries(key)
    end

    -- ---- Discovery ----
    local seen, candidates = {}, {}
    local function add(path, phase)
        if not path or SPECIAL_KEYS[path] or seen[path] then return end
        seen[path] = true
        table.insert(candidates, path)
        report.candidates[phase] = report.candidates[phase] + 1
    end

    -- Phase A: ReadHistory + existing indexes (re-verifies every known entry)
    local ok_rh, ReadHistory = pcall(require, "readhistory")
    if ok_rh and ReadHistory and ReadHistory.hist then
        for _idx, item in ipairs(ReadHistory.hist) do
            if item.file then add(item.file, "a") end
        end
    end
    for _idx, key in ipairs(INDEX_KEYS) do
        for doc_path in pairs(G_reader_settings:readSetting(key, {})) do
            add(doc_path, "a")
        end
    end

    -- Phase B: central sidecar locations (dir/hash storage modes only)
    local ChatHistoryManager = require("koassistant_chat_history_manager")
    ChatHistoryManager:scanCentralSdrPaths(function(book_path, sdr_path)
        if book_path and lfs.attributes(book_path, "mode") ~= "file"
           and sdr_path and sdrHasPluginData(sdr_path) then
            -- Mapped, but the recorded book path doesn't exist locally
            -- (typically another device's absolute path in a synced sidecar):
            -- report instead of indexing a dead path.
            report.unmapped_sidecars = report.unmapped_sidecars + 1
        end
        add(book_path, "b")
    end, function(sdr_path)
        if sdrHasPluginData(sdr_path) then
            report.unmapped_sidecars = report.unmapped_sidecars + 1
        end
    end)

    -- Phase C: user-designated folders only (no folders configured = no scan)
    local folders = features and features.index_scan_folders or {}
    if #folders > 0 then
        local LibraryScanner = require("koassistant_library_scanner")
        local results, walk_seen = {}, {}
        for _idx, folder in ipairs(folders) do
            LibraryScanner.scanFolder(folder, results, walk_seen, nil)
        end
        for _idx, path in ipairs(results) do
            add(path, "c")
        end
    end

    -- ---- Heal ----
    local ActionCache = require("koassistant_action_cache")
    local Notebook = require("koassistant_notebook")
    local PinnedManager = require("koassistant_pinned_manager")
    local no_flush = { no_flush = true }

    for _idx, path in ipairs(candidates) do
        if lfs.attributes(path, "mode") ~= "file" then
            report.skipped_missing = report.skipped_missing + 1
        elseif hasAnySidecarDir(path) then
            report.with_data = report.with_data + 1
            ActionCache.refreshIndex(path, no_flush)
            ChatHistoryManager:refreshChatIndexEntry(path, ui, no_flush)
            Notebook.refreshIndexEntry(path, no_flush)
            PinnedManager.refreshIndex(path, no_flush)
        end
    end

    -- Vault/custom-mode notebooks live in one central folder; a single
    -- additive scan covers them (per-book helper is a no-op in those modes)
    if features and (features.notebook_save_location or "sidecar") ~= "sidecar" then
        Notebook.scanAndRebuildIndex()
    end

    -- ---- Prune + single flush ----
    report.pruned = IndexRebuilder.pruneAllIndexes({ no_flush = true })
    G_reader_settings:flush()

    for _idx, key in ipairs(INDEX_KEYS) do
        report.totals[key] = countIndexEntries(key)
        report.added[key] = report.totals[key] - before[key]
    end

    logger.info("KOAssistant IndexRebuilder: candidates a/b/c:",
        report.candidates.a, report.candidates.b, report.candidates.c,
        "with_data:", report.with_data,
        "skipped_missing:", report.skipped_missing,
        "unmapped:", report.unmapped_sidecars,
        "pruned:", report.pruned)
    return report
end

return IndexRebuilder
