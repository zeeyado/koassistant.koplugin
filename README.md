# KOAssistant

[![GitHub Release](https://img.shields.io/github/v/release/zeeyado/koassistant.koplugin)](https://github.com/zeeyado/koassistant.koplugin/releases/latest)
[![License: GPL-3.0](https://img.shields.io/github/license/zeeyado/koassistant.koplugin)](LICENSE)
[![Translation Status](https://hosted.weblate.org/widgets/koassistant/-/svg-badge.svg)](https://hosted.weblate.org/engage/koassistant/)

**Powerful AI assistant integrated into KOReader.**

A highly flexible and customizable reading and research assistant and knowledge expander.

You can have context free chats, chat about documents in your library, or about text highlighted in a document, with or without additional context. You can translate text, get text explained/analyzed, compare books/articles, and much more by creating advanced and elaborate custom actions, additional contexts, and instructions, all with their own highly granular settings. 

Chats are streamed live (like ChatGPT/Claude, etc), are automatically (or manually) saved, and you can resume them any time, and continue chats with a different provider/model and other changed settings if you like. You can one-click export/copy whole chats to clipboard (markdown formatting), or select and copy text from chats, to then paste e.g. in a highlight note in your document. Your chat reply drafts are saved so you can re-read AI messages and resume typing, or copy and paste parts as you are structuring your reply.

Most settings are configurable in the UI, including: Provider/model, AI behavior and style, user-to-AI interaction languages, translation languages, domains/project/field context, custom actions (which you can create, edit, duplicate, and adjust settings for), and advanced model settings like reasoning/thinking, temperature, and more. Most settings, additional context, and function combinations can be specified for a given action.

> **Development Status**: KOAssistant is currently under active development, with features constantly added. 16 providers are supported (see [Supported Providers](#supported-providers)); **testing and Feedback appreciated**. You can open an issue, feature request, or start a discussion. If you don't want to wait for releases, you can clone the repo from main and check `_meta.lua` to see which version you are on. Some things may break when not on official releases. Running off of other branches than main is not recommended. Due to the current changing nature of the plugin, parts of the documentation (READMEs) may be out of sync.

---

## Table of Contents

- [Quick Setup](#quick-setup)
- [Recommended Setup](#recommended-setup)
- [How to Use KOAssistant](#how-to-use-koassistant)
- [Dictionary Integration](#dictionary-integration)
- [Bypass Modes](#bypass-modes)
- [AI Behavior](#ai-behavior)
- [Managing Conversations](#managing-conversations)
- [Knowledge Domains](#knowledge-domains)
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

**Option A: Via Settings**

1. Go to **Tools → KOAssistant → API Keys**
2. Tap any provider to enter your API key
3. Keys are shown semi-blurred in your settings

**Option B: Via Configuration File**

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

> **Note:** GUI-entered keys take priority over file-based keys. The API Keys menu shows `[set]` for GUI keys and `(file)` for keys from apikeys.lua.

See [Supported Providers](#supported-providers) for full list with links to get API keys.

### 3. Restart KOReader

Find KOAssistant Settings in: **Tools → Page 2 → KOAssistant**

---

## Recommended Setup

### Configure Quick Access Gestures

For easy access to a list of settings, assign KOAssistant actions to a gesture:

1. Go to **Settings → Gesture Manager → Tap corner → Bottom left** (or your preferred gesture)
2. Select **General**
3. Add KOAssistant actions:
   - Chat History
   - Continue Last Chat
   - General Chat
   - Chat About Book
   - Settings
   - Toggle Dictionary Bypass
   - Toggle Highlight Bypass
   - Translate Current Page
   - ...
4. Enable **"Show as QuickMenu"**

> **Tip**: Set up gestures in both **Reader View** (while reading) and **File Browser** separately.
>
> **Tip**: Set other gestures for specific actions you use often, e.g. a multiswipe gesture for "Open Last Chat" if you keep going back and forth between a document and a specific chat.
>
> **Tip**: Assign "Toggle Dictionary Bypass" to a quick gesture if you frequently switch between AI and regular dictionary lookups.


### Key Features to Explore

After basic setup, explore these features to get the most out of KOAssistant:

| Feature | What it does | Where to configure |
|---------|--------------|-------------------|
| **AI Behavior** | Control response style (concise, detailed, custom) | Settings → Advanced → Manage Behaviors |
| **Knowledge Domains** | Add project-like context to conversations | Settings → Advanced → Manage Domains |
| **Custom Actions** | Create your own prompts and workflows | Settings → Manage Actions |
| **Highlight Menu** | Add actions directly to highlight popup | Manage Actions → Add to Highlight Menu |
| **Dictionary Integration** | AI-powered word lookups when tapping words | Settings → Dictionary Settings |
| **Bypass Modes** | Instant AI actions without menus | Settings → Dictionary/Highlight Settings |
| **Reasoning/Thinking** | Enable deep analysis for complex questions | Settings → Advanced → Reasoning |
| **Languages** | Configure multilingual responses | Settings → Language |

See detailed sections below for each feature.

### Tips for Better Results

- **Good document metadata** improves AI responses. Use Calibre, Zotero, or similar tools to ensure titles, authors, and identifiers are correct.
- **Shorter tap duration** makes text selection in KOReader easier: Settings → Taps and Gestures → Long-press interval
- **Choose models wisely**: Fast models (like Haiku) for quick queries; powerful models (like Sonnet, Opus) for deeper analysis.
- **Explore sample behaviors**: The `behaviors.sample/` folder has 25+ behaviors including provider-inspired styles (Claude, GPT, Gemini, etc.) and reading-specialized options. Copy ones you like to `behaviors/`.
- **Combine behaviors with domains**: Behavior controls *how* the AI communicates; Domain provides *what* context. Try `scholarly_standard` + a research domain for rigorous academic analysis. 

---

## How to Use KOAssistant

KOAssistant works in **4 contexts**, each with its own set of actions, and you can create custom actions for each and all contexts, and enable/disable the built in ones:

### Highlight Mode

**Access**: Highlight text in a document → tap "KOAssistant"

**Quick Actions**: You can add frequently-used actions directly to KOReader's highlight popup menu for faster access. Instead of going through the KOAssistant dialog, actions like "KOA: Explain" or "KOA: Translate" appear as separate buttons. See [Highlight Menu Actions](#highlight-menu-actions) below.

**Bypass Mode**: Skip the highlight menu entirely and trigger your chosen action immediately when selecting text. See [Highlight Bypass](#highlight-bypass) below.

**Built-in Actions**:
| Action | Description |
|--------|-------------|
| **Ask** | Free-form question about the text |
| **Explain** | Detailed explanation of the passage |
| **ELI5** | Explain Like I'm 5 - simplified explanation |
| **Summarize** | Concise summary of the text |
| **Elaborate** | Expand on concepts, provide additional context and details |
| **Translate** | Translate to your configured language |
| **Dictionary** | Word definition with context (also accessible via word tap) |

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
| **Ask** | Free-form question about the selected books |
| **Compare** | Compare themes, styles, target audiences |
| **Find Common Themes** | Identify shared topics and patterns |
| **Analyze Collection** | What this selection reveals about reader interests |
| **Quick Summaries** | Brief summary of each book |

**What the AI sees**: List of titles, authors, and identifiers 

### General Chat

**Access**: Tools → KOAssistant → New General Chat, or via gesture (easier)

A free-form conversation without specific document context. If started while a book is open, that "launch context" is saved with the chat (so you know where you launched it from) but doesn't affect the conversation, i.e. the AI doesn't see that you launched it from a specific document, and the chat is saved in General chats

### Quick UI Features

- **Settings Icon (Input)**: Tap the gear icon in the input dialog title bar to open AI Quick Settings—a two-column panel for provider, model, behavior, domain, temperature, streaming, primary language, and translation language
- **Settings Icon (Viewer)**: Tap the gear icon in the chat viewer title bar to adjust font size and text alignment (left/justified/right for RTL)
- **Show/Hide Quote**: In the chat viewer, toggle button to show or hide the highlighted text quote (useful for long selections)
- **Other**: Turn on off Text/Markdown view, Debug view mode, add Tags, Change Domain, etc

---

## Dictionary Integration

KOAssistant integrates with KOReader's dictionary system, providing AI-powered word lookups when you tap on words in a document.

### How It Works

When you tap a word in a document, KOReader normally shows its dictionary popup. With KOAssistant's dictionary integration, you can:

1. **Add an AI button to the dictionary popup** - See an "AI Dictionary" button alongside KOReader's built-in dictionary results
2. **Bypass the dictionary entirely** - Skip KOReader's dictionary and go directly to AI for word lookups

### Dictionary Settings

**Settings → Dictionary Settings**

| Setting | Description |
|---------|-------------|
| **AI Button in Dictionary Popup** | Show "AI Dictionary" button in KOReader's dictionary popup |
| **Response Language** | Language for dictionary definitions (follow translation language or set specific) |
| **Context Mode** | How much surrounding text to include: Sentence, Paragraph, Characters (custom count), or None |
| **Context Characters** | Number of characters when using "Characters" mode (default: 100) |
| **Disable Auto-save** | Don't auto-save dictionary lookups (default: on). Disable to follow general chat saving settings |
| **Enable Streaming** | Stream dictionary responses in real-time |
| **Dictionary Popup Actions** | Configure which actions appear in the dictionary popup's AI menu |
| **Bypass KOReader Dictionary** | Skip dictionary popup, go directly to AI (see below) |
| **Bypass Action** | Which action to trigger when bypass is enabled |
| **Bypass: Follow Vocab Builder Auto-add** | When enabled, bypass follows KOReader's Vocabulary Builder auto-add setting |

### Dictionary Popup Actions

When "AI Button in Dictionary Popup" is enabled, tapping the AI button shows a menu of actions. Configure this menu:

1. **Settings → Dictionary Settings → Dictionary Popup Actions**
2. Enable/disable actions and reorder them
3. First action in the list is shown as the primary option

The dictionary context (surrounding sentence/text) is automatically extracted and included with dictionary actions.

### Dictionary Bypass

When bypass is enabled, tapping a word skips KOReader's dictionary popup entirely and immediately triggers your chosen AI action.

**To enable:**
1. Settings → Dictionary Settings → Bypass KOReader Dictionary → ON
2. Settings → Dictionary Settings → Bypass Action → choose action (default: Dictionary)

**Toggle via gesture:** Assign "KOAssistant: Toggle Dictionary Bypass" to a gesture for quick on/off switching.

**Note:** Dictionary bypass uses compact view by default for quick, focused responses.

### Vocabulary Builder Integration

When using dictionary lookups in compact view, KOAssistant integrates with KOReader's Vocabulary Builder:

- **Auto-add enabled** (Vocabulary Builder ON in KOReader settings): Words are automatically added to vocab builder when looked up via dictionary bypass. A greyed "Added" button confirms the word was added.
- **Auto-add disabled** (Vocabulary Builder OFF): A "+Vocab" button appears to manually add the looked-up word to the vocabulary builder.

The vocab button appears in compact/minimal buttons view (dictionary bypass and popup actions).

**Bypass: Follow Vocab Builder Auto-add** (Settings → Dictionary Settings): Controls whether dictionary bypass respects KOReader's Vocabulary Builder auto-add setting. Disable this if you use bypass for analyzing words you already know and don't want them added to the vocabulary builder.

### Chat Saving

Dictionary lookups are **not auto-saved** by default (`Disable Auto-save` is on). This prevents cluttering your chat history with individual word lookups.

- **Auto-save disabled** (default): Lookups are not saved automatically. If you expand a compact view chat, the Save button becomes active so you can save manually to the current document.
- **Auto-save enabled** (toggle off): Dictionary chats follow your general chat saving settings (auto-save all or auto-save continued).

---

## Bypass Modes

Bypass modes let you skip menus and immediately trigger AI actions. Both dictionary and highlight bypass work similarly:

### Dictionary Bypass

Skip KOReader's dictionary popup when tapping words. Useful for language learners who want instant AI definitions.

**How it works:**
1. Tap a word in the document
2. Instead of dictionary popup → AI action triggers immediately
3. Response appears in compact view

**Configure:** Settings → Dictionary Settings → Bypass KOReader Dictionary

### Highlight Bypass

Skip the highlight menu when selecting text. Useful when you always want the same action (e.g., translate).

**How it works:**
1. Select text by long-pressing and dragging
2. Instead of highlight menu → AI action triggers immediately
3. Response appears based on action settings

**Configure:** Settings → Highlight Settings → Enable Highlight Bypass

### Bypass Action Selection

Both bypass modes let you choose which action triggers:

| Bypass Mode | Default Action | Where to Configure |
|-------------|----------------|-------------------|
| Dictionary | Dictionary | Settings → Dictionary Settings → Bypass Action |
| Highlight | Translate | Settings → Highlight Settings → Bypass Action |

You can select any highlight-context action (built-in or custom) as your bypass action.

### Gesture Toggles

Quick toggle bypass modes without entering settings:

- **KOAssistant: Toggle Dictionary Bypass** - Assign to gesture
- **KOAssistant: Toggle Highlight Bypass** - Assign to gesture

Toggling shows a brief notification confirming the new state.

### Translate Current Page

A special gesture action to translate all visible text on the current page:

**Gesture:** KOAssistant: Translate Current Page

This extracts all text from the visible page/screen and sends it to the Translate action. Unlike dictionary/highlight bypass, this uses full view (not compact) since page translations are longer.

**Works with:** PDF, EPUB, DjVu, and other supported document formats.

---

## AI Behavior

Behavior defines the AI's personality, communication style, and response guidelines. It is sent **first** in the system instructions, before any domain context.

### What Behavior Controls

- Response tone (conversational, academic, concise)
- Formatting preferences (when to use lists, headers, etc.)
- Communication style (brief vs detailed explanations)

### Built-in Behaviors

Five built-in behaviors are always available (based on [Anthropic Claude guidelines](https://docs.anthropic.com/en/release-notes/system-prompts)):

- **Mini** (~220 tokens): Concise guidance for e-reader conversations
- **Standard** (~420 tokens): Balanced guidance for quality responses
- **Full** (~1150 tokens): Comprehensive guidance for best quality responses
- **Research Standard** (~470 tokens): Research-focused with source transparency (based on Perplexity)
- **Translator Direct** (~80 tokens): Direct translation without commentary (used by Translate action)

### Sample Behaviors

The `behaviors.sample/` folder contains a comprehensive collection including:

- **Provider-inspired styles**: Claude, GPT, Gemini, Grok, Perplexity, DeepSeek (all provider-agnostic)
- **Reading-specialized**: Scholarly, Translator, Religious/Classical, Creative
- **Multiple sizes**: Mini (~160-190 tokens), Standard (~400-500), Full (~1150-1325)

To use: copy desired files from `behaviors.sample/` to `behaviors/` folder.

### Custom Behaviors

Create your own behaviors via:

1. **Files**: Add `.md` or `.txt` files to `behaviors/` folder
2. **UI**: Settings → Advanced → Manage Behaviors → Create New

**File format** (same as domains):
- Filename becomes the behavior ID: `concise.md` → ID `concise`
- First `# Heading` becomes the display name
- Rest of file is the behavior text sent to AI

See `behaviors.sample/README.md` for full documentation.

### Per-Action Overrides

Individual actions can override the global behavior:
- Use a different variant (minimal/full/none)
- Provide completely custom behavior text
- Example: The built-in Translate action uses minimal behavior for direct translations

---

## Managing Conversations

### Auto-Save

By default, all chats are automatically saved. You can disable this in Settings → Conversations.

- **Auto-save All Chats**: Save every new conversation
- **Auto-save Continued Chats**: Only save when continuing from history (i.e. from an already saved chat)

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

### Tags

Tags are simple labels for organizing chats. Unlike domains:
- No context attached (just labels)
- Can be added/removed anytime
- Multiple tags per chat allowed

**Adding Tags**:
- In chat viewer: Tap the **#** button in the chat viewer
- In chat history: Long-press a chat → Tags

**Browsing by Tag**: Chat History → hamburger menu → View by Tag

---

## Knowledge Domains

Domains provide **project-like context** for AI conversations. When selected, the domain context is sent **after** the behavior instructions in the system prompt.

### How It Works

System instructions are built as: **Behavior + Domain + Language**

This means:
- Behavior sets HOW the AI communicates
- Domain sets WHAT knowledge context to apply
- Both benefit from Anthropic's prompt caching (90% cost reduction on repeated queries)

You can have very small, focused domains, or large, detailed, interdisciplinary ones.

### Built-in Domain

One AI-generated domain is built-in: **Critical Reader** (~250 tokens) - analytical stance for evaluating arguments and evidence.

This serves as an example of what domains can do. For more options/inspiration, see `domains.sample/` which includes specialized sample domains.

### Creating Domains

Create domains via:

1. **Files**: Add `.md` or `.txt` files to `domains/` folder
2. **UI**: Settings → Advanced → Manage Domains → Create New

**File format**:

**Example**: `domains/philosophy.md`
```markdown
# Philosophy
<!--
Tokens: ~100
Notes: General philosophical inquiry
-->

This conversation relates to philosophical inquiry and analysis.
Consider different schools of thought, logical arguments, and ethical implications.
Reference relevant philosophers and their works when appropriate.
```

- Filename becomes the domain ID: `my_domain.md` → ID `my_domain`
- First `# Heading` becomes the display name (or derived from filename)
- Metadata in `<!-- -->` comments is optional (for tracking token costs)
- Rest of file is the context sent to AI
- Supported: `.md` and `.txt` files

See `domains.sample/` for examples including classical language support and interpretive frameworks.

### Selecting Domains

Domains are selected **per-chat** when starting a conversation:

1. In the chat dialog, tap the **Domain** button
2. Select a domain from the list
3. All messages in this chat will include that domain's context

**Note**: Domains must be selected at the start of a chat (they provide context for the AI). Larger domains give better results but increase API costs. Once a domain is picked in the input window, it stays active until replaced by "None" or another domain; keep this in mind if you often use quick actions without opening the input dialog. You can clear/change the domain through several settings and gestures.

### Browsing by Domain

Chat History → hamburger menu → **View by Domain**

**Note**: Domains are for context, not storage. Chats still save to their book or "General AI Chats", but you can filter by domain in Chat History.

---

## Custom Actions

Actions define what you're asking the AI to do. Combined with behavior and domain, they form the complete request:

**Request = Behavior (how) + Domain (context) + Action (what) + User Input (details)**

When you select an action and start a chat, you can optionally add your own input (a question, additional context, or specific request) which gets combined with the action's prompt template.

### Managing Actions in the UI

**Tools → KOAssistant → Manage Actions**

- Toggle built-in and custom actions on/off
- Create new actions with the wizard
- Edit or delete your custom actions (marked with ★)
- Edit settings for built-in actions (temperature, thinking, provider/model, AI behavior)
- Duplicate/Copy existing Actions to use them as template (e.g. to make a slightly different variant)

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
| `{dictionary_language}` | Any | Dictionary response language from settings |
| `{context}` | Highlight | Surrounding text context (sentence/paragraph/characters) |

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
- `skip_language_instruction`: Don't send user's language preferences to AI (default: off, except Translate action)
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

### API Keys
- Enter API keys directly via the GUI (no file editing needed)
- Shows status indicators: `[set]` for GUI-entered keys, `(file)` for keys from apikeys.lua
- GUI keys take priority over file-based keys
- Tap a provider to enter, view (masked), or clear its key

### Display Settings
- **Render Markdown**: Format responses with styling (bold, lists, etc.)
- **Hide Highlighted Text**: Don't show selection in responses
- **Hide Long Highlights**: Collapse highlights over character threshold
- **Long Highlight Threshold**: Character limit before collapsing (default: 280)

### Chat Settings
- **Auto-save All Chats**: Automatically save every new conversation
- **Auto-save Continued Chats**: Only save when continuing from history
- **Enable Streaming**: Show responses as they generate in real-time
- **Auto-scroll Streaming**: Follow new text during streaming (off by default)
- **Large Stream Dialog**: Use full-screen streaming window

### Advanced
- **Manage Behaviors**: Select or create AI behavior styles (shows current selection)
- **Manage Domains**: Create and manage knowledge domains for project-like context
- **Temperature**: Response creativity (0.0-2.0, Anthropic max 1.0)
- **Reasoning/Thinking**: Per-provider reasoning settings:
  - **Anthropic Extended Thinking**: Budget 1024-32000 tokens
  - **OpenAI Reasoning**: Effort level (low/medium/high)
  - **Gemini Thinking**: Level (low/medium/high)
- **Console Debug**: Enable terminal/console debug logging
- **Show Debug in Chat**: Display debug info in chat viewer
- **Debug Detail Level**: Verbosity (Minimal/Names/Full)
- **Test Connection**: Verify API credentials work

### Dictionary Settings
- **AI Button in Dictionary Popup**: Show AI Dictionary button when tapping words
- **Response Language**: Language for definitions (Follow Translation Language or specific)
- **Context Mode**: Surrounding text to include (Sentence, Paragraph, Characters, None)
- **Context Characters**: Character count for Characters mode (default: 100)
- **Disable Auto-save for Dictionary**: Don't auto-save dictionary lookups (default: on)
- **Enable Streaming**: Stream dictionary responses in real-time
- **Dictionary Popup Actions**: Configure actions in the dictionary popup AI menu
- **Bypass KOReader Dictionary**: Skip dictionary popup, go directly to AI
- **Bypass Action**: Which action to trigger when bypass is enabled (default: Dictionary)
- **Bypass: Follow Vocab Builder Auto-add**: Follow KOReader's Vocabulary Builder auto-add in bypass mode

### Highlight Settings
- **Enable Highlight Bypass**: Immediately trigger action when selecting text (skip menu)
- **Bypass Action**: Which action to trigger when bypass is enabled (default: Translate)
- **Highlight Menu Actions**: View and reorder actions in the highlight popup menu

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

**Note:** The built-in Translate action skips language instruction by default since it specifies the target language directly in the prompt. You can toggle this in the action's settings, and custom actions can use `skip_language_instruction` to control this behavior.

### Actions
- **Manage Actions**: Enable/disable built-in actions, create custom actions
- **Highlight Menu Actions**: View and reorder actions added to the highlight popup menu

### Highlight Menu Actions

Add frequently-used highlight actions directly to KOReader's highlight popup for faster access:

1. Go to **Manage Actions**
2. Tap on a highlight-context action (Explain, Translate, etc.)
3. Tap **"Add to Highlight Menu"**
4. A notification reminds you to restart KOReader

Actions appear as "KOA: Explain", "KOA: Translate", etc. in the highlight popup.

**Managing quick actions**:
- Use **Settings → Highlight Settings → Highlight Menu Actions** to view all enabled quick actions
- Tap an action to move it up/down or remove it
- Actions requiring user input (like "Ask") cannot be added

**Note**: Changes require an app restart since the highlight menu is built at startup. A notification appears when you make changes.

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

This project was originally forked from [ASKGPT by Drew Baumann](https://github.com/drewbaumann/askgpt), renamed to Assistant, and expanded with multi-provider support, custom actions, chat history, and more. Recently renamed to "KOAssistant" due to a naming conflict with [a fork of this project](https://github.com/omer-faruq/assistant.koplugin). Some internal references may still show the old name.

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
