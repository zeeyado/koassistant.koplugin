local ContextExtractor = require("koassistant_context_extractor")

local BookTools = {}
BookTools.__index = BookTools

local DEFAULT_MAX_RESULTS = 8
local MAX_RESULTS = 12
local MAX_READ_PAGES = 5
local MAX_READ_CHARS = 8000
local MAX_SNIPPET_CHARS = 1200
local DEFAULT_TOC_SNIPPET_CHARS = 300
local MAX_TOC_SNIPPET_CHARS = 800
local MAX_TOC_ENTRIES = 120

local function clamp(value, min_value, max_value)
    value = tonumber(value) or min_value
    if value < min_value then return min_value end
    if value > max_value then return max_value end
    return value
end

local function trim(text)
    if type(text) ~= "string" then return "" end
    return (text:gsub("^%s+", ""):gsub("%s+$", ""))
end

local function squeeze(text)
    return trim((text or ""):gsub("%s+", " "))
end

local function excerpt(text, max_chars)
    text = squeeze(text)
    max_chars = max_chars or MAX_SNIPPET_CHARS
    if #text <= max_chars then return text end
    return trim(text:sub(1, max_chars - 3)) .. "..."
end

local function normalizeText(text, case_sensitive)
    text = squeeze(text)
    if not case_sensitive then
        text = text:lower()
    end
    return text
end

local function tokenize(text, case_sensitive)
    text = text or ""
    if not case_sensitive then
        text = text:lower()
    end
    local tokens = {}
    local seen = {}
    for token in text:gmatch("[%w']+") do
        if token ~= "" and not seen[token] then
            seen[token] = true
            table.insert(tokens, token)
        end
    end
    return tokens
end

local function splitSentences(text)
    text = (text or ""):gsub("[\r\n]+", ". ")
    local sentences = {}
    for sentence in text:gmatch("[^%.%!%?]+[%.%!%?]?") do
        local current = squeeze(sentence)
        if current ~= "" then
            while #current > 700 do
                local cut = current:sub(1, 700):match("^(.+)%s+%S*$") or current:sub(1, 700)
                table.insert(sentences, trim(cut))
                current = trim(current:sub(#cut + 1))
            end
            if current ~= "" then
                table.insert(sentences, current)
            end
        end
    end
    return sentences
end

local function levenshteinWithin(a, b, max_distance)
    if a == b then return true end
    local la, lb = #a, #b
    if math.abs(la - lb) > max_distance then return false end
    if la == 0 or lb == 0 then return math.max(la, lb) <= max_distance end

    local prev = {}
    local curr = {}
    for j = 0, lb do prev[j] = j end

    for i = 1, la do
        curr[0] = i
        local row_min = curr[0]
        local ca = a:sub(i, i)
        for j = 1, lb do
            local cost = ca == b:sub(j, j) and 0 or 1
            local deletion = prev[j] + 1
            local insertion = curr[j - 1] + 1
            local substitution = prev[j - 1] + cost
            local value = math.min(deletion, insertion, substitution)
            curr[j] = value
            if value < row_min then row_min = value end
        end
        if row_min > max_distance then return false end
        prev, curr = curr, prev
    end

    return prev[lb] <= max_distance
end

local function tokenThreshold(token)
    local len = #token
    if len <= 3 then return 0 end
    return math.max(1, math.floor(len * 0.25))
end

local function allTokensPresent(tokens, haystack)
    for _, token in ipairs(tokens) do
        if not haystack:find(token, 1, true) then
            return false
        end
    end
    return true
end

local function allTokensFuzzy(tokens, sentence_tokens)
    for _, query_token in ipairs(tokens) do
        local threshold = tokenThreshold(query_token)
        local matched = false
        for _, sentence_token in ipairs(sentence_tokens) do
            if threshold == 0 then
                matched = query_token == sentence_token
            elseif levenshteinWithin(query_token, sentence_token, threshold) then
                matched = true
            end
            if matched then break end
        end
        if not matched then return false end
    end
    return true
end

local function safeCall(fn)
    local ok, result = pcall(fn)
    if ok then return result end
    return nil
end

function BookTools:new(ui, settings)
    local instance = setmetatable({}, self)
    instance.ui = ui
    instance.settings = settings or {}
    instance.extractor = ContextExtractor:new(ui, instance.settings)
    instance.page_cache = {}
    instance.last_hits = {}
    return instance
end

function BookTools:getTotalPages()
    local document = self.ui and self.ui.document
    return document and document.info and document.info.number_of_pages or 0
end

function BookTools:getCurrentPage()
    local document = self.ui and self.ui.document
    if not document then return nil end

    local page = self.ui.view and self.ui.view.state and self.ui.view.state.page
    if not page and document.getXPointer and document.getPageFromXPointer then
        local xp = safeCall(function() return document:getXPointer() end)
        if xp then
            page = safeCall(function() return document:getPageFromXPointer(xp) end)
        end
    end
    page = tonumber(page)

    local total_pages = self:getTotalPages()
    if total_pages <= 0 then return page end
    if not page or page < 1 then return 1 end
    if page > total_pages then return total_pages end
    return page
end

function BookTools:isAvailable()
    return self.ui and self.ui.document and self:getTotalPages() > 0
end

function BookTools:getPageText(page, max_chars)
    page = tonumber(page)
    if not page then return "" end
    local total_pages = self:getTotalPages()
    if total_pages <= 0 or page < 1 or page > total_pages then return "" end

    local cached = self.page_cache[page]
    if cached then return cached end

    local result = self.extractor:getPageRangeText(page, page, {
        max_chars = max_chars or 20000,
    })
    local text = result and result.text or ""
    self.page_cache[page] = text
    return text
end

function BookTools:getRangeText(start_page, end_page, max_chars)
    local current_page = self:getCurrentPage() or self:getTotalPages()
    if not current_page then current_page = 1 end
    start_page = clamp(start_page, 1, current_page)
    end_page = clamp(end_page, start_page, current_page)

    local result = self.extractor:getPageRangeText(start_page, end_page, {
        max_chars = max_chars or MAX_READ_CHARS,
    })
    return result and result.text or ""
end

function BookTools:scoreSentence(sentence, query, query_tokens, fuzzy, case_sensitive)
    local normalized_sentence = normalizeText(sentence, case_sensitive)
    local normalized_query = normalizeText(query, case_sensitive)

    if normalized_sentence:find(normalized_query, 1, true) then
        return 100 + math.min(#normalized_query, 40)
    end
    if allTokensPresent(query_tokens, normalized_sentence) then
        return 70 + #query_tokens
    end
    if fuzzy then
        local sentence_tokens = tokenize(sentence, case_sensitive)
        if allTokensFuzzy(query_tokens, sentence_tokens) then
            return 45 + #query_tokens
        end
    end
    return 0
end

function BookTools:searchBook(args)
    args = args or {}
    local query = trim(args.query)
    if query == "" then
        return { ok = false, error = "query is required" }
    end
    if not self:isAvailable() then
        return { ok = false, error = "book text is not available" }
    end

    local current_page = self:getCurrentPage() or self:getTotalPages()
    local max_results = clamp(args.max_results or DEFAULT_MAX_RESULTS, 1, MAX_RESULTS)
    local fuzzy = args.fuzzy ~= false
    local case_sensitive = args.case_sensitive == true
    local query_tokens = tokenize(query, case_sensitive)
    if #query_tokens == 0 then
        return { ok = false, error = "query must contain searchable text" }
    end

    local scored = {}
    self.last_hits = {}

    for page = 1, current_page do
        local page_text = self:getPageText(page)
        local sentences = splitSentences(page_text)
        for index, sentence in ipairs(sentences) do
            local score = self:scoreSentence(sentence, query, query_tokens, fuzzy, case_sensitive)
            if score > 0 then
                local hit_id = string.format("p%d:%d", page, index)
                local snippet_parts = {}
                if sentences[index - 1] then table.insert(snippet_parts, sentences[index - 1]) end
                table.insert(snippet_parts, sentence)
                if sentences[index + 1] then table.insert(snippet_parts, sentences[index + 1]) end
                local hit = {
                    hit_id = hit_id,
                    page = page,
                    score = score,
                    snippet = excerpt(table.concat(snippet_parts, " "), MAX_SNIPPET_CHARS),
                }
                table.insert(scored, hit)
                self.last_hits[hit_id] = hit
            end
        end
    end

    table.sort(scored, function(a, b)
        if a.score == b.score then
            return a.page < b.page
        end
        return a.score > b.score
    end)

    local results = {}
    for i = 1, math.min(#scored, max_results) do
        table.insert(results, scored[i])
    end

    return {
        ok = true,
        query = query,
        scope = { start_page = 1, end_page = current_page },
        result_count = #results,
        results = results,
    }
end

function BookTools:readAround(args)
    args = args or {}
    if not self:isAvailable() then
        return { ok = false, error = "book text is not available" }
    end

    local page = tonumber(args.page)
    if args.hit_id and self.last_hits[args.hit_id] then
        page = self.last_hits[args.hit_id].page
    elseif args.hit_id then
        page = tonumber(tostring(args.hit_id):match("^p(%d+):%d+$"))
    end
    if not page then
        return { ok = false, error = "hit_id or page is required" }
    end

    local current_page = self:getCurrentPage() or self:getTotalPages()
    page = clamp(page, 1, current_page)
    local before_pages = clamp(args.before_pages or 1, 0, MAX_READ_PAGES - 1)
    local after_pages = clamp(args.after_pages or 1, 0, MAX_READ_PAGES - 1)
    local start_page = math.max(1, page - before_pages)
    local end_page = math.min(current_page, page + after_pages)

    while end_page - start_page + 1 > MAX_READ_PAGES do
        if page - start_page > end_page - page then
            start_page = start_page + 1
        else
            end_page = end_page - 1
        end
    end

    local text = self:getRangeText(start_page, end_page, MAX_READ_CHARS)
    return {
        ok = true,
        page = page,
        range = { start_page = start_page, end_page = end_page },
        chars = #text,
        text = excerpt(text, MAX_READ_CHARS),
    }
end

function BookTools:getEffectiveToc()
    local document = self.ui and self.ui.document
    local toc = self.ui and self.ui.toc and self.ui.toc.toc
    if not toc or #toc == 0 then return nil end

    if document and document.hasHiddenFlows and document:hasHiddenFlows() then
        local filtered = {}
        for _, entry in ipairs(toc) do
            if entry.page and document:getPageFlow(entry.page) == 0 then
                table.insert(filtered, entry)
            end
        end
        return filtered
    end
    return toc
end

function BookTools:toc(args)
    args = args or {}
    if not self:isAvailable() then
        return { ok = false, error = "book text is not available" }
    end

    local current_page = self:getCurrentPage() or self:getTotalPages()
    local max_snippet_chars = clamp(args.max_snippet_chars or DEFAULT_TOC_SNIPPET_CHARS, 0, MAX_TOC_SNIPPET_CHARS)
    local max_entries = clamp(args.max_entries or MAX_TOC_ENTRIES, 1, MAX_TOC_ENTRIES)
    local toc = self:getEffectiveToc()
    local entries = {}

    if toc and #toc > 0 then
        for i, entry in ipairs(toc) do
            local start_page = tonumber(entry.page)
            if start_page and start_page <= current_page then
                local depth = entry.depth or 1
                local end_page = current_page
                for j = i + 1, #toc do
                    local next_entry = toc[j]
                    if next_entry.page and (next_entry.depth or 1) <= depth then
                        end_page = math.min(current_page, next_entry.page - 1)
                        break
                    end
                end
                if end_page >= start_page then
                    local snippet = ""
                    if max_snippet_chars > 0 then
                        snippet = excerpt(self:getRangeText(start_page, math.min(start_page, end_page), max_snippet_chars), max_snippet_chars)
                    end
                    table.insert(entries, {
                        title = entry.title or "",
                        depth = depth,
                        start_page = start_page,
                        end_page = end_page,
                        snippet = snippet,
                    })
                    if #entries >= max_entries then break end
                end
            end
        end
    end

    if #entries == 0 then
        table.insert(entries, {
            title = "Pages read so far",
            depth = 1,
            start_page = 1,
            end_page = current_page,
            snippet = max_snippet_chars > 0 and excerpt(self:getRangeText(1, math.min(1, current_page), max_snippet_chars), max_snippet_chars) or "",
        })
    end

    return {
        ok = true,
        scope = { start_page = 1, end_page = current_page },
        entry_count = #entries,
        truncated = toc and #entries >= max_entries and #toc > max_entries or false,
        entries = entries,
    }
end

function BookTools:execute(name, args)
    if name == "search_book" then
        return self:searchBook(args)
    elseif name == "read_around" then
        return self:readAround(args)
    elseif name == "toc" then
        return self:toc(args)
    end
    return { ok = false, error = "unknown tool: " .. tostring(name) }
end

return BookTools
