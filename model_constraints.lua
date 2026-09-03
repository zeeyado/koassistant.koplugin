-- Model Constraints
-- Centralized definitions for model-specific parameter constraints
-- Add new constraints here as they are discovered via --models testing
--
-- Also defines model capabilities (reasoning/thinking support)
--
-- Capability RESOLUTION ORDER (agenda item 19, docs/model_capability_resolution_plan.md):
--   user override (custom_models.lua) → curated lists below (specific entries first)
--   → derived provider metadata (OpenRouter supported_parameters cache)
--   → family-prefix fallback entries (appended after the specifics).
-- The non-curated layers live in koassistant_model_overrides.lua.

local ModelOverrides = require("koassistant_model_overrides")

local ModelConstraints = {
    openai = {
        -- Models requiring temperature=1.0 (reject other values)
        -- Discovered via: lua tests/run_tests.lua --models openai
        ["gpt-5.6"] = { temperature = 1.0 },   -- luna/sol/terra (prefix); rejects temp!=1 (verified 2026-07-24)
        ["gpt-5.5"] = { temperature = 1.0 },
        ["gpt-5.4"] = { temperature = 1.0 },
        ["gpt-5.4-mini"] = { temperature = 1.0 },
        ["gpt-5.4-nano"] = { temperature = 1.0 },
    },
    anthropic = {
        -- Max temperature is 1.0 for all Anthropic models (vs 2.0 for others)
        _provider_max_temperature = 1.0,
        -- Extended thinking also requires temp=1.0, handled separately in handler
    },
    kimi = {
        -- kimi-k2.6 international (probed 2026-08-15): temperature is
        -- MODE-LOCKED — thinking on (the API default) accepts ONLY 1,
        -- thinking disabled accepts ONLY 0.6; omitting it works in both
        -- modes. The plugin never disables kimi thinking today, so forcing
        -- 1.0 keeps every current request valid (our old 0.7 default 400'd).
        -- If a future tool-session accommodation disables thinking
        -- (deepseek-class, verified viable), it must adjust/drop temp too.
        ["kimi-k2.6"] = { temperature = 1.0 },
    },
    -- Add more providers/models as discovered
}

-- Model capabilities (reasoning/thinking support)
-- Used to determine if a model supports specific features
-- NOTE: Use base model names (without dates) to enable prefix matching
-- e.g., "claude-sonnet-4-5" matches "claude-sonnet-4-5-20250929", "claude-sonnet-4-5-latest", etc.
ModelConstraints.capabilities = {
    anthropic = {
        -- Models that support adaptive thinking (4.6+)
        -- New mode: thinking = {type = "adaptive"}, output_config = {effort = "..."}
        adaptive_thinking = {
            "claude-opus-5",          -- Opus 5 (adaptive ON at API default, disable accepted)
            "claude-fable-5",         -- Fable 5 (frontier; adaptive ALWAYS-ON, no disable)
            "claude-sonnet-5",        -- 5 Sonnet
            "claude-opus-4-8",        -- 4.8 Opus
            "claude-opus-4-7",        -- 4.7 Opus (prefix-matched for safety)
            "claude-sonnet-4-6",      -- 4.6 Sonnet
            "claude-opus-4-6",        -- 4.6 Opus (prefix-matched for safety)
        },
        -- Models that REJECT sampling params (temperature/top_p/top_k → HTTP 400)
        -- Opus 4.7+, Sonnet 5, Opus 5, and Fable 5 removed sampling params entirely
        -- (Opus 5: "temperature is deprecated for this model", verified 2026-07-25);
        -- the builder strips them.
        no_sampling_params = {
            "claude-opus-5",
            "claude-fable-5",
            "claude-sonnet-5",
            "claude-opus-4-8",
            "claude-opus-4-7",
        },
        -- Models that support extended thinking (manual budget_tokens mode)
        -- Deprecated in favor of adaptive; NOTE: NOT supported on Opus 4.7/4.8 or Sonnet 5 (would 400).
        extended_thinking = {
            "claude-sonnet-4-6",      -- 4.6 Sonnet (also adaptive; budget mode still works)
            "claude-haiku-4-5",       -- 4.5 Haiku
        },
        -- Function calling for the book-tool workflows. Tool use is universal on Claude,
        -- so "claude" is a safe FAMILY FALLBACK (unlike the reasoning-adjacent lists above,
        -- where old ids collide across param boundaries — no family entries there). Added
        -- 2026-07-25 after claude-opus-5 launched with tools dead on the native provider.
        tools = {
            "claude",
        },
    },
    openai = {
        -- Models that support reasoning.effort parameter
        -- ("gpt-5" = family fallback, item 19a: new 5.x minors inherit)
        reasoning = {
            "gpt-5.6",                              -- luna/sol/terra (prefix)
            "gpt-5.5",
            "gpt-5.4", "gpt-5.4-mini", "gpt-5.4-nano",
            "gpt-5",
        },
        -- Models where reasoning is opt-in (default=none from OpenAI)
        -- GPT-5.4 + GPT-5.6 default reasoning_effort=none (off; verified 2026-07-24 — 0 reasoning
        -- tokens with nothing sent); gated by master toggle + openai_reasoning sub-toggle.
        -- GPT-5.5 reasons at medium by default (NOT gated — always reasons at factory default).
        reasoning_gated = {
            "gpt-5.6",
            "gpt-5.4", "gpt-5.4-mini", "gpt-5.4-nano",
        },
        -- Function calling for the book-tool workflows (prefix match covers -mini/-nano/-sol/etc.;
        -- "gpt-5" = family fallback).
        tools = {
            "gpt-5.6", "gpt-5.5", "gpt-5.4",
            "gpt-5",
        },
        -- Responses API (/v1/responses) eligibility — the openai handler routes
        -- web-search-on requests (R1: Chat Completions has NO native search) AND
        -- book-tool sessions (R3: reasoning persists across tool rounds) there
        -- (responses_api_plan.md). Also the web-search UI gate via
        -- _web_search_providers below. Prefix match covers -mini/-nano;
        -- "gpt-5" = family fallback.
        responses_web_search = {
            "gpt-5.6", "gpt-5.5", "gpt-5.4",
            "gpt-5",
        },
    },
    deepseek = {
        -- V4: both models support thinking toggle (type: enabled/disabled), ON by default
        -- ("deepseek" = family fallback — the toggle is universal since V3.2)
        thinking = { "deepseek-v4-pro", "deepseek-v4-flash", "deepseek" },
        -- Keep reasoning list for tier system (which models are "reasoning-class")
        reasoning = { "deepseek-v4-pro" },
        -- Function calling for the book-tool workflows (tools wave 1; both V4 models
        -- per api-docs.deepseek.com — works in thinking AND non-thinking mode since V3.2).
        -- Wire gotchas (deepseek.lua): (1) replayed tool-call turns MUST carry
        -- reasoning_content (400 if dropped); (2) thinking mode rejects tool_choice
        -- "required" (our gather rounds) — "Thinking mode does not support this
        -- tool_choice" — and V4 thinks by DEFAULT, so deepseek.lua forces
        -- thinking={type=disabled} on any tool session.
        -- ("deepseek" = family fallback — function calling universal since V3.2)
        tools = { "deepseek-v4", "deepseek" },
    },
    gemini = {
        -- Gemini 3 models use thinkingLevel (minimal/low/medium/high).
        -- "gemini-3" = FAMILY FALLBACK (item 19a): new 3.x minors inherit without a
        -- plugin update; the specific entries stay for documentation value.
        thinking = { "gemini-3.7-flash", "gemini-3.6-flash", "gemini-3.5-flash-lite", "gemini-3.5-flash", "gemini-3.1-pro-preview", "gemini-3.1-flash-lite", "gemini-3" },
        -- Gemini 2.5 models use thinkingBudget (0=off, -1=dynamic, 128-24576).
        -- gemini-3.1-pro-preview ALSO accepts thinkingBudget (probed 2026-08-15,
        -- budget 0 rejected "only works in thinking mode") but its curated axis is
        -- thinkingLevel like all 3.x — deliberately NOT listed here.
        thinking_budget = { "gemini-2.5-flash", "gemini-2.5-pro", "gemini-2.5-flash-lite" },
        -- Google Search grounding ("gemini-3" = family fallback)
        google_search = {
            "gemini-3.7-flash", "gemini-3.6-flash", "gemini-3.5-flash-lite", "gemini-3.5-flash", "gemini-3.1-pro-preview", "gemini-3.1-flash-lite",
            "gemini-2.5-flash", "gemini-2.5-pro", "gemini-2.5-flash-lite",
            "gemini-3",
        },
        -- Function calling for the book-tool workflows (same models as google_search).
        -- The runner's shouldUse gates on this + a tool_wire.lua adapter being registered.
        tools = {
            "gemini-3.7-flash", "gemini-3.6-flash", "gemini-3.5-flash-lite", "gemini-3.5-flash", "gemini-3.1-pro-preview", "gemini-3.1-flash-lite",
            "gemini-2.5-flash", "gemini-2.5-pro", "gemini-2.5-flash-lite",
            "gemini-3",
        },
    },
    -- Note: Z.AI web search only works via a separate endpoint (/api/paas/v4/tools),
    -- NOT via the chat completions tools parameter (silently ignored).
    -- Book tools: GLM function calling on chat completions IS supported (verified
    -- 2026-07-20, docs.z.ai/guides/capabilities/function-calling — OpenAI wire,
    -- JSON-string arguments), but tool_choice only supports "auto": the runner's
    -- gather mode (tool_choice=required) and final pass (tool_choice=none) both
    -- depend on non-auto values, so Z.AI stays OUT of tools wave 1 until it gets
    -- a downgrade accommodation + live test (web_search_tool_plan.md).
    zai = {
        -- GLM-4.5+ models support toggleable thinking (type: enabled/disabled)
        -- Returns reasoning_content field in responses (like DeepSeek)
        -- IMPORTANT: Z.AI requires temperature=1.0 when thinking is enabled
        -- (enforced in zai.lua handler, not here — thinking is togglable)
        -- (No bare "glm" family fallback — it would wrongly cover pre-4.5
        -- non-thinking ids like glm-4-plus; "glm-5" already covers 5.x minors.)
        thinking = {
            "glm-5.2", "glm-5.1", "glm-5-turbo", "glm-5",
            "glm-4.7", "glm-4.7-flash",
        },
    },
    openrouter = {
        -- Unified reasoning object works for all backend models
        -- OpenRouter auto-translates effort to each provider's native format
        -- No model list needed — controlled by whether reasoning param is sent
        -- Function calling for the book-tool workflows. OpenRouter normalizes the OpenAI
        -- tools format across backends; seeded with frontier families whose function
        -- calling is universal — expand only after live verification per family.
        -- 2026-07-25: expanded to every curated-array family whose endpoints report
        -- `tools` in supported_parameters (verified live via tests/model_audit.lua
        -- marketplace cross-check). Prefixes kept generation-scoped where older
        -- siblings might differ (deepseek-v4, grok-4, kimi-k2, minimax-m2).
        tools = {
            "anthropic/claude", "openai/gpt-5", "google/gemini-3", "google/gemini-2.5",
            "deepseek/deepseek-v4", "x-ai/grok-4", "meta-llama/llama-3.3-70b-instruct",
            "mistralai/mistral-large", "mistralai/mistral-medium", "qwen/qwen3",
            "moonshotai/kimi-k2", "minimax/minimax-m2",
            "openai/gpt-oss",   -- open-weight; groq probe grants the same family
        },
    },
    requesty = {
        -- Unified reasoning object works across routed backend models
        -- Requesty forwards effort to each provider's native format
        -- No model list needed — controlled by whether reasoning param is sent
    },
    groq = {
        -- Models with reasoning_effort support
        reasoning = {
            "openai/gpt-oss-120b", "openai/gpt-oss-20b",
            "qwen/qwen3-32b",
        },
        -- Function calling for the book-tool workflows (tools wave 1; per
        -- console.groq.com/docs/tool-use). groq/compound* excluded: built-in
        -- agentic tools only — user-defined tools are explicitly unsupported.
        -- (qwen3-32b + llama-4-scout deprecated by Groq 2026-07-17, not listed.)
        tools = {
            "llama-3.3-70b-versatile", "llama-3.1-8b-instant",
            "openai/gpt-oss-120b", "openai/gpt-oss-20b",
        },
    },
    together = {
        -- Models with reasoning_effort support
        reasoning = {
            "deepseek-ai/DeepSeek-V4-Pro",
            "Qwen/Qwen3.5-397B-A17B",
            "Qwen/Qwen3-235B-A22B",
        },
    },
    fireworks = {
        -- Live-probed 2026-08-15 (keyed account, model_audit battery on every
        -- serving id in the curated list): reasoning_content comes back by
        -- DEFAULT on all of them; tools + forced tool_choice + two-round
        -- replay green (wave 2 — ToolWire alias added the same day).
        reasoning = {
            "accounts/fireworks/models/deepseek-v4-pro",
            "accounts/fireworks/models/deepseek-v4-flash-0731",
            "accounts/fireworks/models/qwen3p8-max",
            "accounts/fireworks/models/kimi-k2p6",
            "accounts/fireworks/models/glm-5p2",
            "accounts/fireworks/models/gpt-oss-120b",
            "accounts/fireworks/models/gpt-oss-20b",
        },
        tools = {
            "accounts/fireworks/models/deepseek-v4-pro",
            "accounts/fireworks/models/deepseek-v4-flash-0731",
            "accounts/fireworks/models/qwen3p8-max",
            "accounts/fireworks/models/kimi-k2p6",
            "accounts/fireworks/models/glm-5p2",
            "accounts/fireworks/models/gpt-oss-120b",
            "accounts/fireworks/models/gpt-oss-20b", -- not probed directly; same model as the probed 120b/groq pair
        },
    },
    sambanova = {
        -- Models with thinking toggle (chat_template_kwargs.enable_thinking)
        thinking = { "DeepSeek-V3.1", "DeepSeek-V3.2" },
    },
    qwen = {
        -- Probed live 2026-08-15 (DashScope international, model_audit battery):
        -- qwen3-max = no default reasoning, temp free in [0, 2), out 65536,
        -- tools + forced tool_choice + two-round replay all green (wave 2 —
        -- ToolWire alias added same day). Other qwen ids unprobed for tools;
        -- grant as batteries run. enable_search web search is wired in
        -- qwen.lua (server-side injection; no sources on this wire).
        tools = { "qwen3-max" },
    },
    kimi = {
        -- kimi-k2.6 probed live 2026-08-15 (international platform): thinks by
        -- default, disable via thinking={type="disabled"} (anthropic shape);
        -- tools green ONLY with thinking disabled (tool_choice=required is
        -- "incompatible with thinking enabled") — kimi.lua forces the disable
        -- on tool sessions (deepseek precedent) and drops temperature
        -- (mode-locked, see forced params).
        thinking = { "kimi-k2.6" },
        tools = { "kimi-k2.6" },
    },
    xai = {
        -- grok-4.6 supports reasoning_effort minimal..xhigh ("none" rejected — probe 2026-08-14);
        -- grok-4.5/4.3 and the grok-4.20 reasoning variant support reasoning_effort (none/low/medium/high)
        -- The grok-4.20 non-reasoning slug has no effort control
        reasoning = { "grok-4.6", "grok-4.5", "grok-4.3", "grok-4.20-0309-reasoning" },
        -- Grok-4-family models take the native web_search agent tool on xAI's
        -- Responses endpoint (/v1/responses, OpenAI-compatible wire — the old
        -- chat-completions live search returns 410 Gone since 2026-01-12).
        -- Routing in xai.lua; also the web-search UI gate via _web_search_providers.
        -- Prefix match: "grok-4.20" covers both -0309 slugs. "grok-4" = family fallback.
        responses_web_search = {
            "grok-4.5", "grok-4.3", "grok-4.20",
            "grok-4",
        },
        -- Function calling for the book-tool workflows (tools wave 1) — on the CHAT
        -- wire: xai.lua's Responses routing bails when config.tools is set. Per-model
        -- "Function calling: Yes" on docs.x.ai (grok-4.5 + grok-build confirm chat
        -- completions explicitly; 4.3/4.20 pages are less explicit — live test).
        -- "grok-4" = family fallback. (NOT added to `reasoning` — the non-reasoning
        -- grok-4.20-0309 slug would collide.)
        tools = {
            "grok-4.5", "grok-4.3", "grok-4.20", "grok-build",
            "grok-4",
        },
    },
    -- NVIDIA (build.nvidia.com). Every entry below was probed live 2026-08-20.
    -- NO web-search capability by design: the chat wire 400s on any non-`function`
    -- tool type, and the Responses endpoint silently DISCARDS {type="web_search"}
    -- (200, but empty annotations and the model says it has no internet access).
    nvidia = {
        -- reasoning_effort verified HONOURED on the nemotron-3 family: low ~140
        -- chars of reasoning_content vs high ~540 on one prompt, 3 samples each,
        -- and "none" returns 0.
        reasoning = {
            "nvidia/nemotron-3",
        },
        -- Function calling. EXACT ids, never a family prefix: within the very same
        -- nemotron-3 family some models emit structured tool_calls under
        -- tool_choice="required" while others answer with the call as PROSE JSON
        -- in `content` (tool_calls null, finish_reason "stop"), which the
        -- book-tools gather phase cannot consume.
        --
        -- Granted only where BOTH auto and forced returned real tool_calls across
        -- repeated samples (device round 2026-08-20). An HTTP 200 proves nothing
        -- here: the prose answers are all 200s, so the probe must inspect
        -- message.tool_calls itself. The first pass got this backwards by
        -- status-code alone.
        --
        -- Withheld, with the reason, so nobody widens this again:
        --   nvidia/nemotron-3-super-120b-a12b  forced -> prose, every sample
        --   nvidia/nemotron-3-ultra-550b-a55b  forced -> prose intermittently
        --   openai/gpt-oss-20b                 auto   -> prose intermittently
        --   minimaxai/minimax-m3               rate-limited, inconclusive
        -- nano-9b-v2, llama-3.3-nemotron-super-49b, llama-3.1-70b and
        -- step-3.7-flash were retired by NVIDIA 2026-08-26 (HTTP 410).
        tools = {
            "nvidia/nemotron-3-nano-30b-a3b",
        },
    },
    perplexity = {
        -- Reasoning models (always-on, but effort is controllable)
        -- sonar-reasoning-pro uses <think> tags, sonar-deep-research also supports effort
        reasoning = { "sonar-reasoning-pro", "sonar-deep-research" },
    },
    mistral = {
        -- Magistral models always think (no toggle, extraction only)
        -- Returns structured content blocks with type: "thinking"
        -- ("magistral" = family fallback, item 19a)
        thinking = { "magistral-medium", "magistral-small", "magistral" },
        -- Function calling for the book-tool workflows (tools wave 1; all current
        -- families per docs.mistral.ai/capabilities/function_calling). Magistral
        -- included: tool_calls coexists with structured thinking content, though a
        -- reported client bug says it may ignore tool_choice=required (gather mode
        -- falls back to prose acceptance) — live test.
        tools = {
            "mistral-large", "mistral-medium", "mistral-small",
            "codestral", "magistral",
            "ministral",    -- edge family (tools probe OK 2026-07-28, covers 3b/8b/14b)
        },
    },
}

-- Maximum output token limits per model
-- Used by handlers to clamp max_tokens before sending requests
-- Models with known output token ceilings (prevents API 400 errors)
-- Max-output ceilings (item 27, raise-where-known). DUAL ROLE: clampMaxTokens
-- caps explicit values down to these; resolveMaxTokens raises the default
-- request UP to min(MAX_TOKENS_TARGET, ceiling) for known models. Precision
-- above MAX_TOKENS_TARGET (32768) is irrelevant to the resolver — entries
-- BELOW it are the load-bearing ones (they prevent 400s AND cap the raise).
-- Prefix-matched (specific ids before shorter family prefixes not needed —
-- pairs() order is undefined, so never add a prefix that shadows a different-
-- valued specific entry). Sources: provider docs, OpenRouter public catalog
-- (top_provider.max_completion_tokens, fetched 2026-08-06), API error text.
ModelConstraints._max_output_tokens = {
    anthropic = {
        ["claude-opus-5"] = 128000,      -- 128K max output (API error text, verified 2026-07-25)
        ["claude-sonnet-5"] = 128000,    -- 128K max output
        ["claude-fable-5"] = 128000,     -- 128K (OpenRouter catalog 2026-08-06; matches 5-family)
        ["claude-opus-4-8"] = 128000,    -- 128K max output
        ["claude-sonnet-4-6"] = 64000,
        ["claude-haiku-4-5"] = 64000,
    },
    openai = {
        ["gpt-5"] = 128000,              -- whole 5.x family incl. 5.4-mini/nano (docs + OpenRouter catalog)
        ["gpt-4.1"] = 32768,             -- documented output cap
        ["gpt-4o"] = 16384,              -- documented output cap (guard for fetched models)
    },
    deepseek = {
        ["deepseek-v4-pro"] = 384000,    -- documented (1M ctx / 384K out)
        ["deepseek-v4-flash"] = 131072,  -- OpenRouter catalog 2026-08-06
    },
    gemini = {
        ["gemini-3"] = 65536,            -- 3.x family (docs; OpenRouter catalog agrees)
        ["gemini-2.5"] = 65536,          -- 2.5 family (docs)
    },
    xai = {
        -- Known-good floor: the handler shipped 32768 requests on grok-4
        -- reasoning models in the field; grok-4.3 documents 131K but the
        -- family-wide max is unprobed — raise per-model when probed.
        ["grok-4"] = 32768,
    },
    zai = {
        ["glm-5"] = 128000,              -- GLM-5.x documented 128K max output
        ["glm-4.7"] = 96000,             -- family ≥96K since GLM-4.5; exact value unprobed
    },
    qwen = {
        ["qwen3-max"] = 65536,           -- ceiling from oversized-max_tokens error (probed 2026-08-15)
    },
    openrouter = {
        -- All values = top_provider.max_completion_tokens from the public
        -- catalog (2026-08-06). x-ai/* and mistralai/* report none — left out.
        ["anthropic/claude-sonnet-5"] = 128000,
        ["anthropic/claude-opus-5"] = 128000,
        ["anthropic/claude-fable-5"] = 128000,
        ["anthropic/claude-sonnet-4.6"] = 128000,
        ["anthropic/claude-opus-4.8"] = 128000,
        ["anthropic/claude-haiku-4.5"] = 64000,
        ["openai/gpt-5"] = 128000,       -- prefix: 5.6-sol/terra/luna, 5.5, 5.4, 5.4-mini
        ["openai/gpt-oss"] = 131072,
        ["google/gemini-3"] = 65536,
        ["deepseek/deepseek-v4-pro"] = 384000,
        ["deepseek/deepseek-v4-flash"] = 131072,
        ["meta-llama/llama-3.3-70b-instruct"] = 16384,
        ["qwen/qwen3-max"] = 65536,
        ["qwen/qwen3-235b-a22b"] = 8192,
        ["perplexity/sonar-pro"] = 8000,
        ["moonshotai/kimi-k2-thinking"] = 100352,
        ["minimax/minimax-m2.1"] = 131072,
    },
    -- Community hosts (item 27 round 3, 2026-08-09). Adding entries here can only
    -- ever HELP: resolveMaxTokens asks min(32768, ceiling) and clampMaxTokens caps
    -- explicit values down, so a correct ceiling can never produce a 400 — unlike
    -- raising a provider's flat fallback, which can. Values read from each
    -- provider's own public /models catalog on 2026-08-09 unless noted.
    cerebras = {
        -- Verified identical across every model Cerebras currently serves
        -- (gpt-oss-120b, zai-glm-4.7, gemma-4-31b): limits.max_completion_tokens
        -- = 40960. Provider-wide "" entry so FETCHED models inherit it too; any
        -- specific id added later wins on longest-prefix.
        [""] = 40960,
    },
    deepinfra = {
        -- Docs state output caps at 16384 regardless of model. The catalog's
        -- metadata.max_tokens mirrors context_length (identical for all 182
        -- entries), so it is a context field and cannot serve as an output cap.
        -- Documented value, not catalog-verified.
        [""] = 16384,
    },
    novita = {
        -- Per-model and genuinely varied: 31 of 145 chat models cap below 16384,
        -- floor gryphe/mythomax-l2-13b at 3200. Only the two ids we ship are
        -- entered; anything else keeps the conservative provider fallback.
        ["deepseek/deepseek-v4"] = 393216,          -- covers -pro and -flash
        -- Output cap EQUALS the entire context window here, so any larger ask is
        -- an immediate 400 -- the clearest evidence that a flat raise is unsafe.
        ["meta-llama/llama-3.3-70b-instruct"] = 12288,
    },
    groq = {
        ["groq/compound"] = 8192,
        ["groq/compound-mini"] = 8192,
        ["meta-llama/llama-4-scout"] = 8192,
        -- Production models: cap to each model's documented max completion tokens
        -- so actions requesting a high max_tokens (e.g. X-Ray's 65536) don't get a
        -- bare HTTP 400 from Groq. (issue #89)
        ["llama-3.3-70b-versatile"] = 32768,   -- default Groq model
        ["qwen/qwen3-32b"] = 40960,
        ["openai/gpt-oss-120b"] = 65536,
        ["openai/gpt-oss-20b"] = 65536,
        -- llama-3.1-8b-instant allows 131072 output (no cap needed)
    },
    perplexity = {
        ["sonar-pro"] = 8192,
    },
}

--- MAX INPUT tokens per model, for the model-aware extraction pre-check.
--- Full cited table (research campaign T2, 2026-08-14 — evidence per line:
--- [probe] = live first-party API call, [docs] = provider's own docs page,
--- [OR] = OpenRouter catalog, [inferred] = arithmetic on two documented
--- numbers). Values are the documented MAXIMUM INPUT where the provider
--- states one (OpenAI does — input alone above it is an immediate 400);
--- elsewhere the single documented context number, with the caller's 0.9
--- headroom covering the output reservation. Absent entry = fail-open (no
--- pre-check claim; the provider error + item-27 self-heal remain the
--- backstop) — ollama (user-set num_ctx) and the community providers are
--- deliberately absent. Longest-prefix matched, same tie-break discipline
--- as _max_output_tokens above.
ModelConstraints._context_windows = {
    anthropic = {
        -- 1M is the no-beta-header DEFAULT on every 1M Claude model at
        -- standard pricing (context-windows docs page, 2026-08-14); only
        -- Haiku 4.5 stays 200K. The old ["claude"]=200000-for-everything
        -- rationale ("1M needs a beta header we do not send") is obsolete.
        ["claude-sonnet-5"]   = 1000000, -- [docs] 1M list; [OR] agrees
        ["claude-opus-5"]     = 1000000, -- [docs]
        ["claude-fable-5"]    = 1000000, -- [docs]
        ["claude-sonnet-4-6"] = 1000000, -- [docs]; [OR] agrees
        ["claude-opus-4-8"]   = 1000000, -- [docs]; [OR] agrees
        ["claude-haiku-4-5"]  = 200000,  -- [docs] models overview; [OR] agrees
        -- Conservative family floor for uncurated claude-* ids: a future 1M
        -- model loses a little scope headroom; a 200K model wrongly called 1M
        -- would 400 in the field.
        ["claude"]            = 200000,  -- [docs] "Other Claude models"
    },
    openai = {
        -- OpenAI documents max INPUT separately from the 1,050,000 window;
        -- input is the load-bearing number. 922,000 stated verbatim on the
        -- 5.6 pages; 5.5/5.4 [inferred] window-minus-output reproduces the
        -- stated max input on every page that carries one.
        ["gpt-5.6"]      = 922000,  -- [docs] "Maximum input tokens: 922,000"
        ["gpt-5.5"]      = 922000,  -- [inferred]
        ["gpt-5.4"]      = 922000,  -- [inferred]
        ["gpt-5.4-mini"] = 272000,  -- [docs] 400K window / 272K max input
        ["gpt-5.4-nano"] = 272000,  -- [docs]
        -- Guards for ids a "Fetch models" run can surface (not curated):
        ["gpt-4.1"]      = 1000000, -- [docs] 1M context family
        ["gpt-4o"]       = 128000,  -- [docs]
    },
    -- openai_codex aliased below (same hosted models, same slugs)
    deepseek = {
        ["deepseek-v4"] = 1000000,  -- [docs] pricing table: 1M for v4-pro AND v4-flash; [OR] 1048576
    },
    gemini = {
        ["gemini-3"]   = 1048576,   -- [probe] models-endpoint inputTokenLimit, all curated 3.x ids
        ["gemini-2.5"] = 1048576,   -- [probe] 2.5-flash / -pro / -flash-lite
    },
    mistral = {
        -- [probe] GET /v1/models field max_context_length, 2026-08-14.
        ["mistral-large"]   = 262144,
        ["mistral-medium"]  = 262144, -- ([OR]'s 131072 is the older pinned -3.1 snapshot, not -latest)
        ["mistral-small"]   = 262144,
        ["magistral-small"] = 262144,
        ["ministral-14b"]   = 262144,
        ["ministral-8b"]    = 262144,
        ["ministral-3b"]    = 131072, -- [probe] genuinely half its siblings (-latest and -2512 both)
        ["codestral"]       = 256000,
        -- magistral-medium-latest: NO entry on purpose — absent from the live
        -- /v1/models listing (delisted-but-served, verified 2026-08-14);
        -- fail-open until the curated id's fate is decided.
    },
    xai = {
        -- [probe] GET /v1/models field context_length, 2026-08-14. Also
        -- adjudicates grok-4.20: xAI's own API says 1M ([OR]'s 2M rejected).
        ["grok-4.6"]   = 500000,
        ["grok-4.5"]   = 500000,
        ["grok-4.3"]   = 1000000,
        ["grok-4.20"]  = 1000000,
        ["grok-build"] = 256000,
    },
    zai = {
        -- [docs] per-model pages (the /models listing carries no metadata).
        ["glm-5.2"] = 1000000,      -- 1M context (5x jump from 5.1)
        ["glm-5"]   = 200000,       -- glm-5 / 5.1 / 5-turbo
        ["glm-4.7"] = 200000,       -- covers glm-4.7-flash
    },
    perplexity = {
        ["sonar-pro"]           = 200000, -- [docs]; [OR] agrees
        ["sonar-reasoning-pro"] = 128000, -- [docs]
        ["sonar-deep-research"] = 128000, -- [docs]
        ["sonar"]               = 127072, -- [OR] exact value (docs round to "128K"; smaller = safer)
    },
    openrouter = {
        -- [OR] live catalog 2026-08-14 (all 31 curated mirror ids resolved).
        -- OpenAI mirrors use OpenAI's documented max INPUT, not [OR]'s window,
        -- so both routes to the same model agree.
        ["anthropic/claude-sonnet-5"]   = 1000000,
        ["anthropic/claude-opus-5"]     = 1000000,
        ["anthropic/claude-fable-5"]    = 1000000,
        ["anthropic/claude-sonnet-4.6"] = 1000000,
        ["anthropic/claude-opus-4.8"]   = 1000000,
        ["anthropic/claude-haiku-4.5"]  = 200000,
        ["openai/gpt-5.6"]              = 922000,
        ["openai/gpt-5.5"]              = 922000,
        ["openai/gpt-5.4"]              = 922000,
        ["openai/gpt-5.4-mini"]         = 272000,
        ["openai/gpt-oss"]              = 131072,
        ["google/gemini-3"]             = 1048576,
        ["deepseek/deepseek-v4"]        = 1000000,
        ["x-ai/grok-4.3"]               = 1000000,
        ["x-ai/grok-4.20"]              = 1000000, -- [probe] xAI's own API; [OR]'s 2M rejected
        ["meta-llama/llama-3.3-70b-instruct"] = 131072,
        ["mistralai/mistral-large-2512"]      = 262144,
        ["mistralai/mistral-medium-3.1"]      = 131072, -- this pinned snapshot IS 131072, unlike -latest
        ["qwen/qwen3-max"]              = 262144,
        ["qwen/qwen3-235b-a22b"]        = 131072,
        ["perplexity/sonar-pro"]        = 200000,
        ["perplexity/sonar-reasoning-pro"] = 128000,
        ["perplexity/sonar"]            = 127072,
        ["moonshotai/kimi-k2-thinking"] = 262144,
        ["minimax/minimax-m2.1"]        = 204800,
    },
}

--- Conservative context-window pre-check (fail-open). Returns nil when the
--- model's input window is unknown (or chars is empty) — callers must treat
--- nil as "no claim", never as "fits". Otherwise returns exceeded (boolean),
--- window_tokens, est_tokens. The estimate is the LOW bound (chars/4 —
--- English-dense; non-Latin scripts run far denser, measured down to ~1.1
--- chars/token for vocalized Arabic on the new Claude tokenizer — T2 ratio
--- table in docs/research/2026-08-14/ if a family-aware estimator is ever
--- wanted) so a warning is only raised for
--- requests that exceed the window under the most favorable tokenization:
--- fewer false alarms, and true overflows still self-report via the provider
--- error. The 0.9 factor leaves headroom for prompt scaffolding + output.
function ModelConstraints.checkContextWindow(provider, model, chars)
    local provider_windows = ModelConstraints._context_windows[provider]
    if not provider_windows or not model or not chars or chars <= 0 then return nil end
    local best, best_len
    for win_model, win_val in pairs(provider_windows) do
        if model == win_model
                or model:match("^" .. win_model:gsub("[%^%$%(%)%%%.%[%]%*%+%-%?]", "%%%1")) then
            if not best_len or #win_model > best_len then
                best, best_len = win_val, #win_model
            end
        end
    end
    if not best then return nil end
    local est_tokens = math.floor(chars / 4)
    return est_tokens >= math.floor(best * 0.9), best, est_tokens
end

-- Default values for reasoning/thinking settings
-- Use these instead of hardcoding values throughout the codebase
ModelConstraints.reasoning_defaults = {
    -- Anthropic adaptive thinking (4.6+)
    anthropic_adaptive = {
        effort = "high",     -- Default effort level
        effort_options = { "low", "medium", "high" },  -- Common options (Sonnet)
        effort_options_opus = { "low", "medium", "high", "xhigh", "max" },  -- Opus (4.7+ adds xhigh)
    },
    -- Anthropic extended thinking (manual budget mode)
    anthropic = {
        budget = 32000,      -- Default budget_tokens (max cap, model uses what it needs)
        budget_min = 1024,   -- Minimum allowed
        budget_max = 32000,  -- Maximum allowed
        budget_step = 1024,  -- SpinWidget step
    },
    -- OpenAI reasoning effort (for gated models: 5.1+)
    openai = {
        effort = "medium",   -- Default effort level
        effort_options = { "low", "medium", "high", "xhigh" },
    },
    -- Gemini thinking level (Gemini 3)
    gemini = {
        level = "high",      -- Default thinking level
        level_options = { "low", "medium", "high" },  -- Common options
        level_options_flash = { "minimal", "low", "medium", "high" },  -- Flash-specific
        -- Gemini 2.5 thinking budget (named levels -> numeric values)
        budget = "dynamic",  -- Default budget setting
        budget_map = {
            dynamic = -1,    -- Model decides how much to think
            low = 1024,
            medium = 8192,
            high = 16384,
            max = 24576,
        },
    },
    -- Effort-based providers
    openrouter = {
        effort = "high",
        effort_options = { "low", "medium", "high" },
    },
    requesty = {
        effort = "high",
        effort_options = { "low", "medium", "high" },
    },
    groq = {
        effort = "high",
        effort_options = { "low", "medium", "high" },
    },
    together = {
        effort = "high",
        effort_options = { "low", "medium", "high" },
    },
    fireworks = {
        effort = "high",
        effort_options = { "low", "medium", "high" },
    },
    xai = {
        effort = "high",
        effort_options = { "low", "medium", "high" },
    },
    perplexity = {
        effort = "high",
        effort_options = { "low", "medium", "high" },
    },
}

-- Per-model reasoning PROFILES — the single source of truth for the reasoning
-- RESOLVER (resolveReasoning): each model's reasoning nature and how it responds
-- to the global stance / per-provider+model preferences / per-action overrides.
--
-- NOTE: model membership here must stay in sync with ModelConstraints.capabilities
-- above, which backs supportsCapability() gating used by the provider request
-- builders. When adding/removing a model, update BOTH.
--
-- Fields:
--   match          prefix-matched model id (same matching as supportsCapability)
--   axis           "none"|"binary"|"effort"|"budget"|"adaptive_effort"
--   default_state  "on"|"off" — natural behavior when NO reasoning param is sent
--   can_disable    can reasoning be turned fully off?
--   can_enable     can reasoning be turned on when off by default?
--   options        ordered levels: effort labels (effort/adaptive) or budget keys (budget)
--   default_option level used for "on" without an explicit choice
--   off_option     effort axis only: explicit "off" value to send (e.g. xAI "none")
--   stance_map     { minimal = {state=,option=}, maximum = {state=,option=} } (data-driven)
--   needs_temp_1   builder must force temperature=1.0 when reasoning on (informational)
--   needs_no_sampling builder strips all sampling params (Opus 4.7/4.8)
--   budget_map     budget axis only: option key -> numeric budget
ModelConstraints.reasoning_profiles = {
    anthropic = {
        -- Fable 5: frontier model. Adaptive thinking is ALWAYS ON (thinking.type:disabled is
        -- rejected — verified 2026-07-24), rejects sampling params, full effort ladder incl.
        -- xhigh/max (max accepted). can_disable=false → minimal stance drops to lowest effort,
        -- not off. default_state="on" also triggers the display=summarized carve-out.
        { match = "claude-fable-5", axis = "adaptive_effort", default_state = "on",
          can_disable = false, can_enable = true,
          options = { "low", "medium", "high", "xhigh", "max" }, default_option = "high",
          stance_map = { minimal = { option = "low" }, maximum = { state = "on", option = "max" } },
          needs_no_sampling = true },
        -- Opus 5: deep-reasoning flagship (2026-07-24, $5/$25). Same shape as Sonnet 5
        -- (probed 2026-07-25): adaptive thinking ON at the API default (thinking block
        -- returned with nothing sent), disable accepted, rejects sampling ("temperature
        -- is deprecated for this model"), full effort ladder incl. xhigh/max (both
        -- verified), budget mode rejected. default_state="on" also triggers the
        -- display=summarized carve-out in anthropic_request.lua.
        { match = "claude-opus-5", axis = "adaptive_effort", default_state = "on",
          can_disable = true, can_enable = true,
          options = { "low", "medium", "high", "xhigh", "max" }, default_option = "high",
          stance_map = { minimal = { state = "off" }, maximum = { state = "on", option = "max" } },
          needs_no_sampling = true },
        -- Opus 4.8 / 4.7: adaptive-only, reject sampling params, default off (we only
        -- think when `thinking` is sent), full Opus effort ladder incl. xhigh/max.
        { match = "claude-opus-4-8", axis = "adaptive_effort", default_state = "off",
          can_disable = true, can_enable = true,
          options = { "low", "medium", "high", "xhigh", "max" }, default_option = "high",
          stance_map = { minimal = { state = "off" }, maximum = { state = "on", option = "max" } },
          needs_no_sampling = true },
        { match = "claude-opus-4-7", axis = "adaptive_effort", default_state = "off",
          can_disable = true, can_enable = true,
          options = { "low", "medium", "high", "xhigh", "max" }, default_option = "high",
          stance_map = { minimal = { state = "off" }, maximum = { state = "on", option = "max" } },
          needs_no_sampling = true },
        -- Opus 4.6: adaptive, full effort ladder, requires temp=1.0 when on.
        { match = "claude-opus-4-6", axis = "adaptive_effort", default_state = "off",
          can_disable = true, can_enable = true,
          options = { "low", "medium", "high", "xhigh", "max" }, default_option = "high",
          stance_map = { minimal = { state = "off" }, maximum = { state = "on", option = "max" } },
          needs_temp_1 = true },
        -- Sonnet 5: adaptive-only, rejects sampling params, full effort ladder incl.
        -- xhigh/max. Unlike the Opus family, adaptive thinking is ON at the API default
        -- (omitting `thinking` runs adaptive) → default_state = "on"; disable is accepted.
        { match = "claude-sonnet-5", axis = "adaptive_effort", default_state = "on",
          can_disable = true, can_enable = true,
          options = { "low", "medium", "high", "xhigh", "max" }, default_option = "high",
          stance_map = { minimal = { state = "off" }, maximum = { state = "on", option = "max" } },
          needs_no_sampling = true },
        -- Sonnet 4.6: adaptive (preferred over legacy budget mode), low/medium/high.
        { match = "claude-sonnet-4-6", axis = "adaptive_effort", default_state = "off",
          can_disable = true, can_enable = true,
          options = { "low", "medium", "high" }, default_option = "high",
          stance_map = { minimal = { state = "off" }, maximum = { state = "on", option = "high" } },
          needs_temp_1 = true },
        -- Haiku 4.5: extended thinking (manual budget) only, requires temp=1.0 when on.
        { match = "claude-haiku-4-5", axis = "budget", default_state = "off",
          can_disable = true, can_enable = true,
          options = { "low", "medium", "high", "max" }, default_option = "high",
          budget_map = { low = 8000, medium = 16000, high = 24000, max = 32000 },
          stance_map = { minimal = { state = "off" }, maximum = { state = "on", option = "max" } },
          needs_temp_1 = true },
    },
    openai = {
        -- GPT-5.6 (luna/sol/terra): gated — reasoning OFF by default (verified 0 reasoning
        -- tokens with nothing sent, 2026-07-24). Opt-in effort none..xhigh (NO max — rejected).
        { match = "gpt-5.6", axis = "effort", default_state = "off",
          can_disable = true, can_enable = true,
          options = { "low", "medium", "high", "xhigh" }, default_option = "medium",
          stance_map = { minimal = { state = "off" }, maximum = { state = "on", option = "xhigh" } } },
        -- GPT-5.5: reasons by default (medium), cannot be fully disabled.
        { match = "gpt-5.5", axis = "effort", default_state = "on",
          can_disable = false, can_enable = true,
          options = { "low", "medium", "high" }, default_option = "medium",
          stance_map = { minimal = { option = "low" }, maximum = { option = "high" } } },
        -- GPT-5.4 family: gated (off by default), opt-in effort incl. xhigh.
        { match = "gpt-5.4", axis = "effort", default_state = "off",
          can_disable = true, can_enable = true,
          options = { "low", "medium", "high", "xhigh" }, default_option = "medium",
          stance_map = { minimal = { state = "off" }, maximum = { state = "on", option = "xhigh" } } },
        -- FAMILY FALLBACK (item 19a): a brand-new gpt-5.x minor inherits a
        -- conservative gated profile (off by default, no xhigh/max guesses) until
        -- probed/curated; custom_models.lua corrects if it differs.
        { match = "gpt-5", axis = "effort", default_state = "off",
          can_disable = true, can_enable = true,
          options = { "low", "medium", "high" }, default_option = "medium",
          stance_map = { minimal = { state = "off" }, maximum = { state = "on", option = "high" } } },
    },
    deepseek = {
        { match = "deepseek-v4-pro", axis = "binary", default_state = "on",
          can_disable = true, can_enable = true,
          stance_map = { minimal = { state = "off" }, maximum = { state = "on" } } },
        { match = "deepseek-v4-flash", axis = "binary", default_state = "on",
          can_disable = true, can_enable = true,
          stance_map = { minimal = { state = "off" }, maximum = { state = "on" } } },
        -- FAMILY FALLBACK (item 19a): the binary thinking toggle is universal since V3.2.
        { match = "deepseek", axis = "binary", default_state = "on",
          can_disable = true, can_enable = true,
          stance_map = { minimal = { state = "off" }, maximum = { state = "on" } } },
    },
    gemini = {
        -- Gemini 3 (thinkingLevel). Pro has no "minimal" floor; flash variants do.
        { match = "gemini-3.1-pro-preview", axis = "effort", default_state = "on",
          can_disable = false, can_enable = true,
          options = { "low", "medium", "high" }, default_option = "high",
          stance_map = { minimal = { option = "low" }, maximum = { option = "high" } } },
        -- gemini-3.7-flash (full free-key battery 2026-08-15): pro-shaped, NOT a 3.6
        -- mirror — thinkingLevel MINIMAL is REJECTED ("not supported for this model");
        -- low/medium/high probed OK, default thinking ON (362 thought tokens bare),
        -- temp free, tools + gather/final modes + replay + SSE all green.
        { match = "gemini-3.7-flash", axis = "effort", default_state = "on",
          can_disable = false, can_enable = true,
          options = { "low", "medium", "high" }, default_option = "high",
          stance_map = { minimal = { option = "low" }, maximum = { option = "high" } } },
        -- gemini-3.6-flash mirrors the 3.5-flash effort profile.
        -- flash-lite MUST precede gemini-3.5-flash (prefix match: "gemini-3.5-flash" would
        -- otherwise swallow "gemini-3.5-flash-lite").
        -- flash-lite variants do NOT think by default (probed 2026-07-25 via model_audit:
        -- bare math prompt → thoughtsTokenCount=0 on 3.5-flash-lite AND 3.1-flash-lite,
        -- vs 729 on 3.5-flash — the earlier "mirrors flash exactly" note was wrong about
        -- the default). Effort levels still work; gated shape like gpt-5.6.
        { match = "gemini-3.6-flash", axis = "effort", default_state = "on",
          can_disable = false, can_enable = true,
          options = { "minimal", "low", "medium", "high" }, default_option = "high",
          stance_map = { minimal = { option = "minimal" }, maximum = { option = "high" } } },
        { match = "gemini-3.5-flash-lite", axis = "effort", default_state = "off",
          can_disable = true, can_enable = true,
          options = { "minimal", "low", "medium", "high" }, default_option = "high",
          stance_map = { minimal = { state = "off" }, maximum = { state = "on", option = "high" } } },
        { match = "gemini-3.5-flash", axis = "effort", default_state = "on",
          can_disable = false, can_enable = true,
          options = { "minimal", "low", "medium", "high" }, default_option = "high",
          stance_map = { minimal = { option = "minimal" }, maximum = { option = "high" } } },
        { match = "gemini-3.1-flash-lite", axis = "effort", default_state = "off",
          can_disable = true, can_enable = true,
          options = { "minimal", "low", "medium", "high" }, default_option = "high",
          stance_map = { minimal = { state = "off" }, maximum = { state = "on", option = "high" } } },
        -- Gemini 2.5 (thinkingBudget): flash/pro think by default (dynamic), can
        -- disable via 0. flash-lite is OFF by default (Google docs + live recheck
        -- 2026-08-14: 0 thought tokens on the math prompt — same class as the
        -- 3.5/3.1 lite correction of 2026-07-25); thinking opt-in via budget.
        -- flash-lite listed before flash so the more-specific id matches first.
        { match = "gemini-2.5-flash-lite", axis = "budget", default_state = "off",
          can_disable = true, can_enable = true,
          options = { "dynamic", "low", "medium", "high", "max" }, default_option = "dynamic",
          budget_map = { dynamic = -1, low = 1024, medium = 8192, high = 16384, max = 24576 },
          stance_map = { minimal = { state = "off" }, maximum = { state = "on", option = "max" } } },
        { match = "gemini-2.5-pro", axis = "budget", default_state = "on",
          can_disable = true, can_enable = true,
          options = { "dynamic", "low", "medium", "high", "max" }, default_option = "dynamic",
          budget_map = { dynamic = -1, low = 1024, medium = 8192, high = 16384, max = 24576 },
          stance_map = { minimal = { state = "off" }, maximum = { state = "on", option = "max" } } },
        { match = "gemini-2.5-flash", axis = "budget", default_state = "on",
          can_disable = true, can_enable = true,
          options = { "dynamic", "low", "medium", "high", "max" }, default_option = "dynamic",
          budget_map = { dynamic = -1, low = 1024, medium = 8192, high = 16384, max = 24576 },
          stance_map = { minimal = { state = "off" }, maximum = { state = "on", option = "max" } } },
        -- FAMILY FALLBACK (item 19a): a new gemini-3.x id inherits the effort
        -- profile with the option subset both pro and flash accept (no "minimal" —
        -- pro rejects it).
        { match = "gemini-3", axis = "effort", default_state = "on",
          can_disable = false, can_enable = true,
          options = { "low", "medium", "high" }, default_option = "high",
          stance_map = { minimal = { option = "low" }, maximum = { option = "high" } } },
    },
    zai = {
        -- GLM-4.5+: thinking on by default, disableable; temp must be 1.0 when on.
        -- glm-5.2 first so it wins over the generic "glm-5" prefix below.
        { match = "glm-5.2", axis = "binary", default_state = "on", can_disable = true, can_enable = true,
          needs_temp_1 = true, stance_map = { minimal = { state = "off" }, maximum = { state = "on" } } },
        { match = "glm-5.1", axis = "binary", default_state = "on", can_disable = true, can_enable = true,
          needs_temp_1 = true, stance_map = { minimal = { state = "off" }, maximum = { state = "on" } } },
        { match = "glm-5-turbo", axis = "binary", default_state = "on", can_disable = true, can_enable = true,
          needs_temp_1 = true, stance_map = { minimal = { state = "off" }, maximum = { state = "on" } } },
        { match = "glm-5", axis = "binary", default_state = "on", can_disable = true, can_enable = true,
          needs_temp_1 = true, stance_map = { minimal = { state = "off" }, maximum = { state = "on" } } },
        { match = "glm-4.7", axis = "binary", default_state = "on", can_disable = true, can_enable = true,
          needs_temp_1 = true, stance_map = { minimal = { state = "off" }, maximum = { state = "on" } } },
        { match = "glm-4.7-flash", axis = "binary", default_state = "on", can_disable = true, can_enable = true,
          needs_temp_1 = true, stance_map = { minimal = { state = "off" }, maximum = { state = "on" } } },
        -- (No bare "glm" family fallback — pre-4.5 ids like glm-4-plus don't think;
        -- "glm-5" above already covers 5.x minors.)
    },
    sambanova = {
        { match = "DeepSeek-V3.1", axis = "binary", default_state = "on", can_disable = true, can_enable = true,
          stance_map = { minimal = { state = "off" }, maximum = { state = "on" } } },
        { match = "DeepSeek-V3.2", axis = "binary", default_state = "on", can_disable = true, can_enable = true,
          stance_map = { minimal = { state = "off" }, maximum = { state = "on" } } },
    },
    kimi = {
        -- kimi-k2.6 international (probed 2026-08-15): thinks by DEFAULT
        -- (311 reasoning tokens bare), disable works via thinking
        -- {type="disabled"} (reasoning tokens → 1). The resolver emits the
        -- neutral kimi_thinking param only on an explicit OFF (on = the API
        -- default, nothing sent); kimi.lua translates + drops temperature.
        -- The China-only -thinking/-turbo ids deliberately get no profile
        -- (unknown/unprobeable) — they resolve to passthrough.
        { match = "kimi-k2.6", axis = "binary", default_state = "on", can_disable = true, can_enable = true,
          stance_map = { minimal = { state = "off" }, maximum = { state = "on" } } },
    },
    openrouter = {
        -- OpenRouter is a meta-provider: reasoning-disable support varies by backend, so
        -- families are matched before the catch-all (first match wins). Reasoning-MANDATORY
        -- backends reject reasoning.enabled=false (verified 2026-07-24: google/gemini-3* →
        -- "Reasoning is mandatory for this endpoint and cannot be disabled"; effort dial
        -- still works — low=284 vs high=816 reasoning tokens). These carry can_disable=false
        -- so the minimal stance resolves to lowest EFFORT, never an (illegal) hard off.
        { match = "google/gemini-3", axis = "effort", default_state = "on", can_disable = false, can_enable = true,
          options = { "low", "medium", "high" }, default_option = "high",
          stance_map = { minimal = { option = "low" }, maximum = { option = "high" } } },
        { match = "openai/gpt-5.5", axis = "effort", default_state = "on", can_disable = false, can_enable = true,
          options = { "low", "medium", "high" }, default_option = "medium",
          stance_map = { minimal = { option = "low" }, maximum = { option = "high" } } },
        -- Perplexity: ONLY sonar-reasoning* models reason; the plain sonar/sonar-pro
        -- rows below stop them falling through to the effort catch-all (their
        -- endpoints report no `reasoning` — a whole-vendor "perplexity/" prefix
        -- wrongly gave sonar-pro a reasoning dial; caught by model_audit 2026-07-25).
        { match = "perplexity/sonar-reasoning", axis = "effort", default_state = "on", can_disable = false, can_enable = true,
          options = { "low", "medium", "high" }, default_option = "high",
          stance_map = { minimal = { option = "low" }, maximum = { option = "high" } } },
        { match = "perplexity/", axis = "none" },
        -- Catch-all: disable-CAPABLE backends (deepseek, gpt-5.4/5.6, claude, glm, …).
        -- off emits reasoning.enabled=false (verified: deepseek/deepseek-v4-flash → 0 tokens).
        -- generic=true: derived metadata saying the backend model has NO reasoning
        -- (supported_parameters without "reasoning") downgrades this to passthrough.
        { match = "", generic = true, axis = "effort", default_state = "off", can_disable = true, can_enable = true,
          options = { "low", "medium", "high" }, default_option = "high",
          stance_map = { minimal = { state = "off" }, maximum = { state = "on", option = "high" } } },
    },
    requesty = {
        -- Same meta-provider caveat as openrouter (mirrors it; forwards to the same backends).
        { match = "google/gemini-3", axis = "effort", default_state = "on", can_disable = false, can_enable = true,
          options = { "low", "medium", "high" }, default_option = "high",
          stance_map = { minimal = { option = "low" }, maximum = { option = "high" } } },
        { match = "openai/gpt-5.5", axis = "effort", default_state = "on", can_disable = false, can_enable = true,
          options = { "low", "medium", "high" }, default_option = "medium",
          stance_map = { minimal = { option = "low" }, maximum = { option = "high" } } },
        -- Same sonar split as openrouter (requesty uses "perplexity/" ids too).
        { match = "perplexity/sonar-reasoning", axis = "effort", default_state = "on", can_disable = false, can_enable = true,
          options = { "low", "medium", "high" }, default_option = "high",
          stance_map = { minimal = { option = "low" }, maximum = { option = "high" } } },
        { match = "perplexity/", axis = "none" },
        { match = "", generic = true, axis = "effort", default_state = "off", can_disable = true, can_enable = true,
          options = { "low", "medium", "high" }, default_option = "high",
          stance_map = { minimal = { state = "off" }, maximum = { state = "on", option = "high" } } },
    },
    nvidia = {
        -- Probed 2026-08-20: on by default (reasoning_content present with no
        -- param), effort honoured, and reasoning_effort="none" fully disables.
        { match = "nvidia/nemotron-3", axis = "effort", default_state = "on", can_disable = true, can_enable = true,
          options = { "low", "medium", "high" }, default_option = "high", off_option = "none",
          stance_map = { minimal = { option = "low" }, maximum = { option = "high" } } },
    },
    groq = {
        { match = "openai/gpt-oss-120b", axis = "effort", default_state = "on", can_disable = false, can_enable = true,
          options = { "low", "medium", "high" }, default_option = "high",
          stance_map = { minimal = { option = "low" }, maximum = { option = "high" } } },
        { match = "openai/gpt-oss-20b", axis = "effort", default_state = "on", can_disable = false, can_enable = true,
          options = { "low", "medium", "high" }, default_option = "high",
          stance_map = { minimal = { option = "low" }, maximum = { option = "high" } } },
        { match = "qwen/qwen3-32b", axis = "effort", default_state = "on", can_disable = false, can_enable = true,
          options = { "low", "medium", "high" }, default_option = "high",
          stance_map = { minimal = { option = "low" }, maximum = { option = "high" } } },
    },
    together = {
        { match = "deepseek-ai/DeepSeek-V4-Pro", axis = "effort", default_state = "on", can_disable = false, can_enable = true,
          options = { "low", "medium", "high" }, default_option = "high",
          stance_map = { minimal = { option = "low" }, maximum = { option = "high" } } },
        { match = "Qwen/Qwen3.5-397B-A17B", axis = "effort", default_state = "on", can_disable = false, can_enable = true,
          options = { "low", "medium", "high" }, default_option = "high",
          stance_map = { minimal = { option = "low" }, maximum = { option = "high" } } },
        { match = "Qwen/Qwen3-235B-A22B", axis = "effort", default_state = "on", can_disable = false, can_enable = true,
          options = { "low", "medium", "high" }, default_option = "high",
          stance_map = { minimal = { option = "low" }, maximum = { option = "high" } } },
    },
    fireworks = {
        -- Probed live 2026-08-15 (all six serving ids): every model reasons by
        -- DEFAULT (reasoning_content present bare). The gpt-oss pair accepts
        -- effort low/medium/high ONLY ("none"/"xhigh"/"max" rejected at the
        -- model layer — cannot disable, same shape as groq's gpt-oss entries);
        -- every other model accepts none..max, so the generic catch-all below
        -- is disableable with the full ladder. Catch-all matches future
        -- fireworks ids too; generic=true yields to derived no-reasoning
        -- metadata should one turn up without reasoning.
        { match = "accounts/fireworks/models/gpt-oss", axis = "effort", default_state = "on", can_disable = false, can_enable = true,
          options = { "low", "medium", "high" }, default_option = "high",
          stance_map = { minimal = { option = "low" }, maximum = { option = "high" } } },
        { match = "accounts/fireworks/", axis = "effort", default_state = "on", can_disable = true, can_enable = true, generic = true,
          options = { "low", "medium", "high", "xhigh", "max" }, default_option = "high", off_option = "none",
          stance_map = { minimal = { state = "off" }, maximum = { state = "on", option = "max" } } },
    },
    xai = {
        -- grok-4.6 (probed 2026-08-14): reasons by default, effort "none" REJECTED
        -- (cannot disable — unlike 4.5/4.3, so the family fallback's off_option would
        -- 400 on the Minimal stance); ladder gains minimal + xhigh, "max" rejected.
        { match = "grok-4.6", axis = "effort", default_state = "on", can_disable = false, can_enable = true,
          options = { "minimal", "low", "medium", "high", "xhigh" }, default_option = "high",
          stance_map = { minimal = { state = "on", option = "minimal" }, maximum = { state = "on", option = "xhigh" } } },
        -- grok-4.5 / 4.3 / 4.20 reasoning: reasons by default, disableable via effort "none".
        { match = "grok-4.5", axis = "effort", default_state = "on", can_disable = true, can_enable = true,
          options = { "low", "medium", "high" }, default_option = "high", off_option = "none",
          stance_map = { minimal = { state = "off" }, maximum = { state = "on", option = "high" } } },
        { match = "grok-4.3", axis = "effort", default_state = "on", can_disable = true, can_enable = true,
          options = { "low", "medium", "high" }, default_option = "high", off_option = "none",
          stance_map = { minimal = { state = "off" }, maximum = { state = "on", option = "high" } } },
        { match = "grok-4.20-0309-reasoning", axis = "effort", default_state = "on", can_disable = true, can_enable = true,
          options = { "low", "medium", "high" }, default_option = "high", off_option = "none",
          stance_map = { minimal = { state = "off" }, maximum = { state = "on", option = "high" } } },
        -- Shim: the bare grok-4.20-0309 slug is NON-reasoning — must sit before the
        -- family fallback below or it would inherit an effort profile it rejects.
        { match = "grok-4.20-0309", axis = "none", default_state = "off",
          can_disable = false, can_enable = false },
        -- grok-build: thinks by default but rejects EVERY reasoningEffort value
        -- (probe 2026-08-14) — always-on with no knob, magistral-style shape.
        { match = "grok-build", axis = "none", default_state = "on",
          can_disable = false, can_enable = false },
        -- FAMILY FALLBACK (item 19a): new grok-4.x ids inherit the effort profile.
        { match = "grok-4", axis = "effort", default_state = "on", can_disable = true, can_enable = true,
          options = { "low", "medium", "high" }, default_option = "high", off_option = "none",
          stance_map = { minimal = { state = "off" }, maximum = { state = "on", option = "high" } } },
    },
    perplexity = {
        -- Always-on (web-grounded); effort only, cannot fully disable.
        { match = "sonar-reasoning-pro", axis = "effort", default_state = "on", can_disable = false, can_enable = true,
          options = { "low", "medium", "high" }, default_option = "high",
          stance_map = { minimal = { option = "low" }, maximum = { option = "high" } } },
        { match = "sonar-deep-research", axis = "effort", default_state = "on", can_disable = false, can_enable = true,
          options = { "low", "medium", "high" }, default_option = "high",
          stance_map = { minimal = { option = "low" }, maximum = { option = "high" } } },
        -- FAMILY FALLBACK (item 19a): covers bare sonar-reasoning + future variants.
        { match = "sonar-reasoning", axis = "effort", default_state = "on", can_disable = false, can_enable = true,
          options = { "low", "medium", "high" }, default_option = "high",
          stance_map = { minimal = { option = "low" }, maximum = { option = "high" } } },
    },
    mistral = {
        -- Magistral: always thinks, no control (extraction only).
        -- ("magistral" = family fallback, item 19a)
        { match = "magistral-medium", axis = "none", default_state = "on", can_disable = false, can_enable = false },
        { match = "magistral-small", axis = "none", default_state = "on", can_disable = false, can_enable = false },
        { match = "magistral", axis = "none", default_state = "on", can_disable = false, can_enable = false },
    },
}

-- SINGLE SOURCE OF TRUTH for web search support + UI gating.
-- To add a provider when web search is expanded, add ONE entry here — both
-- supportsWebSearch() and every "supported providers" label/help string update.
--   mode = "all"                  -> every model of this provider can search
--   mode = "capability:<name>"    -> only models with that capability (e.g. Gemini's google_search)
-- Mechanisms today: anthropic (web_search_20250305 tool), openrouter (:online / Exa),
-- perplexity (built-in Sonar, always on), gemini (googleSearch grounding, capable models),
-- OpenAI, OpenAI Subscription, and xAI use the web_search tool on their Responses
-- APIs (the handlers route web-on requests to their Responses endpoints; see
-- responses_api_plan.md), zai uses a web_search tool on the chat
-- wire — server-side search, results array echoed back; verified live 2026-07-25 on
-- glm-5.2 + glm-4.7-flash). Everything else has NO web search via the Chat Completions
-- API the plugin uses (probed 2026-07-25: deepseek rejects the tool type outright,
-- mistral's WebSearchTool connector is agents-API-only).
ModelConstraints._web_search_providers = {
    { id = "anthropic",  label = "Anthropic",  mode = "all" },
    { id = "gemini",     label = "Gemini",     mode = "capability:google_search" },
    { id = "openai",     label = "OpenAI",     mode = "capability:responses_web_search" },
    { id = "openai_codex", label = "OpenAI Subscription", mode = "capability:responses_web_search" },
    { id = "xai",        label = "xAI",        mode = "capability:responses_web_search" },
    { id = "perplexity", label = "Perplexity", mode = "all" },
    { id = "openrouter", label = "OpenRouter", mode = "all" },
    { id = "zai",        label = "Z.AI",       mode = "all" },
    -- DashScope enable_search: server-side search injection, probed 2026-08-15
    -- (no sources returned on the compatible-mode wire — grounded answers, no
    -- provenance). Wiring in qwen.lua.
    { id = "qwen",       label = "Qwen",       mode = "all" },
}

--- Check if a provider/model can actually perform web search in this plugin.
--- Single source of truth for UI gating (input dialog, chat viewer, quick settings).
--- @param provider string: Provider name
--- @param model string: Model name (only relevant for capability-gated providers, e.g. Gemini)
--- @return boolean: true if web search requests are honored
function ModelConstraints.supportsWebSearch(provider, model)
    if not provider then return false end
    for _, p in ipairs(ModelConstraints._web_search_providers) do
        if p.id == provider then
            if p.mode == "all" then return true end
            local cap = p.mode:match("^capability:(.+)$")
            if cap then
                return ModelConstraints.supportsCapability(provider, model, cap)
            end
            return false
        end
    end
    return false
end

--- Web search effort dial (report 3(a), 2026-07-12): one 3-level setting mapped to
--- provider-specific wire params by each request builder — Anthropic max_uses
--- (2/5/10), Perplexity + OpenAI Responses search_context_size (low/–/high;
--- standard sends nothing = API default), OpenRouter web-plugin max_results
--- (3/–/10; standard keeps the plain :online suffix). Gemini has no count
--- control (dial ignored).
--- @param features table|nil plugin features
--- @return string "light" | "standard" | "thorough" (nil/unknown → "standard")
function ModelConstraints.webSearchEffort(features)
    local effort = features and features.web_search_effort
    if effort == "light" or effort == "thorough" then
        return effort
    end
    return "standard"
end

--- Friendly, comma-joined list of providers that support web search.
--- Derived from _web_search_providers so UI strings stay in sync on expansion.
--- @return string e.g. "Anthropic, Gemini, OpenAI, Perplexity, OpenRouter"
function ModelConstraints.getWebSearchProvidersLabel()
    local labels = {}
    for _, p in ipairs(ModelConstraints._web_search_providers) do
        labels[#labels + 1] = p.label
    end
    return table.concat(labels, ", ")
end

--- Match a model id against a base pattern: exact, or prefix (for versioned/dated ids).
--- e.g. prefixMatch("claude-opus-4-8-20260115", "claude-opus-4-8") == true
--- @param model string|nil
--- @param pattern string|nil
--- @return boolean
local function prefixMatch(model, pattern)
    if not model or not pattern then return false end
    return model == pattern or model:match("^" .. pattern:gsub("%-", "%%-")) ~= nil
end

-- Capabilities that can be granted by derived provider metadata after a curated
-- miss, mapped to the wire-parameter name the metadata reports (OpenRouter
-- supported_parameters). Derived data never overrides a curated grant.
local DERIVED_PARAM_FOR_CAP = {
    tools = "tools",
}

--- The curated per-model constraint table for a provider (prefix-matched), e.g.
--- ModelConstraints.openai["gpt-5.6"] = { temperature = 1.0 }. Shared by apply()
--- and temperatureSupport() so the UI can never disagree with the wire.
--- @return table|nil
local function curatedConstraints(provider, model)
    if not provider or not model then return nil end
    for constraint_model, constraints in pairs(ModelConstraints[provider] or {}) do
        -- Skip special keys starting with _
        if type(constraint_model) == "string" and not constraint_model:match("^_")
            and prefixMatch(model, constraint_model) then
            return constraints
        end
    end
    return nil
end

--- Check if a model supports a specific capability
--- Resolution: user override (grant/deny) → curated lists → derived metadata.
--- @param provider string: Provider name (e.g., "anthropic", "openai")
--- @param model string: Model name (e.g., "claude-sonnet-4-5-20250929")
--- @param capability string: Capability name (e.g., "extended_thinking", "reasoning")
--- @return boolean: true if model supports the capability
function ModelConstraints.supportsCapability(provider, model, capability)
    local override = ModelOverrides.capabilityOverride(provider, model, capability)
    if override ~= nil then
        return override
    end

    local caps = ModelConstraints.capabilities[provider]
    if caps and caps[capability] then
        for _, supported in ipairs(caps[capability]) do
            if prefixMatch(model, supported) then
                return true
            end
        end
    end

    local wire_param = DERIVED_PARAM_FOR_CAP[capability]
    if wire_param then
        local derived = ModelOverrides.derivedParam(provider, model, wire_param)
        if derived ~= nil then
            return derived
        end
    end

    return false
end

--- Get all capabilities for a provider
--- @param provider string: Provider name
--- @return table: Map of capability name -> list of supported models
function ModelConstraints.getProviderCapabilities(provider)
    return ModelConstraints.capabilities[provider] or {}
end

--- How does this provider/model treat a user-set temperature? (item 19c)
--- Built entirely on data that ALREADY drives the wire — the `no_sampling_params`
--- capability (which anthropic_request.lua consults before deleting temperature) and
--- the curated/user constraint tables apply() enforces — so the UI cannot drift from
--- what actually gets sent. Deliberately NOT a `supportsCapability` capability:
--- that returns false on a miss, and "honors temperature" must default to true.
---
--- STATIC per (provider, model). The reasoning-conditional temp=1.0 rule is reported
--- separately as info.temp_1_when_reasoning and must not be treated as a rejection:
--- those models honor temperature whenever reasoning is off.
---
--- KNOWN GAP: apply() runs only for openai and anthropic (openai_compatible.lua calls
--- clampMaxTokens only), so a temperature constraint declared in custom_models.lua for
--- some OTHER provider is reported "forced" here but never actually applied to the
--- request. That is a hole in the apply path, not in this predicate — reporting the
--- declared data is the honest answer, and special-casing providers here would just
--- move the inconsistency somewhere harder to find.
--- @param provider string|nil
--- @param model string|nil
--- @return string mode  "rejected" (stripped) | "forced" (pinned) | "free"
--- @return table info   { value = number|nil, max = number|nil, temp_1_when_reasoning = boolean }
function ModelConstraints.temperatureSupport(provider, model)
    local info = { temp_1_when_reasoning = false }
    if not provider or not model then return "free", info end

    if ModelConstraints.supportsCapability(provider, model, "no_sampling_params") then
        return "rejected", info
    end

    -- User constraints win over curated ones (apply() writes them last)
    local user = ModelOverrides.constraintsFor(provider, model)
    local curated = curatedConstraints(provider, model)
    local pinned = (user and user.temperature) or (curated and curated.temperature)
    if pinned ~= nil then
        info.value = pinned
        return "forced", info
    end

    local provider_constraints = ModelConstraints[provider]
    info.max = provider_constraints and provider_constraints._provider_max_temperature or nil
    local profile = ModelConstraints.getReasoningProfile(provider, model)
    info.temp_1_when_reasoning = (profile and profile.needs_temp_1) == true
    return "free", info
end

--- Apply model constraints to request parameters
--- @param provider string: Provider name (e.g., "openai", "anthropic")
--- @param model string: Model name (e.g., "gpt-5-mini")
--- @param params table: Request parameters (temperature, max_tokens, etc.)
--- @return table: Modified params
--- @return table: Adjustments made { param = { from = old, to = new, reason = optional } }
function ModelConstraints.apply(provider, model, params)
    local adjustments = {}

    -- Check provider-level constraints
    local provider_constraints = ModelConstraints[provider]

    -- Model-specific constraints (prefix match for versioned models)
    -- e.g., "o3-mini" matches "o3-mini", "o3-mini-high", "o3-mini-2025-01-31"
    local model_constraints = curatedConstraints(provider, model)

    if model_constraints then
        for param, required_value in pairs(model_constraints) do
            if params[param] ~= nil and params[param] ~= required_value then
                adjustments[param] = { from = params[param], to = required_value }
                params[param] = required_value
            end
        end
    end

    -- User-declared constraints (custom_models.lua) — applied on top, so they also
    -- work for providers with no builtin table (custom providers) and can correct
    -- a builtin value.
    local user_constraints = ModelOverrides.constraintsFor(provider, model)
    if user_constraints then
        for param, required_value in pairs(user_constraints) do
            if params[param] ~= nil and params[param] ~= required_value then
                adjustments[param] = { from = params[param], to = required_value,
                    reason = "custom_models.lua" }
                params[param] = required_value
            end
        end
    end

    -- Check provider-level max temperature (e.g., Anthropic max 1.0)
    local max_temp = provider_constraints and provider_constraints._provider_max_temperature
    if max_temp and params.temperature and params.temperature > max_temp then
        adjustments.temperature = {
            from = params.temperature,
            to = max_temp,
            reason = "provider max"
        }
        params.temperature = max_temp
    end

    return params, adjustments
end

--- Print debug output for applied constraints
--- @param provider string: Provider name for log prefix
--- @param adjustments table: Adjustments from apply()
function ModelConstraints.logAdjustments(provider, adjustments)
    if not adjustments or not next(adjustments) then
        return
    end

    print(string.format("%s: Model constraints applied:", provider))
    for param, adj in pairs(adjustments) do
        if type(adj) == "table" then
            local reason_str = adj.reason and (" (" .. adj.reason .. ")") or ""
            print(string.format("  %s: %s -> %s%s",
                param,
                tostring(adj.from),
                tostring(adj.to),
                reason_str))
        else
            -- Scalar marker entries: a debug logger must never crash the request
            print(string.format("  %s: %s", param, tostring(adj)))
        end
    end
end

--- Known max-output ceiling for a model, or nil. Three layers:
---   user (custom_models.lua)  — explicit intent, corrects staleness either way
---   learned (derived cache)   — parsed from the provider's OWN max_tokens 400
---                               by the self-heal; empirical, so it beats a
---                               curated guess (a wrong curated value is exactly
---                               what produced the 400 it was learned from)
---   curated (_max_output_tokens below)
local function lookupMaxOutput(provider, model)
    local user_cap = ModelOverrides.maxOutputTokens(provider, model)
    if user_cap then return user_cap end

    local learned = ModelOverrides.derivedMaxOutput(provider, model)
    if learned then return learned end

    local provider_caps = ModelConstraints._max_output_tokens[provider]
    if not provider_caps or not model then return nil end

    -- LONGEST prefix wins. pairs() order is undefined, so a first-match return
    -- would pick nondeterministically whenever two keys both match one id
    -- (e.g. "gpt-5" and a future "gpt-5.4-mini" row) — and this table now sets
    -- DEFAULTS as well as clamps, so a wrong pick is a wrong request, not a
    -- harmless no-op. Mirrors the user-override layer's own tie-break.
    local best, best_len
    for cap_model, max_val in pairs(provider_caps) do
        -- Prefix match (e.g., "deepseek-chat" matches "deepseek-chat-v2").
        -- Escape every Lua pattern magic char, not just "-": an unescaped "."
        -- in a key like "gpt-4.1" or "gemini-2.5" matches ANY character there.
        if model == cap_model
                or model:match("^" .. cap_model:gsub("[%^%$%(%)%%%.%[%]%*%+%-%?]", "%%%1")) then
            if not best_len or #cap_model > best_len then
                best, best_len = max_val, #cap_model
            end
        end
    end
    return best
end

--- Clamp max_tokens to model-specific ceiling (if any)
--- Acts as a ceiling: values below the cap pass through unchanged.
--- @param provider string: Provider name (e.g., "deepseek", "groq")
--- @param model string: Model name (e.g., "deepseek-chat")
--- @param value number|nil: The max_tokens value to clamp
--- @return number|nil: Clamped value, or original if no cap applies
function ModelConstraints.clampMaxTokens(provider, model, value)
    if not value then return value end
    local ceiling = lookupMaxOutput(provider, model)
    if ceiling then return math.min(value, ceiling) end
    return value
end

-- Target request size when the model's output ceiling is known (item 27,
-- raise-where-known): generous enough that reasoning/thinking — which bills
-- against the same budget on every provider — can never starve the answer,
-- low enough to stay a runaway-cost backstop.
ModelConstraints.MAX_TOKENS_TARGET = 32768

--- Parse a provider 400 for a max_tokens/context-length rejection (item 27
--- self-heal). PURE — no IO, no state. Deliberately acts ONLY on errors where
--- the provider STATES its numbers: every real rejection format does (OpenAI
--- "supports at most N completion tokens", Anthropic "max_tokens: X > N",
--- Groq "must be less than or equal to N", vLLM's context sentence), and a
--- stated number beats blind halving — the retry lands exactly right, and a
--- misparse can never cache a wrong ceiling. An error that merely MENTIONS
--- max_tokens without numbers returns nil: no retry, no cache, no guessing.
--- @param err_text string|nil the error message as surfaced to the user
--- @return table|nil  { kind = "output_cap", cap = N }  — model's stated output
---                    limit; safe to CACHE and retry at
---                    { kind = "context", retry_at = N } — context overflow with
---                    computable completion room; retry ONCE, never cache (the
---                    number depends on this request's prompt length)
function ModelConstraints.parseMaxTokensError(err_text)
    if type(err_text) ~= "string" or err_text == "" then return nil end
    local sane = function(n) return n and n >= 1024 and n < 10000000 end

    -- vLLM-family context overflow (Novita, Featherless, local servers, ...):
    -- "This model's maximum context length is 12288 tokens. However, you
    --  requested 20480 tokens (8192 in the messages, 12288 in the completion)."
    -- Checked FIRST: it also contains completion-token numbers that the
    -- output-cap patterns below must never mistake for a model ceiling.
    local ctx = err_text:match("[Mm]aximum context length[^%d]*(%d+)")
        or err_text:match("context length of only (%d+)")
    if ctx then
        local limit = tonumber(ctx)
        local prompt = tonumber(err_text:match("(%d+)%s+in the messages")
            or err_text:match("(%d+)%s+tokens? in the messages"))
        if limit and prompt and limit > prompt then
            local room = limit - prompt - 256  -- margin for chat template overhead
            if room >= 1024 then
                return { kind = "context", retry_at = room }
            end
        end
        return nil  -- context overflow but no computable room: retrying can't help
    end

    -- Output-cap statements, most specific first. Each pattern anchors on
    -- wording that only appears in a max-output rejection.
    local cap = err_text:match("supports at most (%d+) completion tokens")            -- OpenAI
        or err_text:match("supports at most (%d+) output tokens")
        or err_text:match("max_tokens: %d+ > (%d+)")                                   -- Anthropic
        or err_text:match("max_tokens[^%d]-must be less than or equal to[^%d]*(%d+)")  -- Groq et al
        or err_text:match("max_completion_tokens[^%d]-must be less than or equal to[^%d]*(%d+)")
        or err_text:match("max_tokens[^%d]-cannot exceed[^%d]*(%d+)")
        or err_text:match("maximum allowed number of output tokens[^%d]*(%d+)")
        or err_text:match("[Mm]ax output tokens[^%d]-is[^%d]*(%d+)")
        or err_text:match("max_new_tokens[^%d]-must be[^%d]-at most[^%d]*(%d+)")       -- TGI-family
    local n = tonumber(cap)
    if sane(n) then
        return { kind = "output_cap", cap = n }
    end
    return nil
end

--- Persist a ceiling LEARNED from a provider's own rejection into the derived
--- caps cache, so every later request resolves right the first time. The
--- derived layer sits between the user layer and the curated table in
--- lookupMaxOutput — empirical beats curated guess, explicit user intent beats
--- both. Exact model id only (derived data is never prefix-matched).
function ModelConstraints.learnMaxOutput(provider, model, cap)
    if not (provider and model and type(cap) == "number") then return false end
    return ModelOverrides.recordDerivedMaxOutput(provider, model, cap)
end

--- Default max_tokens for a request that carries no explicit value (no action
--- pin, no user api_param). Raise-where-known: models with a KNOWN output
--- ceiling (custom_models.lua override or the curated table) get
--- min(MAX_TOKENS_TARGET, ceiling); unknown models keep the provider's
--- field-proven fallback, so missing curation degrades to today's behavior,
--- never to a 400.
--- @param provider string
--- @param model string|nil
--- @param fallback number: provider default (defaults.lua) for unknown models
--- @return number
function ModelConstraints.resolveMaxTokens(provider, model, fallback)
    local ceiling = lookupMaxOutput(provider, model)
    if ceiling then
        return math.min(ModelConstraints.MAX_TOKENS_TARGET, ceiling)
    end
    return fallback
end

-- Leading text of the Gemini-3 grounding tip. Shared so the generic rate-limit tip can
-- detect it and stay quiet — one error should never carry two tips saying the same thing.
local GROUNDING_TIP_HEAD = "Tip: This is a Google quota limit"

--- Append an actionable tip when a Gemini-3 request carrying web search (grounding)
--- or book tools (function calling) fails with a 429/quota error. Probed live
--- 2026-08-14 on a free-tier key (provider_landscape doc 7b): Gemini 3.x rejects
--- requests that include EITHER extra — googleSearch and functionDeclarations both
--- 429 while the same model answers plain requests, and both work on 2.5 models with
--- the same key. The gating quota is separate from the per-model daily request quota.
--- Paid tier VERIFIED to lift the gate 2026-08-15 (doc 7d): grounding + tools both
--- work on 3.6/3.7 with prepaid credits. Caveat folded into the tip: the 2.5 family
--- is locked for Google accounts created after ~mid-2026 ("no longer available to
--- new users", even paid), so the "use a 2.5 model" option only helps older keys.
--- Plain text (emoji don't render in MuPDF). Returns err_msg unchanged unless every
--- condition holds.
--- @param err_msg string: user-facing error message already built
--- @param provider string|nil: provider id
--- @param model string|nil: model id
--- @param config table|nil: unified request config (for web-search/tools gating)
--- @return string
function ModelConstraints.maybeAppendGemini3GroundingHint(err_msg, provider, model, config)
    if type(err_msg) ~= "string" or err_msg == "" then return err_msg end
    if provider ~= "gemini" then return err_msg end
    if not (model and model:match("^gemini%-3")) then return err_msg end
    -- web search enabled? per-action override > global (mirrors gemini.lua)
    local ws = false
    if config then
        if config.enable_web_search ~= nil then
            ws = config.enable_web_search
        elseif config.features and config.features.enable_web_search then
            ws = true
        end
    end
    -- book tools on this request? (the gather/tool-turn config carries the specs)
    local tools = config and type(config.tools) == "table"
        and type(config.tools.specs) == "table" and #config.tools.specs > 0
    if not (ws or tools) then return err_msg end
    local lowered = err_msg:lower()
    if not (lowered:find("429", 1, true)
            or lowered:find("resource_exhausted", 1, true)
            or lowered:find("quota", 1, true)) then
        return err_msg
    end
    return err_msg .. "\n\n" ..
        GROUNDING_TIP_HEAD .. ", not a plugin error. On free-tier keys, Gemini 3 models " ..
        "reject requests that include web search or book tools, even though plain requests " ..
        "work. Options: turn off web search and book tools for this chat, use a Gemini 2.5 " ..
        "model (works on free keys, but only for Google accounts old enough to still have " ..
        "the 2.5 models), switch to another provider, or add paid credits to your Gemini " ..
        "key in Google AI Studio (confirmed to lift this limit)."
end

--- Append an actionable tip when a request fails because the prompt (usually
--- extracted book text) is too large for the model/tier. Covers HTTP 413
--- ("request too large" / "payload too large") and HTTP 400 context_length_exceeded.
--- Free tiers — notably Groq — measure a single request against a tokens-per-minute
--- budget that is far smaller than the model's nominal context window, so this can
--- fire long before the context window is full. Plain text (emoji don't render in
--- MuPDF). Returns err_msg unchanged unless a size-limit signature matches. (issue #89)
--- @param err_msg string: user-facing error message already built
--- @param provider string|nil: provider id
--- @param model string|nil: model id
--- @param config table|nil: unified request config
--- @return string
function ModelConstraints.maybeAppendContextLimitHint(err_msg, provider, model, config)
    if type(err_msg) ~= "string" or err_msg == "" then return err_msg end
    local lowered = err_msg:lower()
    -- Match size/context signatures only — deliberately NOT a bare "400"/"413"
    -- (too generic; the reason-phrase text below covers the real cases).
    local is_size_error =
        lowered:find("payload too large", 1, true)
        or lowered:find("request entity too large", 1, true)
        or lowered:find("request too large", 1, true)
        or lowered:find("too large for model", 1, true)
        or lowered:find("context_length_exceeded", 1, true)
        or lowered:find("context length", 1, true)
        or lowered:find("reduce your message size", 1, true)
        or lowered:find("reduce the length of the messages", 1, true)
        or lowered:find("tokens per minute", 1, true)
    if not is_size_error then return err_msg end

    -- Per-minute admission refusal (docs/tpm_admission_plan.md): the plan's
    -- tokens-per-minute allowance could not admit prompt + requested answer
    -- budget. The old book-text tip was WRONG for this case (a 211-token
    -- dictionary lookup was told to lower "Max Text Characters"); say what
    -- actually happened, with the provider's own numbers.
    local RateLimits = require("koassistant_rate_limits")
    local refusal = RateLimits.parseRefusal(err_msg)
    if refusal then
        local who = (type(provider) == "string" and provider ~= "") and provider or "This provider"
        local text = "What happened: " .. who .. " counts the answer budget a request asks for " ..
            "(max_tokens) against your plan's tokens-per-minute allowance before running it. " ..
            "This request asked for " .. tostring(refusal.requested) .. " tokens in total against an " ..
            "allowance of " .. tostring(refusal.limit) .. ".\n"
        -- Which half was too big? The refusal names prompt + budget; the budget we
        -- sent is the pin or the resolver's default (same derivation as the router).
        local sent = (config and config.api_params and tonumber(config.api_params.max_tokens))
            or ModelConstraints.resolveMaxTokens(provider, model, nil)
        local prompt_tokens = RateLimits.promptTokensFromRefusal(refusal, sent)
        local budget_was_the_problem = prompt_tokens
            and (prompt_tokens + RateLimits.MARGIN + RateLimits.FLOOR) <= refusal.limit
        if budget_was_the_problem then
            text = text .. "KOAssistant resends such a request once with a smaller answer budget " ..
                "and remembers the allowance for this session. If you keep seeing this, wait a " ..
                "minute (the allowance refills) or pick a model or plan with a larger per-minute limit."
        else
            text = text .. "The request itself is larger than the allowance, so a smaller answer " ..
                "budget cannot help: use a smaller scope (a section, \"Up to current position\", " ..
                "or \"AI knowledge only\" where the action offers a source choice), or a plan/provider " ..
                "with a larger per-minute limit."
        end
        return err_msg .. "\n\n" .. text
    end

    local tip = "Tip: This request was too large for the selected model.\n" ..
        "Actions like X-Ray and Recap send the book's text, which can exceed a model's input limit. Options:\n" ..
        "- Choose \"AI knowledge only\" or a single section when the action offers a source choice.\n" ..
        "- Lower \"Max Text Characters\" (Settings → Text Extraction).\n" ..
        "- Switch to a model/provider with a larger context window."
    if provider == "groq" then
        tip = tip .. "\n\nNote: Groq's free tier limits tokens-per-minute (about 6K-12K) far below the " ..
            "model's context window, so large book text is rejected even on 128K-window models. " ..
            "A paid Groq tier or a larger-context provider avoids this."
    end
    return err_msg .. "\n\n" .. tip
end

--- Turn one google.rpc.QuotaFailure violation into a plain-language line.
--- quotaId is a CamelCase token ("GenerateRequestsPerDayPerProjectPerModel-FreeTier",
--- "GenerateContentInputTokensPerModelPerMinute-FreeTier"); decode the parts we can and
--- otherwise print it verbatim — a raw id the user can search for still beats no id.
--- @param v table: one entry of details[].violations
--- @return string|nil
local function describeQuotaViolation(v)
    local id = type(v.quotaId) == "string" and v.quotaId ~= "" and v.quotaId or nil
    local value = (type(v.quotaValue) == "string" or type(v.quotaValue) == "number")
        and tostring(v.quotaValue) or nil
    if not id and not value then return nil end

    local unit = id and ((id:find("InputToken") and "input tokens")
        or (id:find("Request") and "requests")) or nil
    local period = id and ((id:find("PerDay") and "per day")
        or (id:find("PerMinute") and "per minute")) or nil
    local tier = (id and id:find("FreeTier")) and " (free tier)" or ""

    local line
    if value and unit and period then
        line = "Limit reached: " .. value .. " " .. unit .. " " .. period .. tier
    elseif value and id then
        line = "Limit reached: " .. id .. " = " .. value
    else
        line = "Limit reached: " .. (id or value)
    end

    local dims = type(v.quotaDimensions) == "table" and v.quotaDimensions or nil
    local dim_model = dims and type(dims.model) == "string" and dims.model ~= "" and dims.model or nil
    if dim_model then
        line = line .. ", model " .. dim_model
    end
    return line .. "."
end

--- Extract the machine-readable quota facts from a Google-style error body.
--- A 429 body carries a details[] array — google.rpc.QuotaFailure violations (quotaId,
--- quotaValue, quotaDimensions.model) and google.rpc.RetryInfo (retryDelay) — naming the
--- EXACT bucket that was hit: per-day vs per-minute, requests vs input tokens, free tier
--- vs paid. error.message only ever says "You exceeded your current quota, please check
--- your plan and billing details", so on its own it can't distinguish a 30-second speed
--- bump from a 24-hour wall — or either from a plugin bug. We used to drop the array.
--- Shape-gated, not provider-gated: any backend answering in google.rpc form gets it.
--- Every field is type-checked — luajson decodes JSON null to a truthy sentinel.
--- @param decoded table|nil: decoded error response body
--- @return string|nil: lines to append to the user-facing message, nil if none
function ModelConstraints.formatQuotaDetails(decoded)
    if type(decoded) ~= "table" then return nil end
    local err = type(decoded.error) == "table" and decoded.error or nil
    local details = err and type(err.details) == "table" and err.details or nil
    if not details then return nil end

    local lines = {}
    for _idx, d in ipairs(details) do
        if type(d) == "table" then
            if type(d.violations) == "table" then
                for _vidx, v in ipairs(d.violations) do
                    if type(v) == "table" then
                        local line = describeQuotaViolation(v)
                        if line then table.insert(lines, line) end
                    end
                end
            end
            if type(d.retryDelay) == "string" and d.retryDelay ~= "" then
                table.insert(lines, "You can retry in " .. d.retryDelay .. ".")
            end
        end
    end
    if #lines == 0 then return nil end
    return table.concat(lines, "\n")
end

--- True when an error message looks like a provider rate/quota refusal (HTTP 429 in its
--- various wordings). Used for the tip below and to decide whether offering a retry at
--- the display sites makes sense — rate limits are the one failure class where "try
--- again" is the correct response.
--- @param err_msg string|nil
--- @return boolean
function ModelConstraints.isRateLimitError(err_msg)
    if type(err_msg) ~= "string" then return false end
    local l = err_msg:lower()
    return (l:find("429", 1, true)
        or l:find("resource_exhausted", 1, true)
        or l:find("quota", 1, true)
        or l:find("rate limit", 1, true)
        or l:find("rate_limit", 1, true)
        or l:find("too many requests", 1, true)
        -- Per-minute admission refusals (Groq sends them as HTTP 413): the
        -- allowance refills within a minute, so the persistent dialog with
        -- "Try again" is the right surface, not a 3-second toast.
        or l:find("tokens per min", 1, true)
        or l:find("(tpm)", 1, true)) and true or false
end

--- True when an error message looks like a provider overload/capacity refusal (HTTP 503
--- in its various wordings). Same "try again is the correct response" class as rate
--- limits — a 2026-08-15 device round got a high-demand 503 as a vanishing toast with
--- no retry button. Wordings mirror XrayAuto.classifyStopReason's overloaded class.
--- @param err_msg string|nil
--- @return boolean
function ModelConstraints.isOverloadError(err_msg)
    if type(err_msg) ~= "string" then return false end
    local l = err_msg:lower()
    return (l:find("503", 1, true)
        or l:find("overload", 1, true)
        or l:find("high demand", 1, true)
        or l:find("capacity", 1, true)
        or l:find("try again later", 1, true)) and true or false
end

--- Append a provider-neutral explanation of what a 429 actually means. Free-tier
--- allowances are counted PER MODEL, and per minute as well as per day — the part users
--- can't infer from "quota exceeded for your plan": the same key answers one action and
--- refuses the next, and picking a different model looks like it fixed the plugin.
--- Skipped when the more specific grounding tip already fired.
--- @param err_msg string: user-facing error message already built
--- @param provider string|nil: provider id
--- @param model string|nil: model id (unused; kept for signature parity with the other hints)
--- @param config table|nil: unified request config (unused; parity)
--- @return string
function ModelConstraints.maybeAppendRateLimitHint(err_msg, provider, model, config)
    if type(err_msg) ~= "string" or err_msg == "" then return err_msg end
    if not ModelConstraints.isRateLimitError(err_msg) then return err_msg end
    if err_msg:find(GROUNDING_TIP_HEAD, 1, true) then return err_msg end
    -- Admission refusals get their own explanation in maybeAppendContextLimitHint
    if require("koassistant_rate_limits").parseRefusal(err_msg) then return err_msg end
    local who = (type(provider) == "string" and provider ~= "") and provider or "the provider"
    return err_msg .. "\n\n" ..
        "Tip: this is " .. who .. "'s own rate limit, not a plugin error. These allowances are " ..
        "counted per model, and per minute as well as per day, so one API key can answer a " ..
        "request and refuse the next, and switching model can look like a fix. " ..
        "Options: wait and try again, pick a different model, or switch provider."
end

--- Prefix an API failure with the provider/model it came from. Failures used to arrive
--- context-free ("You exceeded your current quota"), so a user on a per-model limit
--- couldn't see WHICH model refused — the most common source of "is it me or the
--- plugin?" reports. No-ops when the prefix is already present (retries) or when there
--- is no provider to name.
--- @param err_msg string
--- @param provider string|nil
--- @param model string|nil
--- @return string
function ModelConstraints.prefixProviderModel(err_msg, provider, model)
    if type(err_msg) ~= "string" or err_msg == "" then return err_msg end
    if type(provider) ~= "string" or provider == "" then return err_msg end
    local label = (type(model) == "string" and model ~= "") and (provider .. "/" .. model) or provider
    if err_msg:sub(1, #label + 1) == label .. ":" then return err_msg end
    return label .. ": " .. err_msg
end

--- Single decoration point for API request failures: name the model, then append
--- whichever hints apply. The query sites call this instead of nesting maybeAppend*
--- calls, so a new hint is wired in one place.
--- @param err_msg string
--- @param provider string|nil
--- @param model string|nil
--- @param config table|nil: unified request config
--- @return string
function ModelConstraints.decorateRequestError(err_msg, provider, model, config)
    local out = ModelConstraints.prefixProviderModel(err_msg, provider, model)
    out = ModelConstraints.maybeAppendGemini3GroundingHint(out, provider, model, config)
    out = ModelConstraints.maybeAppendRateLimitHint(out, provider, model, config)
    out = ModelConstraints.maybeAppendContextLimitHint(out, provider, model, config)
    return out
end

--------------------------------------------------------------------------------
-- Reasoning resolution
--------------------------------------------------------------------------------

--- Look up the reasoning profile for a provider/model.
--- Resolution: user profile (custom_models.lua, first match) → builtin list (first
--- prefix match; a `generic = true` catch-all yields to derived metadata that says
--- the model has NO controllable reasoning) → synthetic passthrough for
--- unknown/custom models (axis="none" => resolver emits nothing => request untouched).
--- @param provider string|nil
--- @param model string|nil
--- @return table profile
function ModelConstraints.getReasoningProfile(provider, model)
    local user_profile = ModelOverrides.findProfile(provider, model)
    if user_profile then
        return user_profile
    end
    local list = provider and ModelConstraints.reasoning_profiles[provider]
    if list then
        for _, p in ipairs(list) do
            if prefixMatch(model, p.match) then
                if p.generic
                        and ModelOverrides.derivedParam(provider, model, "reasoning") == false then
                    break  -- meta-provider catch-all, but the backend model can't reason
                end
                return p
            end
        end
    end
    -- Passthrough for a model we do not recognize. `unknown` distinguishes it
    -- from a CURATED axis="none" entry (a model we know does not reason): the
    -- two look identical otherwise, but callers that must fail safe around
    -- reasoning need to tell "known not to reason" from "no idea".
    return {
        axis = "none",
        default_state = "off",
        can_disable = false,
        can_enable = false,
        unknown = true,
    }
end

-- Extract a {state, option} intent from a stored preference table, or nil if the
-- pref carries no reasoning fields (so resolution falls through to the next layer).
-- state="default" is the explicit "Model API default" sentinel: unlike nil (which
-- falls through to the stance layer), it pins this model to send_nothing.
local function prefDesired(pref)
    if not pref then return nil end
    if pref.state == "default" then
        return { api_default = true }
    end
    if pref.state ~= nil or pref.effort ~= nil or pref.budget ~= nil then
        return { state = pref.state, option = pref.effort or pref.budget }
    end
    return nil
end

--- Resolve the effective reasoning decision for a request.
--- Precedence (highest first):
---   action_override > session_override > model_pref > global_stance >
---   model natural default.
--- session_override is the one-shot per-chat layer (Quick controls chip —
--- controls_parity_plan.md §10): same shape as action_override, deliberately
--- BELOW it so actions with an explicit reasoning_config (quiz JSON contract
--- etc.) stay protected.
--- @param provider string
--- @param model string
--- @param layers table { global_stance="minimal"|"default"|"maximum",
---                       model_pref={state=,effort=,budget=}|nil,
---                       action_override={force="on"|"off", effort=, budget=}|nil,
---                       session_override={force="on"|"off", effort=, budget=}|nil }
--- @return table decision { mode="on"|"off", axis, effort, budget, send_nothing,
---                          needs_temp_1, needs_no_sampling, off_option, profile }
function ModelConstraints.resolveReasoning(provider, model, layers)
    layers = layers or {}
    local profile = ModelConstraints.getReasoningProfile(provider, model)
    local decision = {
        axis = profile.axis,
        profile = profile,
        needs_no_sampling = profile.needs_no_sampling or false,
        off_option = profile.off_option,
    }

    -- axis "none": no controllable reasoning. Report natural state, emit nothing.
    if profile.axis == "none" then
        decision.mode = (profile.default_state == "on") and "on" or "off"
        decision.send_nothing = true
        decision.needs_temp_1 = false
        return decision
    end

    -- 1. Resolve desired {state, option} by precedence (highest non-nil wins).
    local desired
    local ao = layers.action_override
    local so = layers.session_override
    if ao and ao.force == "off" then
        desired = { state = "off" }
    elseif ao and ao.force == "on" then
        desired = { state = "on", option = ao.effort or ao.budget }
    elseif so and so.force == "off" then
        desired = { state = "off" }
    elseif so and so.force == "on" then
        desired = { state = "on", option = so.effort or so.budget }
    else
        desired = prefDesired(layers.model_pref)
        if desired and desired.api_default then
            -- Explicit per-model "Model API default": resolve exactly like the
            -- "default" stance (emit nothing), SUPPRESSING the stance layer.
            desired = nil
        elseif not desired then
            local stance = layers.global_stance or "default"
            if stance == "minimal" then
                desired = profile.stance_map and profile.stance_map.minimal
            elseif stance == "maximum" then
                desired = profile.stance_map and profile.stance_map.maximum
            end
            -- "default" stance => desired stays nil => send_nothing (model behaves naturally)
        end
    end

    decision.send_nothing = (desired == nil)

    -- 2. Resolve concrete state, clamped to capability.
    local state = (desired and desired.state) or profile.default_state
    local clamped_from_off = false
    if state == "off" and not profile.can_disable then
        state = "on"
        clamped_from_off = true  -- can't truly disable (e.g. Perplexity, Mistral)
    end
    if state == "on" and not profile.can_enable and profile.default_state == "off" then
        state = "off"
    end
    decision.mode = state

    -- 3. Resolve option (effort level / budget). When we had to clamp "off" up to
    -- "on" (can't disable), prefer the lowest level rather than the default.
    local option = desired and desired.option
    if not option then
        if clamped_from_off and profile.options and profile.options[1] then
            option = profile.options[1]
        else
            option = profile.default_option
        end
    end

    decision.option = (type(option) == "string") and option or nil  -- resolved level name (for display)
    if profile.axis == "effort" or profile.axis == "adaptive_effort" then
        decision.effort = option
    elseif profile.axis == "budget" then
        if type(option) == "number" then
            decision.budget = option
        elseif type(option) == "string" and profile.budget_map and profile.budget_map[option] then
            decision.budget = profile.budget_map[option]
        elseif profile.budget_map and profile.default_option then
            decision.budget = profile.budget_map[profile.default_option]
        end
    end

    decision.needs_temp_1 = (profile.needs_temp_1 and state == "on") or false

    return decision
end

--- Parse a per-action reasoning override into a per-provider intent for the resolver.
--- Supports the new schema (string "off", { default=... }, per-provider table) and
--- the legacy fields (action.reasoning / action.extended_thinking + effort/budget).
--- @param action table|nil
--- @param provider string
--- @return table|nil  nil (inherit) | {force="off"} | {force="on", effort=, budget=}
function ModelConstraints.parseActionReasoning(action, provider)
    if not action then return nil end

    local rc = action.reasoning_config
    if rc ~= nil then
        if rc == "off" then return { force = "off" } end
        if type(rc) == "table" then
            local entry = rc[provider]
            if entry == nil then
                -- No provider-specific entry: honour a table-level default.
                if rc.default == "off" or rc.default == false then return { force = "off" } end
                if rc.default == "on" or rc.default == true then return { force = "on" } end
                return nil
            end
            if entry == "off" or entry == false then return { force = "off" } end
            if entry == true then return { force = "on" } end
            if type(entry) == "table" then
                return {
                    force = "on",
                    effort = entry.effort or entry.level,  -- level = Gemini 3 thinkingLevel
                    budget = entry.budget,
                }
            end
            return nil
        end
        return nil
    end

    -- Legacy fields
    if action.reasoning == "off" or action.extended_thinking == "off" then
        return { force = "off" }
    end
    if action.reasoning == "on" or action.extended_thinking == "on" then
        return {
            force = "on",
            effort = action.reasoning_effort or action.reasoning_depth,
            budget = action.thinking_budget,
        }
    end

    return nil
end

--- Translate a resolved reasoning decision into provider-specific api_params keys
--- (mutated in place). Wire format matches the existing per-provider builders.
--- Emits nothing when decision.send_nothing is true (model behaves at API default).
--- @param provider string
--- @param api_params table  (mutated in place)
--- @param decision table    (from resolveReasoning)
-- Reasoning wire keys applyReasoningParams may write. Single source of truth:
-- koassistant_dialogs.lua clears these when rebasing a config, and the loading
-- dialog inspects them for display.
ModelConstraints.REASONING_WIRE_KEYS = {
    "thinking", "output_config", "reasoning", "thinking_budget", "thinking_level",
    "deepseek_thinking", "zai_thinking", "sambanova_thinking", "kimi_thinking",
    "openrouter_reasoning", "requesty_reasoning", "groq_reasoning", "nvidia_reasoning",
    "together_reasoning", "fireworks_reasoning", "xai_reasoning",
    "perplexity_reasoning", "custom_reasoning", "_reasoning",
}

--- Display-only: does this request's computed api_params actually ENABLE
-- reasoning? The loading dialog used a bare truthiness check, so an explicit
-- disable (thinking={type="disabled"}, {enabled=false}, {on=false},
-- effort "none", budget 0) displayed as "Reasoning enabled" (maintainer device
-- report 2026-08-02, translate action). Mirrors applyReasoningParams' off
-- shapes; anything non-nil that is not an explicit disable counts as on.
function ModelConstraints.reasoningDisplayEnabled(api_params)
    if type(api_params) ~= "table" then return false end
    for _idx, key in ipairs(ModelConstraints.REASONING_WIRE_KEYS) do
        local v = api_params[key]
        if v ~= nil and v ~= false and v ~= 0 and v ~= "none" then
            if type(v) ~= "table" then return true end
            if v.type ~= "disabled" and v.enabled ~= false
                    and v.on ~= false and v.effort ~= "none" then
                return true
            end
        end
    end
    return false
end

function ModelConstraints.applyReasoningParams(provider, api_params, decision)
    if not api_params or not decision then return end
    if decision.send_nothing or decision.axis == "none" then return end
    local on = (decision.mode == "on")

    if provider == "anthropic" then
        if on then
            if decision.axis == "adaptive_effort" then
                api_params.thinking = { type = "adaptive" }
                api_params.output_config = { effort = decision.effort }
            elseif decision.axis == "budget" then
                api_params.thinking = {
                    type = "enabled",
                    budget_tokens = math.max(decision.budget or 32000, 1024),
                }
            end
        elseif decision.profile and decision.profile.default_state == "on" then
            -- Model thinks by DEFAULT (e.g. Sonnet 5: omitting `thinking` runs adaptive).
            -- Omission would still think, so emit an explicit disable to honor the off decision.
            api_params.thinking = { type = "disabled" }
        end
        -- else (off + default-off, e.g. Opus/Sonnet 4.6): emit nothing (Anthropic reasons
        -- only when `thinking` is present).
    elseif provider == "openai" or provider == "openai_codex" then
        if on then api_params.reasoning = { effort = decision.effort } end
    elseif provider == "gemini" then
        if decision.axis == "budget" then
            api_params.thinking_budget = on and (decision.budget or -1) or 0
        elseif decision.axis == "effort" then  -- Gemini 3 thinkingLevel
            if on then api_params.thinking_level = decision.effort end
        end
    elseif provider == "deepseek" then
        api_params.deepseek_thinking = { type = on and "enabled" or "disabled" }
    elseif provider == "kimi" then
        -- kimi-k2.6 thinks by DEFAULT; only an explicit OFF needs a wire param
        -- (thinking = {type="disabled"}, probed 2026-08-15 — reasoning tokens
        -- 311 → 1). {type="enabled"} never probed, and on == the API default,
        -- so emit nothing for on. kimi.lua translates and drops temperature
        -- (temp is mode-locked; see the forced-params note).
        if not on then api_params.kimi_thinking = { type = "disabled" } end
    elseif provider == "zai" then
        api_params.zai_thinking = { type = on and "enabled" or "disabled" }
    elseif provider == "sambanova" then
        api_params.sambanova_thinking = on
    elseif provider == "openrouter" then
        -- off reaches here only for disable-CAPABLE backends (mandatory families carry
        -- can_disable=false so their minimal stance resolves to lowest effort, never off).
        if on then api_params.openrouter_reasoning = { effort = decision.effort }
        else api_params.openrouter_reasoning = { enabled = false } end
    elseif provider == "requesty" then
        if on then api_params.requesty_reasoning = { effort = decision.effort }
        else api_params.requesty_reasoning = { enabled = false } end
    elseif provider == "nvidia" then
        -- "none" fully disables (probed); nvidia.lua puts either onto reasoning_effort.
        if on then api_params.nvidia_reasoning = { effort = decision.effort }
        elseif decision.off_option then api_params.nvidia_reasoning = { effort = decision.off_option } end
    elseif provider == "groq" then
        if on then api_params.groq_reasoning = { effort = decision.effort } end
    elseif provider == "together" then
        if on then api_params.together_reasoning = { effort = decision.effort } end
    elseif provider == "fireworks" then
        if on then api_params.fireworks_reasoning = { effort = decision.effort } end
    elseif provider == "xai" then
        if on then
            api_params.xai_reasoning = { effort = decision.effort }
        elseif decision.off_option then
            api_params.xai_reasoning = { effort = decision.off_option }  -- e.g. "none"
        end
    elseif provider == "perplexity" then
        if on then api_params.perplexity_reasoning = { effort = decision.effort } end
    else
        -- Custom providers (no builtin branch): a user profile from custom_models.lua
        -- may name an OpenAI-compatible wire via `wire`. Emit a neutral record;
        -- custom_openai.lua translates it onto the request body. Key must stay listed
        -- in REASONING_WIRE_KEYS (koassistant_dialogs.lua).
        local wire = decision.profile and decision.profile.wire
        if wire then
            api_params.custom_reasoning = {
                wire = wire,
                on = on,
                effort = decision.effort,
                off_option = decision.off_option,
                needs_temp_1 = decision.needs_temp_1,
            }
        end
    end
end

-- OpenAI Subscription uses the same model contracts as the direct OpenAI
-- provider; only its authentication and endpoint differ.
ModelConstraints.openai_codex = ModelConstraints.openai
ModelConstraints.capabilities.openai_codex = ModelConstraints.capabilities.openai
ModelConstraints.reasoning_profiles.openai_codex = ModelConstraints.reasoning_profiles.openai
ModelConstraints._context_windows.openai_codex = ModelConstraints._context_windows.openai

return ModelConstraints
