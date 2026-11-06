--[[
Unit tests: koassistant/ui/data_access.lua's pure helpers (B395 slice 5) and the
attachments' stamps.

- carriedKinds: the kinds a request's context carried, from message_data
- stampsFromKinds: a chat's record as an artifact's (a pin's) stamps
- resumeNeeds: what a resumed chat needs (Never refuses, another provider asks the
  Ask kinds, the same provider passes, legacy chats pass)
- sendableMessages: the saved context messages left out after "Continue without
  the stored context"
- needsFor: a kinds list mixing required and optional kinds; a set of books, each
  with its own kinds
- makeArtifact / makePinned carry their book and stamps; artifactAllowed and
  forProvider judge them for the provider

Run: lua tests/run_tests.lua --unit
]]

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
require("mock_koreader")

local TestRunner = require("test_runner"):new()
local DataAccess = require("koassistant.ui.data_access")
local Gates = require("koassistant.request.privacy_gates")
local A = require("koassistant.request.attachments")
local SDS = require("koassistant.storage.doc_settings")
local UIManager = require("ui/uimanager")
local saved = { resolve = SDS.resolve, show = UIManager.show }
SDS.resolve = function() return nil end  -- no book values in these tests
local shown = {}
UIManager.show = function(_self, w) shown[#shown + 1] = w end

print("Running: test_data_access")
print("")
print("  [the chat's record]")

TestRunner:test("carriedKinds lists what the gather put in the request, in KINDS order", function()
    TestRunner:assertEqual(DataAccess.carriedKinds({}), nil, "nothing of the reader's: no record")
    local k = DataAccess.carriedKinds({ highlights = "h", book_text = "t", library_content = "l",
        stats_groups = { deep = {} }, surrounding_context = "s" })
    TestRunner:assertEqual(table.concat(k, ","), "book_text,highlights,habits,book_list,nearby_text")
    k = DataAccess.carriedKinds({ cached_used_book_text = true, _inherited_stamps = { annotations = true } })
    TestRunner:assertEqual(table.concat(k, ","), "book_text,annotations", "stored material read along counts")
    TestRunner:assertEqual(DataAccess.carriedKinds({ highlights = "" }), nil, "an empty section is nothing")
end)

TestRunner:test("stampsFromKinds: a record as an artifact's stamps; nothing recorded is text-free", function()
    local s = DataAccess.stampsFromKinds({ "book_text", "notebook" })
    TestRunner:assertEqual(s.used_book_text, true)
    TestRunner:assertEqual(s.used_notebook, true)
    TestRunner:assertEqual(s.used_highlights, false)
    TestRunner:assertEqual(DataAccess.stampsFromKinds(nil).used_book_text, false)
    TestRunner:assertEqual(Gates.stampedKinds(DataAccess.stampsFromKinds({ "notebook" })).notebook, true,
        "the gates read the notebook stamp")
end)

print("  [resume]")

TestRunner:test("resumeNeeds: Never refuses, another provider asks the Ask kinds, the same provider passes", function()
    local chat = { data_kinds = { "book_text", "highlights" }, provider = "anthropic" }
    local r = DataAccess.resumeNeeds(chat, {}, "anthropic", "/b/x.epub", nil)
    TestRunner:assertEqual(#r.asked, 0, "the provider that answered has the data")
    TestRunner:assertEqual(r.refused, nil)
    r = DataAccess.resumeNeeds(chat, {}, "openai", "/b/x.epub", nil)
    TestRunner:assertEqual(table.concat(r.asked, ","), "book_text,highlights", "another provider: asked once")
    r = DataAccess.resumeNeeds(chat, { enable_book_text_extraction = "never" }, "anthropic", "/b/x.epub", nil)
    TestRunner:assertEqual(r.refused and r.refused.kind, "book_text", "Never refuses whatever the provider")
    TestRunner:assertEqual(r.refused and r.refused.layer, "global")
    r = DataAccess.resumeNeeds(chat, { trusted_providers = { "ollama" } }, "ollama", "/b/x.epub", nil)
    TestRunner:assertEqual(#r.asked, 0, "a trusted provider's column is Allow by default")
    TestRunner:assertEqual(DataAccess.resumeNeeds({ provider = "openai" }, {}, "anthropic", nil, nil).refused, nil,
        "no record: nothing to check")
    TestRunner:assertEqual(#DataAccess.resumeNeeds({ data_kinds = {} }, {}, "anthropic", nil, nil).asked, 0)
end)

TestRunner:test("sendableMessages drops only the context messages saved with the chat", function()
    local msgs = {
        { role = "user", content = "ctx", is_context = true },
        { role = "user", content = "q" },
        { role = "assistant", content = "a" },
        { role = "user", content = "attached", is_context = true },
    }
    TestRunner:assertEqual(#DataAccess.sendableMessages(msgs, {}), 4, "no choice made: everything")
    local out = DataAccess.sendableMessages(msgs, { _drop_stored_context = 3 })
    TestRunner:assertEqual(#out, 3)
    TestRunner:assertEqual(out[1].content, "q", "the saved context message is out")
    TestRunner:assertEqual(out[3].content, "attached", "a context message added since rides")
end)

print("  [needs]")

TestRunner:test("needsFor: a list may mix required and optional kinds; a set judges each book's own kinds", function()
    local needs = DataAccess.needsFor(nil, { features = {}, provider = "openai",
        kinds = { { kind = "book_text", required = true }, { kind = "highlights", required = false } } })
    TestRunner:assertEqual(needs[1].required, true)
    TestRunner:assertEqual(needs[2].required, false)
    TestRunner:assertEqual(needs[1].state, "ask")
    local set_needs, never_books = DataAccess.needsFor(nil, { features = {}, provider = "openai",
        books = { { file = "/b/1.epub", kinds = { book_text = true } }, { file = "/b/2.epub", kinds = { highlights = true } } } })
    local asked = {}
    for _idx, n in ipairs(set_needs) do asked[n.kind] = n.state end
    TestRunner:assertEqual(asked.book_text, "ask", "the first book's kind")
    TestRunner:assertEqual(asked.highlights, "ask", "the second book's kind")
    TestRunner:assertEqual(never_books, 0)
    local _n2, never2 = DataAccess.needsFor(nil, { features = { enable_book_text_extraction = "never" }, provider = "openai",
        books = { { file = "/b/1.epub", kinds = { book_text = true } } } })
    TestRunner:assertEqual(never2, 1, "a book whose kind is Never is counted")
end)

print("  [attachments carry their stamps]")

TestRunner:test("makeArtifact and makePinned carry the book and the stamps; an old general pin is text-free", function()
    local e = A.makeArtifact("Summary", "summarize_full_document",
        { result = "text", used_book_text = true, used_highlights = false }, "B", nil, "/b/x.epub")
    TestRunner:assertEqual(e.path, "/b/x.epub")
    TestRunner:assertEqual(e.used_book_text, true)
    TestRunner:assertEqual(table.concat(Gates.stampedList(e), ","), "book_text")
    local p = A.makePinned({ result = "r", name = "P", document_path = "/b/x.epub", context_type = "book" })
    TestRunner:assertEqual(Gates.stampedKinds(p).book_text, true, "an old book pin counts as built from text")
    TestRunner:assertEqual(p.path, "/b/x.epub")
    local g = A.makePinned({ result = "r", name = "G", document_path = "__GENERAL_CHATS__", context_type = "general" })
    TestRunner:assertEqual(Gates.stampedKinds(g).book_text, false, "an old general pin sent nothing of a book")
    local n = A.makePinned({ result = "r", name = "N", document_path = "/b/x.epub", context_type = "book",
        used_book_text = false, used_notebook = true })
    TestRunner:assertEqual(table.concat(Gates.stampedList(n), ","), "notebook", "a new pin's record")
end)

TestRunner:test("artifactAllowed and forProvider judge a text-built artifact for the provider", function()
    local e = A.makeArtifact("Summary", "summarize_full_document", { result = "text", used_book_text = true }, "B", nil, "/b/x.epub")
    TestRunner:assertFalse(A.artifactAllowed({}, "openai", e, nil), "Ask: not allowed to send")
    TestRunner:assertTrue(A.artifactAllowed({ enable_book_text_extraction = true }, "openai", e, nil), "Allow")
    TestRunner:assertTrue(A.artifactAllowed({ trusted_providers = { "ollama" } }, "ollama", e, nil), "a trusted provider's column")
    TestRunner:assertTrue(A.artifactAllowed({ _data_once = { book = "/b/x.epub", kinds = { book_text = true } } }, "openai", e, nil),
        "the run's allowance for its book")
    TestRunner:assertFalse(A.artifactAllowed({ _data_once = { book = "/b/other.epub", kinds = { book_text = true } } }, "openai", e, nil),
        "another book's allowance is not this one's")
    TestRunner:assertTrue(A.artifactAllowed({}, "openai", { type = "artifact", used_book_text = false }, nil),
        "no text stamp: nothing to judge")
    shown = {}
    local note = A.makeNote("a note")
    local kept = A.forProvider({ e, note }, {}, "openai", nil)
    TestRunner:assertEqual(#kept, 1, "the artifact is left out")
    TestRunner:assertEqual(kept[1].type, "note")
    TestRunner:assertTrue(#shown == 1 and tostring(shown[1].text):find("attached artifact", 1, true) ~= nil, "a notice says so")
    TestRunner:assertEqual(#A.forProvider({ e, note }, { enable_book_text_extraction = true }, "openai", nil), 2, "Allow: both ride")
end)

-- B395 slice 3 and B500: the no-title rule, the presets' names, the group's
-- privacy keys

TestRunner:test("needsTitle: an action with nothing of the book but its title (B500)", function()
    TestRunner:assertTrue(DataAccess.needsTitle({ prompt = 'Tell me about "{title}"{author_clause}.' }, nil),
        "an AI-knowledge book action")
    TestRunner:assertTrue(DataAccess.needsTitle({ template = "book_info" }, nil), "through its template")
    TestRunner:assertFalse(DataAccess.needsTitle({ prompt = 'X-Ray of "{title}"', use_book_text = true }, nil),
        "the text goes")
    TestRunner:assertTrue(DataAccess.needsTitle({ prompt = 'Summarize "{title}"', use_book_text = true }, "ai_knowledge"),
        "the AI-knowledge source sends no text")
    TestRunner:assertFalse(DataAccess.needsTitle({ prompt = 'My notes on "{title}"', use_annotations = true }, nil),
        "the reader's notes go")
    TestRunner:assertFalse(DataAccess.needsTitle({ prompt = "Explain this." }, nil), "no title in the prompt")
    -- B514: judged on what the run sends
    local args = { prompt = 'Key arguments of "{title}"', use_book_text = true, use_summary_cache = true, source_selection = true }
    TestRunner:assertTrue(DataAccess.needsTitle(args, "ai_knowledge"), "AI knowledge only: no text, no summary")
    TestRunner:assertFalse(DataAccess.needsTitle(args, "summary"), "the summary goes")
    TestRunner:assertFalse(DataAccess.needsTitle(args, "full_text"), "the text goes")
    TestRunner:assertFalse(DataAccess.needsTitle(args, nil), "no source picked yet: the action could use both")
    TestRunner:assertFalse(DataAccess.needsTitle({ prompt = 'Something like "{title}"', use_library = true }, nil),
        "the book list goes (Suggest from Library)")
end)

TestRunner:test("the presets' names and the layers' words", function()
    TestRunner:assertEqual(DataAccess.presetLabel("default"), "Default (Ask)")
    TestRunner:assertEqual(DataAccess.presetLabel(nil), "Custom")
    TestRunner:assertEqual(DataAccess.layerLabel("once"), "this run")
end)

TestRunner:test("a group can hold the five privacy values (B395 slice 4)", function()
    local GS = require("koassistant.books.group_settings")
    local BS = require("koassistant.books.book_settings")
    local keys = {}
    for _idx, k in ipairs(GS.keys()) do keys[k] = true end
    for _kind, key in pairs(BS.PRIVACY_KEY_OF_KIND) do
        TestRunner:assertTrue(keys[key], key .. " is a group key")
        TestRunner:assertTrue(GS.keyLabel(key) ~= key, key .. " has a label")
    end
    TestRunner:assertEqual(GS.valueLabel(BS.KEY_TEXT_EXTRACTION, false), "Never")
    TestRunner:assertEqual(GS.valueLabel(BS.KEY_HIGHLIGHTS_SHARING, true), "Allow")
end)

TestRunner:test("the privacy picker's spec: the book holds Allow or Never, all books Ask, Allow or Never", function()
    local BS = require("koassistant.books.book_settings")
    local spec = BS.privacySpec("book_text")
    TestRunner:assertEqual(#spec.book_options, 2)
    TestRunner:assertEqual(#spec.options, 3)
    local f = {}
    spec.set_global(f, "never")
    TestRunner:assertEqual(f.enable_book_text_extraction, "never")
    spec.set_global(f, "allow")
    TestRunner:assertEqual(f.enable_book_text_extraction, true)
    spec.set_global(f, "ask")
    TestRunner:assertEqual(Gates.globalState(f, "book_text"), "ask")
    local notes = BS.privacySpec("annotations")
    local g = {}
    notes.set_global(g, "allow")
    TestRunner:assertEqual(g.enable_highlights_sharing, true, "allowing notes allows highlights")
    local near = BS.privacySpec("nearby_text")
    local h = {}
    near.set_global(h, "never")
    TestRunner:assertEqual(h.nearby_text_sharing, "never", "string-valued")
    TestRunner:assertEqual(BS.privacySpec("position").global({}), true, "position on unless off")
end)

TestRunner:test("a refusal or a Cancel runs the caller's hook; nothing runs", function()
    shown = {}
    local refused, ran = false, false
    local ok = DataAccess.withAccess(nil, nil, {
        features = { enable_book_text_extraction = "never" }, provider = "openai",
        kinds = { "book_text" }, action_name = "X-Ray",
        on_refused = function() refused = true end,
    }, function() ran = true end)
    TestRunner:assertFalse(ok, "refused")
    TestRunner:assertTrue(refused, "the hook ran")
    TestRunner:assertFalse(ran, "the run did not")
end)

TestRunner:test("the funnel's Cancel clears every dispatch transient, as the dispatch would have (the sweep of 2026-11-06)", function()
    -- A direct entry sets its run option, the chips' state and the allowance
    -- on a shared config just in time; handlePredefinedPrompt consumes them.
    -- A Cancel at the question never reaches those reads, so the funnel's
    -- drop must clear the same list, or the next unrelated request inherits them
    local Dialogs = require("koassistant.ui.dialogs")
    local stubbed = {}
    local function stub(name, fn) stubbed[name] = DataAccess[name]; DataAccess[name] = fn end
    stub("needsFor", function() return { { kind = "book_text", state = "ask" } }, nil end)
    stub("plan", function() return { asked = { "book_text" } } end)
    stub("scanFolders", function() return { "/x" } end)
    stub("windowAmounts", function() return nil, nil end)
    stub("folderWindowNeed", function() return nil end)
    stub("withAccess", function(plugin, action, opts, run_fn) opts.on_cancel() end)
    local cf = { is_general_context = true, enable_web_search = true,
        _web_search_active = true, _model_override_active = { provider = "x", model = "y" },
        _quick_answer_active = true, _attachments_active = true, _run_variant = { web = true },
        _data_once = { book = "b" }, _highlight_context_active = "sentence", _xray_context_prefix = "p",
        _source_mode = "summary", _forced_document_context = "ctx" }
    local ok, asked = pcall(DataAccess.askForDispatch, {}, { id = "a", prompt = "" }, cf, nil,
        { provider = "anthropic" }, function() end)
    for name, fn in pairs(stubbed) do DataAccess[name] = fn end
    TestRunner:assertTrue(ok, "askForDispatch ran: " .. tostring(asked))
    TestRunner:assertEqual(asked, true, "the question was asked")
    local left = {}
    for k in pairs(cf) do
        if k:sub(1, 1) == "_" then left[#left + 1] = k end
    end
    table.sort(left)
    TestRunner:assertEqual(table.concat(left, ","), "", "no transient left on the shared features")
    TestRunner:assertEqual(cf.enable_web_search, true, "the settings stay")
    TestRunner:assertEqual(cf.is_general_context, true)
    -- The list is the one the dispatch consumes: every `config.features._x = nil`
    -- inside handlePredefinedPrompt names a key of the list (a new consumable
    -- added at a read site must join it, or a Cancel leaves it behind)
    local f = assert(io.open("koassistant/ui/dialogs.lua"))
    local src = f:read("*a")
    f:close()
    local from = src:find("\nhandlePredefinedPrompt = function(", 1, true)
    local to = src:find("\nlocal function ", from + 1, true) or #src
    local span = src:sub(from, to)
    local listed = {}
    for _idx, k in ipairs(Dialogs.DISPATCH_TRANSIENTS.entry) do listed[k] = true end
    for _idx, k in ipairs(Dialogs.DISPATCH_TRANSIENTS.later) do listed[k] = true end
    local n = 0
    for key in span:gmatch("config%.features%.(_[%w_]+) = nil") do
        -- (the headless runs' marks never reach the question: the funnel skips
        -- them, and _data_no_question is cleared before it)
        local headless = key:find("^_background_") or key:find("^_ladder_")
            or key == "_merge_payload" or key == "_data_no_question"
        if not headless then
            n = n + 1
            TestRunner:assertTrue(listed[key] == true, "consumed at a read site and in the list: " .. key)
        end
    end
    TestRunner:assertTrue(n >= 7, "the read sites were found (" .. n .. ")")
end)

SDS.resolve = saved.resolve
UIManager.show = saved.show

return TestRunner:summary()
