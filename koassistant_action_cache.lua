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
local logger = require("koassistant_logger")
local T = require("ffi/util").template
local _ = require("koassistant_gettext")

local ActionCache = {}

--- Attempt to migrate a sidecar file from an alternate storage mode location
--- (the shared registry recipe; storage sweep 2026-09-03)
--- @param document_path string The document file path
--- @param current_path string The expected path in current storage mode
--- @param filename string The sidecar filename
--- @return boolean migrated Whether a file was migrated to current_path
local function migrateSidecarIfNeeded(document_path, current_path, filename)
    return require("koassistant_storage_registry").migrateSidecarFile(document_path, current_path, filename)
end

-- Cache format version (increment if structure changes)
-- v2: Added used_annotations and used_book_text fields to track permission state when cache was built
local CACHE_VERSION = 2

-- Artifact keys tracked in the browsing index
local ARTIFACT_KEYS = { "_xray_cache", "_summary_cache", "_analyze_cache", "recap", "xray_simple", "book_info", "analyze_highlights", "key_arguments", "discussion_questions", "quiz", "extract_insights", "reading_guide" }

--- Update the artifact index in g_reader_settings after any cache mutation.
--- Scans the in-memory cache table for known artifact keys and updates the index entry.
--- @param document_path string The document file path
--- @param cache table|nil The current cache table (nil = removed)
--- @param opts table|nil { no_flush = true } to skip G_reader_settings:flush()
local function updateArtifactIndex(document_path, cache, opts)
    if not document_path
        or document_path == "__GENERAL_CHATS__"
        or document_path == "__LIBRARY_CHATS__" then
        return
    end

    local index = G_reader_settings:readSetting("koassistant_artifact_index", {})

    if not cache then
        -- Cache file deleted
        if index[document_path] then
            index[document_path] = nil
            G_reader_settings:saveSetting("koassistant_artifact_index", index)
            if not (opts and opts.no_flush) then
                G_reader_settings:flush()
            end
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
    -- Also count section artifacts (all types) and wiki entries (prefix scan)
    local wiki_prefix = ActionCache.WIKI_PREFIX
    local wiki_prefix_len = #wiki_prefix
    for key, entry in pairs(cache) do
        if type(key) == "string" and type(entry) == "table"
           and entry.version == CACHE_VERSION and entry.result then
            local is_section = false
            for _sp_type, sp in pairs(ActionCache.SECTION_PREFIXES) do
                if key:sub(1, #sp) == sp then
                    is_section = true
                    break
                end
            end
            if is_section or key:sub(1, wiki_prefix_len) == wiki_prefix then
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
        if not (opts and opts.no_flush) then
            G_reader_settings:flush()
        end
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

--- Serialize the cross-book fold ledger (groups round (D)): an ARRAY of
--- { file, title, at, source_ts } records, so the field-by-field serializer
--- needs its own writer (CLAUDE.md Cache Field Parity). Shared by the entry
--- serializer and the checkpoint ring. Writes nothing for an empty ledger, so
--- an absent field stays absent on disk.
--- @param file table Open file handle
--- @param ledger table|nil
--- @param indent string Leading whitespace for the field line
local function writeMergedFrom(file, ledger, indent)
    if type(ledger) ~= "table" or #ledger == 0 then return end
    file:write(indent .. "merged_from = {\n")
    for _idx, rec in ipairs(ledger) do
        if type(rec) == "table" and type(rec.title) == "string" then
            file:write(indent .. "    { title = " .. string.format("%q", rec.title))
            if type(rec.file) == "string" then
                file:write(", file = " .. string.format("%q", rec.file))
            end
            if tonumber(rec.at) then
                file:write(", at = " .. string.format("%d", tonumber(rec.at)))
            end
            if tonumber(rec.source_ts) then
                file:write(", source_ts = " .. string.format("%d", tonumber(rec.source_ts)))
            end
            file:write(" },\n")
        end
    end
    file:write(indent .. "},\n")
end

--- Get cache file path for a document
--- @param document_path string The document file path
--- @return string|nil cache_path The full path to the cache file
function ActionCache.getPath(document_path)
    if not document_path
        or document_path == "__GENERAL_CHATS__"
        or document_path == "__LIBRARY_CHATS__" then
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
        -- saveCache writes a guard "\n" before the long-string closer (so content
        -- ending in "]==" can't fuse with it). Lua's long-string rule strips the
        -- leading newline but keeps the guard, so strip exactly one trailing
        -- newline to make the save/load round-trip lossless.
        for _key, entry in pairs(cache) do
            if type(entry) == "table" and type(entry.result) == "string"
                and entry.result:sub(-1) == "\n" then
                entry.result = entry.result:sub(1, -2)
            end
        end
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
            for _idx, tk in ipairs({ "tokens_in", "tokens_out", "tokens_reasoning" }) do
                if type(entry[tk]) == "number" then
                    file:write(string.format("        %s = %d,\n", tk, entry[tk]))
                end
            end
            if entry.used_research_mode then
                file:write(string.format("        used_research_mode = %s,\n", tostring(entry.used_research_mode)))
            end
            if entry.updated_by_auto then
                file:write(string.format("        updated_by_auto = %s,\n", tostring(entry.updated_by_auto)))
            end
            if entry.posture_promoted then
                file:write(string.format("        posture_promoted = %s,\n", tostring(entry.posture_promoted)))
            end
            if entry.source_mode then
                file:write(string.format("        source_mode = %q,\n", entry.source_mode))
            end
            if entry.merged_from_sections then
                file:write(string.format("        merged_from_sections = %s,\n", tostring(entry.merged_from_sections)))
            end
            if entry.merged_to_main then
                file:write(string.format("        merged_to_main = %s,\n", tostring(entry.merged_to_main)))
            end
            if entry.unavailable_data_text then
                file:write(string.format("        unavailable_data_text = %q,\n", entry.unavailable_data_text))
            end
            if entry.intro then
                file:write(string.format("        intro = %s,\n", tostring(entry.intro)))
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
            if entry.coverage_spans then
                file:write(string.format("        coverage_spans = %q,\n", entry.coverage_spans))
            end
            if entry.producer then
                file:write(string.format("        producer = %q,\n", entry.producer))
            end
            if entry.base_timestamp then
                file:write(string.format("        base_timestamp = %s,\n", tostring(entry.base_timestamp)))
            end
            if entry.merged_from_books then
                file:write(string.format("        merged_from_books = %q,\n", entry.merged_from_books))
            end
            if entry.xray_categories then
                file:write(string.format("        xray_categories = %q,\n", entry.xray_categories))
            end
            if entry.xray_depth then
                file:write(string.format("        xray_depth = %q,\n", entry.xray_depth))
            end
            if entry.edited_at then
                file:write(string.format("        edited_at = %s,\n", tostring(entry.edited_at)))
            end
            writeMergedFrom(file, entry.merged_from, "        ")
            -- Quiz state (answers, correct, revealed) — nested table serialization
            if entry.quiz_state and type(entry.quiz_state) == "table" then
                file:write("        quiz_state = {\n")
                -- answers: sparse table {[1] = "B", [3] = "A"}
                if entry.quiz_state.answers then
                    file:write("            answers = {")
                    for k, v in pairs(entry.quiz_state.answers) do
                        if type(k) == "number" and type(v) == "string" then
                            file:write(string.format(" [%d] = %q,", k, v))
                        end
                    end
                    file:write(" },\n")
                end
                -- revealed: sparse table {[1] = true, [2] = true}
                if entry.quiz_state.revealed then
                    file:write("            revealed = {")
                    for k, v in pairs(entry.quiz_state.revealed) do
                        if type(k) == "number" and v == true then
                            file:write(string.format(" [%d] = true,", k))
                        end
                    end
                    file:write(" },\n")
                end
                -- correct: sparse table {[1] = true, [2] = false}
                if entry.quiz_state.correct then
                    file:write("            correct = {")
                    for k, v in pairs(entry.quiz_state.correct) do
                        if type(k) == "number" and type(v) == "boolean" then
                            file:write(string.format(" [%d] = %s,", k, tostring(v)))
                        end
                    end
                    file:write(" },\n")
                end
                if entry.quiz_state.current_index then
                    file:write(string.format("            current_index = %d,\n", entry.quiz_state.current_index))
                end
                if entry.quiz_state.phase then
                    file:write(string.format("            phase = %q,\n", entry.quiz_state.phase))
                end
                file:write("        },\n")
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

    logger.dbg("KOAssistant ActionCache: Saved cache for", document_path)
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
--- @param metadata table Optional metadata: { model = "model-name", used_highlights = true/false, used_annotations = true/false, used_book_text = true/false, previous_progress_decimal = number }
--- @return boolean success Whether save succeeded
function ActionCache.set(document_path, action_id, result, progress_decimal, metadata)
    if not document_path or not action_id or not result then
        return false
    end

    local cache = loadCache(document_path)
    cache[action_id] = {
        progress_decimal = progress_decimal or 0,
        -- metadata.timestamp preserves the original generation time when a
        -- checkpoint is restored; every normal save stamps now
        timestamp = (metadata and metadata.timestamp) or os.time(),
        model = metadata and metadata.model or "",
        result = result,
        version = CACHE_VERSION,
        -- Track permission state when cache was built
        used_highlights = metadata and metadata.used_highlights,
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
        -- Token usage of the request that wrote this entry (build-cost comparisons)
        tokens_in = metadata and metadata.tokens_in,
        tokens_out = metadata and metadata.tokens_out,
        tokens_reasoning = metadata and metadata.tokens_reasoning,
        -- Track research mode at generation time (for update prompt track consistency)
        used_research_mode = metadata and metadata.used_research_mode,
        -- True when the last write came from a background auto-update (scope-popup trace)
        updated_by_auto = metadata and metadata.updated_by_auto,
        -- 50(f): the FULL spoiler posture installed this entry AHEAD of the
        -- reading position — re-enabling spoiler protection reverts exactly
        -- these installs (deliberate manual switches are never stamped)
        posture_promoted = metadata and metadata.posture_promoted,
        -- Track source mode at generation time (for source indication in viewers)
        source_mode = metadata and metadata.source_mode,
        -- Merge-engine provenance: how many section X-Rays were folded in
        -- (xray_ecosystem_plan.md §6 slice 3; nil = not a merged artifact)
        merged_from_sections = metadata and metadata.merged_from_sections,
        -- Section entries: os.time() when an into-main merge folded this section
        -- in (§7.4 T15; informational — a main redo makes it historical).
        -- Regeneration clears it naturally: a fresh set() carries no value.
        merged_to_main = metadata and metadata.merged_to_main,
        -- Track unavailable data at generation time (pre-formatted string for artifact viewer)
        unavailable_data_text = metadata and metadata.unavailable_data_text,
        -- Introductory X-Ray (round 20): premise-only version at progress 0,
        -- openable at any position (spoiler-free by construction)
        intro = metadata and metadata.intro,
        -- Section X-Ray scope metadata
        scope_label = metadata and metadata.scope_label,
        scope_start_page = metadata and metadata.scope_start_page,
        scope_end_page = metadata and metadata.scope_end_page,
        scope_start_xpointer = metadata and metadata.scope_start_xpointer,
        scope_end_xpointer = metadata and metadata.scope_end_xpointer,
        scope_page_summary = metadata and metadata.scope_page_summary,
        -- Timeline slice 1 (xray_ecosystem_plan.md item 37): honest coverage
        -- as a span set ("a-b,c-d", internal pages — WriteBack span helpers;
        -- whole-book claims stay flag-based) + provenance-per-point
        coverage_spans = metadata and metadata.coverage_spans,
        producer = metadata and metadata.producer,
        base_timestamp = metadata and metadata.base_timestamp,
        -- Cross-book merge provenance (item 43): accumulated source titles,
        -- kept as the display form of the structured fold ledger below
        merged_from_books = metadata and metadata.merged_from_books,
        -- Groups round (D): file-keyed, dated fold ledger
        -- ({ file, title, at, source_ts }) — tells "folded" from "folded, but
        -- that book's X-Ray has changed since". XrayMerge owns its shape.
        merged_from = metadata and metadata.merged_from,
        -- Category selection this artifact was built with (presets v0.21):
        -- csv of group ids; nil = full. The LINEAGE truth — updates and rung
        -- builds follow this stamp, never the sidecar preference.
        xray_categories = metadata and metadata.xray_categories,
        -- Depth rung the lineage was built at (light/deep; nil = standard) — the
        -- same lineage-truth role as xray_categories (docs/xray_depth_axis_plan.md)
        xray_depth = metadata and metadata.xray_depth,
        -- Reader-modified marker (entity dedup); rides into the ring via
        -- CHECKPOINT_COPY_FIELDS so an archived version stays honest too
        edited_at = metadata and metadata.edited_at,
    }

    return saveCache(document_path, cache)
end

--- Update a field on an existing cached entry without rebuilding it.
--- Used for quiz_state persistence (answers, scores) without overwriting the full entry.
--- @param document_path string The document file path
--- @param action_id string The action ID
--- @param field string The field name to update
--- @param value any The value to set
--- @return boolean success
function ActionCache.updateField(document_path, action_id, field, value)
    if not document_path or not action_id or not field then return false end
    local cache = loadCache(document_path)
    if not cache[action_id] then return false end
    cache[action_id][field] = value
    return saveCache(document_path, cache)
end

--- Stamp section entries as folded into the main X-Ray (§7.4 T15). One
--- load+save for the whole batch — never N file rewrites (e-ink).
--- @param document_path string The document file path
--- @param keys table Array of section cache keys
--- @param timestamp number os.time() of the merge
--- @return boolean success
function ActionCache.markSectionsMerged(document_path, keys, timestamp)
    if not document_path or type(keys) ~= "table" or #keys == 0 then return false end
    local cache = loadCache(document_path)
    local touched = false
    for _idx, key in ipairs(keys) do
        if cache[key] then
            cache[key].merged_to_main = timestamp
            touched = true
        end
    end
    if not touched then return false end
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
    -- Companion files die with the artifacts: the checkpoint ring would linger as
    -- an orphan, and a surviving LADDER would silently RESURRECT a deleted X-Ray
    -- through promotion (every delete-all surface must clear it — enforced here,
    -- by construction, rather than at each call site)
    ActionCache.clearXrayCheckpoints(document_path)
    ActionCache.clearXrayLadder(document_path)
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
--- Call this when artifacts are discovered through read-only paths (e.g., viewCache,
--- heal-on-open, index rebuild).
--- @param document_path string The document file path
--- @param opts table|nil { no_flush = true } to skip G_reader_settings:flush()
function ActionCache.refreshIndex(document_path, opts)
    local cache = loadCache(document_path)
    updateArtifactIndex(document_path, next(cache) and cache or nil, opts)
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
    ["book_info"] = _("About"),
    ["analyze_highlights"] = _("Notes Analysis"),
    ["key_arguments"] = _("Key Arguments"),
    ["discussion_questions"] = _("Discussion Questions"),
    ["quiz"] = _("Quiz"),
    ["extract_insights"] = _("Key Insights"),
    ["reading_guide"] = _("Reading Guide"),
}
ActionCache.ARTIFACT_NAMES = ARTIFACT_NAMES

-- Artifact keys that are per-action caches (vs document-level caches)
local PER_ACTION_ARTIFACTS = {
    recap = true, xray_simple = true, book_info = true, analyze_highlights = true,
    key_arguments = true, discussion_questions = true, quiz = true, extract_insights = true, reading_guide = true,
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
    -- Archived X-Ray versions (#73): listed right under the X-Ray row. The
    -- X-Ray browser's own "other artifacts" list (exclude_key = _xray_cache)
    -- keeps its hamburger entry instead. Callers handle is_xray_versions_group
    -- by opening the checkpoint list (no data payload).
    -- ORPHAN SAFETY NET (2026-08-06, device report): the ring CAN outlive the
    -- live X-Ray — a rebuild archives and clears up front, so a cancelled or
    -- never-answered rebuild leaves archives with no X-Ray row to hang under,
    -- and they were unreachable from every surface until a new X-Ray existed.
    -- Archived work must never be strandable: with no live X-Ray the group is
    -- listed standalone (first, since nothing else X-Ray-ish is there).
    if exclude_key ~= "_xray_cache" then
        local xray_idx
        for i, art in ipairs(available) do
            if art.key == "_xray_cache" then
                xray_idx = i
                break
            end
        end
        -- Ring + ladder: the checkpoint list aggregates both, so the count does too
        local cp_count = ActionCache.getXrayCheckpointCount(document_path)
            + ActionCache.getXrayLadderCount(document_path)
        if cp_count > 0 then
            table.insert(available, xray_idx and (xray_idx + 1) or 1, {
                name = xray_idx and T(_("Previous X-Ray Versions (%1)"), cp_count)
                    or T(_("Archived X-Ray Versions (%1)"), cp_count),
                key = "_xray_versions",
                is_xray_versions_group = true,
                is_orphan = not xray_idx or nil,
            })
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
                name = string.format(_("View Section X-Rays (%d)"), count),
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
        "discussion_questions", "quiz", "extract_insights", "reading_guide" }
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
                        name = string.format("%s (%d)", ActionCache.SECTION_GROUP_NAMES[sec_type] or sec_type, type_count),
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

    -- Generated images for this book: every "View Artifacts" surface consumes
    -- this aggregation, so the row appears everywhere. Callers handle
    -- is_image_group by opening the gallery filtered (no data payload).
    local img_ok, ImageGenerator = pcall(require, "koassistant_image_generator")
    if img_ok and ImageGenerator then
        local img_info = ImageGenerator.booksWithImages()[document_path]
        if img_info and img_info.count > 0 then
            table.insert(artifacts, {
                name = T(_("Generated Images (%1)"), img_info.count),
                key = "_generated_images",
                is_image_group = true,
                image_count = img_info.count,
            })
        end
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
--- @param metadata table Optional: { model = "model-name", used_highlights = true/false, used_annotations = true/false, used_book_text = true/false }
---   used_highlights: Track whether highlights were included when building this cache.
---   used_annotations: Track whether annotation notes were included when building this cache.
---   used_book_text: Track whether book text extraction was used. false = AI training data only.
---   When reading the cache, permissions are only required for data that was actually used.
--- @return boolean success
function ActionCache.setXrayCache(document_path, result, progress_decimal, metadata)
    local ok = ActionCache.set(document_path, ActionCache.XRAY_CACHE_KEY, result, progress_decimal, metadata)
    -- S4 (ref #90): every live X-Ray write reaches the group seeding hook —
    -- main.lua registers it; the seed run suppresses it for its own writes
    if ok and type(ActionCache.on_live_xray_written) == "function"
            and not ActionCache.suppress_write_hook then
        pcall(ActionCache.on_live_xray_written, document_path)
    end
    return ok
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

--- Delete an X-Ray and everything derived from it — ONE place, so the three
--- delete surfaces (X-Ray browser, artifact viewer, cache popups) can never
--- drift apart on what "delete" means. Round 28 (maintainer decision after the
--- #90 round: "if you delete the currently promoted X-Ray, everything goes?"):
--- the archived VERSIONS are now the reader's choice — they are independent
--- work, they survive standalone in the artifact list ("Archived X-Ray
--- Versions (N)", the orphan safety net), and losing five of them to one tap
--- was the asymmetry the versions list itself never had.
--- The LADDER is never optional: a surviving prepared rung silently
--- RESURRECTS a deleted X-Ray through promotion.
--- @param document_path string The document file path
--- @param opts table|nil { keep_versions = true → the checkpoint ring survives }
--- @return boolean success
function ActionCache.deleteXray(document_path, opts)
    if not document_path then return false end
    opts = opts or {}
    ActionCache.clearXrayCache(document_path)
    -- X-Ray writes BOTH the doc-level key and the per-action entry; a
    -- doc-key-only clear leaves an entry background auto-update resurrects from
    ActionCache.clear(document_path, "xray")
    ActionCache.clearWikiEntries(document_path)
    ActionCache.clearXrayLadder(document_path)
    if not opts.keep_versions then
        ActionCache.clearXrayCheckpoints(document_path)
    end
    return true
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
    counterarguments = "counterarguments_section:",
    discussion_questions = "discussion_questions_section:",
    quiz = "quiz_section:",
    extract_insights = "extract_insights_section:",
    reading_guide = "reading_guide_section:",
}

-- Human-readable names for section group display (plural for group titles)
ActionCache.SECTION_GROUP_NAMES = {
    xray = _("View Section X-Rays"),
    summary = _("View Section Summaries"),
    analyze = _("View Section Analyses"),
    key_arguments = _("View Section Key Arguments"),
    counterarguments = _("View Section Counterarguments"),
    discussion_questions = _("View Section Discussion Questions"),
    quiz = _("View Section Quizzes"),
    extract_insights = _("View Section Key Insights"),
    reading_guide = _("View Section Reading Guides"),
}

-- Singular type labels for individual section viewer titles
ActionCache.SECTION_TYPE_LABELS = {
    xray = _("X-Ray"),
    summary = _("Summary"),
    analyze = _("Analysis"),
    key_arguments = _("Key Arguments"),
    counterarguments = _("Counterarguments"),
    discussion_questions = _("Discussion Questions"),
    generate_quiz = _("Quiz"),
    extract_insights = _("Key Insights"),
    reading_guide = _("Reading Guide"),
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

-- Reserved key inside koassistant_user_aliases.lua holding the entity
-- never-merge pair list (xray_ecosystem_plan.md §6 slice 4):
-- { { "Name A", "Name B" }, ... }. Same "user curation survives regeneration"
-- contract as the alias entries — consulted by the duplicate scan and injected
-- into the section-merge prompts. get/setUserAliases carry it through the
-- normal get→modify→set round-trips untouched.
ActionCache.NEVER_MERGE_KEY = "__never_merge"
-- Reserved key holding pairs the post-update dedup ask has ALREADY offered
-- (round 18): same array-of-pairs shape as never-merge. One ask per pair,
-- ever — dismissing the ask is an answer; the manual scan stays available.
ActionCache.DEDUP_OFFERED_KEY = "__dedup_offered"
-- Reserved key holding carried entries the reader REMOVED from the carried
-- list (S4, ref #90): a plain array of names. A removed entry must not come
-- back through the automatic seed or a checkpoint install; adding it by hand
-- again clears the record. Same sidecar as the alias edits, so it survives
-- installs and rebuilds.
ActionCache.REMOVED_STUBS_KEY = "__dormant_removed"

--- Get path to user aliases file for a document
--- @param document_path string The document file path
--- @return string|nil path Full path, or nil if not applicable
function ActionCache.getUserAliasesPath(document_path)
    if not document_path
        or document_path == "__GENERAL_CHATS__"
        or document_path == "__LIBRARY_CHATS__" then
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
    -- (never the reserved pair-list keys — their values are arrays of PAIRS,
    -- and wrapping them as add-tables would crash the serializer on save)
    for name, entry in pairs(data) do
        if name ~= ActionCache.NEVER_MERGE_KEY
            and name ~= ActionCache.DEDUP_OFFERED_KEY
            and name ~= ActionCache.REMOVED_STUBS_KEY
            and type(entry) == "table" and not entry.add and not entry.ignore then
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

    -- Remove entries with no content (the reserved pair-list keys hold
    -- arrays of pairs, not add/ignore lists — judged on their own emptiness)
    for name, entry in pairs(aliases_table) do
        if type(entry) ~= "table" then
            aliases_table[name] = nil
        elseif name == ActionCache.NEVER_MERGE_KEY
            or name == ActionCache.DEDUP_OFFERED_KEY
            or name == ActionCache.REMOVED_STUBS_KEY then
            if #entry == 0 then
                aliases_table[name] = nil
            end
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
    for _ri, rkey in ipairs({ ActionCache.NEVER_MERGE_KEY, ActionCache.DEDUP_OFFERED_KEY }) do
        local pair_list = aliases_table[rkey]
        if type(pair_list) == "table" and #pair_list > 0 then
            file:write(string.format("    [%q] = {", rkey))
            for _idx, pair in ipairs(pair_list) do
                if type(pair) == "table" and type(pair[1]) == "string" and type(pair[2]) == "string" then
                    file:write(string.format(" { %q, %q },", pair[1], pair[2]))
                end
            end
            file:write(" },\n")
        end
    end
    local removed = aliases_table[ActionCache.REMOVED_STUBS_KEY]
    if type(removed) == "table" and #removed > 0 then
        file:write(string.format("    [%q] = ", ActionCache.REMOVED_STUBS_KEY))
        write_array(file, removed)
        file:write(",\n")
    end
    for item_name, entry in pairs(aliases_table) do
        if item_name ~= ActionCache.NEVER_MERGE_KEY
            and item_name ~= ActionCache.DEDUP_OFFERED_KEY
            and item_name ~= ActionCache.REMOVED_STUBS_KEY then
            file:write(string.format("    [%q] = { add = ", item_name))
            write_array(file, entry.add)
            if entry.ignore and #entry.ignore > 0 then
                file:write(", ignore = ")
                write_array(file, entry.ignore)
            end
            file:write(" },\n")
        end
    end
    file:write("}\n")
    file:close()

    logger.dbg("KOAssistant ActionCache: Saved user aliases for", document_path)
    return true
end

--- Carried entries the reader removed (S4 tombstones): lowercased-name set.
--- @param document_path string
--- @return table set
function ActionCache.getRemovedStubs(document_path)
    local set = {}
    local raw = ActionCache.getUserAliases(document_path)[ActionCache.REMOVED_STUBS_KEY]
    if type(raw) == "table" then
        for _idx, n in ipairs(raw) do
            if type(n) == "string" and n ~= "" then set[n:lower()] = true end
        end
    end
    return set
end

--- Remember a removed carried entry (the browser's Remove).
function ActionCache.addRemovedStub(document_path, name)
    if type(name) ~= "string" or name == "" then return false end
    local all = ActionCache.getUserAliases(document_path)
    local list = all[ActionCache.REMOVED_STUBS_KEY]
    if type(list) ~= "table" then list = {} end
    for _idx, n in ipairs(list) do
        if type(n) == "string" and n:lower() == name:lower() then return true end
    end
    list[#list + 1] = name
    all[ActionCache.REMOVED_STUBS_KEY] = list
    return ActionCache.setUserAliases(document_path, all)
end

--- Forget a removal (the reader added the entry by hand again).
function ActionCache.clearRemovedStub(document_path, name)
    if type(name) ~= "string" or name == "" then return false end
    local all = ActionCache.getUserAliases(document_path)
    local list = all[ActionCache.REMOVED_STUBS_KEY]
    if type(list) ~= "table" then return true end
    local kept, changed = {}, false
    for _idx, n in ipairs(list) do
        if type(n) == "string" and n:lower() == name:lower() then
            changed = true
        else
            kept[#kept + 1] = n
        end
    end
    if not changed then return true end
    all[ActionCache.REMOVED_STUBS_KEY] = kept
    return ActionCache.setUserAliases(document_path, all)
end

--- Validated pair list from a reserved pair-list key. Pure.
local function pairListFrom(aliases_table, key)
    local raw = type(aliases_table) == "table" and aliases_table[key]
    local list = {}
    if type(raw) == "table" then
        for _idx, pair in ipairs(raw) do
            if type(pair) == "table" and type(pair[1]) == "string" and type(pair[2]) == "string" then
                list[#list + 1] = { pair[1], pair[2] }
            end
        end
    end
    return list
end

--- Validated never-merge pair list from an already-loaded aliases table
--- (callers holding a getUserAliases result skip a second file read). Pure.
--- @param aliases_table table getUserAliases output
--- @return table pairs Array of { name_a, name_b }
function ActionCache.neverMergePairsFrom(aliases_table)
    return pairListFrom(aliases_table, ActionCache.NEVER_MERGE_KEY)
end

--- Already-offered dedup-ask pairs (round 18). Pure.
--- @param aliases_table table getUserAliases output
--- @return table pairs Array of { name_a, name_b }
function ActionCache.dedupOfferedPairsFrom(aliases_table)
    return pairListFrom(aliases_table, ActionCache.DEDUP_OFFERED_KEY)
end

--- Record dedup-ask pairs as offered (batch; order/case-insensitive dedupe).
--- @param document_path string
--- @param new_pairs table Array of { name_a, name_b }
--- @return boolean success
function ActionCache.addDedupOfferedPairs(document_path, new_pairs)
    if type(new_pairs) ~= "table" or #new_pairs == 0 then return false end
    local all = ActionCache.getUserAliases(document_path)
    local list = all[ActionCache.DEDUP_OFFERED_KEY]
    if type(list) ~= "table" then
        list = {}
        all[ActionCache.DEDUP_OFFERED_KEY] = list
    end
    local seen = {}
    for _idx, pair in ipairs(list) do
        if type(pair) == "table" and type(pair[1]) == "string" and type(pair[2]) == "string" then
            local a, b = pair[1]:lower(), pair[2]:lower()
            if a > b then a, b = b, a end
            seen[a .. "\0" .. b] = true
        end
    end
    local added = false
    for _idx, pair in ipairs(new_pairs) do
        if type(pair) == "table" and type(pair[1]) == "string" and type(pair[2]) == "string"
            and pair[1] ~= "" and pair[2] ~= "" then
            local a, b = pair[1]:lower(), pair[2]:lower()
            if a > b then a, b = b, a end
            local key = a .. "\0" .. b
            if not seen[key] then
                seen[key] = true
                list[#list + 1] = { pair[1], pair[2] }
                added = true
            end
        end
    end
    if not added then return true end
    return ActionCache.setUserAliases(document_path, all)
end

--- Add one reader-asserted alias to an entity's user-alias record (the
--- no-hits "Add as alias of…" flow, ref #63). Reuses an existing record
--- key case-insensitively, dedupes against add, and removes the alias from
--- ignore when present — an explicit add outranks an old ignore.
--- @param document_path string The document file path
--- @param item_name string The entity's display name (record key)
--- @param alias string The alias to add
--- @return boolean success
function ActionCache.addUserAlias(document_path, item_name, alias)
    if type(item_name) ~= "string" or item_name == ""
        or type(alias) ~= "string" or alias == "" then
        return false
    end
    local all = ActionCache.getUserAliases(document_path)
    local key = item_name
    for k in pairs(all) do
        if type(k) == "string"
            and k ~= ActionCache.NEVER_MERGE_KEY and k ~= ActionCache.DEDUP_OFFERED_KEY
            and k ~= ActionCache.REMOVED_STUBS_KEY
            and k:lower() == item_name:lower() then
            key = k
            break
        end
    end
    local entry = all[key] or { add = {}, ignore = {} }
    entry.add = entry.add or {}
    entry.ignore = entry.ignore or {}
    local alias_lower = alias:lower()
    for i = #entry.ignore, 1, -1 do
        if entry.ignore[i]:lower() == alias_lower then
            table.remove(entry.ignore, i)
        end
    end
    for _idx, a in ipairs(entry.add) do
        if a:lower() == alias_lower then
            all[key] = entry
            return ActionCache.setUserAliases(document_path, all)
        end
    end
    table.insert(entry.add, alias)
    all[key] = entry
    return ActionCache.setUserAliases(document_path, all)
end

--- Load the entity never-merge pair list (validated copy).
--- @param document_path string The document file path
--- @return table pairs Array of { name_a, name_b }
function ActionCache.getNeverMergePairs(document_path)
    return ActionCache.neverMergePairsFrom(ActionCache.getUserAliases(document_path))
end

--- Re-key the name-keyed side stores after an entry rename (Manage ▸ Rename,
--- 2026-08-09): the AI Wiki entry, the user search-terms record, and
--- never-merge pairs. The artifact itself is renamed by XrayParser.renameItem;
--- this moves everything keyed by the old main-name string so nothing orphans.
--- @param document_path string The document file path
--- @param category_key string The entry's X-Ray category
--- @param old_name string Previous main name
--- @param new_name string New main name
function ActionCache.renameEntityKeys(document_path, category_key, old_name, new_name)
    if type(old_name) ~= "string" or type(new_name) ~= "string"
        or old_name == "" or new_name == "" or old_name == new_name then
        return
    end
    -- Wiki entry rides to the new key (a re-key is a rewrite; timestamp moves)
    local wiki = ActionCache.getWikiEntry(document_path, category_key, old_name)
    if wiki and wiki.result then
        ActionCache.setWikiEntry(document_path, category_key, new_name, wiki.result, wiki)
        ActionCache.clearWikiEntry(document_path, category_key, old_name)
    end
    local all = ActionCache.getUserAliases(document_path)
    local dirty = false
    -- Search-terms record moves under the new name (merged if one exists)
    local old_rec = all[old_name]
    if type(old_rec) == "table" then
        local new_rec = all[new_name]
        if type(new_rec) == "table" then
            for _idx, list_key in ipairs({ "add", "ignore" }) do
                local src = old_rec[list_key]
                if type(src) == "table" then
                    new_rec[list_key] = new_rec[list_key] or {}
                    for _i, term in ipairs(src) do
                        local seen = false
                        for _j, have in ipairs(new_rec[list_key]) do
                            if type(have) == "string" and type(term) == "string"
                                and have:lower() == term:lower() then
                                seen = true
                                break
                            end
                        end
                        if not seen then table.insert(new_rec[list_key], term) end
                    end
                end
            end
        else
            all[new_name] = old_rec
        end
        all[old_name] = nil
        dirty = true
    end
    -- Never-merge pairs follow the rename
    local pairs_list = all[ActionCache.NEVER_MERGE_KEY]
    if type(pairs_list) == "table" then
        local lk = old_name:lower()
        for _idx, pair in ipairs(pairs_list) do
            if type(pair) == "table" then
                for side = 1, 2 do
                    if type(pair[side]) == "string" and pair[side]:lower() == lk then
                        pair[side] = new_name
                        dirty = true
                    end
                end
            end
        end
    end
    if dirty then
        ActionCache.setUserAliases(document_path, all)
    end
end

--- Record a pair of entity names as never-merge (order/case-insensitive dedup).
--- @return boolean success
function ActionCache.addNeverMergePair(document_path, name_a, name_b)
    if type(name_a) ~= "string" or type(name_b) ~= "string"
        or name_a == "" or name_b == "" then
        return false
    end
    local all = ActionCache.getUserAliases(document_path)
    local list = all[ActionCache.NEVER_MERGE_KEY]
    if type(list) ~= "table" then
        list = {}
        all[ActionCache.NEVER_MERGE_KEY] = list
    end
    local ka, kb = name_a:lower(), name_b:lower()
    for _idx, pair in ipairs(list) do
        if type(pair) == "table" and type(pair[1]) == "string" and type(pair[2]) == "string" then
            local pa, pb = pair[1]:lower(), pair[2]:lower()
            if (pa == ka and pb == kb) or (pa == kb and pb == ka) then
                return true
            end
        end
    end
    list[#list + 1] = { name_a, name_b }
    return ActionCache.setUserAliases(document_path, all)
end

--- Remove a never-merge pair (order/case-insensitive match).
--- @return boolean success
function ActionCache.removeNeverMergePair(document_path, name_a, name_b)
    if type(name_a) ~= "string" or type(name_b) ~= "string" then return false end
    local all = ActionCache.getUserAliases(document_path)
    local list = all[ActionCache.NEVER_MERGE_KEY]
    if type(list) ~= "table" then return true end
    local ka, kb = name_a:lower(), name_b:lower()
    local removed = false
    for i = #list, 1, -1 do
        local pair = list[i]
        if type(pair) == "table" and type(pair[1]) == "string" and type(pair[2]) == "string" then
            local pa, pb = pair[1]:lower(), pair[2]:lower()
            if (pa == ka and pb == kb) or (pa == kb and pb == ka) then
                table.remove(list, i)
                removed = true
            end
        end
    end
    if not removed then return true end
    return ActionCache.setUserAliases(document_path, all)
end

-- =============================================================================
-- X-Ray checkpoints (snapshot ring)
-- Every X-Ray save that overwrites a different existing result (incremental
-- update, redo, complete regeneration — manual or background) archives the
-- pre-overwrite entry here (xray_ecosystem_plan.md §5 decision 2) — browsable
-- via "Previous versions" in the X-Ray popup (view/restore/delete) and the
-- input for future series merge. Newest first, trimmed to the ring limit.
-- =============================================================================

ActionCache.XRAY_CHECKPOINTS_FILE = "koassistant_xray_checkpoints.lua"
ActionCache.XRAY_CHECKPOINT_LIMIT = 5

--- Resolve the ring depth from settings. Fallback MUST equal the
--- koassistant_settings_schema.lua default for xray_versions_kept (5).
--- 0 = stop archiving new versions (existing archives stay until deleted).
--- @param features table|nil The features settings table
--- @return number limit 0..20
function ActionCache.checkpointLimitFromFeatures(features)
    local n = tonumber(features and features.xray_versions_kept)
    if n == nil then return ActionCache.XRAY_CHECKPOINT_LIMIT end
    n = math.floor(n)
    if n < 0 then n = 0 end
    if n > 20 then n = 20 end
    return n
end

-- Fields copied from a cache entry into its archived checkpoint (and back on
-- restore). Permission flags ride along so a restored version keeps honest
-- read-gating metadata; pre-metadata checkpoints fall back to the outgoing
-- live entry's flags (its sticky-true superset — never looser).
local CHECKPOINT_COPY_FIELDS = {
    "progress_decimal", "progress_page", "timestamp", "result",
    "used_highlights", "used_annotations", "used_book_text",
    "model", "full_document", "flow_visible_pages", "source_mode",
    "chapter_label", "intro",
    "coverage_spans", "producer", "base_timestamp", "merged_from_books",
    "merged_from", "xray_categories", "xray_depth", "edited_at",
    "tokens_in", "tokens_out", "tokens_reasoning",
}

local function buildCheckpointEntry(source)
    local cp = { archived_at = os.time() }
    for _idx, field in ipairs(CHECKPOINT_COPY_FIELDS) do
        cp[field] = source[field]
    end
    return cp
end

--- Serialize the ring to disk (shared by push/remove/restore).
local function writeCheckpointRing(path, ring)
    local util = require("util")
    local dir = path:match("(.*/)")
    if dir then
        util.makePath(dir)
    end
    local file, err = io.open(path, "w")
    if not file then
        logger.err("KOAssistant ActionCache: Failed to open X-Ray checkpoints file for writing:", err)
        return false
    end
    -- Count header: lets hot paths (artifact aggregation) read the ring size
    -- from one line instead of parsing every archived JSON
    file:write("-- count: " .. #ring .. "\n")
    file:write("return {\n")
    for _idx, cp in ipairs(ring) do
        file:write("    {\n")
        file:write(string.format("        progress_decimal = %s,\n", tostring(cp.progress_decimal or 0)))
        if cp.progress_page then
            file:write(string.format("        progress_page = %s,\n", tostring(cp.progress_page)))
        end
        file:write(string.format("        timestamp = %s,\n", tostring(cp.timestamp or 0)))
        file:write(string.format("        archived_at = %s,\n", tostring(cp.archived_at or 0)))
        if cp.used_highlights ~= nil then
            file:write(string.format("        used_highlights = %s,\n", tostring(cp.used_highlights)))
        end
        if cp.used_annotations ~= nil then
            file:write(string.format("        used_annotations = %s,\n", tostring(cp.used_annotations)))
        end
        if cp.used_book_text ~= nil then
            file:write(string.format("        used_book_text = %s,\n", tostring(cp.used_book_text)))
        end
        if cp.model then
            file:write(string.format("        model = %q,\n", cp.model))
        end
        if cp.full_document then
            file:write(string.format("        full_document = %s,\n", tostring(cp.full_document)))
        end
        if cp.flow_visible_pages then
            file:write(string.format("        flow_visible_pages = %s,\n", tostring(cp.flow_visible_pages)))
        end
        if cp.source_mode then
            file:write(string.format("        source_mode = %q,\n", cp.source_mode))
        end
        if cp.chapter_label then
            file:write(string.format("        chapter_label = %q,\n", cp.chapter_label))
        end
        if cp.intro then
            file:write(string.format("        intro = %s,\n", tostring(cp.intro)))
        end
        if cp.coverage_spans then
            file:write(string.format("        coverage_spans = %q,\n", cp.coverage_spans))
        end
        if cp.producer then
            file:write(string.format("        producer = %q,\n", cp.producer))
        end
        if cp.base_timestamp then
            file:write(string.format("        base_timestamp = %s,\n", tostring(cp.base_timestamp)))
        end
        if cp.merged_from_books then
            file:write(string.format("        merged_from_books = %q,\n", cp.merged_from_books))
        end
        if cp.xray_categories then
            file:write(string.format("        xray_categories = %q,\n", cp.xray_categories))
        end
        if cp.xray_depth then
            file:write(string.format("        xray_depth = %q,\n", cp.xray_depth))
        end
        -- A stored version the reader has since altered (entity dedup sweeps
        -- built-but-uninstalled rungs so a later install cannot resurrect a
        -- merged split). Without this the rewrite was invisible: a rung still
        -- read as a pristine build of its checkpoint.
        if cp.edited_at then
            file:write(string.format("        edited_at = %s,\n", tostring(cp.edited_at)))
        end
        for _tk, tk in ipairs({ "tokens_in", "tokens_out", "tokens_reasoning" }) do
            if type(cp[tk]) == "number" then
                file:write(string.format("        %s = %d,\n", tk, cp[tk]))
            end
        end
        writeMergedFrom(file, cp.merged_from, "        ")
        local result_text = cp.result or ""
        local eq_str = string.rep("=", findSafeDelimiter(result_text))
        file:write(string.format("        result = [%s[\n", eq_str))
        file:write(result_text)
        file:write(string.format("\n]%s],\n", eq_str))
        file:write("    },\n")
    end
    file:write("}\n")
    file:close()
    return true
end

--- Get path to the X-Ray checkpoints sidecar file
--- @param document_path string The document file path
--- @return string|nil path Full path, or nil if not applicable
function ActionCache.getXrayCheckpointsPath(document_path)
    if not document_path
        or document_path == "__GENERAL_CHATS__"
        or document_path == "__LIBRARY_CHATS__" then
        return nil
    end
    local sidecar_dir = DocSettings:getSidecarDir(document_path)
    return sidecar_dir .. "/" .. ActionCache.XRAY_CHECKPOINTS_FILE
end

--- How much of the book an archived version covers. A whole-document build is
--- worth 1 even when its progress stamp says otherwise (a complete install is
--- not always stamped 1.0 -- see the posture notes on full_document).
local function checkpointCoverage(entry)
    if type(entry) ~= "table" then return 0 end
    if entry.full_document then return 1 end
    return tonumber(entry.progress_decimal) or 0
end

--- Trim a newest-first checkpoint list to the ring limit (pure helper, unit-tested).
--- Eviction is by VALUE, not by age (2026-08-18): the entries dropped are the
--- ones covering the least of the book, oldest first among equal coverage. The
--- ring used to truncate its tail, which spent its five slots on whatever
--- happened to overwrite something most recently -- one real ring held 40.9%,
--- 9.7%, 17.8%, 80.8% and 49.7%, where four were abandoned experiments and the
--- one worth keeping was a single rebuild from eviction. Surviving entries keep
--- their newest-first order, so display and index semantics are unchanged.
--- @param list table Array of checkpoint entries, newest first
--- @param limit number|nil Max entries (default XRAY_CHECKPOINT_LIMIT)
--- @return table The same list, trimmed in place
function ActionCache.trimCheckpoints(list, limit)
    limit = limit or ActionCache.XRAY_CHECKPOINT_LIMIT
    if #list <= limit then return list end
    local order = {}
    for i = 1, #list do order[i] = i end
    table.sort(order, function(a, b)
        local ca, cb = checkpointCoverage(list[a]), checkpointCoverage(list[b])
        if ca ~= cb then return ca > cb end
        return a < b
    end)
    local keep = {}
    for i = 1, limit do keep[order[i]] = true end
    for i = #list, 1, -1 do
        if not keep[i] then table.remove(list, i) end
    end
    return list
end

--- Load the checkpoint ring for a book (newest first).
--- @param document_path string The document file path
--- @return table Array of { progress_decimal, progress_page, timestamp, archived_at, result }
function ActionCache.getXrayCheckpoints(document_path)
    local path = ActionCache.getXrayCheckpointsPath(document_path)
    if not path then return {} end

    local attr = lfs.attributes(path)
    if not attr or attr.mode ~= "file" then
        -- Try alternate storage mode locations (lazy migration on mode switch)
        if not migrateSidecarIfNeeded(document_path, path, ActionCache.XRAY_CHECKPOINTS_FILE) then
            return {}
        end
    end

    local ok, data = pcall(dofile, path)
    if not ok or type(data) ~= "table" then
        logger.warn("KOAssistant ActionCache: Failed to load X-Ray checkpoints:", path)
        return {}
    end
    -- Strip the save-time guard newline (same round-trip rule as loadCache)
    for _idx, cp in ipairs(data) do
        if type(cp) == "table" and type(cp.result) == "string"
            and cp.result:sub(-1) == "\n" then
            cp.result = cp.result:sub(1, -2)
        end
    end
    return data
end

--- Cheap ring count for hot paths — the artifact aggregation runs on
--- file-browser long-press, so never parse up to 20 archived JSONs just to
--- count them. Reads the writeCheckpointRing count header; pre-header files
--- (v1 rings) fall back to a full parse (the next write adds the header).
--- @param document_path string The document file path
--- @return number count
function ActionCache.getXrayCheckpointCount(document_path)
    local path = ActionCache.getXrayCheckpointsPath(document_path)
    if not path then return 0 end
    local attr = lfs.attributes(path)
    if not attr or attr.mode ~= "file" then
        if not migrateSidecarIfNeeded(document_path, path, ActionCache.XRAY_CHECKPOINTS_FILE) then
            return 0
        end
    end
    local file = io.open(path, "r")
    if not file then return 0 end
    local first = file:read("*l")
    file:close()
    local n = first and first:match("^%-%- count: (%d+)$")
    if n then return tonumber(n) end
    return #ActionCache.getXrayCheckpoints(document_path)
end

--- Archive a pre-overwrite X-Ray snapshot at the head of the ring.
--- @param document_path string The document file path
--- @param checkpoint table Cache-entry-shaped source (see CHECKPOINT_COPY_FIELDS)
--- @param limit number|nil Ring depth override (checkpointLimitFromFeatures; 0 = no archiving)
--- @return boolean success
function ActionCache.pushXrayCheckpoint(document_path, checkpoint, limit)
    if limit == 0 then return false end
    if not document_path or not checkpoint or not checkpoint.result then return false end
    local path = ActionCache.getXrayCheckpointsPath(document_path)
    if not path then return false end

    local ring = ActionCache.getXrayCheckpoints(document_path)
    table.insert(ring, 1, buildCheckpointEntry(checkpoint))
    ActionCache.trimCheckpoints(ring, limit)

    if not writeCheckpointRing(path, ring) then return false end
    logger.info("KOAssistant ActionCache: Archived X-Ray checkpoint at",
        tostring(checkpoint.progress_decimal), "for", document_path)
    return true
end

--- Remove one checkpoint from the ring.
--- @param document_path string The document file path
--- @param index number 1-based index into the ring (newest first)
--- @return boolean success
function ActionCache.removeXrayCheckpoint(document_path, index)
    local path = ActionCache.getXrayCheckpointsPath(document_path)
    if not path then return false end
    local ring = ActionCache.getXrayCheckpoints(document_path)
    if not ring[index] then return false end
    table.remove(ring, index)
    if #ring == 0 then
        os.remove(path)
        return true
    end
    return writeCheckpointRing(path, ring)
end

--- Pick the archived version nearest at-or-below a reading position — the
--- spoiler-safe view for a re-reader whose live X-Ray is ahead of them.
--- Half-percent tolerance; ties resolve to the newest entry; full-document
--- versions never qualify (they always contain whole-book spoilers).
--- @param ring table Checkpoint list (newest first)
--- @param current_decimal number Reader position 0..1
--- @return number|nil index into ring, or nil when every version is ahead
function ActionCache.nearestCheckpointIndex(ring, current_decimal)
    if type(ring) ~= "table" or type(current_decimal) ~= "number" then return nil end
    local best_idx, best_progress
    for i, cp in ipairs(ring) do
        local p = tonumber(cp.progress_decimal)
        if p and not cp.full_document and p <= current_decimal + 0.005 then
            if not best_progress or p > best_progress then
                best_idx, best_progress = i, p
            end
        end
    end
    return best_idx
end

--- Restore an archived version as the live X-Ray (move semantics: the outgoing
--- live entry takes a ring slot, the restored entry leaves the ring — a
--- restore round-trip never grows the ring). Writes BOTH cache keys: the
--- popup reads the per-action "xray" entry, the extractor and the background
--- pre-filter read the document-level key.
--- @param document_path string The document file path
--- @param index number 1-based index into the ring (newest first)
--- @param limit number|nil Ring depth override (checkpointLimitFromFeatures)
--- @return boolean success
--- @return table|nil entry The restored checkpoint entry (for notifications)
function ActionCache.restoreXrayCheckpoint(document_path, index, limit)
    local path = ActionCache.getXrayCheckpointsPath(document_path)
    if not path then return false end
    local ring = ActionCache.getXrayCheckpoints(document_path)
    local entry = ring[index]
    if not entry or not entry.result then return false end
    table.remove(ring, index)

    local live = ActionCache.getXrayCache(document_path)
    -- Shared archive rule (item 40 — this site MISSED it; promotion, the
    -- write-back primitive, and the response path all had it): a live entry
    -- that IS a ladder rung is already preserved there — archiving it here
    -- duplicated it ("17% today" AND "17% today · checkpoint" on device).
    if live and live.result and limit ~= 0
        and not ActionCache.isXrayLadderRung(document_path, live) then
        table.insert(ring, 1, buildCheckpointEntry(live))
    end
    ActionCache.trimCheckpoints(ring, limit)
    if #ring == 0 then
        os.remove(path)
    elseif not writeCheckpointRing(path, ring) then
        return false
    end

    local function pickFlag(archived, fallback)
        if archived ~= nil then return archived end
        return fallback
    end
    local meta = {
        model = entry.model or (live and live.model),
        timestamp = entry.timestamp,
        progress_page = entry.progress_page,
        full_document = entry.full_document,
        flow_visible_pages = entry.flow_visible_pages,
        source_mode = entry.source_mode or (live and live.source_mode),
        used_highlights = pickFlag(entry.used_highlights, live and live.used_highlights),
        used_annotations = pickFlag(entry.used_annotations, live and live.used_annotations),
        used_book_text = pickFlag(entry.used_book_text, live and live.used_book_text),
        -- A restore moves the pointer; the point keeps its own provenance
        coverage_spans = entry.coverage_spans,
        producer = entry.producer,
        base_timestamp = entry.base_timestamp,
        merged_from_books = entry.merged_from_books,
        merged_from = entry.merged_from,
        xray_categories = entry.xray_categories,
        xray_depth = entry.xray_depth,
    }
    local ok_doc = ActionCache.setXrayCache(document_path, entry.result, entry.progress_decimal or 0, meta)
    local ok_action = ActionCache.set(document_path, "xray", entry.result, entry.progress_decimal or 0, meta)
    logger.info("KOAssistant ActionCache: Restored X-Ray checkpoint at",
        tostring(entry.progress_decimal), "for", document_path)
    return (ok_doc and ok_action) == true, entry
end

--- Remove the checkpoint ring file (called when the X-Ray itself is deleted —
--- the ring is update-overwrite insurance, not delete insurance).
--- @param document_path string The document file path
--- @return boolean success
function ActionCache.clearXrayCheckpoints(document_path)
    local path = ActionCache.getXrayCheckpointsPath(document_path)
    if path then os.remove(path) end
    return true
end

-- =============================================================================
-- X-Ray version ladder (create-ahead prefix versions — xray_ecosystem_plan.md
-- §5 decisions 10/11 + §6 slice 1, ref #73 #90). SEPARATE file from the
-- checkpoint ring above, deliberately: the ring trims to xray_versions_kept on
-- EVERY push (one update after a 10-rung build would destroy rungs), and its
-- restore is move-out. The ladder is an immutable, position-indexed rung SET —
-- ascending by progress, copy-out semantics: viewing or promoting a rung never
-- removes it. Same entry shape and serializer as the ring (count header
-- included, so getXrayLadderCount stays O(1) on aggregation hot paths).
-- =============================================================================

ActionCache.XRAY_LADDER_FILE = "koassistant_xray_ladder.lua"
-- Rungs within half a percent are the same rung (a resume/re-run replaces it)
ActionCache.LADDER_TOLERANCE = 0.005

--- Get path to the X-Ray ladder sidecar file
--- @param document_path string The document file path
--- @return string|nil path Full path, or nil if not applicable
function ActionCache.getXrayLadderPath(document_path)
    if not document_path
        or document_path == "__GENERAL_CHATS__"
        or document_path == "__LIBRARY_CHATS__" then
        return nil
    end
    local sidecar_dir = DocSettings:getSidecarDir(document_path)
    return sidecar_dir .. "/" .. ActionCache.XRAY_LADDER_FILE
end

--- Load the ladder for a book, ascending by progress.
--- @param document_path string The document file path
--- @return table Array of checkpoint-shaped rung entries (CHECKPOINT_COPY_FIELDS)
function ActionCache.getXrayLadder(document_path)
    local path = ActionCache.getXrayLadderPath(document_path)
    if not path then return {} end

    local attr = lfs.attributes(path)
    if not attr or attr.mode ~= "file" then
        if not migrateSidecarIfNeeded(document_path, path, ActionCache.XRAY_LADDER_FILE) then
            return {}
        end
    end

    local ok, data = pcall(dofile, path)
    if not ok or type(data) ~= "table" then
        logger.warn("KOAssistant ActionCache: Failed to load X-Ray ladder:", path)
        return {}
    end
    -- Strip the save-time guard newline (same round-trip rule as loadCache)
    for _idx, rung in ipairs(data) do
        if type(rung) == "table" and type(rung.result) == "string"
            and rung.result:sub(-1) == "\n" then
            rung.result = rung.result:sub(1, -2)
        end
    end
    table.sort(data, function(a, b)
        return (tonumber(a.progress_decimal) or 0) < (tonumber(b.progress_decimal) or 0)
    end)
    return data
end

--- Cheap rung count for hot paths (count header; pre-header files full-parse).
--- @param document_path string The document file path
--- @return number count
function ActionCache.getXrayLadderCount(document_path)
    local path = ActionCache.getXrayLadderPath(document_path)
    if not path then return 0 end
    local attr = lfs.attributes(path)
    if not attr or attr.mode ~= "file" then
        if not migrateSidecarIfNeeded(document_path, path, ActionCache.XRAY_LADDER_FILE) then
            return 0
        end
    end
    local file = io.open(path, "r")
    if not file then return 0 end
    local first = file:read("*l")
    file:close()
    local n = first and first:match("^%-%- count: (%d+)$")
    if n then return tonumber(n) end
    return #ActionCache.getXrayLadder(document_path)
end

--- Highest rung progress in a loaded ladder (resume point for the build chain).
--- Pure — takes the loaded array, not a path. Intro rungs (round 20: premise-only
--- versions at progress 0) are skipped — an intro is not a resume point, and an
--- intro-only ladder must still read as "from nothing".
--- @param ladder table Rung array (any order)
--- @return number|nil progress 0..1, or nil for an empty ladder
function ActionCache.highestXrayLadderProgress(ladder)
    local best
    for _idx, rung in ipairs(ladder or {}) do
        local p = tonumber(rung.progress_decimal)
        if p and not rung.intro and (not best or p > best) then best = p end
    end
    return best
end

--- Save one rung. A rung within LADDER_TOLERANCE of an existing one replaces it
--- (resume re-runs, never duplicates); otherwise inserted in ascending order.
--- @param document_path string The document file path
--- @param rung table Cache-entry-shaped source (see CHECKPOINT_COPY_FIELDS)
--- @return boolean success
function ActionCache.pushXrayLadderRung(document_path, rung)
    if not document_path or not rung or not rung.result then return false end
    local path = ActionCache.getXrayLadderPath(document_path)
    if not path then return false end

    local ladder = ActionCache.getXrayLadder(document_path)
    local entry = buildCheckpointEntry(rung)
    local p = tonumber(entry.progress_decimal) or 0
    local replaced = false
    for i, existing in ipairs(ladder) do
        if math.abs((tonumber(existing.progress_decimal) or 0) - p) <= ActionCache.LADDER_TOLERANCE then
            ladder[i] = entry
            replaced = true
            break
        end
    end
    if not replaced then
        table.insert(ladder, entry)
        table.sort(ladder, function(a, b)
            return (tonumber(a.progress_decimal) or 0) < (tonumber(b.progress_decimal) or 0)
        end)
    end

    if not writeCheckpointRing(path, ladder) then return false end
    logger.dbg("KOAssistant ActionCache: Saved X-Ray ladder rung at", tostring(p), "for", document_path)
    return true
end

--- Persist a loaded-and-modified ladder array (the dedup ladder sweep edits
--- rung RESULTS in place). Timestamps and progress MUST be preserved by the
--- caller — promotion and rung identity match on them.
--- @param document_path string The document file path
--- @param ladder table getXrayLadder output, possibly modified
--- @return boolean success
function ActionCache.saveXrayLadder(document_path, ladder)
    if type(ladder) ~= "table" or #ladder == 0 then return false end
    local path = ActionCache.getXrayLadderPath(document_path)
    if not path then return false end
    return writeCheckpointRing(path, ladder)
end

--- Remove ONE rung, identity-matched (timestamp + progress). Round 24
--- (maintainer: version viewers must allow deleting specific versions) —
--- safe under the unified engine: the grid re-plans a missing point when it
--- is ever needed again, and promotion simply has one fewer candidate.
--- @param document_path string The document file path
--- @param rung table A rung entry (from getXrayLadder or a viewer)
--- @return boolean success
function ActionCache.removeXrayLadderRung(document_path, rung)
    if not document_path or not rung then return false end
    local path = ActionCache.getXrayLadderPath(document_path)
    if not path then return false end
    local ladder = ActionCache.getXrayLadder(document_path)
    local p = tonumber(rung.progress_decimal)
    for i, existing in ipairs(ladder) do
        if existing.timestamp == rung.timestamp and p
            and math.abs((tonumber(existing.progress_decimal) or -1) - p) < 1e-6 then
            table.remove(ladder, i)
            if #ladder == 0 then
                os.remove(path)
                return true
            end
            return writeCheckpointRing(path, ladder)
        end
    end
    return false
end

--- Remove the ladder file (whole-ladder delete; per-rung delete above).
--- @param document_path string The document file path
--- @return boolean success
function ActionCache.clearXrayLadder(document_path)
    local path = ActionCache.getXrayLadderPath(document_path)
    if path then os.remove(path) end
    return true
end

--- Is this cache entry one of the book's ladder rungs? (Identity: timestamp +
--- progress.) THE shared archive rule: an entry that lives in the ladder is
--- never ring-archived — the rung already preserves it, and dups would evict
--- real ring history. Used by promotion, the write-back primitive, and the
--- response path's checkpoint push.
--- @param document_path string The document file path
--- @param entry table|nil A cache entry (live or otherwise)
--- @return boolean
function ActionCache.isXrayLadderRung(document_path, entry)
    if not entry or entry.timestamp == nil then return false end
    local p = tonumber(entry.progress_decimal)
    if not p then return false end
    for _idx, rung in ipairs(ActionCache.getXrayLadder(document_path)) do
        if rung.timestamp == entry.timestamp
            and math.abs((tonumber(rung.progress_decimal) or -1) - p) < 1e-6 then
            return true
        end
    end
    return false
end

--- Promote a rung into the live X-Ray (COPY semantics — the rung stays in the
--- ladder). The outgoing live entry is ring-archived ONLY when it is not itself
--- a ladder rung (isXrayLadderRung) — otherwise every promotion would fill the
--- ring with rung duplicates. Writes BOTH cache keys, like
--- restoreXrayCheckpoint.
--- @param document_path string The document file path
--- @param rung table A rung entry from getXrayLadder
--- @param limit number|nil Ring depth (checkpointLimitFromFeatures; 0 = no archiving)
--- @param opts table|nil { manual = true } → not marked "auto" in the popup trace;
---   { posture_ahead = true } → 50(f) FULL-posture ahead install (stamps
---   posture_promoted for the spoiler-reenable revert)
--- @return boolean success
function ActionCache.promoteXrayLadderRung(document_path, rung, limit, opts)
    if not document_path or not rung or not rung.result then return false end

    local live = ActionCache.getXrayCache(document_path)
    if live and live.result and live.result ~= rung.result and limit ~= 0
        and not ActionCache.isXrayLadderRung(document_path, live) then
        ActionCache.pushXrayCheckpoint(document_path, live, limit)
    end

    -- Round-26 principle at the PROMOTION doorway (2026-08-14): a rung
    -- install replaces the live artifact, and knowledge folded onto it
    -- (cross-book background from group folds/links/dedup absorbs) died
    -- with the swap — rebuild got the carry, the silent page-turn doorway
    -- didn't. Re-stub the outgoing artifact's background carriers into the
    -- incoming rung's OWN ledger (union by name — the rung's chain-carried
    -- ledger stays the base; a wholesale copy would clobber it), then wake
    -- whatever matches the rung's entities. The install keeps the rung's
    -- timestamp, so rung identity (isXrayLadderRung) and the ring-dedup
    -- skip are untouched; restoring the rung from "All versions" still
    -- yields the pure rung. pcall-guarded: any failure installs verbatim —
    -- the carry must never block a promotion.
    local install_result = rung.result
    if live and live.result and live.result ~= rung.result then
        local ok_carry, carried_out, carried_n, woken_n, ledger_n = pcall(function()
            local XrayParser = require("koassistant_xray_parser")
            if not XrayParser.isJSON(live.result) or not XrayParser.isJSON(rung.result) then
                return nil
            end
            local prev_parsed = XrayParser.parse(live.result)
            if type(prev_parsed) ~= "table" or prev_parsed.error then return nil end
            local parsed = XrayParser.parse(rung.result)
            if type(parsed) ~= "table" or parsed.error then return nil end
            local XrayMerge = require("koassistant_xray_merge")
            -- F1 (B278, 2026-08-30): the outgoing LEDGER first — stubs only
            -- the live artifact held (a fold made after this rung was built,
            -- an alias edited onto a stub) died with the swap; the rebuild
            -- path has carried the outgoing ledger across since round 25
            -- S4 tombstones: a carried entry the reader removed stays
            -- removed — dropped from the rung's own copy, never re-unioned
            local skip = ActionCache.getRemovedStubs(document_path)
            local dropped = XrayParser.dropStubs(parsed, skip)
            local u_added, u_refreshed = XrayMerge.unionLedger(prev_parsed, parsed, skip)
            local n = XrayMerge.carryActiveBackground(prev_parsed, parsed)
            local woken = XrayParser.wakeDormant(parsed)
            if u_added == 0 and u_refreshed == 0 and n == 0 and #woken == 0
                    and dropped == 0 then
                return nil
            end
            return XrayParser.serialize(parsed), n, #woken, u_added + u_refreshed
        end)
        if ok_carry and type(carried_out) == "string" then
            install_result = carried_out
            logger.dbg("KOAssistant ActionCache: promotion carried background of",
                tostring(carried_n), "entit(y/ies),", tostring(woken_n), "woken,",
                tostring(ledger_n), "ledger stub(s) unioned, from the outgoing X-Ray")
        end
    end

    local function pickFlag(archived, fallback)
        if archived ~= nil then return archived end
        return fallback
    end
    local meta = {
        model = rung.model or (live and live.model),
        timestamp = rung.timestamp,
        progress_page = rung.progress_page,
        full_document = rung.full_document,
        flow_visible_pages = rung.flow_visible_pages,
        source_mode = rung.source_mode or (live and live.source_mode),
        used_highlights = pickFlag(rung.used_highlights, live and live.used_highlights),
        used_annotations = pickFlag(rung.used_annotations, live and live.used_annotations),
        used_book_text = pickFlag(rung.used_book_text, live and live.used_book_text),
        updated_by_auto = not (opts and opts.manual) or nil,
        -- 50(f): stamped by the promotion fire when the FULL posture installs
        -- a rung ahead of the reading position (revert provenance)
        posture_promoted = (opts and opts.posture_ahead) or nil,
        intro = rung.intro,
        -- A promotion moves the pointer; the point keeps its own provenance
        coverage_spans = rung.coverage_spans,
        producer = rung.producer,
        base_timestamp = rung.base_timestamp,
        merged_from_books = rung.merged_from_books,
        merged_from = rung.merged_from,
        -- The rung's OWN category stamp (nil = built full) — never the live
        -- entry's: the field describes the artifact it rides with
        xray_categories = rung.xray_categories,
        xray_depth = rung.xray_depth,
    }
    local ok_doc = ActionCache.setXrayCache(document_path, install_result, rung.progress_decimal or 0, meta)
    local ok_action = ActionCache.set(document_path, "xray", install_result, rung.progress_decimal or 0, meta)
    logger.info("KOAssistant ActionCache: Promoted X-Ray ladder rung at",
        tostring(rung.progress_decimal), "for", document_path)
    return (ok_doc and ok_action) == true
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
        -- Page-based (PDF/DJVU): the document object is stateless — position
        -- lives on the reader's VIEW. Read it only when this doc IS the live
        -- reader's document (identity guard; artifact_browser precedent).
        -- Before this, the branch was empty and section-in-range never fired
        -- on page-based books.
        local ok, ReaderUI = pcall(require, "apps/reader/readerui")
        local inst = ok and ReaderUI.instance
        if inst and inst.document == doc and inst.view and inst.view.state then
            return inst.view.state.page
        end
        return nil
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
-- Exported for the marks scan (slice 2): section ranges resolve once per
-- disk change there and compare per page turn without re-parsing
ActionCache.getSectionPageRange = getSectionPageRange

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

    -- 1. Check section X-Rays for one covering current page.
    -- Item 40 (maintainer): a section already MERGED into main is part of the
    -- timeline — main carries its content, so it no longer outranks main
    -- here. Without a main (deleted later) the stamp is historical and the
    -- section still serves in steps below.
    if current_page and #sections > 0 then
        local in_range = {}
        for _idx, sec in ipairs(sections) do
            local sp, ep = getSectionPageRange(sec.data, doc)
            if sp and ep and current_page >= sp and current_page <= ep
                and not (has_main and sec.data.merged_to_main) then
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

--- Search for a query across all X-Rays (main + sections) for a document.
--- Returns results grouped by X-Ray, sorted: main first, then in-range section, then chronological.
--- @param document_path string The document file path
--- @param query string Search query
--- @param doc table|nil Document object (for current page detection)
--- @param opts table|nil Options passed to searchAll (e.g., skip_description)
--- @return table Array of { key, label, is_section, scope_summary, results, cache_entry }
-- Memoized exact-handle route index behind the selection intercept (slice 2,
-- ref #63): one normalized-handle set across the main + every section X-Ray,
-- rebuilt only when the book's cache file or user-aliases sidecar changes on
-- disk (mtime+size key — a stat per lookup instead of a full parse per tap).
-- One book at a time: taps are reader-scoped, a different file swaps the slot.
-- Per-book parsed X-Ray memo for group reads (S3, ref #90): the whole-chain
-- lookup and the carried page's "Open in <title>'s X-Ray" parse each earlier
-- book once per stamp; the steady state is a stat call. Bounded: wiped when
-- it outgrows PARSED_XRAY_MEMO_MAX entries (a rare group edit, not a hot path).
local parsed_xray_memo = {}
local parsed_xray_memo_n = 0
local PARSED_XRAY_MEMO_MAX = 12

--- Nearest earlier X-Rayed book in the current book's ORDERED group (S2,
--- ref #90): its parsed main X-Ray (own user aliases merged) answers
--- lookups/marks/cards when this book — carried list included — does not.
--- READ-ONLY tier, so deliberately NO consent gate (nothing leaves the
--- device at lookup time; the carry-in WRITE checks consent like the
--- create-time seed). ai_knowledge/non-JSON lineages never answer, same
--- rule as every other lookup source.
--- Memoized on the cache-file AND user-aliases stamps of EVERY predecessor
--- (a new X-Ray appearing on a NEARER book must re-pick), so steady state
--- is one in-memory group read + two stats per predecessor.
--- @param document_path string Current book
--- @return table|nil { file, title, data, entry, more, stamp } — `more` =
---   how many FURTHER predecessors have a cache file (the "Search all
---   earlier books" row's visibility); `stamp` keys consumer memos.
--- Parsed live X-Ray of ANY book, memoized on that book's cache + alias
--- stamps (S3, ref #90). nil when the book has no valid text-based JSON
--- X-Ray. The returned tables are SHARED across callers: read, never mutate.
--- @param file string Book path
--- @return table|nil { file, title, data (user aliases merged), entry, stamp }
function ActionCache.parsedXrayFor(file)
    if type(file) ~= "string" or file == "" then return nil end
    local cp = ActionCache.getPath(file)
    local ca = cp and lfs.attributes(cp)
    if not ca then return nil end
    local ap = ActionCache.getUserAliasesPath(file)
    local aa = ap and lfs.attributes(ap)
    local stamp = tostring(ca.modification) .. ":" .. tostring(ca.size) .. "|"
        .. (aa and (tostring(aa.modification) .. ":" .. tostring(aa.size)) or "-")
    local m = parsed_xray_memo[file]
    if m and m.stamp == stamp then return m.res or nil end
    local XrayParser = require("koassistant_xray_parser")
    local res = false
    local entry = ActionCache.getXrayCache(file)
    if entry and entry.result and entry.source_mode ~= "ai_knowledge"
            and XrayParser.isJSON(entry.result) then
        local data = XrayParser.parse(entry.result)
        if data and not data.error then
            XrayParser.mergeUserAliases(data, ActionCache.getUserAliases(file))
            local ok_bg, BookGroups = pcall(require, "koassistant_book_groups")
            res = {
                file = file,
                title = ok_bg and BookGroups.displayTitle(file) or file,
                data = data,
                entry = entry,
                stamp = stamp,
            }
        end
    end
    if not m then
        if parsed_xray_memo_n >= PARSED_XRAY_MEMO_MAX then
            parsed_xray_memo = {}
            parsed_xray_memo_n = 0
        end
        parsed_xray_memo_n = parsed_xray_memo_n + 1
    end
    parsed_xray_memo[file] = { stamp = stamp, res = res }
    return res or nil
end

-- Lookup direction (S4, ref #90): the ordered-group "earlier books only"
-- rule is a spoiler guard, so it stands down exactly when spoiler protection
-- does for the current book (off, finished, research). main.lua injects the
-- resolver — it owns the settings and the live DocSettings; without one,
-- earlier books only.
local lookup_both_ways = nil
function ActionCache.setLookupDirectionResolver(fn)
    lookup_both_ways = fn
end
local function bothWays(document_path)
    if type(lookup_both_ways) ~= "function" then return false end
    local ok, res = pcall(lookup_both_ways, document_path)
    return ok and res == true
end

--- Every group book whose X-Ray may answer a lookup for this book, in rank
--- order (S4, ref #90): ordered group = earlier books nearest first, then —
--- only when the current book is not under spoiler protection — later books
--- nearest first; unordered knowledge-sharing group (project) = every other
--- member; plain group = none. Entries are parsedXrayFor's shape plus
--- `direction` ("earlier" | "later" | nil for unordered groups). Each book
--- parses once per stamp; the walk itself is a stat per book.
--- @param document_path string
--- @return table list (possibly empty), string stamp (every book's stamp +
---   the direction — memo keys carry it, so a protection flip re-indexes)
function ActionCache.groupXrays(document_path)
    local out = {}
    if not document_path then return out, "-" end
    local ok_bg, BookGroups = pcall(require, "koassistant_book_groups")
    if not ok_bg or type(BookGroups.lookupBooksFor) ~= "function" then return out, "-" end
    local both = bothWays(document_path)
    local rows = BookGroups.lookupBooksFor(document_path, both)
    if #rows == 0 then return out, "-" end
    local parts = { both and "both" or "earlier" }
    for _idx, row in ipairs(rows) do
        local px = ActionCache.parsedXrayFor(row.file)
        if px then
            local e = {}
            for k, v in pairs(px) do e[k] = v end
            e.direction = row.direction
            out[#out + 1] = e
            parts[#parts + 1] = (row.direction or "any") .. ":" .. px.stamp
        else
            parts[#parts + 1] = "-"
        end
    end
    return out, table.concat(parts, "|")
end

--- The first group X-Ray in rank order (the nearest earlier book while
--- protected), with `more` = how many further group X-Rays exist and the
--- combined stamp; nil when none. Thin over groupXrays.
--- @param document_path string
--- @return table|nil { file, title, data, entry, direction, more, stamp }
function ActionCache.nearestGroupXray(document_path)
    local list, stamp = ActionCache.groupXrays(document_path)
    if #list == 0 then return nil end
    local res = {}
    for k, v in pairs(list[1]) do res[k] = v end
    res.more = #list - 1
    res.stamp = stamp
    return res
end

local exact_route_index = nil -- { path, key, set }

--- Would searchAll's EXACT mode match this query in ANY of the book's X-Rays
--- (main + sections, user search terms folded in)? Boolean route decision
--- only — the actual lookup re-parses through handleLocalXrayLookup.
--- @param document_path string
--- @param query string
--- @return boolean
--- B269 ladder-meta memo: rung coverages + stamps per ladder file stamp,
--- so the per-tap rung pick is arithmetic (the full ladder loads only when
--- the route index actually rebuilds)
local ladder_meta_memo = nil -- { path, key, rungs = {{p, stamp, intro, has_result}} }

function ActionCache.matchAnyXrayExact(document_path, query, opts)
    if not document_path or type(query) ~= "string" or query == "" then
        return false
    end
    -- P5: opts.include_ahead == false stands the ahead peek down (the
    -- Upcoming Entities setting; default on — callers read it per call).
    -- B269: the peek needs opts.position (0..1); without it there is none.
    local include_ahead = not (opts and opts.include_ahead == false)
        and type(opts and opts.position) == "number"
    local path = ActionCache.getPath(document_path)
    if not path then return false end
    -- S2 (ref #90): a book with NO cache file of its own can still route
    -- through its group's nearest X-Rayed predecessor — the reporter's
    -- "never X-Rayed this volume" case — so the missing-file return only
    -- fires when there is no predecessor either.
    local attr = lfs.attributes(path)
    if attr and attr.mode ~= "file" then return false end
    local group_list, group_stamp = ActionCache.groupXrays(document_path)
    if not attr and #group_list == 0 then return false end
    local key = attr and (tostring(attr.modification) .. "|" .. tostring(attr.size)) or "-"
    local alias_path = ActionCache.getUserAliasesPath(document_path)
    local aattr = alias_path and lfs.attributes(alias_path)
    if aattr then
        key = key .. "|" .. tostring(aattr.modification) .. "|" .. tostring(aattr.size)
    end
    -- Point-4: ONE built checkpoint ahead of the live artifact joins the
    -- route (the card's identification peek must FIRE for ahead-only
    -- entities). B269: the rung covering the reader's stretch, picked per
    -- call from a per-ladder-stamp meta memo; the PICKED rung's stamp joins
    -- the key, so moving into the next checkpoint's stretch re-indexes. The
    -- flag state joins the key either way, so a settings flip invalidates.
    local ahead_stamp
    if include_ahead then
        local ladder_path = ActionCache.getXrayLadderPath(document_path)
        local lattr = ladder_path and lfs.attributes(ladder_path)
        if lattr then
            local lkey = tostring(lattr.modification) .. "|" .. tostring(lattr.size)
            if not (ladder_meta_memo and ladder_meta_memo.path == ladder_path
                    and ladder_meta_memo.key == lkey) then
                local rungs = {}
                for _idx, rg in ipairs(ActionCache.getXrayLadder(document_path)) do
                    rungs[#rungs + 1] = { progress_decimal = rg.progress_decimal,
                        full_document = rg.full_document, intro = rg.intro,
                        result = rg.result and true or nil, stamp = tostring(rg.timestamp) }
                end
                ladder_meta_memo = { path = ladder_path, key = lkey, rungs = rungs }
            end
            local live_e = ActionCache.getXrayCache(document_path)
            local live_p = live_e and (live_e.full_document and 1.0
                or tonumber(live_e.progress_decimal)) or 0
            local pick = require("koassistant_xray_auto").pickAheadRung(
                ladder_meta_memo.rungs, live_p, opts.position)
            ahead_stamp = pick and pick.stamp or nil
        end
    end
    key = key .. (ahead_stamp and ("|ahead:" .. ahead_stamp) or "|noahead")
    -- Predecessor tier (S2 Q4, ref #90): the nearest earlier X-Rayed book's
    -- handles join the route so its entities intercept/tap like local ones.
    -- Rank-free here by design — the SET only routes; the card router owns
    -- the order (live -> sections -> carried -> predecessor -> ahead).
    key = key .. "|group:" .. group_stamp
    if not (exact_route_index and exact_route_index.path == path
            and exact_route_index.key == key) then
        local XrayParser = require("koassistant_xray_parser")
        local set = {}
        local user_aliases = ActionCache.getUserAliases(document_path)
        local live_p = 0
        local main = ActionCache.getXrayCache(document_path)
        if main and main.result then
            live_p = main.full_document and 1.0
                or tonumber(main.progress_decimal) or 0
            local data = XrayParser.parse(main.result)
            if data then
                XrayParser.mergeUserAliases(data, user_aliases)
                XrayParser.foldExactHandles(data, set)
                -- Carried tier (S1, ref #90): the ledger's stub handles join
                -- the route UNCONDITIONALLY — earlier books are already-read
                -- content, so the Upcoming Entities flag never gates them (Q8).
                -- The ledger lives inside the cache file, so the existing
                -- stamp key already invalidates on every ledger edit.
                XrayParser.foldLedgerHandles(data, set)
            end
        end
        for _idx, sec in ipairs(ActionCache.getSectionXrays(document_path)) do
            local data = sec.data and sec.data.result
                and XrayParser.parse(sec.data.result)
            if data then
                XrayParser.mergeUserAliases(data, user_aliases)
                XrayParser.foldExactHandles(data, set)
            end
        end
        local ahead
        if ahead_stamp then
            for _idx, rg in ipairs(ActionCache.getXrayLadder(document_path)) do
                if tostring(rg.timestamp) == ahead_stamp then ahead = rg end
            end
        end
        if ahead and ahead.result then
            local data = XrayParser.parse(ahead.result)
            if data then
                XrayParser.mergeUserAliases(data, user_aliases)
                XrayParser.foldExactHandles(data, set)
            end
        end
        -- S4: every group book the direction rule allows (earlier first,
        -- later only when unprotected, every member of a project) folds in
        for _idx, g in ipairs(group_list) do
            XrayParser.foldExactHandles(g.data, set)
            XrayParser.foldLedgerHandles(g.data, set)
        end
        exact_route_index = { path = path, key = key, set = set }
    end
    return require("koassistant_xray_parser")
        .matchExactHandle(exact_route_index.set, query)
end

function ActionCache.searchAllXrays(document_path, query, doc, opts)
    if not document_path or not query or query == "" then return {} end

    local XrayParser = require("koassistant_xray_parser")
    local sections = ActionCache.getSectionXrays(document_path)
    local main = ActionCache.getXrayCache(document_path)
    local current_page = getCurrentPageFromDoc(doc)
    local all_results = {}
    -- User search terms must match here too, not only in the browser — this is
    -- the matcher behind highlight-menu lookup AND the #63 conditional bypass
    -- (F1, xray_marking_plan.md; one sidecar read serves every parse below)
    local user_aliases = ActionCache.getUserAliases(document_path)

    -- Search main X-Ray
    if main and main.result then
        local data = XrayParser.parse(main.result)
        if data then
            XrayParser.mergeUserAliases(data, user_aliases)
            local results = XrayParser.searchAll(data, query, opts)
            if #results > 0 then
                table.insert(all_results, {
                    key = ActionCache.XRAY_CACHE_KEY,
                    label = nil, -- signals "Main X-Ray" to caller
                    is_section = false,
                    scope_summary = nil,
                    results = results,
                    cache_entry = main,
                    _sort_page = -1, -- always first
                })
            end
        end
    end

    -- Search each section X-Ray
    for _idx, sec in ipairs(sections) do
        local data = XrayParser.parse(sec.data.result)
        if data then
            XrayParser.mergeUserAliases(data, user_aliases)
            local results = XrayParser.searchAll(data, query, opts)
            if #results > 0 then
                local sp, ep = getSectionPageRange(sec.data, doc)
                local in_range = sp and ep and current_page
                    and current_page >= sp and current_page <= ep
                local page_summary = sec.data.scope_page_summary
                -- Reconvert if doc available
                if doc and doc.getPageFromXPointer and sec.data.scope_start_xpointer then
                    page_summary = ActionCache.reconvertPageSummary(sec.data, doc)
                end
                table.insert(all_results, {
                    key = sec.key,
                    label = sec.label,
                    is_section = true,
                    scope_summary = page_summary,
                    in_range = in_range,
                    results = results,
                    cache_entry = sec.data,
                    _sort_page = sp or 0,
                })
            end
        end
    end

    -- Sort: main first (sort_page=-1), in-range sections next, then chronological
    table.sort(all_results, function(a, b)
        -- Main always first
        if not a.is_section then return true end
        if not b.is_section then return false end
        -- In-range sections before out-of-range
        if a.in_range and not b.in_range then return true end
        if not a.in_range and b.in_range then return false end
        -- Chronological by start page
        return a._sort_page < b._sort_page
    end)

    return all_results
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
