--[[
Unit tests for koassistant/images/prompt_writer.lua (image round S5, S6, S8:
docs/image_round_plan.md sections 7 and 9).

Covers the pure parts of the prompt writer: the styles, the writer's model,
an X-Ray entry as material and the entries a passage names (the marks'
matcher), the shape line, the system text (the spoiler rule, the entry to
draw), the material blocks (tags, escaping, caps, optional blocks), reading
the writer's answer, and the provenance line.

Run: lua tests/run_tests.lua --unit
]]

package.path = package.path .. ";./?.lua;./?/init.lua"
require("tests.lib.mock_koreader")

local PromptWriter = require("koassistant.images.prompt_writer")

local TestRunner = { passed = 0, failed = 0 }

function TestRunner:test(name, fn)
    local ok, err = pcall(fn)
    if ok then
        self.passed = self.passed + 1
        print(string.format("  ✓ %s", name))
    else
        self.failed = self.failed + 1
        print(string.format("  ✗ %s: %s", name, tostring(err)))
    end
end

function TestRunner:assert(cond, msg)
    if not cond then error(msg or "Assertion failed", 2) end
end

function TestRunner:assertEquals(actual, expected, msg)
    if actual ~= expected then
        error(string.format("%s: expected %s, got %s", msg or "Values not equal",
            tostring(expected), tostring(actual)), 2)
    end
end

local function has(text, piece)
    return type(text) == "string" and text:find(piece, 1, true) ~= nil
end

-- A small fiction X-Ray, as ActionCache.parsedXrayFor returns its data
local XRAY = {
    type = "fiction",
    characters = {
        { name = "Elias Morrow", aliases = { "the keeper" }, role = "Lighthouse keeper",
          description = "A tall, weathered man in a grey oilskin coat." },
        { name = "Mara", description = "His daughter, quick and watchful, with a red scarf." },
        { name = "Tom", description = "A fisherman." },
    },
    locations = {
        { name = "the Black Rocks", description = "Jagged basalt at the mouth of the bay.",
          details = "Covered at high tide." },
    },
    themes = {
        { name = "Solitude", description = "Living apart from others." },
    },
    timeline = {
        { event = "The lamp goes dark", significance = "The storm night begins." },
    },
}

print("  Unit Tests: the image prompt writer")

print("  [Style (S6)]")
TestRunner:test("styleText: the pick's words; the default is Book illustration", function()
    local text, is_default = PromptWriter.styleText({})
    TestRunner:assertEquals(text, "a book illustration")
    TestRunner:assertEquals(is_default, true)
    text, is_default = PromptWriter.styleText({ image_gen_style = "woodcut" })
    TestRunner:assertEquals(text, "a woodcut print")
    TestRunner:assertEquals(is_default, false)
    TestRunner:assertEquals(PromptWriter.styleText({ image_gen_style = "bogus" }), "a book illustration",
        "an unknown value reads as the default")
end)
TestRunner:test("Custom: the typed words, trimmed and capped; empty falls back", function()
    local text = PromptWriter.styleText({ image_gen_style = "custom", image_gen_style_custom = "  a 1920s\ntravel poster " })
    TestRunner:assertEquals(text, "a 1920s travel poster")
    TestRunner:assertEquals(PromptWriter.styleLabel({ image_gen_style = "custom", image_gen_style_custom = "a poster" }),
        "Custom (a poster)")
    TestRunner:assertEquals(PromptWriter.styleText({ image_gen_style = "custom", image_gen_style_custom = "  " }),
        "a book illustration")
    local long = string.rep("x", 500)
    TestRunner:assert(#PromptWriter.styleText({ image_gen_style = "custom", image_gen_style_custom = long }) <= 200)
    TestRunner:assertEquals(PromptWriter.styleLabel({}), "Book illustration")
    TestRunner:assertEquals(#PromptWriter.STYLES, 8, "eight styles, then Custom")
end)

print("  [The writer's model]")
TestRunner:test("target: the chat model by default; Prompt writer's Fast model takes the fast tier", function()
    local ModelLists = require("koassistant.request.model_lists")
    local real = ModelLists.resolveTierTarget
    ModelLists.resolveTierTarget = function(p, tier)
        if tier == "fast" and p == "anthropic" then return "anthropic", "claude-fast" end
        if tier == "fast" and p == "pinned" then return "gemini", "gemini-fast" end
        return nil
    end
    local ok, err = pcall(function()
        local p, m = PromptWriter.target({}, "anthropic")
        TestRunner:assertEquals(p, "anthropic")
        TestRunner:assertEquals(m, nil, "the chat model as configured")
        local fast = { image_gen_writer_model = "fast" }
        p, m = PromptWriter.target(fast, "anthropic")
        TestRunner:assertEquals(p, "anthropic")
        TestRunner:assertEquals(m, "claude-fast")
        p, m = PromptWriter.target(fast, "pinned")
        TestRunner:assertEquals(p, "gemini", "a global tier pin may name another provider")
        TestRunner:assertEquals(m, "gemini-fast")
        p, m = PromptWriter.target({ image_gen_writer_model = "fast", use_action_tiers = false }, "anthropic")
        TestRunner:assertEquals(m, "claude-fast", "the writer's own setting decides, not Faster Models for Quick Actions")
        p, m = PromptWriter.target(fast, "ollama")
        TestRunner:assertEquals(p, "ollama")
        TestRunner:assertEquals(m, nil, "no fast model known: the chat model")
    end)
    ModelLists.resolveTierTarget = real
    if not ok then error(err, 0) end
end)

print("  [X-Ray material (D10, S8)]")
TestRunner:test("entryMaterial: name, aliases, kind, the description with a role first", function()
    local e = PromptWriter.entryMaterial(XRAY.characters[1], "characters")
    TestRunner:assertEquals(e.name, "Elias Morrow")
    TestRunner:assertEquals(e.type, "person")
    TestRunner:assertEquals(e.aliases[1], "the keeper")
    TestRunner:assertEquals(e.description, "Lighthouse keeper. A tall, weathered man in a grey oilskin coat.")
    local place = PromptWriter.entryMaterial(XRAY.locations[1], "locations")
    TestRunner:assertEquals(place.type, "place")
    TestRunner:assert(has(place.description, "Covered at high tide."), place.description)
    local event = PromptWriter.entryMaterial(XRAY.timeline[1], "timeline")
    TestRunner:assertEquals(event.name, "The lamp goes dark")
    TestRunner:assertEquals(event.type, "event")
    TestRunner:assert(has(event.description, "storm night"), event.description)
    local dots = PromptWriter.entryMaterial({ name = "X", role = "A man of few words...", description = "Tall." }, "characters")
    TestRunner:assertEquals(dots.description, "A man of few words... Tall.", "an ellipsis stays an ellipsis")
    local long = PromptWriter.entryMaterial({ name = "X", description = string.rep("word ", 300) }, "characters")
    TestRunner:assert(#long.description <= 604, "about 600 characters: " .. #long.description)
end)
TestRunner:test("entriesFor: the entries the passage names, in its order, aliases too", function()
    local list = PromptWriter.entriesFor(
        "Mara ran down to the Black Rocks, where the keeper stood waiting.", XRAY)
    TestRunner:assertEquals(#list, 3)
    TestRunner:assertEquals(list[1].name, "Mara")
    TestRunner:assertEquals(list[2].name, "the Black Rocks")
    TestRunner:assertEquals(list[3].name, "Elias Morrow", "named by an alias")
    TestRunner:assertEquals(#PromptWriter.entriesFor("Nothing here names anyone.", XRAY), 0)
    TestRunner:assertEquals(#PromptWriter.entriesFor("The lamp goes dark.", XRAY), 0,
        "a Story Arc event is not matched in text (the marks skip it)")
    TestRunner:assertEquals(#PromptWriter.entriesFor("", XRAY), 0)
    TestRunner:assertEquals(#PromptWriter.entriesFor("Mara", nil), 0)
end)
TestRunner:test("entriesFor: the note's entries come first (B535), never twice", function()
    local list = PromptWriter.entriesFor("She ran down to the Black Rocks.", XRAY, nil,
        "this is Mara by the way")
    TestRunner:assertEquals(#list, 2)
    TestRunner:assertEquals(list[1].name, "Mara", "named in the note, which the passage does not")
    TestRunner:assertEquals(list[2].name, "the Black Rocks")
    list = PromptWriter.entriesFor("Mara waved to the keeper.", XRAY, nil, "Mara, at night")
    TestRunner:assertEquals(#list, 2)
    TestRunner:assertEquals(list[1].name, "Mara")
    TestRunner:assertEquals(list[2].name, "Elias Morrow", "Mara is listed once")
    TestRunner:assertEquals(#PromptWriter.entriesFor("Nothing here.", XRAY, nil, "from behind, at dusk"), 0,
        "a note that names nobody adds nobody")
    TestRunner:assertEquals(#PromptWriter.entriesFor("Mara and Tom.", XRAY, 1, "the keeper"), 1, "the limit holds")
end)
TestRunner:test("pickable: each category the matcher reads, in the X-Ray's order, by name (B537)", function()
    local groups = PromptWriter.pickable(XRAY)
    local seen = {}
    for _idx, g in ipairs(groups) do
        local names = {}
        for _j, r in ipairs(g.rows) do names[#names + 1] = r.name end
        seen[#seen + 1] = g.label .. ": " .. table.concat(names, "|")
    end
    TestRunner:assertEquals(table.concat(seen, " / "),
        "Cast: Elias Morrow|Mara|Tom / World: the Black Rocks / Ideas: Solitude", "no Story Arc")
    TestRunner:assertEquals(groups[1].rows[1].role, "Lighthouse keeper")
    TestRunner:assertEquals(#PromptWriter.pickable(nil), 0)
end)
TestRunner:test("entriesFor: the reader's list from the popup is the list (B537)", function()
    local list = PromptWriter.entriesFor("She ran down to the Black Rocks.", XRAY, nil,
        "this is Mara", { "Tom", "Elias Morrow" })
    local names = {}
    for _idx, e in ipairs(list) do names[#names + 1] = e.name end
    TestRunner:assertEquals(table.concat(names, "|"), "Tom|Elias Morrow",
        "in the order picked; what the passage and the note name was on the list to clear")
    list = PromptWriter.entriesFor("Mara waved.", XRAY, nil, nil, { "Mara", "Nobody Here" })
    TestRunner:assertEquals(#list, 1, "an unknown pick is skipped")
    TestRunner:assertEquals(#PromptWriter.entriesFor("Mara waved.", XRAY, nil, nil, {}), 0,
        "an emptied list sends none")
    TestRunner:assertEquals(#PromptWriter.entriesFor("Mara and Tom.", XRAY, 2, nil, { "the Black Rocks", "Tom", "Mara" }), 2,
        "the limit holds")
end)
TestRunner:test("pickerTiers: the picked, then the suggested, then the rest by category (B537)", function()
    local function names(rows)
        local out = {}
        for _idx, r in ipairs(rows) do out[#out + 1] = r.name end
        return table.concat(out, "|")
    end
    local tiers = PromptWriter.pickerTiers(XRAY, "Elias waved to Tom from the Black Rocks.", nil, { "the Black Rocks" })
    TestRunner:assertEquals(names(tiers.picked), "the Black Rocks")
    TestRunner:assertEquals(names(tiers.suggested), "Tom|Elias Morrow",
        "named and not picked, then by one word of the name, as a lookup of \"Elias\" finds him")
    TestRunner:assertEquals(#tiers.groups, 2)
    TestRunner:assertEquals(tiers.groups[1].label .. ": " .. names(tiers.groups[1].rows), "Cast: Mara",
        "the rest, without the ones above")
    TestRunner:assertEquals(tiers.groups[2].label, "Ideas", "a category left empty is gone")
    tiers = PromptWriter.pickerTiers(XRAY, "She looked up.", "Mara at dusk", nil)
    TestRunner:assertEquals(names(tiers.suggested), "Mara", "the note's names too")
    tiers = PromptWriter.pickerTiers(XRAY, "elias waved", nil, nil)
    TestRunner:assertEquals(#tiers.suggested, 0, "a word without its capital proposes nothing")
    local houses = { type = "fiction", characters = {
        { name = "House Arden" }, { name = "House Blane" }, { name = "House Corr" }, { name = "House Dale" },
        { name = "Arden Vey" },
    } }
    tiers = PromptWriter.pickerTiers(houses, "House Arden rode out.", nil, {})
    TestRunner:assertEquals(names(tiers.suggested), "House Arden|Arden Vey",
        "named in full, then Arden; House, which four entries share, proposes nothing")
    local drowned = { type = "fiction", characters = { { name = "The Drowned" }, { name = "Mara" } } }
    tiers = PromptWriter.pickerTiers(drowned, "The rows flooded. Mara saw the boats.", nil, {})
    TestRunner:assertEquals(names(tiers.suggested), "Mara",
        "\"The\" opening a sentence, which the text also writes in lowercase, proposes nothing")
    tiers = PromptWriter.pickerTiers(XRAY, nil, nil, { "Gone Now" })
    TestRunner:assertEquals(names(tiers.picked), "Gone Now", "a pick the X-Ray no longer has stays to clear")
end)
-- The device fixture's shape (Mock Series 3): the term "Warden" in this
-- book, the character "the Warden" and Dorrit Hale carried from book 2,
-- Zeph Umber from book 1
local CARRIED = { type = "fiction",
    characters = { { name = "Gil Rook", role = "Grafter", description = "Grafts the rows." } },
    lexicon = { { term = "Warden", definition = "The keeper of a flooded grove." } },
    __dormant = {
        { name = "the Warden", aliases = { "Warden" }, category = "characters", role = "Harbor official",
          description = "Inspects the ferry manifests.", source = "Vol 2", file = "/b/v2.epub" },
        { name = "Dorrit Hale", category = "characters", role = "Innkeeper",
          description = "Keeps the ferry inn.", source = "Vol 2", file = "/b/v2.epub" },
        { name = "Zeph Umber", category = "characters", description = "A diver.",
          source = "Vol 1", file = "/b/v1.epub" },
        { name = "Gil Rook", category = "characters", description = "An older Gil.", source = "Vol 2",
          file = "/b/v2.epub" },
    },
}
TestRunner:test("withCarried: carried rows among the book's own, a copy (B537)", function()
    local labels = { ["/b/v2.epub"] = "Book 2", ["/b/v1.epub"] = "Book 1" }
    local data = PromptWriter.withCarried(CARRIED, { from = function(s) return labels[s.file] end })
    local names = {}
    for _idx, it in ipairs(data.characters) do
        names[#names + 1] = it.name .. (it._carried and ("<" .. it._from .. ">") or "")
    end
    TestRunner:assertEquals(table.concat(names, "|"), "Gil Rook|Dorrit Hale<Book 2>|the Warden<Book 2>|Zeph Umber<Book 1>",
        "after the book's own, by name; a carried row named like an entry of this book stays out")
    TestRunner:assertEquals(#CARRIED.characters, 1, "the X-Ray's own lists unchanged")
    TestRunner:assert(data.__dormant == nil, "the carried list is folded in, not kept beside")
    data = PromptWriter.withCarried(CARRIED, { skip = { ["/b/v2.epub"] = true } })
    names = {}
    for _idx, it in ipairs(data.characters) do names[#names + 1] = it.name end
    TestRunner:assertEquals(table.concat(names, "|"), "Gil Rook|Zeph Umber",
        "none from a book whose text is Never for a provider here")
    TestRunner:assert(PromptWriter.withCarried({ type = "fiction", characters = {} }).__dormant == nil)
end)
TestRunner:test("carried entries: named, picked and sent like the book's own, the book's own first (B537)", function()
    local data = PromptWriter.withCarried(CARRIED, { from = function() return "Book 2" end })
    local function names(list)
        local out = {}
        for _idx, e in ipairs(list) do out[#out + 1] = e.name end
        return table.concat(out, "|")
    end
    TestRunner:assertEquals(names(PromptWriter.entriesFor(
        "Dorrit Hale, the letters said, was selling. The Warden was named in the small print, and Gil Rook read it twice.",
        data)), "Dorrit Hale|the Warden|Gil Rook", "\"The Warden\" is the carried character, not the term")
    TestRunner:assertEquals(names(PromptWriter.entriesFor("A warden's first job is to notice.", data)), "Warden",
        "\"warden\" alone is this book's term: a carried entry only where none of the book's own is named")
    local list = PromptWriter.entriesFor("x", data, nil, nil, { "Dorrit Hale" })
    TestRunner:assert(list[1] and list[1].carried == true and list[1].description == "Innkeeper. Keeps the ferry inn.",
        "picked by name, sent with its description and marked carried")
    local groups = PromptWriter.pickable(data)
    local cast = {}
    for _idx, r in ipairs(groups[1].rows) do cast[#cast + 1] = r.name .. (r.from and (" · " .. r.from) or "") end
    TestRunner:assertEquals(table.concat(cast, "|"), "Gil Rook|Dorrit Hale · Book 2|the Warden · Book 2|Zeph Umber · Book 2",
        "the book's own by name, then the carried by name, each naming its book")
    local tiers = PromptWriter.pickerTiers(data, "Dorrit closed the inn.", nil, {})
    TestRunner:assertEquals(names(tiers.suggested), "Dorrit Hale", "a carried entry is suggested by one word too")
end)
TestRunner:test("entriesFor: five at most", function()
    local data = { type = "fiction", characters = {} }
    local words = {}
    for i = 1, 7 do
        local name = "Person" .. string.char(64 + i) .. "x"
        data.characters[i] = { name = name, description = "d" }
        words[#words + 1] = name
    end
    TestRunner:assertEquals(#PromptWriter.entriesFor(table.concat(words, " and "), data), 5)
end)

print("  [Shape (D11) and system text]")
TestRunner:test("shapeLine: proportions in words; the e-ink line on a grayscale screen", function()
    TestRunner:assertEquals(PromptWriter.shapeLine("fit", 1264 / 1680, false), "portrait, 3:4; to fill the reader's screen")
    TestRunner:assertEquals(PromptWriter.shapeLine("landscape", 3 / 2, false), "landscape, 3:2")
    TestRunner:assertEquals(PromptWriter.shapeLine("square", 1, true),
        "square, 1:1; shown on a black-and-white e-ink screen: clear shapes, strong contrast")
    TestRunner:assertEquals(PromptWriter.shapeLine("auto", nil, false), nil, "Let the model choose: nothing")
end)
TestRunner:test("systemText: the passage's blocks; the spoiler rule only when protected", function()
    local s = PromptWriter.systemText({})
    TestRunner:assert(has(s, "<passage>") and has(s, "<text_around>") and has(s, "<xray_entry>"), "passage blocks")
    TestRunner:assert(not has(s, "<entry_to_draw>"), "no entry block")
    TestRunner:assert(not has(s, "has not finished the book"), "no spoiler rule")
    TestRunner:assert(has(s, "never by name"), "people by how they look")
    TestRunner:assert(has(s, 'never "a young man named X" or "X, a young man"'), "not even beside a description")
    TestRunner:assert(has(s, "how they look and who they are, never by name")
        and has(s, "their people or nation, age and role"), "who they are, when the material says it")
    s = PromptWriter.systemText({ spoiler = true })
    TestRunner:assert(has(s, "Show nothing from later in the story than the passage."), "spoiler rule")
end)
TestRunner:test("systemText: the setting from the passage's moment, none invented where none is given", function()
    local s = PromptWriter.systemText({})
    TestRunner:assert(has(s, "Take the setting from the moment of the passage, not from another scene"), "the moment's setting")
    TestRunner:assert(has(s, "keep the background simple instead of inventing rooms, furniture or objects"), "no invented interior")
    TestRunner:assert(has(s, "Use it for who they are and how they look, not for where the moment takes place."), "an entry is not the setting")
    TestRunner:assert(has(s, "then the setting as far as the material gives it,"), "the length line")
    local e = PromptWriter.systemText({ subject = "entry" })
    TestRunner:assert(not has(e, "moment of the passage"), "an entry to draw has no passage")
    TestRunner:assert(has(e, "Where the description does not say where the subject is, keep the background simple")
        and has(e, "A place is its own setting.") and has(e, "then the setting as far as the material gives it,"),
        "an entry's background as far as its description gives it")
    TestRunner:assert(has(e, "If the subject is abstract (an idea, an argument, a feeling), choose a scene"),
        "an idea still gets its scene")
end)
TestRunner:test("systemText for an X-Ray entry (S8): the entry to draw, no passage", function()
    local s = PromptWriter.systemText({ subject = "entry", spoiler = true })
    TestRunner:assert(has(s, "<entry_to_draw>"), "entry block")
    TestRunner:assert(not has(s, "<passage>") and not has(s, "<text_around>"), "no passage blocks")
    TestRunner:assert(has(s, "than the description."), "the spoiler rule names the description")
end)

print("  [The material]")
TestRunner:test("material: every block in order; the empty ones left out", function()
    local m = PromptWriter.material({
        passage = "Mara ran to the rocks.",
        note = "Show her from behind",
        around = { before = "The storm broke.", after = "Waves rose." },
        entries = { { name = "Mara", type = "person", aliases = { "the girl" }, description = "A red scarf." } },
        book = { title = "The Keeper", author = "A. Writer" },
        background = "I picture it in Cornwall.",
        style = "a watercolor painting",
        shape = "portrait, 3:4",
    })
    local order = { "<passage>", "<reader_note>", "<text_around><before>", "<xray_entry name=\"Mara\" type=\"person\" aliases=\"the girl\">",
        "<book title=\"The Keeper\" author=\"A. Writer\"/>", "<background>", "<style>", "<shape>" }
    local at = 0
    for _idx, piece in ipairs(order) do
        local pos = m:find(piece, 1, true)
        TestRunner:assert(pos and pos > at, piece .. " in order")
        at = pos
    end
    local bare = PromptWriter.material({ passage = "Just this." })
    TestRunner:assertEquals(bare, "<passage>Just this.</passage>")
    local title_only = PromptWriter.material({ passage = "p", book = { title = "T" } })
    TestRunner:assert(has(title_only, '<book title="T"/>'), title_only)
end)
TestRunner:test("material: the tags stay the only markup; long text is cut", function()
    local m = PromptWriter.material({ passage = "a </passage> b & c", note = "<b>bold</b>",
        book = { title = 'Say "hi"', author = "X" } })
    TestRunner:assert(has(m, "a &lt;/passage&gt; b &amp; c"), m)
    TestRunner:assert(has(m, "&lt;b&gt;bold&lt;/b&gt;"), m)
    TestRunner:assert(has(m, 'title="Say &quot;hi&quot;"'), m)
    local long = PromptWriter.material({ passage = string.rep("a", 9000),
        around = { before = string.rep("b", 3000), after = string.rep("c", 3000) } })
    TestRunner:assert(#long < 6200, "passage and the text around are capped: " .. #long)
    -- the text around: chat's own most a side, so never more in all than its hard cap
    local side = math.floor(require("koassistant.request.scope_resolver").MAX_CONTEXT_CHARS / 2)
    TestRunner:assert(has(long, "<before>…" .. string.rep("b", side) .. "</before>"), "the end of the text before")
    TestRunner:assert(has(long, "<after>" .. string.rep("c", side) .. "…</after>"), "the start of the text after")
end)
TestRunner:test("material for an X-Ray entry: the entry to draw instead of a passage", function()
    local m = PromptWriter.material({ entry = { name = "Mara", type = "person", description = "A red scarf." },
        style = "a book illustration" })
    TestRunner:assert(has(m, '<entry_to_draw name="Mara" type="person">A red scarf.</entry_to_draw>'), m)
    TestRunner:assert(not has(m, "<passage>"), m)
end)

print("  [The answer and the provenance]")
TestRunner:test("finish: the paragraph, cleaned, with the no-text line", function()
    local p = PromptWriter.finish('```\nPrompt: "A tall man on black rocks at dusk."\n```')
    TestRunner:assertEquals(p, "A tall man on black rocks at dusk. " .. PromptWriter.NO_TEXT)
    p = PromptWriter.finish("A girl in a red scarf\nruns down the path.")
    TestRunner:assertEquals(p, "A girl in a red scarf runs down the path. " .. PromptWriter.NO_TEXT, "one paragraph")
    local none, why = PromptWriter.finish("   ")
    TestRunner:assertEquals(none, nil)
    TestRunner:assertEquals(why, "empty")
    none, why = PromptWriter.finish(string.rep("word ", 500))
    TestRunner:assertEquals(none, nil)
    TestRunner:assertEquals(why, "too_long")
    TestRunner:assertEquals(PromptWriter.finish(nil), nil)
end)
TestRunner:test("provenance: who wrote it and from what; what privacy left out", function()
    local line = PromptWriter.provenance({ model = "claude-fast", around = true,
        entries = { { name = "Mara" }, { name = "Elias Morrow" } }, book = "both", background = true, note = true })
    TestRunner:assertEquals(line, "Prompt written by claude-fast from: the passage, the text around it, "
        .. "the X-Ray entries for Mara, Elias Morrow, the book's title and author, the book's Background, your note.")
    line = PromptWriter.provenance({ model = "m", entries = { { name = "Mara" } }, book = "title",
        left_out = { "the text around the passage" } })
    TestRunner:assert(has(line, "the X-Ray entry for Mara, the book's title."), line)
    TestRunner:assert(has(line, "\nLeft out by your privacy settings: the text around the passage."), line)
    line = PromptWriter.provenance({ model = "m", entry = { name = "Mara" } })
    TestRunner:assertEquals(line, "Prompt written by m from: the X-Ray entry for Mara.")
    line = PromptWriter.provenance({ failed = PromptWriter.failureText("too_long") })
    TestRunner:assert(has(line, "The prompt writer failed (an answer too long for a prompt)"), line)
    TestRunner:assert(has(line, "from the passage as framed"), line)
    line = PromptWriter.provenance({ failed = "x", entry = { name = "Mara" } })
    TestRunner:assert(has(line, "from the entry's description"), "an entry has no passage: " .. line)
end)

print("  [the sweep of 2026-11-06: a name set to capitals only]")
TestRunner:test("entriesFor and the suggestions honour a capitals-only name, as the marks do", function()
    local XrayParser = require("koassistant.xray.xray_parser")
    local data = { type = "fiction", characters = {
        { name = "Will", role = "a boy", description = "A boy." },
        { name = "Anna", role = "his sister", description = "A girl." },
    } }
    XrayParser.mergeUserAliases(data, { Will = { case = { will = "capitals" } } })
    local function names(list)
        local out = {}
        for _i, e in ipairs(list) do out[#out + 1] = e.name end
        return table.concat(out, ",")
    end
    TestRunner:assertEquals(names(PromptWriter.entriesFor("Anna said she will go home.", data)), "Anna",
        "a lowercase will is not the boy")
    TestRunner:assertEquals(names(PromptWriter.entriesFor("Anna said Will went home.", data)), "Anna,Will",
        "the capitalized name is")
    local tiers = PromptWriter.pickerTiers(data, "Anna said she will go home.")
    TestRunner:assertEquals(names(tiers.suggested), "Anna", "the suggestions follow the same rule")
end)

print(string.format("  Results: %d passed, %d failed", TestRunner.passed, TestRunner.failed))
return TestRunner.failed == 0
