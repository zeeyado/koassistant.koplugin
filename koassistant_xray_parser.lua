--- X-Ray JSON parser and renderer
--- Pure data module: no UI dependencies.
--- Handles JSON parsing, markdown rendering, character search, and chapter matching.

local json = require("json")
local logger = require("koassistant_logger")
local _ = require("koassistant_gettext")
local T = require("ffi/util").template
local JsonRepair = require("koassistant_json_repair")

local XrayParser = {}

-- Arabic diacritics normalization constants (built once)
-- All use string.char() for Lua 5.1 compatibility (no \xNN escapes)
local ARABIC_QUICK_CHECK_D8 = string.char(0xD8)
local ARABIC_QUICK_CHECK_D9 = string.char(0xD9)
local ARABIC_QUICK_CHECK_DB = string.char(0xDB)
-- Tashkeel: U+064B-U+065F (fathah, dammah, kasrah, shadda, sukun, etc.)
local TASHKEEL_PAT = string.char(0xD9) .. "[" .. string.char(0x8B) .. "-" .. string.char(0x9F) .. "]"
-- Quranic annotation signs: U+0610-U+061A
local SIGN_PAT = string.char(0xD8) .. "[" .. string.char(0x90) .. "-" .. string.char(0x9A) .. "]"
-- Quranic marks: U+06D6-U+06DC
local QURAN_MARK_PAT1 = string.char(0xDB) .. "[" .. string.char(0x96) .. "-" .. string.char(0x9C) .. "]"
-- Extended Quranic marks: U+06DE-U+06ED (includes U+06E1 small sukun)
local QURAN_MARK_PAT2 = string.char(0xDB) .. "[" .. string.char(0x9E) .. "-" .. string.char(0xAD) .. "]"
-- Individual characters to strip/replace
local SUPERSCRIPT_ALEF = string.char(0xD9, 0xB0)  -- U+0670 (dagger alef → regular alef)
local TATWEEL          = string.char(0xD9, 0x80)   -- U+0640
local WORD_JOINER      = string.char(0xE2, 0x81, 0xA0) -- U+2060
-- Alef normalization: variants → regular alef (U+0627)
local ALEF             = string.char(0xD8, 0xA7)   -- U+0627 regular alef
local ALEF_WASLA       = string.char(0xD9, 0xB1)   -- U+0671
local ALEF_MADDA       = string.char(0xD8, 0xA2)   -- U+0622
local ALEF_HAMZA_ABOVE = string.char(0xD8, 0xA3)   -- U+0623
local ALEF_HAMZA_BELOW = string.char(0xD8, 0xA5)   -- U+0625
-- Tanwin fathah + alef: accusative ending ًا — strip before tashkeel removal
local TANWIN_FATHAH_ALEF = string.char(0xD9, 0x8B, 0xD8, 0xA7) -- U+064B + U+0627

--- Normalize Arabic text for fuzzy matching.
--- Strips diacritical marks (tashkeel), Quranic annotation marks,
--- and normalizes alef variants to regular alef.
--- No-op on non-Arabic text (fast byte check).
--- @param str string Input string (typically already lowered)
--- @return string Normalized string
function XrayParser.normalizeArabic(str)
    if not str or str == "" then return str end
    -- Quick check: skip if no Arabic-range leading bytes present
    if not str:find(ARABIC_QUICK_CHECK_D8, 1, true)
        and not str:find(ARABIC_QUICK_CHECK_D9, 1, true)
        and not str:find(ARABIC_QUICK_CHECK_DB, 1, true) then
        return str
    end
    -- Strip tanwin fathah + alef (accusative ending ًا) before tashkeel removal,
    -- so "نَارًا" normalizes to "نار" not "نارا"
    str = str:gsub(TANWIN_FATHAH_ALEF, "")
    -- Strip combining marks
    str = str:gsub(TASHKEEL_PAT, "")
    str = str:gsub(SIGN_PAT, "")
    str = str:gsub(QURAN_MARK_PAT1, "")
    str = str:gsub(QURAN_MARK_PAT2, "")
    str = str:gsub(SUPERSCRIPT_ALEF, ALEF)
    str = str:gsub(TATWEEL, "")
    str = str:gsub(WORD_JOINER, "")
    -- Normalize alef variants to regular alef
    str = str:gsub(ALEF_WASLA, ALEF)
    str = str:gsub(ALEF_MADDA, ALEF)
    str = str:gsub(ALEF_HAMZA_ABOVE, ALEF)
    str = str:gsub(ALEF_HAMZA_BELOW, ALEF)
    return str
end

--- Check whether a string contains Arabic script characters.
--- @param str string
--- @return boolean
function XrayParser.containsArabic(str)
    if not str then return false end
    -- Arabic block leading bytes: 0xD8 covers U+0600-U+063F, 0xD9 covers U+0640-U+067F
    return str:find(ARABIC_QUICK_CHECK_D8, 1, true) ~= nil
        or str:find(ARABIC_QUICK_CHECK_D9, 1, true) ~= nil
end

-- SRELL optional combining marks class: tashkeel + superscript alef +
-- Quranic signs + Quranic marks + tatweel + ZWJ/ZWNJ + word joiner
local SRELL_OPT_MARKS = "[\\u064B-\\u065F\\u0670\\u0610-\\u061A\\u06D6-\\u06ED\\u0640\\u200C-\\u200D\\u2060]*"
-- Alef variants: match any alef form in the document
local SRELL_ALEF_CLASS = "[\\u0627\\u0671\\u0622\\u0623\\u0625]"
-- Arabic definite article ال (UTF-8)
local AL_PREFIX = string.char(0xD8, 0xA7, 0xD9, 0x84)
local AL_PREFIX_LEN = #AL_PREFIX

--- Convert a normalized Arabic string to a SRELL regex with optional combining marks.
--- @param normalized string Already-normalized Arabic text
--- @return string regex SRELL regex pattern
local function arabicToRegex(normalized)
    local parts = {}
    local i = 1
    local len = #normalized

    while i <= len do
        local b = normalized:byte(i)
        if b < 128 then
            if b == 0x20 then
                parts[#parts + 1] = "\\s+"
            else
                local ch = normalized:sub(i, i)
                if ch:match("[%.%+%*%?%[%]%^%$%(%)%{%}%|\\]") then
                    parts[#parts + 1] = "\\" .. ch
                else
                    parts[#parts + 1] = ch
                end
            end
            i = i + 1
        elseif b >= 0xC0 and b < 0xE0 then
            local b2 = normalized:byte(i + 1)
            if not b2 then break end
            local cp = (b - 0xC0) * 64 + (b2 - 0x80)
            if cp >= 0x0600 and cp <= 0x06FF then
                if cp == 0x0627 then
                    -- Alef: optional group — dagger alef (U+0670) in Quranic text
                    -- is consumed by preceding OPT_MARKS, so the full alef letter
                    -- may be absent. Making it optional lets "الغاشية" match "ٱلۡغَٰشِيَةِ".
                    parts[#parts + 1] = "(?:" .. SRELL_ALEF_CLASS .. SRELL_OPT_MARKS .. ")?"
                else
                    parts[#parts + 1] = string.format("\\u%04X", cp) .. SRELL_OPT_MARKS
                end
            else
                parts[#parts + 1] = string.format("\\u%04X", cp)
            end
            i = i + 2
        elseif b >= 0xE0 and b < 0xF0 then
            local b2, b3 = normalized:byte(i + 1), normalized:byte(i + 2)
            if not b2 or not b3 then break end
            local cp = (b - 0xE0) * 4096 + (b2 - 0x80) * 64 + (b3 - 0x80)
            parts[#parts + 1] = string.format("\\u%04X", cp)
            i = i + 3
        elseif b >= 0xF0 then
            i = i + 4
        else
            i = i + 1
        end
    end

    return table.concat(parts)
end

--- Strip Arabic definite article ال from the beginning and after spaces.
--- @param normalized string Already-normalized Arabic text
--- @return string stripped Text with ال removed, or original if no ال found
local function stripArabicArticle(normalized)
    local stripped = normalized
    if stripped:sub(1, AL_PREFIX_LEN) == AL_PREFIX then
        stripped = stripped:sub(AL_PREFIX_LEN + 1)
    end
    stripped = stripped:gsub(" " .. AL_PREFIX, " ")
    return stripped
end

--- Build a diacritics-tolerant regex for searching Arabic text.
--- Converts an Arabic search term into a SRELL-compatible regex where each
--- Arabic letter is followed by an optional combining marks class, so that
--- "الفلق" matches "ٱلْفَلَقِ" in diacritized text.
--- Also includes an ال-stripped alternative so "النادي" matches "نَادِيَهُۥ".
--- Returns nil for non-Arabic terms (caller should use plain search).
--- @param term string The search term
--- @return string|nil regex SRELL regex pattern, or nil if not Arabic
function XrayParser.buildArabicSearchRegex(term)
    if not term or term == "" then return nil end
    if not XrayParser.containsArabic(term) then return nil end

    local normalized = XrayParser.normalizeArabic(term:lower())
    local regex = arabicToRegex(normalized)

    -- Also match without ال (definite article) on each word
    local stripped = stripArabicArticle(normalized)
    if stripped ~= normalized and #stripped > 4 then
        regex = regex .. "|" .. arabicToRegex(stripped)
    end

    return regex
end

-- AI responses sometimes return strings for array fields. Normalize to table.
local function ensure_array(val)
    if type(val) == "table" then return val end
    if type(val) == "string" and val ~= "" then return { val } end
    return nil
end

--- Detect whether a cache result string is JSON or legacy markdown
--- Checks for raw JSON, code-fenced JSON, and JSON preceded by text
--- @param result string The cached result text
--- @return boolean is_json True if result appears to be JSON
function XrayParser.isJSON(result)
    if type(result) ~= "string" then return false end
    -- Raw JSON starting with {
    if result:match("^%s*{") then return true end
    -- Code-fenced JSON (```json ... ``` or ``` { ... ```)
    if result:match("```json%s*{") or result:match("```%s*{") then return true end
    -- JSON embedded after some preamble text (look for { within first 200 chars)
    local first_brace = result:find("{")
    if first_brace and first_brace <= 200 then return true end
    return false
end

-- Known category keys for validating parsed X-Ray data
local FICTION_KEYS = { "characters", "locations", "themes", "lexicon", "timeline", "current_state", "conclusion" }
local NONFICTION_KEYS = { "key_figures", "locations", "core_concepts", "arguments", "terminology", "argument_development", "current_position", "conclusion" }
local ACADEMIC_KEYS = { "key_concepts", "foundations", "methodology", "findings", "referenced_works", "technical_terms", "figures_data", "current_position", "conclusion" }

-- Build normalized key → canonical key map for fuzzy matching.
-- Normalizing = lowercase + strip separators (_, -, spaces).
-- Catches all variants: camelCase, PascalCase, kebab-case, concatenated, etc.
local CANONICAL_KEY_MAP = {}
local function normalizeKeyString(key)
    return key:lower():gsub("[_%- ]", "")
end
for _idx, key in ipairs(FICTION_KEYS) do
    CANONICAL_KEY_MAP[normalizeKeyString(key)] = key
end
for _idx, key in ipairs(NONFICTION_KEYS) do
    CANONICAL_KEY_MAP[normalizeKeyString(key)] = key
end
for _idx, key in ipairs(ACADEMIC_KEYS) do
    CANONICAL_KEY_MAP[normalizeKeyString(key)] = key
end

--- Normalize AI-hallucinated key variants to canonical names in-place.
--- Uses normalize-based matching: lowercase + strip separators → match canonical.
--- Unknown keys that don't match any canonical key are silently ignored.
--- @param data table Candidate parsed data
local function normalizeKeyAliases(data)
    if type(data) ~= "table" then return end
    local to_rename = {}
    for key, value in pairs(data) do
        if type(key) == "string" then
            local canonical = CANONICAL_KEY_MAP[normalizeKeyString(key)]
            if canonical and canonical ~= key and not data[canonical] then
                to_rename[key] = { canonical = canonical, value = value }
            end
        end
    end
    for old_key, info in pairs(to_rename) do
        data[info.canonical] = info.value
        data[old_key] = nil
    end
end

-- ============== Parse-time shape normalization (#90 field report) ==============
-- Weak models emit structurally creative JSON: objects where strings belong
-- ({"name": "X", "relationship": "friend"} inside connections), bare strings
-- where objects belong (a timeline of plain strings rendered every Story Arc
-- row as "Unknown"), maps where arrays belong, numbers for strings. Downstream
-- code concatenates these; a single table element crashed renderToMarkdown in
-- an update's on_complete — losing the merged result AND taking KOReader down
-- (issue #90 crash.log 2026-08-07). Normalize once at parse so every consumer
-- (render, browser rows, search, entity index) sees canonical shapes.
-- Well-formed data passes through unchanged; stored artifacts heal on read.

-- Best-effort string coercion for a value that should have been a string.
local function coerceText(val)
    if type(val) == "string" then return val end
    if type(val) == "number" then return tostring(val) end
    if type(val) == "table" then
        -- Objects: prefer the identity fields models actually emit
        local name
        for _idx, f in ipairs({ "name", "term", "event", "text", "title" }) do
            if type(val[f]) == "string" and val[f] ~= "" then
                name = val[f]
                break
            end
        end
        if name then
            local rel = type(val.relationship) == "string" and val.relationship ~= ""
                and val.relationship
                or type(val.role) == "string" and val.role ~= "" and val.role
            if rel then
                return name .. " (" .. rel .. ")"
            end
            return name
        end
        if type(val.description) == "string" and val.description ~= "" then
            return val.description
        end
        -- Last resort: join the object's string values (sorted — pairs order
        -- is nondeterministic and this must be stable across re-parses)
        local parts = {}
        for _k, v in pairs(val) do
            if type(v) == "string" and v ~= "" then parts[#parts + 1] = v end
        end
        table.sort(parts)
        if #parts > 0 then return table.concat(parts, " — ") end
    end
    return nil
end

-- Coerce a should-be-array-of-strings; nil when nothing survives.
local function coerceStringArray(val)
    if type(val) == "string" then
        return val ~= "" and { val } or nil
    end
    if type(val) ~= "table" then return nil end
    local out = {}
    for _idx, v in ipairs(val) do
        local s = coerceText(v)
        if s and s ~= "" then out[#out + 1] = s end
    end
    return #out > 0 and out or nil
end

-- Keep only well-formed background lines ({ source, text [, file] } — the
-- code-owned cross-book shape). Malformed lines are dropped, never coerced.
local function sanitizeBackground(val)
    if type(val) ~= "table" then return nil end
    local out = {}
    for _idx, b in ipairs(val) do
        if type(b) == "table" and type(b.text) == "string" and b.text ~= "" then
            out[#out + 1] = {
                source = type(b.source) == "string" and b.source ~= "" and b.source or "?",
                text = b.text,
                file = type(b.file) == "string" and b.file ~= "" and b.file or nil,
            }
        end
    end
    return #out > 0 and out or nil
end

-- Fields normalized on every entity/event item
local ITEM_STRING_FIELDS = { "name", "term", "event", "role", "description",
    "significance", "importance", "details", "definition", "evidence", "chapter" }
local ITEM_ARRAY_FIELDS = { "aliases", "connections", "references", "characters" }
-- Categories keyed by something other than `name`
local ENTITY_NAME_FIELD = {
    lexicon = "term", terminology = "term", technical_terms = "term",
    timeline = "event", argument_development = "event",
}
local SINGLETON_KEYS = { current_state = true, current_position = true, conclusion = true }
local SINGLETON_ARRAY_FIELDS = { "conflicts", "questions", "questions_addressed",
    "building_toward", "resolutions", "themes_resolved", "key_findings", "implications" }

local function normalizeItem(item, name_field)
    if type(item) == "string" then
        if item == "" then return nil end
        return { [name_field] = item }
    end
    if type(item) ~= "table" then return nil end
    for _idx, f in ipairs(ITEM_STRING_FIELDS) do
        if item[f] ~= nil and type(item[f]) ~= "string" then
            item[f] = coerceText(item[f])
        end
    end
    for _idx, f in ipairs(ITEM_ARRAY_FIELDS) do
        if item[f] ~= nil then
            item[f] = coerceStringArray(item[f])
        end
    end
    if item.background ~= nil then
        item.background = sanitizeBackground(item.background)
    end
    return item
end

--- Normalize category shapes in-place. Idempotent; runs on every successful
--- parse (fresh responses AND stored artifacts). `__dormant` is deliberately
--- untouched — it is code-owned and never model-shaped.
--- @param data table Parsed X-Ray data (mutated)
local function normalizeShapes(data)
    if type(data) ~= "table" then return end
    -- reader_engagement is REMOVED as a feature (maintainer 2026-08-18): the
    -- X-Ray no longer requests, stores, or shows the section. Legacy artifacts
    -- still carry it; stripping at the parse chokepoint makes every consumer
    -- blind to it at once, and the next write persists the removal.
    data.reader_engagement = nil
    local seen = {}
    for _i, list in ipairs({ FICTION_KEYS, NONFICTION_KEYS, ACADEMIC_KEYS }) do
        for _j, key in ipairs(list) do
            if not seen[key] then
                seen[key] = true
                local val = data[key]
                if SINGLETON_KEYS[key] then
                    if type(val) == "string" and val ~= "" then
                        val = { summary = val }
                        data[key] = val
                    end
                    if type(val) == "table" then
                        if val.summary ~= nil and type(val.summary) ~= "string" then
                            val.summary = coerceText(val.summary)
                        end
                        for _k, f in ipairs(SINGLETON_ARRAY_FIELDS) do
                            if val[f] ~= nil then val[f] = coerceStringArray(val[f]) end
                        end
                    end
                elseif type(val) == "table" then
                    -- Entity/event array category
                    local name_field = ENTITY_NAME_FIELD[key] or "name"
                    local out = {}
                    for _n, item in ipairs(val) do
                        local norm = normalizeItem(item, name_field)
                        if norm then out[#out + 1] = norm end
                    end
                    -- Map-instead-of-array salvage ({"Name": {...}, ...}):
                    -- entries keyed by entity name, no array part at all
                    if #out == 0 and next(val) ~= nil then
                        local names = {}
                        for k, v in pairs(val) do
                            if type(k) == "string" and k ~= "" and type(v) == "table" then
                                names[#names + 1] = k
                            end
                        end
                        table.sort(names)
                        for _n, k in ipairs(names) do
                            local v = val[k]
                            if type(v[name_field]) ~= "string" or v[name_field] == "" then
                                v[name_field] = k
                            end
                            local norm = normalizeItem(v, name_field)
                            if norm then out[#out + 1] = norm end
                        end
                    end
                    data[key] = out
                end
            end
        end
    end
    -- Cross-book merge deltas: background_updates pairs
    if type(data.background_updates) == "table" then
        local out = {}
        for _n, upd in ipairs(data.background_updates) do
            if type(upd) == "table" then
                if upd.name ~= nil and type(upd.name) ~= "string" then
                    upd.name = coerceText(upd.name)
                end
                if upd.background ~= nil and type(upd.background) ~= "string" then
                    upd.background = coerceText(upd.background)
                end
                if upd.aliases ~= nil then
                    upd.aliases = coerceStringArray(upd.aliases)
                end
                out[#out + 1] = upd
            end
        end
        data.background_updates = out
    end
end

--- Check if a table looks like valid X-Ray data (has at least one recognized category key)
--- Also infers and sets the type field if missing.
--- @param data table Candidate parsed data
--- @return boolean valid True if data has recognized X-Ray structure
local function isValidXrayData(data)
    if type(data) ~= "table" then return false end
    -- Check for error response
    if data.error then return true end
    -- Normalize common key variants before checking
    normalizeKeyAliases(data)
    -- Cross-book merge deltas (item 44) may carry ONLY mechanical background
    -- updates — recognize them so such a delta parses without a category key
    if type(data.background_updates) == "table" then return true end
    -- Check for fiction keys
    for _idx, key in ipairs(FICTION_KEYS) do
        if data[key] then
            if not data.type then data.type = "fiction" end
            return true
        end
    end
    -- Check for academic keys (before nonfiction: unique keys come first in array)
    for _idx, key in ipairs(ACADEMIC_KEYS) do
        if data[key] then
            if not data.type then data.type = "academic" end
            return true
        end
    end
    -- Check for non-fiction keys
    for _idx, key in ipairs(NONFICTION_KEYS) do
        if data[key] then
            if not data.type then data.type = "nonfiction" end
            return true
        end
    end
    return false
end

--- Attempt to extract valid JSON from a potentially wrapped response
--- Tries: raw decode, code fence stripping, first-brace-to-last-brace extraction
--- Accepts any table with recognized X-Ray category keys (type field inferred if missing).
--- @param text string The raw AI response
--- @return table|nil data Parsed Lua table, or nil on failure
--- @return string|nil err Error message if all attempts failed
function XrayParser.parse(text)
    if type(text) ~= "string" or text == "" then
        return nil, "empty input"
    end

    -- Attempt 1: direct decode.
    -- `decode_err` carries the LAST decode failure so callers can say WHY a
    -- response was rejected. Three checkpoint builds died on "not valid JSON"
    -- with no further detail on 2026-08-18, and the message conflates two very
    -- different failures: a genuine syntax error, and a decode that SUCCEEDED
    -- whose object carried no recognized X-Ray key (isValidXrayData).
    local decode_err
    local ok, data = pcall(json.decode, text)
    if ok and isValidXrayData(data) then
        normalizeShapes(data)
        return data, nil
    end
    decode_err = (not ok) and tostring(data)
        or "decoded, but no recognized X-Ray key (isValidXrayData)"

    -- Attempt 2: strip markdown code fences (find-based to cross newlines)
    local fence_open = text:find("```json%s*\n") or text:find("```%s*\n")
    local content_start
    if fence_open then
        content_start = text:find("\n", fence_open) + 1
        -- Find the LAST ``` after the opening fence (handles trailing text after fence)
        local fence_close
        local search_pos = content_start
        while true do
            local pos = text:find("\n%s*```", search_pos)
            if pos then
                fence_close = pos
                search_pos = pos + 4
            else
                break
            end
        end
        if fence_close then
            local stripped = text:sub(content_start, fence_close - 1)
            ok, data = pcall(json.decode, stripped)
            if ok and isValidXrayData(data) then
                normalizeShapes(data)
                return data, nil
            end
            decode_err = (not ok) and ("fenced: " .. tostring(data))
                or "fenced: decoded, but no recognized X-Ray key"
        end
    end

    -- Attempt 3: extract from first { to last }
    -- If code fence was found, start after it (skip thinking text braces before fence)
    local first_brace = text:find("{", content_start or 1)
    -- Scan backwards (Lua's .* doesn't cross newlines)
    local last_brace
    for i = #text, 1, -1 do
        if text:byte(i) == 125 then -- }
            last_brace = i
            break
        end
    end
    local extracted
    if first_brace and last_brace and last_brace > first_brace then
        extracted = text:sub(first_brace, last_brace)
        ok, data = pcall(json.decode, extracted)
        if ok and isValidXrayData(data) then
            normalizeShapes(data)
            return data, nil
        end
    end

    -- Attempt 4: repair unescaped inner double quotes (a model can leave a raw " inside a
    -- description or alias), then retry the best candidate. Only reached after strict parsing
    -- failed, so it can't make a parseable response worse.
    local candidate = extracted or text
    ok, data = pcall(json.decode, JsonRepair.escapeInnerQuotes(candidate))
    if ok and isValidXrayData(data) then
        logger.dbg("XrayParser: parsed via unescaped-quote repair")
        normalizeShapes(data)
        return data, nil
    end

    -- Attempt 4b: a key missing its opening quote (`themes_resolved": [`), a
    -- one-character defect that failed a whole 166K-token build on 2026-08-25.
    -- Line-anchored, so it never touches string contents; layered with the
    -- quote repair for responses carrying both.
    local keyed = JsonRepair.quoteBareKeys(candidate)
    if keyed ~= candidate then
        ok, data = pcall(json.decode, keyed)
        if not (ok and isValidXrayData(data)) then
            ok, data = pcall(json.decode, JsonRepair.escapeInnerQuotes(keyed))
        end
        if ok and isValidXrayData(data) then
            logger.dbg("XrayParser: parsed via bare-key repair")
            normalizeShapes(data)
            return data, nil
        end
        candidate = keyed
    end

    -- Attempt 5: drop stray closing braces/brackets (2026-08-18, from a live
    -- rejected checkpoint rung): one extra `}`/`]` in an otherwise-valid
    -- response crashes the bundled decoder with the state.lua:81 'active'
    -- error rather than a syntax message. Same only-after-strict-failure rule
    -- as attempt 4; the quote repair is layered on top for responses carrying
    -- both defects.
    local rebalanced = JsonRepair.dropExtraClosers(candidate)
    if rebalanced == candidate then
        -- Not over-closed; try the mirror defect (complete document, closers
        -- missing at the end — the "Unclosed elements present" class).
        rebalanced = JsonRepair.closeUnclosed(candidate)
    end
    if rebalanced ~= candidate then
        ok, data = pcall(json.decode, rebalanced)
        if not (ok and isValidXrayData(data)) then
            ok, data = pcall(json.decode, JsonRepair.escapeInnerQuotes(rebalanced))
        end
        if ok and isValidXrayData(data) then
            logger.dbg("XrayParser: parsed via bracket-balance repair")
            normalizeShapes(data)
            return data, nil
        end
    end

    return nil, decode_err or "failed to parse JSON from response"
end

--- True when a model response is well-formed JSON that carries NO X-Ray
--- content — `{}`, `{"background_updates": []}`, `{"characters": []}`, or any
--- object whose every value is an empty table/string. Round 28 (#90 device
--- report: merging two unrelated books reported "response is not a valid
--- X-Ray JSON structure"): for the cross-book merge an empty delta is the
--- CORRECT answer for books that share nothing, but `{}` fails
--- isValidXrayData (no recognized key) and so was indistinguishable from
--- garbage. Callers use this to tell "nothing to merge" from "bad response".
--- @param text string Raw model output
--- @return boolean
function XrayParser.isEmptyDelta(text)
    if type(text) ~= "string" or text == "" then return false end
    local candidate = text
    -- Same fence tolerance as parse()
    local fence_open = text:find("```json%s*\n") or text:find("```%s*\n")
    if fence_open then
        local content_start = text:find("\n", fence_open)
        if content_start then
            local rest = text:sub(content_start + 1)
            local fence_close = rest:find("```")
            candidate = fence_close and rest:sub(1, fence_close - 1) or rest
        end
    end
    local first_brace = candidate:find("{")
    local last_brace
    for i = #candidate, 1, -1 do
        if candidate:byte(i) == 125 then last_brace = i break end
    end
    if not (first_brace and last_brace and last_brace > first_brace) then return false end
    local ok, data = pcall(json.decode, candidate:sub(first_brace, last_brace))
    if not ok or type(data) ~= "table" then return false end
    for _key, value in pairs(data) do
        if type(value) == "table" then
            if next(value) ~= nil then return false end
        elseif type(value) == "string" then
            if value ~= "" then return false end
        elseif value ~= nil then
            return false
        end
    end
    return true
end

--- Check if X-Ray data is fiction type
--- Falls back to key-based detection if type field is missing
--- @param data table Parsed X-Ray data
--- @return boolean
function XrayParser.isFiction(data)
    if data.type then return data.type == "fiction" end
    -- Infer from keys: fiction has "characters", nonfiction has "key_figures"
    return data.characters ~= nil
end

--- Check if X-Ray data is academic type
--- Falls back to key-based detection if type field is missing
--- @param data table Parsed X-Ray data
--- @return boolean
function XrayParser.isAcademic(data)
    if data.type then return data.type == "academic" end
    -- Infer from keys: academic has "key_concepts" and "methodology"
    return data.key_concepts ~= nil and data.methodology ~= nil
end

--- Get the key used for characters/figures in this X-Ray type
--- @param data table Parsed X-Ray data
--- @return string key "characters" for fiction, "key_figures" for non-fiction
function XrayParser.getCharacterKey(data)
    return XrayParser.isFiction(data) and "characters" or "key_figures"
end

--- Get characters/figures array from X-Ray data
--- @param data table Parsed X-Ray data
--- @return table characters Array of character/figure entries
function XrayParser.getCharacters(data)
    local key = XrayParser.getCharacterKey(data)
    return data[key] or {}
end

--- Get the searchable name for an item (name, term, or event depending on type)
--- @param item table An X-Ray item entry
--- @return string|nil name The name to search for, or nil
local function getItemSearchName(item)
    return item.name or item.term or item.event
end

--- Count occurrences of a single item (name + aliases) in pre-lowered text.
--- Finds all match spans from name and aliases, merges overlapping spans,
--- and returns the total unique matches (union semantics, same as regex OR).
--- @param item table An X-Ray item entry (must have name/term/event and optionally aliases)
--- @param text_lower string Already-lowered text to search
--- @param exclude_handles table|nil XrayParser.containingHandles output: spans inside an
---   occurrence of another entity's longer handle are not counted (B266)
--- @return number count Unique match count across name and all aliases (0 if not found or name ≤2 chars)
function XrayParser.countItemOccurrences(item, text_lower, exclude_handles)
    local name = getItemSearchName(item)
    if not name or #name <= 2 then return 0 end

    local name_lower = name:lower()

    -- Collect all search terms
    local terms = {}

    -- Handle parenthetical names: "Theosis (Deification)" → "theosis" + "deification"
    local clean_name = name_lower:gsub("%s*%(.-%)%s*", "")
    clean_name = clean_name:match("^%s*(.-)%s*$") or clean_name  -- trim
    local paren_content = name_lower:match("%((.-)%)")

    terms[#terms + 1] = (#clean_name > 2) and clean_name or name_lower

    if paren_content and #paren_content > 2 and not paren_content:match("^%d+$") then
        terms[#terms + 1] = paren_content
    end

    local item_aliases = ensure_array(item.aliases)
    if item_aliases then
        for _idx, alias in ipairs(item_aliases) do
            if #alias > 2 then
                terms[#terms + 1] = alias:lower()
            end
        end
    end

    -- Normalize terms for Arabic diacritics matching
    for i = 1, #terms do
        terms[i] = XrayParser.normalizeArabic(terms[i])
    end

    -- Arabic: also try matching without ال (definite article) on each word.
    -- "النادي" won't substring-match "ناديه" but "نادي" will.
    local term_count = #terms
    for i = 1, term_count do
        local t = terms[i]
        if XrayParser.containsArabic(t) then
            local stripped = stripArabicArticle(t)
            if stripped ~= t and #stripped > 4 then
                terms[#terms + 1] = stripped
            end
        end
    end

    -- Collect all match spans from all terms
    local all_spans = {}
    for _idx, term in ipairs(terms) do
        local spans = XrayParser._collectMatchSpans(text_lower, term)
        for _idx2, span in ipairs(spans) do
            all_spans[#all_spans + 1] = span
        end
    end

    -- Cross-entity containment (B266): a span sitting inside an occurrence
    -- of another entity's longer handle is that entity's mention
    if exclude_handles and #exclude_handles > 0 and #all_spans > 0 then
        local ex = {}
        for _idx, h in ipairs(exclude_handles) do
            for _idx2, span in ipairs(XrayParser._collectMatchSpans(text_lower, h)) do
                ex[#ex + 1] = span
            end
        end
        if #ex > 0 then
            local kept = {}
            for _idx, span in ipairs(all_spans) do
                local inside = false
                for _idx2, x in ipairs(ex) do
                    if span[1] >= x[1] and span[2] <= x[2] then
                        inside = true
                        break
                    end
                end
                if not inside then kept[#kept + 1] = span end
            end
            all_spans = kept
        end
    end

    if #all_spans == 0 then return 0 end
    if #all_spans == 1 then return 1 end

    -- Sort by start position
    table.sort(all_spans, function(a, b)
        return a[1] < b[1]
    end)

    -- Merge overlapping spans and count unique matches
    local count = 1
    local current_end = all_spans[1][2]
    for i = 2, #all_spans do
        if all_spans[i][1] > current_end then
            -- No overlap: new distinct match
            count = count + 1
            current_end = all_spans[i][2]
        elseif all_spans[i][2] > current_end then
            -- Overlapping: extend current span (don't increment count)
            current_end = all_spans[i][2]
        end
    end

    return count
end

--- Singleton categories not useful for chapter text matching
local SINGLETON_CATEGORIES = {
    current_state = true,
    current_position = true,
    reader_engagement = true,
    conclusion = true,
}

--- Categories excluded from chapter text matching
--- Event-based categories have descriptive phrases as "names" (not searchable entity names),
--- which produces misleading counts (e.g., "Chapter 5 describes..." matching common words)
local TEXT_MATCH_EXCLUDED = {
    current_state = true,
    current_position = true,
    reader_engagement = true,
    conclusion = true,
    arguments = true,
    argument_development = true,
    timeline = true,
    findings = true,
    figures_data = true,
}
-- Exported: the marks scan's rebuild diagnostics tally what this gate
-- skipped (slice 2 round 5)
XrayParser.TEXT_MATCH_EXCLUDED = TEXT_MATCH_EXCLUDED

--- Resolve a connection/reference string to any X-Ray item
--- Searches all categories: characters, locations, concepts, themes, etc.
--- Connection strings follow the format "Name (relationship)" or just "Name"
--- @param data table Parsed X-Ray data
--- @param connection_string string e.g. "Elizabeth Bennet (love interest)" or "Constantinople"
--- @return table|nil result { item, category_key, name_portion, relationship } or nil if not found
function XrayParser.resolveConnection(data, connection_string)
    if not connection_string or connection_string == "" then return nil end

    -- A connection is written "Name (relationship)", but a NAME may itself
    -- carry a disambiguating parenthetical: one artifact holds both
    -- "John Jackson (the black)" and "John Jackson (the white)", another both
    -- "Ayesha (of Titlipur)" and "Ayesha (wife of Mahound)". So the string is
    -- ambiguous on its face and we try three readings, longest first, each as
    -- a (handle, annotation) pair:
    --   1. the WHOLE string is the name          -- "John Jackson (the black)"
    --   2. all but the LAST group is the name    -- "John Jackson (the black)" + "killed by Yumas"
    --   3. up to the FIRST group is the name     -- "John Jackson" + "the black"
    -- Reading 3 alone (the original) reduced every such connection to the
    -- shared handle, which the exact pass missed and the substring pass then
    -- resolved to whichever entry sorted first — so half the buttons opened
    -- the wrong character, and the name's own qualifier was displayed as if it
    -- were the relationship.
    local function trim(v) return v and (v:match("^%s*(.-)%s*$")) or v end
    local last_group = connection_string:match("(%b())%s*$")
    local candidates = {
        { handle = trim(connection_string) },
    }
    if last_group then
        local without_last = trim(connection_string:match("^(.*)%s*%b()%s*$"))
        if without_last and without_last ~= "" then
            candidates[#candidates + 1] = {
                handle = without_last, relationship = last_group:sub(2, -2),
            }
        end
    end
    local first_group = connection_string:match("%((.-)%)")
    local short_handle = trim(connection_string:match("^(.-)%s*%("))
    if short_handle and short_handle ~= "" then
        candidates[#candidates + 1] = { handle = short_handle, relationship = first_group }
    end

    -- De-duplicate identical handles, keeping the FIRST (longest) reading
    local seen_handle, ordered = {}, {}
    for _idx, c in ipairs(candidates) do
        if c.handle and c.handle ~= "" and not seen_handle[c.handle] then
            seen_handle[c.handle] = true
            ordered[#ordered + 1] = c
        end
    end
    if #ordered == 0 then return nil end

    local categories = XrayParser.getCategories(data)
    local normalize = XrayParser.normalizeArabic

    -- Build flat list of searchable items with their category keys
    -- Skip singleton categories (current_state, current_position, reader_engagement)
    local searchable = {}
    for _idx, cat in ipairs(categories) do
        if not SINGLETON_CATEGORIES[cat.key] then
            for _idx2, item in ipairs(cat.items) do
                table.insert(searchable, { item = item, category_key = cat.key })
            end
        end
    end

    if #searchable == 0 then return nil end

    local function hit(entry, c)
        return { item = entry.item, category_key = entry.category_key,
                 name_portion = c.handle, relationship = c.relationship }
    end

    -- Pass 0: exact name match, longest reading first — a name carrying its own
    -- parenthetical beats the ambiguous shared handle
    for _ci, c in ipairs(ordered) do
        local c_lower = normalize(c.handle:lower())
        for _idx, entry in ipairs(searchable) do
            local item_name = getItemSearchName(entry.item)
            if item_name and normalize(item_name:lower()) == c_lower then
                return hit(entry, c)
            end
        end
    end

    local name_portion = ordered[#ordered].handle
    local relationship = ordered[#ordered].relationship
    local name_lower = normalize(name_portion:lower())

    -- Pass 1: exact name match (name, term, or event)
    for _idx, entry in ipairs(searchable) do
        local item_name = getItemSearchName(entry.item)
        if item_name and normalize(item_name:lower()) == name_lower then
            return { item = entry.item, category_key = entry.category_key,
                     name_portion = name_portion, relationship = relationship }
        end
    end

    -- Pass 2: alias match (characters/key_figures only)
    for _idx, entry in ipairs(searchable) do
        local aliases = ensure_array(entry.item.aliases)
        if aliases then
            for _idx2, alias in ipairs(aliases) do
                if normalize(alias:lower()) == name_lower then
                    return { item = entry.item, category_key = entry.category_key,
                             name_portion = name_portion, relationship = relationship }
                end
            end
        end
    end

    -- Pass 3: substring match on name (e.g., "Elizabeth" matches "Elizabeth Bennet")
    for _idx, entry in ipairs(searchable) do
        local item_name = getItemSearchName(entry.item)
        if item_name and normalize(item_name:lower()):find(name_lower, 1, true) then
            return { item = entry.item, category_key = entry.category_key,
                     name_portion = name_portion, relationship = relationship }
        end
    end

    return nil
end

--- Get category definitions for building menus
--- @param data table Parsed X-Ray data
--- @return table categories Array of {key, label, items, singular_label}
function XrayParser.getCategories(data)
    if XrayParser.isAcademic(data) then
        local cats = {
            { key = "key_concepts",     label = _("Key Concepts"),     items = data.key_concepts or {} },
            { key = "foundations",       label = _("Foundations"),      items = data.foundations or {} },
            { key = "methodology",      label = _("Methodology"),      items = data.methodology or {} },
            { key = "findings",         label = _("Findings"),         items = data.findings or {} },
            { key = "referenced_works", label = _("Referenced Works"), items = data.referenced_works or {} },
            { key = "technical_terms",  label = _("Technical Terms"),  items = data.technical_terms or {} },
            { key = "figures_data",     label = _("Figures & Data"),   items = data.figures_data or {} },
        }
        if data.conclusion then
            table.insert(cats, { key = "conclusion", label = _("Conclusion"), items = { data.conclusion } })
        elseif data.current_position then
            table.insert(cats, { key = "current_position", label = _("Current Position"), items = { data.current_position } })
        end
        return cats
    elseif XrayParser.isFiction(data) then
        local cats = {
            { key = "characters",    label = _("Cast"),          items = data.characters or {} },
            { key = "locations",     label = _("World"),         items = data.locations or {} },
            { key = "themes",        label = _("Ideas"),         items = data.themes or {} },
            { key = "lexicon",       label = _("Lexicon"),       items = data.lexicon or {} },
            { key = "timeline",      label = _("Story Arc"),     items = data.timeline or {} },
        }
        -- Complete X-Ray uses conclusion; incremental uses current_state
        if data.conclusion then
            table.insert(cats, { key = "conclusion", label = _("Conclusion"), items = { data.conclusion } })
        elseif data.current_state then
            table.insert(cats, { key = "current_state", label = _("Current State"), items = { data.current_state } })
        end
        return cats
    else
        local cats = {
            { key = "key_figures",          label = _("Key Figures"),          items = data.key_figures or {} },
            { key = "locations",            label = _("Locations"),            items = data.locations or {} },
            { key = "core_concepts",        label = _("Core Concepts"),        items = data.core_concepts or {} },
            { key = "arguments",            label = _("Arguments"),            items = data.arguments or {} },
            { key = "terminology",          label = _("Terminology"),          items = data.terminology or {} },
            { key = "argument_development", label = _("Argument Development"), items = data.argument_development or {} },
        }
        -- Complete X-Ray uses conclusion; incremental uses current_position
        if data.conclusion then
            table.insert(cats, { key = "conclusion", label = _("Conclusion"), items = { data.conclusion } })
        elseif data.current_position then
            table.insert(cats, { key = "current_position", label = _("Current Position"), items = { data.current_position } })
        end
        return cats
    end
end

-- Categories that never count as browsable X-Ray content
local NON_ENTITY_KEYS = {
    current_state = true, current_position = true,
    conclusion = true, reader_engagement = true,
}

--- True when parsed data holds at least one entry in any entity/event
--- category. A response that parses but fails this (e.g. a lone
--- current_state, seen from weak models — #90 field report) is not a usable
--- X-Ray CREATE and must not become the artifact. Round 28.
--- @param data table Parsed X-Ray data
--- @return boolean
function XrayParser.hasEntityContent(data)
    if type(data) ~= "table" then return false end
    for _idx, cat in ipairs(XrayParser.getCategories(data)) do
        if not NON_ENTITY_KEYS[cat.key] and type(cat.items) == "table" and #cat.items > 0 then
            return true
        end
    end
    return false
end

--- Round 28 (#90): background is code-owned end-to-end — attached by the
--- cross-book machinery, never model-authored. A model that has SEEN the
--- lines (any prompt carrying artifact JSON) can echo them back mangled or
--- self-labeled, and a rewrite carrying a background field replaces the
--- mechanical one in the merge. Strip every background field from a parsed
--- MODEL RESPONSE before it meets a merge. Never run on stored artifacts.
--- @param data table Freshly parsed model response (mutated)
function XrayParser.dropModelBackground(data)
    if type(data) ~= "table" then return end
    for _idx, cat in ipairs(XrayParser.getCategories(data)) do
        if type(cat.items) == "table" then
            for _idx2, item in ipairs(cat.items) do
                if type(item) == "table" then item.background = nil end
            end
        end
    end
end

-- Fields whose presence makes an entry worth keeping: identity alone (name/
-- term/event, aliases, chapter) is not an entry. Mirrors the schema vocabulary
-- in prompts/actions.lua across all three tracks.
local SANITIZE_CONTENT_FIELDS = { "role", "description", "significance",
    "importance", "details", "definition", "evidence" }
local SANITIZE_CONTENT_ARRAYS = { "connections", "references", "characters" }

--- 2026-08-15 (device round, A0): weak models can emit foreign-schema entries
--- (e.g. {relationships={}, current_position=..., current_state=...} carrying
--- no description at all) that parse fine and merge verbatim into the live
--- artifact. Drop entries that lack their name field or carry ZERO known
--- content fields, and say so in the log (one warn per affected category —
--- background/ladder builds surface it there). Same contract as
--- dropModelBackground above: runs ONLY on freshly parsed MODEL responses
--- before a merge/write, never on stored artifacts (their sparse legacy
--- entries keep displaying). Append/event lists (timeline,
--- argument_development) keep name-only entries — the event text IS the
--- content. `__dormant` is untouched by construction (getCategories never
--- yields it); parse/normalizeItem stay permissive so shape-healing
--- (arrays-as-maps, string items) keeps working upstream of this gate.
--- @param data table Freshly parsed model response (mutated)
--- @return number dropped Total entries dropped
function XrayParser.sanitizeEntries(data)
    if type(data) ~= "table" then return 0 end
    local total = 0
    for _idx, cat in ipairs(XrayParser.getCategories(data)) do
        local list = data[cat.key]
        if not NON_ENTITY_KEYS[cat.key] and type(list) == "table" then
            local name_field = ENTITY_NAME_FIELD[cat.key] or "name"
            local event_list = name_field == "event"
            local kept, dropped = {}, 0
            for _idx2, item in ipairs(list) do
                local ok = false
                if type(item) == "table" then
                    local id = item[name_field]
                    if type(id) == "string" and id ~= "" then
                        if event_list then
                            ok = true
                        else
                            for _idx3, f in ipairs(SANITIZE_CONTENT_FIELDS) do
                                local v = item[f]
                                if type(v) == "string" and v ~= "" then
                                    ok = true
                                    break
                                end
                            end
                            if not ok then
                                for _idx3, f in ipairs(SANITIZE_CONTENT_ARRAYS) do
                                    local v = item[f]
                                    if type(v) == "table" and #v > 0 then
                                        ok = true
                                        break
                                    end
                                end
                            end
                        end
                    end
                end
                if ok then
                    kept[#kept + 1] = item
                else
                    dropped = dropped + 1
                end
            end
            if dropped > 0 then
                for i = #list, 1, -1 do list[i] = nil end
                for i, it in ipairs(kept) do list[i] = it end
                total = total + dropped
                logger.warn("KOAssistant XrayParser: dropped", dropped,
                    "malformed entr(y/ies) from", cat.key, "(foreign schema or no content)")
            end
        end
    end
    return total
end

--- Get the display name for an item depending on category
--- @param item table The item entry
--- @param category_key string The category key
--- @return string name The display name
function XrayParser.getItemName(item, category_key)
    if category_key == "lexicon" or category_key == "terminology" or category_key == "technical_terms" then
        return item.term or _("Unknown")
    end
    if category_key == "timeline" or category_key == "argument_development" then
        return item.event or _("Unknown")
    end
    if category_key == "conclusion" then
        return _("Conclusion")
    end
    return item.name or _("Unknown")
end

--- Merge user-defined aliases into parsed X-Ray data (mutates in place)
--- @param data table Parsed X-Ray data
--- @param user_aliases table Mapping of item name → array of alias strings
--- @return table data The mutated data (for chaining)
function XrayParser.mergeUserAliases(data, user_aliases)
    if not user_aliases or not next(user_aliases) then
        return data
    end
    if not data or type(data) ~= "table" then
        return data
    end

    -- Build case-insensitive lookup: name_lower → { add = {...}, ignore = {...} }
    local lookup = {}
    for name, entry in pairs(user_aliases) do
        if name and type(entry) == "table" then
            local add = entry.add or {}
            local ignore = entry.ignore or {}
            if #add > 0 or #ignore > 0 then
                lookup[name:lower()] = entry
            end
        end
    end
    if not next(lookup) then return data end

    local categories = XrayParser.getCategories(data)
    for _idx, cat in ipairs(categories) do
        for _idx2, item in ipairs(cat.items) do
            local item_name = XrayParser.getItemName(item, cat.key)
            if item_name then
                local user_entry = lookup[item_name:lower()]
                if user_entry then
                    local existing = ensure_array(item.aliases) or {}

                    -- Build ignore set (case-insensitive)
                    local ignore_set = {}
                    for _idx3, ignored in ipairs(user_entry.ignore or {}) do
                        ignore_set[ignored:lower()] = true
                    end

                    -- Remove ignored aliases
                    if next(ignore_set) then
                        local filtered = {}
                        for _idx3, alias in ipairs(existing) do
                            if not ignore_set[alias:lower()] then
                                table.insert(filtered, alias)
                            end
                        end
                        existing = filtered
                    end

                    -- Add user aliases (dedup, case-insensitive)
                    local existing_lower = {}
                    for _idx3, alias in ipairs(existing) do
                        existing_lower[alias:lower()] = true
                    end
                    for _idx3, user_alias in ipairs(user_entry.add or {}) do
                        if not existing_lower[user_alias:lower()] then
                            table.insert(existing, user_alias)
                            existing_lower[user_alias:lower()] = true
                        end
                    end

                    item.aliases = existing
                end
            end
        end
    end

    return data
end

--- Get the secondary text for an item (used as subtitle or mandatory text)
--- @param item table The item entry
--- @param category_key string The category key
--- @return string secondary The secondary display text
function XrayParser.getItemSecondary(item, category_key)
    if category_key == "characters" or category_key == "key_figures" or category_key == "referenced_works" then
        return item.role or ""
    end
    if category_key == "timeline" or category_key == "argument_development" then
        return item.chapter or ""
    end
    if category_key == "lexicon" or category_key == "terminology" or category_key == "technical_terms" then
        return ""
    end
    return ""
end

--- Format a single item's detail text for display
--- @param item table The item entry
--- @param category_key string The category key
--- @return string detail Formatted detail text
--- @param opts table|nil { omit_connections = true } — the browser's entity
---   page renders connections as tappable buttons plus a list, so repeating
---   them as a comma-joined wall of prose (one real entity ran past 1500
---   characters) pushed the description off the screen. Model-facing callers
---   (AI Wiki context) and the card's full-detail view, which have no buttons,
---   pass nothing and keep them.
function XrayParser.formatItemDetail(item, category_key, opts)
    local parts = {}
    local omit_connections = opts and opts.omit_connections

    if category_key == "characters" or category_key == "key_figures" or category_key == "referenced_works" then
        local name = item.name or _("Unknown")
        local role = item.role or ""
        if role ~= "" then
            table.insert(parts, name .. " (" .. role .. ")")
        else
            table.insert(parts, name)
        end
        table.insert(parts, "")

        local aliases = ensure_array(item.aliases)
        if aliases and #aliases > 0 then
            table.insert(parts, _("Also known as:") .. " " .. table.concat(aliases, ", "))
            table.insert(parts, "")
        end

        if item.description and item.description ~= "" then
            table.insert(parts, item.description)
            table.insert(parts, "")
        end

        local connections = not omit_connections and ensure_array(item.connections)
        if connections and #connections > 0 then
            table.insert(parts, _("Connections:") .. " " .. table.concat(connections, ", "))
        end

    elseif category_key == "locations" or category_key == "core_concepts"
        or category_key == "key_concepts" or category_key == "foundations"
        or category_key == "methodology" or category_key == "figures_data" then
        table.insert(parts, item.name or _("Unknown"))
        table.insert(parts, "")
        if item.description and item.description ~= "" then
            table.insert(parts, item.description)
            table.insert(parts, "")
        end
        if item.details and item.details ~= "" then
            table.insert(parts, _("Details:") .. " " .. item.details)
            table.insert(parts, "")
        end
        local sig = item.significance or item.importance
        if sig and sig ~= "" then
            table.insert(parts, _("Significance:") .. " " .. sig)
            table.insert(parts, "")
        end
        local refs = not omit_connections and ensure_array(item.references)
        if refs and #refs > 0 then
            table.insert(parts, _("References:") .. " " .. table.concat(refs, ", "))
        end

    elseif category_key == "themes" or category_key == "arguments" or category_key == "findings" then
        table.insert(parts, item.name or _("Unknown"))
        table.insert(parts, "")
        if item.description and item.description ~= "" then
            table.insert(parts, item.description)
            table.insert(parts, "")
        end
        if item.evidence and item.evidence ~= "" then
            table.insert(parts, _("Evidence:") .. " " .. item.evidence)
            table.insert(parts, "")
        end
        if item.significance and item.significance ~= "" then
            table.insert(parts, _("Significance:") .. " " .. item.significance)
            table.insert(parts, "")
        end
        local refs = not omit_connections and ensure_array(item.references)
        if refs and #refs > 0 then
            table.insert(parts, _("References:") .. " " .. table.concat(refs, ", "))
        end

    elseif category_key == "lexicon" or category_key == "terminology" or category_key == "technical_terms" then
        table.insert(parts, item.term or _("Unknown"))
        table.insert(parts, "")
        if item.definition and item.definition ~= "" then
            table.insert(parts, item.definition)
        end

    elseif category_key == "timeline" or category_key == "argument_development" then
        local event = item.event or _("Unknown")
        local chapter = item.chapter or ""
        if chapter ~= "" then
            table.insert(parts, chapter .. ": " .. event)
        else
            table.insert(parts, event)
        end
        table.insert(parts, "")
        if item.significance and item.significance ~= "" then
            table.insert(parts, item.significance)
            table.insert(parts, "")
        end
        local characters = ensure_array(item.characters) or ensure_array(item.references)
        if characters and #characters > 0 then
            table.insert(parts, _("Characters:") .. " " .. table.concat(characters, ", "))
        end

    elseif category_key == "current_state" or category_key == "current_position" then
        if item.summary and item.summary ~= "" then
            table.insert(parts, item.summary)
            table.insert(parts, "")
        end
        local conflicts = ensure_array(item.conflicts)
        if conflicts and #conflicts > 0 then
            table.insert(parts, _("Active conflicts:"))
            for _idx, c in ipairs(conflicts) do
                table.insert(parts, "- " .. c)
            end
            table.insert(parts, "")
        end
        local questions = ensure_array(item.questions) or ensure_array(item.questions_addressed)
        if questions and #questions > 0 then
            local label = category_key == "current_position"
                and _("Questions addressed:") or _("Unanswered questions:")
            table.insert(parts, label)
            for _idx, q in ipairs(questions) do
                table.insert(parts, "- " .. q)
            end
            table.insert(parts, "")
        end
        local building = ensure_array(item.building_toward)
        if building and #building > 0 then
            table.insert(parts, _("Building toward:"))
            for _idx, b in ipairs(building) do
                table.insert(parts, "- " .. b)
            end
        end

    elseif category_key == "conclusion" then
        if item.summary and item.summary ~= "" then
            table.insert(parts, item.summary)
            table.insert(parts, "")
        end
        -- Fiction fields
        local resolutions = ensure_array(item.resolutions)
        if resolutions and #resolutions > 0 then
            table.insert(parts, _("Resolutions:"))
            for _idx, r in ipairs(resolutions) do
                table.insert(parts, "- " .. r)
            end
            table.insert(parts, "")
        end
        local themes_resolved = ensure_array(item.themes_resolved)
        if themes_resolved and #themes_resolved > 0 then
            table.insert(parts, _("Themes resolved:"))
            for _idx, t in ipairs(themes_resolved) do
                table.insert(parts, "- " .. t)
            end
            table.insert(parts, "")
        end
        -- Non-fiction fields
        local key_findings = ensure_array(item.key_findings)
        if key_findings and #key_findings > 0 then
            table.insert(parts, _("Key findings:"))
            for _idx, f in ipairs(key_findings) do
                table.insert(parts, "- " .. f)
            end
            table.insert(parts, "")
        end
        local implications = ensure_array(item.implications)
        if implications and #implications > 0 then
            table.insert(parts, _("Implications:"))
            for _idx, i in ipairs(implications) do
                table.insert(parts, "- " .. i)
            end
            table.insert(parts, "")
        end
    end

    -- Show aliases for any category that has them (characters/key_figures handle it above)
    if category_key ~= "characters" and category_key ~= "key_figures" then
        local aliases = ensure_array(item.aliases)
        if aliases and #aliases > 0 then
            table.insert(parts, "")
            table.insert(parts, _("Also known as:") .. " " .. table.concat(aliases, ", "))
        end
    end

    -- Cross-book background (item 44): attached mechanically by the merge,
    -- shown for any category that carries it
    if type(item.background) == "table" then
        for _idx, b in ipairs(item.background) do
            if type(b) == "table" and type(b.text) == "string" and b.text ~= "" then
                if #parts > 0 and parts[#parts] ~= "" then table.insert(parts, "") end
                table.insert(parts, T(_("Background — \"%1\": %2"), b.source or "?", b.text))
            end
        end
    end

    return table.concat(parts, "\n")
end

--- Append machine-facing background lines (cross-book merge, item 44) for one
--- item to a markdown line buffer. English labels like the rest of the render.
local function insertBackgroundLines(lines, item)
    if type(item.background) ~= "table" then return end
    for _idx, b in ipairs(item.background) do
        if type(b) == "table" and type(b.text) == "string" and b.text ~= "" then
            table.insert(lines, "*Background — \"" .. (b.source or "?") .. "\": " .. b.text .. "*")
        end
    end
end

--- Render structured X-Ray data to readable markdown
--- Produces output matching the established X-Ray style for display in chat and {xray_cache_section}
--- @param data table Parsed X-Ray JSON
--- @param title string Book title (optional, for header)
--- @param progress string Reading progress e.g. "42%" (optional, for header)
--- @return string markdown Rendered markdown text
function XrayParser.renderToMarkdown(data, title, progress)
    local lines = {}

    -- Header
    local header = "# Reader's Companion"
    if title and title ~= "" then
        header = header .. ": " .. title
    end
    if progress and progress ~= "" then
        if progress == "Complete" or progress == "100%" then
            header = header .. " (Complete)"
        else
            header = header .. " (Through " .. progress .. ")"
        end
    end
    table.insert(lines, header)
    table.insert(lines, "")

    local type_label
    if XrayParser.isAcademic(data) then
        type_label = "ACADEMIC"
    elseif XrayParser.isFiction(data) then
        type_label = "FICTION"
    else
        type_label = "NON-FICTION"
    end
    table.insert(lines, "**Type: " .. type_label .. "**")
    table.insert(lines, "")

    local categories = XrayParser.getCategories(data)
    for _idx, cat in ipairs(categories) do
        if cat.items and #cat.items > 0 then
            table.insert(lines, "## " .. cat.label)

            if cat.key == "current_state" or cat.key == "current_position" or cat.key == "conclusion" then
                -- Current state / conclusion: render inline
                local state = cat.items[1]
                if state.summary and state.summary ~= "" then
                    table.insert(lines, state.summary)
                    table.insert(lines, "")
                end
                -- current_state fields
                local s_conflicts = ensure_array(state.conflicts)
                if s_conflicts and #s_conflicts > 0 then
                    for _idx2, c in ipairs(s_conflicts) do
                        table.insert(lines, "- " .. c)
                    end
                    table.insert(lines, "")
                end
                local s_questions = ensure_array(state.questions) or ensure_array(state.questions_addressed)
                if s_questions and #s_questions > 0 then
                    for _idx2, q in ipairs(s_questions) do
                        table.insert(lines, "- " .. q)
                    end
                    table.insert(lines, "")
                end
                local s_building = ensure_array(state.building_toward)
                if s_building and #s_building > 0 then
                    for _idx2, b in ipairs(s_building) do
                        table.insert(lines, "- " .. b)
                    end
                    table.insert(lines, "")
                end
                -- conclusion fields (fiction)
                local s_resolutions = ensure_array(state.resolutions)
                if s_resolutions and #s_resolutions > 0 then
                    for _idx2, r in ipairs(s_resolutions) do
                        table.insert(lines, "- " .. r)
                    end
                    table.insert(lines, "")
                end
                local s_themes = ensure_array(state.themes_resolved)
                if s_themes and #s_themes > 0 then
                    for _idx2, t in ipairs(s_themes) do
                        table.insert(lines, "- " .. t)
                    end
                    table.insert(lines, "")
                end
                -- conclusion fields (non-fiction)
                local s_findings = ensure_array(state.key_findings)
                if s_findings and #s_findings > 0 then
                    for _idx2, f in ipairs(s_findings) do
                        table.insert(lines, "- " .. f)
                    end
                    table.insert(lines, "")
                end
                local s_implications = ensure_array(state.implications)
                if s_implications and #s_implications > 0 then
                    for _idx2, i in ipairs(s_implications) do
                        table.insert(lines, "- " .. i)
                    end
                    table.insert(lines, "")
                end
            elseif cat.key == "characters" or cat.key == "key_figures" or cat.key == "referenced_works" then
                for _idx2, char in ipairs(cat.items) do
                    local entry = "**" .. (char.name or "Unknown") .. "**"
                    local desc_parts = {}
                    if char.role and char.role ~= "" then
                        table.insert(desc_parts, char.role)
                    end
                    if char.description and char.description ~= "" then
                        table.insert(desc_parts, char.description)
                    end
                    if #desc_parts > 0 then
                        entry = entry .. ": " .. table.concat(desc_parts, ". ")
                    end
                    table.insert(lines, entry)

                    local c_aliases = ensure_array(char.aliases)
                    if c_aliases and #c_aliases > 0 then
                        table.insert(lines, "*(Also known as: " .. table.concat(c_aliases, ", ") .. ")*")
                    end
                    local c_connections = ensure_array(char.connections)
                    if c_connections and #c_connections > 0 then
                        table.insert(lines, "*Connections: " .. table.concat(c_connections, ", ") .. "*")
                    end
                    insertBackgroundLines(lines, char)
                    table.insert(lines, "")
                end
            elseif cat.key == "locations" or cat.key == "core_concepts"
                or cat.key == "key_concepts" or cat.key == "foundations"
                or cat.key == "methodology" or cat.key == "figures_data" then
                for _idx2, loc in ipairs(cat.items) do
                    local entry = "**" .. (loc.name or "Unknown") .. "**"
                    local desc = loc.description or ""
                    local sig = loc.significance or loc.importance or ""
                    local detail_parts = {}
                    if desc ~= "" then table.insert(detail_parts, desc) end
                    if loc.details and loc.details ~= "" then table.insert(detail_parts, loc.details) end
                    if sig ~= "" then table.insert(detail_parts, sig) end
                    if #detail_parts > 0 then
                        entry = entry .. ": " .. table.concat(detail_parts, ". ")
                    end
                    table.insert(lines, entry)
                    local l_refs = ensure_array(loc.references)
                    if l_refs and #l_refs > 0 then
                        table.insert(lines, "*References: " .. table.concat(l_refs, ", ") .. "*")
                    end
                    insertBackgroundLines(lines, loc)
                    table.insert(lines, "")
                end
            elseif cat.key == "themes" or cat.key == "arguments" or cat.key == "findings" then
                for _idx2, theme in ipairs(cat.items) do
                    local entry = "**" .. (theme.name or "Unknown") .. "**"
                    if theme.description and theme.description ~= "" then
                        entry = entry .. ": " .. theme.description
                    end
                    if theme.evidence and theme.evidence ~= "" then
                        entry = entry .. " " .. theme.evidence
                    end
                    if theme.significance and theme.significance ~= "" then
                        entry = entry .. " " .. theme.significance
                    end
                    table.insert(lines, entry)
                    local t_refs = ensure_array(theme.references)
                    if t_refs and #t_refs > 0 then
                        table.insert(lines, "*References: " .. table.concat(t_refs, ", ") .. "*")
                    end
                    insertBackgroundLines(lines, theme)
                    table.insert(lines, "")
                end
            elseif cat.key == "lexicon" or cat.key == "terminology" or cat.key == "technical_terms" then
                for _idx2, term in ipairs(cat.items) do
                    local entry = "**" .. (term.term or "Unknown") .. "**"
                    if term.definition and term.definition ~= "" then
                        entry = entry .. ": " .. term.definition
                    end
                    table.insert(lines, entry)
                    insertBackgroundLines(lines, term)
                    table.insert(lines, "")
                end
            elseif cat.key == "timeline" or cat.key == "argument_development" then
                for _idx2, event in ipairs(cat.items) do
                    local prefix = ""
                    if event.chapter and event.chapter ~= "" then
                        prefix = "**" .. event.chapter .. ":** "
                    else
                        prefix = "- "
                    end
                    local entry = prefix .. (event.event or "Unknown")
                    if event.significance and event.significance ~= "" then
                        entry = entry .. ": " .. event.significance
                    end
                    local e_characters = ensure_array(event.characters) or ensure_array(event.references)
                    if e_characters and #e_characters > 0 then
                        entry = entry .. " [" .. table.concat(e_characters, ", ") .. "]"
                    end
                    table.insert(lines, "- " .. entry)
                end
                table.insert(lines, "")
            end
        end
    end

    -- Belt over the parse-time normalization: a non-string line (unforeseen
    -- shape reaching a raw insert) must cost that line, never the render —
    -- a table here crashed table.concat mid-response (#90 crash.log)
    for i, v in ipairs(lines) do
        if type(v) ~= "string" then lines[i] = "" end
    end
    return table.concat(lines, "\n")
end

--- Search characters/figures by query string
--- Matches against name, aliases, and description (case-insensitive)
--- @param data table Parsed X-Ray data
--- @param query string Search term
--- @return table results Array of {item, match_field} sorted by match quality
function XrayParser.searchCharacters(data, query)
    if not query or query == "" then return {} end

    local characters = XrayParser.getCharacters(data)
    if not characters or #characters == 0 then return {} end

    local query_lower = XrayParser.normalizeArabic(query:lower())
    local results = {}

    local normalize = XrayParser.normalizeArabic
    for _idx, char in ipairs(characters) do
        local match_field = nil

        -- Check name (highest priority)
        if char.name and normalize(char.name:lower()):find(query_lower, 1, true) then
            match_field = "name"
        end

        -- Check aliases
        local s_aliases = ensure_array(char.aliases)
        if not match_field and s_aliases then
            for _idx2, alias in ipairs(s_aliases) do
                if normalize(alias:lower()):find(query_lower, 1, true) then
                    match_field = "alias"
                    break
                end
            end
        end

        -- Check description (lowest priority)
        if not match_field and char.description then
            if normalize(char.description:lower()):find(query_lower, 1, true) then
                match_field = "description"
            end
        end

        if match_field then
            table.insert(results, { item = char, match_field = match_field })
        end
    end

    -- Sort: name matches first, then alias, then description
    local priority = { name = 1, alias = 2, description = 3 }
    table.sort(results, function(a, b)
        return (priority[a.match_field] or 9) < (priority[b.match_field] or 9)
    end)

    return results
end

--- Search across all categories (name, term, event, description, etc.)
--- @param data table Parsed X-Ray data
--- @param query string Search query
--- @param opts table|nil Options: skip_description (bool) to search name+alias only
--- @return table results Array of {item, category_key, category_label, match_field}
function XrayParser.searchAll(data, query, opts)
    if not query or query == "" then return {} end
    local skip_description = opts and opts.skip_description
    -- exact: a handle must BE the query, not merely contain it — the #63
    -- conditional bypass gate ("of" substring-hits inside names, and a
    -- bypass that steals every word from the dictionary is broken); implies
    -- descriptions never match
    local exact = opts and opts.exact
    if exact then skip_description = true end

    local categories = XrayParser.getCategories(data)
    local query_lower = XrayParser.normalizeArabic(query:lower())
    local normalize = XrayParser.normalizeArabic
    -- Arabic: also try ال-stripped query so "النار" finds "نار" and vice versa
    local query_stripped = nil
    if XrayParser.containsArabic(query_lower) then
        local s = stripArabicArticle(query_lower)
        if s ~= query_lower and #s > 4 then query_stripped = s end
    end
    local results = {}

    for _idx, cat in ipairs(categories) do
        -- Skip singleton categories (not useful in search)
        if cat.key ~= "current_state" and cat.key ~= "current_position"
            and cat.key ~= "reader_engagement" and cat.key ~= "conclusion" then
            for _idx2, item in ipairs(cat.items) do
                local match_field = nil
                -- Check primary name/term/event
                local name = item.name or item.term or item.event or ""
                if name ~= "" then
                    local n = normalize(name:lower())
                    if exact then
                        if n == query_lower
                            or (query_stripped and n == query_stripped) then
                            match_field = "name"
                        end
                    elseif n:find(query_lower, 1, true)
                        or (query_stripped and n:find(query_stripped, 1, true)) then
                        match_field = "name"
                    end
                end
                -- Check aliases
                local i_aliases = ensure_array(item.aliases)
                if not match_field and i_aliases then
                    for _idx3, alias in ipairs(i_aliases) do
                        local a = normalize(alias:lower())
                        if exact then
                            if a == query_lower
                                or (query_stripped and a == query_stripped) then
                                match_field = "alias"
                                break
                            end
                        elseif a:find(query_lower, 1, true)
                            or (query_stripped and a:find(query_stripped, 1, true)) then
                            match_field = "alias"
                            break
                        end
                    end
                end
                -- Check description/definition/significance
                if not match_field and not skip_description then
                    local desc = item.description or item.definition or item.significance or ""
                    if desc ~= "" then
                        local d = normalize(desc:lower())
                        if d:find(query_lower, 1, true)
                            or (query_stripped and d:find(query_stripped, 1, true)) then
                            match_field = "description"
                        end
                    end
                end
                if match_field then
                    table.insert(results, {
                        item = item,
                        category_key = cat.key,
                        category_label = cat.label,
                        match_field = match_field,
                    })
                end
            end
        end
    end

    -- Sort: name matches first, then alias, then description
    local priority = { name = 1, alias = 2, description = 3 }
    table.sort(results, function(a, b)
        return (priority[a.match_field] or 9) < (priority[b.match_field] or 9)
    end)

    return results
end

-- One normalization for handle-vs-selection equality: lower + Arabic
-- normalize + whitespace collapse + trim (selections and JSON handles both
-- carry stray spacing).
local function exactKey(s)
    s = XrayParser.normalizeArabic(s:lower()):gsub("\194\160", " "):gsub("%s+", " ")
    return s:match("^%s*(.-)%s*$") or s
end

--- Fold every exact-matchable handle (name/term/event + aliases) of data's
--- entities into `set`. Each handle folds BOTH its raw form and its
--- parenthetical-stripped form — the SAME reduction collectSearchTerms
--- applies for marking/searching, so anything the marks layer underlines is
--- reachable by selecting exactly the underlined words (device 2026-08-14:
--- a parenthetical-suffixed entity was marked via its stripped form but the
--- raw-handle-only set refused the selection). Skips the
--- singleton categories searchAll skips. Feeds the memoized route index
--- behind the selection intercept (slice 2, ref #63).
--- @param data table Parsed X-Ray data (user aliases already merged)
--- @param set table Accumulator: normalized handle -> true
function XrayParser.foldExactHandles(data, set)
    local function fold(h)
        if type(h) ~= "string" or h == "" then return end
        local k = exactKey(h)
        if k ~= "" then set[k] = true end
        -- Parenthetical-stripped variant: "Theosis (Deification)" → "Theosis"
        local stripped = h:gsub("%s*%(.-%)%s*", " ")
        if stripped ~= h then
            k = exactKey(stripped)
            if k ~= "" then set[k] = true end
        end
    end
    for _idx, cat in ipairs(XrayParser.getCategories(data) or {}) do
        if cat.key ~= "current_state" and cat.key ~= "current_position"
            and cat.key ~= "reader_engagement" and cat.key ~= "conclusion" then
            for _idx2, item in ipairs(cat.items) do
                fold(item.name or item.term or item.event)
                local aliases = ensure_array(item.aliases)
                if aliases then
                    for _idx3, a in ipairs(aliases) do
                        fold(a)
                    end
                end
            end
        end
    end
end

--- The query-side mirror against a foldExactHandles set: normalized
--- equality, plus the ال-stripped query variant for Arabic (query side only
--- — the handle side is never article-stripped, matching searchAll's exact
--- mode).
--- @param set table foldExactHandles accumulator
--- @param query string Raw query text
--- @return boolean
function XrayParser.matchExactHandle(set, query)
    if type(query) ~= "string" or query == "" then return false end
    local q = exactKey(query)
    if q == "" then return false end
    if set[q] then return true end
    if XrayParser.containsArabic(q) then
        local s = stripArabicArticle(q)
        if s ~= q and #s > 4 and set[s] then return true end
    end
    return false
end

--- Entity name + aliases as search terms: array of { text, regex } — regex =
--- the Arabic diacritics-tolerant pattern where applicable (EPUB engine
--- only). Rules: parenthetical strip, >2 chars, case-insensitive dedupe,
--- substring-minimal set (a term containing another term is dropped — the
--- short form already finds every occurrence of the long one, and keeping
--- both would double-count the same physical mention). Moved here from the
--- browser (slice 2) so the mention lists, the native-search launches AND
--- ambient marking share one term truth. The dropped longer variants come
--- back as a SECOND return for callers that paint spans rather than count
--- mentions (buildMarkEntities) — counting callers must keep ignoring it.
--- @param item table X-Ray entity item
--- @param item_title string|nil Fallback title when the item has no name
--- @return table terms Array of { text, regex? } (substring-minimal)
--- @return table dropped Longer variants removed by minimization
function XrayParser.collectSearchTerms(item, item_title)
    local terms, seen = {}, {}
    local function add(t)
        if type(t) ~= "string" then return end
        -- Strip parenthetical: "Theosis (Deification)" → "Theosis"
        t = t:gsub("%s*%(.-%)%s*", " ")
        t = t:match("^%s*(.-)%s*$") or ""
        if #t > 2 then
            local k = t:lower()
            if not seen[k] then
                seen[k] = true
                table.insert(terms, {
                    text = t,
                    regex = XrayParser.buildArabicSearchRegex(t),
                })
            end
        end
    end
    add(item.name or item.term or item.event or item_title)
    local aliases = item.aliases
    if type(aliases) == "string" then aliases = { aliases } end
    if type(aliases) == "table" then
        for _idx, a in ipairs(aliases) do add(a) end
    end
    local minimal, dropped = {}, {}
    for i, t in ipairs(terms) do
        local contains_other = false
        local t_lower = t.text:lower()
        for j, u in ipairs(terms) do
            if i ~= j and #u.text < #t.text
                and t_lower:find(u.text:lower(), 1, true) then
                contains_other = true
                break
            end
        end
        table.insert(contains_other and dropped or minimal, t)
    end
    return minimal, dropped
end

--- Ambient-marking entity list (slice 2, ref #78): one entry per markable
--- entity with its collectSearchTerms terms, its CATEGORY_FAMILY family
--- (unmapped categories are their own family) and a normalized variant of
--- each term for the cheap page-presence pre-check. Category gate =
--- TEXT_MATCH_EXCLUDED, the same truth countItemOccurrences uses.
--- Unlike the counting surfaces, the term set here INCLUDES the longer
--- variants the minimizer dropped, sorted longest-first: the widest form
--- present at an occurrence is the one that paints (device 2026-08-14: a
--- one-word alias contained in the entity's full three-word name marked
--- only the middle word of the full name). Zero steady-state cost — the
--- scan's presence pre-check already gates each term's one-time search on
--- the term actually appearing in the page text, so pages showing only the
--- short form never pay for the long one.
--- @param data table Parsed X-Ray data (user aliases already merged)
--- @return table entities Array of { name, category_key, family, terms }
function XrayParser.buildMarkEntities(data)
    local out = {}
    for _idx, cat in ipairs(XrayParser.getCategories(data) or {}) do
        if not TEXT_MATCH_EXCLUDED[cat.key] then
            for _idx2, item in ipairs(cat.items) do
                local terms, long_variants = XrayParser.collectSearchTerms(item, nil)
                for _idx3, lv in ipairs(long_variants) do
                    table.insert(terms, lv)
                end
                table.sort(terms, function(a, b) return #a.text > #b.text end)
                if #terms > 0 then
                    for _idx3, t in ipairs(terms) do
                        -- Whitespace-collapsed (NBSP too) to match the
                        -- layout-text haystack the marks scan collapses the
                        -- same way (line wraps arrive as newlines there)
                        t.norm = XrayParser.normalizeArabic(t.text:lower())
                            :gsub("\194\160", " "):gsub("%s+", " ")
                    end
                    table.insert(out, {
                        name = XrayParser.getItemName(item, cat.key),
                        category_key = cat.key,
                        family = XrayParser.CATEGORY_FAMILY[cat.key] or cat.key,
                        terms = terms,
                    })
                end
            end
        end
    end
    return out
end

--- Rank likely alias-target entities for a handle the X-Ray does NOT know
--- (the no-hits "Add as alias of…" offer, ref #63): per-word substring
--- search over names+aliases, first-hit order, capped. A shared word is
--- the usual identity signal — a character reintroduced under a changed
--- name tends to keep part of it — while a fully novel handle yields
--- nothing and the caller falls back to the manual category pick.
--- TEXT_MATCH_EXCLUDED categories are never targets: user aliases exist to
--- mark and match text, which those never do.
--- @param data table Parsed X-Ray data (user aliases already merged)
--- @param query string The unknown handle
--- @param cap number|nil Max suggestions (default 6)
--- @return table results searchAll-shaped { item, category_key, category_label }
function XrayParser.suggestAliasTargets(data, query, cap)
    cap = cap or 6
    if not data or type(query) ~= "string" then return {} end
    local out, seen = {}, {}
    local words = {}
    for w in query:gmatch("%S+") do
        if #w > 2 then words[#words + 1] = w end
    end
    for _w, w in ipairs(words) do
        for _r, r in ipairs(XrayParser.searchAll(data, w, { skip_description = true })) do
            if not TEXT_MATCH_EXCLUDED[r.category_key] then
                local nm = XrayParser.getItemName(r.item, r.category_key)
                local k = nm and (r.category_key .. "\0" .. nm:lower()) or nil
                if k and not seen[k] then
                    seen[k] = true
                    out[#out + 1] = r
                    if #out >= cap then return out end
                end
            end
        end
    end
    return out
end

--- Find all X-Ray items appearing in chapter text
--- @param data table Parsed X-Ray data
--- @param chapter_text string The chapter text content
--- Counts honor cross-entity containment (B266): the exclusion list is
--- built per item from the same data.
--- @return table results Array of {item, category_key, category_label, count} sorted by count desc
function XrayParser.findItemsInChapter(data, chapter_text)
    if not chapter_text or chapter_text == "" then return {} end

    local categories = XrayParser.getCategories(data)
    if not categories or #categories == 0 then return {} end

    local text_lower = XrayParser.normalizeArabic(chapter_text:lower())
    local results = {}

    for _idx, cat in ipairs(categories) do
        if not TEXT_MATCH_EXCLUDED[cat.key] then
            for _idx2, item in ipairs(cat.items) do
                local count = XrayParser.countItemOccurrences(item, text_lower,
                    XrayParser.containingHandles(data, item))
                if count > 0 then
                    table.insert(results, {
                        item = item,
                        category_key = cat.key,
                        category_label = cat.label,
                        count = count,
                    })
                end
            end
        end
    end

    -- Sort by mention count descending
    table.sort(results, function(a, b)
        return a.count > b.count
    end)

    return results
end

--- Find characters appearing in chapter text using fuzzy name+alias matching
--- @param data table Parsed X-Ray data
--- @param chapter_text string The chapter text content
--- @return table results Array of {item, count} sorted by mention frequency (descending)
function XrayParser.findCharactersInChapter(data, chapter_text)
    if not chapter_text or chapter_text == "" then return {} end

    local characters = XrayParser.getCharacters(data)
    if not characters or #characters == 0 then return {} end

    local text_lower = XrayParser.normalizeArabic(chapter_text:lower())
    local results = {}

    for _idx, char in ipairs(characters) do
        local best_count = XrayParser.countItemOccurrences(char, text_lower,
            XrayParser.containingHandles(data, char))
        if best_count > 0 then
            table.insert(results, { item = char, count = best_count })
        end
    end

    -- Sort by mention count descending
    table.sort(results, function(a, b)
        return a.count > b.count
    end)

    return results
end

--- Check if an ASCII byte is a word character (letter or digit).
--- @param b number Byte value (must be < 128)
--- @return boolean
local function isAsciiWordByte(b)
    if b >= 48 and b <= 57 then return true end   -- 0-9
    if b >= 65 and b <= 90 then return true end   -- A-Z
    if b >= 97 and b <= 122 then return true end  -- a-z
    return false
end

--- Check if the character at a text position is a word character for boundary detection.
--- For ASCII bytes: checks letters and digits.
--- For multi-byte UTF-8: decodes the codepoint and checks known non-word ranges
--- (General Punctuation, Latin-1 symbols, CJK symbols, etc.).
--- @param text string The text
--- @param pos number Byte position to check
--- @param scan_back boolean If true, pos may be a continuation byte (last byte of preceding
---   character); scans back up to 3 bytes to find the leading byte and decode.
--- @return boolean true if it's a word character
local function isWordCharAt(text, pos, scan_back)
    local b = text:byte(pos)
    if not b then return false end

    -- ASCII: simple byte check
    if b < 128 then return isAsciiWordByte(b) end

    -- Multi-byte UTF-8: find the leading byte
    local lead_pos = pos
    if scan_back and b < 0xC0 then
        -- Continuation byte (0x80-0xBF): scan back to find leading byte
        for i = 1, 3 do
            local p = pos - i
            if p < 1 then return true end  -- Can't decode, assume word
            local pb = text:byte(p)
            if pb >= 0xC0 then lead_pos = p; break end
            if pb < 0x80 then return true end  -- Hit ASCII, malformed; assume word
        end
    end

    -- Decode codepoint from leading byte
    local lb = text:byte(lead_pos)
    if not lb or lb < 0xC0 then return true end  -- Can't decode, assume word
    local cp
    if lb < 0xE0 then
        -- 2-byte: U+0080-U+07FF (Latin Extended, Cyrillic, Arabic, Hebrew, etc.)
        local b2 = text:byte(lead_pos + 1)
        if not b2 then return true end
        cp = (lb - 0xC0) * 64 + (b2 - 0x80)
    elseif lb < 0xF0 then
        -- 3-byte: U+0800-U+FFFF (CJK, General Punctuation, symbols, etc.)
        local b2, b3 = text:byte(lead_pos + 1), text:byte(lead_pos + 2)
        if not b2 or not b3 then return true end
        cp = (lb - 0xE0) * 4096 + (b2 - 0x80) * 64 + (b3 - 0x80)
    else
        -- 4-byte: emoji/supplementary — treat as non-word boundary
        return false
    end

    -- Check known non-word Unicode ranges (punctuation, symbols, spaces)
    if cp >= 0x2000 and cp <= 0x206F then return false end  -- General Punctuation (smart quotes, dashes, ellipsis)
    if cp >= 0x00A0 and cp <= 0x00BF then return false end  -- Latin-1 symbols (guillemets, ©, etc.)
    if cp >= 0x2E00 and cp <= 0x2E7F then return false end  -- Supplemental Punctuation
    if cp >= 0x3000 and cp <= 0x303F then return false end  -- CJK Symbols and Punctuation

    -- Everything else (accented letters, Cyrillic, Greek, etc.): word character
    return true
end

--- Check if needle should skip word-boundary checking.
--- Returns true for scripts where byte-level boundary detection is unreliable:
--- - CJK/Thai (3+ byte UTF-8, leading byte >= 0xE0): no word-boundary spaces
--- - Arabic/Hebrew/Syriac (2-byte UTF-8, leading bytes 0xD6-0xDB): have spaces but
---   multi-byte punctuation (،؛؟) makes byte-level boundary check unreliable
--- Latin/Cyrillic/Greek (leading bytes 0xC0-0xD5) still use boundary checking.
--- @param str string Text to check
--- @return boolean
local function skipBoundaryCheck(str)
    for i = 1, #str do
        local b = str:byte(i)
        if b >= 0xE0 then return true end           -- CJK, Thai, etc.
        if b >= 0xD6 and b <= 0xDB then return true end  -- Arabic, Hebrew, Syriac
    end
    return false
end

--- Collect match spans of a substring in text (plain search).
--- For Latin/Cyrillic/Greek: uses word-boundary matching to prevent false positives.
--- For CJK/Thai/Arabic/Hebrew: skips boundary matching (see skipBoundaryCheck).
--- @param text string Haystack (already lowered)
--- @param needle string Needle (already lowered)
--- @return table spans Array of {start, end_pos} pairs
function XrayParser._collectMatchSpans(text, needle)
    local spans = {}
    local pos = 1
    local needle_len = #needle
    local text_len = #text
    local skip_boundaries = skipBoundaryCheck(needle)
    while true do
        local start = text:find(needle, pos, true)
        if not start then break end
        local end_pos = start + needle_len - 1
        if skip_boundaries then
            spans[#spans + 1] = {start, end_pos}
        else
            -- Check word boundaries: character before/after must be non-word
            local before_ok = (start == 1) or not isWordCharAt(text, start - 1, true)
            local after_ok = (end_pos >= text_len) or not isWordCharAt(text, end_pos + 1, false)
            if before_ok and after_ok then
                spans[#spans + 1] = {start, end_pos}
            end
        end
        pos = start + needle_len
    end
    return spans
end

--- Count occurrences of a substring in text (convenience wrapper).
--- @param text string Haystack (already lowered)
--- @param needle string Needle (already lowered)
--- @return number count
function XrayParser._countOccurrences(text, needle)
    return #XrayParser._collectMatchSpans(text, needle)
end

--- Handle normalization shared by the cross-entity containment layer (B266):
--- lowercase, Arabic-folded, NBSP and whitespace runs collapsed, trimmed.
function XrayParser.normalizeHandle(s)
    if type(s) ~= "string" then return "" end
    local h = XrayParser.normalizeArabic(s:lower())
    h = h:gsub("\194\160", " "):gsub("%s+", " ")
    return h:match("^%s*(.-)%s*$") or ""
end

--- Does normalized handle `h` contain normalized term `t` as whole words?
function XrayParser.handleContainsWord(h, t)
    if not (h and t) or #t == 0 or #t >= #h then return false end
    return #XrayParser._collectMatchSpans(h, t) > 0
end

--- Cross-entity containment (B266): the normalized handles of OTHER entities
--- that contain one of this item's search terms as whole words ("Vivian
--- Kubrick" for the entity "Kubrick"). An occurrence of such a handle is the
--- other entity's mention, so every counting/mention surface drops the
--- inner hit. Minimized: a handle containing another listed handle is
--- dropped (one subtraction per occurrence). Own handles never qualify.
--- @return table|nil handles Array of normalized strings, nil when none
function XrayParser.containingHandles(data, item)
    if not (data and item) then return nil end
    local own_min, own_long = XrayParser.collectSearchTerms(item, nil)
    local own = {}
    for _idx, t in ipairs(own_min) do own[XrayParser.normalizeHandle(t.text)] = true end
    for _idx, t in ipairs(own_long) do own[XrayParser.normalizeHandle(t.text)] = true end
    if next(own) == nil then return nil end
    local found, seen = {}, {}
    for _idx, cat in ipairs(XrayParser.getCategories(data) or {}) do
        if not TEXT_MATCH_EXCLUDED[cat.key] then
            for _idx2, other in ipairs(cat.items) do
                if other ~= item then
                    local t1, t2 = XrayParser.collectSearchTerms(other, nil)
                    for _idx3, t in ipairs(t2) do t1[#t1 + 1] = t end
                    for _idx3, t in ipairs(t1) do
                        local h = XrayParser.normalizeHandle(t.text)
                        if h ~= "" and not own[h] and not seen[h] then
                            for own_t in pairs(own) do
                                if XrayParser.handleContainsWord(h, own_t) then
                                    seen[h] = true
                                    found[#found + 1] = h
                                    break
                                end
                            end
                        end
                    end
                end
            end
        end
    end
    if #found == 0 then return nil end
    local minimal = {}
    for i, h in ipairs(found) do
        local contains_other = false
        for j, u in ipairs(found) do
            if i ~= j and XrayParser.handleContainsWord(h, u) then
                contains_other = true
                break
            end
        end
        if not contains_other then minimal[#minimal + 1] = h end
    end
    return minimal
end

--- Does a native-search hit sit INSIDE one of the containing handles? The
--- hit's own text plus its prev/next context must spell the handle around
--- it, at word boundaries ("Vivian" + "Kubrick" completes "vivian kubrick").
--- Pure; used by the mention list / chapter appearances (B266).
function XrayParser.hitInsideHandle(prev_text, matched, next_text, handles)
    if not handles or #handles == 0 then return false end
    local m = XrayParser.normalizeHandle(matched)
    if m == "" then return false end
    local before = XrayParser.normalizeHandle(prev_text)
    local after = XrayParser.normalizeHandle(next_text)
    for _idx, h in ipairs(handles) do
        local pos = 1
        while true do
            local s, e = h:find(m, pos, true)
            if not s then break end
            local lp, ls = h:sub(1, s - 1), h:sub(e + 1)
            if (lp == "" or lp:sub(-1) == " ") and (ls == "" or ls:sub(1, 1) == " ") then
                lp = lp:gsub("%s+$", "")
                ls = ls:gsub("^%s+", "")
                local ok_before = lp == "" or (#before >= #lp and before:sub(-#lp) == lp
                    and (#before == #lp or not isWordCharAt(before, #before - #lp, true)))
                local ok_after = ls == "" or (#after >= #ls and after:sub(1, #ls) == ls
                    and (#after == #ls or not isWordCharAt(after, #ls + 1, false)))
                if ok_before and ok_after then return true end
            end
            pos = s + 1
        end
    end
    return false
end

--- Build a compact entity index listing existing names per category.
--- Used in update prompts so the AI uses exact matching strings for existing entities.
--- @param data table Parsed X-Ray data
--- @return string index Multi-line string: "category: Name1 (alias1, alias2); Name2\n..."
--- Append-only categories carry EVENTS, not named entities: the merge routes
--- them to appendCategory (no name matching at all), and getItemSearchName
--- falls through to item.event, so indexing them emitted every event's full
--- sentence as an "existing entity name" -- 80-87% of the index on a real
--- book.
local INDEX_EXCLUDED_CATEGORIES = {
    timeline = true,
    argument_development = true,
}

function XrayParser.buildEntityIndex(data)
    local categories = XrayParser.getCategories(data)
    if not categories or #categories == 0 then return "" end

    local lines = {}
    for _idx, cat in ipairs(categories) do
        if not SINGLETON_CATEGORIES[cat.key] and not INDEX_EXCLUDED_CATEGORIES[cat.key]
            and cat.items and #cat.items > 0 then
            local names = {}
            for _idx2, item in ipairs(cat.items) do
                local name = getItemSearchName(item)
                if name then
                    local item_aliases = ensure_array(item.aliases)
                    if item_aliases and #item_aliases > 0 then
                        local shown = {}
                        for i = 1, math.min(2, #item_aliases) do
                            shown[i] = item_aliases[i]
                        end
                        name = name .. " (" .. table.concat(shown, ", ") .. ")"
                    end
                    names[#names + 1] = name
                end
            end
            if #names > 0 then
                lines[#lines + 1] = cat.key .. ": " .. table.concat(names, "; ")
            end
        end
    end
    -- Dormant-index alias bridge (item 49 layer 2.5): the ledger's IDENTITY
    -- HANDLES (names + up to 2 aliases — never descriptions or background)
    -- join the index so the model can bridge naming drift wherever it already
    -- runs (updates, merges): it lists a dormant name among an entity's
    -- aliases, and the mechanical wake-pass connects them in the same write.
    local ledger = data[XrayParser.DORMANT_KEY]
    if type(ledger) == "table" and #ledger > 0 then
        local names = {}
        for _idx, stub in ipairs(ledger) do
            if type(stub) == "table" and type(stub.name) == "string" and stub.name ~= "" then
                local name = stub.name
                local stub_aliases = ensure_array(stub.aliases)
                if stub_aliases and #stub_aliases > 0 then
                    local shown = {}
                    for i = 1, math.min(2, #stub_aliases) do
                        shown[i] = stub_aliases[i]
                    end
                    name = name .. " (" .. table.concat(shown, ", ") .. ")"
                end
                names[#names + 1] = name
            end
        end
        if #names > 0 then
            lines[#lines + 1] = "dormant (from related books, not yet in this one): "
                .. table.concat(names, "; ")
        end
    end
    return table.concat(lines, "\n")
end

--- Categories where items use descriptive phrases as names (not stable identifiers).
--- These use pure append during merge instead of name-based matching.
local APPEND_CATEGORIES = {
    timeline = true,
    argument_development = true,
}

--- Merge cross-book background entries (arrays of { source, text }): an
--- addition REPLACES an existing entry from the same source (re-merging an
--- updated book never duplicates) and appends otherwise. Returns a NEW array,
--- nil when nothing valid remains. Pure.
--- @param existing table|nil The item's current background array
--- @param additions table|nil Entries to fold in
--- @return table|nil
function XrayParser.mergeBackground(existing, additions)
    local merged = {}
    -- Round 28 (#90): identity is the source book's FILE PATH when known —
    -- title strings drift (doc_props.title vs display_title vs override gave
    -- the same volume two different labels on one device, so per-source
    -- replace silently duplicated). The label stays display-only. A file-keyed
    -- line also registers its source string, so a legacy line and its
    -- path-keyed successor still collapse to one.
    local by_file = {}
    local by_source = {}
    local function add(entry)
        if type(entry) ~= "table" then return end
        local text = entry.text
        if type(text) ~= "string" or text == "" then return end
        local source = type(entry.source) == "string" and entry.source ~= ""
            and entry.source or "?"
        local file = type(entry.file) == "string" and entry.file ~= ""
            and entry.file or nil
        local line = { source = source, text = text, file = file }
        local idx = file and by_file[file]
        if not idx then
            local sidx = by_source[source]
            if sidx then
                local occ = merged[sidx]
                -- Same source string but two DIFFERENT known files = a real
                -- title collision — keep both lines rather than merge them
                if not (occ.file and file and occ.file ~= file) then
                    idx = sidx
                    -- A replacement never LOSES an identity the slot had
                    line.file = file or occ.file
                end
            end
        end
        if idx then
            merged[idx] = line
        else
            merged[#merged + 1] = line
            idx = #merged
        end
        if line.file then by_file[line.file] = idx end
        by_source[source] = idx
    end
    if type(existing) == "table" then
        for _idx, entry in ipairs(existing) do add(entry) end
    end
    if type(additions) == "table" then
        for _idx, entry in ipairs(additions) do add(entry) end
    end
    if #merged == 0 then return nil end
    return merged
end

--- Merge array category items by name matching (case-insensitive).
--- Matching items are replaced in-place; new items are appended.
--- @param old_items table Existing items array (mutated)
--- @param new_items table New items to merge in
--- @return table old_items The merged array
--- Case-insensitive alias union: keep's aliases first, then new ones not
--- already present. nil when both sides are empty.
local function unionAliases(keep_aliases, new_aliases)
    local out, seen = {}, {}
    -- NOT ipairs({a, b}): a nil first side makes ipairs stop at slot 1 and
    -- silently drop the other list (latent since 2026-08-09 — a rewrite
    -- adding first-ever aliases to an alias-less entry lost them; exposed by
    -- the rename-fold tests 2026-08-14)
    local function addAll(list)
        if type(list) ~= "table" then return end
        for _i, alias in ipairs(list) do
            if type(alias) == "string" and alias ~= "" and not seen[alias:lower()] then
                seen[alias:lower()] = true
                out[#out + 1] = alias
            end
        end
    end
    addAll(keep_aliases)
    addAll(new_aliases)
    return #out > 0 and out or nil
end

--- Case-insensitive union of two string arrays (connections/references),
--- new side first (the fresh read leads); tolerates a bare string on either
--- side. nil when both are empty.
local function unionStringArrays(new_list, keep_list)
    if type(new_list) == "string" then new_list = { new_list } end
    if type(keep_list) == "string" then keep_list = { keep_list } end
    local out, seen = {}, {}
    -- Explicit adds, never ipairs({a, b}) — see unionAliases
    local function addAll(list)
        if type(list) ~= "table" then return end
        for _i, s in ipairs(list) do
            if type(s) == "string" and s ~= "" and not seen[s:lower()] then
                seen[s:lower()] = true
                out[#out + 1] = s
            end
        end
    end
    addAll(new_list)
    addAll(keep_list)
    -- Connection strings carry relationship annotations — "Anna Reyes
    -- (sister)" — so a bare mention and an annotated one of the same person
    -- survive exact-string dedupe as a pair (observed on the first live fold).
    -- A bare "X" yields to any "X (role)" variant; distinct annotations both
    -- stay (they say different things).
    local function baseKey(s)
        return (s:gsub("%s*%b()%s*$", ""):lower():gsub("^%s+", ""):gsub("%s+$", ""))
    end
    -- ONE survivor per TARGET (2026-08-18). A revision re-states a
    -- relationship by extending its own annotation -- "Tobin (a)" becomes
    -- "Tobin (a; b)" -- so keeping every distinct parenthetical accumulated a
    -- fresh copy of the same link at every update, compounding down a ladder
    -- (device: 47 connections resolving to 23 people). Annotated still beats
    -- bare; among annotated the earliest in `out` wins, and `out` leads with
    -- the new side, so the freshest phrasing is the one kept.
    local annotated = {}
    for _i, s in ipairs(out) do
        if s:match("%b()%s*$") then annotated[baseKey(s)] = true end
    end
    local filtered, taken = {}, {}
    for _i, s in ipairs(out) do
        local key = baseKey(s)
        if not taken[key] and (s:match("%b()%s*$") or not annotated[key]) then
            taken[key] = true
            filtered[#filtered + 1] = s
        end
    end
    return #filtered > 0 and filtered or nil
end

--- Reverse-alias rename detection (2026-08-14, a married-name
--- reintroduction caught on device): the delta protocol has no rename verb —
--- a character whose primary name changes can only arrive as a NEW entry
--- carrying the old primary name among its aliases (the model's explicit
--- identity bridge). Find the old entry that bridge points at. Guards: the
--- bridging alias must be MULTI-WORD (short forms — a bare first name —
--- routinely collide with unrelated minor characters; those stay dedup-scan
--- material), must match exactly ONE existing entry's primary name
--- (ambiguity → append, the scan's case), and the pair must not be on the
--- reader's never-merge list.
--- @return number|nil index into old_items
local function renameTarget(new_item, lookup, never_set, new_key)
    if type(new_item) ~= "table" or type(new_item.aliases) ~= "table" then return nil end
    local target, bridge
    for _ai, alias in ipairs(new_item.aliases) do
        if type(alias) == "string" and alias:find("%s") then
            local idx = lookup[alias:lower()]
            if idx then
                if target and target ~= idx then return nil end -- ambiguous
                target, bridge = idx, alias
            end
        end
    end
    if target and never_set and new_key and bridge then
        local a, b = new_key, bridge:lower()
        if a > b then a, b = b, a end
        if never_set[a .. "\0" .. b] then return nil end
    end
    return target
end

local function mergeArrayCategory(old_items, new_items, never_set)
    local lookup = {}
    for i, item in ipairs(old_items) do
        local name = getItemSearchName(item)
        if name then
            lookup[name:lower()] = i
        end
    end
    -- Aliases match too, at LOWER priority than main names (2026-08-09
    -- rename/merge hardening): a delta that re-emits a dedup-dropped or
    -- pre-rename name as its main name must fold into the surviving entry,
    -- not re-create the duplicate. A main name always wins the key; an alias
    -- never shadows another entry's actual name.
    local alias_of = {}
    for i, item in ipairs(old_items) do
        if type(item) == "table" and type(item.aliases) == "table" then
            for _ai, alias in ipairs(item.aliases) do
                if type(alias) == "string" and alias ~= "" then
                    local key = alias:lower()
                    if lookup[key] == nil and alias_of[key] == nil then
                        alias_of[key] = i
                    end
                end
            end
        end
    end
    for _idx, new_item in ipairs(new_items) do
        local name = getItemSearchName(new_item)
        local key = name and name:lower()
        local idx = key and lookup[key]
        local via_alias = false
        if not idx and key then
            idx = alias_of[key]
            via_alias = idx ~= nil
        end
        local via_rename = false
        if not idx and key then
            idx = renameTarget(new_item, lookup, never_set, key)
            via_rename = idx ~= nil
        end
        if idx then
            local keep = old_items[idx]
            -- background is attached mechanically (cross-book merge, item 44)
            -- and never part of the model schema — a rewrite must not shed OR
            -- replace it (round 28: the stored lines always win; model echoes
            -- are dropped at parse, this is the belt for any path that skipped
            -- dropModelBackground)
            new_item.background = keep.background
            if via_alias then
                -- The delta used a secondary name: identity stays the entry's
                -- (a rewrite must not resurrect a renamed/absorbed name as
                -- the main one)
                local keep_name = getItemSearchName(keep)
                if new_item.name ~= nil then new_item.name = keep_name
                elseif new_item.term ~= nil then new_item.term = keep_name
                elseif new_item.event ~= nil then new_item.event = keep_name end
            end
            -- Stored aliases survive the rewrite (dedup absorbs and renames
            -- live there; a model echo that drops them must not shed them)
            new_item.aliases = unionAliases(keep.aliases, new_item.aliases)
            -- Relational data survives EVERY rewrite, not just rename folds
            -- (staleness F2a, 2026-08-17): replace-on-match made re-emitting
            -- an entry the riskiest move available — a status revision that
            -- omitted connections shed them — which taught the model to leave
            -- stale descriptions alone. Union is safe here: short name
            -- strings, nil when both sides are empty, dedup absorbs overlap.
            new_item.connections = unionStringArrays(new_item.connections, keep.connections)
            new_item.references = unionStringArrays(new_item.references, keep.references)
            if via_rename then
                -- Rename fold: the new name IS the point — it stays primary
                -- (the old one rides in aliases, it is the bridge we matched on)
                lookup[key] = idx
                logger.info("KOAssistant: X-Ray merge folded rename '"
                    .. tostring(getItemSearchName(keep)) .. "' -> '" .. tostring(name) .. "'")
            end
            old_items[idx] = new_item
        else
            old_items[#old_items + 1] = new_item
        end
    end
    return old_items
end

--- Append new items to old items without deduplication.
--- Used for timeline/argument_development where names are full sentences.
--- @param old_items table Existing items array (mutated)
--- @param new_items table New items to append
--- @return table old_items The extended array
local function appendCategory(old_items, new_items)
    for _idx, item in ipairs(new_items) do
        old_items[#old_items + 1] = item
    end
    return old_items
end

-- ============== Dormant background ledger (item 49, layers 1-2) ==============
-- A reserved top-level key inside the artifact JSON holding entities CARRIED
-- from related books that have not appeared in THIS book yet — compact stubs
-- { name, aliases, category, description, source, background }. LOCAL-ONLY:
-- stripped from every prompt (zero token cost), invisible to display/search
-- (getCategories never yields it), never authored by the model (write-back
-- drops model-emitted imitations), and it survives XrayParser.merge untouched
-- because merge iterates a fixed key list. The wake-pass below promotes a
-- stub's knowledge into any active entity that matches it.
XrayParser.DORMANT_KEY = "__dormant"

-- What KIND of thing a category holds. Carried knowledge may bridge category
-- drift inside a family (the same figure is `characters` in a novel and
-- `key_figures` in a companion volume) but never across one: a person and a
-- glossary term that share a name are not the same thing (round 26 — a
-- dormant "Keeper" character woke into a "Keeper" lexicon entry on device).
XrayParser.CATEGORY_FAMILY = {
    characters = "people",
    key_figures = "people",
    locations = "places",
    lexicon = "terms",
    terminology = "terms",
    technical_terms = "terms",
    core_concepts = "concepts",
    key_concepts = "concepts",
}

--- Prompt-safe copy of an artifact JSON string: the dormant ledger removed.
--- Returns the input unchanged when no ledger is present (cheap find guard) or
--- when anything about the round-trip fails — a strip failure must never cost
--- the caller the artifact itself. Safe on non-X-Ray strings (prose caches).
--- @param json_str string|nil
--- @return string|nil
--- Canonical parsed→text serialization (the strip helpers' idiom, shared so
--- install-time carries write the same shape the create path caches).
--- @param data table Parsed X-Ray
--- @return string|nil nil on encode failure (callers keep their original text)
function XrayParser.serialize(data)
    local ok, out = pcall(json.encode, data, { pretty = true, indent = true })
    if ok and type(out) == "string" then return out end
    return nil
end

function XrayParser.stripDormantJSON(json_str)
    if type(json_str) ~= "string"
        or not json_str:find('"__dormant"', 1, true) then
        return json_str
    end
    local data = XrayParser.parse(json_str)
    if type(data) ~= "table" or data.error or data[XrayParser.DORMANT_KEY] == nil then
        return json_str
    end
    data[XrayParser.DORMANT_KEY] = nil
    local ok, out = pcall(json.encode, data, { pretty = true, indent = true })
    if ok and type(out) == "string" then return out end
    return json_str
end

--- Prompt-safe copy for UPDATE/MERGE requests (round 28, #90): the dormant
--- ledger AND every mechanical background line removed. Background is
--- code-owned — the model can neither use nor legitimately return it, it
--- inflates dense-script prompts (each folded volume adds paragraphs per
--- entity, compounding through a series), and prompt-visible lines invited
--- the echoes this round dropped. Chat contexts ({xray_cache}) deliberately
--- KEEP background — there it is read-only knowledge for the assistant.
--- Same never-fail contract as stripDormantJSON.
--- @param json_str string|nil
--- @return string|nil
function XrayParser.stripForPromptJSON(json_str)
    if type(json_str) ~= "string"
        or (not json_str:find('"__dormant"', 1, true)
            and not json_str:find('"background"', 1, true)) then
        return json_str
    end
    local data = XrayParser.parse(json_str)
    if type(data) ~= "table" or data.error then
        return json_str
    end
    data[XrayParser.DORMANT_KEY] = nil
    XrayParser.dropModelBackground(data)
    local ok, out = pcall(json.encode, data, { pretty = true, indent = true })
    if ok and type(out) == "string" then return out end
    return json_str
end

--- Background lines a stub contributes to an entity that doesn't already
--- carry lines from those source books (fill-gaps-only — an existing entry
--- from the same source book wins, same rule as the transitive carry).
--- Shared by the automatic wake-pass and the manual wake (browser). Pure.
local function stubBackgroundAdditions(stub, existing_background)
    -- Fill-gaps keys: file path when known (round 28 identity), label always
    local existing_sources = {}
    if type(existing_background) == "table" then
        for _idx, b in ipairs(existing_background) do
            if type(b) == "table" then
                if type(b.source) == "string" then existing_sources[b.source] = true end
                if type(b.file) == "string" then existing_sources[b.file] = true end
            end
        end
    end
    local additions = {}
    local function seen(source, file)
        return existing_sources[source] or (file and existing_sources[file])
    end
    local function mark(source, file)
        existing_sources[source] = true
        if file then existing_sources[file] = true end
    end
    if type(stub.description) == "string" and stub.description ~= ""
        and type(stub.source) == "string" and stub.source ~= ""
        and not seen(stub.source, stub.file) then
        additions[#additions + 1] = { source = stub.source, text = stub.description,
            file = type(stub.file) == "string" and stub.file or nil }
        mark(stub.source, stub.file)
    end
    if type(stub.background) == "table" then
        for _idx, b in ipairs(stub.background) do
            if type(b) == "table" and type(b.text) == "string" and b.text ~= ""
                and type(b.source) == "string" and b.source ~= ""
                and not seen(b.source, b.file) then
                additions[#additions + 1] = { source = b.source, text = b.text,
                    file = type(b.file) == "string" and b.file or nil }
                mark(b.source, b.file)
            end
        end
    end
    return additions
end

--- Wake-pass (carry layer 2): any ledger stub whose name/alias matches an
--- ACTIVE entity folds its carried knowledge into that entity's background —
--- fill-gaps-only, an existing entry from the same source book wins (same
--- rule as the transitive carry) — brings its names along as aliases, and
--- leaves the ledger. Runs on EVERY write-back (merge, incremental update,
--- deepen), so an entity entering by any route wakes its history. Mutates
--- data in place. Pure.
--- @param data table Parsed X-Ray
--- @return table woken Array of { name, source } for logging/toasts
function XrayParser.wakeDormant(data)
    local woken = {}
    if type(data) ~= "table" then return woken end
    local ledger = data[XrayParser.DORMANT_KEY]
    if type(ledger) ~= "table" or #ledger == 0 then
        if ledger ~= nil and (type(ledger) ~= "table" or #ledger == 0) then
            data[XrayParser.DORMANT_KEY] = nil
        end
        return woken
    end
    -- name/alias (lowercased) → active item
    -- Round 26: matching is FAMILY-SCOPED. It used to be a single flat
    -- name→item map over every category, so a dormant CHARACTER woke into a
    -- LEXICON entry that merely shared its name ("Keeper", device corpus) —
    -- the term absorbed a person's history and the real person got nothing.
    -- Within a family the drift is real and must still bridge (a figure is
    -- `characters` in a novel and `key_figures` in a companion volume).
    local lookup, family_lookup = {}, {}
    local function learn(key, item, family)
        if type(key) ~= "string" or key == "" then return end
        local norm = key:lower()
        if lookup[norm] == nil then lookup[norm] = item end
        if family then
            family_lookup[family] = family_lookup[family] or {}
            if family_lookup[family][norm] == nil then family_lookup[family][norm] = item end
        end
    end
    for _idx, cat in ipairs(XrayParser.getCategories(data)) do
        if type(cat.items) == "table" then
            -- Round 27: an unmapped category is its OWN family, so the ledger's
            -- new non-entity stubs (themes, findings, arguments — full
            -- inclusion) can only wake inside their own category instead of
            -- falling through to the flat map, which is the same cross-category
            -- bug round 26 fixed for "Keeper". Mapped families still bridge
            -- their synonyms (characters ↔ key_figures).
            local family = XrayParser.CATEGORY_FAMILY[cat.key] or cat.key
            for _idx2, item in ipairs(cat.items) do
                if type(item) == "table" then
                    learn(XrayParser.getItemName(item, cat.key), item, family)
                    if type(item.aliases) == "table" then
                        for _idx3, alias in ipairs(item.aliases) do learn(alias, item, family) end
                    end
                end
            end
        end
    end
    local remaining = {}
    for _idx, stub in ipairs(ledger) do
        local hit
        if type(stub) == "table" then
            -- A stub that knows its category may only wake inside its family
            -- (or, unmapped, inside that category); one with no category
            -- recorded (pre-ledger writes) keeps the flat match
            local stub_cat = type(stub.category) == "string" and stub.category ~= ""
                and stub.category or nil
            local stub_family = stub_cat
                and (XrayParser.CATEGORY_FAMILY[stub_cat] or stub_cat) or nil
            local scope = stub_family and (family_lookup[stub_family] or {}) or lookup
            hit = type(stub.name) == "string" and stub.name ~= ""
                and scope[stub.name:lower()] or nil
            if not hit and type(stub.aliases) == "table" then
                for _idx2, alias in ipairs(stub.aliases) do
                    if type(alias) == "string" and alias ~= "" and scope[alias:lower()] then
                        hit = scope[alias:lower()]
                        break
                    end
                end
            end
        end
        if hit then
            local additions = stubBackgroundAdditions(stub, hit.background)
            if #additions > 0 then
                hit.background = XrayParser.mergeBackground(hit.background, additions)
            end
            -- A stub matched by alias brings the other book's names along
            local function foldAlias(name)
                if type(name) ~= "string" or name == "" then return end
                local norm = name:lower()
                if lookup[norm] ~= nil then return end -- known name (this or another entity)
                local arr = ensure_array(hit.aliases) or {}
                arr[#arr + 1] = name
                hit.aliases = arr
                lookup[norm] = hit
            end
            foldAlias(stub.name)
            if type(stub.aliases) == "table" then
                for _idx2, a in ipairs(stub.aliases) do foldAlias(a) end
            end
            woken[#woken + 1] = { name = stub.name, source = stub.source }
        else
            remaining[#remaining + 1] = stub
        end
    end
    data[XrayParser.DORMANT_KEY] = #remaining > 0 and remaining or nil
    return woken
end

--- Find an ACTIVE entity by any of several identity handles (round 25, cross-
--- book group navigation): the same person can be "Mira Alvsund" in one volume
--- and "the Keeper" in the next, and can drift category between volumes, so
--- match on name AND aliases across every category — preferred category first,
--- then the rest. Pure.
--- @param data table Parsed X-Ray
--- @param names table Identity handles to try (name + aliases of the source item)
--- @param preferred_category string|nil Category key to search first
--- @return table|nil item, string|nil category_key, number|nil index
function XrayParser.findByIdentity(data, names, preferred_category)
    if type(data) ~= "table" or type(names) ~= "table" or #names == 0 then return nil end
    local wanted = {}
    for _idx, n in ipairs(names) do
        if type(n) == "string" and n ~= "" then wanted[n:lower()] = true end
    end
    if not next(wanted) then return nil end
    local function scan(cat)
        if SINGLETON_CATEGORIES[cat.key] or type(cat.items) ~= "table" then return nil end
        for i, item in ipairs(cat.items) do
            if type(item) == "table" then
                local name = XrayParser.getItemName(item, cat.key)
                if type(name) == "string" and wanted[name:lower()] then return item, cat.key, i end
                local aliases = ensure_array(item.aliases)
                if aliases then
                    for _idx2, a in ipairs(aliases) do
                        if type(a) == "string" and wanted[a:lower()] then return item, cat.key, i end
                    end
                end
            end
        end
        return nil
    end
    local categories = XrayParser.getCategories(data)
    if preferred_category then
        for _idx, cat in ipairs(categories) do
            if cat.key == preferred_category then
                local item, key, i = scan(cat)
                if item then return item, key, i end
                break
            end
        end
    end
    for _idx, cat in ipairs(categories) do
        if cat.key ~= preferred_category then
            local item, key, i = scan(cat)
            if item then return item, key, i end
        end
    end
    return nil
end

--- Same identity match against the DORMANT ledger: an entity absent from this
--- book's visible entries may still be carried here from an earlier volume,
--- which is a more honest landing than "not found". Pure.
--- @param data table Parsed X-Ray
--- @param names table Identity handles to try
--- @return table|nil stub, number|nil index
function XrayParser.findDormantByIdentity(data, names)
    if type(data) ~= "table" or type(names) ~= "table" then return nil end
    local ledger = data[XrayParser.DORMANT_KEY]
    if type(ledger) ~= "table" then return nil end
    local wanted = {}
    for _idx, n in ipairs(names) do
        if type(n) == "string" and n ~= "" then wanted[n:lower()] = true end
    end
    if not next(wanted) then return nil end
    for i, stub in ipairs(ledger) do
        if type(stub) == "table" then
            if type(stub.name) == "string" and wanted[stub.name:lower()] then return stub, i end
            if type(stub.aliases) == "table" then
                for _idx2, a in ipairs(stub.aliases) do
                    if type(a) == "string" and wanted[a:lower()] then return stub, i end
                end
            end
        end
    end
    return nil
end

--- Remove one ledger stub, positional identity verified by name (the dedup
--- rule: never act on an entry the reader did not see). Falls back to a
--- name scan ONLY when the name is unambiguous in the ledger. Mutates data.
--- @param data table Parsed X-Ray
--- @param stub_idx number Ledger index at scan time
--- @param stub_name string Expected stub name
--- @return table|nil stub The removed stub (nil = not found / ambiguous)
function XrayParser.removeStub(data, stub_idx, stub_name)
    if type(data) ~= "table" or type(stub_name) ~= "string" then return nil end
    local ledger = data[XrayParser.DORMANT_KEY]
    if type(ledger) ~= "table" then return nil end
    local stub = ledger[stub_idx]
    if not (type(stub) == "table" and stub.name == stub_name) then
        stub = nil
        for i, s in ipairs(ledger) do
            if type(s) == "table" and s.name == stub_name then
                if stub then return nil end -- ambiguous — refuse
                stub, stub_idx = s, i
            end
        end
        if not stub then return nil end
    end
    table.remove(ledger, stub_idx)
    if #ledger == 0 then data[XrayParser.DORMANT_KEY] = nil end
    return stub
end

--- Manual wake INTO an existing entity (series-identity round, 2026-08-06):
--- reader-asserted identity — the chosen ACTIVE item gains the stub's carried
--- background (fill-gaps-only per source) and its names as aliases; the stub
--- leaves the ledger. The manual counterpart of the wake-pass hit branch,
--- and the zero-token fix for cross-volume naming drift the model missed
--- ("the boy" IS Tobias Renn). Target resolved by category + name, ambiguity
--- refused. Mutates data.
--- @param data table Parsed X-Ray
--- @param stub_idx number Ledger index at scan time
--- @param stub_name string Expected stub name
--- @param cat_key string Target item's category key
--- @param item_name string Target item's name (getItemName form)
--- @return boolean ok
function XrayParser.wakeStubInto(data, stub_idx, stub_name, cat_key, item_name)
    if type(data) ~= "table" then return false end
    local target
    for _idx, cat in ipairs(XrayParser.getCategories(data)) do
        if cat.key == cat_key and type(cat.items) == "table" then
            for _idx2, item in ipairs(cat.items) do
                if type(item) == "table"
                    and XrayParser.getItemName(item, cat_key) == item_name then
                    if target then return false end -- ambiguous name — refuse
                    target = item
                end
            end
        end
    end
    if not target then return false end
    local stub = XrayParser.removeStub(data, stub_idx, stub_name)
    if not stub then return false end
    local additions = stubBackgroundAdditions(stub, target.background)
    if #additions > 0 then
        target.background = XrayParser.mergeBackground(target.background, additions)
    end
    local aliases = ensure_array(target.aliases) or {}
    local seen = {}
    if type(target.name) == "string" then seen[target.name:lower()] = true end
    if type(target.term) == "string" then seen[target.term:lower()] = true end
    for _idx, a in ipairs(aliases) do
        if type(a) == "string" then seen[a:lower()] = true end
    end
    local function foldAlias(name)
        if type(name) == "string" and name ~= "" and not seen[name:lower()] then
            aliases[#aliases + 1] = name
            seen[name:lower()] = true
        end
    end
    foldAlias(stub.name)
    if type(stub.aliases) == "table" then
        for _idx, a in ipairs(stub.aliases) do foldAlias(a) end
    end
    if #aliases > 0 then target.aliases = aliases end
    return true
end

--- Manual wake as a NEW visible entry: the stub becomes a full item in its
--- own category — description verbatim, ancestor background lines kept with
--- their labels. Refused when the artifact's type has no such category
--- (cross-type series). Mutates data.
--- @param data table Parsed X-Ray
--- @param stub_idx number Ledger index at scan time
--- @param stub_name string Expected stub name
--- @return boolean ok
function XrayParser.promoteStub(data, stub_idx, stub_name)
    if type(data) ~= "table" then return false end
    local ledger = data[XrayParser.DORMANT_KEY]
    local probe = type(ledger) == "table" and ledger[stub_idx] or nil
    local cat_key
    if type(probe) == "table" and probe.name == stub_name then
        cat_key = probe.category
    else
        for _idx, s in ipairs(type(ledger) == "table" and ledger or {}) do
            if type(s) == "table" and s.name == stub_name then cat_key = s.category end
        end
    end
    if type(cat_key) ~= "string" then return false end
    local valid = false
    for _idx, cat in ipairs(XrayParser.getCategories(data)) do
        if cat.key == cat_key then valid = true break end
    end
    if not valid then return false end
    local stub = XrayParser.removeStub(data, stub_idx, stub_name)
    if not stub then return false end
    local item
    if cat_key == "lexicon" or cat_key == "terminology" or cat_key == "technical_terms" then
        item = { term = stub.name, definition = stub.description or "" }
    else
        item = { name = stub.name, description = stub.description or "" }
    end
    if type(stub.aliases) == "table" and #stub.aliases > 0 then item.aliases = stub.aliases end
    if type(stub.background) == "table" and #stub.background > 0 then item.background = stub.background end
    local arr = data[cat_key]
    if type(arr) ~= "table" then
        arr = {}
        data[cat_key] = arr
    end
    arr[#arr + 1] = item
    return true
end

--- The inverse of promoteStub: a visible entry goes back to the carried list.
--- Round 27 (maintainer: "Add as its own entry could easily be done by accident
--- and there is no way back"). Restricted by its CALLERS to entries that carry
--- cross-book background — those honestly belong to an earlier book, so the
--- carried list is an honest home for them; a native entry of THIS book would
--- be mislabeled there, and a destructive "delete entry" is a separate
--- question. Nothing is marked on promote, so nothing leaks into a prompt:
--- the round trip is inferred from the data itself.
--- @param data table Parsed X-Ray (mutated)
--- @param cat_key string Category holding the entry
--- @param item_name string Entry name (ambiguous names refused, as elsewhere)
--- @return boolean ok
--- Add identity handles to an entry's aliases (Manage ▸ Link, 2026-08-09):
--- case-insensitive dedupe against the main name and existing aliases. Same
--- exact-name find + ambiguity guard as renameItem. Returns true when the
--- entry was found — even if every name was already present (the link is
--- then already recorded). Pure.
--- @param data table Parsed X-Ray
--- @param cat_key string Category key
--- @param item_name string Main name (exact)
--- @param names table Identity handles to add
--- @return boolean ok
function XrayParser.addItemAliases(data, cat_key, item_name, names)
    if type(data) ~= "table" or type(cat_key) ~= "string"
        or type(item_name) ~= "string" or item_name == ""
        or type(names) ~= "table" then
        return false
    end
    local arr = data[cat_key]
    if type(arr) ~= "table" then return false end
    local at
    for i, item in ipairs(arr) do
        if type(item) == "table" and XrayParser.getItemName(item, cat_key) == item_name then
            if at then return false end -- ambiguous name — refuse
            at = i
        end
    end
    if not at then return false end
    local item = arr[at]
    local aliases = ensure_array(item.aliases) or {}
    local seen = { [item_name:lower()] = true }
    for _idx, a in ipairs(aliases) do
        if type(a) == "string" then seen[a:lower()] = true end
    end
    for _idx, n in ipairs(names) do
        if type(n) == "string" and n ~= "" and not seen[n:lower()] then
            seen[n:lower()] = true
            aliases[#aliases + 1] = n
        end
    end
    item.aliases = #aliases > 0 and aliases or nil
    return true
end

--- Rename an entry's main name (Manage ▸ Rename, 2026-08-09). The old name is
--- pushed onto the FRONT of aliases so the model keeps the mapping
--- ({entity_index} shows "New (old, …)", {cached_result} carries the full
--- array) and the alias-aware delta-merge folds late deltas that still use
--- it. Refuses ambiguous names (same guard as demoteToStub). Side stores
--- keyed by the old name are the caller's job (ActionCache.renameEntityKeys).
--- @param data table Parsed X-Ray
--- @param cat_key string Category key
--- @param old_name string Current main name (exact)
--- @param new_name string Replacement main name
--- @return boolean ok
function XrayParser.renameItem(data, cat_key, old_name, new_name)
    if type(data) ~= "table" or type(cat_key) ~= "string"
        or type(old_name) ~= "string" or old_name == ""
        or type(new_name) ~= "string" or new_name == ""
        or old_name == new_name then
        return false
    end
    local arr = data[cat_key]
    if type(arr) ~= "table" then return false end
    local at
    for i, item in ipairs(arr) do
        if type(item) == "table" and XrayParser.getItemName(item, cat_key) == old_name then
            if at then return false end -- ambiguous name — refuse
            at = i
        end
    end
    if not at then return false end
    local item = arr[at]
    if item.name ~= nil then item.name = new_name
    elseif item.term ~= nil then item.term = new_name
    elseif item.event ~= nil then item.event = new_name
    else return false end
    -- Old name → front of aliases; the new name stops being an alias if it
    -- was one (it is the main name now)
    local aliases = { old_name }
    local seen = { [old_name:lower()] = true, [new_name:lower()] = true }
    for _idx, alias in ipairs(type(item.aliases) == "table" and item.aliases or {}) do
        if type(alias) == "string" and alias ~= "" and not seen[alias:lower()] then
            seen[alias:lower()] = true
            aliases[#aliases + 1] = alias
        end
    end
    item.aliases = aliases
    return true
end

function XrayParser.demoteToStub(data, cat_key, item_name)
    if type(data) ~= "table" or type(cat_key) ~= "string" or type(item_name) ~= "string" then
        return false
    end
    local arr = data[cat_key]
    if type(arr) ~= "table" then return false end
    local at
    for i, item in ipairs(arr) do
        if type(item) == "table" and XrayParser.getItemName(item, cat_key) == item_name then
            if at then return false end -- ambiguous name — refuse, as removeStub does
            at = i
        end
    end
    if not at then return false end
    local item = arr[at]
    -- Source: the earliest book that contributed background, so the row reads
    -- "carried from <that book>" exactly as it did before it was promoted
    local source
    if type(item.background) == "table" then
        for _idx, b in ipairs(item.background) do
            if type(b) == "table" and type(b.source) == "string" and b.source ~= "" then
                source = b.source
                break
            end
        end
    end
    if not source then return false end
    local stub = {
        name = item_name,
        category = cat_key,
        source = source,
        description = type(item.description) == "string" and item.description ~= ""
            and item.description or nil,
        background = item.background,
    }
    if type(item.aliases) == "table" and #item.aliases > 0 then
        stub.aliases = {}
        for _idx, a in ipairs(item.aliases) do stub.aliases[#stub.aliases + 1] = a end
    end
    table.remove(arr, at)
    local ledger = data[XrayParser.DORMANT_KEY]
    if type(ledger) ~= "table" then
        ledger = {}
        data[XrayParser.DORMANT_KEY] = ledger
    end
    ledger[#ledger + 1] = stub
    return true
end

--- Merge partial X-Ray update into existing data.
--- The AI outputs only new/changed entries; this merges them into the full dataset.
--- @param old_data table Complete existing X-Ray data (mutated in place)
--- @param new_data table Partial update from AI
--- @param opts table|nil { never_pairs = ActionCache.getNeverMergePairs output }
---   — reader-ruled non-identical pairs the rename fold must not merge
--- @return table old_data The merged result
function XrayParser.merge(old_data, new_data, opts)
    if not new_data or type(new_data) ~= "table" then return old_data end
    if not old_data or type(old_data) ~= "table" then return new_data end

    local never_set
    if opts and type(opts.never_pairs) == "table" then
        never_set = {}
        for _idx, pair in ipairs(opts.never_pairs) do
            if type(pair) == "table" and type(pair[1]) == "string" and type(pair[2]) == "string" then
                local a, b = pair[1]:lower(), pair[2]:lower()
                if a > b then a, b = b, a end
                never_set[a .. "\0" .. b] = true
            end
        end
    end

    old_data.type = old_data.type or new_data.type

    local keys
    if XrayParser.isAcademic(old_data) then
        keys = ACADEMIC_KEYS
    elseif XrayParser.isFiction(old_data) then
        keys = FICTION_KEYS
    else
        keys = NONFICTION_KEYS
    end
    for _idx, key in ipairs(keys) do
        if new_data[key] ~= nil then
            if SINGLETON_CATEGORIES[key] then
                old_data[key] = new_data[key]
            elseif APPEND_CATEGORIES[key] then
                if type(new_data[key]) == "table" and #new_data[key] > 0 then
                    old_data[key] = appendCategory(old_data[key] or {}, new_data[key])
                end
            else
                if type(new_data[key]) == "table" then
                    old_data[key] = mergeArrayCategory(old_data[key] or {}, new_data[key], never_set)
                end
            end
        end
    end

    return old_data
end

return XrayParser
