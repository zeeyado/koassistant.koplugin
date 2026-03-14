--[[--
Library Scanner for KOAssistant

Scans configured folders to build a structured library catalog.
Extracts per-book metadata from DocSettings sidecars and enriches
with recency data from ReadHistory.

Three data sources combined:
- File system walk: what books exist on device (base)
- DocSettings: reading state per book (status, progress, doc_props)
- ReadHistory: recency ordering (last_read timestamps)

The scanner extracts maximally — all available metadata for every book.
What gets sent to AI is controlled by the formatter, which accepts
options for scope, depth, and grouping.

@module koassistant_library_scanner
]]

local DocSettings = require("docsettings")
local logger = require("logger")
local lfs = require("libs/libkoreader-lfs")

local LibraryScanner = {}

-- Supported depth levels for formatting
LibraryScanner.DEPTH_BASIC = "basic"       -- title + author only
LibraryScanner.DEPTH_STANDARD = "standard" -- + status, progress
LibraryScanner.DEPTH_FULL = "full"         -- + series, language, folder

-- Default character budget for formatted output
local DEFAULT_BUDGET = 100000

--- Check if a file is a supported document type
--- @param file_path string
--- @return boolean
local function isDocumentFile(file_path)
    local DocumentRegistry = require("document/documentregistry")
    return DocumentRegistry:hasProvider(file_path)
end

--- Extract metadata for a single book from its DocSettings sidecar
--- @param doc_path string The document file path
--- @return table metadata Per-book metadata table
local function extractBookMetadata(doc_path)
    local doc_settings = DocSettings:open(doc_path)
    local doc_props = doc_settings:readSetting("doc_props")

    -- Title: display_title > title > filename
    local title = doc_props and (doc_props.display_title or doc_props.title) or nil
    if not title or title == "" then
        title = doc_path:match("([^/]+)%.[^%.]+$") or doc_path
    end

    -- Author: normalize newline-separated to comma-separated
    local author = doc_props and doc_props.authors or nil
    if author and author:find("\n") then
        author = author:gsub("\n", ", ")
    end

    -- Series
    local series = doc_props and doc_props.series or nil
    if series and series == "" then series = nil end

    -- Language
    local language = doc_props and doc_props.language or nil
    if language and language == "" then language = nil end

    -- Reading status
    local summary = doc_settings:readSetting("summary")
    local raw_status = summary and summary.status or nil

    -- Progress
    local progress = doc_settings:readSetting("percent_finished")

    -- Determine canonical status
    local status
    if raw_status == "complete" then
        status = "complete"
    elseif raw_status == "abandoned" then
        status = "abandoned"
    elseif progress and progress >= 0.75 and not raw_status then
        -- 75%+ with no explicit status treated as complete (same as BookPicker)
        status = "complete"
    elseif progress and progress > 0 then
        status = "reading"
    else
        status = "unread"
    end

    -- Extract folder from path
    local folder = doc_path:match("^(.+)/[^/]+$") or ""

    return {
        file = doc_path,
        title = title,
        author = author,
        status = status,
        progress = progress,
        series = series,
        language = language,
        folder = folder,
        last_read = nil, -- enriched later from ReadHistory
    }
end

--- Build a lookup table of last-read timestamps from ReadHistory
--- @return table Map of file_path → timestamp (os.time value)
local function buildReadHistoryIndex()
    local index = {}
    local ok, ReadHistory = pcall(require, "readhistory")
    if not ok or not ReadHistory then
        return index
    end
    ReadHistory:reload()
    for _idx, entry in ipairs(ReadHistory.hist or {}) do
        if entry.file and entry.time then
            index[entry.file] = entry.time
        end
    end
    return index
end

--- Recursively scan a folder for document files
--- @param folder_path string The folder to scan
--- @param results table Array to append file paths to
--- @param seen table Hash of already-seen paths (dedup across folders)
--- @param exclude_path string|nil Path to exclude (current book)
local function scanFolder(folder_path, results, seen, exclude_path)
    local iter, dir_obj = lfs.dir(folder_path)
    if not iter then
        logger.warn("KOAssistant: LibraryScanner cannot read folder:", folder_path)
        return
    end

    for entry in iter, dir_obj do
        if entry == "." or entry == ".." or entry:sub(1, 1) == "." then
            goto continue
        end

        local full_path = folder_path .. "/" .. entry
        local attr = lfs.attributes(full_path)

        if attr then
            if attr.mode == "directory" then
                scanFolder(full_path, results, seen, exclude_path)
            elseif attr.mode == "file" then
                if not seen[full_path]
                   and full_path ~= exclude_path
                   and isDocumentFile(full_path) then
                    seen[full_path] = true
                    table.insert(results, full_path)
                end
            end
        end

        ::continue::
    end
end

--- Scan all configured folders and return structured library data
--- No fallback: if library_scan_folders is empty/nil, returns empty results.
--- Folders must be explicitly configured by the user.
--- @param settings table Features settings table (for library_scan_folders)
--- @param current_book_path string|nil Path to exclude (current book)
--- @return table Structured result: { books, by_status, by_folder, stats }
function LibraryScanner.scan(settings, current_book_path)
    -- Require explicitly configured folders — no fallback
    local folders = settings and settings.library_scan_folders
    if not folders or #folders == 0 then
        return {
            books = {},
            by_status = { reading = {}, complete = {}, abandoned = {}, unread = {} },
            by_folder = {},
            stats = { total = 0, reading = 0, complete = 0, abandoned = 0, unread = 0 },
        }
    end

    -- Collect all document file paths
    local file_paths = {}
    local seen = {}
    for _idx, folder in ipairs(folders) do
        scanFolder(folder, file_paths, seen, current_book_path)
    end

    -- Build ReadHistory index for recency data
    local history_index = buildReadHistoryIndex()

    -- Extract metadata for each book
    local books = {}
    local by_status = {
        reading = {},
        complete = {},
        abandoned = {},
        unread = {},
    }
    local by_folder = {}
    local stats = {
        total = 0,
        reading = 0,
        complete = 0,
        abandoned = 0,
        unread = 0,
    }

    for _idx, file_path in ipairs(file_paths) do
        local ok, metadata = pcall(extractBookMetadata, file_path)
        if ok and metadata then
            -- Enrich with ReadHistory recency
            metadata.last_read = history_index[file_path]

            table.insert(books, metadata)

            -- Index by status
            local status_group = by_status[metadata.status]
            if status_group then
                table.insert(status_group, metadata)
            end

            -- Index by folder
            if not by_folder[metadata.folder] then
                by_folder[metadata.folder] = {}
            end
            table.insert(by_folder[metadata.folder], metadata)

            -- Update stats
            stats.total = stats.total + 1
            if stats[metadata.status] then
                stats[metadata.status] = stats[metadata.status] + 1
            end
        else
            logger.warn("KOAssistant: LibraryScanner failed to extract metadata for:", file_path)
        end
    end

    -- Sort groups by recency (most recently read first, then alphabetically)
    local function sortByRecencyThenTitle(a, b)
        if a.last_read and b.last_read then
            return a.last_read > b.last_read
        elseif a.last_read then
            return true
        elseif b.last_read then
            return false
        else
            return (a.title or "") < (b.title or "")
        end
    end

    table.sort(by_status.reading, sortByRecencyThenTitle)
    table.sort(by_status.complete, sortByRecencyThenTitle)
    table.sort(by_status.abandoned, sortByRecencyThenTitle)
    table.sort(by_status.unread, function(a, b)
        return (a.title or "") < (b.title or "")
    end)

    return {
        books = books,
        by_status = by_status,
        by_folder = by_folder,
        stats = stats,
    }
end

--- Format a single book entry as a text line
--- @param book table Book metadata
--- @param depth string Depth level (basic/standard/full)
--- @return string
local function formatBookLine(book, depth)
    local parts = {}

    -- Title (always present)
    table.insert(parts, '"' .. (book.title or "Unknown") .. '"')

    -- Author
    if book.author and book.author ~= "" then
        table.insert(parts, "by " .. book.author)
    end

    -- Series (full depth only, or standard if available)
    if depth ~= LibraryScanner.DEPTH_BASIC and book.series then
        table.insert(parts, "(" .. book.series .. " series)")
    end

    -- Progress (standard+ depth, for reading/abandoned only)
    if depth ~= LibraryScanner.DEPTH_BASIC and book.progress and book.progress > 0 then
        if book.status == "reading" or book.status == "abandoned" then
            table.insert(parts, "(" .. math.floor(book.progress * 100) .. "%)")
        end
    end

    -- Language (full depth only)
    if depth == LibraryScanner.DEPTH_FULL and book.language then
        table.insert(parts, "[" .. book.language .. "]")
    end

    return "- " .. table.concat(parts, " ")
end

--- Format a group of books with a section header
--- @param books table Array of book metadata
--- @param header string Section header text
--- @param depth string Depth level
--- @param budget_remaining number Characters remaining in budget
--- @return string formatted Formatted text
--- @return number chars_used Characters used
--- @return number books_shown Number of books included
--- @return number books_total Total books in group
local function formatGroup(books, header, depth, budget_remaining)
    if #books == 0 then
        return "", 0, 0, 0
    end

    local lines = {}
    local header_line = header .. " (" .. #books .. "):"
    table.insert(lines, header_line)

    local chars_used = #header_line + 1 -- +1 for newline
    local books_shown = 0

    for _idx, book in ipairs(books) do
        local line = formatBookLine(book, depth)
        local line_cost = #line + 1 -- +1 for newline

        if chars_used + line_cost > budget_remaining then
            -- Budget exceeded — add truncation notice
            local remaining = #books - books_shown
            if remaining > 0 then
                table.insert(lines, "... and " .. remaining .. " more")
            end
            break
        end

        table.insert(lines, line)
        chars_used = chars_used + line_cost
        books_shown = books_shown + 1
    end

    return table.concat(lines, "\n"), chars_used, books_shown, #books
end

--- Format library data for prompt injection
--- @param scan_result table From scan()
--- @param options table|nil Formatting options
--- @return string Formatted text for placeholder injection
function LibraryScanner.format(scan_result, options)
    options = options or {}

    local depth = options.depth or LibraryScanner.DEPTH_STANDARD
    local budget = options.budget or DEFAULT_BUDGET
    local group_by = options.group_by or "status"
    local filter_statuses = options.statuses -- nil = all
    local filter_folders = options.folders   -- nil = all

    -- Apply folder filter if specified
    local by_status = scan_result.by_status
    if filter_folders then
        -- Rebuild by_status from only the specified folders
        by_status = {
            reading = {},
            complete = {},
            abandoned = {},
            unread = {},
        }
        for _idx, folder in ipairs(filter_folders) do
            local folder_books = scan_result.by_folder[folder]
            if folder_books then
                for _bidx, book in ipairs(folder_books) do
                    local group = by_status[book.status]
                    if group then
                        table.insert(group, book)
                    end
                end
            end
        end
    end

    -- Apply status filter
    local status_order = { "reading", "complete", "abandoned", "unread" }
    local status_headers = {
        reading = "Currently reading",
        complete = "Finished",
        abandoned = "On hold",
        unread = "Unread",
    }

    if filter_statuses then
        local allowed = {}
        for _idx, s in ipairs(filter_statuses) do
            allowed[s] = true
        end
        local filtered_order = {}
        for _idx, s in ipairs(status_order) do
            if allowed[s] then
                table.insert(filtered_order, s)
            end
        end
        status_order = filtered_order
    end

    -- Count total for header
    local total = 0
    for _idx, status in ipairs(status_order) do
        total = total + #(by_status[status] or {})
    end

    if total == 0 then
        return ""
    end

    local sections = {}

    if group_by == "status" then
        -- Summary header
        table.insert(sections, total .. " books:")

        local budget_remaining = budget
        for _idx, status in ipairs(status_order) do
            local group = by_status[status] or {}
            if #group > 0 then
                local header = status_headers[status] or status
                local formatted, chars_used = formatGroup(group, header, depth, budget_remaining)
                if formatted ~= "" then
                    table.insert(sections, formatted)
                    budget_remaining = budget_remaining - chars_used
                    if budget_remaining <= 0 then break end
                end
            end
        end
    elseif group_by == "folder" then
        table.insert(sections, total .. " books:")

        local budget_remaining = budget
        -- Sort folders alphabetically
        local folder_list = {}
        for folder in pairs(scan_result.by_folder) do
            table.insert(folder_list, folder)
        end
        table.sort(folder_list)

        for _idx, folder in ipairs(folder_list) do
            -- Apply folder filter if specified
            if filter_folders then
                local found = false
                for _fidx, f in ipairs(filter_folders) do
                    if f == folder then found = true; break end
                end
                if not found then goto continue_folder end
            end

            local books = scan_result.by_folder[folder]
            if books and #books > 0 then
                -- Use folder basename as header
                local folder_name = folder:match("([^/]+)$") or folder
                local formatted, chars_used = formatGroup(books, folder_name, depth, budget_remaining)
                if formatted ~= "" then
                    table.insert(sections, formatted)
                    budget_remaining = budget_remaining - chars_used
                    if budget_remaining <= 0 then break end
                end
            end

            ::continue_folder::
        end
    else -- "flat"
        table.insert(sections, total .. " books:")

        local budget_remaining = budget
        -- Combine all books, sort by recency then title
        local all_books = {}
        for _idx, status in ipairs(status_order) do
            for _bidx, book in ipairs(by_status[status] or {}) do
                table.insert(all_books, book)
            end
        end
        local formatted, _ = formatGroup(all_books, "", depth, budget_remaining)
        if formatted ~= "" then
            table.insert(sections, formatted)
        end
    end

    return table.concat(sections, "\n\n")
end

return LibraryScanner
