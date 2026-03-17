--[[
Unit Tests for sidecar data access and privacy gating

Tests that the ContextExtractor correctly handles file browser (sidecar) context:
- Sidecar access detection (hasSidecarAccess, getDocumentPath)
- Privacy gating applies identically for sidecar reads as for open book
- Sidecar fallback in getHighlights/getAnnotations/getNotebookContent/getReadingProgress
- Cache methods work with sidecar document_path
- Trusted provider bypass works in sidecar context
- requiresOpenBook correctly classifies LIVE vs SIDECAR flags

Run: lua tests/run_tests.lua --unit
]]

-- Setup test environment
package.path = package.path .. ";./?.lua;./?/init.lua"
require("tests.lib.mock_koreader")

local ContextExtractor = require("koassistant_context_extractor")
local Actions = require("prompts.actions")

-- Test suite
local TestRunner = {
    passed = 0,
    failed = 0,
}

function TestRunner:test(name, fn)
    local ok, err = pcall(fn)
    if ok then
        self.passed = self.passed + 1
        print(string.format("  ✓ %s", name))
    else
        self.failed = self.failed + 1
        print(string.format("  ✗ %s: %s", name, tostring(err)))
    end
end

function TestRunner:assert(condition, message)
    if not condition then
        error(message or "Assertion failed", 2)
    end
end

function TestRunner:assertEquals(actual, expected, message)
    if actual ~= expected then
        error(string.format("%s\n  expected: %s\n  actual:   %s",
            message or "Values not equal",
            tostring(expected), tostring(actual)), 2)
    end
end

function TestRunner:assertContains(str, substring, message)
    if type(str) ~= "string" or not str:find(substring, 1, true) then
        error(string.format("%s\n  expected to contain: %q\n  actual: %s",
            message or "String does not contain expected substring",
            substring, tostring(str)), 2)
    end
end

function TestRunner:assertNotContains(str, substring, message)
    if type(str) == "string" and str:find(substring, 1, true) then
        error(string.format("%s\n  expected NOT to contain: %q\n  actual: %s",
            message or "String contains unexpected substring",
            substring, tostring(str)), 2)
    end
end

-- =============================================================================
-- Mock Infrastructure
-- =============================================================================

-- Mock DocSettings for sidecar reads
local mock_sidecar_data = {}

local mock_doc_settings_instance = {
    readSetting = function(self, key)
        return mock_sidecar_data[key]
    end,
}

local original_docsettings = package.loaded["docsettings"]
package.loaded["docsettings"] = {
    open = function(self, path)
        if path and mock_sidecar_data._valid_path then
            return mock_doc_settings_instance
        end
        return mock_doc_settings_instance
    end,
}

-- Mock Notebook for sidecar reads
local mock_notebook_content = ""
local original_notebook = package.loaded["koassistant_notebook"]
package.loaded["koassistant_notebook"] = {
    read = function(path)
        if path then return mock_notebook_content end
        return ""
    end,
}

-- Mock ActionCache for cache tests
local mock_cache_data = {}
local original_action_cache = package.loaded["koassistant_action_cache"]
package.loaded["koassistant_action_cache"] = {
    getXrayCache = function(path)
        return mock_cache_data.xray
    end,
    getAnalyzeCache = function(path)
        return mock_cache_data.analyze
    end,
    getSummaryCache = function(path)
        return mock_cache_data.summary
    end,
}

--- Helper: create a sidecar-mode ContextExtractor (no ui, just document_path + settings)
local function createSidecarExtractor(settings, opts)
    opts = opts or {}
    local s = settings or {}
    s.document_path = s.document_path or "/test/books/sample.epub"
    return ContextExtractor:new(nil, s)
end

--- Helper: create an open-book mock ContextExtractor for comparison
local function createOpenBookExtractor(settings)
    local mock_ui = {
        document = { file = "/test/books/sample.epub" },
        annotation = {
            annotations = mock_sidecar_data.annotations or {},
        },
    }
    return ContextExtractor:new(mock_ui, settings or {})
end

--- Helper: set up sidecar data for tests
local function setupSidecarData(data)
    mock_sidecar_data = data or {}
    mock_sidecar_data._valid_path = true
end

--- Helper: reset all mock data
local function resetMocks()
    mock_sidecar_data = {}
    mock_notebook_content = ""
    mock_cache_data = {}
end

-- =============================================================================
-- Core Sidecar Access Tests
-- =============================================================================

local function runSidecarAccessTests()
    print("\n=== Testing Sidecar Access Infrastructure ===")

    print("\n--- hasSidecarAccess / isAvailable / getDocumentPath ---")

    TestRunner:test("sidecar extractor: hasSidecarAccess returns true", function()
        local extractor = createSidecarExtractor()
        TestRunner:assertEquals(extractor:hasSidecarAccess(), true)
    end)

    TestRunner:test("sidecar extractor: isAvailable returns falsy (no open book)", function()
        local extractor = createSidecarExtractor()
        TestRunner:assert(not extractor:isAvailable(), "isAvailable should be falsy for sidecar")
    end)

    TestRunner:test("sidecar extractor: getDocumentPath returns document_path", function()
        local extractor = createSidecarExtractor({ document_path = "/my/book.epub" })
        TestRunner:assertEquals(extractor:getDocumentPath(), "/my/book.epub")
    end)

    TestRunner:test("open-book extractor: hasSidecarAccess returns false", function()
        local extractor = createOpenBookExtractor()
        TestRunner:assertEquals(extractor:hasSidecarAccess(), false)
    end)

    TestRunner:test("open-book extractor: isAvailable returns true", function()
        local extractor = createOpenBookExtractor()
        TestRunner:assertEquals(extractor:isAvailable(), true)
    end)

    TestRunner:test("open-book extractor: getDocumentPath returns ui.document.file", function()
        local extractor = createOpenBookExtractor()
        TestRunner:assertEquals(extractor:getDocumentPath(), "/test/books/sample.epub")
    end)

    TestRunner:test("nil extractor: both access methods return falsy", function()
        local extractor = ContextExtractor:new(nil, {})
        TestRunner:assert(not extractor:hasSidecarAccess(), "hasSidecarAccess should be falsy")
        TestRunner:assert(not extractor:isAvailable(), "isAvailable should be falsy")
        TestRunner:assertEquals(extractor:getDocumentPath(), nil)
    end)
end

-- =============================================================================
-- Static Sidecar Reader Tests
-- =============================================================================

local function runSidecarReaderTests()
    print("\n=== Testing Static Sidecar Readers ===")

    print("\n--- readSidecarAnnotations ---")

    TestRunner:test("readSidecarAnnotations returns annotations from sidecar", function()
        setupSidecarData({
            annotations = {
                { text = "Fear is the mind-killer", note = "Stoic philosophy" },
                { text = "Plans within plans" },
            },
        })
        local result = ContextExtractor.readSidecarAnnotations("/test/books/dune.epub")
        TestRunner:assertEquals(#result, 2)
        TestRunner:assertEquals(result[1].text, "Fear is the mind-killer")
    end)

    TestRunner:test("readSidecarAnnotations returns empty table for nil path", function()
        local result = ContextExtractor.readSidecarAnnotations(nil)
        TestRunner:assertEquals(#result, 0)
    end)

    TestRunner:test("readSidecarAnnotations returns empty table when no annotations setting", function()
        setupSidecarData({})  -- No annotations key
        local result = ContextExtractor.readSidecarAnnotations("/test/books/empty.epub")
        TestRunner:assertEquals(#result, 0)
    end)

    print("\n--- readSidecarProgress ---")

    TestRunner:test("readSidecarProgress returns formatted progress", function()
        setupSidecarData({ percent_finished = 0.72 })
        local result = ContextExtractor.readSidecarProgress("/test/books/dune.epub")
        TestRunner:assertEquals(result.decimal, 0.72)
        TestRunner:assertEquals(result.formatted, "72%")
    end)

    TestRunner:test("readSidecarProgress returns 0 for nil path", function()
        local result = ContextExtractor.readSidecarProgress(nil)
        TestRunner:assertEquals(result.decimal, 0)
        TestRunner:assertEquals(result.formatted, "")
    end)

    TestRunner:test("readSidecarProgress returns 0 when no progress stored", function()
        setupSidecarData({})
        local result = ContextExtractor.readSidecarProgress("/test/books/new.epub")
        TestRunner:assertEquals(result.decimal, 0)
        TestRunner:assertEquals(result.formatted, "0%")
    end)

    print("\n--- readSidecarNotebook ---")

    TestRunner:test("readSidecarNotebook returns notebook content", function()
        mock_notebook_content = "My notes about this book\n\nKey themes: identity, freedom"
        local result = ContextExtractor.readSidecarNotebook("/test/books/dune.epub")
        TestRunner:assertContains(result, "Key themes")
    end)

    TestRunner:test("readSidecarNotebook returns empty string for nil path", function()
        local result = ContextExtractor.readSidecarNotebook(nil)
        TestRunner:assertEquals(result, "")
    end)

    resetMocks()
end

-- =============================================================================
-- Sidecar Privacy Gating Tests (mirrors open-book gating)
-- =============================================================================

local function runSidecarGatingTests()
    print("\n=== Testing Sidecar Privacy Gating ===")

    -- Setup sidecar data that the extractor will read
    setupSidecarData({
        annotations = {
            { text = "Test highlight from chapter 1" },
            { text = "Annotated passage", note = "My note about this" },
        },
        percent_finished = 0.65,
    })
    mock_notebook_content = "My notebook notes about this book."

    -- =========================================================================
    -- Highlights Gating (sidecar)
    -- =========================================================================
    print("\n--- Sidecar: Highlights Double-Gate ---")

    TestRunner:test("sidecar highlights blocked when sharing disabled", function()
        local extractor = createSidecarExtractor({
            enable_highlights_sharing = false,
            enable_annotations_sharing = false,
        })
        local data = extractor:extractForAction({ use_highlights = true, prompt = "{highlights}" })
        TestRunner:assertEquals(data.highlights, "")
    end)

    TestRunner:test("sidecar highlights allowed when enable_highlights_sharing=true", function()
        local extractor = createSidecarExtractor({
            enable_highlights_sharing = true,
        })
        local data = extractor:extractForAction({ use_highlights = true, prompt = "{highlights}" })
        TestRunner:assertContains(data.highlights, "Test highlight")
    end)

    TestRunner:test("sidecar highlights allowed when enable_annotations_sharing=true (implies)", function()
        local extractor = createSidecarExtractor({
            enable_highlights_sharing = false,
            enable_annotations_sharing = true,
        })
        local data = extractor:extractForAction({ use_highlights = true, prompt = "{highlights}" })
        TestRunner:assertContains(data.highlights, "Test highlight")
    end)

    TestRunner:test("sidecar highlights blocked when use_highlights=false even with sharing on", function()
        local extractor = createSidecarExtractor({
            enable_highlights_sharing = true,
        })
        local data = extractor:extractForAction({ use_highlights = false, prompt = "{highlights}" })
        TestRunner:assertEquals(data.highlights, "")
    end)

    TestRunner:test("sidecar highlights bypass with trusted provider", function()
        local extractor = createSidecarExtractor({
            enable_highlights_sharing = false,
            enable_annotations_sharing = false,
            provider = "local_ollama",
            trusted_providers = { "local_ollama" },
        })
        local data = extractor:extractForAction({ use_highlights = true, prompt = "{highlights}" })
        TestRunner:assertContains(data.highlights, "Test highlight")
    end)

    -- =========================================================================
    -- Annotations Gating + Degradation (sidecar)
    -- =========================================================================
    print("\n--- Sidecar: Annotations Double-Gate + Degradation ---")

    TestRunner:test("sidecar annotations allowed when both gates pass", function()
        local extractor = createSidecarExtractor({
            enable_annotations_sharing = true,
        })
        local data = extractor:extractForAction({ use_annotations = true, prompt = "{annotations}" })
        TestRunner:assertContains(data.annotations, "My note about this")
        TestRunner:assertEquals(data._annotations_degraded, false)
    end)

    TestRunner:test("sidecar annotations blocked when sharing disabled", function()
        local extractor = createSidecarExtractor({
            enable_annotations_sharing = false,
            enable_highlights_sharing = false,
        })
        local data = extractor:extractForAction({ use_annotations = true, prompt = "{annotations}" })
        TestRunner:assertEquals(data.annotations, "")
    end)

    TestRunner:test("sidecar annotations degrade to highlights when annotations off but highlights on", function()
        local extractor = createSidecarExtractor({
            enable_highlights_sharing = true,
            enable_annotations_sharing = false,
        })
        local data = extractor:extractForAction({ use_annotations = true, prompt = "{annotations}" })
        -- Should get highlights data (degraded), not full annotations
        TestRunner:assertContains(data.annotations, "Test highlight")
        TestRunner:assertNotContains(data.annotations, "My note about this")
        TestRunner:assertEquals(data._annotations_degraded, true)
    end)

    TestRunner:test("sidecar annotations bypass with trusted provider", function()
        local extractor = createSidecarExtractor({
            enable_annotations_sharing = false,
            provider = "my_trusted",
            trusted_providers = { "my_trusted" },
        })
        local data = extractor:extractForAction({ use_annotations = true, prompt = "{annotations}" })
        TestRunner:assertContains(data.annotations, "My note about this")
        TestRunner:assertEquals(data._annotations_degraded, false)
    end)

    TestRunner:test("sidecar annotations still blocked when use_annotations=false with trusted provider", function()
        local extractor = createSidecarExtractor({
            enable_annotations_sharing = false,
            provider = "my_trusted",
            trusted_providers = { "my_trusted" },
        })
        local data = extractor:extractForAction({ use_annotations = false, prompt = "{annotations}" })
        TestRunner:assertEquals(data.annotations, "")
    end)

    -- =========================================================================
    -- Reading Progress (sidecar)
    -- =========================================================================
    print("\n--- Sidecar: Reading Progress Opt-Out ---")

    TestRunner:test("sidecar progress allowed by default (opt-out)", function()
        local extractor = createSidecarExtractor({})
        local data = extractor:extractForAction({})
        TestRunner:assertEquals(data.reading_progress, "65%")
        TestRunner:assertEquals(data.progress_decimal, "0.65")
    end)

    TestRunner:test("sidecar progress allowed when enable_progress_sharing=true", function()
        local extractor = createSidecarExtractor({ enable_progress_sharing = true })
        local data = extractor:extractForAction({})
        TestRunner:assertEquals(data.reading_progress, "65%")
    end)

    TestRunner:test("sidecar progress blocked when enable_progress_sharing=false", function()
        local extractor = createSidecarExtractor({ enable_progress_sharing = false })
        local data = extractor:extractForAction({})
        TestRunner:assertEquals(data.reading_progress, "")
        TestRunner:assertEquals(data.progress_decimal, "")
    end)

    TestRunner:test("sidecar progress bypass with trusted provider", function()
        local extractor = createSidecarExtractor({
            enable_progress_sharing = false,
            provider = "my_trusted",
            trusted_providers = { "my_trusted" },
        })
        local data = extractor:extractForAction({})
        TestRunner:assertEquals(data.reading_progress, "65%")
    end)

    -- =========================================================================
    -- Notebook (sidecar)
    -- =========================================================================
    print("\n--- Sidecar: Notebook Double-Gate ---")

    TestRunner:test("sidecar notebook blocked by default (opt-in)", function()
        local extractor = createSidecarExtractor({})
        local data = extractor:extractForAction({ use_notebook = true })
        TestRunner:assertEquals(data.notebook_content, "")
    end)

    TestRunner:test("sidecar notebook allowed when both gates pass", function()
        local extractor = createSidecarExtractor({
            enable_notebook_sharing = true,
        })
        local data = extractor:extractForAction({ use_notebook = true })
        TestRunner:assertContains(data.notebook_content, "notebook notes")
    end)

    TestRunner:test("sidecar notebook blocked when use_notebook=false", function()
        local extractor = createSidecarExtractor({
            enable_notebook_sharing = true,
        })
        local data = extractor:extractForAction({ use_notebook = false })
        TestRunner:assertEquals(data.notebook_content, nil)
    end)

    TestRunner:test("sidecar notebook bypass with trusted provider", function()
        local extractor = createSidecarExtractor({
            enable_notebook_sharing = false,
            provider = "local_ollama",
            trusted_providers = { "local_ollama" },
        })
        local data = extractor:extractForAction({ use_notebook = true })
        TestRunner:assertContains(data.notebook_content, "notebook notes")
    end)

    TestRunner:test("sidecar notebook still blocked when use_notebook=false with trusted provider", function()
        local extractor = createSidecarExtractor({
            enable_notebook_sharing = false,
            provider = "local_ollama",
            trusted_providers = { "local_ollama" },
        })
        local data = extractor:extractForAction({ use_notebook = false })
        TestRunner:assertEquals(data.notebook_content, nil)
    end)

    -- =========================================================================
    -- Caches via sidecar document_path
    -- =========================================================================
    print("\n--- Sidecar: Cache Access via document_path ---")

    TestRunner:test("sidecar xray_cache accessible via document_path", function()
        mock_cache_data.xray = {
            result = "X-Ray content from sidecar",
            progress_decimal = 0.5,
            used_book_text = true,
            used_highlights = false,
        }
        local extractor = createSidecarExtractor({
            enable_book_text_extraction = true,
        })
        local data = extractor:extractForAction({
            use_xray_cache = true,
            use_book_text = true,
        })
        TestRunner:assertContains(data.xray_cache, "X-Ray content from sidecar")
    end)

    TestRunner:test("sidecar xray_cache blocked when text extraction disabled", function()
        mock_cache_data.xray = {
            result = "X-Ray content",
            progress_decimal = 0.5,
            used_book_text = true,
        }
        local extractor = createSidecarExtractor({
            enable_book_text_extraction = false,
        })
        local data = extractor:extractForAction({
            use_xray_cache = true,
            use_book_text = true,
        })
        TestRunner:assertEquals(data.xray_cache, nil)
    end)

    TestRunner:test("sidecar xray_cache (used_book_text=false) allowed without text extraction", function()
        mock_cache_data.xray = {
            result = "AI-only X-Ray",
            progress_decimal = 0.3,
            used_book_text = false,
            used_highlights = false,
        }
        local extractor = createSidecarExtractor({
            enable_book_text_extraction = false,  -- OFF, but cache didn't use text
        })
        local data = extractor:extractForAction({
            use_xray_cache = true,
            use_book_text = true,
        })
        TestRunner:assertContains(data.xray_cache, "AI-only X-Ray")
    end)

    TestRunner:test("sidecar xray_cache (used_highlights=true) blocked when highlights disabled", function()
        mock_cache_data.xray = {
            result = "X-Ray with highlights",
            progress_decimal = 0.5,
            used_book_text = false,
            used_highlights = true,
        }
        local extractor = createSidecarExtractor({
            enable_book_text_extraction = false,
            enable_highlights_sharing = false,
            enable_annotations_sharing = false,
        })
        local data = extractor:extractForAction({
            use_xray_cache = true,
            use_highlights = true,
        })
        TestRunner:assertEquals(data.xray_cache, nil)
    end)

    TestRunner:test("sidecar summary_cache accessible via document_path", function()
        mock_cache_data.summary = {
            result = "Summary from sidecar",
            used_book_text = true,
        }
        local extractor = createSidecarExtractor({
            enable_book_text_extraction = true,
        })
        local data = extractor:extractForAction({
            use_summary_cache = true,
            use_book_text = true,
        })
        TestRunner:assertContains(data.summary_cache, "Summary from sidecar")
    end)

    TestRunner:test("sidecar analyze_cache accessible via document_path", function()
        mock_cache_data.analyze = {
            result = "Analysis from sidecar",
            used_book_text = false,
        }
        local extractor = createSidecarExtractor({
            enable_book_text_extraction = false,  -- OFF, but cache didn't use text
        })
        local data = extractor:extractForAction({
            use_analyze_cache = true,
            use_book_text = true,
        })
        TestRunner:assertContains(data.analyze_cache, "Analysis from sidecar")
    end)

    TestRunner:test("sidecar cache bypass with trusted provider", function()
        mock_cache_data.xray = {
            result = "Trusted X-Ray",
            progress_decimal = 0.7,
            used_book_text = true,
            used_highlights = true,
        }
        local extractor = createSidecarExtractor({
            enable_book_text_extraction = false,
            enable_highlights_sharing = false,
            provider = "local_ollama",
            trusted_providers = { "local_ollama" },
        })
        local data = extractor:extractForAction({
            use_xray_cache = true,
            use_book_text = true,
            use_highlights = true,
        })
        TestRunner:assertContains(data.xray_cache, "Trusted X-Ray")
    end)

    resetMocks()
end

-- =============================================================================
-- _unavailable_data tracking (sidecar context)
-- =============================================================================

local function runSidecarUnavailableDataTests()
    print("\n=== Testing Sidecar _unavailable_data Tracking ===")

    setupSidecarData({
        annotations = {},  -- Empty
        percent_finished = 0.5,
    })
    mock_notebook_content = ""

    print("\n--- Sidecar: _unavailable_data messages ---")

    TestRunner:test("sidecar _unavailable_data: 'highlights (sharing disabled)' when off", function()
        local extractor = createSidecarExtractor({
            enable_highlights_sharing = false,
            enable_annotations_sharing = false,
        })
        local data = extractor:extractForAction({ use_highlights = true, prompt = "{highlights_section}" })
        TestRunner:assert(data._unavailable_data, "should have _unavailable_data")
        local found = false
        for _idx, msg in ipairs(data._unavailable_data) do
            if msg:find("highlights (sharing disabled)", 1, true) then found = true end
        end
        TestRunner:assert(found, "should contain 'highlights (sharing disabled)'")
    end)

    TestRunner:test("sidecar _unavailable_data: 'annotations (sharing disabled)' when both off", function()
        local extractor = createSidecarExtractor({
            enable_highlights_sharing = false,
            enable_annotations_sharing = false,
        })
        local data = extractor:extractForAction({ use_annotations = true, prompt = "{annotations_section}" })
        TestRunner:assert(data._unavailable_data, "should have _unavailable_data")
        local found = false
        for _idx, msg in ipairs(data._unavailable_data) do
            if msg:find("annotations (sharing disabled)", 1, true) then found = true end
        end
        TestRunner:assert(found, "should contain 'annotations (sharing disabled)'")
    end)

    TestRunner:test("sidecar _unavailable_data: 'annotations (using highlights only)' when degraded", function()
        setupSidecarData({
            annotations = {
                { text = "Some highlight" },
            },
            percent_finished = 0.5,
        })
        local extractor = createSidecarExtractor({
            enable_highlights_sharing = true,
            enable_annotations_sharing = false,
        })
        local data = extractor:extractForAction({ use_annotations = true, prompt = "{annotations_section}" })
        TestRunner:assert(data._unavailable_data, "should have _unavailable_data")
        local found = false
        for _idx, msg in ipairs(data._unavailable_data) do
            if msg:find("annotations (using highlights only)", 1, true) then found = true end
        end
        TestRunner:assert(found, "should contain 'annotations (using highlights only)'")
    end)

    TestRunner:test("sidecar _unavailable_data: 'notebook (sharing disabled)' when off", function()
        local extractor = createSidecarExtractor({})  -- default: notebook sharing off
        local data = extractor:extractForAction({ use_notebook = true })
        TestRunner:assert(data._unavailable_data, "should have _unavailable_data")
        local found = false
        for _idx, msg in ipairs(data._unavailable_data) do
            if msg:find("notebook (sharing disabled)", 1, true) then found = true end
        end
        TestRunner:assert(found, "should contain 'notebook (sharing disabled)'")
    end)

    TestRunner:test("sidecar _unavailable_data: no progress entry when sharing enabled (opt-out)", function()
        local extractor = createSidecarExtractor({})  -- default: progress sharing on
        local data = extractor:extractForAction({})
        if data._unavailable_data then
            for _idx, msg in ipairs(data._unavailable_data) do
                TestRunner:assert(not msg:find("progress", 1, true),
                    "should not have progress unavailable entry: " .. msg)
            end
        end
    end)

    TestRunner:test("sidecar _unavailable_data: highlights (none found) when allowed but empty", function()
        setupSidecarData({ annotations = {} })  -- No highlights in sidecar
        local extractor = createSidecarExtractor({
            enable_highlights_sharing = true,
        })
        local data = extractor:extractForAction({ use_highlights = true, prompt = "{highlights_section}" })
        TestRunner:assert(data._unavailable_data, "should have _unavailable_data")
        local found = false
        for _idx, msg in ipairs(data._unavailable_data) do
            if msg:find("highlights (none found)", 1, true) then found = true end
        end
        TestRunner:assert(found, "should contain 'highlights (none found)'")
    end)

    resetMocks()
end

-- =============================================================================
-- LIVE_BOOK_FLAGS vs SIDECAR_FLAGS Classification
-- =============================================================================

local function runFlagClassificationTests()
    print("\n=== Testing Flag Classification (LIVE vs SIDECAR) ===")

    print("\n--- LIVE_BOOK_FLAGS require open book ---")

    TestRunner:test("use_book_text is a LIVE flag", function()
        local found = false
        for _idx, flag in ipairs(Actions.LIVE_BOOK_FLAGS) do
            if flag == "use_book_text" then found = true end
        end
        TestRunner:assert(found, "use_book_text should be in LIVE_BOOK_FLAGS")
    end)

    TestRunner:test("use_page_text is a LIVE flag", function()
        local found = false
        for _idx, flag in ipairs(Actions.LIVE_BOOK_FLAGS) do
            if flag == "use_page_text" then found = true end
        end
        TestRunner:assert(found, "use_page_text should be in LIVE_BOOK_FLAGS")
    end)

    TestRunner:test("use_reading_stats is a LIVE flag", function()
        local found = false
        for _idx, flag in ipairs(Actions.LIVE_BOOK_FLAGS) do
            if flag == "use_reading_stats" then found = true end
        end
        TestRunner:assert(found, "use_reading_stats should be in LIVE_BOOK_FLAGS")
    end)

    print("\n--- SIDECAR_FLAGS do not require open book ---")

    TestRunner:test("use_highlights is a SIDECAR flag", function()
        local found = false
        for _idx, flag in ipairs(Actions.SIDECAR_FLAGS) do
            if flag == "use_highlights" then found = true end
        end
        TestRunner:assert(found, "use_highlights should be in SIDECAR_FLAGS")
    end)

    TestRunner:test("use_annotations is a SIDECAR flag", function()
        local found = false
        for _idx, flag in ipairs(Actions.SIDECAR_FLAGS) do
            if flag == "use_annotations" then found = true end
        end
        TestRunner:assert(found, "use_annotations should be in SIDECAR_FLAGS")
    end)

    TestRunner:test("use_notebook is a SIDECAR flag", function()
        local found = false
        for _idx, flag in ipairs(Actions.SIDECAR_FLAGS) do
            if flag == "use_notebook" then found = true end
        end
        TestRunner:assert(found, "use_notebook should be in SIDECAR_FLAGS")
    end)

    print("\n--- SIDECAR flags NOT in LIVE flags ---")

    TestRunner:test("no SIDECAR flag appears in LIVE_BOOK_FLAGS", function()
        local live_set = {}
        for _idx, flag in ipairs(Actions.LIVE_BOOK_FLAGS) do
            live_set[flag] = true
        end
        for _idx, flag in ipairs(Actions.SIDECAR_FLAGS) do
            TestRunner:assert(not live_set[flag],
                flag .. " should not be in both LIVE and SIDECAR")
        end
    end)

    print("\n--- requiresOpenBook: SIDECAR-only actions ---")

    TestRunner:test("action with only use_highlights does not require open book", function()
        TestRunner:assertEquals(Actions.requiresOpenBook({ use_highlights = true }), false)
    end)

    TestRunner:test("action with only use_annotations does not require open book", function()
        TestRunner:assertEquals(Actions.requiresOpenBook({ use_annotations = true }), false)
    end)

    TestRunner:test("action with only use_notebook does not require open book", function()
        TestRunner:assertEquals(Actions.requiresOpenBook({ use_notebook = true }), false)
    end)

    TestRunner:test("action with only use_reading_progress does not require open book", function()
        TestRunner:assertEquals(Actions.requiresOpenBook({ use_reading_progress = true }), false)
    end)

    TestRunner:test("action with highlights + annotations + notebook does not require open book", function()
        TestRunner:assertEquals(Actions.requiresOpenBook({
            use_highlights = true,
            use_annotations = true,
            use_notebook = true,
            use_reading_progress = true,
        }), false)
    end)

    print("\n--- requiresOpenBook: mixed LIVE + SIDECAR ---")

    TestRunner:test("action with use_highlights + use_book_text requires open book", function()
        TestRunner:assertEquals(Actions.requiresOpenBook({
            use_highlights = true,
            use_book_text = true,
        }), true)
    end)

    TestRunner:test("action with use_annotations + use_reading_stats requires open book", function()
        TestRunner:assertEquals(Actions.requiresOpenBook({
            use_annotations = true,
            use_reading_stats = true,
        }), true)
    end)

    TestRunner:test("source_selection forces open book regardless of sidecar flags", function()
        TestRunner:assertEquals(Actions.requiresOpenBook({
            use_highlights = true,
            source_selection = true,
        }), true)
    end)
end

-- =============================================================================
-- LIVE_BOOK_FLAGS produce empty results in sidecar mode
-- =============================================================================

local function runSidecarLiveFlagTests()
    print("\n=== Testing LIVE Flags in Sidecar Mode (should be empty) ===")

    setupSidecarData({
        annotations = { { text = "A highlight" } },
        percent_finished = 0.5,
    })

    print("\n--- LIVE flags return empty in sidecar context ---")

    TestRunner:test("sidecar: book_text is empty (no open book)", function()
        local extractor = createSidecarExtractor({
            enable_book_text_extraction = true,
        })
        local data = extractor:extractForAction({
            use_book_text = true,
            prompt = "{book_text}",
        })
        -- No open book means extraction returns empty string (not nil)
        TestRunner:assertEquals(data.book_text, "")
    end)

    TestRunner:test("sidecar: full_document is empty (no open book)", function()
        local extractor = createSidecarExtractor({
            enable_book_text_extraction = true,
        })
        local data = extractor:extractForAction({
            use_book_text = true,
            prompt = "{full_document}",
        })
        TestRunner:assertEquals(data.full_document, "")
    end)

    TestRunner:test("sidecar: page_text is empty (no open book)", function()
        local extractor = createSidecarExtractor({})
        local data = extractor:extractForAction({
            prompt = "{page_text}",
        })
        TestRunner:assertEquals(data.page_text, "")
    end)

    TestRunner:test("sidecar: reading_stats returns fallback values (no open book)", function()
        local extractor = createSidecarExtractor({})
        local data = extractor:extractForAction({})
        -- Stats module unavailable in sidecar → fallback values
        TestRunner:assert(data.chapter_title ~= nil, "chapter_title should be set")
        TestRunner:assert(data.chapters_read ~= nil, "chapters_read should be set")
    end)

    TestRunner:test("sidecar: highlights ARE extracted (sidecar flag, not live)", function()
        local extractor = createSidecarExtractor({
            enable_highlights_sharing = true,
        })
        local data = extractor:extractForAction({
            use_highlights = true,
            prompt = "{highlights}",
        })
        TestRunner:assertContains(data.highlights, "A highlight")
    end)

    TestRunner:test("sidecar: progress IS available (sidecar fallback)", function()
        local extractor = createSidecarExtractor({})
        local data = extractor:extractForAction({})
        TestRunner:assertEquals(data.reading_progress, "50%")
    end)

    resetMocks()
end

-- =============================================================================
-- Built-in action eligibility for file browser
-- =============================================================================

local function runFileBrowserEligibilityTests()
    print("\n=== Testing Built-in Action File Browser Eligibility ===")

    print("\n--- Actions that should NOT require open book ---")

    -- These are key sidecar-eligible actions
    local sidecar_eligible = {
        "analyze_highlights",  -- use_highlights + use_annotations + use_notebook
        "connect_with_notes",  -- use_annotations + use_notebook
        "book_reviews",        -- no open-book flags (AI knowledge only)
        "book_info",           -- no open-book flags
        "similar_books",       -- no open-book flags
    }

    for _idx, action_id in ipairs(sidecar_eligible) do
        TestRunner:test(action_id .. " does not require open book", function()
            local action = Actions.getById(action_id)
            if action then
                TestRunner:assertEquals(Actions.requiresOpenBook(action), false,
                    action_id .. " should be eligible for file browser")
            end
            -- Skip silently if action doesn't exist (custom action)
        end)
    end

    print("\n--- Actions that SHOULD require open book ---")

    local requires_open = {
        "xray",          -- source_selection + use_book_text
        "recap",         -- source_selection + use_book_text
        "analyze",       -- source_selection
    }

    for _idx, action_id in ipairs(requires_open) do
        TestRunner:test(action_id .. " requires open book", function()
            local action = Actions.getById(action_id)
            if action then
                TestRunner:assertEquals(Actions.requiresOpenBook(action), true,
                    action_id .. " should require open book")
            end
        end)
    end
end

-- =============================================================================
-- Run all tests
-- =============================================================================

local function runAll()
    print("\n=== Testing Sidecar Data Access and Privacy Gating ===")

    runSidecarAccessTests()
    runSidecarReaderTests()
    runSidecarGatingTests()
    runSidecarUnavailableDataTests()
    runFlagClassificationTests()
    runSidecarLiveFlagTests()
    runFileBrowserEligibilityTests()

    print(string.format("\n=== Results: %d passed, %d failed ===\n", TestRunner.passed, TestRunner.failed))

    -- Restore original modules
    if original_docsettings then
        package.loaded["docsettings"] = original_docsettings
    end
    if original_notebook then
        package.loaded["koassistant_notebook"] = original_notebook
    end
    if original_action_cache then
        package.loaded["koassistant_action_cache"] = original_action_cache
    end

    return TestRunner.failed == 0
end

-- Run tests if executed directly
if arg and arg[0] and arg[0]:match("test_sidecar_gating%.lua$") then
    local success = runAll()
    os.exit(success and 0 or 1)
end

return {
    runAll = runAll,
    TestRunner = TestRunner,
}
