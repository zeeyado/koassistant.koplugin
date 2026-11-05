# Languages

Three different things are called "language" in KOAssistant: the languages the AI answers in, the target languages of the Translate and Dictionary actions, and the language of the plugin's own interface. This page covers all three, the per-book overrides, and right-to-left scripts.

## The AI's languages

**Settings → AI Language Settings** controls what language the AI responds in.

**Auto-detection.** KOAssistant takes your language from KOReader's UI language. If you have not configured any languages, the AI answers in your KOReader language (KOReader in Français: the AI answers in French), and translation and dictionary actions follow it too. The detected language shows as "(auto)" on the Your Languages row of AI Language Settings. Once you set a language yourself, auto-detection is no longer used. A reader who completed the setup wizard before this feature existed and never configured languages gets a one-time prompt offering the detected KOReader language (non-English UIs only).

- **Your Languages**: the languages you speak or understand. The picker lists 47 languages in their own scripts (日本語, Français, Español …) and five classical ones; pick several. They are sent to the AI in the system prompt ("The user understands: …").
- **Primary Language**: which of your languages the AI answers in by default. The first in your list unless you choose another.
- **Additional Languages**: extra languages for translation and dictionary targets that do not affect the AI's response language. They are not sent in the system prompt; they appear in the translation and dictionary pickers and in the Language button of the dictionary and translate windows. Use them for scholarly work (Latin, Sanskrit, Ancient Greek), for a language you are learning (translate into it), or for a language you understand but do not want the AI to default to.
- **Tell the AI the Book's Language**: off by default. Set to "From the book's metadata", [book-tool](Reasoning-Web-Search-and-Book-Tools) sessions tell the AI what language the book's text is in, so its searches use that language even if you ask in another. That is the language the book records; an EPUB or other reflowable book that records none sends the language of KOReader's Typography rules for it instead, and for a PDF that records none no language is named. It can be overridden per book or group in Book Settings → Languages, where you can also pick or type a language.

**Native scripts.** Languages appear in their own scripts in menus and settings; the system prompt uses their English names, which language models follow more reliably. Classical languages (Ancient Greek, Biblical Hebrew, Classical Arabic, Latin, Sanskrit) are shown in English only. **Custom languages:** "Add Custom Language..." at the top of the Your Languages and Additional Languages pickers takes a language that is not in the list; it stays there, and in the translation and dictionary pickers, until you untick it. "Custom..." at the end of the translation and dictionary pickers sets that one target without adding it to a list. A typed language reaches the AI exactly as typed.

**How answers work.** The AI answers in your primary language by default; if you type in another of Your Languages, it switches to that one. It switches only among Your Languages and never answers in an Additional Language of its own accord, even when the content is in that language, because Additional Languages are not part of the language instruction. Examples: Your Languages `English`: always English. Your Languages `Deutsch, English, Français`, primary `English`: English by default, German or French when you write in them. Additional `Latin, Sanskrit`: in the translation and dictionary pickers only.

**How it reaches the AI.** Your languages go last in the system message, after the behavior, the domain and a book's Background note; the instruction tells the AI to answer in your primary language and to switch when you type in another configured one ([Prompts, Behaviors and Domains](Prompts-Behaviors-and-Domains)). Translate and the dictionary actions (Dictionary, Quick Define, Deep Analysis) have **Skip language** on because their prompts name the target language themselves (`{translation_language}`, `{dictionary_language}`). A custom action whose prompt already names a response language should tick **Skip language** too; otherwise leave it off so your language preference applies ([Actions and Menus](Actions-and-Menus)). A prompt can also name your answer language with `{response_language}` (the primary in effect, a book's override included); the X-Ray's prompts do, so a foreign-language book's X-Ray is still written in your language ([Template Variables](Template-Variables)).

## Translation and dictionary languages

Four settings work together:

1. **Your Languages**: sent to the AI.
2. **Primary Language**: the default response language, one of Your Languages.
3. **Translation target** (**Settings → Translate Settings**): the target of the Translate action. **Translate to Primary Language** (on by default) makes it follow the primary language (`↵`); turned off, **Translation Target: …** sets it on its own, from a picker that lists Your Languages and the Additional Languages.
4. **Dictionary language** (**Settings → Dictionary Settings → Response Language: …**): the response language of dictionary lookups; it follows the translation language by default (`↵T`), and can follow the primary (`↵`) or be set on its own, with the same picker.

The Translate and Dictionary buttons of Quick Settings show the symbols: `↵` after a language means it follows the primary language, `↵T` that the dictionary follows the translation language. Two example setups:

- Your Languages English and Spanish, primary English, additional Latin, translation `↵`, dictionary `↵T`: the AI knows you understand English and Spanish, answers in English, translates into English, defines words in English, and Latin is available in the pickers for scholarly texts.
- Your Languages English, primary English, additional Spanish and Latin, translation Spanish, dictionary `↵T`: the AI answers in English, translates into Spanish, defines words in Spanish (useful while reading Spanish), and Latin is there for translation when needed.

The dictionary's and translator's other settings are on [Dictionary and Translation](Dictionary-and-Translation).

## Per book

[Book Settings](Book-Settings-and-Book-Hub) → Languages holds four overrides, each Follow global by default:

- **AI response language**: the language the AI replies in for every action on this book (the "Always respond in X" directive). Keep your global answers in English and set a French novel to French; the book's language is added to your "understands" list, so the AI still switches if you write in one of your other languages.
- **Translation language**: the Translate action's target for this book.
- **Dictionary language**: the definition language for lookups in this book.
- **Book text language**: what language the book's text is in, told to the AI in book-tool sessions: Off, From metadata, a language from the list, or Custom (typed, so "German and Latin" works). It follows the global "Tell the AI the Book's Language" unless set here or in a group.

The AI response language changes the default reply language for every action; the translation and dictionary languages affect only Translate and the dictionary actions, and the book text language only what book-tool sessions are told. A [group](Book-Groups-and-Series)'s Group Settings has the same Languages screen, for every book in the group. With a book open, the Language, Translate and Dictionary buttons of Quick Settings show the book's own value marked "(book)", and holding one opens this screen.

## Right-to-left scripts

Right-to-left answers are shown in plain text, which renders their fonts properly, aligned to the right:

- **Dictionary and translate windows** switch when your dictionary or translation language is right-to-left: Arabic, Classical Arabic, Persian or Urdu. A custom language you typed counts only when spelled exactly as in this list. The dictionary also keeps mixed entries (an Arabic headword with an English pronunciation guide) in the right order: see [Dictionary and Translation](Dictionary-and-Translation#right-to-left-languages).
- **Chat and artifact windows** (X-Ray, X-Ray (Simple), Analyze, Summary) check the answer itself and switch to right-to-left mode when right-to-left letters (Arabic, Persian, Urdu, Syriac and the other right-to-left scripts) outnumber Latin ones.

The switches are **Settings → Display Settings → Rendering → Text Mode for RTL Dictionary**, **Text Mode for RTL Translate** and **Auto RTL mode for Chat**, all on by default ([Chat Windows](Chat-Windows#markdown-and-plain-text)); your Markdown or plain-text preference is kept when the content is not predominantly right-to-left. In the Markdown view every paragraph is laid out in its own direction, so a mixed chat reads right block by block, and right-to-left text is drawn in Noto Naskh Arabic (**Settings → Display Settings → Rendering → Right-to-left text font** picks another face, or None) ([Chat Windows](Chat-Windows#markdown-and-plain-text)). Fonts that do not render at all are a KOReader font question: see [Troubleshooting](Troubleshooting#font-issues-with-arabic-and-other-right-to-left-scripts).

## The interface's language

The plugin's own menus, buttons and messages are available in 26 languages: French, German, Italian, Spanish, Portuguese, Brazilian Portuguese, Dutch, Finnish, Norwegian Bokmål, Swedish, Russian, Polish, Czech, Ukrainian, Simplified Chinese, Japanese, Korean, Vietnamese, Indonesian, Thai, Hindi, Bengali, Urdu, Arabic, Persian (Farsi) and Turkish. By default the interface follows KOReader's language (English when the plugin has no translation for it); **Settings → Display Settings → Plugin UI Language** picks another, or English for the original wording, and takes effect after KOReader restarts.

The translations are made by AI and marked "needs editing" on Weblate; reviewing them is the most useful small contribution there is ([Contributing](Contributing)).

## Related

- [Dictionary and Translation](Dictionary-and-Translation): the actions whose targets these settings set.
- [Prompts, Behaviors and Domains](Prompts-Behaviors-and-Domains): where the language instruction sits in the prompt.
- [Book Settings and Book Hub](Book-Settings-and-Book-Hub): the per-book rows.
- [Contributing](Contributing): translating the interface.
