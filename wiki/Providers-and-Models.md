# Providers and Models

KOAssistant works with 33 built-in AI providers and with any OpenAI-compatible service you add yourself. This page lists the providers and what each can do, what is free, how to use a subscription instead of API credits, how API keys work, and how to choose, add and rank models.

## Supported providers

KOAssistant has **33 built-in providers**: a **curated set** the maintainer tests with real keys and automated probes, and a **community set** (marked `*` in the plugin and *Docs-based* below) implemented from provider documentation. You can add any number of custom OpenAI-compatible providers yourself ([Custom providers](#custom-providers)). OpenAI is listed twice: once for API keys, once for the ChatGPT-subscription login. The name in brackets is the provider's id, which `apikeys.lua` (for its key) and `custom_models.lua` use. Please test and give feedback: fixes are quickly implemented.

| Provider | Description | Status | Get API key |
|----------|-------------|--------|-------------|
| **Anthropic** (`anthropic`) | Claude models (primary focus). Claude Max and Team plans include monthly API credits ([how](#claude-max-and-team-api-credits)) | Tested | [console.anthropic.com](https://console.anthropic.com/) |
| **OpenAI** (`openai`) | GPT models | Tested | [platform.openai.com](https://platform.openai.com/) |
| **OpenAI Subscription** (`openai_codex`) | GPT models through your ChatGPT plan's Codex access (device login; no API key, no API credits; unofficial). [More](#openai-subscription) | Tested | [Getting Started, Option C](Getting-Started#option-c-openai-subscription-device-login) |
| **DeepSeek** (`deepseek`) | Cost-effective reasoning models | Tested | [platform.deepseek.com](https://platform.deepseek.com/) |
| **Gemini** (`gemini`) | Google's Gemini models | Tested | [aistudio.google.com](https://aistudio.google.com/) |
| **Ollama** (`ollama`) | Local models (no API key needed) | Tested | [ollama.ai](https://ollama.ai/) |
| **Groq** (`groq`) | Extremely fast inference; free tier | Tested | [console.groq.com](https://console.groq.com/) |
| **Fireworks** (`fireworks`) | Fast inference for open models; book tools supported | Tested | [fireworks.ai](https://fireworks.ai/) |
| **SambaNova** (`sambanova`) | Fast inference; the advertised free tier (3 models, 20 requests a day) now needs a card ([Free tiers](#free-tiers)) | Docs-based* | [cloud.sambanova.ai](https://cloud.sambanova.ai/) |
| **Together** (`together`) | 200+ open source models | Docs-based* | [api.together.xyz](https://api.together.xyz/) |
| **Mistral** (`mistral`) | European provider, coding models; free tier | Tested | [console.mistral.ai](https://console.mistral.ai/) |
| **xAI** (`xai`) | Grok models, up to 1M context | Tested | [console.x.ai](https://console.x.ai/) |
| **OpenRouter** (`openrouter`) | Meta-provider, 500+ models ([Meta-providers](#meta-providers)) | Tested | [openrouter.ai](https://openrouter.ai/) |
| **Requesty** (`requesty`) | OpenAI-compatible model router | Docs-based* | [requesty.ai](https://requesty.ai/) |
| **Cohere** (`cohere`) | Command models | Tested | [dashboard.cohere.com](https://dashboard.cohere.com/) |
| **Qwen** (`qwen`) | Alibaba's Qwen models | Tested | [modelstudio.console.alibabacloud.com](https://modelstudio.console.alibabacloud.com/) (international; the China console differs) |
| **Kimi** (`kimi`) | Moonshot models | Tested | [platform.kimi.ai](https://platform.kimi.ai/) (international; platform.moonshot.cn for the China region setting) |
| **Doubao** (`doubao`) | ByteDance Volcano Engine | Docs-based* | [console.volcengine.com](https://console.volcengine.com/) |
| **Z.AI** (`zai`) | GLM models, free tier available | Tested | [z.ai](https://z.ai/) |
| **Perplexity** (`perplexity`) | Sonar plus other companies' models (GPT, Claude, Gemini, Grok), each answering with Perplexity's web search and citations | Tested | [perplexity.ai](https://www.perplexity.ai/settings/api) |
| **NVIDIA** (`nvidia`) | Nemotron family and hosted open models; generous free tier, no card. No book tools on the listed models since NVIDIA retired the one that had them (2026-09-01); **no web search** (NVIDIA's API provides none) | Tested | [build.nvidia.com](https://build.nvidia.com/) |
| **Cerebras** (`cerebras`) | Very fast open-model inference (hosts gpt-oss) | Docs-based* | [cloud.cerebras.ai](https://cloud.cerebras.ai/) |
| **MiniMax** (`minimax`) | MiniMax M-series models | Docs-based* | [platform.minimax.io](https://platform.minimax.io/) |
| **DeepInfra** (`deepinfra`) | Many open models, low prices | Docs-based* | [deepinfra.com](https://deepinfra.com/) |
| **Novita AI** (`novita`) | Open-model marketplace | Docs-based* | [novita.ai](https://novita.ai/) |
| **Hyperbolic** (`hyperbolic`) | Open-model host | Docs-based* | [app.hyperbolic.xyz](https://app.hyperbolic.xyz/) |
| **Nebius AI Studio** (`nebius`) | Open-model host | Docs-based* | [studio.nebius.com](https://studio.nebius.com/) |
| **Chutes** (`chutes`) | Decentralized GPU marketplace | Docs-based* | [chutes.ai](https://chutes.ai/) |
| **Featherless** (`featherless`) | Huge open-model catalog | Docs-based* | [featherless.ai](https://featherless.ai/) |
| **Vercel AI Gateway** (`vercel`) | 200+ models behind one key | Docs-based* | [vercel.com](https://vercel.com/) |
| **Cheaper Inference** (`cheaperinference`) | OpenAI-compatible gateway; models from several labs behind one key | Docs-based* | [cheaperinference.com](https://cheaperinference.com/) |
| **OpenCode Zen** (`opencode`) | Pay-as-you-go credit; open-weight models (GLM, DeepSeek, Kimi, MiniMax, Qwen). GPT, Claude and Gemini through OpenCode are not supported yet (they use other endpoints). Sends the conversation header OpenCode requires | Tested | [opencode.ai/auth](https://opencode.ai/auth) |
| **OpenCode Go** (`opencode_go`) | The monthly subscription with its own model list. Same account key as Zen, entered separately under `opencode_go` ([more](#opencode-go)) | Tested | [opencode.ai/docs/go](https://opencode.ai/docs/go/) |
| **A2Agent** (`a2agent`) | Paid gateway to Chinese models (DeepSeek, GLM, Kimi, Qwen, MiniMax) behind one key | Tested | [a2agent.me](https://a2agent.me/) |

## Tested and docs-based providers

*Tested* providers are covered by the maintainer's own API keys and automated probe and test tooling. *Docs-based* providers are implemented from their official documentation and user reports. They should work the same way, but the maintainer holds no key for them, so regressions can go unnoticed until someone reports them (fixes are quick once reported).

In the plugin, a community provider carries a `*` after its name in the provider list, and the row "\* = community set" at the top of the list explains the mark when you tap it. The community hosts' built-in model lists are short seed lists: see [Fetching and testing models](#fetching-and-testing-models).

You can help promote a docs-based provider to tested:

- **Test and report:** try it and open an [issue](https://github.com/zeeyado/koassistant.koplugin/issues) with what worked and what didn't (a screenshot of any error message is gold).
- **Donate a test key:** send a limited-spend, revocable API key to the contact email on the maintainer's GitHub profile. It only needs a few cents of quota to join the automated probe battery, and you can revoke it at any time. Live probing is exactly what promotes a provider into the tested set.

## What each provider can do

- **Web search:** Anthropic, Gemini, OpenAI, OpenAI Subscription, xAI, Perplexity, OpenRouter, Z.AI and Qwen. Other providers ignore the setting and answer without searching. How each one searches, and the effort dial: [Reasoning, Web Search and Book Tools](Reasoning-Web-Search-and-Book-Tools).
- **AI Book Tools** (experimental: the AI searches and reads the open book for grounded, page-referenced answers): Gemini, Anthropic, OpenAI (API or Subscription), OpenRouter, DeepSeek, Mistral, Groq, xAI, Fireworks, Qwen, Kimi, OpenCode Zen, OpenCode Go, A2Agent and Ollama (models whose server reports tool support). The community hosts Cerebras, MiniMax, DeepInfra, Novita AI, Hyperbolic, Nebius AI Studio, Chutes, Featherless and Vercel AI Gateway, and custom providers, can use them for a model once **Test provider...** has recorded that it calls tools, or `custom_models.lua` grants it. A per-chat **Tools** chip turns them on; the setting behind it (off by default) decides whether the chip starts on, globally or per book. See [Reasoning, Web Search and Book Tools](Reasoning-Web-Search-and-Book-Tools).
- **Image generation:** OpenAI, xAI, Gemini and OpenRouter. See [Image Generation](Image-Generation).
- **Reasoning** depends on the model rather than the provider. The stance and the per-model settings are on [Reasoning, Web Search and Book Tools](Reasoning-Web-Search-and-Book-Tools); the models that cannot turn it off are listed under [Provider quirks](#provider-quirks).

## Free tiers

Several providers offer free tiers for testing or budget-conscious use. The details below were verified in mid-August 2026 unless a row gives another date. Free tiers change often, so treat the numbers as indicative and check the provider's own limits page for the current state.

| Provider | Free tier |
|----------|-----------|
| **Groq** | Nearly all models free, no card needed. Limits are per model: roughly 30 requests/min and 6-30K tokens/min (about 30 requests and 8,000 tokens a minute on the gpt-oss models), up to ~14K requests/day on small models, and shared across your whole account. Groq counts the answer budget a request asks for against the per-minute limit before running it; KOAssistant learns your plan's limit from Groq's replies and sizes its requests to fit (v0.22.0+; earlier versions were refused on the free plan), so expect short answers and roughly one request per minute on the 8K-token models. Also hosts OpenAI's open-weight `gpt-oss-120b` and `gpt-oss-20b` on the free tier |
| **OpenAI (ChatGPT account)** | The **OpenAI Subscription** provider works with a **free ChatGPT account** (verified August 2026): no API key, no card; sign in with a device code and chat on your account's quota. Experimental and unofficial, and the free-account limits are not documented, so expect them to be modest. Setup: [Getting Started, Option C](Getting-Started#option-c-openai-subscription-device-login); device code access must be enabled for your ChatGPT account (the verification page at `auth.openai.com/codex/device` explains how). Models served on a free account (checked October 2026): `gpt-5.6-terra` (the default), `gpt-6-luna` and `gpt-5.6-luna`. The Sol and Astra models need a paid plan (OpenAI lists `gpt-6-sol` and `gpt-6.1-sol` for Plus and up), and a free account's request for one, the plugin's flagship pick `gpt-6.1-sol` included, is refused with an error that says so |
| **Gemini** | Flash and Flash-Lite class models free (`gemini-3.8-flash` (the plugin default), `gemini-3.6-flash`, the flash-lite variants, and on older accounts the 2.5-flash family), no card needed. Per-model daily limits are LOW on the newest flashes (~20 requests/day observed on 3.x flash), with more room on 2.5 models. Pro models (removed from the free tier April 2026) and Gemini 4 Argon are paid-only. **The 2.5 family is unavailable on new Google accounts** (roughly mid-2026 onward): requests return "no longer available to new users", even with paid credits. **Web search (grounding) and AI Book Tools do not work on free keys with Gemini 3.x models**: those requests fail instantly with a "quota exceeded" 429 while plain requests work. Use a 2.5 model for them (older accounts only; add it with **Fetch models from provider...**) or turn them off (the error dialog offers a one-tap retry without web search); paid credits lift this limit (verified). Caution: enabling billing on the Google Cloud project removes the free tier for that project, so keep your free key on a project without billing. Going paid is its own maze: new billed projects use prepaid credits bought inside Google AI Studio (minimum $10; Google Cloud trial credits explicitly do NOT apply), and AI Studio access may require age verification in the EEA. If AI Studio cannot create the key itself, create the project in the Cloud Console first, then create the key in AI Studio against that project |
| **NVIDIA** | Joining the free NVIDIA Developer Program needs only an email (**no credit card, no identity check**) and grants ~1,000 inference credits (up to 5,000 on request). Hosts NVIDIA's own Nemotron 3 family plus `gpt-oss-20b`. NVIDIA retires hosted models on short notice: a batch including Llama 3.1 went end-of-life on 2026-08-26, and `gpt-oss-120b`, MiniMax M3 and Nemotron 3 Nano followed on 2026-09-01. Get a key at [build.nvidia.com](https://build.nvidia.com/): profile menu, then Settings, then API Keys (the key starts with `nvapi-`). Caveat: NVIDIA's public model catalog lists far more models than it actually serves, so KOAssistant ships a hand-verified list rather than the full catalog; prefer the listed models over ids fetched with **Fetch models from provider...** |
| **Ollama** | Completely free (runs locally on your hardware) |
| **Mistral** | Free tier ("free mode" / Experiment plan) covers **all** La Plateforme models, roughly 1B tokens/month; phone verification required, no card. The catch is a very low request rate (~2 requests/min: fine for chat, slow for multi-request builds). Mistral no longer publishes exact numbers; check Admin Console → Limits. (Separately, `mistral-small-latest` and `magistral-small-latest` are Apache 2.0 open-weight, so you can also self-host them via Ollama) |
| **OpenRouter** | `:free` model variants (rotating roster: DeepSeek, Llama, `gpt-oss` and more): 20 requests/min and 50 requests/day account-wide. A one-time $10 credit purchase permanently raises that to 1,000 requests/day |
| **Z.AI** | GLM-4.7-Flash free (genuinely free, not trial credits); 1 concurrent request, ~1,000 requests/day |
| **SambaNova** | The advertised free tier (3 models at 20 requests/day) no longer works card-free: new accounts get "a payment method is required" on every API call until a card is added (verified August 2026). Treat it as paid-with-trial rather than free |

> **Note:** some providers widely described as "free" online are actually time-limited trials. Cerebras, for example, offers $5 in credits that expire after 30 days, not a persistent free tier. When in doubt, check whether the allowance renews.

**Best for testing:** Groq (fast free inference, no card), Gemini (free Flash models, no card), Ollama (no API key needed).

Already paying for ChatGPT? Use your plan here instead of API credits. On Claude Max or Team? Your plan includes monthly API credits. Both are in the next section.

## Using a subscription instead of API credits

If you already pay for an AI subscription, you may be able to use it in KOAssistant instead of buying API credits.

### OpenAI Subscription

**Available now.** Sign in with a device code and chat on your ChatGPT account's quota instead of API billing. It works with paid plans **and free ChatGPT accounts** (verified August 2026), and needs no API key. Connect it in **Settings → API Keys & Auth**: tap **OpenAI Subscription**, then **Connect** ([Getting Started, Option C](Getting-Started#option-c-openai-subscription-device-login) has the steps). Device code access must be enabled for your ChatGPT account; the verification page at `auth.openai.com/codex/device` explains how.

This is an unofficial integration: KOAssistant identifies itself honestly, and it may stop working if OpenAI changes the Codex service. Free-account limits are not documented, so expect them to be modest.

- **Models.** The list holds `gpt-5.6-terra` (the default), `gpt-6.1-sol`, `gpt-6-astra`, `gpt-6-luna`, `gpt-6-sol` and `gpt-5.6-luna` (the GPT-6 models since v0.24.0). Which of them answer depends on your ChatGPT plan. Every plan, free accounts included, serves `gpt-5.6-terra` and the Luna models (checked October 2026). The Sol and Astra models need a paid plan (OpenAI lists `gpt-6-sol` and `gpt-6.1-sol` for Plus and up). On a free account a Sol or Astra request is refused, and the error says that your plan does not include the model and which models every plan serves.
- **Speed tiers.** Fast and fastest: `gpt-6-luna`, which every plan serves (the previous fastest pick, `gpt-5.4-mini`, was retired from the Codex backend on August 31, so that tier had been refused since). Standard: `gpt-5.6-terra`. Flagship: `gpt-6.1-sol`, which needs a paid plan. Frontier: `gpt-6-astra`, opt-in as everywhere, also paid.
- **Retired models.** The GPT-5.4 models (gone from Codex on 2026-08-31) and `gpt-5.5` (OpenAI's retirement date for it on Codex was October 14) left the list. A saved pick of one of them moves to a served model with a notice: `gpt-5.4` and `gpt-5.5` to `gpt-5.6-terra`, `gpt-5.4-mini` and `gpt-5.4-nano` to `gpt-6-luna`.
- The subscription has no model list to fetch and no **Test provider...**; check it with **Settings → Advanced → Test Connection**.
- Consumer data-handling policies differ from the API platform's: see [Privacy and Data](Privacy-and-Data).

### OpenCode Go

**Available now.** OpenCode's monthly subscription has its own model list and is a built-in provider (see the [table](#supported-providers)). Enter your OpenCode account key under `opencode_go`: the same key as OpenCode Zen, entered separately. GPT, Claude and Gemini through OpenCode are not supported yet. A few models in its list answer only after you opt in to them in the OpenCode console: `deepseek-v4-pro` (hosted in China) and the two `muse-spark` models (data-collection consent); `deepseek-v4.1-flash`, new in Go's catalog in place of `deepseek-v4-flash`, is listed unverified.

### Claude Max and Team API credits

**Available now.** Claude Max and Team plans include monthly API credits: Max 5x gets $100 a month, Max 20x $200, and Team plans $20 per Standard seat and $100 per Premium seat (pooled, at most $500 a month). **Pro and Free plans are not included.** This is the regular Claude API with your own key, so KOAssistant uses it like any Anthropic key:

1. On claude.ai in a web browser (not the app), open your **Settings**, then **Billing** (Team: **Organization settings**, then **Billing**, as Owner or Primary Owner), and choose **Link organization** under **API credits**. Pick an existing Claude Console organization or create one; sign in to the Console with the same email.
2. In that organization on [console.anthropic.com](https://console.anthropic.com/), create an API key and enter it as your Anthropic key ([Getting Started](Getting-Started)). No card is needed.

The credits arrive each billing month, are spent before any credits you bought, and expire at the end of the month (no rollover). When they run out, requests stop until the next month unless the organization has bought credits or turned on auto-reload. New subscribers can claim after seven days on the plan. Details: [Anthropic's help article](https://support.claude.com/en/articles/17154008-monthly-api-credits-for-max-and-team-plans).

### Not planned

- **Not planned: signing in with a Claude (Anthropic), Google or GitHub Copilot subscription.** These providers ban third-party subscription use and enforce it server-side, so supporting them would require actively impersonating their official clients. That is out of scope permanently (barring a policy change on their side). Claude Max and Team plans can use their monthly API credits instead (above).

## Choosing a provider and model

**Settings → Model** is one row for both: it reads "Model: claude-sonnet-5-5 (Anthropic)", or whatever you use. Tap it for the provider and model menu (33 built-in providers plus your custom ones). The Provider and Model buttons of the Quick Settings panel open shorter versions of the same lists ([Setup, Gestures and Panels](Setup-Gestures-and-Panels)).

### The provider list

- Providers are listed alphabetically, each with its own model menu. Entering a provider switches nothing: the provider and model change together when you pick a model.
- Once you have at least one API key (or the OpenAI Subscription connected), the list shows only the providers you can use (those with a key, Ollama, the OpenAI Subscription once connected, and custom providers marked as not needing a key), plus your current provider, marked "(no key)" if it has none. The rest sit behind **Show all providers (N more)…**. Add keys in **Settings → API Keys & Auth**.
- Picking a model of a provider that has no key selects it anyway and opens its key dialog (the OpenAI Subscription opens its Connect dialog). Cancel leaves the key for later.
- `*` marks the community set, and ★ marks a custom provider (hold it for its options: [Managing custom providers](#managing-custom-providers)).
- Below the providers: **Quick setup: Local provider...**, **Add custom provider...** and, once you have custom providers, **Manage custom providers (N)...** ([Custom providers](#custom-providers)).

### A provider's model menu

- The first row is a reminder: "Hold to manage. ★ = custom, ♥ = favorite". Your custom models come first (★), then the built-in list in its order. ♥ marks a [favorite](#favorite-models); "· fast", "· ultrafast" and the other tier names mark the models the [speed tiers](#model-speed-tiers) use, your own tier picks included; "(default)", "(your default)" or "(system default)" mark the [defaults](#default-models). The menu opens on the page holding the model in use.
- **Tap a model** to use it. **Hold a model** for **♥ Add to favorites** (or **Remove from favorites**), **Set as default for** the provider, **Clear custom default** on your default, and **Remove custom model** on a model you added.
- Below the models:
  - **API key...** (**API keys (N)...** when you have several): enter a key, or open the key manager ([API keys](#api-keys)). The OpenAI Subscription has **Connect / manage subscription...** instead; Ollama has its server and context rows ([Ollama](#ollama)).
  - For Z.AI, Gemini, Qwen and Kimi: the provider's own settings (region, search engine, content filter), the same as [Provider settings](#provider-settings).
  - **Add custom model...** and **Manage custom models (N)...** ([Custom models](#custom-models)).
  - **Fetch models from provider...** (Ollama: **Refresh installed models**) and **Test provider...** ([Fetching and testing models](#fetching-and-testing-models)).
  - **Model tiers...** ([Model speed tiers](#model-speed-tiers)).
  - Custom providers also have **Edit provider...**.

### Ollama

- The model menu lists the models installed on the active server, not a built-in list: tap **Refresh installed models** with the server running to fetch them (switching servers fetches them too). A model you added by hand or had selected that the server does not have is marked "(not installed)". If the default `llama4` is not installed, the first installed model is the default.
- **Server: …** manages several servers: "This device (localhost:11434)" plus any you add with **Add server...** (an address such as `192.168.1.20:11434`, and an optional name). The machine must serve Ollama on the network, not just on localhost; the port is usually 11434. Tap a server to switch to it: its installed models are fetched, and the model you last used there comes back. Hold a saved server to rename or remove it.
- **Context window: …** decides how big a window KOAssistant asks Ollama for. The default, **Server decides**, sends no size, so your Modelfile or `OLLAMA_CONTEXT_LENGTH` stays in charge (Ollama's own default is 4096 tokens). **Fit to request, max 8K** up to **Fit to request, max 128K** size the window to each request, never above the cap you pick; Ollama reserves memory for whatever it is given, so a large window on a large model can push it onto the CPU or stop it loading. KOAssistant checks the model's effective window before sending an oversized prompt and warns rather than letting Ollama silently cut the text, and it reports a request that comes back cut.
- Picking a model reads its capabilities from the server (tool support for AI Book Tools).

## API keys

**Settings → API Keys & Auth** lists every provider (custom ones with ★) with a status: `[set]` for a key entered in the app, `(file)` for a key from `apikeys.lua`, `[N keys]` when several are configured, `[connected]` for the OpenAI Subscription, and `(not required)` for a custom provider that needs no key.

- You can enter keys right there, with no file editing ([Getting Started](Getting-Started) also shows the `apikeys.lua` route). Keys entered in the app take priority over keys in the file.
- Tap a provider to enter its first key. Once a key exists, tapping opens the key manager instead. Each provider's model menu has the same door (**API key...**).
- The key dialog shows the saved key masked (its first 3 and last 4 characters) and offers **Save**, **Clear** and **Cancel**. A pasted key is cleaned: spaces and line breaks anywhere in it, and invisible characters, are removed, and the confirmation says how many. Placeholders left from the sample file (such as `YOUR_GEMINI_API_KEY`) are ignored.
- Your first key also selects its provider.
- **OpenAI Subscription** is managed here too, but opens a Connect / Disconnect dialog instead of key entry (device login with your ChatGPT plan: [OpenAI Subscription](#openai-subscription)).

### Multiple keys per provider

You can store more than one key for the same provider (a free Gemini key and a paid one, or a personal key and a spending-capped one) and switch between them without editing files:

- The key manager ("Gemini API keys (tap to use, hold to manage)") lists every key you have for that provider, masked (`AIz...x3Fq`), each labeled with where it came from (added in app, or apikeys.lua); ● marks the one in use.
- **Tap a key to use it.** The switch applies from the next request, everywhere (chat, provider tests, image generation).
- **Hold a key** to rename or delete it. Keys from `apikeys.lua` are changed by editing that file instead.
- **Add API key...** adds another key. Give keys names like "free" or "paid" so the list stays readable.
- The manager is also reachable from the provider's own model menu (the **API keys (N)...** row).
- In `apikeys.lua`, several keys are written as a list of named entries:

```lua
gemini = {
    { key = "KEY1", alias = "free" },
    { key = "KEY2", alias = "paid" },
},
```

Until you pick one, the first key is used (keys added in the app first, then the file's). If the key in use is deleted, the first key is used again.

## Custom providers

You can add your own OpenAI-compatible providers for local servers or cloud services not in the built-in list.

### Local servers

1. Go to **Settings → Model → Quick setup: Local provider...**.
2. Pick your engine. Presets are available for:

   | Engine | Default port | Notes |
   |--------|-------------|-------|
   | LM Studio | 1234 | Popular GUI, drag-and-drop models |
   | llama.cpp | 8080 | Fast CLI server (llama-server) |
   | Jan | 1337 | Desktop app, easy setup |
   | vLLM | 8000 | Production-grade serving |
   | KoboldCpp | 5001 | Optimized for creative writing |
   | LocalAI | 8080 | Drop-in OpenAI replacement |

3. The name and URL are pre-filled (`http://localhost:<port>/v1/chat/completions`): just change `localhost` to your server's IP if it runs on another machine.
4. Add a model name, tap **Add**, and you're ready.

The API key is turned off for the preset local providers. Running models locally keeps your data on your hardware: see [Privacy and Data](Privacy-and-Data).

### Other endpoints

1. Go to **Settings → Model → Add custom provider...**.
2. Fill in the details:
   - **Name:** the display name (e.g. "My Service").
   - **Base URL:** the full endpoint URL (e.g. `https://api.example.com/v1/chat/completions`).
   - **Default model:** optional; the model name to use by default.
3. Set its API key in **Settings → API Keys & Auth**. A new custom provider requires a key until you turn that off ([Managing custom providers](#managing-custom-providers)).

Custom providers are for services with their own model catalog that use the OpenAI-compatible format. A proxy or relay that speaks a built-in provider's own API (an Anthropic-compatible endpoint for Anthropic, say) is not a custom provider: point that built-in provider at it with `provider_settings` in `configuration.lua` ([Advanced Configuration and Development](Advanced-Configuration-and-Development)).

### Managing custom providers

- Custom providers appear with a ★ prefix in the provider list and in **API Keys & Auth**.
- Hold a custom provider (or tap **Edit provider...** in its model menu) for:
  - **Edit provider...**: its name, base URL and default model.
  - **Fetch models from provider...**: pulls the live `/models` list into a tap-to-add picker (a filter row narrows it; an "Add all" row appears for short lists).
  - **Test this provider...**: the capability check described under [Fetching and testing models](#fetching-and-testing-models).
  - **API key: Required** / **Not required**: tap to toggle whether the provider needs a key.
  - **Remove provider**: also removes its custom models and API key.
- **Manage custom providers (N)...** below the provider list edits each one, or removes them all with their custom models and keys.
- A custom provider's id is `custom_` followed by its name in lowercase, spaces turned into underscores and other punctuation dropped (LM Studio is `custom_lm_studio`); `custom_models.lua` uses it.
- Tips:
  - For Ollama's OpenAI-compatible mode, use `http://localhost:11434/v1/chat/completions`; Fetch models then lists your local models with no key.
  - For a custom provider with no default model, the first custom model you add becomes its default.

### Regional providers

Some providers can't ship as presets because signup or auth is restricted. **SiliconFlow**, **Baidu Qianfan** and **iFlytek** require mainland-China phone or business verification; **Tencent Hunyuan** has no clean international self-serve (use a rehost that carries it); **ModelScope**'s free endpoint has reliability issues; **Yandex** has no confirmed international signup; and **Sber GigaChat**'s rotating-token auth doesn't fit the custom-provider slot at all. If you *do* have working access to one of these through an OpenAI-compatible endpoint, the setup above works: please share a working config in an [issue](https://github.com/zeeyado/koassistant.koplugin/issues) so others benefit.

## Fetching and testing models

Most built-in providers ship a full model list. The community hosts (Cerebras, MiniMax, DeepInfra, Novita AI, Hyperbolic, Nebius AI Studio, Chutes, Featherless, Vercel AI Gateway and Cheaper Inference) ship only a tiny *seed* list ([Current default models](#current-default-models)). Two rows of a provider's model menu fill the gap; pick the provider in **Settings → Model** and add its key in **Settings → API Keys & Auth** first.

- **Fetch models from provider...** pulls the provider's live model list into a picker. Tap a model to add it to your custom models (✓ marks the ones you already have). **Filter models...** narrows a long list (the picker shows the first 30), and **Add all (N)** appears when 20 or fewer are listed. Every provider has it except the OpenAI Subscription, which has no model list, and Ollama, whose menu already lists the installed models (**Refresh installed models**). Gemini needs a key to list its models.
- **Test provider...** runs a quick capability check on the provider's current model: five small requests for Reachability, Streaming (SSE), Tool calling, Forced tool use (the search phase of AI Book Tools) and the Reasoning effort parameter. Each request is built the way a real one is (route, region, thinking off for the tool steps), and a failed step shows the provider's own explanation. Reachability also checks that KOAssistant can read the answer: a host that answers in another shape fails the step with the reason (a real request would fail too), the reply is shown when there is one, and a model that reasons first may answer the 16-token probe without text, which passes. When tool calling or the reasoning parameter passes, **Record capabilities for this model** saves the result, which makes features like AI Book Tools work where the model supports them.
- **Test provider...** needs the OpenAI-style chat format, so Anthropic, Gemini, Cohere, Ollama, Perplexity and the OpenAI Subscription don't have it. For those, select the provider and use **Settings → Advanced → Test Connection**, which sends one short message to your current provider and model, on the endpoint you use (a custom endpoint from `configuration.lua`, the Ollama server picked in the menu, your Z.AI, Qwen or Kimi region), and keeps its result on screen until you tap it. Every custom provider has the test (hold it: **Test this provider...**).

Two catalogs list more than they serve: prefer NVIDIA's listed models over ids fetched from it, and on OpenCode the GPT, Claude and Gemini ids fail (they use other endpoints).

## Custom models

Add models not in the built-in list, for any provider (built-in or custom).

1. Open the provider's model menu (**Settings → Model**, then the provider) and tap **Add custom model...**.
2. Enter the model ID exactly as your provider expects it. It is saved and selected at once.

- Custom models are **saved per provider** and persist across sessions. They appear first in the model menu, with a ★ prefix.
- Duplicates are detected and refused, and stray spaces around the id are trimmed. Use the exact model ID from your provider's documentation.
- For a custom provider with no default model, the first custom model you add becomes its default.
- **Manage custom models (N)...** in the model menu has a **Remove:** row per model (with confirmation) and **Clear all custom models**; for OpenRouter and Ollama it also offers **Refresh model capabilities**. You can also hold a custom model and pick **Remove custom model**. Removing the model in use returns the provider to its default.
- A custom model uses the same request path as the listed ones, streaming included. What else it can do (reasoning controls, AI Book Tools, web search) depends on what KOAssistant knows about the id: an id that starts like a known model (a dated version, for example) is treated like it; for OpenRouter and Ollama, KOAssistant asks the provider when you add a model with **Add custom model...** (Ollama also whenever you pick one), and **Refresh model capabilities** asks again ("Model capabilities detected"); **Test provider...** can record them on OpenAI-style providers; and `custom_models.lua` sets the rest.

**Advanced: custom_models.lua.** For finer control than the in-app picker gives you, copy `custom_models.lua.sample` to `custom_models.lua` in the plugin folder. It lets you grant or deny capabilities (tools, web search, thinking) for any model by id prefix, declare a reasoning profile for models KOAssistant doesn't already know, set parameter constraints (forced values such as temperature 1.0, which apply on every provider) and output caps, and place models into speed tiers, all without waiting for a plugin update. It also covers custom-provider models (target them with the `custom_<name>` provider id) and their reasoning wire type (effort-style vs `enable_thinking`-style). Your entries win over the built-in lists and over what providers report, and updates keep the file. The full format: [Advanced Configuration and Development](Advanced-Configuration-and-Development).

## Favorite models

Long-press a model in any model list (**Settings → Model**, the Quick Settings model button, **More models…** in a long-press menu, an action's model editor, the tier screens) to add it to or remove it from your favorites. ♥ marks a favorite (★ still marks a custom model). Favorites take the first model buttons of every long-press menu, for actions and for **Send**, in the order you added them (a menu has up to three model buttons: your favorites, then your recent picks, then your provider's fast model). **More models…** lists all of them first, and the model button (first in the highlight menu by default; the dictionary popup can show it too) switches between them. The long-press menus and the model button are on [Actions and Menus](Actions-and-Menus#the-action-hold-menu).

## Default models

You can override the system default model of any provider with your preferred choice.

**To set your default:** open the model menu (**Settings → Model**, then the provider), **long-press** any model (built-in or custom) and select **Set as default for** the provider.

**How defaults work:**
- **System default:** the first model in the built-in list, marked "(default)". Once you set your own, it is marked "(system default)".
- **Your default:** the model you set by long-press, marked "(your default)".
- When a provider is selected without a model being picked (the Quick Settings provider list does this), your default is used instead of the system default.

**To clear your default:** long-press it and select **Clear custom default**. The provider reverts to the system default.

### Current default models

The first model in each provider's list is its default. These tables are generated from the plugin's model lists (`koassistant/request/model_lists.lua`) when the page is published, so they match the code. "Also listed" is the rest of the built-in list in the menu's order; the routers list a few ids, and **Fetch models from provider...** lists the whole catalog.

<!-- generated: defaults -->
| Provider | Default | Also listed |
|----------|---------|-------------|
| **Anthropic** | `claude-sonnet-5-5` | `claude-opus-5-5`, `claude-fable-5-1`, `claude-haiku-5-5`, `claude-sonnet-5`, `claude-opus-5`, `claude-fable-5` |
| **OpenAI** | `gpt-5.6-terra` | `gpt-6.1-sol`, `gpt-6-astra`, `gpt-6-luna`, `gpt-6-sol`, `gpt-5.6-luna` |
| **OpenAI Subscription** | `gpt-5.6-terra` | `gpt-6.1-sol`, `gpt-6-astra`, `gpt-6-luna`, `gpt-6-sol`, `gpt-5.6-luna` |
| **DeepSeek** | `deepseek-flash` | `deepseek-v4-pro` |
| **Gemini** | `gemini-3.8-flash` | `gemini-4-argon`, `gemini-3.5-flash-lite`, `gemini-3.6-flash`, `gemini-3.1-pro-preview`, `gemini-3.1-flash-lite` |
| **Groq** | `openai/gpt-oss-120b` | `openai/gpt-oss-20b`, `qwen/qwen3.8-27b` |
| **Mistral** | `mistral-large-latest` | `mistral-medium-latest`, `mistral-small-latest`, `magistral-medium-latest`, `magistral-small-latest`, `ministral-14b-latest`, `ministral-8b-latest`, `ministral-3b-latest`, `codestral-latest` |
| **xAI** | `grok-4.7` | `grok-4.6`, `grok-4.5`, `grok-4.3`, `grok-4.20-0309-non-reasoning`, `grok-4.20-0309-reasoning`, `grok-build-0.1` |
| **OpenRouter** | `anthropic/claude-sonnet-5.5` | `anthropic/claude-opus-5.5`, `anthropic/claude-fable-5.1`, `anthropic/claude-haiku-5.5`, `anthropic/claude-sonnet-5`, `anthropic/claude-opus-5`, `anthropic/claude-fable-5`, `openai/gpt-5.6-terra`, `openai/gpt-6.1-sol` and 27 more |
| **Perplexity** | `perplexity/sonar` | `openai/gpt-6-luna`, `openai/gpt-6-sol`, `openai/gpt-6.1-sol`, `anthropic/claude-sonnet-5-5`, `google/gemini-3.8-flash`, `xai/grok-4.7` |
| **Z.AI** | `glm-5.2` | `glm-5.3`, `glm-5.3-flash`, `glm-5.3-flashx`, `glm-5.1`, `glm-5`, `glm-5-turbo`, `glm-4.7`, `glm-4.7-flash` |
| **Cohere** | `command-a-plus-05-2026` | `command-a-reasoning-08-2025`, `command-r7b-12-2024` |
| **Kimi** | `kimi-k2.6` | `kimi-k3`, `kimi-k2.6-thinking`, `kimi-k2-turbo-preview` |
| **Qwen** | `qwen3.8-max` | `qwen3.8-flash`, `qwen3.5-plus`, `qwen3.5-flash` |
| **Ollama** | `llama4` | `llama3.3`, `llama3.3:70b`, `llama3.2`, `llama3.2:3b`, `qwen3.5`, `qwen3`, `qwen3:8b`, `qwen3:32b` and 12 more |
| **Fireworks** | `accounts/fireworks/models/gpt-oss-120b` | `accounts/fireworks/models/glm-5p3`, `accounts/fireworks/models/glm-5p3-flash`, `accounts/fireworks/models/kimi-k3`, `accounts/fireworks/models/deepseek-v4p1-flash`, `accounts/fireworks/models/minimax-m3`, `accounts/fireworks/models/qwen3p8-max` |
| **NVIDIA** | `nvidia/nemotron-3.5-super-vl-120b-a12b` | `nvidia/nemotron-3-ultra-550b-a55b`, `nvidia/nemotron-3-nano-omni-30b-a3b-reasoning`, `openai/gpt-oss-20b` |
| **OpenCode Zen** | `deepseek-v4.1-flash` | `deepseek-v4-pro`, `glm-5.3-flash`, `glm-5.3`, `kimi-k3`, `qwen3.8-flash`, `minimax-m3`, `qwen3.6-plus` |
| **OpenCode Go** | `kimi-k3` | `hy4-preview`, `longcat-2.0`, `minimax-m3`, `glm-5.3-flash`, `glm-5.3`, `glm-5.2`, `mimo-v2.5-pro`, `mimo-v2.5` and 8 more |
| **A2Agent** | `deepseek-v4-flash` | `deepseek-v4-pro`, `deepseek-v4.1-flash`, `glm-5.3`, `glm-5.3-flash`, `kimi-k3`, `qwen3.8-max`, `qwen3.8-flash`, `MiniMax-M3` |
<!-- /generated: defaults -->

A few of these ids come with conditions:

- **OpenAI Subscription:** the Sol and Astra models need a paid ChatGPT plan; a free account is refused with a note saying so.
- **Gemini:** `gemini-4-argon` and `gemini-3.1-pro-preview` are paid only. The 2.5 models left the list (Google serves them only to accounts that used them before); a 2.5 model you picked keeps working, and **Fetch models from provider...** adds one back. Since 2026-10-08 Google answers `gemini-3.7-flash` with 3.8 Flash and `gemini-3.5-flash` with 3.6 Flash, so a setting that names either moves to the model that answers, with a one-time note.
- **Ollama:** the menu lists the models installed on your server, not this list. `llama4` is the default when it is installed, otherwise your server's first installed model.
- **OpenCode Zen:** the list holds the open-weight models a new workspace serves (October 2026). The OpenCode console's Models tab decides which models a workspace may use, and a model switched off there answers "Model access is disabled"; on a new workspace the older versions are off, so `deepseek-v4-flash` (the previous default), `glm-5.2`, `glm-5.1`, `minimax-m2.7`, `minimax-m2.5`, `qwen3.5-plus` and `qwen3.8-max` left the list. A saved default moves to `deepseek-v4.1-flash` with a one-time note; a model you picked yourself keeps working where it is enabled, and **Fetch models from provider...** lists what your workspace serves.
- **OpenCode Go:** `deepseek-v4-pro` and the `muse-spark` models need an opt-in at the OpenCode console, and `deepseek-v4.1-flash`, which took the place of `deepseek-v4-flash` in Go's catalog, was not verified by a request (the maintainer has no Go subscription). A saved pick of `deepseek-v4-flash` or `deepseek-v4-flash-vision-exp` moves to `deepseek-v4.1-flash` with a one-time note.

The community hosts ship short built-in lists (the first id is the default). Some of these ids were never confirmed with a request, since the maintainer has no key for these providers; if the first request fails, fetch the live list.

<!-- generated: community -->
| Provider | Built-in list |
|----------|---------------|
| **Together** | `deepseek-ai/DeepSeek-V4-Pro-0813`, `deepseek-ai/DeepSeek-V4-Flash-0731`, `meta-llama/Llama-3.3-70B-Instruct-Turbo`, `moonshotai/Kimi-K2.6`, `zai-org/GLM-5.2` |
| **SambaNova** | `gpt-oss-120b`, `DeepSeek-V3.1`, `DeepSeek-V3.2`, `Meta-Llama-3.3-70B-Instruct`, `MiniMax-M3`, `gemma-4-31B-it` |
| **Requesty** | `openai/gpt-4o-mini`, `openai/gpt-5.5`, `openai/gpt-5.4`, `anthropic/claude-sonnet-5-5`, `anthropic/claude-opus-5-5`, `anthropic/claude-fable-5.1`, `anthropic/claude-sonnet-5`, `anthropic/claude-opus-5` and 6 more |
| **Doubao** | `doubao-seed-2.0-pro-32k`, `doubao-seed-2.0-pro-256k`, `doubao-seed-2.0-lite`, `doubao-seed-2.0-code` |
| **Cerebras** | `gpt-oss-120b`, `gemma-4-31b` |
| **MiniMax** | `MiniMax-M3`, `MiniMax-M2.7` |
| **DeepInfra** | `meta-llama/Llama-3.3-70B-Instruct-Turbo`, `deepseek-ai/DeepSeek-V4-Pro` |
| **Novita AI** | `deepseek/deepseek-v4-pro`, `meta-llama/llama-3.3-70b-instruct` |
| **Hyperbolic** | `meta-llama/Llama-3.3-70B-Instruct` |
| **Nebius AI Studio** | `meta-llama/Llama-3.3-70B-Instruct`, `deepseek-ai/DeepSeek-V4` |
| **Chutes** | `deepseek-ai/DeepSeek-V4-Flash-0731-TEE` |
| **Featherless** | `Qwen/Qwen3-32B` |
| **Vercel AI Gateway** | `openai/gpt-5.5`, `anthropic/claude-sonnet-5` |
| **Cheaper Inference** | `gpt-5.4-mini`, `claude-sonnet-5` |
<!-- /generated: community -->

> **Note:** OpenRouter, Requesty, Together, Fireworks and SambaNova use provider-prefixed or vendor-specific model IDs (`anthropic/claude-sonnet-5` on OpenRouter, `deepseek-ai/DeepSeek-V4-Pro-0813` on Together); see the provider's own catalog for exact strings, or use **Fetch models from provider...**. The routers spell the same model differently: `anthropic/claude-sonnet-5.5` and `x-ai/grok-4.3` on OpenRouter, `anthropic/claude-sonnet-5-5` and `xai/grok-4.3` on Requesty. Fireworks ids live under `accounts/fireworks/models/` and write a version's dots as "p" (`glm-5p3` is GLM-5.3).

### When a default changes

- **A model you picked stays**, also after it leaves the list, as long as the provider still serves it. Claude Haiku 4.5, Sonnet 4.6 and Opus 4.8, and GPT-5.6 Sol, GPT-5.5 and the three GPT-5.4 models on the OpenAI API left the picker in v0.24.0 and keep working if you picked them.
- **If you never picked a model** for a provider, you move to its new default at the next start, with a one-time note.
- **A model the provider no longer serves** moves to its replacement even if you picked it, with a one-time note, and tiered actions use models that answer. A favorite, a model pinned to an action or a tier, or a preferred default that still names it is sent as the replacement too. Examples: Perplexity's old Sonar ids (to `perplexity/sonar`), the OpenAI Subscription's GPT-5.4 models and `gpt-5.5`, and models retired on NVIDIA, Groq (Compound, Compound Mini), Fireworks, Together, OpenCode Zen and OpenCode Go.

## Model speed tiers

Beyond your single default model, KOAssistant ranks each provider's models into five speed and cost tiers:

| Tier | Meaning |
|------|---------|
| **Frontier** | Most capable premium models: expensive, and used only when you ask for this tier |
| **Flagship** | The provider's most capable general-purpose model |
| **Standard** | Balanced performance and cost |
| **Fast** | Optimized for speed and lower cost |
| **Ultrafast** | Smallest and cheapest models for basic tasks |

What uses them:

- **Actions with a speed hint.** Translate, Quick Define and Quick Explain use the fast model of your current provider. Only the model changes; the prompt and the other settings stay. You can set a tier per action in the action editor ([Actions and Menus](Actions-and-Menus)), and **Settings → Advanced → Faster Models for Quick Actions** (on by default) turns speed hints off everywhere.
- **The Quick Answer preset's Model override** (in **Settings → Chat & Export Settings → Quick Answer Preset**). **Fastest for provider** takes the first of ultrafast, fast, standard and flagship that the provider has; a tier mode uses that tier ([Contexts and Chat](Contexts-and-Chat)).
- **The fast-model button** of the long-press menus.

A named tier is exact: when your provider has no model for it, the request keeps your current model. Tiers never switch providers, except through a global pin (below). Frontier is never chosen automatically.

**Model tiers...** in any provider's model menu remaps that provider's tiers to your preferred models. Each row shows a tier and its model ("Fast: claude-haiku-5-5", with "(custom)" when it is your pick); a tier's list offers **Default** (the built-in pick) and the provider's models, built-in and custom; **Reset all tiers to defaults** undoes your picks, and **About tiers** explains. Your picks win over `custom_models.lua`, which wins over the built-in picks, and the model list's tier tags follow them.

For a pin that overrides the tier system everywhere (not just one provider), **Settings → Advanced → Tier Models (Global)** locks a tier to one specific provider and model for every tier-hinted request. A pin applies only when an action or Quick Answer asks for a speed tier, and only to that request; normal chats and the models you pick are never affected. Each tier reads "Follow active provider" (the default) or the pinned provider and model, and **Clear all pins** removes them. An unusable pin (missing key) is ignored automatically. A provider's **Model tiers...** names the global pins that outrank it.

Meta-routers (OpenRouter, Requesty, OpenCode Zen, OpenCode Go, A2Agent, Perplexity) ship without curated tier placements, because a router ladder would hop vendors on a speed hint; so do Cerebras, MiniMax, DeepInfra, Novita AI, Hyperbolic, Nebius AI Studio, Chutes, Featherless, Vercel AI Gateway and Cheaper Inference. You can add your own with **Model tiers...** or `custom_models.lua`, custom providers included.

### Current tier picks

The built-in picks, generated from the plugin's tier table when the page is published. An empty Frontier cell means the provider has no frontier-class model; a provider without a row has no curated placements (the routers and the community hosts, as above).

<!-- generated: tiers -->
| Provider | Frontier | Flagship | Standard | Fast | Ultrafast |
|----------|----------|----------|----------|------|-----------|
| **Anthropic** | `claude-fable-5-1` | `claude-opus-5-5` | `claude-sonnet-5-5` | `claude-haiku-5-5` | `claude-haiku-5-5` |
| **OpenAI** | `gpt-6-astra` | `gpt-6.1-sol` | `gpt-5.6-terra` | `gpt-6-luna` | `gpt-6-luna` |
| **OpenAI Subscription** | `gpt-6-astra` | `gpt-6.1-sol` | `gpt-5.6-terra` | `gpt-6-luna` | `gpt-6-luna` |
| **DeepSeek** |  | `deepseek-v4-pro` | `deepseek-flash` | `deepseek-flash` | `deepseek-flash` |
| **Gemini** | `gemini-4-argon` | `gemini-3.8-flash` | `gemini-3.8-flash` | `gemini-3.5-flash-lite` | `gemini-3.5-flash-lite` |
| **Groq** |  | `openai/gpt-oss-120b` | `openai/gpt-oss-120b` | `openai/gpt-oss-20b` | `openai/gpt-oss-20b` |
| **Mistral** |  | `mistral-large-latest` | `mistral-medium-latest` | `ministral-14b-latest` | `ministral-3b-latest` |
| **xAI** |  | `grok-4.7` | `grok-4.20-0309-non-reasoning` | `grok-4.20-0309-non-reasoning` | `grok-4.20-0309-non-reasoning` |
| **Z.AI** |  | `glm-5.3` | `glm-5` | `glm-5-turbo` | `glm-4.7-flash` |
| **Cohere** |  | `command-a-plus-05-2026` | `command-a-plus-05-2026` | `command-r7b-12-2024` | `command-r7b-12-2024` |
| **Kimi** |  | `kimi-k2.6` | `kimi-k2.6` | `kimi-k2.6` | `kimi-k2.6` |
| **Qwen** |  | `qwen3.8-max` | `qwen3.5-plus` | `qwen3.5-flash` | `qwen3.5-flash` |
| **Ollama** |  | `llama4` | `llama3.3` | `llama3.2:3b` | `tinyllama` |
| **Fireworks** |  | `accounts/fireworks/models/glm-5p3` | `accounts/fireworks/models/gpt-oss-120b` | `accounts/fireworks/models/gpt-oss-120b` | `accounts/fireworks/models/deepseek-v4p1-flash` |
| **NVIDIA** |  | `nvidia/nemotron-3-ultra-550b-a55b` | `nvidia/nemotron-3.5-super-vl-120b-a12b` | `openai/gpt-oss-20b` | `openai/gpt-oss-20b` |
| **Together** |  | `deepseek-ai/DeepSeek-V4-Pro-0813` | `meta-llama/Llama-3.3-70B-Instruct-Turbo` | `meta-llama/Llama-3.3-70B-Instruct-Turbo` | `meta-llama/Llama-3.3-70B-Instruct-Turbo` |
| **SambaNova** |  | `gpt-oss-120b` | `Meta-Llama-3.3-70B-Instruct` | `Meta-Llama-3.3-70B-Instruct` | `Meta-Llama-3.3-70B-Instruct` |
| **Doubao** |  | `doubao-seed-2.0-pro-32k` | `doubao-seed-2.0-pro-32k` | `doubao-seed-2.0-lite` | `doubao-seed-2.0-lite` |
<!-- /generated: tiers -->

- **Claude Haiku 5.5** (since v0.24.0, replacing Haiku 4.5) is Anthropic's fast and fastest model, so Translate, Quick Define and Quick Explain run on it when they use the faster model, still with reasoning off. It reads up to 1M tokens (Haiku 4.5: 200K) and costs $0.10 / $0.50 per million tokens, five times that for a request whose prompt passes 100K tokens. It also replaced Haiku 4.5 in the OpenRouter and Requesty lists.
- **`gpt-6-luna`**, the cheapest OpenAI model, is the fast and fastest pick of OpenAI (it replaced GPT-5.6 Luna and GPT-5.4 nano) and of the OpenAI Subscription.
- The Anthropic, OpenAI and OpenAI Subscription model lists read in this order: the default, then the flagship, frontier and fast picks, then one previous version per line.
- Ollama's picks are model names your server may not have installed; point them at installed models with **Model tiers...**.

## Provider settings

**Settings → Advanced → Provider Settings** holds the settings a single provider needs. The same rows sit in that provider's model menu.

- **Z.AI Region:** International (`api.z.ai`, the default) or China (`open.bigmodel.cn`). The same API key works on both.
- **Z.AI Search Engine:** the engine Z.AI's web search uses: Jina (international, the default), Bing (international), or Quark, Sogou, Pro and Basic (Chinese web). The international engines return much better sources for non-Chinese queries.
- **Gemini Content Filter:** Relaxed for books (the default) or Google default. Google's default filter can block answers about violent or sexual passages in books; the reply then arrives empty, with the reason named. Relaxed turns the four adjustable filter categories off for KOAssistant's requests; Google default sends no filter setting.
- **Qwen Region:** International (Singapore, the default), China (Beijing) or US (Virginia). Keys are region-specific and not interchangeable.
- **Kimi Region:** International (`api.moonshot.ai`, the default) or China (`api.moonshot.cn`). Keys are not interchangeable between the two platforms.

Set the Qwen and Kimi regions to the platform that issued your key; Fetch models and Test provider follow the region too.

## Provider quirks

What KOAssistant does differently per provider, mostly on its own. When the current model accepts only one temperature or none, **Settings → Advanced → Temperature** says so ("fixed by this model" or "ignored by this model").

- **Anthropic:** temperature capped at 1.0; adaptive or extended thinking forces it to exactly 1.0. Claude Opus 4.7, 4.8, 5 and 5.5, Sonnet 5 and 5.5, Fable 5 and 5.1 and Haiku 5.5 reject all sampling parameters (temperature is stripped entirely). Sonnet 5.5 cannot switch thinking fully off, so Off sends Anthropic's lowest setting, which does not think on ordinary questions. Sonnet 5.5, Opus 5.5 and Fable 5.1 refuse a forced tool call, so AI Book Tools asks them without the force (here and through OpenRouter). Prompt caching is automatic and gives up to 90% savings on repeated context ([Artifacts and Caching](Artifacts-and-Caching#prompt-caching)).
- **OpenAI:** GPT-5.x and GPT-6 models accept only temperature 1.0; newer models use `max_completion_tokens`. **Native web search** rides the Responses API (`/v1/responses`) for capable models; Chat Completions has no native search, so a web-search request on an unsupported model simply runs without it. GPT-6 models reason by default.
- **Gemini:** uses the "model" role instead of "assistant"; thinking uses the camelCase REST format: 2.5 models use `thinkingBudget` (0 = off, -1 = dynamic, 128-24576 = specific), 3.x models and Gemini 4 Argon use `thinkingLevel` and get no temperature (Google deprecated sampling parameters for Gemini 3, and Argon ignores them). Web search uses Google Search grounding (on free keys, neither web search nor AI Book Tools works with 3.x models: [Free tiers](#free-tiers)). Streaming may arrive in larger chunks than with other providers (cosmetic). Google's content filter is relaxed for book passages by default (**Settings → Advanced → Provider Settings → Gemini Content Filter**).
- **Ollama:** local only; NDJSON streaming (not SSE). For a server on another machine, add it with the **Server** row of Ollama's model menu ([Ollama](#ollama)), or set the endpoint in `configuration.lua`.
- **OpenRouter:** requires an HTTP-Referer header (handled automatically); web search uses OpenRouter's own Exa integration via the `:online` suffix ([Meta-providers](#meta-providers)).
- **Requesty:** OpenAI-compatible model router; uses `provider/model` naming (e.g. `openai/gpt-4o-mini`); sends optional HTTP-Referer and X-Title headers (handled automatically).
- **A2Agent:** gateway to DeepSeek, GLM, Kimi, Qwen and MiniMax models; reasoning follows each model's own settings (GLM models always reason, so Minimal gives their lowest level); no web search; AI Book Tools on every listed model (its Qwen models refuse a forced tool call while they reason, so AI Book Tools asks them without the force).
- **Cohere:** uses the v2/chat endpoint with a different response format. X-Rays work on Cohere, Command R7B and Command A included: KOAssistant knows each model's output limit and retries once at the limit Cohere names.
- **DeepSeek:** `deepseek-flash` (DeepSeek's new name for the V4 flash model; `deepseek-v4-flash` still works) and `deepseek-v4-pro` both support a `thinking` toggle (on by default); 1M context with up to 384K output; controlled by the reasoning stance or a per-model override ([Reasoning, Web Search and Book Tools](Reasoning-Web-Search-and-Book-Tools)). AI Book Tools sessions run with thinking off (DeepSeek refuses their forced lookups while thinking).
- **xAI:** Grok models (4.5, 4.6 and 4.7: 500K context; 4.3 and 4.20: 1M); native **live web search** rides the Responses API (`/v1/responses`) for capable Grok models; the reasoning toggle is baked into some slugs (`grok-4.20-...-reasoning` vs `-non-reasoning`); Grok 4.5, 4.6 and 4.7 cannot turn reasoning off.
- **Z.AI:** regional endpoints ([Provider settings](#provider-settings)); GLM-4.7 and later think through the `thinking` param (on by default; it must be explicitly disabled), and the temperature is sent as 1.0 while they think. GLM-5.x is the current flagship generation, and GLM-5.3 always thinks (it cannot be turned off). Web search uses a chat-wire tool with a pickable engine; no AI Book Tools.
- **Qwen:** the 3.8 and 3.5 models reason by default; Minimal and an action's reasoning off turn it off (`enable_thinking=false`), and AI Book Tools work on all four listed models, with reasoning off during the lookups. A setting that names `qwen3-max` or `qwen3-coder-plus` moves to `qwen3.8-max`, and `qwen-turbo` to `qwen3.5-flash`, with a one-time note. Web search uses DashScope's own search, which reports no sources, so Show Sources stays empty. A temperature of 2.0 is sent as 1.9 (DashScope refuses 2.0). Keys are tied to their region ([Provider settings](#provider-settings)).
- **Kimi:** `kimi-k2.6` and `kimi-k3` accept only temperature 1 while they think, so that is what they get, and no temperature when reasoning is off. `kimi-k2.6-thinking` and `kimi-k2-turbo-preview` are served on the China platform only (the international platform serves `kimi-k2.6` and `kimi-k3`). Keys are tied to their platform ([Provider settings](#provider-settings)).
- **NVIDIA:** no web search (NVIDIA's API provides none); no AI Book Tools on the listed models since NVIDIA retired the one that had them (2026-09-01); answers from its Nemotron models run up to 16,384 tokens by default. NVIDIA retires hosted models on short notice, and its catalog lists more models than it serves ([Free tiers](#free-tiers)).
- **Fireworks:** ids live under `accounts/fireworks/models/` with a version's dots written as "p"; GLM-5.3 and gpt-oss cannot turn reasoning off there, so Off gives them their lowest level.
- **Doubao:** Volcano Engine may require a date-suffixed snapshot or endpoint id; check the exact string in its console.
- **OpenCode Zen and OpenCode Go:** both send the conversation header OpenCode requires (`x-opencode-session`, carrying the chat's id). One account key works for both, entered under `opencode` and `opencode_go`. GPT, Claude and Gemini ids use other OpenCode endpoints and are not supported yet. Qwen 3.8 Flash, and on Go also Qwen 3.8 Max and 3.7 Plus, refuse a forced tool call while they reason, so AI Book Tools asks them without the force.
- **Perplexity:** runs on Perplexity's Agent API since v0.23.0 (the Sonar chat API it used before retired on 2026-09-27). Perplexity serves its own Sonar model and other companies' models (GPT, Claude, Gemini, Grok and more) on one key; the model list holds a few of them, with `perplexity/sonar` as the default, and **Fetch models** lists the rest. Web search is on by default here. With web search on, the model answers inside Perplexity's `fast` search preset, so it searches and cites its sources, as picking a model in Perplexity's own app does; with web search off it answers without a search. The answer's sources list only what it cites; **Show Sources** lists everything found. A setting that still names an old Sonar model (`sonar`, `sonar-pro`, `sonar-reasoning-pro`, `sonar-deep-research`) moves to `perplexity/sonar`, with a one-time note. Perplexity's research presets (`low`, `medium`, `high`, which pick their own model) are not in the list but still work if typed in as a custom model; a preset always searches, so with web search off the request goes to `perplexity/sonar` without a search instead. Web search is reported as used only when results came back. Two Grok models (`xai/grok-4.20-reasoning` and `xai/grok-4.20-multi-agent`) refuse the preset's settings, so they answer on their own and search only when they decide to. **Test provider...** is not offered; **Settings → Advanced → Test Connection** checks it.
- **Models that cannot turn reasoning off:** Minimal and the Quick chip give them their lowest level instead. Among them: GPT-6 Astra and GPT-6.1 Sol, Claude Opus 5.5 and Fable 5, Gemini 4 Argon, Gemini 3.8 Flash, 3.6 Flash and 3.1 Pro, GLM-5.3 and Grok 4.5 to 4.7; through Fireworks, GLM-5.3 and gpt-oss; through OpenRouter, Claude Sonnet 5.5, Opus 5.5 and Fable 5, Gemini 4 Argon, Grok 4.6, Qwen3.8 Max and gpt-oss; through Requesty, Claude Fable 5, Sonnet 5.5 and Opus 5.5. Reasoning from models that end their thinking with a bare `</think>` (Qwen3 Thinking, DeepSeek R1 on some hosts) goes to the reasoning view, not the answer. Per-model details: [Reasoning, Web Search and Book Tools](Reasoning-Web-Search-and-Book-Tools).

## Meta-providers

**OpenRouter** is a "meta-provider" that routes requests to 500+ different backend providers (Anthropic, OpenAI, Google, xAI, Perplexity and others). This architecture has implications. (KOAssistant treats Requesty, OpenCode Zen, OpenCode Go, A2Agent and Perplexity as routers too, without curated speed tiers; the notes below are about OpenRouter.)

**What OpenRouter normalizes (consistent for KOAssistant):**
- **Response format:** always OpenAI-compatible (`choices[0].message.content`).
- **Web search:** with the `:online` suffix, OpenRouter uses its **own Exa search** integration, not the underlying provider's. Web search detection via `url_citation` annotations works consistently.
- **Error format:** standardized error responses.

**What varies (backend differences KOAssistant can't control):**
- **Streaming behavior:** providers send chunks at different rates and sizes. Some stream smoothly, others may appear choppy or "flashing".
- **Response latency:** backend providers have different speeds.
- **Model-specific quirks:** some models (Perplexity's, for example) return structured data that may need special handling.

**Troubleshooting OpenRouter:**
- If streaming appears choppy or unusual, it's likely the backend provider's characteristic, not a KOAssistant bug.
- Try a different underlying model (switch from `x-ai/grok-4.3` to `anthropic/claude-sonnet-5`, for example).
- If web search causes trouble with a model, turn it off for that chat (the Web chip).
- Perplexity models through OpenRouter work but may stream differently.

**Why one handler works:** KOAssistant uses a single OpenRouter handler because the response format is consistent. The streaming variability is cosmetic and doesn't affect the final response.

## Related

- [Getting Started](Getting-Started): install, add your first key, connect the OpenAI Subscription.
- [Reasoning, Web Search and Book Tools](Reasoning-Web-Search-and-Book-Tools): reasoning per model, how each provider searches the web, AI Book Tools.
- [Privacy and Data](Privacy-and-Data): what a provider receives, trusted providers and local processing.
- [Advanced Configuration and Development](Advanced-Configuration-and-Development): custom endpoints in `configuration.lua` and the full `custom_models.lua` format.
- [Actions and Menus](Actions-and-Menus): the long-press menu that runs an action once with another model, and the model button.
- [Settings Reference](Settings-Reference): every row of the Model, API Keys & Auth and Advanced menus.
