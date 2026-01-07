# KOAssistant

[![GitHub Release](https://img.shields.io/github/v/release/zeeyado/koassistant.koplugin)](https://github.com/zeeyado/koassistant.koplugin/releases/latest)
[![License: GPL-3.0](https://img.shields.io/github/license/zeeyado/koassistant.koplugin)](LICENSE)
[![Translation Status](https://hosted.weblate.org/widgets/koassistant/-/svg-badge.svg)](https://hosted.weblate.org/engage/koassistant/)

**Powerful AI assistant integrated into KOReader.**

A highly flexible and customizable research assistant and knowledge expander.

You can have context free chats, chat about documents in your library, or about text highlighted in a document, with or without additional context. You can translate text, get text explained/analyzed, compare books/articles, and much more by creating advanced and elaborate custom actions, additional contexts, and instructions, all with their own highly granular settings. 

Chats are streamed live (like ChatGPT/Claude, etc), are automatically (or manually) saved, and you can resume them any time, and continue chats with a different provider/model and other changed settings if you like. You can one-click export/copy whole chats to clipboard (markdown formatting), or select and copy text from chats, to then paste e.g. in a highlight note in your document. Your chat reply drafts are saved so you can re-read AI messages and resume typing, or copy and paste parts as you are structuring your reply.

Most settings are configurable in the UI, including: Provider/model, AI behavior and style, user-to-AI interaction languages, translation languages, domains/project/field context, custom actions (which you can create, edit, duplicate, and adjust settings for), and advanced model settings like reasoning/thinking, temperature, and more. Most settings, additional context, and function combinations can be specified for a given action.

> **Development Status**: KOAssistant is currently under heavy development, with features constantly added. 16 providers are supported (see [Supported Providers](#supported-providers)); testing and Feedback appreciated. You can open an issue, feature request, or start a discussion.

---

## Table of Contents

- [Quick Setup](#quick-setup)
- [Recommended Setup](#recommended-setup)
- [How to Use KOAssistant](#how-to-use-koassistant)
  - [Highlight Mode](#highlight-mode)
  - [Book/Document Mode](#bookdocument-mode)
  - [Multi-Document Mode](#multi-document-mode)
  - [General Chat](#general-chat)
- [Managing Conversations](#managing-conversations)
- [Knowledge Domains](#knowledge-domains)
- [Tags](#tags)
- [Custom Actions](#custom-actions)
- [Settings Reference](#settings-reference)
- [Advanced Configuration](#advanced-configuration)
- [Technical Features](#technical-features)
- [Supported Providers](#supported-providers)
- [Troubleshooting](#troubleshooting)
- [Contributing](#contributing)
- [Translations](#contributing-translations)
- [Credits](#credits)

---

## Quick Setup

**Get started in 3 steps:**

### 1. Install the Plugin

Download koassistant.koplugin.zip from latest [Release](https://github.com/zeeyado/koassistant.koplugin/releases) -> Assets or clone:
```bash
git clone https://github.com/zeeyado/koassistant.koplugin
```

Copy to your KOReader plugins directory:
```
Kobo/Kindle:  /mnt/onboard/.adds/koreader/plugins/koassistant.koplugin/
Android:      /sdcard/koreader/plugins/koassistant.koplugin/
macOS:        ~/Library/Application Support/koreader/plugins/koassistant.koplugin/
Linux:        ~/.config/koreader/plugins/koassistant.koplugin/
```

### 2. Add Your API Key

Make a copy of apikeys.lua.sample and name it apikeys.lua

```bash
cp apikeys.lua.sample apikeys.lua
```

Edit `apikeys.lua` and add your API key(s):
```lua
return {
    anthropic = "your-key-here",  -- console.anthropic.com
    openai = "",                  -- platform.openai.com
    -- See apikeys.lua.sample for all 16 providers
}
```

See [Supported Providers](#supported-providers) for full list with links to get API keys.

### 3. Restart KOReader

Find KOAssistant Settings in: **Tools → Page 2 → KOAssistant**

---

## Recommended Setup

### Configure Quick Access Gestures

For easy access, assign KOAssistant actions to a gesture:

1. Go to **Settings → Gesture Manager → Tap corner → Bottom left** (or your preferred gesture)
2. Select **General** 
3. Add KOAssistant actions:
   - Chat History
   - Continue Last Chat
   - General Chat
   - Chat About Book
   - Settings
   - ...
4. Enable **"Show as QuickMenu"**

> **Tip**: Set up gestures in both **Reader View** (while reading) and **File Browser** separately.

### Tips for Better Results

- **Good document metadata** improves AI responses. Use Calibre, Zotero, or similar tools to ensure titles, authors, and identifiers are correct.
- **Shorter tap duration** makes text selection in KOReader easier: Settings → Taps and Gestures → Long-press interval
- **Choose models wisely**: Fast models (like Haiku) for quick queries; powerful models (like Sonnet, Opus) for deeper analysis. Choose an appropriate model for a given task (you can set specific models for you custom actions)
- **Discover advanced functionality and adjust settings**: Dig into the deeper functionality available in KOAssistant, like custom knowledge domains and custom actions, temperature, extended thinking, and AI behavior settings, to enhance the plugin and tailor it to your usage.

---

## How to Use KOAssistant

KOAssistant works in **4 contexts**, each with its own set of actions, and you can create custom actions for each and all contexts, and enable/disable the built in ones:

### Highlight Mode

**Access**: Highlight text in a document → tap "KOAssistant"

**Quick Actions**: You can add frequently-used actions directly to KOReader's highlight popup menu for faster access. Instead of going through the KOAssistant dialog, actions like "KOA: Explain" or "KOA: Translate" appear as separate buttons. See [Highlight Menu Actions](#highlight-menu-actions) below.

**Built-in Actions**:
| Action | Description |
|--------|-------------|
| **Ask** | Free-form question about the text |
| **Explain** | Detailed explanation of the passage |
| **ELI5** | Explain Like I'm 5 - simplified explanation |
| **Summarize** | Concise summary of the text |
| **Translate** | Translate to your configured language |

**What the AI sees**: Your highlighted text, plus Document metadata (title, author, identifiers from file properties)

### Book/document Mode 

**Access**: Long-press a book in File Browser → "KOAssistant" or select gesture action "Chat about book/document" while in a document

**Built-in Actions**:
| Action | Description |
|--------|-------------|
| **Ask** | Free-form question about the book |
| **Book Info** | Overview, significance, and why to read it |
| **Find Similar** | Recommendations for similar books |
| **About Author** | Author biography and writing style |
| **Historical Context** | When written and historical significance |

**What the AI sees**: Document metadata (title, author, identifiers from file properties)

### Multi-Document Mode

**Access**: Select multiple documents in File Browser → tap any → "Compare with KOAssistant"

**Built-in Actions**:
| Action | Description |
|--------|-------------|
| **Compare** | Compare themes, styles, target audiences |
| **Find Common Themes** | Identify shared topics and patterns |
| **Analyze Collection** | What this selection reveals about reader interests |
| **Quick Summaries** | Brief summary of each book |

**What the AI sees**: List of titles, authors, and identifiers 

### General Chat

**Access**: Tools → KOAssistant → New General Chat, or via gesture (easier)

A free-form conversation without specific document context. If started while a book is open, that "launch context" is saved with the chat (so you know where you launched it from) but doesn't affect the conversation, i.e. the AI doesn't see that you launched it from a specific document, and the chat is saved in General chats

---

## Managing Conversations

### Auto-Save

By default, all chats are automatically saved. You can disable this in Settings → Conversations.

- **Auto-save All Chats**: Save every new conversation
- **Auto-save Continued Chats**: Only save when continuing from history

### Chat History

**Access**: Tools → KOAssistant → Chat History

Hamburger Menu:

Browse saved conversations organized by:
- **By Document**: Chats grouped by book (including "General AI Chats")
- **By Domain**: Filter by knowledge domain (hamburger menu → View by Domain)
- **By Tag**: Filter by tags you've added (hamburger menu → View by Tag)

Delete all chats

### Chat Actions

Select any chat to:
- **Continue**: Resume the conversation
- **Rename**: Change the chat title
- **Tags**: Add or remove tags
- **Export**: Copy as Text or Markdown
- **Delete**: Remove the chat

### Export Formats

- **Text**: Plain text format, good for sharing
- **Markdown**: Formatted with headers, includes metadata

---

## Knowledge Domains

Domains provide **background context** to frame AI conversations. When you select a domain, its context text is included with every message. They can function similarly to the Projects-feature that many AI providers have. You can have very small, focused projects/domains, or large, detailed, interdisciplinary ones. It is up to you to tailor this. 

### Creating Domains

Make a `domains/` folder and create files in it:

**Example**: `domains/philosophy.md`
```markdown
# Philosophy

This conversation relates to philosophical inquiry and analysis.
Consider different schools of thought, logical arguments, and ethical implications.
Reference relevant philosophers and their works when appropriate.
```

**File format**:
- Filename becomes the domain ID: `my_domain.md` → ID `my_domain`
- First `# Heading` becomes the display name (or derived from filename)
- Rest of file is the context sent to AI
- Supported: `.md` and `.txt` files

See `domains.sample/` for examples.

### Using Domains

1. In the chat dialog, tap the **Domain** button
2. Select a domain from the list
3. All messages in this chat will include that domain's context

**Note**: Domains are knowledge tags, NOT storage locations. Chats still save to their book or "General AI Chats", but you can browse by domain in the Chat history. Domains have to be added at the beginning of a chat as they provide context for the AI. If you use large and detailed knowledge domains, you will get better results, at a higher request price.

### Browsing by Domain:

Chat History → hamburger menu → **View by Domain**

---

## Tags

Tags are simple labels for organizing chats. Unlike domains:
- No context attached (just labels)
- Can be added/removed anytime
- Multiple tags per chat allowed

### Adding Tags

1. Open Chat History
2. Long-press a chat → **Tags**
3. Add new tags or select existing ones

Currently being expanded to make it easier to create and add tags.

### Browsing by Tag

Chat History → hamburger menu → **View by Tag**

---

## Custom Actions

### Managing Actions in the UI

**Tools → KOAssistant → Manage Actions**

- Toggle built-in and custom actions on/off
- Create new actions with the wizard
- Edit or delete your custom actions (marked with ★)
- Edit settings for built-in actions (temperature, thinking, provider/model, AI behavior)

**Action indicators:**
- **★** = Custom action (editable)
- **⚙** = Built-in action with modified settings

**Editing built-in actions:** Long-press any built-in action → "Edit Settings" to customize its advanced settings without creating a new action. Use "Reset to Default" to restore original settings.

### Action Creation Wizard

1. **Name & Context**: Set button text and where/when it appears
2. **AI Behavior**: Optional behavior override (use global, minimal, full, none, or custom)
3. **Action Prompt**: The actual prompt template sent to the AI
4. **Advanced**: Provider, Model, Temperature, and Reasoning/Thinking overrides

### Template Variables

Insert these in you action prompt if you want the AI to reference them.

| Variable | Context | Description |
|----------|---------|-------------|
| `{highlighted_text}` | Highlight | The selected text |
| `{title}` | Book, Highlight | Book title |
| `{author}` | Book, Highlight | Book author |
| `{author_clause}` | Book, Highlight | " by Author" or empty |
| `{count}` | Multi-book | Number of books |
| `{books_list}` | Multi-book | Formatted list of books |
| `{translation_language}` | Any | Target language from settings |

### File-Based Custom Actions

For more control, create `custom_actions.lua`:

```lua
return {
    {
        text = "Grammar Check",
        context = "highlight",
        behavior_override = "You are a grammar expert. Be precise and analytical.",
        prompt = "Check grammar: {highlighted_text}"
    },
    {
        text = "Discussion Questions",
        context = "book",
        prompt = "Generate 5 discussion questions for '{title}'{author_clause}."
    },
    {
        text = "Series Order",
        context = "multi_book",
        prompt = "What's the reading order for these books?\n\n{books_list}"
    },
}
```

**Optional fields**:
- `behavior_variant`: Use a preset behavior ("minimal", "full", "none")
- `behavior_override`: Custom behavior text (overrides variant)
- `provider`: Force specific provider ("anthropic", "openai", etc.)
- `model`: Force specific model for the provider
- `temperature`: Override global temperature (0.0-2.0)
- `reasoning_config`: Per-provider reasoning settings (see below)
- `extended_thinking`: Legacy: "off" to disable, "on" to enable (Anthropic only)
- `thinking_budget`: Legacy: Token budget when extended_thinking="on" (1024-32000)
- `enabled`: Set to `false` to hide
- `include_book_context`: Add book info to highlight actions
- `domain`: Lock to a specific domain

**Per-provider reasoning config** (new in v0.6):
```lua
reasoning_config = {
    anthropic = { budget = 4096 },      -- Extended thinking budget
    openai = { effort = "medium" },     -- low/medium/high
    gemini = { level = "high" },        -- low/medium/high
}
-- Or: reasoning_config = "off" to disable for all providers
```

See `custom_actions.lua.sample` for more examples.

---

## Settings Reference

**Tools → KOAssistant → Settings**

### Quick Actions
- **Chat about Book**: Start a conversation about the current book (only visible when reading)
- **New General Chat**: Start a context-free conversation
- **Chat History**: Browse saved conversations

### Provider & Model
- **Provider**: Select AI provider (16 options - see [Supported Providers](#supported-providers))
- **Model**: Select model for the chosen provider

### Display Settings
- **Render Markdown**: Format responses with styling (bold, lists, etc.)
- **Hide Highlighted Text**: Don't show selection in responses
- **Hide Long Highlights**: Collapse highlights over character threshold
- **Long Highlight Threshold**: Character limit before collapsing (default: 280)

### Chat Settings
- **Auto-save All Chats**: Automatically save every new conversation
- **Auto-save Continued Chats**: Only save when continuing from history
- **Enable Streaming**: Show responses as they generate in real-time
- **Auto-scroll Streaming**: Follow new text during streaming
- **Large Stream Dialog**: Use full-screen streaming window

### Advanced
- **AI Behavior**: Minimal (~100 tokens), Full (~500 tokens), or Custom guidelines
- **Edit Custom Behavior**: Define your own AI behavior instructions (when Custom is selected)
- **Temperature**: Response creativity (0.0-2.0, Anthropic max 1.0)
- **Reasoning/Thinking**: Per-provider reasoning settings:
  - **Anthropic Extended Thinking**: Budget 1024-32000 tokens
  - **OpenAI Reasoning**: Effort level (low/medium/high)
  - **Gemini Thinking**: Level (low/medium/high)
- **Console Debug**: Enable terminal/console debug logging
- **Show Debug in Chat**: Display debug info in chat viewer
- **Debug Detail Level**: Verbosity (Minimal/Names/Full)
- **Test Connection**: Verify API credentials work

### Language
- **Match KOReader UI Language**: When enabled (default), the plugin UI follows KOReader's language setting. Disable to always show English UI (useful if translations are incomplete or inaccurate). Requires restart.
- **Your Languages**: Languages you speak, separated by commas (e.g., "German, English, French"). Leave empty for default AI behavior.
- **Primary Language**: Pick which language AI should respond in by default. Defaults to first in your list, but can be overridden.
- **Translate to Primary Language**: Use your primary language as the translation target.
- **Translation Target**: Pick from your languages or enter a custom target (when above is disabled).

**How language responses work** (when Your Languages is configured):
- AI responds in your primary language by default
- If you type in another language from your list, AI switches to that language
- Leave empty to let AI use its default behavior

**Examples:**
- `"English"` - AI always responds in English
- `"German, English, French"` with Primary set to "English" - English by default, switches if you type in German or French

### Actions & Domains
- **Manage Actions**: Enable/disable built-in actions, create custom actions
- **Highlight Menu Actions**: View and reorder actions added to the highlight popup menu
- **View Domains**: See available knowledge domains

### Highlight Menu Actions

Add frequently-used highlight actions directly to KOReader's highlight popup for faster access:

1. Go to **Manage Actions**
2. Tap on a highlight-context action (Explain, Translate, etc.)
3. Tap **"Add to Highlight Menu"**
4. **Restart KOReader** for changes to take effect

Actions appear as "KOA: Explain", "KOA: Translate", etc. in the highlight popup.

**Managing quick actions**:
- Use **Highlight Menu Actions** to view all enabled quick actions
- Tap an action to move it up/down or remove it
- Actions requiring user input (like "Ask") cannot be added

**Note**: Changes require an app restart since the highlight menu is built at startup.

### About
- **About KOAssistant**: Plugin info and gesture tips
- **Check for Updates**: Manual update check

---

## Advanced Configuration

### configuration.lua

For advanced overrides, copy `configuration.lua.sample` to `configuration.lua`:

```lua
return {
    -- Force a specific provider/model
    provider = "anthropic",
    model = "claude-sonnet-4-20250514",

    -- Provider-specific settings
    provider_settings = {
        anthropic = {
            base_url = "https://api.anthropic.com/v1/messages",
            additional_parameters = {
                max_tokens = 4096
            }
        },
        ollama = {
            model = "llama3",
            base_url = "http://192.168.1.100:11434/api/chat",
        }
    },

    -- Feature overrides
    features = {
        enable_streaming = true,
        ai_behavior_variant = "full",
        enable_extended_thinking = true,
        thinking_budget_tokens = 10000,
    },
}
```

---

## Technical Features

### Streaming Responses

When enabled, responses appear in real-time as the AI generates them.

- **Auto-scroll**: Follows new text as it appears
- **Pause button**: Tap to stop auto-scrolling and read
- **Resume button**: Jump back to bottom and continue following

Works with all providers that support streaming.

### Prompt Caching (Anthropic)

Reduces API costs by ~90% for repeated context, especially useful for large domains with many tokens:

- **What's cached**: AI behavior instructions + domain context
- **Cache duration**: 5 minutes (Anthropic's policy)
- **Automatically enabled**: No configuration needed

When you have the same domain selected across multiple questions, subsequent queries use cached system instructions.

### Reasoning/Thinking

For complex questions, supported models can "think" through the problem before responding:

**Anthropic Extended Thinking:**
1. Enable in Settings → AI Response → Anthropic Extended Thinking
2. Set token budget (1024-32000)
3. Temperature is forced to 1.0 (API requirement)
4. Works with: Claude Sonnet 4.5, Opus 4.x, Haiku 4.5, Sonnet 3.7

**OpenAI Reasoning:**
1. Enable in Settings → AI Response → OpenAI Reasoning
2. Set effort level (low/medium/high)
3. Temperature is forced to 1.0 (API requirement)
4. Works with: o3, o3-mini, o4-mini, GPT-5.x

**Gemini Thinking:**
1. Enable in Settings → AI Response → Gemini Thinking
2. Set level (low/medium/high)
3. Works with: gemini-3-*-preview models

**DeepSeek:** The `deepseek-reasoner` model automatically uses reasoning (no setting needed).

Best for: Complex analysis, reasoning problems, nuanced questions

### AI Behavior Variants

Three styles of AI personality, configurable globally or per-action:

- **Minimal** (~100 tokens): Brief guidelines, lower cost
- **Full** (~500 tokens): Comprehensive guidelines for natural, well-formatted responses
- **Custom**: Your own behavior instructions, fully customizable

Individual actions can override the global setting:
- Use a different variant (minimal/full/custom/none)
- Provide completely custom behavior text per-action
- The built-in Translate action uses minimal behavior for direct, accurate translations

---

## Supported Providers

KOAssistant supports **16 AI providers**. Anthropic (Claude) has been the primary focus and most thoroughly tested. Please test and give feedback -- fixes are quickly implemented

| Provider | Description | Get API Key |
|----------|-------------|-------------|
| **Anthropic** | Claude models (primary focus) | [console.anthropic.com](https://console.anthropic.com/) |
| **OpenAI** | GPT models | [platform.openai.com](https://platform.openai.com/) |
| **DeepSeek** | Cost-effective reasoning models | [platform.deepseek.com](https://platform.deepseek.com/) |
| **Gemini** | Google's Gemini models | [aistudio.google.com](https://aistudio.google.com/) |
| **Ollama** | Local models (no API key needed) | [ollama.ai](https://ollama.ai/) |
| **Groq** | Extremely fast inference | [console.groq.com](https://console.groq.com/) |
| **Fireworks** | Fast inference for open models | [fireworks.ai](https://fireworks.ai/) |
| **SambaNova** | Fastest inference, free tier available | [cloud.sambanova.ai](https://cloud.sambanova.ai/) |
| **Together** | 200+ open source models | [api.together.xyz](https://api.together.xyz/) |
| **Mistral** | European provider, coding models | [console.mistral.ai](https://console.mistral.ai/) |
| **xAI** | Grok models, up to 2M context | [console.x.ai](https://console.x.ai/) |
| **OpenRouter** | Meta-provider, 500+ models | [openrouter.ai](https://openrouter.ai/) |
| **Cohere** | Command models | [dashboard.cohere.com](https://dashboard.cohere.com/) |
| **Qwen** | Alibaba's Qwen models | [dashscope.console.aliyun.com](https://dashscope.console.aliyun.com/) |
| **Kimi** | Moonshot, 256K context | [platform.moonshot.cn](https://platform.moonshot.cn/) |
| **Doubao** | ByteDance Volcano Engine | [console.volcengine.com](https://console.volcengine.com/) |

### Adding Custom Models

In the model selection menu, choose "Custom model..." to enter any model ID your provider supports.

### Provider Quirks

- **Anthropic**: Temperature capped at 1.0; Extended thinking forces temp to exactly 1.0
- **OpenAI**: Reasoning models (o3, GPT-5.x) force temp to 1.0; newer models use `max_completion_tokens`
- **Gemini**: Uses "model" role instead of "assistant"; thinking uses camelCase REST API format
- **Ollama**: Local only; configure `base_url` in `configuration.lua` for remote instances
- **OpenRouter**: Requires HTTP-Referer header (handled automatically)
- **Cohere**: Uses v2/chat endpoint with different response format
- **DeepSeek**: `deepseek-reasoner` model always reasons automatically

---

## Troubleshooting

### "API key missing" error
Edit `apikeys.lua` and add your key for the selected provider.

### No response / timeout
1. Check internet connection
2. Enable Debug Mode to see the actual error
3. Try Test Connection in settings

### Streaming not working
1. Ensure "Enable Streaming" is on in Advanced settings
2. Some providers may have different streaming support

### Wrong model showing
1. Check Settings → AI Provider & Model
2. When switching providers, the model resets to that provider's default

### Chats not saving
1. Check Settings → Conversations → Auto-save settings
2. Manually save via the Save button in chat

### Debug Mode

Enable in Settings → Advanced → Debug Mode

Shows:
- Full request body sent to API
- Raw API response
- Configuration details (provider, model, temperature, etc.)

---

## Requirements

- KOReader 2023.04 or newer
- Internet connection
- At least one API key

---

## Contributing

Contributions welcome! You can:
- Report bugs and issues
- Submit pull requests
- Share feature ideas
- Improve documentation
- [Translate the plugin UI](#contributing-translations) via Weblate

### For Developers

A standalone test suite is available in `tests/`. See `tests/README.md` for setup and usage:

```bash
lua tests/run_tests.lua --unit   # Fast unit tests (no API calls)
lua tests/run_tests.lua --full   # Comprehensive provider tests
lua tests/inspect.lua anthropic  # Inspect request structure
lua tests/inspect.lua --web      # Interactive web UI
```

### Contributing Translations

KOAssistant supports localization with translations managed via Weblate.

[![Translation Status](https://hosted.weblate.org/widgets/koassistant/-/svg-badge.svg)](https://hosted.weblate.org/engage/koassistant/)

**[Contribute translations on Weblate](https://hosted.weblate.org/engage/koassistant/)**

**Current languages:** Arabic, Chinese, French, German, Italian, Portuguese, Spanish

**Important:** Initial translations were AI-generated and marked as "needs review" (fuzzy). They may contain inaccuracies or awkward phrasing. Human review and corrections are welcome!

**If you don't like the translations:** You can disable them in Settings → Language → disable "Match KOReader UI Language" to always show the original English UI.

**To contribute:**
1. Visit the [KOAssistant Weblate project](https://hosted.weblate.org/engage/koassistant/)
2. Create an account or log in
3. Select a language and start reviewing/translating
4. Translations sync automatically to this repository

**To add a new language:** Request it on Weblate or open a GitHub issue.

**Note:** The plugin is under active development, so some strings may change between versions. Contributions are still valuable and will be maintained.

---

## Credits

### History

Originally forked from [ASKGPT by Drew Baumann](https://github.com/drewbaumann/askgpt) in February 2025. Expanded with multi-provider support, custom actions, chat history, domains, and more. This project was originally forked from [ASKGPT by Drew Baumann](https://github.com/drewbaumann/askgpt), renamed to Assistant, and xpanded with multi-provider support, custom actions, chat history, and more. Recently renamed to "KOAssistant" due to a naming conflict with [a fork of this project](https://github.com/omer-faruq/assistant.koplugin). Some internal references may still show the old name.

### Acknowledgments

- Drew Baumann - Original ASKGPT plugin
- KOReader community - Excellent plugin framework
- All contributors and testers

### License

GNU General Public License v3.0 - See [LICENSE](LICENSE)

---

**Questions or Issues?**
- [GitHub Issues](https://github.com/zeeyado/koassistant.koplugin/issues)
- [KOReader Docs](https://koreader.rocks/doc/)
