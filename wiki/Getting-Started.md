# Getting Started

Get KOAssistant working in about five minutes: install the plugin, restart KOReader, add an API key and run your first action. After that, [Setup, Gestures and Panels](Setup-Gestures-and-Panels) covers the next ten minutes.

## 1. Install the Plugin

Download `koassistant.koplugin.zip` from the latest [release](https://github.com/zeeyado/koassistant.koplugin/releases/latest) (under Assets). To run the latest code from the main branch instead, use Code → Download ZIP on the repository page, or clone it:

```bash
git clone https://github.com/zeeyado/koassistant.koplugin
```

Extract or copy the `koassistant.koplugin` folder into KOReader's plugins folder:

| Platform | Plugins folder |
|----------|----------------|
| Kobo | `/mnt/onboard/.adds/koreader/plugins/` |
| Kindle | `/mnt/us/koreader/plugins/` (the `koreader` folder at the root of the USB drive) |
| Android | `/sdcard/koreader/plugins/` |
| macOS | `~/Library/Application Support/koreader/plugins/` |
| Linux | `~/.config/koreader/plugins/` |

The folder must be named exactly `koassistant.koplugin`, with no nested folder inside it: remove `-main` or a similar suffix if you downloaded the ZIP from the main branch. The result looks like this:

```
koreader
└── plugins
    └── koassistant.koplugin
        ├── _meta.lua
        ├── main.lua
        └── ...
```

> **Tip:** when you install from the main branch by hand, you can delete folders such as `screenshots/`, `tests/` and `wiki/` to save space. Release ZIPs leave them out.

> **This is the only time you install by hand.** After this, KOAssistant updates itself: when a new version is available, you see its release notes with an **Update Now** button. One tap handles everything (download, install, keeping your settings). See [Backups and Updates](Backups-and-Updates).

**Alternative:** install KOAssistant from inside KOReader with the [App Store plugin](https://github.com/omer-faruq/appstore.koplugin), which browses, installs and updates KOReader plugins without a computer. It can install from releases or from the latest main branch code.

## 2. Restart KOReader

KOReader loads plugins when it starts, so restart it once. KOAssistant's menu is then the first row of KOReader's Tools menu: **Tools → KOAssistant**. In this wiki, "Settings" means this menu, so **Settings → API Keys & Auth** is the API Keys & Auth row of Tools → KOAssistant.

The first time you open KOAssistant (its menu, or one of its actions), the [Setup Wizard](Setup-Gestures-and-Panels#setup-wizard) walks you through a provider, privacy, language, the emoji icons, the (KOA) mark on its buttons and the panels' gestures; after an update it checks only what changed.

## 3. Get an API Key

You need an API key from at least one AI provider, or a ChatGPT account ([Option C](#option-c-openai-subscription-device-login)). Some places to start:

| Provider | Cost | Where to get a key |
|----------|------|--------------------|
| Gemini | Free tier (Flash models) | [aistudio.google.com](https://aistudio.google.com/) |
| Groq | Free tier | [console.groq.com](https://console.groq.com/) |
| Ollama | Free, runs on your own computer | [ollama.com](https://ollama.com/) |
| Anthropic | Pay per use | [console.anthropic.com](https://console.anthropic.com/) |
| OpenAI | Pay per use | [platform.openai.com](https://platform.openai.com/) |
| OpenAI Subscription | Your ChatGPT plan (free accounts included), no key | [Option C](#option-c-openai-subscription-device-login) below |

KOAssistant has 33 built-in providers; [Providers and Models](Providers-and-Models) lists them all with links to get keys.

**Free options in brief:** Groq and Gemini need no card, Ollama needs no key at all, and a free ChatGPT account works through OpenAI Subscription (device login, experimental). Mistral, OpenRouter, Z.AI and NVIDIA have free allowances too; free tiers change often, and [Providers and Models](Providers-and-Models) has the current limits.

**Already paying?** A ChatGPT plan works here instead of API credits ([Option C](#option-c-openai-subscription-device-login)). A Claude Max or Team plan includes monthly Claude API credits that work here; [Providers and Models](Providers-and-Models) says how to claim them.

## 4. Add Your Key

There are three ways. Use whichever suits you.

### Option A: In Settings

1. Go to **Settings → API Keys & Auth**.
2. Tap a provider and enter your API key.
3. Saved keys are shown masked: only their first and last few characters.

Your first key also selects its provider, so it is ready to use.

### Option B: In apikeys.lua

In the plugin folder, make a copy of `apikeys.lua.sample` named `apikeys.lua`:

```bash
cp apikeys.lua.sample apikeys.lua
```

Edit `apikeys.lua` and add your API key(s):

```lua
return {
    anthropic = "your-key-here",  -- console.anthropic.com
    openai = "",                  -- platform.openai.com
    -- See apikeys.lua.sample for all 32 providers
}
```

Restart KOReader after editing the file: KOAssistant reads it once per session. Updates keep the file. Anthropic is the default provider, so for a key from another provider, choose that provider in the **Model** row of the KOAssistant menu (or the Provider tile of [Quick Settings](Setup-Gestures-and-Panels#quick-settings)).

> **Note:** keys entered in Settings take priority over keys in the file. **Settings → API Keys & Auth** shows `[set]` for a key entered there and `(file)` for one from `apikeys.lua`. Provider pickers only list providers that have a key configured (plus local and keyless providers such as Ollama), so the menus stay short. You can also keep several keys for one provider (for example a free and a paid one) and switch between them; see [Providers and Models](Providers-and-Models).

### Option C: OpenAI Subscription (Device Login)

Works with any ChatGPT account that has Codex access, **including free accounts** (verified August 2026; free-account limits are undocumented, expect them to be modest). Device code access must be enabled for your ChatGPT account: the verification page at `https://auth.openai.com/codex/device` explains how to enable it if it isn't yet.

1. Go to **Settings → API Keys & Auth**, tap **OpenAI Subscription**, then tap **Connect**.
2. KOAssistant shows an OpenAI verification URL and a one-time code. It never tries to open a browser on the e-reader. Open the URL on another device and enter the code (it expires in 15 minutes).
3. Return to KOReader and tap **Check authorization**.

This is separate from the OpenAI API-key provider and does not use API credits.

KOAssistant stores the login's access and refresh tokens in its settings and never displays or logs them. They are left out of ordinary backups: switching the **API Keys** option of **Settings → Backup & Reset → Create Backup** to Include includes them. Resetting API keys (**Settings → Backup & Reset → Reset Settings... → Custom reset...**, then **API keys**) disconnects the subscription, and so does **Disconnect** on the OpenAI Subscription screen. Subscription access depends on OpenAI's Codex backend and on what your ChatGPT account includes, so the available models and how the service behaves may change.

## 5. Try It Out

Open a book, select a passage (long-press and drag), and in the highlight menu tap a KOAssistant action such as **Explain (KOA)** or **Translate (KOA)**. "(KOA)" marks KOAssistant's buttons next to KOReader's own.

That's it: you're up and running. To check a key without opening a book, **Settings → Advanced → Test Connection** sends a short test message to the provider in use.

## 6. Choose What You Share (Optional)

Your highlights, notes, notebook, the book's text, your library scan and your reading habits are not sent unasked: the first time an action wants one of them, KOAssistant shows what it is about to send and to whom, and you answer **Allow once** or **Allow for this book**. **Settings → Privacy & Data** holds one value per kind (Ask, Allow or Never); [Privacy and Data](Privacy-and-Data) explains every option.

> **Quick option:** in **Settings → Privacy & Data → Preset**, **Allow everything** sends every kind without a question, book text included (X-Ray needs it, for one; it raises token costs). **Block everything** is the other end.

## What Next

- **Set up the panels and gestures:** [Setup, Gestures and Panels](Setup-Gestures-and-Panels) has the Setup Wizard, a checklist for your first ten minutes, the Quick Settings and Quick Actions panels, and gestures.
- **Learn the ways to ask:** [Contexts and Chat](Contexts-and-Chat) covers highlights, a whole book, your library, and general chats.
- **Explore X-Ray:** [Using X-Ray](Using-X-Ray) builds a browsable guide to your book.
- **Prefer a minimal footprint?** KOAssistant is designed to stay out of your way. Its main menu is one row in KOReader's Tools menu, and every default integration (file browser buttons, highlight menu items, the dictionary popup, gesture actions) can be turned off in **Settings → Menus & Buttons**; see [Actions and Menus](Actions-and-Menus). Use only what you need.
- **Look something up:** [Settings Reference](Settings-Reference) lists every row of the menu.

## Related

- [Setup, Gestures and Panels](Setup-Gestures-and-Panels): the wizard, the two panels, gestures and bypass modes.
- [Privacy and Data](Privacy-and-Data): what is sent to the AI and how to control it.
- [Providers and Models](Providers-and-Models): every provider, free tiers, subscriptions and multiple keys.
- [Backups and Updates](Backups-and-Updates): how KOAssistant updates itself and keeps your settings.
- [Troubleshooting](Troubleshooting): API key errors, missing emoji and other first-run problems.
