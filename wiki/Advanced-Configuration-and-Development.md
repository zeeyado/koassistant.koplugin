# Advanced Configuration and Development

The configuration files for things the Settings menu does not cover, the debugging switches, the request inspector that shows exactly what a request contains without a device, and what a developer needs to run the test suite or work off the main branch.

## configuration.lua

Most settings are managed in the Settings menu (Tools → KOAssistant). The main reason to use `configuration.lua` is **custom API endpoints**, such as proxies and regional mirrors, for the built-in providers. Copy `configuration.lua.sample` to `configuration.lua` in the plugin folder and uncomment what you need:

```lua
return {
    -- Default provider/model (used until changed in the Settings UI)
    -- provider = "openai",
    -- model = "gpt-5.6-terra",

    -- Custom API endpoints: override the default URL for any built-in provider
    provider_settings = {
        openai = {
            base_url = "https://your-proxy.example.com/v1/chat/completions",
        },
        anthropic = {
            base_url = "https://your-proxy.example.com/v1/messages",
        },
        gemini = {
            -- Gemini base_url is the prefix; the handler appends /{model}:generateContent
            base_url = "https://your-proxy.example.com/v1beta/models",
        },
    },

    -- Feature defaults (Settings UI values take priority)
    features = {
        enable_streaming = true,
        -- Reasoning is per model. Optional global stance: "minimal" | "default" | "maximum".
        -- Per-model overrides are keyed "provider/model". Usually set this in the UI instead.
        reasoning_prefs = {
            stance = "default",
            -- models = { ["anthropic/claude-opus-5-5"] = { state = "on", effort = "high" } },
        },
    },
}
```

The sample documents more feature keys (display, translation, streaming, behavior, web search, debug and others); all are optional. **Priority:** Settings menu > `configuration.lua` > built-in defaults. Once a setting is changed in the menu, the menu's value wins over the file, and so does every key the file already held when KOAssistant first started on this device (those were copied into the saved settings then). Two endpoint rules: an Ollama server added in the menu (the **Server: …** row of **Settings → Model → Ollama**) wins over an Ollama `base_url` here, and a `base_url` for Z.AI, Qwen or Kimi replaces their region setting. KOReader reads the file when it starts, so restart it after an edit; a file with an error is not loaded at all, and KOAssistant shows the error the first time you use it.

**The file is not actively maintained.** Development moved to the Settings menu and the file has drifted behind it. `provider_settings` (custom endpoints) and the documented `features` keys are the supported path. Beyond those, some keys are accepted without ever taking effect, because a few parts of the plugin read their values from the saved settings rather than from this file. One confirmed case: `features.custom_providers` does nothing on an existing install (it is read only on a first run, before any settings exist); add custom providers through **Settings → Model → Add custom provider...** instead. If something you set here does not take effect, [open an issue](https://github.com/zeeyado/koassistant.koplugin/issues) saying what you set and what happened; these are fixed one key at a time, and only reported gaps get fixed.

**Proxy services and custom providers are different things.** A proxy or relay that speaks each provider's own API format (an OpenAI-compatible endpoint for OpenAI, an Anthropic-compatible one for Anthropic) is a `base_url` override in `provider_settings`, not a custom provider. Custom providers (**Settings → Model → Add custom provider...**) are services with their own model catalog that speak the OpenAI-compatible format; see [Providers and Models](Providers-and-Models).

## Other files in the plugin folder

The plugin's own code lives in the `koassistant/` folder, one subfolder per area, and never needs editing. Your files sit at the root of the plugin folder, next to `main.lua`:

- `apikeys.lua`: file-based API keys, an alternative to entering them in Settings ([Getting Started](Getting-Started)).
- `custom_actions.lua`: actions defined in a file rather than in the action editor ([Actions and Menus](Actions-and-Menus)).
- `custom_models.lua`: capabilities, reasoning profiles, parameter constraints, output caps and speed-tier placements for any model, built-in or on a custom provider, from `custom_models.lua.sample` ([Providers and Models](Providers-and-Models#custom-models)). It adds no models: those are added in the model menu.
- `behaviors/` and `domains/`: your own behavior and domain files, which override the built-in ones of the same name ([Prompts, Behaviors and Domains](Prompts-Behaviors-and-Domains)).

Updates preserve all of them ([Backups and Updates](Backups-and-Updates)). KOReader reads `apikeys.lua` and `custom_models.lua` once, like `configuration.lua`: restart it after editing them. A file that is not text (a macOS `._name` companion file copied along with a folder, for one) is skipped by the behavior and domain loaders, so it cannot break requests.

`custom_models.lua` holds up to five tables, each keyed by provider id (`custom_<name>` for a custom provider): `capabilities` (`true` grants and `false` denies a capability such as `tools` for the model ids a prefix matches), `reasoning_profiles` (shaped like the built-in profiles; a custom provider's adds `wire = "effort"` or `wire = "enable_thinking"`, how its requests carry the setting), `constraints` (forced values such as `temperature = 1.0`), `max_output_tokens` (an output ceiling) and `tiers` (one exact model id per tier). The longest matching prefix wins (for reasoning profiles, the first that matches) and `""` matches every model. Your entries win over the built-in lists and over what a provider reports; tier picks made in the model menu win over the file's. The [sample](https://github.com/zeeyado/koassistant.koplugin/blob/main/custom_models.lua.sample) explains each table, with examples.

## Debugging

The debug rows sit under **Settings → Advanced**:

- **Console Debug**: KOAssistant's own tracing in the terminal and in `crash.log`. **For a bug report, this is the switch that fills `crash.log`.** The plugin's tracing is silent by default; Console Debug turns it on without raising KOReader's global log level, so the log stays readable instead of drowning in KOReader's per-repaint output. KOReader's own debug logging (in the file browser, KOReader's Tools tab → More tools → Developer options → Enable debug logging) also turns the tracing on, but the request bodies and the token usage lines come from Console Debug alone. With it on, every API response prints its token usage: input tokens, output tokens, thinking tokens and cache hits (cache read and cache write) when the provider reports them, and the total, for streaming and non-streaming answers alike.
- **Show Debug in Chat**: a debug block above the conversation in the chat window: the messages sent to the AI (long ones cut to their first and last 2,000 characters), with the provider, model, temperature, reasoning, behavior and domain used. It shows neither the request body nor the raw response (Console Debug prints the request body). The chat window's gear menu has **Show Debug** for one window.
- **Debug Detail Level** (with Show Debug in Chat on): Minimal shows the messages alone, Names (the default) adds the provider, model and settings line, Full also adds the start of each part of the system prompt (behavior, domain, language).
- **Truncate Large Content (debug)** (with Console Debug on; on by default): in Console Debug's output, a field longer than 5,000 characters (book text, saved results, message text) is cut to its first and last 2,000 characters with a notice. The debug block in the chat window is always shortened this way.
- **AI Book Tools: Show Lookups (debug)**: appends the AI's book lookups, their raw results and the token usage to each answer; may include book text. See [Reasoning, Web Search and Book Tools](Reasoning-Web-Search-and-Book-Tools).
- **Test Connection**: sends one short message (capped at 512 tokens) to the current provider and model, over the endpoint you use (a custom endpoint from `configuration.lua`, the Ollama server picked in the menu, a Z.AI, Qwen, Kimi or Bedrock region), and shows the reply or the error until you tap it away.

The **Everything (debug)** export level (**Settings → Chat & Export Settings → Content Format**) is not the debug block: it adds every context message (long ones shortened) to the export, but not the settings line or the system prompt.

## The request inspector

The test suite includes an interactive web inspector that lets you test and experiment with KOAssistant on a computer, without KOReader:

- test API keys before using them on the e-reader;
- try behaviors, domains, temperature and reasoning;
- see exactly what is sent to each provider;
- send real requests and read the responses, including multi-turn chats with history;
- simulate every context (a highlight, book metadata, library selections);
- try the custom actions made in the action editor (read from your settings file; `custom_actions.lua` is not loaded);
- load your actual `domains/` folder.

**Requirements:** Lua 5.3 or newer with LuaSocket, LuaSec and dkjson; a clone from GitHub (the tests are left out of release zips to keep them small); the setup in `tests/README.md`.

```bash
cd /path/to/koassistant.koplugin

# Put the rocks on Lua's path first, matching your `lua -v`.
# Without this the web UI fails at startup with a setoption error.
eval "$(luarocks --lua-version 5.5 path)"

lua tests/inspect.lua --web
# Then open http://localhost:8080 in a browser
```

The command-line modes need no browser and are the quickest way to see what a change does to a request:

```bash
lua tests/inspect.lua --list                 # providers available for inspection
lua tests/inspect.lua --inspect anthropic    # the request for one provider
lua tests/inspect.lua --compare openai gemini
lua tests/inspect.lua --export anthropic     # the same thing as JSON
```

The inspector reads your actual settings file (`koassistant_settings.lua`), so run KOReader once on the same computer first, or restore a backup from your device there ([Backups and Updates](Backups-and-Updates#moving-settings-to-another-device)), to work with your real languages, behavior and temperature.

## For developers

The test suite lives in `tests/` and is left out of release zips, which hold the plugin alone (no `tests/`, `scripts/`, `hooks/`, `wiki/` or translation template), so clone the repository. `tests/README.md` has the setup.

```bash
lua tests/run_tests.lua --unit   # unit tests, no API calls
lua tests/run_tests.lua --full   # provider tests, real API calls
lua tests/inspect.lua anthropic  # the request one provider would get
lua tests/inspect.lua --web      # the interactive web UI
```

The plugin runs on KOReader's LuaJIT, which has Lua 5.1's limits (60 upvalues per function, 200 locals), so a file that loads under a desktop Lua can still fail to load on the device, and neither `luacheck .` nor the unit tests catch that: load each changed file with KOReader's own LuaJIT, `/path/to/koreader/luajit -e 'assert(loadfile("main.lua"))'` (on macOS the folder is `KOReader.app/Contents/koreader`). `luacheck .` and the unit tests are the other checks, and the wiki's own rules (links, menu paths, the generated tables) are among the tests: after a change to the settings schema or the model lists, `lua tests/tools/gen_settings_reference.lua` and `lua tests/tools/gen_provider_tables.lua` regenerate the Settings Reference and the Providers and Models tables. `git config core.hooksPath hooks/` turns on the pre-commit hook, which runs luacheck on the staged Lua files.

Running off the main branch: clone, or Code → Download ZIP, and install as in [Getting Started](Getting-Started). The updater never replaces a git checkout (a `.git` folder, or the `.git` file of a worktree): it still says when a release is out, without an **Update Now** button, and `git pull` updates it. A Code → Download ZIP copy has no `.git`, so the updater treats it like a release install and offers the next release over it. **Settings → Advanced → Setup Wizard (dev tools)**, which works only while Console Debug is on, holds the wizard's developer tools: the state each topic's probe reads, **Pretend unconfigured** and **Clear the version stamp (the update check fires again)**, for trying the two faces of the [Setup Wizard](Setup-Gestures-and-Panels#setup-wizard) on a configured install.

## Related

- [Troubleshooting](Troubleshooting): the problems the debug switches help with.
- [Providers and Models](Providers-and-Models): custom providers, custom models, endpoints.
- [Backups and Updates](Backups-and-Updates): what updates preserve, moving a configuration to a computer.
- [Contributing](Contributing): pull requests, the wiki's sources, translations.
