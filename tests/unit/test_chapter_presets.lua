-- Unit tests for chapter scope presets (flexible_scope_plan.md phase 1):
--   * ScopeResolver.chapterPresets — availability matrix + spoiler clamp policy
--   * QuizChapters agreement — the presets use the same chapter resolution as the
--     chapter-end quiz trigger, so a shared sanity case is pinned here

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

local ScopeResolver = require("koassistant_scope_resolver")
local QuizChapters = require("koassistant_quiz_chapters")

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
function TestRunner:assertNotNil(value, msg)
    if value == nil then
        error(string.format("%s: expected non-nil", msg or "assertNotNil"))
    end
end

local function presets(p) return ScopeResolver.chapterPresets(p) end

-- A mid-book chapter: pages 100–140
local CH = { start_page = 100, end_page = 140 }

TestRunner:suite("chapterPresets — hidden entirely")

TestRunner:test("no chapter (no TOC / front matter) → no presets", function()
    local out = presets({ chapter = nil, current_page = 50, is_whole_doc = true })
    TestRunner:assertNil(out.chapter, "chapter row")
    TestRunner:assertNil(out.chapter_so_far, "so-far row")
end)

TestRunner:test("chapter missing page bounds → no presets", function()
    local out = presets({ chapter = { start_page = 100 }, current_page = 120, is_whole_doc = true })
    TestRunner:assertNil(out.chapter, "chapter row")
    TestRunner:assertNil(out.chapter_so_far, "so-far row")
end)

TestRunner:test("neither whole-doc nor to-position action → no presets", function()
    local out = presets({ chapter = CH, current_page = 120,
        is_whole_doc = false, is_to_position = false })
    TestRunner:assertNil(out.chapter, "chapter row")
    TestRunner:assertNil(out.chapter_so_far, "so-far row")
end)

TestRunner:suite("chapterPresets — whole-doc actions (quiz family)")

TestRunner:test("mid-chapter → both presets, correct ranges", function()
    local out = presets({ chapter = CH, current_page = 120, is_whole_doc = true })
    TestRunner:assertNotNil(out.chapter, "chapter row")
    TestRunner:assertEqual(out.chapter.start_page, 100, "chapter start")
    TestRunner:assertEqual(out.chapter.end_page, 140, "chapter end")
    TestRunner:assertNotNil(out.chapter_so_far, "so-far row")
    TestRunner:assertEqual(out.chapter_so_far.start_page, 100, "so-far start")
    TestRunner:assertEqual(out.chapter_so_far.end_page, 120, "so-far end = current page")
end)

TestRunner:test("at chapter start → full chapter only (nothing read yet)", function()
    local out = presets({ chapter = CH, current_page = 100, is_whole_doc = true })
    TestRunner:assertNotNil(out.chapter, "chapter row")
    TestRunner:assertNil(out.chapter_so_far, "so-far hidden at chapter start")
end)

TestRunner:test("at chapter end → full chapter only (so-far would be identical)", function()
    local out = presets({ chapter = CH, current_page = 140, is_whole_doc = true })
    TestRunner:assertNotNil(out.chapter, "chapter row")
    TestRunner:assertNil(out.chapter_so_far, "so-far hidden at chapter end")
end)

TestRunner:test("default current_page (1) before chapter → chapter only", function()
    local out = presets({ chapter = CH, is_whole_doc = true })
    TestRunner:assertNotNil(out.chapter, "chapter row")
    TestRunner:assertNil(out.chapter_so_far, "so-far hidden")
end)

TestRunner:suite("chapterPresets — spoiler clamp policy")

TestRunner:test("spoiler + mid-chapter → full chapter hidden, so-far shown", function()
    local out = presets({ chapter = CH, current_page = 120,
        is_whole_doc = true, spoiler_free = true })
    TestRunner:assertNil(out.chapter, "full-chapter row hidden (would leak unread text)")
    TestRunner:assertNotNil(out.chapter_so_far, "so-far row IS the clamped scope")
    TestRunner:assertEqual(out.chapter_so_far.end_page, 120, "so-far end = current page")
end)

TestRunner:test("spoiler + chapter finished → full chapter allowed", function()
    local out = presets({ chapter = CH, current_page = 140,
        is_whole_doc = true, spoiler_free = true })
    TestRunner:assertNotNil(out.chapter, "chapter row (nothing unread in it)")
    TestRunner:assertNil(out.chapter_so_far, "so-far hidden at chapter end")
end)

TestRunner:test("spoiler + at chapter start → both hidden", function()
    local out = presets({ chapter = CH, current_page = 100,
        is_whole_doc = true, spoiler_free = true })
    TestRunner:assertNil(out.chapter, "chapter row hidden under spoiler mid-chapter")
    TestRunner:assertNil(out.chapter_so_far, "so-far hidden at chapter start")
end)

TestRunner:suite("chapterPresets — to-position actions (recap family)")

TestRunner:test("mid-chapter → so-far only (full run already stops at position)", function()
    local out = presets({ chapter = CH, current_page = 120, is_to_position = true })
    TestRunner:assertNil(out.chapter, "full-chapter row never offered")
    TestRunner:assertNotNil(out.chapter_so_far, "so-far row")
    TestRunner:assertEqual(out.chapter_so_far.start_page, 100, "so-far start")
    TestRunner:assertEqual(out.chapter_so_far.end_page, 120, "so-far end")
end)

TestRunner:test("at chapter start / end → nothing", function()
    local at_start = presets({ chapter = CH, current_page = 100, is_to_position = true })
    TestRunner:assertNil(at_start.chapter_so_far, "so-far hidden at start")
    TestRunner:assertNil(at_start.chapter, "chapter hidden")
    local at_end = presets({ chapter = CH, current_page = 140, is_to_position = true })
    TestRunner:assertNil(at_end.chapter_so_far, "so-far hidden at end")
    TestRunner:assertNil(at_end.chapter, "chapter hidden")
end)

TestRunner:test("spoiler never affects the so-far row (its end IS the position)", function()
    local out = presets({ chapter = CH, current_page = 120,
        is_to_position = true, spoiler_free = true })
    TestRunner:assertNotNil(out.chapter_so_far, "so-far row")
    TestRunner:assertEqual(out.chapter_so_far.end_page, 120, "so-far end")
end)

TestRunner:suite("agreement with the chapter-end quiz resolution")

TestRunner:test("presets range matches _chapterContentRange semantics (next same-depth entry)", function()
    -- TOC: ch1 p1, ch2 p100 (with a nested sub at p110), ch3 p141
    local toc = {
        { page = 1, depth = 1 },
        { page = 100, depth = 1 },
        { page = 110, depth = 2 },
        { page = 141, depth = 1 },
    }
    local indices = QuizChapters.chapterIndices(toc, 1)
    local idx = QuizChapters.currentChapter(toc, indices, 120)
    TestRunner:assertEqual(idx, 2, "current chapter = ch2 (sub-entry invisible at level 1)")
    -- Chapter content range: ch2 start → next same-or-shallower entry's start − 1
    local start_page = toc[idx].page
    local end_page = toc[4].page - 1
    local out = presets({
        chapter = { start_page = start_page, end_page = end_page },
        current_page = 120, is_whole_doc = true,
    })
    TestRunner:assertEqual(out.chapter.start_page, 100, "chapter start from TOC")
    TestRunner:assertEqual(out.chapter.end_page, 140, "chapter end = next chapter start − 1")
end)

print(string.format("\n  chapter presets: %d passed, %d failed", TestRunner.passed, TestRunner.failed))

return TestRunner.failed == 0
