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
    TestRunner:assertEqual(q.chapter_depth, "toc_filter")
    TestRunner:assertNil(q.enabled, "enabled raw (suppress-only) defaults nil")
    TestRunner:assertEqual(q.min_pages, 0)
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

print("")
print(string.rep("-", 50))
print(string.format("  Results: %d passed, %d failed", TestRunner.passed, TestRunner.failed))
print(string.rep("-", 50))

return TestRunner.failed == 0
