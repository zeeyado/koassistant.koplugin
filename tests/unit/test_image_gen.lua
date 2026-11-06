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

local ModelLists = require("koassistant.request.model_lists")
local BaseHandler = require("koassistant.api.base")
local ImageGenerator = require("koassistant.images.image_generator")

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

    print("  [When the chat provider cannot draw (S4)]")
    TestRunner:test("offered: the button shows for a text-only chat provider when an image key exists", function()
        withApikeys({ gemini = "gm-real-key", openrouter = "sk-or-real-key" }, function()
            local settings = mockSettings({})
            TestRunner:assertEquals(ImageGenerator.offered({}, "anthropic", settings), true)
            local keyed = ImageGenerator.keyedProviders(settings)
            TestRunner:assertEquals(table.concat(keyed, ","), "gemini,openrouter", "keyed only, the settings' order")
            TestRunner:assertEquals(ImageGenerator.offered({ image_gen_provider = "auto" }, "deepseek", settings), true)
            TestRunner:assertEquals(ImageGenerator.offered({ image_gen_provider = "openai" }, "anthropic", settings), false,
                "an explicit pick without a key stays hidden")
            TestRunner:assertEquals(ImageGenerator.offered({}, "openai", settings), false,
                "a chat provider that can draw but has no key: hidden, as before")
        end)
        withApikeys({}, function()
            TestRunner:assertEquals(ImageGenerator.offered({}, "anthropic", mockSettings({})), false, "no key at all")
        end)
    end)
    TestRunner:test("the first tap asks; a pick is saved as Provider and the run goes on; Cancel saves nothing", function()
        withApikeys({ gemini = "gm-real-key", xai = "xai-real-key" }, function()
            local stored = {}
            local settings = {
                readSetting = function(_self, key) return key == "features" and stored or nil end,
                saveSetting = function(_self, key, val) if key == "features" then stored = val end end,
                flush = function() end,
            }
            local UIManager = require("ui/uimanager")
            local real_show, real_generate = UIManager.show, ImageGenerator.generate
            local shown, reran = {}, nil
            UIManager.show = function(_self, w) shown[#shown + 1] = w end
            ImageGenerator.generate = function(word, config) reran = { word = word, config = config } end
            local ok, err = pcall(function()
                local config = { provider = "anthropic", features = {} }
                ImageGenerator._generateImpl("a castle", config, settings, nil, {})
                local dialog = shown[1]
                TestRunner:assert(dialog and dialog.title:find("can't make images", 1, true), "the question")
                TestRunner:assertEquals(#dialog.buttons, 3, "the two keyed providers and Cancel")
                TestRunner:assertEquals(dialog.buttons[1][1].text, "xAI (Grok)")
                dialog.buttons[3][1].callback()  -- Cancel
                TestRunner:assertEquals(stored.image_gen_provider, nil, "Cancel saves nothing")
                TestRunner:assertEquals(reran, nil)
                ImageGenerator._generateImpl("a castle", config, settings, nil, {})
                shown[2].buttons[2][1].callback()  -- Gemini
                TestRunner:assertEquals(stored.image_gen_provider, "gemini", "saved as Provider")
                TestRunner:assertEquals(config.features.image_gen_provider, "gemini", "in effect now")
                TestRunner:assertEquals(reran and reran.word, "a castle", "the run goes on")
            end)
            UIManager.show, ImageGenerator.generate = real_show, real_generate
            if not ok then error(err, 0) end
        end)
    end)
    TestRunner:test("providerName: the image providers by brand, the others through the plugin", function()
        TestRunner:assertEquals(ImageGenerator.providerName("openrouter"), "OpenRouter")
        TestRunner:assertEquals(ImageGenerator.providerName("xai"), "xAI (Grok)")
        local plugin = { getProviderDisplayName = function(_self, id) return id == "anthropic" and "Anthropic" or id end }
        TestRunner:assertEquals(ImageGenerator.providerName("anthropic", plugin), "Anthropic")
        TestRunner:assertEquals(ImageGenerator.providerName("anthropic"), "anthropic", "no plugin: the id")
    end)

    print("  [Images index: book associations]")
    TestRunner:test("recordImage → readIndex roundtrip; a picture without a book is recorded too", function()
        withImageIndex(function()
            ImageGenerator.recordImage("a.png",
                { file = "/books/b1.epub", title = "Book One" }, "a castle")
            ImageGenerator.recordImage("b.png", nil, "a tower")
            local index = ImageGenerator.readIndex()
            TestRunner:assertEquals(index["a.png"].book_file, "/books/b1.epub")
            TestRunner:assertEquals(index["a.png"].book_title, "Book One")
            TestRunner:assertEquals(index["a.png"].prompt, "a castle")
            TestRunner:assert(type(index["a.png"].created) == "number", "created timestamp set")
            TestRunner:assertEquals(index["b.png"].prompt, "a tower", "its prompt kept for Regenerate (S7)")
            TestRunner:assertEquals(index["b.png"].book_file, nil)
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
    TestRunner:test("booksWithImages keeps a picture without a book, uncounted", function()
        withImageIndex(function()
            touchFile("a.png")
            ImageGenerator.recordImage("a.png", nil, "p1")
            local books = ImageGenerator.booksWithImages()
            TestRunner:assertEquals(next(books), nil, "no book counted")
            TestRunner:assertEquals(ImageGenerator.readIndex()["a.png"].prompt, "p1", "not pruned")
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
            -- delete: association dropped (image kept, with its prompt, as a
            -- picture without a book)
            ImageGenerator.updateIndexForMove("/books/b2.epub", nil, false)
            TestRunner:assertEquals(ImageGenerator.readIndex()["b.png"].book_file, nil)
            TestRunner:assertEquals(ImageGenerator.readIndex()["b.png"].prompt, "p2", "the prompt stays")
            TestRunner:assertEquals(ImageGenerator.readIndex()["a.png"].book_file, "/moved/b1.epub", "other book untouched")
        end)
    end)
    TestRunner:test("updateIndexForMove: a folder's move takes the pictures of every book inside (B507)", function()
        withImageIndex(function()
            ImageGenerator.recordImage("a.png", { file = "/books/Saga/b1.epub" }, "p1")
            ImageGenerator.recordImage("b.png", { file = "/books/Saga 2/b2.epub" }, "p2")
            ImageGenerator.recordImage("c.png", nil, "p3")
            ImageGenerator.updateIndexForMove("/books/Saga", "/books/Done", false, true)
            local index = ImageGenerator.readIndex()
            TestRunner:assertEquals(index["a.png"].book_file, "/books/Done/b1.epub", "inside: follows")
            TestRunner:assertEquals(index["b.png"].book_file, "/books/Saga 2/b2.epub", "a folder named alike: stays")
            TestRunner:assertEquals(index["c.png"].book_file, nil, "a picture without a book: stays so")
        end)
    end)

    -- The image round's S1 (docs/image_round_plan.md, 2026-10-14) ------------

    print("  [Image models: defaults and retired picks]")
    TestRunner:test("resolveImageModel: default, retired, explicit", function()
        TestRunner:assertEquals(ModelLists.resolveImageModel("openai", nil), "gpt-image-2.6-flare")
        TestRunner:assertEquals(ModelLists.resolveImageModel("openai", "default"), "gpt-image-2.6-flare")
        TestRunner:assertEquals(ModelLists.resolveImageModel("gemini", ""), "gemini-nano-banana-2.1")
        TestRunner:assertEquals(ModelLists.resolveImageModel("xai", "grok-imagine-image-quality"),
            "grok-imagine-image-2.0", "xAI serves the retired id with 2.0")
        TestRunner:assertEquals(ModelLists.resolveImageModel("xai", "grok-imagine-image-pro"), "grok-imagine-image-2.0")
        TestRunner:assertEquals(ModelLists.resolveImageModel("gemini", "gemini-3.1-flash-image"),
            "gemini-3.1-flash-image", "a pick that only left the picker is kept")
        TestRunner:assertEquals(ModelLists.resolveImageModel("openai", "gpt-image-1"), "gpt-image-2.5-flare", "shut down 2026-10-23: the 2.5 pair replaces it")
        TestRunner:assertEquals(ModelLists.resolveImageModel("openai", "gpt-image-2"), "gpt-image-2", "a pick that only left the default slot is kept")
    end)
    TestRunner:test("_image_retired is skipped by provider iteration", function()
        for _idx, p in ipairs(ModelLists.getAllProviders()) do
            TestRunner:assert(p ~= "_image_retired", "_image_retired leaked into getAllProviders")
        end
    end)

    print("  [The request as sent (B064)]")
    -- A 3:4 e-reader screen held upright, the one Fit my screen fits below
    local SCREEN = { w = 1264, h = 1680 }
    TestRunner:test("OpenAI: the defaults (Fit my screen, Draft), JPEG, no response_format", function()
        local r = ImageGenerator.buildRequest("openai", "gpt-image-2.5-flare", "p", {}, SCREEN)
        TestRunner:assertEquals(r.url, "https://api.openai.com/v1/images/generations")
        TestRunner:assertEquals(r.key_header, "Authorization")
        TestRunner:assertEquals(r.body.model, "gpt-image-2.5-flare")
        TestRunner:assertEquals(r.body.size, "1152x1536", "the 2.5 models draw the screen's own proportions")
        TestRunner:assertEquals(r.body.quality, "low", "Draft")
        TestRunner:assertEquals(r.body.output_format, "jpeg")
        TestRunner:assertEquals(r.body.response_format, nil, "gpt-image refuses response_format")
        TestRunner:assertEquals(r.body.n, 1)
    end)
    TestRunner:test("xAI: base64 answer, the nearest ratio its model takes", function()
        local r = ImageGenerator.buildRequest("xai", "grok-imagine-image", "p", {}, SCREEN)
        TestRunner:assertEquals(r.body.response_format, "b64_json")
        TestRunner:assertEquals(r.body.aspect_ratio, "3:4")
        TestRunner:assertEquals(r.body.size, nil, "xAI refuses size")
        TestRunner:assertEquals(r.body.quality, nil, "grok-imagine-image takes no quality")
        TestRunner:assertEquals(r.body.resolution, nil)
    end)
    TestRunner:test("Gemini: model in the path, image output, the Content Filter setting", function()
        local r = ImageGenerator.buildRequest("gemini", "gemini-nano-banana-2.1", "p", {}, SCREEN)
        TestRunner:assertEquals(r.url,
            "https://generativelanguage.googleapis.com/v1beta/models/gemini-nano-banana-2.1:generateContent")
        TestRunner:assertEquals(r.key_header, "x-goog-api-key")
        TestRunner:assertEquals(r.body.contents[1].parts[1].text, "p")
        TestRunner:assertEquals(r.body.generationConfig.responseModalities[1], "IMAGE")
        TestRunner:assertEquals(r.body.generationConfig.imageConfig.aspectRatio, "3:4")
        TestRunner:assertEquals(r.body.generationConfig.imageConfig.imageSize, "1K", "Draft")
        TestRunner:assert(type(r.body.safetySettings) == "table" and #r.body.safetySettings == 4,
            "the relaxed filter, as chat requests carry it")
        local g = ImageGenerator.buildRequest("gemini", "gemini-nano-banana-2.1", "p", { gemini_safety = "google" })
        TestRunner:assertEquals(g.body.safetySettings, nil, "Google's own filter: nothing sent")
    end)

    print("  [Shape and Detail (S2)]")
    TestRunner:test("Fit my screen follows the screen as it is held; 3:4 when none is known", function()
        TestRunner:assertEquals(ImageGenerator.shapeRatio("fit", { w = 1680, h = 1264 }), 1680 / 1264)
        TestRunner:assertEquals(ImageGenerator.shapeRatio("fit", nil), 3 / 4)
        TestRunner:assertEquals(ImageGenerator.shapeRatio(nil, SCREEN), 1264 / 1680, "unset = Fit my screen")
        TestRunner:assertEquals(ImageGenerator.shapeRatio("auto", SCREEN), nil)
        local landscape = ImageGenerator.buildRequest("openai", "gpt-image-2.5-flare", "p", {}, { w = 1680, h = 1264 })
        TestRunner:assertEquals(landscape.body.size, "1536x1152")
        local wide = ImageGenerator.buildRequest("gemini", "gemini-nano-banana-2.1", "p", {}, { w = 1920, h = 1080 })
        TestRunner:assertEquals(wide.body.generationConfig.imageConfig.aspectRatio, "16:9")
    end)
    TestRunner:test("OpenAI: a custom size only for Fit my screen on the 2.5 models, held to 1:3", function()
        local r = ImageGenerator.buildRequest("openai", "gpt-image-2", "p", {}, SCREEN)
        TestRunner:assertEquals(r.body.size, "1024x1536", "older models: the nearest common size")
        r = ImageGenerator.buildRequest("openai", "gpt-image-2.5-sunburst", "p", { image_gen_shape = "square" }, SCREEN)
        TestRunner:assertEquals(r.body.size, "1024x1024", "a fixed shape is a common size")
        r = ImageGenerator.buildRequest("openai", "gpt-image-2.5-flare", "p", {}, { w = 400, h = 2000 })
        TestRunner:assertEquals(r.body.size, "512x1536", "a 1:5 screen is held to 1:3")
        r = ImageGenerator.buildRequest("openai", "gpt-image-2.5-flare", "p", {}, { w = 1072, h = 1448 })
        TestRunner:assertEquals(r.body.size, "1136x1536", "steps of 16")
        r = ImageGenerator.buildRequest("openai", "gpt-image-2.5-flare", "p", { image_gen_shape = "auto" }, SCREEN)
        TestRunner:assertEquals(r.body.size, nil, "Let the model choose: no size")
    end)
    TestRunner:test("Detail: OpenAI's quality, Best is xhigh on the 2.5 models", function()
        local function q(model, detail)
            return ImageGenerator.buildRequest("openai", model, "p", { image_gen_detail = detail }, SCREEN).body.quality
        end
        TestRunner:assertEquals(q("gpt-image-2.5-flare", "standard"), "medium")
        TestRunner:assertEquals(q("gpt-image-2.5-flare", "best"), "xhigh")
        TestRunner:assertEquals(q("gpt-image-1-mini", "best"), "high")
        TestRunner:assertEquals(q("gpt-image-1-mini", "bogus"), "low", "an unknown value reads as Draft")
    end)
    TestRunner:test("Detail: xAI 2.0's quality and resolution; Gemini's size, not Flash Lite's", function()
        local x = ImageGenerator.buildRequest("xai", "grok-imagine-image-2.0", "p", { image_gen_detail = "best" }, SCREEN)
        TestRunner:assertEquals(x.body.quality, "medium")
        TestRunner:assertEquals(x.body.resolution, "2k")
        x = ImageGenerator.buildRequest("xai", "grok-imagine-image-2.0", "p", {}, SCREEN)
        TestRunner:assertEquals(x.body.quality, "low")
        TestRunner:assertEquals(x.body.resolution, "1k")
        local g = ImageGenerator.buildRequest("gemini", "gemini-3-pro-image", "p", { image_gen_detail = "best" }, SCREEN)
        TestRunner:assertEquals(g.body.generationConfig.imageConfig.imageSize, "2K")
        local lite = ImageGenerator.buildRequest("gemini", "gemini-3.1-flash-lite-image", "p",
            { image_gen_detail = "best" }, SCREEN)
        TestRunner:assertEquals(lite.body.generationConfig.imageConfig.imageSize, nil, "Flash Lite: 1K only")
        lite = ImageGenerator.buildRequest("gemini", "gemini-3.1-flash-lite-image", "p", { image_gen_shape = "auto" }, SCREEN)
        TestRunner:assertEquals(lite.body.generationConfig.imageConfig, nil, "nothing to say: no imageConfig")
    end)
    TestRunner:test("Draft: Gemini's thinking models think as little as they can; nothing above Draft", function()
        local function thinking(model, detail)
            local r = ImageGenerator.buildRequest("gemini", model, "p", { image_gen_detail = detail }, SCREEN)
            return r.body.generationConfig.thinkingConfig
        end
        TestRunner:assertEquals(thinking("gemini-nano-banana-2.1", nil).thinkingLevel, "minimal", "Draft is the default")
        TestRunner:assertEquals(thinking("gemini-3-pro-image", "draft").thinkingLevel, "minimal")
        TestRunner:assertEquals(thinking("gemini-nano-banana-2.1", "standard"), nil, "Standard: the model's own")
        TestRunner:assertEquals(thinking("gemini-3-pro-image", "best"), nil, "Best: the model's own")
        TestRunner:assertEquals(thinking("gemini-3.1-flash-lite-image", "draft"), nil, "Flash Lite does not think")
        TestRunner:assertEquals(thinking("gemini-nano-banana-2.2", "draft"), nil,
            "an id nobody probed gets nothing (a refused level is a 400)")
        local o = ImageGenerator.buildRequest("openrouter", "google/gemini-nano-banana-2.1", "p", {}, SCREEN)
        TestRunner:assertEquals(o.body.thinkingConfig, nil, "OpenRouter's Image API takes no thinking level")
        TestRunner:assertEquals(o.body.generationConfig, nil)
    end)
    TestRunner:test("pictureFacts: the models with one setting gray the Detail row", function()
        TestRunner:assertEquals(ImageGenerator.pictureFacts("xai", "grok-imagine-image").detail, false)
        TestRunner:assertEquals(ImageGenerator.pictureFacts("xai", "grok-imagine-image-2026-03-02").detail, false,
            "a dated id is 1.0")
        TestRunner:assertEquals(ImageGenerator.pictureFacts("xai", "grok-imagine-image-2.0").detail, true)
        TestRunner:assertEquals(ImageGenerator.pictureFacts("gemini", "gemini-3.1-flash-lite-image").detail, false)
        TestRunner:assertEquals(ImageGenerator.pictureFacts("gemini", "gemini-nano-banana-2.1").detail, true)
        TestRunner:assertEquals(ImageGenerator.pictureFacts("openai", "gpt-image-1").detail, true)
        local shapes = { portrait = true, landscape = true, square = true }
        for shape in pairs(shapes) do
            for _idx, p in ipairs({ "xai", "gemini" }) do
                local model = ModelLists.getDefaultImageModel(p)
                local r = ImageGenerator.buildRequest(p, model, "p", { image_gen_shape = shape }, SCREEN)
                local ratio = r.body.aspect_ratio or r.body.generationConfig.imageConfig.aspectRatio
                TestRunner:assertEquals(ratio, ({ portrait = "2:3", landscape = "3:2", square = "1:1" })[shape],
                    p .. " " .. shape)
            end
        end
    end)
    TestRunner:test("a provider with no image endpoint builds nothing", function()
        TestRunner:assertEquals(ImageGenerator.buildRequest("anthropic", "x", "p", {}), nil)
    end)

    print("  [OpenRouter (S3)]")
    TestRunner:test("OpenRouter's list and the default; it draws under Follow main provider", function()
        TestRunner:assertEquals(ModelLists.getDefaultImageModel("openrouter"), "openai/gpt-image-2.5-flare")
        TestRunner:assertEquals(#ModelLists.getImageModels("openrouter"), 6)
        withApikeys({ openrouter = "sk-or-real-key" }, function()
            local settings = mockSettings({})
            TestRunner:assertEquals(ImageGenerator.effectiveProvider({}, "openrouter", settings), "openrouter")
            TestRunner:assertEquals(ImageGenerator.effectiveProvider({ image_gen_provider = "openrouter" },
                "anthropic", settings), "openrouter")
        end)
    end)
    TestRunner:test("OpenRouter: the request at the defaults, the app's headers, no key in the body", function()
        local r = ImageGenerator.buildRequest("openrouter", "openai/gpt-image-2.5-flare", "p", {}, SCREEN)
        TestRunner:assertEquals(r.url, "https://openrouter.ai/api/v1/images")
        TestRunner:assertEquals(r.key_header, "Authorization")
        TestRunner:assertEquals(r.body.model, "openai/gpt-image-2.5-flare")
        TestRunner:assertEquals(r.body.aspect_ratio, "3:4", "Fit my screen: the nearest listed ratio")
        TestRunner:assertEquals(r.body.quality, "low", "Draft")
        TestRunner:assertEquals(r.body.output_format, "jpeg", "flare answers JPEG (probed)")
        TestRunner:assertEquals(r.body.resolution, nil, "flare lists no resolution")
        TestRunner:assertEquals(r.body.n, nil)
        TestRunner:assertEquals(r.headers["X-Title"], "KOAssistant")
    end)
    TestRunner:test("OpenRouter: Detail as each model's quality and resolution", function()
        local function body(model, detail, shape)
            return ImageGenerator.buildRequest("openrouter", model, "p",
                { image_gen_detail = detail, image_gen_shape = shape }, SCREEN).body
        end
        TestRunner:assertEquals(body("openai/gpt-image-2.5-flare", "standard").quality, "medium")
        TestRunner:assertEquals(body("openai/gpt-image-2.5-flare", "best").quality, "xhigh")
        local flux = body("black-forest-labs/flux-3-image", "draft")
        TestRunner:assertEquals(flux.resolution, "1K")
        TestRunner:assertEquals(flux.quality, nil)
        TestRunner:assertEquals(flux.output_format, nil, "FLUX 3 refuses output_format (probed)")
        TestRunner:assertEquals(body("black-forest-labs/flux-3-image", "best").resolution, "2K")
        local klein = body("black-forest-labs/flux-3-image-klein", "draft")
        TestRunner:assertEquals(klein.resolution, "1K", "Klein: as probed (6 s, $0.009)")
        TestRunner:assertEquals(klein.aspect_ratio, "3:4")
        TestRunner:assertEquals(klein.output_format, nil)
        TestRunner:assertEquals(body("black-forest-labs/flux-3-image-klein", "best").resolution, "2K")
        TestRunner:assertEquals(body("bytedance-seed/seedream-5-0-flash", "best").resolution, "2K")
        local recraft = body("recraft/recraft-v4.1-flash", "best", "landscape")
        TestRunner:assertEquals(recraft.resolution, nil)
        TestRunner:assertEquals(recraft.quality, nil)
        TestRunner:assertEquals(recraft.aspect_ratio, "4:3", "the nearest of the five it lists")
        TestRunner:assertEquals(body("google/gemini-nano-banana-2.1", "draft", "auto").aspect_ratio, nil,
            "Let the model choose: none")
    end)
    TestRunner:test("OpenRouter: a More models… pick takes its stored lists; the Detail row follows them", function()
        local features = { image_gen_openrouter_caps = { model = "x-ai/grok-imagine-image-2.0",
            ratios = { "1:1", "3:4", "auto" }, resolutions = { "1K", "2K" }, qualities = { "low", "medium" } } }
        features.image_gen_detail = "best"
        local b = ImageGenerator.buildRequest("openrouter", "x-ai/grok-imagine-image-2.0", "p", features, SCREEN).body
        TestRunner:assertEquals(b.aspect_ratio, "3:4")
        TestRunner:assertEquals(b.quality, "medium", "no xhigh or high: the best it lists")
        TestRunner:assertEquals(b.resolution, "2K")
        TestRunner:assertEquals(ImageGenerator.pictureFacts("openrouter", "x-ai/grok-imagine-image-2.0", features).detail,
            true)
        -- the stored lists belong to their model only
        local other = ImageGenerator.buildRequest("openrouter", "meta/muse-image", "p", features, SCREEN).body
        TestRunner:assertEquals(other.aspect_ratio, nil)
        TestRunner:assertEquals(other.quality, nil)
        TestRunner:assertEquals(ImageGenerator.pictureFacts("openrouter", "meta/muse-image", features).detail, false)
        TestRunner:assertEquals(ImageGenerator.pictureFacts("openrouter", "recraft/recraft-v4.1-flash").detail, false,
            "Recraft takes no Detail")
        TestRunner:assertEquals(ImageGenerator.pictureFacts("openrouter", "krea/krea-2-medium", { image_gen_openrouter_caps =
            { model = "krea/krea-2-medium", resolutions = { "1K" } } }).detail, false, "one resolution: no Detail")
    end)
    TestRunner:test("OpenRouter's catalog: models with their parameters; vector-only makers left out", function()
        local body = '{"data":['
            .. '{"id":"b/two","name":"B: Two","supported_parameters":{"aspect_ratio":{"type":"enum","values":["1:1","auto"]},'
            .. '"resolution":{"type":"enum","values":["768","1.5K"]},"n":{"type":"range","min":1,"max":1}}},'
            .. '{"id":"a/one","name":"A: One","supported_parameters":{"quality":{"type":"enum","values":["low","high"]}}},'
            .. '{"id":"r/vector","name":"R: Vector","supported_parameters":{"output_format":{"type":"enum","values":["svg"]}}},'
            .. '{"name":"no id"}]}'
        local models = ImageGenerator.parseOpenRouterCatalog(body)
        TestRunner:assertEquals(#models, 2)
        TestRunner:assertEquals(models[1].id, "a/one", "sorted by id")
        TestRunner:assertEquals(models[1].facts.qualities[2], "high")
        TestRunner:assertEquals(models[2].name, "B: Two")
        TestRunner:assertEquals(models[2].facts.resolutions[2], "1.5K")
        TestRunner:assertEquals(ImageGenerator.parseOpenRouterCatalog("not json"), nil)
        -- a resolution between the listed ones goes to the nearest: 1.5K for Best (2K), 768 is nearer 1K than 1.5K is
        local caps = models[2].facts
        caps.model = "b/two"
        local b = ImageGenerator.buildRequest("openrouter", "b/two", "p",
            { image_gen_openrouter_caps = caps, image_gen_detail = "best" }, SCREEN).body
        TestRunner:assertEquals(b.resolution, "1.5K")
        b = ImageGenerator.buildRequest("openrouter", "b/two", "p", { image_gen_openrouter_caps = caps }, SCREEN).body
        TestRunner:assertEquals(b.resolution, "768")
        TestRunner:assertEquals(b.aspect_ratio, "1:1", "the only ratio it lists")
    end)
    TestRunner:test("OpenRouter's answer: data[].b64_json with its media_type", function()
        local r = ImageGenerator.parseResponse("openrouter",
            '{"created":1,"data":[{"b64_json":"JPEGBYTES","media_type":"image/jpeg"}],"usage":{"cost":0.0059}}')
        TestRunner:assertEquals(r.bytes, "JPEGBYTES")
        TestRunner:assertEquals(ImageGenerator.errorMessage(400,
            '{"error":{"message":"Black Forest Labs FLUX 3 Image does not support: output_format.","code":400}}'),
            "HTTP 400: Black Forest Labs FLUX 3 Image does not support: output_format.")
    end)

    print("  [The answer read (B064, B459)]")
    -- mime.unb64 is a passthrough stub in this file: the "base64" is the bytes
    TestRunner:test("OpenAI-style: b64_json, a link, nothing", function()
        local r = ImageGenerator.parseResponse("openai", '{"data":[{"b64_json":"PNGBYTES"}]}')
        TestRunner:assertEquals(r.bytes, "PNGBYTES")
        r = ImageGenerator.parseResponse("xai", '{"data":[{"url":"https://x.ai/i.jpg"}]}')
        TestRunner:assertEquals(r.url, "https://x.ai/i.jpg")
        local none, msg = ImageGenerator.parseResponse("openai", '{"data":[]}')
        TestRunner:assertEquals(none, nil)
        TestRunner:assert(type(msg) == "string" and msg ~= "", "a message")
        none, msg = ImageGenerator.parseResponse("openai", "not json")
        TestRunner:assertEquals(none, nil)
        TestRunner:assert(type(msg) == "string" and msg ~= "", "a message for a broken answer")
    end)
    TestRunner:test("an error inside a 200 answer is worded", function()
        local r, msg = ImageGenerator.parseResponse("openai", '{"error":{"message":"Billing hard limit"}}')
        TestRunner:assertEquals(r, nil)
        TestRunner:assert(msg:find("Billing hard limit", 1, true), msg)
    end)
    TestRunner:test("Gemini: the image part; the model's text and thoughts are not the image", function()
        local r = ImageGenerator.parseResponse("gemini", '{"candidates":[{"finishReason":"STOP","content":{"parts":['
            .. '{"text":"thinking","thought":true},{"text":"Here is the picture"},'
            .. '{"inlineData":{"mimeType":"image/jpeg","data":"JPEGBYTES"}}]}}]}')
        TestRunner:assertEquals(r.bytes, "JPEGBYTES")
    end)
    TestRunner:test("Gemini without a picture names its reason (B459)", function()
        local _r, msg = ImageGenerator.parseResponse("gemini",
            '{"candidates":[{"finishReason":"IMAGE_SAFETY","content":{"parts":[{"text":"I cannot draw that."}]}}]}')
        TestRunner:assert(msg:find("IMAGE_SAFETY", 1, true) and msg:find("I cannot draw that.", 1, true), msg)
        _r, msg = ImageGenerator.parseResponse("gemini", '{"promptFeedback":{"blockReason":"PROHIBITED_CONTENT"}}')
        TestRunner:assert(msg:find("PROHIBITED_CONTENT", 1, true), msg)
        _r, msg = ImageGenerator.parseResponse("gemini",
            '{"candidates":[{"finishReason":"STOP","content":{"parts":[{"text":"Here is"},{"text":"secret","thought":true}]}}]}')
        TestRunner:assert(msg:find("without a picture", 1, true) and msg:find("Here is", 1, true)
            and not msg:find("secret", 1, true), msg)
    end)
    TestRunner:test("errorMessage: the provider's words; OpenAI moderation named with its stage", function()
        local m = ImageGenerator.errorMessage(400, '{"error":{"code":"moderation_blocked",'
            .. '"message":"Your request was rejected","moderation_details":{"moderation_stage":"output"}}}')
        TestRunner:assert(m:find("picture it made", 1, true) and m:find("Your request was rejected", 1, true), m)
        m = ImageGenerator.errorMessage(400, '{"error":{"code":"moderation_blocked","message":"x",'
            .. '"moderation_details":{"moderation_stage":"input"}}}')
        TestRunner:assert(m:find("refused the prompt", 1, true), m)
        TestRunner:assertEquals(ImageGenerator.errorMessage(401, '{"error":{"message":"Incorrect API key"}}'),
            "HTTP 401: Incorrect API key")
        TestRunner:assertEquals(ImageGenerator.errorMessage(500, "upstream down"), "HTTP 500: upstream down")
    end)
    TestRunner:test("imageExtension: the file type from the bytes", function()
        TestRunner:assertEquals(ImageGenerator.imageExtension("\255\216\255\224rest"), "jpg")
        TestRunner:assertEquals(ImageGenerator.imageExtension("\137PNG\r\n\26\nrest"), "png")
        TestRunner:assertEquals(ImageGenerator.imageExtension("RIFF\0\0\0\0WEBPVP8 "), "webp")
        TestRunner:assertEquals(ImageGenerator.imageExtension("??"), "png", "unknown = png")
    end)

    print("  [The frame (B461, P7, the nearby_text kind)]")
    TestRunner:test("Book info level: None drops the identity, Title keeps the title", function()
        local opts = { book_metadata = { title = "T", author = "A" } }
        local p = ImageGenerator.buildPrompt("sel", opts, {})
        TestRunner:assert(p:find('"T" by A', 1, true), p)
        opts.book_info_level = "title"
        p = ImageGenerator.buildPrompt("sel", opts, {})
        TestRunner:assert(p:find('"T"', 1, true) and not p:find("by A", 1, true), p)
        opts.book_info_level = "full"
        p = ImageGenerator.buildPrompt("sel", opts, {})
        TestRunner:assert(p:find('"T" by A', 1, true), "Full sends both")
        opts.book_info_level = "none"
        TestRunner:assertEquals(ImageGenerator.buildPrompt("sel", opts, {}), "sel", "no frame left: the selection alone")
    end)
    TestRunner:test("the text after the selection follows the clamp", function()
        local window = { prev = "Before it.", next = " rest of the sentence. Next sentence.\nNext paragraph." }
        local p = ImageGenerator.buildPrompt("sel", { window = window, after_limit = "sentence" }, {})
        TestRunner:assert(p:find("rest of the sentence.", 1, true) and not p:find("Next sentence", 1, true), p)
        p = ImageGenerator.buildPrompt("sel", { window = window, after_limit = "paragraph" }, {})
        TestRunner:assert(p:find("Next sentence.", 1, true) and not p:find("Next paragraph", 1, true), p)
        p = ImageGenerator.buildPrompt("sel", { window = window, after_limit = "none" }, {})
        TestRunner:assert(p:find("Before it.", 1, true) and not p:find("rest of", 1, true), p)
        p = ImageGenerator.buildPrompt("sel", { window = window }, {})
        TestRunner:assert(p:find("Next paragraph.", 1, true), "no limit: all of it")
    end)
    TestRunner:test("the frame keeps about 400 characters a side; the writer reads more of the same window", function()
        local window = { prev = string.rep("b", 3000), next = string.rep("c", 3000) }
        -- the mock's util answers nil to everything; ASCII needs no repair
        local util = require("util")
        local had = rawget(util, "fixUtf8")
        util.fixUtf8 = function(s) return s end
        local p = ImageGenerator.buildPrompt("sel", { window = window }, {})
        util.fixUtf8 = had
        TestRunner:assert(p:find("…" .. string.rep("b", 400) .. " […] " .. string.rep("c", 400) .. "…", 1, true)
            and not p:find(string.rep("b", 401), 1, true), "the frame's slice: " .. #p)
        local m = require("koassistant.images.prompt_writer").material({ passage = "sel",
            around = { before = window.prev, after = window.next } })
        TestRunner:assert(m:find(string.rep("b", 1000), 1, true) and not m:find(string.rep("b", 1001), 1, true),
            "the writer's block: " .. #m)
    end)
    TestRunner:test("allowedMaterial: the text around goes only where nearby_text is allowed for every recipient", function()
        local spec = { features = {}, recipients = { "anthropic", "openai" }, window = true }
        TestRunner:assertEquals(ImageGenerator.allowedMaterial(spec).around, true, "Allow by default")
        spec.book = { nearby_text = false }
        TestRunner:assertEquals(ImageGenerator.allowedMaterial(spec).around, false, "a book's Never drops it")
        spec.book = nil
        spec.features = { nearby_text_sharing = "ask" }
        TestRunner:assertEquals(ImageGenerator.allowedMaterial(spec).around, false, "Ask is not yet allowed")
        spec.features._data_once = { book = "/b.epub", kinds = { nearby_text = true } }
        spec.path = "/b.epub"
        TestRunner:assertEquals(ImageGenerator.allowedMaterial(spec).around, true, "Allow once covers both")
        TestRunner:assertEquals(ImageGenerator.allowedMaterial({ features = {}, recipients = { "openai" } }).around,
            false, "no window, nothing to send")
    end)
    TestRunner:test("allowedMaterial: X-Ray descriptions by the kinds they were made from", function()
        local stored = { used_book_text = true, used_highlights = true }
        local spec = { features = { enable_book_text_extraction = true, enable_highlights_sharing = true },
            recipients = { "anthropic", "openai" }, stored = stored }
        TestRunner:assertEquals(ImageGenerator.allowedMaterial(spec).stored, true)
        spec.features.enable_highlights_sharing = nil
        TestRunner:assertEquals(ImageGenerator.allowedMaterial(spec).stored, false,
            "made with highlights, highlights on Ask: not yet")
        spec.stored = { used_book_text = true, used_highlights = false }
        TestRunner:assertEquals(ImageGenerator.allowedMaterial(spec).stored, true, "highlights not used: text alone")
        spec.book = { book_text = false }
        TestRunner:assertEquals(ImageGenerator.allowedMaterial(spec).stored, false, "the book's Never")
    end)
    TestRunner:test("the question resolves a kind across both recipients (the strictest)", function()
        local DataAccess = require("koassistant.ui.data_access")
        local features = { trusted_providers = { "anthropic" }, nearby_text_sharing = "ask" }
        local needs = DataAccess.needsFor(nil, { features = features, kinds = { "nearby_text" },
            providers = { "anthropic", "openai" }, required = false, book = {} })
        TestRunner:assertEquals(needs[1].state, "ask", "trusted Anthropic allows, OpenAI asks: ask")
        needs = DataAccess.needsFor(nil, { features = features, kinds = { "nearby_text" },
            providers = { "anthropic" }, book = {} })
        TestRunner:assertEquals(needs[1].state, "allow", "the trusted column alone")
        needs = DataAccess.needsFor(nil, { features = features, kinds = { "nearby_text" },
            providers = { "anthropic", "openai" }, book = { nearby_text = false } })
        TestRunner:assertEquals(needs[1].state, "never")
        TestRunner:assertEquals(needs[1].layer, "book")
    end)

    TestRunner:test("the question with one unknown provider still resolves (the X-Ray askers pass none)", function()
        local DataAccess = require("koassistant.ui.data_access")
        local needs = DataAccess.needsFor({}, { kinds = { "book_text" }, required = true, features = {} })
        TestRunner:assertEquals(needs[1].state, "ask", "book text on Ask, no provider known: ask")
        needs = DataAccess.needsFor({}, { kinds = { "book_text" }, features = { enable_book_text_extraction = "never" } })
        TestRunner:assertEquals(needs[1].state, "never")
    end)

    print("  [The framed prompt: style, note, an X-Ray entry (S5, S6, S8)]")
    TestRunner:test("a style other than the default and the reader's note end the framed prompt", function()
        local opts = { book_metadata = { title = "T", author = "A" }, note = "  from behind  " }
        local p = ImageGenerator.buildPrompt("sel", opts, { image_gen_style = "watercolor" })
        TestRunner:assert(p:find("\n\nStyle: a watercolor painting.\nThe reader's note: from behind$"), p)
        p = ImageGenerator.buildPrompt("sel", { book_metadata = { title = "T" } }, {})
        TestRunner:assert(not p:find("Style:", 1, true), "the default style adds nothing")
        TestRunner:assertEquals(ImageGenerator.buildPrompt("sel", {}, {}), "sel", "no frame, no lines: the selection")
        TestRunner:assertEquals(ImageGenerator.buildPrompt("sel", {}, { image_gen_style = "comic" }),
            "sel\n\nStyle: a comic-book panel.", "a picked style even without a frame")
    end)
    TestRunner:test("buildEntryPrompt: the entry, the book per the Book info level, the article", function()
        local entry = { name = "Solitude", type = "idea", description = "Living apart." }
        local p = ImageGenerator.buildEntryPrompt(entry, { book_metadata = { title = "T", author = "A" } }, {})
        TestRunner:assert(p:find("Create an illustration of an idea from a book", 1, true), p)
        TestRunner:assert(p:find("To illustrate: Solitude: Living apart.", 1, true), p)
        TestRunner:assert(p:find('From the book "T" by A', 1, true), p)
        p = ImageGenerator.buildEntryPrompt({ name = "Mara", type = "person" },
            { book_metadata = { title = "T", author = "A" }, book_info_level = "none" }, {})
        TestRunner:assert(p:find("of a person", 1, true) and not p:find("From the book", 1, true), p)
    end)
    TestRunner:test("promptShown: the provenance line first", function()
        TestRunner:assertEquals(ImageGenerator.promptShown("the prompt", "Prompt written by m from: the passage."),
            "Prompt written by m from: the passage.\n\nthe prompt")
        TestRunner:assertEquals(ImageGenerator.promptShown("the prompt", nil), "the prompt")
    end)
    TestRunner:test("recordImage keeps the provenance beside the prompt", function()
        withImageIndex(function()
            ImageGenerator.recordImage("c.jpg", { file = "/books/b1.epub", title = "B" }, "p", "Prompt written by m.")
            TestRunner:assertEquals(ImageGenerator.readIndex()["c.jpg"].provenance, "Prompt written by m.")
        end)
    end)
    TestRunner:test("writerConfig: the writer's provider and model, its system text, no web, no stream, reasoning off", function()
        local configuration = { provider = "anthropic", model = "claude-big",
            provider_settings = { anthropic = { model = "claude-big" } },
            features = { enable_web_search = true, enable_streaming = true } }
        local cfg, sent = ImageGenerator.writerConfig(configuration, "anthropic", "claude-haiku-5-5", "SYSTEM")
        TestRunner:assertEquals(cfg.provider, "anthropic")
        TestRunner:assertEquals(cfg.model, "claude-haiku-5-5")
        TestRunner:assertEquals(sent, "claude-haiku-5-5")
        TestRunner:assertEquals(cfg.system.text, "SYSTEM")
        TestRunner:assertEquals(cfg.features.enable_web_search, false)
        TestRunner:assertEquals(cfg.features.enable_streaming, false)
        TestRunner:assertEquals(cfg.features._suppress_loading_dialog, true)
        TestRunner:assertEquals(cfg.api_params.thinking and cfg.api_params.thinking.type, "disabled", "reasoning off")
        TestRunner:assertEquals(configuration.provider_settings.anthropic.model, "claude-big",
            "the shared per-provider table untouched")
        TestRunner:assertEquals(configuration.features.enable_web_search, true, "the shared features untouched")
        cfg = ImageGenerator.writerConfig(configuration, "gemini", "gemini-fast", "S")
        TestRunner:assertEquals(cfg.provider, "gemini", "a tier pin's provider")
        TestRunner:assertEquals(cfg.model, "gemini-fast")
        cfg = ImageGenerator.writerConfig(configuration, "anthropic", nil, "S")
        TestRunner:assertEquals(cfg.model, "claude-big", "no fast model: the chat model as configured")
    end)

    print("  [The run: the question, the writer, the picture (S5)]")
    -- The run with the requests stubbed: the writer's router call is
    -- answered here, the image request is captured where it is built
    local function withRun(answer, fn)
        local UIManager = require("ui/uimanager")
        local ffiutil = require("ffi/util")
        local saved = {
            gq = package.loaded["koassistant.request.gpt_query"],
            sh = package.loaded["koassistant.request.stream_handler"],
            show = UIManager.show, unschedule = UIManager.unschedule,
            run = ffiutil.runInSubProcess, build = ImageGenerator.buildRequest,
        }
        UIManager.unschedule = function() end
        local cap = { shown = {} }
        package.loaded["koassistant.request.gpt_query"] = {
            query = function(messages, cfg, cb)
                cap.writer = { messages = messages, cfg = cfg }
                if answer == false then cb(false, nil, "HTTP 500: upstream down") else cb(true, answer) end
            end,
        }
        package.loaded["koassistant.request.stream_handler"] = {
            showToolStatusDialog = function(o)
                cap.status = o
                return { setText = function(t) cap.status_text = t end, close = function() cap.closed = true end }
            end,
            createWaitingAnimation = function()
                return { getNextFrame = function() return "." end, reset = function() end }
            end,
        }
        UIManager.show = function(_self, w) cap.shown[#cap.shown + 1] = w end
        ffiutil.runInSubProcess = function() return nil end
        ImageGenerator.buildRequest = function(provider, model, prompt, ...)
            cap.image = { provider = provider, model = model, prompt = prompt }
            return saved.build(provider, model, prompt, ...)
        end
        local ok, err = pcall(fn, cap)
        package.loaded["koassistant.request.gpt_query"] = saved.gq
        package.loaded["koassistant.request.stream_handler"] = saved.sh
        UIManager.show, ffiutil.runInSubProcess, ImageGenerator.buildRequest = saved.show, saved.run, saved.build
        UIManager.unschedule = saved.unschedule
        if not ok then error(err, 0) end
    end
    local function config(features)
        return { provider = "anthropic", features = features or {} }
    end
    TestRunner:test("writer on: the writer's request, then its paragraph as the image prompt", function()
        withApikeys({ openai = "sk-real-key" }, function()
            withRun("A girl in a red scarf on black rocks.", function(cap)
                ImageGenerator._askAndRun("openai", "Mara ran to the rocks.", config(), mockSettings({}), nil,
                    { note = "from behind", background = "Cornwall", spoiler = true,
                      book_metadata = { title = "T", author = "A" } })
                local w = cap.writer
                TestRunner:assert(w, "the writer was asked")
                TestRunner:assertEquals(w.cfg.provider, "anthropic", "the chat provider's")
                TestRunner:assertEquals(w.cfg.features._suppress_loading_dialog, true)
                TestRunner:assert(w.cfg.system.text:find("has not finished the book", 1, true), "spoiler rule")
                local material = w.messages[#w.messages].content
                TestRunner:assert(material:find("<passage>Mara ran to the rocks.</passage>", 1, true), material)
                TestRunner:assert(material:find("<reader_note>from behind</reader_note>", 1, true), material)
                TestRunner:assert(material:find("<background>Cornwall</background>", 1, true), material)
                TestRunner:assert(material:find('<book title="T" author="A"/>', 1, true), material)
                TestRunner:assertEquals(cap.image.provider, "openai")
                TestRunner:assertEquals(cap.image.prompt,
                    "A girl in a red scarf on black rocks. The picture contains no text, letters, titles or captions.")
                TestRunner:assert(cap.status_text:find("Generating image with OpenAI", 1, true), cap.status_text)
            end)
        end)
    end)
    TestRunner:test("a writer that fails leaves the framed prompt, said in one line", function()
        withApikeys({ openai = "sk-real-key" }, function()
            withRun(false, function(cap)
                ImageGenerator._askAndRun("openai", "Mara ran to the rocks.", config(), mockSettings({}), nil,
                    { book_metadata = { title = "T", author = "A" } })
                TestRunner:assert(cap.image.prompt:find("Passage to illustrate: Mara ran to the rocks.", 1, true),
                    cap.image.prompt)
                TestRunner:assert(cap.status_text:find("The prompt writer failed (HTTP 500: upstream down)", 1, true),
                    cap.status_text)
            end)
        end)
    end)
    TestRunner:test("writer off: no writer request, the framed prompt", function()
        withApikeys({ openai = "sk-real-key" }, function()
            withRun("unused", function(cap)
                ImageGenerator._askAndRun("openai", "Mara ran.", config({ image_gen_writer = false,
                    image_gen_style = "ink" }), mockSettings({}), nil, { note = "dusk" })
                TestRunner:assertEquals(cap.writer, nil)
                TestRunner:assertEquals(cap.image.prompt, "Mara ran.\n\nStyle: an ink drawing.\nThe reader's note: dusk")
            end)
        end)
    end)
    TestRunner:test("the text around on Ask: one question names both providers; Allow once sends it to both", function()
        withApikeys({ openai = "sk-real-key" }, function()
            withRun("A scene.", function(cap)
                local plugin = { getProviderDisplayName = function(_self, id) return id == "anthropic" and "Anthropic" or id end }
                ImageGenerator._askAndRun("openai", "Mara ran.", config({ nearby_text_sharing = "ask" }),
                    mockSettings({}), nil, { window = { prev = "The storm broke.", next = " Waves rose." }, plugin = plugin })
                TestRunner:assertEquals(cap.writer, nil, "nothing sent before the answer")
                local q = cap.shown[1]
                TestRunner:assert(q and q.title:find("Generate Image will send to Anthropic, to write the prompt, and to OpenAI, to draw it:", 1, true),
                    q and q.title)
                TestRunner:assertEquals(q.buttons[1][1].text, "Allow once")
                q.buttons[1][1].callback()
                local material = cap.writer.messages[#cap.writer.messages].content
                TestRunner:assert(material:find("<before>The storm broke.</before>", 1, true), material)
            end)
        end)
    end)
    TestRunner:test("Continue without: this picture goes without the text around, and nothing is stored", function()
        withApikeys({ openai = "sk-real-key" }, function()
            withRun("A scene.", function(cap)
                ImageGenerator._askAndRun("openai", "Mara ran.", config({ nearby_text_sharing = "ask" }),
                    mockSettings({}), nil, { window = { prev = "Before.", next = " After." } })
                local q = cap.shown[1]
                local without
                for _idx, row in ipairs(q.buttons) do
                    for _j, b in ipairs(row) do
                        if b.text == "Continue without" then without = b end
                        TestRunner:assert(b.text ~= "Not for this book", "no book-wide Never from an image")
                    end
                end
                TestRunner:assert(without, "Continue without offered")
                without.callback()
                local material = cap.writer.messages[#cap.writer.messages].content
                TestRunner:assert(not material:find("<text_around>", 1, true), material)
            end)
        end)
    end)
    TestRunner:test("nothing is asked for text the clamp would not send", function()
        withApikeys({ openai = "sk-real-key" }, function()
            withRun("A scene.", function(cap)
                -- Context Direction "before" and nothing before the selection
                ImageGenerator._askAndRun("openai", "Mara ran.", config({ nearby_text_sharing = "ask" }),
                    mockSettings({}), nil, { window = { prev = "", next = " After." }, after_limit = "none" })
                for _idx, w in ipairs(cap.shown) do
                    TestRunner:assert(not (type(w.title) == "string" and w.title:find("will send to", 1, true)),
                        "no question")
                end
                TestRunner:assert(cap.writer, "the run went on")
            end)
        end)
    end)
    TestRunner:test("an entry to draw with no stamps known is judged as made from the book's text", function()
        local real_ac = package.loaded["koassistant.artifacts.action_cache"]
        package.loaded["koassistant.artifacts.action_cache"] = { parsedXrayFor = function() return nil end }
        local Gates = require("koassistant.request.privacy_gates")
        local real_overrides = Gates.bookOverrides
        Gates.bookOverrides = function() return { book_text = false } end
        local ok, err = pcall(withApikeys, { openai = "sk-real-key" }, function()
            withRun("A scene.", function(cap)
                ImageGenerator._askAndRun("openai", "Mara", config({}), mockSettings({}),
                    { file = "/books/b.epub", title = "B" },
                    { entry = { name = "Mara", type = "person", description = "A red scarf." } })
                TestRunner:assertEquals(cap.writer, nil, "the book's Never refuses the entry: nothing sent")
                local refusal = cap.shown[1]
                TestRunner:assert(refusal and refusal.title:find("Illustrate needs book text", 1, true),
                    refusal and refusal.title)
            end)
        end)
        package.loaded["koassistant.artifacts.action_cache"], Gates.bookOverrides = real_ac, real_overrides
        if not ok then error(err, 0) end
    end)
    TestRunner:test("the book's Never for the text around: no question, the run goes on without it", function()
        local Gates = require("koassistant.request.privacy_gates")
        local real_overrides, real_ac = Gates.bookOverrides, package.loaded["koassistant.artifacts.action_cache"]
        Gates.bookOverrides = function() return { nearby_text = false } end
        package.loaded["koassistant.artifacts.action_cache"] = { parsedXrayFor = function() return nil end }
        local ok, err = pcall(withApikeys, { openai = "sk-real-key" }, function()
            withRun("A scene.", function(cap)
                ImageGenerator._askAndRun("openai", "Mara ran.", config({ nearby_text_sharing = "ask" }),
                    mockSettings({}), { file = "/books/b.epub", title = "B" },
                    { window = { prev = "Before.", next = " After." } })
                for _idx, w in ipairs(cap.shown) do
                    TestRunner:assert(not (type(w.title) == "string" and w.title:find("will send to", 1, true)),
                        "Never asks nothing")
                end
                local material = cap.writer.messages[#cap.writer.messages].content
                TestRunner:assert(not material:find("<text_around>", 1, true), material)
            end)
        end)
        Gates.bookOverrides = real_overrides
        package.loaded["koassistant.artifacts.action_cache"] = real_ac
        if not ok then error(err, 0) end
    end)
    TestRunner:test("the passage's X-Ray entries reach the writer, judged by the X-Ray's stamps", function()
        local Gates = require("koassistant.request.privacy_gates")
        local real_ac, real_overrides = package.loaded["koassistant.artifacts.action_cache"], Gates.bookOverrides
        package.loaded["koassistant.artifacts.action_cache"] = { parsedXrayFor = function()
            return { data = { type = "fiction", characters = { { name = "Mara", description = "A red scarf." } } },
                     entry = { used_book_text = true } }
        end }
        Gates.bookOverrides = function() return {} end
        local ok, err = pcall(withApikeys, { openai = "sk-real-key" }, function()
            withRun("A scene.", function(cap)
                ImageGenerator._askAndRun("openai", "Mara ran.", config({ enable_book_text_extraction = true }),
                    mockSettings({}), { file = "/books/b.epub", title = "B" }, {})
                local material = cap.writer.messages[#cap.writer.messages].content
                TestRunner:assert(material:find('<xray_entry name="Mara" type="person">A red scarf.</xray_entry>', 1, true),
                    material)
            end)
            withRun("A scene.", function(cap)
                -- book text on Ask: the question lists the descriptions
                ImageGenerator._askAndRun("openai", "Mara ran.", config({}),
                    mockSettings({}), { file = "/books/b.epub", title = "B" }, {})
                TestRunner:assert(cap.shown[1] and cap.shown[1].title:find("the X-Ray descriptions of Mara", 1, true),
                    cap.shown[1] and cap.shown[1].title)
            end)
        end)
        package.loaded["koassistant.artifacts.action_cache"], Gates.bookOverrides = real_ac, real_overrides
        if not ok then error(err, 0) end
    end)
    TestRunner:test("carried entries reach the writer too, none from a book whose text is Never (B537)", function()
        local Gates = require("koassistant.request.privacy_gates")
        local real_ac, real_overrides = package.loaded["koassistant.artifacts.action_cache"], Gates.bookOverrides
        package.loaded["koassistant.artifacts.action_cache"] = { parsedXrayFor = function()
            return { data = { type = "fiction", characters = { { name = "Mara", description = "A red scarf." } },
                __dormant = {
                    { name = "Dorrit Hale", category = "characters", description = "Keeps the inn.",
                      source = "Vol 2", file = "/books/v2.epub" },
                    { name = "Zeph Umber", category = "characters", description = "A diver.",
                      source = "Vol 1", file = "/books/never.epub" },
                } }, entry = { used_book_text = true } }
        end }
        Gates.bookOverrides = function(path)
            if path == "/books/never.epub" then return { book_text = false } end
            return {}
        end
        local passage = "Mara met Dorrit Hale and Zeph Umber."
        local ok, err = pcall(withApikeys, { openai = "sk-real-key" }, function()
            withRun("A scene.", function(cap)
                ImageGenerator._askAndRun("openai", passage, config({ enable_book_text_extraction = true }),
                    mockSettings({}), { file = "/books/b.epub", title = "B" }, {})
                local material = cap.writer.messages[#cap.writer.messages].content
                TestRunner:assert(material:find('<xray_entry name="Dorrit Hale" type="person">Keeps the inn.</xray_entry>', 1, true),
                    material)
                TestRunner:assert(not material:find("A diver.", 1, true), "the Never book's entry stays out: " .. material)
            end)
            withRun("A scene.", function(cap)
                -- a pick made in the popup: the run judges it again
                ImageGenerator._askAndRun("openai", passage, config({ enable_book_text_extraction = true }),
                    mockSettings({}), { file = "/books/b.epub", title = "B" }, { picked = { "Zeph Umber", "Dorrit Hale" } })
                local material = cap.writer.messages[#cap.writer.messages].content
                TestRunner:assert(not material:find("A diver.", 1, true), material)
                TestRunner:assert(material:find("Keeps the inn.", 1, true), material)
            end)
            withRun("A scene.", function(cap)
                ImageGenerator._askAndRun("openai", passage, config({}),
                    mockSettings({}), { file = "/books/b.epub", title = "B" }, {})
                TestRunner:assert(cap.shown[1] and cap.shown[1].title:find("the books they are carried from", 1, true),
                    "the question says where carried descriptions come from: "
                    .. tostring(cap.shown[1] and cap.shown[1].title))
            end)
        end)
        package.loaded["koassistant.artifacts.action_cache"], Gates.bookOverrides = real_ac, real_overrides
        if not ok then error(err, 0) end
    end)

    print("  [The gallery: thumbnails, the index, Regenerate (S7)]")
    local function list(t) return table.concat(t or {}, ",") end
    TestRunner:test("thumbnailSize: a third of the screen each way, the ratio kept, never enlarged", function()
        local w, h = ImageGenerator.thumbnailSize(1152, 1536, 1264, 1680)
        TestRunner:assertEquals(w .. "x" .. h, "420x560")
        w, h = ImageGenerator.thumbnailSize(1536, 1024, 1264, 1680)
        TestRunner:assertEquals(w .. "x" .. h, "421x281")
        w, h = ImageGenerator.thumbnailSize(1536, 1024, 1680, 1264)
        TestRunner:assertEquals(w .. "x" .. h, "421x281", "the same box held sideways")
        w, h = ImageGenerator.thumbnailSize(300, 200, 1264, 1680)
        TestRunner:assertEquals(w .. "x" .. h, "300x200", "a small picture is not enlarged")
    end)
    TestRunner:test("picturesOf: an entry's pictures by its names, newest first (B486)", function()
        withImageIndex(function()
            local data = { type = "fiction", characters = {
                { name = "Gil Rook", aliases = { "the grafter", "Jory" } },
                { name = "Jory", description = "The carter." },
            } }
            for _idx, n in ipairs({ "a.png", "b.png", "c.png", "d.png" }) do touchFile(n) end
            ImageGenerator.recordImage("a.png", { file = "/b/one.epub", title = "One" }, "p", nil, { entries = { "Gil Rook" } })
            ImageGenerator.recordImage("b.png", { file = "/b/one.epub", title = "One" }, "p", nil, { entries = { "the grafter", "Mara" } })
            ImageGenerator.recordImage("c.png", { file = "/b/one.epub", title = "One" }, "p", nil, { entries = { "Jory" } })
            ImageGenerator.recordImage("d.png", { file = "/b/two.epub", title = "Two" }, "p", nil, { entries = { "Gil Rook" } })
            ImageGenerator.recordImage("gone.png", { file = "/b/one.epub", title = "One" }, "p", nil, { entries = { "Gil Rook" } })
            local index = ImageGenerator.readIndex()
            index["a.png"].created, index["b.png"].created = 100, 200
            local names, others, main = ImageGenerator.entryNames(data, data.characters[1], "characters")
            local list = ImageGenerator.picturesOf("/b/one.epub", names, others, main, index)
            TestRunner:assertEquals(table.concat(list, "|"), "b.png|a.png",
                "by its name and its other names, newest first; another book's and a deleted file left out")
            names, others, main = ImageGenerator.entryNames(data, data.characters[2], "characters")
            list = ImageGenerator.picturesOf("/b/one.epub", names, others, main, index)
            TestRunner:assertEquals(table.concat(list, "|"), "c.png",
                "a name that is another entry's own name belongs to that entry")
            TestRunner:assertEquals(#ImageGenerator.picturesOf(nil, names), 0)
        end)
    end)
    TestRunner:test("thumbnailPath and subjectFromName", function()
        TestRunner:assertEquals(ImageGenerator.thumbnailPath("x.png"), IMAGES_DIR .. "/thumbnails/x.png.jpg")
        TestRunner:assertEquals(ImageGenerator.subjectFromName("2026-10-15 00.10.50 lighthouse keeper.jpg"), "lighthouse keeper")
        TestRunner:assertEquals(ImageGenerator.subjectFromName("2026-10-15 00.10.50 lighthouse keeper (2).png"), "lighthouse keeper")
        TestRunner:assertEquals(ImageGenerator.subjectFromName("my own.webp"), "my own")
    end)
    TestRunner:test("deleteImages: the picture, its thumbnail, its entry; sweepThumbnails drops the orphans", function()
        withImageIndex(function()
            local lfs = require("libs/libkoreader-lfs")
            touchFile("a.png")
            touchFile("b.png")
            os.execute('mkdir -p "' .. IMAGES_DIR .. '/thumbnails"')
            for _idx, n in ipairs({ "a.png", "b.png", "gone.png" }) do
                local f = assert(io.open(ImageGenerator.thumbnailPath(n), "w"))
                f:write("jpg")
                f:close()
            end
            ImageGenerator.recordImage("a.png", nil, "p1")
            ImageGenerator.recordImage("b.png", nil, "p2")
            ImageGenerator.deleteImages({ "a.png" })
            TestRunner:assertEquals(lfs.attributes(IMAGES_DIR .. "/a.png", "mode"), nil)
            TestRunner:assertEquals(lfs.attributes(ImageGenerator.thumbnailPath("a.png"), "mode"), nil)
            TestRunner:assertEquals(ImageGenerator.readIndex()["a.png"], nil)
            TestRunner:assert(ImageGenerator.readIndex()["b.png"], "the other kept")
            ImageGenerator.sweepThumbnails()
            TestRunner:assertEquals(lfs.attributes(ImageGenerator.thumbnailPath("gone.png"), "mode"), nil, "orphan swept")
            TestRunner:assertEquals(lfs.attributes(ImageGenerator.thumbnailPath("b.png"), "mode"), "file", "b's kept")
        end)
    end)
    TestRunner:test("recordImage keeps who drew it, the kinds and the subject (capped)", function()
        withImageIndex(function()
            ImageGenerator.recordImage("a.png", nil, "p", nil, { provider = "openai", model = "gpt-image-2.5-flare",
                kinds = { "nearby_text" }, description = string.rep("x", 400) })
            local e = ImageGenerator.readIndex()["a.png"]
            TestRunner:assertEquals(e.provider, "openai")
            TestRunner:assertEquals(e.model, "gpt-image-2.5-flare")
            TestRunner:assertEquals(list(e.kinds), "nearby_text")
            TestRunner:assertEquals(#e.description, 300)
        end)
    end)
    TestRunner:test("saveImage: the file by its bytes, the entry with the subject; no decoder, no thumbnail", function()
        withImageIndex(function()
            local path, bb = ImageGenerator.saveImage("\255\216\255jpegbytes", "Mara ran.", { file = "/books/b.epub", title = "B" },
                "A girl running.", "Prompt written by W.", { provider = "xai", model = "grok-imagine-image", kinds = {} })
            TestRunner:assert(path and path:match("%d Mara ran%.jpg$"), tostring(path))
            TestRunner:assertEquals(bb, nil, "the test environment has no image decoder")
            local e = ImageGenerator.readIndex()[path:match("([^/]+)$")]
            TestRunner:assertEquals(e.description, "Mara ran.")
            TestRunner:assertEquals(e.prompt, "A girl running.")
            TestRunner:assertEquals(e.provider, "xai")
            TestRunner:assertEquals(e.book_file, "/books/b.epub")
        end)
    end)
    TestRunner:test("kindsSent: what a prompt carries, recorded with the picture", function()
        local xray = { used_book_text = true }
        TestRunner:assertEquals(list(ImageGenerator.kindsSent({ around = true })), "nearby_text")
        TestRunner:assertEquals(list(ImageGenerator.kindsSent({ stored = xray, written = true, entries = 2 })), "book_text")
        TestRunner:assertEquals(list(ImageGenerator.kindsSent({ stored = xray, written = false, entries = 2 })), "",
            "a framed prompt carries no X-Ray descriptions")
        TestRunner:assertEquals(list(ImageGenerator.kindsSent({ stored = xray, entry = true })), "book_text", "the entry to draw")
        TestRunner:assertEquals(list(ImageGenerator.kindsSent({ around = true, entry = true,
            stored = { used_book_text = true, used_highlights = true } })), "nearby_text,book_text,highlights")
        TestRunner:assertEquals(list(ImageGenerator.kindsSent({})), "")
    end)
    TestRunner:test("promptKinds: the recorded kinds; before S7, the frame's text around", function()
        TestRunner:assertEquals(list(ImageGenerator.promptKinds({ kinds = { "nearby_text", "book_text" } })), "nearby_text,book_text")
        local framed = ImageGenerator.buildPrompt("Mara ran.", { window = { prev = "Before.", next = " After." } }, {})
        TestRunner:assertEquals(list(ImageGenerator.promptKinds({ prompt = framed })), "nearby_text", "the frame's label")
        TestRunner:assertEquals(list(ImageGenerator.promptKinds({ prompt = "Mara ran." })), "")
        TestRunner:assertEquals(list(ImageGenerator.promptKinds({ prompt = framed, kinds = {} })), "", "a recorded list wins")
        TestRunner:assertEquals(list(ImageGenerator.promptKinds(nil)), "")
        -- builds between S5 and S7: a written prompt (it has a provenance
        -- line) as both, an X-Ray entry's frame as book text
        TestRunner:assertEquals(list(ImageGenerator.promptKinds({ prompt = "A girl on the rocks.",
            provenance = "Prompt written by W." })), "nearby_text,book_text")
        local entry_frame = ImageGenerator.buildEntryPrompt({ name = "Mara", type = "person", description = "A red scarf." }, {}, {})
        TestRunner:assertEquals(list(ImageGenerator.promptKinds({ prompt = entry_frame })), "book_text")
    end)
    TestRunner:test("makeThumbnail: made only when the file is there (the JPEG writer hides its failures)", function()
        withImageIndex(function()
            local lfs = require("libs/libkoreader-lfs")
            local saved = package.loaded["ui/renderimage"]
            local writes, sizes = true, {}
            local function fakeBB(w, h)
                return {
                    getWidth = function() return w end, getHeight = function() return h end, free = function() end,
                    writeToFile = function(_self, path)
                        sizes[#sizes + 1] = w .. "x" .. h
                        if writes then
                            local f = io.open(path, "wb")
                            f:write("jpeg")
                            f:close()
                        end
                        return true
                    end,
                }
            end
            package.loaded["ui/renderimage"] = {
                renderImageFile = function() return fakeBB(1152, 1536) end,
                scaleBlitBuffer = function(_self, _bb, w, h) return fakeBB(w, h) end,
            }
            local ok, err = pcall(function()
                TestRunner:assertEquals(ImageGenerator.makeThumbnail("a.png"), true)
                local tw, th = ImageGenerator.thumbnailSize(1152, 1536, 800, 600)
                TestRunner:assertEquals(sizes[1], tw .. "x" .. th, "fitted to a third of the mock's 800x600 screen")
                writes = false
                TestRunner:assertEquals(ImageGenerator.makeThumbnail("b.png"), false, "nothing on disk: not made")
                TestRunner:assertEquals(lfs.attributes(ImageGenerator.thumbnailPath("b.png"), "mode"), nil)
            end)
            package.loaded["ui/renderimage"] = saved
            if not ok then error(err, 0) end
        end)
    end)
    local function buttonTexts(dialog)
        local out = {}
        for _idx, row in ipairs(dialog.buttons or {}) do
            for _j, b in ipairs(row) do out[#out + 1] = b.text end
        end
        return out
    end
    TestRunner:test("Regenerate: the recorded prompt drawn as it stands, no prompt writer", function()
        withApikeys({ openai = "sk-real-key" }, function()
            withRun("unused", function(cap)
                ImageGenerator._regenerateImpl({ name = "2026-10-15 00.10.50 lamp.jpg",
                    entry = { prompt = "A lamp.", provenance = "Prompt written by W.", kinds = {} }, prompt = "A lamp." },
                    config({ image_gen_provider = "openai" }), mockSettings({}))
                TestRunner:assertEquals(cap.writer, nil, "no writer request")
                TestRunner:assertEquals(cap.image.provider, "openai")
                TestRunner:assertEquals(cap.image.prompt, "A lamp.")
            end)
        end)
    end)
    TestRunner:test("Regenerate: the new picture's provenance, book and subject; an edit is said", function()
        local real_run = ImageGenerator._run
        local got
        ImageGenerator._run = function(st) got = st end
        local ok, err = pcall(withApikeys, { openai = "sk-real-key" }, function()
            ImageGenerator._regenerateImpl({ name = "2026-10-15 00.10.50 lighthouse keeper (2).jpg",
                entry = { prompt = "A lamp.", provenance = "Prompt written by W.", kinds = {},
                    book_file = "/books/b.epub", book_title = "B" },
                prompt = "A lamp at night.", edited = true }, config({ image_gen_provider = "openai" }), mockSettings({}))
        end)
        ImageGenerator._run = real_run
        if not ok then error(err, 0) end
        TestRunner:assertEquals(got.fixed_prompt, "A lamp at night.")
        TestRunner:assertEquals(ImageGenerator.regeneratedProvenance(got.fixed_head, nil, got.fixed_source),
            "Drawn from your edit of an earlier picture's prompt. Prompt written by W.")
        TestRunner:assertEquals(got.book_info.file, "/books/b.epub")
        TestRunner:assertEquals(got.description, "lighthouse keeper", "recorded before S7: the subject from its name")
        TestRunner:assertEquals(got.writer_on, false)
        TestRunner:assertEquals(list(got.kinds), "")
    end)
    print("  [Regenerate in the Style now in effect, and Replace (S9)]")
    local PromptWriterT = require("koassistant.images.prompt_writer")
    TestRunner:test("restyleFramed: the style line swapped, added or dropped; the note kept", function()
        local framed = "Create an illustration.\n\nPassage to illustrate: Mara ran.\n\nThe passage is from the book \"T\"."
        TestRunner:assertEquals(ImageGenerator.restyleFramed(framed .. "\n\nStyle: an ink drawing.", "a watercolor painting", false),
            framed .. "\n\nStyle: a watercolor painting.")
        TestRunner:assertEquals(ImageGenerator.restyleFramed(framed, "a woodcut print", false),
            framed .. "\n\nStyle: a woodcut print.", "no line yet: added")
        TestRunner:assertEquals(ImageGenerator.restyleFramed(framed .. "\n\nStyle: an ink drawing.\nThe reader's note: at dusk",
            "a book illustration", true), framed .. "\n\nThe reader's note: at dusk", "the default needs no line; the note stays")
        TestRunner:assertEquals(ImageGenerator.restyleFramed("Mara ran.\n\nStyle: an ink drawing.", "a photograph", false),
            "Mara ran.\n\nStyle: a photograph.", "an unframed prompt")
        local written = "A girl on black rocks. " .. PromptWriterT.NO_TEXT
        TestRunner:assertEquals(ImageGenerator.restyleFramed(written, "a comic-book panel", false),
            written .. "\n\nStyle: a comic-book panel.", "a written prompt gets the line")
    end)
    TestRunner:test("promptWritten and recordedStyle: the record, else what the prompt shows", function()
        TestRunner:assertEquals(ImageGenerator.promptWritten({ written = false, prompt = "x " .. PromptWriterT.NO_TEXT }), false)
        TestRunner:assertEquals(ImageGenerator.promptWritten({ prompt = "A girl. " .. PromptWriterT.NO_TEXT }), true)
        TestRunner:assertEquals(ImageGenerator.promptWritten({ prompt = "Create an illustration of a lamp." }), false)
        TestRunner:assertEquals(ImageGenerator.recordedStyle({ style = "an ink drawing" }), "an ink drawing")
        TestRunner:assertEquals(ImageGenerator.recordedStyle({}), "a book illustration", "before S9: the default")
        TestRunner:assertEquals(PromptWriterT.restyleMaterial("A girl. " .. PromptWriterT.NO_TEXT), "A girl.")
    end)
    TestRunner:test("a picture records its style and whether the writer wrote its prompt", function()
        withImageIndex(function()
            ImageGenerator.recordImage("a.png", nil, "p", nil, { style = "an ink drawing", written = true })
            ImageGenerator.recordImage("b.png", nil, "p", nil, { style = 7, written = "yes" })
            local index = ImageGenerator.readIndex()
            TestRunner:assertEquals(index["a.png"].style, "an ink drawing")
            TestRunner:assertEquals(index["a.png"].written, true)
            TestRunner:assertEquals(index["b.png"].style, nil, "only a string")
            TestRunner:assertEquals(index["b.png"].written, nil, "only a boolean")
        end)
    end)
    TestRunner:test("Regenerate in another style: a framed prompt's line swapped, no request", function()
        withApikeys({ openai = "sk-real-key" }, function()
            withRun("unused", function(cap)
                local prompt = "Mara ran.\n\nStyle: an ink drawing."
                ImageGenerator._regenerateImpl({ name = "x.jpg", prompt = prompt,
                    entry = { prompt = prompt, kinds = {}, style = "an ink drawing", written = false } },
                    config({ image_gen_provider = "openai", image_gen_style = "watercolor" }), mockSettings({}))
                TestRunner:assertEquals(cap.writer, nil, "no request")
                TestRunner:assertEquals(cap.image.prompt, "Mara ran.\n\nStyle: a watercolor painting.")
            end)
            withRun("unused", function(cap)
                local prompt = "Mara ran.\n\nStyle: a watercolor painting."
                ImageGenerator._regenerateImpl({ name = "x.jpg", prompt = prompt,
                    entry = { prompt = prompt, kinds = {}, style = "a watercolor painting" } },
                    config({ image_gen_provider = "openai", image_gen_style = "watercolor" }), mockSettings({}))
                TestRunner:assertEquals(cap.image.prompt, prompt, "the same style: as it stands")
            end)
        end)
    end)
    TestRunner:test("Regenerate in another style: the writer restyles a written prompt; a failure adds a line", function()
        local prompt = "A girl on black rocks. " .. PromptWriterT.NO_TEXT
        withApikeys({ openai = "sk-real-key" }, function()
            withRun("A watercolor of a girl on black rocks.", function(cap)
                ImageGenerator._regenerateImpl({ name = "x.jpg", prompt = prompt,
                    entry = { prompt = prompt, kinds = {}, written = true } },
                    config({ image_gen_provider = "openai", image_gen_style = "watercolor" }), mockSettings({}))
                local w = cap.writer
                TestRunner:assert(w, "the writer was asked")
                TestRunner:assertEquals(w.cfg.provider, "anthropic", "the chat provider's fast model")
                TestRunner:assert(w.cfg.system.text:find("drawn as a watercolor painting", 1, true), w.cfg.system.text)
                TestRunner:assertEquals(w.messages[#w.messages].content, "A girl on black rocks.", "without the no-text line")
                TestRunner:assertEquals(cap.image.prompt, "A watercolor of a girl on black rocks. " .. PromptWriterT.NO_TEXT)
            end)
            withRun(false, function(cap)
                ImageGenerator._regenerateImpl({ name = "x.jpg", prompt = prompt,
                    entry = { prompt = prompt, kinds = {}, written = true } },
                    config({ image_gen_provider = "openai", image_gen_style = "watercolor" }), mockSettings({}))
                TestRunner:assertEquals(cap.image.prompt, prompt .. "\n\nStyle: a watercolor painting.", "the writer failed")
                TestRunner:assert(cap.status_text:find("the style is added as a line", 1, true), cap.status_text)
            end)
        end)
    end)
    TestRunner:test("Regenerate in another style: the writer off adds a line; an edit is drawn as written", function()
        local prompt = "A girl on black rocks. " .. PromptWriterT.NO_TEXT
        withApikeys({ openai = "sk-real-key" }, function()
            withRun("unused", function(cap)
                ImageGenerator._regenerateImpl({ name = "x.jpg", prompt = prompt, entry = { prompt = prompt, kinds = {} } },
                    config({ image_gen_provider = "openai", image_gen_style = "ink", image_gen_writer = false }), mockSettings({}))
                TestRunner:assertEquals(cap.writer, nil)
                TestRunner:assertEquals(cap.image.prompt, prompt .. "\n\nStyle: an ink drawing.")
            end)
            withRun("unused", function(cap)
                ImageGenerator._regenerateImpl({ name = "x.jpg", prompt = "My own words.", edited = true,
                    entry = { prompt = prompt, kinds = {} } },
                    config({ image_gen_provider = "openai", image_gen_style = "ink" }), mockSettings({}))
                TestRunner:assertEquals(cap.writer, nil, "an edit is not restyled")
                TestRunner:assertEquals(cap.image.prompt, "My own words.")
            end)
        end)
    end)
    TestRunner:test("Regenerate in another style: the question names the writer's provider too", function()
        local prompt = "A girl on black rocks. " .. PromptWriterT.NO_TEXT
        withApikeys({ openai = "sk-real-key" }, function()
            withRun("A watercolor of the rocks.", function(cap)
                local plugin = { getProviderDisplayName = function(_self, id) return id == "anthropic" and "Anthropic" or id end }
                ImageGenerator._regenerateImpl({ name = "x.jpg", prompt = prompt, plugin = plugin,
                    entry = { prompt = prompt, kinds = { "nearby_text" }, written = true } },
                    config({ image_gen_provider = "openai", image_gen_style = "watercolor", nearby_text_sharing = "ask" }),
                    mockSettings({}))
                TestRunner:assertEquals(cap.writer, nil, "nothing sent before the answer")
                local q = cap.shown[1]
                TestRunner:assert(q and q.title:find(
                    "Regenerate will send to Anthropic, to restyle the prompt, and to OpenAI, to draw it:", 1, true), q and q.title)
                q.buttons[1][1].callback()
                TestRunner:assert(cap.writer, "after Allow once: the restyle")
            end)
        end)
    end)
    TestRunner:test("Regenerate and replace: the old picture goes only once the new one is saved", function()
        local real_run, real_delete = ImageGenerator._run, ImageGenerator.deleteImages
        local got, deleted
        ImageGenerator._run = function(st) got = st end
        ImageGenerator.deleteImages = function(names) deleted = names end
        local ok, err = pcall(function()
            withApikeys({ openai = "sk-real-key" }, function()
                ImageGenerator._regenerateImpl({ name = "old.jpg", replace = true, prompt = "A lamp.",
                    entry = { prompt = "A lamp.", kinds = {} } }, config({ image_gen_provider = "openai" }), mockSettings({}))
                TestRunner:assertEquals(deleted, nil, "nothing deleted before the new picture")
                got.opts.on_saved("/images/new.jpg")
                TestRunner:assertEquals(deleted and deleted[1], "old.jpg", "deleted after the save")
                got = nil
                ImageGenerator._regenerateImpl({ name = "old.jpg", prompt = "A lamp.", entry = { prompt = "A lamp.", kinds = {} } },
                    config({ image_gen_provider = "openai" }), mockSettings({}))
                TestRunner:assertEquals(got.opts.on_saved, nil, "Regenerate keeps both")
            end)
        end)
        ImageGenerator._run, ImageGenerator.deleteImages = real_run, real_delete
        if not ok then error(err, 0) end
        TestRunner:assertEquals(ImageGenerator.regeneratedProvenance("Head.", "Restyled.", "Source."),
            "Head. Restyled. Source.")
    end)
    TestRunner:test("Regenerate: the text around on Ask asks (required: no Continue without); Allow once draws", function()
        withApikeys({ openai = "sk-real-key" }, function()
            withRun("unused", function(cap)
                ImageGenerator._regenerateImpl({ name = "x.jpg", entry = { prompt = "A lamp.", kinds = { "nearby_text" } },
                    prompt = "A lamp." }, config({ image_gen_provider = "openai", nearby_text_sharing = "ask" }), mockSettings({}))
                TestRunner:assertEquals(cap.image, nil, "nothing sent before the answer")
                local q = cap.shown[1]
                TestRunner:assert(q and q.title:find("Regenerate will send to OpenAI:", 1, true), q and q.title)
                local texts = list(buttonTexts(q))
                TestRunner:assert(not texts:find("Continue without", 1, true) and not texts:find("Not for this book", 1, true), texts)
                TestRunner:assert(not texts:find("Allow for this book", 1, true), "a picture without a book: " .. texts)
                q.buttons[1][1].callback()
                TestRunner:assertEquals(cap.image.prompt, "A lamp.")
            end)
            withRun("unused", function(cap)
                -- with its book: the book's answer is offered
                local Gates = require("koassistant.request.privacy_gates")
                local real = Gates.bookOverrides
                Gates.bookOverrides = function() return {} end
                local ok, err = pcall(ImageGenerator._regenerateImpl, { name = "x.jpg", prompt = "A lamp.",
                    entry = { prompt = "A lamp.", kinds = { "nearby_text" }, book_file = "/books/b.epub" } },
                    config({ image_gen_provider = "openai", nearby_text_sharing = "ask" }), mockSettings({}))
                Gates.bookOverrides = real
                if not ok then error(err, 0) end
                TestRunner:assert(list(buttonTexts(cap.shown[1])):find("Allow for this book", 1, true),
                    list(buttonTexts(cap.shown[1])))
            end)
        end)
    end)
    TestRunner:test("Regenerate: a picture from before S7 is judged by its frame; the book's Never refuses", function()
        local Gates = require("koassistant.request.privacy_gates")
        local real_overrides = Gates.bookOverrides
        local framed = ImageGenerator.buildPrompt("Mara ran.", { window = { prev = "Before.", next = " After." } }, {})
        local ok, err = pcall(withApikeys, { openai = "sk-real-key" }, function()
            withRun("unused", function(cap)
                ImageGenerator._regenerateImpl({ name = "x.jpg", entry = { prompt = framed }, prompt = framed },
                    config({ image_gen_provider = "openai", nearby_text_sharing = "ask" }), mockSettings({}))
                TestRunner:assert(cap.shown[1] and cap.shown[1].title:find("will send to OpenAI", 1, true),
                    "the frame's text around asked for")
            end)
            Gates.bookOverrides = function() return { nearby_text = false } end
            withRun("unused", function(cap)
                ImageGenerator._regenerateImpl({ name = "x.jpg", prompt = "A lamp.",
                    entry = { prompt = "A lamp.", kinds = { "nearby_text" }, book_file = "/books/b.epub" } },
                    config({ image_gen_provider = "openai" }), mockSettings({}))
                TestRunner:assertEquals(cap.image, nil, "nothing sent")
                TestRunner:assert(cap.shown[1] and cap.shown[1].title:find("Regenerate needs text around what you tap", 1, true),
                    cap.shown[1] and cap.shown[1].title)
            end)
        end)
        Gates.bookOverrides = real_overrides
        if not ok then error(err, 0) end
    end)
    TestRunner:test("Regenerate with a chat provider that cannot draw asks which provider first", function()
        withApikeys({ openai = "sk-real-key" }, function()
            withRun("unused", function(cap)
                ImageGenerator._regenerateImpl({ name = "x.jpg", entry = { prompt = "A lamp." }, prompt = "A lamp." },
                    config({}), mockSettings({}))
                TestRunner:assert(cap.shown[1] and cap.shown[1].title:find("can't make images", 1, true),
                    cap.shown[1] and cap.shown[1].title)
                TestRunner:assertEquals(cap.image, nil)
            end)
        end)
    end)
    TestRunner:test("Regenerate: an empty prompt draws nothing", function()
        withRun("unused", function(cap)
            ImageGenerator._regenerateImpl({ name = "x.jpg", entry = {}, prompt = "  " }, config({}), mockSettings({}))
            TestRunner:assertEquals(cap.image, nil)
        end)
    end)

    print("  [The gallery's list and hold view (S7)]")
    -- The gallery requires Menu and ConfirmBox, which the shared mocks lack:
    -- stubs for the load only, restored after
    local function loadBrowser()
        local saved = { menu = package.loaded["ui/widget/menu"], confirm = package.loaded["ui/widget/confirmbox"] }
        package.loaded["ui/widget/menu"] = saved.menu or {}
        package.loaded["ui/widget/confirmbox"] = saved.confirm or {}
        package.loaded["koassistant.images.image_browser"] = nil
        local ok, mod = pcall(require, "koassistant.images.image_browser")
        package.loaded["ui/widget/menu"], package.loaded["ui/widget/confirmbox"] = saved.menu, saved.confirm
        package.loaded["koassistant.images.image_browser"] = nil
        if not ok then error(mod, 0) end
        return mod
    end
    TestRunner:test("groups: All images, each book with the newest picture first, then Without a book", function()
        local B = loadBrowser()
        local files = { { name = "d.png" }, { name = "c.png" }, { name = "b.png" }, { name = "a.png" } }
        local g = B.groups(files, {
            ["d.png"] = { book_file = "/books/two.epub", book_title = "Two" },
            ["c.png"] = { book_file = "/books/one.epub" },
            ["b.png"] = {},
            ["a.png"] = { book_file = "/books/one.epub", book_title = "One" },
        })
        TestRunner:assertEquals(#g, 4)
        TestRunner:assertEquals(g[1].key, "all")
        TestRunner:assertEquals(#g[1].files, 4)
        TestRunner:assertEquals(g[2].key, "/books/two.epub", "the newest picture's book first")
        TestRunner:assertEquals(g[3].title, "One", "a later entry's title fills a missing one")
        TestRunner:assertEquals(#g[3].files, 2)
        TestRunner:assertEquals(g[4].key, "none")
        TestRunner:assertEquals(g[4].files[1].name, "b.png")
        g = B.groups({ { name = "x.png" } }, {})
        TestRunner:assertEquals(#g, 2, "a picture missing from the index is without a book")
        TestRunner:assertEquals(g[2].key, "none")
        g = B.groups({ { name = "y.png" } }, { ["y.png"] = { book_file = "/books/three.epub" } })
        TestRunner:assertEquals(g[2].title, "three.epub", "no title recorded: the file name")
    end)
    TestRunner:test("holdText: who drew it, the provenance, then the prompt", function()
        local B = loadBrowser()
        TestRunner:assertEquals(B.holdText({ prompt = "P", provenance = "Written by W.", provider = "openai", model = "m1" }),
            "Drawn by OpenAI / m1.\nWritten by W.\n\nP")
        TestRunner:assertEquals(B.holdText({ prompt = "P" }), "P", "before S7: the prompt alone")
    end)

    print("  [The picture popup (S9, B537)]")
    local ImageOptions = require("koassistant.images.image_options")
    TestRunner:test("popupItems: a computed label reaches the quick-settings popup", function()
        local items = ImageOptions.popupItems({ { text_func = function() return "Custom…" end, callback = function() end } })
        TestRunner:assertEquals(items[1].text, "Custom…")
    end)
    TestRunner:test("the picture popup's labels: the note and the picks, cut on one line", function()
        TestRunner:assertEquals(ImageOptions.noteLabel(nil), "Add a note…")
        TestRunner:assertEquals(ImageOptions.noteLabel("  "), "Add a note…", "a blank note is no note")
        TestRunner:assertEquals(ImageOptions.noteLabel("at dusk,\n one lit window"), "Note: at dusk, one lit window")
        local long = ImageOptions.noteLabel(string.rep("a", 50))
        TestRunner:assertEquals(long, "Note: " .. string.rep("a", 40) .. "…", "a long note is cut")
        TestRunner:assertEquals(ImageOptions.picksLabel({}), "X-Ray entries: none ▾")
        TestRunner:assertEquals(ImageOptions.picksLabel({ "Gil Rook", "Hollowmere" }), "X-Ray entries: Gil Rook, Hollowmere ▾")
    end)
    TestRunner:test("addNoteEntries: a note's entries first, the earlier note's go, room made by the passage's (B537)", function()
        local xray = { type = "fiction", characters = {
            { name = "Gil Rook" }, { name = "Mara" }, { name = "Tam" }, { name = "Orrin" }, { name = "Hester" },
            { name = "Cass" }, { name = "Jory" },
        } }
        local function list(st) return table.concat(st.picked, "|") end
        local st = { picked = { "Gil Rook" } }
        local left = ImageOptions.addNoteEntries(st, xray, "Mara holds the lamp", "Gil Rook waited.")
        TestRunner:assertEquals(list(st), "Mara|Gil Rook", "the note's first")
        TestRunner:assertEquals(#left, 0)
        ImageOptions.addNoteEntries(st, xray, "Mara again", "Gil Rook waited.")
        TestRunner:assertEquals(list(st), "Mara|Gil Rook", "never twice")
        ImageOptions.addNoteEntries(st, xray, "Tam at dusk", "Gil Rook waited.")
        TestRunner:assertEquals(list(st), "Tam|Gil Rook", "the earlier note's Mara goes with it")
        ImageOptions.addNoteEntries(st, xray, nil, "Gil Rook waited.")
        TestRunner:assertEquals(list(st), "Gil Rook", "a cleared note takes its entries along")
        st = { picked = {} }
        ImageOptions.addNoteEntries(st, xray, "at dusk", "Nobody here.")
        TestRunner:assertEquals(list(st), "", "a note that names nobody adds nobody")
        -- the passage named five: the note's entry takes a passage entry's place
        local passage = "Gil Rook, Mara, Tam, Orrin and Hester."
        st = { picked = { "Gil Rook", "Mara", "Tam", "Orrin", "Hester" } }
        left = ImageOptions.addNoteEntries(st, xray, "and Cass", passage)
        TestRunner:assertEquals(list(st), "Cass|Gil Rook|Mara|Tam|Orrin", "five at most, the passage's last gives way")
        TestRunner:assertEquals(#left, 0)
        -- five picked by hand: nothing gives way, the note's entry is reported
        st = { picked = { "Gil Rook", "Mara", "Tam", "Orrin", "Hester" } }
        left = ImageOptions.addNoteEntries(st, xray, "and Jory", "Nobody here.")
        TestRunner:assertEquals(list(st), "Gil Rook|Mara|Tam|Orrin|Hester", "hand picks stay")
        TestRunner:assertEquals(table.concat(left, "|"), "Jory", "left out, for the notice")
    end)
    TestRunner:test("the picture popup's rows (B537): this picture, then each setting by name and value, a pick saved", function()
        local features = { image_gen_provider = "openai", image_gen_style = "ink" }
        local popup
        local plugin = {
            settings = { data = { features = features }, flush = function() end,
                readSetting = function(_self, k) return k == "features" and features or nil end },
            updateConfigFromSettings = function() end,
            imageStyleItems = function(_self, _after)
                return {
                    { text = "Book illustration", checked_func = function() return features.image_gen_style == "illustration" end,
                      callback = function() features.image_gen_style = "illustration" end },
                    { text = "Ink drawing", checked_func = function() return features.image_gen_style == "ink" end,
                      callback = function() features.image_gen_style = "ink" end },
                    { text_func = function() return "Custom…" end, opens_dialog = true,
                      checked_func = function() return false end, callback = function() popup = "custom" end },
                }
            end,
            showQuickSettingsPopup = function(_self, title, items, _close, on_close)
                popup = { title = title, items = items, on_close = on_close }
            end,
        }
        local function pick(text)
            for _idx, it in ipairs(popup.items) do
                if it.text == text then
                    it.callback()
                    popup.on_close()
                    return
                end
            end
            error("no item " .. text)
        end
        withApikeys({ openai = "sk-real-key" }, function()
            local rebuilt = 0
            local function rebuild() rebuilt = rebuilt + 1 end
            local state = {}
            local xray = { type = "fiction", characters = { { name = "Gil Rook" } } }
            local spec = { writer = true, note = true, xray = xray, passage = "Gil came in.", state = state }
            local rows = ImageOptions.rows(plugin, spec, rebuild)
            local ids, by = {}, {}
            for _idx, r in ipairs(rows) do ids[#ids + 1] = r.id; by[r.id] = r end
            TestRunner:assertEquals(table.concat(ids, ","), "picture,style,look,drawn")
            TestRunner:assert(by.picture.gap == nil and by.style.gap == true and by.look.gap == nil,
                "the picture's own buttons, then the settings as one table below a space")
            TestRunner:assertEquals(by.picture.items[1].text, "Add a note…")
            TestRunner:assertEquals(by.picture.items[2].text, "X-Ray entries: none ▾")
            TestRunner:assert(by.picture.items[2].enabled, "the picks button is live with the writer on")
            TestRunner:assertEquals(by.style.items[1].text, "Prompt: Written by AI ▾",
                "Write the prompt with AI as a dial, on by default")
            TestRunner:assertEquals(by.style.items[2].text, "Style: Ink drawing ▾", "the creation form's dials: name, value, arrow")
            TestRunner:assertEquals(by.look.items[1].text, "Shape: Fit my screen ▾", "Shape on its default")
            TestRunner:assertEquals(by.look.items[2].text, "Detail: Draft ▾", "Detail on its default")
            TestRunner:assertEquals(by.drawn.items[1].text, "Provider: OpenAI ▾")
            TestRunner:assertEquals(by.drawn.items[2].text, "Model: gpt-image-2.6-flare ▾", "the model that draws, by its id")
            -- a value opens its list; a pick is the setting, then the popup rebuilds
            by.look.items[1].callback()
            TestRunner:assertEquals(popup.title, "Shape: Fit my screen", "titled as Settings titles the row")
            TestRunner:assert(popup.on_close == rebuild, "the list comes back to the popup")
            pick("Portrait")
            TestRunner:assertEquals(features.image_gen_shape, "portrait")
            TestRunner:assertEquals(rebuilt, 1)
            rows = ImageOptions.rows(plugin, spec, rebuild)
            for _idx, r in ipairs(rows) do by[r.id] = r end
            TestRunner:assertEquals(by.look.items[1].text, "Shape: Portrait ▾", "the rebuilt row shows the pick")
            by.style.items[2].callback()
            pick("Book illustration")
            TestRunner:assertEquals(features.image_gen_style, "illustration")
            by.style.items[2].callback()
            TestRunner:assertEquals(popup.items[3].text, "Custom…", "a computed label")
            popup.items[3].callback()
            TestRunner:assertEquals(popup, "custom", "Custom… opens its own box (it rebuilds the popup itself)")
            -- the provider's picker, titled as Settings titles the row
            by.drawn.items[1].callback()
            TestRunner:assertEquals(popup.title, "Provider: OpenAI")
            TestRunner:assert(popup.on_close == rebuild, "the picker comes back to the popup")
            -- the writer off, picked in the Prompt list: nothing reads the picks
            by.style.items[1].callback()
            TestRunner:assertEquals(popup.title, "Prompt")
            TestRunner:assert(popup.items[1].checked_func() and not popup.items[2].checked_func(),
                "the list stands on Written by AI")
            pick("Written by AI, from the passage, the entries and your note")
            TestRunner:assert(features.image_gen_writer ~= false, "picking the value it has changes nothing")
            pick("The passage as is, with your note and the style")
            TestRunner:assertEquals(features.image_gen_writer, false)
            rows = ImageOptions.rows(plugin, spec, rebuild)
            for _idx, r in ipairs(rows) do by[r.id] = r end
            TestRunner:assert(by.picture.items[2].enabled == false, "the picks button grays with the writer off")
            TestRunner:assertEquals(by.style.items[1].text, "Prompt: Passage as is ▾")
            -- the picture's own state on the buttons
            state.note, state.picked = "at dusk", { "Gil Rook" }
            rows = ImageOptions.rows(plugin, spec, rebuild)
            TestRunner:assertEquals(rows[1].items[1].text, "Note: at dusk")
            TestRunner:assertEquals(rows[1].items[2].text, "X-Ray entries: Gil Rook ▾")
            -- no X-Ray entries to pick: no picks button
            rows = ImageOptions.rows(plugin, { writer = true, note = true, xray = { type = "fiction" }, state = {} }, rebuild)
            TestRunner:assertEquals(#rows[1].items, 1, "the note alone")
            -- the gallery's: settings only, the Style alone on its row
            rows = ImageOptions.rows(plugin, {}, rebuild)
            ids = {}
            for _idx, r in ipairs(rows) do ids[#ids + 1] = r.id end
            TestRunner:assertEquals(table.concat(ids, ","), "style,look,drawn")
            TestRunner:assert(rows[1].gap == nil, "no space over the first table")
            TestRunner:assertEquals(#rows[1].items, 1, "no Prompt button where no prompt is written")
            -- a retired id shows as the model that draws (the request's resolver)
            features.image_gen_provider = "xai"
            features.image_gen_model_xai = "grok-imagine-image-pro"
            withApikeys({ xai = "xai-real-key" }, function()
                rows = ImageOptions.rows(plugin, {}, rebuild)
                for _idx, r in ipairs(rows) do by[r.id] = r end
                TestRunner:assertEquals(by.drawn.items[2].text, "Model: grok-imagine-image-2.0 ▾")
            end)
            -- a long typed style is cut on its button
            features.image_gen_provider = "openai"
            local long = string.rep("a 1920s travel poster ", 8)
            plugin.imageStyleItems = function(_self, _after)
                return { { text_func = function() return "Custom (" .. long .. ")" end,
                    checked_func = function() return true end, callback = function() end, opens_dialog = true } }
            end
            rows = ImageOptions.rows(plugin, {}, rebuild)
            TestRunner:assert(#rows[1].items[1].text <= 56 and rows[1].items[1].text:find("… ▾$") ~= nil,
                "cut: " .. rows[1].items[1].text)
            -- a chat provider that cannot draw: no model
            features.image_gen_provider = "auto"
            features.provider = "anthropic"
            rows = ImageOptions.rows(plugin, {}, rebuild)
            for _idx, r in ipairs(rows) do by[r.id] = r end
            TestRunner:assertEquals(#by.drawn.items, 1, "no model button")
            TestRunner:assertEquals(by.drawn.items[1].text, "Provider: Follow main provider ▾")
        end)
    end)

    TestRunner:test("providerFirst: the question before the popup only when the chat provider cannot draw", function()
        local saved_ask = ImageGenerator.askProvider
        local asked, picked_cb
        ImageGenerator.askProvider = function(main, keyed, _plugin, on_pick)
            asked = { main = main, keyed = table.concat(keyed, ",") }
            picked_cb = on_pick
        end
        local features = {}
        local plugin = {
            settings = { data = { features = features }, flush = function() end,
                readSetting = function(_self, k) return k == "features" and features or nil end,
                saveSetting = function(_self, k, v) if k == "features" then features = v end end },
            updateConfigFromSettings = function() end,
        }
        local ok, err = pcall(function()
            withApikeys({ openai = "sk-real-key" }, function()
                local ready = 0
                features.image_gen_provider = "openai"
                ImageGenerator.providerFirst(plugin, function() ready = ready + 1 end)
                TestRunner:assertEquals(ready, 1, "a provider that draws: the popup at once")
                TestRunner:assert(asked == nil, "no question")
                features.image_gen_provider = "auto"
                features.provider = "anthropic"
                ImageGenerator.providerFirst(plugin, function() ready = ready + 1 end)
                TestRunner:assertEquals(ready, 1, "the question first")
                TestRunner:assertEquals(asked.main, "anthropic")
                TestRunner:assertEquals(asked.keyed, "openai", "the keyed image providers")
                picked_cb("openai")
                TestRunner:assertEquals(features.image_gen_provider, "openai", "the answer saved as Provider")
                TestRunner:assertEquals(ready, 2, "then the popup")
            end)
            withApikeys({}, function()
                asked = nil
                local ready = 0
                features.image_gen_provider = "auto"
                ImageGenerator.providerFirst(plugin, function() ready = ready + 1 end)
                TestRunner:assert(ready == 1 and asked == nil, "no key at all: nothing to ask, the generator's notice says it")
            end)
        end)
        ImageGenerator.askProvider = saved_ask
        if not ok then error(err, 0) end
    end)

    print("  [The main provider (B462)]")
    TestRunner:test("ConfigHelper.mainProvider: Settings, then configuration.lua, then Anthropic", function()
        local CH = require("koassistant.core.config_helper")
        CH.setFileProvider(nil)
        TestRunner:assertEquals(CH.mainProvider({}), "anthropic")
        TestRunner:assertEquals(CH.mainProvider(nil), "anthropic")
        CH.setFileProvider("gemini")
        TestRunner:assertEquals(CH.mainProvider({}), "gemini", "configuration.lua's provider")
        TestRunner:assertEquals(CH.mainProvider({ provider = "openai" }), "openai", "the Settings pick wins")
        CH.setFileProvider(nil)
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
