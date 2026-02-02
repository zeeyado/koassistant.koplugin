--[[
Unit Tests for Prompt Building & Gating

Tests the full prompt building pipeline:
- MessageBuilder placeholder replacement (section placeholders, raw placeholders)
- ContextExtractor privacy gating (double-gate pattern, opt-in vs opt-out)
- Analysis cache placeholder propagation

Run: lua tests/run_tests.lua --unit
]]

-- Setup test environment
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

local MessageBuilder = require("message_builder")
local ContextExtractor = require("koassistant_context_extractor")

-- Test suite
local TestRunner = {
    passed = 0,
    failed = 0,
}

function TestRunner:test(name, fn)
    local ok, err = pcall(fn)
    if ok then
        self.passed = self.passed + 1
        print(string.format("  \226\156\147 %s", name))
    else
        self.failed = self.failed + 1
        print(string.format("  \226\156\151 %s: %s", name, tostring(err)))
    end
end

function TestRunner:assert(condition, message)
    if not condition then
        error(message or "Assertion failed", 2)
    end
end

function TestRunner:assertEquals(actual, expected, message)
    if actual ~= expected then
        error(string.format("%s: expected '%s', got '%s'",
            message or "Values not equal",
            tostring(expected),
            tostring(actual)), 2)
    end
end

function TestRunner:assertContains(str, substring, message)
    if not str:find(substring, 1, true) then
        error(string.format("%s: '%s' not found in '%s'",
            message or "Substring not found",
            substring,
            str:sub(1, 100) .. (str:len() > 100 and "..." or "")), 2)
    end
end

function TestRunner:assertNotContains(str, substring, message)
    if str:find(substring, 1, true) then
        error(string.format("%s: '%s' should not be in '%s'",
            message or "Unexpected substring found",
            substring,
            str:sub(1, 100) .. (str:len() > 100 and "..." or "")), 2)
    end
end

-- =============================================================================
-- Mock Infrastructure
-- =============================================================================

--- Create a mock ContextExtractor with controllable data methods.
-- @param settings table Privacy settings (enable_annotations_sharing, etc.)
-- @param mock_data table Optional mock data for each method
-- @return ContextExtractor instance with mocked methods
local function createMockExtractor(settings, mock_data)
    mock_data = mock_data or {}

    local extractor = ContextExtractor:new(nil, settings or {})

    -- isAvailable always returns true for testing
    extractor.isAvailable = function() return true end

    -- Override data extraction methods with mock data
    extractor.getHighlights = function()
        return mock_data.highlights or { formatted = "- Test highlight from chapter 1" }
    end

    extractor.getAnnotations = function()
        return mock_data.annotations or { formatted = "- Test annotation with note" }
    end

    extractor.getBookText = function()
        if not extractor:isBookTextExtractionEnabled() then
            return { text = "", disabled = true }
        end
        return mock_data.book_text or { text = "This is the book text content up to current position." }
    end

    extractor.getFullDocumentText = function()
        if not extractor:isBookTextExtractionEnabled() then
            return { text = "", disabled = true }
        end
        return mock_data.full_document or { text = "This is the full document text." }
    end

    extractor.getReadingProgress = function()
        return mock_data.reading_progress or { formatted = "50%", decimal = 0.5 }
    end

    extractor.getReadingStats = function()
        return mock_data.reading_stats or {
            chapter_title = "Chapter 5: The Journey",
            chapters_read = "5",
            time_since_last_read = "2 hours ago",
        }
    end

    extractor.getXrayAnalysis = function()
        return mock_data.xray_analysis or { text = "X-Ray analysis content", progress_formatted = "30%" }
    end

    extractor.getAnalyzeAnalysis = function()
        return mock_data.analyze_analysis or { text = "Deep document analysis content" }
    end

    extractor.getSummaryAnalysis = function()
        return mock_data.summary_analysis or { text = "Book summary content" }
    end

    return extractor
end

-- =============================================================================
-- MessageBuilder Tests
-- =============================================================================

local function runMessageBuilderTests()
    print("\n--- MessageBuilder: Section Placeholders ---")

    TestRunner:test("book_text_section disappears when empty", function()
        local result = MessageBuilder.build({
            prompt = { prompt = "Here: {book_text_section} End." },
            context = "general",
            data = { book_text = "" },
        })
        TestRunner:assertNotContains(result, "Book content so far:")
        TestRunner:assertNotContains(result, "{book_text_section}")
        TestRunner:assertContains(result, "Here:  End.")
    end)

    TestRunner:test("book_text_section includes label when present", function()
        local result = MessageBuilder.build({
            prompt = { prompt = "Here: {book_text_section}" },
            context = "general",
            data = { book_text = "Sample book text." },
        })
        TestRunner:assertContains(result, "Book content so far:")
        TestRunner:assertContains(result, "Sample book text.")
    end)

    TestRunner:test("highlights_section disappears when empty", function()
        local result = MessageBuilder.build({
            prompt = { prompt = "Highlights: {highlights_section}" },
            context = "general",
            data = { highlights = "" },
        })
        TestRunner:assertNotContains(result, "My highlights so far:")
        TestRunner:assertNotContains(result, "{highlights_section}")
    end)

    TestRunner:test("annotations_section includes label when present", function()
        local result = MessageBuilder.build({
            prompt = { prompt = "{annotations_section}" },
            context = "general",
            data = { annotations = "- Test note" },
        })
        TestRunner:assertContains(result, "My annotations:")
        TestRunner:assertContains(result, "- Test note")
    end)

    TestRunner:test("full_document_section includes label when present", function()
        local result = MessageBuilder.build({
            prompt = { prompt = "{full_document_section}" },
            context = "general",
            data = { full_document = "Full doc content." },
        })
        TestRunner:assertContains(result, "Full document:")
        TestRunner:assertContains(result, "Full doc content.")
    end)

    TestRunner:test("surrounding_context_section includes label when present", function()
        local result = MessageBuilder.build({
            prompt = { prompt = "{surrounding_context_section}" },
            context = "general",
            data = { surrounding_context = "The text around the highlight." },
        })
        TestRunner:assertContains(result, "Surrounding text:")
        TestRunner:assertContains(result, "The text around the highlight.")
    end)

    print("\n--- MessageBuilder: Analysis Cache Placeholders ---")

    TestRunner:test("xray_analysis_section includes progress in label", function()
        local result = MessageBuilder.build({
            prompt = { prompt = "{xray_analysis_section}" },
            context = "general",
            data = { xray_analysis = "X-Ray content", xray_analysis_progress = "30%" },
        })
        TestRunner:assertContains(result, "Previous X-Ray analysis (as of 30%):")
        TestRunner:assertContains(result, "X-Ray content")
    end)

    TestRunner:test("xray_analysis_section omits progress when not provided", function()
        local result = MessageBuilder.build({
            prompt = { prompt = "{xray_analysis_section}" },
            context = "general",
            data = { xray_analysis = "X-Ray content" },  -- no progress
        })
        TestRunner:assertContains(result, "Previous X-Ray analysis:")
        TestRunner:assertNotContains(result, "(as of")
    end)

    TestRunner:test("analyze_analysis_section uses correct label", function()
        local result = MessageBuilder.build({
            prompt = { prompt = "{analyze_analysis_section}" },
            context = "general",
            data = { analyze_analysis = "Deep analysis." },
        })
        TestRunner:assertContains(result, "Document analysis:")
        TestRunner:assertContains(result, "Deep analysis.")
    end)

    TestRunner:test("summary_analysis_section uses correct label", function()
        local result = MessageBuilder.build({
            prompt = { prompt = "{summary_analysis_section}" },
            context = "general",
            data = { summary_analysis = "Book summary." },
        })
        TestRunner:assertContains(result, "Book summary:")
        TestRunner:assertContains(result, "Book summary.")
    end)

    TestRunner:test("raw xray_analysis passes through without label", function()
        local result = MessageBuilder.build({
            prompt = { prompt = "Analysis: {xray_analysis}" },
            context = "general",
            data = { xray_analysis = "Raw X-Ray" },
        })
        TestRunner:assertContains(result, "Analysis: Raw X-Ray")
        TestRunner:assertNotContains(result, "Previous X-Ray analysis")
    end)

    TestRunner:test("raw summary_analysis passes through without label", function()
        local result = MessageBuilder.build({
            prompt = { prompt = "Summary: {summary_analysis}" },
            context = "general",
            data = { summary_analysis = "Raw summary" },
        })
        TestRunner:assertContains(result, "Summary: Raw summary")
        TestRunner:assertNotContains(result, "Book summary:")
    end)

    print("\n--- MessageBuilder: Multiple Placeholders ---")

    TestRunner:test("multiple section placeholders in same prompt", function()
        local result = MessageBuilder.build({
            prompt = { prompt = "{book_text_section}\n\n{highlights_section}" },
            context = "general",
            data = { book_text = "Book content", highlights = "- Highlight" },
        })
        TestRunner:assertContains(result, "Book content so far:")
        TestRunner:assertContains(result, "My highlights so far:")
    end)

    TestRunner:test("mixed section and raw placeholders", function()
        local result = MessageBuilder.build({
            prompt = { prompt = "{annotations_section}\nRaw: {annotations}" },
            context = "general",
            data = { annotations = "Test annotation" },
        })
        TestRunner:assertContains(result, "My annotations:")
        TestRunner:assertContains(result, "Raw: Test annotation")
    end)

    TestRunner:test("all empty sections leave no artifacts", function()
        local result = MessageBuilder.build({
            prompt = { prompt = "Start{book_text_section}{highlights_section}{annotations_section}End" },
            context = "general",
            data = { book_text = "", highlights = "", annotations = "" },
        })
        TestRunner:assertEquals(result:find("StartEnd", 1, true) ~= nil, true, "Should be 'StartEnd' with no artifacts")
        TestRunner:assertNotContains(result, "Book content")
        TestRunner:assertNotContains(result, "highlights")
        TestRunner:assertNotContains(result, "annotations")
    end)
end

-- =============================================================================
-- ContextExtractor Gating Tests
-- =============================================================================

local function runGatingTests()
    print("\n--- ContextExtractor: Annotations Double-Gate ---")

    TestRunner:test("annotations blocked when enable_annotations_sharing=false", function()
        local extractor = createMockExtractor({ enable_annotations_sharing = false })
        local data = extractor:extractForAction({ use_annotations = true, prompt = "{annotations}" })
        TestRunner:assertEquals(data.annotations, "")
        TestRunner:assertEquals(data.highlights, "")
    end)

    TestRunner:test("annotations blocked when use_annotations=false", function()
        local extractor = createMockExtractor({ enable_annotations_sharing = true })
        local data = extractor:extractForAction({ use_annotations = false, prompt = "{annotations}" })
        TestRunner:assertEquals(data.annotations, "")
        TestRunner:assertEquals(data.highlights, "")
    end)

    TestRunner:test("annotations allowed when both gates pass", function()
        local extractor = createMockExtractor({ enable_annotations_sharing = true })
        local data = extractor:extractForAction({ use_annotations = true, prompt = "{annotations}" })
        TestRunner:assertContains(data.annotations, "Test annotation")
        TestRunner:assertContains(data.highlights, "Test highlight")
    end)

    TestRunner:test("annotations bypass with trusted provider", function()
        local extractor = createMockExtractor({
            enable_annotations_sharing = false,  -- Global OFF
            provider = "my_trusted",
            trusted_providers = { "my_trusted" },
        })
        local data = extractor:extractForAction({ use_annotations = true, prompt = "{annotations}" })
        TestRunner:assertContains(data.annotations, "Test annotation")
    end)

    print("\n--- ContextExtractor: Book Text Double-Gate ---")

    TestRunner:test("book_text blocked when enable_book_text_extraction=false", function()
        local extractor = createMockExtractor({ enable_book_text_extraction = false })
        local data = extractor:extractForAction({ use_book_text = true, prompt = "{book_text}" })
        TestRunner:assertEquals(data.book_text, "")  -- Empty due to gate
    end)

    TestRunner:test("book_text allowed when both gates pass", function()
        local extractor = createMockExtractor({ enable_book_text_extraction = true })
        local data = extractor:extractForAction({ use_book_text = true, prompt = "{book_text}" })
        TestRunner:assertContains(data.book_text, "book text content")
    end)

    TestRunner:test("book_text not extracted when use_book_text=false", function()
        local extractor = createMockExtractor({ enable_book_text_extraction = true })
        local data = extractor:extractForAction({ use_book_text = false, prompt = "{book_text}" })
        TestRunner:assertEquals(data.book_text, nil)  -- Not extracted at all
    end)

    TestRunner:test("isBookTextExtractionEnabled returns false when nil", function()
        local extractor = createMockExtractor({})  -- No setting
        TestRunner:assertEquals(extractor:isBookTextExtractionEnabled(), false)
    end)

    print("\n--- ContextExtractor: Progress/Stats Opt-Out Pattern ---")

    TestRunner:test("progress allowed when enable_progress_sharing=nil (default)", function()
        local extractor = createMockExtractor({})  -- nil = default enabled
        local data = extractor:extractForAction({})
        TestRunner:assertEquals(data.reading_progress, "50%")
    end)

    TestRunner:test("progress allowed when enable_progress_sharing=true", function()
        local extractor = createMockExtractor({ enable_progress_sharing = true })
        local data = extractor:extractForAction({})
        TestRunner:assertEquals(data.reading_progress, "50%")
    end)

    TestRunner:test("progress blocked when enable_progress_sharing=false", function()
        local extractor = createMockExtractor({ enable_progress_sharing = false })
        local data = extractor:extractForAction({})
        TestRunner:assertEquals(data.reading_progress, "")
    end)

    TestRunner:test("stats allowed when enable_stats_sharing=nil (default)", function()
        local extractor = createMockExtractor({})
        local data = extractor:extractForAction({})
        TestRunner:assertEquals(data.chapter_title, "Chapter 5: The Journey")
        TestRunner:assertEquals(data.chapters_read, "5")
    end)

    TestRunner:test("stats blocked when enable_stats_sharing=false", function()
        local extractor = createMockExtractor({ enable_stats_sharing = false })
        local data = extractor:extractForAction({})
        TestRunner:assertEquals(data.chapter_title, "")
        TestRunner:assertEquals(data.chapters_read, "")
    end)

    print("\n--- ContextExtractor: Analysis Cache Gating ---")

    TestRunner:test("xray_analysis blocked when use_annotations=false", function()
        local extractor = createMockExtractor({
            enable_book_text_extraction = true,
            enable_annotations_sharing = true,
        })
        local data = extractor:extractForAction({
            use_book_text = true,
            use_annotations = false,  -- X-Ray requires annotations
            prompt = "{xray_analysis}",
        })
        TestRunner:assertEquals(data.xray_analysis, nil)
    end)

    TestRunner:test("xray_analysis blocked when enable_book_text_extraction=false", function()
        local extractor = createMockExtractor({
            enable_book_text_extraction = false,  -- Global gate OFF
            enable_annotations_sharing = true,
        })
        local data = extractor:extractForAction({
            use_book_text = true,
            use_annotations = true,
            prompt = "{xray_analysis}",
        })
        TestRunner:assertEquals(data.xray_analysis, nil)
    end)

    TestRunner:test("xray_analysis allowed when all gates pass", function()
        local extractor = createMockExtractor({
            enable_book_text_extraction = true,
            enable_annotations_sharing = true,
        })
        local data = extractor:extractForAction({
            use_book_text = true,
            use_annotations = true,
            prompt = "{xray_analysis}",
        })
        TestRunner:assertContains(data.xray_analysis, "X-Ray analysis content")
        TestRunner:assertEquals(data.xray_analysis_progress, "30%")
    end)

    TestRunner:test("analyze_analysis allowed with book_text gates only", function()
        local extractor = createMockExtractor({
            enable_book_text_extraction = true,
            enable_annotations_sharing = false,  -- Not required for analyze
        })
        local data = extractor:extractForAction({
            use_book_text = true,
            use_annotations = false,  -- Not required
            prompt = "{analyze_analysis}",
        })
        TestRunner:assertContains(data.analyze_analysis, "Deep document analysis")
    end)

    TestRunner:test("analyze_analysis does NOT require use_annotations", function()
        local extractor = createMockExtractor({
            enable_book_text_extraction = true,
        })
        local data = extractor:extractForAction({
            use_book_text = true,
            -- use_annotations not set
            prompt = "{analyze_analysis}",
        })
        TestRunner:assertContains(data.analyze_analysis, "Deep document analysis")
    end)

    TestRunner:test("summary_analysis allowed with book_text gates only", function()
        local extractor = createMockExtractor({
            enable_book_text_extraction = true,
        })
        local data = extractor:extractForAction({
            use_book_text = true,
            prompt = "{summary_analysis}",
        })
        TestRunner:assertContains(data.summary_analysis, "Book summary content")
    end)

    TestRunner:test("analysis cache blocked when use_book_text=false", function()
        local extractor = createMockExtractor({
            enable_book_text_extraction = true,
            enable_annotations_sharing = true,
        })
        local data = extractor:extractForAction({
            use_book_text = false,  -- Gate off
            use_annotations = true,
            prompt = "{xray_analysis} {analyze_analysis} {summary_analysis}",
        })
        TestRunner:assertEquals(data.xray_analysis, nil)
        TestRunner:assertEquals(data.analyze_analysis, nil)
        TestRunner:assertEquals(data.summary_analysis, nil)
    end)
end

-- =============================================================================
-- ActionCache Integration Tests
-- =============================================================================

local function runCacheIntegrationTests()
    print("\n--- ActionCache: Cache Data Flow ---")

    TestRunner:test("xray_analysis data flows to MessageBuilder correctly", function()
        local extractor = createMockExtractor({
            enable_book_text_extraction = true,
            enable_annotations_sharing = true,
        })
        local data = extractor:extractForAction({
            use_book_text = true,
            use_annotations = true,
            prompt = "{xray_analysis_section}",
        })
        -- Now pass to MessageBuilder
        local result = MessageBuilder.build({
            prompt = { prompt = "{xray_analysis_section}" },
            context = "general",
            data = data,
        })
        TestRunner:assertContains(result, "Previous X-Ray analysis (as of 30%):")
        TestRunner:assertContains(result, "X-Ray analysis content")
    end)

    TestRunner:test("empty cache results in empty section placeholder", function()
        local extractor = createMockExtractor({
            enable_book_text_extraction = true,
            enable_annotations_sharing = true,
        }, {
            xray_analysis = { text = "", progress_formatted = nil },  -- Empty cache
        })
        local data = extractor:extractForAction({
            use_book_text = true,
            use_annotations = true,
            prompt = "{xray_analysis_section}",
        })
        local result = MessageBuilder.build({
            prompt = { prompt = "Start{xray_analysis_section}End" },
            context = "general",
            data = data,
        })
        TestRunner:assertNotContains(result, "Previous X-Ray analysis")
        TestRunner:assertContains(result, "StartEnd")
    end)

    TestRunner:test("analyze_analysis flows without progress", function()
        local extractor = createMockExtractor({
            enable_book_text_extraction = true,
        })
        local data = extractor:extractForAction({
            use_book_text = true,
            prompt = "{analyze_analysis_section}",
        })
        local result = MessageBuilder.build({
            prompt = { prompt = "{analyze_analysis_section}" },
            context = "general",
            data = data,
        })
        TestRunner:assertContains(result, "Document analysis:")
        TestRunner:assertNotContains(result, "(as of")  -- No progress for analyze
    end)

    TestRunner:test("summary_analysis flows without progress", function()
        local extractor = createMockExtractor({
            enable_book_text_extraction = true,
        })
        local data = extractor:extractForAction({
            use_book_text = true,
            prompt = "{summary_analysis_section}",
        })
        local result = MessageBuilder.build({
            prompt = { prompt = "{summary_analysis_section}" },
            context = "general",
            data = data,
        })
        TestRunner:assertContains(result, "Book summary:")
    end)

    TestRunner:test("gated-off cache results in section disappearing", function()
        local extractor = createMockExtractor({
            enable_book_text_extraction = false,  -- Gate off
        })
        local data = extractor:extractForAction({
            use_book_text = true,
            prompt = "{analyze_analysis_section}",
        })
        local result = MessageBuilder.build({
            prompt = { prompt = "Before{analyze_analysis_section}After" },
            context = "general",
            data = data,
        })
        TestRunner:assertNotContains(result, "Document analysis:")
        TestRunner:assertContains(result, "BeforeAfter")
    end)
end

-- =============================================================================
-- Run All Tests
-- =============================================================================

local function runAll()
    print("\n=== Testing Prompt Building & Gating ===")

    runMessageBuilderTests()
    runGatingTests()
    runCacheIntegrationTests()

    print(string.format("\n=== Results: %d passed, %d failed ===\n", TestRunner.passed, TestRunner.failed))
    return TestRunner.failed == 0
end

-- Run tests if executed directly
if arg and arg[0] and arg[0]:match("test_prompt_building%.lua$") then
    local success = runAll()
    os.exit(success and 0 or 1)
end

return {
    runAll = runAll,
    TestRunner = TestRunner,
}
