-- #116 / B393: carried entries inside the X-Ray categories, and the carried
-- list opening by category. These run the browser's own page builders against
-- a recording menu (no KOReader widgets), so a page that would crash or list
-- the wrong rows fails here and not on the device:
--   * dial off: every page is what it was (counts, titles, rows)
--   * dial on: a category row counts both ("2 + 3"), a category with carried
--     entries only appears, a category page lists its own entries, the header,
--     then that kind's carried entries in name order with role and source
--   * the carried list opens on category rows; "All" is the old flat page
--   * after a carried-list edit the page on screen and the pages under it are
--     rebuilt, and an emptied page pops back
--   * project groups get their own wording
--
-- Run: lua tests/unit/test_xray_browser_carried.lua  (or lua tests/run_tests.lua --unit)

local function setupPaths()
    local info = debug.getinfo(1, "S")
    local script_path = info.source:match("@?(.*)")
    local unit_dir = script_path:match("(.+)/[^/]+$") or "."
    local tests_dir = unit_dir:match("(.+)/[^/]+$") or "."
    local plugin_dir = tests_dir:match("(.+)/[^/]+$") or "."
    package.path = table.concat({
        plugin_dir .. "/?.lua",
        plugin_dir .. "/koassistant_api/?.lua",
        tests_dir .. "/?.lua",
        tests_dir .. "/lib/?.lua",
        package.path,
    }, ";")
end
setupPaths()
require("mock_koreader")
local TestRunner = require("test_runner"):new()

-- ------------------------------------------------------------------ stubs
-- One Lua process runs every test file: everything replaced here is put back
-- at the end.
local saved = {}
local function stub(name, value)
    saved[#saved + 1] = { name = name, value = package.loaded[name] }
    package.loaded[name] = value
end
local function class()
    local C = {}
    function C:new(o) return setmetatable(o or {}, { __index = self }) end
    function C:extend(o) return setmetatable(o or {}, { __index = self }) end
    return C
end
for _idx, name in ipairs({ "ui/event", "ui/widget/menu", "ui/widget/textviewer" }) do
    if not package.loaded[name] then stub(name, class()) end
end
-- The right-column fitter measures text: eight units a byte is enough here
stub("ui/widget/textwidget", {
    new = function(_self, o)
        return { getSize = function() return { w = #(o.text or "") * 8 } end, free = function() end }
    end,
})
local util = require("util")
local saved_split = rawget(util, "splitToChars")
rawset(util, "splitToChars", function(text)
    local chars = {}
    for ch in text:gmatch("[%z\1-\127\194-\244][\128-\191]*") do chars[#chars + 1] = ch end
    return chars
end)
-- The browser keeps the screen it finds when it loads. An earlier test file
-- may have left another "device" in place, so this one brings its own.
stub("device", {
    screen = {
        getWidth = function() return 800 end,
        getHeight = function() return 600 end,
        scaleBySize = function(_self, n) return n end,
    },
    isTouchDevice = function() return false end,
    hasKeys = function() return false end,
})
stub("ui/font", { getFace = function() return {} end })
stub("ui/size", { padding = { default = 0, large = 0, fullscreen = 0 }, margin = { default = 0 },
    line = { thick = 1 }, border = { default = 1 } })

-- The group the open book is in, and the dial's value, set per test
local group_kind = "series"
local GROUP_BOOKS = { "/b/vol1.epub", "/b/vol2.epub", "/b/vol3.epub" }
stub("koassistant_book_groups", {
    KIND_SERIES = "series", KIND_PROJECT = "project", KIND_PLAIN = "plain",
    groupsFor = function() return { { id = "g1", name = "The Saga", kind = group_kind, books = GROUP_BOOKS } } end,
    kindOf = function(g) return g.kind end,
})
local dial
local SDS = require("koassistant_doc_settings")
local saved_resolve = SDS.resolve
SDS.resolve = function()
    return { readSetting = function(_self, key)
        if key == "koassistant_book_xray_carried" then return dial end
        return nil
    end }
end
-- The artifact cache loads against the minimal mocks the other test files use
_G.G_reader_settings = _G.G_reader_settings or {
    _store = {},
    readSetting = function(self, key, default)
        local v = self._store[key]
        if v == nil then return default end
        return v
    end,
    saveSetting = function(self, key, value) self._store[key] = value end,
    flush = function() end,
}
package.loaded["docsettings"] = package.loaded["docsettings"] or {
    getSidecarDir = function(_self, _doc_path, _force) return "/tmp" end,
    isHashLocationEnabled = function() return false end,
}
local ActionCache = require("koassistant_action_cache")
local saved_artifacts = ActionCache.getAvailableArtifactsWithPinned
ActionCache.getAvailableArtifactsWithPinned = function() return {} end
-- The book's never-merge list, in memory: the carried list reads it each time
-- it opens (the review of likely matches), and no test may read a real file
local never_pairs = {}
local saved_get_never, saved_add_never = ActionCache.getNeverMergePairs, ActionCache.addNeverMergePair
ActionCache.getNeverMergePairs = function() return never_pairs end
ActionCache.addNeverMergePair = function(_file, a, b) never_pairs[#never_pairs + 1] = { a, b } return true end

local had_browser = package.loaded["koassistant_xray_browser"]
package.loaded["koassistant_xray_browser"] = nil
local XrayBrowser = require("koassistant_xray_browser")
local XrayParser = require("koassistant_xray_parser")

-- ------------------------------------------------------------------ fixture
local function xray()
    local data = XrayParser.parse([[{ "type": "fiction",
        "characters": [
            {"name": "Zora", "role": "Lead", "description": "This book's lead."},
            {"name": "Abel", "role": "Rival", "description": "This book's rival."}
        ],
        "locations": [{"name": "The Ford", "description": "A crossing."}],
        "current_state": {"summary": "now"}
    }]])
    data[XrayParser.DORMANT_KEY] = {
        { name = "Tove", role = "Netmender", category = "characters", source = "Volume One", file = "/b/vol1.epub",
          description = "Mended the nets." },
        { name = "brandt", category = "characters", source = "Volume Two", file = "/b/vol2.epub" },
        { name = "Kell", role = "Harbormaster", category = "key_figures", source = "A Companion", file = "/x/companion.epub" },
        { name = "Saltrest", category = "locations", source = "Volume One", file = "/b/vol1.epub" },
        { name = "Runecraft", category = "lexicon", source = "Volume Two", file = "/b/vol2.epub" },
        { name = "Emergence", category = "core_concepts", source = "A Companion", file = "/x/companion.epub" },
    }
    return data
end

local function browser(data)
    local menu = { item_table = {}, paths = {} }
    function menu:switchItemTable(title, items)
        self.title = title
        self.item_table = items
    end
    return setmetatable({
        xray_data = data or xray(),
        metadata = { book_file = "/b/vol3.epub", plugin = {}, enable_emoji = false,
            configuration = { features = {} }, title = "Volume Three" },
        nav_stack = {},
        menu = menu,
        _ledger_gen = 0,
    }, { __index = XrayBrowser })
end

local function rowByText(items, text)
    for i, it in ipairs(items) do
        if it.text == text then return it, i end
    end
    return nil
end
local function texts(items)
    local out = {}
    for i, it in ipairs(items) do out[i] = it.text end
    return table.concat(out, "|")
end
-- A carried row's right column is fitted when the Menu shows the row
local function right(item)
    if item.mandatory_func then return item.mandatory_func() end
    return item.mandatory
end
local function categoryOf(b, key)
    for _idx, cat in ipairs(XrayParser.getCategories(b.xray_data)) do
        if cat.key == key then return cat end
    end
end

-- ------------------------------------------------------------------ tests
print("")
print("  [" .. "dial off: the pages are what they were" .. "]")

TestRunner:test("root counts, no category for carried-only kinds, the carried row", function()
    dial, group_kind = "list", "series"
    local b = browser()
    local items = b:buildCategoryItems()
    TestRunner:assertEqual(rowByText(items, "Cast").mandatory, "2")
    TestRunner:assertEqual(rowByText(items, "World").mandatory, "1")
    TestRunner:assertEqual(rowByText(items, "Lexicon"), nil, "this book has no terms of its own")
    TestRunner:assertEqual(rowByText(items, "Carried from earlier books").mandatory, "6")
end)

TestRunner:test("a category page lists this book's own entries only", function()
    dial = "list"
    local b = browser()
    b:showCategoryItems(categoryOf(b, "characters"))
    TestRunner:assertEqual(b.menu.title, "Cast (2)")
    TestRunner:assertEqual(texts(b.menu.item_table), "Zora|Abel", "the model's order, nothing else")
end)

print("")
print("  [" .. "dial on: carried entries inside the categories" .. "]")

TestRunner:test("root rows count both and a carried-only category appears", function()
    dial, group_kind = "categories", "series"
    local b = browser()
    local items = b:buildCategoryItems()
    TestRunner:assertEqual(rowByText(items, "Cast").mandatory, "2 + 3", "a nonfiction figure files under Cast")
    TestRunner:assertEqual(rowByText(items, "World").mandatory, "1 + 1")
    TestRunner:assertEqual(rowByText(items, "Lexicon").mandatory, "0 + 1", "carried terms show though this book has none yet")
    TestRunner:assertEqual(rowByText(items, "Current State").mandatory, "", "the status block is untouched")
    TestRunner:assertEqual(rowByText(items, "Carried from earlier books").mandatory, "6", "the carried list stays")
end)

TestRunner:test("a category page: own entries, the header, then carried entries by name", function()
    dial = "categories"
    local b = browser()
    b:showCategoryItems(categoryOf(b, "characters"))
    TestRunner:assertEqual(b.menu.title, "Cast (2 + 3)")
    TestRunner:assertEqual(texts(b.menu.item_table), "Zora|Abel|From earlier books (3)|brandt|Kell|Tove",
        "own entries keep the model's order; carried ones are in name order, case ignored")
    local items = b.menu.item_table
    TestRunner:assertEqual(items[2].separator, true, "a line closes this book's own rows")
    TestRunner:assertEqual(items[3].bold, true, "the header")
    TestRunner:assertEqual(right(items[6]), "Netmender · Book 1", "role, then the book's number in the series")
    TestRunner:assertEqual(right(items[4]), "Book 2", "no role: the source alone")
    TestRunner:assertEqual(right(items[5]), "Harbormaster · A Companion",
        "a source outside the series is named by its title")
    -- A carried row opens the carried entry's page, walking this page's carried rows
    local opened
    b.showDormantDetail = function(_self, idx, stub, nav) opened = { idx = idx, stub = stub, nav = nav } end
    items[6].callback()
    TestRunner:assertEqual(opened.stub.name, "Tove")
    TestRunner:assertEqual(opened.idx, 1, "its raw ledger index, for the edit actions")
    TestRunner:assertEqual(#opened.nav.rows, 3, "the arrows walk this category's carried rows")
    TestRunner:assertEqual(opened.nav.index, 3)
end)

TestRunner:test("nothing set is the dial on: in their categories, and the carried list stays", function()
    dial, group_kind = nil, "series"
    local b = browser()
    local items = b:buildCategoryItems()
    TestRunner:assertEqual(rowByText(items, "Cast").mandatory, "2 + 3", "the default counts both")
    TestRunner:assertEqual(rowByText(items, "Carried from earlier books").mandatory, "6", "and keeps the list")
    b:showCategoryItems(categoryOf(b, "characters"))
    TestRunner:assertEqual(b.menu.title, "Cast (2 + 3)")
end)

-- A long series carries hundreds of rows into one category, and fitting a
-- right column lays text out three times or more: only the rows the Menu
-- shows are fitted, each once.
TestRunner:test("a carried row's right column is fitted when the row is shown, once", function()
    group_kind = "series"
    local TW = package.loaded["ui/widget/textwidget"]
    local saved_new, measured = TW.new, 0
    TW.new = function(self, o) measured = measured + 1; return saved_new(self, o) end
    local ok, err = pcall(function()
        dial = "list"
        local own = browser()
        own:showCategoryItems(categoryOf(own, "characters"))
        local own_only = measured
        TestRunner:assertTrue(own_only > 0, "this book's own rows are fitted as the page is built")
        measured = 0
        dial = "categories"
        local b = browser()
        b:showCategoryItems(categoryOf(b, "characters"))
        TestRunner:assertEqual(#b.menu.item_table, 6, "own rows, the header, three carried rows")
        TestRunner:assertEqual(measured, own_only, "the carried rows cost nothing until they are shown")
        local row = b.menu.item_table[6]
        TestRunner:assertEqual(row.mandatory, nil, "no text is stored on the row")
        TestRunner:assertEqual(right(row), "Netmender · Book 1")
        TestRunner:assertTrue(measured > own_only, "fitted on first show")
        local after_first = measured
        TestRunner:assertEqual(right(row), "Netmender · Book 1")
        TestRunner:assertEqual(measured, after_first, "and kept for the next repaint")
    end)
    TW.new = saved_new
    if not ok then error(err, 0) end
end)

TestRunner:test("a section or an archived version never lists carried entries", function()
    dial = "categories"
    local b = browser()
    b.metadata.checkpoint = true
    TestRunner:assertEqual(rowByText(b:buildCategoryItems(), "Cast").mandatory, "2")
    b.metadata.checkpoint = nil
    b.scope = { label = "Part One" }
    b:showCategoryItems(categoryOf(b, "characters"))
    TestRunner:assertEqual(b.menu.title, "Cast (2)")
end)

print("")
print("  [" .. "the carried list by category" .. "]")

TestRunner:test("it opens on category rows; All is the flat page", function()
    dial, group_kind = "list", "series"
    local b = browser()
    b:showDormantList()
    TestRunner:assertEqual(b.menu.title, "Carried from earlier books (6)")
    TestRunner:assertEqual(texts(b.menu.item_table), "AI merge…|All|Cast|World|Lexicon|Other",
        "the list's own tool row, then the kinds")
    TestRunner:assertEqual(rowByText(b.menu.item_table, "Cast").mandatory, "3")
    TestRunner:assertEqual(rowByText(b.menu.item_table, "Other").mandatory, "1")
    rowByText(b.menu.item_table, "All").callback()
    TestRunner:assertEqual(#b.menu.item_table, 6, "every carried entry on one page")
    TestRunner:assertEqual(#b.nav_stack, 2, "under the category rows")
    TestRunner:assertEqual(texts(b.menu.item_table), "brandt|Kell|Tove|Saltrest|Runecraft|Emergence",
        "people, places, terms, concepts; name order inside each")
    TestRunner:assertEqual(right(rowByText(b.menu.item_table, "Tove")), "Cast · Volume One",
        "the flat page keeps the category tag and the source title beside each name")
end)

TestRunner:test("a carried entry's page ends on the back button, then the arrows, like an entry page", function()
    dial, group_kind = "list", "series"
    local b = browser()
    b.metadata.plugin = nil -- no "Open in <book>'s X-Ray" row: nothing to read here
    local TextViewer = require("ui/widget/textviewer")
    local saved_new, shown, closed = TextViewer.new, nil, 0
    TextViewer.new = function(_self, o)
        shown = o
        o.onClose = function() closed = closed + 1 end
        return o
    end
    b:showDormantList({ flat = true })
    rowByText(b.menu.item_table, "Tove").callback()
    local last = shown.buttons_table[#shown.buttons_table]
    TestRunner:assertEqual(last[1].text .. last[2].text .. last[3].text, "←◀▶")
    last[1].callback()
    TestRunner:assertEqual(closed, 1, "back closes the page: the list it was opened from is underneath")
    TestRunner:assertEqual(#b.nav_stack, 1, "and that list is still the page on screen")
    -- A list of one row has nothing to walk: the back button alone
    local one = xray()
    one[XrayParser.DORMANT_KEY] = { one[XrayParser.DORMANT_KEY][1] }
    local b1 = browser(one)
    b1.metadata.plugin = nil
    b1:showDormantList()
    rowByText(b1.menu.item_table, "Tove").callback()
    last = shown.buttons_table[#shown.buttons_table]
    TestRunner:assertEqual(#last, 1)
    TestRunner:assertEqual(last[1].text, "←")
    TextViewer.new = saved_new
end)

TestRunner:test("a single kind opens flat, as before", function()
    local data = xray()
    local ledger = data[XrayParser.DORMANT_KEY]
    data[XrayParser.DORMANT_KEY] = { ledger[1], ledger[2] }
    local b = browser(data)
    b:showDormantList()
    TestRunner:assertEqual(texts(b.menu.item_table), "AI merge…|brandt|Tove", "under the list's tool row")
    TestRunner:assertEqual(b.menu.title, "Carried from earlier books (2)")
end)

TestRunner:test("after an edit the page on screen and the pages under it are rebuilt", function()
    dial = "list"
    local b = browser()
    b:showDormantList()
    rowByText(b.menu.item_table, "Cast").callback()
    TestRunner:assertEqual(b.menu.title, "Cast · From earlier books (3)")
    TestRunner:assertEqual(texts(b.menu.item_table), "brandt|Kell|Tove")
    -- What a committed remove does: new data, the generation moves
    table.remove(b.xray_data[XrayParser.DORMANT_KEY], 1)
    b._ledger_gen = b._ledger_gen + 1
    b:_refreshDormantPage()
    TestRunner:assertEqual(texts(b.menu.item_table), "brandt|Kell", "the page on screen")
    TestRunner:assertEqual(b.menu.title, "Cast · From earlier books (2)")
    b:navigateBack()
    TestRunner:assertEqual(rowByText(b.menu.item_table, "Cast").mandatory, "2", "the category rows under it")
    TestRunner:assertEqual(rowByText(b.menu.item_table, "All").mandatory, "5")
    TestRunner:assertEqual(b.menu.title, "Carried from earlier books (5)")
end)

TestRunner:test("a page left with nothing pops back", function()
    dial = "list"
    local b = browser()
    b:showDormantList()
    rowByText(b.menu.item_table, "World").callback()
    TestRunner:assertEqual(#b.nav_stack, 2)
    local kept = {}
    for _idx, stub in ipairs(b.xray_data[XrayParser.DORMANT_KEY]) do
        if stub.category ~= "locations" then kept[#kept + 1] = stub end
    end
    b.xray_data[XrayParser.DORMANT_KEY] = kept
    b._ledger_gen = b._ledger_gen + 1
    b:_refreshDormantPage()
    TestRunner:assertEqual(#b.nav_stack, 1, "back on the category rows")
    TestRunner:assertEqual(rowByText(b.menu.item_table, "World"), nil, "which no longer list the emptied kind")
end)

TestRunner:test("an integrated category page follows an edit too", function()
    dial = "categories"
    local b = browser()
    b:showCategoryItems(categoryOf(b, "characters"))
    -- "Add as a new entry": the carried row becomes one of this book's own
    XrayParser.promoteStub(b.xray_data, 1, "Tove")
    b._ledger_gen = b._ledger_gen + 1
    b:_refreshDormantPage()
    TestRunner:assertEqual(b.menu.title, "Cast (3 + 2)")
    TestRunner:assertEqual(texts(b.menu.item_table), "Zora|Abel|Tove|From earlier books (2)|brandt|Kell")
    TestRunner:assertEqual(b.location.category_key, "characters", "the page keeps its place for the group jump")
end)

TestRunner:test("the dial flipped from the menu repaints the page on screen", function()
    dial = "list"
    local b = browser()
    b:showCategoryItems(categoryOf(b, "characters"))
    TestRunner:assertEqual(#b.menu.item_table, 2)
    dial = "categories"
    b:_repaintCarried()
    TestRunner:assertEqual(#b.menu.item_table, 6, "own rows, the header, the carried rows")
    b:navigateBack()
    TestRunner:assertEqual(rowByText(b.menu.item_table, "Cast").mandatory, "2 + 3", "and the root")
end)

print("")
print("  [" .. "the root lists what the X-Ray has" .. "]")

TestRunner:test("a category the X-Ray was built without gets no row (the B312 row is gone)", function()
    dial, group_kind = "list", "series"
    local b = browser()
    for _idx, stamp in ipairs({ "people,places,ideas,terms", "people" }) do
        b.metadata.xray_categories = stamp
        local items = b:buildCategoryItems()
        TestRunner:assertEqual(rowByText(items, "Story Arc"), nil, stamp)
        for _i, it in ipairs(items) do
            TestRunner:assertTrue(it.mandatory ~= "not tracked", "no 'not tracked' row: " .. stamp)
        end
    end
end)

print("")
print("  [" .. "the X-Ray popup's carried row (B401)" .. "]")

TestRunner:test("its label is the list's title with the count, and nothing carried means no row", function()
    local saved_parsed = ActionCache.parsedXrayFor
    local data = xray()
    ActionCache.parsedXrayFor = function() return { data = data } end
    local ok, err = pcall(function()
        group_kind = "series"
        TestRunner:assertEqual(XrayBrowser.carriedListLabel("/b/vol3.epub"), "Carried from earlier books (6)")
        TestRunner:assertEqual(XrayBrowser.carriedListTitle("/b/vol3.epub", 4), "Carried from earlier books (4)",
            "a count the caller holds")
        group_kind = "project"
        TestRunner:assertEqual(XrayBrowser.carriedListLabel("/b/vol3.epub"), "Carried from group (6)")
        TestRunner:assertEqual(XrayBrowser.carriedListTitle("/b/vol3.epub", 4), "Carried from group (4)")
        data[XrayParser.DORMANT_KEY] = {}
        TestRunner:assertEqual(XrayBrowser.carriedListLabel("/b/vol3.epub"), nil, "nothing carried")
        ActionCache.parsedXrayFor = function() return nil end
        TestRunner:assertEqual(XrayBrowser.carriedListLabel("/b/vol3.epub"), nil, "no X-Ray")
        -- A text the caller holds that has no carried list is never parsed
        group_kind = "series"
        local parses = 0
        ActionCache.parsedXrayFor = function() parses = parses + 1; return { data = xray() } end
        TestRunner:assertEqual(XrayBrowser.carriedListLabel("/b/vol3.epub", '{"characters": []}'), nil)
        TestRunner:assertEqual(parses, 0, "no carried list in the text: no parse")
        TestRunner:assertEqual(XrayBrowser.carriedListLabel("/b/vol3.epub", '{"__dormant": [{"name": "x"}]}'),
            "Carried from earlier books (6)", "a text with one is counted from the parsed X-Ray")
    end)
    ActionCache.parsedXrayFor = saved_parsed
    group_kind = "series"
    if not ok then error(err, 0) end
end)

TestRunner:test("a browser opened from that row lands on the carried list; another book's row is dropped", function()
    dial, group_kind = "list", "series"
    local Menu = package.loaded["ui/widget/menu"]
    local saved_new = rawget(Menu, "new")
    local opened
    Menu.new = function(_self, o)
        o.paths = {}
        function o:switchItemTable(title, items) self.title = title; self.item_table = items end
        function o:updatePageInfo() end
        opened = o
        return o
    end
    local meta = { book_file = "/b/vol3.epub", plugin = {}, enable_emoji = false,
        configuration = { features = {} }, title = "Volume Three" }
    local ok, err = pcall(function()
        local b = setmetatable({}, { __index = XrayBrowser })
        XrayBrowser._pending_navigate_to = { book_file = "/b/vol3.epub", carried_list = true }
        b:show(xray(), meta, nil)
        TestRunner:assertEqual(opened.title, "Carried from earlier books (6)", "the list is on screen")
        TestRunner:assertEqual(XrayBrowser._pending_navigate_to, nil, "the landing is used once")
        XrayBrowser._pending_navigate_to = { book_file = "/b/other.epub", carried_list = true }
        b = setmetatable({}, { __index = XrayBrowser })
        b:show(xray(), meta, nil)
        TestRunner:assertTrue(opened.title ~= "Carried from earlier books (6)", "the root, not the list")
        TestRunner:assertEqual(#b.nav_stack, 0, "nothing was pushed")
    end)
    rawset(Menu, "new", saved_new)
    XrayBrowser._pending_navigate_to = nil
    if not ok then error(err, 0) end
end)

print("")
print("  [" .. "the carried list's tools: possible matches and AI merge (B314, B401)" .. "]")

-- A book whose names drifted: an entry the earlier book called by a longer
-- name, and two carried rows for one person
local function driftXray()
    local data = XrayParser.parse([[{ "type": "fiction",
        "characters": [
            {"name": "Jory", "role": "Carter", "description": "Drives the cart."},
            {"name": "Abel", "role": "Rival", "description": "This book's rival."}
        ],
        "locations": [{"name": "The Ford", "description": "A crossing."}],
        "current_state": {"summary": "now"}
    }]])
    data[XrayParser.DORMANT_KEY] = {
        { name = "Jory Pell", role = "Toll keeper", category = "characters", source = "Volume Two",
          file = "/b/vol2.epub", description = "Keeps the toll chain." },
        { name = "Dorrit", category = "characters", source = "Volume One", file = "/b/vol1.epub",
          description = "Kept the inn." },
        { name = "Dorrit Hale", role = "Innkeeper", category = "characters", source = "Volume Two",
          file = "/b/vol2.epub", description = "Keeps the ferry inn." },
        { name = "Saltrest", category = "locations", source = "Volume One", file = "/b/vol1.epub" },
    }
    return data
end
-- What a committed carried-list edit does: the change lands, the generation moves
local function committing(b)
    b._commitDormantOp = function(self, apply_fn, text)
        if not apply_fn(self.xray_data) then return false end
        self._ledger_gen = self._ledger_gen + 1
        self.committed = text
        return true
    end
    return b
end
local ButtonDialog = require("ui/widget/buttondialog")
local function withDialogs(fn)
    local saved_new, shown = ButtonDialog.new, {}
    ButtonDialog.new = function(_self, o) shown[#shown + 1] = o return o end
    local ok, err = pcall(fn, shown)
    ButtonDialog.new = saved_new
    if not ok then error(err, 0) end
end
local function button(dialog, text)
    for _idx, row in ipairs(dialog.buttons) do
        if row[1].text == text then return row[1] end
    end
    return nil
end
local function buttonTexts(dialog)
    local out = {}
    for i, row in ipairs(dialog.buttons) do out[i] = row[1].text end
    return table.concat(out, "|")
end

TestRunner:test("the list's top page: the review with its count when names look alike, then the AI merges", function()
    dial, group_kind, never_pairs = "list", "series", {}
    local b = browser(driftXray())
    b:showDormantList()
    TestRunner:assertEqual(texts(b.menu.item_table), "Possible matches|AI merge…|All|Cast|World")
    TestRunner:assertEqual(rowByText(b.menu.item_table, "Possible matches").mandatory, "2")
    TestRunner:assertTrue(rowByText(b.menu.item_table, "AI merge…").separator, "a line under the tools")
    b = browser(driftXray())
    b:showDormantList({ flat = true })
    TestRunner:assertEqual(rowByText(b.menu.item_table, "AI merge…"), nil, "the one-page list is entries only")
end)

TestRunner:test("the review lists each pair once: with this book's entries first, then between carried rows", function()
    never_pairs = {}
    local b = browser(driftXray())
    b:showDormantList()
    rowByText(b.menu.item_table, "Possible matches").callback()
    TestRunner:assertEqual(b.menu.title, "Possible matches (2)")
    TestRunner:assertEqual(texts(b.menu.item_table),
        "With this book's entries (1)|Jory Pell ↔ Jory|Between carried entries (1)|Dorrit ↔ Dorrit Hale")
    TestRunner:assertEqual(b.menu.item_table[2].mandatory, "contained name")
    TestRunner:assertEqual(#b.nav_stack, 2, "a page under the carried list")
end)

TestRunner:test("a pair shows both sides and where each is from; Link joins a carried row to this book's entry", function()
    never_pairs = {}
    withDialogs(function(shown)
        local b = committing(browser(driftXray()))
        b:showDormantList()
        rowByText(b.menu.item_table, "Possible matches").callback()
        rowByText(b.menu.item_table, "Jory Pell ↔ Jory").callback()
        local d = shown[#shown]
        TestRunner:assertEqual(d.title, "Cast: contained name\n\n"
            .. "Jory Pell (carried from Volume Two): Keeps the toll chain.\n\n"
            .. "Jory (this book): Drives the cart.")
        TestRunner:assertEqual(buttonTexts(d),
            "Full descriptions…|Link \"Jory Pell\" to \"Jory\"|Never suggest this pair")
        button(d, "Link \"Jory Pell\" to \"Jory\"").callback()
        TestRunner:assertEqual(b.committed, "Linked \"Jory Pell\" to \"Jory\". Its carried history now shows there.")
        local jory = b.xray_data.characters[1]
        TestRunner:assertEqual(jory.aliases[1], "Jory Pell", "the earlier name is an alias now")
        TestRunner:assertEqual(jory.background[1].source .. ": " .. jory.background[1].text,
            "Volume Two: Keeps the toll chain.", "and that book's text is its line")
        TestRunner:assertEqual(#b.xray_data[XrayParser.DORMANT_KEY], 3, "the row left the carried list")
        TestRunner:assertEqual(b.menu.title, "Possible matches (1)", "the review is redrawn")
        TestRunner:assertEqual(texts(b.menu.item_table), "Between carried entries (1)|Dorrit ↔ Dorrit Hale")
    end)
end)

TestRunner:test("Link joins two carried rows into one; with nothing left the review closes onto the list", function()
    never_pairs = { { "Jory", "Jory Pell" } }
    withDialogs(function(shown)
        local b = committing(browser(driftXray()))
        b:showDormantList()
        TestRunner:assertEqual(rowByText(b.menu.item_table, "Possible matches").mandatory, "1")
        rowByText(b.menu.item_table, "Possible matches").callback()
        rowByText(b.menu.item_table, "Dorrit ↔ Dorrit Hale").callback()
        local d = shown[#shown]
        TestRunner:assertEqual(d.title, "Cast: contained name\n\n"
            .. "Dorrit (carried from Volume One): Kept the inn.\n\n"
            .. "Dorrit Hale (carried from Volume Two): Keeps the ferry inn.")
        button(d, "Link \"Dorrit\" and \"Dorrit Hale\"").callback()
        TestRunner:assertEqual(b.committed, "Linked \"Dorrit\" and \"Dorrit Hale\". They are one carried entry now.")
        local ledger = b.xray_data[XrayParser.DORMANT_KEY]
        TestRunner:assertEqual(#ledger, 3, "one row for the two")
        TestRunner:assertEqual(b.menu.title, "Carried from earlier books (3)", "back on the list, recounted")
        TestRunner:assertEqual(texts(b.menu.item_table), "AI merge…|All|Cast|World", "the review's row is gone")
        TestRunner:assertEqual(#b.nav_stack, 1)
    end)
end)

TestRunner:test("Never is asked once, remembered on the book's never-merge list, and the pair leaves the review", function()
    never_pairs = {}
    local confirm
    stub("ui/widget/confirmbox", { new = function(_self, o) confirm = o return o end })
    withDialogs(function(shown)
        local b = committing(browser(driftXray()))
        b:showDormantList()
        rowByText(b.menu.item_table, "Possible matches").callback()
        rowByText(b.menu.item_table, "Jory Pell ↔ Jory").callback()
        button(shown[#shown], "Never suggest this pair").callback()
        TestRunner:assertEqual(confirm.text, "Never suggest \"Jory Pell\" and \"Jory\" as a match?\n\n"
            .. "This is remembered for this book. To undo it, open \"Find duplicate entities…\" and tap \"Never-merge pairs\".")
        TestRunner:assertEqual(#never_pairs, 0, "nothing is stored before the answer")
        TestRunner:assertEqual(b.menu.title, "Possible matches (2)")
        confirm.ok_callback()
        TestRunner:assertEqual(never_pairs[1][1] .. "|" .. never_pairs[1][2], "Jory Pell|Jory")
        TestRunner:assertEqual(b.menu.title, "Possible matches (1)")
        TestRunner:assertEqual(#b.xray_data[XrayParser.DORMANT_KEY], 4, "the carried list itself is untouched")
        b:navigateBack()
        TestRunner:assertEqual(rowByText(b.menu.item_table, "Possible matches").mandatory, "1", "the list's count follows")
    end)
end)

TestRunner:test("Full descriptions shows both entries whole", function()
    never_pairs = {}
    local TextViewer = require("ui/widget/textviewer")
    local saved_new, viewer = TextViewer.new, nil
    TextViewer.new = function(_self, o) viewer = o return o end
    local ok, err = pcall(withDialogs, function(shown)
        local b = browser(driftXray())
        b:showDormantList()
        rowByText(b.menu.item_table, "Possible matches").callback()
        rowByText(b.menu.item_table, "Dorrit ↔ Dorrit Hale").callback()
        button(shown[#shown], "Full descriptions…").callback()
        TestRunner:assertEqual(viewer.title, "Dorrit ↔ Dorrit Hale")
        TestRunner:assertEqual(viewer.text, "Dorrit\n\nCarried from: Volume One\n\nKept the inn."
            .. "\n\n――――――――\n\n"
            .. "Dorrit Hale (Innkeeper)\n\nCarried from: Volume Two\n\nKeeps the ferry inn.")
    end)
    TextViewer.new = saved_new
    if not ok then error(err, 0) end
end)

TestRunner:test("AI merge… offers the merges between books, from the one builder, and nothing else", function()
    never_pairs = {}
    withDialogs(function(shown)
        local b = browser(driftXray())
        b.metadata.plugin = { _groupXrayMergeKind = function() return "series" end }
        b:showDormantList()
        rowByText(b.menu.item_table, "AI merge…").callback()
        local d = shown[#shown]
        TestRunner:assertEqual(d.title, "AI merge")
        TestRunner:assertEqual(buttonTexts(d),
            "AI merge with another book (1 request)…|AI merge the series (1 request per book)…")
    end)
end)

TestRunner:test("a section or an archived version has no review", function()
    local b = browser(driftXray())
    b.scope = { label = "Part 1" }
    TestRunner:assertEqual(#b:_carriedMatches(), 0)
end)

print("")
print("  [" .. "project groups" .. "]")

TestRunner:test("a project has no earlier books: its own wording, titles as sources", function()
    dial, group_kind = "categories", "project"
    local b = browser()
    TestRunner:assertTrue(rowByText(b:buildCategoryItems(), "Carried from group") ~= nil)
    b:showCategoryItems(categoryOf(b, "characters"))
    TestRunner:assertEqual(b.menu.item_table[3].text, "From the group (3)")
    TestRunner:assertEqual(right(b.menu.item_table[6]), "Netmender · Volume One", "no book numbers without an order")
end)

-- ------------------------------------------------------------------ cleanup
SDS.resolve = saved_resolve
ActionCache.getAvailableArtifactsWithPinned = saved_artifacts
ActionCache.getNeverMergePairs, ActionCache.addNeverMergePair = saved_get_never, saved_add_never
rawset(util, "splitToChars", saved_split)
package.loaded["koassistant_xray_browser"] = had_browser
for i = #saved, 1, -1 do package.loaded[saved[i].name] = saved[i].value end

return TestRunner:summary()
