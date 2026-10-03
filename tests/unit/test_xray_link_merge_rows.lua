-- B401: the "Link and merge…" group of the X-Ray popup and of the X-Ray
-- browser's menu comes from ONE builder (koassistant_xray_rows.lua
-- linkMergeRows), so the two surfaces show the same rows in the same order.
-- Until 2026-10-03 the popup had the group and the browser's menu listed the
-- same rows flat, in another order, with the duplicate review further down.
--   * the rows, their order and labels for a series, a project and a book in
--     no group; no carried entries or no section X-Rays means no such row
--   * a row runs the surface's `pre` (close the chrome), then its handler
--   * both surfaces call the builder and neither spells a row of the group
--     itself (a row re-inlined on one surface is how they drifted)
--
-- Run: lua tests/unit/test_xray_link_merge_rows.lua  (or lua tests/run_tests.lua --unit)

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
require("mock_koreader")
local TestRunner = require("test_runner"):new()

-- The builder asks the browser module for the carried list's title. One Lua
-- process runs every test file: the stand-in is taken out again at the end.
local saved_browser = package.loaded["koassistant_xray_browser"]
local disk_reads = {}
package.loaded["koassistant_xray_browser"] = {
    carriedListTitle = function(_file, n) return "Carried from earlier books (" .. n .. ")" end,
    carriedListLabel = function(file, raw)
        disk_reads[#disk_reads + 1] = { file = file, raw = raw }
        if raw == "none" then return nil end
        return "Carried from earlier books (7)"
    end,
}
local XrayRows = require("koassistant_xray_rows")

local function plugin(kind)
    return { _groupXrayMergeKind = function() return kind end }
end
local function labels(rows)
    local out = {}
    for i, row in ipairs(rows) do out[i] = row[1].text end
    return table.concat(out, " | ")
end
local function handlers(log)
    local function note(name) return function(arg) log[#log + 1] = name .. (arg and (":" .. arg) or "") end end
    return {
        on_carried = note("carried"), on_cross_book = note("cross"),
        on_group_merge = note("group"), on_sections = note("sections"), on_dedup = note("dedup"),
    }
end
local function ctx(kind, extra)
    local c = handlers({})
    c.plugin, c.file = plugin(kind), "/b/vol3.epub"
    for k, v in pairs(extra or {}) do c[k] = v end
    return c
end

print("")
print("  [" .. "the rows, their order and labels" .. "]")

TestRunner:test("a series with carried entries and a section X-Ray: five rows, the carried list first", function()
    local rows = XrayRows.linkMergeRows(ctx("series", { carried_count = 9, section_count = 1 }))
    TestRunner:assertEqual(labels(rows), table.concat({
        "Carried from earlier books (9)…",
        "AI merge with another book (1 request)…",
        "AI merge the series (1 request per book)…",
        "AI merge section X-Rays (1)…",
        "Find duplicate entities…",
    }, " | "))
end)

TestRunner:test("a project names its own merge", function()
    local rows = XrayRows.linkMergeRows(ctx("project", { carried_count = 2 }))
    TestRunner:assertEqual(labels(rows), table.concat({
        "Carried from earlier books (2)…",
        "AI merge with another book (1 request)…",
        "AI merge the group into this book (1 request per book)…",
        "Find duplicate entities…",
    }, " | "))
end)

TestRunner:test("no group merge, nothing carried, no sections: the two rows every X-Ray has", function()
    local rows = XrayRows.linkMergeRows(ctx(nil, { carried_count = 0, section_count = 0 }))
    TestRunner:assertEqual(labels(rows), "AI merge with another book (1 request)… | Find duplicate entities…")
end)

TestRunner:test("a surface without the count hands over the X-Ray's text and the count is read for it", function()
    disk_reads = {}
    local rows = XrayRows.linkMergeRows(ctx("series", { raw = "{json}" }))
    TestRunner:assertEqual(rows[1][1].text, "Carried from earlier books (7)…")
    TestRunner:assertEqual(#disk_reads, 1)
    TestRunner:assertEqual(disk_reads[1].raw, "{json}", "the text goes along, so one without a carried list is not parsed")
    rows = XrayRows.linkMergeRows(ctx("series", { raw = "none" }))
    TestRunner:assertEqual(rows[1][1].text, "AI merge with another book (1 request)…", "nothing carried: no row")
    disk_reads = {}
    XrayRows.linkMergeRows(ctx("series", { carried_count = 3 }))
    TestRunner:assertEqual(#disk_reads, 0, "a surface that counts itself causes no read")
end)

TestRunner:test("the row alignment is the surface's", function()
    local rows = XrayRows.linkMergeRows(ctx("series", { carried_count = 1, align = "left" }))
    for i, row in ipairs(rows) do TestRunner:assertEqual(row[1].align, "left", "row " .. i) end
    rows = XrayRows.linkMergeRows(ctx("series", { carried_count = 1 }))
    TestRunner:assertEqual(rows[1][1].align, nil)
end)

print("")
print("  [" .. "what a row does" .. "]")

TestRunner:test("every row closes the surface first, then starts its own flow", function()
    local log = {}
    local c = handlers(log)
    c.plugin, c.file, c.carried_count, c.section_count = plugin("project"), "/b/vol3.epub", 4, 2
    c.pre = function() log[#log + 1] = "pre" end
    local rows = XrayRows.linkMergeRows(c)
    for _idx, row in ipairs(rows) do row[1].callback() end
    TestRunner:assertEqual(table.concat(log, ","),
        "pre,carried,pre,cross,pre,group:project,pre,sections,pre,dedup",
        "the group merge is told its kind")
end)

TestRunner:test("a row the surface cannot start is left out; no plugin or book means no rows", function()
    local c = ctx("series", { carried_count = 5, section_count = 1 })
    c.on_carried, c.on_sections = nil, nil
    TestRunner:assertEqual(labels(XrayRows.linkMergeRows(c)),
        "AI merge with another book (1 request)… | AI merge the series (1 request per book)… | Find duplicate entities…")
    TestRunner:assertEqual(#XrayRows.linkMergeRows({ file = "/b/vol3.epub" }), 0)
    TestRunner:assertEqual(#XrayRows.linkMergeRows({ plugin = plugin("series") }), 0)
end)

TestRunner:test("the group's row label and its title", function()
    TestRunner:assertEqual(XrayRows.linkMergeLabel(), "Link and merge…")
    TestRunner:assertEqual(XrayRows.linkMergeTitle(), "Link and merge")
end)

print("")
print("  [" .. "parity: both surfaces take the group from the builder" .. "]")

local function source(name)
    local f = assert(io.open(plugin_dir .. "/" .. name, "r"))
    local text = f:read("*a")
    f:close()
    return text
end
local function count(text, needle)
    local n, pos = 0, 1
    while true do
        local s, e = text:find(needle, pos, true)
        if not s then return n end
        n, pos = n + 1, e + 1
    end
end

TestRunner:test("the X-Ray popup and the browser's menu each call it once and spell none of its rows", function()
    for _idx, name in ipairs({ "main.lua", "koassistant_xray_browser.lua" }) do
        local text = source(name)
        TestRunner:assertEqual(count(text, "linkMergeRows("), 1, name .. " builds the group once")
        TestRunner:assertTrue(count(text, "linkMergeLabel()") >= 1, name .. " takes the group's label from the builder")
        for _i, label in ipairs({
            "AI merge with another book (1 request)…",
            "AI merge the series (1 request per book)…",
            "AI merge the group into this book (1 request per book)…",
            "Find duplicate entities…",
            "_(\"Link and merge",
        }) do
            TestRunner:assertEqual(count(text, label), 0, name .. " spells a row of the group itself: " .. label)
        end
    end
end)

-- ------------------------------------------------------------------ cleanup
package.loaded["koassistant_xray_browser"] = saved_browser

return TestRunner:summary()
