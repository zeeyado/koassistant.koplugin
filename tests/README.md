# KOAssistant Test Suite

Standalone test framework for testing KOAssistant without running KOReader's GUI.

## Quick Start

```bash
cd /path/to/koassistant.koplugin

# Run unit tests (fast, no API calls)
lua tests/run_tests.lua --unit

# Run provider connectivity tests
lua tests/run_tests.lua

# Validate all models (detects constraints, ~1 token per model)
lua tests/run_tests.lua --models

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
- Provider/model selection with all 16 providers
- Behavior toggles, temperature slider
- **Domain loading** from your actual `domains/` folder
- **Action loading** from `prompts/actions.lua` + custom actions from settings
- **Ask action** available in all contexts (like plugin)
- **Settings sync** from your `koassistant_settings.lua` (languages, behavior, temperature)
- **Context simulation** (highlight text, book title/author, multi-book)
- Language settings with translation target dropdown
- Extended thinking configuration
- Syntax-highlighted JSON output
- **Chat tab** with conversation view (matches plugin - no system shown)
- **Multi-turn chat** with reply input (Enter key or Reply button)
- **Response tab** shows raw API response, metadata (status, timing) shown separately
- **Auto-scroll** chat to bottom on new messages
- Dark mode support

## Test Categories

### Unit Tests (no API calls)

Located in `tests/unit/`:
- `test_system_prompts.lua` - Behavior variants, language parsing, domain, skip_language_instruction
- `test_streaming_parser.lua` - SSE/NDJSON content extraction for all providers
- `test_response_parser.lua` - Response parsing for all 16 providers
- `test_loaders.lua` - BehaviorLoader and DomainLoader functionality

### Integration Tests (real API calls)

| Mode | Description |
|------|-------------|
| Default | Basic connectivity (API responds, returns string) |
| `--full` | Behaviors, temperatures, domains, languages, extended thinking |
| `--models` | Validate ALL models (~1 token each), detect parameter constraints |

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
-- Returns: { budget = 4096, budget_min = 1024, budget_max = 32000, ... }

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

1. **Configure API keys** in `apikeys.lua`:

   ```bash
   cd /path/to/koassistant.koplugin
   cp apikeys.lua.sample apikeys.lua
   # Edit apikeys.lua and add your API keys
   ```

2. **Run from the plugin directory**:

   ```bash
   cd /path/to/koassistant.koplugin
   lua tests/run_tests.lua
   ```

## Local Configuration

Create `tests/local_config.lua` for custom settings:

```bash
cp tests/local_config.lua.sample tests/local_config.lua
```

Supports: `plugin_dir`, `apikeys_path`, `default_provider`, `verbose`, `skip_providers`

## Providers (16 total)

| Provider | Description |
|----------|-------------|
| anthropic | Claude models (extended thinking support) |
| openai | GPT models |
| deepseek | DeepSeek models (reasoning_content) |
| gemini | Google Gemini |
| ollama | Local models (NDJSON streaming) |
| groq | Fast inference |
| mistral | Mistral AI |
| xai | Grok models |
| openrouter | Meta-provider (500+ models) |
| qwen | Alibaba Qwen |
| kimi | Moonshot |
| together | Together AI |
| fireworks | Fireworks AI |
| sambanova | SambaNova |
| cohere | Command models (v2 API) |
| doubao | ByteDance |

## Files

```
tests/
├── run_tests.lua              # Test runner
├── inspect.lua                # Request inspector (CLI + Web UI)
├── test_config.lua            # Config helpers (buildFullConfig)
├── local_config.lua.sample    # Local config template
├── lib/
│   ├── mock_koreader.lua      # KOReader module mocks
│   ├── constraint_utils.lua   # Plugin constraint utilities wrapper
│   ├── request_inspector.lua  # Core inspection logic
│   ├── terminal_formatter.lua # ANSI colors, formatting
│   └── web_server.lua         # LuaSocket HTTP server
├── web/
│   └── index.html             # Web UI frontend
├── integration/
│   ├── test_full_provider.lua    # Comprehensive tests (--full)
│   └── test_model_validation.lua # Model validation (--models)
└── unit/
    ├── test_constants.lua        # Context constants, GitHub URLs tests
    ├── test_constraint_utils.lua # Constraint utilities tests
    ├── test_system_prompts.lua   # Behavior, language, domain tests
    ├── test_streaming_parser.lua # SSE/NDJSON parsing tests
    ├── test_response_parser.lua  # Provider response parsing tests
    └── test_loaders.lua          # BehaviorLoader, DomainLoader tests
```

## Troubleshooting

### Module not found errors

```bash
luarocks install luasocket
luarocks install luasec        # macOS
sudo luarocks install luasec OPENSSL_DIR=/usr  # Linux
luarocks install dkjson
```

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

- **API Keys**: Providers without keys are skipped (not failed)
- **Ollama**: Requires running Ollama instance locally
- **Streaming**: Not fully testable standalone (requires KOReader subprocess)
- **Token Limits**: Tests use small limits (64-512 tokens) to minimize costs
- **Model Validation Cost**: `--models` uses ~10 input + 1 output tokens per model (~1,400 tokens total for all 130+ models, typically < $0.01)
