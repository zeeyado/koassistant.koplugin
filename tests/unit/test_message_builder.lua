-- Unit tests for koassistant/request/message_builder.lua (audit quick win, the deep one):
-- ALL placeholders resolve here, and the file carries the plugin's oldest
-- fixed gotcha (2026-02-07 replace_placeholder infinite loop) with no
-- regression coverage until now.

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
-- Silence the builder's per-call INFO lines; assertions read the return value
package.loaded["logger"] = {
    info = function() end, warn = function() end,
    dbg = function() end, err = function() end,
}

local MessageBuilder = require("koassistant.request.message_builder")
local Templates = require("koassistant.prompts.templates")

local TestRunner = { passed = 0, failed = 0 }
function TestRunner:test(name, fn)
    local ok, err = pcall(fn)
    if ok then self.passed = self.passed + 1; print("    ✓ " .. name)
    else self.failed = self.failed + 1; print("    ✗ " .. name); print("      Error: " .. tostring(err)) end
end
function TestRunner:eq(a, b, msg)
    if a ~= b then error(string.format("%s: expected %s, got %s",
        msg or "eq", tostring(b), tostring(a)), 2) end
end
function TestRunner:has(s, sub, msg)
    if not s:find(sub, 1, true) then error((msg or "missing") .. ": " .. sub, 2) end
end
function TestRunner:hasnt(s, sub, msg)
    if s:find(sub, 1, true) then error((msg or "unexpected") .. ": " .. sub, 2) end
end

local function countOccur(s, sub)
    local n, pos = 0, 1
    while true do
        local a, b = s:find(sub, pos, true)
        if not a then return n end
        n = n + 1
        pos = b + 1
    end
end

local function build(prompt_text, context, data)
    return MessageBuilder.build({
        prompt = { prompt = prompt_text },
        context = context,
        data = data or {},
    })
end

print("")
print(string.rep("=", 50))
print("  Unit Tests: Message Builder")
print(string.rep("=", 50))

-- The 2026-02-07 gotcha: replacement text containing the literal placeholder
-- re-matched from position 1 and looped forever (swap death on device). The
-- fix advances search_start past each replacement. A regression here HANGS
-- the suite rather than failing an assert -- that is the failure mode.
TestRunner:test("replacement containing its own placeholder terminates, no re-expansion", function()
    local out = MessageBuilder.substituteVariables("A {title} B {title} C",
        { title = 'X {title} Y' })
    TestRunner:eq(out, "A X {title} Y B X {title} Y C",
        "both occurrences replaced exactly once, inner placeholder untouched")
end)

TestRunner:test("percent signs in replacements come through literally", function()
    -- replace_placeholder is find+sub concat, never gsub: "42%" must not be
    -- treated as a pattern capture in the replacement
    local out = build("Progress: {reading_progress}", "general",
        { reading_progress = "42%" })
    TestRunner:has(out, "Progress: 42%")
end)

TestRunner:test("hallucination nudge is web-aware", function()
    local plain = build("{hallucination_nudge}", "general", {})
    TestRunner:has(plain, "say so rather than guessing")
    TestRunner:hasnt(plain, "search the web", "plain variant without web")
    local web = build("{hallucination_nudge}", "general", { web_search_active = true })
    TestRunner:has(web, "search the web to verify", "web variant when search active")
end)

TestRunner:test("text fallback nudge: only when no document text, {title} resolves late", function()
    local no_text = build("{book_text_section}\n\n{text_fallback_nudge}", "book", {
        book_metadata = { title = "Test Book" },
    })
    TestRunner:has(no_text, "No document text was provided")
    -- the nudge itself carries {title}; substitution happens AFTER insertion
    -- (book branch), so the title must land inside the nudge text
    TestRunner:has(no_text, 'Use your knowledge of "Test Book"', "late {title} substitution")
    local with_text = build("{book_text_section}\n\n{text_fallback_nudge}", "book", {
        book_metadata = { title = "Test Book" },
        book_text = "Chapter one begins.",
    })
    TestRunner:has(with_text, "Book content so far:\nChapter one begins.")
    TestRunner:hasnt(with_text, "No document text was provided", "nudge suppressed with text")
end)

TestRunner:test("document_context_section counts as document text and labels smart retrieval honestly", function()
    local sr = build("{document_context_section}\n{text_fallback_nudge}", "book", {
        book_metadata = { title = "T" },
        _source_mode = "smart_retrieval",
        full_document = "RETRIEVED PASSAGE",
    })
    TestRunner:has(sr, "Passages retrieved from the book (targeted lookups, not the full text):")
    TestRunner:hasnt(sr, "No document text was provided", "gather bundle suppresses fallback")
    local ai = build("{document_context_section}\n{text_fallback_nudge}", "book", {
        book_metadata = { title = "T" },
        _source_mode = "ai_knowledge",
    })
    TestRunner:has(ai, "No document text was provided", "ai_knowledge mode keeps the nudge")
end)

TestRunner:test("highlight analysis nudge only when highlights section resolves", function()
    local with_h = build("{highlights_section}\n{highlight_analysis_nudge}", "book", {
        book_metadata = { title = "T" },
        highlights = "- a passage",
    })
    TestRunner:has(with_h, "reader_engagement")
    local without = build("{highlights_section}\n{highlight_analysis_nudge}", "book", {
        book_metadata = { title = "T" },
    })
    TestRunner:hasnt(without, "reader_engagement")
end)

TestRunner:test("highlighted text never duplicates: placeholder form has no Selected-text block", function()
    local sel = "the passage under discussion"
    local in_prompt = build('Explain: "{highlighted_text}"', "highlight",
        { highlighted_text = sel })
    TestRunner:eq(countOccur(in_prompt, sel), 1, "selection appears exactly once")
    TestRunner:hasnt(in_prompt, "Selected text:", "no context block when prompt embeds it")
    local ambient = build("Explain the selected text.", "highlight",
        { highlighted_text = sel })
    TestRunner:has(ambient, "Selected text:")
    TestRunner:eq(countOccur(ambient, sel), 1, "context-block form also carries it once")
    TestRunner:has(ambient, '"' .. sel .. '"', "selection is quoted in the block")
end)

TestRunner:test("selection_label overrides the generic Selected-text label", function()
    local out = build("Discuss.", "highlight", {
        highlighted_text = "entry body",
        selection_label = "From the X-Ray entry:",
    })
    TestRunner:has(out, "From the X-Ray entry:")
    TestRunner:hasnt(out, "Selected text:")
end)

TestRunner:test("ambient surrounding context appends once; placeholder form resolves in place, never both", function()
    local label = Templates.SURROUNDING_CONTEXT_LABEL
    local ambient = build("Explain this.", "highlight", {
        highlighted_text = "sel",
        surrounding_context = "before >>>sel<<< after",
    })
    TestRunner:eq(countOccur(ambient, label), 1, "ambient: labeled section appended once")
    TestRunner:eq(ambient:find(label, 1, true) > ambient:find("Explain this.", 1, true), true,
        "ambient section sits after the prompt")
    local placed = build("{surrounding_context_section}\nExplain this.", "highlight", {
        highlighted_text = "sel",
        surrounding_context = "before >>>sel<<< after",
    })
    TestRunner:eq(countOccur(placed, label), 1, "placeholder form: resolved in place only")
    TestRunner:eq(placed:find(label, 1, true) < placed:find("Explain this.", 1, true), true,
        "in-place section sits where the placeholder was")
end)

TestRunner:test("annotations section label adapts to degradation", function()
    local full = build("{annotations_section}", "book", {
        book_metadata = { title = "T" },
        annotations = "- note",
    })
    TestRunner:has(full, "My annotations:")
    local degraded = build("{annotations_section}", "book", {
        book_metadata = { title = "T" },
        annotations = "- bare highlight",
        _annotations_degraded = true,
    })
    TestRunner:has(degraded, "My highlights so far:")
    TestRunner:hasnt(degraded, "My annotations:", "degraded label replaces, not joins")
end)

TestRunner:test("spoiler nudge: progress variant, no-progress variant, absent when off", function()
    local with_p = build("{spoiler_free_nudge}", "book", {
        book_metadata = { title = "T" },
        spoiler_free = true,
        reading_progress = "42%",
    })
    TestRunner:has(with_p, "currently at 42%", "progress substituted into the nudge")
    local no_p = build("{spoiler_free_nudge}", "book", {
        book_metadata = { title = "T" },
        spoiler_free = true,
    })
    TestRunner:has(no_p, "has not finished this book", "no-progress variant")
    local off = build("{spoiler_free_nudge}", "book", {
        book_metadata = { title = "T" },
        reading_progress = "42%",
    })
    TestRunner:hasnt(off, "reveal", "no nudge when spoiler_free unset")
end)

TestRunner:test("dictionary context mode none strips context lines entirely", function()
    local out = build("Define the word.\nIn context: {context}\nBe brief.", "highlight", {
        highlighted_text = "word",
        context = "the word in its sentence",
        dictionary_context_mode = "none",
    })
    TestRunner:hasnt(out, "In context", "context line stripped")
    TestRunner:hasnt(out, "{context}", "no dangling placeholder")
    TestRunner:has(out, "Be brief.", "following lines survive")
end)

print("")
TestRunner:test("raw data placeholders with nothing behind them are dropped, not sent as written (B464, B465)", function()
    local out = MessageBuilder.build({
        prompt = { prompt = "A {book_text} B {summary_cache} C {library} D {doi_clause} E {title} F {cached_result} G" },
        context = "highlight",
        data = { highlighted_text = "X" },
    })
    for _idx, raw in ipairs({ "{book_text}", "{summary_cache}", "{library}", "{doi_clause}", "{title}", "{cached_result}" }) do
        TestRunner:hasnt(out, raw, "left in the prompt")
    end
    TestRunner:has(out, "A  B  C  D  E  F  G", "the prompt around them survives")
end)

TestRunner:test("a title that is only the file name is named as a file name, never as the title", function()
    local book = build('Tell me about "{title}"{author_clause}.', "book", {
        book_metadata = { title = "scan 001", author = "", author_clause = "", title_from_filename = true },
    })
    TestRunner:has(book, 'Book: no title in its metadata (file name "scan 001", not the title)', "the context line names the file")
    TestRunner:has(book, "Tell me about this book.", "the action's words say this book")
    TestRunner:hasnt(book, 'about "scan 001"', "the file name is never the title")
    local titled = build('Tell me about "{title}".', "book", { book_metadata = { title = "Real Title" } })
    TestRunner:has(titled, 'Book: "Real Title"', "a real title as before")
    TestRunner:has(titled, 'Tell me about "Real Title".', "and in the action's words")
    local hl = build("Explain: {highlighted_text}", "highlight", {
        book_title = "scan 001", book_title_from_filename = true, highlighted_text = "a passage",
    })
    TestRunner:has(hl, 'From a book with no title in its metadata (file name "scan 001")', "the highlight context line too")
    TestRunner:hasnt(hl, 'From "scan 001"', "never as the title")
end)

print(string.rep("-", 50))
print("\n  [the sweep of 2026-11-06: Title only, the context strip, data never re-scanned]")

TestRunner:test("Title only drops {author} and {author_clause} in the book and highlight branches", function()
    local out = MessageBuilder.build({ prompt = { prompt = "Tell me about {title}{author_clause}. Author: {author}." }, context = "book",
        data = { book_metadata = { title = "T", author = "AUTH", author_clause = " by AUTH" }, _book_info_level = "title" },
        using_new_format = true })
    TestRunner:hasnt(out, "AUTH", "the book branch")
    TestRunner:has(out, "Tell me about T. Author: .")
    local out2 = MessageBuilder.build({ prompt = { prompt = 'Explain "{highlighted_text}" from {title}{author_clause}.' }, context = "highlight",
        data = { highlighted_text = "w", book_title = "T", book_author = "AUTH", _book_info_level = "title" },
        using_new_format = true })
    TestRunner:hasnt(out2, "AUTH", "the highlight branch")
    TestRunner:has(out2, 'Explain "w" from T.')
    -- basic keeps the author
    local out3 = MessageBuilder.build({ prompt = { prompt = "About {title}{author_clause}." }, context = "book",
        data = { book_metadata = { title = "T", author = "AUTH", author_clause = " by AUTH" }, _book_info_level = "basic" },
        using_new_format = true })
    TestRunner:has(out3, "About T by AUTH.")
end)

TestRunner:test("the context strip keys on {context} alone; typed text saying In context survives", function()
    local a = MessageBuilder.build({ prompt = { prompt = "In context of this chapter, explain the passage." }, context = "highlight",
        data = { highlighted_text = "w" }, using_new_format = true })
    TestRunner:has(a, "In context of this chapter, explain the passage.", "the action's own words stay")
    local b = MessageBuilder.build({ prompt = { prompt = "Answer: {user_input}" }, context = "highlight",
        data = { highlighted_text = "w", additional_input = "Explain this. In context, why?" }, using_new_format = true })
    TestRunner:has(b, "Answer: Explain this. In context, why?", "the typed text is substituted after the strip")
    TestRunner:hasnt(b, "[Additional user input]")
    local c = MessageBuilder.build({ prompt = { prompt = "Word: {word}\nIn context: {context}\nExplain." }, context = "highlight",
        data = { highlighted_text = "w", dictionary_context_mode = "none" }, using_new_format = true })
    TestRunner:hasnt(c, "In context", "the label's line goes with its placeholder")
    TestRunner:has(c, "Explain.")
end)

TestRunner:test("data is never re-scanned for placeholders: braces inside a selection or the book's text stay as written", function()
    local a = MessageBuilder.build({ prompt = { prompt = 'Explain "{highlighted_text}" from {title}{author_clause}.' }, context = "highlight",
        data = { highlighted_text = 'print(f"{title} by {author}")', book_title = "BT", book_author = "BA" }, using_new_format = true })
    TestRunner:has(a, 'Explain "print(f"{title} by {author}")" from BT by BA.')
    local b = MessageBuilder.build({ prompt = { prompt = "Summarize. {book_text_section}" }, context = "book",
        data = { book_metadata = { title = "BT", author = "BA" }, book_text = "Use {title} and {highlights} and {count} here." },
        using_new_format = true })
    TestRunner:has(b, "Use {title} and {highlights} and {count} here.")
    TestRunner:hasnt(b, "\238\128\128", "the mark is restored")
    -- the nudges' own nested placeholders still resolve (a template, not data)
    local c = MessageBuilder.build({ prompt = { prompt = "Go. {spoiler_free_nudge}" }, context = "book",
        data = { book_metadata = { title = "BT" }, spoiler_free = true, reading_progress = "40%",
            additional_input = "typed {reading_progress}" }, using_new_format = true })
    TestRunner:has(c, "40%", "the template's one resolved")
    TestRunner:has(c, "typed {reading_progress}", "the typed text's one kept")
    TestRunner:eq(countOccur(c, "{reading_progress}"), 1, "and it is the only one left")
end)

print(string.format("  Results: %d passed, %d failed", TestRunner.passed, TestRunner.failed))
print(string.rep("-", 50))
return TestRunner.failed == 0
