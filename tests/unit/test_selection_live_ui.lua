-- Unit tests: a word selected in a plugin window reaches the dictionary of the
-- reader or file browser on screen now (B341). A window keeps the UI it was
-- opened with, which can close under it: an artifact window opened from the
-- file browser rows held a closed FileManager, whose dictionary wrapper never
-- saw the bypass turned on, and 8 of the 14 artifact windows carry no UI.

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

local ChatGPTViewer = require("koassistant_chatgptviewer")

local TestRunner = { passed = 0, failed = 0 }
function TestRunner:test(name, fn)
    local ok, err = pcall(fn)
    if ok then self.passed = self.passed + 1; print("    ✓ " .. name)
    else self.failed = self.failed + 1; print("    ✗ " .. name); print("      Error: " .. tostring(err)) end
end
function TestRunner:eq(a, b, msg)
    if a ~= b then error(string.format("%s: expected %s, got %s", msg or "eq", tostring(b), tostring(a)), 2) end
end

-- The live-UI modules, restored at the end (one process runs every file)
local saved_reader = package.loaded["apps/reader/readerui"]
local saved_fm = package.loaded["apps/filemanager/filemanager"]
local ReaderUIMock, FileManagerMock = {}, {}
package.loaded["apps/reader/readerui"] = ReaderUIMock
package.loaded["apps/filemanager/filemanager"] = FileManagerMock

local function newUI(name)
    local looked = {}
    return {
        name = name,
        looked = looked,
        dictionary = {
            onLookupWord = function(dict_self, word)
                looked[#looked + 1] = { word = word, book = dict_self._koassistant_lookup_book }
            end,
        },
    }
end

local function newViewer(fields)
    return setmetatable(fields, { __index = ChatGPTViewer })
end

print("")
print(string.rep("=", 50))
print("  Unit Tests: selections reach the live UI (B341)")
print(string.rep("=", 50))

TestRunner:test("liveUI: the reader on screen, else the file browser, else the window's own", function()
    local reader, fm, own = newUI("reader"), newUI("fm"), newUI("own")
    ReaderUIMock.instance, FileManagerMock.instance = reader, fm
    TestRunner:eq(ChatGPTViewer.liveUI(own), reader)
    ReaderUIMock.instance = nil
    TestRunner:eq(ChatGPTViewer.liveUI(own), fm)
    FileManagerMock.instance = nil
    TestRunner:eq(ChatGPTViewer.liveUI(own), own, "nothing on screen: the window's own")
    TestRunner:eq(ChatGPTViewer.liveUI(nil), nil)
end)

TestRunner:test("a window with no UI looks a word up in the file browser on screen", function()
    local fm = newUI("fm")
    ReaderUIMock.instance, FileManagerMock.instance = nil, fm
    local v = newViewer({ configuration = { document_path = "/books/about.epub" } })
    v:handleTextSelection("incommensurability", nil)
    TestRunner:eq(#fm.looked, 1, "the dictionary got the word")
    TestRunner:eq(fm.looked[1].word, "incommensurability")
    TestRunner:eq(fm.looked[1].book, "/books/about.epub", "the window's book rides with the lookup")
end)

TestRunner:test("a window holding a closed file browser uses the live one", function()
    local dead, live = newUI("dead"), newUI("live")
    ReaderUIMock.instance, FileManagerMock.instance = nil, live
    local v = newViewer({ _ui = dead, configuration = {} })
    v:handleTextSelection("method", nil)
    TestRunner:eq(#dead.looked, 0, "the closed file browser's dictionary is never used")
    TestRunner:eq(#live.looked, 1)
end)

package.loaded["apps/reader/readerui"] = saved_reader
package.loaded["apps/filemanager/filemanager"] = saved_fm

print("")
print(string.rep("-", 50))
print(string.format("  Results: %d passed, %d failed", TestRunner.passed, TestRunner.failed))
print(string.rep("-", 50))
return TestRunner.failed == 0
