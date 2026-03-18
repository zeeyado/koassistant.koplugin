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

    TestRunner:test("sidecar progress allowed when enable_basic_stats=true", function()
        local extractor = createSidecarExtractor({ enable_basic_stats = true })
        local data = extractor:extractForAction({})
        TestRunner:assertEquals(data.reading_progress, "65%")
    end)

    TestRunner:test("sidecar progress blocked when enable_basic_stats=false", function()
        local extractor = createSidecarExtractor({ enable_basic_stats = false })
        local data = extractor:extractForAction({})
        TestRunner:assertEquals(data.reading_progress, "")
        TestRunner:assertEquals(data.progress_decimal, "")
    end)

    TestRunner:test("sidecar progress bypass with trusted provider", function()
        local extractor = createSidecarExtractor({
            enable_basic_stats = false,
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
-- PARITY: Open-book vs Sidecar extraction must produce identical gating
-- =============================================================================

local function runParityTests()
    print("\n=== Testing Open-Book vs Sidecar Gating PARITY ===")

    -- Both modes read from the same sidecar data source in tests
    -- (open-book mock reads from mock_sidecar_data.annotations too)
    setupSidecarData({
        annotations = {
            { text = "A highlighted passage", note = "My personal note" },
            { text = "Another highlight without note" },
        },
        percent_finished = 0.42,
    })
    mock_notebook_content = "Reader's notebook entry about themes."

    --- Helper: run extractForAction on both modes, return both results
    local function extractBoth(settings, action)
        local sidecar = createSidecarExtractor(settings)
        local open_book = createOpenBookExtractor(settings)
        local sidecar_data = sidecar:extractForAction(action)
        local open_book_data = open_book:extractForAction(action)
        return sidecar_data, open_book_data
    end

    -- =========================================================================
    -- Highlights parity
    -- =========================================================================
    print("\n--- Parity: Highlights ---")

    TestRunner:test("PARITY: highlights blocked in both when sharing OFF", function()
        local s, o = extractBoth(
            { enable_highlights_sharing = false, enable_annotations_sharing = false },
            { use_highlights = true, prompt = "{highlights}" })
        TestRunner:assertEquals(s.highlights, "", "sidecar highlights should be empty")
        TestRunner:assertEquals(o.highlights, "", "open-book highlights should be empty")
    end)

    TestRunner:test("PARITY: highlights allowed in both when sharing ON", function()
        local s, o = extractBoth(
            { enable_highlights_sharing = true },
            { use_highlights = true, prompt = "{highlights}" })
        TestRunner:assertContains(s.highlights, "highlighted passage", "sidecar should have highlights")
        TestRunner:assertContains(o.highlights, "highlighted passage", "open-book should have highlights")
    end)

    TestRunner:test("PARITY: highlights allowed via annotations_sharing in both", function()
        local s, o = extractBoth(
            { enable_highlights_sharing = false, enable_annotations_sharing = true },
            { use_highlights = true, prompt = "{highlights}" })
        TestRunner:assertContains(s.highlights, "highlighted passage", "sidecar should have highlights via annotations")
        TestRunner:assertContains(o.highlights, "highlighted passage", "open-book should have highlights via annotations")
    end)

    TestRunner:test("PARITY: per-action flag blocks in both", function()
        local s, o = extractBoth(
            { enable_highlights_sharing = true },
            { use_highlights = false, prompt = "{highlights}" })
        TestRunner:assertEquals(s.highlights, "", "sidecar highlights should be empty (flag off)")
        TestRunner:assertEquals(o.highlights, "", "open-book highlights should be empty (flag off)")
    end)

    -- =========================================================================
    -- Annotations parity (including degradation)
    -- =========================================================================
    print("\n--- Parity: Annotations + Degradation ---")

    TestRunner:test("PARITY: annotations full in both when annotations_sharing ON", function()
        local s, o = extractBoth(
            { enable_annotations_sharing = true },
            { use_annotations = true, prompt = "{annotations}" })
        TestRunner:assertContains(s.annotations, "My personal note", "sidecar should have full annotations")
        TestRunner:assertContains(o.annotations, "My personal note", "open-book should have full annotations")
        TestRunner:assertEquals(s._annotations_degraded, false)
        TestRunner:assertEquals(o._annotations_degraded, false)
    end)

    TestRunner:test("PARITY: annotations degrade to highlights in both when annotations OFF but highlights ON", function()
        local s, o = extractBoth(
            { enable_highlights_sharing = true, enable_annotations_sharing = false },
            { use_annotations = true, prompt = "{annotations}" })
        -- Both should degrade: have highlight text but NOT the note
        TestRunner:assertContains(s.annotations, "highlighted passage", "sidecar should have degraded highlights")
        TestRunner:assertNotContains(s.annotations, "My personal note", "sidecar should NOT have notes")
        TestRunner:assertContains(o.annotations, "highlighted passage", "open-book should have degraded highlights")
        TestRunner:assertNotContains(o.annotations, "My personal note", "open-book should NOT have notes")
        TestRunner:assertEquals(s._annotations_degraded, true)
        TestRunner:assertEquals(o._annotations_degraded, true)
    end)

    TestRunner:test("PARITY: annotations blocked in both when both sharing OFF", function()
        local s, o = extractBoth(
            { enable_highlights_sharing = false, enable_annotations_sharing = false },
            { use_annotations = true, prompt = "{annotations}" })
        TestRunner:assertEquals(s.annotations, "", "sidecar annotations should be empty")
        TestRunner:assertEquals(o.annotations, "", "open-book annotations should be empty")
    end)

    TestRunner:test("PARITY: annotations blocked when use_annotations=false, even trusted", function()
        local s, o = extractBoth(
            { enable_annotations_sharing = false, provider = "local_ollama", trusted_providers = { "local_ollama" } },
            { use_annotations = false, prompt = "{annotations}" })
        TestRunner:assertEquals(s.annotations, "", "sidecar per-action gate should block")
        TestRunner:assertEquals(o.annotations, "", "open-book per-action gate should block")
    end)

    -- =========================================================================
    -- Notebook parity
    -- =========================================================================
    print("\n--- Parity: Notebook ---")

    TestRunner:test("PARITY: notebook blocked in both when sharing OFF (opt-in default)", function()
        local s, o = extractBoth(
            {},  -- enable_notebook_sharing defaults to nil/false
            { use_notebook = true })
        TestRunner:assertEquals(s.notebook_content, "", "sidecar notebook should be empty")
        TestRunner:assertEquals(o.notebook_content, "", "open-book notebook should be empty")
    end)

    TestRunner:test("PARITY: notebook allowed in both when sharing ON + flag ON", function()
        local s, o = extractBoth(
            { enable_notebook_sharing = true },
            { use_notebook = true })
        TestRunner:assertContains(s.notebook_content, "themes", "sidecar notebook should have content")
        TestRunner:assertContains(o.notebook_content, "themes", "open-book notebook should have content")
    end)

    TestRunner:test("PARITY: notebook blocked when use_notebook=false, even with sharing ON", function()
        local s, o = extractBoth(
            { enable_notebook_sharing = true },
            { use_notebook = false })
        TestRunner:assertEquals(s.notebook_content, nil, "sidecar: flag off → nil (not requested)")
        TestRunner:assertEquals(o.notebook_content, nil, "open-book: flag off → nil (not requested)")
    end)

    -- =========================================================================
    -- Trusted provider parity
    -- =========================================================================
    print("\n--- Parity: Trusted Provider Bypass ---")

    TestRunner:test("PARITY: trusted provider bypasses ALL privacy gates in both modes", function()
        local settings = {
            enable_highlights_sharing = false,
            enable_annotations_sharing = false,
            enable_notebook_sharing = false,
            enable_basic_stats = false,
            provider = "trusted_one",
            trusted_providers = { "trusted_one" },
        }
        local s, o = extractBoth(settings, {
            use_highlights = true, use_annotations = true, use_notebook = true,
            prompt = "{highlights}{annotations}",
        })
        -- All data should be available in both modes
        TestRunner:assertContains(s.highlights, "highlighted passage", "sidecar: trusted bypasses highlights gate")
        TestRunner:assertContains(o.highlights, "highlighted passage", "open-book: trusted bypasses highlights gate")
        TestRunner:assertContains(s.annotations, "My personal note", "sidecar: trusted bypasses annotations gate")
        TestRunner:assertContains(o.annotations, "My personal note", "open-book: trusted bypasses annotations gate")
        TestRunner:assertContains(s.notebook_content, "themes", "sidecar: trusted bypasses notebook gate")
        TestRunner:assertContains(o.notebook_content, "themes", "open-book: trusted bypasses notebook gate")
        -- Progress: sidecar reads from DocSettings, open-book computes from live document
        -- Both should be non-empty (gate passed), but values differ by data source
        TestRunner:assertEquals(s.reading_progress, "42%", "sidecar: trusted bypasses progress gate")
        TestRunner:assert(o.reading_progress ~= nil and o.reading_progress ~= "",
            "open-book: trusted bypasses progress gate (value from live doc)")
    end)

    TestRunner:test("PARITY: trusted bypass does NOT override per-action flags", function()
        local settings = {
            enable_highlights_sharing = false,
            provider = "trusted_one",
            trusted_providers = { "trusted_one" },
        }
        local s, o = extractBoth(settings, {
            use_highlights = false, use_annotations = false,
            prompt = "{highlights}{annotations}",
        })
        TestRunner:assertEquals(s.highlights, "", "sidecar: per-action flag still blocks")
        TestRunner:assertEquals(o.highlights, "", "open-book: per-action flag still blocks")
    end)

    -- =========================================================================
    -- _unavailable_data parity
    -- =========================================================================
    print("\n--- Parity: _unavailable_data messages ---")

    TestRunner:test("PARITY: same _unavailable_data for highlights disabled", function()
        local s, o = extractBoth(
            { enable_highlights_sharing = false, enable_annotations_sharing = false },
            { use_highlights = true, prompt = "{highlights_section}" })
        TestRunner:assert(s._unavailable_data, "sidecar should have _unavailable_data")
        TestRunner:assert(o._unavailable_data, "open-book should have _unavailable_data")
        -- Check same message appears in both
        local s_msg, o_msg = table.concat(s._unavailable_data, "; "), table.concat(o._unavailable_data, "; ")
        TestRunner:assertContains(s_msg, "highlights (sharing disabled)")
        TestRunner:assertContains(o_msg, "highlights (sharing disabled)")
    end)

    TestRunner:test("PARITY: same _unavailable_data for degraded annotations", function()
        setupSidecarData({
            annotations = { { text = "A highlight" } },
            percent_finished = 0.42,
        })
        local s, o = extractBoth(
            { enable_highlights_sharing = true, enable_annotations_sharing = false },
            { use_annotations = true, prompt = "{annotations_section}" })
        TestRunner:assert(s._unavailable_data, "sidecar should have _unavailable_data")
        TestRunner:assert(o._unavailable_data, "open-book should have _unavailable_data")
        local s_msg, o_msg = table.concat(s._unavailable_data, "; "), table.concat(o._unavailable_data, "; ")
        TestRunner:assertContains(s_msg, "annotations (using highlights only)")
        TestRunner:assertContains(o_msg, "annotations (using highlights only)")
    end)

    TestRunner:test("PARITY: same _unavailable_data for notebook disabled", function()
        local s, o = extractBoth(
            {},  -- notebook defaults off
            { use_notebook = true })
        TestRunner:assert(s._unavailable_data, "sidecar should have _unavailable_data")
        TestRunner:assert(o._unavailable_data, "open-book should have _unavailable_data")
        local s_msg, o_msg = table.concat(s._unavailable_data, "; "), table.concat(o._unavailable_data, "; ")
        TestRunner:assertContains(s_msg, "notebook (sharing disabled)")
        TestRunner:assertContains(o_msg, "notebook (sharing disabled)")
    end)

    TestRunner:test("PARITY: no _unavailable_data when all permissions granted", function()
        setupSidecarData({
            annotations = { { text = "A highlight", note = "A note" } },
            percent_finished = 0.5,
        })
        mock_notebook_content = "Notebook content here"
        local s, o = extractBoth(
            { enable_highlights_sharing = true, enable_annotations_sharing = true, enable_notebook_sharing = true },
            { use_highlights = true, use_annotations = true, use_notebook = true, prompt = "{highlights}{annotations}" })
        -- Neither should have any unavailable data
        TestRunner:assertEquals(s._unavailable_data, nil, "sidecar: no unavailable data when all enabled")
        TestRunner:assertEquals(o._unavailable_data, nil, "open-book: no unavailable data when all enabled")
    end)

    resetMocks()
end

-- =============================================================================
-- Real action definitions: test actual built-in actions
-- =============================================================================

local function runRealActionTests()
    print("\n=== Testing Real Action Definitions with Sidecar ===")

    setupSidecarData({
        annotations = {
            { text = "The desert is vast and patient", note = "Recurring motif" },
            { text = "Power attracts the corruptible" },
        },
        percent_finished = 0.72,
    })
    mock_notebook_content = "Themes: ecology, power dynamics, religion"

    local real_actions = {
        { id = "analyze_highlights", desc = "Analyze Notes" },
        { id = "xray_simple", desc = "X-Ray Simple" },
    }

    for _idx, test_def in ipairs(real_actions) do
        local action = Actions.getById(test_def.id)
        if not action then
            TestRunner:test(test_def.desc .. " - SKIP (action not found)", function() end)
        else
            print("\n--- Real action: " .. test_def.desc .. " (" .. test_def.id .. ") ---")

            -- Verify it doesn't require open book (eligible for file browser)
            TestRunner:test(test_def.desc .. ": eligible for file browser", function()
                TestRunner:assertEquals(Actions.requiresOpenBook(action), false,
                    test_def.id .. " should not require open book")
            end)

            -- Test with highlights enabled: should extract highlights
            if action.use_highlights then
                TestRunner:test(test_def.desc .. ": sidecar extracts highlights when sharing ON", function()
                    local extractor = createSidecarExtractor({
                        enable_highlights_sharing = true,
                    })
                    local data = extractor:extractForAction(action)
                    TestRunner:assertContains(data.highlights, "desert",
                        test_def.id .. " should get highlights from sidecar")
                end)

                TestRunner:test(test_def.desc .. ": sidecar highlights empty when sharing OFF", function()
                    local extractor = createSidecarExtractor({
                        enable_highlights_sharing = false,
                        enable_annotations_sharing = false,
                    })
                    local data = extractor:extractForAction(action)
                    TestRunner:assertEquals(data.highlights, "",
                        test_def.id .. " highlights should be empty when sharing off")
                end)

                -- KEY TEST: annotations_sharing implies highlights access
                TestRunner:test(test_def.desc .. ": annotations_sharing=true grants highlight access (implied)", function()
                    local extractor = createSidecarExtractor({
                        enable_highlights_sharing = false,
                        enable_annotations_sharing = true,
                    })
                    local data = extractor:extractForAction(action)
                    TestRunner:assertContains(data.highlights, "desert",
                        test_def.id .. " should get highlights via annotations_sharing implication")
                end)
            end

            -- Test annotations if action uses them
            if action.use_annotations then
                TestRunner:test(test_def.desc .. ": sidecar extracts full annotations when sharing ON", function()
                    local extractor = createSidecarExtractor({
                        enable_annotations_sharing = true,
                    })
                    local data = extractor:extractForAction(action)
                    TestRunner:assertContains(data.annotations, "Recurring motif",
                        test_def.id .. " should get full annotations")
                    TestRunner:assertEquals(data._annotations_degraded, false)
                end)

                TestRunner:test(test_def.desc .. ": sidecar degrades annotations when only highlights ON", function()
                    local extractor = createSidecarExtractor({
                        enable_highlights_sharing = true,
                        enable_annotations_sharing = false,
                    })
                    local data = extractor:extractForAction(action)
                    TestRunner:assertContains(data.annotations, "desert",
                        test_def.id .. " should get degraded highlights-only")
                    TestRunner:assertNotContains(data.annotations, "Recurring motif",
                        test_def.id .. " should NOT have note in degraded mode")
                    TestRunner:assertEquals(data._annotations_degraded, true)
                end)
            end

            -- Test notebook if action uses it
            if action.use_notebook then
                TestRunner:test(test_def.desc .. ": sidecar extracts notebook when sharing ON", function()
                    local extractor = createSidecarExtractor({
                        enable_notebook_sharing = true,
                    })
                    local data = extractor:extractForAction(action)
                    TestRunner:assertContains(data.notebook_content, "ecology",
                        test_def.id .. " should get notebook from sidecar")
                end)
            end

            -- Test progress if action uses it
            if action.use_reading_progress then
                TestRunner:test(test_def.desc .. ": sidecar extracts progress", function()
                    local extractor = createSidecarExtractor({})
                    local data = extractor:extractForAction(action)
                    TestRunner:assertEquals(data.reading_progress, "72%",
                        test_def.id .. " should get progress from sidecar")
                end)
            end

            -- PARITY: compare open-book vs sidecar with full permissions
            TestRunner:test(test_def.desc .. ": PARITY open-book vs sidecar (all enabled)", function()
                local settings = {
                    enable_highlights_sharing = true,
                    enable_annotations_sharing = true,
                    enable_notebook_sharing = true,
                }
                local sidecar_ext = createSidecarExtractor(settings)
                local open_book_ext = createOpenBookExtractor(settings)
                local s = sidecar_ext:extractForAction(action)
                local o = open_book_ext:extractForAction(action)
                -- Compare gating outcomes (both should have data or both empty)
                if action.use_highlights then
                    TestRunner:assert(
                        (s.highlights ~= "") == (o.highlights ~= ""),
                        test_def.id .. ": highlights gating mismatch (sidecar=" ..
                            (#(s.highlights or "")) .. " vs open=" .. (#(o.highlights or "")) .. ")")
                end
                if action.use_annotations then
                    TestRunner:assert(
                        (s.annotations ~= "") == (o.annotations ~= ""),
                        test_def.id .. ": annotations gating mismatch")
                    TestRunner:assertEquals(s._annotations_degraded, o._annotations_degraded,
                        test_def.id .. ": degradation state mismatch")
                end
                if action.use_notebook then
                    TestRunner:assert(
                        (s.notebook_content ~= "") == (o.notebook_content ~= ""),
                        test_def.id .. ": notebook gating mismatch")
                end
            end)

            -- PARITY: compare open-book vs sidecar with minimal permissions
            TestRunner:test(test_def.desc .. ": PARITY open-book vs sidecar (all disabled)", function()
                local settings = {
                    enable_highlights_sharing = false,
                    enable_annotations_sharing = false,
                    enable_notebook_sharing = false,
                    enable_basic_stats = false,
                }
                local sidecar_ext = createSidecarExtractor(settings)
                local open_book_ext = createOpenBookExtractor(settings)
                local s = sidecar_ext:extractForAction(action)
                local o = open_book_ext:extractForAction(action)
                if action.use_highlights then
                    TestRunner:assertEquals(s.highlights, o.highlights,
                        test_def.id .. ": highlights should match when both disabled")
                end
                if action.use_annotations then
                    TestRunner:assertEquals(s.annotations, o.annotations,
                        test_def.id .. ": annotations should match when both disabled")
                end
                if action.use_notebook then
                    TestRunner:assertEquals(s.notebook_content, o.notebook_content,
                        test_def.id .. ": notebook should match when both disabled")
                end
                TestRunner:assertEquals(s.reading_progress, o.reading_progress,
                    test_def.id .. ": progress should match when both disabled")
            end)
        end
    end

    -- =========================================================================
    -- Test annotations-implies-highlights for all highlight-requiring actions
    -- =========================================================================
    print("\n--- Annotations-implies-highlights for requires={\"highlights\"} actions ---")

    local highlight_requiring = {}
    for _idx2, id in ipairs({"analyze_highlights", "connect_with_notes"}) do
        local a = Actions.getById(id)
        if a and a.requires then
            for _idx3, req in ipairs(a.requires) do
                if req == "highlights" then
                    table.insert(highlight_requiring, { id = id, action = a })
                end
            end
        end
    end

    for _idx, entry in ipairs(highlight_requiring) do
        -- Scenario: only annotations_sharing is ON, highlights_sharing is OFF
        -- The annotation-implies-highlights rule should still allow data extraction
        TestRunner:test(entry.id .. ": annotations_sharing=true is sufficient for requires={highlights}", function()
            local extractor = createSidecarExtractor({
                enable_highlights_sharing = false,
                enable_annotations_sharing = true,
            })
            local data = extractor:extractForAction(entry.action)
            -- Should have data through the implication chain
            local has_data = (data.highlights and data.highlights ~= "")
                or (data.annotations and data.annotations ~= "")
            TestRunner:assert(has_data,
                entry.id .. " should have highlight/annotation data when annotations_sharing=true")
        end)

        -- Scenario: only highlights_sharing ON — should work since requires={"highlights"}
        -- checks enable_highlights_sharing OR enable_annotations_sharing
        TestRunner:test(entry.id .. ": highlights_sharing=true is sufficient for requires={highlights}", function()
            local extractor = createSidecarExtractor({
                enable_highlights_sharing = true,
                enable_annotations_sharing = false,
            })
            local data = extractor:extractForAction(entry.action)
            local has_data = (data.highlights and data.highlights ~= "")
                or (data.annotations and data.annotations ~= "")
            TestRunner:assert(has_data,
                entry.id .. " should have data when highlights_sharing=true")
        end)
    end

    resetMocks()
end

-- =============================================================================
-- Edge cases: nil vs false vs true settings
-- =============================================================================

local function runEdgeCaseTests()
    print("\n=== Testing Edge Cases (nil/false/true setting values) ===")

    setupSidecarData({
        annotations = { { text = "A highlight" } },
        percent_finished = 0.5,
    })
    mock_notebook_content = "Notebook content"

    -- =========================================================================
    -- nil setting behavior
    -- =========================================================================
    print("\n--- nil setting behavior ---")

    TestRunner:test("enable_highlights_sharing=nil → blocked (opt-in, default false)", function()
        local extractor = createSidecarExtractor({})  -- nil, not explicitly false
        local data = extractor:extractForAction({ use_highlights = true, prompt = "{highlights}" })
        TestRunner:assertEquals(data.highlights, "", "nil should behave like false for opt-in setting")
    end)

    TestRunner:test("enable_annotations_sharing=nil → blocked (opt-in, default false)", function()
        local extractor = createSidecarExtractor({})
        local data = extractor:extractForAction({ use_annotations = true, prompt = "{annotations}" })
        TestRunner:assertEquals(data.annotations, "", "nil should behave like false for opt-in setting")
    end)

    TestRunner:test("enable_notebook_sharing=nil → blocked (opt-in, default false)", function()
        local extractor = createSidecarExtractor({})
        local data = extractor:extractForAction({ use_notebook = true })
        TestRunner:assertEquals(data.notebook_content, "", "nil should behave like false for opt-in setting")
    end)

    TestRunner:test("enable_basic_stats=nil → allowed (opt-out, default true)", function()
        local extractor = createSidecarExtractor({})  -- nil = default enabled
        local data = extractor:extractForAction({})
        TestRunner:assertEquals(data.reading_progress, "50%", "nil should behave like true for opt-out setting")
        -- Stats (chapter info) are only available with open book, but the gate should pass
        TestRunner:assert(data.chapter_title ~= nil, "basic stats gate should pass when nil (opt-out)")
    end)

    -- =========================================================================
    -- PARITY: nil settings produce same result in both modes
    -- =========================================================================
    print("\n--- PARITY: nil settings ---")

    TestRunner:test("PARITY: nil settings → same gating in both modes", function()
        local settings = {}  -- All nil (defaults)
        local sidecar_ext = createSidecarExtractor(settings)
        local open_book_ext = createOpenBookExtractor(settings)
        local s = sidecar_ext:extractForAction({ use_highlights = true, use_annotations = true, use_notebook = true, prompt = "{highlights}{annotations}" })
        local o = open_book_ext:extractForAction({ use_highlights = true, use_annotations = true, use_notebook = true, prompt = "{highlights}{annotations}" })
        -- All opt-in should be blocked identically
        TestRunner:assertEquals(s.highlights, o.highlights, "highlights should match with nil settings")
        TestRunner:assertEquals(s.annotations, o.annotations, "annotations should match with nil settings")
        TestRunner:assertEquals(s.notebook_content, o.notebook_content, "notebook should match with nil settings")
        -- Opt-out: progress gate passes in both, but values differ (sidecar=DocSettings, open=live doc)
        TestRunner:assert(s.reading_progress ~= nil and s.reading_progress ~= "",
            "sidecar progress should be non-empty (opt-out default allows)")
        TestRunner:assert(o.reading_progress ~= nil and o.reading_progress ~= "",
            "open-book progress should be non-empty (opt-out default allows)")
    end)

    -- =========================================================================
    -- Combination: only one of highlights/annotations enabled
    -- =========================================================================
    print("\n--- Combination: mixed highlights/annotations settings ---")

    TestRunner:test("highlights ON + annotations OFF: highlights extracted, annotations degrade", function()
        local extractor = createSidecarExtractor({
            enable_highlights_sharing = true,
            enable_annotations_sharing = false,
        })
        local data = extractor:extractForAction({
            use_highlights = true, use_annotations = true,
            prompt = "{highlights}{annotations}",
        })
        TestRunner:assertContains(data.highlights, "A highlight", "highlights should be extracted")
        -- Annotations should degrade to highlights (text only, no notes)
        TestRunner:assertContains(data.annotations, "A highlight", "annotations should degrade to highlight text")
        TestRunner:assertEquals(data._annotations_degraded, true, "should be marked as degraded")
    end)

    TestRunner:test("highlights OFF + annotations ON: highlights extracted (annotation implies), annotations full", function()
        local extractor = createSidecarExtractor({
            enable_highlights_sharing = false,
            enable_annotations_sharing = true,
        })
        local data = extractor:extractForAction({
            use_highlights = true, use_annotations = true,
            prompt = "{highlights}{annotations}",
        })
        -- annotations_sharing implies highlights access
        TestRunner:assertContains(data.highlights, "A highlight",
            "highlights should be extracted (annotations_sharing implies)")
        TestRunner:assertContains(data.annotations, "A highlight", "full annotations should be available")
        TestRunner:assertEquals(data._annotations_degraded, false, "should NOT be degraded")
    end)

    -- =========================================================================
    -- use_highlights action flag vs use_annotations flag interaction
    -- =========================================================================
    print("\n--- Action flag interaction ---")

    TestRunner:test("use_highlights=true, use_annotations=false: highlights extracted, annotations degrade", function()
        local extractor = createSidecarExtractor({
            enable_highlights_sharing = true,
            enable_annotations_sharing = true,
        })
        local data = extractor:extractForAction({
            use_highlights = true, use_annotations = false,
            prompt = "{highlights}",
        })
        TestRunner:assertContains(data.highlights, "A highlight")
        -- Degradation path fires: use_annotations=false but use_highlights=true
        -- so elseif highlights_allowed and (use_highlights or use_annotations) → true
        -- This means annotations data is set (degraded to highlights-only)
        TestRunner:assertEquals(data._annotations_degraded, true,
            "annotations should degrade when use_annotations=false but use_highlights=true")
    end)

    TestRunner:test("use_highlights=false, use_annotations=true: annotations extracted, highlights blocked", function()
        local extractor = createSidecarExtractor({
            enable_highlights_sharing = true,
            enable_annotations_sharing = true,
        })
        local data = extractor:extractForAction({
            use_highlights = false, use_annotations = true,
            prompt = "{annotations}",
        })
        TestRunner:assertEquals(data.highlights, "", "highlights should be empty when flag is false")
        TestRunner:assertContains(data.annotations, "A highlight", "annotations should be available")
    end)

    resetMocks()
end

-- =============================================================================
-- Settings propagation: simulate toggle → extract cycle
-- =============================================================================

local function runSettingsPropagationTests()
    print("\n=== Testing Settings Propagation (toggle → extract) ===")

    setupSidecarData({
        annotations = {
            { text = "Should be visible when sharing on" },
        },
        percent_finished = 0.5,
    })
    mock_notebook_content = "Notebook content"

    -- Simulate the real config flow:
    -- 1. Global configuration table (like the real `configuration` global)
    -- 2. Settings toggle changes the value
    -- 3. updateConfigFromSettings merges settings → configuration.features
    -- 4. Sidecar extractor reads from configuration.features

    print("\n--- Simulate: enable → disable → re-extract ---")

    TestRunner:test("settings propagation: highlights ON → extract → highlights found", function()
        -- Step 1: initial config with highlights ON
        local config_features = { enable_highlights_sharing = true }
        local extractor = createSidecarExtractor(config_features)
        local data = extractor:extractForAction({ use_highlights = true, prompt = "{highlights}" })
        TestRunner:assertContains(data.highlights, "Should be visible")
    end)

    TestRunner:test("settings propagation: highlights ON → toggle OFF → re-extract → empty", function()
        -- Step 1: config starts with highlights ON (simulating live configuration.features)
        local config_features = { enable_highlights_sharing = true }

        -- Step 2: user toggles OFF — simulating setSettingValue + updateConfigFromSettings
        config_features.enable_highlights_sharing = false

        -- Step 3: new extractor with updated settings (what sidecar extraction does)
        local extractor = createSidecarExtractor(config_features)
        local data = extractor:extractForAction({ use_highlights = true, prompt = "{highlights}" })
        TestRunner:assertEquals(data.highlights, "", "highlights should be empty after toggle OFF")
    end)

    TestRunner:test("settings propagation: highlights OFF → toggle ON → re-extract → found", function()
        local config_features = { enable_highlights_sharing = false }

        -- Toggle ON
        config_features.enable_highlights_sharing = true

        local extractor = createSidecarExtractor(config_features)
        local data = extractor:extractForAction({ use_highlights = true, prompt = "{highlights}" })
        TestRunner:assertContains(data.highlights, "Should be visible",
            "highlights should appear after toggle ON")
    end)

    -- Simulate the REAL config copy pattern from executeFileBrowserAction
    print("\n--- Simulate: config_copy pattern (executeFileBrowserAction) ---")

    TestRunner:test("config_copy: settings change BEFORE copy → copy has new value", function()
        -- Simulate: global configuration.features gets updated, THEN config_copy is made
        local global_features = { enable_highlights_sharing = true }

        -- User toggles OFF, updateConfigFromSettings runs
        global_features.enable_highlights_sharing = false

        -- Config copy happens (like lines 7529-7532 in executeFileBrowserAction)
        local config_copy_features = {}
        for k, v in pairs(global_features) do
            config_copy_features[k] = v
        end

        -- Sidecar extractor reads from config_copy
        local extractor = createSidecarExtractor(config_copy_features)
        local data = extractor:extractForAction({ use_highlights = true, prompt = "{highlights}" })
        TestRunner:assertEquals(data.highlights, "",
            "config_copy should reflect settings change before copy")
    end)

    TestRunner:test("config_copy: settings change AFTER copy → copy has OLD value (stale!)", function()
        -- Simulate: config_copy is made from global, THEN settings change
        local global_features = { enable_highlights_sharing = true }

        -- Config copy happens first (snapshot)
        local config_copy_features = {}
        for k, v in pairs(global_features) do
            config_copy_features[k] = v
        end

        -- THEN user toggles OFF — but config_copy already has the old value
        global_features.enable_highlights_sharing = false

        -- Sidecar extractor reads from the stale config_copy
        local extractor = createSidecarExtractor(config_copy_features)
        local data = extractor:extractForAction({ use_highlights = true, prompt = "{highlights}" })
        -- This DOCUMENTS the staleness behavior — config_copy is a snapshot
        TestRunner:assertContains(data.highlights, "Should be visible",
            "config_copy is a SNAPSHOT — changes after copy are not reflected")
    end)

    -- The INPUT DIALOG path uses the global configuration directly (no copy)
    -- So it should always see the latest settings
    print("\n--- Simulate: input dialog path (live configuration reference) ---")

    TestRunner:test("input dialog: settings change visible through live reference", function()
        -- Simulate: showChatGPTDialog captures global configuration reference
        local global_config = { features = { enable_highlights_sharing = true } }
        local dialog_config_ref = global_config  -- Same reference

        -- User changes settings via gear menu (modifies global)
        global_config.features.enable_highlights_sharing = false

        -- handlePredefinedPrompt reads from dialog_config_ref (same object)
        local extractor = createSidecarExtractor(dialog_config_ref.features)
        local data = extractor:extractForAction({ use_highlights = true, prompt = "{highlights}" })
        TestRunner:assertEquals(data.highlights, "",
            "live reference should see settings change immediately")
    end)

    -- Test the annotations-implies-highlights auto-enable scenario
    print("\n--- Annotations toggle auto-enables highlights ---")

    TestRunner:test("annotations ON → highlights auto-enabled → annotations OFF → highlights survives", function()
        local features = { enable_highlights_sharing = false, enable_annotations_sharing = false }

        -- User turns annotations ON → on_change auto-enables highlights
        features.enable_annotations_sharing = true
        features.enable_highlights_sharing = true  -- Auto-enabled by on_change

        -- User turns annotations OFF → highlights NOT auto-disabled
        features.enable_annotations_sharing = false
        -- enable_highlights_sharing stays true!

        local extractor = createSidecarExtractor(features)
        local data = extractor:extractForAction({ use_highlights = true, prompt = "{highlights}" })
        TestRunner:assertContains(data.highlights, "Should be visible",
            "highlights should remain after annotations is turned off")
    end)

    TestRunner:test("annotations OFF + highlights ON: highlights extracted, annotations degrade", function()
        local features = {
            enable_highlights_sharing = true,
            enable_annotations_sharing = false,
        }
        local extractor = createSidecarExtractor(features)
        local data = extractor:extractForAction({
            use_highlights = true, use_annotations = true,
            prompt = "{highlights}{annotations}",
        })
        TestRunner:assertContains(data.highlights, "Should be visible")
        TestRunner:assertEquals(data._annotations_degraded, true,
            "annotations should degrade to highlights-only")
    end)

    resetMocks()
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
    runParityTests()
    runRealActionTests()
    runEdgeCaseTests()
    runSettingsPropagationTests()

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
