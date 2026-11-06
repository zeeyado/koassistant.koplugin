# Spoiler Protection

Spoiler protection keeps the AI from revealing what lies beyond your current reading position when you chat about a book. It is on by default, and one posture drives both the chat layer and the X-Ray layer: what the AI is told, what AI Book Tools may read, which X-Ray checkpoint is installed, and how far a text scope may reach.

## How it works

When protection is on, a short reminder is added to each request (never to the saved chat) telling the AI your current reading progress ("The reader is currently at 42% of this book") and forbidding anything beyond that point, including anything found in web-search results. Your position is read again at every send, so a chat that is already open follows you as you read. Whether protection is on is decided when the chat starts (the chip's value, or what research mode, a Finished book, the book's row and the global setting give); a chat you reopen from the chat history decides again at each reply, from the book's current settings. When reading progress is unavailable, a generic form is used ("The reader has not finished this book"); the same generic form is used when **Reading position** (Settings → Privacy & Data) is off (a trusted provider follows its own column), so your position is never disclosed without consent ([Privacy and Data](Privacy-and-Data)).

Where the position comes from: the live reader for an open book, the saved progress for a book in the file browser, and the generic form when no progress is known (0% or unknown).

## What it covers, and what it leaves alone

Covered:

- freeform chat (the Send button) in book and highlight contexts, and every reply in the same session, resumed chats included: protection follows your live position on each reply;
- book and highlight actions that do not opt out, X-Ray "Chat about this" chats included;
- the scope and source popups: while protection is on (for the book, or switched on with the chat's Spoiler chip) they pre-select **Up to current position** instead of Full document whenever that row exists, and running a scope that reaches past your position (Full document, or a section or range that ends beyond it) asks once, "This covers parts you haven't read yet.", before sending. Consenting to a section or range also lifts the reminder for that one request; consenting to Full document does not ([Contexts and Chat](Contexts-and-Chat));
- the Scope chip in the input dialog: a section or range that starts beyond your position asks "Include it anyway?" first (and, if you agree, lifts the reminder for that request), one that only ends beyond it is trimmed to your position, and a From section pick has to start at or before it;
- artifact actions run on a book that is not open, which has no scope popup: with protection on and the book not read to its end (99.5% or more), they ask once, "This covers the whole book, including parts you haven't read yet."

Left alone on purpose:

- actions that opt out: the artifact-generating family (X-Ray, Recap, Document Summary and the rest, which have their own position handling; About is the exception and carries the reminder in its own prompt), Translate and the dictionary family, and the plugin's internal merge and duplicate runs. A custom action opts out with `skip_spoiler = true` ([Actions and Menus](Actions-and-Menus));
- artifact chats (discussing a result that already exists);
- library and general chats (no book to spoil).

## Controls

For a chat, the first of these that applies decides: the chip, then Research Mode or a Finished book (either turns protection off), then the book's row, then the global setting; with none set, protection is on. X-Ray installs use the same order without the chip.

- **Global:** **Settings → Chat & Export Settings → Spoiler Protection**, on by default; **Settings → Reading & Library → X-Ray → Spoiler Protection** mirrors it.
- **Per chat:** the **Spoiler** chip in the input dialog (book and highlight chats only; a shield reading ON or OFF) flips protection for the current chat without touching your saved settings, and never changes which X-Ray checkpoint is installed. The chip starts in the state your per-book or global default resolves to; on a book in research mode or marked Finished it starts OFF, and tapping it ON protects that chat anyway. The input dialog's gear menu → **Toolbar Buttons…** shows or hides it.
- **Per book:** the Spoiler protection row in [Book Settings](Book-Settings-and-Book-Hub) (Follow global / On / Off) seeds the chip each time the input dialog opens; a long press on the chip opens the same per-book or global picker.
- **Quick Settings panel:** the Spoiler Protection tile reads On or Off for the open book, adding (book), (research mode) or (book finished) when one of those decides. A tap flips the global setting (a note says so when the book's own row, research mode or Finished keeps this book as it is); a long press opens the same per-book or global picker.
- **Stands down on its own:** marking a book **Finished** in KOReader's own status screen, or turning Research Mode on for it (or for all books; a DOI detected in the book does not count), disables protection for that book without changing your stored setting; un-finishing the book restores it. The Book Settings row says so ("off: book finished", "off: research mode"). Marking a book finished does not change text extraction: the artifact actions keep their own position handling.

## With AI Book Tools

With [AI Book Tools](Reasoning-Web-Search-and-Book-Tools) on, protection also bounds the tools in code, not only in words: on, the tools can read only up to your current page, so the AI cannot read ahead; off, they can read the whole document. The same bound decides how much text **Settings → Advanced → AI Book Tools: Read Short Texts Whole** may send.

## With X-Ray

Protection steers the X-Ray's checkpoints. On, checkpoint updates install only up to your reading position, so the entries you open describe only what you have read. Two things are deliberate exceptions: a checkpoint you install ahead of your position on purpose (it asks first), and the card for an upcoming entity, which comes from the next built checkpoint, starts with the name alone and asks before it opens the full entry ([Using X-Ray](Using-X-Ray#upcoming-entities)). Off, in research mode, or on a book marked Finished, the newest built checkpoint installs as soon as it is ready. The Book Settings row **X-Ray updates: Newest first / Follow my position** (Book Settings → X-Ray) matters only then: **Follow my position** keeps that book installing checkpoints by your position, and while protection is on, updates follow your position whatever the row says. Building is separate from installing: a checkpoint can be built ahead of you and waits until you reach it, while an update reads only up to your position ([Using X-Ray](Using-X-Ray)).

In a series, later volumes stay closed: a lookup looks past a book only once that book is read (Finished, or read to its last page, which is 99.5% or more) or its own protection is off, and a confirmation opens a later book by name, one at a time ([Book Groups and Series](Book-Groups-and-Series)).

## Context around a selection

While protection is on, the text sent around a highlight or a looked-up word is clamped on the far side: **Settings → Highlight Settings → Context Under Spoiler Protection** sets how far past the selection the context may reach (nothing after the selection, to the end of its sentence, to the end of its paragraph, which is the default, or no limit). **Settings → Highlight Settings → Context Direction** set to Before the selection only (the default is Both sides) sends nothing after the selection at all, protection or not. The clamp covers a lookup from KOReader's dictionary popup, the dictionary bypass, the highlight menu and the input dialog alike, and the text an image prompt carries around the selection ([Image Generation](Image-Generation)), whose prompt writer is also told to show nothing later in the story than the passage (or, for an illustrated X-Ray entry, than its description); the Ctx chip can change both settings for one chat. Selections made inside the plugin's own windows are not clamped, since they are not the book. See [Contexts and Chat](Contexts-and-Chat) and [Dictionary and Translation](Dictionary-and-Translation).

## In custom actions

For every covered request the instruction is added at send time. A custom action that wants to control where it sits in the prompt can carry `{spoiler_free_nudge}`, which resolves to the instruction while protection is active and to nothing otherwise ([Template Variables](Template-Variables)); the first request of such an action then carries it there only, and replies get the send-time reminder. A few built-ins carry it inline: AI Wiki, Reviews, About.

## Related

- [Using X-Ray](Using-X-Ray): checkpoints, version history, and what "follow my position" installs.
- [Book Settings and Book Hub](Book-Settings-and-Book-Hub): the per-book row and the X-Ray updates row.
- [Contexts and Chat](Contexts-and-Chat): the chips row and the scope popup.
- [Privacy and Data](Privacy-and-Data): Reading position, which the position reminder depends on.
