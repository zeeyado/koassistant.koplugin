# KOAssistant Test Suite

Standalone test framework for testing all 16 AI providers without running KOReader's GUI.

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
   cd "/Users/zzz/Library/Application Support/koreader/plugins/koassistant.koplugin"
   lua tests/run_tests.lua
   ```

## Usage

### Test All Providers

```bash
lua tests/run_tests.lua
```

### Test a Single Provider

```bash
lua tests/run_tests.lua anthropic
lua tests/run_tests.lua openai
lua tests/run_tests.lua groq
```

### Verbose Mode (Show Responses)

```bash
lua tests/run_tests.lua --verbose
lua tests/run_tests.lua -v openai
```

### Help

```bash
lua tests/run_tests.lua --help
```

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
├── run_tests.lua      # Main test runner
├── test_config.lua    # Configuration helpers
├── lib/
│   └── mock_koreader.lua  # KOReader module mocks
├── features/          # Feature-specific tests (future)
└── README.md          # This file
```
