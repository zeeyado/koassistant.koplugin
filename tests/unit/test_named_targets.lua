-- Every row that reaches the plugin by NAME names something that exists
-- (B584, #123, 2026-11-05): five Settings rows shipped in v0.24.0 naming
-- callbacks no file defined, and the settings manager only logged the miss.
-- main.lua cannot be required under the mock, so its methods are read from
-- the source; the schema is the real table, walked. The other named-target
-- sets live in the same file so a renamed method cannot ship silently.

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

local TestRunner = { passed = 0, failed = 0 }
function TestRunner:test(name, fn)
    local ok, err = pcall(fn)
    if ok then
        self.passed = self.passed + 1
        print("    PASS " .. name)
    else
        self.failed = self.failed + 1
        print("    FAIL " .. name .. ": " .. tostring(err))
    end
end

local function source(rel)
    local f = assert(io.open(plugin_dir .. "/" .. rel, "r"))
    local s = f:read("*a")
    f:close()
    return s
end

local MAIN = source("main.lua")

-- The plugin's methods, by name, from the source (a definition inside a
-- comment would count, which is the one way this scan could pass wrongly)
local METHODS = {}
for line in MAIN:gmatch("[^\n]+") do
    local name = line:match("^function AskGPT[:.]([%w_]+)%s*%(")
    if name then METHODS[name] = true end
end

local function missingOf(names)
    local out = {}
    for _idx, n in ipairs(names) do
        if not METHODS[n.name] then out[#out + 1] = n.name .. " (" .. n.where .. ")" end
    end
    return table.concat(out, "; ")
end

TestRunner:test("every Settings row callback names a method of the plugin", function()
    local Schema = require("koassistant.ui.settings_schema")
    local names = {}
    local function walk(items, path)
        for _idx, item in ipairs(items or {}) do
            local label = type(item.text) == "string" and item.text or tostring(item.id)
            if type(item.callback) == "string" then
                names[#names + 1] = { name = item.callback, where = path .. " > " .. label }
            end
            if item.items then walk(item.items, path .. " > " .. label) end
        end
    end
    walk(Schema.items, "Settings")
    assert(#names >= 60, "string callbacks walked: " .. #names)
    local missing = missingOf(names)
    assert(missing == "", "Settings rows naming no method: " .. missing)
end)

TestRunner:test("every Quick Actions utility names a method of the plugin", function()
    local names = {}
    for _idx, u in ipairs(require("koassistant.core.constants").QUICK_ACTION_UTILITIES) do
        names[#names + 1] = { name = u.callback, where = "QA utility " .. tostring(u.id) }
    end
    assert(#names >= 5, "utilities walked: " .. #names)
    local missing = missingOf(names)
    assert(missing == "", "utilities naming no method: " .. missing)
end)

TestRunner:test("the Setup Wizard's privacy presets name methods of the plugin", function()
    local names = {}
    for name in source("koassistant/ui/setup_wizard.lua"):gmatch('applyPreset%(%s*"([%w_]+)"') do
        names[#names + 1] = { name = name, where = "wizard preset" }
    end
    assert(#names >= 3, "presets walked: " .. #names)
    local missing = missingOf(names)
    assert(missing == "", "presets naming no method: " .. missing)
end)

TestRunner:test("every Dispatcher event registered in main.lua has its handler", function()
    local names = {}
    for event in MAIN:gmatch('event%s*=%s*"(KOAssistant[%w_]+)"') do
        names[#names + 1] = { name = "on" .. event, where = "Dispatcher event" }
    end
    assert(#names >= 10, "events walked: " .. #names)
    local missing = missingOf(names)
    assert(missing == "", "events with no handler: " .. missing)
end)

TestRunner:test("every Quick Settings tile id has a button in the panel", function()
    local missing = {}
    local ids = require("koassistant.core.constants").QS_ITEMS_DEFAULT_ORDER
    assert(#ids >= 20, "tile ids walked: " .. #ids)
    for _idx, id in ipairs(ids) do
        if not MAIN:find('button_defs%["' .. id .. '"%]%s*=') then missing[#missing + 1] = id end
    end
    assert(#missing == 0, "tiles the panel never draws: " .. table.concat(missing, ", "))
end)

TestRunner:test("the hold menu's surfaces name ActionService methods", function()
    local ActionHold = require("koassistant.ui.action_hold")
    local ActionService = require("koassistant.prompts.action_service")
    local missing, seen = {}, 0
    for surface, spec in pairs(ActionHold.SURFACES) do
        for _idx, key in ipairs({ "is_in", "toggle" }) do
            if spec[key] then
                seen = seen + 1
                if type(ActionService[spec[key]]) ~= "function" then
                    missing[#missing + 1] = surface .. "." .. key .. " = " .. tostring(spec[key])
                end
            end
        end
    end
    assert(seen >= 8, "hold menu names walked: " .. seen)
    assert(#missing == 0, "hold menu names with no method: " .. table.concat(missing, ", "))
end)

TestRunner:test("the picture popup's Settings rows exist in the schema", function()
    local Schema = require("koassistant.ui.settings_schema")
    local src, missing, seen = source("koassistant/images/image_options.lua"), {}, 0
    for id in src:gmatch('menuItem%("([%w_]+)"%)') do
        seen = seen + 1
        if not Schema:getItemById(id) then missing[#missing + 1] = id end
    end
    local model_row = src:match("local MODEL_ROW = (%b{})") or ""
    for id in model_row:gmatch('"([%w_]+)"') do
        seen = seen + 1
        if not Schema:getItemById(id) then missing[#missing + 1] = id end
    end
    assert(seen >= 5, "picture popup rows walked: " .. seen)
    assert(#missing == 0, "picture popup rows missing from the schema: " .. table.concat(missing, ", "))
end)

print(string.format("\n  Results: %d passed, %d failed", TestRunner.passed, TestRunner.failed))
return TestRunner.failed == 0
