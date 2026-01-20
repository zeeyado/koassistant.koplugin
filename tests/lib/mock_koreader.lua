-- Mock KOReader modules for standalone testing
-- This file must be required BEFORE any plugin modules

-- Debug flag for mocks
local VERBOSE_MOCKS = os.getenv("KOASSISTANT_VERBOSE_MOCKS")

-- Mock logger (used by handlers for warnings and debug output)
package.loaded["logger"] = {
    warn = function(...)
        local args = {...}
        local msg = table.concat(vim and vim.tbl_map(tostring, args) or {}, " ")
        for i, v in ipairs(args) do
            msg = (i == 1 and "" or msg .. " ") .. tostring(v)
        end
        print("[WARN]", ...)
    end,
    dbg = function(...)
        if VERBOSE_MOCKS then
            print("[DBG]", ...)
        end
    end,
    info = function(...)
        print("[INFO]", ...)
    end,
    err = function(...)
        print("[ERROR]", ...)
    end,
}

-- Mock ffi (used by base.lua for streaming - we don't support streaming in tests)
package.loaded["ffi"] = {
    C = {
        close = function() end,
        read = function() return 0 end,
    },
    typeof = function() return function() end end,
    new = function() return {} end,
    cdef = function() end,
}

-- Mock ffi/util (used by base.lua for subprocess streaming)
package.loaded["ffi/util"] = {
    runInSubProcess = function()
        error("Streaming is not supported in standalone tests. Use non-streaming mode.")
    end,
    terminateSubProcess = function() end,
    isSubProcessDone = function() return true end,
    getNonBlockingReadSize = function() return 0 end,
    readAllFromFD = function() return "" end,
    writeToFD = function() end,
    template = function(str, table)
        -- Simple template substitution
        return (str:gsub("%%(%d+)", function(i)
            return tostring(table[tonumber(i)] or "")
        end))
    end,
}

-- Use dkjson instead of KOReader's json
-- dkjson is a pure Lua JSON library available via luarocks
local json_ok, dkjson = pcall(require, "dkjson")
if json_ok then
    package.loaded["json"] = dkjson
else
    -- Fallback: try cjson
    local cjson_ok, cjson = pcall(require, "cjson")
    if cjson_ok then
        package.loaded["json"] = cjson
    else
        error([[
JSON library not found. Please install one:
  luarocks install dkjson    (recommended, pure Lua)
  luarocks install lua-cjson (faster, requires compilation)
]])
    end
end

-- Mock gettext (internationalization)
package.loaded["gettext"] = function(str)
    return str
end

-- Mock lfs (luafilesystem - used by behavior_loader and domain_loader)
-- Try to use real lfs if available, otherwise provide minimal mock
local lfs_ok, real_lfs = pcall(require, "lfs")
if lfs_ok then
    -- Real lfs available - use it directly
    package.loaded["libs/libkoreader-lfs"] = real_lfs
else
    -- Minimal mock for when lfs isn't available
    local mock_lfs = {
        attributes = function(path)
            -- Return nil for non-existent paths
            -- Tests can override this if needed
            return nil
        end,
        dir = function(path)
            -- Return empty iterator
            return function() return nil end
        end,
    }
    package.loaded["libs/libkoreader-lfs"] = mock_lfs
end

-- Mock UI widgets (for stream_handler.lua)
-- These are not used in unit tests, but need to exist so the module loads
package.loaded["ui/widget/inputtext"] = {
    extend = function() return {} end,
}
package.loaded["ui/widget/inputdialog"] = {}
package.loaded["ui/uimanager"] = {
    show = function() end,
    close = function() end,
    scheduleIn = function() end,
}
package.loaded["ui/font"] = {
    getFace = function() return {} end,
}
package.loaded["ui/size"] = {
    padding = { default = 0, large = 0 },
    margin = { default = 0 },
    line = { thick = 1 },
    border = { default = 1 },
}
package.loaded["device"] = {
    screen = {
        getWidth = function() return 800 end,
        getHeight = function() return 600 end,
    },
    isTouchDevice = function() return false end,
    hasKeys = function() return false end,
}
package.loaded["ui/constants"] = {
    DIALOG_WIDTH = 600,
}

-- Verification message
if VERBOSE_MOCKS then
    print("[MOCK] KOReader mocks loaded successfully")
    print("[MOCK] JSON library: " .. (json_ok and "dkjson" or "cjson"))
end

return {
    VERBOSE_MOCKS = VERBOSE_MOCKS,
}
