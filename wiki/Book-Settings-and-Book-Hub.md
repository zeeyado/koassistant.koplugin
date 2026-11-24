# Book Settings and Book Hub

Book Settings is the per-book screen: every value set there applies to that book only, sticks to it (stored in KOAssistant's own file inside the book's `.sdr` folder, so it comes back every time you open the book), and overrides the global default. The Book Hub is the one page per book that gathers its artifacts, chats, notebook, group and settings.

## Opening Book Settings

A book must be in scope, so from the reader or the file browser:

| Entry point | Where |
|---|---|
| **Quick Actions** | the **Book Settings** utility (reading mode); reorderable and hideable like any panel item |
| **File browser** | long-press a book → **Book Settings (KOA)** |
| **The input dialog** | the gear menu → **Book Settings** (book and highlight chats) |
| **The Book Hub** | the **Book Settings** row, with its "N customized" count |

Several per-book values are also reachable from the input dialog's chips: tap **Domain** for the Domain & Research picker, hold **Web** for web search (with its Search depth row), hold **Tools** for AI Book Tools (with lookup effort and the read-whole size), hold **Quick** for the Quick answer default (with the preset's settings), hold **Spoiler** for spoiler protection, hold the **Scope** chip of a highlight chat (it reads **Ctx** there) for highlight context; each picker offers a "For this book / Global" target. Book Settings is the full screen; the chip holds are the fast single-setting switches, and both write the same values ([Contexts and Chat](Contexts-and-Chat)).

## What you can set per book

Each row shows its current value: most read "Follow global (X)" when the book has not set them, and "Follow group X (value)" when the book follows one of its [groups](Book-Groups-and-Series) for that setting. Most open a small picker in which **Follow global** is a choice, and so is following a group that sets the value; many of these pickers also have a **Global** tab beside **For this book**, and Book Settings opens them on the book's tab (the Global tab changes the global default instead). The screen leads with a few headline rows (Domain, Background, Research mode, Spoiler protection, Group) and continues with six sub-screens, each with a badge counting its customized settings (the quiz overrides count as one): **X-Ray**, **Chat behavior**, **Privacy & Data**, **Identity**, **Quiz settings**, **Languages**.

### Headline rows

| Setting | Choices | Notes |
|---|---|---|
| **Domain** | Follow global / None / a domain | opens the **Domain & Research** picker (the one the Domain chip opens), which also holds Research mode and Background ([Prompts, Behaviors and Domains](Prompts-Behaviors-and-Domains)) |
| **Background** | free text; the editor says only the first 2,000 characters are sent (a longer note is kept whole, the rest just does not go out) | a standing note about this book, sent with behavior and domain in its requests ("I'm reading this critically; flag questionable claims"), so it reaches actions, gestures and chats on its own; actions that leave the domain out, such as Translate and the dictionary actions, leave it out too (Reviews is the one built-in that keeps it). There is no privacy switch: writing it is the consent ([Prompts, Behaviors and Domains](Prompts-Behaviors-and-Domains#the-per-book-background)) |
| **Research mode** | Follow global / On / Off | [Research Mode](Research-Mode); Off suppresses it even when a DOI is detected |
| **Spoiler protection** | Follow global / On / Off | [Spoiler Protection](Spoiler-Protection); research mode or a book marked Finished stands it down, and the row says so |
| **Group** | tap: the Group Hub; hold: the memberships popup | the book's group membership ("None" when it is in no group): tap opens its Group Hub (a chooser when it is in several, the memberships popup when it is in none), hold opens the memberships popup, where the book joins a group or starts one |

### Chat behavior

| Setting | Choices | Notes |
|---|---|---|
| **AI Book Tools** | Follow global / On / Off | whether the Tools chip starts on for this book ([Reasoning, Web Search and Book Tools](Reasoning-Web-Search-and-Book-Tools)) |
| **Lookup effort** | Follow global / Quick / Standard / Thorough | how much the book tools may look up per question on this book |
| **Read short texts whole** | Follow global / Off / Small / Medium / Large | how long this book's readable text may be and still go to the AI in one piece instead of being searched (16,000 / 64,000 / 128,000 characters) |
| **Web search** | Follow global / On / Off | the per-book web search default, under the chat's Web chip |
| **Search depth** | Follow global / Light / Standard / Thorough | the web search effort for this book |
| **Quick answer default** | Follow global / On / Off | whether the Quick chip starts on for a new chat on this book, and whether actions that take the Quick preset (such as Explain) run quick when started directly; the chip wins once tapped |
| **Highlight context** | Follow global / None / Sentence / Paragraph(s) / Characters | how much surrounding text goes with highlight chats and actions on this book |
| **Dictionary context** | Follow global / None / Sentence / Paragraph(s) / Characters | the same for dictionary lookups on this book |

### X-Ray

| Setting | Choices | Notes |
|---|---|---|
| **Automatic X-Ray** | Follow global / On / Off | one switch for background upkeep of this book's X-Ray. On covers the first build too, whatever the global setting, and confirms how many background requests it needs before starting; Off always wins. It has no effect on page-based books such as PDF and DjVu, and the row says so |
| **X-Ray updates** | Newest first / Follow my position | whether checkpoint installs may run ahead of your position while spoiler protection is off |
| **Build up to** | Whole book / To the end of a section… (open book) | how far the automatic build goes |
| **New X-Ray preset** | Follow global / Who's who / Characters only / Characters and story / Reference / Everything / Light companion / Deep study | sets the categories, Current State and the depth in one tap; reads Custom when they match no preset |
| **New X-Ray type** | Follow global / Auto / Fiction / Nonfiction / Academic | which schema future creates and rebuilds use; Auto lets the AI decide; updates keep the X-Ray's own type; a type unlike the open book's X-Ray offers a rebuild |
| **New X-Ray depth** | Follow global / Light / Standard / Deep | how much each entry carries in future creates and rebuilds, and in section X-Rays; checkpoints and updates keep the depth the X-Ray started with |
| **New X-Ray categories** | Follow global / a checkbox for each category (one stays checked), and the **Current State** checkbox | the categories (People & characters, Places, Themes & ideas, Terms & vocabulary, Timeline & development) and the Current State section for this book's future X-Rays and section X-Rays; the row lists what is ticked |
| **Carried entries** | Follow global / In their categories too / Separate list only | where the entries carried from a group's other books are listed in this book's X-Ray browser; a display choice, nothing is sent |
| **Checkpoint spacing** | Recommended / every 2.5% to 50% | how far apart the background checkpoints land |
| **Passive marking**, **Marking density**, **Entities to mark**, **Tap marked words**, **Upcoming entities**, **Upcoming entity cards**, **Card shows**, **Matching selections open entries**, **Exact hits open** | Follow global / the global row's choices | nine rows: passive marking on or off, its density, which entities are marked, tap to open, upcoming entities, what an upcoming entity's card shows first, how much of an entry a card shows, matching selections, and how an exact hit opens (Footnote panel, Floating popup, Full entry) |

Everything these rows control is explained on [Using X-Ray](Using-X-Ray).

### Privacy & Data

The book's Privacy & Data screen has the same two tabs as the book's other pickers. **For this book** lists five values of this book's own, **Book text**, **Highlights**, **Annotation notes**, **Notebook** and **Text around what you tap**, then **Book info** and a "How this works…" row; each of the five reads **Follow global (Ask)** (the value for all books), **Follow group …**, **Allow** or **Never**. **Global** lists the eight kinds and Book info with their values for all books. A row opens that setting's own picker on the same tab: **For this book** offers Follow global, a Follow group row when one of the book's groups sets the value, Allow and Never; **Global** offers Ask, Allow or Never for all books (Reading position offers On or Off). The same screen opens from the Quick Settings panel's **Privacy & Data** tile, from the question's **More…** and from a refusal's "Change for this book…". The question an action asks writes these rows too ("Allow for this book", "Not for this book"). A book's Never always wins, even over trusted providers; a book's Allow lifts only the global gate, and actions still need their own data access. The rules are on [Privacy and Data](Privacy-and-Data#per-book-values).

**Book info** decides what the AI is told about this book with every request: **None** sends nothing that names it (no "Book: …" line, and an action's own prompt says "this book" where it would name the title and leaves out the author and any DOI; actions that answer only from what the AI knows about the book say they cannot work without the title); **Title only**; **Title & author** (the default, "Book: Title by Author"); **Title, author & position** adds the reading progress, the current chapter and the page, which needs Reading position (**Settings → Privacy & Data → Reading position**). A chat about a closed book includes its saved reading progress, not the chapter or page. Its picker has the same two tabs with these four levels on both; for all books it is **Settings → Privacy & Data → Book info**.

### Identity

| Setting | Choices | Notes |
|---|---|---|
| **AI title** | Use the book's real metadata / Custom… / Send empty | what the AI is told the book is called |
| **AI author** | Use the book's real metadata / Custom… / Send empty | what the AI is told the author is |

These change only what KOAssistant sends to the AI and shows in its own chat header; KOReader's library metadata is never touched. The override reaches every action, X-Ray and the other artifacts included, through `{title}` and `{author}`. **Custom…** fixes wrong metadata, gives a working title, or uses a name the AI will recognize for a badly tagged file; **Send empty** sends nothing for that field (an anonymous author, a junk title suppressed).

### Quiz settings

Overrides for the chapter-end quiz and the Quiz action on this book, each Follow global by default:

- **Chapter-end quiz:** Follow global, or **Off: never quiz this book**. It can silence the chapter-end prompt for one book but cannot turn it on while the global Quiz on Chapter End is off; the offer's **Not for this book** button sets the same.
- **Question count**, **Difficulty**, **Multiple choice**, **Short answer**, **Discussion:** the same options as the global rows.
- **Chapter level:** which table-of-contents level counts as a chapter for this book's chapter-end quiz: Auto-detect, Top level (Level 1), Level 2, Level 3 or All TOC headings.
- **Min chapter length:** skip the chapter-end prompt for chapters shorter than N pages: No minimum, Follow global, or a page count.
- **Min reading time:** the same for the minutes spent in the chapter.

The global rows and the quiz itself: [Reading Analysis Actions](Reading-Analysis-Actions#chapter-quiz).

### Languages

Four overrides, each Follow global by default: the **AI response language** for every action on this book, the **Translation language**, the **Dictionary language**, and the **Book text language** told to the AI in book-tool sessions. They are explained on [Languages](Languages).

## Resolution and reset

The order is: an action's own override where it declares one, then a chip you set in the current chat, then the per-book value, then the global setting. Privacy values are the exception: a book's Never beats everything, including an allowance given for one run. Follow global means no per-book override. Because per-book values are sticky and silent, the screen shows them: its title reads "Book Settings (N customized)" when the book has overrides, and a **Reset book settings** button (shown then, with a confirm) clears every per-book override at once, group follows included, which is the fix when a global change "isn't taking effect" for one book that was customized long ago. A book follows a group for a setting only once the group's value is written into it: by the **Apply** confirm when the value is set at the group, by the ask when the book joins the group, or by a **Follow group** row in a picker. It then reads the group's value live until it picks its own ([Book Groups and Series](Book-Groups-and-Series#group-settings)).

## The Book Hub

One full-screen page per book with everything KOAssistant knows about it:

- every artifact with its coverage and age ("65%, today"), X-Ray first (an open book without one gets a create route; the earlier versions of a live X-Ray are under its **All versions** row, and a book whose X-Ray was deleted with its versions kept shows an **Archived X-Ray Versions** row instead, so a closed book can get one back); tap a row to view it. **Quiz** also holds the section quizzes: with the book open it opens its popup (View Quiz, the section quizzes, New Quiz…), with the book closed a choice of the quiz and the section quizzes (a book with section quizzes but no whole-book quiz lists them as **View Section Quizzes**);
- **Book Chat/Action**, **Chat History** with its count, **Notebook** (tap to view, hold to edit), **Search in book** (open book; hands off to KOReader's full-text search), **Group** (tap opens the Group Hub, hold the memberships popup, "Add to group…" when ungrouped), **Book Settings** ("N customized") and **Open Book** (closed-book views); a book in a group also gets a bottom-left up-arrow to its Group Hub;
- rows refresh in place as you generate things;
- the title-bar ☰ menu: **Refresh index**, **Export all artifacts…** (as Markdown files, to a folder you pick), **Export saved answers for Anki** (the book's saved translations and definitions as a file Anki imports, see [Export saved answers for Anki](Conversations-Notebooks-and-Export#export-saved-answers-for-anki)), **Browse all books…** (the cross-book artifact browser), **Delete all artifacts…** (with a confirmation naming what it covers) and **Quick Settings** (the [panel](Setup-Gestures-and-Panels#quick-settings), over the page).

Open it from a file-browser long-press ("Book Hub (KOA)", switchable under **Settings → Menus & Buttons → Show Book Hub button**), the KOAssistant menu (open book), the Quick Actions panel, a gesture ("KOAssistant: Book Hub"), the "Book Hub…" row on every View Artifacts surface, a book's row in its Group Hub, or the up-arrow at the top level of the book's X-Ray browser. A chat started from a closed book's hub while another book is open belongs to the closed book: its title, settings, saved position and chat storage are that book's ([Contexts and Chat](Contexts-and-Chat)).

## Related

- [Book Groups and Series](Book-Groups-and-Series): group settings, which a book can follow.
- [Settings Reference](Settings-Reference): the global rows these override.
- [Using X-Ray](Using-X-Ray): the X-Ray sub-screen's rows explained.
- [Privacy and Data](Privacy-and-Data): the per-book privacy values and the question that writes them.
- [Artifacts and Caching](Artifacts-and-Caching): the artifacts the hub lists.
