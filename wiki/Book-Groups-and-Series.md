# Book Groups and Series

A group is a named list of books: a series, a project on one subject, or just a list. The X-Rays of a series or a project share what they know, on their own and for free, and you can link names by hand or run an AI merge for one request per book. In a series, reading order is spoiler order: a later book stays out of reach until the books before it are read.

## Group kinds

The kind decides what passes between the books' X-Rays.

| Kind | Order | Between the X-Rays | Later books |
|---|---|---|---|
| **Series** | Reading order, one continued story | What the earlier books' X-Rays know is carried into the later books on its own | Stay out of reach until the books before them are read |
| **Project** | None: books on one subject | What each book's X-Ray knows is carried into every other book on its own | Nothing is held back |
| **Plain** | None: just a list | Nothing is carried; an AI merge between any two X-Rays is still available | Nothing is shared |

Whatever the kind, the books share a hub, a group chat and group settings.

Only a Series is ordered, and its order decides what may feed what: earlier books feed later ones. Switching a series to Project or Plain turns the order off, and everything that depends on it stands down: carrying from earlier books, the series AI merge, the question before a new X-Ray and the "book N of M" labels.

A new group asks **What kind of group?** right after you name it; a tap outside keeps Series. To change the kind later, use **Kind: …** (the row names the current kind) in the Group Hub's ☰ menu, or in the popup you get by holding the group in the Groups list. That popup describes the current kind, and a tap on another kind switches at once.

## How a group's X-Rays share what they know

| Way | What it does | Cost |
|---|---|---|
| **Carried entries** | What the group's other books know waits on this book's carried list and joins its X-Ray on its own when the book introduces it. An entry this book already has gets the other book's description attached. | Free and automatic; nothing is sent |
| **Link** | You say two names are one thing: a carried entry and an entry of this book, two carried entries, or entries of two books. | Free; nothing is sent |
| **AI merge** | The model reads two X-Rays, links names that differ between the books, and writes what the other book adds to the entries they share. | One request per book; the X-Rays are sent, never the books |
| **Merge duplicates** | Two entries of one X-Ray become one (**Find duplicate entities…**, see [Using X-Ray](Using-X-Ray)). | Free; its AI merge option, a combined description, sends a request |

Each is described below: [Carried entries](#carried-entries), [Link](#link-joining-two-names-free), [AI merge](#ai-merge-paid).

## Creating a group

Open the Groups list from Settings → Groups. Its create rows sit at the bottom of the list and in its ☰ menu:

- **New group…**: name it, then pick its kind.
- **New group with this book…** (with a book open): the book's title is prefilled.
- **New group from folder…**: every book in the folder joins, in natural filename order (volume 2 before volume 10, subfolders included), and the folder's name is prefilled.
- **New group from collection…** (when you have KOReader collections): every book of the collection joins, in the collection's own order, and its name is prefilled.
- **New group from series "*name*"…**: the series suggestion, below.

**Series suggestion.** When the open book's metadata carries a series tag, including one typed into KOReader's own Book information editor, and no group has that name yet, a **New group from series "*name*"…** row creates a Series named after the tag, with the book in it. It then offers to find the rest: **Look in a folder…**, **Look in a collection…** or **Not now**. Books whose metadata carries the same series tag are listed for one confirm (**Add all (N)**), and the group sorts itself by series index.

**From a book.** The **Group** row of Book Settings and of the [Book Hub](Book-Settings-and-Book-Hub) opens the book's memberships popup when you hold it, or when you tap it while the book is in no group (the Book Hub's row then reads **Add to group…**). The popup lists each group the book is in (**In *group* (book 2 of 5)** for a series, **In *group* (3 books)** otherwise; tap one for its hub), an **Add to *group*** row for every other group, **New group with this book…** and the series suggestion.

## Adding books and their order

The Group Hub's add rows sit last (and again in its ☰ menu), one per source:

- **Add from history…**: your reading history; tick several books and confirm.
- **Add from files (a book or a folder)…**: tap a book to add just that book, or long-press a folder for all its books. A folder asks **Add all (N)**, **Choose which…** (the picker with every book already ticked, so you can drop a few) or **Cancel**, and adds in filename order.
- **Add from a collection…** (when you have KOReader collections): the same three choices, in the collection's order.

Each picker stays on its own source; its menu filters, searches and confirms. New books join at the end, so an order you set by hand survives. A folder or collection is read once: books added to it later do not join on their own. When the group sets values, the books you add are asked once whether to take them (see [Group settings](#group-settings)).

To reorder, hold a book on the hub: **↑** and **↓** move it one place and the dialog stays open for the next press, and **Move to position…** jumps straight to a slot. The same dialog has **Open this book** and **Remove from group**. In a series the order is the reading order, so it decides which books count as earlier.

## The Groups list

The Groups list (Settings → Groups) shows every group with "Kind · N books" beside it, and an icon per kind if you turn on Settings → Display Settings → Emoji → Emoji Menu Icons. Tap a group for its hub. Hold it for **↑** and **↓** to move it in the list, **Kind: …**, **Group settings…**, **Rename…** and **Delete group…**. Deleting a group never touches the books or their artifacts; only the grouping is removed.

The title-bar ☰ menu repeats the create rows and adds **Sort groups…**: **By name** or **By kind, then name**. A sort reorders the list once; you can still move groups by hand afterwards.

## The Group Hub

A full-screen page per group: the title is the group's name, the subtitle its authors, kind and number of books. Top to bottom:

- **Group Settings…**, with how many values the group sets and how many books do not follow them (see [Group settings](#group-settings)).
- The group's AI merge: **AI merge the series (1 request per book)…** in a series, **AI merge the group into one book (1 request per book)…** in a project (see [AI merge](#ai-merge-paid)). A plain group has none.
- **Series Chat/Action…**, **Project Chat/Action…** or **Group Chat/Action…**: the library chat with every book of the group already selected, for questions and comparisons across them (see [Contexts and Chat](Contexts-and-Chat)).
- The books in order. Tap one for its Book Hub; hold it to move, open or remove it. The open book is marked "open", a book whose file is gone "(missing)".
- The add rows.

The ☰ menu has the add rows, **Kind: …**, **Rename…** and **Delete group…**; the bottom-left up-arrow goes to the Groups list.

Other ways in: the **Group** row of a book's Book Settings or Book Hub (a **Which group?** chooser when the book is in several groups), the **Group Hub** button of the Quick Actions panel (shown only when the open book is in a group), the **→ Group** button in the window of a grouped book's saved artifact (a summary, an analysis and the like), and **Group hub…** in the group's member list (see [Moving between the group's X-Rays](#moving-between-the-groups-x-rays)). A grouped book's Book Hub has a bottom-left up-arrow back to its Group Hub.

## Group settings

A group can hold values for many of the settings a book can, so a series is set up once:

- **Domain**, **Research mode**, **Background** and **Spoiler protection**;
- under **X-Ray ▸**: **Automatic X-Ray**, **New X-Ray preset**, **New X-Ray categories** (with the status block), **New X-Ray depth**, **New X-Ray type**, **Checkpoint spacing** and **Carried entries**;
- under **Privacy & Data ▸**: **Book text**, **Highlights**, **Annotation notes**, **Notebook** and **Text around what you tap**, each Not set, Allow or Never. A group's Never keeps that kind of every member out of every request, trusted providers included, as a book's own Never does ([Privacy and Data](Privacy-and-Data#group-values));
- under **Languages ▸**: the AI response language, translation language, dictionary language and book text language.

Open the screen with the hub's **Group Settings…** row, or **Group settings…** in the Groups list's hold popup. Each row opens the same picker Book Settings uses, with **For this group** in place of **For this book**.

Setting a value asks **Apply *setting*: *value* to all N books in *group*?** (for example "Apply Book text: Never to all 6 books in …?"), and says how many of them have their own value, which it replaces. **Not now** keeps the value at the group without writing it into the books. A book that follows the group reads the group's value live; its Book Settings row and the pickers show **Follow group *name* (*value*)**. A book that picks its own value stops following the group for that setting, and a notice says so; the **Follow group…** row in a picker makes it follow again. The screen lists the books that do not follow in **Re-apply to all (N not following: …)**, which writes every group value into every book.

Books added to a group that sets values are asked once per batch whether to take them, with each setting and its value named: **Apply** or **Keep their own**. A book that leaves the group, and every book of a deleted group, goes back to the global settings for what it followed from the group. **Clear all group settings…** does the same for every book at once, and clearing a single value at the group does it for that setting.

How a book resolves each setting (its own value, its group, or global) is on [Book Settings and Book Hub](Book-Settings-and-Book-Hub).

## Carried entries

Carried entries are what the other books of a group know that this book has not met yet: in a series, the people, places, ideas and terms of the earlier books; in a project, those of every other book. They wait on this book's carried list and join its X-Ray on their own the moment an update brings an entry under that name.

### How the carried list fills

- On its own, at no cost: nothing is sent. Building or updating any X-Ray of the group, and any change to the group (books added, removed or moved, the kind changed), refreshes the books' carried lists in the background.
- The carried list follows the group as it is now. When a book leaves the group, the group is deleted, the books are put in another order or the kind changes, each book drops the carried entries, and the "From" lines on its own entries, of the books it no longer takes from: a book that left, every book of a deleted group, in a series a book that now comes after it, everything in a plain group. What an AI merge added stays, and so do an entry you carried by hand (**Add to this book's carried list**), an entry you added from the carried list, and the ones you removed. Putting a book back brings its entries back.
- In a series, a book's list comes from the nearest earlier book with an X-Ray, and that book's own carried list comes along with it, so one book passes on everything before it. In a project it comes from every other book with an X-Ray.
- A book holds a carried list once it has its own main X-Ray. Only X-Rays your privacy settings let the AI read are used: text extraction allowed for that book, or a trusted provider (see [Privacy and Data](Privacy-and-Data)).
- An entry this book already has gets what the other book says about it attached as a line naming that book, also at no cost. "Already has" means an entry of the same kind (a person as a person, a place as a place): the earlier book's character "the Warden" is carried even when this book has the term "Warden".
- A book's timeline (or argument development) and its status block are never carried: they belong to that book.
- When the earlier books name one character differently (a short name in one volume, the full name in the next), the list still shows one row, with the other volume's description as a "From earlier books" line. When two books carry the same entry, each book's text is kept as that book's line.
- Japanese names that a model wrote with "_" or "-" in place of "・" are read as one name, so one character does not become two entries.
- An update request lists only the carried names its new text mentions, and an AI merge request only those the other X-Ray mentions, so a long carried list does not make every request bigger.

### Where carried entries appear

- **The carried list.** The X-Ray browser's **Carried from earlier books** row (**Carried from group** outside a series), with its count, opens it. A list of several kinds opens on one row per category (Cast, World, Ideas and Lexicon in a novel's X-Ray) with its count, **All** for the whole list, and **Other** for entries this X-Ray's type has no category for (a nonfiction concept in a novel's X-Ray, say); a list of one kind opens as one page. On a category's page each row shows the entry's role and the book it comes from (in a series, the book's number: "Book 3"); on **All** and **Other**, its category and book. A long title is shortened so the name stays whole.
- **Inside the categories.** With **Carried entries** at **In their categories too** (the default), each category lists this book's entries first, then a **From earlier books** header (**From the group** outside a series) and the carried ones in name order. A category row counts both ("85 + 900"), and a category this book has not filled yet still shows when other books carry entries for it. They stay carried entries: their page still says they have not appeared in this book yet. Hundreds of carried rows do not slow a category down: a row's details are worked out when it comes on screen.
- **Mentions.** With the same setting, the carried names a chapter mentions are listed under the same header.
- **Search X-Ray.** Matching carried entries are listed under their own header.
- **The text.** Marks cover carried names too (see [Looking things up across a group](#looking-things-up-across-a-group)).

The **Carried entries** setting is **In their categories too** (the default) or **Separate list only**: for all books in Settings → Reading & Library → X-Ray → Carried Entries, for a group in Group Settings → X-Ray → Carried entries, for one book in Book Settings → X-Ray → Carried entries, and in the X-Ray browser's ☰ menu when the book has carried entries. The carried list is there either way. Changing the setting sends nothing and rebuilds nothing.

Carried entries belong to the book's main X-Ray: a section X-Ray or an archived version does not list them.

### A carried entry's page

Tap a carried entry for its page: its name and role, its other names, the book it comes from and its description there, the lines other books left on it ("From earlier books:"), and a closing note that it has not been seen in this book yet and is linked on its own when an update names it. Its buttons:

- **Open in *Title*'s X-Ray**: the entry in the book it comes from, when that book's X-Ray still has it.
- **Link to an entry of this book…**: for a name that changed between books (a short name here, the full name carried). Pick the entry (from the same category; a long category has a name filter); it takes the carried entry's names and its history, and the row leaves the carried list. Free: nothing is sent.
- **Add as a new entry**: after a confirm, it becomes an entry of this book's X-Ray. It stays an entry across checkpoint installs and rebuilds until you move it back with **Move back to carried list** in the entry's **More…** popup.
- **Remove**: takes it off this book's carried list for good. Neither the automatic carry nor a checkpoint install brings it back; adding it again by hand from the other book's entry does.
- **←** goes back to the list the page was opened from; **◀** and **▶** step through that list.

Rebuilding an X-Ray, or installing a checkpoint, carries the carried list forward instead of destroying it, and a row that comes back after a rebuild still names its book.

## Link: joining two names (free)

Link tells KOAssistant that two names are one thing. It never sends a request.

### Possible matches

The carried list finds likely pairs for you. When a carried name looks like an entry of this book or like another carried name, the list opens with a **Possible matches** row and the count. A pair is proposed for the same name with other capitals or spacing, a shared name or alias, or, for people and places, one name inside the other, such as a first name here and the full name carried. A word more than three entries share, such as a title or a family name, proposes nothing.

The review lists the pairs **With this book's entries** first, then **Between carried entries**, each with its reason: "same name", "shared alias" or "contained name". A pair opens with both descriptions and the book each comes from (**Full descriptions…** shows them whole):

- **Link**: joins them. A carried entry linked to an entry of this book gives it its names and history; two carried entries become one.
- **Never suggest this pair**: keeps them apart. The pair goes on this book's never-merge list, which you undo under **Never-merge pairs** in **Find duplicate entities…**. AI merges into this book are told to keep those pairs apart too.

Below **Possible matches**, the **AI merge…** row offers the [AI merges between books](#ai-merge-paid) for the names no rule can match.

### Linking an entry with another book's entry

In an entry's **More…** popup, **Link with a group member's entry…** asks for a book of the group, then for its entry. Each book's entry gains the other's names as aliases, so the jumps between the books' X-Rays and future AI merges treat them as one. No content is copied.

### Adding another book's entry to this book

An entry found in another book of the group (by a lookup, a card or the search) opens read-only with **Open in *Title*'s X-Ray** and **Add to this book's carried list**: it then waits on this book's carried list like any carried entry, at no cost. The row reads **Already in this book's X-Ray** or **Already on this book's carried list** when that is so, judged by an entry of the same kind. Adding needs text extraction allowed for the other book, or a trusted provider.

## AI merge (paid)

An AI merge asks the model to combine two X-Rays. It matches entries by name, alias and description (a role in one book can be a name in the other), links the names that differ, and writes what the other book adds to the entries the two share. Every row, confirm, progress line and result of a paid merge says **AI merge**, and every row ends with its request count.

### What is sent and what changes

- One request per book: the two X-Rays are sent, never the books.
- This book's entries are kept exactly as they are. What the other book knew is attached to each shared entry as a background line naming that book. Entities of the other book that matter for this one can arrive as new entries, and the rest go on this book's carried list. This book's timeline and status block are never touched.
- It brings in everything the other X-Ray covers, later events included. A book that comes later in the series can be merged in; the confirm cautions that its background includes events beyond this book.
- The receiving X-Ray is archived first, so an AI merge can be undone from **All versions**.
- Every confirm says how many requests it will send, and whether a book was merged in before. Merging one book again sends both X-Rays again, which is worth it only when one of them has changed. The series and project merges skip the books already merged and up to date (**AI merge new only**), run again the ones whose X-Ray changed, and can run everything again (**Re-run all**, **AI merge all**).
- It needs both X-Rays readable under your privacy settings: text extraction allowed for each book, or a trusted provider. A merge missing that for a book does not start.
- When the two books share nothing, it says so and changes nothing. When the merge may have left one figure under two names, it offers **Review duplicates…**.
- The X-Ray browser's ☰ menu → **Info** lists the books AI merges brought in under **Includes background from:**, each "up to date" or "changed since the AI merge".

### The AI merge rows

| Row | Where | What it does | Requests |
|---|---|---|---|
| **AI merge with another book (1 request)…** | **Link and merge…**, the carried list's **AI merge…**, **AI merge X-Rays…** in the member list | Merges one book you pick into this one. The group's books come first (the earlier ones nearest first), then every other book with an X-Ray, under **Other books with an X-Ray (N)…**. | 1 |
| **AI merge the series (1 request per book)…** | **Link and merge…** (a book with two or more earlier books), the Group Hub | Merges each book's X-Ray into the next one's, oldest first (1 into 2, 2 into 3, and so on) up to this book, so every book ends up carrying what the books before it know. It changes the X-Ray of every book after the first; each is archived first. From the hub it runs to the last book with an X-Ray. | 1 per merge: one fewer than the books it covers |
| **AI merge the group into this book (1 request per book)…** | **Link and merge…** (a project) | Merges every other book's X-Ray into this one. The other books are not changed. | 1 per other book with an X-Ray |
| **AI merge the group into one book (1 request per book)…** | The Group Hub (a project) | Asks which book receives, then as above. | 1 per other book with an X-Ray |

Books without an X-Ray are skipped, and the confirm says how many. The receiving book needs its own main X-Ray. A project merge archives this X-Ray at every step, and only as many versions are kept as Settings → Reading & Library → X-Ray → X-Ray Versions to Keep: with that many steps or more, the version from before the run may drop out of the list, and the confirm says so.

### The question before a new X-Ray in a series

When you create a book's X-Ray in one request and the previous book of its series has an X-Ray, a question comes first. It says what happens on its own (the earlier book's knowledge is carried in for free: its names stay linked, and what it says about a person, place or term is attached when this book has that entry) and what an AI merge would add. The choices:

- **Just this book**: no AI merge.
- **Also AI merge when done (1 request)**: merges the previous book in once the new X-Ray is saved.
- **AI merge the series (N requests)**: offered when the previous book has not been merged with its own earlier books, so a merge with it alone would not bring their knowledge.
- **Cancel**: no X-Ray.

Whatever you answer, the new X-Ray's request lists the earlier book's names, so a recurring character, place or term can be linked to its earlier name even when this book calls it something else. Every new X-Ray of a later book in a series gets this list, built in one request or in checkpoints, and so does a rebuild. It rides in the X-Ray's own request, so it adds no request of its own. When the previous book has no X-Ray at all, a note after the create says to build one there to carry its knowledge forward.

## The Link and merge group

The X-Ray popup and the X-Ray browser's ☰ menu show the same **Link and merge…** group, in this order:

1. **Carried from earlier books (N)…** (**Carried from group (N)…** outside a series): opens the carried list, where names are linked by hand for free.
2. **AI merge with another book (1 request)…**
3. **AI merge the series (1 request per book)…**, or in a project **AI merge the group into this book (1 request per book)…**
4. **AI merge section X-Rays (N)…**: the book's own section X-Rays (see [Using X-Ray](Using-X-Ray)).
5. **Find duplicate entities…**: Merge duplicates (see [Using X-Ray](Using-X-Ray)).

A row that does not apply is left out. The X-Ray popup shows the group when the book is in a group or has section X-Rays; the browser's ☰ menu has it on every main X-Ray. The Group Hub carries the group's own AI merge row, and the carried list's **AI merge…** row opens the two AI merges between books.

## Looking things up across a group

Looking a name up in a later book answers from the whole group, not only the open book. Tapping a marked word, an exact dictionary or highlight match, an entity card and the X-Ray browser's search all fall back to this book's carried list first, then to the group's other X-Rays, nearest book first. Later books count only as far as [the series reveal](#the-series-reveal) allows.

- Cards and result rows name their source: **Carried from *Title***, **From *Title*'s X-Ray**. A card for an entry that other books of the group also know adds **Also in *Title*'s X-Ray**.
- The browser's search lists the other books' hits in the same results, under a **From *Title*** header per book. A hit from another book opens read-only, with **Open in *Title*'s X-Ray** and **Add to this book's carried list**.
- An entry page lists what the other books' X-Rays say about it under **In other books of the group:**, one line per book. It is for reading only: **Chat about this** still sends this book's entry.
- A lookup that finds nothing says that the earlier books have nothing either.
- Marks in the text also cover the names on this book's carried list and in the group's other X-Rays, drawn the same dotted way as this book's own (in a series, that content is already behind you). A character known under two names across the series is marked under both. A book needs no X-Ray of its own for this: the next volume of a series is marked from the earlier volumes' X-Rays.
- The X-Ray popup's **Marking & lookup…** row says what the marks and lookups read (this book's X-Ray, its section X-Rays, the other books in its group), and a book whose only X-Rays are those of other books in its group has the row too.

## The series reveal

In a series, lookups look past a book only once it is read (marked **Finished**, or read to its last page) or its own spoiler protection is off (globally, for that book, or by research mode). The first book of the chain that is still unread and protected hides every book after it, whatever their own settings: volume 3 stays out of reach while volume 1 is unread and protected. See [Spoiler Protection](Spoiler-Protection).

- When a later book with an X-Ray is held back, the search results and the no-results message carry a row naming it: **Search *Title* too (may contain spoilers)…**. The row shows whether or not that book has a hit, so it gives nothing away.
- Each confirm (**Search this book**) opens exactly one more book, on its own page (**Results for "…" in *Title***), stacked over the page you confirmed from, so going back steps to the previous book. That page carries the row for the next one. A reveal does not stick: the next search starts at the chain again.
- In the member list (**→ Group**), a held-back book is listed as "(later in the series)" without checking whether the entry appears in it, and opens only after a confirm (**Open it**). The Group Hub's book rows say and ask the same before that book's Book Hub opens, when the hub was reached from an earlier book (its Group button, Book Hub or X-Ray); from the Groups list nothing is held back.
- Marks, entity cards and matching selections never reach past the chain.
- A project shares between all its books in both directions; a plain group shares nothing.

## Moving between the group's X-Rays

In the X-Ray browser, **→ Group** (in the ☰ menu, and in the top row of an entry page) opens the group's member list: its books in order. A book opens its X-Ray at the same entry, or at the same category when it has no such entry. From an entry page the other book's entry opens read-only over the page, with **Open in *Title*'s X-Ray** to switch; that X-Ray's up-arrow at its top level brings you back. A book is marked "(this book)", "(no X-Ray)", "(not in its X-Ray)" or "(later in the series)". Below the books: **AI merge X-Rays…** (a series or a project), **Group hub…** and **Manage groups…**.

The input dialog of a grouped book has a **Group** button that lists the group's books and opens their X-Rays (Settings → Menus & Buttons → Show Group button). In a series, a later volume is marked (later in the series) and asks before it opens.

## Where groups are kept

Groups are stored in KOAssistant's settings folder, not inside the books, and are part of a backup (see [Backups and Updates](Backups-and-Updates)). They survive a book, or a folder of books, moved or renamed in KOReader's file browser, and so do the links the group's X-Rays keep to them (what was AI merged from them, their carried entries), updated a few seconds after the move. A move made outside KOReader (on a computer, say) is not followed. A copy of a book file joins no group. Deleting a book never silently edits a group: the missing book stays listed as "(missing)", so a book on a removed SD card keeps its place in the series, and removing it is up to you.

A book in several groups takes its earlier books, its carried list and its lookups from the first of them in the Groups list. Keep a series above the other groups its books are in: a plain group listed first switches off, for that book, the carry and the lookups of its series. What it has already carried stays as long as any of its groups would give it.

## Related

- [Using X-Ray](Using-X-Ray): one book's X-Ray, its browser, marks and cards, checkpoints, versions and Merge duplicates.
- [Spoiler Protection](Spoiler-Protection): what "read" and "protected" mean for the series reveal.
- [Book Settings and Book Hub](Book-Settings-and-Book-Hub): a book's own settings, following a group, and the Book Hub.
- [Contexts and Chat](Contexts-and-Chat): the library chat that a group's Chat/Action row opens.
- [Privacy and Data](Privacy-and-Data): text extraction and trusted providers, which the carry and every AI merge need.
- [Backups and Updates](Backups-and-Updates): groups are part of a backup.
