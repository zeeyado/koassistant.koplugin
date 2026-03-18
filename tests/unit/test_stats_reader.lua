--[[
Unit Tests for koassistant_stats_reader.lua

Tests engagement group computation, book enrichment, group formatting,
and engagement label priority. Uses mock data — no real DB access.

Run: lua tests/run_tests.lua --unit
]]

-- Setup test environment
local function setupPaths()
    local info = debug.getinfo(1, "S")
    local script_path = info.source:match("@?(.*)")
    local unit_dir = script_path:match("(.+)/[^/]+$") or "."
    local tests_dir = unit_dir:match("(.+)/[^/]+$") or "."
    local plugin_dir = tests_dir:match("(.+)/[^/]+$") or "."

    package.path = table.concat({
        plugin_dir .. "/?.lua",
        plugin_dir .. "/?/init.lua",
        tests_dir .. "/?.lua",
        tests_dir .. "/lib/?.lua",
        package.path,
    }, ";")
end
setupPaths()

require("mock_koreader")

-- ============================================================
-- Test runner
-- ============================================================

local TestRunner = {
    passed = 0,
    failed = 0,
}

function TestRunner:test(name, fn)
    local ok, err = pcall(fn)
    if ok then
        self.passed = self.passed + 1
        print(string.format("  \226\156\147 %s", name))
    else
        self.failed = self.failed + 1
        print(string.format("  \226\156\151 %s: %s", name, tostring(err)))
    end
end

function TestRunner:assertEqual(actual, expected, msg)
    if actual ~= expected then
        error(string.format("%s\nExpected: %s\nActual: %s",
            msg or "Values not equal",
            tostring(expected), tostring(actual)))
    end
end

function TestRunner:assert(condition, msg)
    if not condition then
        error(msg or "Assertion failed")
    end
end

function TestRunner:assertContains(str, substr, msg)
    if not str or not str:find(substr, 1, true) then
        error(string.format("%s\nExpected to contain: %s\nActual: %s",
            msg or "String does not contain substring",
            tostring(substr), tostring(str)))
    end
end

function TestRunner:assertNotContains(str, substr, msg)
    if str and str:find(substr, 1, true) then
        error(string.format("%s\nExpected NOT to contain: %s\nActual: %s",
            msg or "String unexpectedly contains substring",
            tostring(substr), tostring(str)))
    end
end

-- ============================================================
-- Load module under test (skip DB-dependent functions)
-- ============================================================

-- Mock datastorage so getDbPath returns nil (no DB in tests)
package.loaded["datastorage"] = {
    getSettingsDir = function() return "/tmp/nonexistent" end,
}

local StatsReader = require("koassistant_stats_reader")

-- ============================================================
-- Test data helpers
-- ============================================================

local now = os.time()
local DAY = 86400
local HOUR = 3600

local function makeBook(overrides)
    local book = {
        title = "Test Book",
        author = "Test Author",
        status = "reading",
        progress = 0.5,
        md5 = "abc123",
    }
    if overrides then
        for k, v in pairs(overrides) do
            book[k] = v
        end
    end
    return book
end

local function makeStats(overrides)
    local stats = {
        total_read_time = 3600, -- 1 hour
        total_read_pages = 50,
        last_open = now - DAY,
        pages = 300,
    }
    if overrides then
        for k, v in pairs(overrides) do
            stats[k] = v
        end
    end
    return stats
end

-- ============================================================
-- Tests: Group criteria
-- ============================================================

print("\n=== Testing Stats Reader: Group Criteria ===\n")

TestRunner:test("deep_reads: complete + >5h = matches", function()
    local book = makeBook({ status = "complete" })
    local stats = makeStats({ total_read_time = 20000 }) -- ~5.5h
    local groups = StatsReader.computeGroups(book, stats)
    local found = false
    for _, g in ipairs(groups) do
        if g == "deep_reads" then found = true end
    end
    TestRunner:assert(found, "Should match deep_reads")
end)

TestRunner:test("deep_reads: complete + <5h = no match", function()
    local book = makeBook({ status = "complete" })
    local stats = makeStats({ total_read_time = 10000 }) -- ~2.7h
    local groups = StatsReader.computeGroups(book, stats)
    for _, g in ipairs(groups) do
        TestRunner:assert(g ~= "deep_reads", "Should not match deep_reads")
    end
end)

TestRunner:test("deep_reads: not complete = no match", function()
    local book = makeBook({ status = "reading" })
    local stats = makeStats({ total_read_time = 30000 })
    local groups = StatsReader.computeGroups(book, stats)
    for _, g in ipairs(groups) do
        TestRunner:assert(g ~= "deep_reads", "Should not match deep_reads when not complete")
    end
end)

TestRunner:test("recently_finished: complete + <30 days = matches", function()
    local book = makeBook({ status = "complete" })
    local stats = makeStats({ last_open = now - 10 * DAY })
    local groups = StatsReader.computeGroups(book, stats)
    local found = false
    for _, g in ipairs(groups) do
        if g == "recently_finished" then found = true end
    end
    TestRunner:assert(found, "Should match recently_finished")
end)

TestRunner:test("recently_finished: complete + >30 days = no match", function()
    local book = makeBook({ status = "complete" })
    local stats = makeStats({ last_open = now - 60 * DAY })
    local groups = StatsReader.computeGroups(book, stats)
    for _, g in ipairs(groups) do
        TestRunner:assert(g ~= "recently_finished", "Should not match recently_finished")
    end
end)

TestRunner:test("recently_finished: not complete = no match", function()
    local book = makeBook({ status = "reading" })
    local stats = makeStats({ last_open = now - 5 * DAY })
    local groups = StatsReader.computeGroups(book, stats)
    for _, g in ipairs(groups) do
        TestRunner:assert(g ~= "recently_finished", "Should not match recently_finished when reading")
    end
end)

TestRunner:test("stalled: >20% + >30 days inactive + not complete = matches", function()
    local book = makeBook({ status = "reading", progress = 0.45 })
    local stats = makeStats({ last_open = now - 60 * DAY })
    local groups = StatsReader.computeGroups(book, stats)
    local found = false
    for _, g in ipairs(groups) do
        if g == "stalled" then found = true end
    end
    TestRunner:assert(found, "Should match stalled")
end)

TestRunner:test("stalled: <20% progress = no match", function()
    local book = makeBook({ status = "reading", progress = 0.1 })
    local stats = makeStats({ last_open = now - 60 * DAY })
    local groups = StatsReader.computeGroups(book, stats)
    for _, g in ipairs(groups) do
        TestRunner:assert(g ~= "stalled", "Should not match stalled at low progress")
    end
end)

TestRunner:test("stalled: <30 days inactive = no match", function()
    local book = makeBook({ status = "reading", progress = 0.5 })
    local stats = makeStats({ last_open = now - 10 * DAY })
    local groups = StatsReader.computeGroups(book, stats)
    for _, g in ipairs(groups) do
        TestRunner:assert(g ~= "stalled", "Should not match stalled when recently active")
    end
end)

TestRunner:test("stalled: complete = no match", function()
    local book = makeBook({ status = "complete", progress = 0.5 })
    local stats = makeStats({ last_open = now - 60 * DAY })
    local groups = StatsReader.computeGroups(book, stats)
    for _, g in ipairs(groups) do
        TestRunner:assert(g ~= "stalled", "Should not match stalled when complete")
    end
end)

TestRunner:test("briefly_started: <30min + not complete + pages read = matches", function()
    local book = makeBook({ status = "reading", progress = 0.05 })
    local stats = makeStats({ total_read_time = 600, total_read_pages = 5 }) -- 10 min
    local groups = StatsReader.computeGroups(book, stats)
    local found = false
    for _, g in ipairs(groups) do
        if g == "briefly_started" then found = true end
    end
    TestRunner:assert(found, "Should match briefly_started")
end)

TestRunner:test("briefly_started: >30min = no match", function()
    local book = makeBook({ status = "reading" })
    local stats = makeStats({ total_read_time = 3600, total_read_pages = 20 })
    local groups = StatsReader.computeGroups(book, stats)
    for _, g in ipairs(groups) do
        TestRunner:assert(g ~= "briefly_started", "Should not match briefly_started at >30min")
    end
end)

TestRunner:test("briefly_started: complete = no match", function()
    local book = makeBook({ status = "complete" })
    local stats = makeStats({ total_read_time = 300, total_read_pages = 3 })
    local groups = StatsReader.computeGroups(book, stats)
    for _, g in ipairs(groups) do
        TestRunner:assert(g ~= "briefly_started", "Should not match briefly_started when complete")
    end
end)

TestRunner:test("briefly_started: 0 pages read = no match", function()
    local book = makeBook({ status = "reading" })
    local stats = makeStats({ total_read_time = 300, total_read_pages = 0 })
    local groups = StatsReader.computeGroups(book, stats)
    for _, g in ipairs(groups) do
        TestRunner:assert(g ~= "briefly_started", "Should not match briefly_started with 0 pages")
    end
end)

TestRunner:test("book can match multiple groups", function()
    -- Complete, >5h, finished recently → deep_reads + recently_finished
    local book = makeBook({ status = "complete" })
    local stats = makeStats({ total_read_time = 25000, last_open = now - 5 * DAY })
    local groups = StatsReader.computeGroups(book, stats)
    local has_deep = false
    local has_recent = false
    for _, g in ipairs(groups) do
        if g == "deep_reads" then has_deep = true end
        if g == "recently_finished" then has_recent = true end
    end
    TestRunner:assert(has_deep, "Should match deep_reads")
    TestRunner:assert(has_recent, "Should match recently_finished")
end)

TestRunner:test("no groups when stats don't match any criteria", function()
    -- Reading, moderate time, recently active
    local book = makeBook({ status = "reading", progress = 0.5 })
    local stats = makeStats({ total_read_time = 7200, last_open = now - 5 * DAY })
    local groups = StatsReader.computeGroups(book, stats)
    TestRunner:assertEqual(#groups, 0, "Should match no groups")
end)

-- ============================================================
-- Tests: Engagement labels
-- ============================================================

print("\n--- Engagement Labels ---")

TestRunner:test("getEngagementLabel: deep_reads has highest priority", function()
    local book = makeBook()
    book.engagement_groups = { "deep_reads", "recently_finished" }
    local label = StatsReader.getEngagementLabel(book)
    TestRunner:assertEqual(label, "read extensively", "deep_reads should win over recently_finished")
end)

TestRunner:test("getEngagementLabel: stalled priority over briefly_started", function()
    local book = makeBook()
    book.engagement_groups = { "stalled", "briefly_started" }
    local label = StatsReader.getEngagementLabel(book)
    TestRunner:assertEqual(label, "stalled", "stalled should win over briefly_started")
end)

TestRunner:test("getEngagementLabel: no groups = nil", function()
    local book = makeBook()
    book.engagement_groups = {}
    local label = StatsReader.getEngagementLabel(book)
    TestRunner:assertEqual(label, nil, "No groups should return nil")
end)

TestRunner:test("getEngagementLabel: nil groups = nil", function()
    local book = makeBook()
    local label = StatsReader.getEngagementLabel(book)
    TestRunner:assertEqual(label, nil, "nil groups should return nil")
end)

-- ============================================================
-- Tests: Group formatting
-- ============================================================

print("\n--- Group Formatting ---")

TestRunner:test("formatGroup: deep_reads shows hours", function()
    local books = {
        makeBook({ title = "Dune", author = "Frank Herbert", status = "complete" }),
    }
    books[1].stats = makeStats({ total_read_time = 43200 }) -- 12 hours
    books[1].engagement_groups = { "deep_reads" }
    local result = StatsReader.formatGroup(books, "deep_reads")
    TestRunner:assertContains(result, '"Dune"', "Should contain title")
    TestRunner:assertContains(result, "Frank Herbert", "Should contain author")
    TestRunner:assertContains(result, "12 hours", "Should contain hours")
end)

TestRunner:test("formatGroup: recently_finished shows days", function()
    local books = {
        makeBook({ title = "1984", author = "George Orwell", status = "complete" }),
    }
    books[1].stats = makeStats({ last_open = now - 3 * DAY })
    books[1].engagement_groups = { "recently_finished" }
    local result = StatsReader.formatGroup(books, "recently_finished")
    TestRunner:assertContains(result, '"1984"', "Should contain title")
    TestRunner:assertContains(result, "3 days ago", "Should contain days")
end)

TestRunner:test("formatGroup: stalled shows progress and staleness", function()
    local books = {
        makeBook({ title = "War and Peace", author = "Tolstoy", status = "reading", progress = 0.35 }),
    }
    books[1].stats = makeStats({ last_open = now - 90 * DAY })
    books[1].engagement_groups = { "stalled" }
    local result = StatsReader.formatGroup(books, "stalled")
    TestRunner:assertContains(result, "35%", "Should contain progress")
    TestRunner:assertContains(result, "3 months", "Should show months for >60 days")
end)

TestRunner:test("formatGroup: briefly_started shows minutes", function()
    local books = {
        makeBook({ title = "Ulysses", author = "Joyce", status = "reading", progress = 0.02 }),
    }
    books[1].stats = makeStats({ total_read_time = 420, total_read_pages = 3 }) -- 7 minutes
    books[1].engagement_groups = { "briefly_started" }
    local result = StatsReader.formatGroup(books, "briefly_started")
    TestRunner:assertContains(result, "7 minutes", "Should contain minutes")
end)

TestRunner:test("formatGroup: empty when no matching books", function()
    local books = {
        makeBook({ status = "reading" }),
    }
    books[1].engagement_groups = { "stalled" }
    books[1].stats = makeStats()
    local result = StatsReader.formatGroup(books, "deep_reads")
    TestRunner:assertEqual(result, "", "Should be empty for non-matching group")
end)

TestRunner:test("formatGroup: multiple books", function()
    local books = {
        makeBook({ title = "Book A", author = "Author A", status = "complete" }),
        makeBook({ title = "Book B", author = "Author B", status = "complete" }),
    }
    for _, book in ipairs(books) do
        book.stats = makeStats({ total_read_time = 20000 })
        book.engagement_groups = { "deep_reads" }
    end
    local result = StatsReader.formatGroup(books, "deep_reads")
    TestRunner:assertContains(result, "Book A", "Should contain first book")
    TestRunner:assertContains(result, "Book B", "Should contain second book")
end)

-- ============================================================
-- Tests: buildAllGroups
-- ============================================================

print("\n--- buildAllGroups ---")

TestRunner:test("buildAllGroups returns only non-empty groups", function()
    local books = {
        makeBook({ title = "Deep", status = "complete" }),
        makeBook({ title = "Stalled", status = "reading", progress = 0.4 }),
    }
    books[1].stats = makeStats({ total_read_time = 25000, last_open = now - 5 * DAY })
    books[1].engagement_groups = { "deep_reads", "recently_finished" }
    books[2].stats = makeStats({ total_read_time = 7200, last_open = now - 60 * DAY })
    books[2].engagement_groups = { "stalled" }
    local groups = StatsReader.buildAllGroups(books)
    TestRunner:assert(groups.deep_reads ~= nil, "deep_reads should be present")
    TestRunner:assert(groups.recently_finished ~= nil, "recently_finished should be present")
    TestRunner:assert(groups.stalled ~= nil, "stalled should be present")
    TestRunner:assert(groups.briefly_started == nil, "briefly_started should be absent")
end)

TestRunner:test("buildAllGroups returns empty table for no enrichment", function()
    local books = {
        makeBook({ title = "Normal", status = "reading", progress = 0.5 }),
    }
    books[1].engagement_groups = {}
    books[1].stats = makeStats()
    local groups = StatsReader.buildAllGroups(books)
    local count = 0
    for _ in pairs(groups) do count = count + 1 end
    TestRunner:assertEqual(count, 0, "Should have no groups")
end)

-- ============================================================
-- Tests: DB availability (mock returns nil)
-- ============================================================

print("\n--- DB Availability ---")

TestRunner:test("isAvailable returns false when no DB", function()
    TestRunner:assertEqual(StatsReader.isAvailable(), false, "Should be false with mock DataStorage")
end)

TestRunner:test("enrichBooks returns false when no DB", function()
    local books = { makeBook() }
    local result = StatsReader.enrichBooks(books)
    TestRunner:assertEqual(result, false, "enrichBooks should return false when DB unavailable")
end)

-- ============================================================
-- Results
-- ============================================================

print(string.format("\n=== Results: %d passed, %d failed ===", TestRunner.passed, TestRunner.failed))
if TestRunner.failed > 0 then
    os.exit(1)
end
