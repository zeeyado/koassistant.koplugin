-- An editor saved with nothing changed changes nothing (B575).
--
-- The editors of an action (Quick Edit, the full wizard, the built-in editor)
-- and Duplicate each rebuilt the stored record from the fields their own state
-- held. Opened from the Action Manager, whose list entries carried a subset of
-- the action, a Save or a Duplicate dropped the domain, the Quick switch, the
-- spoiler and surrounding-text settings, requires and max_tokens; the wizard
-- turned Web "Never" into "Follow global" and lost the temperature; a built-in
-- saved unchanged stored its shipped values as an override.
--
-- The plugin's own manager and service, with the dialogs recorded and tapped
-- (tests/lib/ui_recorder.lua): every editor is opened from both doors (the
-- manager's list entry, and the action as the service hands it to the hold
-- menu), saved unchanged, and the stored record compared with what was stored.
--
-- Run: lua tests/unit/test_action_editors_roundtrip.lua  (or lua tests/run_tests.lua --unit)

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

print("")
print(string.rep("=", 50))
print("  The action editors: a Save keeps what it did not change")
print(string.rep("=", 50))

-- the manager's list window is KOReader's Menu, which this file never shows
local MENU = "ui/widget/menu"
local had_menu = package.loaded[MENU]
if not had_menu then
    local ok = pcall(require, MENU)
    if not ok then package.loaded[MENU] = { new = function(_c, o) return o or {} end, extend = function(_c, o) return o or {} end } end
end
local ui = Recorder.install()
local PromptsManager = require("koassistant.ui.prompts_manager")
local ActionService = require("koassistant.prompts.action_service")
local Actions = require("koassistant.prompts.actions")

-- ------------------------------------------------------------------ helpers
local function deep(v)
    if type(v) ~= "table" then return v end
    local out = {}
    for k, x in pairs(v) do out[k] = deep(x) end
    return out
end
-- every difference between two records, as "field: was -> is"
local function diff(was, is, prefix, out)
    out, prefix = out or {}, prefix or ""
    local keys = {}
    for k in pairs(type(was) == "table" and was or {}) do keys[k] = true end
    for k in pairs(type(is) == "table" and is or {}) do keys[k] = true end
    for k in pairs(keys) do
        local a, b = was and was[k], is and is[k]
        if type(a) == "table" and type(b) == "table" then
            diff(a, b, prefix .. tostring(k) .. ".", out)
        elseif a ~= b then
            out[#out + 1] = string.format("%s%s: %s -> %s", prefix, tostring(k), tostring(a), tostring(b))
        end
    end
    table.sort(out)
    return out
end

-- An action with every setting away from its default, and four an editor
-- has no row for (the spoiler and surrounding-text settings, requires and
-- its hint, max_tokens, the description)
local function fullAction()
    return {
        text = "Margin Notes",
        context = "highlight",
        prompt = "Explain {highlighted_text} in the margin's voice.",
        description = "A custom action with everything set",
        behavior_variant = "none",
        include_book_context = true,
        skip_language_instruction = true,
        skip_domain = true,
        skip_background = false,          -- tri-state: false = always include
        domain = "philosophy",
        api_params = { temperature = 0.3, max_tokens = 1234 },
        reasoning_config = { default = "high" },
        provider = "anthropic",
        model = "claude-sonnet-5-5",
        model_tier = "fast",
        use_book_text = true,
        use_highlights = true,
        use_annotations = true,
        use_reading_progress = true,
        use_reading_stats = true,
        use_advanced_stats = true,
        use_notebook = true,
        use_library = true,
        accept_quick_answer = true,
        compact_view = true,
        minimal_buttons = true,
        enable_web_search = false,        -- tri-state: false = Never
        skip_spoiler = true,
        use_surrounding_context = false,  -- tri-state: false = never
        requires = { "book_text" },
        blocked_hint = "Needs the book's text",
        enabled = true,
    }
end

local function world(custom, overrides)
    local data = { custom_actions = custom or {}, builtin_action_overrides = overrides or {}, features = {} }
    local settings = {
        readSetting = function(_s, k) return data[k] end,
        saveSetting = function(_s, k, v) data[k] = v end,
        delSetting = function(_s, k) data[k] = nil end,
        flush = function() end,
    }
    local service = ActionService:new(settings)
    if service.init then service:init() end
    local plugin = { settings = settings, action_service = service,
        getProviderDisplayName = function(_s, id) return tostring(id) end }
    local pm = PromptsManager:new(plugin)
    pm.refreshMenu = function() end   -- the list window is not what is under test
    pm.show = function() end
    return pm, service, data
end
local function reset()
    for i = #ui.stack, 1, -1 do ui.stack[i] = nil end
    for i = #ui.shown, 1, -1 do ui.shown[i] = nil end
end
-- the two doors an editor is opened from
local function listEntry(pm, name)
    pm:loadPrompts()
    for _idx, p in ipairs(pm.prompts) do
        if p.text == name then return p end
    end
    error("the manager lists no action named " .. name)
end
local function serviceAction(service, context, name)
    service.actions_cache = nil
    for _idx, p in ipairs(service:getAllPrompts(context, true)) do
        if p.text == name then return p end
    end
    error("the service has no action named " .. name)
end
local function hasButton(pattern)
    for _idx, t in ipairs(ui:texts()) do
        if tostring(t):find(pattern, 1, true) then return t end
    end
    return nil
end

local DOORS = {
    { "the Action Manager's list", function(pm) return listEntry(pm, "Margin Notes") end },
    { "the hold menu (the service's action)", function(_pm, service) return serviceAction(service, "highlight", "Margin Notes") end },
}

-- ------------------------------------------------------------------ custom actions
for _idx, door in ipairs(DOORS) do
    local door_name, open = door[1], door[2]

    TestRunner:test("Quick Edit from " .. door_name .. ": Save with nothing changed changes nothing", function()
        reset()
        local pm, service, data = world({ fullAction() })
        local before = deep(data.custom_actions[1])
        pm:showCustomQuickSettings(open(pm, service))
        TestRunner:assertTrue(hasButton("☑ Takes the Quick preset") ~= nil,
            "the screen shows the Quick switch as it is stored (on)")
        ui:tap("Save")
        local changed = diff(before, data.custom_actions[1])
        TestRunner:assertEqual(table.concat(changed, "; "), "", "nothing changed")
    end)

    TestRunner:test("the full editor from " .. door_name .. ": Save with nothing changed changes nothing", function()
        reset()
        local pm, service, data = world({ fullAction() })
        local before = deep(data.custom_actions[1])
        pm:showPromptEditor(open(pm, service))
        ui:tap("Next →")   -- the name and the context
        ui:tap("Next →")   -- the prompt
        ui:tap("Save")     -- the settings
        local changed = diff(before, data.custom_actions[1])
        TestRunner:assertEqual(table.concat(changed, "; "), "", "nothing changed")
    end)

    TestRunner:test("Quick Edit from " .. door_name .. ": one switch changed changes that field alone", function()
        reset()
        local pm, service, data = world({ fullAction() })
        local before = deep(data.custom_actions[1])
        pm:showCustomQuickSettings(open(pm, service))
        ui:tap((assert(hasButton("Takes the Quick preset"), "the Quick row")))   -- assert hands back every argument
        ui:tap("Save")
        local changed = diff(before, data.custom_actions[1])
        TestRunner:assertEqual(table.concat(changed, "; "), "accept_quick_answer: true -> nil",
            "the Quick switch went off and nothing else moved")
    end)

    TestRunner:test("the full editor from " .. door_name .. ": a new name changes the name alone", function()
        reset()
        local pm, service, data = world({ fullAction() })
        local before = deep(data.custom_actions[1])
        pm:showPromptEditor(open(pm, service))
        ui:type("Margin Notes II")
        ui:tap("Next →")
        ui:tap("Next →")
        ui:tap("Save")
        local changed = diff(before, data.custom_actions[1])
        TestRunner:assertEqual(table.concat(changed, "; "), "text: Margin Notes -> Margin Notes II", "the name alone")
    end)

    TestRunner:test("Duplicate from " .. door_name .. " keeps the action's settings", function()
        reset()
        local pm, service, data = world({ fullAction() })
        pm:duplicateAction(open(pm, service))
        local copy = data.custom_actions[2]
        TestRunner:assertTrue(type(copy) == "table", "a second action was stored")
        local want = deep(data.custom_actions[1])
        want.text = copy.text                 -- the copy has its own name
        want.enabled = nil                    -- a new action is on without saying so
        local changed = diff(want, copy)
        TestRunner:assertEqual(table.concat(changed, "; "), "", "every setting came along")
    end)
end

TestRunner:test("the full editor shows Web: Never for an action stored as Never", function()
    reset()
    local pm, service, data = world({ fullAction() })
    pm:showPromptEditor(serviceAction(service, "highlight", "Margin Notes"))
    ui:tap("Next →")
    ui:tap("Next →")
    local row
    for _idx, t in ipairs(ui:texts()) do
        if tostring(t):find("Web", 1, true) then row = t end
    end
    TestRunner:assertTrue(row ~= nil, "the settings step has a web row")
    TestRunner:assertTrue(not tostring(row):find("Global", 1, true),
        "which does not read Global for an action set to Never: " .. tostring(row))
    local _unused = data
end)

TestRunner:test("a new action is stored as the wizard filled it", function()
    reset()
    local pm, _service, data = world({})
    pm:showPromptEditor(nil)
    ui:type("Fresh")
    ui:tap((assert(hasButton("Context: "), "the context row")))
    -- the context picker: its first row
    local picked = ui:texts()[1]
    ui:tap(picked)
    ui:type("Fresh")
    ui:tap("Next →")
    ui:type("Say hello to {highlighted_text}.")
    ui:tap("Next →")
    ui:tap("Create")
    local rec = data.custom_actions[1]
    TestRunner:assertTrue(type(rec) == "table", "one action was stored")
    TestRunner:assertEqual(rec.text, "Fresh", "under its name")
    TestRunner:assertEqual(rec.prompt, "Say hello to {highlighted_text}.", "with its prompt")
    TestRunner:assertEqual(rec.enabled, true, "enabled")
    TestRunner:assertTrue(rec.api_params == nil, "and no empty api_params table")
end)

-- ------------------------------------------------------------------ the merge itself
TestRunner:test("mergeEdit: a state that remembers nothing still keeps what no editor knows", function()
    local stored = fullAction()
    local state = { name = "Margin Notes", prompt = stored.prompt, context = "highlight", temperature = 0.9 }
    local out = PromptsManager.mergeEdit(stored, state)
    TestRunner:assertEqual(out.skip_spoiler, true, "the spoiler setting stays")
    TestRunner:assertEqual(out.use_surrounding_context, false, "the surrounding-text setting stays, false included")
    TestRunner:assertEqual(out.requires[1], "book_text", "requires stays")
    TestRunner:assertEqual(out.api_params.max_tokens, 1234, "max_tokens stays beside a new temperature")
    TestRunner:assertEqual(out.api_params.temperature, 0.9, "the temperature is the state's")
    TestRunner:assertEqual(out.domain, nil, "a field the state holds as nil is written as nil (no memory, no guess)")
    TestRunner:assertTrue(stored.api_params.temperature == 0.3, "the stored record's own table is not written to")
end)

TestRunner:test("mergeEdit: a reasoning table replaced by an equal one is no change; a cleared temperature leaves max_tokens", function()
    local stored = fullAction()
    local state = PromptsManager.rememberLoaded({ name = "Margin Notes", prompt = stored.prompt, context = "highlight",
        temperature = 0.3, reasoning_config = { default = "high" }, domain = "philosophy" })
    state.reasoning_config = { default = "high" }   -- a picker hands back a new table with the same choice
    state.temperature = nil                          -- the reader set the temperature back to Global
    local out = PromptsManager.mergeEdit(stored, state)
    TestRunner:assertTrue(out.reasoning_config == stored.reasoning_config, "the stored reasoning table is kept")
    TestRunner:assertEqual(out.api_params.temperature, nil, "the temperature is gone")
    TestRunner:assertEqual(out.api_params.max_tokens, 1234, "max_tokens is not")
    TestRunner:assertEqual(out.model_tier, "fast", "a field the state never loaded is kept")
end)

-- ------------------------------------------------------------------ built-in actions
-- A built-in that ships a temperature, a reasoning pin or a behavior of its
-- own: the fields a Save used to store whenever they were set
local function pinnedBuiltin()
    for _idx, context in ipairs({ "highlight", "book" }) do
        for _j, a in ipairs(Actions.getForContext and Actions.getForContext(context) or {}) do
            if a.id and (a.reasoning_config ~= nil or a.behavior_variant ~= nil
                    or (a.api_params and a.api_params.temperature)) and not a.local_handler then
                return context, a
            end
        end
    end
    return nil
end

TestRunner:test("a built-in saved with nothing changed stores no override, from either door", function()
    local context, builtin = pinnedBuiltin()
    TestRunner:assertTrue(builtin ~= nil, "a built-in with a shipped temperature, reasoning or behavior exists")
    if not builtin then return end
    for _idx, from_list in ipairs({ true, false }) do
        reset()
        local pm, service, data = world({})
        local prompt
        if from_list then
            pm:loadPrompts()
            for _j, p in ipairs(pm.prompts) do
                if p.id == builtin.id and p.source == "builtin" then prompt = p end
            end
        else
            for _j, p in ipairs(service:getAllPrompts(context, true)) do
                if p.id == builtin.id then prompt = p end
            end
        end
        TestRunner:assertTrue(prompt ~= nil, "the built-in " .. builtin.id .. " is listed")
        prompt.context = prompt.context or context
        pm:showBuiltinSettingsEditor(prompt)
        ui:tap("Save")
        local key = prompt.context .. ":" .. builtin.id
        TestRunner:assertTrue(data.builtin_action_overrides[key] == nil,
            (from_list and "from the list" or "from the hold menu") .. ": " .. builtin.id
            .. " stores nothing (" .. table.concat(diff({}, data.builtin_action_overrides[key] or {}), "; ") .. ")")
    end
end)

TestRunner:test("a built-in's stored domain survives a Save with nothing changed, and nothing joins it", function()
    reset()
    local key = "highlight:explain"
    TestRunner:assertTrue(Actions.getById("explain") ~= nil, "Explain is a built-in")
    local pm, _service, data = world({}, { [key] = { domain = "philosophy" } })
    pm:loadPrompts()
    local prompt
    for _j, p in ipairs(pm.prompts) do
        if p.id == "explain" and p.source == "builtin" then prompt = p end
    end
    TestRunner:assertTrue(prompt ~= nil, "Explain is listed")
    pm:showBuiltinSettingsEditor(prompt)
    ui:tap("Save")
    local changed = diff({ domain = "philosophy" }, data.builtin_action_overrides[prompt.context .. ":explain"] or {})
    TestRunner:assertEqual(table.concat(changed, "; "), "", "the override is the domain alone, as before")
end)

TestRunner:test("an override that only repeats the shipped values goes at the next Save", function()
    local context, builtin = pinnedBuiltin()
    if not builtin then return end
    reset()
    local stale = {}
    if builtin.api_params and builtin.api_params.temperature then stale.temperature = builtin.api_params.temperature end
    if builtin.behavior_variant then stale.behavior_variant = builtin.behavior_variant end
    if builtin.reasoning_config ~= nil then stale.reasoning_config = deep(builtin.reasoning_config) end
    local key = context .. ":" .. builtin.id
    local pm, _service, data = world({}, { [key] = stale })
    pm:loadPrompts()
    local prompt
    for _j, p in ipairs(pm.prompts) do
        if p.id == builtin.id and p.source == "builtin" then prompt = p end
    end
    TestRunner:assertTrue(prompt ~= nil, "the built-in is listed")
    pm:showBuiltinSettingsEditor(prompt)
    ui:tap("Save")
    TestRunner:assertTrue(data.builtin_action_overrides[prompt.context .. ":" .. builtin.id] == nil,
        "the stale override is gone: the action follows releases again")
end)

-- ------------------------------------------------------------------ the guard
TestRunner:test("no editor stores a record it built itself", function()
    local f = assert(io.open(PLUGIN_DIR .. "/koassistant/ui/prompts_manager.lua", "r"))
    local src = f:read("*a")
    f:close()
    local updates, merged = 0, 0
    for line in src:gmatch("[^\n]+") do
        if line:find("service:updateUserAction(", 1, true) then
            updates = updates + 1
            if line:find("PromptsManager.mergeEdit(", 1, true) then merged = merged + 1 end
        end
    end
    TestRunner:assertTrue(updates >= 2, "the Save paths are still where this test looks")
    TestRunner:assertEqual(merged, updates, "every Save of a custom action goes through mergeEdit")
    TestRunner:assertTrue(src:find("updateUserPrompt", 1, true) == nil, "and none calls a function the service does not have")
    TestRunner:assertTrue(src:find("service:addUserAction(PromptsManager.mergeEdit(nil, state))", 1, true) ~= nil,
        "a new action is written by the same view of the state")
end)

-- everything replaced goes back: one Lua process runs the whole suite
ui:restore()
if not had_menu then package.loaded[MENU] = nil end

return TestRunner:summary()
