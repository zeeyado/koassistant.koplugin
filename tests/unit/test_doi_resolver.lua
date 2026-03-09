-- Unit tests for doi_resolver.lua
-- Tests DOI matching, extraction from metadata, page text parsing, and resolution
-- No API calls - pure logic testing

-- Setup paths
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

-- Simple test framework
local TestRunner = {
    passed = 0,
    failed = 0,
}

function TestRunner:suite(name)
    print(string.format("\n  [%s]", name))
end

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
        error(string.format("%s: expected %q, got %q",
            msg or "assertEqual", tostring(expected), tostring(actual)))
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

-- Load module under test
local DOIResolver = require("doi_resolver")

print("")
print(string.rep("=", 50))
print("  Unit Tests: doi_resolver.lua")
print(string.rep("=", 50))

-- ============================================================
-- matchDOI()
-- ============================================================

TestRunner:suite("matchDOI — basic patterns")

TestRunner:test("standard DOI with 4-digit registrant", function()
    TestRunner:assertEqual(DOIResolver.matchDOI("doi:10.1234/abc.def"), "10.1234/abc.def")
end)

TestRunner:test("standard DOI with 5-digit registrant", function()
    TestRunner:assertEqual(DOIResolver.matchDOI("10.12345/some-article"), "10.12345/some-article")
end)

TestRunner:test("DOI with 9-digit registrant", function()
    TestRunner:assertEqual(DOIResolver.matchDOI("10.123456789/x"), "10.123456789/x")
end)

TestRunner:test("DOI embedded in URL", function()
    TestRunner:assertEqual(
        DOIResolver.matchDOI("http://dx.doi.org/10.1098/rstb.2013.0299"),
        "10.1098/rstb.2013.0299"
    )
end)

TestRunner:test("DOI embedded in citation text", function()
    TestRunner:assertEqual(
        DOIResolver.matchDOI("NeuroImage, 270 (2023) 119955. doi:10.1016/j.neuroimage.2023.119955"),
        "10.1016/j.neuroimage.2023.119955"
    )
end)

TestRunner:test("DOI with complex suffix", function()
    TestRunner:assertEqual(
        DOIResolver.matchDOI("10.1073/pnas.0602173103"),
        "10.1073/pnas.0602173103"
    )
end)

TestRunner:suite("matchDOI — trailing punctuation stripping")

TestRunner:test("strips trailing period", function()
    TestRunner:assertEqual(DOIResolver.matchDOI("10.1234/abc."), "10.1234/abc")
end)

TestRunner:test("strips trailing comma", function()
    TestRunner:assertEqual(DOIResolver.matchDOI("10.1234/abc,"), "10.1234/abc")
end)

TestRunner:test("strips trailing semicolon", function()
    TestRunner:assertEqual(DOIResolver.matchDOI("10.1234/abc;"), "10.1234/abc")
end)

TestRunner:test("strips trailing closing paren", function()
    TestRunner:assertEqual(DOIResolver.matchDOI("(doi:10.1234/abc)"), "10.1234/abc")
end)

TestRunner:test("strips trailing closing bracket", function()
    TestRunner:assertEqual(DOIResolver.matchDOI("[10.1234/abc]"), "10.1234/abc")
end)

TestRunner:test("strips multiple trailing punctuation", function()
    TestRunner:assertEqual(DOIResolver.matchDOI("10.1234/abc.)."), "10.1234/abc")
end)

TestRunner:test("preserves internal periods", function()
    TestRunner:assertEqual(
        DOIResolver.matchDOI("10.1016/j.neuroimage.2023.119955"),
        "10.1016/j.neuroimage.2023.119955"
    )
end)

TestRunner:suite("matchDOI — edge cases and nil handling")

TestRunner:test("returns nil for nil input", function()
    TestRunner:assertNil(DOIResolver.matchDOI(nil))
end)

TestRunner:test("returns nil for empty string", function()
    TestRunner:assertNil(DOIResolver.matchDOI(""))
end)

TestRunner:test("returns nil for text without DOI", function()
    TestRunner:assertNil(DOIResolver.matchDOI("This is just regular text"))
end)

TestRunner:test("returns nil for citation-format string (no DOI)", function()
    -- Royal Society puts citation format in Subject, not DOI
    TestRunner:assertNil(DOIResolver.matchDOI("Phil. Trans. R. Soc. B 2014.369:20130299"))
end)

TestRunner:test("returns nil for short registrant (3 digits)", function()
    TestRunner:assertNil(DOIResolver.matchDOI("10.123/too-short"))
end)

TestRunner:test("returns first DOI when multiple present", function()
    local result = DOIResolver.matchDOI("10.1234/first 10.5678/second")
    TestRunner:assertEqual(result, "10.1234/first")
end)

TestRunner:test("handles DOI at end of string", function()
    TestRunner:assertEqual(
        DOIResolver.matchDOI("see 10.1234/end-of-string"),
        "10.1234/end-of-string"
    )
end)

TestRunner:suite("matchDOI — real-world DOI formats")

TestRunner:test("Elsevier DOI", function()
    TestRunner:assertEqual(
        DOIResolver.matchDOI("10.1016/j.neuroimage.2023.119955"),
        "10.1016/j.neuroimage.2023.119955"
    )
end)

TestRunner:test("Royal Society DOI", function()
    TestRunner:assertEqual(
        DOIResolver.matchDOI("10.1098/rstb.2013.0299"),
        "10.1098/rstb.2013.0299"
    )
end)

TestRunner:test("Wiley DOI with eLocator", function()
    TestRunner:assertEqual(
        DOIResolver.matchDOI("10.1111/cogs.13230"),
        "10.1111/cogs.13230"
    )
end)

TestRunner:test("ACL Anthology DOI", function()
    TestRunner:assertEqual(
        DOIResolver.matchDOI("10.18653/v1/2020.acl-main.463"),
        "10.18653/v1/2020.acl-main.463"
    )
end)

TestRunner:test("PNAS DOI", function()
    TestRunner:assertEqual(
        DOIResolver.matchDOI("10.1073/pnas.0602173103"),
        "10.1073/pnas.0602173103"
    )
end)

TestRunner:test("Cambridge DOI with S-prefix", function()
    TestRunner:assertEqual(
        DOIResolver.matchDOI("10.1017/S0140525X0999094X"),
        "10.1017/S0140525X0999094X"
    )
end)

-- ============================================================
-- extractDOI()
-- ============================================================

TestRunner:suite("extractDOI — metadata field priority")

TestRunner:test("extracts from identifiers (highest priority)", function()
    local result = DOIResolver.extractDOI({
        identifiers = "doi:10.1234/from-identifiers",
        description = "doi:10.1234/from-description",
        keywords = "doi:10.1234/from-keywords",
    })
    TestRunner:assertEqual(result, "10.1234/from-identifiers")
end)

TestRunner:test("falls back to description when no identifiers", function()
    local result = DOIResolver.extractDOI({
        description = "NeuroImage, 270 (2023) 119955. doi:10.1016/j.neuroimage.2023.119955",
    })
    TestRunner:assertEqual(result, "10.1016/j.neuroimage.2023.119955")
end)

TestRunner:test("falls back to keywords when no identifiers or description match", function()
    local result = DOIResolver.extractDOI({
        description = "Some text without a DOI",
        keywords = "keyword1; 10.5678/in-keywords",
    })
    TestRunner:assertEqual(result, "10.5678/in-keywords")
end)

TestRunner:test("returns nil when no fields contain DOI", function()
    TestRunner:assertNil(DOIResolver.extractDOI({
        description = "Phil. Trans. R. Soc. B 2014.369:20130299",
        keywords = "language; cognition; evolution",
    }))
end)

TestRunner:test("returns nil for nil doc_props", function()
    TestRunner:assertNil(DOIResolver.extractDOI(nil))
end)

TestRunner:test("returns nil for empty doc_props", function()
    TestRunner:assertNil(DOIResolver.extractDOI({}))
end)

TestRunner:test("handles missing fields gracefully", function()
    TestRunner:assertNil(DOIResolver.extractDOI({ title = "Some Book" }))
end)

-- ============================================================
-- extractDOIFromPage()
-- ============================================================

TestRunner:suite("extractDOIFromPage — page text extraction")

TestRunner:test("extracts DOI from string page text", function()
    local mock_doc = {
        getPageText = function(self, page)
            return "Header text doi:10.1098/rstb.2013.0299 footer text"
        end,
    }
    TestRunner:assertEqual(DOIResolver.extractDOIFromPage(mock_doc), "10.1098/rstb.2013.0299")
end)

TestRunner:test("extracts DOI from structured PDF text (blocks/spans)", function()
    local mock_doc = {
        getPageText = function(self, page)
            return {
                { -- block 1
                    { word = "Research" },
                    { word = "Article" },
                },
                { -- block 2
                    { word = "doi:10.1016/j.neuroimage.2023.119955" },
                },
                { -- block 3
                    { word = "Published" },
                    { word = "2023" },
                },
            }
        end,
    }
    TestRunner:assertEqual(DOIResolver.extractDOIFromPage(mock_doc), "10.1016/j.neuroimage.2023.119955")
end)

TestRunner:test("returns nil when page has no DOI", function()
    local mock_doc = {
        getPageText = function(self, page)
            return "Just regular text on page 1 without any identifier"
        end,
    }
    TestRunner:assertNil(DOIResolver.extractDOIFromPage(mock_doc))
end)

TestRunner:test("returns nil when getPageText throws", function()
    local mock_doc = {
        getPageText = function(self, page)
            error("page extraction failed")
        end,
    }
    TestRunner:assertNil(DOIResolver.extractDOIFromPage(mock_doc))
end)

TestRunner:test("returns nil when getPageText returns nil", function()
    local mock_doc = {
        getPageText = function(self, page)
            return nil
        end,
    }
    TestRunner:assertNil(DOIResolver.extractDOIFromPage(mock_doc))
end)

TestRunner:test("returns nil for empty table page text", function()
    local mock_doc = {
        getPageText = function(self, page)
            return {}
        end,
    }
    TestRunner:assertNil(DOIResolver.extractDOIFromPage(mock_doc))
end)

TestRunner:test("handles mixed block types (some without word field)", function()
    local mock_doc = {
        getPageText = function(self, page)
            return {
                { -- block with non-word entries
                    { x = 10, y = 20 },
                    { word = "10.1234/mixed-block" },
                },
            }
        end,
    }
    TestRunner:assertEqual(DOIResolver.extractDOIFromPage(mock_doc), "10.1234/mixed-block")
end)

-- ============================================================
-- resolveDOI() — resolution order and caching
-- ============================================================

TestRunner:suite("resolveDOI — resolution order")

-- Mock doc_settings for testing cache behavior
local function makeMockSettings(data)
    local store = data or {}
    return {
        has = function(self, key)
            return store[key] ~= nil
        end,
        readSetting = function(self, key)
            return store[key]
        end,
        saveSetting = function(self, key, value)
            store[key] = value
        end,
        flush = function(self) end,
        _store = store,
    }
end

TestRunner:test("returns cached DOI from doc_settings", function()
    local settings = makeMockSettings({ koassistant_doi = "10.1234/cached" })
    local result = DOIResolver.resolveDOI(nil, nil, nil, settings)
    TestRunner:assertEqual(result, "10.1234/cached")
end)

TestRunner:test("returns nil for false sentinel (scanned, not found)", function()
    local settings = makeMockSettings({ koassistant_doi = false })
    local result = DOIResolver.resolveDOI(nil, nil, nil, settings)
    TestRunner:assertNil(result)
end)

TestRunner:test("metadata takes priority over text scan when both available", function()
    local doc_props = { description = "doi:10.1234/from-metadata" }
    local mock_doc = {
        getPageText = function(self, page)
            return "doi:10.5678/from-page-text"
        end,
    }
    local settings = makeMockSettings({})
    local result = DOIResolver.resolveDOI(nil, doc_props, mock_doc, settings)
    TestRunner:assertEqual(result, "10.1234/from-metadata")
end)

TestRunner:test("falls back to text scan when metadata has no DOI", function()
    local doc_props = { description = "No DOI here" }
    local mock_doc = {
        getPageText = function(self, page)
            return "doi:10.5678/from-page-text"
        end,
    }
    local settings = makeMockSettings({})
    local result = DOIResolver.resolveDOI(nil, doc_props, mock_doc, settings)
    TestRunner:assertEqual(result, "10.5678/from-page-text")
end)

TestRunner:test("returns nil when no sources have DOI and no document", function()
    local doc_props = { description = "No DOI" }
    local settings = makeMockSettings({})
    local result = DOIResolver.resolveDOI(nil, doc_props, nil, settings)
    TestRunner:assertNil(result)
    -- Should NOT cache false when no document (file browser gap)
    TestRunner:assertEqual(settings:has("koassistant_doi"), false, "should not cache without document")
end)

TestRunner:suite("resolveDOI — caching behavior")

TestRunner:test("caches DOI found from metadata", function()
    local doc_props = { identifiers = "10.1234/cached-from-meta" }
    local settings = makeMockSettings({})
    DOIResolver.resolveDOI(nil, doc_props, nil, settings)
    TestRunner:assertEqual(settings._store.koassistant_doi, "10.1234/cached-from-meta")
end)

TestRunner:test("caches DOI found from text scan", function()
    local mock_doc = {
        getPageText = function(self, page)
            return "doi:10.1234/cached-from-scan"
        end,
    }
    local settings = makeMockSettings({})
    DOIResolver.resolveDOI(nil, nil, mock_doc, settings)
    TestRunner:assertEqual(settings._store.koassistant_doi, "10.1234/cached-from-scan")
end)

TestRunner:test("caches false sentinel when text scan finds no DOI", function()
    local mock_doc = {
        getPageText = function(self, page)
            return "No DOI on this page"
        end,
    }
    local settings = makeMockSettings({})
    DOIResolver.resolveDOI(nil, nil, mock_doc, settings)
    TestRunner:assertEqual(settings._store.koassistant_doi, false, "should cache false sentinel")
end)

TestRunner:test("does not cache when no document and no metadata DOI", function()
    local settings = makeMockSettings({})
    DOIResolver.resolveDOI(nil, { description = "no doi" }, nil, settings)
    TestRunner:assertEqual(settings:has("koassistant_doi"), false, "should not cache")
end)

TestRunner:test("cache prevents re-scanning", function()
    local scan_count = 0
    local mock_doc = {
        getPageText = function(self, page)
            scan_count = scan_count + 1
            return "doi:10.1234/scan-once"
        end,
    }
    local settings = makeMockSettings({})
    -- First call: scans and caches
    DOIResolver.resolveDOI(nil, nil, mock_doc, settings)
    TestRunner:assertEqual(scan_count, 1)
    -- Second call: reads from cache
    DOIResolver.resolveDOI(nil, nil, mock_doc, settings)
    TestRunner:assertEqual(scan_count, 1, "should not re-scan")
end)

-- ============================================================
-- buildBookMetadata()
-- ============================================================

TestRunner:suite("buildBookMetadata")

TestRunner:test("builds metadata with DOI from doc_props", function()
    local result = DOIResolver.buildBookMetadata(
        "Test Title", "Test Author", "/path/to/file",
        { identifiers = "10.1234/test-doi" }, nil, makeMockSettings({})
    )
    TestRunner:assertEqual(result.title, "Test Title")
    TestRunner:assertEqual(result.author, "Test Author")
    TestRunner:assertEqual(result.author_clause, " by Test Author")
    TestRunner:assertEqual(result.doi, "10.1234/test-doi")
    TestRunner:assertEqual(result.doi_clause, "\nDOI: 10.1234/test-doi")
end)

TestRunner:test("builds metadata without DOI (fiction book)", function()
    local result = DOIResolver.buildBookMetadata(
        "A Novel", "Some Author", "/path/to/novel",
        { description = "A great story" }, nil, makeMockSettings({})
    )
    TestRunner:assertNil(result.doi)
    TestRunner:assertEqual(result.doi_clause, "")
end)

TestRunner:test("handles nil title", function()
    local result = DOIResolver.buildBookMetadata(nil, "Author", nil, nil, nil, nil)
    TestRunner:assertEqual(result.title, "Unknown")
end)

TestRunner:test("handles nil authors", function()
    local result = DOIResolver.buildBookMetadata("Title", nil, nil, nil, nil, nil)
    TestRunner:assertEqual(result.author, "")
    TestRunner:assertEqual(result.author_clause, "")
end)

TestRunner:test("handles empty authors", function()
    local result = DOIResolver.buildBookMetadata("Title", "", nil, nil, nil, nil)
    TestRunner:assertEqual(result.author_clause, "")
end)

TestRunner:test("preserves file path", function()
    local result = DOIResolver.buildBookMetadata("T", "A", "/some/path.pdf", nil, nil, makeMockSettings({}))
    TestRunner:assertEqual(result.file, "/some/path.pdf")
end)

-- ============================================================
-- Summary
-- ============================================================

print("")
print(string.rep("-", 50))
print(string.format("  Results: %d passed, %d failed", TestRunner.passed, TestRunner.failed))
print(string.rep("-", 50))

if TestRunner.failed > 0 then
    os.exit(1)
end
