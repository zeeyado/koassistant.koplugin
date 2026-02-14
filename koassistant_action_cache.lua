--[[--
Action Cache module for KOAssistant - Per-book response caching for X-Ray/Recap

Enables incremental updates: when user runs X-Ray at 30%, then again at 50%,
the second request sends only the new content (30%-50%) plus the cached response.

Cache is stored in sidecar directory (auto-moves with books).
Caches results regardless of text extraction. Tracks used_book_text metadata
for dynamic permission gating (caches built without text don't require
text extraction permission to read).

@module koassistant_action_cache
]]

local DocSettings = require("docsettings")
local lfs = require("libs/libkoreader-lfs")
local logger = require("logger")
local _ = require("koassistant_gettext")

local ActionCache = {}

-- Cache format version (increment if structure changes)
-- v2: Added used_annotations and used_book_text fields to track permission state when cache was built
local CACHE_VERSION = 2

-- Artifact keys tracked in the browsing index
local ARTIFACT_KEYS = { "_xray_cache", "_summary_cache", "_analyze_cache", "recap", "xray_simple", "book_info", "analyze_highlights" }

--- Update the artifact index in g_reader_settings after any cache mutation.
--- Scans the in-memory cache table for known artifact keys and updates the index entry.
--- @param document_path string The document file path
--- @param cache table|nil The current cache table (nil = removed)
local function updateArtifactIndex(document_path, cache)
    if not document_path
        or document_path == "__GENERAL_CHATS__"
        or document_path == "__MULTI_BOOK_CHATS__" then
        return
    end

    local index = G_reader_settings:readSetting("koassistant_artifact_index", {})

    if not cache then
        -- Cache file deleted
        if index[document_path] then
            index[document_path] = nil
            G_reader_settings:saveSetting("koassistant_artifact_index", index)
            G_reader_settings:flush()
        end
        return
    end

    -- Count valid artifact entries and find most recent timestamp
    local count = 0
    local latest = 0
    for _idx, key in ipairs(ARTIFACT_KEYS) do
        local entry = cache[key]
        if entry and type(entry) == "table" and entry.version == CACHE_VERSION and entry.result then
            count = count + 1
            if (entry.timestamp or 0) > latest then
                latest = entry.timestamp or 0
            end
        end
    end

    local changed = false
    if count > 0 then
        local prev = index[document_path]
        if not prev or prev.count ~= count or prev.modified ~= latest then
            index[document_path] = { modified = latest, count = count }
            changed = true
        end
    elseif index[document_path] then
        index[document_path] = nil
        changed = true
    end

    if changed then
        G_reader_settings:saveSetting("koassistant_artifact_index", index)
        G_reader_settings:flush()
    end
end

--- Find a safe long string delimiter for content that won't appear in the text
--- Returns number of = signs needed (0 means use [[]], 1 means [=[]=], etc.)
--- @param content string The content to wrap
--- @return number equals Number of = signs needed for safe delimiter
local function findSafeDelimiter(content)
    if not content then return 2 end
    -- Start with 2 equals (standard), check if ]]==] appears
    -- If so, try 3, 4, etc. until safe
    for equals = 2, 10 do
        local closing = "]" .. string.rep("=", equals) .. "]"
        if not content:find(closing, 1, true) then
            return equals
        end
    end
    return 10 -- Fallback (extremely unlikely to need more)
end

--- Get cache file path for a document
--- @param document_path string The document file path
--- @return string|nil cache_path The full path to the cache file
function ActionCache.getPath(document_path)
    if not document_path
        or document_path == "__GENERAL_CHATS__"
        or document_path == "__MULTI_BOOK_CHATS__" then
        return nil
    end
    local sidecar_dir = DocSettings:getSidecarDir(document_path)
    return sidecar_dir .. "/koassistant_cache.lua"
end

--- Load cache from file
--- @param document_path string The document file path
--- @return table cache The cache table (empty if not found)
local function loadCache(document_path)
    local path = ActionCache.getPath(document_path)
    if not path then return {} end

    local attr = lfs.attributes(path)
    if not attr or attr.mode ~= "file" then
        return {}
    end

    local ok, cache = pcall(dofile, path)
    if ok and type(cache) == "table" then
        return cache
    else
        logger.warn("KOAssistant ActionCache: Failed to load cache:", path)
        return {}
    end
end

--- Save cache to file
--- @param document_path string The document file path
--- @param cache table The cache table to save
--- @return boolean success Whether save succeeded
local function saveCache(document_path, cache)
    local path = ActionCache.getPath(document_path)
    if not path then return false end

    -- Ensure sidecar directory exists
    local util = require("util")
    local dir = path:match("(.*/)")
    if dir then
        util.makePath(dir)
    end

    local file, err = io.open(path, "w")
    if not file then
        logger.err("KOAssistant ActionCache: Failed to open file for writing:", err)
        return false
    end

    -- Write as Lua table
    file:write("return {\n")
    for action_id, entry in pairs(cache) do
        if type(entry) == "table" then
            file:write(string.format("    [%q] = {\n", action_id))
            file:write(string.format("        progress_decimal = %s,\n", tostring(entry.progress_decimal or 0)))
            file:write(string.format("        timestamp = %s,\n", tostring(entry.timestamp or 0)))
            file:write(string.format("        model = %q,\n", entry.model or ""))
            file:write(string.format("        version = %s,\n", tostring(entry.version or CACHE_VERSION)))
            -- Track permission state when cache was built
            if entry.used_highlights ~= nil then
                file:write(string.format("        used_highlights = %s,\n", tostring(entry.used_highlights)))
            end
            if entry.used_annotations ~= nil then
                file:write(string.format("        used_annotations = %s,\n", tostring(entry.used_annotations)))
            end
            if entry.used_book_text ~= nil then
                file:write(string.format("        used_book_text = %s,\n", tostring(entry.used_book_text)))
            end
            if entry.previous_progress_decimal then
                file:write(string.format("        previous_progress_decimal = %s,\n", tostring(entry.previous_progress_decimal)))
            end
            if entry.flow_visible_pages then
                file:write(string.format("        flow_visible_pages = %s,\n", tostring(entry.flow_visible_pages)))
            end
            if entry.progress_page then
                file:write(string.format("        progress_page = %s,\n", tostring(entry.progress_page)))
            end
            if entry.full_document then
                file:write(string.format("        full_document = %s,\n", tostring(entry.full_document)))
            end
            if entry.used_reasoning then
                file:write(string.format("        used_reasoning = %s,\n", tostring(entry.used_reasoning)))
            end
            if entry.web_search_used then
                file:write(string.format("        web_search_used = %s,\n", tostring(entry.web_search_used)))
            end
            -- Result may contain special characters, use long string with safe delimiter
            local result_text = entry.result or ""
            local eq_count = findSafeDelimiter(result_text)
            local eq_str = string.rep("=", eq_count)
            file:write(string.format("        result = [%s[\n", eq_str))
            file:write(result_text)
            file:write(string.format("\n]%s],\n", eq_str))
            file:write("    },\n")
        end
    end
    file:write("}\n")
    file:close()

    logger.info("KOAssistant ActionCache: Saved cache for", document_path)
    updateArtifactIndex(document_path, cache)
    return true
end

--- Get cached entry for an action
--- @param document_path string The document file path
--- @param action_id string The action ID (e.g., "xray", "recap")
--- @return table|nil entry The cached entry, or nil if not found
function ActionCache.get(document_path, action_id)
    local cache = loadCache(document_path)
    local entry = cache[action_id]
    if entry and entry.version == CACHE_VERSION then
        return entry
    end
    -- Ignore entries with old version
    return nil
end

--- Save an entry to cache
--- @param document_path string The document file path
--- @param action_id string The action ID (e.g., "xray", "recap")
--- @param result string The AI response text
--- @param progress_decimal number Progress as decimal (0.0-1.0)
--- @param metadata table Optional metadata: { model = "model-name", used_annotations = true/false, used_book_text = true/false, previous_progress_decimal = number }
--- @return boolean success Whether save succeeded
function ActionCache.set(document_path, action_id, result, progress_decimal, metadata)
    if not document_path or not action_id or not result then
        return false
    end

    local cache = loadCache(document_path)
    cache[action_id] = {
        progress_decimal = progress_decimal or 0,
        timestamp = os.time(),
        model = metadata and metadata.model or "",
        result = result,
        version = CACHE_VERSION,
        -- Track permission state when cache was built
        used_annotations = metadata and metadata.used_annotations,
        used_book_text = metadata and metadata.used_book_text,
        -- Track incremental update origin
        previous_progress_decimal = metadata and metadata.previous_progress_decimal,
        -- Track hidden flow state when cache was built (nil = no hidden flows)
        flow_visible_pages = metadata and metadata.flow_visible_pages,
        -- Raw page number for extraction math (flow-aware progress can't be used for page calculations)
        progress_page = metadata and metadata.progress_page,
        -- Full-document X-Ray (entire document, not spoiler-free)
        full_document = metadata and metadata.full_document,
        -- Track reasoning and web search usage
        used_reasoning = metadata and metadata.used_reasoning,
        web_search_used = metadata and metadata.web_search_used,
    }

    return saveCache(document_path, cache)
end

--- Clear cached entry for an action
--- @param document_path string The document file path
--- @param action_id string The action ID to clear
--- @return boolean success Whether clear succeeded
function ActionCache.clear(document_path, action_id)
    local cache = loadCache(document_path)
    if cache[action_id] then
        cache[action_id] = nil
        return saveCache(document_path, cache)
    end
    return true -- Nothing to clear
end

--- Clear all cached entries for a document
--- @param document_path string The document file path
--- @return boolean success Whether clear succeeded
function ActionCache.clearAll(document_path)
    local path = ActionCache.getPath(document_path)
    if not path then return false end

    local attr = lfs.attributes(path)
    if attr and attr.mode == "file" then
        os.remove(path)
        logger.info("KOAssistant ActionCache: Cleared all cache for", document_path)
    end
    updateArtifactIndex(document_path, nil)
    return true
end

--- Check if cache exists for an action
--- @param document_path string The document file path
--- @param action_id string The action ID to check
--- @return boolean exists Whether a cache entry exists
function ActionCache.exists(document_path, action_id)
    return ActionCache.get(document_path, action_id) ~= nil
end

--- Refresh the artifact index for a document by loading its cache.
--- Call this when artifacts are discovered through read-only paths (e.g., viewCache).
--- @param document_path string The document file path
function ActionCache.refreshIndex(document_path)
    local cache = loadCache(document_path)
    updateArtifactIndex(document_path, next(cache) and cache or nil)
end

-- =============================================================================
-- Document Cache API
-- Reserved cache keys for reusable document caches that other actions can reference
-- =============================================================================

-- Reserved keys for document caches (prefixed with _ to avoid collision with action IDs)
ActionCache.XRAY_CACHE_KEY = "_xray_cache"
ActionCache.ANALYZE_CACHE_KEY = "_analyze_cache"
ActionCache.SUMMARY_CACHE_KEY = "_summary_cache"
ActionCache.ARTIFACT_KEYS = ARTIFACT_KEYS

-- Human-readable names for artifact keys
local ARTIFACT_NAMES = {
    ["_xray_cache"] = "X-Ray",
    ["_summary_cache"] = _("Summary"),
    ["_analyze_cache"] = _("Analysis"),
    ["recap"] = _("Recap"),
    ["xray_simple"] = _("X-Ray (Simple)"),
    ["book_info"] = _("Book Info"),
    ["analyze_highlights"] = _("Notes Analysis"),
}
ActionCache.ARTIFACT_NAMES = ARTIFACT_NAMES

-- Artifact keys that are per-action caches (vs document-level caches)
local PER_ACTION_ARTIFACTS = { recap = true, xray_simple = true, book_info = true, analyze_highlights = true }

--- Get available artifacts for a document file.
--- Central source of truth for discovering cached artifacts.
--- @param document_path string The document file path
--- @param exclude_key string|nil Optional artifact key to exclude (e.g. "_xray_cache" when viewing X-Ray)
--- @return table Array of { name, key, data, is_per_action } entries
function ActionCache.getAvailableArtifacts(document_path, exclude_key)
    if not document_path then return {} end
    local available = {}
    for _idx, key in ipairs(ARTIFACT_KEYS) do
        if key ~= exclude_key then
            local entry = ActionCache.get(document_path, key)
            if entry and entry.result then
                table.insert(available, {
                    name = ARTIFACT_NAMES[key] or key,
                    key = key,
                    data = entry,
                    is_per_action = PER_ACTION_ARTIFACTS[key] or false,
                })
            end
        end
    end
    return available
end

--- Get cached X-Ray (partial document analysis to reading position)
--- @param document_path string The document file path
--- @return table|nil entry { result, progress_decimal, timestamp, model, used_annotations, used_book_text } or nil
---   used_annotations: Whether annotations were included when building this cache.
---   used_book_text: Whether book text extraction was used. false = AI training data only.
---   Use these to determine what permissions are required to read the cache.
function ActionCache.getXrayCache(document_path)
    return ActionCache.get(document_path, ActionCache.XRAY_CACHE_KEY)
end

--- Save X-Ray to reusable cache
--- @param document_path string The document file path
--- @param result string The X-Ray text
--- @param progress_decimal number Progress as decimal (0.0-1.0)
--- @param metadata table Optional: { model = "model-name", used_annotations = true/false, used_book_text = true/false }
---   used_annotations: Track whether annotations were included when building this cache.
---   used_book_text: Track whether book text extraction was used. false = AI training data only.
---   When reading the cache, permissions are only required for data that was actually used.
--- @return boolean success
function ActionCache.setXrayCache(document_path, result, progress_decimal, metadata)
    return ActionCache.set(document_path, ActionCache.XRAY_CACHE_KEY, result, progress_decimal, metadata)
end

--- Get cached document analysis (full document deep analysis)
--- @param document_path string The document file path
--- @return table|nil entry { result, progress_decimal, timestamp, model, used_book_text } or nil
---   used_book_text: Whether book text extraction was used. false = AI training data only.
function ActionCache.getAnalyzeCache(document_path)
    return ActionCache.get(document_path, ActionCache.ANALYZE_CACHE_KEY)
end

--- Save document analysis to reusable cache
--- @param document_path string The document file path
--- @param result string The analysis text
--- @param progress_decimal number Progress (typically 1.0 for full document)
--- @param metadata table Optional: { model = "model-name", used_book_text = true/false }
--- @return boolean success
function ActionCache.setAnalyzeCache(document_path, result, progress_decimal, metadata)
    return ActionCache.set(document_path, ActionCache.ANALYZE_CACHE_KEY, result, progress_decimal, metadata)
end

--- Get cached document summary (full document summary)
--- @param document_path string The document file path
--- @return table|nil entry { result, progress_decimal, timestamp, model, used_book_text } or nil
---   used_book_text: Whether book text extraction was used. false = AI training data only.
function ActionCache.getSummaryCache(document_path)
    return ActionCache.get(document_path, ActionCache.SUMMARY_CACHE_KEY)
end

--- Save document summary to reusable cache
--- @param document_path string The document file path
--- @param result string The summary text
--- @param progress_decimal number Progress (typically 1.0 for full document)
--- @param metadata table Optional: { model = "model-name", used_book_text = true/false }
--- @return boolean success
function ActionCache.setSummaryCache(document_path, result, progress_decimal, metadata)
    return ActionCache.set(document_path, ActionCache.SUMMARY_CACHE_KEY, result, progress_decimal, metadata)
end

--- Clear X-Ray cache
--- @param document_path string The document file path
--- @return boolean success
function ActionCache.clearXrayCache(document_path)
    return ActionCache.clear(document_path, ActionCache.XRAY_CACHE_KEY)
end

--- Clear document analysis cache
--- @param document_path string The document file path
--- @return boolean success
function ActionCache.clearAnalyzeCache(document_path)
    return ActionCache.clear(document_path, ActionCache.ANALYZE_CACHE_KEY)
end

--- Clear document summary cache
--- @param document_path string The document file path
--- @return boolean success
function ActionCache.clearSummaryCache(document_path)
    return ActionCache.clear(document_path, ActionCache.SUMMARY_CACHE_KEY)
end

--- Get path to user aliases file for a document
--- @param document_path string The document file path
--- @return string|nil path Full path, or nil if not applicable
function ActionCache.getUserAliasesPath(document_path)
    if not document_path
        or document_path == "__GENERAL_CHATS__"
        or document_path == "__MULTI_BOOK_CHATS__" then
        return nil
    end
    local sidecar_dir = DocSettings:getSidecarDir(document_path)
    return sidecar_dir .. "/koassistant_user_aliases.lua"
end

--- Load user-defined search term edits for X-Ray items
--- Format: { [item_name] = { add = { ... }, ignore = { ... } } }
--- Backward compatible with old format { [item_name] = { "alias1", "alias2" } }
--- @param document_path string The document file path
--- @return table aliases Mapping of item name → { add = {...}, ignore = {...} }
function ActionCache.getUserAliases(document_path)
    local path = ActionCache.getUserAliasesPath(document_path)
    if not path then return {} end

    local attr = lfs.attributes(path)
    if not attr or attr.mode ~= "file" then
        return {}
    end

    local ok, data = pcall(dofile, path)
    if not ok or type(data) ~= "table" then
        logger.warn("KOAssistant ActionCache: Failed to load user aliases:", path)
        return {}
    end

    -- Normalize: old format { [name] = { "a", "b" } } → { [name] = { add = { "a", "b" } } }
    for name, entry in pairs(data) do
        if type(entry) == "table" and not entry.add and not entry.ignore then
            -- Old format: plain array of strings
            data[name] = { add = entry }
        end
    end
    return data
end

--- Save user-defined search term edits for X-Ray items
--- @param document_path string The document file path
--- @param aliases_table table Mapping of item name → { add = {...}, ignore = {...} }
--- @return boolean success Whether save succeeded
function ActionCache.setUserAliases(document_path, aliases_table)
    local path = ActionCache.getUserAliasesPath(document_path)
    if not path then return false end

    -- Remove entries with no content
    for name, entry in pairs(aliases_table) do
        if type(entry) ~= "table" then
            aliases_table[name] = nil
        else
            local add = entry.add or {}
            local ignore = entry.ignore or {}
            if #add == 0 and #ignore == 0 then
                aliases_table[name] = nil
            end
        end
    end

    -- If nothing left, remove the file
    if not next(aliases_table) then
        os.remove(path)
        return true
    end

    -- Ensure sidecar directory exists
    local util = require("util")
    local dir = path:match("(.*/)")
    if dir then
        util.makePath(dir)
    end

    local file, err = io.open(path, "w")
    if not file then
        logger.err("KOAssistant ActionCache: Failed to open user aliases file for writing:", err)
        return false
    end

    local function write_array(f, arr)
        if not arr or #arr == 0 then
            f:write("{}")
            return
        end
        f:write("{ ")
        for i, val in ipairs(arr) do
            f:write(string.format("%q", val))
            if i < #arr then f:write(", ") end
        end
        f:write(" }")
    end

    file:write("return {\n")
    for item_name, entry in pairs(aliases_table) do
        file:write(string.format("    [%q] = { add = ", item_name))
        write_array(file, entry.add)
        if entry.ignore and #entry.ignore > 0 then
            file:write(", ignore = ")
            write_array(file, entry.ignore)
        end
        file:write(" },\n")
    end
    file:write("}\n")
    file:close()

    logger.info("KOAssistant ActionCache: Saved user aliases for", document_path)
    return true
end

return ActionCache
