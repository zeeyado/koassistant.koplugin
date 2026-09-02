--[[
Unit tests: SafeDocSettings.overlayCustomProps (effective book props)

KOReader keeps a title/authors edited in Book information in the sidecar's
custom_metadata.lua and never rewrites metadata.lua's doc_props. Every plugin
site that turns doc_props into a title/author must overlay it. Tests:
- overlay applied when a custom metadata file exists (custom wins per field)
- raw table returned untouched when there is no custom file
- nil raw + custom file = the custom props; nil raw + nothing = nil
- missing KOReader modules degrade to the raw props (never throw)
- STRUCTURAL GATE: every readSetting("doc_props") line in the plugin is
  either overlaid on that line, feeds the chat index (has_props/indexTitleAuthor),
  or carries an explicit "-- raw-props:" reason. This is the test that would
  have caught the 2026-09-02 gap (20 closed-book sites showing the original
  title after an edit in KOReader).

Run: lua tests/run_tests.lua --unit
]]

local plugin_dir
local function setupPaths()
    local info = debug.getinfo(1, "S")
    local script_path = info.source:match("@?(.*)")
    local unit_dir = script_path:match("(.+)/[^/]+$") or "."
    local tests_dir = unit_dir:match("(.+)/[^/]+$") or "."
    plugin_dir = tests_dir:match("(.+)/[^/]+$") or "."
    package.path = table.concat({
        plugin_dir .. "/?.lua",
        tests_dir .. "/?.lua",
        tests_dir .. "/lib/?.lua",
        package.path,
    }, ";")
end
setupPaths()

require("mock_koreader")

local TestRunner = { passed = 0, failed = 0 }
function TestRunner:test(name, fn)
    local ok, err = pcall(fn)
    if ok then
        self.passed = self.passed + 1
        print(string.format("    ✓ %s", name))
    else
        self.failed = self.failed + 1
        print(string.format("    ✗ %s\n      %s", name, tostring(err)))
    end
end
function TestRunner:assertEqual(actual, expected, message)
    if actual ~= expected then
        error(string.format("%s: expected '%s', got '%s'",
            message or "Assertion failed", tostring(expected), tostring(actual)), 2)
    end
end

-- ------------------------------------------------------------
-- Mocks: docsettings (custom-file lookup) + KOReader's BookInfo.extendProps
-- ------------------------------------------------------------
local custom_props = {}   -- path -> custom_props table (presence = file exists)
local saved_docsettings = package.loaded["docsettings"]
local saved_bookinfo = package.loaded["apps/filemanager/filemanagerbookinfo"]

local function installMocks()
    package.loaded["docsettings"] = {
        findCustomMetadataFile = function(_self, path)
            return custom_props[path] and ("/mock" .. path .. ".sdr/custom_metadata.lua") or nil
        end,
    }
    -- Same shape as KOReader's: per-field custom-over-original, plus display_title
    package.loaded["apps/filemanager/filemanagerbookinfo"] = {
        extendProps = function(original, filepath)
            local custom = custom_props[filepath] or {}
            original = original or {}
            local props = {}
            for _idx, key in ipairs({ "title", "authors", "series", "series_index", "language", "keywords", "description" }) do
                props[key] = custom[key] or original[key]
            end
            props.display_title = props.title or filepath:match("([^/]+)%.[^%.]+$")
            return props
        end,
    }
end
installMocks()

package.loaded["koassistant_doc_settings"] = nil
local SafeDocSettings = require("koassistant_doc_settings")

print("\n  -- overlayCustomProps --")

TestRunner:test("custom metadata wins per field, untouched fields keep the original", function()
    custom_props["/books/a.epub"] = { title = "Edited" }
    local props = SafeDocSettings.overlayCustomProps(
        { title = "Original", authors = "Someone", identifiers = "doi:x" }, "/books/a.epub")
    TestRunner:assertEqual(props.title, "Edited", "custom title")
    TestRunner:assertEqual(props.authors, "Someone", "original author kept")
    TestRunner:assertEqual(props.display_title, "Edited", "display_title follows")
    TestRunner:assertEqual(props.identifiers, nil, "overlay filters identifiers (DOI must read raw)")
    custom_props["/books/a.epub"] = nil
end)

TestRunner:test("no custom file: the raw table comes back untouched", function()
    local raw = { title = "Original" }
    TestRunner:assertEqual(SafeDocSettings.overlayCustomProps(raw, "/books/b.epub"), raw, "same table")
end)

TestRunner:test("nil raw: custom file yields the custom props, nothing yields nil", function()
    custom_props["/books/c.epub"] = { title = "Only custom" }
    local props = SafeDocSettings.overlayCustomProps(nil, "/books/c.epub")
    TestRunner:assertEqual(props and props.title, "Only custom", "custom title from nil raw")
    custom_props["/books/c.epub"] = nil
    TestRunner:assertEqual(SafeDocSettings.overlayCustomProps(nil, "/books/c.epub"), nil, "nil stays nil")
end)

TestRunner:test("nil path: raw returned", function()
    local raw = { title = "x" }
    TestRunner:assertEqual(SafeDocSettings.overlayCustomProps(raw, nil), raw, "no path = no overlay")
end)

TestRunner:test("missing KOReader modules degrade to raw, never throw", function()
    custom_props["/books/d.epub"] = { title = "Edited" }
    local raw = { title = "Original" }
    package.loaded["apps/filemanager/filemanagerbookinfo"] = nil
    package.preload["apps/filemanager/filemanagerbookinfo"] = function() error("not available") end
    TestRunner:assertEqual(SafeDocSettings.overlayCustomProps(raw, "/books/d.epub"), raw,
        "no BookInfo = raw")
    package.preload["apps/filemanager/filemanagerbookinfo"] = nil
    package.loaded["docsettings"] = { }  -- no findCustomMetadataFile
    TestRunner:assertEqual(SafeDocSettings.overlayCustomProps(raw, "/books/d.epub"), raw,
        "no custom-file lookup = raw")
    installMocks()
    custom_props["/books/d.epub"] = nil
end)

-- ------------------------------------------------------------
-- Structural gate over the plugin sources
-- ------------------------------------------------------------
print("\n  -- structural gate: no raw doc_props title reads --")

local function listLuaFiles()
    local files = {}
    for _idx, sub in ipairs({ "", "/koassistant_api", "/koassistant_ui", "/prompts" }) do
        local dir = plugin_dir .. sub
        local handle = io.popen('ls "' .. dir .. '"/*.lua 2>/dev/null')
        if handle then
            for line in handle:lines() do files[#files + 1] = line end
            handle:close()
        end
    end
    return files
end

TestRunner:test("every readSetting(\"doc_props\") line is overlaid, index-fed, or marked raw-props", function()
    local offenders = {}
    local files = listLuaFiles()
    assert(#files > 20, "source listing failed (" .. #files .. " files)")
    for _idx, path in ipairs(files) do
        local fh = io.open(path, "r")
        if fh then
            local n = 0
            for line in fh:lines() do
                n = n + 1
                if line:find('readSetting("doc_props")', 1, true)
                    and not line:find("overlayCustomProps(", 1, true)
                    and not line:find("has_props = true", 1, true)
                    and not line:find("indexTitleAuthor(", 1, true)
                    and not line:find("-- raw-props:", 1, true) then
                    offenders[#offenders + 1] = path:match("([^/]+)$") .. ":" .. n
                end
            end
            fh:close()
        end
    end
    if #offenders > 0 then
        error("raw doc_props reads without overlay (wrap in SafeDocSettings.overlayCustomProps "
            .. "or mark '-- raw-props: <reason>'):\n        " .. table.concat(offenders, "\n        "))
    end
end)

-- Cleanup
package.loaded["docsettings"] = saved_docsettings
package.loaded["apps/filemanager/filemanagerbookinfo"] = saved_bookinfo
package.loaded["koassistant_doc_settings"] = nil

print(string.format("\n  Effective props tests: %d passed, %d failed", TestRunner.passed, TestRunner.failed))
return TestRunner.failed == 0
