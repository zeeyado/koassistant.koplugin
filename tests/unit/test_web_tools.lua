--[[
Unit Tests for koassistant_web_tools.lua

Covers the pure half of the web-search backend engine
(docs/web_search_tool_plan.md phase 1):
- request building: SearXNG URL shape + query encoding + base-url trimming,
  Tavily POST body/headers
- response normalization per backend from fixture JSON, including the luajson
  null-sentinel guards (null title/content/answer must not crash or leak)
- result capping (MAX_RESULTS) and UTF-8-safe snippet truncation
- formatResults rendering (numbered refs keep URLs; empty results -> nil)
- sourcesFrom provenance mapping
- backendReady / credentialFor (unknown backend, missing credential,
  bare-host healing for searxng)

The network path (WebTools.search / BaseHandler.fetchAsync) is subprocess +
UI-loop territory — live-tested, not unit-tested here beyond the synchronous
config-error branches.

Run: lua tests/run_tests.lua --unit
]]

package.path = package.path .. ";./?.lua;./?/init.lua"
require("tests.lib.mock_koreader")

local json = require("json")
local WebTools = require("koassistant_web_tools")

local T = {
    passed = 0,
    failed = 0,
}

function T:test(name, fn)
    local ok, err = pcall(fn)
    if ok then
        self.passed = self.passed + 1
        print(string.format("  ✓ %s", name))
    else
        self.failed = self.failed + 1
        print(string.format("  ✗ %s: %s", name, tostring(err)))
    end
end

function T:assert(condition, message)
    if not condition then error(message or "Assertion failed", 2) end
end

function T:assertEquals(expected, actual, message)
    if expected ~= actual then
        error(string.format("%s\nexpected: %s\nactual:   %s",
            message or "Values not equal", tostring(expected), tostring(actual)), 2)
    end
end

-- luajson null sentinel: decoding real JSON null yields whatever the library
-- uses (a truthy function value in KOReader's luajson; possibly nil in other
-- json builds the harness may load). Decode from raw JSON so fixtures carry
-- REAL nulls either way.
local function decode(raw)
    local ok, decoded = pcall(json.decode, raw)
    T:assert(ok, "fixture JSON must decode: " .. tostring(decoded))
    return decoded
end

print("\n=== Request building ===")

T:test("searxng: URL shape, encoding, trailing-slash trim", function()
    local backend = WebTools.getBackend("searxng")
    local req = backend.buildRequest("hello world & more", "http://my.host:8888///")
    T:assertEquals("http://my.host:8888/search?q=hello%20world%20%26%20more&format=json", req.url)
    T:assertEquals("GET", req.method)
    T:assert(req.body == nil, "searxng is a GET, no body")
end)

T:test("urlencode: unreserved kept, reserved escaped", function()
    T:assertEquals("a-b._~9", WebTools._urlencode("a-b._~9"))
    T:assertEquals("caf%C3%A9", WebTools._urlencode("café"))
    T:assertEquals("a%2Fb%3Fc%3Dd", WebTools._urlencode("a/b?c=d"))
end)

T:test("tavily: POST body carries query and caps, Bearer header", function()
    local backend = WebTools.getBackend("tavily")
    local req = backend.buildRequest("some question", "tvly-KEY")
    T:assertEquals("https://api.tavily.com/search", req.url)
    T:assertEquals("POST", req.method)
    T:assertEquals("Bearer tvly-KEY", req.headers["Authorization"])
    local body = decode(req.body)
    T:assertEquals("some question", body.query)
    T:assertEquals(WebTools.MAX_RESULTS, body.max_results)
    T:assertEquals(true, body.include_answer)
    T:assertEquals(false, body.include_raw_content)
end)

print("\n=== SearXNG normalization ===")

T:test("searxng: results fold with title/url/snippet", function()
    local backend = WebTools.getBackend("searxng")
    local norm = backend.parse(decode([[{
        "query": "q",
        "results": [
            {"title": "First", "url": "https://a.example/x", "content": "Alpha  beta\n\tgamma."},
            {"title": "Second", "url": "https://b.example/y", "content": "Delta."}
        ]
    }]]))
    T:assert(norm.ok, "parse should succeed")
    T:assertEquals(2, #norm.results)
    T:assertEquals("First", norm.results[1].title)
    T:assertEquals("https://a.example/x", norm.results[1].url)
    T:assertEquals("Alpha beta gamma.", norm.results[1].snippet, "whitespace runs collapse")
    T:assert(norm.answer == nil, "searxng has no answer field")
end)

T:test("searxng: null fields survive (sentinel guard)", function()
    local backend = WebTools.getBackend("searxng")
    local norm = backend.parse(decode([[{
        "results": [
            {"title": null, "url": "https://a.example/x", "content": null},
            {"title": "OK", "url": null, "content": "text"}
        ]
    }]]))
    T:assert(norm.ok, "parse should succeed")
    T:assertEquals(2, #norm.results)
    T:assertEquals("Untitled", norm.results[1].title, "null title -> Untitled")
    T:assert(norm.results[1].snippet == nil, "null content -> no snippet")
    T:assert(norm.results[2].url == nil, "null url -> nil")
end)

T:test("searxng: caps at MAX_RESULTS", function()
    local items = {}
    for i = 1, 10 do
        table.insert(items, string.format('{"title": "R%d", "url": "https://e/%d", "content": "c"}', i, i))
    end
    local backend = WebTools.getBackend("searxng")
    local norm = backend.parse(decode('{"results": [' .. table.concat(items, ",") .. ']}'))
    T:assertEquals(WebTools.MAX_RESULTS, #norm.results)
end)

T:test("searxng: missing results key -> ok=false", function()
    local backend = WebTools.getBackend("searxng")
    local norm = backend.parse(decode('{"message": "rate limited"}'))
    T:assertEquals(false, norm.ok)
    T:assert(norm.error ~= nil, "error message present")
end)

print("\n=== Tavily normalization ===")

T:test("tavily: answer + results", function()
    local backend = WebTools.getBackend("tavily")
    local norm = backend.parse(decode([[{
        "answer": "Short summary.",
        "results": [
            {"title": "Doc", "url": "https://t.example/d", "content": "Body text."}
        ]
    }]]))
    T:assert(norm.ok, "parse should succeed")
    T:assertEquals("Short summary.", norm.answer)
    T:assertEquals(1, #norm.results)
end)

T:test("tavily: null answer -> nil (sentinel guard)", function()
    local backend = WebTools.getBackend("tavily")
    local norm = backend.parse(decode('{"answer": null, "results": []}'))
    T:assert(norm.ok, "parse should succeed")
    T:assert(norm.answer == nil, "null answer must not leak")
end)

print("\n=== Snippet truncation ===")

T:test("long snippet truncates on a UTF-8 boundary", function()
    -- 199 ASCII chars then a 2-byte char straddling the 200-byte cut.
    local snippet = string.rep("a", 199) .. "éxxxx"
    local backend = WebTools.getBackend("searxng")
    local norm = backend.parse(decode(json.encode({
        results = { { title = "T", url = "https://e/1", content = snippet } },
    })))
    local out = norm.results[1].snippet
    T:assert(#out <= WebTools.SNIPPET_MAX_CHARS + 3, "capped (plus ellipsis)")
    T:assert(not out:find("\195$"), "no dangling UTF-8 lead byte")
    T:assertEquals(string.rep("a", 199) .. "…", out)
end)

print("\n=== formatResults / sourcesFrom ===")

T:test("formatResults: numbered refs with URLs and snippets", function()
    local text = WebTools.formatResults("my query", {
        ok = true,
        answer = "The answer.",
        results = {
            { title = "One", url = "https://a/1", snippet = "S1" },
            { title = "Two", url = nil, snippet = nil },
        },
    })
    T:assert(text:find('Web search results for "my query":', 1, true), "header names the query")
    T:assert(text:find("Summary: The answer.", 1, true), "answer rendered")
    T:assert(text:find("[1] One - https://a/1", 1, true), "numbered ref keeps URL")
    T:assert(text:find("S1", 1, true), "snippet rendered")
    T:assert(text:find("[2] Two", 1, true), "url-less ref renders title only")
end)

T:test("formatResults: failure/empty -> nil", function()
    T:assert(WebTools.formatResults("q", { ok = false, error = "x" }) == nil)
    T:assert(WebTools.formatResults("q", { ok = true, results = {} }) == nil)
    T:assert(WebTools.formatResults("q", nil) == nil)
end)

T:test("sourcesFrom: url-bearing results only, provenance shape", function()
    local sources = WebTools.sourcesFrom({
        ok = true,
        results = {
            { title = "One", url = "https://a/1" },
            { title = "NoUrl" },
        },
    })
    T:assertEquals(1, #sources)
    T:assertEquals("https://a/1", sources[1].url)
    T:assertEquals("One", sources[1].title)
    T:assert(WebTools.sourcesFrom({ ok = true, results = {} }) == nil)
end)

print("\n=== Backend registry / readiness ===")

T:test("backendIds: phase-1 set in stable order", function()
    local ids = WebTools.backendIds()
    T:assertEquals("searxng", ids[1])
    T:assertEquals("tavily", ids[2])
end)

T:test("backendReady: unknown backend", function()
    local ready, reason = WebTools.backendReady("nope", nil)
    T:assertEquals(false, ready)
    T:assertEquals("unknown", reason)
end)

T:test("backendReady: missing credential", function()
    local ready, reason = WebTools.backendReady("tavily", nil)
    T:assertEquals(false, ready)
    T:assertEquals("credential", reason)
end)

T:test("search: synchronous error paths (unknown backend / empty query / unconfigured)", function()
    local got
    local cancel = WebTools.search("nope", "q", nil, function(norm) got = norm end)
    T:assert(cancel == nil and got and got.ok == false, "unknown backend errors synchronously")
    got = nil
    cancel = WebTools.search("searxng", "   ", nil, function(norm) got = norm end)
    T:assert(cancel == nil and got and got.ok == false, "empty query errors synchronously")
    -- Only meaningful when no real tavily_api_key is configured on this
    -- machine (dev checkouts carry a live apikeys.lua the key store reads).
    if WebTools.credentialFor("tavily", nil) == nil then
        got = nil
        cancel = WebTools.search("tavily", "real query", nil, function(norm) got = norm end)
        T:assert(cancel == nil and got and got.ok == false, "unconfigured backend errors synchronously")
        T:assert(got.error:find("Tavily", 1, true), "error names the backend")
    end
end)

print(string.format("\n=== Results: %d passed, %d failed ===", T.passed, T.failed))
return T.failed == 0
