--[[
Unit tests: S2 predecessor tier (ref #90) — ActionCache.nearestGroupXray
walk + memo, the route index's predecessor fold (no-cache books included),
XrayCard.resolve's predecessor ordering (transitive source titles, the Q6
also_ahead hint), XrayMerge.carryOne, and the S3 whole-chain walk + carried-entry roles.

Real ActionCache + BookGroups under the docsettings shim (per-doc sidecar
dirs — the multi-book variant of test_xray_card's harness).

Run: lua tests/unit/test_xray_predecessor.lua  (auto-discovered by run_tests.lua --unit)
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

local TestRunner = require("test_runner"):new()
-- Per-file sugar (test_xray_parser/test_xray_card precedent)
function TestRunner:suite(name) print(string.format("\n  [%s]", name)) end
function TestRunner:eq(a, b, msg)
    self:assertEqual(a, b, msg)
end
function TestRunner:ok(v, msg)
    self:assertTrue(not not v, msg)
end
print("Running: test_xray_predecessor")
print("")

-- ---------------------------------------------------------------- harness
local TMP_ROOT = "/tmp/koassistant_xray_pred_test_" .. tostring(os.time())
    .. "_" .. tostring(math.random(10000))
os.execute(string.format("mkdir -p %q", TMP_ROOT))
os.execute("mkdir -p /tmp/koreader/settings")

local VOL1 = TMP_ROOT .. "/vol1.epub"
local VOL2 = TMP_ROOT .. "/vol2.epub"
local VOL3 = TMP_ROOT .. "/vol3.epub"
for _idx, doc in ipairs({ VOL1, VOL2, VOL3 }) do
    os.execute(string.format("mkdir -p %q", doc .. ".sdr"))
end

package.loaded["koassistant_action_cache"] = nil
package.loaded["koassistant_book_groups"] = nil
package.loaded["koassistant_xray_card"] = nil
package.loaded["docsettings"] = nil
package.loaded["util"] = nil
-- BookGroups' store needs real read/save/flush semantics, and the runner
-- shares one Lua state: an earlier test file (test_xray_card) leaves a
-- nil-returning luasettings stub behind. Install a functional in-memory
-- one for this file; the original is restored at the end.
local prior_luasettings = package.loaded["luasettings"]
package.loaded["luasettings"] = {
    open = function(_path)
        local store = {}
        local inst
        inst = {
            readSetting = function(_self, key, default)
                local v = store[key]
                if v == nil then return default end
                return v
            end,
            saveSetting = function(_self, key, value)
                store[key] = value
                return inst
            end,
            delSetting = function(_self, key)
                store[key] = nil
                return inst
            end,
            flush = function() end,
            close = function() end,
        }
        return inst
    end,
}
_G.G_reader_settings = {
    _store = {},
    readSetting = function(self, key, default)
        local v = self._store[key]
        if v == nil then return default end
        return v
    end,
    saveSetting = function(self, key, value) self._store[key] = value end,
    flush = function() end,
}
package.loaded["docsettings"] = {
    -- Per-doc sidecars: the multi-book point of this harness
    getSidecarDir = function(_self, doc_path, _force) return doc_path .. ".sdr" end,
    isHashLocationEnabled = function() return false end,
    open = function() return { readSetting = function() end, close = function() end } end,
}
package.loaded["util"] = {
    makePath = function(dir) os.execute(string.format("mkdir -p %q", dir)) end,
}
local ActionCache = require("koassistant_action_cache")
local BookGroups = require("koassistant_book_groups")
local XrayParser = require("koassistant_xray_parser")

local VOL1_JSON = '{"characters":[{"name":"Zara Flint","description":"Dives for bells and never says who pays."}]}'
local VOL2_JSON = '{"characters":[{"name":"Petra Lund","role":"Innkeeper","description":"Keeps the crossing inn and hears everything twice."}],'
    .. '"lexicon":[{"term":"salt road","definition":"The low road that shows only at ebb."}],'
    .. '"__dormant":[{"name":"Wick","category":"characters","description":"Lights the pier lamps.","source":"Volume One","file":"' .. VOL1 .. '"}]}'
local VOL3_LIVE_JSON = '{"characters":[{"name":"Mira Voss","description":"Minds the orchard."}]}'
local VOL3_RUNG_JSON = '{"characters":[{"name":"Hester Vane","description":"Walks the salt line."},'
    .. '{"name":"Petra Lund","description":"Arrives inland with the inn sign."}]}'

local group = BookGroups.create("Pred Walk Test Series")
BookGroups.addBook(group.id, VOL1)
BookGroups.addBook(group.id, VOL2)
BookGroups.addBook(group.id, VOL3)

TestRunner:suite("nearestGroupXray — walk, memo, more count")

TestRunner:test("walks past non-X-Rayed books; memo re-picks when a nearer X-Ray appears", function()
    -- Live X-Ray = BOTH keys: per-action "xray" AND doc-level _xray_cache
    -- (getXrayCache reads the latter — the gen.lua two-key lesson)
    assert(ActionCache.set(VOL1, "xray", VOL1_JSON, 1.0, { model = "m", used_book_text = true }))
    assert(ActionCache.setXrayCache(VOL1, VOL1_JSON, 1.0, { model = "m", used_book_text = true }))
    local pred = ActionCache.nearestGroupXray(VOL3)
    TestRunner:ok(pred, "vol1-only: a predecessor resolves")
    TestRunner:eq(pred.file, VOL1, "vol2 has no X-Ray, the walk lands on vol1")
    TestRunner:eq(pred.more, 0, "nothing X-Rayed beyond the pick")
    TestRunner:ok(type(pred.title) == "string" and pred.title ~= "", "title resolves")
    -- A nearer book gains an X-Ray: the stamp changes, the memo re-picks
    assert(ActionCache.set(VOL2, "xray", VOL2_JSON, 1.0, { model = "m", used_book_text = true }))
    assert(ActionCache.setXrayCache(VOL2, VOL2_JSON, 1.0, { model = "m", used_book_text = true }))
    pred = ActionCache.nearestGroupXray(VOL3)
    TestRunner:eq(pred.file, VOL2, "nearest X-Rayed book wins")
    TestRunner:eq(pred.more, 1, "vol1's cache file counts as a further book to sweep")
    TestRunner:ok(pred.data and pred.data.characters, "parsed data rides the result")
end)

TestRunner:test("first book, unordered groups, ungrouped books: no predecessor", function()
    TestRunner:eq(ActionCache.nearestGroupXray(VOL1), nil, "book 1 has no earlier books")
    BookGroups.setOrdered(group.id, false)
    TestRunner:eq(ActionCache.nearestGroupXray(VOL3), nil,
        "unordered group: predecessorsOf stands down (Q5, series only)")
    BookGroups.setOrdered(group.id, true)
    TestRunner:eq(ActionCache.nearestGroupXray(TMP_ROOT .. "/lone.epub"), nil, "ungrouped book")
end)

TestRunner:suite("route index — predecessor fold (S2 Q4)")

TestRunner:test("pred handles route from a book with NO cache file of its own", function()
    TestRunner:eq(ActionCache.matchAnyXrayExact(VOL3, "Petra Lund"), true, "pred active routes")
    TestRunner:eq(ActionCache.matchAnyXrayExact(VOL3, "salt road"), true, "pred term routes")
    TestRunner:eq(ActionCache.matchAnyXrayExact(VOL3, "wick"), true, "pred ledger stub routes (transitive)")
    TestRunner:eq(ActionCache.matchAnyXrayExact(VOL3, "Nobody Here"), false, "miss stays a miss")
end)

TestRunner:suite("card resolve — predecessor tier (D1 order, Q6 hint)")

local XrayCard = require("koassistant_xray_card")

TestRunner:test("live > predecessor > ahead; transitive stubs keep the original source", function()
    assert(ActionCache.set(VOL3, "xray", VOL3_LIVE_JSON, 0.4, { model = "m", used_book_text = true }))
    assert(ActionCache.setXrayCache(VOL3, VOL3_LIVE_JSON, 0.4, { model = "m", used_book_text = true }))
    assert(ActionCache.pushXrayLadderRung(VOL3, {
        result = VOL3_RUNG_JSON, progress_decimal = 0.7, timestamp = 1700000900 }))
    local hit = XrayCard.resolve(VOL3, "Mira Voss", { position = 0.5 })
    TestRunner:eq(hit and hit.source, "live", "live tier first")
    hit = XrayCard.resolve(VOL3, "Petra Lund", { position = 0.5 })
    TestRunner:eq(hit and hit.source, "predecessor", "pred beats the built-ahead rung")
    TestRunner:eq(hit.pred_file, VOL2, "pred file rides the hit")
    TestRunner:eq(hit.source_title, hit.pred_title, "active hit: provenance is the predecessor")
    TestRunner:eq(hit.also_ahead, 0.7, "Q6: the next checkpoint also knows the name")
    hit = XrayCard.resolve(VOL3, "Wick", { position = 0.5 })
    TestRunner:eq(hit and hit.source, "predecessor", "pred's own ledger answers (transitive)")
    TestRunner:eq(hit.pred_stub, true, "stub flag rides")
    TestRunner:eq(hit.source_title, "Volume One", "transitive hit reports the ORIGINAL book")
    TestRunner:eq(hit.also_ahead, nil, "no hint when the rung lacks the name")
    hit = XrayCard.resolve(VOL3, "Hester Vane", { position = 0.5 })
    TestRunner:eq(hit and hit.source, "ahead", "rung-only entity keeps the peek")
end)

TestRunner:test("Upcoming Entities off: pred tier stays, hint and peek stand down", function()
    local hit = XrayCard.resolve(VOL3, "Petra Lund", { include_ahead = false, position = 0.5 })
    TestRunner:eq(hit and hit.source, "predecessor", "pred is already-read content, not a peek")
    TestRunner:eq(hit.also_ahead, nil, "hint respects the toggle")
    TestRunner:eq(XrayCard.resolve(VOL3, "Hester Vane", { include_ahead = false, position = 0.5 }),
        nil, "peek stood down")
end)

TestRunner:suite("carryOne — the manual single-entity seed (Q2)")

TestRunner:test("carries actives and term-keyed entries; refreshes by name", function()
    local XrayMerge = require("koassistant_xray_merge")
    local parsed = XrayParser.parse(VOL3_LIVE_JSON)
    local petra = { name = "Petra Lund", role = "Innkeeper", aliases = { "the innkeeper" },
        description = "Keeps the crossing inn." }
    TestRunner:ok(XrayMerge.carryOne(parsed, petra, "characters",
        { source = "Volume Two", file = VOL2 }), "carry succeeds")
    local DK = XrayParser.DORMANT_KEY
    TestRunner:eq(#parsed[DK], 1, "one stub")
    TestRunner:eq(parsed[DK][1].name, "Petra Lund")
    TestRunner:eq(parsed[DK][1].source, "Volume Two")
    TestRunner:eq(parsed[DK][1].aliases[1], "the innkeeper", "aliases copy")
    TestRunner:ok(XrayMerge.carryOne(parsed, petra, "characters",
        { source = "Volume Two", file = VOL2 }), "re-carry ok")
    TestRunner:eq(#parsed[DK], 1, "refreshed by name, never duplicated")
    local term = { term = "salt road", definition = "The low road at ebb." }
    TestRunner:ok(XrayMerge.carryOne(parsed, term, "lexicon", { source = "Volume Two", file = VOL2 }))
    TestRunner:eq(parsed[DK][2].name, "salt road", "term-keyed name resolves")
    TestRunner:eq(parsed[DK][2].description, "The low road at ebb.", "definition becomes the stub text")
    TestRunner:ok(not XrayMerge.carryOne(parsed, { role = "x" }, "characters", nil),
        "nameless item refused")
    -- The carried stub resolves through the S1 machinery immediately
    TestRunner:eq(#XrayParser.searchLedger(parsed, "the innkeeper", { exact = true }), 1,
        "stub alias searchable after carry")
end)

TestRunner:suite("S3 — whole-chain walk, parsed memo, role on carried entries")

TestRunner:test("groupXrays: every earlier X-Rayed book nearest first; parsedXrayFor memoizes", function()
    local chain = ActionCache.groupXrays(VOL3)
    TestRunner:eq(#chain, 2, "two earlier X-Rayed books")
    TestRunner:eq(chain[1].file, VOL2, "nearest first")
    TestRunner:eq(chain[2].file, VOL1, "then the book before it")
    TestRunner:ok(chain[1].data and chain[1].entry and chain[1].title, "parsed data, entry and title ride")
    TestRunner:eq(#ActionCache.groupXrays(VOL1), 0, "first book: nothing earlier")
    TestRunner:eq(#ActionCache.groupXrays(TMP_ROOT .. "/lone.epub"), 0, "ungrouped book")
    TestRunner:eq(ActionCache.parsedXrayFor(TMP_ROOT .. "/nope.epub"), nil, "no cache file = nil")
    local a = ActionCache.parsedXrayFor(VOL2)
    TestRunner:ok(a ~= nil and a == ActionCache.parsedXrayFor(VOL2), "unchanged stamp = the memoized table")
    TestRunner:ok(ActionCache.nearestGroupXray(VOL3).data == a.data, "nearest shares the same parse")
end)

TestRunner:test("role rides on carried entries: carryOne, the seed, JSON round trip, promote and demote", function()
    local XrayMerge = require("koassistant_xray_merge")
    local DK = XrayParser.DORMANT_KEY
    local parsed = XrayParser.parse(VOL3_LIVE_JSON)
    TestRunner:ok(XrayMerge.carryOne(parsed, { name = "Petra Lund", role = "Innkeeper", description = "d" },
        "characters", { source = "Volume Two", file = VOL2 }))
    TestRunner:eq(parsed[DK][1].role, "Innkeeper", "carryOne copies the role")
    local base = XrayParser.parse(VOL3_LIVE_JSON)
    XrayMerge.populateDormant(base, nil, XrayParser.parse(VOL2_JSON), "Volume Two", VOL2,
        "Volume Three", VOL3)
    local stub = XrayParser.findDormantByIdentity(base, { "Petra Lund" })
    TestRunner:eq(stub and stub.role, "Innkeeper", "the create-time seed copies the role")
    local again = XrayParser.parse(XrayParser.serialize(base))
    local st2, idx = XrayParser.findDormantByIdentity(again, { "Petra Lund" })
    TestRunner:eq(st2 and st2.role, "Innkeeper", "role survives the JSON round trip")
    TestRunner:ok(XrayParser.promoteStub(again, idx, "Petra Lund"), "promote")
    local item = XrayParser.findByIdentity(again, { "Petra Lund" }, "characters")
    TestRunner:eq(item and item.role, "Innkeeper", "promote restores the role onto the entry")
    item.background = { { source = "Volume Two", text = "Kept the inn.", file = VOL2 } }
    TestRunner:ok(XrayParser.demoteToStub(again, "characters", "Petra Lund"), "demote")
    local st3 = XrayParser.findDormantByIdentity(again, { "Petra Lund" })
    TestRunner:eq(st3 and st3.role, "Innkeeper", "demote keeps the role")
end)

TestRunner:suite("S4 — direction rule, tombstones, alias-safe seed, automatic reseed")

TestRunner:test("lookupBooksFor: ordered = earlier (then later when both ways); project = all; plain = none", function()
    local rows = BookGroups.lookupBooksFor(VOL2, false)
    TestRunner:eq(#rows, 1, "protected: earlier only")
    TestRunner:eq(rows[1].file, VOL1)
    TestRunner:eq(rows[1].direction, "earlier")
    rows = BookGroups.lookupBooksFor(VOL2, true)
    TestRunner:eq(#rows, 2, "unprotected: both directions")
    TestRunner:eq(rows[1].file, VOL1, "earlier first")
    TestRunner:eq(rows[2].file, VOL3, "then later")
    TestRunner:eq(rows[2].direction, "later")
    BookGroups.setKind(group.id, BookGroups.KIND_PROJECT)
    rows = BookGroups.lookupBooksFor(VOL2, false)
    TestRunner:eq(#rows, 2, "project: every other member, direction-free")
    TestRunner:eq(rows[1].direction, nil)
    BookGroups.setKind(group.id, BookGroups.KIND_PLAIN)
    TestRunner:eq(#BookGroups.lookupBooksFor(VOL2, true), 0, "plain: nothing, even both ways")
    BookGroups.setKind(group.id, BookGroups.KIND_SERIES)
end)

TestRunner:test("groupXrays + the card follow the injected chain resolver", function()
    local both = false
    ActionCache.setLookupChainResolver(function(_file) return both end)
    local list, stamp = ActionCache.groupXrays(VOL2)
    TestRunner:eq(#list, 1, "protected: the earlier book only")
    TestRunner:ok(stamp:find("^chain:0"), "stamp carries the reach")
    both = true
    local list2, stamp2 = ActionCache.groupXrays(VOL2)
    TestRunner:eq(#list2, 2, "unprotected: vol 1 and vol 3")
    TestRunner:eq(list2[2].direction, "later")
    TestRunner:ok(stamp2 ~= stamp, "a protection flip changes the memo key")
    -- Vol 3's own live entity answers a vol-2 lookup only while unprotected,
    -- and then ranks as a later-book hit
    local hit = XrayCard.resolve(VOL2, "Mira Voss", { position = 0.5 })
    TestRunner:eq(hit and hit.source, "predecessor", "later book answers")
    TestRunner:eq(hit and hit.direction, "later")
    both = false
    TestRunner:eq(XrayCard.resolve(VOL2, "Mira Voss", { position = 0.5 }), nil,
        "protected: later books stay silent")
    TestRunner:eq(ActionCache.matchAnyXrayExact(VOL2, "Mira Voss"), false, "route agrees")
    both = true
    TestRunner:eq(ActionCache.matchAnyXrayExact(VOL2, "Mira Voss"), true, "route follows the flip")
    ActionCache.setLookupChainResolver(nil)
end)

TestRunner:test("tombstones: removed entries stay out of the seed and the install union; adding by hand clears", function()
    local XrayMerge = require("koassistant_xray_merge")
    TestRunner:ok(ActionCache.addRemovedStub(VOL3, "Wick"), "record a removal")
    TestRunner:ok(ActionCache.getRemovedStubs(VOL3)["wick"], "lowercased set")
    TestRunner:ok(ActionCache.getUserAliases(VOL3)[ActionCache.REMOVED_STUBS_KEY], "lives in the aliases sidecar")
    local skip = ActionCache.getRemovedStubs(VOL3)
    local base = XrayParser.parse(VOL3_LIVE_JSON)
    XrayMerge.populateDormant(base, nil, XrayParser.parse(VOL2_JSON), "Volume Two", VOL2,
        "Volume Three", VOL3, skip)
    TestRunner:eq(XrayParser.findDormantByIdentity(base, { "Wick" }), nil, "seed skips the removed name")
    TestRunner:ok(XrayParser.findDormantByIdentity(base, { "Petra Lund" }), "others still seed")
    local rung = XrayParser.parse(VOL3_LIVE_JSON)
    local prev = XrayParser.parse(VOL2_JSON) -- its ledger holds Wick
    XrayMerge.unionLedger(prev, rung, skip)
    TestRunner:eq(XrayParser.findDormantByIdentity(rung, { "Wick" }), nil, "install union skips it too")
    local holder = XrayParser.parse(VOL2_JSON)
    TestRunner:eq(XrayParser.dropStubs(holder, skip), 1, "dropStubs removes the rung's own copy")
    TestRunner:ok(ActionCache.clearRemovedStub(VOL3, "wick"), "clear (case-insensitive)")
    TestRunner:eq(next(ActionCache.getRemovedStubs(VOL3)), nil, "gone")
end)

TestRunner:test("re-seed keeps a reader-added alias and reports refreshed only on change", function()
    local XrayMerge = require("koassistant_xray_merge")
    local base = XrayParser.parse(VOL3_LIVE_JSON)
    local src = XrayParser.parse(VOL2_JSON)
    local added = XrayMerge.populateDormant(base, nil, src, "Volume Two", VOL2, "Volume Three", VOL3)
    TestRunner:ok(added >= 1, "first seed adds")
    TestRunner:ok(XrayParser.addStubAlias(base, "Petra Lund", "the innkeeper"), "reader alias")
    local added2, refreshed2 = XrayMerge.populateDormant(base, nil, src, "Volume Two", VOL2, "Volume Three", VOL3)
    TestRunner:eq(added2, 0, "nothing new")
    TestRunner:eq(refreshed2, 0, "unchanged copy: no refresh reported")
    local stub = XrayParser.findDormantByIdentity(base, { "the innkeeper" })
    TestRunner:eq(stub and stub.name, "Petra Lund", "the alias survived the re-seed")
    src.characters[1].description = "Sold the inn."
    local _a3, refreshed3 = XrayMerge.populateDormant(base, nil, src, "Volume Two", VOL2, "Volume Three", VOL3)
    TestRunner:eq(refreshed3, 1, "a changed source copy counts as a refresh")
    TestRunner:eq(XrayParser.findDormantByIdentity(base, { "Petra Lund" }).description, "Sold the inn.")
end)

TestRunner:test("promoteStub keeps the earlier book's text as a background line (survives an install)", function()
    local base = XrayParser.parse(VOL2_JSON) -- ledger: Wick from Volume One
    local stub, idx = XrayParser.findDormantByIdentity(base, { "Wick" })
    TestRunner:ok(stub, "stub present")
    TestRunner:ok(XrayParser.promoteStub(base, idx, "Wick"), "promote")
    local item = XrayParser.findByIdentity(base, { "Wick" }, "characters")
    TestRunner:eq(item and item.background and item.background[1].source, "Volume One",
        "background line from the stub's own text")
    local XrayMerge = require("koassistant_xray_merge")
    local incoming = XrayParser.parse(VOL3_LIVE_JSON)
    TestRunner:eq(XrayMerge.carryActiveBackground(base, incoming), 1,
        "an install re-stubs it instead of dropping it")
    TestRunner:ok(XrayParser.findDormantByIdentity(incoming, { "Wick" }), "back on the carried list")
end)

TestRunner:test("reseedGroup: seeds every member in order, writes only on change, idempotent", function()
    local XrayMerge = require("koassistant_xray_merge")
    local features = { enable_book_text_extraction = true }
    local written, checked = XrayMerge.reseedGroup(group, features, nil, nil)
    TestRunner:ok(checked >= 2, "vol 2 and vol 3 have sources")
    TestRunner:ok(written >= 1, "at least one list written")
    local v3 = XrayParser.parse(ActionCache.getXrayCache(VOL3).result)
    TestRunner:ok(XrayParser.findDormantByIdentity(v3, { "Petra Lund" }) or
        XrayParser.findByIdentity(v3, { "Petra Lund" }, "characters"),
        "vol 3 knows vol 2's innkeeper (carried, or woken onto a live entry)")
    TestRunner:ok(XrayParser.findDormantByIdentity(v3, { "Zara Flint" }),
        "vol 1's diver reaches vol 3 through vol 2's list (chain in one run)")
    local written2 = XrayMerge.reseedGroup(group, features, nil, nil)
    TestRunner:eq(written2, 0, "second run: nothing to write")
    TestRunner:eq(XrayMerge.reseedGroup(group, {}, nil, nil), 0, "no consent: nothing written")
end)

TestRunner:suite("S5 — later books stay behind a confirm (ref #90)")

TestRunner:test("groupXrays include_later walks past the rule; heldBackLaterXrays counts what it holds back", function()
    ActionCache.setLookupChainResolver(function(_file) return false end)
    TestRunner:eq(#ActionCache.groupXrays(VOL2), 1, "protected: the earlier book only")
    local all, stamp = ActionCache.groupXrays(VOL2, { include_later = true })
    TestRunner:eq(#all, 2, "the confirmed reveal walks both directions")
    TestRunner:eq(all[1].direction, "earlier")
    TestRunner:eq(all[2].direction, "later")
    TestRunner:ok(stamp:find("^both"), "and says so in the stamp")
    TestRunner:eq(ActionCache.heldBackLaterXrays(VOL1), 2, "first volume: both later X-Rays held back")
    TestRunner:eq(ActionCache.heldBackLaterXrays(VOL2), 1, "middle volume: one")
    TestRunner:eq(ActionCache.heldBackLaterXrays(VOL3), 0, "last volume: nothing later")
    TestRunner:eq(ActionCache.heldBackLaterXrays(TMP_ROOT .. "/lone.epub"), 0, "ungrouped: nothing")
    ActionCache.setLookupChainResolver(function(_file) return true end)
    TestRunner:eq(ActionCache.heldBackLaterXrays(VOL2), 0, "unprotected: the walk already reaches them")
    ActionCache.setLookupChainResolver(nil)
    TestRunner:eq(ActionCache.heldBackLaterXrays(VOL2), 1, "no resolver = protected")
    BookGroups.setKind(group.id, BookGroups.KIND_PROJECT)
    TestRunner:eq(ActionCache.heldBackLaterXrays(VOL2), 0, "project: every member answers, nothing held back")
    BookGroups.setKind(group.id, BookGroups.KIND_SERIES)
end)

TestRunner:suite("S6 — the chain: later volumes open one read book at a time (ref #90)")

TestRunner:test("a later volume answers only when every book before it is read or unprotected", function()
    local open = {}
    ActionCache.setLookupChainResolver(function(file) return open[file] == true end)
    TestRunner:eq(#ActionCache.groupXrays(VOL1), 0, "vol 1 unread and protected: nothing later")
    TestRunner:eq(ActionCache.heldBackLaterXrays(VOL1), 2, "both later X-Rays held back")
    open[VOL1] = true
    local list, stamp = ActionCache.groupXrays(VOL1)
    TestRunner:eq(#list, 1, "vol 1 read: vol 2 answers")
    TestRunner:eq(list[1].file, VOL2)
    TestRunner:eq(list[1].direction, "later")
    TestRunner:ok(stamp:find("^chain:1"), "the stamp carries the reach")
    TestRunner:eq(ActionCache.heldBackLaterXrays(VOL1), 1, "vol 3 still behind unread vol 2")
    open[VOL3] = true
    TestRunner:eq(#ActionCache.groupXrays(VOL1), 1, "vol 3's own state never opens it")
    open[VOL2] = true
    local list2, stamp2 = ActionCache.groupXrays(VOL1)
    TestRunner:eq(#list2, 2, "vol 2 read too: vol 3 answers")
    TestRunner:eq(list2[2].file, VOL3)
    TestRunner:ok(stamp2 ~= stamp, "the reach changes the memo key")
    TestRunner:eq(ActionCache.heldBackLaterXrays(VOL1), 0, "nothing held back")
    open[VOL1] = nil
    TestRunner:eq(#ActionCache.groupXrays(VOL1), 0, "the current book blocks first, whatever the others say")
    TestRunner:eq(#ActionCache.groupXrays(VOL1, { include_later = true }), 2, "the confirmed reveal ignores the chain")
    -- From the middle: earlier books never need clearing
    open[VOL2] = nil
    TestRunner:eq(#ActionCache.groupXrays(VOL2), 1, "vol 2 unread: vol 1 only")
    open[VOL2] = true
    TestRunner:eq(#ActionCache.groupXrays(VOL2), 2, "vol 2 read: vol 1 and vol 3")
    ActionCache.setLookupChainResolver(nil)
end)

TestRunner:test("S7: the confirmed reveal opens one X-Rayed later book per confirm, past the chain", function()
    local open = {}
    ActionCache.setLookupChainResolver(function(file) return open[file] == true end)
    local one = ActionCache.groupXrays(VOL1, { reveal = 1 })
    TestRunner:eq(#one, 1, "one reveal from unread vol 1: vol 2")
    TestRunner:eq(one[1].file, VOL2)
    TestRunner:eq(one[1].revealed, true, "flagged as revealed")
    TestRunner:eq(#ActionCache.groupXrays(VOL1, { reveal = 2 }), 2, "two reveals: vol 3 too")
    TestRunner:eq(ActionCache.heldBackLaterXrays(VOL1, 1), 1, "one reveal in: vol 3 still held back")
    TestRunner:eq(ActionCache.nextHeldBackLaterXray(VOL1, 0).file, VOL2, "the next reveal is vol 2")
    TestRunner:eq(ActionCache.nextHeldBackLaterXray(VOL1, 1).file, VOL3, "then vol 3")
    TestRunner:eq(ActionCache.nextHeldBackLaterXray(VOL1, 2), nil, "then nothing")
    open[VOL1] = true
    TestRunner:eq(ActionCache.nextHeldBackLaterXray(VOL1, 0).file, VOL3,
        "vol 1 read: the chain shows vol 2, the reveal starts at vol 3")
    local mixed = ActionCache.groupXrays(VOL1, { reveal = 1 })
    TestRunner:eq(#mixed, 2, "chain plus one reveal")
    TestRunner:eq(mixed[1].revealed, nil, "the chain-reached book is not a reveal")
    TestRunner:eq(mixed[2].revealed, true)
    ActionCache.setLookupChainResolver(nil)
end)

-- ---------------------------------------------------------------- cleanup
BookGroups.remove(group.id)
os.execute(string.format("rm -rf %q", TMP_ROOT))
TestRunner:suite("S4 device round — project seeding between typeless nonfiction X-Rays")

TestRunner:test("reseedGroup carries between nonfiction members that declare no type", function()
    local XrayMerge = require("koassistant_xray_merge")
    local PA = TMP_ROOT .. "/proj_a.epub"
    local PB = TMP_ROOT .. "/proj_b.epub"
    for _idx, doc in ipairs({ PA, PB }) do
        os.execute(string.format("mkdir -p %q", doc .. ".sdr"))
    end
    -- No "type" field and an empty locations list, like the mock project pair
    -- on device: the shared key used to make both read as fiction, with every
    -- real category empty and nothing to carry
    local A_JSON = '{"key_figures":[{"name":"Maren Kessler","role":"Marine ecologist","description":"Coined the term."}],'
        .. '"locations":[],"arguments":[{"name":"Commons outlast owners","description":"Deeds do not."}],'
        .. '"terminology":[{"term":"slack water","definition":"The pause between tides."}]}'
    local B_JSON = '{"key_figures":[{"name":"Ivo Larsen","role":"Harbor historian","description":"Writes the ledgers."}],'
        .. '"locations":[],"terminology":[{"term":"salt road","definition":"A low-tide cart route."}],'
        .. '"__dormant":[{"name":"Maren Kessler","category":"key_figures","description":"Coined the term.",'
        .. '"source":"Project A","file":"' .. PA .. '"}]}'
    TestRunner:eq(XrayParser.parse(A_JSON).type, "nonfiction", "typeless nonfiction JSON infers nonfiction")
    for _idx, pair in ipairs({ { PA, A_JSON }, { PB, B_JSON } }) do
        assert(ActionCache.set(pair[1], "xray", pair[2], 1.0, { model = "m", used_book_text = true }))
        assert(ActionCache.setXrayCache(pair[1], pair[2], 1.0, { model = "m", used_book_text = true }))
    end
    local pgroup = BookGroups.create("Pred Project Test")
    BookGroups.addBook(pgroup.id, PA)
    BookGroups.addBook(pgroup.id, PB)
    BookGroups.setKind(pgroup.id, BookGroups.KIND_PROJECT)
    pgroup = BookGroups.byId(pgroup.id)
    local features = { enable_book_text_extraction = true }
    local written, checked = XrayMerge.reseedGroup(pgroup, features, nil, nil)
    TestRunner:eq(checked, 2, "both members have a source")
    TestRunner:eq(written, 2, "both carried lists change")
    local a = XrayParser.parse(ActionCache.getXrayCache(PA).result)
    TestRunner:ok(XrayParser.findDormantByIdentity(a, { "salt road" }), "A carries B's term")
    TestRunner:eq(XrayParser.findDormantByIdentity(a, { "Maren Kessler" }), nil,
        "B's stub of A's own figure never rides back into A")
    local b = XrayParser.parse(ActionCache.getXrayCache(PB).result)
    TestRunner:ok(XrayParser.findDormantByIdentity(b, { "Commons outlast owners" }), "B carries A's argument")
    TestRunner:eq(XrayParser.findDormantByIdentity(b, { "Maren Kessler" }).role, "Marine ecologist",
        "the existing stub gained the role")
    TestRunner:eq(XrayMerge.reseedGroup(pgroup, features, nil, nil), 0, "idempotent")
end)

package.loaded["luasettings"] = prior_luasettings
package.loaded["koassistant_book_groups"] = nil
package.loaded["koassistant_action_cache"] = nil

print("")
print(string.rep("-", 50))
print(string.format("  Results: %d passed, %d failed", TestRunner.passed, TestRunner.failed))
return TestRunner.failed == 0
