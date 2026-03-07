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
local T = require("ffi/util").template
local _ = require("koassistant_gettext")

local ActionCache = {}

--- Check alternate storage mode locations for a sidecar file (lazy migration on mode switch)
--- @param document_path string The document file path
--- @param filename string The sidecar filename (e.g., "koassistant_cache.lua")
--- @return string|nil alternate_path Path at alternate location if found
local function findSidecarInAlternateLocation(document_path, filename)
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
                return alt_path
            end
        end
    end
    return nil
end

--- Attempt to migrate a sidecar file from an alternate storage mode location
--- @param document_path string The document file path
--- @param current_path string The expected path in current storage mode
--- @param filename string The sidecar filename
--- @return boolean migrated Whether a file was migrated to current_path
local function migrateSidecarIfNeeded(document_path, current_path, filename)
    local alt = findSidecarInAlternateLocation(document_path, filename)
    if alt then
        local util = require("util")
        local dir = current_path:match("(.*/)") or ""
        if dir ~= "" then util.makePath(dir) end
        local ok, err = os.rename(alt, current_path)
        if ok then
            logger.info("KOAssistant: Migrated sidecar file", filename, "from alternate storage location")
            return true
        else
            logger.warn("KOAssistant: Failed to migrate sidecar file", filename, ":", err)
        end
    end
    return false
end

-- Cache format version (increment if structure changes)
-- v2: Added used_annotations and used_book_text fields to track permission state when cache was built
local CACHE_VERSION = 2

-- Artifact keys tracked in the browsing index
local ARTIFACT_KEYS = { "_xray_cache", "_summary_cache", "_analyze_cache", "recap", "xray_simple", "book_info", "analyze_highlights", "key_arguments", "discussion_questions", "generate_quiz", "extract_insights" }

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
    -- Also count section X-Ray and wiki entries (prefix scan)
    local section_prefix = ActionCache.SECTION_XRAY_PREFIX
    local section_prefix_len = #section_prefix
    local wiki_prefix = ActionCache.WIKI_PREFIX
    local wiki_prefix_len = #wiki_prefix
    for key, entry in pairs(cache) do
        if type(key) == "string" and type(entry) == "table"
           and entry.version == CACHE_VERSION and entry.result then
            if key:sub(1, section_prefix_len) == section_prefix
               or key:sub(1, wiki_prefix_len) == wiki_prefix then
                count = count + 1
                if (entry.timestamp or 0) > latest then
                    latest = entry.timestamp or 0
                end
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
        -- Try alternate storage mode locations (lazy migration on mode switch)
        if not migrateSidecarIfNeeded(document_path, path, "koassistant_cache.lua") then
            return {}
        end
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
            if entry.source_mode then
                file:write(string.format("        source_mode = %q,\n", entry.source_mode))
            end
            if entry.unavailable_data_text then
                file:write(string.format("        unavailable_data_text = %q,\n", entry.unavailable_data_text))
            end
            -- Section X-Ray scope metadata
            if entry.scope_label then
                file:write(string.format("        scope_label = %q,\n", entry.scope_label))
            end
            if entry.scope_start_page then
                file:write(string.format("        scope_start_page = %s,\n", tostring(entry.scope_start_page)))
            end
            if entry.scope_end_page then
                file:write(string.format("        scope_end_page = %s,\n", tostring(entry.scope_end_page)))
            end
            if entry.scope_start_xpointer then
                file:write(string.format("        scope_start_xpointer = %q,\n", entry.scope_start_xpointer))
            end
            if entry.scope_end_xpointer then
                file:write(string.format("        scope_end_xpointer = %q,\n", entry.scope_end_xpointer))
            end
            if entry.scope_page_summary then
                file:write(string.format("        scope_page_summary = %q,\n", entry.scope_page_summary))
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
        -- Track source mode at generation time (for source indication in viewers)
        source_mode = metadata and metadata.source_mode,
        -- Track unavailable data at generation time (pre-formatted string for artifact viewer)
        unavailable_data_text = metadata and metadata.unavailable_data_text,
        -- Section X-Ray scope metadata
        scope_label = metadata and metadata.scope_label,
        scope_start_page = metadata and metadata.scope_start_page,
        scope_end_page = metadata and metadata.scope_end_page,
        scope_start_xpointer = metadata and metadata.scope_start_xpointer,
        scope_end_xpointer = metadata and metadata.scope_end_xpointer,
        scope_page_summary = metadata and metadata.scope_page_summary,
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
    ["key_arguments"] = _("Key Arguments"),
    ["discussion_questions"] = _("Discussion Questions"),
    ["generate_quiz"] = _("Generate Quiz"),
    ["extract_insights"] = _("Key Insights"),
}
ActionCache.ARTIFACT_NAMES = ARTIFACT_NAMES

-- Artifact keys that are per-action caches (vs document-level caches)
local PER_ACTION_ARTIFACTS = {
    recap = true, xray_simple = true, book_info = true, analyze_highlights = true,
    key_arguments = true, discussion_questions = true, generate_quiz = true, extract_insights = true,
}

--- Get available artifacts for a document file.
--- Central source of truth for discovering cached artifacts.
--- @param document_path string The document file path
--- @param exclude_key string|nil Optional artifact key to exclude (e.g. "_xray_cache" when viewing X-Ray)
--- @param doc table|nil Document object — when provided, section X-Rays covering the current page are promoted to top-level entries
--- @return table Array of { name, key, data, is_per_action } entries
function ActionCache.getAvailableArtifacts(document_path, exclude_key, doc)
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
    -- Add section X-Ray entries as a group (no position-based promotion here;
    -- surfacing is done in the action popups themselves)
    local sections = ActionCache.getSectionXrays(document_path)
    if #sections > 0 then
        local count = #sections
        if exclude_key then
            for _idx, sec in ipairs(sections) do
                if sec.key == exclude_key then
                    count = count - 1
                    break
                end
            end
        end
        if count > 0 then
            table.insert(available, {
                name = string.format(_("Section X-Rays (%d)"), #sections),
                key = "_xray_sections",
                data = sections,
                is_section_xray_group = true,
                is_section_group = true,
                section_type = "xray",
                _excluded_section_key = exclude_key,
            })
        end
    end
    -- Add non-X-Ray section groups
    local other_section_types = { "summary", "analyze", "key_arguments",
        "discussion_questions", "generate_quiz", "extract_insights" }
    for _idx, sec_type in ipairs(other_section_types) do
        local prefix = ActionCache.SECTION_PREFIXES[sec_type]
        if prefix then
            local type_sections = ActionCache.getSections(document_path, prefix)
            if #type_sections > 0 then
                local type_count = #type_sections
                if exclude_key then
                    for _idx2, sec in ipairs(type_sections) do
                        if sec.key == exclude_key then
                            type_count = type_count - 1
                            break
                        end
                    end
                end
                if type_count > 0 then
                    table.insert(available, {
                        name = string.format("%s (%d)", ActionCache.SECTION_GROUP_NAMES[sec_type] or sec_type, #type_sections),
                        key = "_" .. sec_type .. "_sections",
                        data = type_sections,
                        is_section_group = true,
                        section_type = sec_type,
                        _excluded_section_key = exclude_key,
                    })
                end
            end
        end
    end
    -- Add wiki entries group if any exist
    local wikis = ActionCache.getWikiEntries(document_path)
    if #wikis > 0 then
        table.insert(available, {
            name = string.format(_("AI Wiki Entries (%d)"), #wikis),
            key = "_wiki_entries",
            data = wikis,
            is_wiki_group = true,
        })
    end
    return available
end

--- Get available artifacts + pinned artifacts for a document.
--- Combines cached artifacts from getAvailableArtifacts() with pinned artifacts from PinnedManager.
--- Pinned entries have is_pinned=true flag for caller to handle differently.
--- @param document_path string The document file path
--- @param exclude_key string|nil Optional artifact key to exclude
--- @param doc table|nil Document object — passed through to getAvailableArtifacts for section promotion
--- @return table Array of entries (cached + pinned)
function ActionCache.getAvailableArtifactsWithPinned(document_path, exclude_key, doc)
    local artifacts = ActionCache.getAvailableArtifacts(document_path, exclude_key, doc)
    if not document_path then return artifacts end

    local ok, PinnedManager = pcall(require, "koassistant_pinned_manager")
    if not ok or not PinnedManager then return artifacts end

    local pinned = PinnedManager.getPinnedForDocument(document_path)
    if #pinned > 0 then
        table.insert(artifacts, {
            name = string.format(_("Pinned Artifacts (%d)"), #pinned),
            key = "_pinned_artifacts",
            data = pinned,
            is_pinned_group = true,
        })
    end

    return artifacts
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

-- Section X-Ray prefix for per-section X-Ray entries (stored in same cache file)
ActionCache.SECTION_XRAY_PREFIX = "_xray_section:"

-- Section prefixes for all section-capable action types
-- Maps action_id (or document cache type) to its section prefix
ActionCache.SECTION_PREFIXES = {
    xray = "_xray_section:",
    summary = "_summary_section:",
    analyze = "_analyze_section:",
    key_arguments = "key_arguments_section:",
    discussion_questions = "discussion_questions_section:",
    generate_quiz = "generate_quiz_section:",
    extract_insights = "extract_insights_section:",
}

-- Human-readable names for section group display (plural for group titles)
ActionCache.SECTION_GROUP_NAMES = {
    xray = _("Section X-Rays"),
    summary = _("Section Summaries"),
    analyze = _("Section Analyses"),
    key_arguments = _("Section Key Arguments"),
    discussion_questions = _("Section Discussion Questions"),
    generate_quiz = _("Section Quizzes"),
    extract_insights = _("Section Key Insights"),
}

-- Singular type labels for individual section viewer titles
ActionCache.SECTION_TYPE_LABELS = {
    xray = _("X-Ray"),
    summary = _("Summary"),
    analyze = _("Analysis"),
    key_arguments = _("Key Arguments"),
    discussion_questions = _("Discussion Questions"),
    generate_quiz = _("Quiz"),
    extract_insights = _("Key Insights"),
}

-- Wiki entry prefix for per-item encyclopedia entries (stored in same cache file)
ActionCache.WIKI_PREFIX = "_wiki:"

--- Clear all wiki entries for a document
--- @param document_path string The document file path
--- @return boolean success
function ActionCache.clearWikiEntries(document_path)
    local cache = loadCache(document_path)
    local found = false
    local prefix_len = #ActionCache.WIKI_PREFIX
    for key, _v in pairs(cache) do
        if type(key) == "string" and key:sub(1, prefix_len) == ActionCache.WIKI_PREFIX then
            cache[key] = nil
            found = true
        end
    end
    if found then
        return saveCache(document_path, cache)
    end
    return true
end

--- Get a wiki entry for a specific item
--- @param document_path string The document file path
--- @param category_key string The X-Ray category (e.g., "characters")
--- @param item_name string The item name
--- @return table|nil cached entry
function ActionCache.getWikiEntry(document_path, category_key, item_name)
    return ActionCache.get(document_path, ActionCache.WIKI_PREFIX .. category_key .. ":" .. item_name)
end

--- Save a wiki entry for a specific item
--- @param document_path string The document file path
--- @param category_key string The X-Ray category
--- @param item_name string The item name
--- @param result string The wiki text
--- @param metadata table Optional: { model, used_reasoning, web_search_used }
--- @return boolean success
function ActionCache.setWikiEntry(document_path, category_key, item_name, result, metadata)
    return ActionCache.set(document_path, ActionCache.WIKI_PREFIX .. category_key .. ":" .. item_name, result, nil, metadata)
end

--- Clear a single wiki entry
--- @param document_path string The document file path
--- @param category_key string The X-Ray category
--- @param item_name string The item name
--- @return boolean success
function ActionCache.clearWikiEntry(document_path, category_key, item_name)
    return ActionCache.clear(document_path, ActionCache.WIKI_PREFIX .. category_key .. ":" .. item_name)
end

--- Get all wiki entries for a document, sorted alphabetically by item name.
--- @param document_path string The document file path
--- @return table Array of { key, label, category_key, item_name, data }
function ActionCache.getWikiEntries(document_path)
    if not document_path then return {} end
    local cache = loadCache(document_path)
    local entries = {}
    local prefix = ActionCache.WIKI_PREFIX
    local prefix_len = #prefix
    for key, entry in pairs(cache) do
        if type(key) == "string" and key:sub(1, prefix_len) == prefix
           and type(entry) == "table" and entry.version == CACHE_VERSION and entry.result then
            -- Key format: _wiki:category_key:item_name
            local rest = key:sub(prefix_len + 1)
            local cat_key, item_name = rest:match("^([^:]+):(.+)$")
            table.insert(entries, {
                key = key,
                label = item_name or rest,
                category_key = cat_key or "",
                item_name = item_name or rest,
                data = entry,
            })
        end
    end
    table.sort(entries, function(a, b)
        return (a.label or "") < (b.label or "")
    end)
    return entries
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
        -- Try alternate storage mode locations (lazy migration on mode switch)
        if not migrateSidecarIfNeeded(document_path, path, "koassistant_user_aliases.lua") then
            return {}
        end
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

-- =============================================================================
-- Section API (generic for all section-capable action types)
-- Each type uses a prefix: "_xray_section:", "_summary_section:", etc.
-- =============================================================================

--- Get all sections for a given prefix, sorted by start page.
--- @param document_path string The document file path
--- @param prefix string The section prefix (e.g., ActionCache.SECTION_XRAY_PREFIX)
--- @return table Array of { key, label, data } sorted by scope_start_page
function ActionCache.getSections(document_path, prefix)
    if not document_path or not prefix then return {} end
    local cache = loadCache(document_path)
    local sections = {}
    local prefix_len = #prefix
    for key, entry in pairs(cache) do
        if type(key) == "string" and key:sub(1, prefix_len) == prefix
           and type(entry) == "table" and entry.version == CACHE_VERSION and entry.result then
            table.insert(sections, {
                key = key,
                label = entry.scope_label or key:sub(prefix_len + 1),
                data = entry,
            })
        end
    end
    table.sort(sections, function(a, b)
        return (a.data.scope_start_page or 0) < (b.data.scope_start_page or 0)
    end)
    return sections
end

--- Get count of sections for a given prefix (lightweight, no full data load).
--- @param document_path string The document file path
--- @param prefix string The section prefix
--- @return number count
function ActionCache.getSectionCount(document_path, prefix)
    if not document_path or not prefix then return 0 end
    local cache = loadCache(document_path)
    local count = 0
    local prefix_len = #prefix
    for key, entry in pairs(cache) do
        if type(key) == "string" and key:sub(1, prefix_len) == prefix
           and type(entry) == "table" and entry.version == CACHE_VERSION and entry.result then
            count = count + 1
        end
    end
    return count
end

--- Clear all section entries for a given prefix.
--- @param document_path string The document file path
--- @param prefix string The section prefix
--- @return boolean success
function ActionCache.clearSections(document_path, prefix)
    if not prefix then return true end
    local cache = loadCache(document_path)
    local found = false
    local prefix_len = #prefix
    for key, _v in pairs(cache) do
        if type(key) == "string" and key:sub(1, prefix_len) == prefix then
            cache[key] = nil
            found = true
        end
    end
    if found then
        return saveCache(document_path, cache)
    end
    return true
end

--- Reconvert stored page summary using XPointers for font-size independence.
--- Returns the reconverted summary or the stored one if reconversion not possible.
--- @param data table Cache entry with scope_* fields
--- @param doc table|nil Document object with getPageFromXPointer method
--- @return string page_summary
function ActionCache.reconvertPageSummary(data, doc)
    if not data then return "" end
    if not doc or not doc.getPageFromXPointer then return data.scope_page_summary or "" end
    local start_xp = data.scope_start_xpointer
    if not start_xp then return data.scope_page_summary or "" end
    local new_start = doc:getPageFromXPointer(start_xp)
    local new_end
    local end_xp = data.scope_end_xpointer
    if end_xp then
        new_end = doc:getPageFromXPointer(end_xp)
        if new_end then new_end = new_end - 1 end
    else
        -- Last section: find last visible page (excluding hidden flows)
        local total = (doc.info and doc.info.number_of_pages) or 0
        if doc.hasHiddenFlows and doc:hasHiddenFlows() then
            for page = total, 1, -1 do
                if doc:getPageFlow(page) == 0 then
                    new_end = page
                    break
                end
            end
        else
            new_end = total
        end
    end
    if new_start and new_end then
        -- Convert to visible page numbers (excludes hidden flow pages like footnotes)
        if doc.getPageNumberInFlow then
            new_start = doc:getPageNumberInFlow(new_start)
            new_end = doc:getPageNumberInFlow(new_end)
        end
        return T(_("pp %1–%2"), new_start, new_end)
    end
    return data.scope_page_summary or ""
end

--- Get the section prefix for an action, based on its cache key or action ID.
--- @param action_id string The action ID or document cache type
--- @return string|nil prefix The section prefix, or nil if action doesn't support sections
function ActionCache.getSectionPrefix(action_id)
    -- Map document cache keys to their section type
    if action_id == "_xray_cache" or action_id == "xray" then return ActionCache.SECTION_PREFIXES.xray end
    if action_id == "_summary_cache" or action_id == "summarize_full_document" then return ActionCache.SECTION_PREFIXES.summary end
    if action_id == "_analyze_cache" or action_id == "analyze_full_document" then return ActionCache.SECTION_PREFIXES.analyze end
    return ActionCache.SECTION_PREFIXES[action_id]
end

-- Maps action IDs to SECTION_GROUP_NAMES keys (for actions whose ID differs from section type)
local SECTION_TYPE_FOR_ACTION = {
    summarize_full_document = "summary",
    analyze_full_document = "analyze",
}

--- Get the section group display name for a section type or action ID.
--- @param key string The section type key (e.g., "xray", "summary") or action ID (e.g., "summarize_full_document")
--- @return string|nil display name, or nil if not found
function ActionCache.getSectionGroupName(key)
    local section_type = SECTION_TYPE_FOR_ACTION[key] or key
    return ActionCache.SECTION_GROUP_NAMES[section_type]
end

-- Backward-compatible wrappers for X-Ray-specific callers

--- Get all section X-Rays for a document, sorted by start page.
--- @param document_path string The document file path
--- @return table Array of { key, label, data } sorted by scope_start_page
function ActionCache.getSectionXrays(document_path)
    return ActionCache.getSections(document_path, ActionCache.SECTION_XRAY_PREFIX)
end

--- Get count of section X-Rays for a document.
--- @param document_path string The document file path
--- @return number count
function ActionCache.getSectionXrayCount(document_path)
    return ActionCache.getSectionCount(document_path, ActionCache.SECTION_XRAY_PREFIX)
end

--- Clear all section X-Ray entries for a document.
--- @param document_path string The document file path
--- @return boolean success
function ActionCache.clearSectionXrays(document_path)
    return ActionCache.clearSections(document_path, ActionCache.SECTION_XRAY_PREFIX)
end

--- Check if any X-Ray exists for a document (main or section).
--- Lightweight check for button visibility gating.
--- @param document_path string The document file path
--- @return boolean
function ActionCache.hasAnyXray(document_path)
    if not document_path then return false end
    local cached = ActionCache.getXrayCache(document_path)
    if cached and cached.result then return true end
    return ActionCache.getSectionXrayCount(document_path) > 0
end


--- Get the current page number from a document object.
--- Handles both page-based (PDF) and flowing (EPUB) documents.
--- @param doc table Document object
--- @return number|nil current_page
local function getCurrentPageFromDoc(doc)
    if not doc then return nil end
    -- Guard: document must have pages (protects against unrendered documents)
    if not doc.info or not doc.info.number_of_pages or doc.info.number_of_pages == 0 then
        return nil
    end
    if doc.info.has_pages then
        -- PDF: not easily accessible without ui.view — fall back to xpointer
    end
    local xp = doc.getXPointer and doc:getXPointer()
    if xp and doc.getPageFromXPointer then
        return doc:getPageFromXPointer(xp)
    end
    return nil
end

--- Get the page range for a section X-Ray entry, using XPointers for accuracy.
--- Falls back to stored page numbers if XPointers not available.
--- @param data table Section cache entry with scope_* fields
--- @param doc table|nil Document object
--- @return number|nil start_page, number|nil end_page
local function getSectionPageRange(data, doc)
    if not data then return nil, nil end
    local start_page, end_page
    -- Try xpointer-based conversion first (font-size independent)
    if doc and doc.getPageFromXPointer then
        if data.scope_start_xpointer then
            start_page = doc:getPageFromXPointer(data.scope_start_xpointer)
        end
        if data.scope_end_xpointer then
            end_page = doc:getPageFromXPointer(data.scope_end_xpointer)
            if end_page then end_page = end_page - 1 end  -- end xpointer is exclusive
        elseif data.scope_start_xpointer then
            -- Last section: has start xpointer but no end → use last visible page
            local total = doc.info and doc.info.number_of_pages or 0
            if doc.hasHiddenFlows and doc:hasHiddenFlows() then
                for page = total, 1, -1 do
                    if doc:getPageFlow(page) == 0 then
                        end_page = page
                        break
                    end
                end
            else
                end_page = total
            end
        end
    end
    -- Fall back to stored page numbers
    if not start_page then start_page = data.scope_start_page end
    if not end_page then end_page = data.scope_end_page end
    return start_page, end_page
end

--- Find the best X-Ray for the current reading position.
--- Priority: section in range > main > sole section out of range.
--- If multiple sections exist with none/multiple in range, returns needs_selection.
--- @param document_path string The document file path
--- @param doc table|nil Document object (needed for page position check)
--- @return table|nil result { entry, key, is_section, label } or { needs_selection=true, sections={...} }
function ActionCache.findBestXray(document_path, doc)
    if not document_path then return nil end

    local current_page = getCurrentPageFromDoc(doc)
    local sections = ActionCache.getSectionXrays(document_path)
    local main = ActionCache.getXrayCache(document_path)
    local has_main = main and main.result

    -- 1. Check section X-Rays for one covering current page
    if current_page and #sections > 0 then
        local in_range = {}
        for _idx, sec in ipairs(sections) do
            local sp, ep = getSectionPageRange(sec.data, doc)
            if sp and ep and current_page >= sp and current_page <= ep then
                table.insert(in_range, sec)
            end
        end
        if #in_range == 1 then
            return {
                entry = in_range[1].data,
                key = in_range[1].key,
                is_section = true,
                label = in_range[1].label,
            }
        elseif #in_range > 1 then
            -- Multiple sections in range: let caller show selection popup
            return { needs_selection = true, sections = in_range }
        end
    end

    -- 2. Fall back to main X-Ray
    if has_main then
        return {
            entry = main,
            key = ActionCache.XRAY_CACHE_KEY,
            is_section = false,
        }
    end

    -- 3. Only section X-Rays, none in range
    if #sections == 1 then
        -- Sole section: use it even out of range (better than nothing)
        return {
            entry = sections[1].data,
            key = sections[1].key,
            is_section = true,
            label = sections[1].label,
        }
    elseif #sections > 1 then
        -- Multiple sections, none in range: let caller show selection popup
        return { needs_selection = true, sections = sections }
    end

    return nil
end

--- Find sections matching the current reading position for a given prefix.
--- @param document_path string The document file path
--- @param doc table Document object (needed for page position check)
--- @param prefix string|nil Section prefix (defaults to SECTION_XRAY_PREFIX for backward compat)
--- @return table Array of matching section entries from getSections()
function ActionCache.findMatchingSections(document_path, doc, prefix)
    if not document_path or not doc then return {} end
    local current_page = getCurrentPageFromDoc(doc)
    if not current_page then return {} end

    local sections = ActionCache.getSections(document_path, prefix or ActionCache.SECTION_XRAY_PREFIX)
    local matching = {}
    for _idx, sec in ipairs(sections) do
        local sp, ep = getSectionPageRange(sec.data, doc)
        if sp and ep and current_page >= sp and current_page <= ep then
            table.insert(matching, sec)
        end
    end
    return matching
end

--- Find the best section artifact covering a given page range (scope).
--- Used to match an existing section summary/artifact against a user-picked section scope.
--- Priority: exact match > containing match. Most recent wins ties.
--- @param document_path string The document file path
--- @param doc table Document object (needed for xpointer-based page conversion)
--- @param prefix string Section prefix (e.g., SECTION_PREFIXES.summary)
--- @param scope_start number Start page of the scope to match
--- @param scope_end number End page of the scope to match
--- @return table|nil Best matching section { key, label, data } or nil
function ActionCache.findBestSectionForScope(document_path, doc, prefix, scope_start, scope_end)
    if not document_path or not prefix or not scope_start or not scope_end then return nil end
    local sections = ActionCache.getSections(document_path, prefix)
    if #sections == 0 then return nil end

    local best_exact, best_containing
    for _idx, sec in ipairs(sections) do
        local sp, ep = getSectionPageRange(sec.data, doc)
        if sp and ep then
            if sp == scope_start and ep == scope_end then
                -- Exact match: prefer most recent
                if not best_exact or (sec.data.timestamp or 0) > (best_exact.data.timestamp or 0) then
                    best_exact = sec
                end
            elseif sp <= scope_start and ep >= scope_end then
                -- Containing match: prefer tightest fit (smallest range), then most recent
                local range = ep - sp
                if not best_containing then
                    best_containing = sec
                    best_containing._range = range
                else
                    local prev_range = best_containing._range
                    if range < prev_range or (range == prev_range and (sec.data.timestamp or 0) > (best_containing.data.timestamp or 0)) then
                        best_containing = sec
                        best_containing._range = range
                    end
                end
            end
        end
    end

    local result = best_exact or best_containing
    if result then
        result._range = nil  -- clean up temporary field
    end
    return result
end

return ActionCache
