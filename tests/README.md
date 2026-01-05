# KOAssistant Test Suite

Standalone test framework for testing KOAssistant without running KOReader's GUI.

## Quick Start

```bash
cd /path/to/koassistant.koplugin

# Run unit tests (fast, no API calls)
lua tests/run_tests.lua --unit

# Run provider connectivity tests
lua tests/run_tests.lua

# Inspect request structure
lua tests/inspect.lua anthropic

# Start web UI for interactive testing
lua tests/inspect.lua --web
```

## Tools

### Test Runner (`run_tests.lua`)

Runs automated tests against providers.

```bash
# Unit tests only (107 tests, no API calls)
lua tests/run_tests.lua --unit

# Basic connectivity for all providers
lua tests/run_tests.lua

# Single provider
lua tests/run_tests.lua anthropic

# Comprehensive tests (behaviors, temps, domains)
lua tests/run_tests.lua anthropic --full

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
- Provider/model selection with all 16 providers
- Behavior toggles, temperature slider
- **Domain loading** from your actual `domains/` folder
- **Action loading** from `prompts/actions.lua` with template resolution
- **Context simulation** (highlight text, book title/author)
- Language settings and extended thinking configuration
- Syntax-highlighted JSON output
- Dark mode support

## Test Categories

### Unit Tests (107 tests, no API calls)

Located in `tests/unit/`:
- `test_system_prompts.lua` - 46 tests: behavior variants, language parsing, domain
- `test_streaming_parser.lua` - 22 tests: SSE/NDJSON content extraction
- `test_response_parser.lua` - 39 tests: response parsing for all 16 providers

### Integration Tests (real API calls)

| Mode | Description |
|------|-------------|
| Default | Basic connectivity (API responds, returns string) |
| `--full` | Behaviors, temperatures, domains, languages, extended thinking |

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
│   ├── request_inspector.lua  # Core inspection logic
│   ├── terminal_formatter.lua # ANSI colors, formatting
│   └── web_server.lua         # LuaSocket HTTP server
├── web/
│   └── index.html             # Web UI frontend
└── unit/
    ├── test_system_prompts.lua
    ├── test_streaming_parser.lua
    └── test_response_parser.lua
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
