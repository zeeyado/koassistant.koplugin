--[[--
Action Cache module for KOAssistant - Per-book response caching for X-Ray/Recap

Enables incremental updates: when user runs X-Ray at 30%, then again at 50%,
the second request sends only the new content (30%-50%) plus the cached response.

Cache is stored in sidecar directory (auto-moves with books).
Only caches when book text extraction is enabled AND used.

@module koassistant_action_cache
]]

local DocSettings = require("docsettings")
local lfs = require("libs/libkoreader-lfs")
local logger = require("logger")

local ActionCache = {}

-- Cache format version (increment if structure changes)
local CACHE_VERSION = 1

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
            -- Result may contain special characters, use long string
            file:write("        result = [==[\n")
            file:write(entry.result or "")
            file:write("\n]==],\n")
            file:write("    },\n")
        end
    end
    file:write("}\n")
    file:close()

    logger.info("KOAssistant ActionCache: Saved cache for", document_path)
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
--- @param metadata table Optional metadata: { model = "model-name" }
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
    return true
end

--- Check if cache exists for an action
--- @param document_path string The document file path
--- @param action_id string The action ID to check
--- @return boolean exists Whether a cache entry exists
function ActionCache.exists(document_path, action_id)
    return ActionCache.get(document_path, action_id) ~= nil
end

return ActionCache
