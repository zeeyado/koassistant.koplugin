# KOAssistant Test Suite

Standalone test framework for testing KOAssistant without running KOReader's GUI.

## Test Categories

### Unit Tests (Fast, Free, No API Calls)
Located in `tests/unit/`. These test core logic without making API calls:
- `test_system_prompts.lua` - Behavior variants, language parsing, domain integration
- `test_streaming_parser.lua` - SSE/NDJSON content extraction
- `test_response_parser.lua` - Response parsing for all 16 providers

### Integration Tests (Real API Calls)
The default test mode. Tests all 16 AI providers with real API calls.

## Prerequisites

You need Lua 5.3+ with LuaSocket and LuaSec installed.

### macOS (Homebrew)

```bash
# Install Lua
brew install lua luarocks

# Install required packages
luarocks install luasocket
luarocks install luasec
luarocks install dkjson

# Verify installation
lua -v
lua -e "require('socket'); print('LuaSocket OK')"
lua -e "require('ssl'); print('LuaSec OK')"
lua -e "require('dkjson'); print('dkjson OK')"
```

### Linux (Debian/Ubuntu)

```bash
# Install Lua and LuaRocks
sudo apt install lua5.3 liblua5.3-dev luarocks

# Install packages
sudo luarocks install luasocket
sudo luarocks install luasec OPENSSL_DIR=/usr
sudo luarocks install dkjson
```

## Setup

1. **Ensure you have API keys configured** in `apikeys.lua`:

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

## Usage

### Run Unit Tests (Fast, No API Calls)

```bash
lua tests/run_tests.lua --unit
```

### Run All Tests (Unit + Integration)

```bash
lua tests/run_tests.lua --all
```

### Run Integration Tests Only (Default)

```bash
lua tests/run_tests.lua
```

### Test a Single Provider

```bash
lua tests/run_tests.lua anthropic
lua tests/run_tests.lua openai
lua tests/run_tests.lua groq
```

### Comprehensive Provider Tests (--full)

Run comprehensive tests that check behaviors, temperatures, domains, and language instructions:

```bash
# Test a single provider comprehensively
lua tests/run_tests.lua groq --full
lua tests/run_tests.lua anthropic --full -v

# Test all providers comprehensively (takes longer)
lua tests/run_tests.lua --full
```

The `--full` flag runs these tests for each provider:
- Basic connectivity
- Minimal behavior variant
- Full behavior variant
- Temperature 0.0 (deterministic)
- Temperature max (1.0 for Anthropic, 2.0 for others)
- Domain context (checks if response reflects domain)
- Language instruction (checks if response is in correct language)
- Extended thinking (Anthropic only)

### Verbose Mode (Show Responses)

```bash
lua tests/run_tests.lua --verbose
lua tests/run_tests.lua -v openai
```

### Help

```bash
lua tests/run_tests.lua --help
```

## Local Configuration

Create a local configuration file to customize paths and settings:

```bash
cp tests/local_config.lua.sample tests/local_config.lua
# Edit tests/local_config.lua with your settings
```

The local config file is gitignored and supports:
- `plugin_dir` - Override plugin directory path
- `apikeys_path` - Override API keys file location
- `default_provider` - Default provider for quick tests
- `verbose` - Always run in verbose mode
- `skip_providers` - Skip specific providers even if API key exists

## Expected Output

```
======================================================================
  KOAssistant Provider Tests
======================================================================

  anthropic    ✓ PASS  (1.23s)
  openai       ✓ PASS  (890ms)
  deepseek     ✓ PASS  (1.45s)
  gemini       ✓ PASS  (670ms)
  ollama       ⊘ SKIP  (no API key)
  groq         ✓ PASS  (340ms)
  mistral      ✓ PASS  (910ms)
  xai          ⊘ SKIP  (no API key)
  openrouter   ✓ PASS  (780ms)
  qwen         ✗ FAIL
               Error: Invalid API key format
  kimi         ⊘ SKIP  (no API key)
  together     ✓ PASS  (560ms)
  fireworks    ✓ PASS  (450ms)
  sambanova    ✓ PASS  (380ms)
  cohere       ✓ PASS  (920ms)
  doubao       ⊘ SKIP  (no API key)

----------------------------------------------------------------------
  Results: 11 passed, 1 failed, 4 skipped

```

## Providers

| Provider | Description |
|----------|-------------|
| anthropic | Claude models |
| openai | GPT models |
| deepseek | DeepSeek models |
| gemini | Google Gemini |
| ollama | Local models (requires running Ollama) |
| groq | Fast inference |
| mistral | Mistral AI |
| xai | Grok models |
| openrouter | Meta-provider (500+ models) |
| qwen | Alibaba Qwen |
| kimi | Moonshot |
| together | Together AI |
| fireworks | Fireworks AI |
| sambanova | SambaNova |
| cohere | Command models |
| doubao | ByteDance |

## Notes

- **API Keys**: Providers without valid API keys are skipped (not failed)
- **Ollama**: Requires a running Ollama instance locally
- **Streaming**: Not tested (requires KOReader's subprocess system)
- **Token Limits**: Tests use small token limits (64-256) to minimize costs

## Troubleshooting

### "module 'socket' not found"

Install LuaSocket:
```bash
luarocks install luasocket
```

### "module 'ssl' not found"

Install LuaSec:
```bash
# macOS
luarocks install luasec

# Linux (may need OpenSSL path)
sudo luarocks install luasec OPENSSL_DIR=/usr
```

### "module 'dkjson' not found"

Install dkjson:
```bash
luarocks install dkjson
```

### Tests hang or timeout

Some providers may be slow. The tests don't have a timeout - they wait for the API response. If a provider consistently hangs, there may be a network or API issue.

## Files

```
tests/
├── run_tests.lua              # Main test runner (--unit, --all, --full flags)
├── test_config.lua            # Configuration helpers (buildConfig, buildFullConfig)
├── local_config.lua.sample    # Sample local config (copy to local_config.lua)
├── local_config.lua           # User's local config (gitignored)
├── lib/
│   └── mock_koreader.lua      # KOReader module mocks
├── unit/                      # Unit tests (no API calls)
│   ├── test_system_prompts.lua    # 46 tests - behavior, language, domain
│   ├── test_streaming_parser.lua  # 22 tests - SSE/NDJSON parsing
│   └── test_response_parser.lua   # 39 tests - 16 provider responses
├── integration/               # Integration tests (real API calls)
│   └── test_full_provider.lua     # Comprehensive provider tests (--full flag)
└── README.md                  # This file
```
