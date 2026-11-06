# KOAssistant

[![GitHub Release](https://img.shields.io/github/v/release/zeeyado/koassistant.koplugin)](https://github.com/zeeyado/koassistant.koplugin/releases/latest)
[![Wiki](https://img.shields.io/badge/docs-wiki-blue)](https://github.com/zeeyado/koassistant.koplugin/wiki)
[![License: GPL-3.0](https://img.shields.io/github/license/zeeyado/koassistant.koplugin)](LICENSE)
[![AI-translated](https://img.shields.io/badge/dynamic/json?url=https%3A%2F%2Fhosted.weblate.org%2Fapi%2Fprojects%2Fkoassistant%2Fstatistics%2F&query=%24.fuzzy_percent&suffix=%25&label=AI-translated&color=8ab4f8&cacheSeconds=3600)](https://hosted.weblate.org/engage/koassistant/)
[![Human-reviewed](https://img.shields.io/badge/dynamic/json?url=https%3A%2F%2Fhosted.weblate.org%2Fapi%2Fprojects%2Fkoassistant%2Fstatistics%2F&query=%24.translated_percent&suffix=%25&label=human-reviewed&color=brightgreen&cacheSeconds=3600)](https://hosted.weblate.org/engage/koassistant/)

**Powerful, customizable AI assistant for KOReader.**

**Documentation:** the [Wiki](https://github.com/zeeyado/koassistant.koplugin/wiki) has a page for every feature; the full list is at the [end of this page](#documentation).

<p align="center">
  <a href="screenshots/ELI5highlightchat.png"><img src="screenshots/ELI5highlightchat.png" width="180" alt="AI explains highlighted text"></a>
  <a href="screenshots/Xraybrowser.png"><img src="screenshots/Xraybrowser.png" width="180" alt="X-Ray browser"></a>
  <a href="screenshots/compactdict.png"><img src="screenshots/compactdict.png" width="180" alt="Dictionary integration"></a>
  <a href="screenshots/settingsui.png"><img src="screenshots/settingsui.png" width="180" alt="Settings and menu"></a>
</p>

## What it does

- **Highlight text** → translate, explain, define words, analyze passages, connect ideas, and save the answer into KOReader's notes; short answers land in a small popup at your selection. [Contexts and Chat](https://github.com/zeeyado/koassistant.koplugin/wiki/Contexts-and-Chat)
- **X-Ray** → a browsable guide to the book up to where you are (people, places, ideas, terms), kept current by checkpoints as you read, with known names underlined in the text. [Using X-Ray](https://github.com/zeeyado/koassistant.koplugin/wiki/Using-X-Ray)
- **Book Groups** → a series or a project with its own hub and settings; what the other books' X-Rays know is carried in for free. [Book Groups and Series](https://github.com/zeeyado/koassistant.koplugin/wiki/Book-Groups-and-Series)
- **Book Hub** → one page per book gathering its artifacts, chats, notebook, group and settings. [Book Settings and Book Hub](https://github.com/zeeyado/koassistant.koplugin/wiki/Book-Settings-and-Book-Hub)
- **Reading analysis** → recap, document summary and analysis, an About overview, notes analysis, discussion questions, chapter quizzes, an end-of-book suggestion. [Reading Analysis Actions](https://github.com/zeeyado/koassistant.koplugin/wiki/Reading-Analysis-Actions)
- **Research Mode** → papers with a DOI get an academic X-Ray, research-aware prompts and, with web search on, web-enriched analysis, with no setup. [Research Mode](https://github.com/zeeyado/koassistant.koplugin/wiki/Research-Mode)
- **Spoiler protection** → on by default: the AI stays behind your reading position, per book or for one chat. [Spoiler Protection](https://github.com/zeeyado/koassistant.koplugin/wiki/Spoiler-Protection)
- **Session controls** → a chip row in the input dialog (Domain, Web, Tools, Quick, Scope, Attach, Spoiler); most chips are a tap for this chat and a hold for their default. [Contexts and Chat](https://github.com/zeeyado/koassistant.koplugin/wiki/Contexts-and-Chat)
- **Dictionary and translation** → actions in KOReader's dictionary popup, a compact AI dictionary, bypass modes that skip the menus, and translate views. [Dictionary and Translation](https://github.com/zeeyado/koassistant.koplugin/wiki/Dictionary-and-Translation)
- **Notebooks** → a markdown notebook per book, an optional one-tap Add to notebook button in the highlight menu, Obsidian vault integration. [Conversations, Notebooks and Export](https://github.com/zeeyado/koassistant.koplugin/wiki/Conversations-Notebooks-and-Export)
- **Library** → what to read next, reading patterns, comparisons across books, collection analysis. [Contexts and Chat](https://github.com/zeeyado/koassistant.koplugin/wiki/Contexts-and-Chat)
- **General chat** → the AI without book context. [Contexts and Chat](https://github.com/zeeyado/koassistant.koplugin/wiki/Contexts-and-Chat)
- **Web search, book tools, reasoning** → current information from the web, the AI searching the open book for its answers, thinking set per model. [Reasoning, Web Search and Book Tools](https://github.com/zeeyado/koassistant.koplugin/wiki/Reasoning-Web-Search-and-Book-Tools)
- **Multilingual** → chat in any language the AI understands; the plugin's UI has 26 languages. [Languages](https://github.com/zeeyado/koassistant.koplugin/wiki/Languages)
- **Generate images** → a highlight or an X-Ray entry drawn by OpenAI, xAI, Gemini or OpenRouter, kept in a gallery on the device. [Image Generation](https://github.com/zeeyado/koassistant.koplugin/wiki/Image-Generation)
- **Customizable** → custom actions, behaviors, domains, per-action models, template variables, and control over every menu the plugin appears in. [Actions and Menus](https://github.com/zeeyado/koassistant.koplugin/wiki/Actions-and-Menus), [Prompts, Behaviors and Domains](https://github.com/zeeyado/koassistant.koplugin/wiki/Prompts-Behaviors-and-Domains)
- **Private by default** → your highlights, notes, notebook, the book's text, library and reading habits are asked for before anything goes. [Privacy and Data](https://github.com/zeeyado/koassistant.koplugin/wiki/Privacy-and-Data)
- **Keeps itself current** → one-tap updates, backups and restore. [Backups and Updates](https://github.com/zeeyado/koassistant.koplugin/wiki/Backups-and-Updates)

**Status:** active development; you can also run off the main branch for the newest features (untested, may break). [Issues](https://github.com/zeeyado/koassistant.koplugin/issues), [discussions](https://github.com/zeeyado/koassistant.koplugin/discussions) and [translations](https://hosted.weblate.org/engage/koassistant/) are welcome.

---

## Quick setup

You need KOReader, a connection, and a key, a ChatGPT plan or a local provider such as Ollama.

### 1. Install the plugin

Download `koassistant.koplugin.zip` from the latest [Release](https://github.com/zeeyado/koassistant.koplugin/releases) → Assets. To run the latest code instead: Code → Download Zip, or clone the repository:
```bash
git clone https://github.com/zeeyado/koassistant.koplugin
```

Extract or copy the `koassistant.koplugin` folder to your KOReader plugins directory:
```
Kobo:         /mnt/onboard/.adds/koreader/plugins/koassistant.koplugin/
Kindle:       /mnt/us/koreader/plugins/koassistant.koplugin/
Android:      /sdcard/koreader/plugins/koassistant.koplugin/
macOS:        ~/Library/Application Support/koreader/plugins/koassistant.koplugin/
Linux:        ~/.config/koreader/plugins/koassistant.koplugin/
```

The folder must be named exactly `koassistant.koplugin` (remove a "-main" suffix if you downloaded the zip of the main branch), with `main.lua` and `_meta.lua` directly inside it, not in a nested folder.

> **This is the only time you install by hand.** From then on KOAssistant updates itself: when a new version is out you see its release notes with an "Update Now" button, and one tap downloads, installs and keeps your settings. See [Updating](#updating).

**Alternative:** [Storefront](https://github.com/ultimatejimmy/storefront.koplugin) or the [App Store plugin](https://github.com/omer-faruq/appstore.koplugin) installs KOAssistant from inside KOReader, from releases or from the main branch, with no computer.

### 2. Restart KOReader

KOAssistant's menu is at **Tools → KOAssistant**, the first row of KOReader's Tools menu. The Setup Wizard runs the first time you open it: a provider, privacy, language, emoji icons, the (KOA) button mark, gestures; after an update it checks only what changed.

### 3. Add an API key

**In the plugin:** **Tools → KOAssistant → API Keys & Auth**, tap a provider and paste its key (shown masked afterwards; several keys per provider are kept). **In a file:** copy `apikeys.lua.sample` to `apikeys.lua`, fill it in and restart KOReader; keys entered in the plugin take priority over it. **A ChatGPT plan, no key:** **Settings → API Keys & Auth → OpenAI Subscription → Connect** shows a URL and a one-time code; open the URL on another device, enter the code, tap **Check authorization**.

## First steps

- Answer the question the first time an action wants your data, or set a kind to Allow or Never for all books under **Settings → Privacy & Data**. [Privacy and Data](https://github.com/zeeyado/koassistant.koplugin/wiki/Privacy-and-Data)
- Try the highlight menu: Translate, Explain, Quick Explain, Summarize, Quick Define and Dictionary are there by default. [Actions and Menus](https://github.com/zeeyado/koassistant.koplugin/wiki/Actions-and-Menus)
- Try the bypass modes: a single word straight to the AI dictionary, a longer selection straight to a translation. [Dictionary and Translation](https://github.com/zeeyado/koassistant.koplugin/wiki/Dictionary-and-Translation)
- Hold any action button for its description, one-time run options (Quick answer, another model, no reasoning, web search) and its placements.
- Open a book's X-Ray from Quick Actions and let checkpoints keep it current. [Using X-Ray](https://github.com/zeeyado/koassistant.koplugin/wiki/Using-X-Ray)

Quick Settings and Quick Actions are two panels that hold most of what you need; the wizard gives each its gesture. Everything about the wizard, the panels, gestures and bypass modes: [Setup, Gestures and Panels](https://github.com/zeeyado/koassistant.koplugin/wiki/Setup-Gestures-and-Panels).

## Privacy at a glance

KOAssistant sends data to AI providers to generate answers. The threat model is simple: you may include sensitive data (annotations, notes, book content) by accident. Pick providers thoughtfully; local or self-hosted models (Ollama and the local presets) keep everything on your own hardware.

- **Always sent:** your question, and the selected text for highlight actions.
- **Sent by default:** the book's title and author (Book info, which None turns off so nothing names the book), the enabled system content (languages, domain, behavior), your reading position (progress, chapter, time since you last read), the text around what you tap (a few sentences or one page), and a per-book Background note if you wrote one.
- **Asked the first time:** highlights, annotation notes, the notebook, the book's text (for X-Ray, Recap and the like), the library scan, reading habits (curated groups with rounded hours and days; the raw statistics stay on the device). The question names the action, the provider and the amount; **Allow once** covers that run, **Allow for this book** keeps your answer.

| Preset | What it does |
|---|---|
| **Default (Ask)** | Every value as it ships: the kinds above are asked for the first time an action wants them. |
| **Allow everything** | Every kind goes without a question, book text included. |
| **Block everything** | Every kind set to Never: only your question, the selected text and the book info go (and the behavior, domain and Background texts). |

Book text raises token costs, so its question says how much would go; trusted providers (a local Ollama, say) have their own values; a book's own Never beats everything.

The full model, the double-gating of book text, what each action accesses, and the design choices: [Privacy and Data](https://github.com/zeeyado/koassistant.koplugin/wiki/Privacy-and-Data).

## Supported providers

KOAssistant has **33 built-in providers**: a **curated set** the maintainer tests with real keys and automated probes, and a **community set** (marked `*` in the plugin, *Docs-based* below) implemented from provider documentation; plus any number of custom OpenAI-compatible providers you add yourself. OpenAI is listed twice: once for API keys, once for the ChatGPT-subscription login.

| Provider | Description | Status | Get API key |
|----------|-------------|--------|-------------|
| **Anthropic** | Claude models (primary focus). Claude Max and Team plans include monthly API credits | Tested | [console.anthropic.com](https://console.anthropic.com/) |
| **OpenAI** | GPT models | Tested | [platform.openai.com](https://platform.openai.com/) |
| **OpenAI Subscription** | GPT models through your ChatGPT plan's Codex access (device login; no API key, no API credits; unofficial) | Tested | [Quick setup, Option C](#3-add-an-api-key) |
| **DeepSeek** | Cost-effective reasoning models | Tested | [platform.deepseek.com](https://platform.deepseek.com/) |
| **Gemini** | Google's Gemini models | Tested | [aistudio.google.com](https://aistudio.google.com/) |
| **Ollama** | Local models (no API key needed) | Tested | [ollama.ai](https://ollama.ai/) |
| **Groq** | Extremely fast inference; free tier | Tested | [console.groq.com](https://console.groq.com/) |
| **Fireworks** | Fast inference for open models; book tools supported | Tested | [fireworks.ai](https://fireworks.ai/) |
| **SambaNova** | Fast inference; the advertised free tier now needs a card | Docs-based* | [cloud.sambanova.ai](https://cloud.sambanova.ai/) |
| **Together** | 200+ open source models | Docs-based* | [api.together.xyz](https://api.together.xyz/) |
| **Mistral** | European provider, coding models; free tier | Tested | [console.mistral.ai](https://console.mistral.ai/) |
| **xAI** | Grok models, up to 1M context | Tested | [console.x.ai](https://console.x.ai/) |
| **OpenRouter** | Meta-provider, 500+ models | Tested | [openrouter.ai](https://openrouter.ai/) |
| **Amazon Bedrock** | AWS-hosted models through the Converse API; a Bedrock API key and a region setting; no streaming yet | Docs-based* | [console.aws.amazon.com/bedrock](https://console.aws.amazon.com/bedrock/) |
| **Requesty** | OpenAI-compatible model router | Docs-based* | [requesty.ai](https://requesty.ai/) |
| **Cohere** | Command models | Tested | [dashboard.cohere.com](https://dashboard.cohere.com/) |
| **Qwen** | Alibaba's Qwen models | Tested | [modelstudio.console.alibabacloud.com](https://modelstudio.console.alibabacloud.com/) (international; the CN console differs) |
| **Kimi** | Moonshot models | Tested | [platform.kimi.ai](https://platform.kimi.ai/) (international; platform.moonshot.cn for the China region setting) |
| **Doubao** | ByteDance Volcano Engine | Docs-based* | [console.volcengine.com](https://console.volcengine.com/) |
| **Z.AI** | GLM models, free tier available | Tested | [z.ai](https://z.ai/) |
| **Perplexity** | Sonar plus other companies' models, each answering with Perplexity's web search and citations | Tested | [perplexity.ai](https://www.perplexity.ai/settings/api) |
| **NVIDIA** | Nemotron family and hosted open models; generous free tier, no card; no web search | Tested | [build.nvidia.com](https://build.nvidia.com/) |
| **Cerebras** | Very fast open-model inference | Docs-based* | [cloud.cerebras.ai](https://cloud.cerebras.ai/) |
| **MiniMax** | MiniMax M-series models | Docs-based* | [platform.minimax.io](https://platform.minimax.io/) |
| **DeepInfra** | Many open models, low prices | Docs-based* | [deepinfra.com](https://deepinfra.com/) |
| **Novita AI** | Open-model marketplace | Docs-based* | [novita.ai](https://novita.ai/) |
| **Hyperbolic** | Open-model host | Docs-based* | [app.hyperbolic.xyz](https://app.hyperbolic.xyz/) |
| **Nebius AI Studio** | Open-model host | Docs-based* | [studio.nebius.com](https://studio.nebius.com/) |
| **Chutes** | Decentralized GPU marketplace | Docs-based* | [chutes.ai](https://chutes.ai/) |
| **Featherless** | Huge open-model catalog | Docs-based* | [featherless.ai](https://featherless.ai/) |
| **Vercel AI Gateway** | 200+ models behind one key | Docs-based* | [vercel.com](https://vercel.com/) |
| **OpenCode Zen** | Pay-as-you-go credit; open-weight models (GLM, DeepSeek, Kimi, MiniMax, Qwen) | Tested | [opencode.ai/auth](https://opencode.ai/auth) |
| **OpenCode Go** | The monthly subscription with its own model list; the same account key, entered under `opencode_go` | Tested | [opencode.ai/docs/go](https://opencode.ai/docs/go/) |
| **A2Agent** | Gateway to Chinese models (DeepSeek, GLM, Kimi, Qwen, MiniMax) behind one key | Tested | [a2agent.me](https://a2agent.me/) |

\* *Tested* providers are covered by the maintainer's own keys and probe tooling. *Docs-based* providers are implemented from their documentation and user reports; they should work the same way, but regressions can go unnoticed until someone reports them. You can promote one: test it and open an issue with what worked and what did not, or donate a limited-spend, revocable key to the contact email on the maintainer's GitHub profile.

**Free:** Groq, Gemini, Ollama, Mistral, OpenRouter's `:free` models, Z.AI, NVIDIA, a free ChatGPT account through OpenAI Subscription, and the API credits of Claude Max and Team plans. **Web search** on Anthropic, Gemini, OpenAI, OpenAI Subscription, xAI, Perplexity, OpenRouter, Z.AI and Qwen; **AI Book Tools** on Gemini, Anthropic, Amazon Bedrock (the probed models), OpenAI (API or Subscription), OpenRouter, DeepSeek, Mistral, Groq, xAI, Fireworks, Qwen, Kimi, OpenCode Zen, OpenCode Go, A2Agent and Ollama; images on OpenAI, xAI, Gemini and OpenRouter.

Custom providers and local presets (LM Studio, llama.cpp, Jan, vLLM, KoboldCpp, LocalAI), custom models, favorites, default models and tiers, quirks: [Providers and Models](https://github.com/zeeyado/koassistant.koplugin/wiki/Providers-and-Models).

## Updating

When a new version is out, KOAssistant shows its release notes with an **Update Now** button: one tap verifies the release, keeps your own files and settings, and asks you to restart. A git clone updates with `git pull`.

Manual updates, what is safe during an update, update checking, backups, restore and reset: [Backups and Updates](https://github.com/zeeyado/koassistant.koplugin/wiki/Backups-and-Updates).

## Getting help

**Quick checks when something does not work:**
- **An action ignores your highlights, notes or the book's text.** Each kind is asked for the first time an action wants it, and "Not for this book" sets the book's value to Never: check Book Settings → Privacy & Data for the book and **Settings → Privacy & Data** for all books.
- **"No API key found".** Add the key for the selected provider in **Settings → API Keys & Auth** or in `apikeys.lua`; a sample placeholder such as "your-key-here" counts as no key.
- **No response or a timeout.** Check the connection and read the error: it names the provider and model and adds one tip.
- **Menu icons show as boxes.** KOReader ships no emoji font; **Settings → Display Settings → Emoji → Emoji Font** installs the bundled one (a restart follows), and the rows below it turn the icons off.
- **Highlight menu or bypass actions do not appear.** In a book: KOReader's gear menu → Taps and gestures → Long-press on text; "Dictionary on single word selection" must be on for dictionary bypass, and the highlight action must be "Ask with popup dialog".

The whole list, with fonts for Arabic and other scripts, settings reset and debug mode: [Troubleshooting](https://github.com/zeeyado/koassistant.koplugin/wiki/Troubleshooting).

**Where to ask:** [Discussions](https://github.com/zeeyado/koassistant.koplugin/discussions) for questions, prompt ideas, setups and workflows; [Issues](https://github.com/zeeyado/koassistant.koplugin/issues) for bugs with steps to reproduce and for specific feature requests.

## Documentation

The [Wiki](https://github.com/zeeyado/koassistant.koplugin/wiki) holds the reference, one page per feature:

- **Getting started:** [Getting Started](https://github.com/zeeyado/koassistant.koplugin/wiki/Getting-Started) · [Setup, Gestures and Panels](https://github.com/zeeyado/koassistant.koplugin/wiki/Setup-Gestures-and-Panels) · [Privacy and Data](https://github.com/zeeyado/koassistant.koplugin/wiki/Privacy-and-Data)
- **Using KOAssistant:** [Contexts and Chat](https://github.com/zeeyado/koassistant.koplugin/wiki/Contexts-and-Chat) · [Chat Windows](https://github.com/zeeyado/koassistant.koplugin/wiki/Chat-Windows) · [Using X-Ray](https://github.com/zeeyado/koassistant.koplugin/wiki/Using-X-Ray) · [Book Groups and Series](https://github.com/zeeyado/koassistant.koplugin/wiki/Book-Groups-and-Series) · [Reading Analysis Actions](https://github.com/zeeyado/koassistant.koplugin/wiki/Reading-Analysis-Actions) · [Research Mode](https://github.com/zeeyado/koassistant.koplugin/wiki/Research-Mode) · [Spoiler Protection](https://github.com/zeeyado/koassistant.koplugin/wiki/Spoiler-Protection) · [Dictionary and Translation](https://github.com/zeeyado/koassistant.koplugin/wiki/Dictionary-and-Translation) · [Book Settings and Book Hub](https://github.com/zeeyado/koassistant.koplugin/wiki/Book-Settings-and-Book-Hub) · [Conversations, Notebooks and Export](https://github.com/zeeyado/koassistant.koplugin/wiki/Conversations-Notebooks-and-Export) · [Artifacts and Caching](https://github.com/zeeyado/koassistant.koplugin/wiki/Artifacts-and-Caching) · [Image Generation](https://github.com/zeeyado/koassistant.koplugin/wiki/Image-Generation)
- **Customization:** [Actions and Menus](https://github.com/zeeyado/koassistant.koplugin/wiki/Actions-and-Menus) · [Template Variables](https://github.com/zeeyado/koassistant.koplugin/wiki/Template-Variables) · [Prompts, Behaviors and Domains](https://github.com/zeeyado/koassistant.koplugin/wiki/Prompts-Behaviors-and-Domains) · [Languages](https://github.com/zeeyado/koassistant.koplugin/wiki/Languages)
- **Providers and models:** [Providers and Models](https://github.com/zeeyado/koassistant.koplugin/wiki/Providers-and-Models) · [Reasoning, Web Search and Book Tools](https://github.com/zeeyado/koassistant.koplugin/wiki/Reasoning-Web-Search-and-Book-Tools)
- **Reference and support:** [Settings Reference](https://github.com/zeeyado/koassistant.koplugin/wiki/Settings-Reference) · [Backups and Updates](https://github.com/zeeyado/koassistant.koplugin/wiki/Backups-and-Updates) · [Advanced Configuration and Development](https://github.com/zeeyado/koassistant.koplugin/wiki/Advanced-Configuration-and-Development) · [Troubleshooting](https://github.com/zeeyado/koassistant.koplugin/wiki/Troubleshooting) · [Contributing](https://github.com/zeeyado/koassistant.koplugin/wiki/Contributing)

## Contributing

Bug reports and feature ideas in [Issues](https://github.com/zeeyado/koassistant.koplugin/issues), questions and setups in [Discussions](https://github.com/zeeyado/koassistant.koplugin/discussions), pull requests on GitHub (the wiki is the repository's `wiki/` folder), translations on [Weblate](https://hosted.weblate.org/engage/koassistant/) (26 languages, AI-filled and waiting for human review). The test suite lives in `tests/` (clone the repository; `lua tests/run_tests.lua --unit` runs it without API calls). More: [Contributing](https://github.com/zeeyado/koassistant.koplugin/wiki/Contributing).

## Credits

This project was originally forked from [ASKGPT by Drew Baumann](https://github.com/drewbaumann/askgpt), renamed to Assistant, and expanded with multi-provider support, custom actions, chat history and more. It was renamed to KOAssistant after a naming conflict with [a fork of this project](https://github.com/omer-faruq/assistant.koplugin); some internal references may still show the old name.

Thanks to Drew Baumann for the original ASKGPT plugin, to the KOReader community for an excellent plugin framework, and to all contributors and testers.

This plugin is developed with AI assistance using (mostly) [Claude Code](https://claude.ai) (Anthropic). The well-documented KOReader plugin framework and codebase made it possible for AI tools to understand the existing patterns and contribute to development and documentation.

**License:** GNU General Public License v3.0, see [LICENSE](LICENSE).
