-- The model button in the highlight menu and the dictionary popup
-- (koassistant_model_switch.lua, #86 / B345 step 4): its list is the favorites
-- in their order, then the recent "More models…" picks not already listed, with
-- keyless providers left out; its label is the model in effect.
--
-- Run: lua tests/unit/test_model_switch.lua  (or lua tests/run_tests.lua --unit)

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
local ModelSwitch = require("koassistant_model_switch")
local TestRunner = require("test_runner"):new()

local function names(list)
    local out = {}
    for _idx, e in ipairs(list) do out[#out + 1] = e.model .. (e.favorite and "*" or "") end
    return table.concat(out, " | ")
end

TestRunner:test("favorites first in their order, then recent picks not already listed", function()
    local features = {
        favorite_models = { { provider = "openai", model = "b" }, { provider = "anthropic", model = "a" } },
        run_recent_models = { { provider = "anthropic", model = "a" }, { provider = "xai", model = "c" } },
    }
    TestRunner:assertEqual(names(ModelSwitch.entries(features)), "b* | a* | c", "order and marks")
end)

TestRunner:test("a provider without a key is left out; nothing saved lists nothing", function()
    local features = { favorite_models = { { provider = "groq", model = "x" }, { provider = "openai", model = "y" } } }
    TestRunner:assertEqual(names(ModelSwitch.entries(features, function(p) return p ~= "groq" end)), "y*",
        "keyless skipped")
    TestRunner:assertEqual(#ModelSwitch.entries({}), 0, "empty")
end)

TestRunner:test("label: the model in effect, with the robot when emoji icons are on", function()
    local features = { enable_emoji_icons = true }
    local plugin = {
        settings = { readSetting = function() return features end },
        getCurrentModel = function() return "claude-sonnet-5" end,
    }
    TestRunner:assertEqual(ModelSwitch.label(plugin), "\u{1F916} claude-sonnet-5", "emoji")
    features.enable_emoji_icons = false
    TestRunner:assertEqual(ModelSwitch.label(plugin), "Model: claude-sonnet-5", "words")
end)

return TestRunner:summary()
