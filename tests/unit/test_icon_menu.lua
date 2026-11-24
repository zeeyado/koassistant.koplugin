-- The menu that hangs from a title bar's icon (koassistant/ui/icon_menu.lua):
-- what it shows and where, the settings row every full page's menu ends with
-- (a full page covers the reader and KOReader's gestures with it), and two
-- guards: a page with a ☰ icon opens its rows under that icon (the Book Hub's
-- floated in the middle of the screen), and each full page's menu has the
-- way to the settings.
--
-- Run: lua tests/unit/test_icon_menu.lua  (or lua tests/run_tests.lua --unit)

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
local TestRunner = require("test_runner"):new()
local Recorder = require("ui_recorder")

local function source(rel)
    local handle = assert(io.open(PLUGIN_DIR .. "/" .. rel, "r"))
    local text = handle:read("*a")
    handle:close()
    return text
end

print("  the menu under a title bar's icon")

TestRunner:test("the rows hang from the icon: left-aligned, as wide as their text, no title", function()
    local ui = Recorder.install()
    local IconMenu = require("koassistant.ui.icon_menu")
    local icon = { x = 12, y = 20, w = 48, h = 48 }
    local page = { title_bar = { left_button = { image = { dimen = icon } } } }
    local dialog = IconMenu.show(page, {
        { text = "Refresh", callback = function() end },
        { text = "Delete all…", callback = function() end, enabled = false },
    })
    local top = ui:top()
    local at, below = dialog.anchor()
    ui:restore()
    TestRunner:assertTrue(top == dialog, "the menu is the window on top")
    TestRunner:assertEqual(dialog._widget, "ui/widget/buttondialog")
    TestRunner:assertTrue(at == icon, "placed by the icon's own rectangle")
    TestRunner:assertTrue(below == true, "and under it")
    TestRunner:assertTrue(dialog.shrink_unneeded_width == true, "as wide as its rows")
    TestRunner:assertEqual(dialog.title, nil, "no title: the page names itself")
    TestRunner:assertEqual(#dialog.buttons, 2, "one row per entry")
    for _idx, row in ipairs(dialog.buttons) do
        TestRunner:assertEqual(#row, 1, "a row is one button")
        TestRunner:assertEqual(row[1].align, "left")
    end
    TestRunner:assertTrue(dialog.buttons[2][1].enabled == false, "a row that cannot run is shown greyed")
end)

TestRunner:test("a tap closes the menu, then runs the row", function()
    local ui = Recorder.install()
    local IconMenu = require("koassistant.ui.icon_menu")
    local page = { title_bar = { left_button = { image = { dimen = { x = 0, y = 0, w = 40, h = 40 } } } } }
    local dialog
    local seen
    dialog = IconMenu.show(page, {
        { text = "Export", callback = function() seen = { open = ui.UIManager:isWidgetShown(dialog) } end },
    })
    ui:tap("Export")
    local left = ui:top()
    ui:restore()
    TestRunner:assertTrue(seen ~= nil, "the row ran")
    TestRunner:assertTrue(seen.open == false, "with the menu already closed")
    TestRunner:assertEqual(left, nil, "and nothing is left on screen")
end)

TestRunner:test("the settings row: Quick Settings, last, under a double line, where the page hands the plugin over", function()
    local ui = Recorder.install()
    local IconMenu = require("koassistant.ui.icon_menu")
    local opened = 0
    local plugin = { onKOAssistantAISettings = function() opened = opened + 1 end }
    local page = { title_bar = { left_button = { image = { dimen = { x = 0, y = 0, w = 40, h = 40 } } } } }
    local dialog
    local seen
    plugin.onKOAssistantAISettings = function() opened = opened + 1; seen = ui.UIManager:isWidgetShown(dialog) end
    dialog = IconMenu.show(page, { { text = "Refresh", callback = function() end } }, plugin)
    local rows = #dialog.buttons
    local gap, last = dialog.buttons[2], dialog.buttons[3]
    ui:tap("Quick Settings")
    ui:restore()
    TestRunner:assertEqual(rows, 3, "the page's row, a double line, the settings row")
    TestRunner:assertEqual(#gap, 0, "an empty row: KOReader's double line")
    TestRunner:assertEqual(last[1].text, "Quick Settings")
    TestRunner:assertEqual(last[1].align, "left")
    TestRunner:assertEqual(opened, 1, "a tap opens the panel")
    TestRunner:assertTrue(seen == false, "with the menu closed first")
    -- a caller with no plugin at hand gets its rows alone
    ui = Recorder.install()
    local bare = IconMenu.show(page, { { text = "Refresh", callback = function() end } })
    ui:restore()
    TestRunner:assertEqual(#bare.buttons, 1)
    TestRunner:assertEqual(IconMenu.settingsRow(nil), nil)
    TestRunner:assertEqual(IconMenu.settingsRow({}), nil, "an instance that has no panel")
end)

TestRunner:test("a menu a page builds by hand gets the same row: its own rows kept, its own close run first", function()
    local IconMenu = require("koassistant.ui.icon_menu")
    local order = {}
    local plugin = { onKOAssistantAISettings = function() order[#order + 1] = "panel" end }
    local own = { {{ text = "Chat History" }}, {}, {{ text = "Browse by type…" }} }
    local out = IconMenu.withSettings(own, plugin, function() order[#order + 1] = "closed" end)
    TestRunner:assertTrue(out == own, "the page's own table, added to")
    TestRunner:assertEqual(#own, 5)
    TestRunner:assertEqual(own[1][1].text, "Chat History", "its rows are untouched")
    TestRunner:assertEqual(#own[4], 0)
    TestRunner:assertEqual(own[5][1].text, "Quick Settings")
    own[5][1].callback()
    TestRunner:assertEqual(table.concat(order, ","), "closed,panel")
    local alone = { {{ text = "Chat History" }} }
    IconMenu.withSettings(alone, nil, function() end)
    TestRunner:assertEqual(#alone, 1, "no plugin, nothing added")
end)

-- A page whose title bar carries the ☰ icon opens rows, and rows hang from the
-- icon: through IconMenu, or (the pages built before it) a dialog of their own
-- that names an anchor. A page with the icon and neither is the fault this
-- guards against.
TestRunner:test("every page with a ☰ icon opens its rows under the icon", function()
    local list = assert(io.popen('cd "' .. PLUGIN_DIR .. '" && ls main.lua && find koassistant -name "*.lua" | LC_ALL=C sort'))
    local pages, floating = 0, {}
    for rel in list:lines() do
        local text = source(rel)
        local has_icon = false
        for line in text:gmatch("[^\n]+") do
            if line:find("title_bar_left_icon%s*=") and line:find('"appbar.menu"', 1, true) then has_icon = true end
        end
        if has_icon then
            pages = pages + 1
            local hangs = text:find('icon_menu").show(', 1, true) or text:find("[%s%.]anchor%s*=%s*function")
            if not hangs then floating[#floating + 1] = rel end
        end
    end
    list:close()
    TestRunner:assertTrue(pages >= 10, "the pages were found (" .. pages .. ")")
    TestRunner:assertEqual(table.concat(floating, ", "), "", "a ☰ menu that hangs from nothing")
end)

-- The full pages (they cover the reader; the pickers and the settings' own
-- managers are not among them): each one's menu ends with the settings row,
-- through the one helper. `menus` = how many ☰ menus the file builds.
local FULL_PAGES = {
    { file = "koassistant/books/book_page.lua", menus = 1 },
    { file = "koassistant/books/group_page.lua", menus = 1 },       -- one builder, the hub's and the list's
    { file = "koassistant/xray/xray_browser.lua", menus = 1 },
    { file = "koassistant/chat/chat_history_dialog.lua", menus = 5 },
    { file = "koassistant/chat/notebook_manager.lua", menus = 1 },
    { file = "koassistant/artifacts/artifact_browser.lua", menus = 1 },
    { file = "koassistant/images/image_browser.lua", menus = 1 },   -- one builder, the grid's and the list's
}

TestRunner:test("every full page's menu ends with the way to the settings", function()
    for _i, page in ipairs(FULL_PAGES) do
        local text = source(page.file)
        local n = 0
        for _ in text:gmatch('icon_menu"%)%.withSettings%(') do n = n + 1 end
        -- a menu shown through the helper hands it the plugin as the third argument:
        -- on the call's own line, or on the line that closes its rows
        local at = 1
        while true do
            local from, to = text:find('icon_menu").show(', at, true)
            if not from then break end
            local line_end = text:find("\n", to, true) or #text
            local first = text:sub(to + 1, line_end - 1)
            local closing = first
            if not first:find("%)%s*$") then
                closing = text:match("\n%s*}(,[^\n]*%))%s*\n", line_end) or ""
            end
            if closing:lower():find("plugin") then n = n + 1 end
            at = line_end
        end
        TestRunner:assertEqual(n, page.menus, page.file .. ": menus with the settings row")
    end
    -- the Book Hub's menu shows through the helper, on the page's own icon
    local book = source("koassistant/books/book_page.lua")
    local from = book:find("local function showHamburger", 1, true)
    TestRunner:assertTrue(from ~= nil, "the Book Hub's menu builder")
    local body = book:sub(from, book:find("\nend\n", from, true))
    TestRunner:assertTrue(body:find('icon_menu").show(BookPage._menu', 1, true) ~= nil, "hangs from the page's own icon")
    TestRunner:assertEqual(body:find("ButtonDialog", 1, true), nil, "no dialog of its own")
end)

TestRunner:test("the picture gallery's icon opens a menu: deleting everything is a row, not the icon itself", function()
    local text = source("koassistant/images/image_browser.lua")
    TestRunner:assertEqual(text:find("on_menu = function() deleteAll", 1, true), nil, "the grid's icon")
    TestRunner:assertEqual(text:find("onLeftButtonTap = function() deleteAll", 1, true), nil, "the list's icon")
    TestRunner:assertTrue(text:find('_("Delete all images…")', 1, true) ~= nil, "the row")
end)

return TestRunner:summary()
