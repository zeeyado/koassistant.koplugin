-- KOReader's annotations list holds page bookmarks beside the highlights (no
-- drawer, the page's first words as text). ContextExtractor.isHighlight is
-- THE rule, and every reader of the list that means highlights asks it (the
-- sweep of 2026-11-06): the two formatters, the funnel's two counts and the
-- X-Ray browser's highlight matches.
--
-- Run: lua tests/unit/test_annotation_shapes.lua  (or lua tests/run_tests.lua --unit)

local function setupPaths()
    local info = debug.getinfo(1, "S")
    local script_path = info.source:match("@?(.*)")
    local unit_dir = script_path:match("(.+)/[^/]+$") or "."
    local tests_dir = unit_dir:match("(.+)/[^/]+$") or "."
    local plugin_dir = tests_dir:match("(.+)/[^/]+$") or "."
    package.path = table.concat({
        plugin_dir .. "/?.lua", tests_dir .. "/?.lua", tests_dir .. "/lib/?.lua", package.path,
    }, ";")
    return plugin_dir
end
local plugin_dir = setupPaths()
require("mock_koreader")
local TestRunner = require("test_runner"):new()
local CE = require("koassistant.request.context_extractor")

local function read(rel)
    local f = assert(io.open(plugin_dir .. "/" .. rel, "r"))
    local s = f:read("*a")
    f:close()
    return s
end

print("Running: test_annotation_shapes")
print("")

-- the shapes ReaderBookmark:toggleBookmark and ReaderHighlight create
local bookmark = { page = "/body/DocFragment[3]", text = "in Ch3", chapter = "Ch3" }
local highlight = { drawer = "lighten", text = "real hl", chapter = "Ch3", pos0 = "a", pos1 = "b" }
local noted = { drawer = "underscore", text = "noted hl", note = "my note", pageno = 12 }

TestRunner:test("isHighlight: a drawer and a text; a page bookmark is neither", function()
    TestRunner:assertTrue(CE.isHighlight(highlight))
    TestRunner:assertTrue(CE.isHighlight(noted))
    TestRunner:assertFalse(CE.isHighlight(bookmark), "a page bookmark")
    TestRunner:assertFalse(CE.isHighlight({ drawer = "lighten", text = "" }), "an empty text")
    TestRunner:assertFalse(CE.isHighlight("x"))
    TestRunner:assertFalse(CE.isHighlight(nil))
end)

TestRunner:test("the formatters count and list the highlights only", function()
    local h = CE.formatHighlights({ bookmark, highlight, noted })
    TestRunner:assertEqual(h.count, 2)
    TestRunner:assertTrue(h.formatted:find("real hl", 1, true) ~= nil)
    TestRunner:assertTrue(h.formatted:find("in Ch3", 1, true) == nil, "the bookmark's page words are not a highlight")
    local a = CE.formatAnnotations({ bookmark, highlight, noted })
    TestRunner:assertEqual(a.count, 2)
    TestRunner:assertTrue(a.formatted:find("[Note: my note]", 1, true) ~= nil)
    TestRunner:assertTrue(a.formatted:find("in Ch3", 1, true) == nil)
end)

TestRunner:test("the funnel's counts and the X-Ray browser's matches ask the rule", function()
    local da = read("koassistant/ui/data_access.lua")
    local n = select(2, da:gsub('require%("koassistant%.request%.context_extractor"%)%.isHighlight%(a%)', ""))
    TestRunner:assertEqual(n, 2, "the amounts and the exists counts")
    TestRunner:assertTrue(da:find('type(a) == "table" and type(a.text) == "string" and a.text ~= ""', 1, true) == nil, "no own rule left")
    local xb = read("koassistant/xray/xray_browser.lua")
    TestRunner:assertTrue(xb:find("if isHighlight(annotation) then", 1, true) ~= nil, "findItemHighlights")
    local ce = read("koassistant/request/context_extractor.lua")
    TestRunner:assertEqual(select(2, ce:gsub("if ContextExtractor%.isHighlight%(annotation%) then", "")), 2, "both formatters")
end)

-- ── a note the plugin saved is told from the reader's own (B756 c) ───────────
-- The record is the one HighlightNote keeps per book: built here the way its
-- writer builds it, a piece per saved answer with its place and fingerprint.
local HighlightNote = require("koassistant.chat.highlight_note")
local TRANSLATION = "The morning rose grey."
local EXPLAINED = "Explain:\nGrey here means overcast."
local function piece(kind, text, from, extra)
    local p = { kind = kind, at = 1, from = from, len = #text, sum = HighlightNote.fingerprint(text) }
    for k, v in pairs(extra or {}) do p[k] = v end
    return p
end
local function store(lines)
    return { readSetting = function(_self, key)
        return key == HighlightNote.RECORD_KEY and lines or nil
    end }
end
local kept = { drawer = "lighten", text = "Morning came grey", chapter = "Ch1", datetime = "2026-11-23 10:00:00",
    note = TRANSLATION .. "\n\n" .. EXPLAINED }
local kept_record = { [kept.datetime] = { parts = {
    piece("translate", TRANSLATION, 1, { action = "translate", action_name = "Translate", lead = 0 }),
    piece("chat", EXPLAINED, #TRANSLATION + 3, { action = "explain", action_name = "Explain", lead = #"Explain:\n" }),
} } }

TestRunner:test("answers the plugin saved go marked as saved answers, never as the reader's note", function()
    local a = CE.formatAnnotations({ kept }, { record = store(kept_record) })
    TestRunner:assertEqual(a.formatted, table.concat({
        '- "Morning came grey"',
        "  [Saved translation: The morning rose grey.]",
        "  [Saved AI answer (Explain): Grey here means overcast.]",
        "  (Chapter: Ch1)",
    }, "\n"), "each piece under its mark, the action's own line left out (the mark says it)")
    TestRunner:assertTrue(a.formatted:find("[Note:", 1, true) == nil, "nothing of it is called the reader's note")
    TestRunner:assertEqual(a.items[1].note, kept.note, "the item keeps the note as it is")
    -- a dictionary answer, and an answer whose action is not on record
    local word = { drawer = "lighten", text = "lantern", datetime = "d2", note = "A lamp.\n\nA bare answer." }
    local rec = { d2 = { parts = { piece("dictionary", "A lamp.", 1), piece("chat", "A bare answer.", 10) } } }
    a = CE.formatAnnotations({ word }, { record = store(rec) })
    TestRunner:assertTrue(a.formatted:find("  [Saved dictionary answer: A lamp.]\n  [Saved AI answer: A bare answer.]", 1, true) ~= nil,
        a.formatted)
end)

TestRunner:test("the reader's own words around a saved answer stay notes, in the note's order", function()
    local mixed = { drawer = "lighten", text = "Morning came grey", datetime = kept.datetime,
        note = "Before it, mine.\n\n" .. TRANSLATION .. "\n\n(ch. 2, my own line)" }
    local rec = { [kept.datetime] = { parts = { piece("translate", TRANSLATION, #"Before it, mine.\n\n" + 1) } } }
    local a = CE.formatAnnotations({ mixed }, { record = store(rec), include_chapter = false })
    TestRunner:assertEqual(a.formatted, table.concat({
        '- "Morning came grey"',
        "  [Note: Before it, mine.]",
        "  [Saved translation: The morning rose grey.]",
        "  [Note: (ch. 2, my own line)]",
    }, "\n"))
end)

TestRunner:test("a note the reader rewrote, a note with no record and a record that cannot be read are the reader's", function()
    local rewritten = { drawer = "lighten", text = "Morning came grey", datetime = kept.datetime,
        note = "The morning rose gray, I would say." }
    local a = CE.formatAnnotations({ rewritten }, { record = store(kept_record), include_chapter = false })
    TestRunner:assertEqual(a.formatted, '- "Morning came grey"\n  [Note: The morning rose gray, I would say.]')
    a = CE.formatAnnotations({ noted }, { record = store(kept_record) })
    TestRunner:assertTrue(a.formatted:find("[Note: my note]", 1, true) ~= nil, "another highlight's own note")
    a = CE.formatAnnotations({ kept }, { record = { readSetting = function() error("disk") end } })
    TestRunner:assertTrue(a.formatted:find("[Note: " .. kept.note .. "]", 1, true) ~= nil, "sent whole, as before the record existed")
    a = CE.formatAnnotations({ kept })
    TestRunner:assertTrue(a.formatted:find("[Note: " .. kept.note .. "]", 1, true) ~= nil, "no record handed over")
    TestRunner:assertEqual(CE.noteRecord(nil), nil, "no book: no record")
end)

TestRunner:test("every place that builds the notes of a request hands the record over", function()
    -- the hand-off's two ends: the callers, cut from the source
    local sites, with_record = 0, 0
    for _i, rel in ipairs({ "koassistant/request/context_extractor.lua", "koassistant/ui/dialogs.lua", "main.lua" }) do
        local src = read(rel)
        local at = 1
        while true do
            local s, e = src:find("ContextExtractor%.formatAnnotations%(", at)
            if not s then break end
            if src:sub(math.max(1, s - 9), s - 1) ~= "function " then
                sites = sites + 1
                local call = src:sub(s, e + 160)
                if call:find("with_record", 1, true) or call:find("record = ContextExtractor.noteRecord(", 1, true) then
                    with_record = with_record + 1
                end
            end
            at = e + 1
        end
    end
    TestRunner:assertEqual(sites, 3, "the open book, a closed book, each book of a library action")
    TestRunner:assertEqual(with_record, sites, "a site that does not would send an AI's saved answer as the reader's note")
end)

return TestRunner:summary()
