-- Unit tests for koassistant/ui/gesture_picker.lua (B489, 2026-10-19): the
-- frozen copy of KOReader's gesture slots against the installed KOReader's
-- own file when it is present, the pure helpers (free counts, the plan for
-- a tap, the holder's words, an action's bindings).

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

local GesturePicker = require("koassistant.ui.gesture_picker")

local TestRunner = { passed = 0, failed = 0 }
function TestRunner:test(name, fn)
    local ok, err = pcall(fn)
    if ok then
        self.passed = self.passed + 1
        print(string.format("  \226\156\147 %s", name))
    else
        self.failed = self.failed + 1
        print(string.format("  \226\156\151 %s: %s", name, tostring(err)))
    end
end
function TestRunner:assertEqual(actual, expected, msg)
    if actual ~= expected then
        error(string.format("%s: expected %s, got %s", msg or "eq", tostring(expected), tostring(actual)), 2)
    end
end
function TestRunner:assertTrue(v, msg) if not v then error((msg or "expected true"), 2) end end

print("\nGesture picker")

local ids, n_slots = {}, 0
for _idx, section in ipairs(GesturePicker.SECTIONS) do
    for _jdx, slot in ipairs(section.slots) do
        n_slots = n_slots + 1
        ids[slot.id] = section.key
    end
end

TestRunner:test("every slot id is unique and worded, every section keyed", function()
    local seen_ids, seen_keys, count = {}, {}, 0
    for _idx, section in ipairs(GesturePicker.SECTIONS) do
        TestRunner:assertTrue(type(section.key) == "string" and not seen_keys[section.key], "section key " .. tostring(section.key))
        seen_keys[section.key] = true
        TestRunner:assertTrue(type(section.label) == "string" and section.label ~= "", "section label")
        for _jdx, slot in ipairs(section.slots) do
            TestRunner:assertTrue(not seen_ids[slot.id], "duplicate id " .. tostring(slot.id))
            seen_ids[slot.id] = true
            TestRunner:assertTrue(type(slot.label) == "string" and slot.label ~= "", "label of " .. tostring(slot.id))
            count = count + 1
        end
    end
    TestRunner:assertTrue(count >= 70, "the whole list, not a shortlist: " .. count)
end)

TestRunner:test("the frozen copy matches the installed KOReader's gestures plugin (when present)", function()
    local path = "/Applications/KOReader.app/Contents/koreader/plugins/gestures.koplugin/main.lua"
    local f = io.open(path, "r")
    if not f then
        print("    (no installed KOReader here, the copy is taken as read)")
        return
    end
    local src = f:read("*a"); f:close()
    local block = src:match("local gestures_list = {(.-)\n}")
    TestRunner:assertTrue(block, "gestures_list found in the installed file")
    local theirs, n_theirs = {}, 0
    for id in block:gmatch("\n%s*([%w_]+)%s*=") do
        if id ~= "multiswipe" then theirs[id] = true; n_theirs = n_theirs + 1 end
    end
    local missing, extra = {}, {}
    for id in pairs(theirs) do if not ids[id] then missing[#missing + 1] = id end end
    for id in pairs(ids) do if not theirs[id] then extra[#extra + 1] = id end end
    table.sort(missing); table.sort(extra)
    TestRunner:assertEqual(table.concat(missing, ","), "", "KOReader slots this copy lacks")
    TestRunner:assertEqual(table.concat(extra, ","), "", "slots KOReader no longer has")
    TestRunner:assertEqual(n_slots, n_theirs, "the count")
    -- the sections too: every id of a KOReader section sits in ours
    local items = src:match("local section_items = {(.-)\n}")
    TestRunner:assertTrue(items, "section_items found")
    for key, body in items:gmatch("\n%s*([%w_]+)%s*=%s*{(.-)}") do
        for id in body:gmatch('"([%w_]+)"') do
            TestRunner:assertEqual(ids[id], key, "section of " .. id)
        end
    end
end)

TestRunner:test("sectionOf and slotLabel, with a fallback for an unknown id", function()
    TestRunner:assertEqual(GesturePicker.sectionOf("tap_right_bottom_corner").key, "tap_corner")
    TestRunner:assertEqual(GesturePicker.sectionOf("multiswipe_west_east").key, "multiswipes")
    TestRunner:assertEqual(GesturePicker.sectionOf("no_such_gesture"), nil)
    TestRunner:assertEqual(GesturePicker.slotLabel("tap_right_bottom_corner"), "Tap bottom-right corner")
    TestRunner:assertEqual(GesturePicker.slotLabel("multiswipe_west_east"), "Multiswipe ⬅ ➡")
    TestRunner:assertEqual(GesturePicker.slotLabel("some_new_gesture"), "some new gesture", "prettified")
    TestRunner:assertEqual(GesturePicker.modeLabel("gesture_fm"), "file browser")
    TestRunner:assertEqual(GesturePicker.modeLabel("gesture_reader"), "reader")
end)

TestRunner:test("freeCount counts a section's free slots in one mode", function()
    local section = GesturePicker.sectionOf("tap_right_bottom_corner")
    local mode = {
        tap_right_bottom_corner = { koassistant_quick_actions = true },
        tap_top_left_corner = { settings = { show_as_quickmenu = true } },  -- settings alone is free
        tap_top_right_corner = {},
    }
    local free, total = GesturePicker.freeCount(section, mode)
    TestRunner:assertEqual(total, 4)
    TestRunner:assertEqual(free, 3)
    free = GesturePicker.freeCount(section, nil)
    TestRunner:assertEqual(free, 4, "no data: all free")
end)

TestRunner:test("plan: free assigns, mine offers Remove, taken asks", function()
    TestRunner:assertEqual(GesturePicker.plan(nil, "a"), "free")
    TestRunner:assertEqual(GesturePicker.plan({}, "a"), "free")
    TestRunner:assertEqual(GesturePicker.plan({ a = true }, "a"), "mine")
    TestRunner:assertEqual(GesturePicker.plan({ b = true }, "a"), "taken")
    TestRunner:assertEqual(GesturePicker.plan({ a = true, b = true }, "a"), "mine", "mine beside another")
end)

TestRunner:test("holder: the describer's words, 'taken' when it cannot say", function()
    TestRunner:assertEqual(GesturePicker.holder({ x = true }, function() return "Toggle frontlight" end), "Toggle frontlight")
    TestRunner:assertEqual(GesturePicker.holder({ x = true }, function() error("unknown action") end), "taken")
    TestRunner:assertEqual(GesturePicker.holder({ x = true }, function() return "" end), "taken")
    TestRunner:assertEqual(GesturePicker.holder({ x = true }, nil), "taken")
end)

TestRunner:test("bindingsFor lists an action's slots in both modes, sorted; bindingsText words them", function()
    local data = {
        gesture_reader = {
            tap_right_bottom_corner = { koassistant_quick_actions = true },
            double_tap_left_side = { koassistant_quick_actions = true, other = true },
            tap_top_left_corner = { other = true },
        },
        gesture_fm = { tap_right_bottom_corner = { koassistant_quick_actions = true } },
    }
    local b = GesturePicker.bindingsFor(data, "koassistant_quick_actions")
    TestRunner:assertEqual(#b, 3)
    TestRunner:assertEqual(b[1].section, "gesture_fm", "file browser first (sorted by section key)")
    TestRunner:assertEqual(b[2].slot, "tap_right_bottom_corner", "within a mode, the picker's order: a tap corner before a double tap")
    TestRunner:assertEqual(b[3].slot, "double_tap_left_side")
    TestRunner:assertEqual(GesturePicker.bindingsText(data, "koassistant_quick_actions"),
        "Tap bottom-right corner (file browser), Tap bottom-right corner (reader), Double-tap left side (reader)")
    -- a device's own multiswipes sort after the corner, never before it (they read as defaults)
    local multi = GesturePicker.bindingsFor({ gesture_reader = {
        multiswipe_north_south_north = { koassistant_quick_actions = true },
        multiswipe_south_north_south = { koassistant_quick_actions = true },
        tap_right_bottom_corner = { koassistant_quick_actions = true },
        some_future_gesture = { koassistant_quick_actions = true },
    } }, "koassistant_quick_actions")
    TestRunner:assertEqual(multi[1].slot, "tap_right_bottom_corner")
    TestRunner:assertEqual(multi[2].slot, "multiswipe_north_south_north")
    TestRunner:assertEqual(multi[3].slot, "multiswipe_south_north_south")
    TestRunner:assertEqual(multi[4].slot, "some_future_gesture", "an id this copy does not know comes last")
    TestRunner:assertEqual(GesturePicker.bindingsText(data, "nothing"), nil)
    TestRunner:assertEqual(#GesturePicker.bindingsFor(nil, "x"), 0)
end)

TestRunner:test("ready: KOReader's gesture data exists", function()
    TestRunner:assertTrue(GesturePicker.ready({ gesture_reader = {} }))
    TestRunner:assertTrue(not GesturePicker.ready({}))
    TestRunner:assertTrue(not GesturePicker.ready(nil))
end)

print("\nBindings whose action no longer exists (B609)")

TestRunner:test("boundIds: the plugin's bound ids minus the known ones, sorted; a slot's settings key skipped", function()
    local data = {
        gesture_reader = {
            tap_top_left_corner = { koassistant_action_book_ui_3 = true,
                settings = { order = { "koassistant_action_book_ui_3" } } },
            tap_top_right_corner = { koassistant_quick_actions = true },
            hold_top_left_corner = { toggle_frontlight = true },
        },
        gesture_fm = {
            tap_top_left_corner = { koassistant_action_general_ui_9 = true, koassistant_quick_settings = true },
        },
    }
    local known = { koassistant_quick_actions = true, koassistant_quick_settings = true }
    TestRunner:assertEqual(table.concat(GesturePicker.boundIds(data, "koassistant_", known), ","),
        "koassistant_action_book_ui_3,koassistant_action_general_ui_9")
    TestRunner:assertEqual(#GesturePicker.boundIds(data, "koassistant_action_", { koassistant_action_book_ui_3 = true }), 1)
    TestRunner:assertEqual(#GesturePicker.boundIds(nil, "koassistant_"), 0)
    TestRunner:assertEqual(#GesturePicker.boundIds({ gesture_reader = {} }, "koassistant_"), 0)
end)

TestRunner:test("forget: every binding of an id in both modes goes; other actions and slots stay", function()
    local data = {
        gesture_reader = {
            tap_top_left_corner = { koassistant_action_book_ui_3 = true },
            tap_top_right_corner = { koassistant_action_book_ui_3 = true, toggle_frontlight = true },
        },
        gesture_fm = {
            tap_top_left_corner = { koassistant_action_book_ui_3 = true },
            hold_top_left_corner = { koassistant_quick_settings = true },
        },
    }
    local flushed = 0
    local plugin = { ui = { gestures = { settings = { data = data, flush = function() flushed = flushed + 1 end } } } }
    local n, how = GesturePicker.forget(plugin, "koassistant_action_book_ui_3")
    TestRunner:assertEqual(n, 3)
    TestRunner:assertEqual(how, "live")
    TestRunner:assertTrue(data.gesture_reader.tap_top_left_corner == nil, "a slot left with nothing goes back to nil")
    TestRunner:assertEqual(data.gesture_reader.tap_top_right_corner.toggle_frontlight, true, "the other action on a slot stays")
    TestRunner:assertTrue(data.gesture_reader.tap_top_right_corner.koassistant_action_book_ui_3 == nil)
    TestRunner:assertTrue(data.gesture_fm.tap_top_left_corner == nil)
    TestRunner:assertEqual(data.gesture_fm.hold_top_left_corner.koassistant_quick_settings, true)
    TestRunner:assertTrue(flushed >= 1, "written")
    TestRunner:assertEqual((GesturePicker.forget(plugin, "koassistant_action_book_ui_3")), 0, "nothing left to forget")
    TestRunner:assertEqual(#GesturePicker.boundIds(data, "koassistant_action_"), 0, "and none listed as dead")
end)

print(string.format("\n=== Results: %d passed, %d failed ===", TestRunner.passed, TestRunner.failed))
return TestRunner.failed == 0
