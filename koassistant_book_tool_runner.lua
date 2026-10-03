local BookTools = require("koassistant_book_tools")
local BookSettings = require("koassistant_book_settings")
local ConfigHelper = require("koassistant_config_helper")
local DebugUtils = require("koassistant_debug_utils")
local ModelConstraints = require("model_constraints")
local ScopeResolver = require("koassistant_scope_resolver")
local ToolWire = require("koassistant_api.tool_wire")
local _ = require("koassistant_gettext")
local T = require("ffi/util").template

local BookToolRunner = {}

-- Lookup-effort dial (tools_ux_plan.md §2): features.tool_lookup_effort scales how much
-- searching a session may do. turns/calls cap the loop (both modes); bundle_chars caps
-- the phase-2 context bundle (gather only — individual tool caps of 8K/read target and
-- 180-char snippets bound each call, but nothing else bounds the session total).
-- "standard" = the former hard constants; unknown/missing values fall back to it.
-- whole_chars: the whole-text path (wholeReadableText) hands phase 2 the readable text
-- itself when it is no longer than this, instead of searching it.
-- Sending a text that fits is the QUICKEST path (one request, no rounds), so quick and
-- standard share the same limit; only thorough reaches further.
local EFFORT_BUDGETS = {
    quick    = { turns = 2, calls = 4,  bundle_chars = 32000, whole_chars = 64000 },
    standard = { turns = 4, calls = 8,  bundle_chars = 32000, whole_chars = 64000 },
    thorough = { turns = 6, calls = 16, bundle_chars = 48000, whole_chars = 128000 },
}
local function budgetFor(features)
    return EFFORT_BUDGETS[(features or {}).tool_lookup_effort] or EFFORT_BUDGETS.standard
end
BookToolRunner.budgetFor = budgetFor  -- exposed for unit tests
-- Diagnostic blocks (lookups trace, raw tool-result dump, token usage) are emitted only
-- when features.tool_workflow_diagnostics is on (gated in finish()); off by default. The dump
-- can contain raw book-text snippets, so it must never ship on for ordinary users.
local VERBOSE_TOOL_OUTPUT = true
local VERBOSE_SECTION_MAX_CHARS = 256
local SHOW_TURN_TOKEN_USAGE = true

local TOOL_INSTRUCTIONS = [[

When answering questions about the current book, use the local book tools when you need evidence from the text. Prefer search_book for specific phrases, character names, objects, or events; it returns all matching hit references with short concordance excerpts and page counts. Batch related lookups: pass multiple terms via search_book queries=[...] and multiple targets via read_around hit_ids=[...] / pages=[...] in a single call to avoid extra round trips. Use read_around for surrounding context, and toc for chapter structure; to find a chapter or essay by its title, call toc with title_contains rather than searching the text for the title. Every tool result carries a notes field stating what it could not search, list or read; a zero-hit result under such a note is inconclusive, not evidence of absence. Mention such a limit in your answer only where it bears on the question; never describe the lookups themselves, their caps or hit counts.]]

-- Reading-scope clause appended to the tool instructions. "current" enforces spoiler safety
-- (the model is also clamped in BookTools); "full" lets it use the whole document.
local SCOPE_NOTE_CURRENT = " The tools can only read pages up to the user's current reading position; do not request or claim access to later pages."
local SCOPE_NOTE_FULL = " The tools can read the entire document."

local FINAL_INSTRUCTIONS = [[

Use the gathered local book tool results to answer the user's question. Do not describe the lookups, their caps, hit counts, partial matches or cut passages. If a part of the book was out of reach for this question, say so in one sentence rather than filling the gap from memory.]]

local FINAL_NOTE_CURRENT = " Do not use or reveal any information about events or plot developments beyond the user's current reading position."

-- Gather mode (gather_then_generate_plan.md D2): phase 1 collects passages only; the
-- model signals completion via the `done` tool, then phase 2 answers as a normal
-- (streamed, web-search-capable) request with the gathered passages injected.
local GATHER_INSTRUCTIONS = [[

GATHER PHASE: Do not answer the user's question yet. Use the book tools (search_book, read_around, toc) to collect the passages needed to answer it; batch related lookups in one call. To find a chapter or essay by its title, call toc with title_contains rather than searching the text for the title. When you have gathered enough evidence — or if the question needs no book lookups — call the done tool. In this phase respond only with tool calls, never with prose. Every tool result carries a notes field stating what it could not search, list or read: read it before deciding you are done.]]

local FUNCTION_DECLARATIONS = {
    {
        name = "search_book",
        description = "Search the readable book text, word by word (no meaning matching: cover synonyms with several queries). Pass multiple terms via queries=[...] to batch lookups in one call. Returns per-query blocks with at most 12 hits each (raise with max_hits, up to 40), best score first and at most 2 per page; total_hits is always the exact count and page_summary lists the pages with hits. Each hit states its match_type: phrase, tokens (every word), substring (the words occur only inside longer words, e.g. anima in animals: weak evidence, ranked below whole-word hits), or partial (a query of 3+ words with most of its words present; the missing words are listed). Spelling must match (no typo tolerance): retry a name with another spelling if it finds nothing. In a long book each query costs one document search per word (at most 6 new words per call, longest first; a very common word does not narrow the search), so prefer few, specific words. Anything left out (hits, pages, hidden sections, spent budget) is stated in notes. Hit IDs are namespaced (e.g. q1:p42:3); call read_around for surrounding context.",
        parameters = {
            type = "object",
            properties = {
                queries = {
                    type = "array",
                    description = "Multiple phrases, names, or details to search for in one call. Preferred when you have several distinct lookups.",
                    items = { type = "string" },
                },
                query = {
                    type = "string",
                    description = "Single phrase, name, event, or detail. Use queries=[...] for multiple terms.",
                },
                case_sensitive = {
                    type = "boolean",
                    description = "Require exact casing. Defaults to false.",
                },
                max_hits = {
                    type = "integer",
                    description = "Hits returned per query. Defaults to 12, capped at 40.",
                },
            },
        },
    },
    {
        name = "read_around",
        description = "Read surrounding text near one or more search hits or page numbers: up to 5 pages and 8000 characters per target, 4 targets per call, within the readable range. Notes state any target that was moved, skipped or cut.",
        parameters = {
            type = "object",
            properties = {
                hit_id = {
                    type = "string",
                    description = "A hit_id returned by search_book, such as q1:p42:3.",
                },
                page = {
                    type = "integer",
                    description = "Page to read around when no hit_id is available.",
                },
                hit_ids = {
                    type = "array",
                    description = "Multiple hit_id values returned by search_book. Up to 4 are read in one call.",
                    items = { type = "string" },
                },
                pages = {
                    type = "array",
                    description = "Multiple page numbers to read around. Up to 4 are read in one call.",
                    items = { type = "integer" },
                },
                targets = {
                    type = "array",
                    description = "Multiple targets, each with hit_id or page. Up to 4 are read in one call.",
                    items = {
                        type = "object",
                        properties = {
                            hit_id = { type = "string" },
                            page = { type = "integer" },
                        },
                    },
                },
                before_pages = {
                    type = "integer",
                    description = "Number of pages before the target page. Defaults to 1.",
                },
                after_pages = {
                    type = "integer",
                    description = "Number of pages after the target page. Defaults to 1.",
                },
            },
        },
    },
    {
        name = "toc",
        description = "List table-of-contents entries within the readable range: at most 120 per call, in document order, out of possibly many more; total_entries is the exact count of matching entries. When the full list exceeds the cap and no max_depth is given, only the levels that fit are listed (depth_shown) so the structure survives; the note says how to go deeper. Narrow with max_depth (1 = volumes or parts) or title_contains; each entry carries its parent path. No snippets by default. Entries left out (cap, hidden sections, past the reader's position) are stated in notes.",
        parameters = {
            type = "object",
            properties = {
                max_snippet_chars = {
                    type = "integer",
                    description = "Maximum snippet length per entry. Defaults to 0 and is capped at 800.",
                },
                max_entries = {
                    type = "integer",
                    description = "Maximum number of TOC entries. Defaults to 120 (the ceiling).",
                },
                max_depth = {
                    type = "integer",
                    description = "Only entries at this depth or shallower (1 = top level).",
                },
                title_contains = {
                    type = "string",
                    description = "Only entries whose title contains this text (case-insensitive).",
                },
            },
        },
    },
}

-- Gather-phase terminator: deterministic loop exit (no answer prose to throw away).
-- Only declared in gather mode; the interactive loop keeps its detect-text termination.
local DONE_DECLARATION = {
    name = "done",
    description = "Call when you have gathered enough passages to answer the user's question, or when the question needs no book lookups.",
    parameters = {
        type = "object",
        properties = {},
    },
}

local GATHER_DECLARATIONS = {}
for _idx, spec in ipairs(FUNCTION_DECLARATIONS) do
    table.insert(GATHER_DECLARATIONS, spec)
end
table.insert(GATHER_DECLARATIONS, DONE_DECLARATION)

local function appendListItem(items, text)
    if text and text ~= "" then
        table.insert(items, "- " .. text)
    end
end

local function copyMessages(messages)
    local copy = {}
    for _idx, msg in ipairs(messages or {}) do
        table.insert(copy, ConfigHelper:deepCopy(msg))
    end
    return copy
end

-- Contents outline for the scope message: the levels that fit, one line per entry, and
-- what was left out. Sent once per session so the model's first query can start from the
-- book's shape instead of a guess.
local function outlineLines(outline)
    local lines = {}
    if type(outline) ~= "table" then return lines end
    if not outline.has_toc then
        table.insert(lines, "This book has no table of contents.")
        return lines
    end
    local shown = #(outline.entries or {})
    local levels = ""
    if outline.depth_shown and outline.deepest and outline.depth_shown < outline.deepest then
        levels = string.format(", levels 1-%d of %d", outline.depth_shown, outline.deepest)
    end
    table.insert(lines, string.format("Contents outline (%d of %d entries within the readable range%s; call toc for page ranges, deeper levels or a title filter):",
        shown, outline.total or shown, levels))
    for _idx, entry in ipairs(outline.entries or {}) do
        table.insert(lines, string.format("- %s%s (pp. %d-%d%s)",
            entry.path and (entry.path .. " > ") or "",
            entry.title or "",
            entry.start_page or 0,
            entry.end_page or 0,
            entry.continues_past_position and ", continues past the reader's position" or ""))
    end
    if (outline.omitted or 0) > 0 then
        table.insert(lines, string.format("... %d more entries at these levels are not listed here.", outline.omitted))
    end
    if (outline.past_position or 0) > 0 and outline.reading_scope ~= "full" then
        table.insert(lines, string.format("%d entries start after the reader's current position and are not listed (spoiler protection).", outline.past_position))
    end
    if (outline.hidden or 0) > 0 then
        table.insert(lines, string.format("%d entries are in sections the reader has hidden (KOReader hidden flows) and are not listed.", outline.hidden))
    end
    return lines
end

local function appendScopeMessage(messages, scope)
    if type(scope) ~= "table" then return end
    local lines = { "[Book tool scope]" }
    if scope.reading_scope == "full" then
        table.insert(lines, string.format("Current page: %s of %s",
            tostring(scope.current_page or "?"), tostring(scope.total_pages or "?")))
        table.insert(lines, string.format("You may read the entire document (pages 1-%s).",
            tostring(scope.end_page or scope.total_pages or "?")))
    else
        table.insert(lines, string.format("Current page: %s of %s",
            tostring(scope.current_page or "?"), tostring(scope.total_pages or "?")))
        table.insert(lines, string.format("Readable page range: 1-%s", tostring(scope.end_page or "?")))
        table.insert(lines, string.format("Do not request or infer content after page %s.", tostring(scope.end_page or "?")))
    end
    -- The book's language decides the search language: an English question about a
    -- German book still needs German queries, and nothing else tells the model that.
    if scope.language then
        table.insert(lines, string.format("Book text language: %s. Write search_book queries in the language of the book text, even when the reader writes in another language.",
            tostring(scope.language)))
    else
        table.insert(lines, "Write search_book queries in the language the book text is in, which may differ from the reader's.")
    end
    if scope.outline then
        table.insert(lines, "")
        for _idx, line in ipairs(outlineLines(scope.outline)) do
            table.insert(lines, line)
        end
    end
    table.insert(messages, {
        role = "user",
        content = table.concat(lines, "\n"),
        is_context = true,
    })
end

-- The scope message's language line follows the "Book text language" setting (global,
-- default off; per book or group: off / from metadata / a chosen or typed language).
-- Off or unknown sends only the rule to write queries in the text's language.
local function scopeForMessage(tools, ui, features)
    local scope = tools:getScope()
    scope.language = BookSettings.resolveBookTextLanguage(ui and ui.doc_settings, features,
        tools:getBookLanguage())
    return scope
end

-- mode: "tools" (interactive loop turn), "gather" (gather-phase turn), "final"
-- (interactive final pass — history replays tool turns, so declarations must stay).
local function buildToolConfig(config, mode, reading_scope)
    local tool_config = ConfigHelper:deepCopy(config or {})
    tool_config.features = tool_config.features or {}
    tool_config.features.enable_streaming = false
    tool_config.features.enable_web_search = false
    tool_config.enable_web_search = false

    if mode == "final" then
        -- Final pass: the message history still contains tool turns, and providers reject
        -- tool_use/tool_result replay when no tools are declared (Anthropic 400s, including
        -- via OpenRouter backends). Keep the declarations and forbid further calls via mode
        -- NONE — handlers render it as tool_choice "none" / functionCallingConfig NONE.
        tool_config.tools = {
            specs = FUNCTION_DECLARATIONS,
            mode = "NONE",
        }
    elseif mode == "gather" then
        -- ANY forces a tool call every gather round (search_book/... or done): the model
        -- can never answer in prose on the non-streamed gather path, so the final answer
        -- always comes from the streamed phase 2. Handlers render it as tool_choice
        -- any/required/functionCallingConfig ANY; prose acceptance in step_gather stays
        -- as a fallback for providers that ignore it.
        tool_config.tools = {
            specs = GATHER_DECLARATIONS,
            mode = "ANY",
        }
    else
        -- Provider-neutral tool declaration; each provider's buildRequestBody renders its format.
        tool_config.tools = {
            specs = FUNCTION_DECLARATIONS,
            mode = "AUTO",
        }
    end

    -- Append the spoiler-scope clause so the instructions match the structural clamp in BookTools.
    local spoiler_safe = reading_scope ~= "full"
    local instructions
    if mode == "final" then
        instructions = FINAL_INSTRUCTIONS .. (spoiler_safe and FINAL_NOTE_CURRENT or "")
    elseif mode == "gather" then
        instructions = GATHER_INSTRUCTIONS .. (spoiler_safe and SCOPE_NOTE_CURRENT or SCOPE_NOTE_FULL)
    else
        instructions = TOOL_INSTRUCTIONS .. (spoiler_safe and SCOPE_NOTE_CURRENT or SCOPE_NOTE_FULL)
    end
    -- Budget-aware prompt (tools_ux_plan.md §2): tell the model its total lookup budget
    -- up front so it plans (broad → narrow, deliberate done) instead of being cut off by
    -- an invisible cap. Skipped for "final" (no further calls allowed there anyway).
    if mode ~= "final" then
        local budget = budgetFor(tool_config.features)
        instructions = instructions
            .. string.format(" You may use at most %d lookups in total, across at most %d rounds.", budget.calls, budget.turns)
    end
    tool_config.system = tool_config.system or {}
    tool_config.system.text = (tool_config.system.text or "") .. instructions
    return tool_config
end

local function buildToolSettings(features, reading_scope)
    features = features or {}
    return {
        -- Consent is enforced upstream in BookToolRunner.shouldUse (requires
        -- enable_book_text_extraction, or a trusted provider) before the runner ever
        -- builds tools, so the extractor is enabled here unconditionally — this also
        -- covers the trusted-provider bypass case (extraction setting may be off).
        enable_book_text_extraction = true,
        max_book_text_chars = features.max_book_text_chars,
        max_pdf_pages = features.max_pdf_pages,
        reading_scope = reading_scope,
    }
end

-- Resolve the tool reading scope from the spoiler posture (request layer —
-- spoiler_posture_plan.md §2): the Spoiler chip's per-chat value when present
-- (true OR false, so unchecking un-clamps even while the global is on), else
-- research mode > per-book override > global. Protected → "current" (clamp to
-- reading position); otherwise → "full" (whole document).
local function resolveReadingScope(config, ui)
    local features = config and config.features or {}
    local posture = BookSettings.resolveSpoilerPosture(ui and ui.doc_settings, features,
        { session = features._spoiler_free_active })
    return posture.protected and "current" or "full"
end

-- Live spoiler line (spoiler_posture_plan.md C4 REVISED 2026-08-11, PROVISIONAL —
-- maintainer wants this model revisited): protection rides each SEND as one
-- instruction line, appended as its OWN final user message and computed from the
-- posture and reading position AT THAT MOMENT — never baked into the system
-- prompt (which stays stable for provider prefix caches) and never written into
-- MessageHistory (wire-time copy: transcript, saves and exports stay clean, and
-- lines never accumulate across replies). A running chat therefore follows the
-- reader: read on and the boundary moves with you; toggle protection and the next
-- reply obeys. Gated on features._spoiler_live, set only by
-- buildUnifiedRequestConfig for book/highlight chats whose action doesn't
-- skip_spoiler (and restored across resume via control_state) — headless,
-- background and merge traffic never carries it.
local function liveSpoilerLine(cfg, ui)
    local features = cfg and cfg.features or {}
    if features._spoiler_live ~= true then return nil end
    -- Defense in depth (2026-08-12 device log): general/library chats never
    -- get the line, whatever an upstream flag claims — the resume legacy
    -- default marked sentinel-path chats eligible for a while.
    if features.is_general_context or features.is_library_context then return nil end
    -- One-shot stand-down (spoiler-scope consent, 2026-08-17): the reader
    -- explicitly chose a beyond-position span for THIS request, so the nudge
    -- must not fight the scope it consented to. Consumed here; the next
    -- protected send re-resolves and the nudge returns.
    if features._spoiler_scope_consent then
        features._spoiler_scope_consent = nil
        return nil
    end
    local book_file = features.book_metadata and features.book_metadata.file
    local book_open = ui and ui.document
        and (not book_file or ui.document.file == book_file) or false
    local ds
    if book_open then
        ds = ui.doc_settings
    elseif book_file then
        ds = require("koassistant_doc_settings").resolve(book_file, ui)
    end
    local posture = BookSettings.resolveSpoilerPosture(ds, features,
        { session = features._spoiler_free_active })
    if not posture.protected then return nil end
    -- Privacy gate (2026-08-15 device-round audit): the reader's position is
    -- basic-stats data — with stats sharing off (and the provider untrusted)
    -- this line must NOT disclose it, exactly as extractForAction already
    -- withholds {reading_progress}. The no-progress nudge variant covers it.
    local stats_ok = features.enable_basic_stats ~= false
    if not stats_ok and cfg and cfg.provider
        and type(features.trusted_providers) == "table" then
        for _idx, p in ipairs(features.trusted_providers) do
            if p == cfg.provider then
                stats_ok = true
                break
            end
        end
    end
    local progress
    if not stats_ok then
        progress = nil
    elseif book_open then
        local rp = require("koassistant_context_extractor"):new(ui):getReadingProgress()
        progress = rp and rp.formatted
    elseif ds and ds.readSetting then
        -- Closed book: the sidecar position is current by definition (nothing can
        -- advance while the book isn't being read).
        local pf = ds:readSetting("percent_finished")
        if type(pf) == "number" and pf > 0 then
            progress = string.format("%d%%", math.floor(pf * 100 + 0.5))
        end
    end
    local Templates = require("prompts/templates")
    -- Diagnostic (device round 2026-08-12: spoiler reasoning sighted in a
    -- general chat — general/library must never reach here, _spoiler_live
    -- stays nil for them): log every ACTUAL injection so a logged round can
    -- separate our line from the model's own spoiler-awareness.
    require("koassistant_logger").dbg("KOAssistant: live spoiler line appended — progress:",
        progress or "none", "book:", book_file or (book_open and "open") or "?")
    if not progress or progress == "" or progress == "0%" then
        return Templates.SPOILER_FREE_NUDGE_NO_PROGRESS
    end
    return (Templates.SPOILER_FREE_NUDGE:gsub("{reading_progress}",
        function() return progress end))
end
BookToolRunner._liveSpoilerLine = liveSpoilerLine  -- exposed for unit tests (its siblings already are)

-- Pure decoration half, exposed for unit tests: append `line` as its OWN user
-- message at the END of a COPIED array — the originals are MessageHistory's live
-- tables and must never mutate. Own-message rather than glued into the user's
-- text, for two reasons. Caching: automatic prefix caches (OpenAI/Gemini/
-- DeepSeek) key on byte-identical history — with a standalone line every stored
-- message repeats exactly across requests and only the line's own tokens are
-- ever uncached, whereas gluing into the last user message makes that message's
-- CLEAN form (what the next request replays from history) a guaranteed miss.
-- Anthropic's cache breakpoints sit on the system block only, so message shape
-- is cache-neutral there. Separation: the user's words are never rewritten, and
-- the model reads the line as standalone scaffolding — the same wire shape the
-- Attach chip already ships on every provider (consecutive user messages are
-- established). `in_prompt` marks an action whose prompt resolved
-- {spoiler_free_nudge} in place: its FIRST request (no assistant turn yet)
-- already carries the instruction (the never-both rule), replies decorate.
function BookToolRunner.decorateSpoilerMessages(messages, line, in_prompt)
    if not line or type(messages) ~= "table" then return messages end
    local has_user, has_assistant
    for _i, m in ipairs(messages) do
        if m.role == "user" then
            has_user = true
        elseif m.role == "assistant" then
            has_assistant = true
        end
    end
    if not has_user then return messages end
    if in_prompt and not has_assistant then return messages end
    local out = {}
    for i, m in ipairs(messages) do out[i] = m end
    table.insert(out, { role = "user", content = line, is_context = true })
    return out
end

local function summarizeToolCall(call, result)
    local name = call and call.name or "tool"
    result = result or {}
    if name == "search_book" then
        local query_count = result.query_count or (result.queries and #result.queries) or 0
        local terms = {}
        if result.queries then
            for i, block in ipairs(result.queries) do
                if i > 4 then
                    table.insert(terms, "...")
                    break
                end
                -- The pages with hits (first six), so Sources & Lookups shows where the
                -- model's evidence came from even when it never read around a hit.
                local pages = {}
                for p, entry in ipairs(block.page_summary or {}) do
                    if p > 6 then
                        table.insert(pages, "...")
                        break
                    end
                    table.insert(pages, tostring(entry.page))
                end
                local where = #pages > 0 and (" on pp. " .. table.concat(pages, ", ")) or ""
                table.insert(terms, string.format("%q(%d%s)", block.query or "", block.total_hits or 0, where))
            end
        end
        local suffix = #terms > 0 and (" [" .. table.concat(terms, ", ") .. "]") or ""
        return string.format("search_book: %d quer%s, %d hit(s)%s",
            query_count,
            query_count == 1 and "y" or "ies",
            result.total_hits or 0,
            suffix)
    elseif name == "read_around" then
        if result.results then
            local ranges = {}
            for i, item in ipairs(result.results) do
                if i > 4 then break end
                local range = item.range or {}
                table.insert(ranges, string.format("%s-%s",
                    tostring(range.start_page or "?"),
                    tostring(range.end_page or "?")))
            end
            return string.format("read_around: %d target(s), pp. %s",
                result.target_count or #result.results,
                table.concat(ranges, ", "))
        else
            local range = result.range or {}
            return string.format("read_around: pp. %s-%s", tostring(range.start_page or "?"), tostring(range.end_page or "?"))
        end
    elseif name == "toc" then
        local args = type(call.args) == "table" and call.args or {}
        local filters = {}
        if type(args.title_contains) == "string" and args.title_contains ~= "" then
            table.insert(filters, string.format("title contains %q", args.title_contains))
        end
        if tonumber(args.max_depth) then
            table.insert(filters, string.format("depth <= %d", tonumber(args.max_depth)))
        end
        return string.format("toc: %d entries%s", result.entry_count or 0,
            #filters > 0 and (" (" .. table.concat(filters, ", ") .. ")") or "")
    end
    return name
end

local function appendTrace(answer, trace)
    if type(answer) ~= "string" or #trace == 0 then return answer end
    local lines = { "", "---", "**Lookups used:**" }
    for _idx, item in ipairs(trace) do
        appendListItem(lines, item)
    end
    return answer .. "\n" .. table.concat(lines, "\n")
end

-- Notes ride the result table (the JSON the model sees during the rounds); the bundle
-- prints them too so phase 2 inherits every disclosure.
local function noteLines(lines, notes, indent)
    for _idx, note in ipairs(notes or {}) do
        table.insert(lines, (indent or "  ") .. "note: " .. tostring(note))
    end
end

local function formatToolResultText(name, result)
    result = result or {}  -- defensive, mirrors summarizeToolCall (BookTools:execute always returns a table)
    if result.ok == false then
        -- A failed call must never render as a legitimate zero-hit result — "0 hits"
        -- reads as evidence of absence to the model, not as tool failure.
        return string.format("%s: lookup failed — %s", name, tostring(result.error or "unknown error"))
    end
    if name == "search_book" then
        local query_count = result.query_count or (result.queries and #result.queries) or 0
        local lines = {}
        noteLines(lines, result.notes)
        if result.queries then
            for q_index, block in ipairs(result.queries) do
                table.insert(lines, string.format("  [q%d %q] %d hit(s) across %d page(s)",
                    q_index,
                    block.query or "",
                    block.total_hits or 0,
                    block.matching_pages or 0))
                noteLines(lines, block.notes, "    ")
                local page_lines = {}
                if block.page_summary then
                    for i, page in ipairs(block.page_summary) do
                        if i > 20 then
                            table.insert(page_lines, string.format("... %d more page(s)", #block.page_summary - 20))
                            break
                        end
                        table.insert(page_lines, string.format("p%d:%d", page.page or 0, page.count or 0))
                    end
                end
                if #page_lines > 0 then
                    table.insert(lines, "    pages: " .. table.concat(page_lines, ", "))
                end
                if block.results then
                    for i, hit in ipairs(block.results) do
                        if i > 12 then
                            table.insert(lines, string.format("    ... %d more hit(s)", #block.results - 12))
                            break
                        end
                        local missing = ""
                        if type(hit.missing) == "table" and #hit.missing > 0 then
                            missing = ", missing: " .. table.concat(hit.missing, " ")
                        end
                        table.insert(lines, string.format("    [%s, p%d, %s%s] %s",
                            hit.hit_id or "?",
                            hit.page or 0,
                            hit.match_type or "?",
                            missing,
                            hit.snippet or ""))
                    end
                end
            end
        end
        local header = string.format("search_book: %d quer%s, %d total hit(s)",
            query_count,
            query_count == 1 and "y" or "ies",
            result.total_hits or 0)
        if #lines > 0 then
            return header .. "\n" .. table.concat(lines, "\n")
        end
        return header
    elseif name == "read_around" then
        if result.results then
            local lines = { string.format("read_around: %d targets", result.target_count or #result.results) }
            noteLines(lines, result.notes)
            for _idx, item in ipairs(result.results) do
                local range = item.range or {}
                noteLines(lines, item.notes)
                table.insert(lines, string.format("  [%s, pp. %s-%s] %s",
                    item.hit_id or ("p" .. tostring(item.page or "?")),
                    tostring(range.start_page or "?"),
                    tostring(range.end_page or "?"),
                    item.text or ""))
            end
            return table.concat(lines, "\n")
        else
            local range = result.range or {}
            local lines = { string.format("read_around: pp. %s-%s",
                tostring(range.start_page or "?"),
                tostring(range.end_page or "?")) }
            noteLines(lines, result.notes)
            table.insert(lines, "  " .. (result.text or ""))
            return table.concat(lines, "\n")
        end
    elseif name == "toc" then
        local lines = {}
        noteLines(lines, result.notes)
        if result.entries then
            for _idx, entry in ipairs(result.entries) do
                local snippet = entry.snippet and #entry.snippet > 0 and (": " .. entry.snippet) or ""
                table.insert(lines, string.format("  %s%s (pp. %d-%d%s)%s",
                    entry.path and (entry.path .. " > ") or "",
                    entry.title or "",
                    entry.start_page or 0,
                    entry.end_page or 0,
                    entry.continues_past_position and ", continues past the reader's position" or "",
                    snippet))
            end
        end
        local header = string.format("toc: %d entries", result.entry_count or 0)
        if #lines > 0 then
            return header .. "\n" .. table.concat(lines, "\n")
        end
        return header
    end
    return name .. ": " .. tostring(result)
end

local function truncateSection(text, max_chars)
    if type(text) ~= "string" or max_chars <= 0 or #text <= max_chars then
        return text
    end
    return ScopeResolver.utf8Head(text, max_chars - 3) .. "..."
end

-- Every distinct note the session's tool results carried (result, per-query block and
-- per-target levels), in first-seen order. Phase 2 is a normal request with the original
-- system prompt, so the notes must ride the context block itself to reach the answer.
-- The notes worth relaying to the reader: parts of the book a lookup could not reach,
-- and lookups that could not run (error blocks). Routine caps (BookTools.isRoutineNote)
-- stay in the tool results the model already read.
local function collectNotes(tool_outputs)
    local notes, seen = {}, {}
    local function take(list)
        for _idx, note in ipairs(list or {}) do
            if type(note) == "string" and not seen[note] and not BookTools.isRoutineNote(note) then
                seen[note] = true
                table.insert(notes, note)
            end
        end
    end
    for _idx, output in ipairs(tool_outputs or {}) do
        for _jdx, item in ipairs(output.executed or {}) do
            local result = item.result
            if type(result) == "table" then
                take(result.notes)
                if type(result.error) == "string" then take({ result.error }) end
                for _kdx, block in ipairs(result.queries or {}) do
                    take(block.notes)
                    if type(block.error) == "string" then take({ block.error }) end
                end
                for _kdx, target in ipairs(result.results or {}) do
                    if type(target) == "table" then take(target.notes) end
                end
            end
        end
    end
    return notes
end
BookToolRunner._collectNotes = collectNotes  -- exposed for unit tests
BookToolRunner._summarizeToolCall = summarizeToolCall  -- exposed for unit tests

local LOOKUP_LIMITS_HEADER = "[Lookup limits]\nParts of the book the lookups above could not reach:"
local LOOKUP_LIMITS_FOOTER = "Mention this in one plain sentence at the end of your answer only where it could change the answer (a part of the book out of reach, a lookup that could not run); otherwise say nothing about the lookups. Never fill such a gap from memory or the web without saying that the book itself was not consulted for it."

local function lookupLimitsBlock(tool_outputs)
    local notes = collectNotes(tool_outputs)
    if #notes == 0 then return nil end
    local lines = { LOOKUP_LIMITS_HEADER }
    for _idx, note in ipairs(notes) do
        table.insert(lines, "- " .. note)
    end
    table.insert(lines, LOOKUP_LIMITS_FOOTER)
    return table.concat(lines, "\n")
end
BookToolRunner._lookupLimitsBlock = lookupLimitsBlock  -- exposed for unit tests

-- Gather mode: assemble the phase-2 context bundle from the session's tool results.
-- Chronological; identical formatted sections deduplicate (repeated identical lookups
-- collapse); FAILED calls (ok == false) are skipped entirely — plan §4: keep the partial
-- bundle, and an all-failures session leaves the bundle empty so the honest "no relevant
-- passages" note fires instead. Capped to bundle_chars (from the lookup-effort budget):
-- an overflowing section is truncated into the remaining budget (a single batched
-- read_around can exceed the whole cap — dropping it whole could empty the bundle),
-- later ones get an omission note so truncation never reads as full coverage.
local function buildGatherBundle(tool_outputs, bundle_chars)
    local sections = {}
    local seen = {}
    local total = 0
    local omitted = 0
    for _idx, output in ipairs(tool_outputs or {}) do
        for _jdx, item in ipairs(output.executed or {}) do
            if type(item.result) == "table" and item.result.ok == false then
                -- skip failed calls (the error text still reaches diagnostics via
                -- formatToolResultText's error branch in appendVerboseToolOutput)
            else
                local section = formatToolResultText(item.call.name, item.result)
                if type(section) == "string" and #section > 0 and not seen[section] then
                    seen[section] = true
                    local remaining = bundle_chars - total
                    if #section <= remaining then
                        table.insert(sections, section)
                        total = total + #section
                    elseif remaining > 500 then
                        table.insert(sections, truncateSection(section, remaining)
                            .. "\n(this result was cut here to fit the context bundle)")
                        total = bundle_chars
                    else
                        omitted = omitted + 1
                    end
                end
            end
        end
    end
    if omitted > 0 then
        table.insert(sections, string.format("(%d further tool result(s) omitted — bundle size limit)", omitted))
    end
    return table.concat(sections, "\n\n")
end

local function appendVerboseToolOutput(answer, tool_outputs)
    if not VERBOSE_TOOL_OUTPUT or type(answer) ~= "string" or #tool_outputs == 0 then
        return answer
    end

    local lines = { "", "---", "**Tool results sent to model:**", "",
        string.format("(each section truncated to %d chars; verbose preview only)", VERBOSE_SECTION_MAX_CHARS) }
    for i, output in ipairs(tool_outputs) do
        table.insert(lines, "")
        table.insert(lines, string.format("Turn %d:", i))
        for _idx, item in ipairs(output.executed or {}) do
            local section = formatToolResultText(item.call.name, item.result)
            table.insert(lines, truncateSection(section, VERBOSE_SECTION_MAX_CHARS))
        end
    end
    return answer .. "\n" .. table.concat(lines, "\n")
end

local function mergeUsage(total, usage)
    if type(usage) ~= "table" then return total end
    total = total or { _call_count = 0 }
    total._call_count = total._call_count + 1

    local fields = {
        "input_tokens",
        "output_tokens",
        "total_tokens",
        "cache_read",
        "cache_creation",
        "reasoning_tokens",
    }
    for _idx, field in ipairs(fields) do
        if type(usage[field]) == "number" then
            total[field] = (total[field] or 0) + usage[field]
        end
    end

    if not usage.total_tokens then
        local computed = (usage.input_tokens or 0) + (usage.output_tokens or 0) + (usage.reasoning_tokens or 0)
        if computed > 0 then
            total.total_tokens = (total.total_tokens or 0) + computed
        end
    end

    return total
end

local function formatTurnUsage(usage)
    if type(usage) ~= "table" then
        return "unavailable"
    end

    local parts = {}
    if usage.input_tokens then
        table.insert(parts, string.format("%d input", usage.input_tokens))
    end
    if usage.output_tokens then
        table.insert(parts, string.format("%d output", usage.output_tokens))
    end
    if usage.reasoning_tokens and usage.reasoning_tokens > 0 then
        table.insert(parts, string.format("%d thinking", usage.reasoning_tokens))
    end
    if usage.cache_read and usage.cache_read > 0 then
        table.insert(parts, string.format("%d cache_read", usage.cache_read))
    end
    if usage.cache_creation and usage.cache_creation > 0 then
        table.insert(parts, string.format("%d cache_write", usage.cache_creation))
    end

    local text = usage.total_tokens and string.format("%d total tokens", usage.total_tokens)
        or DebugUtils.formatUsage(usage)
    if usage.total_tokens and #parts > 0 then
        text = text .. " (" .. table.concat(parts, ", ") .. ")"
    end
    if text == "" then
        text = "unavailable"
    end

    if usage._call_count and usage._call_count > 0 then
        local call_label = usage._call_count == 1 and "API call" or "API calls"
        text = text .. string.format(" across %d %s", usage._call_count, call_label)
    end
    return text
end

local function appendTurnTokenUsage(answer, usage)
    if not SHOW_TURN_TOKEN_USAGE or type(answer) ~= "string" then
        return answer
    end
    return answer .. "\n\n---\n**Total token usage this turn:** " .. formatTurnUsage(usage)
end

-- Tools read book text, so a trusted provider bypasses the extraction-consent gate
-- (mirrors ContextExtractor:isProviderTrusted — features.trusted_providers vs the active provider).
local function isProviderTrusted(provider, features)
    if not provider then return false end
    for _idx, trusted_id in ipairs(features.trusted_providers or {}) do
        if trusted_id == provider then return true end
    end
    return false
end

-- Session-level eligibility: everything shouldUse checks EXCEPT the activation decision
-- (global flag / session checkbox) and the context flags. Used by the input dialog to
-- decide whether the per-chat "Book tools" checkbox is worth showing at all (it gates
-- context itself); capability + adapter + extraction consent + open document.
-- Returns eligible:boolean and, when false, a reason: "provider" (no tools capability /
-- wire adapter), "consent" (no text-extraction consent), or "no_book". The reason lets
-- UI callers (the smart-retrieval popup row) explain a grayed option; boolean-only
-- callers are unaffected.
function BookToolRunner.sessionEligible(config, ui)
    local features = config and config.features or {}
    -- The tools search the OPEN book: a request about another book (a chat
    -- started from a Book Hub or a group hub while this one is open) has
    -- nothing here to search, whatever the open book's settings say (B387)
    local target = features.book_metadata and features.book_metadata.file
    if target and ui and ui.document and ui.document.file
            and target ~= ui.document.file then
        return false, "no_book"
    end
    local provider = config and (config.provider or config.default_provider)
    -- Provider/model must support function calling AND have a tool_wire adapter; otherwise
    -- fall through to the normal (whole-context) path. Generalizes the old gemini-only gate.
    local model = config and ConfigHelper:getModelInfo(config)
    if not (ModelConstraints.supportsCapability(provider, model, "tools") and ToolWire.hasAdapter(provider)) then
        return false, "provider"
    end
    -- Tools are a form of book-text extraction → respect the consent gate
    -- (trusted bypass); the per-book privacy override wins in both directions
    -- (deny beats trusted).
    local consent = features.enable_book_text_extraction == true
        or isProviderTrusted(provider, features)
    if ui and ui.doc_settings then
        local ov = BookSettings.effectivePrivacyOverrides(ui.doc_settings).book_text
        if ov ~= nil then consent = ov end
    end
    if not consent then
        return false, "consent"
    end
    if ui == nil or ui.document == nil then
        return false, "no_book"
    end
    return true
end

-- D3 smart retrieval gate (tools_ux_plan.md §4): allowed when the session could
-- run tools. The old posture-off master switch is gone (binary collapse
-- 2026-08-12 — Off is a chip DEFAULT, not a hard kill), so this is now a thin
-- alias of sessionEligible kept for its call sites and reason strings:
-- "provider" | "consent" | "no_book".
function BookToolRunner.smartRetrievalAllowed(config, ui)
    return BookToolRunner.sessionEligible(config, ui)
end

function BookToolRunner.shouldUse(config, ui)
    local features = config and config.features or {}
    -- Activation: the per-chat checkbox (features._tools_active, explicit true/false set at
    -- Send) wins when present; otherwise the global experimental flag is the default.
    -- (D1 — gather_then_generate_plan.md)
    local active
    if features._tools_active ~= nil then
        active = features._tools_active == true
    else
        -- Non-dialog paths (e.g. resumed chats, whose Send transients are cleared):
        -- follow the effective default — the same derivation as the chip's
        -- initial state, so the two never disagree. ui.doc_settings is the OPEN book's
        -- live instance (read-only here); tools only ever run against the open book
        -- (sessionEligible requires ui.document).
        active = BookSettings.resolveBookTools(ui and ui.doc_settings, features)
    end
    if not active then return false end
    if not BookToolRunner.sessionEligible(config, ui) then return false end
    return features.is_library_context ~= true
        and features.is_general_context ~= true
        and features._xray_chat_active ~= true
end

-- Convenience wrapper: route through BookToolRunner.run when shouldUse is true,
-- otherwise call query_fn directly. Lets all chat reply paths share one call site
-- without each caller knowing about the runner.
function BookToolRunner.queryWith(query_fn, messages, cfg, callback, plugin, ui)
    -- ⚡ quick-answer retry (input safety net S3): the stream's ⚡ button makes
    -- queryChatGPT call back with the sentinel err. Intercept it here — this layer owns
    -- `cfg`, the caller's send-site config, which the answer's on_complete uses for chat
    -- attribution AND which the viewer adopts for replies. Rebuild THAT config IN PLACE
    -- with quick posture (reasoning off / web off / tools off / preset model, via the
    -- shared, tested applyQuickReplyOverrides) and re-run, so the fast answer is correctly
    -- attributed and quick persists on replies. tools-off makes the re-run a plain send.
    -- Works for BOTH gather (the sentinel propagates up through run()'s finish) and direct.
    local function wrapped(success, answer, err, ...)
        if err == require("koassistant_constants").QUICK_RETRY_SENTINEL then
            cfg.features = cfg.features or {}
            cfg.features._session_quick_answer = true
            cfg.features._quick_reply_orig = nil  -- fresh baseline for the transform
            -- OFF->ON = fresh preset application (A9 (b) invariant): stale
            -- input-dialog pins must not keep web/tools alive on the quick retry
            cfg.features._session_web_touched = nil
            cfg.features._session_tools_touched = nil
            require("koassistant_dialogs").applyQuickReplyOverrides(cfg, plugin)
            return BookToolRunner.queryWith(query_fn, messages, cfg, callback, plugin, ui)
        end
        return callback(success, answer, err, ...)
    end
    -- Live spoiler line: decorate a COPY per attempt — the ⚡ retry recursion above
    -- re-enters with the caller's original array, so every attempt carries exactly
    -- one line, current as of that send.
    local send_messages = BookToolRunner.decorateSpoilerMessages(messages,
        liveSpoilerLine(cfg, ui),
        cfg and cfg.features and cfg.features._spoiler_in_prompt)
    if BookToolRunner.shouldUse(cfg, ui) then
        return BookToolRunner.run({
            query_fn = query_fn,
            messages = send_messages,
            config = cfg,
            settings = plugin and plugin.settings,
            ui = ui,
            on_complete = wrapped,
        })
    end
    return query_fn(send_messages, cfg, wrapped, plugin and plugin.settings)
end

-- Whole-text path (docs/tool_based_context_plan.md 9.6 step 0, the "if it fits, put it
-- in the prompt" rule): when the readable text is no longer than the effort's
-- whole_chars, the gather skips its rounds and phase 2 gets the text itself. A search
-- over a 20-page range hands the model 12 snippets of a text it could simply read.
-- Returns nil (search as usual) when the text overflows, is empty, or the setting is off.
-- Size first, text second. Pages are screens, so bytes per page are roughly constant
-- within a book: three sampled pages spread through the range give an estimate, and a
-- range that is clearly over budget is skipped without extracting it. (The first
-- version asked the extractor for the whole range with a size cap; it extracts the
-- entire range and truncates afterwards, which froze the device on an 18k-page book.)
-- A range that plausibly fits is then extracted page by page with an early exit, and
-- that extraction IS the payload, so nothing is done twice beyond the three samples.
local WHOLE_TEXT_SAMPLE_PAGES = 3
local WHOLE_TEXT_ESTIMATE_SLACK = 1.5  -- skip when the estimate exceeds this times the budget

local function estimateReadableBytes(tools, end_page, limit)
    if end_page <= WHOLE_TEXT_SAMPLE_PAGES * 2 then return 0 end  -- too small to bother
    local sampled, count = 0, 0
    for i = 1, WHOLE_TEXT_SAMPLE_PAGES do
        local page = math.floor(end_page * (i - 0.5) / WHOLE_TEXT_SAMPLE_PAGES)
        page = math.max(1, math.min(end_page, page))
        local ok, text = pcall(tools.getPageText, tools, page, limit + 1)
        if ok and type(text) == "string" then
            sampled = sampled + #text
            count = count + 1
        end
    end
    if count == 0 then return 0 end
    return sampled / count * end_page
end

local function wholeReadableText(tools, features, budget)
    if (features or {}).tool_whole_text == false then return nil end
    local scope = tools:getScope()
    local end_page = tonumber(scope.end_page)
    if not end_page or end_page < 1 then return nil end
    local limit = budget.whole_chars
    if estimateReadableBytes(tools, end_page, limit) > limit * WHOLE_TEXT_ESTIMATE_SLACK then
        return nil
    end
    local parts = {}
    local total = 0
    for page = 1, end_page do
        -- limit + 1 so an oversized single page is seen as such (the default per-page
        -- extraction cap would hide it).
        local ok, text = pcall(tools.getPageText, tools, page, limit + 1)
        if not ok then return nil end
        if type(text) == "string" and text ~= "" then
            total = total + #text + 2
            if total > limit then return nil end
            table.insert(parts, text)
        end
    end
    local text = table.concat(parts, "\n\n"):gsub("^%s+", ""):gsub("%s+$", "")
    if #text == 0 then return nil end
    return {
        text = text,
        chars = #text,
        end_page = end_page,
        total_pages = scope.total_pages,
        reading_scope = scope.reading_scope,
    }
end

local function wholeTextRangeLine(whole)
    if whole.reading_scope ~= "full" and whole.total_pages and whole.end_page < whole.total_pages then
        return string.format("Pages 1-%d of %d, up to the reader's current position; spoiler protection keeps the later pages out of reach, so say so if the question needs them.",
            whole.end_page, whole.total_pages)
    end
    return string.format("Pages 1-%d, the whole book.", whole.end_page)
end

local function wholeTextBlock(whole)
    return "[The book's readable text, in full]\n" .. wholeTextRangeLine(whole) .. "\n\n" .. whole.text
end

local function wholeTextTraceLine(whole)
    return string.format("read the readable text in full: pp. 1-%d of %d (%d chars)",
        whole.end_page, whole.total_pages or whole.end_page, whole.chars)
end

-- Execute a turn's tool calls in order, then opts.on_done(executed, saw_done). search_book
-- runs off the UI thread (BookTools.executeAsync); while its child runs the kill sits in
-- opts.cancel_slot, so the status window's Stop/Skip/Quick keep their semantics, and
-- opts.on_cancelled stands in for the killed round's callback (it must apply the same
-- guards). Without a status window an InfoMessage shows the wait; a tap on it cancels.
-- opts.on_wait(seconds|nil) reports the elapsed search time (nil = the search ended).
local function runToolCalls(tools, calls, opts)
    local executed = {}
    local saw_done = false
    local index = 0
    local next_call
    next_call = function()
        index = index + 1
        local call = calls[index]
        if not call then return opts.on_done(executed, saw_done) end
        if opts.skip_done and call.name == "done" then
            saw_done = true
            return next_call()
        end
        if opts.on_call then opts.on_call(call) end
        local cancelled = false
        local wait_box = nil
        local function closeWait()
            if wait_box then
                local box = wait_box
                wait_box = nil
                box.dismiss_callback = nil  -- fires on any close, programmatic included
                pcall(function() require("ui/uimanager"):close(box) end)
            end
        end
        local cancel = tools:executeAsync(call.name, call.args or {}, function(result)
            if cancelled then return end
            if opts.cancel_slot then opts.cancel_slot.cancel = nil end
            closeWait()
            if opts.on_wait then opts.on_wait(nil) end
            table.insert(executed, { call = call, result = result })
            if opts.on_result then opts.on_result(call, result) end
            return next_call()
        end, function(seconds)
            if not cancelled and opts.on_wait then opts.on_wait(seconds) end
        end)
        if cancel then
            local function kill()
                if cancelled then return end
                cancelled = true
                pcall(cancel)
                closeWait()
                if opts.on_wait then opts.on_wait(nil) end
                opts.on_cancelled()
            end
            if opts.cancel_slot then
                opts.cancel_slot.cancel = kill
            end
            if not opts.has_status then
                local ok, InfoMessage = pcall(require, "ui/widget/infomessage")
                if ok and InfoMessage then
                    local ok2, box = pcall(InfoMessage.new, InfoMessage, {
                        text = _("Searching the book…\nTap to stop."),
                        dismiss_callback = function()
                            wait_box = nil
                            if opts.cancel_slot and opts.cancel_slot.cancel then
                                local slot_cancel = opts.cancel_slot.cancel
                                opts.cancel_slot.cancel = nil
                                slot_cancel()
                            else
                                kill()
                            end
                        end,
                    })
                    if ok2 and box then
                        wait_box = box
                        pcall(function() require("ui/uimanager"):show(box) end)
                    end
                end
            end
        end
    end
    next_call()
end

function BookToolRunner.run(params)
    params = params or {}
    BookToolRunner._cancelled = false
    BookToolRunner._skip_gather = false
    BookToolRunner._quick_retry_requested = false
    local query_fn = params.query_fn
    local on_complete = params.on_complete
    if not query_fn then
        if on_complete then on_complete(false, nil, "Book tool runner missing query function") end
        return nil
    end

    local messages = copyMessages(params.messages)
    local config = params.config or {}
    local features = config.features or {}
    local provider = config.provider or config.default_provider
    local reading_scope = resolveReadingScope(config, params.ui)
    local tools = BookTools:new(params.ui, buildToolSettings(features, reading_scope))
    appendScopeMessage(messages, scopeForMessage(tools, params.ui, features))
    local trace = {}
    local tool_outputs = {}
    local token_usage = nil
    local tool_turns = 0
    local tool_calls = 0
    local budget = budgetFor(features)
    local completed = false
    local gather_mode = (features.tool_mode or "gather") == "gather"
    -- Gather only: the interactive loop has no phase 2 to hand the text to.
    local whole_text = gather_mode and wholeReadableText(tools, features, budget) or nil
    if whole_text then trace = { wholeTextTraceLine(whole_text) } end

    -- Gather-phase status window (streamed sessions only): one dialog that ticks per
    -- lookup round; closed before phase 2, whose normal stream dialog takes its place.
    local status_handle
    local search_wait = nil  -- elapsed seconds of the running search child, for the window
    -- Cancel handle for the in-flight non-streaming request while its loading dialog is
    -- suppressed (the status window replaces it). Filled by handleNonStreamingBackground
    -- via config._register_cancel; consumed by the status window's Stop.
    local cancel_slot = {}

    local function closeStatus()
        if status_handle then
            status_handle.close()
            status_handle = nil
        end
    end

    local function updateStatus()
        if not status_handle then return end
        -- Header + counter are translated; the per-lookup trace lines below are raw
        -- summarizeToolCall output (tool names + numbers — treated as technical content,
        -- same exemption as debug strings).
        local counter = tool_calls == 1 and _("1 lookup so far")
            or T(_("%1 lookups so far"), tool_calls)
        local lines = { _("Searching the book…"), counter, "" }
        for _idx, item in ipairs(trace) do
            table.insert(lines, "• " .. item)
        end
        if search_wait then
            table.insert(lines, "")
            table.insert(lines, T(_("Searching the book text… %1 s"), search_wait))
        end
        status_handle.setText(table.concat(lines, "\n"))
    end

    local function finish(success, answer, err, reasoning, web_search_used)
        if completed then return end
        completed = true
        closeStatus()
        if success and type(answer) == "string" then
            -- The lookups trace, the raw tool-result dump (may contain book-text snippets),
            -- and the token-usage footer are developer diagnostics for the experimental tools:
            -- emit only behind their own opt-in (NOT show_debug_in_chat — that's the general
            -- debug section). Off by default → clean answers.
            if config.features and config.features.tool_workflow_diagnostics == true then
                answer = appendTrace(answer, trace)
                answer = appendVerboseToolOutput(answer, tool_outputs)
                answer = appendTurnTokenUsage(answer, token_usage)
            end
        end
        -- Fold book-tool lookups into the provenance slot (5th arg): the per-message
        -- "Searched the book" indicator + the "Show Sources" viewer read it from the
        -- saved message, replacing the old note baked into the answer text.
        local provenance = web_search_used
        if success and (tool_calls > 0 or whole_text) then
            if type(provenance) ~= "table" then
                provenance = provenance and { web_search = true } or {}
            end
            provenance.book_tools = { lookups = tool_calls, trace = trace,
                whole_text = whole_text and true or nil }
        end
        if on_complete then
            on_complete(success, answer, err, reasoning, provenance)
        end
    end

    local function requestFinal()
        local final_config = buildToolConfig(config, "final", reading_scope)
        final_config.features.loading_message = _("Book tools\nPreparing answer...")
        table.insert(messages, {
            role = "user",
            content = "Answer the user's question using the gathered tool results. Do not call more tools.",
        })
        return query_fn(messages, final_config, function(success, answer, err, reasoning, web_search_used, usage)
            token_usage = mergeUsage(token_usage, usage)
            finish(success, answer, err, reasoning, web_search_used)
        end, params.settings)
    end

    -- Gather phase 2: a NORMAL request (streaming and web search per the user's settings)
    -- built from the ORIGINAL history — no tool turns to replay, so no tools declaration —
    -- with the gathered passages injected as a context block before the user's question.
    local function startGenerate()
        closeStatus()
        local gen_messages = copyMessages(params.messages)
        local bundle = buildGatherBundle(tool_outputs, budget.bundle_chars)
        local context_text
        local limits = lookupLimitsBlock(tool_outputs)
        if whole_text then
            context_text = wholeTextBlock(whole_text)
        elseif bundle and #bundle > 0 then
            context_text = "[Passages retrieved from the book for this question]\n" .. bundle
            if limits then context_text = context_text .. "\n\n" .. limits end
        elseif tool_calls > 0 then
            -- Lookups ran but returned nothing usable: say so honestly instead of letting
            -- the model imply it read the text (same spirit as {text_fallback_nudge}).
            -- When phase 2 has web search available, say so — "answer from general
            -- knowledge" alone reads as an instruction NOT to search.
            local web_available
            if config.enable_web_search ~= nil then
                web_available = config.enable_web_search == true
            else
                web_available = features.enable_web_search == true
            end
            web_available = web_available
                and ModelConstraints.supportsWebSearch(provider, config.model)
            if web_available then
                context_text = "[Book lookup note]\nBook lookups found no relevant passages for this question. Search the web if that would help answer it; otherwise answer from the conversation and general knowledge, and say so when the book text would have been needed."
            else
                context_text = "[Book lookup note]\nBook lookups found no relevant passages for this question. Answer from the conversation and general knowledge, and say so when the book text would have been needed."
            end
            if limits then context_text = context_text .. "\n\n" .. limits end
        else
            -- No lookups at all (the model called done at once, or the reader skipped
            -- them). Phase 2 is a normal request that knows nothing about the tools, so
            -- an answer about the book's content would read as if the text were checked.
            -- Say what was within reach and ask for the disclosure only when it applies.
            local scope = tools:getScope()
            local range = ""
            if scope.reading_scope ~= "full" and scope.end_page and scope.total_pages
                and scope.end_page < scope.total_pages then
                range = string.format(" Only pages 1-%d of %d were within reach (the reader's current position; spoiler protection).",
                    scope.end_page, scope.total_pages)
            end
            context_text = "[Book lookup note]\nThe book text was not consulted for this question: no lookups were made."
                .. range
                .. " If your answer describes what this book says, state that it comes from general knowledge and not from the text; a question that does not concern the book's content needs no such note."
        end
        if context_text then
            local insert_at = #gen_messages + 1
            for i = #gen_messages, 1, -1 do
                local msg = gen_messages[i]
                if msg.role == "user" and not msg.is_context then
                    insert_at = i
                    break
                end
            end
            table.insert(gen_messages, insert_at, {
                role = "user",
                content = context_text,
                is_context = true,
            })
        end
        local gen_config = ConfigHelper:deepCopy(config)
        gen_config.tools = nil
        return query_fn(gen_messages, gen_config, function(success, answer, err, reasoning, web_search_used, usage)
            if completed then return end
            token_usage = mergeUsage(token_usage, usage)
            -- The "Searched the book — N lookups" trust signal is no longer appended to
            -- the answer text: finish() folds the lookups into the provenance slot and
            -- the chat view renders it as a per-message indicator (keeps saved answers
            -- and exports clean).
            finish(success, answer, err, reasoning, web_search_used)
        end, params.settings)
    end

    local step_gather
    step_gather = function()
        if completed then return nil end
        if BookToolRunner._cancelled then
            finish(false, nil, _("Request cancelled by user."))
            return nil
        end
        if tool_turns >= budget.turns or tool_calls >= budget.calls then
            -- Budget exhausted = gathered enough; generate from what we have.
            return startGenerate()
        end

        local tool_config = buildToolConfig(config, "gather", reading_scope)
        tool_config.features.loading_message = tool_turns == 0
            and _("Book tools\nThinking...")
            or _("Book tools\nReading...")
        if status_handle then
            tool_config.features._suppress_loading_dialog = true
        end
        tool_config._register_cancel = function(cancel_fn)
            cancel_slot.cancel = cancel_fn
        end

        return query_fn(messages, tool_config, function(success, answer, err, reasoning, web_search_used, usage)
            cancel_slot.cancel = nil
            -- A round parked behind NetworkMgr:runWhenConnected can fire AFTER Stop
            -- already finished the run — bail before doing any work with its result.
            if completed then return end
            token_usage = mergeUsage(token_usage, usage)
            -- Skip pressed: on_skip already dispatched startGenerate(); this round's
            -- result (usually the skip-cancel failure) must neither finish() the run
            -- nor recurse into another lookup round.
            if BookToolRunner._skip_gather then return end
            -- Quick pressed: on_quick already finish()ed with the retry sentinel; the
            -- dead round's cancel-failure must not touch the run (defends against a
            -- cancel that fires the callback synchronously, before finish set completed).
            if BookToolRunner._quick_retry_requested then return end
            if not success then
                finish(false, nil, err, reasoning, web_search_used)
                return
            end

            if type(answer) ~= "table" or answer._tool_calls ~= true then
                -- The model answered as prose instead of gathering (provider ignored the
                -- gather protocol). Accept it — same outcome as interactive mode; discarding
                -- and regenerating would double-bill the turn.
                finish(true, answer, nil, reasoning, web_search_used)
                return
            end

            local calls = answer.calls or {}
            if #calls == 0 then
                finish(false, nil, _("Model returned an empty tool call"))
                return
            end

            tool_turns = tool_turns + 1

            return runToolCalls(tools, calls, {
                skip_done = true,
                cancel_slot = cancel_slot,
                has_status = status_handle ~= nil,
                on_call = function() tool_calls = tool_calls + 1 end,
                on_result = function(call, result)
                    table.insert(trace, summarizeToolCall(call, result))
                    updateStatus()
                end,
                on_wait = function(seconds)
                    search_wait = seconds
                    updateStatus()
                end,
                on_cancelled = function()
                    -- Same guards as the round callback above: Skip and Quick set their
                    -- flags before killing the search and continue on their own.
                    if completed or BookToolRunner._skip_gather or BookToolRunner._quick_retry_requested then return end
                    finish(false, nil, _("Request cancelled by user."))
                end,
                on_done = function(executed, saw_done)
                    if completed or BookToolRunner._skip_gather or BookToolRunner._quick_retry_requested then return end
                    if #executed > 0 then
                        table.insert(tool_outputs, { executed = executed })
                    end

                    if saw_done then
                        -- done terminates the phase; this turn is never replayed (phase 2
                        -- starts from the original history), so unanswered echoed calls
                        -- can't 400.
                        return startGenerate()
                    end

                    if #executed > 0 then
                        -- Budget-aware prompt (tools_ux_plan.md §2): the round's last
                        -- result table carries the remaining budget — stringifyResult
                        -- JSON-encodes the table verbatim, so this reaches the model on
                        -- every provider. The bundle and diagnostics formatters read named
                        -- fields, so it never leaks to the user.
                        local last_result = executed[#executed].result
                        if type(last_result) == "table" then
                            last_result.lookup_budget = string.format("%d of %d lookups remaining",
                                math.max(0, budget.calls - tool_calls), budget.calls)
                        end
                        -- Keep the gather conversation going in the provider's native wire shape.
                        ToolWire.appendToolTurn(provider, messages, answer.raw_assistant_turn, executed)
                    end
                    updateStatus()
                    return step_gather()
                end,
            })
        end, params.settings)
    end

    local step
    step = function()
        if completed then return nil end
        if BookToolRunner._cancelled then
            finish(false, nil, _("Request cancelled by user."))
            return nil
        end
        if tool_turns >= budget.turns or tool_calls >= budget.calls then
            return requestFinal()
        end

        local tool_config = buildToolConfig(config, "tools", reading_scope)
        tool_config.features.loading_message = tool_turns == 0
            and _("Book tools\nThinking...")
            or _("Book tools\nReading...")

        return query_fn(messages, tool_config, function(success, answer, err, reasoning, web_search_used, usage)
            if completed then return end
            token_usage = mergeUsage(token_usage, usage)
            if not success then
                finish(false, nil, err, reasoning, web_search_used)
                return
            end

            if type(answer) ~= "table" or answer._tool_calls ~= true then
                finish(true, answer, nil, reasoning, web_search_used)
                return
            end

            local calls = answer.calls or {}
            if #calls == 0 then
                finish(false, nil, _("Model returned an empty tool call"))
                return
            end

            tool_turns = tool_turns + 1

            -- Execute EVERY call in this turn: each tool_use must get a matching tool_result,
            -- or strict providers (Anthropic) reject the next request (HTTP 400). MAX_TOOL_CALLS
            -- caps further TURNS (checked at the top of step()), so a turn may slightly overrun.
            return runToolCalls(tools, calls, {
                on_call = function() tool_calls = tool_calls + 1 end,
                on_result = function(call, result)
                    table.insert(trace, summarizeToolCall(call, result))
                end,
                on_cancelled = function()
                    if completed then return end
                    finish(false, nil, _("Request cancelled by user."))
                end,
                on_done = function(executed)
                    if completed then return end
                    if #executed > 0 then
                        table.insert(tool_outputs, { executed = executed })
                        -- Budget-aware prompt: see the step_gather counterpart above.
                        local last_result = executed[#executed].result
                        if type(last_result) == "table" then
                            last_result.lookup_budget = string.format("%d of %d lookups remaining",
                                math.max(0, budget.calls - tool_calls), budget.calls)
                        end
                        -- Serialize the model echo + tool results in the provider's native shape.
                        ToolWire.appendToolTurn(provider, messages, answer.raw_assistant_turn, executed)
                    end
                    step()
                end,
            })
        end, params.settings)
    end

    if gather_mode then
        -- The readable text fits: no rounds, no status window, straight to phase 2 with
        -- the text as the passages block.
        if whole_text then return startGenerate() end
        -- Status window only for streamed sessions; with streaming off, the per-round
        -- loading InfoMessages (and phase 2's own) remain the UI, exactly as interactive.
        if features.enable_streaming ~= false then
            local ok, StreamHandler = pcall(require, "stream_handler")
            if ok and StreamHandler and StreamHandler.showToolStatusDialog then
                -- pcall the construction too: a failed dialog must degrade to the
                -- per-round loading InfoMessages, never kill the request.
                local ok2, handle = pcall(StreamHandler.showToolStatusDialog, {
                    settings = {
                        large_stream_dialog = features.large_stream_dialog,
                        response_font_size = features.markdown_font_size,
                        enable_emoji_icons = features.enable_emoji_icons == true,
                    },
                    initial_text = _("Consulting book tools…"),
                    on_stop = function()
                        BookToolRunner._cancelled = true
                        if cancel_slot.cancel then
                            -- Kills the in-flight subprocess; its callback lands in
                            -- step_gather's not-success branch → finish(cancelled).
                            local cancel = cancel_slot.cancel
                            cancel_slot.cancel = nil
                            pcall(cancel)
                        else
                            finish(false, nil, _("Request cancelled by user."))
                        end
                    end,
                    on_skip = function()
                        -- Stop gathering, answer from what was collected: kill any
                        -- in-flight lookup round and go straight to phase 2. The dead
                        -- round's callback bails on the flag (guard in step_gather).
                        if completed or BookToolRunner._skip_gather then return end
                        BookToolRunner._skip_gather = true
                        if cancel_slot.cancel then
                            local cancel = cancel_slot.cancel
                            cancel_slot.cancel = nil
                            pcall(cancel)
                        end
                        startGenerate()
                    end,
                    -- Quick-answer retry (gather-⚡): abandon the book work entirely and
                    -- resend as a plain fast answer. Only when the run is quick-eligible.
                    -- Set the flag first (mirrors on_skip's synchronous-cancel guard),
                    -- kill the in-flight round, then finish() with the sentinel — which
                    -- rides up through on_complete (queryWith's wrapped callback) to apply
                    -- quick posture and resend. tools-off there ⇒ no re-gather, no loop.
                    on_quick = features._quick_eligible == true and function()
                        if completed or BookToolRunner._quick_retry_requested then return end
                        BookToolRunner._quick_retry_requested = true
                        if cancel_slot.cancel then
                            local cancel = cancel_slot.cancel
                            cancel_slot.cancel = nil
                            pcall(cancel)
                        end
                        finish(false, nil, require("koassistant_constants").QUICK_RETRY_SENTINEL)
                    end or nil,
                })
                if ok2 and type(handle) == "table" then status_handle = handle end
            end
        end
        return step_gather()
    end
    return step()
end

-- Standalone gather (D3 smart retrieval — tools_ux_plan.md §4): phase 1 ONLY, for
-- predefined actions. Runs the done-terminated tool loop against a synthetic question
-- and hands back the assembled bundle instead of dispatching a generate phase — the
-- caller injects it into the action's own (streamed) request in place of extracted
-- text. No chat history is involved; activation is the popup's explicit source choice,
-- so posture/_tools_active play no role here (only sessionEligible, checked by the
-- popup before offering the option).
-- params: { question, query_fn, config, ui, settings,
--           on_complete(bundle|nil, info) } — bundle is a string ("" = zero-gather);
--           nil bundle means the gather failed, with info = { cancelled = true } or
--           { error = msg }. On success info = { tool_calls = N, trace = {...} }
--           (trace = per-lookup summary lines for the provenance surface).
function BookToolRunner.gatherForAction(params)
    params = params or {}
    local on_complete = params.on_complete or function() end
    local query_fn = params.query_fn
    local config = params.config or {}
    local features = config.features or {}
    if not query_fn then
        on_complete(nil, { error = "Book tool runner missing query function" })
        return nil
    end
    BookToolRunner._cancelled = false
    BookToolRunner._skip_gather = false
    local provider = config.provider or config.default_provider
    -- Explicit scope pick (round 4, maintainer: scope means SCOPE regardless of
    -- source): the unified popup's smart-retrieval dispatch stashes the committed
    -- scope — "full" = whole document (the Run consent already covered unread
    -- reach under protection), "current" = up to the reading position. Consumed
    -- ONCE here so it can never leak into a later session's tool scope; direct
    -- entries set nothing and keep the posture-resolved clamp.
    local scope_override = features._tool_reading_scope
    features._tool_reading_scope = nil
    if scope_override ~= "full" and scope_override ~= "current" then
        scope_override = nil
    end
    local reading_scope = scope_override or resolveReadingScope(config, params.ui)
    local tools = BookTools:new(params.ui, buildToolSettings(features, reading_scope))
    local budget = budgetFor(features)
    local messages = { { role = "user", content = params.question or "" } }
    appendScopeMessage(messages, scopeForMessage(tools, params.ui, features))
    local trace = {}
    local tool_outputs = {}
    local tool_turns = 0
    local tool_calls = 0
    local completed = false
    local cancel_slot = {}
    local status_handle
    local search_wait = nil

    local function closeStatus()
        if status_handle then
            status_handle.close()
            status_handle = nil
        end
    end

    local function updateStatus()
        if not status_handle then return end
        local counter = tool_calls == 1 and _("1 lookup so far")
            or T(_("%1 lookups so far"), tool_calls)
        local lines = { _("Searching the book…"), counter, "" }
        for _idx, item in ipairs(trace) do
            table.insert(lines, "• " .. item)
        end
        if search_wait then
            table.insert(lines, "")
            table.insert(lines, T(_("Searching the book text… %1 s"), search_wait))
        end
        status_handle.setText(table.concat(lines, "\n"))
    end

    local function finish(bundle, info)
        if completed then return end
        completed = true
        closeStatus()
        on_complete(bundle, info)
    end

    local function deliver()
        finish(buildGatherBundle(tool_outputs, budget.bundle_chars),
            { tool_calls = tool_calls, trace = trace })
    end

    -- The readable text fits the whole-text budget: the action gets it in full, no rounds.
    local whole = wholeReadableText(tools, features, budget)
    if whole then
        finish(wholeTextBlock(whole), { tool_calls = 0, trace = { wholeTextTraceLine(whole) }, whole_text = true })
        return nil
    end

    local step
    step = function()
        if completed then return nil end
        if BookToolRunner._cancelled then
            return finish(nil, { cancelled = true })
        end
        if tool_turns >= budget.turns or tool_calls >= budget.calls then
            return deliver()
        end

        local tool_config = buildToolConfig(config, "gather", reading_scope)
        tool_config.features.loading_message = tool_turns == 0
            and _("Book tools\nThinking...")
            or _("Book tools\nReading...")
        if status_handle then
            tool_config.features._suppress_loading_dialog = true
        end
        tool_config._register_cancel = function(cancel_fn)
            cancel_slot.cancel = cancel_fn
        end

        return query_fn(messages, tool_config, function(success, answer, err)
            cancel_slot.cancel = nil
            if completed then return end
            if not success then
                return finish(nil, BookToolRunner._cancelled
                    and { cancelled = true } or { error = err })
            end
            if type(answer) ~= "table" or answer._tool_calls ~= true then
                -- Provider ignored the gather protocol (prose despite mode ANY):
                -- there is no chat to accept it into — deliver what was gathered.
                return deliver()
            end
            local calls = answer.calls or {}
            if #calls == 0 then
                return deliver()
            end

            tool_turns = tool_turns + 1
            return runToolCalls(tools, calls, {
                skip_done = true,
                cancel_slot = cancel_slot,
                has_status = status_handle ~= nil,
                on_call = function() tool_calls = tool_calls + 1 end,
                on_result = function(call, result)
                    table.insert(trace, summarizeToolCall(call, result))
                    updateStatus()
                end,
                on_wait = function(seconds)
                    search_wait = seconds
                    updateStatus()
                end,
                on_cancelled = function()
                    -- Skip sets its flag before killing the search and delivers itself.
                    if completed or BookToolRunner._skip_gather then return end
                    finish(nil, { cancelled = true })
                end,
                on_done = function(executed, saw_done)
                    if completed or BookToolRunner._skip_gather then return end
                    if #executed > 0 then
                        table.insert(tool_outputs, { executed = executed })
                    end

                    if saw_done then
                        return deliver()
                    end

                    if #executed > 0 then
                        -- Budget-aware prompt: see the step_gather counterpart in run().
                        local last_result = executed[#executed].result
                        if type(last_result) == "table" then
                            last_result.lookup_budget = string.format("%d of %d lookups remaining",
                                math.max(0, budget.calls - tool_calls), budget.calls)
                        end
                        ToolWire.appendToolTurn(provider, messages, answer.raw_assistant_turn, executed)
                    end
                    updateStatus()
                    return step()
                end,
            })
        end, params.settings)
    end

    -- Status window (same degradation pattern as run()'s gather mode): streamed sessions
    -- get the ticking dialog; otherwise the per-round loading InfoMessages remain the UI.
    if features.enable_streaming ~= false then
        local ok, StreamHandler = pcall(require, "stream_handler")
        if ok and StreamHandler and StreamHandler.showToolStatusDialog then
            local ok2, handle = pcall(StreamHandler.showToolStatusDialog, {
                settings = {
                    large_stream_dialog = features.large_stream_dialog,
                    response_font_size = features.markdown_font_size,
                },
                initial_text = _("Consulting book tools…"),
                on_stop = function()
                    BookToolRunner._cancelled = true
                    if cancel_slot.cancel then
                        local cancel = cancel_slot.cancel
                        cancel_slot.cancel = nil
                        pcall(cancel)
                    else
                        finish(nil, { cancelled = true })
                    end
                end,
                on_skip = function()
                    -- Deliver the bundle gathered so far ("" on zero-gather, which the
                    -- caller's fallback path already handles). deliver() → finish() sets
                    -- completed, so a killed round's late callback bails on that guard.
                    if completed then return end
                    BookToolRunner._skip_gather = true
                    if cancel_slot.cancel then
                        local cancel = cancel_slot.cancel
                        cancel_slot.cancel = nil
                        pcall(cancel)
                    end
                    deliver()
                end,
            })
            if ok2 and type(handle) == "table" then status_handle = handle end
        end
    end
    return step()
end

BookToolRunner.function_declarations = FUNCTION_DECLARATIONS
-- Gather set incl. the empty-properties `done` tool — exported so the model
-- audit's tool legs probe the REAL specs (the empty-properties shape is the
-- field-found Gemini rejection class; tests/model_audit.lua T7 P1.3).
BookToolRunner.gather_declarations = GATHER_DECLARATIONS

function BookToolRunner.cancel()
    BookToolRunner._cancelled = true
end

return BookToolRunner
