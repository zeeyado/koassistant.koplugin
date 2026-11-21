-- A background job's result is read into a buffer the reader still holds
-- (B769, 2026-11-21).
--
-- Five readers allocated a buffer, kept only a pointer cast from it
-- (`local pointer = ffi.cast("void*", buffer)`) and read into that pointer
-- from a function scheduled for later. A cast pointer keeps nothing alive in
-- LuaJIT: once the function that made the buffer returned, the buffer's own
-- variable was gone, the collector was free to release the memory, and the
-- child's bytes then landed in memory the app was using. The app ended with a
-- segmentation fault some seconds later, at an address made of the child's own
-- bytes (the app, run on a book opened on its last page, ended that way twice
-- in three runs; shown in KOReader's LuaJIT with a finalizer on the buffer:
-- freed before the read with the pointer alone, alive with the buffer itself).
--
-- The rule: a read buffer is handed to read() and to ffi.string() ITSELF, so
-- the function that reads holds it. A reader may keep a cast pointer beside
-- it only when the same function also uses the buffer (the two request
-- readers do, through ffi.string).
--
-- This file reads the source; LuaJIT's collector is not in the unit suite.
--
-- Run: lua tests/unit/test_read_buffers.lua  (or lua tests/run_tests.lua --unit)

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

local TestRunner = require("test_runner"):new()

local function pluginFiles()
    local files = {}
    local p = io.popen('cd "' .. plugin_dir .. '" && ls main.lua && find koassistant -name "*.lua" | LC_ALL=C sort')
    for line in p:lines() do files[#files + 1] = line end
    p:close()
    return files
end

local function read(path)
    local f = assert(io.open(plugin_dir .. "/" .. path, "r"))
    local text = f:read("*a")
    f:close()
    return text
end

-- every `local NAME = ffi.cast("void*", OWNER)` of a file (either quote)
local function castPointers(text)
    local found = {}
    for name, owner in text:gmatch("local%s+([%w_]+)%s*=%s*ffi%.cast%(%s*[\"']void%s*%*[\"']%s*,%s*([%w_]+)%s*%)") do
        found[#found + 1] = { name = name, owner = owner }
    end
    return found
end

print("Running: test_read_buffers")
print("")
print("  [a read buffer is held by the function that reads into it (B769)]")

TestRunner:test("the pattern is found where it is, and not where it is not", function()
    local bad = 'local chunk = ffi.new("char[?]", n)\nlocal pointer = ffi.cast("void*", chunk)\n'
        .. "local function poll() ffi.C.read(fd, pointer, n) return ffi.string(pointer, n) end\n"
    local casts = castPointers(bad)
    TestRunner:assertEqual(#casts, 1)
    TestRunner:assertEqual(casts[1].name .. " from " .. casts[1].owner, "pointer from chunk")
    TestRunner:assertEqual(#castPointers("local p = ffi.cast('void *', buf)"), 1, "single quotes and a space")
    TestRunner:assertEqual(#castPointers('ffi.C.read(fd, ffi.cast("void*", buffer), n)'), 0,
        "a cast made at the call uses the buffer there, so it is held")
    TestRunner:assertEqual(#castPointers('local ptr = ffi.cast("const char*", data)'), 0, "a view of a Lua string")
end)

TestRunner:test("no reader keeps only a pointer to its buffer", function()
    local files = pluginFiles()
    TestRunner:assertTrue(#files > 80, "the plugin's files are listed (" .. #files .. ")")
    local kept, problems = 0, {}
    for _idx, path in ipairs(files) do
        local text = read(path)
        for _idx2, cast in ipairs(castPointers(text)) do
            -- allowed only beside a use of the buffer itself in a read-back
            if text:find("ffi.string(" .. cast.owner .. ",", 1, true) then
                kept = kept + 1
            else
                problems[#problems + 1] = path .. ": " .. cast.name .. " = ffi.cast(\"void*\", " .. cast.owner
                    .. ") and no ffi.string(" .. cast.owner .. ", ...): pass " .. cast.owner
                    .. " itself to read() and ffi.string()"
            end
        end
    end
    TestRunner:assertEqual(table.concat(problems, "\n"), "")
    TestRunner:assertEqual(kept, 2, "the two request readers, which use their buffer beside the pointer")
end)

TestRunner:test("the five background readers read into the buffer they made", function()
    local READERS = {
        { "koassistant/xray/xray_index.lua", "chunk" },          -- the name index's background pass
        { "koassistant/api/base.lua", "buffer" },                -- fetchAsync: model lists, the provider test, the update check
        { "koassistant/tools/book_tools.lua", "chunk" },         -- the book search off the loop
        { "koassistant/images/image_generator.lua", "buf" },     -- the picture request
        { "koassistant/api/openai_codex_oauth.lua", "buffer" },  -- the subscription sign-in
    }
    for _idx, reader in ipairs(READERS) do
        local path, owner = reader[1], reader[2]
        local text = read(path)
        TestRunner:assertTrue(text:find("local " .. owner .. ' = ffi.new("char[?]",', 1, true) ~= nil,
            path .. ": makes its buffer")
        local _s, reads = text:gsub("ffi%.C%.read%([%w_]+, " .. owner .. ", [%w_]+%)", "")
        TestRunner:assertEqual(reads, 2, path .. ": both reads take the buffer itself")
        local _s2, strings = text:gsub("ffi%.string%(" .. owner .. ", bytes%)", "")
        TestRunner:assertEqual(strings, 2, path .. ": and both copies out of it")
    end
end)

return TestRunner:summary()
