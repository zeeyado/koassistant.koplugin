--- Reading statistics reader for KOAssistant
-- Queries KOReader's statistics.sqlite3 database to compute engagement groups.
-- Raw stats never leave the device — only human-readable group labels are used.
--
-- Two consumers:
-- 1. Library scan formatter: engagement labels in {library} output (gated by enable_advanced_stats + use_advanced_stats)
-- 2. Items presets: cross-referenced with ReadHistory for quick-add (ungated, deferred)
--
-- Groups are the core abstraction: each is a filter (status + stats thresholds) producing a book list.
-- Groups become placeholders ({deep_reads_section}, {stalled_section}, etc.) that actions compose.

local logger = require("koassistant.core.logger")
local lfs = require("libs/libkoreader-lfs")

local StatsReader = {}

-- Engagement group definitions
-- Each group has: id, criteria function, format function for per-book line
-- Criteria takes (book, stats) where book has status/progress from DocSettings,
-- stats has total_read_time/last_open/total_read_pages from DB
StatsReader.GROUPS = {
    {
        id = "deep_reads",
        -- Books completed with significant time investment
        criteria = function(book, stats)
            return book.status == "complete"
                and stats.total_read_time
                and stats.total_read_time > 18000 -- >5 hours
        end,
        format_book = function(book, stats)
            local hours = math.floor(stats.total_read_time / 3600)
            local line = string.format('"%s"', book.title or "Unknown")
            if book.author and book.author ~= "" then
                line = line .. " by " .. book.author
            end
            line = line .. string.format(" (%d hours)", hours)
            return line
        end,
    },
    {
        id = "recently_finished",
        -- Books completed in the last 30 days
        criteria = function(book, stats)
            if book.status ~= "complete" then return false end
            if not stats.last_open then return false end
            local days_ago = (os.time() - stats.last_open) / 86400
            return days_ago <= 30
        end,
        format_book = function(book, stats)
            local days_ago = math.floor((os.time() - stats.last_open) / 86400)
            local line = string.format('"%s"', book.title or "Unknown")
            if book.author and book.author ~= "" then
                line = line .. " by " .. book.author
            end
            if days_ago <= 1 then
                line = line .. " (finished today)"
            elseif days_ago <= 7 then
                line = line .. string.format(" (finished %d days ago)", days_ago)
            else
                local weeks = math.floor(days_ago / 7)
                if weeks == 1 then
                    line = line .. " (finished last week)"
                else
                    line = line .. string.format(" (finished %d weeks ago)", weeks)
                end
            end
            return line
        end,
    },
    {
        id = "stalled",
        -- Started reading (>20% progress) but haven't returned in >30 days, not complete
        criteria = function(book, stats)
            if book.status == "complete" then return false end
            if not book.progress or book.progress < 0.2 then return false end
            if not stats.last_open then return false end
            local days_ago = (os.time() - stats.last_open) / 86400
            return days_ago > 30
        end,
        format_book = function(book, stats)
            local days_ago = math.floor((os.time() - stats.last_open) / 86400)
            local line = string.format('"%s"', book.title or "Unknown")
            if book.author and book.author ~= "" then
                line = line .. " by " .. book.author
            end
            local progress_pct = math.floor((book.progress or 0) * 100)
            if days_ago < 60 then
                line = line .. string.format(" (%d%%, last opened %d days ago)", progress_pct, days_ago)
            else
                local months = math.floor(days_ago / 30)
                line = line .. string.format(" (%d%%, last opened %d months ago)", progress_pct, months)
            end
            return line
        end,
    },
    {
        id = "briefly_started",
        -- Opened but barely read (<30 min total), not complete
        criteria = function(book, stats)
            if book.status == "complete" then return false end
            if not stats.total_read_time then return false end
            if stats.total_read_time <= 0 then return false end
            return stats.total_read_time < 1800 -- <30 minutes
                and stats.total_read_pages and stats.total_read_pages > 0
        end,
        format_book = function(book, stats)
            local minutes = math.floor(stats.total_read_time / 60)
            local line = string.format('"%s"', book.title or "Unknown")
            if book.author and book.author ~= "" then
                line = line .. " by " .. book.author
            end
            if minutes <= 1 then
                line = line .. " (less than a minute)"
            else
                line = line .. string.format(" (%d minutes)", minutes)
            end
            return line
        end,
    },
}

--- Get the path to the statistics database
--- @return string|nil path, or nil if DB doesn't exist
function StatsReader.getDbPath()
    local ok, DataStorage = pcall(require, "datastorage")
    if not ok then return nil end
    local path = DataStorage:getSettingsDir() .. "/statistics.sqlite3"
    local attr = lfs.attributes(path)
    if attr and attr.mode == "file" then
        return path
    end
    return nil
end

--- Check if the statistics database is available
--- @return boolean
function StatsReader.isAvailable()
    return StatsReader.getDbPath() ~= nil
end

--- Load all book stats from the database into a lookup table keyed by md5
--- @return table|nil md5_to_stats lookup, or nil on error
function StatsReader.loadAllStats()
    local db_path = StatsReader.getDbPath()
    if not db_path then return nil end

    local sq3_ok, SQ3 = pcall(require, "lua-ljsqlite3/init")
    if not sq3_ok then
        logger.warn("KOAssistant: StatsReader cannot load lua-ljsqlite3")
        return nil
    end

    local conn_ok, conn = pcall(SQ3.open, db_path, "ro")
    if not conn_ok or not conn then
        logger.warn("KOAssistant: StatsReader cannot open stats DB:", db_path)
        return nil
    end

    local query_ok, result = pcall(conn.exec, conn,
        "SELECT title, authors, md5, total_read_time, total_read_pages, last_open, pages FROM book")
    if not query_ok or not result or not result.md5 then
        pcall(conn.close, conn)
        -- Empty DB or query error — not necessarily an error (fresh install)
        return nil
    end

    local lookup = StatsReader.foldRows(result)

    pcall(conn.close, conn)
    return lookup
end

--- The book table's rows by md5. KOReader keeps one row per book id, and a
--- book opened under two ids (a move, a re-import) has two rows for one
--- md5: the last row read won, so part of its time was lost (the sweep of
--- 2026-11-06). Pure: the rows are folded, the time and pages summed (the
--- pages capped at the book's), last_open the newest, title and authors from
--- the newest row.
--- @param result table the columns as lua-ljsqlite3's exec returns them
--- @return table { [md5] = { title, authors, total_read_time, total_read_pages, last_open, pages } }
function StatsReader.foldRows(result)
    local lookup = {}
    local count = #result.md5
    for i = 1, count do
        local md5 = result.md5[i]
        if md5 and md5 ~= "" then
            local row = {
                title = result.title[i],
                authors = result.authors[i],
                total_read_time = tonumber(result.total_read_time[i]) or 0,
                total_read_pages = tonumber(result.total_read_pages[i]) or 0,
                last_open = tonumber(result.last_open[i]),
                pages = tonumber(result.pages[i]) or 0,
            }
            local have = lookup[md5]
            if not have then
                lookup[md5] = row
            else
                local newer = (row.last_open or 0) >= (have.last_open or 0)
                have.total_read_time = have.total_read_time + row.total_read_time
                have.pages = math.max(have.pages, row.pages)
                have.total_read_pages = math.min(have.total_read_pages + row.total_read_pages,
                    have.pages > 0 and have.pages or math.huge)
                if newer then
                    have.last_open = row.last_open
                    have.title, have.authors = row.title, row.authors
                end
            end
        end
    end
    return lookup
end

--- Total reading time (seconds) spent in a page range for one book, from the stats DB.
--- Reads the `page_stat` VIEW (which rescales recorded time to the book's current pagination),
--- so the page range must be in current pagination. Read-only; all failures return nil so the
--- caller can fail open (don't block on missing/unavailable stats).
--- @param id_book number  integer book id in the stats DB (ReaderStatistics.id_curr_book)
--- @param first_page number
--- @param last_page number
--- @return number|nil  seconds, or nil if unavailable/error
function StatsReader.getReadingTimeInRange(id_book, first_page, last_page)
    if type(id_book) ~= "number" or type(first_page) ~= "number" or type(last_page) ~= "number" then
        return nil
    end
    local db_path = StatsReader.getDbPath()
    if not db_path then return nil end

    local sq3_ok, SQ3 = pcall(require, "lua-ljsqlite3/init")
    if not sq3_ok then return nil end

    local conn_ok, conn = pcall(SQ3.open, db_path, "ro")
    if not conn_ok or not conn then return nil end

    local sql = string.format(
        "SELECT COALESCE(SUM(duration),0) AS secs FROM page_stat WHERE id_book=%d AND page>=%d AND page<=%d",
        math.floor(id_book), math.floor(first_page), math.floor(last_page))
    local query_ok, result = pcall(conn.exec, conn, sql)
    pcall(conn.close, conn)
    if not query_ok or not result or not result.secs then return nil end
    return tonumber(result.secs[1])
end

--- When the statistics database last recorded this book being read, as a Unix time:
--- the newest page view stored for it (every `book` row with this md5, since a book
--- whose title or author was edited has a second row). nil when the database, the
--- book or any stored page view is missing, so the caller sends nothing rather than
--- a guess. KOReader writes page views to the database every 50 page turns and when
--- the book closes or the device sleeps, so inside a session this is the end of the
--- earlier one (or a recent save of this one). Read-only; all failures return nil.
--- @param md5 string  the book's partial_md5_checksum (hex, as the statistics plugin stores it)
--- @return number|nil  seconds since the epoch
function StatsReader.getLastReadTime(md5)
    -- Only hex reaches the SQL text below
    if type(md5) ~= "string" or md5 == "" or md5:find("%X") then return nil end
    local db_path = StatsReader.getDbPath()
    if not db_path then return nil end

    local sq3_ok, SQ3 = pcall(require, "lua-ljsqlite3/init")
    if not sq3_ok then return nil end

    local conn_ok, conn = pcall(SQ3.open, db_path, "ro")
    if not conn_ok or not conn then return nil end

    local sql = string.format(
        "SELECT MAX(start_time) AS last_read FROM page_stat_data "
        .. "WHERE id_book IN (SELECT id FROM book WHERE md5 = '%s')", md5)
    local query_ok, result = pcall(conn.exec, conn, sql)
    pcall(conn.close, conn)
    if not query_ok or not result or not result.last_read then return nil end
    local ts = tonumber(result.last_read[1])
    if not ts or ts <= 0 then return nil end
    return ts
end

--- Compute engagement group for a single book
--- @param book table Book metadata (from scanner: title, author, status, progress, md5)
--- @param stats table Stats data (from DB: total_read_time, last_open, etc.)
--- @return table Array of matching group IDs (a book can match multiple groups)
function StatsReader.computeGroups(book, stats)
    local matching = {}
    for _idx, group in ipairs(StatsReader.GROUPS) do
        if group.criteria(book, stats) then
            table.insert(matching, group.id)
        end
    end
    return matching
end

--- Enrich an array of books with stats data and engagement groups
--- Books must have .md5 field (from DocSettings partial_md5_checksum)
--- Attaches .stats and .engagement_groups to each book that has matching stats
--- @param books table Array of book metadata tables
--- @return boolean true if any books were enriched
function StatsReader.enrichBooks(books)
    if not books or #books == 0 then return false end

    local lookup = StatsReader.loadAllStats()
    if not lookup then return false end

    local enriched_any = false
    for _idx, book in ipairs(books) do
        if book.md5 then
            local stats = lookup[book.md5]
            if stats then
                book.stats = stats
                book.engagement_groups = StatsReader.computeGroups(book, stats)
                enriched_any = true
            end
        end
    end
    return enriched_any
end

--- Build formatted content for a specific engagement group from enriched books
--- Returns raw list (no label/header) — callers wrap with section labels
--- @param books table Array of enriched books (after enrichBooks())
--- @param group_id string Group ID to filter by
--- @return string Formatted book list, empty string if no matches
function StatsReader.formatGroup(books, group_id)
    if not books or #books == 0 then return "" end

    -- Find group definition
    local group_def
    for _idx, g in ipairs(StatsReader.GROUPS) do
        if g.id == group_id then
            group_def = g
            break
        end
    end
    if not group_def then return "" end

    local lines = {}
    for _idx, book in ipairs(books) do
        if book.engagement_groups and book.stats then
            for _idx2, gid in ipairs(book.engagement_groups) do
                if gid == group_id then
                    table.insert(lines, "- " .. group_def.format_book(book, book.stats))
                    break
                end
            end
        end
    end
    return table.concat(lines, "\n")
end

--- Build all group contents from enriched books
--- Returns a table of group_id → formatted content (empty groups omitted)
--- @param books table Array of enriched books (after enrichBooks())
--- @return table Map of group_id → formatted string
function StatsReader.buildAllGroups(books)
    local groups = {}
    for _idx, group in ipairs(StatsReader.GROUPS) do
        local content = StatsReader.formatGroup(books, group.id)
        if content ~= "" then
            groups[group.id] = content
        end
    end
    return groups
end

--- Get the primary engagement label for a book (for scanner formatter enrichment)
--- Returns the most significant single label, not all groups
--- Priority: deep_read > stalled > briefly_started > recently_finished
--- @param book table Enriched book with .engagement_groups
--- @return string|nil Human-readable label, or nil if no notable engagement
function StatsReader.getEngagementLabel(book)
    if not book.engagement_groups or #book.engagement_groups == 0 then
        return nil
    end

    -- Priority order for display labels (most informative first)
    local priority = {
        deep_reads = "read extensively",
        stalled = "stalled",
        briefly_started = "opened briefly",
        recently_finished = "recently finished",
    }
    local order = { "deep_reads", "stalled", "briefly_started", "recently_finished" }

    for _idx, group_id in ipairs(order) do
        for _idx2, gid in ipairs(book.engagement_groups) do
            if gid == group_id then
                return priority[group_id]
            end
        end
    end
    return nil
end

return StatsReader
