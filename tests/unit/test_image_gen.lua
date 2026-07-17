--[[
Unit Tests for image generation (PR #96 polish)

Covers:
- ModelLists image-model inventory (getImageModels/getDefaultImageModel)
- BaseHandler.getApiKey / isPlaceholderKey (shared key resolution)
- ImageGenerator.effectiveProvider resolution chain:
  explicit image_gen_provider > image-capable main provider; key required;
  no fallback to merely-keyed providers
- Book-association index (agenda 2b): recordImage/readIndex roundtrip,
  booksWithImages join + stale pruning, removeIndexEntries,
  updateIndexForMove move/delete/copy semantics

Run: lua tests/run_tests.lua --unit
]]

-- Setup test environment
package.path = package.path .. ";./?.lua;./?/init.lua"
require("tests.lib.mock_koreader")

-- luasocket's mime module is not in the shared mock; the image generator only
-- calls it at response time, so a passthrough stub is enough here
package.loaded["mime"] = {
    b64 = function(s) return s end,
    unb64 = function(s) return s end,
}

local ModelLists = require("koassistant_model_lists")
local BaseHandler = require("koassistant_api.base")
local ImageGenerator = require("koassistant_image_generator")

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

-- Helpers -------------------------------------------------------------------

local function mockSettings(features)
    return {
        readSetting = function(_self, key)
            if key == "features" then return features end
            return nil
        end,
    }
end

local function withApikeys(keys, fn)
    local prev = package.loaded["apikeys"]
    package.loaded["apikeys"] = keys
    local ok, err = pcall(fn)
    package.loaded["apikeys"] = prev
    if not ok then error(err, 0) end
end

-- Index test helpers ---------------------------------------------------------
-- The index helpers lazily require("luasettings") per call, so an in-memory
-- mock can be swapped in around each test. Image files are real files under
-- the mock datastorage dir (booksWithImages joins index against directory).

local IMAGES_DIR = "/tmp/koreader/koassistant_images"

local index_store  -- in-memory backing for the mocked LuaSettings

local MockLuaSettings = {
    open = function(_self, path)
        index_store[path] = index_store[path] or {}
        local data = index_store[path]
        return {
            readSetting = function(_s, key) return data[key] end,
            saveSetting = function(_s, key, val) data[key] = val end,
            flush = function() end,
        }
    end,
}

local function touchFile(name)
    local f = assert(io.open(IMAGES_DIR .. "/" .. name, "w"))
    f:write("png")
    f:close()
end

--- Run fn with a fresh images dir + in-memory index store
local function withImageIndex(fn)
    local prev = package.loaded["luasettings"]
    package.loaded["luasettings"] = MockLuaSettings
    index_store = {}
    os.execute('rm -rf "' .. IMAGES_DIR .. '" && mkdir -p "' .. IMAGES_DIR .. '"')
    -- updateIndexForMove stat-guards on the index file existing on disk
    touchFile(ImageGenerator.getIndexFilename())
    local ok, err = pcall(fn)
    package.loaded["luasettings"] = prev
    os.execute('rm -rf "' .. IMAGES_DIR .. '"')
    if not ok then error(err, 0) end
end

-- Tests ----------------------------------------------------------------------

local function runAll()
    print("  Unit Tests: Image generation")

    print("  [ModelLists image-model inventory]")
    TestRunner:test("image-capable providers have model lists with a default", function()
        for _idx, provider in ipairs({ "openai", "xai", "gemini" }) do
            local list = ModelLists.getImageModels(provider)
            TestRunner:assert(type(list) == "table" and #list > 0,
                provider .. " has a non-empty image model list")
            TestRunner:assertEquals(ModelLists.getDefaultImageModel(provider), list[1],
                provider .. " default = first list entry")
        end
    end)
    TestRunner:test("non-image providers return nil", function()
        TestRunner:assertEquals(ModelLists.getImageModels("anthropic"), nil)
        TestRunner:assertEquals(ModelLists.getDefaultImageModel("anthropic"), nil)
    end)
    TestRunner:test("_image_models is skipped by provider iteration", function()
        for _idx, p in ipairs(ModelLists.getAllProviders()) do
            TestRunner:assert(p ~= "_image_models", "_image_models leaked into getAllProviders")
        end
    end)

    print("  [BaseHandler.getApiKey / isPlaceholderKey]")
    TestRunner:test("placeholder keys are rejected", function()
        TestRunner:assertEquals(BaseHandler.isPlaceholderKey("YOUR_OPENAI_API_KEY"), true)
        TestRunner:assertEquals(BaseHandler.isPlaceholderKey("put-key-_HERE"), true)
        TestRunner:assertEquals(BaseHandler.isPlaceholderKey(""), true)
        TestRunner:assertEquals(BaseHandler.isPlaceholderKey(nil), true)
        TestRunner:assertEquals(BaseHandler.isPlaceholderKey("sk-real-key-123"), false)
    end)
    TestRunner:test("GUI key wins over apikeys.lua and is trimmed", function()
        withApikeys({ openai = "sk-file-key" }, function()
            local settings = mockSettings({ api_keys = { openai = "  sk-gui-key \n" } })
            TestRunner:assertEquals(BaseHandler.getApiKey("openai", settings), "sk-gui-key")
        end)
    end)
    TestRunner:test("falls back to apikeys.lua; placeholders ignored", function()
        withApikeys({ openai = "sk-file-key", xai = "YOUR_XAI_API_KEY" }, function()
            local settings = mockSettings({})
            TestRunner:assertEquals(BaseHandler.getApiKey("openai", settings), "sk-file-key")
            TestRunner:assertEquals(BaseHandler.getApiKey("xai", settings), nil)
        end)
    end)

    print("  [ImageGenerator.effectiveProvider]")
    TestRunner:test("auto: follows image-capable main provider", function()
        withApikeys({ openai = "sk-file-key" }, function()
            local settings = mockSettings({})
            local p = ImageGenerator.effectiveProvider({}, "openai", settings)
            TestRunner:assertEquals(p, "openai")
        end)
    end)
    TestRunner:test("auto: nil for non-image main provider (no key hunting)", function()
        withApikeys({ openai = "sk-file-key" }, function()
            local settings = mockSettings({})
            local p, reason = ImageGenerator.effectiveProvider({}, "anthropic", settings)
            TestRunner:assertEquals(p, nil)
            TestRunner:assertEquals(reason, "no_endpoint")
        end)
    end)
    TestRunner:test("explicit provider overrides main provider", function()
        withApikeys({ xai = "xai-real-key" }, function()
            local settings = mockSettings({})
            local p = ImageGenerator.effectiveProvider(
                { image_gen_provider = "xai" }, "anthropic", settings)
            TestRunner:assertEquals(p, "xai")
        end)
    end)
    TestRunner:test("explicit provider without a key -> no_key", function()
        withApikeys({}, function()
            local settings = mockSettings({})
            local p, reason = ImageGenerator.effectiveProvider(
                { image_gen_provider = "gemini" }, "openai", settings)
            TestRunner:assertEquals(p, nil)
            TestRunner:assertEquals(reason, "no_key")
        end)
    end)
    TestRunner:test("explicit 'auto' sentinel behaves like nil", function()
        withApikeys({ openai = "sk-file-key" }, function()
            local settings = mockSettings({})
            local p = ImageGenerator.effectiveProvider(
                { image_gen_provider = "auto" }, "openai", settings)
            TestRunner:assertEquals(p, "openai")
        end)
    end)
    TestRunner:test("nil main provider -> no_endpoint", function()
        local p, reason = ImageGenerator.effectiveProvider({}, nil, mockSettings({}))
        TestRunner:assertEquals(p, nil)
        TestRunner:assertEquals(reason, "no_endpoint")
    end)

    print("  [Images index: book associations]")
    TestRunner:test("recordImage → readIndex roundtrip; no-op without book info", function()
        withImageIndex(function()
            ImageGenerator.recordImage("a.png",
                { file = "/books/b1.epub", title = "Book One" }, "a castle")
            ImageGenerator.recordImage("b.png", nil, "ignored")
            local index = ImageGenerator.readIndex()
            TestRunner:assertEquals(index["a.png"].book_file, "/books/b1.epub")
            TestRunner:assertEquals(index["a.png"].book_title, "Book One")
            TestRunner:assertEquals(index["a.png"].prompt, "a castle")
            TestRunner:assert(type(index["a.png"].created) == "number", "created timestamp set")
            TestRunner:assertEquals(index["b.png"], nil)
        end)
    end)
    TestRunner:test("booksWithImages counts per book and prunes stale entries", function()
        withImageIndex(function()
            touchFile("a.png")
            touchFile("b.png")
            ImageGenerator.recordImage("a.png", { file = "/books/b1.epub", title = "Book One" }, "p1")
            ImageGenerator.recordImage("b.png", { file = "/books/b1.epub", title = "Book One" }, "p2")
            ImageGenerator.recordImage("gone.png", { file = "/books/b2.epub", title = "Book Two" }, "p3")
            local books = ImageGenerator.booksWithImages()
            TestRunner:assertEquals(books["/books/b1.epub"].count, 2)
            TestRunner:assertEquals(books["/books/b1.epub"].book_title, "Book One")
            TestRunner:assert(books["/books/b1.epub"].modified > 0, "modified from created timestamps")
            TestRunner:assertEquals(books["/books/b2.epub"], nil, "stale entry not counted")
            TestRunner:assertEquals(ImageGenerator.readIndex()["gone.png"], nil, "stale entry pruned")
        end)
    end)
    TestRunner:test("removeIndexEntries removes only the listed names", function()
        withImageIndex(function()
            ImageGenerator.recordImage("a.png", { file = "/books/b1.epub" }, "p1")
            ImageGenerator.recordImage("b.png", { file = "/books/b1.epub" }, "p2")
            ImageGenerator.removeIndexEntries({ "a.png", "never-there.png" })
            local index = ImageGenerator.readIndex()
            TestRunner:assertEquals(index["a.png"], nil)
            TestRunner:assert(index["b.png"] ~= nil, "unrelated entry kept")
        end)
    end)
    TestRunner:test("updateIndexForMove: move rewrites, delete unassigns, copy no-ops", function()
        withImageIndex(function()
            ImageGenerator.recordImage("a.png", { file = "/books/b1.epub" }, "p1")
            ImageGenerator.recordImage("b.png", { file = "/books/b2.epub" }, "p2")
            -- copy: images stay with the original book
            ImageGenerator.updateIndexForMove("/books/b1.epub", "/copied/b1.epub", true)
            TestRunner:assertEquals(ImageGenerator.readIndex()["a.png"].book_file, "/books/b1.epub")
            -- move: association follows the book
            ImageGenerator.updateIndexForMove("/books/b1.epub", "/moved/b1.epub", false)
            TestRunner:assertEquals(ImageGenerator.readIndex()["a.png"].book_file, "/moved/b1.epub")
            -- delete: association dropped (image becomes global-only)
            ImageGenerator.updateIndexForMove("/books/b2.epub", nil, false)
            TestRunner:assertEquals(ImageGenerator.readIndex()["b.png"], nil)
            TestRunner:assert(ImageGenerator.readIndex()["a.png"] ~= nil, "other book untouched")
        end)
    end)

    print(string.format("  Results: %d passed, %d failed", TestRunner.passed, TestRunner.failed))
    return TestRunner.failed == 0
end

-- Run tests if executed directly
if arg and arg[0] and arg[0]:match("test_image_gen%.lua$") then
    local success = runAll()
    os.exit(success and 0 or 1)
end

return {
    runAll = runAll,
    TestRunner = TestRunner,
}
