-- The key a refused request carried, named under the refusal (#125):
-- ModelConstraints.keySentLine through decorateRequestError, the way the query
-- router decorates every provider refusal. Which refusals name the key (an
-- authentication status, a 403 about the key, a sentence saying the key is not
-- valid whatever its status), what the line shows (name, source, the first 3
-- characters, the length; never the end), and what never gets one (another
-- refusal, a key that is not the reader's, a second decoration).
--
-- The keys are invented and shaped like no provider's key.
--
-- Run: lua tests/unit/test_key_refusal.lua  (or lua tests/run_tests.lua --unit)

local function setupPaths()
    local info = debug.getinfo(1, "S")
    local script_path = info.source:match("@?(.*)")
    local unit_dir = script_path:match("(.+)/[^/]+$") or "."
    local tests_dir = unit_dir:match("(.+)/[^/]+$") or "."
    local plugin_dir = tests_dir:match("(.+)/[^/]+$") or "."
    package.path = table.concat({
        plugin_dir .. "/?.lua", tests_dir .. "/?.lua", tests_dir .. "/lib/?.lua", package.path,
    }, ";")
end
setupPaths()
require("mock_koreader")
local TestRunner = require("test_runner"):new()
local ModelConstraints = require("koassistant.request.model_constraints")

print("Running: test_key_refusal")
print("")

-- apikeys.lua as the module under test sees it (never the real file)
local saved_apikeys = package.loaded["apikeys"]
local FILE_KEY = "fk1-test-not-a-real-key-file-0000-Wq7z"
package.loaded["apikeys"] = { groq = { { key = FILE_KEY, alias = "paid" } } }

local APP_KEY = "Ab8-test-not-a-real-key-app-0000-Zx9q"
local function configWith(key, provider)
    return {
        api_key = key,
        features = { api_keys = { [provider or "gemini"] = { { key = APP_KEY } } } },
    }
end
local function decorate(err, provider, config)
    return ModelConstraints.decorateRequestError(err, provider, "m-1", config)
end
local function hasLine(out) return out:find("The key sent (", 1, true) ~= nil end

TestRunner:test("a sentence saying the key is not valid names the key, whatever the status", function()
    local out = decorate("HTTP 400: API key not valid. Please pass a valid API key. (INVALID_ARGUMENT)",
        "gemini", configWith(APP_KEY))
    TestRunner:assertTrue(hasLine(out), "the key is named: " .. out)
    TestRunner:assertTrue(out:find('The key sent (added in the app) begins with "Ab8" and is '
        .. #APP_KEY .. " characters long.", 1, true) ~= nil, "its source, its start and its length")
    TestRunner:assertTrue(out:find("missing its first few characters", 1, true) ~= nil, "what to compare")
    local incorrect = decorate("HTTP 400: Incorrect API key provided: Ab***. You can obtain one from the console.",
        "gemini", configWith(APP_KEY))
    TestRunner:assertTrue(hasLine(incorrect), "an incorrect key")
end)

TestRunner:test("an authentication status names the key, with its name and apikeys.lua as its source", function()
    local out = decorate("HTTP 401: Unauthorized", "groq", { api_key = FILE_KEY, features = {} })
    TestRunner:assertTrue(out:find('The key sent ("paid", from apikeys.lua) begins with "fk1" and is '
        .. #FILE_KEY .. " characters long.", 1, true) ~= nil, out)
    -- the device transport's status line, with no body sentence
    local device = decorate("Error 401: Unauthorized", "groq", { api_key = FILE_KEY, features = {} })
    TestRunner:assertTrue(hasLine(device), "Error 401 too")
end)

TestRunner:test("a 403 names the key only when it is about the key", function()
    TestRunner:assertTrue(hasLine(decorate("HTTP 403: Your API key does not have permission to use the specified resource.",
        "gemini", configWith(APP_KEY))), "a 403 about the key")
    TestRunner:assertFalse(hasLine(decorate("HTTP 403: Country, region, or territory not supported",
        "gemini", configWith(APP_KEY))), "a 403 about the place")
end)

TestRunner:test("other refusals get no key line, and the tips' own words do not count", function()
    local rate = decorate("HTTP 429: You exceeded your current quota, please check your plan and billing details.",
        "gemini", configWith(APP_KEY))
    TestRunner:assertTrue(rate:find(ModelConstraints.HINT_HEADS.burst, 1, true) ~= nil, "the rate-limit tip fired")
    TestRunner:assertFalse(hasLine(rate), "no key line on a rate limit")
    TestRunner:assertFalse(hasLine(decorate(rate, "gemini", configWith(APP_KEY))),
        "nor on its second decoration, whose tip says 'one API key'")
    TestRunner:assertFalse(hasLine(decorate("HTTP 400: Invalid value for 'temperature'.", "gemini",
        configWith(APP_KEY))), "an invalid parameter is not the key")
    TestRunner:assertFalse(hasLine(decorate("HTTP 500: Internal error", "gemini", configWith(APP_KEY))), "a 500")
end)

TestRunner:test("only a key of the reader's own is named, once", function()
    TestRunner:assertFalse(hasLine(decorate("HTTP 401: Unauthorized", "gemini", nil)), "no config")
    TestRunner:assertFalse(hasLine(decorate("HTTP 401: Unauthorized", "gemini", { features = {} })), "no key")
    TestRunner:assertFalse(hasLine(decorate("HTTP 401: Unauthorized", "openai_codex",
        { api_key = "token-test-not-a-key-0000-0000", features = {} })), "a sign-in token is not a key")
    local once = decorate("HTTP 401: Unauthorized", "gemini", configWith(APP_KEY))
    TestRunner:assertEqual(decorate(once, "gemini", configWith(APP_KEY)), once, "a second decoration adds nothing")
end)

TestRunner:test("the key's end never shows, and a short key shows no characters", function()
    local out = decorate("HTTP 401: Unauthorized", "gemini", configWith(APP_KEY))
    TestRunner:assertFalse(out:find(APP_KEY:sub(-4), 1, true) ~= nil, "the last 4 characters are not shown")
    TestRunner:assertFalse(out:find(APP_KEY:sub(4, 12), 1, true) ~= nil, "nor its middle")
    local short = "k7-short"
    local cfg = { api_key = short, features = { api_keys = { gemini = short } } }
    local s = decorate("HTTP 401: Unauthorized", "gemini", cfg)
    TestRunner:assertTrue(s:find("The key sent (added in the app) is 8 characters long.", 1, true) ~= nil, s)
end)

package.loaded["apikeys"] = saved_apikeys

return TestRunner:summary()
