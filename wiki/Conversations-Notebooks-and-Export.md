# Conversations, Notebooks and Export

Where chats are kept and how to find them again, what you can do with a saved chat (continue, rename, tag, star, pin, export, delete), the per-book notebook and its Obsidian-friendly storage, exporting to the clipboard or a file, and what happens to all of it when books move or are deleted.

## Auto-save

By default every chat is saved, except dictionary lookups and translations ([Dictionary and Translation](Dictionary-and-Translation#saving-lookups-and-translations)) and the artifact actions (X-Ray, summaries, recaps, quizzes and the like), whose results are kept as artifacts instead ([Artifacts and Caching](Artifacts-and-Caching)). Two rows under **Settings → Chat & Export Settings** control it, both on by default: **Auto-save All Chats** saves every new conversation and its replies; **Auto-save Continued Chats** (it applies when the first row is off) saves the new replies of a chat that is already saved, one you saved with **Save** or continued from Chat History. An unsaved chat is saved on its own before you star or tag it. A chat started about a book that is not open (from a Book Hub, a group page or the artifact browser while another book is open) is saved with that book, not the open one ([Chat Windows](Chat-Windows)).

## Chat History

**Settings → Chat History**: with a book open that has saved chats, it opens that book's chats, and the bottom-left up-arrow leads to the full list; the Chat History tile in Quick Settings always opens the full list. Its ☰ menu goes to the Notebooks and Artifacts browsers, groups the chats by domain (**View by Domain**) or by tag (**View by Tag**), and holds **Delete all chats**.

The document view lists, in order: a **Starred** folder with every starred chat across all documents (shown when any chat is starred), General AI Chats, Library Chats (comparisons and analyses across several books), then the books, the one with the newest chat first. With emoji menu icons on, entries carry a type prefix (💬 general, 📚 library, 📖 book); a starred chat carries a ★ in its list either way. Tap a document for its chat list; hold it for Open Book (books only), Delete All Chats, Cancel.

**A chat's options** (select it): **Continue Chat**, **Rename**, **Tags**, **Star / Unstar**, **Pin Last Response as Artifact / Unpin from Artifacts**, **Export** (clipboard or file), **Open Book** (books only), **Delete Chat**. Chats get a 💬 prefix and tag entries a 🏷️ prefix with emoji icons on.

**Continue Chat** checks what the chat was given before its stored context goes out again: a kind set to Never for the book since the chat stops it, with **Continue without the stored context** (your turns stay; the context saved with the chat is left out of the replies); continuing toward another provider than the one that answered asks once for the kinds still on Ask. Chats saved before v0.24.0 carry no record and open as before.

## Export and save to file

**Export** on a chat in Chat History offers **Copy to Clipboard** (the formatted text) or **Save to File** (Markdown or plain text, in your Export Style). The chat window's own **Export** (in its gear menu) only saves a file ([Chat Windows](Chat-Windows#copy-and-export)).

**What is included** is set under **Settings → Chat & Export Settings → Content Format**: **Export Style** (Markdown, the default, or Plain Text, for Copy, Note and Save to File); **Copy Content** (default Whole chat + metadata); **Note Content** (default Whole chat); **Save to File Content** (default Follow Copy Content); **Chat History Export** (default Ask every time). The formats: **Last response only** (the answer alone); **Whole chat** (a line with the action or chat name and the model, then every message you typed and every answer, in order; the highlighted text is left out; a note saved from an action you typed nothing for is shorter, see [Save to Note](Contexts-and-Chat#save-to-note)); **Whole chat + metadata** (a header with the title, date, book and model, the highlighted text, then your messages and the answers, no context messages); **Everything (debug)** (the same plus every context message, long ones shortened). "Ask every time" shows a picker before each export.

**Where files go**: **Settings → Chat & Export Settings → Save Location**: the **KOAssistant exports folder** (the default, `koassistant_exports/` under KOReader's data folder), a **Custom folder** (the folder picker opens when you pick it), or **Ask every time**. In the exports or custom folder, files are sorted into `book_chats/`, `general_chats/` and `library_chats/`. The **Save book chats alongside books** row (off by default) puts book chats in a `chats/` folder next to the book instead; general and library chats always use the central folder. File names read `[book title]_[chat title]_[YYYYMMDD_HHMMSS].md` (`.txt` in Plain Text), spaces turned into underscores: the book title cut to about 30 characters (left out next to the book), the chat title cut to about 25, and a time. From Chat History the chat title is the saved chat's title (yours if you renamed it) and the time is the chat's last save; from the chat window it is the action's name (none for a typed question) and the time the chat started (its last save for a chat reopened from Chat History).

## Export saved answers for Anki

The answers you saved as notes in a book ([Save to Note](Contexts-and-Chat#save-to-note), the Minimal Popup's **+**, or saved automatically) can be written as a text file that [Anki](https://apps.ankiweb.net) imports, one card per highlight: the passage on one side, its note on the other. Nothing is sent anywhere and no AI request is made.

**To export:** open the book's [Book Hub](Book-Settings-and-Book-Hub#the-book-hub), tap the ☰ menu, then **Export saved answers for Anki**. A notice says how many answers were exported and where the file is. It lands in an `anki/` folder of your export folder (the Save Location above; with **Ask every time** you pick the folder), named after the book.

**In Anki:** **File → Import**, pick the file, choose your note type and deck. The file says by itself that it is tab-separated and holds HTML, and which column is the tags.

**What a row holds:**

| Column | Holds |
|---|---|
| **ID** | When the highlight was made. It never changes, so the same highlight is the same row at every export |
| **Front** | The highlighted passage |
| **Back** | The note as it reads now: the saved answer, with anything you added or corrected. A definition's bold words and lists stay formatted |
| **Book**, **Chapter**, **Page** | Where the highlight is |
| **Kind** | The action that made the answer (Translate, Quick Define, …) |
| **Tags** | `KOAssistant`, the action, and the book's title |

- **Which answers:** those saved by Translate, Quick Define and Dictionary, unless you change the list under **Settings → Highlight Settings → Answers Exported for Anki**. A long explanation kept as a note is left out until you tick its action; ticked, it is exported the next time. Notes you wrote yourself on a highlight with no saved answer are not exported (KOReader's own **Export highlights** has them).
- **Exporting again:** every export writes the whole file again, so export whenever you like and import the same file. Anki recognises the notes it already has: in its import window, **Existing notes** set to **Preserve** adds only the new ones and leaves what you changed in Anki alone, **Update** also brings in notes you corrected in KOReader.
- **Your own note type:** Anki fills a note type's fields from the columns of the same name, so **Front** and **Back** fill Anki's stock note types with no mapping, and the other columns are simply left out there. If your note type has other field names, type them under **Settings → Highlight Settings → Anki Column Names** (three names: the id, the passage, the note) and they fill by themselves too. A note type whose first field is an id (a number or a time of its own) gets the **ID** column there, and the same words highlighted in two places stay two notes.

## Notebooks

A notebook is one persistent Markdown file per book for the AI insights, notes and observations you want to keep, as opposed to chat history, which keeps whole conversations. Custom actions can read it with the `{notebook}` placeholder ([Template Variables](Template-Variables)), and **→ Chat** in the notebook's window ("Chat about this notebook") tells the AI the notebook is your own notes. Both follow the notebook's value: Ask by default (the chat asks the first time, and **Allow for this book** keeps your answer), **Settings → Privacy & Data → Notebook** for all books, a trusted provider, or the book's own value ([Privacy and Data](Privacy-and-Data)).

### Where notebooks are stored

**Settings → Notebook Settings → Save Location**:

| Location | Where | File name |
|---|---|---|
| **Alongside book** (default) | the book's sidecar folder (`.sdr/`) | `koassistant_notebook.md` |
| **KOAssistant notebooks folder** | `koassistant_notebooks/` in KOReader's data folder | `Author — Title.md` |
| **Custom folder** | any folder, an Obsidian vault for instance | `Author — Title.md` |

Changing the location offers to move every existing notebook (Custom folder asks for the folder first); declining keeps the old location. A notebook outlives its book. When you delete a book in KOReader, a notebook stored alongside it is moved to the KOAssistant folder (`koassistant_notebooks/`) under the book's name and a message says where it is; central and custom-folder notebooks stay in their folder. Browse Notebooks lists each of them with the words **(book not on this device)**. A notebook with nothing in it goes with the book, and deleting a whole folder in KOReader takes the notebooks stored inside it along.

**Obsidian and synced folders.** Point the custom folder at your vault (or any synced folder) and notebooks are regular vault files: named `Author — Title.md` for discovery (cut to 100 bytes on a whole character; a second book with the same author and title gets `Author — Title (2).md`), with YAML front matter (title, author, book path, creation date, visible in Obsidian's metadata panel), in standard Markdown that any editor, plugin or sync service handles. The em-dash separator keeps them apart from the `obsidian-koreader-highlights` plugin's `Author - Title.md` (a hyphen): highlights and notebooks are different content, so different files are right.

### Saving to a notebook

- **From the highlight menu:** select text in the book and tap **Add to notebook (KOA)**; the selection is appended to the book's notebook (created if needed) with a timestamp and page information, no AI call. The button is off by default; the **Show Add to Notebook button** row under **Settings → Menus & Buttons** turns it on, effective the next time the menu opens.
- **From the chat window:** the **Notebook** button (book chats only) offers **Add Chat to Notebook** (the latest answer, with the chat's first question and its highlighted text), **Add (choose format)...** (the same, as Question + Response or Last response only this once), **View Notebook** and **Edit Notebook** (both over the chat window); with no notebook yet only the two Add rows show, and the first save creates it.
- **From a text selection:** select two or more words (or hold one word longer) in any book-scoped KOAssistant window (the chat window, the X-Ray browser, the quiz, the Sources and Reasoning viewers, and with enhanced text selection KOReader's own text viewer and dictionary popup) and tap **Add to Notebook**; the selection is appended with a timestamp header. General and library chats have no book to target, so the button is hidden there. A toast names the book, which matters when the window's content belongs to a book other than the open one.

**What is saved** (**Settings → Notebook Settings → Content Format**): **Response only**; **Q&A** (the highlighted text, your question, the answer); **Full Q&A** (the default and the recommended one: the same plus anything attached with the Attach chip, notes, artifacts, chats, files; the generic book-context messages are left out, a notebook being book-specific already). Every entry carries the timestamp, the action's name and, with the book open, the page, the progress and the chapter title.

### Reading and editing a notebook

- **Browse all notebooks:** **Settings → Browse Notebooks**, newest change first; its ☰ menu goes to Chat History and the artifact browser.
- **From the file browser:** long-press a book → **Notebook (KOA)** (when one exists).
- **From the chat window:** the Notebook button's View or Edit.
- **Outside KOReader:** the `.md` file opens in any Markdown editor or in Obsidian.

Tapping a notebook in the browser offers **View**, **Edit**, **Open Book** and **Delete Notebook**; a notebook whose book is not on this device offers **View** and **Delete Notebook**. View opens it in the chat window with Copy, Export (a copy of the file, into a folder you pick), the MD / TXT toggle, → Chat, **Open in Reader** (KOReader's full reader, with Markdown rendering and page navigation) and Edit; Edit opens the text editor. **Settings → Notebook Settings → Viewer Mode** makes KOReader's reader the default viewer instead.

Notebooks are cumulative (new entries append), portable (plain `.md`), migrated with their front matter added or stripped when the location changes, and, in the central and custom folders, relinked on their own: a book that lost its settings and is added again finds its existing notebook by the generated file name, while another book of the same name that is still where the notebook's front matter recorded it keeps its own.

| | Notebooks | Chat History |
|---|---|---|
| Purpose | curated insights | full conversation logs |
| Storage | one `.md` file per book | many chats per book |
| Content | chosen answers and notes | the complete back-and-forth |
| Editing | by hand, any time | fixed once saved |
| Format | Markdown, Obsidian-compatible | structured data |

## Tags, starring and pinning

**Tags** are plain labels: no context attached, added or removed at any time, several per chat. Add them with the chat window's **#** button or a chat's **Tags** option in Chat History; browse by tag from Chat History's ☰ menu.

**Starring** marks a whole conversation worth coming back to: a ★ prefix, and a place in the Starred folder at the top of Chat History. A starred chat stays an ordinary chat you can continue.

**Pinning** keeps one answer: it snapshots the chat's last AI response as a named, read-only artifact. A naming dialog is pre-filled with the action's name and the first line of the answer, cut to about 50 characters (or the chat's title when pinning from Chat History), and you can edit it. Pinned artifacts sit beside the generated ones, under your name: a book's pins in the **Pinned Artifacts** row of its artifacts (artifact browser, Book Hub, View Artifacts), each opening in a window marked "(Pinned)" with a **Delete** button; general and library pins under **General (Pinned)** and **Library (Pinned)** at the top of the artifact browser, where holding one offers **Rename** and **Delete**. They are stored with the book (in its sidecar folder), or globally for general and library chats, and move with the book. Pinning captures the most recent answer, usually the refined one after a few turns; a newer answer can be pinned again. The chat it came from is untouched, and deleting the pin does not touch the chat ([Artifacts and Caching](Artifacts-and-Caching)).

Both are reached from the chat window's **Pin / ★** button (a popup with Pin Last Response as Artifact and Star Conversation, whose labels turn into Unpin from Artifacts and Unstar Conversation) and from a chat's options in Chat History, for new and reopened chats alike.

## Where chats live, and what moves with a book

Chats sit in three places: **book chats** next to the book, in the `.sdr` folder's `koassistant_chats.lua` (the plugin's own file; per-book settings sit beside it in `koassistant_book_settings.lua`); **general chats** in `koassistant_general_chats.lua` and **library chats** in `koassistant_library_chats.lua`, both in KOReader's settings folder. So book chats travel with the book when you move or copy it, nothing is lost when you reorganize your library, and the indexes stay in step when you move, copy, rename or delete books in KOReader's file manager. Moving or renaming a whole folder there is followed too, as KOReader's own History and Collections follow it: the indexes, groups and pictures of the books inside, and the library and index scan folders and the custom notebook and export folders when they are that folder or inside it. A move made outside KOReader is not followed; Rebuild Data Indexes heals the indexes after one ([Backups and Updates](Backups-and-Updates)). Library chats keep the full list of compared books in their metadata and have their own section in Chat History. Pinned artifacts travel with the book too (`koassistant_pinned.lua` in the sidecar folder); general and library pins are stored globally.

**Deleting a book** in KOReader's file manager deletes its KOAssistant data with it: chat history, saved artifacts, pinned artifacts, Book Settings, X-Ray search terms and a sidecar notebook, as KOReader deletes a book's settings, highlights and notes. General and library chats and pins are unaffected; central and custom-folder notebooks survive. KOReader's own **Reset** on a book (file browser long-press → Reset) clears KOReader's reading position, highlights and settings and no longer touches KOAssistant's chats, artifacts or per-book settings.

**Storage modes.** All three of KOReader's metadata storage modes work: "Book folder" (`.sdr` folders beside the books, the default), "KOReader settings folder" (centralized), and "Hash-based". Every per-book file (chats, Book Settings, saved results, notebook, pins, X-Ray search terms) follows the mode, and switching modes moves the files on first access.

**Indexes.** Small indexes map book paths to their chats, notebooks, artifacts, pins and images; a library that got out of step (files copied outside KOReader) heals when you open an affected book, and the Backup & Reset tools validate or rebuild the indexes for a whole folder ([Backups and Updates](Backups-and-Updates#data-indexes)).

**Older installs.** Chats and per-book settings kept in KOReader's `metadata.lua` by old versions are moved into the plugin's own files on first launch (the plugin no longer writes to `metadata.lua`); very old installs with chats in hash folders are offered an import (**Migrate Now** or **Later**), with the old files backed up to `koassistant_chats.backup/`.

## Related

- [Chat Windows](Chat-Windows): the Reply, Save and Notebook buttons, and Export in the gear menu.
- [Artifacts and Caching](Artifacts-and-Caching): pinned responses beside the generated artifacts.
- [Privacy and Data](Privacy-and-Data): whether a notebook may be sent to the AI.
- [Backups and Updates](Backups-and-Updates): backing chats up, the data indexes.
- [Prompts, Behaviors and Domains](Prompts-Behaviors-and-Domains): browsing chats by domain.
