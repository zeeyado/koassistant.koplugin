-- Settings work per plugin instance (B602, 2026-11-05): every instance (the
-- file browser's, each book's) used to write and fsync the whole settings
-- file at its start, changed or not, then parse it a second time. Now the
-- first instance of a fresh home seeds the file once; a later instance that
-- changes nothing writes nothing and parses the file once. KOReader's own
-- frontend headless, the plugin loaded by PluginLoader (boot.lua).
local S = dofile(os.getenv("KOA_PLUGIN") .. "/tests/scenarios/boot.lua")

-- Every scenario of a run shares one home (run.sh), so an earlier scenario
-- may have seeded the settings file already: boot.lua alone leaves one key in
-- it (auto_check_updates), the plugin's first instance many. Read before the
-- counters go in. (Audit 2026-11-12: the seed was asserted without this, so
-- the default run, where s01 comes first, always reported this scenario failed.)
local seeded_before = false
do
    local settings = require("luasettings"):open(
        require("datastorage"):getSettingsDir() .. "/koassistant_settings.lua")
    local n = 0
    for _k in pairs(settings:readSetting("features") or {}) do n = n + 1 end
    seeded_before = n > 1
end

-- LuaSettings writes through util.writeToFile and reads through dofile
-- (frontend/luasettings.lua); both counted for the plugin's settings file
local writes, reads = 0, 0
local util = require("util")
local real_write = util.writeToFile
util.writeToFile = function(data, file, ...)
    if type(file) == "string" and file:find("koassistant_settings%.lua$") then writes = writes + 1 end
    return real_write(data, file, ...)
end
local real_dofile = dofile
dofile = function(path) -- luacheck: ignore
    if type(path) == "string" and path:find("koassistant_settings%.lua$") then reads = reads + 1 end
    return real_dofile(path)
end

S.fileManager()
S.check(S.plugin ~= nil, "the file browser's plugin instance")
S.note("the file browser instance: writes", writes, "reads", reads,
    seeded_before and "(a home an earlier scenario seeded)" or "(a fresh home)")
if seeded_before then
    S.check(writes == 0, "a home seeded earlier: the first instance of this scenario writes nothing")
else
    S.check(writes >= 1, "a fresh home: the first instance seeds the settings file")
end
S.closeFileManager()
local w1, r1 = writes, reads
S.note("after the file browser closed: writes", w1, "reads", r1)

S.open("Mock Series 3")
S.check(S.plugin ~= nil, "the reader's plugin instance")
S.check(writes == w1, string.format("the reader instance writes nothing at its start (%d writes)", writes - w1))
S.check(reads - r1 == 1, string.format("and parses the file once (%d reads)", reads - r1))
S.close()

local w2, r2 = writes, reads
S.open("Mock Series 2")
S.check(writes == w2, string.format("a second reader instance writes nothing either (%d writes)", writes - w2))
S.check(reads - r2 == 1, string.format("and parses the file once (%d reads)", reads - r2))

S.finish()
