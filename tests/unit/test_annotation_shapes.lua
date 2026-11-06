-- KOReader's annotations list holds page bookmarks beside the highlights (no
-- drawer, the page's first words as text). ContextExtractor.isHighlight is
-- THE rule, and every reader of the list that means highlights asks it (the
-- sweep of 2026-11-06): the two formatters, the funnel's two counts and the
-- X-Ray browser's highlight matches.
--
-- Run: lua tests/unit/test_annotation_shapes.lua  (or lua tests/run_tests.lua --unit)

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
local plugin_dir = setupPaths()
require("mock_koreader")
local TestRunner = require("test_runner"):new()
local CE = require("koassistant.request.context_extractor")

local function read(rel)
    local f = assert(io.open(plugin_dir .. "/" .. rel, "r"))
    local s = f:read("*a")
    f:close()
    return s
end

print("Running: test_annotation_shapes")
print("")

-- the shapes ReaderBookmark:toggleBookmark and ReaderHighlight create
local bookmark = { page = "/body/DocFragment[3]", text = "in Ch3", chapter = "Ch3" }
local highlight = { drawer = "lighten", text = "real hl", chapter = "Ch3", pos0 = "a", pos1 = "b" }
local noted = { drawer = "underscore", text = "noted hl", note = "my note", pageno = 12 }

TestRunner:test("isHighlight: a drawer and a text; a page bookmark is neither", function()
    TestRunner:assertTrue(CE.isHighlight(highlight))
    TestRunner:assertTrue(CE.isHighlight(noted))
    TestRunner:assertFalse(CE.isHighlight(bookmark), "a page bookmark")
    TestRunner:assertFalse(CE.isHighlight({ drawer = "lighten", text = "" }), "an empty text")
    TestRunner:assertFalse(CE.isHighlight("x"))
    TestRunner:assertFalse(CE.isHighlight(nil))
end)

TestRunner:test("the formatters count and list the highlights only", function()
    local h = CE.formatHighlights({ bookmark, highlight, noted })
    TestRunner:assertEqual(h.count, 2)
    TestRunner:assertTrue(h.formatted:find("real hl", 1, true) ~= nil)
    TestRunner:assertTrue(h.formatted:find("in Ch3", 1, true) == nil, "the bookmark's page words are not a highlight")
    local a = CE.formatAnnotations({ bookmark, highlight, noted })
    TestRunner:assertEqual(a.count, 2)
    TestRunner:assertTrue(a.formatted:find("[Note: my note]", 1, true) ~= nil)
    TestRunner:assertTrue(a.formatted:find("in Ch3", 1, true) == nil)
end)

TestRunner:test("the funnel's counts and the X-Ray browser's matches ask the rule", function()
    local da = read("koassistant/ui/data_access.lua")
    local n = select(2, da:gsub('require%("koassistant%.request%.context_extractor"%)%.isHighlight%(a%)', ""))
    TestRunner:assertEqual(n, 2, "the amounts and the exists counts")
    TestRunner:assertTrue(da:find('type(a) == "table" and type(a.text) == "string" and a.text ~= ""', 1, true) == nil, "no own rule left")
    local xb = read("koassistant/xray/xray_browser.lua")
    TestRunner:assertTrue(xb:find("if isHighlight(annotation) then", 1, true) ~= nil, "findItemHighlights")
    local ce = read("koassistant/request/context_extractor.lua")
    TestRunner:assertEqual(select(2, ce:gsub("if ContextExtractor%.isHighlight%(annotation%) then", "")), 2, "both formatters")
end)

return TestRunner:summary()
