--[[--
Scope-resolution helpers (surrounding_context_plan.md §5 — phase 0).

Pure string helpers for the word-walk backend of surrounding context: UTF-8-safe
trims, real paragraph windows, and the mode dispatcher `trimContext`. The full
ScopeResolver contract (anchors + range scopes: pages / chapter-so-far / whole
chapter) lands with the flexible-scope work; keep everything in this module pure —
no UI, no privacy gating, no KOReader requires — so it stays unit-testable.

The raw inputs (`prev`/`next`) come from ReaderHighlight:getSelectedWordContext(),
whose crengine backend inserts "\n" at paragraph/block boundaries — that is what
makes real paragraph windows possible. PDF/kopt backends may provide no newlines;
paragraph mode then degrades to the whole capped window.
]]

local ScopeResolver = {}

-- Hard cap to prevent surrounding context being used as a book-text-extraction
-- bypass. This is context for disambiguation, not document extraction; the
-- word-walk modes are deliberately exempt from the extraction consent gate
-- BECAUSE of this cap (range scopes, when they arrive, will be gated).
ScopeResolver.MAX_CONTEXT_CHARS = 2000

-- string.sub operates on bytes, splitting multibyte UTF-8 chars
local UTF8_CHAR_PATTERN = '[%z\1-\127\194-\253][\128-\191]*'

--- First n UTF-8 chars of str. @return trimmed, was_truncated
function ScopeResolver.utf8First(str, n)
    local count = 0
    local byte_end = 0
    for uchar in str:gmatch(UTF8_CHAR_PATTERN) do
        count = count + 1
        if count > n then
            return str:sub(1, byte_end), true
        end
        byte_end = byte_end + #uchar
    end
    return str:sub(1, byte_end), false
end

--- Last n UTF-8 chars of str. @return trimmed, was_truncated
function ScopeResolver.utf8Last(str, n)
    local offsets = {}
    local count = 0
    local pos = 1
    for uchar in str:gmatch(UTF8_CHAR_PATTERN) do
        count = count + 1
        offsets[count] = pos
        pos = pos + #uchar
    end
    if count <= n then
        return str, false
    end
    return str:sub(offsets[count - n + 1]), true
end

--- Real paragraph window: take the last/first n newline-separated segments around
-- the selection. The segment adjacent to the selection is the remainder of the
-- paragraph containing it, so n=1 means "just the containing paragraph". Text with
-- no newlines (PDF/kopt word windows) degrades to the whole capped window.
-- @param prev string text before the selection ("" ok)
-- @param next_text string text after the selection ("" ok)
-- @param n number paragraphs per side (>= 1)
-- @param max_per_side number UTF-8 char cap applied per side
-- @return before, after  (strings, possibly empty)
function ScopeResolver.paragraphWindow(prev, next_text, n, max_per_side)
    n = (type(n) == "number" and n >= 1) and math.floor(n) or 1
    local function segments(text)
        local segs = {}
        for seg in text:gmatch("[^\n]+") do
            if seg:match("%S") then table.insert(segs, seg) end
        end
        return segs
    end
    local before, after = "", ""
    local prev_segs = segments(prev or "")
    if #prev_segs > 0 then
        before = table.concat(prev_segs, "\n", math.max(1, #prev_segs - n + 1), #prev_segs)
    end
    local next_segs = segments(next_text or "")
    if #next_segs > 0 then
        after = table.concat(next_segs, "\n", 1, math.min(n, #next_segs))
    end
    before = (ScopeResolver.utf8Last(before, max_per_side))
    after = (ScopeResolver.utf8First(after, max_per_side))
    return before, after
end

--- Chapter-preset availability for the unified scope popup (flexible_scope_plan.md
-- phase 1). Pure decision logic: takes resolved facts, returns which presets to show
-- and their effective page ranges. WHICH actions get chapter presets is the caller's
-- product decision (quiz-only, maintainer 2026-07-16 — other actions state their scope
-- explicitly via Pick section… / From section…); UI labels, chapter resolution,
-- extraction, and gating all stay in main.lua.
-- @param p table {
--   chapter = { start_page = N, end_page = N } | nil,  -- current chapter (nil = no TOC / front matter)
--   current_page = number,
--   spoiler_free = boolean,  -- resolved per-book/global posture (session chip never applies here)
-- }
-- @return table {
--   chapter = { start_page, end_page } | nil,         -- "Current chapter" row (nil = hidden)
--   chapter_so_far = { start_page, end_page } | nil,  -- "Current chapter so far" row (nil = hidden)
-- }
function ScopeResolver.chapterPresets(p)
    local ch = p.chapter
    if not ch or not ch.start_page or not ch.end_page then return {} end
    local cur = p.current_page or 1
    local out = {}
    -- "Current chapter so far": strictly mid-chapter — at the chapter start nothing has
    -- been read yet, and at/after the chapter end it equals the full chapter.
    if cur > ch.start_page and cur < ch.end_page then
        out.chapter_so_far = { start_page = ch.start_page, end_page = cur }
    end
    -- "Current chapter": spoiler posture clamps any scope's end to the current position
    -- (plan §2) — mid-chapter the clamped range IS the so-far row, so hide this one
    -- instead of double-listing it.
    if not (p.spoiler_free and cur < ch.end_page) then
        out.chapter = { start_page = ch.start_page, end_page = ch.end_page }
    end
    return out
end

--- Trim a raw context window to the requested mode and mark the selection.
-- Modes: "sentence" (default; falls back to characters when boundaries yield too
-- little), "paragraph" (opts.paragraphs per side), "characters" (opts.char_count
-- per side), "none" (returns ""). All output respects MAX_CONTEXT_CHARS.
-- @param prev string|nil text before the selection
-- @param next_text string|nil text after the selection
-- @param highlighted_text string|nil the selection (embedded as >>>text<<<)
-- @param mode string|nil
-- @param opts table|nil { char_count = N, paragraphs = N }
-- @return string marked context, or "" when nothing usable
function ScopeResolver.trimContext(prev, next_text, highlighted_text, mode, opts)
    mode = mode or "sentence"
    if mode == "none" then return "" end
    opts = opts or {}
    prev = prev or ""
    next_text = next_text or ""
    if prev == "" and next_text == "" then return "" end

    local max_per_side = math.floor(ScopeResolver.MAX_CONTEXT_CHARS / 2)
    local char_count = opts.char_count or 100
    if char_count > max_per_side then char_count = max_per_side end

    local word_marker = ">>>" .. (highlighted_text or "") .. "<<<"

    if mode == "characters" then
        local before, before_truncated = ScopeResolver.utf8Last(prev, char_count)
        local after, after_truncated = ScopeResolver.utf8First(next_text, char_count)
        if before_truncated then
            before = "..." .. before
        end
        if after_truncated then
            after = after .. "..."
        end
        return before .. " " .. word_marker .. " " .. after

    elseif mode == "paragraph" then
        local before, after = ScopeResolver.paragraphWindow(prev, next_text, opts.paragraphs, max_per_side)
        -- Always mark as an excerpt: the window itself was word-count-bounded,
        -- so outermost segments may be partial paragraphs.
        if #before > 0 then
            before = "..." .. before
        end
        if #after > 0 then
            after = after .. "..."
        end
        return before .. " " .. word_marker .. " " .. after

    else  -- "sentence" mode (default)
        local function findSentenceStart(text)
            -- Search backwards for sentence end (.!?) followed by space
            local last_end = text:match(".*[%.!%?]%s+()") or 1
            return text:sub(last_end)
        end
        local function findSentenceEnd(text)
            -- Search forwards for sentence end (.!?)
            local end_pos = text:find("[%.!%?]%s") or text:find("[%.!%?]$")
            if end_pos then
                return text:sub(1, end_pos)
            end
            return text
        end

        local sentence_before = findSentenceStart(prev)
        local sentence_after = findSentenceEnd(next_text)

        -- If sentence parsing results in very little text, fall back to characters mode
        local result = sentence_before .. " " .. word_marker .. " " .. sentence_after
        if #result < 30 then  -- Threshold accounts for the marker
            return ScopeResolver.trimContext(prev, next_text, highlighted_text, "characters", opts)
        end

        if #sentence_before < #prev then
            result = "..." .. result
        end
        if #sentence_after < #next_text then
            result = result .. "..."
        end

        local _truncated
        result, _truncated = ScopeResolver.utf8First(result, ScopeResolver.MAX_CONTEXT_CHARS)
        if _truncated then
            result = result .. "..."
        end

        return result
    end
end

return ScopeResolver
