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

-- Minimum useful paragraph-window size per side (UTF-8 chars). Books where every
-- line is its own block (dialogue, scripts, poetry) make "n paragraphs" nearly
-- empty — the containing paragraph of a highlighted speech line is just the
-- speaker tag — so paragraphWindow keeps absorbing outward segments until each
-- side reaches this floor (or runs out). Prose is unaffected: one paragraph
-- already clears it. Stays far under MAX_CONTEXT_CHARS, so the consent-exemption
-- rationale above is untouched.
ScopeResolver.PARAGRAPH_MIN_CHARS = 300

local function utf8Len(s)
    local count = 0
    for _ in s:gmatch(UTF8_CHAR_PATTERN) do count = count + 1 end
    return count
end

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

--- Drop a partial trailing UTF-8 sequence left by a byte cut. Malformed input (no
--- lead byte in reach, stray continuation bytes after ASCII) passes through unchanged
--- rather than triggering unbounded rescans.
function ScopeResolver.utf8TrimTail(s)
    local n = #s
    if n == 0 then return s end
    if s:byte(n) < 0x80 then return s end -- ASCII tail: clean
    local i = n
    while i > 0 and n - i < 4 do
        local b = s:byte(i)
        if b >= 0xC0 then
            -- Found the sequence's lead byte: keep it only if complete
            local need = b >= 0xF0 and 4 or b >= 0xE0 and 3 or 2
            if n - i + 1 >= need then return s end
            return s:sub(1, i - 1)
        elseif b < 0x80 then
            return s -- ASCII followed by stray continuation bytes: malformed, keep
        end
        i = i - 1
    end
    return s -- no lead byte within 4 bytes: malformed, keep
end

--- Drop leading continuation bytes left by a byte cut that started mid-sequence.
function ScopeResolver.utf8TrimHead(s)
    local i = 1
    while i <= #s do
        local b = s:byte(i)
        if b < 0x80 or b >= 0xC0 then break end
        i = i + 1
    end
    return s:sub(i)
end

--- THE byte-budget cuts. Every `text:sub(1, n)` / `text:sub(-n)` on document text that
--- reaches a request goes through these: a cut that lands inside a multi-byte character
--- leaves stray bytes, KOReader's json encoder ships them verbatim, and the provider
--- rejects the whole request as invalid JSON. Budgets stay in BYTES (the caps are byte
--- caps); only the boundary snaps back to a whole character.
function ScopeResolver.utf8Head(str, max_bytes)
    if #str <= max_bytes then return str end
    return ScopeResolver.utf8TrimTail(str:sub(1, max_bytes))
end

function ScopeResolver.utf8Tail(str, max_bytes)
    if #str <= max_bytes then return str end
    return ScopeResolver.utf8TrimHead(str:sub(-max_bytes))
end

--- Byte length of the valid UTF-8 sequence starting at `i`, or nil when the
--- bytes there are not one. Rejects what the standard rejects: continuation
--- bytes with no lead, the overlong C0/C1 heads, surrogates (ED A0..BF) and
--- everything past U+10FFFF (F5..FF).
local function utf8SeqLen(s, i)
    local b = s:byte(i)
    if not b then return nil end
    if b < 0x80 then return 1 end
    if b < 0xC2 then return nil end
    local need, lo, hi
    if b < 0xE0 then
        need, lo, hi = 2, 0x80, 0xBF
    elseif b < 0xF0 then
        need = 3
        lo = (b == 0xE0) and 0xA0 or 0x80
        hi = (b == 0xED) and 0x9F or 0xBF
    elseif b < 0xF5 then
        need = 4
        lo = (b == 0xF0) and 0x90 or 0x80
        hi = (b == 0xF4) and 0x8F or 0xBF
    else
        return nil
    end
    local c = s:byte(i + 1)
    if not c or c < lo or c > hi then return nil end
    for k = 2, need - 1 do
        c = s:byte(i + k)
        if not c or c < 0x80 or c > 0xBF then return nil end
    end
    return need
end

--- Position of the first byte that is not part of a valid UTF-8 sequence, or
--- nil when the string is clean. ASCII runs are jumped in C by the find, so an
--- all-ASCII string costs ONE find and no copy: this runs on every request on
--- e-ink hardware and must not walk the body byte by byte.
function ScopeResolver.utf8FirstBad(s)
    local pos = 1
    while true do
        local i = s:find("[\128-\255]", pos)
        if not i then return nil end
        local len = utf8SeqLen(s, i)
        if not len then return i end
        pos = i + len
    end
end

--- Drop every byte that is not part of a valid UTF-8 sequence.
function ScopeResolver.utf8Repair(s)
    local out, pos, keep_from = {}, 1, 1
    while true do
        local i = s:find("[\128-\255]", pos)
        if not i then break end
        local len = utf8SeqLen(s, i)
        if len then
            pos = i + len
        else
            if i > keep_from then out[#out + 1] = s:sub(keep_from, i - 1) end
            pos = i + 1
            keep_from = pos
        end
    end
    if keep_from == 1 then return s end
    out[#out + 1] = s:sub(keep_from)
    return table.concat(out)
end


--- Real paragraph window: take the last/first n newline-separated segments around
-- the selection. The segment adjacent to the selection is the remainder of the
-- paragraph containing it, so n=1 means "just the containing paragraph". Sides
-- shorter than PARAGRAPH_MIN_CHARS keep absorbing outward segments (single-line-
-- paragraph books would otherwise yield almost nothing). Text with no newlines
-- (PDF/kopt word windows) degrades to the whole capped window.
-- @param prev string text before the selection ("" ok)
-- @param next_text string text after the selection ("" ok)
-- @param n number paragraphs per side (>= 1)
-- @param max_per_side number UTF-8 char cap applied per side
-- @return before, after, before_bounded, after_bounded  (strings, possibly
--         empty; a flag = that side hit a boundary — the char cap or the raw
--         window's edge — so the caller can ellipsize honestly)
function ScopeResolver.paragraphWindow(prev, next_text, n, max_per_side)
    n = (type(n) == "number" and n >= 1) and math.floor(n) or 1
    local floor_chars = ScopeResolver.PARAGRAPH_MIN_CHARS
    if floor_chars > max_per_side then floor_chars = max_per_side end
    local function segments(text)
        local segs = {}
        for seg in text:gmatch("[^\n]+") do
            if seg:match("%S") then table.insert(segs, seg) end
        end
        return segs
    end
    -- Sentence snaps for the CAP cut (device 2026-08-17: the blind utf8 trim
    -- opened the window mid-sentence). Only the cap cut snaps — a raw-window
    -- edge was cut at word granularity upstream and a document edge is already
    -- clean, so snapping those would drop a whole leading sentence. Degrades
    -- to the raw cut when the capped window holds no boundary at all.
    local function snapStartToSentence(text)
        local _, e = text:find("[%.!%?]%s+")
        if e and e < #text then return text:sub(e + 1) end
        return text
    end
    local function snapEndToSentence(text)
        local last
        local pos = 1
        while true do
            local s = text:find("[%.!%?]", pos)
            if not s then break end
            local nxt = text:sub(s + 1, s + 1)
            if nxt == "" or nxt:match("%s") then last = s end
            pos = s + 1
        end
        if last and last < #text then return text:sub(1, last) end
        return text
    end
    local before, after = "", ""
    local before_bounded, after_bounded = false, false
    local prev_segs = segments(prev or "")
    if #prev_segs > 0 then
        local count = math.min(n, #prev_segs)
        before = table.concat(prev_segs, "\n", #prev_segs - count + 1, #prev_segs)
        while utf8Len(before) < floor_chars and count < #prev_segs do
            count = count + 1
            before = table.concat(prev_segs, "\n", #prev_segs - count + 1, #prev_segs)
        end
        -- All segments absorbed = the raw fetch window (or the document) is
        -- the boundary, so the outermost paragraph may be partial
        before_bounded = count >= #prev_segs
    end
    local next_segs = segments(next_text or "")
    if #next_segs > 0 then
        local count = math.min(n, #next_segs)
        after = table.concat(next_segs, "\n", 1, count)
        while utf8Len(after) < floor_chars and count < #next_segs do
            count = count + 1
            after = table.concat(next_segs, "\n", 1, count)
        end
        after_bounded = count >= #next_segs
    end
    local cut
    before, cut = ScopeResolver.utf8Last(before, max_per_side)
    if cut then
        before = snapStartToSentence(before)
        before_bounded = true
    end
    after, cut = ScopeResolver.utf8First(after, max_per_side)
    if cut then
        after = snapEndToSentence(after)
        after_bounded = true
    end
    return before, after, before_bounded, after_bounded
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
    -- include_first_page (round 7, the Scope chip's rule): the row also shows ON the
    -- chapter's first page — the page being read is extractable text, and readers often
    -- sit exactly there after a chapter break ("there is no current chapter to current
    -- position" on device). The quiz presets keep the strict rule.
    local past_start
    if p.include_first_page then
        past_start = cur >= ch.start_page
    else
        past_start = cur > ch.start_page
    end
    if past_start and cur < ch.end_page then
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

--- Resolve a freeform Scope-chip pick into an extractable page range (flexible_scope_plan.md
-- phase 3). Pure decision logic: the session pick + resolved facts in, the effective range
-- out — or nil + a reason the caller turns into UI. Spoiler posture clamps a section's end
-- to the current position (plan §2); picks lying entirely beyond the position are invalid
-- rather than silently empty. The "page" kind never reaches here (no range — the caller
-- extracts the visible page directly).
-- @param pick table { kind = "to_position"|"from_section"|"section"|"range",
--   start_page = N|nil, end_page = N|nil }  -- pages only used by the section/range kinds
-- @param p table { current_page = number, spoiler_free = boolean }
-- @return table|nil { start_page, end_page, clamped = true|nil },
--         string|nil reason when nil: "nothing_read"|"beyond_position"|"bad_pick"
function ScopeResolver.chipScope(pick, p)
    local cur = (p and p.current_page) or 1
    local kind = pick and pick.kind
    if kind == "to_position" then
        if cur <= 1 then return nil, "nothing_read" end
        return { start_page = 1, end_page = cur }
    elseif kind == "from_section" then
        -- End = current position by construction (spoiler-safe); a start beyond the
        -- position is rejected regardless of spoiler posture (mirrors the popup's
        -- pick-time rule).
        if not (pick.start_page) then return nil, "bad_pick" end
        if pick.start_page > cur then return nil, "beyond_position" end
        return { start_page = pick.start_page, end_page = cur }
    elseif kind == "section" or kind == "range" then
        if not (pick.start_page and pick.end_page) then return nil, "bad_pick" end
        if p and p.spoiler_free then
            if pick.start_page > cur then return nil, "beyond_position" end
            if pick.end_page > cur then
                return { start_page = pick.start_page, end_page = cur, clamped = true }
            end
        end
        return { start_page = pick.start_page, end_page = pick.end_page }
    end
    return nil, "bad_pick"
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
    -- Consolidation P5 (2026-08-16, granularity round 2 per maintainer):
    -- after-side limiting — opts.after_limit "none" | "sentence" | "paragraph"
    -- (nil = unlimited). Callers pass it for the global "before only" direction
    -- pick ("none") and for the spoiler clamp (the configured granularity —
    -- the after window can reach up to MAX_CONTEXT_CHARS/2 past the selection
    -- into unread text, but the sentence/paragraph the selection sits in is on
    -- the visible page). Truncating next_text up front covers every mode,
    -- including the sentence→characters starve fallback.
    if opts.after_limit == "none" then
        next_text = ""
    elseif opts.after_limit == "sentence" and next_text ~= "" then
        -- Keep only to the end of the sentence the selection sits in
        local e = next_text:find("[%.!%?]%s") or next_text:find("[%.!%?]$")
        if e then next_text = next_text:sub(1, e) end
    elseif opts.after_limit == "paragraph" and next_text ~= "" then
        -- Keep only the remainder of the selection's own paragraph
        local e = next_text:find("\n")
        if e then next_text = next_text:sub(1, e - 1) end
    end
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
        local before, after, before_bounded, after_bounded =
            ScopeResolver.paragraphWindow(prev, next_text, opts.paragraphs, max_per_side)
        -- Ellipses only when the side actually hit a boundary (the char cap,
        -- sentence-snapped in paragraphWindow, or the raw window's edge). The
        -- old unconditional "..." read as "starts mid-sentence" even on
        -- whole-paragraph windows (device 2026-08-17).
        if #before > 0 and before_bounded then
            before = "..." .. before
        end
        if #after > 0 and after_bounded then
            after = after .. "..."
        end
        return before .. " " .. word_marker .. " " .. after

    else  -- "sentence" mode (default)
        local function findSentenceStart(text)
            -- Granularity round 3 (device 2026-08-16): one FULL sentence before
            -- the selection's own. The old walk took only the text after the
            -- LAST terminator — the start of the selection's own sentence — so
            -- a selection that began its sentence got an EMPTY before side
            -- (device: before blank while the after clause rode along). Collect
            -- sentence-start positions (after each terminator+space run); the
            -- last is the selection's own sentence, the one before it is the
            -- previous full sentence.
            local starts = {}
            local pos = 1
            while true do
                local s, e = text:find("[%.!%?]%s+", pos)
                if not s then break end
                starts[#starts + 1] = e + 1
                pos = e + 1
            end
            local from = starts[#starts - 1] or 1
            return text:sub(from)
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

        -- If sentence parsing finds very little actual context, fall back to
        -- characters mode. Measure the found context alone: the old check measured
        -- the whole result including the >>>highlight<<< marker, so any highlight
        -- longer than ~30 bytes defeated the fallback — dialogue books (one line =
        -- one sentence = one block) then got a starved window.
        if #sentence_before + #sentence_after < 40 then
            return ScopeResolver.trimContext(prev, next_text, highlighted_text, "characters", opts)
        end
        local result = sentence_before .. " " .. word_marker .. " " .. sentence_after

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

--- A short display excerpt around the selection, cut from a trimContext
--- result (its ">>>word<<<" marker). Each side stays inside the word's own
--- paragraph, takes up to `side_bytes` bytes (a byte budget keeps CJK and
--- Latin lines comparable), snaps to whole characters and, where the script
--- has spaces, to whole words; whitespace collapses to single spaces. A side
--- that was cut here or already by trimContext ("...") gets "…". Display
--- only: the dictionary views show it above the answer.
--- @param context string|nil a trimContext result
--- @param side_bytes number|nil per-side budget (default 100)
--- @return string|nil before, string|nil word, string|nil after (nil = no marker)
function ScopeResolver.contextExcerpt(context, side_bytes)
    if type(context) ~= "string" then return nil end
    local s = context:find(">>>", 1, true)
    local e = s and context:find("<<<", s + 3, true)
    if not e then return nil end
    side_bytes = side_bytes or 100
    local function squash(t)
        return (t:gsub("%s+", " "):match("^ ?(.-) ?$"))
    end
    local word = squash(context:sub(s + 3, e - 1))
    if word == "" then return nil end
    local raw_before, raw_after = context:sub(1, s - 1), context:sub(e + 3)
    local before_cut = raw_before:find("^%s*%.%.%.") ~= nil
    local after_cut = raw_after:find("%.%.%.%s*$") ~= nil
    -- Paragraph boundaries (crengine's "\n"): an excerpt never reaches into
    -- the neighbouring paragraph
    local nl_before = raw_before:match("^.*\n(.*)$")
    if nl_before then raw_before, before_cut = nl_before, false end
    local nl_after = raw_after:match("^(.-)\n")
    if nl_after then raw_after, after_cut = nl_after, false end
    local before = squash((raw_before:gsub("^%s*%.%.%.", "")))
    local after = squash((raw_after:gsub("%.%.%.%s*$", "")))
    if #before > side_bytes then
        -- Start on a word boundary (unchanged where the script has no spaces)
        before = squash((ScopeResolver.utf8Tail(before, side_bytes):gsub("^%S*%s", "", 1)))
        before_cut = true
    end
    if #after > side_bytes then
        after = squash((ScopeResolver.utf8Head(after, side_bytes):gsub("%s%S*$", "", 1)))
        after_cut = true
    end
    if before_cut and before ~= "" then before = "…" .. before end
    if after_cut and after ~= "" then after = after .. "…" end
    return before, word, after
end

return ScopeResolver
