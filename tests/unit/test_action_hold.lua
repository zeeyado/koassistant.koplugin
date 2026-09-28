-- The shared action hold menu (koassistant_action_hold.lua, 2026-09-07, B122):
-- the row plan per source and surface, and the membership pair per surface.
--
-- Run: lua tests/unit/test_action_hold.lua  (or lua tests/run_tests.lua --unit)

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
local ActionHold = require("koassistant_action_hold")
local TestRunner = require("test_runner"):new()

local function ids(rows)
    local out = {}
    for _idx, r in ipairs(rows) do out[#out + 1] = r.id .. (r.kind and (":" .. r.kind) or "") end
    return table.concat(out, ",")
end

TestRunner:test("plan: built-in on a surface it is on", function()
    local rows = ActionHold.plan({ id = "explain", source = "builtin" }, "highlight", true)
    TestRunner:assertEqual(ids(rows), "membership,placements,edit:builtin,duplicate", "rows")
    TestRunner:assertEqual(rows[1].on, true, "remove offered")
end)

TestRunner:test("plan: built-in with an override gains Reset; not on the surface = Add", function()
    local rows = ActionHold.plan({ id = "explain", source = "builtin", has_override = true }, "quick_actions", false)
    TestRunner:assertEqual(ids(rows), "membership,placements,edit:builtin,duplicate,reset", "rows")
    TestRunner:assertEqual(rows[1].on, false, "add offered")
end)

TestRunner:test("plan: custom (UI) and custom_actions.lua sources route to their editors", function()
    TestRunner:assertEqual(ids(ActionHold.plan({ id = "x", source = "ui" }, "highlight", true)),
        "membership,placements,edit:ui,duplicate", "ui")
    TestRunner:assertEqual(ids(ActionHold.plan({ id = "x", source = "config" }, "highlight", true)),
        "membership,placements,edit:config,duplicate", "config")
end)

TestRunner:test("plan: local-handler pseudo actions have no editor or duplicate; no surface = no membership row", function()
    TestRunner:assertEqual(ids(ActionHold.plan({ id = "xray_lookup", source = "builtin", local_handler = true }, "highlight", true)),
        "membership,placements", "pseudo action")
    TestRunner:assertEqual(ids(ActionHold.plan({ id = "explain", source = "builtin" }, nil, nil)),
        "placements,edit:builtin,duplicate", "no surface")
    TestRunner:assertEqual(ids(ActionHold.plan({ id = "explain", source = "builtin" }, "input", nil)),
        "placements,edit:builtin,duplicate", "surface without membership")
end)

-- Layout (B345, run_options_plan.md Q1): membership and Edit stay in the menu,
-- the rest folds under More…; a single folded row is not worth a sub-menu.
TestRunner:test("layout: membership and Edit stay, placements/duplicate/reset fold", function()
    local primary, more = ActionHold.layout(ActionHold.plan(
        { id = "explain", source = "builtin", has_override = true }, "highlight", true))
    TestRunner:assertEqual(ids(primary), "membership,edit:builtin", "primary")
    TestRunner:assertEqual(ids(more), "placements,duplicate,reset", "more")
end)

TestRunner:test("layout: a single folded row is shown directly", function()
    local primary, more = ActionHold.layout(ActionHold.plan(
        { id = "xray_lookup", source = "builtin", local_handler = true }, "highlight", true))
    TestRunner:assertEqual(ids(primary), "membership,placements", "primary")
    TestRunner:assertEqual(#more, 0, "no More…")
end)

TestRunner:test("labels: Add/Remove name the surface", function()
    TestRunner:assertEqual(ActionHold.rowLabel({ id = "membership", on = true }, "highlight"),
        "Remove from the highlight menu", "remove")
    TestRunner:assertEqual(ActionHold.rowLabel({ id = "membership", on = false }, "quick_actions"),
        "Add to Quick Actions", "add")
    TestRunner:assertEqual(ActionHold.rowLabel({ id = "membership", on = false }, "input"),
        "Add to this input dialog", "input")
end)

-- A fake action_service with the real method names: every surface's pair is
-- looked up by name, so a rename in action_service fails here, not on device.
local function fakeService()
    local svc = { sets = { highlight = {}, dictionary = {}, quick = {}, fb = {}, general = {}, input = {} } }
    local function has(set, id) return svc.sets[set][id] == true end
    local function flip(set, id) svc.sets[set][id] = not svc.sets[set][id] end
    function svc:isInHighlightMenu(id) return has("highlight", id) end
    function svc:toggleHighlightMenuAction(id) flip("highlight", id) end
    function svc:isInDictionaryPopup(id) return has("dictionary", id) end
    function svc:toggleDictionaryPopupAction(id) flip("dictionary", id) end
    function svc:isInQuickActions(id) return has("quick", id) end
    function svc:toggleQuickAction(id) flip("quick", id) end
    function svc:isInFileBrowser(id) return has("fb", id) end
    function svc:toggleFileBrowserAction(id) flip("fb", id) end
    function svc:isInGeneralMenu(id) return has("general", id) end
    function svc:toggleGeneralMenuAction(id) flip("general", id) end
    function svc:isInInput(ctx, id) return has("input", ctx .. ":" .. id) end
    function svc:toggleInputAction(ctx, id) flip("input", ctx .. ":" .. id) end
    return svc
end

TestRunner:test("membership: every surface toggles through its own pair", function()
    local svc = fakeService()
    for _idx, surface in ipairs({ "highlight", "dictionary", "quick_actions", "file_browser" }) do
        TestRunner:assertEqual(ActionHold.isOn(svc, surface, nil, "explain"), false, surface .. " off")
        TestRunner:assertEqual(ActionHold.toggle(svc, surface, nil, "explain"), true, surface .. " on after toggle")
        TestRunner:assertEqual(ActionHold.toggle(svc, surface, nil, "explain"), false, surface .. " off again")
    end
    TestRunner:assertEqual(ActionHold.toggle(svc, "input", "book", "explain"), true, "input book")
    TestRunner:assertEqual(ActionHold.isOn(svc, "input", "highlight", "explain"), false, "input contexts are separate")
    TestRunner:assertEqual(ActionHold.toggle(svc, "input", "general", "explain"), true, "general dialog pair")
    TestRunner:assertEqual(svc.sets.general.explain, true, "general went through toggleGeneralMenuAction")
    TestRunner:assertEqual(ActionHold.isOn(svc, "input", nil, "explain"), nil, "input without a context = no membership")
    TestRunner:assertEqual(ActionHold.isOn(svc, "nowhere", nil, "explain"), nil, "unknown surface")
    TestRunner:assertEqual(ActionHold.toggle(svc, "nowhere", nil, "explain"), nil, "unknown surface toggles nothing")
end)

TestRunner:test("the real action_service has every method the surface table names", function()
    local ActionService = require("action_service")
    for surface, spec in pairs(ActionHold.SURFACES) do
        if spec.is_in then
            TestRunner:assertEqual(type(ActionService[spec.is_in]), "function", surface .. " is_in")
            TestRunner:assertEqual(type(ActionService[spec.toggle]), "function", surface .. " toggle")
        end
    end
    for _idx, name in ipairs({ "isInInput", "toggleInputAction", "isInGeneralMenu", "toggleGeneralMenuAction" }) do
        TestRunner:assertEqual(type(ActionService[name]), "function", name)
    end
end)

return TestRunner:summary()
