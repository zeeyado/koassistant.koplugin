-- Unit tests for koassistant_xray_parser.lua JSON extraction + shared unescaped-quote repair.

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

local XrayParser = require("koassistant_xray_parser")

local TestRunner = { passed = 0, failed = 0 }
function TestRunner:suite(name) print(string.format("\n  [%s]", name)) end
function TestRunner:test(name, fn)
    local ok, err = pcall(fn)
    if ok then self.passed = self.passed + 1; print("    ✓ " .. name)
    else self.failed = self.failed + 1; print("    ✗ " .. name); print("      Error: " .. tostring(err)) end
end
function TestRunner:ok(v, msg) if not v then error(msg or "expected truthy") end end
function TestRunner:eq(a, b, msg)
    if a ~= b then error(string.format("%s: expected %q, got %q", msg or "eq", tostring(b), tostring(a))) end
end

TestRunner:suite("XrayParser.parse — well-formed")
TestRunner:test("raw fiction JSON", function()
    local d = XrayParser.parse('{"characters":[{"name":"Jack","description":"a man"}]}')
    TestRunner:ok(d); TestRunner:ok(d.characters)
end)
TestRunner:test("fenced JSON", function()
    local d = XrayParser.parse('```json\n{"characters":[{"name":"Wendy","description":"his wife"}]}\n```')
    TestRunner:ok(d); TestRunner:ok(d.characters)
end)
TestRunner:test("JSON with leading thinking text + trailing prose", function()
    local d = XrayParser.parse('Here is the X-Ray:\n```json\n{"characters":[{"name":"Danny","description":"the son"}]}\n```\nHope that helps.')
    TestRunner:ok(d); TestRunner:ok(d.characters)
end)

TestRunner:suite("XrayParser.parse — unescaped inner quotes (shared repair)")
TestRunner:test("raw double quotes in a description are recovered", function()
    local txt = '```json\n{"characters":[{"name":"Jack","description":"He says "all work and no play" repeatedly, echoing the "spirit" of the hotel."}]}\n```'
    local d, e = XrayParser.parse(txt)
    TestRunner:ok(d, "should recover via repair: " .. tostring(e))
    TestRunner:ok(d.characters)
    TestRunner:ok(d.characters[1].description:find("all work and no play"), "description content preserved")
end)
TestRunner:test("repair does not corrupt valid X-Ray", function()
    local d = XrayParser.parse('{"key_figures":[{"name":"Kant","description":"a philosopher"}],"core_concepts":[]}')
    TestRunner:ok(d); TestRunner:ok(d.key_figures)
end)

TestRunner:suite("bare-key repair (2026-08-25 large-text bench failure)")
TestRunner:test("a key missing its opening quote is recovered", function()
    local txt = '{\n  "characters": [\n    {"name": "Alice", "description": "a girl"}\n  ],\n  "conclusion": {\n    themes_resolved": ["pride"]\n  }\n}'
    local d, e = XrayParser.parse(txt)
    TestRunner:ok(d, "should recover via bare-key repair: " .. tostring(e))
    TestRunner:ok(d and d.conclusion and d.conclusion.themes_resolved, "the repaired key is present")
end)
TestRunner:test("a fully unquoted key before a structural value is recovered", function()
    local txt = '{\n  characters: [\n    {"name": "Alice", "description": "a girl"}\n  ]\n}'
    local d = XrayParser.parse(txt)
    TestRunner:ok(d and d.characters and d.characters[1].name == "Alice")
end)
TestRunner:test("line-anchored: identifiers inside string values are untouched", function()
    local JsonRepair = require("koassistant_json_repair")
    local s = '{"characters":[{"name":"Alice","description":"she said\nquote\": no"}]}'
    TestRunner:eq(JsonRepair.quoteBareKeys('{"a": 1}'), '{"a": 1}')
    -- A bare word at line start followed by `":` IS the defect shape; inside a
    -- value it can only appear after a newline the model put in the string,
    -- which strict parsing already rejects. Valid JSON is never changed:
    local valid = '{\n  "name": "x",\n  "list": ["a", "b"]\n}'
    TestRunner:eq(JsonRepair.quoteBareKeys(valid), valid)
    TestRunner:ok(#JsonRepair.quoteBareKeys(s) >= #s)
end)

TestRunner:suite("round 28 — parse-time shape normalization (#90 field report)")
TestRunner:test("timeline of plain strings becomes {event} objects (fixes 'Unknown' rows)", function()
    local d = XrayParser.parse('{"characters":[{"name":"Jack"}],"timeline":["Jack arrives","The snow falls"]}')
    TestRunner:ok(d)
    TestRunner:eq(d.timeline[1].event, "Jack arrives")
    TestRunner:eq(XrayParser.getItemName(d.timeline[2], "timeline"), "The snow falls")
end)
TestRunner:test("connection objects coerce to 'Name (relationship)' strings", function()
    local d = XrayParser.parse('{"characters":[{"name":"Jack","connections":[{"name":"Wendy","relationship":"wife"},"Danny (son)"]}]}')
    TestRunner:ok(d)
    TestRunner:eq(d.characters[1].connections[1], "Wendy (wife)")
    TestRunner:eq(d.characters[1].connections[2], "Danny (son)")
end)
TestRunner:test("alias objects and numeric fields coerce; render survives (crash.log shape)", function()
    local d = XrayParser.parse('{"characters":[{"name":"Jack","role":{"description":"Protagonist"},"aliases":[{"name":"The Caretaker"}]}],"current_state":{"summary":{"text":"Deep winter"},"conflicts":[{"name":"Cabin fever"}]}}')
    TestRunner:ok(d)
    TestRunner:eq(d.characters[1].role, "Protagonist")
    TestRunner:eq(d.characters[1].aliases[1], "The Caretaker")
    TestRunner:eq(d.current_state.summary, "Deep winter")
    TestRunner:eq(d.current_state.conflicts[1], "Cabin fever")
    local ok, md = pcall(XrayParser.renderToMarkdown, d, "The Overlook", "35%")
    TestRunner:ok(ok, "render must not crash: " .. tostring(md))
    TestRunner:ok(md:find("The Caretaker", 1, true), "alias rendered")
end)
TestRunner:test("map-instead-of-array category salvaged, keys become names", function()
    local d = XrayParser.parse('{"characters":{"Jack":{"role":"Protagonist"},"Wendy":{"role":"Supporting"}}}')
    TestRunner:ok(d)
    TestRunner:eq(#d.characters, 2)
    TestRunner:eq(d.characters[1].name, "Jack") -- sorted for stability
end)
TestRunner:test("string current_state becomes {summary}; background arrays keep their shape", function()
    local d = XrayParser.parse('{"characters":[{"name":"Jack","background":[{"source":"Vol 1","text":"He was a teacher.","file":"/books/v1.epub"},{"bogus":true}]}],"current_state":"All is calm."}')
    TestRunner:ok(d)
    TestRunner:eq(d.current_state.summary, "All is calm.")
    TestRunner:eq(#d.characters[1].background, 1, "malformed background line dropped")
    TestRunner:eq(d.characters[1].background[1].file, "/books/v1.epub")
end)

TestRunner:suite("round 28 — hasEntityContent / dropModelBackground / merge belt")
TestRunner:test("hasEntityContent: lone current_state is NOT a usable create", function()
    local d = XrayParser.parse('{"current_state":{"summary":"Nine years past, at the northern front..."}}')
    TestRunner:ok(d, "current_state-only still parses")
    TestRunner:ok(not XrayParser.hasEntityContent(d), "but holds no entity content")
    local d2 = XrayParser.parse('{"characters":[{"name":"Almark"}]}')
    TestRunner:ok(XrayParser.hasEntityContent(d2))
end)
TestRunner:test("dropModelBackground strips echoed background from a response", function()
    local d = XrayParser.parse('{"characters":[{"name":"Jack","background":[{"source":"Vol 4","text":"echoed junk"}]}]}')
    XrayParser.dropModelBackground(d)
    TestRunner:eq(d.characters[1].background, nil)
end)
TestRunner:test("merge: a rewrite carrying background NEVER replaces the stored lines", function()
    local old = XrayParser.parse('{"characters":[{"name":"Jack","description":"old","background":[{"source":"Vol 1","text":"mechanical truth"}]}]}')
    local new = XrayParser.parse('{"characters":[{"name":"Jack","description":"new","background":[{"source":"Vol 4","text":"model echo"}]}]}')
    local merged = XrayParser.merge(old, new)
    TestRunner:eq(merged.characters[1].description, "new", "rewrite lands")
    TestRunner:eq(#merged.characters[1].background, 1)
    TestRunner:eq(merged.characters[1].background[1].text, "mechanical truth")
end)

TestRunner:suite("rename fold — reverse-alias bridge (device case 2026-08-14)")
TestRunner:test("new entry bridging an old primary name folds as a rename", function()
    local old = XrayParser.parse('{"characters":[{"name":"Mara Ellison","role":"Supporting","description":"old text","connections":["Tomas Cole (husband)"],"background":[{"source":"Vol 1","text":"kept"}]}]}')
    local new = XrayParser.parse('{"characters":[{"name":"Mara Cole","aliases":["Mara Ellison"],"description":"new text","connections":["Jules Renn (lover)"]}]}')
    local merged = XrayParser.merge(old, new)
    TestRunner:eq(#merged.characters, 1, "one entity, not a split")
    TestRunner:eq(merged.characters[1].name, "Mara Cole", "new name is primary")
    TestRunner:eq(merged.characters[1].description, "new text")
    local aliases = table.concat(merged.characters[1].aliases or {}, "|")
    TestRunner:ok(aliases:find("Mara Ellison", 1, true) ~= nil, "old name rides in aliases")
    local conns = table.concat(merged.characters[1].connections or {}, "|")
    TestRunner:ok(conns:find("Tomas Cole", 1, true) ~= nil, "old connections union in")
    TestRunner:ok(conns:find("Jules Renn", 1, true) ~= nil, "new connections lead")
    TestRunner:eq(merged.characters[1].background[1].text, "kept", "stored background survives the fold")
end)
TestRunner:test("fold union: bare connection yields to the annotated variant", function()
    local old = XrayParser.parse('{"characters":[{"name":"Mara Ellison","connections":["Tomas Cole (husband)"]}]}')
    local new = XrayParser.parse('{"characters":[{"name":"Mara Cole","aliases":["Mara Ellison"],"connections":["Tomas Cole","Jules Renn"]}]}')
    local merged = XrayParser.merge(old, new)
    local conns = merged.characters[1].connections
    TestRunner:eq(#conns, 2, "bare duplicate dropped")
    local joined = table.concat(conns, "|")
    TestRunner:ok(joined:find("Tomas Cole (husband)", 1, true) ~= nil, "annotated variant survives")
    TestRunner:ok(joined:find("Jules Renn", 1, true) ~= nil)
end)
TestRunner:test("single-word bridge does NOT fold (short-form collision guard)", function()
    local old = XrayParser.parse('{"characters":[{"name":"Zed","description":"a porter"}]}')
    local new = XrayParser.parse('{"characters":[{"name":"Zed Amari","aliases":["Zed"],"description":"a general"}]}')
    local merged = XrayParser.merge(old, new)
    TestRunner:eq(#merged.characters, 2, "appended, dedup-scan material")
end)
TestRunner:test("ambiguous bridge (two old entries matched) does NOT fold", function()
    local old = XrayParser.parse('{"characters":[{"name":"Mara Ellison"},{"name":"Mara Quinn"}]}')
    local new = XrayParser.parse('{"characters":[{"name":"Mara Cole","aliases":["Mara Ellison","Mara Quinn"]}]}')
    local merged = XrayParser.merge(old, new)
    TestRunner:eq(#merged.characters, 3, "appended on ambiguity")
end)
TestRunner:test("never-merge pair blocks the fold", function()
    local old = XrayParser.parse('{"characters":[{"name":"Mara Ellison"}]}')
    local new = XrayParser.parse('{"characters":[{"name":"Mara Cole","aliases":["Mara Ellison"]}]}')
    local merged = XrayParser.merge(old, new,
        { never_pairs = { { "Mara Cole", "Mara Ellison" } } })
    TestRunner:eq(#merged.characters, 2, "reader ruling wins over the bridge")
end)
TestRunner:test("forward alias match still wins over the rename fold", function()
    -- Delta re-emits a stored alias as its main name: identity stays the
    -- old entry's (the 2026-08-09 rule), rename fold must not interfere
    local old = XrayParser.parse('{"characters":[{"name":"Mara Cole","aliases":["Mara Ellison"],"description":"kept identity"}]}')
    local new = XrayParser.parse('{"characters":[{"name":"Mara Ellison","description":"rewrite"}]}')
    local merged = XrayParser.merge(old, new)
    TestRunner:eq(#merged.characters, 1)
    TestRunner:eq(merged.characters[1].name, "Mara Cole", "primary name preserved")
end)

TestRunner:suite("round 28 — mergeBackground file identity")
TestRunner:test("same file under two drifted labels collapses to one line", function()
    local merged = XrayParser.mergeBackground(
        { { source = "アルマーク４　武術大会編", text = "old", file = "/b/v4.epub" } },
        { { source = "アルマーク 04 武術大会編 (MFブックス)", text = "new", file = "/b/v4.epub" } })
    TestRunner:eq(#merged, 1)
    TestRunner:eq(merged[1].text, "new")
end)
TestRunner:test("legacy line gains the file key from its successor; label-only still dedupes", function()
    local merged = XrayParser.mergeBackground(
        { { source = "Vol 1", text = "old" } },
        { { source = "Vol 1", text = "new", file = "/b/v1.epub" } })
    TestRunner:eq(#merged, 1)
    TestRunner:eq(merged[1].file, "/b/v1.epub")
    TestRunner:eq(merged[1].text, "new")
end)
TestRunner:test("two DIFFERENT files sharing one label stay separate", function()
    local merged = XrayParser.mergeBackground(
        { { source = "Collected", text = "a", file = "/b/one.epub" } },
        { { source = "Collected", text = "b", file = "/b/two.epub" } })
    TestRunner:eq(#merged, 2)
end)

TestRunner:suite("round 28 — isEmptyDelta (no-overlap merges are an ANSWER)")
TestRunner:test("content-free JSON is recognized, in every shape a model emits", function()
    for _idx, s in ipairs({ "{}", '{"background_updates": []}', '{"characters": []}',
        '```json\n{"background_updates": []}\n```', '{"background_updates": [], "characters": []}' }) do
        TestRunner:ok(XrayParser.isEmptyDelta(s), "empty: " .. s:gsub("\n", "\\n"))
    end
end)
TestRunner:test("anything with real content is NOT empty", function()
    for _idx, s in ipairs({ '{"background_updates": [{"name":"X","background":"y"}]}',
        '{"characters":[{"name":"Jack"}]}', '{"error":"I cannot do this"}',
        "These two books share nothing.", "" }) do
        TestRunner:ok(not XrayParser.isEmptyDelta(s), "not empty: " .. s)
    end
end)
TestRunner:test("the empty delta the merge prompt asks for still PARSES as valid data", function()
    -- Both facts matter: parse() accepts it (so a merge that returns it is not
    -- an error), and isEmptyDelta flags it (so the caller reports "no overlap")
    local d = XrayParser.parse('{"background_updates": []}')
    TestRunner:ok(d, "parses")
    TestRunner:ok(XrayParser.isEmptyDelta('{"background_updates": []}'), "and is flagged empty")
end)

TestRunner:suite("round 28 — stripForPromptJSON")
TestRunner:test("background and dormant stripped; entities and state kept", function()
    local src = '{"characters":[{"name":"Jack","description":"kept","background":[{"source":"Vol 1","text":"hidden"}]}],"current_state":{"summary":"kept"},"__dormant":[{"name":"Ghost","category":"characters"}]}'
    local out = XrayParser.stripForPromptJSON(src)
    TestRunner:ok(not out:find("hidden", 1, true), "background gone")
    TestRunner:ok(not out:find("__dormant", 1, true), "ledger gone")
    TestRunner:ok(out:find("kept", 1, true), "content kept")
end)
TestRunner:test("prose and background-free JSON pass through untouched", function()
    local prose = "This recap has a background section in prose."
    TestRunner:eq(XrayParser.stripForPromptJSON(prose), prose)
    local plain = '{"characters":[{"name":"Jack"}]}'
    TestRunner:eq(XrayParser.stripForPromptJSON(plain), plain)
end)

TestRunner:suite("2026-08-09 — alias-aware delta merge (rename/dedup hardening)")
TestRunner:test("delta re-emitting an alias folds into the entry, identity kept", function()
    local old = { characters = { { name = "Andrew", aliases = { "Andy" },
        description = "old", background = { { source = "Vol 1", text = "b" } } } } }
    local new = { characters = { { name = "Andy", description = "new" } } }
    local merged = XrayParser.merge(old, new)
    TestRunner:eq(#merged.characters, 1, "no duplicate created")
    TestRunner:eq(merged.characters[1].name, "Andrew", "main name preserved")
    TestRunner:eq(merged.characters[1].description, "new", "content updated")
    TestRunner:ok(merged.characters[1].background, "background carried")
    TestRunner:eq(merged.characters[1].aliases[1], "Andy", "alias set survives")
end)
TestRunner:test("a main name always beats another entry's alias", function()
    local old = { characters = {
        { name = "Bob", description = "1" },
        { name = "Carl", aliases = { "Bob" }, description = "2" } } }
    local new = { characters = { { name = "Bob", description = "upd" } } }
    local merged = XrayParser.merge(old, new)
    TestRunner:eq(#merged.characters, 2, "both entries live")
    TestRunner:eq(merged.characters[1].description, "upd", "real Bob updated")
    TestRunner:eq(merged.characters[2].description, "2", "Carl untouched")
end)
TestRunner:test("stored aliases survive a rewrite that drops them", function()
    local old = { characters = { { name = "Ana", aliases = { "The Girl" }, description = "o" } } }
    local new = { characters = { { name = "Ana", description = "n" } } }
    local merged = XrayParser.merge(old, new)
    TestRunner:eq(merged.characters[1].aliases[1], "The Girl", "absorbed alias kept")
end)
TestRunner:test("an unknown name still appends", function()
    local old = { characters = { { name = "Ana", description = "o" } } }
    local new = { characters = { { name = "Zed", description = "z" } } }
    local merged = XrayParser.merge(old, new)
    TestRunner:eq(#merged.characters, 2, "appended")
end)

TestRunner:suite("2026-08-09 — renameItem (Manage ▸ Rename)")
TestRunner:test("renames and pushes the old name onto the front of aliases", function()
    local data = { characters = { { name = "Andy", aliases = { "kid" }, description = "d" } } }
    TestRunner:ok(XrayParser.renameItem(data, "characters", "Andy", "Andrew"))
    TestRunner:eq(data.characters[1].name, "Andrew")
    TestRunner:eq(data.characters[1].aliases[1], "Andy")
    TestRunner:eq(data.characters[1].aliases[2], "kid")
end)
TestRunner:test("the new name stops being an alias of itself", function()
    local data = { characters = { { name = "Andy", aliases = { "Andrew" } } } }
    TestRunner:ok(XrayParser.renameItem(data, "characters", "Andy", "Andrew"))
    TestRunner:eq(data.characters[1].name, "Andrew")
    TestRunner:eq(#data.characters[1].aliases, 1)
    TestRunner:eq(data.characters[1].aliases[1], "Andy")
end)
TestRunner:test("ambiguous names are refused", function()
    local data = { characters = { { name = "Andy" }, { name = "Andy" } } }
    TestRunner:ok(not XrayParser.renameItem(data, "characters", "Andy", "Andrew"))
end)
TestRunner:test("missing name / same name are refused", function()
    local data = { characters = { { name = "Andy" } } }
    TestRunner:ok(not XrayParser.renameItem(data, "characters", "Nobody", "X"))
    TestRunner:ok(not XrayParser.renameItem(data, "characters", "Andy", "Andy"))
end)
TestRunner:test("term-named categories rename their term field", function()
    local data = { technical_terms = { { term = "Grok", description = "d" } } }
    TestRunner:ok(XrayParser.renameItem(data, "technical_terms", "Grok", "Grokking"))
    TestRunner:eq(data.technical_terms[1].term, "Grokking")
    TestRunner:eq(data.technical_terms[1].aliases[1], "Grok")
end)

TestRunner:suite("2026-08-09 — addItemAliases (Manage ▸ Link)")
TestRunner:test("adds missing handles, dedupes case-insensitively, skips own name", function()
    local data = { characters = { { name = "Mira", aliases = { "The Keeper" } } } }
    TestRunner:ok(XrayParser.addItemAliases(data, "characters", "Mira",
        { "the keeper", "Mira", "Mira Alvsund" }))
    TestRunner:eq(#data.characters[1].aliases, 2)
    TestRunner:eq(data.characters[1].aliases[2], "Mira Alvsund")
end)
TestRunner:test("found-but-nothing-new still reports ok (link already recorded)", function()
    local data = { characters = { { name = "Mira", aliases = { "The Keeper" } } } }
    TestRunner:ok(XrayParser.addItemAliases(data, "characters", "Mira", { "The Keeper" }))
    TestRunner:eq(#data.characters[1].aliases, 1)
end)
TestRunner:test("ambiguous and missing names are refused", function()
    local data = { characters = { { name = "Ana" }, { name = "Ana" } } }
    TestRunner:ok(not XrayParser.addItemAliases(data, "characters", "Ana", { "X" }))
    TestRunner:ok(not XrayParser.addItemAliases(data, "characters", "Nobody", { "X" }))
end)

TestRunner:suite("slice 2 — foldExactHandles / matchExactHandle (route index)")
TestRunner:test("name and alias hit, case-insensitive; substrings do not", function()
    local data = { characters = { { name = "Elena Voss", aliases = { "The Master" } } } }
    local set = {}
    XrayParser.foldExactHandles(data, set)
    TestRunner:ok(XrayParser.matchExactHandle(set, "elena voss"))
    TestRunner:ok(XrayParser.matchExactHandle(set, "THE MASTER"))
    TestRunner:ok(not XrayParser.matchExactHandle(set, "Voss"))
    TestRunner:ok(not XrayParser.matchExactHandle(set, "of"))
    TestRunner:ok(not XrayParser.matchExactHandle(set, ""))
end)
TestRunner:test("singleton categories are skipped", function()
    local data = { current_state = { { name = "Reading chapter 3" } } }
    local set = {}
    XrayParser.foldExactHandles(data, set)
    TestRunner:ok(not XrayParser.matchExactHandle(set, "Reading chapter 3"))
end)
TestRunner:test("parenthetical-stripped variant folds (marked text = selectable text)", function()
    -- Device 2026-08-14: "Signal fire (beacon)" was marked as
    -- "Poison container" (collectSearchTerms strips the parenthetical) but
    -- selecting those words missed the raw-handle-only route index
    local data = { locations = { { name = "Signal fire (beacon)" } } }
    local set = {}
    XrayParser.foldExactHandles(data, set)
    TestRunner:ok(XrayParser.matchExactHandle(set, "signal fire"))
    TestRunner:ok(XrayParser.matchExactHandle(set, "Signal fire (beacon)"))
    TestRunner:ok(XrayParser.matchExactHandle(set, "  signal   fire "))
    TestRunner:ok(not XrayParser.matchExactHandle(set, "beacon"))
end)
TestRunner:test("Arabic: article-stripped QUERY matches unstripped handle (searchAll parity)", function()
    local data = { characters = { { name = "نجمة" } } }
    local set = {}
    XrayParser.foldExactHandles(data, set)
    -- query "النجمة" strips to "نجمة" (query side only, like searchAll exact)
    TestRunner:ok(XrayParser.matchExactHandle(set, "النجمة"))
    -- handle side is never stripped: handle "النار" does not match query "نار"
    local set2 = {}
    XrayParser.foldExactHandles({ characters = { { name = "النار" } } }, set2)
    TestRunner:ok(not XrayParser.matchExactHandle(set2, "نار"))
end)

TestRunner:suite("B266 — cross-entity containment")
local B266_DATA = {
    characters = {
        { name = "Stanley Kubrick", aliases = { "Kubrick" } },
        { name = "Vivian Kubrick" },
        { name = "Christiane Kubrick", aliases = { "Mrs. Kubrick" } },
        { name = "Jack" },
    },
    timeline = { { event = "Kubrick Estate sale" } }, -- excluded category
}
TestRunner:test("containingHandles: other entities' longer handles, own forms excluded", function()
    local h = XrayParser.containingHandles(B266_DATA, B266_DATA.characters[1])
    local set = {}
    for _i, x in ipairs(h) do set[x] = true end
    TestRunner:ok(set["vivian kubrick"])
    TestRunner:ok(set["christiane kubrick"])
    TestRunner:ok(set["mrs. kubrick"])
    TestRunner:ok(not set["stanley kubrick"]) -- own long form
    TestRunner:ok(not set["kubrick estate sale"]) -- timeline never counts
    TestRunner:eq(XrayParser.containingHandles(B266_DATA, B266_DATA.characters[4]), nil)
end)
TestRunner:test("countItemOccurrences: hits inside a longer handle are the other entity's", function()
    local text = "kubrick spoke. vivian kubrick filmed it, and christiane kubrick painted. kubrick left."
    local item = B266_DATA.characters[1]
    TestRunner:eq(XrayParser.countItemOccurrences(item, text), 4)
    TestRunner:eq(XrayParser.countItemOccurrences(item, text,
        XrayParser.containingHandles(B266_DATA, item)), 2)
    -- The longer entity keeps its own count
    TestRunner:eq(XrayParser.countItemOccurrences(B266_DATA.characters[2], text), 1)
end)
TestRunner:test("hitInsideHandle: prev/next context completes the handle at word boundaries", function()
    local handles = { "vivian kubrick", "mrs. kubrick" }
    TestRunner:ok(XrayParser.hitInsideHandle("and Vivian", "Kubrick", "filmed it", handles))
    TestRunner:ok(XrayParser.hitInsideHandle("Mrs.", "Kubrick", "painted", handles))
    TestRunner:ok(not XrayParser.hitInsideHandle("director", "Kubrick", "left", handles))
    -- "Olivian Kubrick" does not spell "Vivian Kubrick"
    TestRunner:ok(not XrayParser.hitInsideHandle("Olivian", "Kubrick", "", handles))
    TestRunner:ok(not XrayParser.hitInsideHandle(nil, "Kubrick", nil, handles))
    TestRunner:ok(not XrayParser.hitInsideHandle("Vivian", "Kubrick", "", nil))
end)

TestRunner:suite("slice 2 — collectSearchTerms / buildMarkEntities")
TestRunner:test("terms: parenthetical strip, dedupe, substring-minimal set", function()
    local terms, dropped = XrayParser.collectSearchTerms({
        name = "Jean Valjean", aliases = { "Valjean", "Theosis (Deification)" } })
    local texts = {}
    for _i, t in ipairs(terms) do texts[t.text] = true end
    TestRunner:ok(texts["Valjean"])
    TestRunner:ok(not texts["Jean Valjean"]) -- contains "Valjean", dropped
    TestRunner:ok(texts["Theosis"])
    -- The dropped longer variant rides the second return (for span painting)
    TestRunner:eq(#dropped, 1)
    TestRunner:eq(dropped[1].text, "Jean Valjean")
end)
TestRunner:test("mark entities: dropped long variants included, longest-first", function()
    -- A short alias contained in the full name: counting keeps only the
    -- short form, but the MARKS term set must carry the full name first so
    -- the widest form present at an occurrence is the one that paints
    local data = {
        characters = { { name = "Corvan Aldous Merek", aliases = { "Aldous" } } },
    }
    local ents = XrayParser.buildMarkEntities(data)
    TestRunner:eq(#ents, 1)
    local texts = {}
    for _i, t in ipairs(ents[1].terms) do texts[#texts + 1] = t.text end
    TestRunner:eq(#texts, 2)
    TestRunner:eq(texts[1], "Corvan Aldous Merek")
    TestRunner:eq(texts[2], "Aldous")
    -- Long variant carries a presence-check norm like every other term
    TestRunner:eq(ents[1].terms[1].norm, "corvan aldous merek")
end)
TestRunner:test("suggestAliasTargets: word overlap ranks, excluded cats out (ref #63)", function()
    local data = {
        characters = { { name = "Mara Ellison", aliases = { "Mara" } }, { name = "Tomas Cole" } },
        timeline = { { event = "Mara arrives" } },
    }
    local s = XrayParser.suggestAliasTargets(data, "Mara Cole", 6)
    TestRunner:eq(#s, 2)
    TestRunner:eq(s[1].item.name, "Mara Ellison") -- shared given name ranks first
    TestRunner:eq(s[2].item.name, "Tomas Cole")   -- shared surname second
    -- The timeline event containing "Mara" is never a target
    -- A fully novel single-word handle gives no signal
    TestRunner:eq(#XrayParser.suggestAliasTargets(data, "Quorra"), 0)
end)
TestRunner:test("mark entities: families mapped, excluded categories out, norms present", function()
    local data = {
        characters = { { name = "Mira", description = "d" } },
        locations = { { name = "Oslo" } },
        timeline = { { event = "Mira arrives in Oslo" } },
    }
    local ents = XrayParser.buildMarkEntities(data)
    local by_name = {}
    for _i, e in ipairs(ents) do by_name[e.name] = e end
    TestRunner:ok(by_name["Mira"] and by_name["Mira"].family == "people")
    TestRunner:ok(by_name["Oslo"] and by_name["Oslo"].family == "places")
    TestRunner:ok(not by_name["Mira arrives in Oslo"]) -- timeline excluded
    TestRunner:eq(by_name["Mira"].terms[1].norm, "mira")
end)

TestRunner:suite("sanitizeEntries — weak-model schema garbage (2026-08-15 A0)")
TestRunner:test("foreign-schema/no-content entries dropped, legit sparse entries kept", function()
    local d = {
        characters = {
            { name = "Jack", description = "a man" },                       -- keep: content
            { name = "Wendy", role = "his wife" },                          -- keep: role counts
            { name = "GHOST_A", relationships = {}, current_position = "hall",
              current_state = "fiction" },                                  -- drop: zero content fields
            { name = "Hollow", aliases = { "H" } },                         -- drop: aliases don't count
        },
        locations = {
            { name = "Overlook", significance = "the hotel" },              -- keep
            { name = "BARE_PLACE" },                                        -- drop: name only
        },
    }
    local dropped = XrayParser.sanitizeEntries(d)
    TestRunner:eq(dropped, 3, "dropped count")
    TestRunner:eq(#d.characters, 2, "characters kept")
    TestRunner:eq(d.characters[1].name, "Jack", "order preserved 1")
    TestRunner:eq(d.characters[2].name, "Wendy", "order preserved 2")
    TestRunner:eq(#d.locations, 1, "locations kept")
end)
TestRunner:test("missing/empty name field drops regardless of content", function()
    local d = { characters = {
        { description = "orphaned description with no name" },
        { name = "", description = "empty name" },
        { name = "Danny", description = "the son" },
    } }
    TestRunner:eq(XrayParser.sanitizeEntries(d), 2, "two dropped")
    TestRunner:eq(#d.characters, 1, "one kept")
end)
TestRunner:test("event lists keep name-only entries; term categories use their fields", function()
    local d = {
        type = "fiction",  -- classify: lexicon/timeline are fiction categories
        timeline = { { event = "The family arrives", chapter = "1" } },     -- keep: event IS content
        lexicon = {
            { term = "shining", definition = "the gift" },                  -- keep
            { term = "bare_term" },                                         -- drop: no definition/content
        },
    }
    TestRunner:eq(XrayParser.sanitizeEntries(d), 1, "one dropped")
    TestRunner:eq(#d.timeline, 1, "timeline untouched")
    TestRunner:eq(#d.lexicon, 1, "lexicon garbage dropped")
end)
TestRunner:test("connections-only entries count as content; arrays checked non-empty", function()
    local d = { characters = {
        { name = "Linked", connections = { "Jack" } },                      -- keep: array content
        { name = "Empty", connections = {} },                               -- drop: empty array
    } }
    TestRunner:eq(XrayParser.sanitizeEntries(d), 1, "one dropped")
    TestRunner:eq(d.characters[1].name, "Linked", "connections-only kept")
end)
TestRunner:test("singletons and the dormant ledger are untouched", function()
    local d = {
        characters = { { name = "Jack", description = "a man" } },
        current_state = { summary = "mid-book" },
        conclusion = { summary = "the end" },
        [XrayParser.DORMANT_KEY] = { { name = "Carried", category = "characters" } },
    }
    TestRunner:eq(XrayParser.sanitizeEntries(d), 0, "nothing dropped")
    TestRunner:ok(d.current_state and d.current_state.summary == "mid-book", "current_state intact")
    TestRunner:ok(d.conclusion and d.conclusion.summary == "the end", "conclusion intact")
    TestRunner:eq(#d[XrayParser.DORMANT_KEY], 1, "dormant ledger intact")
end)

TestRunner:suite("merge — direct-name-match relational union (staleness F2a)")
TestRunner:test("re-emit under the SAME name unions connections and keeps references", function()
    local old = XrayParser.parse('{"characters":[{"name":"Mara Cole","description":"old text","connections":["Tomas Cole (husband)"],"references":["Doc 1"]}]}')
    local new = XrayParser.parse('{"characters":[{"name":"Mara Cole","description":"revised: now leads the expedition","connections":["Jules Renn (rival)"]}]}')
    local merged = XrayParser.merge(old, new)
    local c = merged.characters[1]
    TestRunner:eq(c.description, "revised: now leads the expedition", "new description wins")
    local joined = table.concat(c.connections, "|")
    TestRunner:ok(joined:find("Tomas Cole", 1, true), "old connection survives the rewrite")
    TestRunner:ok(joined:find("Jules Renn", 1, true), "new connection added")
    TestRunner:ok(c.references and c.references[1] == "Doc 1", "references survive when the delta omits the key")
end)
TestRunner:test("union dedupes an identical connection string", function()
    local old = XrayParser.parse('{"characters":[{"name":"Mara Cole","description":"old","connections":["Tomas Cole (husband)"]}]}')
    local new = XrayParser.parse('{"characters":[{"name":"Mara Cole","description":"new","connections":["Tomas Cole (husband)"]}]}')
    local merged = XrayParser.merge(old, new)
    TestRunner:eq(#merged.characters[1].connections, 1, "no doubling on echo")
end)
TestRunner:test("delta omitting connections leaves the old array intact", function()
    local old = XrayParser.parse('{"characters":[{"name":"Mara Cole","description":"old","connections":["Tomas Cole (husband)","Jules Renn (rival)"]}]}')
    local new = XrayParser.parse('{"characters":[{"name":"Mara Cole","description":"status changed: injured"}]}')
    local merged = XrayParser.merge(old, new)
    local c = merged.characters[1]
    TestRunner:eq(c.description, "status changed: injured", "revision applied")
    TestRunner:eq(#c.connections, 2, "connections kept whole")
end)

print("")
print("\n  [dropExtraClosers - stray-closer repair (state.lua:81 class)]")

TestRunner:test("doubled final closer is dropped and the result parses", function()
    local JR = require("koassistant_json_repair")
    TestRunner:eq(JR.dropExtraClosers('{"characters":[{"name":"A","description":"d"}]}}'),
        '{"characters":[{"name":"A","description":"d"}]}', "final stray } dropped")
    local parsed = XrayParser.parse('```json\n{"characters":[{"name":"A","description":"d"}]}}\n```')
    TestRunner:eq(parsed ~= nil, true, "parse recovers via the stray-closer repair")
    TestRunner:eq(parsed.characters[1].name, "A", "content intact")
end)

TestRunner:test("stray closer mid-document is dropped", function()
    local JR = require("koassistant_json_repair")
    local fixed = JR.dropExtraClosers('{"a":[{"x":1}]],"b":[2]}')
    TestRunner:eq(fixed, '{"a":[{"x":1}],"b":[2]}', "mismatched ] dropped where it appears")
end)

TestRunner:test("closers inside strings and escapes are untouched", function()
    local JR = require("koassistant_json_repair")
    local text = '{"name":"A }] \\" x","d":"]] }"}'
    TestRunner:eq(JR.dropExtraClosers(text), text, "string content never counts as structure")
end)

TestRunner:test("balanced input is byte-identical; missing closers are not papered over", function()
    local JR = require("koassistant_json_repair")
    local good = '{"characters":[{"name":"A"}]}'
    TestRunner:eq(JR.dropExtraClosers(good), good, "no-op on balanced input")
    local truncated = '{"characters":[{"name":"A"}]'
    TestRunner:eq(JR.dropExtraClosers(truncated), truncated, "truncation left for the caller to see")
end)


print("\n  [closeUnclosed - under-closed complete document]")

TestRunner:test("complete document missing its final brace recovers", function()
    local JR = require("koassistant_json_repair")
    local txt = '{"type":"fiction","characters":[{"name":"A","description":"d"}],"current_state":{"summary":"s","questions":["q?"]}'
    TestRunner:eq(JR.closeUnclosed(txt), txt .. "}", "one missing } appended")
    local parsed = XrayParser.parse(txt)
    TestRunner:eq(parsed ~= nil, true, "parse recovers the under-closed response")
    TestRunner:eq(parsed.characters[1].name, "A", "content intact")
end)

TestRunner:test("several missing closers append innermost first", function()
    local JR = require("koassistant_json_repair")
    TestRunner:eq(JR.closeUnclosed('{"a":[{"x":"y"}'), '{"a":[{"x":"y"}]}', "]} appended in order")
end)

TestRunner:test("true truncation still fails: mid-string, after comma, after colon, mid-number", function()
    local JR = require("koassistant_json_repair")
    for _i, cut in ipairs({
        '{"characters":[{"name":"A","description":"cut mid sent',
        '{"characters":[{"name":"A"},',
        '{"characters":[{"name":',
        '{"count": 12',
    }) do
        TestRunner:eq(JR.closeUnclosed(cut), cut, "not papered over: " .. cut:sub(1, 30))
    end
end)

TestRunner:test("balanced input untouched", function()
    local JR = require("koassistant_json_repair")
    local good = '{"characters":[{"name":"A"}]}'
    TestRunner:eq(JR.closeUnclosed(good), good, "no-op when nothing is open")
end)

print(string.rep("-", 50))
print(string.format("  Results: %d passed, %d failed", TestRunner.passed, TestRunner.failed))
print(string.rep("-", 50))
return TestRunner.failed == 0
