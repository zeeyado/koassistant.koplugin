-- Model lists for each provider
-- SINGLE SOURCE OF TRUTH for all model data
-- Last updated: 2026-07-28
--
-- Structure:
--   ModelLists[provider] = array of model IDs (for backward compat & dropdowns)
--   ModelLists._tiers = tier -> provider -> model_id mappings
--   ModelLists._docs = provider documentation URLs for update checking

local ModelLists = {
    ---------------------------------------------------------------------------
    -- MODEL LISTS (flat arrays for backward compatibility)
    -- Order matters: first model is the default for each provider
    ---------------------------------------------------------------------------

    anthropic = {
        -- Claude 5 / 4.x (current generation)
        "claude-sonnet-5",              -- default (balanced speed/cost); adaptive thinking on, rejects sampling params
        "claude-opus-5",                -- deep reasoning flagship (2026-07-24, $5/$25 like Opus 4.8); adaptive thinking on, disable ok, rejects sampling
        "claude-fable-5",               -- most capable / frontier; adaptive thinking ALWAYS-ON (no disable), rejects sampling, premium price
        "claude-sonnet-4-6",            -- previous flagship (kept available), 1M context
        "claude-opus-4-8",              -- deep reasoning / agentic (adaptive thinking)
        "claude-haiku-4-5-20251001",    -- fast
    },

    openai = {
        -- GPT-5.6 (current generation), tiered by price/perf: sol (flagship) >
        -- terra (balanced) > luna (cost). Default = terra (balanced), not the priciest.
        -- All: reasoning opt-in (OFF by default; none..xhigh, NO max), 128K output,
        -- tools + web search (Responses API), ~1M context, temperature=1.0 only.
        "gpt-5.6-terra",                -- balanced (default)
        "gpt-5.6-sol",                  -- flagship (most capable)
        "gpt-5.6-luna",                 -- cost-optimized
        -- GPT-5.5 (previous flagship; reasons by default at medium, cannot disable)
        "gpt-5.5",
        -- GPT-5.4 (affordable tier)
        "gpt-5.4",
        "gpt-5.4-mini",                 -- standard
        "gpt-5.4-nano",                 -- fast/ultrafast
        -- NOTE: *-pro variants are v1/responses only (not chat-completions) — excluded.
    },

    openai_codex = {
        -- OpenAI ChatGPT subscription (Codex OAuth) reuses the same curated
        -- subscription model slugs as direct OpenAI, but authenticates with
        -- device-code OAuth against ChatGPT's Codex backend.
        -- Probed live 2026-08-15 on a FREE ChatGPT account: terra/luna/5.5/
        -- 5.4-mini answer; sol, 5.4 and 5.4-nano are refused there ("not
        -- supported when using Codex with a ChatGPT account") with a clear
        -- error. ALL slugs stay listed (paid plans unverified, may serve
        -- more); default + tier picks use free-served slugs only, so
        -- auto-selection never 400s (maintainer ruling 2026-08-15).
        "gpt-5.6-terra",                -- balanced (default; served on free accounts)
        "gpt-5.6-sol",                  -- flagship (most capable; refused on free accounts)
        "gpt-5.6-luna",                 -- cost-optimized (served on free accounts)
        "gpt-5.5",                      -- served on free accounts
        "gpt-5.4",                      -- refused on free accounts
        "gpt-5.4-mini",                 -- served on free accounts
        "gpt-5.4-nano",                 -- refused on free accounts
    },

    deepseek = {
        -- DeepSeek V4 (current generation, 1M context, thinking on by default)
        "deepseek-v4-pro",              -- flagship (default) + reasoning
        "deepseek-v4-flash",            -- standard/fast
    },

    gemini = {
        -- Gemini 3.x (current generation)
        "gemini-3.7-flash",             -- newest flash (default since 2026-08-15; full free-key
                                        -- battery: default thinking ON, effort low/medium/high,
                                        -- MINIMAL rejected (unlike 3.6), tools + streaming green,
                                        -- free-tier grounding gated like the rest of 3.x)
        "gemini-3.6-flash",             -- previous default (kept available)
        "gemini-3.5-flash",             -- previous flash (kept available)
        "gemini-3.1-pro-preview",       -- frontier tier, reasoning (paid only; no 3.5/3.6 pro yet;
                                        -- full battery green on a paid key 2026-08-15: effort
                                        -- low/medium/high, no disable, tools + grounding work)
        "gemini-3.5-flash-lite",        -- fast/ultrafast (newest lite)
        "gemini-3.1-flash-lite",        -- ultrafast (previous)
        -- Gemini 2.5 (kept for popularity)
        "gemini-2.5-flash",             -- still popular, free tier
        "gemini-2.5-pro",               -- GA deep-reasoning (paid)
        "gemini-2.5-flash-lite",        -- cheapest/fastest 2.5 (free tier)
    },

    ollama = {
        -- Llama (Meta) - most popular open models
        "llama4",                       -- latest Llama (default)
        "llama3.3",
        "llama3.3:70b",
        "llama3.2",
        "llama3.2:3b",                  -- fast
        -- Qwen (Alibaba) - excellent multilingual
        "qwen3.5",
        "qwen3",
        "qwen3:8b",
        "qwen3:32b",
        -- DeepSeek
        "deepseek-v4",
        "deepseek-r1",                  -- reasoning
        "deepseek-r1:8b",
        -- Gemma (Google)
        "gemma4",
        "gemma3",
        "gemma3:4b",
        "gemma3:27b",
        -- Mistral
        "mistral",
        "mistral-nemo",                 -- Apache 2.0, 12B
        -- Phi (Microsoft) - small but capable
        "phi4",
        "gpt-oss",                      -- OpenAI open-weight (:20b default, :120b tag)
        -- Tiny models
        "tinyllama",                    -- ~637MB, good for testing
    },

    groq = {
        -- Production models (FREE tier with rate limits)
        "openai/gpt-oss-120b",                          -- flagship (default)
        "openai/gpt-oss-20b",                           -- fast
        -- (llama-3.3-70b-versatile + llama-3.1-8b-instant — the former default
        -- and fast picks — deprecated by Groq effective 2026-08-16, vendor-
        -- recommended replacements = the two gpt-oss models above (T9 refresh
        -- 2026-08-14). qwen/qwen3-32b + meta-llama/llama-4-scout deprecated
        -- 2026-07-17. Removed from the picker; constraint entries kept for
        -- users with the model still persisted in settings.)
        -- Compound AI (agentic)
        "groq/compound",                                -- web search + code exec
        "groq/compound-mini",
    },

    mistral = {
        -- Flagship (Mistral Large 3 via -latest alias)
        "mistral-large-latest",         -- flagship (default)
        -- Medium (Mistral Medium 3.5)
        "mistral-medium-latest",        -- standard
        -- Small (Mistral Small 4 - unified reasoning/multimodal/coding, open-weight)
        "mistral-small-latest",         -- fast (open-weight)
        -- Reasoning (Magistral 1.2)
        "magistral-medium-latest",
        "magistral-small-latest",       -- open-weight (Apache 2.0)
        -- Ministral edge models (2512 generation; 14b/8b probed 2026-07-28,
        -- 3b probed 2026-08-14: no reasoning axis, temperature free, tools OK)
        "ministral-14b-latest",         -- fast
        "ministral-8b-latest",
        "ministral-3b-latest",          -- ultrafast ($0.10/M in+out, vision+tools)
        -- Coding
        "codestral-latest",
    },

    xai = {
        -- Grok 4.6 (flagship since 2026-08-12; 500K context, $2/$6 — grok-4.5
        -- successor. Probed 2026-08-14: effort minimal..xhigh, effort "none"
        -- REJECTED (cannot disable reasoning — unlike 4.5/4.3), temp free, tools OK)
        "grok-4.6",                     -- flagship (default) + reasoning
        -- Grok 4.5 (500K context; the documented agent-tools
        -- model — native web search rides its Responses endpoint)
        "grok-4.5",                     -- reasoning
        -- Grok 4.3 (1M context)
        "grok-4.3",                     -- reasoning
        -- Grok 4.20 (1M context; reasoning toggle baked into the slug)
        "grok-4.20-0309-non-reasoning", -- standard/fast
        "grok-4.20-0309-reasoning",     -- reasoning
        -- Specialized
        "grok-build-0.1",               -- coding (256K context)
    },

    openrouter = {
        -- OpenRouter model naming differs from direct provider APIs
        -- Format: provider/model-name (no "-latest" suffixes, periods not dashes)

        -- Anthropic
        "anthropic/claude-sonnet-5",    -- default (flagship); slug confirmed on openrouter.ai
        "anthropic/claude-opus-5",      -- deep reasoning flagship (a -fast variant exists at 2x price; not listed)
        "anthropic/claude-fable-5",     -- most capable / frontier
        "anthropic/claude-sonnet-4.6",
        "anthropic/claude-opus-4.8",
        "anthropic/claude-haiku-4.5",

        -- OpenAI (gpt-5.6: sol > terra > luna)
        "openai/gpt-5.6-sol",
        "openai/gpt-5.6-terra",
        "openai/gpt-5.6-luna",
        "openai/gpt-5.5",
        "openai/gpt-5.4",
        "openai/gpt-5.4-mini",
        -- OpenAI open-weight (Apache 2.0; ids live-verified on the catalog
        -- 2026-08-04, a 20b ":free" variant also exists)
        "openai/gpt-oss-120b",
        "openai/gpt-oss-20b",

        -- Google
        "google/gemini-3.7-flash",      -- catalog-verified 2026-08-15 ($0.38/$1.88, half of 3.6 there)
        "google/gemini-3.6-flash",
        "google/gemini-3.5-flash",
        "google/gemini-3.5-flash-lite",

        -- DeepSeek
        "deepseek/deepseek-v4-pro",
        "deepseek/deepseek-v4-flash",

        -- xAI Grok
        "x-ai/grok-4.3",
        "x-ai/grok-4.20",

        -- Meta Llama
        "meta-llama/llama-3.3-70b-instruct",

        -- Mistral
        "mistralai/mistral-large-2512",
        "mistralai/mistral-medium-3.1",

        -- Qwen
        "qwen/qwen3-max",
        "qwen/qwen3-235b-a22b",

        -- Perplexity (built-in web search)
        "perplexity/sonar-pro",
        "perplexity/sonar-reasoning-pro",
        "perplexity/sonar",

        -- Other notable
        "moonshotai/kimi-k2-thinking",
        "minimax/minimax-m2.1",
    },

    requesty = {
        -- Requesty is an OpenAI-compatible model router (https://requesty.ai).
        -- Model naming: provider/model-name, but NOT the same convention as OpenRouter —
        -- Requesty hyphenates Anthropic versions (claude-sonnet-4-6, not 4.6) and uses
        -- "xai/" (not "x-ai/"). All ids below verified against the live catalog
        -- (https://router.requesty.ai/v1/models, public, 2026-07-05).

        -- OpenAI
        "openai/gpt-4o-mini",           -- default (fast, low-cost)
        "openai/gpt-5.5",
        "openai/gpt-5.4",

        -- Anthropic
        "anthropic/claude-sonnet-5",
        "anthropic/claude-opus-5",      -- deep-reasoning flagship (no dotted version, so the hyphenation rule is moot)
        "anthropic/claude-fable-5",     -- frontier (verified in catalog 2026-07-28)
        "anthropic/claude-sonnet-4-6",
        "anthropic/claude-haiku-4-5",

        -- Google
        "google/gemini-2.5-flash",

        -- DeepSeek
        "deepseek/deepseek-v4-pro",

        -- xAI Grok
        "xai/grok-4.3",
    },

    qwen = {
        -- Qwen3 / Qwen3.5 (current)
        "qwen3-max",                    -- flagship (default)
        "qwen3.5-plus",                 -- standard
        "qwen3.5-flash",                -- fast
        "qwen-turbo",                   -- ultrafast
        "qwen3-coder-plus",             -- coding
    },

    kimi = {
        -- Kimi K2.6 (current, multimodal). Probed on the INTERNATIONAL
        -- platform 2026-08-15: it serves ONLY kimi-k2.6 (+ a k2.7-code slug),
        -- thinks by default, and temperature is mode-locked (see
        -- model_constraints kimi note). The -thinking and -turbo ids 404
        -- there ("Not found ... or Permission denied") but stay listed for
        -- CN-platform users (region split; codex-precedent: never strip
        -- models that other plans/regions may serve — the error is clear).
        "kimi-k2.6",                    -- flagship (default; the one id served internationally)
        "kimi-k2.6-thinking",           -- reasoning (CN platform)
        "kimi-k2-turbo-preview",        -- fast (CN platform)
    },

    together = {
        -- DeepSeek V4 (current)
        "deepseek-ai/DeepSeek-V4-Pro",                       -- flagship + reasoning
        "deepseek-ai/DeepSeek-V4-Flash-0731", -- dated variant is the live id (catalog-verified 2026-08-15; the bare -Flash slug is gone)
        -- Llama 3.3
        "meta-llama/Llama-3.3-70B-Instruct-Turbo",           -- standard/fast
        -- Other
        "moonshotai/Kimi-K2.6",
        "zai-org/GLM-5.2",                                   -- GLM-5 deprecated 2026-06-22, changelog recommends 5.2
        -- (Removed per Together's own changelog, T9 refresh 2026-08-14:
        -- Qwen/Qwen3.5-397B-A17B deprecated from serverless 2026-06-29;
        -- Qwen/Qwen3-235B-A22B-Instruct-2507-tput moved dedicated-only
        -- 2026-07-10; MiniMaxAI/MiniMax-M2.7 deprecated 2026-07-28.)
    },

    fireworks = {
        -- Live-verified against the keyed /v1/models catalog 2026-08-15
        -- (24 serving ids; Fireworks encodes dots as "p": k2p6 = k2.6).
        -- Default = the cheap workhorse, not the flagship (maintainer,
        -- same-day device round): deepseek-v4-pro stays the flagship tier.
        "accounts/fireworks/models/gpt-oss-120b",                    -- standard/fast (default)
        "accounts/fireworks/models/deepseek-v4-pro",                 -- flagship + reasoning
        "accounts/fireworks/models/deepseek-v4-flash-0731",          -- fast deepseek
        "accounts/fireworks/models/qwen3p8-max",
        "accounts/fireworks/models/kimi-k2p6",                       -- reasoning
        "accounts/fireworks/models/glm-5p2",
        "accounts/fireworks/models/gpt-oss-20b",                     -- small/fast
        -- (Dead ids dropped 2026-08-15, absent from the live catalog:
        -- deepseek-r1, qwen3-235b-a22b, kimi-k2-thinking. Earlier removals
        -- per Fireworks' changelog, T9 refresh 2026-08-14: llama-v3p3-70b
        -- deprecated 2026-05-14 -> gpt-oss-120b; glm-5 -> glm-5p2 above.)
    },

    sambanova = {
        -- gpt-oss (Production tier)
        "gpt-oss-120b",                                      -- flagship (default)
        -- DeepSeek
        "DeepSeek-V3.1",                                     -- reasoning (128K ctx)
        "DeepSeek-V3.2",                                     -- preview (32K ctx per docs)
        -- Llama 3.x
        "Meta-Llama-3.3-70B-Instruct",                       -- standard/fast
        -- Other
        "MiniMax-M2.7",
        "gemma-4-31B-it",
        -- (Llama-4-Maverick-17B-128E-Instruct — the former default/flagship —
        -- deprecated by SambaNova 2026-06-09 and absent from their live model
        -- page (T9 refresh 2026-08-14); their suggested gemma-4-31B-it is
        -- Preview-tier, so the Production-tier gpt-oss-120b is the new default.)
    },

    cohere = {
        -- Command A+ (latest, strongest - first MoE)
        "command-a-plus-05-2026",       -- flagship (default)
        -- Reasoning
        "command-a-reasoning-08-2025",  -- reasoning
        -- Smaller/fast
        "command-r7b-12-2024",          -- fast
    },

    doubao = {
        -- Doubao Seed 2.0 (current, Feb 2026)
        -- NOTE: native ARK may require date-suffixed snapshot or endpoint IDs;
        -- verify exact strings in the Volcengine console.
        "doubao-seed-2.0-pro-32k",      -- flagship (default)
        "doubao-seed-2.0-pro-256k",
        "doubao-seed-2.0-lite",         -- fast
        "doubao-seed-2.0-code",         -- coding
    },

    perplexity = {
        -- All Sonar models include built-in web search with citations
        "sonar-pro",                    -- flagship (default, advanced search)
        "sonar-reasoning-pro",          -- reasoning + search
        "sonar-deep-research",          -- deep research
        "sonar",                        -- fast search (lightweight)
    },

    zai = {
        -- GLM-5.x (200K context)
        "glm-5.2",                      -- flagship (default), released 2026-06-16
        "glm-5.1",                      -- previous flagship (kept available), coding leader
        "glm-5",
        "glm-5-turbo",                  -- fast
        -- GLM-4.7 (200K context)
        "glm-4.7",                      -- reasoning
        "glm-4.7-flash",                -- free tier
    },

    ---------------------------------------------------------------------------
    -- COMMUNITY SET (M1, model_management_strategy.md "End-state REVISION 2"):
    -- docs-based providers, no maintainer key yet. SEED lists only — 1-2
    -- documented ids so the provider is usable out of the box; the real path is
    -- "Fetch models from provider" (per-user live list). No tier placements
    -- (tier features no-op). Promotion to curated = keys pipeline (item 25e M4).
    ---------------------------------------------------------------------------
    -- Seed ids below marked "live 2026-08-09" were checked against the provider's
    -- own public /models catalog. The others remain docs-based guesses.
    -- Four ids were WRONG and 404'd on the user's first request (two of them the
    -- provider's DEFAULT model, i.e. the provider was unusable out of the box).
    cerebras = {
        "gpt-oss-120b",                             -- live 2026-08-09
        "gemma-4-31b",                              -- catalog 2026-08-14 (replaced zai-glm-4.7, which Cerebras deprecates 2026-08-17; llama-3.3-70b before that, deprecated 2026-02-16)
    },
    minimax = {
        "MiniMax-M3",                               -- seed (unverified: catalog needs a key)
        "MiniMax-M2.7",                             -- seed (unverified)
    },
    deepinfra = {
        "meta-llama/Llama-3.3-70B-Instruct-Turbo",  -- live 2026-08-09 (non-Turbo id does not exist)
        "deepseek-ai/DeepSeek-V4-Pro",              -- live 2026-08-09 (bare "DeepSeek-V4" does not exist)
    },
    novita = {
        "deepseek/deepseek-v4-pro",                 -- live 2026-08-09 (bare "deepseek-v4" does not exist)
        "meta-llama/llama-3.3-70b-instruct",        -- live 2026-08-09
    },
    hyperbolic = {
        "meta-llama/Llama-3.3-70B-Instruct",        -- seed (unverified)
    },
    -- NVIDIA (build.nvidia.com / NIM). CURATED FROM A LIVE PROBE 2026-08-20:
    -- of 77 chat ids in their public /v1/models, only 21 answered — 47 returned
    -- 404 and 9 accepted the connection and never sent a byte (a silent hang
    -- with no error to render, e.g. deepseek-ai/deepseek-v4-flash-0731 and
    -- meta/llama-3.3-70b-instruct). ONLY add ids here after they answer live;
    -- their catalog is aspirational and "Fetch models" will re-import the dead.
    nvidia = {
        "nvidia/nemotron-3-super-120b-a12b",        -- default: tools + forced tools + effort all probed
        "nvidia/nemotron-3-ultra-550b-a55b",
        "nvidia/nemotron-3-nano-30b-a3b",
        "openai/gpt-oss-120b",                      -- answers live 2026-08-29 (reachability only)
        "openai/gpt-oss-20b",
        "minimaxai/minimax-m3",
        -- RETIRED BY NVIDIA (HTTP 410 Gone, end of life 2026-08-26/28, re-probed
        -- 2026-08-29; the reader-visible "HTTP 400/404" report on 0.21.2):
        --   nvidia/nvidia-nemotron-nano-9b-v2, nvidia/llama-3.3-nemotron-super-49b-v1.5,
        --   meta/llama-3.1-70b-instruct, meta/llama-3.1-8b-instruct,
        --   stepfun-ai/step-3.7-flash, nvidia/nemotron-mini-4b-instruct
        -- CANDIDATES that answered a reachability call 2026-08-29 but have NOT
        -- had the model_audit battery: moonshotai/kimi-k3 (~3s),
        -- nvidia/nemotron-3-nano-omni-30b-a3b-reasoning (~0.8s),
        -- mistralai/mistral-nemotron (~0.5s; 2 of 3 probes timed out on 08-20),
        -- deepseek-ai/deepseek-v4-flash-0731 (~15s, content null beside
        -- reasoning_content). deepseek-ai/deepseek-v4-pro-0813 still hangs.
        -- EXCLUDED, do not re-add without re-probing (device round 2026-08-20):
        --   nvidia/nemotron-3.5-lightning-30b-a3b -- reasoning never terminates on
        --     constraint-shaped prompts ("translate this", "answer in N words"):
        --     content comes back byte-identical to reasoning_content with no answer
        --     after it, on every sample. Only reasoning_effort="none" works, and our
        --     default stance sends nothing, so reasoning is ON by default.
    },
    nebius = {
        "meta-llama/Llama-3.3-70B-Instruct",        -- seed (unverified)
        "deepseek-ai/DeepSeek-V4",                  -- seed (unverified)
    },
    chutes = {
        -- Chutes' own live catalog (chutes.ai/app, fetched 2026-08-14) lists
        -- every current id with a -TEE suffix; the old bare "deepseek-ai/
        -- DeepSeek-V4" appears nowhere in it.
        "deepseek-ai/DeepSeek-V4-Flash-0731-TEE",   -- catalog 2026-08-14
    },
    featherless = {
        "Qwen/Qwen3-32B",                           -- seed (unverified)
    },
    vercel = {
        "openai/gpt-5.5",                           -- seed (unverified)
        "anthropic/claude-sonnet-5",                -- seed (unverified)
    },

    ---------------------------------------------------------------------------
    -- CURATED vs COMMUNITY membership (REVISION 2). Community = docs-based, no
    -- maintainer key / local-pipeline coverage yet. This INCLUDES the long-
    -- shipped providers the maintainer has never been able to test (honest
    -- relabeling, item 25e M4) — remove a provider here when its key arrives
    -- and the model_audit pipeline has run (that's the promotion).
    ---------------------------------------------------------------------------
    _community = {
        -- pre-2026-08 built-ins, never maintainer-tested
        -- (fireworks + cohere PROMOTED OUT 2026-08-15: keyed, catalog-validated,
        -- probed — fireworks full batteries incl. tools wave 2, cohere live
        -- validation + the reasoning-parse fix. together/sambanova stay: keys
        -- exist but generation is credit/card-gated, so still unverified.)
        -- (qwen + kimi promoted 2026-08-15 evening: keyed, validated, batteries
        -- on the defaults, both native web-search wires probed working.)
        groq = true, together = true, sambanova = true,
        requesty = true, doubao = true,
        -- M1 additions (ex hosted presets)
        cerebras = true, minimax = true, deepinfra = true, novita = true,
        hyperbolic = true, nebius = true, chutes = true, featherless = true,
        vercel = true,
    },

    ---------------------------------------------------------------------------
    -- TIER MAPPINGS
    -- Maps tier -> provider -> recommended model_id
    -- Tiers: frontier > flagship > standard > fast > ultrafast
    --
    -- The old "reasoning" tier was RETIRED 2026-07-28 (item 19d): reasoning is a
    -- per-model AXIS now (model_constraints.lua profiles), not a price rung —
    -- every current flagship thinks. Persisted "reasoning" picks read through to
    -- flagship via normalizeTier(); never to frontier (no silent up-pricing).
    -- Users can add/override tier entries (incl. for custom providers) via the
    -- tiers section of custom_models.lua — resolved in getModelForTier().
    ---------------------------------------------------------------------------

    -- Every id we have EVER shipped as a provider's array default (mined from git history
    -- 2026-07-25; newest first). Purpose: `features.model` CONFLATES a default auto-baked on
    -- provider switch with a model the user deliberately picked, so it cannot be refreshed
    -- safely on its own. If the persisted id appears here, it was almost certainly baked by
    -- us rather than chosen — which makes it safe to move to the current default when we
    -- bump one (defaults_propagation_plan.md §3). APPEND the outgoing id whenever a default
    -- changes; never remove entries (that would strand the users we are trying to migrate).
    -- Explicit picks are recorded in features.model_explicit from 2026-07-25 onward, so this
    -- heuristic only has to cover users who predate that.
    _shipped_defaults = {
        anthropic  = { "claude-sonnet-5", "claude-sonnet-4-6", "claude-sonnet-4-5-20250929" },
        openai     = { "gpt-5.6-terra", "gpt-5.5", "gpt-5.4", "gpt-5.2" },
        openai_codex = { "gpt-5.6-terra", "gpt-5.5", "gpt-5.4" },
        gemini     = { "gemini-3.7-flash", "gemini-3.6-flash", "gemini-3.5-flash", "gemini-2.5-flash", "gemini-3-flash-preview" },
        deepseek   = { "deepseek-v4-pro", "deepseek-chat" },
        ollama     = { "llama4", "llama3.3" },
        groq       = { "openai/gpt-oss-120b", "llama-3.3-70b-versatile" },
        mistral    = { "mistral-large-latest" },
        xai        = { "grok-4.6", "grok-4.5", "grok-4.3", "grok-4.20-beta-0309-non-reasoning", "grok-4-1-fast-non-reasoning" },
        openrouter = { "anthropic/claude-sonnet-5", "anthropic/claude-sonnet-4.6", "anthropic/claude-sonnet-4.5" },
        requesty   = { "openai/gpt-4o-mini" },
        qwen       = { "qwen3-max" },
        kimi       = { "kimi-k2.6", "kimi-k2.5", "kimi-k2-0905-preview" },
        together   = { "deepseek-ai/DeepSeek-V4-Pro", "meta-llama/Llama-4-Maverick-17B-128E-Instruct-FP8" },
        fireworks  = { "accounts/fireworks/models/gpt-oss-120b", "accounts/fireworks/models/deepseek-v4-pro", "accounts/fireworks/models/llama4-maverick-instruct-basic" },
        sambanova  = { "gpt-oss-120b", "Llama-4-Maverick-17B-128E-Instruct", "Meta-Llama-4-Maverick-17B-128E-Instruct" },
        cohere     = { "command-a-plus-05-2026", "command-a-03-2025" },
        doubao     = { "doubao-seed-2.0-pro-32k", "doubao-1.8-pro-32k" },
        perplexity = { "sonar-pro", "sonar" },
        zai        = { "glm-5.2", "glm-5.1", "glm-5-turbo", "glm-5" },
    },

    _tiers = {
        -- META ROUTERS (openrouter, requesty) have NO curated placements
        -- (maintainer ruling 2026-08-17): a router's tier ladder would hop
        -- SUB-VENDORS (anthropic pick silently running an openai slug on a
        -- "fast" hint) — surprising and wrong. Tier hints on a router keep
        -- the current model (resolveTierModel nil-miss). Users who want
        -- router tiers set them via the Model tiers GUI / custom_models.lua
        -- (override layer resolves before curated). The mechanical
        -- family-sticky sub-ladder idea is queued v0.22 (Gate B).
        -- Most capable, premium-priced models. STRICTLY OPT-IN: nothing
        -- auto-selects this tier — the Quick preset "fastest" walk stops at
        -- flagship, and getModelForTier() fallback only descends (a frontier
        -- REQUEST falls to flagship; a flagship request never climbs here).
        -- Sparse by design: most providers have no frontier-class model.
        frontier = {
            anthropic = "claude-fable-5",
            gemini = "gemini-3.1-pro-preview",       -- paid-only deep reasoning
        },

        -- Provider's most capable general-purpose model
        flagship = {
            anthropic = "claude-opus-5",             -- deep-reasoning flagship; sonnet-5 is the standard tier
            openai = "gpt-5.6-sol",
            openai_codex = "gpt-5.6-terra", -- best slug served on ALL plans (sol 400s on free accounts; still pickable manually)
            deepseek = "deepseek-v4-pro",
            gemini = "gemini-3.7-flash",             -- Pro models are paid-only; keep tier free-tier usable (3.7-flash battery-probed on a free key 2026-08-15)
            groq = "openai/gpt-oss-120b",            -- llama picks deprecated by Groq 2026-08-16
            mistral = "mistral-large-latest",
            xai = "grok-4.6",
            cohere = "command-a-plus-05-2026",
            ollama = "llama4",
            together = "deepseek-ai/DeepSeek-V4-Pro",
            fireworks = "accounts/fireworks/models/deepseek-v4-pro",
            sambanova = "gpt-oss-120b",              -- Maverick deprecated 2026-06-09
            qwen = "qwen3-max",
            kimi = "kimi-k2.6",
            doubao = "doubao-seed-2.0-pro-32k",
            zai = "glm-5.2",
            perplexity = "sonar-pro",
            nvidia = "nvidia/nemotron-3-ultra-550b-a55b",
        },

        -- Balanced performance and cost
        standard = {
            anthropic = "claude-sonnet-5",
            openai = "gpt-5.6-terra",  -- standard/default
            openai_codex = "gpt-5.6-terra",
            deepseek = "deepseek-v4-flash",
            gemini = "gemini-3.7-flash",
            groq = "openai/gpt-oss-120b",
            mistral = "mistral-medium-latest",
            xai = "grok-4.20-0309-non-reasoning",
            cohere = "command-a-plus-05-2026",
            ollama = "llama3.3",
            together = "meta-llama/Llama-3.3-70B-Instruct-Turbo",
            fireworks = "accounts/fireworks/models/gpt-oss-120b", -- llama-v3p3 deprecated 2026-05-14, vendor target gpt-oss-120b
            sambanova = "Meta-Llama-3.3-70B-Instruct",
            qwen = "qwen3.5-plus",
            kimi = "kimi-k2.6",
            doubao = "doubao-seed-2.0-pro-32k",
            zai = "glm-5",
            perplexity = "sonar",
            nvidia = "nvidia/nemotron-3-super-120b-a12b",
        },

        -- Optimized for speed and lower cost
        fast = {
            anthropic = "claude-haiku-4-5-20251001",
            openai = "gpt-5.6-luna",
            openai_codex = "gpt-5.6-luna",
            deepseek = "deepseek-v4-flash",
            gemini = "gemini-3.5-flash-lite",   -- lite = the no-default-thinking class; 3.6-flash here duplicated standard and can't turn thinking off (floor = minimal)
            groq = "openai/gpt-oss-20b",        -- 8b-instant deprecated 2026-08-16; gpt-oss-20b is Groq's own replacement (reasons at medium by default — no non-reasoning production model remains)
            mistral = "ministral-14b-latest",
            xai = "grok-4.20-0309-non-reasoning",
            cohere = "command-r7b-12-2024",
            ollama = "llama3.2:3b",
            together = "meta-llama/Llama-3.3-70B-Instruct-Turbo",
            fireworks = "accounts/fireworks/models/gpt-oss-120b", -- llama-v3p3 deprecated 2026-05-14
            sambanova = "Meta-Llama-3.3-70B-Instruct",
            qwen = "qwen3.5-flash",
            kimi = "kimi-k2.6", -- turbo-preview 404s on the international platform (2026-08-15); k2.6 serves everywhere
            doubao = "doubao-seed-2.0-lite",
            zai = "glm-5-turbo",
            perplexity = "sonar",
            nvidia = "nvidia/nemotron-3-nano-30b-a3b",  -- lightning pulled: see the array note
        },

        -- Smallest/cheapest models for basic tasks
        ultrafast = {
            anthropic = "claude-haiku-4-5-20251001",
            openai = "gpt-5.4-nano",
            openai_codex = "gpt-5.4-mini", -- smallest slug served on ALL plans (nano 400s on free accounts; still pickable manually)
            deepseek = "deepseek-v4-flash",
            gemini = "gemini-3.5-flash-lite",
            groq = "openai/gpt-oss-20b",            -- see fast-tier note: Groq retired every non-reasoning production model 2026-08-16
            mistral = "ministral-3b-latest",
            xai = "grok-4.20-0309-non-reasoning",
            cohere = "command-r7b-12-2024",
            ollama = "tinyllama",
            together = "meta-llama/Llama-3.3-70B-Instruct-Turbo",
            fireworks = "accounts/fireworks/models/gpt-oss-20b", -- smaller/faster sibling (in the array since the 2026-08-15 catalog refresh)
            sambanova = "Meta-Llama-3.3-70B-Instruct",
            qwen = "qwen-turbo",
            kimi = "kimi-k2.6", -- turbo-preview 404s on the international platform (2026-08-15); k2.6 serves everywhere
            doubao = "doubao-seed-2.0-lite",
            zai = "glm-4.7-flash",
            perplexity = "sonar",
            nvidia = "openai/gpt-oss-20b",  -- nano-9b-v2 retired by NVIDIA 2026-08-26 (410)
        },
    },

    ---------------------------------------------------------------------------
    -- DOCUMENTATION SOURCES
    -- For update checking - where to find current model lists
    --
    -- NOTE: Each provider has unique model ID formats. No universal source.
    -- Always verify model strings against the provider's own API/docs.
    ---------------------------------------------------------------------------

    _docs = {
        anthropic = {
            api_list = "https://api.anthropic.com/v1/models",
            docs = "https://docs.anthropic.com/en/docs/about-claude/models",
            curl = "curl https://api.anthropic.com/v1/models -H 'anthropic-version: 2023-06-01' -H 'x-api-key: $ANTHROPIC_API_KEY'",
        },
        openai = {
            api_list = "https://api.openai.com/v1/models",
            docs = "https://platform.openai.com/docs/models",
            curl = "curl https://api.openai.com/v1/models -H 'Authorization: Bearer ***'",
        },
        openai_codex = {
            docs = "https://auth.openai.com/codex/device",
        },
        deepseek = {
            api_list = "https://api.deepseek.com/v1/models",
            docs = "https://api-docs.deepseek.com/quick_start/pricing",
        },
        gemini = {
            api_list = "https://generativelanguage.googleapis.com/v1beta/models",
            docs = "https://ai.google.dev/gemini-api/docs/models/gemini",
            curl = "curl 'https://generativelanguage.googleapis.com/v1beta/models?key=$GEMINI_API_KEY'",
        },
        groq = {
            api_list = "https://api.groq.com/openai/v1/models",
            docs = "https://console.groq.com/docs/models",
        },
        mistral = {
            api_list = "https://api.mistral.ai/v1/models",
            docs = "https://docs.mistral.ai/getting-started/models/models_overview/",
        },
        xai = {
            api_list = "https://api.x.ai/v1/models",
            docs = "https://docs.x.ai/docs/models",
        },
        openrouter = {
            api_list = "https://openrouter.ai/api/v1/models",
            docs = "https://openrouter.ai/models",
        },
        requesty = {
            api_list = "https://router.requesty.ai/v1/models",
            docs = "https://requesty.ai/",
        },
        qwen = {
            docs = "https://help.aliyun.com/zh/model-studio/getting-started/models",
        },
        kimi = {
            docs = "https://platform.moonshot.cn/docs/intro",
            -- International platform: platform.kimi.ai (separate accounts,
            -- region-locked keys — see features.kimi_region)
        },
        together = {
            api_list = "https://api.together.xyz/v1/models",
            docs = "https://docs.together.ai/docs/inference-models",
        },
        fireworks = {
            docs = "https://docs.fireworks.ai/getting-started/quickstart",
        },
        sambanova = {
            api_list = "https://api.sambanova.ai/v1/models",
            docs = "https://community.sambanova.ai/t/supported-models/193",
        },
        cohere = {
            api_list = "https://api.cohere.com/v1/models",
            docs = "https://docs.cohere.com/docs/models",
        },
        doubao = {
            docs = "https://www.volcengine.com/docs/82379/1263482",
        },
        perplexity = {
            docs = "https://docs.perplexity.ai/",
        },
        zai = {
            api_list = "https://api.z.ai/api/paas/v4/models",
            docs = "https://docs.z.ai/api-reference/llm/chat-completion",
        },
        ollama = {
            api_list = "http://localhost:11434/api/tags",
            docs = "https://github.com/ollama/ollama/blob/main/docs/api.md",
            library = "https://ollama.com/library",
        },
        -- Community set (M1): list endpoints derived from the chat URL, unprobed
        cerebras = {
            api_list = "https://api.cerebras.ai/v1/models",
            docs = "https://inference-docs.cerebras.ai/",
        },
        minimax = {
            api_list = "https://api.minimax.io/v1/models",
            docs = "https://platform.minimax.io/docs/",
        },
        deepinfra = {
            api_list = "https://api.deepinfra.com/v1/openai/models",
            docs = "https://deepinfra.com/docs/",
        },
        novita = {
            api_list = "https://api.novita.ai/openai/models",
            docs = "https://novita.ai/docs/",
        },
        hyperbolic = {
            api_list = "https://api.hyperbolic.xyz/v1/models",
            docs = "https://docs.hyperbolic.xyz/",
        },
        nvidia = {
            api_list = "https://integrate.api.nvidia.com/v1/models",
            docs = "https://build.nvidia.com/",
        },
        nebius = {
            api_list = "https://api.studio.nebius.com/v1/models",
            docs = "https://docs.studio.nebius.com/",
        },
        chutes = {
            api_list = "https://llm.chutes.ai/v1/models",
            docs = "https://chutes.ai/",
        },
        featherless = {
            api_list = "https://api.featherless.ai/v1/models",
            docs = "https://featherless.ai/docs/",
        },
        vercel = {
            api_list = "https://ai-gateway.vercel.sh/v1/models",
            docs = "https://vercel.com/docs/ai-gateway",
        },
    },

    ---------------------------------------------------------------------------
    -- TIER DEFINITIONS
    -- Human-readable descriptions for each tier
    ---------------------------------------------------------------------------

    _tier_info = {
        frontier = {
            description = "Most capable premium models — expensive, explicit opt-in only",
            typical_use = "Hardest analysis where cost is no concern; never auto-selected",
        },
        flagship = {
            description = "Provider's most capable general-purpose model",
            typical_use = "Quality-critical tasks, comprehensive assistance",
        },
        standard = {
            description = "Balanced performance and cost",
            typical_use = "Daily reading assistance, general queries",
        },
        fast = {
            description = "Optimized for speed and lower cost",
            typical_use = "Quick lookups, simple explanations, definitions",
        },
        ultrafast = {
            description = "Smallest/cheapest models for basic tasks",
            typical_use = "Vocabulary, definitions, very basic tasks",
        },
    },
}

-------------------------------------------------------------------------------
-- IMAGE GENERATION MODELS (PR #96 polish)
-- Order matters: first model is the default for each provider. Wire/endpoint
-- facts (URLs, auth headers, request shapes) live in koassistant_image_generator.lua.
-- _-prefixed so provider iteration (getAllProviders) skips it.
-------------------------------------------------------------------------------

ModelLists._image_models = {
    openai = {
        "gpt-image-1-mini",       -- fast (~15 s), cheapest (default)
        "gpt-image-1.5",
        "gpt-image-2",            -- flagship quality, slow (~60 s)
        "gpt-image-1",
        "chatgpt-image-latest",
    },
    xai = {
        "grok-imagine-image",          -- fast (~7 s) (default)
        "grok-imagine-image-quality",  -- higher quality (alias: grok-imagine-image-pro)
    },
    gemini = {
        "gemini-3.1-flash-image",  -- "Nano Banana" (default)
        "gemini-3-pro-image",
    },
}

-------------------------------------------------------------------------------
-- HELPER FUNCTIONS
-------------------------------------------------------------------------------

-- Get image-generation models for a provider (nil if unsupported)
function ModelLists.getImageModels(provider)
    return ModelLists._image_models[provider]
end

-- Get the default image-generation model for a provider (first in list)
function ModelLists.getDefaultImageModel(provider)
    local list = ModelLists._image_models[provider]
    return list and list[1]
end

-- Get sorted list of all provider names
function ModelLists.getAllProviders()
    local providers = {}
    for provider, _ in pairs(ModelLists) do
        -- Skip internal tables (start with _) and functions
        if type(ModelLists[provider]) == "table" and not provider:match("^_") then
            table.insert(providers, provider)
        end
    end
    table.sort(providers)
    return providers
end

--- Community-set membership (docs-based, not covered by the maintainer's keys/
--- pipeline yet — model_management_strategy.md "End-state REVISION 2").
function ModelLists.isCommunity(provider)
    return ModelLists._community[provider] == true
end

-- Check if a provider ID is a built-in provider
-- @param provider_id string - Provider ID to check
-- @return boolean
function ModelLists.isBuiltInProvider(provider_id)
    return ModelLists[provider_id] ~= nil and type(ModelLists[provider_id]) == "table"
end

-- Canonical tier ladder, most capable first. Fallback only ever DESCENDS this
-- list — frontier is reachable solely by asking for it explicitly.
local TIER_ORDER = {"frontier", "flagship", "standard", "fast", "ultrafast"}

-- Map legacy/unknown tier names onto the canonical ladder. The retired
-- "reasoning" tier (persisted quick_preset_tier values predate 2026-07-28)
-- resolves to flagship — deliberately NOT frontier, so no pick silently gets
-- more expensive than what the user chose.
-- @param tier string|nil
-- @return string - canonical tier name
function ModelLists.normalizeTier(tier)
    if tier == "reasoning" then return "flagship" end
    for _idx, t in ipairs(TIER_ORDER) do
        if t == tier then return tier end
    end
    return "standard"
end

-- One tier/provider lookup: user override (custom_models.lua tiers section,
-- item 18b — also how custom providers get tiers) first, curated second.
local function lookupTier(provider, tier)
    local ModelOverrides = require("koassistant_model_overrides")
    local override = ModelOverrides.tierOverride(provider, tier)
    if override then return override end
    local tier_map = ModelLists._tiers[tier]
    return tier_map and tier_map[provider] or nil
end

-- Get model for a specific tier and provider (with fallback)
-- @param provider string - Provider name
-- @param tier string - Tier name (frontier/flagship/standard/fast/ultrafast;
--                      legacy "reasoning" reads through to flagship)
-- @param fallback boolean - If true, falls back to next-cheaper tier (default: true)
-- @return string|nil - Model ID or nil
function ModelLists.getModelForTier(provider, tier, fallback)
    if fallback == nil then fallback = true end
    tier = ModelLists.normalizeTier(tier)

    -- Direct lookup
    local model = lookupTier(provider, tier)
    if model then return model end

    -- Fallback toward cheaper tiers
    if fallback then
        local start_idx = 1
        for i, t in ipairs(TIER_ORDER) do
            if t == tier then
                start_idx = i + 1
                break
            end
        end

        for i = start_idx, #TIER_ORDER do
            model = lookupTier(provider, TIER_ORDER[i])
            if model then return model end
        end
    end

    return nil
end

-- Resolve a speed-tier hint to a model (item 18e per-action tiers + the ⚡ Quick
-- preset's "fastest" mode — keep both consumers agreeing). "fastest" walks
-- ultrafast toward slower until the provider has a listed tier — NEVER frontier
-- (opt-in only); a named tier is EXACT (maintainer 2026-08-14): a tier is a
-- class pick, not a direction — "fast" silently degrading to ultrafast is a
-- quality cliff nobody asked for, and "fastest" already exists as the explicit
-- walk. A miss returns nil → callers keep the current model (or the pinned
-- provider's default under a provider pin). Goes through the tier override
-- layer, so custom_models.lua placements work (incl. custom providers).
-- @param provider string
-- @param tier string - "fastest" or a tier name (flagship/standard/fast/ultrafast)
-- @return string|nil model id
function ModelLists.resolveTierModel(provider, tier)
    if not provider or not tier then return nil end
    if tier == "fastest" then
        for _idx, t in ipairs({ "ultrafast", "fast", "standard", "flagship" }) do
            local m = ModelLists.getModelForTier(provider, t, false)
            if m then return m end
        end
        return nil
    end
    -- Strict: only canonical tier names resolve. getModelForTier would
    -- normalizeTier() garbage to "standard" — a silent model switch on a typo'd
    -- or sentinel value ("none") is worse than doing nothing.
    local canonical = false
    for _idx, t in ipairs(TIER_ORDER) do
        if t == tier then
            canonical = true
            break
        end
    end
    if not canonical then return nil end
    return ModelLists.getModelForTier(provider, tier, false)
end

-- Global-aware tier resolution (tier GUI phase 2, docs/tier_gui_plan.md): like
-- resolveTierModel, but each step of the walk consults the GLOBAL tier pin
-- first (ModelOverrides.globalTierPin — a usable pin names provider+model
-- regardless of the active provider), then the active provider's own ladder.
-- Returns provider, model — the provider differs from the input when a pin
-- fired; callers dispatch cross-provider via the model-override rebase (the ⚡
-- session-pick machinery). "fastest" still never touches frontier; named tiers
-- are EXACT like resolveTierModel's (maintainer 2026-08-14 — one step: pin for
-- that tier, else the provider's own placement, else nil; garbage/sentinels
-- resolve to nothing as before).
-- resolveTierModel itself stays ladder-only — it answers "what is THIS
-- provider's tier model", which the tier GUI's default rows depend on.
-- @return string|nil provider, string|nil model
function ModelLists.resolveTierTarget(provider, tier)
    if not provider or not tier then return nil end
    local ModelOverrides = require("koassistant_model_overrides")
    local function step(t)
        local pp, pm = ModelOverrides.globalTierPin(t)
        if pp then return pp, pm end
        local m = lookupTier(provider, t)
        if m then return provider, m end
        return nil
    end
    if tier == "fastest" then
        for _idx, t in ipairs({ "ultrafast", "fast", "standard", "flagship" }) do
            local p2, m2 = step(t)
            if p2 then return p2, m2 end
        end
        return nil
    end
    local canonical = false
    for _idx, t in ipairs(TIER_ORDER) do
        if t == tier then
            canonical = true
            break
        end
    end
    if not canonical then return nil end
    return step(tier)
end

-- Get the tier for a given model
-- @param provider string - Provider name
-- @param model_id string - Model ID
-- @return string - Tier name (defaults to "standard")
function ModelLists.getTierForModel(provider, model_id)
    -- Through lookupTier so GUI/custom_models.lua placements label correctly;
    -- TIER_ORDER walk also makes a model placed in two tiers deterministic
    -- (the old pairs() walk over _tiers was undefined-order).
    for _idx, tier_name in ipairs(TIER_ORDER) do
        if lookupTier(provider, tier_name) == model_id then
            return tier_name
        end
    end
    return "standard"
end

-- Get tier info (description and typical use)
-- @param tier string - Tier name
-- @return table|nil - {description, typical_use}
function ModelLists.getTierInfo(tier)
    return ModelLists._tier_info[tier]
end

-- Get documentation URLs for a provider
-- @param provider string - Provider name
-- @return table|nil - {api_list, docs, curl, ...}
function ModelLists.getDocs(provider)
    return ModelLists._docs[provider]
end

--- Decide what to do with a persisted `features.model` when the provider's default may have
--- moved on, or when the id no longer exists (defaults_propagation_plan.md §3, gaps G2/G3).
--- PURE: no settings/UI access, so it is unit-testable and safe to call on every load.
---
--- Decision order:
---   nil/empty model           -> keep    (nil already resolves to the provider default)
---   explicit user pick        -> keep    (never clobber a deliberate choice)
---   no current default        -> keep    (custom providers may have none)
---   already the default       -> keep
---   matches a shipped default -> refresh (it was auto-baked by a provider switch)
---   not a known valid id      -> reset   (stale id: would 404; G3 safety net)
---   otherwise                 -> keep    (user picked a non-default model at some point)
---
--- @param opts table {
---   model            string|nil  persisted features.model
---   current_default  string|nil  the provider's default today
---   explicit         boolean|nil user explicitly picked a model for this provider
---   known_models     table|nil   valid ids for this provider (built-ins + user customs)
---   shipped_defaults table|nil   ids ever shipped as this provider's default
--- }
--- @return string action  "keep" | "refresh" | "reset"
--- @return string|nil new_model  the id to move to (nil when action == "keep")
function ModelLists.resolveModelRefresh(opts)
    opts = opts or {}
    local model = opts.model
    if type(model) ~= "string" or model == "" then return "keep", nil end
    if opts.explicit then return "keep", nil end

    local current_default = opts.current_default
    if type(current_default) ~= "string" or current_default == "" then return "keep", nil end
    if model == current_default then return "keep", nil end

    for _idx, id in ipairs(opts.shipped_defaults or {}) do
        if id == model then return "refresh", current_default end
    end

    -- Unknown ids are only treated as stale when we actually have a list to judge against;
    -- an empty/absent list must never trigger a reset (custom providers, unseeded callers).
    local known = opts.known_models
    if type(known) == "table" and #known > 0 then
        for _idx, id in ipairs(known) do
            if id == model then return "keep", nil end
        end
        return "reset", current_default
    end

    return "keep", nil
end

return ModelLists
