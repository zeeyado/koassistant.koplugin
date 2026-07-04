--[[
Unit Tests for koassistant_doc_settings.lua (SafeDocSettings)

The issue #72 stopgap: every plugin read/write of a book's DocSettings must
resolve to the LIVE ReaderUI doc_settings whenever the target book is currently
open — a fresh DocSettings:open() of an open book creates a divergent second
in-memory copy of metadata.lua whose flush clobbers KOReader's annotations and
reading progress. Covers:
- samePath: string equality, realpath alias resolution (Android /sdcard etc.),
  nil handling, missing-realpath fallback
- resolve: caller's ui preferred; ReaderUI.instance fallback (nil ui,
  FileManager ui, alias path); fresh instance only when the book is not open;
  nil document_path semantics

Run: lua tests/run_tests.lua --unit
]]

package.path = package.path .. ";./?.lua;./?/init.lua"
require("tests.lib.mock_koreader")

-- Controllable stubs -------------------------------------------------------

-- realpath alias table: path -> canonical
local realpath_map = {}
package.loaded["ffi/util"].realpath = function(path)
    return realpath_map[path]
end

-- Fake fresh DocSettings instances (tagged so tests can tell them apart)
local fresh_opened = {}
package.loaded["docsettings"] = {
    open = function(_self, path)
        local inst = { fresh = true, path = path }
        table.insert(fresh_opened, inst)
        return inst
    end,
}

-- ReaderUI singleton stub
local ReaderUIStub = { instance = nil }
package.loaded["apps/reader/readerui"] = ReaderUIStub

local SafeDocSettings = require("koassistant_doc_settings")

local function makeUI(file)
    return {
        document = { file = file },
        doc_settings = { live = true, file = file },
    }
end

local T = {
    passed = 0,
    failed = 0,
}

function T:test(name, fn)
    -- Reset shared stub state before each test
    realpath_map = {}
    fresh_opened = {}
    ReaderUIStub.instance = nil
    local ok, err = pcall(fn)
    if ok then
        self.passed = self.passed + 1
        print(string.format("  ✓ %s", name))
    else
        self.failed = self.failed + 1
        print(string.format("  ✗ %s: %s", name, tostring(err)))
    end
end

function T:assert(condition, message)
    if not condition then error(message or "Assertion failed", 2) end
end

function T:assertEquals(actual, expected, message)
    if actual ~= expected then
        error(string.format("%s: expected %s, got %s",
            message or "Values not equal", tostring(expected), tostring(actual)), 2)
    end
end

function T:runAll()
    print("\nSafeDocSettings (issue #72 live-instance resolver)")

    -- ---- samePath ----
    self:test("samePath: identical strings match without realpath", function()
        self:assert(SafeDocSettings.samePath("/books/a.epub", "/books/a.epub"))
    end)

    self:test("samePath: nil on either side is false", function()
        self:assert(not SafeDocSettings.samePath(nil, "/books/a.epub"))
        self:assert(not SafeDocSettings.samePath("/books/a.epub", nil))
        self:assert(not SafeDocSettings.samePath(nil, nil))
    end)

    self:test("samePath: aliases resolve equal via realpath", function()
        realpath_map["/sdcard/books/a.epub"] = "/storage/emulated/0/books/a.epub"
        realpath_map["/storage/emulated/0/books/a.epub"] = "/storage/emulated/0/books/a.epub"
        self:assert(SafeDocSettings.samePath(
            "/sdcard/books/a.epub", "/storage/emulated/0/books/a.epub"))
    end)

    self:test("samePath: different files stay different", function()
        realpath_map["/books/a.epub"] = "/books/a.epub"
        realpath_map["/books/b.epub"] = "/books/b.epub"
        self:assert(not SafeDocSettings.samePath("/books/a.epub", "/books/b.epub"))
    end)

    self:test("samePath: unresolvable realpath (nil) is false, not a crash", function()
        self:assert(not SafeDocSettings.samePath("/gone/a.epub", "/gone/b.epub"))
    end)

    -- ---- resolve: caller's ui ----
    self:test("resolve: caller's ui wins when its open book matches exactly", function()
        local ui = makeUI("/books/a.epub")
        local ds, is_live = SafeDocSettings.resolve("/books/a.epub", ui)
        self:assertEquals(ds, ui.doc_settings, "must return the live instance")
        self:assert(is_live, "must report live")
        self:assertEquals(#fresh_opened, 0, "must not open a fresh instance")
    end)

    self:test("resolve: caller's ui wins on alias path (realpath match)", function()
        local ui = makeUI("/storage/emulated/0/books/a.epub")
        realpath_map["/sdcard/books/a.epub"] = "/canon/a.epub"
        realpath_map["/storage/emulated/0/books/a.epub"] = "/canon/a.epub"
        local ds, is_live = SafeDocSettings.resolve("/sdcard/books/a.epub", ui)
        self:assertEquals(ds, ui.doc_settings, "alias must still resolve to live instance")
        self:assert(is_live, "must report live")
    end)

    -- ---- resolve: ReaderUI.instance fallback ----
    self:test("resolve: nil ui falls back to ReaderUI.instance for the open book", function()
        ReaderUIStub.instance = makeUI("/books/a.epub")
        local ds, is_live = SafeDocSettings.resolve("/books/a.epub", nil)
        self:assertEquals(ds, ReaderUIStub.instance.doc_settings,
            "must return the global live instance")
        self:assert(is_live, "must report live")
        self:assertEquals(#fresh_opened, 0, "must not open a fresh instance")
    end)

    self:test("resolve: FileManager-like ui (no document) falls back to ReaderUI.instance", function()
        ReaderUIStub.instance = makeUI("/books/a.epub")
        local filemanager_ui = { doc_settings = nil, document = nil }
        local ds, is_live = SafeDocSettings.resolve("/books/a.epub", filemanager_ui)
        self:assertEquals(ds, ReaderUIStub.instance.doc_settings,
            "dual-instance case must still find the live reader")
        self:assert(is_live, "must report live")
    end)

    self:test("resolve: ReaderUI.instance matches via alias path", function()
        ReaderUIStub.instance = makeUI("/storage/emulated/0/books/a.epub")
        realpath_map["/sdcard/books/a.epub"] = "/canon/a.epub"
        realpath_map["/storage/emulated/0/books/a.epub"] = "/canon/a.epub"
        local ds, is_live = SafeDocSettings.resolve("/sdcard/books/a.epub", nil)
        self:assertEquals(ds, ReaderUIStub.instance.doc_settings,
            "alias path must resolve to the live instance")
        self:assert(is_live, "must report live")
    end)

    -- ---- resolve: fresh instance only when not open ----
    self:test("resolve: different open book yields a fresh instance", function()
        ReaderUIStub.instance = makeUI("/books/other.epub")
        realpath_map["/books/other.epub"] = "/books/other.epub"
        realpath_map["/books/a.epub"] = "/books/a.epub"
        local ds, is_live = SafeDocSettings.resolve("/books/a.epub", nil)
        self:assert(ds and ds.fresh, "must open a fresh instance")
        self:assertEquals(ds.path, "/books/a.epub")
        self:assert(not is_live, "must report not live")
    end)

    self:test("resolve: nothing open yields a fresh instance", function()
        local ds, is_live = SafeDocSettings.resolve("/books/a.epub", nil)
        self:assert(ds and ds.fresh, "must open a fresh instance")
        self:assert(not is_live, "must report not live")
    end)

    -- ---- resolve: nil document_path ----
    self:test("resolve: nil path returns caller ui's own book", function()
        local ui = makeUI("/books/a.epub")
        local ds, is_live = SafeDocSettings.resolve(nil, ui)
        self:assertEquals(ds, ui.doc_settings)
        self:assert(is_live, "must report live")
    end)

    self:test("resolve: nil path and no open book returns nil", function()
        local ds, is_live = SafeDocSettings.resolve(nil, nil)
        self:assertEquals(ds, nil)
        self:assert(not is_live, "must report not live")
    end)

    print(string.format("\nResults: %d passed, %d failed\n", self.passed, self.failed))
    return self.failed == 0
end

-- Run directly
if arg and arg[0] and arg[0]:match("test_doc_settings_resolver%.lua$") then
    local success = T:runAll()
    os.exit(success and 0 or 1)
end

return T
