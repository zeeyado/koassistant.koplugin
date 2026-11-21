# Research Mode

Research mode adapts KOAssistant's prompts, X-Ray schema and web search behavior for academic and research texts. It turns itself on when your document carries a DOI (Digital Object Identifier), so a paper with a DOI needs no setup, and you can turn it on by hand for any book.

## What turns it on

| Trigger | How it works |
|---|---|
| **DOI auto-detection** | When KOAssistant detects a DOI in your document, research mode turns on automatically. |
| **Per-book setting** | Set by hand in the Domain & Research picker or Book Settings, and kept with the book. A book in a group can follow the group's setting. |
| **Global setting** | Set on the picker's Global target; applies to every book without a setting of its own. |
| **Per-action override** | An action can force research mode on or off, whatever the other settings say. |

Whatever turns it on, research mode reaches only chats and actions about a book; general and library chats never carry it.

**Resolution order:** action override > per-book setting > DOI auto-detection > global setting. A per-book **Off** keeps research mode off even when a DOI is detected.

No built-in action carries an override; a file-based custom action can, with `research_mode = true` or `research_mode = false` ([Actions and Menus](Actions-and-Menus)).

A detected DOI turns research mode on for each request about the book as it is made. The Domain chip, the Quick Settings tile and the Book Settings row show only what you have set, and a DOI on its own does not stand spoiler protection down.

## What changes

| Change | What it does |
|---|---|
| **Academic X-Ray** | A new X-Ray uses seven research categories instead of the fiction or non-fiction ones: Key Concepts, Foundations (intellectual lineage, paradigms), Methodology, Findings, Referenced Works (with aliases and connections), Technical Terms, Figures & Data. See [The academic X-Ray](#the-academic-x-ray). |
| **Academic prompts** | About, Find Similar and X-Ray (Simple) switch to research-oriented prompts: the research context, methodology and cited works instead of characters and themes. About gives a research overview (the question the paper addresses, its contributions, its context in the field, its methods, its impact and reception), Find Similar recommends related academic works, and X-Ray (Simple) becomes a research companion. |
| **Research note** | A note added to the system prompt tells the AI the text is an academic or research paper: ground the analysis in the provided text and, if web search is available, use it to verify technical claims, place the paper within its field, look up referenced works or foundational concepts, and search for the DOI for citation context and related work. It rides every request about the book: actions, your own questions in a chat, and chats about its artifacts. |
| **Web search** | Actions that normally run with web search off follow your web search setting instead (the book's own, else the global one): X-Ray, Document Summary, Document Analysis, Key Arguments, Extract Key Insights, Analyze Notes, and on highlights Summarize and Thematic Connection. If web search is on, research texts get web-enriched analysis. Recap, Discussion Questions and Quiz keep web search off. |
| **Spoiler protection stands down** | Research mode on for a book (set for the book, taken from its group when the book follows it, or globally) turns spoiler protection off for that book without touching your stored setting: the chat reminder stops, [AI Book Tools](Reasoning-Web-Search-and-Book-Tools) may read the whole document, and X-Ray checkpoints install as soon as they are built. The Book Settings row says "off: research mode"; Book Settings → X-Ray → X-Ray updates → **Follow my reading position** keeps a book's checkpoints at your position. See [Spoiler Protection](Spoiler-Protection). |

Recap, Key Arguments, Counterarguments, Discussion Questions, Quiz and Reading Guide carry an academic branch in their own prompts (methodology, evidence, the paper's place in its field), which they use for any paper, with research mode or without. See [Reading Analysis Actions](Reading-Analysis-Actions).

## Turning it on or off

Research mode lives in the **Domain & Research** picker, in a "Research Mode" section below the domain list. Open the picker from:

- the **Domain** chip in the chat input dialog;
- the **Domain** tile in Quick Settings;
- **Book Settings**: the **Research mode** row (or the Domain row);
- **Settings → Actions & Prompts → Default Domain & Research** (the row names your default domain), which opens on the Global target.

When a book is in scope, the picker's top row is a target toggle, **For this book | Global**, shared by the domain and research mode. The picker opens on **For this book** whenever a book is in hand; general and library chats use the global target.

- **Book target:** **Follow global (On or Off)** / **On** / **Off**, saved with the book.
- **Global target:** **Off** / **On**, for every book without a setting of its own.

The domain rows above the research section are described in [Prompts, Behaviors and Domains](Prompts-Behaviors-and-Domains), and so is the book's **Background** row, which the picker shows on the book target.

**Where it shows.** When research mode is on for the book (set for the book or globally), the Domain chip swaps its 🏛️ icon for a microscope 🔬 (with **Settings → Display Settings → Emoji → Emoji Menu Icons** on), or puts "(research)" in front of the domain name, so you can tell at a glance. The Quick Settings Domain tile does the same (with Emoji Panel Icons on), or adds "(research)" after the name; it also marks a domain set for this book with "(book)". The Book Settings row reads **Research mode: Follow global (Off)**, **On**, **Off**, or the group the book follows.

**Groups.** A group can set research mode for all its books from its Group Settings, with the same picker ("For this group"): see [Book Groups and Series](Book-Groups-and-Series).

## DOI detection

KOAssistant looks for the book's DOI when you run an action or a chat about it:

1. **The cached result**, instant (checked first).
2. **Document metadata**: the identifier, description and keyword fields (EPUB identifiers, PDF description or keywords).
3. **A first-page text scan**: the text of page 1 is extracted on the device, searched for a DOI pattern, and discarded. This is the most reliable route for PDFs, since publishers print the DOI on page 1. It needs the book open.

After the first action run, the result is cached with the book, so later actions (including from the file browser) use it instantly. When the first-page scan finds no DOI, that is cached too: later runs re-check only the metadata (a DOI added to the book's identifiers or description is found) and never repeat the page scan. Turn research mode on by hand for such a book. From the file browser, without the book open, only the cached result and the metadata are checked.

DOI detection runs whatever research mode is set to: a detected DOI is always available to prompts through `{doi_clause}`. The research mode setting only controls whether the research behavior (the research note, the prompt swaps, the web search change) turns on.

**The DOI in prompts.** When a DOI is detected, the built-in prompts that carry `{doi_clause}` name it on a "DOI:" line, which helps the AI identify the exact paper and its citation context: nearly every built-in book action (not Quiz or Suggest from Library), and on highlights Explain in Context, Analyze in Context, Thematic Connection and AI Wiki. A custom action gets it by including `{doi_clause}` ([Template Variables](Template-Variables)). Library actions carry no DOI.

**Privacy.** The DOI is a public identifier (like a URL). Only the DOI string enters the book's metadata: no document content leaves the device beyond what you've already opted into through the privacy settings ([Privacy and Data](Privacy-and-Data)).

## The academic X-Ray

With research mode on, a new X-Ray uses the academic schema: **Key Concepts**, **Foundations**, **Methodology**, **Findings**, **Referenced Works**, **Technical Terms** and **Figures & Data**, then **Current Position** (an X-Ray up to your position) or **Conclusion** (one that covers the whole document). The categories are discipline-agnostic: the prompt tells the AI to adapt its categorization to the field (a physics paper has different natural categories than a sociology study or a philosophy paper), and to leave Figures & Data out when a paper has no significant figures or data.

The X-Ray browser works identically: category navigation, search, chapter appearances, AI Wiki, linkable cross-references and all its other features carry over. Academic X-Rays use the same two-track design (incremental vs complete) and support section X-Rays. The category, depth and Current State picks for new X-Rays don't apply to them: an academic X-Ray always uses the whole research schema.

**The X-Ray type decides too.** With the type on **Auto** (the default), research mode picks the academic schema. **Academic** uses it for a book's new X-Rays even with research mode off (that X-Ray request then also gets the research note and the web search change), and **Fiction** or **Nonfiction** keeps a book's new X-Rays on that schema even with research mode on. Set the type in **Settings → Reading & Library → X-Ray → Type of New X-Rays**, or per book in Book Settings → X-Ray → New X-Ray type. See [Using X-Ray](Using-X-Ray).

## Updates keep their track

When you update an existing artifact (for example "Update X-Ray to 50%"), the update keeps the track the artifact was built with: a non-fiction X-Ray stays non-fiction even if research mode is now on, and an academic one stays academic after you turn research mode off. **Redo** regenerates from scratch with the current research mode setting.

## Tips

- **Good metadata matters.** DOI detection works best when your documents have clean metadata. Use Calibre or your reference manager (Zotero, Mendeley) to put the DOI in the document's identifier or description fields. For PDFs without a DOI in their metadata, the first-page scan catches most academic papers, since publishers print the DOI on page 1.
- **Research mode without a DOI.** For academic books, textbooks or research-adjacent texts that have no DOI, turn research mode on by hand in the Domain & Research picker. You get the academic X-Ray schema, the research note and the web search change: everything except the DOI-specific prompt enrichment.
- **Give the AI the text.** The AI may not recognize a research paper from its title, so X-Ray (Simple) and other answers from AI knowledge are limited for papers. Enable text extraction for meaningful output ([Privacy and Data](Privacy-and-Data)).
- **More reasoning for dense texts.** For short, dense works (research papers, academic chapters, technical documents under about 100 pages), more reasoning can significantly improve an X-Ray or a Document Analysis: see [Reasoning, Web Search and Book Tools](Reasoning-Web-Search-and-Book-Tools).

## Related

- [Using X-Ray](Using-X-Ray): the X-Ray browser, its two tracks, section X-Rays and the type setting.
- [Reading Analysis Actions](Reading-Analysis-Actions): Recap, summaries, analyses and quizzes, which adapt to papers.
- [Prompts, Behaviors and Domains](Prompts-Behaviors-and-Domains): domains, the other half of the Domain & Research picker, and the per-book Background.
- [Spoiler Protection](Spoiler-Protection): why research mode turns protection off, and how a book is pinned back to your position.
- [Book Settings and Book Hub](Book-Settings-and-Book-Hub): the per-book research row beside the other per-book settings.
- [Template Variables](Template-Variables): `{doi_clause}` for custom actions.
