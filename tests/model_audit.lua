#!/usr/bin/env lua
-- Model Audit & Capability Probe (agenda item 20)
--
-- Turns model updates from archaeology into a reviewed diff:
--   1. DISCOVERY - fetch each provider's live model list (endpoints from
--      ModelLists._docs[provider].api_list) and diff against our curated arrays.
--   2. PROBE - for a chosen model, run the empirical capability battery that
--      /models endpoints do NOT report: temperature acceptance, reasoning
--      default on/off, effort ladder (incl. xhigh/max), disable support,
--      output-token ceiling, tools acceptance, forced tool_choice (the runner's
--      gather/final modes - the Z.AI wave-1.5 failure class a bare tools probe
--      cannot see), and an SSE streaming smoke test.
--   3. DRAFT - emit copy-pasteable stanzas for model_constraints.lua plus
--      reminders for koassistant_model_lists.lua. NEVER auto-applied - a
--      human reviews the diff and places tiers by hand.
--
-- Usage:
--   lua tests/model_audit.lua                          # discovery diff, all keyed providers
--   lua tests/model_audit.lua anthropic gemini         # discovery diff, subset
--   lua tests/model_audit.lua --probe anthropic claude-opus-5   # probe one model (LIVE calls)
--   lua tests/model_audit.lua --probe-new              # discovery, then probe each NEW model
--   lua tests/model_audit.lua --probe-new openai       # ... for one provider
--   lua tests/model_audit.lua --recheck [providers]    # drift sweep over CURATED models (LIVE,
--                                                      # 2 micro-requests each): still served?
--                                                      # reasoning default? temp rule still right?
--   lua tests/model_audit.lua --recheck --ceilings     # + output-ceiling check (3rd request/model;
--                                                      # gemini rides free metadata instead)
--   Options: --verbose   full error bodies + ignored-id lists
--
-- Probes make real API micro-requests (max_tokens 32..1024); a full battery is
-- ~20-30 requests (T7 hardening 2026-08-14 added the temperature-value sweep,
-- the real-dispatch-shape leg incl. the Anthropic cache-engagement pair, and
-- the two-round tool replay through the plugin's own ToolWire adapters with
-- the runner's real specs), fractions of a cent on most providers. Perplexity
-- caveat: every request also bills one web search.
--
-- Requires luarocks modules (luasocket, luasec, dkjson). Run this FIRST:
--   eval "$(luarocks --lua-version 5.5 path)"
-- (without it HTTP/JSON are unavailable and the script aborts with this hint).

-- Setup package path for plugin modules (same pattern as inspect.lua)
local function setupPaths()
    local info = debug.getinfo(1, "S")
    local script_path = info.source:match("@?(.*)")
    local script_dir = script_path:match("(.*/)") or "./"
    local plugin_dir = script_dir:gsub("tests/$", ""):gsub("/$", "")
    if plugin_dir == "" then plugin_dir = "." end
    package.path = script_dir .. "lib/?.lua;" ..
                   script_dir .. "?.lua;" ..
                   plugin_dir .. "/?.lua;" ..
                   package.path
    return plugin_dir
end
setupPaths()

-- Real network is required for everything this tool does; detect BEFORE the
-- mocks kick in (mock_koreader stubs ssl.https when luasocket is absent).
local HAS_NETWORK = pcall(require, "ssl.https")

-- Load mocks so plugin modules resolve under plain lua. Side benefit: the
-- hermeticity block empties the custom_models.lua / derived-cache override
-- layers, so "current resolution" below reflects what SHIPS (curated +
-- family fallbacks), not this machine's local overrides.
require("mock_koreader")

local JSON_OK, json = pcall(require, "json")
local ModelLists = require("koassistant_model_lists")
local ModelConstraints = require("model_constraints")
local Defaults = require("koassistant_api.defaults")
local TestConfig = require("test_config")

local ModelAudit = {}

--------------------------------------------------------------------------------
-- Output helpers
--------------------------------------------------------------------------------

local C = {
    red = "\27[31m", green = "\27[32m", yellow = "\27[33m",
    cyan = "\27[36m", dim = "\27[90m", bold = "\27[1m", off = "\27[0m",
}

local function printf(fmt, ...)
    print(string.format(fmt, ...))
end

local function banner(text)
    printf("\n%s== %s %s%s", C.bold, text, string.rep("=", math.max(4, 74 - #text)), C.off)
end

--------------------------------------------------------------------------------
-- Pure helpers (unit-tested via tests/unit/test_model_audit.lua)
--------------------------------------------------------------------------------

-- Plain-substring fragments that mark a fetched id as not-a-chat-model (or not
-- a curation target). Matched lowercase, plain find. Humans review the diff;
-- --verbose prints what was ignored, so misclassification is visible.
ModelAudit.NOISE = {
    common = {
        "embed", "rerank", "whisper", "tts", "audio", "moderation",
        "transcribe", "dall-e", "image", "ocr", "guard", "sora", "imagen",
        "veo", "vision-preview", "deep-research",
    },
    openai = {
        "davinci", "babbage", "text-", "realtime", "computer-use", "codex",
        "search-preview", "chatgpt", "instruct", "-pro",
    },
    gemini = {
        "gemma", "aqa", "learnlm", "-live", "banana", "robotics", "computer-use",
        "lyria", "antigravity", "omni", "customtools",  -- music gen / IDE agent / speech / variant
        "video-understanding",  -- video-input EAP variants (3.7-flash-video-understanding-eap)
    },
    mistral = {
        "open-mistral", "open-mixtral", "voxtral", "moderation",
        "codestral", "devstral", "-code", "fim", "vibe", "leanstral",  -- coding/agent side products
    },
    xai = { "imagine" },  -- image/video gen
}

-- Returns the matching fragment (truthy) when the id should be ignored.
function ModelAudit.isNoise(provider, id)
    local lower = id:lower()
    local function hit(list)
        if not list then return nil end
        for _i, frag in ipairs(list) do
            if lower:find(frag, 1, true) then return frag end
        end
        return nil
    end
    return hit(ModelAudit.NOISE.common) or hit(ModelAudit.NOISE[provider])
end

-- Ids we LOOKED AT and decided not to curate (menu bloat, superseded, rolling
-- aliases whose constraints would silently go stale when the provider repoints
-- them). They print dim with the reason instead of flooding NEW on every run.
-- DELETE an entry to resurface the id. Reviewed 2026-07-25.
ModelAudit.DELIBERATE_SKIPS = {
    anthropic = {
        ["claude-opus-4-6"] = "superseded by opus-4-8 (custom-add if wanted)",
        ["claude-opus-4-7"] = "superseded by opus-4-8 (custom-add if wanted)",
    },
    gemini = {
        ["gemini-3-flash-preview"] = "3.0 preview, superseded by 3.1+ stable",
        ["gemini-3-pro-preview"] = "3.0 preview, superseded by 3.1+ stable",
        ["gemini-3.1-flash-lite-preview"] = "preview of curated 3.1-flash-lite",
        ["gemini-flash-latest"] = "rolling alias - curated constraints would go stale invisibly",
        ["gemini-flash-lite-latest"] = "rolling alias - curated constraints would go stale invisibly",
        ["gemini-pro-latest"] = "rolling alias - curated constraints would go stale invisibly",
        ["gemini-2.0-flash"] = "old generation",
        ["gemini-2.0-flash-001"] = "old generation",
        ["gemini-2.0-flash-lite"] = "old generation",
        ["gemini-2.0-flash-lite-001"] = "old generation",
    },
    openai = {
        ["chat-latest"] = "ChatGPT-tuned rolling alias",
        ["gpt-5.3-chat-latest"] = "ChatGPT-tuned rolling alias",
    },
    mistral = {
        ["mistral-medium"] = "curated via mistral-medium-latest",
        ["mistral-medium-3"] = "curated via mistral-medium-latest",
        ["mistral-medium-3-5"] = "curated via mistral-medium-latest",
        ["mistral-medium-3.5"] = "curated via mistral-medium-latest",
        ["mistral-tiny-latest"] = "legacy tiny tier",
        ["mistral-tiny-2407"] = "legacy tiny tier",
        ["glm-5-2"] = "partner-hosted GLM - probe blocked (rate-limited on our tier 2026-08-14)",
        ["zai-glm-5-2"] = "partner-hosted GLM - probe blocked (rate-limited on our tier 2026-08-14)",
    },
    xai = {
        ["grok-4.20-multi-agent-0309"] = "specialised multi-agent variant",
    },
}

-- Announcement watch: ids we KNOW exist (announcements, direct probes) that
-- the provider's list endpoint does not return or our key cannot yet access -
-- the glm-5.3 class (released 2026-08-14, absent from Z.AI's known-incomplete
-- /models list, probe got "no permission" under the staged rollout). Discovery
-- prints a standing reminder per entry and upgrades it to "NOW LISTED - probe"
-- / "now curated - delete" as state changes; delete an entry once the id is
-- curated or abandoned.
ModelAudit.WATCH = {
    zai = {
        ["glm-5.3"] = "released 2026-08-14; probe got 'no permission' (staged rollout) - re-probe",
    },
}

-- Pure: classify a watched id against the curated array and the fetched list.
function ModelAudit.watchStatus(id, curated_set, fetched)
    if curated_set and curated_set[id] then return "curated" end
    if fetched and fetched[id] then return "listed" end
    return "watching"
end

-- Direct-provider id -> OpenRouter marketplace slug prefix, for enriching NEW
-- ids with the pricing + context_length the marketplace fetch already returns
-- (tier PROPOSALS - a human still places tiers and defaults).
ModelAudit.OPENROUTER_PREFIX = {
    anthropic = "anthropic", openai = "openai", gemini = "google",
    mistral = "mistralai", xai = "x-ai", deepseek = "deepseek",
    zai = "z-ai", perplexity = "perplexity",
}

-- OR ids use periods where direct ids use dashes (and vice versa); fold.
local function orNormalize(s)
    return s:lower():gsub("%.", "-")
end

-- Pure: find provider/model in an OpenRouter marketplace map (id -> meta).
-- Returns slug, meta - or nil when unmapped/unmatched.
function ModelAudit.openrouterLookup(or_models, provider, model)
    local prefix = ModelAudit.OPENROUTER_PREFIX[provider]
    if not prefix or type(or_models) ~= "table" then return nil end
    local want = orNormalize(prefix .. "/" .. model)
    for id, meta in pairs(or_models) do
        if orNormalize(id) == want then return id, meta end
    end
    return nil
end

-- Pure: human-readable price/context line from OR meta (nil when it has neither).
-- OR pricing is per TOKEN as strings ("0.000002") - scale to per-million.
function ModelAudit.openrouterAnnotation(meta)
    if type(meta) ~= "table" then return nil end
    local parts = {}
    local p = type(meta.pricing) == "table" and meta.pricing
    local pin = p and tonumber(p.prompt)
    local pout = p and tonumber(p.completion)
    if pin and pout then
        table.insert(parts, string.format("$%.2f in / $%.2f out per M tokens",
            pin * 1e6, pout * 1e6))
    end
    if type(meta.context_length) == "number" then
        table.insert(parts, string.format("ctx %dK", math.floor(meta.context_length / 1000)))
    end
    if #parts == 0 then return nil end
    return table.concat(parts, " - ")
end

-- Dated/numbered snapshots and -latest aliases of an id we already curate are
-- not "new models" (gpt-4o vs gpt-4o-2024-08-06, gemini -001, mistral -2509).
-- Each candidate base is also checked against the curated "-latest" alias,
-- since Mistral is curated via aliases (magistral-medium-2509 -> *-latest).
function ModelAudit.isSnapshotOf(id, curated_set)
    local candidates = {}
    local function addBase(base)
        if base then table.insert(candidates, base) end
    end
    addBase(id:match("^(.-)%-%d%d%d%d%-%d%d%-%d%d$"))   -- -YYYY-MM-DD
    addBase(id:match("^(.-)%-%d%d%d%d$"))               -- -YYMM (mistral) / -MMDD
    addBase(id:match("^(.-)%-%d%d%d$"))                 -- -001 / -002
    addBase(id:match("^(.-)%-latest$"))
    for _i, base in ipairs(candidates) do
        if curated_set[base] then return base end
        if curated_set[base .. "-latest"] then return base .. "-latest" end
    end
    return nil
end

-- Release timestamp from list metadata: OpenAI-shaped lists report `created`
-- (epoch), Anthropic reports `created_at` (ISO). nil when unavailable.
function ModelAudit.modelTimestamp(meta)
    if type(meta) ~= "table" then return nil end
    if type(meta.created) == "number" then return meta.created end
    if type(meta.created_at) == "string" then
        local y, mo, d = meta.created_at:match("^(%d%d%d%d)%-(%d%d)%-(%d%d)")
        if y then
            return os.time({ year = tonumber(y), month = tonumber(mo),
                             day = tonumber(d), hour = 12 })
        end
    end
    return nil
end

ModelAudit.RECENT_SECONDS = 180 * 86400  -- uncurated ids older than this go to `stale`

-- curated: array of ids; fetched: map id -> meta; now: os.time() (nil = no
-- staleness split, everything uncurated lands in `new`).
-- Returns { new={}, stale={}, removed={}, snapshots={}, ignored={}, deliberate={}, known=n }.
function ModelAudit.diffLists(provider, curated, fetched, now)
    local result = { new = {}, stale = {}, removed = {}, snapshots = {}, ignored = {},
                     deliberate = {}, known = 0 }
    local curated_set = {}
    for _i, id in ipairs(curated) do curated_set[id] = true end
    local skips = ModelAudit.DELIBERATE_SKIPS[provider] or {}

    local fetched_ids = {}
    for id in pairs(fetched) do table.insert(fetched_ids, id) end
    table.sort(fetched_ids)

    for _i, id in ipairs(fetched_ids) do
        if curated_set[id] then
            result.known = result.known + 1
        elseif ModelAudit.isSnapshotOf(id, curated_set) then
            table.insert(result.snapshots, id)
        elseif ModelAudit.isNoise(provider, id) then
            table.insert(result.ignored, id)
        elseif skips[id] then
            table.insert(result.deliberate, { id = id, reason = skips[id] })
        else
            -- No timestamp = assume recent (loud beats silent for a discovery tool)
            local ts = ModelAudit.modelTimestamp(fetched[id])
            if now and ts and (now - ts) > ModelAudit.RECENT_SECONDS then
                table.insert(result.stale, id)
            else
                table.insert(result.new, id)
            end
        end
    end
    for _i, id in ipairs(curated) do
        if not fetched[id] then table.insert(result.removed, id) end
    end
    return result
end

-- Extract a human-readable error message from a decoded error body.
function ModelAudit.errText(decoded, raw)
    if type(decoded) == "table" then
        local e = decoded.error
        if type(e) == "table" and type(e.message) == "string" then return e.message end
        if type(e) == "string" then return e end
        if type(decoded.message) == "string" then return decoded.message end
    end
    return tostring(raw or ""):sub(1, 400)
end

-- Parse the output-token ceiling out of an oversized-max_tokens error.
-- Takes the largest number that is >= 1024 and BELOW the absurd value we sent
-- (excludes echoes of our own value and large date-like ids such as 20251001).
-- vLLM-family CONTEXT errors also echo the request total ("maximum context
-- length is 12288 tokens. However, you requested 20480 tokens") — the
-- largest-number rule would return 20480, not the bound, so the stated
-- context length is checked FIRST (same order as the runtime's
-- parseMaxTokensError; T7 P1 fix 2026-08-14).
function ModelAudit.parseCeiling(err, sent)
    local text = tostring(err)
    local ctx = text:match("context length[^%d]*(%d+)")
        or text:match("context window[^%d]*(%d+)")
    if ctx then
        local n = tonumber(ctx)
        if n and n >= 1024 and n < sent then return n end
    end
    local best
    for num in text:gmatch("%d+") do
        local n = tonumber(num)
        if n and n >= 1024 and n < sent and (not best or n > best) then best = n end
    end
    return best
end

-- Reasoning evidence in an OpenAI-wire success response (nil = none found).
function ModelAudit.reasoningEvidence(decoded)
    if type(decoded) ~= "table" then return nil end
    local usage = decoded.usage
    if type(usage) == "table" then
        local det = usage.completion_tokens_details
        if type(det) == "table" and type(det.reasoning_tokens) == "number"
                and det.reasoning_tokens > 0 then
            return "reasoning_tokens=" .. det.reasoning_tokens
        end
    end
    local choice = type(decoded.choices) == "table" and decoded.choices[1]
    local msg = type(choice) == "table" and choice.message
    if type(msg) == "table" then
        if type(msg.reasoning_content) == "string" and #msg.reasoning_content > 0 then
            return "reasoning_content present"
        end
        if type(msg.reasoning) == "string" and #msg.reasoning > 0 then
            return "reasoning field present"
        end
        if type(msg.content) == "string" and msg.content:find("<think>", 1, true) then
            return "<think> tags in content"
        end
    end
    return nil
end

-- Fragments marking an error body as transient capacity/limit noise, matched
-- lowercase plain-find (only consulted on non-200s).
ModelAudit.TRANSIENT_FRAGMENTS = {
    "rate limit", "rate_limit", "high demand", "overloaded", "over capacity",
    "temporarily unavailable", "try again", "please retry", "server busy",
}

-- True when a FAILED request is worth retrying: nil code (network-layer
-- failure), 429/5xx, or a transient body fragment. Permission/validation
-- errors ("no permission", "invalid temperature") stay non-transient so a
-- retry never blurs a real verdict.
function ModelAudit.isTransient(code, text)
    if code == nil then return true end
    local n = tonumber(code)
    if n == 429 or (n and n >= 500 and n < 600) then return true end
    local lower = tostring(text or ""):lower()
    for _i, frag in ipairs(ModelAudit.TRANSIENT_FRAGMENTS) do
        if lower:find(frag, 1, true) then return true end
    end
    return false
end

--------------------------------------------------------------------------------
-- HTTP (lazy-required so the pure helpers stay loadable without luarocks)
--------------------------------------------------------------------------------

-- Transient failures (429 quota, 5xx capacity, network drops) get a short
-- backoff-and-retry before giving up: a rate-limited BASELINE used to abort a
-- whole battery, and a mid-battery transient recorded a false REJECTED
-- (gemini-3.7-flash "high demand" + the mistral rate-limit runs, 2026-08-14).
local RETRY_DELAYS = { 3, 8 }

local function sleepSeconds(s)
    local ok, socket = pcall(require, "socket")
    if ok and socket and socket.sleep then socket.sleep(s) end
end

local function httpGetOnce(url, headers)
    local https = require("ssl.https")
    local ltn12 = require("ltn12")
    local chunks = {}
    local ok, code = https.request({
        url = url, method = "GET", headers = headers,
        sink = ltn12.sink.table(chunks),
    })
    local text = table.concat(chunks)
    if not ok then return nil, "network: " .. tostring(code), nil end
    if code ~= 200 then
        return nil, string.format("HTTP %s: %s", tostring(code), text:sub(1, 300)),
            tonumber(code) or code
    end
    return text
end

local function httpGet(url, headers)
    local text, err, code
    for attempt = 1, #RETRY_DELAYS + 1 do
        text, err, code = httpGetOnce(url, headers)
        if text or not ModelAudit.isTransient(code, err) then return text, err end
        local delay = RETRY_DELAYS[attempt]
        if not delay then break end
        printf("  %stransient fetch failure - retrying in %ds (attempt %d/%d)%s",
            C.dim, delay, attempt + 1, #RETRY_DELAYS + 1, C.off)
        sleepSeconds(delay)
    end
    return text, err
end

-- POST JSON; returns http_code (number|string), decoded (table|nil), raw text.
local function httpPostJsonOnce(url, headers, body_tbl)
    local https = require("ssl.https")
    local ltn12 = require("ltn12")
    local payload = json.encode(body_tbl)
    local chunks = {}
    local hdrs = { ["Content-Type"] = "application/json",
                   ["Content-Length"] = tostring(#payload) }
    for k, v in pairs(headers or {}) do hdrs[k] = v end
    local ok, code = https.request({
        url = url, method = "POST", headers = hdrs,
        source = ltn12.source.string(payload),
        sink = ltn12.sink.table(chunks),
    })
    local text = table.concat(chunks)
    if not ok then return nil, nil, "network: " .. tostring(code) end
    local decoded
    if text ~= "" then
        local dok, d = pcall(json.decode, text)
        if dok and type(d) == "table" then decoded = d end
    end
    return tonumber(code) or code, decoded, text
end

local function httpPostJson(url, headers, body_tbl)
    local code, decoded, raw
    for attempt = 1, #RETRY_DELAYS + 1 do
        code, decoded, raw = httpPostJsonOnce(url, headers, body_tbl)
        if code == 200 or not ModelAudit.isTransient(code, raw) then
            return code, decoded, raw
        end
        local delay = RETRY_DELAYS[attempt]
        if not delay then break end
        printf("  %stransient HTTP %s - retrying in %ds (attempt %d/%d)%s",
            C.dim, tostring(code), delay, attempt + 1, #RETRY_DELAYS + 1, C.off)
        sleepSeconds(delay)
    end
    return code, decoded, raw
end

--------------------------------------------------------------------------------
-- Discovery
--------------------------------------------------------------------------------

local function bearerHeaders(key)
    return { ["Authorization"] = "Bearer " .. key }
end

-- {data=[{id=...}]} -> map id -> meta (type-checked: luajson-null paranoia)
local function parseOpenAIShapedList(data)
    if type(data) ~= "table" or type(data.data) ~= "table" then
        return nil, "unexpected response shape"
    end
    local out = {}
    for _i, m in ipairs(data.data) do
        if type(m) == "table" and type(m.id) == "string" then out[m.id] = m end
    end
    return out
end

local DISCOVERY = {
    anthropic = {
        query = "?limit=1000",
        headers = function(key)
            return { ["x-api-key"] = key, ["anthropic-version"] = "2023-06-01" }
        end,
        parse = parseOpenAIShapedList,
    },
    openai   = { headers = bearerHeaders, parse = parseOpenAIShapedList },
    deepseek = { headers = bearerHeaders, parse = parseOpenAIShapedList },
    mistral  = {
        headers = bearerHeaders,
        parse = function(data)
            local models, err = parseOpenAIShapedList(data)
            if not models then return nil, err end
            -- Mistral reports capabilities; drop ids that can't chat at all.
            for id, m in pairs(models) do
                local caps = type(m) == "table" and m.capabilities
                if type(caps) == "table" and caps.completion_chat == false then
                    models[id] = nil
                end
            end
            return models
        end,
    },
    xai = { headers = bearerHeaders, parse = parseOpenAIShapedList },
    -- NVIDIA lists ~100 ids of which most are NOT served: probed live 2026-08-20,
    -- 47 of 77 chat ids returned 404 and 9 accepted the connection then never
    -- answered (a silent hang the UI cannot render). Treat every "+ NEW" here as
    -- a CANDIDATE ONLY and --probe it before adding to the curated array.
    nvidia = { headers = bearerHeaders, parse = parseOpenAIShapedList },
    -- zai's list endpoint OMITS some serving ids (glm-4.7-flash probed alive
    -- 2026-07-25 while absent from the list) - soften REMOVED to verify-first.
    zai = { headers = bearerHeaders, parse = parseOpenAIShapedList, incomplete_list = true },
    gemini = {
        query = function(key) return "?key=" .. key .. "&pageSize=1000" end,
        parse = function(data)
            if type(data) ~= "table" or type(data.models) ~= "table" then
                return nil, "unexpected response shape"
            end
            local out = {}
            for _i, m in ipairs(data.models) do
                if type(m) == "table" and type(m.name) == "string" then
                    local can_generate = false
                    for _j, method in ipairs(type(m.supportedGenerationMethods) == "table"
                                             and m.supportedGenerationMethods or {}) do
                        if method == "generateContent" then can_generate = true end
                    end
                    if can_generate then
                        out[m.name:match("models/(.+)") or m.name] = m
                    end
                end
            end
            return out
        end,
    },
    -- Marketplaces: hundreds of backend models; "new" is meaningless noise.
    -- Instead we verify our curated ids still exist and cross-check their
    -- reported supported_parameters against our resolution layer.
    openrouter = { headers = bearerHeaders, parse = parseOpenAIShapedList, marketplace = true },
    -- OpenCode (#107, 2026-09-05): /models is public on both plans; the Zen
    -- list (ModelLists._docs) also carries GPT/Claude/Gemini ids that answer
    -- only on the Responses/Messages doors — "+ NEW" is a candidate, --probe it.
    opencode = { headers = bearerHeaders, parse = parseOpenAIShapedList, marketplace = true },
    opencode_go = { headers = bearerHeaders, parse = parseOpenAIShapedList },
}

-- One key per provider entry, no sharing (maintainer 2026-09-05: OpenCode
-- Zen and Go are separate `opencode` / `opencode_go` entries; the same
-- string may sit under both).
local function keyFor(apikeys, provider)
    return apikeys[provider]
end

local function fetchProviderList(provider, api_key)
    local docs = ModelLists._docs[provider]
    local url = docs and docs.api_list
    if not url then return nil, "no list endpoint documented (_docs.api_list)" end
    local adapter = DISCOVERY[provider]
    if not adapter then return nil, "no discovery adapter" end

    if adapter.query then
        url = url .. (type(adapter.query) == "function" and adapter.query(api_key) or adapter.query)
    end
    local headers = adapter.headers and adapter.headers(api_key) or nil
    local text, err = httpGet(url, headers)
    if not text then return nil, err end
    local dok, data = pcall(json.decode, text)
    if not dok or type(data) ~= "table" then return nil, "response not valid JSON" end
    local models, perr = adapter.parse(data)
    if not models then return nil, perr end
    return models, nil, data
end

-- Cross-check one curated OpenRouter id's supported_parameters against our
-- resolution layer. Returns a list of mismatch strings (empty = consistent).
local function openrouterMismatches(id, meta)
    local params = type(meta) == "table" and meta.supported_parameters
    if type(params) ~= "table" then return {} end
    local set = {}
    for _i, p in ipairs(params) do
        if type(p) == "string" then set[p] = true end
    end
    local mismatches = {}
    local our_tools = ModelConstraints.supportsCapability("openrouter", id, "tools")
    if set.tools and not our_tools then
        table.insert(mismatches, "reports tools, we resolve false")
    elseif our_tools and not set.tools then
        table.insert(mismatches, "we resolve tools, endpoint doesn't report it")
    end
    local profile = ModelConstraints.getReasoningProfile("openrouter", id)
    local we_reason = profile and profile.axis ~= "none"
    if set.reasoning and not we_reason then
        table.insert(mismatches, "reports reasoning, our profile is none/passthrough")
    elseif we_reason and not set.reasoning and not (profile and profile.generic) then
        table.insert(mismatches, "curated reasoning profile, endpoint doesn't report reasoning")
    end
    return mismatches
end

-- Runs discovery for one provider, prints the report, returns diff (or nil).
local function runDiscovery(provider, api_key, verbose)
    banner(provider)
    local curated = ModelLists[provider]
    if type(curated) ~= "table" or #curated == 0 then
        printf("  %sskipped: no curated model array%s", C.dim, C.off)
        return nil
    end
    if not TestConfig.isValidApiKey(api_key) and provider ~= "ollama" then
        printf("  %sskipped: no API key in apikeys.lua%s", C.dim, C.off)
        return nil
    end

    local fetched, err = fetchProviderList(provider, api_key)
    if not fetched then
        printf("  %sfetch failed:%s %s", C.red, C.off, tostring(err))
        return nil
    end

    if DISCOVERY[provider].marketplace then
        local total = 0
        for _ignored in pairs(fetched) do total = total + 1 end
        printf("  marketplace: %d live ids (new-model diff suppressed) - checking %d curated ids",
            total, #curated)
        for _i, id in ipairs(curated) do
            if not fetched[id] then
                printf("  %s- REMOVED%s  %s  %s!! users' saved picks will 400%s",
                    C.red, C.off, id, C.red, C.off)
            else
                local mismatches = openrouterMismatches(id, fetched[id])
                if #mismatches > 0 then
                    printf("  %s? %s%s: %s", C.yellow, id, C.off, table.concat(mismatches, "; "))
                elseif verbose then
                    printf("  %s= %s ok%s", C.dim, id, C.off)
                end
            end
        end
        return { new = {}, removed = {} }
    end

    local diff = ModelAudit.diffLists(provider, curated, fetched, os.time())
    printf("  fetched %d chat-relevant ids - curated %d - older uncurated %d - snapshots %d - ignored %d",
        diff.known + #diff.new + #diff.stale + #diff.snapshots, #curated,
        #diff.stale, #diff.snapshots, #diff.ignored)
    if #diff.new > 0 then
        printf("  %sNEW%s (not in koassistant_model_lists.lua):", C.green, C.off)
        for _i, id in ipairs(diff.new) do
            printf("    + %-40s %sprobe: lua tests/model_audit.lua --probe %s %s%s",
                id, C.dim, provider, id, C.off)
        end
    end
    if #diff.stale > 0 then
        printf("  %solder uncurated (released >180d ago, deliberate skips?): %s%s",
            C.dim, table.concat(diff.stale, ", "), C.off)
    end
    if #diff.deliberate > 0 then
        printf("  %sdeliberately skipped (see ModelAudit.DELIBERATE_SKIPS; delete an entry to resurface):%s",
            C.dim, C.off)
        for _i, entry in ipairs(diff.deliberate) do
            printf("    %s. %-38s %s%s", C.dim, entry.id, entry.reason, C.off)
        end
    end
    if #diff.removed > 0 then
        if DISCOVERY[provider].incomplete_list then
            printf("  %sABSENT FROM LIST%s (this provider's list endpoint is known-incomplete):",
                C.yellow, C.off)
            for _i, id in ipairs(diff.removed) do
                printf("    - %s  %sverify: lua tests/model_audit.lua --probe %s %s%s",
                    id, C.dim, provider, id, C.off)
            end
        else
            printf("  %sREMOVED%s (curated but absent from the live list):", C.red, C.off)
            for _i, id in ipairs(diff.removed) do
                printf("    - %s  %s!! users' saved picks will 400 - verify, plan migration%s",
                    id, C.red, C.off)
            end
        end
    end
    if #diff.new == 0 and #diff.removed == 0 then
        printf("  %sin sync%s", C.green, C.off)
    end
    local watch = ModelAudit.WATCH[provider]
    if watch then
        local curated_set = {}
        for _i, id in ipairs(curated) do curated_set[id] = true end
        local wids = {}
        for id in pairs(watch) do table.insert(wids, id) end
        table.sort(wids)
        for _i, id in ipairs(wids) do
            local status = ModelAudit.watchStatus(id, curated_set, fetched)
            if status == "curated" then
                printf("  %swatch entry %s is now CURATED - delete it from ModelAudit.WATCH%s",
                    C.green, id, C.off)
            elseif status == "listed" then
                printf("  %sWATCH -> NOW LISTED:%s %s  %sprobe: lua tests/model_audit.lua --probe %s %s%s",
                    C.green, C.off, id, C.dim, provider, id, C.off)
            else
                printf("  %swatching (not listed): %-24s %s%s", C.yellow, id, watch[id], C.off)
            end
        end
    end
    if verbose then
        if #diff.snapshots > 0 then
            printf("  %ssnapshots: %s%s", C.dim, table.concat(diff.snapshots, ", "), C.off)
        end
        if #diff.ignored > 0 then
            printf("  %signored (noise filter): %s%s", C.dim, table.concat(diff.ignored, ", "), C.off)
        end
    end
    return diff
end

--------------------------------------------------------------------------------
-- Probe engine
--------------------------------------------------------------------------------

local PROBE_PROMPT = "Reply with only: ok"
-- The reasoning-default baseline needs a prompt worth thinking about: ADAPTIVE
-- models skip thinking on trivial prompts, which would misread as "default OFF"
-- (bit the first claude-opus-5 probe run - it thinks by default, but not for "ok").
local REASONING_PROBE_PROMPT = "If a book has 300 pages and I read 40 percent and then 25 more pages, what page am I on? Reply with only the number."
local ABSURD_MAX_TOKENS = 10000000

-- One dummy property everywhere: dkjson encodes EMPTY tables as [], which
-- providers reject where an object is required (properties/input_schema).
local function dummyProps()
    return { ping = { type = "string", description = "Any value." } }
end

--------------------------------------------------------------------------------
-- Real-shape probe material (T7 P1, 2026-08-14). The battery's bare
-- one-message legs are a LOWER BOUND on request complexity; real dispatch
-- always carries a system prompt, usually consecutive user turns (Attach
-- chip, the live spoiler line), and a 4-digit token ask — so each family
-- battery also probes THAT shape, plus a two-round tool replay through the
-- plugin's own ToolWire adapters with the runner's REAL tool specs.
--------------------------------------------------------------------------------

-- Deep copy (plain tables) — the runner's shared spec tables must never be
-- mutated by probe-side encoding tags.
function ModelAudit.deepcopy(t)
    if type(t) ~= "table" then return t end
    local out = {}
    for k, v in pairs(t) do out[k] = ModelAudit.deepcopy(v) end
    return out
end

-- Encoder parity (T7 gap 14): the runtime's KOReader json encodes an empty
-- Lua table as {} (object); dkjson emits [] unless tagged. The real gather
-- specs contain exactly one empty object (the `done` tool's properties) — tag
-- every empty table so dkjson sends the wire the plugin actually sends.
function ModelAudit.markEmptyObjects(t)
    if type(t) ~= "table" then return t end
    if next(t) == nil then
        return setmetatable(t, { __jsontype = "object" })
    end
    for _k, v in pairs(t) do ModelAudit.markEmptyObjects(v) end
    return t
end

-- The runner's real declarations (gather set incl. the empty-properties
-- `done` tool — the field-found Gemini rejection class), probe-safe copy.
local function realToolSpecs()
    local ok, Runner = pcall(require, "koassistant_book_tool_runner")
    if not ok or type(Runner) ~= "table" then return nil end
    local specs = Runner.gather_declarations or Runner.function_declarations
    if type(specs) ~= "table" then return nil end
    return ModelAudit.markEmptyObjects(ModelAudit.deepcopy(specs))
end

-- Per-family renderings, exactly as the handlers render them.
local function anthropicToolDefs(specs)
    local defs = {}
    for _i, spec in ipairs(specs) do
        table.insert(defs, { name = spec.name, description = spec.description,
                             input_schema = spec.parameters })
    end
    return defs
end
local function openaiToolDefs(specs)
    local defs = {}
    for _i, spec in ipairs(specs) do
        table.insert(defs, { type = "function",
            ["function"] = { name = spec.name, description = spec.description,
                             parameters = spec.parameters } })
    end
    return defs
end
-- Mirrors gemini.lua's accommodation: OBJECT schemas with EMPTY properties are
-- rejected ("should be non-empty for OBJECT type"), so such specs omit
-- `parameters` — the accommodation itself is under test here.
local function geminiToolDefs(specs)
    local declarations = {}
    for _i, spec in ipairs(specs) do
        local params = spec.parameters
        if type(params) == "table" and type(params.properties) == "table"
                and next(params.properties) == nil then
            table.insert(declarations, { name = spec.name, description = spec.description })
        else
            table.insert(declarations, spec)
        end
    end
    return { { functionDeclarations = declarations } }
end

local TOOL_REPLAY_PROMPT = "Show me this book's table of contents. Use the toc tool."

-- Real-dispatch history shape: consecutive user turns are DELIBERATE plugin
-- output (Attach chip context message; the live spoiler line rides as its own
-- final user message).
local function realHistory()
    return {
        { role = "user", content = "[Context]\nBook: \"The Probe Book\" by Nobody.\n\n[User Question]\nReply with only: ok" },
        { role = "assistant", content = "ok" },
        { role = "user", content = "Reply with only: ok, once more." },
        { role = "user", content = "The reader is currently at 40% of this book. Do not reveal or discuss anything beyond this point." },
    }
end

-- ~6K chars of system text: comfortably above every Claude model's minimum
-- cacheable prefix (512-4096 tokens by model) so the cache-engagement
-- assertion can't silently no-op the way the old short system block did.
local REAL_SYSTEM_SENTENCE = "You are a careful reading assistant for an e-reader plugin. " ..
    "Ground every answer in the provided book context, cite page numbers when you know them, " ..
    "keep responses short for a small e-ink screen, and never reveal content beyond the " ..
    "reader's stated position. "
local function realSystemText()
    return REAL_SYSTEM_SENTENCE:rep(28)
end

-- Neutral tool-call parse via the plugin's OWN response transformers; falls
-- back to the shared "openai" transformer for providers without one.
local function parseToolCalls(decoded, provider)
    local ResponseParser = require("koassistant_api.response_parser")
    local ok, content = ResponseParser:parseResponse(decoded, provider)
    if not ok or type(content) ~= "table" or not content._tool_calls then
        if provider ~= "openai" then
            ok, content = ResponseParser:parseResponse(decoded, "openai")
            if ok and type(content) == "table" and content._tool_calls then return content end
        end
        return nil
    end
    return content
end

-- Execute the parsed calls with a constant result and append the turn through
-- the plugin's real ToolWire adapter (the one leg that must import plugin
-- code: round-2 failure classes — gemini thought_signature, deepseek
-- reasoning_content, orphaned call ids — live in the adapter's exact output).
local function appendReplayTurn(adapter_key, messages, parsed)
    local ToolWire = require("koassistant_api.tool_wire")
    local adapter = ToolWire.adapters[adapter_key]
    if not adapter then return false end
    local executed = {}
    for _i, call in ipairs(parsed.calls or {}) do
        table.insert(executed, { call = call,
            result = { ok = true, note = "probe: constant tool result", chapters = { "One", "Two" } } })
    end
    adapter.appendToolTurn(messages, parsed.raw_assistant_turn, executed)
    return #executed > 0
end

local function newFacts(family, provider, model)
    return { family = family, provider = provider, model = model,
             efforts = {}, probes = {} }
end

-- HTTP 429 (quota/rate limit) proves nothing about a capability — record it as
-- inconclusive (nil) rather than rejection, so quota noise can't poison a draft
-- (bit a gemini-3.5-flash battery: free-tier per-minute quota mid-ladder).
local function verdict(code)
    if code == 200 then return true end
    if code == 429 then return nil end
    return false
end

local function recordProbe(facts, name, ok, detail)
    table.insert(facts.probes, { name = name, ok = ok, detail = detail })
    local mark
    if ok then
        mark = C.green .. "OK" .. C.off
    elseif ok == nil then
        mark = C.yellow .. "INCONCLUSIVE (quota/rate limit - retry)" .. C.off
    else
        mark = C.red .. "REJECTED" .. C.off
    end
    printf("  [%2d] %-38s %s  %s%s%s",
        #facts.probes, name, mark, C.dim, tostring(detail or ""):sub(1, 90), C.off)
end

-- SSE framing check for the streaming smoke: luasocket buffers the whole
-- response, so this verifies the server ACCEPTS stream=true and answers in SSE
-- framing - it does NOT verify incremental delivery (that needs the real
-- handlers on-device).
function ModelAudit.looksLikeSSE(text)
    if type(text) ~= "string" then return false end
    return text:find("^data:") ~= nil or text:find("\ndata:") ~= nil
        or text:find("^event:") ~= nil or text:find("\nevent:") ~= nil
end

local function recordStreamProbe(facts, code, decoded, raw)
    local name = "streaming (stream=true SSE smoke)"
    if code == 200 and ModelAudit.looksLikeSSE(raw) then
        facts.stream_ok = true
        recordProbe(facts, name, true, "SSE framing in response")
    elseif code == 200 then
        facts.stream_ok = false
        recordProbe(facts, name, false, "200 but non-SSE body - stream param likely ignored")
    else
        facts.stream_ok = verdict(code)
        recordProbe(facts, name, facts.stream_ok, ModelAudit.errText(decoded, raw))
    end
end

-- ---- Anthropic wire ---------------------------------------------------------

local ANTHROPIC_LADDER = { "low", "medium", "high", "xhigh", "max" }

local function probeAnthropic(model, api_key, verbose)
    local facts = newFacts("anthropic", "anthropic", model)
    local url = Defaults.ProviderDefaults.anthropic.base_url
    local headers = { ["x-api-key"] = api_key, ["anthropic-version"] = "2023-06-01" }

    local function req(extra, max_toks, prompt)
        local body = { model = model, max_tokens = max_toks or 32,
                       messages = { { role = "user", content = prompt or PROBE_PROMPT } } }
        for k, v in pairs(extra or {}) do body[k] = v end
        return httpPostJson(url, headers, body)
    end

    -- 1. baseline: reachable? does it think by default?
    local code, decoded, raw = req(nil, 1024, REASONING_PROBE_PROMPT)
    if code ~= 200 then
        recordProbe(facts, "baseline (bare request)", false, ModelAudit.errText(decoded, raw))
        printf("  %sbaseline failed - aborting battery (bad model id / key?)%s", C.red, C.off)
        return facts
    end
    facts.reachable = true
    local has_thinking = false
    for _i, block in ipairs(type(decoded.content) == "table" and decoded.content or {}) do
        if type(block) == "table" and block.type == "thinking" then has_thinking = true end
    end
    facts.default_reasoning = has_thinking
    facts.evidence = has_thinking and "thinking block in bare response" or "no thinking block"
    recordProbe(facts, "baseline (bare request)", true,
        facts.evidence .. " -> default " .. (has_thinking and "ON" or "OFF"))

    -- 2. sampling params
    local tcode, tdec, traw = req({ temperature = 0.7 })
    facts.temp_ok = verdict(tcode)
    if not facts.temp_ok then facts.temp_err = ModelAudit.errText(tdec, traw) end
    recordProbe(facts, "temperature=0.7", facts.temp_ok, facts.temp_err)

    -- 3. explicit disable
    local dcode, ddec, draw = req({ thinking = { type = "disabled" } })
    facts.disable_ok = verdict(dcode)
    if not facts.disable_ok then facts.disable_err = ModelAudit.errText(ddec, draw) end
    recordProbe(facts, 'thinking={type="disabled"}', facts.disable_ok, facts.disable_err)

    -- 4. adaptive + effort ladder
    facts.ladder = ANTHROPIC_LADDER
    for _i, effort in ipairs(ANTHROPIC_LADDER) do
        local ecode, edec, eraw = req({
            thinking = { type = "adaptive" },
            output_config = { effort = effort },
        })
        facts.efforts[effort] = verdict(ecode)
        if ecode == 200 then facts.adaptive_ok = true end
        recordProbe(facts, "adaptive effort=" .. effort, verdict(ecode),
            ecode ~= 200 and ModelAudit.errText(edec, eraw) or nil)
    end
    if facts.adaptive_ok == nil then facts.adaptive_ok = false end

    -- 5. legacy budget mode
    local bcode, bdec, braw = req({
        thinking = { type = "enabled", budget_tokens = 2048 } }, 4096)
    facts.budget_ok = verdict(bcode)
    if not facts.budget_ok then facts.budget_err = ModelAudit.errText(bdec, braw) end
    recordProbe(facts, "extended thinking (budget_tokens)", facts.budget_ok, facts.budget_err)

    -- 6. output ceiling from oversized max_tokens error text
    local ccode, cdec, craw = req(nil, ABSURD_MAX_TOKENS)
    if ccode == 429 then
        recordProbe(facts, "output ceiling (oversized max_tokens)", nil,
            ModelAudit.errText(cdec, craw))
    elseif ccode ~= 200 then
        local err = ModelAudit.errText(cdec, craw)
        facts.ceiling = ModelAudit.parseCeiling(err, ABSURD_MAX_TOKENS)
        recordProbe(facts, "output ceiling (oversized max_tokens)", facts.ceiling ~= nil,
            facts.ceiling and ("ceiling=" .. facts.ceiling) or err)
    else
        recordProbe(facts, "output ceiling (oversized max_tokens)", false,
            "accepted?! no ceiling error - verify by hand")
    end

    -- 7. tools sanity — the runner's REAL declarations (T7 P1.3: array params,
    -- object items, the empty-properties `done` tool; a ping stub can green a
    -- schema shape the plugin never sends). Falls back to the stub only if the
    -- runner module fails to load.
    local real_specs = realToolSpecs()
    local probe_tools = real_specs and anthropicToolDefs(real_specs)
        or { { name = "ping", description = "Connectivity test.",
               input_schema = { type = "object", properties = dummyProps() } } }
    local wcode, wdec, wraw = req({ tools = probe_tools })
    facts.tools_ok = verdict(wcode)
    if not facts.tools_ok then facts.tools_err = ModelAudit.errText(wdec, wraw) end
    recordProbe(facts, real_specs and "tools (real runner specs)" or "tools (minimal function def)",
        facts.tools_ok, facts.tools_err)

    -- 8. forced tool_choice - the runner's gather ("any") and final ("none")
    -- passes need non-auto tool_choice; a bare tools probe can't see this
    -- (the Z.AI wave-1.5 failure class).
    if facts.tools_ok then
        local acode, adec, araw = req({ tools = probe_tools, tool_choice = { type = "any" } })
        facts.tool_choice_any_ok = verdict(acode)
        local adetail = acode ~= 200 and ModelAudit.errText(adec, araw) or nil
        if facts.tool_choice_any_ok == false then
            -- thinking-by-default models reject forced tool_choice; the runner
            -- accommodation is disabling thinking on tool turns (deepseek precedent)
            local rcode = req({ tools = probe_tools, tool_choice = { type = "any" },
                                thinking = { type = "disabled" } })
            if rcode == 200 then
                facts.tool_choice_any_thinking_off = true
                adetail = (adetail or "") .. " | OK with thinking disabled"
            end
        end
        recordProbe(facts, 'tool_choice={type="any"} (gather)', facts.tool_choice_any_ok, adetail)
        local ncode, ndec, nraw = req({ tools = probe_tools, tool_choice = { type = "none" } })
        facts.tool_choice_none_ok = verdict(ncode)
        recordProbe(facts, 'tool_choice={type="none"} (final)', facts.tool_choice_none_ok,
            ncode ~= 200 and ModelAudit.errText(ndec, nraw) or nil)
    end

    -- 9. streaming smoke
    local scode, sdec, sraw = req({ stream = true })
    recordStreamProbe(facts, scode, sdec, sraw)

    -- 10. real dispatch shape (T7 P1.1): system ARRAY with a block breakpoint
    -- + the top-level auto-advancing cache_control (what anthropic_request.lua
    -- sends since 2026-08-14), consecutive-user history, the real resolved
    -- token ask — and an assertion that the cache ENGAGES (below the model's
    -- minimum cacheable prefix it silently no-ops, the shipped-config bug the
    -- campaign measured).
    local real_max = ModelConstraints.clampMaxTokens("anthropic", model,
        ModelConstraints.resolveMaxTokens("anthropic", model, 16384))
    local real_body = {
        model = model, max_tokens = real_max,
        system = { { type = "text", text = realSystemText(),
                     cache_control = { type = "ephemeral" } } },
        cache_control = { type = "ephemeral" },
        messages = realHistory(),
    }
    local r1code, r1dec, r1raw = httpPostJson(url, headers, real_body)
    local r1usage = r1code == 200 and type(r1dec.usage) == "table" and r1dec.usage or {}
    local wrote = (r1usage.cache_creation_input_tokens or 0) > 0
        or (r1usage.cache_read_input_tokens or 0) > 0
    facts.real_shape_ok = verdict(r1code)
    recordProbe(facts, "real shape (system+consecutive users)", facts.real_shape_ok,
        r1code ~= 200 and ModelAudit.errText(r1dec, r1raw)
            or string.format("cache_creation=%s cache_read=%s",
                tostring(r1usage.cache_creation_input_tokens),
                tostring(r1usage.cache_read_input_tokens)))
    if r1code == 200 then
        facts.cache_engaged = wrote
        if not wrote then
            recordProbe(facts, "prompt cache engagement", false,
                "0 cached tokens - prefix below this model's minimum cacheable size?")
        else
            local r2code, r2dec = httpPostJson(url, headers, real_body)
            local r2usage = r2code == 200 and type(r2dec.usage) == "table" and r2dec.usage or {}
            local read_back = (r2usage.cache_read_input_tokens or 0) > 0
            facts.cache_read_ok = r2code == 200 and read_back or verdict(r2code)
            recordProbe(facts, "prompt cache engagement (write then read)",
                facts.cache_read_ok,
                string.format("read_back=%s", tostring(r2usage.cache_read_input_tokens)))
        end
    end

    -- 11. two-round tool replay (T7 P1.2): round 1 forces a call on the real
    -- specs; the result rides back through the plugin's OWN ToolWire adapter;
    -- round 2 must accept the replayed turn. Every known round-2 failure class
    -- is invisible to the single-call legs above.
    if facts.tools_ok and real_specs then
        local t1code, t1dec, t1raw = req({ tools = probe_tools,
            tool_choice = { type = "any" } }, 1024, TOOL_REPLAY_PROMPT)
        local parsed = t1code == 200 and parseToolCalls(t1dec, "anthropic") or nil
        if not parsed then
            recordProbe(facts, "tool replay round 1 (forced call)", verdict(t1code),
                t1code ~= 200 and ModelAudit.errText(t1dec, t1raw) or "no tool call parsed")
        else
            local messages = { { role = "user", content = TOOL_REPLAY_PROMPT } }
            appendReplayTurn("anthropic", messages, parsed)
            local t2code, t2dec, t2raw = req({ messages = messages,
                tools = probe_tools, tool_choice = { type = "none" } }, 1024)
            facts.tool_replay_ok = verdict(t2code)
            recordProbe(facts, "tool replay round 2 (adapter echo)", facts.tool_replay_ok,
                t2code ~= 200 and ModelAudit.errText(t2dec, t2raw) or nil)
        end
    end

    if verbose and facts.temp_err then printf("  %stemp error: %s%s", C.dim, facts.temp_err, C.off) end
    return facts
end

-- ---- OpenAI-compatible chat wire -------------------------------------------

local OPENAI_LADDER = { "none", "minimal", "low", "medium", "high", "xhigh", "max" }

-- Per-provider chat-wire probe configs. url defaults to ProviderDefaults.
local OPENAI_FAMILY = {
    openai     = { effort_key = "reasoning_effort" },
    xai        = { effort_key = "reasoning_effort" },
    perplexity = { effort_key = "reasoning_effort",
                   cost_note = "every Perplexity request also bills one web search" },
    groq       = { effort_key = "reasoning_effort" },
    together   = { effort_key = "reasoning_effort" },
    fireworks  = { effort_key = "reasoning_effort" },
    opencode   = { effort_key = "reasoning_effort",   -- #107: open-weight models on the chat door; reasoning wire = whatever the backend honors (probe decides)
                   extra_headers = { ["x-opencode-session"] = "koassistant-model-audit" } },
    opencode_go = { effort_key = "reasoning_effort",
                   extra_headers = { ["x-opencode-session"] = "koassistant-model-audit" } },
    deepseek   = { binary_key = "thinking" },   -- {type="enabled"/"disabled"}
    zai        = { binary_key = "thinking" },
    mistral    = {},                            -- no reasoning params (magistral always-on)
    qwen       = {},                            -- DashScope compatible-mode; enable_thinking probing TODO (2026-08-15)
    kimi       = {},                            -- Moonshot international; k2.6 has no reasoning params
                                                -- CAUTION: lowest tier = org-wide 3 RPM — expect 429 retries
    openrouter = { reasoning_obj = true,        -- reasoning={effort=..}/{enabled=false}
                   extra_headers = { ["HTTP-Referer"] = "https://github.com/zeeyado/koassistant.koplugin",
                                     ["X-Title"] = "KOAssistant model audit" } },
}

-- Providers whose web search (and gpt-5.x tools) ride the /v1/responses wire -
-- probed as its own battery section. openai_codex excluded (OAuth, not a key).
local RESPONSES_FAMILY = { openai = true, xai = true,
    web_note = "the Responses web probe runs one real search" }

local function probeOpenAIFamily(provider, model, api_key, verbose)
    local facts = newFacts("openai", provider, model)
    local fam = OPENAI_FAMILY[provider]
    local pd = Defaults.ProviderDefaults[provider]
    local url = fam.url or (pd and pd.base_url)
    if not url then
        printf("  %sno chat endpoint known for %s%s", C.red, provider, C.off)
        return facts
    end
    if fam.cost_note then printf("  %snote: %s%s", C.yellow, fam.cost_note, C.off) end
    local headers = bearerHeaders(api_key)
    for k, v in pairs(fam.extra_headers or {}) do headers[k] = v end

    -- token param dance: start with max_tokens, fall back to max_completion_tokens
    local token_key = "max_tokens"
    local function req(extra, max_toks, prompt)
        local body = { model = model,
                       messages = { { role = "user", content = prompt or PROBE_PROMPT } } }
        body[token_key] = max_toks or 256
        for k, v in pairs(extra or {}) do body[k] = v end
        return httpPostJson(url, headers, body)
    end

    -- 1. baseline (+ max_completion_tokens detection)
    local code, decoded, raw = req(nil, 1024, REASONING_PROBE_PROMPT)
    if code ~= 200 then
        local err = ModelAudit.errText(decoded, raw)
        if err:find("max_completion_tokens", 1, true) then
            token_key = "max_completion_tokens"
            facts.needs_max_completion_tokens = true
            code, decoded, raw = req(nil, 1024, REASONING_PROBE_PROMPT)
        end
    end
    if code ~= 200 then
        recordProbe(facts, "baseline (bare request)", false, ModelAudit.errText(decoded, raw))
        printf("  %sbaseline failed - aborting battery (bad model id / key?)%s", C.red, C.off)
        return facts
    end
    facts.reachable = true
    facts.evidence = ModelAudit.reasoningEvidence(decoded)
    facts.default_reasoning = facts.evidence ~= nil
    -- A handful of reasoning tokens on a math prompt is a weak ON signal
    -- (could be bookkeeping overhead rather than a reasoning default).
    local rt = facts.evidence and tonumber(facts.evidence:match("^reasoning_tokens=(%d+)$"))
    facts.weak_reasoning_evidence = (rt ~= nil and rt < 64) or nil
    recordProbe(facts, "baseline (bare request)", true,
        (facts.evidence or "no reasoning evidence") ..
        " -> default " .. (facts.default_reasoning and "ON" or "OFF") ..
        (facts.weak_reasoning_evidence and " (weak signal - verify)" or "") ..
        (facts.needs_max_completion_tokens and " (needs max_completion_tokens)" or ""))

    -- 2. temperature — the plugin's ACTUAL values, not just "is 0.7 legal"
    -- (T7 P1.4): action pins sit at 0.3-0.6, the user spinner allows 0.0-2.0.
    local tcode, tdec, traw = req({ temperature = 0.7 }, 32)
    facts.temp_ok = verdict(tcode)
    if not facts.temp_ok then facts.temp_err = ModelAudit.errText(tdec, traw) end
    recordProbe(facts, "temperature=0.7", facts.temp_ok, facts.temp_err)
    if facts.temp_ok then
        facts.temp_values = {}
        for _i, tv in ipairs({ 0.0, 0.3, 1.0, 2.0 }) do
            local vcode, vdec, vraw = req({ temperature = tv }, 32)
            facts.temp_values[tostring(tv)] = verdict(vcode)
            recordProbe(facts, "temperature=" .. tostring(tv), verdict(vcode),
                vcode ~= 200 and ModelAudit.errText(vdec, vraw) or nil)
        end
    end

    -- 3. reasoning controls
    if fam.effort_key then
        facts.ladder = OPENAI_LADDER
        for _i, effort in ipairs(OPENAI_LADDER) do
            local ecode, edec, eraw = req({ [fam.effort_key] = effort })
            facts.efforts[effort] = verdict(ecode)
            recordProbe(facts, fam.effort_key .. "=" .. effort, verdict(ecode),
                ecode ~= 200 and ModelAudit.errText(edec, eraw) or nil)
        end
        facts.disable_ok = facts.efforts.none
    elseif fam.binary_key then
        facts.binary = true
        local oncode, ondec, onraw = req({ [fam.binary_key] = { type = "enabled" } })
        facts.binary_on_ok = verdict(oncode)
        recordProbe(facts, fam.binary_key .. '={type="enabled"}', facts.binary_on_ok,
            not facts.binary_on_ok and ModelAudit.errText(ondec, onraw) or nil)
        local offcode, offdec, offraw = req({ [fam.binary_key] = { type = "disabled" } })
        facts.binary_off_ok = verdict(offcode)
        facts.disable_ok = facts.binary_off_ok
        recordProbe(facts, fam.binary_key .. '={type="disabled"}', facts.binary_off_ok,
            not facts.binary_off_ok and ModelAudit.errText(offdec, offraw) or nil)
    elseif fam.reasoning_obj then
        facts.ladder = OPENAI_LADDER
        for _i, effort in ipairs(OPENAI_LADDER) do
            local ecode, edec, eraw = req({ reasoning = { effort = effort } })
            facts.efforts[effort] = verdict(ecode)
            recordProbe(facts, "reasoning.effort=" .. effort, verdict(ecode),
                ecode ~= 200 and ModelAudit.errText(edec, eraw) or nil)
        end
        local offcode, offdec, offraw = req({ reasoning = { enabled = false } })
        facts.disable_ok = verdict(offcode)
        recordProbe(facts, "reasoning.enabled=false", facts.disable_ok,
            not facts.disable_ok and ModelAudit.errText(offdec, offraw) or nil)
    end

    -- 4. output ceiling
    local ccode, cdec, craw = req(nil, ABSURD_MAX_TOKENS)
    if ccode == 429 then
        recordProbe(facts, "output ceiling (oversized " .. token_key .. ")", nil,
            ModelAudit.errText(cdec, craw))
    elseif ccode ~= 200 then
        local err = ModelAudit.errText(cdec, craw)
        facts.ceiling = ModelAudit.parseCeiling(err, ABSURD_MAX_TOKENS)
        recordProbe(facts, "output ceiling (oversized " .. token_key .. ")",
            facts.ceiling ~= nil, facts.ceiling and ("ceiling=" .. facts.ceiling) or err)
    else
        recordProbe(facts, "output ceiling (oversized " .. token_key .. ")", false,
            "accepted (provider may clamp silently) - check docs")
    end

    -- 5. tools sanity — the runner's REAL declarations (T7 P1.3; stub fallback
    -- only if the runner module fails to load)
    local real_specs = realToolSpecs()
    local probe_tools = real_specs and openaiToolDefs(real_specs)
        or { { type = "function",
               ["function"] = { name = "ping", description = "Connectivity test.",
                                parameters = { type = "object", properties = dummyProps() } } } }
    local wcode, wdec, wraw = req({ tools = probe_tools })
    facts.tools_ok = verdict(wcode)
    if not facts.tools_ok then facts.tools_err = ModelAudit.errText(wdec, wraw) end
    recordProbe(facts, real_specs and "tools (real runner specs)" or "tools (minimal function def)",
        facts.tools_ok, facts.tools_err)

    -- 6. forced tool_choice (runner gather="required" / final="none" - the
    -- Z.AI wave-1.5 failure class a bare tools probe cannot see)
    if facts.tools_ok then
        local acode, adec, araw = req({ tools = probe_tools, tool_choice = "required" })
        facts.tool_choice_any_ok = verdict(acode)
        local adetail = acode ~= 200 and ModelAudit.errText(adec, araw) or nil
        if facts.tool_choice_any_ok == false and fam.binary_key then
            -- deepseek V4 precedent: thinking mode rejects tool_choice=required;
            -- the handler accommodation is forcing thinking off on tool turns
            local rcode = req({ tools = probe_tools, tool_choice = "required",
                                [fam.binary_key] = { type = "disabled" } })
            if rcode == 200 then
                facts.tool_choice_any_thinking_off = true
                adetail = (adetail or "") .. " | OK with " .. fam.binary_key .. " disabled"
            end
        end
        recordProbe(facts, 'tool_choice="required" (gather)', facts.tool_choice_any_ok, adetail)
        local ncode, ndec, nraw = req({ tools = probe_tools, tool_choice = "none" })
        facts.tool_choice_none_ok = verdict(ncode)
        recordProbe(facts, 'tool_choice="none" (final)', facts.tool_choice_none_ok,
            ncode ~= 200 and ModelAudit.errText(ndec, nraw) or nil)
    end

    -- 7. streaming smoke
    local scode, sdec, sraw = req({ stream = true }, 32)
    recordStreamProbe(facts, scode, sdec, sraw)

    -- 8. OpenRouter bonus: per-model endpoints metadata (what the derive layer reads)
    if provider == "openrouter" then
        local text = httpGet("https://openrouter.ai/api/v1/models/" .. model .. "/endpoints", headers)
        if text then
            local dok, data = pcall(json.decode, text)
            local endpoints = dok and type(data) == "table" and type(data.data) == "table"
                and type(data.data.endpoints) == "table" and data.data.endpoints
            if endpoints then
                local union = {}
                for _i, ep in ipairs(endpoints) do
                    for _j, p in ipairs(type(ep) == "table" and type(ep.supported_parameters) == "table"
                                        and ep.supported_parameters or {}) do
                        if type(p) == "string" then union[p] = true end
                    end
                end
                facts.meta = union
                local names = {}
                for p in pairs(union) do table.insert(names, p) end
                table.sort(names)
                printf("  %ssupported_parameters: %s%s", C.dim, table.concat(names, ", "), C.off)
            end
        end
    end

    -- 10. Responses wire (openai/xai only) - the wire this plugin ACTUALLY uses
    -- for web search (and gpt-5.x book tools); a chat-wire verdict says nothing
    -- about it. Bare acceptance -> web_search tool -> SSE smoke.
    if RESPONSES_FAMILY[provider] then
        printf("  %snote: %s%s", C.yellow, RESPONSES_FAMILY.web_note, C.off)
        local rurl = url:gsub("chat/completions$", "responses")
        local rcode, rdec, rraw = httpPostJson(rurl, headers,
            { model = model, input = PROBE_PROMPT, max_output_tokens = 64, store = false })
        facts.responses_ok = verdict(rcode)
        recordProbe(facts, "Responses wire (bare)", facts.responses_ok,
            rcode ~= 200 and ModelAudit.errText(rdec, rraw) or nil)
        if facts.responses_ok then
            local wcode2, wdec2, wraw2 = httpPostJson(rurl, headers,
                { model = model, input = "What year is it right now? Answer briefly.",
                  max_output_tokens = 128, store = false,
                  tools = { { type = "web_search" } } })
            facts.responses_web_ok = verdict(wcode2)
            recordProbe(facts, "Responses + web_search tool", facts.responses_web_ok,
                wcode2 ~= 200 and ModelAudit.errText(wdec2, wraw2) or nil)
            local rscode, rsdec, rsraw = httpPostJson(rurl, headers,
                { model = model, input = PROBE_PROMPT, max_output_tokens = 64,
                  store = false, stream = true })
            if rscode == 200 then
                facts.responses_stream_ok = ModelAudit.looksLikeSSE(rsraw)
            else
                facts.responses_stream_ok = verdict(rscode)
            end
            recordProbe(facts, "Responses streaming (SSE smoke)", facts.responses_stream_ok,
                facts.responses_stream_ok == false and (rscode == 200 and "200 but non-SSE body"
                    or ModelAudit.errText(rsdec, rsraw)) or nil)
        end
    end

    -- 11. real dispatch shape (T7 P1.1): system message + consecutive user
    -- turns + the real resolved token ask. Perplexity gets the handler-merged
    -- shape (perplexity.lua merges consecutive same-role turns — the known
    -- rejecter's accommodation is itself under test); everyone else gets the
    -- raw shape dispatch actually sends.
    do
        local history = { { role = "system", content = realSystemText() } }
        for _i, msg in ipairs(realHistory()) do table.insert(history, msg) end
        if provider == "perplexity" then
            local merged = { history[1] }
            for i = 2, #history do
                local prev = merged[#merged]
                if history[i].role == prev.role then
                    prev.content = prev.content .. "\n\n" .. history[i].content
                else
                    table.insert(merged, history[i])
                end
            end
            history = merged
        end
        local real_max = ModelConstraints.clampMaxTokens(provider, model,
            ModelConstraints.resolveMaxTokens(provider, model, 4096))
        local rcode, rdec, rraw = req({ messages = history }, real_max)
        facts.real_shape_ok = verdict(rcode)
        recordProbe(facts, "real shape (system+consecutive users)", facts.real_shape_ok,
            rcode ~= 200 and ModelAudit.errText(rdec, rraw) or nil)
    end

    -- 12. two-round tool replay (T7 P1.2) through the plugin's own ToolWire
    -- adapter. deepseek mirrors its handler (thinking disabled on tool
    -- sessions; reasoning_content stays on the replayed turn — V3.2+ 400s
    -- without it); other providers get the handler-stripped shape.
    if facts.tools_ok and real_specs then
        local tool_extra = { tools = probe_tools, tool_choice = "required" }
        if provider == "deepseek" then tool_extra.thinking = { type = "disabled" } end
        local t1code, t1dec, t1raw = req(tool_extra, 1024, TOOL_REPLAY_PROMPT)
        local parsed = t1code == 200 and parseToolCalls(t1dec, provider) or nil
        if not parsed then
            recordProbe(facts, "tool replay round 1 (forced call)", verdict(t1code),
                t1code ~= 200 and ModelAudit.errText(t1dec, t1raw) or "no tool call parsed")
        else
            local messages = { { role = "user", content = TOOL_REPLAY_PROMPT } }
            appendReplayTurn("openai", messages, parsed)
            for _i, m in ipairs(messages) do
                if provider ~= "deepseek" then m.reasoning_content = nil end
                if provider ~= "openrouter" then m.reasoning_details = nil end
            end
            local replay_extra = { messages = messages, tools = probe_tools, tool_choice = "none" }
            if provider == "deepseek" then replay_extra.thinking = { type = "disabled" } end
            local t2code, t2dec, t2raw = req(replay_extra, 1024)
            facts.tool_replay_ok = verdict(t2code)
            recordProbe(facts, "tool replay round 2 (adapter echo)", facts.tool_replay_ok,
                t2code ~= 200 and ModelAudit.errText(t2dec, t2raw) or nil)
        end
    end

    if verbose and facts.temp_err then printf("  %stemp error: %s%s", C.dim, facts.temp_err, C.off) end
    return facts
end

-- ---- Gemini wire ------------------------------------------------------------

local GEMINI_LEVELS = { "minimal", "low", "medium", "high" }

local function probeGemini(model, api_key, verbose)
    local facts = newFacts("gemini", "gemini", model)
    local base = ModelLists._docs.gemini.api_list  -- .../v1beta/models
    local url = base .. "/" .. model .. ":generateContent?key=" .. api_key

    -- 0. metadata (free): output limit, temperature range
    local mtext = httpGet(base .. "/" .. model .. "?key=" .. api_key)
    if mtext then
        local mok, mdata = pcall(json.decode, mtext)
        if mok and type(mdata) == "table" then
            facts.meta = mdata
            if type(mdata.outputTokenLimit) == "number" then
                facts.ceiling = mdata.outputTokenLimit
            end
            -- Keep the temperature bound as a FACT (T7 P1.4) instead of
            -- printing and discarding it — the draft compares it against what
            -- the plugin sends (0.3-0.7 pins vs Google's recommended 1.0 on
            -- Gemini 3).
            if type(mdata.maxTemperature) == "number" then
                facts.max_temperature_meta = mdata.maxTemperature
            end
            printf("  %smetadata: outputTokenLimit=%s inputTokenLimit=%s maxTemperature=%s%s",
                C.dim, tostring(mdata.outputTokenLimit), tostring(mdata.inputTokenLimit),
                tostring(mdata.maxTemperature), C.off)
        end
    end

    local function req(gen_extra, extra, max_toks, prompt)
        local body = {
            contents = { { parts = { { text = prompt or PROBE_PROMPT } } } },
            generationConfig = { maxOutputTokens = max_toks or 256 },
        }
        for k, v in pairs(gen_extra or {}) do body.generationConfig[k] = v end
        for k, v in pairs(extra or {}) do body[k] = v end
        return httpPostJson(url, nil, body)
    end

    -- 1. baseline: thoughtsTokenCount?
    local code, decoded, raw = req(nil, nil, 1024, REASONING_PROBE_PROMPT)
    if code ~= 200 then
        recordProbe(facts, "baseline (bare request)", false, ModelAudit.errText(decoded, raw))
        printf("  %sbaseline failed - aborting battery (bad model id / key?)%s", C.red, C.off)
        return facts
    end
    facts.reachable = true
    local um = type(decoded.usageMetadata) == "table" and decoded.usageMetadata
    local thoughts = um and type(um.thoughtsTokenCount) == "number" and um.thoughtsTokenCount or 0
    facts.default_reasoning = thoughts > 0
    facts.evidence = thoughts > 0 and ("thoughtsTokenCount=" .. thoughts) or "no thoughts tokens"
    recordProbe(facts, "baseline (bare request)", true,
        facts.evidence .. " -> default " .. (facts.default_reasoning and "ON" or "OFF"))

    -- 2. temperature (metadata usually allows; probe confirms)
    local tcode, tdec, traw = req({ temperature = 0.7 }, nil, 32)
    facts.temp_ok = verdict(tcode)
    if not facts.temp_ok then facts.temp_err = ModelAudit.errText(tdec, traw) end
    recordProbe(facts, "temperature=0.7", facts.temp_ok, facts.temp_err)

    -- 3. thinkingLevel ladder (Gemini 3 effort axis)
    facts.ladder = GEMINI_LEVELS
    local any_level = false
    for _i, level in ipairs(GEMINI_LEVELS) do
        local ecode, edec, eraw = req({ thinkingConfig = { thinkingLevel = level:upper() } }, nil, 32)
        facts.efforts[level] = verdict(ecode)
        if ecode == 200 then any_level = true end
        recordProbe(facts, "thinkingLevel=" .. level:upper(), verdict(ecode),
            ecode ~= 200 and ModelAudit.errText(edec, eraw) or nil)
    end
    facts.adaptive_ok = any_level  -- effort-style control accepted

    -- 4. thinkingBudget (2.5 budget axis; 0 = disable)
    local zcode, zdec, zraw = req({ thinkingConfig = { thinkingBudget = 0 } }, nil, 32)
    facts.disable_ok = verdict(zcode)
    recordProbe(facts, "thinkingBudget=0 (disable)", facts.disable_ok,
        not facts.disable_ok and ModelAudit.errText(zdec, zraw) or nil)
    local bcode, bdec, braw = req({ thinkingConfig = { thinkingBudget = 1024 } }, nil, 32)
    facts.budget_ok = verdict(bcode)
    recordProbe(facts, "thinkingBudget=1024", facts.budget_ok,
        not facts.budget_ok and ModelAudit.errText(bdec, braw) or nil)

    -- 5. tools sanity — the runner's REAL declarations rendered with
    -- gemini.lua's empty-properties accommodation (T7 P1.3: the `done` tool's
    -- empty properties is the field-found Gemini rejection class, so the
    -- accommodation itself is under test); stub fallback if the runner module
    -- fails to load.
    local real_specs = realToolSpecs()
    local probe_tools = real_specs and geminiToolDefs(real_specs)
        or { { functionDeclarations = { { name = "ping", description = "Connectivity test.",
              parameters = { type = "object", properties = dummyProps() } } } } }
    local wcode, wdec, wraw = req(nil, { tools = probe_tools }, 32)
    facts.tools_ok = verdict(wcode)
    if not facts.tools_ok then facts.tools_err = ModelAudit.errText(wdec, wraw) end
    recordProbe(facts, real_specs and "tools (real runner specs)" or "tools (functionDeclarations)",
        facts.tools_ok, facts.tools_err)

    -- 6. forced tool_choice (runner gather=ANY / final=NONE via toolConfig -
    -- the Z.AI wave-1.5 failure class a bare tools probe cannot see)
    if facts.tools_ok then
        local acode, adec, araw = req(nil, { tools = probe_tools,
            toolConfig = { functionCallingConfig = { mode = "ANY" } } }, 32)
        facts.tool_choice_any_ok = verdict(acode)
        recordProbe(facts, "toolConfig mode=ANY (gather)", facts.tool_choice_any_ok,
            acode ~= 200 and ModelAudit.errText(adec, araw) or nil)
        local ncode, ndec, nraw = req(nil, { tools = probe_tools,
            toolConfig = { functionCallingConfig = { mode = "NONE" } } }, 32)
        facts.tool_choice_none_ok = verdict(ncode)
        recordProbe(facts, "toolConfig mode=NONE (final)", facts.tool_choice_none_ok,
            ncode ~= 200 and ModelAudit.errText(ndec, nraw) or nil)
    end

    -- 7. streaming smoke (separate endpoint: :streamGenerateContent?alt=sse)
    local stream_url = base .. "/" .. model .. ":streamGenerateContent?alt=sse&key=" .. api_key
    local scode, sdec, sraw = httpPostJson(stream_url, nil, {
        contents = { { parts = { { text = PROBE_PROMPT } } } },
        generationConfig = { maxOutputTokens = 32 },
    })
    recordStreamProbe(facts, scode, sdec, sraw)

    -- 8. real dispatch shape (T7 P1.1): system_instruction + consecutive user
    -- turns, as gemini.lua sends them.
    do
        local rcode, rdec, rraw = httpPostJson(url, nil, {
            system_instruction = { parts = { { text = realSystemText() } } },
            contents = {
                { role = "user", parts = { { text = "Reply with only: ok" } } },
                { role = "model", parts = { { text = "ok" } } },
                { role = "user", parts = { { text = "Reply with only: ok, once more." } } },
                { role = "user", parts = { { text = "The reader is at 40% of this book. Do not discuss anything beyond this point." } } },
            },
            generationConfig = { maxOutputTokens = 256 },
        })
        facts.real_shape_ok = verdict(rcode)
        recordProbe(facts, "real shape (system+consecutive users)", facts.real_shape_ok,
            rcode ~= 200 and ModelAudit.errText(rdec, rraw) or nil)
    end

    -- 9. two-round tool replay (T7 P1.2): Gemini 3 enforces thought_signature
    -- replay — a single-call probe can never see it. The turn rides the
    -- plugin's own gemini ToolWire adapter; roles map as gemini.lua maps them
    -- (assistant echo keeps "model", tool results go on a "user" turn).
    if facts.tools_ok and real_specs then
        local t1code, t1dec, t1raw = req(nil, { tools = probe_tools,
            toolConfig = { functionCallingConfig = { mode = "ANY" } } }, 1024, TOOL_REPLAY_PROMPT)
        local parsed = t1code == 200 and parseToolCalls(t1dec, "gemini") or nil
        if not parsed then
            recordProbe(facts, "tool replay round 1 (forced call)", verdict(t1code),
                t1code ~= 200 and ModelAudit.errText(t1dec, t1raw) or "no tool call parsed")
        else
            local messages = { { role = "user",
                parts = { { text = TOOL_REPLAY_PROMPT } } } }
            local ToolWire = require("koassistant_api.tool_wire")
            local executed = {}
            for _i, call in ipairs(parsed.calls or {}) do
                table.insert(executed, { call = call,
                    result = { ok = true, note = "probe: constant tool result" } })
            end
            ToolWire.adapters.gemini.appendToolTurn(messages, parsed.raw_assistant_turn, executed)
            local contents = {}
            for _i, m in ipairs(messages) do
                table.insert(contents, {
                    role = m.role == "tool" and "user" or m.role,
                    parts = m.parts,
                })
            end
            local t2code, t2dec, t2raw = httpPostJson(url, nil, {
                contents = contents,
                tools = probe_tools,
                toolConfig = { functionCallingConfig = { mode = "NONE" } },
                generationConfig = { maxOutputTokens = 1024 },
            })
            facts.tool_replay_ok = verdict(t2code)
            recordProbe(facts, "tool replay round 2 (adapter echo)", facts.tool_replay_ok,
                t2code ~= 200 and ModelAudit.errText(t2dec, t2raw) or nil)
        end
    end

    printf("  %sgoogle_search grounding: not probed (separate quota) - set per family/docs%s",
        C.dim, C.off)

    if verbose and facts.temp_err then printf("  %stemp error: %s%s", C.dim, facts.temp_err, C.off) end
    return facts
end

--------------------------------------------------------------------------------
-- Current resolution + draft stanzas
--------------------------------------------------------------------------------

local AUDIT_CAPS = {
    "tools", "reasoning", "reasoning_gated", "thinking", "adaptive_thinking",
    "extended_thinking", "thinking_budget", "no_sampling_params",
    "responses_web_search",
}

function ModelAudit.currentResolution(provider, model)
    local caps = {}
    for _i, cap in ipairs(AUDIT_CAPS) do
        caps[cap] = ModelConstraints.supportsCapability(provider, model, cap)
    end
    local params = { temperature = 0.7 }
    params = ModelConstraints.apply(provider, model, params)
    return {
        profile = ModelConstraints.getReasoningProfile(provider, model),
        caps = caps,
        temp_after_apply = params and params.temperature,
        clamped = ModelConstraints.clampMaxTokens(provider, model, ABSURD_MAX_TOKENS),
        resolved_default = ModelConstraints.resolveMaxTokens(provider, model, 8192),
    }
end

local function orderedAccepted(facts, exclude)
    local out = {}
    for _i, e in ipairs(facts.ladder or {}) do
        if facts.efforts[e] and not (exclude and exclude[e]) then
            table.insert(out, e)
        end
    end
    return out
end

local function quoteList(list)
    local parts = {}
    for _i, v in ipairs(list) do table.insert(parts, string.format("%q", v)) end
    return table.concat(parts, ", ")
end

local function mark(needs_curation)
    return needs_curation and (C.yellow .. "  <-- NEEDS CURATION" .. C.off)
        or (C.dim .. "  (already covered by current resolution)" .. C.off)
end

-- Pure-ish (uses facts + current only): returns printable lines.
function ModelAudit.draftStanzas(facts, current)
    local lines = {}
    local function add(fmt, ...)
        table.insert(lines, select("#", ...) > 0 and string.format(fmt, ...) or fmt)
    end
    local provider, model = facts.provider, facts.model
    local profile = current.profile or {}

    add("%s-- DRAFT for model_constraints.lua (REVIEW - never auto-applied) ------------%s",
        C.bold, C.off)

    -- Capability list deltas
    add("-- capabilities.%s:", provider)
    local function capLine(cap, probed, note)
        if probed == nil then return end
        if probed then
            add('--   %-20s += "%s"%s%s', cap, model, note or "", mark(not current.caps[cap]))
        elseif current.caps[cap] then
            add('--   %-20s currently resolves TRUE but the probe result disagrees %s<-- investigate%s',
                cap, C.red, C.off)
        end
    end
    if facts.family == "anthropic" then
        capLine("adaptive_thinking", facts.adaptive_ok)
        capLine("extended_thinking", facts.budget_ok)
        capLine("no_sampling_params", facts.temp_ok == false)
        capLine("tools", facts.tools_ok)
    elseif facts.family == "gemini" then
        capLine("thinking", facts.default_reasoning or facts.adaptive_ok or facts.budget_ok)
        capLine("thinking_budget", facts.budget_ok)
        capLine("tools", facts.tools_ok)
    else
        local reasons = facts.default_reasoning or facts.disable_ok
            or #orderedAccepted(facts) > 0 or facts.binary_on_ok
        capLine("reasoning", reasons or false)
        if provider == "openai" and reasons and facts.default_reasoning == false then
            capLine("reasoning_gated", true, "  (efforts accepted, default OFF)")
        end
        if facts.binary then capLine("thinking", facts.binary_on_ok) end
        capLine("tools", facts.tools_ok)
        if provider == "openai" and facts.tools_ok == false then
            add("--   NOTE: probe uses the chat wire; this plugin runs gpt-5.x function tools")
            add("--   over the Responses API (openai.lua R3) - a chat-wire rejection does not")
            add("--   prove tools are absent")
        end
        capLine("responses_web_search", facts.responses_web_ok)
        if facts.responses_ok == false then
            add("%s-- NOTE: Responses wire REJECTED the model - web search cannot route for it%s",
                C.yellow, C.off)
        end
        if facts.responses_ok and facts.responses_stream_ok == false then
            add("%s-- NOTE: Responses streaming not honored - web-on requests would not stream%s",
                C.yellow, C.off)
        end
    end

    -- Wire notes from the tool_choice / streaming probes
    if facts.tools_ok and facts.tool_choice_any_ok == false then
        add("%s-- NOTE: forced tool_choice (gather mode) REJECTED - runner-incompatible as-is (Z.AI class)%s",
            C.yellow, C.off)
        if facts.tool_choice_any_thinking_off then
            add("%s--   but ACCEPTED with thinking disabled - deepseek-style handler accommodation works%s",
                C.yellow, C.off)
        end
    end
    if facts.tools_ok and facts.tool_choice_none_ok == false then
        add("%s-- NOTE: tool_choice none/NONE REJECTED - runner final pass needs an accommodation%s",
            C.yellow, C.off)
    end
    if facts.stream_ok == false then
        add("%s-- NOTE: stream=true not honored (rejected or non-SSE response) - verify before relying on streaming%s",
            C.yellow, C.off)
    end

    -- Temperature constraint (non-anthropic wire: forced value, not capability)
    if facts.temp_ok == false and facts.family ~= "anthropic" then
        local covered = current.temp_after_apply ~= 0.7
        add("-- ModelConstraints.%s (forced params):%s", provider, mark(not covered))
        add('    ["%s"] = { temperature = 1.0 },', model)
    end

    -- Reasoning profile stanza
    local axis, options
    if facts.family == "anthropic" then
        axis = facts.adaptive_ok and "adaptive_effort"
            or (facts.budget_ok and "budget") or "none"
        options = orderedAccepted(facts)
    elseif facts.binary then
        axis = (facts.binary_on_ok or facts.binary_off_ok) and "binary" or "none"
    else
        options = orderedAccepted(facts, { none = true })
        axis = #options > 0 and "effort"
            or (facts.family == "gemini" and facts.budget_ok and "budget") or "none"
    end

    local profile_differs = (profile.axis or "none") ~= axis
        or (axis ~= "none" and (profile.default_state == "on") ~= (facts.default_reasoning == true))
    if axis == "none" then
        add("-- reasoning profile: no controls accepted -> axis \"none\" / passthrough%s",
            mark(profile_differs))
    else
        add("-- reasoning_profiles.%s - insert BEFORE any family fallback entries:%s",
            provider, mark(profile_differs))
        if facts.family == "anthropic" and facts.adaptive_ok and not facts.default_reasoning then
            add('-- CAUTION: default_state "off" inferred from one prompt; adaptive models may')
            add("-- skip thinking even on the math probe - verify against the model announcement")
        end
        if facts.weak_reasoning_evidence then
            add('-- CAUTION: default_state "on" rests on a small reasoning-token count - verify')
        end
        local default_state = facts.default_reasoning and "on" or "off"
        local can_disable = facts.disable_ok and true or false
        if axis == "binary" then
            add('    { match = "%s", axis = "binary", default_state = "%s",', model, default_state)
            add('      can_disable = %s, can_enable = %s },',
                tostring(can_disable), tostring(facts.binary_on_ok and true or false))
        else
            local default_option = facts.efforts and facts.efforts.high and "high"
                or (options and options[1]) or "medium"
            add('    { match = "%s", axis = "%s", default_state = "%s",', model, axis, default_state)
            add('      can_disable = %s, can_enable = true,', tostring(can_disable))
            if options and #options > 0 then
                add('      options = { %s }, default_option = "%s",', quoteList(options), default_option)
            end
            local minimal = can_disable and '{ state = "off" }'
                or string.format('{ state = "on", option = "%s" }', options and options[1] or "low")
            local maximum = string.format('{ state = "on", option = "%s" }',
                options and options[#options] or "high")
            add('      stance_map = { minimal = %s, maximum = %s },', minimal, maximum)
            local flags = {}
            if facts.family == "anthropic" and facts.temp_ok == false then
                table.insert(flags, "needs_no_sampling = true")
            end
            if facts.efforts and facts.efforts.none and facts.family ~= "anthropic" then
                table.insert(flags, 'off_option = "none"')
            end
            add('      %s},', #flags > 0 and (table.concat(flags, ", ") .. " ") or "")
        end
    end

    -- Output ceiling
    if facts.ceiling then
        local covered = current.clamped == facts.ceiling
        add("-- _max_output_tokens.%s:%s", provider, mark(not covered))
        add('    ["%s"] = %d,', model, facts.ceiling)
    end

    -- Wire notes that live outside model_constraints.lua
    if facts.needs_max_completion_tokens then
        add("%s-- NOTE: needs max_completion_tokens - check the prefix rule in koassistant_api/openai.lua%s",
            C.yellow, C.off)
    end

    add("%s-- koassistant_model_lists.lua (HUMAN decisions) ---------------------------%s",
        C.bold, C.off)
    add('--   %s array: add "%s" (position matters - first entry = provider default)', provider, model)
    add("--   _tiers: place by price/positioning (frontier/flagship/standard/fast/ultrafast)")
    add("--   then run: lua tests/run_tests.lua --models %s", provider)
    return lines
end

-- ---- Ollama wire (native /api/chat, plain http, keyless) --------------------
--
-- Local server: root from KOA_OLLAMA_URL (default localhost:11434). Ollama
-- capabilities are DERIVED at runtime (/api/show at model pick), so this
-- battery verifies WIRE behavior per local model and prints the caps — it
-- drafts no stanzas. Request bodies come from the REAL handler
-- (OllamaHandler:buildRequestBody), per the T7 real-shape discipline.

local function ollamaPostJson(url, body_tbl, timeout)
    local http = require("socket.http")
    local ltn12 = require("ltn12")
    local prev_timeout = http.TIMEOUT
    if timeout then http.TIMEOUT = timeout end
    local payload = json.encode(body_tbl)
    local chunks = {}
    local ok, code = http.request({
        url = url, method = "POST",
        headers = { ["Content-Type"] = "application/json",
                    ["Content-Length"] = tostring(#payload) },
        source = ltn12.source.string(payload),
        sink = ltn12.sink.table(chunks),
    })
    http.TIMEOUT = prev_timeout
    local text = table.concat(chunks)
    if not ok then return nil, nil, "network: " .. tostring(code) end
    local decoded
    if text ~= "" then
        local dok, d = pcall(json.decode, text)
        if dok and type(d) == "table" then decoded = d end
    end
    return tonumber(code) or code, decoded, text
end

-- Ollama streams NDJSON (one JSON object per line), never SSE.
local function looksLikeNDJSON(text)
    if type(text) ~= "string" then return false end
    local first = text:match("^([^\n]+)\n")
    if not first then return false end
    local ok, d = pcall(json.decode, first)
    return ok and type(d) == "table" and (d.message ~= nil or d.done ~= nil)
end

-- Where thinking landed in a response: "field" (message.thinking), "tags"
-- (<think> in content — the form the plugin's parser extracts), or nil.
local function ollamaThinkingIn(decoded)
    local msg = type(decoded) == "table" and type(decoded.message) == "table"
        and decoded.message or nil
    if not msg then return nil end
    if type(msg.thinking) == "string" and msg.thinking:match("%S") then return "field" end
    if type(msg.content) == "string" and msg.content:find("<think>", 1, true) then return "tags" end
    return nil
end

local function probeOllama(model, _verbose)
    local facts = newFacts("ollama", "ollama", model)
    local root = os.getenv("KOA_OLLAMA_URL")
    root = ((root and root ~= "") and root or "http://localhost:11434"):gsub("/+$", "")
    local chat_url = root .. "/api/chat"
    printf("  %sserver: %s (override with KOA_OLLAMA_URL); local inference - legs can take a while%s",
        C.dim, root, C.off)

    local OllamaHandler = require("koassistant_api.ollama")
    local ResponseParser = require("koassistant_api.response_parser")
    local function handlerBody(history, config)
        config = config or {}
        config.model = model
        config.base_url = chat_url
        local built = OllamaHandler:buildRequestBody(history, config)
        return built.body
    end

    -- 1. /api/show — the source the runtime capability derive reads
    local scode, sdec, sraw = ollamaPostJson(root .. "/api/show", { model = model }, 30)
    if scode ~= 200 then
        recordProbe(facts, "/api/show (capability derive)", false,
            sraw and tostring(sraw):sub(1, 120) or "unreachable")
        printf("  %sserver or model unavailable - aborting (is Ollama running? model pulled?)%s",
            C.red, C.off)
        return facts
    end
    local caps = {}
    if type(sdec) == "table" and type(sdec.capabilities) == "table" then
        for _i, c in ipairs(sdec.capabilities) do
            if type(c) == "string" then table.insert(caps, c) end
        end
    end
    facts.ollama_caps = caps
    recordProbe(facts, "/api/show (capability derive)", true,
        "capabilities: " .. (#caps > 0 and table.concat(caps, ", ") or "(none reported)"))
    local has_tools_cap, has_thinking_cap = false, false
    for _i, c in ipairs(caps) do
        if c == "tools" then has_tools_cap = true end
        if c == "thinking" then has_thinking_cap = true end
    end

    -- 2. baseline through the real handler shape; where does thinking land?
    local body = handlerBody({ { role = "user", content = REASONING_PROBE_PROMPT } })
    local code, decoded, raw = ollamaPostJson(chat_url, body, 300)
    if code ~= 200 then
        recordProbe(facts, "baseline (handler shape)", false, tostring(raw):sub(1, 160))
        printf("  %sbaseline failed - aborting battery%s", C.red, C.off)
        return facts
    end
    facts.reachable = true
    local where = ollamaThinkingIn(decoded)
    facts.default_reasoning = where ~= nil
    recordProbe(facts, "baseline (handler shape)", true,
        where and ("thinks by default - thinking in "
            .. (where == "tags" and "<think> tags (the form the plugin extracts)"
                or "message.thinking FIELD"))
        or "no thinking in bare response -> default OFF")

    -- 3. the plugin's own transformer on the real response
    local pok, pcontent, preasoning = ResponseParser:parseResponse(decoded, "ollama")
    recordProbe(facts, "plugin parser (content extraction)",
        (pok and type(pcontent) == "string" and pcontent:match("%S") ~= nil) or false,
        pok and (preasoning and "content + reasoning extracted" or "content extracted")
            or tostring(pcontent))

    -- 4/5. think param (thinking-capable models only)
    if has_thinking_cap then
        body = handlerBody({ { role = "user", content = REASONING_PROBE_PROMPT } })
        body.think = false
        local dcode, ddec = ollamaPostJson(chat_url, body, 300)
        local dwhere = ollamaThinkingIn(ddec)
        facts.disable_ok = (dcode == 200 and dwhere == nil) or false
        recordProbe(facts, "think=false (suppression)", facts.disable_ok,
            dcode ~= 200 and ("HTTP " .. tostring(dcode))
            or (dwhere and "thinking STILL present" or "thinking suppressed"))

        body = handlerBody({ { role = "user", content = REASONING_PROBE_PROMPT } })
        body.think = true
        local ecode, edec = ollamaPostJson(chat_url, body, 300)
        local ewhere = ollamaThinkingIn(edec)
        recordProbe(facts, "think=true (explicit)", (ecode == 200 and ewhere ~= nil) or false,
            ecode ~= 200 and ("HTTP " .. tostring(ecode))
            or (ewhere and ("thinking in " .. (ewhere == "field" and "message.thinking FIELD"
                    or "<think> tags"))
                or "no thinking came back"))
    end

    -- 6. real-dispatch shape (system + consecutive user turns)
    body = handlerBody(realHistory(), { system = { text = realSystemText() } })
    local rcode, _rdec, rraw = ollamaPostJson(chat_url, body, 300)
    recordProbe(facts, "real-dispatch shape (system+history)", rcode == 200,
        rcode ~= 200 and tostring(rraw):sub(1, 120) or nil)

    -- 7. streaming smoke: NDJSON framing
    body = handlerBody({ { role = "user", content = PROBE_PROMPT } })
    body.stream = true
    local stcode, _stdec, straw = ollamaPostJson(chat_url, body, 300)
    facts.stream_ok = (stcode == 200 and looksLikeNDJSON(straw)) or false
    recordProbe(facts, "streaming (NDJSON framing)", facts.stream_ok,
        stcode ~= 200 and ("HTTP " .. tostring(stcode))
        or (facts.stream_ok and "NDJSON lines" or "200 but non-NDJSON body"))

    -- 8/9. tools: two-round replay through the REAL handler + ToolWire adapter.
    -- tool_choice is IGNORED by ollama (probed 0.17.7): "required" cannot force
    -- a call, so a prose round 1 is INCONCLUSIVE, not a rejection (the runner's
    -- prose fallback covers it). Round 2 replays with NO declarations — the
    -- plugin's mode NONE stray-call guard, under test here.
    local specs = realToolSpecs()
    if has_tools_cap and specs then
        local messages = { { role = "user", content = TOOL_REPLAY_PROMPT } }
        body = handlerBody(messages, { tools = { specs = specs, mode = "ANY" } })
        local t1code, t1dec, t1raw = ollamaPostJson(chat_url, body, 300)
        if t1code ~= 200 then
            facts.tools_ok = false
            recordProbe(facts, "tools round 1 (real specs, mode ANY)", false,
                tostring(t1raw):sub(1, 160))
        else
            local parsed = parseToolCalls(t1dec, "ollama")
            if parsed then
                facts.tools_ok = true
                recordProbe(facts, "tools round 1 (real specs, mode ANY)", true,
                    "called " .. tostring(parsed.calls[1] and parsed.calls[1].name))
                if appendReplayTurn("ollama", messages, parsed) then
                    body = handlerBody(messages, { tools = { specs = specs, mode = "NONE" } })
                    local t2code, t2dec, t2raw = ollamaPostJson(chat_url, body, 300)
                    local t2ok = false
                    if t2code == 200 then
                        local ok2, c2 = ResponseParser:parseResponse(t2dec, "ollama")
                        t2ok = (ok2 and type(c2) == "string" and c2:match("%S") ~= nil) or false
                    end
                    facts.tool_replay_ok = t2ok
                    recordProbe(facts, "tool replay round 2 (adapter echo)", t2ok,
                        t2code ~= 200 and tostring(t2raw):sub(1, 120)
                        or (t2ok and "grounded prose after replay (no declarations sent)"
                            or "no prose content"))
                end
            else
                facts.tools_ok = nil
                recordProbe(facts, "tools round 1 (real specs, mode ANY)", nil,
                    "no call - prose answer (tool_choice ignored; runner prose-fallback covers this)")
            end
        end
    elseif not has_tools_cap then
        recordProbe(facts, "tools (capability gate)", false,
            "/api/show reports no tools capability - the Tools chip stays off for this model")
    end

    return facts
end

--------------------------------------------------------------------------------
-- Probe dispatch
--------------------------------------------------------------------------------

local function probeModel(provider, model, api_key, verbose)
    banner("PROBE " .. provider .. " / " .. model)
    -- Ollama: local + keyless; capabilities are derived at runtime, no stanzas
    if provider == "ollama" then
        local facts = probeOllama(model, verbose)
        if facts and facts.reachable then
            print("")
            printf("  %sollama capabilities are DERIVED at runtime (/api/show at model pick) - nothing to draft%s",
                C.dim, C.off)
        end
        return facts
    end
    if not TestConfig.isValidApiKey(api_key) then
        printf("  %sno API key for %s in apikeys.lua%s", C.red, provider, C.off)
        return nil
    end
    printf("  %s~13-19 micro-requests (max_tokens 32..1024) - fractions of a cent%s", C.dim, C.off)

    local facts
    if provider == "anthropic" then
        facts = probeAnthropic(model, api_key, verbose)
    elseif provider == "gemini" then
        facts = probeGemini(model, api_key, verbose)
    elseif OPENAI_FAMILY[provider] then
        facts = probeOpenAIFamily(provider, model, api_key, verbose)
    else
        printf("  %sno probe adapter for %q yet%s (have: anthropic, gemini, %s)",
            C.red, provider, C.off, "openai/deepseek/xai/zai/mistral/perplexity/openrouter/groq/together/fireworks/qwen/kimi/opencode")
        return nil
    end

    if facts and facts.reachable then
        print("")
        local current = ModelAudit.currentResolution(provider, model)
        for _i, line in ipairs(ModelAudit.draftStanzas(facts, current)) do
            print(line)
        end
    end
    return facts
end

--------------------------------------------------------------------------------
-- Recheck (curated-constraints drift sweep): 2 micro-requests per CURATED
-- model - baseline (math prompt, reasoning-default evidence) + temperature=0.7
-- - compared against the resolution layer. The cheap standing answer to the
-- pre-freeze "recheck constraints" checklist item: catches delisted-and-dead
-- ids, reasoning-default flips, and temperature rules that would 400 in the
-- field, without the full 13-19-request battery per model.
--------------------------------------------------------------------------------

-- Pure: compare a recheck observation against the current resolution layer.
-- Returns level ("ok" | "warn" | "drift") + reason strings. The asymmetry is
-- deliberate: a mismatch that would 400 in the field (we SEND something the
-- model rejects) is DRIFT; an over-strict constraint (we withhold something
-- the model accepts) is only a WARN.
function ModelAudit.recheckCompare(obs, current)
    if not obs.served then
        -- Key-tier limitations (free-tier quota on paid-only models, staged
        -- rollouts) are about OUR key, not the curation - warn, don't drift.
        local err = tostring(obs.err or "?")
        local lower = err:lower()
        if lower:find("quota", 1, true) or lower:find("permission", 1, true)
                or lower:find("billing", 1, true) then
            return "warn", { "not probeable with this key (quota/permission): " .. err:sub(1, 100) }
        end
        return "drift", { "not served: " .. err:sub(1, 120) }
    end
    local reasons, level = {}, "ok"
    local function drift(msg) level = "drift"; table.insert(reasons, msg) end
    local function warn(msg)
        if level ~= "drift" then level = "warn" end
        table.insert(reasons, msg)
    end
    local profile = current.profile or {}
    local pstate = profile.default_state
    if obs.default_reasoning then
        if (profile.axis or "none") == "none" then
            -- axis none + default_state "on" = documented always-on with no
            -- controls (the magistral / grok-build class) - consistent.
            if pstate ~= "on" then
                drift("reasons by default, profile axis is none")
            end
        elseif pstate ~= "on" then
            drift("reasons by default, profile default_state is " .. tostring(pstate))
        end
    elseif pstate == "on" then
        -- Some wires report no reasoning evidence even when thinking ran, so
        -- absence alone never claims drift.
        warn("no reasoning evidence on math prompt (profile default on) - verify")
    elseif obs.weak_evidence then
        warn("weak reasoning evidence (" .. tostring(obs.weak_evidence)
            .. " tokens) on a default-off profile - verify")
    end
    -- "What we'd send": apply() passing 0.7 through, UNLESS the handler strips
    -- sampling params entirely (no_sampling_params lives in the request
    -- builder, not in apply() - the Opus 4.7+/5-family class).
    local we_send_temp = current.temp_after_apply == 0.7
        and not (current.caps and current.caps.no_sampling_params)
    if obs.temp_ok == false then
        if we_send_temp then
            drift("temperature=0.7 rejected but constraints pass it through (field 400s)")
        end
        -- rejected while constraints strip/force it = consistent
    elseif obs.temp_ok == true then
        if not we_send_temp then
            warn("temperature accepted but constraints modify/strip it (possibly stale)")
        end
    else
        warn("temperature probe inconclusive (rate limit)")
    end
    -- Output-ceiling comparison (--ceilings leg). Only the harmful directions:
    -- a clamp BELOW the stated ceiling is often a deliberate known-good floor
    -- (the grok-4 32768 case) and never errors, so it stays silent.
    if obs.ceiling then
        local rd, clamped = current.resolved_default, current.clamped
        if rd and obs.ceiling < rd then
            drift(string.format(
                "stated output ceiling %d below our default %d (first request 400s)",
                obs.ceiling, rd))
        elseif clamped and obs.ceiling < clamped then
            warn(string.format(
                "stated ceiling %d below our clamp %d (user pins in the gap 400)",
                obs.ceiling, clamped))
        end
    end
    return level, reasons
end

local function recheckObserve(provider, model, api_key, opts)
    local obs = { model = model }
    if provider == "anthropic" then
        local url = Defaults.ProviderDefaults.anthropic.base_url
        local headers = { ["x-api-key"] = api_key, ["anthropic-version"] = "2023-06-01" }
        local code, decoded, raw = httpPostJson(url, headers, { model = model, max_tokens = 1024,
            messages = { { role = "user", content = REASONING_PROBE_PROMPT } } })
        if code ~= 200 then obs.err = ModelAudit.errText(decoded, raw); return obs end
        obs.served = true
        obs.default_reasoning = false
        for _i, block in ipairs(type(decoded.content) == "table" and decoded.content or {}) do
            if type(block) == "table" and block.type == "thinking" then obs.default_reasoning = true end
        end
        local tcode, tdec, traw = httpPostJson(url, headers, { model = model, max_tokens = 32,
            temperature = 0.7, messages = { { role = "user", content = PROBE_PROMPT } } })
        obs.temp_ok = verdict(tcode)
        if obs.temp_ok == false then obs.temp_err = ModelAudit.errText(tdec, traw) end
        if opts and opts.ceilings then
            local ccode, cdec, craw = httpPostJson(url, headers, { model = model,
                max_tokens = ABSURD_MAX_TOKENS,
                messages = { { role = "user", content = PROBE_PROMPT } } })
            if ccode ~= 200 and ccode ~= 429 then
                obs.ceiling = ModelAudit.parseCeiling(ModelAudit.errText(cdec, craw), ABSURD_MAX_TOKENS)
            end
        end
        return obs
    elseif provider == "gemini" then
        local base = ModelLists._docs.gemini.api_list
        local url = base .. "/" .. model .. ":generateContent?key=" .. api_key
        local code, decoded, raw = httpPostJson(url, nil, {
            contents = { { parts = { { text = REASONING_PROBE_PROMPT } } } },
            generationConfig = { maxOutputTokens = 1024 } })
        if code ~= 200 then obs.err = ModelAudit.errText(decoded, raw); return obs end
        obs.served = true
        local um = type(decoded.usageMetadata) == "table" and decoded.usageMetadata
        local thoughts = um and type(um.thoughtsTokenCount) == "number" and um.thoughtsTokenCount or 0
        obs.default_reasoning = thoughts > 0
        local tcode, tdec, traw = httpPostJson(url, nil, {
            contents = { { parts = { { text = PROBE_PROMPT } } } },
            generationConfig = { maxOutputTokens = 32, temperature = 0.7 } })
        obs.temp_ok = verdict(tcode)
        if obs.temp_ok == false then obs.temp_err = ModelAudit.errText(tdec, traw) end
        if opts and opts.ceilings then
            -- Gemini states the ceiling in free model metadata - no generation.
            local mtext = httpGet(base .. "/" .. model .. "?key=" .. api_key)
            if mtext then
                local mok, mdata = pcall(json.decode, mtext)
                if mok and type(mdata) == "table"
                        and type(mdata.outputTokenLimit) == "number" then
                    obs.ceiling = mdata.outputTokenLimit
                end
            end
        end
        return obs
    elseif OPENAI_FAMILY[provider] then
        local fam = OPENAI_FAMILY[provider]
        local pd = Defaults.ProviderDefaults[provider]
        local url = fam.url or (pd and pd.base_url)
        if not url then obs.err = "no chat endpoint known"; return obs end
        local headers = bearerHeaders(api_key)
        for k, v in pairs(fam.extra_headers or {}) do headers[k] = v end
        local token_key = "max_tokens"
        local function req(extra, max_toks, prompt)
            local body = { model = model,
                           messages = { { role = "user", content = prompt or PROBE_PROMPT } } }
            body[token_key] = max_toks or 32
            for k, v in pairs(extra or {}) do body[k] = v end
            return httpPostJson(url, headers, body)
        end
        local code, decoded, raw = req(nil, 1024, REASONING_PROBE_PROMPT)
        if code ~= 200 and ModelAudit.errText(decoded, raw):find("max_completion_tokens", 1, true) then
            token_key = "max_completion_tokens"
            code, decoded, raw = req(nil, 1024, REASONING_PROBE_PROMPT)
        end
        if code ~= 200 then obs.err = ModelAudit.errText(decoded, raw); return obs end
        obs.served = true
        -- Same weak-signal rule as the full battery: a handful of reasoning
        -- tokens on a math prompt is bookkeeping noise, not a reasoning default.
        local evidence = ModelAudit.reasoningEvidence(decoded)
        local rt = evidence and tonumber(evidence:match("^reasoning_tokens=(%d+)$"))
        if rt and rt < 64 then
            obs.weak_evidence = rt
            obs.default_reasoning = false
        else
            obs.default_reasoning = evidence ~= nil
        end
        local tcode, tdec, traw = req({ temperature = 0.7 }, 32)
        obs.temp_ok = verdict(tcode)
        if obs.temp_ok == false then obs.temp_err = ModelAudit.errText(tdec, traw) end
        if opts and opts.ceilings then
            local ccode, cdec, craw = req(nil, ABSURD_MAX_TOKENS)
            if ccode ~= 200 and ccode ~= 429 then
                obs.ceiling = ModelAudit.parseCeiling(ModelAudit.errText(cdec, craw), ABSURD_MAX_TOKENS)
            end
        end
        return obs
    end
    obs.err = "no probe adapter for this provider"
    return obs
end

local function runRecheck(provider, api_key, verbose, opts)
    banner("RECHECK " .. provider)
    local curated = ModelLists[provider]
    if type(curated) ~= "table" or #curated == 0 then
        printf("  %sskipped: no curated model array%s", C.dim, C.off)
        return nil
    end
    if not TestConfig.isValidApiKey(api_key) then
        printf("  %sskipped: no API key in apikeys.lua%s", C.dim, C.off)
        return nil
    end
    local fam = OPENAI_FAMILY[provider]
    if provider ~= "anthropic" and provider ~= "gemini" and not fam then
        printf("  %sskipped: no probe adapter%s", C.dim, C.off)
        return nil
    end
    if fam and fam.cost_note then printf("  %snote: %s%s", C.yellow, fam.cost_note, C.off) end
    printf("  %s%d micro-requests per curated model (%d models)%s", C.dim,
        (opts and opts.ceilings) and 3 or 2, #curated, C.off)
    local counts = { ok = 0, warn = 0, drift = 0 }
    for _i, model in ipairs(curated) do
        local obs = recheckObserve(provider, model, api_key, opts)
        local level, reasons =
            ModelAudit.recheckCompare(obs, ModelAudit.currentResolution(provider, model))
        counts[level] = counts[level] + 1
        if level == "ok" then
            printf("  %sOK%s     %-38s%s", C.green, C.off, model,
                verbose and (C.dim .. (obs.default_reasoning and "reasons by default"
                    or "no default reasoning") .. C.off) or "")
        else
            printf("  %s%-6s%s %-38s %s", level == "drift" and C.red or C.yellow,
                level:upper(), C.off, model, table.concat(reasons, "; "))
        end
    end
    printf("  %ssummary: %d ok, %d warn, %d drift%s",
        counts.drift > 0 and C.red or (counts.warn > 0 and C.yellow or C.green),
        counts.ok, counts.warn, counts.drift, C.off)
    return counts
end

--------------------------------------------------------------------------------
-- Main
--------------------------------------------------------------------------------

local MAX_PROBE_NEW = 10

local function main()
    -- arg parsing
    local providers, verbose = {}, false
    local mode, probe_provider, probe_model = "discover", nil, nil
    local recheck_ceilings = false
    local i = 1
    while i <= #arg do
        local a = arg[i]
        if a == "--help" or a == "-h" then
            print("Usage: lua tests/model_audit.lua [providers...] [--probe <provider> <model>] " ..
                  "[--probe-new] [--recheck [--ceilings]] [--verbose]")
            os.exit(0)
        elseif a == "--verbose" or a == "-v" then
            verbose = true
        elseif a == "--probe" then
            mode = "probe"
            probe_provider, probe_model = arg[i + 1], arg[i + 2]
            i = i + 2
            if not probe_provider or not probe_model then
                print("--probe needs <provider> <model>")
                os.exit(1)
            end
        elseif a == "--probe-new" then
            mode = "probe-new"
        elseif a == "--recheck" then
            mode = "recheck"
        elseif a == "--ceilings" then
            recheck_ceilings = true
        elseif a:match("^%-") then
            printf("unknown option: %s (see --help)", a)
            os.exit(1)
        else
            table.insert(providers, a)
        end
        i = i + 1
    end

    if not HAS_NETWORK or not JSON_OK then
        print("Real HTTP/JSON modules unavailable (luasocket/luasec/dkjson).")
        print("Run this first, then retry:")
        print('  eval "$(luarocks --lua-version 5.5 path)"')
        os.exit(1)
    end
    require("socket.http").TIMEOUT = 60
    pcall(function() require("ssl.https").TIMEOUT = 60 end)

    local apikeys = TestConfig.loadApiKeys()

    if mode == "probe" then
        local facts = probeModel(probe_provider, probe_model, keyFor(apikeys, probe_provider), verbose)
        os.exit((facts and facts.reachable) and 0 or 1)
    end

    if mode == "recheck" then
        if #providers == 0 then
            -- Default set = every keyed provider with a probe adapter, EXCEPT
            -- openrouter (31 marketplace mirror ids - run --recheck openrouter
            -- explicitly when you mean it).
            for _i, p in ipairs(ModelLists.getAllProviders()) do
                if (p == "anthropic" or p == "gemini" or OPENAI_FAMILY[p])
                        and p ~= "openrouter"
                        and TestConfig.isValidApiKey(keyFor(apikeys, p)) then
                    table.insert(providers, p)
                end
            end
            table.sort(providers)
            printf("%sopenrouter excluded from the default recheck set (31 mirror ids) - " ..
                   "run: lua tests/model_audit.lua --recheck openrouter%s", C.dim, C.off)
        end
        local any_drift = false
        for _i, p in ipairs(providers) do
            local counts = runRecheck(p, keyFor(apikeys, p), verbose, { ceilings = recheck_ceilings })
            if counts and counts.drift > 0 then any_drift = true end
        end
        os.exit(any_drift and 1 or 0)
    end

    -- discovery (both "discover" and "probe-new" start here)
    if #providers == 0 then
        local skipped = {}
        for _i, p in ipairs(ModelLists.getAllProviders()) do
            if DISCOVERY[p] then
                table.insert(providers, p)
            else
                table.insert(skipped, p)
            end
        end
        table.sort(providers)
        table.sort(skipped)
        printf("%sno discovery adapter (validate via --models instead): %s%s",
            C.dim, table.concat(skipped, ", "), C.off)
    end

    local to_probe = {}
    for _i, provider in ipairs(providers) do
        if not DISCOVERY[provider] then
            banner(provider)
            local docs = ModelLists._docs[provider]
            printf("  %sskipped: %s%s", C.dim,
                (docs and docs.api_list) and "no discovery adapter yet"
                or "no public list endpoint - validate via: lua tests/run_tests.lua --models "
                   .. provider, C.off)
            for id, note in pairs(ModelAudit.WATCH[provider] or {}) do
                printf("  %swatching: %-24s %s%s", C.yellow, id, note, C.off)
            end
        else
            local diff = runDiscovery(provider, keyFor(apikeys, provider), verbose)
            if diff then
                for _j, id in ipairs(diff.new) do
                    table.insert(to_probe, { provider = provider, model = id })
                end
            end
        end
    end

    -- Enrich NEW ids with marketplace pricing/context (tier proposals). One
    -- extra GET; skipped without an openrouter key or when nothing is new.
    if #to_probe > 0 and TestConfig.isValidApiKey(apikeys.openrouter) then
        local or_models = fetchProviderList("openrouter", apikeys.openrouter)
        if or_models then
            printf("\n%sNEW-id metadata via the OpenRouter marketplace (tier proposals - human places tiers):%s",
                C.bold, C.off)
            for _i, entry in ipairs(to_probe) do
                local slug, meta = ModelAudit.openrouterLookup(or_models, entry.provider, entry.model)
                local note = slug and ModelAudit.openrouterAnnotation(meta)
                if note then
                    printf("  %s/%s: %s  %s(%s)%s",
                        entry.provider, entry.model, note, C.dim, slug, C.off)
                else
                    printf("  %s%s/%s: no marketplace match%s",
                        C.dim, entry.provider, entry.model, C.off)
                end
            end
        end
    end

    if mode == "probe-new" then
        if #to_probe == 0 then
            print("\nNothing new to probe.")
        else
            printf("\n%d new model(s) to probe.", #to_probe)
            for idx, entry in ipairs(to_probe) do
                if idx > MAX_PROBE_NEW then
                    printf("%sstopping at %d probes - rerun with --probe %s %s (and beyond) for the rest%s",
                        C.yellow, MAX_PROBE_NEW, entry.provider, entry.model, C.off)
                    break
                end
                probeModel(entry.provider, entry.model, keyFor(apikeys, entry.provider), verbose)
            end
        end
    elseif #to_probe > 0 then
        printf("\n%sTip:%s probe new ids with --probe (or all at once with --probe-new).",
            C.bold, C.off)
    end
end

-- Run main() only when executed directly (unit tests require this file as a
-- lib; the path-boundary anchor keeps test_model_audit.lua from matching).
if arg and arg[0]
        and (arg[0]:match("^model_audit%.lua$") or arg[0]:match("/model_audit%.lua$")) then
    main()
end

return ModelAudit
