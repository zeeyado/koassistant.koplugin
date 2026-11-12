# Backups and Updates

How KOAssistant updates itself and how to update it by hand, what the update checker does, and the backup, restore, index-repair and reset tools under **Settings → Backup & Reset**. The lists of what gets backed up, restored, preserved by an update and kept by a settings reset all come from one place in the plugin, its storage registry, so the flows cannot drift apart.

## Updating the plugin

### Automatic update, one tap

When KOAssistant detects a new version (on startup, or from a manual check), the release notes dialog has an **Update Now** button. Tap it and the plugin does everything:

1. Downloads the release zip from GitHub and checks it against the release's size and checksum, so a cut or damaged download never replaces your plugin. Slow Wi-Fi gets up to 10 minutes.
2. Extracts it to a staging folder and verifies the new version (`_meta.lua` and `main.lua` present, version as expected).
3. Preserves your configuration files: `apikeys.lua`, `configuration.lua`, `custom_actions.lua`, `custom_models.lua`, and custom `behaviors/` and `domains/` folders (a linked folder keeps its files). Your files are checked before anything is deleted; a file that cannot be carried over keeps the old folder in place and tells you where it is.
4. Swaps the old plugin folder aside and moves the new version into place; if the swap fails, the previous version is restored.
5. Restores your configuration files into the new version.
6. Asks you to restart KOReader.

The button appears in the original and the translated release-notes viewers, so you can read the notes in your language and update from the same dialog. An update always runs the updater you already have installed, which is why each release also tests that the previous release's updater installs it.

If you installed by cloning the git repository, the button does not appear: the updater never replaces a git checkout. Use `git pull` (below).

### What is safe during updates

Your settings and data are not touched by an update, automatic or manual:

- all settings (provider, model, features, privacy and the rest) live outside the plugin folder;
- API keys entered in Settings live outside the plugin folder;
- chat history, notebooks and saved results live in KOReader's settings and sidecar files;
- backups, exports and generated images live under KOReader's data folder (`koassistant_backups/`, `koassistant_exports/`, `koassistant_images/`).

The updater also preserves the optional files inside the plugin folder listed above.

### Manual update

If you prefer to update by hand, or are updating from a version without the updater:

**Extract over the existing folder (recommended).** New and changed files are overwritten, your configuration files are untouched.

1. Download `koassistant.koplugin.zip` from the [latest release](https://github.com/zeeyado/koassistant.koplugin/releases) → Assets.
2. Connect the device over USB, or use a file manager on Android.
3. Extract the zip directly over the existing `koassistant.koplugin` folder in the plugins folder (Kobo `/mnt/onboard/.adds/koreader/plugins/`, Kindle `/mnt/us/koreader/plugins/`, Android `/sdcard/koreader/plugins/`, macOS `~/Library/Application Support/koreader/plugins/`, Linux `~/.config/koreader/plugins/`). When asked about existing files, choose Replace, Overwrite or Merge. Merge keeps files from older versions beside the new ones; they do no harm, but deleting the old folder first, after copying out your own files (the ones an update preserves, listed above), leaves only the current ones.
4. Eject the device and restart KOReader.

On some file managers "extract here" into the plugins folder merges into the existing folder on its own; on others you drag the extracted folder over the existing one and confirm the overwrite.

**Clean install, if you have problems.** This deletes the old plugin folder, so back up your own files first:

1. Back up any files you created inside the plugin folder: `apikeys.lua` (if you use file-based keys), `configuration.lua`, `custom_actions.lua`, `custom_models.lua`, and your `behaviors/` and `domains/` folders.
2. Delete the existing `koassistant.koplugin` folder.
3. Extract the new zip into the plugins folder.
4. Copy your files back into the new folder.
5. Restart KOReader.

Keys entered in Settings are stored elsewhere and survive a clean install; only a file-based `apikeys.lua` needs backing up.

**Git pull, for developers.** In a cloned repository, `git pull` in the plugin folder gives you the latest development version, unreleased changes included. The updater detects a git checkout (a `.git` folder, or the `.git` file of a worktree or submodule) and never installs over it.

## Update checking

### Automatic check

By default KOAssistant checks for updates at most once a day, about 20 seconds after KOReader starts and only when Wi-Fi is on, deferred so it never competes with opening your book.

1. About 20 seconds after start, the check runs silently in a subprocess with an 8-second timeout; a check that already succeeded within the last 24 hours is skipped before any network work; with Wi-Fi off it is skipped entirely. Opening or closing a book starts the plugin again and can schedule another check, under the same rules.
2. If a new version exists, a dialog shows the current and the latest version, the full release notes with clickable links, **Update Now** (hidden for git checkouts and when the release has no zip), **Visit Release Page**, **Translate** (shown when you have a non-English interaction language) and **Later**.
3. If a response is streaming when the update is found, the dialog waits until streaming ends.

The check compares your installed version with GitHub's releases, pre-releases included, by semantic version (it strips `v` and `v.` prefixes and picks the highest version, not the newest entry). A failed check (Wi-Fi on, but GitHub unreachable) is tried again at the next KOReader start, or when you next open or close a book once 30 minutes have passed, never sooner; the 24-hour timestamp is recorded only on success, and a manual check is never held back.

To turn the automatic check off: **Settings → Auto-check for updates on startup** (near the bottom of the KOAssistant menu, beside About KOAssistant and Check for Updates). Or set `auto_check_updates = false` in the `features` table of `configuration.lua` and restart KOReader; a choice made in the menu wins over the file ([Advanced Configuration and Development](Advanced-Configuration-and-Development#configurationlua)).

### Manual check

**Settings → Check for Updates** always shows a result, an update or "You are running the latest version", with a longer 15-second timeout. A version newer than the latest release says "You are running a development version". Pre-releases order as alpha < beta < rc < release, and a final release outranks its own pre-releases.

## Backup and restore

### What can be backed up

Backups are selective:

| Category | What is included | Default |
|---|---|---|
| **Core Settings** | provider and model, behaviors, domains, temperature, languages, every toggle, custom providers, custom models, action menu customizations, general and library pinned artifacts, book groups, and the per-book settings of every book KOAssistant can find (the same search as Rebuild Data Indexes) | always included |
| **API Keys** | your API keys and an OpenAI Subscription sign-in, in plain text | excluded by default |
| **Config Files** | `configuration.lua`, `custom_actions.lua`, `custom_models.lua` (and `apikeys.lua` only when API keys are included), if they exist | included if the files exist |
| **Domains & Behaviors** | your custom domains and behaviors (`.md` and `.txt` files; hidden files such as a macOS `._name.md` companion are left out) | included |
| **Chat History** | all saved conversations (book, general and library chats) | excluded, can be large |

API keys are stored in plain text in a backup: include them only when you control who can read the backup files. A backup does not hold notebooks, artifacts (X-Rays and the rest), per-book pinned items, generated images or exports.

### Creating a backup

1. **Settings → Backup & Reset → Create Backup**.
2. Choose what to include.
3. Tap Create Backup. The backup lands in `koassistant_backups/` in KOReader's data folder, named `koassistant_backup_<date>_<time>.koa`.

A backup is a `.koa` file (KOAssistant Archive), a tar.gz holding your settings, content and a `manifest.json` that records what is included, the plugin version and item counts. Good moments: before a major update, before a big change of settings, to move settings to another device, as a periodic snapshot.

### Restoring

1. **Settings → Backup & Reset → Restore from Backup**.
2. Pick a backup from the list, newest first.
3. Preview what it contains.
4. Choose what to restore (categories can be left out).
5. Choose the mode: **Replace** (default, safest: your current settings are replaced outright) or **Merge** (advanced, below).
6. Tap Restore Now and confirm, then restart KOReader (the last dialog offers Restart Now) for everything to take effect.

A restore point, a full backup with your API keys and chats, is created before every restore; a restore that fails midway rolls back to it on its own, and you can restore it yourself to undo a restore. It holds your API keys even when you left them out of your own backups, because an undo has to bring back everything, and like any backup with keys it keeps them in plain text; the confirmation before a restore says it is a full copy. A backup made before KOAssistant moved chats into the books' own sidecar files is imported into the current storage during the restore, so its chats appear in Chat History without an extra step.

### Restore modes

**Replace** replaces the current settings with the backup, after the restore point: what you backed up is exactly what you get. Restoring settings this way without API keys keeps the keys you have (entered in Settings, in `apikeys.lua`, or the OpenAI Subscription sign-in).

**Merge** combines the backup with what is on the device. Plain settings take the backup's values. The things you made that are kept one by one are joined: custom domains, behaviors and providers created in the app, book groups, general and library pinned answers and chats made after the backup stay, and one that both hold takes the backup's version. Custom actions and the custom model list are taken from the backup wholesale, so an action you made after the backup is removed. API keys merge by provider with the backup winning; domain and behavior files merge by filename.

In both modes a restore never hands out an old id again: a custom domain, behavior or book group you create after a restore gets a new id, even when the backup is older than the last one you had made (a book set to a domain or following a group that the restore removed must not silently take a new one).

### Managing backups

**Settings → Backup & Reset → View Backups** lists every backup with its date and size, and the total size in its title. For each: **Info** (the manifest: what is included, version, timestamp), **Restore**, **Delete**. Restore points are in the same list (their names start with `koassistant_restore_point_`), and opening View Backups deletes the ones older than seven days.

### Moving settings to another device

Create a backup on the main device (settings, API keys, domains and behaviors; leave chat history out to keep it small), copy the `.koa` file from `koassistant_backups/` to the other installation's `koassistant_backups/`, restore it there, and restart KOReader. Useful for testing a new version with your real configuration, for the request inspector on a computer ([Advanced Configuration and Development](Advanced-Configuration-and-Development)), and for keeping several e-readers alike.

### What a restore validates

Custom actions missing a required field are skipped; edits to built-in actions that no longer exist are skipped; a backup from a different plugin version gets a warning in the preview; chats and per-book settings for books not found at the same path on this device are skipped rather than restored as dead entries. Warnings are shown after the restore; valid items are restored, invalid ones skipped.

## Data indexes

The global browsers (artifacts, chats, notebooks, pinned items) run on small device-local indexes, while the data itself lives in the book's `.sdr` sidecar folder, wherever KOReader's Book metadata location setting keeps it (beside the book, or in KOReader's `docsettings` or `hashdocsettings` folder); after a change of that setting, each KOAssistant file moves to the new place the first time it is read. If you move or delete books outside KOReader, or sync sidecar files between devices, the indexes can drift from what is on disk. Two tools keep them right, and a light self-heal runs on its own: each time you open a book, that book's entries in all four indexes are refreshed shortly after it loads, so synced or restored data becomes visible through normal reading.

- **Settings → Backup & Reset → Validate Data Indexes** checks the four indexes for stale entries (books moved or deleted outside KOReader), repairs count mismatches and removes entries whose book file no longer exists.
- **Settings → Backup & Reset → Rebuild Data Indexes** does the reverse: it finds books whose KOAssistant data is on disk but not in this device's browsers (after a sync, a restore or a migration), from your reading history, KOReader's central sidecar locations and the scan folders below; heals their entries; then prunes stale ones. It never wipes an index. Books on unmounted storage get pruned; run it again with the storage mounted. On a large library it takes a while, and it ends with a report: books checked, books with data, per-index totals, stale entries removed, synced sidecars that matched no local book.
- **Settings → Backup & Reset → Index Scan Folders** points the rebuild at your synced book folders. Only these are scanned, only by a rebuild or by a backup gathering per-book settings, and folders absent on this device are skipped. A local scan, nothing leaves the device, kept separate from the privacy-gated library scan folders. A settings reset clears the list.
- **Settings → Backup & Reset → Auto-Rebuild on Startup** (off by default) runs the rebuild after KOReader starts, at most once a day, in the background, and only when scan folders are configured.

## Reset settings

**Settings → Backup & Reset → Reset Settings...** holds the resets. A long press on a row shows what it resets and what it keeps.

- **Quick: Settings only**: resets the menu's settings (provider, model, temperature, streaming, display, export, dictionary, translation, reasoning, debug) and keeps API keys, your languages (the translation and dictionary languages included), your selections (behavior, domain, trusted providers, the X-Ray defaults, favorite models, toolbar buttons, the export folder, **+ Gesture Menu** additions), all actions, custom behaviors and domains, custom providers and models, KOReader's gesture assignments and chat history.
- **Quick: Actions only**: resets everything about actions (custom actions, edits to built-in actions, disabled actions, and every action menu: highlight, dictionary, quick actions, general, file browser, and each input dialog's ordering, plus the order and visibility of the QA Panel Utilities and QS Panel Items) and keeps the rest.
- **Quick: Fresh start**: resets all settings (your selections included), all actions, custom behaviors and domains, and custom providers and models; keeps API keys, your languages, KOReader's gesture assignments and chat history; then offers the Setup Wizard's welcome chain (**Later** leaves it to **Run everything** in **Settings → Setup Wizard**), and deletes `koassistant_chats.backup` (the copy of chats an old version's chat import kept), if there is one.
- **Custom reset...**: a checklist of what to reset: settings, custom actions, action edits, action menus, custom providers and models, behaviors and domains, API keys (marked ⚠ when set to Reset). Tap each item to switch between Keep and Reset, then Reset Selected.
- **Clear all chat history**: deletes every saved conversation: book, general and library chats. This cannot be undone.

The action manager (**Settings → Actions & Prompts → Manage Actions**) has a ☰ menu with the action-related resets, and every ordering manager (Manage Actions, Highlight Menu, Dictionary Popup, File Browser Items, QA Panel Actions, QA Panel Utilities, QS Panel Items, Input Dialog Actions) has a ☰ menu with links to the others. When to reset, and which option fits which problem: [Troubleshooting](Troubleshooting#settings-reset).

## Related

- [Troubleshooting](Troubleshooting): which reset fits which problem.
- [Getting Started](Getting-Started): the first, manual installation.
- [Privacy and Data](Privacy-and-Data): the library scan folders, which are not the index scan folders.
- [Advanced Configuration and Development](Advanced-Configuration-and-Development): `configuration.lua`, which the updater preserves.
