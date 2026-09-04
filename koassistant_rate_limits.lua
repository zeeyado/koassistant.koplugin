--[[
Per-minute admission limits (2026-09-03, docs/tpm_admission_plan.md).

Some providers (Groq, Cerebras, OpenAI) admit a request only if prompt tokens PLUS the
requested answer budget (max_tokens) fit the plan's tokens-per-minute allowance, and
refuse BEFORE running anything otherwise. Groq's free plan allows 8,000/min on the
gpt-oss models while the plugin's default budget is 32,768, so every request was
refused (docs/max_tokens_tpm_investigation.md).

This module learns the allowance from the providers' own rate-limit response headers
(x-ratelimit-limit-tokens, OpenAI-style) and, as a fallback, from the refusal text
("Limit N, Requested M"), keeps it in memory per provider+model for THIS SESSION only,
and sizes the answer budget to fit. Nothing is persisted: the allowance belongs to the
account's plan, not the model, and changes when the plan changes.

Pure: no KOReader requires, unit-tested in tests/unit/test_rate_limits.lua.
]]

local RateLimits = {}

--- Marker line the forked fetch child writes into the pipe so the parent learns the
--- response headers (the pipe carries only the body otherwise). Same shape as
--- BaseHandler.PROTOCOL_NON_200: "\r\n<marker><fields>\n\n".
RateLimits.PROTOCOL_MARKER = "X-KOA-RATELIMIT:"

--- Response headers worth forwarding (lower-case). The OpenAI-style family is exactly
--- the family sent by the providers that gate on max_tokens (OpenAI, Groq; Cerebras with a
--- "-minute" suffix). Anthropic (anthropic-ratelimit-*) and Gemini (none) use other names
--- and never gate this way; OpenRouter sends only a generic X-RateLimit-Limit on its own
--- errors. Daily buckets (*-tokens-day, and Groq's x-ratelimit-limit-requests = RPD) are
--- deliberately NOT read: only the per-minute allowance decides admission.
RateLimits.HEADER_FIELDS = {
    ["x-ratelimit-limit-tokens"] = "limit_tokens",
    ["x-ratelimit-limit-tokens-per-minute"] = "limit_tokens",
    ["x-ratelimit-limit-tokens-minute"] = "limit_tokens",          -- Cerebras spelling
    ["x-ratelimit-remaining-tokens"] = "remaining_tokens",
    ["x-ratelimit-remaining-tokens-per-minute"] = "remaining_tokens",
    ["x-ratelimit-remaining-tokens-minute"] = "remaining_tokens",
    ["x-ratelimit-reset-tokens"] = "reset_tokens",
    ["x-ratelimit-limit-requests"] = "limit_requests",
    ["x-ratelimit-remaining-requests"] = "remaining_requests",
    ["retry-after"] = "retry_after",
}

RateLimits.MARGIN = 256   -- tokens kept free under the allowance (estimate slack)
RateLimits.FLOOR = 512    -- below this an answer is not worth asking for
RateLimits.BYTES_PER_TOKEN = 3  -- conservative across scripts (CJK ~3 bytes/token)

--- Could this number be a real model or plan token count?
--- NOT a provider constant: it is the "a token count that could be a real model
--- or plan number" bound that already lived in the tree, in the self-heal parser
--- (model_constraints.lua parseMaxTokensError now delegates here, so there is
--- ONE definition). It rejects a digit lifted out of a model name (`llama3` -> 3),
--- a number too small for an allowance worth sizing against, and the 800030000
--- that a duplicated response header welds into one value on the device transport.
--- @param n any
--- @return boolean
function RateLimits.saneTokenCount(n)
    return type(n) == "number" and n >= 1024 and n < 10000000
end

local memo = {}  -- ["provider/model"] = { limit_tokens=, remaining_tokens=, source= }

local function key(provider, model)
    return tostring(provider or "?") .. "/" .. tostring(model or "?")
end

--- Pick the forwardable fields out of a headers table (any key case).
--- @param headers table|nil
--- @return table|nil fields (nil when nothing relevant is present)
function RateLimits.fromHeaders(headers)
    if type(headers) ~= "table" then return nil end
    local out, any = {}, false
    for k, v in pairs(headers) do
        local name = RateLimits.HEADER_FIELDS[tostring(k):lower()]
        if name and out[name] == nil then
            out[name] = tostring(v)
            any = true
        end
    end
    return any and out or nil
end

--- Child side: one marker line for the pipe. Values are sanitized to a safe charset.
--- @param headers table|nil raw response headers
--- @return string|nil the full line (with the surrounding newlines), nil when empty
function RateLimits.encodeMarker(headers)
    local fields = RateLimits.fromHeaders(headers)
    if not fields then return nil end
    local names = {}
    for name in pairs(fields) do names[#names + 1] = name end
    table.sort(names)
    local parts = {}
    for _idx, name in ipairs(names) do
        local v = tostring(fields[name]):gsub("[^%w%.:%-]", "")
        parts[#parts + 1] = name .. "=" .. v
    end
    return "\r\n" .. RateLimits.PROTOCOL_MARKER .. table.concat(parts, ";") .. "\n\n"
end

--- Parent side: fields out of one marker line (with or without the prefix).
--- @param line string
--- @return table|nil fields
function RateLimits.decodeMarker(line)
    if type(line) ~= "string" then return nil end
    local body = line
    local p = line:find(RateLimits.PROTOCOL_MARKER, 1, true)
    if p then body = line:sub(p + #RateLimits.PROTOCOL_MARKER) end
    body = body:match("^%s*(.-)%s*$") or ""
    if body == "" then return nil end
    local out, any = {}, false
    for pair in body:gmatch("[^;]+") do
        local k, v = pair:match("^([%w_]+)=(.*)$")
        if k and v and v ~= "" then out[k] = v; any = true end
    end
    return any and out or nil
end

--- Non-streaming consumer: pull the marker line out of a whole pipe buffer.
--- @param text string
--- @return table|nil fields, string cleaned text (marker line removed)
function RateLimits.extractMarker(text)
    if type(text) ~= "string" then return nil, text end
    local s = text:find(RateLimits.PROTOCOL_MARKER, 1, true)
    if not s then return nil, text end
    local e = text:find("\n", s, true) or #text
    local line = text:sub(s, e)
    local cleaned = text:sub(1, s - 1) .. text:sub(e + 1)
    return RateLimits.decodeMarker(line), cleaned
end

--- Remember what a provider told us. Only a limit that could be real is worth
--- keeping, and where two sources disagree the more reliable one wins: a header
--- (or the "Test provider" probe) is the provider stating the plan, while a
--- refusal is prose the plugin read numbers out of.
--- @param provider string
--- @param model string|nil
--- @param fields table|nil (fromHeaders/decodeMarker shape)
--- @param source string|nil "header" | "refusal" | "probe" | "context"
--- @return boolean recorded
function RateLimits.record(provider, model, fields, source)
    if type(fields) ~= "table" then return false end
    local limit = tonumber(fields.limit_tokens)
    if not limit or limit <= 0 then return false end
    limit = math.floor(limit)
    if not RateLimits.saneTokenCount(limit) then return false end
    source = source or "header"
    local k = key(provider, model)
    local old = memo[k]
    local function stated(src) return src == "header" or src == "probe" end
    if old and stated(old.source) and not stated(source) then
        return false
    end
    -- A "context" record (a model's context window, written by the self-heal)
    -- shares this slot with the allowance: one slot holding two quantities is
    -- open question Q3 of the request-sizing audit. Until it is answered, a
    -- window may replace a refusal-learned allowance (later writer wins, as
    -- before) but never a header- or probe-stated one, because a larger window
    -- overwriting a smaller allowance would re-open #106 for the session.
    local remaining = tonumber(fields.remaining_tokens)
    if remaining and (remaining < 0 or remaining >= 10000000) then remaining = nil end
    memo[k] = {
        limit_tokens = limit,
        remaining_tokens = remaining,
        source = source,
    }
    return true
end

--- @return table|nil { limit_tokens, remaining_tokens, source }
function RateLimits.known(provider, model)
    return memo[key(provider, model)]
end

function RateLimits.forget(provider, model)
    memo[key(provider, model)] = nil
end

--- Test seam.
function RateLimits._reset()
    memo = {}
end

--- Conservative prompt-size estimate from byte length.
function RateLimits.estimateTokens(chars)
    local n = tonumber(chars) or 0
    if n <= 0 then return 0 end
    return math.ceil(n / RateLimits.BYTES_PER_TOKEN)
end

--- The largest answer budget the plan admits for a prompt of this size, or nil when the
--- plan is unknown OR the prompt itself leaves no usable room (then the request goes out
--- unchanged and the provider's refusal explains it honestly).
--- @param provider string
--- @param model string|nil
--- @param prompt_chars number byte length of everything we send as text
--- @param prompt_tokens number|nil exact prompt tokens when a refusal told us
--- @return number|nil cap
function RateLimits.budgetCap(provider, model, prompt_chars, prompt_tokens)
    local k = memo[key(provider, model)]
    if not k then return nil end
    local used = prompt_tokens or RateLimits.estimateTokens(prompt_chars)
    local room = k.limit_tokens - used - RateLimits.MARGIN
    if room < RateLimits.FLOOR then return nil end
    return math.floor(room)
end

--- Byte size of everything we send as text: the system prompt plus every message
--- whose content is a string. LIFTED VERBATIM from the closure in
--- koassistant_gpt_query.lua's dispatch path, so a pre-send check and the
--- dispatch-time cap work from the same number by construction and cannot drift.
--- @param system_text string|nil config.system.text
--- @param messages table|nil the message history
--- @return number bytes
function RateLimits.promptChars(system_text, messages)
    local n = 0
    if type(system_text) == "string" then
        n = n + #system_text
    end
    for _idx = 1, #(messages or {}) do
        local m = messages[_idx]
        if m and type(m.content) == "string" then n = n + #m.content end
    end
    return n
end

--- Does the plan this session knows about leave no room for an answer? Exactly
--- budgetCap's own condition (allowance minus the prompt estimate minus MARGIN
--- below FLOOR), asked ahead of time: no new threshold, and it can never
--- disagree with the cap because it asks the cap.
--- @param provider string
--- @param model string|nil
--- @param prompt_chars number byte length of everything we send as text
--- @return number|nil limit, number estimate, string|nil source
---         (nil = the plan is unknown, or it leaves usable room)
function RateLimits.promptExceedsPlan(provider, model, prompt_chars)
    local k = memo[key(provider, model)]
    if not k then return nil end
    if RateLimits.budgetCap(provider, model, prompt_chars) then return nil end
    return k.limit_tokens, RateLimits.estimateTokens(prompt_chars), k.source
end

--- Apply the cap to a resolved/pinned budget: only ever shrinks.
--- @return number|nil new value, boolean changed
function RateLimits.applyCap(value, cap)
    if not cap then return value, false end
    if value == nil or value > cap then return cap, true end
    return value, false
end

local PER_MINUTE_SIGNATURES = { "tokens per min", "(tpm)", "tokens-per-minute" }

--- Where the per-minute signature starts in a lowercased error text (earliest
--- of the three spellings), or nil when the text is not about a per-minute
--- token bucket at all.
local function perMinutePos(l)
    local best
    for _idx = 1, #PER_MINUTE_SIGNATURES do
        local p = l:find(PER_MINUTE_SIGNATURES[_idx], 1, true)
        if p and (not best or p < best) then best = p end
    end
    return best
end

--- Read "<word> N" out of a text, tolerating the separators providers use
--- ("Limit 8000", "limit: 12,000", "Requested ~12903"). The word must stand on
--- its own, so "delimiter" is not a limit and "caused" is not a used count, and
--- the number must follow the word directly (spaces, a colon, a tilde or an
--- equals sign in between, nothing else), so a model id such as `limit-3b` or
--- a "try again in 20s" further down the sentence never supplies the number.
local function numberAfter(text, word)
    local raw = text:match("%f[%a]" .. word .. "%f[%A][%s:~=]*(%d[%d,]*)")
    if not raw then return nil end
    return tonumber((raw:gsub(",", "")))
end

--- Does the text carry a "Used N" count, for ANY bucket (per minute, per day)?
--- A used count means the bucket is SPENT and refills with time, so a wording
--- that carries one is never a deterministic size error, whatever else it says.
--- @param err_text string|nil
--- @return boolean
function RateLimits.hasUsedCount(err_text)
    if type(err_text) ~= "string" or err_text == "" then return false end
    return numberAfter(err_text:lower(), "used") ~= nil
end

--- Recognize a per-minute refusal and read its numbers. Tolerant on purpose: a
--- per-minute signature plus a limit number and a requested number, in any prose.
--- Groq: "... on tokens per minute (TPM): Limit 8000, Requested 32979, please reduce ..."
--- OpenAI: "... on tokens per min (TPM): Limit 30000, Requested 40000. The input or output tokens must be reduced ..."
--- The numbers are read from the text AFTER the signature only. Every real
--- rate-limit 429 opens "Rate limit reached for model `llama3-70b-8192`", so a
--- search of the whole text for "limit" reads the 3 out of the model name and
--- reports an allowance of 3 tokens a minute.
--- @param err_text string
--- @return table|nil { limit = N, requested = M, used = U or nil }
function RateLimits.parseRefusal(err_text)
    if type(err_text) ~= "string" or err_text == "" then return nil end
    local l = err_text:lower()
    local at = perMinutePos(l)
    if not at then return nil end
    local tail = l:sub(at)
    local limit = numberAfter(tail, "limit")
    local requested = numberAfter(tail, "requested")
    local used = numberAfter(tail, "used")
    if not limit or not requested or limit <= 0 or requested <= 0 then return nil end
    return {
        limit = math.floor(limit),
        requested = math.floor(requested),
        used = used and math.floor(used) or nil,
    }
end

--- Which kind of per-minute refusal is this?
---   "burst"     the allowance is already spent ("Used N" in the wording). The
---               bucket refills with TIME, not with a smaller request, so a
---               burst must never be resent at a smaller budget.
---   "admission" prompt plus the requested answer budget did not fit the
---               allowance. Deterministic, so a smaller budget can help, and the
---               honest explanation names what was too big. Covers the wordings
---               that state no numbers at all (Cerebras), which parseRefusal
---               cannot classify because it returns nil for them.
---   nil         not a per-minute token refusal (a daily bucket, a
---               requests-per-minute 429, an output cap, ordinary prose).
--- @param err_text string|nil
--- @return string|nil
function RateLimits.refusalKind(err_text)
    if type(err_text) ~= "string" or err_text == "" then return nil end
    local l = err_text:lower()
    local at = perMinutePos(l)
    if not at then return nil end
    if numberAfter(l:sub(at), "used") then return "burst" end
    return "admission"
end

--- Budget for the one resend after a refusal. When we know the budget the refused
--- request carried, the prompt size is exact (requested - sent); otherwise estimate.
--- @param refusal table parseRefusal output
--- @param sent_budget number|nil the max_tokens the refused request carried
--- @param prompt_chars number|nil
--- @return number|nil budget (nil = the prompt alone does not fit; do not resend)
function RateLimits.retryBudget(refusal, sent_budget, prompt_chars)
    if type(refusal) ~= "table" then return nil end
    local used
    if sent_budget and refusal.requested > sent_budget then
        used = refusal.requested - sent_budget
    else
        used = RateLimits.estimateTokens(prompt_chars)
    end
    local room = refusal.limit - used - RateLimits.MARGIN
    if room < RateLimits.FLOOR then return nil end
    return math.floor(room)
end

--- Exact prompt tokens implied by a refusal, when the sent budget is known.
function RateLimits.promptTokensFromRefusal(refusal, sent_budget)
    if type(refusal) ~= "table" or not sent_budget then return nil end
    if refusal.requested > sent_budget then return refusal.requested - sent_budget end
    return nil
end

return RateLimits
