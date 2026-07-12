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

TestRunner:test("n=1 mid-paragraph: remainder of the containing paragraph only", function()
    local prev = "Par one.\nPar two.\nStart of par three "
    local nxt = " end of par three.\nPar four.\nPar five."
    local before, after = ScopeResolver.paragraphWindow(prev, nxt, 1, 1000)
    TestRunner:assertEqual(before, "Start of par three ", "before = containing-paragraph remainder")
    TestRunner:assertEqual(after, " end of par three.", "after = containing-paragraph remainder")
end)

TestRunner:test("n=2 adds one whole neighbor paragraph per side", function()
    local prev = "Par one.\nPar two.\nStart of par three "
    local nxt = " end of par three.\nPar four.\nPar five."
    local before, after = ScopeResolver.paragraphWindow(prev, nxt, 2, 1000)
    TestRunner:assertEqual(before, "Par two.\nStart of par three ", "before = prev paragraph + remainder")
    TestRunner:assertEqual(after, " end of par three.\nPar four.", "after = remainder + next paragraph")
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
    TestRunner:assertContains(result, "and lands.", "sentence after included")
    TestRunner:assertNotContains(result, "Next sentence here", "beyond sentence end excluded")
end)

TestRunner:test("characters mode respects char_count and ellipsizes truncation", function()
    local result = ScopeResolver.trimContext(
        string.rep("a", 300), string.rep("b", 300), "WORD", "characters", { char_count = 50 })
    TestRunner:assertContains(result, ">>>WORD<<<", "marker present")
    TestRunner:assertContains(result, "..." .. string.rep("a", 50), "before truncated + ellipsis")
    TestRunner:assertContains(result, string.rep("b", 50) .. "...", "after truncated + ellipsis")
end)

TestRunner:test("paragraph mode uses opts.paragraphs", function()
    local result = ScopeResolver.trimContext(
        "P1.\nP2.\nP3 start ", " P3 end.\nP4.\nP5.", "SEL", "paragraph", { paragraphs = 2 })
    TestRunner:assertContains(result, "P2.", "second paragraph back included")
    TestRunner:assertContains(result, "P4.", "second paragraph forward included")
    TestRunner:assertNotContains(result, "P1.", "third paragraph back excluded")
    TestRunner:assertNotContains(result, "P5.", "third paragraph forward excluded")
end)

TestRunner:test("mode none / empty window return empty string", function()
    TestRunner:assertEqual(ScopeResolver.trimContext("a", "b", "w", "none"), "", "none mode")
    TestRunner:assertEqual(ScopeResolver.trimContext("", "", "w", "sentence"), "", "empty window")
    TestRunner:assertEqual(ScopeResolver.trimContext(nil, nil, "w", "sentence"), "", "nil window")
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
    TestRunner:assertNil(Actions.highlight.grammar.use_surrounding_context,
        "grammar follows ambient (strong beneficiary)")
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

print("")
print(string.rep("-", 50))
print(string.format("  Results: %d passed, %d failed", TestRunner.passed, TestRunner.failed))
print(string.rep("-", 50))

return TestRunner.failed == 0
