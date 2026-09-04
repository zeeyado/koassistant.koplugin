# KOAssistant Test Suite

Standalone test framework for testing KOAssistant without running KOReader's GUI.

## Important: Run from a KOReader Installation

The test suite must run from within a **KOReader installation** where KOAssistant is installed. This is because:

- **API keys** are read from your KOAssistant settings (`koassistant_settings.lua`) or `apikeys.lua`
- **Domains and behaviors** are loaded from your `domains/` and `behaviors/` folders
- **Settings** (language, temperature, behavior) sync from your actual configuration

### KOReader Plugin Paths by Platform

| Platform | Path |
|----------|------|
| **Kobo/Kindle** | `/mnt/onboard/.adds/koreader/plugins/koassistant.koplugin/` |
| **Android** | `/sdcard/koreader/plugins/koassistant.koplugin/` |
| **macOS** | `~/Library/Application Support/koreader/plugins/koassistant.koplugin/` |
| **Linux** | `~/.config/koreader/plugins/koassistant.koplugin/` |
| **Windows** | `%APPDATA%\koreader\plugins\koassistant.koplugin\` |

### First-Time Setup

> **Note:** The `tests/` directory is excluded from release zips to keep downloads small. To run tests, you need to **clone the repository** from GitHub:
> ```bash
> git clone https://github.com/zzzsm/koassistant.git
> ```
> Then copy or symlink the cloned folder to your KOReader plugins directory.

1. **Install KOReader** on your computer (download from [koreader.rocks](https://koreader.rocks))
2. **Clone KOAssistant** from GitHub (release zips don't include tests)
3. **Copy to plugins folder** or create a symlink
4. **Launch KOReader once** to create the settings file
4. **Add your API keys** via Settings → API Keys (or create `apikeys.lua`)
5. **Run tests** from the plugin directory

**Pro tip:** If you already have KOAssistant configured on your e-reader, use [Backup & Restore](../README.md#backup--restore) to export your settings and import them on your computer.

## Quick Start

```bash
# Navigate to your KOAssistant plugin directory (see paths above)
cd ~/Library/Application\ Support/koreader/plugins/koassistant.koplugin  # macOS
cd ~/.config/koreader/plugins/koassistant.koplugin                       # Linux

# Run unit tests (fast, no API calls)
lua tests/run_tests.lua --unit

# Run provider connectivity tests
lua tests/run_tests.lua

# Validate all models (detects constraints, ~1 token per model)
lua tests/run_tests.lua --models

# Test reasoning/thinking across providers
lua tests/run_tests.lua --reasoning

# Inspect request structure
lua tests/inspect.lua anthropic

# Start web UI for interactive testing
lua tests/inspect.lua --web
```

## Tools

### Test Runner (`run_tests.lua`)

Runs automated tests against providers.

```bash
# Unit tests only (no API calls)
lua tests/run_tests.lua --unit

# Basic connectivity for all providers
lua tests/run_tests.lua

# Single provider
lua tests/run_tests.lua anthropic

# Comprehensive tests (behaviors, temps, domains)
lua tests/run_tests.lua anthropic --full

# Validate ALL models for a provider (minimal cost)
lua tests/run_tests.lua --models openai

# Validate all models across all providers
lua tests/run_tests.lua --models

# Verbose output
lua tests/run_tests.lua -v
```

### Model Audit & Capability Probe (`model_audit.lua`)

Discovery + empirical probing for model updates (agenda item 20). Fetches each
keyed provider's live model list, diffs it against `koassistant_model_lists.lua`
(noise-filtered, snapshots/`-latest` aliases collapsed), then probes chosen
models for the facts `/models` never reports — temperature acceptance, reasoning
default, effort ladder, disable support, output ceiling, tools — and emits DRAFT
`model_constraints.lua` stanzas annotated against the current resolution layer.
Never auto-applies anything; tier placement stays human.

```bash
eval "$(luarocks --lua-version 5.5 path)"   # required first: real HTTP + dkjson

# Discovery diff (list GETs only, no generation cost)
lua tests/model_audit.lua
lua tests/model_audit.lua anthropic gemini

# Probe battery on one model (~10-14 live micro-requests, fractions of a cent)
lua tests/model_audit.lua --probe anthropic claude-opus-5

# Probe everything the diff found (capped at 10 per run)
lua tests/model_audit.lua --probe-new

lua tests/model_audit.lua --verbose   # full error bodies + ignored-id lists
```

OpenRouter runs in marketplace mode (verifies curated ids exist + cross-checks
their `supported_parameters` against our resolution instead of listing hundreds
of "new" backends). Pure helpers are unit-tested in
`tests/unit/test_model_audit.lua`; the probe engine itself is live-only.

### Request Inspector (`inspect.lua`)

Visualize exactly what requests are sent to each provider.

```bash
# Inspect single provider
lua tests/inspect.lua anthropic
lua tests/inspect.lua openai --behavior full

# Compare providers side-by-side
lua tests/inspect.lua --compare anthropic openai gemini

# Export as JSON
lua tests/inspect.lua --export anthropic > request.json

# List providers and presets
lua tests/inspect.lua --list

# Use presets
lua tests/inspect.lua anthropic --preset thinking
lua tests/inspect.lua anthropic --preset domain

# Custom options
lua tests/inspect.lua anthropic --behavior minimal --temp 0.5
lua tests/inspect.lua anthropic --languages "English, Spanish"
lua tests/inspect.lua anthropic --thinking 8192
```

**Presets:** `minimal`, `full`, `domain`, `thinking`, `multilingual`, `custom`

### Web UI (`inspect.lua --web`)

Interactive browser-based request inspector.

```bash
# Start web server (default port 8080)
lua tests/inspect.lua --web

# Custom port
lua tests/inspect.lua --web --port 3000

# Then open http://localhost:8080
```

**Features:**
- Live request building (no API calls needed)
- **Send Request** to actually call provider APIs
- Provider/model selection for every built-in provider
- Behavior toggles, temperature slider, **max tokens slider**
- **Domain loading** from your actual `domains/` folder
- **Action loading** from `prompts/actions.lua` + custom actions from settings
- **Ask action** available in all contexts (like plugin)
- **Settings sync** from your `koassistant_settings.lua` (languages, behavior, temperature)
- **Context simulation** (highlight text, book title/author, multi-book)
- Language settings with translation target dropdown
- Extended thinking configuration (Anthropic, OpenAI, Gemini)
- Syntax-highlighted JSON output with **per-box copy buttons**
- **Expandable editor** with placeholder insertion for action prompts
- **Chat tab** with conversation view (matches plugin - no system shown)
- **Multi-turn chat** with reply input (Enter key or Reply button)
- **Response tab** shows raw API response, metadata (status, timing) shown separately
- **Auto-scroll** chat to bottom on new messages
- **Reset button** to restore defaults
- Dark mode support

## Test Categories

### Unit Tests (no API calls)

Located in `tests/unit/` — **96 files, ~3,180 checks** (run `lua tests/run_tests.lua --unit` for the live count; the runner prints a per-file summary and no grand total).

**Contract every test file must follow:** end with `return TestRunner.failed == 0` (or return a `runAll` table). ⚠ The harness treats a `nil` return as PASSING — a forgotten return line yields a false green. Read the printed per-file summaries, not just the exit code.

**Running a single file:** there is no filter flag; run directly from the repo root: `lua tests/unit/test_xray_parser.lua`.

The 96 files, with what each one pins:

- `test_action_cache_parity.lua` - ActionCache `set()` / `saveCache()` / `loadCache()` field parity through a real disk round-trip
- `test_action_display_text.lua` - `ActionService.getActionDisplayText`: the badge text on action buttons
- `test_action_service.lua` - pure ActionService helpers: copyAction, getApiParams, custom-action flag migration, duplicate naming
- `test_actions.lua` - placeholder gating, flag cascading, `DOUBLE_GATED_FLAGS`, `inferOpenBookFlags()`
- `test_anthropic_tools_request.lua` - Anthropic tool declarations and replay, through the handler's real `buildRequestBody`
- `test_api_keys.lua` - multi-key resolution: listApiKeys / getApiKey / keyFingerprint over every store shape, GUI-before-file order, stale-selection fallback
- `test_artifact_writeback.lua` - the shared write-back primitive: metadata reconciliation, coverage/gaps, commitXray/applyXray round-trips, the never-archive-a-rung rule
- `test_attachments.lua` - Attach chip engine: per-type budgets, staging list, builders, wire framing
- `test_auto_update.lua` - auto-update helpers (verify, preserve, restore) against real temp directories
- `test_backup_roundtrip.lua` - the real BackupManager backing up and restoring end to end in a temp filesystem
- `test_book_groups.lua` - book-groups store: CRUD, manual ordering, move re-keying policy, merge-candidate order
- `test_book_picker.lua` - the book picker's pure ordering helpers (the picker hands callers a set; order must be imposed)
- `test_book_settings.lua` - per-book resolvers and overrides: AI title/author, book-info level, spoiler, quiz, language, tools posture, sidecar key count
- `test_book_store.lua` - Track 37: the sidecar facade, per-book store, chats file, `migrateBook` / `ensureMigrated` / `migrateAll`
- `test_book_tool_runner.lua` - the book tool runner: interactive loop, gather mode, spoiler clamping of the reading scope
- `test_book_tools.lua` - the `toc` / `search_book` / `read_around` tool implementations
- `test_chapter_presets.lua` - chapter scope presets: availability matrix, spoiler clamp, agreement with the quiz chapter resolution
- `test_chat_persistence.lua` - chat save/load round-trips, tags, renames, and full-replacement saves
- `test_chip_scope.lua` - the Scope chip's range resolution (kind x spoiler x position)
- `test_constants.lua` - context lists, expansion, validation, GitHub URLs
- `test_constraint_utils.lua` - the test-side constraint wrapper delegates to the plugin's own constraints
- `test_context_routing.lua` - actions belong to the right context, input-dialog defaults are valid, library stays isolated
- `test_context_windows.lua` - `ModelConstraints.checkContextWindow`, the model-aware extraction pre-check
- `test_custom_openai_reasoning.lua` - custom-provider reasoning wire translation in `customizeRequestBody`
- `test_dict_buttons.lua` - dictionary-popup button specs: ids, ordering, row groups, visibility gating
- `test_dispatch_sizing.lua` - `ModelConstraints.dispatchModel` is the one model id a request is keyed under (includes a structural source scan)
- `test_doc_settings_resolver.lua` - SafeDocSettings: live-instance resolution and samePath alias handling (#72)
- `test_doi_resolver.lua` - DOI matching, extraction from metadata and page text, resolution
- `test_effective_props.lua` - `overlayCustomProps` plus the structural gate over every raw `doc_props` read
- `test_error_wordings.lua` - the real provider wordings for output-cap / context / admission refusals, as a corpus
- `test_export.lua` - export formatting: content modes, styles, filenames, cache content
- `test_gemini_tools_request.lua` - Gemini tool request construction
- `test_gettext_lang_cache.lua` - the gettext language cache (no settings re-read per `_()` call)
- `test_gettext_unescape.lua` - the PO parser unescapes both msgid and msgstr
- `test_handler_max_tokens.lua` - every provider handler both resolves and clamps max_tokens (the handler contract)
- `test_image_gen.lua` - image-model inventory, provider resolution chain, the book-association index
- `test_index_rebuild.lua` - index heal/rebuild (#92): refresh ops, per-book helpers, merge semantics, pruning
- `test_library_scanner.lua` - library metadata extraction, status categorization, formatted catalog
- `test_loaders.lua` - BehaviorLoader and DomainLoader file loading, sorting, retrieval
- `test_math.lua` - the LaTeX to readable HTML converter (#105), including the luamd safety rules
- `test_max_tokens.lua` - `resolveMaxTokens` / `clampMaxTokens`: raise-where-known defaults, pin clamping
- `test_message_builder.lua` - placeholder resolution in message_builder.lua, including the replace_placeholder loop gotcha
- `test_message_history.lua` - conversation tracking, token estimation, reasoning entries
- `test_migrations.lua` - the one-time settings upgrade chain, fixture-based, including idempotence
- `test_minimal_popup_registry.lua` - `Constants.resolveMinimalPopupActions` read-through (nil = defaults, empty stays empty)
- `test_model_audit.lua` - the pure helpers of `tests/model_audit.lua`: diff classification, ceiling parsing, draft stanzas
- `test_model_overrides.lua` - the capability resolution layer: user overrides, derived metadata, family-prefix fallbacks
- `test_model_refresh.lua` - `ModelLists.resolveModelRefresh`: never clobber a deliberate model pick
- `test_model_tiers.lua` - the 5-tier ladder, retired-tier read-through, descend-only fallback, array-membership invariant
- `test_non200_errors.lua` - API error extraction and the tip gating in the error dialog
- `test_notebook_snippet.lua` - notebook snippet formatting and append, with a real file round-trip
- `test_ollama_endpoints.lua` - Ollama server address normalization and the wire routing at the active endpoint
- `test_ollama_num_ctx.lua` - per-request `num_ctx` sizing (the silent-truncation guard)
- `test_ollama_tools_request.lua` - Ollama tool declarations, decoded-object arguments, ignored `tool_choice`
- `test_openai_codex_handler.lua` - OpenAI Subscription: codex endpoint, OAuth headers, collected-SSE transport, web-search and tool wire
- `test_openai_codex_oauth.lua` - device-code OAuth: user-code / poll / exchange / refresh requests, JWT claims
- `test_openai_compatible.lua` - the OpenAI-compatible base handler and its hooks
- `test_openai_responses.lua` - the OpenAI Responses path: routing, request builder, transformer, stream events
- `test_openai_tools_request.lua` - OpenAI chat-completions tool declarations and the message-copy loop
- `test_pinned_manager_parity.lua` - pinned save/load long-string round-trip against adversarial content
- `test_prompt_building.lua` - MessageBuilder, ContextExtractor privacy gating and cache flow end to end
- `test_prompt_chars.lua` - `RateLimits.promptChars` stays the router's own prompt-size arithmetic
- `test_quick_preset_forces.lua` - `Dialogs.quickPresetForces`, the quick-preset facet-off rule
- `test_quick_reply_overrides.lua` - reply-time re-derivation of web / tools / model / reasoning from the Quick baseline
- `test_quiz_chapters.lua` - pure chapter-boundary resolution for the chapter-end quiz
- `test_quiz_parser.lua` - quiz JSON extraction and unescaped-quote repair
- `test_rate_limits.lua` - per-minute admission limits: header capture, pipe marker, session memo, refusal parsing, budget sizing
- `test_reasoning.lua` - reasoning parameter injection and reasoning-content parsing
- `test_reply_quote.lua` - the "Add to reply" quote formatting and popup gating
- `test_response_parser.lua` - per-provider response parsing from mock responses (the Responses-API transformer is covered in `test_openai_responses.lua`)
- `test_session_chips_registry.lua` - `Constants.resolveSessionChips` auto-injection (a new chip appears, a dismissed one stays gone)
- `test_setup_wizard.lua` - wizard pure helpers: font install dir, `font_ui_fallbacks` append semantics, completer probes
- `test_sidecar_gating.lua` - sidecar (file browser) reads and identical privacy gating
- `test_state_management.lua` - context detection, flag isolation, config merge, transient flags, cache permission gating
- `test_stats_reader.lua` - engagement group computation and labels from mock stats
- `test_storage_modes.lua` - chat index rebuild phases and lazy sidecar migration
- `test_storage_registry.lua` - the registry stays the single source of truth, including a source-literal scan
- `test_stream_ratelimit_marker.lua` - the streaming consumer drains the pipe and learns the plan on both transports
- `test_streaming_parser.lua` - SSE/NDJSON content extraction
- `test_surrounding_context.lua` - surrounding-context trims, the per-action tri-state, placeholder vs ambient append
- `test_system_prompts.lua` - behavior resolution, language parsing, unified system building
- `test_templates.lua` - template constants, nudge substitution, no literal placeholders left in built-in actions
- `test_tool_wire.lua` - the per-provider tool-turn adapters
- `test_wave1_tools_request.lua` - DeepSeek / Mistral / Groq / xAI tool requests at handler level, plus the xAI routing invariant
- `test_web_search.lua` - web-search request building, response parsing, streaming detection
- `test_web_tools.lua` - the SearXNG / Tavily backend module (built but not wired into the plugin yet): request and parse, null sentinels, result formatting
- `test_xai_responses.lua` - the xAI Responses routing and request builder
- `test_xray_auto.lua` - the background auto-update gate matrix and the checkpoint ring
- `test_xray_card.lua` - the entity card's identification line (`firstSentence` / `sentenceEnd`) and its resolve ordering
- `test_xray_category_prompts.lua` - X-Ray category prompt assembly (full stays byte-identical, filtered drops the rest)
- `test_xray_counting.lua` - occurrence counting: match spans, word boundaries, union of name and aliases
- `test_xray_dedup.lua` - duplicate scan, merge application, never-merge storage, AI-merge prompt sentinels
- `test_xray_merge.lua` - the parser's programmatic merge and the entity index
- `test_xray_merge_engine.lua` - the merge engine's pure halves: prompts, unions, scope, consent gate
- `test_xray_parser.lua` - X-Ray JSON extraction and the shared unescaped-quote repair
- `test_xray_predecessor.lua` - the cross-book tiers (#90): group walk and memo, route fold, card ordering, carry, the chain

### Integration Tests (real API calls)

| Mode | Description |
|------|-------------|
| Default | Basic connectivity (API responds, returns string) |
| `--full` | Behaviors, temperatures, domains, languages, extended thinking |
| `--models` | Validate ALL models (~1 token each), detect parameter constraints |
| `--reasoning` | Test reasoning/thinking parameters across providers |

#### Model Validation (`--models`)

Tests every model in `koassistant_model_lists.lua` with ultra-minimal requests to discover:
- Invalid model names (404 errors)
- Parameter constraints (temperature, max_tokens requirements)
- Access restrictions

**Features:**
- Pre-checks model names via provider APIs (OpenAI, Gemini, Ollama)
- Auto-retries with adjusted parameters when constraints detected
- Reports working models, constraints found, and invalid models

**Example output:**
```
[openai] Testing 15 models...
  Pre-check: 1 models not in API list
    ⚠ o3-pro
  gpt-5.2                    ⚠ CONSTRAINT: max_tokens (default rejected, max_tokens=16 works)
  gpt-5-mini                 ⚠ CONSTRAINT: multiple constraints (temp=1.0 + max_tokens=16 works)
  gpt-4.1                    ✓ OK (789ms)

Detected Constraints:
  openai/gpt-5.2: requires max_tokens >= 16
  openai/gpt-5-mini: requires temp=1.0 + max_tokens >= 16
```

## Test Utilities

### `tests/lib/constraint_utils.lua`

Wrapper around plugin's `model_constraints.lua` module that eliminates duplicated constraint logic in tests.

**Why it exists**: Tests used to duplicate temperature constraints, reasoning defaults, and error parsing logic. This caused drift when plugin constraints changed.

**Functions**:
```lua
local ConstraintUtils = require("tests.lib.constraint_utils")

-- Get max temperature for provider (1.0 for Anthropic, 2.0 for others)
local max_temp = ConstraintUtils.getMaxTemperature("anthropic")  -- Returns 1.0

-- Get default temperature from plugin's Defaults module
local default_temp = ConstraintUtils.getDefaultTemperature("openai")  -- Returns 0.7

-- Get reasoning defaults (extended thinking budgets, effort levels)
local anthropic_reasoning = ConstraintUtils.getReasoningDefaults("anthropic")
-- Returns: { budget = 32000, budget_min = 1024, budget_max = 32000, ... }

local openai_reasoning = ConstraintUtils.getReasoningDefaults("openai")
-- Returns: { effort = "medium", effort_options = { "low", "medium", "high" } }

-- Check if model supports capability
local supports = ConstraintUtils.supportsCapability("anthropic", "claude-sonnet-4-5", "extended_thinking")
-- Returns: true

-- Parse constraint errors from API responses
local constraint = ConstraintUtils.parseConstraintError("Error: temperature must be 1.0")
-- Returns: { type = "temperature", value = 1.0, reason = "..." }

-- Build retry config with corrected parameters
local new_config = ConstraintUtils.buildRetryConfig(original_config, constraint)
```

**Usage in tests**:
- `test_full_provider.lua` - Uses `getMaxTemperature()` instead of hardcoded map
- `test_model_validation.lua` - Uses `parseConstraintError()` instead of 67-line duplicate
- `test_config.lua` - Uses `getDefaultTemperature()` and `getReasoningDefaults()` for config building

**Benefits**:
- ✅ Tests always reflect actual plugin constraints (single source of truth)
- ✅ Removed 75+ lines of duplicated code
- ✅ No drift between test expectations and plugin behavior
- ✅ Adding new constraints automatically updates all tests

## Prerequisites

Lua 5.3+ with LuaSocket, LuaSec, and dkjson.

### macOS (Homebrew)

```bash
brew install lua luarocks
luarocks install luasocket luasec dkjson

# Verify
lua -e "require('socket'); require('ssl'); require('dkjson'); print('OK')"
```

### Linux (Debian/Ubuntu)

```bash
sudo apt install lua5.3 liblua5.3-dev luarocks
sudo luarocks install luasocket
sudo luarocks install luasec OPENSSL_DIR=/usr
sudo luarocks install dkjson
```

## Setup

1. **Configure API keys** - Test suite uses API keys from two sources (same priority as plugin):

   **Option A: GUI-entered keys** (recommended for regular users)
   - Keys entered via Settings → API Keys in KOReader
   - Automatically used by test suite/web inspector
   - **Highest priority** (overrides apikeys.lua)

   **Option B: File-based keys** (recommended for development)
   ```bash
   # Navigate to plugin directory (see paths in "KOReader Plugin Paths" above)
   cp apikeys.lua.sample apikeys.lua
   # Edit apikeys.lua and add your API keys
   ```

   Both sources are merged, with GUI keys taking priority over file keys.

   **Multiple keys per provider**: when an apikeys.lua entry is a list (see the
   sample file), the test tooling uses the FIRST entry by default — same rule as
   the plugin. To run the suite or `model_audit.lua` against a specific key, set
   `KOA_KEY_ALIAS_<PROVIDER>` to that entry's alias:
   ```bash
   KOA_KEY_ALIAS_GEMINI=paid lua tests/model_audit.lua --probe gemini gemini-3.7-flash
   ```

2. **Run from the plugin directory** (see [KOReader Plugin Paths](#koreader-plugin-paths-by-platform) above):

   ```bash
   # macOS example:
   cd ~/Library/Application\ Support/koreader/plugins/koassistant.koplugin
   lua tests/run_tests.lua

   # Linux example:
   cd ~/.config/koreader/plugins/koassistant.koplugin
   lua tests/run_tests.lua
   ```

## Testing with Real User Settings

You can test with your actual KOAssistant settings by using the backup/restore feature to export settings from your main device (e.g., e-reader) and import them into a KOReader installation where you run the test suite.

**How to do it:**

1. **On your main device**: Settings → Advanced → Settings Management → Create Backup
   - Choose what to include (recommend: Settings, API Keys, User Content)
   - Exclude Chat History to keep backup small
   - The backup will be saved to `/koassistant_backups/` folder

2. **Copy the backup** (`.koa` file) from `/koassistant_backups/` to your test environment

3. **On test device**: Settings → Advanced → Settings Management → Restore from Backup
   - Select the backup file
   - Choose what to restore (Settings, API Keys, etc.)
   - Click "Restore Now"

4. **Restart KOReader** after restore for changes to take full effect

**This is useful for:**
- Testing provider connectivity with your API keys
- Testing custom domains/behaviors in the web inspector
- Testing with your preferred settings configuration (languages, temperature, etc.)
- Sharing settings between multiple KOReader installations

**Example workflow:**
```bash
# On your e-reader: Create backup via Settings UI
# Copy backup to test machine
scp /mnt/onboard/.adds/koreader/koassistant_backups/koassistant_backup_*.koa \
    ~/test-env/koassistant_backups/

# On test machine: Restore via Settings UI or run tests
cd /path/to/koassistant.koplugin
lua tests/run_tests.lua
lua tests/inspect.lua --web  # Will use your restored API keys
```

## Local Configuration

Create `tests/local_config.lua` for custom settings:

```bash
cp tests/local_config.lua.sample tests/local_config.lua
```

Supports: `plugin_dir`, `apikeys_path`, `default_provider`, `verbose`, `skip_providers`

## Providers (30 ids)

The 29 built-in providers plus `openai_codex` (OpenAI Subscription: a keyless access path, but
its own provider id in code). `ModelLists.getAllProviders()` is the live list, and the inspector's
`--list` prints it. User-defined OpenAI-compatible providers get runtime ids of the form
`custom_<slug>` and are not listed here.

| Provider | Description |
|----------|-------------|
| anthropic | Claude models (extended thinking support) |
| openai | GPT models |
| openai_codex | OpenAI Subscription: GPT models via a ChatGPT plan (device login, no API key) |
| deepseek | DeepSeek models (reasoning_content) |
| gemini | Google Gemini |
| ollama | Local models (NDJSON streaming) |
| groq | Fast inference |
| mistral | Mistral AI |
| xai | Grok models |
| openrouter | Meta-provider (500+ models) |
| requesty | OpenAI-compatible model router |
| qwen | Alibaba Qwen |
| kimi | Moonshot |
| together | Together AI |
| fireworks | Fireworks AI |
| sambanova | SambaNova |
| cohere | Command models (v2 API) |
| doubao | ByteDance |
| zai | Z.AI GLM models |
| perplexity | Sonar models (built-in web search) |
| nvidia | Nemotron family + hosted open models (no web search) |
| cerebras | Very fast open-model inference |
| minimax | MiniMax M-series |
| deepinfra | Many open models |
| novita | Open-model marketplace |
| hyperbolic | Open-model host |
| nebius | Nebius AI Studio |
| chutes | Decentralized GPU marketplace |
| featherless | Huge open-model catalog |
| vercel | Vercel AI Gateway |

## Files

```
tests/
├── run_tests.lua              # Test runner
├── inspect.lua                # Request inspector (CLI + Web UI)
├── model_audit.lua            # Model discovery diff + capability probe battery
├── test_config.lua            # Config helpers (buildFullConfig, KOA_KEY_ALIAS_* key selection)
├── local_config.lua.sample    # Local config template
├── fixtures/
│   ├── sample_context.lua     # Sample context data for tests
│   └── mock_series/           # Offline mock-book generator (X-Ray/groups device fixture):
│                              #   lua tests/fixtures/mock_series/gen.lua --out <dir> [--base <target>]
│                              # 7 tiny invented EPUBs + real-API sidecar data (see gen.lua header)
├── lib/
│   ├── mock_koreader.lua      # KOReader module mocks
│   ├── test_runner.lua        # Assertion/reporting harness every unit file uses
│   ├── test_helpers.lua       # Integration-test helpers (sync HTTP instead of KOReader subprocesses)
│   ├── constraint_utils.lua   # Plugin constraint utilities wrapper
│   ├── request_inspector.lua  # Core inspection logic
│   ├── terminal_formatter.lua # ANSI colors, formatting
│   └── web_server.lua         # LuaSocket HTTP server
├── tools/
│   ├── tpm_stub_server.py     # Local provider stub playing a per-minute token allowance (no credentials)
│   └── tpm_e2e.lua            # End-to-end transport check against that stub (KOReader's bundled LuaJIT)
├── web/
│   └── index.html             # Web UI frontend
├── integration/
│   ├── test_full_provider.lua    # Comprehensive tests (--full)
│   ├── test_model_validation.lua # Model validation (--models)
│   └── test_reasoning.lua        # Reasoning integration tests (--reasoning)
└── unit/                      # 96 files - see "Unit Tests" above for the per-file list
```

## Troubleshooting

### Module not found errors

```bash
luarocks install luasocket
luarocks install luasec        # macOS
sudo luarocks install luasec OPENSSL_DIR=/usr  # Linux
luarocks install dkjson
```

### Live tests all FAIL with "mocked - no network" (models show `? FAIL`)

The rocks are installed but not on Lua's module path, so `require("socket")`/`require("ssl.https")`
fail and `mock_koreader` falls back to a no-network stub (every model "fails" without a real call).
Fix by exporting the LuaRocks paths for your Lua version before running — **no reinstall needed**:

```bash
eval "$(luarocks --lua-version 5.5 path)"   # match your `lua -v`; also 5.4/5.3
lua tests/run_tests.lua --models
```

Add that `eval` to your shell profile to make it permanent. Verify with
`lua -e "print(pcall(require,'ssl.https'))"` — it should print `true`.

> **Lua 5.5 note:** 5.5 makes `for`-loop control variables `const`. Test tooling that reassigns a
> loop variable errors at runtime (fixed in `terminal_formatter.lua`; if you hit another, copy the
> loop var into a `local` first). The plugin runtime (LuaJIT 5.1) is unaffected.

### Web UI won't start

Check if port is in use:
```bash
lsof -i :8080
# Use different port
lua tests/inspect.lua --web --port 3000
```

### Tests hang

Some providers may be slow. Tests wait for API response without timeout. Check network connectivity if a provider consistently hangs.

## Notes

- **API Keys**: Test suite merges keys from both GUI settings and apikeys.lua (GUI keys take priority). Providers without keys are skipped (not failed)
- **Ollama**: Requires running Ollama instance locally
- **Streaming**: Not fully testable standalone (requires KOReader subprocess)
- **Token Limits**: Tests use small limits (64-512 tokens) to minimize costs
- **Model Validation Cost**: `--models` uses ~10 input + 1 output tokens per model (~2,000 tokens total for all 179 curated models, typically < $0.01)

## Per-minute admission limits (no credentials needed)

`tests/unit/test_rate_limits.lua` covers the pure logic (headers, pipe marker, session
memo, refusal parsing, budget sizing) and `tests/unit/test_non200_errors.lua` the error
text and dialog class. For an end-to-end run without any provider key:

```bash
python3 tests/tools/tpm_stub_server.py            # Groq-shaped plan: 8000 tokens/min, headers on
python3 tests/tools/tpm_stub_server.py 8765 8000 --no-headers   # learn from the refusal text only
python3 tests/tools/tpm_stub_server.py 1234 32768 --openrouter  # context-window wording (HTTP 400, no headers)
```

Automated transport check (real base.lua fetch paths under KOReader's bundled LuaJIT,
no UI): with the stub running,

```bash
(cd /Applications/KOReader.app/Contents/koreader && ./luajit \
    "$PWD_PLUGIN/tests/tools/tpm_e2e.lua" "$PWD_PLUGIN")   # PWD_PLUGIN = the plugin dir
```

expects "TPM e2e: all checks passed" (headers as fetchInSubprocess's 3rd return, the pipe
marker on a 413 and on a 200 SSE stream, parent-side sizing, the capped request admitted).
On macOS this exercises the http.request path (the one devices use); the macOS raw-SSL
path is covered by any real https request on the desktop build.

Desktop KOReader: Settings > Provider > Add custom provider, base URL
`http://127.0.0.1:8765/v1/chat/completions`, no API key, any model id. Then:

1. Send any chat. Stub log: first request `REFUSE` (max_tokens 32768), second `ok`
   with a budget near 7,500. Plugin log (Console Debug on): "per-minute allowance 8000
   refused budget 32768 - resending at N".
2. Send another chat. Stub log: `ok` on the FIRST try; plugin log: "answer budget capped
   to N by the plan's per-minute allowance 8000".
3. Run "Test provider" on a fresh session, then send a chat: no refusal at all (the
   probe learned the plan). Plugin log: "test probe learned per-minute allowance 8000".
4. Paste ~40K characters into a chat: one refusal, no resend, and the error dialog says
   the request itself is larger than the allowance (scope advice), staying on screen.
5. OpenRouter shape: restart the stub as `python3 tests/tools/tpm_stub_server.py 1234 32768
   --openrouter` (LIMIT = the model's context window, HTTP 400, no headers) and send a
   chat. Expect one refusal then ok (plugin log: "max_tokens self-heal (context), retrying
   at N"), and the NEXT chat admitted first try ("answer budget capped ... allowance 32768").
