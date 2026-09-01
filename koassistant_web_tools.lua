--[[
Web search backends — phase 1 of the local web-search family
(docs/web_search_tool_plan.md §2b: SearXNG self-hosted + Tavily hosted).

This module is the backend-neutral ENGINE both delivery mechanisms consume
(tool-loop and search-then-inject wire in later slices — nothing here decides
WHEN to search):
- per-backend clients build the HTTP request and parse the provider response
  into one neutral shape: { ok = true, answer = string|nil,
  results = { { title, url, snippet } } } or { ok = false, error = string }
- formatResults renders the numbered-reference block injected into model
  context ([1] title - url, snippets capped; plan §3 — citations kept, unlike
  the fork's URL-stripping)
- search() runs the fetch off the UI loop via BaseHandler.fetchAsync
  (subprocess + parent poll; parent-side DNS, macOS fork-safe)

Credentials live in apikeys.lua / the GUI key store under the backend's
credential name (searxng_base_url is the instance URL, not a key — same
storage, same GUI-overrides-file resolution order via listApiKeys).

All decoded provider fields are type-checked: KOReader's luajson decodes JSON
null to a TRUTHY function sentinel (see luajson-null-sentinel memory).
]]

local logger = require("koassistant_logger")

local WebTools = {}

WebTools.MAX_RESULTS = 3
WebTools.SNIPPET_MAX_CHARS = 200

-- Null-sentinel guard: only a non-empty string passes.
local function str(v)
    if type(v) == "string" and v ~= "" then return v end
    return nil
end

-- UTF-8-safe truncation: cut at max_chars bytes, then walk back over
-- continuation bytes (0x80-0xBF) so a multi-byte sequence is never split.
local function truncateUtf8(s, max_chars)
    if type(s) ~= "string" or #s <= max_chars then return s end
    local cut = max_chars
    while cut > 1 do
        local b = s:byte(cut + 1)
        if not b or b < 0x80 or b > 0xBF then break end
        cut = cut - 1
    end
    return s:sub(1, cut) .. "…"
end

-- Collapse whitespace runs (snippets arrive with newlines/tabs from HTML text).
local function cleanSnippet(s)
    s = str(s)
    if not s then return nil end
    s = s:gsub("%s+", " "):gsub("^%s+", ""):gsub("%s+$", "")
    if s == "" then return nil end
    return truncateUtf8(s, WebTools.SNIPPET_MAX_CHARS)
end

-- RFC 3986 query-component percent-encoding (local: KOReader's util is not
-- loadable under the unit-test harness, and the encoder is 6 lines).
local function urlencode(s)
    return (s:gsub("[^%w%-%._~]", function(c)
        return string.format("%%%02X", string.byte(c))
    end))
end
WebTools._urlencode = urlencode  -- test seam

-- Fold a provider results array into the neutral shape (shared by both
-- backends — SearXNG and Tavily both use {title, url, content} entries).
local function foldResults(items)
    local results = {}
    if type(items) ~= "table" then return results end
    for _idx, item in ipairs(items) do
        if #results >= WebTools.MAX_RESULTS then break end
        if type(item) == "table" then
            local title = str(item.title)
            local url = str(item.url)
            if title or url then
                table.insert(results, {
                    title = title or "Untitled",
                    url = url,
                    snippet = cleanSnippet(item.content),
                })
            end
        end
    end
    return results
end

-- Backend registry. Each backend:
--   id, label            picker identity
--   credential           apikeys.lua / GUI key-store name
--   keyless              true = credential is a URL, not a secret (SearXNG)
--   buildRequest(query, credential) -> { url, method, headers?, body? }
--   parse(decoded)       decoded JSON table -> neutral result shape
local BACKENDS = {}

BACKENDS.searxng = {
    id = "searxng",
    label = "SearXNG",
    credential = "searxng_base_url",
    keyless = true,
    buildRequest = function(query, credential)
        local base = credential:gsub("/+$", "")
        return {
            url = base .. "/search?q=" .. urlencode(query) .. "&format=json",
            method = "GET",
        }
    end,
    parse = function(decoded)
        if type(decoded) ~= "table" or type(decoded.results) ~= "table" then
            return { ok = false, error = "unexpected SearXNG response shape" }
        end
        return { ok = true, results = foldResults(decoded.results) }
    end,
}

BACKENDS.tavily = {
    id = "tavily",
    label = "Tavily",
    credential = "tavily_api_key",
    buildRequest = function(query, credential)
        local json = require("json")
        return {
            url = "https://api.tavily.com/search",
            method = "POST",
            headers = {
                ["Content-Type"] = "application/json",
                ["Authorization"] = "Bearer " .. credential,
            },
            body = json.encode({
                query = query,
                max_results = WebTools.MAX_RESULTS,
                search_depth = "basic",
                include_answer = true,
                include_raw_content = false,
            }),
        }
    end,
    parse = function(decoded)
        if type(decoded) ~= "table" or type(decoded.results) ~= "table" then
            return { ok = false, error = "unexpected Tavily response shape" }
        end
        local norm = { ok = true, results = foldResults(decoded.results) }
        norm.answer = cleanSnippet(str(decoded.answer))
        return norm
    end,
}

-- Stable picker order (phase 1 set).
local BACKEND_ORDER = { "searxng", "tavily" }

function WebTools.backendIds()
    return BACKEND_ORDER
end

function WebTools.getBackend(id)
    return BACKENDS[id]
end

--- The backend's configured credential (nil when missing). SearXNG's
--- "credential" is its base URL; both resolve through the shared key store
--- (GUI entries override apikeys.lua, placeholders filtered).
function WebTools.credentialFor(id, settings)
    local backend = BACKENDS[id]
    if not backend then return nil end
    local BaseHandler = require("koassistant_api.base")
    local cred = BaseHandler.getApiKey(backend.credential, settings)
    if id == "searxng" and cred and not cred:match("^https?://") then
        -- A bare host is a config mistake we can heal; anything else is not a URL.
        cred = "http://" .. cred
    end
    return cred
end

--- Usability check for pickers/pre-flight.
--- @return boolean ready, string|nil reason ("unknown" | "credential")
function WebTools.backendReady(id, settings)
    if not BACKENDS[id] then return false, "unknown" end
    if not WebTools.credentialFor(id, settings) then return false, "credential" end
    return true
end

--- Render the neutral result shape as the context block handed to the model.
--- Numbered references keep URLs (research-mode citations); snippets are
--- already capped by the parse step.
function WebTools.formatResults(query, norm)
    if type(norm) ~= "table" or norm.ok ~= true then return nil end
    local lines = {}
    table.insert(lines, string.format('Web search results for "%s":', query))
    if norm.answer then
        table.insert(lines, "")
        table.insert(lines, "Summary: " .. norm.answer)
    end
    local results = norm.results or {}
    if #results == 0 and not norm.answer then
        return nil
    end
    for i, r in ipairs(results) do
        table.insert(lines, "")
        if r.url then
            table.insert(lines, string.format("[%d] %s - %s", i, r.title, r.url))
        else
            table.insert(lines, string.format("[%d] %s", i, r.title))
        end
        if r.snippet then
            table.insert(lines, r.snippet)
        end
    end
    return table.concat(lines, "\n")
end

--- Sources list for the provenance surface ("Show Sources"), matching the
--- {url, title} entry shape harvested from native provider search.
function WebTools.sourcesFrom(norm)
    if type(norm) ~= "table" or norm.ok ~= true then return nil end
    local sources = {}
    for _idx, r in ipairs(norm.results or {}) do
        if r.url then
            table.insert(sources, { url = r.url, title = r.title })
        end
    end
    if #sources == 0 then return nil end
    return sources
end

--- Run one search off the UI loop.
--- @param id string backend id
--- @param query string search query
--- @param settings LuaSettings|nil (credential resolution)
--- @param on_done function(norm) — always called once with the neutral shape
---        (never after cancel); may be called synchronously on config errors
--- @return function|nil cancel
function WebTools.search(id, query, settings, on_done)
    local backend = BACKENDS[id]
    if not backend then
        on_done({ ok = false, error = "unknown search backend: " .. tostring(id) })
        return nil
    end
    if type(query) == "string" then
        query = query:gsub("^%s+", ""):gsub("%s+$", "")
    end
    if not str(query) then
        on_done({ ok = false, error = "empty search query" })
        return nil
    end
    local credential = WebTools.credentialFor(id, settings)
    if not credential then
        on_done({ ok = false, error = backend.label .. " is not configured" })
        return nil
    end

    local request = backend.buildRequest(query, credential)
    local BaseHandler = require("koassistant_api.base")
    logger.dbg("KOAssistant: web search via", backend.id, "query length", #query)
    return BaseHandler.fetchAsync(request.url, {
        method = request.method,
        headers = request.headers,
        body = request.body,
        timeout = 45,
    }, function(status_code, body)
        if not status_code then
            on_done({ ok = false, error = backend.label .. ": " .. (str(body) or "network error") })
            return
        end
        if status_code ~= 200 then
            logger.dbg("KOAssistant: web search non-200", backend.id, status_code, "body length", #(body or ""))
            on_done({ ok = false, error = string.format("%s: HTTP %d", backend.label, status_code) })
            return
        end
        local json = require("json")
        local ok, decoded = pcall(json.decode, body)
        if not ok then
            on_done({ ok = false, error = backend.label .. ": unparseable response" })
            return
        end
        on_done(backend.parse(decoded))
    end)
end

return WebTools
