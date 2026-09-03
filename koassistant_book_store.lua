--[[--
Per-book plugin storage (Track 37, issue #72): KOAssistant's own sidecar files.

KOReader owns metadata.lua and flushes the WHOLE file from its one live
in-memory copy. Until 2026-09-02 the plugin kept its per-book data INSIDE that
file (chats, the Book Settings keys, the notebook reference, the DOI cache, the
last-opened stamp, the X-Ray coverage-ask stamp), which made every plugin
write a whole-file rewrite of KOReader's data, every KOReader open pay for our
chats, and issue #72 possible at all. This module moves that data into two
files of our own in the same .sdr folder the other plugin sidecar files use:

  koassistant_book_settings.lua   { settings = { <koassistant_* key> = value } }
  koassistant_chats.lua           { chats = { [chat_id] = chat } }

Both are registered as sidecar_file entries in koassistant_storage_registry.lua,
so the move/copy/delete patch, the index rebuilder and the backup lists pick
them up like the cache/notebook/pinned files.

THE FACADE: `BookStore.wrap(doc_settings, document_path)` returns an object with
the DocSettings read/write API whose koassistant_* keys route to the settings
file while every other key (percent_finished, summary, doc_props, ...) still
reads from KOReader's DocSettings. SafeDocSettings.resolve() returns a facade,
so the ~130 call sites written against DocSettings keep working unchanged, and
the mixed sites (spoiler posture reading KOReader's `summary` beside our
spoiler key) keep working by construction. One cached settings store per book
means every caller shares one copy: the divergent-copies bug cannot recur for
our own file. Writes persist immediately (small file, rare writes, crash-safe).

MIGRATION: `migrateBook` moves one book's keys out of metadata.lua
(copy first, verify, THEN delete from metadata.lua, then flush KOReader's
file), idempotent so an interrupted pass re-runs safely; the bulk pass runs at
plugin init while chat_storage_version == 2 and the straggler check runs on
first store access per book per session (an older plugin build writing into
metadata.lua after the move is folded in, never destroyed).
]]

local lfs = require("libs/libkoreader-lfs")
local logger = require("koassistant_logger")

local BookStore = {}

BookStore.SETTINGS_FILE = "koassistant_book_settings.lua"
BookStore.CHATS_FILE = "koassistant_chats.lua"
BookStore.PREFIX = "koassistant_"
-- The chats key inside metadata.lua (legacy location, read only by the migration)
BookStore.LEGACY_CHATS_KEY = "koassistant_chats"

local SPECIAL = { ["__GENERAL_CHATS__"] = true, ["__LIBRARY_CHATS__"] = true }

function BookStore.isPluginKey(key)
    return type(key) == "string" and key:sub(1, #BookStore.PREFIX) == BookStore.PREFIX
end

local function countKeys(t)
    local n = 0
    for _k in pairs(t) do n = n + 1 end
    return n
end

-- ── Paths ────────────────────────────────────────────────────────────────────

local function sidecarDir(document_path, location)
    local ok, DocSettings = pcall(require, "docsettings")
    if not ok or type(DocSettings) ~= "table" or not DocSettings.getSidecarDir then return nil end
    local ok2, dir = pcall(DocSettings.getSidecarDir, DocSettings, document_path, location)
    if ok2 and type(dir) == "string" and dir ~= "" then return dir end
    return nil
end

--- Path of one of our sidecar files for a book in the CURRENT storage mode.
--- nil for the general/library pseudo-paths and when no sidecar dir resolves
--- (the facade then degrades to the DocSettings it was given).
function BookStore.pathFor(document_path, filename)
    if type(document_path) ~= "string" or document_path == "" or SPECIAL[document_path] then
        return nil
    end
    local dir = sidecarDir(document_path)
    if not dir then return nil end
    return dir .. "/" .. filename
end

--- Lazy storage-mode migration (same recipe as the cache/notebook/pinned
--- files): when the file is missing at the current location, look in the
--- other storage modes and move it over.
local function migrateSidecarIfNeeded(document_path, current_path, filename)
    local ok_ds, DocSettings = pcall(require, "docsettings")
    if not ok_ds or type(DocSettings) ~= "table" then return false end
    local current = G_reader_settings:readSetting("document_metadata_folder", "doc")
    local alternates = { "doc", "dir" }
    if DocSettings.isHashLocationEnabled and DocSettings.isHashLocationEnabled() then
        table.insert(alternates, "hash")
    end
    for _idx, loc in ipairs(alternates) do
        if loc ~= current then
            local alt_dir = sidecarDir(document_path, loc)
            local alt_path = alt_dir and (alt_dir .. "/" .. filename)
            if alt_path and lfs.attributes(alt_path, "mode") == "file" then
                local util = require("util")
                local dir = current_path:match("(.*/)") or ""
                if dir ~= "" then util.makePath(dir) end
                local ok, err = os.rename(alt_path, current_path)
                if ok then
                    logger.info("KOAssistant: Migrated sidecar file", filename, "from alternate storage location")
                    return true
                end
                logger.warn("KOAssistant: Failed to migrate sidecar file", filename, ":", err)
            end
        end
    end
    return false
end

local function fileStamp(path)
    local attr = path and lfs.attributes(path)
    if not attr or attr.mode ~= "file" then return "none" end
    return tostring(attr.modification) .. ":" .. tostring(attr.size)
end

local function ensureDir(file_path)
    local dir = file_path:match("(.*/)") or ""
    if dir ~= "" then
        local ok, util = pcall(require, "util")
        if ok and util.makePath then util.makePath(dir) end
    end
end

-- ── Single-key file helpers (both files store ONE top-level key) ─────────────

local function readKeyFile(file_path, key)
    if not file_path then return nil end
    local LuaSettings = require("luasettings")
    local ok, ls = pcall(LuaSettings.open, LuaSettings, file_path)
    if not ok or not ls then return nil end
    local v = ls:readSetting(key)
    if type(v) ~= "table" then return nil end
    return v
end

local function writeKeyFile(file_path, key, value)
    local LuaSettings = require("luasettings")
    ensureDir(file_path)
    local ok, err = pcall(function()
        local ls = LuaSettings:open(file_path)
        ls:saveSetting(key, value)
        ls:flush()
    end)
    if not ok then return false, "write failed: " .. tostring(err) end
    -- Read-back verify (the old safeWriteToMetadata contract)
    local back = readKeyFile(file_path, key)
    if not back then
        return false, "verification failed: data not found after write"
    end
    return true
end

local function removeFile(file_path)
    if file_path and lfs.attributes(file_path, "mode") == "file" then
        os.remove(file_path)
    end
    local old = file_path and (file_path .. ".old")
    if old and lfs.attributes(old, "mode") == "file" then
        os.remove(old)
    end
end

-- ── Settings store (one cached instance per book) ────────────────────────────

local Store = {}
Store.__index = Store

function Store:readSetting(key, default)
    local v = self.data[key]
    if v == nil then return default end
    return v
end

function Store:has(key)
    return self.data[key] ~= nil
end

--- Every write persists immediately: writes are rare (a user changing a
--- per-book setting, one stamp per book open) and the file is tiny, so the
--- crash-safety is worth more than a batched flush. flush() is then a no-op.
function Store:saveSetting(key, value)
    if self.data[key] == value and type(value) ~= "table" then return self end
    self.data[key] = value
    self.dirty = true
    self:flush()
    return self
end

function Store:delSetting(key)
    if self.data[key] == nil then return self end
    self.data[key] = nil
    self.dirty = true
    self:flush()
    return self
end

--- Write the file (or remove it when nothing is left, so .sdr folders stay
--- clean and KOReader's purge can rmdir them). Returns ok, err.
function Store:flush()
    if not self.dirty then return true end
    if not self.file then return false, "no sidecar path" end
    local ok, err
    if next(self.data) == nil then
        removeFile(self.file)
        ok = true
    else
        ok, err = writeKeyFile(self.file, "settings", self.data)
    end
    if ok then
        self.dirty = false
        self.stamp = fileStamp(self.file)
    else
        logger.warn("KOAssistant BookStore: settings write failed for", self.file, ":", err)
    end
    return ok, err
end

function Store:isEmpty()
    return next(self.data) == nil
end

-- cache_key -> { store = Store, checked = bool }
local cache = {}

local function cacheKey(document_path)
    local ok, ffiutil = pcall(require, "ffi/util")
    if ok and ffiutil.realpath then
        local rp = ffiutil.realpath(document_path)
        if rp then return rp end
    end
    return document_path
end

local function loadStore(document_path)
    local file = BookStore.pathFor(document_path, BookStore.SETTINGS_FILE)
    local data
    if file then
        if lfs.attributes(file, "mode") ~= "file" then
            migrateSidecarIfNeeded(document_path, file, BookStore.SETTINGS_FILE)
        end
        data = readKeyFile(file, "settings")
    end
    return setmetatable({
        file = file,
        data = data or {},
        dirty = false,
        stamp = fileStamp(file),
        path = document_path,
    }, Store)
end

--- Drop the cached store for a book (called by the move/copy/delete patch and
--- after external writes). Safe with unknown paths.
function BookStore.invalidate(document_path)
    if type(document_path) ~= "string" then return end
    cache[cacheKey(document_path)] = nil
end

function BookStore._resetForTests()
    cache = {}
end

--- The per-book settings store. ONE instance per book per session; re-read
--- when the file changed on disk (sync tools, another process). Runs the
--- straggler migration check once per book per session (see migrateBook):
--- `raw_ds` = a real DocSettings for this book when the caller has one
--- (free for the open book); otherwise the check opens one only when our
--- settings file is missing.
--- @param document_path string
--- @param raw_ds table|nil real DocSettings (never a facade) or nil
--- @param opts table|nil { no_migrate = true } (used by migrateBook itself)
--- @return Store|nil nil when no sidecar path resolves
function BookStore.settings(document_path, raw_ds, opts)
    if type(document_path) ~= "string" or SPECIAL[document_path] then return nil end
    local key = cacheKey(document_path)
    local entry = cache[key]
    if entry then
        local file = entry.store.file
        if file and not entry.store.dirty and fileStamp(file) ~= entry.store.stamp then
            entry.store = loadStore(document_path)
        end
    else
        entry = { store = loadStore(document_path), checked = false }
        cache[key] = entry
    end
    if not entry.store.file then return nil end
    if not entry.checked and not (opts and opts.no_migrate) then
        entry.checked = true
        BookStore.ensureMigrated(document_path, raw_ds)
    end
    return entry.store
end

-- ── Chats file ───────────────────────────────────────────────────────────────

-- Plain read of the chats file (nil when there is none). The migration
-- itself reads through this, never through readChats' straggler hook.
local function readChatsFile(document_path)
    local file = BookStore.pathFor(document_path, BookStore.CHATS_FILE)
    if not file then return nil end
    if lfs.attributes(file, "mode") ~= "file" then
        migrateSidecarIfNeeded(document_path, file, BookStore.CHATS_FILE)
    end
    return readKeyFile(file, "chats")  -- nil when there is no file
end

--- @return table chats keyed by id ({} when none)
function BookStore.readChats(document_path)
    local chats = readChatsFile(document_path)
    if chats then return chats end
    -- Straggler net: a book the bulk pass never reached (not a candidate,
    -- unreadable at the time, a failed run) still holds its chats in
    -- metadata.lua; fold them in before answering "no chats" (once per
    -- session; the live DocSettings when the book is open)
    if BookStore.pathFor(document_path, BookStore.CHATS_FILE) then
        BookStore.ensureMigrated(document_path)
        chats = readChatsFile(document_path)
    end
    return chats or {}
end

--- Write the whole chats table (validate + write + read-back verify). An
--- empty table removes the file.
--- @return boolean ok, string|nil err
function BookStore.writeChats(document_path, chats)
    local file = BookStore.pathFor(document_path, BookStore.CHATS_FILE)
    if not file then return false, "no sidecar path for " .. tostring(document_path) end
    if type(chats) ~= "table" then return false, "chats must be a table" end
    for id, chat in pairs(chats) do
        if type(chat) ~= "table" then return false, "invalid chat " .. tostring(id) end
    end
    if next(chats) == nil then
        removeFile(file)
        return true
    end
    return writeKeyFile(file, "chats", chats)
end

function BookStore.hasChatsFile(document_path)
    local file = BookStore.pathFor(document_path, BookStore.CHATS_FILE)
    return file ~= nil and lfs.attributes(file, "mode") == "file"
end

-- ── Facade over a DocSettings ────────────────────────────────────────────────

local Facade = {}
Facade.__index = Facade

function Facade:_store()
    return BookStore.settings(self._path, self._raw, { no_migrate = true })
end

function Facade:readSetting(key, default)
    if BookStore.isPluginKey(key) then
        local st = self:_store()
        if st then return st:readSetting(key, default) end
        return default
    end
    return self._raw:readSetting(key, default)
end

function Facade:has(key)
    if BookStore.isPluginKey(key) then
        local st = self:_store()
        return st ~= nil and st:has(key)
    end
    return self._raw:has(key)
end

function Facade:saveSetting(key, value)
    if BookStore.isPluginKey(key) then
        local st = self:_store()
        if st then
            if value == nil then st:delSetting(key) else st:saveSetting(key, value) end
        end
        return self
    end
    -- The plugin never writes KOReader's keys (verified 2026-09-02); pass
    -- through so any future one behaves exactly as before the move.
    logger.dbg("KOAssistant BookStore: non-plugin key written through the facade:", key)
    self._raw:saveSetting(key, value)
    return self
end

function Facade:delSetting(key)
    if BookStore.isPluginKey(key) then
        local st = self:_store()
        if st then st:delSetting(key) end
        return self
    end
    self._raw:delSetting(key)
    return self
end

--- Our store persists on every write; KOReader's file is never flushed by
--- the plugin any more (it owns the timing for its own data).
function Facade:flush()
    local st = self:_store()
    if st then st:flush() end
    return self
end

function Facade:isTrue(key) return self:readSetting(key) == true end
function Facade:isFalse(key) return self:readSetting(key) == false end
function Facade:nilOrTrue(key) local v = self:readSetting(key); return v == nil or v == true end
function Facade:nilOrFalse(key) local v = self:readSetting(key); return v == nil or v == false end

function BookStore.isFacade(obj)
    return type(obj) == "table" and obj._koa_facade == true
end

--- Wrap a DocSettings so plugin keys live in our file. Idempotent. Degrades
--- to the DocSettings itself when no book path / sidecar dir resolves (test
--- fakes, custom-metadata objects) — logged at dbg.
--- @param doc_settings table real DocSettings (live or fresh)
--- @param document_path string|nil the book; defaults to doc_settings.data.doc_path
function BookStore.wrap(doc_settings, document_path)
    if doc_settings == nil then return nil end
    if BookStore.isFacade(doc_settings) then return doc_settings end
    local path = document_path
    if not path and type(doc_settings.data) == "table" then
        path = doc_settings.data.doc_path
    end
    if not path or not BookStore.pathFor(path, BookStore.SETTINGS_FILE) then
        logger.dbg("KOAssistant BookStore: no sidecar path, DocSettings used unwrapped")
        return doc_settings
    end
    local f = setmetatable({
        _koa_facade = true,
        _raw = doc_settings,
        _path = path,
        data = doc_settings.data,
    }, Facade)
    -- First touch per book per session: fold in anything an older build (or
    -- a pre-move file) left inside metadata.lua. Free when clean.
    BookStore.settings(path, doc_settings)
    return f
end

--- The real DocSettings behind a facade (or the object itself).
function BookStore.unwrap(obj)
    if BookStore.isFacade(obj) then return obj._raw end
    return obj
end

-- ── Migration out of metadata.lua ────────────────────────────────────────────

local function ourKeysIn(data)
    local ours = {}
    if type(data) ~= "table" then return ours end
    for k, v in pairs(data) do
        if BookStore.isPluginKey(k) then ours[k] = v end
    end
    return ours
end

--- Does this DocSettings still carry plugin keys?
function BookStore.hasLegacyKeys(raw_ds)
    return raw_ds ~= nil and next(ourKeysIn(raw_ds.data)) ~= nil
end

--- Move one book's plugin data out of its DocSettings into our files.
--- Copy first (existing file data wins per chat id / per key, so a half-done
--- earlier pass is harmless), verify, and only then delete the keys from
--- metadata.lua and flush KOReader's file. An empty legacy chats table is
--- just deleted. Never touches a book without our keys.
--- @param document_path string
--- @param raw_ds table real DocSettings for this book (live when open)
--- @return string status "clean" | "moved" | "failed"
--- @return table|string info { chats = n, keys = n } or the error
function BookStore.migrateBook(document_path, raw_ds)
    if not raw_ds or BookStore.isFacade(raw_ds) then
        return "failed", "migrateBook needs a real DocSettings"
    end
    local data = raw_ds.data
    local ours = ourKeysIn(data)
    if next(ours) == nil then return "clean", { chats = 0, keys = 0 } end
    if not BookStore.pathFor(document_path, BookStore.SETTINGS_FILE) then
        return "failed", "no sidecar path"
    end

    -- 1. Chats
    local legacy_chats = ours[BookStore.LEGACY_CHATS_KEY]
    ours[BookStore.LEGACY_CHATS_KEY] = nil
    local moved_chats, merged = 0, nil
    if type(legacy_chats) == "table" and next(legacy_chats) ~= nil then
        merged = {}
        for id, chat in pairs(legacy_chats) do
            if type(chat) == "table" then
                merged[id] = chat
                moved_chats = moved_chats + 1
            end
        end
        for id, chat in pairs(readChatsFile(document_path) or {}) do
            merged[id] = chat  -- the file's copy wins
        end
        local ok, err = BookStore.writeChats(document_path, merged)
        if not ok then
            logger.warn("KOAssistant BookStore: chats migration failed for", document_path, ":", err)
            return "failed", err
        end
    end

    -- 2. Settings keys (existing store value wins)
    local moved_keys = 0
    if next(ours) ~= nil then
        local st = BookStore.settings(document_path, raw_ds, { no_migrate = true })
        if not st then return "failed", "no settings store" end
        for k, v in pairs(ours) do
            if st.data[k] == nil then
                st.data[k] = v
                st.dirty = true
            end
            moved_keys = moved_keys + 1
        end
        local ok, err = st:flush()
        if not ok then return "failed", err end
        -- Verify on disk
        local back = readKeyFile(st.file, "settings")
        for k in pairs(ours) do
            if not back or back[k] == nil then
                return "failed", "verification failed for key " .. k
            end
        end
    end

    -- 3. Only now: remove from metadata.lua and flush KOReader's file
    for k in pairs(ours) do data[k] = nil end
    data[BookStore.LEGACY_CHATS_KEY] = nil
    local okf, errf = pcall(raw_ds.flush, raw_ds)
    if not okf then
        -- Copies are in place; the keys stay in metadata.lua and the next
        -- pass finds them again (existing file data wins, so nothing is lost)
        logger.warn("KOAssistant BookStore: metadata.lua flush failed for", document_path, ":", errf)
        return "failed", errf
    end

    -- 4. Chat index (Fix M fields ride along)
    if merged then
        local ok_m, err_m = pcall(function()
            local ChatHistoryManager = require("koassistant_chat_history_manager")
            ChatHistoryManager:updateChatIndex(document_path, "refresh", nil, merged, {
                no_flush = true,
                doc_props = raw_ds:readSetting("doc_props"), has_props = true,  -- overlaid in the index
            })
        end)
        if not ok_m then
            logger.warn("KOAssistant BookStore: chat index refresh after migration failed:", err_m)
        end
    end

    logger.info("KOAssistant BookStore: moved plugin data out of metadata.lua for", document_path,
        "(chats:", moved_chats, "keys:", moved_keys, ")")
    return "moved", { chats = moved_chats, keys = moved_keys }
end

-- per-session memo of straggler checks that already ran (cache_key -> true)
local migrated_this_session = {}

--- Straggler net: fold in anything still inside metadata.lua for this book.
--- With a raw DocSettings in hand the check is a table scan; without one it
--- opens the book's DocSettings ONLY when our settings file is missing
--- (a book that has a store file has been through a pass already).
--- @return string|nil status from migrateBook, nil when skipped
function BookStore.ensureMigrated(document_path, raw_ds)
    if type(document_path) ~= "string" or SPECIAL[document_path] then return nil end
    local key = cacheKey(document_path)
    if migrated_this_session[key] then return nil end
    migrated_this_session[key] = true
    if raw_ds and BookStore.isFacade(raw_ds) then raw_ds = raw_ds._raw end
    if not raw_ds then
        local sfile = BookStore.pathFor(document_path, BookStore.SETTINGS_FILE)
        if sfile and lfs.attributes(sfile, "mode") == "file" then return nil end
        if lfs.attributes(document_path, "mode") ~= "file" then return nil end
        local ok, ds = pcall(function()
            return require("koassistant_doc_settings").resolveRaw(document_path)
        end)
        if not ok or not ds then return nil end
        raw_ds = ds
    end
    if not BookStore.hasLegacyKeys(raw_ds) then return "clean" end
    local status, info = BookStore.migrateBook(document_path, raw_ds)
    if status == "failed" then
        -- Let a later access retry
        migrated_this_session[key] = nil
        logger.warn("KOAssistant BookStore: straggler migration failed for", document_path, ":", info)
    end
    return status
end

function BookStore._resetMigrationMemoForTests()
    migrated_this_session = {}
end

--- Bulk pass over every book the plugin can find (first start after the
--- update). Candidates = the index rebuilder's discovery set (chat/notebook/
--- artifact/pinned indexes + ReadHistory + central sidecar dirs + user index
--- folders). Books that are only reachable later are covered by
--- ensureMigrated on first access.
--- @param ui table|nil ReaderUI/FileManager (live DocSettings for the open book)
--- @param features table|nil plugin features (index_scan_folders)
--- @return table report { candidates, moved, clean, failed, skipped, chats, keys, failures = {path,...} }
function BookStore.migrateAll(ui, features)
    local report = { candidates = 0, moved = 0, clean = 0, failed = 0, skipped = 0,
        chats = 0, keys = 0, failures = {} }
    local ok_r, IndexRebuilder = pcall(require, "koassistant_index_rebuilder")
    if not ok_r or not IndexRebuilder.collectCandidates then
        report.failed = 1
        table.insert(report.failures, "index rebuilder unavailable")
        return report
    end
    local candidates = IndexRebuilder.collectCandidates(features)
    report.candidates = #candidates
    local SafeDocSettings = require("koassistant_doc_settings")
    for _idx, path in ipairs(candidates) do
        if lfs.attributes(path, "mode") ~= "file" or not IndexRebuilder.hasAnySidecarDir(path) then
            report.skipped = report.skipped + 1
        else
            local ok, raw = pcall(SafeDocSettings.resolveRaw, path, ui)
            if not ok or not raw then
                report.failed = report.failed + 1
                table.insert(report.failures, path)
            else
                local status, info = BookStore.migrateBook(path, raw)
                if status == "moved" then
                    report.moved = report.moved + 1
                    report.chats = report.chats + (info.chats or 0)
                    report.keys = report.keys + (info.keys or 0)
                    migrated_this_session[cacheKey(path)] = true
                elseif status == "clean" then
                    report.clean = report.clean + 1
                    migrated_this_session[cacheKey(path)] = true
                else
                    report.failed = report.failed + 1
                    table.insert(report.failures, path .. " (" .. tostring(info) .. ")")
                    logger.info("KOAssistant BookStore: migration failed for", path, ":", info)
                end
            end
        end
    end
    return report
end

return BookStore
