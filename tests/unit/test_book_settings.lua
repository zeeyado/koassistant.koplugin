-- Unit tests for koassistant_book_settings.lua
-- Tests the pure per-book AI title/author override helpers (no UI, no API).

local function setupPaths()
    local info = debug.getinfo(1, "S")
    local script_path = info.source:match("@?(.*)")
    local unit_dir = script_path:match("(.+)/[^/]+$") or "."
    local tests_dir = unit_dir:match("(.+)/[^/]+$") or "."
    local plugin_dir = tests_dir:match("(.+)/[^/]+$") or "."

    package.path = table.concat({
        plugin_dir .. "/?.lua",
        tests_dir .. "/?.lua",
        tests_dir .. "/lib/?.lua",
        package.path,
    }, ";")
end
setupPaths()

require("mock_koreader")
-- Stub UI widgets the module requires at load time (not exercised by these tests)
package.loaded["ui/widget/buttondialog"] = package.loaded["ui/widget/buttondialog"] or {}

local BookSettings = require("koassistant_book_settings")
local MessageBuilder = require("message_builder")

-- Simple test framework (matches the other unit tests)
local TestRunner = { passed = 0, failed = 0 }
function TestRunner:suite(name) print(string.format("\n  [%s]", name)) end
function TestRunner:test(name, fn)
    local ok, err = pcall(fn)
    if ok then
        self.passed = self.passed + 1
        print(string.format("    ✓ %s", name))
    else
        self.failed = self.failed + 1
        print(string.format("    ✗ %s", name))
        print(string.format("      Error: %s", tostring(err)))
    end
end
function TestRunner:assertEqual(actual, expected, msg)
    if actual ~= expected then
        error(string.format("%s: expected %q, got %q", msg or "assertEqual",
            tostring(expected), tostring(actual)))
    end
end
function TestRunner:assertNil(value, msg)
    if value ~= nil then
        error(string.format("%s: expected nil, got %q", msg or "assertNil", tostring(value)))
    end
end
function TestRunner:assertContains(str, needle, msg)
    if not str or not str:find(needle, 1, true) then
        error(string.format("%s: expected to contain %q", msg or "assertContains", tostring(needle)))
    end
end
function TestRunner:assertNotContains(str, needle, msg)
    if str and str:find(needle, 1, true) then
        error(string.format("%s: expected NOT to contain %q", msg or "assertNotContains", tostring(needle)))
    end
end

-- Mock DocSettings: only readSetting is exercised
local function makeDocSettings(map)
    return { readSetting = function(_self, k) return map[k] end }
end
local KT = BookSettings.KEY_AI_TITLE
local KA = BookSettings.KEY_AI_AUTHOR

TestRunner:suite("getMetadataOverride")

TestRunner:test("nil doc_settings → nil, nil", function()
    local t, a = BookSettings.getMetadataOverride(nil)
    TestRunner:assertNil(t); TestRunner:assertNil(a)
end)

TestRunner:test("empty string = send-empty override (NOT unset)", function()
    local t, a = BookSettings.getMetadataOverride(makeDocSettings({ [KT] = "", [KA] = "" }))
    TestRunner:assertEqual(t, ""); TestRunner:assertEqual(a, "")
end)

TestRunner:test("returns set values", function()
    local t, a = BookSettings.getMetadataOverride(makeDocSettings({ [KT] = "IJ", [KA] = "DFW" }))
    TestRunner:assertEqual(t, "IJ"); TestRunner:assertEqual(a, "DFW")
end)

TestRunner:suite("applyMetadataOverride")

TestRunner:test("no override → returns the SAME table unchanged", function()
    local meta = { title = "Real", author = "Auth", author_clause = " by Auth" }
    local out = BookSettings.applyMetadataOverride(meta, makeDocSettings({}))
    TestRunner:assertEqual(out, meta, "should be identity when no override")
end)

TestRunner:test("nil doc_settings → input unchanged", function()
    local meta = { title = "Real" }
    TestRunner:assertEqual(BookSettings.applyMetadataOverride(meta, nil), meta)
end)

TestRunner:test("title override → new table, title replaced, author kept", function()
    local meta = { title = "Real", author = "Auth", author_clause = " by Auth", file = "/x.epub" }
    local out = BookSettings.applyMetadataOverride(meta, makeDocSettings({ [KT] = "Override" }))
    TestRunner:assertEqual(out.title, "Override")
    TestRunner:assertEqual(out.author, "Auth")
    TestRunner:assertEqual(out.author_clause, " by Auth")
    TestRunner:assertEqual(out.file, "/x.epub", "other fields copied")
    -- input not mutated
    TestRunner:assertEqual(meta.title, "Real", "input must not be mutated")
end)

TestRunner:test("author override → author + author_clause rebuilt", function()
    local meta = { title = "Real", author = "Auth", author_clause = " by Auth" }
    local out = BookSettings.applyMetadataOverride(meta, makeDocSettings({ [KA] = "New Author" }))
    TestRunner:assertEqual(out.title, "Real")
    TestRunner:assertEqual(out.author, "New Author")
    TestRunner:assertEqual(out.author_clause, " by New Author")
end)

TestRunner:test("both overrides applied", function()
    local out = BookSettings.applyMetadataOverride(
        { title = "Real", author = "Auth" },
        makeDocSettings({ [KT] = "T2", [KA] = "A2" }))
    TestRunner:assertEqual(out.title, "T2")
    TestRunner:assertEqual(out.author, "A2")
    TestRunner:assertEqual(out.author_clause, " by A2")
end)

TestRunner:test("nil metadata + override → fresh table", function()
    local out = BookSettings.applyMetadataOverride(nil, makeDocSettings({ [KT] = "Only" }))
    TestRunner:assertEqual(out.title, "Only")
end)

TestRunner:test("empty-string override → field emptied, author_clause cleared", function()
    local out = BookSettings.applyMetadataOverride(
        { title = "Real", author = "Auth", author_clause = " by Auth" },
        makeDocSettings({ [KA] = "" }))  -- author = send empty; title untouched
    TestRunner:assertEqual(out.author, "")
    TestRunner:assertEqual(out.author_clause, "")
    TestRunner:assertEqual(out.title, "Real", "nil title override leaves title")
end)

-- End-to-end: the override must actually reach the prompt the AI sees, and the
-- real title/author must be suppressed when overridden.
TestRunner:suite("integration: override reaches the prompt, original suppressed")

local REAL = { title = "Real Title", author = "Real Author", author_clause = " by Real Author" }
local function buildBookPrompt(meta)
    return MessageBuilder.build({
        prompt = { prompt = 'Discuss "{title}"{author_clause}.' },
        context = "book",
        data = { book_metadata = meta },
    })
end

TestRunner:test("book context: fake title+author sent; original NOT sent", function()
    local meta = BookSettings.applyMetadataOverride(REAL, makeDocSettings({ [KT] = "Fake Title", [KA] = "Fake Author" }))
    local result = buildBookPrompt(meta)
    TestRunner:assertContains(result, "Fake Title", "fake title in prompt")
    TestRunner:assertContains(result, "Fake Author", "fake author in prompt")
    TestRunner:assertNotContains(result, "Real Title", "original title suppressed")
    TestRunner:assertNotContains(result, "Real Author", "original author suppressed")
end)

TestRunner:test("no override → real metadata reaches the prompt", function()
    local meta = BookSettings.applyMetadataOverride(REAL, makeDocSettings({}))
    local result = buildBookPrompt(meta)
    TestRunner:assertContains(result, "Real Title")
    TestRunner:assertContains(result, "Real Author")
end)

TestRunner:test("title-only override: fake title, real author retained", function()
    local meta = BookSettings.applyMetadataOverride(REAL, makeDocSettings({ [KT] = "Fake Title" }))
    local result = buildBookPrompt(meta)
    TestRunner:assertContains(result, "Fake Title")
    TestRunner:assertContains(result, "Real Author")
    TestRunner:assertNotContains(result, "Real Title")
end)

TestRunner:test("send-empty author: real title kept, author fully suppressed", function()
    local meta = BookSettings.applyMetadataOverride(REAL, makeDocSettings({ [KA] = "" }))
    local result = buildBookPrompt(meta)
    TestRunner:assertContains(result, "Real Title")
    TestRunner:assertNotContains(result, "Real Author")
    TestRunner:assertNotContains(result, " by ", "no author clause when author is empty")
end)

print("")
print(string.rep("-", 50))
print(string.format("  Results: %d passed, %d failed", TestRunner.passed, TestRunner.failed))
print(string.rep("-", 50))

return TestRunner.failed == 0
