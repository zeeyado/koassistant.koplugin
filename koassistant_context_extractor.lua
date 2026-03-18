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
    -- document_path: explicit path for sidecar access when ui.document is nil (file browser)
    instance.document_path = settings and settings.document_path or nil
    return instance
end

--- Check if extraction is available (document is open).
-- @return boolean
function ContextExtractor:isAvailable()
    return self.ui and self.ui.document ~= nil
end

--- Check if sidecar data is available (document_path set, for file browser context).
-- @return boolean
function ContextExtractor:hasSidecarAccess()
    return self.document_path ~= nil
end

--- Get the effective document path (open book or explicit path).
-- @return string|nil
function ContextExtractor:getDocumentPath()
    if self.ui and self.ui.document and self.ui.document.file then
        return self.ui.document.file
    end
    return self.document_path
end

-- =============================================================================
-- Sidecar Readers (static) — read per-book data from DocSettings on disk
-- =============================================================================

--- Read annotations array from a book's sidecar file on disk.
-- Works for any book, open or not. Returns the raw annotations array.
-- @param document_path string Full path to the document file
-- @return table Array of annotation tables (may be empty)
function ContextExtractor.readSidecarAnnotations(document_path)
    if not document_path then return {} end
    local DocSettings = require("docsettings")
    local ok, doc_settings = pcall(DocSettings.open, DocSettings, document_path)
    if not ok or not doc_settings then return {} end
    return doc_settings:readSetting("annotations") or {}
end

--- Read notebook content from a book's sidecar file on disk.
-- @param document_path string Full path to the document file
-- @return string Notebook markdown content (may be empty)
function ContextExtractor.readSidecarNotebook(document_path)
    if not document_path then return "" end
    local Notebook = require("koassistant_notebook")
    return Notebook.read(document_path) or ""
end

--- Read reading progress from a book's sidecar file on disk.
-- @param document_path string Full path to the document file
-- @return table { decimal = number, formatted = string }
function ContextExtractor.readSidecarProgress(document_path)
    if not document_path then return { decimal = 0, formatted = "" } end
    local DocSettings = require("docsettings")
    local ok, doc_settings = pcall(DocSettings.open, DocSettings, document_path)
    if not ok or not doc_settings then return { decimal = 0, formatted = "" } end
    local percent = doc_settings:readSetting("percent_finished") or 0
    local pct = math.floor(percent * 100 + 0.5)
    return {
        decimal = percent,
        formatted = pct .. "%",
    }
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
        -- Sidecar fallback: read stored progress from disk
        local doc_path = self:getDocumentPath()
        if doc_path then
            local sidecar = ContextExtractor.readSidecarProgress(doc_path)
            result.decimal = sidecar.decimal
            result.percent = math.floor(sidecar.decimal * 100 + 0.5)
            result.formatted = sidecar.formatted
        end
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

--- Get text for a specific page range (used for Section X-Ray extraction).
-- Extracts text bounded to [start_page, end_page], respecting hidden flows.
-- @param start_page number Start page (inclusive)
-- @param end_page number End page (inclusive)
-- @param options table { max_chars = 1000000 }
-- @return table { text, truncated, char_count, disabled }
function ContextExtractor:getPageRangeText(start_page, end_page, options)
    options = options or {}
    local max_chars = options.max_chars or self.settings.max_book_text_chars or Constants.EXTRACTION_DEFAULTS.MAX_BOOK_TEXT_CHARS

    logger.info("ContextExtractor:getPageRangeText called, pages", start_page, "-", end_page)

    local result = {
        text = "",
        truncated = false,
        char_count = 0,
        disabled = false,
    }

    if not self:isBookTextExtractionEnabled() then
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

    -- Clamp to valid range
    start_page = math.max(1, math.min(start_page, total_pages))
    end_page = math.max(start_page, math.min(end_page, total_pages))

    local book_text = ""

    if not self.ui.document.info.has_pages then
        -- EPUB: extract using XPointers for the page range
        local document = self.ui.document

        if document.hasHiddenFlows and document:hasHiddenFlows() then
            -- Flow-aware: only visible pages within range
            local success, text = pcall(function()
                local ranges = ContextExtractor.getVisiblePageRanges(document, start_page, end_page)
                return extractVisibleText(document, ranges, total_pages)
            end)
            if success then
                book_text = text
            else
                logger.warn("ContextExtractor: Failed flow-aware page range extraction:", text)
            end
        else
            -- Standard: XPointer-based range extraction
            local success, text = pcall(function()
                local start_xp = document:getPageXPointer(start_page)
                local end_xp = document:getPageXPointer(math.min(end_page + 1, total_pages))
                if start_xp and end_xp then
                    return document:getTextFromXPointers(start_xp, end_xp) or ""
                end
                return ""
            end)
            if success then
                book_text = text
            else
                logger.warn("ContextExtractor: Failed page range EPUB extraction:", text)
            end
        end
    else
        -- PDF: extract specified page range
        local success, text = pcall(function()
            local document = self.ui.document
            local has_hidden = document.hasHiddenFlows and document:hasHiddenFlows()
            local pages = {}

            for page = start_page, end_page do
                if not (has_hidden and document:getPageFlow(page) ~= 0) then
                    local page_text = document:getPageText(page) or ""
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
                end
            end

            return table.concat(pages, "\n")
        end)

        if success then
            book_text = text
        else
            logger.warn("ContextExtractor: Failed page range PDF extraction:", text)
        end
    end

    -- Truncate if needed (keep end content)
    if #book_text > max_chars then
        result.truncated = true
        local notice = string.format(
            "[Section text truncated due to extraction limit. Showing last %d characters.]",
            max_chars)
        book_text = notice .. "\n\n" .. book_text:sub(-max_chars)
    end

    result.text = book_text
    result.char_count = #book_text

    logger.info("ContextExtractor:getPageRangeText - extracted", result.char_count, "chars from pages", start_page, "-", end_page)
    return result
end

--- Get text of the current visible page.
-- Uses same extraction approach as translateCurrentPage():
--   EPUB/CRE: screen coordinates (getTextFromPositions) for exact visible content
--   PDF/DjVu: getTextBoxes with line structure, getTextFromPositions fallback
-- Exempt from text extraction gating (single page is minimal data).
-- @return table { text, char_count }
function ContextExtractor:getVisiblePageText()
    local result = {
        text = "",
        char_count = 0,
    }

    if not self:isAvailable() then
        return result
    end

    local document = self.ui.document
    local page_text = nil

    -- Detect document type: CRE (EPUB) vs PDF/DjVu
    local is_cre_document = document.getXPointer ~= nil

    if is_cre_document then
        -- EPUB/CRE: use screen positions for exact visible content
        local view_dimen = self.ui.view and self.ui.view.dimen
        if view_dimen then
            local pos0 = { x = 0, y = 0 }
            local pos1 = { x = view_dimen.w, y = view_dimen.h }
            local success, pos_result = pcall(document.getTextFromPositions, document, pos0, pos1, true)
            if success and pos_result and pos_result.text and pos_result.text ~= "" then
                page_text = pos_result.text
            end
        end

        -- Fallback: try getTextFromXPointer
        if (not page_text or page_text == "") and document.getTextFromXPointer then
            local xp = document:getXPointer()
            if xp then
                local success, text = pcall(document.getTextFromXPointer, document, xp)
                if success and text and text ~= "" then
                    page_text = text
                end
            end
        end
    else
        -- PDF/DjVu: use getTextBoxes for structured line extraction
        local current_page = self.ui.view and self.ui.view.state and self.ui.view.state.page or 1

        local success, text_boxes = pcall(document.getTextBoxes, document, current_page)
        if success and text_boxes and #text_boxes > 0 then
            local lines = {}
            for _line_idx, line in ipairs(text_boxes) do
                local words = {}
                for _word_idx, word_box in ipairs(line) do
                    if word_box.word then
                        table.insert(words, word_box.word)
                    end
                end
                if #words > 0 then
                    table.insert(lines, table.concat(words, " "))
                end
            end
            if #lines > 0 then
                page_text = table.concat(lines, "\n")
            end

            -- Fallback: try getTextFromPositions with text box bounds
            if (not page_text or page_text == "") then
                local first_line = text_boxes[1]
                local last_line = text_boxes[#text_boxes]
                if first_line and #first_line > 0 and last_line and #last_line > 0 then
                    local first_word = first_line[1]
                    local last_word = last_line[#last_line]
                    if first_word and last_word then
                        local pos0 = { x = first_word.x0 or 0, y = first_word.y0 or 0, page = current_page }
                        local pos1 = { x = last_word.x1 or 0, y = last_word.y1 or 0, page = current_page }
                        local ok, pos_result = pcall(document.getTextFromPositions, document, pos0, pos1)
                        if ok and pos_result and pos_result.text then
                            page_text = pos_result.text
                        end
                    end
                end
            end
        end
    end

    page_text = page_text or ""
    result.text = page_text
    result.char_count = #page_text

    logger.info("ContextExtractor:getVisiblePageText - extracted", result.char_count, "chars")
    return result
end

--- Format a raw annotations array into highlights (text only, no notes).
-- @param annotations table Array of annotation tables from ui.annotation or sidecar
-- @param options table { max_count = 100, include_chapter = true }
-- @return table { formatted = "...", count = number, items = array }
function ContextExtractor.formatHighlights(annotations, options)
    options = options or {}
    local max_count = options.max_count or 100
    local include_chapter = options.include_chapter ~= false

    local result = { formatted = "", count = 0, items = {} }
    local lines = {}
    local count = 0

    for _, annotation in ipairs(annotations) do
        if count >= max_count then break end
        if annotation.text and annotation.text ~= "" then
            count = count + 1
            table.insert(result.items, {
                text = annotation.text,
                chapter = annotation.chapter,
                pageno = annotation.pageno,
            })
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

--- Get highlights from the document (text only, no notes).
-- Falls back to sidecar when no open book but document_path is set.
-- @param options table { max_count = 100, include_chapter = true }
-- @return table { formatted = "...", count = number, items = array }
function ContextExtractor:getHighlights(options)
    logger.info("ContextExtractor:getHighlights called")

    -- Open book: read from annotation module
    if self:isAvailable() and self.ui.annotation and self.ui.annotation.annotations then
        logger.info("ContextExtractor:getHighlights - found", #self.ui.annotation.annotations, "annotations")
        return ContextExtractor.formatHighlights(self.ui.annotation.annotations, options)
    end

    -- Sidecar fallback: read from DocSettings on disk
    local doc_path = self:getDocumentPath()
    if doc_path then
        logger.info("ContextExtractor:getHighlights - sidecar fallback for", doc_path)
        local annotations = ContextExtractor.readSidecarAnnotations(doc_path)
        return ContextExtractor.formatHighlights(annotations, options)
    end

    logger.info("ContextExtractor:getHighlights - not available (no document or path)")
    return { formatted = "", count = 0, items = {} }
end

--- Format a raw annotations array into annotations (highlights with user notes).
-- @param annotations table Array of annotation tables from ui.annotation or sidecar
-- @param options table { max_count = 100, include_chapter = true }
-- @return table { formatted = "...", count = number, items = array }
function ContextExtractor.formatAnnotations(annotations, options)
    options = options or {}
    local max_count = options.max_count or 100
    local include_chapter = options.include_chapter ~= false

    local result = { formatted = "", count = 0, items = {} }
    local lines = {}
    local count = 0

    for _, annotation in ipairs(annotations) do
        if count >= max_count then break end
        if annotation.text and annotation.text ~= "" then
            count = count + 1
            table.insert(result.items, {
                text = annotation.text,
                note = annotation.note,
                chapter = annotation.chapter,
                pageno = annotation.pageno,
            })
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

--- Get annotations (highlights with user notes attached).
-- Falls back to sidecar when no open book but document_path is set.
-- @param options table { max_count = 100, include_chapter = true }
-- @return table { formatted = "...", count = number, items = array }
function ContextExtractor:getAnnotations(options)
    -- Open book: read from annotation module
    if self:isAvailable() and self.ui.annotation and self.ui.annotation.annotations then
        return ContextExtractor.formatAnnotations(self.ui.annotation.annotations, options)
    end

    -- Sidecar fallback: read from DocSettings on disk
    local doc_path = self:getDocumentPath()
    if doc_path then
        local annotations = ContextExtractor.readSidecarAnnotations(doc_path)
        return ContextExtractor.formatAnnotations(annotations, options)
    end

    return { formatted = "", count = 0, items = {} }
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
    local result = { text = "", progress = nil, progress_formatted = nil, used_highlights = nil, used_annotations = nil, used_book_text = nil }

    local doc_path = self:getDocumentPath()
    if not doc_path then return result end

    local ActionCache = require("koassistant_action_cache")
    local entry = ActionCache.getXrayCache(doc_path)

    if entry then
        result.text = entry.result or ""
        result.progress = entry.progress_decimal
        result.used_highlights = entry.used_highlights
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

    local doc_path = self:getDocumentPath()
    if not doc_path then return result end

    local ActionCache = require("koassistant_action_cache")
    local entry = ActionCache.getAnalyzeCache(doc_path)

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

    local doc_path = self:getDocumentPath()
    if not doc_path then return result end

    local ActionCache = require("koassistant_action_cache")
    local entry = ActionCache.getSummaryCache(doc_path)

    if entry then
        result.text = entry.result or ""
        result.used_book_text = entry.used_book_text
    end

    return result
end

--- Get notebook content for the current document.
-- Falls back to sidecar when no open book but document_path is set.
-- @return table with notebook content { content = string }
function ContextExtractor:getNotebookContent()
    local result = { content = "" }

    local doc_path = self:getDocumentPath()
    if not doc_path then return result end

    local Notebook = require("koassistant_notebook")
    local content = Notebook.read(doc_path)
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

    -- Annotations: full annotations preferred, degrade to highlights-only when either gate
    -- blocks annotations. Two fallback paths:
    --   1. Per-action gate: use_annotations OFF but use_highlights ON → degrade to highlights
    --   2. Global gate: enable_annotations_sharing OFF but enable_highlights_sharing ON → degrade
    -- Tracks degradation state for adaptive labels in {annotations_section}.
    local annotations_allowed = provider_trusted
        or self.settings.enable_annotations_sharing == true
    if action.use_annotations and annotations_allowed then
        -- Both gates pass: full annotations (highlighted text + user notes)
        data.annotations = self:getAnnotations().formatted or ""
        data._annotations_degraded = false
    elseif highlights_allowed and (action.use_highlights or action.use_annotations) then
        -- Annotations blocked at either gate, but highlights available: degrade
        data.annotations = self:getHighlights().formatted or ""
        data._annotations_degraded = true
    else
        data.annotations = ""
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

    -- Page text extraction: exempt from text extraction gating (single page, minimal data)
    -- Triggered by {page_text} / {page_text_section} placeholder in prompt
    local prompt = action.prompt or ""
    if prompt:find("{page_text", 1, true) then
        local page_result = self:getVisiblePageText()
        data.page_text = page_result.text
    end

    -- Text extraction: flag is permission gate, placeholders trigger extraction
    -- Flag "use_book_text" renamed to "Allow text extraction" in UI
    -- Also gated by enable_book_text_extraction setting (checked in extraction methods)
    if action.use_book_text then
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

        -- {full_document} / {full_document_section} / {document_context_section} → extract entire document (or section scope)
        -- {document_context_section} resolves to full_document when source_mode is "full_text"
        if prompt:find("{full_document", 1, true) or prompt:find("{document_context_section}", 1, true) then
            local full_doc_result
            if action._section_scope then
                -- Section scope: extract only the scoped page range
                local scope = action._section_scope
                full_doc_result = self:getPageRangeText(scope.start_page, scope.end_page, options)
            else
                full_doc_result = self:getFullDocumentText(options)
            end
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
    -- When executing a section action with source=summary, find matching section summary
    -- by position (not name) with fallback: exact match > containing match > main summary
    if action.use_summary_cache then
        local summary
        if action._section_scope and self.ui and self.ui.document then
            local ActionCache = require("koassistant_action_cache")
            local file = self.ui.document.file
            local scope = action._section_scope
            local match = ActionCache.findBestSectionForScope(
                file, self.ui.document, ActionCache.SECTION_PREFIXES.summary,
                scope.start_page, scope.end_page)
            if match then
                summary = { text = match.data.result or "", used_book_text = match.data.used_book_text }
            end
        end
        if not summary then
            summary = self:getSummaryCache()
        end
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

    -- Library data extraction: triple-gated
    -- Requires: (1) use_library action flag, (2) enable_library_scanning global setting,
    --           (3) library_scan_folders configured (non-empty)
    -- Trusted providers bypass gate 2 only (NOT gate 3 — folders must always be explicit)
    -- Session scan folders (_session_scan_folders) bypass gates 2+3 — user actively chose them
    local session_scan = self.settings._session_scan_folders
    local has_session_scan = session_scan and #session_scan > 0
    local library_setting_allowed = provider_trusted or self.settings.enable_library_scanning == true
    local library_folders = self.settings.library_scan_folders
    local library_folders_configured = library_folders and #library_folders > 0
    -- Global toggle is absolute gate; session folders only bypass folder configuration requirement
    local library_allowed = library_setting_allowed and (library_folders_configured or has_session_scan)
    if action.use_library and library_allowed then
        local LibraryScanner = require("koassistant_library_scanner")
        -- Use session scan folders if available (already computed as effective set)
        local scan_result
        if has_session_scan then
            local scan_settings = { library_scan_folders = session_scan }
            scan_result = LibraryScanner.scan(scan_settings, self.document_path)
        else
            scan_result = LibraryScanner.scan(self.settings, self.document_path)
        end
        -- Stats enrichment: engagement labels + group placeholders
        -- Gated: enable_stats_sharing (opt-out) + use_reading_stats per-action
        local stats_gated = action.use_reading_stats
            and self.settings.enable_stats_sharing ~= false
        local format_options = {}
        if stats_gated and scan_result and scan_result.books and #scan_result.books > 0 then
            local stats_ok, StatsReader = pcall(require, "koassistant_stats_reader")
            if stats_ok and StatsReader then
                local enriched = StatsReader.enrichBooks(scan_result.books)
                if enriched then
                    for _idx, book in ipairs(scan_result.books) do
                        book.engagement_label = StatsReader.getEngagementLabel(book)
                    end
                    data.stats_groups = StatsReader.buildAllGroups(scan_result.books)
                    format_options.include_engagement = true
                end
            end
        end
        data.library_content = LibraryScanner.format(scan_result, format_options)
    elseif action.use_library and not library_allowed then
        -- Explicitly set empty when gated off (for section placeholder to disappear)
        data.library_content = ""
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

    -- Annotations: check if requested but degraded or unavailable
    if action.use_annotations or action.use_highlights then
        if data._annotations_degraded then
            -- Using highlights instead of full annotations (either gate blocked)
            if data.annotations and data.annotations ~= "" then
                table.insert(unavailable, "annotations (using highlights only)")
            else
                table.insert(unavailable, "highlights (none found)")
            end
        elseif action.use_annotations then
            -- Full annotations were requested
            if not highlights_allowed and not annotations_allowed then
                table.insert(unavailable, "annotations (sharing disabled)")
            elseif not data.annotations or data.annotations == "" then
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

    -- Library: check if requested but not available
    if action.use_library then
        if not library_setting_allowed then
            table.insert(unavailable, "library (scanning disabled)")
        elseif not library_folders_configured then
            table.insert(unavailable, "library (no folders configured)")
        elseif not data.library_content or data.library_content == "" then
            table.insert(unavailable, "library (no books found)")
        end
    end

    -- Summary cache: check if requested but not available
    if action.use_summary_cache then
        if not data.summary_cache or data.summary_cache == "" then
            table.insert(unavailable, "summary cache (not generated)")
        end
    end

    -- Store unavailable data list for display in chat
    if #unavailable > 0 then
        data._unavailable_data = unavailable
    end

    return data
end

return ContextExtractor
