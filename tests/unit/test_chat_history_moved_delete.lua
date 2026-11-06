-- A chat saved before its book was moved still records the old path; the
-- chat index was re-keyed to the new path by the move. Deleting the chat
-- through the new path must update the index under the new path (the sweep
-- of 2026-11-06; audit findings_by_module.md): it wrote a fresh entry under
-- the OLD path and left the new one's count as it was.
--
-- Run: lua tests/unit/test_chat_history_moved_delete.lua  (or lua tests/run_tests.lua --unit)

local function setupPaths()
    local info = debug.getinfo(1, "S")
    local script_path = info.source:match("@?(.*)")
    local unit_dir = script_path:match("(.+)/[^/]+$") or "."
    local tests_dir = unit_dir:match("(.+)/[^/]+$") or "."
    local plugin_dir = tests_dir:match("(.+)/[^/]+$") or "."
    package.path = table.concat({
        plugin_dir .. "/?.lua", tests_dir .. "/?.lua", tests_dir .. "/lib/?.lua", package.path,
    }, ";")
end
setupPaths()
require("mock_koreader")
local TestRunner = require("test_runner"):new()

print("Running: test_chat_history_moved_delete")
print("")

-- in-memory LuaSettings and DocSettings over one store, by path
local saved = {
    luasettings = package.loaded["luasettings"], docsettings = package.loaded["docsettings"],
    util = package.loaded["util"],
    manager = package.loaded["koassistant.chat.chat_history_manager"],
    store = package.loaded["koassistant.storage.book_store"],
    doc = package.loaded["koassistant.storage.doc_settings"],
    G = _G.G_reader_settings,
}
local lfs = package.loaded["libs/libkoreader-lfs"]
local saved_attr = lfs.attributes

local function deepCopy(o)
    if type(o) ~= "table" then return o end
    local c = {}
    for k, v in pairs(o) do c[deepCopy(k)] = deepCopy(v) end
    return c
end
local store = {}
local LS = {}
LS.__index = LS
function LS:open(p) store[p] = store[p] or {}; return setmetatable({ _path = p, file = p }, LS) end
function LS:readSetting(k, d) local v = store[self._path][k]; if v == nil then return d end; return deepCopy(v) end
function LS:saveSetting(k, v) store[self._path][k] = deepCopy(v) end
function LS:flush() end
local DS = {}
DS.__index = DS
function DS:open(p) local key = "ds:" .. p; store[key] = store[key] or {}; return setmetatable({ _path = key, data = {} }, DS) end
DS.readSetting, DS.saveSetting, DS.flush = LS.readSetting, LS.saveSetting, LS.flush
function DS:has() return false end
function DS:getSidecarDir(p) return (p:match("(.*)%.") or p) .. ".sdr" end
package.loaded["luasettings"] = LS
package.loaded["docsettings"] = DS
package.loaded["util"] = { makePath = function() end }
local g = {}
_G.G_reader_settings = {
    readSetting = function(_s, k, d) local v = g[k]; if v == nil then return d end; return v end,
    saveSetting = function(_s, k, v) g[k] = v end, flush = function() end,
}
local files = {}
lfs.attributes = function(p, a)
    if files[p] then
        if a == "mode" then return "file" end
        return { mode = "file", modification = 1, size = 1 }
    end
    return nil
end
package.loaded["koassistant.chat.chat_history_manager"] = nil
package.loaded["koassistant.storage.book_store"] = nil
package.loaded["koassistant.storage.doc_settings"] = nil
local M = require("koassistant.chat.chat_history_manager")
local BookStore = require("koassistant.storage.book_store")

TestRunner:test("deleting a chat through the moved book's path updates the index under that path", function()
    local mgr = M:new()
    local OLD, NEW = "/books/a/Book.epub", "/books/b/Book.epub"
    files[OLD] = true
    local function chat(id)
        return { id = id, title = "t", document_path = OLD, timestamp = os.time(),
            messages = { { role = "user", content = "q" } } }
    end
    mgr:saveChatToDocSettings(nil, chat("c1"))
    mgr:saveChatToDocSettings(nil, chat("c2"))
    -- the move patch: the chats file follows the book, the index is re-keyed,
    -- the chats keep their old document_path
    local old_file = BookStore.pathFor(OLD, BookStore.CHATS_FILE)
    local new_file = BookStore.pathFor(NEW, BookStore.CHATS_FILE)
    store[new_file], store[old_file] = store[old_file], nil
    files[OLD], files[NEW], files[new_file] = nil, true, true
    BookStore.invalidate(OLD)
    local idx = g.koassistant_chat_index
    idx[NEW], idx[OLD] = idx[OLD], nil
    TestRunner:assertEqual(idx[NEW].count, 2, "two chats under the new path")
    TestRunner:assertTrue(mgr:deleteChat(NEW, "c1"), "deleted")
    idx = g.koassistant_chat_index
    TestRunner:assertEqual(idx[NEW] and idx[NEW].count, 1, "the new path's entry counts one")
    TestRunner:assertEqual(idx[OLD], nil, "nothing written under the old path")
    TestRunner:assertTrue(mgr:deleteChat(NEW, "c2"), "the last one deleted")
    idx = g.koassistant_chat_index
    TestRunner:assertTrue(idx[NEW] == nil or (idx[NEW].count or 0) == 0, "the entry is gone or empty")
    TestRunner:assertEqual(idx[OLD], nil)
end)

lfs.attributes = saved_attr
package.loaded["luasettings"] = saved.luasettings
package.loaded["docsettings"] = saved.docsettings
package.loaded["util"] = saved.util
package.loaded["koassistant.chat.chat_history_manager"] = saved.manager
package.loaded["koassistant.storage.book_store"] = saved.store
package.loaded["koassistant.storage.doc_settings"] = saved.doc
_G.G_reader_settings = saved.G

return TestRunner:summary()
