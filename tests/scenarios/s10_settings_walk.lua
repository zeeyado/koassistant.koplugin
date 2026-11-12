--[[
Every row of the plugin's Settings menu, in KOReader's real frontend, in the
reader and in the file browser: each row's text, enabled, checked and help
functions are run, every submenu is opened, and every leaf with a callback is
TAPPED.

Fails on:
  * a row that names a callback the plugin does not have (issue #123: v0.24.1
    shipped five X-Ray rows that did nothing on a tap; on that tree this walk
    reports exactly those five, in both modes);
  * a row function that raises an error.
Taps that show no new window and log nothing are counted, not failed (a
toggle does that). Rows that reach the network or restart the app are not
tapped, and the plugin's own network entry points are stubbed.
(Written by the audit of 2026-11-12 as a probe; the test the reporter of
issue #123 asked for.)
]]
local S = dofile(os.getenv("KOA_PLUGIN") .. "/tests/scenarios/boot.lua")
local UIManager = S.UIManager

local warns = {}
local logger = require("logger")
local real_warn = logger.warn
logger.warn = function(...)
    local parts = {}
    for i = 1, select("#", ...) do parts[#parts + 1] = tostring(select(i, ...)) end
    warns[#warns + 1] = table.concat(parts, " ")
    return real_warn(...)
end

-- rows never tapped: they reach the network or restart the app
local SKIP = {
    ["Test Connection"] = true,
}
local SKIP_PATTERNS = { "Plugin UI Language", "^Language", "Check for [Uu]pdate", "[Tt]est [Pp]rovider", "Restart", "Fetch models", "Refresh" ,
    "Sign in", "Sign out", "Install", "Uninstall", "Download" }

local function skipped(t)
    if type(t) ~= "string" then return false end
    if SKIP[t] then return true end
    for _, p in ipairs(SKIP_PATTERNS) do if t:find(p) then return true end end
    return false
end

local function txt(item)
    if item.text_func then
        local ok, t = pcall(item.text_func)
        if not ok then return nil, t end
        return t
    end
    return item.text
end

local errors, missing, inert, tapped, rows, submenus = {}, {}, {}, 0, 0, 0
local visited = {}

local function stackLen() return #UIManager._window_stack end

local function closeAbove(n)
    local stack = UIManager._window_stack
    for i = #stack, n + 1, -1 do
        local w = stack[i] and stack[i].widget
        if w then pcall(UIManager.close, UIManager, w) end
    end
    S.settle()
    stack = UIManager._window_stack
    for i = #stack, n + 1, -1 do
        local w = stack[i] and stack[i].widget
        if w then pcall(UIManager.close, UIManager, w) end
    end
    S.settle()
end

local function walk(items, path, depth, mode)
    if depth > 7 or type(items) ~= "table" or visited[items] then return end
    visited[items] = true
    for _, item in ipairs(items) do
        if type(item) == "table" then
            rows = rows + 1
            local t, terr = txt(item)
            local where = mode .. ": " .. path .. " > " .. tostring(t)
            if terr then errors[#errors + 1] = where .. " text_func: " .. tostring(terr) end
            for _, fn in ipairs({ "enabled_func", "checked_func", "help_text_func", "radio_func", "hold_callback_func" }) do
                if type(item[fn]) == "function" then
                    local ok, e = pcall(item[fn])
                    if not ok then errors[#errors + 1] = where .. " " .. fn .. ": " .. tostring(e) end
                end
            end
            local subs = item.sub_item_table
            if not subs and item.sub_item_table_func then
                local w0 = #warns
                local ok, r = pcall(item.sub_item_table_func)
                submenus = submenus + 1
                if not ok then
                    errors[#errors + 1] = where .. " sub_item_table_func: " .. tostring(r)
                else
                    subs = r
                end
                for i = w0 + 1, #warns do
                    if warns[i]:find("not found") then missing[#missing + 1] = where .. ": " .. warns[i] end
                end
            end
            if subs then
                walk(subs, path .. " > " .. tostring(t), depth + 1, mode)
            elseif item.callback and not skipped(t) then
                local enabled = true
                if item.enabled_func then
                    local ok, e = pcall(item.enabled_func)
                    enabled = ok and e ~= false
                end
                if item.enabled == false then enabled = false end
                if enabled then
                    local menu = S.menu()
                    local n0, w0 = stackLen(), #warns
                    local ok, e = pcall(item.callback, menu)
                    local okS, eS = pcall(S.settle)
                    if not okS then errors[#errors + 1] = where .. " (scheduled after tap): " .. tostring(eS) end
                    tapped = tapped + 1
                    if not ok then errors[#errors + 1] = where .. " callback: " .. tostring(e) end
                    local found = false
                    for i = w0 + 1, #warns do
                        if warns[i]:find("not found") then
                            missing[#missing + 1] = where .. ": " .. warns[i]
                            found = true
                        end
                    end
                    local n1 = stackLen()
                    local menu_gone = not S.menu()
                    if ok and not found and n1 <= n0 and not menu_gone
                            and not item.checked_func and not item.radio and not item.checked then
                        inert[#inert + 1] = where
                    end
                    pcall(closeAbove, n0)
                    if not S.menu() then
                        pcall(S.closeAll)
                        pcall(S.openMenu, "KOAssistant")
                    end
                end
            end
        end
    end
end

local stubbed = {}
local function stubNetwork(plugin)
    for _, name in ipairs({ "fetchProviderModels", "startFetchModels", "testProvider", "testProviderConnection",
            "checkForUpdates", "fetchDerivedModelCaps", "refreshOllamaModels", "fetchOllamaModels" }) do
        if type(plugin[name]) == "function" then
            plugin[name] = function()
                stubbed[#stubbed + 1] = name
                UIManager:show(require("ui/widget/infomessage"):new{ text = "stub " .. name })
                return nil, "stubbed"
            end
        end
    end
end

local function run(mode)
    stubNetwork(S.plugin)
    S.openMenu("KOAssistant")
    local menu = S.menu()
    local root
    for _, tab in ipairs(menu.tab_item_table) do
        for _, item in ipairs(tab) do
            if S.itemText(item) == "KOAssistant" then root = item end
        end
    end
    S.check(root ~= nil, mode .. ": the KOAssistant row")
    local subs = root.sub_item_table or root.sub_item_table_func()
    walk(subs, "KOAssistant", 1, mode)
    pcall(S.closeAll)
end

S.open("Mock Series 3")
run("reader")
S.close()
visited = {}
S.fileManager()
run("filebrowser")

S.note("network stubs called:", table.concat(stubbed, ", "))
S.note("rows walked:", rows, "submenus opened:", submenus, "leaves tapped:", tapped)
S.check(rows > 3000 and tapped > 2000, "the walk covered the menu (" .. rows .. " rows, " .. tapped .. " leaves tapped)")
S.note("errors:", #errors)
for _, e in ipairs(errors) do print("    ERR " .. e) end
S.note("callback-not-found:", #missing)
for _, e in ipairs(missing) do print("    MISSING " .. e) end
S.note("taps with no visible effect (counted, not failed):", #inert)
S.check(#missing == 0, "no Settings row names a callback that does not exist")
S.check(#errors == 0, "no Settings row function raised an error")
S.finish()
