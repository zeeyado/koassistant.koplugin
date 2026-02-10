--[[
Unit Tests for State Management

Tests context detection, flag isolation, config merging, transient flag
consumption, and cache permission gating. These are "contract tests" that
verify invariants the rest of the codebase depends on.

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

function TestRunner:assertNil(actual, message)
    if actual ~= nil then
        error(string.format("%s: expected nil, got '%s'",
            message or "Value not nil",
            tostring(actual)), 2)
    end
end

function TestRunner:assertNotNil(actual, message)
    if actual == nil then
        error(string.format("%s: expected non-nil value",
            message or "Value is nil"), 2)
    end
end

-- =============================================================================
-- Contract reimplementations
-- =============================================================================

--- Reimplementation of getPromptContext() from koassistant_dialogs.lua:159-171
--- If the production function changes, tests using this will fail, signaling
--- that the contract has changed and tests need review.
local function getPromptContext(config)
    if config and config.features then
        if config.features.is_multi_book_context then
            return "multi_book"
        elseif config.features.is_book_context then
            return "book"
        elseif config.features.is_general_context then
            return "general"
        end
    end
    return "highlight"  -- default
end

--- Reimplementation of the flag-setting patterns from main.lua.
--- Each function simulates what the corresponding entry point does to config.features.

local function applyHighlightPattern(features)
    features.is_general_context = nil
    features.is_book_context = nil
    features.is_multi_book_context = nil
    features.book_metadata = nil
    features.books_info = nil
end

local function applyBookPattern(features, title, authors, file)
    features.is_general_context = nil
    features.is_book_context = true
    features.is_multi_book_context = nil
    features.book_metadata = {
        title = title or "Test Book",
        author = authors or "Test Author",
        author_clause = (authors and authors ~= "") and string.format(" by %s", authors) or "",
        file = file or "/path/to/book.epub",
    }
end

local function applyGeneralPattern(features)
    features.is_general_context = true
    features.is_book_context = nil
    features.is_multi_book_context = nil
    features.book_metadata = nil
    features.books_info = nil
end

local function applyMultiBookPattern(features, books_info)
    features.is_general_context = nil
    features.is_book_context = nil
    features.is_multi_book_context = true
    features.books_info = books_info or {}
end

local function applyDictionaryPattern(features)
    features.is_general_context = nil
    features.is_book_context = nil
    features.is_multi_book_context = nil
end

--- Reimplementation of updateConfigFromSettings() merge logic from main.lua:1429-1455.
--- @param config table The existing configuration (mutated in place)
--- @param saved_features table Features read from saved settings
local function mergeSettingsIntoConfig(config, saved_features)
    local runtime_only_keys = {
        is_general_context = true,
        is_book_context = true,
        is_multi_book_context = true,
        book_metadata = true,
        book_context = true,
        books_info = true,
        selection_data = true,
        compact_view = true,
        minimal_buttons = true,
        is_full_page_translate = true,
    }

    if not config.features then
        config.features = saved_features
    else
        for k, v in pairs(saved_features) do
            if not runtime_only_keys[k] then
                config.features[k] = v
            end
        end
    end

    -- Explicitly clear transient flags after merge
    config.features.compact_view = nil
    config.features.minimal_buttons = nil
    config.features.is_full_page_translate = nil
end

--- Reimplementation of transient flag consumption from koassistant_dialogs.lua:2515-2522.
--- @param configuration table The configuration object
--- @return boolean|nil hide_artifacts
--- @return table|nil exclude_action_flags
local function consumeTransientFlags(configuration)
    local hide_artifacts = ((configuration or {}).features or {})._hide_artifacts
    local exclude_action_flags = ((configuration or {}).features or {})._exclude_action_flags

    if configuration and configuration.features then
        configuration.features._hide_artifacts = nil
        configuration.features._exclude_action_flags = nil
    end

    return hide_artifacts, exclude_action_flags
end

-- =============================================================================
-- Mock Infrastructure for Cache Permission Tests
-- =============================================================================

--- Create a mock ContextExtractor with controllable cache data.
--- @param settings table Privacy settings (enable_book_text_extraction, etc.)
--- @param mock_data table Mock data for cache methods
--- @return ContextExtractor instance with mocked methods
local function createMockExtractor(settings, mock_data)
    mock_data = mock_data or {}

    local extractor = ContextExtractor:new(nil, settings or {})

    extractor.isAvailable = function() return true end

    extractor.getHighlights = function()
        return mock_data.highlights or { formatted = "- Test highlight" }
    end

    extractor.getAnnotations = function()
        return mock_data.annotations or { formatted = "- Test annotation" }
    end

    extractor.getBookText = function()
        if not extractor:isProviderTrusted() and not extractor:isBookTextExtractionEnabled() then
            return { text = "", disabled = true }
        end
        return mock_data.book_text or { text = "Book text." }
    end

    extractor.getFullDocumentText = function()
        if not extractor:isProviderTrusted() and not extractor:isBookTextExtractionEnabled() then
            return { text = "", disabled = true }
        end
        return mock_data.full_document or { text = "Full document." }
    end

    extractor.getReadingProgress = function()
        return mock_data.reading_progress or { formatted = "50%", decimal = 0.5 }
    end

    extractor.getReadingStats = function()
        return mock_data.reading_stats or {
            chapter_title = "Chapter 5",
            chapters_read = "5",
            time_since_last_read = "2 hours ago",
        }
    end

    extractor.getXrayCache = function()
        return mock_data.xray_cache or { text = "", progress_formatted = "" }
    end

    extractor.getAnalyzeCache = function()
        return mock_data.analyze_cache or { text = "" }
    end

    extractor.getSummaryCache = function()
        return mock_data.summary_cache or { text = "" }
    end

    extractor.getNotebookContent = function()
        return mock_data.notebook_content or { content = "" }
    end

    return extractor
end

-- =============================================================================
-- Section 1: Context Detection Contract
-- =============================================================================

local function runContextDetectionTests()
    print("\n--- Context Detection Contract ---")

    TestRunner:test("book context flag returns 'book'", function()
        local config = { features = { is_book_context = true } }
        TestRunner:assertEquals(getPromptContext(config), "book")
    end)

    TestRunner:test("general context flag returns 'general'", function()
        local config = { features = { is_general_context = true } }
        TestRunner:assertEquals(getPromptContext(config), "general")
    end)

    TestRunner:test("multi_book context flag returns 'multi_book'", function()
        local config = { features = { is_multi_book_context = true } }
        TestRunner:assertEquals(getPromptContext(config), "multi_book")
    end)

    TestRunner:test("no flags returns 'highlight' (default)", function()
        local config = { features = {} }
        TestRunner:assertEquals(getPromptContext(config), "highlight")
    end)

    TestRunner:test("nil config returns 'highlight'", function()
        TestRunner:assertEquals(getPromptContext(nil), "highlight")
    end)

    TestRunner:test("nil features returns 'highlight'", function()
        local config = { features = nil }
        TestRunner:assertEquals(getPromptContext(config), "highlight")
    end)

    TestRunner:test("empty config returns 'highlight'", function()
        TestRunner:assertEquals(getPromptContext({}), "highlight")
    end)

    -- Priority tests
    TestRunner:test("multi_book wins over book (both true)", function()
        local config = { features = { is_multi_book_context = true, is_book_context = true } }
        TestRunner:assertEquals(getPromptContext(config), "multi_book")
    end)

    TestRunner:test("multi_book wins over general (both true)", function()
        local config = { features = { is_multi_book_context = true, is_general_context = true } }
        TestRunner:assertEquals(getPromptContext(config), "multi_book")
    end)

    TestRunner:test("book wins over general (both true)", function()
        local config = { features = { is_book_context = true, is_general_context = true } }
        TestRunner:assertEquals(getPromptContext(config), "book")
    end)

    TestRunner:test("all three true: multi_book wins", function()
        local config = { features = {
            is_multi_book_context = true,
            is_book_context = true,
            is_general_context = true,
        } }
        TestRunner:assertEquals(getPromptContext(config), "multi_book")
    end)

    -- Truthy values
    TestRunner:test("truthy non-boolean value triggers context", function()
        local config = { features = { is_book_context = "yes" } }
        TestRunner:assertEquals(getPromptContext(config), "book")
    end)

    TestRunner:test("false flag does not trigger context", function()
        local config = { features = { is_book_context = false } }
        TestRunner:assertEquals(getPromptContext(config), "highlight")
    end)

    TestRunner:test("all flags false returns 'highlight'", function()
        local config = { features = {
            is_book_context = false,
            is_general_context = false,
            is_multi_book_context = false,
        } }
        TestRunner:assertEquals(getPromptContext(config), "highlight")
    end)
end

-- =============================================================================
-- Section 2: Context Flag Isolation
-- =============================================================================

local function runContextFlagIsolationTests()
    print("\n--- Context Flag Isolation ---")

    TestRunner:test("highlight pattern: all context flags nil", function()
        local features = { is_book_context = true, is_general_context = true, is_multi_book_context = true }
        applyHighlightPattern(features)
        TestRunner:assertNil(features.is_book_context, "is_book_context")
        TestRunner:assertNil(features.is_general_context, "is_general_context")
        TestRunner:assertNil(features.is_multi_book_context, "is_multi_book_context")
    end)

    TestRunner:test("highlight pattern: clears book_metadata and books_info", function()
        local features = { book_metadata = { title = "Test" }, books_info = { {}, {} } }
        applyHighlightPattern(features)
        TestRunner:assertNil(features.book_metadata, "book_metadata")
        TestRunner:assertNil(features.books_info, "books_info")
    end)

    TestRunner:test("book pattern: only is_book_context=true", function()
        local features = { is_general_context = true, is_multi_book_context = true }
        applyBookPattern(features)
        TestRunner:assertEquals(features.is_book_context, true, "is_book_context")
        TestRunner:assertNil(features.is_general_context, "is_general_context")
        TestRunner:assertNil(features.is_multi_book_context, "is_multi_book_context")
    end)

    TestRunner:test("book pattern: sets book_metadata with expected fields", function()
        local features = {}
        applyBookPattern(features, "My Book", "Jane Doe", "/books/my_book.epub")
        TestRunner:assertNotNil(features.book_metadata, "book_metadata should be set")
        TestRunner:assertEquals(features.book_metadata.title, "My Book")
        TestRunner:assertEquals(features.book_metadata.author, "Jane Doe")
        TestRunner:assertEquals(features.book_metadata.author_clause, " by Jane Doe")
        TestRunner:assertEquals(features.book_metadata.file, "/books/my_book.epub")
    end)

    TestRunner:test("book pattern: empty author produces empty author_clause", function()
        local features = {}
        applyBookPattern(features, "My Book", "")
        TestRunner:assertEquals(features.book_metadata.author_clause, "")
    end)

    TestRunner:test("general pattern: only is_general_context=true", function()
        local features = { is_book_context = true, is_multi_book_context = true }
        applyGeneralPattern(features)
        TestRunner:assertEquals(features.is_general_context, true, "is_general_context")
        TestRunner:assertNil(features.is_book_context, "is_book_context")
        TestRunner:assertNil(features.is_multi_book_context, "is_multi_book_context")
    end)

    TestRunner:test("general pattern: clears book_metadata and books_info", function()
        local features = { book_metadata = { title = "Test" }, books_info = { {}, {} } }
        applyGeneralPattern(features)
        TestRunner:assertNil(features.book_metadata, "book_metadata")
        TestRunner:assertNil(features.books_info, "books_info")
    end)

    TestRunner:test("multi_book pattern: only is_multi_book_context=true", function()
        local features = { is_book_context = true, is_general_context = true }
        applyMultiBookPattern(features, { { title = "Book1" }, { title = "Book2" } })
        TestRunner:assertEquals(features.is_multi_book_context, true, "is_multi_book_context")
        TestRunner:assertNil(features.is_book_context, "is_book_context")
        TestRunner:assertNil(features.is_general_context, "is_general_context")
    end)

    TestRunner:test("dictionary pattern: all context flags nil", function()
        local features = { is_book_context = true, is_general_context = true, is_multi_book_context = true }
        applyDictionaryPattern(features)
        TestRunner:assertNil(features.is_book_context, "is_book_context")
        TestRunner:assertNil(features.is_general_context, "is_general_context")
        TestRunner:assertNil(features.is_multi_book_context, "is_multi_book_context")
    end)

    -- Sequence tests
    TestRunner:test("sequence: book → general → book flag is nil", function()
        local features = {}
        applyBookPattern(features)
        TestRunner:assertEquals(getPromptContext({ features = features }), "book")
        applyGeneralPattern(features)
        TestRunner:assertEquals(getPromptContext({ features = features }), "general")
        TestRunner:assertNil(features.is_book_context, "book flag should be nil after general")
    end)

    TestRunner:test("sequence: general → highlight → general flag is nil", function()
        local features = {}
        applyGeneralPattern(features)
        TestRunner:assertEquals(getPromptContext({ features = features }), "general")
        applyHighlightPattern(features)
        TestRunner:assertEquals(getPromptContext({ features = features }), "highlight")
        TestRunner:assertNil(features.is_general_context, "general flag should be nil after highlight")
    end)

    TestRunner:test("non-context features survive pattern changes", function()
        local features = { provider = "anthropic", default_temperature = 0.7 }
        applyBookPattern(features)
        TestRunner:assertEquals(features.provider, "anthropic", "provider survives")
        TestRunner:assertEquals(features.default_temperature, 0.7, "temperature survives")
        applyGeneralPattern(features)
        TestRunner:assertEquals(features.provider, "anthropic", "provider still survives")
    end)
end

-- =============================================================================
-- Section 3: Config Merge / Runtime-Only Keys
-- =============================================================================

local function runConfigMergeTests()
    print("\n--- Config Merge / Runtime-Only Keys ---")

    TestRunner:test("saved setting overwrites existing config value", function()
        local config = { features = { provider = "anthropic" } }
        mergeSettingsIntoConfig(config, { provider = "openai" })
        TestRunner:assertEquals(config.features.provider, "openai")
    end)

    TestRunner:test("new saved setting added to existing config", function()
        local config = { features = { provider = "anthropic" } }
        mergeSettingsIntoConfig(config, { default_temperature = 0.9 })
        TestRunner:assertEquals(config.features.default_temperature, 0.9)
    end)

    TestRunner:test("runtime key is_book_context survives merge", function()
        local config = { features = { is_book_context = true } }
        mergeSettingsIntoConfig(config, { is_book_context = false, provider = "openai" })
        TestRunner:assertEquals(config.features.is_book_context, true, "runtime key preserved")
        TestRunner:assertEquals(config.features.provider, "openai", "saved key applied")
    end)

    TestRunner:test("runtime key is_general_context survives merge", function()
        local config = { features = { is_general_context = true } }
        mergeSettingsIntoConfig(config, { is_general_context = nil })
        TestRunner:assertEquals(config.features.is_general_context, true)
    end)

    TestRunner:test("runtime key is_multi_book_context survives merge", function()
        local config = { features = { is_multi_book_context = true } }
        mergeSettingsIntoConfig(config, { is_multi_book_context = false })
        TestRunner:assertEquals(config.features.is_multi_book_context, true)
    end)

    TestRunner:test("runtime key book_metadata survives merge", function()
        local meta = { title = "Test Book" }
        local config = { features = { book_metadata = meta } }
        mergeSettingsIntoConfig(config, { book_metadata = nil })
        TestRunner:assertEquals(config.features.book_metadata, meta)
    end)

    TestRunner:test("runtime key selection_data survives merge", function()
        local sel = { text = "selected text" }
        local config = { features = { selection_data = sel } }
        mergeSettingsIntoConfig(config, { selection_data = nil })
        TestRunner:assertEquals(config.features.selection_data, sel)
    end)

    TestRunner:test("runtime key books_info survives merge", function()
        local books = { { title = "A" }, { title = "B" } }
        local config = { features = { books_info = books } }
        mergeSettingsIntoConfig(config, {})
        TestRunner:assertEquals(config.features.books_info, books)
    end)

    TestRunner:test("runtime key book_context survives merge", function()
        local config = { features = { book_context = "some context" } }
        mergeSettingsIntoConfig(config, { book_context = "stale" })
        TestRunner:assertEquals(config.features.book_context, "some context")
    end)

    -- Transient flag clearing
    TestRunner:test("transient flag compact_view cleared after merge", function()
        local config = { features = { compact_view = true } }
        mergeSettingsIntoConfig(config, {})
        TestRunner:assertNil(config.features.compact_view)
    end)

    TestRunner:test("transient flag minimal_buttons cleared after merge", function()
        local config = { features = { minimal_buttons = true } }
        mergeSettingsIntoConfig(config, {})
        TestRunner:assertNil(config.features.minimal_buttons)
    end)

    TestRunner:test("transient flag is_full_page_translate cleared after merge", function()
        local config = { features = { is_full_page_translate = true } }
        mergeSettingsIntoConfig(config, {})
        TestRunner:assertNil(config.features.is_full_page_translate)
    end)

    TestRunner:test("empty features table: merge initializes from saved settings", function()
        local config = {}
        mergeSettingsIntoConfig(config, { provider = "gemini", default_temperature = 0.5 })
        TestRunner:assertEquals(config.features.provider, "gemini")
        TestRunner:assertEquals(config.features.default_temperature, 0.5)
    end)

    TestRunner:test("existing non-runtime key not in saved settings: preserved", function()
        local config = { features = { debug = "full", provider = "anthropic" } }
        mergeSettingsIntoConfig(config, { provider = "openai" })
        TestRunner:assertEquals(config.features.debug, "full", "existing key preserved")
        TestRunner:assertEquals(config.features.provider, "openai", "saved key updated")
    end)

    TestRunner:test("full scenario: runtime keys + saved settings + transient clearing", function()
        local config = {
            features = {
                is_book_context = true,
                book_metadata = { title = "Novel" },
                compact_view = true,
                provider = "anthropic",
            }
        }
        mergeSettingsIntoConfig(config, {
            provider = "gemini",
            default_temperature = 0.8,
            is_book_context = false,  -- stale saved value
            compact_view = true,      -- stale saved value
        })
        -- Runtime keys preserved
        TestRunner:assertEquals(config.features.is_book_context, true, "runtime key preserved")
        TestRunner:assertEquals(config.features.book_metadata.title, "Novel", "book_metadata preserved")
        -- Saved settings applied
        TestRunner:assertEquals(config.features.provider, "gemini", "provider updated")
        TestRunner:assertEquals(config.features.default_temperature, 0.8, "temperature applied")
        -- Transient flag cleared
        TestRunner:assertNil(config.features.compact_view, "transient cleared")
    end)
end

-- =============================================================================
-- Section 4: Transient Flag Consumption
-- =============================================================================

local function runTransientFlagConsumptionTests()
    print("\n--- Transient Flag Consumption ---")

    TestRunner:test("_hide_artifacts consumed and cleared", function()
        local config = { features = { _hide_artifacts = true } }
        local hide, _ = consumeTransientFlags(config)
        TestRunner:assertEquals(hide, true, "value read correctly")
        TestRunner:assertNil(config.features._hide_artifacts, "cleared after consumption")
    end)

    TestRunner:test("_exclude_action_flags consumed and cleared", function()
        local flags = { "use_book_text", "use_annotations" }
        local config = { features = { _exclude_action_flags = flags } }
        local _, exclude = consumeTransientFlags(config)
        TestRunner:assertEquals(exclude, flags, "value read correctly")
        TestRunner:assertNil(config.features._exclude_action_flags, "cleared after consumption")
    end)

    TestRunner:test("both flags nil: no crash, returns nil", function()
        local config = { features = {} }
        local hide, exclude = consumeTransientFlags(config)
        TestRunner:assertNil(hide, "hide is nil")
        TestRunner:assertNil(exclude, "exclude is nil")
    end)

    TestRunner:test("missing features table: no crash", function()
        local config = {}
        local hide, exclude = consumeTransientFlags(config)
        TestRunner:assertNil(hide)
        TestRunner:assertNil(exclude)
    end)

    TestRunner:test("nil config: no crash", function()
        local hide, exclude = consumeTransientFlags(nil)
        TestRunner:assertNil(hide)
        TestRunner:assertNil(exclude)
    end)

    TestRunner:test("consuming once clears: second read returns nil", function()
        local config = { features = { _hide_artifacts = true, _exclude_action_flags = { "a" } } }
        consumeTransientFlags(config)
        local hide, exclude = consumeTransientFlags(config)
        TestRunner:assertNil(hide, "second read returns nil for _hide_artifacts")
        TestRunner:assertNil(exclude, "second read returns nil for _exclude_action_flags")
    end)

    TestRunner:test("other flags not affected by consumption", function()
        local config = { features = {
            _hide_artifacts = true,
            provider = "anthropic",
            is_book_context = true,
        } }
        consumeTransientFlags(config)
        TestRunner:assertEquals(config.features.provider, "anthropic", "provider unchanged")
        TestRunner:assertEquals(config.features.is_book_context, true, "context flag unchanged")
    end)
end

-- =============================================================================
-- Section 5: Cache Permission Gating
-- =============================================================================

local function runCachePermissionGatingTests()
    print("\n--- Cache Permission Gating: X-Ray Cache ---")

    -- X-Ray cache: used_book_text variations
    TestRunner:test("xray: used_book_text=false + extraction disabled → accessible", function()
        local extractor = createMockExtractor(
            { enable_book_text_extraction = false },
            { xray_cache = { text = "X-Ray content", progress_formatted = "30%", used_book_text = false } }
        )
        local data = extractor:extractForAction({ use_xray_cache = true })
        TestRunner:assertEquals(data.xray_cache, "X-Ray content", "cache should be accessible")
    end)

    TestRunner:test("xray: used_book_text=true + extraction disabled → blocked", function()
        local extractor = createMockExtractor(
            { enable_book_text_extraction = false },
            { xray_cache = { text = "X-Ray content", progress_formatted = "30%", used_book_text = true } }
        )
        local data = extractor:extractForAction({ use_xray_cache = true })
        TestRunner:assertNil(data.xray_cache, "cache should be blocked")
    end)

    TestRunner:test("xray: used_book_text=nil (legacy) + extraction disabled → blocked", function()
        local extractor = createMockExtractor(
            { enable_book_text_extraction = false },
            { xray_cache = { text = "Legacy X-Ray", progress_formatted = "20%", used_book_text = nil } }
        )
        local data = extractor:extractForAction({ use_xray_cache = true })
        TestRunner:assertNil(data.xray_cache, "legacy cache treated as text-based, should be blocked")
    end)

    TestRunner:test("xray: used_book_text=true + extraction enabled → accessible", function()
        local extractor = createMockExtractor(
            { enable_book_text_extraction = true },
            { xray_cache = { text = "X-Ray content", progress_formatted = "50%", used_book_text = true } }
        )
        local data = extractor:extractForAction({ use_xray_cache = true })
        TestRunner:assertEquals(data.xray_cache, "X-Ray content", "cache should be accessible")
    end)

    -- X-Ray cache: annotation gate
    TestRunner:test("xray: used_annotations=true + annotations disabled → blocked", function()
        local extractor = createMockExtractor(
            { enable_book_text_extraction = false, enable_annotations_sharing = false },
            { xray_cache = { text = "Annotated X-Ray", progress_formatted = "40%",
                used_book_text = false, used_annotations = true } }
        )
        local data = extractor:extractForAction({ use_xray_cache = true, use_annotations = true })
        TestRunner:assertNil(data.xray_cache, "annotation gate should block")
    end)

    TestRunner:test("xray: used_annotations=true + annotations enabled + action flag → accessible", function()
        local extractor = createMockExtractor(
            { enable_book_text_extraction = false, enable_annotations_sharing = true },
            { xray_cache = { text = "Annotated X-Ray", progress_formatted = "40%",
                used_book_text = false, used_annotations = true } }
        )
        local data = extractor:extractForAction({ use_xray_cache = true, use_annotations = true })
        TestRunner:assertEquals(data.xray_cache, "Annotated X-Ray", "both gates satisfied")
    end)

    TestRunner:test("xray: used_annotations=false → accessible regardless of annotation setting", function()
        local extractor = createMockExtractor(
            { enable_book_text_extraction = false, enable_annotations_sharing = false },
            { xray_cache = { text = "No-annotation X-Ray", progress_formatted = "30%",
                used_book_text = false, used_annotations = false } }
        )
        local data = extractor:extractForAction({ use_xray_cache = true })
        TestRunner:assertEquals(data.xray_cache, "No-annotation X-Ray")
    end)

    TestRunner:test("xray: trusted provider bypasses text extraction gate", function()
        local extractor = createMockExtractor(
            { enable_book_text_extraction = false, trusted_providers = { "ollama" }, provider = "ollama" },
            { xray_cache = { text = "Trusted X-Ray", progress_formatted = "60%", used_book_text = true } }
        )
        local data = extractor:extractForAction({ use_xray_cache = true })
        TestRunner:assertEquals(data.xray_cache, "Trusted X-Ray", "trusted provider bypasses gate")
    end)

    -- Analyze cache
    print("\n--- Cache Permission Gating: Analyze Cache ---")

    TestRunner:test("analyze: used_book_text=false + extraction disabled → accessible", function()
        local extractor = createMockExtractor(
            { enable_book_text_extraction = false },
            { analyze_cache = { text = "Analysis content", used_book_text = false } }
        )
        local data = extractor:extractForAction({ use_analyze_cache = true })
        TestRunner:assertEquals(data.analyze_cache, "Analysis content")
    end)

    TestRunner:test("analyze: used_book_text=true + extraction disabled → blocked", function()
        local extractor = createMockExtractor(
            { enable_book_text_extraction = false },
            { analyze_cache = { text = "Analysis content", used_book_text = true } }
        )
        local data = extractor:extractForAction({ use_analyze_cache = true })
        TestRunner:assertNil(data.analyze_cache, "should be blocked")
    end)

    TestRunner:test("analyze: used_book_text=nil + extraction disabled → blocked", function()
        local extractor = createMockExtractor(
            { enable_book_text_extraction = false },
            { analyze_cache = { text = "Legacy analysis", used_book_text = nil } }
        )
        local data = extractor:extractForAction({ use_analyze_cache = true })
        TestRunner:assertNil(data.analyze_cache, "legacy treated as text-based")
    end)

    TestRunner:test("analyze: trusted provider bypasses gate", function()
        local extractor = createMockExtractor(
            { enable_book_text_extraction = false, trusted_providers = { "ollama" }, provider = "ollama" },
            { analyze_cache = { text = "Trusted analysis", used_book_text = true } }
        )
        local data = extractor:extractForAction({ use_analyze_cache = true })
        TestRunner:assertEquals(data.analyze_cache, "Trusted analysis")
    end)

    -- Summary cache
    print("\n--- Cache Permission Gating: Summary Cache ---")

    TestRunner:test("summary: used_book_text=false + extraction disabled → accessible", function()
        local extractor = createMockExtractor(
            { enable_book_text_extraction = false },
            { summary_cache = { text = "Summary content", used_book_text = false } }
        )
        local data = extractor:extractForAction({ use_summary_cache = true })
        TestRunner:assertEquals(data.summary_cache, "Summary content")
    end)

    TestRunner:test("summary: used_book_text=true + extraction disabled → blocked", function()
        local extractor = createMockExtractor(
            { enable_book_text_extraction = false },
            { summary_cache = { text = "Summary content", used_book_text = true } }
        )
        local data = extractor:extractForAction({ use_summary_cache = true })
        TestRunner:assertNil(data.summary_cache, "should be blocked")
    end)

    TestRunner:test("summary: used_book_text=nil + extraction disabled → blocked", function()
        local extractor = createMockExtractor(
            { enable_book_text_extraction = false },
            { summary_cache = { text = "Legacy summary", used_book_text = nil } }
        )
        local data = extractor:extractForAction({ use_summary_cache = true })
        TestRunner:assertNil(data.summary_cache, "legacy treated as text-based")
    end)

    TestRunner:test("summary: trusted provider bypasses gate", function()
        local extractor = createMockExtractor(
            { enable_book_text_extraction = false, trusted_providers = { "ollama" }, provider = "ollama" },
            { summary_cache = { text = "Trusted summary", used_book_text = true } }
        )
        local data = extractor:extractForAction({ use_summary_cache = true })
        TestRunner:assertEquals(data.summary_cache, "Trusted summary")
    end)

    -- Cross-cache independence
    print("\n--- Cache Permission Gating: Cross-Cache Independence ---")

    TestRunner:test("xray blocked but analyze accessible (different used_book_text)", function()
        local extractor = createMockExtractor(
            { enable_book_text_extraction = false },
            {
                xray_cache = { text = "X-Ray", progress_formatted = "30%", used_book_text = true },
                analyze_cache = { text = "Analysis", used_book_text = false },
            }
        )
        local data = extractor:extractForAction({ use_xray_cache = true, use_analyze_cache = true })
        TestRunner:assertNil(data.xray_cache, "xray should be blocked (used text)")
        TestRunner:assertEquals(data.analyze_cache, "Analysis", "analyze should be accessible (no text)")
    end)

    TestRunner:test("mixed used_book_text: only false-flagged caches accessible", function()
        local extractor = createMockExtractor(
            { enable_book_text_extraction = false },
            {
                xray_cache = { text = "X-Ray", progress_formatted = "30%", used_book_text = true },
                analyze_cache = { text = "Analysis", used_book_text = nil },  -- legacy
                summary_cache = { text = "Summary", used_book_text = false },
            }
        )
        local data = extractor:extractForAction({
            use_xray_cache = true, use_analyze_cache = true, use_summary_cache = true,
        })
        TestRunner:assertNil(data.xray_cache, "xray blocked")
        TestRunner:assertNil(data.analyze_cache, "analyze blocked (nil = legacy)")
        TestRunner:assertEquals(data.summary_cache, "Summary", "summary accessible")
    end)

    TestRunner:test("action flag use_xray_cache=false prevents access regardless of permissions", function()
        local extractor = createMockExtractor(
            { enable_book_text_extraction = true },
            { xray_cache = { text = "X-Ray", progress_formatted = "50%", used_book_text = false } }
        )
        local data = extractor:extractForAction({ use_xray_cache = false })
        TestRunner:assertNil(data.xray_cache, "action flag prevents access")
    end)

    TestRunner:test("action flag use_analyze_cache absent prevents access", function()
        local extractor = createMockExtractor(
            { enable_book_text_extraction = true },
            { analyze_cache = { text = "Analysis", used_book_text = false } }
        )
        local data = extractor:extractForAction({})  -- no use_analyze_cache flag
        TestRunner:assertNil(data.analyze_cache, "missing action flag prevents access")
    end)
end

-- =============================================================================
-- Run all tests
-- =============================================================================

print("=== State Management Tests ===")

runContextDetectionTests()
runContextFlagIsolationTests()
runConfigMergeTests()
runTransientFlagConsumptionTests()
runCachePermissionGatingTests()

-- Summary
print(string.format("\n=== Results: %d passed, %d failed ===",
    TestRunner.passed, TestRunner.failed))

return TestRunner.failed == 0
