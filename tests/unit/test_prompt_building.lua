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
        -- Trusted provider bypasses global gate
        if not extractor:isProviderTrusted() and not extractor:isBookTextExtractionEnabled() then
            return { text = "", disabled = true }
        end
        return mock_data.book_text or { text = "This is the book text content up to current position." }
    end

    extractor.getFullDocumentText = function()
        -- Trusted provider bypasses global gate
        if not extractor:isProviderTrusted() and not extractor:isBookTextExtractionEnabled() then
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
        return mock_data.xray_analysis or { text = "X-Ray analysis content", progress_formatted = "30%", used_annotations = true }
    end

    extractor.getAnalyzeAnalysis = function()
        return mock_data.analyze_analysis or { text = "Deep document analysis content" }
    end

    extractor.getSummaryAnalysis = function()
        return mock_data.summary_analysis or { text = "Book summary content" }
    end

    extractor.getNotebookContent = function()
        return mock_data.notebook_content or { content = "My notebook notes about this book." }
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

    TestRunner:test("notebook_section disappears when empty", function()
        local result = MessageBuilder.build({
            prompt = { prompt = "Notes: {notebook_section}" },
            context = "general",
            data = { notebook_content = "" },
        })
        TestRunner:assertNotContains(result, "My notebook entries:")
        TestRunner:assertNotContains(result, "{notebook_section}")
    end)

    TestRunner:test("notebook_section includes label when present", function()
        local result = MessageBuilder.build({
            prompt = { prompt = "{notebook_section}" },
            context = "general",
            data = { notebook_content = "My reading notes." },
        })
        TestRunner:assertContains(result, "My notebook entries:")
        TestRunner:assertContains(result, "My reading notes.")
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

    TestRunner:test("annotations still blocked when use_annotations=false even with trusted provider", function()
        local extractor = createMockExtractor({
            enable_annotations_sharing = false,
            provider = "my_trusted",
            trusted_providers = { "my_trusted" },
        })
        -- Trusted provider only bypasses global gate, not action flag
        local data = extractor:extractForAction({ use_annotations = false, prompt = "{annotations}" })
        TestRunner:assertEquals(data.annotations, "")
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

    TestRunner:test("book_text bypass with trusted provider", function()
        local extractor = createMockExtractor({
            enable_book_text_extraction = false,  -- Global OFF
            provider = "local_ollama",
            trusted_providers = { "local_ollama" },
        })
        local data = extractor:extractForAction({ use_book_text = true, prompt = "{book_text}" })
        TestRunner:assertContains(data.book_text, "book text content")
    end)

    print("\n--- ContextExtractor: Full Document Double-Gate ---")

    TestRunner:test("full_document blocked when enable_book_text_extraction=false", function()
        local extractor = createMockExtractor({ enable_book_text_extraction = false })
        local data = extractor:extractForAction({ use_book_text = true, prompt = "{full_document}" })
        TestRunner:assertEquals(data.full_document, "")
    end)

    TestRunner:test("full_document allowed when both gates pass", function()
        local extractor = createMockExtractor({ enable_book_text_extraction = true })
        local data = extractor:extractForAction({ use_book_text = true, prompt = "{full_document}" })
        TestRunner:assertContains(data.full_document, "full document text")
    end)

    TestRunner:test("full_document bypass with trusted provider", function()
        local extractor = createMockExtractor({
            enable_book_text_extraction = false,  -- Global OFF
            provider = "my_trusted",
            trusted_providers = { "my_trusted" },
        })
        local data = extractor:extractForAction({ use_book_text = true, prompt = "{full_document}" })
        TestRunner:assertContains(data.full_document, "full document text")
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

    print("\n--- ContextExtractor: Notebook Double-Gate ---")

    TestRunner:test("notebook blocked when enable_notebook_sharing=false (default)", function()
        local extractor = createMockExtractor({})  -- nil = default disabled (opt-in)
        local data = extractor:extractForAction({ use_notebook = true })
        TestRunner:assertEquals(data.notebook_content, "")
    end)

    TestRunner:test("notebook blocked when use_notebook=false", function()
        local extractor = createMockExtractor({ enable_notebook_sharing = true })
        local data = extractor:extractForAction({ use_notebook = false })
        TestRunner:assertEquals(data.notebook_content, nil)  -- Not extracted at all
    end)

    TestRunner:test("notebook allowed when both gates pass", function()
        local extractor = createMockExtractor({ enable_notebook_sharing = true })
        local data = extractor:extractForAction({ use_notebook = true })
        TestRunner:assertContains(data.notebook_content, "notebook notes")
    end)

    TestRunner:test("notebook bypass with trusted provider", function()
        local extractor = createMockExtractor({
            enable_notebook_sharing = false,  -- Global OFF (default)
            provider = "local_ollama",
            trusted_providers = { "local_ollama" },
        })
        local data = extractor:extractForAction({ use_notebook = true })
        TestRunner:assertContains(data.notebook_content, "notebook notes")
    end)

    TestRunner:test("notebook still blocked when use_notebook=false even with trusted provider", function()
        local extractor = createMockExtractor({
            enable_notebook_sharing = false,
            provider = "local_ollama",
            trusted_providers = { "local_ollama" },
        })
        -- Trusted provider only bypasses global gate, not action flag
        local data = extractor:extractForAction({ use_notebook = false })
        TestRunner:assertEquals(data.notebook_content, nil)
    end)

    print("\n--- ContextExtractor: Analysis Cache Gating ---")

    -- X-Ray cache with used_annotations=true (default mock) requires annotation permission
    TestRunner:test("xray_analysis (with annotations) blocked when use_annotations=false", function()
        local extractor = createMockExtractor({
            enable_book_text_extraction = true,
            enable_annotations_sharing = true,
        })
        -- Default mock has used_annotations=true, so annotation permission is required
        local data = extractor:extractForAction({
            use_book_text = true,
            use_xray_analysis = true,
            use_annotations = false,  -- Cache was built with annotations, so this blocks
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
            use_xray_analysis = true,
            use_annotations = true,
        })
        TestRunner:assertEquals(data.xray_analysis, nil)
    end)

    TestRunner:test("xray_analysis (with annotations) blocked when enable_annotations_sharing=false", function()
        local extractor = createMockExtractor({
            enable_book_text_extraction = true,
            enable_annotations_sharing = false,  -- Global annotations gate OFF
        })
        -- Default mock has used_annotations=true, so annotation permission is required
        local data = extractor:extractForAction({
            use_book_text = true,
            use_xray_analysis = true,
            use_annotations = true,  -- Action flag ON, but global gate OFF
        })
        TestRunner:assertEquals(data.xray_analysis, nil)
    end)

    TestRunner:test("xray_analysis (with annotations) allowed when all gates pass", function()
        local extractor = createMockExtractor({
            enable_book_text_extraction = true,
            enable_annotations_sharing = true,
        })
        local data = extractor:extractForAction({
            use_book_text = true,
            use_xray_analysis = true,
            use_annotations = true,
        })
        TestRunner:assertContains(data.xray_analysis, "X-Ray analysis content")
        TestRunner:assertEquals(data.xray_analysis_progress, "30%")
    end)

    TestRunner:test("xray_analysis bypass with trusted provider (both global gates off)", function()
        local extractor = createMockExtractor({
            enable_book_text_extraction = false,  -- OFF
            enable_annotations_sharing = false,   -- OFF
            provider = "local_ollama",
            trusted_providers = { "local_ollama" },
        })
        local data = extractor:extractForAction({
            use_book_text = true,
            use_xray_analysis = true,
            use_annotations = true,
        })
        TestRunner:assertContains(data.xray_analysis, "X-Ray analysis content")
    end)

    -- X-Ray cache WITHOUT annotations does NOT require annotation permission
    TestRunner:test("xray_analysis (without annotations) allowed even when annotations disabled", function()
        -- Create extractor with cache that was built WITHOUT annotations
        local extractor = createMockExtractor({
            enable_book_text_extraction = true,
            enable_annotations_sharing = false,  -- Annotations disabled
        }, {
            xray_analysis = { text = "X-Ray without annotations", progress_formatted = "40%", used_annotations = false }
        })
        local data = extractor:extractForAction({
            use_book_text = true,
            use_xray_analysis = true,
            use_annotations = false,  -- OK because cache was built without annotations
        })
        TestRunner:assertContains(data.xray_analysis, "X-Ray without annotations")
    end)

    TestRunner:test("xray_analysis (without annotations) allowed when use_annotations=false", function()
        -- Cache built without annotations doesn't require annotation permission
        local extractor = createMockExtractor({
            enable_book_text_extraction = true,
            enable_annotations_sharing = true,  -- Even with annotations enabled globally
        }, {
            xray_analysis = { text = "X-Ray no annot", progress_formatted = "25%", used_annotations = false }
        })
        local data = extractor:extractForAction({
            use_book_text = true,
            use_xray_analysis = true,
            use_annotations = false,  -- Action doesn't request annotations - OK for this cache
        })
        TestRunner:assertContains(data.xray_analysis, "X-Ray no annot")
    end)

    TestRunner:test("xray_analysis with nil used_annotations treated as no annotations required", function()
        -- Legacy cache without used_annotations field (nil) - treat as not requiring annotations
        local extractor = createMockExtractor({
            enable_book_text_extraction = true,
        }, {
            xray_analysis = { text = "Legacy X-Ray cache", progress_formatted = "20%", used_annotations = nil }
        })
        local data = extractor:extractForAction({
            use_book_text = true,
            use_xray_analysis = true,
            -- No use_annotations flag
        })
        TestRunner:assertContains(data.xray_analysis, "Legacy X-Ray cache")
    end)

    TestRunner:test("analyze_analysis allowed with book_text gates only", function()
        local extractor = createMockExtractor({
            enable_book_text_extraction = true,
            enable_annotations_sharing = false,  -- Not required for analyze
        })
        local data = extractor:extractForAction({
            use_book_text = true,
            use_analyze_analysis = true,  -- Explicit flag required
            use_annotations = false,  -- Not required
        })
        TestRunner:assertContains(data.analyze_analysis, "Deep document analysis")
    end)

    TestRunner:test("analyze_analysis does NOT require use_annotations", function()
        local extractor = createMockExtractor({
            enable_book_text_extraction = true,
        })
        local data = extractor:extractForAction({
            use_book_text = true,
            use_analyze_analysis = true,  -- Explicit flag required
            -- use_annotations not set
        })
        TestRunner:assertContains(data.analyze_analysis, "Deep document analysis")
    end)

    -- Flag-only pattern: placeholders alone don't trigger extraction
    TestRunner:test("analyze_analysis requires explicit flag (placeholder alone not enough)", function()
        local extractor = createMockExtractor({
            enable_book_text_extraction = true,
        })
        local data = extractor:extractForAction({
            use_book_text = true,
            -- use_analyze_analysis NOT set
            prompt = "{analyze_analysis}",  -- Placeholder in prompt, but no flag
        })
        TestRunner:assertEquals(data.analyze_analysis, nil)
    end)

    TestRunner:test("summary_analysis requires explicit flag (placeholder alone not enough)", function()
        local extractor = createMockExtractor({
            enable_book_text_extraction = true,
        })
        local data = extractor:extractForAction({
            use_book_text = true,
            -- use_summary_analysis NOT set
            prompt = "{summary_analysis}",  -- Placeholder in prompt, but no flag
        })
        TestRunner:assertEquals(data.summary_analysis, nil)
    end)

    TestRunner:test("xray_analysis requires explicit flag (placeholder alone not enough)", function()
        local extractor = createMockExtractor({
            enable_book_text_extraction = true,
            enable_annotations_sharing = true,
        })
        local data = extractor:extractForAction({
            use_book_text = true,
            use_annotations = true,
            -- use_xray_analysis NOT set
            prompt = "{xray_analysis}",  -- Placeholder in prompt, but no flag
        })
        TestRunner:assertEquals(data.xray_analysis, nil)
    end)

    TestRunner:test("summary_analysis allowed with book_text gates only", function()
        local extractor = createMockExtractor({
            enable_book_text_extraction = true,
        })
        local data = extractor:extractForAction({
            use_book_text = true,
            use_summary_analysis = true,  -- Explicit flag required
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
            use_xray_analysis = true,
            use_analyze_analysis = true,
            use_summary_analysis = true,
            use_annotations = true,
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
            use_xray_analysis = true,  -- Explicit flag required
            use_annotations = true,
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
            xray_analysis = { text = "", progress_formatted = nil, used_annotations = false },  -- Empty cache
        })
        local data = extractor:extractForAction({
            use_book_text = true,
            use_xray_analysis = true,  -- Explicit flag required
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
            use_analyze_analysis = true,  -- Explicit flag required
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
            use_summary_analysis = true,  -- Explicit flag required
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
            use_analyze_analysis = true,  -- Explicit flag, but global gate blocks
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
