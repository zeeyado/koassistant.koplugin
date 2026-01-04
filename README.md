# KOAssistant - AI Assistant for KOReader

A powerful AI assistant integrated into KOReader.

Meant to be a technical research assistant and knowledge expander.

You can have context free chats, or chat about or compare one or more documents in your library, or about text highlighted in a document. You can translate, get text explained, compare books/articles, and much more by creating custom actions. Chats are automatically saved and you can resume them any time.

Most settings are configurable in the UI, including provider/model, AI behavior, and more, with some advanced settings requiring file editing.

> **Development Status**: KOAssistant is under active development. **Anthropic (Claude)** is the primary focus and most thoroughly tested. Other providers (OpenAI, DeepSeek, Gemini, Ollama) are supported but may need adjustments and further integration. Feedback appreciated.

> **Note**: This project was recently renamed from "Assistant" to "KOAssistant" due to a naming conflict with [a fork of this project](https://github.com/omer-faruq/assistant.koplugin). Some internal references may still show the old name.


---

## Table of Contents

- [Quick Setup](#quick-setup)
- [Recommended Setup](#recommended-setup)
- [How to Use KOAssistant](#how-to-use-koassistant)
  - [Highlight Mode](#highlight-mode)
  - [Book Mode](#book-mode)
  - [Multi-Book Mode](#multi-book-mode)
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
- [Credits](#credits)

---

## Quick Setup

**Get started in 3 steps:**

### 1. Install the Plugin

Download from [Releases](https://github.com/zeeyado/koassistant.koplugin/releases) or clone:
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

Edit `apikeys.lua` and add your API key:
```lua
return {
    anthropic = "your-key-here",  -- Get from console.anthropic.com
    openai = "",     -- Optional: platform.openai.com
    deepseek = "",   -- Optional: platform.deepseek.com
    gemini = "",     -- Optional: aistudio.google.com
    ollama = "",     -- Usually empty for local Ollama
}
```

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

**Built-in Actions**:
| Action | Description |
|--------|-------------|
| **Ask** | Free-form question about the text |
| **Explain** | Detailed explanation of the passage |
| **ELI5** | Explain Like I'm 5 - simplified explanation |
| **Summarize** | Concise summary of the text |
| **Translate** | Translate to your configured language |

**What the AI sees**: Your highlighted text, plus optionally the book title and author.

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
4. **Advanced**: Provider, Model, Temperature and Extended thinking overrides 

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
- `extended_thinking`: Override thinking ("off" to disable, "on" to enable)
- `thinking_budget`: Token budget when extended_thinking="on" (1024-32000)
- `enabled`: Set to `false` to hide
- `include_book_context`: Add book info to highlight actions
- `domain`: Lock to a specific domain

See `custom_actions.lua.sample` for more examples.

---

## Settings Reference

**Tools → KOAssistant → Settings**

### Quick Actions
- **New General Chat**: Start a context-free conversation
- **Chat History**: Browse saved conversations

### Provider & Model
- **Provider**: Select AI provider (Anthropic, OpenAI, DeepSeek, Gemini, Ollama)
- **Model**: Select model for the chosen provider
- **Temperature**: Response creativity (0.0-2.0, Anthropic max 1.0)

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
- **AI Behavior**: Minimal (~100 tokens) or Full (~500 tokens) guidelines
- **Enable Extended Thinking**: Enable Claude's reasoning capability (Anthropic only)
- **Thinking Budget**: Token budget for reasoning (1024-32000)
- **Console Debug**: Enable terminal/console debug logging
- **Show Debug in Chat**: Display debug info in chat viewer
- **Debug Detail Level**: Verbosity (Minimal/Names/Full)
- **Test Connection**: Verify API credentials work

### Actions & Domains
- **Translation Language**: Target language for the Translate action
- **Manage Actions**: Enable/disable built-in actions, create custom actions
- **View Domains**: See available knowledge domains

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

### Extended Thinking (Anthropic)

For complex questions, Claude can "think" through the problem before responding:

1. Enable in Settings → Advanced → Enable Extended Thinking
2. Set token budget (1024-32000)
3. Temperature is forced to 1.0 (API requirement)

Best for: Complex analysis, reasoning problems, nuanced questions

### AI Behavior Variants

Two styles of AI personality, configurable globally or per-action:

- **Minimal** (~100 tokens): Brief guidelines, lower cost
- **Full** (~500 tokens): Comprehensive guidelines for natural, well-formatted responses

Individual actions can override the global setting:
- Use a different variant (minimal/full/none)
- Provide completely custom behavior text
- The built-in Translate action uses minimal behavior for direct, accurate translations

---

## Supported Providers

| Provider | Status | API Key From |
|----------|--------|--------------|
| **Anthropic** | Primary focus | [console.anthropic.com](https://console.anthropic.com/) |
| OpenAI | Supported | [platform.openai.com](https://platform.openai.com/) |
| DeepSeek | Supported | [platform.deepseek.com](https://platform.deepseek.com/) |
| Gemini | Supported | [aistudio.google.com](https://aistudio.google.com/) |
| Ollama | Supported | Local (no key needed) |

### Adding Custom Models

In the model selection menu, choose "Custom model..." to enter any model ID your provider supports.

### Provider Quirks

- **Anthropic**: Temperature capped at 1.0; Extended thinking forces temp to exactly 1.0
- **Gemini**: Uses "model" role instead of "assistant"
- **Ollama**: Local only; configure `base_url` in `configuration.lua` for remote instances

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

---

## Credits

### History

Originally forked from [ASKGPT by Drew Baumann](https://github.com/drewbaumann/askgpt) in February 2025. Expanded with multi-provider support, custom actions, chat history, domains, and more.

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
