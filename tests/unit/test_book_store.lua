--[[
Unit tests: koassistant_book_store.lua (Track 37 — plugin data out of metadata.lua)

- Facade: plugin keys route to koassistant_book_settings.lua, KOReader keys
  pass through to the DocSettings, saveSetting(nil) deletes, flush never
  touches KOReader's file, wrap is idempotent, degrades without a sidecar path
- Store: one cached instance per book, writes persist immediately, an emptied
  store removes its file, invalidate drops the cache
- Chats file: read/write/verify, empty table removes the file
- migrateBook: copy-first/verify/delete/flush, existing file data wins,
  empty legacy chats key just deleted, idempotent, clean books untouched,
  index refreshed with the moved chats
- ensureMigrated: straggler net once per session, retries after a failure;
  a chats read with no chats file folds the book's legacy chats in first
- migrateAll: candidates walked, version-bump contract (zero failures)
- SafeDocSettings.resolve returns a facade; resolveRaw the DocSettings
- STRUCTURAL GATES: no chats key read/write outside the store, no direct
  `ui.doc_settings:` calls in main.lua, no sidecar_dockey registry entries

Run: lua tests/run_tests.lua --unit
]]

local plugin_dir
local function setupPaths()
    local info = debug.getinfo(1, "S")
    local script_path = info.source:match("@?(.*)")
    local unit_dir = script_path:match("(.+)/[^/]+$") or "."
    local tests_dir = unit_dir:match("(.+)/[^/]+$") or "."
    plugin_dir = tests_dir:match("(.+)/[^/]+$") or "."
    package.path = table.concat({
        plugin_dir .. "/?.lua",
        tests_dir .. "/?.lua",
        tests_dir .. "/lib/?.lua",
        package.path,
    }, ";")
end
setupPaths()

-- ============================================================
-- Mocks (installed BEFORE the standard mocks so ours win)
-- ============================================================
local function deepCopy(o)
    if type(o) ~= "table" then return o end
    local c = {}
    for k, v in pairs(o) do c[deepCopy(k)] = deepCopy(v) end
    return c
end

local files = {}          -- path -> { data = table }  (LuaSettings "disk")
local existing = {}       -- path -> true (lfs.attributes file registry)
local ds_flushes = {}     -- doc_path -> count of DocSettings:flush()

local saved = {
    luasettings = package.loaded["luasettings"],
    docsettings = package.loaded["docsettings"],
    lfs = package.loaded["libs/libkoreader-lfs"],
    util = package.loaded["util"],
    readhistory = package.loaded["readhistory"],
    rebuilder = package.loaded["koassistant_index_rebuilder"],
    chm = package.loaded["koassistant_chat_history_manager"],
    store = package.loaded["koassistant_book_store"],
    sds = package.loaded["koassistant_doc_settings"],
}

-- Persistent LuaSettings by path (colon or dot call)
local MockLS = {}
MockLS.__index = MockLS
package.loaded["luasettings"] = {
    open = function(a, b)
        local path = b or a
        if not files[path] then files[path] = { data = {} } end
        return setmetatable({ _path = path, data = files[path].data }, MockLS)
    end,
}
function MockLS:readSetting(key, default)
    local v = self.data[key]
    if v == nil then return default end
    return deepCopy(v)
end
function MockLS:saveSetting(key, value) self.data[key] = deepCopy(value); return self end
function MockLS:delSetting(key) self.data[key] = nil; return self end
function MockLS:has(key) return self.data[key] ~= nil end
function MockLS:flush() existing[self._path] = true; return self end

-- DocSettings: per-book data table with doc_path, flush counter
local docs = {}   -- doc_path -> data table
local MockDS = {}
MockDS.__index = MockDS
function MockDS:getSidecarDir(doc_path, _loc)
    return (doc_path:match("(.*)%.") or doc_path) .. ".sdr"
end
function MockDS:open(doc_path)
    if not docs[doc_path] then docs[doc_path] = { doc_path = doc_path } end
    return setmetatable({ data = docs[doc_path] }, MockDS)
end
function MockDS:readSetting(key, default)
    local v = self.data[key]
    if v == nil then return default end
    return v
end
function MockDS:saveSetting(key, value) self.data[key] = value; return self end
function MockDS:delSetting(key) self.data[key] = nil; return self end
function MockDS:has(key) return self.data[key] ~= nil end
function MockDS:flush()
    local p = self.data.doc_path
    ds_flushes[p] = (ds_flushes[p] or 0) + 1
    if self.data._fail_flush then error("disk full") end  -- lives on the shared data (any instance)
    return self
end
function MockDS.isHashLocationEnabled() return false end
package.loaded["docsettings"] = MockDS

package.loaded["util"] = { makePath = function() end }

-- os.remove against the in-memory "disk"
local saved_os_remove = os.remove
os.remove = function(path)  -- luacheck: ignore 122
    if existing[path] then existing[path] = nil; files[path] = nil; return true end
    return nil, "no such file"
end


local g_store = {}
_G.G_reader_settings = {
    readSetting = function(_, key, default)
        if key == "document_metadata_folder" then return "doc" end
        local v = g_store[key]
        if v == nil then return default end
        return v
    end,
    saveSetting = function(_, key, value) g_store[key] = value end,
    flush = function() end,
}

require("mock_koreader")
-- The shared mock installs its own lfs unconditionally; ours must win
package.loaded["libs/libkoreader-lfs"] = {
    attributes = function(path, attr)
        if existing[path] then
            if attr == "mode" then return "file" end
            if attr then return nil end
            return { mode = "file", modification = 1, size = 1 }
        end
        return nil
    end,
    dir = function() return function() return nil end end,
    mkdir = function() return true end,
}

package.loaded["koassistant_book_store"] = nil
package.loaded["koassistant_doc_settings"] = nil
package.loaded["koassistant_chat_history_manager"] = nil
package.loaded["koassistant_index_rebuilder"] = nil

-- Chat manager stub: record index refreshes (the real one is exercised elsewhere)
local index_calls = {}
package.loaded["koassistant_chat_history_manager"] = {
    updateChatIndex = function(_self, path, op, _id, chats, opts)
        local n = 0
        for _ in pairs(chats) do n = n + 1 end
        table.insert(index_calls, { path = path, op = op, count = n, has_props = opts and opts.has_props })
    end,
}

-- Index rebuilder stub for migrateAll
local candidates = {}
package.loaded["koassistant_index_rebuilder"] = {
    collectCandidates = function() return candidates end,
    hasAnySidecarDir = function(path) return existing[(path:match("(.*)%.") or path) .. ".sdr"] == true end,
}

local BookStore = require("koassistant_book_store")
local SafeDocSettings = require("koassistant_doc_settings")

-- ============================================================
-- Runner
-- ============================================================
local TestRunner = { passed = 0, failed = 0 }
local function reset()
    files = {}; existing = {}; docs = {}; ds_flushes = {}; index_calls = {}; candidates = {}; g_store = {}
    BookStore._resetForTests()
    BookStore._resetMigrationMemoForTests()
end
function TestRunner:test(name, fn)
    reset()
    local ok, err = pcall(fn)
    if ok then
        self.passed = self.passed + 1
        print(string.format("    ✓ %s", name))
    else
        self.failed = self.failed + 1
        print(string.format("    ✗ %s\n      %s", name, tostring(err)))
    end
end
local function eq(a, b, msg)
    if a ~= b then
        error(string.format("%s: expected '%s', got '%s'", msg or "assert", tostring(b), tostring(a)), 2)
    end
end
local function truthy(v, msg) if not v then error((msg or "assert") .. ": expected truthy", 2) end end

local BOOK = "/books/a.epub"
local SFILE = "/books/a.sdr/koassistant_book_settings.lua"
local CFILE = "/books/a.sdr/koassistant_chats.lua"
local function bookFile(path) existing[path] = true; existing[(path:match("(.*)%.") or path) .. ".sdr"] = true end

-- ============================================================
print("\n  -- facade --")

TestRunner:test("plugin keys route to the settings file, KOReader keys pass through", function()
    bookFile(BOOK)
    local raw = MockDS:open(BOOK)
    raw.data.percent_finished = 0.4
    local f = BookStore.wrap(raw, BOOK)
    truthy(BookStore.isFacade(f), "wrapped")
    f:saveSetting("koassistant_book_domain", "history")
    eq(f:readSetting("koassistant_book_domain"), "history", "read back through facade")
    eq(f:readSetting("percent_finished"), 0.4, "KOReader key passes through")
    eq(raw.data.koassistant_book_domain, nil, "metadata.lua never receives the plugin key")
    eq(files[SFILE].data.settings.koassistant_book_domain, "history", "persisted immediately")
    eq(ds_flushes[BOOK], nil, "KOReader's file never flushed by the plugin")
    f:flush()
    eq(ds_flushes[BOOK], nil, "facade flush touches only our file")
end)

TestRunner:test("saveSetting(nil) and delSetting remove; has() reflects the store; empty store removes its file", function()
    bookFile(BOOK)
    local f = BookStore.wrap(MockDS:open(BOOK), BOOK)
    f:saveSetting("koassistant_book_quiz", { enabled = false })
    truthy(f:has("koassistant_book_quiz"), "has after save")
    f:saveSetting("koassistant_book_quiz", nil)
    eq(f:has("koassistant_book_quiz"), false, "nil = delete")
    f:saveSetting("koassistant_doi", false)
    eq(f:readSetting("koassistant_doi"), false, "false sentinel stored, not treated as absent")
    f:delSetting("koassistant_doi")
    eq(f:readSetting("koassistant_doi", "dflt"), "dflt", "default after delete")
    eq(existing[SFILE], nil, "emptied store removed its file")
end)

TestRunner:test("wrap is idempotent and degrades without a sidecar path", function()
    bookFile(BOOK)
    local f = BookStore.wrap(MockDS:open(BOOK), BOOK)
    eq(BookStore.wrap(f), f, "wrapping a facade returns it")
    local fake = { readSetting = function() return "x" end }
    eq(BookStore.wrap(fake), fake, "no path = object returned unwrapped")
    eq(BookStore.wrap(nil), nil, "nil stays nil")
    eq(BookStore.unwrap(f).data.doc_path, BOOK, "unwrap yields the DocSettings")
end)

TestRunner:test("one store per book: two facades see the same value; invalidate re-reads disk", function()
    bookFile(BOOK)
    local f1 = BookStore.wrap(MockDS:open(BOOK), BOOK)
    local f2 = BookStore.wrap(MockDS:open(BOOK), BOOK)
    f1:saveSetting("koassistant_book_spoiler_free", false)
    eq(f2:readSetting("koassistant_book_spoiler_free"), false, "shared instance")
    files[SFILE].data.settings.koassistant_book_spoiler_free = true  -- external write
    BookStore.invalidate(BOOK)
    eq(f2:readSetting("koassistant_book_spoiler_free"), true, "re-read after invalidate")
end)

-- ============================================================
print("\n  -- chats file --")

TestRunner:test("writeChats + readChats roundtrip; empty write removes the file", function()
    bookFile(BOOK)
    local ok = BookStore.writeChats(BOOK, { c1 = { id = "c1", messages = {} } })
    truthy(ok, "write ok")
    truthy(BookStore.hasChatsFile(BOOK), "file exists")
    eq(BookStore.readChats(BOOK).c1.id, "c1", "read back")
    eq(BookStore.readChats("/books/none.epub").c1, nil, "unknown book = empty")
    truthy(BookStore.writeChats(BOOK, {}), "empty write ok")
    eq(existing[CFILE], nil, "chats file removed")
    local bad = BookStore.writeChats(BOOK, { c1 = "nope" })
    eq(bad, false, "non-table chat rejected")
end)

-- ============================================================
print("\n  -- migrateBook --")

TestRunner:test("moves chats + keys out of metadata.lua, deletes them there, flushes KOReader's file once", function()
    bookFile(BOOK)
    local raw = MockDS:open(BOOK)
    raw.data.percent_finished = 0.5
    raw.data.koassistant_chats = { c1 = { id = "c1", messages = {} } }
    raw.data.koassistant_book_domain = "history"
    raw.data.koassistant_notebook_ref = { filename = "x.md" }
    raw.data.doc_props = { title = "T" }
    local status, info = BookStore.migrateBook(BOOK, raw)
    eq(status, "moved", "status")
    eq(info.chats, 1, "one chat moved")
    eq(info.keys, 2, "two keys moved")
    eq(raw.data.koassistant_chats, nil, "chats gone from metadata.lua")
    eq(raw.data.koassistant_book_domain, nil, "key gone from metadata.lua")
    eq(raw.data.percent_finished, 0.5, "KOReader data untouched")
    eq(ds_flushes[BOOK], 1, "KOReader file flushed once")
    eq(BookStore.readChats(BOOK).c1.id, "c1", "chat in the chats file")
    eq(BookStore.settings(BOOK):readSetting("koassistant_book_domain"), "history", "key in the settings file")
    eq(#index_calls, 1, "chat index refreshed")
    eq(index_calls[1].op, "refresh", "refresh op")
    eq(index_calls[1].has_props, true, "title/author carried")
end)

TestRunner:test("existing file data wins on collision; an empty legacy chats key is just deleted", function()
    bookFile(BOOK)
    BookStore.writeChats(BOOK, { c1 = { id = "c1", title = "file copy" } })
    BookStore.settings(BOOK):saveSetting("koassistant_book_domain", "file copy")
    local raw = MockDS:open(BOOK)
    raw.data.koassistant_chats = { c1 = { id = "c1", title = "metadata copy" }, c2 = { id = "c2" } }
    raw.data.koassistant_book_domain = "metadata copy"
    local status = BookStore.migrateBook(BOOK, raw)
    eq(status, "moved", "moved")
    local chats = BookStore.readChats(BOOK)
    eq(chats.c1.title, "file copy", "file wins for c1")
    eq(chats.c2.id, "c2", "c2 added")
    eq(BookStore.settings(BOOK):readSetting("koassistant_book_domain"), "file copy", "file wins for the key")

    reset(); bookFile(BOOK)
    local raw2 = MockDS:open(BOOK)
    raw2.data.koassistant_chats = {}
    local st2 = BookStore.migrateBook(BOOK, raw2)
    eq(st2, "moved", "empty chats key handled")
    eq(raw2.data.koassistant_chats, nil, "empty legacy key deleted")
    eq(existing[CFILE], nil, "no chats file created for nothing")
end)

TestRunner:test("clean book is untouched; a failed KOReader flush leaves the keys for a retry (copies kept)", function()
    bookFile(BOOK)
    local raw = MockDS:open(BOOK)
    raw.data.percent_finished = 0.1
    eq(BookStore.migrateBook(BOOK, raw), "clean", "clean")
    eq(ds_flushes[BOOK], nil, "no flush on a clean book")

    raw.data.koassistant_book_domain = "history"
    raw.data._fail_flush = true
    local status = BookStore.migrateBook(BOOK, raw)
    eq(status, "failed", "failed")
    eq(BookStore.settings(BOOK):readSetting("koassistant_book_domain"), "history", "copy landed")
    -- the keys were removed from the in-memory table before the flush attempt;
    -- on disk metadata.lua still holds them, and the next pass re-reads it
    raw.data._fail_flush = false
    raw.data.koassistant_book_domain = "history"
    eq(BookStore.migrateBook(BOOK, raw), "moved", "retry succeeds")
    eq(BookStore.migrateBook(BOOK, raw), "clean", "idempotent afterwards")
end)

TestRunner:test("migrateBook refuses a facade and a book without a sidecar path", function()
    bookFile(BOOK)
    local f = BookStore.wrap(MockDS:open(BOOK), BOOK)
    eq(BookStore.migrateBook(BOOK, f), "failed", "facade refused")
    local raw = MockDS:open("__GENERAL_CHATS__")
    raw.data.koassistant_chats = { c1 = { id = "c1" } }
    eq(BookStore.migrateBook("__GENERAL_CHATS__", raw), "failed", "special path refused")
end)

-- ============================================================
print("\n  -- straggler net (ensureMigrated / wrap) --")

TestRunner:test("wrap folds legacy keys in on first touch, once per session", function()
    bookFile(BOOK)
    local raw = MockDS:open(BOOK)
    raw.data.koassistant_book_domain = "history"
    local f = BookStore.wrap(raw, BOOK)
    eq(f:readSetting("koassistant_book_domain"), "history", "value visible through the facade")
    eq(raw.data.koassistant_book_domain, nil, "moved out of metadata.lua")
    eq(ds_flushes[BOOK], 1, "one flush")
    raw.data.koassistant_book_domain = "stale write by an old build"
    BookStore.wrap(raw, BOOK)
    eq(ds_flushes[BOOK], 1, "no second check this session")
    BookStore._resetMigrationMemoForTests()
    BookStore._resetForTests()  -- a new session = new store cache + new memo
    BookStore.wrap(raw, BOOK)
    eq(ds_flushes[BOOK], 2, "next session folds the straggler in")
    f = BookStore.wrap(raw, BOOK)
    eq(f:readSetting("koassistant_book_domain"), "history", "existing store value wins over the stale write")
end)

TestRunner:test("ensureMigrated without a DocSettings opens one only when our file is missing", function()
    bookFile(BOOK)
    local raw = MockDS:open(BOOK)
    raw.data.koassistant_chats = { c1 = { id = "c1" } }
    eq(BookStore.ensureMigrated(BOOK), "moved", "opened + moved")
    eq(BookStore.readChats(BOOK).c1.id, "c1", "chats file written")
    BookStore._resetMigrationMemoForTests()
    BookStore.settings(BOOK):saveSetting("koassistant_book_domain", "x")  -- settings file now exists
    raw.data.koassistant_chats = { c9 = { id = "c9" } }
    eq(BookStore.ensureMigrated(BOOK), nil, "skipped: store file present, no DocSettings in hand")
    eq(BookStore.ensureMigrated("__GENERAL_CHATS__"), nil, "special path skipped")
end)

TestRunner:test("readChats folds legacy chats in when the chats file is missing", function()
    -- the bulk pass never reached this book (not a candidate / unreadable /
    -- a failed run): the first chats read must not answer "no chats"
    bookFile(BOOK)
    local raw = MockDS:open(BOOK)
    raw.data.koassistant_chats = { c1 = { id = "c1" } }
    local chats = BookStore.readChats(BOOK)
    eq(chats.c1 and chats.c1.id, "c1", "answered from metadata.lua on the first read")
    eq(raw.data.koassistant_chats, nil, "moved out of metadata.lua")
    eq(ds_flushes[BOOK], 1, "one KOReader flush")
    eq(BookStore.readChats(BOOK).c1.id, "c1", "chats file written")
    eq(ds_flushes[BOOK], 1, "second read touches nothing")
end)

TestRunner:test("a failed straggler migration is retried on the next access", function()
    bookFile(BOOK)
    local raw = MockDS:open(BOOK)
    raw.data.koassistant_book_domain = "history"
    raw.data._fail_flush = true
    eq(BookStore.ensureMigrated(BOOK, raw), "failed", "first attempt fails")
    raw.data._fail_flush = false
    raw.data.koassistant_book_domain = "history"
    eq(BookStore.ensureMigrated(BOOK, raw), "moved", "retried")
end)

-- ============================================================
print("\n  -- migrateAll --")

TestRunner:test("walks the candidates: moved / clean / skipped counted, failures listed", function()
    local a, b, c, d = "/books/a.epub", "/books/b.epub", "/books/c.epub", "/books/gone.epub"
    bookFile(a); bookFile(b); existing[c] = true  -- c: book exists, no sidecar dir
    MockDS:open(a).data.koassistant_chats = { c1 = { id = "c1" } }
    MockDS:open(a).data.koassistant_book_domain = "history"
    MockDS:open(b).data.percent_finished = 0.2
    candidates = { a, b, c, d }
    local report = BookStore.migrateAll(nil, {})
    eq(report.candidates, 4, "candidates")
    eq(report.moved, 1, "moved")
    eq(report.clean, 1, "clean")
    eq(report.skipped, 2, "skipped (no sidecar dir / missing file)")
    eq(report.failed, 0, "no failures")
    eq(report.chats, 1, "chats counted")
    eq(report.keys, 1, "keys counted")
end)

TestRunner:test("a failure is reported (caller keeps the version stamp for a retry)", function()
    bookFile(BOOK)
    local raw = MockDS:open(BOOK)
    raw.data.koassistant_book_domain = "history"
    raw.data._fail_flush = true
    candidates = { BOOK }
    local report = BookStore.migrateAll(nil, {})
    eq(report.failed, 1, "one failure")
    truthy(report.failures[1]:find(BOOK, 1, true), "failure names the book")
end)

-- ============================================================
print("\n  -- SafeDocSettings --")

TestRunner:test("resolve returns a facade for the open book and for a closed book; resolveRaw the DocSettings", function()
    bookFile(BOOK)
    local live = MockDS:open(BOOK)
    local ui = { document = { file = BOOK }, doc_settings = live }
    local f, is_live = SafeDocSettings.resolve(BOOK, ui)
    truthy(BookStore.isFacade(f), "facade")
    eq(is_live, true, "live")
    eq(BookStore.unwrap(f), live, "over the live instance")
    local f2 = SafeDocSettings.resolve(nil, ui)
    truthy(BookStore.isFacade(f2), "nil path = caller's own book, wrapped")
    local raw, raw_live = SafeDocSettings.resolveRaw(BOOK, ui)
    eq(raw, live, "resolveRaw = the DocSettings itself")
    eq(raw_live, true, "live flag")
    bookFile("/books/closed.epub")
    local f3 = SafeDocSettings.resolve("/books/closed.epub")
    truthy(BookStore.isFacade(f3), "closed book facade")
    f3:saveSetting("koassistant_book_domain", "x")
    eq(files["/books/closed.sdr/koassistant_book_settings.lua"].data.settings.koassistant_book_domain, "x",
        "closed-book write lands in its own file")
end)

-- ============================================================
print("\n  -- structural gates --")

local function listLuaFiles()
    local out = {}
    for _idx, sub in ipairs({ "", "/koassistant_api", "/koassistant_ui", "/prompts" }) do
        local h = io.popen('ls "' .. plugin_dir .. sub .. '"/*.lua 2>/dev/null')
        if h then
            for line in h:lines() do out[#out + 1] = line end
            h:close()
        end
    end
    return out
end

local function readLines(path)
    local fh = io.open(path, "r")
    if not fh then return {} end
    local lines = {}
    for line in fh:lines() do lines[#lines + 1] = line end
    fh:close()
    return lines
end

TestRunner:test("no code reads or writes the legacy koassistant_chats DocSettings key outside the store", function()
    local offenders = {}
    for _idx, path in ipairs(listLuaFiles()) do
        local name = path:match("([^/]+)$")
        if name ~= "koassistant_book_store.lua" then
            for n, line in ipairs(readLines(path)) do
                if line:find('Setting("koassistant_chats"', 1, true) then
                    offenders[#offenders + 1] = name .. ":" .. n
                end
            end
        end
    end
    eq(#offenders, 0, "legacy chats key sites: " .. table.concat(offenders, ", "))
end)

TestRunner:test("main.lua never calls ui.doc_settings directly (plugin keys go through _openBookDS)", function()
    local offenders = {}
    for n, line in ipairs(readLines(plugin_dir .. "/main.lua")) do
        if line:find("ui.doc_settings:", 1, true) then
            offenders[#offenders + 1] = "main.lua:" .. n
        end
    end
    eq(#offenders, 0, "direct DocSettings calls: " .. table.concat(offenders, ", "))
end)

TestRunner:test("no useDocSettingsStorage / v1 chat-dir routing survives", function()
    local offenders = {}
    for _idx, path in ipairs(listLuaFiles()) do
        local name = path:match("([^/]+)$")
        for n, line in ipairs(readLines(path)) do
            if line:find("useDocSettingsStorage", 1, true) or line:find("getDocumentChatDir", 1, true) then
                offenders[#offenders + 1] = name .. ":" .. n
            end
        end
    end
    eq(#offenders, 0, "v1 routing sites: " .. table.concat(offenders, ", "))
end)

-- ============================================================
-- Cleanup
-- ============================================================
for k, v in pairs({
    ["luasettings"] = saved.luasettings, ["docsettings"] = saved.docsettings,
    ["libs/libkoreader-lfs"] = saved.lfs, ["util"] = saved.util,
    ["readhistory"] = saved.readhistory,
    ["koassistant_index_rebuilder"] = saved.rebuilder,
    ["koassistant_chat_history_manager"] = saved.chm,
    ["koassistant_book_store"] = saved.store,
    ["koassistant_doc_settings"] = saved.sds,
}) do
    package.loaded[k] = v
end
package.loaded["koassistant_book_store"] = nil
package.loaded["koassistant_doc_settings"] = nil
package.loaded["koassistant_chat_history_manager"] = nil
package.loaded["koassistant_index_rebuilder"] = nil

os.remove = saved_os_remove  -- luacheck: ignore 122
print(string.format("\n  Book store tests: %d passed, %d failed", TestRunner.passed, TestRunner.failed))
return TestRunner.failed == 0
