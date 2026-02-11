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

    -- Anthropic: { usage: { input_tokens, output_tokens, cache_creation_input_tokens, cache_read_input_tokens } }
    -- Also in message_start SSE: { message: { usage: { input_tokens, output_tokens } } }
    -- Also in message_delta SSE: { usage: { output_tokens } }
    local usage = response.usage
        or (response.message and response.message.usage)

    if usage and (usage.input_tokens or usage.output_tokens) then
        return {
            input_tokens = usage.input_tokens,
            output_tokens = usage.output_tokens,
            total_tokens = (usage.input_tokens or 0) + (usage.output_tokens or 0),
            cache_read = usage.cache_read_input_tokens,
            cache_creation = usage.cache_creation_input_tokens,
        }
    end

    -- OpenAI/compatible: { usage: { prompt_tokens, completion_tokens, total_tokens } }
    if usage and (usage.prompt_tokens or usage.completion_tokens) then
        return {
            input_tokens = usage.prompt_tokens,
            output_tokens = usage.completion_tokens,
            total_tokens = usage.total_tokens or ((usage.prompt_tokens or 0) + (usage.completion_tokens or 0)),
            cache_read = usage.prompt_tokens_details and usage.prompt_tokens_details.cached_tokens,
        }
    end

    -- Gemini: { usageMetadata: { promptTokenCount, candidatesTokenCount, totalTokenCount } }
    local gemini = response.usageMetadata
    if gemini and (gemini.promptTokenCount or gemini.candidatesTokenCount) then
        return {
            input_tokens = gemini.promptTokenCount,
            output_tokens = gemini.candidatesTokenCount,
            total_tokens = gemini.totalTokenCount or ((gemini.promptTokenCount or 0) + (gemini.candidatesTokenCount or 0)),
            cache_read = gemini.cachedContentTokenCount,
        }
    end

    -- Ollama: { eval_count, prompt_eval_count } (in done event)
    if response.prompt_eval_count or response.eval_count then
        return {
            input_tokens = response.prompt_eval_count,
            output_tokens = response.eval_count,
            total_tokens = (response.prompt_eval_count or 0) + (response.eval_count or 0),
        }
    end

    -- Cohere: { meta: { tokens: { input_tokens, output_tokens } } }
    local cohere = response.meta and response.meta.tokens
    if cohere and (cohere.input_tokens or cohere.output_tokens) then
        return {
            input_tokens = cohere.input_tokens,
            output_tokens = cohere.output_tokens,
            total_tokens = (cohere.input_tokens or 0) + (cohere.output_tokens or 0),
        }
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

return DebugUtils
