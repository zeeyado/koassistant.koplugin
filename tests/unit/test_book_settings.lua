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
TestRunner:test("defaults to false when neither set", function()
    TestRunner:assertEqual(BookSettings.resolveSpoilerFree(makeDocSettings({}), {}), false)
end)
TestRunner:test("nil doc_settings follows global", function()
    TestRunner:assertEqual(BookSettings.resolveSpoilerFree(nil, { spoiler_free_chat = true }), true)
    TestRunner:assertEqual(BookSettings.resolveSpoilerFree(nil, {}), false)
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

TestRunner:test("resolveToolsPosture: per-book override > global > manual", function()
    TestRunner:assertEqual(BookSettings.resolveToolsPosture(nil, nil), "manual",
        "no book, no features → manual")
    TestRunner:assertEqual(BookSettings.resolveToolsPosture(nil, { tools_posture = "auto" }), "auto",
        "global auto, no book override")
    local ds = fakeDocSettings({ koassistant_book_tools = "off" })
    TestRunner:assertEqual(BookSettings.resolveToolsPosture(ds, { tools_posture = "auto" }), "off",
        "per-book off wins over global auto")
    ds = fakeDocSettings({})
    TestRunner:assertEqual(BookSettings.resolveToolsPosture(ds, { tools_posture = "off" }), "off",
        "no book override → global off")
end)

TestRunner:test("resolveToolsPosture: unknown values fall through, never wedge", function()
    local ds = fakeDocSettings({ koassistant_book_tools = "banana" })
    TestRunner:assertEqual(BookSettings.resolveToolsPosture(ds, { tools_posture = "auto" }), "auto",
        "corrupt sidecar value falls through to the global")
    TestRunner:assertEqual(BookSettings.resolveToolsPosture(nil, { tools_posture = true }), "manual",
        "legacy boolean-ish global falls through to manual")
end)

TestRunner:test("toolsPostureLabel maps all three values (manual is the fallback)", function()
    TestRunner:assertEqual(BookSettings.toolsPostureLabel("off"), "Off", "off label")
    TestRunner:assertEqual(BookSettings.toolsPostureLabel("auto"), "Auto", "auto label")
    TestRunner:assertEqual(BookSettings.toolsPostureLabel("manual"), "Manual", "manual label")
    TestRunner:assertEqual(BookSettings.toolsPostureLabel(nil), "Manual", "nil falls back to Manual")
end)

TestRunner:test("KEY_TOOLS is registered in SIDECAR_KEYS (reset/count coverage)", function()
    local found = false
    for _i, key in ipairs(BookSettings.SIDECAR_KEYS) do
        if key == BookSettings.KEY_TOOLS then found = true end
    end
    TestRunner:assertEqual(found, true, "koassistant_book_tools missing from SIDECAR_KEYS")
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

print("")
print(string.rep("-", 50))
print(string.format("  Results: %d passed, %d failed", TestRunner.passed, TestRunner.failed))
print(string.rep("-", 50))

return TestRunner.failed == 0
