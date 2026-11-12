-- B456: the domain manager had two bulk deletes that did the same thing ("Delete
-- all custom" and "Restore defaults": built-in domains cannot be deleted, so
-- there was nothing to restore), and neither cleared a selected domain that
-- pointed at a deleted one (the single delete does). With the selection left
-- dangling, no domain was sent and the chip showed the raw id.
--
-- Run: lua tests/unit/test_domain_manager.lua  (or lua tests/run_tests.lua --unit)

local function setupPaths()
    local info = debug.getinfo(1, "S")
    local script_path = info.source:match("@?(.*)")
    local unit_dir = script_path:match("(.+)/[^/]+$") or "."
    local tests_dir = unit_dir:match("(.+)/[^/]+$") or "."
    local plugin_dir = tests_dir:match("(.+)/[^/]+$") or "."
    package.path = table.concat({
        plugin_dir .. "/?.lua",
        tests_dir .. "/?.lua",
        tests_dir .. "/lib/?.lua",
        package.path,
    }, ";")
    return plugin_dir
end
local plugin_dir = setupPaths()
require("mock_koreader")
local TestRunner = require("test_runner"):new()

-- The manager stores the widget classes and builds them lazily, so class-shaped
-- stubs are enough to load it. Loaded copies are put back afterwards: the suite
-- runs every file in one Lua process.
local STUBBED = { "ui/widget/menu", "ui/widget/confirmbox", "ui/widget/textviewer" }
local saved = { manager = package.loaded["koassistant.ui.domain_manager"] }
for _idx, name in ipairs(STUBBED) do
    saved[name] = package.loaded[name]
    if not package.loaded[name] then
        package.loaded[name] = {
            new = function(_self, o) return o or {} end,
            extend = function(_self, o) return o or {} end,
        }
    end
end
package.loaded["koassistant.ui.domain_manager"] = nil
local DomainManager = require("koassistant.ui.domain_manager")
package.loaded["koassistant.ui.domain_manager"] = saved.manager
for _idx, name in ipairs(STUBBED) do package.loaded[name] = saved[name] end

--- A plugin whose settings keep `features` in memory and count the flushes.
local function pluginWith(features)
    local store = { features = features }
    local settings = { flushes = 0 }
    function settings:readSetting(key) return store[key] end
    function settings:saveSetting(key, value) store[key] = value end
    function settings:flush() self.flushes = self.flushes + 1 end
    return { settings = settings }, store
end

local function twoCustom()
    return {
        { id = "custom_1", name = "One", context = "first" },
        { id = "custom_2", name = "Two", context = "second" },
    }
end

print("\n  [Delete all custom clears a selection that pointed at a deleted domain]")

TestRunner:test("the selected domain is cleared when it was one of the deleted", function()
    local plugin, store = pluginWith({ custom_domains = twoCustom(), selected_domain = "custom_2" })
    DomainManager:new(plugin):deleteAllCustomDomains()
    TestRunner:assertEqual(#store.features.custom_domains, 0, "every custom domain is gone")
    TestRunner:assertEqual(store.features.selected_domain, nil, "no id left pointing at nothing")
end)

TestRunner:test("it is the same rule whichever custom domain was selected", function()
    local plugin, store = pluginWith({ custom_domains = twoCustom(), selected_domain = "custom_1" })
    DomainManager:new(plugin):deleteAllCustomDomains()
    TestRunner:assertEqual(store.features.selected_domain, nil)
end)

TestRunner:test("a built-in or file domain stays selected", function()
    local plugin, store = pluginWith({ custom_domains = twoCustom(), selected_domain = "synthesis" })
    DomainManager:new(plugin):deleteAllCustomDomains()
    TestRunner:assertEqual(#store.features.custom_domains, 0)
    TestRunner:assertEqual(store.features.selected_domain, "synthesis", "it was not deleted")
end)

TestRunner:test("no selection stays no selection", function()
    local plugin, store = pluginWith({ custom_domains = twoCustom() })
    DomainManager:new(plugin):deleteAllCustomDomains()
    TestRunner:assertEqual(store.features.selected_domain, nil)
end)

TestRunner:test("both changes reach the disk", function()
    local plugin, store = pluginWith({ custom_domains = twoCustom(), selected_domain = "custom_2" })
    DomainManager:new(plugin):deleteAllCustomDomains()
    TestRunner:assertTrue(plugin.settings.flushes >= 2, "the list and the selection are each flushed")
    TestRunner:assertEqual(store.features.custom_domains[1], nil)
end)

TestRunner:test("with no custom domains it changes nothing", function()
    local plugin, store = pluginWith({ selected_domain = "synthesis" })
    DomainManager:new(plugin):deleteAllCustomDomains()
    TestRunner:assertEqual(#store.features.custom_domains, 0)
    TestRunner:assertEqual(store.features.selected_domain, "synthesis")
end)

print("\n  [the single delete is the rule it follows]")

TestRunner:test("deleting one custom domain clears the selection the same way", function()
    local plugin, store = pluginWith({ custom_domains = twoCustom(), selected_domain = "custom_2" })
    DomainManager:new(plugin):deleteCustomDomain("custom_2")
    TestRunner:assertEqual(#store.features.custom_domains, 1)
    TestRunner:assertEqual(store.features.selected_domain, nil)
end)

print("\n  [one row, not two]")

local function source(rel)
    local f = assert(io.open(plugin_dir .. "/" .. rel, "r"))
    local s = f:read("*a")
    f:close()
    return s
end
local src = source("koassistant/ui/domain_manager.lua")

TestRunner:test("the menu has Delete all custom and no second row for the same action", function()
    TestRunner:assertTrue(src:find('_("Delete all custom")', 1, true), "the row")
    TestRunner:assertFalse(src:find('_("Restore defaults")', 1, true),
        "built-in domains cannot be deleted, so there is nothing to restore")
end)

TestRunner:test("the row deletes through the method that clears the selection", function()
    TestRunner:assertFalse(src:find("self_ref:saveCustomDomains({})", 1, true),
        "no bulk delete that skips the selection")
    TestRunner:assertTrue(src:find("self_ref:deleteAllCustomDomains()", 1, true), "the row calls it")
end)

print("")
print("  [the sweep of 2026-11-06: ids never reused; a template fills the editor]")

TestRunner:test("a deleted highest id is never given to a new domain", function()
    local plugin, store = pluginWith({ custom_domains = twoCustom() })
    local dm = DomainManager:new(plugin)
    dm:deleteCustomDomain("custom_2")
    local id = dm:generateDomainId()
    TestRunner:assertEqual(id, "custom_3", "the counter is seeded past the highest id ever seen")
    TestRunner:assertEqual(store.features.custom_domain_next_id, 4, "and grows")
    dm:deleteCustomDomain("custom_1")
    TestRunner:assertEqual(dm:generateDomainId(), "custom_4", "a Delete all leaves the counter alone")
    local fresh = DomainManager:new(pluginWith({ custom_domains = twoCustom(), custom_domain_next_id = 9 }))
    TestRunner:assertEqual(fresh:generateDomainId(), "custom_9", "a stored counter is honoured")
    local Registry = require("koassistant.storage.storage_registry")
    local listed = {}
    for _idx, k in ipairs(Registry.SETTINGS_SUBKEYS.internal) do listed[k] = true end
    TestRunner:assertTrue(listed.custom_domain_next_id and listed.custom_behavior_next_id, "both counters registered")
    -- Fresh Start drops the custom domains and keeps every book's own domain
    -- value: the counters must outlive it, or the next new domain takes an id
    -- a book still points at (audit 2026-11-12)
    local kept = {}
    for _idx, k in ipairs(Registry.freshStartPreserve()) do kept[k] = true end
    TestRunner:assertTrue(kept["features.custom_domain_next_id"] and kept["features.custom_behavior_next_id"],
        "both counters survive Fresh Start")
    TestRunner:assertTrue(not kept["features.custom_domains"] and not kept["features.custom_behaviors"],
        "the lists themselves do not")
end)

TestRunner:test("Use as Template while editing fills the editor with the template", function()
    local Recorder = require("ui_recorder")
    local ui = Recorder.install()
    local plugin = pluginWith({ custom_domains = twoCustom() })
    local dm = DomainManager:new(plugin)
    dm:showDomainEditor({ id = "custom_1", name = "One", context = "first" }, "a template context", "Template Name")
    local top = ui:top()
    TestRunner:assertEqual(top and top.input, "Template Name", "the template's name, not the domain's")
    ui.stack = {}
    dm:showDomainEditor({ id = "custom_1", name = "One", context = "first" })
    TestRunner:assertEqual(ui:top().input, "One", "an edit without a template keeps the domain")
    ui:restore()
end)

TestRunner:test("the behavior manager: the same counter and the same editor rule", function()
    local STUB2 = { "ui/widget/menu", "ui/widget/confirmbox", "ui/widget/textviewer" }
    local kept = { manager = package.loaded["koassistant.ui.behavior_manager"] }
    for _idx, name in ipairs(STUB2) do
        kept[name] = package.loaded[name]
        if not package.loaded[name] then
            package.loaded[name] = { new = function(_self, o) return o or {} end, extend = function(_self, o) return o or {} end }
        end
    end
    package.loaded["koassistant.ui.behavior_manager"] = nil
    local ok, BehaviorManager = pcall(require, "koassistant.ui.behavior_manager")
    package.loaded["koassistant.ui.behavior_manager"] = kept.manager
    for _idx, name in ipairs(STUB2) do package.loaded[name] = kept[name] end
    TestRunner:assertTrue(ok, "the behavior manager loads: " .. tostring(BehaviorManager))
    local plugin, store = pluginWith({ custom_behaviors = {
        { id = "custom_1", name = "One", text = "first" }, { id = "custom_2", name = "Two", text = "second" } } })
    local bm = BehaviorManager:new(plugin)
    bm:deleteCustomBehavior("custom_2")
    TestRunner:assertEqual(bm:generateBehaviorId(), "custom_3")
    TestRunner:assertEqual(store.features.custom_behavior_next_id, 4)
    local Recorder = require("ui_recorder")
    local ui = Recorder.install()
    bm:showBehaviorEditor({ id = "custom_1", name = "One", text = "first" }, "a template text", "Template Name")
    TestRunner:assertEqual(ui:top() and ui:top().input, "Template Name")
    ui:restore()
end)

return TestRunner:summary()
