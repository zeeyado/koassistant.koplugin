--[[--
Pinned Artifacts module for KOAssistant

Manages user-pinned chat response snapshots. Pinned artifacts are read-only
snapshots stored alongside a book (sidecar) or in settings dir (general/multi-book).
They appear in the artifact browser with a pin indicator, distinct from
AI-generated cached artifacts.

Storage locations:
- Book context: sidecar_dir/koassistant_pinned.lua
- General context: settings_dir/koassistant_pinned_general.lua
- Multi-book context: settings_dir/koassistant_pinned_multi_book.lua

@module koassistant_pinned_manager
]]

local DataStorage = require("datastorage")
local DocSettings = require("docsettings")
local lfs = require("libs/libkoreader-lfs")
local logger = require("logger")

local PinnedManager = {}

-- Pinned format version
local PINNED_VERSION = 1

-- File paths for non-book contexts
PinnedManager.GENERAL_PINNED_FILE = DataStorage:getSettingsDir() .. "/koassistant_pinned_general.lua"
PinnedManager.MULTI_BOOK_PINNED_FILE = DataStorage:getSettingsDir() .. "/koassistant_pinned_multi_book.lua"

-- Special path constants (match chat history convention)
PinnedManager.GENERAL_KEY = "__GENERAL_CHATS__"
PinnedManager.MULTI_BOOK_KEY = "__MULTI_BOOK_CHATS__"

--- Find a safe long string delimiter that won't appear in the text.
--- @param content string The content to wrap
--- @return number equals Number of = signs needed
local function findSafeDelimiter(content)
    if not content then return 2 end
    for equals = 2, 10 do
        local closing = "]" .. string.rep("=", equals) .. "]"
        if not content:find(closing, 1, true) then
            return equals
        end
    end
    return 10
end

--- Write a long string field safely using delimiter escaping.
--- @param file file File handle
--- @param indent string Indentation prefix
--- @param field_name string Field name
--- @param value string The string value
local function writeLongString(file, indent, field_name, value)
    local text = value or ""
    local eq_count = findSafeDelimiter(text)
    local eq_str = string.rep("=", eq_count)
    file:write(string.format("%s%s = [%s[\n", indent, field_name, eq_str))
    file:write(text)
    file:write(string.format("]%s],\n", eq_str))
end

--- Get storage file path for a given context.
--- @param document_path string Document path or special key
--- @return string|nil path The file path, or nil if invalid
function PinnedManager.getPath(document_path)
    if not document_path then return nil end
    if document_path == PinnedManager.GENERAL_KEY then
        return PinnedManager.GENERAL_PINNED_FILE
    elseif document_path == PinnedManager.MULTI_BOOK_KEY then
        return PinnedManager.MULTI_BOOK_PINNED_FILE
    else
        local sidecar_dir = DocSettings:getSidecarDir(document_path)
        return sidecar_dir .. "/koassistant_pinned.lua"
    end
end

--- Check alternate storage mode locations for a sidecar file (lazy migration on mode switch)
--- Only applies to book-context paths (not general/multi-book which use settings dir)
--- @param document_path string The document file path
--- @param current_path string The expected path in current storage mode
--- @param filename string The sidecar filename
--- @return boolean migrated Whether a file was migrated to current_path
local function migrateSidecarIfNeeded(document_path, current_path, filename)
    -- Skip for non-book contexts (stored in settings dir, not sidecar)
    if document_path == PinnedManager.GENERAL_KEY
        or document_path == PinnedManager.MULTI_BOOK_KEY then
        return false
    end
    local current = G_reader_settings:readSetting("document_metadata_folder", "doc")
    local alternates = { "doc", "dir" }
    if DocSettings.isHashLocationEnabled() then
        table.insert(alternates, "hash")
    end
    for _idx, loc in ipairs(alternates) do
        if loc ~= current then
            local alt_dir = DocSettings:getSidecarDir(document_path, loc)
            local alt_path = alt_dir .. "/" .. filename
            if lfs.attributes(alt_path, "mode") == "file" then
                local util = require("util")
                local dir = current_path:match("(.*/)") or ""
                if dir ~= "" then util.makePath(dir) end
                local ok, err = os.rename(alt_path, current_path)
                if ok then
                    logger.info("KOAssistant: Migrated sidecar file", filename, "from alternate storage location")
                    return true
                else
                    logger.warn("KOAssistant: Failed to migrate sidecar file", filename, ":", err)
                end
            end
        end
    end
    return false
end

--- Load pinned artifacts from file.
--- @param document_path string Document path or special key
--- @return table Array of pinned entries
local function loadPinned(document_path)
    local path = PinnedManager.getPath(document_path)
    if not path then return {} end

    local attr = lfs.attributes(path)
    if not attr or attr.mode ~= "file" then
        -- Try alternate storage mode locations (lazy migration on mode switch)
        if not migrateSidecarIfNeeded(document_path, path, "koassistant_pinned.lua") then
            return {}
        end
    end

    local ok, data = pcall(dofile, path)
    if ok and type(data) == "table" then
        return data
    else
        logger.warn("KOAssistant PinnedManager: Failed to load:", path)
        return {}
    end
end

--- Save pinned artifacts to file with safe serialization.
--- @param document_path string Document path or special key
--- @param pinned table Array of pinned entries
--- @return boolean success
local function savePinned(document_path, pinned)
    local path = PinnedManager.getPath(document_path)
    if not path then return false end

    -- Ensure directory exists
    local util = require("util")
    local dir = path:match("(.*/)")
    if dir then
        util.makePath(dir)
    end

    local file, err = io.open(path, "w")
    if not file then
        logger.err("KOAssistant PinnedManager: Failed to open for writing:", err)
        return false
    end

    file:write("return {\n")
    for _idx, entry in ipairs(pinned) do
        if type(entry) == "table" then
            file:write("    {\n")
            file:write(string.format("        id = %q,\n", entry.id or ""))
            file:write(string.format("        action_id = %q,\n", entry.action_id or "chat"))
            file:write(string.format("        action_text = %q,\n", entry.action_text or ""))
            if entry.name then
                file:write(string.format("        name = %q,\n", entry.name))
            end
            file:write(string.format("        timestamp = %s,\n", tostring(entry.timestamp or 0)))
            file:write(string.format("        model = %q,\n", entry.model or ""))
            file:write(string.format("        context_type = %q,\n", entry.context_type or "book"))
            file:write(string.format("        version = %s,\n", tostring(entry.version or PINNED_VERSION)))
            if entry.book_title then
                file:write(string.format("        book_title = %q,\n", entry.book_title))
            end
            if entry.book_author then
                file:write(string.format("        book_author = %q,\n", entry.book_author))
            end
            if entry.document_path then
                file:write(string.format("        document_path = %q,\n", entry.document_path))
            end
            -- Long string fields (may contain special characters)
            writeLongString(file, "        ", "result", entry.result)
            writeLongString(file, "        ", "user_prompt", entry.user_prompt)
            file:write("    },\n")
        end
    end
    file:write("}\n")
    file:close()

    logger.info("KOAssistant PinnedManager: Saved pinned for", document_path)
    return true
end

--- Update the pinned index in G_reader_settings.
--- Tracks count and last modified timestamp per document.
--- @param document_path string Document path or special key
--- @param pinned table|nil Array of pinned entries (nil = removed)
local function updatePinnedIndex(document_path, pinned)
    local index = G_reader_settings:readSetting("koassistant_pinned_index", {})

    local changed = false
    if pinned and #pinned > 0 then
        -- Find latest timestamp
        local latest = 0
        for _idx, entry in ipairs(pinned) do
            if (entry.timestamp or 0) > latest then
                latest = entry.timestamp or 0
            end
        end
        local prev = index[document_path]
        if not prev or prev.count ~= #pinned or prev.modified ~= latest then
            index[document_path] = { count = #pinned, modified = latest }
            changed = true
        end
    elseif index[document_path] then
        index[document_path] = nil
        changed = true
    end

    if changed then
        G_reader_settings:saveSetting("koassistant_pinned_index", index)
        G_reader_settings:flush()
    end
end

--- Invalidate file browser dialog row cache so pin changes are reflected.
--- The file browser caches button rows per-file; pin add/remove must clear it.
local function invalidateFileDialogCache()
    local ok1, FileManager = pcall(require, "apps/filemanager/filemanager")
    if ok1 and FileManager.instance and FileManager.instance.koassistant then
        FileManager.instance.koassistant._file_dialog_row_cache = { file = nil, rows = nil }
    end
    local ok2, ReaderUI = pcall(require, "apps/reader/readerui")
    if ok2 and ReaderUI.instance and ReaderUI.instance.koassistant then
        ReaderUI.instance.koassistant._file_dialog_row_cache = { file = nil, rows = nil }
    end
end

--- Add a pinned artifact.
--- @param document_path string Document path or special key
--- @param entry table Pinned entry (must include id, result, action_text, etc.)
--- @return boolean success
function PinnedManager.addPin(document_path, entry)
    if not document_path or not entry or not entry.result then
        return false
    end
    entry.version = PINNED_VERSION
    entry.timestamp = entry.timestamp or os.time()

    local pinned = loadPinned(document_path)
    table.insert(pinned, entry)

    local ok = savePinned(document_path, pinned)
    if ok then
        updatePinnedIndex(document_path, pinned)
        invalidateFileDialogCache()
    end
    return ok
end

--- Remove a pinned artifact by ID.
--- @param document_path string Document path or special key
--- @param pin_id string The pin ID to remove
--- @return boolean success
function PinnedManager.removePin(document_path, pin_id)
    if not document_path or not pin_id then return false end

    local pinned = loadPinned(document_path)
    local found = false
    for i = #pinned, 1, -1 do
        if pinned[i].id == pin_id then
            table.remove(pinned, i)
            found = true
            break
        end
    end

    if not found then return false end

    local ok
    if #pinned == 0 then
        -- Remove file entirely
        local path = PinnedManager.getPath(document_path)
        if path then
            os.remove(path)
            ok = true
        end
    else
        ok = savePinned(document_path, pinned)
    end

    if ok then
        updatePinnedIndex(document_path, #pinned > 0 and pinned or nil)
        invalidateFileDialogCache()
    end
    return ok or false
end

--- Update fields on an existing pinned artifact.
--- @param document_path string Document path or special key
--- @param pin_id string The pin ID to update
--- @param updates table Key-value pairs to merge into the entry
--- @return boolean success
function PinnedManager.updatePin(document_path, pin_id, updates)
    if not document_path or not pin_id or not updates then return false end

    local pinned = loadPinned(document_path)
    for _idx, entry in ipairs(pinned) do
        if entry.id == pin_id then
            for k, v in pairs(updates) do
                entry[k] = v
            end
            return savePinned(document_path, pinned) or false
        end
    end
    return false
end

--- Get all pinned artifacts for a document.
--- @param document_path string Document path or special key
--- @return table Array of pinned entries (newest first)
function PinnedManager.getPinnedForDocument(document_path)
    local pinned = loadPinned(document_path)
    -- Sort newest first
    table.sort(pinned, function(a, b)
        return (a.timestamp or 0) > (b.timestamp or 0)
    end)
    return pinned
end

--- Get general pinned artifacts.
--- @return table Array of pinned entries
function PinnedManager.getGeneralPinned()
    return PinnedManager.getPinnedForDocument(PinnedManager.GENERAL_KEY)
end

--- Get multi-book pinned artifacts.
--- @return table Array of pinned entries
function PinnedManager.getMultiBookPinned()
    return PinnedManager.getPinnedForDocument(PinnedManager.MULTI_BOOK_KEY)
end

--- Get pinned count for a document (from index, no file I/O).
--- @param document_path string Document path or special key
--- @return number count
function PinnedManager.getPinnedCount(document_path)
    local index = G_reader_settings:readSetting("koassistant_pinned_index", {})
    local entry = index[document_path]
    return entry and entry.count or 0
end

--- Check if any pinned artifacts exist for a document.
--- @param document_path string Document path or special key
--- @return boolean
function PinnedManager.hasPinned(document_path)
    return PinnedManager.getPinnedCount(document_path) > 0
end

--- Get full pinned index (all documents with pinned artifacts).
--- @return table { [document_path] = { count, modified } }
function PinnedManager.getPinnedIndex()
    return G_reader_settings:readSetting("koassistant_pinned_index", {})
end

--- Generate a unique pin ID.
--- @return string id Format: "pin_<timestamp>_<random>"
function PinnedManager.generateId()
    return "pin_" .. os.time() .. "_" .. tostring(math.random(100000, 999999))
end

return PinnedManager
