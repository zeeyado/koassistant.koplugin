--[[--
Context extractor for KOAssistant.

This module extracts reading context data from KOReader documents:
- Book text (EPUB via XPointers, PDF via page extraction)
- Highlights and annotations
- Reading progress and statistics
- Chapter information

@module koassistant_context_extractor
]]

local lfs = require("libs/libkoreader-lfs")
local logger = require("logger")

local ContextExtractor = {}
ContextExtractor.__index = ContextExtractor

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

--- Get reading progress as percentage.
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

    -- Try to get percent_finished from doc_settings
    local percent_finished = 0
    if self.ui.doc_settings then
        percent_finished = self.ui.doc_settings:readSetting("percent_finished") or 0
    end

    -- If doc_settings not available, calculate from page position
    if percent_finished == 0 and self.ui.document then
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
            percent_finished = current_page / total_pages
        end
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
-- @param options table { max_chars = 50000, max_pages = 250 }
-- @return table { text = "...", truncated = bool, char_count = number, disabled = bool }
function ContextExtractor:getBookText(options)
    options = options or {}
    local max_chars = options.max_chars or self.settings.max_book_text_chars or 50000
    local max_pages = options.max_pages or self.settings.max_pdf_pages or 250

    logger.info("ContextExtractor:getBookText called, enable_book_text_extraction=",
               self.settings.enable_book_text_extraction and "true" or "false/nil")

    local result = {
        text = "",
        truncated = false,
        char_count = 0,
        disabled = false,
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

    if not self.ui.document.info.has_pages then
        -- EPUB/flowing document: use XPointers
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
    else
        -- PDF/page-based document: extract page by page
        local success, text = pcall(function()
            local current_page = self.ui.view and self.ui.view.state and self.ui.view.state.page or 1
            local start_page = math.max(1, current_page - max_pages)
            local pages = {}

            for page = start_page, current_page do
                local page_text = self.ui.document:getPageText(page) or ""
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
            end

            return table.concat(pages, "\n")
        end)

        if success then
            book_text = text
        else
            logger.warn("ContextExtractor: Failed to extract PDF text:", text)
        end
    end

    -- Truncate if needed (keep most recent content, add notice)
    if #book_text > max_chars then
        book_text = "[Earlier content truncated for length]\n\n" .. book_text:sub(-max_chars)
        result.truncated = true
    end

    result.text = book_text
    result.char_count = #book_text

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
-- Lightweight data (progress, highlights, annotations, stats) is always extracted.
-- Book text extraction requires the use_book_text flag (because it's slow/expensive).
-- @param action table with optional use_book_text flag
-- @return table with all available data
function ContextExtractor:extractForAction(action)
    action = action or {}
    local data = {}

    -- Always extract reading progress (instant)
    local progress = self:getReadingProgress()
    data.reading_progress = progress.formatted
    data.progress_decimal = tostring(progress.decimal)

    -- Always extract highlights (fast - reads from memory)
    local highlights = self:getHighlights()
    data.highlights = highlights.formatted

    -- Always extract annotations (fast - same source as highlights)
    local annotations = self:getAnnotations()
    data.annotations = annotations.formatted

    -- Always extract reading stats (fast - TOC lookup + file timestamp)
    local stats = self:getReadingStats()
    data.chapter_title = stats.chapter_title
    data.chapters_read = stats.chapters_read
    data.time_since_last_read = stats.time_since_last_read

    -- Book text extraction requires explicit flag (slow/expensive operation)
    if action.use_book_text then
        local options = {}
        if action.max_book_text_chars then
            options.max_chars = action.max_book_text_chars
        end
        local book_text = self:getBookText(options)
        data.book_text = book_text.text
    end

    return data
end

return ContextExtractor
