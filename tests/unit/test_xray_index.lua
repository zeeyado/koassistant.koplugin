-- Unit tests for the one text matcher (koassistant/xray/xray_parser.lua), the
-- per-book name index (koassistant/xray/xray_index.lua) and the page-local marks
-- (koassistant/xray/xray_marks.lua) against a mock crengine document.
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
    return plugin_dir
end
local PLUGIN_DIR = setupPaths()
require("mock_koreader")

-- A private sidecar folder for the index file
local SIDECAR = os.tmpname()
os.remove(SIDECAR)
os.execute('mkdir -p "' .. SIDECAR .. '"')
package.loaded["docsettings"] = {
    getSidecarDir = function() return SIDECAR end,
}
package.loaded["koassistant.storage.storage_registry"] = {
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

local XrayParser = require("koassistant.xray.xray_parser")
local XrayIndex = require("koassistant.xray.xray_index")
local XrayMarks = require("koassistant.xray.xray_marks")

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
-- Text nodes in document order: a paragraph is a string (one node) or a list
-- of { text, rt = true } parts (ruby annotations are their own nodes, under
-- an rt element). xpointers are "<node path>.<char offset>". A range's text
-- works like crengine's getRangeText: paragraphs joined with "\n", rt nodes
-- skipped, soft hyphens dropped; a node's own text (getTextFromXPointer)
-- keeps them. Words are runs of non-separator characters within a node, each
-- CJK character a word; the current page's characters are on screen.
local function newMockDoc(paragraphs, page_starts)
    local doc = { info = { number_of_pages = #page_starts }, file = "/books/mock.epub", current_page = 1 }
    local nodes = {}
    for pi, para in ipairs(paragraphs) do
        local parts = type(para) == "string" and { { text = para } } or para
        local k, r = 0, 0
        for _i, part in ipairs(parts) do
            local chars = {}
            for ch in part.text:gmatch("[%z\1-\127\194-\244][\128-\191]*") do chars[#chars + 1] = ch end
            local path
            if part.rt then
                r = r + 1
                path = "/body/p[" .. pi .. "]/ruby[1]/rt[" .. r .. "]/text()[1]"
            else
                k = k + 1
                path = "/body/p[" .. pi .. "]/text()[" .. k .. "]"
            end
            nodes[#nodes + 1] = { pi = pi, path = path, chars = chars, rt = part.rt }
        end
    end
    local by_path = {}
    for ni, n in ipairs(nodes) do by_path[n.path] = ni end
    local function xp(ni, off) return nodes[ni].path .. "." .. off end
    local function parse(x)
        local path, off = x:match("^(.*)%.(%d+)$")
        return by_path[path], tonumber(off)
    end
    local function lin(x)
        local ni, off = parse(x)
        return ni * 1000000 + off
    end
    local SEPS = { ["’"] = true, ["“"] = true, ["”"] = true, ["，"] = true, ["。"] = true }
    local SHY = "\194\173"
    local function isSep(ch) return ch:match("^[%s%p]$") ~= nil or SEPS[ch] end
    local function isCJK(ch)
        local b = ch:byte(1)
        return b and b >= 0xE3 and b <= 0xE9
    end
    local starts, ends = {}, {}
    for ni, n in ipairs(nodes) do
        local chars = n.chars
        local i = 1
        while i <= #chars do
            if isSep(chars[i]) then
                i = i + 1
            elseif isCJK(chars[i]) then
                starts[#starts + 1] = { ni, i - 1 }
                ends[#ends + 1] = { ni, i }
                i = i + 1
            else
                local j = i
                while j <= #chars and (chars[j] == SHY or (not isSep(chars[j]) and not isCJK(chars[j]))) do
                    j = j + 1
                end
                starts[#starts + 1] = { ni, i - 1 }
                ends[#ends + 1] = { ni, j - 1 }
                i = j
            end
        end
    end
    local function posLin(p) return p[1] * 1000000 + p[2] end
    doc.calls = 0
    function doc:getPageXPointer(p)
        local s = page_starts[p]
        return s and xp(by_path["/body/p[" .. s[1] .. "]/text()[1]"], s[2])
    end
    function doc:endXPointer() return xp(#nodes, #nodes[#nodes].chars) end
    function doc:compareXPointers(a, b)
        self.calls = self.calls + 1
        local la, lb = lin(a), lin(b)
        if lb > la then return 1 elseif lb == la then return 0 end
        return -1
    end
    function doc:getNextVisibleWordStart(x)
        self.calls = self.calls + 1
        local l = lin(x)
        for _i, st in ipairs(starts) do
            if posLin(st) > l then return xp(st[1], st[2]) end
        end
    end
    function doc:getPrevVisibleWordStart(x)
        self.calls = self.calls + 1
        local l, best = lin(x), nil
        for _i, st in ipairs(starts) do
            if posLin(st) < l then best = st else break end
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
    function doc:getTextFromXPointer(x)
        local ni = parse(x)
        return table.concat(nodes[ni].chars)
    end
    function doc:getTextFromXPointers(a, b)
        self.calls = self.calls + 1
        local na, oa = parse(a)
        local nb, ob = parse(b)
        local out, last_pi = {}, nil
        for ni = na, nb do
            local n = nodes[ni]
            if last_pi and n.pi ~= last_pi then out[#out + 1] = "\n" end
            last_pi = n.pi
            if not n.rt then
                local from = (ni == na) and oa + 1 or 1
                local to = (ni == nb) and ob or #n.chars
                for i = from, to do
                    if n.chars[i] ~= SHY then out[#out + 1] = n.chars[i] end
                end
            end
        end
        return table.concat(out)
    end
    function doc:getScreenBoxesFromPositions(a, b)
        local la, lb = lin(a), lin(b)
        local ps, pe = page_starts[self.current_page], page_starts[self.current_page + 1]
        local ls = by_path["/body/p[" .. ps[1] .. "]/text()[1]"] * 1000000 + ps[2]
        local le = pe and (by_path["/body/p[" .. pe[1] .. "]/text()[1]"] * 1000000 + pe[2]) or math.huge
        if la >= le or lb <= ls then return { { x = 0, y = 900, w = 10, h = 10 } } end
        return { { x = la % 1000000, y = 20, w = lb - la, h = 10, node = math.floor(la / 1000000) } }
    end
    return doc
end

package.loaded["koassistant.request.context_extractor"] = {
    documentEndXPointer = function(document) return document:endXPointer() end,
}

local PARAS = {
    "Albert Einstein was born in Ulm.",
    "Einstein studied physics. Vivian Kubrick filmed Kubrick.",
    "Later, Einstein’s theory changed physics.",
    "李白写了静夜思。李白是诗人。",
    "بِسۡمِ ٱللَّهِ ٱلرَّحۡمَٰنِ ٱلرَّحِيمِ",
    -- soft hyphens in the DOM text, not in the range text
    "Die Ver\194\173wal\194\173tung traf Einstein.",
    -- ruby: the rt readings are their own nodes, skipped by the range text
    { { text = "東" }, { text = "とう", rt = true }, { text = "京" }, { text = "きょう", rt = true },
      { text = "に行った。" } },
}
-- page 1 = paragraphs 1-2, page 2 = 3, page 3 = 4, page 4 = 5, page 5 = 6, page 6 = 7
local PAGES = { { 1, 0 }, { 3, 0 }, { 4, 0 }, { 5, 0 }, { 6, 0 }, { 7, 0 } }
local DATA = {
    characters = {
        { name = "Albert Einstein", aliases = { "Einstein" } },
        { name = "Stanley Kubrick", aliases = { "Kubrick" } },
        { name = "Vivian Kubrick" },
        { name = "李白" },
    },
    locations = { { name = "Ulm" }, { name = "東京" } },
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
TestRunner:test("matchTermSet: name and aliases; minimal forms", function()
    local set = XrayParser.matchTermSet({ name = "Theosis", aliases = { "Deification", "Deification process" } })
    TestRunner:ok(has(set.all, "theosis") and has(set.all, "deification"))
    TestRunner:ok(has(set.minimal, "deification") and not has(set.minimal, "deification process"),
        "a form containing another is not minimal")
    TestRunner:eq(set.source["deification process"], "Deification process")
    TestRunner:eq(XrayParser.matchTermSet({ name = "Bo" }), nil, "two-byte names never match")
end)
TestRunner:test("matchTermSet: a bracketed part in the name's own script is a label; a leading The drops", function()
    local set = XrayParser.matchTermSet({ name = "The Wise Old Man (archetype)",
        aliases = { "Spirit archetype", "The Sun" } })
    TestRunner:ok(not has(set.all, "archetype"), "(archetype) would match every archetype")
    TestRunner:ok(has(set.all, "spirit archetype"), "an alias stays whole")
    TestRunner:ok(has(set.minimal, "wise old man"), "the article is optional while two words remain")
    TestRunner:ok(has(set.all, "the sun") and not has(set.all, "sun"), "one word keeps its article")
    for _i, name in ipairs({ "The Old Ferryman (Norse tale)", "Theosis (Deification)",
            "Anna (the elder)", "Anna Weber (1901–1977)" }) do
        local s = XrayParser.matchTermSet({ name = name })
        TestRunner:eq(#s.all, name:find("^The ") and 2 or 1, name .. ": the name outside the brackets only")
    end
end)
TestRunner:test("matchTermSet: a bracketed part in another script is the name in that script", function()
    local set = XrayParser.matchTermSet({ name = "The Old City (المَدِينَة القَدِيمَة)" })
    TestRunner:ok(has(set.all, "old city"), "the English name")
    TestRunner:ok(has(set.all, XrayParser.matchNormalize("المَدِينَة القَدِيمَة")), "the Arabic name")
    local ar = XrayParser.matchTermSet({ name = "القَاهِرَة (Cairo)" })
    TestRunner:ok(has(ar.all, "cairo"), "a transliteration after an Arabic name")
    TestRunner:ok(has(XrayParser.matchTermSet({ name = "Tokyo (東京)" }).all, "東京"), "CJK after Latin")
    TestRunner:ok(not has(XrayParser.matchTermSet({ name = "Rome (Roma روما)" }).all, "roma روما"),
        "a part sharing the name's script is a label")
end)
TestRunner:test("matchTermSet: Arabic alef-optional and article-dropped forms", function()
    local set = XrayParser.matchTermSet({ name = "الله" })
    TestRunner:ok(has(set.all, "الله") and has(set.all, "لله"), "initial alef optional (li-llahi)")
    TestRunner:ok(has(set.minimal, "لله"))
    local set2 = XrayParser.matchTermSet({ name = "الرحمن" })
    TestRunner:ok(has(set2.minimal, "رحمن"), "the article drops")
end)
TestRunner:test("matchTermSet: an Arabic word keeps its first alef; li- + al- contracts; three letters at least (B339)", function()
    local ard = XrayParser.matchTermSet({ name = "الأرض" })
    TestRunner:ok(has(ard.all, "الارض") and has(ard.all, "ارض"), "the name and its article-dropped form")
    TestRunner:ok(has(ard.all, "للارض"), "li- + al-: lil-ard")
    TestRunner:ok(not has(ard.all, "رض"), "the first alef of a word is always written")
    TestRunner:ok(not has(ard.all, "لارض"), "the article's alef drops only after li-")
    local kalla = XrayParser.matchTermSet({ name = "كلا" })
    TestRunner:ok(has(kalla.all, "كلا") and not has(kalla.all, "كل"), "two letters never match")
    TestRunner:eq(XrayParser.matchTermSet({ name = "هو" }), nil, "a two-letter name matches nothing")
    local maryam = XrayParser.matchTermSet({ name = "مريم", aliases = { "هي" } })
    TestRunner:ok(has(maryam.all, "مريم") and not has(maryam.all, "هي"), "a two-letter alias adds nothing")
    local ibrahim = XrayParser.matchTermSet({ name = "إبراهيم" })
    TestRunner:ok(has(ibrahim.all, "ابراهيم") and has(ibrahim.all, "ابرهيم"),
        "a medial alef stays optional (the dagger-alef spelling)")
    TestRunner:ok(not has(ibrahim.all, "براهيم"), "the first alef stays")
end)
TestRunner:test("occurrencesIn: an Arabic name matches at a word's start, prefixes and short endings allowed (B339)", function()
    local ard = XrayParser.matchTermSet({ name = "الأرض" })
    local function count(text)
        return #XrayParser.occurrencesIn(XrayParser.matchNormalize(text), ard, nil)
    end
    TestRunner:eq(count("مُعْرِضُونَ"), 0, "the reported word: رض inside a different word")
    TestRunner:eq(count("وَالْأَرْضِ"), 1, "wa- + the name")
    TestRunner:eq(count("بِالْأَرْضِ"), 1, "bi- + the name")
    TestRunner:eq(count("لِلْأَرْضِ"), 1, "li- + al- contracted")
    TestRunner:eq(count("أَرْضِهِمْ"), 1, "an ending of up to three letters (their land)")
    TestRunner:eq(count("ارضكموها"), 0, "a longer ending is another word")
    TestRunner:eq(count("فِي الْأَرْضِ وَالسَّمَاءِ"), 1)
    local allah = XrayParser.matchTermSet({ name = "الله" })
    local norm = XrayParser.matchNormalize("ٱلۡحَمۡدُ لِلَّهِ رَبِّ ٱلۡعَٰلَمِينَ وَٱللَّهُ")
    TestRunner:eq(#XrayParser.occurrencesIn(norm, allah, nil), 2, "li-llahi and wa-llahu")
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
    TestRunner:eq(table.concat(d.pages, ","), "1,2,5")
    TestRunner:eq(#d.offs[1], 2, "two on page 1")
    TestRunner:eq(SCANNED["ulm"]:match("^1:"), "1:")
end)
TestRunner:test("entityPages: union and containment per page", function()
    local ein = XrayParser.matchTermSet(DATA.characters[1])
    local counts, total = XrayIndex.entityPages(LAYOUT, ein, nil)
    TestRunner:eq(counts[1], 2, "Albert Einstein + Einstein on page 1")
    TestRunner:eq(counts[2], 1)
    TestRunner:eq(counts[5], 1, "read through the soft hyphens around it")
    TestRunner:eq(total, 4)
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
TestRunner:test("store/load: layouts keyed by stamp, four kept, newest first", function()
    XrayIndex.store(doc.file, "S1", SCANNED)
    XrayIndex.store(doc.file, "S2", { einstein = "1:0" })
    XrayIndex.store(doc.file, "S1", { mileva = "" })
    local l1 = XrayIndex.layout(doc.file, "S1")
    TestRunner:ok(l1 and l1.forms.einstein == SCANNED.einstein and l1.forms.mileva == "",
        "new forms merge into the stored layout")
    XrayIndex.store(doc.file, "S4", {})
    XrayIndex.store(doc.file, "S5", {})
    TestRunner:ok(XrayIndex.layout(doc.file, "S2") ~= nil, "four layouts fit (B505)")
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
    TestRunner:eq(data.layouts[4].stamp, "S1")
    TestRunner:eq(data.layouts[4].forms.einstein, SCANNED.einstein)
end)

TestRunner:test("a store keeps the layouts another device wrote meanwhile (B505)", function()
    -- This device's memo holds S3, S5, S4, S1; a sync tool then brings a file
    -- whose newest layout is another device's
    local path = XrayIndex.path(doc.file)
    local f = io.open(path, "rb")
    local src = f:read("*a")
    f:close()
    local other = src:gsub('layouts = {\n', 'layouts = {\n    {\n      stamp = "OTHER",\n      forms = {\n        ["mileva"] = "",\n      },\n    },\n', 1)
    f = io.open(path, "wb")
    f:write(other)
    f:close()
    XrayIndex.store(doc.file, "S3", { einstein = "1:0" })
    TestRunner:ok(XrayIndex.layout(doc.file, "OTHER") ~= nil, "the other device's layout survives this write")
    TestRunner:eq(XrayIndex.layout(doc.file, "S3").forms.einstein, "1:0", "this device's own pass lands")
end)

TestRunner:test("an index written by the older matcher is read as missing (B339)", function()
    XrayIndex.stop(true) -- drop the loaded memo
    local f = io.open(XrayIndex.path(doc.file), "wb")
    f:write('return {\n  version = 1,\n  layouts = { { stamp = "S1", forms = { einstein = "1:0" } } },\n}\n')
    f:close()
    TestRunner:eq(XrayIndex.load(doc.file), nil, "Arabic spans changed: the book is indexed again")
    XrayIndex.stop(true)
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

TestRunner:test("soft hyphens: words read without them, positions still the DOM's", function()
    local pieces, norm = XrayIndex.pageWords(doc, 5, 5, 0)
    TestRunner:ok(norm:find("die verwaltung traf einstein.", 1, true), norm)
    for _i, pc in ipairs(pieces) do
        if pc.text:find("^Einstein") then
            TestRunner:eq(pc.ws:match("%.(%d+)$"), "22", "the DOM offset counts the soft hyphens")
        end
    end
end)
TestRunner:test("ruby: the readings add nothing to the text", function()
    local pieces, norm = XrayIndex.pageWords(doc, 6, 6, 0)
    TestRunner:ok(norm:find("東京に行った", 1, true), norm)
    for _i, pc in ipairs(pieces) do
        if pc.ws:find("/rt%[") then TestRunner:eq(pc.text, "", "an rt word has no width") end
    end
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
TestRunner:test("soft hyphens and ruby: the mark sits on the name", function()
    local state = { entities = buildEntities(), spacing = 0, file = doc.file }
    doc.current_page = 5
    local marks = XrayMarks._computeMarks(state, ui, 5, 5, "none")
    TestRunner:eq(#marks, 1)
    TestRunner:eq(marks[1].x, 22, "starts at Einstein, not before it")
    doc.current_page = 6
    local rm = XrayMarks._computeMarks(state, ui, 6, 6, "none")
    TestRunner:eq(markNames(rm)["東京"], 2, "one box per base character, none on the reading")
    TestRunner:eq(rm[1].x, 0, "starts at 東")
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

-- ── Capitals only (B533 S2) ────────────────────────────────────────────
TestRunner:suite("capitals only (B533 S2)")
local function required(name) return XrayParser.capsRequired(XrayParser.matchNormalizeKeepCase(name), true) end
local function passes(name, text)
    return XrayParser.capsPass(XrayParser.capsMask(XrayParser.matchNormalizeKeepCase(text)), required(name))
end
TestRunner:test("the rule: the name's capitals in the text, its first word free, all-caps passes", function()
    TestRunner:ok(passes("The Pale Ones", "the Pale Ones"), "a small the mid-sentence")
    TestRunner:ok(passes("The Pale Ones", "The Pale Ones"))
    TestRunner:ok(passes("The Pale Ones", "THE PALE ONES"), "all-caps")
    TestRunner:ok(not passes("The Pale Ones", "the pale ones"), "the everyday phrase")
    TestRunner:ok(passes("Tide", "Tide"))
    TestRunner:ok(not passes("Tide", "tide"))
    TestRunner:ok(not passes("Red Fen", "red fen"), "the second word decides")
    TestRunner:ok(passes("Red Fen", "red Fen"), "the first word is free")
    TestRunner:ok(passes("Ana-Lis", "Ana-lis"), "a word's first letter only")
    TestRunner:eq(required("the grafter"), 0, "a name with no capital requires nothing")
    TestRunner:eq(required("李白"), 0, "nor one in a script without case")
    TestRunner:ok(passes("Tide", "李白"), "a word without case counts as capitalized")
end)
TestRunner:test("matchTermSet: the forms a capitals-only name requires; any case wins a shared form", function()
    local item = { name = "The Wise Old Man", aliases = { "the wise old man" },
        _caps = { ["the wise old man"] = true } }
    -- the alias as written is lowercase, but the record is by the lowered
    -- name, so both are capitals only: the name's capitals rule its forms
    local set = XrayParser.matchTermSet(item)
    TestRunner:eq(set.caps["the wise old man"], 14, "Wise, Old and Man; The free")
    TestRunner:eq(set.caps["wise old man"], 7, "the article-dropped form keeps every capital left")
    local mixed = XrayParser.matchTermSet({ name = "The Drowned", aliases = { "the drowned" },
        _caps = { ["the drowned"] = true } })
    TestRunner:eq(mixed.caps["the drowned"], 2, "one record covers both spellings")
    local open = XrayParser.matchTermSet({ name = "Warden", aliases = { "warden" }, _caps = {} })
    TestRunner:eq(open.caps, nil, "nothing set: no caps table")
    local any = { name = "Gil Rook", aliases = { "Gil" }, _caps = { ["gil rook"] = true } }
    TestRunner:eq(XrayParser.matchTermSet(any).caps["gil"], nil, "the alias stays any case")
    any._caps = nil
    TestRunner:eq(XrayParser.matchTermSet(any).caps, nil, "the memo follows the record")
end)
TestRunner:test("occurrencesIn: a capitals-only form counts with the twin, every case without it", function()
    local set = XrayParser.matchTermSet({ name = "The Drowned", _caps = { ["the drowned"] = true } })
    local text = "Past the drowned trees, the Drowned lit fires. THE DROWNED came."
    local norm, keep = XrayParser.matchNormalize(text), XrayParser.matchNormalizeKeepCase(text)
    TestRunner:eq(#XrayParser.occurrencesIn(norm, set), 3, "no twin: as before")
    local occ = XrayParser.occurrencesIn(norm, set, nil, keep)
    TestRunner:eq(#occ, 2)
    TestRunner:eq(keep:sub(occ[1][1], occ[1][2]), "the Drowned")
    -- a twin that does not fold back (a piece the fold changed) passes
    TestRunner:eq(#XrayParser.occurrencesIn(norm, set, nil, ("\1"):rep(#norm)), 3, "unreadable: counted")
end)
TestRunner:test("the piece builder's twin: same bytes as the folded run", function()
    local pieces = XrayParser.textPieces("Out on the water the Drowned lit fires, past the drowned trees.")
    local norm = XrayParser.normalizePieces(pieces)
    local keep = XrayParser.normalizePieces(pieces, true)
    TestRunner:eq(#keep, #norm)
    TestRunner:eq(XrayParser.foldCase(keep), norm)
    TestRunner:ok(keep:find("the Drowned", 1, true) ~= nil)
end)

local CAPS_PARAS = {
    "Out on the water the Drowned lit fires past the drowned trees.",
    "Tamsin counted the drowned rows.",
    "THE DROWNED came at night.",
}
local caps_doc = newMockDoc(CAPS_PARAS, { { 1, 0 }, { 2, 0 }, { 3, 0 } })
caps_doc.file = "/books/caps.epub"
local CAPS_DATA = { characters = { { name = "The Drowned" } } }
local CAPS_SCANNED = XrayIndex.scan(caps_doc, { "the drowned" }, 1, 3)
local CAPS_LAYOUT = { stamp = "C1", forms = CAPS_SCANNED }
local function drownedSet(capitals)
    local data = { characters = { { name = "The Drowned" } } }
    if capitals then
        XrayParser.mergeUserAliases(data, { ["The Drowned"] = { case = { ["the drowned"] = "capitals" } } })
    end
    return XrayParser.matchTermSet(data.characters[1]), data
end
TestRunner:test("the index records each occurrence's capitals", function()
    TestRunner:eq(CAPS_SCANNED["the drowned"], "1:18m2.45m0,1:16m0,1:1us",
        "the Drowned, the drowned; the drowned; THE DROWNED (every word capitalized: no mark; in capitals, a sentence start)")
    local d = XrayIndex.decode(CAPS_LAYOUT, "the drowned")
    TestRunner:eq(table.concat(d.pages, ","), "1,2,3")
    TestRunner:eq(d.caps[1][1], 2)
    TestRunner:eq(d.caps[1][2], 0)
    TestRunner:eq(d.caps[3], nil)
end)
TestRunner:test("counts and spacing follow capitals only, with no new pass", function()
    local any = drownedSet(false)
    local counts, total = XrayIndex.entityPages(CAPS_LAYOUT, any, nil)
    TestRunner:eq(total, 4, "any case: all four")
    TestRunner:eq(counts[2], 1)
    local caps = drownedSet(true)
    counts, total = XrayIndex.entityPages(CAPS_LAYOUT, caps, nil)
    TestRunner:eq(total, 2, "capitals only: the faction twice")
    TestRunner:eq(counts[1], 1)
    TestRunner:eq(counts[2], nil, "the drowned rows are not a mention")
    TestRunner:eq(counts[3], 1)
    TestRunner:eq(XrayIndex.prevPage(CAPS_LAYOUT, caps, nil, 3), 1, "the spacing skips page 2")
    TestRunner:eq(XrayIndex.prevPage(CAPS_LAYOUT, any, nil, 3), 2)
end)
TestRunner:test("the marks: a capitals-only name underlines only where the text has its capitals", function()
    local caps_ui = { document = caps_doc }
    caps_doc.current_page = 1
    local _any_set, any_data = drownedSet(false)
    local any_state = { entities = XrayParser.buildMarkEntities(any_data), spacing = 0, file = caps_doc.file }
    TestRunner:eq(markNames(XrayMarks._computeMarks(any_state, caps_ui, 1, 1, "none"))["The Drowned"], 2)
    local _caps_set, caps_data = drownedSet(true)
    local caps_state = { entities = XrayParser.buildMarkEntities(caps_data), spacing = 0, file = caps_doc.file }
    local marks = XrayMarks._computeMarks(caps_state, caps_ui, 1, 1, "none")
    TestRunner:eq(markNames(marks)["The Drowned"], 1, "the faction, not the drowned trees")
    caps_doc.current_page = 2
    TestRunner:eq(markNames(XrayMarks._computeMarks(caps_state, caps_ui, 2, 2, "none"))["The Drowned"], nil)
    caps_doc.current_page = 3
    TestRunner:eq(markNames(XrayMarks._computeMarks(caps_state, caps_ui, 3, 3, "none"))["The Drowned"], 1,
        "all-caps text passes")
end)
TestRunner:test("a selection routes to the entry only with its capitals; a typed search still lists it", function()
    local _set, data = drownedSet(true)
    local route = {}
    XrayParser.foldExactHandles(data, route)
    TestRunner:ok(not XrayParser.matchExactHandle(route, "the drowned"), "the everyday phrase opens the dictionary")
    TestRunner:ok(XrayParser.matchExactHandle(route, "the Drowned"))
    TestRunner:ok(XrayParser.matchExactHandle(route, "THE DROWNED"))
    TestRunner:eq(#XrayParser.searchAll(data, "the drowned", { exact = true }), 0, "no direct hit")
    TestRunner:eq(#XrayParser.searchAll(data, "the Drowned", { exact = true }), 1)
    TestRunner:eq(#XrayParser.searchAll(data, "the drowned"), 1, "the list finds it")
    -- an any-case handle of another entry under the same key still routes
    XrayParser.foldExactHandles({ characters = { { name = "the drowned" } } }, route)
    TestRunner:ok(XrayParser.matchExactHandle(route, "the drowned"))
end)
TestRunner:test("the PDF hits and KOReader's search: the same capitals", function()
    local _set, data = drownedSet(true)
    local terms = XrayParser.collectSearchTerms(data.characters[1])
    TestRunner:eq(terms[1].caps, 2)
    TestRunner:eq(terms[1].words, 2)
    TestRunner:ok(not XrayParser.textCapsOk("the drowned", terms[1].caps, terms[1].words))
    TestRunner:ok(XrayParser.textCapsOk("the Drowned,", terms[1].caps, terms[1].words), "punctuation rides along")
    TestRunner:ok(XrayParser.textCapsOk("the drowned rows", terms[1].caps, terms[1].words),
        "another word count: unreadable, counted")
    TestRunner:eq(XrayParser.caseSearchRegex("The Drowned", 2), "[tT][hH][eE]\\s+D[rR][oO][wW][nN][eE][dD]")
    TestRunner:eq(XrayParser.caseSearchRegex("Élodie", 1), "\\u00C9[lL][oO][dD][iI][eE]",
        "non-ASCII as code points (crengine's regex)")
    TestRunner:eq(XrayParser.caseSearchRegex("St. Vale", 0), "[sS][tT]\\.\\s+[vV][aA][lL][eE]", "any case, escaped")
    local example, lower = XrayParser.capsExample("The Drowned")
    TestRunner:eq(example, "the Drowned")
    TestRunner:eq(lower, "the drowned")
    TestRunner:eq(XrayParser.capsExample("the grafter"), nil, "nothing to offer")
end)

print("  [Automatic capitals (B533 S3)]")
TestRunner:test("startsSentence: a paragraph's start or after a sentence end; an abbreviation's period may end one (B599)", function()
    for _idx, before in ipairs({ "", "  \226\128\156", "It rained. ", "Who came? ", "He said: ",
            "Wait\226\128\166 ", "\"Go home.\" ", "(It rained.) ",
            -- a period after an abbreviation or a single letter: counted as a
            -- start, which proves nothing ("No. Summer" is no evidence either way)
            "Mr. ", "J. ", "No. ", "i. ", "Jan. ", "Ed. ",
            -- the guillemets both ways, the low German quotes, the inverted Spanish marks
            "\194\171", "He said: \194\171", "\194\171Go home.\194\187 ", "\226\128\158", "\226\128\158Go home.\226\128\156 ",
            "\194\191", "\194\161", "\226\128\185", "\226\128\185Go.\226\128\186 " }) do
        TestRunner:ok(XrayParser.startsSentence(before), "starts after: " .. before)
    end
    for _idx, before in ipairs({ "past the ", "He met her, ", "a\226\128\148", "the No ", "no. 5 and the " }) do
        TestRunner:ok(not XrayParser.startsSentence(before), "mid-sentence after: " .. before)
    end
end)
TestRunner:test("allCaps and capsEvidence: what one occurrence says about a name", function()
    TestRunner:ok(XrayParser.allCaps("THE DROWNED"))
    TestRunner:ok(not XrayParser.allCaps("The Drowned"))
    TestRunner:ok(not XrayParser.allCaps("A"), "one capital is a word, not capitals")
    -- "The Drowned": its second word's capital required (2)
    TestRunner:eq(XrayParser.capsEvidence(2, 2, false, false), "P", "the Drowned mid-sentence")
    TestRunner:eq(XrayParser.capsEvidence(2, 0, false, false), "L", "the drowned")
    TestRunner:eq(XrayParser.capsEvidence(2, 3, true, false), "P", "a sentence start leaves the second capital telling")
    TestRunner:eq(XrayParser.capsEvidence(2, 3, false, true), nil, "THE DROWNED proves nothing")
    -- "Summer": one word, its capital required (1)
    TestRunner:eq(XrayParser.capsEvidence(1, 1, true, false), nil, "a sentence start proves nothing")
    TestRunner:eq(XrayParser.capsEvidence(1, 1, false, false), "P")
    TestRunner:eq(XrayParser.capsEvidence(1, 0, false, false), "L")
    TestRunner:eq(XrayParser.capsEvidence(7, 5, false, false), nil, "some of the capitals, not all")
end)
TestRunner:test("autoCapsSwitch: written both ways, the capitalized way no stray", function()
    TestRunner:ok(XrayParser.autoCapsSwitch(3, 1))
    TestRunner:ok(not XrayParser.autoCapsSwitch(2, 1), "three at least")
    TestRunner:ok(not XrayParser.autoCapsSwitch(9, 0), "never in lowercase: nothing to gain")
    TestRunner:ok(XrayParser.autoCapsSwitch(3, 9), "a quarter")
    TestRunner:ok(not XrayParser.autoCapsSwitch(3, 10), "under a quarter: a name the book writes in lowercase")
end)
TestRunner:test("paragraphStarts: each paragraph's place in the page's folded text", function()
    local function starts(text)
        local list = XrayIndex.paragraphStarts(text, #XrayParser.matchNormalize(text))
        return list and table.concat(list, ",") or "nil"
    end
    TestRunner:eq(starts("A b.\nC d."), "1,6")
    TestRunner:eq(starts("\nA"), "2", "a leading break is a space")
    TestRunner:eq(starts("A\n"), "1")
    TestRunner:eq(starts("A \n  B"), "1,3", "a space run across the break is one space")
    TestRunner:eq(starts("A\n\n\nB"), "1,3")
    TestRunner:eq(starts("A\n   \nB"), "1,3")
    TestRunner:eq(starts("\195\132 b\n  \195\150"), "1,6", "folded letters keep their length")
    TestRunner:eq(starts("One\194\160two\nThree"), "1,9", "a no-break space folds like the whole")
    TestRunner:eq(XrayIndex.paragraphStarts("A\nB", 99), nil, "a sum that misses: unknown")
end)
local AUTO_PARAS = {
    "THE DROWNED",
    "Out on the water the Drowned lit fires past the drowned trees.",
    "Tamsin said the Drowned had come back. The Drowned were singing.",
    "Summer came late. In the summer the rows flooded, and summer rain fell on Summer and Tamsin.",
}
local auto_doc = newMockDoc(AUTO_PARAS, { { 1, 0 }, { 2, 0 }, { 3, 0 }, { 4, 0 } })
local AUTO_DATA = { type = "fiction", characters = {
    { name = "The Drowned" }, { name = "Summer" }, { name = "Tamsin" },
}, __dormant = { { name = "the Hollow Men", category = "characters", source = "Vol 1" } } }
local auto_forms = {}
for _idx, item in ipairs(AUTO_DATA.characters) do
    for _f, f in ipairs(XrayParser.matchTermSet(item).all) do auto_forms[#auto_forms + 1] = f end
end
local AUTO_LAYOUT = { stamp = "A1", forms = XrayIndex.scan(auto_doc, auto_forms, 1, 4) }
TestRunner:test("a name is judged on the layout that holds its forms, the newest first (B597)", function()
    -- after a font change the new forms go into the layout in use only: the
    -- newer layout holds The Drowned's forms, the older one everything else
    local drowned, others = {}, {}
    local drowned_forms = XrayParser.matchTermSet({ name = "The Drowned" }).all
    local is_drowned = {}
    for _idx, f in ipairs(drowned_forms) do is_drowned[f] = true end
    for f, enc in pairs(AUTO_LAYOUT.forms) do
        if is_drowned[f] then drowned[f] = enc else others[f] = enc end
    end
    local newer, older = { stamp = "A2", forms = drowned }, { stamp = "A1", forms = others }
    local n_new, n_old = 0, 0
    for _f in pairs(drowned) do n_new = n_new + 1 end
    for _f in pairs(others) do n_old = n_old + 1 end
    TestRunner:ok(n_old > n_new, "the older layout holds more forms")
    TestRunner:eq(XrayIndex.layoutHolding({ newer, older }, drowned_forms), newer, "The Drowned: the newer layout")
    TestRunner:eq(XrayIndex.layoutHolding({ newer, older }, XrayParser.matchTermSet({ name = "Summer" }).all), older, "Summer: the older")
    TestRunner:eq(XrayIndex.layoutHolding(older, drowned_forms), nil, "one layout without the forms: nothing")
    TestRunner:eq(XrayIndex.layoutHolding({ older }, { "nowhere" }), nil)
    TestRunner:eq(XrayIndex.layoutHolding(AUTO_LAYOUT, drowned_forms), AUTO_LAYOUT, "a single layout as before")
    local auto = XrayIndex.autoCaps({ newer, older }, AUTO_DATA)
    TestRunner:ok(auto["the drowned"], "judged on the newer layout, switched")
    TestRunner:eq(next(XrayIndex.autoCaps(older, AUTO_DATA)), nil, "the layout with the most forms alone would not judge it")
    local src = assert(io.open(PLUGIN_DIR .. "/koassistant/artifacts/action_cache.lua", "r")):read("*a")
    TestRunner:ok(src:find("XrayIndex.layoutHolding(judgedLayouts(document_path), set.all)", 1, true) ~= nil, "capsCounts reads the layout holding the name")
    TestRunner:ok(src:find("XrayIndex.autoCaps(layouts, data, judged)", 1, true) ~= nil, "autoCaps passes every current layout")
    TestRunner:ok(src:find("local function bestLayout", 1, true) == nil, "the most-forms pick is gone")
end)
TestRunner:test("capsEvidence: how the book writes a name, read from the index", function()
    local set = XrayParser.matchTermSet({ name = "The Drowned", _caps = { ["the drowned"] = true } })
    local p, l = XrayIndex.capsEvidence(AUTO_LAYOUT, set, nil)
    TestRunner:eq(p .. "/" .. l, "3/1", "three with the capital (one opening a sentence), one without; the heading in capitals proves nothing")
    set = XrayParser.matchTermSet({ name = "Summer", _caps = { summer = true } })
    p, l = XrayIndex.capsEvidence(AUTO_LAYOUT, set, nil)
    TestRunner:eq(p .. "/" .. l, "1/2", "the sentence start proves nothing")
    TestRunner:eq(XrayIndex.capsEvidence({ forms = {} }, set, nil), nil, "not indexed: not judged")
end)
TestRunner:test("automatic capitals read only the book file as it is now (replaced, generated again)", function()
    -- a folder of its own: the index file the other tests share stays as it is
    local ds = package.loaded["docsettings"]
    local saved_dir = ds.getSidecarDir
    local dir = SIDECAR .. "/regenerated"
    os.execute('mkdir -p "' .. dir .. '"')
    ds.getSidecarDir = function() return dir end
    local ok, err = pcall(function()
        XrayIndex.stop(true)
        local ActionCache = require("koassistant.artifacts.action_cache")
        local book = dir .. "/book.epub"
        local f = io.open(book, "wb")
        f:write(string.rep("x", 7761))
        f:close()
        -- the earlier text, indexed first and holding more forms, never wrote
        -- the name with its capitals
        local old = { ["grey cat"] = "" }
        for k in pairs(AUTO_LAYOUT.forms) do old[k] = "" end
        XrayIndex.store(book, "H0:4:7711", old)
        XrayIndex.store(book, "H1:4:7761", AUTO_LAYOUT.forms)
        local cur = XrayIndex.currentLayouts(book)
        TestRunner:eq(#cur, 1, "one layout of the file as it is now")
        TestRunner:eq(cur[1].stamp, "H1:4:7761")
        TestRunner:ok(ActionCache.autoCaps(book, AUTO_DATA)["the drowned"],
            "this text decides, though the earlier text's layout holds more forms")
        -- replaced again: nothing indexed for this text yet, so any case
        f = io.open(book, "wb")
        f:write(string.rep("x", 7800))
        f:close()
        TestRunner:eq(#XrayIndex.currentLayouts(book), 0)
        TestRunner:eq(next((ActionCache.autoCaps(book, AUTO_DATA))), nil, "until the index has this text")
    end)
    ds.getSidecarDir = saved_dir
    XrayIndex.stop(true)
    if not ok then error(err, 0) end
end)
TestRunner:test("automatic capitals judge the upcoming entities too: the newest built checkpoint past the live X-Ray (#120)", function()
    local ds = package.loaded["docsettings"]
    local saved_dir = ds.getSidecarDir
    local dir = SIDECAR .. "/upcoming"
    os.execute('mkdir -p "' .. dir .. '"')
    ds.getSidecarDir = function() return dir end
    local ok, err = pcall(function()
        XrayIndex.stop(true)
        local ActionCache = require("koassistant.artifacts.action_cache")
        local book = dir .. "/book.epub"
        local f = io.open(book, "wb")
        f:write(string.rep("x", 8123))
        f:close()
        -- the Warden is known from the next checkpoint only; the book writes
        -- it four times with its capital mid-sentence and once without
        local paras = {
            "Out on the water the Drowned lit fires past the drowned trees.",
            "Tamsin said the Drowned had come back. The Drowned were singing.",
            "At the gate the Warden waited; a warden of the marsh is no lord. Then the Warden spoke, and the Warden left, and the Warden slept.",
        }
        local doc = newMockDoc(paras, { { 1, 0 }, { 2, 0 }, { 3, 0 } })
        local live = { type = "fiction", characters = { { name = "The Drowned" }, { name = "Tamsin" } } }
        local rung = { type = "fiction", characters = { { name = "The Drowned" }, { name = "Tamsin" }, { name = "Warden" } } }
        local forms = {}
        for _idx, item in ipairs(rung.characters) do
            for _f, fm in ipairs(XrayParser.matchTermSet(item).all) do forms[#forms + 1] = fm end
        end
        XrayIndex.store(book, "H1:3:8123", XrayIndex.scan(doc, forms, 1, 3))
        TestRunner:eq(ActionCache.autoCaps(book, live)["warden"], nil, "no checkpoint built: the live names alone")
        ActionCache.pushXrayLadderRung(book, { result = XrayParser.serialize(rung), progress_decimal = 0.6, timestamp = 1700000000 })
        local auto = ActionCache.autoCaps(book, live)
        TestRunner:ok(auto["the drowned"], "the live name as before")
        TestRunner:ok(auto["warden"], "the upcoming entity's name judged from the checkpoint")
        -- an introduction is no checkpoint
        ActionCache.clearXrayLadder(book)
        ActionCache.pushXrayLadderRung(book, { result = XrayParser.serialize(rung), progress_decimal = 0, intro = true, timestamp = 1700000001 })
        TestRunner:eq(ActionCache.autoCaps(book, live)["warden"], nil, "an intro rung is skipped")
        ActionCache.clearXrayLadder(book)
        -- the rule's counts, as the names screen shows them
        local p, l = ActionCache.capsCounts(book, "Warden", rung, rung.characters[3])
        TestRunner:eq(tostring(p) .. "/" .. tostring(l), "4/1", "capsCounts: the automatic rule's own numbers")
        TestRunner:eq(ActionCache.capsCounts(book, "Nobody", rung, nil), nil, "not indexed: no counts")
    end)
    ds.getSidecarDir = saved_dir
    XrayIndex.stop(true)
    if not ok then error(err, 0) end
end)
TestRunner:test("autoCaps: the names this book writes both ways switch to capitals only", function()
    local auto = XrayIndex.autoCaps(AUTO_LAYOUT, AUTO_DATA)
    local names = {}
    for n in pairs(auto) do names[#names + 1] = n end
    table.sort(names)
    TestRunner:eq(table.concat(names, ","), "the drowned",
        "Summer too few, Tamsin never in lowercase, the carried name not indexed yet")
    -- the matchers: the automatic choice unless the reader picked
    local data = { type = "fiction", characters = { { name = "The Drowned" }, { name = "Summer" } },
        __dormant = { { name = "The Drowned Host", category = "characters" } } }
    XrayParser.mergeUserAliases(data, { [XrayParser.AUTO_CAPS_KEY] = { ["the drowned"] = true, ["the drowned host"] = true } })
    TestRunner:eq(XrayParser.matchTermSet(data.characters[1]).caps["the drowned"], 2, "set by the rule")
    TestRunner:eq(XrayParser.matchTermSet(data.characters[2]).caps, nil)
    TestRunner:eq(XrayParser.matchTermSet(data.__dormant[1]).caps["the drowned host"], 6, "a carried row takes it too")
    local route = {}
    XrayParser.foldLedgerHandles(data, route)
    TestRunner:ok(not XrayParser.matchExactHandle(route, "the drowned host"), "a carried row routes only with its capitals")
    TestRunner:ok(XrayParser.matchExactHandle(route, "the Drowned Host"))
    TestRunner:eq(#XrayParser.searchLedger(data, "the drowned host", { exact = true }), 0, "no direct hit on the carried row")
    TestRunner:eq(#XrayParser.searchLedger(data, "the Drowned Host", { exact = true }), 1)
    TestRunner:eq(#XrayParser.searchLedger(data, "the drowned host"), 1, "the list still finds it")
    data = { type = "fiction", characters = { { name = "The Drowned" } } }
    XrayParser.mergeUserAliases(data, { ["The Drowned"] = { case = { ["the drowned"] = "any" } },
        [XrayParser.AUTO_CAPS_KEY] = { ["the drowned"] = true } })
    TestRunner:eq(XrayParser.matchTermSet(data.characters[1]).caps, nil, "Any case keeps the rule off the name")
    local marks_state = { entities = XrayParser.buildMarkEntities(data), spacing = 0, file = auto_doc.file }
    auto_doc.current_page = 2
    local before = markNames(XrayMarks._computeMarks(marks_state, { document = auto_doc }, 2, 2, "none"))["The Drowned"]
    data = { type = "fiction", characters = { { name = "The Drowned" } } }
    XrayParser.mergeUserAliases(data, { [XrayParser.AUTO_CAPS_KEY] = { ["the drowned"] = true } })
    marks_state = { entities = XrayParser.buildMarkEntities(data), spacing = 0, file = auto_doc.file }
    local after = markNames(XrayMarks._computeMarks(marks_state, { document = auto_doc }, 2, 2, "none"))["The Drowned"]
    TestRunner:eq(before .. " -> " .. after, "2 -> 1", "the underline leaves \"the drowned trees\"")
end)

TestRunner:suite("the sweep of 2026-11-06: the word boundary per script, the kept index pass, the hashed containment")

TestRunner:test("a name of a script with word boundaries counts whole words only; CJK and Arabic as before", function()
    local function count(name, text)
        return #XrayParser._collectMatchSpans(XrayParser.matchNormalize(text), XrayParser.matchNormalize(name))
    end
    TestRunner:eq(count("Lệ", "Anh ra lệnh."), 0, "Vietnamese inside a word")
    TestRunner:eq(count("Lệ", "Cô Lệ đến."), 1, "Vietnamese whole word")
    TestRunner:eq(count("Hà", "Hàng"), 0, "a 2-byte-only Vietnamese name inside a word")
    TestRunner:eq(count("राम", "वह आराम से"), 0, "Devanagari inside a word")
    TestRunner:eq(count("राम", "राम आया"), 1, "Devanagari whole word")
    TestRunner:eq(count("राम", "राम। आया"), 1, "the danda is no word character")
    TestRunner:eq(count("דן", "גן עדן"), 0, "Hebrew inside a word")
    TestRunner:eq(count("דן", "דן בא"), 1, "Hebrew whole word")
    TestRunner:eq(count("דן", "בית־דן"), 1, "the maqaf is no word character")
    TestRunner:eq(count("Ἀχιλλεύς", "XἈχιλλεύςY"), 0, "polytonic Greek inside a word")
    TestRunner:eq(count("ნინო", "ნინოს"), 0, "Georgian inside a word")
    TestRunner:eq(count("Ян", "Янтарь"), 0, "Cyrillic inside a word (as before)")
    TestRunner:eq(count("Lea", "Leap"), 0, "Latin inside a word (as before)")
    TestRunner:eq(count("東京", "私は東京に住む"), 1, "CJK: no boundary needed (as before)")
    TestRunner:eq(count("สมชาย", "คุณสมชายมา"), 1, "Thai: no boundary needed")
    TestRunner:eq(count("한국", "대한국민"), 1, "Hangul: no boundary needed")
    TestRunner:eq(count("نار", "النار"), 1, "Arabic: the article prefix rule (as before)")
    TestRunner:ok(XrayParser._skipBoundaryCheck("東京") and XrayParser._skipBoundaryCheck("نار"), "the seam")
    TestRunner:ok(not XrayParser._skipBoundaryCheck("Lệ") and not XrayParser._skipBoundaryCheck("דן"), "the seam")
end)

TestRunner:test("the marks standing down keep the name index's pass; a close drops it", function()
    local saved_in, saved_un = UIManager.scheduleIn, UIManager.unschedule
    local scheduled = {}
    UIManager.scheduleIn = function(_s, _d, fn) scheduled[fn] = true end
    UIManager.unschedule = function(_s, fn) scheduled[fn] = nil end
    local function n() local c = 0 for _ in pairs(scheduled) do c = c + 1 end return c end
    local doc = { file = SIDECAR .. "/kept.epub", getPageXPointer = function() return "" end,
        info = { number_of_pages = 300 }, getDocumentRenderingHash = function() return 1234 end,
        getCurrentPage = function() return 1 end }
    local ui = { document = doc, rolling = {}, view = { view_modules = {} } }
    XrayIndex.stop(true)
    local layout = XrayIndex.ready(ui, { "anna", "boris" })
    TestRunner:eq(layout, nil, "nothing stored yet")
    TestRunner:eq(n(), 1, "the pass is queued")
    local plugin = { ui = ui, settings = { readSetting = function() return { xray_marking = false } end } }
    XrayMarks.sync(plugin)
    TestRunner:eq(n(), 1, "the marks off: the pass stays queued (Mentions reads it)")
    XrayMarks.teardown(plugin)
    TestRunner:eq(n(), 0, "a plain teardown (the book closes) drops it")
    UIManager.scheduleIn, UIManager.unschedule = saved_in, saved_un
end)

TestRunner:test("the hashed containment pass gives the pairwise pass's answer", function()
    local data = XrayParser.parse(require("json").encode({ type = "fiction", characters = {
        { name = "Vivian Kubrick", aliases = { "Viv" }, description = "d" },
        { name = "Kubrick", description = "d" },
        { name = "Jean-Luc Picard", description = "d" },
        { name = "Luc", description = "d" },
        { name = "Jean-Luc", description = "d" },
        { name = "O'Brien", description = "d" },
        { name = "Miles O'Brien", description = "d" },
        { name = "Brien", description = "d" },
        { name = "Anna", description = "d" },
        { name = "Anna Karenina", aliases = { "Karenina" }, description = "d" },
        { name = "東京", description = "d" },
        { name = "東京タワー", description = "d" },
        { name = "نار", description = "d" },
        { name = "النار الكبيرة", description = "d" },
        { name = "Mr Kubrick", description = "d" },
    } }))
    local function build()
        local ents = XrayParser.buildMarkEntities(data)
        for _i, e in ipairs(ents) do e.longer, e.handles = nil, nil end
        return ents
    end
    -- the pairwise pass as it was (the reference)
    local function pairwise(ents)
        for i, a in ipairs(ents) do
            local longer, handles, seen_h
            if a.set then
                for j, b in ipairs(ents) do
                    if i ~= j and b.set then
                        local hit = false
                        for _tb, tb in ipairs(b.set.all) do
                            for _ta, ta in ipairs(a.set.minimal) do
                                if #tb > #ta and tb:find(ta, 1, true)
                                        and XrayParser.handleContainsWord(tb, ta) then
                                    hit = true
                                    seen_h = seen_h or {}
                                    if not seen_h[tb] then
                                        seen_h[tb] = true
                                        handles = handles or {}
                                        handles[#handles + 1] = tb
                                    end
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
            end
            if longer then table.sort(longer) end
            if handles then table.sort(handles) end
            a.longer, a.handles = longer, handles
        end
        return ents
    end
    local ref = pairwise(build())
    local got = build()
    XrayMarks._containment(got, XrayParser)
    local function list(t) return t and table.concat(t, ",") or "-" end
    local hits = 0
    for i = 1, #ref do
        TestRunner:eq(list(got[i].longer), list(ref[i].longer), "longer of " .. tostring(ref[i].name))
        TestRunner:eq(list(got[i].handles), list(ref[i].handles), "handles of " .. tostring(ref[i].name))
        if ref[i].longer then hits = hits + 1 end
    end
    TestRunner:ok(hits >= 6, "the fixture holds contained names (" .. hits .. ")")
end)

os.execute('rm -rf "' .. SIDECAR .. '"')
print(string.format("  Results: %d passed, %d failed", TestRunner.passed, TestRunner.failed))
return TestRunner.failed == 0
