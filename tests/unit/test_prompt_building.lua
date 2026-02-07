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

    extractor.getXrayCache = function()
        return mock_data.xray_cache or { text = "X-Ray content", progress_formatted = "30%", used_annotations = true }
    end

    extractor.getAnalyzeCache = function()
        return mock_data.analyze_cache or { text = "Deep document analysis content" }
    end

    extractor.getSummaryCache = function()
        return mock_data.summary_cache or { text = "Document summary content" }
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

    TestRunner:test("xray_cache_section includes progress in label", function()
        local result = MessageBuilder.build({
            prompt = { prompt = "{xray_cache_section}" },
            context = "general",
            data = { xray_cache = "X-Ray content", xray_cache_progress = "30%" },
        })
        TestRunner:assertContains(result, "Previous X-Ray (as of 30%):")
        TestRunner:assertContains(result, "X-Ray content")
    end)

    TestRunner:test("xray_cache_section omits progress when not provided", function()
        local result = MessageBuilder.build({
            prompt = { prompt = "{xray_cache_section}" },
            context = "general",
            data = { xray_cache = "X-Ray content" },  -- no progress
        })
        TestRunner:assertContains(result, "Previous X-Ray:")
        TestRunner:assertNotContains(result, "(as of")
    end)

    TestRunner:test("analyze_cache_section uses correct label", function()
        local result = MessageBuilder.build({
            prompt = { prompt = "{analyze_cache_section}" },
            context = "general",
            data = { analyze_cache = "Deep analysis." },
        })
        TestRunner:assertContains(result, "Document analysis:")
        TestRunner:assertContains(result, "Deep analysis.")
    end)

    TestRunner:test("summary_cache_section uses correct label", function()
        local result = MessageBuilder.build({
            prompt = { prompt = "{summary_cache_section}" },
            context = "general",
            data = { summary_cache = "Book summary." },
        })
        TestRunner:assertContains(result, "Document summary:")
        TestRunner:assertContains(result, "Book summary.")
    end)

    TestRunner:test("raw xray_cache passes through without label", function()
        local result = MessageBuilder.build({
            prompt = { prompt = "Analysis: {xray_cache}" },
            context = "general",
            data = { xray_cache = "Raw X-Ray" },
        })
        TestRunner:assertContains(result, "Analysis: Raw X-Ray")
        TestRunner:assertNotContains(result, "Previous X-Ray analysis")
    end)

    TestRunner:test("raw summary_cache passes through without label", function()
        local result = MessageBuilder.build({
            prompt = { prompt = "Summary: {summary_cache}" },
            context = "general",
            data = { summary_cache = "Raw summary" },
        })
        TestRunner:assertContains(result, "Summary: Raw summary")
        TestRunner:assertNotContains(result, "Document summary:")
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
    TestRunner:test("xray_cache (with annotations) blocked when use_annotations=false", function()
        local extractor = createMockExtractor({
            enable_book_text_extraction = true,
            enable_annotations_sharing = true,
        })
        -- Default mock has used_annotations=true, so annotation permission is required
        local data = extractor:extractForAction({
            use_book_text = true,
            use_xray_cache = true,
            use_annotations = false,  -- Cache was built with annotations, so this blocks
        })
        TestRunner:assertEquals(data.xray_cache, nil)
    end)

    TestRunner:test("xray_cache blocked when enable_book_text_extraction=false", function()
        local extractor = createMockExtractor({
            enable_book_text_extraction = false,  -- Global gate OFF
            enable_annotations_sharing = true,
        })
        local data = extractor:extractForAction({
            use_book_text = true,
            use_xray_cache = true,
            use_annotations = true,
        })
        TestRunner:assertEquals(data.xray_cache, nil)
    end)

    TestRunner:test("xray_cache (with annotations) blocked when enable_annotations_sharing=false", function()
        local extractor = createMockExtractor({
            enable_book_text_extraction = true,
            enable_annotations_sharing = false,  -- Global annotations gate OFF
        })
        -- Default mock has used_annotations=true, so annotation permission is required
        local data = extractor:extractForAction({
            use_book_text = true,
            use_xray_cache = true,
            use_annotations = true,  -- Action flag ON, but global gate OFF
        })
        TestRunner:assertEquals(data.xray_cache, nil)
    end)

    TestRunner:test("xray_cache (with annotations) allowed when all gates pass", function()
        local extractor = createMockExtractor({
            enable_book_text_extraction = true,
            enable_annotations_sharing = true,
        })
        local data = extractor:extractForAction({
            use_book_text = true,
            use_xray_cache = true,
            use_annotations = true,
        })
        TestRunner:assertContains(data.xray_cache, "X-Ray content")
        TestRunner:assertEquals(data.xray_cache_progress, "30%")
    end)

    TestRunner:test("xray_cache bypass with trusted provider (both global gates off)", function()
        local extractor = createMockExtractor({
            enable_book_text_extraction = false,  -- OFF
            enable_annotations_sharing = false,   -- OFF
            provider = "local_ollama",
            trusted_providers = { "local_ollama" },
        })
        local data = extractor:extractForAction({
            use_book_text = true,
            use_xray_cache = true,
            use_annotations = true,
        })
        TestRunner:assertContains(data.xray_cache, "X-Ray content")
    end)

    -- X-Ray cache WITHOUT annotations does NOT require annotation permission
    TestRunner:test("xray_cache (without annotations) allowed even when annotations disabled", function()
        -- Create extractor with cache that was built WITHOUT annotations
        local extractor = createMockExtractor({
            enable_book_text_extraction = true,
            enable_annotations_sharing = false,  -- Annotations disabled
        }, {
            xray_cache = { text = "X-Ray without annotations", progress_formatted = "40%", used_annotations = false }
        })
        local data = extractor:extractForAction({
            use_book_text = true,
            use_xray_cache = true,
            use_annotations = false,  -- OK because cache was built without annotations
        })
        TestRunner:assertContains(data.xray_cache, "X-Ray without annotations")
    end)

    TestRunner:test("xray_cache (without annotations) allowed when use_annotations=false", function()
        -- Cache built without annotations doesn't require annotation permission
        local extractor = createMockExtractor({
            enable_book_text_extraction = true,
            enable_annotations_sharing = true,  -- Even with annotations enabled globally
        }, {
            xray_cache = { text = "X-Ray no annot", progress_formatted = "25%", used_annotations = false }
        })
        local data = extractor:extractForAction({
            use_book_text = true,
            use_xray_cache = true,
            use_annotations = false,  -- Action doesn't request annotations - OK for this cache
        })
        TestRunner:assertContains(data.xray_cache, "X-Ray no annot")
    end)

    TestRunner:test("xray_cache with nil used_annotations treated as no annotations required", function()
        -- Legacy cache without used_annotations field (nil) - treat as not requiring annotations
        local extractor = createMockExtractor({
            enable_book_text_extraction = true,
        }, {
            xray_cache = { text = "Legacy X-Ray cache", progress_formatted = "20%", used_annotations = nil }
        })
        local data = extractor:extractForAction({
            use_book_text = true,
            use_xray_cache = true,
            -- No use_annotations flag
        })
        TestRunner:assertContains(data.xray_cache, "Legacy X-Ray cache")
    end)

    TestRunner:test("analyze_cache allowed with book_text gates only", function()
        local extractor = createMockExtractor({
            enable_book_text_extraction = true,
            enable_annotations_sharing = false,  -- Not required for analyze
        })
        local data = extractor:extractForAction({
            use_book_text = true,
            use_analyze_cache = true,  -- Explicit flag required
            use_annotations = false,  -- Not required
        })
        TestRunner:assertContains(data.analyze_cache, "Deep document analysis")
    end)

    TestRunner:test("analyze_cache does NOT require use_annotations", function()
        local extractor = createMockExtractor({
            enable_book_text_extraction = true,
        })
        local data = extractor:extractForAction({
            use_book_text = true,
            use_analyze_cache = true,  -- Explicit flag required
            -- use_annotations not set
        })
        TestRunner:assertContains(data.analyze_cache, "Deep document analysis")
    end)

    -- Flag-only pattern: placeholders alone don't trigger extraction
    TestRunner:test("analyze_cache requires explicit flag (placeholder alone not enough)", function()
        local extractor = createMockExtractor({
            enable_book_text_extraction = true,
        })
        local data = extractor:extractForAction({
            use_book_text = true,
            -- use_analyze_cache NOT set
            prompt = "{analyze_cache}",  -- Placeholder in prompt, but no flag
        })
        TestRunner:assertEquals(data.analyze_cache, nil)
    end)

    TestRunner:test("summary_cache requires explicit flag (placeholder alone not enough)", function()
        local extractor = createMockExtractor({
            enable_book_text_extraction = true,
        })
        local data = extractor:extractForAction({
            use_book_text = true,
            -- use_summary_cache NOT set
            prompt = "{summary_cache}",  -- Placeholder in prompt, but no flag
        })
        TestRunner:assertEquals(data.summary_cache, nil)
    end)

    TestRunner:test("xray_cache requires explicit flag (placeholder alone not enough)", function()
        local extractor = createMockExtractor({
            enable_book_text_extraction = true,
            enable_annotations_sharing = true,
        })
        local data = extractor:extractForAction({
            use_book_text = true,
            use_annotations = true,
            -- use_xray_cache NOT set
            prompt = "{xray_cache}",  -- Placeholder in prompt, but no flag
        })
        TestRunner:assertEquals(data.xray_cache, nil)
    end)

    TestRunner:test("summary_cache allowed with book_text gates only", function()
        local extractor = createMockExtractor({
            enable_book_text_extraction = true,
        })
        local data = extractor:extractForAction({
            use_book_text = true,
            use_summary_cache = true,  -- Explicit flag required
        })
        TestRunner:assertContains(data.summary_cache, "Document summary content")
    end)

    TestRunner:test("analysis cache blocked when use_book_text=false", function()
        local extractor = createMockExtractor({
            enable_book_text_extraction = true,
            enable_annotations_sharing = true,
        })
        local data = extractor:extractForAction({
            use_book_text = false,  -- Gate off
            use_xray_cache = true,
            use_analyze_cache = true,
            use_summary_cache = true,
            use_annotations = true,
        })
        TestRunner:assertEquals(data.xray_cache, nil)
        TestRunner:assertEquals(data.analyze_cache, nil)
        TestRunner:assertEquals(data.summary_cache, nil)
    end)
end

-- =============================================================================
-- ActionCache Integration Tests
-- =============================================================================

local function runCacheIntegrationTests()
    print("\n--- ActionCache: Cache Data Flow ---")

    TestRunner:test("xray_cache data flows to MessageBuilder correctly", function()
        local extractor = createMockExtractor({
            enable_book_text_extraction = true,
            enable_annotations_sharing = true,
        })
        local data = extractor:extractForAction({
            use_book_text = true,
            use_xray_cache = true,  -- Explicit flag required
            use_annotations = true,
        })
        -- Now pass to MessageBuilder
        local result = MessageBuilder.build({
            prompt = { prompt = "{xray_cache_section}" },
            context = "general",
            data = data,
        })
        TestRunner:assertContains(result, "Previous X-Ray (as of 30%):")
        TestRunner:assertContains(result, "X-Ray content")
    end)

    TestRunner:test("empty cache results in empty section placeholder", function()
        local extractor = createMockExtractor({
            enable_book_text_extraction = true,
            enable_annotations_sharing = true,
        }, {
            xray_cache = { text = "", progress_formatted = nil, used_annotations = false },  -- Empty cache
        })
        local data = extractor:extractForAction({
            use_book_text = true,
            use_xray_cache = true,  -- Explicit flag required
        })
        local result = MessageBuilder.build({
            prompt = { prompt = "Start{xray_cache_section}End" },
            context = "general",
            data = data,
        })
        TestRunner:assertNotContains(result, "Previous X-Ray analysis")
        TestRunner:assertContains(result, "StartEnd")
    end)

    TestRunner:test("analyze_cache flows without progress", function()
        local extractor = createMockExtractor({
            enable_book_text_extraction = true,
        })
        local data = extractor:extractForAction({
            use_book_text = true,
            use_analyze_cache = true,  -- Explicit flag required
        })
        local result = MessageBuilder.build({
            prompt = { prompt = "{analyze_cache_section}" },
            context = "general",
            data = data,
        })
        TestRunner:assertContains(result, "Document analysis:")
        TestRunner:assertNotContains(result, "(as of")  -- No progress for analyze
    end)

    TestRunner:test("summary_cache flows without progress", function()
        local extractor = createMockExtractor({
            enable_book_text_extraction = true,
        })
        local data = extractor:extractForAction({
            use_book_text = true,
            use_summary_cache = true,  -- Explicit flag required
        })
        local result = MessageBuilder.build({
            prompt = { prompt = "{summary_cache_section}" },
            context = "general",
            data = data,
        })
        TestRunner:assertContains(result, "Document summary:")
    end)

    TestRunner:test("gated-off cache results in section disappearing", function()
        local extractor = createMockExtractor({
            enable_book_text_extraction = false,  -- Gate off
        })
        local data = extractor:extractForAction({
            use_book_text = true,
            use_analyze_cache = true,  -- Explicit flag, but global gate blocks
        })
        local result = MessageBuilder.build({
            prompt = { prompt = "Before{analyze_cache_section}After" },
            context = "general",
            data = data,
        })
        TestRunner:assertNotContains(result, "Document analysis:")
        TestRunner:assertContains(result, "BeforeAfter")
    end)
end

-- =============================================================================
-- Context Type Tests
-- =============================================================================

local function runContextTypeTests()
    print("\n--- MessageBuilder: Context Types ---")

    TestRunner:test("highlight context includes book info when available", function()
        local result = MessageBuilder.build({
            prompt = { prompt = "Explain this term" },
            context = "highlight",
            data = {
                highlighted_text = "serendipity",
                book_title = "The Art of Discovery",
                book_author = "Jane Smith",
            },
        })
        TestRunner:assertContains(result, "[Context]")
        TestRunner:assertContains(result, "The Art of Discovery")
        TestRunner:assertContains(result, "Jane Smith")
        TestRunner:assertContains(result, "serendipity")
    end)

    TestRunner:test("highlight context uses {highlighted_text} placeholder", function()
        local result = MessageBuilder.build({
            prompt = { prompt = 'Define the word "{highlighted_text}"' },
            context = "highlight",
            data = {
                highlighted_text = "ephemeral",
            },
        })
        TestRunner:assertContains(result, 'Define the word "ephemeral"')
        -- Should NOT duplicate the text in context since it's in the prompt
        TestRunner:assertNotContains(result, "Selected text:")
    end)

    TestRunner:test("book context substitutes {title} and {author}", function()
        local result = MessageBuilder.build({
            prompt = { prompt = "Summarize {title} by {author}" },
            context = "book",
            data = {
                book_metadata = {
                    title = "1984",
                    author = "George Orwell",
                },
            },
        })
        TestRunner:assertContains(result, "Summarize 1984 by George Orwell")
    end)

    TestRunner:test("book context substitutes {author_clause} when author present", function()
        local result = MessageBuilder.build({
            prompt = { prompt = "About {title}{author_clause}" },
            context = "book",
            data = {
                book_metadata = {
                    title = "Dune",
                    author = "Frank Herbert",
                    author_clause = " by Frank Herbert",
                },
            },
        })
        TestRunner:assertContains(result, "About Dune by Frank Herbert")
    end)

    TestRunner:test("book context with empty author", function()
        local result = MessageBuilder.build({
            prompt = { prompt = "Review {title}" },
            context = "book",
            data = {
                book_metadata = {
                    title = "Unknown Author Book",
                    author = "",
                },
            },
        })
        TestRunner:assertContains(result, "Review Unknown Author Book")
    end)

    TestRunner:test("multi_book context substitutes {count} and {books_list}", function()
        local result = MessageBuilder.build({
            prompt = { prompt = "Compare these {count} books:\n{books_list}" },
            context = "multi_book",
            data = {
                books_info = {
                    { title = "Book One", authors = "Author A" },
                    { title = "Book Two", authors = "Author B" },
                },
            },
        })
        TestRunner:assertContains(result, "Compare these 2 books:")
        TestRunner:assertContains(result, 'Book One')
        TestRunner:assertContains(result, 'Author A')
        TestRunner:assertContains(result, 'Book Two')
    end)

    TestRunner:test("general context includes just the prompt", function()
        local result = MessageBuilder.build({
            prompt = { prompt = "What is quantum computing?" },
            context = "general",
            data = {},
        })
        TestRunner:assertContains(result, "[Request]")
        TestRunner:assertContains(result, "What is quantum computing?")
        TestRunner:assertNotContains(result, "[Context]")
    end)

    TestRunner:test("general context validates context type", function()
        -- Invalid context should fall back to general
        local result = MessageBuilder.build({
            prompt = { prompt = "Test prompt" },
            context = "invalid_context_type",
            data = {},
        })
        TestRunner:assertContains(result, "[Request]")
        TestRunner:assertContains(result, "Test prompt")
    end)
end

-- =============================================================================
-- Language Placeholder Tests
-- =============================================================================

local function runLanguagePlaceholderTests()
    print("\n--- MessageBuilder: Language Placeholders ---")

    TestRunner:test("{dictionary_language} substitution", function()
        local result = MessageBuilder.build({
            prompt = { prompt = "Define this word in {dictionary_language}" },
            context = "highlight",
            data = {
                highlighted_text = "test",
                dictionary_language = "German",
            },
        })
        TestRunner:assertContains(result, "Define this word in German")
        TestRunner:assertNotContains(result, "{dictionary_language}")
    end)

    TestRunner:test("{translation_language} substitution", function()
        local result = MessageBuilder.build({
            prompt = { prompt = "Translate to {translation_language}" },
            context = "highlight",
            data = {
                highlighted_text = "hello",
                translation_language = "Japanese",
            },
        })
        TestRunner:assertContains(result, "Translate to Japanese")
        TestRunner:assertNotContains(result, "{translation_language}")
    end)

    TestRunner:test("both language placeholders in same prompt", function()
        local result = MessageBuilder.build({
            prompt = { prompt = "Define in {dictionary_language} then translate to {translation_language}" },
            context = "highlight",
            data = {
                highlighted_text = "word",
                dictionary_language = "English",
                translation_language = "French",
            },
        })
        TestRunner:assertContains(result, "Define in English then translate to French")
    end)
end

-- =============================================================================
-- Dictionary Context Tests
-- =============================================================================

local function runDictionaryContextTests()
    print("\n--- MessageBuilder: Dictionary Context ---")

    TestRunner:test("{context_section} includes word disambiguation label", function()
        local result = MessageBuilder.build({
            prompt = { prompt = "{context_section}\n\nDefine the word" },
            context = "highlight",
            data = {
                context = "The book fell from the >>>shelf<<< with a loud crash.",
            },
        })
        TestRunner:assertContains(result, "Word appears in this context:")
        TestRunner:assertContains(result, ">>>shelf<<<")
    end)

    TestRunner:test("{context_section} disappears when context empty", function()
        local result = MessageBuilder.build({
            prompt = { prompt = "{context_section}Define the word" },
            context = "highlight",
            data = {
                context = "",
            },
        })
        TestRunner:assertNotContains(result, "Word appears in this context:")
        TestRunner:assertContains(result, "Define the word")
    end)

    TestRunner:test("{context_section} disappears when dictionary_context_mode=none", function()
        local result = MessageBuilder.build({
            prompt = { prompt = "{context_section}Define the word" },
            context = "highlight",
            data = {
                context = "Some context here",
                dictionary_context_mode = "none",
            },
        })
        TestRunner:assertNotContains(result, "Word appears in this context:")
        TestRunner:assertNotContains(result, "Some context here")
    end)

    TestRunner:test("{context} raw placeholder works", function()
        local result = MessageBuilder.build({
            prompt = { prompt = "Context: {context}" },
            context = "highlight",
            data = {
                context = "raw context text",
            },
        })
        TestRunner:assertContains(result, "Context: raw context text")
    end)

    TestRunner:test("dictionary_context_mode=none strips {context} lines", function()
        local result = MessageBuilder.build({
            prompt = { prompt = "Define word.\nIn context: {context}\nMake it simple." },
            context = "highlight",
            data = {
                context = "some context",
                dictionary_context_mode = "none",
            },
        })
        TestRunner:assertNotContains(result, "{context}")
        TestRunner:assertNotContains(result, "In context")
        TestRunner:assertContains(result, "Define word")
        TestRunner:assertContains(result, "Make it simple")
    end)
end

-- =============================================================================
-- Surrounding Context Tests
-- =============================================================================

local function runSurroundingContextTests()
    print("\n--- MessageBuilder: Surrounding Context ---")

    TestRunner:test("{surrounding_context_section} includes label when present", function()
        local result = MessageBuilder.build({
            prompt = { prompt = "{surrounding_context_section}\n\nAnalyze." },
            context = "highlight",
            data = {
                highlighted_text = "key term",
                surrounding_context = "Previous sentence. Key term appears here. Next sentence.",
            },
        })
        TestRunner:assertContains(result, "Surrounding text:")
        TestRunner:assertContains(result, "Key term appears here")
    end)

    TestRunner:test("{surrounding_context_section} disappears when empty", function()
        local result = MessageBuilder.build({
            prompt = { prompt = "{surrounding_context_section}Analyze." },
            context = "highlight",
            data = {
                highlighted_text = "word",
                surrounding_context = "",
            },
        })
        TestRunner:assertNotContains(result, "Surrounding text:")
        TestRunner:assertContains(result, "Analyze.")
    end)

    TestRunner:test("{surrounding_context} raw placeholder works", function()
        local result = MessageBuilder.build({
            prompt = { prompt = "Nearby text: {surrounding_context}" },
            context = "highlight",
            data = {
                highlighted_text = "word",
                surrounding_context = "The surrounding area.",
            },
        })
        TestRunner:assertContains(result, "Nearby text: The surrounding area.")
    end)
end

-- =============================================================================
-- Reading Stats Placeholders Tests
-- =============================================================================

local function runReadingStatsTests()
    print("\n--- MessageBuilder: Reading Stats Placeholders ---")

    TestRunner:test("{reading_progress} substitution", function()
        local result = MessageBuilder.build({
            prompt = { prompt = "At {reading_progress}, recap the story" },
            context = "book",
            data = {
                book_metadata = { title = "Test Book", author = "" },
                reading_progress = "45%",
            },
        })
        TestRunner:assertContains(result, "At 45%, recap the story")
    end)

    TestRunner:test("{progress_decimal} substitution", function()
        local result = MessageBuilder.build({
            prompt = { prompt = "Progress: {progress_decimal}" },
            context = "book",
            data = {
                book_metadata = { title = "Test", author = "" },
                progress_decimal = "0.45",
            },
        })
        TestRunner:assertContains(result, "Progress: 0.45")
    end)

    TestRunner:test("{chapter_title} substitution", function()
        local result = MessageBuilder.build({
            prompt = { prompt = "Current chapter: {chapter_title}" },
            context = "book",
            data = {
                book_metadata = { title = "Test", author = "" },
                chapter_title = "Chapter 5: The Discovery",
            },
        })
        TestRunner:assertContains(result, "Current chapter: Chapter 5: The Discovery")
    end)

    TestRunner:test("{chapters_read} substitution", function()
        local result = MessageBuilder.build({
            prompt = { prompt = "You have read {chapters_read} chapters" },
            context = "book",
            data = {
                book_metadata = { title = "Test", author = "" },
                chapters_read = "5",
            },
        })
        TestRunner:assertContains(result, "You have read 5 chapters")
    end)

    TestRunner:test("{time_since_last_read} substitution", function()
        local result = MessageBuilder.build({
            prompt = { prompt = "Last read: {time_since_last_read}" },
            context = "book",
            data = {
                book_metadata = { title = "Test", author = "" },
                time_since_last_read = "2 days ago",
            },
        })
        TestRunner:assertContains(result, "Last read: 2 days ago")
    end)
end

-- =============================================================================
-- Cache Placeholder Tests
-- =============================================================================

local function runCachePlaceholderTests()
    print("\n--- MessageBuilder: Cache/Incremental Placeholders ---")

    TestRunner:test("{cached_result} substitution", function()
        local result = MessageBuilder.build({
            prompt = { prompt = "Previous analysis:\n{cached_result}\n\nUpdate this." },
            context = "book",
            data = {
                book_metadata = { title = "Test", author = "" },
                cached_result = "Previous AI analysis text here.",
            },
        })
        TestRunner:assertContains(result, "Previous AI analysis text here.")
    end)

    TestRunner:test("{cached_progress} substitution", function()
        local result = MessageBuilder.build({
            prompt = { prompt = "At {cached_progress} you said..." },
            context = "book",
            data = {
                book_metadata = { title = "Test", author = "" },
                cached_progress = "30%",
            },
        })
        TestRunner:assertContains(result, "At 30% you said...")
    end)

    TestRunner:test("{incremental_book_text_section} includes label when present", function()
        local result = MessageBuilder.build({
            prompt = { prompt = "{incremental_book_text_section}\n\nUpdate analysis." },
            context = "book",
            data = {
                book_metadata = { title = "Test", author = "" },
                incremental_book_text = "New content since last time...",
            },
        })
        TestRunner:assertContains(result, "New content since your last analysis:")
        TestRunner:assertContains(result, "New content since last time...")
    end)

    TestRunner:test("{incremental_book_text_section} disappears when empty", function()
        local result = MessageBuilder.build({
            prompt = { prompt = "{incremental_book_text_section}Update." },
            context = "book",
            data = {
                book_metadata = { title = "Test", author = "" },
                incremental_book_text = "",
            },
        })
        TestRunner:assertNotContains(result, "New content since your last analysis:")
        TestRunner:assertContains(result, "Update.")
    end)
end

-- =============================================================================
-- Additional Input Tests
-- =============================================================================

local function runAdditionalInputTests()
    print("\n--- MessageBuilder: Additional User Input ---")

    TestRunner:test("additional_input appended to message", function()
        local result = MessageBuilder.build({
            prompt = { prompt = "Do the task" },
            context = "general",
            data = {
                additional_input = "Please also consider this extra context.",
            },
        })
        TestRunner:assertContains(result, "[Additional user input]")
        TestRunner:assertContains(result, "Please also consider this extra context.")
    end)

    TestRunner:test("empty additional_input not included", function()
        local result = MessageBuilder.build({
            prompt = { prompt = "Do the task" },
            context = "general",
            data = {
                additional_input = "",
            },
        })
        TestRunner:assertNotContains(result, "[Additional user input]")
    end)
end

-- =============================================================================
-- MessageBuilder.substituteVariables() Tests
-- =============================================================================

local function runSubstituteVariablesTests()
    print("\n--- MessageBuilder.substituteVariables() ---")

    -- Nudges
    TestRunner:test("substituteVariables: {conciseness_nudge} substituted", function()
        local Templates = require("prompts.templates")
        local result = MessageBuilder.substituteVariables("Be brief. {conciseness_nudge}", {})
        TestRunner:assertNotContains(result, "{conciseness_nudge}")
        TestRunner:assertContains(result, Templates.CONCISENESS_NUDGE)
    end)

    TestRunner:test("substituteVariables: {hallucination_nudge} substituted", function()
        local Templates = require("prompts.templates")
        local result = MessageBuilder.substituteVariables("Answer. {hallucination_nudge}", {})
        TestRunner:assertNotContains(result, "{hallucination_nudge}")
        TestRunner:assertContains(result, Templates.HALLUCINATION_NUDGE)
    end)

    -- Language placeholders
    TestRunner:test("substituteVariables: {translation_language}", function()
        local result = MessageBuilder.substituteVariables("Translate to {translation_language}", {
            translation_language = "Spanish",
        })
        TestRunner:assertContains(result, "Translate to Spanish")
    end)

    TestRunner:test("substituteVariables: {dictionary_language}", function()
        local result = MessageBuilder.substituteVariables("Define in {dictionary_language}", {
            dictionary_language = "French",
        })
        TestRunner:assertContains(result, "Define in French")
    end)

    -- Metadata placeholders
    TestRunner:test("substituteVariables: {title}", function()
        local result = MessageBuilder.substituteVariables("About {title}", { title = "Dune" })
        TestRunner:assertContains(result, "About Dune")
    end)

    TestRunner:test("substituteVariables: {author}", function()
        local result = MessageBuilder.substituteVariables("By {author}", { author = "Herbert" })
        TestRunner:assertContains(result, "By Herbert")
    end)

    TestRunner:test("substituteVariables: {author_clause}", function()
        local result = MessageBuilder.substituteVariables("Book{author_clause}", { author_clause = " by Tolkien" })
        TestRunner:assertContains(result, "Book by Tolkien")
    end)

    TestRunner:test("substituteVariables: {highlighted_text}", function()
        local result = MessageBuilder.substituteVariables("Word: {highlighted_text}", { highlighted_text = "quantum" })
        TestRunner:assertContains(result, "Word: quantum")
    end)

    TestRunner:test("substituteVariables: {count}", function()
        local result = MessageBuilder.substituteVariables("Compare {count} books", { count = 3 })
        TestRunner:assertContains(result, "Compare 3 books")
    end)

    TestRunner:test("substituteVariables: {books_list}", function()
        local result = MessageBuilder.substituteVariables("Books:\n{books_list}", { books_list = "1. Book A\n2. Book B" })
        TestRunner:assertContains(result, "1. Book A")
    end)

    -- Section placeholders: present
    TestRunner:test("substituteVariables: {book_text_section} with data", function()
        local result = MessageBuilder.substituteVariables("{book_text_section}", { book_text = "Chapter 1 content" })
        TestRunner:assertContains(result, "Book content so far:")
        TestRunner:assertContains(result, "Chapter 1 content")
    end)

    TestRunner:test("substituteVariables: {book_text_section} disappears when empty", function()
        local result = MessageBuilder.substituteVariables("Start{book_text_section}End", { book_text = "" })
        TestRunner:assertContains(result, "StartEnd")
        TestRunner:assertNotContains(result, "Book content")
    end)

    TestRunner:test("substituteVariables: {highlights_section} with data", function()
        local result = MessageBuilder.substituteVariables("{highlights_section}", { highlights = "- highlight 1" })
        TestRunner:assertContains(result, "My highlights so far:")
    end)

    TestRunner:test("substituteVariables: {annotations_section} disappears when empty", function()
        local result = MessageBuilder.substituteVariables("A{annotations_section}B", { annotations = "" })
        TestRunner:assertContains(result, "AB")
    end)

    TestRunner:test("substituteVariables: {notebook_section} with data", function()
        local result = MessageBuilder.substituteVariables("{notebook_section}", { notebook_content = "My notes" })
        TestRunner:assertContains(result, "My notebook entries:")
        TestRunner:assertContains(result, "My notes")
    end)

    TestRunner:test("substituteVariables: {full_document_section} with data", function()
        local result = MessageBuilder.substituteVariables("{full_document_section}", { full_document = "Full text" })
        TestRunner:assertContains(result, "Full document:")
    end)

    TestRunner:test("substituteVariables: {surrounding_context_section} with data", function()
        local result = MessageBuilder.substituteVariables("{surrounding_context_section}", {
            surrounding_context = "nearby text",
        })
        TestRunner:assertContains(result, "Surrounding text:")
        TestRunner:assertContains(result, "nearby text")
    end)

    -- Cache section placeholders
    TestRunner:test("substituteVariables: {xray_cache_section} with progress", function()
        local result = MessageBuilder.substituteVariables("{xray_cache_section}", {
            xray_cache = "X-Ray data",
            xray_cache_progress = "45%",
        })
        TestRunner:assertContains(result, "Previous X-Ray (as of 45%):")
        TestRunner:assertContains(result, "X-Ray data")
    end)

    TestRunner:test("substituteVariables: {analyze_cache_section} with data", function()
        local result = MessageBuilder.substituteVariables("{analyze_cache_section}", {
            analyze_cache = "Analysis content",
        })
        TestRunner:assertContains(result, "Document analysis:")
    end)

    TestRunner:test("substituteVariables: {summary_cache_section} with data", function()
        local result = MessageBuilder.substituteVariables("{summary_cache_section}", {
            summary_cache = "Summary content",
        })
        TestRunner:assertContains(result, "Document summary:")
    end)

    -- Reading stats
    TestRunner:test("substituteVariables: {chapter_title}", function()
        local result = MessageBuilder.substituteVariables("Ch: {chapter_title}", { chapter_title = "The Beginning" })
        TestRunner:assertContains(result, "Ch: The Beginning")
    end)

    TestRunner:test("substituteVariables: {chapters_read}", function()
        local result = MessageBuilder.substituteVariables("Read {chapters_read}", { chapters_read = "7" })
        TestRunner:assertContains(result, "Read 7")
    end)

    TestRunner:test("substituteVariables: {time_since_last_read}", function()
        local result = MessageBuilder.substituteVariables("Last: {time_since_last_read}", {
            time_since_last_read = "3 days ago",
        })
        TestRunner:assertContains(result, "Last: 3 days ago")
    end)

    -- No structural wrappers
    TestRunner:test("substituteVariables: no [Context] wrapper", function()
        local result = MessageBuilder.substituteVariables("Explain {title}", { title = "1984" })
        TestRunner:assertNotContains(result, "[Context]")
    end)

    TestRunner:test("substituteVariables: no [Request] wrapper", function()
        local result = MessageBuilder.substituteVariables("Explain {title}", { title = "1984" })
        TestRunner:assertNotContains(result, "[Request]")
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
    runContextTypeTests()
    runLanguagePlaceholderTests()
    runDictionaryContextTests()
    runSurroundingContextTests()
    runReadingStatsTests()
    runCachePlaceholderTests()
    runAdditionalInputTests()
    runSubstituteVariablesTests()

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
