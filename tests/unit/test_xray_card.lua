-- Unit tests for koassistant_xray_card.lua pure helpers (firstSentence /
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

local XrayCard = require("koassistant_xray_card")

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

TestRunner:suite("isAliasHit")
TestRunner:test("same handle is not an alias hit", function()
    assert(XrayCard.isAliasHit({ query = "The  Black", name = "the black" }) == false)
end)
TestRunner:test("different handle is an alias hit", function()
    assert(XrayCard.isAliasHit({ query = "the black", name = "Jackson, John" }) == true)
end)
TestRunner:test("missing query never counts", function()
    assert(XrayCard.isAliasHit({ name = "X" }) == false)
end)

print(string.format("\n  Results: %d passed, %d failed", TestRunner.passed, TestRunner.failed))
return TestRunner.failed == 0
