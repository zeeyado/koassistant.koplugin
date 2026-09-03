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

-- Book-info level: resolution + gating of the generic [Context] auto-block
TestRunner:suite("resolveBookInfoLevel")

local KBI = "koassistant_book_info_level"
TestRunner:test("per-book override wins over global", function()
    TestRunner:assertEqual(
        BookSettings.resolveBookInfoLevel(makeDocSettings({ [KBI] = "none" }), { book_info_in_chat = "full" }), "none")
end)
TestRunner:test("falls back to global when no per-book", function()
    TestRunner:assertEqual(
        BookSettings.resolveBookInfoLevel(makeDocSettings({}), { book_info_in_chat = "full" }), "full")
end)
TestRunner:test("defaults to basic when neither set", function()
    TestRunner:assertEqual(BookSettings.resolveBookInfoLevel(makeDocSettings({}), {}), "basic")
end)

-- Spoiler-free resolution (drives the tool reading scope): per-book true/false wins over global
TestRunner:suite("resolveSpoilerFree")

local KSF = "koassistant_book_spoiler_free"
TestRunner:test("per-book true wins over global off", function()
    TestRunner:assertEqual(
        BookSettings.resolveSpoilerFree(makeDocSettings({ [KSF] = true }), { spoiler_free_chat = false }), true)
end)
TestRunner:test("per-book false overrides global on", function()
    TestRunner:assertEqual(
        BookSettings.resolveSpoilerFree(makeDocSettings({ [KSF] = false }), { spoiler_free_chat = true }), false)
end)
TestRunner:test("nil per-book follows global on", function()
    TestRunner:assertEqual(
        BookSettings.resolveSpoilerFree(makeDocSettings({}), { spoiler_free_chat = true }), true)
end)
TestRunner:test("defaults to PROTECTED when neither set (the §4.3 flip)", function()
    TestRunner:assertEqual(BookSettings.resolveSpoilerFree(makeDocSettings({}), {}), true)
end)
TestRunner:test("nil doc_settings follows global", function()
    TestRunner:assertEqual(BookSettings.resolveSpoilerFree(nil, { spoiler_free_chat = false }), false)
    TestRunner:assertEqual(BookSettings.resolveSpoilerFree(nil, {}), true)
end)
TestRunner:test("research mode disables protection (the §2 unification consequence)", function()
    -- The request layer now consults research like the X-Ray posture always did:
    -- the chat nudge and the tool reading clamp stand down for a researched book.
    TestRunner:assertEqual(
        BookSettings.resolveSpoilerFree(
            makeDocSettings({ koassistant_book_research_mode = true }),
            { spoiler_free_chat = true }),
        false)
    -- ... even over an explicit per-book spoiler override (the 50(g) rule)
    TestRunner:assertEqual(
        BookSettings.resolveSpoilerFree(
            makeDocSettings({ [KSF] = true, koassistant_book_research_mode = true }), {}),
        false)
    -- Escape hatch: book research OFF re-enables the spoiler layers
    TestRunner:assertEqual(
        BookSettings.resolveSpoilerFree(
            makeDocSettings({ [KSF] = true, koassistant_book_research_mode = false }),
            { research_mode = true }),
        true)
end)

TestRunner:suite("book-info level gates the [Context] auto-block")

TestRunner:test("none (book): drops Book: line, but {title} still resolves", function()
    local result = MessageBuilder.build({
        prompt = { prompt = 'About "{title}".' }, context = "book",
        data = { book_metadata = { title = "T", author = "A" }, _book_info_level = "none" },
    })
    TestRunner:assertNotContains(result, 'Book: "T"', "auto-block suppressed")
    TestRunner:assertContains(result, 'About "T"', "{title} still resolves")
end)
TestRunner:test("basic (book): keeps Book: line", function()
    local result = MessageBuilder.build({
        prompt = { prompt = 'About "{title}".' }, context = "book",
        data = { book_metadata = { title = "T", author = "A" }, _book_info_level = "basic" },
    })
    TestRunner:assertContains(result, 'Book: "T" by A')
end)
TestRunner:test("no level set: keeps Book: line (back-compat default = basic)", function()
    local result = MessageBuilder.build({
        prompt = { prompt = 'x' }, context = "book",
        data = { book_metadata = { title = "T", author = "A" } },
    })
    TestRunner:assertContains(result, 'Book: "T" by A')
end)
TestRunner:test("none (highlight): drops From line, keeps selected text", function()
    local result = MessageBuilder.build({
        prompt = { prompt = "Explain." }, context = "highlight",
        data = { book_title = "T", book_author = "A", highlighted_text = "the passage", _book_info_level = "none" },
    })
    TestRunner:assertNotContains(result, 'From "T"')
    TestRunner:assertContains(result, "the passage")
end)
TestRunner:test("basic (highlight): keeps From line + selected text", function()
    local result = MessageBuilder.build({
        prompt = { prompt = "Explain." }, context = "highlight",
        data = { book_title = "T", book_author = "A", highlighted_text = "the passage", _book_info_level = "basic" },
    })
    TestRunner:assertContains(result, 'From "T" by A')
    TestRunner:assertContains(result, "the passage")
end)

TestRunner:test("full (book): appends progress/chapter/page after Book: line", function()
    local result = MessageBuilder.build({
        prompt = { prompt = "x" }, context = "book",
        data = { book_metadata = { title = "T", author = "A" }, _book_info_level = "full",
                 reading_progress = "62%", chapter_title = "Ch 3", page_number = "484" },
    })
    TestRunner:assertContains(result, 'Book: "T" by A')
    TestRunner:assertContains(result, "Reading progress: 62%")
    TestRunner:assertContains(result, "Current chapter: Ch 3")
    TestRunner:assertContains(result, "Page: 484")
end)
TestRunner:test("full degrades gracefully when position data absent (no stats)", function()
    local result = MessageBuilder.build({
        prompt = { prompt = "x" }, context = "book",
        data = { book_metadata = { title = "T", author = "A" }, _book_info_level = "full" },
    })
    TestRunner:assertContains(result, 'Book: "T" by A')
    TestRunner:assertNotContains(result, "Reading progress:")
end)
TestRunner:test("basic does NOT append position even if present", function()
    local result = MessageBuilder.build({
        prompt = { prompt = "x" }, context = "book",
        data = { book_metadata = { title = "T" }, _book_info_level = "basic", reading_progress = "62%" },
    })
    TestRunner:assertNotContains(result, "Reading progress:")
end)

-- Composition: book-info level × AI title/author override
TestRunner:suite("interaction: override + book-info level")

TestRunner:test("full + custom title/author: custom values AND position; original gone", function()
    local meta = BookSettings.applyMetadataOverride(REAL, makeDocSettings({ [KT] = "Fake T", [KA] = "Fake A" }))
    local result = MessageBuilder.build({
        prompt = { prompt = 'About "{title}"{author_clause}.' }, context = "book",
        data = { book_metadata = meta, _book_info_level = "full",
                 reading_progress = "62%", chapter_title = "Ch 3", page_number = "484" },
    })
    TestRunner:assertContains(result, 'Book: "Fake T" by Fake A', "custom in auto-block")
    TestRunner:assertContains(result, "Reading progress: 62%", "position present")
    TestRunner:assertContains(result, 'About "Fake T" by Fake A', "{title}/{author_clause} also custom")
    TestRunner:assertNotContains(result, "Real Title", "original suppressed")
    TestRunner:assertNotContains(result, "Real Author")
end)

TestRunner:test("none + custom title: no auto-block, but {title} still resolves to custom (X-Ray case)", function()
    local meta = BookSettings.applyMetadataOverride(REAL, makeDocSettings({ [KT] = "Fake T" }))
    local result = MessageBuilder.build({
        prompt = { prompt = 'Create an X-Ray for "{title}".' }, context = "book",
        data = { book_metadata = meta, _book_info_level = "none" },
    })
    TestRunner:assertNotContains(result, 'Book: "', "generic auto-block suppressed")
    TestRunner:assertContains(result, 'X-Ray for "Fake T"', "{title} still resolves to the custom value")
    TestRunner:assertNotContains(result, "Real Title", "original never appears")
end)

-- Per-book quiz overrides: per-book field > global > built-in default
TestRunner:suite("resolveQuiz")

local KQ = BookSettings.KEY_QUIZ

TestRunner:test("no per-book, no globals → built-in defaults", function()
    local q = BookSettings.resolveQuiz(makeDocSettings({}), {})
    TestRunner:assertEqual(q.count, 8)
    TestRunner:assertEqual(q.difficulty, "medium")
    TestRunner:assertEqual(q.mc, true)
    TestRunner:assertEqual(q.sa, true)
    TestRunner:assertEqual(q.essay, true)
    TestRunner:assertEqual(q.chapter_depth, 2)
    TestRunner:assertNil(q.enabled, "enabled raw (suppress-only) defaults nil")
    TestRunner:assertEqual(q.min_pages, 5, "gate active out of the box (schema default, not 0)")
    TestRunner:assertEqual(q.min_minutes, 3, "time gate active out of the box (schema default, not 0)")
end)

TestRunner:test("nil doc_settings → globals/defaults only", function()
    local q = BookSettings.resolveQuiz(nil, { quiz_question_count = 5 })
    TestRunner:assertEqual(q.count, 5)
    TestRunner:assertEqual(q.difficulty, "medium")
end)

TestRunner:test("globals win when no per-book table", function()
    local q = BookSettings.resolveQuiz(makeDocSettings({}), {
        quiz_question_count = 12, quiz_difficulty = "hard",
        quiz_mc_enabled = false, quiz_chapter_depth = 2, quiz_min_chapter_pages = 5,
    })
    TestRunner:assertEqual(q.count, 12)
    TestRunner:assertEqual(q.difficulty, "hard")
    TestRunner:assertEqual(q.mc, false, "global mc=false respected")
    TestRunner:assertEqual(q.chapter_depth, 2)
    TestRunner:assertEqual(q.min_pages, 5)
end)

TestRunner:test("per-book overrides each field", function()
    local q = BookSettings.resolveQuiz(makeDocSettings({ [KQ] = {
        count = 4, difficulty = "easy", mc = false, sa = false, essay = true,
        chapter_depth = 1, enabled = false, min_pages = 7,
    } }), {
        quiz_question_count = 12, quiz_difficulty = "hard",
        quiz_mc_enabled = true, quiz_chapter_depth = "toc_filter", quiz_min_chapter_pages = 5,
    })
    TestRunner:assertEqual(q.count, 4)
    TestRunner:assertEqual(q.difficulty, "easy")
    TestRunner:assertEqual(q.mc, false)
    TestRunner:assertEqual(q.sa, false)
    TestRunner:assertEqual(q.essay, true)
    TestRunner:assertEqual(q.chapter_depth, 1)
    TestRunner:assertEqual(q.enabled, false, "suppress-only flag carried raw")
    TestRunner:assertEqual(q.min_pages, 7)
end)

TestRunner:test("partial per-book: only count overridden; rest follow global", function()
    local q = BookSettings.resolveQuiz(makeDocSettings({ [KQ] = { count = 3 } }), {
        quiz_question_count = 12, quiz_difficulty = "hard", quiz_mc_enabled = false,
    })
    TestRunner:assertEqual(q.count, 3, "per-book count wins")
    TestRunner:assertEqual(q.difficulty, "hard", "difficulty follows global")
    TestRunner:assertEqual(q.mc, false, "mc follows global")
end)

TestRunner:test("per-book boolean false overrides a true global", function()
    local q = BookSettings.resolveQuiz(makeDocSettings({ [KQ] = { essay = false } }),
        { quiz_essay_enabled = true })
    TestRunner:assertEqual(q.essay, false)
end)

TestRunner:test("per-book boolean true overrides a false global", function()
    local q = BookSettings.resolveQuiz(makeDocSettings({ [KQ] = { mc = true } }),
        { quiz_mc_enabled = false })
    TestRunner:assertEqual(q.mc, true)
end)

TestRunner:test("per-book min_pages = 0 overrides a non-zero global (this book: no gate)", function()
    local q = BookSettings.resolveQuiz(makeDocSettings({ [KQ] = { min_pages = 0 } }),
        { quiz_min_chapter_pages = 5 })
    TestRunner:assertEqual(q.min_pages, 0)
end)

-- Per-book translation/dictionary language overrides
TestRunner:suite("applyLanguageOverride")

local SystemPrompts = require("prompts.system_prompts")
local KTL = BookSettings.KEY_TRANSLATION_LANG
local KDL = BookSettings.KEY_DICTIONARY_LANG

TestRunner:test("nil doc_settings → identity", function()
    local cfg = { translation_language = "x" }
    TestRunner:assertEqual(BookSettings.applyLanguageOverride(cfg, nil), cfg)
end)

TestRunner:test("no per-book keys → identity (same table)", function()
    local cfg = { translation_language = "x" }
    TestRunner:assertEqual(BookSettings.applyLanguageOverride(cfg, makeDocSettings({})), cfg)
end)

TestRunner:test("empty-string overrides are treated as follow-global (identity)", function()
    local cfg = { translation_language = "x" }
    TestRunner:assertEqual(BookSettings.applyLanguageOverride(cfg, makeDocSettings({ [KTL] = "", [KDL] = "" })), cfg)
end)

TestRunner:test("translation override → new table, forces use_primary=false", function()
    local cfg = { translation_use_primary = true, translation_language = "english" }
    local out = BookSettings.applyLanguageOverride(cfg, makeDocSettings({ [KTL] = "spanish" }))
    TestRunner:assertEqual(out.translation_language, "spanish")
    TestRunner:assertEqual(out.translation_use_primary, false)
    TestRunner:assertEqual(cfg.translation_use_primary, true, "input not mutated")
    TestRunner:assertEqual(cfg.translation_language, "english", "input not mutated")
end)

TestRunner:test("dictionary override → dictionary_language set, translation untouched", function()
    local out = BookSettings.applyLanguageOverride(
        { dictionary_language = "english", translation_language = "english", translation_use_primary = true },
        makeDocSettings({ [KDL] = "french" }))
    TestRunner:assertEqual(out.dictionary_language, "french")
    TestRunner:assertEqual(out.translation_use_primary, true, "dict override leaves translation alone")
end)

TestRunner:test("both overrides applied", function()
    local out = BookSettings.applyLanguageOverride(
        { translation_use_primary = true }, makeDocSettings({ [KTL] = "german", [KDL] = "italian" }))
    TestRunner:assertEqual(out.translation_language, "german")
    TestRunner:assertEqual(out.translation_use_primary, false)
    TestRunner:assertEqual(out.dictionary_language, "italian")
end)

-- End-to-end: the override must actually change the resolved language, even when the
-- global is set to "use primary" (which would otherwise ignore translation_language).
TestRunner:suite("integration: per-book language reaches the resolver")

TestRunner:test("book translation language wins over global use-primary", function()
    local base = {
        translation_use_primary = true,  -- global would use primary
        primary_language = "english",
        translation_language = "english",
    }
    local cfg = BookSettings.applyLanguageOverride(base, makeDocSettings({ [KTL] = "spanish" }))
    TestRunner:assertEqual(SystemPrompts.getEffectiveTranslationLanguage(cfg), "spanish")
    -- Without the override the global resolves to the primary. The resolver returns the
    -- primary as a display name ("English"); the override returns the raw id ("spanish"),
    -- exactly as the global translation_language picker does — the point is they differ.
    TestRunner:assertEqual(SystemPrompts.getEffectiveTranslationLanguage(base), "English")
end)

TestRunner:test("book dictionary language wins over global follow-translation", function()
    local base = {
        dictionary_language = "__FOLLOW_TRANSLATION__",
        translation_use_primary = true, primary_language = "english", translation_language = "english",
    }
    local cfg = BookSettings.applyLanguageOverride(base, makeDocSettings({ [KDL] = "japanese" }))
    TestRunner:assertEqual(SystemPrompts.getEffectiveDictionaryLanguage(cfg), "japanese")
end)

-- Per-book MAIN AI response language (the "Always respond in X" directive)
TestRunner:suite("applyResponseLanguageOverride")

local KRL = BookSettings.KEY_RESPONSE_LANG

TestRunner:test("nil doc_settings / no key / empty → identity", function()
    local cfg = { interaction_languages = { "english" } }
    TestRunner:assertEqual(BookSettings.applyResponseLanguageOverride(cfg, nil), cfg)
    TestRunner:assertEqual(BookSettings.applyResponseLanguageOverride(cfg, makeDocSettings({})), cfg)
    TestRunner:assertEqual(BookSettings.applyResponseLanguageOverride(cfg, makeDocSettings({ [KRL] = "" })), cfg)
end)

TestRunner:test("override prepends (deduped) and sets primary; input not mutated", function()
    local cfg = { interaction_languages = { "english", "french" }, primary_language = "english" }
    local out = BookSettings.applyResponseLanguageOverride(cfg, makeDocSettings({ [KRL] = "spanish" }))
    TestRunner:assertEqual(out.interaction_languages[1], "spanish", "book lang first")
    TestRunner:assertEqual(out.interaction_languages[2], "english")
    TestRunner:assertEqual(out.interaction_languages[3], "french")
    TestRunner:assertEqual(out.primary_language, "spanish")
    TestRunner:assertEqual(#cfg.interaction_languages, 2, "input list not mutated")
end)

TestRunner:test("override dedups when already present", function()
    local out = BookSettings.applyResponseLanguageOverride(
        { interaction_languages = { "english", "spanish" } }, makeDocSettings({ [KRL] = "spanish" }))
    TestRunner:assertEqual(out.interaction_languages[1], "spanish")
    TestRunner:assertEqual(out.interaction_languages[2], "english")
    TestRunner:assertEqual(#out.interaction_languages, 2, "no duplicate spanish")
end)

TestRunner:test("override parses the legacy comma-string list", function()
    local out = BookSettings.applyResponseLanguageOverride(
        { user_languages = "english, french" }, makeDocSettings({ [KRL] = "german" }))
    TestRunner:assertEqual(out.interaction_languages[1], "german")
    TestRunner:assertEqual(out.interaction_languages[2], "english")
    TestRunner:assertEqual(out.interaction_languages[3], "french")
end)

TestRunner:test("end-to-end: the response-language instruction switches to the book language", function()
    local cfg = BookSettings.applyResponseLanguageOverride(
        { interaction_languages = { "english" }, primary_language = "english" },
        makeDocSettings({ [KRL] = "spanish" }))
    local instr = SystemPrompts.buildLanguageInstruction(cfg.interaction_languages, cfg.primary_language)
    TestRunner:assertContains(instr, "Always respond in spanish")
    -- without the override the instruction would say english
    local base = SystemPrompts.buildLanguageInstruction({ "english" }, "english")
    TestRunner:assertContains(base, "Always respond in english")
end)

-- End-to-end quiz wiring: a per-book sidecar → resolveQuiz → the emitted instructions.
-- This is the path the quiz-instruction builder runs in handlePredefinedPrompt.
TestRunner:suite("quiz override reaches the emitted instructions")

local QuizPrompt = require("koassistant_quiz_prompt")

TestRunner:test("defaults (no override): 8 questions, medium, all three types", function()
    local instr = QuizPrompt.build(BookSettings.resolveQuiz(makeDocSettings({}), {}))
    TestRunner:assertContains(instr, "Generate exactly 8 questions")
    TestRunner:assertContains(instr, "Difficulty: Medium")
    TestRunner:assertContains(instr, "multiple_choice")
    TestRunner:assertContains(instr, "short_answer")
    TestRunner:assertContains(instr, "essay")
end)

TestRunner:test("per-book count+difficulty+types flow through to instructions", function()
    local ds = makeDocSettings({ [KQ] = { count = 4, difficulty = "hard", mc = true, sa = false, essay = false } })
    local instr = QuizPrompt.build(BookSettings.resolveQuiz(ds, {
        quiz_question_count = 12, quiz_difficulty = "easy",  -- globals that must be overridden
    }))
    TestRunner:assertContains(instr, "Generate exactly 4 questions", "per-book count wins")
    TestRunner:assertContains(instr, "Difficulty: Hard", "per-book difficulty wins")
    TestRunner:assertContains(instr, 'All 4 questions must be type "multiple_choice"', "single enabled type")
    TestRunner:assertNotContains(instr, "short_answer", "disabled type absent")
    TestRunner:assertNotContains(instr, "Generate exactly 12", "global count overridden")
end)

TestRunner:test("all types disabled per-book → falls back to multiple choice", function()
    local ds = makeDocSettings({ [KQ] = { mc = false, sa = false, essay = false } })
    local instr = QuizPrompt.build(BookSettings.resolveQuiz(ds, {}))
    TestRunner:assertContains(instr, "multiple_choice")
end)

-- Customized-count indicator + reset
TestRunner:suite("countCustomized + resetBook")

local function makeMutableDocSettings(map)
    return {
        _data = map or {},
        readSetting = function(self, k) return self._data[k] end,
        saveSetting = function(self, k, v) self._data[k] = v end,
        flush = function() end,
    }
end

TestRunner:test("nil / empty → 0 customized", function()
    TestRunner:assertEqual(BookSettings.countCustomized(nil), 0)
    TestRunner:assertEqual(BookSettings.countCustomized(makeDocSettings({})), 0)
end)

TestRunner:test('counts each non-nil key, including send-empty ("")', function()
    local ds = makeDocSettings({
        koassistant_book_domain = "philosophy",
        [KQ] = { count = 4 },
        [KT] = "",  -- send-empty title IS a customization
    })
    TestRunner:assertEqual(BookSettings.countCustomized(ds), 3)
end)

TestRunner:test("resetBook clears every owned key", function()
    local ds = makeMutableDocSettings({
        koassistant_book_domain = "philosophy",
        koassistant_book_research_mode = true,
        [KQ] = { count = 4 },
        [KT] = "IJ",
        [KTL] = "spanish",
    })
    TestRunner:assertEqual(BookSettings.countCustomized(ds), 5)
    BookSettings.resetBook(ds)
    TestRunner:assertEqual(BookSettings.countCustomized(ds), 0)
end)

TestRunner:test("setQuizField sets a field on an empty book (the popup's disable path)", function()
    local ds = makeMutableDocSettings({})
    BookSettings.setQuizField(ds, "enabled", false)
    TestRunner:assertEqual(BookSettings.resolveQuiz(ds, {}).enabled, false, "enabled=false persisted")
    TestRunner:assertEqual(ds._data[KQ].enabled, false)
end)
TestRunner:test("setQuizField merges without clobbering other fields", function()
    local ds = makeMutableDocSettings({ [KQ] = { count = 4 } })
    BookSettings.setQuizField(ds, "enabled", false)
    TestRunner:assertEqual(ds._data[KQ].count, 4, "existing field kept")
    TestRunner:assertEqual(ds._data[KQ].enabled, false)
end)
TestRunner:test("setQuizField clearing the only field drops the table", function()
    local ds = makeMutableDocSettings({ [KQ] = { enabled = false } })
    BookSettings.setQuizField(ds, "enabled", nil)
    TestRunner:assertNil(ds._data[KQ], "emptied table cleared")
end)
TestRunner:test("setQuizField nil doc_settings is a no-op", function()
    BookSettings.setQuizField(nil, "enabled", false)  -- must not error
end)

TestRunner:test("SIDECAR_KEYS covers all KEY_ constants", function()
    local present = {}
    for _i, k in ipairs(BookSettings.SIDECAR_KEYS) do present[k] = true end
    for _i, k in ipairs({ BookSettings.KEY_SPOILER_FREE, BookSettings.KEY_BOOK_INFO,
        BookSettings.KEY_AI_TITLE, BookSettings.KEY_AI_AUTHOR, BookSettings.KEY_QUIZ,
        BookSettings.KEY_TRANSLATION_LANG, BookSettings.KEY_DICTIONARY_LANG,
        BookSettings.KEY_RESPONSE_LANG }) do
        if not present[k] then error("SIDECAR_KEYS missing " .. tostring(k)) end
    end
end)

-- Reading-time gate (pass 2): resolveQuiz min_minutes + getReadingTimeInRange fail-open
TestRunner:suite("resolveQuiz min_minutes")

TestRunner:test("default 3 when nothing set (gate active out of the box)", function()
    TestRunner:assertEqual(BookSettings.resolveQuiz(makeDocSettings({}), {}).min_minutes, 3)
end)
TestRunner:test("falls back to global", function()
    TestRunner:assertEqual(
        BookSettings.resolveQuiz(makeDocSettings({}), { quiz_min_chapter_time = 3 }).min_minutes, 3)
end)
TestRunner:test("per-book wins over global", function()
    TestRunner:assertEqual(
        BookSettings.resolveQuiz(makeDocSettings({ [KQ] = { min_minutes = 10 } }),
            { quiz_min_chapter_time = 3 }).min_minutes, 10)
end)
TestRunner:test("per-book 0 overrides a non-zero global", function()
    TestRunner:assertEqual(
        BookSettings.resolveQuiz(makeDocSettings({ [KQ] = { min_minutes = 0 } }),
            { quiz_min_chapter_time = 3 }).min_minutes, 0)
end)

TestRunner:suite("getReadingTimeInRange fail-open")

local StatsReader = require("koassistant_stats_reader")
TestRunner:test("non-number args → nil", function()
    TestRunner:assertNil(StatsReader.getReadingTimeInRange("x", 1, 5))
    TestRunner:assertNil(StatsReader.getReadingTimeInRange(1, nil, 5))
end)
TestRunner:test("no stats DB available → nil (caller fails open)", function()
    TestRunner:assertNil(StatsReader.getReadingTimeInRange(1, 1, 5))
end)

TestRunner:suite("AI Book Tools posture (tools_ux_plan.md §1)")

local function fakeDocSettings(values)
    return { readSetting = function(_self, key) return values[key] end }
end

TestRunner:test("resolveBookTools: per-book override > global > false (schema default)", function()
    TestRunner:assertEqual(BookSettings.resolveBookTools(nil, nil), false,
        "no book, no features → false (must match the schema default; flipped 2026-08-17)")
    TestRunner:assertEqual(BookSettings.resolveBookTools(nil, { enable_book_tools = false }), false,
        "global off, no book override")
    local ds = fakeDocSettings({ koassistant_book_tools = false })
    TestRunner:assertEqual(BookSettings.resolveBookTools(ds, { enable_book_tools = true }), false,
        "per-book off wins over global on")
    ds = fakeDocSettings({ koassistant_book_tools = true })
    TestRunner:assertEqual(BookSettings.resolveBookTools(ds, { enable_book_tools = false }), true,
        "per-book on wins over global off")
end)

TestRunner:test("resolveBookTools: legacy posture strings keep resolving (sidecars never mass-migrate)", function()
    local ds = fakeDocSettings({ koassistant_book_tools = "auto" })
    TestRunner:assertEqual(BookSettings.resolveBookTools(ds, { enable_book_tools = false }), true,
        "legacy per-book auto → on")
    ds = fakeDocSettings({ koassistant_book_tools = "manual" })
    TestRunner:assertEqual(BookSettings.resolveBookTools(ds, { enable_book_tools = true }), false,
        "legacy per-book manual → off")
    ds = fakeDocSettings({ koassistant_book_tools = "off" })
    TestRunner:assertEqual(BookSettings.resolveBookTools(ds, { enable_book_tools = true }), false,
        "legacy per-book off → off (default only — no hard kill anymore)")
    TestRunner:assertEqual(BookSettings.resolveBookTools(nil, { tools_posture = "manual" }), false,
        "unmigrated legacy global manual → off")
    TestRunner:assertEqual(BookSettings.resolveBookTools(nil, { tools_posture = "auto" }), true,
        "unmigrated legacy global auto → on")
    TestRunner:assertEqual(BookSettings.resolveBookTools(nil,
        { enable_book_tools = true, tools_posture = "off" }), true,
        "new key wins over stale legacy key")
end)

TestRunner:test("resolveBookTools: unknown values fall through, never wedge", function()
    local ds = fakeDocSettings({ koassistant_book_tools = "banana" })
    TestRunner:assertEqual(BookSettings.resolveBookTools(ds, { enable_book_tools = false }), false,
        "corrupt sidecar value falls through to the global")
    TestRunner:assertEqual(BookSettings.resolveBookTools(nil, { tools_posture = 42 }), false,
        "corrupt legacy global falls through to the default (off)")
end)

TestRunner:test("KEY_TOOLS is registered in SIDECAR_KEYS (reset/count coverage)", function()
    local found = false
    for _i, key in ipairs(BookSettings.SIDECAR_KEYS) do
        if key == BookSettings.KEY_TOOLS then found = true end
    end
    TestRunner:assertEqual(found, true, "koassistant_book_tools missing from SIDECAR_KEYS")
end)

TestRunner:suite("Web search per-book layer (book_scoped_controls_plan.md §5)")

TestRunner:test("webSearchOverride: tri-state raw override", function()
    TestRunner:assertNil(BookSettings.webSearchOverride(nil), "no book → nil")
    TestRunner:assertNil(BookSettings.webSearchOverride(fakeDocSettings({})), "no override → nil")
    TestRunner:assertEqual(BookSettings.webSearchOverride(
        fakeDocSettings({ koassistant_book_web_search = true })), true, "explicit on")
    TestRunner:assertEqual(BookSettings.webSearchOverride(
        fakeDocSettings({ koassistant_book_web_search = false })), false, "explicit off")
end)

TestRunner:test("resolveWebSearch: per-book override > global (opt-in, default false)", function()
    TestRunner:assertEqual(BookSettings.resolveWebSearch(nil, nil), false,
        "no book, no features → false (matches schema default)")
    TestRunner:assertEqual(BookSettings.resolveWebSearch(nil, { enable_web_search = true }), true,
        "global on, no book")
    local ds = fakeDocSettings({ koassistant_book_web_search = false })
    TestRunner:assertEqual(BookSettings.resolveWebSearch(ds, { enable_web_search = true }), false,
        "per-book off wins over global on")
    ds = fakeDocSettings({ koassistant_book_web_search = true })
    TestRunner:assertEqual(BookSettings.resolveWebSearch(ds, { enable_web_search = false }), true,
        "per-book on wins over global off")
    ds = fakeDocSettings({})
    TestRunner:assertEqual(BookSettings.resolveWebSearch(ds, {}), false,
        "no layers set → off")
end)

TestRunner:suite("Effort dials per-book layer (T1: chip-hold effort surfacing)")

TestRunner:test("resolveToolEffort: per-book override > global > standard", function()
    TestRunner:assertEqual(BookSettings.resolveToolEffort(nil, nil), "standard",
        "no book, no features → standard (schema default)")
    TestRunner:assertEqual(BookSettings.resolveToolEffort(nil, { tool_lookup_effort = "thorough" }), "thorough",
        "global used when no book override")
    local ds = fakeDocSettings({ koassistant_book_tool_effort = "quick" })
    TestRunner:assertEqual(BookSettings.resolveToolEffort(ds, { tool_lookup_effort = "thorough" }), "quick",
        "per-book wins over global")
    TestRunner:assertEqual(BookSettings.resolveToolEffort(
        fakeDocSettings({ koassistant_book_tool_effort = "bogus" }), { tool_lookup_effort = "thorough" }), "thorough",
        "invalid per-book falls through to global")
    TestRunner:assertEqual(BookSettings.resolveToolEffort(fakeDocSettings({}), { tool_lookup_effort = "nonsense" }),
        "standard", "invalid global falls through to standard")
end)

TestRunner:test("resolveWebEffort: per-book override > global > standard", function()
    TestRunner:assertEqual(BookSettings.resolveWebEffort(nil, nil), "standard",
        "no book, no features → standard")
    TestRunner:assertEqual(BookSettings.resolveWebEffort(nil, { web_search_effort = "light" }), "light",
        "global used when no book override")
    local ds = fakeDocSettings({ koassistant_book_web_effort = "thorough" })
    TestRunner:assertEqual(BookSettings.resolveWebEffort(ds, { web_search_effort = "light" }), "thorough",
        "per-book wins over global")
    TestRunner:assertEqual(BookSettings.resolveWebEffort(
        fakeDocSettings({ koassistant_book_web_effort = "quick" }), { web_search_effort = "light" }), "light",
        "invalid per-book (quick is tools-only) falls through to global")
end)

TestRunner:test("effort labels map values (standard is the fallback)", function()
    TestRunner:assertEqual(BookSettings.toolEffortLabel("quick"), "Quick", "tool quick")
    TestRunner:assertEqual(BookSettings.toolEffortLabel("thorough"), "Thorough", "tool thorough")
    TestRunner:assertEqual(BookSettings.toolEffortLabel(nil), "Standard", "tool nil → Standard")
    TestRunner:assertEqual(BookSettings.webEffortLabel("light"), "Light", "web light")
    TestRunner:assertEqual(BookSettings.webEffortLabel("thorough"), "Thorough", "web thorough")
    TestRunner:assertEqual(BookSettings.webEffortLabel(nil), "Standard", "web nil → Standard")
end)

TestRunner:test("KEY_TOOL_EFFORT and KEY_WEB_EFFORT are in SIDECAR_KEYS (reset/count coverage)", function()
    local have = {}
    for _i, key in ipairs(BookSettings.SIDECAR_KEYS) do have[key] = true end
    TestRunner:assertEqual(have[BookSettings.KEY_TOOL_EFFORT], true, "tool effort key registered")
    TestRunner:assertEqual(have[BookSettings.KEY_WEB_EFFORT], true, "web effort key registered")
end)

TestRunner:test("KEY_WEB_SEARCH and KEY_DOMAIN/KEY_RESEARCH are in SIDECAR_KEYS", function()
    local found = {}
    for _i, key in ipairs(BookSettings.SIDECAR_KEYS) do found[key] = true end
    TestRunner:assertEqual(found[BookSettings.KEY_WEB_SEARCH] == true, true,
        "koassistant_book_web_search missing from SIDECAR_KEYS")
    TestRunner:assertEqual(found["koassistant_book_domain"] == true, true,
        "KEY_DOMAIN constant must keep the original key string")
    TestRunner:assertEqual(found["koassistant_book_research_mode"] == true, true,
        "KEY_RESEARCH constant must keep the original key string")
    TestRunner:assertEqual(found[BookSettings.KEY_HIGHLIGHT_CONTEXT] == true, true,
        "koassistant_book_highlight_context missing from SIDECAR_KEYS")
    TestRunner:assertEqual(found[BookSettings.KEY_DICTIONARY_CONTEXT] == true, true,
        "koassistant_book_dictionary_context missing from SIDECAR_KEYS")
    TestRunner:assertEqual(found[BookSettings.KEY_XRAY_AUTO] == true, true,
        "koassistant_book_xray_auto missing from SIDECAR_KEYS")
    TestRunner:assertEqual(found[BookSettings.KEY_QUICK_ANSWER] == true, true,
        "koassistant_book_quick_answer missing from SIDECAR_KEYS")
    TestRunner:assertEqual(found[BookSettings.KEY_TOOL_EFFORT] == true, true,
        "koassistant_book_tool_effort missing from SIDECAR_KEYS")
    TestRunner:assertEqual(found[BookSettings.KEY_WEB_EFFORT] == true, true,
        "koassistant_book_web_effort missing from SIDECAR_KEYS")
    TestRunner:assertEqual(found[BookSettings.KEY_XRAY_GOAL] == true, true,
        "koassistant_book_xray_goal missing from SIDECAR_KEYS (round 21)")
    TestRunner:assertEqual(found[BookSettings.KEY_BACKGROUND] == true, true,
        "koassistant_book_background missing from SIDECAR_KEYS (book_background_plan.md)")
    TestRunner:assertEqual(found[BookSettings.KEY_XRAY_SPACING] == true, true,
        "koassistant_book_xray_spacing missing from SIDECAR_KEYS (spacing slice)")
    TestRunner:assertEqual(#BookSettings.SIDECAR_KEYS, 37, "37 per-book keys expected (incl. 4 privacy overrides + xray promotion hold + checkpoint spacing + 9 marking & lookup overrides incl. upcoming-entities, intercept, card, card length, ahead card (B269) + xray categories + xray depth (2026-08-25); xray highlights removed with reader engagement 2026-08-18)")
end)

TestRunner:suite("resolveXrayMarking (2026-08-15: popup edits the book layer)")
TestRunner:test("nothing set: schema defaults, no override", function()
    local m = BookSettings.resolveXrayMarking(makeDocSettings({}), {})
    TestRunner:assertEqual(m.enabled, true, "marking default ON")
    TestRunner:assertEqual(m.density, "10", "density default")
    TestRunner:assertEqual(m.families, "all", "families default")
    TestRunner:assertEqual(m.tap, true, "tap default ON")
    TestRunner:assertEqual(m.has_override, false, "no override")
end)
TestRunner:test("globals flow through when book layer empty", function()
    local m = BookSettings.resolveXrayMarking(makeDocSettings({}),
        { xray_marking = false, xray_marking_density = "all", xray_marking_families = "people" })
    TestRunner:assertEqual(m.enabled, false, "global off honored")
    TestRunner:assertEqual(m.density, "all", "global density")
    TestRunner:assertEqual(m.families, "people", "global families")
    TestRunner:assertEqual(m.has_override, false, "still no book override")
end)
TestRunner:test("book layer beats globals both directions", function()
    local m = BookSettings.resolveXrayMarking(makeDocSettings({
        [BookSettings.KEY_XRAY_MARKING] = true,
        [BookSettings.KEY_XRAY_MARKING_DENSITY] = "once",
        [BookSettings.KEY_XRAY_MARKING_TAP] = false,
    }), { xray_marking = false, xray_marking_density = "all", xray_marking_tap = true })
    TestRunner:assertEqual(m.enabled, true, "book ON beats global off")
    TestRunner:assertEqual(m.density, "once", "book density wins")
    TestRunner:assertEqual(m.tap, false, "book tap-off beats global on")
    TestRunner:assertEqual(m.families, "all", "unset family follows global default chain")
    TestRunner:assertEqual(m.has_override, true, "override flagged")
end)
TestRunner:test("nil doc_settings = global-only resolution", function()
    local m = BookSettings.resolveXrayMarking(nil, { xray_marking_density = "25" })
    TestRunner:assertEqual(m.density, "25", "globals only")
    TestRunner:assertEqual(m.has_override, false, "no ds, no override")
end)
TestRunner:test("intercept + card (round 5): defaults, book layer beats the global pair", function()
    local m = BookSettings.resolveXrayMarking(makeDocSettings({}), {})
    TestRunner:assertEqual(m.intercept, true, "intercept default ON")
    TestRunner:assertEqual(m.card, "footnote", "card default footnote")
    m = BookSettings.resolveXrayMarking(makeDocSettings({}),
        { xray_selection_intercept = false, xray_card_landing = false })
    TestRunner:assertEqual(m.intercept, false, "global intercept off honored")
    TestRunner:assertEqual(m.card, "full", "global landing-off maps to full")
    m = BookSettings.resolveXrayMarking(makeDocSettings({}),
        { xray_card_style = "popup" })
    TestRunner:assertEqual(m.card, "popup", "global style popup maps through")
    m = BookSettings.resolveXrayMarking(makeDocSettings({
        [BookSettings.KEY_XRAY_INTERCEPT] = false,
        [BookSettings.KEY_XRAY_CARD] = "popup",
    }), { xray_card_landing = false })
    TestRunner:assertEqual(m.intercept, false, "book intercept-off beats default-on global")
    TestRunner:assertEqual(m.card, "popup", "book card beats the global pair")
    TestRunner:assertEqual(m.has_override, true, "override flagged")
    m = BookSettings.resolveXrayMarking(makeDocSettings({
        [BookSettings.KEY_XRAY_CARD] = "bogus",
    }), {})
    TestRunner:assertEqual(m.card, "footnote", "junk book card value falls to the global chain")
end)

TestRunner:test("ahead (Upcoming Entities): default ON, tri-state book layer beats global", function()
    local m = BookSettings.resolveXrayMarking(makeDocSettings({}), {})
    TestRunner:assertEqual(m.ahead, true, "ahead default ON")
    m = BookSettings.resolveXrayMarking(makeDocSettings({}),
        { xray_show_ahead_entities = false })
    TestRunner:assertEqual(m.ahead, false, "global off honored")
    TestRunner:assertEqual(m.has_override, false, "global off is not a book override")
    m = BookSettings.resolveXrayMarking(makeDocSettings({
        [BookSettings.KEY_XRAY_AHEAD] = true,
    }), { xray_show_ahead_entities = false })
    TestRunner:assertEqual(m.ahead, true, "book ON beats global off")
    TestRunner:assertEqual(m.has_override, true, "override flagged")
    m = BookSettings.resolveXrayMarking(makeDocSettings({
        [BookSettings.KEY_XRAY_AHEAD] = false,
    }), {})
    TestRunner:assertEqual(m.ahead, false, "book OFF beats default-on global")
end)

TestRunner:test("xraySpacingOverride: valid ratio passes, junk and out-of-range are nil", function()
    local function ds_with(v)
        return { readSetting = function(_, key)
            if key == BookSettings.KEY_XRAY_SPACING then return v end
        end }
    end
    TestRunner:assertEqual(BookSettings.xraySpacingOverride(ds_with(0.05)), 0.05, "5% override")
    TestRunner:assertEqual(BookSettings.xraySpacingOverride(ds_with(0.025)), 0.025, "2.5% override")
    TestRunner:assertEqual(BookSettings.xraySpacingOverride(ds_with(nil)), nil, "unset = formula")
    TestRunner:assertEqual(BookSettings.xraySpacingOverride(ds_with(0)), nil, "zero rejected")
    TestRunner:assertEqual(BookSettings.xraySpacingOverride(ds_with(0.9)), nil, "above half rejected")
    TestRunner:assertEqual(BookSettings.xraySpacingOverride(ds_with("junk")), nil, "junk rejected")
    TestRunner:assertEqual(BookSettings.xraySpacingOverride(nil), nil, "no doc_settings")
end)

TestRunner:suite("Quick Answer default (controls_parity_plan.md §8c.7)")

TestRunner:test("resolveQuickAnswerDefault: per-book override > global (opt-in, default false)", function()
    local ds_on = { readSetting = function(_, key)
        if key == BookSettings.KEY_QUICK_ANSWER then return true end
    end }
    local ds_off = { readSetting = function(_, key)
        if key == BookSettings.KEY_QUICK_ANSWER then return false end
    end }
    local ds_nil = { readSetting = function() return nil end }
    TestRunner:assertEqual(BookSettings.resolveQuickAnswerDefault(ds_on, { quick_answer_default = false }), true,
        "per-book true beats global false")
    TestRunner:assertEqual(BookSettings.resolveQuickAnswerDefault(ds_off, { quick_answer_default = true }), false,
        "per-book false beats global true")
    TestRunner:assertEqual(BookSettings.resolveQuickAnswerDefault(ds_nil, { quick_answer_default = true }), true,
        "nil override follows global true")
    TestRunner:assertEqual(BookSettings.resolveQuickAnswerDefault(nil, {}), false,
        "no book, unset global = off (opt-in default)")
end)

TestRunner:suite("Surrounding-context per-book layer (surrounding_context_plan.md §2)")

TestRunner:test("resolveHighlightContext: per-book override > global > none", function()
    local ds = fakeDocSettings({ [BookSettings.KEY_HIGHLIGHT_CONTEXT] = "paragraph" })
    TestRunner:assertEqual(BookSettings.resolveHighlightContext(ds, { highlight_context_mode = "sentence" }),
        "paragraph", "per-book wins over global")
    ds = fakeDocSettings({ [BookSettings.KEY_HIGHLIGHT_CONTEXT] = "none" })
    TestRunner:assertEqual(BookSettings.resolveHighlightContext(ds, { highlight_context_mode = "sentence" }),
        "none", "per-book none silences a global mode")
    ds = fakeDocSettings({})
    TestRunner:assertEqual(BookSettings.resolveHighlightContext(ds, { highlight_context_mode = "sentence" }),
        "sentence", "no override → global")
    TestRunner:assertEqual(BookSettings.resolveHighlightContext(ds, {}),
        "none", "nothing set → none (ambient is opt-in)")
    TestRunner:assertEqual(BookSettings.resolveHighlightContext(nil, nil),
        "none", "nil-safe")
    ds = fakeDocSettings({ [BookSettings.KEY_HIGHLIGHT_CONTEXT] = "bogus" })
    TestRunner:assertEqual(BookSettings.resolveHighlightContext(ds, { highlight_context_mode = "sentence" }),
        "sentence", "unknown stored value falls through to global")
end)

TestRunner:test("resolveDictionaryContext: per-book override > global > sentence", function()
    local ds = fakeDocSettings({ [BookSettings.KEY_DICTIONARY_CONTEXT] = "characters" })
    TestRunner:assertEqual(BookSettings.resolveDictionaryContext(ds, { dictionary_context_mode = "none" }),
        "characters", "per-book wins over global")
    ds = fakeDocSettings({ [BookSettings.KEY_DICTIONARY_CONTEXT] = "none" })
    TestRunner:assertEqual(BookSettings.resolveDictionaryContext(ds, { dictionary_context_mode = "sentence" }),
        "none", "per-book none silences a global mode")
    ds = fakeDocSettings({})
    TestRunner:assertEqual(BookSettings.resolveDictionaryContext(ds, { dictionary_context_mode = "paragraph" }),
        "paragraph", "no override → global")
    TestRunner:assertEqual(BookSettings.resolveDictionaryContext(ds, { dictionary_context_mode = "none" }),
        "none", "explicit global none is honored")
    TestRunner:assertEqual(BookSettings.resolveDictionaryContext(ds, {}),
        "sentence", "nothing set → sentence (defaults sweep D1)")
    TestRunner:assertEqual(BookSettings.resolveDictionaryContext(nil, nil),
        "sentence", "nil-safe")
end)

TestRunner:suite("D3 smart retrieval — {document_context_section} (tools_ux_plan.md §4)")

TestRunner:test("smart_retrieval mode labels the bundle as retrieved passages", function()
    local result = MessageBuilder.build({
        prompt = { prompt = "Q\n\n{document_context_section}\n\n{text_fallback_nudge}" },
        context = "highlight",
        data = { _source_mode = "smart_retrieval", full_document = "PASSAGE-A\n\nPASSAGE-B" },
    })
    TestRunner:assertContains(result, "Passages retrieved from the book", "bundle label present")
    TestRunner:assertContains(result, "PASSAGE-A", "bundle content present")
    TestRunner:assertNotContains(result, "Full document:", "not mislabeled as full text")
    TestRunner:assertNotContains(result, "No document text was provided", "fallback nudge absent")
end)

TestRunner:test("zero-gather smart retrieval resolves empty and fires the fallback nudge", function()
    local result = MessageBuilder.build({
        prompt = { prompt = "Q\n\n{document_context_section}\n\n{text_fallback_nudge}" },
        context = "highlight",
        data = { _source_mode = "smart_retrieval" },
    })
    TestRunner:assertNotContains(result, "Passages retrieved", "no bundle label without a bundle")
    TestRunner:assertContains(result, "No document text was provided", "fallback nudge fires")
end)

TestRunner:suite("Automatic X-Ray tri-state (xray_ecosystem_plan.md §7 P1)")

TestRunner:test("xrayAutoOverride: strings win; legacy true needs the migration grant", function()
    local function ds(v) return { readSetting = function(_, key)
        if key == BookSettings.KEY_XRAY_AUTO then return v end
    end } end
    TestRunner:assertEqual(BookSettings.xrayAutoOverride(ds("on"), {}), "on", "string on")
    TestRunner:assertEqual(BookSettings.xrayAutoOverride(ds("off"), {}), "off", "string off")
    TestRunner:assertEqual(BookSettings.xrayAutoOverride(ds(nil), {}), nil, "unset = follow")
    -- Legacy boolean true: honored ONLY with the migration's master-was-on grant
    TestRunner:assertEqual(BookSettings.xrayAutoOverride(ds(true), { _xray_auto_legacy_optin = true }), "on",
        "legacy opt-in honored when the old master was on")
    TestRunner:assertEqual(BookSettings.xrayAutoOverride(ds(true), {}), nil,
        "legacy opt-in inert without the grant (old master was off)")
    TestRunner:assertEqual(BookSettings.xrayAutoOverride(nil, {}), nil, "no doc_settings = follow")
end)

TestRunner:test("resolveXrayAuto: per-book On bundles create; follow needs master+create", function()
    local function ds(v) return { readSetting = function(_, key)
        if key == BookSettings.KEY_XRAY_AUTO then return v end
    end } end
    local auto, create = BookSettings.resolveXrayAuto(ds("on"), {})
    TestRunner:assertEqual(auto, true, "per-book On is standalone (global off)")
    TestRunner:assertEqual(create, true, "per-book On bundles auto-create")
    auto, create = BookSettings.resolveXrayAuto(ds("off"), { xray_auto_update = true, xray_auto_create = true })
    TestRunner:assertEqual(auto, false, "per-book Off beats global on")
    TestRunner:assertEqual(create, false, "per-book Off kills create too")
    auto, create = BookSettings.resolveXrayAuto(ds(nil), { xray_auto_update = true })
    TestRunner:assertEqual(auto, true, "follow-global inherits the all-books master")
    TestRunner:assertEqual(create, false, "follow-global create needs the sub-toggle")
    auto, create = BookSettings.resolveXrayAuto(ds(nil), { xray_auto_update = true, xray_auto_create = true })
    TestRunner:assertEqual(create, true, "follow-global create with the sub-toggle on")
    auto = BookSettings.resolveXrayAuto(ds(nil), {})
    TestRunner:assertEqual(auto, false, "everything unset = off (schema default)")
end)

TestRunner:suite("Per-book Background (book_background_plan.md)")

local function bgDs(v)
    return { readSetting = function(_, key)
        if key == BookSettings.KEY_BACKGROUND then return v end
    end }
end

TestRunner:test("getBackground: unset / blank / non-string → nil", function()
    TestRunner:assertNil(BookSettings.getBackground(nil), "no doc_settings")
    TestRunner:assertNil(BookSettings.getBackground(bgDs(nil)), "unset")
    TestRunner:assertNil(BookSettings.getBackground(bgDs("")), "empty string")
    TestRunner:assertNil(BookSettings.getBackground(bgDs("   \n  ")), "whitespace only")
    TestRunner:assertNil(BookSettings.getBackground(bgDs(true)), "non-string value")
end)

TestRunner:test("getBackground: trims surrounding whitespace", function()
    TestRunner:assertEqual(BookSettings.getBackground(bgDs("  reading this critically \n")),
        "reading this critically", "trimmed")
end)

TestRunner:test("getBackground: caps over-long text (UTF-8 safe)", function()
    local long = string.rep("a", BookSettings.BACKGROUND_MAX_CHARS + 500)
    local out = BookSettings.getBackground(bgDs(long))
    TestRunner:assertEqual(#out <= BookSettings.BACKGROUND_MAX_CHARS, true, "capped to the max")
    -- Multi-byte tail must not be cut mid-sequence
    local multi = string.rep("é", BookSettings.BACKGROUND_MAX_CHARS)  -- 2 bytes each
    local out2 = BookSettings.getBackground(bgDs(multi))
    TestRunner:assertEqual(#out2 <= BookSettings.BACKGROUND_MAX_CHARS, true, "multibyte capped")
    TestRunner:assertEqual(#out2 % 2, 0, "no half codepoint at the tail")
end)

TestRunner:test("backgroundRowLabel: 'not set' when empty, preview when set", function()
    TestRunner:assertEqual(BookSettings.backgroundRowLabel(bgDs(nil)), "not set", "unset label")
    TestRunner:assertEqual(BookSettings.backgroundRowLabel(bgDs("short note")), "short note", "short preview")
    local label = BookSettings.backgroundRowLabel(bgDs(string.rep("x", 100)))
    TestRunner:assertEqual(#label < 40, true, "long value is previewed, not dumped")
    TestRunner:assertEqual(BookSettings.backgroundRowLabel(bgDs("two\nlines here")), "two lines here",
        "newlines collapsed for the row")
end)

--==========================================================================
TestRunner:suite("Per-book privacy overrides (effectivePrivacyOverrides)")

local function privDs(store)
    return { readSetting = function(_self, key) return store[key] end }
end

TestRunner:test("no overrides: everything nil (follow global)", function()
    local out = BookSettings.effectivePrivacyOverrides(privDs({}))
    TestRunner:assertNil(out.highlights, "highlights")
    TestRunner:assertNil(out.annotations, "annotations")
    TestRunner:assertNil(out.notebook, "notebook")
    TestRunner:assertNil(out.book_text, "book_text")
    local none = BookSettings.effectivePrivacyOverrides(nil)
    TestRunner:assertNil(none.highlights, "nil doc_settings tolerated")
end)

TestRunner:test("allow annotations implies allow highlights", function()
    local out = BookSettings.effectivePrivacyOverrides(privDs({
        [BookSettings.KEY_ANNOTATIONS_SHARING] = true,
    }))
    TestRunner:assertEqual(out.annotations, true, "annotations allowed")
    TestRunner:assertEqual(out.highlights, true, "highlights implied")
end)

TestRunner:test("deny highlights implies deny annotations (deny wins over stored allow)", function()
    local out = BookSettings.effectivePrivacyOverrides(privDs({
        [BookSettings.KEY_HIGHLIGHTS_SHARING] = false,
        [BookSettings.KEY_ANNOTATIONS_SHARING] = true,
    }))
    TestRunner:assertEqual(out.highlights, false, "highlights denied")
    TestRunner:assertEqual(out.annotations, false, "annotations denied by implication")
end)

TestRunner:test("corrupt non-boolean sidecar values read as follow-global (fail-closed)", function()
    local out = BookSettings.effectivePrivacyOverrides(privDs({
        [BookSettings.KEY_TEXT_EXTRACTION] = "off",
        [BookSettings.KEY_NOTEBOOK_SHARING] = 1,
    }))
    TestRunner:assertNil(out.book_text, "string value must not grant or deny")
    TestRunner:assertNil(out.notebook, "number value must not grant or deny")
end)

TestRunner:test("notebook and book_text pass through in both directions", function()
    local allow = BookSettings.effectivePrivacyOverrides(privDs({
        [BookSettings.KEY_NOTEBOOK_SHARING] = true,
        [BookSettings.KEY_TEXT_EXTRACTION] = true,
    }))
    TestRunner:assertEqual(allow.notebook, true, "notebook allow")
    TestRunner:assertEqual(allow.book_text, true, "book_text allow")
    local deny = BookSettings.effectivePrivacyOverrides(privDs({
        [BookSettings.KEY_NOTEBOOK_SHARING] = false,
        [BookSettings.KEY_TEXT_EXTRACTION] = false,
    }))
    TestRunner:assertEqual(deny.notebook, false, "notebook deny")
    TestRunner:assertEqual(deny.book_text, false, "book_text deny")
end)

TestRunner:test("privacy keys are in SIDECAR_KEYS (reset/count/registry coverage)", function()
    local want = {
        [BookSettings.KEY_HIGHLIGHTS_SHARING] = true,
        [BookSettings.KEY_ANNOTATIONS_SHARING] = true,
        [BookSettings.KEY_NOTEBOOK_SHARING] = true,
        [BookSettings.KEY_TEXT_EXTRACTION] = true,
    }
    for _i, key in ipairs(BookSettings.SIDECAR_KEYS) do
        want[key] = nil
    end
    TestRunner:assertNil(next(want), "all four privacy keys registered")
end)

TestRunner:suite("X-Ray spoiler posture (xray_ecosystem_plan.md 50(f)+(g))")

TestRunner:test("resolveXrayPosture: default (nothing set) is TRACK (the §4.3 flip)", function()
    local posture, reason = BookSettings.resolveXrayPosture(nil, nil)
    TestRunner:assertEqual(posture, "track", "no settings anywhere -> track")
    TestRunner:assertEqual(reason, "global", "reason is the global layer")
    posture = BookSettings.resolveXrayPosture(fakeDocSettings({}), {})
    TestRunner:assertEqual(posture, "track", "empty book + empty features -> track")
    -- The opt-out: explicit global false restores newest-first installs
    posture = BookSettings.resolveXrayPosture(fakeDocSettings({}), { spoiler_free_chat = false })
    TestRunner:assertEqual(posture, "full", "explicit global off -> full")
end)

TestRunner:test("resolveXrayPosture: global spoiler_free_chat -> track", function()
    local posture, reason = BookSettings.resolveXrayPosture(
        fakeDocSettings({}), { spoiler_free_chat = true })
    TestRunner:assertEqual(posture, "track", "global spoiler protection -> track")
    TestRunner:assertEqual(reason, "global", "global layer")
end)

TestRunner:test("xrayPromotionHold: only the \"position\" sentinel pins (device round 5)", function()
    TestRunner:assertEqual(BookSettings.xrayPromotionHold(nil), false, "no ds -> no hold")
    TestRunner:assertEqual(BookSettings.xrayPromotionHold(fakeDocSettings({})), false, "unset -> no hold")
    TestRunner:assertEqual(BookSettings.xrayPromotionHold(
        fakeDocSettings({ koassistant_book_xray_promotion = "position" })), true, "position -> hold")
    TestRunner:assertEqual(BookSettings.xrayPromotionHold(
        fakeDocSettings({ koassistant_book_xray_promotion = true })), false, "other values -> no hold")
end)

TestRunner:test("resolveXrayPosture: per-book spoiler override wins both ways", function()
    local ds_on = fakeDocSettings({ koassistant_book_spoiler_free = true })
    local ds_off = fakeDocSettings({ koassistant_book_spoiler_free = false })
    local posture, reason = BookSettings.resolveXrayPosture(ds_on, { spoiler_free_chat = false })
    TestRunner:assertEqual(posture, "track", "book true -> track over explicit global-off")
    TestRunner:assertEqual(reason, "book", "book layer")
    posture = BookSettings.resolveXrayPosture(ds_off, { spoiler_free_chat = true })
    TestRunner:assertEqual(posture, "full", "book false -> full over global-on")
end)

TestRunner:test("resolveXrayPosture: research disables spoiler gating (book > global research)", function()
    local posture, reason = BookSettings.resolveXrayPosture(
        fakeDocSettings({ koassistant_book_research_mode = true }), { spoiler_free_chat = true })
    TestRunner:assertEqual(posture, "full", "book research beats global spoiler protection")
    TestRunner:assertEqual(reason, "research", "research layer named for labels")
    posture = BookSettings.resolveXrayPosture(
        fakeDocSettings({}), { research_mode = true, spoiler_free_chat = true })
    TestRunner:assertEqual(posture, "full", "global research beats global spoiler protection")
    posture = BookSettings.resolveXrayPosture(
        fakeDocSettings({ koassistant_book_research_mode = false }),
        { research_mode = true, spoiler_free_chat = true })
    TestRunner:assertEqual(posture, "track", "book research OFF re-enables the global spoiler layer")
end)

TestRunner:test("resolveXrayPosture: research beats even an explicit per-book spoiler (50(g) rule)", function()
    local ds = fakeDocSettings({
        koassistant_book_spoiler_free = true,
        koassistant_book_research_mode = true,
    })
    local posture, reason = BookSettings.resolveXrayPosture(ds, {})
    TestRunner:assertEqual(posture, "full", "active research disables spoiler gating outright")
    TestRunner:assertEqual(reason, "research", "research layer")
    -- The escape hatch: book research OFF re-enables the spoiler layers
    posture = BookSettings.resolveXrayPosture(fakeDocSettings({
        koassistant_book_spoiler_free = true,
        koassistant_book_research_mode = false,
    }), { research_mode = true })
    TestRunner:assertEqual(posture, "track", "book research=false falls through to the spoiler layers")
end)

TestRunner:suite("resolveSpoilerPosture (spoiler_posture_plan.md §2 — one resolver, two layers)")

TestRunner:test("request layer: session chip beats everything, both ways", function()
    local p = BookSettings.resolveSpoilerPosture(
        fakeDocSettings({ koassistant_book_spoiler_free = true }),
        { spoiler_free_chat = true }, { session = false })
    TestRunner:assertEqual(p.protected, false, "chip off un-protects over book+global on")
    TestRunner:assertEqual(p.reason, "session")
    TestRunner:assertEqual(p.layer, "request", "request is the default layer")
    p = BookSettings.resolveSpoilerPosture(
        fakeDocSettings({ koassistant_book_research_mode = true }), {}, { session = true })
    TestRunner:assertEqual(p.protected, true,
        "chip on protects even over research — an explicit per-chat ask")
    TestRunner:assertEqual(p.reason, "session")
end)

TestRunner:test("mechanical layer ignores the session chip by design", function()
    -- A per-chat toggle must never silently reinstall a different X-Ray version.
    local p = BookSettings.resolveSpoilerPosture(
        fakeDocSettings({}), { spoiler_free_chat = true },
        { layer = "mechanical", session = false })
    TestRunner:assertEqual(p.protected, true, "global protection holds; chip not consulted")
    TestRunner:assertEqual(p.reason, "global")
    TestRunner:assertEqual(p.layer, "mechanical")
end)

TestRunner:test("research > book > global; book research OFF is the escape hatch", function()
    local p = BookSettings.resolveSpoilerPosture(fakeDocSettings({
        koassistant_book_spoiler_free = true,
        koassistant_book_research_mode = true,
    }), {})
    TestRunner:assertEqual(p.protected, false, "research disables outright, even over book spoiler on")
    TestRunner:assertEqual(p.reason, "research")
    p = BookSettings.resolveSpoilerPosture(
        fakeDocSettings({ koassistant_book_spoiler_free = false }), { spoiler_free_chat = true })
    TestRunner:assertEqual(p.protected, false, "book off beats global on")
    TestRunner:assertEqual(p.reason, "book")
    p = BookSettings.resolveSpoilerPosture(
        fakeDocSettings({ koassistant_book_research_mode = false }),
        { research_mode = true, spoiler_free_chat = true })
    TestRunner:assertEqual(p.protected, true, "book research OFF re-enables the global spoiler layer")
    TestRunner:assertEqual(p.reason, "global")
end)

TestRunner:test("finished book stands protection down (2026-08-11)", function()
    local p = BookSettings.resolveSpoilerPosture(fakeDocSettings({
        summary = { status = "complete" },
        koassistant_book_spoiler_free = true,
    }), { spoiler_free_chat = true })
    TestRunner:assertEqual(p.protected, false,
        "finished disables outright, even over book+global spoiler on")
    TestRunner:assertEqual(p.reason, "finished")
    -- The session chip is an explicit per-chat ask — honored even when finished
    p = BookSettings.resolveSpoilerPosture(
        fakeDocSettings({ summary = { status = "complete" } }), {}, { session = true })
    TestRunner:assertEqual(p.protected, true, "chip on protects over finished")
    TestRunner:assertEqual(p.reason, "session")
    -- Research sits above finished in the chain (both stand down; label order)
    p = BookSettings.resolveSpoilerPosture(fakeDocSettings({
        summary = { status = "complete" },
        koassistant_book_research_mode = true,
    }), {})
    TestRunner:assertEqual(p.reason, "research")
    -- Un-finishing restores whatever was stored
    p = BookSettings.resolveSpoilerPosture(
        fakeDocSettings({ summary = { status = "reading" } }), {})
    TestRunner:assertEqual(p.protected, true, "a reading status changes nothing")
    TestRunner:assertEqual(p.reason, "default")
    -- Mechanical layer: finished flips the X-Ray posture to full
    local posture, reason = BookSettings.resolveXrayPosture(
        fakeDocSettings({ summary = { status = "complete" } }), {})
    TestRunner:assertEqual(posture, "full")
    TestRunner:assertEqual(reason, "finished")
end)

TestRunner:test("explicit global vs nothing-set stay distinct (the §4.3 flip seam)", function()
    local p = BookSettings.resolveSpoilerPosture(fakeDocSettings({}), { spoiler_free_chat = false })
    TestRunner:assertEqual(p.protected, false)
    TestRunner:assertEqual(p.reason, "global", "explicit false is a global decision — the opt-out")
    p = BookSettings.resolveSpoilerPosture(fakeDocSettings({}), {})
    TestRunner:assertEqual(p.protected, true, "schema default: protection ON (flipped 2026-08-11)")
    TestRunner:assertEqual(p.reason, "default", "nothing set anywhere = the flipped branch")
    p = BookSettings.resolveSpoilerPosture(nil, nil)
    TestRunner:assertEqual(p.protected, true, "no ds, no features: fail protected")
    TestRunner:assertEqual(p.reason, "default")
end)

TestRunner:test("ignore_finished: the cross-book rule reads only the reader's own switch (S5, ref #90)", function()
    local finished = { summary = { status = "complete" } }
    local p = BookSettings.resolveSpoilerPosture(fakeDocSettings(finished), {},
        { layer = "mechanical", ignore_finished = true })
    TestRunner:assertEqual(p.protected, true, "finished alone: the series stays protected")
    TestRunner:assertEqual(p.reason, "default")
    p = BookSettings.resolveSpoilerPosture(fakeDocSettings({ summary = { status = "complete" },
        koassistant_book_spoiler_free = false }), {}, { ignore_finished = true })
    TestRunner:assertEqual(p.protected, false, "finished + explicit book off: the switch counts")
    TestRunner:assertEqual(p.reason, "book")
    p = BookSettings.resolveSpoilerPosture(fakeDocSettings(finished), { spoiler_free_chat = false },
        { ignore_finished = true })
    TestRunner:assertEqual(p.protected, false, "global off counts")
    TestRunner:assertEqual(p.reason, "global")
    p = BookSettings.resolveSpoilerPosture(fakeDocSettings({ summary = { status = "complete" },
        koassistant_book_research_mode = true }), {}, { ignore_finished = true })
    TestRunner:assertEqual(p.reason, "research", "research still stands protection down")
    p = BookSettings.resolveSpoilerPosture(fakeDocSettings(finished), {})
    TestRunner:assertEqual(p.reason, "finished", "without the opt the finished layer is untouched")
end)

TestRunner:suite("clearXrayLineageState (B272, 2026-09-04: deleted = quiet, the override is pinned off unconditionally)")

TestRunner:test("every delete pins the per-book automation off and clears the lineage stamps", function()
    local function mutableDs(map)
        local ds = { _data = map, flushed = 0 }
        function ds:readSetting(k) return self._data[k] end
        function ds:saveSetting(k, v) self._data[k] = v end
        function ds:delSetting(k) self._data[k] = nil end
        function ds:flush() self.flushed = self.flushed + 1 end
        return ds
    end
    local A, ASKED = BookSettings.KEY_XRAY_AUTO, BookSettings.KEY_XRAY_COVERAGE_ASKED
    -- per-book on under a global off: pinned off (the on-open offer fires
    -- only while the key is unset, and a delete used to unset it)
    local ds = mutableDs({ [A] = "on", [ASKED] = true, [BookSettings.KEY_XRAY_PROMOTION] = "position" })
    BookSettings.clearXrayLineageState(ds, { xray_auto_update = false })
    TestRunner:assertEqual(ds._data[A], "off", "override pinned off")
    TestRunner:assertEqual(BookSettings.xrayAutoOverride(ds, { xray_offer_auto = true }), "off",
        "the offer's unset-key gate sees an answer")
    TestRunner:assertEqual(ds._data[ASKED], nil, "stamp cleared")
    TestRunner:assertEqual(ds._data[BookSettings.KEY_XRAY_PROMOTION], nil, "hold cleared")
    TestRunner:assertEqual(ds.flushed, 1)
    -- follow-global under a global auto-create: the device case — pinned off
    ds = mutableDs({ [ASKED] = true })
    local g = { xray_auto_update = true, xray_auto_create = true }
    BookSettings.clearXrayLineageState(ds, g)
    TestRunner:assertEqual(ds._data[A], "off", "explicit off, so the coverage ask stays away")
    TestRunner:assertEqual(BookSettings.resolveXrayAuto(ds, g), false)
    TestRunner:assertEqual(ds.flushed, 1)
    -- per-book on under a global auto: same outcome
    ds = mutableDs({ [A] = "on" })
    BookSettings.clearXrayLineageState(ds, g)
    TestRunner:assertEqual(ds._data[A], "off")
    -- nothing set, global off (the maintainer's device: all-books OFF, offer ON):
    -- still pinned off, so the next open of the X-Ray-less book asks nothing
    ds = mutableDs({})
    BookSettings.clearXrayLineageState(ds, {})
    TestRunner:assertEqual(ds._data[A], "off", "pinned even when no layer said on")
    TestRunner:assertEqual(ds.flushed, 1)
    ds = mutableDs({})
    BookSettings.clearXrayLineageState(ds, nil)
    TestRunner:assertEqual(ds._data[A], "off", "nil features: same pin")
    TestRunner:assertEqual(ds.flushed, 1)
end)

TestRunner:suite("resolveDomain / resolveResearch (consolidation round P1)")

TestRunner:test("resolveDomain: book override wins, layer book", function()
    local ds = makeDocSettings({ [BookSettings.KEY_DOMAIN] = "history" })
    local id, layer = BookSettings.resolveDomain(ds, { selected_domain = "science" })
    TestRunner:assertEqual(id, "history")
    TestRunner:assertEqual(layer, "book")
end)

TestRunner:test("resolveDomain: _none sentinel blocks global, layer book", function()
    local ds = makeDocSettings({ [BookSettings.KEY_DOMAIN] = "_none" })
    local id, layer = BookSettings.resolveDomain(ds, { selected_domain = "science" })
    TestRunner:assertNil(id, "_none = explicit no-domain")
    TestRunner:assertEqual(layer, "book", "the override is still book-sourced")
end)

TestRunner:test("resolveDomain: global fallthrough, layer global", function()
    local id, layer = BookSettings.resolveDomain(makeDocSettings({}), { selected_domain = "science" })
    TestRunner:assertEqual(id, "science")
    TestRunner:assertEqual(layer, "global")
end)

TestRunner:test("resolveDomain: nothing set / nil inputs → nil, nil", function()
    local id, layer = BookSettings.resolveDomain(nil, nil)
    TestRunner:assertNil(id); TestRunner:assertNil(layer)
    id, layer = BookSettings.resolveDomain(makeDocSettings({}), {})
    TestRunner:assertNil(id); TestRunner:assertNil(layer)
end)

TestRunner:test("resolveResearch: explicit book false beats DOI and global", function()
    local ds = makeDocSettings({ [BookSettings.KEY_RESEARCH] = false })
    TestRunner:assertEqual(
        BookSettings.resolveResearch(ds, { research_mode = true }, { doi = "10.1000/x" }),
        false, "book-level off pins the chain")
end)

TestRunner:test("resolveResearch: book true wins without DOI or global", function()
    local ds = makeDocSettings({ [BookSettings.KEY_RESEARCH] = true })
    TestRunner:assertEqual(BookSettings.resolveResearch(ds, {}), true)
end)

TestRunner:test("resolveResearch: DOI layer sits between book and global", function()
    TestRunner:assertEqual(
        BookSettings.resolveResearch(makeDocSettings({}), {}, { doi = "10.1000/x" }),
        true, "DOI turns research on when the book says nothing")
    TestRunner:assertEqual(
        BookSettings.resolveResearch(makeDocSettings({}), { research_mode = true }),
        true, "global fallthrough without DOI")
    TestRunner:assertEqual(
        BookSettings.resolveResearch(nil, nil), false, "nothing set = off")
end)

TestRunner:suite("resolveXrayDepth (book > global default > standard)")
TestRunner:test("nothing set = standard, no layer", function()
    local d, layer = BookSettings.resolveXrayDepth(makeDocSettings({}), {})
    TestRunner:assertEqual(d, nil, "depth"); TestRunner:assertEqual(layer, nil, "layer")
end)
TestRunner:test("global light applies when the book is unset", function()
    local d, layer = BookSettings.resolveXrayDepth(makeDocSettings({}), { xray_default_depth = "light" })
    TestRunner:assertEqual(d, "light", "depth"); TestRunner:assertEqual(layer, "global", "layer")
end)
TestRunner:test("book deep beats global light; explicit book standard pins standard", function()
    local d, layer = BookSettings.resolveXrayDepth(
        makeDocSettings({ [BookSettings.KEY_XRAY_DEPTH] = "deep" }), { xray_default_depth = "light" })
    TestRunner:assertEqual(d, "deep", "depth"); TestRunner:assertEqual(layer, "book", "layer")
    d, layer = BookSettings.resolveXrayDepth(
        makeDocSettings({ [BookSettings.KEY_XRAY_DEPTH] = "standard" }), { xray_default_depth = "light" })
    TestRunner:assertEqual(d, nil, "pinned standard"); TestRunner:assertEqual(layer, "book", "layer")
end)
TestRunner:test("junk values fall through; nil doc settings still honours the global", function()
    local d = BookSettings.resolveXrayDepth(makeDocSettings({ [BookSettings.KEY_XRAY_DEPTH] = "huge" }), { xray_default_depth = "bogus" })
    TestRunner:assertEqual(d, nil, "junk")
    local d2, layer2 = BookSettings.resolveXrayDepth(nil, { xray_default_depth = "deep" })
    TestRunner:assertEqual(d2, "deep", "nil ds"); TestRunner:assertEqual(layer2, "global", "layer")
    TestRunner:assertEqual(BookSettings.xrayDepthLabel(nil), "Standard", "label")
end)

TestRunner:suite("resolveXrayCategories (book > global default > full)")

local KXC = BookSettings.KEY_XRAY_CATEGORIES

TestRunner:test("nothing set = full, no layer", function()
    local sel, layer = BookSettings.resolveXrayCategories(makeDocSettings({}), {})
    TestRunner:assertNil(sel); TestRunner:assertNil(layer)
end)

TestRunner:test("book csv beats a different global", function()
    local sel, layer = BookSettings.resolveXrayCategories(
        makeDocSettings({ [KXC] = "people" }),
        { xray_default_categories = "events" })
    TestRunner:assertEqual(sel, "people")
    TestRunner:assertEqual(layer, "book")
end)

TestRunner:test("book 'full' sentinel beats a narrowed global", function()
    local sel, layer = BookSettings.resolveXrayCategories(
        makeDocSettings({ [KXC] = "full" }),
        { xray_default_categories = "people" })
    TestRunner:assertNil(sel, "explicit full = nil selection")
    TestRunner:assertEqual(layer, "book")
end)

TestRunner:test("unset book follows the global default", function()
    local sel, layer = BookSettings.resolveXrayCategories(
        makeDocSettings({}), { xray_default_categories = "people,places" })
    TestRunner:assertEqual(sel, "people,places")
    TestRunner:assertEqual(layer, "global")
end)

TestRunner:test("nil doc_settings still applies the global (no-book create path)", function()
    local sel, layer = BookSettings.resolveXrayCategories(
        nil, { xray_default_categories = "people" })
    TestRunner:assertEqual(sel, "people")
    TestRunner:assertEqual(layer, "global")
end)

TestRunner:test("junk book value falls through; full-set global folds to full", function()
    local sel, layer = BookSettings.resolveXrayCategories(
        makeDocSettings({ [KXC] = "bogus" }),
        { xray_default_categories = "people,places,ideas,terms,events" })
    TestRunner:assertNil(sel, "full-set csv normalizes to nil = full")
    TestRunner:assertNil(layer)
end)

print("")
print(string.rep("-", 50))
print(string.format("  Results: %d passed, %d failed", TestRunner.passed, TestRunner.failed))
print(string.rep("-", 50))

return TestRunner.failed == 0
