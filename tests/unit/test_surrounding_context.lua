-- Unit tests for the surrounding-context feature (surrounding_context_plan.md):
--   * koassistant_scope_resolver.lua — pure trims (paragraph window, modes, caps)
--   * Actions.effectiveSurroundingContextMode — per-action tri-state matrix
--   * MessageBuilder — placeholder-in-place vs ambient-append, never both

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

local ScopeResolver = require("koassistant_scope_resolver")
local Actions = require("prompts.actions")
local MessageBuilder = require("message_builder")
local Templates = require("prompts.templates")

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
local function countOccurrences(str, needle)
    local n, pos = 0, 1
    while true do
        local s, e = str:find(needle, pos, true)
        if not s then return n end
        n = n + 1
        pos = e + 1
    end
end

--==========================================================================
TestRunner:suite("ScopeResolver.paragraphWindow")

-- Prose-sized paragraphs (each clears PARAGRAPH_MIN_CHARS) so the n semantics
-- are observable without the floor kicking in.
local PAR_TWO = "Par two " .. string.rep("b", 320) .. "."
local REMAINDER_BEFORE = "Start of par three " .. string.rep("c", 320)
local REMAINDER_AFTER = string.rep("d", 320) .. " end of par three."
local PAR_FOUR = "Par four " .. string.rep("e", 320) .. "."
local PROSE_PREV = "Par one.\n" .. PAR_TWO .. "\n" .. REMAINDER_BEFORE
local PROSE_NEXT = REMAINDER_AFTER .. "\n" .. PAR_FOUR .. "\nPar five."

TestRunner:test("n=1 mid-paragraph (prose): remainder of the containing paragraph only", function()
    local before, after = ScopeResolver.paragraphWindow(PROSE_PREV, PROSE_NEXT, 1, 1000)
    TestRunner:assertEqual(before, REMAINDER_BEFORE, "before = containing-paragraph remainder")
    TestRunner:assertEqual(after, REMAINDER_AFTER, "after = containing-paragraph remainder")
end)

TestRunner:test("n=2 adds one whole neighbor paragraph per side (prose)", function()
    local before, after = ScopeResolver.paragraphWindow(PROSE_PREV, PROSE_NEXT, 2, 1000)
    TestRunner:assertEqual(before, PAR_TWO .. "\n" .. REMAINDER_BEFORE, "before = prev paragraph + remainder")
    TestRunner:assertEqual(after, REMAINDER_AFTER .. "\n" .. PAR_FOUR, "after = remainder + next paragraph")
end)

TestRunner:test("dialogue (one line = one block): floor absorbs neighboring lines", function()
    local prev = "F.R.: Fine. Listen, we're here for a few more days and then we're going to France.\n"
        .. "S.K.: (Overlapping) Because no, it's not. It's something else.\n"
        .. "S.K.: "
    local nxt = ".\nF.R.: Stanley, forgive me, I have to get something straight.\n"
        .. "S.K.: I don't know yet if it's something you're going to want to do."
    local before, after = ScopeResolver.paragraphWindow(prev, nxt, 1, 1000)
    TestRunner:assertContains(before, "Because no", "previous dialogue line absorbed")
    TestRunner:assertContains(before, "few more days", "second previous line absorbed too")
    TestRunner:assertContains(after, "Stanley, forgive me", "next dialogue line absorbed")
end)

TestRunner:test("floor expansion is still bounded by max_per_side", function()
    local lines = {}
    for i = 1, 50 do lines[i] = "Line " .. i .. " " .. string.rep("z", 20) end
    local prev = table.concat(lines, "\n") .. "\nTag: "
    local before = (ScopeResolver.paragraphWindow(prev, "", 1, 100))
    TestRunner:assertEqual(#before <= 100, true, "capped at max_per_side")
end)

TestRunner:test("no newlines (PDF/kopt) degrades to the whole capped window", function()
    local before, after = ScopeResolver.paragraphWindow("just a flat window", "more flat text", 1, 1000)
    TestRunner:assertEqual(before, "just a flat window", "flat before kept whole")
    TestRunner:assertEqual(after, "more flat text", "flat after kept whole")
end)

TestRunner:test("per-side char cap is enforced", function()
    local long = string.rep("x", 600)
    local before, after = ScopeResolver.paragraphWindow(long, long, 1, 100)
    TestRunner:assertEqual(#before, 100, "before capped")
    TestRunner:assertEqual(#after, 100, "after capped")
end)

TestRunner:test("cap cut snaps the window to sentence boundaries", function()
    -- Before side: three sentences, cap lands mid-second — the partial leading
    -- sentence is dropped so the window opens at a sentence start
    local s1 = "First sentence here padding padding. "
    local s2 = "Second sentence with more words in it. "
    local s3 = "Third sentence right before the selection."
    local prev = s1 .. s2 .. s3
    local before, _, bb = ScopeResolver.paragraphWindow(prev, "", 1, #s2 + #s3 + 10)
    TestRunner:assertEqual(before:sub(1, 6), "Second", "before opens at a sentence start")
    TestRunner:assertEqual(bb, true, "cap cut marks the side bounded")
    -- After side: cap lands mid-third — the trailing partial sentence is dropped
    local nxt = "Alpha beta gamma delta done. Second one also ends. Third trails off unfinished here"
    local _, after, _, ab = ScopeResolver.paragraphWindow("", nxt, 1, 60)
    TestRunner:assertEqual(after:sub(-5), "ends.", "after closes at a sentence end")
    TestRunner:assertEqual(ab, true, "cap cut marks the side bounded")
end)

TestRunner:test("snap degrades to the raw cut when no boundary exists", function()
    local long = string.rep("x", 600)
    local before, after = ScopeResolver.paragraphWindow(long, long, 1, 100)
    TestRunner:assertEqual(#before, 100, "before keeps the raw cap cut")
    TestRunner:assertEqual(#after, 100, "after keeps the raw cap cut")
end)

TestRunner:test("paragraph mode ellipsizes only bounded sides", function()
    -- Unbounded: n=1 of a 3-paragraph side over the floor — clean window, no "..."
    local pad = string.rep("word ", 70)  -- ~350 chars, clears PARAGRAPH_MIN_CHARS
    local prev = "Outer old paragraph. " .. pad .. "\nMiddle one. " .. pad .. "\nAdjacent paragraph. " .. pad
    local nxt = "Rest of paragraph. " .. pad .. "\nNext paragraph. " .. pad .. "\nFar one. " .. pad
    local result = ScopeResolver.trimContext(prev, nxt, "SEL", "paragraph", { paragraphs = 1 })
    TestRunner:assertNotContains(result, "...", "clean paragraph window carries no ellipsis")
    -- Bounded: single flat run over the cap — both sides ellipsized
    local long = string.rep("y", 1200)
    local bounded = ScopeResolver.trimContext(long, long, "SEL", "paragraph", { paragraphs = 1 })
    TestRunner:assertEqual(bounded:sub(1, 3), "...", "capped before side ellipsized")
    TestRunner:assertEqual(bounded:sub(-3), "...", "capped after side ellipsized")
end)

TestRunner:test("empty and whitespace-only sides yield empty strings", function()
    local before, after = ScopeResolver.paragraphWindow("", "  \n  \n", 1, 100)
    TestRunner:assertEqual(before, "", "empty prev")
    TestRunner:assertEqual(after, "", "whitespace next")
end)

--==========================================================================
TestRunner:suite("ScopeResolver.trimContext")

TestRunner:test("sentence mode extracts the surrounding sentence with marker", function()
    local result = ScopeResolver.trimContext(
        "Other sentence. The quick brown fox jumps over", " and lands. Next sentence here.",
        "the dog", "sentence")
    TestRunner:assertContains(result, ">>>the dog<<<", "marker present")
    TestRunner:assertContains(result, "The quick brown fox", "sentence before included")
    TestRunner:assertContains(result, "Other sentence.", "previous full sentence included (round 3)")
    TestRunner:assertContains(result, "and lands.", "sentence after included")
    TestRunner:assertNotContains(result, "Next sentence here", "beyond sentence end excluded")
end)

TestRunner:test("sentence mode: selection at sentence start still gets a before side", function()
    -- Device 2026-08-16: a selection that BEGAN its sentence got an empty
    -- before side — the old walk only completed the selection's own sentence,
    -- and there was nothing of it before the selection. One full sentence
    -- back is what "sentence context" means; exactly one, not two.
    local prev = "An earlier point was made. The previous sentence sits right here. "
    local nxt = ", just as the after clause continues. Next sentence beyond."
    local result = ScopeResolver.trimContext(prev, nxt,
        "The hypothesis must fit the data", "sentence")
    TestRunner:assertContains(result, "previous sentence sits right here.",
        "previous full sentence included")
    TestRunner:assertNotContains(result, "earlier point", "only one sentence back")
    TestRunner:assertContains(result, "after clause continues.", "own-sentence tail kept")
    TestRunner:assertNotContains(result, "Next sentence beyond", "next sentence excluded")
end)

TestRunner:test("characters mode respects char_count and ellipsizes truncation", function()
    local result = ScopeResolver.trimContext(
        string.rep("a", 300), string.rep("b", 300), "WORD", "characters", { char_count = 50 })
    TestRunner:assertContains(result, ">>>WORD<<<", "marker present")
    TestRunner:assertContains(result, "..." .. string.rep("a", 50), "before truncated + ellipsis")
    TestRunner:assertContains(result, string.rep("b", 50) .. "...", "after truncated + ellipsis")
end)

TestRunner:test("paragraph mode uses opts.paragraphs (prose-sized)", function()
    local p1 = "P1 " .. string.rep("a", 320) .. "."
    local p2 = "P2 " .. string.rep("b", 320) .. "."
    local p3s = "P3 start " .. string.rep("c", 320)
    local p3e = string.rep("d", 320) .. " P3 end."
    local p4 = "P4 " .. string.rep("e", 320) .. "."
    local p5 = "P5 " .. string.rep("f", 320) .. "."
    local result = ScopeResolver.trimContext(
        p1 .. "\n" .. p2 .. "\n" .. p3s, p3e .. "\n" .. p4 .. "\n" .. p5,
        "SEL", "paragraph", { paragraphs = 2 })
    TestRunner:assertContains(result, "P2 ", "second paragraph back included")
    TestRunner:assertContains(result, "P4 ", "second paragraph forward included")
    TestRunner:assertNotContains(result, "P1 ", "third paragraph back excluded")
    TestRunner:assertNotContains(result, "P5 ", "third paragraph forward excluded")
end)

TestRunner:test("sentence fallback triggers on tiny context even with a long highlight", function()
    -- Dialogue: sentence boundaries collapse to the speaker tag; the old check
    -- measured the marker-inclusive result, so a >30-byte highlight starved this.
    local prev = "F.R.: We are here for a few more days.\nS.K.: "
    local nxt = ".\nF.R.: Stanley, forgive me, I have to get something straight."
    local result = ScopeResolver.trimContext(prev, nxt, "I'll get it to you there", "sentence")
    TestRunner:assertContains(result, ">>>I'll get it to you there<<<", "marker present")
    TestRunner:assertContains(result, "few more days",
        "fallback pulled real context beyond the collapsed sentence boundary")
end)

TestRunner:test("mode none / empty window return empty string", function()
    TestRunner:assertEqual(ScopeResolver.trimContext("a", "b", "w", "none"), "", "none mode")
    TestRunner:assertEqual(ScopeResolver.trimContext("", "", "w", "sentence"), "", "empty window")
    TestRunner:assertEqual(ScopeResolver.trimContext(nil, nil, "w", "sentence"), "", "nil window")
end)

TestRunner:test("after_limit 'none' drops the after side in every mode (P5 spoiler clamp)", function()
    local prev = "Other sentence. The quick brown fox jumps over"
    local nxt = " and lands. Next sentence here."
    for _idx, mode in ipairs({ "sentence", "characters", "paragraph" }) do
        local result = ScopeResolver.trimContext(prev, nxt, "the dog", mode,
            { after_limit = "none", char_count = 50, paragraphs = 1 })
        TestRunner:assertContains(result, ">>>the dog<<<", mode .. ": marker present")
        TestRunner:assertNotContains(result, "and lands", mode .. ": after side dropped")
    end
    -- Suppressed after + empty before yields nothing at all
    TestRunner:assertEqual(
        ScopeResolver.trimContext("", " after text only.", "w", "sentence", { after_limit = "none" }),
        "", "empty before + suppressed after = empty")
end)

TestRunner:test("after_limit 'sentence' keeps only the selection's own sentence tail", function()
    local prev = "Earlier sentence. The fox jumps over"
    local nxt = " and lands safely. Then the story continues here."
    local result = ScopeResolver.trimContext(prev, nxt, "the dog", "characters",
        { after_limit = "sentence", char_count = 200 })
    TestRunner:assertContains(result, "and lands safely.", "sentence tail kept")
    TestRunner:assertNotContains(result, "story continues", "next sentence excluded")
end)

TestRunner:test("after_limit 'paragraph' keeps only the selection's own paragraph tail", function()
    local prev = "Para start, the fox jumps over"
    local nxt = " and lands. More of the same paragraph.\nNext paragraph starts here."
    local result = ScopeResolver.trimContext(prev, nxt, "the dog", "characters",
        { after_limit = "paragraph", char_count = 300 })
    TestRunner:assertContains(result, "More of the same paragraph.", "paragraph tail kept")
    TestRunner:assertNotContains(result, "Next paragraph starts", "next paragraph excluded")
end)

TestRunner:test("hard cap: no mode can exceed MAX_CONTEXT_CHARS by much", function()
    local huge = string.rep("y", 5000)
    local result = ScopeResolver.trimContext(huge, huge, "W", "characters", { char_count = 5000 })
    -- 2 sides * 1000 cap + marker + ellipses/spaces
    TestRunner:assertEqual(#result < ScopeResolver.MAX_CONTEXT_CHARS + 50, true, "characters capped")
end)

TestRunner:test("utf8 trims do not split multibyte chars", function()
    local s = string.rep("é", 10)  -- 2 bytes each
    local first = (ScopeResolver.utf8First(s, 3))
    TestRunner:assertEqual(first, "ééé", "utf8First counts chars, not bytes")
    local last = (ScopeResolver.utf8Last(s, 3))
    TestRunner:assertEqual(last, "ééé", "utf8Last counts chars, not bytes")
end)

--==========================================================================
TestRunner:suite("Actions.effectiveSurroundingContextMode — tri-state matrix")

TestRunner:test("nil action (freeform) follows the ambient mode", function()
    TestRunner:assertEqual(Actions.effectiveSurroundingContextMode(nil, {}, "sentence"), "sentence")
    TestRunner:assertNil(Actions.effectiveSurroundingContextMode(nil, {}, "none"), "ambient off")
    TestRunner:assertNil(Actions.effectiveSurroundingContextMode(nil, {}, nil), "ambient unset")
end)

TestRunner:test("flag false always wins", function()
    local action = { id = "dictionary", use_surrounding_context = false, prompt = "x" }
    TestRunner:assertNil(Actions.effectiveSurroundingContextMode(action, {}, "paragraph"))
end)

TestRunner:test("flag true: own context_mode > ambient > sentence fallback", function()
    local action = { id = "wiki", use_surrounding_context = true, prompt = "x {surrounding_context_section}" }
    TestRunner:assertEqual(Actions.effectiveSurroundingContextMode(action, {}, "paragraph"),
        "paragraph", "ambient mode adopted")
    TestRunner:assertEqual(Actions.effectiveSurroundingContextMode(action, {}, "none"),
        "sentence", "global none → sentence fallback (explicit-true actions still work)")
    action.context_mode = "characters"
    TestRunner:assertEqual(Actions.effectiveSurroundingContextMode(action, {}, "paragraph"),
        "characters", "action's own mode wins")
end)

TestRunner:test("nil flag: ambient with structural skips", function()
    local plain = { id = "explain", prompt = "Explain: {highlighted_text}" }
    TestRunner:assertEqual(Actions.effectiveSurroundingContextMode(plain, {}, "sentence"),
        "sentence", "plain action follows ambient")
    TestRunner:assertNil(Actions.effectiveSurroundingContextMode(plain, {}, "none"), "ambient off → nil")
    local scoped = { id = "explain_in_context", prompt = "x", source_selection = true }
    TestRunner:assertNil(Actions.effectiveSurroundingContextMode(scoped, {}, "sentence"),
        "source_selection actions provide their own scope")
    local dict_style = { id = "custom_dict", prompt = "Define {highlighted_text}\n{context_section}" }
    TestRunner:assertNil(Actions.effectiveSurroundingContextMode(dict_style, {}, "sentence"),
        "{context_section} channel skips ambient")
    local doc_style = { id = "custom_doc", prompt = "x {document_context_section}" }
    TestRunner:assertNil(Actions.effectiveSurroundingContextMode(doc_style, {}, "sentence"),
        "{document_context_section} skips ambient")
    local local_action = { id = "xray_lookup", local_handler = "xray_lookup" }
    TestRunner:assertNil(Actions.effectiveSurroundingContextMode(local_action, {}, "sentence"),
        "local actions never build an AI request")
end)

TestRunner:test("translate: gated on translate_use_context, never for full-page", function()
    local translate = { id = "translate", prompt = "Translate this to X: {highlighted_text}" }
    TestRunner:assertNil(Actions.effectiveSurroundingContextMode(translate, {}, "sentence"),
        "toggle off (default) → no context even with ambient on")
    TestRunner:assertEqual(
        Actions.effectiveSurroundingContextMode(translate, { translate_use_context = true }, "none"),
        "sentence", "toggle on + ambient off → sentence")
    TestRunner:assertEqual(
        Actions.effectiveSurroundingContextMode(translate, { translate_use_context = true }, "paragraph"),
        "paragraph", "toggle on adopts ambient mode")
    TestRunner:assertNil(
        Actions.effectiveSurroundingContextMode(translate,
            { translate_use_context = true, is_full_page_translate = true }, "paragraph"),
        "full-page translation is excluded")
end)

TestRunner:test("built-in exclusions and inclusions carry the right flags", function()
    TestRunner:assertEqual(Actions.special.dictionary.use_surrounding_context, false, "dictionary excluded")
    TestRunner:assertEqual(Actions.special.quick_define.use_surrounding_context, false, "quick_define excluded")
    TestRunner:assertEqual(Actions.special.deep.use_surrounding_context, false, "dictionary_deep excluded")
    TestRunner:assertEqual(Actions.highlight.wiki.use_surrounding_context, true, "wiki stays explicit-true")
    TestRunner:assertNil(Actions.highlight.fact_check.use_surrounding_context,
        "fact_check follows ambient (strong beneficiary)")
end)

--==========================================================================
TestRunner:suite("MessageBuilder — in-place vs ambient append (never both)")

TestRunner:test("placeholder present: resolved in place with the label, no append", function()
    local result = MessageBuilder.build({
        prompt = { prompt = "Ask about X\n\n{surrounding_context_section}\n\nAnswer well." },
        context = "highlight",
        data = { highlighted_text = "X", surrounding_context = "before >>>X<<< after" },
    })
    TestRunner:assertContains(result, Templates.SURROUNDING_CONTEXT_LABEL, "label present")
    TestRunner:assertContains(result, "before >>>X<<< after", "context present")
    TestRunner:assertEqual(countOccurrences(result, "before >>>X<<< after"), 1, "context appears exactly once")
    -- In place means before the trailing prompt text, not appended after it
    TestRunner:assertEqual(result:find("before >>>X<<<", 1, true) < result:find("Answer well.", 1, true),
        true, "resolved at the placeholder position")
end)

TestRunner:test("no placeholder (ambient): labeled section appended once", function()
    local result = MessageBuilder.build({
        prompt = { prompt = "Explain: {highlighted_text}" },
        context = "highlight",
        data = { highlighted_text = "X", surrounding_context = "before >>>X<<< after" },
    })
    TestRunner:assertContains(result, Templates.SURROUNDING_CONTEXT_LABEL, "label present")
    TestRunner:assertEqual(countOccurrences(result, "before >>>X<<< after"), 1, "context appears exactly once")
    TestRunner:assertEqual(result:find("Explain: X", 1, true) < result:find("before >>>X<<<", 1, true),
        true, "appended after the request")
end)

TestRunner:test("no surrounding_context data: placeholder resolves empty, nothing appended", function()
    local result = MessageBuilder.build({
        prompt = { prompt = "Ask\n\n{surrounding_context_section}" },
        context = "highlight",
        data = { highlighted_text = "X" },
    })
    TestRunner:assertNotContains(result, "{surrounding_context_section}", "placeholder resolved")
    TestRunner:assertNotContains(result, Templates.SURROUNDING_CONTEXT_LABEL, "no label without content")
end)

TestRunner:test("raw {surrounding_context} placeholder suppresses the append too", function()
    local result = MessageBuilder.build({
        prompt = { prompt = "Context: {surrounding_context}\nDone." },
        context = "highlight",
        data = { highlighted_text = "X", surrounding_context = "RAWCTX" },
    })
    TestRunner:assertEqual(countOccurrences(result, "RAWCTX"), 1, "context appears exactly once")
    TestRunner:assertNotContains(result, Templates.SURROUNDING_CONTEXT_LABEL,
        "raw placeholder means the action labels it itself")
end)

TestRunner:suite("contextExcerpt (dictionary display excerpt)")

TestRunner:test("short context passes through; marker word bolded by the caller", function()
    local b, w, a = ScopeResolver.contextExcerpt("She found the >>>derelict<<< ship at dawn.")
    TestRunner:assertEqual(b, "She found the", "before")
    TestRunner:assertEqual(w, "derelict", "word")
    TestRunner:assertEqual(a, "ship at dawn.", "after")
end)

TestRunner:test("no marker or empty word = nil", function()
    TestRunner:assertNil(ScopeResolver.contextExcerpt("plain text"), "no marker")
    TestRunner:assertNil(ScopeResolver.contextExcerpt(">>> <<<"), "blank word")
    TestRunner:assertNil(ScopeResolver.contextExcerpt(nil), "nil")
end)

TestRunner:test("long sides cut to the budget on word boundaries, with ellipses", function()
    local prev = string.rep("alpha ", 40)   -- 240 bytes
    local nxt = string.rep("omega ", 40)
    local b, w, a = ScopeResolver.contextExcerpt(prev .. ">>>word<<< " .. nxt, 30)
    TestRunner:assertEqual(w, "word", "word")
    TestRunner:assertEqual(b:sub(1, 3) == "…", true, "before marked as cut")
    TestRunner:assertEqual(#b <= 30 + 3, true, "before within budget (+ ellipsis)")
    TestRunner:assertEqual(b:find("^…alpha") ~= nil, true, "before starts on a whole word")
    TestRunner:assertEqual(a:sub(-3) == "…", true, "after marked as cut")
    TestRunner:assertEqual(a:find("omega…$") ~= nil, true, "after ends on a whole word")
end)

TestRunner:test("trimContext's own ellipses carry over; paragraph breaks bound each side", function()
    local b, _w, a = ScopeResolver.contextExcerpt("...end of a sentence >>>word<<< more text...")
    TestRunner:assertEqual(b, "…end of a sentence", "leading ... becomes …")
    TestRunner:assertEqual(a, "more text…", "trailing ... becomes …")
    local b2, _w2, a2 = ScopeResolver.contextExcerpt("Last para ends.\nNew para starts >>>here<<< and\nnext para.")
    TestRunner:assertEqual(b2, "New para starts", "before stops at the paragraph break")
    TestRunner:assertEqual(a2, "and", "after stops at the paragraph break")
    local b3 = ScopeResolver.contextExcerpt("Earlier paragraph.\n>>>Opening<<< words")
    TestRunner:assertEqual(b3, "", "word opening its paragraph = empty before")
end)

TestRunner:test("CJK: byte budget on character boundaries, no word snap", function()
    local prev = string.rep("日本語の", 20)  -- 240 bytes, no spaces
    local b = ScopeResolver.contextExcerpt(prev .. ">>>猫<<<です", 30)
    TestRunner:assertEqual(b:sub(1, 3) == "…", true, "cut marked")
    TestRunner:assertEqual(#b - 3 <= 30, true, "within budget")
    TestRunner:assertEqual((#b - 3) % 3 == 0, true, "whole 3-byte characters only")
end)

print("")
print(string.rep("-", 50))
print(string.format("  Results: %d passed, %d failed", TestRunner.passed, TestRunner.failed))
print(string.rep("-", 50))

return TestRunner.failed == 0
