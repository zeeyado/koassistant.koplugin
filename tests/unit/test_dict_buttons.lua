--[[
Unit Tests for koassistant_dict_buttons.lua

Covers the dependency-free decision logic shared by both dictionary-popup
button adapters in main.lua (new addToDictButtons API + legacy onDictButtonsReady):
- spec id formatting & ordering (zero-padded so KOReader's orderedPairs keeps order)
- row-group assignment (rows of 3)
- our-key detection for stale clearing
- visibility gating (wiki / empty word / requires_open_book / requires_xray_cache)
- non-reader-lookup flag consumption (idempotent)
- row splitting

main.lua itself can't be loaded under the harness (pulls in KOReader UI modules),
so the bug-prone logic lives in this pure module and is exercised here.

Run: lua tests/run_tests.lua --unit
]]

package.path = package.path .. ";./?.lua;./?/init.lua"
require("tests.lib.mock_koreader")

local DictButtons = require("koassistant_dict_buttons")

local T = {
    passed = 0,
    failed = 0,
}

function T:test(name, fn)
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
    print("\nDictButtons (dictionary popup helpers)")

    -- ---- specId / ordering ----
    self:test("specId is zero-padded and embeds the action id", function()
        self:assertEquals(DictButtons.specId(1, "dictionary"), "koassistant_dict_01_dictionary")
        self:assertEquals(DictButtons.specId(12, "xray_lookup"), "koassistant_dict_12_xray_lookup")
    end)

    self:test("specId order survives alphabetical (orderedPairs) sorting", function()
        -- KOReader iterates _dict_buttons with byte-lexicographic orderedPairs.
        -- Build ids for 12 actions, sort as strings, expect 1..12 order preserved.
        local ids = {}
        for i = 1, 12 do ids[i] = DictButtons.specId(i, "act" .. i) end
        local sorted = {}
        for i = 1, #ids do sorted[i] = ids[i] end
        table.sort(sorted)  -- string sort, mimicking orderedPairs
        for i = 1, 12 do
            self:assertEquals(sorted[i], ids[i], "position " .. i .. " must keep insertion order")
        end
    end)

    -- ---- rowGroup (rows of 3) ----
    self:test("rowGroup buckets indices into rows of 3", function()
        self:assertEquals(DictButtons.rowGroup(1), "koassistant_dict_row1")
        self:assertEquals(DictButtons.rowGroup(3), "koassistant_dict_row1")
        self:assertEquals(DictButtons.rowGroup(4), "koassistant_dict_row2")
        self:assertEquals(DictButtons.rowGroup(6), "koassistant_dict_row2")
        self:assertEquals(DictButtons.rowGroup(7), "koassistant_dict_row3")
    end)

    -- ---- label ----
    self:test("label appends (KOA) suffix", function()
        self:assertEquals(DictButtons.label("AI Dictionary"), "AI Dictionary (KOA)")
    end)

    -- ---- scaffold ----
    self:test("scaffold returns conditional, bold, correctly-keyed spec", function()
        local spec = DictButtons.scaffold({ id = "ai_wiki" }, 4, "AI Wiki")
        self:assertEquals(spec.id, "koassistant_dict_04_ai_wiki")
        self:assertEquals(spec.text, "AI Wiki (KOA)")
        self:assertEquals(spec.font_bold, true)
        self:assertEquals(spec.conditional, true)
        self:assertEquals(spec.row_group, "koassistant_dict_row2")
    end)

    -- ---- ourKeys (stale clearing) ----
    self:test("ourKeys returns only koassistant_dict_ keys, leaves foreign", function()
        local dict_buttons = {
            koassistant_dict_01_dictionary = {},
            koassistant_dict_02_xray_lookup = {},
            prev_dict = {},                 -- built-in KOReader button
            wikipedia = {},                 -- another plugin / built-in
        }
        local keys = DictButtons.ourKeys(dict_buttons)
        table.sort(keys)
        self:assertEquals(#keys, 2)
        self:assertEquals(keys[1], "koassistant_dict_01_dictionary")
        self:assertEquals(keys[2], "koassistant_dict_02_xray_lookup")
    end)

    self:test("ourKeys on nil/empty returns empty list", function()
        self:assertEquals(#DictButtons.ourKeys(nil), 0)
        self:assertEquals(#DictButtons.ourKeys({}), 0)
    end)

    -- ---- shouldShow gating ----
    local function popup(opts)
        opts = opts or {}
        return { is_wiki = opts.is_wiki, word = opts.word == nil and "hello" or opts.word }
    end

    self:test("shouldShow: normal action on a normal popup -> true", function()
        self:assert(DictButtons.shouldShow(popup(), {}, true, nil))
    end)

    self:test("shouldShow: Wikipedia popup -> false", function()
        self:assert(not DictButtons.shouldShow(popup({ is_wiki = true }), {}, true, nil))
    end)

    self:test("shouldShow: empty/no word -> false", function()
        self:assert(not DictButtons.shouldShow(popup({ word = "" }), {}, true, nil))
        self:assert(not DictButtons.shouldShow(popup({ word = false }), {}, true, nil))
    end)

    self:test("shouldShow: requires_open_book with no document -> false", function()
        self:assert(not DictButtons.shouldShow(popup(), { requires_open_book = true }, false, nil))
        self:assert(DictButtons.shouldShow(popup(), { requires_open_book = true }, true, nil))
    end)

    self:test("shouldShow: requires_xray_cache gates on has_xray_fn", function()
        local action = { requires_xray_cache = true }
        self:assert(not DictButtons.shouldShow(popup(), action, true, function() return false end))
        self:assert(DictButtons.shouldShow(popup(), action, true, function() return true end))
    end)

    self:test("shouldShow: has_xray_fn only called when action requires it", function()
        local calls = 0
        local fn = function() calls = calls + 1; return true end
        DictButtons.shouldShow(popup(), {}, true, fn)                       -- normal action
        self:assertEquals(calls, 0, "must not probe X-Ray cache for normal actions")
        DictButtons.shouldShow(popup(), { requires_xray_cache = true }, true, fn)
        self:assertEquals(calls, 1, "must probe X-Ray cache for conditional X-Ray action")
    end)

    -- ---- consumeNonReader (idempotent flag transfer) ----
    self:test("consumeNonReader transfers flag from dict to popup, clears dict", function()
        local dict = { _koassistant_non_reader_lookup = true }
        local p = {}
        local v = DictButtons.consumeNonReader(p, dict)
        self:assertEquals(v, true)
        self:assertEquals(p._koassistant_non_reader, true)
        self:assertEquals(dict._koassistant_non_reader_lookup, nil, "flag must be consumed")
    end)

    self:test("consumeNonReader defaults to false when no flag set", function()
        local p = {}
        self:assertEquals(DictButtons.consumeNonReader(p, {}), false)
        self:assertEquals(p._koassistant_non_reader, false)
    end)

    self:test("consumeNonReader is idempotent across rebuilds", function()
        local p = {}
        DictButtons.consumeNonReader(p, { _koassistant_non_reader_lookup = true })  -- captures true
        -- Second call (e.g. pagination rebuild) with a fresh non-reader flag set:
        -- must NOT overwrite the value already captured for this popup.
        local dict2 = { _koassistant_non_reader_lookup = true }
        DictButtons.consumeNonReader(p, dict2)
        self:assertEquals(p._koassistant_non_reader, true)
        self:assertEquals(dict2._koassistant_non_reader_lookup, true,
            "second call must not consume a new flag once popup value is set")
    end)

    self:test("consumeNonReader tolerates nil dict", function()
        local p = {}
        self:assertEquals(DictButtons.consumeNonReader(p, nil), false)
    end)

    -- ---- splitRows ----
    local function rowSizes(rows)
        local sizes = {}
        for i = 1, #rows do sizes[i] = #rows[i] end
        return table.concat(sizes, ",")
    end

    self:test("splitRows groups into rows of 3 with partial last row", function()
        self:assertEquals(rowSizes(DictButtons.splitRows({ 1, 2, 3, 4, 5 })), "3,2")
        self:assertEquals(rowSizes(DictButtons.splitRows({ 1, 2, 3 })), "3")
        self:assertEquals(rowSizes(DictButtons.splitRows({ 1, 2, 3, 4, 5, 6 })), "3,3")
        self:assertEquals(rowSizes(DictButtons.splitRows({ 1, 2, 3, 4, 5, 6, 7 })), "3,3,1")
        self:assertEquals(rowSizes(DictButtons.splitRows({ 1 })), "1")
        self:assertEquals(#DictButtons.splitRows({}), 0)
    end)

    self:test("splitRows preserves element order and contents", function()
        local rows = DictButtons.splitRows({ "a", "b", "c", "d" })
        self:assertEquals(rows[1][1], "a")
        self:assertEquals(rows[1][3], "c")
        self:assertEquals(rows[2][1], "d")
    end)

    print(string.format("\nResults: %d passed, %d failed\n", self.passed, self.failed))
    return self.failed == 0
end

-- Run directly
if arg and arg[0] and arg[0]:match("test_dict_buttons%.lua$") then
    local success = T:runAll()
    os.exit(success and 0 or 1)
end

return T
