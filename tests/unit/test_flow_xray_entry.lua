-- Flow tests on the koamock fixture (docs/test_automation_plan.md, layer 1):
-- an X-Ray entry's More… popup and what it opens, driven through the browser's
-- REAL code with the dialogs recorded (tests/lib/ui_recorder.lua), on the
-- invented "Mock Series 3" X-Ray the desktop fixture writes to disk
-- (tests/lib/koamock.lua). The device round's do-X-expect-Y steps, minus
-- what only a screen shows:
--   * B534: Move back to carried list only on an entry added from the carried
--     list, never on one that only carries history from an earlier book
--   * B535: Illustrate… opens the image settings panel; Illustrate with a
--     note… asks for the note and draws the entry with it
--   * B535: a note that names an entry brings it to the prompt writer
--   * Merge with another entry…: the entry page stays under the pick (Cancel,
--     Back and a tap outside land on it); a merge, by hand or by the AI,
--     lands on the kept entry
--
-- Run: lua tests/unit/test_flow_xray_entry.lua  (or lua tests/run_tests.lua --unit)

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
local TestRunner = require("test_runner"):new()
local Recorder = require("ui_recorder")
local KoaMock = require("koamock")

-- ------------------------------------------------------------------ stubs
-- One Lua process runs every test file: everything replaced here goes back.
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
for _idx, name in ipairs({ "ui/event", "ui/widget/menu" }) do
    if not package.loaded[name] then stub(name, class()) end
end
stub("ui/widget/textwidget", {
    new = function(_self, o)
        return { getSize = function() return { w = #(o.text or "") * 8 } end, free = function() end }
    end,
})
stub("device", {
    screen = {
        getWidth = function() return 800 end,
        getHeight = function() return 600 end,
        scaleBySize = function(_self, n) return n end,
        isColorEnabled = function() return false end,
    },
    isTouchDevice = function() return false end,
    hasKeys = function() return false end,
})
stub("ui/font", { getFace = function() return {} end })
stub("ui/size", { padding = { default = 0, large = 0, fullscreen = 0 }, margin = { default = 0 },
    line = { thick = 1 }, border = { default = 1 } })
stub("ui/network/manager", { runWhenConnected = function(_self, fn) fn() end })
-- luasocket's mime is not in the shared mock; the image generator calls it
-- only at response time
if not package.loaded["mime"] then
    stub("mime", { b64 = function(s) return s end, unb64 = function(s) return s end })
end
stub("koassistant.books.book_groups", {
    KIND_SERIES = "series", KIND_PROJECT = "project", KIND_PLAIN = "plain",
    groupsFor = function() return {} end,
    kindOf = function(g) return g.kind end,
    displayTitle = function(path) return path end,
    -- no groups here: a carried row names its source title
    carriedSourceLabeler = function() return function(s) return s.source or "", false end end,
})
local SDS = require("koassistant.storage.doc_settings")
local saved_resolve, saved_overlay = SDS.resolve, SDS.overlayCustomProps
SDS.resolve = function()
    return { readSetting = function() return nil end }
end
SDS.overlayCustomProps = function(props) return props or {} end
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
-- The dialogs are recorded from here on; the browser is loaded fresh so it
-- picks up this file's stubs
local ui = Recorder.install()
local ActionCache = require("koassistant.artifacts.action_cache")
local promoted = {}
local saved_promoted, saved_ladder = ActionCache.getPromotedStubs, ActionCache.getXrayLadderCount
ActionCache.getPromotedStubs = function() return promoted end
ActionCache.getXrayLadderCount = function() return 0 end
local had_browser = package.loaded["koassistant.xray.xray_browser"]
package.loaded["koassistant.xray.xray_browser"] = nil
local XrayBrowser = require("koassistant.xray.xray_browser")
local XrayParser = require("koassistant.xray.xray_parser")
local ImageGenerator = require("koassistant.images.image_generator")

-- ------------------------------------------------------------------ fixture
-- The plugin as the browser sees it: settings with an image provider that has
-- a key, so Illustrate is offered (the keys are fake and nothing is sent: the
-- picture itself is stubbed below)
local features = { image_gen_provider = "openai", provider = "anthropic" }
local plugin = {
    settings = { data = { features = features },
        readSetting = function(_self, k) return k == "features" and features or nil end },
    updateConfigFromSettings = function() end,
    imageStyleItems = function() return {} end,
    showQuickSettingsPopup = function() end,
}

local function browser(data, file)
    return setmetatable({
        xray_data = data,
        metadata = { book_file = file, plugin = plugin, enable_emoji = false,
            configuration = { features = features }, title = "Mock Series 3 - The Orchard" },
        nav_stack = {},
        menu = { item_table = {}, paths = {}, switchItemTable = function() end },
        _ledger_gen = 0,
    }, { __index = XrayBrowser })
end

local function entry(data, cat, name)
    for _idx, item in ipairs(data[cat] or {}) do
        if XrayParser.getItemName(item, cat) == name then return item end
    end
    error("no entry " .. name)
end

local function withKeys(fn)
    local prev = package.loaded["apikeys"]
    package.loaded["apikeys"] = { openai = "sk-flow-test" }
    local ok, err = pcall(fn)
    package.loaded["apikeys"] = prev
    if not ok then error(err, 0) end
end

local function moreOf(b, item, cat)
    ui.stack = {}
    b:_showEntityManagePopup(item, cat, XrayParser.getItemName(item, cat), nil, nil, nil, true, {})
    return ui:top()
end

-- ------------------------------------------------------------------ tests
print("")
print("  [More… on an entry (B534)]")

TestRunner:test("an entry with history from an earlier book: no Move back", function()
    local data, file = KoaMock.xray("Mock Series 3")
    local tamsin = entry(data, "characters", "Tamsin Vael")
    TestRunner:assertTrue(type(tamsin.background) == "table" and #tamsin.background > 0,
        "the fixture gives her a line from volume 1")
    local popup = moreOf(browser(data, file), tamsin, "characters")
    TestRunner:assertTrue(ui:has("Names and matching…", popup), table.concat(ui:texts(popup), " | "))
    TestRunner:assertTrue(not ui:has("Edit search terms", popup) and not ui:has("Rename…", popup),
        "B533: one row for both")
    TestRunner:assertTrue(not ui:has("Move back to carried list", popup),
        "never carried here: " .. table.concat(ui:texts(popup), " | "))
end)

TestRunner:test("an entry added from the carried list: Move back, then its confirm", function()
    local data, file = KoaMock.xray("Mock Series 3")
    -- Oswin Tarr: the fixture's hand-added entry and its record
    promoted = KoaMock.promoted("Mock Series 3")
    local ok, err = pcall(function()
        TestRunner:assertEqual(promoted["oswin tarr"], "Oswin Tarr", "the planted record")
        local popup = moreOf(browser(data, file), entry(data, "characters", "Oswin Tarr"), "characters")
        ui:tap("Move back to carried list", popup)
        local confirm = ui:top()
        TestRunner:assertTrue(confirm and confirm.ok_text == "Move", "the confirm")
        TestRunner:assertTrue(tostring(confirm.text):find("Oswin Tarr", 1, true) ~= nil, tostring(confirm.text))
        -- the same record on Tamsin, who has history but was never added by hand
        local tamsin = moreOf(browser(data, file), entry(data, "characters", "Tamsin Vael"), "characters")
        TestRunner:assertTrue(not ui:has("Move back to carried list", tamsin), "the record names Oswin only")
    end)
    promoted = {}
    if not ok then error(err, 0) end
end)

print("")
print("  [Illustrate (B535)]")

TestRunner:test("Illustrate… opens the picture popup: a note for this picture, then the picture", function()
    -- the popup's own widgets are the headless scenario's (s06); here its spec
    local ImageOptions = require("koassistant.images.image_options")
    local saved_generate, saved_show = ImageGenerator.generate, ImageOptions.show
    local drawn, spec
    ImageGenerator.generate = function(_text, _config, _settings, book_info, gen_opts)
        drawn = { book_info = book_info, gen_opts = gen_opts }
    end
    ImageOptions.show = function(_plugin, s) spec = s end
    local ok, err = pcall(withKeys, function()
        local data, file = KoaMock.xray("Mock Series 3")
        local popup = moreOf(browser(data, file), entry(data, "characters", "Gil Rook"), "characters")
        ui:tap("Illustrate…", popup)
        TestRunner:assertEqual(spec.title, "Illustrate \"Gil Rook\"")
        TestRunner:assertTrue(spec.note == true and spec.writer == true, "a note row and the writer row")
        TestRunner:assertTrue(spec.xray == nil, "no picks: the entry is the subject")
        TestRunner:assertEqual(#spec.actions, 1)
        TestRunner:assertEqual(spec.actions[1].text, "Illustrate")
        spec.state.note = "up the ladder, at dusk"
        spec.actions[1].callback()
        TestRunner:assertTrue(drawn ~= nil, "the picture was asked for")
        TestRunner:assertEqual(drawn.gen_opts.note, "up the ladder, at dusk")
        TestRunner:assertEqual(drawn.gen_opts.entry.name, "Gil Rook")
        TestRunner:assertEqual(drawn.book_info.file, file)
        drawn, spec = nil, nil
        moreOf(browser(data, file), entry(data, "characters", "Gil Rook"), "characters")
        ui:tap("Illustrate…")
        spec.actions[1].callback()
        TestRunner:assertTrue(drawn ~= nil and drawn.gen_opts.note == nil, "no note typed: none sent")
    end)
    ImageGenerator.generate, ImageOptions.show = saved_generate, saved_show
    if not ok then error(err, 0) end
end)

TestRunner:test("a note that names an entry brings it to the prompt writer", function()
    local data, file = KoaMock.xray("Mock Series 3")
    local saved_parsed, saved_run = ActionCache.parsedXrayFor, ImageGenerator._run
    local DataAccess = require("koassistant.ui.data_access")
    local saved_access = DataAccess.withAccess
    local run
    ActionCache.parsedXrayFor = function() return { data = data, entry = { used_book_text = true } } end
    DataAccess.withAccess = function(_plugin, _action, _opts, run_fn) run_fn({}) end
    ImageGenerator._run = function(st) run = st end
    local ok, err = pcall(function()
        ImageGenerator._askAndRun("openai", "He handed her the knife by way of hello.",
            { provider = "anthropic", features = { image_gen_frame_context = false } }, plugin.settings,
            { file = file, title = "Mock Series 3 - The Orchard" },
            { note = "this is Gil Rook by the way", plugin = plugin })
        TestRunner:assertTrue(run ~= nil, "the run went ahead")
        TestRunner:assertEqual(#run.entries, 1, "the passage names nobody; the note names one")
        TestRunner:assertEqual(run.entries[1].name, "Gil Rook")
    end)
    ActionCache.parsedXrayFor, ImageGenerator._run = saved_parsed, saved_run
    DataAccess.withAccess = saved_access
    if not ok then error(err, 0) end
end)

print("")
print("  [Pictures beside their entries (B486) and picked entries (B535)]")

TestRunner:test("More…: Pictures (N)… beside Illustrate…, opening the gallery on that entry", function()
    local data, file = KoaMock.xray("Mock Series 3")
    local saved_pics = ImageGenerator.picturesOf
    local had_ib = package.loaded["koassistant.images.image_browser"]
    local shown
    package.loaded["koassistant.images.image_browser"] = { show = function(o) shown = o end }
    ImageGenerator.picturesOf = function(book, names)
        return (book == file and names["gil rook"]) and { "x.png", "y.png" } or {}
    end
    local ok, err = pcall(withKeys, function()
        local popup = moreOf(browser(data, file), entry(data, "characters", "Gil Rook"), "characters")
        TestRunner:assertTrue(ui:has("Pictures (2)…", popup) and ui:has("Illustrate…", popup),
            table.concat(ui:texts(popup), " | "))
        ui:tap("Pictures (2)…", popup)
        TestRunner:assertTrue(shown and shown.entry, "the gallery opened on an entry")
        TestRunner:assertEqual(shown.entry.book_file, file)
        TestRunner:assertEqual(shown.entry.title, "Gil Rook")
        TestRunner:assertTrue(shown.entry.names["gil rook"] == true, "matched by its names")
        popup = moreOf(browser(data, file), entry(data, "characters", "Tamsin Vael"), "characters")
        TestRunner:assertTrue(not table.concat(ui:texts(popup), "|"):find("Pictures", 1, true),
            "an entry without pictures: Illustrate… alone")
    end)
    ImageGenerator.picturesOf = saved_pics
    package.loaded["koassistant.images.image_browser"] = had_ib
    if not ok then error(err, 0) end
end)

TestRunner:test("a picture records what it shows: the picks, the passage's names, the entry drawn", function()
    local data, file = KoaMock.xray("Mock Series 3")
    local saved_parsed, saved_run = ActionCache.parsedXrayFor, ImageGenerator._run
    local DataAccess = require("koassistant.ui.data_access")
    local saved_access = DataAccess.withAccess
    local run
    ActionCache.parsedXrayFor = function() return { data = data, entry = { used_book_text = true } } end
    DataAccess.withAccess = function(_plugin, _action, _opts, run_fn) run_fn({}) end
    ImageGenerator._run = function(st) run = st end
    local book = { file = file, title = "Mock Series 3 - The Orchard" }
    local ok, err = pcall(function()
        ImageGenerator._askAndRun("openai", "He handed her the knife by way of hello.",
            { provider = "anthropic", features = { image_gen_frame_context = false } }, plugin.settings,
            book, { picked = { "Gil Rook" }, plugin = plugin })
        TestRunner:assertEqual(run.entries[1] and run.entries[1].name, "Gil Rook", "the pick goes to the writer")
        TestRunner:assertEqual(table.concat(run.about or {}, "|"), "Gil Rook", "and is recorded with the picture")
        run = nil
        ImageGenerator._askAndRun("openai", "Gil Rook was up a ladder in the salt-apple rows.",
            { provider = "anthropic", features = { image_gen_frame_context = false, image_gen_writer = false } },
            plugin.settings, book, { plugin = plugin })
        TestRunner:assertEqual(#run.entries, 0, "the writer off: no entries sent")
        TestRunner:assertEqual(table.concat(run.about or {}, "|"), "Gil Rook",
            "but the picture still records whom the passage names")
        run = nil
        ImageGenerator._askAndRun("openai", nil,
            { provider = "anthropic", features = { image_gen_frame_context = false } }, plugin.settings,
            book, { entry = { name = "Tamsin Vael", description = "d" }, plugin = plugin })
        TestRunner:assertEqual(table.concat(run.about or {}, "|"), "Tamsin Vael", "Illustrate: the entry drawn")
    end)
    ActionCache.parsedXrayFor, ImageGenerator._run = saved_parsed, saved_run
    DataAccess.withAccess = saved_access
    if not ok then error(err, 0) end
end)

TestRunner:test("the note box: OK hands the note over, a blank one as none, Cancel nothing", function()
    local got, called = nil, 0
    local ok, err = pcall(function()
        ui.stack = {}
        ImageGenerator.askNote("from behind", function(text) got, called = text, called + 1 end)
        local note = ui:top()
        TestRunner:assertEqual(note.title, "Note for the picture")
        TestRunner:assertEqual(note.input, "from behind", "opens on the note so far")
        TestRunner:assertTrue(note.description == nil and type(note.input_hint) == "string"
            and note.input_hint:find("in the rain", 1, true) ~= nil
            and note.input_hint:find("what to include", 1, true) ~= nil,
            "the examples are the gray hint inside the box")
        TestRunner:assertTrue(note.text_height ~= nil, "a box the size of the chat's (text_height alone sizes it)")
        TestRunner:assertEqual(table.concat(ui:texts(note), " | "), "Cancel | OK")
        ui:type("at dusk", note)
        ui:tap("OK", note)
        TestRunner:assertEqual(got, "at dusk")
        ImageGenerator.askNote(nil, function(text) got, called = text, called + 1 end)
        ui:type("   ")
        ui:tap("OK")
        TestRunner:assertTrue(got == nil and called == 2, "a blank note is none")
        ImageGenerator.askNote(nil, function() called = called + 1 end)
        ui:tap("Cancel")
        TestRunner:assertEqual(called, 2, "Cancel hands nothing over")
    end)
    if not ok then error(err, 0) end
end)

TestRunner:test("the picker: picked, suggested, then by category; closing hands the list back (B537)", function()
    local saved_menu = package.loaded["ui/widget/menu"]
    local menu
    package.loaded["ui/widget/menu"] = { new = function(_cls, o)
        menu = o
        o.switchItemTable = function(self_m, title, items) self_m.title, self_m.item_table = title, items end
        return o
    end }
    local done, called = nil, 0
    local ok, err = pcall(function()
        local rows = {}
        for i = 3, 7 do rows[#rows + 1] = { name = "Name " .. i } end
        local tiers = {
            picked = { { name = "Name 2", role = "a role" } },
            suggested = { { name = "Name 1" } },
            groups = { { label = "Cast", rows = rows } },
        }
        ImageGenerator.pickEntries(tiers, { "Name 2" }, function(names) done, called = names, called + 1 end)
        local texts = {}
        for _idx, it in ipairs(menu.item_table) do texts[#texts + 1] = it.text end
        TestRunner:assertEqual(table.concat(texts, "|"),
            "\u{2611} Name 2 \u{00B7} a role|Suggested|\u{2610} Name 1|Cast|\u{2610} Name 3|\u{2610} Name 4|\u{2610} Name 5|\u{2610} Name 6|\u{2610} Name 7",
            "the picked first, then the suggested and each category under a heading; no Done row")
        local function tap(label)
            for _idx, it in ipairs(menu.item_table) do
                if it.text:find(label, 1, true) then return menu.onMenuSelect(menu, it) end
            end
            error("no row " .. label)
        end
        TestRunner:assertTrue(menu.title:find("1 of 5", 1, true) ~= nil, menu.title)
        tap("Suggested")
        TestRunner:assertTrue(menu.title:find("1 of 5", 1, true) ~= nil, "a heading does nothing")
        tap("Name 4"); tap("Name 1"); tap("Name 2")
        TestRunner:assertTrue(menu.title:find("2 of 5", 1, true) ~= nil, "Name 2 cleared: " .. menu.title)
        TestRunner:assertTrue(menu.item_table[1].text:find("Name 2", 1, true) ~= nil,
            "a cleared row keeps its place")
        tap("Name 5"); tap("Name 6"); tap("Name 7")
        TestRunner:assertTrue(menu.title:find("5 of 5", 1, true) ~= nil, menu.title)
        tap("Name 3")
        TestRunner:assertTrue(menu.title:find("5 of 5", 1, true) ~= nil, "a sixth is refused")
        TestRunner:assertEqual(called, 0, "nothing handed back while it is open")
        menu.close_callback()
        TestRunner:assertEqual(table.concat(done or {}, "|"), "Name 4|Name 1|Name 5|Name 6|Name 7",
            "closing it (the X, Back) hands the list back in the order picked")
    end)
    package.loaded["ui/widget/menu"] = saved_menu
    if not ok then error(err, 0) end
end)

print("")
print("  [Names and matching (B533)]")

-- The book's alias file and its live X-Ray "on disk", in memory: the screen's
-- writes are checked without files. The view is the disk copy with the alias
-- file merged, as the browser reads it after every commit.
local function deepcopy(v)
    if type(v) ~= "table" then return v end
    local out = {}
    for k, x in pairs(v) do out[k] = deepcopy(x) end
    return out
end
local function namesHarness()
    local data, file = KoaMock.xray("Mock Series 3")
    local disk = KoaMock.xray("Mock Series 3")
    -- Gil Rook gets an alias from the AI, on both copies
    entry(data, "characters", "Gil Rook").aliases = { "the grafter" }
    entry(disk, "characters", "Gil Rook").aliases = { "the grafter" }
    local store, replays, auto = {}, {}, {}
    local saved_get, saved_set, saved_wiki = ActionCache.getUserAliases, ActionCache.setUserAliases,
        ActionCache.getWikiEntry
    local saved_auto, saved_counts = ActionCache.autoCaps, ActionCache.capsCounts
    ActionCache.getUserAliases = function() return deepcopy(store) end
    ActionCache.setUserAliases = function(_file, t) store = deepcopy(t) return true end
    ActionCache.getWikiEntry = function() return nil end
    -- the book's usage, as the name index would report it (B533 S3), and the
    -- rule's counts for one name (nil = not indexed yet)
    local counts
    ActionCache.autoCaps = function() return auto, "" end
    ActionCache.capsCounts = function() if counts then return counts[1], counts[2] end return nil end
    local WriteBack = require("koassistant.xray.artifact_writeback")
    local saved_replay = WriteBack.replayIntoRungs
    WriteBack.replayIntoRungs = function(_file, fn) replays[#replays + 1] = fn return 0 end
    local b = browser(data, file)
    local function view()
        local v = XrayParser.parse(XrayParser.serialize(disk))
        local overlay = deepcopy(store)
        if next(auto) then overlay[XrayParser.AUTO_CAPS_KEY] = auto end
        XrayParser.mergeUserAliases(v, overlay)
        return v
    end
    b.showItemDetail = function() end
    b._rebuildToDetail = function() end
    b._dismissDetail = function() end
    b._commitDormantOp = function(self, apply_fn)
        if not apply_fn(disk) then return false end
        self.xray_data = view()
        return true
    end
    b.reloadLiveMain = function(self)
        self.xray_data = view()
        return true
    end
    local h = { b = b, disk = disk, replays = replays, view = view }
    function h.store() return store end
    function h.setAuto(t) auto = t end
    function h.setCounts(p, l) counts = p and { p, l } or nil end
    function h.restore()
        ActionCache.getUserAliases, ActionCache.setUserAliases = saved_get, saved_set
        ActionCache.getWikiEntry = saved_wiki
        ActionCache.autoCaps, ActionCache.capsCounts = saved_auto, saved_counts
        WriteBack.replayIntoRungs = saved_replay
    end
    return h
end
local function rowsOf(w)
    return table.concat(ui:texts(w), " | ")
end
-- a name's choices (the one in force marked ●, the others ○)
local NOT_MATCHED = "Not matched (no underline, count or lookup)"

TestRunner:test("every name with what it is and whether it is matched", function()
    local h = namesHarness()
    local ok, err = pcall(function()
        ui.stack = {}
        h.b:editSearchTerms(entry(h.b.xray_data, "characters", "Gil Rook"), "characters", "Gil Rook")
        local names = ui:top()
        TestRunner:assertEqual(names.title, "Names of \"Gil Rook\"")
        TestRunner:assertTrue(ui:has("Gil Rook · main name · any case (automatic)", names), rowsOf(names))
        TestRunner:assertTrue(ui:has("the grafter · from the AI · matched", names),
            "a name with no capital is just matched: " .. rowsOf(names))
        TestRunner:assertTrue(ui:has("Add a name…", names) and ui:has("Close", names), rowsOf(names))
        TestRunner:assertTrue(not ui:has("Reset to the AI's names", names), "nothing differs yet")
    end)
    h.restore()
    if not ok then error(err, 0) end
end)

TestRunner:test("the main name stops matching: no form, no direct hit, still the entry's name", function()
    local h = namesHarness()
    local ok, err = pcall(function()
        local gil = entry(h.b.xray_data, "characters", "Gil Rook")
        ui.stack = {}
        h.b:editSearchTerms(gil, "characters", "Gil Rook")
        ui:tap("Gil Rook · main name · any case (automatic)")
        TestRunner:assertTrue(ui:has("Rename…") and ui:has("● Automatic (now any case)")
            and ui:has("○ " .. NOT_MATCHED), rowsOf())
        TestRunner:assertTrue(not ui:has("Delete"), "the AI's name is never deleted")
        ui:tap("○ " .. NOT_MATCHED)
        TestRunner:assertEqual(h.store()["Gil Rook"].ignore[1], "Gil Rook", "written to the alias file")
        TestRunner:assertTrue(ui:has("● " .. NOT_MATCHED) and ui:has("○ Automatic (now any case)"),
            "the choice stays open, the mark moved: " .. rowsOf())
        ui:tap("Back")
        TestRunner:assertTrue(ui:has("Gil Rook · main name · not matched"), rowsOf())
        TestRunner:assertTrue(ui:has("Reset to the AI's names"), rowsOf())
        -- a fresh read of the book, as every surface does
        local fresh = XrayParser.parse(XrayParser.serialize(h.disk))
        XrayParser.mergeUserAliases(fresh, h.store())
        local item = entry(fresh, "characters", "Gil Rook")
        local set = XrayParser.matchTermSet(item)
        TestRunner:assertEqual(table.concat(set.all, ","), "the grafter", "only the alias is matched")
        TestRunner:assertEqual(#XrayParser.searchAll(fresh, "Gil Rook", { exact = true }), 0, "no direct hit")
        TestRunner:assertEqual(#XrayParser.searchAll(fresh, "Gil Rook"), 1, "a typed search still lists it")
        local terms = XrayParser.collectSearchTerms(item)
        TestRunner:assertEqual(#terms, 1, "the search hand-over leaves it out")
        local handles = {}
        XrayParser.foldExactHandles(fresh, handles)
        TestRunner:assertTrue(not XrayParser.matchExactHandle(handles, "gil rook"), "the selection intercept too")
        -- and back
        ui:tap("Gil Rook · main name · not matched")
        ui:tap("○ Automatic (now any case)")
        ui:tap("Back")
        TestRunner:assertTrue(ui:has("Gil Rook · main name · any case (automatic)"), rowsOf())
        TestRunner:assertEqual(#(h.store()["Gil Rook"] or { ignore = {} }).ignore, 0, "out of the alias file")
    end)
    h.restore()
    if not ok then error(err, 0) end
end)

TestRunner:test("a rename keeps the AI's name matched, asks nothing, and Reset undoes it all", function()
    local h = namesHarness()
    local ok, err = pcall(function()
        ui.stack = {}
        h.b:editSearchTerms(entry(h.b.xray_data, "characters", "Gil Rook"), "characters", "Gil Rook")
        ui:tap("Gil Rook · main name · any case (automatic)")
        ui:tap("Rename…")
        ui:type("Gil Rookwood")
        ui:tap("Rename")
        local names = ui:top()
        TestRunner:assertEqual(names.title, "Names of \"Gil Rookwood\"", "the screen of the renamed entry, no question")
        TestRunner:assertTrue(ui:has("Gil Rook · the AI's name · any case (automatic)", names), rowsOf(names))
        local rec = h.store()["Gil Rookwood"]
        TestRunner:assertEqual(rec.ai_name, "Gil Rook", "the record holds the AI's name")
        TestRunner:assertEqual(rec.typed[1], "Gil Rookwood", "and the typed one")
        TestRunner:assertEqual(#h.replays, 1, "the built checkpoints take the rename")
        -- the AI's alias as the main name: the typed name becomes a name of the reader's
        ui:tap("the grafter · from the AI · matched", names)
        ui:tap("Make it the main name")
        names = ui:top()
        TestRunner:assertEqual(names.title, "Names of \"the grafter\"")
        TestRunner:assertTrue(ui:has("Gil Rookwood · your name · any case (automatic)", names), rowsOf(names))
        TestRunner:assertEqual(h.store()["the grafter"].ai_name, "Gil Rook", "the AI's name kept through renames")
        TestRunner:assertEqual(#h.store()["the grafter"].typed, 1, "the AI's alias is not a typed name")
        -- the reader's own name deletes
        ui:tap("Gil Rookwood · your name · any case (automatic)", names)
        ui:tap("Delete")
        local grafter = entry(h.disk, "characters", "the grafter")
        for _idx, a in ipairs(grafter.aliases or {}) do
            TestRunner:assertTrue(a ~= "Gil Rookwood", "out of the X-Ray's aliases")
        end
        TestRunner:assertTrue(h.store()["the grafter"].typed == nil or #h.store()["the grafter"].typed == 0,
            "out of the record")
        -- Reset: the AI's name and aliases back, the record gone
        ui:tap("Reset to the AI's names")
        ui:tap("Reset")
        local gil = entry(h.disk, "characters", "Gil Rook")
        TestRunner:assertEqual(table.concat(gil.aliases or {}, ","), "the grafter", "the AI's aliases as they were")
        TestRunner:assertTrue(h.store()["Gil Rook"] == nil and h.store()["the grafter"] == nil, "the record cleared")
    end)
    h.restore()
    if not ok then error(err, 0) end
end)

TestRunner:test("an upcoming entity's names and matching from its full entry (#120): the same rows, choices and record", function()
    local h = namesHarness()
    local ok, err = pcall(function()
        local CAPS = "Capitals only (\"Lady\", not \"lady\")"
        local hit = { source = "ahead", ahead_progress = 0.5, query = "lady", name = "Lady", category_key = "characters",
            item = { name = "Lady", description = "A direwolf.", aliases = { "the she-wolf" } } }
        ui.stack = {}
        XrayBrowser.showUpcomingNames(hit, "/mock/book.epub")
        TestRunner:assertEqual(ui:top().title, "Names of \"Lady\" (from the next checkpoint)")
        TestRunner:assertTrue(ui:has("Lady · main name · any case (automatic)") and ui:has("the she-wolf · from the AI · matched"),
            rowsOf())
        TestRunner:assertTrue(not ui:has("Add a name…") and not ui:has("Reset to the AI's names"), "nothing that edits the X-Ray: " .. rowsOf())
        ui:tap("Lady · main name · any case (automatic)")
        TestRunner:assertTrue(ui:has("● Automatic (now any case)") and ui:has("○ " .. CAPS) and ui:has("○ " .. NOT_MATCHED), rowsOf())
        TestRunner:assertTrue(not ui:has("Rename…") and not ui:has("Delete"), "no rename or delete on an upcoming entity: " .. rowsOf())
        ui:tap("○ " .. CAPS)
        TestRunner:assertEqual(h.store()["Lady"].case["lady"], "capitals", "written to the alias file, by the entry's name")
        TestRunner:assertTrue(hit.item._caps and hit.item._caps["lady"] == true, "the entry in hand follows")
        TestRunner:assertTrue(ui:has("● " .. CAPS) and ui:has("○ Automatic (now any case)"), "the list stays open, the mark moved: " .. rowsOf())
        ui:tap("○ " .. NOT_MATCHED)
        TestRunner:assertEqual(h.store()["Lady"].ignore[1], "Lady", "not matched")
        TestRunner:assertTrue(hit.item._name_off == true)
        ui:tap("Back")
        TestRunner:assertTrue(ui:has("Lady · main name · not matched"), rowsOf())
        ui:tap("Close")
        TestRunner:assertEqual(ui:top(), nil, "closed")
    end)
    h.restore()
    if not ok then error(err, 0) end
end)
TestRunner:test("the reveal box's Matching… holds the tapped name alone, under its own words; the full entry's every name (B590)", function()
    local h = namesHarness()
    local ok, err = pcall(function()
        -- the spoiler-surfaces sweep's reproduction: a nickname tapped before
        -- Reveal; the list was titled with the entry's name and listed every alias
        local hit = { source = "ahead", ahead_progress = 0.5, query = "the Ferryman", name = "Osric Dunmere",
            category_key = "characters",
            item = { name = "Osric Dunmere", description = "A ferryman of the marsh. Secretly the lost heir.",
                aliases = { "the Ferryman", "the Lost Heir" } } }
        local function nothingOfTheEntry(where)
            local all = tostring(ui:top().title) .. "|" .. rowsOf()
            TestRunner:assertTrue(not all:find("Osric", 1, true) and not all:find("Dunmere", 1, true)
                and not all:find("Lost Heir", 1, true) and not all:find("from the AI", 1, true)
                and not all:find("main name", 1, true), where .. ": " .. all)
        end
        ui.stack = {}
        XrayBrowser.showUpcomingNames(hit, "/mock/book.epub", { tapped = true })
        TestRunner:assertEqual(ui:top().title, "Matching of \"the Ferryman\" (from the next checkpoint)")
        TestRunner:assertEqual(rowsOf(), "the Ferryman · any case (automatic) | Close", "the tapped name alone, not what it is")
        nothingOfTheEntry("the list")
        ui:tap("the Ferryman · any case (automatic)")
        TestRunner:assertEqual((tostring(ui:top().title):match("^[^\n]+")), "the Ferryman", "the choices under the tapped word alone")
        TestRunner:assertTrue(ui:has("○ " .. NOT_MATCHED) and ui:has("● Automatic (now any case)"), rowsOf())
        nothingOfTheEntry("the choices")
        ui:tap("○ " .. NOT_MATCHED)
        TestRunner:assertEqual(h.store()["Osric Dunmere"].ignore[1], "the Ferryman", "saved by the entry's name, as the full list saves")
        TestRunner:assertTrue(ui:has("● " .. NOT_MATCHED), "the list stays open, the mark moved: " .. rowsOf())
        ui:tap("Back")
        TestRunner:assertEqual(rowsOf(), "the Ferryman · not matched | Close")
        nothingOfTheEntry("the list after the pick")
        ui:tap("Close")
        TestRunner:assertEqual(ui:top(), nil, "closed")
        -- after Reveal, the full entry's Matching…: every name, the pick kept
        ui.stack = {}
        XrayBrowser.showUpcomingNames(hit, "/mock/book.epub")
        TestRunner:assertEqual(ui:top().title, "Names of \"Osric Dunmere\" (from the next checkpoint)")
        TestRunner:assertTrue(ui:has("Osric Dunmere · main name · any case (automatic)")
            and ui:has("the Lost Heir · from the AI · any case (automatic)")
            and ui:has("the Ferryman · from the AI · not matched"), rowsOf())
    end)
    h.restore()
    if not ok then error(err, 0) end
end)

TestRunner:test("the box's wiring in main.lua: the box's Matching… passes the tapped name, the full entry's does not (B590)", function()
    local here = debug.getinfo(1, "S").source:match("@?(.*)")
    local root = here:gsub("/?tests/unit/[^/]+$", "")
    if root == "" then root = "." end
    local f = assert(io.open(root .. "/main.lua", "r"))
    local src = f:read("*all")
    f:close()
    local at = assert(src:find('ok_text = _("Reveal")', 1, true), "the ahead confirm")
    local block = src:sub(math.max(1, at - 1800), at + 400)
    TestRunner:assertTrue(block:find("showUpcomingNames(h, file, tapped and { tapped = true } or nil)", 1, true) ~= nil,
        "one opener, the tapped flag decides")
    TestRunner:assertTrue(block:find('other_buttons = {{{ text = _("Matching…"), callback = function() matching(true) end }}}', 1, true) ~= nil,
        "the box passes the tapped name")
    TestRunner:assertTrue(block:find('buttons_table = {{{ text = _("Matching…"), callback = function() matching(false) end }}}', 1, true) ~= nil,
        "the full entry lists every name")
end)

TestRunner:test("capitals: automatic, capitals only, any case; one choice marked, the row says which, Reset clears it (S2, S3)", function()
    local h = namesHarness()
    local ok, err = pcall(function()
        local CAPS = "Capitals only (\"the Drowned\", not \"the drowned\")"
        local ANY = "Any case (\"the Drowned\" and \"the drowned\")"
        ui.stack = {}
        h.b:editSearchTerms(entry(h.b.xray_data, "characters", "The Drowned"), "characters", "The Drowned")
        ui:tap("The Drowned · main name · any case (automatic)")
        TestRunner:assertTrue(ui:has("● Automatic (now any case)") and ui:has("○ " .. CAPS) and ui:has("○ " .. ANY)
            and ui:has("○ " .. NOT_MATCHED), "every choice, automatic marked: " .. rowsOf())
        TestRunner:assertTrue(ui:top().title:find("Automatic decides from how the book writes the name, once the book's names are indexed.", 1, true) ~= nil,
            "the title says what automatic is, and that the index has no counts yet: " .. tostring(ui:top().title))
        -- the index has the book: the rule's own counts (#120)
        h.setCounts(3, 1)
        ui:tap("Back")
        ui:tap("The Drowned · main name · any case (automatic)")
        TestRunner:assertTrue(ui:top().title:find("Automatic decides from how the book writes the name: its capitals in 3 of 4 counted uses.", 1, true) ~= nil,
            "the counts: " .. tostring(ui:top().title))
        h.setCounts(nil)
        ui:tap("○ " .. CAPS)
        TestRunner:assertEqual(h.store()["The Drowned"].case["the drowned"], "capitals", "written to the alias file")
        TestRunner:assertTrue(ui:has("● " .. CAPS) and ui:has("○ Automatic (now any case)"),
            "the choice stays open, the mark moved: " .. rowsOf())
        ui:tap("Back")
        TestRunner:assertTrue(ui:has("The Drowned · main name · capitals only"), rowsOf())
        TestRunner:assertTrue(ui:has("Reset to the AI's names"), rowsOf())
        -- a fresh read of the book, as every surface does: the matcher asks the capitals
        local fresh = XrayParser.parse(XrayParser.serialize(h.disk))
        XrayParser.mergeUserAliases(fresh, h.store())
        TestRunner:assertEqual(XrayParser.matchTermSet(entry(fresh, "characters", "The Drowned")).caps["the drowned"], 2)
        -- any case, picked: the record says so, the row too
        ui:tap("The Drowned · main name · capitals only")
        ui:tap("○ " .. ANY)
        TestRunner:assertEqual(h.store()["The Drowned"].case["the drowned"], "any", "kept as the reader's pick")
        ui:tap("Back")
        TestRunner:assertTrue(ui:has("The Drowned · main name · any case"), rowsOf())
        -- the book writes it both ways: the rule sets capitals only, unless picked otherwise
        h.setAuto({ ["the drowned"] = true })
        fresh = h.view()
        TestRunner:assertTrue(XrayParser.matchTermSet(entry(fresh, "characters", "The Drowned")).caps == nil,
            "Any case keeps the automatic rule off the name")
        ui:tap("The Drowned · main name · any case")
        TestRunner:assertTrue(ui:has("● " .. ANY) and ui:has("○ Automatic (now capitals only)"),
            "automatic says what it would do: " .. rowsOf())
        ui:tap("○ Automatic (now capitals only)")
        TestRunner:assertEqual(h.store()["The Drowned"].case, nil, "out of the alias file: automatic again")
        TestRunner:assertTrue(ui:has("● Automatic (now capitals only)"), rowsOf())
        ui:tap("Back")
        TestRunner:assertTrue(ui:has("The Drowned · main name · capitals only (automatic)"), rowsOf())
        fresh = h.view()
        TestRunner:assertEqual(XrayParser.matchTermSet(entry(fresh, "characters", "The Drowned")).caps["the drowned"], 2,
            "the automatic choice reaches the matcher")
        -- not matched, then a capitals choice: matched again with that choice, in one tap
        ui:tap("The Drowned · main name · capitals only (automatic)")
        ui:tap("○ " .. NOT_MATCHED)
        TestRunner:assertEqual(h.store()["The Drowned"].ignore[1], "The Drowned", "not matched")
        ui:tap("○ " .. ANY)
        TestRunner:assertEqual(#h.store()["The Drowned"].ignore, 0, "matched again")
        TestRunner:assertEqual(h.store()["The Drowned"].case["the drowned"], "any", "with the choice")
        ui:tap("Back")
        TestRunner:assertTrue(ui:has("The Drowned · main name · any case"), rowsOf())
        -- Reset clears the pick with the rest: automatic again
        ui:tap("Reset to the AI's names")
        ui:tap("Reset")
        TestRunner:assertEqual(h.store()["The Drowned"], nil, "the record cleared")
        TestRunner:assertTrue(ui:has("The Drowned · main name · capitals only (automatic)")
            and not ui:has("Reset to the AI's names"), rowsOf())
        h.setAuto({})
        -- a one-word term names itself; a name with no capital is matched or not, nothing else
        ui.stack = {}
        h.b:editSearchTerms(entry(h.b.xray_data, "lexicon", "Warden"), "lexicon", "Warden")
        ui:tap("Warden · main name · any case (automatic)")
        TestRunner:assertTrue(ui:has("○ Capitals only (\"Warden\", not \"warden\")"), rowsOf())
        ui.stack = {}
        h.b:editSearchTerms(entry(h.b.xray_data, "characters", "Gil Rook"), "characters", "Gil Rook")
        ui:tap("the grafter · from the AI · matched")
        TestRunner:assertTrue(ui:has("● Matched") and ui:has("○ " .. NOT_MATCHED), rowsOf())
        for _idx, t in ipairs(ui:texts()) do
            TestRunner:assertTrue(not t:find("apitals", 1, true) and not t:find("case", 1, true),
                "no capital to require: " .. rowsOf())
        end
        TestRunner:assertTrue(not ui:top().title:find("Automatic", 1, true), "nor a word about it in the title")
    end)
    h.restore()
    if not ok then error(err, 0) end
end)

TestRunner:test("a rebuild that names the entry as the AI did gets the reader's name back", function()
    local rebuilt = KoaMock.xray("Mock Series 3")
    local records = { ["Gil Rookwood"] = { ai_name = "Gil Rook", typed = { "Gil Rookwood", "Rook the Younger" } } }
    TestRunner:assertEqual(XrayParser.keepRenames(rebuilt, records), 1)
    local gil = entry(rebuilt, "characters", "Gil Rookwood")
    TestRunner:assertEqual(gil.aliases[1], "Gil Rook", "the AI's name as the first alias")
    TestRunner:assertTrue(table.concat(gil.aliases, ","):find("Rook the Younger", 1, true) ~= nil,
        "the reader's other typed names as aliases")
    TestRunner:assertEqual(XrayParser.keepRenames(rebuilt, records), 0, "an update that carried it: nothing to do")
end)

print("")
print("  [Merge with another entry]")

-- The duplicate flow seeded from an entry, on an in-memory disk copy; the
-- entry page is a shown widget, so the test sees whether it stays
local UIManager = require("ui/uimanager")
local function mergeHarness()
    local data, file = KoaMock.xray("Mock Series 3")
    local h = { disk = KoaMock.xray("Mock Series 3"), writes = 0 }
    local WriteBack = require("koassistant.xray.artifact_writeback")
    local saved_cache, saved_get, saved_set = ActionCache.getXrayCache, ActionCache.getUserAliases,
        ActionCache.setUserAliases
    local saved_ladder, saved_never, saved_commit = ActionCache.getXrayLadder, ActionCache.addNeverMergePair,
        WriteBack.commitXray
    ActionCache.getXrayCache = function()
        return { result = XrayParser.serialize(h.disk), progress_decimal = 0.5 }
    end
    ActionCache.getUserAliases = function() return {} end
    ActionCache.setUserAliases = function() return true end
    ActionCache.getXrayLadder = function() return {} end
    ActionCache.addNeverMergePair = function() h.never = true end
    WriteBack.commitXray = function(_file, json_text)
        h.disk = XrayParser.parse(json_text)
        h.writes = h.writes + 1
        return true
    end
    local b = browser(data, file)
    b.reloadLiveMain = function(self)
        self.xray_data = XrayParser.parse(XrayParser.serialize(h.disk))
        return true
    end
    b._rebuildToDetail = function(_self, cat, name) h.rebuilt = cat .. "/" .. name end
    -- the entry page: closes like the TextViewer it is
    h.page = { onClose = function(w) UIManager:close(w) end }
    h.b = b
    function h.open()
        ui.stack = {}
        UIManager:show(h.page)
        b._detail_viewer = h.page
        b:_showEntityManagePopup(entry(b.xray_data, "characters", "Gil Rook"), "characters",
            "Gil Rook", nil, nil, h.page, true, {})
        ui:tap("Merge with another entry…")
    end
    function h.restore()
        ActionCache.getXrayCache, ActionCache.getUserAliases = saved_cache, saved_get
        ActionCache.setUserAliases, ActionCache.getXrayLadder = saved_set, saved_ladder
        ActionCache.addNeverMergePair, WriteBack.commitXray = saved_never, saved_commit
    end
    return h
end
local PICK = "Pick the entry to pair with \"Gil Rook\""

TestRunner:test("the entry page stays under the pick: Cancel, Back and a tap outside land on it", function()
    local h = mergeHarness()
    local ok, err = pcall(function()
        h.open()
        local pick = ui:top()
        TestRunner:assertEqual(pick.title, PICK)
        TestRunner:assertTrue(UIManager:isWidgetShown(h.page), "the entry page is still open")
        TestRunner:assertTrue(ui:has("Jory", pick) and not ui:has("Gil Rook", pick), rowsOf(pick))
        ui:tap("Cancel", pick)
        TestRunner:assertTrue(ui:top() == h.page, "Cancel: the entry page")
        -- the pair's Back and a tap outside it: the pick again, never the duplicates list
        h.open()
        ui:tap("Jory")
        TestRunner:assertTrue(ui:has("Merge: keep \"Gil Rook\""), rowsOf())
        ui:tap("Back")
        TestRunner:assertEqual(ui:top().title, PICK)
        ui:tap("Jory")
        ui:tapOutside()
        TestRunner:assertEqual(ui:top().title, PICK)
        ui:tap("Cancel")
        TestRunner:assertTrue(ui:top() == h.page and h.writes == 0, "nothing written, the page on top")
        -- Never suggest: remembered, and back on the page
        h.open()
        ui:tap("Jory")
        ui:tap("Never suggest this pair")
        ui:tap("Never merge")
        TestRunner:assertTrue(h.never, "the pair remembered")
        TestRunner:assertTrue(UIManager:isWidgetShown(h.page) and h.rebuilt == nil, "the page stays")
        TestRunner:assertTrue(not tostring(ui:top().title or ""):find("Possible duplicate", 1, true),
            "no duplicates list")
    end)
    h.restore()
    if not ok then error(err, 0) end
end)

TestRunner:test("a merge lands on the kept entry", function()
    local h = mergeHarness()
    local ok, err = pcall(function()
        h.open()
        ui:tap("Jory")
        ui:tap("Merge: keep \"Gil Rook\"")
        TestRunner:assertEqual(h.writes, 1, "the merge written")
        TestRunner:assertTrue(not UIManager:isWidgetShown(h.page), "the old page closed")
        TestRunner:assertEqual(h.rebuilt, "characters/Gil Rook", "rebuilt onto the kept entry")
        local gil = entry(h.b.xray_data, "characters", "Gil Rook")
        TestRunner:assertTrue(table.concat(gil.aliases or {}, ","):find("Jory", 1, true) ~= nil,
            "Jory is one of his names now")
        for _idx, w in ipairs(ui.stack) do
            TestRunner:assertTrue(not tostring(w.title or ""):find("Possible duplicate", 1, true),
                "no duplicates list")
        end
    end)
    h.restore()
    if not ok then error(err, 0) end
end)

TestRunner:test("an AI merge lands on the kept entry; one the AI declines leaves the page", function()
    local XrayMerge = require("koassistant.xray.xray_merge")
    local saved_access, saved_cfg = XrayMerge.withDataAccess, XrayMerge.buildHeadlessConfig
    local saved_dialogs = package.loaded["koassistant.ui.dialogs"]
    local answer
    XrayMerge.withDataAccess = function(_opts, _books, _name, run) run({ features = features }) end
    XrayMerge.buildHeadlessConfig = function() return {}, {} end
    package.loaded["koassistant.ui.dialogs"] = {
        executeActionForResult = function(_action, _text, _ui, _config, _plugin, _bm, done) done(answer) end,
    }
    local AI_ROW = "AI merge: combined description, keep \"Gil Rook\""
    local ok, err = pcall(function()
        local h = mergeHarness()
        local ok2, err2 = pcall(function()
            answer = "DIFFERENT ENTITIES\nA grafter and a boy who share an orchard."
            h.open()
            ui:tap("Jory")
            ui:tap(AI_ROW)
            ui:tap("Not now")
            TestRunner:assertTrue(h.writes == 0 and h.rebuilt == nil, "declined: nothing written or rebuilt")
            TestRunner:assertTrue(UIManager:isWidgetShown(h.page), "the page stays")
            answer = "A grafter of the orchard, also called Jory."
            h.open()
            ui:tap("Jory")
            ui:tap(AI_ROW)
            TestRunner:assertEqual(h.writes, 1, "the merge written")
            TestRunner:assertEqual(h.rebuilt, "characters/Gil Rook", "rebuilt onto the kept entry")
            TestRunner:assertTrue(not UIManager:isWidgetShown(h.page), "the old page closed")
            TestRunner:assertEqual(entry(h.b.xray_data, "characters", "Gil Rook").description,
                "A grafter of the orchard, also called Jory.", "the combined description")
        end)
        h.restore()
        if not ok2 then error(err2, 0) end
    end)
    XrayMerge.withDataAccess, XrayMerge.buildHeadlessConfig = saved_access, saved_cfg
    package.loaded["koassistant.ui.dialogs"] = saved_dialogs
    if not ok then error(err, 0) end
end)

TestRunner:test("a PDF hit counts when the term is the matched words as a whole (B600)", function()
    local whole = XrayBrowser._pdfWholeWord
    TestRunner:assertTrue(whole("Christian", "Christ") == false, "Christ inside Christian")
    TestRunner:assertTrue(whole("Hannah", "Ann") == false, "Ann inside Hannah")
    TestRunner:assertTrue(whole("Christ,", "Christ") == true, "a trailing comma is no letter")
    TestRunner:assertTrue(whole("Ann", "Ann") == true)
    TestRunner:assertTrue(whole("Ann Lee", "Ann Lee") == true, "a two-word term")
    TestRunner:assertTrue(whole("\226\128\156Christ\226\128\157", "Christ") == true, "quotes around it")
    TestRunner:assertTrue(whole(nil, "Christ") == true, "no matched text: nothing to judge, kept")
    TestRunner:assertTrue(whole("Christian", "") == true, "no term: kept")
end)

-- ------------------------------------------------------------------ cleanup
ui:restore()
ActionCache.getPromotedStubs, ActionCache.getXrayLadderCount = saved_promoted, saved_ladder
SDS.resolve, SDS.overlayCustomProps = saved_resolve, saved_overlay
package.loaded["koassistant.xray.xray_browser"] = had_browser
for i = #saved, 1, -1 do package.loaded[saved[i].name] = saved[i].value end

return TestRunner:summary()
