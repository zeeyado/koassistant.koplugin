-- Unit tests: the REAL provider error wordings for "the request was too big"
-- (request-sizing audit, Track C, 2026-09-03).
--
-- Three failure classes bound how big a request may be, and each provider says
-- it differently:
--   output_cap  - max_tokens above the model's own output ceiling
--   context     - prompt, or prompt + max_tokens, above the context window
--   admission   - a per-minute token allowance counted BEFORE the model runs
--   burst       - an ordinary rate-limit 429 (often with a Used/Requested pair)
-- Everything the plugin does about them is decided by pure functions:
--   ModelConstraints.parseMaxTokensError  (self-heal: retry value / learned cap)
--   RateLimits.parseRefusal               (admission resend arithmetic)
--   RateLimits.refusalKind                (burst vs admission: resend or wait)
--   ModelConstraints.isRateLimitError     (persistent dialog vs vanishing toast)
--   ModelConstraints.decorateRequestError (WHICH tip the reader is shown)
--   XrayAuto.classifyStopReason           (the unattended ladder's verdict and
--                                          whether it retries at all)
--
-- This file is the CORPUS: one entry per verbatim wording collected from the
-- repo's own fixtures, this repo's issues, and public provider reports. Every
-- entry carries its source. Entries WITHOUT known_miss must parse exactly as
-- `expect` says. Entries WITH known_miss must currently NOT parse that way, so
-- the day a parser learns the wording this file fails and the corpus gets
-- updated deliberately instead of drifting.
--
-- NOTHING here changes the parsers. It records what they do today.
--
-- Run: lua tests/unit/test_error_wordings.lua   (or lua tests/run_tests.lua --unit)

local function setupPaths()
    local info = debug.getinfo(1, "S")
    local script_path = info.source:match("@?(.*)")
    local unit_dir = script_path:match("(.+)/[^/]+$") or "."
    local tests_dir = unit_dir:match("(.+)/[^/]+$") or "."
    local plugin_dir = tests_dir:match("(.+)/[^/]+$") or "."
    package.path = table.concat({
        plugin_dir .. "/?.lua",
        plugin_dir .. "/koassistant_api/?.lua",
        tests_dir .. "/?.lua",
        tests_dir .. "/lib/?.lua",
        package.path,
    }, ";")
end
setupPaths()

-- Load mocks BEFORE any plugin modules
require("mock_koreader")

local TestRunner = { passed = 0, failed = 0 }

function TestRunner.assert(condition, message)
    if condition then
        TestRunner.passed = TestRunner.passed + 1
    else
        TestRunner.failed = TestRunner.failed + 1
        print("  FAIL: " .. message)
    end
end

local ModelConstraints = require("model_constraints")
local RateLimits = require("koassistant_rate_limits")
-- The unattended surface's classifier is the fourth parser over these same
-- wordings (audit B2b); the module is pure (no KOReader deps at file level).
local XrayAuto = require("koassistant_xray_auto")

--------------------------------------------------------------------------------
-- THE CORPUS
--
-- text     = VERBATIM, as the provider sends it (the parsers see the whole body
--            text, so the JSON envelope shape is recorded in `envelope` where a
--            source showed it, but the parsers only ever read the message).
-- source   = where the wording was read (repo path, gh issue, provider doc).
-- expect   = the TRUE class of the wording plus every number it states.
--            kind "output_cap": parseMaxTokensError -> {output_cap, cap=limit}
--            kind "context" with retry_at: parseMaxTokensError ->
--                {context, limit, prompt, retry_at}
--            kind "context" WITHOUT retry_at: parseMaxTokensError -> nil,
--                which is correct: the prompt alone does not fit (or the
--                message states no prompt number), so no resend can help.
--            kind "admission"/"burst" with limit+requested:
--                parseRefusal -> {limit, requested, used}
--            kind "admission"/"burst" without them: parseRefusal -> nil
--            kind "other": both parsers -> nil
--            rate_limit = what isRateLimitError must return.
-- refusal_kind = what RateLimits.refusalKind must return ("admission", "burst",
--            or absent for nil = not a per-minute token refusal). Asserted on
--            EVERY entry, so a wording elsewhere in the corpus that started
--            classifying would fail here.
-- hint     = WHICH tip the reader gets, one of ModelConstraints.HINT_HEADS'
--            ids or "none" (audit B2: exactly one tip per refusal, and the
--            right one). The entry's text is run through decorateRequestError,
--            the way the query router builds the message, and every other
--            hint's needle must be absent — the double tip (generic rate-limit
--            plus book-text) and the suppressed tip (F12) both fail here.
-- ladder   = { kind, transient } XrayAuto.classifyStopReason must return for
--            the DECORATED string, which is what the unattended checkpoint
--            ladder really receives (audit B2b/F36: the retry decision used to
--            be driven by the plugin's own advice paragraph, and was inverted).
--------------------------------------------------------------------------------

local CORPUS = {

    ----------------------------------------------------------------------------
    -- Output caps: max_tokens above the model's own output ceiling
    ----------------------------------------------------------------------------
    {
        id = "openai_max_tokens_too_large",
        provider = "openai",
        status = 400,
        source = "tests/unit/test_max_tokens.lua parser fixture; wording reported at "
            .. "community.openai.com/t/batch-api-errors-max-tokens-is-too-large/738029",
        text = "max_tokens is too large: 100000. This model supports at most 16384 completion tokens, "
            .. "whereas you provided 100000.",
        expect = { kind = "output_cap", limit = 16384, rate_limit = false },
        hint = "none",
        ladder = { kind = "too_large", transient = false },
    },
    {
        id = "anthropic_output_cap",
        provider = "anthropic",
        status = 400,
        source = "github.com/anthropics/claude-code/issues/11302",
        envelope = '{"type":"error","error":{"type":"invalid_request_error","message":"..."},"request_id":"req_..."}',
        text = "max_tokens: 21333 > 4096, which is the maximum allowed number of output tokens for "
            .. "claude-3-opus-20240229",
        expect = { kind = "output_cap", limit = 4096, rate_limit = false },
        hint = "none",
        ladder = { kind = "too_large", transient = false },
    },
    {
        id = "groq_output_cap",
        provider = "groq",
        status = 400,
        source = "github.com/sst/opencode/issues/1000 (Groq, kimi-k2); same family as issue #89",
        text = "`max_tokens` must be less than or equal to `16384`, the maximum value for `max_tokens` "
            .. "is less than the `context_window` for this model",
        expect = { kind = "output_cap", limit = 16384, rate_limit = false },
        hint = "none",
        ladder = { kind = "too_large", transient = false },
    },
    {
        id = "gemini_max_output_range",
        provider = "gemini",
        status = 400,
        source = "discuss.ai.google.dev/t/unable-to-submit-request-because-it-has-a-maxoutputtokens-value-of-828858/101543",
        text = "Unable to submit request because it has a maxOutputTokens value of 828858 but the "
            .. "supported range is from 1 (inclusive) to 65537 (exclusive).",
        -- Range is exclusive at the top, so the real ceiling is 65536.
        expect = { kind = "output_cap", limit = 65536, rate_limit = false },
        known_miss = true,
        hint = "none",
        ladder = { kind = "other", transient = false },
    },
    {
        id = "dashscope_max_tokens_range",
        provider = "qwen",
        status = 400,
        -- Verbatim capture from a Qwen model on Alibaba Cloud Model Studio. The
        -- documentation page only shows the template "Range of max_tokens should be [1, xxx]".
        source = "github.com/anomalyco/opencode/issues/40770",
        envelope = '{"error":{"code":"invalid_parameter_error","param":null,"message":"...","type":"invalid_request_error"},"id":"chatcmpl-..."}',
        text = "Range of max_tokens should be [1, 131072]",
        expect = { kind = "output_cap", limit = 131072, rate_limit = false },
        known_miss = true,
        hint = "none",
        ladder = { kind = "other", transient = false },
    },

    ----------------------------------------------------------------------------
    -- Context overflow, with computable room (a resend can succeed)
    ----------------------------------------------------------------------------
    {
        id = "openai_context_exceeded",
        provider = "openai",
        status = 400,
        source = "community.openai.com/t/strange-error-this-models-maximum-context-length-is-4097-tokens-"
            .. "however-you-requested-4097-tokens/100020",
        envelope = '{"message":"...","type":"invalid_request_error","param":"messages",'
            .. '"code":"context_length_exceeded"}',
        text = "This model's maximum context length is 4097 tokens. However, you requested 4097 tokens "
            .. "(999 in the messages, 3098 in the completion). Please reduce the length of the messages "
            .. "or completion.",
        expect = { kind = "context", limit = 4097, prompt = 999, retry_at = 4097 - 999 - 256,
            rate_limit = false },
        hint = "context",
        ladder = { kind = "too_large", transient = false },
    },
    {
        id = "vllm_context_room",
        provider = "vllm-family",
        status = 400,
        source = "tests/unit/test_max_tokens.lua fixture; wording from vllm-project/vllm issue 20409",
        text = "This model's maximum context length is 12288 tokens. However, you requested 20480 tokens "
            .. "(8192 in the messages, 12288 in the completion). Please reduce the length of the messages "
            .. "or completion.",
        expect = { kind = "context", limit = 12288, prompt = 8192, retry_at = 12288 - 8192 - 256,
            rate_limit = false },
        hint = "context",
        ladder = { kind = "too_large", transient = false },
    },
    {
        id = "vllm_context_new_wording",
        provider = "vllm-family",
        status = 400,
        source = "github.com/vllm-project/vllm/issues/42474 (vllm/renderers/params.py _token_len_check)",
        text = "This model's maximum context length is 128000 tokens. However, you requested 65535 output "
            .. "tokens and your prompt contains at least 62466 input tokens, for a total of at least "
            .. "128001 tokens.",
        -- Parsed only because of the "N input tokens" alternative; the older
        -- "(N in the messages, M in the completion)" shape is gone here.
        expect = { kind = "context", limit = 128000, prompt = 62466, retry_at = 128000 - 62466 - 256,
            rate_limit = false },
        hint = "context",
        ladder = { kind = "too_large", transient = false },
    },
    {
        id = "openrouter_context_free_model",
        provider = "openrouter",
        status = 400,
        source = "tests/unit/test_max_tokens.lua + tests/tools/tpm_stub_server.py --openrouter (issue #106)",
        text = "This endpoint's maximum context length is 32768 tokens. However, you requested about 33002 "
            .. "tokens (234 of text input, 32768 in the output). Please reduce the length of either one, "
            .. "or use the \"middle-out\" transform to compress your prompt automatically.",
        expect = { kind = "context", limit = 32768, prompt = 234, retry_at = 32768 - 234 - 256,
            rate_limit = false },
        hint = "context",
        ladder = { kind = "too_large", transient = false },
    },
    {
        id = "openrouter_context_big_model",
        provider = "openrouter",
        status = 400,
        source = "github.com/hotovo/aider-desk/issues/597",
        envelope = '{"error":{"message":"..."}}',
        text = "This endpoint's maximum context length is 1000000 tokens. However, you requested about "
            .. "1012124 tokens (12124 of text input, 1000000 in the output). Please reduce the length of "
            .. "either one, or use the 'middle-out' transform to compress your prompt automatically.",
        expect = { kind = "context", limit = 1000000, prompt = 12124, retry_at = 1000000 - 12124 - 256,
            rate_limit = false },
        hint = "context",
        ladder = { kind = "too_large", transient = false },
    },

    ----------------------------------------------------------------------------
    -- Context overflow where no resend can help (prompt alone over the window,
    -- or the message states no prompt number). nil is the CORRECT answer.
    ----------------------------------------------------------------------------
    {
        id = "vllm_context_prompt_alone_too_big",
        provider = "vllm-family",
        status = 400,
        source = "github.com/vllm-project/vllm/issues/20409",
        text = "This model's maximum context length is 16384 tokens. However, you requested 122946 tokens "
            .. "(112946 in the messages, 10000 in the completion). Please reduce the length of the "
            .. "messages or completion.",
        expect = { kind = "context", limit = 16384, prompt = 112946, rate_limit = false },
        hint = "book_text",
        ladder = { kind = "too_large", transient = false },
    },
    {
        id = "deepseek_context",
        provider = "deepseek",
        status = 400,
        source = "github.com/zed-industries/zed/issues/57718",
        envelope = '{"error":{"message":"...","type":"invalid_request_error","param":null,'
            .. '"code":"invalid_request_error"}}',
        text = "This model's maximum context length is 1048576 tokens. However, you requested 1787370 "
            .. "tokens (1403370 in the messages, 384000 in the completion). Please reduce the length of "
            .. "the messages or completion.",
        expect = { kind = "context", limit = 1048576, prompt = 1403370, rate_limit = false },
        hint = "book_text",
        ladder = { kind = "too_large", transient = false },
    },
    {
        id = "lmstudio_keep_tokens",
        provider = "lmstudio",
        status = 400,
        source = "github.com/lmstudio-ai/lmstudio-bug-tracker/issues/237",
        text = "Trying to keep the first 15857 tokens when context the overflows. However, the model is "
            .. "loaded with context length of only 4096 tokens, which is not enough.",
        -- The "context length of only N" alternative reads the window; the
        -- 15857 is not in any prompt-token shape, and it is over the window
        -- anyway, so declining is right.
        expect = { kind = "context", limit = 4096, prompt = 15857, rate_limit = false },
        hint = "book_text",
        ladder = { kind = "too_large", transient = false },
    },
    {
        id = "anthropic_prompt_too_long",
        provider = "anthropic",
        status = 400,
        source = "github.com/anthropics/claude-code/issues/57296",
        envelope = '{"type":"error","error":{"type":"invalid_request_error","message":"..."},'
            .. '"request_id":"req_..."}',
        text = "prompt is too long: 209375 tokens > 200000 maximum",
        -- 200000 is the model's WINDOW and is not prompt-dependent (the T2
        -- research doc proposed learning it); nothing reads it today.
        expect = { kind = "context", limit = 200000, prompt = 209375, rate_limit = false },
        hint = "none",
        ladder = { kind = "other", transient = false },
    },
    {
        id = "xai_prompt_length",
        provider = "xai",
        status = 400,
        source = "github.com/cline/cline/issues/3120 (xAI grok-3)",
        text = "This model's maximum prompt length is 131072 but the request contains 136973 tokens.",
        expect = { kind = "context", limit = 131072, prompt = 136973, rate_limit = false },
        hint = "none",
        ladder = { kind = "other", transient = false },
    },
    {
        id = "perplexity_messages_tokens",
        provider = "perplexity",
        status = 400,
        source = "community.make.com/t/400-messages-have-xx-tokens-which-exceeds-the-max-limit-of-xx-tokens/53291",
        text = "[400] Messages have 16865 tokens, which exceeds the max limit of 8192 tokens.",
        expect = { kind = "context", limit = 8192, prompt = 16865, rate_limit = false },
        hint = "none",
        ladder = { kind = "other", transient = false },
    },
    {
        id = "cohere_too_many_tokens",
        provider = "cohere",
        status = 400,
        source = "portkey.ai/error-library/input-limit-exceeded-error-10146 (Cohere, input_limit_exceeded_error)",
        text = "Too many tokens: the total number of tokens in the prompt exceeds the limit of 4081. "
            .. "Try using a shorter prompt or enable prompt truncating. "
            .. "See https://docs.cohere.com/reference/generate for more details.",
        expect = { kind = "context", limit = 4081, rate_limit = false },
        hint = "none",
        ladder = { kind = "other", transient = false },
    },
    {
        id = "moonshot_token_limit",
        provider = "moonshot",
        status = 400,
        source = "github.com/MoonshotAI/kimi-cli/issues/2011",
        envelope = "{'error': {'message': '...', 'type': 'invalid_request_error'}}",
        text = "Invalid request: Your request exceeded model token limit: 262144 (requested: 269030)",
        expect = { kind = "context", limit = 262144, requested = 269030, rate_limit = false },
        hint = "none",
        ladder = { kind = "other", transient = false },
    },
    {
        id = "nvidia_nim_input_length",
        provider = "nvidia",
        status = 400,
        source = "forums.developer.nvidia.com/t/api-input-length-1217-exceeds-maximum-allowed-token-size-512-"
            .. "but-configured-the-api-parameters-to-4096/314917",
        text = "Input length 1217 exceeds maximum allowed token size 512",
        expect = { kind = "context", limit = 512, prompt = 1217, rate_limit = false },
        hint = "none",
        ladder = { kind = "other", transient = false },
    },
    {
        id = "openrouter_poolside_input_length",
        provider = "openrouter",
        status = 400,
        source = "github.com/earendil-works/pi/issues/4943 (OpenRouter, poolside backend)",
        text = "Input length 131393 exceeds the maximum allowed input length of 131040 tokens.",
        expect = { kind = "context", limit = 131040, prompt = 131393, rate_limit = false },
        hint = "none",
        ladder = { kind = "other", transient = false },
    },
    {
        id = "gemini_input_token_count",
        provider = "gemini",
        status = 400,
        source = "github.com/google-gemini/gemini-cli/issues/12493",
        envelope = '{"error":{"code":400,"message":"...","errors":[{"message":"..."}]}}',
        text = "The input token count (1236488) exceeds the maximum number of tokens allowed (1048576).",
        expect = { kind = "context", limit = 1048576, prompt = 1236488, rate_limit = false },
        hint = "none",
        ladder = { kind = "other", transient = false },
    },
    {
        id = "dashscope_input_range",
        provider = "qwen",
        status = 400,
        -- Verbatim capture (a Qwen model on Alibaba Cloud Model Studio, printed by the
        -- qwen-code client as "[API Error: 400 <400> InternalError.Algo.InvalidParameter:
        -- Range of input length should be [1, 1048576]]"). The documentation page only
        -- shows the template "Range of input length should be [1, xxx]".
        source = "github.com/QwenLM/qwen-code/issues/350",
        text = "InternalError.Algo.InvalidParameter: Range of input length should be [1, 1048576]",
        expect = { kind = "context", limit = 1048576, rate_limit = false },
        hint = "none",
        ladder = { kind = "other", transient = false },
    },
    {
        id = "together_input_validation",
        provider = "together",
        status = 400,
        source = "github.com/BerriAI/litellm/issues/4934 (Together, TGI dialect)",
        text = "Input validation error: `inputs` tokens + `max_new_tokens` must be <= 4097. "
            .. "Given: 80125 `inputs` tokens and 4096 `max_new_tokens`",
        -- States the window AND the exact prompt, but in TGI's wording: no
        -- pattern reads either. Harmless here (80125 > 4097 anyway), not
        -- harmless on the shape where max_new_tokens is the whole problem.
        expect = { kind = "context", limit = 4097, prompt = 80125, rate_limit = false },
        hint = "none",
        ladder = { kind = "other", transient = false },
    },
    {
        id = "openai_context_legacy_semicolon",
        provider = "openai",
        status = 400,
        source = "community.openai.com/t/annoying-error-if-max-completion-tokens-is-too-high/1111015",
        text = "This model's maximum context length is 4097 tokens, however you requested 5360 tokens "
            .. "(1360 in your prompt; 4000 for the completion). Please reduce your prompt; or completion "
            .. "length.",
        -- The window parses, the prompt does not ("in YOUR prompt"), so a
        -- retry that would have fit is never attempted.
        expect = { kind = "context", limit = 4097, prompt = 1360, retry_at = 4097 - 1360 - 256,
            rate_limit = false },
        known_miss = true,
        hint = "book_text",
        ladder = { kind = "too_large", transient = false },
    },
    {
        id = "anthropic_input_plus_max_tokens",
        provider = "anthropic",
        status = 400,
        source = "github.com/run-llama/llama_index/issues/18520 (same wording in anthropics/claude-code 476)",
        envelope = "{'type': 'error', 'error': {'type': 'invalid_request_error', 'message': '...'}}",
        text = "input length and max_tokens exceed context limit: 154690 + 64000 > 200000, "
            .. "decrease input length or max_tokens and try again",
        -- Anthropic's OWN "the answer budget broke it" wording: window, prompt
        -- and budget are all stated and a resend at 45054 would succeed.
        expect = { kind = "context", limit = 200000, prompt = 154690, retry_at = 200000 - 154690 - 256,
            rate_limit = false },
        known_miss = true,
        hint = "none",
        ladder = { kind = "other", transient = false },
    },

    ----------------------------------------------------------------------------
    -- Wordings that carry no usable numbers at all
    ----------------------------------------------------------------------------
    {
        id = "zai_glm_overflow",
        provider = "zai",
        status = 400,
        source = "github.com/anomalyco/opencode/issues/27629 (Z.AI glm-5 family)",
        text = "tokens in request more than max tokens allowed",
        expect = { kind = "other", rate_limit = false },
        hint = "none",
        ladder = { kind = "other", transient = false },
    },
    {
        id = "minimax_context_window",
        provider = "minimax",
        status = 400,
        source = "github.com/agentscope-ai/QwenPaw/issues/1273 (MiniMax code 2013)",
        text = "invalid params, context window exceeds limit",
        expect = { kind = "other", rate_limit = false },
        hint = "none",
        ladder = { kind = "other", transient = false },
    },
    {
        id = "llamacpp_context",
        provider = "llama.cpp",
        status = 400,
        source = "github.com/continuedev/continue/issues/9797 (llama-server, send_error)",
        text = "the request exceeds the available context size, try increasing it",
        expect = { kind = "other", rate_limit = false },
        hint = "none",
        ladder = { kind = "other", transient = false },
    },

    ----------------------------------------------------------------------------
    -- Per-minute ADMISSION refusals: prompt + requested budget counted before
    -- the model runs (issue #106)
    ----------------------------------------------------------------------------
    {
        id = "groq_413_reddit",
        provider = "groq",
        status = 413,
        source = "docs/max_tokens_tpm_investigation.md + issue #106 (Reddit screenshot, free plan)",
        envelope = '{"error":{"message":"...","type":"tokens","code":"rate_limit_exceeded"}}',
        text = "Request too large for model `openai/gpt-oss-20b` in organization `org_01kx` service tier "
            .. "`on_demand` on tokens per minute (TPM): Limit 8000, Requested 32979, please reduce your "
            .. "message size and try again. Need more tokens? Upgrade to Dev Tier today at "
            .. "https://console.groq.com/settings/billing",
        expect = { kind = "admission", limit = 8000, requested = 32979, rate_limit = true },
        refusal_kind = "admission",
        hint = "admission",
        ladder = { kind = "too_large", transient = false },
    },
    {
        id = "groq_413_continue",
        provider = "groq",
        status = 413,
        source = "github.com/continuedev/continue/issues/10218",
        text = "413 Request too large for model `llama-3.3-70b-versatile` in organization "
            .. "`org_01kgg5588eftc8k70aes4864eb` service tier `on_demand` on tokens per minute (TPM): "
            .. "Limit 12000, Requested 14137, please reduce your message size and try again.",
        expect = { kind = "admission", limit = 12000, requested = 14137, rate_limit = true },
        refusal_kind = "admission",
        hint = "admission",
        ladder = { kind = "too_large", transient = false },
    },
    {
        id = "groq_413_eliza",
        provider = "groq",
        status = 413,
        source = "github.com/elizaOS/eliza/issues/4040",
        text = "Request too large for model `llama-3.1-8b-instant` in organization `xxxx` service tier "
            .. "`on_demand` on tokens per minute (TPM): Limit 6000, Requested 6294",
        expect = { kind = "admission", limit = 6000, requested = 6294, rate_limit = true },
        refusal_kind = "admission",
        hint = "admission",
        ladder = { kind = "too_large", transient = false },
    },
    {
        id = "openai_413_admission",
        provider = "openai",
        status = 429,
        source = "tests/unit/test_rate_limits.lua fixture (OpenAI 'tokens per min' spelling)",
        text = "Request too large for gpt-4o in organization org-abc on tokens per min (TPM): Limit 30000, "
            .. "Requested 40000. The input or output tokens must be reduced in order to run successfully.",
        expect = { kind = "admission", limit = 30000, requested = 40000, rate_limit = true },
        refusal_kind = "admission",
        hint = "admission",
        ladder = { kind = "too_large", transient = false },
    },
    {
        id = "cerebras_tpm",
        provider = "cerebras",
        status = 429,
        source = "github.com/anomalyco/opencode/issues/7463; mechanism documented at "
            .. "inference-docs.cerebras.ai/support/rate-limits",
        text = "Tokens per minute limit exceeded - too many tokens processed",
        -- Cerebras gates on max_completion_tokens the same way Groq does but
        -- states NO numbers, so only the headers can size the budget. It is
        -- still an admission refusal: refusalKind classifies it (parseRefusal
        -- cannot, having no numbers to return).
        expect = { kind = "admission", rate_limit = true },
        refusal_kind = "admission",
        hint = "admission_numberless",
        ladder = { kind = "too_large", transient = false },
    },

    ----------------------------------------------------------------------------
    -- Ordinary rate-limit bursts (the window is already spent)
    ----------------------------------------------------------------------------
    {
        id = "groq_429_tpm_burst",
        provider = "groq",
        status = 429,
        source = "github.com/danielmiessler/fabric/issues/364",
        envelope = "{'error': {'message': '...', 'type': 'tokens', 'code': 'rate_limit_exceeded'}}",
        text = "Rate limit reached for model `llama3-70b-8192` in organization "
            .. "`org_01hrsvc1b8ey0anvbgha0xckf2` on tokens per minute (TPM): Limit 7000, Used 0, "
            .. "Requested ~12903. Please try again in 50.597142857s.",
        -- The numbers are read after the per-minute signature only. An
        -- unanchored search captured the "3" of "llama3" (the first digits
        -- after the word "limit" in "Rate limit reached...") instead of 7000.
        expect = { kind = "burst", limit = 7000, requested = 12903, used = 0, rate_limit = true },
        refusal_kind = "burst",
        hint = "burst",
        ladder = { kind = "rate_limited", transient = true },
    },
    {
        id = "groq_429_tpm_burst_gemma",
        provider = "groq",
        status = 429,
        source = "github.com/Aider-AI/aider/issues/3265 (Groq via litellm; the organization id is "
            .. "redacted as `...` at the source)",
        envelope = '{"error":{"message":"...","type":"tokens","code":"rate_limit_exceeded"}}',
        text = "Rate limit reached for model `gemma2-9b-it` in organization `...` service tier "
            .. "`on_demand` on tokens per minute (TPM): Limit 15000, Used 11972, Requested 4351. "
            .. "Please try again in 5.289s. Visit https://console.groq.com/docs/rate-limits for more "
            .. "information.",
        -- A second model id, because the digit an unanchored search steals moves
        -- with the name: `llama3` gave 3 above, `gemma2` gives 2 here.
        expect = { kind = "burst", limit = 15000, requested = 4351, used = 11972, rate_limit = true },
        refusal_kind = "burst",
        hint = "burst",
        ladder = { kind = "rate_limited", transient = true },
    },
    {
        id = "openai_429_tpm_burst",
        provider = "openai",
        status = 429,
        source = "github.com/openai/codex/issues/88",
        envelope = '{"type":"tokens","code":"rate_limit_exceeded","param":null,"message":"..."}',
        text = "Rate limit reached for o4-mini in organization org-**** on tokens per min (TPM): "
            .. "Limit 200000, Used 162960, Requested 42288. Please try again in 1.574s. "
            .. "Visit https://platform.openai.com/account/rate-limits to learn more.",
        -- Same anchoring point; the unanchored pattern captured the "4" of
        -- "o4-mini" here.
        expect = { kind = "burst", limit = 200000, requested = 42288, used = 162960, rate_limit = true },
        refusal_kind = "burst",
        hint = "burst",
        ladder = { kind = "rate_limited", transient = true },
    },
    {
        id = "groq_429_tpd_burst",
        provider = "groq",
        status = 429,
        source = "github.com/continuedev/continue/issues/10920",
        text = "Rate limit reached for model `llama-3.3-70b-versatile` in organization "
            .. "`org_01kjh7p9n8f1qs6nz2bz77vy6b` service tier `on_demand` on tokens per day (TPD): "
            .. "Limit 100000, Used 97050, Requested 3619. Please try again in 9m38.016s.",
        -- A DAILY bucket: a per-minute resend must never fire here, and does
        -- not (no per-minute signature in the text). refusal_kind is therefore
        -- absent = nil: not a per-minute refusal at all.
        expect = { kind = "burst", rate_limit = true },
        hint = "burst",
        ladder = { kind = "rate_limited", transient = true },
    },
    {
        id = "openai_429_rpm_burst",
        provider = "openai",
        status = 429,
        source = "developers.openai.com/cookbook/examples/how_to_handle_rate_limits",
        text = "Rate limit reached for default-codex in organization org-{id} on requests per min. "
            .. "Limit: 20.000000 / min. Current: 24.000000 / min.",
        -- Requests, not tokens: nothing to resize, and refusal_kind is absent =
        -- nil for the same reason (no per-minute TOKEN signature).
        expect = { kind = "burst", rate_limit = true },
        hint = "burst",
        ladder = { kind = "rate_limited", transient = true },
    },
}

--------------------------------------------------------------------------------
-- Matching: what the three parsers must produce for one entry
--------------------------------------------------------------------------------

--- @return boolean ok, string detail
local function checkEntry(entry)
    local e = entry.expect
    local mt = ModelConstraints.parseMaxTokensError(entry.text)
    local rf = RateLimits.parseRefusal(entry.text)

    if e.kind == "output_cap" then
        if not mt then return false, "parseMaxTokensError returned nil" end
        if mt.kind ~= "output_cap" then return false, "kind is " .. tostring(mt.kind) end
        if mt.cap ~= e.limit then
            return false, "cap is " .. tostring(mt.cap) .. ", expected " .. tostring(e.limit)
        end
        if rf ~= nil then return false, "parseRefusal fired on an output cap" end
        return true, "output_cap " .. tostring(mt.cap)
    end

    if e.kind == "context" then
        if rf ~= nil then return false, "parseRefusal fired on a context overflow" end
        if e.retry_at == nil then
            if mt ~= nil then
                return false, "expected no retry, got " .. tostring(mt.kind) .. " retry_at=" .. tostring(mt.retry_at)
            end
            return true, "no retry (correct: the prompt alone does not fit)"
        end
        if not mt then return false, "parseMaxTokensError returned nil" end
        if mt.kind ~= "context" then return false, "kind is " .. tostring(mt.kind) end
        if mt.limit ~= e.limit then
            return false, "limit is " .. tostring(mt.limit) .. ", expected " .. tostring(e.limit)
        end
        if mt.prompt ~= e.prompt then
            return false, "prompt is " .. tostring(mt.prompt) .. ", expected " .. tostring(e.prompt)
        end
        if mt.retry_at ~= e.retry_at then
            return false, "retry_at is " .. tostring(mt.retry_at) .. ", expected " .. tostring(e.retry_at)
        end
        return true, "context retry_at " .. tostring(mt.retry_at)
    end

    if e.kind == "admission" or e.kind == "burst" then
        if mt ~= nil then return false, "parseMaxTokensError fired on a rate-limit message" end
        if e.limit == nil and e.requested == nil then
            if rf ~= nil then
                return false, "expected no numbers, got limit=" .. tostring(rf.limit)
                    .. " requested=" .. tostring(rf.requested)
            end
            return true, "no numbers (correct)"
        end
        if not rf then return false, "parseRefusal returned nil" end
        if rf.limit ~= e.limit then
            return false, "limit is " .. tostring(rf.limit) .. ", expected " .. tostring(e.limit)
        end
        if rf.requested ~= e.requested then
            return false, "requested is " .. tostring(rf.requested) .. ", expected " .. tostring(e.requested)
        end
        -- "Used N" is what separates a spent bucket from a request that was too
        -- big to admit, so the corpus asserts it (absent in the expectation
        -- means the wording carries none).
        if rf.used ~= e.used then
            return false, "used is " .. tostring(rf.used) .. ", expected " .. tostring(e.used)
        end
        return true, "limit " .. tostring(rf.limit) .. " requested " .. tostring(rf.requested)
            .. " used " .. tostring(rf.used)
    end

    -- kind "other": nothing may be extracted
    if mt ~= nil then return false, "parseMaxTokensError fired on a numberless message" end
    if rf ~= nil then return false, "parseRefusal fired on a numberless message" end
    return true, "nothing extracted (correct)"
end

--------------------------------------------------------------------------------
-- Run
--------------------------------------------------------------------------------

print("test_error_wordings: real provider wordings for output caps, context overflow and per-minute limits")

local seen_ids = {}
local misses, hits = 0, 0

for _idx, entry in ipairs(CORPUS) do
    -- Corpus hygiene: ids unique, every entry sourced and verbatim.
    TestRunner.assert(entry.id and not seen_ids[entry.id], "corpus id is unique: " .. tostring(entry.id))
    seen_ids[entry.id] = true
    TestRunner.assert(type(entry.source) == "string" and entry.source ~= "",
        entry.id .. ": carries a source")
    TestRunner.assert(type(entry.text) == "string" and #entry.text > 0,
        entry.id .. ": carries the verbatim text")
    TestRunner.assert(type(entry.provider) == "string" and entry.provider ~= "",
        entry.id .. ": names a provider")
    TestRunner.assert(type(entry.status) == "number", entry.id .. ": records an HTTP status")

    -- isRateLimitError decides persistent dialog vs 3-second toast.
    local is_rl = ModelConstraints.isRateLimitError(entry.text)
    TestRunner.assert(is_rl == entry.expect.rate_limit,
        entry.id .. ": isRateLimitError is " .. tostring(is_rl)
            .. ", expected " .. tostring(entry.expect.rate_limit))

    -- refusalKind decides whether a resend can help: a burst waits for the
    -- bucket to refill, an admission refusal can be resized. Every entry is
    -- asserted, so a wording outside the two per-minute sections must classify
    -- as nil (its refusal_kind field is absent).
    local rk = RateLimits.refusalKind(entry.text)
    TestRunner.assert(rk == entry.refusal_kind,
        entry.id .. ": refusalKind is " .. tostring(rk)
            .. ", expected " .. tostring(entry.refusal_kind))

    -- ONE tip per refusal, and the right one (audit B2). The message the reader
    -- sees is the decorated one, so build it the way the query router does and
    -- assert that the expected hint fired, once, and no other did.
    local decorated = ModelConstraints.decorateRequestError(entry.text, entry.provider, nil, nil)
    TestRunner.assert(entry.hint == "none" or ModelConstraints.HINT_HEADS[entry.hint] ~= nil,
        entry.id .. ": names a known hint (" .. tostring(entry.hint) .. ")")
    for head_id, needle in pairs(ModelConstraints.HINT_HEADS) do
        local fired = decorated:find(needle, 1, true) ~= nil
        TestRunner.assert(fired == (head_id == entry.hint),
            entry.id .. ": hint '" .. head_id .. "' fired = " .. tostring(fired)
                .. ", expected hint '" .. tostring(entry.hint) .. "'")
    end
    if entry.hint ~= "none" then
        -- A tip must not be appended twice either (the F12 double-tip shape).
        local needle, count, pos = ModelConstraints.HINT_HEADS[entry.hint], 0, 1
        while true do
            local at = decorated:find(needle, pos, true)
            if not at then break end
            count = count + 1
            pos = at + 1
        end
        TestRunner.assert(count == 1,
            entry.id .. ": the '" .. entry.hint .. "' tip appears " .. count .. " times, expected once")
    end

    -- The unattended ladder grades the SAME decorated string (audit B2b): an
    -- admission refusal or a size 400 must never buy the one 60-second retry.
    local lk, lt = XrayAuto.classifyStopReason(decorated)
    TestRunner.assert(lk == entry.ladder.kind and lt == entry.ladder.transient,
        entry.id .. ": classifyStopReason is " .. tostring(lk) .. "/" .. tostring(lt)
            .. ", expected " .. tostring(entry.ladder.kind) .. "/" .. tostring(entry.ladder.transient))

    local ok, detail = checkEntry(entry)
    if entry.known_miss then
        misses = misses + 1
        TestRunner.assert(not ok,
            entry.id .. ": marked known_miss but the parsers now match it -- update the corpus (" .. detail .. ")")
        if not ok then
            print("  KNOWN MISS: " .. entry.id .. " (" .. entry.provider .. ", "
                .. entry.expect.kind .. ") -- " .. detail)
        end
    else
        hits = hits + 1
        TestRunner.assert(ok, entry.id .. ": " .. detail)
    end
end

print(string.format("\n  corpus: %d entries (%d parsed as expected, %d known misses)",
    #CORPUS, hits, misses))

-- The corpus must keep covering every failure class and both wire families,
-- otherwise a future trim could quietly delete the interesting half.
do
    local kinds, providers = {}, {}
    for _idx, entry in ipairs(CORPUS) do
        kinds[entry.expect.kind] = (kinds[entry.expect.kind] or 0) + 1
        providers[entry.provider] = true
    end
    for _idx, k in ipairs({ "output_cap", "context", "admission", "burst", "other" }) do
        TestRunner.assert((kinds[k] or 0) > 0, "corpus still covers the " .. k .. " class")
    end
    for _idx, p in ipairs({ "openai", "anthropic", "gemini", "groq", "openrouter", "vllm-family" }) do
        TestRunner.assert(providers[p], "corpus still covers " .. p)
    end
end

-- The lever sentence names what the failing surface can actually change (F35).
do
    local cerebras = "Tokens per minute limit exceeded - too many tokens processed"
    local function decorated(features)
        return ModelConstraints.decorateRequestError(cerebras, "cerebras", nil, { features = features })
    end
    local cases = {
        { { is_library_context = true }, "Library scanning", "library action names the folder list" },
        { { is_general_context = true }, "Attach button", "general chat names the Attach button" },
        { { _spoiler_live = false }, "whole artifact", "artifact chat is told the artifact is the prompt" },
        { { _xray_chat_active = true }, "new X-Ray chat", "X-Ray chat names a new X-Ray chat" },
        { {}, "smaller scope", "book request keeps the scope wording" },
        { nil, "smaller scope", "no features at all: the book wording" },
    }
    for _idx, c in ipairs(cases) do
        local out = decorated(c[1])
        TestRunner:assert(out:find(c[2], 1, true) ~= nil, "lever: " .. c[3] .. " -- got: " .. out:sub(-160))
    end
    TestRunner:assert(decorated(nil):find("smaller scope", 1, true) ~= nil, "nil config falls back to the book wording")
end

-- Decorating an already-decorated message adds nothing (retry surfaces re-report).
do
    for _idx, entry in ipairs(CORPUS) do
        local once = ModelConstraints.decorateRequestError(entry.text, entry.provider, nil, nil)
        local twice = ModelConstraints.decorateRequestError(once, entry.provider, nil, nil)
        TestRunner.assert(twice == once, entry.id .. ": a second decoration changes nothing")
    end
end

print(string.format("\n%d passed, %d failed", TestRunner.passed, TestRunner.failed))
return TestRunner.failed == 0
