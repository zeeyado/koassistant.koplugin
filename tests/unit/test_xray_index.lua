-- Unit tests for the one text matcher (koassistant_xray_parser.lua), the
-- per-book name index (koassistant_xray_index.lua) and the page-local marks
-- (koassistant_xray_marks.lua) against a mock crengine document.
-- docs/xray_marks_freeze_plan.md round 4.

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

-- A private sidecar folder for the index file
local SIDECAR = os.tmpname()
os.remove(SIDECAR)
os.execute('mkdir -p "' .. SIDECAR .. '"')
package.loaded["docsettings"] = {
    getSidecarDir = function() return SIDECAR end,
}
package.loaded["koassistant_storage_registry"] = {
    migrateSidecarFile = function() return false end,
}
-- Earlier files in the one-process suite leave their own device mocks
package.loaded["device"] = {
    screen = {
        getWidth = function() return 800 end,
        getHeight = function() return 600 end,
        scaleBySize = function(_self, x) return x end,
    },
}
local UIManager = require("ui/uimanager")
UIManager.unschedule = UIManager.unschedule or function() end
UIManager.setDirty = UIManager.setDirty or function() end

local XrayParser = require("koassistant_xray_parser")
local XrayIndex = require("koassistant_xray_index")
local XrayMarks = require("koassistant_xray_marks")

local TestRunner = { passed = 0, failed = 0 }
function TestRunner:suite(name) print(string.format("\n  [%s]", name)) end
function TestRunner:test(name, fn)
    local ok, err = pcall(fn)
    if ok then self.passed = self.passed + 1; print("    ✓ " .. name)
    else self.failed = self.failed + 1; print("    ✗ " .. name); print("      Error: " .. tostring(err)) end
end
function TestRunner:ok(v, msg) if not v then error(msg or "expected truthy", 2) end end
function TestRunner:eq(a, b, msg)
    if a ~= b then error(string.format("%s: expected %q, got %q", msg or "eq", tostring(b), tostring(a)), 2) end
end

local function has(list, value)
    for _i, v in ipairs(list or {}) do
        if v == value then return true end
    end
    return false
end

-- ── Mock crengine document ─────────────────────────────────────────────
-- One text node per paragraph; xpointers "/body/p[N]/text().<char offset>";
-- a range's text joins paragraphs with "\n" (crengine's block break); words
-- are runs of non-separator characters, each CJK character a word; the
-- current page's characters are on screen, everything else is off it.
local function newMockDoc(paragraphs, page_starts)
    local doc = { info = { number_of_pages = #page_starts }, file = "/books/mock.epub", current_page = 1 }
    local paras = {}
    for i, text in ipairs(paragraphs) do
        local chars = {}
        for ch in text:gmatch("[%z\1-\127\194-\244][\128-\191]*") do chars[#chars + 1] = ch end
        paras[i] = chars
    end
    local function xp(pi, off) return "/body/p[" .. pi .. "]/text()." .. off end
    local function parse(x)
        local pi, off = x:match("p%[(%d+)%]/text%(%)%.(%d+)$")
        return tonumber(pi), tonumber(off)
    end
    local function lin(x)
        local pi, off = parse(x)
        return pi * 1000000 + off
    end
    local SEPS = { ["’"] = true, ["“"] = true, ["”"] = true, ["，"] = true, ["。"] = true }
    local function isSep(ch) return ch:match("^[%s%p]$") ~= nil or SEPS[ch] end
    local function isCJK(ch)
        local b = ch:byte(1)
        return b and b >= 0xE3 and b <= 0xE9
    end
    local starts, ends = {}, {}
    for pi, chars in ipairs(paras) do
        local i = 1
        while i <= #chars do
            if isSep(chars[i]) then
                i = i + 1
            elseif isCJK(chars[i]) then
                starts[#starts + 1] = { pi, i - 1 }
                ends[#ends + 1] = { pi, i }
                i = i + 1
            else
                local j = i
                while j <= #chars and not isSep(chars[j]) and not isCJK(chars[j]) do j = j + 1 end
                starts[#starts + 1] = { pi, i - 1 }
                ends[#ends + 1] = { pi, j - 1 }
                i = j
            end
        end
    end
    local function posLin(p) return p[1] * 1000000 + p[2] end
    doc.calls = 0
    function doc:getPageXPointer(p)
        local s = page_starts[p]
        return s and xp(s[1], s[2])
    end
    function doc:endXPointer() return xp(#paras, #paras[#paras]) end
    function doc:compareXPointers(a, b)
        self.calls = self.calls + 1
        local la, lb = lin(a), lin(b)
        if lb > la then return 1 elseif lb == la then return 0 end
        return -1
    end
    function doc:getNextVisibleWordStart(x)
        self.calls = self.calls + 1
        local l = lin(x)
        for _i, s in ipairs(starts) do
            if posLin(s) > l then return xp(s[1], s[2]) end
        end
    end
    function doc:getPrevVisibleWordStart(x)
        self.calls = self.calls + 1
        local l, best = lin(x), nil
        for _i, s in ipairs(starts) do
            if posLin(s) < l then best = s else break end
        end
        return best and xp(best[1], best[2])
    end
    function doc:getNextVisibleWordEnd(x)
        self.calls = self.calls + 1
        local l = lin(x)
        for _i, e in ipairs(ends) do
            if posLin(e) > l then return xp(e[1], e[2]) end
        end
    end
    function doc:getTextFromXPointers(a, b)
        self.calls = self.calls + 1
        local pa, oa = parse(a)
        local pb, ob = parse(b)
        local out = {}
        for pi = pa, pb do
            local chars = paras[pi]
            local from = (pi == pa) and oa + 1 or 1
            local to = (pi == pb) and ob or #chars
            local seg = {}
            for i = from, to do seg[#seg + 1] = chars[i] end
            out[#out + 1] = table.concat(seg)
        end
        return table.concat(out, "\n")
    end
    function doc:getScreenBoxesFromPositions(a, b)
        local la, lb = lin(a), lin(b)
        local ps, pe = page_starts[self.current_page], page_starts[self.current_page + 1]
        local ls = posLin(ps)
        local le = pe and posLin(pe) or math.huge
        if la >= le or lb <= ls then return { { x = 0, y = 900, w = 10, h = 10 } } end
        return { { x = la % 1000000, y = 20, w = lb - la, h = 10 } }
    end
    return doc
end

package.loaded["koassistant_context_extractor"] = {
    documentEndXPointer = function(document) return document:endXPointer() end,
}

local PARAS = {
    "Albert Einstein was born in Ulm.",
    "Einstein studied physics. Vivian Kubrick filmed Kubrick.",
    "Later, Einstein’s theory changed physics.",
    "李白写了静夜思。李白是诗人。",
    "بِسۡمِ ٱللَّهِ ٱلرَّحۡمَٰنِ ٱلرَّحِيمِ",
}
-- page 1 = paragraphs 1-2, page 2 = 3, page 3 = 4, page 4 = 5
local PAGES = { { 1, 0 }, { 3, 0 }, { 4, 0 }, { 5, 0 } }
local DATA = {
    characters = {
        { name = "Albert Einstein", aliases = { "Einstein" } },
        { name = "Stanley Kubrick", aliases = { "Kubrick" } },
        { name = "Vivian Kubrick" },
        { name = "李白" },
    },
    locations = { { name = "Ulm" } },
    themes = { { name = "الله" } },
}

-- ── The matcher ────────────────────────────────────────────────────────
TestRunner:suite("matcher: normalization and forms")
TestRunner:test("matchNormalize: case, format characters, whitespace runs", function()
    TestRunner:eq(XrayParser.matchNormalize("Mercu\194\173rius"), "mercurius", "soft hyphen")
    TestRunner:eq(XrayParser.matchNormalize("St.\194\160Paul"), "st. paul", "no-break space")
    TestRunner:eq(XrayParser.matchNormalize("Adam \n  Kadmon"), "adam kadmon", "whitespace run")
    TestRunner:eq(XrayParser.matchNormalize("A\226\128\139B\226\129\160C"), "abc", "zero-width space, word joiner")
end)
TestRunner:test("matchNormalize: Arabic marks drop, the dagger alef too; alef forms unify", function()
    -- Uthmani ar-Rahman (dagger alef) = the common spelling
    TestRunner:eq(XrayParser.matchNormalize("ٱلرَّحۡمَٰنِ"), XrayParser.matchNormalize("الرحمن"))
    TestRunner:eq(XrayParser.matchNormalize("ٱللَّهِ"), "الله")
end)
TestRunner:test("matchTermSet: name, parenthetical, aliases; minimal forms", function()
    local set = XrayParser.matchTermSet({ name = "Theosis (Deification)", aliases = { "Deification process" } })
    TestRunner:ok(has(set.all, "theosis") and has(set.all, "deification"))
    TestRunner:ok(has(set.minimal, "deification") and not has(set.minimal, "deification process"),
        "a form containing another is not minimal")
    TestRunner:eq(set.source["deification process"], "Deification process")
    TestRunner:eq(XrayParser.matchTermSet({ name = "Bo" }), nil, "two-byte names never match")
end)
TestRunner:test("matchTermSet: Arabic alef-optional and article-dropped forms", function()
    local set = XrayParser.matchTermSet({ name = "الله" })
    TestRunner:ok(has(set.all, "الله") and has(set.all, "لله"), "initial alef optional (li-llahi)")
    TestRunner:ok(has(set.minimal, "لله"))
    local set2 = XrayParser.matchTermSet({ name = "الرحمن" })
    TestRunner:ok(has(set2.minimal, "رحمن"), "the article drops")
end)
TestRunner:test("matchTermSet memo follows an alias edited in place", function()
    local item = { name = "Kubrick" }
    TestRunner:ok(not has(XrayParser.matchTermSet(item).all, "stanley"))
    item.aliases = { "Stanley" }
    TestRunner:ok(has(XrayParser.matchTermSet(item).all, "stanley"))
end)
TestRunner:test("occurrencesIn: union of forms, containment by handles", function()
    local set = XrayParser.matchTermSet(DATA.characters[1])
    local norm = XrayParser.matchNormalize("Albert Einstein met Einstein; einsteinium is not him.")
    TestRunner:eq(#XrayParser.occurrencesIn(norm, set, nil), 2)
    local kub = XrayParser.matchTermSet(DATA.characters[2])
    local norm2 = XrayParser.matchNormalize("Vivian Kubrick filmed Kubrick.")
    TestRunner:eq(#XrayParser.occurrencesIn(norm2, kub, nil), 2)
    TestRunner:eq(#XrayParser.occurrencesIn(norm2, kub,
        XrayParser.containingMatchHandles(DATA, DATA.characters[2])), 1)
end)
TestRunner:test("occurrencesIn: Arabic substring through the marks", function()
    local norm = XrayParser.matchNormalize(PARAS[5])
    TestRunner:eq(#XrayParser.occurrencesIn(norm, XrayParser.matchTermSet({ name = "الله" }), nil), 1)
    TestRunner:eq(#XrayParser.occurrencesIn(norm, XrayParser.matchTermSet({ name = "الرحمن" }), nil), 1)
end)
TestRunner:test("normalizePieces: CJK joins without spaces; whitespace collapses across pieces", function()
    local norm, ranges = XrayParser.normalizePieces({ { text = "山" }, { text = "田" }, { text = "太" }, { text = "郎" } })
    TestRunner:eq(norm, "山田太郎")
    TestRunner:eq(ranges[2][1], 4, "each piece keeps its byte range")
    -- a lone Quranic sign normalizes to nothing: no doubled space around it
    local norm2, ranges2 = XrayParser.normalizePieces({ { text = "يوم " }, { text = "ۚ " }, { text = "الدين" } })
    TestRunner:eq(norm2, "يوم الدين")
    TestRunner:eq(ranges2[2], false)
end)
TestRunner:test("textPieces: CJK one character each, words with their whitespace", function()
    local pieces = XrayParser.textPieces("李白 wrote 静夜思.")
    local texts = {}
    for _i, p in ipairs(pieces) do texts[#texts + 1] = p.text end
    TestRunner:eq(table.concat(texts, "|"), "李|白 |wrote |静|夜|思|.")
    local norm, ranges = XrayParser.normalizePieces(pieces)
    local occ = XrayParser.occurrencesIn(norm, XrayParser.matchTermSet({ name = "静夜思" }), nil)
    TestRunner:eq(#occ, 1)
    local f, l = XrayParser.piecesForSpan(ranges, occ[1][1], occ[1][2])
    TestRunner:eq(f, 4)
    TestRunner:eq(l, 6)
    local before, match, after = XrayParser.snippetFromPieces(pieces, f, l)
    TestRunner:eq(before, "李白 wrote ")
    TestRunner:eq(match, "静夜思")
    TestRunner:eq(after, ".")
end)

-- ── The index ──────────────────────────────────────────────────────────
TestRunner:suite("name index: scan, queries, store")
local doc = newMockDoc(PARAS, PAGES)
local ENTS = XrayParser.buildMarkEntities(DATA)
local FORMS, seen_f = {}, {}
for _i, e in ipairs(ENTS) do
    for _j, f in ipairs(e.set.all) do
        if not seen_f[f] then
            seen_f[f] = true
            FORMS[#FORMS + 1] = f
        end
    end
end
local SCANNED = XrayIndex.scan(doc, FORMS, 1, #PAGES)
local LAYOUT = { stamp = "S1", forms = SCANNED }

TestRunner:test("scan: every form recorded, pages and offsets encoded", function()
    TestRunner:ok(SCANNED["einstein"] ~= nil and SCANNED["einstein"] ~= "")
    local d = XrayIndex.decode(LAYOUT, "einstein")
    TestRunner:eq(table.concat(d.pages, ","), "1,2")
    TestRunner:eq(#d.offs[1], 2, "two on page 1")
    TestRunner:eq(SCANNED["ulm"]:match("^1:"), "1:")
end)
TestRunner:test("entityPages: union and containment per page", function()
    local ein = XrayParser.matchTermSet(DATA.characters[1])
    local counts, total = XrayIndex.entityPages(LAYOUT, ein, nil)
    TestRunner:eq(counts[1], 2, "Albert Einstein + Einstein on page 1")
    TestRunner:eq(counts[2], 1)
    TestRunner:eq(total, 3)
    local kub = XrayParser.matchTermSet(DATA.characters[2])
    local _c, with_handles = XrayIndex.entityPages(LAYOUT, kub,
        XrayParser.containingMatchHandles(DATA, DATA.characters[2]))
    TestRunner:eq(with_handles, 1, "Vivian Kubrick is Vivian's mention")
    local li = XrayParser.matchTermSet(DATA.characters[4])
    local lc = XrayIndex.entityPages(LAYOUT, li, nil)
    TestRunner:eq(lc[3], 2, "CJK name twice on page 3")
    local allah = XrayParser.matchTermSet(DATA.themes[1])
    TestRunner:eq(XrayIndex.entityPages(LAYOUT, allah, nil)[4], 1)
end)
TestRunner:test("entityPages: a span limits the pages", function()
    local ein = XrayParser.matchTermSet(DATA.characters[1])
    local _c, total = XrayIndex.entityPages(LAYOUT, ein, nil, 2, 4)
    TestRunner:eq(total, 1)
end)
TestRunner:test("prevPage / covers / missing", function()
    local ein = XrayParser.matchTermSet(DATA.characters[1])
    TestRunner:eq(XrayIndex.prevPage(LAYOUT, ein, nil, 2), 1)
    TestRunner:eq(XrayIndex.prevPage(LAYOUT, ein, nil, 1), nil, "first appearance: none before")
    local unknown = XrayParser.matchTermSet({ name = "Mileva" })
    TestRunner:eq(XrayIndex.prevPage(LAYOUT, unknown, nil, 3), false, "a form not indexed")
    TestRunner:ok(not XrayIndex.covers(LAYOUT, unknown))
    TestRunner:eq(#XrayIndex.missing(LAYOUT, { "einstein", "mileva" }), 1)
end)
TestRunner:test("store/load: layouts keyed by stamp, two kept, newest first", function()
    XrayIndex.store(doc.file, "S1", SCANNED)
    XrayIndex.store(doc.file, "S2", { einstein = "1:0" })
    XrayIndex.store(doc.file, "S1", { mileva = "" })
    local l1 = XrayIndex.layout(doc.file, "S1")
    TestRunner:ok(l1 and l1.forms.einstein == SCANNED.einstein and l1.forms.mileva == "",
        "new forms merge into the stored layout")
    XrayIndex.store(doc.file, "S3", {})
    TestRunner:eq(XrayIndex.layout(doc.file, "S2"), nil, "the oldest layout drops")
    -- The file reads back the same (a fresh load, not the memo)
    local f = io.open(XrayIndex.path(doc.file), "rb")
    local src = f:read("*a")
    f:close()
    TestRunner:ok(not src:find("_decoded"), "runtime memo never written")
    local fn = assert((loadstring or load)(src))
    local data = fn()
    TestRunner:eq(data.layouts[1].stamp, "S3")
    TestRunner:eq(data.layouts[2].forms.einstein, SCANNED.einstein)
end)

-- ── Page words ─────────────────────────────────────────────────────────
TestRunner:suite("page words: the walk")
TestRunner:test("Latin page: every word, the book's separators, inside flags", function()
    local pieces, norm = XrayIndex.pageWords(doc, 1, 1, 2)
    TestRunner:eq(pieces[1].text:sub(1, 6), "Albert", "the page's first word is not skipped")
    for _i, pc in ipairs(pieces) do
        TestRunner:ok(not pc.text:find("^%s"), "no piece starts with whitespace")
    end
    TestRunner:ok(norm:find("born in ulm. einstein studied", 1, true), "block break collapses to a space")
    TestRunner:ok(norm:find("vivian kubrick filmed kubrick.", 1, true))
    local last = pieces[#pieces]
    TestRunner:ok(not last.inside, "margin words after the page are outside")
end)
TestRunner:test("CJK page: one piece per character, no spaces between them", function()
    local pieces, norm = XrayIndex.pageWords(doc, 3, 3, 0)
    TestRunner:ok(norm:find("李白写了静夜思。李白是诗人。", 1, true), norm)
    local n = 0
    for _i, pc in ipairs(pieces) do
        if pc.inside and pc.text:find("^李") then n = n + 1 end
    end
    TestRunner:eq(n, 2)
end)

-- ── Marks ──────────────────────────────────────────────────────────────
TestRunner:suite("marks: page-local")
local function buildEntities()
    local ents = XrayParser.buildMarkEntities(DATA)
    for i, a in ipairs(ents) do
        local longer, handles
        for j, b in ipairs(ents) do
            if i ~= j then
                local hit = false
                for _tb, tb in ipairs(b.set.all) do
                    for _ta, ta in ipairs(a.set.minimal) do
                        if #tb > #ta and tb:find(ta, 1, true) and XrayParser.handleContainsWord(tb, ta) then
                            hit = true
                            handles = handles or {}
                            handles[#handles + 1] = tb
                            break
                        end
                    end
                end
                if hit then
                    longer = longer or {}
                    longer[#longer + 1] = j
                end
            end
        end
        a.longer, a.handles = longer, handles
    end
    return ents
end
local ui = { document = doc }
local function markNames(marks)
    local by = {}
    for _i, m in ipairs(marks) do by[m.name] = (by[m.name] or 0) + 1 end
    return by
end
TestRunner:test("every occurrence: names on the page, containment, taps read the form", function()
    doc.current_page = 1
    local state = { entities = buildEntities(), spacing = 0, file = doc.file }
    local marks = XrayMarks._computeMarks(state, ui, 1, 1, "none")
    local by = markNames(marks)
    TestRunner:eq(by["Albert Einstein"], 2)
    TestRunner:eq(by["Stanley Kubrick"], 1, "the Kubrick inside Vivian Kubrick is Vivian's")
    TestRunner:eq(by["Vivian Kubrick"], 1)
    TestRunner:eq(by["Ulm"], 1)
    TestRunner:eq(by["李白"], nil, "the next page's names stay off this one")
    local texts = {}
    for _i, m in ipairs(marks) do texts[m.text] = true end
    TestRunner:ok(texts["Albert Einstein"] and texts["Einstein"], "the tapped form, not the entry name")
end)
TestRunner:test("CJK and Arabic pages mark", function()
    local state = { entities = buildEntities(), spacing = 0, file = doc.file }
    doc.current_page = 3
    TestRunner:eq(markNames(XrayMarks._computeMarks(state, ui, 3, 3, "none"))["李白"], 2)
    doc.current_page = 4
    TestRunner:eq(markNames(XrayMarks._computeMarks(state, ui, 4, 4, "none"))["الله"], 1)
end)
TestRunner:test("once per page, and spacing from the index", function()
    XrayIndex.store(doc.file, "S1", SCANNED)
    local ents = buildEntities()
    doc.current_page = 1
    local once = XrayMarks._computeMarks({ entities = ents, spacing = 1, file = doc.file }, ui, 1, 1, "S1")
    TestRunner:eq(markNames(once)["Albert Einstein"], 1)
    doc.current_page = 2
    local first_only = { entities = ents, spacing = math.huge, file = doc.file }
    TestRunner:eq(markNames(XrayMarks._computeMarks(first_only, ui, 2, 2, "S1"))["Albert Einstein"], nil,
        "seen on page 1: no mark under first appearance only")
    doc.current_page = 1
    TestRunner:eq(markNames(XrayMarks._computeMarks(first_only, ui, 1, 1, "S1"))["Albert Einstein"], 1,
        "its first page marks")
    -- No stored layout for this stamp: once per page
    doc.current_page = 2
    TestRunner:eq(markNames(XrayMarks._computeMarks(first_only, ui, 2, 2, "unbuilt"))["Albert Einstein"], 1)
end)

os.execute('rm -rf "' .. SIDECAR .. '"')
print(string.format("  Results: %d passed, %d failed", TestRunner.passed, TestRunner.failed))
return TestRunner.failed == 0
