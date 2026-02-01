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

    local truncated_count = #text - (edge_size * 2)
    return text:sub(1, edge_size)
        .. "\n\n[... " .. truncated_count .. " chars truncated ...]\n\n"
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
        print("=== " .. label .. " ===")
        print(text)
        print("===========================================")
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
                new_msg[k] = v:sub(1, edge)
                    .. "\n\n[... " .. (#v - max_content) .. " chars truncated ...]\n\n"
                    .. v:sub(-edge)
            else
                new_msg[k] = v
            end
        end
        truncated[i] = new_msg
    end
    return truncated
end

return DebugUtils
