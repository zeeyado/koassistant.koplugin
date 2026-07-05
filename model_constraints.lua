-- Model Constraints
-- Centralized definitions for model-specific parameter constraints
-- Add new constraints here as they are discovered via --models testing
--
-- Also defines model capabilities (reasoning/thinking support)

local ModelConstraints = {
    openai = {
        -- Models requiring temperature=1.0 (reject other values)
        -- Discovered via: lua tests/run_tests.lua --models openai
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
            "claude-sonnet-5",        -- 5 Sonnet
            "claude-opus-4-8",        -- 4.8 Opus
            "claude-opus-4-7",        -- 4.7 Opus (prefix-matched for safety)
            "claude-sonnet-4-6",      -- 4.6 Sonnet
            "claude-opus-4-6",        -- 4.6 Opus (prefix-matched for safety)
        },
        -- Models that REJECT sampling params (temperature/top_p/top_k → HTTP 400)
        -- Opus 4.7+ and Sonnet 5 removed sampling params entirely; the builder strips them.
        no_sampling_params = {
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
        -- Function calling for the book-tool workflows (universal on Claude; list families).
        tools = {
            "claude-opus-4", "claude-sonnet-4", "claude-sonnet-5", "claude-haiku-4",
        },
    },
    openai = {
        -- Models that support reasoning.effort parameter
        reasoning = {
            "gpt-5.5",
            "gpt-5.4", "gpt-5.4-mini", "gpt-5.4-nano",
        },
        -- Models where reasoning is opt-in (default=none from OpenAI)
        -- GPT-5.4 defaults reasoning_effort=none (off); gated by master toggle + openai_reasoning sub-toggle.
        -- GPT-5.5 reasons at medium by default (NOT gated — always reasons at factory default).
        reasoning_gated = {
            "gpt-5.4", "gpt-5.4-mini", "gpt-5.4-nano",
        },
        -- Note: OpenAI Chat Completions API does NOT have native web search.
        -- Web search requires Responses API or function calling with external tools.
    },
    deepseek = {
        -- V4: both models support thinking toggle (type: enabled/disabled), ON by default
        thinking = { "deepseek-v4-pro", "deepseek-v4-flash" },
        -- Keep reasoning list for tier system (which models are "reasoning-class")
        reasoning = { "deepseek-v4-pro" },
    },
    gemini = {
        -- Gemini 3 models use thinkingLevel (minimal/low/medium/high)
        thinking = { "gemini-3.5-flash", "gemini-3.1-pro-preview", "gemini-3.1-flash-lite" },
        -- Gemini 2.5 models use thinkingBudget (0=off, -1=dynamic, 128-24576)
        thinking_budget = { "gemini-2.5-flash", "gemini-2.5-pro", "gemini-2.5-flash-lite" },
        -- Google Search grounding
        google_search = {
            "gemini-3.5-flash", "gemini-3.1-pro-preview", "gemini-3.1-flash-lite",
            "gemini-2.5-flash", "gemini-2.5-pro", "gemini-2.5-flash-lite",
        },
        -- Function calling for the book-tool workflows (same models as google_search).
        -- The runner's shouldUse gates on this + a tool_wire.lua adapter being registered.
        tools = {
            "gemini-3.5-flash", "gemini-3.1-pro-preview", "gemini-3.1-flash-lite",
            "gemini-2.5-flash", "gemini-2.5-pro", "gemini-2.5-flash-lite",
        },
    },
    -- Note: xAI web search requires Responses API (/v1/responses) which is
    -- not compatible with Chat Completions. Deprecated Feb 20, 2026 (410 Gone).
    -- Note: Z.AI web search only works via a separate endpoint (/api/paas/v4/tools),
    -- NOT via the chat completions tools parameter (silently ignored).
    zai = {
        -- GLM-4.5+ models support toggleable thinking (type: enabled/disabled)
        -- Returns reasoning_content field in responses (like DeepSeek)
        -- IMPORTANT: Z.AI requires temperature=1.0 when thinking is enabled
        -- (enforced in zai.lua handler, not here — thinking is togglable)
        thinking = {
            "glm-5.2", "glm-5.1", "glm-5-turbo", "glm-5",
            "glm-4.7", "glm-4.7-flash",
        },
    },
    openrouter = {
        -- Unified reasoning object works for all backend models
        -- OpenRouter auto-translates effort to each provider's native format
        -- No model list needed — controlled by whether reasoning param is sent
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
        -- Models with reasoning_effort support
        reasoning = {
            "accounts/fireworks/models/deepseek-v4-pro",
            "accounts/fireworks/models/deepseek-r1",
            "accounts/fireworks/models/kimi-k2-thinking",
            "accounts/fireworks/models/qwen3-235b-a22b",
        },
    },
    sambanova = {
        -- Models with thinking toggle (chat_template_kwargs.enable_thinking)
        thinking = { "DeepSeek-V3.1", "DeepSeek-V3.2" },
    },
    xai = {
        -- grok-4.3 and the grok-4.20 reasoning variant support reasoning_effort (none/low/medium/high)
        -- The grok-4.20 non-reasoning slug has no effort control
        reasoning = { "grok-4.3", "grok-4.20-0309-reasoning" },
    },
    perplexity = {
        -- Reasoning models (always-on, but effort is controllable)
        -- sonar-reasoning-pro uses <think> tags, sonar-deep-research also supports effort
        reasoning = { "sonar-reasoning-pro", "sonar-deep-research" },
    },
    mistral = {
        -- Magistral models always think (no toggle, extraction only)
        -- Returns structured content blocks with type: "thinking"
        thinking = { "magistral-medium", "magistral-small" },
    },
}

-- Maximum output token limits per model
-- Used by handlers to clamp max_tokens before sending requests
-- Models with known output token ceilings (prevents API 400 errors)
ModelConstraints._max_output_tokens = {
    anthropic = {
        ["claude-sonnet-5"] = 128000,    -- 128K max output
        ["claude-opus-4-8"] = 128000,    -- 128K max output
        ["claude-sonnet-4-6"] = 64000,
        ["claude-haiku-4-5"] = 64000,
    },
    -- deepseek: v4 models allow 384K output (no cap needed)
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
    },
    deepseek = {
        { match = "deepseek-v4-pro", axis = "binary", default_state = "on",
          can_disable = true, can_enable = true,
          stance_map = { minimal = { state = "off" }, maximum = { state = "on" } } },
        { match = "deepseek-v4-flash", axis = "binary", default_state = "on",
          can_disable = true, can_enable = true,
          stance_map = { minimal = { state = "off" }, maximum = { state = "on" } } },
    },
    gemini = {
        -- Gemini 3 (thinkingLevel). Pro has no "minimal" floor; flash variants do.
        { match = "gemini-3.1-pro-preview", axis = "effort", default_state = "on",
          can_disable = false, can_enable = true,
          options = { "low", "medium", "high" }, default_option = "high",
          stance_map = { minimal = { option = "low" }, maximum = { option = "high" } } },
        { match = "gemini-3.5-flash", axis = "effort", default_state = "on",
          can_disable = false, can_enable = true,
          options = { "minimal", "low", "medium", "high" }, default_option = "high",
          stance_map = { minimal = { option = "minimal" }, maximum = { option = "high" } } },
        { match = "gemini-3.1-flash-lite", axis = "effort", default_state = "on",
          can_disable = false, can_enable = true,
          options = { "minimal", "low", "medium", "high" }, default_option = "high",
          stance_map = { minimal = { option = "minimal" }, maximum = { option = "high" } } },
        -- Gemini 2.5 (thinkingBudget): thinks by default (dynamic), can disable via 0.
        -- flash-lite listed before flash so the more-specific id matches first.
        { match = "gemini-2.5-flash-lite", axis = "budget", default_state = "on",
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
    },
    sambanova = {
        { match = "DeepSeek-V3.1", axis = "binary", default_state = "on", can_disable = true, can_enable = true,
          stance_map = { minimal = { state = "off" }, maximum = { state = "on" } } },
        { match = "DeepSeek-V3.2", axis = "binary", default_state = "on", can_disable = true, can_enable = true,
          stance_map = { minimal = { state = "off" }, maximum = { state = "on" } } },
    },
    openrouter = {
        -- Universal effort; "off" = don't request reasoning (backends may still reason).
        { match = "", axis = "effort", default_state = "off", can_disable = true, can_enable = true,
          options = { "low", "medium", "high" }, default_option = "high",
          stance_map = { minimal = { state = "off" }, maximum = { state = "on", option = "high" } } },
    },
    requesty = {
        -- Universal effort; "off" = don't request reasoning (backends may still reason).
        { match = "", axis = "effort", default_state = "off", can_disable = true, can_enable = true,
          options = { "low", "medium", "high" }, default_option = "high",
          stance_map = { minimal = { state = "off" }, maximum = { state = "on", option = "high" } } },
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
        { match = "accounts/fireworks/models/deepseek-v4-pro", axis = "effort", default_state = "on", can_disable = false, can_enable = true,
          options = { "low", "medium", "high" }, default_option = "high",
          stance_map = { minimal = { option = "low" }, maximum = { option = "high" } } },
        { match = "accounts/fireworks/models/deepseek-r1", axis = "effort", default_state = "on", can_disable = false, can_enable = true,
          options = { "low", "medium", "high" }, default_option = "high",
          stance_map = { minimal = { option = "low" }, maximum = { option = "high" } } },
        { match = "accounts/fireworks/models/kimi-k2-thinking", axis = "effort", default_state = "on", can_disable = false, can_enable = true,
          options = { "low", "medium", "high" }, default_option = "high",
          stance_map = { minimal = { option = "low" }, maximum = { option = "high" } } },
        { match = "accounts/fireworks/models/qwen3-235b-a22b", axis = "effort", default_state = "on", can_disable = false, can_enable = true,
          options = { "low", "medium", "high" }, default_option = "high",
          stance_map = { minimal = { option = "low" }, maximum = { option = "high" } } },
    },
    xai = {
        -- grok-4.3 / 4.20 reasoning: reasons by default, disableable via effort "none".
        { match = "grok-4.3", axis = "effort", default_state = "on", can_disable = true, can_enable = true,
          options = { "low", "medium", "high" }, default_option = "high", off_option = "none",
          stance_map = { minimal = { state = "off" }, maximum = { state = "on", option = "high" } } },
        { match = "grok-4.20-0309-reasoning", axis = "effort", default_state = "on", can_disable = true, can_enable = true,
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
    },
    mistral = {
        -- Magistral: always thinks, no control (extraction only).
        { match = "magistral-medium", axis = "none", default_state = "on", can_disable = false, can_enable = false },
        { match = "magistral-small", axis = "none", default_state = "on", can_disable = false, can_enable = false },
    },
}

-- SINGLE SOURCE OF TRUTH for web search support + UI gating.
-- To add a provider when web search is expanded, add ONE entry here — both
-- supportsWebSearch() and every "supported providers" label/help string update.
--   mode = "all"                  -> every model of this provider can search
--   mode = "capability:<name>"    -> only models with that capability (e.g. Gemini's google_search)
-- Mechanisms today: anthropic (web_search_20250305 tool), openrouter (:online / Exa),
-- perplexity (built-in Sonar, always on), gemini (googleSearch grounding, capable models).
-- Everything else (OpenAI, DeepSeek, xAI, Mistral, Groq, etc.) has NO web search via the
-- Chat Completions API the plugin uses.
ModelConstraints._web_search_providers = {
    { id = "anthropic",  label = "Anthropic",  mode = "all" },
    { id = "gemini",     label = "Gemini",     mode = "capability:google_search" },
    { id = "perplexity", label = "Perplexity", mode = "all" },
    { id = "openrouter", label = "OpenRouter", mode = "all" },
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

--- Friendly, comma-joined list of providers that support web search.
--- Derived from _web_search_providers so UI strings stay in sync on expansion.
--- @return string e.g. "Anthropic, Gemini, Perplexity, OpenRouter"
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

--- Check if a model supports a specific capability
--- @param provider string: Provider name (e.g., "anthropic", "openai")
--- @param model string: Model name (e.g., "claude-sonnet-4-5-20250929")
--- @param capability string: Capability name (e.g., "extended_thinking", "reasoning")
--- @return boolean: true if model supports the capability
function ModelConstraints.supportsCapability(provider, model, capability)
    local caps = ModelConstraints.capabilities[provider]
    if not caps or not caps[capability] then
        return false
    end

    for _, supported in ipairs(caps[capability]) do
        if prefixMatch(model, supported) then
            return true
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
    if not provider_constraints then
        return params, adjustments
    end

    -- Check model-specific constraints (prefix match for versioned models)
    -- e.g., "o3-mini" matches "o3-mini", "o3-mini-high", "o3-mini-2025-01-31"
    local model_constraints = nil
    for constraint_model, constraints in pairs(provider_constraints) do
        -- Skip special keys starting with _
        if type(constraint_model) == "string" and not constraint_model:match("^_") then
            -- Check for exact match or prefix match
            if model == constraint_model or model:match("^" .. constraint_model:gsub("%-", "%%-")) then
                model_constraints = constraints
                break
            end
        end
    end

    if model_constraints then
        for param, required_value in pairs(model_constraints) do
            if params[param] ~= nil and params[param] ~= required_value then
                adjustments[param] = { from = params[param], to = required_value }
                params[param] = required_value
            end
        end
    end

    -- Check provider-level max temperature (e.g., Anthropic max 1.0)
    local max_temp = provider_constraints._provider_max_temperature
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
        local reason_str = adj.reason and (" (" .. adj.reason .. ")") or ""
        print(string.format("  %s: %s -> %s%s",
            param,
            tostring(adj.from),
            tostring(adj.to),
            reason_str))
    end
end

--- Clamp max_tokens to model-specific ceiling (if any)
--- Acts as a ceiling: values below the cap pass through unchanged.
--- @param provider string: Provider name (e.g., "deepseek", "groq")
--- @param model string: Model name (e.g., "deepseek-chat")
--- @param value number|nil: The max_tokens value to clamp
--- @return number|nil: Clamped value, or original if no cap applies
function ModelConstraints.clampMaxTokens(provider, model, value)
    if not value then return value end
    local provider_caps = ModelConstraints._max_output_tokens[provider]
    if not provider_caps then return value end

    for cap_model, max_val in pairs(provider_caps) do
        -- Prefix match (e.g., "deepseek-chat" matches "deepseek-chat-v2")
        if model == cap_model or model:match("^" .. cap_model:gsub("%-", "%%-")) then
            return math.min(value, max_val)
        end
    end

    return value
end

--- Append an actionable tip when a Gemini-3 grounded (web-search) request fails with a
--- 429/quota error. Gemini-3 grounding uses a separate monthly quota shared across all
--- Gemini-3 models, independent of 2.5's daily quota, so it can be exhausted while 2.5
--- grounding still works on the same key. Plain text (emoji don't render in MuPDF).
--- Returns err_msg unchanged unless every condition holds.
--- @param err_msg string: user-facing error message already built
--- @param provider string|nil: provider id
--- @param model string|nil: model id
--- @param config table|nil: unified request config (for web-search gating)
--- @return string
function ModelConstraints.maybeAppendGemini3GroundingHint(err_msg, provider, model, config)
    if type(err_msg) ~= "string" or err_msg == "" then return err_msg end
    if provider ~= "gemini" then return err_msg end
    if not (model and model:match("^gemini%-3")) then return err_msg end
    -- web search enabled? per-action override > global (mirrors gemini.lua:146-153)
    local ws = false
    if config then
        if config.enable_web_search ~= nil then
            ws = config.enable_web_search
        elseif config.features and config.features.enable_web_search then
            ws = true
        end
    end
    if not ws then return err_msg end
    local lowered = err_msg:lower()
    if not (lowered:find("429", 1, true)
            or lowered:find("resource_exhausted", 1, true)
            or lowered:find("quota", 1, true)) then
        return err_msg
    end
    return err_msg .. "\n\n" ..
        "Tip: This is a Google quota limit, not a plugin error. Gemini 3 grounding can hit a " ..
        "free-tier limit of 0 even with billing attached, when your project's paid tier isn't " ..
        "provisioned for it. Workarounds: use a Gemini 2.5 model for web search, switch to " ..
        "Anthropic/Perplexity/OpenRouter, or enable paid-tier quota for Gemini 3 in Google AI Studio."
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

--------------------------------------------------------------------------------
-- Reasoning resolution
--------------------------------------------------------------------------------

--- Look up the reasoning profile for a provider/model.
--- Returns the first prefix match, or a synthetic passthrough profile for
--- unknown/custom models (axis="none" => resolver emits nothing => request untouched).
--- @param provider string|nil
--- @param model string|nil
--- @return table profile
function ModelConstraints.getReasoningProfile(provider, model)
    local list = provider and ModelConstraints.reasoning_profiles[provider]
    if list then
        for _, p in ipairs(list) do
            if prefixMatch(model, p.match) then
                return p
            end
        end
    end
    return {
        axis = "none",
        default_state = "off",
        can_disable = false,
        can_enable = false,
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
---   action_override > model_pref > global_stance > model natural default.
--- @param provider string
--- @param model string
--- @param layers table { global_stance="minimal"|"default"|"maximum",
---                       model_pref={state=,effort=,budget=}|nil,
---                       action_override={force="on"|"off", effort=, budget=}|nil }
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
    if ao and ao.force == "off" then
        desired = { state = "off" }
    elseif ao and ao.force == "on" then
        desired = { state = "on", option = ao.effort or ao.budget }
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
    elseif provider == "openai" then
        if on then api_params.reasoning = { effort = decision.effort } end
    elseif provider == "gemini" then
        if decision.axis == "budget" then
            api_params.thinking_budget = on and (decision.budget or -1) or 0
        elseif decision.axis == "effort" then  -- Gemini 3 thinkingLevel
            if on then api_params.thinking_level = decision.effort end
        end
    elseif provider == "deepseek" then
        api_params.deepseek_thinking = { type = on and "enabled" or "disabled" }
    elseif provider == "zai" then
        api_params.zai_thinking = { type = on and "enabled" or "disabled" }
    elseif provider == "sambanova" then
        api_params.sambanova_thinking = on
    elseif provider == "openrouter" then
        if on then api_params.openrouter_reasoning = { effort = decision.effort } end
    elseif provider == "requesty" then
        if on then api_params.requesty_reasoning = { effort = decision.effort } end
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
    end
end

return ModelConstraints
