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

--- Remember what a provider told us. Only a numeric limit is worth keeping.
--- @param provider string
--- @param model string|nil
--- @param fields table|nil (fromHeaders/decodeMarker shape)
--- @param source string|nil "header" | "refusal" | "probe" (for logs/tests)
--- @return boolean recorded
function RateLimits.record(provider, model, fields, source)
    if type(fields) ~= "table" then return false end
    local limit = tonumber(fields.limit_tokens)
    if not limit or limit <= 0 then return false end
    memo[key(provider, model)] = {
        limit_tokens = math.floor(limit),
        remaining_tokens = tonumber(fields.remaining_tokens),
        source = source or "header",
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

--- Apply the cap to a resolved/pinned budget: only ever shrinks.
--- @return number|nil new value, boolean changed
function RateLimits.applyCap(value, cap)
    if not cap then return value, false end
    if value == nil or value > cap then return cap, true end
    return value, false
end

--- Recognize an admission refusal and read its numbers. Tolerant on purpose: a
--- per-minute signature plus a limit number and a requested number, in any prose.
--- Groq: "... on tokens per minute (TPM): Limit 8000, Requested 32979, please reduce ..."
--- OpenAI: "... on tokens per min (TPM): Limit 30000, Requested 40000. The input or output tokens must be reduced ..."
--- @param err_text string
--- @return table|nil { limit = N, requested = M }
function RateLimits.parseRefusal(err_text)
    if type(err_text) ~= "string" or err_text == "" then return nil end
    local l = err_text:lower()
    local per_minute = l:find("tokens per min", 1, true) or l:find("(tpm)", 1, true)
        or l:find("tokens-per-minute", 1, true)
    if not per_minute then return nil end
    local limit = tonumber(l:match("limit[^%d]-(%d[%d,]*)") and l:match("limit[^%d]-(%d[%d,]*)"):gsub(",", ""))
    local requested = tonumber(l:match("requested[^%d]-(%d[%d,]*)") and l:match("requested[^%d]-(%d[%d,]*)"):gsub(",", ""))
    if not limit or not requested or limit <= 0 or requested <= 0 then return nil end
    return { limit = math.floor(limit), requested = math.floor(requested) }
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
