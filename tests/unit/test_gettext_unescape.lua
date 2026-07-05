--[[
Unit tests: koassistant_gettext PO parser msgid/msgstr unescaping

Guards audit v0.20.0 finding (gettext msgid unescape): parsePOFile used to unescape only
the msgstr (value), leaving the msgid (key) in its raw escaped form. At runtime _() passes
the REAL Lua string (e.g. an actual newline from "Supported models:\n"), so any translation
whose msgid contained \n or \" could never match and silently fell back to English. The fix
unescapes BOTH sides via a single left-to-right pass (so an escaped backslash \\ can't
re-trigger on the following char).

Run: lua tests/unit/test_gettext_unescape.lua  (auto-discovered by run_tests.lua --unit)
]]

-- Setup test environment
local function setupPaths()
    local info = debug.getinfo(1, "S")
    local script_path = info.source:match("@?(.*)")
    local unit_dir = script_path:match("(.+)/[^/]+$") or "."
    local tests_dir = unit_dir:match("(.+)/[^/]+$") or "."
    local plugin_dir = tests_dir:match("(.+)/[^/]+$") or "."

    package.path = table.concat({
        plugin_dir .. "/?.lua",
        plugin_dir .. "/?/init.lua",
        tests_dir .. "/?.lua",
        tests_dir .. "/lib/?.lua",
        package.path,
    }, ";")
end
setupPaths()

-- Reset module cache before requiring (matters under run_tests.lua)
package.loaded["koassistant_gettext"] = nil
local Gettext = require("koassistant_gettext")
local TestRunner = require("test_runner"):new()

-- Write a temp .po whose msgids exercise the escape cases, then parse it off disk.
-- The file bytes must contain literal backslashes, so Lua "\\" writes one backslash.
local TMP_PO = "/tmp/koassistant_gettext_test_" .. tostring(os.time()) .. "_" .. tostring(math.random(10000)) .. ".po"
local PO_LINES = {
    'msgid ""',
    'msgstr ""',
    '"Content-Type: text/plain; charset=UTF-8\\n"',
    '',
    'msgid "Supported models:\\n"',       -- file: Supported models:\n  (backslash + n)
    'msgstr "Modelos compatibles:\\n"',
    '',
    'msgid "Search: \\"%1\\""',            -- file: Search: \"%1\"  (escaped quotes)
    'msgstr "Buscar: \\"%1\\""',
    '',
    'msgid "a\\\\b"',                      -- file: a\\b  (escaped backslash)
    'msgstr "x\\\\y"',
    '',
    'msgid "a\\\\nb"',                     -- file: a\\nb  (escaped backslash THEN n)
    'msgstr "ordering-case"',
    '',
    'msgid "plain string"',
    'msgstr "cadena simple"',
    '',
    'msgid "First line\\n"',               -- multi-line msgid via continuation
    '"Second line"',
    'msgstr "Primera\\n"',
    '"Segunda"',
    '',
}
do
    local f = assert(io.open(TMP_PO, "w"))
    f:write(table.concat(PO_LINES, "\n"))
    f:close()
end

local po = Gettext.parsePOFile(TMP_PO)

print("Running: test_gettext_unescape")
print("")
print("  [PO msgid/msgstr unescaping]")

TestRunner:test("msgid containing \\n is keyed by a REAL newline (the core bug)", function()
    assert(po, "parsePOFile should return a table")
    -- What _() passes at runtime: a string with a real newline.
    TestRunner:assertEqual(po["Supported models:\n"], "Modelos compatibles:\n",
        "real-newline key must resolve; msgstr newline unescaped too")
    -- The old buggy key (raw, still-escaped) must NOT exist anymore.
    TestRunner:assertEqual(po["Supported models:\\n"], nil,
        "raw escaped key must be gone (proves the msgid is unescaped)")
end)

TestRunner:test("msgid containing \\\" is keyed by a REAL quote", function()
    TestRunner:assertEqual(po['Search: "%1"'], 'Buscar: "%1"', "real-quote key must resolve")
end)

TestRunner:test("escaped backslash \\\\ decodes to a single backslash", function()
    TestRunner:assertEqual(po["a\\b"], "x\\y", "\\\\ -> \\ on both sides")
end)

TestRunner:test("escaped backslash before n stays backslash+n (ordering, not a newline)", function()
    -- "a\\nb" in the file is backslash+backslash+n+b -> a + backslash + n + b (4 chars),
    -- NOT a + backslash + newline + b. The old sequential-gsub order got this wrong.
    TestRunner:assertEqual(po["a\\nb"], "ordering-case", "backslash+n key, not backslash+newline")
    TestRunner:assertEqual(po["a\\\nb"], nil, "must NOT be keyed by backslash+newline")
end)

TestRunner:test("plain msgid without escapes still resolves", function()
    TestRunner:assertEqual(po["plain string"], "cadena simple", "plain passthrough")
end)

TestRunner:test("multi-line continuation msgid concatenates then unescapes", function()
    TestRunner:assertEqual(po["First line\nSecond line"], "Primera\nSegunda",
        "continuation lines joined, escapes decoded after concatenation")
end)

-- Cleanup
os.remove(TMP_PO)

local ok = TestRunner:summary()
return ok
