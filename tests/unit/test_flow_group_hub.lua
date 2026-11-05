-- Flow test (docs/test_automation_plan.md, layer 1): the Group Hub's member
-- rows hold a later volume of a series back (B591, 2026-11-05), as the
-- "→ Group" popup does (B418): the row reads "(later in the series)" and
-- asks before that volume's Book Hub opens (its rows open the volume's X-Ray
-- and Recap); an earlier volume opens at once; with no book leading to the
-- hub (the Groups list) nothing is held back; the open book stands in. Driven
-- through group_page.lua's real code with the dialogs recorded
-- (tests/lib/ui_recorder.lua); the series' hold-back set is stubbed (its
-- rule has its own tests) and the Book Hub is recorded.
--
-- Run: lua tests/unit/test_flow_group_hub.lua  (or lua tests/run_tests.lua --unit)

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
local TestRunner = require("test_runner"):new()
local Recorder = require("ui_recorder")

-- ------------------------------------------------------------------ stubs
-- One Lua process runs every test file: everything replaced here goes back.
local saved = {}
local function stub(name, value)
    saved[#saved + 1] = { name = name, value = package.loaded[name] }
    package.loaded[name] = value
end
local opened = {}
-- KOReader's Menu as the page builds it: the rows land in item_table
stub("ui/widget/menu", { new = function(cls, o)
    o = o or {}
    o.paths = o.paths or {}
    o.updatePageInfo = function() end
    o.onCloseWidget = function() end
    o.paintTo = function() end
    o.switchItemTable = function(self_m, title, items, _idx, _sub, subtitle)
        self_m.title, self_m.item_table, self_m.subtitle = title, items, subtitle
    end
    return setmetatable(o, { __index = cls })
end })
stub("koassistant.books.group_settings", { rowLabel = function() return "Group Settings" end, show = function() end })
stub("koassistant.books.book_page", { show = function(o) opened[#opened + 1] = o end })

local BookGroups = require("koassistant.books.book_groups")
local mem = {}
BookGroups._setStoreForTests({
    readSetting = function(_self, key) return mem[key] end,
    saveSetting = function(_self, key, value) mem[key] = value end,
    flush = function() end,
})
-- titles from the paths, every file present
local saved_props, saved_exists = BookGroups.displayProps, BookGroups.fileExists
BookGroups.displayProps = function(path) return (path:match("([^/]+)%.epub$") or path), nil end
BookGroups.fileExists = function() return true end
local GroupsUI = require("koassistant.books.book_groups_ui")
local saved_coll = GroupsUI.hasCollections
GroupsUI.hasCollections = function() return false end
-- the artifact cache's load-time needs (the flow tests' shared stubs)
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
-- the series' hold-back set, by the book the hub is opened for
local ActionCache = require("koassistant.artifacts.action_cache")
local saved_held = ActionCache.heldBackLaterFiles
local held_from = {}
ActionCache.heldBackLaterFiles = function(file) return held_from[file] or {} end

local ui = Recorder.install()
local had_page = package.loaded["koassistant.books.group_page"]
package.loaded["koassistant.books.group_page"] = nil
local GroupPage = require("koassistant.books.group_page")

-- ------------------------------------------------------------------ fixture
local g = BookGroups.create("Mock Series")
BookGroups.addBook(g.id, "/v1.epub")
BookGroups.addBook(g.id, "/v2.epub")
BookGroups.addBook(g.id, "/v3.epub")
held_from["/v1.epub"] = { ["/v3.epub"] = "v3" }
local plugin = { settings = { readSetting = function() return {} end } }

local function rowFor(menu, head)
    for _idx, it in ipairs(menu.item_table or {}) do
        if it.text:find(head, 1, true) then return it end
    end
    local texts = {}
    for _idx, it in ipairs(menu.item_table or {}) do texts[#texts + 1] = it.text end
    error("no row " .. head .. " in: " .. table.concat(texts, " | "))
end
local function hub(opts)
    GroupPage.close({ silent = true })
    ui.stack = {}
    opened = {}
    opts.group_id, opts.plugin, opts.front = g.id, plugin, true
    GroupPage.show(opts)
    local menu = ui:top()
    TestRunner:assertTrue(menu and menu.item_table ~= nil, "the hub is a Menu with rows")
    return menu
end

print("Running: test_flow_group_hub")
print("")
print("  [a later volume held back on the hub's rows (B591)]")

TestRunner:test("from volume 1: volume 3's row says so and asks; Open it opens its Book Hub", function()
    local menu = hub({ file = "/v1.epub" })
    local r3 = rowFor(menu, "3. v3")
    TestRunner:assertTrue(r3.text:find("(later in the series)", 1, true) ~= nil, r3.text)
    TestRunner:assertTrue(rowFor(menu, "2. v2").text:find("later", 1, true) == nil, "volume 2 is not held back")
    r3.callback()
    local confirm = ui:top()
    TestRunner:assertEqual(confirm and confirm.ok_text, "Open it", "the confirm")
    TestRunner:assertTrue(tostring(confirm.text):find("v3 comes later in the series", 1, true) ~= nil, tostring(confirm.text))
    TestRunner:assertEqual(#opened, 0, "nothing opened before the confirm")
    ui:tap("Open it")
    TestRunner:assertEqual(#opened, 1)
    TestRunner:assertEqual(opened[1].file, "/v3.epub")
    TestRunner:assertEqual(opened[1].title, "v3", "the Book Hub's header keeps the undecorated title")
end)

TestRunner:test("an earlier volume opens at once", function()
    local menu = hub({ file = "/v1.epub" })
    rowFor(menu, "2. v2").callback()
    TestRunner:assertEqual(#opened, 1)
    TestRunner:assertEqual(opened[1].file, "/v2.epub")
    TestRunner:assertTrue(ui:top() == menu, "no confirm")
end)

TestRunner:test("from the Groups list, with no book open, nothing is held back", function()
    local menu = hub({})
    TestRunner:assertTrue(rowFor(menu, "3. v3").text:find("later", 1, true) == nil, "no reference book, no hold-back")
    rowFor(menu, "3. v3").callback()
    TestRunner:assertEqual(#opened, 1, "opens at once")
end)

TestRunner:test("the open book stands in when no book led to the hub", function()
    local menu = hub({ ui = { document = { file = "/v1.epub" } } })
    TestRunner:assertTrue(rowFor(menu, "3. v3").text:find("(later in the series)", 1, true) ~= nil)
    TestRunner:assertEqual(rowFor(menu, "1. v1").mandatory, "open", "and its own row says open")
end)

TestRunner:test("the words and the confirm are one copy with the → Group popup", function()
    TestRunner:assertEqual(GroupsUI.laterLabel("v3"), "v3 (later in the series)")
    ui.stack = {}
    local ran = false
    GroupsUI.confirmLaterVolume("v3", function() ran = true end)
    TestRunner:assertEqual(ui:top().ok_text, "Open it")
    ui:tap("Open it")
    TestRunner:assertTrue(ran, "Open it runs the opener")
end)

-- ------------------------------------------------------------------ cleanup
GroupPage.close({ silent = true })
BookGroups.remove(g.id)
ui:restore()
BookGroups.displayProps, BookGroups.fileExists = saved_props, saved_exists
GroupsUI.hasCollections = saved_coll
ActionCache.heldBackLaterFiles = saved_held
package.loaded["koassistant.books.group_page"] = had_page
for i = #saved, 1, -1 do package.loaded[saved[i].name] = saved[i].value end

return TestRunner:summary()
