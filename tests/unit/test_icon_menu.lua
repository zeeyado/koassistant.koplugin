-- The menu that hangs from a title bar's icon (koassistant/ui/icon_menu.lua):
-- what it shows and where, and a guard that a page with a ☰ icon opens its
-- rows under that icon (the Book Hub's floated in the middle of the screen).
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

-- A page whose title bar carries the ☰ icon opens rows, and rows hang from the
-- icon: through IconMenu, or (the pages built before it) a dialog of their own
-- that names an anchor. A page with the icon and neither is the fault this
-- guards against. The one page whose icon runs a single action is listed, and
-- must leave the list when it gets a menu.
local NO_MENU = {
    ["koassistant/images/image_browser.lua"] = "its icon asks to delete every picture, with no menu between",
}

TestRunner:test("every page with a ☰ icon opens its rows under the icon", function()
    local list = assert(io.popen('cd "' .. PLUGIN_DIR .. '" && ls main.lua && find koassistant -name "*.lua" | LC_ALL=C sort'))
    local pages, floating, stale = 0, {}, {}
    for rel in list:lines() do
        local text = source(rel)
        local has_icon = false
        for line in text:gmatch("[^\n]+") do
            if line:find("title_bar_left_icon%s*=") and line:find('"appbar.menu"', 1, true) then has_icon = true end
        end
        if has_icon then
            pages = pages + 1
            local hangs = text:find('icon_menu").show(', 1, true) or text:find("[%s%.]anchor%s*=%s*function")
            if NO_MENU[rel] then
                if hangs then stale[#stale + 1] = rel end
            elseif not hangs then
                floating[#floating + 1] = rel
            end
        end
    end
    list:close()
    TestRunner:assertTrue(pages >= 10, "the pages were found (" .. pages .. ")")
    TestRunner:assertEqual(table.concat(floating, ", "), "", "a ☰ menu that hangs from nothing")
    TestRunner:assertEqual(table.concat(stale, ", "), "", "listed as having no menu, and has one now: take it off the list")
end)

TestRunner:test("the Book Hub and the Group Hub build their menu through the one copy", function()
    local book = source("koassistant/books/book_page.lua")
    local from = book:find("local function showHamburger", 1, true)
    TestRunner:assertTrue(from ~= nil, "the Book Hub's menu builder")
    local body = book:sub(from, book:find("\nend\n", from, true))
    TestRunner:assertTrue(body:find('icon_menu").show(BookPage._menu', 1, true) ~= nil, "hangs from the page's own icon")
    TestRunner:assertEqual(body:find("ButtonDialog", 1, true), nil, "no dialog of its own")
    local group = source("koassistant/books/group_page.lua")
    TestRunner:assertTrue(group:find('icon_menu").show(menu, rows)', 1, true) ~= nil, "the Group Hub's and the groups list's")
end)

return TestRunner:summary()
