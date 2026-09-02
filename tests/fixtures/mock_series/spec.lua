--[[
Mock X-Ray fixture SPEC (#90 cross-book lookup, docs/xray_cross_book_lookup_plan.md §6.2).

Pure data consumed by gen.lua. Seven tiny invented books in three folders (one
folder per group kind — the groups themselves are created BY HAND on the target
with "New group from folder…", which is itself an entry point under test):

  Mock Series/   3 fiction volumes, the main test bed (series group)
  Mock Project/  2 non-fiction siblings with a fold residue (project group)
  Mock Shelf/    2 unrelated books, the negative control (plain group)

Every name and title is invented; nothing references a real book.

Per book: `folder`, `filename`, `title`, `author`, `chapters` (title + `text`,
the hand-written sentences that carry the entity names, + `filler`, the number
of neutral filler paragraphs gen.lua appends so a chapter spans a few screens),
and the planted data: `xray` (JSON string + progress/meta), `ladder` (rungs),
`ring` (archived versions), `sections`, `aliases`, `sidecar` (DocSettings keys).

The __PATH:n__ placeholders inside JSON strings are replaced by gen.lua with
the FINAL (target) path of book n in this spec array — stub/background `file`
fields are path identity and must match where the books will actually live.

Entity matrix (vol 3 = book under test; live X-Ray covers 40%, one built rung
at 70%): see the plan doc §6.2. Short form:
  Tamsin Vael   live everywhere (control; carries a vol-1 background line)
  Gil Rook      vol-3-only, live (control)
  Orrin Blackwood  vol-3 ledger stub (src vol 2), ALSO active in the 70% rung
  Elias Penrose    vol-3 ledger stub (src vol 2); alias target ("the ferryman")
  Cass Merrow      vol-3 ledger stub with TRANSITIVE provenance (src vol 1)
  Fenna Quill      vol-3 ledger stub, never in vol-3 text (browser-only)
  Dorrit Hale      vol 2 active, DELIBERATELY absent from vol 3 (S2 tier)
  Zeph Umber       vol 1 active only, absent from vol 2 (S2 whole-chain tier)
  Hester Lune      70% rung only (ahead-only control)
  Saltmere         place, vol-3 ledger stub (family = places)
  Warden           vol-3 live LEXICON term + ledger CHARACTER stub (chooser)
  Vex              vol-3 ledger stub WITH alias "the grey cat" (alias hit)
]]

local V1 = "__PATH:1__"
local V2 = "__PATH:2__"

-- ---------------------------------------------------------------- X-Ray JSON
-- Hand-written, small, schema-shaped like real output (fiction: characters/
-- locations/themes/lexicon/timeline/current_state; nonfiction: key_figures/
-- core_concepts/terminology/...). Kept as Lua long strings; gen.lua validates
-- every one through the real XrayParser.parse before writing.

local VOL1_XRAY = [[{
  "type": "fiction",
  "characters": [
    {"name": "Tamsin Vael", "role": "Lantern keeper", "description": "Tamsin Vael keeps the harbor lantern and reads the tide ledgers. She is stubborn, careful, and owes the town nothing.", "connections": ["Cass Merrow (friend)"]},
    {"name": "Cass Merrow", "role": "Tide clerk", "description": "Cass Merrow records the tides and keeps Tamsin honest. Dry-witted, always cold."},
    {"name": "Zeph Umber", "role": "Salvage diver", "description": "Zeph Umber dives the drowned quarter for brass and bells. Appears in the last chapters and leaves without a goodbye."}
  ],
  "locations": [
    {"name": "Saltmere", "description": "Saltmere is the drowned market town across the bay, visited at low tide."}
  ],
  "themes": [
    {"name": "Keeping the light", "description": "Duty done in private, unthanked."}
  ],
  "lexicon": [],
  "timeline": [
    {"event": "Tamsin finds the cracked lens"},
    {"event": "Cass hides the tide ledger"}
  ],
  "conclusion": "The lantern stays lit; the ledger stays hidden."
}]]

local VOL2_XRAY = [[{
  "type": "fiction",
  "characters": [
    {"name": "Tamsin Vael", "role": "Lantern keeper", "description": "Tamsin Vael crosses to the ferry route this volume, still keeping the light from the far shore.", "background": [{"source": "Mock Series 1 - The Lantern", "text": "Kept the harbor lantern and read the tide ledgers.", "file": "]] .. V1 .. [["}]},
    {"name": "Orrin Blackwood", "role": "Ferry master", "description": "Orrin Blackwood runs the night ferry and never asks for fares twice. He knows every sandbar by sound.", "connections": ["Elias Penrose (deckhand)"]},
    {"name": "Elias Penrose", "role": "Deckhand", "description": "Elias Penrose poles the ferry through the shallows. The passengers call him the ferryman, though the title is Orrin's."},
    {"name": "Fenna Quill", "role": "Letter carrier", "description": "Fenna Quill rows the mail between the shore towns. Never late, never early."},
    {"name": "Dorrit Hale", "role": "Innkeeper", "description": "Dorrit Hale keeps the ferry inn and hears everything twice. She trades in small kindnesses."},
    {"name": "the Warden", "aliases": ["Warden"], "role": "Harbor official", "description": "The Warden inspects the ferry manifests and is never seen eating. First name unknown."},
    {"name": "Vex", "role": "Ship's cat", "aliases": ["the grey cat"], "description": "Vex, the grey cat, boards whichever boat is warmest and answers to no one."}
  ],
  "locations": [
    {"name": "Saltmere", "description": "Saltmere again, seen from the water this time; the ferry rounds it at slack tide."}
  ],
  "themes": [],
  "lexicon": [],
  "timeline": [
    {"event": "The night ferry runs aground"},
    {"event": "Dorrit closes the inn for the storm"}
  ],
  "conclusion": "The ferry route survives the season.",
  "__dormant": [
    {"name": "Cass Merrow", "category": "characters", "role": "Tide clerk", "description": "Cass Merrow records the tides and keeps Tamsin honest. Dry-witted, always cold.", "source": "Mock Series 1 - The Lantern", "file": "]] .. V1 .. [["}
  ]
}]]

-- Vol 3 LIVE artifact: covers to 40%. Ledger = the seed vol 2 would have given
-- it (actives + vol 2's own ledger riding transitively). Dorrit is deliberately
-- absent (the S2 predecessor tier must be the only way to find her); Zeph is
-- absent from vol 2 entirely (S2 whole-chain tier).
local VOL3_XRAY = [[{
  "type": "fiction",
  "characters": [
    {"name": "Tamsin Vael", "role": "Orchard warden", "description": "Tamsin Vael has come inland to mind the sea-orchard. She distrusts the quiet.", "background": [{"source": "Mock Series 1 - The Lantern", "text": "Kept the harbor lantern and read the tide ledgers.", "file": "]] .. V1 .. [["}]},
    {"name": "Gil Rook", "role": "Grafter", "description": "Gil Rook grafts the salt-apple rows and talks to the trees more than to people."}
  ],
  "locations": [
    {"name": "Hollowmere", "description": "Hollowmere is the sunken orchard valley where the story now sits."}
  ],
  "themes": [],
  "lexicon": [
    {"term": "Warden", "definition": "In the orchard counties a warden is the keeper of a flooded grove, not an official."}
  ],
  "timeline": [
    {"event": "Tamsin takes the orchard post"},
    {"event": "Gil finds the salt line rising"}
  ],
  "current_state": "Tamsin settles into Hollowmere; the salt is rising.",
  "__dormant": [
    {"name": "Orrin Blackwood", "category": "characters", "role": "Ferry master", "description": "Orrin Blackwood runs the night ferry and never asks for fares twice. He knows every sandbar by sound.", "source": "Mock Series 2 - The Ferry", "file": "]] .. V2 .. [["},
    {"name": "Elias Penrose", "category": "characters", "role": "Deckhand", "description": "Elias Penrose poles the ferry through the shallows. The passengers call him the ferryman, though the title is Orrin's.", "source": "Mock Series 2 - The Ferry", "file": "]] .. V2 .. [["},
    {"name": "Cass Merrow", "category": "characters", "role": "Tide clerk", "description": "Cass Merrow records the tides and keeps Tamsin honest. Dry-witted, always cold.", "source": "Mock Series 1 - The Lantern", "file": "]] .. V1 .. [["},
    {"name": "Fenna Quill", "category": "characters", "role": "Letter carrier", "description": "Fenna Quill rows the mail between the shore towns. Never late, never early.", "source": "Mock Series 2 - The Ferry", "file": "]] .. V2 .. [["},
    {"name": "the Warden", "category": "characters", "role": "Harbor official", "aliases": ["Warden"], "description": "The Warden inspects the ferry manifests and is never seen eating. First name unknown.", "source": "Mock Series 2 - The Ferry", "file": "]] .. V2 .. [["},
    {"name": "Vex", "aliases": ["the grey cat"], "category": "characters", "role": "Ship's cat", "description": "Vex, the grey cat, boards whichever boat is warmest and answers to no one.", "source": "Mock Series 2 - The Ferry", "file": "]] .. V2 .. [["},
    {"name": "Saltmere", "category": "locations", "description": "Saltmere is the drowned market town across the bay, visited at low tide.", "source": "Mock Series 2 - The Ferry", "file": "]] .. V2 .. [["}
  ]
}]]

-- The built-but-uninstalled 70% rung: Orrin has arrived (woken: his stub is
-- gone, his vol-2 line rides as background), Hester is new (ahead-only
-- control). Everything else still carried.
local VOL3_RUNG_70 = [[{
  "type": "fiction",
  "characters": [
    {"name": "Tamsin Vael", "role": "Orchard warden", "description": "Tamsin Vael has come inland to mind the sea-orchard. She distrusts the quiet.", "background": [{"source": "Mock Series 1 - The Lantern", "text": "Kept the harbor lantern and read the tide ledgers.", "file": "]] .. V1 .. [["}]},
    {"name": "Gil Rook", "role": "Grafter", "description": "Gil Rook grafts the salt-apple rows and talks to the trees more than to people."},
    {"name": "Orrin Blackwood", "role": "Ferry master, retired", "description": "Orrin Blackwood arrives at Hollowmere without his ferry and will not say why.", "background": [{"source": "Mock Series 2 - The Ferry", "text": "Ran the night ferry and never asked for fares twice.", "file": "]] .. V2 .. [["}]},
    {"name": "Hester Lune", "role": "Surveyor", "description": "Hester Lune walks the salt line with brass instruments and writes to someone nightly."}
  ],
  "locations": [
    {"name": "Hollowmere", "description": "Hollowmere is the sunken orchard valley where the story now sits."}
  ],
  "themes": [],
  "lexicon": [
    {"term": "Warden", "definition": "In the orchard counties a warden is the keeper of a flooded grove, not an official."}
  ],
  "timeline": [
    {"event": "Tamsin takes the orchard post"},
    {"event": "Gil finds the salt line rising"},
    {"event": "Orrin arrives without his ferry"},
    {"event": "Hester maps the salt line"}
  ],
  "current_state": "Orrin has come inland; Hester measures what the salt takes.",
  "__dormant": [
    {"name": "Elias Penrose", "category": "characters", "role": "Deckhand", "description": "Elias Penrose poles the ferry through the shallows. The passengers call him the ferryman, though the title is Orrin's.", "source": "Mock Series 2 - The Ferry", "file": "]] .. V2 .. [["},
    {"name": "Cass Merrow", "category": "characters", "role": "Tide clerk", "description": "Cass Merrow records the tides and keeps Tamsin honest. Dry-witted, always cold.", "source": "Mock Series 1 - The Lantern", "file": "]] .. V1 .. [["},
    {"name": "Fenna Quill", "category": "characters", "role": "Letter carrier", "description": "Fenna Quill rows the mail between the shore towns. Never late, never early.", "source": "Mock Series 2 - The Ferry", "file": "]] .. V2 .. [["},
    {"name": "the Warden", "category": "characters", "role": "Harbor official", "aliases": ["Warden"], "description": "The Warden inspects the ferry manifests and is never seen eating. First name unknown.", "source": "Mock Series 2 - The Ferry", "file": "]] .. V2 .. [["},
    {"name": "Vex", "aliases": ["the grey cat"], "category": "characters", "role": "Ship's cat", "description": "Vex, the grey cat, boards whichever boat is warmest and answers to no one.", "source": "Mock Series 2 - The Ferry", "file": "]] .. V2 .. [["},
    {"name": "Saltmere", "category": "locations", "description": "Saltmere is the drowned market town across the bay, visited at low tide.", "source": "Mock Series 2 - The Ferry", "file": "]] .. V2 .. [["}
  ]
}]]

-- An old archived version of vol 3's live (ring entry: "All versions" row).
local VOL3_RING_25 = [[{
  "type": "fiction",
  "characters": [
    {"name": "Tamsin Vael", "role": "Orchard warden", "description": "Tamsin Vael has come inland to mind the sea-orchard."}
  ],
  "locations": [], "themes": [], "lexicon": [],
  "timeline": [{"event": "Tamsin takes the orchard post"}],
  "current_state": "Tamsin arrives at Hollowmere."
}]]

-- A section X-Ray of vol 3 chapter 2 (data-shape example; page numbers are
-- APPROXIMATE — rendered page counts vary with font size, and nothing in the
-- fixture depends on exact section ranges).
local VOL3_SECTION_CH2 = [[{
  "type": "fiction",
  "characters": [
    {"name": "Gil Rook", "role": "Grafter", "description": "Gil Rook, first met among the salt-apple rows."}
  ],
  "locations": [], "themes": [], "lexicon": [],
  "timeline": [{"event": "Gil shows Tamsin the grafting knife"}],
  "current_state": "Chapter 2: Tamsin meets Gil."
}]]

local PROJ_A_XRAY = [[{
  "key_figures": [
    {"name": "Maren Kessler", "role": "Marine ecologist", "description": "Maren Kessler surveyed the tidal commons for thirty years and coined the term."},
    {"name": "Ivo Larsen", "role": "Harbor historian", "description": "Ivo Larsen catalogued the drowned market records."}
  ],
  "locations": [],
  "core_concepts": [
    {"name": "Tidal Commons", "description": "The shared intertidal ground no one owns and everyone works, the book's central idea."}
  ],
  "arguments": [
    {"name": "Commons outlast owners", "description": "Shared ground survives its stewards; deeds do not."}
  ],
  "terminology": [
    {"term": "slack water", "definition": "The pause between tides when the commons can be crossed."}
  ],
  "argument_development": [
    {"event": "The commons is defined"},
    {"event": "Three drowned harbors are compared"}
  ],
  "conclusion": "The commons persists where ownership failed."
}]]

-- Project B: a fold from A has already happened — "Tidal Commons" carries a
-- background line from A, and Maren sits in B's ledger (project-group fold
-- residue; the family bridge characters <-> key_figures is exercised here).
local PROJ_B_XRAY = [[{
  "key_figures": [
    {"name": "Ivo Larsen", "role": "Harbor historian", "description": "Ivo Larsen, now writing the salt-road ledgers, argues the roads WERE the commons."}
  ],
  "locations": [],
  "core_concepts": [
    {"name": "Tidal Commons", "description": "Reused here for the salt roads: a commons of passage rather than ground.", "background": [{"source": "Mock Project A - Field Notes", "text": "The shared intertidal ground no one owns and everyone works.", "file": "__PATH:4__"}]}
  ],
  "arguments": [],
  "terminology": [
    {"term": "salt road", "definition": "A low-tide cart route across the flats."}
  ],
  "argument_development": [
    {"event": "The salt roads are mapped"}
  ],
  "conclusion": "Passage, not ground, made the commons.",
  "__dormant": [
    {"name": "Maren Kessler", "category": "key_figures", "description": "Maren Kessler surveyed the tidal commons for thirty years and coined the term.", "source": "Mock Project A - Field Notes", "file": "__PATH:4__"}
  ]
}]]

local SHELF_A_XRAY = [[{
  "type": "fiction",
  "characters": [
    {"name": "Petra Illy", "role": "Paper folder", "description": "Petra Illy folds birds that will not stay folded."}
  ],
  "locations": [], "themes": [], "lexicon": [],
  "timeline": [{"event": "The first bird unfolds itself"}],
  "current_state": "Petra suspects the paper."
}]]

local SHELF_B_XRAY = [[{
  "type": "fiction",
  "characters": [
    {"name": "Anselm Grey", "role": "Glazier", "description": "Anselm Grey cuts winter glass that never fogs."}
  ],
  "locations": [], "themes": [], "lexicon": [],
  "timeline": [{"event": "The first pane sings in the cold"}],
  "current_state": "Anselm listens to the glass."
}]]

-- ------------------------------------------------------------------- chapters
-- `text` = the sentences that carry names (rendered verbatim, one paragraph);
-- `filler` = how many neutral filler paragraphs gen.lua appends after it.

local function ch(title, text, filler)
    return { title = title, text = text, filler = filler or 3 }
end

local VOL1_CHAPTERS = {
    ch("The Cracked Lens", "Tamsin Vael climbed the lantern stair before first light. The lens had cracked in the night and no one would say how."),
    ch("Tide Ledgers", "Cass Merrow kept the tide ledgers in a locked drawer. Tamsin asked for the key and got a lecture instead."),
    ch("Low Water", "At low water the road to Saltmere showed itself, cobble by cobble. Tamsin walked it once and swore never again."),
    ch("The Hidden Page", "Cass tore a page from the ledger and hid it in the salt jar. Tamsin pretended not to see."),
    ch("The Diver", "Zeph Umber surfaced by the mole with a bell in each hand. Nobody had hired a diver, and Zeph never said who paid."),
    ch("Keeping the Light", "Zeph left on the morning tide without a goodbye. Tamsin lit the lantern and Cass unlocked the drawer at last."),
}

local VOL2_CHAPTERS = {
    ch("The Night Ferry", "Orrin Blackwood ran the night ferry by sound alone. Tamsin Vael boarded at the far shore with one bag."),
    ch("The Deckhand", "Elias Penrose poled the shallows while the passengers slept. They called him the ferryman, and Orrin let them."),
    ch("Mail by Water", "Fenna Quill rowed the mail across before breakfast. Dorrit Hale had the inn fires lit when she landed."),
    ch("Manifests", "The Warden came aboard at Saltmere and read the manifest twice. Vex, the grey cat, sat on the ink."),
    ch("Aground", "The ferry ran aground on the singing bar. Elias got them off; Orrin logged it as weather."),
    ch("The Storm Season", "Dorrit Hale closed the inn for the storm and fed whoever knocked. The route held; the season ended."),
}

-- Vol 3: ten chapters, so chapter N spans roughly (N-1)/10 .. N/10 of the book.
-- Live X-Ray covers to 40% (end of ch 4); the built rung covers to 70% (end of
-- ch 7). Guests are placed for the plan's device steps: Elias ~45%, Saltmere
-- ~48%, Dorrit ~50%, Warden ~52%, Orrin ~55%, the grey cat ~58%, Cass ~60%,
-- Zeph ~65%, Hester ~68%.
local VOL3_CHAPTERS = {
    ch("The Orchard Post", "Tamsin Vael came inland to Hollowmere to mind the sea-orchard. The quiet felt rented."),
    ch("The Grafter", "Gil Rook was up a ladder in the salt-apple rows, talking to the graft. He handed Tamsin the knife by way of hello."),
    ch("The Salt Line", "Gil showed Tamsin the white line climbing the trunks. A warden's first job, he said, is to notice."),
    ch("Rented Quiet", "Tamsin walked the flooded rows at dusk. Whatever was wrong with Hollowmere had not introduced itself yet."),
    ch("A Face From the Water", "A poleman stood at the orchard gate, hat in hand. Elias Penrose had come a long way from the crossing, and Tamsin could not place him at first. He asked after work, then after the road to Saltmere, and left before the answer.", 4),
    ch("The Inn Sign", "A painted sign came upriver on the cart: an inn changing hands. Dorrit Hale, the letters said, was selling. The Warden was named in the small print, and Gil read it twice. That evening a grey cat crossed the orchard wall as if it owned the deed. Behind the cart walked Orrin Blackwood, carrying nothing, and he would not say why he had come inland.", 4),
    ch("Old Ledgers", "A tide ledger arrived wrapped in oilcloth, in a hand Tamsin knew: Cass Merrow's. No note. Later a stranger asked at the gate for salvage work and gave the name Zeph Umber; Gil sent him upvalley. By dark a surveyor's lamp burned on the ridge, and someone said the name Hester Lune.", 4),
    ch("Instruments", "Hester Lune walked the salt line with brass instruments and wrote to someone nightly. The man who carried her tripod kept his own counsel."),
    ch("What the Salt Takes", "Tamsin and Gil counted the drowned rows. Hester's figures said the valley had three seasons left."),
    ch("The Grove Warden", "Tamsin took the warden's oath under the oldest tree. The salt kept rising, and the story went on without asking."),
}

local PROJ_A_CHAPTERS = {
    ch("Defining the Commons", "Maren Kessler spent thirty years on the flats before naming what she stood on: the tidal commons."),
    ch("Three Harbors", "The drowned markets of three harbors are compared. Ivo Larsen supplies the records."),
    ch("Slack Water", "At slack water the commons can be crossed on foot. The term does the argument's work."),
    ch("What Persists", "Deeds drowned with the harbors. The commons did not."),
}

local PROJ_B_CHAPTERS = {
    ch("The Salt Roads", "Ivo Larsen maps the low-tide cart routes. A commons of passage, he calls them."),
    ch("Carts and Crossings", "The salt road bore carts twice a day and belonged to no one between tides."),
    ch("Passage as Commons", "The roads, not the ground, made the commons. The tidal commons idea is put to work."),
    ch("The Last Crossing", "The last mapped salt road drowned in living memory. The argument rests."),
}

local SHELF_A_CHAPTERS = {
    ch("The First Bird", "Petra Illy folded a paper bird and set it on the sill. By morning it had unfolded itself."),
    ch("Creases", "Petra folded faster than the paper could forget. The birds stayed birds a little longer."),
    ch("The Flock", "A drawer of flat paper rustled at night. Petra stopped opening the drawer."),
    ch("Unfolding", "Petra left the window open. The paper decided for itself."),
}

local SHELF_B_CHAPTERS = {
    ch("Winter Glass", "Anselm Grey cut glass that never fogged, and in deep cold it sang."),
    ch("The Singing Pane", "The first pane sang a low note at dawn. Anselm sold it anyway."),
    ch("Frost Work", "Every window Anselm glazed stayed clear through the worst of it."),
    ch("What the Cold Wants", "Anselm listened to the glass and glazed no more that winter."),
}

-- ---------------------------------------------------------------------- books
-- Order matters: __PATH:n__ refers to positions in THIS array.

local BOOKS = {
    {
        folder = "Mock Series", filename = "Mock Series 1 - The Lantern.epub",
        title = "Mock Series 1 - The Lantern", author = "A. Mock",
        chapters = VOL1_CHAPTERS,
        xray = { json = VOL1_XRAY, progress = 1.0,
            meta = { model = "mock", used_book_text = true, source_mode = "book_text",
                full_document = true, timestamp = 1755000100 } },
        aliases = { ["Tamsin Vael"] = { add = { "Tam" } } },
        sidecar = { koassistant_book_xray_auto = false },
    },
    {
        folder = "Mock Series", filename = "Mock Series 2 - The Ferry.epub",
        title = "Mock Series 2 - The Ferry", author = "A. Mock",
        chapters = VOL2_CHAPTERS,
        xray = { json = VOL2_XRAY, progress = 1.0,
            meta = { model = "mock", used_book_text = true, source_mode = "book_text",
                full_document = true, timestamp = 1755000200 } },
        sidecar = { koassistant_book_xray_auto = false },
    },
    {
        folder = "Mock Series", filename = "Mock Series 3 - The Orchard.epub",
        title = "Mock Series 3 - The Orchard", author = "A. Mock",
        chapters = VOL3_CHAPTERS,
        xray = { json = VOL3_XRAY, progress = 0.4,
            meta = { model = "mock", used_book_text = true, source_mode = "book_text",
                timestamp = 1755000300 } },
        ladder = {
            { json = VOL3_RUNG_70, progress = 0.7, timestamp = 1755000400,
                model = "mock", used_book_text = true, source_mode = "book_text" },
        },
        ring = {
            { json = VOL3_RING_25, progress = 0.25, timestamp = 1755000250,
                model = "mock", used_book_text = true, source_mode = "book_text" },
        },
        sections = {
            { label = "Chapter 2", json = VOL3_SECTION_CH2,
                start_page = 5, end_page = 9, timestamp = 1755000310 },
        },
        sidecar = { koassistant_book_xray_auto = false },
    },
    {
        folder = "Mock Project", filename = "Mock Project A - Field Notes.epub",
        title = "Mock Project A - Field Notes", author = "M. Mock",
        chapters = PROJ_A_CHAPTERS,
        xray = { json = PROJ_A_XRAY, progress = 1.0,
            meta = { model = "mock", used_book_text = true, source_mode = "book_text",
                full_document = true, timestamp = 1755000500 } },
        sidecar = { koassistant_book_xray_auto = false },
    },
    {
        folder = "Mock Project", filename = "Mock Project B - Salt Roads.epub",
        title = "Mock Project B - Salt Roads", author = "M. Mock",
        chapters = PROJ_B_CHAPTERS,
        xray = { json = PROJ_B_XRAY, progress = 1.0,
            meta = { model = "mock", used_book_text = true, source_mode = "book_text",
                full_document = true, timestamp = 1755000600,
                merged_from_books = "Mock Project A - Field Notes" } },
        sidecar = { koassistant_book_xray_auto = false },
    },
    {
        folder = "Mock Shelf", filename = "Mock Shelf A - Paper Birds.epub",
        title = "Mock Shelf A - Paper Birds", author = "S. Mock",
        chapters = SHELF_A_CHAPTERS,
        xray = { json = SHELF_A_XRAY, progress = 0.5,
            meta = { model = "mock", used_book_text = true, source_mode = "book_text",
                timestamp = 1755000700 } },
        sidecar = { koassistant_book_xray_auto = false },
    },
    {
        folder = "Mock Shelf", filename = "Mock Shelf B - Winter Glass.epub",
        title = "Mock Shelf B - Winter Glass", author = "S. Mock",
        chapters = SHELF_B_CHAPTERS,
        xray = { json = SHELF_B_XRAY, progress = 0.5,
            meta = { model = "mock", used_book_text = true, source_mode = "book_text",
                timestamp = 1755000800 } },
        sidecar = { koassistant_book_xray_auto = false },
    },
}

-- Neutral filler paragraphs (no entity names — the names above are the only
-- occurrences, so mention counts and marks stay predictable).
local FILLER = {
    "The weather held through the morning and turned by afternoon, as it always did in that season. Nobody remarked on it, which was its own kind of remark.",
    "There was bread, and there was work, and the two traded places at noon. The gulls kept their opinions loud and their distance short.",
    "The tide did what tides do, twice, without being asked. Somewhere a door banged until someone wedged it with a folded sack.",
    "Evening came in over the water with nothing to declare. The lamps were lit in the usual order, and the usual order was enough.",
    "A cart went by on the upper road, empty going and loaded coming back. The dogs escorted it both ways on principle.",
    "The night was long the way working nights are long, and the morning arrived owing nobody an apology.",
}

return { books = BOOKS, filler = FILLER }
