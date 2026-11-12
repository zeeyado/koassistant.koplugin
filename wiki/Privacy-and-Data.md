# Privacy and Data

KOAssistant sends data to the AI provider you choose so it can answer you. This page explains what is sent, what is asked for before it goes, and every control you have: the value of each kind of data (Ask, Allow or Never), the presets, per-book values, trusted providers, and the per-action flags of custom actions.

> ⚠️ **KOAssistant asks before it sends your data.** Your highlights, notes, notebook, book text, library scan and reading habits are each on **Ask** by default: the first time an action wants one of them, KOAssistant shows what it is about to send and to whom, and you answer **Allow once** or **Allow for this book** (**Always allow** for the library scan and reading habits). Set a kind to **Allow** in **Settings → Privacy & Data** to skip the question, or to **Never** to refuse it everywhere. Two kinds go without a question unless you change them: your reading position and the text around what you tap ([What Gets Sent](#what-gets-sent)).

This is not privacy theater: the "threat model" is simply users including sensitive data (annotations, notes, content) by accident. You are already being permissive by using online AIs at all, this plugin encourages AI analysis of your reading material, and the available placeholders (template variables) can carry a substantial amount of sensitive data. Reading habits (Ask by default, like the others) are read from KOReader's Statistics plugin locally to derive reading engagement groups; see [Design Choices](#design-choices) for what this means. Best practice is to pick providers thoughtfully, and the very best practice is to use local or self-hosted solutions, such as Ollama (see [Local Processing](#local-processing)).

## What Gets Sent

### Always sent (cannot be disabled)

- Your question or prompt.
- The selected text, for highlight actions.

### Sent by default (for actions that use it)

- **Book info**: what the AI is told about the book, set in **Settings → Privacy & Data → Book info**: None, Title only, Title & author (the default), or Title, author & position (adds your reading progress, chapter and page when Reading position is on). It is never asked and the presets leave it alone. **None sends nothing that names the book**: no book line, and an action's own prompt says "this book" where it would name the title and leaves out the author and any DOI. Book actions that answer from what the AI knows about the book (About, About Author, Find Similar, Historical Context, Related Thinkers, Reviews, X-Ray (Simple)) cannot work without the title, so they say so instead of running; so does any book action run with the source popup's **AI knowledge only**, which sends neither text nor summary (Suggest from Library runs: it sends your library scan). A book can have its own level in **Book Settings → Privacy & Data**; one run can go without it, or with the title and author where None is in effect (**Without book info** or **With book info** in an action's long-press menu, [Actions and Menus](Actions-and-Menus#the-action-hold-menu)); a book or highlight chat about the open book can switch it with **Send book info** in the input dialog's gear menu ([Contexts and Chat](Contexts-and-Chat#the-gear-menu)). A highlight action leaves the book line out when you uncheck **Include book info** in its settings in the action manager, and Book Settings → Identity can change or blank the title and author the AI is told (see [Book Settings and Book Hub](Book-Settings-and-Book-Hub)).
- **Enabled system content**, like your languages, domain and behavior.
- **Reading position**: reading progress (percentage), chapter title, chapters read count, how long ago you last read the book, and the print page number when the book carries a page list. The data used to calculate them (the exact date and time you last read, from KOReader's reading statistics, and so on) stays local. It is on by default because spoiler protection relies on it, and it is the one kind that is never asked: **Settings → Privacy & Data → Reading position** turns it on or off.
- **The text around what you tap**: the bounded text around a selection (the context of a highlight or of a dictionary lookup), your current page (page translate, the Scope chip's "Current page") and the text around an image prompt. A few sentences or one page, never more; it has its own value (Allow by default), independent of the book's text.
- **Per-book Background**: if you have written a standing note about a book in Book Settings (what you're reading it for, how to treat it), it is sent with requests for that book alongside behavior and domain. Most actions that leave the domain out, such as translation and dictionary lookups, leave it out too. There is no separate privacy value: writing it is the consent, and it stays empty otherwise. See [Prompts, Behaviors and Domains](Prompts-Behaviors-and-Domains).

### Asked the first time (Ask by default)

- **Highlights**: your highlighted passages (with their chapter or page), separate from annotation notes.
- **Annotation notes**: your highlighted text with the personal notes you attached. Allowing notes allows highlights; Never for highlights is Never for notes.
- **Notebook**: your KOAssistant notebook for the book, with the dates of its entries.
- **Book text**: actual text from the document (for X-Ray, Recap and others). See [Text Extraction and Double-gating](#text-extraction-and-double-gating).
- **Library Scan**: metadata of the books in your scan folders: title, author, series and reading status, with the progress percentage of books you are reading or have put on hold. Books are grouped by status and ordered by when you last read them; the dates themselves are not sent. Only sent by library chats and by actions that use your library (such as Next Read, Find Similar and Suggest from Library), and only from the folders ticked for that run: your default scan folders, or others you add on the fly ([the folder window](#the-folder-window)).
- **Reading habits**: reading engagement data derived from KOReader's Statistics plugin: curated groups based on reading time and completion patterns (books read extensively, stalled reads, briefly started, recently finished). Raw statistics (session logs, pages per session, reading speed, exact timestamps) are computed locally and **never** sent; only lists of books with rounded labels reach the AI (see [Design Choices](#design-choices)). Only used by library scan actions.

## The Three Values and the Question

Every kind of data has one value, for all books, in **Settings → Privacy & Data**:

- **Ask** (the default): the first time an action wants this kind, a question appears before anything is read or sent.
- **Allow**: it goes without a question.
- **Never**: it never goes. An action that cannot work without it is refused, and an action that can simply runs without it.

### The question

It names the action, the provider the request goes to, and every kind of data the run wants that is still on Ask, with the amount or the source where it is known ("text from this book, up to your position (42%)", "your highlights (12)", "your library scan: the books in the folders ticked below"). Data the run has nothing of is not asked: your reading habits without KOReader's reading statistics, highlights, notes or a notebook the book does not have.

- **Allow once**: this run and the replies of the chat it opens. Nothing is stored.
- **Allow for this book**: sets the book's own value to Allow (Book Settings → Privacy & Data), so this book is never asked again for that kind.
- **Continue without** (when nothing asked is required): the run goes on without those kinds, this time only. Nothing is stored.
- **Allow once, without …** (when a run asks a required kind and an optional one, as Next Read asks your library scan and your reading habits): the required kind goes this time, the optional one stays out.
- **Not for this book** (only when nothing asked is required): the run goes on without those kinds, and the book's own value becomes Never for them, so later runs leave them out too. Change it on the book's Privacy & Data screen.
- **Always allow** replaces "Allow for this book" for the two kinds no book can hold, your library scan and your reading habits: it sets the value for all books (with a trusted provider, the trusted providers' own value).
- A request about no book (an image made outside a book, for instance) has neither "Allow for this book" nor "Not for this book": there is no book to keep the answer.
- **More…**: opens the book's Privacy & Data screen, or the one for all books when there is no book or only the library scan or reading habits are asked, and asks again when you come back (or goes on, when nothing is left to ask). A question judged by a trusted provider's own values opens the settings, where those values live.
- **Cancel**: nothing is sent.

Generate Image with its prompt writer on sends the text around the passage and X-Ray descriptions to two providers: the one that writes the prompt and the one that draws it, which receives a prompt made from them. Each kind must be allowed for both, and the question names both ("Generate Image will send to Anthropic, to write the prompt, and to OpenAI, to draw it"). Its **Continue without** (in place of Not for this book) makes this picture without them and stores nothing, since a Never for the book's text would also stop its X-Ray updates; see [Image Generation](Image-Generation#the-prompt-writer). **Illustrate…** on an X-Ray entry asks the same way for the kinds the entry's description was made from, without Continue without: the description is the picture's subject, so a Never refuses it ([Image Generation](Image-Generation#illustrate-from-x-ray)). A kept image remembers what its prompt carried: drawing that prompt again from the gallery (**Regenerate**, **Regenerate and replace** or **Edit prompt…**) asks the same way for the provider drawing now, and for the prompt writer's provider too when a new Style has it restyle the prompt ("Regenerate will send to Anthropic, to restyle the prompt, and to OpenAI, to draw it"), without Continue without (what a written prompt took from them cannot be taken out), and a Never refuses it ([Image Generation](Image-Generation#the-gallery)).

A required kind (X-Ray's book text, say) on Never is a short refusal that names where the value comes from (this book, all books or trusted providers): **Change for this book…** opens the book's Privacy & Data screen, **Open Settings** the settings. A request over several picked books asks once for the set; each book's own value still decides for its data, and books set to Never stay out.

### The folder window

Outside the library dialog, a run that reads your library (Suggest from Library, Find Similar, the end-of-book suggestion) shows the scan folders it would read in a window before it goes, when Library Scan is on Ask or when the action cannot work without the list (Suggest from Library). On Never there is no window: an action that needs the list is refused, with a button to Privacy & Data.

- **The folders.** The first rows are your default scan folders (**Settings → Reading & Library → Default Scan Folders**), ticked. Below them come the last five folders you added on the fly, unticked. A tap ticks or unticks a folder; a long-press shows its full path.
- **+ Add folder…** picks another folder for this run. It comes ticked and is remembered among the recent folders, but it never becomes a default scan folder.
- **On Ask the window is the question.** The answers sit under the folders: **Allow once**, **Always allow**, **Continue without** (when the action can do without the list, as Find Similar can), **More…** and **Cancel**.
- **On Allow the window has Run and Cancel**, for an action that needs the list. Find Similar shows no window on Allow: it reads your default scan folders or, with none, goes without the list.
- **A folder has to be ticked** for an action that needs the list: until one is, its answer buttons are grayed out. With nothing ticked, Find Similar offers **Continue without**, which runs it without your library scan. Reading habits ride the library's books, so with no folder ticked they do not go either.

No folder has to be set beforehand: the window is where you pick.

**In the library dialog** the folders are picked before the action, under its **Library Scan ▾** ([Contexts and Chat](Contexts-and-Chat#library-mode)), so it has no folder window. Next Read, Discover New, Analyze Library and Challenge My Taste stay grayed out until a folder is ticked there (a default one counts). On Ask, a run asks first and names the ticked folders, with **Allow once, without your reading habits** where the action can also use them; on Allow it just runs. Recommend runs without your library scan when nothing is ticked. The typed Send asks on Ask too, naming the folders, and needs the list when no book is picked under **Items ▾** (it is then the chat's only context).

### Where it is asked

At the moment of need, and nowhere else: when an action starts (from a menu, a gesture, the Quick Actions panel, the highlight menu, the file browser or an input dialog), on the **Run** button of an action's scope and source popup (where the spoiler reminder also sits, so the two are one dialog), when you pick a Scope chip range or turn the Tools chip on and send, when you attach your notebook or chat about it, when you chat about an X-Ray entry whose page lists your highlights, when you generate an image, illustrate an X-Ray entry or draw a kept image's prompt again, when a library chat sends your library scan, and, while the text around what you tap is on Ask, when a lookup, a highlight chat or **Translate Page** would send it. Viewing, browsing and deleting what is already on the device never ask.

A saved result follows what it was built from, wherever it goes: chatting about an artifact (the artifact window's → Chat, Chat about this on an X-Ray entry, the X-Ray's Full View, an AI Wiki article), attaching an artifact or a pinned answer to a chat, writing an AI Wiki article and every AI merge ask the same way for the kinds the result was built from, and a kind set to Never refuses them. Updating a result does too: an update sends the saved result back with the new text, so when an X-Ray or a recap was built with your highlights, the question names it ("the saved X-Ray, which was built with your highlights") beside the book's text, and **Allow once, without your highlights** starts the result over from the text instead. Continuing a saved chat checks the kinds it was given ([Conversations, Notebooks and Export](Conversations-Notebooks-and-Export#chat-history)).

### Background features

Automatic X-Ray and checkpoint builds have no moment to ask while you read, so they need a standing Allow: the book's own value, the value for all books, or a trusted provider. When a book with automatic building on is still on Ask, the engine asks once, in the foreground, at the moment a checkpoint would build: **Allow for this book** writes the book's value and lets it build; **Cancel** pauses automatic building for that book until you start it yourself or reopen the book. The confirm that turns automatic building on asks the same thing with **Allow for this book and start**. A build you start by hand (checkpoints now, one background request) asks before its own confirm, and **Allow once** there covers every checkpoint of that build, never the automatic continuation afterwards.

## Privacy Controls

### Presets

**Settings → Privacy & Data → Preset** names the preset your values match, or **Custom** when they match none, and opens the three with the matching one marked. A pick applies at once; a note then lists the rows it changed ("Book text: Allow → Ask") and what it left alone.

| Preset | What it does |
|--------|--------------|
| **Default (Ask)** | Every value goes back to the one it ships with, the trusted providers' column included: each kind is asked for the first time an action wants it; reading position and the text around what you tap are sent. |
| **Allow everything** | Every kind goes without a question, book text included (it raises token costs). |
| **Block everything** | Every kind set to Never: only your question, the selected text and the book info go (and the behavior, domain and Background texts, which no preset touches); reading position goes off too, so spoiler protection no longer knows where you are. Actions that need more are refused until you allow it. |

A preset sets the values for all books (Default (Ask) the trusted providers' column as well). The trusted providers list, each book's own values, Book info and the default scan folders stay as they are: under Allow everything and Block everything a trusted provider keeps its own column, and a book with its own Allow still sends that kind.

### The kinds of data

The rows sit under the presets in **Settings → Privacy & Data**, each with Ask, Allow or Never. They govern every provider you have not marked trusted.

- **Annotation notes** (default: Ask): your personal notes attached to highlights. Allowing notes allows highlights too. Actions requesting notes degrade gracefully: when notes are not allowed but highlights are, they receive highlights only (labeled "My highlights so far:" instead of "My annotations:"). Used by Analyze Notes, Connect (With Notes), Analyze in Context and actions with `{annotations}` placeholders.
- **Highlights** (default: Ask): your highlighted text passages, without notes. Never here is Never for notes too. Used by Recap, Analyze Notes and actions with `{highlights}` placeholders. X-Ray does not send them: an X-Ray entity page lists the highlights that mention the entry, matched on the device, and they go out only when you chat about that entry. Grayed out while Annotation notes are on Allow.
- **Notebook** (default: Ask): the notebook entries for the book. Used by Connect (With Notes), Analyze Notes, Analyze in Context and actions with the `{notebook}` placeholder, and by attaching your notebook in a chat or chatting about it.
- **Reading position** (default: on): reading progress percentage, chapter title, chapters read count, how long ago you last read the book. On or off, never asked. Used by X-Ray, Recap and other context-aware features.
- **Library Scan** (default: Ask): the same value as **Library Scan** in Reading & Library; see [Library Scanning Settings](#library-scanning-settings).
- **Reading habits** (default: Ask): reading engagement data derived from KOReader's Statistics plugin, shared as curated groups with library scan actions. See [Design Choices](#design-choices).
- **Text around what you tap** (default: Allow): the bounded text around a selection, your current page and the text around an image prompt; independent of book text.
- **Book info** (default: Title & author): what the AI is told about the book; see [What Gets Sent](#what-gets-sent).
- **Text Extraction**: a submenu holding **Book text** and the extraction limits; see [Text Extraction Settings](#text-extraction-settings).
- **Tip: Per-book values**, right under the preset, explains [Per-Book Values](#per-book-values).

### Library Scanning Settings

In **Settings → Reading & Library**, under Library:

- **Library Scan** (default: Ask): the same value as in Privacy & Data. Needed by the scan-based library actions (Next Read, Discover New, Analyze Library, Challenge My Taste) and the Suggest from Library book action. Find Similar and Recommend add your library to their answer when Library Scan is allowed, but don't need it.
- **Default Scan Folders**: the folders a library action starts with, ticked by default (grayed out while Library Scan is Never). Each run can untick them or add others in [the folder window](#the-folder-window); none has to be set. The library dialog starts from them too: its pick lasts while that dialog is open, and with every folder unticked no list is sent. Book actions (Suggest from Library, Find Similar) start from them as well.

A library action needs three things: the Library Scan value (Ask asks at each run, with **Always allow** for all books), at least one folder ticked for the run, and the action's "Allow Library Scan" flag (see [Design Choices](#design-choices)).

### Graceful Degradation

When a kind of data is not allowed, actions adapt automatically. Section placeholders like `{highlights_section}` simply disappear from prompts, so you don't need to modify your actions. For book text, most actions fall back to the AI's training knowledge; see [Text Extraction and Double-gating](#text-extraction-and-double-gating). When an action asked for data it did not get, its response starts with a line that says why, such as *Response generated without: highlights (not allowed for this request)*: "set to Never", "set to Never for this book" or "set to Never for trusted providers" when a value said no, "none found" when there was nothing to send.

Attaching your notebook with the Attach chip in a chat follows the notebook's value like the `{notebook}` placeholder does: on Ask it asks when you pick it, and it will not attach under Never.

### Seeing What an Action Uses

If your device supports emoji fonts, turn on **Settings → Display Settings → Emoji → Emoji Data Access Indicators** (independent of Emoji Menu Icons) to see at a glance what data each action accesses. The marks follow action names in the action manager, Quick Actions, the highlight and dictionary menus and the file browser buttons:

- 📄 document text (directly or through a saved summary, analysis or X-Ray)
- 🔖 highlights only (no personal notes)
- 📝 annotations (highlights with your notes)
- 📓 notebook
- 📚 library catalog
- 📊 reading habits (reading engagement groups)
- 🌐 web search, always on for this action; (🌐) web search through your default, which is on (in an input dialog, through its Web chip)
- (🔍), in an input dialog: the action may search the book with AI Book Tools (smart retrieval is available and the book's text is not set to Never; on Ask the run asks first; the Tools chip only decides whether the source popup preselects it)
- ⚡, in an input dialog with Quick on: the action takes the Quick preset; the buttons without it run as they always do

## Per-Book Values

Every kind that concerns one book's data (book text, highlights, annotation notes, notebook, the text around what you tap) can have its own value for one book in **Book Settings → Privacy & Data**, the book's Privacy & Data screen (its **For this book** tab; the **Global** tab holds the values for all books). A row reads **Follow global (Ask)** (the value for all books), **Follow group …** when the book follows a [group's value](#group-values), **Allow** or **Never**, and opens the same picker as the book's other settings: its **For this book** tab offers Follow global, a Follow group row for each of the book's groups that sets a value, **Allow** (sent without asking for this book) or **Never** (not sent, whatever else says); its **Global** tab sets the value for all books (Ask, Allow or Never). **Book info** comes after the five, with its own levels on the same two tabs. The question writes these rows too: **Allow for this book** sets Allow, **Not for this book** sets Never.

- **A book's Never always wins**, even over [trusted providers](#trusted-providers) and an allowance given for one run, and it binds background features such as Automatic X-Ray too.
- **A book's Allow satisfies only the global gate**: per-action flags still apply (see [Double-gating for Custom Actions](#double-gating-for-custom-actions)).
- Allowing annotation notes for a book implies highlights; Never for highlights is Never for notes too.
- Reading position, the library scan and reading habits have no per-book value.

This lets you keep a kind on Ask or Never for all books and allow it for specific books, or allow it everywhere and fence off a sensitive one. **How this works…** at the bottom of the screen restates these rules.

### Group values

A group can hold the same five values in **Group Settings → Privacy & Data** ([Book Groups and Series](Book-Groups-and-Series#group-settings)). Setting one offers to apply it to every book in the group ("Apply Book text: Never to all 6 books in …?"), a book added to the group is asked once with each value named, and a book follows the group's value until it picks its own. A group's Never works like a book's own: that kind of every member stays out of every request, trusted providers included. Values are set at the group only, never from a book's screen or the question.

A book that is not open is judged by its own values: an action on it from the file browser, or from a chat about that book (opened from its Book Hub, for example), reads its highlights, annotations and notebook from disk under the same gates, and checks that book's settings before it starts. A library action on several selected books applies each book's own values and asks once for the set.

The Quick Settings panel's **Privacy & Data** tile opens this same screen: a tap on the book's tab (the values for all books when no book is open), a hold on the Global tab (see [Setup, Gestures and Panels](Setup-Gestures-and-Panels)).

## Trusted Providers

**Settings → Privacy & Data → Trusted Providers** lists every provider, built-in and custom. Tick the ones you fully trust (for example a local Ollama) and tap Save.

A trusted provider follows its own column of values, **Settings → Privacy & Data → What trusted providers may use**: one row per kind of data, Allow for all of them unless you change it, so nothing is asked for requests that go to a trusted provider. Set a kind to Ask or Never there and it applies to trusted providers only; every other provider follows the rows of Privacy & Data.

- Trust replaces the values for all books only. Each action still needs its own per-action flags, and a [book's Never](#per-book-values) still wins.
- Library Scan still needs at least one folder ticked for the run ([the folder window](#the-folder-window)).
- A trusted provider's Allow is a standing Allow for background features (Automatic X-Ray and X-Ray checkpoint builds): those build without a question.

**Which provider counts.** The value is judged for the provider a request actually goes to: your active provider, an action's own pinned provider, a model picked from the long-press menu of an action or of Send, or the Quick chip's preset model. Pinning an action to a different provider never inherits trust it shouldn't. When the receiving provider may not get something, it is left out of that request:

- book passages gathered by smart retrieval, a notebook or an artifact attached with the Attach chip (in a new chat, a reply, or a chat reopened from Chat History) and the library scan of a library chat, each with a short notice;
- the highlights an X-Ray entry's "Chat about this" carries.

A chat about your notebook from the notebook viewer ("Chat about this notebook") follows the notebook's value for the provider that chat goes to: the book's own value decides first, then the question on Ask, Allow, or a trusted provider; under Never it does not start.

## Text Extraction and Double-gating

Text extraction sends actual book or document content to the AI, enabling features like X-Ray, Recap, Document Summary and Document Analysis, and highlight actions like Explain in Context, to analyze what you've read. **Book text is on Ask by default**: the first action that wants it asks you, with the amount it would send (up to your position, the whole book, a section, or the passages the book tools look up), and **Allow for this book** keeps your answer for the book. Without the text, most actions gracefully fall back to the AI's training knowledge: the AI is explicitly told no document text was provided and asked to use what it knows about the work (or say so honestly if it doesn't recognize it). This works reasonably for well-known titles but will be inaccurate for obscure works, and is basically unusable for research papers and articles the AI hasn't seen. **Exception:** X-Ray, Document Summary and Document Analysis require book text and are refused under Never (see [When an Action Is Blocked](#when-an-action-is-blocked)); use X-Ray (Simple) for a prose overview from AI knowledge.

> **Tip:** If you allow book text but don't want to send the *whole* document, you have finer-grained options: choose "Use document summary" or a specific section in an action's source-selection popup, attach a text range with the **Scope** chip on a freeform chat, or let **AI Book Tools** retrieve only the relevant passages (see [Reasoning, Web Search and Book Tools](Reasoning-Web-Search-and-Book-Tools)). KOReader's Hidden Flows also exclude front matter, appendices and the like from extraction (see [Using X-Ray](Using-X-Ray)).

### Why It Asks

1. **Token costs and context window**: extracting book text uses significantly more context than you might expect. A full book can consume 60K+ tokens per request, which adds up quickly with paid APIs, so you should opt into this cost consciously; the question names the amount for that reason. Large contexts also significantly degrade response quality, especially for follow-up questions. That's why actions with source selection let you choose "Use document summary" instead: your queries run on a previously generated summary (~2-8K tokens) rather than the full document text.
2. **Content awareness** (see [Double-gating for Custom Actions](#double-gating-for-custom-actions)): for most readers of mainstream books the text itself isn't privacy-sensitive. But if you're reading something non-standard, subversive, controversial or otherwise sensitive, be aware that the actual content is sent to cloud AI providers. This is a secondary consideration for most users, but important for some.

### How to Allow It

- Answer the question when an action asks: **Allow once** for that run, **Allow for this book** to keep it for the book.
- For all books: **Settings → Privacy & Data → Text Extraction → Book text**, set to Allow (a notice explains the token cost). Built-in actions (X-Ray, Recap, Explain in Context, Analyze in Context and the others that read text) already have the per-action flag enabled.
- The Quick Settings panel's **Privacy & Data** tile opens the book's Privacy & Data screen, where the Global tab of Book text sets it for all books. AI Book Tools need the same value (a trusted provider satisfies it too).

### Text Extraction Settings

**Settings → Privacy & Data → Text Extraction** (the row reads "Text Extraction (book text: Ask)", Allow or Never). Every row below the value is grayed out while book text is Never.

- **Book text**: Ask (the default), Allow or Never. Allow lets actions extract and send book text without a question: X-Ray, Recap, Explain in Context, Analyze in Context, AI Book Tools and actions with text placeholders (`{book_text}`, `{full_document}` and so on). Setting it to Allow shows a notice about token costs, with a tip about using Hidden Flows to save tokens.
- **Max Text Characters**: the most characters to extract (100,000 to 10,000,000; default 4,000,000, about 1M tokens). The default covers most books with Gemini's 1M-token context; lower it for smaller models. The API rejects requests that exceed the model's context window.
- **Max Pages (PDF, DJVU, CBZ…)**: the most pages to extract from page-based formats (100 to 5,000; default 2,000).
- **Don't warn about truncated extractions**: when unchecked (the default), a blocking warning appears before sending a request whose extracted text was cut to fit the character limit. It shows the coverage (for example "covers 0%–85% of the document") so you know how much of the document was included, and offers Cancel or Continue Anyway. This setting is the way to turn it off.
- **Don't warn about large extractions**: when unchecked (the default), a warning appears before sending a request with over 500K characters (~125K tokens) of extracted text, and below that size when the text likely exceeds the current model's known context window. Most models except Gemini will struggle at this size. The warning offers Cancel or Continue; this setting is the way to turn it off.

### Background Features

[Automatic X-Ray and X-Ray checkpoint builds](Using-X-Ray) extract text and spend tokens **without a per-request confirmation**, under a standing Allow for book text: the book's own value, Allow for all books, or a trusted provider. See [Background features](#background-features) above for how a book still on Ask is asked once.

- They re-check the value when they fire, so setting it to Never stops them.
- Their size is bounded by their own guards: the progress-gap window and incremental checkpoint steps.
- The interactive warnings don't interrupt them. A background extraction cut to fit the character limit aborts the run instead of sending partial text, and a checkpoint step that would be a large request pauses the build ("Checkpoint build paused at N of M: the next step is a large request") until you resume it. Only the first request of a build you start yourself can show the size warning, right after you confirm; accepting it covers the rest of that build.

### Two Text Extraction Types

The placeholder in an action's prompt decides how much is extracted:

- `{book_text_section}`: from the start to your current reading position (used by X-Ray and Recap).
- `{full_document_section}`: the entire document regardless of position (used by Document Summary and Document Analysis).

Actions with a source-selection popup (Explain in Context, Analyze in Context, Key Arguments, Discussion Questions and more) use `{document_context_section}`, which carries the full document, a section, a document summary or the passages smart retrieval found, depending on the source you pick. Every placeholder is listed in [Template Variables](Template-Variables).

### Double-gating for Custom Actions

When you create a custom action from scratch, sensitive data requires both the kind's value (Allow, or your answer to the question) AND a per-action permission flag. This prevents accidental data leakage when you use sensitive placeholders: allowing a kind doesn't automatically expose that data in all your custom actions. A placeholder alone never switches these flags on; you tick them in the action's settings (see [Actions and Menus](Actions-and-Menus)).

> **For built-in actions:** you only answer the question (or set the value). Built-in actions already have the appropriate per-action flags set, and a copy of a built-in action inherits its data-access flags.

Which flags each data type needs (relevant when you create custom actions from scratch):

| Data Type | The value (Settings → Privacy & Data) | Per-Action Flag |
|-----------|----------------|-----------------|
| Book text | Book text | "Allow text extraction" checked |
| X-Ray analysis cache | Book text if the cache was built with text (+ Highlights if it was built with highlights) | The action's `use_xray_cache` field (no in-app checkbox), plus "Allow highlight use" if the cache was built with highlights |
| Analyze / Summary caches | Book text if the cache was built with text | The action's `use_analyze_cache` or `use_summary_cache` field (no in-app checkbox; the built-in actions that offer a summary source carry `use_summary_cache`) |
| Highlights | Highlights (or Annotation notes) | "Allow highlight use" checked |
| Annotations | Annotation notes (degrades to highlights when notes are not allowed but highlights are) | "Allow annotation use (notes)" checked |
| Notebook | Notebook | "Allow notebook use" checked |
| Library catalog | Library Scan + a folder ticked for the run | "Allow Library Scan" checked |
| Reading habits | Reading habits (they ride the library catalog, so Library Scan too) | "Allow reading habits" checked (with "Allow Library Scan") |
| Text around what you tap* | Text around what you tap (Allow by default) | Field `use_surrounding_context` (no in-app checkbox): unset = follow the global Surrounding Context setting (the default for custom actions), `true` = always on (also set automatically when your prompt contains `{surrounding_context}`), `false` = never |
| Per-book values | Book Settings → Privacy & Data (per book; a book's Never beats everything, trusted providers included) | Same per-action flags as above |
| Page text* | Text around what you tap | Automatic when the prompt uses a `{page_text}` placeholder |

\* **Surrounding context** is the text around a highlight (more than you actually selected). It is hard-capped at 2000 characters and belongs to the kind **Text around what you tap**; it only rides along when the Surrounding Context mode (**Settings → Highlight Settings → Surrounding Context**, per book in Book Settings → Chat behavior → Highlight context, or the **Ctx** chip, which is the Scope chip of a highlight chat) is set to Sentence, Paragraph(s) or Characters rather than "None (off)". Dictionary lookups and actions with their own source selection don't use it. Per action it is a tri-state value in the action's Lua definition (not an editor checkbox): leave `use_surrounding_context` unset to follow that setting, or set it to `true` or `false` in a custom action to pin it always on or never. **Page text** is the single currently visible page and belongs to the same kind; it is included only when an action's prompt uses the `{page_text}` placeholder. The Scope chip's "Current page" pick is the same kind; every larger range it attaches is book text.

> **Tip:** turn on **Emoji Data Access Indicators** (see [Seeing What an Action Uses](#seeing-what-an-action-uses)) to see each action's flags on its name, with no need to open its settings.

### When an Action Is Blocked

Built-in actions that cannot work without a kind of data check before anything is sent. On Ask they ask; on Never they stop with a short refusal that names where the value comes from (this book, all books or trusted providers) and a way to change it (**Change for this book…** or **Open Settings**):

| Needs | Actions |
|-------|---------|
| Book text | X-Ray, Document Summary, Document Analysis |
| Highlights or annotation notes | Analyze Notes, Connect (With Notes) |
| Library Scan and a folder ticked for the run ([the folder window](#the-folder-window)) | Next Read, Discover New, Analyze Library, Challenge My Taste, Suggest from Library |

The check follows the same rules as the extraction: a trusted provider is judged by its own column, a book's Never fails it, and for a book that isn't open it reads that book's own values.

With **Book info** at None (for all books, for the book, or for one chat with the gear menu's **Send book info** off), a book action that answers from what the AI knows about the book (About, About Author, Find Similar, Historical Context, Related Thinkers, Reviews, X-Ray (Simple)), or any book action run with the source popup's **AI knowledge only**, stops the same way: it cannot work without the title, and the message says where None is set.

### Highlights, Recap and X-Ray

**Recap** uses highlights, never annotation notes, so your personal notes never reach it. If you want it to see your highlighted passages, answer Allow when it asks, or set **Highlights** to Allow (Annotation notes are not needed for Recap, and would share your notes with the actions that use them); without them it analyzes the book text alone.

**X-Ray does not read your highlights at all.** It works from book text only, and X-Ray (Simple) from AI knowledge only, so the highlights value changes nothing they send. An X-Ray entity page matches your highlights locally and offers them as "Your highlights (N)…" whatever the value; they go to the AI only when you tap "Chat about this", which asks on Ask and leaves them out under Never, and only to a provider that may receive highlights.

### Cache Permission Inheritance

When caches (saved artifacts) are built, they record what data was used. Actions that later reference cache placeholders inherit requirements from what the cache actually contains, and the question lists them:

- Cache built **without text extraction**: no book text needed (the AI used training knowledge only).
- Cache built **with text extraction**: book text needed.
- Recap cache built **without highlights**: no highlights needed.
- Recap cache built **with highlights**: highlights (or annotation notes) also required.
- Older X-Ray caches built before X-Ray stopped reading highlights carry the same requirement until they are rebuilt.

The same check runs when you update an artifact: if a kind its cache needs is not allowed for this run (set to Never, say), the update is skipped and a fresh full generation runs instead.

A result also records the notebook when it read it and the provider that made it, and a result built from another result inherits what that one was built from: Key Arguments run on a document summary built from the book's text counts as built from text. A pinned answer carries the kinds its chat was given. Results saved before v0.24.0 count as built from text, as before, and so do older pins made in a book's chats.

The artifact viewer shows "Based on AI training data knowledge" or "Based on extracted document text", so you always know what a cache contains. If you set a kind to Never after building a cache, actions may render the cache placeholder empty. To fix it, either allow the kind again or regenerate the cache with your current values. See [Troubleshooting](Troubleshooting) if text extraction isn't working.

## Upgrading from an earlier version

Earlier versions had on/off switches. On the first start after the upgrade, every sharing switch becomes **Ask**, the ones that were on included (Reading position keeps its on or off); your per-book values (a book's On or Off) and your trusted providers are kept, since they are exactly "Allow for this book" and "Not for this book". The first time you open KOAssistant, the [Setup Wizard's update check](Setup-Gestures-and-Panels#setup-wizard) says so, and its Privacy step offers **Keep Default (Ask)**, **Allow everything**, **Block everything** or **Decide later** (when the update check does not run, a one-time notice says so instead). The first action that wants a kind of data then asks, and your answer can be kept for the book.

## Local Processing

For maximum privacy, **Ollama** can run AI models entirely on your own device(s):

- Data never leaves your hardware.
- It works offline after the model download.
- See [Ollama's official docs](https://github.com/ollama/ollama) for installation and its [FAQ](https://github.com/ollama/ollama/blob/main/docs/faq.md) for network setup (hosting on another machine).
- Quick start: install Ollama → `ollama pull qwen2.5:0.5b` → select "Ollama" as the provider in KOAssistant's settings.
- For network hosting, open the **Server: …** row of **Settings → Model → Ollama**, tap **Add server...** and enter the machine's address (for example `http://192.168.1.100:11434`). Tap a server to switch to it; hold it to rename or remove it.

**Other local options:** LM Studio, llama.cpp, Jan, vLLM, KoboldCpp and LocalAI all have **one-tap presets**: go to **Settings → Model → Quick setup: Local provider...**, pick your engine, and the name and URL are pre-filled. Just change `localhost` to your server's IP if it runs on another machine. See [Providers and Models](Providers-and-Models) for custom providers.

Anyone using local LLMs is encouraged to open [issues](https://github.com/zeeyado/koassistant.koplugin/issues) or [discussions](https://github.com/zeeyado/koassistant.koplugin/discussions) (feature requests welcome) to help improve support for local, privacy-focused use.

## Provider Policies

Cloud providers have their own data handling practices. Check their policies on data retention and model training, and remember that API policies often differ from those of the web interface.

The **OpenAI Subscription** provider authenticates with your consumer ChatGPT account rather than the API platform. Consumer data-handling and model-training policies differ from the API platform's, so review your ChatGPT account's data settings if you use it.

## Design Choices

### Library Scanning

When Library Scan is allowed (**Settings → Privacy & Data → Library Scan**, or your answer to the question), KOAssistant scans the folders you tick for the run (your default scan folders, or others you add) for book metadata (title, author, series, reading status, progress) to power library-aware features like Next Read and reading pattern analysis (Analyze Library). Your last-read dates only order the list and are not sent. Only catalog metadata is sent, **not** book content, highlights or annotations.

Library scanning is triple-gated:

1. the **Library Scan** value (Ask by default; the question offers **Always allow**);
2. at least one folder ticked for the run: your default scan folders start ticked, and you can add others ([the folder window](#the-folder-window));
3. the action's "Allow Library Scan" flag.

Trusted providers follow their own column for the first gate but still need a folder.

### Reading Engagement Data (Reading habits)

KOReader's Statistics plugin collects extensive local data (reading time, pages per session, reading speed, session history, daily patterns). When **Reading habits** are allowed (**Settings → Privacy & Data**, Ask by default), KOAssistant queries this database **locally** to compute engagement groups, which library scan actions can compose through template variables (`{deep_reads_section}`, `{stalled_section}`, `{briefly_started_section}`, `{recently_finished_section}`):

| Group | Which books | What a line adds |
|-------|-------------|------------------|
| Books read extensively | finished, more than 5 hours of reading | total hours |
| Recently finished | finished and last opened within 30 days | how long ago |
| Stalled reads | past 20%, not finished, not opened for over 30 days | progress and how long since you last opened it |
| Briefly started | not finished, under 30 minutes of reading | minutes read |

In the library list itself, a book with notable engagement gets one short label: "read extensively", "stalled", "opened briefly" or "recently finished".

**What reaches the AI:** only human-readable lists of books, for example `"Title" by Author (47 hours)`. Raw statistics (exact timestamps, pages per session, reading speed, session logs) are used for local computation only and **never** leave the device. The AI sees categorized lists of books, not behavioral data.

**Why it asks:** reading patterns over time create a surprisingly detailed personal profile. Even the curated groups reveal information about reading habits: which books were abandoned, which consumed obsessively, which ignored for months. This warrants a conscious answer rather than a default-on toggle.

## Related

- [Book Settings and Book Hub](Book-Settings-and-Book-Hub): the per-book Privacy & Data, Identity and Chat behavior screens.
- [Actions and Menus](Actions-and-Menus): the action editor's data-access checkboxes for custom actions.
- [Template Variables](Template-Variables): every placeholder and the kind of data it needs.
- [Using X-Ray](Using-X-Ray): Automatic X-Ray and checkpoints, which run under a standing Allow for book text.
- [Providers and Models](Providers-and-Models): local presets, custom providers and the OpenAI Subscription.
- [Troubleshooting](Troubleshooting): what to check when an action finds no highlights or no text.
