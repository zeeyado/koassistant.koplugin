-- Flow tests for the Setup Wizard's dialogs (docs/test_automation_plan.md
-- layer 1): the real showApiKeyDialog cut from main.lua, the wizard's
-- provider step driven through the UI recorder.
--
-- The sweep of 2026-11-06: a key entry cancelled from the provider list
-- (Cancel, an empty Save, the Back key) returns to the list instead of
-- leaving the wizard; a single-topic Icons install asks KOReader's own
-- restart question (no chain to resume).
--
-- Run: lua tests/unit/test_flow_setup_wizard.lua  (or lua tests/run_tests.lua --unit)

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
local Recorder = require("ui_recorder")

local function read(rel)
    local f = assert(io.open(plugin_dir .. "/" .. rel, "r"))
    local s = f:read("*a")
    f:close()
    return s
end

print("Running: test_flow_setup_wizard")
print("")

-- the real key dialog, cut from main.lua and bound to stubs for its upvalues
local function keyDialog()
    local src = read("main.lua")
    local s = src:find("function AskGPT:showApiKeyDialog", 1, true)
    local e = src:find("\nend\n", s, true)
    local body = src:sub(s, e + 4)
    local chunk = "local AskGPT, UIManager, InfoMessage, T, _, maskApiKey, hasFileApiKey, hasAnyApiKeys, firstKeySwitches = ...\n" .. body
    local fn = assert(load(chunk, "=showApiKeyDialog"))
    local AskGPT = {}
    fn(AskGPT, require("ui/uimanager"), require("ui/widget/infomessage"), require("ffi/util").template,
        function(x) return x end,
        function(k) return k ~= "" and "****" or "" end,
        function() return false end,
        function() return false end,
        function(current, provider, configured, others) return current ~= provider and not configured and not others end)
    return AskGPT.showApiKeyDialog
end

TestRunner:test("a key entry cancelled from the wizard's provider list comes back to the list", function()
    local ui = Recorder.install()
    local lfs = require("libs/libkoreader-lfs")
    local real_attr = lfs.attributes
    lfs.attributes = function(path, ...)
        if tostring(path):match("apikeys%.lua$") then return nil end
        return real_attr(path, ...)
    end
    local SetupWizard = require("koassistant.ui.setup_wizard")
    local store = { features = {} }
    local plugin = {
        settings = {
            readSetting = function(_s, k) return store[k] end,
            saveSetting = function(_s, k, v) store[k] = v end,
            flush = function() end,
        },
        getProviderDisplayName = function(_p, id) return id end,
        updateConfigFromSettings = function() end,
        testProvider = function() end,
        isProviderConfigured = function() return false end,
        getCurrentProvider = function() return "anthropic" end,
        getEffectiveDefaultModel = function() return "m" end,
        showApiKeyDialog = keyDialog(),
    }
    local function run(exit)
        ui.stack = {}
        local advanced = 0
        SetupWizard.stepProvider(plugin, { force = false, results = {} }, function() advanced = advanced + 1 end)
        local list = ui:top()
        TestRunner:assertTrue(list and list._widget == "ui/widget/buttondialog", "the provider list")
        ui:tap("Anthropic")
        TestRunner:assertEqual(ui:top()._widget, "ui/widget/inputdialog", exit .. ": the key dialog")
        if exit == "cancel" then
            ui:tap("Cancel")
        elseif exit == "empty save" then
            ui:type("")
            ui:tap("Save")
        else
            -- the Back key: InputDialog's close button (id "close")
            local w = ui:top()
            for _i, row in ipairs(w.buttons) do
                for _j, b in ipairs(row) do if b.id == "close" then b.callback() end end
            end
        end
        local top = ui:top()
        TestRunner:assertTrue(top and top._widget == "ui/widget/buttondialog" and ui:has("Anthropic"),
            exit .. ": the provider list is back (top: " .. tostring(top and top._widget) .. ")")
        TestRunner:assertEqual(advanced, 0, exit .. ": the step did not advance")
    end
    run("cancel")
    run("empty save")
    run("back")
    lfs.attributes = real_attr
    ui:restore()
end)

TestRunner:test("a single-topic Icons install asks KOReader's own restart question", function()
    local src = read("koassistant/ui/setup_wizard.lua")
    local a = src:find("local function restartThen()", 1, true)
    local body = src:sub(a, a + 700)
    TestRunner:assertTrue(body:find("if not ctx or ctx.single or not Device:canRestart() then", 1, true) ~= nil,
        "outside the chain, a single topic or no restart: askForRestart")
end)

return TestRunner:summary()
