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
        -- Order (maintainer 2026-10-11): the default first, then the other tier
        -- picks (flagship, frontier, fast), then one previous version per line.
        "claude-sonnet-5-5",            -- default + standard (2026-09-28, $2/$10, balanced); adaptive thinking on, off = "between_tools", no forced tool calls
        "claude-opus-5-5",              -- flagship: deep reasoning (2026-09-22, $4/$20); thinking on, NO disable, no forced tool calls
        "claude-fable-5-1",             -- frontier: most capable (2026-09-01, $10/$50); thinks only when asked, no forced tool calls
        "claude-haiku-5-5",             -- fast + ultrafast (2026-10-07, $0.10/$0.50 up to 100K prompt tokens, 5x above); adaptive thinking on, disable ok
                                        -- (replaces claude-haiku-4-5-20251001, still served: saved picks keep working)
        -- Previous generation, one per line. Still served, so an explicit pick of an id
        -- that left the picker is kept (resolveModelRefresh); a default baked long ago
        -- moves to today's default. Left 2026-10-11: claude-sonnet-4-6, claude-opus-4-8.
        "claude-sonnet-5",              -- previous default; adaptive thinking on, disable ok, rejects sampling params
        "claude-opus-5",                -- previous flagship (2026-07-24, $5/$25); adaptive thinking on, disable ok, rejects sampling
        "claude-fable-5",               -- previous frontier; adaptive thinking ALWAYS-ON (no disable), rejects sampling, premium price
    },

    openai = {
        -- Order (maintainer 2026-10-11): the default first, then the other tier
        -- picks (flagship, frontier, fast + ultrafast), then one previous version
        -- per line. GPT-5.6 (sol > terra > luna): reasoning opt-in (OFF by default;
        -- none..xhigh, NO max), 128K output, ~1M context, temperature=1.0 only, tools
        -- + web search (Responses API). GPT-6 (astra > sol > luna, 2026-09; 6.1 Sol
        -- 2026-09-29): REASON BY DEFAULT (medium; sol and luna turn off with "none",
        -- astra and 6.1 cannot), otherwise the same shape (probed 2026-09-28 and
        -- 2026-09-30). No GPT-6 terra exists: 5.6 terra stays the balanced default.
        -- Prices per M tokens from OpenRouter's catalog, 2026-10-11.
        "gpt-5.6-terra",                -- default + standard: balanced ($2/$12)
        "gpt-6.1-sol",                  -- flagship ($2/$10, like 6-sol); cannot turn reasoning off
        "gpt-6-astra",                  -- frontier ($10/$50); cannot turn reasoning off
        "gpt-6-luna",                   -- fast + ultrafast: the cheapest OpenAI model ($0.10/$0.50; half of 5.6-luna, below 5.4-nano); off = "none"
        -- Previous generation, one per line. Still served on the API, so an explicit
        -- pick of an id that left the picker is kept (resolveModelRefresh). Left
        -- 2026-10-11: gpt-5.6-sol, gpt-5.5, gpt-5.4, gpt-5.4-mini, gpt-5.4-nano.
        "gpt-6-sol",                    -- previous sol ($2/$10); turns reasoning off
        "gpt-5.6-luna",                 -- previous luna ($0.20/$1.20); reasoning opt-in
        -- NOTE: *-pro variants are v1/responses only (not chat-completions): excluded.
    },

    openai_codex = {
        -- OpenAI ChatGPT subscription (Codex OAuth) reuses the same curated
        -- subscription model slugs as direct OpenAI, but authenticates with
        -- device-code OAuth against ChatGPT's Codex backend. Same order as the
        -- direct list: the default, the tier picks, one previous version per line.
        -- Probed live on a FREE ChatGPT account on 2026-08-15 and 2026-10-11
        -- (the handler's exact wire): terra, 6-luna, 5.6-luna and 5.5 answer;
        -- every sol, astra and the 5.4 ids are refused ("not supported when
        -- using Codex with a ChatGPT account") with a clear error, which the
        -- plugin follows with the plan tip (ModelConstraints.HINT_HEADS.plan).
        -- Refused slugs stay listed (paid plans serve more: OpenAI's Codex
        -- models page gives 6-sol and 6.1-sol to Plus and up). The default and
        -- the standard, fast and ultrafast picks use free-served slugs only
        -- (maintainer ruling 2026-08-15); flagship and frontier may need a paid
        -- plan (maintainer 2026-10-11: free users should not expect flagship,
        -- and the refusal names the plan). Gone from the Codex backend on every
        -- plan and moved to _retired: the 5.4 ids (2026-08-31) and 5.5
        -- (OpenAI's date 2026-10-14; retired three days early, B417). 5.6-sol
        -- left the picker 2026-10-11 (one previous sol is enough).
        "gpt-5.6-terra",                -- default + standard; served on free accounts
        "gpt-6.1-sol",                  -- flagship; refused on free accounts (Plus and up, per OpenAI's Codex models page)
        "gpt-6-astra",                  -- frontier; refused on free accounts
        "gpt-6-luna",                   -- fast + ultrafast; served on free accounts (OpenAI's pick for Free and Go)
        "gpt-6-sol",                    -- previous sol; refused on free accounts (Plus and up)
        "gpt-5.6-luna",                 -- previous luna; served on free accounts
    },

    deepseek = {
        -- DeepSeek V4 (current generation, 1M context, thinking on by default)
        "deepseek-flash",               -- standard/fast (default). DeepSeek's list renamed
                                        -- deepseek-v4-flash to this 2026-09 (the old id still
                                        -- answers, served as deepseek-flash); probed 2026-09-28
        "deepseek-v4-pro",              -- flagship + reasoning
    },

    gemini = {
        -- Gemini 3.x (current generation)
        "gemini-3.8-flash",             -- newest flash (default since 2026-09-28; same price as 3.7,
                                        -- battery 2026-09-28: default thinking ON, effort
                                        -- low/medium/high, MINIMAL rejected, tools + replay +
                                        -- streaming green, grounding on the paid key, answers
                                        -- on a free key)
        "gemini-4-argon",               -- frontier (GA 2026-10-13, paid only: $2/$10 to 2026-11-30, then
                                        -- $4/$20). Battery 2026-10-14: thinks by default, low/medium/high,
                                        -- MINIMAL rejected, a budget of 0 does not turn it off; tools,
                                        -- replay, streaming and grounding green
        "gemini-3.5-flash-lite",        -- fast/ultrafast (newest lite)
        -- Since 2026-10-08 Google answers gemini-3.7-flash with 3.8-flash and gemini-3.5-flash
        -- with 3.6-flash (the response's modelVersion says so): both left the picker and
        -- saved picks move via _retired.
        "gemini-3.6-flash",             -- previous flash
        "gemini-3.1-pro-preview",       -- previous frontier, reasoning (paid only; full battery green
                                        -- on a paid key 2026-08-15: effort low/medium/high, no
                                        -- disable, tools + grounding work)
        "gemini-3.1-flash-lite",        -- previous lite
        -- The 2.5 models left the picker 2026-10-14 (maintainer: one previous version per
        -- line). Google serves them only to accounts that used them before (2026-09-18);
        -- an explicit pick is kept (resolveModelRefresh) and Fetch models adds them back.
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
        "qwen/qwen3.8-27b",                             -- replaced qwen3.6-27b 2026-09-14; reasoning off by default, free OTPM 1000
        -- (llama-3.3-70b-versatile + llama-3.1-8b-instant — the former default
        -- and fast picks — deprecated by Groq effective 2026-08-16, vendor-
        -- recommended replacements = the two gpt-oss models above (T9 refresh
        -- 2026-08-14). qwen/qwen3-32b + meta-llama/llama-4-scout deprecated
        -- 2026-07-17. Removed from the picker; constraint entries kept for
        -- users with the model still persisted in settings.)
        -- (groq/compound + compound-mini decommissioned by Groq 2026-09-21, no
        -- vendor replacement; saved picks move to the gpt-oss pair via _retired.)
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
        -- Grok 4.7 (2026-09-21; 500K context, $1.60/$4.80 — cheaper than 4.6.
        -- Probed 2026-09-28: the 4.6 shape — effort minimal..xhigh, "none" and "max"
        -- REJECTED, thinks by default, temp free, tools + forced + replay + web green)
        "grok-4.7",                     -- flagship (default) + reasoning
        -- Grok 4.6 (flagship 2026-08-12 to 2026-09-28; 500K context, $2/$6.
        -- Probed 2026-08-14: effort minimal..xhigh, effort "none"
        -- REJECTED (cannot disable reasoning — unlike 4.5/4.3), temp free, tools OK)
        "grok-4.6",                     -- previous flagship + reasoning
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

        -- Anthropic and OpenAI follow their direct lists' order (maintainer 2026-10-11,
        -- applied here 2026-10-14): the current models first, then one previous version
        -- per line. Left the picker 2026-10-14, still served (a saved pick is kept):
        -- claude-sonnet-4.6, claude-opus-4.8, gpt-5.6-sol, gpt-5.5, gpt-5.4, gpt-5.4-mini.

        -- Anthropic
        "anthropic/claude-sonnet-5.5",  -- default (2026-09-28; battery 2026-09-29); reasoning cannot be turned off here, Minimal = low
        "anthropic/claude-opus-5.5",    -- deep reasoning flagship (2026-09-22; battery 2026-09-28)
        "anthropic/claude-fable-5.1",   -- most capable / frontier (2026-09-01; battery 2026-09-28)
        "anthropic/claude-haiku-5.5",   -- fast (2026-10-07; battery 2026-10-08: reasons by default, turns off here)
        "anthropic/claude-sonnet-5",    -- previous default
        "anthropic/claude-opus-5",      -- previous flagship (a -fast variant exists at 2x price; not listed)
        "anthropic/claude-fable-5",     -- previous frontier

        -- OpenAI (gpt-6: astra > sol > luna, reason by default; battery 2026-09-28;
        -- gpt-5.6: sol > terra > luna)
        "openai/gpt-5.6-terra",
        "openai/gpt-6.1-sol",           -- cannot turn reasoning off (battery 2026-09-30)
        "openai/gpt-6-astra",
        "openai/gpt-6-luna",
        "openai/gpt-6-sol",             -- previous sol
        "openai/gpt-5.6-luna",          -- previous luna
        -- OpenAI open-weight (Apache 2.0; ids live-verified on the catalog
        -- 2026-08-04, a 20b ":free" variant also exists)
        "openai/gpt-oss-120b",
        "openai/gpt-oss-20b",

        -- Google
        "google/gemini-3.8-flash",      -- battery 2026-09-28 (reasoning mandatory here)
        "google/gemini-4-argon",        -- battery 2026-10-14 (reasoning mandatory here; $2/$10 to 2026-11-30)
        "google/gemini-3.6-flash",
        "google/gemini-3.5-flash-lite",
        -- google/gemini-3.7-flash and 3.5-flash left the picker 2026-10-14: Google's own API
        -- answers them with 3.8 and 3.6. They still answer here (AI Studio and Vertex
        -- endpoints), so a saved pick is kept rather than moved.

        -- DeepSeek
        "deepseek/deepseek-v4-pro",
        "deepseek/deepseek-v4.1-flash",                 -- 2026-09-10; battery 2026-09-28
        "deepseek/deepseek-v4-flash",

        -- Z.AI
        "z-ai/glm-5.3",                                 -- battery 2026-09-28 (reasoning mandatory here)

        -- xAI Grok
        "x-ai/grok-4.7",                                -- probed 2026-09-28 (reasoning mandatory here, forced tools OK)
        "x-ai/grok-4.3",
        "x-ai/grok-4.20",

        -- Meta Llama
        "meta-llama/llama-3.3-70b-instruct",

        -- Mistral
        "mistralai/mistral-large-2512",
        "mistralai/mistral-medium-3.1",

        -- Qwen (qwen3-max and qwen3-235b-a22b answer 404 "deprecated on Oct 9, 2026";
        -- saved picks move via _retired)
        "qwen/qwen3.8-max-0902",                        -- battery 2026-10-14 (reasoning mandatory here, forced tools OK)
        "qwen/qwen3.8-flash",                           -- battery 2026-09-28 (forced tool calls refused: auto)

        -- Perplexity (built-in web search)
        "perplexity/sonar-pro",
        "perplexity/sonar-reasoning-pro",
        "perplexity/sonar",

        -- Other notable (batteries 2026-09-28; they replace kimi-k2-thinking and
        -- minimax-m2.1, which reasoned by default under an off-by-default row)
        "moonshotai/kimi-k3",
        "minimax/minimax-m3",
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

        -- Anthropic (the 5.x successors verified in the catalog 2026-09-29; it spells
        -- Fable 5.1 with a dot, unlike Sonnet/Opus 5.5)
        "anthropic/claude-sonnet-5-5",
        "anthropic/claude-opus-5-5",    -- deep-reasoning flagship
        "anthropic/claude-fable-5.1",   -- frontier
        "anthropic/claude-sonnet-5",
        "anthropic/claude-opus-5",      -- previous flagship (no dotted version, so the hyphenation rule is moot)
        "anthropic/claude-fable-5",     -- previous frontier (verified in catalog 2026-07-28)
        "anthropic/claude-sonnet-4-6",
        "anthropic/claude-haiku-5-5",   -- in the catalog 2026-10-08 (hyphenated, like Sonnet/Opus 5.5)

        -- Google
        "google/gemini-2.5-flash",

        -- DeepSeek
        "deepseek/deepseek-v4-pro",

        -- xAI Grok
        "xai/grok-4.3",
    },

    qwen = {
        -- Qwen3.8 (2026-08/09, 1M context). Probed 2026-09-28: reason by default
        -- (enable_thinking=false turns it off on the wire, api_params.qwen_thinking, B368), temp
        -- [0, 2), 128K out; forced tool calls refused while thinking, so no tools.
        "qwen3.8-max",                  -- default + flagship (since 2026-10-14)
        "qwen3.8-flash",
        "qwen3.5-plus",                 -- standard
        "qwen3.5-flash",                -- fast + ultrafast
        -- Gone 2026-10-14 (saved picks move via _retired): qwen3-max and qwen3-coder-plus
        -- answer 404 "Model not exist" (Alibaba's retirement of 2026-10-10); qwen-turbo
        -- left the list and answers only 429 "exceeded your current request limit".
    },

    kimi = {
        -- Kimi K2.6 (current, multimodal). Probed on the INTERNATIONAL
        -- platform 2026-08-15: it serves ONLY kimi-k2.6 (+ a k2.7-code slug),
        -- thinks by default, and temperature is mode-locked (see
        -- model_constraints kimi note). The -thinking and -turbo ids 404
        -- there ("Not found ... or Permission denied") but stay listed for
        -- CN-platform users (region split; codex-precedent: never strip
        -- models that other plans/regions may serve — the error is clear).
        "kimi-k2.6",                    -- default (the id served on both platforms)
        -- Kimi K3 (2026-07, 1M context; international platform, probed 2026-09-28):
        -- thinks by default, disable works, temperature 1 only while thinking,
        -- tools + forced tool_choice + replay green.
        "kimi-k3",                      -- flagship
        "kimi-k2.6-thinking",           -- reasoning (CN platform)
        "kimi-k2-turbo-preview",        -- fast (CN platform)
    },

    together = {
        -- DeepSeek V4 (current)
        "deepseek-ai/DeepSeek-V4-Pro-0813",                  -- default + flagship; the bare -Pro slug left the catalog (2026-09-28, -30), only this dated id is listed (the Flash-0731 precedent; unverified by request: our key has no credits)
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
        "accounts/fireworks/models/glm-5p3",                         -- flagship (thinking-only)
        "accounts/fireworks/models/glm-5p3-flash",
        "accounts/fireworks/models/kimi-k3",
        "accounts/fireworks/models/deepseek-v4p1-flash",             -- fast deepseek (reasoning can turn off)
        "accounts/fireworks/models/minimax-m3",
        "accounts/fireworks/models/qwen3p8-max",
        -- (2026-09-28: deepseek-v4-pro, deepseek-v4-flash-0731, kimi-k2p6 and
        -- gpt-oss-20b stopped serving — still LISTED but "not found ... not
        -- deployed" on request; deepseek-v4-pro-0813 too. Listed != served here.
        -- The five ids above qwen3p8-max probed green on the full battery.
        -- 2026-09-29: glm-5p2 the same, found by the recheck; glm-5p3 answers.)
        -- (Dead ids dropped 2026-08-15, absent from the live catalog:
        -- deepseek-r1, qwen3-235b-a22b, kimi-k2-thinking. Earlier removals
        -- per Fireworks' changelog, T9 refresh 2026-08-14: llama-v3p3-70b
        -- deprecated 2026-05-14 -> gpt-oss-120b; glm-5 -> glm-5p2, itself retired 2026-09-29.)
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
        "MiniMax-M3",                                        -- replaced MiniMax-M2.7 in the catalog by 2026-10-14
                                                             -- (1M ctx; catalog only: the key is refused)
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

    -- Perplexity (Agent API, B078): a gateway to its own Sonar and other
    -- companies' models (/v1/models, 49 ids on 2026-09-28; "Fetch models"
    -- brings the rest). With web search on each model answers inside the fast
    -- preset, which searches and cites (koassistant/api/perplexity.lua); every
    -- id below searched and cited that way (probed 2026-09-28). Presets are not
    -- models, so none is listed (a typed one still works). Meta router: NO tier
    -- placements (maintainer ruling 2026-09-28, after preset tiers read as
    -- "low: flagship").
    perplexity = {
        "perplexity/sonar",             -- default: Perplexity's own model (every retired Sonar id lands here)
        "openai/gpt-6-luna",            -- the model Perplexity's own fast/low/medium presets run
        "openai/gpt-6-sol",
        "openai/gpt-6.1-sol",           -- searched and cited 2026-09-30; takes no temperature
        "anthropic/claude-sonnet-5-5",  -- replaces claude-sonnet-5 (same price; searched and cited 2026-09-29)
        "google/gemini-3.8-flash",
        "xai/grok-4.7",
    },

    zai = {
        -- GLM-5.x (200K context)
        "glm-5.2",                      -- default (released 2026-06-16; thinking can be turned off)
        -- GLM-5.3 (2026-08; 1M+ context). Probed 2026-09-28: thinking ALWAYS on (effort
        -- low/high/max rides top-level reasoning_effort, not wired yet), temp free,
        -- 128K out, tools + forced tool_choice + replay green.
        "glm-5.3",                      -- flagship
        "glm-5.3-flash",                -- cheap ($0.15/$0.50)
        "glm-5.3-flashx",
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
        "nvidia/nemotron-3.5-super-vl-120b-a12b",   -- default since 2026-10-20: the full battery green that day (reasoning on by default, every effort level, forced tool calls + the replay once, SSE, 1M out)
        "nvidia/nemotron-3-ultra-550b-a55b",
        -- nvidia/nemotron-3-super-120b-a12b, the default from 2026-08-20, answered
        -- 404 "Function not found for account" on 2026-10-20 (three requests, fine
        -- the day before, the other three ids answering): listed, not served, the
        -- same way nemotron-nano-3-30b-a3b went. Saved picks move via _retired.
        "nvidia/nemotron-3-nano-omni-30b-a3b-reasoning", -- ~1.2s 2026-08-29 (effort low/none ok, SSE ok, 65536 ok; forced tools 503 ~1 in 3, so no tools grant); answered 2026-09-28 15:47 then HUNG (3 x 90 s) at 16:40 while the rest answered in 0-2 s, so it lost the fast/ultrafast picks
        "openai/gpt-oss-20b",                       -- fast + ultrafast (1 s, 2026-09-28); reasons by default, 131072 out
        -- RETIRED BY NVIDIA 2026-09-01 (HTTP 410 Gone, recheck 2026-09-28):
        --   nvidia/nemotron-3-nano-30b-a3b (was the ultrafast pick and the only
        --   tools grant), openai/gpt-oss-120b, minimaxai/minimax-m3. Listed but NOT
        --   served (404 "Function not found"): nvidia/nemotron-nano-3-30b-a3b.
        -- RETIRED BY NVIDIA (HTTP 410 Gone, end of life 2026-08-26/28, re-probed
        -- 2026-08-29; the reader-visible "HTTP 400/404" report on 0.21.2):
        --   nvidia/nvidia-nemotron-nano-9b-v2, nvidia/llama-3.3-nemotron-super-49b-v1.5,
        --   meta/llama-3.1-70b-instruct, meta/llama-3.1-8b-instruct,
        --   stepfun-ai/step-3.7-flash, nvidia/nemotron-mini-4b-instruct
        -- PROBED 2026-08-29 AND WITHHELD (model_audit has no nvidia adapter yet;
        -- legs run by hand):
        --   moonshotai/kimi-k3 -- answers, but 429 on every follow-up call even
        --     paced 20s apart (roughly one request per minute on our tier).
        --   mistralai/mistral-nemotron -- HTTP 500 on 5 of 8 calls.
        --   deepseek-ai/deepseek-v4-flash-0731 -- 15-45s for a one-word answer,
        --     one 529; deepseek-v4-pro-0813 still hangs.
        --   2026-09-28: moonshotai/kimi-k3, z-ai/glm-5.3, z-ai/glm-5.3-flash and
        --     deepseek-ai/deepseek-v4.1-flash never answered the first request
        --     (read timeout after 60 s, three tries each).
        -- EXCLUDED, do not re-add without re-probing (device round 2026-08-20):
        --   nvidia/nemotron-3.5-lightning-30b-a3b -- reasoning never terminates on
        --     constraint-shaped prompts ("translate this", "answer in N words"):
        --     content comes back byte-identical to reasoning_content with no answer
        --     after it, on every sample. Only reasoning_effort="none" works, and our
        --     default stance sends nothing, so reasoning is ON by default.
        --     Re-probed 2026-09-28: the full battery is green (forced tool calls
        --     3/3), but both constraint prompts still hang past 60 s. Still out.
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
    cheaperinference = {
        -- Bare model ids, as its public catalog spells them
        -- (https://api.cheaperinference.com/public/models, no key needed).
        "gpt-5.4-mini",                             -- catalog 2026-10-28
        "claude-sonnet-5",                          -- catalog 2026-10-28
    },
    -- OpenCode (#107, added 2026-09-05; CURATED: keyed, /models on both plans
    -- read the same day, every id below GREEN on the full model_audit battery
    -- — reasoning ladder, tools + forced + none, two-round replay, SSE).
    -- Only ids that answer on the OpenAI CHAT door and exist on BOTH the Zen
    -- and the Go list. GPT ids (Responses door), Claude/Gemini ids (Messages
    -- door) and grok-4.6 answer 500 on this wire and are left out on purpose;
    -- "Fetch models" will import them and they fail politely. Meta router:
    -- NO tier placements (the 2026-08-17 openrouter/requesty ruling).
    opencode = {
        -- 2026-10-20 (the maintainer's new Zen key): the console's Models tab
        -- decides which models a workspace may use, and a new workspace has the
        -- older versions OFF. Its keyed /v1/models then lists 44 of the public
        -- catalog's 85 ids, and a request for any other id answers "Upstream
        -- request failed: Model access is disabled". The list below = the
        -- open-weight ids a new workspace serves, every one green on the full
        -- battery that day (eight batteries, about half a cent). deepseek-v4-flash
        -- (the default since 2026-09-05), glm-5.2, glm-5.1, minimax-m2.7,
        -- minimax-m2.5, qwen3.5-plus and qwen3.8-max left the picker: off on a
        -- new workspace, still served where a workspace enables them, so an
        -- explicit pick is kept and the baked default moves via _shipped_defaults
        -- ("Fetch models" lists what a workspace serves).
        "deepseek-v4.1-flash",                      -- default: the v4-flash line's current model; ladder none..max, tools, SSE
        "deepseek-v4-pro",
        "glm-5.3-flash",
        "glm-5.3",
        "kimi-k3",                                  -- effort low/high/max on this door (minimal, medium, xhigh refused 2026-10-20)
        "qwen3.8-flash",                            -- B368 2026-10-14: book tools without a forced call
        "minimax-m3",
        "qwen3.6-plus",                             -- effort low..xhigh, off = none; rejects temperature 2.0
        -- Earlier sweeps (2026-09-05, 2026-09-28) left out: the Muse and Grok ids
        -- (server errors on this wire), kimi-k2.7-code (not found), the free ids
        -- (answer only inside OpenCode's own client), ling-3.0-flash-fin-free
        -- (finance model), jev-1.13 ("does not support this protocol" on the
        -- chat door). Stopped serving on this door (saved picks move via
        -- _retired): glm-5 ("deprecated, use glm-5.3"), kimi-k2.6 + kimi-k2.5
        -- ("Endpoint is unavailable"), deepseek-v4-flash-vision-exp (no chat
        -- route), nemotron-3.5-lightning-free.
    },
    -- OpenCode Go (the subscription catalog; CURATED 2026-09-05: all 35
    -- /zen/go/v1/models ids ran the model_audit battery on the Go endpoint
    -- with the maintainer's Zen key — the endpoint answers it without a Go
    -- subscription). Order = default first, then the fully green models,
    -- then reasoning-only (no forced tool calls on this endpoint), then the
    -- OPT-IN ids (maintainer 2026-09-05: listed, never default — they fail
    -- until the reader opts in at the OpenCode console). Left out: ids this
    -- wire does not serve (gpt-5.6-luna, grok-4.6/4.5, omen-alpha,
    -- kimi-k2.7-code, kimi-k2.5, minimax-m2.7, mimo-v2-pro/omni, hy3-preview).
    -- deepseek-v4-flash and deepseek-v4-flash-vision-exp left Go's catalog by
    -- 2026-10-20 (retired here, to deepseek-v4.1-flash, which the catalog
    -- lists in their place).
    -- Meta router: NO tier placements. Facts per id: koassistant/request/model_constraints.lua.
    opencode_go = {
        "kimi-k3",                                  -- default: every battery leg green, full reasoning ladder incl. off
        "hy4-preview",                              -- green; stated output ceiling 1M
        "longcat-2.0",
        "minimax-m3",                               -- green; reasoning arrives as <think> tags (parser strips)
        "glm-5.3-flash",                            -- green; effort low/high/max only on this endpoint
        "glm-5.3",
        "glm-5.2",
        "mimo-v2.5-pro",
        "mimo-v2.5",
        "hy3",
        -- (2026-09-28, answered even without a Go subscription: glm-5.1, minimax-m2.5,
        -- qwen3.7-max, qwen3.6-plus and kimi-k2.6 "deprecated, use ...", glm-5 and
        -- qwen3.5-plus "unavailable"; saved picks move via _retired.)
        "qwen3.8-max",                              -- book tools without a forced call (B368; unverified here)
        "qwen3.8-flash",                            -- same
        "qwen3.7-plus",                             -- same
        "deepseek-v4.1-flash",                      -- the v4-flash line's successor, in Go's catalog 2026-10-20; unprobed here (no Go subscription): no grants, no profile
        "deepseek-v4-pro",                          -- OPT-IN (China-hosted; enable in the OpenCode console)
        "muse-spark-1.3-contributor",               -- OPT-IN (data-collection consent)
        "muse-spark-1.2-contributor",               -- OPT-IN (same)
    },
    -- A2Agent (#108, added 2026-09-27; CURATED: donated key, /models read the
    -- same day, every id below ran the full model_audit battery and a live
    -- request through this handler). A gateway to DeepSeek, GLM, Kimi, Qwen
    -- and MiniMax. Seed = the newest model per family; "Fetch models" brings
    -- the rest (22 ids). Meta router: NO tier placements. Facts per id:
    -- koassistant/request/model_constraints.lua.
    a2agent = {
        "deepseek-v4-flash",                        -- default: the cheapest id with tools + a reasoning switch
        "deepseek-v4-pro",
        "deepseek-v4.1-flash",
        "glm-5.3",
        "glm-5.3-flash",
        "kimi-k3",
        "qwen3.8-max",                              -- book tools without a forced call (refused while thinking; B368)
        "qwen3.8-flash",                            -- same
        "MiniMax-M3",                               -- reasoning arrives as <think> tags (parser strips)
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
        -- (groq PROMOTED 2026-09-07: keyed with a reader's free key (#106),
        -- discovery + the full battery green on all 4 seed ids; tier rows kept.)
        together = true, sambanova = true,
        requesty = true, doubao = true,
        -- M1 additions (ex hosted presets)
        cerebras = true, minimax = true, deepinfra = true, novita = true,
        hyperbolic = true, nebius = true, chutes = true, featherless = true,
        vercel = true,
        -- later community additions
        cheaperinference = true,
        -- opencode: CURATED from day one (2026-09-05, #107): keyed + battery
        -- green on every seed id; a meta router, so no tier placements.
        -- a2agent: CURATED from day one (2026-09-27, #108), same terms.
    },

    ---------------------------------------------------------------------------
    -- TIER MAPPINGS
    -- Maps tier -> provider -> recommended model_id
    -- Tiers: frontier > flagship > standard > fast > ultrafast
    --
    -- The old "reasoning" tier was RETIRED 2026-07-28 (item 19d): reasoning is a
    -- per-model AXIS now (koassistant/request/model_constraints.lua profiles), not a price rung —
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
        anthropic  = { "claude-sonnet-5-5", "claude-sonnet-5", "claude-sonnet-4-6", "claude-sonnet-4-5-20250929" },
        openai     = { "gpt-5.6-terra", "gpt-5.5", "gpt-5.4", "gpt-5.2" },
        openai_codex = { "gpt-5.6-terra", "gpt-5.5", "gpt-5.4" },
        gemini     = { "gemini-3.8-flash", "gemini-3.7-flash", "gemini-3.6-flash", "gemini-3.5-flash", "gemini-2.5-flash", "gemini-3-flash-preview" },
        deepseek   = { "deepseek-flash", "deepseek-v4-flash", "deepseek-v4-pro", "deepseek-chat" },
        ollama     = { "llama4", "llama3.3" },
        groq       = { "openai/gpt-oss-120b", "llama-3.3-70b-versatile" },
        mistral    = { "mistral-large-latest" },
        xai        = { "grok-4.7", "grok-4.6", "grok-4.5", "grok-4.3", "grok-4.20-beta-0309-non-reasoning", "grok-4-1-fast-non-reasoning" },
        openrouter = { "anthropic/claude-sonnet-5.5", "anthropic/claude-sonnet-5", "anthropic/claude-sonnet-4.6", "anthropic/claude-sonnet-4.5" },
        requesty   = { "openai/gpt-4o-mini" },
        qwen       = { "qwen3.8-max", "qwen3-max" },
        kimi       = { "kimi-k2.6", "kimi-k2.5", "kimi-k2-0905-preview" },
        together   = { "deepseek-ai/DeepSeek-V4-Pro-0813", "deepseek-ai/DeepSeek-V4-Pro", "meta-llama/Llama-4-Maverick-17B-128E-Instruct-FP8" },
        fireworks  = { "accounts/fireworks/models/gpt-oss-120b", "accounts/fireworks/models/deepseek-v4-pro", "accounts/fireworks/models/llama4-maverick-instruct-basic" },
        sambanova  = { "gpt-oss-120b", "Llama-4-Maverick-17B-128E-Instruct", "Meta-Llama-4-Maverick-17B-128E-Instruct" },
        cohere     = { "command-a-plus-05-2026", "command-a-03-2025" },
        doubao     = { "doubao-seed-2.0-pro-32k", "doubao-1.8-pro-32k" },
        perplexity = { "perplexity/sonar", "fast", "sonar-pro", "sonar" },
        zai        = { "glm-5.2", "glm-5.1", "glm-5-turbo", "glm-5" },
        opencode   = { "deepseek-v4.1-flash", "deepseek-v4-flash" },
        nvidia     = { "nvidia/nemotron-3.5-super-vl-120b-a12b", "nvidia/nemotron-3-super-120b-a12b" },
    },

    -- Ids a provider no longer serves, mapped to their replacement. The startup
    -- refresh moves a stored pick even when it was deliberate (the old id would
    -- fail), with a one-time notice; the request router (gpt_query) maps any other
    -- stored copy (a favorite, an action's or a tier's pin, a provider's preferred
    -- default) at the wire. Perplexity: the
    -- Sonar chat wire retired 2026-09-27; sonar lives on as perplexity/sonar on
    -- the Agent API, the other Sonar models are gone and land on it too (the
    -- default).
    _retired = {
        perplexity = {
            ["sonar"] = "perplexity/sonar",
            ["sonar-pro"] = "perplexity/sonar",
            ["sonar-reasoning-pro"] = "perplexity/sonar",
            ["sonar-deep-research"] = "perplexity/sonar",
        },
        -- Gone from Codex with ChatGPT sign-in on every plan: the 5.4 ids on 2026-08-31
        -- (OpenAI's Codex models page names 5.4 and 5.4-mini; nano was refused on the free
        -- account in both sweeps and is read as gone with its family) and 5.5 on 2026-10-14
        -- (retired here three days early, B417). Saved picks move to the slugs the free
        -- account serves (sweep 2026-10-11).
        openai_codex = {
            ["gpt-5.4"] = "gpt-5.6-terra",
            ["gpt-5.4-mini"] = "gpt-6-luna",
            ["gpt-5.4-nano"] = "gpt-6-luna",
            ["gpt-5.5"] = "gpt-5.6-terra",
        },
        -- Stopped serving 2026-09 (recheck 2026-09-28): NVIDIA's are HTTP 410 end of
        -- life; Fireworks' still list but answer "not found ... not deployed"; Groq
        -- decommissioned the compound pair 2026-09-21 (deprecations page).
        groq = {
            ["groq/compound"] = "openai/gpt-oss-120b",
            ["groq/compound-mini"] = "openai/gpt-oss-20b",
        },
        nvidia = {
            ["nvidia/nemotron-3-nano-30b-a3b"] = "openai/gpt-oss-20b",
            ["openai/gpt-oss-120b"] = "openai/gpt-oss-20b",
            -- 2026-10-20: the super-120b default stopped serving (404 "Function not
            -- found"); it and the earlier mapping onto it go to the 3.5 Super VL
            ["nvidia/nemotron-3-super-120b-a12b"] = "nvidia/nemotron-3.5-super-vl-120b-a12b",
            ["minimaxai/minimax-m3"] = "nvidia/nemotron-3.5-super-vl-120b-a12b",
        },
        opencode_go = {   -- the server's own "use ..." where we list it (kimi-k2.7-code is not curated here)
            ["glm-5.1"] = "glm-5.3",
            ["glm-5"] = "glm-5.3",
            ["minimax-m2.5"] = "minimax-m3",
            ["qwen3.7-max"] = "qwen3.8-max",
            ["qwen3.6-plus"] = "qwen3.7-plus",
            ["qwen3.5-plus"] = "qwen3.7-plus",
            ["kimi-k2.6"] = "kimi-k3",
            -- left Go's catalog by 2026-10-20; deepseek-v4.1-flash is listed in their place
            ["deepseek-v4-flash"] = "deepseek-v4.1-flash",
            ["deepseek-v4-flash-vision-exp"] = "deepseek-v4.1-flash",
        },
        opencode = {
            ["glm-5"] = "glm-5.3",
            ["kimi-k2.6"] = "kimi-k3",
            ["kimi-k2.5"] = "kimi-k3",
            -- their earlier replacement deepseek-v4-flash is off on a new workspace (2026-10-20)
            ["deepseek-v4-flash-vision-exp"] = "deepseek-v4.1-flash",
            ["nemotron-3.5-lightning-free"] = "deepseek-v4.1-flash",
        },
        fireworks = {
            ["accounts/fireworks/models/deepseek-v4-pro"] = "accounts/fireworks/models/glm-5p3",
            ["accounts/fireworks/models/deepseek-v4-flash-0731"] = "accounts/fireworks/models/deepseek-v4p1-flash",
            ["accounts/fireworks/models/kimi-k2p6"] = "accounts/fireworks/models/kimi-k3",
            ["accounts/fireworks/models/gpt-oss-20b"] = "accounts/fireworks/models/gpt-oss-120b",
            ["accounts/fireworks/models/glm-5p2"] = "accounts/fireworks/models/glm-5p3",   -- recheck 2026-09-29
        },
        -- Gone from Together's catalog 2026-09-28 (only the dated -0813 listed; catalog
        -- evidence, the key has no credits to confirm by request).
        together = {
            ["deepseek-ai/DeepSeek-V4-Pro"] = "deepseek-ai/DeepSeek-V4-Pro-0813",
        },
        -- Google answers these with another model since 2026-10-08 (changelog; the
        -- response's modelVersion names the replacement, checked 2026-10-14). Moving the
        -- pick keeps the name honest; the old id would still answer.
        gemini = {
            ["gemini-3.7-flash"] = "gemini-3.8-flash",
            ["gemini-3.5-flash"] = "gemini-3.6-flash",
        },
        -- Model Studio 2026-10-14: qwen3-max and qwen3-coder-plus answer 404 "Model not
        -- exist"; qwen-turbo left the list and answers only a 429 request limit.
        qwen = {
            ["qwen3-max"] = "qwen3.8-max",
            ["qwen3-coder-plus"] = "qwen3.8-max",
            ["qwen-turbo"] = "qwen3.5-flash",
        },
        -- OpenRouter 2026-10-14: both 404 "deprecated on Oct 9, 2026" (its own advice:
        -- Qwen3.8 Max (0902) and Qwen3.7 Plus; the curated flash stands in for the latter).
        openrouter = {
            ["qwen/qwen3-max"] = "qwen/qwen3.8-max-0902",
            ["qwen/qwen3-235b-a22b"] = "qwen/qwen3.8-flash",
        },
        -- Gone from SambaNova's catalog by 2026-10-14 (catalog evidence; the key is refused).
        sambanova = {
            ["MiniMax-M2.7"] = "MiniMax-M3",
        },
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
            anthropic = "claude-fable-5-1",
            openai = "gpt-6-astra",                  -- $10/$50; cannot turn reasoning off
            openai_codex = "gpt-6-astra",            -- opt-in like every frontier pick; needs a paid plan (refused on free accounts with the plan tip, 2026-10-11)
            gemini = "gemini-4-argon",               -- paid only (no free tier); GA, replaces 3.1-pro-preview here 2026-10-14
        },

        -- Provider's most capable general-purpose model
        flagship = {
            anthropic = "claude-opus-5-5",           -- deep-reasoning flagship; sonnet-5-5 is the standard tier
            openai = "gpt-6.1-sol",                  -- same price as 6-sol; reasons by default and cannot turn it off
            openai_codex = "gpt-6.1-sol",   -- needs a paid plan: refused on free accounts with the plan tip (maintainer 2026-10-11, amending the 2026-08-15 ruling for flagship alone)
            deepseek = "deepseek-v4-pro",
            gemini = "gemini-3.8-flash",             -- Pro models are paid-only; keep tier free-tier usable (3.8-flash answers on a free key 2026-09-28)
            groq = "openai/gpt-oss-120b",            -- llama picks deprecated by Groq 2026-08-16
            mistral = "mistral-large-latest",
            xai = "grok-4.7",
            cohere = "command-a-plus-05-2026",
            ollama = "llama4",
            together = "deepseek-ai/DeepSeek-V4-Pro-0813",
            fireworks = "accounts/fireworks/models/glm-5p3",       -- deepseek-v4-pro stopped serving 2026-09
            sambanova = "gpt-oss-120b",              -- Maverick deprecated 2026-06-09
            qwen = "qwen3.8-max",                    -- qwen3-max retired 2026-10-10
            kimi = "kimi-k2.6",                      -- kimi-k3 probed on the international platform only; China-region keys exist (the pre-v0.21 migration), tier hints must never 400
            doubao = "doubao-seed-2.0-pro-32k",
            zai = "glm-5.3",                         -- always thinks (the 5.2 default can turn it off)
            nvidia = "nvidia/nemotron-3-ultra-550b-a55b",
        },

        -- Balanced performance and cost
        standard = {
            anthropic = "claude-sonnet-5-5",
            openai = "gpt-5.6-terra",  -- standard/default
            openai_codex = "gpt-5.6-terra",
            deepseek = "deepseek-flash",
            gemini = "gemini-3.8-flash",
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
            nvidia = "nvidia/nemotron-3.5-super-vl-120b-a12b",   -- super-120b stopped serving 2026-10-20
        },

        -- Optimized for speed and lower cost
        fast = {
            anthropic = "claude-haiku-5-5",          -- thinks by default; the fast-tier actions and Quick send off (disable accepted)
            openai = "gpt-6-luna",   -- cheapest ($0.10/$0.50, half of 5.6-luna) and newer; the fast-tier actions and Quick send reasoning off ("none"); probe 2026-10-11
            openai_codex = "gpt-6-luna",   -- served on free accounts; the fast-tier actions send reasoning off ("none", accepted on the Codex wire), then as quick as 5.6-luna (probe 2026-10-11)
            deepseek = "deepseek-flash",
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
            nvidia = "openai/gpt-oss-20b",  -- 1 s; nano-omni hung 2026-09-28, lightning pulled: see the array note
        },

        -- Smallest/cheapest models for basic tasks
        ultrafast = {
            anthropic = "claude-haiku-5-5",
            openai = "gpt-6-luna",   -- cheaper than 5.4-nano ($0.20/$1.25) and newer; no smaller GPT-6 exists (maintainer 2026-10-11)
            openai_codex = "gpt-6-luna",   -- no mini or nano on the Codex backend (the 5.4 ids left it 2026-08-31): luna fills fast and ultrafast, as on other providers
            deepseek = "deepseek-flash",
            gemini = "gemini-3.5-flash-lite",
            groq = "openai/gpt-oss-20b",            -- see fast-tier note: Groq retired every non-reasoning production model 2026-08-16
            mistral = "ministral-3b-latest",
            xai = "grok-4.20-0309-non-reasoning",
            cohere = "command-r7b-12-2024",
            ollama = "tinyllama",
            together = "meta-llama/Llama-3.3-70B-Instruct-Turbo",
            fireworks = "accounts/fireworks/models/deepseek-v4p1-flash", -- gpt-oss-20b stopped serving 2026-09; reasoning can turn off
            sambanova = "Meta-Llama-3.3-70B-Instruct",
            qwen = "qwen3.5-flash",                  -- qwen-turbo gone 2026-10-14; the fast pick fills both
            kimi = "kimi-k2.6", -- turbo-preview 404s on the international platform (2026-08-15); k2.6 serves everywhere
            doubao = "doubao-seed-2.0-lite",
            zai = "glm-4.7-flash",
            nvidia = "openai/gpt-oss-20b",  -- nano-30b retired 2026-09-01 (410); nano-omni and lightning hang
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
            api_list = "https://dashscope-intl.aliyuncs.com/compatible-mode/v1/models",  -- international
            docs = "https://help.aliyun.com/zh/model-studio/getting-started/models",
        },
        kimi = {
            api_list = "https://api.moonshot.ai/v1/models",  -- international
            docs = "https://platform.moonshot.cn/docs/intro",
            -- International platform: platform.kimi.ai (separate accounts,
            -- region-locked keys — see features.kimi_region)
        },
        together = {
            api_list = "https://api.together.xyz/v1/models",
            docs = "https://docs.together.ai/docs/inference-models",
        },
        fireworks = {
            api_list = "https://api.fireworks.ai/inference/v1/models",
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
            api_list = "https://api.perplexity.ai/v1/models",  -- direct models only, no presets
            docs = "https://docs.perplexity.ai/docs/agent-api/models",
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
        cheaperinference = {
            api_list = "https://api.cheaperinference.com/v1/models",   -- needs the key
            docs = "https://cheaperinference.com/docs",
        },
        opencode = {
            api_list = "https://opencode.ai/zen/v1/models",   -- public
            docs = "https://opencode.ai/docs/zen/",
        },
        opencode_go = {
            api_list = "https://opencode.ai/zen/go/v1/models",   -- public
            docs = "https://opencode.ai/docs/go/",
        },
        a2agent = {
            api_list = "https://api.a2agent.me/v1/models",   -- public
            docs = "https://docs.a2agent.me",
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
-- facts (URLs, auth headers, request shapes) live in koassistant/images/image_generator.lua.
-- _-prefixed so provider iteration (getAllProviders) skips it.
-------------------------------------------------------------------------------

-- Refreshed 2026-10-14 (docs/image_round_plan.md, rulings R1 + R2): the chat
-- lists' rule, current models then one previous version per line. Left the
-- picker, still served (a saved pick keeps working): gpt-image-1.5,
-- gpt-image-1, chatgpt-image-latest, gemini-3.1-flash-image (deprecated by
-- Google for gemini-nano-banana-2.1).
ModelLists._image_models = {
    openai = {
        "gpt-image-2.5-flare",     -- default: OpenAI's pick for new work; 11 s at low quality (2026-10-14)
        "gpt-image-2.5-sunburst",  -- the base model: finest detail, slower
        "gpt-image-2",             -- previous flagship
        "gpt-image-1-mini",        -- previous fast pick
    },
    xai = {
        "grok-imagine-image",      -- default: fast (~7 s), $0.02
        "grok-imagine-image-2.0",  -- better pictures, $0.04 at low (15 s, 2026-10-14)
    },
    gemini = {
        "gemini-nano-banana-2.1",       -- default: Nano Banana 2.1, the successor of gemini-3.1-flash-image at half its price
        "gemini-3.1-flash-lite-image",  -- fastest and cheapest, 1K only
        "gemini-3-pro-image",           -- Nano Banana Pro: finest detail, slower
    },
    -- OpenRouter's Image API (image round S3, 2026-10-14): one key for
    -- several makers; "More models…" in the settings reaches the rest of its
    -- catalog. Prices per picture from each model's endpoints that day.
    openrouter = {
        "openai/gpt-image-2.5-flare",         -- default: about $0.005 at Draft (priced per token)
        "google/gemini-nano-banana-2.1",      -- priced per token, about $0.04
        "black-forest-labs/flux-3-image",     -- $0.048 at 1K
        "black-forest-labs/flux-3-image-klein", -- FLUX 3's small open-weights model: $0.009 at 1K, 6 s (2026-10-16)
        "bytedance-seed/seedream-5-0-flash",  -- $0.018
        "recraft/recraft-v4.1-flash",         -- $0.007, leans to illustration
    },
}

-- Image models the provider answers with another model: a stored pick goes out
-- as the replacement (ModelLists.resolveImageModel). xAI serves
-- grok-imagine-image-quality (and its alias -pro) with grok-imagine-image-2.0
-- at low quality from 2026-11-02.
ModelLists._image_retired = {
    xai = {
        ["grok-imagine-image-quality"] = "grok-imagine-image-2.0",
        ["grok-imagine-image-pro"] = "grok-imagine-image-2.0",
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

-- The image model a stored pick sends: nil, "" or "default" = the list's
-- first; a retired id = its replacement; anything else as stored.
function ModelLists.resolveImageModel(provider, stored)
    if type(stored) ~= "string" or stored == "" or stored == "default" then
        return ModelLists.getDefaultImageModel(provider)
    end
    local retired = ModelLists._image_retired[provider]
    return (retired and retired[stored]) or stored
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
    local ModelOverrides = require("koassistant.request.model_overrides")
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
    local ModelOverrides = require("koassistant.request.model_overrides")
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

--- The id that replaces a model the provider no longer serves (_retired).
--- @param provider string|nil
--- @param model string|nil
--- @return string|nil replacement id, nil when the model is not retired
function ModelLists.retiredReplacement(provider, model)
    local retired = provider and ModelLists._retired[provider]
    local replacement = retired and model and retired[model]
    return type(replacement) == "string" and replacement or nil
end

--- Decide what to do with a persisted `features.model` when the provider's default may have
--- moved on, or when the id no longer exists (defaults_propagation_plan.md §3, gaps G2/G3).
--- PURE: no settings/UI access, so it is unit-testable and safe to call on every load.
---
--- Decision order:
---   nil/empty model           -> keep    (nil already resolves to the provider default)
---   retired id                -> retired (the provider no longer serves it; even a
---                                         deliberate pick moves, to its replacement)
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
---   retired          table|nil   retired id -> replacement (ModelLists._retired[provider])
--- }
--- @return string action  "keep" | "refresh" | "reset" | "retired"
--- @return string|nil new_model  the id to move to (nil when action == "keep")
function ModelLists.resolveModelRefresh(opts)
    opts = opts or {}
    local model = opts.model
    if type(model) ~= "string" or model == "" then return "keep", nil end
    local replacement = type(opts.retired) == "table" and opts.retired[model]
    if type(replacement) == "string" and replacement ~= "" then return "retired", replacement end
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
