-- Multi-key resolution tests (2026-08-15): BaseHandler.listApiKeys / getApiKey /
-- keyFingerprint over every store shape — legacy single string, array of strings,
-- array of { key, alias } tables, mixed — plus placeholder filtering, GUI-before-file
-- order, fingerprint selection and the stale-selection fallback.
--
-- Run: lua tests/run_tests.lua --unit  (or directly: lua tests/unit/test_api_keys.lua)

local function setupPaths()
    local info = debug.getinfo(1, "S")
    local script_path = info.source:match("@?(.*)")
    local unit_dir = script_path:match("(.+)/[^/]+$") or "."
    local tests_dir = unit_dir:match("(.+)/[^/]+$") or "."
    local plugin_dir = tests_dir:match("(.+)/[^/]+$") or "."

    package.path = table.concat({
        plugin_dir .. "/?.lua",
        plugin_dir .. "/koassistant_api/?.lua",
        tests_dir .. "/?.lua",
        tests_dir .. "/lib/?.lua",
        package.path,
    }, ";")
end

setupPaths()
require("mock_koreader")

local TestRunner = { passed = 0, failed = 0 }

function TestRunner.assert(condition, message)
    if condition then
        TestRunner.passed = TestRunner.passed + 1
    else
        TestRunner.failed = TestRunner.failed + 1
        print("  FAIL: " .. message)
    end
end

local Base = require("koassistant_api.base")

-- Control the apikeys.lua the module under test sees. package.loaded is the seam:
-- listApiKeys does require("apikeys") per call, so preloading a table serves it.
local function setFileKeys(tbl)
    package.loaded["apikeys"] = tbl
end

-- Minimal settings stub: only readSetting("features") is consulted.
local function settingsWith(features)
    return { readSetting = function(_self, k)
        if k == "features" then return features end
    end }
end

print("=== Testing multi-key API key resolution ===")

-- Legacy shapes unchanged ------------------------------------------------------
setFileKeys({ gemini = "  file-key-1234567890  " })
TestRunner.assert(Base.getApiKey("gemini", nil) == "file-key-1234567890",
    "single file string resolves, trimmed")

setFileKeys({ gemini = "YOUR_GEMINI_API_KEY" })
TestRunner.assert(Base.getApiKey("gemini", nil) == nil,
    "placeholder file key filtered")

setFileKeys({ gemini = "file-key-1234567890" })
local s = settingsWith({ api_keys = { gemini = "gui-key-abcdefghij" } })
TestRunner.assert(Base.getApiKey("gemini", s) == "gui-key-abcdefghij",
    "legacy GUI string beats file key (pre-multi-key behavior)")

-- Multi shapes -----------------------------------------------------------------
setFileKeys({ gemini = {
    "file-key-A-1234567890",
    { key = "file-key-B-1234567890", alias = "paid" },
    "YOUR_GEMINI_API_KEY",          -- placeholder entry dropped
    { key = 42 },                   -- junk entry dropped
} })
local list = Base.listApiKeys("gemini", nil)
TestRunner.assert(#list == 2, "file array: placeholders and junk filtered (got " .. #list .. ")")
TestRunner.assert(list[1].key == "file-key-A-1234567890" and list[1].source == "file",
    "file order preserved, provenance stamped")
TestRunner.assert(list[2].alias == "paid", "file entry alias carried")

local s2 = settingsWith({ api_keys = { gemini = {
    { key = "gui-key-1-abcdefghij", alias = "personal" },
    "gui-key-2-abcdefghij",
} } })
local merged = Base.listApiKeys("gemini", s2)
TestRunner.assert(#merged == 4, "GUI list + file list merged (got " .. #merged .. ")")
TestRunner.assert(merged[1].key == "gui-key-1-abcdefghij" and merged[1].source == "gui",
    "GUI entries come first")
TestRunner.assert(Base.getApiKey("gemini", s2) == "gui-key-1-abcdefghij",
    "no selection: first GUI entry wins")

-- Selection --------------------------------------------------------------------
local fp_fileB = Base.keyFingerprint("file-key-B-1234567890")
local s3 = settingsWith({
    api_keys = { gemini = { { key = "gui-key-1-abcdefghij" } } },
    api_key_selected = { gemini = fp_fileB },
})
TestRunner.assert(Base.getApiKey("gemini", s3) == "file-key-B-1234567890",
    "selection fingerprint picks a FILE key over the GUI default")

local s4 = settingsWith({
    api_keys = { gemini = { { key = "gui-key-1-abcdefghij" } } },
    api_key_selected = { gemini = "gon...e:20:12345" },  -- stale: no such key anymore
})
TestRunner.assert(Base.getApiKey("gemini", s4) == "gui-key-1-abcdefghij",
    "stale selection falls back to default order")

-- Fingerprint ------------------------------------------------------------------
local fp = Base.keyFingerprint("abcdefghijkl")
TestRunner.assert(fp:match("^abc%.%.%.ijkl:12:%d+$") ~= nil,
    "fingerprint = first3...last4:len:hash (got " .. fp .. ")")
TestRunner.assert(Base.keyFingerprint("short"):match("^%*%*%*%*%*:5:%d+$") ~= nil,
    "short keys fully masked")
TestRunner.assert(Base.keyFingerprint("") == "" and Base.keyFingerprint(nil) == "",
    "empty/nil fingerprint is empty")
TestRunner.assert(Base.keyFingerprint("abcdefghijkl") ~= Base.keyFingerprint("abcdefghijk"),
    "length is part of the fingerprint")
-- Same mask, same length, different middles — the realistic same-provider case
-- (every Google key starts "AIza" at 39 chars); the hash must separate them.
TestRunner.assert(
    Base.keyFingerprint("file-key-A-1234567890") ~= Base.keyFingerprint("file-key-B-1234567890"),
    "hash separates same-mask same-length keys")

-- Sanitizing (Kindle GUI paste, discussion #54) --------------------------------
-- A key copied out of a text file opened in KOReader wraps, so the line break
-- lands INSIDE the key. The old end-trim could not reach it.
TestRunner.assert(Base.sanitizeKey("AIzaSyAbCd\nEfGhIjKlMnOp1234567") == "AIzaSyAbCdEfGhIjKlMnOp1234567",
    "interior newline stripped")
TestRunner.assert(Base.sanitizeKey(" sk-ant-\194\160api03-abcdefghij \t") == "sk-ant-api03-abcdefghij",
    "NBSP and surrounding ASCII whitespace stripped")
TestRunner.assert(Base.sanitizeKey("sk-\226\128\139or-v1-abcdefghij\239\187\191") == "sk-or-v1-abcdefghij",
    "zero-width space and BOM stripped")
TestRunner.assert(Base.sanitizeKey("sk-Ab_9.xyz-QRS=~") == "sk-Ab_9.xyz-QRS=~",
    "every printable ASCII character a key may use survives untouched")
TestRunner.assert(Base.sanitizeKey(nil) == "" and Base.sanitizeKey(42) == "",
    "non-strings sanitize to empty")

-- Sanitizing happens on READ, so a key already SAVED with junk in it heals
-- without a migration, and its fingerprint matches the cleaned form.
setFileKeys(nil)
local s5 = settingsWith({ api_keys = { gemini = { { key = "AIzaSy-dirty\n-1234567890" } } } })
TestRunner.assert(Base.getApiKey("gemini", s5) == "AIzaSy-dirty-1234567890",
    "already-stored dirty key heals on resolution")
local s6 = settingsWith({
    api_keys = { gemini = { { key = "AIzaSy-dirty\n-1234567890" } },
                 openai = "sk-plain-1234567890" },
    api_key_selected = { gemini = Base.keyFingerprint("AIzaSy-dirty-1234567890") },
})
TestRunner.assert(Base.getApiKey("gemini", s6) == "AIzaSy-dirty-1234567890",
    "selection fingerprint is computed over the SANITIZED key")

-- Cleanup: leave no fake apikeys module for later test files in the same run
package.loaded["apikeys"] = nil

print(string.format("\n  Results: %d passed, %d failed", TestRunner.passed, TestRunner.failed))
return TestRunner.failed == 0
