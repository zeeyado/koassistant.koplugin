-- The reader's place after a text extraction (B646). KOReader caches some
-- engine answers per view (credocument.lua's call cache, on by default): its
-- tag follows gotoPage and gotoPos, never gotoXPointer, and getXPointer is a
-- cached answer. An extraction that came back with gotoXPointer alone left
-- the cache answering for the page it had jumped to: the reading position
-- read before the next repaint was the extraction's end (a checkpoint ahead
-- of the reader installed with spoiler protection on) or the book's start.
-- The fake document below models that cache; the mock of
-- test_document_end_xpointer.lua does not, which is why the suite never saw
-- it. The numbers below (0.01, 0.67) are the ones the installed app gave
-- before the fix.
--
-- Run: lua tests/unit/test_extract_place.lua  (or lua tests/run_tests.lua --unit)

local function setupPaths()
    local info = debug.getinfo(1, "S")
    local script_path = info.source:match("@?(.*)")
    local unit_dir = script_path:match("(.+)/[^/]+$") or "."
    local tests_dir = unit_dir:match("(.+)/[^/]+$") or "."
    local plugin_dir = tests_dir:match("(.+)/[^/]+$") or "."
    package.path = table.concat({
        plugin_dir .. "/?.lua",
        plugin_dir .. "/koassistant/api/?.lua",
        tests_dir .. "/?.lua",
        tests_dir .. "/lib/?.lua",
        package.path,
    }, ";")
end
setupPaths()
require("mock_koreader")
local ContextExtractor = require("koassistant.request.context_extractor")

local TestRunner = { passed = 0, failed = 0 }
function TestRunner:suite(name) print(string.format("\n  [%s]", name)) end
function TestRunner:test(name, fn)
    local ok, err = pcall(fn)
    if ok then self.passed = self.passed + 1; print("    ok   " .. name)
    else self.failed = self.failed + 1; print("    FAIL " .. name); print("      " .. tostring(err)) end
end
function TestRunner:assertEqual(actual, expected, msg)
    if actual ~= expected then
        error(string.format("%s: expected %s, got %s", msg or "assert",
            tostring(expected), tostring(actual)), 2)
    end
end

-- A fake CRE document with KOReader's call cache, under the names KOReader
-- gives its fields: pages 1..N, the engine's own page in `engine`, the
-- current tag in _current_call_cache_tag and that tag's answers in
-- _tag_call_cache; getXPointer is answered from there when it holds one.
-- opts.no_cache = the reader switched the cache off (no tag functions at
-- all); opts.untagged = no view tagged yet; opts.fail_text =
-- getTextFromXPointers throws.
local function makeDoc(opts)
    opts = opts or {}
    local N = opts.pages or 100
    local doc = {
        info = { number_of_pages = N, has_pages = false },
        engine = opts.page or 40,
    }
    local tags = {}
    local function pageOf(xp)
        if xp == "xp_end" then return N end
        return tonumber(tostring(xp):match("(%d+)$")) or 1
    end
    local function setTag(tag)
        tags[tag] = tags[tag] or {}
        doc._tag_call_cache = tags[tag]
        doc._current_call_cache_tag = tag
    end
    function doc:gotoPage(p) if not opts.no_cache then setTag("page" .. p) end; self.engine = p end
    function doc:gotoPos(pos) if not opts.no_cache then setTag("pos" .. pos) end; self.engine = 1 end
    -- the engine moves, the cache's tag does not: KOReader's own rule
    function doc:gotoXPointer(xp) self.engine = pageOf(xp) end
    function doc:getXPointer()
        local slot = self._tag_call_cache
        if slot and slot.xp then return slot.xp end
        local xp = "xp_p" .. self.engine
        if slot then slot.xp = xp end
        return xp
    end
    function doc:getCurrentPage() return self.engine end
    function doc:getPageFromXPointer(xp) return pageOf(xp) end
    function doc:getPageXPointer(p) if p > N then return "" end; return "xp_p" .. p end
    function doc:getTextFromPositions()
        if self.engine == N then return { text = "last", pos0 = "xp_p" .. N, pos1 = "xp_end" } end
        return { pos1 = "xp_p" .. (self.engine + 1) }
    end
    function doc:compareXPointers(a, b)
        local ra = a == "xp_end" and N + 0.5 or pageOf(a)
        local rb = b == "xp_end" and N + 0.5 or pageOf(b)
        if rb > ra then return 1 elseif rb < ra then return -1 else return 0 end
    end
    function doc:getTextFromXPointers(a, b)
        if opts.fail_text then error("the engine failed") end
        return "text:" .. a .. "->" .. b
    end
    if not opts.no_cache then
        doc._callCacheGetCurrentTag = function() return doc._current_call_cache_tag end
        doc._callCacheSetCurrentTag = setTag
        -- KOReader painted the reader's page: the tag is that page's
        if not opts.untagged then doc:gotoPage(doc.engine) end
    end
    return doc
end

local function extractor(doc)
    return ContextExtractor:new({ document = doc }, { enable_book_text_extraction = true })
end
local function position(doc)
    return extractor(doc):getReadingProgress().decimal
end

TestRunner:suite("the fake document behaves like KOReader's cache")

TestRunner:test("a jump restored with gotoXPointer alone leaves the cache on the jump's page", function()
    local doc = makeDoc()
    local xp0 = doc:getXPointer()
    doc:gotoPage(96)
    doc:getXPointer()
    doc:gotoXPointer(xp0)
    TestRunner:assertEqual(doc:getCurrentPage(), 40, "the engine is back on the reader's page")
    TestRunner:assertEqual(doc:getXPointer(), "xp_p96", "the cache still answers for page 96")
end)

TestRunner:suite("the reading position after an extraction")

local function check(name, run, opts)
    TestRunner:test(name, function()
        local doc = makeDoc(opts)
        local before = position(doc)
        TestRunner:assertEqual(before, 0.4, "the position before")
        run(extractor(doc), doc)
        TestRunner:assertEqual(doc:getCurrentPage(), 40, "the engine's page after")
        TestRunner:assertEqual(position(doc), before, "the position the plugin reads after")
        if not (opts and (opts.no_cache or opts.untagged)) then
            TestRunner:assertEqual(doc._current_call_cache_tag, "page40", "the cache's tag after")
        end
    end)
end

check("text up to the position (the walk goes to the book's start)",
    function(ex) ex:getBookText({}) end)
check("a range inside the book (the walk ends on the range's last page)",
    function(ex) ex:getBookTextRange(0.1, 0.67, {}) end)
check("a range to the book's end (a nested walk to the last page)",
    function(ex) ex:getBookTextRange(0.4, 1, {}) end)
check("the whole document",
    function(ex) ex:getFullDocumentText({}) end)
check("the document's end bound alone",
    function(_ex, doc) ContextExtractor.documentEndXPointer(doc, 100) end)
check("a walk that fails midway",
    function(ex) ex:getBookTextRange(0.1, 0.67, {}) end, { fail_text = true })
check("with KOReader's cache switched off",
    function(ex) ex:getBookTextRange(0.1, 0.67, {}) end, { no_cache = true })
check("before any view was tagged",
    function(ex) ex:getBookTextRange(0.1, 0.67, {}) end, { untagged = true })

TestRunner:test("a page the walk visited keeps no answer of another page", function()
    -- the walk to the last page must not leave the last page's tag holding the
    -- reader's position: KOReader would read it back when the reader gets there
    local doc = makeDoc()
    extractor(doc):getBookTextRange(0.4, 1, {})
    position(doc)
    doc:gotoPage(100)
    TestRunner:assertEqual(doc:getXPointer(), "xp_p100", "the last page answers for itself")
end)

print(string.format("\n  Results: %d passed, %d failed", TestRunner.passed, TestRunner.failed))
return TestRunner.failed == 0
