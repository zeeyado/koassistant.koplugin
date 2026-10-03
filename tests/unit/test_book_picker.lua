-- Unit tests for koassistant_book_picker.lua pure ordering helpers (round 29).
--
-- Why this file exists: the picker hands callers a SET (hash keyed by file
-- path). Any caller that cares about order — a book group's reading order
-- above all — must impose one, and a plain pairs() loop scrambled a 30-volume
-- folder add. These helpers are that order, so they are worth pinning.

local function setupPaths()
    local info = debug.getinfo(1, "S")
    local script_path = info.source:match("@?(.*)")
    local unit_dir = script_path:match("(.+)/[^/]+$") or "."
    local tests_dir = unit_dir:match("(.+)/[^/]+$") or "."
    local plugin_dir = tests_dir:match("(.+)/[^/]+$") or "."
    package.path = table.concat({
        plugin_dir .. "/?.lua", tests_dir .. "/?.lua", tests_dir .. "/lib/?.lua", package.path,
    }, ";")
end
setupPaths()
require("mock_koreader")

-- UI-only modules the picker requires at load time; the helpers under test are
-- pure and never touch them.
package.loaded["ui/widget/buttondialog"] = package.loaded["ui/widget/buttondialog"] or {}
package.loaded["ui/widget/infomessage"] = package.loaded["ui/widget/infomessage"] or {}
package.loaded["ui/widget/menu"] = package.loaded["ui/widget/menu"] or {}
package.loaded["docsettings"] = package.loaded["docsettings"] or {
    open = function() return { readSetting = function() end, close = function() end } end,
}

local BookPicker = require("koassistant_book_picker")

local TestRunner = { passed = 0, failed = 0 }
function TestRunner:suite(name) print(string.format("\n  [%s]", name)) end
function TestRunner:test(name, fn)
    local ok, err = pcall(fn)
    if ok then self.passed = self.passed + 1; print("    ✓ " .. name)
    else self.failed = self.failed + 1; print("    ✗ " .. name); print("      Error: " .. tostring(err)) end
end
function TestRunner:ok(v, msg) if not v then error(msg or "expected truthy") end end
function TestRunner:eq(a, b, msg)
    if a ~= b then error(string.format("%s: expected %q, got %q", msg or "eq", tostring(b), tostring(a))) end
end

local function ordered(paths)
    local set = {}
    for _idx, p in ipairs(paths) do set[p] = true end
    return BookPicker.orderedSelection(set)
end

TestRunner:suite("orderedSelection — natural filename order")

TestRunner:test("digit runs compare numerically, not lexically (vol 2 before vol 10)", function()
    local out = ordered({ "/b/vol 10.epub", "/b/vol 2.epub", "/b/vol 1.epub", "/b/vol 9.epub" })
    TestRunner:eq(out[1], "/b/vol 1.epub", "1st")
    TestRunner:eq(out[2], "/b/vol 2.epub", "2nd")
    TestRunner:eq(out[3], "/b/vol 9.epub", "3rd")
    TestRunner:eq(out[4], "/b/vol 10.epub", "4th")
end)

TestRunner:test("zero-padded and bare numbers interleave correctly", function()
    local out = ordered({ "/b/v03.epub", "/b/v1.epub", "/b/v2.epub", "/b/v10.epub" })
    TestRunner:eq(out[1], "/b/v1.epub")
    TestRunner:eq(out[2], "/b/v2.epub")
    TestRunner:eq(out[3], "/b/v03.epub")
    TestRunner:eq(out[4], "/b/v10.epub")
end)

TestRunner:test("case does not split a series", function()
    local out = ordered({ "/b/Vol 9.epub", "/b/vol 2.epub" })
    TestRunner:eq(out[1], "/b/vol 2.epub")
    TestRunner:eq(out[2], "/b/Vol 9.epub")
end)

TestRunner:test("orders by FILENAME, not full path (folder names must not reorder volumes)", function()
    local out = ordered({ "/z/アルマーク 04.epub", "/a/アルマーク 03.epub" })
    TestRunner:eq(out[1], "/a/アルマーク 03.epub", "vol 3 first despite the later folder")
    TestRunner:eq(out[2], "/z/アルマーク 04.epub")
end)

TestRunner:test("multi-byte names sort without splitting codepoints", function()
    local out = ordered({ "/b/アルマーク 10.epub", "/b/アルマーク 2.epub" })
    TestRunner:eq(out[1], "/b/アルマーク 2.epub")
    TestRunner:eq(out[2], "/b/アルマーク 10.epub")
end)

TestRunner:test("result is total and stable: equal filenames still order deterministically", function()
    local out = ordered({ "/z/same.epub", "/a/same.epub" })
    TestRunner:eq(#out, 2, "both kept")
    TestRunner:eq(out[1], "/a/same.epub", "full path breaks the tie")
end)

TestRunner:test("empty and nil selections are safe", function()
    TestRunner:eq(#BookPicker.orderedSelection({}), 0)
    TestRunner:eq(#BookPicker.orderedSelection(nil), 0)
end)

TestRunner:suite("pathOrderLess — comparator contract")

TestRunner:test("irreflexive and antisymmetric (table.sort would error otherwise)", function()
    TestRunner:ok(not BookPicker.pathOrderLess("/b/a.epub", "/b/a.epub"), "not less than itself")
    TestRunner:ok(BookPicker.pathOrderLess("/b/a.epub", "/b/b.epub"), "a < b")
    TestRunner:ok(not BookPicker.pathOrderLess("/b/b.epub", "/b/a.epub"), "and not the reverse")
end)

TestRunner:test("a numeric prefix sorts before a longer name sharing it", function()
    TestRunner:ok(BookPicker.pathOrderLess("/b/v2.epub", "/b/v2 extra.epub"))
end)

TestRunner:test("the extension never reorders a mixed-format series", function()
    -- Volume order must survive .epub/.pdf/.cbz mixing
    local out = ordered({ "/b/Vol 4.pdf", "/b/Vol 3.epub", "/b/Vol 5.cbz" })
    TestRunner:eq(out[1], "/b/Vol 3.epub")
    TestRunner:eq(out[2], "/b/Vol 4.pdf")
    TestRunner:eq(out[3], "/b/Vol 5.cbz")
end)

TestRunner:test("same volume in two formats stays adjacent and deterministic", function()
    local out = ordered({ "/b/Vol 3.pdf", "/b/Vol 3.epub" })
    TestRunner:eq(#out, 2)
    TestRunner:eq(out[1], "/b/Vol 3.epub", "tie falls through to the full path")
end)

TestRunner:suite("pathOrderLess — strict weak ordering (round-29 audit regressions)")

-- The audit found two ways the first cut broke table.sort's contract. Both are
-- pinned here because neither shows up as a crash — they surface as a silently
-- wrong reading order, which is the one thing a series group must not have.

TestRunner:test("mixed zero-padding: the padded volume still sorts before its variant", function()
    -- Was inverted: total-name-length tie-break vs. desynced cursors
    TestRunner:ok(BookPicker.pathOrderLess("/b/Vol 0002.epub", "/b/Vol 2b.epub"),
        "Vol 0002 before Vol 2b")
    TestRunner:ok(BookPicker.pathOrderLess("/b/Ch 001.epub", "/b/Ch 1b.epub"),
        "Ch 001 before Ch 1b")
end)

TestRunner:test("no intransitive triples across a mixed-padding pool", function()
    local pool = {}
    for i = 1, 8 do
        pool[#pool + 1] = string.format("/b/Ch %d.epub", i)
        pool[#pool + 1] = string.format("/b/Ch %03d.epub", i)
        pool[#pool + 1] = string.format("/b/Ch %db.epub", i)
        pool[#pool + 1] = string.format("/b/Ch %d - Extra.epub", i)
    end
    local L = BookPicker.pathOrderLess
    for i = 1, #pool do
        for j = 1, #pool do
            for k = 1, #pool do
                if L(pool[i], pool[j]) and L(pool[j], pool[k]) then
                    TestRunner:ok(L(pool[i], pool[k]), string.format(
                        "cycle: %s < %s < %s", pool[i], pool[j], pool[k]))
                end
            end
        end
    end
end)

TestRunner:test("sorted order is independent of input permutation", function()
    local pool = { "/b/Ch 001.epub", "/b/Ch 1b.epub", "/b/Ch 1 - Extra.epub",
                   "/b/Ch 2.epub", "/b/Ch 10.epub" }
    local expected
    -- every rotation must yield the same order
    for shift = 0, #pool - 1 do
        local t = {}
        for i = 1, #pool do t[i] = pool[((i + shift - 1) % #pool) + 1] end
        table.sort(t, BookPicker.pathOrderLess)
        local joined = table.concat(t, "|")
        if not expected then expected = joined end
        TestRunner:eq(joined, expected, "rotation " .. shift)
    end
end)

TestRunner:test("digit runs beyond double precision compare exactly (LuaJIT has no int64)", function()
    -- tonumber() would collapse these to the same double on device
    TestRunner:ok(BookPicker.pathOrderLess(
        "/b/9007199254740992 y.epub", "/b/9007199254740993 x.epub"),
        "…992 before …993 despite both exceeding 2^53")
end)

TestRunner:test("five-character extensions strip too (.epub3, .xhtml, .htmlz)", function()
    TestRunner:ok(BookPicker.pathOrderLess("/b/a.epub3", "/b/a.xhtml"),
        "extension stripped, tie falls to full path")
    local out = ordered({ "/b/Vol 3 - Extra.epub", "/b/Vol 3.epub3" })
    TestRunner:eq(out[1], "/b/Vol 3.epub3", "the volume, not its extra, comes first")
end)

TestRunner:test("a decimal side-volume is NOT eaten by extension stripping", function()
    -- Only ONE extension is stripped, so "Vol 3.5.epub" keeps its .5
    local out = ordered({ "/b/Vol 3.5.epub", "/b/Vol 3.epub", "/b/Vol 4.epub" })
    TestRunner:eq(out[1], "/b/Vol 3.epub")
    TestRunner:eq(out[2], "/b/Vol 3.5.epub", "3.5 sits between 3 and 4")
    TestRunner:eq(out[3], "/b/Vol 4.epub")
end)

print("")
print(string.rep("-", 50))
print(string.format("  Results: %d passed, %d failed", TestRunner.passed, TestRunner.failed))
print(string.rep("-", 50))
TestRunner:suite("collection source (round 7)")

TestRunner:test("collectionBooks lists a collection in ITS order, names sorted, default labelled", function()
    local saved = package.loaded["readcollection"]
    package.loaded["readcollection"] = {
        default_collection_name = "favorites",
        coll = {
            favorites = { ["/z.epub"] = { file = "/z.epub", order = 2 }, ["/a.epub"] = { file = "/a.epub", order = 1 } },
            Series = { ["/vol2.epub"] = { file = "/vol2.epub", order = 5 }, ["/vol1.epub"] = { file = "/vol1.epub", order = 3 },
                       ["/x.epub"] = { file = "/x.epub" } },
        },
    }
    local names = BookPicker.collectionNames()
    TestRunner:eq(#names, 2, "two collections")
    TestRunner:eq(names[1], "Series", "sorted by name")
    TestRunner:ok(BookPicker.hasCollections(), "has collections")
    TestRunner:eq(BookPicker.collectionLabel("favorites"), "Favorites", "default collection reads Favorites")
    TestRunner:eq(BookPicker.collectionLabel("Series"), "Series", "others keep their name")
    local books = BookPicker.collectionBooks("Series")
    TestRunner:eq(table.concat(books, ","), "/vol1.epub,/vol2.epub,/x.epub", "collection order, order-less last")
    TestRunner:eq(#BookPicker.collectionBooks("nope"), 0, "unknown collection is empty")
    package.loaded["readcollection"] = { coll = {} }
    TestRunner:ok(not BookPicker.hasCollections(), "no collections")
    package.loaded["readcollection"] = saved
end)

TestRunner:suite("the options menu")

-- B407: a group hub has one add row per source, so the picker each opens
-- stays on that source. The dialog class is the one the picker captured when
-- it loaded (an earlier test file may have loaded it against another stub).
TestRunner:test("a fixed source leaves the source rows out of the menu", function()
    local BD
    for i = 1, 60 do
        local name, value = debug.getupvalue(BookPicker._showPickerOptions, i)
        if not name then break end
        if name == "ButtonDialog" then BD = value end
    end
    TestRunner:ok(type(BD) == "table", "the picker's dialog class")
    local saved_new = rawget(BD, "new")
    local captured
    BD.new = function(_self, o) captured = o; return o end
    local function labels(fixed)
        local picker = setmetatable({
            _selected = {}, _entries = {}, _current_source = "history", _fixed_source = fixed,
        }, { __index = BookPicker })
        picker:_showPickerOptions()
        local out = {}
        for i, row in ipairs(captured.buttons) do out[i] = row[1].text end
        return table.concat(out, "|")
    end
    local ok, err = pcall(function()
        local open = labels(nil)
        TestRunner:ok(open:find("Sources:", 1, true), "the open picker lists its sources")
        TestRunner:ok(open:find("Browse Folder…", 1, true), "and browses folders")
        local fixed = labels(true)
        TestRunner:ok(not fixed:find("Sources:", 1, true), "no sources header")
        TestRunner:ok(not fixed:find("History", 1, true), "no history row")
        TestRunner:ok(not fixed:find("Browse", 1, true), "no browse rows")
        TestRunner:ok(fixed:find("Confirm Selection (0)", 1, true), "confirm stays")
        TestRunner:ok(fixed:find("Filter…", 1, true) and fixed:find("Search…", 1, true),
            "filter and search stay")
    end)
    rawset(BD, "new", saved_new)
    if not ok then error(err, 0) end
end)

return TestRunner.failed == 0
