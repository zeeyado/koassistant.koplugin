local BookTools = require("koassistant_book_tools")
local BookSettings = require("koassistant_book_settings")
local ConfigHelper = require("koassistant_config_helper")
local DebugUtils = require("koassistant_debug_utils")
local ModelConstraints = require("model_constraints")
local ToolWire = require("koassistant_api.tool_wire")
local _ = require("koassistant_gettext")
local T = require("ffi/util").template

local BookToolRunner = {}

-- Lookup-effort dial (tools_ux_plan.md §2): features.tool_lookup_effort scales how much
-- searching a session may do. turns/calls cap the loop (both modes); bundle_chars caps
-- the phase-2 context bundle (gather only — individual tool caps of 8K/read target and
-- 180-char snippets bound each call, but nothing else bounds the session total).
-- "standard" = the former hard constants; unknown/missing values fall back to it.
local EFFORT_BUDGETS = {
    quick    = { turns = 2, calls = 4,  bundle_chars = 32000 },
    standard = { turns = 4, calls = 8,  bundle_chars = 32000 },
    thorough = { turns = 6, calls = 16, bundle_chars = 48000 },
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

When answering questions about the current book, use the local book tools when you need evidence from the text. Prefer search_book for specific phrases, character names, objects, or events; it returns all matching hit references with short concordance excerpts and page counts. Batch related lookups: pass multiple terms via search_book queries=[...] and multiple targets via read_around hit_ids=[...] / pages=[...] in a single call to avoid extra round trips. Use read_around for surrounding context, and toc for chapter structure.]]

-- Reading-scope clause appended to the tool instructions. "current" enforces spoiler safety
-- (the model is also clamped in BookTools); "full" lets it use the whole document.
local SCOPE_NOTE_CURRENT = " The tools can only read pages up to the user's current reading position; do not request or claim access to later pages."
local SCOPE_NOTE_FULL = " The tools can read the entire document."

local FINAL_INSTRUCTIONS = [[

Use the gathered local book tool results to answer the user's question.]]

local FINAL_NOTE_CURRENT = " Do not use or reveal any information about events or plot developments beyond the user's current reading position."

-- Gather mode (gather_then_generate_plan.md D2): phase 1 collects passages only; the
-- model signals completion via the `done` tool, then phase 2 answers as a normal
-- (streamed, web-search-capable) request with the gathered passages injected.
local GATHER_INSTRUCTIONS = [[

GATHER PHASE: Do not answer the user's question yet. Use the book tools (search_book, read_around, toc) to collect the passages needed to answer it; batch related lookups in one call. When you have gathered enough evidence — or if the question needs no book lookups — call the done tool. In this phase respond only with tool calls, never with prose.]]

local FUNCTION_DECLARATIONS = {
    {
        name = "search_book",
        description = "Search the readable book text. Pass multiple terms via queries=[...] to batch lookups in one call. Returns per-query blocks with compact hit metadata and short concordance excerpts; hit IDs are namespaced (e.g. q1:p42:3). Call read_around for surrounding context.",
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
                fuzzy = {
                    type = "boolean",
                    description = "Use fuzzy matching for likely typos or approximate names. Defaults to true.",
                },
                case_sensitive = {
                    type = "boolean",
                    description = "Require exact casing. Defaults to false.",
                },
            },
        },
    },
    {
        name = "read_around",
        description = "Read surrounding text near one or more search hits or page numbers, capped to a small range within the readable range.",
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
        description = "List table-of-contents entries within the readable range. No snippets are included by default.",
        parameters = {
            type = "object",
            properties = {
                max_snippet_chars = {
                    type = "integer",
                    description = "Maximum snippet length per entry. Defaults to 0 and is capped at 800.",
                },
                max_entries = {
                    type = "integer",
                    description = "Maximum number of TOC entries. Defaults to 120.",
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

local function appendScopeMessage(messages, scope)
    if type(scope) ~= "table" then return end
    local content
    if scope.reading_scope == "full" then
        content = string.format(
            "[Book tool scope]\nCurrent page: %s of %s\nYou may read the entire document (pages 1-%s).",
            tostring(scope.current_page or "?"),
            tostring(scope.total_pages or "?"),
            tostring(scope.end_page or scope.total_pages or "?"))
    else
        content = string.format(
            "[Book tool scope]\nCurrent page: %s of %s\nReadable page range: 1-%s\nDo not request or infer content after page %s.",
            tostring(scope.current_page or "?"),
            tostring(scope.total_pages or "?"),
            tostring(scope.end_page or "?"),
            tostring(scope.end_page or "?"))
    end
    table.insert(messages, {
        role = "user",
        content = content,
        is_context = true,
    })
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
            .. string.format(" You may use at most %d lookups in total.", budget.calls)
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

-- Resolve the tool reading scope from the spoiler-free policy: spoiler-free in effect
-- (session flag, or per-book/global setting) → "current" (clamp to reading position);
-- otherwise → "full" (whole document — research, non-fiction, finished books).
local function resolveReadingScope(config, ui)
    local features = config and config.features or {}
    -- The session checkbox (set on the Send path) is authoritative when present — true OR
    -- false — so unchecking it un-clamps (full scope) even while global spoiler-free is on.
    if features._spoiler_free_active ~= nil then
        return features._spoiler_free_active and "current" or "full"
    end
    local doc_settings = ui and ui.doc_settings
    if BookSettings.resolveSpoilerFree(doc_settings, features) then return "current" end
    return "full"
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
                table.insert(terms, string.format("%q(%d)", block.query or "", block.total_hits or 0))
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
        return string.format("toc: %d entries", result.entry_count or 0)
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
        if result.queries then
            for q_index, block in ipairs(result.queries) do
                table.insert(lines, string.format("  [q%d %q] %d hit(s) across %d page(s)",
                    q_index,
                    block.query or "",
                    block.total_hits or 0,
                    block.matching_pages or 0))
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
                        table.insert(lines, string.format("    [%s, p%d, %s] %s",
                            hit.hit_id or "?",
                            hit.page or 0,
                            hit.match_type or "?",
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
            for _idx, item in ipairs(result.results) do
                local range = item.range or {}
                table.insert(lines, string.format("  [%s, pp. %s-%s] %s",
                    item.hit_id or ("p" .. tostring(item.page or "?")),
                    tostring(range.start_page or "?"),
                    tostring(range.end_page or "?"),
                    item.text or ""))
            end
            return table.concat(lines, "\n")
        else
            local range = result.range or {}
            return string.format("read_around: pp. %s-%s\n  %s",
                tostring(range.start_page or "?"),
                tostring(range.end_page or "?"),
                result.text or "")
        end
    elseif name == "toc" then
        local lines = {}
        if result.entries then
            for _idx, entry in ipairs(result.entries) do
                local snippet = entry.snippet and #entry.snippet > 0 and (": " .. entry.snippet) or ""
                table.insert(lines, string.format("  %s (pp. %d-%d)%s",
                    entry.title or "",
                    entry.start_page or 0,
                    entry.end_page or 0,
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
    return text:sub(1, max_chars - 3) .. "..."
end

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
                        table.insert(sections, truncateSection(section, remaining))
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
    local provider = config and (config.provider or config.default_provider)
    -- Provider/model must support function calling AND have a tool_wire adapter; otherwise
    -- fall through to the normal (whole-context) path. Generalizes the old gemini-only gate.
    local model = config and ConfigHelper:getModelInfo(config)
    if not (ModelConstraints.supportsCapability(provider, model, "tools") and ToolWire.hasAdapter(provider)) then
        return false, "provider"
    end
    -- Tools are a form of book-text extraction → respect the consent gate (trusted bypass).
    if features.enable_book_text_extraction ~= true and not isProviderTrusted(provider, features) then
        return false, "consent"
    end
    if ui == nil or ui.document == nil then
        return false, "no_book"
    end
    return true
end

-- D3 smart retrieval gate (tools_ux_plan.md §4 + master-switch decision 2026-07-11):
-- the per-action source is allowed when the session could run tools AND the effective
-- tools posture (per-book > global) isn't "off" — posture is THE master switch for all
-- tool use; manual vs auto only affects the chat checkbox's default state.
-- Returns allowed:boolean and, when false, a reason:
-- "provider" | "consent" | "no_book" | "posture_off".
function BookToolRunner.smartRetrievalAllowed(config, ui)
    local ok, reason = BookToolRunner.sessionEligible(config, ui)
    if not ok then return false, reason end
    local features = config and config.features or {}
    if BookSettings.resolveToolsPosture(ui and ui.doc_settings, features) == "off" then
        return false, "posture_off"
    end
    return true
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
        -- follow the effective posture default — the same derivation as the checkbox's
        -- initial state, so the two never disagree. ui.doc_settings is the OPEN book's
        -- live instance (read-only here); tools only ever run against the open book
        -- (sessionEligible requires ui.document).
        local posture = BookSettings.resolveToolsPosture(ui and ui.doc_settings, features)
        active = posture == "auto"
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
            require("koassistant_dialogs").applyQuickReplyOverrides(cfg, plugin)
            return BookToolRunner.queryWith(query_fn, messages, cfg, callback, plugin, ui)
        end
        return callback(success, answer, err, ...)
    end
    if BookToolRunner.shouldUse(cfg, ui) then
        return BookToolRunner.run({
            query_fn = query_fn,
            messages = messages,
            config = cfg,
            settings = plugin and plugin.settings,
            ui = ui,
            on_complete = wrapped,
        })
    end
    return query_fn(messages, cfg, wrapped, plugin and plugin.settings)
end

function BookToolRunner.run(params)
    params = params or {}
    BookToolRunner._cancelled = false
    BookToolRunner._skip_gather = false
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
    appendScopeMessage(messages, tools:getScope())
    local trace = {}
    local tool_outputs = {}
    local token_usage = nil
    local tool_turns = 0
    local tool_calls = 0
    local budget = budgetFor(features)
    local completed = false
    local gather_mode = (features.tool_mode or "gather") == "gather"

    -- Gather-phase status window (streamed sessions only): one dialog that ticks per
    -- lookup round; closed before phase 2, whose normal stream dialog takes its place.
    local status_handle
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
        if success and tool_calls > 0 then
            if type(provenance) ~= "table" then
                provenance = provenance and { web_search = true } or {}
            end
            provenance.book_tools = { lookups = tool_calls, trace = trace }
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
        if bundle and #bundle > 0 then
            context_text = "[Passages retrieved from the book for this question]\n" .. bundle
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

            local saw_done = false
            local executed = {}
            for _idx, call in ipairs(calls) do
                if call.name == "done" then
                    saw_done = true
                else
                    tool_calls = tool_calls + 1
                    local result = tools:execute(call.name, call.args or {})
                    table.insert(trace, summarizeToolCall(call, result))
                    table.insert(executed, { call = call, result = result })
                end
            end
            if #executed > 0 then
                table.insert(tool_outputs, { executed = executed })
            end

            if saw_done then
                -- done terminates the phase; this turn is never replayed (phase 2 starts
                -- from the original history), so unanswered echoed calls can't 400.
                return startGenerate()
            end

            if #executed > 0 then
                -- Budget-aware prompt (tools_ux_plan.md §2): the round's last result table
                -- carries the remaining budget — stringifyResult JSON-encodes the table
                -- verbatim, so this reaches the model on every provider. The bundle and
                -- diagnostics formatters read named fields, so it never leaks to the user.
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

            local executed = {}
            for _idx, call in ipairs(calls) do
                -- Execute EVERY call in this turn: each tool_use must get a matching tool_result,
                -- or strict providers (Anthropic) reject the next request (HTTP 400). MAX_TOOL_CALLS
                -- caps further TURNS (checked at the top of step()), so a turn may slightly overrun.
                tool_calls = tool_calls + 1
                local result = tools:execute(call.name, call.args or {})
                table.insert(trace, summarizeToolCall(call, result))
                table.insert(executed, { call = call, result = result })
            end

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
        end, params.settings)
    end

    if gather_mode then
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
    local reading_scope = resolveReadingScope(config, params.ui)
    local tools = BookTools:new(params.ui, buildToolSettings(features, reading_scope))
    local budget = budgetFor(features)
    local messages = { { role = "user", content = params.question or "" } }
    appendScopeMessage(messages, tools:getScope())
    local trace = {}
    local tool_outputs = {}
    local tool_turns = 0
    local tool_calls = 0
    local completed = false
    local cancel_slot = {}
    local status_handle

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
            local saw_done = false
            local executed = {}
            for _idx, call in ipairs(calls) do
                if call.name == "done" then
                    saw_done = true
                else
                    tool_calls = tool_calls + 1
                    local result = tools:execute(call.name, call.args or {})
                    table.insert(trace, summarizeToolCall(call, result))
                    table.insert(executed, { call = call, result = result })
                end
            end
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

function BookToolRunner.cancel()
    BookToolRunner._cancelled = true
end

return BookToolRunner
