# Dictionary and Translation

KOAssistant adds AI lookups to KOReader's dictionary and an AI translator for selected text and whole pages. This page covers the AI buttons in the dictionary popup, the dictionary bypass, the dictionary and translate windows, Translate Page, the Vocabulary builder, and the settings behind them.

## How it works

*Built with help from contributions to [assistant.koplugin](https://github.com/omer-faruq/assistant.koplugin) by [plateaukao](https://github.com/plateaukao) and others.*

When you select a word in a document, KOReader normally shows its dictionary popup. KOAssistant gives you two ways to use AI there:

1. **AI buttons in the dictionary popup:** tap **Dictionary (KOA)** or another KOAssistant button in KOReader's dictionary popup ([below](#the-dictionary-popup-actions)).
2. **Dictionary bypass:** skip KOReader's dictionary and go straight to your chosen KOAssistant dictionary action ([Dictionary bypass](#dictionary-bypass)).

> **Tip:** for the best results, duplicate a built-in dictionary action and tailor it to your language pair, give it a light model (for example Haiku) for speed, and make it your bypass action for one-tap lookups. See [Custom dictionary actions](#custom-dictionary-actions).

- **No AI buttons in KOReader's dictionary popup:** turn off **Settings → Menus & Buttons → Show AI buttons**.
- **Copy and Translate for text in dictionary results:** turn on **Settings → Menus & Buttons → Enhance text selection** (needs a KOReader restart). In KOReader's dictionary, Wikipedia and other viewers, a single word then opens the dictionary, and selecting several words, or long-pressing one word, opens a popup with Copy, Dictionary and Translate ([Chat Windows](Chat-Windows#selecting-text-in-a-window)).

### X-Ray entries come first

If the book has an X-Ray and the word you look up (or the text you select) exactly matches an entry's name or alias, KOAssistant opens that entry instead of the dictionary or the highlight menu, ahead of any bypass action you set. Anything that does not match falls through to your normal behavior, and a very long press at the end of a selection always brings back KOReader's plain highlight menu.

Exact hits open a compact entity card first (a footnote panel by default, or a floating popup next to the word), with the full entry one tap away; turn **Entity Card First** off to jump straight to the entry. All of it is on by default. Set it for all books under **Settings → Reading & Library → X-Ray** (**X-Ray Entry for Matching Selections**, **Entity Card First**, **Card Style**), or per book in Book Settings → X-Ray or the X-Ray popup's **Marking & lookup…**. See [Using X-Ray](Using-X-Ray#matching-selections).

## The dictionary popup actions

With **Show AI buttons** on (the default), KOAssistant adds its dictionary actions to KOReader's dictionary popup. Four AI actions are there by default, plus a local lookup that appears only when it can help:

| Action | Purpose | What you get |
|---|---|---|
| **Dictionary** | Standard dictionary entry | Pronunciation, part of speech and lemma, numbered definitions, a brief etymology, synonyms |
| **Quick Define** | Fast, minimal lookup | A one-line definition: no etymology, no synonyms |
| **Deep Analysis** | Linguistic deep-dive | Morphology (roots, affixes), word family, etymology path, cognates; it adapts to the word's language family (Semitic roots, Indo-European stems) |
| **AI Wiki** | Encyclopedia entry | A Wikipedia-style overview: definition, history, key facts, significance |
| **Look up in X-Ray** | Local lookup, shown only when the book has an X-Ray | The word's entry in the book's X-Ray, when it has one. No AI call, works offline |

- Dictionary, Quick Define and Deep Analysis answer in your dictionary language ([Dictionary settings](#dictionary-settings)). Dictionary and Quick Define are in the highlight menu by default too.
- AI Wiki keeps its entry with the book: looking the same text up again reopens the saved entry, whose window has **Regenerate** and **Delete** ([Artifacts and Caching](Artifacts-and-Caching)).
- You can also add **Switch model**, the model button: it goes first among the AI buttons, shows your model, and switches it without closing the popup. To run one lookup on another model, long-press the action instead.

### Choosing the popup's buttons

- **Settings → Menus & Buttons → Dictionary Popup Actions** lists every highlight action, built-in and custom, with a ✓ on those in the popup: tap to add or remove, hold to move, and the ☰ menu for the other managers and **Reset to defaults**. Entries that appear only sometimes are marked "(dynamic)".
- Or from **Settings → Actions & Prompts → Manage Actions**: hold an action, then tap **+ Dict. Popup**.
- The manager only adds, removes and orders. The action the bypass runs is chosen separately, under **Settings → Dictionary Settings → Bypass Action** (Quick Define by default).
- **Long-press** a KOAssistant button in the popup for the action's long-press menu: run it once another way (another model, no reasoning), remove it from the popup, edit or duplicate it. The popup stays open. See [Actions and Menus](Actions-and-Menus#the-action-hold-menu).
- The buttons carry a "(KOA)" mark that tells them apart from KOReader's own; untick **Settings → Menus & Buttons → Show (KOA) on KOAssistant's buttons** to drop it (from the next lookup).
- The AI buttons are left off Wikipedia result windows.

## Dictionary settings

**Settings → Dictionary Settings** controls how lookups behave; which buttons the popup shows is set under **Settings → Menus & Buttons** (above). Every row with its default is on [Settings Reference](Settings-Reference#dictionary-settings).

- **Response Language** (**Settings → Dictionary Settings → Response Language**): the language definitions are written in. By default it follows your translation language (the row reads "Response Language: (Follow Translation)"); it can follow your primary language instead, be one of your languages, or a language you type (**Custom...**). A book can have its own: Book Settings → Languages → Dictionary language. See [Languages](Languages#translation-and-dictionary-languages).
- **Context Mode** and **Context Characters:** how much text around the word goes with a lookup ([Context mode](#context-mode)).
- **Show Excerpt:** opens the answer with the passage around the word ([Show Excerpt](#show-excerpt)).
- **Disable Auto-save for Dictionary** (on): lookups stay out of your chat history unless you save them ([Saving lookups and translations](#saving-lookups-and-translations)).
- **Copy Content** and **Note Content:** what the window's **Copy** and **+Note** take. **Definition only** by default; the other choices are Follow global setting, Ask every time, Full (metadata + chat), Question + Response and Everything (debug).
- **Enable Streaming** (on): shows the answer as it is written.
- **Bypass KOReader Dictionary**, **Bypass Action** and **Bypass: Follow Vocab Builder Auto-add:** the [dictionary bypass](#dictionary-bypass) and how it treats the [Vocabulary builder](#vocabulary-builder).

> **Tip:** try dictionary actions and context modes in the [request inspector](Advanced-Configuration-and-Development#the-request-inspector) on a computer to find what works best for your reading, and consider [custom dictionary actions](#custom-dictionary-actions) for your language pair.

## Context mode

**Settings → Dictionary Settings → Context Mode** sends the text around the word with a lookup: **None** (only the word), **Sentence** (the default: the sentence holding the word), **Paragraph** (more surrounding text) or **Characters** (a fixed number before and after the word, set by **Context Characters**: 100 by default, 20 to 500, active only in this mode). A book can have its own mode: Book Settings → Chat behavior → Dictionary context ([Book Settings and Book Hub](Book-Settings-and-Book-Hub#chat-behavior)).

The **Ctx** button in the dictionary window turns context on or off for one lookup by running it again with or without the surrounding text ([The window's buttons](#the-windows-buttons)).

**Context off:**

- a natural, complete dictionary entry
- every meaning and homograph (for example "round" as noun, verb and adjective)
- a faster answer (less text to process)
- no idea which meaning your reading needs

**Context on** (the default):

- a precise definition for this use of the word
- the word's role in this sentence explained
- other meanings may be left out (the context picks one, so homographs are not shown)
- a slightly slower answer (more text to process)

**Best practice:** keep context on while reading, and tap **Ctx** to turn it off when you want the full range of a word's meanings rather than the one the sentence forces.

### Show Excerpt

**Settings → Dictionary Settings → Show Excerpt** (off by default; also on the gear menu of the dictionary windows) opens the answer with a short excerpt of the text around the word, the word in bold. It is for display only: nothing extra is sent, and it appears only for lookups that sent context (Ctx on). In the full chat window, **Hide Quote** hides it.

### The text after the word

Dictionary, Quick Define, Deep Analysis and Translate do not carry the [spoiler protection](Spoiler-Protection) reminder; what they send from the book is the context itself. Two rows under **Settings → Highlight Settings** limit the side after the word: **Context Direction** (**Before the selection only** sends nothing after it) and, while spoiler protection is on, **Context Under Spoiler Protection** (up to the end of the word's sentence or paragraph, or nothing after it). They apply to every dictionary lookup: from the dictionary popup, the highlight menu, the bypass and the input dialog.

## Dictionary bypass

With the bypass on, selecting a word skips KOReader's dictionary popup and runs your chosen AI action at once. The Bypass Action row names your own actions too. If the action a bypass points at was deleted, KOReader's own dictionary (or the highlight menu) opens, with a one-time notice, until you pick another; deleting an action clears a bypass that pointed at it.

1. **Settings → Dictionary Settings → Bypass KOReader Dictionary**: on.
2. **Settings → Dictionary Settings → Bypass Action**: choose the action (Quick Define by default).

Any highlight action, built-in or custom, can be the bypass action. Quick Define is the default because it is fast; switch to the full **Dictionary** action when you want etymology and synonyms, or point the bypass at a lightweight action of your own.

> **Tip:** set the bypass action to **Look up in X-Ray**. A tapped word the X-Ray knows then opens its entry (or a list of entries when it matches only part of their names), and any other word, like every word in a book without an X-Ray, falls through to KOReader's normal dictionary.

- **Quick switching:** assign **KOAssistant: Toggle Dictionary Bypass** to a gesture ([Setup, Gestures and Panels](Setup-Gestures-and-Panels#gesture-toggles)); a brief notification confirms the new state. The Quick Settings panel has the same switch as its **D.Bypass** tile; hold the tile to pick the bypass action.
- **Where the answer appears:** short bypass answers land in the [Minimal Popup](Chat-Windows#minimal-popup) next to the word (Quick Define is one of its actions by default: **Settings → Minimal Popup → Actions Using Minimal Popup**). Longer answers, and lookups started from KOReader's own dictionary window, open the compact dictionary window. Deep Analysis uses the full-size dictionary window ([Dictionary windows](#dictionary-windows)).
- **Words inside windows:** a single word you select inside a KOAssistant window (chat, artifact, X-Ray browser, quiz), or inside KOReader's own viewers with Enhance text selection on, goes through the bypass too. Such lookups carry no context from the book, so **Ctx** is grayed out.
- **Single words run the highlight bypass instead?** KOReader's **Dictionary on single word selection** must be on: see [Troubleshooting](Troubleshooting#bypass-or-highlight-menu-actions-do-not-appear).

The highlight bypass does the same for text selections, running an action (Translate by default) instead of opening the highlight menu: see [Setup, Gestures and Panels](Setup-Gestures-and-Panels#highlight-bypass).

## Dictionary windows

Dictionary actions open in one of these views, set per action in its editor (the **View** row, for highlight actions; see [Actions and Menus](Actions-and-Menus)):

- **Dictionary Compact** (the default for Dictionary and Quick Define): a small window for quick lookups. It opens at 60% of the screen height and grows to fit a longer answer, up to 80%, so there is always room to tap outside and close it. Tap **→ Chat** to continue in the full chat window.
- **Dictionary** (the default for Deep Analysis): a full-size window with the same buttons, and more room for detailed content such as morphology and etymology. **→ Chat** opens the full chat window.
- **Standard:** the full chat window with all its buttons (reply, save, tag, pin, export and the rest) and no dictionary buttons ([Chat Windows](Chat-Windows)).
- **Translate:** the [translate window](#the-translate-window).

An action in the [Minimal Popup](Chat-Windows#minimal-popup) list opens there first; the view above applies when you expand the popup or the answer does not fit.

### The window's buttons

Both dictionary windows share two rows of buttons:

- **Row 1:** MD ON / TXT ON, Copy, +Note, Wiki, +Vocab
- **Row 2:** → Chat, Language, Ctx, the action's name, Close

| Button | Does |
|---|---|
| **MD ON** / **TXT ON** | Switches between Markdown and Plain Text ("MD ON" while Markdown is active). For right-to-left languages it may start at TXT ON ([Right-to-left languages](#right-to-left-languages)). Long-press for the display options ([Chat Windows](Chat-Windows#markdown-and-plain-text)) |
| **Copy** | Copies what **Copy Content** names (the definition only, by default). Long-press to choose this time |
| **+Note** | Saves the answer as a KOReader note attached to the looked-up word (the highlight stays on the word). Grayed out when the word's position is not known, as for a word looked up inside another window |
| **Wiki** | Looks the word up through KOReader's Wikipedia lookup |
| **+Vocab** | Adds the word to KOReader's Vocabulary builder; the button then reads **Added**, grayed out ([Vocabulary builder](#vocabulary-builder)) |
| **→ Chat** | Opens the answer in the full chat window, with every option (continue the conversation, save, export and the rest) |
| **Language** | Runs the lookup again in another language, picked from your languages. The window closes and a new one opens with the result; your setting stays as it is |
| **Ctx: ON** / **Ctx: OFF** | Runs the lookup again with or without the surrounding text. A lookup done without context (mode None) can turn it on for a context-aware definition (Sentence); one done with context can drop it for a plain definition. Not sticky: the next lookup follows your setting again. Grayed out for words looked up inside a window rather than the book |
| **The action's name** | Shows the current action; tap to switch to another action of the dictionary popup (directly when there is only one other, otherwise from a list). AI Wiki, Look up in X-Ray and Switch model are not offered here |
| **Close** | Closes the window. Long-press to close everything down to the page at once (dictionary windows and the highlight menu too) |

The gear menu of both windows has **Show Excerpt** ([Show Excerpt](#show-excerpt)); the full-size window also has **Window Size** ([Chat Windows](Chat-Windows#window-size-and-rotation)). For right-to-left dictionary languages both windows use Plain Text (when the setting is on) and align bidirectional text correctly.

## Translation

### The translate window

Every translation action (Translate from the highlight menu, the highlight bypass with Translate, [Translate Page](#translate-page)) opens the **translate window** (Translate View), a minimal window built for translations. Short translations from a highlight can land in the [Minimal Popup](Chat-Windows#minimal-popup) first; tapping it opens the translate window.

- **Row 1:** MD ON / TXT ON, Copy, Save to Note
- **Row 2:** → Chat, Show Original / Hide Original, Language, Close

| Button | Does |
|---|---|
| **MD ON** / **TXT ON** | Switches between Markdown and Plain Text |
| **Copy** | Copies what **Copy Content** names (the translation only, by default). Long-press to choose this time |
| **Save to Note** | Saves the translation as a note on your highlight: the translate window closes and KOReader's note editor opens with the translation filled in. Long-press to choose the note's content this time. Grayed out when the text did not come from a highlight (Translate Page) |
| **→ Chat** | Opens the full chat window with every option (continue the conversation, save and the rest) |
| **Show Original** / **Hide Original** | Shows or hides the text you translated |
| **Language** | Runs the translation again into another of your languages; your setting stays as it is |
| **Close** | Closes the window. Long-press to close everything down to the page |

Translations are not auto-saved by default: like dictionary lookups, they are meant to be read and let go ([Saving lookups and translations](#saving-lookups-and-translations)).

### Translate settings

**Settings → Translate Settings** sets the target language and shapes the translate window. Every row with its default is on [Settings Reference](Settings-Reference#translate-settings).

- **Target language:** with **Translate to Primary Language** on (the default), translations go into your primary language. Turn it off to choose another under **Settings → Translate Settings → Translation Target**: one of your languages, or one you type (**Custom...**). A book can have its own target: Book Settings → Languages → Translation language ([Languages](Languages#per-book)).
- **Disable Auto-Save for Translate** (on): translations are not saved unless you save them through **→ Chat**.
- **Enable Streaming** (on): shows the translation as it is written.
- **Include Surrounding Context** (off): sends the text around the highlight with the translation, so the AI can resolve pronouns, tone and ambiguous words. It uses the mode of **Settings → Highlight Settings → Surrounding Context**, or a sentence when that is off. It never applies to full-page translation.
- **Copy Content** and **Note Content:** what **Copy** and **Save to Note** take. **Translation only** by default; the other choices are Follow global setting, Ask every time (a picker each time, also when inherited from the global setting), Full (metadata + chat), Question + Response and Everything (debug).
- **Original text:** **Original Text** decides whether the text you translated shows above the translation: **Hide Long** (the default; hidden when longer than **Long Text Threshold**, 280 characters by default), **Always Hide**, **Never Hide**, or **Follow Global**, which uses the quote settings of **Settings → Display Settings → Highlights** ([Chat Windows](Chat-Windows#quotes)). **Hide for Full Page Translate** (on) always hides it for Translate Page, whatever the other rows say. **Show Original** in the window changes it for one translation.

### Translate Page

**KOAssistant: Translate Page** translates all the text on the page you see: it extracts the visible page's text, sends it to the Translate action, and opens the result in the translate window. It works with PDF, EPUB, DjVu and the other document formats KOReader opens.

- Run it from a gesture (reader only; the gesture can be bound on **Settings → Gestures**) or from the **Translate Page** button of the Quick Actions panel ([Setup, Gestures and Panels](Setup-Gestures-and-Panels)).
- The original text is hidden (**Hide for Full Page Translate**, on by default).
- No surrounding context is added, the Minimal Popup is never used, and **Save to Note** is grayed out, since there is no highlight.
- Good for academic reading and foreign-language texts.

## Language indicators

The dictionary and translation languages can follow other settings. On the [Quick Settings](Setup-Gestures-and-Panels#quick-settings) panel, their tiles show return symbols when they do (tap a tile to change the language):

- `↵` = following your primary language (for example "Translate: English ↵")
- `↵T` = following your translation language (for example "Dictionary: English ↵T")

A book's own language shows "(book)" instead. In the Settings menu the rows say it in words: "Response Language: (Follow Translation)" or "(Follow Primary)". How the languages work together: [Languages](Languages#translation-and-dictionary-languages).

## Right-to-left languages

Dictionary and translate windows handle right-to-left (RTL) languages specially. When your dictionary or translation language is Arabic, Classical Arabic, Persian or Urdu:

- **Automatic RTL mode:** the window aligns right to left. Dictionary windows use Plain Text for it (**Settings → Display Settings → Rendering → Text Mode for RTL Dictionary**, on by default); translate windows stay in the Markdown view, the translation right-to-left in the right-to-left font and the original left-to-right, unless **Text Mode for RTL Translate** (off by default) is on. **Text Mode for Dictionary** (off by default) uses Plain Text in dictionary windows for every language, which helps the scripts the Markdown view draws in its plain fallback face (Hebrew, Devanagari, Bengali, Thai); while it is on, the RTL dictionary switch is grayed out.
- **Bidirectional alignment:** entries with right-to-left content are aligned correctly, and mixed content (an Arabic headword with an English pronunciation guide) reads in the right order.
- **Phonetic transcriptions** are anchored to display correctly beside right-to-left headwords.

Both views draw Arabic and Persian properly (the Markdown view in the **Right-to-left text font**); Hebrew reads better in Plain Text. When the language is not right-to-left, your Markdown or Plain Text preference stays as it is. In the Markdown view every paragraph takes its own direction, and in a dictionary window of a right-to-left language a paragraph that starts with a right-to-left word is laid out right-to-left, so a headword followed by a Latin pronunciation guide and an English gloss stays on the right. Chat and artifact windows check their content instead (**Auto RTL mode for Chat**): see [Chat Windows](Chat-Windows#markdown-and-plain-text) and [Languages](Languages#right-to-left-scripts). Fonts that do not render at all: [Troubleshooting](Troubleshooting#font-issues-with-arabic-and-other-right-to-left-scripts).

## Custom dictionary actions

The built-in dictionary actions use prompts that work in many situations:

- **monolingual lookups** (an English word, English definitions)
- **bilingual lookups** (a French word, English definitions and translations)
- **context-aware disambiguation** (Ctx on)

For the best results, **create dictionary actions for your own use**:

1. Open **Settings → Actions & Prompts → Manage Actions**.
2. **Hold** Dictionary or Quick Define and tap **Duplicate** (tapping the row only turns the action on or off).
3. Edit the copy with prompts for your language pair or learning style.
4. Add it to the popup: **Settings → Menus & Buttons → Dictionary Popup Actions**.
5. Make it the bypass action for one-tap lookups: **Settings → Dictionary Settings → Bypass Action**.
6. For the fastest answers, leave the bypass on Quick Define, or point it at your own lightweight action.

A duplicate keeps the original's view mode and its model and reasoning settings. Your prompt receives the word's context through `{context_section}` (or `{context}`) and the dictionary language through `{dictionary_language}` ([Template Variables](Template-Variables)). An action you create from scratch can tick **Dictionary Popup** in the wizard's first step ([Actions and Menus](Actions-and-Menus)).

**Examples:**

- **"EN→AR Dictionary":** explicit Arabic translation with English metalanguage
- **"Monolingual French":** definitions only in French, no translations
- **"Etymology Focus":** start from Deep Analysis and remove the morphology sections
- **"Quick Vocab":** a minimal definition and an example sentence, for flashcards

**Tips:**

- Give dictionary actions a **lighter model** (for example Haiku) with a per-action model override. Translate and Quick Define already ask for your provider's faster model while **Settings → Advanced → Faster Models for Quick Actions** is on (the default; see [Providers and Models](Providers-and-Models)).
- **Context on** (the default) disambiguates the word as it is used; **context off** gives complete entries with every sense.
- For right-to-left languages the compact window switches to Plain Text on its own.

## Vocabulary builder

The dictionary windows (compact and full-size, from the bypass and from the popup's actions) work with KOReader's Vocabulary builder:

- **Auto add on** (KOReader's Vocabulary builder has **Auto add new words** on): a word you look up through the dictionary bypass is added for you, and the window's button reads **Added**, grayed out. A word looked up from KOReader's dictionary popup is handled by KOReader itself, and the button shows the same state.
- **Auto add off:** the window shows **+Vocab** to add the looked-up word by hand. The word is stored as KOReader's own lookups store it, the punctuation around the selection removed; both need the Vocabulary builder plugin enabled.

**Settings → Dictionary Settings → Bypass: Follow Vocab Builder Auto-add** (on by default) decides whether the bypass follows KOReader's auto-add. Turn it off if you use the bypass to analyze words you already know and do not want them added; **+Vocab** still adds a word by hand.

## Saving lookups and translations

Dictionary lookups are **not auto-saved** by default (**Disable Auto-save for Dictionary** is on), so single-word lookups do not clutter your chat history.

- **Auto-save off** (the default): to keep a lookup, or to ask more about it, tap **→ Chat** in the dictionary window (compact or full-size). The full chat window opens with an active **Save** button that saves to the current document, and you can ask follow-up questions there, for example about etymology or usage patterns.
- **Auto-save on** (turn the row off): dictionary chats follow your general chat saving settings, **Auto-save All Chats** or **Auto-save Continued Chats** ([Conversations, Notebooks and Export](Conversations-Notebooks-and-Export#auto-save)).

Translations work the same way with **Settings → Translate Settings → Disable Auto-Save for Translate** (on by default): save one through **→ Chat**.

## Related

- [Setup, Gestures and Panels](Setup-Gestures-and-Panels): the highlight bypass, the bypass gestures and the Quick Settings tiles.
- [Languages](Languages): your languages, the dictionary and translation targets, and per-book languages.
- [Chat Windows](Chat-Windows): the full chat window behind → Chat, the Minimal Popup, and selecting text inside windows.
- [Using X-Ray](Using-X-Ray): marks, entity cards and Look up in X-Ray.
- [Actions and Menus](Actions-and-Menus): editing and creating actions, their view modes and their menus.
- [Settings Reference](Settings-Reference): every Dictionary Settings and Translate Settings row with its default.
