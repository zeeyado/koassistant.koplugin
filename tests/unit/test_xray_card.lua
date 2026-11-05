-- Unit tests for koassistant/xray/xray_card.lua pure helpers (firstSentence /
-- sentenceEnd: the entity card's identification line).

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

local XrayCard = require("koassistant.xray.xray_card")

local TestRunner = { passed = 0, failed = 0 }
function TestRunner:suite(name) print(string.format("\n  [%s]", name)) end
function TestRunner:test(name, fn)
    local ok, err = pcall(fn)
    if ok then self.passed = self.passed + 1; print("    ✓ " .. name)
    else self.failed = self.failed + 1; print("    ✗ " .. name); print("      Error: " .. tostring(err)) end
end
function TestRunner:eq(a, b, msg)
    if a ~= b then error(string.format("%s: expected %q, got %q", msg or "eq", tostring(b), tostring(a))) end
end

local fs = XrayCard.firstSentence

TestRunner:suite("firstSentence - plain sentences")
TestRunner:test("cuts at the first real terminator", function()
    TestRunner:eq(fs("Johnny is a boy. He lives in town."), "Johnny is a boy.")
    TestRunner:eq(fs("Who is he? Nobody knows."), "Who is he?")
    TestRunner:eq(fs("Run! Now."), "Run!")
end)
TestRunner:test("single sentence returns whole", function()
    TestRunner:eq(fs("  Just one sentence.  "), "Just one sentence.")
    TestRunner:eq(fs("no terminator at all"), "no terminator at all")
end)
TestRunner:test("empty / non-string", function()
    TestRunner:eq(fs(nil), "")
    TestRunner:eq(fs("   "), "")
end)

TestRunner:suite("firstSentence - abbreviations are not sentence ends")
TestRunner:test("initial chains (the reported H.S. case)", function()
    TestRunner:eq(fs("Johnny met Sally at Valleys H.S. a few years ago. They married."),
        "Johnny met Sally at Valleys H.S. a few years ago.")
    TestRunner:eq(fs("Born in the U.S.A. in 1950. Died later."), "Born in the U.S.A. in 1950.")
end)
TestRunner:test("single initials and titles", function()
    TestRunner:eq(fs("J. R. Ewing owns the ranch. He is rich."), "J. R. Ewing owns the ranch.")
    TestRunner:eq(fs("Mr. Smith teaches. Mrs. Smith paints."), "Mr. Smith teaches.")
    TestRunner:eq(fs("Dr. Who arrives. Then leaves."), "Dr. Who arrives.")
    TestRunner:eq(fs("D.B. Cooper vanished. Never found."), "D.B. Cooper vanished.")
end)
TestRunner:test("lowercase continuation after a period", function()
    TestRunner:eq(fs("Works at Acme Corp. as a clerk. Quiet."), "Works at Acme Corp. as a clerk.")
end)
TestRunner:test("listed abbreviation followed by uppercase still continues", function()
    TestRunner:eq(fs("Loves cats, dogs, etc. Hates rain."), "Loves cats, dogs, etc. Hates rain.")
end)
TestRunner:test("? and ! never count as abbreviations", function()
    TestRunner:eq(fs("Mr. who? Nobody."), "Mr. who?")
end)

TestRunner:suite("firstSentence - Arabic marks and cap")
TestRunner:test("Arabic question mark keeps the whole 2-byte mark", function()
    TestRunner:eq(fs("من هو؟ لا أحد."), "من هو؟")
end)
TestRunner:test("220-char cap on a boundary with ellipsis", function()
    local long = string.rep("word ", 60) .. "end"
    local out = fs(long)
    assert(#out <= 224, "capped")
    assert(out:sub(-3) == "…", "ellipsis")
end)

TestRunner:suite("firstSentence - boundaries that used to render the whole entry (2026-09-07)")
TestRunner:test("non-breaking space after the period still ends the sentence", function()
    TestRunner:eq(fs("He is the captain.\194\160He betrays the crew later."), "He is the captain.",
        "NBSP normalized before the scan")
end)
TestRunner:test("a lowercase name after an ordinary word does not hold the sentence open", function()
    TestRunner:eq(fs("The house was built in 1892. van Gogh later owned it."), "The house was built in 1892.",
        "digits before the period are not an abbreviation")
    TestRunner:eq(fs("She left the village. de Vries stayed behind."), "She left the village.",
        "a long ordinary word before the period is not an abbreviation")
end)
TestRunner:test("a short abbreviation before a lowercase word still holds", function()
    TestRunner:eq(fs("They argued Smith vs. the board for years. Nobody won."),
        "They argued Smith vs. the board for years.", "vs. stays inside the sentence")
end)

TestRunner:suite("firstSentence - CJK (ref #90)")
TestRunner:test("full-width stop ends the sentence without a space", function()
    TestRunner:eq(fs("彼は町の医者だ。妻と二人で暮らす。"), "彼は町の医者だ。")
end)
TestRunner:test("full-width question mark ends the sentence", function()
    TestRunner:eq(fs("誰？知らない。"), "誰？")
end)
TestRunner:test("cap never splits a multibyte character", function()
    local long = string.rep("字", 120)  -- 360 bytes, no spaces, no stops
    local out = fs(long)
    assert(#out <= 224, "capped")
    assert(out:sub(-3) == "…", "ellipsis")
    local body = out:sub(1, -4)
    assert(#body % 3 == 0, "whole 3-byte characters only")
end)

TestRunner:suite("staged ahead card (B269, #120)")
local function aheadHit(query)
    return { source = "ahead", query = query, name = "Osric Dunmere", category_key = "characters",
        category_label = "Character", ahead_progress = 0.5,
        item = { name = "Osric Dunmere", role = "Supporting",
            description = "A ferryman of the marsh. He keeps a secret." } }
end
TestRunner:test("the name stage shows the tapped word and offers the one line, a nickname included", function()
    for _idx, q in ipairs({ "Osric", "the Ferryman" }) do
        local c = XrayCard._cardContent(aheadHit(q))
        TestRunner:eq(c.name, q, "the tapped word is the name line")
        TestRunner:eq(c.body, "", "no description yet")
        TestRunner:eq(c.next_stage, "sentence", "the one line is one tap away for " .. q)
        TestRunner:eq(c.kind, "Character", "the category alone, no role")
        assert(c.warn and c.line and c.line:find("50%", 1, true), "the next-checkpoint warning")
    end
end)
TestRunner:test("the sentence stage adds the role and the first sentence; the next tap is the full entry", function()
    local c = XrayCard._cardContent(aheadHit("the Ferryman"), { stage = "sentence" })
    TestRunner:eq(c.body, "A ferryman of the marsh.", "the first sentence")
    TestRunner:eq(c.kind, "Character (Supporting)", "the role shows at the sentence stage")
    TestRunner:eq(c.next_stage, nil, "the next tap is the full entry")
    TestRunner:eq(c.hint, "Tap for the full entry", "the hint says so")
end)
TestRunner:test("Upcoming Entity Cards set to the first sentence start there, a nickname included", function()
    local c = XrayCard._cardContent(aheadHit("the Ferryman"), { ahead_card = "entry" })
    TestRunner:eq(c.body, "A ferryman of the marsh.", "starts at the sentence stage")
end)

TestRunner:test("the reveal box and the full entry both open the names list (structural, #120)", function()
    local here = debug.getinfo(1, "S").source:match("@?(.*)")
    local root = here:gsub("/?tests/unit/[^/]+$", "")
    if root == "" then root = "." end
    local f = assert(io.open(root .. "/main.lua", "r"))
    local src = f:read("*all"); f:close()
    local at = assert(src:find('ok_text = _("Reveal")', 1, true), "the ahead confirm")
    local block = src:sub(math.max(1, at - 1800), at + 400)
    assert(block:find('other_buttons = {{{ text = _("Matching…"), callback = function() matching(true) end }}}', 1, true),
        "the box's Matching… row: the tapped name alone (B590)")
    assert(block:find('buttons_table = {{{ text = _("Matching…"), callback = function() matching(false) end }}}', 1, true),
        "the full entry's Matching… row: every name")
    assert(block:find("showUpcomingNames(h, file, tapped and { tapped = true } or nil)", 1, true),
        "both open the names list, the box's on the tapped name")
end)

-- ---- resolve-order tests (S1, ref #90): real ActionCache under the
-- docsettings shim (test_xray_auto.lua pattern) — the card requires it
-- lazily inside resolve, so the shim installs before the first call.
TestRunner:suite("resolve — carried tier ordering (S1, ref #90)")
local TMP_ROOT = "/tmp/koassistant_xray_card_test_" .. tostring(os.time()) .. "_" .. tostring(math.random(10000))
local SIDECAR_DIR = TMP_ROOT .. "/book.sdr"
os.execute(string.format("mkdir -p %q", SIDECAR_DIR))
package.loaded["koassistant.artifacts.action_cache"] = nil
package.loaded["docsettings"] = nil
package.loaded["util"] = nil
package.loaded["luasettings"] = nil
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
    getSidecarDir = function(_self, _doc_path, _force) return SIDECAR_DIR end,
    isHashLocationEnabled = function() return false end,
}
package.loaded["util"] = {
    makePath = function(dir) os.execute(string.format("mkdir -p %q", dir)) end,
}
package.loaded["luasettings"] = {
    open = function() return { readSetting = function() return nil end, close = function() end } end,
}
local ActionCache = require("koassistant.artifacts.action_cache")
local DOC = TMP_ROOT .. "/book.epub"

local LIVE_JSON = '{"characters":[{"name":"Tamsin Vael","description":"Keeps the light. Stubborn."}],'
    .. '"__dormant":[{"name":"Orrin Blackwood","category":"characters","description":"Ferry master. Never asks twice.","source":"Vol 2","file":"/b/v2.epub"},'
    .. '{"name":"Vex","aliases":["the grey cat"],"category":"characters","description":"A cat.","source":"Vol 2","file":"/b/v2.epub"}]}'
local RUNG_JSON = '{"characters":[{"name":"Tamsin Vael","description":"Still here."},'
    .. '{"name":"Orrin Blackwood","description":"Arrives inland."},'
    .. '{"name":"Hester Lune","description":"Walks the salt line."}]}'
assert(ActionCache.set(DOC, "xray", LIVE_JSON, 0.4, { model = "m", used_book_text = true }))
assert(ActionCache.setXrayCache(DOC, LIVE_JSON, 0.4, { model = "m", used_book_text = true }))
assert(ActionCache.pushXrayLadderRung(DOC, {
    result = RUNG_JSON, progress_decimal = 0.7, timestamp = 1700000700 }))

TestRunner:test("live beats carried; carried beats ahead; ahead still reachable", function()
    local hit = XrayCard.resolve(DOC, "Tamsin Vael", { position = 0.5 })
    TestRunner:eq(hit and hit.source, "live", "live tier first")
    hit = XrayCard.resolve(DOC, "Orrin Blackwood", { position = 0.5 })
    TestRunner:eq(hit and hit.source, "carried", "stub outranks the built-ahead rung (D1)")
    TestRunner:eq(hit.source_title, "Vol 2", "provenance rides the hit")
    TestRunner:eq(hit.stub_idx, 1, "ledger index rides the hit")
    hit = XrayCard.resolve(DOC, "Hester Lune", { position = 0.5 })
    TestRunner:eq(hit and hit.source, "ahead", "rung-only entity keeps the peek")
end)
TestRunner:test("Q8: include_ahead=false keeps the carried tier, kills the peek", function()
    local hit = XrayCard.resolve(DOC, "the grey cat", { include_ahead = false })
    TestRunner:eq(hit and hit.source, "carried", "alias hit through the ledger")
    TestRunner:eq(hit.name, "Vex", "stub identity, not the tapped alias")
    TestRunner:eq(XrayCard.resolve(DOC, "Hester Lune", { include_ahead = false }), nil,
        "peek stood down")
end)
TestRunner:test("B329: a section hit names its section on the card", function()
    assert(ActionCache.set(DOC, "_xray_section:Ch. 3",
        '{"characters":[{"name":"Mira Fenn","description":"Rows the night ferry. Hums."}]}',
        0.4, { model = "m", used_book_text = true, scope_label = "Ch. 3" }))
    local hit = XrayCard.resolve(DOC, "Mira Fenn", { include_ahead = false })
    TestRunner:eq(hit and hit.source, "section", "section tier")
    TestRunner:eq(hit.section_label, "Ch. 3", "the section's label rides the hit")
    TestRunner:eq(XrayCard._cardContent(hit, {}).line, "From the section X-Ray: Ch. 3", "provenance line")
    hit.also_in = { { title = "Vol 2" } }
    TestRunner:eq(XrayCard._cardContent(hit, {}).line,
        "From the section X-Ray: Ch. 3 \u{00B7} Also in Vol 2's X-Ray", "joined with the group line")
    local live = XrayCard.resolve(DOC, "Tamsin Vael", { include_ahead = false })
    TestRunner:eq(XrayCard._cardContent(live, {}).line, nil, "a live hit has no provenance line")
end)
os.execute(string.format("rm -rf %q", TMP_ROOT))

print(string.format("\n  Results: %d passed, %d failed", TestRunner.passed, TestRunner.failed))
return TestRunner.failed == 0
