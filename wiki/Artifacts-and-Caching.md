# Artifacts and Caching

Thirteen actions produce document artifacts: saved, per-book results you can open at any time without running the action again. Every artifact is a reference you can read on its own; the Summary is also reusable as a cheaper stand-in for the book's text. This page covers the artifact types, where to view them, the View / Update / Redo popup, how X-Ray and Recap update incrementally, the summary-as-source pattern, prompt caching, and context windows and costs. The X-Ray itself has its own page, [Using X-Ray](Using-X-Ray).

## The artifacts

| Artifact | Made by | What it holds | Use |
|---|---|---|---|
| **Summary** | Document Summary | a neutral, comprehensive representation of the document | the artifact to reuse: a document source in actions with source selection, replacing the raw text with a compact summary; also a reading reference on its own |
| **X-Ray** | X-Ray | structured data in the categories chosen for the book (by default all but the timeline and argument development): fiction has characters, locations, themes, lexicon and timeline; non-fiction key figures, locations, core concepts, arguments, terminology and argument development; academic ([Research Mode](Research-Mode)) key concepts, foundations, methodology, findings, referenced works, technical terms, figures and data | the browsable X-Ray with categories, search, mentions, distribution and cross-references; needs text extraction; also usable as context in custom actions |
| **X-Ray (Simple)** | X-Ray (Simple) | a prose overview: characters, themes, settings, key terms, where things stand | a text window; a companion guide from AI knowledge, no text extraction; its own saved result beside X-Ray |
| **Recap** | Recap | a "previously on" story refresher | a text window to resume where you left off; updates incrementally as you read |
| **Analysis** | Document Analysis | an opinionated deep analysis | an analytical overview; not recommended as input for further analysis, each layer loses nuance |
| **About** | About | a reader-oriented overview from AI knowledge | background, reception and reading context; no text extraction; web search when enabled |
| **Notes Analysis** | Analyze Notes | an analysis of your highlights and annotations | patterns in what you note; rerun it as your notes grow, to your position or for the whole book |
| **Key Arguments** | Key Arguments | thesis, evidence, assumptions, counterarguments | a text window; source selection (full text, summary or AI knowledge); section scope |
| **Counterarguments** | Counterarguments | the case against the work: steelmanned opposing positions, the weakest links, what would falsify it, who disagrees and why | the adversarial counterpart of Key Arguments; source selection; section scope |
| **Discussion Questions** | Discussion Questions | comprehension, analytical, interpretive and personal questions | source selection; section scope |
| **Quiz** | Quiz | an interactive one-at-a-time quiz with scoring | the quiz window; source selection; section scope; can trigger at chapter ends |
| **Reading Guide** | Reading Guide | a spoiler-free guide to what is ahead: threads, patterns, context, approach | source selection; section scope; updates as you read further |
| **Key Insights** | Extract Key Insights | the important takeaways, novel perspectives, actionable conclusions | source selection; section scope |

Beyond these, **AI Wiki** entries (from the X-Ray browser or from highlighted text) are saved artifacts too and appear in the artifact browser; **generated images** are indexed per book and listed beside the artifacts as a "Generated Images" group ([Image Generation](Image-Generation)); and any chat's last reply can be pinned as a named artifact with the chat window's Pin button, listed beside the generated ones under the name you gave it ([Conversations, Notebooks and Export](Conversations-Notebooks-and-Export)). What the reading actions themselves do is on [Reading Analysis Actions](Reading-Analysis-Actions).

## Viewing artifacts

- **Quick Actions**: tap an artifact action. With a saved result the View / Update / Redo popup opens; without one the action starts, after its scope and source popup where it has one (X-Ray offers **Create X-Ray…**, Analyze Notes asks: to your position or complete). A **View Artifacts** button appears once the book has any, opening a picker.
- **File browser**: long-press a book → **View Artifacts (KOA)** → pick one.
- **Book Hub**: the book's own page lists every artifact with live status beside Book Chat/Action, Chat History, Notebook, Group and Book Settings ([Book Settings and Book Hub](Book-Settings-and-Book-Hub)).
- **Artifact browser**: every book with saved or pinned artifacts, from the ☰ menus of Chat History and the notebook browser or the KOAssistant menu's **Browse Artifacts** row. Its own ☰ menu goes to those two, has **Browse by type…**, and ends with **Quick Settings**. **General (Pinned)** and **Library (Pinned)** rows sit at the top when they exist; each book shows its count of saved, pinned and image artifacts (a book with only images appears too). Tap a book for the artifact picker (Summary, X-Ray and the rest, plus the groups "View Section X-Rays (N)", "View Section Summaries (N)" and the like for each kind of section artifact, "Previous X-Ray Versions (N)" ("Archived X-Ray Versions (N)" once no live X-Ray is left), "AI Wiki Entries (N)", "Pinned Artifacts (N)", "Generated Images (N)", and "Book Hub…" and "Open Book"); a group popup layers over the picker and closes back to it. Hold a book for View, Delete All or Cancel. The browser's ☰ menu also has **Browse by type…**: one kind of artifact across every book, each kind with its count of artifacts, the most first. It lists every kind a book's own list shows (the section kinds, AI Wiki Entries, Pinned Artifacts with the General and Library pins at the top) except the earlier X-Ray versions; a kind's list has one row per book, and tapping a book opens what its own list opens there (a group's popup for the section kinds, wiki entries and pins). **Generated Images** opens the image gallery, pictures without a book included.
- **Input dialog and windows**: the book and highlight input dialogs have a **View Artifacts** button once the book has any (a Menus & Buttons toggle); an artifact window's **Artifacts** button and the end of the X-Ray browser's main list show the book's other saved results.
- **Gestures**: an artifact action can be added to the gesture menu (**Settings → Actions & Prompts → Manage Actions** → hold the action → **+ Gesture Menu**, then restart KOReader).

The window title names the artifact and the book, with how far into the book the artifact reaches when that is short of the end ("Recap (45%)").

**The artifact window's buttons:** row 1 Copy, Artifacts (jump to the book's other saved results), → Group (when the book is in a group), Export and navigation; row 2 → Chat, the MD ON / TXT ON toggle, Info, Update, Redo or Regenerate, Open Doc (with no book open), Delete, Close. **Export** saves the artifact as a Markdown file, named after the book, the artifact and the time and headed by the book, model, date and coverage, in a folder you pick; the Book Hub's ☰ menu has **Export all artifacts…**. **→ Chat** opens a reply box over the artifact; your question starts a chat with the artifact as context, the AI told it is a previously generated artifact and not the book's text, saved as a regular book chat with Reply, Save and Export. X-Ray opens in its browser and Quiz in the quiz window; every other artifact opens in the text window; an old markdown X-Ray falls back to the text window. Position-relevant artifacts (X-Ray (Simple), Recap, Analyze Notes, Reading Guide) show **Update to X%** once you have read on and **Redo** before that; position-irrelevant ones (Summary, Analysis, About, Key Arguments, Counterarguments and the rest) show **Regenerate**, which opens the scope and source popup for an action that has one. With no book open, only About, X-Ray (Simple) and Analyze Notes can regenerate; the others offer Open Doc.

**Info** shows how an artifact was made: the data source (extracted text, the summary or AI knowledge), the model, the date, whether reasoning or web search was used, and the tokens the run cost (in, out and reasoning). An artifact built without text extraction comes from the AI's knowledge, which works for well-known books and less for obscure ones; regenerate with extraction on for better quality.

A chat about an artifact, like attaching one, follows what the artifact was built from: the first time it asks for those kinds when they are still on Ask, and a kind set to Never for the book refuses it ([Privacy and Data](Privacy-and-Data#where-it-is-asked)).

A chat or artifact started from a Book Hub, a group page or the artifact browser while another book is open belongs to that book: its artifacts are saved with it, never listed among the open book's; a summary or analysis of a book that is not the open one offers no Regenerate (open that book first).

## Caching and incremental updates

Every artifact is saved per book; an answer that was cut off is shown but not saved (an earlier copy stays), and so is an X-Ray answer with no entries. X-Ray and Recap also update incrementally: as you read on, an update sends only the text since the last run, and the AI builds on its earlier result instead of starting over, at a few hundred output tokens instead of thousands (a Recap built from AI knowledge runs fresh instead). The place the last run stopped is kept as a position in the text, not only as a page number, so an update after a font or margin change, after turning the device, or on another device whose copy of the book's sidecar folder is synced starts where the last run's text ended (an older result without that position finds its place from its percentage and starts a little early). An X-Ray update also carries an index of the existing entries and merges the AI's new or changed entries in by name; a complete or section X-Ray never updates. Each saved result records whether it was built from the book's text or your highlights, and an update builds on it only while those are still allowed (otherwise it starts over). The X-Ray's updates, free checkpoint installs, versions and storage are on [Using X-Ray](Using-X-Ray#keeping-the-x-ray-current), Recap's on [Reading Analysis Actions](Reading-Analysis-Actions#recap).

**The View / Update / Redo popup** appears wherever an artifact action can be triggered: the Quick Actions panel, gestures, the book chat's action picker. For X-Ray with no saved result it offers **Create X-Ray…** (the coverage and build chooser). With a saved result it starts with **View**; an artifact that follows your position (Recap, Reading Guide, X-Ray (Simple)) then offers **Update** once you have read on by more than 1% ("Update Reading Guide (to 45%)") and **Redo** before that, About offers **Regenerate**, the actions with source selection offer **New …** (their scope and source popup), and Analyze Notes offers an update or redo to your position or **Redo Analyze Notes (complete)**. With the book open, an action that makes section artifacts also lists the ones whose range you are reading in, then the group of all of them.

X-Ray (Simple) is saved as its own artifact beside X-Ray, regenerates fresh on every update (the popup offers it when your position has advanced), and both can coexist.

**Storage.** Artifacts live in the book's sidecar folder (`.sdr/koassistant_cache.lua`, with the X-Ray's archived versions and prepared checkpoints beside it in `koassistant_xray_checkpoints.lua` and `koassistant_xray_ladder.lua`, and the book's pinned artifacts in `koassistant_pinned.lua`), move with the book when you reorganize your library, and are deleted with it when you delete the book in KOReader's file manager.

**Deleting.** One artifact: the window's Delete button; for X-Ray, the X-Ray browser's ☰ menu: **Delete X-Ray** also removes the prepared checkpoints and every AI Wiki entry of the book (those made from highlighted text too) and, when archived versions exist, asks whether to keep them; a section X-Ray has **Delete Section X-Ray**. Everything for the book: the Book Hub's ☰ menu → **Delete all artifacts…**, or hold the book in the artifact browser → **Delete All**; chats, the notebook, pinned artifacts and generated images are kept. Any of these forces fresh generation next time, which also switches between the incremental and complete tracks.

**Requirements and limits.** X-Ray and every action with source selection (Recap, Document Summary, Document Analysis, Key Arguments and the rest) run from reading mode, not the file browser; About, X-Ray (Simple) and Analyze Notes run from the file browser too, reading highlights, annotations, notebook and progress from disk. An incremental update needs the position to have advanced by more than 1%. X-Ray, Document Summary and Document Analysis require extraction; Key Arguments, Counterarguments, Discussion Questions, Quiz, Reading Guide and Extract Key Insights offer source selection; Recap and Analyze Notes work without extraction. Only X-Ray and Recap update incrementally (Reading Guide tracks your position but regenerates in full); complete and section X-Rays always regenerate; section X-Rays need an open book with a table of contents; going backwards in the book regenerates; X-Ray cannot be duplicated in the action manager (its output needs the X-Ray browser), every other artifact action can, but a duplicate is a one-shot chat action with no saved artifact and no updates; an old markdown X-Ray is regenerated in the current format on its next run.

## The summary as a reusable source

For medium and long texts, sending the whole document (100K tokens and more) for every action is expensive and sometimes impossible. The pattern: generate the summary once with Document Summary (a few thousand tokens; the source popup's **Generate summary** does it too the first time), then let actions with source selection use it as the document source. The result is a large token saving and often better answers for repeated questions.

When you trigger an action with source selection, one popup chooses the scope (the full document, up to your position, or a section) and the source (extract the text, use the summary, or AI knowledge only); the two context-aware highlight actions also offer **Smart retrieval**, which needs text extraction and a provider and model that support tool calls, Web Search and Book Tools](Reasoning-Web-Search-and-Book-Tools)). The actions that offer the popup are listed on [Contexts and Chat](Contexts-and-Chat).

A custom action gets the same popup with `source_selection = true` and `use_summary_cache = true`, and `{document_context_section}` as its unified placeholder, which resolves to whatever source you choose ([Template Variables](Template-Variables)). Savings: raw text about 100,000 tokens per query against 2,000 to 8,000 for the summary, so ten highlight queries save roughly a million tokens, and the difference compounds in a conversation because every follow-up resends the full history.

**Artifacts in custom actions.** Three artifacts can be referenced with `{summary_cache_section}`, `{xray_cache_section}` and `{analyze_cache_section}` (X-Ray (Simple) has no placeholder: it is a standalone overview, not data for reuse). The summary is the recommended one; the X-Ray and analysis placeholders are for experiments, and all three vanish when empty, so including them is always safe. Example, a "Questions from X-Ray" action: run X-Ray on a book (allowing its text when asked, or set **Settings → Privacy & Data → Text Extraction → Book text** to Allow, and **Settings → Privacy & Data → Highlights** if you like), create an action whose prompt reads `Based on this analysis:\n\n{xray_cache_section}\n\nWhat are the 3 most important questions I should be thinking about?`, check "Allow text extraction" and "Allow highlight use" in its permissions, and run it: it uses the saved X-Ray without analysing again, and with no X-Ray yet the placeholder is empty and the action still runs. The permissions a placeholder needs follow how the X-Ray was built ([Privacy and Data](Privacy-and-Data#text-extraction-and-double-gating)).

For a document you will query many times, generate the summary early. The artifacts are convenient in themselves: browse a book's X-Ray for a character's aliases and connections, see who appears in the current chapter, search any entry, use Look up in X-Ray while reading, review the Analysis for the arguments, or skim the Summary before returning to a book you set aside.

## Prompt caching

Prompt caching lowers cost and latency by reusing previously processed prompt prefixes. Most major providers do it automatically:

| Provider | Type | Saving | Notes |
|---|---|---|---|
| Anthropic | automatic | 90% | a top-level cache marker: the API places the breakpoint and advances it as the chat grows, so book text and earlier turns cache too |
| OpenAI | automatic | 90% | from 1,024 tokens |
| Gemini 2.5 and newer | automatic | 90% | from 1,024 to 2,048 tokens |
| DeepSeek | automatic | up to 90% | disk-based, from 64 tokens |
| Groq | automatic | 50% | some models (Kimi K2, gpt-oss) |

What is cached is the stable prefix of each request: the system message (behavior, domain, language instruction) and the conversation so far, so book text embedded in the first message is cached on later follow-ups. Each follow-up resends the whole conversation; without caching you pay full price for it every turn, with caching the seen content costs 10 to 50% of the normal rate. The more stable content a conversation starts with, the larger the saving.

An action that saves its result (an X-Ray, a summary, a recap and the other artifact actions) has no follow-up that could read a cache back: the saved result opens, and a chat about it starts from the result. With Claude, directly or through OpenRouter, writing a cache costs a quarter more than plain input, so such a request is sent without the marker for its messages and the book's text is billed at the plain rate: about 18% less for an X-Ray of a whole book (measured on Claude Sonnet 5.5). On Anthropic the system message keeps its own marker (through OpenRouter such a request carries none), and the marker stays on a request that searches the web. The other side: running the very same action again within five minutes pays for the text in full.

## Text extraction limits, context windows and costs

Roughly 100 pages make 100,000 to 170,000 characters (25,000 to 40,000 tokens), depending on the layout and the font size. The default extraction limit is 4,000,000 characters (about a million tokens), configurable up to 10,000,000 (**Settings → Privacy & Data → Text Extraction → Max Text Characters**); the default page limit for PDF, DJVU, CBZ and the like is 2,000 pages, up to 5,000. The default is sized for Gemini's 1M-token context; smaller models hit their limit long before it, and the limit is a safety cap, not a target: **the model's context window is the real bound.** A request whose text exceeds it is rejected by the API, so a **large extraction warning** appears before a request above 500K characters (about 125K tokens), or earlier when the model's known context window is exceeded, with the chance to cancel; **Don't warn about large extractions** under the same submenu turns it off. If the text exceeds the character limit and is truncated, a blocking **truncation warning** shows the covered range ("Extracted text was truncated (covers 0%–85% of the document).") with Cancel or Continue Anyway, before the large-extraction warning; **Don't warn about truncated extractions** turns that one off. KOReader's hidden flows exclude front matter, appendices and endnotes from extraction, which saves tokens and improves results without lowering the limits ([Using X-Ray](Using-X-Ray#hidden-flows-and-tables-of-contents)). Two extraction types exist: `{book_text_section}` reads from the start to your position (spoiler-safe, X-Ray and Recap), `{full_document_section}` reads the whole document whatever the position (Document Summary, Document Analysis and a complete X-Ray; actions with source selection use `{document_context_section}`, which carries the source you pick).

| Provider | Context window | Maximum English text (about 4 characters per token) |
|---|---|---|
| Gemini 3.8 Flash and the other Gemini 3 and Gemini 4 models | 1M tokens | about 4M characters, any book |
| Claude (Sonnet 5.5, Opus 5.5, Haiku 5.5, Fable 5.2) | 1M tokens | about 3M characters, any book (Claude counts about 3 characters per token, see below) |
| OpenAI GPT-6 and GPT-5.6 models | about 920K tokens of input | about 3.7M characters |
| DeepSeek V4 | 1M tokens | about 4M characters, any book |
| others (Mistral, Qwen, Grok, GLM and the rest) | 128K to 1M tokens, by model (a local model: what its server allows) | about 500K to 4M characters |

CJK and other non-Latin text tokenizes at about two characters per token, which roughly halves these estimates.

Cost per request, input only, English (list prices in November 2026; DeepSeek's row is from an earlier check):

| Model | 250K characters (about 60K tokens) | 500K (125K) | 1M (250K) |
|---|---|---|---|
| DeepSeek V4 | $0.02 | $0.04 | $0.07 |
| Claude Haiku 5.5 | $0.01 | $0.09 | $0.17 |
| Gemini 3.8 Flash | $0.05 | $0.09 | $0.19 |
| GPT-6.1 Terra | $0.06 | $0.13 | $0.25 |
| Gemini 4 Hydrogen | $0.09 | $0.19 | $0.38 |
| GPT-6.2 Sol | $0.13 | $0.25 | $0.50 |
| Claude Sonnet 5.5 | $0.17 | $0.35 | $0.70 |
| Claude Opus 5.5 | $0.35 | $0.70 | $1.40 |

The token counts in the header are the usual estimate of four characters per token. Claude's current models count English prose at about three (measured in November 2026: a novel of 681,000 characters, 119,000 words, is 238,000 tokens), so the three Claude rows are computed at about 87K, 175K and 350K tokens. Measured on that novel: an X-Ray of the whole book in one request cost $0.54 on Claude Sonnet 5.5 (by the same count about $0.14 on Haiku 5.5 and $1.10 on Opus 5.5), and built in checkpoints as you read about three times as much. Gemini 3.8 Flash doubles in price on January 1, 2027.

Claude Haiku 5.5 bills a request at five times its base rate, input and output, once the prompt passes 100K tokens, hence the jump between its first two columns. Prompt caching cuts the repeated parts by 50 to 90%; the new content of each turn (your latest question and the previous answer) is charged in full.

**Keeping within the window:** use hidden flows; run X-Ray or Recap early, so each later run sends only the new text (starting an X-Ray at 80% of a long novel sends 80% of it at once); choose the summary as the source; use Smart retrieval for a targeted question; lower the extraction limit to match a small model; keep conversations focused and start a new chat after an action that used the whole text (the plugin warns when a conversation passes about 50K tokens).

**When a provider refuses.** If a request asks for a longer answer than the model allows and the error states the real limit, the plugin retries once at that value and remembers it for the model; a context overflow is retried once when the provider says how much room is left, and that window is remembered until KOReader restarts. Some providers (Groq, Cerebras, OpenAI) count the answer budget a request asks for against a per-minute token allowance, so on a small plan even a short question can be refused; the plugin learns the allowance from the provider's own replies and sizes later requests to fit, resending once with a budget the plan admits (nothing is resent when the minute's allowance is simply spent), and Test provider records it too. A prompt larger than the plan or the context window gets a brief notice and is still sent. A refusal a smaller answer cannot fix names the lever where you are: a smaller scope or a new chat while reading, attaching less in a general chat, fewer folders for a library action; a wait the provider asks for is passed on in seconds. An account limit (credits used up, a spending limit) is told apart from a rate limit, never retried, and the tip says adding credits is the only fix; a background X-Ray step stopped that way reports it and stops trying ([Providers and Models](Providers-and-Models)).

## Related

- [Using X-Ray](Using-X-Ray): the X-Ray, its checkpoints and versions.
- [Reading Analysis Actions](Reading-Analysis-Actions): what each artifact action does.
- [Contexts and Chat](Contexts-and-Chat): the scope and source popup.
- [Privacy and Data](Privacy-and-Data): text extraction and the permissions a saved result needs.
- [Template Variables](Template-Variables): the artifact placeholders.
