--[[
Unit tests: Book groups store (koassistant_book_groups.lua) — item 46, #90.

CRUD, manual ordering, first-group neighbor rule, move re-keying policy
(move re-keys / copy never joins / delete keeps), and the merge picker's
earlier-feeds-later candidate ordering.

Run: lua tests/unit/test_book_groups.lua  (auto-discovered by run_tests.lua --unit)
]]

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

-- UI-only modules koassistant_book_picker requires at load time
-- (orderBySeriesIndex borrows its pathOrderLess comparator); the helpers
-- under test are pure and never touch them. Same stubs as test_book_picker.
package.loaded["ui/widget/buttondialog"] = package.loaded["ui/widget/buttondialog"] or {}
package.loaded["ui/widget/infomessage"] = package.loaded["ui/widget/infomessage"] or {}
package.loaded["ui/widget/menu"] = package.loaded["ui/widget/menu"] or {}
package.loaded["docsettings"] = package.loaded["docsettings"] or {
    open = function() return { readSetting = function() end, close = function() end } end,
}

package.loaded["koassistant_book_groups"] = nil
local BookGroups = require("koassistant_book_groups")

-- Functional in-memory store (the real one is LuaSettings over a settings-dir file)
local mem = {}
BookGroups._setStoreForTests({
    readSetting = function(_self, key) return mem[key] end,
    saveSetting = function(_self, key, value) mem[key] = value end,
    flush = function() end,
})

local TestRunner = require("test_runner"):new()

print("Running: test_book_groups")
print("")
print("  [store CRUD + ordering]")

TestRunner:test("create / rename / delete round-trip", function()
    local g = BookGroups.create("Wheel of Time")
    TestRunner:assertEqual(g.name, "Wheel of Time", "name stored")
    TestRunner:assertTrue(g.id ~= nil, "id assigned")
    TestRunner:assertEqual(#BookGroups.all(), 1, "listed")
    TestRunner:assertTrue(BookGroups.rename(g.id, "WoT"), "rename ok")
    TestRunner:assertEqual(BookGroups.byId(g.id).name, "WoT", "rename persisted")
    TestRunner:assertTrue(BookGroups.remove(g.id), "delete ok")
    TestRunner:assertEqual(#BookGroups.all(), 0, "gone")
    TestRunner:assertEqual(BookGroups.rename("nope", "x"), false, "rename unknown id fails")
end)

TestRunner:test("addBook: order = add order, duplicates refused", function()
    local g = BookGroups.create("Series")
    TestRunner:assertTrue(BookGroups.addBook(g.id, "/b1.epub"), "add 1")
    TestRunner:assertTrue(BookGroups.addBook(g.id, "/b2.epub"), "add 2")
    TestRunner:assertEqual(BookGroups.addBook(g.id, "/b1.epub"), false, "dup refused")
    local books = BookGroups.byId(g.id).books
    TestRunner:assertEqual(#books, 2, "two members")
    TestRunner:assertEqual(books[1], "/b1.epub", "order kept")
    BookGroups.remove(g.id)
end)

TestRunner:test("moveBook: up/down with clamping", function()
    local g = BookGroups.create("S")
    BookGroups.addBook(g.id, "/a"); BookGroups.addBook(g.id, "/b"); BookGroups.addBook(g.id, "/c")
    TestRunner:assertTrue(BookGroups.moveBook(g.id, "/c", -1), "move up")
    TestRunner:assertEqual(BookGroups.byId(g.id).books[2], "/c", "c now second")
    TestRunner:assertEqual(BookGroups.moveBook(g.id, "/a", -1), false, "clamped at top")
    TestRunner:assertTrue(BookGroups.moveBook(g.id, "/a", 1), "move down")
    TestRunner:assertEqual(BookGroups.byId(g.id).books[1], "/c", "new head")
    BookGroups.remove(g.id)
end)

print("")
print("  [membership + neighbors]")

TestRunner:test("neighbors follow the FIRST containing group; predecessors in order", function()
    local g1 = BookGroups.create("First")
    local g2 = BookGroups.create("Second")
    BookGroups.addBook(g1.id, "/v1"); BookGroups.addBook(g1.id, "/v2"); BookGroups.addBook(g1.id, "/v3")
    BookGroups.addBook(g2.id, "/v2"); BookGroups.addBook(g2.id, "/x")
    local prev, next_p, group = BookGroups.neighbors("/v2")
    TestRunner:assertEqual(group.id, g1.id, "first group wins")
    TestRunner:assertEqual(prev, "/v1", "prev")
    TestRunner:assertEqual(next_p, "/v3", "next")
    local none_prev, none_next = BookGroups.neighbors("/elsewhere")
    TestRunner:assertEqual(none_prev, nil, "no group: nil prev")
    TestRunner:assertEqual(none_next, nil, "no group: nil next")
    local preds = BookGroups.predecessorsOf("/v3")
    TestRunner:assertEqual(#preds, 2, "two predecessors")
    TestRunner:assertEqual(preds[1], "/v1", "oldest first")
    TestRunner:assertEqual(#BookGroups.groupsFor("/v2"), 2, "both memberships listed")
    BookGroups.remove(g1.id); BookGroups.remove(g2.id)
end)

TestRunner:test("updateForMove: move re-keys, copy never joins, delete keeps", function()
    local g = BookGroups.create("S")
    BookGroups.addBook(g.id, "/old.epub"); BookGroups.addBook(g.id, "/other.epub")
    BookGroups.updateForMove("/old.epub", "/new.epub", true)  -- copy
    TestRunner:assertEqual(BookGroups.byId(g.id).books[1], "/old.epub", "copy: unchanged")
    BookGroups.updateForMove("/old.epub", "/new.epub", false) -- move
    TestRunner:assertEqual(BookGroups.byId(g.id).books[1], "/new.epub", "move: re-keyed")
    BookGroups.updateForMove("/other.epub", nil, false)       -- delete
    TestRunner:assertEqual(#BookGroups.byId(g.id).books, 2, "delete: membership kept")
    -- Overwrite-move onto an existing member: no duplicate
    BookGroups.updateForMove("/other.epub", "/new.epub", false)
    TestRunner:assertEqual(#BookGroups.byId(g.id).books, 1, "overwrite-move dedupes")
    BookGroups.remove(g.id)
end)

print("")
print("  [merge picker ordering (earlier feeds later)]")

TestRunner:test("orderCandidates: nearest predecessor first, then later mates, then rest", function()
    local groups = { { id = "g1", name = "Saga", books = { "/v1", "/v2", "/v3", "/v4", "/v5" } } }
    local candidates = {
        { file = "/alpha", title = "Alpha" },
        { file = "/v5", title = "Vol 5" },
        { file = "/v1", title = "Vol 1" },
        { file = "/v2", title = "Vol 2" },
        { file = "/zeta", title = "Zeta" },
    }
    local sorted = BookGroups.orderCandidates(candidates, "/v3", groups)
    TestRunner:assertEqual(sorted[1].file, "/v2", "nearest predecessor on top")
    TestRunner:assertEqual(sorted[2].file, "/v1", "older predecessor second")
    TestRunner:assertEqual(sorted[3].file, "/v5", "later mate after predecessors")
    TestRunner:assertEqual(sorted[4].file, "/alpha", "rest keeps given order")
    TestRunner:assertEqual(sorted[5].file, "/zeta", "rest keeps given order (2)")
    TestRunner:assertEqual(sorted[1].group_direction, "before", "direction annotated")
    TestRunner:assertEqual(sorted[3].group_direction, "after", "later mate flagged")
    TestRunner:assertEqual(sorted[3].group_name, "Saga", "group name annotated")
    TestRunner:assertEqual(sorted[4].group_name, nil, "non-mates unannotated")
end)

TestRunner:test("moveBookTo: absolute position, clamped, garbage and same-pos rejected", function()
    local g = BookGroups.create("Abs")
    BookGroups.addBook(g.id, "/a"); BookGroups.addBook(g.id, "/b")
    BookGroups.addBook(g.id, "/c"); BookGroups.addBook(g.id, "/d")
    TestRunner:assertEqual(BookGroups.moveBookTo(g.id, "/d", 2), true, "moves to absolute position")
    TestRunner:assertEqual(BookGroups.byId(g.id).books[2], "/d", "landed at 2")
    TestRunner:assertEqual(BookGroups.moveBookTo(g.id, "/a", 99), true, "over-large position clamps to end")
    TestRunner:assertEqual(BookGroups.byId(g.id).books[4], "/a", "clamped to last slot")
    TestRunner:assertEqual(BookGroups.moveBookTo(g.id, "/d", "x"), false, "garbage position rejected")
    TestRunner:assertEqual(BookGroups.moveBookTo(g.id, "/d", 1), false, "same position is a no-op")
end)

TestRunner:test("booksInfoFor: reading order kept, {title, authors, file} shape, missing skipped", function()
    -- Real temp files so fileExists passes; doc-settings resolution has no
    -- sidecar → the filename fallback names the rows
    local dir = (os.getenv("TMPDIR") or "/tmp"):gsub("/$", "")
    local beta, alpha = dir .. "/koa_bg_beta.epub", dir .. "/koa_bg_alpha.epub"
    for _idx, p in ipairs({ beta, alpha }) do
        local fh = assert(io.open(p, "w")); fh:write("x"); fh:close()
    end
    local group = { id = "gx", name = "Shape",
        books = { beta, alpha, dir .. "/koa_bg_gone.epub" } }
    local rows = BookGroups.booksInfoFor(group, nil)
    os.remove(beta); os.remove(alpha)
    TestRunner:assertEqual(#rows, 2, "missing member skipped")
    TestRunner:assertEqual(rows[1].file, beta, "reading order kept (not alphabetical)")
    TestRunner:assertEqual(rows[1].title, "koa_bg_beta", "filename fallback strips extension")
    TestRunner:assertEqual(rows[1].authors, "", "authors default to empty string")
    TestRunner:assertEqual(rows[2].title, "koa_bg_alpha", "second member follows")
end)

TestRunner:test("orderCandidates: group_id lens picks the ordering group (multi-group book)", function()
    local groups = {
        { id = "g1", name = "Saga", books = { "/v1", "/v2", "/shared" } },
        { id = "g2", name = "Papers", books = { "/p1", "/shared", "/p2" } },
    }
    local candidates = {
        { file = "/p2", title = "Paper 2" },
        { file = "/v1", title = "Vol 1" },
        { file = "/p1", title = "Paper 1" },
    }
    -- Lens g2: p1 is the predecessor, p2 the later mate, v1 unannotated rest
    local sorted = BookGroups.orderCandidates(candidates, "/shared", groups, "g2")
    TestRunner:assertEqual(sorted[1].file, "/p1", "g2 predecessor on top")
    TestRunner:assertEqual(sorted[1].group_name, "Papers", "annotated from the lens group")
    TestRunner:assertEqual(sorted[2].file, "/p2", "g2 later mate second")
    TestRunner:assertEqual(sorted[3].file, "/v1", "other group's mate is rest under this lens")
    TestRunner:assertEqual(sorted[3].group_name, nil, "no cross-lens annotation")
    -- No lens: first containing group (g1) wins, as before
    local candidates2 = {
        { file = "/p1", title = "Paper 1" },
        { file = "/v2", title = "Vol 2" },
    }
    local sorted2 = BookGroups.orderCandidates(candidates2, "/shared", groups)
    TestRunner:assertEqual(sorted2[1].file, "/v2", "default lens = first containing group")
end)

TestRunner:test("orderCandidates: current book in no group returns given order", function()
    local groups = { { id = "g1", name = "Saga", books = { "/v1", "/v2" } } }
    local candidates = {
        { file = "/v1", title = "Vol 1" },
        { file = "/b", title = "B" },
    }
    local sorted = BookGroups.orderCandidates(candidates, "/lonely", groups)
    TestRunner:assertEqual(sorted[1].file, "/v1", "order preserved")
    TestRunner:assertEqual(sorted[1].group_name, nil, "no annotations without a shared group")
end)

print("")
print("  [unordered groups (round 27: a group need not be a series)]")

TestRunner:test("isOrdered: nil means ordered; setOrdered stores only the false", function()
    local g = BookGroups.create("Project")
    TestRunner:assertTrue(BookGroups.isOrdered(BookGroups.byId(g.id)), "new group is ordered")
    TestRunner:assertTrue(BookGroups.isOrdered(nil), "nil group reads as ordered (no gate)")
    TestRunner:assertTrue(BookGroups.setOrdered(g.id, false), "unset ok")
    TestRunner:assertEqual(BookGroups.byId(g.id).ordered, false, "false persisted")
    TestRunner:assertEqual(BookGroups.isOrdered(BookGroups.byId(g.id)), false, "reads back unordered")
    TestRunner:assertTrue(BookGroups.setOrdered(g.id, true), "re-set ok")
    TestRunner:assertEqual(BookGroups.byId(g.id).ordered, nil,
        "ordered serializes as absent, exactly as before the field existed")
    TestRunner:assertEqual(BookGroups.setOrdered("nope", false), false, "unknown id fails")
    BookGroups.remove(g.id)
end)

print("")
print("  [group kinds (round 30: series / project / plain)]")

TestRunner:test("kindOf: absent kind reads from the pre-kind data, never guesses", function()
    -- A group written before `kind` existed: no fields at all = SERIES, which
    -- is what every such group has always behaved as
    TestRunner:assertEqual(BookGroups.kindOf({}), BookGroups.KIND_SERIES,
        "no kind, no ordered → series")
    TestRunner:assertEqual(BookGroups.kindOf(nil), BookGroups.KIND_SERIES,
        "nil group → series (no gate)")
    -- Round 27's ordered=false turned sequence features OFF and granted nothing
    -- in return, so it must read as PLAIN — promoting it to project would start
    -- offering folds the reader never opted into
    TestRunner:assertEqual(BookGroups.kindOf({ ordered = false }), BookGroups.KIND_PLAIN,
        "ordered=false without kind → plain, NOT project")
    -- An explicit kind always wins over the mirror field
    TestRunner:assertEqual(BookGroups.kindOf({ kind = "project", ordered = false }),
        BookGroups.KIND_PROJECT, "explicit kind wins")
    TestRunner:assertEqual(BookGroups.kindOf({ kind = "nonsense" }), BookGroups.KIND_SERIES,
        "an unknown kind falls back to series rather than breaking")
end)

TestRunner:test("setKind: persists, mirrors `ordered`, and drives isOrdered/sharesKnowledge", function()
    local g = BookGroups.create("Foucault")
    TestRunner:assertTrue(BookGroups.setKind(g.id, BookGroups.KIND_PROJECT), "set project")
    local stored = BookGroups.byId(g.id)
    TestRunner:assertEqual(stored.kind, "project", "kind persisted")
    TestRunner:assertEqual(stored.ordered, false, "ordered mirrored for older readers")
    TestRunner:assertEqual(BookGroups.isOrdered(stored), false, "a project has no order")
    TestRunner:assertTrue(BookGroups.sharesKnowledge(stored), "but it DOES share knowledge")

    TestRunner:assertTrue(BookGroups.setKind(g.id, BookGroups.KIND_PLAIN), "set plain")
    stored = BookGroups.byId(g.id)
    TestRunner:assertEqual(BookGroups.isOrdered(stored), false, "plain has no order")
    TestRunner:assertTrue(not BookGroups.sharesKnowledge(stored), "and shares nothing")

    TestRunner:assertTrue(BookGroups.setKind(g.id, BookGroups.KIND_SERIES), "back to series")
    stored = BookGroups.byId(g.id)
    TestRunner:assertEqual(stored.ordered, nil, "series clears the mirror to absent")
    TestRunner:assertTrue(BookGroups.isOrdered(stored), "order restored")
    TestRunner:assertTrue(BookGroups.sharesKnowledge(stored), "series shares too")

    TestRunner:assertEqual(BookGroups.setKind(g.id, "bogus"), false, "invalid kind refused")
    TestRunner:assertEqual(BookGroups.setKind("nope", "project"), false, "unknown id fails")
    BookGroups.remove(g.id)
end)

TestRunner:test("setOrdered maps onto kinds so there is ONE write path", function()
    local g = BookGroups.create("Legacy")
    BookGroups.setOrdered(g.id, false)
    TestRunner:assertEqual(BookGroups.kindOf(BookGroups.byId(g.id)), BookGroups.KIND_PLAIN,
        "the old false means plain")
    BookGroups.setOrdered(g.id, true)
    TestRunner:assertEqual(BookGroups.kindOf(BookGroups.byId(g.id)), BookGroups.KIND_SERIES,
        "and the old true means series")
    BookGroups.remove(g.id)
end)

TestRunner:test("a project yields no predecessors — the sequence chokepoint holds", function()
    local g = BookGroups.create("Sexuality")
    BookGroups.addBook(g.id, "/f1"); BookGroups.addBook(g.id, "/f2"); BookGroups.addBook(g.id, "/f3")
    TestRunner:assertEqual(#BookGroups.predecessorsOf("/f3"), 2, "series: two earlier volumes")
    BookGroups.setKind(g.id, BookGroups.KIND_PROJECT)
    local preds, group = BookGroups.predecessorsOf("/f3")
    TestRunner:assertEqual(#preds, 0, "project: nothing is 'earlier'")
    TestRunner:assertTrue(group ~= nil, "group still returned so callers can name it")
    BookGroups.remove(g.id)
end)

TestRunner:test("predecessorsOf: the ONE chokepoint — unordered yields none, group still named", function()
    local g = BookGroups.create("Papers")
    BookGroups.addBook(g.id, "/p1"); BookGroups.addBook(g.id, "/p2"); BookGroups.addBook(g.id, "/p3")
    local preds, group = BookGroups.predecessorsOf("/p3")
    TestRunner:assertEqual(#preds, 2, "ordered: predecessors as before")
    BookGroups.setOrdered(g.id, false)
    preds, group = BookGroups.predecessorsOf("/p3")
    TestRunner:assertEqual(#preds, 0, "unordered: no earlier books at all")
    TestRunner:assertTrue(group ~= nil, "group still returned so callers can name it")
    TestRunner:assertEqual(group.id, g.id, "and it is the right one")
    -- Navigation is NOT sequence-contingent: neighbors keep working
    local prev, next_p = BookGroups.neighbors("/p2")
    TestRunner:assertEqual(prev, "/p1", "prev still navigable")
    TestRunner:assertEqual(next_p, "/p3", "next still navigable")
    BookGroups.remove(g.id)
end)

TestRunner:test("orderCandidates: unordered mates lead, with no position and no direction", function()
    local groups = { { id = "g1", name = "Reading list", ordered = false,
        books = { "/a", "/b", "/c", "/d" } } }
    local candidates = {
        { file = "/zzz", title = "Outsider" },
        { file = "/d", title = "D" },
        { file = "/a", title = "A" },
    }
    local sorted = BookGroups.orderCandidates(candidates, "/b", groups)
    TestRunner:assertEqual(sorted[1].file, "/a", "mates first, in group order")
    TestRunner:assertEqual(sorted[2].file, "/d", "including the ones listed later")
    TestRunner:assertEqual(sorted[3].file, "/zzz", "non-members last")
    TestRunner:assertEqual(sorted[1].group_name, "Reading list", "still named as a group-mate")
    TestRunner:assertEqual(sorted[1].group_pos, nil, "no book number to show")
    TestRunner:assertEqual(sorted[1].group_direction, nil,
        "no direction: this is what keeps the series chain and the LATER warning away")
    TestRunner:assertEqual(sorted[2].group_direction, nil, "neither side has one")
end)

print("")
print("  [series helpers (P5 item 7)]")

TestRunner:test("normalizeSeries: case + whitespace fold, nil for empty/non-string", function()
    TestRunner:assertEqual(BookGroups.normalizeSeries("  Example Saga  "), "example saga", "trim + lower")
    TestRunner:assertEqual(BookGroups.normalizeSeries("Example\t  Saga"), "example saga", "inner whitespace collapsed")
    TestRunner:assertEqual(BookGroups.normalizeSeries(""), nil, "empty is nil")
    TestRunner:assertEqual(BookGroups.normalizeSeries("   "), nil, "blank is nil")
    TestRunner:assertEqual(BookGroups.normalizeSeries(42), nil, "non-string is nil")
end)

TestRunner:test("orderBySeriesIndex: numeric index first, index-less tail in natural filename order", function()
    local sorted = BookGroups.orderBySeriesIndex({
        { path = "/b/vol 10.epub" },
        { path = "/b/second.epub", idx = 2 },
        { path = "/b/vol 2.epub" },
        { path = "/b/first.epub", idx = "1" },
        { path = "/b/interlude.epub", idx = 1.5 },
    })
    TestRunner:assertEqual(sorted[1].path, "/b/first.epub", "string index tonumber'd, 1 first")
    TestRunner:assertEqual(sorted[2].path, "/b/interlude.epub", "decimal side-volume in place")
    TestRunner:assertEqual(sorted[3].path, "/b/second.epub", "index 2 after 1.5")
    TestRunner:assertEqual(sorted[4].path, "/b/vol 2.epub", "index-less tail starts")
    TestRunner:assertEqual(sorted[5].path, "/b/vol 10.epub", "natural order: 2 before 10")
end)

print("")
print("  [group list order]")

TestRunner:test("moveGroup / moveGroupTo: list order, clamped, no on_change", function()
    -- Fresh store: earlier tests may leave groups behind, and this one reads the whole list
    local saved_mem = mem
    mem = {}
    local a = BookGroups.create("A")
    local b = BookGroups.create("B")
    local c = BookGroups.create("C")
    local fired = false
    BookGroups.on_change = function() fired = true end
    local function ids()
        local out = {}
        for _idx, g in ipairs(BookGroups.all()) do out[#out + 1] = g.id end
        return table.concat(out, ",")
    end
    TestRunner:assertEqual(ids(), a.id .. "," .. b.id .. "," .. c.id, "creation order")
    local i, n = BookGroups.groupIndex(c.id)
    TestRunner:assertEqual(i, 3, "index of the third group")
    TestRunner:assertEqual(n, 3, "count")
    TestRunner:assertTrue(BookGroups.moveGroup(c.id, -1), "move up")
    TestRunner:assertEqual(ids(), a.id .. "," .. c.id .. "," .. b.id, "moved up one")
    TestRunner:assertEqual(BookGroups.moveGroup(a.id, -1), false, "clamped at top")
    TestRunner:assertTrue(BookGroups.moveGroupTo(b.id, 1), "to the top")
    TestRunner:assertEqual(ids(), b.id .. "," .. a.id .. "," .. c.id, "moved to position 1")
    TestRunner:assertEqual(BookGroups.moveGroupTo(b.id, 1), false, "same position rejected")
    TestRunner:assertEqual(BookGroups.moveGroupTo(b.id, "x"), false, "garbage rejected")
    TestRunner:assertEqual(BookGroups.moveGroupTo("nope", 2), false, "unknown id rejected")
    TestRunner:assertTrue(BookGroups.moveGroupTo(b.id, 99), "clamped to the end")
    TestRunner:assertEqual(ids(), a.id .. "," .. c.id .. "," .. b.id, "moved to the end")
    TestRunner:assertEqual(fired, false, "display order never notifies")
    TestRunner:assertEqual(BookGroups.groupIndex("nope"), nil, "unknown id has no index")
    BookGroups.on_change = nil
    mem = saved_mem
end)

TestRunner:test("sortGroups: one-shot, by name or by kind then name, display name canon, no on_change", function()
    local saved_mem = mem
    mem = {}
    local b = BookGroups.create("beta")
    local q = BookGroups.create("")       -- unnamed: the UI renders "(unnamed)"
    local a = BookGroups.create("Alpha")
    local fired = false
    BookGroups.on_change = function() fired = true end
    BookGroups.sortGroups("name", function(g) return g.name == "?" and "(unnamed)" or g.name end)
    local list = BookGroups.all()
    TestRunner:assertEqual(list[1].id, q.id, "'(unnamed)' sorts first (punctuation before letters)")
    TestRunner:assertEqual(list[2].id, a.id, "Alpha before beta, case-insensitive")
    TestRunner:assertEqual(list[3].id, b.id, "beta last")
    TestRunner:assertTrue(BookGroups.moveGroup(b.id, -2), "still movable by hand afterwards")
    TestRunner:assertEqual(BookGroups.all()[1].id, b.id, "moved to the top")
    TestRunner:assertEqual(fired, false, "display order never notifies")
    -- By kind: series, project, plain, then name within a kind
    BookGroups.setKind(a.id, BookGroups.KIND_PLAIN)
    BookGroups.setKind(q.id, BookGroups.KIND_PROJECT)
    BookGroups.setKind(b.id, BookGroups.KIND_SERIES)
    fired = false
    BookGroups.sortGroups("kind")
    list = BookGroups.all()
    TestRunner:assertEqual(list[1].id, b.id, "series first")
    TestRunner:assertEqual(list[2].id, q.id, "project second")
    TestRunner:assertEqual(list[3].id, a.id, "plain last")
    TestRunner:assertEqual(fired, false, "sorting by kind never notifies either")
    BookGroups.on_change = nil
    mem = saved_mem
end)

TestRunner:test("group settings: get/set/clear, settingsOf copy, no on_change; leave and delete hooks", function()
    local g = BookGroups.create("Series")
    BookGroups.addBook(g.id, "/v1.epub"); BookGroups.addBook(g.id, "/v2.epub")
    local fired = false
    BookGroups.on_change = function() fired = true end
    TestRunner:assertEqual(BookGroups.getSetting(g.id, "koassistant_book_spoiler_free"), nil, "unset")
    TestRunner:assertTrue(BookGroups.setSetting(g.id, "koassistant_book_spoiler_free", false), "set")
    TestRunner:assertEqual(BookGroups.getSetting(g.id, "koassistant_book_spoiler_free"), false, "false stored")
    TestRunner:assertEqual(BookGroups.setSetting(g.id, "koassistant_book_spoiler_free", false), false, "same value = no change")
    TestRunner:assertTrue(BookGroups.setSetting(g.id, "koassistant_book_domain", "history"), "second key")
    local copy = BookGroups.settingsOf(g.id)
    TestRunner:assertEqual(copy.koassistant_book_domain, "history", "copy carries the value")
    copy.koassistant_book_domain = "x"
    TestRunner:assertEqual(BookGroups.getSetting(g.id, "koassistant_book_domain"), "history", "copy is a copy")
    TestRunner:assertTrue(BookGroups.setSetting(g.id, "koassistant_book_domain", nil), "clear")
    TestRunner:assertEqual(BookGroups.getSetting(g.id, "koassistant_book_domain"), nil, "cleared")
    TestRunner:assertEqual(BookGroups.setSetting("nope", "k", 1), false, "unknown group")
    TestRunner:assertEqual(BookGroups.setSetting(g.id, "", 1), false, "empty key refused")
    TestRunner:assertEqual(BookGroups.getSetting("nope", "k"), nil, "unknown group reads nil")
    TestRunner:assertEqual(fired, false, "settings never fire on_change")
    BookGroups.setSetting(g.id, "koassistant_book_spoiler_free", nil)
    TestRunner:assertEqual(BookGroups.byId(g.id).settings, nil, "emptied settings table dropped")
    local left, removed = {}, nil
    BookGroups.on_leave = function(id, path) left[#left + 1] = id .. ":" .. path end
    BookGroups.on_removed = function(id, books) removed = id .. ":" .. table.concat(books, ",") end
    BookGroups.removeBook(g.id, "/v1.epub")
    TestRunner:assertEqual(left[1], g.id .. ":/v1.epub", "on_leave fired with the path")
    BookGroups.remove(g.id)
    TestRunner:assertEqual(removed, g.id .. ":/v2.epub", "on_removed fired with the remaining members")
    BookGroups.on_change = nil; BookGroups.on_leave = nil; BookGroups.on_removed = nil
end)

TestRunner:test("follow-group helpers: a marker of a group that no longer exists reads as follow-global", function()
    local BookSettings = require("koassistant_book_settings")
    local BookStore = require("koassistant_book_store")
    local GroupSettings = require("koassistant_group_settings")
    local g = BookGroups.create("Series")
    local key = "koassistant_book_research_mode"
    local function fakeDS(marker) return { readRaw = function(_, k) if k == key then return marker end end } end
    TestRunner:assertEqual(BookSettings.followingGroup(fakeDS(BookStore.marker(g.id)), key), g.id, "live group: following")
    TestRunner:assertEqual(BookSettings.followingGroup(fakeDS(BookStore.marker("gone")), key), nil, "missing group: not following")
    TestRunner:assertEqual(BookSettings.followGroupLabel(fakeDS(BookStore.marker("gone")), key, "On"), nil, "missing group: caller keeps its label")
    TestRunner:assertEqual(BookSettings.followingGroup(fakeDS(true), key), nil, "own value: not following")
    TestRunner:assertEqual(GroupSettings.replacedNotice(key, "gone"), nil, "missing group: no toast text")
    BookGroups.remove(g.id)
end)

TestRunner:test("shortName: UTF-8 safe cap with an ellipsis", function()
    TestRunner:assertEqual(BookGroups.shortName("short"), "short", "under the cap untouched")
    TestRunner:assertEqual(BookGroups.shortName("abcdef", 3), "abc\u{2026}", "cut at the cap")
    TestRunner:assertEqual(BookGroups.shortName("abc def", 4), "abc\u{2026}", "trailing space dropped")
    TestRunner:assertEqual(BookGroups.shortName("\u{0645}\u{0631}\u{062D}\u{0628}\u{0627}", 3),
        "\u{0645}\u{0631}\u{062D}\u{2026}", "counts characters, not bytes")
    TestRunner:assertEqual(BookGroups.shortName("\u{0645}\u{0631}\u{062D}", 3), "\u{0645}\u{0631}\u{062D}", "exactly the cap untouched")
    TestRunner:assertEqual(BookGroups.shortName(nil), "", "nil is empty")
end)

TestRunner:test("the hub's files row adds one tapped book, and still takes a folder (B405)", function()
    local GroupsUI = require("koassistant_book_groups_ui")
    local saved = {}
    for _i, name in ipairs({ "ui/widget/pathchooser", "libs/libkoreader-lfs", "document/documentregistry" }) do
        saved[name] = package.loaded[name]
    end
    local orig_show_group, orig_settings = GroupsUI.showGroup, rawget(_G, "G_reader_settings")
    local chooser, parent_taps, reopened = nil, 0, 0
    package.loaded["ui/widget/pathchooser"] = {
        new = function(_self, o) chooser = o; return o end,
        onMenuSelect = function() parent_taps = parent_taps + 1; return true end,
    }
    package.loaded["libs/libkoreader-lfs"] = {
        attributes = function(path) return path:match("%.epub$") and "file" or "directory" end,
    }
    package.loaded["document/documentregistry"] = {
        hasProvider = function(_self, name) return name:match("%.epub$") ~= nil end,
    }
    _G.G_reader_settings = { readSetting = function() return "/books" end }
    GroupsUI.showGroup = function() reopened = reopened + 1 end

    local g = BookGroups.create("Shelf")
    local ok, err = pcall(function()
        GroupsUI.addFolderFlow(g.id, {})
        TestRunner:assertEqual(chooser.select_file, true, "a file can be chosen")
        TestRunner:assertEqual(chooser.select_directory, true, "and so can a folder")
        TestRunner:assertEqual(chooser.file_filter("notes.txt"), false, "only books are listed")
        TestRunner:assertEqual(chooser.file_filter("a.epub"), true)
        -- A tap on a book asks the chooser's own "Choose this file?"; a tap on a folder opens it
        local asked
        chooser.onMenuHold = function(_self, item) asked = item.path; return true end
        chooser.onMenuSelect(chooser, { path = "/books/a.epub", is_file = true })
        TestRunner:assertEqual(asked, "/books/a.epub", "tap on a book = choose it")
        chooser.onMenuSelect(chooser, { path = "/books/sub" })
        TestRunner:assertEqual(parent_taps, 1, "tap on a folder navigates")
        -- Choosing the book adds that one book and lands back on the hub
        chooser.onConfirm("/books/a.epub")
        TestRunner:assertEqual(#BookGroups.byId(g.id).books, 1, "one book joined")
        TestRunner:assertEqual(BookGroups.byId(g.id).books[1], "/books/a.epub")
        TestRunner:assertTrue(reopened > 0, "the hub is refreshed")
        -- The same book again changes nothing
        chooser.onConfirm("/books/a.epub")
        TestRunner:assertEqual(#BookGroups.byId(g.id).books, 1, "no duplicate member")
    end)
    GroupsUI.showGroup = orig_show_group
    _G.G_reader_settings = orig_settings
    for name, mod in pairs(saved) do package.loaded[name] = mod end
    for _i, name in ipairs({ "ui/widget/pathchooser", "libs/libkoreader-lfs", "document/documentregistry" }) do
        if saved[name] == nil then package.loaded[name] = nil end
    end
    BookGroups.remove(g.id)
    if not ok then error(err, 0) end
end)

TestRunner:test("a hub add row's picker stays on that row's source (B407)", function()
    local GroupsUI = require("koassistant_book_groups_ui")
    local BookPicker = require("koassistant_book_picker")
    local names = { "ui/widget/pathchooser", "libs/libkoreader-lfs", "document/documentregistry",
        "ui/widget/buttondialog" }
    local saved = {}
    for _i, name in ipairs(names) do saved[name] = package.loaded[name] end
    local orig = { show = BookPicker.show, list = BookPicker.listFolderBooks,
        pick = BookPicker.pickCollection, group = GroupsUI.showGroup,
        settings = rawget(_G, "G_reader_settings") }
    local shown, chooser, ask = {}, nil, nil
    BookPicker.show = function(_self, o) shown[#shown + 1] = o end
    BookPicker.listFolderBooks = function() return { "/books/sub/a.epub", "/books/sub/b.epub" } end
    BookPicker.pickCollection = function(on_pick) on_pick("Shelf", "Shelf", { "/c/a.epub" }) end
    GroupsUI.showGroup = function() end
    package.loaded["ui/widget/pathchooser"] = { new = function(_self, o) chooser = o; return o end }
    package.loaded["libs/libkoreader-lfs"] = { attributes = function() return "directory" end }
    package.loaded["document/documentregistry"] = { hasProvider = function() return true end }
    package.loaded["ui/widget/buttondialog"] = { new = function(_self, o) ask = o; return o end }
    _G.G_reader_settings = { readSetting = function() return "/books" end }
    local function tap(label)
        for _i, row in ipairs(ask.buttons) do
            if row[1].text == label then return row[1].callback() end
        end
        error("no row: " .. label)
    end

    local g = BookGroups.create("Shelf")
    local ok, err = pcall(function()
        GroupsUI.addBooksFlow(g.id, {})
        TestRunner:assertEqual(shown[1].fixed_source, true, "the history row")
        TestRunner:assertEqual(shown[1].initial_source, nil, "which opens on the history")
        GroupsUI.addFolderFlow(g.id, {})
        chooser.onConfirm("/books/sub")
        tap("Choose which…")
        TestRunner:assertEqual(shown[2].fixed_source, true, "a folder's books")
        TestRunner:assertEqual(shown[2].initial_source, "/books/sub")
        GroupsUI.addCollectionFlow(g.id, {})
        tap("Choose which…")
        TestRunner:assertEqual(shown[3].fixed_source, true, "a collection's books")
    end)
    BookPicker.show, BookPicker.listFolderBooks, BookPicker.pickCollection = orig.show, orig.list, orig.pick
    GroupsUI.showGroup = orig.group
    _G.G_reader_settings = orig.settings
    for _i, name in ipairs(names) do package.loaded[name] = saved[name] end
    BookGroups.remove(g.id)
    if not ok then error(err, 0) end
end)

local ok = TestRunner:summary()
return ok
