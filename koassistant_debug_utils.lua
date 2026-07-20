--[[--
Debug utilities for KOAssistant

Provides truncation for debug output to keep terminal and chat viewer manageable
when dealing with large content (book text, cached responses, etc.).

@module koassistant_debug_utils
]]

local json = require("json")

local DebugUtils = {}

-- Default truncation settings for individual fields
local DEFAULT_FIELD_MAX = 5000   -- Max chars for a single large field
local DEFAULT_FIELD_EDGE = 2000  -- Chars from each end of large fields

-- Fields known to contain large content that should be truncated individually
-- These are truncated before JSON encoding to preserve JSON structure
local LARGE_CONTENT_FIELDS = {
    -- Request body fields
    "book_text",
    "incremental_book_text",
    "cached_result",
    "notebook",
    "highlights",
    "annotations",
    "full_document",
    -- Message content (handled specially in truncateMessages)
    "content",
    "result",
    "text",
}

--- Truncate text for debug display
--- Shows beginning + end with truncation notice in middle
--- @param text string The text to truncate
--- @param max_length number Optional max total length (default 5000)
--- @param edge_size number Optional chars from each end (default 2000)
--- @return string Truncated text with notice, or original if short enough
function DebugUtils.truncate(text, max_length, edge_size)
    if not text then return "" end
    max_length = max_length or DEFAULT_FIELD_MAX
    edge_size = edge_size or DEFAULT_FIELD_EDGE

    if #text <= max_length then
        return text
    end

    local total = #text
    local truncated_count = total - (edge_size * 2)
    return text:sub(1, edge_size)
        .. "\n\n[... " .. truncated_count .. " of " .. total .. " chars truncated ...]\n\n"
        .. text:sub(-edge_size)
end

--- Check if a key is a known large content field
local function isLargeContentField(key)
    for _idx, field in ipairs(LARGE_CONTENT_FIELDS) do
        if key == field then return true end
    end
    return false
end

--- Deep copy a table, truncating known large content fields
--- Preserves JSON structure while truncating only the content that's large
--- @param data table The data table to copy and truncate
--- @param max_length number Optional max length per field (default 5000)
--- @param edge_size number Optional chars from each end (default 2000)
--- @return table Copy with truncated large fields
local function deepCopyWithTruncation(data, max_length, edge_size)
    if type(data) ~= "table" then
        return data
    end

    local copy = {}
    for k, v in pairs(data) do
        if type(v) == "table" then
            copy[k] = deepCopyWithTruncation(v, max_length, edge_size)
        elseif type(v) == "string" and isLargeContentField(k) and #v > (max_length or DEFAULT_FIELD_MAX) then
            -- Truncate known large content fields
            copy[k] = DebugUtils.truncate(v, max_length, edge_size)
        else
            copy[k] = v
        end
    end
    return copy
end

--- Print debug info with field-level truncation
--- Truncates specific large fields (book_text, cached_result, etc.) while preserving JSON structure
--- Adds visual separation for large outputs to improve terminal readability
--- @param label string Label for the debug output
--- @param data any Data to print (will be JSON encoded if table)
--- @param config table Optional config with features.debug_truncate_content
function DebugUtils.print(label, data, config)
    local text

    -- Check if truncation is enabled (default: true)
    local should_truncate = true
    if config and config.features and config.features.debug_truncate_content == false then
        should_truncate = false
    end

    local is_table = type(data) == "table"

    if is_table then
        -- Truncate specific fields before JSON encoding (preserves structure)
        local data_to_encode = should_truncate and deepCopyWithTruncation(data) or data
        local ok, encoded = pcall(json.encode, data_to_encode)
        text = ok and encoded or tostring(data)
    else
        text = tostring(data)
        -- For plain strings, still apply truncation if needed
        if should_truncate then
            text = DebugUtils.truncate(text)
        end
    end

    -- Add visual separation for large outputs (tables with > 500 chars)
    if is_table and #text > 500 then
        print("")
        print("--------------------------------------------------------------------------------")
        print("-- " .. label)
        print("--------------------------------------------------------------------------------")
        print(text)
        print("--------------------------------------------------------------------------------")
        print("")
    else
        print(label, text)
    end
end

--- Truncate message content within a messages array for debug display
--- Creates a copy with truncated content, does not modify original
--- @param messages table Array of message objects with content field
--- @param max_content number Optional max content length per message (default 2000)
--- @return table Copy of messages with truncated content
function DebugUtils.truncateMessages(messages, max_content)
    if not messages then return {} end
    max_content = max_content or 2000

    local truncated = {}
    for i, msg in ipairs(messages) do
        local new_msg = {}
        for k, v in pairs(msg) do
            if k == "content" and type(v) == "string" and #v > max_content then
                local edge = math.floor(max_content / 2)
                local total = #v
                new_msg[k] = v:sub(1, edge)
                    .. "\n\n[... " .. (total - max_content) .. " of " .. total .. " chars truncated ...]\n\n"
                    .. v:sub(-edge)
            else
                new_msg[k] = v
            end
        end
        truncated[i] = new_msg
    end
    return truncated
end

--- Extract token usage from any provider's response format
--- Normalizes to { input_tokens, output_tokens, total_tokens, cache_read, cache_creation }
--- @param response table The raw API response (or SSE event)
--- @return table|nil Normalized usage or nil if no usage data found
function DebugUtils.extractUsage(response)
    if not response or type(response) ~= "table" then return nil end

    -- This runs on EVERY streamed event, and KOReader's luajson decodes JSON
    -- null to a truthy FUNCTION sentinel — so every field must be type-checked
    -- before indexing or arithmetic. OpenAI Responses lifecycle events carry
    -- usage:null until the terminal event (crashed live streams on device).
    local function tbl(v) return type(v) == "table" and v or nil end
    local function num(v) return type(v) == "number" and v or nil end

    -- Anthropic: { usage: { input_tokens, output_tokens, cache_creation_input_tokens, cache_read_input_tokens } }
    -- Also in message_start SSE: { message: { usage: { input_tokens, output_tokens } } }
    -- Also in message_delta SSE: { usage: { output_tokens } }
    -- OpenAI Responses uses the same input_tokens/output_tokens names — non-streaming
    -- at response.usage, streaming inside the terminal event's response object
    local usage = tbl(response.usage)
        or (tbl(response.message) and tbl(response.message.usage))
        or (tbl(response.response) and tbl(response.response.usage))
        or nil

    if usage then
        local input = num(usage.input_tokens)
        local output = num(usage.output_tokens)
        if input or output then
            return {
                input_tokens = input,
                output_tokens = output,
                total_tokens = num(usage.total_tokens) or ((input or 0) + (output or 0)),
                cache_read = num(usage.cache_read_input_tokens)
                    or (tbl(usage.input_tokens_details)
                        and num(usage.input_tokens_details.cached_tokens) or nil),
                cache_creation = num(usage.cache_creation_input_tokens),
                reasoning_tokens = tbl(usage.output_tokens_details)
                    and num(usage.output_tokens_details.reasoning_tokens) or nil,
            }
        end

        -- OpenAI/compatible: { usage: { prompt_tokens, completion_tokens, total_tokens } }
        local prompt = num(usage.prompt_tokens)
        local completion = num(usage.completion_tokens)
        if prompt or completion then
            local completion_details = tbl(usage.completion_tokens_details)
                or tbl(usage.output_tokens_details)
            return {
                input_tokens = prompt,
                output_tokens = completion,
                total_tokens = num(usage.total_tokens) or ((prompt or 0) + (completion or 0)),
                cache_read = tbl(usage.prompt_tokens_details)
                    and num(usage.prompt_tokens_details.cached_tokens) or nil,
                reasoning_tokens = completion_details
                    and num(completion_details.reasoning_tokens) or nil,
            }
        end
    end

    -- Gemini: { usageMetadata: { promptTokenCount, candidatesTokenCount, totalTokenCount } }
    local gemini = tbl(response.usageMetadata)
    if gemini then
        local prompt = num(gemini.promptTokenCount)
        local candidates = num(gemini.candidatesTokenCount)
        if prompt or candidates then
            return {
                input_tokens = prompt,
                output_tokens = candidates,
                total_tokens = num(gemini.totalTokenCount) or ((prompt or 0) + (candidates or 0)),
                cache_read = num(gemini.cachedContentTokenCount),
                reasoning_tokens = num(gemini.thoughtsTokenCount),
            }
        end
    end

    -- Ollama: { eval_count, prompt_eval_count } (in done event)
    local prompt_eval = num(response.prompt_eval_count)
    local eval = num(response.eval_count)
    if prompt_eval or eval then
        return {
            input_tokens = prompt_eval,
            output_tokens = eval,
            total_tokens = (prompt_eval or 0) + (eval or 0),
        }
    end

    -- Cohere: { meta: { tokens: { input_tokens, output_tokens } } }
    local cohere = tbl(response.meta) and tbl(response.meta.tokens) or nil
    if cohere then
        local input = num(cohere.input_tokens)
        local output = num(cohere.output_tokens)
        if input or output then
            return {
                input_tokens = input,
                output_tokens = output,
                total_tokens = (input or 0) + (output or 0),
            }
        end
    end

    return nil
end

--- Format token usage as a compact debug string
--- @param usage table Normalized usage from extractUsage()
--- @return string Formatted usage line
function DebugUtils.formatUsage(usage)
    if not usage then return "" end
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
    if #parts == 0 then return "" end
    local total = usage.total_tokens and string.format(" (%d total)", usage.total_tokens) or ""
    return table.concat(parts, ", ") .. total
end

--- Print token usage line to terminal
--- @param label string Prefix label (e.g., "Anthropic")
--- @param response table Raw API response
function DebugUtils.printUsage(label, response)
    local usage = DebugUtils.extractUsage(response)
    if usage then
        print(string.format("[%s] Token usage: %s", label, DebugUtils.formatUsage(usage)))
    end
end

--- Dump X-Ray merge data (old cache, AI delta, merged result) to docs/ for analysis.
--- Call from koassistant_dialogs.lua inside the `if using_cache and message_data._parsed_old_xray` block,
--- wrapping the XrayParser.merge() call:
---   local DebugUtils = require("koassistant_debug_utils")
---   parsed = DebugUtils.dumpXrayMerge(message_data._parsed_old_xray, parsed, XrayParser)
function DebugUtils.dumpXrayMerge(old_xray, delta, XrayParser)
    local logger = require("logger")
    local script_path = require("ffi/util").realpath(debug.getinfo(1, "S").source:sub(2)):match("(.*/)")
    local debug_dir = script_path .. "docs"

    local function countEntries(data)
        local counts = {}
        for k, v in pairs(data) do
            if k ~= "type" then
                if type(v) == "table" and #v > 0 then
                    counts[k] = #v
                elseif type(v) == "table" then
                    counts[k] = "singleton"
                end
            end
        end
        return counts
    end

    for label, data in pairs({OLD = old_xray, DELTA = delta}) do
        logger.info("KOAssistant: X-Ray merge debug —", label, "categories:")
        for k, v in pairs(countEntries(data)) do
            logger.info("  ", k, "=", tostring(v))
        end
    end

    local f = io.open(debug_dir .. "/debug_xray_old.json", "w")
    if f then f:write(json.encode(old_xray)); f:close() end
    f = io.open(debug_dir .. "/debug_xray_ai_delta.json", "w")
    if f then f:write(json.encode(delta)); f:close() end

    local merged = XrayParser.merge(old_xray, delta)

    logger.info("KOAssistant: X-Ray merge debug — MERGED categories:")
    for k, v in pairs(countEntries(merged)) do
        logger.info("  ", k, "=", tostring(v))
    end
    f = io.open(debug_dir .. "/debug_xray_merged.json", "w")
    if f then f:write(json.encode(merged)); f:close() end

    logger.info("KOAssistant: Debug files written to docs/debug_xray_*.json")
    return merged
end

return DebugUtils
