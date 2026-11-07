# Troubleshooting

What to check when something does not work, in the order people usually need it: missing data, text extraction, fonts and icons, keys and connections, menus, and the reset options. Most problems are a setting that is still off or a kind of data set to Never; the first two sections cover almost all reports.

## Features not working or empty data

If Analyze Notes, Connect (With Notes), X-Ray or Recap seem to ignore your reading data: **highlights, notes, the notebook and the book's text are each asked for the first time an action wants them, and a kind set to Never is left out.** Check what you answered (Book Settings → Privacy & Data for the book) and **Settings → Privacy & Data** for all books (**What trusted providers may use** there, for a trusted provider); a refusal names which of the three it comes from. After an update from an earlier version every sharing switch starts on Ask, the ones that were on included ([Privacy and Data](Privacy-and-Data#upgrading-from-an-earlier-version)).

| Feature not working | What to check |
|---|---|
| Analyze Notes or Connect (With Notes) is refused ("needs highlights, which is set to Never") | Highlights set to Never for the book or for all books; set it to Ask or Allow |
| Connect (With Notes) ignores your notes | Annotation notes and Notebook: answer Allow when it asks, or set them to Allow |
| Recap misses your highlights | Highlights: answer Allow when it asks (allowing Annotation notes allows them too), or check for a Never. X-Ray does not use highlights: it reads the book's text only |
| X-Ray is refused ("needs book text, which is set to Never") | Book text set to Never for the book or for all books (**Settings → Privacy & Data → Text Extraction**); set it to Ask or Allow, or use X-Ray (Simple) instead |
| Document Analysis or Document Summary is refused | Book text set to Never |
| Recap uses only the book's title | Book text: answer Allow when it asks, or check for a Never |
| Explain in Context or Analyze in Context use only the title | Book text: pick a text source in their popup and answer Allow, or check for a Never |
| Analyze in Context ignores your highlights or notes | Highlights; Annotation notes add your notes, Notebook your notebook: answer Allow when it asks |
| A custom action with `{highlights}` stays empty | Highlights (or Annotation notes) allowed, and the action's own "Allow highlight use" flag |
| A custom action with `{notebook}` stays empty | Notebook allowed, and the action's own "Allow notebook use" flag |
| A custom action with `{book_text}` stays empty | Book text allowed, and the action's own "Allow text extraction" flag |

**Why:** personal data (highlights, annotation notes, notebook, book text) is not shared with AI providers unasked: each kind is on Ask, the first action that wants it asks, and "Not for this book" in that question sets the book's value to Never. Book text, highlights, annotation notes, the notebook and the text around what you tap can each be set for one book in **Book Settings → Privacy & Data**, and a book's Never wins over the value here, even for a trusted provider. The whole model is on [Privacy and Data](Privacy-and-Data).

Actions that use document text still work without it: they do not fail, the AI is told to use its training knowledge and to be honest about what it does not recognize. For well-known books that often gives reasonable results; for obscure works or papers, allow the book's text. With book text allowed and a provider and model that support tool calls, Explain in Context and Analyze in Context can search the book for the passages they need (**Smart retrieval** in their source popup) instead of sending a full extraction; see [Reasoning, Web Search and Book Tools](Reasoning-Web-Search-and-Book-Tools).

**Quick fix:** in **Settings → Privacy & Data → Preset**, **Allow everything** sends every kind without a question, book text included; **Default (Ask)** brings the questions back. A preset leaves each book's own values alone, so a book set to Never stays that way.

**See what an action needs:** **Settings → Display Settings → Emoji → Emoji Data Access Indicators** adds a suffix to each action's name showing what it accesses (📄 🔖 📝 📓 📚 📊 🌐; the legend is on [Privacy and Data](Privacy-and-Data#seeing-what-an-action-uses)). It needs an emoji font, below.

## Text extraction not working

If Recap, Explain in Context, Analyze in Context or a custom action with `{book_text}` or `{full_document}` return empty or generic answers based only on the title (X-Ray is refused without it; X-Ray (Simple) is the alternative):

**Book text is asked for the first time an action wants it.** If you answered "Not for this book", the book's value is Never: Book Settings → Privacy & Data → Book text sets it back to Follow global or Allow. For all books:

1. Open **Settings → Privacy & Data → Text Extraction**.
2. Set **Book text** to Ask (the question comes back) or Allow (no question).
3. On Allow a notice explains the token cost; that is expected.

For a custom action, also check that the action has **Allow text extraction** on in its settings, and that its prompt uses a text placeholder (`{book_text_section}` or `{full_document_section}`).

Why it asks: extraction sends the book's content to the provider, raises token use and cost, some readers prefer AI knowledge only, and the content may be sensitive. Without it most actions degrade rather than fail: the AI is told that no document text was provided and asked to use its knowledge of the work, with a guard against inventing details for works it does not recognize. X-Ray, Document Summary and Document Analysis are the exception: they are refused when book text is Never ([Privacy and Data](Privacy-and-Data#when-an-action-is-blocked)).

**Quick check:** if a Recap or a context-aware highlight action answers from the book's title and author alone, the book's text was not allowed for that run. X-Ray shows the refusal with a button to the screen that holds the value.

**A scanned PDF has no text to send.** A PDF made of page images (a scan without a text layer) gives no text even with Book text allowed: before an action sends, "No text could be extracted from this document" asks whether to send anyway, in which case the AI answers from its general knowledge, not the book. An X-Ray building checkpoints in the background stops instead. A copy of the PDF run through an OCR tool has a text layer the plugin can read.

## Emoji font setup

Emoji icons in the plugin's menus and buttons (Emoji Menu Icons, Emoji Data Access Indicators) need an emoji font installed in KOReader, which ships none. The icons work in menus, the action manager, the X-Ray browser and chat-window buttons. The Markdown chat view needs no install: it draws emoji with the plugin's bundled copy of the same font. Plain Text windows and the Minimal Popup use KOReader's interface fonts, so they show emoji only once the font is installed.

**The short route:** **Settings → Display Settings → Emoji → Emoji Font** installs the bundled Noto Emoji font into KOReader's fonts folder, enables it as a UI fallback font and asks for a restart; after the restart the same row shows a display test whose **Yes, enable** turns the icons on (with the icons already on, its buttons read **Yes, looks good** and **No, reinstall the font**, which copies the font again). The row's label says where you are (Not Installed, Restart KOReader, Installed). The Setup Wizard's Icons step (**Settings → Setup Wizard**) runs the same install and test. If the icons are on and no emoji font is there, the plugin offers the install once when it starts. The steps below are the same thing by hand.

**Step 1, install the font.** KOAssistant carries a copy in its own folder, `koassistant.koplugin/fonts/NotoEmoji-Regular.ttf`; you can also download **Noto Emoji** (monochrome, `.ttf`) from [Google Fonts](https://fonts.google.com/noto/specimen/Noto+Emoji): `NotoEmoji-Regular.ttf`, not Noto Color Emoji, which KOReader's text renderer cannot use. Copy it to KOReader's fonts folder (KOReader does not look for fonts inside plugin folders) and restart KOReader:

| Platform | Font folder |
|---|---|
| Kobo | `/.adds/koreader/fonts/` |
| Kindle | `koreader/fonts/` (on the USB root) |
| PocketBook | `/applications/koreader/fonts/` |
| Android | `/koreader/fonts/` on device storage |

On Android, KOReader's **Enable system fonts** does not help here: the only emoji font the Additional UI fallback fonts menu offers is one named Noto Emoji, and Android's own is Noto Color Emoji, so copy the file as on the other platforms.

**Step 2, enable it as a UI fallback font.** Installing the file is not enough: from any screen, open KOReader's gear menu → **Device** → **Additional UI fallback fonts**, check **Noto Emoji**, and restart when asked.

**Step 3, enable the icons in KOAssistant:** **Settings → Display Settings → Emoji → Emoji Menu Icons** and, if you want them, **Emoji Data Access Indicators**.

Platform notes: Android, Kobo and PocketBook: copy the file, enable it as a fallback. Kindle has limited emoji support; some glyphs may stay question marks even with the font installed, and if results are poor, turn the emoji options off.

Still not working? The font must be Noto Emoji itself (the fallback menu lists no other emoji font); the font must be enabled under Additional UI fallback fonts, not just copied; restart KOReader fully, not just the book; as a last resort turn Emoji Menu Icons off, the plugin works without them.

## Font issues with Arabic and other right-to-left scripts

The Markdown view draws Arabic, Persian and Urdu in Noto Naskh Arabic, Hebrew in FreeSans, Devanagari and Bengali in KOReader's Noto UI faces and emoji with the bundled Noto Emoji: its renderer (KOReader's MuPDF) cannot fall back letter by letter, but it takes a named font file for a run of text, and that is how each script gets its face wherever it appears, a word inside an English sentence included. A letter none of those faces cover (Thai, for one) goes to a fixed fallback face (the CJK font, then FreeSerif). If text renders wrongly there, switch to plain text: on the fly with the **MD ON / TXT ON** button in the chat window, or for good with **Settings → Display Settings → Rendering → View Mode → Plain Text**; plain text uses KOReader's interface fonts letter by letter and keeps headers, bold and lists readable ([Chat Windows](Chat-Windows#markdown-and-plain-text)). For the Arabic face, **Settings → Display Settings → Rendering → Right-to-left text font** picks Noto Sans Arabic UI, any font KOReader knows, or None.

Every window stays in your view mode whatever the language; plain text is your choice (the button, View Mode, or **Text Mode for Dictionary** for the dictionary windows), never automatic ([Languages](Languages#right-to-left-scripts)). Direction itself is not a font question: in the Markdown view every paragraph is laid out in its own direction ([Chat Windows](Chat-Windows#markdown-and-plain-text)).

## "No API key found"

Add the key for the selected provider in **Settings → API Keys & Auth** or in `apikeys.lua`. A key still set to a placeholder from `apikeys.lua.sample` (such as `YOUR_GEMINI_API_KEY`) counts as no key. Pasted keys are cleaned on read: spaces, line breaks (including one in the middle of the key, which is how a key copied from a wrapped text file usually fails) and invisible characters are dropped, so a key saved with them starts working without re-entering it; saving a key in Settings says how many stray characters it removed.

Once any provider has a key, the provider pickers (inside the **Settings → Model** row and in Quick Settings) list only the providers that have one, plus keyless ones such as Ollama and the current provider marked "(no key)"; **Show all providers** at the end of the list shows the rest. A provider missing from the list has no key yet.

## No response or a timeout

1. Check the internet connection.
2. Read the error: a provider's refusal names the provider and the model, keeps the provider's own sentence with its HTTP status (such as "HTTP 429"), and when the cause is a known one (a rate limit, an account out of credits, a request too large for the model) one tip says what to do. An error stays on screen until you tap it (cancelling a request is the one brief message); a rate limit, an overloaded model or an account out of credits comes with a **Try again** button where a retry makes sense. **Settings → Advanced → Console Debug** also writes the provider's own error text to `crash.log`.
3. Try **Settings → Advanced → Test Connection**.
4. Be patient with very long requests: the plugin waits up to 15 minutes for the provider to send something, so a big X-Ray or a full-document run on a slow model is not cut off early.
5. If the provider stopped the answer for a reason of its own (a content filter, a recitation block, a refusal), the reply says so by name instead of reporting a broken response; a partial answer is kept and marked as cut short, never saved as complete. For Gemini, see **Settings → Advanced → Provider Settings → Gemini Content Filter**.

## Streaming not working

Check **Settings → Chat & Export Settings → Streaming**; some providers differ in what they support. Dictionary and translate windows also have their own **Enable Streaming** row (under **Settings → Dictionary Settings** and **Settings → Translate Settings**), and answers shown in the Minimal Popup never stream.

## The wrong model is used

Check the **Settings → Model** row for the current global default. When you switch providers, the model resets to that provider's default. If a chat still uses an unexpected model, something is redirecting that request: the action's own provider and model (set in its editor), a per-action tier hint (**Settings → Advanced → Faster Models for Quick Actions** turns those off), a global tier pin (**Settings → Advanced → Tier Models (Global)**), the Quick Answer preset's **Model override**, or a model picked for one run by holding Send or the action. See [Providers and Models](Providers-and-Models).

## Chats not saving

Check the auto-save rows under **Settings → Chat & Export Settings**, or save by hand with the chat window's Save button. Dictionary lookups and translations are not auto-saved by default: **Settings → Dictionary Settings → Disable Auto-save for Dictionary** and **Settings → Translate Settings → Disable Auto-Save for Translate** start on. See [Conversations, Notebooks and Export](Conversations-Notebooks-and-Export).

## Bypass or highlight menu actions do not appear

KOReader's own text selection settings can get in the way. In a book, open KOReader's gear menu → Taps and gestures → Long-press on text:

- **Dictionary on single word selection** must be on for dictionary bypass to work; off, a single word is handled like a longer selection (highlight bypass when that is on, otherwise the highlight menu).
- The long-press action chosen below it must be **Ask with popup dialog** for the highlight menu actions and highlight bypass to work; with any other choice KOReader skips its highlight menu and KOAssistant's actions with it; holding the press a moment longer still opens the menu.

## Settings reset

After a problematic update, or for a fresh start: **Settings → Backup & Reset → Reset Settings...**

- **Settings wrong?** **Quick: Settings only** resets the settings, keeps API keys, languages, your selections and actions.
- **Action problems?** **Quick: Actions only** resets every action setting, keeps everything else.
- **Strange behaviour after an update?** **Quick: Settings only** is the safest first step. After a manual update, restart KOReader and see [Manual update](Backups-and-Updates#manual-update): a clean install rules out files left from an older version.
- **Many things broken?** **Quick: Fresh start** resets everything except your API keys and subscription sign-in, languages, gesture registrations and chats. It then offers the Setup Wizard's welcome chain; **Later** leaves it to **Run everything** in **Settings → Setup Wizard**.
- **Want to redo the provider, privacy, language, icons, button marks or gestures?** **Settings → Setup Wizard** lists each topic with its state; a tap re-runs that step.
- **Exact control?** **Custom reset...** lists what to reset.

A long press on any reset row shows exactly what it resets and keeps. The options are described on [Backups and Updates](Backups-and-Updates#reset-settings).

## Debug mode

**Settings → Advanced → Console Debug** is the switch that fills `crash.log` for a bug report: KOAssistant's own tracing is silent by default, and this turns it on without raising KOReader's global log level. **Show Debug in Chat** shows the messages sent and the provider, model and settings used, above the conversation in the chat window. What each shows, and the token usage line: [Advanced Configuration and Development](Advanced-Configuration-and-Development#debugging).

## Related

- [Privacy and Data](Privacy-and-Data): the settings most "not working" reports come down to.
- [Getting Started](Getting-Started): install paths and the key options.
- [Backups and Updates](Backups-and-Updates): the reset options, updating, restore.
- [Advanced Configuration and Development](Advanced-Configuration-and-Development): debugging, configuration.lua, the request inspector.
- [Contributing](Contributing): what to include in a bug report.
