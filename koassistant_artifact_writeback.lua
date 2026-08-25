--[[--
Shared artifact write-back primitive (xray_ecosystem_plan.md §6 slice 2, ref #90).

ONE canonical sequence for every writer that lands a model output in a book's
X-Ray: parse/repair → (delta mode) merge into a base → reconcile permission +
coverage metadata (sticky-true superset — an artifact that CONTAINS data built
from a source keeps that source's flag even when the newest pass didn't use it)
→ archive the outgoing live version (ring push, SKIPPED when the outgoing entry
is a ladder rung: rung duplicates would evict real history) → write BOTH cache
keys (doc-level `_xray_cache` + per-action "xray" — single-key writes caused
resurrection bugs, see index_rebuild history) → resync the caller's background
pre-filter.

Consumers: the merge engine (§6 slice 3), tool-assisted deepen / chat
write-back / artifact-edit-via-chat (W3+ d/e/g). The interface is
artifact-type-generic in shape; only the X-Ray dispatch ships in v1 (§5
decision 9 — summaries are a prose-merge fast-follow through the same seam).

handleResponse (koassistant_dialogs.lua) keeps its own historically-verified
write path — its per-action vs doc-level metadata divergence is deliberate and
audit-sensitive — but shares the ARCHIVE RULE via ActionCache.isXrayLadderRung.
If slice 3 work touches that path anyway, folding it onto applyXray is the
recorded cleanup.
]]

local logger = require("koassistant_logger")

local WriteBack = {}

--- Sticky-true reconciliation for one permission flag: true on either side
--- stays true (the merged artifact still contains that data); an explicit
--- new value otherwise wins; base fills the rest. Pure.
local function stickyFlag(new_v, base_v)
    if new_v == true or base_v == true then return true end
    if new_v ~= nil then return new_v end
    return base_v
end

-- Fields inherited from the base when the new pass doesn't supply them:
-- provenance continuity (model/source_mode) AND the coverage/lineage
-- companions — dropping full_document would let a complete-track artifact
-- slip into the incremental machinery (background updates, ladder promotion),
-- and dropping progress_page breaks the next incremental extraction under
-- hidden flows. Same field set as CHECKPOINT_COPY_FIELDS / restore / promote.
local BASE_CONTINUITY_FIELDS = {
    "model", "source_mode", "full_document", "progress_page", "flow_visible_pages",
    -- The artifact still CONTAINS the other books' background after later
    -- updates (item 43 cross-book provenance; the ledger is its dated form —
    -- both inherit or a rebuild would look like it had never been folded into)
    "merged_from_books",
    "merged_from",
    -- Category stamp (presets v0.21): a dedup/browser-edit/merge commit rewrites
    -- the same lineage — the stamp must survive it
    "xray_categories",
    "xray_depth",
}

--- Reconcile permission/provenance metadata for a write that merges new
--- material into (or replaces) a base entry. Pure — returns a NEW table.
--- Sticky-true superset on the used_* flags (incl. the legacy
--- used_annotations→used_highlights implication); continuity fields fall back
--- to the base; a provenance TABLE in web_search_used is normalized to a plain
--- boolean (the manual cache serializer would otherwise corrupt the whole
--- book cache file — see CLAUDE.md Provenance note).
--- @param base_entry table|nil The cache entry being built upon (may be nil = fresh)
--- @param new_meta table|nil Metadata describing the NEW material/pass
--- @return table meta
function WriteBack.reconcileXrayMeta(base_entry, new_meta)
    local base = base_entry or {}
    local meta = {}
    for k, v in pairs(new_meta or {}) do meta[k] = v end
    -- Legacy caches used used_annotations to mean highlights (extractor read
    -- gate treats nil-highlights + annotations-true as highlights-true)
    local base_highlights = base.used_highlights
    if base_highlights == nil and base.used_annotations == true then
        base_highlights = true
    end
    meta.used_highlights = stickyFlag(new_meta and new_meta.used_highlights, base_highlights)
    meta.used_annotations = stickyFlag(new_meta and new_meta.used_annotations, base.used_annotations)
    meta.used_book_text = stickyFlag(new_meta and new_meta.used_book_text, base.used_book_text)
    for _idx, field in ipairs(BASE_CONTINUITY_FIELDS) do
        if meta[field] == nil then meta[field] = base[field] end
    end
    -- Coverage spans (timeline slice 1): the merged artifact still CONTAINS
    -- the base's covered content — union, never overwrite. Legacy bases
    -- derive through the read-through (scope pages / prefix claim); a
    -- whole-book base contributes via the full_document continuity flag
    -- instead (no page total here).
    local base_spans = WriteBack.spansFromEntry(base)
    if meta.coverage_spans ~= nil or base_spans ~= nil then
        meta.coverage_spans = WriteBack.unionSpans(meta.coverage_spans, base_spans)
    end
    -- Provenance-per-point: base identity defaults to the entry built upon
    if meta.base_timestamp == nil then meta.base_timestamp = base.timestamp end
    if type(meta.web_search_used) == "table" then
        -- Same rule as handleResponse's web_search_flag: a provenance table
        -- means web search only when its web_search field says so (it may
        -- carry only book_tools)
        meta.web_search_used = meta.web_search_used.web_search == true
    end
    return meta
end

--- Coverage summary for a set of scope-carrying inputs (section entries or any
--- {label, start_page, end_page} list). Pure. Returns the maximum end coverage
--- plus the page gaps between consecutive inputs — slice 3's "warn, never
--- block" data (a gap is a completeness concern, not a spoiler concern: the
--- merged progress stays honest as a spoiler ceiling since content is a
--- subset).
--- @param inputs table Array of { label, start_page, end_page } (any order)
--- @param total_pages number|nil For the end-coverage ratio (nil = no ratio)
--- @return table { end_page, progress_decimal|nil, gaps = { {after_label, before_label, from_page, to_page} } }
function WriteBack.coverageFromInputs(inputs, total_pages)
    local sorted = {}
    for _idx, item in ipairs(inputs or {}) do
        if item.start_page and item.end_page then
            sorted[#sorted + 1] = item
        end
    end
    table.sort(sorted, function(a, b) return a.start_page < b.start_page end)
    local gaps = {}
    local end_page = 0
    local reach = nil  -- running maximum: nested inputs (a parent TOC span
    local reach_label  -- containing its chapters) must not fake gaps
    for _idx, item in ipairs(sorted) do
        if reach and item.start_page > reach + 1 then
            gaps[#gaps + 1] = {
                after_label = reach_label,
                before_label = item.label,
                from_page = reach + 1,
                to_page = item.start_page - 1,
            }
        end
        if not reach or item.end_page > reach then
            reach = item.end_page
            reach_label = item.label
        end
        if item.end_page > end_page then end_page = item.end_page end
    end
    local ratio
    if total_pages and total_pages > 0 and end_page > 0 then
        ratio = math.min(1.0, end_page / total_pages)
    end
    return { end_page = end_page, progress_decimal = ratio, gaps = gaps }
end

-- ===================== Coverage spans (timeline slice 1) =====================
-- A timeline point's coverage is a SET of inclusive page spans, canonically
-- encoded as "a-b,c-d" (INTERNAL pages, ascending, overlapping/adjacent spans
-- merged — same raw-pages convention as scope_start/end_page; display converts
-- via getPageNumberInFlow). Spans record what the content actually covers,
-- honestly across holes — merged spaced-apart sections no longer overstate.
-- Whole-book claims stay flag-based (full_document / progress 1.0) and derive
-- at read time via spansFromEntry: page totals drift on reflow, the flag
-- doesn't. Pointer eligibility (plan item 37(a)) is COMPUTED, never chosen: a
-- point may be live iff prefixCoverage() is non-nil.

--- Normalize a span set: accepts the canonical string or an array of
--- {from, to}; returns a NEW ascending array with overlapping/adjacent spans
--- merged and invalid members dropped. Pure.
--- @param spans string|table|nil
--- @return table Array of { from, to }
function WriteBack.parseSpans(spans)
    if type(spans) == "string" then
        local list = {}
        for a, b in spans:gmatch("(%d+)%s*%-%s*(%d+)") do
            list[#list + 1] = { from = tonumber(a), to = tonumber(b) }
        end
        spans = list
    end
    local list = {}
    for _idx, s in ipairs(spans or {}) do
        local from = tonumber(s.from)
        local to = tonumber(s.to)
        if from and to and from > 0 and to >= from then
            list[#list + 1] = { from = math.floor(from), to = math.floor(to) }
        end
    end
    table.sort(list, function(x, y) return x.from < y.from end)
    local merged = {}
    for _idx, s in ipairs(list) do
        local last = merged[#merged]
        if last and s.from <= last.to + 1 then
            if s.to > last.to then last.to = s.to end
        else
            merged[#merged + 1] = { from = s.from, to = s.to }
        end
    end
    return merged
end

--- Canonical string form of a span set; nil for an empty set (the cache field
--- is omitted rather than stored empty). Pure.
--- @param spans string|table|nil
--- @return string|nil
function WriteBack.formatSpans(spans)
    local norm = WriteBack.parseSpans(spans)
    if #norm == 0 then return nil end
    local parts = {}
    for _idx, s in ipairs(norm) do
        parts[#parts + 1] = s.from .. "-" .. s.to
    end
    return table.concat(parts, ",")
end

--- Union of two span sets (either form, either nil). Pure.
--- @return string|nil Canonical string
function WriteBack.unionSpans(a, b)
    local list = WriteBack.parseSpans(a)
    for _idx, s in ipairs(WriteBack.parseSpans(b)) do
        list[#list + 1] = s
    end
    return WriteBack.formatSpans(list)
end

--- Pointer eligibility: the end page x when the spans cover a contiguous
--- prefix [1→x], nil otherwise (a hole at the start disqualifies — section
--- points [a→b] are timeline members, never pointer candidates). Pure.
--- @param spans string|table|nil
--- @return number|nil
function WriteBack.prefixCoverage(spans)
    local norm = WriteBack.parseSpans(spans)
    local first = norm[1]
    if first and first.from <= 1 then return first.to end
    return nil
end

--- Uncovered holes in [1 → total_pages] (or → the last span end when no total
--- is given). Empty spans yield NO gaps — "unknown coverage" must not read as
--- "everything missing". Feeds the slice-3 "Fill gap (pp X–Y)" offers. Pure.
--- @param spans string|table|nil
--- @param total_pages number|nil
--- @return table Array of { from, to }
function WriteBack.spanGaps(spans, total_pages)
    local norm = WriteBack.parseSpans(spans)
    if #norm == 0 then return {} end
    local gaps = {}
    local expect = 1
    for _idx, s in ipairs(norm) do
        if s.from > expect then
            gaps[#gaps + 1] = { from = expect, to = s.from - 1 }
        end
        expect = s.to + 1
    end
    local total = tonumber(total_pages)
    if total and total > 0 and expect <= total then
        gaps[#gaps + 1] = { from = expect, to = total }
    end
    return gaps
end

--- Coverage spans for ANY cache entry, stamped or legacy (read-through).
--- Precedence: an explicit coverage_spans field wins; section entries derive
--- from their scope pages (BEFORE the full_document check — sections carry
--- full_document=true as a scope-complete marker, not a whole-book claim);
--- whole-book claims (full_document / progress 1.0) resolve only against a
--- known page total; intro entries claim nothing; everything else is the
--- legacy prefix claim [1→progress_page]. Pure.
--- @param entry table|nil A cache entry / rung / ring checkpoint
--- @param total_pages number|nil The document's page count, when known
--- @return string|nil Canonical spans string
function WriteBack.spansFromEntry(entry, total_pages)
    if type(entry) ~= "table" then return nil end
    if entry.coverage_spans then
        return WriteBack.formatSpans(entry.coverage_spans)
    end
    if entry.scope_start_page and entry.scope_end_page then
        return WriteBack.formatSpans({ { from = entry.scope_start_page, to = entry.scope_end_page } })
    end
    if entry.full_document or (tonumber(entry.progress_decimal) or 0) >= 1 then
        local total = tonumber(total_pages)
        if total and total > 0 then return "1-" .. math.floor(total) end
        return nil
    end
    if entry.intro then return nil end
    local page = tonumber(entry.progress_page)
    if page and page > 0 then return "1-" .. math.floor(page) end
    return nil
end

--- Parse (and repair) a model answer into X-Ray data, merging a delta into a
--- base when one is given. No disk access.
--- NOTE: a PARSED-TABLE base is mutated in place and aliased by the return
--- value (XrayParser.merge's own documented contract) — callers holding one
--- base across several deltas should pass the entry/JSON-string forms, which
--- re-parse per call.
--- @param answer string Raw model output
--- @param base table|string|nil Base to merge INTO: a parsed X-Ray table, a
---   cache entry ({ result = json string }), or a raw JSON string. nil =
---   complete mode (the answer stands alone).
--- @param transform function|nil transform(delta, base_parsed) called after
---   both sides parse and BEFORE the delta merge — may mutate either in place
---   (item 44: the cross-book merge applies mechanical background updates and
---   strips disobedient rewrites here). base_parsed is nil in complete mode.
--- @param never_pairs table|nil ActionCache.getNeverMergePairs output — the
---   reader's non-identical rulings, guarded in the merge's rename fold
--- @return table|nil parsed Merged/complete X-Ray data table
--- @return string|nil err Error text (model refusal or unparseable output)
--- @return string|nil cache_json Serialized JSON for cache storage (pretty
---   under dkjson in the test env; compact under KOReader's json — the cache
---   is machine-read either way)
function WriteBack.parseXrayAnswer(answer, base, transform, never_pairs)
    local XrayParser = require("koassistant_xray_parser")
    local parsed = XrayParser.parse(answer or "")
    if parsed and parsed.error then
        return nil, parsed.error, nil
    end
    if not parsed then
        return nil, "response is not a valid X-Ray JSON structure", nil
    end
    -- Carry ledger (item 49): the model NEVER authors the dormant ledger —
    -- drop any imitation before merging (the base's real ledger survives
    -- XrayParser.merge untouched: fixed key list)
    parsed[XrayParser.DORMANT_KEY] = nil
    -- Round 28 (#90): background is code-owned too — a model echo of the
    -- mechanical lines must never replace the stored ones. Runs BEFORE the
    -- transform, whose cross-book carry attaches the legitimate, code-owned
    -- background onto delta entries.
    XrayParser.dropModelBackground(parsed)
    -- 2026-08-15 (A0): drop foreign-schema/no-content entries from the fresh
    -- response before they can merge into the artifact (weak-model pollution)
    XrayParser.sanitizeEntries(parsed)
    if base ~= nil then
        local base_parsed = base
        if type(base) == "table" and base.result ~= nil then
            base_parsed = XrayParser.parse(base.result)
        elseif type(base) == "string" then
            base_parsed = XrayParser.parse(base)
        end
        if type(base_parsed) ~= "table" or base_parsed.error then
            return nil, "base artifact is not a valid X-Ray JSON structure", nil
        end
        if type(transform) == "function" then
            transform(parsed, base_parsed)
        end
        parsed = XrayParser.merge(base_parsed, parsed,
            never_pairs and { never_pairs = never_pairs } or nil)
    elseif type(transform) == "function" then
        transform(parsed, nil)
    end
    -- Wake-pass (carry layer 2): entities present after this write promote any
    -- matching dormant stubs — every write-back route passes through here, so
    -- an entity entering by ANY route (merge, incremental update, deepen)
    -- wakes its carried history
    local woken = XrayParser.wakeDormant(parsed)
    if #woken > 0 then
        logger.dbg("KOAssistant WriteBack: woke", #woken, "dormant entit(y/ies)")
    end
    local json = require("json")
    local ok, cache_json = pcall(json.encode, parsed, { pretty = true, indent = true })
    if not ok or type(cache_json) ~= "string" then
        return nil, "failed to serialize merged X-Ray", nil
    end
    return parsed, nil, cache_json
end

--- Commit an X-Ray result to disk: archive the outgoing live version (unless
--- it IS a ladder rung — the shared archive rule), then write BOTH cache keys.
--- @param document_path string
--- @param cache_json string The (already serialized) X-Ray JSON
--- @param progress_decimal number Coverage of the result, 0..1
--- @param meta table Cache metadata (reconciled — see reconcileXrayMeta)
--- @param opts table|nil { limit = ring depth, OR features = settings table to
---   resolve the user's xray_versions_kept from (pass one of them — omitting
---   both falls back to the schema default and ignores a user's 0 = "stop
---   archiving" choice); prev = the live entry when the caller JUST read it
---   (skips a full cache reload — e-ink; pass only a fresh read);
---   refresh_fn = background pre-filter resync callback }
--- @return boolean success
function WriteBack.commitXray(document_path, cache_json, progress_decimal, meta, opts)
    if not document_path or not cache_json then return false end
    opts = opts or {}
    local ActionCache = require("koassistant_action_cache")
    local limit = opts.limit
    if limit == nil then
        limit = ActionCache.checkpointLimitFromFeatures(opts.features)
    end

    local prev = opts.prev
    if prev == nil then
        prev = ActionCache.getXrayCache(document_path)
    end
    if prev and prev.result and prev.result ~= cache_json and limit ~= 0
        and not ActionCache.isXrayLadderRung(document_path, prev) then
        ActionCache.pushXrayCheckpoint(document_path, prev, limit)
    end

    local ok_doc = ActionCache.setXrayCache(document_path, cache_json, progress_decimal or 0, meta)
    local ok_action = ActionCache.set(document_path, "xray", cache_json, progress_decimal or 0, meta)
    if opts.refresh_fn then pcall(opts.refresh_fn) end
    logger.info("KOAssistant WriteBack: committed X-Ray at", tostring(progress_decimal),
        "for", document_path)
    return (ok_doc and ok_action) == true
end

--- The one-call form: parse → merge → reconcile → commit.
--- IMPORTANT: metadata reconciliation and the coverage floor need a CACHE
--- ENTRY for the base. Passing `base` as a parsed table or raw JSON string
--- supplies CONTENT only — no flag inheritance, no coverage floor — so
--- callers holding the entry must pass it (as `base` directly, or as
--- `base_entry` alongside a content-form `base`). Getting this wrong
--- DOWNGRADES permission flags on data the merged artifact still contains.
--- @param opts table:
---   document_path (required) · answer (required, raw model output) ·
---   base (cache entry / parsed table / JSON string, nil = complete mode) ·
---   base_entry (optional: the cache entry for flags/coverage when `base` is
---   a content form) · progress_decimal (coverage of the RESULT; guarded to
---   never regress below the base entry's) · meta (the new pass's metadata,
---   reconciled against the base entry) · transform (pre-merge hook — see
---   parseXrayAnswer) · limit / features (ring depth — see commitXray) ·
---   refresh_fn
--- @return boolean ok
--- @return string result_or_err cache_json on success, error text on failure
function WriteBack.applyXray(opts)
    if not (opts and opts.document_path and opts.answer) then
        return false, "missing document_path or answer"
    end
    local never_pairs
    do
        local ok_np, np = pcall(function()
            return require("koassistant_action_cache").getNeverMergePairs(opts.document_path)
        end)
        if ok_np then never_pairs = np end
    end
    local parsed, err, cache_json = WriteBack.parseXrayAnswer(opts.answer, opts.base, opts.transform, never_pairs)
    if not parsed then
        return false, err or "parse failed"
    end
    -- Round 28 (#90): reconcile mechanical background against the book's
    -- group — backfill file identities onto legacy labeled lines, drop
    -- self-lines, dedupe per source book, order by series position
    local ok_rec, rec_changed = pcall(function()
        return require("koassistant_xray_merge").reconcileBackground(parsed, opts.document_path)
    end)
    if ok_rec and rec_changed then
        local json = require("json")
        local ok_enc, re = pcall(json.encode, parsed, { pretty = true, indent = true })
        if ok_enc and type(re) == "string" then cache_json = re end
    end
    local base_entry = opts.base_entry
    if base_entry == nil and type(opts.base) == "table"
        and type(opts.base.result) == "string" then
        base_entry = opts.base
    end
    local meta = WriteBack.reconcileXrayMeta(base_entry, opts.meta)
    local progress = tonumber(opts.progress_decimal) or 0
    local base_progress = base_entry and tonumber(base_entry.progress_decimal)
    if base_progress and base_progress > progress then
        -- A quality pass or partial merge never SHRINKS coverage claims
        progress = base_progress
    end
    local ok = WriteBack.commitXray(opts.document_path, cache_json, progress, meta, {
        limit = opts.limit,
        features = opts.features,
        refresh_fn = opts.refresh_fn,
    })
    if not ok then
        return false, "cache write failed"
    end
    return true, cache_json
end

return WriteBack
