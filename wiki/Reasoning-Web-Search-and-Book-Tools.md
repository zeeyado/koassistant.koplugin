# Reasoning, Web Search and Book Tools

Three ways to make an answer better grounded or better thought through: reasoning (the model thinks before it answers), web search (the model looks things up on the web), and AI Book Tools (the model searches and reads the open book on demand). All three have a global setting under **Settings → Advanced**, most have a per-book override, and the input dialog's chips switch web search and book tools for one chat. What the chat window shows afterwards, the Show Sources and Show Reasoning viewers, is on [Chat Windows](Chat-Windows).

## Reasoning

For complex questions, many models can think through the problem before responding. Reasoning raises latency and token use but can improve results a lot for complex tasks such as deep analysis and nuanced questions.

Reasoning is controlled per model, not by one global switch. Every model has its own nature (some always reason, some cannot, some are off by default, some on) and KOAssistant respects it. Two controls steer it:

1. **The global stance** (**Settings → Advanced → Reasoning → Global stance**, or the Reasoning tile in Quick Settings): one dial applied to every model as far as each allows. **Minimal** is off where the model can be turned off, otherwise its lowest setting; **Default** is each model's normal behaviour, nothing forced (the default for everyone); **Maximum** is the model's deepest reasoning. Because the stance respects each model's capability, Minimal turns reasoning off on models that support it and dials always-on models down to their lowest effort; it never claims a model is off when it is not.
2. **Per-model overrides** (**Settings → Advanced → Reasoning → Per-model reasoning**): pick a provider, then a model, then set it: **Follow global** (the default), **Model API default** (the model's own behaviour whatever the stance), **Off** where supported, or **On** or a level (effort or budget), depending on the model. Only configurable models are listed, and each row shows your setting and what it resolves to ("Follow global → High").

The Reasoning tile in Quick Settings shows the effective state for the current model ("Default", "Off", "High") and opens a two-tab popup: **Global** (the stance alone) and **Current model** (that model's controls, with an "Other models…" browser).

**Quick Answer.** The input dialog's Quick chip applies the Quick Answer preset, which turns reasoning off for that chat by default (its "Turn Reasoning Off" component under **Settings → Chat & Export Settings → Quick Answer Preset**); your stance and per-model settings are untouched ([Contexts and Chat](Contexts-and-Chat)).

**Precedence**, highest first: a per-action setting; a choice for this chat or run (**No reasoning** from a long press on Send or on an action, or the Quick Answer preset's reasoning-off while Quick is on); the per-model override; the global stance; the model's own default. Any action can override reasoning per provider under its settings (Manage Actions → hold the action → Edit Settings → Reasoning → **Configure per-provider...**), and several built-ins (Translate, Quick Define, Dictionary, Summarize, X-Ray) force it off because the task gains nothing from it ([Actions and Menus](Actions-and-Menus)).

### What each model can do

| Model family | Nature | Control |
|---|---|---|
| Claude Sonnet 5.5 | adaptive, on by default (thinks on harder questions) | Off (Anthropic's lowest setting) / effort low to max, xhigh included |
| Claude Sonnet 5, Opus 5, Haiku 5.5 | adaptive, on by default | Off / effort low to max, xhigh included |
| Claude Opus 5.5 | adaptive, on by default | effort low to max, xhigh included; cannot be fully disabled |
| Claude Fable 5.1 | adaptive, off by default (thinks when asked) | Off / effort low to max, xhigh included |
| Claude Fable 5 | adaptive, always on | effort low to max, xhigh included; cannot be fully disabled |
| Claude Opus 4.8 / 4.7 / 4.6, Sonnet 4.6 | adaptive, off by default | Off / effort low to high; Opus adds xhigh, max |
| Gemini 4 Argon, Gemini 3 (3.8 / 3.6 flash, 3.1 pro) | thinks by default | effort low to high (3.6 flash also minimal); cannot be fully disabled |
| Gemini 3 flash-lite (3.5, 3.1) | off by default | Off / effort minimal to high |
| OpenAI GPT-6 sol / luna | reasons by default | Off / effort low to xhigh |
| OpenAI GPT-6 astra, GPT-6.1 sol | reasons by default | effort low to xhigh; cannot be fully disabled |
| OpenAI GPT-6.1 terra (the default), GPT-5.6 terra, GPT-5.6 family | reasons by default (medium) | Off / effort low to xhigh |
| OpenAI GPT-5.4 family | off by default (gated) | Off / effort low to xhigh |
| OpenAI GPT-5.5 | reasons by default | effort low / medium / high; cannot be fully disabled |
| DeepSeek V4 and Flash, Z.AI GLM-4.7 to 5.2 | thinks by default | On / Off |
| Z.AI GLM-5.3 family | always thinks | no control |
| Qwen 3.8 / 3.7 / 3.5 (the Qwen provider) | reasons by default | Off / On |
| xAI Grok 4.7, 4.6, 4.5 | reasons by default | effort minimal to xhigh; cannot be fully disabled |
| xAI Grok 4.3 | reasons by default | Off / effort low / medium / high |
| xAI Grok 4.20 reasoning | always reasons | no control |
| Groq gpt-oss, Together DeepSeek-V4-Pro | always reason | effort only, low / medium / high |
| Groq Qwen 3.8 27B | off by default | Off / effort low / medium / high |
| Fireworks models | reason by default | Off / effort (GLM-5.3: effort only) |
| Mistral Large 4 | thinks by default | no control on Mistral's own wire (low / medium / high through OpenCode Zen and OpenRouter) |
| Mistral Magistral | always reasons | no control; the thinking is extracted and viewable |
| Kimi K3.1 Pro | always thinks | no control |
| NVIDIA Step 5 preview, nemotron-3 family | reason by default | Off / effort low / medium / high |
| A2Agent DeepSeek-V4.1-Flash, MiniMax-M3.1-Flash | reason by default | Off / effort (MiniMax: effort only) |

Temperature is forced to 1.0 where a model's reasoning requires it (Claude adaptive and extended thinking, Z.AI thinking). Sonnet 5.5, Opus 5.5, Haiku 5.5, Opus 5, Fable 5.1, Fable 5, Sonnet 5, Opus 4.8 and Opus 4.7 reject sampling parameters outright, and Google deprecated them for every Gemini 3 model and Gemini 4 Argon, so those requests carry none; **Settings → Advanced → Temperature** says "ignored by this model" for them.

**Viewing the reasoning.** When a model returns its thinking (Anthropic, Gemini, DeepSeek, Z.AI, Mistral, Kimi, Qwen, OpenRouter, and the `<think>`-tag models on Groq, Together, Fireworks, SambaNova, Ollama and Perplexity), it is captured and shown by **Show Reasoning** in the chat window's gear menu. The answer's usage line names it ("Reasoning/Thinking was used") when **Settings → Advanced → Reasoning → Show Indicator in Chat** is on (the default); on OpenAI, which keeps its reasoning hidden, it says "Reasoning requested" with the effort sent instead, and dictionary windows leave reasoning out of that line ([Chat Windows](Chat-Windows#show-sources-and-show-reasoning)).

## Web search

Supported providers can search the web and use current information in their answers.

| Provider | Mechanism | Notes |
|---|---|---|
| **Anthropic** | the web search tool | all models; the effort dial sets the maximum number of searches (2 / 5 / 10) |
| **OpenAI** | native web search (the Responses API) | GPT-5 and newer models; the effort dial sets the search context size |
| **OpenAI Subscription** | native web search (Responses through the Codex backend) | the same models and effort mapping; which models answer depends on the ChatGPT plan |
| **Gemini** | Google Search grounding | search-grounding-capable models; the search count is automatic. **Free-tier keys: grounding on Gemini 3.x models is rejected** (an instant "quota exceeded" error even when plain requests work): use a 2.5 model for web search on a free key (only on Google accounts old enough to still have them), switch provider, or add paid credits (confirmed to lift the limit). The error dialog offers "Try again without web search" |
| **xAI** | the web search tool (the Responses API) | Grok-4 models; search decided automatically |
| **OpenRouter** | Exa search through the `:online` suffix | every model (about $0.007 per searched request); the effort dial sets the result count (3 on Light, the provider default on Standard, 10 on Thorough) |
| **Z.AI** | the `web_search` tool on the chat wire | all models; results return with links and titles; the engine is pickable (**Settings → Advanced → Provider Settings → Z.AI Search Engine**; the API's own default returns poor sources for non-Chinese queries) |
| **Qwen** | DashScope `enable_search` | all models; the provider injects results on its side and reports no sources, so Show Sources has nothing to list |
| **Perplexity** | Perplexity's own search (the Agent API): the model answers inside Perplexity's fast search preset | on by default (the Web chip starts on); turned off per chat or per book, the model answers without a search; the effort dial sets the search context size |

Other providers ignore web search and answer normally.

**How it works.** Set the global default with **Settings → Advanced → Web Search → Enable Web Search** (off by default), or toggle it for one chat with the **Web** chip. While it is on the AI can search during its answer; during streaming a "Searching the web..." line shows (with a 🔍 prefix when emoji icons are on), any prose written before the search stays visible followed by an inline "[Searched the web]" marker, and afterwards the answer's usage line says "Web search was used" when **Settings → Advanced → Web Search → Show Indicator in Chat** is on (the default). The URLs and queries are kept with the chat and shown by **Show Sources** in the chat window's gear menu, the same viewer that lists book lookups.

**Web Search Effort** (**Settings → Advanced → Web Search → Web Search Effort**, grayed while Enable Web Search is off): **Light** (fewest searches, fastest and cheapest), **Standard** (the provider's defaults) or **Thorough** (most searches and context, slower and costlier). It maps to each provider's own control where one exists: Anthropic's maximum searches, the search context size on OpenAI (API and Subscription) and Perplexity, OpenRouter's result count, Z.AI's result count and snippet size; on Thorough, Qwen searches on every request; Gemini and xAI decide on their own. Per book: hold the Web chip and use its "Search depth" row, or Book Settings → Chat behavior.

**Layering**, highest first: an action's own flag; the chat's Web chip; the per-book override; the global default. The Web chip's tap changes the current chat only; its hold opens the For-this-book / Global picker. With **Settings → Display Settings → Emoji → Emoji Data Access Indicators** on, action labels show the effective state: a forced-on action shows 🌐, one that follows the setting shows (🌐) while search is on. The reply window carries the same chip ("Web N/A" when the provider cannot search), and a long press on its Send replies with another model or without reasoning.

**Per-action override.** A custom action can set `enable_web_search = true` (always search; the built-in News Update does this to fetch news even when search is otherwise off), `false` (never), or leave it unset to follow the effective setting ([Actions and Menus](Actions-and-Menus)). **Research Mode** changes actions that force search off, X-Ray and Summarize among them, to follow your setting instead, so a paper with a DOI gets web-enriched analysis when search is on ([Research Mode](Research-Mode)).

Best for questions about current events, recent developments, fact-checking and research topics. Web search raises token use and may add latency; Perplexity searches by default, but its Web toggle genuinely turns search off for a chat or a book. OpenRouter routes to many backends with their own streaming behaviour: if streaming turns choppy with search on, turn search off for that chat ([Providers and Models](Providers-and-Models)).

## AI Book Tools

When you chat about an open book, the AI can call local tools to look things up in the book on demand, instead of answering only from the book's metadata and its own knowledge. That grounds answers in what you have read, with real page references. The rows are under **Settings → Advanced**; the feature is experimental, and its behaviour may change.

**What it does.** The AI gets three local tools: `search_book` (word search: the exact phrase first, then every word, then most words of a longer query; the book's very common words are not required; whole-word hits before hits inside longer words; 12 best hits per query with the exact total; spelling must match), `read_around` (a page window around a hit or a page) and `toc` (the table of contents, filterable by level and title), and may call them before answering. Every search runs in a background process, so the screen stays live and Stop cancels (the progress window counts the seconds); in a long EPUB it uses KOReader's own document search. Before the first lookup the AI sees a short outline of the contents and how far it may read. The search and the extraction run on your device; only the AI's own tool requests and the bounded excerpts it asks for go to the provider, unless the readable text is short enough to send whole (below). Every result tells the AI what it could not reach (caps, the spoiler limit, hidden sections); the answer mentions a part of the book that was out of reach only where it matters, and never describes the lookups themselves.

**Reading short texts whole.** When the readable text (up to your position while spoiler protection is on) is no longer than **Settings → Advanced → AI Book Tools: Read Short Texts Whole** allows (Off, Small 16,000 characters, Medium 64,000, the default, or Large 128,000; Arabic, Cyrillic or CJK text counts two to three bytes per character), the AI gets it in one piece instead of searching it: a novella, a short story or the first chapters of a long book are then covered in full. The text goes with every message of the chat, placed so that providers which cache prompts charge the repeats at a fraction (providers that cache in small steps, OpenAI and DeepSeek among them, still charge the part you had already read at the cached rate when you read on between messages). When the model's known limits cannot take it (a per-minute allowance met earlier in the session, a small context window) the book is searched instead. Off means always search, and so does the Interactive mode. Per book: Book Settings → Chat behavior, or hold the Tools chip.

**Two modes** (**Settings → Advanced → Book Tools Mode**):

- **Gather then answer** (the default): the AI quietly collects the passages it needs first (a small status window shows "Consulting book tools…", then "Searching the book…"), then streams a normal answer with those passages included. Web search stays available during the answer. Recommended: grounded answers and streaming.
- **Interactive**: the original agentic loop; the AI narrates as it searches and reads. Responses do not stream during the tool turns and web search is off, so expect a short wait. Its closing request keeps the same instructions as the rest of the run, with the closing note added as a message, which the newest Claude models require.

**On or off** (**Settings → Advanced → AI Book Tools**, off by default): whether the **Tools** chip in a book chat starts on. The chip is always there when the session is eligible, so one tap flips tools for a single chat, and the AI still decides per question whether to look anything up (a question answerable from knowledge triggers no lookups). Per book: Book Settings → Chat behavior, or hold the Tools chip for a For-this-book / Global picker that also carries the lookup effort dial and the read-whole size. The per-book value wins over the global one; the chip wins for the current chat once tapped.

**Lookup effort** (**Settings → Advanced → Book Tools Lookup Effort**): **Quick** (2 rounds, 4 lookups), **Standard** (4 rounds, 8 lookups) or **Thorough** (6 rounds, 16 lookups, a larger passage budget) caps how much the AI may look up per question and tells the model its remaining budget, so it plans its searches from broad to narrow instead of being cut off mid-search.

**Providers:** Gemini, Claude (Anthropic), OpenAI (API or Subscription), Amazon Bedrock (the models the contributor probed: [Providers and Models](Providers-and-Models)) and OpenRouter, plus DeepSeek, Mistral, Groq, xAI, Fireworks, Qwen, Kimi, OpenCode Zen, OpenCode Go and A2Agent on tool-capable models, and Ollama locally (a local model's capabilities are derived from the model menu, on pick or with "Refresh model capabilities", before the Tools chip lights up). Each round of lookups normally requires the model to call a tool. A few models refuse that (Claude Sonnet 5.5, Opus 5.5 and Fable 5.1, and some Qwen 3.7 and 3.8 models through OpenRouter, OpenCode and A2Agent), so they are asked without the requirement and decide when to search; rarely, one answers without searching. On DeepSeek, Kimi and the Qwen provider, reasoning is turned off during the lookups (some of their models refuse the forced step while they reason); in the default gather mode the answer written after the lookups reasons as usual. Most community hosts, and custom providers, can use them for a model once **Test provider...** has recorded that it calls tools ([Providers and Models](Providers-and-Models#fetching-and-testing-models)). Providers and models without tool support fall back to normal chat.

**Requires** the book's text: the tools read it ([Privacy and Data](Privacy-and-Data)). On Ask the Send asks the first time (**Allow for this book** keeps your answer); a trusted provider follows its own column, and a book's own **Book text** row (Book Settings → Privacy & Data) wins either way.

**Where it applies:** freeform chat and replies about the open book (book and highlight contexts), and Smart retrieval for two context-aware actions. Not the artifact actions (X-Ray, Summary and the rest extract their own context and stay tools-free, their follow-up replies included), and not general, library or X-Ray chats, or a send that carries a Scope chip pick (which attaches the text itself); a chat about a book that is not open cannot use them either, since the tools search the open book.

**Smart retrieval as a source.** Explain in Context and Analyze in Context offer "Smart retrieval (AI searches the book)" as a fourth source in their scope and source popup, beside full text, summary and AI knowledge: the AI gathers the passages relevant to your highlight and question, then answers from them. It is preselected when the session is tools-capable, and shown grayed with the reason when it is not (an unsupported provider, book text set to Never, a section or range scope); a dialog whose Tools chip is off leaves it offered but not preselected, and so does Quick on for an action that takes it (the preset's Book tools off); a direct entry then skips the silent gather too. "Full document" lets the tools read the whole book; "Up to current position" clamps them to where you are. The direct entry points (a highlight long-press, the dictionary) run the same gather silently.

**Spoiler-aware in code.** The tools follow [Spoiler Protection](Spoiler-Protection) structurally: with protection on (the default) they can only read up to your current page, so the AI cannot read ahead; with it off they can read the whole document, which research papers, non-fiction and finished books want.

**What you see.** After tools ran, the answer's usage line says "Book search (N lookups)", or "Book text read in full" when the whole text was sent (**Settings → Advanced → AI Book Tools: Show Indicator in Chat**, on by default), and the exact searches and page ranges under **Show Sources** in the chat window's gear menu. **Settings → Advanced → AI Book Tools: Show Lookups (debug)** appends the lookups, the raw results and the token usage to each answer; leave it off for clean answers, the raw results can include book text.

## Related

- [Chat Windows](Chat-Windows): Show Sources, Show Reasoning, the usage line.
- [Contexts and Chat](Contexts-and-Chat): the Web, Tools and Quick chips.
- [Providers and Models](Providers-and-Models): which models each provider offers.
- [Book Settings and Book Hub](Book-Settings-and-Book-Hub): the per-book rows for tools, lookup effort, the read-whole size and web search.
- [Artifacts and Caching](Artifacts-and-Caching): the summary as a cheaper source, context windows and costs.
