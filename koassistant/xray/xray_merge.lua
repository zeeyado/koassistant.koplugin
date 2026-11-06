--[[--
X-Ray merge engine v1 (xray_ecosystem_plan.md §6 slice 3, ref #90).

Merges section X-Rays into the main X-Ray or into a combined (coarser-span)
section artifact. AI merge is THE mechanism — independently-generated section
X-Rays describe recurring entities with section-local knowledge only, so a
programmatic name-match merge would be lossy last-writer-wins (§5 design
substance); XrayParser.merge is only safe on model-authored deltas, which is
exactly what the into-main prompt asks for.

WIRE-SAFETY INVARIANT (gate finding, 2026-07-26): artifact JSON must NEVER ride
action.prompt — the early placeholder passes strip lines ("In context…"/{context})
and substitute placeholder literals INSIDE it — and must not ride the late
{cached_result}-style channels either (the identity and cache-section passes
rescan content injected there). The payloads travel through
config.features._merge_payload → message_data → injectPayload, which splices
them over brace-free @@KOA_MERGE_*@@ sentinel tokens AFTER MessageBuilder.build
has finished (single left-to-right scan; nothing runs afterward).

Three shapes, two write paths:
- sections → EXISTING JSON main (DELTA): update-prompt shape → applyXray with
  base (delta merge, sticky flags, coverage floor, archive, both keys).
- sections → NEW/LEGACY main (REPLACE): one-shot complete merge → applyXray
  complete mode; the old main (if any) is ring-archived; metadata comes from
  the inputs alone (the old main's content is NOT in the result). Requires a
  computable coverage ratio (book open) — a replace must never write a
  guessed claim.
- sections → COMBINED SECTION ("Part I" from chapters, ≥2 inputs): one-shot →
  section entry with the union scope (sanitized key + overwrite confirm, like
  the manual section writer; sections have no ring).

Inputs are KEPT. Coverage gaps WARN, never block; material beyond the reader/
main coverage also warns. The series axis reuses this input shape later
(coverage-tagged artifact list — §5 decision 9 seams).
]]

-- Widget requires stay lazy (inside the UI functions): the pure halves of this
-- module (prompt builders, unions, scope, consent gate) are unit-tested under
-- mock_koreader, which does not stub the dialog widgets.
local UIManager = require("ui/uimanager")
local logger = require("koassistant.core.logger")
local SafeDocSettings = require("koassistant.storage.doc_settings")
local T = require("ffi/util").template
local _ = require("koassistant.core.gettext")

local XrayMerge = {}

-- Group display name (A3): "?" is the store's unnamed placeholder — every
-- user-visible group name here routes through the UI helper. Lazy require:
-- the pure halves of this module stay loadable under mock_koreader.
local function groupName(g)
    return require("koassistant.books.book_groups_ui").displayName(g)
end

-- Mirrors the xray action's sampling shape (koassistant/prompts/actions.lua): structural
-- JSON work, large possible output.
XrayMerge.API_PARAMS = { temperature = 0.5, max_tokens = 65536 }

-- English like every model-facing prompt (never translated). {title} and
-- {author_clause} are standard message_builder placeholders (small, safe).
-- The @@KOA_MERGE_*@@ SENTINELS are brace-free tokens replaced by
-- injectPayload AFTER MessageBuilder.build has finished — the artifact JSON
-- never passes through any placeholder machinery (wire-safety invariant).
-- %COUNT% / %COVERAGE% are module-filled plain text.
XrayMerge.COMPLETE_PROMPT = [[Merge these %COUNT% section X-Rays of "{title}"{author_clause} into ONE combined X-Ray.

Each section below is a complete X-Ray of one part of the book, listed in reading order. The same character, location, or concept may appear in several sections, each described with only that section's knowledge — your job is to combine those into single, unified entries.

@@KOA_MERGE_INPUTS@@

Output ONE complete merged JSON object using exactly the same JSON keys and structure as the sections. Rules:
- Every entity that appears in ANY section appears exactly ONCE in the output
- When sections describe the same entity, write ONE description that combines their knowledge in reading order; union their aliases and connections
- timeline / argument_development: concatenate entries in section order (do not deduplicate events)
- current_state / current_position: take it from the LAST section only
- Do not invent entities or events that appear in no section

@@KOA_MERGE_NEVER@@

CRITICAL: Output ONLY valid JSON — no other text. JSON keys must remain in English. Character names, location names, terms, and aliases must be in the same language and script as the source text. Aliases are other names for the same entry (a nickname, title, short form or spelling), never pronouns. All other string values must be written in {response_language}, regardless of the language of the source text.]]

XrayMerge.DELTA_PROMPT = [[Update this X-Ray for "{title}"{author_clause} by folding in the %COUNT% section X-Rays below.

Previous analysis (covers up to %COVERAGE%):
@@KOA_MERGE_MAIN@@

@@KOA_MERGE_INDEX@@

Section X-Rays to fold in (each covers one part of the book, listed in reading order; their content may OVERLAP the previous analysis — fold in only what is new or richer):

@@KOA_MERGE_INPUTS@@

Output ONLY the new or changed entries as a JSON object. Use exactly the same JSON keys and structure as the previous analysis. Your output will be programmatically merged with the existing data, so:
- OMIT categories entirely if nothing changed in them — they will be preserved as-is
- When adding a new entry to a category, include ONLY the new entries in that category's array
- When a section reveals significant new information about an existing entity, output the COMPLETE updated entry with all fields (it will replace the old version)
- A modified entry REPLACES the old one — carry over its existing details (identifying facts, relationships, earlier developments) and add the new; anything you leave out is lost
- To reference an existing entity, use the EXACT name from the entity list above
- Names listed under "dormant" are carried from related books and have NOT appeared in this book yet — they are not existing entries. If an entity you are adding or updating is the same person, place, or thing as a dormant name, include that dormant name among its aliases.
- Include "current_state" (fiction) or "current_position" (nonfiction) ONLY if the sections extend past the previous analysis's coverage — otherwise omit it
- Do not invent entities or events that appear in no section

@@KOA_MERGE_NEVER@@

CRITICAL: Output ONLY valid JSON — no other text. JSON keys must remain in English. Character names, location names, terms, and aliases must be in the same language and script as the source text. Aliases are other names for the same entry (a nickname, title, short form or spelling), never pronouns. All other string values must be written in {response_language}, regardless of the language of the source text.]]

-- Cross-book merge (items 43/44, #90): fold ANOTHER book's X-Ray into this
-- book's main as BACKGROUND. Recurring entities are NEVER rewritten by the
-- model (chained rewrites decay — the field report behind item 44): the model
-- emits background_updates pairs and crossBookTransform attaches them
-- mechanically, so the existing entry survives verbatim on every merge. Only
-- genuinely new carry-over entities arrive as full entries. This book's
-- timeline/current-state stay untouched (prompt + mechanical strip). Same
-- sentinel wire-safety as the section prompts.
XrayMerge.CROSS_BOOK_DELTA_PROMPT = [[Update this X-Ray for "{title}"{author_clause} by folding in the X-Ray of a related book below (for example an earlier book in the same series, or a companion work).

Previous analysis of "{title}" (covers up to %COVERAGE%):
@@KOA_MERGE_MAIN@@

@@KOA_MERGE_INDEX@@

X-Ray of the related book:

@@KOA_MERGE_INPUTS@@

Entity matching is the core of this task: the same person, place, or thing may appear under DIFFERENT names in the two X-Rays — a proper name in one; an epithet, role, or descriptive handle (like "the boy" or "the Keeper") in the other; spelling or translation drift. Before treating any related-book entity as new, check it against every existing entry's name, aliases, AND description. When two entries clearly describe the same person, place, or thing, treat them as the SAME entity and bridge the names through "aliases". When the evidence points that way but is not explicit, still prefer the alias bridge over creating a near-duplicate entry.

Output ONLY a JSON object in this delta format — it will be programmatically merged with the existing data:
- "background_updates": [{"name": "Exact Existing Name", "background": "One to three sentences of background from the related book.", "aliases": ["optional additional alias"]}] — one entry for each entity that appears in BOTH X-Rays (recurring characters, places, concepts, terms). Use the EXACT name from the entity list above. The existing entry is kept exactly as it is and your background text is attached alongside it, so cover only what the related book adds: who or what they were there, what they did, what carries over. This is the ONLY way to touch an existing entity — NEVER repeat an existing entity in the category arrays.
- Category arrays (same JSON keys and structure as the previous analysis): ONLY for entities from the related book that do NOT appear in the previous analysis but matter for understanding "{title}" (recurring or referenced figures, shared places, carried-over concepts). Write their descriptions as background knowledge from the related book.
- Names listed under "dormant" are carried from other related books and have NOT appeared in "{title}" yet — they are not existing entries. If an entity of the related book is the same person, place, or thing as a dormant name, treat it per the rules above (background_updates if it matches an existing entry, category arrays otherwise) and include the dormant name among its aliases.
- OMIT categories with nothing to add — they are preserved as-is
- timeline / argument_development and current_state / current_position belong to "{title}" alone — NEVER include them
- Do not invent entities that appear in neither X-Ray
- If the two books genuinely share nothing — no recurring person, place, concept or term, and nothing from the related book that helps a reader of "{title}" — return exactly {"background_updates": []} and nothing else. An empty result is a correct, expected answer for unrelated books; NEVER manufacture a connection to avoid it, and never fold in an entity merely because both books mention something similar in passing.

@@KOA_MERGE_NEVER@@

CRITICAL: Output ONLY valid JSON — no other text. JSON keys must remain in English. Character names, location names, terms, and aliases must be in the same language and script as the source text. Aliases are other names for the same entry (a nickname, title, short form or spelling), never pronouns. All other string values, including all background texts, must be written in {response_language}, regardless of the language of the source text.]]

--- Coverage-tagged inputs block (the shape the series merge reuses later:
--- swap section labels for book labels). Rides the {incremental_book_text}
--- late channel — never action.prompt. Pure.
--- @param sections table Array of { label, data = { result, scope_page_summary } }
--- @return string block
function XrayMerge.buildInputsBlock(sections)
    local parts = {}
    for i, sec in ipairs(sections) do
        local pages = sec.data and sec.data.scope_page_summary
        local coverage = pages and pages ~= "" and (" (" .. pages .. ")") or ""
        parts[#parts + 1] = string.format('Section %d — "%s"%s:\n%s',
            i, sec.label or "?", coverage, (sec.data and sec.data.result) or "")
    end
    return table.concat(parts, "\n\n")
end

--- Literal single-pass replace with advance (no Lua patterns; the search
--- position moves past each replacement so injected content is never
--- rescanned). Pure.
local function fillLiteral(text, marker, value)
    local out = text
    local from = 1
    while true do
        local s, e = out:find(marker, from, true)
        if not s then return out end
        out = out:sub(1, s - 1) .. value .. out:sub(e + 1)
        from = s + #value
    end
end

--- Whether a main X-Ray covers the whole text: the complete track, or an
--- incremental X-Ray updated to the end (B518, ruled 2026-10-20). Such a main
--- takes a delta merge with the book closed: nothing has to be placed against
--- its coverage. Pure.
function XrayMerge.coversWholeBook(main_entry)
    if type(main_entry) ~= "table" then return false end
    if main_entry.full_document then return true end
    return (tonumber(main_entry.progress_decimal) or 0) >= 1
end

--- Coverage phrase for the delta prompt's %COVERAGE% slot. Pure.
function XrayMerge.coveragePhrase(main_entry)
    if main_entry.full_document then
        return "the entire book"
    end
    local p = tonumber(main_entry.progress_decimal)
    if p then
        return math.floor(p * 100 + 0.5) .. "% of the book"
    end
    return "an earlier reading position"
end

--- Never-merge pair lines for the @@KOA_MERGE_NEVER@@ payload slot. The NAMES
--- are artifact-derived content — they ride the sentinel payload, never the
--- prompt (wire-safety invariant applies to them like any artifact text). Pure.
--- @param never_pairs table|nil ActionCache.getNeverMergePairs output
--- @return string lines ("" when none)
function XrayMerge.neverLines(never_pairs)
    if not never_pairs or #never_pairs == 0 then return "" end
    local lines = {}
    for _idx, pair in ipairs(never_pairs) do
        lines[#lines + 1] = '- "' .. pair[1] .. '" and "' .. pair[2] .. '"'
    end
    return table.concat(lines, "\n")
end

--- One-shot complete merge prompt + its sentinel payload. Pure.
--- @param never_pairs table|nil Reader-confirmed distinct pairs (§6 slice 4)
--- @return string prompt, table payload (see injectPayload)
function XrayMerge.buildCompletePrompt(sections, never_pairs)
    return fillLiteral(XrayMerge.COMPLETE_PROMPT, "%COUNT%", tostring(#sections)), {
        inputs = XrayMerge.buildInputsBlock(sections),
        never = XrayMerge.neverLines(never_pairs),
    }
end

--- Delta merge prompt + payload (fold sections into an existing JSON main).
--- @param main_entry table Live main cache entry (JSON result)
--- @param entity_index string XrayParser.buildEntityIndex output (may be "")
--- @param never_pairs table|nil Reader-confirmed distinct pairs (§6 slice 4)
--- @return string prompt, table payload
function XrayMerge.buildDeltaPrompt(sections, main_entry, entity_index, never_pairs)
    local prompt = fillLiteral(XrayMerge.DELTA_PROMPT, "%COUNT%", tostring(#sections))
    prompt = fillLiteral(prompt, "%COVERAGE%", XrayMerge.coveragePhrase(main_entry))
    return prompt, {
        inputs = XrayMerge.buildInputsBlock(sections),
        -- Neither the dormant ledger (item 49) nor the mechanical background
        -- lines (round 28) ride a prompt — both are code-owned
        main = require("koassistant.xray.xray_parser").stripForPromptJSON(main_entry.result or ""),
        index = entity_index or "",
        never = XrayMerge.neverLines(never_pairs),
    }
end

--- Cross-book inputs block: ONE related book's X-Ray, labeled by book (the
--- label swap buildInputsBlock's doc anticipated). Rides the sentinel payload,
--- never action.prompt. Pure.
--- @param source table { title, author, entry = cache entry }
--- @return string block
function XrayMerge.buildCrossBookInputsBlock(source)
    local head = string.format('Related book — "%s"%s:', source.title or "?",
        (source.author and source.author ~= "" and (" by " .. source.author)) or "")
    -- Ledger stripped: the model matches/composes/selects on ACTIVE entities
    -- only — dormant carry is code's job (item 49). Background stripped too
    -- (round 28): the transitive carry is mechanical, and a folded series
    -- otherwise compounds every ancestor's paragraphs into each hop's prompt
    return head .. "\n" .. require("koassistant.xray.xray_parser").stripForPromptJSON(
        (source.entry and source.entry.result) or "")
end

-- =============================================================================
-- Cross-book fold ledger (groups round item (D), 2026-08-09)
-- =============================================================================
-- Provenance was a "; "-joined TITLE STRING, so "folded" could not be told from
-- "folded, but that book's X-Ray has been rebuilt since" — which is exactly the
-- staleness caveat the round-28 confirm had to disclose. The ledger is the
-- file-keyed, dated form:
--     merged_from = { { file = , title = , at = , source_ts = }, ... }
-- `file` and `source_ts` are ABSENT for transitively carried labels (a
-- background line names an ancestor book we never opened) and for everything
-- written before this existed. Those read as status "unknown", NEVER "stale":
-- a reader must not be nudged into paying for re-folds of work already done,
-- and the version they carry is genuinely unknowable after the fact.
-- `merged_from_books` survives as a DERIVED display string, so every existing
-- reader (browser Info, checkpoint copy, write-back continuity) is untouched.

local function trimLabel(s)
    if type(s) ~= "string" then return nil end
    local t = s:match("^%s*(.-)%s*$")
    return t ~= "" and t or nil
end

--- Same-source identity: the file when BOTH sides know one, else the
--- trimmed-exact title match the string form always used (so a legacy
--- title-only record still matches a modern file-keyed fold of the same book).
local function sameSource(rec, desc)
    if rec.file and desc.file then return rec.file == desc.file end
    return rec.title ~= nil and rec.title == trimLabel(desc.title)
end

--- A cache entry's fold ledger, structured. Reads the modern `merged_from`
--- array; falls back to parsing the legacy `merged_from_books` string into
--- title-only records. Always returns a NEW table. Pure.
--- @param entry table|nil Cache entry
--- @return table ledger
function XrayMerge.ledgerOf(entry)
    local out = {}
    local led = entry and entry.merged_from
    if type(led) == "table" then
        for _idx, rec in ipairs(led) do
            local title = type(rec) == "table" and trimLabel(rec.title)
            if title then
                out[#out + 1] = { file = rec.file, title = title,
                    at = tonumber(rec.at), source_ts = tonumber(rec.source_ts) }
            end
        end
        return out
    end
    for part in tostring((entry and entry.merged_from_books) or ""):gmatch("([^;]+)") do
        local title = trimLabel(part)
        if title then out[#out + 1] = { title = title } end
    end
    return out
end

--- The ledger's display form — the legacy `merged_from_books` string, which
--- stays the field every reader outside this module consumes. Pure.
--- @param ledger table|nil
--- @return string
function XrayMerge.provenanceString(ledger)
    local titles = {}
    for _idx, rec in ipairs(ledger or {}) do titles[#titles + 1] = rec.title end
    return table.concat(titles, "; ")
end

--- Record one fold in a ledger, in place. An already-listed source is updated
--- rather than duplicated: it keeps its file if we now know one, and when a
--- NEWER source version is folded, both `source_ts` (which version we carry)
--- and `at` (when we took it) move to the new fold. Pure apart from the
--- os.time() default, which callers may pass in as `desc.at`.
--- @param ledger table|nil
--- @param desc table { file =, title =, source_ts =, at = }
--- @return table ledger
function XrayMerge.appendMergedFrom(ledger, desc)
    ledger = ledger or {}
    local incoming = {
        file = desc and desc.file,
        title = trimLabel(desc and desc.title) or "?",
        at = tonumber(desc and desc.at) or os.time(),
        source_ts = tonumber(desc and desc.source_ts),
    }
    for _idx, rec in ipairs(ledger) do
        if sameSource(rec, incoming) then
            rec.file = rec.file or incoming.file
            if incoming.source_ts and incoming.source_ts ~= rec.source_ts then
                rec.source_ts = incoming.source_ts
                rec.at = incoming.at
            end
            return ledger
        end
    end
    ledger[#ledger + 1] = incoming
    return ledger
end

--- Fold status of one source against a target entry's ledger:
---   "none"    — never folded
---   "current" — folded, and that X-Ray has not changed since
---   "stale"   — folded, but the source's X-Ray is newer than what we carry
---   "unknown" — folded, but no version was recorded (legacy or transitively
---               carried) — counts as done everywhere, never as a reason to
---               spend a request re-running it
--- @param entry table|nil Target cache entry
--- @param source table|nil { title =, file =, timestamp = } (the SOURCE entry's timestamp)
--- @return string status
function XrayMerge.foldStatus(entry, source)
    if type(source) ~= "table" then return "none" end
    for _idx, rec in ipairs(XrayMerge.ledgerOf(entry)) do
        if sameSource(rec, source) then
            local src_ts = tonumber(source.timestamp)
            if not src_ts or not rec.source_ts then return "unknown" end
            return src_ts > rec.source_ts and "stale" or "current"
        end
    end
    return "none"
end

--- True when a fold is already recorded, whatever its version status. Round 28:
--- lets the series chain skip hops that already ran — n-1 re-merges shrink to
--- just the new volumes.
--- @param entry table|nil Cache entry
--- @param source_title string|nil
--- @param source_file string|nil Preferred identity when known
--- @return boolean
function XrayMerge.hasFolded(entry, source_title, source_file)
    return XrayMerge.foldStatus(entry,
        { title = source_title, file = source_file }) ~= "none"
end

--- Cross-book delta prompt + payload (fold one book's X-Ray into this book's
--- JSON main). Pure.
--- @param main_entry table Target live main cache entry (JSON result)
--- @param entity_index string XrayParser.buildEntityIndex output (may be "")
--- @param never_pairs table|nil Target book's reader-confirmed distinct pairs
--- @param source table { title, author, entry }
--- @return string prompt, table payload
function XrayMerge.buildCrossBookPrompt(main_entry, entity_index, never_pairs, source)
    local prompt = fillLiteral(XrayMerge.CROSS_BOOK_DELTA_PROMPT, "%COVERAGE%",
        XrayMerge.coveragePhrase(main_entry))
    return prompt, {
        inputs = XrayMerge.buildCrossBookInputsBlock(source),
        main = require("koassistant.xray.xray_parser").stripForPromptJSON(main_entry.result or ""),
        index = entity_index or "",
        never = XrayMerge.neverLines(never_pairs),
    }
end

-- Categories cross-book merges must never touch: append categories (the
-- target's own narrative) and singletons (its reading state). Mirrors the
-- parser's APPEND/SINGLETON sets; everything else is name-matched entities.
local PROTECTED_CATEGORIES = {
    timeline = true,
    argument_development = true,
    current_state = true,
    current_position = true,
    conclusion = true,
    reader_engagement = true,
    -- The dormant carry ledger (item 49) is code-owned — a model-emitted
    -- imitation is stripped from every delta (write-back drops it too)
    __dormant = true,
}

-- NAMED-ENTITY categories: things with an IDENTITY that can recur in another
-- book. This governs the NAMING CANON only — the block that tells a fresh
-- X-Ray "call these people/places/terms what the previous book called them".
-- Steering names is right for identities and WRONG for analysis: telling the
-- model to reuse the previous book's theme wording would bias this book's own
-- reading of its own text, which is the one thing a fresh extraction must own.
-- Round 27 (maintainer): the CARRY LEDGER deliberately does NOT use this set —
-- it carries everything that is not append/singleton (see populateDormant).
-- Carrying is not steering: a carried theme is reading material for the reader
-- and, at most, wakes onto a same-category entry.
local ENTITY_CATEGORIES = {
    characters = true, key_figures = true, locations = true,
    lexicon = true, terminology = true, technical_terms = true,
    core_concepts = true, key_concepts = true,
}

--- name/alias (lowercased) → item, over every entity category. First bind
--- wins (duplicate names are the dedup engine's problem, not ours). Pure.
local function buildEntityLookup(base_data)
    local XrayParser = require("koassistant.xray.xray_parser")
    local lookup = {}
    local function learn(key, item)
        if type(key) == "string" and key ~= "" then
            local norm = key:lower()
            if lookup[norm] == nil then lookup[norm] = item end
        end
    end
    for _idx, cat in ipairs(XrayParser.getCategories(base_data or {})) do
        if not PROTECTED_CATEGORIES[cat.key] and type(cat.items) == "table" then
            for _idx2, item in ipairs(cat.items) do
                learn(XrayParser.getItemName(item, cat.key), item)
                if type(item.aliases) == "table" then
                    for _idx3, alias in ipairs(item.aliases) do learn(alias, item) end
                end
            end
        end
    end
    return lookup
end

--- Union new aliases into an item, case-insensitive, never duplicating the
--- item's own name. Mutates the item.
local function mergeAliasesInto(item, additions)
    if type(additions) ~= "table" then return end
    local aliases = type(item.aliases) == "table" and item.aliases or {}
    local seen = {}
    if type(item.name) == "string" then seen[item.name:lower()] = true end
    if type(item.term) == "string" then seen[item.term:lower()] = true end
    for _idx, a in ipairs(aliases) do
        if type(a) == "string" then seen[a:lower()] = true end
    end
    local added = false
    for _idx, a in ipairs(additions) do
        if type(a) == "string" and a ~= "" and not seen[a:lower()] then
            aliases[#aliases + 1] = a
            seen[a:lower()] = true
            added = true
        end
    end
    if added then item.aliases = aliases end
end

-- Normalized title compare (trimmed, case-folded): labels in background lines
-- came from title strings captured at different times through different
-- resolution paths — casing/whitespace drift must not defeat a self-check.
local function normTitle(s)
    if type(s) ~= "string" then return nil end
    local r = s:lower():gsub("^%s+", ""):gsub("%s+$", "")
    return r
end

--- Attach cross-book background to existing entities MECHANICALLY (item 44):
--- the matched entry keeps its description verbatim; the background rides the
--- item's `background` array ({ source, text [, file] } — file-keyed identity
--- since round 28, per-source replace — see XrayParser.mergeBackground) and
--- optional new aliases are unioned in. Matching is by name OR alias,
--- case-insensitive. Mutates base_data. Pure otherwise.
--- @param base_data table Parsed target X-Ray
--- @param updates table Array of { name, background, aliases? }
--- @param source_title string The related book's title (display label)
--- @param source_file string|nil The related book's file path (identity key)
--- @return number applied, number unmatched
function XrayMerge.applyBackgroundUpdates(base_data, updates, source_title, source_file)
    local XrayParser = require("koassistant.xray.xray_parser")
    local applied, unmatched = 0, 0
    if type(base_data) ~= "table" or type(updates) ~= "table" then
        return applied, unmatched
    end
    local lookup = buildEntityLookup(base_data)
    for _idx, upd in ipairs(updates) do
        local name = type(upd) == "table" and type(upd.name) == "string" and upd.name
        local item = name and lookup[name:lower()]
        if item and type(upd.background) == "string" and upd.background ~= "" then
            item.background = XrayParser.mergeBackground(item.background,
                { { source = source_title, text = upd.background, file = source_file } })
            mergeAliasesInto(item, upd.aliases)
            applied = applied + 1
        else
            unmatched = unmatched + 1
        end
    end
    return applied, unmatched
end

--- Transitive background carry (item 49, #90 chained-merge field report): a
--- chained series merge must not lose earlier ancestors — the source's own
--- labeled background lines (e.g. Vol 1's inside Vol 2's X-Ray) are copied
--- MECHANICALLY onto the matching target entity (or onto the delta's kept
--- carry-over entry) with their ORIGINAL source labels intact. Fill-gaps
--- only: a label already present on the receiving item wins, so a fresher
--- direct merge of that ancestor is never overwritten by a stale copy riding
--- in through a chain. Lines labeled with the target book itself are skipped
--- (self-background via out-of-order merges), as are unattributable "?"
--- labels. Mutates base_parsed/delta items; pure otherwise.
--- @param base_parsed table|nil Parsed target X-Ray
--- @param delta table|nil Model delta AFTER the rewrite-drop pass (kept entries only)
--- @param source_parsed table Parsed source X-Ray
--- @param target_title string|nil The target book's title (self-label filter)
--- @param target_file string|nil The target book's file path (round 28: the
---   robust self-filter — title strings drift, paths don't)
--- @return table Distinct labels actually carried (array of strings)
function XrayMerge.carrySourceBackground(base_parsed, delta, source_parsed, target_title, target_file)
    local XrayParser = require("koassistant.xray.xray_parser")
    local carried, carried_set = {}, {}
    if type(source_parsed) ~= "table" then return carried end
    local target_norm = normTitle(target_title)
    local base_lookup = buildEntityLookup(base_parsed or {})
    -- The delta's kept carry-over entries, keyed like buildEntityLookup
    local delta_lookup = {}
    if type(delta) == "table" then
        for key, arr in pairs(delta) do
            if not PROTECTED_CATEGORIES[key] and type(arr) == "table" then
                for _idx, entry in ipairs(arr) do
                    if type(entry) == "table" then
                        local name = entry.name or entry.term
                        if type(name) == "string" and name ~= ""
                            and delta_lookup[name:lower()] == nil then
                            delta_lookup[name:lower()] = entry
                        end
                        if type(entry.aliases) == "table" then
                            for _idx2, alias in ipairs(entry.aliases) do
                                if type(alias) == "string" and alias ~= ""
                                    and delta_lookup[alias:lower()] == nil then
                                    delta_lookup[alias:lower()] = entry
                                end
                            end
                        end
                    end
                end
            end
        end
    end
    local function findIn(lookup, name, item)
        local hit = type(name) == "string" and name ~= "" and lookup[name:lower()]
        if hit then return hit end
        if type(item.aliases) == "table" then
            for _idx, alias in ipairs(item.aliases) do
                if type(alias) == "string" and alias ~= "" and lookup[alias:lower()] then
                    return lookup[alias:lower()]
                end
            end
        end
    end
    for _idx, cat in ipairs(XrayParser.getCategories(source_parsed)) do
        if not PROTECTED_CATEGORIES[cat.key] and type(cat.items) == "table" then
            for _idx2, item in ipairs(cat.items) do
                if type(item) == "table" and type(item.background) == "table" then
                    local name = XrayParser.getItemName(item, cat.key)
                    local target_item = findIn(base_lookup, name, item)
                        or findIn(delta_lookup, name, item)
                    if target_item then
                        -- Fill-gaps keys: file when known, source label always
                        local existing_sources = {}
                        if type(target_item.background) == "table" then
                            for _idx3, b in ipairs(target_item.background) do
                                if type(b) == "table" then
                                    if type(b.source) == "string" then
                                        existing_sources[b.source] = true
                                    end
                                    if type(b.file) == "string" then
                                        existing_sources[b.file] = true
                                    end
                                end
                            end
                        end
                        local additions = {}
                        for _idx3, b in ipairs(item.background) do
                            if type(b) == "table" and type(b.text) == "string" and b.text ~= ""
                                and type(b.source) == "string" and b.source ~= ""
                                and b.source ~= "?"
                                and normTitle(b.source) ~= target_norm
                                and not (target_file and b.file == target_file)
                                and not existing_sources[b.source]
                                and not (b.file and existing_sources[b.file]) then
                                additions[#additions + 1] = { source = b.source, text = b.text,
                                    file = type(b.file) == "string" and b.file or nil }
                            end
                        end
                        if #additions > 0 then
                            target_item.background = XrayParser.mergeBackground(
                                target_item.background, additions)
                            for _idx3, b in ipairs(additions) do
                                if not carried_set[b.source] then
                                    carried_set[b.source] = true
                                    carried[#carried + 1] = b.source
                                end
                            end
                        end
                    end
                end
            end
        end
    end
    return carried
end

--- Carry layer 1 (item 49): source entities that did NOT arrive in this merge
--- become dormant ledger stubs on the target — invisible, token-free carriers
--- that the wake-pass (XrayParser.wakeDormant, run by every write-back)
--- promotes the moment a matching entity appears by any route. The source's
--- own ledger rides along too (transitive skip-volume carry: vol N's artifact
--- + ledger covers 1..N — the "vol 7 needs vol 6's artifact only" invariant).
--- A stub already in the ledger is refreshed by the newer source, its carried
--- background lines unioned. Mutates base_parsed; pure otherwise.
--- @param base_parsed table Parsed target X-Ray (mutated)
--- @param delta table|nil Model delta AFTER the rewrite-drop pass (kept = arriving entities)
--- @param source_parsed table Parsed source X-Ray
--- @param source_title string The source book's title (stub provenance label)
--- @param source_file string|nil The source book's file path (round 28 identity key)
--- @param target_title string|nil The TARGET book's title — self-filter (round
---   28: this path had none, so a self-labeled line reaching a ledger came
---   back via the wake-pass)
--- @param target_file string|nil The target book's file path (robust self-filter)
--- @return number stubs newly added
--- Case-insensitive alias union, first list's order first; nil when empty.
local function unionAliases(a, b)
    local out, seen = {}, {}
    -- two explicit passes: ipairs over { a, b } stopped at a nil a, so a
    -- stub seeded without aliases never gained the source's later ones
    -- (the sweep of 2026-11-06)
    local function addAll(list)
        for _i, alias in ipairs(type(list) == "table" and list or {}) do
            if type(alias) == "string" and alias ~= "" and not seen[alias:lower()] then
                seen[alias:lower()] = true
                out[#out + 1] = alias
            end
        end
    end
    addAll(a)
    addAll(b)
    return #out > 0 and out or nil
end

--- @param skip table|nil Lowercased-name set of carried entries the reader
---   removed (S4 tombstones): never stashed
--- @param enrich boolean|nil The free seeds pass true (B394 slice 3): a source
---   entry that is ALREADY in the target gives it its description as a
---   labeled background line, as the wake-pass does for one that arrives
---   later. The AI merge leaves it off: there the model writes that line.
--- @return number added, number refreshed (existing stubs whose copy changed,
---   plus the target entries the enrichment changed)
function XrayMerge.populateDormant(base_parsed, delta, source_parsed, source_title,
        source_file, target_title, target_file, skip, enrich)
    local XrayParser = require("koassistant.xray.xray_parser")
    if type(base_parsed) ~= "table" or type(source_parsed) ~= "table" then return 0, 0 end
    local DK = XrayParser.DORMANT_KEY
    local target_norm = normTitle(target_title)
    -- Carried lines a stub may bring along: cleanly attributable, never the
    -- target book's own label/path riding back in
    local function stubLines(background)
        if type(background) ~= "table" then return nil end
        local bg
        for _idx, b in ipairs(background) do
            if type(b) == "table" and type(b.text) == "string" and b.text ~= ""
                and type(b.source) == "string" and b.source ~= ""
                and b.source ~= "?"
                and normTitle(b.source) ~= target_norm
                and not (target_file and b.file == target_file) then
                bg = bg or {}
                bg[#bg + 1] = { source = b.source, text = b.text,
                    file = type(b.file) == "string" and b.file or nil }
            end
        end
        return bg
    end
    -- Everything the target can already match: its actives + the delta's
    -- arriving entities (they become actives in the merge right after this),
    -- by family, the wake-pass's rule (round 26): a source entry is already
    -- here only as an entry of its family, so the character "the Warden"
    -- (alias "Warden") is carried beside the term "Warden"
    local present = {}
    local function learn(key, name, entry)
        if type(name) ~= "string" or name == "" then return end
        local family = XrayParser.CATEGORY_FAMILY[key] or key
        present[family] = present[family] or {}
        if present[family][name:lower()] == nil then present[family][name:lower()] = entry end
    end
    for _idx, cat in ipairs(XrayParser.getCategories(base_parsed)) do
        if not PROTECTED_CATEGORIES[cat.key] and type(cat.items) == "table" then
            for _idx2, item in ipairs(cat.items) do
                if type(item) == "table" then
                    learn(cat.key, XrayParser.getItemName(item, cat.key), item)
                    for _idx3, alias in ipairs(type(item.aliases) == "table" and item.aliases or {}) do
                        learn(cat.key, alias, item)
                    end
                end
            end
        end
    end
    if type(delta) == "table" then
        for key, arr in pairs(delta) do
            if not PROTECTED_CATEGORIES[key] and type(arr) == "table" then
                for _idx, entry in ipairs(arr) do
                    if type(entry) == "table" then
                        learn(key, entry.name or entry.term, entry)
                        for _idx2, alias in ipairs(type(entry.aliases) == "table" and entry.aliases or {}) do
                            learn(key, alias, entry)
                        end
                    end
                end
            end
        end
    end
    local ledger = base_parsed[DK]
    if type(ledger) ~= "table" then ledger = {} end
    -- Deterministic content fingerprint: the reseed dry-run writes only on a
    -- real change, and a re-seed of a source whose full-name stub has since
    -- folded under the short name appends-then-folds to identical content
    -- (counters alone would report a change every run)
    local function ledgerFingerprint(list)
        local parts = {}
        for _idx, stub in ipairs(list) do
            if type(stub) == "table" then
                local aliases = {}
                for _a, a in ipairs(type(stub.aliases) == "table" and stub.aliases or {}) do
                    aliases[#aliases + 1] = tostring(a)
                end
                local bg = {}
                for _b, b in ipairs(type(stub.background) == "table" and stub.background or {}) do
                    if type(b) == "table" then
                        bg[#bg + 1] = tostring(b.source) .. "\3" .. tostring(b.text) .. "\3" .. tostring(b.file)
                    end
                end
                parts[#parts + 1] = table.concat({ tostring(stub.name), tostring(stub.category),
                    tostring(stub.source), tostring(stub.file), tostring(stub.role),
                    tostring(stub.description), table.concat(aliases, "\2"),
                    table.concat(bg, "\2") }, "\1")
            end
        end
        return table.concat(parts, "\n")
    end
    local before = ledgerFingerprint(ledger)
    local by_name = {}
    for i, stub in ipairs(ledger) do
        if type(stub) == "table" and type(stub.name) == "string" then
            by_name[stub.name:lower()] = i
        end
    end
    local added, refreshed = 0, 0
    local function stash(stub)
        local key = type(stub.name) == "string" and stub.name ~= ""
            and stub.name:lower() or nil
        if not key then return end
        -- S4 tombstones: an entry the reader removed never comes back
        if skip and skip[key] then return end
        local at = by_name[key]
        if at then
            -- Newer source refreshes the stub; carried lines AND aliases are
            -- unioned (S4: an alias the reader added onto the stub survives
            -- an automatic re-seed) and the role fills in from the old copy
            local old = ledger[at]
            stub.background = XrayParser.mergeBackground(old.background, stub.background)
            -- B394 slice 3: the row being replaced came from ANOTHER book (a
            -- project seeds from every member; a series' nearest book
            -- changes): its description stays, as that book's line, unless
            -- the new row already carries one from it. The ledger fold's own
            -- rule. A row never keeps a line from its own source, so two
            -- books taking turns settle on the same content every run.
            local function sameBook(src, file)
                return (file ~= nil and file == stub.file) or (src ~= nil and src == stub.source)
            end
            if type(old.description) == "string" and old.description ~= ""
                    and type(old.source) == "string" and old.source ~= "" and old.source ~= "?"
                    and not sameBook(old.source, old.file) then
                local have = false
                for _idx, b in ipairs(stub.background or {}) do
                    if type(b) == "table" and ((old.file ~= nil and b.file == old.file)
                            or b.source == old.source) then
                        have = true
                        break
                    end
                end
                if not have then
                    stub.background = stub.background or {}
                    stub.background[#stub.background + 1] = { source = old.source,
                        text = old.description, file = old.file }
                end
            end
            if type(stub.background) == "table" then
                local kept = {}
                for _idx, b in ipairs(stub.background) do
                    if not (type(b) == "table" and sameBook(b.source, b.file)) then
                        kept[#kept + 1] = b
                    end
                end
                stub.background = #kept > 0 and kept or nil
            end
            stub.aliases = unionAliases(old.aliases, stub.aliases)
            stub.role = stub.role or old.role
            -- B536: a row the reader carried by hand stays theirs
            stub.by_hand = stub.by_hand or old.by_hand
            if stub.description ~= old.description or stub.role ~= old.role
                or #(stub.aliases or {}) ~= #(old.aliases or {})
                or #(stub.background or {}) ~= #(old.background or {}) then
                refreshed = refreshed + 1
            end
            ledger[at] = stub
        else
            ledger[#ledger + 1] = stub
            by_name[key] = #ledger
            added = added + 1
        end
    end
    local function isPresent(name, aliases, key)
        local here = present[XrayParser.CATEGORY_FAMILY[key] or key]
        if not here then return false end
        if type(name) == "string" and name ~= "" and here[name:lower()] then return true end
        if type(aliases) == "table" then
            for _idx, a in ipairs(aliases) do
                if type(a) == "string" and a ~= "" and here[a:lower()] then return true end
            end
        end
        return false
    end
    -- (a) source ACTIVES that did not arrive → stubs. Round 27 (maintainer:
    -- "leaning hard towards full inclusion"): EVERY category the merge engine
    -- is allowed to touch carries, not just named entities — themes, findings
    -- and arguments are exactly what a non-series project group wants to see
    -- from its other books, and even in a series "what the last book was
    -- about" is worth a row. Only PROTECTED_CATEGORIES stay out, and they are
    -- structurally unable to carry: timeline/argument_development are APPEND
    -- lists of events (every book's events would pile up forever) and the
    -- singletons (current_state, reader_engagement, conclusion) are this
    -- book's own reading state, not an entry with a name.
    -- Source entries the target already holds (B394 slice 3): with `enrich`
    -- they give the target's own entry a labeled line instead of nothing
    local present_stubs = {}
    for _idx, cat in ipairs(XrayParser.getCategories(source_parsed)) do
        if not PROTECTED_CATEGORIES[cat.key] and type(cat.items) == "table" then
            for _idx2, item in ipairs(cat.items) do
                if type(item) == "table" then
                    local name = XrayParser.getItemName(item, cat.key)
                    if type(name) == "string" and name ~= "" then
                        local aliases
                        if type(item.aliases) == "table" and #item.aliases > 0 then
                            aliases = {}
                            for _idx3, a in ipairs(item.aliases) do aliases[#aliases + 1] = a end
                        end
                        local stub = {
                            name = name,
                            aliases = aliases,
                            category = cat.key,
                            -- S3 parity: the role rides so a carried card reads
                            -- like a live one ("Cast (Innkeeper)")
                            role = type(item.role) == "string" and item.role ~= ""
                                and item.role or nil,
                            description = type(item.description) == "string"
                                and item.description ~= "" and item.description or nil,
                            source = source_title,
                            file = source_file,
                            -- Only cleanly attributable carried lines ride along
                            background = stubLines(item.background),
                        }
                        if not isPresent(name, item.aliases, cat.key) then
                            stash(stub)
                        elseif enrich then
                            present_stubs[#present_stubs + 1] = stub
                        end
                    end
                end
            end
        end
    end
    -- (b) the source's OWN dormant stubs (transitive skip-volume carry).
    -- Deliberately stashed even when they match a target active: an active
    -- source entity delivered its knowledge via the carry above, but a source
    -- DORMANT hasn't — the wake-pass right after the merge promotes it in the
    -- same write.
    if type(source_parsed[DK]) == "table" then
        for _idx, stub in ipairs(source_parsed[DK]) do
            -- Everything the source carries rides on (round 27 full inclusion).
            -- Round 28: a transitive stub that IS this target (by path or
            -- label) stays out — it would wake into the book it came from
            if type(stub) == "table" and type(stub.name) == "string" and stub.name ~= ""
                and not PROTECTED_CATEGORIES[stub.category or ""]
                and not (target_file and stub.file == target_file)
                and not (target_norm and normTitle(stub.source) == target_norm) then
                stash({
                    name = stub.name,
                    aliases = stub.aliases,
                    category = stub.category,
                    role = stub.role,
                    description = stub.description,
                    source = stub.source or source_title,
                    file = stub.file,
                    background = stubLines(stub.background),
                })
            end
        end
    end
    if #ledger > 0 then base_parsed[DK] = ledger end
    -- #90 (2026-09-09): two sources naming one entity differently (the short
    -- name in one volume, the dotted full name in the next, each the other's
    -- alias) landed as two stubs because the ledger was keyed by exact name. Fold by name identity
    -- here as well as in the wake-pass: the reseed dry-run only writes when
    -- this function reports a change, and editLiveXray runs no wake-pass
    refreshed = refreshed + XrayParser.foldLedger(base_parsed)
    -- B394 slice 3: the free path for entries already here. Family-scoped
    -- and fill-gaps-only like the wake-pass it shares its code with, so a
    -- second run changes nothing and reports nothing.
    local enriched = #present_stubs > 0
        and XrayParser.enrichFromStubs(base_parsed, present_stubs) or 0
    if ledgerFingerprint(ledger) == before then return 0, enriched end
    return added, refreshed + enriched
end

--- Round 26 (device audit — the round-25 rebuild carry was half a fix): a
--- rebuild replaces the artifact wholesale, so cross-book background already
--- folded onto ACTIVE entities died with it, even though the intent was "a
--- rebuild must never cost knowledge the book already held". Re-stub every
--- outgoing entity that carries background into the ledger (identity + the
--- background verbatim, never the old description — the new read owns that);
--- the wake-pass right after promotes them back onto whatever the fresh X-Ray
--- named, and anything the new read dropped stays honestly carried.
--- @param prev_parsed table The outgoing X-Ray
--- @param parsed table The fresh X-Ray (mutated: ledger populated)
--- @return number added
function XrayMerge.carryActiveBackground(prev_parsed, parsed)
    local XrayParser = require("koassistant.xray.xray_parser")
    if type(prev_parsed) ~= "table" or type(parsed) ~= "table" then return 0 end
    local DK = XrayParser.DORMANT_KEY
    local ledger = type(parsed[DK]) == "table" and parsed[DK] or {}
    local by_name = {}
    for i, stub in ipairs(ledger) do
        if type(stub) == "table" and type(stub.name) == "string" then
            by_name[stub.name:lower()] = i
        end
    end
    local added = 0
    for _idx, cat in ipairs(XrayParser.getCategories(prev_parsed)) do
        if not PROTECTED_CATEGORIES[cat.key] and type(cat.items) == "table" then
            for _idx2, item in ipairs(cat.items) do
                if type(item) == "table" and type(item.background) == "table"
                    and #item.background > 0 then
                    local name = XrayParser.getItemName(item, cat.key)
                    if type(name) == "string" and name ~= "" then
                        local aliases
                        if type(item.aliases) == "table" and #item.aliases > 0 then
                            aliases = {}
                            for _idx3, a in ipairs(item.aliases) do aliases[#aliases + 1] = a end
                        end
                        local stub = {
                            name = name,
                            aliases = aliases,
                            category = cat.key,
                            -- The role is this book's own reading of who the
                            -- entry is: enough to recognize the row by
                            role = type(item.role) == "string" and item.role ~= ""
                                and item.role or nil,
                            background = item.background,
                        }
                        local at = by_name[name:lower()]
                        if at then
                            stub.background = XrayParser.mergeBackground(
                                ledger[at].background, item.background)
                            stub.source = ledger[at].source
                            stub.file = ledger[at].file
                            stub.description = ledger[at].description
                            stub.role = stub.role or ledger[at].role
                            ledger[at] = stub
                        else
                            -- No older carried row lends its source (B394 slice
                            -- 3): name the book of the last line (the nearest
                            -- one once the lines are in series order), so the
                            -- row is never listed without where it came from.
                            -- No description: the lines hold the knowledge and
                            -- come back whole when the entry wakes.
                            local last = item.background[#item.background]
                            if type(last) == "table" and type(last.source) == "string"
                                    and last.source ~= "" and last.source ~= "?" then
                                stub.source = last.source
                                stub.file = type(last.file) == "string" and last.file or nil
                            end
                            ledger[#ledger + 1] = stub
                            by_name[name:lower()] = #ledger
                            added = added + 1
                        end
                    end
                end
            end
        end
    end
    if #ledger > 0 then parsed[DK] = ledger end
    return added
end

--- F1 (B278, 2026-08-30, docs/xray_cross_book_lookup_plan.md §2.4): the
--- promotion doorway carried only ACTIVE background carriers (above), so a
--- stub that lived ONLY in the outgoing artifact's ledger — a fold made after
--- the rung was built, a late seed, an alias the reader edited onto a stub —
--- died with the swap, while the rebuild path has copied the outgoing ledger
--- across first since round 25. Union the outgoing ledger into the incoming
--- one BY NAME: a stub present in both takes the outgoing (newer) version —
--- category/source/file/description where set, the rung's as fallback — with
--- aliases and background lines unioned; a stub the incoming lacks is
--- appended. Runs BEFORE carryActiveBackground and the wake-pass, which
--- re-wakes anything the rung already named (fill-gaps-only background, so
--- nothing duplicates): idempotent. A stub the reader REMOVED from the
--- outgoing ledger is absent here and cannot return through this union; the
--- rung's own copy still brings it back (tombstones out of scope, documented).
--- @param prev_parsed table The outgoing X-Ray
--- @param parsed table The incoming rung (mutated: ledger unioned)
--- @return number added, number refreshed
--- @param skip table|nil S4 tombstones (lowercased-name set): never unioned
function XrayMerge.unionLedger(prev_parsed, parsed, skip)
    local XrayParser = require("koassistant.xray.xray_parser")
    if type(prev_parsed) ~= "table" or type(parsed) ~= "table" then return 0, 0 end
    local DK = XrayParser.DORMANT_KEY
    local prev_ledger = prev_parsed[DK]
    if type(prev_ledger) ~= "table" or #prev_ledger == 0 then return 0, 0 end
    local ledger = type(parsed[DK]) == "table" and parsed[DK] or {}
    local by_name = {}
    for i, stub in ipairs(ledger) do
        if type(stub) == "table" and type(stub.name) == "string" then
            by_name[stub.name:lower()] = i
        end
    end
    local added, refreshed = 0, 0
    for _idx, stub in ipairs(prev_ledger) do
        if type(stub) == "table" and type(stub.name) == "string" and stub.name ~= ""
                and not (skip and skip[stub.name:lower()]) then
            local key = stub.name:lower()
            local at = by_name[key]
            if at then
                local old = ledger[at]
                local merged = {
                    name = stub.name,
                    category = stub.category or old.category,
                    source = stub.source or old.source,
                    file = stub.file or old.file,
                    description = stub.description or old.description,
                    role = stub.role or old.role,
                    background = XrayParser.mergeBackground(old.background, stub.background),
                    by_hand = stub.by_hand or old.by_hand,
                }
                -- Aliases: the outgoing list first (the reader's edits live
                -- there), then whatever the rung's copy had that it lacks
                local aliases, seen = {}, {}
                local function fold(list)
                    for _idx2, a in ipairs(type(list) == "table" and list or {}) do
                        if type(a) == "string" and a ~= "" and not seen[a:lower()] then
                            seen[a:lower()] = true
                            aliases[#aliases + 1] = a
                        end
                    end
                end
                fold(stub.aliases)
                fold(old.aliases)
                if #aliases > 0 then merged.aliases = aliases end
                ledger[at] = merged
                refreshed = refreshed + 1
            else
                ledger[#ledger + 1] = stub
                by_name[key] = #ledger
                added = added + 1
            end
        end
    end
    if #ledger > 0 then parsed[DK] = ledger end
    return added, refreshed
end

--- Round 28 (#90 device report: doubled self-labeled Vol-4 lines, background
--- order 4,2,1,3): write-time reconciliation of every mechanical background
--- array against the book's group(s).
---   1. BACKFILL — a legacy title-labeled line whose label matches a group
---      member's title (doc_props title/display_title/AI override, normalized)
---      gains that member's file path as its identity key. Existing data heals
---      on the next write.
---   2. SELF-DROP — lines resolving to the book itself go: background about
---      this very book is what the artifact IS. Self-lines only ever arrived
---      via model echoes (now dropped at parse) or title-string drift.
---   3. DEDUPE — per source file/label via mergeBackground (newest wins).
---   4. ORDER — series position first (reading order), then other file-keyed
---      lines, then legacy labels in arrival order.
--- Dormant stubs get the same treatment (incl. their own source-file
--- backfill; a stub sourced from this very book is dropped). Bounded cost:
--- one DocSettings resolve per group member, only when the artifact carries
--- background or a ledger at all.
--- @param parsed table Parsed X-Ray data (mutated)
--- @param file string This book's file path
--- @param ui table|nil Live UI handle (open-book resolves)
--- @return boolean changed True when anything was modified
function XrayMerge.reconcileBackground(parsed, file, ui)
    if type(parsed) ~= "table" or type(file) ~= "string" or file == "" then return false end
    local XrayParser = require("koassistant.xray.xray_parser")
    local DK = XrayParser.DORMANT_KEY
    -- Fast out: nothing to reconcile
    local function anyBg(items)
        for _idx, item in ipairs(items) do
            if type(item) == "table" and type(item.background) == "table"
                and #item.background > 0 then
                return true
            end
        end
        return false
    end
    local has_bg = false
    for _idx, cat in ipairs(XrayParser.getCategories(parsed)) do
        if type(cat.items) == "table" and anyBg(cat.items) then
            has_bg = true
            break
        end
    end
    local ledger = type(parsed[DK]) == "table" and parsed[DK] or nil
    if not has_bg and not (ledger and #ledger > 0) then return false end

    local BookGroups = require("koassistant.books.book_groups")
    -- Member set: this book always (self-drop needs its variants), plus every
    -- group-mate; series positions from ordered groups only
    local members, member_list, file_pos = { [file] = true }, { file }, {}
    for _gidx, g in ipairs(BookGroups.groupsFor(file)) do
        -- Round 30: kind is the truth, and it resolves the pre-kind field too
        local ordered = BookGroups.isOrdered(g)
        for i, bf in ipairs(g.books or {}) do
            if type(bf) == "string" and bf ~= "" then
                if not members[bf] then
                    members[bf] = true
                    member_list[#member_list + 1] = bf
                end
                if ordered and file_pos[bf] == nil then file_pos[bf] = i end
            end
        end
    end
    -- Title-variant → file map (normalized). A variant claimed by two
    -- DIFFERENT members is ambiguous — never backfill from it (and never
    -- self-drop on it: a line we cannot attribute is kept).
    local variant_to_file = {}
    for _midx, member in ipairs(member_list) do
        local ok_ds, ds = pcall(function()
            return require("koassistant.storage.doc_settings").resolve(member, ui)
        end)
        if ok_ds and ds then
            local props = require("koassistant.storage.doc_settings").overlayCustomProps(ds:readSetting("doc_props"), member) or {}
            local names = { props.title, props.display_title }
            local ok_ov, ov_title = pcall(function()
                return require("koassistant.books.book_settings").getMetadataOverride(ds)
            end)
            if ok_ov and ov_title ~= nil then names[#names + 1] = ov_title end
            for _n, t in ipairs(names) do
                local norm = normTitle(t)
                if norm and norm ~= "" then
                    if variant_to_file[norm] == nil then
                        variant_to_file[norm] = member
                    elseif variant_to_file[norm] ~= member then
                        variant_to_file[norm] = false -- ambiguous
                    end
                end
            end
        end
    end

    local changed = false
    local function reconcileArray(arr)
        if type(arr) ~= "table" or #arr == 0 then return arr end
        local kept = {}
        for _idx, b in ipairs(arr) do
            if type(b) == "table" and type(b.text) == "string" and b.text ~= "" then
                local line = { source = b.source, text = b.text,
                    file = type(b.file) == "string" and b.file ~= "" and b.file or nil }
                local norm = normTitle(line.source)
                if not line.file and norm then
                    local hit = variant_to_file[norm]
                    if type(hit) == "string" then
                        line.file = hit
                        changed = true
                    end
                end
                if line.file == file then
                    changed = true -- self line dropped (backfill resolved it to this book)
                else
                    kept[#kept + 1] = line
                end
            else
                changed = true -- malformed line dropped
            end
        end
        local merged = XrayParser.mergeBackground(nil, kept) or {}
        -- Order: series position → other file-keyed → legacy, arrival order
        -- kept inside each bucket (positions are unique per file post-dedupe,
        -- so the sort has no equal keys to destabilize)
        local pos_b, file_b, legacy_b = {}, {}, {}
        for _idx, b in ipairs(merged) do
            if b.file and file_pos[b.file] then
                pos_b[#pos_b + 1] = b
            elseif b.file then
                file_b[#file_b + 1] = b
            else
                legacy_b[#legacy_b + 1] = b
            end
        end
        table.sort(pos_b, function(a, b2) return file_pos[a.file] < file_pos[b2.file] end)
        local out = {}
        for _bidx, bucket in ipairs({ pos_b, file_b, legacy_b }) do
            for _l, b in ipairs(bucket) do out[#out + 1] = b end
        end
        if #out ~= #arr then
            changed = true
        else
            for i, b in ipairs(out) do
                local o = arr[i]
                if type(o) ~= "table" or o.source ~= b.source
                    or o.file ~= b.file or o.text ~= b.text then
                    changed = true
                    break
                end
            end
        end
        if #out == 0 then return nil end
        return out
    end

    for _idx, cat in ipairs(XrayParser.getCategories(parsed)) do
        if type(cat.items) == "table" then
            for _idx2, item in ipairs(cat.items) do
                if type(item) == "table" and item.background ~= nil then
                    item.background = reconcileArray(item.background)
                end
            end
        end
    end
    if ledger then
        local kept_stubs = {}
        for _idx, stub in ipairs(ledger) do
            if type(stub) == "table" then
                local snorm = normTitle(stub.source)
                if not stub.file and snorm then
                    local hit = variant_to_file[snorm]
                    if type(hit) == "string" then
                        stub.file = hit
                        changed = true
                    end
                end
                if stub.background ~= nil then
                    stub.background = reconcileArray(stub.background)
                end
                if stub.file == file then
                    changed = true -- a stub of the book itself is meaningless here
                else
                    kept_stubs[#kept_stubs + 1] = stub
                end
            else
                changed = true
            end
        end
        parsed[DK] = #kept_stubs > 0 and kept_stubs or nil
    end
    return changed
end

--- Nearest eligible carry source: walks the group's predecessors nearest→
--- farthest and returns the FIRST with a valid JSON main X-Ray AND
--- text-extraction consent (its own ledger rides along, so one eligible
--- predecessor carries everything it knows — transitive). Shared by the
--- create-time seed and the naming canon (carry layer 3(iii)).
--- @param file string Target book path
--- @param features table|nil Current settings features (consent resolution)
--- @param provider string|nil Provider id (trusted-provider consent)
--- @param ui table|nil
--- @return table|nil src { file, title, entry, parsed }
function XrayMerge.seedSource(file, features, provider, ui)
    if type(file) ~= "string" or file == "" then return nil end
    local BookGroups = require("koassistant.books.book_groups")
    local preds = BookGroups.predecessorsOf(file)
    if #preds == 0 then return nil end
    local ActionCache = require("koassistant.artifacts.action_cache")
    local XrayParser = require("koassistant.xray.xray_parser")
    for i = #preds, 1, -1 do
        local entry = ActionCache.getXrayCache(preds[i])
        if entry and entry.result and XrayParser.isJSON(entry.result)
            and XrayMerge.carryOk(entry, features, provider, preds[i], ui) then
            local source_parsed = XrayParser.parse(entry.result)
            if source_parsed and not source_parsed.error then
                return { file = preds[i], title = BookGroups.displayTitle(preds[i], ui),
                    entry = entry, parsed = source_parsed }
            end
        end
    end
    return nil
end

--- Carry layer 3(i): mechanical create-time seed — a fresh (or rebuilt) main
--- X-Ray starts its dormant ledger from the nearest X-Rayed predecessor in
--- the book's group (seedSource), locally and token-free; the artifact's
--- visible content is untouched. Skip-volume wake then works even if the
--- reader never merges, and a complete rebuild recovers the ledger it just
--- dropped.
--- @param file string Target book path
--- @param parsed table Freshly parsed X-Ray data (mutated: ledger populated)
--- @param features table|nil Current settings features (consent resolution)
--- @param provider string|nil Provider id (trusted-provider consent)
--- @param ui table|nil
--- @return number added, string|nil source_title
--- Books this X-Ray's carried list is seeded from (S4, ref #90): an ordered
--- group gives the nearest consented X-Rayed EARLIER book (its own carried
--- list brings the rest along transitively); an unordered knowledge-sharing
--- group (project) gives EVERY other consented X-Rayed member; a plain group
--- none. Fresh parses — safe to mutate downstream.
--- @return table sources { { file, title, entry, parsed }, ... }
function XrayMerge.seedSources(file, features, provider, ui)
    local out = {}
    if type(file) ~= "string" or file == "" then return out end
    local one = XrayMerge.seedSource(file, features, provider, ui)
    if one then
        out[1] = one
        return out
    end
    local BookGroups = require("koassistant.books.book_groups")
    local group = type(BookGroups.groupsFor) == "function" and BookGroups.groupsFor(file)[1] or nil
    if not group or BookGroups.isOrdered(group) or not BookGroups.sharesKnowledge(group) then
        return out
    end
    local ActionCache = require("koassistant.artifacts.action_cache")
    local XrayParser = require("koassistant.xray.xray_parser")
    for _idx, p in ipairs(group.books) do
        if p ~= file then
            local entry = ActionCache.getXrayCache(p)
            if entry and entry.result and entry.source_mode ~= "ai_knowledge"
                and XrayParser.isJSON(entry.result)
                and XrayMerge.carryOk(entry, features, provider, p, ui) then
                local parsed = XrayParser.parse(entry.result)
                if parsed and not parsed.error then
                    out[#out + 1] = { file = p, title = BookGroups.displayTitle(p, ui),
                        entry = entry, parsed = parsed }
                end
            end
        end
    end
    return out
end

--- The reader's removals for a book, or nil when unreadable (tests without
--- a sidecar shim, and nothing else, land here).
local function removedStubsFor(file)
    local ok, skip = pcall(function()
        return require("koassistant.artifacts.action_cache").getRemovedStubs(file)
    end)
    return ok and skip or nil
end

function XrayMerge.seedDormant(file, parsed, features, provider, ui)
    if type(parsed) ~= "table" then return 0, nil end
    local sources = XrayMerge.seedSources(file, features, provider, ui)
    if #sources == 0 then return 0, nil end
    local skip = removedStubsFor(file)
    local added, titles = 0, {}
    for _idx, src in ipairs(sources) do
        local n = XrayMerge.populateDormant(parsed, nil, src.parsed, src.title,
            src.file, nil, file, skip, true)
        added = added + n
        titles[#titles + 1] = src.title
    end
    return added, table.concat(titles, ", ")
end

-- Files whose pre-seed version was already ring-archived this session (the
-- browser's once-per-session rule for carried-list edits)
local reseed_archived = {}

--- Automatic seeding of EXISTING X-Rays (S4, maintainer 2026-09-02): every
--- member with a live text-based X-Ray gets its carried list refreshed from
--- its seed sources, in list order (an ordered chain completes front to back
--- within one run — a member's fresh list feeds the next member's seed).
--- Zero tokens. A member is written only when the seed actually adds or
--- changes something (dry run on a throwaway parse first), through
--- editLiveXray (pre-op version archived once per session). Removed entries
--- stay removed (tombstones). Idempotent. B536: each member's share is made
--- current first (XrayMerge.refreshCarried: what its groups no longer give
--- goes), and after a change of the group itself a plain group's members are
--- refreshed too, so a group that stops carrying drops what it held.
--- @param group table The group record
--- @param features table Settings features (consent)
--- @param provider string|nil Active provider id (trusted-provider consent)
--- @param ui table|nil
--- @param opts table|nil { changed = the group itself changed (members,
---   order, kind), memo / done = one run's shared reads and refreshed books }
--- @return number written, number checked
function XrayMerge.reseedGroup(group, features, provider, ui, opts)
    if type(group) ~= "table" or type(group.books) ~= "table" then return 0, 0 end
    opts = opts or {}
    local BookGroups = require("koassistant.books.book_groups")
    if not BookGroups.sharesKnowledge(group) and not opts.changed then return 0, 0 end
    local memo, done = opts.memo or {}, opts.done or {}
    local written, checked = 0, 0
    for _idx, file in ipairs(group.books) do
        local wrote, looked = XrayMerge.refreshCarried(file, features, provider, ui,
            { memo = memo, done = done, explicit = opts.changed })
        if looked then checked = checked + 1 end
        if wrote then written = written + 1 end
    end
    return written, checked
end

--- Carry ONE entry from an earlier book's X-Ray into a book's carried
--- list (S2 Q2, ref #90): the reader-asserted single-entity form of the
--- create-time seed — the same stub shape populateDormant builds, appended
--- (or refreshed) by name. Pure on parsed data; the caller writes via
--- WriteBack.editLiveXray and checks consent (same rule as the seed). A
--- transitive pick (the predecessor's own stub) keeps its ORIGINAL
--- provenance through `prov`. Reached only after a full local miss, so no
--- already-active self-filter is needed here.
--- @param parsed table Current book's parsed live X-Ray (mutated)
--- @param item table The predecessor entry (active item or stub)
--- @param category_key string
--- @param prov table|nil { source, file } Provenance for the stub
--- @return boolean ok
function XrayMerge.carryOne(parsed, item, category_key, prov)
    local XrayParser = require("koassistant.xray.xray_parser")
    if type(parsed) ~= "table" or type(item) ~= "table" then return false end
    local name = XrayParser.getItemName(item, category_key)
    if type(name) ~= "string" or name == "" then return false end
    if name ~= item.name and name ~= item.term and name ~= item.event then
        -- getItemName's translated "Unknown" fallback: nothing real to carry
        return false
    end
    local aliases
    if type(item.aliases) == "table" and #item.aliases > 0 then
        aliases = {}
        for _idx, a in ipairs(item.aliases) do aliases[#aliases + 1] = a end
    end
    local desc
    for _idx, f in ipairs({ "description", "definition", "significance", "summary" }) do
        if type(item[f]) == "string" and item[f] ~= "" then
            desc = item[f]
            break
        end
    end
    local background
    if type(item.background) == "table" then
        for _idx, b in ipairs(item.background) do
            if type(b) == "table" and type(b.text) == "string" and b.text ~= ""
                and type(b.source) == "string" and b.source ~= "" then
                background = background or {}
                background[#background + 1] = { source = b.source, text = b.text,
                    file = type(b.file) == "string" and b.file or nil }
            end
        end
    end
    local DK = XrayParser.DORMANT_KEY
    local ledger = parsed[DK]
    if type(ledger) ~= "table" then
        ledger = {}
        parsed[DK] = ledger
    end
    local stub = {
        name = name,
        aliases = aliases,
        category = category_key,
        role = type(item.role) == "string" and item.role ~= "" and item.role or nil,
        description = desc,
        source = prov and prov.source or nil,
        file = prov and prov.file or nil,
        background = background,
        -- B536: the reader's pick, not the group's carry: it stays when the
        -- book it came from leaves the group (XrayMerge.pruneCarried)
        by_hand = true,
    }
    local key = name:lower()
    for i, s in ipairs(ledger) do
        if type(s) == "table" and type(s.name) == "string" and s.name:lower() == key then
            stub.background = XrayParser.mergeBackground(s.background, stub.background)
            ledger[i] = stub
            return true
        end
    end
    ledger[#ledger + 1] = stub
    return true
end

--- Alias bridge for the CREATE request (carry layer 3(iii), 2026-08-06;
--- REFRAMED 2026-08-07): IDENTITY HANDLES — names + up to two aliases, never
--- content — of the predecessor's named entities, plus its dormant ledger's
--- (transitive). Injected into every fresh create of a grouped book whose
--- earlier book has an X-Ray, whatever the fold ask's answer (B394 slice 3).
--- The first cut told the model to reuse the earlier book's NAME for a
--- recurring entity. Wrong (maintainer): an X-Ray is a companion to THIS book,
--- so an entry must be called what this book calls it — titling book 5's "the
--- Magister" as book 1's "Tobias Renn" names someone the reader has not met
--- under that name, and leaks a reveal the book may be withholding. It also
--- bought nothing: the wake-pass and merges match on name OR alias, so an
--- alias is a complete link. Now the block asks for exactly that — this book's
--- name on the entry, the earlier name in "aliases" when the text supports the
--- identification. Pure.
--- @param source_parsed table Predecessor's parsed X-Ray
--- @param source_title string|nil
--- @return string|nil block Framed prompt block (nil when nothing to list)
function XrayMerge.namingCanonBlock(source_parsed, source_title, exclude_files)
    if type(source_parsed) ~= "table" then return nil end
    local XrayParser = require("koassistant.xray.xray_parser")
    local order, bucket = {}, {}
    local function put(cat_key, name, aliases)
        if type(name) ~= "string" or name == "" then return end
        if not bucket[cat_key] then
            bucket[cat_key] = {}
            order[#order + 1] = cat_key
        end
        local shown = name
        if type(aliases) == "table" and #aliases > 0 then
            local a = {}
            for i = 1, math.min(2, #aliases) do a[i] = tostring(aliases[i]) end
            shown = shown .. " (" .. table.concat(a, ", ") .. ")"
        end
        bucket[cat_key][#bucket[cat_key] + 1] = shown
    end
    for _idx, cat in ipairs(XrayParser.getCategories(source_parsed)) do
        if ENTITY_CATEGORIES[cat.key] and type(cat.items) == "table" then
            for _idx2, item in ipairs(cat.items) do
                if type(item) == "table" then
                    put(cat.key, XrayParser.getItemName(item, cat.key), item.aliases)
                end
            end
        end
    end
    local ledger = source_parsed[XrayParser.DORMANT_KEY]
    if type(ledger) == "table" then
        for _idx, stub in ipairs(ledger) do
            if type(stub) == "table" and ENTITY_CATEGORIES[stub.category or ""]
                    and not (exclude_files and stub.file and exclude_files[stub.file]) then
                put(stub.category, stub.name, stub.aliases)
            end
        end
    end
    if #order == 0 then return nil end
    local lines = {}
    for _idx, key in ipairs(order) do
        lines[#lines + 1] = key .. ": " .. table.concat(bucket[key], "; ")
    end
    return "[Earlier book reference]\nThis book is part of the same series as \""
        .. (source_title or "?")
        .. "\", whose X-Ray already exists. The names below are an ALIAS BRIDGE, not naming "
        .. "instructions. Name every entry the way THIS book names it — an entry's \"name\" "
        .. "must be a name this book's text actually uses. If one of your entries is clearly "
        .. "the same person, place or term as one below, add that earlier name to that "
        .. "entry's \"aliases\" so the two books can be linked. Never rename an entry to "
        .. "match the list, never add entries for names that do not appear in this book's "
        .. "text, and do not guess an identity the text does not support.\n"
        .. table.concat(lines, "\n")
end

--- Ledger union for cross-book merges: the target's ledger + the source + the
--- source's OWN ledger — a merge carries the source's ancestor-labeled
--- background along (item 49), so transitive sources are genuinely included and
--- must be recorded, or chained volumes read as gap-ridden (provenanceGap) and
--- "Includes background from" understates. Transitive records deliberately
--- carry NO version: we hold the ancestor's content second-hand, so which
--- version of it we have is the source book's fact, not ours to claim. Pure.
--- @param ledger table|nil Target's ledger (XrayMerge.ledgerOf output)
--- @param source_desc table { file =, title =, source_ts = } The book being folded in
--- @param source_ledger table|nil That book's own ledger
--- @return table ledger
function XrayMerge.unionMergedFrom(ledger, source_desc, source_ledger)
    local out = XrayMerge.appendMergedFrom(ledger, source_desc)
    for _idx, rec in ipairs(source_ledger or {}) do
        XrayMerge.appendMergedFrom(out, { file = rec.file, title = rec.title })
    end
    return out
end

--- Carry layer 3(ii) gap check: which of these titles are missing from a
--- book's merge provenance? Same trimmed-exact title identity the ledger uses.
--- Pure.
--- @param titles table Ordered titles that SHOULD have been folded in
--- @param ledger table|nil The book's ledger (XrayMerge.ledgerOf output)
--- @return table missing Titles not found in the provenance
function XrayMerge.provenanceGap(titles, ledger)
    local have = {}
    for _idx, rec in ipairs(ledger or {}) do have[rec.title] = true end
    local missing = {}
    for _idx, t in ipairs(titles or {}) do
        if not have[t] then missing[#missing + 1] = t end
    end
    return missing
end

--- Pre-merge transform for cross-book deltas (rides WriteBack.applyXray's
--- transform hook): applies background_updates to the BASE, strips the
--- protected categories, and drops any disobedient full rewrite of an
--- existing entity from the delta (salvaging its aliases) — so a cross-book
--- merge can NEVER replace or shorten what the target book already knows,
--- regardless of model tier. When source_parsed is given, the source's own
--- background lines carry over transitively (see carrySourceBackground);
--- labels actually carried are appended to meta_out.merged_from_books (the
--- SAME table later read by reconcileXrayMeta — the transform runs first).
--- @param source_title string The related book's title
--- @param source_parsed table|nil Parsed source X-Ray (transitive carry input)
--- @param target_title string|nil The target book's title (self-label filter)
--- @param meta_out table|nil applyXray meta table to receive carried labels
--- @param source_file string|nil Source book file path (round 28 identity key)
--- @param target_file string|nil Target book file path (robust self-filter)
--- @return function transform(delta, base_parsed)
function XrayMerge.crossBookTransform(source_title, source_parsed, target_title, meta_out,
        source_file, target_file, stats)
    return function(delta, base_parsed)
        if type(delta) ~= "table" or type(base_parsed) ~= "table" then return end
        local updates = delta.background_updates
        delta.background_updates = nil
        local applied, unmatched = XrayMerge.applyBackgroundUpdates(
            base_parsed, updates or {}, source_title, source_file)
        for key in pairs(PROTECTED_CATEGORIES) do delta[key] = nil end
        local lookup = buildEntityLookup(base_parsed)
        local dropped = 0
        for key, arr in pairs(delta) do
            if type(arr) == "table" and #arr > 0 then
                local kept = {}
                for _idx, entry in ipairs(arr) do
                    local name = type(entry) == "table" and (entry.name or entry.term)
                    local hit = type(name) == "string" and lookup[name:lower()]
                    if hit then
                        mergeAliasesInto(hit, entry.aliases)
                        dropped = dropped + 1
                    else
                        kept[#kept + 1] = entry
                    end
                end
                if #kept ~= #arr then delta[key] = kept end
            end
        end
        local carried_n = 0
        local stubbed = 0
        if type(source_parsed) == "table" then
            local labels = XrayMerge.carrySourceBackground(
                base_parsed, delta, source_parsed, target_title, target_file)
            carried_n = #labels
            if meta_out then
                -- Carried labels name ancestor books we never read: title only,
                -- no version — they land in the ledger as "unknown" folds.
                local led = XrayMerge.ledgerOf(meta_out)
                for _idx, label in ipairs(labels) do
                    XrayMerge.appendMergedFrom(led, { title = label })
                end
                meta_out.merged_from = led
                meta_out.merged_from_books = XrayMerge.provenanceString(led)
            end
            -- Carry layer 1: whatever did NOT arrive goes dormant instead of
            -- being lost — the wake-pass right after the merge promotes any
            -- stub that already matches.
            -- Round 28 considered gating this on a SERIES relationship (a
            -- dormant stub reads as "has not appeared YET", a sequence claim)
            -- and REVERTED: round 27 already decided full inclusion precisely
            -- because a non-series PROJECT group wants its siblings' entities
            -- carried. The zero-overlap case that motivated the idea is now
            -- handled earlier and better — an empty delta never reaches a
            -- write at all (executeCrossBook's isEmptyDelta short-circuit).
            stubbed = XrayMerge.populateDormant(base_parsed, delta, source_parsed,
                source_title, source_file, target_title, target_file)
        end
        -- Round 28: what the fold actually CHANGED, so the caller can tell a
        -- legitimate "these books share nothing" from a successful merge
        local arrived = 0
        for key, arr in pairs(delta) do
            if not PROTECTED_CATEGORIES[key] and type(arr) == "table" then
                arrived = arrived + #arr
            end
        end
        if stats then
            stats.applied = applied
            stats.arrived = arrived
            stats.stubbed = stubbed
        end
        logger.dbg("KOAssistant XrayMerge: cross-book background —",
            applied, "applied,", unmatched, "unmatched,", dropped, "rewrites dropped,",
            carried_n, "ancestor labels carried,", stubbed, "gone dormant,",
            arrived, "new entities")
    end
end

--- Replace the sentinel tokens with the artifact JSON. Called from
--- handlePredefinedPrompt AFTER MessageBuilder.build has finished — every
--- placeholder pass has already run, so nothing can strip lines or substitute
--- placeholder literals inside the injected JSON. ONE left-to-right scan over
--- the ORIGINAL message with an output buffer: replacements are never
--- rescanned, by ANY token — sequential per-token passes would let a token
--- literal inside one payload be replaced by a later token's pass. Pure.
--- @param message string The built consolidated message
--- @param payload table { inputs, main, index, never } from the prompt builders
--- @return string message with payload injected
function XrayMerge.injectPayload(message, payload)
    if type(message) ~= "string" or type(payload) ~= "table" then return message end
    local index_block = ""
    if payload.index and payload.index ~= "" then
        -- Same framing as the incremental update path (koassistant/request/message_builder.lua)
        index_block = "Existing entities in previous analysis:\n" .. payload.index
    end
    local never_block = ""
    if payload.never and payload.never ~= "" then
        never_block = "These are DIFFERENT entities (reader-confirmed) — never merge them into one entry:\n"
            .. payload.never
    end
    local values = {
        ["@@KOA_MERGE_INPUTS@@"] = payload.inputs or "",
        ["@@KOA_MERGE_MAIN@@"] = payload.main or "",
        ["@@KOA_MERGE_INDEX@@"] = index_block,
        ["@@KOA_MERGE_NEVER@@"] = never_block,
    }
    local out = {}
    local pos = 1
    while true do
        local best_s, best_e, best_v
        for token, value in pairs(values) do
            local s, e = message:find(token, pos, true)
            if s and (not best_s or s < best_s) then
                best_s, best_e, best_v = s, e, value
            end
        end
        if not best_s then
            out[#out + 1] = message:sub(pos)
            break
        end
        out[#out + 1] = message:sub(pos, best_s - 1)
        out[#out + 1] = best_v
        pos = best_e + 1
    end
    return table.concat(out)
end

--- Union permission metadata across the inputs (sticky-true: the merged
--- artifact contains every input's material). nil beats explicit false — the
--- read gates treat nil/legacy as "used" (conservative). Pure.
--- @param entries table Array of cache entries (section .data tables)
--- @return table { used_book_text, used_highlights }
function XrayMerge.unionInputMeta(entries)
    local function unionFlag(field)
        local saw_nil = false
        for _idx, e in ipairs(entries) do
            if e[field] == true then return true end
            if e[field] == nil then saw_nil = true end
        end
        if saw_nil then return nil end
        return false
    end
    return {
        used_book_text = unionFlag("used_book_text"),
        used_highlights = unionFlag("used_highlights"),
    }
end

--- Scope fields for a combined-section target: union range, composite label
--- (range-picker "A – B" precedent). Pure; sections assumed sorted by start.
--- @param sections table getSections-shaped array (sorted)
--- @return table scope { label, start_page, end_page, start_xpointer, end_xpointer, page_summary }
function XrayMerge.combinedScope(sections)
    local first = sections[1]
    local last = sections[#sections]
    local label
    if #sections == 1 or first.label == last.label then
        label = first.label
    else
        label = (first.label or "?") .. " – " .. (last.label or "?")
    end
    local start_page = first.data and first.data.scope_start_page
    local end_page = last.data and last.data.scope_end_page
    local page_summary
    if start_page and end_page then
        page_summary = T(_("pp %1–%2"), start_page, end_page)
    end
    return {
        label = label,
        start_page = start_page,
        end_page = end_page,
        start_xpointer = first.data and first.data.scope_start_xpointer,
        end_xpointer = last.data and last.data.scope_end_xpointer,
        page_summary = page_summary,
    }
end

--- Text-extraction read gate for the merge: the inputs are text-DERIVED
--- artifacts, and sending them must respect the same dynamic permission the
--- cache read gates enforce (revoked consent blocks injection — it must block
--- re-sending through a merge too). Trusted providers bypass, as everywhere.
--- The book's per-book privacy override (book_file, optional) wins in both
--- directions — deny beats trusted.
--- @return boolean allowed
function XrayMerge.consentOk(entries, features, provider, book_file, ui)
    local Gates = require("koassistant.request.privacy_gates")
    local needs_text = false
    for _idx, e in ipairs(entries) do
        if Gates.stampedKinds(e).book_text then
            needs_text = true
            break
        end
    end
    if not needs_text then return true end
    -- The book's own value, a run's allowance on this config, trust, the switch
    return Gates.allows("book_text", Gates.context(features, provider, { path = book_file, ui = ui }))
end

--- The carry's rule (B395 slice 5): a book's X-Ray may be read INTO another
--- book's carried list, locally and token-free, unless a kind it was built
--- from is Never for that book (a Never book contributes nothing). Ask is
--- fine here: nothing is sent at seed time, and the prompt seams that list
--- carried names drop the Never sources (neverSourceFiles).
function XrayMerge.carryOk(entry, features, provider, book_file, ui)
    local Gates = require("koassistant.request.privacy_gates")
    local ctx
    for _idx, kind in ipairs(Gates.stampedList(entry or {})) do
        ctx = ctx or Gates.context(features, provider, { path = book_file, ui = ui })
        if not Gates.usable(kind, ctx) then return false end
    end
    return true
end

--- The source books of a parsed X-Ray's carried list whose text is Never
--- (their own value or the switch), as a set of files for the prompt seams
--- that list carried names: the entity index and the naming canon.
function XrayMerge.neverSourceFiles(parsed, features, provider, ui)
    local Gates = require("koassistant.request.privacy_gates")
    local XrayParser = require("koassistant.xray.xray_parser")
    local out, seen = {}, {}
    local ledger = type(parsed) == "table" and parsed[XrayParser.DORMANT_KEY]
    if type(ledger) ~= "table" then return out end
    for _idx, stub in ipairs(ledger) do
        local file = type(stub) == "table" and stub.file
        if type(file) == "string" and file ~= "" and not seen[file] then
            seen[file] = true
            if not Gates.usable("book_text", Gates.context(features, provider, { path = file, ui = ui })) then
                out[file] = true
            end
        end
    end
    return out
end

--- One entry standing for several (a section merge's inputs): stamped with
--- every kind any of them was built from.
function XrayMerge.unionStamps(entries)
    local Gates = require("koassistant.request.privacy_gates")
    local out = { used_book_text = false }
    local field = { book_text = "used_book_text", highlights = "used_highlights",
        annotations = "used_annotations", notebook = "used_notebook" }
    for _idx, e in ipairs(entries or {}) do
        for kind, used in pairs(Gates.stampedKinds(e)) do
            if used and field[kind] then out[field[kind]] = true end
        end
    end
    if out.used_annotations and out.used_highlights == nil then out.used_highlights = false end
    return out
end

--- A Never on any book an AI merge would send: the refusal with that book's
--- door (B395 slice 5). books: { { file, title, entry }, ... }.
--- @return boolean refused
function XrayMerge.refusedBook(opts, books, action_name)
    local Gates = require("koassistant.request.privacy_gates")
    local cfg = opts.configuration or {}
    local provider = cfg.provider or cfg.default_provider
    for _idx, b in ipairs(books or {}) do
        for _k, kind in ipairs(Gates.stampedList(b.entry or {})) do
            local state, layer = Gates.resolve(kind,
                Gates.context(cfg.features or {}, provider, { path = b.file, ui = opts.ui }))
            if state == "never" then
                require("koassistant.ui.data_access").refuse(opts.plugin, { kind = kind, layer = layer,
                    action_name = action_name, path = b.file, ui = opts.ui })
                return true
            end
        end
    end
    return false
end

--- The question before an AI merge (B395 slice 5): the books whose X-Rays
--- the run sends, each with the kinds its X-Ray was built from. A Never on
--- any of them refuses (refusedBook); the kinds on Ask are asked once for
--- the set; the allowance lands on a PRIVATE copy of the configuration,
--- which run(run_cfg) receives and every request of the run is built from
--- (a chain's later hops must find it; nothing else may).
--- @return boolean true when the run started or a question is up
function XrayMerge.withDataAccess(opts, books, action_name, run)
    if XrayMerge.refusedBook(opts, books, action_name) then return false end
    local Gates = require("koassistant.request.privacy_gates")
    local src = opts.configuration or {}
    local run_cfg = {}
    for k, v in pairs(src) do run_cfg[k] = v end
    run_cfg.features = {}
    for k, v in pairs(src.features or {}) do run_cfg.features[k] = v end
    run_cfg.features._data_once = nil
    local set = {}
    for _idx, b in ipairs(books or {}) do
        set[#set + 1] = { file = b.file, title = b.title, kinds = Gates.stampedKinds(b.entry or {}) }
    end
    require("koassistant.ui.data_access").withAccess(opts.plugin, nil, {
        features = run_cfg.features, provider = run_cfg.provider or run_cfg.default_provider,
        books = set, ui = opts.ui, action_name = action_name,
        amounts = {
            book_text = _("the X-Rays of these books, built from their text"),
            highlights = _("the highlights these X-Rays were built with"),
            annotations = _("the notes these X-Rays were built with"),
            notebook = _("the notebook these X-Rays were built with"),
        },
    }, function() run(run_cfg) end)
    return true
end

-- ============================ execution ============================

--- Config copy for a headless artifact request (never the shared module
--- table; the nested book_metadata gets a fresh copy too — CLAUDE.md Config
--- Copy Pattern), with the sentinel payload riding the consume-once
--- _merge_payload transient. Shared with the entity dedup flow (§6 slice 4).
--- Caller is responsible for updateConfigFromSettings beforehand.
--- @param opts table { configuration, file, title, author }
--- @param payload table injectPayload payload
--- @return table config, table bm (the fresh book_metadata)
function XrayMerge.buildHeadlessConfig(opts, payload)
    local config = {}
    for k, v in pairs(opts.configuration or {}) do config[k] = v end
    config.features = {}
    for k, v in pairs((opts.configuration or {}).features or {}) do config.features[k] = v end
    config.features.is_book_context = true
    config.features.is_general_context = nil
    config.features.is_library_context = nil
    -- Round 25 (device report): merges emit raw delta JSON, and the post-create
    -- fold runs OVER the X-Ray the reader just opened — a full-screen JSON dump
    -- there reads as "it opened the wrong X-Ray". Hidden streaming keeps the
    -- waiting animation, the Show toggle and the cancel affordance. Round 26:
    -- name the work — the placeholder used to be hardcoded quiz wording.
    config.features.hidden_streaming = true
    config.features.hidden_streaming_label = _("AI merge in progress")  -- a paid merge says "AI merge" everywhere (B401, B440)
    config.features.hidden_streaming_note = _("Tap Show to watch it arrive.")
    local bm = {}
    for k, v in pairs(config.features.book_metadata or {}) do bm[k] = v end
    bm.file = opts.file
    -- Identity comes from the TARGET book, NEVER inherited from whatever book
    -- happens to be open — merges can launch from a cross-book-viewed X-Ray
    -- (group nav / artifact browser), and "identity sent and sidecar consulted
    -- must be the same book" (item 46 follow-up). Missing title/author resolve
    -- from the target's own doc_props + AI override.
    local title, author = opts.title, opts.author
    if not title or title == "" or author == nil then
        local ok, ds = pcall(function()
            return require("koassistant.storage.doc_settings").resolve(opts.file, opts.ui)
        end)
        if ok and ds then
            local props = require("koassistant.storage.doc_settings").overlayCustomProps(ds:readSetting("doc_props"), opts.file) or {}
            local ok_ov, ov_t, ov_a = pcall(function()
                return require("koassistant.books.book_settings").getMetadataOverride(ds)
            end)
            if not title or title == "" then
                title = props.display_title or props.title
                if ok_ov and ov_t ~= nil then title = ov_t end
            end
            if author == nil then
                author = props.authors
                if type(author) == "string" and author:find("\n") then
                    author = author:gsub("\n", ", ")
                end
                if ok_ov and ov_a ~= nil then author = ov_a end
            end
        end
    end
    if not title or title == "" then
        title = opts.file:match("([^/]+)%.[^.]+$") or opts.file:match("([^/]+)$") or opts.file
    end
    bm.title = title
    bm.author = author or ""
    bm.author_clause = (bm.author ~= "" and (" by " .. bm.author)) or ""
    -- Stale DOI from another book would flip research mode on a structural merge
    bm.doi = nil
    bm.doi_clause = nil
    config.features.book_metadata = bm
    -- The synthetic identity channel must match the gated one (book identity
    -- reaches the AI via TWO channels — CLAUDE.md): never the open book's string
    config.features.book_context = bm.title .. bm.author_clause
    -- Wire-safety: the payloads ride the late sentinel injection, never action.prompt
    config.features._merge_payload = payload
    return config, bm
end

--- Run the merge headlessly and write the result.
--- @param opts table { file, ui, plugin, configuration, sections (getSections
---   rows, sorted), target = "main"|"section", main_entry, delta_mode,
---   coverage_ratio (flow-aware 0..1 or nil), title, author, on_done(ok, err) }
function XrayMerge.execute(opts)
    local Dialogs = require("koassistant.ui.dialogs")
    local ActionCache = require("koassistant.artifacts.action_cache")
    local WriteBack = require("koassistant.xray.artifact_writeback")
    local XrayParser = require("koassistant.xray.xray_parser")

    local into_main = opts.target == "main"
    local delta_mode = opts.delta_mode and into_main

    -- Reader-confirmed distinct pairs steer the model's entity merging (§6
    -- slice 4 — same list the duplicate scan consults)
    local never_pairs = ActionCache.getNeverMergePairs(opts.file)

    local prompt_text, payload
    if delta_mode then
        local parsed_main = XrayParser.parse(opts.main_entry.result)
        -- The carried names listed are the ones the section X-Rays mention (B394 slice 4)
        local m_cfg = opts.configuration or {}
        local entity_index = parsed_main and XrayParser.buildEntityIndex(parsed_main,
            { text = XrayMerge.buildInputsBlock(opts.sections),
              exclude_files = XrayMerge.neverSourceFiles(parsed_main, m_cfg.features,
                  m_cfg.provider or m_cfg.default_provider, opts.ui) }) or ""
        prompt_text, payload = XrayMerge.buildDeltaPrompt(opts.sections, opts.main_entry, entity_index, never_pairs)
    else
        prompt_text, payload = XrayMerge.buildCompletePrompt(opts.sections, never_pairs)
    end

    -- Synthetic internal action: no extraction, no web, no chat storage, no
    -- response-side caching (the write below is owned by the write-back seam)
    local action = {
        id = "xray_merge",
        text = _("Merge X-Ray"),
        context = "book",
        prompt = prompt_text,
        storage_key = "__SKIP__",
        enable_web_search = false,
        skip_spoiler = true,  -- mechanical JSON merge; a posture nudge could drop entries
        reasoning_config = "off",  -- xray-action parity (T2): structural JSON merge, no reasoning
        api_params = XrayMerge.API_PARAMS,
        builtin = true,
    }

    if opts.plugin and opts.plugin.updateConfigFromSettings then
        opts.plugin:updateConfigFromSettings()
    end
    local config, bm = XrayMerge.buildHeadlessConfig(opts, payload)

    local input_entries = {}
    for _idx, sec in ipairs(opts.sections) do input_entries[#input_entries + 1] = sec.data end

    local plugin_ref = opts.plugin
    local file = opts.file
    Dialogs.executeActionForResult(action, config.features.book_context or "", opts.ui, config,
        opts.plugin, bm,
        function(result, meta_or_err)
            if not result then
                -- Round 26: a fold that never came back logged NOTHING between
                -- its request body and the next UI event, so a silent failure
                -- was indistinguishable from "the fold ran and changed nothing"
                logger.info("KOAssistant XrayMerge: fold into", file, "FAILED:",
                    tostring(meta_or_err or "no response"))
                if opts.on_done then opts.on_done(false, tostring(meta_or_err or "no response")) end
                return
            end
            -- model_info is unreliable on this seam (may be "" — pre-existing);
            -- nil lets reconciliation fall back to the base's model
            local model_name = type(meta_or_err) == "table"
                and meta_or_err.model ~= "" and meta_or_err.model or nil
            local used_reasoning = type(meta_or_err) == "table"
                and meta_or_err.used_reasoning or nil
            local union = XrayMerge.unionInputMeta(input_entries)
            -- Timeline slice 1: honest input coverage — the union of every
            -- input's spans, holes preserved (spaced-apart sections no longer
            -- overstate in metadata). The base's own spans union in via
            -- reconcileXrayMeta on the delta path.
            local input_spans
            for _idx, e in ipairs(input_entries) do
                -- A section's range as it falls in this layout when the book
                -- is open (B503), else as recorded
                local sp, ep
                if opts.section_range then sp, ep = opts.section_range(e) end
                input_spans = WriteBack.unionSpans(input_spans,
                    (sp and ep) and (sp .. "-" .. ep) or WriteBack.spansFromEntry(e))
            end

            if into_main then
                local ok, res_or_err = WriteBack.applyXray({
                    document_path = file,
                    answer = result,
                    -- REPLACE mode (no/legacy main): metadata comes from the
                    -- inputs alone — the old main's content is not in the result,
                    -- so no flag inheritance and no coverage floor from it
                    base = delta_mode and opts.main_entry or nil,
                    base_entry = delta_mode and opts.main_entry or nil,
                    progress_decimal = opts.coverage_ratio or 0,
                    meta = {
                        model = model_name,
                        used_reasoning = used_reasoning,
                        used_book_text = union.used_book_text,
                        used_highlights = union.used_highlights,
                        merged_from_sections = #opts.sections,
                        coverage_spans = input_spans,
                        producer = "section_merge",
                    },
                    features = config.features,
                    refresh_fn = function()
                        if plugin_ref then
                            plugin_ref._file_dialog_row_cache = { file = nil, rows = nil }
                            if plugin_ref._refreshXrayAutoState and plugin_ref.ui
                                and plugin_ref.ui.document and plugin_ref.ui.document.file == file then
                                plugin_ref:_refreshXrayAutoState()
                            end
                        end
                    end,
                })
                if ok then
                    -- Stamp the inputs as folded-in (T15): section list + merge
                    -- picker read this. A section regeneration clears it (fresh
                    -- set() carries no merged_to_main); a main redo merely makes
                    -- it historical (informational, timestamped).
                    local keys = {}
                    for _idx, sec in ipairs(opts.sections) do keys[#keys + 1] = sec.key end
                    ActionCache.markSectionsMerged(file, keys, os.time())
                end
                if opts.on_done then opts.on_done(ok, not ok and res_or_err or nil, opts.target) end
            else
                -- Combined-section target: validate, then write a section entry
                -- with the union scope (section conventions: progress 1.0 +
                -- full_document; sanitized key like the manual section writer;
                -- overwrite was confirmed in the flow)
                local parsed, err, cache_json = WriteBack.parseXrayAnswer(result)
                if not parsed then
                    if opts.on_done then opts.on_done(false, err or "parse failed") end
                    return
                end
                local scope = XrayMerge.combinedScope(opts.sections)
                -- The range as it falls in this layout when the book is open
                -- (B503: the inputs may come from other layouts), then the
                -- label in VISIBLE pages when possible (manual-writer parity;
                -- scope_* fields stay raw for extraction math)
                local doc = opts.ui and opts.ui.document
                if doc and not require("koassistant.storage.doc_settings").samePath(doc.file, file) then
                    doc = nil
                end
                if doc and opts.section_range then
                    -- The union of the sections' own ranges, each placed in
                    -- this layout; its bounds keep the positions of the
                    -- sections they come from (a section saved without
                    -- positions makes it a range by pages only: a start with
                    -- no end position would read as "to the end of the book")
                    local sp, ep, first, last
                    for _idx, sec in ipairs(opts.sections) do
                        local s, e = opts.section_range(sec.data)
                        if s and (not sp or s < sp) then sp, first = s, sec end
                        if e and (not ep or e > ep) then ep, last = e, sec end
                    end
                    if sp and ep and sp <= ep then
                        scope.start_page, scope.end_page = sp, ep
                        scope.page_summary = T(_("pp %1–%2"), sp, ep)
                        if first.data.scope_start_xpointer and last.data.scope_start_xpointer then
                            scope.start_xpointer = first.data.scope_start_xpointer
                            scope.end_xpointer = last.data.scope_end_xpointer
                        else
                            scope.start_xpointer, scope.end_xpointer = nil, nil
                        end
                    end
                end
                if doc and scope.start_page and scope.end_page
                    and doc.hasHiddenFlows and doc:hasHiddenFlows() and doc.getPageNumberInFlow then
                    scope.page_summary = T(_("pp %1–%2"),
                        doc:getPageNumberInFlow(scope.start_page) or scope.start_page,
                        doc:getPageNumberInFlow(scope.end_page) or scope.end_page)
                end
                local ok = ActionCache.set(file, XrayMerge.sectionKeyFor(scope.label), cache_json, 1.0, {
                    model = model_name,
                    used_reasoning = used_reasoning,
                    used_book_text = union.used_book_text,
                    used_highlights = union.used_highlights,
                    full_document = true,
                    merged_from_sections = #opts.sections,
                    coverage_spans = input_spans,
                    producer = "section_merge",
                    scope_label = scope.label,
                    scope_start_page = scope.start_page,
                    scope_end_page = scope.end_page,
                    scope_start_xpointer = scope.start_xpointer,
                    scope_end_xpointer = scope.end_xpointer,
                    scope_page_summary = scope.page_summary,
                })
                if ok and plugin_ref then
                    plugin_ref._file_dialog_row_cache = { file = nil, rows = nil }
                end
                if opts.on_done then opts.on_done(ok == true, ok ~= true and "cache write failed" or nil, opts.target) end
            end
        end)
end

--- Cache key for a combined section — same sanitization as the manual section
--- writer (main.lua): colons conflict with the key separator, 80-char cap. Pure.
function XrayMerge.sectionKeyFor(label)
    local ActionCache = require("koassistant.artifacts.action_cache")
    local cache_label = (label or "?"):gsub(":", "-")
    if #cache_label > 80 then cache_label = cache_label:sub(1, 80) end
    return ActionCache.SECTION_PREFIXES.xray .. cache_label
end

-- ============================ UI flow ============================

-- The question before a section merge's one request (B395 slice 5): the
-- kinds every input was built from, once; the run copies from the private
-- config the allowance lands on
local function runSectionMerge(opts)
    local entries = {}
    for _idx, sec in ipairs(opts.sections or {}) do entries[#entries + 1] = sec.data end
    if opts.main_entry then entries[#entries + 1] = opts.main_entry end
    XrayMerge.withDataAccess(opts, { { file = opts.file, title = opts.title,
            entry = XrayMerge.unionStamps(entries) } }, _("AI merge section X-Rays"),
        function(run_cfg)
            opts.configuration = run_cfg
            XrayMerge.execute(opts)
        end)
end

local function showWarningsThenRun(opts, warnings)
    if #warnings == 0 then
        runSectionMerge(opts)
        return
    end
    local ButtonDialog = require("ui/widget/buttondialog")
    local dialog
    dialog = ButtonDialog:new{
        title = table.concat(warnings, "\n\n"),
        buttons = {
            {{
                text = _("AI merge anyway"),
                callback = function()
                    UIManager:close(dialog)
                    runSectionMerge(opts)
                end,
            }},
            {{
                text = _("Cancel"),
                callback = function() UIManager:close(dialog) end,
            }},
        },
    }
    UIManager:show(dialog)
end

--- Combined-section pre-check: overwrite confirm when the sanitized key
--- already exists (mirrors the manual section writer's replace confirm).
local function confirmSectionOverwriteThenRun(opts, warnings)
    local ActionCache = require("koassistant.artifacts.action_cache")
    local ButtonDialog = require("ui/widget/buttondialog")
    local scope = XrayMerge.combinedScope(opts.sections)
    local existing = ActionCache.get(opts.file, XrayMerge.sectionKeyFor(scope.label))
    if not existing then
        showWarningsThenRun(opts, warnings)
        return
    end
    local dialog
    dialog = ButtonDialog:new{
        title = T(_("A Section X-Ray named '%1' already exists. Replace it?"), scope.label),
        buttons = {
            {{
                text = _("Replace"),
                callback = function()
                    UIManager:close(dialog)
                    showWarningsThenRun(opts, warnings)
                end,
            }},
            {{
                text = _("Cancel"),
                callback = function() UIManager:close(dialog) end,
            }},
        },
    }
    UIManager:show(dialog)
end

local function pickTargetThenRun(opts)
    local ButtonDialog = require("ui/widget/buttondialog")
    local WriteBack = require("koassistant.xray.artifact_writeback")
    local XrayParser = require("koassistant.xray.xray_parser")
    local sections = opts.sections

    local scoped = {}
    for _idx, sec in ipairs(sections) do
        -- The section's pages in this layout when the book is open (B503)
        local sp, ep
        if opts.section_range then sp, ep = opts.section_range(sec.data) end
        scoped[#scoped + 1] = {
            label = sec.label,
            start_page = sp or sec.data.scope_start_page,
            end_page = ep or sec.data.scope_end_page,
        }
    end
    local coverage = WriteBack.coverageFromInputs(scoped)
    -- Flow-aware ratio (raw scope pages ÷ raw total misclaims on hidden-flow
    -- books — gate finding): page_ratio_fn maps a raw page to a visible-page
    -- ratio; nil when the book isn't open
    local coverage_ratio
    if opts.page_ratio_fn and coverage.end_page and coverage.end_page > 0 then
        coverage_ratio = opts.page_ratio_fn(coverage.end_page)
    end
    opts.coverage_ratio = coverage_ratio

    -- Full parse validation, not the shallow isJSON sniff: a prose main with an
    -- early brace must fall through to REPLACE, not select delta and fail after
    -- the API spend
    local delta_mode = false
    if opts.main_entry ~= nil then
        local parsed_main = XrayParser.parse(opts.main_entry.result or "")
        delta_mode = parsed_main ~= nil and not parsed_main.error
    end
    opts.delta_mode = delta_mode
    -- A main that covers the whole text (the complete track, or 100% reached)
    -- needs no placing: the merge may go with the book closed (B518)
    local main_whole = delta_mode and XrayMerge.coversWholeBook(opts.main_entry)

    local function warningsFor(target)
        local warnings = {}
        for _idx, gap in ipairs(coverage.gaps) do
            warnings[#warnings + 1] = T(
                _("No section X-Ray covers pp %1–%2 (between \"%3\" and \"%4\"). The merged result will have a gap there."),
                gap.from_page, gap.to_page, gap.after_label or "?", gap.before_label or "?")
        end
        if target == "main" then
            -- Base-coverage gap (device round 1 T4): a delta merge whose first
            -- selected section starts past the main's covered range leaves a hole
            -- no input fills — the between-inputs loop above can't see it
            local base_page = delta_mode and not main_whole
                and tonumber(opts.main_entry.progress_page) or nil
            local first_start = scoped[1] and tonumber(scoped[1].start_page)
            if base_page and first_start and first_start > base_page + 1 then
                warnings[#warnings + 1] = T(
                    _("The main X-Ray covers up to p. %1 and the first selected section starts at p. %2. The pages between are in neither."),
                    base_page, first_start)
            end
            -- Raising the main's claim / passing the reader = spoiler-relevant
            local main_p = delta_mode and tonumber(opts.main_entry.progress_decimal) or nil
            local reader_p = opts.reading_decimal
            if coverage_ratio and reader_p and coverage_ratio > reader_p + 0.01 then
                warnings[#warnings + 1] = T(
                    _("The selected sections cover text beyond your reading position (%1%). The merged X-Ray will contain later material."),
                    math.floor(reader_p * 100 + 0.5))
            elseif coverage_ratio and main_p and not main_whole
                and coverage_ratio > main_p + 0.01 then
                warnings[#warnings + 1] = T(
                    _("The selected sections extend beyond the X-Ray's current coverage (%1%). Its coverage claim will rise to %2%."),
                    math.floor(main_p * 100 + 0.5), math.floor(coverage_ratio * 100 + 0.5))
            end
        end
        return warnings
    end

    local main_row_text
    if delta_mode then
        main_row_text = _("Merge into main X-Ray")
    elseif opts.main_entry and opts.main_entry.result then
        -- Legacy/non-JSON main: its content can't be merged — this is a replace
        main_row_text = _("Replace main X-Ray (old version is archived)")
    else
        main_row_text = _("Create main X-Ray from sections")
    end
    local scope_preview = XrayMerge.combinedScope(sections)

    -- Into-main coverage requirements:
    -- DELTA: the floor holds the main's claim, so a missing ratio is safe when
    -- the main covers the whole text (complete-track, or 100% reached). Whether
    -- it covers every selected section is otherwise only known with the book
    -- open (B503): stored pages may come from different layouts, and a wrong
    -- yes would keep a claim below the text the merge adds.
    -- REPLACE/CREATE: the result's claim IS the ratio, never write a guess.
    local main_possible
    if delta_mode then
        main_possible = coverage_ratio ~= nil or main_whole
    else
        main_possible = coverage_ratio ~= nil
    end

    local dialog
    local rows = {}
    if main_possible then
        table.insert(rows, {{
            text = main_row_text,
            callback = function()
                UIManager:close(dialog)
                opts.target = "main"
                showWarningsThenRun(opts, warningsFor("main"))
            end,
        }})
    else
        table.insert(rows, {{
            text = T(_("%1 (open the book first)"), main_row_text),
            enabled = false,
        }})
    end
    if #sections >= 2 then
        table.insert(rows, {{
            text = T(_("Create combined section X-Ray (\"%1\")"), scope_preview.label or "?"),
            callback = function()
                UIManager:close(dialog)
                opts.target = "section"
                confirmSectionOverwriteThenRun(opts, warningsFor("section"))
            end,
        }})
    else
        table.insert(rows, {{
            text = _("Create combined section X-Ray: select at least two sections"),
            enabled = false,
        }})
    end
    table.insert(rows, {{
        text = _("Cancel"),
        callback = function() UIManager:close(dialog) end,
    }})
    dialog = ButtonDialog:new{
        title = T(_("AI merge %1 section X-Rays into…"), #sections),
        buttons = rows,
    }
    UIManager:show(dialog)
end

--- Entry point: section multi-select → target → warnings → run.
--- @param opts table { file (required), ui, plugin, configuration (required),
---   title, author, on_done(ok, err) — optional override for the default
---   notification }
function XrayMerge.startFlow(opts)
    local ActionCache = require("koassistant.artifacts.action_cache")
    local ButtonDialog = require("ui/widget/buttondialog")
    local InfoMessage = require("ui/widget/infomessage")
    local Notification = require("ui/widget/notification")
    local XrayParser = require("koassistant.xray.xray_parser")

    -- Cross-instance staleness: the consent gate below must see CURRENT
    -- settings (revoking text extraction in the other instance must bite here)
    if opts.plugin and opts.plugin.updateConfigFromSettings then
        opts.plugin:updateConfigFromSettings()
    end

    -- Identity fallback from the open document (browser callers pass these in;
    -- the popup path may not)
    if (not opts.title or opts.title == "") and opts.ui and opts.ui.doc_props
        and opts.ui.document and opts.ui.document.file == opts.file then
        opts.title = opts.ui.doc_props.display_title or opts.ui.doc_props.title
        if not opts.author or opts.author == "" then
            local authors = opts.ui.doc_props.authors or ""
            if authors:find("\n") then authors = authors:gsub("\n", ", ") end
            opts.author = authors
        end
    end

    local all_sections = ActionCache.getSections(opts.file, ActionCache.SECTION_PREFIXES.xray)
    local sections = {}
    for _idx, sec in ipairs(all_sections) do
        if sec.data and sec.data.result and XrayParser.isJSON(sec.data.result) then
            sections[#sections + 1] = sec
        end
    end
    if #sections == 0 then
        UIManager:show(InfoMessage:new{
            text = _("No section X-Rays to merge. Generate some first (X-Ray popup → Generate Section X-Ray)."),
            timeout = 3,
        })
        return
    end

    local main_entry = ActionCache.getXrayCache(opts.file)
    if main_entry and not main_entry.result then main_entry = nil end

    -- Read-gate parity: revoked text-extraction consent blocks re-sending
    -- text-derived artifacts (trusted provider bypasses, as everywhere)
    -- A Never on a kind these X-Rays were built from refuses here with the
    -- door; the kinds on Ask are asked once at the run (B395 slice 5)
    local gate_entries = {}
    for _idx, sec in ipairs(sections) do gate_entries[#gate_entries + 1] = sec.data end
    if main_entry then gate_entries[#gate_entries + 1] = main_entry end
    if XrayMerge.refusedBook(opts, { { file = opts.file, title = opts.title,
            entry = XrayMerge.unionStamps(gate_entries) } }, _("AI merge section X-Rays")) then
        return
    end

    -- Coverage context: a raw-page → flow-aware-ratio mapper (hidden-flow books
    -- would misclaim on raw ÷ raw-total math) + the reading position
    local page_ratio_fn, reading_decimal, section_range, open_doc
    if opts.ui and opts.ui.document
            and require("koassistant.storage.doc_settings").samePath(opts.ui.document.file, opts.file) then
        local doc = opts.ui.document
        local total = doc.info and doc.info.number_of_pages
        if total and total > 0 then
            local ContextExtractor = require("koassistant.request.context_extractor")
            -- Saved pages as they fall in this layout (B503): the main's
            -- coverage and the sections' ranges, wherever they were built,
            -- and the sections in this layout's text order (their stored
            -- pages may come from layouts that sort them otherwise)
            open_doc = doc
            main_entry = ContextExtractor.entryInLayout(doc, main_entry)
            section_range = function(data) return ActionCache.getSectionPageRange(data, doc) end
            local starts = {}
            for _idx, sec in ipairs(sections) do
                starts[sec] = section_range(sec.data) or sec.data.scope_start_page or 0
            end
            table.sort(sections, function(a, b) return starts[a] < starts[b] end)
            local visible_total = ContextExtractor.getFlowFingerprint(doc)
            if visible_total and visible_total > 0 then
                page_ratio_fn = function(page)
                    local vp = doc.getPageNumberInFlow and doc:getPageNumberInFlow(page) or page
                    return math.min(1.0, vp / visible_total)
                end
            else
                page_ratio_fn = function(page)
                    return math.min(1.0, page / total)
                end
            end
            local okp, progress = pcall(function()
                return ContextExtractor:new(opts.ui):getReadingProgress()
            end)
            reading_decimal = okp and progress and tonumber(progress.decimal) or nil
        end
    end

    -- Multi-select, ●/○ toggle rows rebuilt on tap (chip-manager idiom).
    -- Pre-selected = sections NOT yet folded into the main (T15) — re-merging
    -- already-merged content just re-sends it; already-merged rows stay
    -- pickable and are labeled. (No merged sections at all → everything
    -- selected, the original common case.)
    local selected = {}
    for _idx, sec in ipairs(sections) do
        if not sec.data.merged_to_main then selected[sec.key] = true end
    end

    local current_picker
    local showPicker  -- forward decl (toggle rows close-and-rebuild)
    showPicker = function()
        if current_picker then
            UIManager:close(current_picker)
            current_picker = nil
        end
        local dialog  -- declared BEFORE the rows so their closures capture it
        local rows = {}
        local count = 0
        for _idx, sec in ipairs(sections) do
            if selected[sec.key] then count = count + 1 end
        end
        for _idx, sec in ipairs(sections) do
            local captured = sec
            local detail_parts = {}
            local pages = sec.data.scope_page_summary
            if open_doc and sec.data.scope_start_xpointer then
                pages = ActionCache.reconvertPageSummary(sec.data, open_doc) or pages
            end
            if pages and pages ~= "" then detail_parts[#detail_parts + 1] = pages end
            if sec.data.merged_to_main then detail_parts[#detail_parts + 1] = _("merged") end
            local detail = #detail_parts > 0
                and (" (" .. table.concat(detail_parts, ", ") .. ")") or ""
            table.insert(rows, {{
                text = (selected[captured.key] and "● " or "○ ") .. (captured.label or "?") .. detail,
                align = "left",
                callback = function()
                    selected[captured.key] = not selected[captured.key] or nil
                    showPicker()
                end,
            }})
        end
        table.insert(rows, {{
            text = T(_("AI merge %1 selected…"), count),
            enabled = count >= 1,
            callback = function()
                UIManager:close(dialog)
                current_picker = nil
                local picked = {}
                for _idx, sec in ipairs(sections) do
                    if selected[sec.key] then picked[#picked + 1] = sec end
                end
                pickTargetThenRun({
                    file = opts.file,
                    ui = opts.ui,
                    plugin = opts.plugin,
                    configuration = opts.configuration,
                    sections = picked,
                    main_entry = main_entry,
                    page_ratio_fn = page_ratio_fn,
                    section_range = section_range,
                    reading_decimal = reading_decimal,
                    title = opts.title,
                    author = opts.author,
                    on_done = opts.on_done or function(ok, err, target)
                        if not ok then
                            UIManager:show(InfoMessage:new{
                                text = T(_("X-Ray merge failed: %1"), tostring(err or "unknown error")),
                                timeout = 4,
                            })
                            return
                        end
                        if target ~= "main" or #picked == 0 then
                            UIManager:show(Notification:new{
                                text = T(_("X-Ray merge complete (%1 sections)"), #picked),
                            })
                            return
                        end
                        -- Same landing rule as the cross-book fold (round 27):
                        -- this merge closed the X-Ray it ran from, so come back
                        -- to it carrying the merged sections
                        XrayMerge.reopenLive(opts)
                        -- Into-main merges keep their inputs by design (merge is
                        -- additive) — but ask, so the section list doesn't read
                        -- as "the merge didn't take" (device rounds 1+2, T5)
                        local ActionCache2 = require("koassistant.artifacts.action_cache")
                        local choice
                        choice = ButtonDialog:new{
                            title = T(_("Merged %1 section X-Rays into the main X-Ray."), #picked)
                                .. "\n" .. _("Keep them as separate section X-Rays too?"),
                            buttons = {
                                {{
                                    text = _("Keep sections"),
                                    callback = function() UIManager:close(choice) end,
                                }},
                                {{
                                    text = T(_("Delete the %1 merged sections"), #picked),
                                    callback = function()
                                        UIManager:close(choice)
                                        for _idx, sec in ipairs(picked) do
                                            ActionCache2.clear(opts.file, sec.key)
                                        end
                                        UIManager:show(Notification:new{
                                            text = T(_("Deleted %1 section X-Rays."), #picked),
                                        })
                                    end,
                                }},
                            },
                        }
                        UIManager:show(choice)
                    end,
                })
            end,
        }})
        table.insert(rows, {{
            text = _("Cancel"),
            callback = function()
                UIManager:close(dialog)
                current_picker = nil
            end,
        }})
        dialog = ButtonDialog:new{
            title = _("AI merge section X-Rays: pick inputs"),
            buttons = rows,
        }
        current_picker = dialog
        UIManager:show(dialog)
    end
    -- Flow is really starting — retire the caller's browser only now, so the
    -- no-sections/consent-blocked early returns above leave it intact (T11)
    if opts.close_browser then opts.close_browser() end
    showPicker()
    logger.dbg("KOAssistant XrayMerge: flow started with", #sections, "sections for", opts.file)
end

-- ==================== Cross-book merge (item 43, #90 v1) ====================
-- Merge, not connect: the source book's X-Ray is read-only INPUT (originals
-- stay untouched and browsable); the result lands in the TARGET book's main
-- via the ordinary delta write-back (the outgoing main is ring-archived —
-- undoable from All versions). No series backend: the picker lists every book
-- the artifact index knows with a JSON main X-Ray; manual pick covers series,
-- same-author, and thematic cases alike. A standalone library-level series
-- artifact stays deferred (§5 decisions 6/7).

--- Run the cross-book merge headlessly and write the result into the target.
--- @param opts table { file (target), ui, plugin, configuration, title, author
---   (TARGET identity for the headless config), main_entry (target JSON main),
---   source = { file, title, author, entry }, on_done(ok, err) }
function XrayMerge.executeCrossBook(opts)
    local Dialogs = require("koassistant.ui.dialogs")
    local ActionCache = require("koassistant.artifacts.action_cache")
    local WriteBack = require("koassistant.xray.artifact_writeback")
    local XrayParser = require("koassistant.xray.xray_parser")

    local main_entry = opts.main_entry
    local parsed_main = XrayParser.parse(main_entry.result or "")
    if not parsed_main or parsed_main.error then
        if opts.on_done then opts.on_done(false, "main X-Ray is not valid JSON") end
        return
    end
    -- The carried names listed are the ones the other book's X-Ray mentions (B394 slice 4)
    local x_cfg = opts.configuration or {}
    local entity_index = XrayParser.buildEntityIndex(parsed_main,
        { text = XrayMerge.buildCrossBookInputsBlock(opts.source),
          exclude_files = XrayMerge.neverSourceFiles(parsed_main, x_cfg.features,
              x_cfg.provider or x_cfg.default_provider, opts.ui) }) or ""
    local never_pairs = ActionCache.getNeverMergePairs(opts.file)
    local prompt_text, payload = XrayMerge.buildCrossBookPrompt(
        main_entry, entity_index, never_pairs, opts.source)

    -- Synthetic internal action — same shape as the section merge
    local action = {
        id = "xray_cross_merge",
        text = _("Merge X-Ray from another book"),
        context = "book",
        prompt = prompt_text,
        storage_key = "__SKIP__",
        enable_web_search = false,
        skip_spoiler = true,  -- mechanical JSON merge; a posture nudge could drop entries
        -- No reasoning pin (series-identity round, 2026-08-06): cross-book
        -- entity resolution is a judgment task — the extraction action's
        -- latency "off" would run it at the floor (Gemini 3.x can't disable,
        -- "off" resolves to minimal). nil = stance/model default.
        api_params = XrayMerge.API_PARAMS,
        builtin = true,
    }
    if opts.plugin and opts.plugin.updateConfigFromSettings then
        opts.plugin:updateConfigFromSettings()
    end
    local config, bm = XrayMerge.buildHeadlessConfig(opts, payload)
    local plugin_ref = opts.plugin
    local file = opts.file
    local source = opts.source
    -- One line per fold at DISPATCH (round 26): a fold could previously only be
    -- traced by reconstructing it from picker and extraction lines
    logger.dbg("KOAssistant XrayMerge: folding", (source and source.title) or "?",
        "into", opts.title or file)
    Dialogs.executeActionForResult(action, config.features.book_context or "", opts.ui, config,
        opts.plugin, bm,
        function(result, meta_or_err)
            if not result then
                -- Round 26: a fold that never came back logged NOTHING between
                -- its request body and the next UI event, so a silent failure
                -- was indistinguishable from "the fold ran and changed nothing"
                logger.info("KOAssistant XrayMerge: fold into", file, "FAILED:",
                    tostring(meta_or_err or "no response"))
                if opts.on_done then opts.on_done(false, tostring(meta_or_err or "no response")) end
                return
            end
            local model_name = type(meta_or_err) == "table"
                and meta_or_err.model ~= "" and meta_or_err.model or nil
            local used_reasoning = type(meta_or_err) == "table"
                and meta_or_err.used_reasoning or nil
            local union = XrayMerge.unionInputMeta({ source.entry })
            -- Item 49 transitive carry: the transform appends carried ancestor
            -- labels to THIS table (reconcileXrayMeta reads it after the
            -- transform has run inside parseXrayAnswer)
            local wb_ledger = XrayMerge.unionMergedFrom(
                XrayMerge.ledgerOf(main_entry),
                { file = source.file, title = source.title,
                  source_ts = source.entry and source.entry.timestamp },
                source.entry and XrayMerge.ledgerOf(source.entry))
            local wb_meta = {
                model = model_name,
                used_reasoning = used_reasoning,
                used_book_text = union.used_book_text,
                used_highlights = union.used_highlights,
                producer = "book_merge",
                -- The ledger is the truth; the string is its display form, kept
                -- in sync here AND after the transform appends carried labels
                merged_from = wb_ledger,
                merged_from_books = XrayMerge.provenanceString(wb_ledger),
            }
            local source_parsed = XrayParser.parse(
                (source.entry and source.entry.result) or "")
            -- Round 28: an EMPTY delta is the correct answer for two books that
            -- share nothing — the prompt asks for exactly that. It is not a
            -- failed merge, and reporting it as one ("response is not a valid
            -- X-Ray JSON structure", device report) reads as a bug in the
            -- plugin rather than an answer about the books. Nothing is written.
            if XrayParser.isEmptyDelta(result) then
                logger.info("KOAssistant XrayMerge: fold into", file,
                    "found NO OVERLAP with", (source and source.title) or "?")
                if opts.on_done then opts.on_done(true, nil, { no_overlap = true }) end
                return
            end
            local merge_stats = {}
            local ok, res_or_err = WriteBack.applyXray({
                document_path = file,
                answer = result,
                base = main_entry,
                base_entry = main_entry,
                -- Item 44: background attaches mechanically; existing entries
                -- can never be replaced or shortened by this merge. Item 49:
                -- the source's own ancestor background carries over with
                -- original labels (chained merges no longer lose Vol 1).
                -- Round 28: file paths ride as the identity keys.
                transform = XrayMerge.crossBookTransform(source.title,
                    source_parsed, bm.title, wb_meta, source.file, file, merge_stats),
                -- Cross-book knowledge claims NO target pages: progress stays
                -- the base's (floor guard) and coverage_spans union base-only
                -- (slice-1 reconcile — the new pass carries none)
                progress_decimal = tonumber(main_entry.progress_decimal) or 0,
                meta = wb_meta,
                features = config.features,
                refresh_fn = function()
                    if plugin_ref then
                        plugin_ref._file_dialog_row_cache = { file = nil, rows = nil }
                        if plugin_ref._refreshXrayAutoState and plugin_ref.ui
                            and plugin_ref.ui.document and plugin_ref.ui.document.file == file then
                            plugin_ref:_refreshXrayAutoState()
                        end
                    end
                    -- An X-Ray browser open on this book holds a pre-merge
                    -- snapshot (round 25) — reload it in place
                    require("koassistant.xray.xray_browser"):reloadLiveMain(file)
                end,
            })
            -- A well-formed delta that touched nothing is the same answer as an
            -- empty one — say so instead of claiming a merge happened
            local touched_nothing = ok
                and (merge_stats.applied or 0) == 0 and (merge_stats.arrived or 0) == 0
            if opts.on_done then
                opts.on_done(ok, not ok and res_or_err or nil,
                    touched_nothing and { no_overlap = true, wrote = true } or nil)
            end
        end)
end

--- Post-merge duplicate check (series-identity round, 2026-08-06): run the
--- mechanical duplicate scan on a freshly merged artifact and offer the
--- dedup flow when it finds pairs — a fold that imported a differently-named
--- recurring entity leaves exactly the near-duplicates the scan catches
--- (same name / shared alias / contained name). Description-level twins with
--- no name overlap stay the reader's call. Silent when clean; attended merge
--- paths only.
--- @param opts table { file, ui, plugin, configuration, title, author }
function XrayMerge.maybeOfferDedupScan(opts)
    local ActionCache = require("koassistant.artifacts.action_cache")
    local XrayParser = require("koassistant.xray.xray_parser")
    local XrayDedup = require("koassistant.xray.xray_dedup")
    local entry = ActionCache.getXrayCache(opts.file)
    if not (entry and entry.result and XrayParser.isJSON(entry.result)) then return end
    local data = XrayParser.parse(entry.result)
    if not data or data.error then return end
    local user_aliases = ActionCache.getUserAliases(opts.file)
    if next(user_aliases) then
        XrayParser.mergeUserAliases(data, user_aliases)
    end
    local found = XrayDedup.findDuplicates(data,
        ActionCache.neverMergePairsFrom(user_aliases))
    if #found == 0 then return end
    local ButtonDialog = require("ui/widget/buttondialog")
    local dialog
    dialog = ButtonDialog:new{
        title = T(_("The merge may have left %1 duplicate entit(y/ies), the same figure under two names. Review them?"), #found),
        buttons = {
            {{ text = _("Review duplicates…"), callback = function()
                UIManager:close(dialog)
                require("koassistant.xray.xray_dedup").startFlow({
                    file = opts.file, ui = opts.ui, plugin = opts.plugin,
                    configuration = opts.configuration,
                    title = opts.title, author = opts.author,
                })
            end }},
            {{ text = _("Not now"), callback = function() UIManager:close(dialog) end }},
        },
    }
    UIManager:show(dialog)
end

--- Run the organic series chain headlessly: chain[1]→chain[2], 2→3, …
--- (oldest first, the receiving book last) — each hop re-reads BOTH sides
--- fresh (the previous hop just rewrote the source), re-checks consent, and
--- stops loudly naming the hop on failure. Shared by the merge picker's
--- fold-all row and the post-create fold offer (carry layer 3(ii)).
--- @param opts table { chain = ordered {file, title, author, entry} rows,
---   features, provider, ui, plugin, configuration,
---   close_browser (called once the preflight sweep passes), on_done(ok) }
function XrayMerge.runSeriesChain(opts)
    local ActionCache = require("koassistant.artifacts.action_cache")
    local XrayParser = require("koassistant.xray.xray_parser")
    local InfoMessage = require("ui/widget/infomessage")
    local Notification = require("ui/widget/notification")
    local chain = opts.chain or {}
    local n_merges = #chain - 1
    if n_merges < 1 then return end
    local skipped = 0
    local no_overlap_n = 0
    -- Preflight consent sweep (2026-08-05): fail BEFORE the first request
    -- names the blocking book — never stop a paid run midway on a knowable
    -- condition. The per-step checks stay (settings can change mid-run).
    for _cidx, member in ipairs(chain) do
        if not XrayMerge.consentOk({ member.entry }, opts.features, opts.provider, member.file, opts.ui) then
            UIManager:show(InfoMessage:new{
                text = T(_("Cannot start: text-extraction consent is missing for \"%1\"."), member.title),
                timeout = 5,
            })
            return
        end
    end
    if opts.close_browser then opts.close_browser() end
    local function step(idx)
        if idx > n_merges then
            local done_text = skipped > 0
                and T(_("AI merge of the series done: %1 merges, %2 already done."),
                    n_merges - skipped, skipped)
                or T(_("AI merge of the series done: %1 merges."), n_merges)
            if no_overlap_n > 0 then
                done_text = done_text .. " "
                    .. T(_("%1 found nothing to carry over."), no_overlap_n)
            end
            UIManager:show(Notification:new{ text = done_text })
            -- Post-merge duplicate check on the final receiving book (the
            -- chain is always attended); earlier hops go unchecked — one
            -- dialog per chain, and the reader can scan any volume manually
            local last = chain[#chain]
            -- The chain closed the browser at step 1 (round 27): land on the
            -- final receiving book's X-Ray, which is the one it was run from
            XrayMerge.reopenLive({
                file = last.file, title = last.title, author = last.author,
                plugin = opts.plugin, reopen_live = opts.reopen_live,
            })
            XrayMerge.maybeOfferDedupScan({
                file = last.file, title = last.title, author = last.author,
                ui = opts.ui, plugin = opts.plugin, configuration = opts.configuration,
            })
            if opts.on_done then opts.on_done(true) end
            return
        end
        local src_c = chain[idx]
        local tgt_c = chain[idx + 1]
        -- Both re-read fresh: the previous hop rewrote src
        local fresh_src = ActionCache.getXrayCache(src_c.file)
        local fresh_tgt = ActionCache.getXrayCache(tgt_c.file)
        if not (fresh_src and fresh_src.result and XrayParser.isJSON(fresh_src.result))
            or not (fresh_tgt and fresh_tgt.result and XrayParser.isJSON(fresh_tgt.result)) then
            UIManager:show(InfoMessage:new{
                text = T(_("Stopped at \"%1\": its X-Ray is no longer available."),
                    (fresh_src and fresh_src.result) and tgt_c.title or src_c.title),
                timeout = 4,
            })
            return
        end
        if not XrayMerge.consentOk({ fresh_src }, opts.features, opts.provider, src_c.file, opts.ui)
            or not XrayMerge.consentOk({ fresh_tgt }, opts.features, opts.provider, tgt_c.file, opts.ui) then
            UIManager:show(InfoMessage:new{
                text = T(_("Stopped at \"%1\": text-extraction consent is missing for it."), src_c.title),
                timeout = 5,
            })
            return
        end
        -- Round 28: a hop whose fold is already recorded in the target's
        -- provenance is skipped (opt-in — the confirm's "Re-run all" clears
        -- it). Checked fresh from disk at hop time, same as everything else.
        -- A STALE hop is not skippable: the source's X-Ray has been rebuilt
        -- since this fold, so what the target carries is genuinely out of date.
        -- "unknown" (legacy/transitive, no version recorded) counts as done —
        -- see the ledger note above.
        local hop_status = XrayMerge.foldStatus(fresh_tgt,
            { title = src_c.title, file = src_c.file, timestamp = fresh_src.timestamp })
        if opts.skip_done and (hop_status == "current" or hop_status == "unknown") then
            skipped = skipped + 1
            logger.dbg("KOAssistant XrayMerge: chain hop", idx, "skipped -",
                src_c.title, "already folded into", tgt_c.title)
            return step(idx + 1)
        end
        UIManager:show(Notification:new{
            text = T(_("AI merge %1 of %2: %3 into %4"), idx, n_merges,
                src_c.title, tgt_c.title),
        })
        XrayMerge.executeCrossBook({
            file = tgt_c.file, ui = opts.ui, plugin = opts.plugin,
            configuration = opts.configuration,
            title = tgt_c.title, author = tgt_c.author,
            main_entry = fresh_tgt,
            source = { file = src_c.file, title = src_c.title,
                author = src_c.author, entry = fresh_src },
            on_done = function(ok, err, outcome)
                if ok then
                    -- A hop that found nothing is not a failure — it continues
                    -- the chain, but the final tally says so (round 28):
                    -- consecutive volumes sharing nothing is worth noticing
                    if outcome and outcome.no_overlap then
                        no_overlap_n = no_overlap_n + 1
                    end
                    step(idx + 1)
                else
                    UIManager:show(InfoMessage:new{
                        text = T(_("Stopped at \"%1\" into \"%2\": %3"), src_c.title,
                            tgt_c.title, tostring(err or "unknown error")),
                        timeout = 5,
                    })
                end
            end,
        })
    end
    step(1)
end

--- PROJECT fan-in (round 30): fold every other member's X-Ray into THIS book,
--- one after another. The order-free counterpart to runSeriesChain — a project
--- group has no "earlier feeds later", so there is no chain to walk and no
--- spoiler direction to warn about; knowledge flows inward to the book the
--- reader is actually holding, and the other members are left untouched.
---
--- Deliberately N-1 merges into ONE target, never N² across the group: the
--- 2026-08-07 sketch established that copying a project's shared concepts into
--- every member would reintroduce the item-44 erosion one level up (each copy
--- drifts independently). The symmetric always-on version is read-time
--- resolution, which is a separate, unbuilt idea; this is the explicit one-off.
--- @param opts table { file, title, author, ui, plugin, configuration,
---   sources = ordered {file, title, author, entry} rows, main_entry,
---   skip_done, close_browser, reopen_live, on_done }
function XrayMerge.runFanIn(opts)
    local ActionCache = require("koassistant.artifacts.action_cache")
    local XrayParser = require("koassistant.xray.xray_parser")
    local InfoMessage = require("ui/widget/infomessage")
    local Notification = require("ui/widget/notification")
    local sources = opts.sources or {}
    local n_total = #sources
    if n_total < 1 then return end
    -- Separate tallies: conflating them makes the closing line lie (a run where
    -- every fold legitimately found nothing must not read "Folded in 0 book(s)"
    -- with no explanation, and a source whose X-Ray vanished is not "done")
    local merged, no_overlap_n, done_n, unavailable_n = 0, 0, 0, 0
    -- Consent preflight on the TARGET only: it is the one book whose failure
    -- makes the whole run pointless. A SOURCE that is not shareable is skipped
    -- per book below instead — unlike a chain, a fan-in has no dependency
    -- between steps, so one denied book must not cost the reader the other N-1.
    if not XrayMerge.consentOk({ opts.main_entry }, opts.features, opts.provider,
            opts.file, opts.ui) then
        UIManager:show(InfoMessage:new{
            text = T(_("Cannot start: text-extraction consent is missing for \"%1\"."),
                opts.title or "?"),
            timeout = 5,
        })
        return
    end
    if opts.close_browser then opts.close_browser() end
    local function finish()
        local parts = { T(_("AI merged %1 book(s)."), merged) }
        if no_overlap_n > 0 then
            parts[#parts + 1] = T(_("%1 shared nothing."), no_overlap_n)
        end
        if done_n > 0 then
            parts[#parts + 1] = T(_("%1 already done."), done_n)
        end
        if unavailable_n > 0 then
            parts[#parts + 1] = T(_("%1 skipped (no X-Ray or not shareable)."), unavailable_n)
        end
        UIManager:show(Notification:new{ text = table.concat(parts, " ") })
        XrayMerge.reopenLive(opts)
        XrayMerge.maybeOfferDedupScan(opts)
        if opts.on_done then opts.on_done(true) end
    end
    local function stop(text)
        UIManager:show(InfoMessage:new{ text = text, timeout = 5 })
        -- A partially merged book must still be reachable: land back on it
        -- rather than leaving the reader on a closed browser
        XrayMerge.reopenLive(opts)
        if opts.on_done then opts.on_done(false, text) end
    end
    local function step(idx)
        if idx > n_total then return finish() end
        local src = sources[idx]
        -- Both sides re-read fresh: the previous fold rewrote the target
        local fresh_tgt = ActionCache.getXrayCache(opts.file)
        local fresh_src = ActionCache.getXrayCache(src.file)
        if not (fresh_tgt and fresh_tgt.result and XrayParser.isJSON(fresh_tgt.result)) then
            return stop(T(_("Stopped: the X-Ray of \"%1\" is no longer available."),
                opts.title or "?"))
        end
        -- Re-checked every step, not just at the start: settings can change
        -- mid-run, and the target's gate is the one that must stop the run
        if not XrayMerge.consentOk({ fresh_tgt }, opts.features, opts.provider,
                opts.file, opts.ui) then
            return stop(T(_("Stopped: text-extraction consent is missing for \"%1\"."),
                opts.title or "?"))
        end
        if not (fresh_src and fresh_src.result and XrayParser.isJSON(fresh_src.result))
            or not XrayMerge.consentOk({ fresh_src }, opts.features, opts.provider,
                src.file, opts.ui) then
            unavailable_n = unavailable_n + 1
            return step(idx + 1)
        end
        -- Stale sources re-run here too (see the chain's note)
        local src_status = XrayMerge.foldStatus(fresh_tgt,
            { title = src.title, file = src.file, timestamp = fresh_src.timestamp })
        if opts.skip_done and (src_status == "current" or src_status == "unknown") then
            done_n = done_n + 1
            logger.dbg("KOAssistant XrayMerge: fan-in skipped", src.title, "- already folded")
            return step(idx + 1)
        end
        UIManager:show(Notification:new{
            text = T(_("AI merge %1 of %2: %3"), idx, n_total, src.title),
        })
        XrayMerge.executeCrossBook({
            file = opts.file, ui = opts.ui, plugin = opts.plugin,
            configuration = opts.configuration,
            title = opts.title, author = opts.author,
            main_entry = fresh_tgt,
            source = { file = src.file, title = src.title,
                author = src.author, entry = fresh_src },
            on_done = function(ok, err, outcome)
                if ok then
                    if outcome and outcome.no_overlap then
                        no_overlap_n = no_overlap_n + 1
                    else
                        merged = merged + 1
                    end
                    step(idx + 1)
                else
                    stop(T(_("Stopped at \"%1\": %2"), src.title,
                        tostring(err or "unknown error")))
                end
            end,
        })
    end
    step(1)
end

--- Carry layer 3(iii), the PRE-create fold ask (maintainer decision
--- 2026-08-06, replacing the post-create offer): BEFORE an attended fresh
--- main X-Ray of a grouped book whose previous book has an X-Ray, ask once —
--- just this book / merge when done / bring the chain up to date. Accepting
--- auto-runs the AI merge when the create lands (runPostCreateFold).
--- Declining declines the PAID merge only (B394 slice 3): the free carry
--- runs either way (the seed, and the naming canon in the create request,
--- which the caller injects whatever the answer), and the dialog says so.
--- When the previous book has no X-Ray, no dialog — the post-create gap note
--- covers that case. Cancel aborts the create.
--- @param opts table { file, ui, configuration }
--- @param proceed function(mode) mode = "single"|"chain"|nil (declined) |
---   "cancel" (round 28: abort the create — the caller must NOT send)
--- @return boolean asked False when no dialog applies (proceed NOT called —
---   the caller continues synchronously)
function XrayMerge.preCreateFoldAsk(opts, proceed)
    local BookGroups = require("koassistant.books.book_groups")
    local preds, group = BookGroups.predecessorsOf(opts.file)
    if #preds == 0 then return false end
    local ActionCache = require("koassistant.artifacts.action_cache")
    local XrayParser = require("koassistant.xray.xray_parser")
    local nearest = preds[#preds]
    local nearest_entry = ActionCache.getXrayCache(nearest)
    if not (nearest_entry and nearest_entry.result and XrayParser.isJSON(nearest_entry.result)) then
        return false
    end
    local ButtonDialog = require("ui/widget/buttondialog")
    local nearest_title = BookGroups.displayTitle(nearest, opts.ui)
    -- The previous book's own X-Rayed predecessors vs its provenance:
    -- anything missing means its X-Ray does not yet carry those volumes
    local earlier_titles = {}
    for i = 1, #preds - 1 do
        local e = ActionCache.getXrayCache(preds[i])
        if e and e.result and XrayParser.isJSON(e.result) then
            earlier_titles[#earlier_titles + 1] = BookGroups.displayTitle(preds[i], opts.ui)
        end
    end
    local missing = XrayMerge.provenanceGap(earlier_titles,
        XrayMerge.ledgerOf(nearest_entry))
    -- B394 slice 3: the old wording ("Fold its knowledge into this book's
    -- X-Ray once it is built?") read as THE way to carry knowledge, while the
    -- free carry already does most of it. Say what happens on its own first,
    -- then what the paid merge adds; the free choice leads.
    local ask_text = T(_("\"%1\" (the previous book in %2) has an X-Ray. What it knows is carried into this book's X-Ray on its own, at no cost: its names stay linked, and what it says about a person, place or term is attached when this book has that entry."),
            nearest_title, (group and groupName(group)) or _("this group"))
        .. "\n\n"
        .. T(_("Also run an AI merge when this X-Ray is done? It links names that differ between the two books and writes what \"%1\" adds to the entries they share. The two X-Rays are sent, not the books."),
            nearest_title)
    if #missing > 0 then
        ask_text = ask_text .. "\n"
            .. T(_("Note: \"%1\" has not been merged with its own earlier book(s) yet (%2), so a merge with it alone would not bring their knowledge."),
                nearest_title, table.concat(missing, ", "))
    end
    local ask
    local buttons = {
        {{ text = _("Just this book"), callback = function()
            UIManager:close(ask)
            proceed(nil)
        end }},
        {{ text = _("Also AI merge when done (1 request)"), callback = function()
            UIManager:close(ask)
            proceed("single")
        end }},
    }
    if #missing > 0 and #earlier_titles >= 1 then
        buttons[#buttons + 1] = {{
            text = T(_("AI merge the series (%1 requests)"), #earlier_titles + 1),
            callback = function()
                UIManager:close(ask)
                proceed("chain")
            end,
        }}
    end
    -- Round 28 (device report): with the dialog non-dismissable and every
    -- button STARTING the X-Ray, there was no way out — the reader had to pick
    -- one and then cancel the request it had already sent. Cancel aborts the
    -- create itself, which is what the outside tap used to do.
    buttons[#buttons + 1] = {{ text = _("Cancel"), callback = function()
        UIManager:close(ask)
        proceed("cancel")
    end }}
    -- Not dismissable: this ask gates the create itself, so a tap outside would
    -- silently abandon the X-Ray with no message (Cancel is the explicit exit,
    -- "Just this book" the explicit opt-out of the paid merge)
    ask = ButtonDialog:new{ title = ask_text, buttons = buttons, dismissable = false }
    UIManager:show(ask)
    return true
end

--- Execute the accepted pre-create fold once the create landed (carry layer
--- 3(iii), second half): "single" folds the previous book in, "chain" runs
--- the organic chain ending at this book. Everything is re-read fresh from
--- disk — the create just wrote the target, and the ask ran one request ago.
--- Ends with the post-merge duplicate check (single here; the chain nudges
--- from runSeriesChain itself).
--- @param opts table { file, title, author, ui, plugin, configuration,
---   mode = "single"|"chain" }
function XrayMerge.runPostCreateFold(opts)
    local BookGroups = require("koassistant.books.book_groups")
    local ActionCache = require("koassistant.artifacts.action_cache")
    local XrayParser = require("koassistant.xray.xray_parser")
    local InfoMessage = require("ui/widget/infomessage")
    local Notification = require("ui/widget/notification")
    local preds = BookGroups.predecessorsOf(opts.file)
    if #preds == 0 then return end
    local main_entry = ActionCache.getXrayCache(opts.file)
    if not (main_entry and main_entry.result and XrayParser.isJSON(main_entry.result)) then return end
    local nearest = preds[#preds]
    local nearest_entry = ActionCache.getXrayCache(nearest)
    if not (nearest_entry and nearest_entry.result and XrayParser.isJSON(nearest_entry.result)) then return end
    local nearest_title = BookGroups.displayTitle(nearest, opts.ui)
    local provider = (opts.configuration
        and (opts.configuration.provider or opts.configuration.default_provider))
    if opts.mode == "chain" then
        local chain = {}
        for i = 1, #preds - 1 do
            local e = ActionCache.getXrayCache(preds[i])
            if e and e.result and XrayParser.isJSON(e.result) then
                chain[#chain + 1] = { file = preds[i],
                    title = BookGroups.displayTitle(preds[i], opts.ui), entry = e }
            end
        end
        chain[#chain + 1] = { file = nearest, title = nearest_title, entry = nearest_entry }
        chain[#chain + 1] = { file = opts.file, title = opts.title,
            author = opts.author, entry = main_entry }
        -- The question before the first request (B395 slice 5)
        XrayMerge.withDataAccess(opts, chain, _("AI merge the series"), function(run_cfg)
            XrayMerge.runSeriesChain({
                chain = chain, features = run_cfg.features, provider = provider,
                ui = opts.ui, plugin = opts.plugin, configuration = run_cfg,
                -- Round 28: hops that already ran are skipped — the ask said
                -- "bring the series up to date", not "redo it"
                skip_done = true,
            })
        end)
        return
    end
    -- The question before the request (B395 slice 5): both X-Rays' kinds, once
    XrayMerge.withDataAccess(opts,
        { { file = nearest, title = nearest_title, entry = nearest_entry },
          { file = opts.file, title = opts.title, entry = main_entry } },
        _("AI merge"), function(run_cfg)
    UIManager:show(Notification:new{ text = T(_("AI merge with \"%1\"…"), nearest_title) })
    XrayMerge.executeCrossBook({
        file = opts.file, ui = opts.ui, plugin = opts.plugin,
        configuration = run_cfg,
        title = opts.title, author = opts.author,
        main_entry = main_entry,
        source = { file = nearest, title = nearest_title, entry = nearest_entry },
        on_done = function(ok, err, outcome)
            if ok and outcome and outcome.no_overlap then
                UIManager:show(InfoMessage:new{
                    text = T(_("Nothing to merge: \"%1\" and this book share no people, places or concepts."), nearest_title),
                    timeout = 4,
                })
            elseif ok then
                UIManager:show(Notification:new{
                    text = T(_("AI merged \"%1\" into this book's X-Ray."), nearest_title),
                })
                XrayMerge.maybeOfferDedupScan(opts)
            else
                UIManager:show(InfoMessage:new{
                    text = T(_("AI merge failed: %1"), tostring(err or "unknown error")),
                    timeout = 5,
                })
            end
        end,
    })
    end)
end

--- Land back on the live X-Ray after a fold that closed the browser it ran
--- from (round 27 device report: "after folding in, the x ray closes -- it
--- should probably just refresh"). Opt-in via opts.reopen_live, set by the
--- X-Ray browser's own entries; the artifact-browser and popup routes, where
--- no X-Ray view was open, are unaffected. No-ops without a plugin handle.
--- @param opts table { file, plugin, reopen_live, title, author }
function XrayMerge.reopenLive(opts)
    if not (opts and opts.reopen_live and opts.plugin and opts.plugin._showLiveXray) then
        return
    end
    opts.plugin:_showLiveXray(opts.file, {
        book_title = opts.title, book_author = opts.author,
    })
end

--- The one grouped-create case the pre-create ask cannot cover: the previous
--- book has no X-Ray at all. A post-create note names the gap (informational,
--- never a question — there is nothing to run).
--- @param opts table { file, ui }
function XrayMerge.maybeNotePredecessorGap(opts)
    local BookGroups = require("koassistant.books.book_groups")
    local preds, group = BookGroups.predecessorsOf(opts.file)
    if #preds == 0 then return end
    local ActionCache = require("koassistant.artifacts.action_cache")
    local XrayParser = require("koassistant.xray.xray_parser")
    local nearest = preds[#preds]
    local nearest_entry = ActionCache.getXrayCache(nearest)
    if nearest_entry and nearest_entry.result and XrayParser.isJSON(nearest_entry.result) then
        return
    end
    UIManager:show(require("ui/widget/infomessage"):new{
        text = T(_("\"%1\" (the previous book in %2) has no X-Ray yet. Build one there to carry its knowledge forward."),
            BookGroups.displayTitle(nearest, opts.ui), (group and groupName(group)) or _("this group")),
        timeout = 6,
    })
end

--- The project fold's confirm (round 30, fan-in): every other member's X-Ray
--- is merged INTO one book. One confirm for the merge picker's row and the
--- direct entries (B394 slice 1). It names what the run costs first.
--- @param opts table startCrossBookFlow's opts (file = the receiving book)
--- @param mates table The other members WITH an X-Ray: { file, title, author, entry }
--- @param main_entry table opts.file's X-Ray entry
--- @param tgt_group table The project group
--- @param back function|nil "Back" and the tap outside (nil = just close)
local function confirmFanIn(opts, mates, main_entry, tgt_group, back)
    local ActionCache = require("koassistant.artifacts.action_cache")
    local ButtonDialog = require("ui/widget/buttondialog")
    local features = (opts.configuration and opts.configuration.features) or {}
    local provider = (opts.configuration
        and (opts.configuration.provider or opts.configuration.default_provider))
    local done_n, stale_n = 0, 0
    for _idx, m in ipairs(mates) do
        local st = XrayMerge.foldStatus(main_entry, { title = m.title,
            file = m.file, timestamp = m.entry and m.entry.timestamp })
        if st == "stale" then stale_n = stale_n + 1
        elseif st ~= "none" then done_n = done_n + 1 end
    end
    -- Members with no X-Ray of their own
    local missing_n = math.max(0, (#tgt_group.books - 1) - #mates)
    local confirm_title = T(_("AI merge %1 other book(s) of \"%2\" into this book's X-Ray?"),
            #mates, groupName(tgt_group))
        .. "\n" .. _("One request per book; the X-Rays are sent, not the books. Knowledge flows INTO this book only: the other books are not changed.")
    -- Undo is per-STEP here, and every step archives the SAME book: a long
    -- fan-in can push the pre-run version out of the ring entirely, so
    -- promising "undo from All versions" the way the series chain does would
    -- be a lie (there each hop archives a different book).
    local ring = ActionCache.checkpointLimitFromFeatures(features)
    if ring > 0 and #mates >= ring then
        confirm_title = confirm_title .. "\n"
            .. T(_("Note: each step archives this X-Ray, and only %1 versions are kept. After this run the version from before it may no longer be in the list."), ring)
    else
        confirm_title = confirm_title .. "\n"
            .. _("Each step archives this X-Ray first, so the run can be undone from All versions.")
    end
    if missing_n > 0 then
        confirm_title = confirm_title .. "\n"
            .. T(_("Skipped: %1 group member(s) have no X-Ray yet."), missing_n)
    end
    if done_n > 0 then
        confirm_title = confirm_title .. "\n"
            .. T(_("%1 of them are already merged in and up to date: those are skipped."), done_n)
    end
    if stale_n > 0 then
        confirm_title = confirm_title .. "\n"
            .. T(_("%1 of them were merged in before, but their X-Rays have changed since: those run again."), stale_n)
    end
    local function launch(skip_done)
        -- The question before the first request (B395 slice 5): the target
        -- and every member, their X-Rays' kinds, asked once
        local books = { { file = opts.file, title = opts.title, entry = main_entry } }
        for _idx, m in ipairs(mates) do books[#books + 1] = m end
        XrayMerge.withDataAccess(opts, books, _("AI merge the group"), function(run_cfg)
            XrayMerge.runFanIn({
                file = opts.file, title = opts.title, author = opts.author,
                ui = opts.ui, plugin = opts.plugin,
                configuration = run_cfg,
                features = run_cfg.features, provider = provider,
                main_entry = main_entry, sources = mates,
                skip_done = skip_done,
                close_browser = opts.close_browser,
                reopen_live = opts.reopen_live,
                on_done = opts.on_done,
            })
        end)
    end
    local confirm
    local btns = {}
    if done_n > 0 and done_n < #mates then
        btns[#btns + 1] = {{ text = T(_("AI merge new only: %1 request(s)"), #mates - done_n),
            callback = function() UIManager:close(confirm) launch(true) end }}
    end
    btns[#btns + 1] = {{ text = T(_("AI merge all: %1 request(s)"), #mates),
        callback = function() UIManager:close(confirm) launch(false) end }}
    btns[#btns + 1] = {{ text = back and _("Back") or _("Cancel"), callback = function()
        UIManager:close(confirm)
        if back then back() end
    end }}
    confirm = ButtonDialog:new{ title = confirm_title, buttons = btns,
        tap_close_callback = back,
    }
    UIManager:show(confirm)
end

--- The project fold, opened directly (B394 slice 1): the X-Ray popup's and the
--- browser's "Fold the group into this book…" rows and the hub's project row
--- (after its target pick). Reads only the group's own members.
--- @param opts table startCrossBookFlow's opts; file = the receiving book
--- @return boolean shown False when a message explained why not
function XrayMerge.startFanInFlow(opts)
    local ActionCache = require("koassistant.artifacts.action_cache")
    local BookGroups = require("koassistant.books.book_groups")
    local InfoMessage = require("ui/widget/infomessage")
    local XrayParser = require("koassistant.xray.xray_parser")
    if opts.plugin and opts.plugin.updateConfigFromSettings then
        opts.plugin:updateConfigFromSettings()
    end
    if not opts.title or opts.title == "" then
        opts.title = BookGroups.displayTitle(opts.file, opts.ui)
    end
    local main_entry = ActionCache.getXrayCache(opts.file)
    if not (main_entry and main_entry.result and XrayParser.isJSON(main_entry.result)) then
        UIManager:show(InfoMessage:new{
            text = _("This book needs a main X-Ray before another book's can be merged into it."),
            timeout = 4,
        })
        return false
    end
    local group
    for _idx, g in ipairs(BookGroups.groupsFor(opts.file)) do
        if BookGroups.kindOf(g) == BookGroups.KIND_PROJECT
                and (not opts.group_id or g.id == opts.group_id) then
            group = g
            break
        end
    end
    local mates = {}
    for _idx, p in ipairs(group and group.books or {}) do
        if p ~= opts.file then
            local ok_read, entry = pcall(ActionCache.getXrayCache, p)
            if ok_read and entry and entry.result and XrayParser.isJSON(entry.result) then
                mates[#mates + 1] = { file = p, title = BookGroups.displayTitle(p, opts.ui),
                    entry = entry }
            end
        end
    end
    if #mates == 0 then
        UIManager:show(InfoMessage:new{
            text = group and T(_("No other book in %1 has an X-Ray yet."), groupName(group))
                or _("This book is not in a project group."),
            timeout = 4,
        })
        return false
    end
    confirmFanIn(opts, mates, main_entry, group, nil)
    logger.dbg("KOAssistant XrayMerge: fan-in confirm,", #mates, "other X-Rays for", opts.file)
    return true
end

--- The series merge's confirm (item 46/49, the ORGANIC SERIES CHAIN,
--- maintainer decision 2026-08-06): each volume's X-Ray merges into the NEXT
--- volume's (1→2, 2→3, … N-1→N, oldest first), so EVERY volume ends up
--- carrying its predecessors — the carry stack (verbatim labeled background +
--- transitive ledger + alias bridge) makes each hop lossless, and archives
--- land one-per-volume instead of piling on the last book. Both sides of
--- every hop are re-read fresh: the previous hop just rewrote the source.
--- One confirm for both doors: the merge picker's row and the direct entries
--- (the X-Ray popup, the browser's menu, the hub: B394 slice 1). It names
--- what the run costs before anything is sent.
--- @param opts table startCrossBookFlow's opts (file = the LAST book of the run)
--- @param predecessors table Earlier books WITH an X-Ray, in reading order:
---   { file, title, author, entry }
--- @param main_entry table opts.file's X-Ray entry
--- @param group table|string|nil The series (named in the text; a table also
---   gives the count of earlier books without an X-Ray)
--- @param back function|nil "Back" and the tap outside (nil = just close)
local function confirmSeriesChain(opts, predecessors, main_entry, group, back)
    local ButtonDialog = require("ui/widget/buttondialog")
    local features = (opts.configuration and opts.configuration.features) or {}
    local provider = (opts.configuration
        and (opts.configuration.provider or opts.configuration.default_provider))
    -- Preflight disclosure (2026-08-05): the list only ever holds
    -- predecessors WITH X-Rays — name the gap instead of silently skipping
    -- X-Ray-less earlier books
    local missing_n = 0
    if type(group) == "table" then
        local pos = require("koassistant.books.book_groups").positionOf(group, opts.file)
        if pos then missing_n = math.max(0, (pos - 1) - #predecessors) end
    end
    -- The chain: predecessors in reading order, this book last
    local chain = {}
    for _pidx, pre in ipairs(predecessors) do chain[#chain + 1] = pre end
    chain[#chain + 1] = { file = opts.file, title = opts.title,
        author = opts.author, entry = main_entry }
    local n_merges = #chain - 1
    -- Round 28 (field report: adding Vol 4 re-ran 1→2 and 2→3): hops already
    -- recorded in the target's provenance can be skipped — only the new
    -- volumes cost requests
    local done_n, stale_n = 0, 0
    for i = 1, n_merges do
        local st = XrayMerge.foldStatus(chain[i + 1].entry,
            { title = chain[i].title, file = chain[i].file,
              timestamp = chain[i].entry and chain[i].entry.timestamp })
        if st == "stale" then stale_n = stale_n + 1
        elseif st ~= "none" then done_n = done_n + 1 end
    end
    local confirm_title = T(_("Bring %1 up to date with %2 AI merge(s), oldest first: each book's X-Ray is merged into the next book's (1 into 2, 2 into 3, and so on). One request per merge. The X-Rays are sent, not the books."),
            groupName(group), n_merges)
        .. "\n" .. _("Every book ends up carrying what the books before it know, as labeled background. Each receiving X-Ray is archived first, so every step can be undone from that book's version list.")
    if missing_n > 0 then
        confirm_title = confirm_title .. "\n"
            .. T(_("Skipped: %1 earlier book(s) have no X-Ray yet."), missing_n)
    end
    if done_n > 0 then
        confirm_title = confirm_title .. "\n"
            .. T(_("%1 of these merges already ran and are up to date: those are skipped (\"Re-run all\" runs them anyway)."), done_n)
    end
    if stale_n > 0 then
        confirm_title = confirm_title .. "\n"
            .. T(_("%1 ran before, but those X-Rays have changed since: they run again."), stale_n)
    end
    local function launchChain(skip_done)
        -- The question before the first request (B395 slice 5): every book of
        -- the chain, its X-Ray's kinds, asked once; the allowance rides the
        -- private copy every hop's request is built from
        XrayMerge.withDataAccess(opts, chain, _("AI merge the series"), function(run_cfg)
            XrayMerge.runSeriesChain({
                chain = chain, features = run_cfg.features, provider = provider,
                ui = opts.ui, plugin = opts.plugin,
                configuration = run_cfg,
                close_browser = opts.close_browser,
                reopen_live = opts.reopen_live,
                on_done = opts.on_done,
                skip_done = skip_done,
            })
        end)
    end
    local confirm
    local chain_buttons = {}
    local function button(text, skip_done)
        table.insert(chain_buttons, {{
            text = text,
            callback = function()
                UIManager:close(confirm)
                launchChain(skip_done)
            end,
        }})
    end
    if done_n > 0 and done_n < n_merges then
        button(T(_("AI merge new only: %1 request(s)"), n_merges - done_n), true)
        button(T(_("Re-run all: %1 request(s)"), n_merges), false)
    elseif done_n >= n_merges and n_merges > 0 then
        button(T(_("Re-run all: %1 request(s)"), n_merges), false)
    else
        button(T(_("AI merge the series: %1 request(s)"), n_merges), false)
    end
    table.insert(chain_buttons, {{ text = back and _("Back") or _("Cancel"), callback = function()
        UIManager:close(confirm)
        if back then back() end
    end }})
    confirm = ButtonDialog:new{
        title = confirm_title,
        buttons = chain_buttons,
        -- A tap outside is Back (B360)
        tap_close_callback = back,
    }
    UIManager:show(confirm)
end

--- The series merge, opened directly (B394 slice 1): the X-Ray popup's and the
--- browser's "Bring the series up to date…" rows and the hub's series row.
--- It used to sit two taps deep, as a row inside the merge picker. Reads only
--- the series' own earlier books (the picker reads every book with an X-Ray).
--- @param opts table startCrossBookFlow's opts; file = the book the run ends at
--- @return boolean shown False when a message explained why not
function XrayMerge.startSeriesChainFlow(opts)
    local ActionCache = require("koassistant.artifacts.action_cache")
    local BookGroups = require("koassistant.books.book_groups")
    local InfoMessage = require("ui/widget/infomessage")
    local XrayParser = require("koassistant.xray.xray_parser")
    -- Cross-instance staleness: the consent gates must see CURRENT settings
    if opts.plugin and opts.plugin.updateConfigFromSettings then
        opts.plugin:updateConfigFromSettings()
    end
    if not opts.title or opts.title == "" then
        opts.title = BookGroups.displayTitle(opts.file, opts.ui)
    end
    local main_entry = ActionCache.getXrayCache(opts.file)
    if not (main_entry and main_entry.result and XrayParser.isJSON(main_entry.result)) then
        UIManager:show(InfoMessage:new{
            text = _("This book needs a main X-Ray before another book's can be merged into it."),
            timeout = 4,
        })
        return false
    end
    local preds, group = BookGroups.predecessorsOf(opts.file)
    local predecessors = {}
    for _idx, p in ipairs(preds) do
        local ok_read, entry = pcall(ActionCache.getXrayCache, p)
        if ok_read and entry and entry.result and XrayParser.isJSON(entry.result) then
            predecessors[#predecessors + 1] = { file = p,
                title = BookGroups.displayTitle(p, opts.ui), entry = entry }
        end
    end
    if #predecessors == 0 then
        local why
        if #preds > 0 then
            why = T(_("No earlier book in %1 has an X-Ray yet."), groupName(group))
        elseif group and BookGroups.isOrdered(group) then
            why = T(_("This is the first book of %1: there is no earlier book to merge in."),
                groupName(group))
        else
            why = _("This book is not in a series group.")
        end
        UIManager:show(InfoMessage:new{ text = why, timeout = 4 })
        return false
    end
    confirmSeriesChain(opts, predecessors, main_entry, group, nil)
    logger.dbg("KOAssistant XrayMerge: series chain confirm,", #predecessors, "earlier X-Rays for", opts.file)
    return true
end

--- Entry point: candidate books → spoiler confirm → run.
--- @param opts table { file (target, required), ui, plugin, configuration
---   (required), title, author, close_browser, on_done(ok, err) }
function XrayMerge.startCrossBookFlow(opts)
    local ActionCache = require("koassistant.artifacts.action_cache")
    local ButtonDialog = require("ui/widget/buttondialog")
    local InfoMessage = require("ui/widget/infomessage")
    local Notification = require("ui/widget/notification")
    local XrayParser = require("koassistant.xray.xray_parser")

    -- Cross-instance staleness: the consent gates below must see CURRENT settings
    if opts.plugin and opts.plugin.updateConfigFromSettings then
        opts.plugin:updateConfigFromSettings()
    end
    -- Identity fallback from the open document (same rule as startFlow)
    if (not opts.title or opts.title == "") and opts.ui and opts.ui.doc_props
        and opts.ui.document and opts.ui.document.file == opts.file then
        opts.title = opts.ui.doc_props.display_title or opts.ui.doc_props.title
        if not opts.author or opts.author == "" then
            local authors = opts.ui.doc_props.authors or ""
            if authors:find("\n") then authors = authors:gsub("\n", ", ") end
            opts.author = authors
        end
    end
    -- Cross-book-viewed target (group nav / artifact browser): identity from
    -- the TARGET file, never the open book (item 46 follow-up)
    if not opts.title or opts.title == "" then
        opts.title = require("koassistant.books.book_groups").displayTitle(opts.file, opts.ui)
    end

    local main_entry = ActionCache.getXrayCache(opts.file)
    if not (main_entry and main_entry.result and XrayParser.isJSON(main_entry.result)) then
        UIManager:show(InfoMessage:new{
            text = _("This book needs a main X-Ray before another book's can be merged into it."),
            timeout = 4,
        })
        return
    end

    -- Multi-group target (round 37): the suggestion ordering needs ONE
    -- group's lens — ask which, once per flow (the pick rides opts, so the
    -- Back re-entries below keep it)
    if not opts.group_id then
        local BookGroups = require("koassistant.books.book_groups")
        local memberships = BookGroups.groupsFor(opts.file)
        if #memberships > 1 then
            local gdialog
            local grows = {}
            for _idx, g in ipairs(memberships) do
                local captured = g
                grows[#grows + 1] = {{
                    text = BookGroups.isOrdered(captured)
                        and T(_("%1 (book %2 of %3)"), groupName(captured),
                            BookGroups.positionOf(captured, opts.file) or 0, #captured.books)
                        or T(_("%1 (%2 books)"), groupName(captured), #captured.books),
                    align = "left",
                    callback = function()
                        UIManager:close(gdialog)
                        opts.group_id = captured.id
                        XrayMerge.startCrossBookFlow(opts)
                    end,
                }}
            end
            gdialog = ButtonDialog:new{
                title = T(_("\"%1\" is in several groups. Order the merge suggestions by which one?"), opts.title or "?"),
                buttons = grows,
            }
            UIManager:show(gdialog)
            return
        end
    end

    -- Candidates: every book the artifact index knows about with a JSON main
    -- X-Ray (read on demand — the index only holds books WITH artifacts).
    -- Title/author follow the identity rule: the per-book AI override on the
    -- SOURCE book's sidecar dictates what the prompt calls it.
    local index = G_reader_settings:readSetting("koassistant_artifact_index") or {}
    local candidates = {}
    for path in pairs(index) do
        if path ~= opts.file then
            local ok_read, entry = pcall(ActionCache.getXrayCache, path)
            if ok_read and entry and entry.result and XrayParser.isJSON(entry.result) then
                local title, author
                local ok_ds, ds = pcall(function()
                    return require("koassistant.storage.doc_settings").resolve(path, opts.ui)
                end)
                if ok_ds and ds then
                    local props = require("koassistant.storage.doc_settings").overlayCustomProps(ds:readSetting("doc_props"), path) or {}
                    title = props.display_title or props.title
                    author = props.authors
                    if type(author) == "string" and author:find("\n") then
                        author = author:gsub("\n", ", ")
                    end
                    local ov_t, ov_a = require("koassistant.books.book_settings").getMetadataOverride(ds)
                    if ov_t ~= nil then title = ov_t end
                    if ov_a ~= nil then author = ov_a end
                end
                if not title or title == "" then
                    title = path:match("([^/]+)%.[^.]+$") or path:match("([^/]+)$") or path
                end
                candidates[#candidates + 1] = {
                    file = path, title = title, author = author or "", entry = entry,
                }
            end
        end
    end
    if #candidates == 0 then
        UIManager:show(InfoMessage:new{
            text = _("No other book has an X-Ray yet. Create one in the other book first."),
            timeout = 4,
        })
        return
    end
    table.sort(candidates, function(a, b) return (a.title or "") < (b.title or "") end)
    -- Item 46: group-aware order — predecessors first (nearest on top), then
    -- later group-mates, then everything else; annotates group_name/group_pos/
    -- group_direction for the labels and the directional warning below
    local BookGroups = require("koassistant.books.book_groups")
    candidates = BookGroups.orderCandidates(candidates, opts.file, nil, opts.group_id)

    local features = (opts.configuration and opts.configuration.features) or {}
    local provider = (opts.configuration
        and (opts.configuration.provider or opts.configuration.default_provider))

    local picker, other_picker
    local function closePickers()
        if picker then UIManager:close(picker) end
        if other_picker then UIManager:close(other_picker) end
    end
    -- Device round 2026-08-05 ("the menus here are really bad"): TIERED picker
    -- — the group tier (fold-all + group-mates) leads, and the index-wide
    -- list moves behind one "Other books…" row instead of burying the group
    -- rows under every X-Rayed book in the library
    local group_rows, other_rows = {}, {}
    for _idx, cand in ipairs(candidates) do
        local captured = cand
        local row_label = captured.title
            .. (captured.author ~= "" and (" (" .. captured.author .. ")") or "")
        if captured.group_name then
            -- An unordered group has no book numbers (round 27) — name it only
            row_label = row_label .. " · " .. (captured.group_pos
                and T(_("%1, book %2"), groupName(captured.group_name), captured.group_pos)
                or groupName(captured.group_name))
        end
        table.insert(captured.group_name and group_rows or other_rows, {{
            text = row_label,
            align = "left",
            callback = function()
                closePickers()
                -- A Never on either book refuses with that book's door; the
                -- kinds on Ask are asked after the confirm (B395 slice 5)
                local pair_books = { { file = captured.file, title = captured.title, entry = captured.entry },
                    { file = opts.file, title = opts.title, entry = main_entry } }
                if XrayMerge.refusedBook(opts, pair_books, _("AI merge")) then return end
                -- Item 46: earlier feeds later — merging a LATER group-mate is
                -- legal (re-readers) but the spoiler warning names the direction
                local confirm_text = T(_("AI merge the X-Ray of \"%1\" into \"%2\"?"), captured.title, opts.title or "?")
                    .. "\n" .. _("One request: the two X-Rays are sent, not the books. Recurring characters, places, and concepts gain that book's background. This brings in everything its X-Ray covers, including its later events. The receiving X-Ray is archived first, so this can be undone from All versions.")
                -- B394 slice 1: this door never said that merging the same
                -- book again sends everything again
                local fold_status = XrayMerge.foldStatus(main_entry, { title = captured.title,
                    file = captured.file, timestamp = captured.entry and captured.entry.timestamp })
                if fold_status == "stale" then
                    confirm_text = confirm_text .. "\n\n" .. _("This book was merged in before and its X-Ray has changed since. Merging again brings the changes in.")
                elseif fold_status ~= "none" then
                    confirm_text = confirm_text .. "\n\n" .. _("This book was merged in before. Merging again sends both X-Rays again; that is only worth it when one of them has changed.")
                end
                if captured.group_direction == "after" then
                    confirm_text = confirm_text .. "\n\n" .. T(_("Caution: \"%1\" comes LATER in %2. Its background includes events beyond this book."),
                        captured.title, groupName(captured.group_name))
                end
                local confirm
                confirm = ButtonDialog:new{
                    title = confirm_text,
                    buttons = {
                        {{
                            text = _("AI merge (1 request)"),
                            callback = function()
                                UIManager:close(confirm)
                                XrayMerge.withDataAccess(opts, pair_books, _("AI merge"), function(run_cfg)
                                if opts.close_browser then opts.close_browser() end
                                XrayMerge.executeCrossBook({
                                    file = opts.file,
                                    ui = opts.ui,
                                    plugin = opts.plugin,
                                    configuration = run_cfg,
                                    title = opts.title,
                                    author = opts.author,
                                    main_entry = main_entry,
                                    source = captured,
                                    on_done = opts.on_done or function(ok, err, outcome)
                                        if ok and outcome and outcome.no_overlap then
                                            -- Round 28: an honest answer about the
                                            -- two books, not a plugin failure —
                                            -- InfoMessage (dismissable, readable)
                                            -- rather than a passing toast
                                            UIManager:show(InfoMessage:new{
                                                text = T(_("Nothing to merge: \"%1\" and this book share no people, places or concepts. Nothing was changed."), captured.title),
                                                timeout = 5,
                                            })
                                            XrayMerge.reopenLive(opts)
                                        elseif ok then
                                            UIManager:show(Notification:new{
                                                text = T(_("AI merged the X-Ray of \"%1\" into this book."), captured.title),
                                            })
                                            -- Round 27: the fold retired the
                                            -- X-Ray it was launched from — land
                                            -- back on it, now carrying the fold
                                            XrayMerge.reopenLive(opts)
                                            XrayMerge.maybeOfferDedupScan(opts)
                                        else
                                            -- Round 28: name the likely cause. The
                                            -- raw reason stays for diagnosis, but a
                                            -- bare "not a valid X-Ray JSON
                                            -- structure" reads as a plugin bug when
                                            -- it usually means the model answered
                                            -- in prose. Nothing was written.
                                            UIManager:show(InfoMessage:new{
                                                text = T(_("X-Ray merge failed: the model did not return a usable result. Nothing was changed; trying again often works.\n\n%1"),
                                                    tostring(err or "unknown error")),
                                                timeout = 6,
                                            })
                                        end
                                    end,
                                })
                                end)
                            end,
                        }},
                        {{
                            text = _("Back"),
                            callback = function()
                                UIManager:close(confirm)
                                -- Back one step to the book list, not abandon
                                XrayMerge.startCrossBookFlow(opts)
                            end,
                        }},
                    },
                    -- A tap outside is Back (B360)
                    tap_close_callback = function() XrayMerge.startCrossBookFlow(opts) end,
                }
                UIManager:show(confirm)
            end,
        }})
    end
    -- The series merge (confirmSeriesChain above): offered here when two or
    -- more earlier books have X-Rays (one earlier book is just its own row)
    local predecessors = {}
    for _idx, cand in ipairs(candidates) do
        if cand.group_direction == "before" then
            predecessors[#predecessors + 1] = cand
        end
    end
    table.sort(predecessors, function(a, b) return a.group_pos < b.group_pos end)
    local fold_rows = {}
    -- Round 30 — PROJECT groups get the order-free counterpart: fan-in. A
    -- project has no predecessors (predecessorsOf is series-only), so the chain
    -- row below never appears for one; instead offer to fold every other member
    -- INTO this book (confirmFanIn above). Group-mates are identifiable by
    -- group_name, which orderCandidates sets for unordered groups too (only
    -- pos/direction drop).
    do
        local BG = require("koassistant.books.book_groups")
        local tgt_group = (opts.group_id and BG.byId(opts.group_id))
            or BG.groupsFor(opts.file)[1]
        if tgt_group and BG.kindOf(tgt_group) == BG.KIND_PROJECT then
            local mates = {}
            for _idx, cand in ipairs(candidates) do
                if cand.group_name then mates[#mates + 1] = cand end
            end
            if #mates >= 2 then
                table.insert(fold_rows, {{
                    text = T(_("AI merge the other books (up to %1 requests)…"), #mates),
                    callback = function()
                        UIManager:close(picker)
                        confirmFanIn(opts, mates, main_entry, tgt_group,
                            function() XrayMerge.startCrossBookFlow(opts) end)
                    end,
                }})
            end
        end
    end
    if #predecessors >= 2 then
        table.insert(fold_rows, {{
            text = T(_("AI merge the series (%1 earlier books)…"), #predecessors),
            callback = function()
                UIManager:close(picker)
                local BG = require("koassistant.books.book_groups")
                local group = (opts.group_id and BG.byId(opts.group_id))
                    or BG.groupsFor(opts.file)[1]
                confirmSeriesChain(opts, predecessors, main_entry,
                    group or predecessors[1].group_name,
                    -- Back one step to the book list, not abandon
                    function() XrayMerge.startCrossBookFlow(opts) end)
            end,
        }})
    end
    -- Assembly (tiered): fold-all first, then group-mates, then the rest
    -- behind one row
    local rows = {}
    for _i, r in ipairs(fold_rows) do rows[#rows + 1] = r end
    local tgt_group = (opts.group_id and BookGroups.byId(opts.group_id))
        or BookGroups.groupsFor(opts.file)[1]
    if tgt_group and #predecessors == 0 and BookGroups.isOrdered(tgt_group) then
        -- Discoverability (device 2026-08-05): the fold-in machinery is
        -- invisible until earlier group-mates HAVE X-Rays — say why.
        -- Unordered groups (round 27) have no "earlier" at all: the absence is
        -- the design, not a gap to explain.
        rows[#rows + 1] = {{
            text = T(_("No earlier book in %1 has an X-Ray yet"), groupName(tgt_group)),
            enabled = false,
        }}
    end
    for _i, r in ipairs(group_rows) do rows[#rows + 1] = r end
    if #group_rows > 0 and #other_rows > 0 then
        rows[#rows + 1] = {{
            text = T(_("Other books with an X-Ray (%1)…"), #other_rows),
            align = "left",
            callback = function()
                UIManager:close(picker)
                local orows = {}
                for _i, r in ipairs(other_rows) do orows[#orows + 1] = r end
                orows[#orows + 1] = {{
                    text = _("Back"),
                    callback = function()
                        UIManager:close(other_picker)
                        XrayMerge.startCrossBookFlow(opts)
                    end,
                }}
                other_picker = ButtonDialog:new{
                    title = T(_("AI merge into \"%1\": other books with an X-Ray"), opts.title or "?"),
                    buttons = orows,
                    tap_close_callback = function() XrayMerge.startCrossBookFlow(opts) end,
                }
                UIManager:show(other_picker)
            end,
        }}
    else
        for _i, r in ipairs(other_rows) do rows[#rows + 1] = r end
    end
    table.insert(rows, {{
        text = _("Manage groups…"),
        callback = function()
            UIManager:close(picker)
            require("koassistant.books.book_groups_ui").showManager({
                plugin = opts.plugin, ui = opts.ui,
                on_close = function() XrayMerge.startCrossBookFlow(opts) end,
            })
        end,
    }})
    table.insert(rows, {{
        text = _("Cancel"),
        callback = function() UIManager:close(picker) end,
    }})
    picker = ButtonDialog:new{
        -- Naming the TARGET matters: this flow can be launched from another
        -- book's X-Ray via group navigation — "this book" would be ambiguous
        title = T(_("AI merge into \"%1\": pick the other book"), opts.title or "?"),
        buttons = rows,
    }
    UIManager:show(picker)
    logger.dbg("KOAssistant XrayMerge: cross-book picker with", #candidates, "candidates for", opts.file)
end

-- ============================ Moved books (B504) ============================
-- Cross-book X-Ray data names books by path: the fold ledger (merged_from),
-- carried entries and background lines. A move inside KOReader re-keys the
-- indexes, the images and the groups (main.lua's updateLocation patch for a
-- book, StorageRegistry.followFolderMove for a folder, B507); these links are
-- re-keyed here, in one background sweep after the moves settle. Another
-- device's paths are not this: they need an identity that does not depend on
-- the folder (docs/cross_device_plan.md section 2).

-- A path-shaped quoted string: an opening quote, then "/" (or "\/", as
-- KOReader's JSON encoder writes it), up to the closing quote (book paths
-- hold no quote: FAT forbids it). Found by pattern, so a sweep costs the
-- same for one move or a hundred, and each occurrence is replaced once, by
-- its own move, whatever order the moves came in
local QUOTED_PATH = '"(\\?/[^"]*)"'

-- The quoted replacement for a quoted path that names a moved book, written
-- the way the old one was (JSON-escaped or plain); nil for any other string
local function movedQuote(inner, moves)
    if inner:sub(1, 2) == "\\/" then
        local new = moves[(inner:gsub("\\/", "/"))]
        return new and ('"' .. (new:gsub("/", "\\/")) .. '"') or nil
    end
    local new = moves[inner]
    return new and ('"' .. new .. '"') or nil
end

local function replacePaths(s, moves)
    local changed = false
    local out = s:gsub(QUOTED_PATH, function(inner)
        local repl = movedQuote(inner, moves)
        if repl then changed = true end
        return repl
    end)
    return out, changed
end

-- A record's own path (merged_from rows): exact equality
local function rekeyRecords(list, moves)
    local changed = false
    if type(list) ~= "table" then return false end
    for _idx, rec in ipairs(list) do
        if type(rec) == "table" and type(rec.file) == "string" and moves[rec.file] then
            rec.file = moves[rec.file]
            changed = true
        end
    end
    return changed
end

-- One saved X-Ray (cache entry, checkpoint or archived version): its result
-- text and its fold ledger. Timestamps, progress and the rest stay as read.
local function rekeyEntry(entry, moves)
    local changed = false
    if type(entry.result) == "string" then
        local out, ch = replacePaths(entry.result, moves)
        if ch then entry.result = out; changed = true end
    end
    if rekeyRecords(entry.merged_from, moves) then changed = true end
    return changed
end

-- Does a store file name a moved book? Read raw: the results' JSON and the
-- Lua-quoted fold ledgers both show their paths as quoted strings. A store
-- left at another sidecar location (KOReader's metadata location changed
-- since the book was last opened) moves here first, as any read moves it.
local function storeNames(path, moves, load)
    if not path then return false end
    local lfs = require("libs/libkoreader-lfs")
    if lfs.attributes(path, "mode") ~= "file" then pcall(load) end
    local f = io.open(path, "rb")
    if not f then return false end
    local text = f:read("*a") or ""
    f:close()
    for inner in text:gmatch(QUOTED_PATH) do
        if movedQuote(inner, moves) then return true end
    end
    return false
end

--- Re-key one book's links to moved books: its cache, built checkpoints and
--- archived versions, each file read first and rewritten only when it names
--- an old path. Only the quoted paths change: nothing is re-encoded, so an
--- installed checkpoint and the live X-Ray stay byte-identical, and no
--- timestamp moves (a fold's version check compares them).
--- @param document_path string The book whose stores are checked
--- @param moves table { [old_path] = new_path }
--- @return number stores rewritten
function XrayMerge.rekeyBook(document_path, moves)
    local ActionCache = require("koassistant.artifacts.action_cache")
    local rewritten = 0
    if storeNames(ActionCache.getPath(document_path), moves,
            function() ActionCache.getXrayCache(document_path) end) then
        if ActionCache.rewriteEntries(document_path, function(_key, entry)
                return rekeyEntry(entry, moves)
            end) then
            rewritten = rewritten + 1
        end
    end
    if storeNames(ActionCache.getXrayLadderPath(document_path), moves,
            function() ActionCache.getXrayLadder(document_path) end) then
        local ladder = ActionCache.getXrayLadder(document_path)
        local changed = false
        for _idx, rung in ipairs(ladder) do
            if type(rung) == "table" and rekeyEntry(rung, moves) then changed = true end
        end
        if changed and ActionCache.saveXrayLadder(document_path, ladder) then rewritten = rewritten + 1 end
    end
    if storeNames(ActionCache.getXrayCheckpointsPath(document_path), moves,
            function() ActionCache.getXrayCheckpoints(document_path) end) then
        local ring = ActionCache.getXrayCheckpoints(document_path)
        local changed = false
        for _idx, cp in ipairs(ring) do
            if type(cp) == "table" and rekeyEntry(cp, moves) then changed = true end
        end
        if changed and ActionCache.saveXrayCheckpoints(document_path, ring) then rewritten = rewritten + 1 end
    end
    return rewritten
end

-- Moves waiting for the sweep, in the order they happened:
-- { old = path, new = path, folder = true for a folder's move }
local pending_moves = {}
-- Books one step of a sweep reads: a large library never holds the screen
local SWEEP_SLICE = 8

-- One move applied to one path: a book's own path, or a folder and
-- everything inside it; any other path as it was
local function applyMove(m, path)
    if m.folder then return SafeDocSettings.movedPath(path, m.old, m.new) or path end
    return path == m.old and m.new or path
end

-- Where a path saved before the waiting moves is now: each move applied in
-- the order it happened (a book moved and then its folder renamed ends under
-- the folder's new name; two books trading places each take their own move);
-- nil when the moves leave it where it was
local function movedPath(list, path)
    local p = path
    for _idx, m in ipairs(list) do p = applyMove(m, p) end
    if p ~= path then return p end
    return nil
end

--- @param all_at_once boolean|nil every book in one step (the tests)
local function sweepMoves(all_at_once)
    local list = pending_moves
    pending_moves = {}
    if #list == 0 then return end
    -- The lookup every rewrite below reads as moves[path]
    local moves = setmetatable({}, { __index = function(_t, path)
        if type(path) == "string" then return movedPath(list, path) end
    end })
    -- Where each move left what it moved (the later moves applied): a book's
    -- last path, a folder's
    local books, folders = {}, {}
    for i, m in ipairs(list) do
        local last = m.new
        for j = i + 1, #list do last = applyMove(list[j], last) end
        if m.folder then
            folders[#folders + 1] = last
        else
            books[last] = true
        end
    end
    local function moved(path)
        if books[path] then return true end
        for _idx, dir in ipairs(folders) do
            if SafeDocSettings.inFolder(path, dir) then return true end
        end
        return false
    end
    -- Pinned items name their book too (a pin's privacy check reads it): the
    -- general and library stores, and the moved books' own (a moved folder's
    -- books by the pinned index, which the move re-keyed already)
    local PinnedManager = require("koassistant.artifacts.pinned_manager")
    local pin_stores = { PinnedManager.GENERAL_KEY, PinnedManager.LIBRARY_KEY }
    for path in pairs(books) do pin_stores[#pin_stores + 1] = path end
    if #folders > 0 then
        for path in pairs(G_reader_settings:readSetting("koassistant_pinned_index") or {}) do
            if not books[path] and moved(path) then pin_stores[#pin_stores + 1] = path end
        end
    end
    for _idx, key in ipairs(pin_stores) do
        local ok, err = pcall(PinnedManager.rekeyPaths, key, moves)
        if not ok then logger.warn("KOAssistant XrayMerge: could not update pinned links in", key, ":", tostring(err)) end
    end
    -- Every book that may hold a link: the books with saved artifacts, and
    -- the moved books' groups (a group's X-Rays carry its members)
    local seen, queue = {}, {}
    local function add(path)
        if type(path) == "string" and not path:match("^__") and not seen[path] then
            seen[path] = true
            queue[#queue + 1] = path
        end
    end
    for path in pairs(G_reader_settings:readSetting("koassistant_artifact_index") or {}) do add(path) end
    local BookGroups = require("koassistant.books.book_groups")
    for _idx, group in ipairs(BookGroups.all()) do
        local reached = false
        for _j, member in ipairs(group.books or {}) do
            if moved(member) then reached = true; break end
        end
        if reached then
            for _j, member in ipairs(group.books or {}) do add(member) end
        end
    end
    local rewritten, touched = 0, 0
    local function step()
        local n = 0
        while #queue > 0 and (all_at_once or n < SWEEP_SLICE) do
            local path = table.remove(queue)
            n = n + 1
            local ok, count = pcall(XrayMerge.rekeyBook, path, moves)
            if ok and count > 0 then
                rewritten = rewritten + count
                touched = touched + 1
            elseif not ok then
                logger.warn("KOAssistant XrayMerge: could not update moved-book links in", path, ":", tostring(count))
            end
        end
        if #queue > 0 then
            UIManager:scheduleIn(0.1, step)
        elseif touched > 0 then
            logger.info("KOAssistant XrayMerge: moved book links updated in", touched, "book(s),", rewritten, "file(s)")
        end
    end
    step()
end

--- A book moved inside KOReader (the updateLocation patch, moves only), or a
--- folder (StorageRegistry.followFolderMove, B507): the links other books'
--- X-Rays keep to it, or to the books inside it, follow, in one sweep a few
--- seconds after the last of a batch of moves. Moves before the sweep apply
--- in their order: a book moved twice maps to its last path.
--- @param old_path string
--- @param new_path string
--- @param folder boolean|nil the paths are a folder's
function XrayMerge.noteMoved(old_path, new_path, folder)
    if type(old_path) ~= "string" or type(new_path) ~= "string" or old_path == new_path then return end
    pending_moves[#pending_moves + 1] = { old = old_path, new = new_path, folder = folder or nil }
    UIManager:unschedule(sweepMoves)
    UIManager:scheduleIn(3, sweepMoves)
end

-- Tests drive the sweep without the scheduler
XrayMerge._sweepMoves = sweepMoves

-- ── Carried entries follow the groups (B536) ────────────────────────────────
-- The free carry is mechanical, so what a book holds of it is decided by its
-- groups as they are NOW: a carried row or a history line from a book it no
-- longer takes from goes, at every change of its groups, when it leaves one,
-- when one is deleted, and after every write of its X-Ray (a checkpoint built
-- while the group was different cannot bring it back). What an AI merge
-- brought stays, and so do the reader's own decisions: a row carried by hand,
-- an entry added by hand from the carried list, the removed-carried record.

-- Normalized title variants a label may carry for a book (the labels were
-- written from the display title, the doc_props title or the AI override,
-- and from the file name when a book had no title)
local function titleNorms(path, ui)
    local out = {}
    local function add(t)
        local n = normTitle(t)
        if n and n ~= "" then out[#out + 1] = n end
    end
    local ok_ds, ds = pcall(function() return SafeDocSettings.resolve(path, ui) end)
    if ok_ds and ds then
        local props = SafeDocSettings.overlayCustomProps(ds:readSetting("doc_props"), path) or {}
        add(props.title)
        add(props.display_title)
    end
    local ok_t, title = pcall(function()
        return require("koassistant.books.book_groups").displayTitle(path, ui)
    end)
    if ok_t then add(title) end
    add(path:match("([^/]+)%.[^.]+$"))
    return out
end

-- Each book's AI-merge record, read again only when its cache file changed:
-- the rule reaches every book of a long series on each run
local record_memo = {}
local function mergeRecordsOf(path)
    local ActionCache = require("koassistant.artifacts.action_cache")
    local cp = ActionCache.getPath(path)
    local a = cp and require("libs/libkoreader-lfs").attributes(cp)
    local stamp = a and (tostring(a.modification) .. ":" .. tostring(a.size)) or "-"
    local m = record_memo[path]
    if m and m.stamp == stamp then return m.ledger end
    local led = XrayMerge.ledgerOf(a and ActionCache.getXrayCache(path) or nil)
    record_memo[path] = { stamp = stamp, ledger = led }
    return led
end

--- What a book may hold of the free carry now (B536), as a predicate over a
--- carried row or history line's book. Allowed: what its groups give (a
--- series' earlier books, a project's other members, a plain group nothing),
--- what was AI merged into it, and the same of every book reached that way (a
--- source's own carried list rides on), never a book that comes after it in
--- one of its series unless it AI merged that book itself. A book in several
--- groups keeps what any of them gives. A path this device does not have (a
--- copy synced from another device, a book gone from disk) cannot be judged
--- and is kept; a line from before files were recorded is judged by its
--- book's title, and kept when the title names no book a group here holds.
--- @param file string The book
--- @param opts table|nil { ui, memo = one run's shared reads ({ titles,
---   exists }), own = this book's merge record when already read, own_extra =
---   more records of its own (its archived versions'), exists =
---   function(path) (tests), entry_of = function(path) -> cache entry (tests) }
--- @return function keep(row_file, row_source) -> boolean
function XrayMerge.carryRule(file, opts)
    opts = opts or {}
    local BookGroups = require("koassistant.books.book_groups")
    local memo = opts.memo or {}
    memo.titles = memo.titles or {}
    memo.exists = memo.exists or {}
    local exists_fn = opts.exists or BookGroups.fileExists
    local function current(p)
        return movedPath(pending_moves, p) or p
    end
    local function ledgerFor(p)
        if p == file and opts.own then return opts.own end
        if opts.entry_of then
            local ok, entry = pcall(opts.entry_of, p)
            return XrayMerge.ledgerOf(ok and entry or nil)
        end
        local ok, led = pcall(mergeRecordsOf, p)
        return ok and led or {}
    end
    local function norm(s)
        local n = normTitle(s)
        if n == nil or n == "" or n == "?" then return nil end
        return n
    end
    local function titlesOf(p)
        local list = memo.titles[p]
        if not list then
            list = titleNorms(p, opts.ui)
            memo.titles[p] = list
        end
        return list
    end
    -- In a series nothing comes from a later book
    local later = {}
    for _idx, g in ipairs(BookGroups.groupsFor(file)) do
        if BookGroups.isOrdered(g) then
            local past = false
            for _j, p in ipairs(g.books or {}) do
                if past then later[p] = true elseif p == file then past = true end
            end
        end
    end
    -- What this book AI merged itself stays, a later book included
    local own_files, own_titles = {}, {}
    local function addOwn(list)
        for _idx, rec in ipairs(list or {}) do
            if rec.file then own_files[current(rec.file)] = true end
            local n = norm(rec.title)
            if n then own_titles[n] = true end
        end
    end
    addOwn(ledgerFor(file))
    addOwn(opts.own_extra)
    local files, merged_titles = {}, {}
    local seen, queue, head = { [file] = true }, { file }, 1
    local function reach(p)
        if type(p) ~= "string" or p == "" or p == file or later[p] then return end
        files[p] = true
        if not seen[p] then
            seen[p] = true
            queue[#queue + 1] = p
        end
    end
    while head <= #queue do
        local book = queue[head]
        head = head + 1
        for _idx, g in ipairs(BookGroups.groupsFor(book)) do
            if BookGroups.isOrdered(g) then
                for _j, p in ipairs(g.books or {}) do
                    if p == book then break end
                    reach(p)
                end
            elseif BookGroups.sharesKnowledge(g) then
                for _j, p in ipairs(g.books or {}) do
                    if p ~= book then reach(p) end
                end
            end
        end
        for _idx, rec in ipairs(ledgerFor(book)) do
            local n = norm(rec.title)
            if n then merged_titles[n] = true end
            if rec.file then reach(current(rec.file)) end
        end
    end
    local allowed_titles, known_titles
    local function allowedTitles()
        if allowed_titles then return allowed_titles end
        allowed_titles = {}
        for p in pairs(files) do
            for _idx, n in ipairs(titlesOf(p)) do allowed_titles[n] = true end
        end
        return allowed_titles
    end
    -- The titles of the books the groups here hold: a line from before files
    -- were recorded is refused only when it names one of them
    local function knownTitles()
        if known_titles then return known_titles end
        known_titles = {}
        for _idx, g in ipairs(BookGroups.all()) do
            for _j, p in ipairs(g.books or {}) do
                for _k, n in ipairs(titlesOf(p)) do known_titles[n] = true end
            end
        end
        return known_titles
    end
    local function exists(p)
        local e = memo.exists[p]
        if e == nil then
            local ok, r = pcall(exists_fn, p)
            e = not ok or r == true
            memo.exists[p] = e
        end
        return e
    end
    return function(row_file, row_source)
        local n = norm(row_source)
        if type(row_file) == "string" and row_file ~= "" then
            local f = current(row_file)
            if own_files[f] or (n and own_titles[n]) then return true end
            if f == file or later[f] then return false end
            if files[f] or (n and merged_titles[n]) then return true end
            return not exists(f)
        end
        if not n then return true end -- unattributable: kept, as the reconcile keeps it
        if own_titles[n] or merged_titles[n] or allowedTitles()[n] then return true end
        return not knownTitles()[n]
    end
end

--- Drop what `keep` refuses from a parsed X-Ray (B536): carried rows and the
--- history lines on entries and rows. The book's own entries are never
--- removed, only lines on them; an entry added by hand from the carried list
--- keeps all of its lines, and a row carried by hand stays. A row whose own
--- book is refused but which holds lines from books still allowed (an AI
--- merge's among them) stays with those lines, filed under the first of them,
--- without what the refused book said. Pure.
--- @param data table Parsed X-Ray (mutated)
--- @param keep function(file, source) -> boolean (carryRule)
--- @param hand table|nil Lowercased name -> spelling: the entries added by
---   hand from the carried list (ActionCache.getPromotedStubs)
--- @param opts table|nil { source_copy = a seed source's copy: its own
---   hand-carried rows are not the target's }
--- @return number removed Rows and lines dropped (a row re-filed counts one)
function XrayMerge.pruneCarried(data, keep, hand, opts)
    if type(data) ~= "table" or type(keep) ~= "function" then return 0 end
    local XrayParser = require("koassistant.xray.xray_parser")
    local mine = not (opts and opts.source_copy)
    local removed = 0
    local function isHand(name, aliases)
        if type(hand) ~= "table" then return false end
        if type(name) == "string" and hand[name:lower()] then return true end
        for _idx, a in ipairs(type(aliases) == "table" and aliases or {}) do
            if type(a) == "string" and hand[a:lower()] then return true end
        end
        return false
    end
    local function keptLines(bg)
        if type(bg) ~= "table" then return bg end
        local out = {}
        for _idx, b in ipairs(bg) do
            if type(b) ~= "table" or keep(b.file, b.source) then
                out[#out + 1] = b
            else
                removed = removed + 1
            end
        end
        if #out == #bg then return bg end
        return #out > 0 and out or nil
    end
    for _idx, cat in ipairs(XrayParser.getCategories(data)) do
        if type(cat.items) == "table" then
            for _idx2, item in ipairs(cat.items) do
                if type(item) == "table" and type(item.background) == "table"
                        and not isHand(XrayParser.getItemName(item, cat.key), item.aliases) then
                    item.background = keptLines(item.background)
                end
            end
        end
    end
    local DK = XrayParser.DORMANT_KEY
    local ledger = data[DK]
    if type(ledger) == "table" then
        local out = {}
        for _idx, stub in ipairs(ledger) do
            if type(stub) ~= "table" or (mine and (stub.by_hand or isHand(stub.name, stub.aliases))) then
                out[#out + 1] = stub
            elseif keep(stub.file, stub.source) then
                stub.background = keptLines(stub.background)
                out[#out + 1] = stub
            else
                removed = removed + 1
                local lines = keptLines(stub.background)
                if type(lines) == "table" and #lines > 0 then
                    stub.background = lines
                    stub.file, stub.source = lines[1].file, lines[1].source
                    stub.description, stub.role = nil, nil
                    out[#out + 1] = stub
                end
            end
        end
        if #out ~= #ledger or removed > 0 then data[DK] = #out > 0 and out or nil end
    end
    return removed
end

--- One book's share of the free carry made current (B536): what it may no
--- longer hold goes, then the seed adds what its sources give, their copies
--- pruned by the same rule first and a source the rule refuses skipped, so
--- nothing it may not hold comes back in through a source that has not caught
--- up yet. Before anything goes, the AI merges an earlier update dropped from
--- the record are read back from the book's archived versions and
--- checkpoints. Zero tokens. Writes only when something changed, through
--- editLiveXray (the version before archived once per session, like every
--- automatic seed).
--- @param file string
--- @param features table Settings features (the seed's consent)
--- @param provider string|nil
--- @param ui table|nil
--- @param opts table|nil { memo (one run's shared reads), done (set: books
---   already refreshed in this run, skipped and marked), explicit = a group
---   change, a leave or a delete asked (after a mere write, a device that
---   keeps no groups prunes nothing: its books may be another device's) }
--- @return boolean written, boolean looked (the book has a carry to look at)
function XrayMerge.refreshCarried(file, features, provider, ui, opts)
    opts = opts or {}
    if type(file) ~= "string" or file == "" then return false, false end
    if opts.done then
        if opts.done[file] then return false, false end
        opts.done[file] = true
    end
    local ActionCache = require("koassistant.artifacts.action_cache")
    local XrayParser = require("koassistant.xray.xray_parser")
    local entry = ActionCache.getXrayCache(file)
    if not (entry and entry.result and entry.source_mode ~= "ai_knowledge"
            and XrayParser.isJSON(entry.result)) then
        return false, false
    end
    local prune = opts.explicit or #require("koassistant.books.book_groups").all() > 0
    local sources = XrayMerge.seedSources(file, features, provider, ui)
    -- Nothing to seed from, and nothing carried or nothing to prune: nothing to read
    if #sources == 0 and (not prune or (not entry.result:find('"__dormant"', 1, true)
            and not entry.result:find('"background"', 1, true))) then
        return false, false
    end
    local memo = opts.memo or {}
    local own = XrayMerge.ledgerOf(entry)
    local keep = XrayMerge.carryRule(file, { ui = ui, memo = memo, own = own })
    local ok_h, hand = pcall(ActionCache.getPromotedStubs, file)
    if not ok_h then hand = nil end
    if prune then
        local probe = XrayParser.parse(entry.result)
        if probe and not probe.error and XrayMerge.pruneCarried(probe, keep, hand) > 0 then
            local extra = {}
            for _idx, getter in ipairs({ ActionCache.getXrayCheckpoints, ActionCache.getXrayLadder }) do
                local ok_v, versions = pcall(getter, file)
                for _j, v in ipairs(ok_v and type(versions) == "table" and versions or {}) do
                    for _k, rec in ipairs(XrayMerge.ledgerOf(v)) do extra[#extra + 1] = rec end
                end
            end
            if #extra > 0 then
                keep = XrayMerge.carryRule(file, { ui = ui, memo = memo, own = own, own_extra = extra })
            end
        end
    end
    local usable = {}
    for _idx, src in ipairs(sources) do
        if keep(src.file, src.title) then
            XrayMerge.pruneCarried(src.parsed, keep, nil, { source_copy = true })
            usable[#usable + 1] = src
        end
    end
    local skip = removedStubsFor(file)
    local function apply(data)
        local changed = prune and XrayMerge.pruneCarried(data, keep, hand) > 0 or false
        for _idx, src in ipairs(usable) do
            local added, refreshed = XrayMerge.populateDormant(data, nil, src.parsed,
                src.title, src.file, nil, file, skip, true)
            if added > 0 or (refreshed or 0) > 0 then changed = true end
        end
        return changed
    end
    local probe = XrayParser.parse(entry.result)
    if not (probe and not probe.error and apply(probe)) then return false, true end
    local ok = require("koassistant.xray.artifact_writeback").editLiveXray(file, apply, {
        features = features,
        limit = reseed_archived[file] and 0 or nil,
    })
    if ok then reseed_archived[file] = true end
    return ok == true, true
end

return XrayMerge
