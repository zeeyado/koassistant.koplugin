local BookTools = require("koassistant_book_tools")
local ConfigHelper = require("koassistant_config_helper")
local DebugUtils = require("koassistant_debug_utils")

local GeminiToolRunner = {}

local MAX_TOOL_TURNS = 4
local MAX_TOOL_CALLS = 8
-- Diagnostic blocks (lookups trace, raw tool-result dump, token usage) are emitted only
-- when features.show_debug_in_chat is on (gated in finish()); off by default. The dump can
-- contain raw book-text snippets, so it must never ship on for ordinary users.
local VERBOSE_TOOL_OUTPUT = true
local VERBOSE_SECTION_MAX_CHARS = 256
local SHOW_TURN_TOKEN_USAGE = true

local TOOL_INSTRUCTIONS = [[

When answering questions about the current book, use the local book tools when you need evidence from the text. The tools can only read pages up to the user's current reading position. Prefer search_book for specific phrases, character names, objects, or events; it returns all matching hit references with short concordance excerpts and page counts. Batch related lookups: pass multiple terms via search_book queries=[...] and multiple targets via read_around hit_ids=[...] / pages=[...] in a single call to avoid extra round trips. Use read_around for surrounding context, and toc for chapter structure. Do not claim access to unread pages.]]

local FINAL_INSTRUCTIONS = [[

Use the gathered local book tool results to answer the user's question. Do not use or reveal any information about events or plot developments beyond the user's current reading position.]]

local FUNCTION_DECLARATIONS = {
    {
        name = "search_book",
        description = "Search the book text up to the current reading position. Pass multiple terms via queries=[...] to batch lookups in one call. Returns per-query blocks with compact hit metadata and short concordance excerpts; hit IDs are namespaced (e.g. q1:p42:3). Call read_around for surrounding context.",
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
        description = "Read surrounding text near one or more search hits or page numbers, capped to a small spoiler-safe range before the current page.",
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
        description = "List table-of-contents entries up to the current reading position. No snippets are included by default.",
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

local function appendListItem(items, text)
    if text and text ~= "" then
        table.insert(items, "- " .. text)
    end
end

local function copyMessages(messages)
    local copy = {}
    for _, msg in ipairs(messages or {}) do
        table.insert(copy, ConfigHelper:deepCopy(msg))
    end
    return copy
end

local function appendScopeMessage(messages, scope)
    if type(scope) ~= "table" then return end
    table.insert(messages, {
        role = "user",
        content = string.format(
            "[Book tool scope]\nCurrent page: %s of %s\nReadable page range: 1-%s\nDo not request or infer content after page %s.",
            tostring(scope.current_page or "?"),
            tostring(scope.total_pages or "?"),
            tostring(scope.end_page or "?"),
            tostring(scope.end_page or "?")),
        is_context = true,
    })
end

local function buildToolConfig(config, final_only)
    local tool_config = ConfigHelper:deepCopy(config or {})
    tool_config.features = tool_config.features or {}
    tool_config.features.enable_streaming = false
    tool_config.features.enable_web_search = false
    tool_config.enable_web_search = false

    if not final_only then
        tool_config.gemini_tools = {
            function_declarations = FUNCTION_DECLARATIONS,
            mode = "AUTO",
        }
    else
        tool_config.gemini_tools = nil
    end

    tool_config.system = tool_config.system or {}
    tool_config.system.text = (tool_config.system.text or "") .. (final_only and FINAL_INSTRUCTIONS or TOOL_INSTRUCTIONS)
    return tool_config
end

local function buildToolSettings(features)
    features = features or {}
    return {
        -- Consent is enforced upstream in GeminiToolRunner.shouldUse (requires
        -- enable_book_text_extraction, or a trusted provider) before the runner ever
        -- builds tools, so the extractor is enabled here unconditionally — this also
        -- covers the trusted-provider bypass case (extraction setting may be off).
        enable_book_text_extraction = true,
        max_book_text_chars = features.max_book_text_chars,
        max_pdf_pages = features.max_pdf_pages,
    }
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
    for _, item in ipairs(trace) do
        appendListItem(lines, item)
    end
    return answer .. "\n" .. table.concat(lines, "\n")
end

local function formatToolResultText(name, result)
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
            for _, item in ipairs(result.results) do
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
            for _, entry in ipairs(result.entries) do
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

local function appendVerboseToolOutput(answer, tool_outputs)
    if not VERBOSE_TOOL_OUTPUT or type(answer) ~= "string" or #tool_outputs == 0 then
        return answer
    end

    local lines = { "", "---", "**Tool results sent to model:**", "",
        string.format("(each section truncated to %d chars; verbose preview only)", VERBOSE_SECTION_MAX_CHARS) }
    for i, output in ipairs(tool_outputs) do
        table.insert(lines, "")
        table.insert(lines, string.format("Turn %d:", i))
        if output.content and output.content.parts then
            for _, part in ipairs(output.content.parts) do
                if part.functionResponse then
                    local name = part.functionResponse.name or "tool"
                    local result = part.functionResponse.response or {}
                    local section = formatToolResultText(name, result)
                    table.insert(lines, truncateSection(section, VERBOSE_SECTION_MAX_CHARS))
                end
            end
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
    for _, field in ipairs(fields) do
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
        local call_label = usage._call_count == 1 and "Gemini API call" or "Gemini API calls"
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

local function makeFunctionResponsePart(call, result)
    local response = {
        name = call.name,
        response = result,
    }
    if call.id then
        response.id = call.id
    end
    return {
        functionResponse = response,
    }
end

local function appendModelContent(messages, model_content)
    if not model_content or not model_content.parts then return end
    table.insert(messages, {
        role = model_content.role or "model",
        parts = model_content.parts,
    })
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

function GeminiToolRunner.shouldUse(config, ui)
    local features = config and config.features or {}
    -- Experimental opt-in (default off): the whole feature is gated behind this flag.
    if features.enable_tool_workflows ~= true then return false end
    local provider = config and (config.provider or config.default_provider)
    -- Tools are a form of book-text extraction → respect the consent gate (trusted bypass).
    if features.enable_book_text_extraction ~= true and not isProviderTrusted(provider, features) then
        return false
    end
    return provider == "gemini"
        and features.is_library_context ~= true
        and features.is_general_context ~= true
        and features._xray_chat_active ~= true
        and ui ~= nil
        and ui.document ~= nil
end

-- Convenience wrapper: route through GeminiToolRunner.run when shouldUse is true,
-- otherwise call query_fn directly. Lets all chat reply paths share one call site
-- without each caller knowing about the runner.
function GeminiToolRunner.queryWith(query_fn, messages, cfg, callback, plugin, ui)
    if GeminiToolRunner.shouldUse(cfg, ui) then
        return GeminiToolRunner.run({
            query_fn = query_fn,
            messages = messages,
            config = cfg,
            settings = plugin and plugin.settings,
            ui = ui,
            on_complete = callback,
        })
    end
    return query_fn(messages, cfg, callback, plugin and plugin.settings)
end

function GeminiToolRunner.run(params)
    params = params or {}
    GeminiToolRunner._cancelled = false
    local query_fn = params.query_fn
    local on_complete = params.on_complete
    if not query_fn then
        if on_complete then on_complete(false, nil, "Gemini tool runner missing query function") end
        return nil
    end

    local messages = copyMessages(params.messages)
    local config = params.config or {}
    local features = config.features or {}
    local tools = BookTools:new(params.ui, buildToolSettings(features))
    appendScopeMessage(messages, tools:getScope())
    local trace = {}
    local tool_outputs = {}
    local token_usage = nil
    local tool_turns = 0
    local tool_calls = 0
    local completed = false

    local function finish(success, answer, err, reasoning, web_search_used)
        if completed then return end
        completed = true
        if success and type(answer) == "string" then
            -- The lookups trace, the raw tool-result dump (may contain book-text snippets),
            -- and the token-usage footer are developer diagnostics: emit only when in-chat
            -- debug is enabled. Off by default → clean answers for ordinary users.
            if config.features and config.features.show_debug_in_chat == true then
                answer = appendTrace(answer, trace)
                answer = appendVerboseToolOutput(answer, tool_outputs)
                answer = appendTurnTokenUsage(answer, token_usage)
            end
        end
        if on_complete then
            on_complete(success, answer, err, reasoning, web_search_used)
        end
    end

    local function requestFinal()
        local final_config = buildToolConfig(config, true)
        final_config.features.loading_message = "Gemini book tools\nPreparing answer..."
        table.insert(messages, {
            role = "user",
            content = "Answer the user's question using the gathered tool results. Do not call more tools.",
        })
        return query_fn(messages, final_config, function(success, answer, err, reasoning, web_search_used, usage)
            token_usage = mergeUsage(token_usage, usage)
            finish(success, answer, err, reasoning, web_search_used)
        end, params.settings)
    end

    local step
    step = function()
        if completed then return nil end
        if GeminiToolRunner._cancelled then
            finish(false, nil, "Request cancelled by user.")
            return nil
        end
        if tool_turns >= MAX_TOOL_TURNS or tool_calls >= MAX_TOOL_CALLS then
            return requestFinal()
        end

        local tool_config = buildToolConfig(config, false)
        tool_config.features.loading_message = tool_turns == 0
            and "Gemini book tools\nThinking..."
            or "Gemini book tools\nReading..."

        return query_fn(messages, tool_config, function(success, answer, err, reasoning, web_search_used, usage)
            token_usage = mergeUsage(token_usage, usage)
            if not success then
                finish(false, nil, err, reasoning, web_search_used)
                return
            end

            if type(answer) ~= "table" or answer._gemini_function_calls ~= true then
                finish(true, answer, nil, reasoning, web_search_used)
                return
            end

            local calls = answer.calls or {}
            if #calls == 0 then
                finish(false, nil, "Gemini returned an empty tool call")
                return
            end

            tool_turns = tool_turns + 1
            appendModelContent(messages, answer.model_content)

            local response_parts = {}
            for _, call in ipairs(calls) do
                if tool_calls >= MAX_TOOL_CALLS then break end
                tool_calls = tool_calls + 1
                local result = tools:execute(call.name, call.args or {})
                table.insert(trace, summarizeToolCall(call, result))
                table.insert(response_parts, makeFunctionResponsePart(call, result))
            end

            if #response_parts > 0 then
                table.insert(tool_outputs, {
                    content = {
                        role = "user",
                        parts = response_parts,
                    },
                })
                table.insert(messages, {
                    role = "tool",
                    parts = response_parts,
                })
            end

            step()
        end, params.settings)
    end

    return step()
end

GeminiToolRunner.function_declarations = FUNCTION_DECLARATIONS

function GeminiToolRunner.cancel()
    GeminiToolRunner._cancelled = true
end

return GeminiToolRunner
