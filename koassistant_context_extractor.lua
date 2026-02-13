--[[--
Context extractor for KOAssistant.

This module extracts reading context data from KOReader documents:
- Book text (EPUB via XPointers, PDF via page extraction)
- Highlights and annotations
- Reading progress and statistics
- Chapter information

@module koassistant_context_extractor
]]

local Constants = require("koassistant_constants")
local lfs = require("libs/libkoreader-lfs")
local logger = require("logger")

local ContextExtractor = {}
ContextExtractor.__index = ContextExtractor

--- Get contiguous ranges of visible (flow 0) pages within a page range.
--- Short-circuits when no hidden flows active.
--- @param document table KOReader document object
--- @param from_page number Start page (inclusive, actual page number)
--- @param to_page number End page (inclusive, actual page number)
--- @return table ranges Array of {start_page, end_page}
function ContextExtractor.getVisiblePageRanges(document, from_page, to_page)
    if not document.hasHiddenFlows or not document:hasHiddenFlows() then
        return {{ start_page = from_page, end_page = to_page }}
    end
    local ranges = {}
    local range_start = nil
    for page = from_page, to_page do
        if document:getPageFlow(page) == 0 then
            if not range_start then range_start = page end
        else
            if range_start then
                table.insert(ranges, { start_page = range_start, end_page = page - 1 })
                range_start = nil
            end
        end
    end
    if range_start then
        table.insert(ranges, { start_page = range_start, end_page = to_page })
    end
    return ranges
end

--- Compute flow fingerprint: count of visible (flow 0) pages.
--- Returns nil when no hidden flows active (no fingerprint needed).
--- @param document table KOReader document object
--- @return number|nil visible_page_count
function ContextExtractor.getFlowFingerprint(document)
    if not document.hasHiddenFlows or not document:hasHiddenFlows() then
        return nil
    end
    local total_pages = document.info and document.info.number_of_pages or 0
    local visible = 0
    for page = 1, total_pages do
        if document:getPageFlow(page) == 0 then
            visible = visible + 1
        end
    end
    return visible
end

--- Extract text from visible page ranges using XPointers.
--- @param document table KOReader document object
--- @param ranges table Array of {start_page, end_page} from getVisiblePageRanges
--- @param total_pages number Total pages in document
--- @return string text
local function extractVisibleText(document, ranges, total_pages)
    if #ranges == 0 then return "" end
    local parts = {}
    for _idx, r in ipairs(ranges) do
        local start_xp = document:getPageXPointer(r.start_page)
        local end_xp = document:getPageXPointer(math.min(r.end_page + 1, total_pages))
        if start_xp and end_xp then
            local text = document:getTextFromXPointers(start_xp, end_xp)
            if text and text ~= "" then
                table.insert(parts, text)
            end
        end
    end
    return table.concat(parts, "\n")
end

--- Create a new ContextExtractor instance.
-- @param ui KOReader UI instance (ReaderUI)
-- @param settings Settings table with extraction limits
-- @return ContextExtractor instance
function ContextExtractor:new(ui, settings)
    local instance = setmetatable({}, self)
    instance.ui = ui
    instance.settings = settings or {}
    return instance
end

--- Check if extraction is available (document is open).
-- @return boolean
function ContextExtractor:isAvailable()
    return self.ui and self.ui.document ~= nil
end

--- Check if current provider is trusted (bypasses privacy settings).
-- @return boolean
function ContextExtractor:isProviderTrusted()
    local provider = self.settings.provider
    local trusted_providers = self.settings.trusted_providers or {}

    if not provider then
        return false
    end

    for _idx, trusted_id in ipairs(trusted_providers) do
        if trusted_id == provider then
            return true
        end
    end
    return false
end

--- Get reading progress as percentage.
-- Always calculates fresh from current position for accuracy.
-- @return table { percent = 42, formatted = "42%", decimal = 0.42 }
function ContextExtractor:getReadingProgress()
    local result = {
        percent = 0,
        formatted = "0%",
        decimal = 0,
    }

    if not self:isAvailable() then
        return result
    end

    local percent_finished = 0

    -- Always calculate fresh from current position when document is open
    -- (doc_settings:readSetting("percent_finished") can be stale until autosave)
    if self.ui.document then
        local total_pages = self.ui.document.info and self.ui.document.info.number_of_pages
        if total_pages and total_pages > 0 then
            local current_page
            if self.ui.document.info.has_pages then
                -- Page-based document (PDF)
                current_page = self.ui.view and self.ui.view.state and self.ui.view.state.page or 1
            else
                -- Flowing document (EPUB) - get page from current position
                local current_xp = self.ui.document:getXPointer()
                if current_xp then
                    current_page = self.ui.document:getPageFromXPointer(current_xp) or 1
                else
                    current_page = 1
                end
            end
            -- Flow-aware progress: count only visible pages when hidden flows active
            if self.ui.document.hasHiddenFlows
                    and self.ui.document:hasHiddenFlows() then
                local visible_at_or_before = 0
                local total_visible = 0
                for page = 1, total_pages do
                    if self.ui.document:getPageFlow(page) == 0 then
                        total_visible = total_visible + 1
                        if page <= current_page then
                            visible_at_or_before = visible_at_or_before + 1
                        end
                    end
                end
                if total_visible > 0 then
                    percent_finished = visible_at_or_before / total_visible
                else
                    percent_finished = current_page / total_pages
                end
            else
                percent_finished = current_page / total_pages
            end

            result.current_page = current_page
            result.total_pages = total_pages
        end
    end

    -- Fallback to saved setting only if live calculation failed
    if percent_finished == 0 and self.ui.doc_settings then
        percent_finished = self.ui.doc_settings:readSetting("percent_finished") or 0
    end

    result.decimal = percent_finished
    result.percent = math.floor(percent_finished * 100 + 0.5)
    result.formatted = tostring(result.percent) .. "%"

    return result
end

--- Check if book text extraction is enabled globally.
-- @return boolean
function ContextExtractor:isBookTextExtractionEnabled()
    -- Default to false if not explicitly enabled
    return self.settings.enable_book_text_extraction == true
end

--- Get book text up to current reading position.
-- @param options table { max_chars = 1000000, max_pages = 500 }
-- @return table { text, truncated, char_count, disabled, coverage_start, coverage_end }
--   coverage_start/coverage_end are percentages (0-100) when truncated, nil otherwise
function ContextExtractor:getBookText(options)
    options = options or {}
    local max_chars = options.max_chars or self.settings.max_book_text_chars or Constants.EXTRACTION_DEFAULTS.MAX_BOOK_TEXT_CHARS
    local max_pages = options.max_pages or self.settings.max_pdf_pages or Constants.EXTRACTION_DEFAULTS.MAX_PDF_PAGES

    logger.info("ContextExtractor:getBookText called, enable_book_text_extraction=",
               self.settings.enable_book_text_extraction and "true" or "false/nil")

    local result = {
        text = "",
        truncated = false,
        char_count = 0,
        disabled = false,
        coverage_start = nil,  -- Percentage where extracted text starts (when truncated)
        coverage_end = nil,    -- Percentage where extracted text ends (current progress)
    }

    -- Check global gate - if disabled, return empty
    if not self:isBookTextExtractionEnabled() then
        logger.info("ContextExtractor:getBookText - extraction disabled by setting, returning empty")
        result.disabled = true
        return result
    end

    if not self:isAvailable() then
        return result
    end

    local book_text = ""

    -- Get progress BEFORE navigation (EPUB extraction temporarily moves position)
    local saved_progress = self:getReadingProgress()

    if not self.ui.document.info.has_pages then
        -- EPUB/flowing document: use XPointers
        local document = self.ui.document
        local total_pages = document.info.number_of_pages or 0

        if document.hasHiddenFlows and document:hasHiddenFlows() and total_pages > 0 then
            -- Flow-aware path: extract only visible (flow 0) pages
            local success, text = pcall(function()
                local current_xp = document:getXPointer()
                if not current_xp then return "" end
                local current_page = document:getPageFromXPointer(current_xp) or total_pages
                local ranges = ContextExtractor.getVisiblePageRanges(document, 1, current_page)
                return extractVisibleText(document, ranges, total_pages)
            end)
            if success then
                book_text = text
            else
                logger.warn("ContextExtractor: Failed to extract flow-aware EPUB text:", text)
            end
        else
            -- Standard path: extract from beginning to current position
            local success, text = pcall(function()
                local current_xp = self.ui.document:getXPointer()
                if not current_xp then
                    return ""
                end
                -- Jump to beginning to get start position
                self.ui.document:gotoPos(0)
                local start_xp = self.ui.document:getXPointer()
                -- Return to current position
                self.ui.document:gotoXPointer(current_xp)
                -- Extract text between start and current
                return self.ui.document:getTextFromXPointers(start_xp, current_xp) or ""
            end)
            if success then
                book_text = text
            else
                logger.warn("ContextExtractor: Failed to extract EPUB text:", text)
            end
        end
    else
        -- PDF/page-based document: extract page by page
        local success, text = pcall(function()
            local document = self.ui.document
            local current_page = self.ui.view and self.ui.view.state and self.ui.view.state.page or 1
            local start_page = math.max(1, current_page - max_pages)
            local has_hidden = document.hasHiddenFlows and document:hasHiddenFlows()
            local pages = {}

            for page = start_page, current_page do
                -- Skip hidden flow pages
                if has_hidden and document:getPageFlow(page) ~= 0 then
                    -- skip
                else
                local page_text = document:getPageText(page) or ""
                -- Handle complex table structure returned by some PDF handlers
                if type(page_text) == "table" then
                    local words = {}
                    for _, block in ipairs(page_text) do
                        if type(block) == "table" then
                            for i = 1, #block do
                                local span = block[i]
                                if type(span) == "table" and span.word then
                                    table.insert(words, span.word)
                                end
                            end
                        end
                    end
                    page_text = table.concat(words, " ")
                end
                table.insert(pages, page_text)
                end -- if has_hidden skip/else
            end

            return table.concat(pages, "\n")
        end)

        if success then
            book_text = text
        else
            logger.warn("ContextExtractor: Failed to extract PDF text:", text)
        end
    end

    -- Truncate if needed (keep most recent content, add notice with coverage)
    local original_length = #book_text
    if original_length > max_chars then
        -- Use saved_progress (captured before EPUB navigation that can affect position)
        local kept_ratio = max_chars / original_length
        -- coverage_start/end as decimals (0.0-1.0)
        local coverage_start_dec = saved_progress.decimal * (1 - kept_ratio)
        local coverage_end_dec = saved_progress.decimal
        -- Convert to percent for display (avoid 0%-0% for low progress)
        local coverage_start = math.max(0, math.floor(coverage_start_dec * 100))
        local coverage_end = math.max(1, math.ceil(coverage_end_dec * 100)) -- At least 1%

        result.truncated = true
        result.coverage_start = coverage_start
        result.coverage_end = coverage_end

        local notice = string.format(
            "[Book text covers ~%d%%-%d%%. Earlier content truncated due to extraction limit.]",
            coverage_start, coverage_end)
        book_text = notice .. "\n\n" .. book_text:sub(-max_chars)
    end

    result.text = book_text
    result.char_count = #book_text

    return result
end

--- Get book text between two progress positions (for incremental cache updates).
-- Used to extract only the "delta" of new content since a cached position.
-- @param from_progress number Start position as decimal (0.0-1.0)
-- @param to_progress number End position as decimal (0.0-1.0)
-- @param options table { max_chars = 1000000, max_pages = 500 }
-- @return table { text, truncated, char_count, disabled, coverage_start, coverage_end }
--   coverage_start/coverage_end are percentages (0-100) when truncated, nil otherwise
function ContextExtractor:getBookTextRange(from_progress, to_progress, options)
    options = options or {}
    local max_chars = options.max_chars or self.settings.max_book_text_chars or Constants.EXTRACTION_DEFAULTS.MAX_BOOK_TEXT_CHARS
    local max_pages = options.max_pages or self.settings.max_pdf_pages or Constants.EXTRACTION_DEFAULTS.MAX_PDF_PAGES

    logger.info("ContextExtractor:getBookTextRange called, from=", from_progress, "to=", to_progress)

    local result = {
        text = "",
        truncated = false,
        char_count = 0,
        disabled = false,
        coverage_start = nil,  -- Percentage where extracted text starts (when truncated)
        coverage_end = nil,    -- Percentage where extracted text ends
    }

    -- Validate inputs
    if not from_progress or not to_progress or from_progress >= to_progress then
        logger.warn("ContextExtractor:getBookTextRange - invalid range:", from_progress, "to", to_progress)
        return result
    end

    -- Check global gate
    if not self:isBookTextExtractionEnabled() then
        logger.info("ContextExtractor:getBookTextRange - extraction disabled by setting")
        result.disabled = true
        return result
    end

    if not self:isAvailable() then
        return result
    end

    local total_pages = self.ui.document.info and self.ui.document.info.number_of_pages
    if not total_pages or total_pages <= 0 then
        logger.warn("ContextExtractor:getBookTextRange - cannot determine total pages")
        return result
    end

    local book_text = ""

    if not self.ui.document.info.has_pages then
        -- EPUB/flowing document: use XPointers
        local document = self.ui.document
        local from_page = math.max(1, math.floor(from_progress * total_pages))
        local to_page = math.min(total_pages, math.ceil(to_progress * total_pages))

        if document.hasHiddenFlows and document:hasHiddenFlows() then
            -- Flow-aware path: extract only visible (flow 0) pages in range
            local success, text = pcall(function()
                local ranges = ContextExtractor.getVisiblePageRanges(document, from_page, to_page)
                return extractVisibleText(document, ranges, total_pages)
            end)
            if success then
                book_text = text
            else
                logger.warn("ContextExtractor: Failed to extract flow-aware EPUB range text:", text)
            end
        else
            -- Standard path: navigate to get XPointers
            local success, text = pcall(function()
                local current_xp = document:getXPointer()

                document:gotoPage(from_page)
                local start_xp = document:getXPointer()

                document:gotoPage(to_page)
                local end_xp = document:getXPointer()

                if current_xp then
                    document:gotoXPointer(current_xp)
                end

                return document:getTextFromXPointers(start_xp, end_xp) or ""
            end)
            if success then
                book_text = text
            else
                logger.warn("ContextExtractor: Failed to extract EPUB range text:", text)
            end
        end
    else
        -- PDF/page-based document: extract page by page
        local success, text = pcall(function()
            local document = self.ui.document
            -- Calculate page range from progress
            local from_page = math.max(1, math.floor(from_progress * total_pages))
            local to_page = math.min(total_pages, math.ceil(to_progress * total_pages))

            -- Limit the range to max_pages
            if to_page - from_page > max_pages then
                from_page = to_page - max_pages
            end

            local has_hidden = document.hasHiddenFlows and document:hasHiddenFlows()
            local pages = {}
            for page = from_page, to_page do
                -- Skip hidden flow pages
                if not (has_hidden and document:getPageFlow(page) ~= 0) then
                local page_text = document:getPageText(page) or ""
                -- Handle complex table structure
                if type(page_text) == "table" then
                    local words = {}
                    for _, block in ipairs(page_text) do
                        if type(block) == "table" then
                            for i = 1, #block do
                                local span = block[i]
                                if type(span) == "table" and span.word then
                                    table.insert(words, span.word)
                                end
                            end
                        end
                    end
                    page_text = table.concat(words, " ")
                end
                table.insert(pages, page_text)
                end -- if not hidden
            end

            return table.concat(pages, "\n")
        end)

        if success then
            book_text = text
        else
            logger.warn("ContextExtractor: Failed to extract PDF range text:", text)
        end
    end

    -- Truncate if needed (keep most recent content, add notice with coverage)
    local original_length = #book_text
    if original_length > max_chars then
        -- Calculate coverage: we have from_progress to to_progress, but only kept a portion
        local kept_ratio = max_chars / original_length
        local range_size = to_progress - from_progress
        -- Calculate decimals first, then convert with proper rounding
        local coverage_start_dec = from_progress + range_size * (1 - kept_ratio)
        local coverage_start = math.max(0, math.floor(coverage_start_dec * 100))
        local coverage_end = math.max(1, math.ceil(to_progress * 100)) -- At least 1%

        result.truncated = true
        result.coverage_start = coverage_start
        result.coverage_end = coverage_end

        local notice = string.format(
            "[New content covers ~%d%%-%d%%. Earlier portion truncated due to extraction limit.]",
            coverage_start, coverage_end)
        book_text = notice .. "\n\n" .. book_text:sub(-max_chars)
    end

    result.text = book_text
    result.char_count = #book_text

    logger.info("ContextExtractor:getBookTextRange - extracted", result.char_count, "chars")
    return result
end

--- Get full document text (entire document, ignores reading position).
-- Used for short content analysis (papers, articles) where AI should see everything.
-- @param options table { max_chars = 1000000, max_pages = 500 }
-- @return table { text, truncated, char_count, disabled, coverage_start, coverage_end }
function ContextExtractor:getFullDocumentText(options)
    options = options or {}
    local max_chars = options.max_chars or self.settings.max_book_text_chars or Constants.EXTRACTION_DEFAULTS.MAX_BOOK_TEXT_CHARS
    local max_pages = options.max_pages or self.settings.max_pdf_pages or Constants.EXTRACTION_DEFAULTS.MAX_PDF_PAGES

    logger.info("ContextExtractor:getFullDocumentText called")

    local result = {
        text = "",
        truncated = false,
        char_count = 0,
        disabled = false,
        coverage_start = nil,
        coverage_end = nil,
    }

    -- Check global gate
    if not self:isBookTextExtractionEnabled() then
        logger.info("ContextExtractor:getFullDocumentText - extraction disabled")
        result.disabled = true
        return result
    end

    if not self:isAvailable() then
        return result
    end

    local total_pages = self.ui.document.info and self.ui.document.info.number_of_pages
    if not total_pages or total_pages <= 0 then
        return result
    end

    local book_text = ""

    if not self.ui.document.info.has_pages then
        -- EPUB: extract from start to END (not current position)
        local document = self.ui.document

        if document.hasHiddenFlows and document:hasHiddenFlows() and total_pages > 0 then
            -- Flow-aware path: extract only visible (flow 0) pages
            local success, text = pcall(function()
                local ranges = ContextExtractor.getVisiblePageRanges(document, 1, total_pages)
                return extractVisibleText(document, ranges, total_pages)
            end)
            if success then
                book_text = text
            else
                logger.warn("ContextExtractor: Failed to extract flow-aware full EPUB text:", text)
            end
        else
            -- Standard path: navigate to get start/end XPointers
            local success, text = pcall(function()
                local current_xp = document:getXPointer()

                document:gotoPos(0)
                local start_xp = document:getXPointer()

                document:gotoPage(total_pages)
                local end_xp = document:getXPointer()

                if current_xp then
                    document:gotoXPointer(current_xp)
                end

                return document:getTextFromXPointers(start_xp, end_xp) or ""
            end)
            if success then
                book_text = text
            else
                logger.warn("ContextExtractor: Failed to extract full EPUB text:", text)
            end
        end
    else
        -- PDF: extract ALL pages
        local success, text = pcall(function()
            local document = self.ui.document
            local start_page = math.max(1, total_pages - max_pages + 1)
            local has_hidden = document.hasHiddenFlows and document:hasHiddenFlows()
            local pages = {}

            for page = start_page, total_pages do
                -- Skip hidden flow pages
                if not (has_hidden and document:getPageFlow(page) ~= 0) then
                local page_text = document:getPageText(page) or ""
                -- Handle table structure (same as getBookText)
                if type(page_text) == "table" then
                    local words = {}
                    for _idx, block in ipairs(page_text) do
                        if type(block) == "table" then
                            for i = 1, #block do
                                local span = block[i]
                                if type(span) == "table" and span.word then
                                    table.insert(words, span.word)
                                end
                            end
                        end
                    end
                    page_text = table.concat(words, " ")
                end
                table.insert(pages, page_text)
                end -- if not hidden
            end

            return table.concat(pages, "\n")
        end)

        if success then
            book_text = text
        else
            logger.warn("ContextExtractor: Failed to extract full PDF text:", text)
        end
    end

    -- Truncate if needed (keep end content, same pattern as getBookText)
    local original_length = #book_text
    if original_length > max_chars then
        local kept_ratio = max_chars / original_length
        -- For full document: coverage is of entire document (0% to 100%)
        local coverage_start_dec = 1.0 * (1 - kept_ratio)
        local coverage_start = math.max(0, math.floor(coverage_start_dec * 100))
        local coverage_end = 100

        result.truncated = true
        result.coverage_start = coverage_start
        result.coverage_end = coverage_end

        local notice = string.format(
            "[Document text covers ~%d%%-%d%%. Earlier content truncated due to extraction limit.]",
            coverage_start, coverage_end)
        book_text = notice .. "\n\n" .. book_text:sub(-max_chars)
    end

    result.text = book_text
    result.char_count = #book_text

    logger.info("ContextExtractor:getFullDocumentText - extracted", result.char_count, "chars")
    return result
end

--- Get highlights from the document (text only, no notes).
-- @param options table { max_count = 100, include_chapter = true }
-- @return table { formatted = "...", count = number, items = array }
function ContextExtractor:getHighlights(options)
    options = options or {}
    local max_count = options.max_count or 100
    local include_chapter = options.include_chapter ~= false

    logger.info("ContextExtractor:getHighlights called")

    local result = {
        formatted = "",
        count = 0,
        items = {},
    }

    if not self:isAvailable() then
        logger.info("ContextExtractor:getHighlights - not available (no document)")
        return result
    end

    -- Access annotations from the annotation module
    if not self.ui.annotation or not self.ui.annotation.annotations then
        logger.info("ContextExtractor:getHighlights - no annotation module or no annotations")
        return result
    end
    logger.info("ContextExtractor:getHighlights - found", #self.ui.annotation.annotations, "annotations")

    local lines = {}
    local count = 0

    for _, annotation in ipairs(self.ui.annotation.annotations) do
        if count >= max_count then
            break
        end

        if annotation.text and annotation.text ~= "" then
            count = count + 1

            local item = {
                text = annotation.text,
                chapter = annotation.chapter,
                pageno = annotation.pageno,
            }
            table.insert(result.items, item)

            -- Format the highlight
            local line = '- "' .. annotation.text .. '"'
            if include_chapter and annotation.chapter then
                line = line .. " (Chapter: " .. annotation.chapter .. ")"
            elseif annotation.pageno then
                line = line .. " (Page " .. annotation.pageno .. ")"
            end
            table.insert(lines, line)
        end
    end

    result.formatted = table.concat(lines, "\n")
    result.count = count

    return result
end

--- Get annotations (highlights with user notes attached).
-- @param options table { max_count = 100, include_chapter = true }
-- @return table { formatted = "...", count = number, items = array }
function ContextExtractor:getAnnotations(options)
    options = options or {}
    local max_count = options.max_count or 100
    local include_chapter = options.include_chapter ~= false

    local result = {
        formatted = "",
        count = 0,
        items = {},
    }

    if not self:isAvailable() then
        return result
    end

    if not self.ui.annotation or not self.ui.annotation.annotations then
        return result
    end

    local lines = {}
    local count = 0

    for _, annotation in ipairs(self.ui.annotation.annotations) do
        if count >= max_count then
            break
        end

        if annotation.text and annotation.text ~= "" then
            count = count + 1

            local item = {
                text = annotation.text,
                note = annotation.note,
                chapter = annotation.chapter,
                pageno = annotation.pageno,
            }
            table.insert(result.items, item)

            -- Format with note if available
            local line = '- "' .. annotation.text .. '"'
            if annotation.note and annotation.note ~= "" then
                line = line .. "\n  [Note: " .. annotation.note .. "]"
            end
            if include_chapter and annotation.chapter then
                line = line .. "\n  (Chapter: " .. annotation.chapter .. ")"
            elseif annotation.pageno then
                line = line .. "\n  (Page " .. annotation.pageno .. ")"
            end
            table.insert(lines, line)
        end
    end

    result.formatted = table.concat(lines, "\n")
    result.count = count

    return result
end

--- Get reading statistics.
-- @return table { chapters_read, chapter_title, time_since_last_read, last_read_timestamp }
function ContextExtractor:getReadingStats()
    local result = {
        chapters_read = "0",
        chapter_title = "(Chapter unavailable)",
        time_since_last_read = "Recently",
        last_read_timestamp = nil,
    }

    if not self:isAvailable() then
        return result
    end

    -- Get current chapter title from TOC
    local success_chapter, chapter_info = pcall(function()
        if self.ui.toc then
            local current_page
            if self.ui.document.info.has_pages then
                current_page = self.ui.view and self.ui.view.state and self.ui.view.state.page
            else
                local current_xp = self.ui.document:getXPointer()
                if current_xp then
                    current_page = self.ui.document:getPageFromXPointer(current_xp)
                end
            end

            if current_page then
                local title = self.ui.toc:getTocTitleByPage(current_page)
                if title and title ~= "" then
                    return { title = title }
                end
            end
        end
        return nil
    end)

    if success_chapter and chapter_info then
        result.chapter_title = chapter_info.title
    end

    -- Calculate chapters read (approximate from TOC)
    local success_count, chapters = pcall(function()
        if self.ui.toc and self.ui.toc.toc then
            local toc = self.ui.toc.toc
            local current_page
            if self.ui.document.info.has_pages then
                current_page = self.ui.view and self.ui.view.state and self.ui.view.state.page or 1
            else
                local current_xp = self.ui.document:getXPointer()
                current_page = current_xp and self.ui.document:getPageFromXPointer(current_xp) or 1
            end

            local count = 0
            for _, entry in ipairs(toc) do
                if entry.page and entry.page <= current_page then
                    count = count + 1
                end
            end
            return count
        end
        return 0
    end)

    if success_count then
        result.chapters_read = tostring(chapters)
    end

    -- Get time since last read from file access time
    local success_time, time_info = pcall(function()
        if self.ui.document and self.ui.document.file then
            local attr = lfs.attributes(self.ui.document.file)
            if attr and attr.access then
                local now = os.time()
                local diff_seconds = now - attr.access
                result.last_read_timestamp = attr.access

                -- Format human-readable duration
                if diff_seconds < 60 then
                    return "Just now"
                elseif diff_seconds < 3600 then
                    local minutes = math.floor(diff_seconds / 60)
                    return minutes == 1 and "1 minute ago" or (minutes .. " minutes ago")
                elseif diff_seconds < 86400 then
                    local hours = math.floor(diff_seconds / 3600)
                    return hours == 1 and "1 hour ago" or (hours .. " hours ago")
                else
                    local days = math.floor(diff_seconds / 86400)
                    return days == 1 and "1 day ago" or (days .. " days ago")
                end
            end
        end
        return "Recently"
    end)

    if success_time then
        result.time_since_last_read = time_info
    end

    return result
end

--- Extract all context data for an action.
-- =============================================================================
-- Document Cache Extraction
-- Read cached content from previous X-Ray or Summary runs
-- =============================================================================

--- Get cached X-Ray (partial document analysis to reading position).
-- @return table { text, progress, progress_formatted, used_annotations }
--   used_annotations: Whether annotations were included when building this cache.
--   Use this to determine if annotation permission is required to read the cache.
function ContextExtractor:getXrayCache()
    local result = { text = "", progress = nil, progress_formatted = nil, used_annotations = nil, used_book_text = nil }

    if not self:isAvailable() or not self.ui.document or not self.ui.document.file then
        return result
    end

    local ActionCache = require("koassistant_action_cache")
    local entry = ActionCache.getXrayCache(self.ui.document.file)

    if entry then
        result.text = entry.result or ""
        result.progress = entry.progress_decimal
        result.used_annotations = entry.used_annotations
        result.used_book_text = entry.used_book_text
        if entry.progress_decimal then
            result.progress_formatted = tostring(math.floor(entry.progress_decimal * 100 + 0.5)) .. "%"
        end
    end

    return result
end

--- Get cached document analysis (full document deep analysis).
-- @return table { text, used_book_text }
function ContextExtractor:getAnalyzeCache()
    local result = { text = "", used_book_text = nil }

    if not self:isAvailable() or not self.ui.document or not self.ui.document.file then
        return result
    end

    local ActionCache = require("koassistant_action_cache")
    local entry = ActionCache.getAnalyzeCache(self.ui.document.file)

    if entry then
        result.text = entry.result or ""
        result.used_book_text = entry.used_book_text
    end

    return result
end

--- Get cached document summary (full document summary).
-- @return table { text, used_book_text }
function ContextExtractor:getSummaryCache()
    local result = { text = "", used_book_text = nil }

    if not self:isAvailable() or not self.ui.document or not self.ui.document.file then
        return result
    end

    local ActionCache = require("koassistant_action_cache")
    local entry = ActionCache.getSummaryCache(self.ui.document.file)

    if entry then
        result.text = entry.result or ""
        result.used_book_text = entry.used_book_text
    end

    return result
end

--- Get notebook content for the current document.
-- @return table with notebook content { content = string }
function ContextExtractor:getNotebookContent()
    local result = { content = "" }

    if not self.ui or not self.ui.document or not self.ui.document.file then
        return result
    end

    local Notebook = require("koassistant_notebook")
    local content = Notebook.read(self.ui.document.file)
    if content and content ~= "" then
        result.content = content
    end

    return result
end

-- =============================================================================
-- Unified Extraction for Actions
-- =============================================================================

-- Data extraction respects privacy settings (enable_*_sharing).
-- Trusted providers bypass privacy settings entirely.
-- When a data type is disabled, returns empty string (section placeholders handle gracefully).
-- Book text extraction also requires the use_book_text flag (because it's slow/expensive).
-- @param action table with optional use_book_text flag
-- @return table with all available data
function ContextExtractor:extractForAction(action)
    action = action or {}
    local data = {}

    -- Check if current provider is trusted (bypasses all privacy settings)
    local provider_trusted = self:isProviderTrusted()

    -- Reading progress - check privacy setting (default: enabled)
    if provider_trusted or self.settings.enable_progress_sharing ~= false then
        local progress = self:getReadingProgress()
        data.reading_progress = progress.formatted
        data.progress_decimal = tostring(progress.decimal)
        data.progress_page = progress.current_page
    else
        data.reading_progress = ""
        data.progress_decimal = ""
    end

    -- Highlights - check both global setting AND per-action flag (default: disabled)
    -- Double-gate: user must enable sharing globally AND action must request it
    -- Annotations implies highlights: enable_annotations_sharing grants highlight access too
    local highlights_allowed = provider_trusted
        or self.settings.enable_highlights_sharing == true
        or self.settings.enable_annotations_sharing == true
    if highlights_allowed and action.use_highlights then
        data.highlights = self:getHighlights().formatted
    else
        data.highlights = ""
    end

    -- Annotations - stricter gate: only annotations setting (includes highlight text + user notes)
    local annotations_allowed = provider_trusted
        or self.settings.enable_annotations_sharing == true
    if annotations_allowed and action.use_annotations then
        data.annotations = self:getAnnotations().formatted
    else
        data.annotations = ""
    end

    -- Notes: annotations preferred, highlights fallback
    -- Used by {notes_section} placeholder for actions where user notes are core data
    if action.use_notes then
        if annotations_allowed then
            local ann = self:getAnnotations()
            data.notes = ann.formatted or ""
            data._notes_is_annotations = true
        elseif highlights_allowed then
            -- Annotations not allowed, fall back to highlights only
            data.notes = self:getHighlights().formatted or ""
            data._notes_is_annotations = false
        else
            data.notes = ""
        end
    end

    -- Reading stats - check privacy setting (default: enabled)
    if provider_trusted or self.settings.enable_stats_sharing ~= false then
        local stats = self:getReadingStats()
        data.chapter_title = stats.chapter_title
        data.chapters_read = stats.chapters_read
        data.time_since_last_read = stats.time_since_last_read
    else
        data.chapter_title = ""
        data.chapters_read = ""
        data.time_since_last_read = ""
    end

    -- Text extraction: flag is permission gate, placeholders trigger extraction
    -- Flag "use_book_text" renamed to "Allow text extraction" in UI
    -- Also gated by enable_book_text_extraction setting (checked in extraction methods)
    if action.use_book_text then
        local prompt = action.prompt or ""
        local options = {}
        if action.max_book_text_chars then
            options.max_chars = action.max_book_text_chars
        end

        -- {book_text} / {book_text_section} → extract to current position
        if prompt:find("{book_text", 1, true) then
            local book_text_result = self:getBookText(options)
            data.book_text = book_text_result.text
            -- Pass truncation metadata for UI notifications
            if book_text_result.truncated then
                data.book_text_truncated = true
                data.book_text_coverage_start = book_text_result.coverage_start
                data.book_text_coverage_end = book_text_result.coverage_end
            end
        end

        -- {full_document} / {full_document_section} → extract entire document
        if prompt:find("{full_document", 1, true) then
            local full_doc_result = self:getFullDocumentText(options)
            data.full_document = full_doc_result.text
            -- Pass truncation metadata for UI notifications
            if full_doc_result.truncated then
                data.full_document_truncated = true
                data.full_document_coverage_start = full_doc_result.coverage_start
                data.full_document_coverage_end = full_doc_result.coverage_end
            end
        end
    end

    -- Document cache extraction: dynamic permission based on what each cache actually contains
    -- If cache was built without text extraction (used_book_text=false), no text extraction permission needed
    -- If cache was built with text extraction (used_book_text=true or nil/legacy), require text extraction permission
    -- Trusted providers bypass the text extraction setting (consistent with book text extraction)
    local text_extraction_allowed = provider_trusted or self:isBookTextExtractionEnabled()

    -- {xray_cache} / {xray_cache_section} → cached X-Ray
    if action.use_xray_cache then
        local xray = self:getXrayCache()
        -- Dynamic text extraction gate: only require if cache used text (nil/legacy = requires)
        local requires_text = xray.used_book_text ~= false
        local text_ok = not requires_text or text_extraction_allowed
        -- Dynamic highlight gate: only require if cache used highlights
        -- Legacy compat: old caches have used_annotations but no used_highlights field
        local requires_highlights = xray.used_highlights == true
            or (xray.used_highlights == nil and xray.used_annotations == true)
        local highlights_ok = not requires_highlights
            or (highlights_allowed and action.use_highlights)
        -- Dynamic annotation gate: only for NEW caches that explicitly tracked annotations
        -- (old caches used used_annotations to mean highlights, handled above)
        local requires_annotations = xray.used_annotations == true
            and xray.used_highlights ~= nil
        local annotations_ok = not requires_annotations
            or (annotations_allowed and action.use_annotations)
        if text_ok and highlights_ok and annotations_ok then
            data.xray_cache = xray.text
            data.xray_cache_progress = xray.progress_formatted
        end
    end

    -- {analyze_cache} / {analyze_cache_section} → cached document analysis
    if action.use_analyze_cache then
        local analyze = self:getAnalyzeCache()
        local requires_text = analyze.used_book_text ~= false
        if not requires_text or text_extraction_allowed then
            data.analyze_cache = analyze.text
        end
    end

    -- {summary_cache} / {summary_cache_section} → cached document summary
    if action.use_summary_cache then
        local summary = self:getSummaryCache()
        local requires_text = summary.used_book_text ~= false
        if not requires_text or text_extraction_allowed then
            data.summary_cache = summary.text
        end
    end

    -- Notebook content extraction: double-gated like other sensitive data
    -- Requires both use_notebook flag AND enable_notebook_sharing global setting
    -- Trusted providers bypass the global setting
    local notebook_allowed = provider_trusted or self.settings.enable_notebook_sharing == true
    if action.use_notebook and notebook_allowed then
        local notebook = self:getNotebookContent()
        data.notebook_content = notebook.content
    elseif action.use_notebook and not notebook_allowed then
        -- Explicitly set empty when gated off (for section placeholder to disappear)
        data.notebook_content = ""
    end

    -- Track unavailable data: when action requested data but it wasn't provided
    -- This helps users understand when AI relied on training data vs actual book content
    -- Two cases: permission denied (setting disabled) OR data empty (no highlights, etc.)
    local unavailable = {}

    -- Book text: check if requested but not available
    if action.use_book_text then
        local book_text_enabled = provider_trusted or self:isBookTextExtractionEnabled()
        if not book_text_enabled then
            -- Permission denied
            table.insert(unavailable, "book text (extraction disabled)")
        elseif (not data.book_text or data.book_text == "") and
               (not data.full_document or data.full_document == "") then
            -- Permission granted but no text extracted (could be PDF without text layer, etc.)
            -- Only flag if action likely expected text (has placeholder in prompt)
            local prompt = action.prompt or ""
            if prompt:find("{book_text", 1, true) or prompt:find("{full_document", 1, true) then
                table.insert(unavailable, "book text (none extracted)")
            end
        end
    end

    -- Highlights: check if requested but not available
    if action.use_highlights then
        if not highlights_allowed then
            table.insert(unavailable, "highlights (sharing disabled)")
        elseif not data.highlights or data.highlights == "" then
            table.insert(unavailable, "highlights (none found)")
        end
    end

    -- Annotations: check if requested but not available
    if action.use_annotations then
        if not annotations_allowed then
            table.insert(unavailable, "annotations (sharing disabled)")
        elseif not data.annotations or data.annotations == "" then
            table.insert(unavailable, "annotations (none found)")
        end
    end

    -- Notes: check if requested but degraded or unavailable
    if action.use_notes then
        if not highlights_allowed and not annotations_allowed then
            table.insert(unavailable, "notes (sharing disabled)")
        elseif not annotations_allowed and highlights_allowed then
            -- Degraded: using highlights instead of full annotations
            if data.notes and data.notes ~= "" then
                table.insert(unavailable, "annotations (using highlights only)")
            else
                table.insert(unavailable, "highlights (none found)")
            end
        elseif annotations_allowed then
            if not data.notes or data.notes == "" then
                table.insert(unavailable, "annotations (none found)")
            end
        end
    end

    -- Notebook: check if requested but not available
    if action.use_notebook then
        if not notebook_allowed then
            -- Permission denied
            table.insert(unavailable, "notebook (sharing disabled)")
        elseif not data.notebook_content or data.notebook_content == "" then
            -- Permission granted but notebook is empty
            table.insert(unavailable, "notebook (empty)")
        end
    end

    -- Store unavailable data list for display in chat
    if #unavailable > 0 then
        data._unavailable_data = unavailable
    end

    return data
end

return ContextExtractor
