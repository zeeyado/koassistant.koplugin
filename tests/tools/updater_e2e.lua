-- One "Update Now" with the updater a reader has installed (B379). Loads
-- <plugins>/koassistant.koplugin/koassistant_update_checker.lua, the installed
-- version's own code, and runs its performUpdate on <zip> as release <version>,
-- with KOReader's real archive, file and process code. Only the screen,
-- settings and network are stubbed; the download is a copy of <zip>.
-- Prints every message the reader would see, one "MSG <kind>: <text>" line
-- each. tests/tools/updater_e2e.sh prepares the folders and checks the result.
--
-- Run from KOReader's folder with its LuaJIT:
--   cd /Applications/KOReader.app/Contents/koreader
--   ./luajit <repo>/tests/tools/updater_e2e.lua <plugins> <zip> <version> <settings> [size] [sha256]

local plugins, zip, version, settings_dir, zip_size, zip_sha256 = arg[1], arg[2], arg[3], arg[4], arg[5], arg[6]
assert(plugins and zip and version and settings_dir, "usage: updater_e2e.lua <plugins> <zip> <version> <settings> [size] [sha256]")
local plugin = plugins .. "/koassistant.koplugin"

require("setupkoenv")

-- What the reader would see
local function say(kind, text)
    io.write("MSG ", kind, ": ", (tostring(text):gsub("\n", " | ")), "\n")
end

-- Stubs: widgets record their text; nothing is drawn
local function widget(kind)
    return { new = function(_self, o) o = o or {}; o._kind = kind; return o end }
end
local UIManager = {
    show = function(_self, w) if type(w) == "table" and w.text then say(w._kind or "widget", w.text) end end,
    close = function() end,
    forceRePaint = function() end,
    setDirty = function() end,
    broadcastEvent = function() end,
    scheduleIn = function(_self, _delay, fn) fn() end,
    nextTick = function(_self, fn) fn() end,
    unschedule = function() end,
    askForRestart = function(_self, msg) say("restart", msg) end,
}
local stubs = {
    ["ui/uimanager"] = UIManager,
    ["ui/widget/infomessage"] = widget("info"),
    ["ui/widget/confirmbox"] = widget("confirm"),
    ["ui/widget/buttondialog"] = widget("buttons"),
    ["ui/widget/notification"] = widget("notification"),
    ["ui/network/manager"] = { isOnline = function() return true end,
        runWhenOnline = function(_self, fn) fn() end, runWhenConnected = function(_self, fn) fn() end },
    ["device"] = { isAndroid = function() return false end, canOpenLink = function() return false end,
        screen = { getWidth = function() return 600 end, getHeight = function() return 800 end,
            scaleBySize = function(_self, n) return n end } },
    ["datastorage"] = { getSettingsDir = function() return settings_dir end,
        getDataDir = function() return settings_dir end, getFullDataDir = function() return settings_dir end },
    ["luasettings"] = { open = function() return {
        readSetting = function() end, saveSetting = function() end, flush = function() end,
        isTrue = function() return false end, has = function() return false end } end },
}
for name, mod in pairs(stubs) do
    package.preload[name] = function() return mod end
end
-- Every other screen module the updater's loadUI pulls in: an empty stub
local function stubLoader(name)
    if name:match("^ui/") or name:match("^apps/") or name == "ffi/blitbuffer" then
        return function() return setmetatable({}, { __index = function() return widget(name) end }) end
    end
end
table.insert(package.loaders, 2, stubLoader)
G_reader_settings = stubs["luasettings"].open()  -- luacheck: ignore

-- The installed plugin's modules come first, as in KOReader
package.path = plugin .. "/?.lua;" .. package.path

local UC = assert(loadfile(plugin .. "/koassistant_update_checker.lua"))()

local function upvalue(fn, name)
    local i = 1
    while true do
        local n, v = debug.getupvalue(fn, i)
        if not n then return nil end
        if n == name then return v, i end
        i = i + 1
    end
end
-- Update Now's own code: the popup's button calls performUpdate
local showUpdatePopup = assert(upvalue(UC.showPendingUpdate, "showUpdatePopup"), "showUpdatePopup not found")
local performUpdate = assert(upvalue(showUpdatePopup, "performUpdate"), "performUpdate not found")
local _dl, dl_index = upvalue(performUpdate, "downloadFile")
assert(dl_index, "downloadFile not found")
-- The download: the zip's bytes land where the real download writes them
debug.setupvalue(performUpdate, dl_index, function(_url, dest, callback)
    local src = assert(io.open(zip, "rb"))
    local data = src:read("*a")
    src:close()
    local out = assert(io.open(dest, "wb"))
    out:write(data)
    out:close()
    callback(true)
end)

performUpdate({
    zip_url = "file://" .. zip,
    latest_version = version,
    zip_size = tonumber(zip_size),
    zip_sha256 = zip_sha256 ~= "" and zip_sha256 or nil,
})
io.write("DONE\n")
